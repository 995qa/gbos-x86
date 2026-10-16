# gbOS86 NVMe installer/updater. Sourced by stage0 for menu choice 2 (or gbos.cfg MODE=install), after the
# stick is mounted at /gbos ($G=/gbos/gbos, log dir $L, stick partition $DEV) and drivers loaded.
#
# ERASES THE WHOLE TARGET NVMe and lays it out as:
#   p1 GBOS_EFI   512 MiB FAT32, EFI system partition: EFI/BOOT/BOOTX64.EFI (this kernel + stage0)
#   p2 GBOSSYS      8 GiB FAT32: gbos/ as on the stick (super.img, hook.sh, firmware, ...)
#   p3 GBOS_META   64 MiB ext4: Android /metadata
#   p4 GBOS_DATA   rest   ext4: Android /data
# Nothing is written until the disk's serial number is typed. Every copied file is checked with
# sha256 after being read back from the disk. Never returns: powers off or waits on failure.

I=$G/installer
tool() { $I/lib/ld-musl-x86_64.so.1 --library-path $I/lib $I/bin/"$@"; }
TTY=/dev/tty1
say() { echo "$*" > $TTY; echo "$*" >> $L/install.log; log "install: $*"; }
halt_here() { say ""; say "$1"; say "Power off with the power button."; sync; while true; do sleep 3600; done; }
# save_logs MOUNTED_GBOS_DIR [BOOTS]: copy the installed system's last BOOTS (default 3) boot-N log dirs to
# this boot's log dir on the stick (gbos/logs/boot-N/nvme-logs). A file FAT can't read in full (cluster chain
# cut short by a power-off) is copied with dd conv=noerror,sync instead of failing; the tail is then NULs.
save_logs() {
  mkdir -p $L/nvme-logs
  for b in $(ls $1/logs | sort -t- -k2 -n | tail -n ${2:-3}); do
    say "  $b"
    (cd $1/logs && find $b -type d) | while read d; do mkdir -p $L/nvme-logs/$d; done
    (cd $1/logs && find $b -type f) | while read f; do
      cp $1/logs/$f $L/nvme-logs/$f 2>/dev/null || dd if=$1/logs/$f of=$L/nvme-logs/$f bs=4k conv=noerror,sync 2>/dev/null
    done
  done
  sync
}
die() { halt_here "INSTALL FAILED: $*  (log: gbos/logs/boot-$N/install.log on the stick)"; }
ask() { printf '%s' "$1" > $TTY; read -r REPLY < $TTY; echo "$1$REPLY" >> $L/install.log; }
check() { a=$(sha256sum "$1" | cut -d' ' -f1); b=$(sha256sum "$2" | cut -d' ' -f1); [ "$a" = "$b" ] || die "verify failed: $2"; echo "ok $a $2" >> $L/install.log; }

