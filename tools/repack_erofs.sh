#!/bin/sh
# repack_erofs.sh IN.img OUT.img : extract an erofs image (owner/perms/xattrs kept), apply tools/patch_tree.py, rebuild.
# Runs the Linux side in the gbos-erofs container; /work is a throwaway volume so xattrs work.
set -e
IN=$(cd "$(dirname "$1")" && pwd)/$(basename "$1"); OUT=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
ROOT=$(cd "$(dirname "$0")/.." && pwd)
V=gbos-work-$$
docker volume create $V >/dev/null
docker run --rm --cap-add SYS_ADMIN --cap-add MAC_ADMIN --cap-add SETFCAP -v $V:/work -v "$ROOT":/host:ro -v "$(dirname "$IN")":/in:ro -v "$(dirname "$OUT")":/out gbos-erofs sh -ec "
  mkdir /work/tree
  fsck.erofs --extract=/work/tree --force --preserve --xattrs /in/$(basename "$IN") >/work/extract.log 2>&1 || { tail -5 /work/extract.log; exit 1; }
  python3 -I /host/tools/tree_manifest.py /work/tree > /work/m1.txt
  python3 -I /host/tools/patch_tree.py /work/tree
  mkfs.erofs -zlz4hc,9 --quiet -T0 -x1 /out/$(basename "$OUT") /work/tree
  mkdir /work/tree2
  fsck.erofs --extract=/work/tree2 --force --preserve --xattrs /out/$(basename "$OUT") >/work/extract2.log 2>&1
  python3 -I /host/tools/tree_manifest.py /work/tree2 > /work/m2.txt
  if diff /work/m1.txt /work/m2.txt >/work/diff.txt; then echo MANIFEST_IDENTICAL; else echo MANIFEST_DIFF; head -5 /work/diff.txt; wc -l /work/diff.txt; fi
"
docker volume rm $V >/dev/null
