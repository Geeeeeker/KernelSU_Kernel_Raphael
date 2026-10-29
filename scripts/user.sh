#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must be set}
cd "$KERNEL_DIR"

# 3. 添加 rtl8188eus WiFi 驱动（原样）
git clone --depth=1 --branch master https://github.com/Geeeeeker/android_kernel_xiaomi_sdm845.git rtl8188eus-repo
if [ -d "rtl8188eus-repo/drivers/rtl8188eus" ]; then
  cp -r rtl8188eus-repo/drivers/rtl8188eus drivers/
  echo 'obj-$(CONFIG_RTL8188EU) += rtl8188eus/' >> drivers/Makefile
  echo 'source "drivers/rtl8188eus/Kconfig"' >> drivers/Kconfig
else

grep -n 'ksu_handle_stat' fs/stat.c
  echo "Error: rtl8188eus directory not found"
  exit 1
fi
rm -rf rtl8188eus-repo

# 4. 修复 rtl8188eus 在 clang -Werror 下触发的 -Wparentheses-equality
#    原因：usb_halinit.c 里 if ((IS_FULL_SPEED_USB(Adapter)) ... 多包了一层括号，
#    该驱动是第三方老代码，直接对其目录关闭该警告最安全。
if [ -f drivers/rtl8188eus/Makefile ]; then
  if ! grep -q 'Wno-parentheses-equality' drivers/rtl8188eus/Makefile; then
    cat >> drivers/rtl8188eus/Makefile <<'EOF'

# Third-party rtl8188eus driver: silence clang's -Werror=parentheses-equality
subdir-ccflags-y += -Wno-parentheses-equality
subdir-ccflags-y += -Wno-error=parentheses-equality
EOF
    echo "rtl8188eus: appended -Wno-parentheses-equality to Makefile"
  else
    echo "rtl8188eus: -Wno-parentheses-equality already present"
  fi
else
  echo "rtl8188eus: Makefile not found, skip warning suppression"
fi


# ========== 修复 SukiSU-Ultra 在 5.4 内核上缺失 linux/pgtable.h ==========
# 背景：linux/pgtable.h 从 5.8 才独立拆分，5.4 只有 asm/pgtable.h。
#       sucompat.c 直接 include 前者会 fatal error。
# 替换策略：在整个 kernelsu 树里，凡是 include <linux/pgtable.h> 的，
#           一律改成 <asm/pgtable.h>，兼容 5.4 与之后的树。
fix_sukisu_pgtable_include() {
    local root="${KERNEL_DIR}/drivers/kernelsu"
    if [ ! -e "$root" ]; then
        echo "[-] ${root} not present; skipping pgtable fix (KSU not installed?)"
        return 0
    fi

    local count=0 f
    # grep -l 会跟随 symlink；显式遍历所有 .c/.h 更保险
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        sed -i 's|#include <linux/pgtable.h>|#include <asm/pgtable.h>|' "$f"
        count=$((count + 1))
        echo "[+] Replaced linux/pgtable.h -> asm/pgtable.h in ${f#"$KERNEL_DIR"/}"
    done < <(grep -rIl --include='*.c' --include='*.h' \
                  '#include <linux/pgtable.h>' "$root" 2>/dev/null)

    if [ "$count" -eq 0 ]; then
        echo "[*] No '#include <linux/pgtable.h>' found under drivers/kernelsu"
    else
        echo "[+] pgtable fix applied to ${count} file(s)"
    fi
}

fix_sukisu_pgtable_include



# ========== 修复 SukiSU-Ultra 在 5.4 内核上 fsnotify_ops 不兼容 ==========
# handle_inode_event 是 Linux 5.9+ 的 fsnotify_ops 字段，5.4 只有 handle_event
# 且两者签名互不兼容。在 <5.9 上整文件禁用 pkg_observer，只留空 stub。
# ========== 用兼容 5.4 的版本覆写 SukiSU-Ultra 的 pkg_observer.c ==========
# 上游 builtin 分支的 pkg_observer.c 是旧版，无条件使用 handle_inode_event
# （5.9+ 字段）。用带版本判断的新版整文件覆写，天然兼容 5.4。
fix_sukisu_fsnotify_compat() {
    local f="${KERNEL_DIR}/drivers/kernelsu/manager/pkg_observer.c"
    [ -f "$f" ] || { echo "[-] pkg_observer.c not found at $f"; return 0; }

    # 如果已经有版本判断，说明是新版，什么都不用做
    if grep -q 'LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)' "$f"; then
        echo "[*] pkg_observer.c already has 5.9 guard, skipping"
        return 0
    fi

    if grep -q 'SUSFS_FSNOTIFY_COMPAT_V2' "$f"; then
        echo "[*] pkg_observer.c already replaced with V2"
        return 0
    fi

    cp "$f" "${f}.orig"

    cat > "$f" <<'PKG_EOF'
// SPDX-License-Identifier: GPL-2.0
/* SUSFS_FSNOTIFY_COMPAT_V2: pre-5.9 compatible version */
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
#define MASK_ADB (FS_CLOSE_WRITE | FS_MOVE | FS_DELETE | FS_EVENT_ON_CHILD)

struct watch_dir {
	const char *path;
	u32 mask;
	struct path kpath;
	struct inode *inode;
	struct fsnotify_mark *mark;
};

static struct fsnotify_group *g;

#include "pkg_observer_defs.h"

static KSU_DECL_FSNOTIFY_OPS(ksu_handle_inode_event)
{
	if (!file_name)
		return 0;
	if (mask & FS_ISDIR)
		return 0;
	if (ksu_fname_len(file_name) == 13 &&
	    !memcmp(ksu_fname_arg(file_name), "packages.list", 13)) {
		pr_info("packages.list detected: %d\n", mask);
		track_throne(false);
	}
	if (ksu_fname_len(file_name) == 4 &&
	    !memcmp(ksu_fname_arg(file_name), "ksud", 4)) {
		if (mask & (FS_CLOSE_WRITE | FS_MOVED_TO))
			ksu_set_ksud_present(true);
		else if (mask & (FS_DELETE | FS_MOVED_FROM))
			ksu_set_ksud_present(false);
	}
	return 0;
}

static const struct fsnotify_ops ksu_ops = {
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)
	.handle_inode_event = ksu_handle_inode_event,
#else
	.handle_event = ksu_handle_inode_event,
#endif
};

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

static struct watch_dir g_watch = { .path = "/data/system",
				    .mask = MASK_SYSTEM };
static struct watch_dir g_adb_watch = { .path = "/data/adb",
					.mask = MASK_ADB };

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
PKG_EOF

    # 立刻验证
    if grep -q 'LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)' "$f" \
       && grep -q 'SUSFS_FSNOTIFY_COMPAT_V2' "$f"; then
        echo "[+] pkg_observer.c replaced (lines: $(wc -l < "$f"))"
    else
        echo "[-] Replacement verification failed; restoring backup"
        mv "${f}.orig" "$f"
        return 1
    fi
}
