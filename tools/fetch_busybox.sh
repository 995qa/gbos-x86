#!/bin/sh
# kernel/out/busybox: the static x86-64 busybox stage0 and the stick use (Debian's busybox-static, 1.37).
# Needs docker; safe to re-run.   tools/fetch_busybox.sh [OUT_FILE]
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-$ROOT/kernel/out/busybox}
mkdir -p "$(dirname "$OUT")"
D=$(mktemp -d)
docker run --rm --platform linux/amd64 -v "$D":/out debian:trixie-slim sh -c '
  apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends busybox-static >/dev/null &&
  cp /bin/busybox /out/busybox && /out/busybox | head -1'
cp "$D/busybox" "$OUT"; chmod 755 "$OUT"; rm -rf "$D"
echo "busybox -> $OUT"
