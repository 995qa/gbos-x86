#!/bin/sh
# Always drive the built-in panel (eDP) as full-range RGB (0-255). With Broadcast RGB = Automatic,
# i915 picks limited range (16-235) whenever the mode matches a CEA timing, which lifts black to grey.
# This rules that out on the Latitude 5300 (washed-out picture, "white veil" even on video).
# External DP/HDMI keep i915's normal behaviour. Idempotent.
set -e
cd /build/src/drivers/gpu/drm/i915/display
grep -q 'gbos: eDP is always full-range RGB' intel_dp.c && { echo already; exit 0; }
[ "$(grep -c '^	if (crtc_state->output_format != INTEL_OUTPUT_FORMAT_RGB)$' intel_dp.c)" -ge 1 ] || { echo "anchor mismatch"; exit 1; }
# Insert right after the YCbCr early return in intel_dp_limited_color_range().
awk '
  /^bool intel_dp_limited_color_range\(/ { infn=1 }
  { print }
  infn && /^		return false;$/ && !done {
    print ""
    print "\t/* gbos: eDP is always full-range RGB (kernel/isa_emu_patch/i915_edp_full_range.sh). */"
    print "\tif (conn_state->connector->connector_type == DRM_MODE_CONNECTOR_eDP)"
    print "\t\treturn false;"
    done=1; infn=0
  }
' intel_dp.c > intel_dp.c.new && mv intel_dp.c.new intel_dp.c
grep -n -B6 -A3 'gbos: eDP is always full-range RGB' intel_dp.c
