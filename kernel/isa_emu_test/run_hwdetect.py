#!/usr/bin/env python3
"""run_hwdetect.py KERNEL -- boot KERNEL in QEMU (q35 + Intel HDA + e1000e + USB) with usb/modules and usb/hwdetect.sh
in the initramfs, run gbos_hwdetect, print hwdetect.txt. Checks that modalias coldplug loads the right drivers."""
import pathlib, subprocess, sys, tempfile
repo = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(repo / 'lapis/qemu'))
from cpio_tree import pack
init = b'''#!/bin/busybox sh
/bin/busybox --install -s /bin
mount -t proc proc /proc; mount -t sysfs sysfs /sys; mount -t devtmpfs dev /dev
G=/gbos/gbos; L=/tmp/L; mkdir -p $L
log() { echo "LOG: $*"; }
. $G/hwdetect.sh
gbos_hwdetect 6
echo ==== REPORT; cat $L/hwdetect.txt | head -120
echo HWDETECT_TEST_DONE
poweroff -f
'''
with tempfile.TemporaryDirectory() as tmp:
    t = pathlib.Path(tmp)
    (t / 'gbos/gbos').mkdir(parents=True)
    (t / 'gbos/gbos/modules').symlink_to(repo / 'usb/modules')  # os.walk below follows via copy
    import shutil
    shutil.rmtree(t / 'gbos'); shutil.copytree(repo / 'usb/modules', t / 'gbos/gbos/modules')
    shutil.copy(repo / 'usb/hwdetect.sh', t / 'gbos/gbos/hwdetect.sh')
    extra = [('init', 0o100755, init, 0, 0), ('dev', 0o40755, b'', 0, 0), ('proc', 0o40755, b'', 0, 0), ('sys', 0o40755, b'', 0, 0)]
    rd = t / 'rd.cpio'; rd.write_bytes(pack(str(t / 'gbos').rsplit('/gbos', 1)[0] if False else str(t), extra=extra))
    cmd = ['qemu-system-x86_64', '-machine', 'q35', '-cpu', 'Skylake-Client', '-m', '2048', '-smp', '2', '-nographic', '-no-reboot',
           '-nic', 'user,model=e1000e', '-device', 'intel-hda', '-device', 'hda-duplex', '-device', 'qemu-xhci', '-device', 'usb-kbd',
           '-kernel', sys.argv[1], '-initrd', str(rd), '-append', 'console=ttyS0 8250.nr_uarts=1 panic=-1 loglevel=4 rdinit=/init']
    r = subprocess.run(cmd, capture_output=True, text=True, errors='replace', timeout=900)
out = r.stdout + r.stderr
open('hwdetect_last.log', 'w').write(out)
print('\n'.join(l for l in out.splitlines() if 'warning: TCG' not in l)[-6000:])
