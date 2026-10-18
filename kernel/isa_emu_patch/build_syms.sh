#!/bin/sh
# Incremental kernel build (gbos-kbuild, -v gbos-ksrc:/build -v <repo>/kernel:/k): turn the given CONFIG symbols on as
# modules, rebuild only what changed, install every module into /build/modroot_syms (stripped, depmod'ed).
#   docker run --rm -v gbos-ksrc:/build -v $PWD/kernel:/k:ro gbos-kbuild sh /k/isa_emu_patch/build_syms.sh SYM1 SYM2 ...
# Also put the symbols into configure_whl.py GENERIC so a from-scratch build_generic.sh gets them. bzImage is relinked
# (IKCONFIG embeds the config), but only the new .ko files matter. The previous .config is kept as .config.prev.
set -e
C=/build/inputs/clang-r584948c
export PATH=$C/bin:$PATH LD_LIBRARY_PATH=$C/lib:$LD_LIBRARY_PATH
M="make -C /build/src O=/build/out ARCH=x86_64 LLVM=$C/bin/ CC=$C/bin/clang-22"
cd /build/out
cp .config .config.prev
for s in "$@"; do /build/src/scripts/config --file .config --module $s; done
$M olddefconfig >/dev/null
diff .config.prev .config || true
for s in "$@"; do grep -q "^CONFIG_$s=m" .config || { echo "NOT ENABLED: $s (dependency unmet?)"; exit 1; }; done
$M -j${JOBS:-$(nproc)} bzImage modules 2>&1 | tail -n 5
rm -rf /build/modroot_syms
$M modules_install INSTALL_MOD_PATH=/build/modroot_syms INSTALL_MOD_STRIP=1 >/dev/null 2>&1
echo "modules: $(find /build/modroot_syms -name '*.ko' | wc -l)"
echo BUILD_SYMS_DONE
