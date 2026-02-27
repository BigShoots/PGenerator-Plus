# Pgen Companion

A local Windows desktop application for controlling PGenerator — the
Raspberry Pi HDMI pattern generator used for display calibration.

**Replaces DeviceControl** — no cloud account required.  Connects
directly to PGenerator over any local network interface:

| Interface        | Default IP     |
|------------------|----------------|
| Bluetooth PAN    | 10.10.11.1     |
| WiFi AP          | 10.10.10.1     |
| USB gadget       | 10.10.12.1     |
| Ethernet / DHCP  | (discovered)   |

## Features

- **Auto-discovery**: finds PGenerator on known BT/WiFi/USB IPs or via
  UDP broadcast on port 1977.
- **System info**: version, model, hostname, temperature, resolution,
  uptime.
- **Signal Mode / AVI InfoFrame**: output mode (SDR / HDR10 / HLG /
  Dolby Vision LL / Dolby Vision Std), color format, colorimetry,
  quantization range, bit depth — all applied live.
- **HDR / DRM InfoFrame**: EOTF, primaries, max/min luminance,
  MaxCLL, MaxFALL — applied live with PGenerator restart.
- **Dolby Vision**: DV status, color space, metadata type.
- **Pattern control**: draw shape, dimensions, RGB color with preview,
  background color.
- **Network overview**: all interface IPs and MACs.
- **EDID viewer**: parsed EDID from the connected display.

## Requirements

- Python 3.10+ with tkinter (included with the standard Windows
  installer)
- No external GUI libraries needed

## Running from source

```
python pgen_companion.py
```

## Building a standalone .exe (Windows)

```
pip install -r requirements.txt
build.bat
```

The output is `dist/PgenCompanion/PgenCompanion.exe`.

## How it works

Pgen Companion communicates with the PGenerator daemon (`PGeneratord.pl`)
over TCP port 85 using the same protocol that DeviceControl uses:

- Commands are framed with `\x02\r` (STX + CR)
- `CMD:GET_*` / `CMD:SET_*` for system and config queries
- `RGB=...` for pattern commands
- `RESTARTPGENERATOR:` to apply infoframe changes

Settings like EOTF, primaries, colorimetry, etc. are persisted to
`/etc/PGenerator/PGenerator.conf` on the Pi via the
`SET_PGENERATOR_CONF_*` command interface, then the PGeneratord C binary
is restarted to pick up the new DRM/AVI infoframe values.
