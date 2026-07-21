#!/usr/bin/env perl
# Meter Settings gear pane: a gear next to the meter dropdown opens a
# popover ("Meter Settings") that consolidates Meter Delay, Refresh Rate,
# and a flattened Low Light Handler. Meter Profile stays in the header.
# Source-only test; no live renderer or meter required.
use strict; use warnings; use Test::More;
my $webui='usr/share/PGenerator/webui.pm';
open(my $fh,'<',$webui) or BAIL_OUT("can't read $webui: $!");
local $/; my $src=<$fh>; close $fh;

# Task 1: gear + popover scaffold in the meter header, wired via setupGear.
like($src, qr/<div class="meter-card-header-meter">[\s\S]{0,1200}?id="meterProfileGear"/s,
  'meter header has the Meter Settings gear button');
like($src, qr/id="meterProfileGearPopover"[^>]*class="meter-xyz-gear-popover"|class="meter-xyz-gear-popover"[^>]*id="meterProfileGearPopover"/s,
  'gear popover uses the shared popover class');
like($src, qr/<div class="meter-profile-title">Meter Settings<\/div>/s,
  'popover is titled "Meter Settings"');
like($src, qr/id="meterProfileRelocSlot"/s, 'popover has the relocation slot container');
like($src, qr/meterProfile:setupGear\('meterProfileGear','meterProfileGearPopover'\)/s,
  'gear is registered with setupGear');
like($src, qr/#meterProfileGearPopover\{[^}]*max-height/s, 'popover has a max-height so it never overflows');

# Task 2: profile stays beside Display Type; timing controls relocate.
like($src, qr/function meterRelocateProfileControls\(\)/s,
  'relocation function is defined');
like($src, qr/meter-card-header-col-display[\s\S]{0,1800}?id="meterProfileHeaderCol"[\s\S]{0,500}?id="meterCcssProfile"/s,
  'Meter Profile is directly right of Display Type in the header');
like($src, qr/meterRelocateProfileControls[\s\S]{0,400}?getElementById\('meterProfileHeaderCol'\)/s,
  'runtime relocation keeps Meter Profile in its header column');
like($src, qr/meterRelocateProfileControls[\s\S]{0,800}?getElementById\('meterDelay'\)/s,
  'relocation moves the Meter Delay field');
like($src, qr/meterRelocateProfileControls[\s\S]{0,800}?getElementById\('meterRefreshRate'\)/s,
  'relocation moves the Refresh Rate field');
like($src, qr/meterRelocateProfileControls\(\);/s, 'relocation is invoked at init');
unlike($src, qr/id="meterProfileDisplayField"/s,
  'Meter Settings popover no longer contains the profile field');

# Task 3: Low Light Handler is a flat section in the popover, nested gear gone.
like($src, qr/id="meterProfileLowLight"/s, 'flat Low Light Handler section is in the popover');
like($src, qr/<input type="checkbox" id="meterLowLightEnabled" onchange="meterSetLowLightHandler\(\)">/s,
  'single Enabled checkbox persists on change');
unlike($src, qr/meterLowLightHighPrecision/s, 'high precision checkbox + JS refs removed (mapped to -x = Yxy output, a no-op for precision)');
unlike($src, qr/id="meterLowLightToggleWrap"/s, 'old low-light toggle row is gone');
unlike($src, qr/id="meterLowLightGear"/s, 'nested low-light gear button is gone');
unlike($src, qr/id="meterLowLightGearPopover"/s, 'nested low-light gear popover is gone');
unlike($src, qr/id="meterLowLightEnabledGear"/s, 'duplicate gear Enabled checkbox is gone');
unlike($src, qr/lowLight:setupGear/s, 'gears object no longer registers the nested low-light gear');
# Scope the Calman check to the low-light feature only: pre-existing
# unrelated refs (e.g. meterAutoCalHdrCalmanReset, HDR autocal comments)
# are out of scope for this work and must not be renamed here.
my ($ll_section) = $src =~ /(id="meterProfileLowLight"[\s\S]{0,1800})/;
unlike($ll_section // '', qr/Calman/, 'new low-light popover section has no Calman wording');
unlike($src, qr/Calman-style low-light/, 'low-light "Calman-style" comments scrubbed');

# Task 4: high precision control removed. It mapped to spotread -x, which
# is the "Display Yxy instead of Lab" output flag (already always on in every
# read path), so it never changed measurement precision. The low-light
# read-state no longer composes the x_<mode> variants, and highPrecision is
# no longer persisted.
unlike($src, qr/meterLowLightReadState[\s\S]{0,500}?'x_'\s*\+/s,
  'read-state no longer composes x_<mode>');
unlike($src, qr/highPrecision/s,
  'highPrecision no longer persisted/restored by the low-light handler');

# Task 5: measured target levels are visibly blank and cannot be edited,
# including after Display Type changes apply new black-level defaults.
like($src, qr/id="meterTargetWhite"[^>]*disabled/s,
  'Target White starts disabled while Use Measured is selected');
like($src, qr/id="meterTargetBlack"[^>]*disabled/s,
  'Target Black starts disabled while Use Measured is selected');
unlike($src, qr/id="meterTarget(?:White|Black)"[^>]*placeholder="auto"/s,
  'measured Target White and Target Black start blank');
like($src, qr/function meterApplyTargetLevelsDisplayDefaults[\s\S]{0,1800}?meterSetTargetLevelsStateOnly\(\)/s,
  'Display Type defaults resynchronize target input disabled state');

done_testing();
