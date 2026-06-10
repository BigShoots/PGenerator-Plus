# Pi5 parity baseline (pre-fix)

Captured 2026-06-10 (read-only) from the Pi5 at 192.168.1.249, as part of the
Pi5 functional-parity work (`.kilo/plans/pi5-functional-parity.md`). The goal:
the Pi5 must output exactly what the user or connected software configures —
output format, quantization range, colorspace/AVI signalling, bit depth, HDR
metadata — with the same fidelity as the Pi4 reference (192.168.1.179).

## Parity gaps identified

| # | Gap | Evidence |
|---|-----|----------|
| G1 | ~~Loaded vc4 has no `output format` connector property~~ **RESOLVED 2026-06-10 — measurement artifact.** The patched module IS loaded (running srcversion `FE6D3C3FFE4E28A6622CFE8` matches the repo artifact `vc4-6.12.25-rpt-rpi-v8-dv-vsif.ko.xz`) and the property exists on both connectors (`RGB444=0 YCBCR444=1 YCBCR422=2`), but it is created with `DRM_MODE_PROP_ATOMIC` so it is hidden from non-atomic clients — it only shows under `modetest -a -c`. Real fix: all tooling must list/write with the atomic cap (`kms_connector_has_property` and `modetest_connector_write` in command.pm updated accordingly). No kernel install or reboot was needed | `modetest -M vc4 -a -c` shows props 41/48 |
| G2 | Wire `Broadcast RGB = 1 (Full)` while conf `rgb_quant_range=1` (Limited). Enum semantics differ: conf `1=Limited, 2=Full`; Broadcast RGB `0=Automatic, 1=Full, 2=Limited 16:235`. Repo mapping helpers are correct; the deployed stack is stale | `modetest` value 1 vs conf |
| G3 | Wire `Colorspace = 9 (BT2020_RGB)` while conf is `colorimetry=9 + color_format=1` (YCC) → should be 10 (BT2020_YCC) once YCC output works | `modetest` value 9 |
| G4 | Deployed Perl stack stale and three-way diverged (deployed `command.pm` md5 `de038d9a…` ≠ repo `86ee72f5…` ≠ pi5 rootfs overlay `be25315a…`) | md5 capture below |
| G5 | Pi5 renderer source lacks the Pi4 lifted-blacks fix (84ed1cc7): no `pg_read_conf_*` helpers; HLG branch zero-inits min_dml; HDR branch uses startup-only values | source grep |
| G6 | Real Pi5 build sources (`ofApp.cpp`, `ofApp.h`, `rgb2ycbcr.h`) untracked — exist only in `/home/jordan/pgplus-cross/build-pi5-hdr-limited/pattern_generator/src/` | tree listing |
| G7 | Pi5 conf `min_luma=0.005` vs Pi4 reference `0.0005` (min_dml 50 vs 5) | conf below |
| G8 | Pi5 runs without `drm_override.so` (daemon skips it on Colorspace kernels, `command.pm:467-469`) → no enforcement net; persistence across renderer atomic commits must be proven | code |
| G9 | Wire `max bpc = 8` while conf says `max_bpc=10` (renderer not running; nothing reapplied properties) | capture below |

## Raw capture (2026-06-10)

```
## os
PRETTY_NAME="Raspbian GNU/Linux 12 (bookworm)"
6.12.25+rpt-rpi-v8
## conf
ip_pattern=0.0.0.0
port_pattern=85
calman_mode_idx=30
dv_profile=1
min_luma=0.005
mode_idx=30
dv_color_space=0
color_format=1
colorimetry=9
dv_interface=0
dv_metadata=0
dv_status=0
eotf=2
is_hdr=1
is_ll_dovi=0
is_sdr=0
is_std_dovi=0
max_bpc=10
max_cll=1000
max_fall=400
max_luma=1000
primaries=1
rgb_quant_range=1
signal_mode=hdr10
## binaries
c709cc6fb69e9b838c3a7f55b550a4c1  /usr/sbin/PGeneratord
c709cc6fb69e9b838c3a7f55b550a4c1  /usr/sbin/PGeneratord.dv
-rwxr-xr-x 1 root root 2591388 Jun  7 20:57 /usr/sbin/PGeneratord
-rwxr-xr-x 1 root root 2591388 Jun  7 20:57 /usr/sbin/PGeneratord.dv
-rwxr-xr-x 1 root root    2717 May  5 06:07 /usr/sbin/PGeneratord.pl
## perl
4d4e0ffd5387c2b40531534285645be7  /usr/share/PGenerator/bash.pm
226570fa1b8e173e3e75b7b94f480d45  /usr/share/PGenerator/client.pm
de038d9a3528c258c17d6611a8a606b2  /usr/share/PGenerator/command.pm
aeca7b409c6a72fa7863577fe4b19602  /usr/share/PGenerator/conf.pm
14a3a156fe88c56d41f449c96aeba275  /usr/share/PGenerator/daemon.pm
6fe70d1837e441b7b66fa71a225d7c43  /usr/share/PGenerator/discovery.pm
e335b104b1c0efe0ddc41efc5c082384  /usr/share/PGenerator/file.pm
6430e1afcd66fb14d8ed388b32c86268  /usr/share/PGenerator/info.pm
a3a6c1045d8cd6aed0b93b0f51cc6dee  /usr/share/PGenerator/lg.pm
34ea7788a8ca4ad98b454eb8e1f9c209  /usr/share/PGenerator/log.pm
9c35f2468bf4ece19ced59d6be085dd4  /usr/share/PGenerator/pattern.pm
e91c81be543bb5b2e5efee2c5487b719  /usr/share/PGenerator/resolve.pm
984964802e5b7d49a2f5c598bb3916de  /usr/share/PGenerator/serial.pm
99fa8eebf262e6d379948900aa15e8fe  /usr/share/PGenerator/variables.pm
290203fafb274e5775580170e0cdbaa3  /usr/share/PGenerator/version.pm
109e387e6ca01ad54e536751ae3b7622  /usr/share/PGenerator/webui.pm
## connector props
Connectors:
	34 max bpc:
	7 HDR_OUTPUT_METADATA:
	39 Colorspace:
	40 Broadcast RGB:
	42 DOVI_OUTPUT_METADATA:
	45 max bpc:
	7 HDR_OUTPUT_METADATA:
	46 Colorspace:
	47 Broadcast RGB:
	49 DOVI_OUTPUT_METADATA:
## prop values (HDMI-A-1 = props 34/39/40, HDMI-A-2 = 45/46/47)
	39 Colorspace:   value: 9
	46 Colorspace:   value: 0
	40 Broadcast RGB: value: 1
	47 Broadcast RGB: value: 0
	34 max bpc:      values: 8 12   value: 8
	45 max bpc:      values: 8 12   value: 8
## vc4
/lib/modules/6.12.25+rpt-rpi-v8/kernel/drivers/gpu/drm/vc4/vc4.ko.xz
f7480f8fe82656209deea71e8762e67d  (loaded module: has DOVI_OUTPUT_METADATA, lacks "output format")
## procs
renderer not running
PGeneratord.pl running (pid 5167, since Jun 07)
```

## Notes
- The loaded vc4 module exposes `DOVI_OUTPUT_METADATA` (DV-VSIF patch present)
  but NOT the `output format` property — any replacement module must keep both.
- A completed DV greyscale meter series exists on this Pi5 (series status
  `complete`), so the device is in active calibration use; deploys must check
  idle state first.
