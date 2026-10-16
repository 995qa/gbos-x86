#!/bin/sh
# Kernel #31 stage 2 (gbos-kbuild, -v gbos-ksrc:/build): from the full module tree made by build_generic.sh, make
#   /build/modroot_ini   only the modules the stage0 initramfs already carried (/build/ini_modules.txt), depmod'ed
# Host side afterwards:  docker cp the tree to usb/modroot, usb/make_initramfs.py usb/modroot usb/stage0.cpio,
# put it at /build/out/gbos_stage0.cpio and run build.sh again so it is embedded (see tools/build_kernel31.sh).
set -e
KVER=$(cat /build/out/include/config/kernel.release)
SRC=/build/modroot_all/lib/modules/$KVER
DST=/build/modroot_ini/lib/modules/$KVER
rm -rf /build/modroot_ini; mkdir -p $DST
while read m; do mkdir -p $DST/$(dirname $m); cp $SRC/$m $DST/$m; done < /build/ini_modules.txt
cp $SRC/modules.order $SRC/modules.builtin $SRC/modules.builtin.modinfo $DST/ 2>/dev/null || true
depmod -b /build/modroot_ini $KVER
echo "initramfs modules: $(find $DST -name '*.ko' | wc -l), $(du -sh /build/modroot_ini | cut -f1) (kernel $KVER)"
