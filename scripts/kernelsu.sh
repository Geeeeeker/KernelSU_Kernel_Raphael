#!/usr/bin/env bash
# Install a KernelSU variant into the kernel tree.
#
# Every variant ships a near-identical kernel/setup.sh that clones itself next
# to the kernel tree and symlinks drivers/kernelsu at it. They differ in three
# ways that matter, all of which are encoded in the registry below:
#
#   * the directory the clone lands in (KernelSU vs KernelSU-Next),
#   * what "no argument" means -- most check out the latest tag, ReSukiSU
#     checks out main,
#   * which ref carries non-GKI support and which carries SUSFS.
#
# The critical safety property: every variant's setup.sh ends its checkout with
#     git checkout "$1" ... || echo "[-] Checkout default branch"
# so an invalid ref does NOT fail the script -- it silently leaves the tree on
# the default branch. A build asking for SukiSU's SUSFS-capable 'builtin'
# branch and typing 'susfs-main' (which does not exist) would quietly produce a
# kernel with no SUSFS at all. So we validate the ref before calling setup.sh
# and verify the checkout afterwards.

set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must point at the kernel source tree}

# ------------------------------------------------------------- registry -----
#
# Fields, '|'-separated:
#   1 repo URL
#   2 ref the setup.sh script itself is fetched from
#   3 directory setup.sh clones into, relative to the kernel tree
#   4 default ref for modern (>= 5.10) kernels; empty means "let setup.sh pick"
#   5 default ref for legacy (< 5.10) kernels
#   6 refs that already contain SUSFS support (space separated; '-' for none)
#   7 human-readable name
#
# Verified against each repo's live branch/tag list on 2026-07-27.

ksu_registry() {
	case "$1" in
	kernelsu)
		echo "https://github.com/tiann/KernelSU|main|KernelSU||v0.9.5|-|KernelSU" ;;
	kernelsu-next)
		echo "https://github.com/KernelSU-Next/KernelSU-Next|dev|KernelSU-Next|dev|legacy|-|KernelSU-Next" ;;
	sukisu-ultra)
		# 'main' is the modular v4 tree (KPM, no SUSFS); 'builtin' is the
		# non-GKI/source-integrated tree and is the only one with SUSFS Kconfig.
		echo "https://github.com/SukiSU-Ultra/SukiSU-Ultra|main|KernelSU|main|builtin|builtin|SukiSU-Ultra" ;;
	resukisu)
		# Re-fork of SukiSU-Ultra aimed at legacy/non-GKI kernels.
		# SUSFS is NOT bundled; it must be applied via the inline-hook patch
		# script from the SUSFS ecosystem (see apply_resukisu_susfs below).
		echo "https://github.com/ReSukiSU/ReSukiSU|main|KernelSU|main|main|inline-hook|ReSukiSU" ;;
	rsuntk)
		echo "https://github.com/rsuntk/KernelSU|main|KernelSU|main|main|susfs-rksu-master|RKSU (rsuntk)" ;;
	backslashxx)
		echo "https://github.com/backslashxx/KernelSU|master|KernelSU|master|master|-|backslashxx KernelSU" ;;
	*)
		die "unknown KSU_VARIANT '$1'" ;;
	esac
}

ksu_field() { ksu_registry "$1" | cut -d'|' -f"$2"; }

ksu_default_is_branch() { [ "$1" = "resukisu" ]; }

# ---------------------------------------------------------------- install ---

