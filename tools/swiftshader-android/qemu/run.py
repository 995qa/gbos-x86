#!/usr/bin/env python3
"""Run the SwiftShader HAL smoke test (vktest.c) inside Google's real userspace under QEMU (TCG, no Android init needed).

  run.py HAL.so [--kernel kernel/out_isa/bzImage] [--parts lapis/parts] [--busybox kernel/out/busybox] [--cpu Skylake-Client]
(the kernel, parts and busybox are not in git: see README "Building from scratch"; env KERNEL / PARTS / BUSYBOX work too)

Boots a kernel with a tiny initramfs that mounts Google's system/vendor/product/system_ext erofs images (read-only, as
lapis/qemu/run_b.py does), bind-mounts HAL.so over /vendor/lib64/hw/vulkan.intel.so exactly like hook.sh does, then runs vktest
under Google's bootstrap linker64 in a chroot. Prints VKTEST_PASS (and exits 0) when the HAL opens, enumerates one CPU device with the
Android extensions, runs a queue submission and a compute pipeline (JIT). Needs docker (gbos-swbuild + volume gbos-swsr from
build.sh: NDK, AOSP headers) to compile vktest, and qemu-system-x86_64.
"""
import argparse, os, pathlib, struct, subprocess, sys, tempfile
here = pathlib.Path(__file__).resolve().parent
root = here.parents[2]
sys.path.insert(0, str(root / 'lapis/qemu'))  # cpio_tree.py
from cpio_tree import pack

ap = argparse.ArgumentParser()
ap.add_argument('hal'); ap.add_argument('--kernel', default=os.environ.get('KERNEL', str(root / 'kernel/out_isa/bzImage')))
ap.add_argument('--parts', default=os.environ.get('PARTS', str(root / 'lapis/parts')))
ap.add_argument('--busybox', default=os.environ.get('BUSYBOX', str(root / 'kernel/out/busybox')))
ap.add_argument('--cpu', default='Skylake-Client'); ap.add_argument('--mem', default='3072'); ap.add_argument('--timeout', type=int, default=900)
a = ap.parse_args()
out = pathlib.Path(os.environ.get('OUT', tempfile.mkdtemp(prefix='swrtest.')))
out.mkdir(parents=True, exist_ok=True)

# 1. vktest (bionic, NDK r27c from the gbos-swsr volume)
subprocess.run(['docker', 'run', '--rm', '--platform', 'linux/amd64', '-v', 'gbos-swsr:/w:ro', '-v', f'{here}:/src:ro', '-v', f'{out}:/out', 'gbos-swbuild', 'sh', '-ec', r'''
A=/w/aosp
INC="-I$A/libhardware/include -I$A/libhardware/include_all -I$A/core/libcutils/include -I$A/core/libsystem/include -I$A/native/vulkan/include"
/w/android-ndk-r27c/toolchains/llvm/prebuilt/linux-x86_64/bin/x86_64-linux-android34-clang -O1 -Wall $INC /src/vktest.c -o /out/vktest'''], check=True)

