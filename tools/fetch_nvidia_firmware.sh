#!/bin/sh
# Fetch the NVIDIA (nouveau) firmware for one chip from linux-firmware, without cloning the whole
# 1.5 GB tree. The files are small (a few hundred kB per chip, except the GSP firmware of Turing
# and newer, which is 30-70 MB per chip and is not fetched here).
#
#   tools/fetch_nvidia_firmware.sh [CHIP ...]      (default: every pre-Turing chip)
#
# Output: usb/firmware/nvidia/<chip>/... (the same layout linux-firmware uses, so the driver finds
# the files through the firmware path). The chip is the one nouveau prints at boot
# ("nouveau 0000:01:00.0: NVIDIA GP107"): gp100, gp102, gp104, gp106, gp107, gp108, gm200, gm204,
# gm206, gm20b, gk20a.
#
# Some of the files are WHENCE "Link:" entries (the real file lives in another chip's folder,
# e.g. nvidia/gp107/gr/sw_bundle_init.bin -> nvidia/gp102/gr/sw_bundle_init.bin); those are
# downloaded from their target and stored under the link name, as the driver asks for them.
set -e
REPO=$(cd "$(dirname "$0")/.." && pwd)
OUT=$REPO/usb/firmware/nvidia
BASE=https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git
CHIPS=${*:-gp100 gp102 gp104 gp106 gp107 gp108 gm200 gm204 gm206 gm20b gk20a}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
curl -sfL "$BASE/plain/WHENCE" -o "$W/WHENCE"

get() { # get PATH_IN_TREE (relative to the firmware root)
  f=$OUT/${1#nvidia/}
  [ -f "$f" ] && return 0
  mkdir -p "$(dirname "$f")"
  curl -sfL "$BASE/plain/$1" -o "$f" || { rm -f "$f"; echo "  not in linux-firmware: $1"; return 1; }
  echo "  $1"
}

for c in $CHIPS; do
  echo "== $c"
  # the files the driver asks for (MODULE_FIRMWARE in the kernel) and their WHENCE links
  for f in acr/bl.bin acr/ucode_load.bin acr/ucode_unload.bin acr/unload_bl.bin \
           gr/fecs_bl.bin gr/fecs_data.bin gr/fecs_inst.bin gr/fecs_sig.bin \
           gr/gpccs_bl.bin gr/gpccs_data.bin gr/gpccs_inst.bin gr/gpccs_sig.bin \
           gr/sw_bundle_init.bin gr/sw_ctx.bin gr/sw_method_init.bin gr/sw_nonctx.bin \
           nvdec/scrubber.bin sec2/desc.bin sec2/image.bin sec2/sig.bin; do
    p=$c/$f
    [ -f "$OUT/$p" ] && continue
    # a WHENCE link? then take the target (the path is relative to the link's own directory)
    t=$(sed -n "s#^Link: nvidia/$p -> \(.*\)\$#\1#p" "$W/WHENCE" | head -1)
    if [ -n "$t" ]; then
      t=$(python3 -c "import os,sys; print(os.path.normpath(os.path.join(os.path.dirname(sys.argv[1]), sys.argv[2])))" "nvidia/$p" "$t")
      get "$t" || continue
      mkdir -p "$(dirname "$OUT/$p")"
      cp "$OUT/${t#nvidia/}" "$OUT/$p" && echo "  nvidia/$p (link -> $t)"
      continue
    fi
    get "nvidia/$p" || true
  done
done
echo
echo "firmware in $OUT: $(find $OUT -name '*.bin' | wc -l) files, $(du -sh $OUT | cut -f1)"
echo "copy it to the stick: cp -R $OUT/. /Volumes/GBOS/gbos/firmware/nvidia/"
