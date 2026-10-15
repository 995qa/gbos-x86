#!/bin/sh
# Build soft_gk inside the gbos-kbuild image (Android clang, no NDK): links against the image's
# own libraries in libs/ (system/lib64, plus libc/libdl from the runtime APEX).
set -e
C=/build/inputs/clang-r584948c
cd /host/gatekeeper
$C/bin/clang-22 --target=x86_64-linux-android36 -O2 -fPIE -fno-stack-protector -ffreestanding \
  -fvisibility=hidden -Wall -Wextra -Werror -c soft_gk.c -o soft_gk.o
$C/bin/ld.lld -pie --dynamic-linker=/system/bin/linker64 -z noexecstack -z now --hash-style=gnu \
  --no-undefined -e _start -o soft_gk soft_gk.o -Llibs -lc -lbinder_ndk -llog -lcrypto -ldl
$C/bin/llvm-readelf -d soft_gk | grep -E 'NEEDED|FLAGS'
