# PGenerator v1.6 vs PGenerator+ Comparison Report

**Date:** 2026-03-03  
**Original v1.6:** Running on Pi 400 Rev 1.0, kernel 5.10.89+-7l, BiasiLinux  
**PGenerator+:** v2.0.2, same hardware platform

---

## File-by-File Status

| File | Status | Calibration Impact |
|------|--------|--------------------|
| bash.pm | **Identical** | None |
| client.pm | **Identical** | None |
| file.pm | **Identical** | None |
| info.pm | **Identical** | None |
| log.pm | **Identical** | None |
| serial.pm | **Identical** | None |
| version.pm | Changed (1.6 → 2.0.2) | None |
| variables.pm | Changed | Minor (new vars, debug logging) |
| conf.pm | Changed | Yes (bits_default sync) |
| pattern.pm | Changed | Yes (max_rgb dynamic calc) |
| daemon.pm | **Heavily changed** | Yes (RGB scaling, UPGCI protocol) |
| command.pm | Changed | Yes (DRM properties, LD_PRELOAD) |
| discovery.pm | Changed | None (client tracking only) |
| PGeneratord.pl | Changed | None (loads webui.pm) |
| webui.pm | **New file** (2057 lines) | None |
| favicon.ico | **New file** | None |

---

## Original v1.6 Capabilities

- **8-bit only** — `max_bpc=8`, `$bits_default=8` hardcoded, never changed at runtime
- **RGB Full only** — `color_format=0`, no YCbCr support
- **No HDR metadata commands** — no UPGCI protocol for HDR/EOTF/DV switching
- **CSC registers:** Identity matrix (RGB passthrough)
- **Calman RGB conversion:** `int($val/1024*256)` — always downscales 10-bit Calman inputs to 8-bit

### Verified Pattern Output (Original v1.6)

**Calman 100% white (1023,1023,1023,100):**
```
BITS=8
RGB=255,255,255
DIM=7680,4320
POSITION=-1920,-1080
```

**Calman 50% grey (512,512,512,100):**
```
BITS=8
RGB=128,128,128
DIM=7680,4320
POSITION=-1920,-1080
```

Note: DIM=7680,4320 (2× screen size) is a known scaling issue (`$max_x/$max_y` = 1920×1080 while display is 3840×2160). The C binary clamps to screen size, so display output is correct.

---

## Calibration-Critical Differences

### 1. RGB Value Scaling (daemon.pm) — Most Important Change

| Aspect | Original v1.6 | PGenerator+ |
|--------|---------------|-------------|
| Formula | `int($val/1024*256)` | `int($val/$calman_max*$target_max+0.5)` |
| Divisor | 1024 (power of 2) | 1023 (actual max code value) |
| Rounding | Truncation | Round-half-up (+0.5) |
| Output depth | Always 8-bit (0-255) | Native: 8→255, 10→1023, 12→4095 |

**At 8-bit, both produce identical integer results** for all Calman inputs. The +0.5 rounding and /1023 vs /1024 divisor difference doesn't change any integer output at 8-bit depth.

**At 10-bit (Plus only):** Calman values pass through directly (1023→1023), enabling true 10-bit precision.

### 2. DIM Scaling Fix (command.pm + pattern.pm)

Plus adds `$max_x=$w_s; $max_y=$h_s` after resolution changes, fixing the 2× oversized DIM. Original's oversized DIM is harmless (C binary clamps) but incorrect.

### 3. `$bits_default` Sync from Config (conf.pm)

Plus adds: `$bits_default=int($pgenerator_conf{"max_bpc"}) if($pgenerator_conf{"max_bpc"} > 0)`

Ensures patterns match the configured bit depth from boot, not just after Calman sends a BITD command.

### 4. Dynamic `$max_rgb` Calculation (pattern.pm)

Plus adds: `$max_rgb=(1 << $bits) - 1 if($bits > 8)`

Enables proper range validation for 10-bit and 12-bit patterns.

### 5. DRM Property Setup (command.pm)

Plus adds `apply_drm_properties()` before spawning the binary and `LD_PRELOAD=drm_override.so`. Required for Pi 4 KMS driver; doesn't affect 8-bit RGB behavior.

---

## New Features in Plus (Not in Original)

