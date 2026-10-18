# Sourced from gbos.cfg, before any partition is mounted. stage0's `dmctl create` calls (one per partition, each
# a fresh process that loads libcrypto) run BoringSSL's load-time module hash through SHA-NI, which traps here:
# ~3.7M emulated instructions, ~2 s of boot, all before hook.sh gets to bind the patched libraries. So bind them
# first: this wraps chroot (dmctl's only external command) and does it once, just before the first call.
# Which files, and the sha256 of the exact original each patch needs, come from patched/MANIFEST ("early" lines; written
# by tools/port_build.py). Fail-safe: if this never fires, hook.sh does the same binds later (gbos_bind_patches).
gbos_early_patch() {
  [ -f "$G/patched/MANIFEST" ] || return 0
  while read -r ep_kind ep_target ep_want ep_file ep_rest; do
    [ "$ep_kind" = early ] || continue
    [ -f "$G/$ep_file" ] && [ -f "$ep_target" ] || continue
    if [ "$(sha256sum "$ep_target" | cut -d' ' -f1)" = "$ep_want" ]; then
      mount --bind "$G/$ep_file" "$ep_target" && log "early: patched $ep_target"
    fi
  done < "$G/patched/MANIFEST"
}
chroot() {
  if [ -z "$GBOS_EARLY_DONE" ] && [ "$1" = /new ]; then
    GBOS_EARLY_DONE=1
    gbos_early_patch
  fi
  command chroot "$@"
}
