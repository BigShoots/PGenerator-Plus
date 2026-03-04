## Plan: Revert Bit Depth to Automatic (Original Behavior)

**TL;DR**: Remove manual bit depth control from the web UI and revert to the original PGenerator behavior: always start at 8-bit, and let calibration software (ColourSpace via BITD command or calman via upcgi) switch to 10-bit automatically when needed. The `max_bpc` config key remains functional — it's just no longer user-configurable from the web UI. Protocol commands (BITD, DSMD, HDR_ENABLE, CONF_HDR) continue to work so calibration software can drive bit depth changes. The docx explicitly states: *"There is no option to select the output Bit Depth within the template. This is a conscious decision."*

**Steps**
First restore the previous commit before all the extra work was done to make 10bit work, this was unecessary as the original version already had the ability to go into 10bit output, we werejust not understating it correctly. Then remove the bit depth dropdown and all related JS logic from the web UI, and ensure the backend always starts in 8-bit mode and only switches to 10-bit when BITD:10 is received from ColourSpace or when calma/hcfr explicitly set 10-bit via DSMD/HDR_ENABLE or send a 10bit signal. Calman will send 10bit when set to hdr. Adding calman support is new and not in the original version. The original version only switched to 10-bit when ColourSpace sent the BITD:10 command. This change adds the ability for Calman to also trigger 10-bit mode via DSMD/HDR_ENABLE commands, which set `max_bpc` for HDMI signaling but do not change pattern precision (bits_default remains 8). Only the BITD command changes both HDMI link depth and pattern precision. I want the pattern precision to be 10 bit when calman sends 10bit signal.

