#!/usr/bin/env python3
"""Patch Mesa's Android EGL platform so that it can import the gralloc buffers of a mapper4
based gralloc (cros_gralloc/minigbm, as in Google's desktop image).

  patch_egl_handle.py MESA_SRC_DIR

Why: with a mapper4 gralloc the framework's ANativeWindowBuffer carries no native handle.
AOSP's GraphicBuffer::initWithSize() (the mapper4 path) fills in width/height/stride/format/
usage but never the handle - only the legacy initWithHandle() does. Mesa's u_gralloc needs
that handle to import the dma-buf, so every import fails and nothing is rendered (a black
screen: the apps and SurfaceFlinger cannot draw into their buffers).

The fix: when the window buffer has no handle, get it from the AHardwareBuffer (which is the
GraphicBuffer) with the NDK's AHardwareBuffer_sendHandleToUnixSocket(), and build a native
handle with the dma-buf fd for u_gralloc's fallback backend. Also use DRM_FORMAT_MOD_LINEAR
for those buffers: u_gralloc's fallback backend reports DRM_FORMAT_MOD_INVALID, and the DRI2
import needs the modifier to know the number of planes.

Idempotent: running it twice does nothing the second time.
"""
import os
import sys

REL = 'src/egl/drivers/dri2/platform_android.c'

INCLUDES_OLD = """#include <stdbool.h>
#include <stdio.h>
#include <xf86drm.h>
#include <cutils/properties.h>
#include <drm-uapi/drm_fourcc.h>
"""
INCLUDES_NEW = """#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <xf86drm.h>
#include <cutils/properties.h>
#include <android/hardware_buffer.h>
#include <drm-uapi/drm_fourcc.h>
"""

HELPER = '''
/*
 * gbos: get the native handle of a window buffer when the framework did not put one into
 * the ANativeWindowBuffer (the mapper4 path of AOSP's GraphicBuffer does not), so that
 * u_gralloc can import the dma-buf. See tools/mesa-android/patch_egl_handle.py.
 */
static native_handle_t *
droid_get_buffer_handle(struct ANativeWindowBuffer *buf)
{
   AHardwareBuffer *ahb;
   native_handle_t *handle = NULL;
   int sockets[2];
   struct msghdr msg;
   struct iovec iov;
   struct cmsghdr *cmsg;
   char data[1] = { 0 };
   char control[CMSG_SPACE(sizeof(int))];

   ahb = ANativeWindowBuffer_getHardwareBuffer(buf);
   if (!ahb)
      return NULL;

   if (socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) < 0)
      return NULL;

   if (AHardwareBuffer_sendHandleToUnixSocket(ahb, sockets[1]) < 0) {
      close(sockets[0]);
      close(sockets[1]);
      return NULL;
   }
   close(sockets[1]);

   memset(&msg, 0, sizeof(msg));
   memset(control, 0, sizeof(control));
   iov.iov_base = data;
   iov.iov_len = sizeof(data);
   msg.msg_iov = &iov;
   msg.msg_iovlen = 1;
   msg.msg_control = control;
   msg.msg_controllen = sizeof(control);

   if (recvmsg(sockets[0], &msg, 0) < 0) {
      close(sockets[0]);
      return NULL;
   }

   cmsg = CMSG_FIRSTHDR(&msg);
   if (!cmsg || cmsg->cmsg_type != SCM_RIGHTS) {
      close(sockets[0]);
      return NULL;
   }

   handle = native_handle_create(1, 0);
   if (handle)
      handle->data[0] = *(int *)CMSG_DATA(cmsg);
   else
      close(*(int *)CMSG_DATA(cmsg));
   close(sockets[0]);

   return handle;
}

'''

BODY_OLD = """   struct dri_image *img = NULL;

   if (u_gralloc_get_buffer_basic_info(dri2_dpy->gralloc, &gr_handle,
                                       &buf_info))
      return 0;
"""
BODY_NEW = """   struct dri_image *img = NULL;
   native_handle_t *own_handle = NULL;

   /* gbos: no handle in the window buffer (mapper4 gralloc): get it from the AHardwareBuffer */
   if (!gr_handle.handle) {
      own_handle = droid_get_buffer_handle(buf);
      gr_handle.handle = own_handle;
   }

   if (u_gralloc_get_buffer_basic_info(dri2_dpy->gralloc, &gr_handle,
                                       &buf_info))
   {
      if (own_handle) {
         native_handle_close(own_handle);
         native_handle_delete(own_handle);
      }
      return 0;
   }

   /* gbos: u_gralloc's fallback backend has no modifier information and the DRI2 import needs
    * it to know the number of planes - gralloc buffers are linear */
   if (buf_info.modifier == DRM_FORMAT_MOD_INVALID)
      buf_info.modifier = DRM_FORMAT_MOD_LINEAR;
"""

TAIL_OLD = """   img = droid_create_image_from_buffer_info(
         dri2_dpy, buf->width, buf->height, &buf_info, &color_info, priv);
   }

   return img;
}
"""
TAIL_NEW = """   img = droid_create_image_from_buffer_info(
         dri2_dpy, buf->width, buf->height, &buf_info, &color_info, priv);
   }

   if (own_handle) {
      native_handle_close(own_handle);
      native_handle_delete(own_handle);
   }

   return img;
}
"""


def main():
    root = sys.argv[1]
    path = os.path.join(root, REL)
    if not os.path.exists(path):
        sys.exit('no such file: %s' % path)
    s = open(path).read()
    if 'droid_get_buffer_handle' in s:
        print('already patched')
        return
    for old, new, what in ((INCLUDES_OLD, INCLUDES_NEW, 'includes'),
                            (BODY_OLD, BODY_NEW, 'the import'),
                            (TAIL_OLD, TAIL_NEW, 'the cleanup')):
        if s.count(old) != 1:
            sys.exit('anchor mismatch (%s): found %d' % (what, s.count(old)))
        s = s.replace(old, new)
    # the helper goes in front of droid_create_image_from_native_buffer
    anchor = 'static struct dri_image *\ndroid_create_image_from_native_buffer('
    if s.count(anchor) != 1:
        sys.exit('anchor mismatch (the helper)')
    s = s.replace(anchor, HELPER.lstrip('\n') + anchor)
    open(path, 'w').write(s)
    print('patched %s' % REL)


if __name__ == '__main__':
    main()
