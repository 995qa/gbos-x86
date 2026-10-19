#!/bin/sh
# Surface Laptop 7 (Intel, Lunar Lake): ACPI match for the Surface Aggregator platform hub (MSHW0551). Run inside gbos-kbuild.
# Mainline already defines ssam_node_group_sl7 (battery, AC, fan, platform profile, internal keyboard) but only references it from
# the device-tree table (the Snapdragon Surface Laptop 7), so on x86 nothing binds and keyboard/battery never appear.
# The same entry linux-surface carries in patches/6.19/0007-surface-sam.patch (see nierdal's write-up in linux-surface issue #1710).
# Idempotent.
set -e
F=${SRC:-/build/src}/drivers/platform/surface/surface_aggregator_registry.c
grep -q MSHW0551 $F || sed -i '/^static const struct acpi_device_id ssam_platform_hub_acpi_match\[\] = {$/a\
\t/* Surface Laptop 7 (Intel Lunar Lake) */\
\t{ "MSHW0551", (unsigned long)ssam_node_group_sl7 },' $F
grep -n -B1 'MSHW0551' $F
