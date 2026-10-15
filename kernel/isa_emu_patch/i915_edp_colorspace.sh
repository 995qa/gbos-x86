#!/bin/sh
# Ignore the Colorspace property on eDP. Google's drm_hwcomposer sets it to BT2020_RGB on the
# built-in panel, so i915 sends a VSC SDP saying "BT.2020 RGB". The Latitude 5300's LG LP133WF6
# (an sRGB panel) honours that, gamut-maps the sRGB content into its own gamut, and everything
# looks pale. SurfaceFlinger really outputs sRGB, so eDP always gets the default colorimetry.
# The property itself stays (the HWC may depend on it); external DP/HDMI are unchanged. Idempotent.
set -e
cd /build/src/drivers/gpu/drm/i915/display
grep -q gbos_dp_colorspace intel_dp.c && { grep -c gbos_dp_colorspace intel_dp.c; exit 0; }
[ "$(grep -c '^	switch (conn_state->colorspace) {$' intel_dp.c)" = 2 ] || { echo "anchor mismatch"; exit 1; }
sed -i '/^static void intel_dp_compute_vsc_colorimetry(const struct intel_crtc_state \*crtc_state,$/i\
/* gbos: eDP always gets the default colorimetry (see kernel/isa_emu_patch/i915_edp_colorspace.sh). */\
static enum drm_colorspace gbos_dp_colorspace(const struct drm_connector_state *conn_state)\
{\
	if (conn_state->connector->connector_type == DRM_MODE_CONNECTOR_eDP)\
		return DRM_MODE_COLORIMETRY_DEFAULT;\
	return conn_state->colorspace;\
}\
' intel_dp.c
sed -i 's/^	switch (conn_state->colorspace) {$/	switch (gbos_dp_colorspace(conn_state)) {/' intel_dp.c
grep -c gbos_dp_colorspace intel_dp.c
