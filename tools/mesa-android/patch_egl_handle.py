#!/usr/bin/env python3
"""Patch Mesa's Android EGL platform so that it can import the gralloc buffers of a mapper4
based gralloc (cros_gralloc/minigbm, as in Google's desktop image).

  patch_egl_handle.py MESA_SRC_DIR

Why: with a mapper4 gralloc the framework's ANativeWindowBuffer carries no native handle.
AOSP's GraphicBuffer::initWithSize() (the mapper4 path) fills in width/height/stride/format/
usage but never the handle - only the legacy initWithHandle() does. Mesa's u_gralloc (every
backend) starts from that handle, so every import fails and nothing is rendered (a black
screen: the apps and SurfaceFlinger cannot draw into their buffers).

The fix: when the window buffer has no handle, take it from the AHardwareBuffer (which *is*
the GraphicBuffer) with the NDK's AHardwareBuffer_getNativeHandle() - its handle holds the
dma-buf that u_gralloc's fallback backend imports. Also use DRM_FORMAT_MOD_LINEAR for those
buffers: u_gralloc's fallback backend reports DRM_FORMAT_MOD_INVALID, and the DRI2 import
needs the modifier to know the number of planes.

Idempotent: running it twice does nothing the second time.
"""
import os
import sys

REL = 'src/egl/drivers/dri2/platform_android.c'

INCLUDES_OLD = """#include <cutils/properties.h>
#include <drm-uapi/drm_fourcc.h>
"""
INCLUDES_NEW = """#include <cutils/properties.h>
#include <android/hardware_buffer.h>
#include <drm-uapi/drm_fourcc.h>
"""

DECL = """/* gbos: the NDK does not export this one (it is a private AOSP API), but the
 * framework's libnativewindow.so has it - and that is the one that runs.
 */
extern const native_handle_t *AHardwareBuffer_getNativeHandle(const AHardwareBuffer *buffer);

"""

BODY_OLD = """   struct dri_image *img = NULL;

   if (u_gralloc_get_buffer_basic_info(dri2_dpy->gralloc, &gr_handle,
                                       &buf_info))
      return 0;
"""
BODY_NEW = """   struct dri_image *img = NULL;

   /* gbos: no handle in the window buffer (the mapper4 path of AOSP's GraphicBuffer does not
    * fill it in): take it from the AHardwareBuffer, which is the GraphicBuffer, so that u_gralloc
    * can import the dma-buf. See tools/mesa-android/patch_egl_handle.py. */
   if (!gr_handle.handle) {
      AHardwareBuffer *ahb = ANativeWindowBuffer_getHardwareBuffer(buf);
      if (ahb)
         gr_handle.handle = AHardwareBuffer_getNativeHandle(ahb);
   }

   if (u_gralloc_get_buffer_basic_info(dri2_dpy->gralloc, &gr_handle,
                                       &buf_info))
      return 0;

   /* gbos: u_gralloc's fallback backend has no modifier information and the DRI2 import needs
    * it to know the number of planes - gralloc buffers are linear */
   if (buf_info.modifier == DRM_FORMAT_MOD_INVALID)
      buf_info.modifier = DRM_FORMAT_MOD_LINEAR;
"""


def main():
    root = sys.argv[1]
    path = os.path.join(root, REL)
    if not os.path.exists(path):
        sys.exit('no such file: %s' % path)
    s = open(path).read()
    if 'AHardwareBuffer_getNativeHandle' in s:
        print('already patched')
        return
    for old, new, what in ((INCLUDES_OLD, INCLUDES_NEW, 'the includes'),
                            (BODY_OLD, BODY_NEW, 'the import')):
        if s.count(old) != 1:
            sys.exit('anchor mismatch (%s): found %d' % (what, s.count(old)))
        s = s.replace(old, new)
    # the declaration goes in front of droid_create_image_from_native_buffer
    anchor = 'static struct dri_image *\ndroid_create_image_from_native_buffer('
    if s.count(anchor) != 1:
        sys.exit('anchor mismatch (the declaration)')
    s = s.replace(anchor, DECL + anchor)
    open(path, 'w').write(s)
    print('patched %s' % REL)


if __name__ == '__main__':
    main()
