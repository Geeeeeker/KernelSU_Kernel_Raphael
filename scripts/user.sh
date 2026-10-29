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
fix_sukisu_fsnotify_compat() {
    local kver
    kver=$(sed -nE 's/^VERSION[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' Makefile | head -1).\
$(sed -nE 's/^PATCHLEVEL[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' Makefile | head -1)

    if [ "$(printf '%s\n' "5.9" "$kver" | sort -V | head -1)" != "5.9" ]; then
        echo "[*] Kernel $kver >= 5.9, skipping fsnotify fix"
        return 0
    fi

    local f="${KERNEL_DIR}/drivers/kernelsu/manager/pkg_observer.c"
    [ -f "$f" ] || { echo "[-] pkg_observer.c not found"; return 0; }

    if grep -q 'SUSFS_FSNOTIFY_COMPAT' "$f"; then
        echo "[*] pkg_observer.c already patched"
        return 0
    fi

    python3 - "$f" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()

# 确保能拿到 LINUX_VERSION_CODE
if '#include <linux/version.h>' not in src:
    src = '#include <linux/version.h>\n' + src

# 找到最后一个 #include 行的位置，作为 #if 的插入点
lines = src.split('\n')
insert_pos = 0
for i, line in enumerate(lines):
    if line.lstrip().startswith('#include'):
        insert_pos = i + 1

guard_open = (
    "/* SUSFS_FSNOTIFY_COMPAT: kernel < 5.9 lacks handle_inode_event */\n"
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)"
)
lines.insert(insert_pos, guard_open)

body = '\n'.join(lines)

tail = """

#else /* LINUX_VERSION_CODE < KERNEL_VERSION(5, 9, 0) */
/* SUSFS_FSNOTIFY_COMPAT: pkg_observer disabled on pre-5.9 kernels.
 * handle_inode_event does not exist there and handle_event has a different
 * (incompatible) signature. Stub the public entry points so callers link.
 */
int ksu_start_pkg_monitor(void) { return 0; }
void ksu_stop_pkg_monitor(void) { }
#endif /* SUSFS_FSNOTIFY_COMPAT */
"""
open(path, 'w').write(body.rstrip() + tail)
print("[+] Wrapped pkg_observer.c for kernel < 5.9 and added stubs")
PYEOF

    if [ $? -ne 0 ]; then
        echo "[-] Failed to patch pkg_observer.c"
        return 1
    fi
    echo "[+] pkg_observer.c patched for kernel $kver"
}
