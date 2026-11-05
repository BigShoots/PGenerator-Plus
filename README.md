<p align="center">
  <img src="Pgen+_Logo_black_bg_slim.png" alt="PGenerator+" width="640"/>
</p>

<h3 align="center">The Raspberry Pi 4 pattern generator that proves its codes on the HDMI cable: bit-exact, Dolby Vision aware, driven from your TV remote</h3>

<p align="center">
  <a href="https://github.com/BlackJoker90/PGenerator-Plus/releases/latest"><img src="https://img.shields.io/github/v/release/BlackJoker90/PGenerator-Plus?style=for-the-badge&color=5b7fff&label=release" alt="Latest release"/></a>
  <img src="https://img.shields.io/badge/Raspberry%20Pi-4-c51a4a?style=for-the-badge&logo=raspberrypi&logoColor=white" alt="Raspberry Pi 4"/>
  <img src="https://img.shields.io/badge/SDR%20%C2%B7%20HDR10%20%C2%B7%20HLG%20%C2%B7%20Dolby%20Vision-1f2433?style=for-the-badge" alt="SDR, HDR10, HLG, Dolby Vision"/>
  <a href="COPYING"><img src="https://img.shields.io/badge/license-GPLv3-3b4252?style=for-the-badge" alt="GPLv3"/></a>
</p>

<p align="center">
  <a href="#only-in-this-fork">Only here</a> ·
  <a href="#why-this-fork">Why this fork</a> ·
  <a href="#at-a-glance-fork-vs-original">Fork vs. original</a> ·
  <a href="#get-started">Get started</a> ·
  <a href="#calibration-software-compatibility">Calman &amp; co.</a> ·
  <a href="#reference">Reference</a> ·
  <a href="https://buymeacoffee.com/fabioelia9r">☕ Support</a>
</p>

<p align="center">
  <img src="screenshots/webui-patterns.png" alt="PGenerator+ Web UI in the Volt theme: Patterns workspace with Calman G1 plates, test images and playlists" width="900"/>
</p>

---

<a id="only-in-this-fork"></a>

## 🏆 Only in this fork

What no other PGenerator build does today. The comparison basis is the latest upstream PGenerator+ (2.12.1); none of these exist there.

<table>
<tr>
<td width="50%" valign="top">

### 🔬 Codes proven on the cable
The Pi reads back its own scanout. The built-in **Signal Self-Test** draws known codes in twelve signal modes and checks the pixels, the link depth, the AVI infoframe (format, range, colorimetry, VIC), the HDR metadata field by field and the Dolby Vision infoframe. 10-bit codes stay 10-bit, and **RGB Limited goes out without the kernel's compression** (patched vc4). A full 0–1023 sweep comes back exact.

</td>
<td width="50%" valign="top">

