#!/usr/bin/env perl
# Test that the calibration card (meterCard) exposes a Calman-style
# Low Light Handler gear menu that maps to what spotread actually
# supports, and that the setting flows end-to-end:
#
#   gear onchange -> meterSetLowLightHandler -> localStorage
#   page load     -> meterRestoreLowLightHandler -> gear
#   manual read   -> meterBuildManualReadPayload -> low_light field
#   series start  -> webui_meter_series_start parses low_light.mode
#   meter_series.sh launch -> env LOW_LIGHT_MODE=... prefix
#   meter_session.sh case   -> LOW_LIGHT_FLAGS -> SR_CMD
#
# Mode mapping (spotread has no direct integration-time control and
# maxes at 5-read averaging, so the dropdown covers what spotread
# actually supports, not Calman's xRite-SDK options):
#   off   -> (no flag, single long read)
#   a     -> -Y a   (2-read avg)
#   aa    -> -Y aa  (3-read avg)
#   aaa   -> -Y aaa (5-read avg)
#   x     -> -x     (high precision, longer integration)
#   x_a   -> -x -Y a
#   x_aa  -> -x -Y aa
#   x_aaa -> -x -Y aaa
#
# The trigger threshold (cd/m^2) is used at the calibration level
# (autocal, series read, single read) to decide whether to apply the
# mode. When the expected target luminance is below the trigger AND
# the handler is enabled, the mode is used; otherwise the default
# single-read path runs. This avoids a two-pass adaptive read.
#
# This is a source-only test, no live renderer or meter required.
use strict;
use warnings;
use Test::More;

my $webui = 'usr/share/PGenerator/webui.pm';
my $shell = 'usr/bin/meter_session.sh';
my $series_shell = 'usr/bin/meter_series.sh';

open(my $fh, '<', $webui) or BAIL_OUT("can't read $webui: $!");
local $/; my $src = <$fh>; close $fh;
open(my $sh, '<', $shell) or BAIL_OUT("can't read $shell: $!");
local $/; my $sh_src = <$sh>; close $sh;
open(my $sh2, '<', $series_shell) or BAIL_OUT("can't read $series_shell: $!");
local $/; my $series_src = <$sh2>; close $sh2;

# 1. The gear menu must be in the calibration card (meterCard, not
# the autocal card). The card title flips between "Test Patterns" and
# "Calibration" depending on meter connection.
like($src, qr/<div class="card span2 meter-patterns-only"[\s\S]{0,200}?id="meterCard">/s,
  'calibration card meterCard is present (id="meterCard", meter-patterns-only)');
like($src, qr/id="meterProfileLowLight"/s,
  'Low Light Handler is a flat section in the Meter Settings popover');
like($src, qr/<div class="meter-profile-section-title">Low Light Handler/s,
  'Low Light Handler section title present in the popover');

# 2. The gear popover must have all 8 mode options plus the trigger
# input with the 5.0 cd/m^2 default.
like($src, qr/<option value="off"[^>]*>Off\s+\(single read\)<\/option>/s,
  'mode dropdown has the "off" option');
like($src, qr/<option value="a"[^>]*>2\s+reads\s+\(a\)<\/option>/s,
  'mode dropdown has the "2 reads (a)" option');
like($src, qr/<option value="aa"[^>]*>3\s+reads\s+\(aa\)<\/option>/s,
  'mode dropdown has the "3 reads (aa)" option');
like($src, qr/<option value="aaa"[^>]*>5\s+reads\s+\(aaa\)<\/option>/s,
  'mode dropdown has the "5 reads (aaa)" option');
unlike($src, qr/id="meterLowLightHighPrecision"/s,
  'high precision checkbox removed (spotread -x = Yxy output, a no-op for precision)');
unlike($src, qr/<option value="x"[^>]*>/s,
  'no x* options remain in the Mode dropdown');
like($src, qr/id="meterLowLightTrigger"[^>]*value="5\.0"/s,
  'trigger defaults to 5.0 cd/m^2');

