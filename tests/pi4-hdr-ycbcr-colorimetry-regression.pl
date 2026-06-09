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
my $override=read_text('usr/lib/drm_override.c');
my $rootfs_override=read_text('tools/image-targets/pi4-biasi/rootfs/usr/lib/drm_override.c');
my $renderer=read_text('tools/image-targets/pi4-biasi/src/ofxRPI4Window/src/ofxRPI4Window.cpp');
my $shared_renderer=read_text('src/ofxRPI4Window/src/ofxRPI4Window.cpp');

is($rootfs_command,$command,'Pi4 image rootfs command.pm matches shared runtime command.pm');
is($rootfs_override,$override,'Pi4 image rootfs drm_override.c matches shared runtime drm_override.c');

like(
 $command,
 qr/map_kms_colorspace\(\$colorimetry,\$color_fmt\).*?Colorimetry:\$colorspace.*?Colorspace:\$colorspace/s,
 'Pi4 legacy Colorimetry and newer Colorspace properties use the same mapped enum'
);
unlike(
 $command,
 qr/Colorimetry:\$colorimetry/,
 'Pi4 legacy Colorimetry no longer writes the raw colorimetry enum'
);

like(
 $override,
 qr/static uint64_t map_connector_colorimetry.*?if \(output_fmt == 0\).*?return colorimetry;.*?if \(colorimetry == 9\).*?return 10;/s,
 'drm_override maps BT.2020 RGB to BT.2020 YCbCr when the configured output format is not RGB'
);
like(
 $override,
 qr/mapped_colorimetry = map_connector_colorimetry\(colorimetry_override, output_fmt_override\)/,
 'drm_override applies the mapped colorimetry before overriding atomic commits'
);

like(
 $renderer,
 qr/avi_infoframe\.colorimetry = \(avi_info\.output_format == 0\) \? 9 : 10;/,
 'Pi4 renderer source emits BT.2020 RGB only for RGB output and BT.2020 YCbCr for YCbCr output'
);
like(
 $shared_renderer,
 qr/avi_infoframe\.colorimetry = \(avi_info\.output_format == 0\) \? 9 : 10;/,
 'Shared renderer source emits BT.2020 RGB only for RGB output and BT.2020 YCbCr for YCbCr output'
);
like(
 $renderer,
 qr/avi_infoframe\.colorimetry == 9 \|\| avi_infoframe\.colorimetry == 10/,
 'Pi4 renderer source treats both BT.2020 RGB and YCbCr connector enums as BT.2020 plane encoding'
);
like(
 $shared_renderer,
 qr/avi_infoframe\.colorimetry == 9 \|\| avi_infoframe\.colorimetry == 10/,
 'Shared renderer source treats both BT.2020 RGB and YCbCr connector enums as BT.2020 plane encoding'
);

done_testing();
