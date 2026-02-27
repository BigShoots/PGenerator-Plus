# Project Guidelines — PGenerator

PGenerator is a Raspberry Pi–based HDMI display calibration pattern generator. It renders test patterns (rectangles, circles, images, text) to a connected display and is controlled over TCP by calibration software (LightSpace CMS, Calman, HCFR, DeviceControl).

## Architecture

```
Boot: etc/init.d/rcPGenerator → etc/init.d/PGenerator
  ↓
Splash: /usr/share/PGenerator/splash.fb → /dev/fb0 (RGB565 1920×1080)
  ↓
Hardware init: USB gadget, WiFi AP, Bluetooth, DHCP
  ↓
Setup wizard: usr/sbin/pgenerator-wizard.sh (dialog TUI on HDMI, once per power cycle)
  │  Welcome screen has 15 s timeout -- if nobody presses OK, wizard
  │  skips entirely and PGenerator starts with existing settings.
  ↓
Daemon: usr/sbin/PGeneratord.pl (Perl TCP server, port 85 + 2100)
  ├─ Writes pattern descriptions to /var/lib/PGenerator/operations.txt
  ├─ Spawns usr/sbin/PGeneratord (C/C++ binary renderer reads operations.txt)
  │    If dv_status=1 and PGeneratord.dv exists, spawns the .dv binary instead
  ├─ Threads: main loop, device info collector, UDP discovery (port 1977)
  └─ Delegates privileged ops to usr/bin/PGenerator_cmd.pl via sudo + base64-encoded PG_CMD env var
```

- **Perl modules** live in [usr/share/PGenerator/](usr/share/PGenerator/) — loaded via `do "file.pm"` (flat namespace, no packages/OO). All `.pm` files must end with `return 1;`.
- **IPC** between Perl daemon and C binary is file-based: daemon writes `operations.txt`, binary reads it. Info caching uses `.info` files on tmpfs at `/var/lib/PGenerator/running/`.
- **Config** at [etc/PGenerator/PGenerator.conf](etc/PGenerator/PGenerator.conf) is `key=value` format (no sections). `ip_pattern` and `port_pattern` are read-only.
- **LUT** at [etc/PGenerator/lut.txt](etc/PGenerator/lut.txt) — `R,G,B=R_delta,G_delta,B_delta` per-channel correction; supports `ALL` wildcard.

## Code Style

### Perl (`.pl` / `.pm`)
- No `use strict`/`use warnings` — all variables are implicitly package-global.
- Single-space indentation throughout.
- Subroutine prototypes: `sub name (@) { ... }` on nearly all subs.
- Old-style bareword filehandles with `open()`/`close()`.
- Section headers use `#####` banner-style comments with centered titles.
- Variables: `$snake_case`; constants: `$ALL_CAPS`; subs: `snake_case()`.
- See [daemon.pm](usr/share/PGenerator/daemon.pm) and [pattern.pm](usr/share/PGenerator/pattern.pm) for canonical examples.

### Bash (`.sh`)
- [pgenerator-wizard.sh](usr/sbin/pgenerator-wizard.sh) uses `set -o pipefail` (no `-e` or `-u` — dialog non-zero returns are used for control flow).
- [pgenerator-slim.sh](usr/sbin/pgenerator-slim.sh) uses `set -euo pipefail`.
- Legacy init scripts ([etc/init.d/PGenerator](etc/init.d/PGenerator)) use `#!/bin/sh` without strict mode.

## Project Conventions

- **Pattern DSL**: Patterns are described line-by-line in `operations.txt` — `DRAW=RECTANGLE`, `DIM=w,h`, `RGB=r,g,b`, `BG=r,g,b`, `POSITION=x,y`, `BITS=n`, `FRAME=1`, `END=1`.
- **Template system**: Templates in `/var/lib/PGenerator/tmp/` support `DYNAMIC` placeholders, `VAR=` declarations, `MACRO=` references to other templates.
- **Discovery protocol**: UDP broadcast on port 1977 — clients send `"Who is a PGenerator"`, device replies `"I am a PGenerator <hostname>"`.
- **Privilege separation**: Daemon runs as user `pgenerator`. Privileged commands go through `sudo PGenerator_cmd.pl` with args in base64-encoded `PG_CMD` env var.
- **Threading**: Perl `threads` + `threads::shared` for shared state. Three persistent threads.