### 🕶️ A silent source: no SPD InfoFrame
A stock Pi labels itself in the SPD InfoFrame (*"Broadcom Videocore"*), and displays can change the picture for the source type it names. [Light Illusion](https://www.lightillusion.com/hdmi_infoframes.html) saw it on an ASUS ProArt PA32DC: Low Latency Dolby Vision from a Pi was **limited to Rec.709**, and with the Pi's SPD removed it showed the **full gamut**, matching a Murideo SIX-G. The fork's vc4 driver **never sends the SPD InfoFrame**, and the WebUI shows the packet register as proof.

</td>
</tr>
<tr>
<td valign="top">

### 🌈 Dolby Vision that reads your display
The DV card decodes the display's **EDID Dolby block**: peak and black luminance, primaries, Standard and Low Latency support. Choosing DV fills in the display's own peak and black, flags mismatches and marks patches above the peak. **LLDV runs at 12-bit** and really switches the TV into DV.

</td>
<td valign="top">

### 📺 Patterns from the TV remote
Press **OK or Menu on the TV remote** and every pattern appears as a menu on the TV. **Playlists** step with the arrow keys over HDMI-CEC. No phone or laptop needed at the screen.

</td>
</tr>
<tr>
<td valign="top">

### 🎛️ Calman connects as a G1
Calman can drive PGenerator+ as a **Portrait Displays G1**: patches, signal modes and all **19 G1 specialty patterns**, rendered on the Pi. The UPGCI connection works too, now with replies Calman can parse.

</td>
<td valign="top">

### ⚡ Fast, and it does not fall over
A signal mode change takes **~3.5–4.5 s instead of ~10 s**. Rapid setting changes are serialized, so they can no longer start two renderers and crash the HDMI driver. Without a display the renderer waits instead of failing.

</td>
</tr>
</table>

<a id="why-this-fork"></a>

## ✨ Why this fork

This is **BlackJoker90's fork** of [BigShoots/PGenerator-Plus](https://github.com/BigShoots/PGenerator-Plus). It branched from upstream 2.12.1 in September 2026 and has had **145+ commits and 30+ releases** since then (2.12.2 → 2.13.x). Upstream has nothing newer that the fork lacks.

Everything the original does is still here: patterns over TCP for Calman, ColourSpace, HCFR and Resolve; on-Pi meter workflows; LG AutoCal; profile building. The fork's focus is the **signal on the HDMI cable** and the **day-to-day experience**:

<table>
<tr>
<td width="50%" valign="top">

### 🎯 Bit-exact output
10-bit pattern codes reach the GPU **without 8-bit quantisation**. **RGB Limited is bit-exact**: a patched vc4 module skips the kernel's compression CSC. HDR10/HLG at 12-bit goes out as bit-exact 10-bit instead of crashing the renderer. **8-bit patterns on a 10-bit link** go out as exactly code × 4 (126 → 504), in SDR, HDR10 and LLDV. The G1 Brightness and Contrast plates switch to **10-bit steps** (0–95, 928–1023) on a 10-bit link. Scanout readback on the Pi checks the codes; nobody has to eyeball them. At 4K: 60 Hz in 8-bit RGB or YCbCr 4:2:2, 24 / 30 Hz up to 10-bit RGB ([which signals](#bit-exact-4k)).

</td>
<td width="50%" valign="top">

### ⚡ Faster signal switching
Changing signal mode takes **~3.5–4.5 s instead of ~10 s**. Format changes go into one atomic modeset, and signal settings are applied in place where possible. The link stays RGB until the renderer is up.

</td>
</tr>
<tr>
<td valign="top">

### 🎛️ Calman that just works
The UPGCI handshake now has proper ACKs and the settings format Calman actually parses. `GET_SETTINGS` works. Codes are rounded to the output depth, with a notice when a code is not exact. YCbCr 4:2:0 requests are refused cleanly with a NAK instead of breaking the link. Calman can also **connect to PGenerator+ as a G1** and control it completely; the output follows what Calman shows (a G1 connection starts at RGB 8-bit Limited, like Calman's G1 source). All 19 **G1 specialty patterns** are rendered on the Pi; you start them from Calman or from the WebUI.

</td>
<td valign="top">

### 🌈 Dolby Vision, fixed
Low Latency DV renders at **12-bit** and really switches the TV into DV, with pattern codes sent at 10-bit. The display's EDID Dolby block sets the DV metadata defaults. Standard DV always uses the 8-bit tunnel the TV expects, also after a 10-bit Calman session, and its AVI infoframe names the timing's own VIC instead of a fixed 1080p60 (CTA-861). Leaving DV signals "DV off" properly and gives back the format, range and depth you had before DV, and the SDR colorimetry. Calman DV consistently runs as standard DV.

</td>
</tr>
<tr>
<td valign="top">

### 🔌 Hotplug-safe
Without a display, the renderer waits instead of failing. The UI says so in a banner, and your saved mode is kept. After a hotplug the screen shows black instead of grey or a text console. Before a reboot or power-off, the HDMI link is handed back as plain RGB.

</td>
<td valign="top">

### 🖥️ A reworked Web UI
**13 colour themes** (dark, light, OLED, Natrium, the lime Volt …) and workspace navigation. Only sending patterns (for example from Calman or HCFR)? Hide the Measure workspaces with one switch in Settings. The UI shows the measured HDMI link depth and clock. It is served compressed with an ETag, pauses polling in hidden tabs and uses its own dialogs instead of browser pop-ups. Toasts appear only for warnings and errors.

</td>
</tr>
<tr>
<td valign="top">

### 📦 Safer OTA updates
Updates come from **this fork's releases**. The dialog shows the release notes and download progress. You can **reinstall or roll back** to an earlier release. Packages are about **20 % smaller** (stripped binaries, no duplicate files, unused Python modules dropped). Update checks are cached (gentle on the GitHub API), and cross-site requests to the WebUI are refused.

</td>
<td valign="top">

### 🧹 Small things that add up
mDNS answers AAAA queries with an NSEC record, so clients do not wait for an IPv6 address that never comes. `/api/lg/status` answers in milliseconds instead of ~4 s. Start and restart show an **animated progress screen on the TV** that follows the real boot steps in the colours of the WebUI theme you picked, and the WebUI follows a restart in its own dialog and reloads once the Pi is back. A renderer restart in YCbCr no longer flashes the screen green. **Faster start and reboot**: the WebUI answers about 25 s after the kernel starts, 10 s sooner than in earlier releases, and a reboot from the WebUI is back about 11 s sooner (USB network detection runs in the background, the WiFi driver is reloaded only when it failed, the WebUI starts before the renderer); every step is logged with its uptime in `/var/log/PGenerator/boot-times.log`. **Download Logs** replaces the old log upload.

</td>
</tr>
<tr>
<td valign="top">

### 🧪 Signal self-test
One button in **Output** runs twelve signal modes (SDR RGB Limited/Full and YCbCr 4:2:2/4:4:4, HDR10 RGB Limited and YCbCr 4:2:2/4:4:4, HLG RGB Limited and YCbCr 4:4:4, Dolby Vision Standard and Low Latency). In each mode it draws known codes (greys, colours checked against the BT.709/BT.2020 Y'CbCr formulas, 8-bit and 12-bit source codes), **reads back what the Pi scans out** and checks the link depth and the AVI infoframe: format, range, colorimetry and the VIC of the running mode. It also reads the infoframes from the HDMI packet RAM: HDR metadata only in HDR, field by field against your settings (ST 2084 primaries and luminances; HLG without mastering data), and in Dolby Vision the infoframe the display switches on (the Dolby VSIF for Low Latency, the HDMI 1.4b VSIF for Standard). Your signal settings come back afterwards; a quick check covers three modes in about 40 s.

</td>
<td valign="top">

### 📺 Pattern menu and playlists on the TV remote
Press **OK or Menu on the TV remote** and a menu of every pattern appears on the TV: G1 plates, test images and playlists as thumbnails. Arrows move, OK shows the pattern, left/right step on, Back returns to the menu. No phone needed. It dims itself in HDR and Dolby Vision and closes after ten idle minutes (OLED). Playlists step the same way: right or down for next, left or up for back, a number key to jump, Exit to end. Three built-in playlists (Picture setup, Greyscale windows, Panel check), plus your own from G1 plates, test images, uploads and APL windows. A deck on the page shows where you are.

</td>
</tr>
<tr>
<td valign="top">

### 🚫 Refused settings, with the reason
A setting the Pi or the display cannot carry is **refused instead of quietly changed**: 10-bit RGB at 4K 60 Hz needs 742.5 MHz on the link and the Pi 4 sends at most 600 MHz; a YCbCr format, a bit depth or an HDR mode missing from the display's EDID; TV-led Dolby Vision at 4K 60 Hz or low-latency DV in RGB where the display's Dolby block does not list it. The output stays as it was, the WebUI says why and what works instead, and **patches are refused until working settings arrive** (Calman gets a NAK). In Output, options that cannot go out stay visible but locked, with the reason next to them.

While **Calman, ColourSpace or LightSpace is connected, it sets the signal**: the Output settings, presets and Apply are locked with the reason, and `/api/config` refuses signal changes, so the cable keeps what the software shows. Settings other than the signal still save; HCFR and Resolve only send patches and leave the signal to the WebUI. Sessions are tracked per socket and port: Calman from its `INIT` on 2100 (UPGCI) or 2101 (G1), not from its discovery probe; port 85 clients from their first pattern. A session ends with Calman's `SHUTDOWN` or when its socket closes, and a client that vanishes without closing (VM paused, network gone) is dropped after about a minute by TCP keepalive instead of staying "connected". The header tooltip lists each session with port, protocol and when data last came.

</td>
<td valign="top">

### 🔗 What is on the cable, and when the link dropped
Next to the settings, **On the cable** shows what is actually sent (format, range, depth, HDR mode), read from the infoframes and the encoder, and names every quiet adjustment ("12-bit setting is sent as 10-bit."). Hover over the signal or the calibration program in the header for the same. If the HDMI link drops while Calman is connected or a measurement runs (display reset, input change, power off), the time is recorded and a notice says the readings across it can't be combined.

</td>
</tr>
</table>

<a id="at-a-glance-fork-vs-original"></a>

## ⚖️ At a glance: fork vs. original

| | Original ([BigShoots](https://github.com/BigShoots/PGenerator-Plus) 2.12.1) | **This fork (2.13.x)** |
|---|---|---|
| 10-bit pattern codes | quantised through 8 bit on the way to the GPU | **sent at full 10-bit precision** |
| RGB Limited output | kernel compression CSC after the framebuffer | **bit-exact** (patched vc4, verified by scanout readback) |
| HDR10 / HLG at 12-bit | renderer crashed | bit-exact 10-bit |
| HLG meter targets | power curve: 50 % HLG targeted 435 cd/m² on a 1000 cd/m² display | **ITU-R BT.2100 HLG** (50 % → 51 cd/m², 75 % → 203 cd/m²); colour and saturation targets are the BT.2100 display of the codes sent |
| Signal-mode switch | ~10 s | **~3.5–4.5 s** |
| Low Latency Dolby Vision | TV did not switch into DV | 12-bit, TV switches into DV |
| Standard Dolby Vision AVI infoframe | VIC always 16 (1080p60), also at 24, 30 Hz or 4K | **the VIC of the timing on the cable** (e.g. 1080p24 → 32, 2160p24 → 93; patched vc4) |
| Calman UPGCI | settings replies Calman could not parse | ACK + parseable settings, `GET_SETTINGS` |
| Calman YCbCr 4:2:0 request | no defined answer | clean NAK, current format kept, WebUI notice |
| Settings the Pi or display can't carry | applied anyway: vc4 quietly lowers the depth, or the display shows nothing | **refused with the reason** (link bandwidth, EDID), output kept, patches refused until working settings arrive |
| WebUI signal change during a Calman / ColourSpace session | applied, so the cable no longer matched what the software showed | **locked with the reason**: the software sets the signal while it is connected |
| What goes out on the cable | – | **shown next to the settings**, quiet adjustments named (e.g. 12-bit sent as 10-bit) |
| Range mismatch between Pi and display | – | **Range Check** test image: shows whether the display decodes Limited or Full, next to the range on the cable, plus an EDID check that predicts from the display's EDID (QS/QY) and the Pi's AVI infoframe (Q/YQ, VIC) whether the display on Auto matches |
| HDMI link drop during a measurement | – | **recorded with the time**, notice and banner: readings across it can't be combined |
| Calman connection as G1 | – | **full control** from Calman (patches, signal modes, G1 patterns) |
| Calman G1 specialty patterns | – | all 19 rendered on the Pi, started from Calman or the WebUI |
| No display connected | renderer started anyway | waits for a display, banner in the UI, saved mode kept |
| Rapid setting changes | could start two renderers at once (vc4 crash, reboot needed) | **serialized**: one renderer, no crash |
| Display's Dolby Vision block | only "DV supported" | peak, black, interfaces and primaries shown; mismatch warnings; patches above the peak flagged |
| SPD InfoFrame | always sent ("Broadcom Videocore", media player); can limit a display's LLDV gamut to Rec.709 (ASUS PA32DC, Light Illusion) | **never sent**: removed in the vc4 driver (Pi 4) |
| WebUI themes | dark / light / system | **13 themes** incl. Natrium dark & light and Volt, Scope, Ultraviolet |
| Measurement workspaces | – | **can be hidden** in Settings for pattern-only setups (Calman, HCFR) |
| HDMI link readout | – | measured link depth and clock |
| CPU scaling governor | fixed in `/etc/default/rcPGenerator` | **Scaling Type in the WebUI**, applies without a reboot |
| OTA | latest release only | release notes, progress, **reinstall / rollback**, ~20 % smaller packages |
| Self-test of the HDMI output | – | **built in**: scanout readback, link depth, AVI (colorimetry, VIC), HDR metadata fields and Dolby Vision infoframes per mode, HLG included |
| Pattern playlists | – | **stepped with the TV remote** (HDMI-CEC), own playlists |
| On-screen pattern menu | – | **every pattern on the TV**, picked with the remote |
| Start and restart | static splash, WebUI just goes offline | **animated progress on the TV** (real boot steps, in the WebUI theme), restart dialog in the WebUI that reconnects by itself; WebUI up about 25 s after the kernel starts |
| Popups | success and error toasts | warnings and errors only |
| Test EDID | – | **file on the boot partition** replaces the display's EDID (kernel `edid_override`), banner while in use |
| ColourSpace's `PiTPG` hardware entry | – | **PiTPG protocol 2 on port 85**: patches with frame timing, signal settings, the 11 PiTPG test patterns, EDID / HDMI / InfoFrame texts |

> The left column describes upstream behaviour as stated in the fork commits that changed it. Run `git log origin/main..main` in a clone with both remotes for the full list.

## 📸 Screenshots

<table>
<tr>
<td width="68%" valign="top"><img src="screenshots/webui-playlists.png" alt="Playlist deck with the current pattern, a filmstrip of all steps and the playlist library"/></td>
<td width="32%" rowspan="3" valign="top"><img src="screenshots/webui-phone.png" alt="Playlists on a phone"/></td>
</tr>
<tr>
<td align="center"><sub>Playlists: the deck follows the TV remote; Start, duplicate or edit from the library</sub></td>
</tr>
<tr>
<td valign="top"><img src="screenshots/webui-settings.png" alt="Settings workspace with the theme picker (Volt selected), the Measure switch and settings backup"/><br/><p align="center"><sub>Settings: 13 themes, layout and backup in one place</sub></p></td>
</tr>
<tr>
<td colspan="2" valign="top"><img src="screenshots/webui-system.png" alt="System workspace: Device Info with CPU, memory and temperature meters and tiles for board, hostname, resolution, uptime, RAM and network, plus the GPU Memory and Scaling Type selects, and Software Update below"/><br/><p align="center"><sub>System: CPU, memory and temperature at a glance, the device facts, GPU memory and CPU Scaling Type set right in their tiles, and the OTA update</sub></p></td>
</tr>
<tr>
<td colspan="2" valign="top"><img src="screenshots/webui-selftest.png" alt="Signal self-test in Output: all 12 modes bit-exact (SDR, HDR10, HLG, Dolby Vision), with link details and the drawn swatches per mode"/><br/><p align="center"><sub>Signal self-test, right below Display Settings: every mode read back from the scanout on a real Pi 4, bit-exact in 12 of 12</sub></p></td>
</tr>
<tr>
<td colspan="2" valign="top"><img src="screenshots/tv-restart.png" alt="Restart screen on the TV: PGenerator+ logo, Restarting PGenerator+, a progress bar and the steps Shut down (done), Restart (current) and Start"/><br/><p align="center"><sub>On the TV during a restart, in the Volt theme (rendered by the Pi's start screen program); at start-up the same screen follows System, Network, Services and PGenerator+</sub></p></td>
</tr>
</table>
<p align="center"><sub>Top right: the same playlists on a phone, with a bottom tab bar</sub></p>

---

<a id="get-started"></a>

## 🚀 Get started

### 💾 New install: flash the image

1. Download the newest release that has image parts, from [Releases](https://github.com/BlackJoker90/PGenerator-Plus/releases) (`PGenerator_Plus_vX.Y.Z_pi4.img.xz.001` and `.002`).
   Image releases are rare by design. Most releases are OTA-only, so grab the latest image and update from there.
2. Join the parts and flash:
   - **Windows:** open `.001` with [7-Zip](https://www.7-zip.org/) to get the `.img`, then flash it with [Balena Etcher](https://etcher.balena.io/) or [Rufus](https://rufus.ie/).
   - **macOS / Linux:** `cat PGenerator_Plus_*_pi4.img.xz.0* > pgen.img.xz`, then flash `pgen.img.xz` with [Raspberry Pi Imager](https://www.raspberrypi.com/software/). Imager reads `.xz` directly.
   - Use a microSD card or USB stick of at least 8 GB.
3. Boot the Pi and connect to it, using one of the methods below.
4. Open **`http://pgenerator.local`** (or the Pi's IP address).
5. Go to **System → Software Update → Check for Updates** to move to the newest OTA release.

<details>
<summary><b>Connection methods (Bluetooth PAN, Wi-Fi AP, Ethernet)</b></summary>

- **Bluetooth PAN:** pair with the Pi, then join its PAN in Windows settings.
  <p align="left">
    <img src="screenshots/add_bluetooth_device.png" alt="Add Bluetooth device" width="200"/>
    <img src="screenshots/add_device.png" alt="Confirm device addition" width="200"/>
    <img src="screenshots/select_bluetooth.png" alt="Select Bluetooth" width="200"/>
    <img src="screenshots/select_pgenerator.png" alt="Select PGenerator" width="200"/>
    <img src="screenshots/join_bt_pan.png" alt="Join Bluetooth PAN" width="200"/>
  </p>
- **Wired PAN:** Ethernet cable directly between your computer and the Pi.
- **Wired LAN:** Pi on your router or switch.
- **USB:** the Pi 4's USB-C port to your computer: a network as CDC-NCM (Linux, macOS, Windows 11 without a driver), rebuilt as RNDIS when the computer does not use NCM within 5 s (older Windows). The Pi is `10.10.12.1`; the boot partition also appears as a drive.
- **Wireless PAN:** join the Pi's access point (SSID `PGenerator`, password `PGenerator`).
  <p align="left"><img src="screenshots/join_wifi_pan.png" alt="Join WiFi PAN" width="200"/></p>
- **Wireless LAN:** join your own Wi-Fi from **Connectivity** in the Web UI, after connecting once by one of the methods above.

</details>

### 🔀 Coming from the original project?

OTA updates stay within one `MAJOR.MINOR` family. 2.13 needs a new kernel module, so a Pi on upstream 2.12.x cannot update to the fork over the air. To switch:

1. Export your settings with **Export System Settings** in the Web UI.
2. Flash the latest fork image (see above).
3. Import the backup, then use **Check for Updates** to reach the newest 2.13.x.

From then on the Pi follows this fork's releases. The update source is `usr/share/PGenerator/update-channel`, and an `update_repo=owner/repo` line in `PGenerator.conf` overrides it.

### ⬆️ Updating

- **Web UI:** **System → Software Update → Check for Updates → Install Update.** The dialog shows the release notes and download progress, then restarts the service. The release dropdown also lets you reinstall the current release or roll back to an earlier one.
- **SSH** (`root` / `PGenerator!!$`):

  ```bash
  /usr/sbin/pgenerator-update check   # is there something newer?
  /usr/sbin/pgenerator-update apply   # install it
  ```

---

## 🎨 What PGenerator+ does

PGenerator+ is a free, open-source display calibration suite for the Raspberry Pi 4, built around a precision HDMI test pattern generator. It produces SDR, HDR10, HLG and Dolby Vision patterns. The calibration software on your laptop drives it over TCP/IP, or it runs closed-loop SDR and HDR workflows on the Pi itself with a USB colorimeter.

- **Precision HDMI patterns:** full-screen patches, windows, APL backgrounds, custom RGB triplets and patch sizes, drawn through DRM/KMS.
- **HDR and Dolby Vision:** HDR10 (ST.2084 PQ with mastering metadata), HLG, standard and Low Latency Dolby Vision. AVI, DRM and DOVI infoframes are set correctly, and capabilities are detected from the EDID.
- **Network control:** Calman (UPGCI, port 2100), ColourSpace / LightSpace and HCFR (port 85; ColourSpace also through its `PiTPG` entry, PiTPG protocol 2), DeviceControl, and the Resolve XML protocol (port 20002, outbound). UDP discovery runs on port 1977.
- **Web dashboard:** signal settings, diagnostic patterns, a live infoframe decoder, HDMI-CEC, networking, OTA, and meter measurements. The measurement workspaces can be hidden for pattern-only setups.
- **LG AutoCal (SDR and HDR):** on-device closed-loop calibration of LG TVs: 26-point greyscale, RGB balance, 3D LUT and HDR tone mapping, with an optional Tone Mapping Shadow Fix.
- **Meter workflows:** ArgyllCMS `spotread` with persistent sessions, greyscale, colour and saturation sweeps, CCSS management, and live ΔE and chromaticity charts.
- **Display profiles:** measured Windows MHC2 and KDE HDR cLUT profiles (ICC v2.2 / v4.4 with CICP), built in the browser.
- **mDNS:** reachable at `pgenerator.local`.
- **Field networking:** Bluetooth PAN, Wi-Fi AP, Ethernet.

---

<a id="calibration-software-compatibility"></a>

## 🤝 Calibration software compatibility

**1. Calman (Portrait Displays)**

- **Protocol:** SpectraCal Unified Pattern Generator Control Interface (port `2100`)
- **Connect:** **Find Source** → Manufacturer `SpectraCal` (or `Portrait Displays`) → Model `SpectraCal - Unified Pattern Generator Control Interface`. Enter the Pi's IP and connect.
  - *Calman control:* Calman switches SDR / HDR10 / HLG / Dolby Vision, EOTF, colorimetry, format and mastering metadata directly; PGenerator+ applies them in real time. In HDR10, HLG and Dolby Vision the colorimetry stays BT.2020, the container these signals are defined in; a BT.709 gamut target is drawn inside it.
  - *Bit depth:* the Calman thread follows the configured bit depth. 10-bit codes stay exact, and codes are rounded to the output depth with a notice when one is not exact.
  - *Modes:* `CONF_FORMAT` requests resolve to the EDID copy of a mode rather than the userdef boot mode. G1 sessions start at Calman's RGB 8-bit default.
  - *Windows and APL:* fixed, custom and gray-surround APL windows (`RGB_S`, `RGB_A`, `CommandRGB`, `10_SIZE`, `11_APL`). With limited range, window backgrounds are drawn at black.
  - *Unsupported formats:* a YCbCr 4:2:0 request gets a NAK, and the WebUI shows a notice. The current format stays.
  - *Refused settings:* settings the Pi or the display cannot carry (link bandwidth, missing EDID support for a format, depth or HDR mode) get a NAK. The output stays as it was, the WebUI shows the reason and what works, and patches get a NAK until Calman sends settings that work (or disconnects). The same applies to port 85 clients (`ERR:Refused: …`).
  - *YCbCr is always Limited:* with Range Full on a YCbCr output (Calman, LightSpace, Resolve), the full-range codes are converted to studio range (0–1023 → 64–940) and the AVI infoframe says Limited, also on modes without a CEA VIC.
  - *Session safety:* pattern state is cleared on session start, shutdown and disconnect.
  - *Connect as G1:* Calman can also connect through **Find Source → Portrait Displays G1** and controls PGenerator+ completely that way: patches, signal modes and every G1 specialty pattern (Basic Alignment, Warm-Up, Granger Rainbow, Brightness, Contrast, Color Bars, SMPTE, ANSI checkerboards and the rest). The same 19 patterns are in the WebUI under Patterns.
  - *Compatibility note:* PGenerator+ is an independent community project, not affiliated with or endorsed by Portrait Displays. Make sure your Calman license and workflow comply with the vendor's terms.
  - *License note:* Portrait Displays removed UPGCI from Calman **Home** licenses starting with 5.15.x (2024). Home users need 5.14.x or older, a professional tier, or other software (ColourSpace, HCFR).

**2. ColourSpace / LightSpace CMS**

- **Protocol:** XML network calibration protocol (port `85`)
- **Connect:** **Hardware Options** → Hardware `Network` (or `PGenerator`) → enter the Pi's IP.
- **Connect as PiTPG:** in a Profiling window, **Hardware Options** → Hardware `PiTPG` → enter the Pi's IP in *Network Address* (PGenerator+ is `pgenerator.local`, not `PiTPG.local`). Port 85 tells the two protocols apart by the client's first bytes, so the classic entry keeps working.
  - *What it does:* PiTPG protocol 2 as PiTPG 2.0.0 answers it (reported edition `basic`): settings with PiTPG's value ranges, rolled back when one is refused; modes matched to the display's own list within 0.005 Hz, the EDID's timing preferred over the userdef boot mode; patches whose reply carries the DRM flip that showed them (sequence, time, frame period); the 11 test patterns (Contrast, Brightness, ANSI 1/2, Corner Box 1/2, Probe Alignment, Granger, horizontal and vertical ramps, FALD) drawn in the last patch's window; a peak note for HDR10 and Dolby Vision patches above the display's declared peak; HDMI info, EDID, InfoFrames, log and kernel log as texts.
  - *Codes and depth:* as in PiTPG, patch codes go out unchanged: the patch scale (Full, Legal, Extended) sets the RGB range in the AVI infoframe, not the codes, and the link follows the patch depth (8-bit patches on an 8-bit link, 10-bit patches need a 10-bit one). Both end with the next settings change and when ColourSpace disconnects, and the output settings in effect before them come back.
  - *Differences from a PiTPG:* standard Dolby Vision goes out limited range only (a Full or Extended patch scale is refused there), Granger is not drawn in Dolby Vision, YCbCr with a Full scale is refused (YCbCr is always Limited), and refused settings are put back rather than kept. Ted's Edition content is not part of it.

**3. HCFR**

- **Protocol:** network pattern generator commands (port `85`)
- **Connect:** **Measures → Generator → Configure** → `Network`, then enter the Pi's IP.
- Generator behaviour has been cross-checked against the upstream [HCFR](https://github.com/hcfr/hcfr) source. HCFR itself is not bundled.

**4. Resolve protocol (Calman / HCFR / DisplayCAL)**

- **Protocol:** XML calibration protocol (port `20002`). PGenerator+ connects *outbound* to the calibration PC, which helps across subnets.
- **Connect:** in the Web UI's **Resolve Protocol** card, enter the PC's IP and port and click **Connect**.
- **Bit depth:** the XML's `bits` is the precision of the patch codes, not an output setting. The output keeps the depth set in the WebUI: 8-bit codes on a 10-bit output take the same 8 → 10-bit step as the G1 patches, 10-bit codes on an 8-bit output are scaled to 8 bits by the renderer.
- **Windows redirect helper:** `tools/PGenerator-Resolve-Redirect.bat` forwards Calman's local port 20002 to the Pi.

**5. DeviceControl**

- UDP discovery on port `1977` (`"Who is a PGenerator"` → `"I am a PGenerator <name>"`) plus TCP pattern control. With the stock hostname, the device advertises itself as `PGenerator+`.

---

## 🗺️ Web UI tour

Served on **port 80** at `http://pgenerator.local`. It has a **Desktop** layout with a sidebar of workspaces and a **Tablet** layout for tablets and phones: a bottom tab bar opens one workspace at a time (Output first), with draggable, collapsible cards. The layout is chosen in Settings → UI Settings.

| Workspace | What's in it |
|---|---|
| **Output** | Signal mode (SDR / HDR10 / HLG / Dolby Vision), resolution from the EDID, bit depth, colour format, colorimetry, range, and HDR10 and DV metadata (with hints for measuring Dolby Vision). Options the Pi or the display cannot carry stay visible but locked, with the reason. **On the cable** shows what is actually sent and any quiet adjustment; banners show refused settings (with what works), HDMI link interruptions during a measurement and a test EDID in use. Shows a banner while no display is connected. Moving the cable to the other HDMI port keeps the resolution (the mode is followed by its timing, not its list position) and the output follows the cable. Below it the **Signal Self-Test**: draws known codes in every signal mode and reads the scanout back, next to link depth, range CSC, AVI infoframe, HDR metadata and the Dolby Vision infoframe |
| **Patterns** | Calman G1 plates (favourites Basic Alignment, Warm-Up, Granger Rainbow, plus all others; Basic Alignment doubles as an overscan check: numbered rings 1 to 5 % in from each edge, so the outermost ring still visible shows how much the display crops), the test images Range Check (sub-black codes show whether the display decodes the signal as Limited or Full, next to the range on the cable; an EDID check from the display's EDID and the Pi's AVI infoframe says whether the display on Auto should match), White Clipping and Black Clipping, your own uploaded images and videos, and **playlists** you step through with the TV remote; "Show menu on TV" opens the on-screen pattern menu |
| **Calibration** | Meter detection, single and continuous reads, series runs (Greyscale 21/11, Colors 30, Saturation 24), charts, and session export |
| **Meter Profiler** | Meter correction (CCSS) editor and preview |
| **3D LUT · Display Profiler** | LUT handling, MHC2 / KDE HDR profile building |
| **Connectivity** | Wi-Fi client, access point and Bluetooth in one Network card, LG TV control (pairing, AutoCal: greyscale, 3D LUT, HDR tone map, Shadow Fix) and the Resolve client; on Tablet and Phone also HDMI-CEC |
| **System** | Device info: CPU, memory and temperature with meters, plus board, hostname, resolution, uptime, RAM and the network interfaces; GPU memory (asks before the required reboot) and CPU **Scaling Type** (Performance recommended, applies at once) are set in their tiles. Below the device info: Software Update (with notes, progress, rollback) and Download Logs |
| **Live Information** (right-hand drawer on Desktop) | Active signal, the infoframe decoder (AVI, DRM and SPD), the measured HDMI link depth and clock, and HDMI-CEC with the TV remote. Updated while open; a failed read says how old the frames on screen are. On Tablet and Phone the infoframe decoder is a card in **System** |
| **Settings** | Layout, zoom, **13 themes**, Show/Hide for the Measure workspaces, and settings backup and restore |

**Don't need the meter tools?** Settings → UI Settings → **Measure Workspaces → Hide** removes Calibration, Meter Profiler, 3D LUT and Display Profiler from the navigation, along with the meter status in the header. Saved measurements, profiles and LUTs are kept, and **Show** brings everything back. The choice is stored per browser.

The header shows the connection, HDMI display, calibration software, meter and temperature at a glance. Restart and power-off are one tap away.

<details>
<summary><b>Meter &amp; measurements in detail</b></summary>

- **USB meter detection**, and reports whether `spotread` is available.
- **Persistent read sessions**, so repeated reads skip the meter init cost.
- **Read Once** and **Continuous** modes.
- **Series:** Greyscale 21pt / 11pt, Colors 30, Saturation Sweep 24.
- **Patch controls:** settle delay, patch size, APL windows, refresh-rate override, OLED pattern insertion, i1D3 AIO disable.
- **Charts:** luminance, CCT, chromaticity, RGB balance, luminance tracking, CIELUV and CIEDE2000 ΔE.
- **Supported meters:** Calibrite/X-Rite i1Display Pro Plus, i1 Pro, i1 Display Pro / ColorMunki Display, Datacolor Spyder 5 / SpyderX, ColorVision Spyder, Sequel Chroma 5.
- **Runtime:** bundled ArgyllCMS `spotread` 3.5.0 (armhf) at `/usr/bin/spotread`, with `spotread_wrapper.sh`, `spotread_measure.py`, `meter_session.sh` and `meter_series.sh`. Plain Linux USB/HID plus bundled udev rules; no proprietary drivers.
- **CCSS:** a bundled library in `/usr/share/PGenerator/ccss/`, display-type presets, and `.ccss` or spectral `.csv` uploads (stored in `ccss/custom/`).

</details>

<details>
<summary><b>LG AutoCal (SDR &amp; HDR) in detail</b></summary>

On-device closed-loop calibration of LG TVs through the webOS calibration API. LG only; it needs a paired TV.

- **`meter_lg_autocal.pl`:** 1D greyscale plus 2-point / 20-point white balance, with an optional commit-and-polish pass.
- **`meter_lg_3d_autocal.pl`:** 3D LUT autocal. It probes a colour cube, fits the residuals into the TV's LUT and re-measures.
- **SDR and HDR10:** `sdr26` and `hdr20` DDC layouts. The Pi switches the HDMI mode itself.
- **Full AutoCal pipeline:** pre-cal reads → 26-pt greyscale → 3D LUT → HDR tone map → optional Shadow Fix → post-cal reads.
- **Tone Mapping Shadow Fix:** probes the panel's post-cal DPG zones and trims the 0–30 % PQ shadow band, with revert-if-worse.
- **Panel stabilisation**, display-type presets, manual target white and black, live per-stage status, HTML and JSON reports, and restart-safe runs.

</details>

---

<a id="reference"></a>

## 📚 Reference

### 📡 Signal modes

| Mode | Description |
|---|---|
| **SDR** | Rec.709, 8- or 10-bit, RGB Full / Limited or YCbCr (always Limited) |
| **HDR10** | PQ (ST.2084), full DRM InfoFrame metadata, 10-bit (12-bit requests go out as bit-exact 10-bit) |
| **HLG** | Hybrid Log-Gamma, 10-bit |
| **Dolby Vision** | Standard (TV-led, 8-bit RGB tunnel; used for Calman DV) or Low Latency (LLDV, 12-bit) |

<a id="bit-exact-4k"></a>

### 📐 What goes out bit-exact at 4K

The Pi 4 sends at most **600 MHz** on the HDMI link, and only on HDMI0 (HDMI1: 340 MHz, no 4K 60 Hz). The link clock is the pixel clock × bit depth / 8; YCbCr 4:2:2 always travels in a 12-bit container at the pixel clock. For 4K (3840 × 2160):

| Signal | Link clock | On the cable |
|---|---|---|
| 4K 60 Hz, RGB / YCbCr 4:4:4, 8-bit | 594 MHz | **bit-exact** |
| 4K 60 Hz, YCbCr 4:2:2, 12-bit container | 594 MHz | **bit-exact** (10-bit codes; 12-bit codes in Low Latency DV) |
| 4K 24 / 30 Hz, RGB / YCbCr 4:4:4, 10-bit | 371.25 MHz | **bit-exact** |
| 4K 60 Hz, RGB / YCbCr 4:4:4, 10-bit | 742.5 MHz | **not possible**: needs HDMI 2.1 |
| 4K 60 Hz, RGB / YCbCr 4:4:4, 12-bit | 891 MHz | **not possible**: needs HDMI 2.1 |

HDMI 2.0 ends at 600 MHz; anything above needs the FRL link of HDMI 2.1, which the Pi 4 does not have. PGenerator+ **refuses** these settings with the reason and suggests what works instead (8-bit, YCbCr 4:2:2 or 24 / 30 Hz). A 12-bit RGB setting outside Dolby Vision goes out as 10-bit, and **On the cable** says so.

The Pi 4's KMS driver sets the HDMI InfoFrames directly:

- **AVI:** colour format (RGB / YCbCr 4:4:4 / 4:2:2), colorimetry (BT.709 / BT.2020), quantisation range, VIC
- **DRM:** EOTF, mastering primaries, max/min luminance, MaxCLL, MaxFALL
- **Dolby Vision:** a DOVI output metadata blob from `PGeneratord.dv`, with DV capability detected from the EDID VSVDB
- **SPD:** a stock Pi kernel names the Pi "Broadcom Videocore", source type media player, and some displays treat that source type differently (an ASUS PA32DC limited LLDV to Rec.709 until it was removed, see Light Illusion's [HDMI InfoFrames](https://www.lightillusion.com/hdmi_infoframes.html)). The vc4 driver shipped with PGenerator+ (Pi 4) never sends it; the card shows the packet enable bit read back from the HDMI block as proof

The Dolby Vision card shows what the display declares in its EDID Dolby block: peak and black luminance, supported interfaces (Standard / Low Latency) and primaries. Choosing Dolby Vision fills in the declared peak and black while Max/Min Luma are still at the factory 1000 / 0.005; otherwise it warns when Max Luma or the transport does not match (a higher Max Luma is fine to test the display's tone mapping) and sets the declared values with one button, and the measurement strip flags DV patches above the declared peak, which the display clips. With the Standard transport the card also shows the mastering display the DV metadata carries (`source_min/max_PQ`, by default the Dolby 62 / 3696 = 0.005–4000 cd/m², as in PGenerator 1.6); Max/Min Luma do not change it, a port 85 client can. In HDR10 the strip flags greyscale patches above the peak the display's HDR static metadata block declares (Desired Content Max Luminance, 50 × 2^(CV/32) cd/m²); most TVs leave that value out, so nothing is flagged for them.

### 🏗️ Architecture

```
Boot: /etc/init.d/rcPGenerator → /etc/init.d/PGenerator
  ↓
Splash: RGB565 framebuffer image → /dev/fb0 (shown once, early)
  ↓
Hardware init: USB gadget, WiFi AP, Bluetooth, DHCP
  ↓
Daemon: PGeneratord.pl (Perl TCP server)
  ├─ TCP port 85   — LightSpace / pattern protocol
  ├─ TCP port 2100 — Calman protocol
  ├─ TCP port 2101 — RPC service
  ├─ TCP port 80   — Web UI (HTTP + JSON API, gzip + ETag)
  ├─ UDP port 5353 — mDNS responder
  ├─ UDP port 1977 — Device discovery
  ├─ UDP port 3529 — RPC discovery
  ├─ Spawns PGeneratord (C/C++ renderer, reads operations.txt) once a display is connected
  │    └─ PGeneratord.dv variant for Dolby Vision
  └─ Threads: main loop, device info, UDP discovery (x3), Resolve client, HTTP, mDNS
```

**IPC:** the Perl daemon writes pattern descriptions to `/var/lib/PGenerator/operations.txt`:

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

`PGeneratord` reads this file and renders it through OpenGL ES on DRM/KMS.

Standard Dolby Vision stays wire-compatible with PGenerator 1.6 on port `85`. Clients send the same 8-bit `RGB`, `TESTPATTERN` or `TESTTEMPLATE` requests they send to 1.6. PGenerator+ converts them internally from 8-bit to 12-bit Dolby source values and keeps the 8-bit HDMI tunnel. Clients must not send the internal `SOURCE_MAX` field. `10bit` declarations are accepted and keep their added precision.

A client can advertise its name without detecting the version by extending `GETSTATUS`:

```
GETSTATUS:CLIENTNAME=PerceptualPro
```

PGenerator 1.6 treats this as a normal `GETSTATUS`. PGenerator+ also shows the sanitised name in its status bar while the socket is connected. `CLIENTNAME:<name>` works as a standalone command, and so do the aliases `CLIENT_NAME` and `SOFTWARE`. `=` may replace `:`. Names are limited to 64 safe characters, and commands end with `0x02 0x0d`.

**Privilege separation:** the daemon runs as `pgenerator`. Privileged operations (config writes, service control, updates) go through `PGenerator_cmd.pl` via `sudo`, with base64-encoded environment arguments. The WebUI refuses cross-site requests.

### ⚙️ Configuration

`/etc/PGenerator/PGenerator.conf`: flat `key=value`, no sections.

| Key | Values | Description |
|---|---|---|
| `port_pattern` | `85` | TCP port for the pattern protocol (read-only) |
| `color_format` | `0`=RGB, `1`=YCbCr444, `2`=YCbCr422 | HDMI output colour format |
| `colorimetry` | `0`=BT.709, `1`=BT.2020 | AVI InfoFrame colorimetry |
| `rgb_quant_range` | `0`=Auto, `1`=Limited, `2`=Full | RGB quantisation range (YCbCr always goes out Limited) |
| `max_bpc` | `8`, `10`, `12` | Bits per channel |
| `eotf` | `0`=SDR, `2`=PQ, `3`=HLG | Transfer function |
| `primaries` | `1`=Rec.2020, `2`=P3/D65, `3`=P3/DCI | Mastering display primaries |
| `max_luma` / `min_luma` | nits (min ×0.0001) | Mastering display luminance |
| `max_cll` / `max_fall` | nits | Content light level metadata |
| `dv_status` | `0`=off, `1`=on | Use the Dolby Vision renderer |
| `is_hdr` / `is_sdr` | `0` / `1` | Signal mode flags |
| `is_ll_dovi` / `is_std_dovi` | `0` / `1` | Dolby Vision mode flags |
| `dv_interface` | `0`=Standard, `1`=Low Latency | DV interface type |
| `dv_map_mode` | `1`=Absolute, `2`=Relative | DV source-mapping mode of the `.dv` renderer |
| `dv_metadata` | `2`=Perceptual, `3`=Absolute, `4`=Relative | Calman metadata-mode bookkeeping |
| `dv_color_space` | `0`=YCbCr422, `1`=RGB444, `2`=YCbCr444 | DV colour space |
| `update_repo` | `owner/repo` | Optional: override the OTA source (default from `update-channel`) |

**LUT correction:** `/etc/PGenerator/lut.txt` holds per-channel deltas (`R,G,B=R_delta,G_delta,B_delta`, plus an `ALL` wildcard). The daemon applies them before writing pattern files.

**Test EDID:** a file `PGenerator-test-EDID.bin` in the root of the boot partition (the FAT partition a PC sees on the SD card) replaces the connected display's EDID from the next start of PGenerator+: modes, formats, HDR and Dolby Vision support then come from the file (for example to try a Dolby Vision block the display does not have). It must be a complete EDID (version 1, 128 bytes per block, as many blocks as the base block declares, valid checksums); anything else is ignored with the reason. Copied through the Pi's USB drive, eject the drive on the computer before restarting. A display must still be connected. The HDMI-CEC physical address is taken from the file too, so with a file from another display the TV remote may not reach the Pi. Output shows a banner while it is in use; remove the file and restart for the display's own EDID. The last result is in `/var/log/PGenerator/test-edid.txt` (what the banner shows) and `test-edid.log` (the whole run).

### 🍓 Hardware

- **Raspberry Pi 4** (or Pi 400). This is required for HDR10/DV and the KMS driver. Other Pi models are not supported.
- HDMI connection to the display
- Network: Ethernet, Wi-Fi, Bluetooth or the Wi-Fi AP

<details>
<summary><b>API reference</b></summary>

All endpoints are on port 80 and return JSON.

| Method | Endpoint | Description |
|---|---|---|
| GET | `/api/ping` | Health check; `boot` is the kernel boot id, new after every reboot |
| GET | `/api/info` | Device info (hostname, temp, IPs, Wi-Fi, resolution, calibration status with `sessions`: software, protocol, port, peer, start and last data per session) |
| GET | `/api/config` | Current configuration |
| POST | `/api/config` | Apply configuration changes (only the keys you send). Signal settings the Pi or display cannot carry are refused (`"refused":true` with the reason, nothing written); so are signal changes while Calman, ColourSpace or LightSpace is connected (`"locked":true`; `/api/info` reports it as `calibration.owns_signal`), and colorimetry 7 (opRGB) or 8 (BT.2020 constant luminance) with YCbCr, which the renderer cannot encode. In HDR10, HLG and Dolby Vision the colorimetry is always BT.2020 (9). Quiet adjustments come back in `adjusted` |
| GET | `/api/modes` | HDMI modes from the display EDID |
| POST | `/api/restart` | Restart the pattern generator |
| POST | `/api/reboot` | Reboot the device |
| GET / POST | `/api/ui/bootscreen-theme` | Read / store the theme colours for the TV's start and restart screen (`theme`, `colors`: nine `#rrggbb` values); the WebUI sends the latest theme choice in order, reports save failures with Retry, and retries an unsaved choice after a page reload |
| GET | `/api/wifi/scan` | Scan for Wi-Fi networks |
| GET | `/api/wifi/status` | Wi-Fi connection status |
| POST | `/api/wifi/connect` | Connect to Wi-Fi (`ssid`, `psk`) |
| GET / POST | `/api/wifi/ap` | Read / set AP SSID and password |
| GET | `/api/infoframes` | AVI, DRM and SPD InfoFrame hex data, whether SPD is on the wire |
| GET | `/api/signal` | What the settings ask for (`requested`), what is on the cable (`sending`, `wire`: format, range, EOTF, depth, TMDS clock), the check against board and display (`check`), quiet `adjustments`, the current refusal (`refused`), the last HDMI link interruption during a measurement (`link_event`) and a test EDID in use or not applied (`test_edid`) |
| GET | `/api/cec/status` | HDMI-CEC TV power status |
| GET | `/api/cec/{cmd}` | Send a CEC command (`wake`, `on`, `off`, `as`) |
| POST | `/api/pattern` | Display a test pattern (refused with the reason while signal settings are refused) |
| POST | `/api/resolve/connect` · `/disconnect` | Resolve client mode |
| GET | `/api/resolve/status` | Resolve connection status |
| GET | `/api/update/check` | Check this fork's releases for an OTA package |
| POST | `/api/update/apply` | Start the OTA download and install |
| GET | `/api/update/status` | OTA progress |
| GET / POST | `/api/boot/memory` | Read / set the GPU memory split (POST reboots) |
| GET / POST | `/api/system/governor` | Read / set the CPU scaling governor (`{"governor":"performance"}`), no reboot |

**Meter & CCSS**

| Method | Endpoint | Description |
|---|---|---|
| GET | `/api/meter/status` | Detect the meter and `spotread` |
| POST | `/api/meter/read` | Start a manual read |
| GET | `/api/meter/read/result` | Poll the latest read |
| POST | `/api/meter/series` | Start a greyscale, colour or saturation series |
| GET | `/api/meter/series/status` | Series progress and readings |
| POST | `/api/meter/stop` · `/clear` · `/reset` | Stop, clear results, force a meter reset |
| GET / POST | `/api/meter/settings` | Load / save meter settings (POST replaces them; send the full object) |
| GET | `/api/ccss/list` · `/api/ccss/all` | Custom / all CCSS profiles |
| POST | `/api/ccss/upload` | Upload a `.ccss` or spectral `.csv` |
| POST | `/api/ccss/delete/{filename}` | Delete a custom profile |

</details>

<details>
<summary><b>Project structure</b></summary>

```
src/
  pattern_generator/             # PGeneratord renderer source (C++/openFrameworks)
  ofxRPI4Window/                 # DRM/KMS window addon with HDR/DV support
  PGeneratorDisplayMirror.c      # Display mirror utility
etc/
  init.d/PGenerator              # Init script (service start/stop)
  PGenerator/PGenerator.conf     # Configuration (key=value)
  PGenerator/lut.txt             # LUT colour correction table
  udev/rules.d/99-colorimeter.rules
  sudo/sudoers.d/PGenerator
usr/
  sbin/
    PGeneratord.pl               # Main daemon (Perl, forks + threads)
    PGeneratord, PGeneratord.dv  # Prebuilt renderers
    pgenerator-update            # OTA updater (GitHub Releases)
  bin/
    PGenerator_cmd.pl            # Privileged command handler (root)
    meter_*.sh, spotread_*       # Meter automation
  share/PGenerator/
    daemon.pm                    # TCP server, request routing, threads
    pattern.pm                   # Pattern files, LUT, scaling
    client.pm                    # LightSpace / Calman protocols
    resolve.pm                   # Resolve XML protocol (client mode)
    discovery.pm                 # UDP discovery
    webui.pm                     # HTTP server + JSON API
    webui-*.html/css/js          # Web UI fragments
    update-channel               # OTA source repository
    version.pm                   # Version info
    ccss/                        # Bundled CCSS profiles
tools/
  build_pgenerator_plus_ota.sh   # OTA package builder
  build_pgenerator_plus_image.sh # Overlay image builder
  renderer-build/                # Cross-build of the renderer in a VM
```

Target overlays (`tools/image-targets/*/rootfs`) own the renderer binaries and hardware backend files (`command.pm`, `conf.pm`, `variables.pm`, CEC helpers, DRM override). They come from a reviewed external release input and are not part of a clean public checkout. The calibration maths are documented in [Calibration maths architecture](docs/calibration-math-architecture.md).

</details>

<details>
<summary><b>Build your own image or OTA package</b></summary>

**Overlay image** (bring your own BiasiLinux / PGenerator base):

```bash
sudo ./tools/build_pgenerator_plus_image.sh \
  --base-image /path/to/compatible-biasilinux-pgenerator.img \
  --output ./build/PGenerator_Plus_custom.img
```

The script copies the base image and overlays the repository's `etc/`, `usr/`, `var/` and `lib/` trees onto its root partition. It is an overlay build, not a from-scratch distro build: the base must already contain the BiasiLinux dependencies, the `pgenerator` account and the sudoers setup. The renderer binaries are taken from the repo as they are. Clear runtime state before publishing an image, and make sure `PGenerator.conf` is back on the SDR 1080p RGB 8-bit default. The script does not shrink or compress the image.

The ArgyllCMS 3.5.0 armhf runtime is bundled. Its `colprof` comes from the PGenerator+ ICC v4.4/CICP fork. For on-device TI3 → CCSS conversion, import `ccxxmake` and its helpers with [tools/import_argyll_runtime.sh](tools/import_argyll_runtime.sh), or pass `--argyll-runtime-dir` to the image builder.

**OTA package:**

```bash
./tools/build_pgenerator_plus_ota.sh
```

The updater downloads only the newest tarball, so every OTA package is a **cumulative overlay** of `etc`, `usr`, `var` and `lib`, not a delta. Use versioned scripts in `usr/share/PGenerator/update-migrations.d` for one-time migrations and file removals. During `apply`, the updater runs every script newer than the installed version and no newer than the target.

**VC4 kernel module:** the `5.10.89+-7l` build tree lives in `build/vc4-kernel-build-env/` (gitignored). The build notes are kept locally and are not part of the public tree.

</details>

<details>
<summary><b>Build the renderer from source</b></summary>

`PGeneratord` is a C++ application on [openFrameworks](https://openframeworks.cc/) 0.11.2, with a custom DRM/KMS window addon for HDR and Dolby Vision output.

```
src/
  pattern_generator/src/
    main.cpp        # Config parsing, Pi/distro checks, window setup
    ofApp.cpp       # Render loop: operations.txt, patterns, DV metadata
    rgb2ycbcr.h     # RGB ↔ YCbCr conversion
  ofxRPI4Window/src/
    ofxRPI4Window.cpp  # Atomic modesetting, EGL/GBM, HDR/DV infoframes
    igt_edid.h         # EDID parsing helpers
  ofxRPI4Window/patchOF.sh, ofx.patch, drm_vc4.patch, mesa_hdr.patch
```

**On a Pi 4** with BiasiLinux, openFrameworks 0.11.2 in `/opt/openFrameworks`, and `libdrm`, `gbm`, `gles2`, `egl`, `gstreamer`, `boost-filesystem`, `freeimage`, `cairo`, `curl`, `fontconfig` and `uriparser` dev packages installed:

```bash
cp -r src/ofxRPI4Window /opt/openFrameworks/addons/
cd /opt/openFrameworks/addons/ofxRPI4Window && ./patchOF.sh   # option 1
cd /path/to/PGenerator-Plus/src/pattern_generator && make
sudo cp bin/PGeneratord /usr/sbin/PGeneratord
sudo cp bin/PGeneratord /usr/sbin/PGeneratord.dv
```

**Cross-build:** `tools/renderer-build/` builds `PGeneratord`, `PGeneratord.dv` and `drm_override.so` in a bionic sysroot VM. The shipped binaries in `usr/sbin/` are the authoritative runtime artifacts.

Sources: [BigShoots/PGenerator_Source](https://github.com/BigShoots/PGenerator_Source) (`pgen_dovi_latest`) by Riccardo Biasiotto, GPLv3. The DRM/KMS addon is [docdude/ofxRPI4WindowHDR](https://github.com/docdude/ofxRPI4WindowHDR), forked from [jvcleave/ofxRPI4Window](https://github.com/jvcleave/ofxRPI4Window).

</details>

---

## 🙏 Credits

This fork stands on the shoulders of:

- **[PGenerator](https://github.com/Biasiolo/PGenerator)** by Riccardo Biasiotto: the pattern engine, TCP protocols and renderer (GPLv3).
- **[BigShoots/PGenerator-Plus](https://github.com/BigShoots/PGenerator-Plus)**: the original PGenerator+, with the Web UI, HDR/DV configuration, meter workflows, LG AutoCal, profile building and OTA. This fork continues from its 2.12.1.
- **[docdude/ofxRPI4WindowHDR](https://github.com/docdude/ofxRPI4WindowHDR)**, **[ArgyllCMS](https://www.argyllcms.com/)** and **[HCFR](https://github.com/hcfr/hcfr)**.

## ☕ Support the project

If this fork saves you time on your calibration bench, a coffee keeps the work going:

<p>
  <a href="https://buymeacoffee.com/fabioelia9r"><img src="https://img.shields.io/badge/Buy%20me%20a%20coffee-fabioelia9r-ffdd00?style=for-the-badge&logo=buymeacoffee&logoColor=black" alt="Buy me a coffee"/></a>
</p>

## 📜 License

GNU General Public License v3.0. See [COPYING](COPYING).
