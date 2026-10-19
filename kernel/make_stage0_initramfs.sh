#!/bin/sh
# Build the stage0 initramfs (the busybox init that mounts the stick and starts Android) from a
# modules_install tree, and copy it where the kernel expects it.
#
#   sh kernel/make_stage0_initramfs.sh [MODULES_ROOT] [OUT.cpio]
#     MODULES_ROOT  a modules_install tree (default /build/modroot_all)
#     OUT.cpio      where to write it (default /build/out/gbos_stage0.cpio)
#
# The module set is kernel/stage0_modules.txt: the modules stage0 can load before Android starts
# (i915, iwlwifi/iwlmvm/mac80211/cfg80211, the Bluetooth stack, sdhci for eMMC, zram, ...). The
# rest of the module tree lives on the stick (gbos/modules) and is loaded by usb/hwdetect.sh.
# The initramfs is embedded in the kernel (CONFIG_INITRAMFS_SOURCE), so the kernel has to be
# rebuilt after this.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
MODROOT=${1:-/build/modroot_all}
OUT=${2:-/build/out/gbos_stage0.cpio}
LIST=$ROOT/kernel/stage0_modules.txt
[ -d "$MODROOT/lib/modules" ] || { echo "no modules in $MODROOT"; exit 1; }
[ -f "$LIST" ] || { echo "no $LIST"; exit 1; }

VER=$(ls "$MODROOT/lib/modules" | head -1)
W=$(mktemp -d "${TMPDIR:-/tmp}/stage0.XXXXXX"); trap 'rm -rf "$W"' EXIT
DEST=$W/lib/modules/$VER
mkdir -p "$DEST"

missing=0
while read -r m; do
  [ -n "$m" ] || continue
  if [ -f "$MODROOT/lib/modules/$VER/$m" ]; then
    mkdir -p "$DEST/$(dirname "$m")"
    cp "$MODROOT/lib/modules/$VER/$m" "$DEST/$m"
  else
    echo "missing module: $m" >&2
    missing=$((missing+1))
  fi
done < "$LIST"
[ $missing = 0 ] || { echo "$missing module(s) not in $MODROOT"; exit 1; }

# the module metadata (depmod'ed) and the built-in list, so modprobe works in stage0
for f in "$MODROOT/lib/modules/$VER"/modules.*; do
  [ -f "$f" ] && cp "$f" "$DEST/"
done

python3 "$ROOT/usb/make_initramfs.py" "$W" "$OUT"
echo "initramfs: $OUT ($(stat -c %s "$OUT") bytes, $(find "$W" -name '*.ko' | wc -l) modules)"