## HDR / Dolby Vision Binary Swap

The `PGeneratord` C/C++ binary comes in two variants:

| Binary | Purpose |
|--------|---------|
| `PGeneratord` | Default binary — supports HDR10 (sets `HDR_OUTPUT_METADATA` DRM blob with BT.2020 primaries) |
| `PGeneratord.dv` | Dolby Vision binary — sets `DOVI_OUTPUT_METADATA` DRM blob (detects DV via EDID VSVDB) |

`command.pm` (`pattern_generator_start`) checks `dv_status` in `PGenerator.conf`:
- `dv_status=0` → spawns `PGeneratord` (HDR mode)
- `dv_status=1` → spawns `PGeneratord.dv` if present, otherwise falls back to default

Both binaries read the same `operations.txt` and config. The swap is necessary because the default binary's EDID DV detection (`cta_is_dovi_video_block`) fails on some TVs despite a valid Dolby VSVDB in the EDID.

## Wizard Timeout Behavior

All `dialog` wrapper functions (`show_info`, `ask_yesno`, `get_input`, `get_password`, `show_menu`) include `--timeout $DIALOG_TIMEOUT` (default 15 s). The key behavior:

- **Welcome screen timeout** → wizard skips entirely, preserving existing config
- **Individual step timeout** (when user pressed OK on welcome but walks away) → step returns "No" / empty, skipping that step
- This ensures PGenerator always starts within ~20 s even with nobody at the display.

## Key Modules

| Module | Purpose |
|--------|---------|
| [daemon.pm](usr/share/PGenerator/daemon.pm) | TCP socket server, request routing |
| [pattern.pm](usr/share/PGenerator/pattern.pm) | Pattern file creation, LUT application, scaling |
| [command.pm](usr/share/PGenerator/command.pm) | System commands (HDMI, temp, WiFi, etc.) |
| [client.pm](usr/share/PGenerator/client.pm) | LightSpace/Calman client protocol handling |
| [discovery.pm](usr/share/PGenerator/discovery.pm) | UDP broadcast discovery |
| [conf.pm](usr/share/PGenerator/conf.pm) | Configuration file parsing |
| [variables.pm](usr/share/PGenerator/variables.pm) | All global variables, paths, defaults |
| [pgenerator-wizard.sh](usr/sbin/pgenerator-wizard.sh) | Boot setup wizard (dialog TUI, auto-skips on timeout, replaces DeviceControl) |
| [pgenerator-slim.sh](usr/sbin/pgenerator-slim.sh) | Image size reduction (~6.5 GB → ~1.5 GB) |

## Dependencies

**Perl**: `threads`, `threads::shared`, `IO::Socket::INET`, `IO::Select`, `XML::Simple`, `URI::Escape`, `MIME::Base64`, `Digest::MD5`, `IPC::Open2`, `File::Path`, `Time::HiRes`

**System tools**: `vcgencmd`, `tvservice`, `modetest`, `edid-decode`, `socat`, `convert`/`identify` (ImageMagick), `wpa_cli`, `dialog`

**Runtime**: Raspberry Pi only (checks `/proc/device-tree/model`); requires BiasiLinux distro.

## Build and Test

- No build system for Perl code — scripts deploy as-is via FHS layout.
- The `PGeneratord` C/C++ binary is pre-compiled (not buildable from this workspace). The `.dv` variant is a separate pre-compiled binary for Dolby Vision.
- Boot splash (`build/splash.png` → `build/splash.fb`) is a 1920×1080 RGB565 raw framebuffer image displayed before the wizard. Update version text in `splash.png` and regenerate `splash.fb` with the PIL script.
- No automated test suite exists — test by deploying to a Raspberry Pi.
- [pgenerator-slim.sh](usr/sbin/pgenerator-slim.sh) reduces a stock `RPI.img` (~6.5 GB → ~1.5 GB) for distribution.

## Security

- Daemon binds TCP ports 85 (pattern) and 2100 (Calman) — no authentication on either.
- `EVALPATTERN=` in templates (Perl `eval`) is currently disabled for security.
- `PGenerator_cmd.pl` runs as root via sudoers — validate all inputs before extending it.
- The `PG_CMD` env var carrying privileged command args is base64-encoded but not encrypted.
