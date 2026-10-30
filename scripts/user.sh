#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must be set}
cd "$KERNEL_DIR"

# 1. 修复 fair.c 缺失的 se_update_runnable 调用（保持原样）
sed -i '/se_update_runnable(se);/s/^/\/\//' kernel/sched/fair.c

# 2. 修复并恢复 fs/stat.c 中的 ksu_handle_stat hook
python3 - <<'PY'
import re, sys

path = 'fs/stat.c'
try:
    with open(path, 'r', encoding='utf-8') as f:
        s = f.read()
except FileNotFoundError:
    sys.exit(f'{path}: not found')

# (a) 先移除所有已有的 ksu_handle_stat 调用行（清理旧补丁的残留）
s, n = re.subn(
    r'^[ \t]*ksu_handle_stat\([^)\n]*\);[ \t]*\r?\n',
    '',
    s, flags=re.M,
)
print(f'fs/stat.c: removed {n} existing ksu_handle_stat call(s)')

# (b) 在 newfstatat 函数内、vfs_fstatat 调用之前，插入带正确 #ifdef 保护的调用
m = re.search(r'SYSCALL_DEFINE4\(\s*newfstatat,', s)
if not m:
    sys.exit('newfstatat not found in fs/stat.c')
v = s.find('vfs_fstatat(', m.end())
if v < 0:
    sys.exit('vfs_fstatat not found after newfstatat')
line_start = s.rfind('\n', 0, v) + 1
insert = (
    '#ifdef CONFIG_KSU\n'
    '\tksu_handle_stat(&dfd, &filename, &flag);\n'
    '#endif\n'
)
s = s[:line_start] + insert + s[line_start:]
print('fs/stat.c: inserted ksu_handle_stat with #ifdef CONFIG_KSU guard')

# (c) 确保 extern 声明存在且签名正确（const char __user **）
#     优先放在文件头部 include 之后，并同样用 #ifdef CONFIG_KSU 保护
decl = (
    '#ifdef CONFIG_KSU\n'
    'extern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);\n'
    '#endif\n'
)
if not re.search(r'extern\s+int\s+ksu_handle_stat\s*\(', s):
    # 找到最后一个 #include 行之后插入
    last_include = None
    for m2 in re.finditer(r'^#include[^\n]*\n', s, flags=re.M):
        last_include = m2
    if last_include:
        pos = last_include.end()
    else:
        # 没有 include 就放在 SPDX 行之后
        m2 = re.search(r'^// SPDX-License-Identifier:[^\n]*\n', s, flags=re.M)
        pos = m2.end() if m2 else 0
    s = s[:pos] + decl + s[pos:]
    print('fs/stat.c: added extern declaration for ksu_handle_stat')
else:
    print('fs/stat.c: extern declaration already present, skipping')

# (d) 最后做一次预处理块平衡检查：删除孤儿 #endif，并报告未闭合的 #if
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

with open(path, 'w', encoding='utf-8') as f:
    f.write(s)

# (e) 预览关键区域，方便 CI 日志核对
import subprocess
subprocess.run(['grep', '-nE',
                r'(ksu_handle_stat|SYSCALL_DEFINE4\(.*newfstatat|vfs_fstatat|#\s*(if|ifdef|ifndef|endif))',
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
