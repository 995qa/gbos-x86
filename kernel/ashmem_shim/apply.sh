#!/bin/sh
# Run inside the kernel source root (/build/src). Idempotent.
# Adds CONFIG_MEMFD_ASHMEM_SHIM: ashmem ioctls on memfd in C, for builds with CONFIG_RUST=n (where
# the Rust ashmem driver, and with it the memfd ioctls in mm/shmem.c, are compiled out).
# mm/Makefile already has the obj- line for memfd-ashmem-shim.o.
set -e
P=${P:-/host/kernel/ashmem_shim}
cp $P/memfd-ashmem-shim.c mm/
grep -q 'memfd-ashmem-shim.o' mm/Makefile
grep -q 'config MEMFD_ASHMEM_SHIM' mm/Kconfig || sed -i '/^config MEMFD_CREATE$/i \
config MEMFD_ASHMEM_SHIM\
\tbool "ashmem ioctls on memfd without the Rust ashmem driver"\
\tdepends on MEMFD_CREATE \&\& !ASHMEM\
\tdefault y\
\thelp\
\t  Answers the ashmem ioctls on memfd files so libcutils uses memfd\
\t  instead of /dev/ashmem. C port of ashmem_memfd_ioctl() in\
\t  drivers/staging/android/ashmem.rs.\
' mm/Kconfig
sed -i 's/^#ifdef CONFIG_ASHMEM$/#if IS_ENABLED(CONFIG_ASHMEM) || IS_ENABLED(CONFIG_MEMFD_ASHMEM_SHIM)/' mm/shmem.c
grep -c 'CONFIG_MEMFD_ASHMEM_SHIM' mm/shmem.c
