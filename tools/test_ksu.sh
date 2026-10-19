#!/bin/sh
# Test of the KernelSU integration: the userspace script (usb/ksu/install.sh), the hook.sh service
# that runs it, the manager APK's signing certificate (the kernel only accepts the official one) and
# the kernel-side options (kernel/configure_whl.py).
# Run: sh tools/test_ksu.sh
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
W=$(mktemp -d "${TMPDIR:-/tmp}/ksu.XXXXXX"); trap 'rm -rf "$W"' EXIT
fail=0; n=0
ok()  { n=$((n+1)); echo "ok   $*"; }
bad() { n=$((n+1)); fail=$((fail+1)); echo "FAIL $*"; }

BB=$(ls "$ROOT"/kernel/out/busybox 2>/dev/null | head -1)

# --- 1. the kernel's expectations about the manager APK -------------------------------------------
# kernel/manager/apk_sign.c (KernelSU v3.3.1): the certificate must be 827 bytes with this hash.
EXP_SIZE=827
EXP_SHA=c371061b19d8c7d7d6133c6a9bafe198fa944e50c1b31c9d8daa8d7f1fc2d2d6
APK=$ROOT/usb/ksu/manager.apk
if [ -f "$APK" ]; then
  python3 - "$APK" > "$W/cert.txt" <<'EOF'
import hashlib, struct, sys
apk = open(sys.argv[1], "rb").read()
eocd = apk.rfind(b"PK\x05\x06")
cd = struct.unpack_from("<I", apk, eocd + 16)[0]
size = struct.unpack_from("<Q", apk, cd - 24)[0]
region = apk[cd - 8 - size:cd - 24][8:]
off, blocks = 0, {}
while off < len(region):
    ln = struct.unpack_from("<Q", region, off)[0]; off += 8
    bid = struct.unpack_from("<I", region, off)[0]; off += 4
    blocks.setdefault(bid, region[off:off + ln]); off += ln
val = blocks.get(0x7109871A) or blocks.get(0xF05368C0)
def lp(b, o):
    n = struct.unpack_from("<I", b, o)[0]
    return b[o + 4:o + 4 + n], o + 4 + n
signers, _ = lp(val, 0)
signer, _ = lp(signers, 0)
sd, _ = lp(signer, 0)
_d, o = lp(sd, 0)
certs, _ = lp(sd, o)
cert, _ = lp(certs, 0)
print(len(cert)); print(hashlib.sha256(cert).hexdigest())
EOF
  size=$(sed -n 1p "$W/cert.txt"); sha=$(sed -n 2p "$W/cert.txt")
  [ "$size" = "$EXP_SIZE" ] && ok "manager APK certificate is $EXP_SIZE bytes" || bad "manager APK certificate is $size bytes, the kernel wants $EXP_SIZE"
  [ "$sha" = "$EXP_SHA" ] && ok "manager APK certificate hash matches the kernel's" || bad "manager APK certificate hash $sha != $EXP_SHA"
else
  ok "no manager APK on the stick yet (build.sh fetches it; skipped)"
fi
[ -f "$ROOT/usb/ksu/ksud" ] && ok "ksud is on the stick" || ok "no ksud on the stick yet (build.sh fetches it; skipped)"

# --- 2. the userspace script ----------------------------------------------------------------------
# It is run with the paths it uses replaced by the test's, so what is tested is the shipped code.
S=$ROOT/usb/ksu/install.sh
[ -f "$S" ] && ok "usb/ksu/install.sh exists" || { bad "usb/ksu/install.sh missing"; exit 1; }
mkdir -p "$W/stick/gbos/ksu" "$W/stick/gbos/logs/boot-1" "$W/data" "$W/tmp" "$W/bin"
cp "$ROOT/usb/ksu/ksud" "$W/stick/gbos/ksu/ksud" 2>/dev/null || echo ksud > "$W/stick/gbos/ksu/ksud"
cp "$ROOT/usb/ksu/manager.apk" "$W/stick/gbos/ksu/manager.apk" 2>/dev/null || echo apk > "$W/stick/gbos/ksu/manager.apk"
# stubs: pm says the package is not installed, dmesg has nothing
cat > "$W/bin_pm" <<'EOF'
#!/bin/sh
case "$1" in
  path) exit 1;;                       # not installed
  install) echo "Success"; exit 0;;    # pretend it worked
