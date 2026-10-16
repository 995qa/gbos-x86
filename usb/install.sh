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
# check SOURCE COPY: byte-for-byte compare (the page cache is dropped before verifying, so this re-reads the copy from the disk). Much
# faster than hashing both files with busybox's software sha256 (that took minutes for the 5 GB system image).
check() { cmp -s "$1" "$2" || die "verify failed: $2"; echo "ok $2" >> $L/install.log; }

# Big items (system image, firmware, modules) are skipped on update when nothing about them changed since the last VERIFIED copy.
# A "stamp" is a hash of an item's file names, sizes and modification times on the stick. It is saved on the SSD (gbos/.stamps/) only
# after the copy was verified, so the next update compares two short strings instead of reading ~5.5 GB twice and re-copying ~400 MB.
# Replacing an item on the stick changes its file times, so a stale stamp cannot hide a real change. UPDATE_FULL=1 in gbos.cfg, or a
# missing stamp, forces the full compare, copy and verify.
STAMPED="super.img firmware modules"
stamp_of() { _l=$(find "$G/$1" -type f -exec stat -c '%n %s %Y' {} + 2>/dev/null | sort); [ -n "$_l" ] || return 1; printf '%s\n' "$_l" | sha256sum | cut -d' ' -f1; }
stamp_same() { [ -z "$UPDATE_FULL" ] && [ -f /mnt/nsys/gbos/.stamps/$1 ] && _s=$(stamp_of $1) && [ "$(cat /mnt/nsys/gbos/.stamps/$1)" = "$_s" ]; }
stamp_save() { _s=$(stamp_of $1) && mkdir -p /mnt/nsys/gbos/.stamps && printf '%s\n' "$_s" > /mnt/nsys/gbos/.stamps/$1; }
is_skipped() { case " $SKIP " in *" $1 "*) return 0;; esac; return 1; }

# Optional AI stand-in for Google's AICore (the stock one needs hardware attestation this laptop can't do): Magic Pointer and
# friends answer through an API the USER provides (an OpenAI-compatible chat API: address, key, model). Asked on every install and
# every update. LOCAL_AI=1/0 in the stick's gbos.cfg answers without asking (1 needs API settings already on the SSD or on the stick);
# a test run with gbos_install_confirm= on the kernel command line never asks and says no. No removes it again. The older
# local-model version's files (model, llama-server) are ALWAYS deleted from the SSD here.
# The API key is typed with echo off and never goes to install.log (ask_secret below does not log), the screen or git.
# localai_step MOUNTED_GBOSSYS DATA_PARTITION: sets LOCAL_AI to what the installed gbos.cfg should say.
ask_secret() { printf '%s' "$1" > $TTY; stty -echo < $TTY 2>/dev/null; read -r REPLY < $TTY; stty echo < $TTY 2>/dev/null; echo > $TTY; }
trim() { printf '%s' "$1" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }
conf_get() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1 | tr -d '\r'; }
# api_problem URL MODEL KEY: prints what is wrong (never the key) and returns 1, or returns 0.
api_problem() {
  [ -n "$1" ] || { echo "the API address is empty"; return 1; }
  [ -n "$2" ] || { echo "the model name is empty"; return 1; }
  [ -n "$3" ] || { echo "the API key is empty"; return 1; }
  case "$1" in
    https://*) ;;
    http://localhost*|http://127.*|http://10.*|http://192.168.*|http://172.1[6-9].*|http://172.2[0-9].*|http://172.3[01].*) ;;
    *) echo "the address must start with https:// (http:// only for a server on this machine or your own network)"; return 1;;
  esac
  return 0
}
# api_write FILE URL MODEL KEY CAP: root-only (it holds the key).
api_write() { ( umask 077; printf 'BASE_URL=%s\nMODEL=%s\nAPI_KEY=%s\nMAX_PER_HOUR=%s\n' "$2" "$3" "$4" "$5" > "$1.new" ) && chmod 600 "$1.new" && mv -f "$1.new" "$1"; }

