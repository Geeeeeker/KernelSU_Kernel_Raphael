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
# 背景：handle_inode_event 是 5.9+ 的特性；5.4 只有 handle_event，
#       且两者签名不同，无法直接转换。在 <5.9 内核上禁用 pkg_observer。
fix_sukisu_fsnotify_compat() {
    local kver
    kver=$(sed -nE 's/^VERSION[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' Makefile | head -1).\
$(sed -nE 's/^PATCHLEVEL[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' Makefile | head -1)

    # 只在 < 5.9 时处理（5.9 及以上已有 handle_inode_event）
    if [ "$(printf '%s\n' "5.9" "$kver" | sort -V | head -1)" != "5.9" ]; then
        echo "[*] Kernel $kver already supports handle_inode_event, skipping fsnotify fix"
        return 0
    fi

    local f="${KERNEL_DIR}/drivers/kernelsu/manager/pkg_observer.c"
    if [ ! -f "$f" ]; then
        echo "[-] pkg_observer.c not found, skipping fsnotify fix"
        return 0
    fi

    # 如果已经修补过（包含我们的标记），直接返回
    if grep -q 'SUSFS_FSNOTIFY_COMPAT' "$f"; then
        echo "[*] pkg_observer.c already patched for kernel < 5.9"
        return 0
    fi

    # 用 #if 0 包裹 fsnotify_ops 定义，使其在旧内核上不被编译
    # 同时把 ksu_handle_inode_event 也标记为 unused，避免 -Wunused 报错
    python3 - "$f" <<'PYEOF'
import sys, re
path = sys.argv[1]
src = open(path).read()

# 1. 找到 fsnotify_ops 的定义，用 #if 0 ... #endif 包裹
#    典型形式：static const struct fsnotify_ops fsnotify_ops = { ... };
pattern = r'(static\s+const\s+struct\s+fsnotify_ops\s+\w+\s*=\s*\{.*?\};)'
def wrap_ops(m):
    return "/* SUSFS_FSNOTIFY_COMPAT: kernel < 5.9 lacks handle_inode_event */\n#if 0\n" + m.group(1) + "\n#endif"
new_src, n = re.subn(pattern, wrap_ops, src, count=1, flags=re.S)
if n == 0:
    print("[-] Could not locate fsnotify_ops definition; aborting", file=sys.stderr)
    sys.exit(1)

# 2. 给 ksu_handle_inode_event 加上 __maybe_unused，避免未使用警告
new_src = re.sub(
    r'(int\s+ksu_handle_inode_event\s*\()',
    r'__maybe_unused \1',
    new_src, count=1
)

open(path, 'w').write(new_src)
print("[+] Wrapped fsnotify_ops in #if 0 and marked ksu_handle_inode_event unused")
PYEOF

    if [ $? -eq 0 ]; then
        echo "[+] pkg_observer.c patched for kernel $kver"
    else
        echo "[-] Failed to patch pkg_observer.c"
        return 1
    fi
}

fix_sukisu_fsnotify_compat