# Optional local AI replacement for Google's AICore (the stock one needs hardware attestation this laptop can't do).
# Asked on every install and every update. LOCAL_AI=1/0 in the stick's gbos.cfg answers without asking; a test run
# with gbos_install_confirm= on the kernel command line never asks and says no. Yes needs gbos/localai/localai.apk
# and llama-server on the stick, plus model.gguf there or already on the installed system. No removes it again.
# localai_step MOUNTED_GBOSSYS DATA_PARTITION: sets LOCAL_AI to what the installed gbos.cfg should say.
localai_step() {
  _sys=$1; _data=$2; _ans=$LOCAL_AI
  _conf=$(sed -n 's/.*gbos_install_confirm=\([^ ]*\).*/\1/p' /proc/cmdline)
  if [ -z "$_ans" ]; then
    if [ -n "$_conf" ]; then _ans=0; else
      say ""
      say "Optional: local AI replacement. Magic Pointer suggestions run on a model on this laptop's CPU instead of Google's"
      say "servers (which refuse this laptop). Needs about 3.4 GB on the SSD and is slow on this CPU. Answering n removes it."
      ask "Install or keep the local AI replacement? [y/N] "
      case "$REPLY" in y|Y|yes|YES) _ans=1;; *) _ans=0;; esac
    fi
  fi
  mkdir -p /mnt/ndata
  if [ "$_ans" != 1 ]; then
    if mount -t ext4 "$_data" /mnt/ndata 2>/dev/null; then rm -rf /mnt/ndata/gbos-localai; umount /mnt/ndata; fi
    rm -rf "$_sys/gbos/localai"; LOCAL_AI=0; say "Local AI replacement: off"; return 0
  fi
  LOCAL_AI=0
  _lf="localai.apk llama-server prep.sh run.sh diag.sh"   # everything hook.sh and the init services run
  for f in $_lf; do
    [ -f $G/localai/$f ] || { say "Local AI replacement skipped: gbos/localai/$f is not on the stick"; return 0; }
  done
  mount -t ext4 "$_data" /mnt/ndata 2>/dev/null || { say "Local AI replacement skipped: cannot mount $_data"; return 0; }
  mkdir -p /mnt/ndata/gbos-localai
  M=/mnt/ndata/gbos-localai/model.gguf
  if [ -f $G/localai/model.gguf ]; then
    _need=$(( $(stat -c %s $G/localai/model.gguf) / 1048576 + 300 ))
    _have=$(df -m /mnt/ndata | awk 'NR==2{print $4}')
    if [ -f $M ] && [ "$(stat -c %s $M)" = "$(stat -c %s $G/localai/model.gguf)" ]; then
      say "  model already on the SSD"
    elif [ "$_have" -lt "$_need" ]; then
      umount /mnt/ndata; say "Local AI replacement skipped: needs $_need MB free on the SSD, has $_have MB"; return 0
    else
      say "  copying the model ($(( $(stat -c %s $G/localai/model.gguf) / 1048576 )) MiB) ..."
      cp $G/localai/model.gguf $M.part && mv $M.part $M || { rm -f $M.part; umount /mnt/ndata; say "Local AI replacement skipped: copying the model failed"; return 0; }
    fi
  elif [ ! -f $M ]; then
    umount /mnt/ndata; say "Local AI replacement skipped: no gbos/localai/model.gguf on the stick or the SSD"; return 0
  fi
  # Optional: Magic Pointer patched to need only text queries (localai/build_gpointer.sh, ~235 MB, Google's app so never shipped
  # in the image). Lives on the data partition as a read-only file that prep.sh binds over the system copy.
  P=/mnt/ndata/gbos-localai/gpointer.apk
  if [ -f $G/localai/gpointer.apk ]; then
    _gs=$(stat -c %s $G/localai/gpointer.apk)
    if [ -f $P ] && [ "$(stat -c %s $P)" = "$_gs" ] && cmp -s $G/localai/gpointer.apk $P; then
      say "  patched Magic Pointer already on the SSD"
    elif [ "$(df -m /mnt/ndata | awk 'NR==2{print $4}')" -lt $(( _gs / 1048576 + 100 )) ]; then
      say "  patched Magic Pointer skipped: not enough free space on the SSD"; rm -f $P
    else
      say "  copying the patched Magic Pointer ($(( _gs / 1048576 )) MiB) ..."
      rm -f $P; cp $G/localai/gpointer.apk $P.part && mv $P.part $P || { rm -f $P.part $P; say "  patched Magic Pointer: copy failed, skipped"; }
    fi
    [ -f $P ] && chmod 444 $P
  else
    rm -f $P
  fi
  rm -rf "$_sys/gbos/localai"; mkdir -p "$_sys/gbos/localai"
  for f in $_lf; do
    cp $G/localai/$f "$_sys/gbos/localai/" || { umount /mnt/ndata; say "Local AI replacement skipped: copying $f failed"; return 0; }
  done
  chmod 644 $M; chmod 755 /mnt/ndata/gbos-localai
  sync; echo 3 > /proc/sys/vm/drop_caches
  [ -f $G/localai/model.gguf ] && { say "  verifying the model ..."; check $G/localai/model.gguf $M; }
  [ -f $G/localai/gpointer.apk ] && [ -f $P ] && check $G/localai/gpointer.apk $P
  for f in $_lf; do check $G/localai/$f "$_sys/gbos/localai/$f"; done
  umount /mnt/ndata
  LOCAL_AI=1; say "Local AI replacement: on"
}
# Write the installed system's gbos.cfg from the stick's: boots normally, remembers the local AI answer.
write_installed_cfg() {
  grep -v -e '^MODE=' -e '^ACTION=' -e '^LOCAL_AI=' $G/gbos.cfg > /mnt/nsys/gbos/gbos.cfg
  echo 'MODE=boot' >> /mnt/nsys/gbos/gbos.cfg; echo "LOCAL_AI=${LOCAL_AI:-0}" >> /mnt/nsys/gbos/gbos.cfg
}

