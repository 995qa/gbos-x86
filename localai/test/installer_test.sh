#!/bin/sh
# Runs usb/install.sh's localai_step under busybox with a fake SSD/stick and scripted answers. Run via localai/test.sh (docker).
# Usage (inside the container): installer_test.sh /path/to/install.sh
set -u
INSTALL=$1
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; fails=$((fails+1)); }
# --- pull out just the AI step (from ask_secret to just before write_installed_cfg) ---
sed -n '/^ask_secret() {/,/^# Write the installed system/p' "$INSTALL" | sed '$d' | sed '/drop_caches/d' > /tmp/step.sh

setup() {  # fresh fake world: stick G, mounted SSD data at /mnt/ndata, system part SYS
  rm -rf /w /mnt/ndata/gbos-localai; mkdir -p /w/stick/localai /w/sys/gbos /mnt/ndata/gbos-localai
  for f in localai.apk prep.sh diag.sh; do echo "content-$f" > /w/stick/localai/$f; done
  : > /w/install.log
}
run() {  # run localai_step with answers from $1 (one per line); extra env in $2
  cat > /w/driver.sh <<DRV
G=/w/stick; L=/w; TTY=/dev/null; LOCAL_AI=${2:-}
say() { echo "\$*" | tee -a /w/install.log; }
ask() { printf '%s' "\$1"; read -r REPLY; echo "\$1\$REPLY" >> /w/install.log; }   # same logging as the real ask
check() { cmp -s "\$1" "\$2" || { echo "VERIFY FAILED \$2"; return 1; }; }
stty() { :; }
mount() { return 0; }
umount() { return 0; }
. /tmp/step.sh
ask_secret() { printf '%s' "\$1"; read -r REPLY; }   # the real one reads the tty with echo off and does NOT log
localai_step /w/sys "/dev/null"
echo "RESULT LOCAL_AI=\$LOCAL_AI"
DRV
  printf '%s\n' "$1" | sh /w/driver.sh > /w/out.txt 2>&1
}
val() { sed -n "s/^$1=//p" /mnt/ndata/gbos-localai/api.conf; }

# 1. answer yes, enter settings on screen; old local-model leftovers present
setup; touch /mnt/ndata/gbos-localai/model.gguf /mnt/ndata/gbos-localai/mmproj.gguf /w/sys/gbos/llama-server; mkdir -p /w/sys/gbos/localai; touch /w/sys/gbos/localai/llama-server /w/sys/gbos/localai/run.sh
run "y

gemini-test-model
SECRETKEY-123
50"
grep -q 'RESULT LOCAL_AI=1' /w/out.txt && ok "yes + typed settings -> LOCAL_AI=1" || { fail "yes + typed settings"; cat /w/out.txt; }
[ "$(val BASE_URL)" = "https://generativelanguage.googleapis.com/v1beta/openai" ] && ok "blank address -> Gemini default" || fail "default address: $(val BASE_URL)"
[ "$(val MODEL)" = "gemini-test-model" ] && [ "$(val API_KEY)" = "SECRETKEY-123" ] && [ "$(val MAX_PER_HOUR)" = "50" ] && ok "model, key and cap saved" || fail "saved values"
[ "$(stat -c %a /mnt/ndata/gbos-localai/api.conf)" = "600" ] && ok "api.conf is mode 600" || fail "api.conf mode $(stat -c %a /mnt/ndata/gbos-localai/api.conf)"
! grep -q 'SECRETKEY' /w/install.log /w/out.txt && ok "the key is NOT in install.log or the screen output" || fail "KEY LEAKED"
[ ! -e /mnt/ndata/gbos-localai/model.gguf ] && [ ! -e /mnt/ndata/gbos-localai/mmproj.gguf ] && ok "old model + vision files deleted from the SSD" || fail "model leftovers remain"
[ ! -e /w/sys/gbos/localai/llama-server ] && [ ! -e /w/sys/gbos/localai/run.sh ] && [ -f /w/sys/gbos/localai/prep.sh ] && [ -f /w/sys/gbos/localai/localai.apk ] && ok "llama-server/run.sh gone, app + scripts installed" || fail "system dir: $(ls /w/sys/gbos/localai)"

