#!/bin/sh
# NVIDIA (nouveau): atomic modesetting, so that the Android hardware composer (drm_hwcomposer, which
# is atomic-only) can drive the card. Without it the HWC finds no pipeline
# ("drmhwc: No pipelines available. Creating null-display for headless mode") and nothing is shown.
#
# Two parts, both from upstream:
#  1. drivers/gpu/drm/nouveau/nouveau_display.c: the DRM mode_config hooks for atomic modesetting
#     were never filled in, even though the encoder/connector/crtc helpers below them are
#     (Lyude Paul, "drm/nouveau/disp: Set drm_mode_config_funcs.atomic_(check|commit)", January 2026:
#     two lines, .atomic_commit = drm_atomic_helper_commit, .atomic_check = drm_atomic_helper_check).
#  2. drivers/gpu/drm/nouveau/nouveau_drm.c: the nouveau.atomic module parameter defaults to 0
#     ("Expose atomic ioctl (default: disabled)"), so the DRM core never gets DRIVER_ATOMIC and the
#     atomic ioctls stay hidden. Upstream changed the default to "auto" in August 2026
#     (Lyude Paul, "drm/nouveau: Enable atomic modesetting by default"): atomic is on for NV50 and
#     newer. We simply default the parameter to 1, which does the same for every card this kernel
#     supports (the driver only reaches this code for PCI chips).
#
# The parameter is still there: "nouveau.atomic=0" on the module load turns it off again.
# Idempotent.
set -e
cd /build/src/drivers/gpu/drm/nouveau

# 1. the atomic mode_config hooks
if ! grep -q 'gbos: atomic modesetting' nouveau_display.c; then
  [ "$(grep -c 'fb_create = nouveau_user_framebuffer_create,' nouveau_display.c)" = 1 ] || { echo "anchor mismatch (fb_create)"; exit 1; }
  awk '
    { print }
    /\t\.fb_create = nouveau_user_framebuffer_create,$/ {
      print "\t/* gbos: atomic modesetting (upstream: drm/nouveau/disp, January 2026) */"
      print "\t.atomic_commit = drm_atomic_helper_commit,"
      print "\t.atomic_check = drm_atomic_helper_check,"
    }' nouveau_display.c > /tmp/nd.new && mv /tmp/nd.new nouveau_display.c
  grep -q 'drm_atomic_helper_commit' nouveau_display.c || { echo "patch failed"; exit 1; }
fi

# 2. atomic on by default (the nouveau.atomic parameter)
if ! grep -q 'gbos: atomic modesetting on by default' nouveau_drm.c; then
  [ "$(grep -c '^static int nouveau_atomic = 0;$' nouveau_drm.c)" = 1 ] || { echo "anchor mismatch (nouveau_atomic)"; exit 1; }
  sed -i 's/^static int nouveau_atomic = 0;$/static int nouveau_atomic = 1; \/* gbos: atomic modesetting on by default (upstream, August 2026) *\//' nouveau_drm.c
  grep -q 'gbos: atomic modesetting on by default' nouveau_drm.c || { echo "patch failed (nouveau_atomic)"; exit 1; }
fi

grep -n -A 6 'nouveau_mode_config_funcs = {' nouveau_display.c
grep -n 'nouveau_atomic = ' nouveau_drm.c
