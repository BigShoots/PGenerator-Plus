#!/usr/bin/env perl
# Test that the autocal card exposes a Low-light handler dropdown that
# controls the METER_AVERAGING env var exported to meter_session.sh
# without redeploying. The dropdown is the operator's per-run switch
# between the single long read (off, the project default) and 2/3/5-read
# averaging (a/aa/aaa) for noisy panels or low-IRE patches.
#
# Wiring chain:
#   dropdown onchange -> meterSetAutoCalAveraging -> localStorage
#   page load         -> meterRestoreAutoCalAveraging -> dropdown
#   autocal read      -> meterBuildManualReadPayload -> meter_averaging field
#   series start body -> webui_meter_series_start parses meter_averaging
#   meter_series.sh   -> env METER_AVERAGING=... prefix on the command
#   meter_session.sh   -> case ${METER_AVERAGING:-off} -> -Y flag
#
# This is a source-only test, no live renderer or meter required.
use strict;
use warnings;
use Test::More;

my $src_path = 'usr/share/PGenerator/webui.pm';
open(my $fh, '<', $src_path) or BAIL_OUT("can't read $src_path: $!");
local $/; my $src = <$fh>; close $fh;

# 1. The dropdown HTML must exist in the autocal card with all four
# options (off, a, aa, aaa) and the onchange handler.
like($src, qr/<select\s+id="meterAutoCalAveraging"[^>]*onchange="meterSetAutoCalAveraging\(this\.value\)"/s,
  'autocal card has a #meterAutoCalAveraging select with onchange handler');
like($src, qr/<option\s+value="off"[^>]*>Off\s+\(single read\)<\/option>/s,
  'dropdown has the "off (single read)" option');
like($src, qr/<option\s+value="a"[^>]*>2\s+reads\s+\(a\)<\/option>/s,
  'dropdown has the "2 reads (a)" option');
like($src, qr/<option\s+value="aa"[^>]*>3\s+reads\s+\(aa\)<\/option>/s,
  'dropdown has the "3 reads (aa)" option');
like($src, qr/<option\s+value="aaa"[^>]*>5\s+reads\s+\(aaa\)<\/option>/s,
  'dropdown has the "5 reads (aaa)" option');
like($src, qr/Low-light\s+handler/s,
  'dropdown is labeled "Low-light handler"');

# 2. The JS helpers must exist with the right shape.
like($src, qr/function\s+meterSetAutoCalAveraging\s*\(\s*value\s*\)/s,
  'meterSetAutoCalAveraging(value) defined');
like($src, qr/function\s+meterRestoreAutoCalAveraging\s*\(\s*\)/s,
  'meterRestoreAutoCalAveraging() defined');
like($src, qr/const\s+METER_AUTOCAL_AVERAGING_KEY\s*=\s*['"]pgen\.meter\.autocalAveraging['"]/s,
  'localStorage key constant defined');

# 3. meterSetAutoCalAveraging must validate the value (reject anything
# that is not off / a / aa / aaa) and persist to localStorage.
like($src, qr/meterSetAutoCalAveraging[\s\S]{0,400}?localStorage\.setItem\(\s*METER_AUTOCAL_AVERAGING_KEY/s,
  'meterSetAutoCalAveraging persists to localStorage');
like($src, qr/meterSetAutoCalAveraging[\s\S]{0,400}?v\s*!==\s*['"]off['"][\s\S]{0,200}?v\s*!==\s*['"]a['"][\s\S]{0,200}?v\s*!==\s*['"]aa['"][\s\S]{0,200}?v\s*!==\s*['"]aaa['"]/s,
  'meterSetAutoCalAveraging validates against off/a/aa/aaa');

# 4. meterRestoreAutoCalAveraging must read from localStorage and only
# set the dropdown if the saved value is one of the valid options.
like($src, qr/meterRestoreAutoCalAveraging[\s\S]{0,400}?localStorage\.getItem\(\s*METER_AUTOCAL_AVERAGING_KEY/s,
  'meterRestoreAutoCalAveraging reads from localStorage');
like($src, qr/meterRestoreAutoCalAveraging[\s\S]{0,600}?sel\.value\s*=\s*saved/s,
  'meterRestoreAutoCalAveraging assigns the saved value to the select');

# 5. The restore must be called on page load. The autocal config apply
# path is the right place (config has just been loaded from the server).
like($src, qr/meterSyncHdrMetadata\(\);[\s\S]{0,200}?meterRestoreAutoCalAveraging\(\)/s,
  'meterRestoreAutoCalAveraging is called during config apply (page load)');

# 6. meterBuildManualReadPayload must pass the dropdown value through to
# the server as meter_averaging so meter_session.sh exports the env var.
like($src, qr/meterBuildManualReadPayload[\s\S]{0,1500}?readPayload\.meter_averaging\s*=\s*String\(avgSel\.value\)/s,
  'meterBuildManualReadPayload forwards the dropdown as meter_averaging');

# 7. The series start body parser must accept meter_averaging and reject
# invalid values (fall through to off).
like($src, qr/\$meter_averaging="";/,
  'series start body parser declares $meter_averaging local');
like($src, qr/\$meter_averaging\s*=\s*"off"\s*unless\(\$meter_averaging\s+eq\s+"off"\s*\|\|\s*\$meter_averaging\s+eq\s+"a"\s*\|\|\s*\$meter_averaging\s+eq\s+"aa"\s*\|\|\s*\$meter_averaging\s+eq\s+"aaa"\)/s,
  'invalid meter_averaging values fall through to off');

# 8. The meter_series.sh launch must export METER_AVERAGING when the
# value is non-empty.
like($src, qr/averaging_env\s*=\s*"env METER_AVERAGING='\$meter_averaging' "[\s\S]{0,200}?if\(\$meter_averaging\s+ne\s+""\)/s,
  'meter_series.sh is launched with env METER_AVERAGING when set');
like($src, qr/setsid\s+sudo\s+\$averaging_env\/bin\/bash\s+\/usr\/bin\/meter_series\.sh/s,
  'averaging_env is interpolated into the setsid sudo bash command');

# 9. Prior-fix invariants must still hold.
like($src, qr/"1\.4"=>14,"2"=>20,"2\.7"=>28/s,
  'hdr20 10-bit Full table still present (fc8ff80d invariant)');
like($src, qr/function\s+meterNormalizeOledBlackReading[\s\S]{0,1000}?return\s+meterNormalizeMeasuredReading\(/s,
  'meterNormalizeOledBlackReading is a pass-through (2306eb45 invariant)');
like($src, qr/function\s+meterDrawLiftedBlackLabel/s,
  'lifted-black chart label helper still present (4668e285 invariant)');

done_testing();
