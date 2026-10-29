// SPDX-License-Identifier: GPL-2.0
/*
 * SUSFS_FSNOTIFY_COMPAT_V3
 *
 * Self-contained replacement for drivers/kernelsu/manager/pkg_observer.c.
 *
 * See commit message / workflow comment for the full rationale. Short version:
 *   - builtin's pkg_observer.c uses fsnotify_ops.handle_inode_event, a 5.9+
 *     field, and lacks pkg_observer_defs.h, so it cannot compile on 5.4.
 *   - this file expands the version splits manually and does not include any
 *     private KSU headers except the three that builtin actually ships.
 *   - ksu_set_ksud_present() / track_throne() may not be declared in the
 *     builtin headers, so prototypes are provided locally and weak bodies
 *     prevent link errors if nothing else defines them.
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

/*
 * Local prototypes.
 *
 * runtime/ksud_boot.h in the builtin branch does not declare
 * ksu_set_ksud_present(), so calls below would be implicit int and then
 * conflict with the weak void definition at end of file. Declaring both here
 * keeps the compiler happy regardless of what the builtin headers provide.
 */
extern void ksu_set_ksud_present(bool present);
extern void track_throne(bool force);

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

/* ---- fsnotify_ops -------------------------------------------------------- */

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
/*
 * If builtin defines these elsewhere (strong), these weak bodies are ignored.
 * If not, they satisfy the linker with no-ops. Signatures must match the
 * prototypes declared at the top of this file.
 */

__attribute__((weak)) void track_throne(bool force)           { (void)force; }
__attribute__((weak)) void ksu_set_ksud_present(bool present) { (void)present; }
