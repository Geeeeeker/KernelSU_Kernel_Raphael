#!/usr/bin/env bash
# Prepare the defconfig and compile the kernel.

set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=scripts/kernelsu.sh
. "$(dirname "${BASH_SOURCE[0]}")/kernelsu.sh"
# shellcheck source=scripts/patches.sh
. "$(dirname "${BASH_SOURCE[0]}")/patches.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must be set}
WORKSPACE=${WORKSPACE:-$(cd "${KERNEL_DIR}/.." && pwd)}
ARCH=${ARCH:-arm64}
OUT="${KERNEL_DIR}/out"

DEFCONFIG_PATH="${KERNEL_DIR}/arch/${ARCH}/configs/${KERNEL_CONFIG}"

# ------------------------------------------------------------- defconfig ---

prepare_defconfig() {
	group "Preparing defconfig"
	[ -f "$DEFCONFIG_PATH" ] \
		|| die "defconfig not found: arch/${ARCH}/configs/${KERNEL_CONFIG}
       Available: $(ls "${KERNEL_DIR}/arch/${ARCH}/configs/" | head -20 | tr '\n' ' ')"

	cp "$DEFCONFIG_PATH" "${WORKSPACE}/defconfig.orig"

	local kver
	kver=$(kernel_version "$KERNEL_DIR" || echo "0.0")

	if [ "${KSU_VARIANT:-none}" != "none" ]; then
		kconf_enable "$DEFCONFIG_PATH" CONFIG_KSU
		ksu_hook_configs "${KSU_VARIANT}" "${KSU_HOOK_MODE:-auto}" "$DEFCONFIG_PATH" "$kver"

		if is_true "${ENABLE_SUSFS:-false}"; then
			susfs_defconfig "$DEFCONFIG_PATH"
		fi

		if is_true "${ENABLE_KPM:-false}"; then
			# patch_linux resolves symbols at runtime, so kallsyms must be complete.
			kconf_set_many "$DEFCONFIG_PATH" \
				CONFIG_KPM=y CONFIG_KALLSYMS=y CONFIG_KALLSYMS_ALL=y
		fi
	fi

	# Overlayfs backs KernelSU's module mounts and system-partition writes.
	is_true "${ADD_OVERLAYFS_CONFIG:-false}" && kconf_enable "$DEFCONFIG_PATH" CONFIG_OVERLAY_FS

	# Kept as a standalone switch for kernels that need kprobes for their own
	# reasons, independent of the hook mode.
	if is_true "${ADD_KPROBES_CONFIG:-false}"; then
		kconf_set_many "$DEFCONFIG_PATH" \
			CONFIG_MODULES=y CONFIG_KPROBES=y CONFIG_HAVE_KPROBES=y CONFIG_KPROBE_EVENTS=y
	fi

	if is_true "${DISABLE_LTO:-false}"; then
		kconf_set_many "$DEFCONFIG_PATH" \
			CONFIG_LTO=n CONFIG_LTO_CLANG=n CONFIG_LTO_CLANG_FULL=n \
			CONFIG_LTO_CLANG_THIN=n CONFIG_THINLTO=n CONFIG_LTO_NONE=y
	fi

	is_true "${DISABLE_CC_WERROR:-false}" && kconf_disable "$DEFCONFIG_PATH" CONFIG_CC_WERROR

	# Free-form extras: one CONFIG_x=y per line, or space separated.
	if [ -n "${EXTRA_DEFCONFIG:-}" ]; then
		local kv
		# shellcheck disable=SC2086
		for kv in $(printf '%s' "$EXTRA_DEFCONFIG" | tr '\n' ' '); do
			[ -n "$kv" ] || continue
			case "$kv" in
				*=*) kconf_set "$DEFCONFIG_PATH" "${kv%%=*}" "${kv#*=}" ;;
				*)   warn "ignoring malformed EXTRA_DEFCONFIG entry '${kv}' (want CONFIG_X=y)" ;;
			esac
		done
	fi

	# A stable LOCALVERSION keeps artifact names predictable. Without this the
	# tree appends "-dirty" as soon as any patch above touches a tracked file.
	if [ -n "${KERNEL_NAME:-}" ]; then
		kconf_set "$DEFCONFIG_PATH" CONFIG_LOCALVERSION "\"-${KERNEL_NAME}\""
		if [ -f "${KERNEL_DIR}/scripts/setlocalversion" ]; then
			sed -i 's/echo "\$res"/echo "\$res"/; s/-dirty//g' "${KERNEL_DIR}/scripts/setlocalversion"
		fi
	fi

	info "defconfig changes:"
	diff -u "${WORKSPACE}/defconfig.orig" "$DEFCONFIG_PATH" | sed -n '4,$p' | sed 's/^/    /' || true
	endgroup
}

# ----------------------------------------------------------------- build ---

