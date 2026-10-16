#!/bin/sh
# Download the Android build tools and platform jar that build_apk.sh uses, from Google's SDK repository, into
# localai/.toolchain (or $TOOLCHAIN). About 130 MB to download. Each archive is checked against the sha1 Google
# publishes in its repository catalogue before it is unpacked.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
TC=${TOOLCHAIN:-$HERE/.toolchain}
BASE=https://dl.google.com/android/repository
mkdir -p "$TC/dl" "$TC/build-tools" "$TC/platforms"

get() { # file sha1 destdir marker
  f=$1; sum=$2; dest=$3; marker=$4
  [ -e "$marker" ] && { echo "have $f"; return; }
  [ -f "$TC/dl/$f" ] || { echo "downloading $f"; curl -fL --progress-bar -o "$TC/dl/$f.part" "$BASE/$f" && mv "$TC/dl/$f.part" "$TC/dl/$f"; }
  got=$( (sha1sum "$TC/dl/$f" 2>/dev/null || shasum "$TC/dl/$f") | cut -d' ' -f1)
  [ "$got" = "$sum" ] || { echo "checksum mismatch for $f ($got)"; rm -f "$TC/dl/$f"; exit 1; }
  unzip -q -o "$TC/dl/$f" -d "$dest"
}

get build-tools_r35.0.1_linux.zip e009a9b188cfeb1d2b4c318ab5cb4f1ddc368861 "$TC/build-tools" "$TC/build-tools/35.0.1/aapt2"
[ -d "$TC/build-tools/android-15" ] && mv "$TC/build-tools/android-15" "$TC/build-tools/35.0.1"
get platform-36_r02.zip 2c1a80dd4d9f7d0e6dd336ec603d9b5c55a6f576 "$TC/platforms" "$TC/platforms/android-36/android.jar"
echo "toolchain ready in $TC"
