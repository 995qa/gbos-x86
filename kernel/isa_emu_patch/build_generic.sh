#!/bin/sh
# Kernel #31 stage 1 (runs in gbos-kbuild with -v gbos-ksrc:/build -v <repo>/kernel:/k):
# generic Intel gen6+ laptop config -> bzImage + all modules -> stripped, depmod'ed trees:
#   /build/modroot_all   every module (goes to usb/modules/ on the stick, loaded by usb/hwdetect.sh)
# The stage0 initramfs keeps only the modules it already had (see build_generic_stage2.sh).
set -e
C=/build/inputs/clang-r584948c
export PATH=$C/bin:$PATH LD_LIBRARY_PATH=$C/lib:$LD_LIBRARY_PATH
M="make -C /build/src O=/build/out ARCH=x86_64 LLVM=$C/bin/ CC=$C/bin/clang-22"
cd /build/out
python3 /k/configure_whl.py --generic .config .config.new && cp .config.new .config
$M olddefconfig >/dev/null
# No forced legacy-HDA: snd_intel_dspcfg picks HDA or SOF per machine (SOF only when it sees DMIC/SoundWire).
/build/src/scripts/config --file /build/out/.config --set-str CMDLINE "$(cat /k/isa_emu_patch/generic_cmdline.txt)"
$M olddefconfig >/dev/null
python3 /k/configure_whl.py --check .config
$M -j${JOBS:-$(nproc)} bzImage modules 2>&1 | tail -n 30
rm -rf /build/modroot_all
$M modules_install INSTALL_MOD_PATH=/build/modroot_all INSTALL_MOD_STRIP=1 >/dev/null 2>&1
echo "modules: $(find /build/modroot_all -name '*.ko' | wc -l), $(du -sh /build/modroot_all | cut -f1)"
echo STAGE1_DONE