make_args() {
	printf '%s' "O=out ARCH=${ARCH}"
	[ -n "${CUSTOM_CMDS:-}" ] && printf ' %s' "$CUSTOM_CMDS"
	[ -n "${EXTRA_CMDS:-}"  ] && printf ' %s' "$EXTRA_CMDS"
	[ -n "${GCC_64:-}"      ] && printf ' %s' "$GCC_64"
	[ -n "${GCC_32:-}"      ] && printf ' %s' "$GCC_32"
	if is_true "${USE_LLVM:-false}"; then
		printf ' LLVM=1 LLVM_IAS=1'
		[ -n "${GCC_64:-}" ] || printf ' CROSS_COMPILE=aarch64-linux-gnu-'
	fi
}

build_kernel() {
	group "Building kernel"
	export PATH="${CLANG_PATH:-}:${PATH}"
	export KBUILD_BUILD_HOST=${KBUILD_BUILD_HOST:-Github-Action}
	export KBUILD_BUILD_USER=${KBUILD_BUILD_USER:-kernelsu-action}

	# DISABLE_LTO is this action's boolean configuration switch, but several
	# Android kernel trees use the same Make variable for compiler flags (for
	# example, "-fno-lto").  Leaving our value in the environment makes a
	# non-LTO build invoke `clang ... false ...`, treating "false" as an input
	# file.  prepare_defconfig() has already consumed the action setting, so let
	# Kbuild own the name from this point on.
	unset DISABLE_LTO

	# Custom manager signature, when the user builds their own manager APK.
	if [ -n "${KSU_EXPECTED_SIZE:-}" ] && [ -n "${KSU_EXPECTED_HASH:-}" ]; then
		export KSU_EXPECTED_SIZE KSU_EXPECTED_HASH
		info "using custom manager signature (size=${KSU_EXPECTED_SIZE})"
	fi

	local cc="clang" args
	args=$(make_args)
	if is_true "${ENABLE_CCACHE:-true}" && command -v ccache >/dev/null; then
		cc="ccache clang"
		export CCACHE_DIR="${CCACHE_DIR:-${WORKSPACE}/.ccache}"
		info "ccache enabled (dir: ${CCACHE_DIR})"
	fi

	cd "$KERNEL_DIR"
	if is_true "${ENABLE_STOCKCONFIG:-false}"; then
		local stockconfig_found=false
		read -ra flags <<< "${STOCKCONFIG_FLAGS}"
		local stockconfig kernel_stockconfig
		for flag in "${flags[@]}"; do
			stockconfig="${DEVICE}${flag}_defconfig"
			kernel_stockconfig="arch/${ARCH}/configs/${stockconfig}"
			if [ -f "${kernel_stockconfig}" ]; then
				info "Found stockconfig included in kernel tree: ${stockconfig}, skipping stockconfig generation"
				stockconfig_found=true
				break
			fi
		done
		if ! is_true "${stockconfig_found}"; then
			info "make ${args} ${stockconfig}"
			git show HEAD:"arch/${ARCH}/configs/${KERNEL_CONFIG}" > "${kernel_stockconfig}"
			# shellcheck disable=SC2086
			make -j"$(nproc --all)" CC=clang $args "${stockconfig}" \
				|| die "stockconfig generation failed"
			mv -v "${OUT}/.config" "${kernel_stockconfig}"
		fi
		info "Use ${stockconfig} as /proc/config.gz to bypass VINTF check"
		sed -i "s|^\(\$(obj)/config_data:\) \$(KCONFIG_CONFIG) FORCE|\1 ${kernel_stockconfig} FORCE|" "${STOCKCONFIG_MAKEFILE}"
	fi
	info "make ${args} ${KERNEL_CONFIG}"
	# shellcheck disable=SC2086
	make -j"$(nproc --all)" CC=clang $args "${KERNEL_CONFIG}" \
		|| die "defconfig generation failed"

	# ------------------------------------------------------------------
	# 关键改动 1：显式指定编译目标，避免默认 `all` 目标连带 `dtbs`。
	#
	# ARM64 的 `all` 会连带 `dtbs`，而 `dtbs` 又会去编译 Makefile.dtbo
	# 里所有 dtbo-y 条目，包括和当前内核树不兼容的 andromeda-*.dtbo，
	# 从而在 andromeda-pinctrl.dtsi 处报语法错误。
	#
	# 这里只编译内核镜像（KERNEL_IMAGE_NAME，默认 Image.gz）和
	# （若 CONFIG_MODULES=y）模块，完全不进入 dts 目录。
	# ------------------------------------------------------------------
	local build_targets="${KERNEL_IMAGE_NAME}"
	if grep -q '^CONFIG_MODULES=y' "${OUT}/.config" 2>/dev/null; then
		build_targets="${build_targets} modules"
	fi

	info "make ${args} ${build_targets}"
	# shellcheck disable=SC2086
	make -j"$(nproc --all)" CC="$cc" $args ${build_targets} \
		|| die "kernel build failed"

	# 关键改动 2：编译刚结束就补 Image.gz。
	# 内核未开启 CONFIG_KERNEL_GZIP 时只产出 Image，而 package.sh /
	# anykernel.sh 常把 Image.gz 路径写死，这里立即压一份，保证后续
	# check_output 和 package.sh 都能找到文件。
	local boot="${OUT}/arch/${ARCH}/boot"
	if [ -f "${boot}/Image" ] && [ ! -f "${boot}/Image.gz" ]; then
		info "Image.gz not produced by kernel; generating from Image"
		if gzip -9 -k -f "${boot}/Image"; then
			ok "generated ${boot}/Image.gz"
			export_env KERNEL_IMAGE_NAME Image.gz
		else
			warn "failed to gzip Image -> Image.gz"
		fi
	fi

	# 关键改动 3：编译完成后创建设备树空文档，让打包流程继续。
	# 这里只在 NEED_DTBO=true 且内核确实没产出 dtbo.img 时创建 0 字节
	# 占位，并打上 DTBO_IS_PLACEHOLDER 标记，避免空文件被误刷。
	if is_true "${NEED_DTBO:-false}"; then
		if [ ! -f "${boot}/dtbo.img" ]; then
			warn "NEED_DTBO=true but ${boot}/dtbo.img was not produced"
			warn "creating 0-byte placeholder so packaging can continue"
			warn "DO NOT flash this placeholder -- keep the dtbo already on your device"
			: > "${boot}/dtbo.img"
			export_env DTBO_IS_PLACEHOLDER true
		else
			export_env DTBO_IS_PLACEHOLDER false
		fi
	fi

	endgroup
}

