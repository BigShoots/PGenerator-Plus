#!/usr/bin/env perl
# Meter Settings gear pane: a gear next to the meter dropdown opens a
# popover ("Meter Settings") that consolidates Meter Profile (display
# type), Meter Delay, Refresh Rate, and a flattened Low Light Handler.
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
like($src, qr/id="meterProfileDisplayField"/s, 'popover has the display/profile field container');
like($src, qr/id="meterProfileRelocSlot"/s, 'popover has the relocation slot container');
like($src, qr/meterProfile:setupGear\('meterProfileGear','meterProfileGearPopover'\)/s,
  'gear is registered with setupGear');
like($src, qr/#meterProfileGearPopover\{[^}]*max-height/s, 'popover has a max-height so it never overflows');

# Task 2: existing controls relocate into the popover at runtime.
like($src, qr/function meterRelocateProfileControls\(\)/s,
  'relocation function is defined');
like($src, qr/meterRelocateProfileControls[\s\S]{0,600}?getElementById\('meterDisplayType'\)/s,
  'relocation moves the display-type select');
like($src, qr/meterRelocateProfileControls[\s\S]{0,600}?getElementById\('customCcssPanel'\)/s,
  'relocation moves the CCSS panel');
like($src, qr/meterRelocateProfileControls[\s\S]{0,800}?getElementById\('meterDelay'\)/s,
  'relocation moves the Meter Delay field');
like($src, qr/meterRelocateProfileControls[\s\S]{0,800}?getElementById\('meterRefreshRate'\)/s,
  'relocation moves the Refresh Rate field');
like($src, qr/meterRelocateProfileControls\(\);/s, 'relocation is invoked at init');
unlike($src, qr/<label>Display Type<\/label>/s,
  'old inline "Display Type" label is removed (now "Meter Profile" in the popover)');

# Task 3: Low Light Handler is a flat section in the popover, nested gear gone.
like($src, qr/id="meterProfileLowLight"/s, 'flat Low Light Handler section is in the popover');
like($src, qr/<input type="checkbox" id="meterLowLightEnabled" onchange="meterSetLowLightHandler\(\)">/s,
  'single Enabled checkbox persists on change');
like($src, qr/<input type="checkbox" id="meterLowLightHighPrecision"/s, 'High precision checkbox present');
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

# Task 4: high precision checkbox composes the effective mode + persists.
like($src, qr/function meterLowLightReadState[\s\S]{0,400}?meterLowLightHighPrecision/s,
  'read-state reads the high precision checkbox');
like($src, qr/meterLowLightReadState[\s\S]{0,500}?'x_'\s*\+/s,
  'read-state composes x_<mode> when high precision is on');
like($src, qr/function meterSetLowLightHandler[\s\S]{0,500}?highPrecision/s,
  'set-handler persists highPrecision to localStorage');
like($src, qr/function meterRestoreLowLightHandler[\s\S]{0,800}?highPrecision/s,
  'restore reads highPrecision back');

done_testing();
