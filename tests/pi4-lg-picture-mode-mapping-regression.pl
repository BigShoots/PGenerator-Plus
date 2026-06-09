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

my $command=read_text('usr/share/PGenerator/command.pm');
my $rootfs_command=read_text('tools/image-targets/pi4-biasi/rootfs/usr/share/PGenerator/command.pm');
my $helper=read_text('usr/sbin/pgenerator-lg');
my $webui=read_text('usr/share/PGenerator/webui.pm');
my $lg=read_text('usr/share/PGenerator/lg.pm');

# Mirror must stay in sync with shared runtime command.pm so the
# Pi4 image build ships the same picture-mode mapping the live
# runtime uses. (Same contract as pi4-hdr-ycbcr-colorimetry-
# regression.pl.)
is($rootfs_command,$command,'Pi4 image rootfs command.pm matches shared runtime command.pm');

# The shared helper function exists in both the runtime module
# and the long-running helper binary. The runtime copy is the
# one that the WebUI actually exercises.
like($command,qr/sub map_picture_mode_label_to_ddc_name\(@\)/,'shared command.pm declares map_picture_mode_label_to_ddc_name');
like($helper,qr/sub map_picture_mode_label_to_ddc_name \(\@\)/,'pgenerator-lg declares map_picture_mode_label_to_ddc_name');

# Signal-mode-aware companion helpers exist in both copies.
like($command,qr/sub lg_picture_mode_signal_for_canonical_name\(@\)/,'shared command.pm declares lg_picture_mode_signal_for_canonical_name');
like($command,qr/sub lg_picture_mode_signal_compatible\(@\)/,'shared command.pm declares lg_picture_mode_signal_compatible');
like($helper,qr/sub lg_picture_mode_signal_for_canonical_name \(\@\)/,'pgenerator-lg declares lg_picture_mode_signal_for_canonical_name');
like($helper,qr/sub lg_picture_mode_signal_compatible \(\@\)/,'pgenerator-lg declares lg_picture_mode_signal_compatible');
like($helper,qr/sub lg_picture_mode_signal_examples \(\@\)/,'pgenerator-lg declares lg_picture_mode_signal_examples');

# The helper accepts a second signal_mode argument and forwards it
# through both lookup branches.
like($command,qr/my \$signal_mode=shift;.*?\$signal_mode=""\s*if\(\$signal_mode ne "sdr" && \$signal_mode ne "hdr10" && \$signal_mode ne "hlg" && \$signal_mode ne "dv"\)/s,'shared command.pm normalizes the signal_mode argument to sdr/hdr10/hlg/dv');
like($command,qr/&lg_picture_mode_signal_compatible\(\$resolved,\$signal_mode\)/,'shared command.pm applies the signal-mode compatibility check on every resolution branch');

# The set_workflow in pgenerator-lg plumbs signal_mode into the
# mapping call and surfaces a clear error when the resolved
# canonical name is not valid in the current signal context.
like($helper,qr/my \(\$ip,\$client_key,\$connect_timeout,\$settings,\$readback_keys,\$tv_input,\$keep_calibration_mode,\$fallback_picture_mode,\$calibration_mode_active,\$reset_ddc_baseline,\$verify_ddc_upload,\$force_ddc_white_balance,\$signal_mode\)=@_/,'pgenerator-lg lg_picture_set_workflow accepts a trailing signal_mode parameter');
like($helper,qr/&map_picture_mode_label_to_ddc_name\(\$caller_picture_mode,\$signal_mode\)/,'pgenerator-lg calls the signal-mode-aware map helper from picture_set');
like($helper,qr/error_code => "unknown-picture-mode-label"/s,'pgenerator-lg keeps the unknown-picture-mode-label error code');
like($helper,qr/&\s*lg_picture_set_workflow\(\$ip,\$client_key,\$connect_timeout,\$settings,\$readback_keys,\$tv_input,\$keep_calibration_mode,\$picture_mode,\$calibration_mode_active,\$reset_ddc_baseline,\$verify_ddc_upload,\$force_ddc_white_balance,\$signal_mode\)/,'pgenerator-lg main passes signal_mode through to lg_picture_set_workflow');

# The WebUI route forwards signal_mode to the helper binary so the
# rejection can be raised before a round-trip to the LG TV.
like($lg,qr/signal_mode => \$payload->\Q{"signal_mode"}\E/,'WebUI /api/lg/picture-settings/set forwards signal_mode to the helper binary');

# The front-end JavaScript now sends signal_mode with the
# picture-mode change so the backend has the context to validate.
like($lg,qr/body:JSON\.stringify\(\{settings:\{pictureMode:value\},picture_mode:value,signal_mode:lgSignalModeKey\(\),readback_keys:\['pictureMode'\]\}\)/,'lg.pm JS lgSetPictureMode() sends signal_mode with the picture-mode change');

# The front-end dropdown no longer offers a stale picture-mode
# value from a different signal mode as a selectable option.
like($lg,qr/if\(canonicalCurrent&&lgPictureModeMatchesSignal\(canonicalCurrent,mode\)\) extras\.push\(canonicalCurrent\);/,'lg.pm JS filters extras by current signal mode');

done_testing();
