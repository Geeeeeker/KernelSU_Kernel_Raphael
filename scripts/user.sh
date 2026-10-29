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











# ========== 用带版本判断的 rules.c 覆写 SukiSU-Ultra 的旧版 ==========
# builtin 分支的 rules.c 缺少 SELINUX_POLICY_INSTEAD_SELINUX_SS 判断，
# 直接访问 selinux_state.policy / policy_mutex，5.4(4.12-based) 上不存在，
# 无法编译。这里用带 #if LINUX_VERSION_CODE 分支的完整版本覆盖。
install_selinux_rules() {
    local dst="${KERNEL_DIR}/drivers/kernelsu/selinux/rules.c"

    if [ ! -d "$(dirname "$dst")" ]; then
        echo "[-] selinux dir not found: $(dirname "$dst"); skipping"
        return 0
    fi

    if grep -q 'SELINUX_POLICY_INSTEAD_SELINUX_SS' "$dst" 2>/dev/null; then
        echo "[*] rules.c already has version guard; skipping"
        return 0
    fi

    [ -f "$dst" ] && cp -v "$dst" "${dst}.orig"

    cat > "$dst" <<'RULES_EOF'
#include "linux/rcupdate.h"
#include "security.h"
#include <linux/uaccess.h>
#include <linux/types.h>
#include <linux/version.h>
#include <linux/lockdep.h>
#include <linux/slab.h>
#include <linux/string.h>
#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 13, 0)
#include <uapi/linux/sched/types.h>
#elif LINUX_VERSION_CODE >= KERNEL_VERSION(4, 12, 0)
#include <linux/sched/types.h>
#else
#include <linux/sched.h>
#endif
#include <linux/stop_machine.h>

#include "uapi/selinux.h"
#include "klog.h" // IWYU pragma: keep
#include "selinux.h"
#include "sepolicy.h"
#include "ss/services.h"
#include "linux/lsm_audit.h" // IWYU pragma: keep
#include "xfrm.h"
#include "compat/kernel_compat.h"

#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)
#define SELINUX_POLICY_INSTEAD_SELINUX_SS
#endif

#define ALL NULL

static DEFINE_MUTEX(ksu_rules);

static struct policydb *get_policydb(void)
{
    struct policydb *db;
#ifdef KSU_COMPAT_USE_SELINUX_STATE
#ifdef SELINUX_POLICY_INSTEAD_SELINUX_SS
    struct selinux_policy *policy = selinux_state.policy;
    db = &policy->policydb;
#else
    struct selinux_ss *ss = selinux_state.ss;
    db = &ss->policydb;
#endif
#else
    db = &policydb;
#endif
    return db;
}

#if ((!defined(KSU_COMPAT_USE_SELINUX_STATE)) || \
	LINUX_VERSION_CODE >= KERNEL_VERSION(6, 4, 0))
extern int avc_ss_reset(u32 seqno);
#else
extern int avc_ss_reset(struct selinux_avc *avc, u32 seqno);
#endif
// reset avc cache table, otherwise the new rules will not take effect if already denied
static void reset_avc_cache()
{
#if ((!defined(KSU_COMPAT_USE_SELINUX_STATE)) || \
	LINUX_VERSION_CODE >= KERNEL_VERSION(6, 4, 0))
    avc_ss_reset(0);
    selnl_notify_policyload(0);
    selinux_status_update_policyload(0);
#else
    struct selinux_avc *avc = selinux_state.avc;
    avc_ss_reset(avc, 0);
    selnl_notify_policyload(0);
    selinux_status_update_policyload(&selinux_state, 0);
#endif
    selinux_xfrm_notify_policyload();
}

#ifndef SELINUX_POLICY_INSTEAD_SELINUX_SS

// rwlock
#if defined(KSU_COMPAT_USE_SELINUX_STATE)
static inline rwlock_t *ksu_get_policy_rwlock(void) { return &selinux_state.ss->policy_rwlock; }
#elif defined(KSU_COMPAT_HAS_EXPORTED_POLICY_RWLOCK)
static inline rwlock_t *ksu_get_policy_rwlock(void) { extern rwlock_t policy_rwlock; return &policy_rwlock; }
#else
static inline rwlock_t *ksu_get_policy_rwlock(void) { return NULL; }
#endif