ksu_install() {
	local variant=$1 requested_ref=${2-}

	[ "$variant" = "none" ] && { info "KernelSU integration disabled"; return 0; }

	local repo setup_ref dir modern_ref legacy_ref susfs_refs name
	IFS='|' read -r repo setup_ref dir modern_ref legacy_ref susfs_refs name <<<"$(ksu_registry "$variant")"

	group "Installing ${name}"
	info "repository: ${repo}"

	# Decide which ref to check out.
	local kver ref=$requested_ref
	kver=$(kernel_version "$KERNEL_DIR" || echo "0.0")
	if [ -z "$ref" ]; then
		if ver_ge "$kver" "5.10"; then
			ref=$modern_ref
		else
			ref=$legacy_ref
			[ -n "$ref" ] && info "kernel ${kver} is pre-GKI; defaulting to ref '${ref}'"
		fi
	fi

	# Validate before handing the ref to setup.sh, which would swallow a typo.
	if [ -n "$ref" ]; then
		info "validating ref '${ref}' exists in ${repo}"
		ref_exists "$repo" "$ref" \
			|| die "ref '${ref}' does not exist in ${repo}.
       setup.sh would silently fall back to the default branch and you would
       get a kernel without the feature you asked for.
       Available branches: $(git ls-remote --heads "$repo" 2>/dev/null | awk '{print $2}' | sed 's@refs/heads/@@' | grep -v dependabot | tr '\n' ' ')"
		ok "ref '${ref}' exists"
	else
		warn "no ref pinned; setup.sh will pick the latest tag. Set KSU_REF for reproducible builds."
	fi

	if [ -z "$requested_ref" ] && ksu_default_is_branch "$variant"; then
		warn "${name}'s setup.sh defaults to the moving 'main' branch rather than a tag."
		warn "Pin KSU_REF (e.g. a tag) if you need reproducible builds."
	fi

	# Run the variant's own installer.
	local setup_url="https://raw.githubusercontent.com/${repo#https://github.com/}/${setup_ref}/kernel/setup.sh"
	info "running ${setup_url}"
	(
		cd "$KERNEL_DIR"
		if [ -n "$ref" ]; then
			fetch_stdout "$setup_url" | bash -s "$ref"
		else
			fetch_stdout "$setup_url" | bash
		fi
	) || die "${name} setup.sh failed"

	# --- verify the installer actually did what it claims ------------------
	local ksu_dir="${KERNEL_DIR}/${dir}"
	[ -d "$ksu_dir" ] || die "${name} setup.sh finished but ${dir}/ is missing"

	local link="${KERNEL_DIR}/drivers/kernelsu"
	[ -e "$link" ] || die "drivers/kernelsu symlink was not created"

	local driver_makefile="${KERNEL_DIR}/drivers/Makefile"
	if ! grep -qE '^[[:space:]]*obj-\$\(CONFIG_KSU\)[[:space:]]*\+=[[:space:]]*kernelsu/?[[:space:]]*$' "$driver_makefile"; then
		if grep -qE '^[[:space:]]*obj-\$\(CONFIG_[A-Z0-9_]+\)[[:space:]]*\+=[[:space:]]*kernelsu/?[[:space:]]*$' "$driver_makefile"; then
			sed -i -E 's@^[[:space:]]*obj-\$\(CONFIG_[A-Z0-9_]+\)[[:space:]]*\+=[[:space:]]*kernelsu/?[[:space:]]*$@obj-$(CONFIG_KSU) += kernelsu/@' "$driver_makefile"
			warn "normalized stale drivers/Makefile KernelSU guard to CONFIG_KSU"
		else
			printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >>"$driver_makefile"
			warn "added missing CONFIG_KSU rule to drivers/Makefile"
		fi
	fi

	grep -qE '^[[:space:]]*obj-\$\(CONFIG_KSU\)[[:space:]]*\+=[[:space:]]*kernelsu/?[[:space:]]*$' "$driver_makefile" \
		|| die "drivers/Makefile was not wired to CONFIG_KSU for kernelsu"
	grep -q 'drivers/kernelsu/Kconfig' "${KERNEL_DIR}/drivers/Kconfig" \
		|| die "drivers/Kconfig was not wired up for kernelsu"

	# Confirm we landed on the ref we asked for, catching the silent fallback.
	local head_desc head_sha
	head_sha=$(git -C "$ksu_dir" rev-parse --short HEAD)
	head_desc=$(git -C "$ksu_dir" describe --tags --always 2>/dev/null || echo "$head_sha")
	if [ -n "$ref" ]; then
		local want
		want=$(git -C "$ksu_dir" rev-parse --verify --quiet "$ref^{commit}" 2>/dev/null || true)
		if [ -n "$want" ] && [ "$want" != "$(git -C "$ksu_dir" rev-parse HEAD)" ]; then
			die "${name} is checked out at ${head_desc}, not the requested ref '${ref}'"
		fi
	fi
	ok "${name} installed at ${head_desc} (${head_sha})"

	# --- publish facts the later steps need --------------------------------
	local count version_label
	count=$(git -C "$ksu_dir" rev-list --count HEAD 2>/dev/null || echo 0)
	if git -C "$ksu_dir" describe --exact-match --tags >/dev/null 2>&1; then
		version_label=$(git -C "$ksu_dir" describe --exact-match --tags)
	else
		version_label="${ref:-HEAD}-${head_sha}"
	fi

	export_env KSU_DIR "$dir"
	export_env KSU_NAME "$name"
	export_env KSU_REF_RESOLVED "${ref:-<latest-tag>}"
	export_env KSU_VERSION_LABEL "$version_label"
	export_env KSU_COMMIT_COUNT "$count"
	export_env KSU_SUSFS_BUNDLED_REFS "$susfs_refs"
	export_env UPLOADNAME "-${name// /_}_${version_label}"

	ksu_resolve_hook_mode "${KSU_HOOK_MODE:-auto}" "$kver"

	# --- SUSFS for ReSukiSU ------------------------------------------------
	# ReSukiSU does not bundle SUSFS. For non-GKI kernels the supported path
	# is the susfs_inline_hook patch script, which replaces the legacy
	# 10_enable_susfs_for_ksu.patch entirely.
	if [ "$variant" = "resukisu" ] && [ "$susfs_refs" = "inline-hook" ]; then
		apply_resukisu_susfs "$KERNEL_DIR" "$kver"
	fi

	summary "| KernelSU variant | \`${name}\` |"
	summary "| KernelSU ref | \`${ref:-latest tag}\` -> \`${version_label}\` |"

	endgroup
}

