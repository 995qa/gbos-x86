#!/bin/sh
# Build SwiftShader (CPU Vulkan) as an Android vendor Vulkan HAL (hwvulkan module, "vulkan.<name>.so") for x86_64, with the NDK.
# Used for GPUs Google's image has no driver for (AMD): hook.sh bind-mounts the result over /vendor/lib64/hw/vulkan.intel.so.
#
#   tools/swiftshader-android/build.sh DEVLIBS [OUT_DIR]
#
# DEVLIBS = a folder with the device's own liblog.so libnativewindow.so libsync.so libhardware.so libcutils.so (from the Googlebook
#           system image, e.g. lapis/probe/system_a/system/lib64); they are only linked against, never shipped.
# Downloads (once, into the docker volume gbos-swsr): Android NDK r27c (~650 MB, dl.google.com), SwiftShader at a pinned commit
# (~250 MB, swiftshader.googlesource.com) and a few AOSP header directories (libhardware, system/core, frameworks/native; a few MB).
# Why not SwiftShader's own CMake for Android: it only knows Windows/Linux/Mac/Fuchsia for Vulkan (Android is built with Soong in
# AOSP), so swiftshader-android.patch makes the NDK build take the Linux paths plus the Android glue from src/Android.bp.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
DEVLIBS=${1:?usage: build.sh DEVLIBS [OUT_DIR]}; DEVLIBS=$(cd "$DEVLIBS" && pwd)
OUT=${2:-$HERE/../../build/swr}; mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
for l in liblog libnativewindow libsync libhardware libcutils; do [ -f "$DEVLIBS/$l.so" ] || { echo "missing $DEVLIBS/$l.so"; exit 1; }; done
docker build --platform linux/amd64 -q -t gbos-swbuild - <<'DOCKERFILE' >/dev/null
FROM --platform=linux/amd64 debian:trixie-slim
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends curl ca-certificates unzip git cmake ninja-build python3 xz-utils make file binutils >/dev/null && rm -rf /var/lib/apt/lists/*
WORKDIR /w
DOCKERFILE
docker volume create gbos-swsr >/dev/null
docker run --rm --platform linux/amd64 -e KEEP_BUILD="${KEEP_BUILD:-0}" -v gbos-swsr:/w -v "$HERE":/h:ro -v "$DEVLIBS":/devlibs:ro -v "$OUT":/out gbos-swbuild sh -ec '
  cd /w
  # NDK r27c (sha256 from the download)
  if [ ! -d android-ndk-r27c ]; then
    curl -fL --retry 5 -o ndk.zip https://dl.google.com/android/repository/android-ndk-r27c-linux.zip
    echo "59c2f6dc96743b5daf5d1626684640b20a6bd2b1d85b13156b90333741bad5cc  ndk.zip" | sha256sum -c -
    unzip -q ndk.zip
  fi
  # SwiftShader, pinned
  if [ ! -d swiftshader/.git ]; then
    git init -q swiftshader && git -C swiftshader remote add origin https://swiftshader.googlesource.com/SwiftShader
    git -C swiftshader fetch -q --depth 1 origin cddb5c91b23ff70a1f607ea31610aa0d7f4b5ad5
    git -C swiftshader checkout -q FETCH_HEAD
  fi
  git -C swiftshader checkout -q -- . ; git -C swiftshader apply /h/swiftshader-android.patch
  python3 swiftshader/src/commit_id.py gen swiftshader/src/Vulkan/commit.h
  # AOSP headers (only what src/Vulkan and src/System include under __ANDROID__), pinned
  mkdir -p aosp && cd aosp
  get() { # name url sha paths...
    n=$1; u=$2; s=$3; shift 3
    [ -d $n ] || { git init -q $n; git -C $n remote add origin $u; git -C $n config core.sparseCheckout true
      for p in "$@"; do echo "/$p/" >> $n/.git/info/sparse-checkout; done
      git -C $n fetch -q --depth 1 --filter=blob:none origin $s; git -C $n checkout -q FETCH_HEAD; }
  }
  B=https://android.googlesource.com
  get libhardware $B/platform/hardware/libhardware 7e08958a6cbe2b02c9d80a66fba68fd8a864d73d include include_all
  get core $B/platform/system/core a3b721a32242006b59cb12bd62c9133632af3a2d libcutils/include libsync/include libsystem/include libutils/include liblog/include libvndksupport/include
  get native $B/platform/frameworks/native 4f463a6b1de9198963dc6aff74154a504ba3f8f6 libs/nativewindow/include libs/arect/include vulkan/include
  cd /w
  mkdir -p stubs && cd stubs && for n in pthread rt; do [ -f lib$n.a ] || ar rcs lib$n.a; done && cd ..
  mkdir -p devlibs && cp /devlibs/liblog.so /devlibs/libnativewindow.so /devlibs/libsync.so /devlibs/libhardware.so /devlibs/libcutils.so devlibs/
  A=/w/aosp
  INC="$A/libhardware/include:$A/libhardware/include_all:$A/core/libcutils/include:$A/core/libsync/include:$A/core/libsystem/include:$A/core/libutils/include:$A/core/liblog/include:$A/core/libvndksupport/include:$A/native/libs/nativewindow/include:$A/native/libs/arect/include:$A/native/vulkan/include"
  export CPLUS_INCLUDE_PATH=$INC C_INCLUDE_PATH=$INC
  NDK=/w/android-ndk-r27c
  [ "${KEEP_BUILD:-0}" = 1 ] || rm -rf build-sw   # a clean build takes ~40 min on 8 cores; KEEP_BUILD=1 reuses the last one
  cmake -S swiftshader -B build-sw -G Ninja -DCMAKE_TOOLCHAIN_FILE=$NDK/build/cmake/android.toolchain.cmake -DANDROID_ABI=x86_64 \
    -DANDROID_PLATFORM=android-34 -DANDROID_STL=c++_static -DCMAKE_BUILD_TYPE=Release -DSWIFTSHADER_BUILD_TESTS=OFF \
    -DSWIFTSHADER_BUILD_BENCHMARKS=OFF -DSWIFTSHADER_WARNINGS_AS_ERRORS=OFF -DSWIFTSHADER_BUILD_PVR=OFF -DSWIFTSHADER_BUILD_WSI_XCB=OFF -DSWIFTSHADER_BUILD_WSI_WAYLAND=OFF \
    -DCMAKE_CXX_FLAGS="-Wno-error -Wno-missing-field-initializers" \
    -DCMAKE_SHARED_LINKER_FLAGS="-L/w/devlibs -L/w/stubs -Wl,--allow-shlib-undefined" >/dev/null 2>&1
  ninja -C build-sw -j"$(nproc)" vk_swiftshader
  $NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip --strip-unneeded -o /out/vulkan.swiftshader.so build-sw/libvk_swiftshader.so
  ls -l /out/vulkan.swiftshader.so; sha256sum /out/vulkan.swiftshader.so
'
