#!/usr/bin/env perl
# Test that the HDR10 autocal 26pt series step builder in webui.pm is
# range-aware (Full vs Limited 10-bit) so the 0% step lands on true black
# and the renderer receives codes that match the active transport.
#
# Pre-fix behavior: the $lg_hdr20_codes branch of $grey_code_for_stim used
# a hardcoded 8-bit Limited fallback `int(16 + stimulus*2.19 + 0.5)`
# clamped to [16, 235] and never emitted `input_max` on the step JSON.
# On HDR10 RGB 10-bit Full the 0% step therefore sent r=g=b=16 with
# input_max=255, which the renderer scaled to a visibly lifted gray
# (~1.6% in 10-bit Full terms) and which the chart then plotted as
# effectively 0.0 cd/m^2 next to a real black lift.
#
# HDR10 patches are always 10-bit per project convention (the renderer
# scales to 8-bit transports on the way out), so this test only needs
# to cover the (Full, Limited) range axis; bit depth is fixed at 10.
#
# This is a source-only test, no live renderer or meter required.
use strict;
use warnings;
use Test::More;

my $src_path = 'usr/share/PGenerator/webui.pm';
open(my $fh, '<', $src_path) or BAIL_OUT("can't read $src_path: $!");
local $/; my $src = <$fh>; close $fh;

# 1. The two 10-bit HDR code tables must be present and PQ-encoded.
# The 100% entry is the only one that is identical between Full and Limited
# in absolute terms -- both land on their respective max codes (1023 / 940).
# The 1.4% entry is the most diagnostic for range awareness: 76 (Limited)
# vs 14 (Full), a 62-code gap that is impossible from the 8-bit Limited
# fallback (which clamped to 19).
like($src, qr/"1\.4"=>14,"2"=>20,"2\.7"=>28/s,
  'hdr20 10-bit Full table present (1.4=>14, 2=>20, 2.7=>28)');
like($src, qr/"1\.4"=>76,"2"=>82,"2\.7"=>88/s,
  'hdr20 10-bit Limited table present (1.4=>76, 2=>82, 2.7=>88)');
like($src, qr/"100"=>1023/,
  'hdr20 10-bit Full: 100% tops at 1023 (true Full white)');
like($src, qr/"100"=>940/,
  'hdr20 10-bit Limited: 100% tops at 940 (legal Limited white)');

# 2. The old hardcoded 8-bit Limited fallback `int(16 + x*219 + 0.5)`
# inside the lg_hdr20_codes branch must NOT appear. The literal
# `int(16 + $stimulus_pct/100*219 + .5)` was the pre-fix formula.
# As of the pattern-insertion-mode-correct refactor the closure delegates
# to webui_grey_code_for_stimulus(), so the lg_hdr20_codes branch body
# lives in the helper. Match either the legacy in-closure form OR the
# helper (which preserves the same body).
my $hdr20_branch_re = qr/(?:if\(\$lg_hdr20_codes\)|hdr20_codes\)\s*\{\s*my\s+\%lg_hdr20_code)[^;]*?[\s\S]{0,3000}?(?:return\s+\$c|return\s+\(\$code,\$input_max\))/s;
my ($hdr20_body) = $src =~ /($hdr20_branch_re)/;
ok(defined $hdr20_body, 'hdr20 branch body found') or BAIL_OUT('hdr20 branch missing -- source refactored, update test');
ok(index($hdr20_body, 'int(16 + $stimulus_pct/100*219 + .5)') == -1,
   'hdr20 fallback no longer hardcodes int(16 + stimulus*2.19 + 0.5)');
ok(index($hdr20_body, '$c=16 if($c < 16)') == -1,
   'hdr20 fallback no longer clamps to 16 (8-bit Limited black)');
ok(index($hdr20_body, '$c=235 if($c > 235)') == -1,
   'hdr20 fallback no longer clamps to 235 (8-bit Limited white)');

# 3. The fallback must use the range-aware $lg_hdr20_min_code /
# $lg_hdr20_span_code variables so 0% resolves to the active range's
# black code (0 for Full, 64 for Limited) instead of 16.
like($hdr20_body, qr/\$lg_hdr20_active_table->\{\$slot_key\}/,
  'hdr20 fallback consults the active 10-bit table for in-table slots');
