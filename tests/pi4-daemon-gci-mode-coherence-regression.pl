#!/usr/bin/env perl
# Regression test: daemon.pm GCI gate and mode-coherence enforcement.
#
# The bug: when the Calman GCI control plane (UPGCI 2.0, established
# by INIT:2.0) sends a mode-transition command (HDR_ENABLE,
# CONF_HDR, CONF_SDR, DSMD, EOTF), the gate at the top of
# $calman_save_setting allow-lists only primaries/eotf/is_hdr and
# suppresses Calman's saves of the mode-coupled keys (signal_mode,
# is_sdr, colorimetry, dv_status, is_ll_dovi, is_std_dovi). Without
# a daemon-derived coherence update, the conf is left incoherent
# (is_hdr=1, eotf=2 with signal_mode=sdr, is_sdr=1, colorimetry=2).
# drm_override.so then reads the stale colorimetry=2 from the conf
# and rewrites the renderer's correct wire colorimetry (10) back to
# 2 on every atomic commit, so the LG C2 reports BT.709 instead of
# BT.2020.
#
# The fix: $calman_enforce_mode_coherence recomputes the mode-coupled
# keys from the post-save conf (eotf, primaries, is_hdr) and writes
# them via &sudo directly (a daemon write, not a Calman write, so the
# gate is bypassed). Preference keys (rgb_quant_range, max_bpc,
# color_format, min_luma, max_luma, max_cll, max_fall) are NOT
# touched and remain strictly WebUI-owned; Calman's writes of them
# stay suppressed.
#
# Source-only test, no live daemon required.
use strict;
use warnings;
use Test::More;

my $daemon = 'usr/share/PGenerator/daemon.pm';
open(my $fh, '<', $daemon) or BAIL_OUT("can't read $daemon: $!");
local $/; my $src = <$fh>; close $fh;

# 1. The GCI gate is still in place (fbee7ac3 restoration must be
#    preserved) and the allow-list is exactly {primaries, eotf, is_hdr}.
like($src,
  qr/if\(\$calman_gci\{\$connection\}\s*&&\s*\$conf_key\s*ne\s*"primaries"\s*&&\s*\$conf_key\s*ne\s*"eotf"\s*&&\s*\$conf_key\s*ne\s*"is_hdr"\)/,
  'GCI gate still allow-lists only primaries, eotf, is_hdr');

# 2. The gate still suppresses preference keys (rgb_quant_range,
#    max_bpc, color_format, min_luma, max_luma, max_cll, max_fall)
#    when written by Calman GCI — this is the deliberate fbee7ac3
#    behavior that the coherence fix must NOT bypass.
like($src,
  qr/Calman GCI:\s*suppressed save\s+\$conf_key=\$conf_val\s+\(WebUI owns this key\)/,
  'gate still logs "WebUI owns this key" suppression');