#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 2, 0) || defined(KSU_COMPAT_HAS_BACKPORTED_CPUS_PTR)
static inline const cpumask_t *ksu_get_current_cpumask_t() { return current->cpus_ptr; }
#else
static inline cpumask_t *ksu_get_current_cpumask_t() { return &current->cpus_allowed; }
#endif

#endif // #ifndef SELINUX_POLICY_INSTEAD_SELINUX_SS

static int apply_kernelsu_rules_fn(void *ptr)
{
	struct policydb *db = (struct policydb *)ptr;

    ksu_type(db, KERNEL_SU_DOMAIN, "domain");
    ksu_permissive(db, KERNEL_SU_DOMAIN);
    ksu_typeattribute(db, KERNEL_SU_DOMAIN, "mlstrustedsubject");
    ksu_typeattribute(db, KERNEL_SU_DOMAIN, "netdomain");
    ksu_typeattribute(db, KERNEL_SU_DOMAIN, "bluetoothdomain");

    // Create unconstrained file type
    ksu_type(db, KERNEL_SU_FILE, "file_type");
    ksu_typeattribute(db, KERNEL_SU_FILE, "mlstrustedobject");
    ksu_allow(db, "domain", KERNEL_SU_FILE, ALL, ALL);

    // allow all!
    ksu_allow(db, KERNEL_SU_DOMAIN, ALL, ALL, ALL);

    // allow us do any ioctl
    if (db->policyvers >= POLICYDB_VERSION_XPERMS_IOCTL) {
        ksu_allowxperm(db, KERNEL_SU_DOMAIN, ALL, "blk_file", ALL);
        ksu_allowxperm(db, KERNEL_SU_DOMAIN, ALL, "fifo_file", ALL);
        ksu_allowxperm(db, KERNEL_SU_DOMAIN, ALL, "chr_file", ALL);
        ksu_allowxperm(db, KERNEL_SU_DOMAIN, ALL, "file", ALL);
    }

    // we need to save allowlist in /data/adb/ksu
    ksu_allow(db, "kernel", "adb_data_file", "dir", ALL);
    ksu_allow(db, "kernel", "adb_data_file", "file", ALL);
    // we need to search /data/app
    ksu_allow(db, "kernel", "apk_data_file", "file", "open");
    ksu_allow(db, "kernel", "apk_data_file", "dir", "open");
    ksu_allow(db, "kernel", "apk_data_file", "dir", "read");
    ksu_allow(db, "kernel", "apk_data_file", "dir", "search");
    // we may need to do mount on shell
    ksu_allow(db, "kernel", "shell_data_file", "file", ALL);
    // we need to read /data/system/packages.list
    ksu_allow(db, "kernel", "kernel", "capability", "dac_override");
    // Android 10+:
    // http://aospxref.com/android-12.0.0_r3/xref/system/sepolicy/private/file_contexts#512
    ksu_allow(db, "kernel", "packages_list_file", "file", ALL);
    // Kernel 4.4
    ksu_allow(db, "kernel", "packages_list_file", "dir", ALL);
    // Android 9-:
    // http://aospxref.com/android-9.0.0_r61/xref/system/sepolicy/private/file_contexts#360
    ksu_allow(db, "kernel", "system_data_file", "file", ALL);
    ksu_allow(db, "kernel", "system_data_file", "dir", ALL);
    // our ksud triggered by init
    ksu_allow(db, "init", "adb_data_file", "file", ALL);
    ksu_allow(db, "init", "adb_data_file", "dir", ALL); // #1289
    ksu_allow(db, "init", KERNEL_SU_DOMAIN, ALL, ALL);
    // we need to umount modules in zygote
    ksu_allow(db, "zygote", "adb_data_file", "dir", "search");

    // copied from Magisk rules
    // suRights
    ksu_allow(db, "servicemanager", KERNEL_SU_DOMAIN, "dir", "search");
    ksu_allow(db, "servicemanager", KERNEL_SU_DOMAIN, "dir", "read");
    ksu_allow(db, "servicemanager", KERNEL_SU_DOMAIN, "file", "open");
    ksu_allow(db, "servicemanager", KERNEL_SU_DOMAIN, "file", "read");
    ksu_allow(db, "servicemanager", KERNEL_SU_DOMAIN, "process", "getattr");
    ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "process", "sigchld");

    // allowLog
    ksu_allow(db, "logd", KERNEL_SU_DOMAIN, "dir", "search");
    ksu_allow(db, "logd", KERNEL_SU_DOMAIN, "file", "read");
    ksu_allow(db, "logd", KERNEL_SU_DOMAIN, "file", "open");
    ksu_allow(db, "logd", KERNEL_SU_DOMAIN, "file", "getattr");

    // dumpsys, send fd
    ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "fd", "use");
    ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "fifo_file", "write");
    ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "fifo_file", "read");
    ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "fifo_file", "open");
    ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "fifo_file", "getattr");
    ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "unix_stream_socket", "read");
    ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "unix_stream_socket", "write");
    ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "unix_stream_socket", "connectto");
    ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "unix_stream_socket", "getopt");
    ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "unix_stream_socket", "getattr");

    // use memfd created by su domain
    ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "memfd_file", "execute");
    ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "memfd_file", "getattr");
    ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "memfd_file", "map");
    ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "memfd_file", "read");
    ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "memfd_file", "write");

    // bootctl
    ksu_allow(db, "hwservicemanager", KERNEL_SU_DOMAIN, "dir", "search");
    ksu_allow(db, "hwservicemanager", KERNEL_SU_DOMAIN, "file", "read");
    ksu_allow(db, "hwservicemanager", KERNEL_SU_DOMAIN, "file", "open");
    ksu_allow(db, "hwservicemanager", KERNEL_SU_DOMAIN, "process", "getattr");

    // For mounting loop devices, mirrors, tmpfs
    ksu_allow(db, "kernel", ALL, "file", "read");
    ksu_allow(db, "kernel", ALL, "file", "write");

    // Allow all binder transactions
    ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "binder", ALL);

    // Allow system server kill su process
    ksu_allow(db, "system_server", KERNEL_SU_DOMAIN, "process", "getpgid");
    ksu_allow(db, "system_server", KERNEL_SU_DOMAIN, "process", "sigkill");

    return 0;
}

