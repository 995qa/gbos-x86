# Surface Laptop 7 (Intel) runtime files

Copied to the stick as `gbos/surface/` (and by the installer to the internal disk).

| File | What |
|---|---|
| `iptsd-run.sh` | started by the `gbos_iptsd` service in `hook.sh`; finds the touchpad's hidraw node (045E:0C9F) and keeps `iptsd` running on it. Exits by itself on other laptops. |
| `iptsd.conf` | touchpad calibration |
| `iptsd`, `iptsd-check-device` | static binaries, **not committed**: built by `tools/build_surface_tools.sh` (alex-lentz/iptsd, a fork of linux-surface/iptsd with Surface Laptop 7 support, plus `tools/iptsd/0004-...patch`) |

Without the two binaries nothing happens: the touchpad then still moves the pointer and clicks by tapping, as before.

Credit: the iptsd fork is alex-lentz's; the calibration, the `LiftGraceMs` patch and most of what is known about this touchpad come from
nierdal's write-up in linux-surface/linux-surface issue #1710. iptsd is GPL-2.0-or-later.
