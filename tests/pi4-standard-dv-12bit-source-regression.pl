#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;

sub slurp {
 my ($path)=@_;
 open(my $fh,'<',$path) or BAIL_OUT("cannot read $path: $!");
 local $/;
 my $text=<$fh>;
 close($fh);
 return $text;
}

my $app=slurp('tools/image-targets/pi4-biasi/src/pattern_generator/src/ofApp.cpp');
my $header=slurp('tools/image-targets/pi4-biasi/src/pattern_generator/src/ofApp.h');
my $window=slurp('tools/image-targets/pi4-biasi/src/ofxRPI4Window/src/ofxRPI4Window.cpp');
my $webui=slurp('usr/share/PGenerator/webui.pm');
my $series_worker=slurp('usr/bin/meter_series.sh');
my $dv_profile=slurp('usr/bin/meter_lg_dv_profile.pl');
my $autocal=slurp('usr/bin/meter_lg_autocal.pl');
my ($pattern_shader)=$window=~/(void ofxRPI4Window::dovi_pattern_shader\(\).*?)(?=void ofxRPI4Window::dovi_image_shader\(\))/s;
BAIL_OUT('cannot isolate standard-DV pattern shader') if(!defined($pattern_shader));

like($app,qr/el\[0\]\s*==\s*"SOURCE_MAX"/,'renderer parses SOURCE_MAX independently of BITS');
like($header,qr/int\s+arr_source_max\[2048\]\[2048\]/,'renderer stores source precision per draw');
like($app,qr/setUniform3f\("source_rgb"/,'renderer passes unquantized source codes to the DV shader');
like($app,qr/setUniform1i\("source_max",dv_source_max\)/,'renderer tells the DV shader the source code depth');
unlike($pattern_shader,qr/int\(rgb1\.r\*256\.0\)<<4/,'standard-DV pattern shader no longer quantizes through 8-bit RGB');
like($pattern_shader,qr/if\s*\(source_max\s*==\s*4095\)/,'standard-DV shader accepts native 12-bit source codes');
like($pattern_shader,qr/outputColor\s*=\s*vec4\(float\(R1\)\/255\.0/,'standard-DV shader still emits packed 8-bit RGB bytes');

like($webui,qr/my \$pattern_source_bits=\(\$signal_mode eq "dv"\) \? 12 : \$pat_bits/,'WebUI separates DV source precision from transport BITS');
like($webui,qr/BITS=\$pat_bits\\nSOURCE_MAX=\$pattern_source_max/,'pattern command carries both transport BITS and SOURCE_MAX');
like($webui,qr/my \$dv_series_code_min=\$dv_series \? 256 : 0/,'DV series use 12-bit legal black');
like($webui,qr/my \$dv_series_code_span=\$dv_series \? 3504 : 255/,'DV series use the 12-bit legal span');
like($webui,qr/dv_series_code_bits => \(\(\$signal_mode eq "dv"\) \? 12 : 8\)/,'series insertion uses native 12-bit DV codes');
like($webui,qr/dv_series_code_bits => \(\(\$_ac_signal_mode eq "dv"\) \? 12 : 8\)/,'autocal insertion uses native 12-bit DV codes');
like($webui,qr/int\(\$num\{"input_max"\}\)==4095/,'custom series accepts native 12-bit steps');
like($series_worker,qr/\$\{SIGNAL_MODE,,\}" == "dv".*?3504\.0.*?3760/s,'series worker DV insertion fallback is native legal 12-bit');
like($series_worker,qr/\$\{SIGNAL_MODE,,\}" == "dv".*?echo 4095/s,'series worker stamps the DV insertion fallback as 12-bit');
like($dv_profile,qr/256\.0\+\(\$pct\/100\.0\)\*3504\.0\+0\.5\),4095/,'DV profile insertion fallback is native legal 12-bit');
like($autocal,qr/lc\(\$config->\{"signal_mode"\}\) eq "dv".*?3504\.0\+0\.5\),4095/s,'autocal insertion fallback is native legal 12-bit');

done_testing();
