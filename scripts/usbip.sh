#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must be set}
ROOT=${GITHUB_WORKSPACE:-$(cd "${KERNEL_DIR}/.." && pwd)}
ARCH=${ARCH:-arm64}

# ========== 设置 QEMU 用户态支持 (用于 arm64 容器) ==========
sudo apt-get update
sudo apt-get install -y qemu-user-static binfmt-support
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes

# ========== 编译 USB/IP 内核模块（可选） ==========
cd "$KERNEL_DIR"
export SHELL=/bin/bash
export PATH="${CLANG_PATH:-}:${PATH}"
make -j"$(nproc)" \
  SHELL=/bin/bash \
  ARCH=arm64 \
  LLVM=1 \
  LLVM_IAS=1 \
  O=out \
  CROSS_COMPILE=aarch64-linux-gnu- \
  LD=ld.lld \
  M=drivers/usb/usbip \
  modules || echo "Warning: USB/IP modules build skipped or failed."

mkdir -p "$ROOT/usbip-out/modules"
if ls out/drivers/usb/usbip/*.ko 1> /dev/null 2>&1; then
    cp out/drivers/usb/usbip/*.ko "$ROOT/usbip-out/modules/"
else
    echo "No USB/IP kernel modules generated (probably built-in)."
fi

# ========== 编译 USB/IP 用户态工具 (Docker arm64 容器) ==========
mkdir -p "$ROOT/usbip-out/bin" "$ROOT/usbip-out/libs"
kernel_rel="${KERNEL_DIR#"$ROOT"/}"
[ "$kernel_rel" = "$KERNEL_DIR" ] && kernel_rel="$(basename "$KERNEL_DIR")"

docker run --rm --platform linux/arm64 \
  --memory=4g \
  -v "$ROOT:/workspace" \
  -v "$ROOT/usbip-out:/output" \
  -w "/workspace/$kernel_rel" \
  arm64v8/ubuntu:22.04 \
  bash -c "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    ulimit -s unlimited
    apt update
    apt install -y \
      build-essential \
      autoconf \
      libtool \
      pkg-config \
      libudev-dev \
      libssl-dev \
      flex \
      bison \
      file \
      patchelf
    cd tools/usb/usbip
    ./autogen.sh
    ./configure CFLAGS=\"-Wno-error -Wno-error=stringop-truncation\" --with-tcp-wrappers=no
    make -j1
    cp src/.libs/usbip /output/bin/
    cp src/.libs/usbipd /output/bin/
    cp libsrc/.libs/libusbip.so.0* /output/libs/
    cd /output
    BINARIES=\"bin/usbip bin/usbipd libs/libusbip.so.0*\"
    DEPS=\"\"
    for file in \$BINARIES; do
      if [ -f \"\$file\" ]; then
        needed=\$(readelf -d \"\$file\" | grep NEEDED | awk '{print \$5}' | tr -d '[]' || true)
        for lib in \$needed; do
          if [[ \"\$DEPS\" != *\"\$lib\"* ]]; then
            DEPS=\"\$DEPS \$lib\"
          fi
        done
      fi
    done
    for lib in \$(echo \$DEPS | tr ' ' '\\n' | sort -u); do
      libpath=\$(ldconfig -p | grep \"\$lib (\" | head -1 | awk '{print \$NF}' || true)
      if [ -z \"\$libpath\" ]; then
        libpath=\$(find /lib /usr/lib -name \"\$lib\" -type f 2>/dev/null | head -1 || true)
      fi
      if [ -n \"\$libpath\" ]; then
        cp -P \"\$libpath\" libs/ 2>/dev/null || cp \"\$libpath\" libs/
        for reallib in \$(find \"\$(dirname \"\$libpath\")\" -name \"\${lib%.so*}*\" -type f 2>/dev/null); do
          cp -n \"\$reallib\" libs/ 2>/dev/null || true
        done
      fi
    done
    ld_linux=\"/lib/ld-linux-aarch64.so.1\"
    if [ -f \"\$ld_linux\" ]; then
      cp -P \"\$ld_linux\" libs/
    fi
  "

# ========== 打包 USB/IP 产物 ==========
cd "$ROOT/usbip-out"
tar czf "$ROOT/usbip-arm64-bundle.tar.gz" .