# 2. second update: keep the saved settings (Y), nothing typed
run "y
y"
grep -q 'RESULT LOCAL_AI=1' /w/out.txt && [ "$(val API_KEY)" = "SECRETKEY-123" ] && ok "update: 'keep them' keeps the saved key" || { fail "keep"; cat /w/out.txt; }
! grep -q 'SECRETKEY' /w/out.txt && ok "update: the saved key is never printed" || fail "KEY PRINTED"

# 3. update but change settings (n to keep, enter new)
run "y
n
https://api.example.com/v1
other-model
NEWKEY-9
"
[ "$(val BASE_URL)" = "https://api.example.com/v1" ] && [ "$(val API_KEY)" = "NEWKEY-9" ] && [ "$(val MAX_PER_HOUR)" = "120" ] && ok "update: new settings replace the old (cap defaults to 120)" || { fail "replace: $(sed 's/API_KEY=.*/API_KEY=<hidden>/' /mnt/ndata/gbos-localai/api.conf | tr '\n' ' ')"; sed 's/NEWKEY.*/<key>/' /w/out.txt | tail -12; }

# 4. bad input is rejected, then accepted on retry
setup
run "y
http://evil.example.com/v1
m
K

https://ok.example.com/v1
m2
K2
"
[ "$(val BASE_URL)" = "https://ok.example.com/v1" ] && grep -q 'must start with https' /w/out.txt && ok "public http:// address rejected, retry accepted" || { fail "retry"; cat /w/out.txt | tail -8; }

# 5. answer no: everything removed, including the saved key
run "n"
grep -q 'RESULT LOCAL_AI=0' /w/out.txt && [ ! -e /mnt/ndata/gbos-localai ] && [ ! -e /w/sys/gbos/localai ] && ok "no: key, config and AI files removed" || { fail "no"; ls -R /mnt/ndata /w/sys; }

# 6. settings file prepared on the stick
setup
printf 'BASE_URL=https://stick.example.com/v1\r\nMODEL=stick-model\r\nAPI_KEY=STICKKEY-7\r\n' > /w/stick/localai/api.conf
run "y"
[ "$(val BASE_URL)" = "https://stick.example.com/v1" ] && [ "$(val API_KEY)" = "STICKKEY-7" ] && ok "settings file on the stick imported (CRLF tolerated)" || { fail "stick import"; cat /w/out.txt | tail -5; }
! grep -q 'STICKKEY' /w/out.txt /w/install.log && ok "stick key not printed or logged" || fail "STICK KEY LEAKED"

# 7. non-interactive: gbos.cfg says LOCAL_AI=1 with nothing configured -> skipped, not stuck
setup
run "" 1
grep -q 'RESULT LOCAL_AI=0' /w/out.txt && ok "LOCAL_AI=1 without any API settings is skipped, not hung" || { fail "noninteractive"; tail -5 /w/out.txt; }

# 8. missing script on the stick -> skipped
setup; rm /w/stick/localai/prep.sh
run "y"
grep -q 'RESULT LOCAL_AI=0' /w/out.txt && grep -q 'prep.sh is not on the stick' /w/out.txt && ok "incomplete stick -> skipped with a message" || fail "incomplete stick"

