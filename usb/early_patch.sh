# Sourced from gbos.cfg, before any partition is mounted. stage0's `dmctl create` calls (one per partition, each
# a fresh process that loads libcrypto) run BoringSSL's load-time module hash through SHA-NI, which traps here:
# ~3.7M emulated instructions, ~2 s of boot, all before hook.sh gets to bind the patched libraries. So bind them
# first: this wraps chroot (dmctl's only external command) and does it once, just before the first call.
# Fail-safe: if this never fires, hook.sh does the same binds later. Both are hash-gated on the exact originals.
gbos_early_patch() {
  for p in system:/new/system/lib64/libz.so:371f70d6a9392327cb36838d0cbc7af7388d1689c25d91cd343af8e58433683b system:/new/system/lib64/libcrypto.so:0ee96c7e0cb1ffca5520d2eaca02b4fa2ccff5a8fcb753a491e85555a91c9f2a \
           vendor:/new/vendor/lib64/libz.so:e45aecb65cbb40f0c3070b05aa9d974076d401ed6f2aff3081af26a14e812590 vendor:/new/vendor/lib64/libcrypto.so:70cc371baf9925d5f1f857d03177d5193caf60bb13bb2012b4336657adcf48e7; do
    n=${p%%:*}; r=${p#*:}; t=${r%%:*}; h=${r#*:}; b=${t##*/}; b=${b%.so}
    f=$G/patched/$n.$b.so
    [ -f "$f" ] && [ -f "$t" ] || continue
    if [ "$(sha256sum $t | cut -d' ' -f1)" = "$h" ]; then
      mount --bind "$f" "$t" && log "early: patched $n $b"
    fi
  done
}
chroot() {
  if [ -z "$GBOS_EARLY_DONE" ] && [ "$1" = /new ]; then
    GBOS_EARLY_DONE=1
    gbos_early_patch
  fi
  command chroot "$@"
}