### Protocol Extensions (daemon.pm)
- **UPGCI Calman commands:** SN, CAP, TERM, ENABLE PATTERNS, INIT
- **HDR control:** HDR_ENABLE, CONF_HDR, DSMD, EOTF/HDR_EOTF, PRIM/HDR_PRIMARIES
- **Signal settings:** BITD, COLF, QRNG, CLSP, MAXL, MINL, MAXCLL, MAXFALL
- **Pattern control:** CommandRGB, SetRange, 10_SIZE, 11_APL, 303_UPDATE/APPLY
- **Window sizing:** RGB_S direct percentage windows, RGB_B manual gray surround, RGB_A explicit foreground/background/window payloads
- **Calman session handling:** resets APL/window/background state on INIT, TERM, QUIT/SHUTDOWN, and disconnect so stale Calman state does not leak between sessions
- **RPC support:** raw RPC clients on port 2101 receive real CAP / STATUS responses and can use `CommandRGB` without STX/ETX framing
- **DV mode:** 21_HDR_MetadataMode for Dolby Vision sub-modes

### Infrastructure
- **Web UI** (webui.pm) — HTTP server on port 80 + mDNS (pgenerator.local)
- **Auto 4K mode selection** — scans modetest for 3840×2160@30
- **Thread stability** — SIGPIPE handling, detached threads, recv/accept error handling
- **Client tracking** — IP + software name for WebUI status display
- **Deferred apply** — batches setting changes, restarts binary only when pattern arrives

---

## CSC Register Baseline (HDMI0 @ 0xFEF00200)

### Original v1.6 (RGB Full 8-bit, 3840×2160@25)
```
CSC+0x00 CSC_CTL      = 0x00000007  (enabled, RGB mode)
CSC+0x04 CSC_12_11    = 0x00002000  (identity: G=0, R=1.0)
CSC+0x08 CSC_14_13    = 0x00000000  (B=0, offset=0)
CSC+0x0c CSC_22_21    = 0x20000000  (G=1.0, R=0)
CSC+0x10 CSC_24_23    = 0x00000000  (B=0, offset=0)
CSC+0x14 CSC_32_31    = 0x00000000  (G=0, R=0)
CSC+0x18 CSC_34_33    = 0x00002000  (B=1.0, offset=0)
CSC+0x1c              = 0x00300000
```
Identity matrix — pure RGB passthrough. S2.13 format: 0x2000 = 1.0.

### PGenerator+ (RGB Limited 8-bit — last read before swap)
```
CSC+0x00 CSC_CTL      = 0x00000007
CSC+0x04 CSC_12_11    = 0x00001b80  (R scaling ≈ 0.8438)
CSC+0x08 CSC_14_13    = 0x04000000  (offset=64)
CSC+0x0c CSC_22_21    = 0x1b800000  (G scaling ≈ 0.8438)
CSC+0x10 CSC_24_23    = 0x04000000  (offset=64)
CSC+0x14 CSC_32_31    = 0x00000000
CSC+0x18 CSC_34_33    = 0x04001b80  (B scaling ≈ 0.8438, offset=64)
CSC+0x1c              = 0x00300000
```
Full→Limited RGB scaling matrix (219/256 ≈ 0.8555, offset=16×4=64).

---

## PGenerator.conf Comparison

### Original v1.6
```
max_bpc=8
color_format=0
rgb_quant_range=2
colorimetry=9
is_hdr=1
eotf=2
dv_status=0
mode_idx=13
```

### PGenerator+ (typical HDR 10-bit config)
```
max_bpc=10
color_format=0 (or 1 for YCbCr444)
rgb_quant_range=1
colorimetry=9
is_hdr=1
eotf=2
dv_status=0
mode_idx=20
```

---

## Conclusion

**The original v1.6 is 8-bit RGB only.** It has no support for 10-bit, HDR metadata switching, YCbCr, or Dolby Vision through Calman commands.

**PGenerator+ retains bit-perfect 8-bit calibration compatibility.** All unchanged code paths (client.pm, pattern template system, LUT application, DeviceControl protocol) are identical. The Calman RGB conversion produces identical integer output at 8-bit depth.

**All Plus changes are either:**
1. New features (HDR, 10-bit, YCbCr, Web UI, DV)
2. Bug fixes that don't affect 8-bit behavior (DIM scaling, thread safety)
3. Infrastructure for the new features (DRM properties, LD_PRELOAD)
