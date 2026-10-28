#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must be set}
cd "$KERNEL_DIR"

# 1. 修复 fair.c 缺失的 se_update_runnable 调用
sed -i '/se_update_runnable(se);/s/^/\/\//' kernel/sched/fair.c

# 2. 添加 rtl8188eus WiFi 驱动
git clone --depth=1 --branch master https://github.com/Geeeeeker/android_kernel_xiaomi_sdm845.git rtl8188eus-repo
if [ -d "rtl8188eus-repo/drivers/rtl8188eus" ]; then
  cp -r rtl8188eus-repo/drivers/rtl8188eus drivers/
  echo 'obj-$(CONFIG_RTL8188EU) += rtl8188eus/' >> drivers/Makefile
  echo 'source "drivers/rtl8188eus/Kconfig"' >> drivers/Kconfig
else
  echo "Error: rtl8188eus directory not found"
  exit 1
fi
rm -rf rtl8188eus-repo

# 3. 自动修复stat.c声明位置问题。
python3 - <<'PY'
import re
path = 'fs/stat.c'
src = open(path).read()
decl = 'extern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);'
# 移除原位置的声明（如果在 #ifdef 块里，把 #ifdef/#endif 一起处理）
src = re.sub(r'#ifdef CONFIG_KSU\s*\n\s*' + re.escape(decl) + r'\s*\n#endif\s*\n', '', src)
# 在第一个函数定义前插入声明
marker = 'SYSCALL_DEFINE'
idx = src.find(marker)
src = src[:idx] + f'#ifdef CONFIG_KSU\n{decl}\n#endif\n\n' + src[idx:]
open(path, 'w').write(src)
print("moved ksu_handle_stat declaration to top of fs/stat.c")
PY