# 3. The gear must be registered with setupGear so the popover opens.
like($src, qr/meterProfile:setupGear\('meterProfileGear','meterProfileGearPopover'\)/s,
  'Meter Settings gear is registered with setupGear');

# 4. The JS helpers must exist with the right shape.
like($src, qr/function\s+meterSetLowLightHandler\s*\(\s*\)/s,
  'meterSetLowLightHandler() defined');
like($src, qr/function\s+meterRestoreLowLightHandler\s*\(\s*\)/s,
  'meterRestoreLowLightHandler() defined');
like($src, qr/function\s+meterLowLightFlags\s*\(\s*mode\s*\)/s,
  'meterLowLightFlags(mode) defined');
like($src, qr/const\s+METER_LOW_LIGHT_KEY\s*=\s*['"]pgen\.meter\.lowLight['"]/s,
  'localStorage key constant defined');

# 5. meterLowLightFlags must map every dropdown mode to the right
# spotread flag set, and 'off' / unknown must return '' (no flag).
like($src, qr/meterLowLightFlags[\s\S]{0,1500}?case\s+['"]a['"]:\s+return\s+['"]-Y a['"]/s,
  'meterLowLightFlags maps "a" to "-Y a"');
like($src, qr/meterLowLightFlags[\s\S]{0,1500}?case\s+['"]aa['"]:\s+return\s+['"]-Y aa['"]/s,
  'meterLowLightFlags maps "aa" to "-Y aa"');
like($src, qr/meterLowLightFlags[\s\S]{0,1500}?case\s+['"]aaa['"]:\s+return\s+['"]-Y aaa['"]/s,
  'meterLowLightFlags maps "aaa" to "-Y aaa"');
# High-precision (x / x_*) modes removed: spotread -x is the "Display Yxy
# instead of Lab" output flag (already always on in every read path), so
# these mappings were no-ops for measurement precision.
unlike($src, qr/meterLowLightFlags[\s\S]{0,1500}?case\s+['"]x['"]:/s,
  'meterLowLightFlags no longer maps the x / x_* high-precision modes');
like($src, qr/meterLowLightFlags[\s\S]{0,1500}?case\s+['"]off['"]:\s+return\s+['"]['"]/s,
  'meterLowLightFlags maps "off" to "" (no flag)');

# 6. The manual read payload must pass the low-light state through to
# the server. All reads (autocal, series read, single read) use this
# path via meterBuildManualReadPayload.
like($src, qr/meterBuildManualReadPayload[\s\S]{0,2000}?readPayload\.low_light\s*=/s,
  'meterBuildManualReadPayload sets readPayload.low_light');
# Normalization lives in meterLowLightReadState (the payload just attaches
# its result): mode is the base dropdown value (off/a/aa/aaa), trigger is numeric.
like($src, qr/function meterLowLightReadState[\s\S]{0,600}?mode:base/s,
  'read state returns the base mode (off/a/aa/aaa) in the payload object');
like($src, qr/function meterLowLightReadState[\s\S]{0,600}?trigger:Number\(trigger\.value\)/s,
  'read state returns a numeric trigger in the payload object');

# 7. The series start body parser must accept low_light.mode and reject
# invalid values (fall through to off).
like($src, qr/\$low_light_mode="";/s,
  'series start body parser declares $low_light_mode local');
like($src, qr/"low_light".*"mode".*a-z_/s,
  'series start body parses low_light.mode field');
like($src, qr/\$low_light_mode="off"\s*unless\(\$low_light_mode\s+eq\s+"off"\s*\|\|\s*\$low_light_mode\s+eq\s+"a"\s*\|\|\s*\$low_light_mode\s+eq\s+"aa"\s*\|\|\s*\$low_light_mode\s+eq\s+"aaa"\s*\|\|\s*\$low_light_mode\s+eq\s+"x"\s*\|\|\s*\$low_light_mode\s+eq\s+"x_a"\s*\|\|\s*\$low_light_mode\s+eq\s+"x_aa"\s*\|\|\s*\$low_light_mode\s+eq\s+"x_aaa"\)/s,
  'invalid low_light.mode values fall through to off');
# The unless-clause must be INSIDE the regex-match conditional, so an
# absent low_light field leaves $low_light_mode="" and the env-var
# prefix below stays empty (manual series read bodies don't carry
# low_light, and the legacy pre-handler command must remain unchanged).
like($src, qr/if\(\$body=~\/"low_light"[\s\S]{0,500}?"mode"[\s\S]{0,500}?unless\(\$low_light_mode\s+eq\s+"off"/s,
  'series start parser only validates low_light when the field is present (unless-clause is gated on the regex match)');

# 8. The meter_series.sh launch must pass $low_light_mode as a positional
# argument (not an env-var prefix, so the daemon's sudo NOPASSWD rule
# still matches and the launch does not stall). The pattern-insertion
# refactor appends two more positional "<code>:<input_max>" pairs after
# low_light_mode, so accept any trailing args before </dev/null.
like($src, qr/\/usr\/bin\/meter_series\.sh[^\n]*'\$low_light_mode'[^<]*<\/dev\/null/s,
  'series launch passes low_light_mode as a positional arg (not env prefix)');
unlike($src, qr/env LOW_LIGHT_MODE=/s,
  'series launch no longer uses an env-var prefix (keeps sudo NOPASSWD match)');

# 9. meter_session.sh must read LOW_LIGHT_MODE and build LOW_LIGHT_FLAGS
# via a case statement covering all 8 mode values + off.
like($sh_src, qr/case\s+"\$\{LOW_LIGHT_MODE:-off\}"\s+in/s,
  'meter_session.sh has the LOW_LIGHT_MODE case statement');
like($sh_src, qr/a\)\s+LOW_LIGHT_FLAGS="-Y a"\s*;;/s,
  'LOW_LIGHT_FLAGS case "a" sets "-Y a"');
like($sh_src, qr/aa\)\s+LOW_LIGHT_FLAGS="-Y aa"\s*;;/s,
  'LOW_LIGHT_FLAGS case "aa" sets "-Y aa"');
like($sh_src, qr/aaa\)\s+LOW_LIGHT_FLAGS="-Y aaa"\s*;;/s,
  'LOW_LIGHT_FLAGS case "aaa" sets "-Y aaa"');
like($sh_src, qr/x\)\s+LOW_LIGHT_FLAGS="-x"\s*;;/s,
  'LOW_LIGHT_FLAGS case "x" sets "-x"');
like($sh_src, qr/x_a\)\s+LOW_LIGHT_FLAGS="-x -Y a"\s*;;/s,
  'LOW_LIGHT_FLAGS case "x_a" sets "-x -Y a"');
like($sh_src, qr/x_aa\)\s+LOW_LIGHT_FLAGS="-x -Y aa"\s*;;/s,
  'LOW_LIGHT_FLAGS case "x_aa" sets "-x -Y aa"');
like($sh_src, qr/x_aaa\)\s+LOW_LIGHT_FLAGS="-x -Y aaa"\s*;;/s,
  'LOW_LIGHT_FLAGS case "x_aaa" sets "-x -Y aaa"');
like($sh_src, qr/off\|\*\)\s+LOW_LIGHT_FLAGS=""/s,
  'LOW_LIGHT_FLAGS case "off" sets "" (no flag)');