1. **Remove HTML dropdown** — In [webui.pm](usr/share/PGenerator/webui.pm#L1049-L1057), delete the entire `<div class="field">` block containing the `<select id="max_bpc">` element (Bit Depth label + 8/10/12 options).

2. **Remove `max_bpc` from JS `loadConfig()`** — In [webui.pm L1345](usr/share/PGenerator/webui.pm#L1345), remove the `setVal('max_bpc', ...)` line so loading config doesn't try to populate a now-deleted dropdown.

3. **Remove `max_bpc` from JS `captureSettings()`** — In [webui.pm L1368](usr/share/PGenerator/webui.pm#L1368), remove `max_bpc:getVal('max_bpc')` from the settings snapshot object.

4. **Remove `max_bpc` from JS change listener arrays** — In [webui.pm L1397](usr/share/PGenerator/webui.pm#L1397) and [L1404](usr/share/PGenerator/webui.pm#L1404), remove `'max_bpc'` from the arrays that trigger `checkSettingsChanged` and `updateDropdowns`.

5. **Simplify `getValidFormats()` / `getValidBpc()` / `updateDropdowns()`** — In [webui.pm L1432–L1555](usr/share/PGenerator/webui.pm#L1432-L1555):
   - Remove the `getValidBpc()` function entirely (no longer needed).
   - In `getValidFormats()`, remove the `bpc` parameter; hardcode `bpc=8` internally for bandwidth/deep-color calculations since bit depth is always auto.
   - In `updateDropdowns()`, remove all bpc-filtering logic (the block at [L1541–1549](usr/share/PGenerator/webui.pm#L1541-L1549) that disables/hides invalid bit depths). Keep color format filtering intact.

6. **Remove `max_bpc` from JS `resetDefaults()`** — In [webui.pm L1723](usr/share/PGenerator/webui.pm#L1723), remove the `setVal('max_bpc','8')` line.

7. **Remove `max_bpc` from JS `applySettings()`** — In [webui.pm L1744](usr/share/PGenerator/webui.pm#L1744), remove `max_bpc:getVal('max_bpc')` from the `changes` object. This prevents the web UI from ever sending `max_bpc` to the backend.

8. **Remove `max_bpc` from Perl `%restart_keys` and dead code** — In [webui.pm L379–388](usr/share/PGenerator/webui.pm#L379-L388):
   - Remove `max_bpc` from the `%restart_keys` hash (web UI never sends it anymore).
   - Remove the dead `if(0) { $bits_default=... }` block and its comment.

9. **Force 8-bit on startup in `conf.pm`** — In [conf.pm L57–62](usr/share/PGenerator/conf.pm#L57-L62):
   - Replace the `bits_default = 10` promotion block with logic that resets `max_bpc` to `8` in config on every daemon start: call `sudo("SET_PGENERATOR_CONF","max_bpc","8")` and set `$pgenerator_conf{'max_bpc'} = "8"`.
   - Keep `$bits_default = 8` (its initial value from [variables.pm L164](usr/share/PGenerator/variables.pm#L164), unchanged).
   - This ensures the daemon always boots into 8-bit SDR mode regardless of what a previous ColourSpace session left in config.

10. **Sync `$bits_default` when BITD is received** — In [daemon.pm L588–596](usr/share/PGenerator/daemon.pm#L588-L596), after `$calman_save_setting->("max_bpc","$bitd_val")`, add `$bits_default = $bitd_val;`. This is the "automatic" behavior from the docx: when ColourSpace explicitly requests 10-bit via the BITD command, both the HDMI link depth and the pattern value precision change. Other protocol commands (DSMD, HDR_ENABLE, CONF_HDR) continue to set `max_bpc` for HDMI signaling without changing `$bits_default` — Calman and HCFR always send 8-bit values.

11. **Update `calman_save_setting` comment** — In [daemon.pm L335–337](usr/share/PGenerator/daemon.pm#L335-L337), update the comment to reflect the new behavior: `bits_default` is synced only by BITD, not by HDR/DSMD commands. Remove the misleading "EGL surface is always 8bpc" note since pgeneratord_10bit uses native 10-bit DRM dumb buffers.

12. **Reset `bits_default` on web UI output changes** — In the Perl `webui_apply_config` handler ([webui.pm L377–396](usr/share/PGenerator/webui.pm#L377-L396)), when a restart-triggering config change occurs from the web UI, force `$bits_default = 8` and `$pgenerator_conf{'max_bpc'} = "8"` (and persist to config). This matches the original docx behavior: *"Any change made to the output within the Template will force the output back to 8 bit."*

**Files changed (summary)**

| File | Change |
|------|--------|
| [webui.pm](usr/share/PGenerator/webui.pm) | Remove bit depth dropdown, all JS bpc logic, Perl restart_keys entry |
| [conf.pm](usr/share/PGenerator/conf.pm) | Reset max_bpc=8 on startup instead of promoting bits_default |
| [daemon.pm](usr/share/PGenerator/daemon.pm) | Sync bits_default on BITD; update comments |

**Files NOT changed**

| File | Why unchanged |
|------|---------------|
| [command.pm](usr/share/PGenerator/command.pm) | Renderer selection by `max_bpc` still works — protocol commands set it |
| [pattern.pm](usr/share/PGenerator/pattern.pm) | `BITS=$bits_default` in operations.txt still works correctly |
| [variables.pm](usr/share/PGenerator/variables.pm) | `$bits_default=8` default stays the same |
| [PGenerator.conf](etc/PGenerator/PGenerator.conf) | `max_bpc=8` default stays; value is now reset on each boot |

**Verification**

- Boot PGenerator → confirm web UI has no Bit Depth dropdown
- Boot PGenerator → check `/etc/PGenerator/PGenerator.conf` has `max_bpc=8`
- Connect with Calman → patterns render at 8-bit (BITS=8 in `/var/lib/PGenerator/operations.txt`)
- Connect with ColourSpace → send BITD:10 → confirm renderer switches to `pgeneratord_10bit` and BITS=10 in operations.txt
- Send BITD:8 → confirm back to legacy renderer and BITS=8
- Enable HDR via DSMD/HDR_ENABLE → confirm max_bpc=10 in config (HDMI link for metadata) but BITS=8 in operations.txt (Calman still 8-bit)
- Change color format in web UI while ColourSpace had set 10-bit → confirm it resets to 8-bit

**Decisions**
- **Protocol commands kept**: BITD, DSMD, HDR_ENABLE, CONF_HDR still work — only web UI control removed
- **BITD syncs bits_default**: Only the explicit BITD command changes pattern precision; HDR/DSMD commands only change HDMI link depth
- **Startup always 8-bit**: max_bpc reset to 8 on every daemon start
- **Web UI output changes reset to 8-bit**: Matches original docx behavior