chvt 1 2>/dev/null
clear > $TTY 2>/dev/null
say "=============================================================="
say " gbOS86 installer"
say "=============================================================="

# Everything this needs must be on the stick before anything is touched.
STICKDISK=$(basename $(readlink -f /sys/class/block/${DEV##*/}/..))
EFIPART=/dev/$(ls /sys/class/block/$STICKDISK | grep -m1 "^${STICKDISK}p\?1$")
mkdir -p /mnt/stickefi && mount -t vfat -o ro $EFIPART /mnt/stickefi 2>/dev/null \
  || die "cannot mount the stick's EFI partition ($EFIPART)"
KERNEL=/mnt/stickefi/EFI/BOOT/BOOTX64.EFI
FILES="super.img super.layout hook.sh aidiag.sh early_patch.sh hwdetect.sh apex_patch.sh crossystem bootdisk.img libkm_compat.so system_ext_manifest.xml soft_gk"
DIRS="firmware patched audio installer kmod modules"
for f in $FILES; do [ -f $G/$f ] || die "missing gbos/$f on the stick"; done
for d in $DIRS; do [ -d $G/$d ] || die "missing gbos/$d/ on the stick"; done
[ -f $KERNEL ] || die "missing EFI/BOOT/BOOTX64.EFI on the stick's EFI partition"
tool sfdisk --version > /dev/null 2>&1 || die "partitioning tools in gbos/installer/ don't run"

# ACTION=update in gbos.cfg: don't erase anything. Save the installed system's last 3 boots of logs
# to this boot's log dir on the stick, then bring its gbos/ files and kernel up to the stick's.
# GBOS_DATA and GBOS_META (apps, accounts, settings) are not touched.
NSYS=$(findfs LABEL=GBOSSYS 2>/dev/null); NEFI=$(findfs LABEL=GBOS_EFI 2>/dev/null); NDATA=$(findfs LABEL=GBOS_DATA 2>/dev/null)
if [ -z "$ACTION" ] && [ -n "$NSYS" ] && [ -n "$NEFI" ] && [ -n "$NDATA" ]; then
  # An install exists: never erase it just because the stick was left in. Ask.
  say "Found an existing gbOS86 install on the NVMe."
  say "  1) Update it: keep apps, accounts and settings; save its logs to this stick"
  say "  2) Reinstall: ERASE the NVMe and install from scratch"
  say "  3) Only save its logs to this stick (nothing on the NVMe is changed)"
  say "  anything else: cancel"
  ask "choice> "
  case "$REPLY" in 1) ACTION=update;; 2) ACTION=install;; 3) ACTION=logs;; *) halt_here "Cancelled. Nothing was written.";; esac
fi
# ACTION=logs (menu choice 3, or ACTION=logs in gbos.cfg): read-only on the NVMe, takes seconds.
# LOG_BOOTS in gbos.cfg = how many of the installed system's last boots to copy (default 3).
if [ "$ACTION" = logs ]; then
  [ -n "$NSYS" ] || die "no gbos install on the NVMe (GBOSSYS not found)"
  mkdir -p /mnt/nsys
  mount -t vfat -o ro $NSYS /mnt/nsys || die "mount GBOSSYS failed"
  [ -d /mnt/nsys/gbos/logs ] || die "the installed system has no gbos/logs"
  say "Saving the installed system's last ${LOG_BOOTS:-3} boots of logs to the stick (gbos/logs/boot-$N/nvme-logs) ..."
  save_logs /mnt/nsys/gbos ${LOG_BOOTS:-3}
  umount /mnt/nsys; sync
  say ""
  say "Logs saved. Remove the USB stick and turn the laptop back on."
  log "install: logs saved"; sync
  ask "Press Enter to power off. "
  poweroff -f