# 10. Both spotread invocation paths in meter_session.sh must append
# $LOW_LIGHT_FLAGS to the SR_CMD.
like($sh_src, qr/SR_CMD="\$SPOTREAD_BIN -e -y \$DISPLAY_TYPE -c \$PORT_NUM -x \$AVG_FLAG \$LOW_LIGHT_FLAGS"/s,
  'non-CCSS SR_CMD appends $LOW_LIGHT_FLAGS');
like($sh_src, qr/SR_CMD="\$SPOTREAD_BIN -e -y \$DISPLAY_TYPE -X '\$CCSS_FILE' -c \$PORT_NUM -x \$AVG_FLAG \$LOW_LIGHT_FLAGS"/s,
  'CCSS SR_CMD appends $LOW_LIGHT_FLAGS');

# 11. The old autocal card dropdown must be gone (a4415ed3 was on
# the wrong card; this commit moves it to the calibration card).
unlike($src, qr/meterAutoCalAveraging/s,
  'autocal-card dropdown id is gone');
unlike($src, qr/METER_AUTOCAL_AVERAGING_KEY/s,
  'autocal-card localStorage key is gone');
unlike($src, qr/function\s+meterSetAutoCalAveraging/s,
  'autocal-card setter is gone');
unlike($src, qr/function\s+meterRestoreAutoCalAveraging/s,
  'autocal-card restorer is gone');