# 3. The coherence helper exists.
like($src,
  qr/my\s+\$calman_enforce_mode_coherence\s*=\s*sub\s*\{/,
  '$calman_enforce_mode_coherence helper is defined');
like($src,
  qr/Calman GCI:\s*coherence update\s+\$k=\$v\s+\(WebUI-owned, but mode transition implied it\)/,
  'coherence helper logs daemon-derived updates with the documented message');
like($src,
  qr/Calman GCI:\s*signal-mode coherence enforced\s*\(eotf=/,
  'coherence helper logs the final summary with eotf/primaries/is_hdr');

# 4. The coherence writes go through &sudo directly (daemon write,
#    not a Calman write that would re-hit the gate). This is the key
#    invariant: the helper must call &sudo("SET_PGENERATOR_CONF",...)
#    and update $pgenerator_conf{...} in-place, NOT funnel through
#    $calman_save_setting.
like($src,
  qr/sub\s*\{\s*[\s\S]{0,3000}?\&sudo\("SET_PGENERATOR_CONF",\$k,\$v\)[\s\S]{0,500}?\$pgenerator_conf\{\$k\}="\$v"/,
  'coherence helper writes via &sudo and updates $pgenerator_conf in-place (not via calman_save_setting)');

# 5. The trigger is fired from $calman_save_setting when the gate
#    let through a mode-affecting key (eotf, is_hdr, primaries).
like($src,
  qr/\$calman_enforce_mode_coherence->\(\)\s*if\(\$calman_gci\{\$connection\}\s*&&[\s\S]{0,200}?\$conf_key\s*eq\s*"eotf"[\s\S]{0,200}?\$conf_key\s*eq\s*"is_hdr"[\s\S]{0,200}?\$conf_key\s*eq\s*"primaries"/,
  'calman_save_setting triggers coherence on eotf/is_hdr/primaries under GCI');

# 6. The coherence update is gated on $calman_gci{$connection} — it
#    must NOT run for the Calman RPC path or WebUI saves (those set
#    the mode-coupled keys directly already, or via the WebUI
#    preference path). The helper's first line is a guard.
like($src,
  qr/my\s+\$calman_enforce_mode_coherence\s*=\s*sub\s*\{\s*return\s+if\(\!\$calman_gci\{\$connection\}\)/,
  'coherence helper is a no-op when GCI is not active on this connection');

# 7. The coherence rule: colorimetry=9 when eotf>=2 (and primaries!=0),
#    colorimetry=2 otherwise. This must mirror the existing
#    calman_set_non_dv_mode helper (daemon.pm ~line 1244).
like($src,
  qr/my\s+\$want_colorimetry=\(\$eotf_val\s*>=\s*2\)\s*\?\s*\(?\(\$prim_val\s*==\s*0\)\s*\?\s*"2"\s*:\s*"9"\)\s*:\s*"2"/,
  'coherence helper colorimetry rule matches calman_set_non_dv_mode (9 if eotf>=2 and prim!=0, else 2)');

# 8. The coherence rule: signal_mode derived from eotf.
like($src,
  qr/\$want_signal_mode=\(\$eotf_val\s*==\s*3\)\s*\?\s*"hlg"\s*:\s*"hdr10"\s*if\(\$eotf_val\s*>=\s*2\)/,
  'coherence helper signal_mode rule: hlg for eotf=3, hdr10 for eotf=2, sdr for eotf<2');

# 9. DV keys (dv_status, is_ll_dovi, is_std_dovi) are reset to 0 on a
#    non-DV transition (the transition IMPLIES dv_status=0). On a DV
#    transition the coherence helper writes dv_status=1 and the
#    standard-transport DV flags as daemon-derived updates, so the
#    GCI gate does not silently drop the DV enable and leave the
#    renderer in HDR10 mode.
like($src,
  qr/if\(\$calman_dv_transition_active\)\s*\{[\s\S]{0,400}?push\s+\@coherence_writes,\["dv_status","1"\]/,
  'coherence helper writes dv_status=1 during a DV transition');
like($src,
  qr/if\(\$calman_dv_transition_active\)[\s\S]{0,500}?push\s+\@coherence_writes,\["is_std_dovi","1"\]/,
  'coherence helper writes is_std_dovi=1 during a DV transition (standard transport)');
like($src,
  qr/if\(\$non_dv\)\s*\{[\s\S]{0,200}?push\s+\@coherence_writes,\["dv_status","0"\]/,
  'coherence helper resets dv_status=0 on non-DV transitions');
like($src,
  qr/push\s+\@coherence_writes,\["is_ll_dovi","0"\]/,
  'coherence helper resets is_ll_dovi=0');
like($src,
  qr/push\s+\@coherence_writes,\["is_std_dovi","0"\]/,
  'coherence helper resets is_std_dovi=0');

# 9b. The DV transition flag is declared and managed by
#     calman_set_dv_rgb.
like($src, qr/my\s+\$calman_dv_transition_active\s*=\s*0\b/,
  '$calman_dv_transition_active flag is declared');
like($src,
  qr/\$calman_dv_transition_active\s*=\s*1\s*;[\s\S]{0,200}?\$calman_save_setting->\(\s*"is_hdr"/,
  'calman_set_dv_rgb sets the DV transition flag before its saves');
like($src,
  qr/\$calman_save_setting->\(\s*"dv_metadata"[\s\S]{0,300}?\$calman_dv_transition_active\s*=\s*0\b/,
  'calman_set_dv_rgb clears the DV transition flag at the end');

# 9c. calman_force_dv_rgb (called from $calman_apply when dv is
#     already active) must also set the flag, otherwise its
#     re-application of is_hdr/eotf/primaries would re-trigger
#     coherence with the flag cleared and reset dv_status back to 0.
like($src,
  qr/return\s+if\(\!\$calman_dv_active->\(\)\)\s*;[\s\S]{0,200}?\$calman_dv_transition_active\s*=\s*1\b/,
  'calman_force_dv_rgb sets the DV transition flag');
like($src,
  qr/apply_source_rgb_quant_range\("calman",2\)[\s\S]{0,200}?\$calman_dv_transition_active\s*=\s*0\b/,
  'calman_force_dv_rgb clears the DV transition flag at the end');

# 9d. The signal_mode entry in the coherence write list must reflect
#     the DV branch — set BEFORE the list is built, not after, so
#     the initial hdr10 entry doesn't win.
like($src,
  qr/if\(\$calman_dv_transition_active\)\s*\{\s*\$want_signal_mode\s*=\s*"dv"\s*;?\s*\}[\s\S]{0,200}?my\s+\@coherence_writes\s*=/,
  'coherence helper resolves want_signal_mode to "dv" before building the write list');

# 10. The preference keys (min_luma, max_luma, max_cll, max_fall,
#     rgb_quant_range, max_bpc, color_format) must NOT appear in
#     the coherence helper's @coherence_writes — they remain
#     WebUI-owned and Calman's writes of them stay suppressed.
my $coherence_block;
if($src =~ /my\s+\$calman_enforce_mode_coherence\s*=\s*sub\s*\{([\s\S]+?)\n\s*\};/m) {
 $coherence_block=$1;
} else { $coherence_block=""; }
for my $pref (qw(min_luma max_luma max_cll max_fall rgb_quant_range max_bpc color_format)) {
 unlike($coherence_block,
  qr/\["$pref",/,
  "coherence helper does not write preference key $pref (stays WebUI-owned)");
}

# 11. Mode-transition handlers must trigger $calman_apply so the
#     renderer restarts and the TV gets the new mode without waiting
#     for the next pattern. The user-visible symptom of skipping
#     this: WebUI and conf show the new mode, but the wire stays on
#     the old colorimetry until a pattern command forces a restart.
#     (a) HDR_ENABLE:True path
like($src,
  qr/if\(\$pattern_cmd\s*=~\/\^True\$\/i\)\s*\{[\s\S]{0,800}?\$calman_set_non_dv_mode->\(\s*"hdr"[\s\S]{0,400}?\$calman_apply->\(\)/,
  'HDR_ENABLE:True triggers calman_apply so the renderer restarts immediately');
#     (b) CONF_HDR path (apply at the end of the handler)
like($src,
  qr/Calman: CONF_HDR parsed[\s\S]{0,800}?\$calman_apply->\(\)/,
  'CONF_HDR handler triggers calman_apply at the end so wire updates');
#     (c) EOTF / HDR_EOTF path
like($src,
  qr/if\(\$type\s*eq\s*"EOTF"\s*\|\|\s*\$type\s*eq\s*"HDR_EOTF"\)\s*\{[\s\S]{0,600}?\$calman_apply->\(\)/,
  'EOTF/HDR_EOTF handler triggers calman_apply so wire updates');

done_testing();
