#!/usr/bin/env python3
"""Run B: boot lapis second-stage userspace from the real partition images on the isa-emu kernel."""
import os, pathlib, subprocess, sys
here = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(here))
from cpio_tree import pack
parts = here.parent / 'parts'
patched = here.parent / 'patched'
use_patched = os.environ.get('PATCHED', '') == '1'
def image(name):
    p = patched / (name + '.img')
    return p if use_patched and p.exists() else parts / (name + '.img')
kernel = os.environ.get('KERNEL', str(here.parent.parent / 'kernel/out_isa/bzImage'))
busybox = (here.parent.parent / 'kernel/out/busybox').read_bytes()
timeout = int(os.environ.get('TIMEOUT', '240'))
mem = os.environ.get('MEM', '4096')
disks = [('system', 'system_a'), ('vendor', 'vendor_a'), ('product', 'product_a'),
         ('system_ext', 'system_ext_a'), ('system_dlkm', 'system_dlkm_a'), ('vendor_dlkm', 'vendor_dlkm_a'),
         ('dm_system', 'system_a'), ('dm_vendor', 'vendor_a'), ('dm_product', 'product_a'), ('dm_system_ext', 'system_ext_a')]
script = r'''#!/bin/busybox sh
export PATH=/bin:/sbin
/bin/busybox --install -s /bin
mount -t proc proc /proc; mount -t sysfs sysfs /sys; mount -t tmpfs -o mode=0755 tmpfs /dev
mknod -m 666 /dev/null c 1 3; mknod -m 666 /dev/zero c 1 5; mknod -m 666 /dev/full c 1 7
mknod -m 666 /dev/random c 1 8; mknod -m 666 /dev/urandom c 1 9; mknod -m 600 /dev/kmsg c 1 11
mknod -m 666 /dev/tty c 5 0; mknod -m 600 /dev/console c 5 1; mknod -m 666 /dev/ptmx c 5 2
mknod -m 660 /dev/loop-control c 10 237; for i in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do mknod -m 660 /dev/loop$i b 7 $i; done
mkdir -p -m 0755 /dev/socket /dev/block /dev/pts /dev/dm-user
exec >/dev/console 2>&1
for d in /sys/block/*; do n=${d##*/}; [ -f $d/dev ] && mknod /dev/$n b $(cat $d/dev | tr ':' ' '); done
echo "B: stage0 started"
sleep 1
find_disk() { for d in /sys/block/nvme*; do [ "$(cat $d/device/serial 2>/dev/null | tr -d ' ')" = "$1" ] && echo /dev/${d##*/} && return; done; }
mkdir -p /new
SYS=$(find_disk system); echo "system=$SYS"
mount -t erofs -o ro $SYS /new || { echo "B: mount system failed"; exec sh; }
for p in vendor product system_ext system_dlkm vendor_dlkm; do
  D=$(find_disk $p); mkdir -p /new/$p
  mount -t erofs -o ro $D /new/$p && echo "B: mounted $p from $D" || echo "B: mount $p failed"
done
mkdir -p /dev/mapper; mknod -m 600 /dev/mapper/control c 10 236; mknod -m 600 /dev/device-mapper c 10 236
mount --bind /dev /new/dev; mount --bind /proc /new/proc; mount --bind /sys /new/sys
for p in system:system_a vendor:vendor_a product:product_a system_ext:system_ext_a; do
  n=${p%%:*}; D=$(find_disk dm_$n); sz=$(cat /sys/block/${D##*/}/size)
  echo "B: dmctl create ${p##*:} -ro linear 0 $sz $D 0"
  LD_LIBRARY_PATH=/system/lib64/bootstrap:/system/lib64 chroot /new /system/bin/bootstrap/linker64 /system/bin/dmctl create ${p##*:} -ro linear 0 $sz $D 0 2>&1 | grep -v linkerconfig; echo "B: dm ${p##*:} rc=$?"
done
umount /new/sys; umount /new/proc; umount /new/dev
grep -q stage0only /proc/cmdline && { echo B: stage0only done; poweroff -f; }
mount -t tmpfs -o mode=0771 tmpfs /new/data
mount -t tmpfs tmpfs /new/metadata
mount -t devpts devpts /dev/pts -o mode=0620,ptmxmode=0666 2>/dev/null
mount --move /dev /new/dev; mount --move /proc /new/proc; mount --move /sys /new/sys
mount -t selinuxfs selinuxfs /new/sys/fs/selinux
mount -t tmpfs -o mode=0755 tmpfs /new/mnt
mount -t tmpfs -o mode=0755 tmpfs /new/debug_ramdisk
mount -t tmpfs -o mode=0755 tmpfs /new/second_stage_resources
echo "B: switching root, exec /system/bin/init selinux_setup"
exec switch_root /new /system/bin/init selinux_setup
'''
files = [('dev', 0o40755, b'', 0, 0), ('dev/console', 0o20600, b'', 5, 1), ('proc', 0o40755, b'', 0, 0),
         ('sys', 0o40755, b'', 0, 0), ('bin', 0o40755, b'', 0, 0), ('new', 0o40755, b'', 0, 0),
         ('bin/busybox', 0o100755, busybox, 0, 0), ('init', 0o100755, script.encode(), 0, 0)]
import tempfile
with tempfile.TemporaryDirectory() as t:
    cpio = pack(t, extra=files)
    (here / 'b.cpio').write_bytes(cpio)
cmd = ['qemu-system-x86_64', '-machine', 'q35', '-cpu', os.environ.get('CPU', 'Skylake-Client'), '-m', mem, '-smp', os.environ.get('SMP', '4'),
       '-nographic', '-no-reboot', '-nic', 'none', '-kernel', kernel, '-initrd', str(here / 'b.cpio'),
       '-append', 'console=ttyS0 8250.nr_uarts=1 loglevel=7 panic=-1 printk.devkmsg=on rdinit=/init '
                  'androidboot.hardware=android-desktop androidboot.slot_suffix=_a androidboot.console=ttyS0 '
                  'androidboot.verifiedbootstate=orange androidboot.selinux=permissive ' + os.environ.get('EXTRA', '')]
for i, (serial, img) in enumerate(disks):
    cmd += ['-drive', 'if=none,id=d%d,file=%s,format=raw,readonly=on' % (i, image(img)),
            '-device', 'nvme,drive=d%d,serial=%s' % (i, serial)]
log = open(here / ('b.log' if len(sys.argv) < 2 else sys.argv[1]), 'wb')
try:
    subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT, timeout=timeout)
except subprocess.TimeoutExpired:
    log.write(b'\n[run_b: timeout]\n')
