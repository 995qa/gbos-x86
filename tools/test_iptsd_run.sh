#!/bin/sh
# Test of usb/surface/iptsd-run.sh against a fake /sys, fake /dev and fake iptsd binaries (nothing touches the machine):
#   - the Surface touchpad's hidraw node (HID_ID ...045E:00000C9F) is found and iptsd is started on it, another HID device is ignored
#   - a rejecting iptsd-check-device means no start
#   - no such touchpad: gives up (exit 0) after WAIT; without the binaries it exits at once and writes no log
#   - the service in hook.sh is oneshot (the script exits by itself on other laptops, init must not restart it)
# Run: sh tools/test_iptsd_run.sh
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
R=$ROOT/usb/surface/iptsd-run.sh
W=$(mktemp -d "${TMPDIR:-/tmp}/iptsdtest.XXXXXX"); trap 'rm -rf "$W"' EXIT
fail=0; n=0
ok()  { n=$((n+1)); echo "ok   $*"; }
bad() { n=$((n+1)); fail=$((fail+1)); echo "FAIL $*"; }

mkdev() { # mkdev SYS NAME HID_ID HID_NAME
  mkdir -p "$1/class/hidraw/$2/device"
  printf 'HID_ID=%s\nHID_NAME=%s\n' "$3" "$4" > "$1/class/hidraw/$2/device/uevent"
}
mkstick() { # mkstick DIR CHECK_RC : fake gbos dir with stub binaries
  mkdir -p "$1/surface" "$1/logs/boot-1"
  printf '#!/bin/sh\nexit %s\n' "$2" > "$1/surface/iptsd-check-device"
  printf '#!/bin/sh\necho "iptsd on $1" > "%s/ran"\nexit 0\n' "$1" > "$1/surface/iptsd"
  chmod +x "$1/surface/iptsd" "$1/surface/iptsd-check-device"
}
run() { # run GBOSDIR SYSDIR [extra env...]
  g=$1; s=$2; shift 2
  env GBOS_G="$g" GBOS_SYS="$s" GBOS_DEV=/dev GBOS_SLEEP=0 "$@" sh "$R" 1
}

# 1. touchpad present, one other HID device
S=$W/sys1; G=$W/g1
mkdev $S hidraw0 0003:000004F2:0000B6B7 "USB Camera"
mkdev $S hidraw1 0018:0000045E:00000C9F "MSHW0264:00 045E:0C9F"
mkstick $G 0
run $G $S GBOS_ONCE=1; rc=$?
[ $rc = 0 ] && ok "touchpad present: exit 0" || bad "touchpad present: exit $rc"
grep -q 'iptsd on /dev/hidraw1' $G/ran 2>/dev/null && ok "iptsd started on /dev/hidraw1 (not on the camera's hidraw0)" || bad "iptsd not started on hidraw1: $(cat $G/ran 2>&1)"
grep -q 'iptsd exited rc=0' $G/logs/boot-1/iptsd.txt && ok "exit status of iptsd logged correctly" || bad "rc not logged: $(cat $G/logs/boot-1/iptsd.txt)"

# 2. check-device rejects the node
G=$W/g2; mkstick $G 1
run $G $S GBOS_ONCE=1; rc=$?
[ $rc = 1 ] && [ ! -e $G/ran ] && ok "rejected by iptsd-check-device: iptsd not started" || bad "rejected case: rc=$rc ran=$(cat $G/ran 2>&1)"

# 3. no such touchpad on this machine
S=$W/sys3; mkdev $S hidraw0 0003:000004F2:0000B6B7 "USB Camera"
G=$W/g3; mkstick $G 0
run $G $S GBOS_WAIT=0; rc=$?
[ $rc = 0 ] && grep -q 'giving up' $G/logs/boot-1/iptsd.txt && [ ! -e $G/ran ] && ok "other laptop: gives up with exit 0, iptsd never started" || bad "other laptop: rc=$rc"

# 4. binaries missing
G=$W/g4; mkdir -p $G/logs/boot-1
run $G $S GBOS_WAIT=0; rc=$?
[ $rc = 0 ] && [ ! -e $G/logs/boot-1/iptsd.txt ] && ok "no surface/iptsd on the stick: exit 0, no log" || bad "no binaries: rc=$rc"

# 5. hook.sh / syntax
H=$ROOT/usb/hook.sh
awk '/^service gbos_iptsd /{f=1} f&&/oneshot/{print "yes"; exit} f&&/^$/{exit}' "$H" | grep -q yes && ok "hook: gbos_iptsd is oneshot" || bad "hook: gbos_iptsd service not oneshot"
grep -qF 'start gbos_iptsd' "$H" && ok "hook: gbos_iptsd is started" || bad "hook: gbos_iptsd never started"
sh -n "$R" && sh -n "$H" && ok "sh -n iptsd-run.sh hook.sh" || bad "syntax"

echo "$n checks, $fail failed"
[ $fail = 0 ] && echo IPTSD_RUN_TEST_PASS
exit $fail