void apply_kernelsu_rules()
{
	struct policydb *db;

	if (!getenforce()) {
		pr_info("SELinux permissive or disabled, apply rules!\n");
	}

#ifdef SELINUX_POLICY_INSTEAD_SELINUX_SS
	struct selinux_policy *pol, *old_pol = selinux_state.policy;
	mutex_lock(&selinux_state.policy_mutex);
	pol = ksu_dup_sepolicy(rcu_dereference_protected(old_pol, lockdep_is_held(&selinux_state.policy_mutex)));
	if (!pol) {
		pr_err("failed to dup selinux_policy\n");
		goto out_unlock;
	}
	db = &pol->policydb;

	apply_kernelsu_rules_fn((void *)db);

	rcu_assign_pointer(selinux_state.policy, pol);
	synchronize_rcu();
	ksu_destroy_sepolicy(old_pol);

	reset_avc_cache();
out_unlock:
	mutex_unlock(&selinux_state.policy_mutex);
#else

	cpumask_t old_mask;
	db = get_policydb();
	rwlock_t *lock = ksu_get_policy_rwlock();
	
	if (!lock)
		goto do_stop_machine;

	/*
	 * HACK: write_lock() is held with preempt enabled. DO NOT let the
	 * task be migrated to any other CPU than the current CPU. And since
	 * set_cpus_allowed_ptr() can sleep, use raw_smp_processor_id() to get
	 * current CPU and bypass preemption checks.
	 */
	cpumask_copy(&old_mask, ksu_get_current_cpumask_t());
	set_cpus_allowed_ptr(current, cpumask_of(raw_smp_processor_id()));

	write_lock(lock);
	preempt_enable();

    // we do this dance since both kernel and userspace can trigger this
	if (likely(current && current->mm))
		goto has_current_mm;

	apply_kernelsu_rules_fn((void *)db);
	goto out_unlock;

has_current_mm:
	;

    // HACK: raise priority of this to the heavens
	int old_policy = current->policy;
	struct sched_param old_param = { .sched_priority = current->rt_priority };
	struct sched_param new_param = { .sched_priority = 50 };

	sched_setscheduler_nocheck(current, 1, &new_param); // raise, fifo, 50
	apply_kernelsu_rules_fn((void *)db);
	sched_setscheduler_nocheck(current, old_policy, &old_param); // restore

out_unlock:
	preempt_disable();
	write_unlock(lock);
	set_cpus_allowed_ptr(current, &old_mask);
	goto out_flush;

do_stop_machine:
	stop_machine(apply_kernelsu_rules_fn, (void *)db, NULL);

out_flush:
	smp_mb();
	reset_avc_cache();
#endif
}

