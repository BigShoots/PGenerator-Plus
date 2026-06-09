#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;

sub read_text {
 my ($path)=@_;
 open(my $fh,'<',$path) or die "Failed to read $path: $!";
 local $/;
 return <$fh>;
}

my $helper=read_text('usr/sbin/pgenerator-lg');
my $webui=read_text('usr/share/PGenerator/webui.pm');
my $lg=read_text('usr/share/PGenerator/lg.pm');
my $rootfs_lg_path='tools/image-targets/pi4-biasi/rootfs/usr/share/PGenerator/lg.pm';
my $runtime_lg_path='usr/share/PGenerator/lg.pm';
my $rootfs_command_path='tools/image-targets/pi4-biasi/rootfs/usr/share/PGenerator/command.pm';
my $rootfs_lg=-f $rootfs_lg_path ? read_text($rootfs_lg_path) : undef;
my $rootfs_command=-f $rootfs_command_path ? 1 : 0;

# 1) The helper workflow accepts a trailing $reset_ddc_state
#    parameter. Pattern: capture the parameter list and verify the
#    new variable is in it.
like($helper,qr/my\s*\(\$ip,\$client_key,\$connect_timeout,\$tv_input,\$fallback_picture_mode,\$signal_mode,\$require_white_balance_reset,\$reset_ddc_state\)=@_/,'pgenerator-lg lg_picture_reset_workflow declares trailing $reset_ddc_state parameter');

# 2) The DDC write block is gated on $reset_ddc_state. The
#    unconditional 1D LUT upload + local file clear that lived at
#    1666-1676 is now inside an if($reset_ddc_state) branch.
like($helper,qr/if\(\$reset_ddc_state\)\s*\{[\s\S]{0,800}?&lg_ddc_1d_white_balance_set\(/,'pgenerator-lg DDC 1D LUT upload is gated on $reset_ddc_state');
like($helper,qr/\$reset_ddc_state\s*==\s*1\s*\?\s*1\s*:\s*0/s,'pgenerator-lg only requests a TV-side DDC reset when $reset_ddc_state == 1');

# 3) &lg_ddc_clear_state is called only inside the $reset_ddc_state
#    branch (i.e. the file delete is no longer unconditional).
unlike($helper,qr/^(&lg_ddc_clear_state\([^\n]*\);\s*)$/m,'pgenerator-lg no longer has an unconditional lg_ddc_clear_state call');
like($helper,qr/if\(\$reset_ddc_state\)\s*\{[\s\S]{0,1500}?&lg_ddc_clear_state\(/,'pgenerator-lg lg_ddc_clear_state is inside the $reset_ddc_state branch');

# 4) The WebUI route plumbs require_white_balance_reset through to
#    the helper, and adds reset_ddc_state so the helper knows
#    whether to run the DDC wipe.
like($lg,qr/reset_ddc_state\s*=>\s*\$payload->\Q{"require_white_balance_reset"}\E\s*\?\s*1\s*:\s*0/,'WebUI /api/lg/picture-settings/reset maps require_white_balance_reset to helper reset_ddc_state');

# 5) The DisplayCard front-end button now sends
#    require_white_balance_reset: false explicitly, matching the
#    TV-menu "Advanced Settings -> Reset" intent (no DDC wipe).
like($lg,qr/body:JSON\.stringify\(\{picture_mode:mode,signal_mode:signal,require_white_balance_reset:false\}\)/,'lgResetPictureMode() sends require_white_balance_reset:false');

# 6) The Auto Cal preflight still sends require_white_balance_reset:
#    true so the existing DDC-wipe behavior is preserved.
like($webui,qr/require_white_balance_reset:true/,'Auto Cal preflight still sends require_white_balance_reset:true');

# 7) Rootfs mirror parity: only when the runtime lg.pm is mirrored
#    to the rootfs overlay (and per the existing 3-way symmetry
#    convention from 2514fcd4, that happens only when command.pm is
#    also mirrored) do we require byte-identical files.
if(defined($rootfs_lg) && $rootfs_command) {
 is($rootfs_lg,read_text($runtime_lg_path),'Pi4 image rootfs lg.pm matches shared runtime lg.pm when command.pm is mirrored');
} else {
 diag('Rootfs lg.pm is not mirrored (or command.pm is not mirrored); skipping byte-identical parity assertion.');
}

done_testing();
