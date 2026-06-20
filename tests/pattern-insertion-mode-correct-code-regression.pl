#!/usr/bin/env perl
# Test that pattern insertion (patch_insert_*) computes the mode-correct
# code from the active output mode (SDR / HDR10 / DV / HLG) -- the SAME
# code the greyscale-series ladder emits for that stimulus.
#
# Pre-fix behavior:
#   - meter_series.sh's patch_insert_code_for_level() hardcoded a linear
#     (level/100)*255 formula and never consulted the output mode, so on
#     HDR/DV/HLG wires the insertion flash was either too dim (linear 8-bit
#     sent through PQ EOTF) or, on HDR10, off-mode (over-bright).
#   - meter_lg_autocal.pl's _patch_insert_code_for_level() branched on
#     signal_mode but interpreted the level as "% of max_luma nits"
#     (pq((level/100)*max_luma)), over-driving 25% to 250 nits on a
#     1000-nit panel and biasing the run.
#
# Fix: webui.pm is the single source of truth. It exposes
# webui_grey_code_for_stimulus() which reproduces the closure's exact
# stimulus->code mapping. webui_meter_series_start and
# webui_meter_lg_autocal_start precompute the insertion code via this
# helper and forward it to the worker, which just SENDS it.
#
# Source-only test, no live renderer / meter required.
use strict;
use warnings;
use Test::More;

# Substring-presence check: avoids regex variable-interpolation pitfalls
# (e.g. "${VAR}" inside a regex interpolates the current value of $VAR).
sub has_substr {
 my ($haystack, $needle) = @_;
 return index($haystack, $needle) != -1 ? 1 : 0;
}

my $root = $ENV{PGEN_REPO_ROOT} || '.';
my $webui_path = "$root/usr/share/PGenerator/webui.pm";
my $series_path = "$root/usr/bin/meter_series.sh";
my $autocal_path = "$root/usr/bin/meter_lg_autocal.pl";

open(my $fh, '<', $webui_path) or BAIL_OUT("can't read $webui_path: $!");
local $/; my $webui_src = <$fh>; close $fh;

open($fh, '<', $series_path) or BAIL_OUT("can't read $series_path: $!");
local $/; my $series_src = <$fh>; close $fh;

open($fh, '<', $autocal_path) or BAIL_OUT("can't read $autocal_path: $!");
local $/; my $autocal_src = <$fh>; close $fh;

# 1. The shared helper sub must exist and be documented as the single
# source of truth for stimulus->code.
ok(has_substr($webui_src, "sub webui_grey_code_for_stimulus ("),
  'webui.pm exposes webui_grey_code_for_stimulus helper');
ok(has_substr($webui_src, "Single source of truth for stimulus-percent"),
  'helper is documented as single source of truth for stimulus->code');

# 2. The closure must delegate to the helper so the series behavior is
# preserved AND the helper's output is used by both the series and the
# insertion paths.
ok(has_substr($webui_src, '&webui_grey_code_for_stimulus($stimulus_pct,$signal_mode,$target_gamma,$lim,$_opts_for_grey)'),
  '$grey_code_for_stim closure delegates to webui_grey_code_for_stimulus');

# 3. webui_meter_series_start must compute the precomputed insertion codes
# via the helper and pass them as the final positional args to meter_series.sh.
ok(has_substr($webui_src, 'webui_grey_code_for_stimulus($patch_insert_patch_level'),
  'series_start computes insert_patch_code via the helper');
ok(has_substr($webui_src, 'webui_grey_code_for_stimulus($patch_insert_time_level'),
  'series_start computes insert_time_code via the helper');
ok(has_substr($webui_src, q('${insert_patch_code}:${insert_patch_input_max}')),
  'series cmd passes precomputed patch code as a "code:input_max" pair');
ok(has_substr($webui_src, q('${insert_time_code}:${insert_time_input_max}')),
  'series cmd passes precomputed time code as a "code:input_max" pair');
