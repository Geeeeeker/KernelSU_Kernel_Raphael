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

# This tree's defconfig is known and fixed; no searching required.
KERNEL_DEFCONFIG_REL="arch/arm64/configs/raphael_defconfig"

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

ksu_registry() {
	case "$1" in
	kernelsu)
		echo "https://github.com/tiann/KernelSU|main|KernelSU||v0.9.5|-|KernelSU" ;;
	kernelsu-next)
		echo "https://github.com/KernelSU-Next/KernelSU-Next|dev|KernelSU-Next|dev|legacy|-|KernelSU-Next" ;;
	sukisu-ultra)
		echo "https://github.com/SukiSU-Ultra/SukiSU-Ultra|main|KernelSU|main|builtin|builtin|SukiSU-Ultra" ;;
	resukisu)
		# SUSFS is NOT bundled. Kernel-side patch applied by
		# apply_resukisu_susfs() below. The KernelSU-side 10_ patch is
		# deliberately skipped: it targets the old flat KSU layout.
		echo "https://github.com/ReSukiSU/ReSukiSU|main|KernelSU|main|main|kernel-patch|ReSukiSU" ;;
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

	if [ "$variant" = "resukisu" ] && [ "$susfs_refs" = "kernel-patch" ]; then
		apply_resukisu_susfs "$KERNEL_DIR" "$kver"
	fi

	summary "| KernelSU variant | \`${name}\` |"
	summary "| KernelSU ref | \`${ref:-latest tag}\` -> \`${version_label}\` |"

	endgroup
}

# --------------------------------------------------- ReSukiSU SUSFS patch ---

