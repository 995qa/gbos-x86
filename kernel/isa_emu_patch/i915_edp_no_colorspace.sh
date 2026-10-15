#!/bin/sh
# Don't create the Colorspace property on eDP at all, so drm_hwcomposer can't ask for BT2020_RGB on the
# built-in panel. Stronger than i915_edp_colorspace.sh (which ignores the value); kept together with it.
# Risk: an HWC that requires the property on every connector would refuse to drive the panel. External
# DP/HDMI keep it. Idempotent.
set -e
cd /build/src/drivers/gpu/drm/i915/display
grep -q 'gbos: no Colorspace property on eDP' intel_dp.c && { echo already; exit 0; }
[ "$(grep -c '^		intel_attach_dp_colorspace_property(&connector->base);$' intel_dp.c)" = 1 ] || { echo "anchor mismatch"; exit 1; }
sed -i 's/^		intel_attach_dp_colorspace_property(&connector->base);$/		if (!intel_dp_is_edp(intel_dp))	\/* gbos: no Colorspace property on eDP *\/\n\t\t\tintel_attach_dp_colorspace_property(\&connector->base);/' intel_dp.c
grep -n -B3 -A2 'gbos: no Colorspace property on eDP' intel_dp.c