esac
exit 0
EOF
cat > "$W/bin_dmesg" <<'EOF'
#!/bin/sh
echo "KernelSU: welcome to KernelSU version 32680"
EOF
chmod 755 "$W/bin_pm" "$W/bin_dmesg"
mkdir -p "$W/bin"
mv "$W/bin_pm" "$W/bin/pm"; mv "$W/bin_dmesg" "$W/bin/dmesg"
sed -e "s#^G=/postinstall/gbos#G=$W/stick/gbos#" \
    -e "s#^N=\$1#N=1#" \
    -e "s#/data/local/tmp#$W/tmp#g" \
    -e "s#/data/adb#$W/data/adb#g" \
    "$S" > "$W/install.sh"
sh -n "$W/install.sh" && ok "sh -n install.sh" || bad "syntax error in install.sh"
PATH="$W/bin:$PATH" sh "$W/install.sh" 1 > "$W/out.txt" 2>&1
[ -f "$W/data/adb/ksud" ] && ok "ksud copied to /data/adb" || bad "ksud not installed"
grep -q "pm install" "$W/out.txt" && ok "the manager app is installed with pm" || bad "pm install never ran"
grep -q "already installed" /dev/null; :
# second run: the manager is installed now (pm path succeeds), ksud is already there
cat > "$W/bin/pm" <<'EOF'
#!/bin/sh
case "$1" in
  path) echo "package:/data/app/$PKG/base.apk"; exit 0;;
esac
exit 0
EOF
chmod 755 "$W/bin/pm"
PATH="$W/bin:$PATH" sh "$W/install.sh" 1 > "$W/out2.txt" 2>&1
grep -q "already installed" "$W/out2.txt" && ok "a second run does not reinstall the manager" || bad "the manager is installed again on every boot"
grep -q "already in" "$W/out2.txt" && ok "a second run keeps the existing ksud" || bad "ksud is copied again on every boot"
[ -f "$W/stick/gbos/logs/boot-1/ksu.txt" ] && ok "the log lands in logs/boot-N/ksu.txt" || bad "no log written"

# KSU_MANAGER=0: the daemon is installed, the app is not
PATH="$W/bin:$PATH" sh "$W/install.sh" 1 0 > "$W/out3.txt" 2>&1
grep -q "not installed" "$W/out3.txt" && ok "KSU_MANAGER=0: the manager app is not installed" || bad "KSU_MANAGER=0: the app was installed anyway"
grep -q "pm install" "$W/out3.txt" && bad "KSU_MANAGER=0: pm install ran" || ok "KSU_MANAGER=0: pm install does not run"

# --- 3. the hook service ---------------------------------------------------------------------------
H=$ROOT/usb/hook.sh
grep -qF "service gbos_ksu" "$H" && ok "hook: the gbos_ksu service exists" || bad "hook: no gbos_ksu service"
grep -qF "start gbos_ksu" "$H" && ok "hook: gbos_ksu is started" || bad "hook: gbos_ksu is never started"
[ "$(grep -cF 'start gbos_ksu' "$H")" = 2 ] && ok "hook: started at post-fs-data and after boot_completed" \
  || bad "hook: gbos_ksu should run twice (ksud early, the manager app when pm works)"
sh -n "$H" && ok "sh -n hook.sh" || bad "syntax error in hook.sh"

# --- 4. the kernel side ---------------------------------------------------------------------------
C=$ROOT/kernel/configure_whl.py
grep -q "'KSU': 'y'" "$C" && ok "configure_whl.py: CONFIG_KSU=y" || bad "configure_whl.py: CONFIG_KSU is not set"
grep -q "'KSU_X86_PATCH_SYSCALL_DISPATCHER': 'y'" "$C" && ok "configure_whl.py: the x86_64 dispatcher patch is on" \
  || bad "configure_whl.py: CONFIG_KSU_X86_PATCH_SYSCALL_DISPATCHER is not set"
grep -q "kernelsu" "$ROOT/kernel/kernelsu/apply.sh" && ok "kernel/kernelsu/apply.sh links the sources in" || bad "kernel/kernelsu/apply.sh looks wrong"
sh -n "$ROOT/kernel/kernelsu/apply.sh" && ok "sh -n kernel/kernelsu/apply.sh" || bad "syntax error in kernel/kernelsu/apply.sh"
sh -n "$ROOT/kernel/fetch_kernel_sources.sh" && ok "sh -n kernel/fetch_kernel_sources.sh" || bad "syntax error in kernel/fetch_kernel_sources.sh"
# the manager package name the kernel looks for
grep -q "me.weishu.kernelsu" "$S" && ok "the script knows the manager's package name" || bad "package name missing"

echo "$n checks, $fail failed"
[ $fail = 0 ] && echo KSU_TEST_PASS
exit $fail
