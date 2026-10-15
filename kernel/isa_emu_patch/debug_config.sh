#!/bin/sh
# Enable on-screen VT/fbcon console + verbose cmdline for the USB debug image.
set -e
cd /build/src
S="scripts/config --file /build/out/.config"
$S -e VT -e VT_CONSOLE -e VT_HW_CONSOLE_BINDING -e FB -e FB_CORE -e FB_EFI -e DRM_FBDEV_EMULATION \
   -e FRAMEBUFFER_CONSOLE -e FRAMEBUFFER_CONSOLE_DETECT_PRIMARY -e FRAMEBUFFER_CONSOLE_DEFERRED_TAKEOVER \
   -e DRM_PANIC -e DRM_PANIC_SCREEN_QR_CODE -e FONT_SUPPORT -e FONTS -e FONT_TER16x32 -e FONT_8x16 \
   -e MAGIC_SYSRQ -e EFI_VARS_PSTORE -e DM_INIT -d FRAMEBUFFER_CONSOLE_DEFERRED_TAKEOVER
$S --set-str CMDLINE "${GBOS_CMDLINE}"
$S --set-str INITRAMFS_SOURCE "${GBOS_INITRAMFS:-}"
C=/build/inputs/clang-r584948c
make -C /build/src O=/build/out ARCH=x86_64 LLVM=$C/bin/ CC=$C/bin/clang-22 olddefconfig >/dev/null
grep -E 'CONFIG_(VT|VT_CONSOLE|FB|FB_EFI|DRM_FBDEV_EMULATION|FRAMEBUFFER_CONSOLE|DRM_PANIC|CMDLINE|INITRAMFS_SOURCE)=' /build/out/.config
