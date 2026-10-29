// SPDX-License-Identifier: GPL-2.0
/*
 * SUSFS_SELINUX_RULES_COMPAT_V1
 *
 * Stub replacement for drivers/kernelsu/selinux/rules.c on kernels whose
 * struct selinux_state has neither .policy nor .policy_mutex.
 *
 * The upstream rules.c targets Linux >= 5.10, where selinux_state carries
 * a struct selinux_policy *policy protected by policy_mutex, and where
 * struct selinux_policy is defined in security/selinux/ss/services.h.
 * Trees that report 5.4 but descend from 4.x (e.g. "4.12 upgraded to 5.4")
 * still use struct selinux_ss instead, so the upstream code does not and
 * cannot compile.
 *
 * Consequence: runtime SELinux policy modification (granting su domain
 * permissions, restoring old rules on uninstall) is disabled on this tree.
 * Root, sucompat, module mounting and the rest of KernelSU still work.
 */

#include <linux/kernel.h>
#include <linux/version.h>

#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)
#error "patches/rules.c is a stub; do not use it on 5.10+ kernels"
#endif

int apply_kernelsu_rules(void)
{
	return 0;
}

int revert_kernelsu_rules(void)
{
	return 0;
}

void ksu_selinux_hide(void)
{
}

void ksu_selinux_restore(void)
{
}
