#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must be set}
cd "$KERNEL_DIR"

# ============================================================
# 1. 修复 SukiSU-Ultra 在 5.4 内核上缺失 linux/pgtable.h
# ============================================================
fix_sukisu_pgtable_include() {
    local root="${KERNEL_DIR}/drivers/kernelsu"
    if [ ! -e "$root" ]; then
        echo "[-] ${root} not present; skipping pgtable fix"
        return 0
    fi

    local count=0 f
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

# ============================================================
# 2. 修复 SukiSU-Ultra 在 5.4 内核上 allowlist.c 的 API 差异
#    - TWA_RESUME 是 5.7+ 才有的 task_work_add 第三参数 → 改成 true
#    - put_task_struct 在 5.4 需要 <linux/sched/task.h>
#    幂等：重复运行不会二次修改
# ============================================================
fix_allowlist_for_54() {
    local f="${KERNEL_DIR}/drivers/kernelsu/policy/allowlist.c"
    if [ ! -f "$f" ]; then
        echo "[-] allowlist.c not found at $f; skipping"
        return 0
    fi

    python3 - "$f" <<'PY'
import sys
path = sys.argv[1]
src = open(path).read()
changed = []

# (a) <linux/sched/task.h> — 5.4 的 <linux/sched.h> 不含 put_task_struct 原型
if '#include <linux/sched/task.h>' not in src:
    if '#include <linux/sched.h>' in src:
        src = src.replace('#include <linux/sched.h>',
                          '#include <linux/sched.h>\n#include <linux/sched/task.h>', 1)
        changed.append('include sched/task.h')
    else:
        src = '#include <linux/sched/task.h>\n' + src
        changed.append('prepend sched/task.h')

# (b) TWA_RESUME (5.7+) -> true (5.4 的 bool 参数)
if 'TWA_RESUME' in src:
    src = src.replace('TWA_RESUME', 'true')
    changed.append('TWA_RESUME -> true')

if changed:
    open(path, 'w').write(src)
    print('[+] allowlist.c patched: ' + ', '.join(changed))
else:
    print('[*] allowlist.c already compatible')
PY

    # 落地校验：TWA_RESUME 必须消失、sched/task.h 必须出现
    if grep -q 'TWA_RESUME' "$f"; then
        echo "[-] FAIL: TWA_RESUME still present in allowlist.c"
        return 1
    fi
    if ! grep -q '#include <linux/sched/task.h>' "$f"; then
        echo "[-] FAIL: <linux/sched/task.h> not added to allowlist.c"
        return 1
    fi
    echo "[+] allowlist.c verified: TWA_RESUME gone, sched/task.h present"
}

# ============================================================
# 3. rtl8188eus WiFi 驱动
# ============================================================
install_rtl8188eus() {
    git clone --depth=1 --branch master \
        https://github.com/Geeeeeker/android_kernel_xiaomi_sdm845.git rtl8188eus-repo
    if [ -d "rtl8188eus-repo/drivers/rtl8188eus" ]; then
        cp -r rtl8188eus-repo/drivers/rtl8188eus drivers/
        echo 'obj-$(CONFIG_RTL8188EU) += rtl8188eus/' >> drivers/Makefile
        echo 'source "drivers/rtl8188eus/Kconfig"'      >> drivers/Kconfig
    else
        echo "[-] rtl8188eus directory not found"
        rm -rf rtl8188eus-repo
        exit 1
    fi
    rm -rf rtl8188eus-repo

    # 关闭 clang -Werror=parentheses-equality（第三方老代码）
    if [ -f drivers/rtl8188eus/Makefile ]; then
        if ! grep -q 'Wno-parentheses-equality' drivers/rtl8188eus/Makefile; then
            cat >> drivers/rtl8188eus/Makefile <<'EOF'

# Third-party rtl8188eus driver: silence clang's -Werror=parentheses-equality
subdir-ccflags-y += -Wno-parentheses-equality
subdir-ccflags-y += -Wno-error=parentheses-equality
EOF
            echo "rtl8188eus: appended -Wno-parentheses-equality"
        else
            echo "rtl8188eus: -Wno-parentheses-equality already present"
        fi
    fi
}

# ========== 修复 cpu_spoof.c 在 5.4 内核上 vdso_clock_mode 缺失 ==========
# vdso_clock_mode 是 Linux 5.7/5.8 才加入 struct clocksource 的成员。
# 在 5.4 上，把引用该成员的代码段用版本宏包裹，旧内核直接跳过。
fix_cpu_spoof_for_54() {
    local f="${KERNEL_DIR}/drivers/kernelsu/extension/cpu_spoof.c"
    if [ ! -f "$f" ]; then
        echo "[-] cpu_spoof.c not found at $f; skipping"
        return 0
    fi

    if grep -q 'SUSFS_CPU_SPOOF_COMPAT' "$f"; then
        echo "[*] cpu_spoof.c already patched"
        return 0
    fi

    python3 - "$f" <<'PY'
import sys, re
path = sys.argv[1]
src = open(path).read()

# 匹配包含 vdso_clock_mode 的赋值语句块。典型形式：
#   (*curr_cs_ptr)->vdso_clock_mode = ...;
# 也可能跨多行。用正则找到该语句，并用 #if 包裹。
pattern = r'(\s*\(\*curr_cs_ptr\)->vdso_clock_mode\s*=[^;]*;)'
match = re.search(pattern, src, flags=re.S)
if not match:
    print('[-] Could not locate vdso_clock_mode assignment; aborting', file=sys.stderr)
    sys.exit(1)

block = match.group(1)
wrapped = (
    '\n/* SUSFS_CPU_SPOOF_COMPAT: vdso_clock_mode is 5.7+ */\n'
    '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 7, 0)\n'
    + block +
    '\n#endif /* SUSFS_CPU_SPOOF_COMPAT */\n'
)

# 确保 LINUX_VERSION_CODE 可用
if '#include <linux/version.h>' not in src:
    src = '#include <linux/version.h>\n' + src

src = src.replace(block, wrapped, 1)
open(path, 'w').write(src)
print('[+] cpu_spoof.c patched: wrapped vdso_clock_mode in #if 5.7+')
PY

    if grep -q 'SUSFS_CPU_SPOOF_COMPAT' "$f"; then
        echo "[+] cpu_spoof.c verified"
    else
        echo "[-] FAIL: cpu_spoof.c patch not applied"
        return 1
    fi
}


# ============================================================
# 执行
# ============================================================
fix_sukisu_pgtable_include
fix_allowlist_for_54
install_rtl8188eus
fix_cpu_spoof_for_54

# ============================================================
# 4. 打印 allowlist.c 全文，便于在 CI 日志中核对
# ============================================================
ALLOWLIST="${KERNEL_DIR}/drivers/kernelsu/policy/allowlist.c"
if [ -f "$ALLOWLIST" ]; then
    echo "============================================================"
    echo " BEGIN allowlist.c ($(wc -l < "$ALLOWLIST") lines)"
    echo "============================================================"
    cat -n "$ALLOWLIST"
    echo "============================================================"
    echo " END allowlist.c"
    echo "============================================================"
else
    echo "[-] allowlist.c not found at $ALLOWLIST"
fi