fi
if [ "${ACTION:-install}" = update ]; then
  NSYS=$(findfs LABEL=GBOSSYS 2>/dev/null); NEFI=$(findfs LABEL=GBOS_EFI 2>/dev/null)
  [ -n "$NSYS" ] && [ -n "$NEFI" ] || die "no gbos install on the NVMe (GBOSSYS/GBOS_EFI not found)"
  mkdir -p /mnt/nsys /mnt/nefi
  mount -t vfat -o flush $NSYS /mnt/nsys || die "mount GBOSSYS failed"
  mount -t vfat $NEFI /mnt/nefi || die "mount GBOS_EFI failed"
  say "Saving the installed system's logs to the stick (gbos/logs/boot-$N/nvme-logs) ..."
  save_logs /mnt/nsys/gbos 3
  say "Updating the installed system (data is not touched) ..."
  for f in $FILES; do cmp -s $G/$f /mnt/nsys/gbos/$f || { say "  $f"; cp $G/$f /mnt/nsys/gbos/$f || die "copy $f failed"; }; done
  for d in $DIRS; do rm -rf /mnt/nsys/gbos/$d; cp -r $G/$d /mnt/nsys/gbos/ || die "copy $d/ failed"; done
  cmp -s $KERNEL /mnt/nefi/EFI/BOOT/BOOTX64.EFI || { say "  kernel"; cp $KERNEL /mnt/nefi/EFI/BOOT/BOOTX64.EFI || die "copy kernel failed"; }
  localai_step /mnt/nsys "$NDATA"
  # Settings such as DENSITY follow the stick; the installed copy always boots normally.
  write_installed_cfg
  sync; echo 3 > /proc/sys/vm/drop_caches
  say "Verifying ..."
  check $KERNEL /mnt/nefi/EFI/BOOT/BOOTX64.EFI
  for f in $FILES; do check $G/$f /mnt/nsys/gbos/$f; done
  for d in $DIRS; do (cd $G && find $d -type f) | while read f; do check $G/$f /mnt/nsys/gbos/$f; done || exit 1; done || die "verify failed"
  umount /mnt/nefi /mnt/nsys /mnt/stickefi; sync
  say ""
  say "Update done. Remove the USB stick and turn the laptop back on."
  log "install: update complete"; sync
  ask "Press Enter to power off. "
  poweroff -f
fi