apply_resukisu_susfs() {
	local kernel_dir=$1 kver=$2

	group "Applying SUSFS kernel patches for ReSukiSU (kernel ${kver})"

	local SUSFS_REPO=${SUSFS_REPO:-"https://github.com/simonpunk/susfs4ksu.git"}
	local SUSFS_REF=${SUSFS_REF:-"1.4.2-kernel-5.4"}

	local susfs_tmp
	susfs_tmp=$(mktemp -d)

	info "cloning SUSFS from ${SUSFS_REPO} (ref ${SUSFS_REF})"
	if ! git clone --depth=1 --branch "$SUSFS_REF" "$SUSFS_REPO" "$susfs_tmp" >/dev/null 2>&1; then
		rm -rf "$susfs_tmp"
		die "failed to clone ${SUSFS_REPO} at ref '${SUSFS_REF}'"
	fi
	ok "SUSFS source cloned"

	local copied=0
	local f src dst
	for f in fs/susfs.c fs/sus_su.c include/linux/susfs.h include/linux/sus_su.h include/linux/susfs_def.h; do
		src="${susfs_tmp}/kernel_patches/${f}"
		dst="${kernel_dir}/${f}"
		if [ -f "$src" ]; then
			mkdir -p "$(dirname "$dst")"
			cp "$src" "$dst"
			copied=$((copied+1))
		fi
	done
	[ "$copied" -ge 2 ] || { rm -rf "$susfs_tmp"; die "no SUSFS source files found under ${susfs_tmp}/kernel_patches"; }
	ok "copied ${copied} SUSFS source files into kernel tree"

	local patch="${susfs_tmp}/kernel_patches/50_add_susfs_in_kernel-5.4.patch"
	[ -f "$patch" ] || { rm -rf "$susfs_tmp"; die "kernel-side patch missing: $patch"; }

	info "applying 50_add_susfs_in_kernel-5.4.patch"
	local patch_log="${kernel_dir}/.susfs_patch.log"
	if ! (cd "$kernel_dir" && patch -p1 --forward < "$patch" > "$patch_log" 2>&1); then
		warn "50_add_susfs_in_kernel-5.4.patch did not apply cleanly"
		grep -nE 'FAILED|Hunk|Reversed|already' "$patch_log" | head -20 || true
		rm -rf "$susfs_tmp"
		die "SUSFS kernel patch failed; see ${patch_log}"
	fi
	ok "50_add_susfs_in_kernel-5.4.patch applied"
		# --- 手动补充 SUSFS/ReSukiSU 缺失的 setresuid 钩子 ---
	local sys_c="${kernel_dir}/kernel/sys.c"
	if [ -f "$sys_c" ] && ! grep -q 'ksu_handle_setresuid' "$sys_c"; then
		warn "setresuid hook missing, attempting to inject..."
		python3 - "$sys_c" <<'PY'
import sys, re
path = sys.argv[1]
s = open(path).read()

# 匹配 setresuid 函数定义
pat = re.compile(r'(SYSCALL_DEFINE3\(setresuid,\s*uid_t,\s*ruid,\s*uid_t,\s*euid,\s*uid_t,\s*suid\)\s*\{)', re.S)
m = pat.search(s)
if not m:
    sys.exit('setresuid syscall definition not found')

# 在函数开始处插入钩子调用
hook = '''
#ifdef CONFIG_KSU
	{
		extern int ksu_handle_setresuid(uid_t old_uid, uid_t new_uid);
		ksu_handle_setresuid(ruid, euid);
	}
#endif
'''
s = s[:m.end()] + hook + s[m.end():]
open(path, 'w').write(s)
print("Injected ksu_handle_setresuid hook into kernel/sys.c")
PY
		ok "setresuid hook injected"
	else
		info "setresuid hook already present or kernel/sys.c not found"
	fi
	rm -f "$patch_log"

	info "skipping 10_enable_susfs_for_ksu.patch (obsolete for modern KSU forks)"

	# Fixed defconfig path for this tree.
	local defconfig="${kernel_dir}/${KERNEL_DEFCONFIG_REL}"
	if [ ! -f "$defconfig" ]; then
		rm -rf "$susfs_tmp"
		die "defconfig not found at ${defconfig}"
	fi
	ok "using defconfig: ${defconfig}"

	if ! grep -q 'config KSU_SUSFS' "${kernel_dir}/fs/Kconfig"; then
		warn "fs/Kconfig missing KSU_SUSFS entries; inserting minimal block"
		python3 - "$kernel_dir/fs/Kconfig" <<'PY'
import sys
path = sys.argv[1]
s = open(path).read()
if 'config KSU_SUSFS' in s:
    sys.exit(0)
marker = 'menu "File systems"'
idx = s.find(marker)
if idx < 0:
    sys.exit('menu "File systems" not found in fs/Kconfig')
insert_at = s.find('\n', idx) + 1
block = '''
config KSU_SUSFS
\tbool "KernelSU SUSFS support"
\tdefault y
\thelp
\t  SUSFS hides mounts, paths and kstat from root detection.

config KSU_SUSFS_SUS_PATH
\tbool "SUSFS: hide suspicious paths"
\tdepends on KSU_SUSFS
\tdefault y

config KSU_SUSFS_SUS_MOUNT
\tbool "SUSFS: hide suspicious mounts"
\tdepends on KSU_SUSFS
\tdefault y

config KSU_SUSFS_SUS_KSTAT
\tbool "SUSFS: fake kstat"
\tdepends on KSU_SUSFS
\tdefault y

config KSU_SUSFS_SPOOF_UNAME
\tbool "SUSFS: spoof uname"
\tdepends on KSU_SUSFS
\tdefault y

config KSU_SUSFS_ENABLE_LOG
\tbool "SUSFS: enable logging"
\tdepends on KSU_SUSFS
\tdefault n

config KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS
\tbool "SUSFS: hide KSU/SUSFS symbols"
\tdepends on KSU_SUSFS
\tdefault y

config KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
\tbool "SUSFS: spoof cmdline"
\tdepends on KSU_SUSFS
\tdefault y

config KSU_SUSFS_OPEN_REDIRECT
\tbool "SUSFS: open redirect"
\tdepends on KSU_SUSFS
\tdefault y
'''
open(path, 'w').write(s[:insert_at] + block + s[insert_at:])
PY
		ok "inserted KSU_SUSFS Kconfig block into fs/Kconfig"
	fi

	kconf_enable "$defconfig" CONFIG_KSU_SUSFS
	ok "enabled CONFIG_KSU_SUSFS in ${defconfig}"

	rm -rf "$susfs_tmp"
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

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	ksu_install "${KSU_VARIANT:-none}" "${KSU_REF:-}"
fi
