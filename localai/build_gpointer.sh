#!/bin/sh
# Build usb/localai/gpointer.apk: Google's Magic Pointer app from YOUR Googlebook image (lapis/parts/product_a.img), with the
# one-byte capability patch from patch_gpointer.py. It is Google's binary, so it is generated locally, never committed and
# never part of the release image. Refuses to patch any build other than the one the patch was written for.
# Needs python3 and either dump.erofs (erofs-utils) or docker with the project's gbos-erofs image (tools/erofs-docker).
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
IMG=${1:-$ROOT/lapis/parts/product_a.img}
OUT=${2:-$ROOT/usb/localai/gpointer.apk}
[ -f "$IMG" ] || { echo "missing $IMG (build.sh extracts Google's partitions into lapis/parts)"; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
P=/priv-app/ContextualCursorPrebuilt/ContextualCursorPrebuilt.apk
echo "extracting $P from $IMG"
if command -v dump.erofs >/dev/null 2>&1; then
  dump.erofs --cat --path=$P "$IMG" > "$T/original.apk"
else
  Z=; [ "$(getenforce 2>/dev/null)" = Enforcing ] && Z=:z
  docker run --rm --platform linux/amd64 --entrypoint sh -v "$(dirname "$IMG")":/in:ro$Z gbos-erofs \
    -c "dump.erofs --cat --path=$P /in/$(basename "$IMG")" > "$T/original.apk"
fi
python3 -I "$HERE/patch_gpointer.py" "$T/original.apk" "$T/patched.apk"
mkdir -p "$(dirname "$OUT")"; mv "$T/patched.apk" "$OUT"
ls -l "$OUT"