#define KSU_SEPOLICY_MAX_BATCH_SIZE (8U * 1024U * 1024U)
#define KSU_SEPOLICY_MAX_ARGS 5

struct sepol_data {
    u32 cmd;
    u32 subcmd;
};

struct sepol_batch_cursor {
    const u8 *cur;
    const u8 *end;
};

static size_t sepol_remaining(const struct sepol_batch_cursor *cursor)
{
    return (size_t)(cursor->end - cursor->cur);
}

static int sepol_read_cmd_header(struct sepol_batch_cursor *cursor,
                                 struct sepol_data *header)
{
    if (sepol_remaining(cursor) < sizeof(*header)) {
        return -EINVAL;
    }

    memcpy(header, cursor->cur, sizeof(*header));
    cursor->cur += sizeof(*header);

    return 0;
}

static int sepol_read_string(struct sepol_batch_cursor *cursor,
                             const char **out)
{
    u32 len;
    const char *str;

    if (sepol_remaining(cursor) < sizeof(len)) {
        return -EINVAL;
    }

    memcpy(&len, cursor->cur, sizeof(len));
    cursor->cur += sizeof(len);

    if (len >= sepol_remaining(cursor)) {
        return -EINVAL;
    }

    str = (const char *)cursor->cur;
    if (memchr(str, '\0', len) != NULL || str[len] != '\0') {
        return -EINVAL;
    }

    cursor->cur += len + 1;
    if (len == 0) {
        *out = ALL;
        return 0;
    }

    *out = str;
    return 0;
}

static int sepol_require_not_all(const char *value, const char *name)
{
    if (value != ALL) {
        return 0;
    }

    pr_err("sepol: %s cannot be ALL.\n", name);
    return -EINVAL;
}

int sepol_expected_argc(u32 cmd)
{
    switch (cmd) {
    case KSU_SEPOLICY_CMD_NORMAL_PERM:
        return 4;
    case KSU_SEPOLICY_CMD_XPERM:
        return 5;
    case KSU_SEPOLICY_CMD_TYPE_STATE:
        return 1;
    case KSU_SEPOLICY_CMD_TYPE:
    case KSU_SEPOLICY_CMD_TYPE_ATTR:
        return 2;
    case KSU_SEPOLICY_CMD_ATTR:
        return 1;
    case KSU_SEPOLICY_CMD_TYPE_TRANSITION:
        return 5;
    case KSU_SEPOLICY_CMD_TYPE_CHANGE:
        return 4;
    case KSU_SEPOLICY_CMD_GENFSCON:
        return 3;
    default:
        return -EINVAL;
    }
}

