#!/bin/sh
# Ignore userspace gamma/degamma/CTM blobs: the pipe always runs linear (correct for an sRGB panel).
# Google's drm_hwcomposer is written for xe's LOG_GAMMA_LUT. On i915 it logs "Missing optional
# LOG_GAMMA_LUT property, falling back to GAMMA_LUT" on every commit and loads its curve into the
# linear GAMMA_LUT, which lifts the shadows: a white veil over everything, video included.
# The properties stay (the HWC keeps working); only the hardware ignores them. Costs gamma-based
# features such as Night Light. Idempotent.
set -e
cd /build/src/drivers/gpu/drm/i915/display
grep -q 'gbos: ignore userspace gamma' intel_display.c && { echo already; exit 0; }
python3 - intel_display.c <<'EOF'
import sys
p = sys.argv[1]; s = open(p).read()
old = """	drm_property_replace_blob(&crtc_state->hw.degamma_lut,
				  crtc_state->uapi.degamma_lut);
	drm_property_replace_blob(&crtc_state->hw.gamma_lut,
				  crtc_state->uapi.gamma_lut);
	drm_property_replace_blob(&crtc_state->hw.ctm,
				  crtc_state->uapi.ctm);
}"""
new = """	/* gbos: ignore userspace gamma/degamma/CTM (kernel/isa_emu_patch/i915_ignore_gamma.sh). */
	drm_property_replace_blob(&crtc_state->hw.degamma_lut, NULL);
	drm_property_replace_blob(&crtc_state->hw.gamma_lut, NULL);
	drm_property_replace_blob(&crtc_state->hw.ctm, NULL);
}"""
assert s.count(old) == 1, "anchor mismatch"
open(p, 'w').write(s.replace(old, new))
EOF
grep -n -B2 -A4 'gbos: ignore userspace gamma' intel_display.c