# ---------------- update speed-ups: stamps and byte-compare verification ----------------
sed -n '/^check() {/,/^is_skipped/p' "$INSTALL" > /tmp/stamps.sh
cat > /w/stamp_driver.sh <<'DRV'
G=/w/stick; L=/w; DIED=0
die() { echo "DIE: $*"; DIED=1; }
. /tmp/stamps.sh
t() { if "$@"; then echo yes; else echo no; fi; }
rm -rf /w/stick /mnt/nsys; mkdir -p /w/stick/firmware /mnt/nsys/gbos; : > /w/install.log
echo aaaa > /w/stick/firmware/x; dd if=/dev/zero of=/w/stick/super.img bs=1024 count=64 2>/dev/null
echo "no_stamp_yet=$(t stamp_same firmware)"
stamp_save firmware; stamp_save super.img
echo "after_save=$(t stamp_same firmware) $(t stamp_same super.img)"
touch -d '2001-01-01 00:00:00' /w/stick/firmware/x
echo "file_time_changed=$(t stamp_same firmware)"
stamp_save firmware; echo "after_resave=$(t stamp_same firmware)"
echo aaaaaaaa > /w/stick/firmware/x; touch -d '2001-01-01 00:00:00' /w/stick/firmware/x
echo "size_changed=$(t stamp_same firmware)"
stamp_save firmware; echo extra > /w/stick/firmware/new_file
echo "file_added=$(t stamp_same firmware)"
stamp_save firmware; rm /w/stick/firmware/new_file
echo "file_removed=$(t stamp_same firmware)"
stamp_save firmware; UPDATE_FULL=1; echo "forced_full=$(t stamp_same firmware)"; UPDATE_FULL=
dd if=/dev/urandom of=/w/stick/super.img bs=1024 count=64 2>/dev/null; touch -d '2005-05-05 05:05:05' /w/stick/super.img   # a real replacement is a long copy, so it has a new time
echo "same_size_new_content=$(t stamp_same super.img)"
mkdir -p /w/stick/empty; echo "empty_dir_stamp=$(t stamp_of empty)"; echo "empty_never_same=$(t stamp_same empty)"
SKIP=" super.img"; echo "skip_list=$(t is_skipped super.img) $(t is_skipped firmware)"
printf one > /w/a; printf one > /w/b; printf two > /w/c
check /w/a /w/b; echo "check_equal_died=$DIED"; check /w/a /w/c >/dev/null; echo "check_different_died=$DIED"
grep -q 'sha256sum "\$1"' /tmp/stamps.sh && echo "check_still_hashes=yes" || echo "check_still_hashes=no"
DRV
sh /w/stamp_driver.sh > /w/stamp_out.txt 2>&1
g() { sed -n "s/^$1=//p" /w/stamp_out.txt; }
[ "$(g no_stamp_yet)" = no ] && ok "stamps: no saved stamp -> full path" || fail "no_stamp_yet"
[ "$(g after_save)" = "yes yes" ] && ok "stamps: unchanged since the verified copy -> skipped" || fail "after_save: $(g after_save)"
[ "$(g file_time_changed)" = no ] && [ "$(g after_resave)" = yes ] && ok "stamps: a changed file time is noticed (and a new stamp works)" || fail "time: $(g file_time_changed)/$(g after_resave)"
[ "$(g size_changed)" = no ] && [ "$(g file_added)" = no ] && [ "$(g file_removed)" = no ] && ok "stamps: changed size, added file and removed file are all noticed" || fail "size/add/remove"
[ "$(g forced_full)" = no ] && ok "stamps: UPDATE_FULL=1 forces the full path" || fail "forced_full"
[ "$(g same_size_new_content)" = no ] && ok "stamps: same-size replacement (new file time) is noticed" || fail "same_size_new_content"
[ "$(g empty_dir_stamp)" = no ] && [ "$(g empty_never_same)" = no ] && ok "stamps: an empty listing never counts as a match" || fail "empty"
[ "$(g skip_list)" = "yes no" ] && ok "stamps: skip list lookup" || fail "skip_list: $(g skip_list)"
[ "$(g check_equal_died)" = 0 ] && ok "check: identical files pass" || fail "check equal"
[ "$(g check_different_died)" = 1 ] && ok "check: a differing copy stops the update" || fail "check different"
[ "$(g check_still_hashes)" = no ] && ok "check: byte compare, no sha256 of both files" || fail "check still hashes"

[ $fails = 0 ] && echo "ALL PASS" || echo "$fails FAILED"
exit $fails
