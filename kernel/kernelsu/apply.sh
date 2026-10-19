#!/bin/sh
# Build KernelSU into the kernel (CONFIG_KSU=y). Run inside the build container,
# in the kernel source root (/build/src). Idempotent.
#
# KernelSU (tiann/KernelSU, GPL-2.0) is linked into drivers/kernelsu the way
# upstream's kernel/setup.sh does, and the build gets the options the module
# build would pass on the command line (an in-tree build has no autoconf.h
# force-include in every file, so the x86_64 dispatcher patch would be missed).
#
# The x86_64 syscall dispatcher patch (CONFIG_KSU_X86_PATCH_SYSCALL_DISPATCHER)
# is what makes KernelSU work on 6.9+ kernels: upstream x86 dispatches syscalls
# through a switch statement (arch/x86/entry/syscall_64.c), so patching
# sys_call_table[] has no effect. KernelSU then patches x64_sys_call itself.
set -e
P=${P:-/host/kernel/kernelsu}
KSU=${KSU_SRC:-/build/inputs/KernelSU}
cd /build/src

[ -d "$KSU/kernel" ] || { echo "KernelSU sources not found: $KSU" >&2; exit 1; }

# 1. the sources: a symlink into the KernelSU checkout, the way upstream's kernel/setup.sh does it.
# The symlink matters: KernelSU derives its version from the commit count of its own git checkout
# (the manager app refuses a kernel older than version 32513), so the sources have to stay in the
# git repository.
rm -rf drivers/kernelsu
ln -s ../../inputs/KernelSU/kernel drivers/kernelsu
[ -f drivers/kernelsu/Kbuild ] || { echo "drivers/kernelsu does not point at the KernelSU sources" >&2; exit 1; }

# 2. the options the external-module build passes with -D. An in-tree build sees them through
# autoconf.h, but not in every file, so pass them explicitly. KernelSU tests them with #ifdef,
# so a disabled option must stay undefined (not "0").
KB=drivers/kernelsu/Kbuild
# an earlier version of this script added the options unconditionally; remove that
sed -i '/ccflags-y += -DCONFIG_KSU_.*\$(if/d' "$KB"
python3 - "$KB" <<'EOF'
import sys

path = sys.argv[1]
begin = "# gbos: in-tree build (begin)"
end = "# gbos: in-tree build (end)"
block = """%s
# The external-module build passes these with -D (an external module does not get autoconf.h
# force-included); an in-tree build sees them through autoconf.h, but not in every file.
# KernelSU tests them with #ifdef, so only the enabled ones are defined here.
ifeq ($(CONFIG_KSU_DISABLE_MANAGER),y)
ccflags-y += -DCONFIG_KSU_DISABLE_MANAGER=1
endif
ifeq ($(CONFIG_KSU_DISABLE_POLICY),y)
ccflags-y += -DCONFIG_KSU_DISABLE_POLICY=1
endif
ifeq ($(CONFIG_KSU_DEBUG),y)
ccflags-y += -DCONFIG_KSU_DEBUG=1
endif
ifeq ($(CONFIG_KSU_X86_PATCH_SYSCALL_DISPATCHER),y)
ccflags-y += -DCONFIG_KSU_X86_PATCH_SYSCALL_DISPATCHER=1
endif
%s
""" % (begin, end)

text = open(path).read()
if begin in text:
    head = text[:text.index(begin)]
    tail = text[text.index(end) + len(end):]
    text = head + block + tail
else:
    text = text.rstrip("\n") + "\n\n" + block
open(path, "w").write(text)
EOF

# 3. drivers/Makefile and drivers/Kconfig
grep -q "kernelsu" drivers/Makefile || printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> drivers/Makefile
grep -q 'source "drivers/kernelsu/Kconfig"' drivers/Kconfig || \
  sed -i '/^endmenu/i source "drivers/kernelsu/Kconfig"' drivers/Kconfig

# 4. report
echo "kernelsu: $(ls drivers/kernelsu/ | tr '\n' ' ')"
n=$(cd drivers/kernelsu && git rev-list --count HEAD 2>/dev/null)
echo "version: $n commits -> KSU_VERSION $((30000 + ${n:-0}))"
grep -c kernelsu drivers/Makefile
grep -c "drivers/kernelsu/Kconfig" drivers/Kconfig