# Target: an internal NVMe namespace, never the stick.
set -- $(ls /sys/block | grep '^nvme[0-9]*n[0-9]*$')
[ $# -ge 1 ] || die "no NVMe disk found (block devices: $(ls /sys/block | tr '\n' ' '))"
[ $# -eq 1 ] || die "more than one NVMe disk ($*); this installer only handles one"
T=$1; TD=/dev/$T
[ "$T" != "$STICKDISK" ] || die "target $T is the stick"
CTRL=/sys/block/$T/device
MODEL=$(cat $CTRL/model 2>/dev/null | sed 's/ *$//'); SERIAL=$(cat $CTRL/serial 2>/dev/null | sed 's/^ *//; s/ *$//')
SIZE=$(( $(cat /sys/block/$T/size) * 512 )); GB=$(( SIZE / 1000000000 ))
[ -n "$SERIAL" ] || die "cannot read the serial number of $T"
[ $GB -ge 24 ] || die "$T is only ${GB} GB; need at least 24 GB"

say ""
say "Target disk: $TD"
say "  model:  $MODEL"
say "  serial: $SERIAL"
say "  size:   ${GB} GB"
say "  current partitions: $(ls /sys/block/$T | grep "^${T}p" | tr '\n' ' ')"
say ""
say "EVERYTHING ON THIS DISK WILL BE ERASED (Windows, files, all partitions)."
say "To continue, type the serial number exactly as shown. Anything else cancels."
CONFIRM=$(sed -n 's/.*gbos_install_confirm=\([^ ]*\).*/\1/p' /proc/cmdline)
if [ -n "$CONFIRM" ]; then
  REPLY=$CONFIRM; say "(serial taken from the kernel command line: $REPLY)"
else
  ask "serial> "
fi
[ "$REPLY" = "$SERIAL" ] || halt_here "Cancelled. Nothing was written to $TD."

# Keep the old install's recent logs (best effort) before they're erased.
if [ -n "$NSYS" ] && mkdir -p /mnt/oldsys && mount -t vfat -o ro $NSYS /mnt/oldsys 2>/dev/null; then
  mkdir -p $L/nvme-logs
  for b in $(ls /mnt/oldsys/gbos/logs 2>/dev/null | sort -t- -k2 -n | tail -3); do cp -r /mnt/oldsys/gbos/logs/$b $L/nvme-logs/ 2>/dev/null; done
  say "Saved the old install's logs to gbos/logs/boot-$N/nvme-logs on the stick."
  umount /mnt/oldsys
fi

say ""
say "Erasing and partitioning $TD ..."
for p in $(ls /sys/block/$T | grep "^${T}p"); do umount /dev/$p 2>/dev/null; done
# Clear old signatures at both ends (the backup GPT lives at the end).
dd if=/dev/zero of=$TD bs=1M count=16 conv=fsync 2>/dev/null
dd if=/dev/zero of=$TD bs=1M count=16 seek=$(( SIZE / 1048576 - 16 )) conv=fsync 2>/dev/null
tool sfdisk --wipe always --wipe-partitions always $TD >> $L/install.log 2>&1 <<EOF || die "sfdisk failed"
label: gpt
size=512MiB, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="GBOS_EFI"
size=8GiB, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name="GBOSSYS"
size=64MiB, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="GBOS_META"
type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="GBOS_DATA"
EOF
blockdev --rereadpt $TD 2>/dev/null; sleep 2; mdev -s
P=${TD}p
for i in 1 2 3 4; do [ -b $P$i ] || { sleep 2; mdev -s; }; [ -b $P$i ] || die "partition $P$i did not appear"; done
tool sfdisk -l $TD >> $L/install.log 2>&1

say "Formatting ..."
tool mkfs.fat -F 32 -n GBOS_EFI ${P}1 >> $L/install.log 2>&1 || die "mkfs GBOS_EFI failed"
tool mkfs.fat -F 32 -n GBOSSYS ${P}2 >> $L/install.log 2>&1 || die "mkfs GBOSSYS failed"
# No 'encrypt' feature: vold then behaves as it does on tmpfs (no fscrypt).
tool mke2fs -F -q -t ext4 -L GBOS_META ${P}3 >> $L/install.log 2>&1 || die "mkfs GBOS_META failed"
tool mke2fs -F -q -t ext4 -L GBOS_DATA -m 0 ${P}4 >> $L/install.log 2>&1 || die "mkfs GBOS_DATA failed"
tool e2fsck -fn ${P}3 >> $L/install.log 2>&1 || die "fsck GBOS_META failed"
tool e2fsck -fn ${P}4 >> $L/install.log 2>&1 || die "fsck GBOS_DATA failed"

# Copy, then check every file against the source after dropping the page cache.
mkdir -p /mnt/nefi /mnt/nsys
mount -t vfat ${P}1 /mnt/nefi || die "mount GBOS_EFI failed"
mount -t vfat -o flush ${P}2 /mnt/nsys || die "mount GBOSSYS failed"
mkdir -p /mnt/nefi/EFI/BOOT /mnt/nsys/gbos/logs
say "Copying the kernel ..."
cp $KERNEL /mnt/nefi/EFI/BOOT/BOOTX64.EFI || die "copy BOOTX64.EFI failed"
say "Copying the system (super.img is $(( $(stat -c %s $G/super.img) / 1048576 )) MiB, this takes a few minutes) ..."
for f in $FILES; do cp $G/$f /mnt/nsys/gbos/$f || die "copy $f failed"; done
for d in $DIRS; do cp -r $G/$d /mnt/nsys/gbos/ || die "copy $d/ failed"; done
cp /gbos/busybox /mnt/nsys/busybox 2>/dev/null
# The installed system boots normally and can't re-run the installer.
localai_step /mnt/nsys ${P}4
write_installed_cfg
sync; echo 3 > /proc/sys/vm/drop_caches

say "Verifying ..."
check $KERNEL /mnt/nefi/EFI/BOOT/BOOTX64.EFI
for f in $FILES; do check $G/$f /mnt/nsys/gbos/$f; done
for d in $DIRS; do (cd $G && find $d -type f) | while read f; do check $G/$f /mnt/nsys/gbos/$f; done || exit 1; done || die "verify failed"
umount /mnt/nefi /mnt/nsys /mnt/stickefi; sync

say ""
say "=============================================================="
say " gbOS86 is installed on $TD."
say " Remove the USB stick, then turn the laptop back on. If it doesn't"
say " boot gbos, press F12 at the Dell logo and pick the NVMe/UEFI entry"
say " (or add \\EFI\\BOOT\\BOOTX64.EFI as a boot option in BIOS setup)."
say "=============================================================="
log "install: complete"; sync
if [ -n "$CONFIRM" ]; then poweroff -f; fi
ask "Press Enter to power off. "
poweroff -f
