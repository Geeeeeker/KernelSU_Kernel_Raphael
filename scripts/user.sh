#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must be set}
cd "$KERNEL_DIR"

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

# 4. 修复 rtl8188eus 在 clang -Werror 下触发的 -Wparentheses-equality
#    原因：usb_halinit.c 里 if ((IS_FULL_SPEED_USB(Adapter)) ... 多包了一层括号，
#    该驱动是第三方老代码，直接对其目录关闭该警告最安全。
if [ -f drivers/rtl8188eus/Makefile ]; then
  if ! grep -q 'Wno-parentheses-equality' drivers/rtl8188eus/Makefile; then
    cat >> drivers/rtl8188eus/Makefile <<'EOF'

# Third-party rtl8188eus driver: silence clang's -Werror=parentheses-equality
subdir-ccflags-y += -Wno-parentheses-equality
subdir-ccflags-y += -Wno-error=parentheses-equality
EOF
    echo "rtl8188eus: appended -Wno-parentheses-equality to Makefile"
  else
    echo "rtl8188eus: -Wno-parentheses-equality already present"
  fi
else
  echo "rtl8188eus: Makefile not found, skip warning suppression"
fi
