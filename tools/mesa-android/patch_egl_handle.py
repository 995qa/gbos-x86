#!/usr/bin/env python3
"""Patch Mesa's Android EGL platform so that it can import the gralloc buffers of a mapper4
based gralloc (cros_gralloc/minigbm, as in Google's desktop image).

  patch_egl_handle.py MESA_SRC_DIR

Why: with a mapper4 gralloc the framework's ANativeWindowBuffer carries no native handle.
AOSP's GraphicBuffer::initWithSize() (the mapper4 path) fills in width/height/stride/format/
usage but never the handle - only the legacy initWithHandle() does. Mesa's u_gralloc (every
backend) starts from that handle, so every import fails and nothing is rendered (a black
screen: the apps and SurfaceFlinger cannot draw into their buffers).

The fix has two parts:
 1. when the window buffer has no handle, take it from the AHardwareBuffer (which *is* the
    GraphicBuffer) with AHardwareBuffer_getNativeHandle() - its handle holds the dma-buf that
    u_gralloc imports. That function is a private AOSP API (the NDK does not export it, the
    framework's libnativewindow.so does), so the patch declares it.
 2. u_gralloc's CrOS backend cannot be used with a mapper4 gralloc: it asks the gralloc
    module for the buffer info with a "perform" call that expects the module's own handle
    format. The fallback backend reads the dma-buf fd straight from the handle, which is what
    we have, so it is tried first.

Also use DRM_FORMAT_MOD_LINEAR for those buffers: u_gralloc's fallback backend reports
DRM_FORMAT_MOD_INVALID, and the DRI2 import needs the modifier to know the number of planes.

Idempotent: running it twice does nothing the second time.
"""
import os
import sys

REL = 'src/egl/drivers/dri2/platform_android.c'
REL_GRALLOC = 'src/util/u_gralloc/u_gralloc.c'

INCLUDES_OLD = """#include <cutils/properties.h>
#include <drm-uapi/drm_fourcc.h>
"""
INCLUDES_NEW = """#include <cutils/properties.h>
#include <android/hardware_buffer.h>
#include <drm-uapi/drm_fourcc.h>

#include "util/log.h"
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
      if (ahb) {
         gr_handle.handle = AHardwareBuffer_getNativeHandle(ahb);
         mesa_logi("gbos: native handle from the AHardwareBuffer: %d fds",
                   gr_handle.handle ? gr_handle.handle->numFds : -1);
      }
   }

   if (u_gralloc_get_buffer_basic_info(dri2_dpy->gralloc, &gr_handle,
                                       &buf_info)) {
      mesa_loge("gbos: no buffer info for the window buffer");
      return 0;
   }

   /* gbos: u_gralloc's fallback backend has no modifier information and the DRI2 import needs
    * it to know the number of planes - gralloc buffers are linear */
   if (buf_info.modifier == DRM_FORMAT_MOD_INVALID)
      buf_info.modifier = DRM_FORMAT_MOD_LINEAR;
"""

# u_gralloc: try the fallback backend before the CrOS one (the CrOS "perform" call does not
# understand the handles of a mapper4 gralloc)
GRALLOC_OLD = """} u_grallocs[] = {
   /* Prefer the CrOS API as it is significantly faster than IMapper4 */
   {.type = U_GRALLOC_TYPE_CROS, .create = u_gralloc_cros_api_create},
"""
GRALLOC_NEW = """} u_grallocs[] = {
   /* gbos: the fallback backend first - the CrOS API's "perform" call does not understand
    * the handles of a mapper4 gralloc (see tools/mesa-android/patch_egl_handle.py) */
   {.type = U_GRALLOC_TYPE_FALLBACK, .create = u_gralloc_fallback_create},
   /* Prefer the CrOS API as it is significantly faster than IMapper4 */
   {.type = U_GRALLOC_TYPE_CROS, .create = u_gralloc_cros_api_create},
"""


def patch_file(path, edits):
    s = open(path).read()
    for old, new, what in edits:
        if s.count(old) != 1:
            if new in s:
                continue
            sys.exit('anchor mismatch (%s): found %d' % (what, s.count(old)))
        s = s.replace(old, new)
    open(path, 'w').write(s)


def main():
    root = sys.argv[1]
    path = os.path.join(root, REL)
    if not os.path.exists(path):
        sys.exit('no such file: %s' % path)
    if 'AHardwareBuffer_getNativeHandle' in open(path).read():
        print('already patched')
        return
    patch_file(path, ((INCLUDES_OLD, INCLUDES_NEW, 'the includes'),
                      (BODY_OLD, BODY_NEW, 'the import')))
    # the declaration goes in front of droid_create_image_from_native_buffer
    s = open(path).read()
    anchor = 'static struct dri_image *\ndroid_create_image_from_native_buffer('
    if s.count(anchor) != 1:
        sys.exit('anchor mismatch (the declaration)')
    open(path, 'w').write(s.replace(anchor, DECL + anchor))
    # and u_gralloc has to use the fallback backend
    patch_file(os.path.join(root, REL_GRALLOC),
               ((GRALLOC_OLD, GRALLOC_NEW, 'the u_gralloc backends'),))
    print('patched %s and %s' % (REL, REL_GRALLOC))


if __name__ == '__main__':
    main()
