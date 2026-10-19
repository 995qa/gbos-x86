#!/usr/bin/env python3
"""run_ksu_qemu.py KERNEL [--keep] -- boot KERNEL in QEMU and check that KernelSU came up.

The kernel is booted with a tiny initramfs (busybox + a script that prints the kernel log and
powers off). What is checked:
  * "welcome to KernelSU version <N>" and the version is one the manager app accepts (>= 32513)
  * the syscall dispatcher was patched ("dispatcher installed at slot N") and the hooks are in
  * no "X86_FEATURE_INDIRECT_SAFE is not enabled" abort (that is what KernelSU does when the
    syscall dispatcher patch is missing)

Usage: python3 kernel/isa_emu_test/run_ksu_qemu.py usb/out/BOOTX64.EFI
"""
import pathlib
import re
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[1]

INIT = r"""#!/bin/sh
/bin/busybox --install -s /bin 2>/dev/null
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t devtmpfs devtmpfs /dev 2>/dev/null
echo "=== KSUTEST BEGIN ==="
dmesg | grep -iE "kernelsu|ksu|ksud|sys_call_table|dispatcher|syscall hook|X86_FEATURE" > /dev/ksu.log
cat /dev/ksu.log
echo "=== KSUTEST END ==="
poweroff -f
"""


def cpio(files):
    """newc cpio of (name, mode, data) entries."""
    out = bytearray()
    ino = [1000]

    def ent(name, mode, data=b""):
        raw = name.encode() + b"\0"
        ino[0] += 1
        f = [ino[0], mode, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(raw), 0]
        out.extend(b"070701" + b"".join(b"%08x" % n for n in f) + raw)
        out.extend(bytes(-len(out) % 4))
        out.extend(data)
        out.extend(bytes(-len(out) % 4))

    for name, mode, data in files:
        ent(name, mode, data)
    ent("TRAILER!!!", 0)
    return bytes(out)


def main() -> int:
    kernel = sys.argv[1] if len(sys.argv) > 1 else str(ROOT / "usb/out/BOOTX64.EFI")
    busybox = ROOT / "kernel/out/busybox"
    if not busybox.exists():
        print("no busybox (kernel/out/busybox): run tools/fetch_busybox.sh")
        return 2
    files = [
        ("dev", 0o40755, b""),
        ("proc", 0o40755, b""),
        ("sys", 0o40755, b""),
        ("bin", 0o40755, b""),
        ("dev/console", 0o20600, b""),
        ("bin/busybox", 0o100755, busybox.read_bytes()),
        # the kernel runs /init through the script's interpreter, so /bin/sh has to exist
        ("bin/sh", 0o100755, busybox.read_bytes()),
        ("init", 0o100755, INIT.encode()),
    ]
    with tempfile.TemporaryDirectory() as tmp:
        rd = pathlib.Path(tmp) / "rd.cpio"
        rd.write_bytes(cpio(files))
        cmd = ["qemu-system-x86_64", "-machine", "q35", "-cpu", "Skylake-Client", "-m", "1024",
               "-smp", "2", "-nographic", "-no-reboot", "-nic", "none", "-kernel", kernel,
               "-initrd", str(rd), "-append",
               "console=ttyS0 8250.nr_uarts=1 panic=-1 loglevel=7 rdinit=/init"]
        r = subprocess.run(cmd, capture_output=True, text=True, errors="replace", timeout=300)
    out = r.stdout + r.stderr
    (ROOT / "kernel/isa_emu_test/last_ksu.log").write_text(out)

    fails = 0

    def check(cond, what):
        nonlocal fails
        print(("ok   " if cond else "FAIL ") + what)
        if not cond:
            fails += 1

    m = re.search(r"welcome to KernelSU version (\d+)", out)
    check(bool(m), "KernelSU announces itself" + ("" if m else " (no 'welcome to KernelSU version' in the log)"))
    if m:
        version = int(m.group(1))
        check(version >= 32513,
              "kernel version %d is one the manager app accepts (>= 32513)" % version)
    check("dispatcher installed at slot" in out, "the x86_64 syscall dispatcher was patched")
    check("registered syscall hook" in out, "the syscall hooks were registered")
    check("X86_FEATURE_INDIRECT_SAFE is not enabled" not in out,
          "KernelSU did not abort for a missing dispatcher patch")
    check("KSUTEST END" in out, "the test program ran to the end")
    print("%d check(s) failed" % fails)
    print("KSU_QEMU_TEST_PASS" if not fails else "KSU_QEMU_TEST_FAIL")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
