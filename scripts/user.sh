#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must be set}
cd "$KERNEL_DIR"

# 1. 修复 fair.c 缺失的 se_update_runnable 调用（保持你验证过的原样）
sed -i '/se_update_runnable(se);/s/^/\/\//' kernel/sched/fair.c

# 2. 清理 fs/stat.c 中 newfstatat 里被错误插入的 ksu_handle_stat 调用
#    背景：
#      - fs/stat.c 原文件中，ksu_handle_stat 的正确调用位于 vfs_statx() 内，
#        使用 struct filename ** 类型（&fname），与文件开头的 extern 声明匹配。
#      - 某些 KSU 手动钩子补丁会在 newfstatat 中额外插入
#          ksu_handle_stat(&dfd, &filename, &flag);
#        此处 filename 为 const char __user *，&filename 与声明的
#        struct filename ** 不兼容，会触发 implicit declaration / 类型错误，
#        且常伴随 #ifdef/#endif 不平衡。
#    处理方式：
#      a) 只删除 newfstatat 函数体内（到 vfs_fstatat 调用之前）的
#         ksu_handle_stat(&dfd, &filename, &flag); 行；
#      b) 保留 vfs_statx() 中的调用和文件开头的 extern 声明不动；
#      c) 清理因此产生的孤儿 #endif。
python3 - <<'PY'
import re, sys

path = 'fs/stat.c'
try:
    s = open(path, encoding='utf-8').read()
except FileNotFoundError:
    sys.exit(f'{path}: not found')

# 定位 newfstatat 与它内部的 vfs_fstatat 调用之间的片段
m = re.search(r'SYSCALL_DEFINE4\(\s*newfstatat,', s)
if not m:
    sys.exit('newfstatat not found in fs/stat.c')
v = s.find('vfs_fstatat(', m.end())
if v < 0:
    sys.exit('vfs_fstatat not found after newfstatat')

segment = s[m.end():v]
new_segment, n = re.subn(
    r'^[ \t]*ksu_handle_stat\(&dfd, &filename, &flag\);[ \t]*\r?\n',
    '',
    segment, flags=re.M,
)
if n:
    print(f'fs/stat.c: removed {n} wrongly-inserted ksu_handle_stat call(s) from newfstatat')
else:
    print('fs/stat.c: no ksu_handle_stat call found in newfstatat (nothing to remove)')
s = s[:m.end()] + new_segment + s[v:]

# 预处理块平衡：删除孤儿 #endif
lines = s.splitlines(keepends=True)
balance = 0
kept = []
for i, line in enumerate(lines, 1):
    st = line.lstrip()
    if re.match(r'#\s*(if|ifdef|ifndef)\b', st):
        balance += 1
        kept.append(line)
    elif re.match(r'#\s*endif\b', st):
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

# 预览关键行，方便 CI 日志核对
import subprocess
print('--- verification ---')
subprocess.run(['grep', '-nE',
                r'(ksu_handle_stat|SYSCALL_DEFINE4\(.*newfstatat|vfs_statx|vfs_fstatat)',
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