static int apply_one_sepolicy_cmd(struct policydb *db,
                                  const struct sepol_data *header,
                                  const char **args)
{
    bool success = false;
    int ret;

    switch (header->cmd) {
    case KSU_SEPOLICY_CMD_NORMAL_PERM:
        if (header->subcmd == KSU_SEPOLICY_SUBCMD_NORMAL_PERM_ALLOW) {
            success = ksu_allow(db, args[0], args[1], args[2], args[3]);
        } else if (header->subcmd == KSU_SEPOLICY_SUBCMD_NORMAL_PERM_DENY) {
            success = ksu_deny(db, args[0], args[1], args[2], args[3]);
        } else if (header->subcmd == KSU_SEPOLICY_SUBCMD_NORMAL_PERM_AUDITALLOW) {
            success = ksu_auditallow(db, args[0], args[1], args[2], args[3]);
        } else if (header->subcmd == KSU_SEPOLICY_SUBCMD_NORMAL_PERM_DONTAUDIT) {
            success = ksu_dontaudit(db, args[0], args[1], args[2], args[3]);
        } else {
            pr_err("sepol: unknown subcmd: %d\n", header->subcmd);
        }
        return success ? 0 : -EINVAL;

    case KSU_SEPOLICY_CMD_XPERM:
        ret = sepol_require_not_all(args[3], "operation");
        if (ret < 0) {
            return ret;
        }
        ret = sepol_require_not_all(args[4], "perm_set");
        if (ret < 0) {
            return ret;
        }

        if (header->subcmd == KSU_SEPOLICY_SUBCMD_XPERM_ALLOW) {
            success = ksu_allowxperm(db, args[0], args[1], args[2], args[4]);
        } else if (header->subcmd == KSU_SEPOLICY_SUBCMD_XPERM_AUDITALLOW) {
            success =
                ksu_auditallowxperm(db, args[0], args[1], args[2], args[4]);
        } else if (header->subcmd == KSU_SEPOLICY_SUBCMD_XPERM_DONTAUDIT) {
            success =
                ksu_dontauditxperm(db, args[0], args[1], args[2], args[4]);
        } else {
            pr_err("sepol: unknown subcmd: %d\n", header->subcmd);
        }
        return success ? 0 : -EINVAL;

    case KSU_SEPOLICY_CMD_TYPE_STATE:
        ret = sepol_require_not_all(args[0], "type");
        if (ret < 0) {
            return ret;
        }

        if (header->subcmd == KSU_SEPOLICY_SUBCMD_TYPE_STATE_PERMISSIVE) {
            success = ksu_permissive(db, args[0]);
        } else if (header->subcmd == KSU_SEPOLICY_SUBCMD_TYPE_STATE_ENFORCE) {
            success = ksu_enforce(db, args[0]);
        } else {
            pr_err("sepol: unknown subcmd: %d\n", header->subcmd);
        }
        return success ? 0 : -EINVAL;

    case KSU_SEPOLICY_CMD_TYPE:
    case KSU_SEPOLICY_CMD_TYPE_ATTR:
        ret = sepol_require_not_all(args[0], "type");
        if (ret < 0) {
            return ret;
        }
        ret = sepol_require_not_all(args[1], "attribute");
        if (ret < 0) {
            return ret;
        }

        if (header->cmd == KSU_SEPOLICY_CMD_TYPE) {
            success = ksu_type(db, args[0], args[1]);
        } else {
            success = ksu_typeattribute(db, args[0], args[1]);
        }
        if (!success) {
            pr_err("sepol: %d failed.\n", header->cmd);
            return -EINVAL;
        }
        return 0;

    case KSU_SEPOLICY_CMD_ATTR:
        ret = sepol_require_not_all(args[0], "attribute");
        if (ret < 0) {
            return ret;
        }

        if (!ksu_attribute(db, args[0])) {
            pr_err("sepol: %d failed.\n", header->cmd);
            return -EINVAL;
        }
        return 0;

    case KSU_SEPOLICY_CMD_TYPE_TRANSITION: {
        const char *object = ALL;

        ret = sepol_require_not_all(args[0], "src");
        if (ret < 0) {
            return ret;
        }
        ret = sepol_require_not_all(args[1], "tgt");
        if (ret < 0) {
            return ret;
        }
        ret = sepol_require_not_all(args[2], "cls");
        if (ret < 0) {
            return ret;
        }
        ret = sepol_require_not_all(args[3], "default_type");
        if (ret < 0) {
            return ret;
        }

        object = args[4];

        success =
            ksu_type_transition(db, args[0], args[1], args[2], args[3], object);
        return success ? 0 : -EINVAL;
    }

    case KSU_SEPOLICY_CMD_TYPE_CHANGE:
        ret = sepol_require_not_all(args[0], "src");
        if (ret < 0) {
            return ret;
        }
        ret = sepol_require_not_all(args[1], "tgt");
        if (ret < 0) {
            return ret;
        }
        ret = sepol_require_not_all(args[2], "cls");
        if (ret < 0) {
            return ret;
        }
        ret = sepol_require_not_all(args[3], "default_type");
        if (ret < 0) {
            return ret;
        }

        if (header->subcmd == KSU_SEPOLICY_SUBCMD_TYPE_CHANGE_CHANGE) {
            success = ksu_type_change(db, args[0], args[1], args[2], args[3]);
        } else if (header->subcmd == KSU_SEPOLICY_SUBCMD_TYPE_CHANGE_MEMBER) {
            success = ksu_type_member(db, args[0], args[1], args[2], args[3]);
        } else {
            pr_err("sepol: unknown subcmd: %d\n", header->subcmd);
        }
        return success ? 0 : -EINVAL;

    case KSU_SEPOLICY_CMD_GENFSCON:
        ret = sepol_require_not_all(args[0], "name");
        if (ret < 0) {
            return ret;
        }
        ret = sepol_require_not_all(args[1], "path");
        if (ret < 0) {
            return ret;
        }
        ret = sepol_require_not_all(args[2], "context");
        if (ret < 0) {
            return ret;
        }

        if (!ksu_genfscon(db, args[0], args[1], args[2])) {
            pr_err("sepol: %d failed.\n", header->cmd);
            return -EINVAL;
        }
        return 0;

    default:
        pr_err("sepol: unknown cmd: %d\n", header->cmd);
        return -EINVAL;
    }
}

