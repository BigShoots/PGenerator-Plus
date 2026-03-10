# Calman Pi Behavior

This note documents the Calman / UPGCI behavior that has been validated against the real Raspberry Pi daemon in `usr/share/PGenerator/daemon.pm`.

It is intentionally focused on the production Pi path, not the Android reference implementation.

---

## Ports and framing

### UPGCI (`2100`)
- TCP server on port `2100`
- Calman commands are framed with `STX` (`0x02`) and `ETX` (`0x03`)
- Responses are a single `ACK` (`0x06`)

### RPC (`2101`)
- TCP server on port `2101`
- Commands are accepted as raw text without STX/ETX framing
- `CAP`, `STATUS`, `FIRMWARE`, `SN`, and `GET_SETTINGS` return real payloads on this socket
- `CommandRGB` works on RPC using the same parsing logic as the framed UPGCI path

---

## Session state

Calman state is intentionally reset on:
- `INIT`
- `TERM`
- `QUIT`
- `SHUTDOWN`
- socket disconnect

Reset state:
- `APL target = 18`
- `APL enabled = 0`
- `background = 0,0,0`
- `window size = 10`

This prevents stale APL or manual surround settings from leaking into the next Calman session.

---

## Pattern command behavior on the Pi

### `RGB_S:r,g,b,size`
Direct window-size command.

Behavior:
- foreground RGB is scaled to the current HDMI output bit depth
- the 4th field is treated as the window percentage
- this path does **not** inject computed APL backgrounds
- the active manual background is used as-is (normally black after `INIT`)

This matches the real Pi behavior needed for ordinary fixed-size Calman windows.

### Example
Input:
- `RGB_S:0460,0460,0460,010`

Observed result:
- 10% window
- `RGB=460,460,460`
- `BG=0,0,0`

---

### `RGB_A:r,g,b,bg_r,bg_g,bg_b,size`
Explicit full-pattern command.

Behavior:
- foreground RGB is scaled to the current HDMI output bit depth
- background RGB is taken directly from fields 4-6
- the final field is treated as the window percentage
- this path is used to honor explicit Calman surrounds exactly as sent

This is important because current Calman builds have been observed sending `RGB_A` for real window/APL selections on the Pi instead of relying only on `10_SIZE` / `11_APL` / `CommandRGB`.

### Example
Input:
- `RGB_A:0460,0460,0460,0195,0195,0195,0010`

Observed result:
- 10% window
- `RGB=460,460,460`
- `BG=195,195,195`

---

### `RGB_B:r,g,b,bg`
Manual gray-surround command.

Behavior:
- foreground RGB is scaled to the current HDMI output bit depth
- the 4th field is treated as a gray background level
- computed APL is disabled when this command is used
- the stored manual background is then used for subsequent direct window commands until reset/disconnect

---

### `10_SIZE:value`
Stores the custom window size for later use.

Behavior:
- clamped to `1..100`
- primarily used by `CommandRGB(...,999)`

---

### `11_APL:value`
Stores the custom APL target.

Behavior:
- clamped to `0..100`
- enables computed APL mode
- primarily used by `CommandRGB(...,999)`

---

### `CommandRGB:r,g,b,tenBit,sizeToken`
Implements the G1-style window token behavior.

Supported size-token semantics:
- `1..100` = direct window size, no computed APL
- `101..998` = preset constant APL mode where `APL = token - 100` and window size is fixed at `10%`
- `999` = custom mode using stored `10_SIZE` and `11_APL`

### Example
RPC input:
- `CommandRGB:460,460,460,1,118`

Observed result:
- interpreted as preset `APL 18`
- fixed `10%` window
- computed background `BG=195,195,195` on the tested Pi configuration

---

## Why `RGB_A` matters

Real Calman traffic captured from the Raspberry Pi showed that the live UI does not always use `CommandRGB`, `10_SIZE`, and `11_APL` for window/APL selections.

Observed commands included:
- `RGB_S:0256,0256,0256,100`
- `RGB_S:0102,0102,0102,100`
- `RGB_S:0460,0460,0460,010`
- `RGB_A:0460,0460,0460,0195,0195,0195,0010`
- `RGB_A:0460,0460,0460,0205,0205,0205,0010`

Because of that, honoring explicit 7-field `RGB_A` payloads on the Pi is required for the “real deal” Calman behavior.

---

## Validation summary

The current Pi daemon has been validated to:
- keep 10-bit Calman values at native precision when output is 10bpc
- handle both framed UPGCI (`2100`) and raw RPC (`2101`) Calman paths
- avoid stale APL state between sessions
- treat `RGB_S` as a direct fixed-window path
- honor explicit `RGB_A` foreground/background/window payloads
- keep G1-style `CommandRGB` size-token APL behavior available for RPC / SetControl style clients
