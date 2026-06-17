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

done_testing();