# Pattern insertion applies to ANY series type, not just greyscale.
# The old `$type eq "greyscale"` gate would skip colors + other types;
# after the fix, the guard is only on the patch_insert flags themselves.
ok(!has_substr($webui_src, 'if($type eq "greyscale" && ($patch_insert_patch_enabled || $patch_insert_time_enabled))'),
  'series_start precomputes insert codes for any series type (no greyscale-only gate)');

# 4. webui_meter_lg_autocal_start must inject the precomputed codes into
# the config body before launching the worker.
ok(has_substr($webui_src, q("patch_insert_patch_code":$_ac_insert_patch_code)),
  'autocal_start injects patch_insert_patch_code into config body');
ok(has_substr($webui_src, q("patch_insert_patch_input_max":$_ac_insert_patch_input_max)),
  'autocal_start injects patch_insert_patch_input_max into config body');
ok(has_substr($webui_src, q("patch_insert_time_code":$_ac_insert_time_code)),
  'autocal_start injects patch_insert_time_code into config body');
ok(has_substr($webui_src, q("patch_insert_time_input_max":$_ac_insert_time_input_max)),
  'autocal_start injects patch_insert_time_input_max into config body');

# 5. meter_series.sh must read the two new positional args (29/30) and
# use them instead of its own linear formula.
ok(has_substr($series_src, 'PATCH_INSERT_PATCH_PRECOMPUTED="$'),
  'meter_series.sh reads arg 29 as PATCH_INSERT_PATCH_PRECOMPUTED');
ok(has_substr($series_src, 'PATCH_INSERT_TIME_PRECOMPUTED="$'),
  'meter_series.sh reads arg 30 as PATCH_INSERT_TIME_PRECOMPUTED');
# The two call sites for post_insert_patch must forward the precomputed
# payload as the 4th positional arg.
ok(has_substr($series_src, q(post_insert_patch "$PATCH_INSERT_TIME_LEVEL" "$PATCH_INSERT_TIME_DURATION_MS" "time" "$PATCH_INSERT_TIME_PRECOMPUTED")),
  'time-insertion call forwards the precomputed payload');
ok(has_substr($series_src, q(post_insert_patch "$PATCH_INSERT_PATCH_LEVEL" "$duration_ms" "patch" "$PATCH_INSERT_PATCH_PRECOMPUTED")),
  'patch-insertion call forwards the precomputed payload');
ok(has_substr($series_src, 'patch_insert_input_max_for_level'),
  'meter_series.sh derives input_max from the precomputed payload');

# 6. meter_lg_autocal.pl must use the precomputed code when present and
# preserve the legacy _patch_insert_code_for_level as a fallback.
ok(has_substr($autocal_src, 'defined($config->{$code_key}) && $config->{$code_key} ne ""'),
  'meter_lg_autocal.pl prefers the precomputed patch_insert_*_code from config');
ok(has_substr($autocal_src, '_patch_insert_code_for_level'),
  'legacy _patch_insert_code_for_level retained (used as fallback)');

# 7. The helper's documentation must explicitly cover SDR / HDR10 / DV / HLG.
for my $mode (qw(sdr hdr10 dv hlg)) {
 ok(has_substr($webui_src, $mode), "helper documentation/source mentions $mode mode");
}

# 8. The hdr20 10-bit tables in the helper must remain PQ-encoded so
# insertion patches match the series for hdr10 26pt runs. Spot-check the
# 20% entry (10-bit Full: 205, Limited: 239; pre-fix linear would be
# 20/20). Linear values would be 20, which is way below the 1.4% slot.
ok(has_substr($webui_src, q("20"=>205)), 'hdr20 10-bit Full table: 20% is PQ-encoded (205)');
ok(has_substr($webui_src, q("20"=>239)), 'hdr20 10-bit Limited table: 20% is PQ-encoded (239)');

# 9. The precomputed payload uses the colon-joined "code:input_max" format
# so the daemon's sudo NOPASSWD "/usr/bin/meter_series.sh *" arg-count
# stays small. The worker splits on the colon.
ok(has_substr($series_src, q([[ -n "$precomputed" && "$precomputed" == *:* ]])),
  'meter_series.sh splits the precomputed payload on ":"');

done_testing();