# --------------------------------------------------------------- verify ---

check_output() {
	group "Checking build output"
	local boot="${OUT}/arch/${ARCH}/boot"

	# 无条件兜底：只要有 Image 没有 Image.gz，就压一份。
	# 不依赖 KERNEL_IMAGE_NAME，避免回退/export_env 时序问题。
	if [ -f "${boot}/Image" ] && [ ! -f "${boot}/Image.gz" ]; then
		if gzip -9 -k -f "${boot}/Image"; then
			ok "generated ${boot}/Image.gz from Image"
		else
			warn "failed to gzip Image -> Image.gz"
		fi
	fi

	# 候选顺序：优先 Image.gz，其次 Image，最后 Image.gz-dtb。
	local candidates=("Image.gz" "Image" "Image.gz-dtb")
	local image="" candidate
	for candidate in "${candidates[@]}"; do
		if [ -f "${boot}/${candidate}" ]; then
			image="${boot}/${candidate}"
			KERNEL_IMAGE_NAME="${candidate}"
			export_env KERNEL_IMAGE_NAME "${candidate}"
			break
		fi
	done

	if [ -z "${image}" ]; then
		die "no kernel image found under ${boot}
       Tried: ${candidates[*]}
       Built files: $(ls "${boot}" 2>/dev/null | tr '\n' ' ')
       If 'Building kernel' produced nothing, check that build_kernel()
       actually ran: grep -n 'make -j' scripts/build.sh"
	fi

	ok "kernel image: ${KERNEL_IMAGE_NAME} ($(du -h "${image}" | cut -f1))"
	export_env CHECK_FILE_IS_OK true

	# ------------------------------------------------------------- dtbo ---
	# 缺 dtbo.img 时创建 0 字节占位，让打包流程继续；用 DTBO_IS_PLACEHOLDER
	# 标记，Upload / release 步骤据此跳过发布，避免空文件被刷入设备。
	if is_true "${NEED_DTBO:-false}"; then
		if [ ! -f "${boot}/dtbo.img" ]; then
			warn "NEED_DTBO=true but ${boot}/dtbo.img was not produced"
			warn "creating 0-byte placeholder so packaging can continue"
			warn "DO NOT flash this placeholder -- keep the dtbo already on your device"
			: > "${boot}/dtbo.img"
			export_env DTBO_IS_PLACEHOLDER true
		else
			export_env DTBO_IS_PLACEHOLDER false
		fi
		export_env CHECK_DTBO_IS_OK true
		ok "dtbo.img present ($(du -h "${boot}/dtbo.img" | cut -f1))"
	fi

	# KPM rewrites the image in place, so it has to happen after the build and
	# before packaging.
	if is_true "${ENABLE_KPM:-false}"; then
		kpm_patch_image "${image}"
	fi

	# Record the version string the kernel actually reports.
	if [ -f "${OUT}/include/generated/utsrelease.h" ]; then
		local rel
		rel=$(sed -nE 's/.*UTS_RELEASE[[:space:]]+"([^"]+)".*/\1/p' "${OUT}/include/generated/utsrelease.h")
		export_env KERNEL_RELEASE "${rel}"
		ok "kernel release: ${rel}"
		summary "| Kernel release | \`${rel}\` |"
	fi
	endgroup
}

# --------------------------------------------------------------- entry ---

# 兼容两种调用方式：直接执行 ./build.sh，或 bash /abs/path/scripts/build.sh。
# 原判断只认 BASH_SOURCE == $0，在某些 runner 上会因为路径形式不同而
# 整个 case 不执行，表现就是"什么都没做"。
if [ "${BASH_SOURCE[0]}" = "${0}" ] || [ "$(basename "${0}")" = "build.sh" ]; then
	case "${1:-all}" in
		defconfig) prepare_defconfig ;;
		compile)   build_kernel ;;
		check)     check_output ;;
		all)       prepare_defconfig; build_kernel; check_output ;;
		*) die "unknown build step '$1'" ;;
	esac
fi
