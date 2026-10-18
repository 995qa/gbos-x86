#!/usr/bin/env python3
"""Let Google's vendor gralloc (libminigbm_gralloc.so, minigbm statically linked) allocate buffers on an AMD GPU.

  patch_gralloc_amdgpu.py IN OUT

THIS is the library that matters for graphics (gralloc.minigbm.so, mapper.minigbm.so and the allocator service all link it; the
separate /vendor/lib64/libgbm.so is only used by the camera and video-codec HALs, see patch_libgbm_amdgpu.py).

minigbm picks a backend by comparing the DRM driver name (drmGetVersion) with a chain of string literals (inlined drv_get_backend,
.text 0xc4c0..0xc710); each branch loads the matching `struct backend`. Google's build has no amdgpu backend, so gralloc fails on a
Ryzen laptop. Eight backends (komeda, radeon, nouveau, vkms, ...) are the *same* generic linear dumb-buffer one (identical init
0xef30 / bo_create_with_modifiers 0xf040: every render/texture format linear, drv_dumb_bo_create_ex). The "komeda" one (ARM Mali
display processor, never on x86) has a 7-byte string literal "komeda\\0": it is rewritten to "amdgpu\\0", so the comparison chain and
that backend's name both say "amdgpu". Dumb buffers are allowed on render nodes (DRM_RENDER_ALLOW in kernel 6.18's drm_ioctl.c), so
cros_gralloc's render-node-first search (renderD128..) works.

Second edit: cros_gralloc_driver::init sets a "software renderer" flag when the property ro.hardware.vulkan contains "lvp" or "pastel"
(drv_get_os_option + strstr, .text 0x17326..0x1737d; Google's own hook for SwiftShader/lavapipe, whose vulkan.pastel.so the image
does not ship). cros_gralloc_driver::lock (0x19140) refuses CPU access to a buffer that was not allocated with CPU usage unless that
flag is set, but a CPU Vulkan driver must lock every buffer ANGLE/Skia/SurfaceFlinger hand it (AHardwareBuffer_lockPlanes). Setting
ro.hardware.vulkan=pastel would also need a vulkan.pastel.so in /vendor/lib64/hw (read-only erofs: a tmpfs overlay of that directory),
so instead the literal "pastel\\0" is rewritten to "intel\\0\\0": the flag is set for ro.hardware.vulkan=intel, which hook.sh keeps.

Only applied to the exact original (sha256 pinned): the offset is into one specific build.
"""
import hashlib, sys

ORIG_SHA = 'd48536951fd0e9643e71a5c8843e90833ce3e212e182782185470e2fbbfad673'
KOMEDA = 0x50b7   # .rodata literal compared at 0xc549 and pointed to by backend_komeda.name (file 0x1c238)
PASTEL = 0x51af   # .rodata literal strstr()'d against ro.hardware.vulkan at 0x17364 (its only reference)


def main():
    src, dst = sys.argv[1], sys.argv[2]
    d = bytearray(open(src, 'rb').read())
    if hashlib.sha256(d).hexdigest() != ORIG_SHA:
        sys.exit('unexpected libminigbm_gralloc.so (sha256 differs from the build this patch was made for)')
    assert d[KOMEDA:KOMEDA + 7] == b'komeda\0' and d[KOMEDA - 1] == 0
    assert b'amdgpu' not in d
    d[KOMEDA:KOMEDA + 7] = b'amdgpu\0'
    assert d[PASTEL:PASTEL + 7] == b'pastel\0' and d[PASTEL - 1] == 0 and d.count(b'pastel') == 1
    d[PASTEL:PASTEL + 7] = b'intel\0\0'
    open(dst, 'wb').write(d)
    print('patched: generic linear backend answers to DRM driver "amdgpu"; software-renderer flag set by ro.hardware.vulkan=intel')


if __name__ == '__main__':
    main()
