#!/usr/bin/env python3
"""run_mesa_overlay.py KERNEL -- boot KERNEL in QEMU and check that the /vendor/lib64 overlay
that hook.sh builds for the nouveau path (Mesa's EGL) really works on this kernel.

  python3 kernel/isa_emu_test/run_mesa_overlay.py usb/out/BOOTX64.EFI

What it checks (the same steps as usb/hook.sh's gbos_gpu_mesa_install):
  - overlayfs over the vendor's own files (lower) with a tmpfs upper (needs the tmpfs "xattr"
    option: overlayfs stores its metadata in user xattrs on a tmpfs),
  - the Mesa files land in /vendor/lib64/egl, the vendor's own files stay readable and are NOT
    emptied (a tmpfs with bind mounts instead of an overlay empties them: the kernel drops the
    binds when the tmpfs is mounted over the directory they come from),
  - a bind mount over a file of the overlay works (that is how the patched libcrypto is put back).
Prints MESA_OVERLAY_TEST_PASS when all of that holds.
"""
import pathlib, subprocess, sys, tempfile

repo = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(repo / 'lapis/qemu'))
from cpio_tree import pack

init = b'''#!/bin/busybox sh
/bin/busybox --install -s /bin
mount -t proc proc /proc; mount -t sysfs sysfs /sys; mount -t devtmpfs dev /dev
G=/gbos/gbos
NEWROOT=/new
log() { echo "LOG: $*"; }
# a fake vendor partition: a file that must survive the overlay, a directory with a file in it
mkdir -p /new/vendor/lib64/hw
echo "ORIGINAL-LIBZ" > /new/vendor/lib64/libz.so
echo "ORIGINAL-VULKAN" > /new/vendor/lib64/hw/vulkan.intel.so
# the patched library and the manifest that hook.sh uses
mkdir -p $G/patched
echo "PATCHED-LIBZ" > $G/patched/vendor.libz.so
WANT=$(sha256sum /new/vendor/lib64/libz.so | cut -d" " -f1)
cat > $G/patched/MANIFEST <<EOF
early /new/vendor/lib64/libz.so $WANT patched/vendor.libz.so
EOF
# the Mesa files
mkdir -p $G/mesa
for f in libEGL_mesa.so libGLESv1_CM_mesa.so libGLESv2_mesa.so libgallium_dri.so libgbm.so.1; do
  echo "MESA-$f" > $G/mesa/$f
done
# the real code from hook.sh
mkdir -p /tmp
sed -n '/^# --- GPU driver selection/,/^# --- end GPU driver selection ---/p' $G/hook.sh > /tmp/gpu.sh
. /tmp/gpu.sh
gbos_gpu_mesa_install
echo "INSTALL_RC=$?"
echo "--- what is in /new/vendor/lib64 now ---"
ls /new/vendor/lib64
echo "--- the vendor\'s own files ---"
cat /new/vendor/lib64/libz.so
cat /new/vendor/lib64/hw/vulkan.intel.so
echo "--- Mesa\'s EGL ---"
cat /new/vendor/lib64/egl/libEGL_mesa.so 2>&1
cat /new/vendor/lib64/egl/libGLESv2_mesa.so 2>&1
echo "--- the gallium driver ---"
cat /new/vendor/lib64/libgallium_dri.so 2>&1
echo "--- the re-applied patch ---"
cat /new/vendor/lib64/libz.so
echo MESA_OVERLAY_TEST_DONE
poweroff -f
'''

with tempfile.TemporaryDirectory() as tmp:
    t = pathlib.Path(tmp)
    (t / 'gbos/gbos/mesa').mkdir(parents=True)
    (t / 'gbos/gbos/patched').mkdir(parents=True)
    (t / 'gbos/gbos/hook.sh').write_bytes((repo / 'usb/hook.sh').read_bytes())
    for f in ('libEGL_mesa.so', 'libGLESv1_CM_mesa.so', 'libGLESv2_mesa.so', 'libgallium_dri.so', 'libgbm.so.1'):
        src = repo / 'usb/mesa' / f
        if src.exists():
            (t / 'gbos/gbos/mesa' / f).write_bytes(src.read_bytes())
    # /bin/busybox comes from the kernel's own initramfs (the stage0 one), like the other tests
    extra = [('init', 0o100755, init, 0, 0), ('dev', 0o40755, b'', 0, 0), ('proc', 0o40755, b'', 0, 0),
             ('sys', 0o40755, b'', 0, 0), ('new', 0o40755, b'', 0, 0)]
    rd = t / 'rd.cpio'
    rd.write_bytes(pack(str(t), extra=extra))
    cmd = ['qemu-system-x86_64', '-machine', 'q35', '-cpu', 'Skylake-Client', '-m', '2048', '-smp', '2',
           '-nographic', '-no-reboot', '-kernel', sys.argv[1], '-initrd', str(rd),
           '-append', 'console=ttyS0 8250.nr_uarts=1 panic=-1 loglevel=4 rdinit=/init']
    r = subprocess.run(cmd, capture_output=True, text=True, errors='replace', timeout=900)
out = r.stdout + r.stderr
open('mesa_overlay_last.log', 'w').write(out)
lines = [l for l in out.splitlines() if 'warning: TCG' not in l]
print('\n'.join(lines)[-4000:])
text = '\n'.join(lines)
checks = [
    ('INSTALL_RC=0', 'the overlay was installed'),
    ('ORIGINAL-VULKAN', "the vendor's own file survived the overlay"),
    ('MESA-libEGL_mesa.so', "Mesa's EGL is in /vendor/lib64/egl"),
    ('MESA-libgallium_dri.so', 'the gallium driver is in /vendor/lib64'),
    ('PATCHED-LIBZ', 'the patched library was put back over the overlay'),
]
bad = [why for needle, why in checks if needle not in text]
if 'ORIGINAL-LIBZ' in text and 'PATCHED-LIBZ' not in text:
    bad.append('the patched library did not replace the original')
if bad:
    print('MESA_OVERLAY_TEST_FAIL: ' + '; '.join(bad))
    sys.exit(1)
print('MESA_OVERLAY_TEST_PASS')
