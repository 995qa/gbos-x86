#!/bin/sh
# Unit-test the parts of the local AI service that don't need a device: the chip-format repair (ChipsTest) and the parcel
# reading/writing against a reference reader (WireTest, using a stand-in android.os.Parcel from test/fake). Needs docker.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
Z=; [ "$(getenforce 2>/dev/null)" = Enforcing ] && Z=:z
docker build --platform linux/amd64 -q -t gbos-localai-build "$HERE" >/dev/null
docker run --rm --platform linux/amd64 -v "$HERE":/h:ro$Z gbos-localai-build sh -ec '
  mkdir -p /o /t/gbos/localai && cp /h/test/*Test.java /t/gbos/localai/
  S=/h/src/gbos/localai
  javac -d /o /h/test/fake/android/os/Parcel.java $S/Wire.java $S/Messages.java $S/Chips.java /t/gbos/localai/*Test.java
  java -cp /o gbos.localai.ChipsTest
  java -cp /o gbos.localai.WireTest'
