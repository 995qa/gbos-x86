#!/bin/sh
# Build usb/localai/localai.apk (the AICore stand-in). Needs docker and the toolchain from fetch_toolchain.sh.
# The signing key is created once in $LOCALAI_KEYS (default ~/.gbos-localai) and reused so updates keep the same
# signature. Never commit it.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
TC=${TOOLCHAIN:-$HERE/.toolchain}
OUT=${1:-$HERE/../usb/localai}
KEYS=${LOCALAI_KEYS:-$HOME/.gbos-localai}
[ -f "$TC/build-tools/35.0.1/aapt2" ] || { echo "no toolchain in $TC: run localai/fetch_toolchain.sh"; exit 1; }
mkdir -p "$OUT" "$KEYS"; OUT=$(cd "$OUT" && pwd)
docker build --platform linux/amd64 -q -t gbos-localai-build "$HERE" >/dev/null

# Fedora/RHEL (SELinux enforcing): bind mounts of this repo's folders need :z.
Z=; [ "$(getenforce 2>/dev/null)" = Enforcing ] && Z=:z

docker run --rm --platform linux/amd64 -v "$HERE":/src:ro$Z -v "$TC":/tc:ro -v "$OUT":/out$Z -v "$KEYS":/keys \
  gbos-localai-build sh -ec '
  BT=/tc/build-tools/35.0.1; AJ=/tc/platforms/android-36/android.jar
  W=/tmp/b; rm -rf $W; mkdir -p $W/classes $W/dex
  javac --release 11 -Xlint:-options -cp $AJ -d $W/classes $(find /src/src -name "*.java")
  $BT/d8 --release --min-api 29 --lib $AJ --output $W/dex $(find $W/classes -name "*.class")
  $BT/aapt2 link -o $W/base.apk -I $AJ --manifest /src/AndroidManifest.xml --min-sdk-version 29 --target-sdk-version 35
  (cd $W/dex && zip -q $W/base.apk classes.dex)
  $BT/zipalign -f -p 4 $W/base.apk $W/aligned.apk
  [ -f /keys/localai.jks ] || keytool -genkeypair -keystore /keys/localai.jks -storepass gbos-localai -keypass gbos-localai \
      -alias localai -keyalg RSA -keysize 3072 -validity 36500 -dname "CN=gbOS86 local AI" >/dev/null 2>&1
  $BT/apksigner sign --v4-signing-enabled false --ks /keys/localai.jks --ks-pass pass:gbos-localai --key-pass pass:gbos-localai --out /out/localai.apk $W/aligned.apk
  $BT/apksigner verify --print-certs /out/localai.apk | head -2
  $BT/aapt2 dump badging /out/localai.apk | head -3
'
ls -l "$OUT/localai.apk"
