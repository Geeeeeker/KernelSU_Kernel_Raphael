#!/usr/bin/env bash
# User-specific pre-build fixes and driver additions.
# Run before build.sh (needs the kernel tree already checked out).

set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must be set}
cd "$KERNEL_DIR"

# --------------------------------------------------- fair.c: se_update_runnable ---
group "Fixing fair.c se_update_runnable"
FAIR=sched/fair.c
if [ -f "$FAIR" ]; then
	before=$(grep -c 'se_update_runnable(se);' "$FAIR" || true)
	if [ "$before" -gt 0 ]; then
		# 保留缩进，行首加 "// "，比 /s/^/\/\// 更干净
		sed -i 's|^\([[:space:]]*\)se_update_runnable(se);|\1// se_update_runnable(se);|' "$FAIR"
		after=$(grep -c '^[[:space:]]*// se_update_runnable(se);' "$FAIR" || true)
		ok "commented ${after}/${before} se_update_runnable call(s) in ${FAIR}"
	else
		info "no se_update_runnable call found in ${FAIR}; nothing to do"
	fi
else
	warn "${FAIR} not found; skipping"
fi
endgroup

# --------------------------------------------------- rtl8188eus WiFi driver ---
group "Adding rtl8188eus WiFi driver"
RTL_REPO=https://github.com/Geeeeeker/android_kernel_xiaomi_sdm845.git
RTL_BRANCH=master

if [ -d drivers/rtl8188eus ]; then
	info "drivers/rtl8188eus already exists; skipping clone"
else
	rm -rf rtl8188eus-repo
	git clone --depth=1 --branch "$RTL_BRANCH" "$RTL_REPO" rtl8188eus-repo
	if [ -d rtl8188eus-repo/drivers/rtl8188eus ]; then
		cp -r rtl8188eus-repo/drivers/rtl8188eus drivers/
		grep -q 'rtl8188eus' drivers/Makefile || \
			echo 'obj-$(CONFIG_RTL8188EU) += rtl8188eus/' >> drivers/Makefile
		grep -q 'rtl8188eus/Kconfig' drivers/Kconfig || \
			echo 'source "drivers/rtl8188eus/Kconfig"' >> drivers/Kconfig
		ok "rtl8188eus driver added"
	else
		rm -rf rtl8188eus-repo
		die "rtl8188eus directory not found in ${RTL_REPO}"
	fi
	rm -rf rtl8188eus-repo
fi
endgroup