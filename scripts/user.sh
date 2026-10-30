#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must be set}
cd "$KERNEL_DIR"

# 1. 修复 fair.c 缺失的 se_update_runnable 调用（保持你验证过的原样）
sed -i '/se_update_runnable(se);/s/^/\/\//' kernel/sched/fair.c

# 2. 修复 fs/stat.c 中的 KSU hook
#    a) 所有 ksu_handle_stat(...) 调用替换为空语句 `;`，保留 `if (...) ;` 结构
#    b) 逐行扫描预处理块，删除孤儿 `#endif`
python3 - <<'PY'
import re, sys

path = 'fs/stat.c'
try:
    with open(path, 'r', encoding='utf-8') as f:
        s = f.read()
except FileNotFoundError:
    sys.exit(f'{path}: not found')

# (a) ksu_handle_stat(...) -> ;（空语句）
s, n = re.subn(
    r'^([ \t]*)ksu_handle_stat\([^)\n]*\);[ \t]*\r?\n',
    r'\1;\n',
    s, flags=re.M,
)
print(f'fs/stat.c: replaced {n} ksu_handle_stat call(s) with ";"')

# (b) 预处理块平衡：删除孤儿 #endif
lines = s.splitlines(keepends=True)
balance = 0
kept = []
for i, line in enumerate(lines, 1):
    stripped = line.lstrip()
    if re.match(r'#\s*(if|ifdef|ifndef)\b', stripped):
        balance += 1
        kept.append(line)
    elif re.match(r'#\s*endif\b', stripped):
        if balance == 0:
            print(f'fs/stat.c: removed orphan "#endif" at line {i}')
            continue
        balance -= 1
        kept.append(line)
    else:
        kept.append(line)
s = ''.join(kept)

if balance > 0:
    print(f'fs/stat.c: WARNING - {balance} unclosed #if block(s) remain')
else:
    print('fs/stat.c: preprocessor blocks balanced')

# 写回
with open(path, 'w', encoding='utf-8') as f:
    f.write(s)

# (c) 预览受影响区域，方便日志核对
import subprocess
subprocess.run(['grep', '-nE',
                r'(ksu_handle_stat|#\s*(if|ifdef|ifndef|endif))',
                path], check=False)
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
