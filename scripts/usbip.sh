#!/usr/bin/env bash
# Build USB/IP kernel modules + userspace tools (arm64) and bundle them.
# Run after build.sh (needs out/.config and clang ready).

set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must be set}
WORKSPACE=${WORKSPACE:-$(cd "${KERNEL_DIR}/.." && pwd)}
ARCH=${ARCH:-arm64}
OUT="${KERNEL_DIR}/out"

# 打包产物放在 GITHUB_WORKSPACE 根，与 Upload artifact 的 path 对齐
ROOT=${GITHUB_WORKSPACE:-${WORKSPACE}}
USBIP_OUT=${USBIP_OUT:-${ROOT}/usbip-out}
BUNDLE=${BUNDLE:-${ROOT}/usbip-arm64-bundle.tar.gz}

# ------------------------------------------------------------ qemu setup ---
group "Installing QEMU user-mode support"
sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends qemu-user-static binfmt-support
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
endgroup

# ------------------------------------------------------- kernel modules ---
group "Building USB/IP kernel modules"
[ -f "${OUT}/.config" ] \
	|| die "kernel not configured: ${OUT}/.config missing (run build.sh first)"
[ -n "${CLANG_PATH:-}" ] && export PATH="${CLANG_PATH}:${PATH}"

make -C "${KERNEL_DIR}" -j"$(nproc)" \
	SHELL=/bin/bash \
	ARCH="${ARCH}" \
	LLVM=1 \
	LLVM_IAS=1 \
	O=out \
	CROSS_COMPILE=aarch64-linux-gnu- \
	LD=ld.lld \
	M=drivers/usb/usbip \
	modules || warn "USB/IP kernel modules build skipped or failed"

mkdir -p "${USBIP_OUT}/modules"
shopt -s nullglob
ko_files=("${OUT}/drivers/usb/usbip/"*.ko)
if [ "${#ko_files[@]}" -gt 0 ]; then
	cp "${ko_files[@]}" "${USBIP_OUT}/modules/"
	ok "copied ${#ko_files[@]} USB/IP module(s)"
else
	info "no USB/IP kernel modules generated (probably built-in)"
fi
shopt -u nullglob
endgroup

# ------------------------------------------------------ userspace tools ---
group "Building USB/IP userspace tools (arm64)"
mkdir -p "${USBIP_OUT}/bin" "${USBIP_OUT}/libs"

# KERNEL_DIR 相对 ROOT 的路径，用于 docker -w
kernel_rel="${KERNEL_DIR#"$ROOT"/}"
[ "${kernel_rel}" = "${KERNEL_DIR}" ] && kernel_rel="$(basename "${KERNEL_DIR}")"

docker run --rm --platform linux/arm64 \
	--memory=4g \
	-v "${ROOT}:/workspace" \
	-v "${USBIP_OUT}:/output" \
	-w "/workspace/${kernel_rel}" \
	arm64v8/ubuntu:22.04 \
	bash -c "$(cat <<'INNER'
set -e
export DEBIAN_FRONTEND=noninteractive
ulimit -s unlimited
apt update
apt install -y \
  build-essential autoconf libtool pkg-config libudev-dev libssl-dev \
  flex bison file patchelf
cd tools/usb/usbip
./autogen.sh
./configure CFLAGS="-Wno-error -Wno-error=stringop-truncation" --with-tcp-wrappers=no
make -j1
cp src/.libs/usbip /output/bin/
cp src/.libs/usbipd /output/bin/
cp libsrc/.libs/libusbip.so.0* /output/libs/
cd /output
BINARIES="bin/usbip bin/usbipd libs/libusbip.so.0*"
DEPS=""
for file in $BINARIES; do
  if [ -f "$file" ]; then
    needed=$(readelf -d "$file" | grep NEEDED | awk '{print $5}' | tr -d '[]' || true)
    for lib in $needed; do
      if [[ "$DEPS" != *"$lib"* ]]; then
        DEPS="$DEPS $lib"
      fi
    done
  fi
done
for lib in $(echo $DEPS | tr ' ' '\n' | sort -u); do
  libpath=$(ldconfig -p | grep "$lib (" | head -1 | awk '{print $NF}' || true)
  if [ -z "$libpath" ]; then
    libpath=$(find /lib /usr/lib -name "$lib" -type f 2>/dev/null | head -1 || true)
  fi
  if [ -n "$libpath" ]; then
    cp -P "$libpath" libs/ 2>/dev/null || cp "$libpath" libs/
    for reallib in $(find "$(dirname "$libpath")" -name "${lib%.so*}*" -type f 2>/dev/null); do
      cp -n "$reallib" libs/ 2>/dev/null || true
    done
  fi
done
ld_linux="/lib/ld-linux-aarch64.so.1"
if [ -f "$ld_linux" ]; then
  cp -P "$ld_linux" libs/
fi
INNER
)"
endgroup

# ------------------------------------------------------------- package ---
group "Packaging USB/IP bundle"
tar czf "${BUNDLE}" -C "${USBIP_OUT}" .
ok "bundle: ${BUNDLE} ($(du -h "${BUNDLE}" | cut -f1))"
endgroup