unlike($src, qr/"meter_averaging"/s,
  'autocal-card meter_averaging field is gone');
unlike($src, qr/\$averaging_env/s,
  'autocal-card averaging_env prefix is gone');
unlike($src, qr/meterRestoreAutoCalAveraging\(\)/s,
  'autocal-card restore call is gone');

# 12. Prior-fix invariants must still hold. None of these commits'
# invariants should regress.
like($src, qr/"1\.4"=>14,"2"=>20,"2\.7"=>28/s,
  'hdr20 10-bit Full table still present (fc8ff80d invariant)');
like($src, qr/"1\.4"=>76,"2"=>82,"2\.7"=>88/s,
  'hdr20 10-bit Limited table still present (fc8ff80d invariant)');
like($sh_src, qr/METER_AVERAGING:-off/s,
  'spotread default is off (56c7019a invariant)');
like($src, qr/function\s+meterNormalizeOledBlackReading[\s\S]{0,2000}?return\s+meterNormalizeMeasuredReading\(/s,
  'meterNormalizeOledBlackReading is a pass-through (2306eb45 invariant)');
like($src, qr/function\s+meterDrawLiftedBlackLabel/s,
  'lifted-black chart label helper still present (4668e285 invariant)');

# 13. End-to-end wiring on the series-read path. The series start
# body builder at the /api/meter/series call site must attach
# low_light (via meterLowLightReadState), and meter_series.sh must
# consume LOW_LIGHT_MODE so the env var actually takes effect on
# the spotread invocation. Without these, the gear is silently
# dropped on the wire for manual series reads.
like($src, qr/function\s+meterLowLightReadState\s*\(\s*\)/s,
  'meterLowLightReadState helper is defined');
like($src, qr/meterLowLightReadState\(\)[\s\S]{0,200}?readPayload\.low_light=lowLight/s,
  'meterBuildManualReadPayload calls meterLowLightReadState and attaches the result');
# The series start fetch (the one that calls /api/meter/series) must
# read the gear state and attach it to the body literal.
like($src, qr/meterLowLightReadState\(\)[\s\S]{0,500}?_seriesBody\.low_light=_ll/s,
  'series start body attaches low_light from the gear state');
like($series_src, qr/case\s+"\${LOW_LIGHT_MODE:-off}"\s+in/s,
  'meter_series.sh has the LOW_LIGHT_MODE case statement (consumes the env var)');
like($series_src, qr/a\)\s+LOW_LIGHT_FLAGS="-Y a"\s*;;/s,
  'meter_series.sh case "a" sets "-Y a"');
like($series_src, qr/off\|\*\)\s+LOW_LIGHT_FLAGS=""/s,
  'meter_series.sh case "off" sets "" (no flag)');
like($series_src, qr/SR_CMD="\$SR_CMD \$LOW_LIGHT_FLAGS"/s,
  'meter_series.sh appends $LOW_LIGHT_FLAGS to $SR_CMD');

done_testing();