# 2. a compute shader (SPIR-V 1.0): d[gl_GlobalInvocationID.x] = 7*i + 1, local_size_x = 64
ids = {k: i + 1 for i, k in enumerate('main gid arr B var void fn uint v3 pin int c0 c7 c1 pq lbl p i m a q'.split())}
def op(code, *w): return [((len(w) + 1) << 16) | code, *w]
def s(t): b = t.encode() + b'\0'; b += bytes(-len(b) % 4); return list(struct.unpack('<%dI' % (len(b) // 4), b))
ids2 = dict(ids); ids2['pinu'] = len(ids2) + 1; ids2['puu'] = len(ids2) + 1
I = ids2
w = []
w += op(17, 1) + op(14, 0, 1)
w += op(15, 5, I['main'], *s('main'), I['gid']) + op(16, I['main'], 17, 64, 1, 1)
w += op(71, I['gid'], 11, 28) + op(71, I['arr'], 6, 4) + op(72, I['B'], 0, 35, 0) + op(71, I['B'], 3)
w += op(71, I['var'], 34, 0) + op(71, I['var'], 33, 0)
w += op(19, I['void']) + op(33, I['fn'], I['void']) + op(21, I['uint'], 32, 0) + op(23, I['v3'], I['uint'], 3)
w += op(32, I['pin'], 1, I['v3']) + op(59, I['pin'], I['gid'], 1)
w += op(29, I['arr'], I['uint']) + op(30, I['B'], I['arr']) + op(32, I['pq'], 2, I['B']) + op(59, I['pq'], I['var'], 2)
w += op(21, I['int'], 32, 1) + op(43, I['int'], I['c0'], 0) + op(43, I['uint'], I['c7'], 7) + op(43, I['uint'], I['c1'], 1)
w += op(32, I['pinu'], 1, I['uint']) + op(32, I['puu'], 2, I['uint'])
w += op(54, I['void'], I['main'], 0, I['fn']) + op(248, I['lbl'])
w += op(65, I['pinu'], I['p'], I['gid'], I['c0'])           # &gid.x  (index 0, written as component via int constant)
w += op(61, I['uint'], I['i'], I['p'])
w += op(132, I['uint'], I['m'], I['i'], I['c7']) + op(128, I['uint'], I['a'], I['m'], I['c1'])
w += op(65, I['puu'], I['q'], I['var'], I['c0'], I['i']) + op(62, I['q'], I['a']) + op(253) + op(56)
spv = [0x07230203, 0x00010000, 0, len(ids2) + 1, 0] + w
(out / 'test.spv').write_bytes(struct.pack('<%dI' % len(spv), *spv))

# 3. initramfs and QEMU
init = r'''#!/bin/busybox sh
export PATH=/bin:/sbin
/bin/busybox --install -s /bin
mount -t proc proc /proc; mount -t sysfs sysfs /sys; mount -t tmpfs -o mode=0755 tmpfs /dev
mknod -m 666 /dev/null c 1 3; mknod -m 666 /dev/zero c 1 5; mknod -m 666 /dev/random c 1 8; mknod -m 666 /dev/urandom c 1 9
mknod -m 600 /dev/console c 5 1; mknod -m 666 /dev/tty c 5 0; mknod -m 600 /dev/kmsg c 1 11
exec >/dev/console 2>&1
for d in /sys/block/*; do n=${d##*/}; [ -f $d/dev ] && mknod /dev/$n b $(cat $d/dev | tr ':' ' '); done
find_disk() { for d in /sys/block/nvme*; do [ "$(cat $d/device/serial 2>/dev/null | tr -d ' ')" = "$1" ] && echo /dev/${d##*/} && return; done; }
mkdir -p /new
mount -t erofs -o ro $(find_disk system) /new || { echo "VKTEST_FAIL mount system"; poweroff -f; }
for p in vendor product system_ext; do mount -t erofs -o ro $(find_disk $p) /new/$p || echo "mount $p failed"; done
mount --bind /dev /new/dev; mount --bind /proc /new/proc; mount --bind /sys /new/sys
mount -t tmpfs -o mode=0755 tmpfs /new/mnt; mkdir -p /new/mnt/t; mount --bind /t /new/mnt/t
# exactly what hook.sh does:
mount --bind /t/vulkan.swiftshader.so /new/vendor/lib64/hw/vulkan.intel.so && echo "bound HAL over vulkan.intel.so"
echo "VKTEST_START"
LD_LIBRARY_PATH=/system/lib64/bootstrap:/system/lib64:/vendor/lib64 chroot /new /system/bin/bootstrap/linker64 /mnt/t/vktest /vendor/lib64/hw/vulkan.intel.so /mnt/t/test.spv
echo "VKTEST_EXIT=$?"
poweroff -f
'''
files = [('dev', 0o40755, b'', 0, 0), ('dev/console', 0o20600, b'', 5, 1), ('proc', 0o40755, b'', 0, 0), ('sys', 0o40755, b'', 0, 0),
         ('bin', 0o40755, b'', 0, 0), ('new', 0o40755, b'', 0, 0), ('t', 0o40755, b'', 0, 0),
         ('bin/busybox', 0o100755, pathlib.Path(a.busybox).read_bytes(), 0, 0), ('init', 0o100755, init.encode(), 0, 0),
         ('t/vktest', 0o100755, (out / 'vktest').read_bytes(), 0, 0), ('t/test.spv', 0o100644, (out / 'test.spv').read_bytes(), 0, 0),
         ('t/vulkan.swiftshader.so', 0o100755, pathlib.Path(a.hal).read_bytes(), 0, 0)]
with tempfile.TemporaryDirectory() as t:
    (out / 'rd.cpio').write_bytes(pack(t, extra=files))
parts = pathlib.Path(a.parts)
disks = [('system', 'system_a'), ('vendor', 'vendor_a'), ('product', 'product_a'), ('system_ext', 'system_ext_a')]
cmd = ['qemu-system-x86_64', '-machine', 'q35', '-cpu', a.cpu, '-m', a.mem, '-smp', '4', '-nographic', '-no-reboot', '-nic', 'none',
       '-kernel', a.kernel, '-initrd', str(out / 'rd.cpio'),
       '-append', 'console=ttyS0 8250.nr_uarts=1 loglevel=4 panic=-1 rdinit=/init']
for i, (serial, img) in enumerate(disks):
    cmd += ['-drive', f'if=none,id=d{i},file={parts / (img + ".img")},format=raw,readonly=on', '-device', f'nvme,drive=d{i},serial={serial}']
log = out / 'qemu.log'
try:
    r = subprocess.run(cmd, stdout=open(log, 'wb'), stderr=subprocess.STDOUT, timeout=a.timeout)
except subprocess.TimeoutExpired:
    print('timeout'); 
txt = log.read_bytes().decode(errors='replace')
i = txt.find('VKTEST_START')
print(txt[i if i >= 0 else -3000:][-6000:])
print('log:', log)
sys.exit(0 if 'VKTEST_PASS' in txt else 1)
