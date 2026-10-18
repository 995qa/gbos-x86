#!/bin/sh
# port_build.sh [PARTS_DIR] [--write] [--isa] [--product]
#
# Port gbOS86 to a Google build (default PARTS_DIR: lapis/parts, filled by build.sh / tools/fetch_google_parts.py).
# Unpacks system, vendor, system_ext (+ product) and every APEX payload in the gbos-erofs container, then runs
# tools/port_build.py on them: re-applies the binary patches (libz, libcrypto, libkm_compat), regenerates the VINTF
# manifest and usb/patched/MANIFEST, checks every anchor the boot scripts rely on, and with --isa scans the build for
# instructions the kernel emulator does not cover. Without --write the repo is not touched.
#
#   PORT_KEEP=1   keep the unpacked build in the docker volume gbos-port-work (a re-run skips the ~minutes of unpacking)
#
# See porting.md.  Needs docker and the gbos-erofs image (docker build -t gbos-erofs tools/erofs-docker).
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PARTS=$ROOT/lapis/parts; WRITE=0; EXTRA=""; EXARGS=""; KC=""
while [ $# -gt 0 ]; do
  case $1 in
    --write) WRITE=1; EXTRA="$EXTRA --write";;
    --isa) EXTRA="$EXTRA --isa";;
    --product) EXARGS="--product";;
    -h|--help) sed -n '2,13p' "$0"; exit 0;;
    -*) echo "unknown option $1"; exit 2;;
    *) PARTS=$(cd "$1" && pwd);;
  esac
  shift
done
for n in system_a vendor_a system_ext_a; do [ -f "$PARTS/$n.img" ] || { echo "missing $PARTS/$n.img (run ./build.sh, or tools/fetch_google_parts.py)"; exit 1; }; done
docker image inspect gbos-erofs >/dev/null 2>&1 || { echo "building the gbos-erofs image ..."; docker build -q -t gbos-erofs "$ROOT/tools/erofs-docker"; }
# kernel.config sits next to the partitions when lp_extract.py put it there
[ -f "$PARTS/kernel.config" ] && EXTRA="$EXTRA --kernel-config=/in/kernel.config"

# Fedora/RHEL (SELinux enforcing): bind mounts of this repo need :z (never relabel other directories)
Z=; [ "$(getenforce 2>/dev/null)" = Enforcing ] && Z=,z
RO=ro; [ $WRITE = 1 ] && RO=rw
V=gbos-port-work; [ "${PORT_KEEP:-0}" = 1 ] || V=gbos-port-work-$$
docker volume create $V >/dev/null
trap '[ "${PORT_KEEP:-0}" = 1 ] || docker volume rm $V >/dev/null 2>&1' EXIT
docker run --rm -v $V:/work -v "$ROOT":/host:$RO$Z -v "$PARTS":/in:ro$Z gbos-erofs sh -ec "
  [ -f /work/.done ] || { rm -rf /work/*; python3 -I /host/tools/extract_build.py /in /work $EXARGS; }
  python3 -I /host/tools/port_build.py /work $EXTRA"