#ifdef SELINUX_POLICY_INSTEAD_SELINUX_SS
int handle_sepolicy(void __user *user_data, u64 data_len)
{
	struct selinux_policy *pol, *old_pol;
	struct policydb *db;
	struct sepol_batch_cursor cursor;
	u8 *payload;
	int ret;
	int success_cmd_count;
	u32 cmd_index;

	if (!user_data || !data_len) {
		return -EINVAL;
	}

	if (data_len > KSU_SEPOLICY_MAX_BATCH_SIZE) {
		return -E2BIG;
	}

	payload = kvmalloc((size_t)data_len, GFP_KERNEL);
	if (!payload) {
		return -ENOMEM;
	}

	if (copy_from_user(payload, user_data, (size_t)data_len)) {
		ret = -EFAULT;
		goto out_free;
	}

	if (!getenforce()) {
		pr_info("SELinux permissive or disabled when handle policy!\n");
	}

	mutex_lock(&selinux_state.policy_mutex);

	old_pol = selinux_state.policy;
	pol = ksu_dup_sepolicy(rcu_dereference_protected(
		old_pol, lockdep_is_held(&selinux_state.policy_mutex)));
	if (!pol) {
		ret = -ENOMEM;
		goto out_unlock;
	}
	db = &pol->policydb;

	cursor.cur = payload;
	cursor.end = payload + (size_t)data_len;

	ret = 0;
	success_cmd_count = 0;
	cmd_index = 0;
	while (cursor.cur < cursor.end) {
		struct sepol_data header;
		const char *args[KSU_SEPOLICY_MAX_ARGS] = { 0 };
		int expected_argc;
		u32 arg_index;

		ret = sepol_read_cmd_header(&cursor, &header);
		if (ret < 0) {
			pr_err("sepol: failed to read cmd header #%u.\n", cmd_index);
			goto out_drop_new_policy;
		}

		expected_argc = sepol_expected_argc(header.cmd);
		if (expected_argc < 0 || expected_argc > KSU_SEPOLICY_MAX_ARGS) {
			ret = -EINVAL;
			pr_err("sepol: invalid cmd header #%u.\n", cmd_index);
			goto out_drop_new_policy;
		}

		for (arg_index = 0; arg_index < (u32)expected_argc; arg_index++) {
			ret = sepol_read_string(&cursor, &args[arg_index]);
			if (ret < 0) {
				pr_err("sepol: failed to read cmd #%u arg #%u.\n", cmd_index, arg_index);
				goto out_drop_new_policy;
			}
		}

		ret = apply_one_sepolicy_cmd(db, &header, args);
		if (ret < 0) {
			pr_err("sepol: cmd #%u failed, cmd=%u subcmd=%u.\n", cmd_index, header.cmd, header.subcmd);
		} else {
			success_cmd_count++;
		}
		cmd_index++;
	}

	rcu_assign_pointer(selinux_state.policy, pol);
	synchronize_rcu();
	ksu_destroy_sepolicy(old_pol);

	reset_avc_cache();
	ret = success_cmd_count;
	goto out_unlock;

out_drop_new_policy:
	ksu_destroy_sepolicy(pol);
out_unlock:
	mutex_unlock(&selinux_state.policy_mutex);
out_free:
	kvfree(payload);

	return ret;
}
#else

struct handle_sepolicy_args {
	void *ctx_success_cmd_count;
	void *ctx_payload;
	u64 ctx_data_len;
};

