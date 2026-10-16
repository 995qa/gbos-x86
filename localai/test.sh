#!/bin/sh
# Tests for the API-based AI features that don't need the laptop. Needs docker.
#  - Java (in the build image): chip-format repair (ChipsTest), parcel reading/writing against a reference reader (WireTest, with a
#    stand-in android.os.Parcel from test/fake), the API client (ApiTest: JSON, settings, request building, a real HTTP round trip
#    against a fake provider, the request cap).
#  - The installer's AI step (installer_test.sh): the real function from usb/install.sh run under busybox sh (Alpine) with a fake
#    SSD/stick and scripted answers; checks files, permissions, leftover cleanup, and that the API key never reaches the log.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
Z=; [ "$(getenforce 2>/dev/null)" = Enforcing ] && Z=:z
docker build --platform linux/amd64 -q -t gbos-localai-build "$HERE" >/dev/null
docker run --rm --platform linux/amd64 -v "$HERE":/h:ro$Z gbos-localai-build sh -ec '
  mkdir -p /o /t/gbos/localai && cp /h/test/*Test.java /t/gbos/localai/
  S=/h/src/gbos/localai
  javac -d /o /h/test/fake/android/os/Parcel.java $S/Wire.java $S/Messages.java $S/Chips.java $S/Json.java $S/Config.java $S/Api.java /t/gbos/localai/*Test.java
  java -cp /o gbos.localai.ChipsTest
  java -cp /o gbos.localai.WireTest
  java -cp /o gbos.localai.ApiTest'
echo "--- installer step (busybox sh)"
docker run --rm --platform linux/amd64 -v "$ROOT":/r:ro$Z alpine:latest sh /r/localai/test/installer_test.sh /r/usb/install.sh
