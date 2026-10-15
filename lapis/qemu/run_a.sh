#!/bin/sh
# Run A: real first-stage init from the init_boot + vendor_boot ramdisks, no disks.
set -e
cd "$(dirname "$0")"
python3 -I cpio_tree.py ../probe/ramdisk/vendor_boot vendor_boot.cpio
cat ../probe/init_boot.cpio vendor_boot.cpio > a.cpio
exec qemu-system-x86_64 -machine q35 -cpu Skylake-Client -m 3072 -smp 2 -nographic -no-reboot -nic none \
  -kernel "${KERNEL:-../../kernel/out_isa/bzImage}" -initrd a.cpio \
  -append "console=ttyS0 8250.nr_uarts=1 loglevel=7 panic=-1 printk.devkmsg=on androidboot.hardware=android-desktop androidboot.slot_suffix=_a androidboot.console=ttyS0 androidboot.selinux=permissive"