static int handle_sepolicy_fn(void *data)
{
	struct sepol_batch_cursor cursor;
	int ret = 0;
	u32 cmd_index = 0;
	int success_cmd_count = 0;

	struct policydb *db = get_policydb();
	struct handle_sepolicy_args *ctx = (struct handle_sepolicy_args *)data;
	u8 *payload = (u8 *)ctx->ctx_payload;
	u64 data_len = ctx->ctx_data_len;

	cursor.cur = payload;
	cursor.end = payload + (size_t)data_len;

	while (cursor.cur < cursor.end) {
		struct sepol_data header;
		const char *args[KSU_SEPOLICY_MAX_ARGS] = { 0 };
		int expected_argc;
		u32 arg_index;

		ret = sepol_read_cmd_header(&cursor, &header);
		if (ret < 0) {
			pr_err("sepol: failed to read cmd header #%u.\n", cmd_index);
			goto out;
		}

		expected_argc = sepol_expected_argc(header.cmd);
		if (expected_argc < 0 || expected_argc > KSU_SEPOLICY_MAX_ARGS) {
			ret = -EINVAL;
			pr_err("sepol: invalid cmd header #%u.\n", cmd_index);
			goto out;
		}

		for (arg_index = 0; arg_index < (u32)expected_argc; arg_index++) {
			ret = sepol_read_string(&cursor, &args[arg_index]);
			if (ret < 0) {
				pr_err("sepol: failed to read cmd #%u arg #%u.\n", cmd_index, arg_index);
				goto out;
			}
		}

		ret = apply_one_sepolicy_cmd(db, &header, args);
		if (ret < 0)
			pr_err("sepol: cmd #%u failed, cmd=%u subcmd=%u.\n", cmd_index, header.cmd, header.subcmd);
		else {
			success_cmd_count++;
		}

		cmd_index++;
	}

out:
	*(int *)(ctx->ctx_success_cmd_count) = success_cmd_count;
	return ret;
}

int handle_sepolicy(void __user *user_data, u64 data_len)
{
	u8 *payload;
	int ret = 0;
	int success_cmd_count = 0;
	cpumask_t old_mask;

	if (!user_data || !data_len)
		return -EINVAL;

	if (data_len > KSU_SEPOLICY_MAX_BATCH_SIZE)
		return -E2BIG;

	payload = kvmalloc((size_t)data_len, GFP_KERNEL);
	if (!payload)
		return -ENOMEM;

	if (copy_from_user(payload, user_data, (size_t)data_len)) {
		ret = -EFAULT;
		goto out_free;
	}

	if (!getenforce()) {
		pr_info("SELinux permissive or disabled when handle policy!\n");
	}

	struct handle_sepolicy_args ctx = { 0 };
	ctx.ctx_success_cmd_count = (void *)&success_cmd_count;
	ctx.ctx_payload = (void *)payload;
	ctx.ctx_data_len = (u64)data_len;

	rwlock_t *lock = ksu_get_policy_rwlock();
	if (!lock)
		goto do_stop_machine;

	/*
	 * HACK: write_lock() is held with preempt enabled. DO NOT let the
	 * task be migrated to any other CPU than the current CPU. And since
	 * set_cpus_allowed_ptr() can sleep, use raw_smp_processor_id() to get
	 * current CPU and bypass preemption checks.
	 */
	cpumask_copy(&old_mask, ksu_get_current_cpumask_t());
	set_cpus_allowed_ptr(current, cpumask_of(raw_smp_processor_id()));

	write_lock(lock);
	preempt_enable();

	if (likely(current && current->mm))
		goto has_current_mm;

	ret = handle_sepolicy_fn((void *)&ctx);
	goto out_unlock;

has_current_mm:
	;

	int old_policy = current->policy;
	struct sched_param old_param = { .sched_priority = current->rt_priority };
	struct sched_param new_param = { .sched_priority = 50 };

	sched_setscheduler_nocheck(current, 1, &new_param);
	ret = handle_sepolicy_fn((void *)&ctx);
	sched_setscheduler_nocheck(current, old_policy, &old_param);

out_unlock:
	preempt_disable();
	write_unlock(lock);
	set_cpus_allowed_ptr(current, &old_mask);
	goto out_done;

do_stop_machine:
	ret = stop_machine(handle_sepolicy_fn, (void *)&ctx, NULL);

out_done:
	if (ret)
		goto out_free;

	smp_mb();
	reset_avc_cache();
	ret = success_cmd_count;

out_free:
	kvfree(payload);

	return ret;
}
#endif // SELINUX_POLICY_INSTEAD_SELINUX_SS
RULES_EOF

    if grep -q 'SELINUX_POLICY_INSTEAD_SELINUX_SS' "$dst"; then
        echo "[+] rules.c replaced ($(wc -l < "$dst") lines)"
    else
        echo "[-] FAIL: rules.c replacement failed"
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
install_selinux_rules


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
