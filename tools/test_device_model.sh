#!/bin/sh
# Test of the vendor/build.prop rewrite in usb/hook.sh (DEVICE_MODEL, DENSITY, the always-on overrides): the block is cut out of
# hook.sh and run on a fake vendor/build.prop, so what is tested is the shipped code.
# Run: sh tools/test_device_model.sh
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
W=$(mktemp -d "${TMPDIR:-/tmp}/devmodel.XXXXXX"); trap 'rm -rf "$W"' EXIT
fail=0; n=0
ok()  { n=$((n+1)); echo "ok   $*"; }
bad() { n=$((n+1)); fail=$((fail+1)); echo "FAIL $*"; }

# the block: from 'case "$DENSITY" in' to the '} > /tmp/vendor.build.prop' redirect (the bind mount after it is cut off)
awk '/^case "\$DENSITY" in/{p=1} p{print} /^\} > \/tmp\/vendor.build.prop/{exit}' "$ROOT/usb/hook.sh" \
  | sed -e 's# && mount --bind.*$##' -e "s#/new/vendor/build.prop#$W/in.prop#g" -e "s#/tmp/vendor.build.prop#$W/out.prop#g" > "$W/block.sh"
[ -s "$W/block.sh" ] && ok "block extracted from hook.sh ($(wc -l < "$W/block.sh") lines)" || { bad "block not found in hook.sh"; exit 1; }

cat > "$W/in.prop" <<'EOF'
ro.product.vendor.model=Lapis
ro.product.vendor.marketname=Lapis Googlebook
ro.product.vendor.brand=google
ro.boot.hypervisor.protected_vm.supported=1
ro.sf.lcd_density=260
EOF
count() { grep -c "^$1\$" "$W/out.prop"; }

# with DEVICE_MODEL: old model/marketname lines replaced (each key exactly once), other lines kept
DEVICE_MODEL="Surface Laptop 7" GPU_SW=0 DENSITY= sh "$W/block.sh"
for k in "ro.product.model=Surface Laptop 7" "ro.product.vendor.model=Surface Laptop 7" "ro.product.marketname=Surface Laptop 7" "ro.product.vendor.marketname=Surface Laptop 7"; do
  [ "$(count "$k")" = 1 ] && ok "out.prop has: $k" || bad "out.prop lacks (or repeats): $k"
done
grep -q 'Lapis' "$W/out.prop" && bad "old model/marketname lines survived" || ok "old model/marketname lines are gone"
grep -q '^ro.product.vendor.brand=google$' "$W/out.prop" && ok "brand untouched" || bad "brand changed"
grep -q 'protected_vm' "$W/out.prop" && bad "protected_vm line not hidden" || ok "protected_vm.supported still hidden"
grep -q '^ro.sf.lcd_density=260$' "$W/out.prop" && ok "stock density kept when DENSITY unset" || bad "density changed without DENSITY"

# without DEVICE_MODEL: nothing about the model changes
DEVICE_MODEL= GPU_SW=0 DENSITY=180 sh "$W/block.sh"
grep -q '^ro.product.vendor.model=Lapis$' "$W/out.prop" && grep -q '^ro.product.vendor.marketname=Lapis Googlebook$' "$W/out.prop" && ok "DEVICE_MODEL unset: model lines untouched" || bad "DEVICE_MODEL unset but model lines changed"
grep -q '^ro.product.model=' "$W/out.prop" && bad "ro.product.model added although DEVICE_MODEL unset" || ok "DEVICE_MODEL unset: no ro.product.model added"
grep -q '^ro.sf.lcd_density=180$' "$W/out.prop" && ok "DENSITY still applied" || bad "DENSITY not applied"

# the service that sets the Settings "Device name"
H=$ROOT/usb/hook.sh
grep -qF "settings put global device_name '\$DEVICE_MODEL'" "$H" && ok "hook: gbos_devname sets Settings.Global.device_name" || bad "hook: no device_name service"
grep -qF 'start gbos_devname' "$H" && ok "hook: gbos_devname is started" || bad "hook: gbos_devname never started"
sh -n "$H" && ok "sh -n hook.sh" || bad "syntax"

echo "$n checks, $fail failed"
[ $fail = 0 ] && echo DEVICE_MODEL_TEST_PASS
exit $fail
