# Raspberry Pi PGenerator Bit-Depth Handling: Original vs Plus

Date: 2026-03-03

## 1) Scope, Inputs, and Evidence Limits

This document compares **how bit depth is actually handled in code** for:

- **Original**: `PGenerator_original`
- **Plus**: `PGenerator_plus`

It also includes the requested AVSForum PDF input:

- `../../avsforum.pdf`

### AVSForum PDF extractability in this environment

The PDF exists and is valid, but text extraction is not available from current tooling/runtime:

- PDF confirmed: [../../avsforum.pdf](../../avsforum.pdf)
- Metadata available via `pdfinfo` (55 pages, Microsoft Print to PDF producer).
- `pdftotext` returns effectively no textual content.
- `pdfimages -list` shows image-heavy pages.
- OCR tooling (`tesseract`) is not installed in this environment.

**Result:** AVSForum content cannot be quoted/paraphrased directly here; the comparison below is grounded in repository source code and config/docs.

---

## 2) High-Level Summary

- **Original is effectively 8-bit in active Calman RGB handling**: incoming Calman RGB payloads are down-converted using `int(v/1024*256)`.
- **Plus introduces protocol-level bit-depth controls** (`BITD`, HDR/format controls), renderer selection by `max_bpc`, and a native 10-bit renderer path (`pgeneratord_10bit`).
- **Plus still has mixed behavior by command path**:
  - `CommandRGB` path still applies the legacy 10-bit→8-bit down-conversion.
  - `RGB_*` path scales to `bits_default` target range.
- **12-bit in Plus is link/config-level; render surface remains 10-bit** in `pgeneratord_10bit` (12-bit values are quantized to 10-bit).

---

## 3) Original: End-to-End Bit-Depth Behavior

### 3.1 Defaults and state

