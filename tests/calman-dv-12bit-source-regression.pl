#!/usr/bin/perl
use strict;
use warnings;
use Test::More;

my $daemon_path='usr/share/PGenerator/daemon.pm';
my $pattern_path='usr/share/PGenerator/pattern.pm';

open(my $daemon_fh,'<',$daemon_path) or die "open $daemon_path: $!";
local $/;
my $daemon=<$daemon_fh>;
close($daemon_fh);

open(my $pattern_fh,'<',$pattern_path) or die "open $pattern_path: $!";
my $pattern=<$pattern_fh>;
close($pattern_fh);

my ($dv_source_sub)=$daemon=~/(sub calman_dv_source_max \(\@\) \{.*?^\})/ms;
my ($target_sub)=$daemon=~/(sub calman_target_max \(\@\) \{.*?^\})/ms;
my ($scale_sub)=$daemon=~/(sub calman_scale_value \(\@\) \{.*?^\})/ms;
ok($dv_source_sub && $target_sub && $scale_sub,'loaded Calman scaling helpers for behavioral checks');
{
 package CalmanDvScaleTest;
 our (%pgenerator_conf,$bits_default);
 no strict;
 eval "$dv_source_sub\n$target_sub\n$scale_sub\n1;" or die $@;
 $bits_default=8;
 %pgenerator_conf=(dv_status=>1,is_std_dovi=>1);
}
is(CalmanDvScaleTest::calman_target_max(),4095,'Calman DV target is 12-bit');
is(CalmanDvScaleTest::calman_scale_value(940,1023),3760,'Calman legal white expands from 10-bit to 12-bit');
is(CalmanDvScaleTest::calman_scale_value(1023,1023),4095,'Calman full white reaches the 12-bit endpoint');
{
 package CalmanDvScaleTest;
 %CalmanDvScaleTest::pgenerator_conf=(dv_status=>1,is_std_dovi=>0);
}
is(CalmanDvScaleTest::calman_dv_source_max(),0,'non-standard DV transport does not use the RGB tunnel source path');
{
 package CalmanDvScaleTest;
 %CalmanDvScaleTest::pgenerator_conf=(dv_status=>0,is_std_dovi=>0);
}
is(CalmanDvScaleTest::calman_scale_value(940,1023),235,'non-DV 8-bit Calman scaling remains unchanged');
is(CalmanDvScaleTest::calman_dv_source_max(),0,'non-DV Calman patterns do not declare DV source precision');

my ($create_pattern_sub)=$pattern=~/(sub create_pattern_file \(\@\) \{.*?^\})/ms;
ok($create_pattern_sub,'loaded direct pattern writer for behavioral checks');
{
 package CalmanDvPatternTest;
 our ($requested_by_default,$bits_default,$bg_default,$position_default,$w_s,$h_s,$max_x,$max_y);
 no strict;
 sub round_val { return int($_[0] + 0.5); }
 sub get_position { return $_[2]; }
 eval "no warnings 'uninitialized';\n$create_pattern_sub\n1;" or die $@;
 $requested_by_default='unknown';
 $bits_default=8;
 $bg_default='0,0,0';
 $position_default='0,0';
 $w_s=1920;
 $h_s=1080;
 $max_x=1920;
 $max_y=1080;
}
my $dv_pattern=CalmanDvPatternTest::create_pattern_file(
 'RECTANGLE','1920,1080',100,'3760,3760,3760','256,256,256','0,0','',1,1,
 'calman','LIMITED',4095
);
like($dv_pattern,qr/^BITS=8$/m,'Calman DV keeps the packed RGB tunnel at 8-bit');
like($dv_pattern,qr/^SOURCE_MAX=4095$/m,'Calman DV declares 12-bit source codes');
like($dv_pattern,qr/^RGB=3760,3760,3760$/m,'Calman DV writes the expanded 12-bit values');
my $sdr_pattern=CalmanDvPatternTest::create_pattern_file(
 'RECTANGLE','1920,1080',100,'235,235,235','0,0,0','0,0','',1,1,
 'calman','',0
);
unlike($sdr_pattern,qr/^SOURCE_MAX=/m,'non-DV Calman pattern header remains unchanged');

like(
 $daemon,
 qr/sub calman_dv_source_max.*?return 4095 if\(int\(\$pgenerator_conf\{"dv_status"\} \|\| 0\) == 1 &&\s*int\(\$pgenerator_conf\{"is_std_dovi"\} \|\| 0\) == 1\)/s,
 'active Calman DV uses 12-bit source codes'
);
like(
 $daemon,
 qr/sub calman_render_rgb_pattern.*?my \$calman_max=1023;.*?my \$target_max=&calman_target_max\(\);.*?calman_scale_value\(\$el_cmd\[0\],\$calman_max\)/s,
 'Calman RGB input remains 10-bit and scales to the DV target'
);
like(
 $daemon,
 qr/create_pattern_file\("RECTANGLE".*?\$source_range,\$source_max\)/s,
 'direct Calman rectangles declare their independent source precision'
);
like(
 $daemon,
 qr/get_pattern\(\$test_template_command,\$pattern_dynamic,.*?"calman",\$source_range,\$source_max\)/s,
 'dynamic Calman patterns declare their independent source precision'
);
like(
 $pattern,
 qr/\$pattern_string\.="SOURCE_MAX=\$source_max\\n" if\(\$source_max > 0\)/,
 'direct pattern files emit SOURCE_MAX'
);
like(
 $pattern,
 qr/\$str=~s\/\^END=\(\.\*\)\$\/SOURCE_MAX=\$source_max\\nEND=\$1\/mg if\(\$source_max > 0/,
 'template pattern files emit SOURCE_MAX'
);
like(
 $pattern,
 qr/\$max_rgb=\$source_max if\(\$source_max > 0\)/,
 'pattern validation accepts the declared 12-bit source range'
);

done_testing();
