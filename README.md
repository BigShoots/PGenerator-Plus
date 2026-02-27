# PGenerator+

A Raspberry Pi–based HDMI test pattern generator for display calibration. PGenerator+ outputs precision color patches and test patterns over HDMI — including HDR10, HLG, and Dolby Vision — controlled remotely by calibration software over TCP/IP.

Built on the open-source [PGenerator](https://github.com/Biasiolo/PGenerator) by Riccardo Biasiotto (GPLv3).

## Installation & Updates

### How to Flash the Image

1. Download the latest full image release (`PGenerator_Plus.img.zip`) from the GitHub Releases page and extract the `.img` file.
2. Use a tool like [Balena Etcher](https://etcher.balena.io/) or [Rufus](https://rufus.ie/) to flash the `.img` file to a microSD card or USB flash drive (minimum 8GB).
3. Insert the microSD card or USB flash drive into your Raspberry Pi and power it on.
4. Connect to the Pi using one of the following methods:
   - **Bluetooth PAN:** First connect to the Bluetooth device on your computer, then join its PAN in Windows settings.
   - **Wired PAN:** Connect an Ethernet cable directly between your device and the Pi.
   - **Wired LAN:** Connect the Pi to your local network router or switch via Ethernet.
   - **Wireless PAN:** Connect your device to the Pi's default WiFi Access Point (SSID: `PGenerator`, Password: `PGenerator`).
   - **Wireless LAN:** Connect the Pi to your existing WiFi network (can be configured via the Web UI after using one of the other methods).
5. Access the web UI at `http://pgenerator.local` or the device's IP address.

### How to Update (OTA)

PGenerator+ includes a built-in Over-The-Air (OTA) update system that pulls the latest releases directly from GitHub.

**Via Web UI (Recommended):**
1. Open the PGenerator+ web dashboard.
2. Scroll down to the **Software Update** card.
3. Click **Check for Updates**. If a new version is available, the changelog will appear.
4. Click **Install Update**. The device will download the update, apply it, and restart automatically.

**Via Command Line:**
You can also trigger updates via SSH (`root` / `PGenerator!!$`):
```bash
# Check for updates
/usr/sbin/pgenerator-update check

# Apply the latest update
/usr/sbin/pgenerator-update apply
```

---

## Features

### Signal Modes

| Mode | Description |
|------|-------------|
| **SDR** | Standard Dynamic Range (Rec.709), 8-bit |
| **HDR10** | Static HDR with PQ (ST.2084) EOTF, 10-bit, full DRM InfoFrame metadata |
| **HLG** | Hybrid Log-Gamma for broadcast HDR, 10-bit |
| **Dolby Vision (Low Latency)** | LLDV with RPU metadata, 12-bit — recommended for DV calibration |
| **Dolby Vision (Standard)** | TV-led / display-managed DV processing, 12-bit |

The Raspberry Pi 4's KMS driver is used to set HDMI InfoFrames directly:

- **AVI InfoFrame** — color format (RGB / YCbCr 4:4:4 / 4:2:2), colorimetry (BT.709 / BT.2020), quantization range (Full / Limited), bit depth
- **DRM InfoFrame** — EOTF, mastering display primaries (Rec.2020 / P3), luminance (max/min), MaxCLL, MaxFALL
- **Dolby Vision** — DOVI output metadata blob via a dedicated binary (`PGeneratord.dv`) that detects DV capability from the display's EDID VSVDB

### Calibration Software Compatibility

PGenerator+ acts as a TCP-controlled pattern generator, compatible with many major calibration software packages.

**1. Calman (Portrait Displays)**
- **Protocol:** SpectraCal Unified Pattern Generator Control Interface (Port `2100`)
- **How to Connect:** In your workflow, click **Find Source** → Manufacturer: `SpectraCal` → Model: `SpectraCal - Unified Pattern Generator Control Interface`. Enter the PGenerator's IP address and click Connect.

**2. ColourSpace / LightSpace CMS**
- **Protocol:** XML Network Calibration Protocol (Port `85`)
- **How to Connect:** Open **Hardware Options** → Hardware: `Network` (or `PGenerator` if listed). Enter the PGenerator's IP address in the Network Address field and click Connect.

**3. HCFR**
- **Protocol:** Network Pattern Generator Commands (Port `85`)
- **How to Connect:** Go to **Measures** > **Generator** > **Configure** → Select `Network` from the dropdown and enter the PGenerator's IP address.

**4. DeviceControl**
- **Protocol:** UDP discovery + TCP pattern control

*Device Discovery:* Calibration software can often discover the device automatically via UDP broadcast on port `1977` (`"Who is a PGenerator"` → `"I am a PGenerator <hostname>"`), allowing you to select your device from a list instead of entering the IP address manually.

### Web UI Dashboard

A single-page settings dashboard served on **port 80**, accessible from any browser at the device's IP or `pgenerator.local`.

**Settings & Controls:**
- Signal mode selection (SDR / HDR10 / HLG / Dolby Vision)
- Output resolution picker (auto-detected from display EDID via `modetest`)
- Color format, colorimetry, bit depth, quantization range
- Full HDR10 DRM InfoFrame metadata (EOTF, primaries, luminance, MaxCLL/MaxFALL)
- Dolby Vision settings (LL/Standard, color space, metadata type, interface)
- Apply & Restart bar — contextual, appears only when settings have changed

**Test Patterns:**
- Full-field colors: white, black, red, green, blue, cyan, magenta, yellow, 50% gray
- Grayscale ramps & steps (2–10% increments)
- Window pattern (18% screen area, centered)
- Overscan border
- Color bars
- Saturation sweeps (25% / 50% / 75% for each primary and secondary)
- Generic RGB patch with configurable patch size (10% / 18% / 25% / 50% / 100%)

**Device Info:**
- Hostname, resolution, uptime, CPU temperature
- All network interfaces with IPs (Ethernet, WiFi, WiFi AP, Bluetooth PAN)
- WiFi connection details (SSID, band, frequency, signal strength)
- Connected calibration software detection
- Live latency indicator with color-coded response time

**Network Management:**
- WiFi client — scan & connect to networks
- WiFi Access Point — configure SSID & password (reachable at 10.10.10.1)

**HDMI-CEC:**
- TV power status display
- Wake / On / Input / Standby controls

**HDMI Infoframes:**
- Live readout of AVI and DRM InfoFrame hex data from the HDMI output
- Decoded human-readable fields (color format, quantization, colorimetry, VIC, EOTF, luminance)

**UI Features:**
- Dark theme with responsive layout (desktop + mobile)
- Drag-and-drop widget reordering with persistent layout (localStorage)
- Toast notifications for all actions

### mDNS / Bonjour

Built-in mDNS responder on port 5353 — the device is reachable at `pgenerator.local` without any DNS configuration. Responds to A-record queries with subnet-aware IP selection.

### OTA Updates

Self-updating via GitHub Releases from this repository:

- `pgenerator-update check` — queries the GitHub API for the latest release, returns JSON with version comparison and changelog
- `pgenerator-update apply` — downloads the release `.tar.gz` asset, stops the service, extracts over the filesystem, and restarts

Updates are triggered from the web UI or command line. Release assets are tar.gz archives with FHS-layout paths that overlay directly onto the root filesystem.

### LUT Correction

Per-channel color correction via `/etc/PGenerator/lut.txt`:

```
R,G,B=R_delta,G_delta,B_delta
```

Supports exact RGB matches and an `ALL` wildcard for global offset. Applied by the Perl daemon before writing pattern files.

---

## Architecture

```
Boot: /etc/init.d/rcPGenerator → /etc/init.d/PGenerator
  ↓
Splash: RGB565 framebuffer image → /dev/fb0 (1920×1080)
  ↓
Hardware init: USB gadget, WiFi AP, Bluetooth, DHCP
  ↓
Daemon: PGeneratord.pl (Perl TCP server)
  ├─ TCP port 85   — LightSpace / pattern protocol
  ├─ TCP port 2100 — Calman protocol
  ├─ TCP port 80   — Web UI (HTTP + JSON API)
  ├─ UDP port 5353 — mDNS responder
  ├─ UDP port 1977 — Device discovery
  ├─ Spawns PGeneratord (C/C++ renderer, reads operations.txt)
  │    └─ PGeneratord.dv variant for Dolby Vision
  └─ Threads: main loop, device info, UDP discovery (x2), HTTP, mDNS
```

### IPC

The Perl daemon writes pattern descriptions to `/var/lib/PGenerator/operations.txt` in a simple DSL:

```
PATTERN_NAME=TestPattern
BITS=8
DRAW=RECTANGLE
DIM=1920,1080
RGB=255,128,0
BG=0,0,0
POSITION=0,0
END=1
FRAME=1
```

The C/C++ binary (`PGeneratord`) reads this file and renders directly to the display via the Pi's GPU.

### Privilege Separation

The daemon runs as the `pgenerator` user. Privileged operations (config writes, service control, updates) are delegated to `PGenerator_cmd.pl` via `sudo`, with arguments passed as base64-encoded environment variables.

---

## Project Structure

```
etc/
  init.d/PGenerator              # Init script (service start/stop)
  PGenerator/PGenerator.conf     # Configuration (key=value)
  PGenerator/lut.txt             # LUT color correction table
usr/
  sbin/
    PGeneratord.pl               # Main daemon (Perl, forks + threads)
    PGeneratord                  # Pattern renderer (C/C++ binary)
    PGeneratord.dv               # Dolby Vision renderer variant
    pgenerator-update            # OTA update script (GitHub Releases)
  bin/
    PGenerator_cmd.pl            # Privileged command handler (runs as root)
  share/PGenerator/
    daemon.pm                    # TCP server, request routing, thread management
    pattern.pm                   # Pattern file creation, LUT, scaling
    command.pm                   # System commands (HDMI, temp, WiFi, process mgmt)
    client.pm                    # LightSpace / Calman protocol handling
    discovery.pm                 # UDP broadcast discovery responder
    webui.pm                     # Web UI: HTTP server, JSON API, HTML/CSS/JS SPA
    conf.pm                      # Configuration file parser
    variables.pm                 # Global variables, paths, defaults
    version.pm                   # Version info ($version, $version_plus)
    info.pm                      # Device info collection
    log.pm                       # Logging
    file.pm                      # File utilities
```

### Key Modules

| Module | Purpose |
|--------|---------|
| [daemon.pm](usr/share/PGenerator/daemon.pm) | TCP socket server, fork + thread management, request routing |
| [pattern.pm](usr/share/PGenerator/pattern.pm) | Pattern DSL file creation, LUT application, resolution scaling |
| [command.pm](usr/share/PGenerator/command.pm) | HDMI mode detection (KMS/modetest), 4K auto-select, process management |
| [client.pm](usr/share/PGenerator/client.pm) | LightSpace XML protocol, Calman protocol handling |
| [discovery.pm](usr/share/PGenerator/discovery.pm) | UDP broadcast discovery for DeviceControl and LightSpace |
| [webui.pm](usr/share/PGenerator/webui.pm) | Full web dashboard: HTTP server, REST API, single-page HTML/CSS/JS app |
| [conf.pm](usr/share/PGenerator/conf.pm) | `key=value` configuration file reader/writer |
| [variables.pm](usr/share/PGenerator/variables.pm) | All global paths, defaults, shared state declarations |
| [version.pm](usr/share/PGenerator/version.pm) | Version string (`2.0.1`) and product name (`PGenerator+`) |

---

## Configuration

`/etc/PGenerator/PGenerator.conf` — flat `key=value` format, no sections:

| Key | Values | Description |
|-----|--------|-------------|
| `port_pattern` | `85` | TCP port for pattern protocol (read-only) |
| `color_format` | `0`=RGB, `1`=YCbCr444, `2`=YCbCr422 | HDMI output color format |
| `colorimetry` | `0`=BT.709, `1`=BT.2020 | AVI InfoFrame colorimetry |
| `rgb_quant_range` | `0`=Auto, `1`=Limited, `2`=Full | RGB quantization range |
| `max_bpc` | `8`, `10`, `12` | Bits per channel |
| `eotf` | `0`=SDR, `2`=PQ, `3`=HLG | Electro-optical transfer function |
| `primaries` | `1`=Rec.2020, `2`=P3/D65, `3`=P3/DCI | Mastering display primaries |
| `max_luma` / `min_luma` | nits (min is ×0.0001) | Mastering display luminance |
| `max_cll` / `max_fall` | nits | Content light level metadata |
| `dv_status` | `0`=off, `1`=on | Enable Dolby Vision binary |
| `is_hdr` / `is_sdr` | `0` / `1` | Signal mode flags |
| `is_ll_dovi` / `is_std_dovi` | `0` / `1` | Dolby Vision mode flags |
| `dv_interface` | `0`=Standard, `1`=Low Latency | DV interface type |
| `dv_metadata` | `0`=Type 1, `1`=Type 4 | DV metadata type |
| `dv_color_space` | `0`=YCbCr422, `1`=RGB444, `2`=YCbCr444 | DV color space |

---

## Hardware Requirements

- **Raspberry Pi 4** (or Pi 400) — required for HDR/DV and KMS driver support
- **BiasiLinux** distribution (custom Raspberry Pi OS)
- HDMI connection to target display
- Network connection (Ethernet, WiFi, or WiFi AP mode)

Older Pi models work for SDR-only output.

---

## API Reference

All endpoints are served on port 80. Responses are JSON.

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/ping` | Health check, returns `{"ok":1}` |
| GET | `/api/info` | Device info (hostname, temp, IPs, WiFi, resolution, calibration status) |
| GET | `/api/config` | Current configuration as JSON |
| POST | `/api/config` | Apply configuration changes (JSON body) |
| GET | `/api/modes` | Available HDMI output modes from display EDID |
| POST | `/api/restart` | Restart pattern generator |
| POST | `/api/reboot` | Reboot device |
| GET | `/api/wifi/scan` | Scan for WiFi networks |
| GET | `/api/wifi/status` | WiFi connection status |
| POST | `/api/wifi/connect` | Connect to WiFi (JSON: ssid, psk) |
| GET | `/api/wifi/ap` | Get AP settings |
| POST | `/api/wifi/ap` | Set AP SSID & password |
| GET | `/api/infoframes` | Read AVI and DRM InfoFrame hex data from HDMI output |
| GET | `/api/cec/status` | HDMI-CEC TV power status |
| GET | `/api/cec/{cmd}` | Send CEC command (wake, on, off, as) |
| POST | `/api/pattern` | Display a test pattern (JSON: name, r, g, b, size) |

---

## Based On

PGenerator+ is built on [PGenerator](https://github.com/Biasiolo/PGenerator) by Riccardo Biasiotto, licensed under the GNU General Public License v3.0. The original project provides the core pattern generation engine, TCP protocol handling, and C/C++ renderer binary.

PGenerator+ adds the web-based dashboard, HDR/DV InfoFrame configuration UI, mDNS discovery, HDMI-CEC control, OTA updates via GitHub Releases, and various stability improvements.

---

## License

GNU General Public License v3.0 — see [COPYING](COPYING) for details.