# --------------------------------------------------- ReSukiSU SUSFS patch ---
#
# The SUSFS project explicitly states that non-GKI kernels need the inline-hook
# patches rather than the old flat-layout KernelSU patches. The script below
# fetches a community-maintained susfs_inline_hook_patches.sh and runs it from
# the kernel root. Adjust SUSFS_INLINE_HOOK_URL if the upstream location moves.
apply_resukisu_susfs() {
	local kernel_dir=$1 kver=$2

	# Community-maintained inline-hook patch script for non-GKI SUSFS.
	# This is the path referenced by users who have ReSukiSU + SUSFS working
	# on 5.4 kernels.
	local SUSFS_INLINE_HOOK_URL="https://raw.githubusercontent.com/JackA1ltman/NonGKI_Kernel_Build_2nd/mainline/Patches/susfs_inline_hook_patches.sh"
	local patch_script="${kernel_dir}/susfs_inline_hook_patches.sh"

	group "Applying SUSFS inline-hook patches for ReSukiSU (kernel ${kver})"

	info "fetching ${SUSFS_INLINE_HOOK_URL}"
	if ! fetch_stdout "$SUSFS_INLINE_HOOK_URL" > "$patch_script"; then
		rm -f "$patch_script"
		die "failed to fetch SUSFS inline-hook patch script from ${SUSFS_INLINE_HOOK_URL}"
	fi
	chmod +x "$patch_script"

	info "running susfs_inline_hook_patches.sh from ${kernel_dir}"
	(
		cd "$kernel_dir"
		bash ./susfs_inline_hook_patches.sh
	) || die "SUSFS inline-hook patch script failed"

	# The inline-hook script copies susfs source files and applies the kernel
	# side hunks. Confirm the key files landed.
	for f in fs/susfs.c include/linux/susfs.h; do
		[ -f "${kernel_dir}/${f}" ] || die "SUSFS file missing after inline-hook patch: ${f}"
	done
	ok "SUSFS inline-hook patches applied"

	# Ensure the kernel config declares SUSFS support.
	local defconfig
	defconfig=$(kernel_defconfig "$kernel_dir") || die "could not locate kernel defconfig"
	kconf_enable "$defconfig" CONFIG_KSU_SUSFS
	ok "enabled CONFIG_KSU_SUSFS in ${defconfig}"

	# Clean up the downloaded script; it is not part of the kernel tree.
	rm -f "$patch_script"

	endgroup
}

# ------------------------------------------------------------ hook config ---

ksu_resolve_hook_mode() {
	local mode=${1:-auto} kver=$2
	if [ "$mode" = "auto" ]; then
		if ver_ge "$kver" "5.10"; then
			mode="kprobes"
		else
			mode="manual"
		fi
		info "hook mode 'auto' resolved to '${mode}' for kernel ${kver}"
	fi
	export_env KSU_HOOK_MODE_RESOLVED "$mode"
}

ksu_hook_configs() {
	local variant=$1 mode=$2 defconfig=$3 kver=$4

	if [ "$mode" = "auto" ]; then
		[ -n "${KSU_HOOK_MODE_RESOLVED:-}" ] || ksu_resolve_hook_mode "$mode" "$kver"
		mode=$KSU_HOOK_MODE_RESOLVED
	fi

	case "$mode" in
	none) return 0 ;;
	kprobes)
		kconf_enable "$defconfig" CONFIG_MODULES
		kconf_enable "$defconfig" CONFIG_KPROBES
		kconf_enable "$defconfig" CONFIG_HAVE_KPROBES
		kconf_enable "$defconfig" CONFIG_KPROBE_EVENTS
		kconf_enable "$defconfig" CONFIG_KRETPROBES
		[ "$variant" = "kernelsu-next" ] && kconf_enable "$defconfig" CONFIG_KSU_KPROBES_HOOK
		;;
	manual)
		case "$variant" in
			kernelsu-next)  kconf_enable "$defconfig" CONFIG_KSU_MANUAL_HOOK ;;
			sukisu-ultra)  kconf_enable "$defconfig" CONFIG_KSU_MANUAL_HOOK ;;
			resukisu)
				kconf_set_many "$defconfig" \
					CONFIG_KSU_MANUAL_HOOK=y CONFIG_DEBUG_KERNEL=y \
					CONFIG_KALLSYMS=y CONFIG_KALLSYMS_ALL=y ;;
			*) : ;;
		esac
		;;
	tracepoint)
		[ "$variant" = "resukisu" ] || [ "$variant" = "sukisu-ultra" ] \
			|| warn "hook mode 'tracepoint' is only declared by ReSukiSU/SukiSU-Ultra; ignoring for ${variant}"
		kconf_enable "$defconfig" CONFIG_KSU_TRACEPOINT_HOOK
		;;
	syscall)
		kconf_enable "$defconfig" CONFIG_KSU_SYSCALL_HOOK
		;;
	esac
}

# Only run the installer when sourced as a script entry point.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	ksu_install "${KSU_VARIANT:-none}" "${KSU_REF:-}"
fi
