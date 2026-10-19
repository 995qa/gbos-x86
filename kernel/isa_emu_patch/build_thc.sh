#!/bin/sh
# Kernel #34 (gbos-kbuild, -v gbos-ksrc:/build -v <repo>/kernel:/k): #33 + Intel Touch Host Controller modules
# (intel-thc, intel-quickspi, intel-quicki2c: Lunar Lake keyboard/touchpad). Only these three symbols change
# (they are also in configure_whl.py GENERIC, so a from-scratch build_generic.sh gets them too).
# Output: /build/modroot_thc = stripped, depmod'ed tree with every module; the bzImage differs from #33 only by
# the embedded config (IKCONFIG) and the build counter.
set -e
C=/build/inputs/clang-r584948c
export PATH=$C/bin:$PATH LD_LIBRARY_PATH=$C/lib:$LD_LIBRARY_PATH
M="make -C /build/src O=/build/out ARCH=x86_64 LLVM=$C/bin/ CC=$C/bin/clang-22"
cd /build/out
[ -f .config.33 ] || cp .config .config.33
for s in INTEL_THC_HID INTEL_QUICKSPI INTEL_QUICKI2C; do /build/src/scripts/config --file .config --module $s; done
$M olddefconfig >/dev/null
diff .config.33 .config || true
python3 /k/configure_whl.py --check .config
$M -j${JOBS:-$(nproc)} bzImage modules 2>&1 | tail -n 30
rm -rf /build/modroot_thc
$M modules_install INSTALL_MOD_PATH=/build/modroot_thc INSTALL_MOD_STRIP=1 >/dev/null 2>&1
echo "modules: $(find /build/modroot_thc -name '*.ko' | wc -l)"
echo BUILD_THC_DONE
