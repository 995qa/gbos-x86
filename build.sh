#!/bin/sh
# gbOS86: one-command build.   ./build.sh            -> dist/gbOS86-YYYYMMDD.img (about 6.7 GB), ready to flash.
#   ./build.sh -y          don't ask before downloading
#   ./build.sh --dry-run   show what would be downloaded and built, change nothing
#
# What it does (each step is skipped when its result already exists, so re-running is cheap and resumable):
#   1. Google's OS: downloads Google's public Googlebook recovery image (7.7 GB) and extracts only the six partitions
#      gbOS86 needs (about 8 GB, streamed, so the 19 GB disk image inside is never written to disk).
#   2. busybox (Debian busybox-static, ~1 MB) via docker.
#   3. Kernel modules (14 MB) and firmware (53 MB) built from this repo's sources, from the GitHub release.
#   4. Assembles the flashable image with tools/make_gbos86_image.sh (the kernel, patched libraries and installer
#      tools are already in this repository).
# Needs: macOS or Linux, docker (running), python3, curl, tar, xz, ~35 GB free disk. The image holds Google's OS and
# patched Google libraries: for your own use, don't share it.
set -e
cd "$(dirname "$0")"
YES=0; DRY=0
for a in "$@"; do case $a in -y|--yes) YES=1;; --dry-run) DRY=1;; -h|--help) sed -n '2,15p' "$0"; exit 0;; esac; done

REL=https://github.com/linuxkid473/gbos-x86/releases/download/v32
MODS=gbos86-modules-6.18.21-gbos-whl.tar.xz;               MODS_SHA=876705e2f707bde12ef558b0759f2b3c62db287e8163183d767d5f53fa3ffdac
# v33 firmware = v32 + Realtek rtw89 8852A/B/BT/C and 8851B (v32's fetch regex skipped them: no Wi-Fi on RTL8852BE laptops)
# v34 firmware = v33 + Intel Bluetooth link names ibt-0040-1050/2120/4150 (WHENCE "Link:" entries: Bluetooth on Intel AX201 laptops)
REL_FW=https://github.com/linuxkid473/gbos-x86/releases/download/v34
FW=gbos86-firmware-d5455717-sof2026.09.2-r3.tar.xz;        FW_SHA=653a6a2214429dd9c2f8f933dbd323ae231095257f9219da7f385f4d7022b877
GOOGLE=https://dl.google.com/device/recovery/lapis-user/16452207/recovery.zip
PARTS="system_a vendor_a product_a system_ext_a system_dlkm_a vendor_dlkm_a"

say() { printf '\n== %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
have_parts() { for p in $PARTS; do [ -s lapis/parts/$p.img ] || return 1; done; }
fetch() { # url dest sha
  mkdir -p "$(dirname "$2")"
  curl -fL --retry 5 -C - -o "$2" "$1" || die "download failed: $1"
  [ "$(sha "$2")" = "$3" ] || { rm -f "$2"; die "checksum mismatch for $1 (file deleted, run again)"; }
}

for c in docker python3 curl tar xz; do command -v $c >/dev/null 2>&1 || die "missing '$c'"; done
docker info >/dev/null 2>&1 || die "docker is installed but not running"

NEED=""
have_parts || NEED="$NEED\n  - Google's recovery image: $GOOGLE (7.7 GB, from dl.google.com)"
[ -x kernel/out/busybox ] || NEED="$NEED\n  - busybox-static from Debian via docker (about 1 MB)"
[ -d usb/modules/lib/modules ] || NEED="$NEED\n  - $MODS (14 MB, from this project's GitHub release)"
[ -f usb/firmware/intel/ibt-0040-1050.sfi ] || NEED="$NEED\n  - $FW (38 MB, from this project's GitHub release)"
if [ -z "$NEED" ]; then say "everything is already downloaded"; else
  printf 'This will download:%b\n' "$NEED"
fi
FREE_KB=$(df -k . | awk 'NR==2{print $4}'); [ "$FREE_KB" -gt 36000000 ] || printf '\nWARNING: only %d GB free here; about 35 GB are needed.\n' $((FREE_KB / 1000000))
[ $DRY = 1 ] && { echo "(dry run: nothing changed)"; exit 0; }
if [ -n "$NEED" ] && [ $YES = 0 ]; then printf '\nContinue? [y/N] '; read -r a; case $a in y|Y|yes) ;; *) exit 1;; esac; fi

if ! have_parts; then
  say "1/4 Google's OS image"
  fetch "$GOOGLE" lapis/recovery.zip "$(cut -d' ' -f1 lapis/recovery.zip.sha256)"
  python3 tools/fetch_google_parts.py lapis/recovery.zip lapis/parts $PARTS
  [ "${KEEP_ZIP:-0}" = 1 ] || rm -f lapis/recovery.zip
else say "1/4 Google's OS image: already extracted"; fi

if [ ! -x kernel/out/busybox ]; then say "2/4 busybox"; sh tools/fetch_busybox.sh; else say "2/4 busybox: present"; fi

if [ ! -d usb/modules/lib/modules ]; then
  say "3/4 kernel modules and firmware"
  fetch "$REL/$MODS" "build/dl/$MODS" "$MODS_SHA"; tar -xJf "build/dl/$MODS" -C usb
else say "3/4 kernel modules: present"; fi
if [ ! -f usb/firmware/intel/ibt-0040-1050.sfi ]; then
  fetch "$REL_FW/$FW" "build/dl/$FW" "$FW_SHA"; tar -xJf "build/dl/$FW" -C usb
else say "    firmware: present"; fi

say "4/4 building the image"
sh tools/make_gbos86_image.sh
echo
echo "Done. Flash the .img in dist/ to a USB stick of 8 GB or more (balenaEtcher, Rufus, or dd), then boot it (F12)."
