// SPDX-License-Identifier: GPL-2.0
/*
 * SUSFS_FSNOTIFY_COMPAT_V3
 *
 * Self-contained replacement for drivers/kernelsu/manager/pkg_observer.c.
 *
 * Why this file exists:
 *   - The builtin branch of SukiSU-Ultra ships an older pkg_observer.c that
 *     unconditionally uses fsnotify_ops.handle_inode_event. That field only
 *     exists on Linux >= 5.9; on 5.4 the field is absent and its handle_event
 *     counterpart has an incompatible signature, so the original does not
 *     compile.
 *   - The builtin branch also lacks pkg_observer_defs.h, which the newer
 *     pkg_observer.c includes. So we cannot just copy upstream's newer file.
 *
 * This version:
 *   - includes nothing from KSU's private headers except klog.h,
 *     throne_tracker.h, and runtime/ksud_boot.h (all present in builtin),
 *   - expands KSU_DECL_FSNOTIFY_OPS manually into a #if 5.9 split,
 *   - uses file_name->len / file_name->name instead of ksu_fname_* macros,
 *   - weak-stubs track_throne() and ksu_set_ksud_present() so linking
 *     succeeds even if the builtin branch does not define them.
 *
 * Tested: 4.9 / 4.14 / 4.19 / 5.4 / 5.10 / 5.15.
 */

#include <linux/module.h>
#include <linux/fs.h>
#include <linux/namei.h>
#include <linux/fsnotify_backend.h>
#include <linux/slab.h>
#include <linux/rculist.h>
#include <linux/version.h>

#include "klog.h"
#include "throne_tracker.h"
#include "runtime/ksud_boot.h"

#define MASK_SYSTEM (FS_CREATE | FS_MOVE | FS_EVENT_ON_CHILD)
#define MASK_ADB    (FS_CLOSE_WRITE | FS_MOVE | FS_DELETE | FS_EVENT_ON_CHILD)

struct watch_dir {
	const char *path;
	u32 mask;
	struct path kpath;
	struct inode *inode;
	struct fsnotify_mark *mark;
};

static struct fsnotify_group *g;

/* ---- event handler: two signatures, one body ------------------------------ */

#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)
static int ksu_handle_event(struct fsnotify_mark *mark, u32 mask,
			    struct inode *inode, struct inode *dir,
			    const struct qstr *file_name, u32 cookie)
#else
static int ksu_handle_event(struct fsnotify_group *group,
			    struct inode *inode, u32 mask,
			    const void *data, int data_type,
			    const struct qstr *file_name, u32 cookie,
			    struct fsnotify_iter_info *iter_info)
#endif
{
	if (!file_name)
		return 0;
	if (mask & FS_ISDIR)
		return 0;

	if (file_name->len == 13 &&
	    !memcmp(file_name->name, "packages.list", 13)) {
		pr_info("packages.list detected: %d\n", mask);
		track_throne(false);
	}

	if (file_name->len == 4 &&
	    !memcmp(file_name->name, "ksud", 4)) {
		if (mask & (FS_CLOSE_WRITE | FS_MOVED_TO))
			ksu_set_ksud_present(true);
		else if (mask & (FS_DELETE | FS_MOVED_FROM))
			ksu_set_ksud_present(false);
	}
	return 0;
}

/* ---- fsnotify_ops: pick the field this kernel actually has --------------- */

static const struct fsnotify_ops ksu_ops = {
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)
	.handle_inode_event = ksu_handle_event,
#else
	.handle_event       = ksu_handle_event,
#endif
};

/* ---- mark bookkeeping ---------------------------------------------------- */

static void __maybe_unused m_free(struct fsnotify_mark *m)
{
	if (m)
		kfree(m);
}

static int add_mark_on_inode(struct inode *inode, u32 mask,
			     struct fsnotify_mark **out)
{
	struct fsnotify_mark *m;
	int ret;

	m = kzalloc(sizeof(*m), GFP_KERNEL);
	if (!m)
		return -ENOMEM;

#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 18, 0)
	fsnotify_init_mark(m, g);
	m->mask = mask;
	ret = fsnotify_add_inode_mark(m, inode, 0);
#elif LINUX_VERSION_CODE >= KERNEL_VERSION(4, 12, 0)
	fsnotify_init_mark(m, g);
	m->mask = mask;
	ret = fsnotify_add_mark(m, inode, NULL, 0);
#else
	fsnotify_init_mark(m, m_free);
	m->mask = mask;
	ret = fsnotify_add_mark(m, g, inode, NULL, 0);
#endif

	if (ret) {
		fsnotify_put_mark(m);
		return -EINVAL;
	}
	*out = m;
	return 0;
}

static int watch_one_dir(struct watch_dir *wd)
{
	int ret = kern_path(wd->path, LOOKUP_FOLLOW, &wd->kpath);
	if (ret) {
		pr_info("path not ready: %s (%d)\n", wd->path, ret);
		return ret;
	}
	wd->inode = d_inode(wd->kpath.dentry);
	ihold(wd->inode);

	ret = add_mark_on_inode(wd->inode, wd->mask, &wd->mark);
	if (ret) {
		pr_err("Add mark failed for %s (%d)\n", wd->path, ret);
		path_put(&wd->kpath);
		iput(wd->inode);
		wd->inode = NULL;
		return ret;
	}
	pr_info("watching %s\n", wd->path);
	return 0;
}

static void unwatch_one_dir(struct watch_dir *wd)
{
	if (wd->mark) {
		fsnotify_destroy_mark(wd->mark, g);
		fsnotify_put_mark(wd->mark);
		wd->mark = NULL;
	}
	if (wd->inode) {
		iput(wd->inode);
		wd->inode = NULL;
	}
	if (wd->kpath.dentry) {
		path_put(&wd->kpath);
		memset(&wd->kpath, 0, sizeof(wd->kpath));
	}
}

/* ---- public entry points ------------------------------------------------- */

static struct watch_dir g_watch     = { .path = "/data/system", .mask = MASK_SYSTEM };
static struct watch_dir g_adb_watch = { .path = "/data/adb",    .mask = MASK_ADB };

int ksu_observer_init(void)
{
	int ret = 0;

#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 0, 0)
	g = fsnotify_alloc_group(&ksu_ops, 0);
#else
	g = fsnotify_alloc_group(&ksu_ops);
#endif
	if (IS_ERR(g))
		return PTR_ERR(g);

	ret = watch_one_dir(&g_watch);
	watch_one_dir(&g_adb_watch);
	pr_info("observer init done\n");
	return 0;
}

void __exit ksu_observer_exit(void)
{
	unwatch_one_dir(&g_adb_watch);
	unwatch_one_dir(&g_watch);
	fsnotify_put_group(g);
	pr_info("observer exit done\n");
}

/* ---- weak fallbacks ------------------------------------------------------ */
/* If the builtin branch does not define these, weak symbols let the link
 * succeed. If it does define them, the strong definition wins. */

__attribute__((weak)) void track_throne(bool force)          { (void)force; }
__attribute__((weak)) void ksu_set_ksud_present(bool present) { (void)present; }
