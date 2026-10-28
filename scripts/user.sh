#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must be set}
cd "$KERNEL_DIR"

# 1. 修复 fair.c 缺失的 se_update_runnable 调用（保持你验证过的原样）
sed -i '/se_update_runnable(se);/s/^/\/\//' kernel/sched/fair.c

# 2. 清理 fs/stat.c 里被重复插入的 ksu_handle_stat，只在 newfstatat 里保留一处
python3 - <<'PY'
import re
path = 'fs/stat.c'
s = open(path).read()

# 删除所有调用行（extern 声明不动）
s = re.sub(r'^[ \t]*ksu_handle_stat\(&dfd, &filename, &flag\);[ \t]*\n', '', s, flags=re.M)

# 在 newfstatat 内、vfs_fstatat 调用之前插入一处
m = re.search(r'SYSCALL_DEFINE4\(newfstatat,', s)
if not m:
    raise SystemExit('newfstatat not found in fs/stat.c')
v = s.find('vfs_fstatat(', m.start())
if v < 0:
    raise SystemExit('vfs_fstatat not found after newfstatat')
line_start = s.rfind('\n', 0, v) + 1
s = s[:line_start] + '\tksu_handle_stat(&dfd, &filename, &flag);\n' + s[line_start:]

open(path, 'w').write(s)
print('fs/stat.c: kept exactly one ksu_handle_stat inside newfstatat')
PY

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