localai_step() {
  _sys=$1; _data=$2; _ans=$LOCAL_AI; _cfgans=$LOCAL_AI   # _cfgans: what gbos.cfg pre-answered (LOCAL_AI itself is reset below)
  _conf=$(sed -n 's/.*gbos_install_confirm=\([^ ]*\).*/\1/p' /proc/cmdline)
  mkdir -p /mnt/ndata
  _mounted=0; mount -t ext4 "$_data" /mnt/ndata 2>/dev/null && _mounted=1
  # Leftovers of the local-model version (about 4 GB): gone on every install/update, whatever is answered below.
  if [ $_mounted = 1 ]; then rm -f /mnt/ndata/gbos-localai/model.gguf /mnt/ndata/gbos-localai/mmproj.gguf; fi
  rm -f "$_sys/gbos/localai/llama-server" "$_sys/gbos/localai/run.sh"
  A=/mnt/ndata/gbos-localai/api.conf
  if [ -z "$_ans" ]; then
    if [ -n "$_conf" ]; then _ans=0; else
      say ""
      say "Optional: AI features (Magic Pointer) through an API YOU provide. Google's own servers refuse this laptop, so the text and"
      say "pictures you point at would be sent to the provider whose address and key you enter (a Gemini API key works, or any"
      say "OpenAI-compatible service). Needs Wi-Fi and counts against your key's quota. Answering n removes it and any saved key."
      ask "Use an API for the AI features? [y/N] "
      case "$REPLY" in y|Y|yes|YES) _ans=1;; *) _ans=0;; esac
    fi
  fi
  if [ "$_ans" != 1 ]; then
    [ $_mounted = 1 ] && { rm -rf /mnt/ndata/gbos-localai; umount /mnt/ndata; }
    rm -rf "$_sys/gbos/localai"; LOCAL_AI=0; say "AI features through an API: off (saved key and AI files removed)"; return 0
  fi
  LOCAL_AI=0
  _lf="localai.apk prep.sh diag.sh"   # everything hook.sh and the init services run
  for f in $_lf; do
    [ -f $G/localai/$f ] || { [ $_mounted = 1 ] && umount /mnt/ndata; say "AI features skipped: gbos/localai/$f is not on the stick"; return 0; }
  done
  [ $_mounted = 1 ] || { say "AI features skipped: cannot mount $_data"; return 0; }
  mkdir -p /mnt/ndata/gbos-localai; chmod 755 /mnt/ndata/gbos-localai

  # --- API settings: a file on the stick wins (prepare gbos/localai/api.conf on a computer, then delete it from the stick afterwards),
  # else keep what is on the SSD if the user agrees, else ask on this screen.
  _have_cfg=0
  if [ -f $G/localai/api.conf ]; then
    _u=$(trim "$(conf_get $G/localai/api.conf BASE_URL)"); _m=$(trim "$(conf_get $G/localai/api.conf MODEL)")
    _k=$(trim "$(conf_get $G/localai/api.conf API_KEY)"); _c=$(trim "$(conf_get $G/localai/api.conf MAX_PER_HOUR)")
    if _why=$(api_problem "$_u" "$_m" "$_k"); then
      if api_write $A "$_u" "$_m" "$_k" "${_c:-120}"; then
        _have_cfg=1; say "  API settings imported from gbos/localai/api.conf on the stick (delete that file from the stick if you don't want your key there)"
      else
        say "  could not save the API settings from the stick"
      fi
    else
      say "  gbos/localai/api.conf on the stick is not usable: $_why"
    fi
    _k=
  fi
  if [ $_have_cfg = 0 ] && [ -f $A ]; then
    _u=$(conf_get $A BASE_URL)
    if api_problem "$_u" "$(conf_get $A MODEL)" "$(conf_get $A API_KEY)" > /dev/null; then
      if [ -n "$_cfgans" ]; then
        _have_cfg=1   # answered by gbos.cfg: keep what is saved
      else
        say "  Current API settings: $_u , model $(conf_get $A MODEL) (key saved)"
        ask "  Keep them? [Y/n] "
        case "$REPLY" in n|N|no|NO) ;; *) _have_cfg=1;; esac
      fi
    fi
  fi
  _try=0
  while [ $_have_cfg = 0 ] && [ $_try -lt 3 ]; do
    _try=$((_try+1))
    ask "  API address [https://generativelanguage.googleapis.com/v1beta/openai]: "; _u=$(trim "$REPLY"); [ -n "$_u" ] || _u=https://generativelanguage.googleapis.com/v1beta/openai
    ask "  Model name (e.g. gemini-2.5-flash, as your provider names it): "; _m=$(trim "$REPLY")
    ask_secret "  API key (typed, not shown): "; _k=$(trim "$REPLY")
    ask "  Max AI requests per hour [120]: "; _c=$(trim "$REPLY"); case "$_c" in ''|*[!0-9]*) _c=120;; esac
    if _why=$(api_problem "$_u" "$_m" "$_k"); then
      api_write $A "$_u" "$_m" "$_k" "$_c" && _have_cfg=1 || say "  could not save the settings"
    else
      say "  Not saved: $_why. Try again."
    fi
    _k=
  done
  if [ $_have_cfg = 0 ]; then umount /mnt/ndata; say "AI features skipped: no usable API settings were entered"; return 0; fi
  chmod 600 $A

  # --- Optional: Magic Pointer patched to need only text queries (localai/build_gpointer.sh, ~235 MB, Google's app so never shipped
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
    cp $G/localai/$f "$_sys/gbos/localai/" || { umount /mnt/ndata; say "AI features skipped: copying $f failed"; return 0; }
  done
  sync; echo 3 > /proc/sys/vm/drop_caches
  [ -f $G/localai/gpointer.apk ] && [ -f $P ] && check $G/localai/gpointer.apk $P
  for f in $_lf; do check $G/localai/$f "$_sys/gbos/localai/$f"; done
  umount /mnt/ndata
  LOCAL_AI=1; say "AI features through your API: on (provider $(printf '%s' "$_u" | sed 's#^[a-z]*://\([^/:]*\).*#\1#'))"
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
  SKIP=""
  for f in $FILES; do
    case " $STAMPED " in *" $f "*) if stamp_same $f; then SKIP="$SKIP $f"; say "  $f unchanged, skipped"; continue; fi;; esac
    cmp -s $G/$f /mnt/nsys/gbos/$f || { say "  $f"; cp $G/$f /mnt/nsys/gbos/$f || die "copy $f failed"; }
  done
  for d in $DIRS; do
    case " $STAMPED " in *" $d "*) if stamp_same $d; then SKIP="$SKIP $d"; say "  $d/ unchanged, skipped"; continue; fi;; esac
    say "  $d/"; rm -rf /mnt/nsys/gbos/$d; cp -r $G/$d /mnt/nsys/gbos/ || die "copy $d/ failed"
  done
  cmp -s $KERNEL /mnt/nefi/EFI/BOOT/BOOTX64.EFI || { say "  kernel"; cp $KERNEL /mnt/nefi/EFI/BOOT/BOOTX64.EFI || die "copy kernel failed"; }
  localai_step /mnt/nsys "$NDATA"
  # Settings such as DENSITY follow the stick; the installed copy always boots normally.
  write_installed_cfg
  sync; echo 3 > /proc/sys/vm/drop_caches
  say "Verifying ..."
  check $KERNEL /mnt/nefi/EFI/BOOT/BOOTX64.EFI
  for f in $FILES; do is_skipped $f || check $G/$f /mnt/nsys/gbos/$f; done
  for d in $DIRS; do is_skipped $d && continue; (cd $G && find $d -type f) | while read f; do check $G/$f /mnt/nsys/gbos/$f; done || exit 1; done || die "verify failed"
  for i in $STAMPED; do stamp_save $i || say "  (could not save the update stamp for $i; the next update will do a full compare)"; done
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
for i in $STAMPED; do stamp_save $i || true; done
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