like($hdr20_body, qr/\$lg_hdr20_min_code\s*\+\s*\$stimulus_pct\/100\s*\*\s*\$lg_hdr20_span_code/s,
  'hdr20 fallback formula uses the range-aware min/span for 0% and out-of-table slots');
like($hdr20_body, qr/\$[cC]ode=\$lg_hdr20_min_code if\(\$[cC]ode\s*<\s*\$lg_hdr20_min_code\)/,
  'hdr20 fallback clamps to the active min (0 for Full, 64 for Limited)');
like($hdr20_body, qr/\$[cC]ode=\$lg_hdr20_min_code\s*\+\s*\$lg_hdr20_span_code\s+if\(\$[cC]ode\s*>\s*\$lg_hdr20_min_code\s*\+\s*\$lg_hdr20_span_code\)/,
  'hdr20 fallback clamps to the active max (1023 for Full, 940 for Limited)');

# 4. The hdr20 active-table selector must be range-aware. When
# $greyscale_patch_limited is false (Full), the Full table wins;
# when true (Limited), the Limited table wins; when neither HDR10
# branch is taken (SDR/colors), the original 8-bit Limited table is
# the safe default.
like($src, qr/my\s+\$lg_hdr20_active_table=\\%lg_hdr20_code;/,
  'lg_hdr20_active_table defaults to the 8-bit Limited table (SDR-safe)');
like($src, qr/\$lg_hdr20_active_table=\\%lg_hdr20_code_10bit_limited\s+if\(\$lg_hdr20_codes\)/,
  'lg_hdr20_active_table switches to 10-bit Limited for HDR10');
like($src, qr/\$lg_hdr20_active_table=\\%lg_hdr20_code_10bit_full\s+if\(\$lg_hdr20_codes\s*&&\s*!\$greyscale_patch_limited\)/,
  'lg_hdr20_active_table switches to 10-bit Full for HDR10 Full transport');

# 5. The range-derived min/span must reflect Full vs Limited:
#    Full  -> min=0,  span=1023
#    Limited -> min=64, span=876
like($src, qr/my\s+\$lg_hdr20_min_code=\(\$lg_hdr20_codes\s*&&\s*!\$greyscale_patch_limited\)\s*\?\s*0\s*:\s*64\s*;/,
  'lg_hdr20_min_code is 0 on Full, 64 on Limited');
like($src, qr/my\s+\$lg_hdr20_span_code=\(\$lg_hdr20_codes\s*&&\s*!\$greyscale_patch_limited\)\s*\?\s*1023\s*:\s*876\s*;/,
  'lg_hdr20_span_code is 1023 on Full, 876 on Limited');

# 6. input_max:1023 must be emitted on HDR10 26pt steps (project
# convention: HDR is always 10-bit; the renderer scales to 8-bit
# transports on the way out).
like($src, qr/\\"input_max\\":1023"\s+if\(\$lg_hdr20_codes\)/,
  'HDR10 26pt steps emit input_max:1023');

# 7. SDR must not be touched. The SDR autocal 26pt table must remain
# unchanged (still hardcoded 10-bit Limited 64..1023 regardless of
# the user's transport range) -- SDR range-awareness is a separate
# fix and explicitly out of scope for this commit.
like($src, qr/lg_autocal_26_code=\(\s*"2\.3"=>84,"3"=>92,"4"=>100,"5"=>108/s,
  'SDR autocal 26pt table still uses linear 10-bit Limited codes (untouched)');

# 8. The 8-bit Limited hdr20 table (the SDR-safe default) must remain
# PQ-encoded with the original 8-bit Limited values (1.4=>19 .. 100=>235).
# These are NOT linear; they are the 8-bit PQ-encoded values that
# match the JS METER_LG_GREY_HDR_AUTOCAL_CODES_8BIT_LIMITED table.
like($src, qr/"1\.4"=>19.*"100"=>235/s,
  'hdr20 8-bit Limited table: 1.4=>19 .. 100=>235 (PQ-encoded, unchanged)');

done_testing();
