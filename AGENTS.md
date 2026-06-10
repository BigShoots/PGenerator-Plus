
   Pi4 is reachable at 192.168.1.179 username root password PGenerator!!$
   Pi5 is reachable at 192.168.1.249
   Commit your changes as you make them so we can revert.

   Deploying runtime changes to the Pi4:
   - Do not deploy or restart during an active calibration, meter read, or pattern run unless explicitly asked.
   - Before copying Perl changes, run local syntax checks such as `perl -c usr/share/PGenerator/webui.pm`, `perl -c usr/bin/meter_lg_autocal.pl`, and `perl -c usr/sbin/pgenerator-lg` for any touched files.
   - Check Pi4 reachability/status first:
     SSHPASS='PGenerator!!$' sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/pgen_known_hosts root@192.168.1.179 'pgrep -af "PGeneratord|meter_|spotread" || true'
   - Back up the target files before overwriting them:
     SSHPASS='PGenerator!!$' sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/pgen_known_hosts root@192.168.1.179 'ts=$(date +%Y%m%d-%H%M%S); mkdir -p /root/pgen-backups/$ts; cp -a /usr/bin/meter_lg_autocal.pl /usr/bin/meter_lg_3d_autocal.pl /usr/sbin/pgenerator-lg /usr/share/PGenerator/webui.pm /root/pgen-backups/$ts/ 2>/dev/null; echo $ts'
   - Copy only the changed runtime files to their matching absolute paths, for example:
     SSHPASS='PGenerator!!$' sshpass -e scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/pgen_known_hosts -p usr/bin/meter_lg_autocal.pl usr/bin/meter_lg_3d_autocal.pl root@192.168.1.179:/usr/bin/
     SSHPASS='PGenerator!!$' sshpass -e scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/pgen_known_hosts -p usr/sbin/pgenerator-lg root@192.168.1.179:/usr/sbin/pgenerator-lg
     SSHPASS='PGenerator!!$' sshpass -e scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/pgen_known_hosts -p usr/share/PGenerator/webui.pm root@192.168.1.179:/usr/share/PGenerator/webui.pm
   - Restart PGenerator with the SysV init script. This image does not have systemctl/service; redirect output so SSH does not stay attached to daemon logs:
     SSHPASS='PGenerator!!$' sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/pgen_known_hosts root@192.168.1.179 '/etc/init.d/PGenerator restart >/tmp/PGenerator-restart.log 2>&1 </dev/null &'
   - Verify after restart from a fresh SSH command:
     SSHPASS='PGenerator!!$' sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/pgen_known_hosts root@192.168.1.179 'ps w | grep -E "[P]Generatord.pl|[P]Generator_serial" || true; wget -q -O - http://127.0.0.1/api/status 2>/dev/null | head -c 500 || true'

   Building the renderer (PGeneratord) on the Pi4:
   - The renderer is built on the Pi4 itself using `/opt/openFrameworks`. The prebuilt cross-compile env at `/home/jordan/pgplus-cross/` is for the Pi5 only; do not use it for Pi4 builds.
   - The build script is at `tools/scripts/build_pgeneratord_on_pi.sh` (a copy of the one in `/mnt/homestorage/Projects/PGenerator_reference/PGenerator_Source/build_pgeneratord_on_pi.sh`). The script syncs `tools/image-targets/pi4-biasi/src/pattern_generator/src/` and `tools/image-targets/pi4-biasi/src/ofxRPI4Window/src/` to the Pi, then runs `make` on the Pi.
   - Default build flags (on the Pi): `PLATFORM_OS=Linux PLATFORM_ARCH=armv6l PLATFORM_LIB_SUBPATH=linuxarmv6l PLATFORM_VARIANT=default`. These are the legacy OF flags the project actually uses; the OF tree is armv6-built even though the Pi4 is armv7.
   - For deploy flow use `--deploy`; the script will copy `bin/pattern_generator` to both `/usr/sbin/PGeneratord` and `/usr/sbin/PGeneratord.dv`, restart the service via `/etc/init.d/PGenerator`, and verify with `curl http://127.0.0.1/api/ping`.
   - The renderer's `updateHDR_Infoframe()` function in `ofxRPI4Window.cpp` had a long-standing zero-init bug for `min_display_mastering_luminance`. The fix is in commit `84ed1cc7`. Any future renderer change must preserve the conf read at the top of `updateHDR_Infoframe()` and the populated min/max DML/CLL/FALL fields, otherwise the LG C2 will re-apply a near-black lift at 5% stimulus.
   - After rebuilding, the on-wire HDR_OUTPUT_METADATA blob can be verified with `modetest -M vc4 -c 33 -p | grep -A 12 "7 HDR_OUTPUT_METADATA"` and decoded (32 bytes: 4-byte wrapper + infoframe struct with primaries, white_point, max/min_dml, max_cll, max_fall).
   - gstreamer for Pi4 builds: the build REQUIRES real gstreamer-1.0 development support — `/usr/lib/pkgconfig/gstreamer{,-app,-video,-base}-1.0.pc` plus headers in `/usr/include/gstreamer-1.0` (the BiasiLinux 1.0 image ships these; version 1.6.4; there is no package manager on the Pi). Pass `GST_VERSION=1.0` to make to pin the openFrameworks gstreamer selection. Creating fake/stub `.pc` files (e.g. gstreamer-0.10 stubs in /tmp) to satisfy the OF config check is FORBIDDEN.
   - Old-ABI flag plumbing: pass `PROJECT_CFLAGS='-D_GLIBCXX_USE_CXX11_ABI=0'` (and `PLATFORM_CXXFLAGS='-Wall -Werror=return-type -std=c++17 -DGCC_HAS_REGEX'` for c++17). Never pass `CXXFLAGS=`/`CFLAGS=` on the make command line: a command-line override silently drops the platform defines (`-DTARGET_RASPBERRY_PI`, `-march=armv6`, addon `-I/usr/include/libdrm`, ...) because OF composes them via `CXXFLAGS +=` in config.project.mk.
   - Renderer start race (pre-existing, not a renderer bug): `pattern_generator_start` in command.pm runs root DRM helpers (`apply_drm_properties`, `apply_hdr_metadata_helper`/pgsethdr) in the ~2s window after spawning the unprivileged renderer; if a helper holds DRM master while the renderer calls drmSetMaster, the renderer exits ("failed to set drm master ... Permission denied") and the WebUI reports "Pattern renderer failed to start". It is timing-dependent (HDR-mode init is slower and loses more often), affects old and new binaries alike, and a retry or a service restart usually recovers it.

   Building and deploying the renderer (PGeneratord) on the Pi5 (192.168.1.249, Raspbian Bookworm 12):
   - The Pi5 renderer is built NATIVELY on the Pi5 in `/root/pgplus-build/pattern_generator` against the openFrameworks tree at `/root/pgplus-build/openFrameworks` (g++ 12, links the system bookworm libs). The cross env at `/home/jordan/pgplus-cross/` is NOT the production build path.
   - Canonical sources live in the repo at `tools/image-targets/pi5-bookworm-armhf/src/` (pattern_generator + ofxRPI4Window). Use `tools/scripts/build_and_deploy_pi5_renderer.sh [--deploy]` — it syncs repo sources to the Pi, builds incrementally, verifies ldd/conf-path, and deploys with backups and an idle-state guard.
   - gstreamer for Pi5 builds: the REAL system gstreamer-1.0 dev stack (libgstreamer1.0-dev, libgstreamer-plugins-base1.0-dev — version 1.22) is installed on the Pi5 and auto-detected. Fake/stub `.pc` files are FORBIDDEN.
   - DRM property differences vs the Pi4 (Bookworm vc4):
     * `Colorimetry` -> `Colorspace` (same enum values; `map_kms_colorspace` in command.pm maps conf colorimetry+color_format, e.g. 9+YCC -> 10 BT2020_YCC).
     * `rgb quant range` -> `Broadcast RGB` with DIFFERENT enum numbering: conf `1=Limited, 2=Full` but Broadcast RGB `0=Automatic, 1=Full, 2=Limited 16:235`. Always map via `map_broadcast_rgb` (command.pm) / `pi5_broadcast_rgb_from_rgb_quant_range` (renderer). Locked by `tests/pi5-kms-output-mapping-regression.pl`.
     * The PGenerator `output format` connector property comes from the patched vc4 module (`tools/image-targets/pi5-bookworm-armhf/kernel/`, artifact vc4-6.12.25-rpt-rpi-v8-dv-vsif.ko.xz, loaded since Jun 2026) and is created with DRM_MODE_PROP_ATOMIC: it is INVISIBLE to legacy listings — use `modetest -M vc4 -a -c`. Property writes likewise go through `modetest_connector_write` (atomic `-a -w` with legacy fallback).
   - The Pi5 runs WITHOUT `/usr/lib/drm_override.so` (command.pm skips it on Colorspace-based kernels), so there is no enforcement safety net: after ANY renderer change, re-verify that connector properties and the HDR blob survive pattern changes (atomic commits). See the verification matrix in `tools/image-targets/pi5-bookworm-armhf/PARITY-BASELINE.md`.
   - The Pi5 renderer's `updateHDR_Infoframe()` carries the same conf-read fix as the Pi4 (port of 84ed1cc7); the same preservation rule applies. Locked by `tests/pi5-renderer-hdr-metadata-conf-read-regression.pl`.
   - Calman GCI protocol details (useful for replay tests): GCI connects to port 2100 (not the classic pattern port 85); frames are `\x02<TYPE>:<args>\x03` (STX/ETX); the session becomes GCI after `INIT:2.0`. A full HDR switch is INIT:2.0, HDR_ENABLE:True, CONF_HDR:ST2084,..., then a pattern command (RGB_S:...) to trigger the deferred apply.

   HDR metadata plumbing notes (for future maintainers):
   - The wire HDR_OUTPUT_METADATA blob is built by THREE independent code paths on the Pi4: (1) the renderer's `updateHDR_Infoframe()` C++ function via DRM atomic commit on every page flip; (2) the `/usr/bin/pgsethdr` helper binary called from `etc/init.d/PGenerator` startup and from the WebUI's `apply_hdr_metadata_helper` in `usr/share/PGenerator/command.pm`; (3) `/usr/lib/drm_override.so` (LD_PRELOAD) which currently only touches max_bpc, output_format, Colorimetry, and rgb_quant_range (no HDR).
   - The renderer's path is the source of truth on the wire. `pgsethdr` and `drm_override` are the safety net and the WebUI's manual path. The renderer's `updateHDR_Infoframe()` must read the conf on every call to keep the wire blob correct.
   - `pgsethdr` uses `DRM_IOCTL_SET_MASTER` (0x641e on 32-bit ARM, NOT 0x2001001e) and `DRM_IOCTL_DROP_MASTER` to steal and release the DRM master from the renderer so it can run while the renderer is alive.
   - pgsethdr's HDR conversion: `min_dml = round(min_luma / 0.0001)`, `max_dml = (uint16_t)max_luma`, primaries are coord_to_u16(x) = `(uint16_t)(x / 0.00002 + 0.5)`. These match the renderer's `pg_min_luma_to_u16()` and `EGL_METADATA_SCALING_EXT` constants.
   - The `calman_gci=1` flag in `/etc/PGenerator/PGenerator.conf` is set by daemon.pm when the Calman UPnGCI plugin is active. It is consumed by pgsethdr and the GCI control plane; it has no effect on the renderer's atomic commit.

   Use subagents to do your work, you are their boss, you delegate and review their reports. Try to reusse agents that will require similar context to the new task. For example, if an agent was delegeated to run a calibration test for sdr and you need to run another one, reuse that same agent instead of creating a new one. Do not touch tools let them do the work. 

   Visually confirm your work with screenshots where possible. 

   source code should not include references to calman source code.

   No commits or files should contain reference to being authored by claude or chatgpt or any other model. 
