#!/bin/sh
# Build Mesa's AMD Vulkan driver (RADV) as an Android vendor Vulkan HAL ("vulkan.<name>.so", x86_64) with the NDK, for AMD GPUs
# (Ryzen / Radeon). Google's image only has an Intel Vulkan driver; hook.sh can bind the result over /vendor/lib64/hw/vulkan.intel.so.
# EXPERIMENTAL: never run on a real AMD laptop (see README "AMD graphics").
#
#   tools/radv-android/build.sh [OUT_DIR]
#
# Needs no device libraries: Mesa's `android-stub` option links against stub liblog/libcutils/libhardware/libnativewindow/libsync (their
# real versions on the device are used at run time); only the AOSP headers are needed, which tools/swiftshader-android/build.sh
# already fetched into the docker volume gbos-swsr (run that once first, or let this script fetch them: same pinned commits).
# Downloads (once, into the docker volume gbos-swsr): Android NDK r27c (~650 MB, dl.google.com), Mesa 25.0.7 (~370 MB, gitlab.freedesktop.org),
# libdrm 2.4.124 (~10 MB), meson wraps for expat/zlib (a few MB, wrapdb.mesonbuild.com).
# No LLVM: RADV compiles shaders with its own ACO compiler.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$HERE/../../build/radv}; mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
docker build --platform linux/amd64 -q -t gbos-radvbuild - <<'DOCKERFILE' >/dev/null
FROM --platform=linux/amd64 debian:trixie-slim
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends curl ca-certificates unzip git ninja-build meson pkgconf bison flex \
    python3 python3-mako python3-yaml python3-packaging python3-ply glslang-tools xz-utils make file binutils build-essential cmake >/dev/null && rm -rf /var/lib/apt/lists/*
WORKDIR /w
DOCKERFILE
docker volume create gbos-swsr >/dev/null
docker run --rm --platform linux/amd64 -e KEEP_BUILD="${KEEP_BUILD:-0}" -v gbos-swsr:/w -v "$HERE":/h:ro -v "$OUT":/out gbos-radvbuild sh -ec '
  cd /w
  NDK=/w/android-ndk-r27c
  if [ ! -d $NDK ]; then
    curl -fL --retry 5 -o ndk.zip https://dl.google.com/android/repository/android-ndk-r27c-linux.zip
    echo "59c2f6dc96743b5daf5d1626684640b20a6bd2b1d85b13156b90333741bad5cc  ndk.zip" | sha256sum -c -
    unzip -q ndk.zip
  fi
  # AOSP headers (same pinned commits as tools/swiftshader-android/build.sh)
  mkdir -p aosp && cd aosp
  get() { n=$1; u=$2; s=$3; shift 3
    [ -d $n ] || { git init -q $n; git -C $n remote add origin $u; git -C $n config core.sparseCheckout true
      for p in "$@"; do echo "/$p/" >> $n/.git/info/sparse-checkout; done
      git -C $n fetch -q --depth 1 --filter=blob:none origin $s; git -C $n checkout -q FETCH_HEAD; }; }
  B=https://android.googlesource.com
  get libhardware $B/platform/hardware/libhardware 7e08958a6cbe2b02c9d80a66fba68fd8a864d73d include include_all
  get core $B/platform/system/core a3b721a32242006b59cb12bd62c9133632af3a2d libcutils/include libsync/include libsystem/include libutils/include liblog/include libvndksupport/include
  get native $B/platform/frameworks/native 4f463a6b1de9198963dc6aff74154a504ba3f8f6 libs/nativewindow/include libs/arect/include vulkan/include
  cd /w
  A=/w/aosp
  INC="$A/libhardware/include:$A/libhardware/include_all:$A/core/libcutils/include:$A/core/libsync/include:$A/core/libsystem/include:$A/core/libutils/include:$A/core/liblog/include:$A/core/libvndksupport/include:$A/native/libs/nativewindow/include:$A/native/libs/arect/include:$A/native/vulkan/include"
  export CPLUS_INCLUDE_PATH=$INC C_INCLUDE_PATH=$INC
  # Mesa and libdrm, pinned
  [ -d mesa/.git ] || git clone -q --depth 1 --branch mesa-25.0.7 https://gitlab.freedesktop.org/mesa/mesa.git mesa
  [ -d drm/.git ]  || git clone -q --depth 1 --branch libdrm-2.4.124 https://gitlab.freedesktop.org/mesa/drm.git drm
  TC=$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin
  SDK=34
  cat > cross.txt <<EOF
[binaries]
ar = "$TC/llvm-ar"
c = ["$TC/x86_64-linux-android$SDK-clang", "-fno-exceptions", "-fno-unwind-tables", "-fno-asynchronous-unwind-tables"]
cpp = ["$TC/x86_64-linux-android$SDK-clang++", "-fno-exceptions", "-fno-unwind-tables", "-fno-asynchronous-unwind-tables", "-static-libstdc++"]
c_ld = "lld"
cpp_ld = "lld"
strip = "$TC/llvm-strip"
pkg-config = "pkgconf"
[host_machine]
system = "android"
cpu_family = "x86_64"
cpu = "x86_64"
endian = "little"
[properties]
needs_exe_wrapper = true
EOF
  # meson wants single quotes in machine files
  tr "\042" "\047" < cross.txt > cross.tmp && mv cross.tmp cross.txt
  # libdrm with amdgpu (static, so the HAL has no extra .so to ship)
  rm -rf /w/drm-b /w/sys; mkdir -p /w/sys
  meson setup drm-b drm --cross-file cross.txt --prefix=/w/sys --libdir=lib --default-library=static -Dintel=disabled -Dradeon=disabled -Damdgpu=enabled \
    -Dnouveau=disabled -Dvmwgfx=disabled -Dfreedreno=disabled -Dvc4=disabled -Detnaviv=disabled -Dexynos=disabled -Domap=disabled -Dtegra=disabled \
    -Dudev=false -Dcairo-tests=disabled -Dvalgrind=disabled -Dtests=false -Dman-pages=disabled -Dinstall-test-programs=false >/w/drm-setup.log 2>&1 || { tail -30 /w/drm-setup.log; exit 1; }
  ninja -C drm-b install >/w/drm-build.log 2>&1 || { tail -30 /w/drm-build.log; exit 1; }
  export PKG_CONFIG_PATH=/w/sys/lib/pkgconfig PKG_CONFIG_LIBDIR=/w/sys/lib/pkgconfig
  cd mesa
  [ "${KEEP_BUILD:-0}" = 1 ] || rm -rf /w/mesa-b
  [ -d /w/mesa-b ] || meson setup /w/mesa-b . --cross-file /w/cross.txt --prefix=/w/mesa-out --buildtype=release -Db_ndebug=true -Dstrip=true \
    -Dc_args="-I/w/sys/include -I/w/sys/include/libdrm" -Dcpp_args="-I/w/sys/include -I/w/sys/include/libdrm" -Dplatforms=android -Dandroid-stub=true -Dplatform-sdk-version=$SDK -Dandroid-libbacktrace=disabled -Dcpp_rtti=false \
    -Dvulkan-drivers=amd -Dgallium-drivers= -Dllvm=disabled -Dopengl=false -Dgles1=disabled -Dgles2=disabled -Degl=disabled -Dgbm=disabled -Dglx=disabled \
    -Dglvnd=disabled -Dvalgrind=disabled -Dlibunwind=disabled -Dlmsensors=disabled -Dshader-cache=enabled -Dbuild-tests=false -Dvulkan-layers= \
    -Dvideo-codecs= -Dgallium-va=disabled -Dgallium-vdpau=disabled -Dxlib-lease=disabled -Dzstd=disabled -Dperfetto=false -Dmicrosoft-clc=disabled \
    -Dintel-rt=disabled -Dteflon=false -Dgallium-opencl=disabled -Dgallium-rusticl=false -Dtools= >/w/mesa-setup.log 2>&1 || { tail -60 /w/mesa-setup.log; exit 1; }
  ninja -C /w/mesa-b -j"$(nproc)" >/w/mesa-build.log 2>&1 || { tail -60 /w/mesa-build.log; exit 1; }
  find /w/mesa-b -name "libvulkan_radeon.so" -exec ls -l {} \;
  F=$(find /w/mesa-b -name "libvulkan_radeon.so" | head -n 1)
  $TC/llvm-strip --strip-unneeded -o /out/vulkan.radv.so "$F"
  ls -l /out/vulkan.radv.so; sha256sum /out/vulkan.radv.so
'
