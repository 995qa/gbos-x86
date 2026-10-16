#!/bin/sh
# Build llama-server (llama.cpp) for Android x86_64 into usb/localai/llama-server. Needs docker and the toolchain
# from fetch_toolchain.sh. The source is a shallow clone of the pinned tag into localai/.llama.cpp (gitignored).
# CPU features are fixed to what a Skylake-or-newer laptop has (AVX2, FMA, F16C, BMI2): no AVX-512/VNNI, which
# the Whiskey Lake CPU lacks (the kernel's instruction emulation would make them crawl).
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
TC=${TOOLCHAIN:-$HERE/.toolchain}
OUT=${1:-$HERE/../usb/localai}
TAG=${LLAMA_TAG:-v0.7.0}
SRC=$HERE/.llama.cpp
NDK=/tc/ndk/android-ndk-r27d
[ -d "$TC/ndk/android-ndk-r27d/toolchains" ] || { echo "no NDK in $TC: run localai/fetch_toolchain.sh"; exit 1; }
if [ ! -d "$SRC/.git" ]; then
  git clone --depth 1 --branch "$TAG" https://github.com/ggml-org/llama.cpp "$SRC"
fi
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
docker build --platform linux/amd64 -q -t gbos-localai-build "$HERE" >/dev/null
Z=; [ "$(getenforce 2>/dev/null)" = Enforcing ] && Z=:z

docker run --rm --platform linux/amd64 -v "$SRC":/src$Z -v "$TC":/tc:ro -v "$OUT":/out$Z gbos-localai-build sh -ec "
  cmake -S /src -B /tmp/build -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE=$NDK/build/cmake/android.toolchain.cmake \
    -DANDROID_ABI=x86_64 -DANDROID_PLATFORM=android-29 -DANDROID_STL=c++_static \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
    -DGGML_NATIVE=OFF -DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON -DGGML_BMI2=ON \
    -DGGML_AVX512=OFF -DGGML_AVX_VNNI=OFF -DGGML_OPENMP=OFF \
    -DLLAMA_CURL=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TOOLS=ON -DLLAMA_BUILD_SERVER=ON
  cmake --build /tmp/build --target llama-server -j\$(nproc)
  $NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip -o /out/llama-server /tmp/build/bin/llama-server
"
ls -l "$OUT/llama-server"
