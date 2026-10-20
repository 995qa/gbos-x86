#!/usr/bin/env python3
"""Run from the Mesa source root; idempotent.

RADV's own vkGetAndroidHardwareBufferPropertiesANDROID returns format UNDEFINED / externalFormat 0 for a YV12 buffer, so Skia fails
("Failed to create valid YCbCr conversion information") and SurfaceFlinger aborts. Renaming it makes the entrypoint table fall back to
the common vk_common_ implementation, which reports YV12 as external format G8_B8_R8_3PLANE_420."""
import sys

P = 'src/amd/vulkan/radv_android.c'
OLD = 'VkResult\nradv_GetAndroidHardwareBufferPropertiesANDROID('
NEW = 'static VkResult __attribute__((unused))\ngbos_unused_radv_GetAndroidHardwareBufferPropertiesANDROID('

s = open(P).read()
if NEW in s:
    print('already patched:', P)
elif s.count(OLD) != 1:
    sys.exit(f'{P}: anchor found {s.count(OLD)} times')
else:
    open(P, 'w').write(s.replace(OLD, NEW))
    print('patched:', P)