- `bits_default` is initialized to 8:
  - [../../PGenerator_original/usr/share/PGenerator/variables.pm#L161](../../PGenerator_original/usr/share/PGenerator/variables.pm#L161)
- Default config also ships with `max_bpc=8`:
  - [../../PGenerator_original/etc/PGenerator/PGenerator.conf#L12](../../PGenerator_original/etc/PGenerator/PGenerator.conf#L12)

### 3.2 Calman parser behavior (daemon path)

- Calman branch in daemon handles `RGB_*` payloads and converts RGB values as:
  - `int($el_cmd[n]/1024*256)`
  - [../../PGenerator_original/usr/share/PGenerator/daemon.pm#L248-L257](../../PGenerator_original/usr/share/PGenerator/daemon.pm#L248-L257)
- Special case: `RGB_S` size `100` uses full-field pattern generation:
  - [../../PGenerator_original/usr/share/PGenerator/daemon.pm#L264-L272](../../PGenerator_original/usr/share/PGenerator/daemon.pm#L264-L272)
- No equivalent runtime handling for Plus-only control commands (`BITD`, `CONF_HDR`, `HDR_ENABLE`, etc.) in this parser block.
- The protocol reference documents 8/10-bit `CommandRGB` semantics, but that does not change the daemon conversion path above:
  - [../../PGenerator_original/UPGCI_Protocol_Reference.txt#L156-L175](../../PGenerator_original/UPGCI_Protocol_Reference.txt#L156-L175)

### 3.3 Pattern file and `BITS` semantics

- Simple pattern generation defaults to 8-bit bounds (`0..255`); 10-bit bounds are only enabled for `...10bit` draw suffix:
  - [../../PGenerator_original/usr/share/PGenerator/pattern.pm#L35-L48](../../PGenerator_original/usr/share/PGenerator/pattern.pm#L35-L48)
- Template expansion resolves `BITS=DYNAMIC` from input/default, otherwise writes `BITS=$bits_default`:
  - [../../PGenerator_original/usr/share/PGenerator/pattern.pm#L464-L500](../../PGenerator_original/usr/share/PGenerator/pattern.pm#L464-L500)

### 3.4 Renderer handoff

- Start path always launches legacy `/usr/sbin/PGeneratord`:
  - [../../PGenerator_original/usr/share/PGenerator/command.pm#L23-L31](../../PGenerator_original/usr/share/PGenerator/command.pm#L23-L31)

### 3.5 Related but separate config knobs

- Config writes support `MAX_BPC` and many HDR/DV keys through command interface:
  - [../../PGenerator_original/usr/share/PGenerator/command.pm#L145-L152](../../PGenerator_original/usr/share/PGenerator/command.pm#L145-L152)
- But Calman RGB parser behavior above remains fixed to 10-bit-input→8-bit conversion.

### 3.6 LightSpace client nuance

- LightSpace XML path can carry `colex.bits` and pass bit info into template payload generation:
  - [../../PGenerator_original/usr/share/PGenerator/client.pm#L81-L109](../../PGenerator_original/usr/share/PGenerator/client.pm#L81-L109)

---

## 4) Plus: End-to-End Bit-Depth Behavior

### 4.1 Defaults and startup sync

- Base variable remains `bits_default=8`:
  - [../usr/share/PGenerator/variables.pm#L164](../usr/share/PGenerator/variables.pm#L164)
- On startup, if `max_bpc >= 10` and `pgeneratord_10bit` exists, Plus forces `bits_default=10`:
  - [../usr/share/PGenerator/conf.pm#L57-L61](../usr/share/PGenerator/conf.pm#L57-L61)

### 4.2 Extended Calman/UPGCI settings handling

- Plus daemon adds a richer command parser and deferred-apply model:
  - `calman_save_setting` / `calman_apply`
  - [../usr/share/PGenerator/daemon.pm#L331-L348](../usr/share/PGenerator/daemon.pm#L331-L348)
- `BITD` accepts `8`, `10`, `12` and writes `max_bpc`:
  - [../usr/share/PGenerator/daemon.pm#L588-L592](../usr/share/PGenerator/daemon.pm#L588-L592)
- Also handles HDR and format controls (`HDR_ENABLE`, `CONF_HDR`, `COLF`, `QRNG`, `CLSP`, luminance metadata, etc.):
  - [../usr/share/PGenerator/daemon.pm#L354-L706](../usr/share/PGenerator/daemon.pm#L354-L706)

### 4.3 Two different RGB conversion paths

### A) `CommandRGB` path (legacy behavior retained)

- When `tenBit` flag is set, Plus still performs:
  - `int(v/1024*256)`
  - [../usr/share/PGenerator/daemon.pm#L708-L719](../usr/share/PGenerator/daemon.pm#L708-L719)

### B) `RGB_*` path (bits-aware scaling)

- Uses `calman_max=1023` and `target_max` from `bits_default`:
  - 8-bit target: `255`
  - 10-bit target: `1023`
  - 12-bit target: `4095`
- Formula:
  - `int(v / 1023 * target_max + 0.5)`
  - [../usr/share/PGenerator/daemon.pm#L743-L752](../usr/share/PGenerator/daemon.pm#L743-L752)

### 4.4 Pattern generation and `BITS`

- `create_pattern_file()` now generalizes max RGB for bits > 8:
  - `max_rgb = (1 << bits) - 1`
  - [../usr/share/PGenerator/pattern.pm#L47-L50](../usr/share/PGenerator/pattern.pm#L47-L50)
- Template/default `BITS` behavior remains analogous to Original (but uses current `bits_default`):
  - [../usr/share/PGenerator/pattern.pm#L468-L503](../usr/share/PGenerator/pattern.pm#L468-L503)

### 4.5 Renderer selection and DRM setup

- Before launch, Plus applies KMS connector properties (`max bpc`, `output format`):
  - [../usr/share/PGenerator/command.pm#L49-L76](../usr/share/PGenerator/command.pm#L49-L76)
- Start logic:
  - `max_bpc >= 10` + binary present → `/usr/sbin/pgeneratord_10bit`
  - else → legacy `PGeneratord` with `LD_PRELOAD=/usr/lib/drm_override.so`
  - [../usr/share/PGenerator/command.pm#L88-L106](../usr/share/PGenerator/command.pm#L88-L106)

### 4.6 Native 10-bit renderer internals (`pgeneratord_10bit`)

- Uses DRM dumb buffer + `XRGB2101010` framebuffer format:
  - [../usr/sbin/pgeneratord_10bit.c#L289-L299](../usr/sbin/pgeneratord_10bit.c#L289-L299)
- Reads `BITS` from operations file (fallback from config):
  - [../usr/sbin/pgeneratord_10bit.c#L445-L463](../usr/sbin/pgeneratord_10bit.c#L445-L463)
- Converts inputs to 10-bit render domain:
  - 8-bit scaled up to 10-bit
  - 10-bit passthrough
  - 12-bit scaled down to 10-bit
  - [../usr/sbin/pgeneratord_10bit.c#L488-L500](../usr/sbin/pgeneratord_10bit.c#L488-L500)
  - [../usr/sbin/pgeneratord_10bit.c#L591-L606](../usr/sbin/pgeneratord_10bit.c#L591-L606)

### 4.7 DRM override and DV gating

- `drm_override` reads `max_bpc`, `dv_status`, `color_format` from config and overrides DRM property calls:
  - [../usr/lib/drm_override.c#L391-L460](../usr/lib/drm_override.c#L391-L460)
- Explicitly blocks `DOVI_OUTPUT_METADATA` when `dv_status=0`:
  - [../usr/lib/drm_override.c#L570-L620](../usr/lib/drm_override.c#L570-L620)

### 4.8 Runtime sync caveat in Web UI

- Web UI update path intentionally does **not** live-sync `bits_default` from `max_bpc` (`if(0)` guard):
  - [../usr/share/PGenerator/webui.pm#L387-L388](../usr/share/PGenerator/webui.pm#L387-L388)

---

## 5) Side-by-Side Bit-Depth Differences

| Stage | Original | Plus |
|---|---|---|
| Default bit-depth state | `bits_default=8` | `bits_default=8`, may become `10` at startup when `max_bpc>=10` and 10-bit renderer exists |
| Calman settings protocol | Mostly `RGB_*` pattern handling | Adds `BITD`, HDR metadata and signal-format controls |
| Main RGB conversion | `int(v/1024*256)` | `CommandRGB`: same legacy conversion; `RGB_*`: bits-aware scaling to 8/10/12 target range |
| `BITS` in operations flow | Usually ends up at default 8 unless template/path overrides | Tracks `bits_default`, with wider numeric validation |
| Renderer process | Legacy `PGeneratord` | Auto-selects `pgeneratord_10bit` for `max_bpc>=10`, else legacy + `drm_override` |
| Render precision | Inferred 8-bit-oriented from daemon conversion path | Native 10-bit framebuffer path (`XRGB2101010`) |
| 12-bit handling | No end-to-end 12-bit render path visible | Accepts 12-bit settings but quantizes to 10-bit in renderer |
| DV metadata control | Config knobs exist; no equivalent rich parser path | DV metadata/property handling and explicit `dv_status` gating in override layer |

---

## 6) Numeric Conversion Comparison (Important)

### 6.1 Formulas in code

- Original Calman `RGB_*`:
  - `int(v/1024*256)`
  - [../../PGenerator_original/usr/share/PGenerator/daemon.pm#L254-L256](../../PGenerator_original/usr/share/PGenerator/daemon.pm#L254-L256)
- Plus `RGB_*` when `bits_default=8`:
  - `int(v/1023*255+0.5)`
  - [../usr/share/PGenerator/daemon.pm#L743-L749](../usr/share/PGenerator/daemon.pm#L743-L749)

### 6.2 Equivalence check result

Evaluating both formulas over all `v=0..1023` yields **170 differing code points**.

Representative differences:

| Input `v` | Original output | Plus (`RGB_*`, 8-bit target) |
|---:|---:|---:|
| 3 | 0 | 1 |
| 7 | 1 | 2 |
| 768 | 192 | 191 |
| 940 | 235 | 234 |
| 1000 | 250 | 249 |
| 1020 | 255 | 254 |
| 1023 | 255 | 255 |

Interpretation:

- Plus `RGB_*` path is not numerically identical to Original for all 10-bit inputs at 8-bit output target.
- Plus `CommandRGB` path remains legacy-compatible conversion-wise when `tenBit=1`.

---

## 7) Documentation/Code Consistency Notes

There is at least one notable naming/runtime mismatch to be aware of while analyzing bit-depth and DV paths:

- README references `PGeneratord.dv` as the DV variant:
  - [../README.md#L64-L66](../README.md#L64-L66)
  - [../README.md#L179](../README.md#L179)
  - [../README.md#L218](../README.md#L218)
- Current start logic in code routes by `max_bpc` to `pgeneratord_10bit` vs legacy binary:
  - [../usr/share/PGenerator/command.pm#L88-L106](../usr/share/PGenerator/command.pm#L88-L106)

This does not invalidate bit-depth findings, but it matters when mapping README statements to active runtime paths.

---

## 8) Practical Conclusions

1. **Original**: active Calman RGB path is 8-bit-oriented in practice due fixed 10-bit→8-bit conversion in daemon.
2. **Plus**: introduces real 10-bit rendering capability via dedicated renderer and KMS property orchestration.
3. **Plus command-path caveat**: not all incoming command paths are equally “10-bit native” (`CommandRGB` vs `RGB_*`).
4. **12-bit caveat**: accepted at control/link level, but renderer quantizes to 10-bit pixel packing.
5. **AVSForum source integration**: direct textual extraction from the provided PDF was not possible here; code evidence is complete and reproducible.

---

## 9) Primary Source Index

### Original

- [../../PGenerator_original/usr/share/PGenerator/variables.pm](../../PGenerator_original/usr/share/PGenerator/variables.pm)
- [../../PGenerator_original/usr/share/PGenerator/daemon.pm](../../PGenerator_original/usr/share/PGenerator/daemon.pm)
- [../../PGenerator_original/usr/share/PGenerator/pattern.pm](../../PGenerator_original/usr/share/PGenerator/pattern.pm)
- [../../PGenerator_original/usr/share/PGenerator/command.pm](../../PGenerator_original/usr/share/PGenerator/command.pm)
- [../../PGenerator_original/usr/share/PGenerator/client.pm](../../PGenerator_original/usr/share/PGenerator/client.pm)
- [../../PGenerator_original/etc/PGenerator/PGenerator.conf](../../PGenerator_original/etc/PGenerator/PGenerator.conf)

### Plus

- [../usr/share/PGenerator/conf.pm](../usr/share/PGenerator/conf.pm)
- [../usr/share/PGenerator/variables.pm](../usr/share/PGenerator/variables.pm)
- [../usr/share/PGenerator/daemon.pm](../usr/share/PGenerator/daemon.pm)
- [../usr/share/PGenerator/pattern.pm](../usr/share/PGenerator/pattern.pm)
- [../usr/share/PGenerator/command.pm](../usr/share/PGenerator/command.pm)
- [../usr/share/PGenerator/webui.pm](../usr/share/PGenerator/webui.pm)
- [../usr/sbin/pgeneratord_10bit.c](../usr/sbin/pgeneratord_10bit.c)
- [../usr/lib/drm_override.c](../usr/lib/drm_override.c)
- [../README.md](../README.md)

### Requested PDF

- [../../avsforum.pdf](../../avsforum.pdf)
