#!/usr/bin/perl

use strict;
use warnings;
use Errno qw(EINTR);
use File::Path qw(make_path);
use IO::Select ();
use IO::Socket::INET ();
use JSON::PP ();
use MIME::Base64 ();
use POSIX qw(strftime);
use Time::HiRes qw(sleep time);

my $config_file = shift || "/tmp/meter_lg_3d_autocal_config.json";
my $state_file = shift || "/tmp/meter_lg_3d_autocal.json";
my $stop_file = shift || "/tmp/meter_lg_3d_autocal.stop";
my $api_host = "127.0.0.1";
my $api_port = 80;
my $json = JSON::PP->new->canonical(1);
my $cancelled = 0;

$SIG{TERM} = sub { $cancelled = 1; };
$SIG{INT} = sub { $cancelled = 1; };

sub json_true { return JSON::PP::true; }
sub json_false { return JSON::PP::false; }
sub json_bool {
 my ($value)=@_;
 return $value ? json_true() : json_false();
}

sub ramp_levels { return (0,2,5,8,12,16,20,30,40,50,60,70,80,88,94,98,100); }

sub describe_and_exit {
 print $json->encode({
  status => "ok",
  default_method => "matrix",
  lut_size => 17,
  cube_lut_size => 17,
  payload_lut_size => 33,
  payload_bits => 12,
  payload_endianness => "little-endian uint16",
  payload_axis_order => "R fastest, G middle, B slowest",
  payload_channel_order => "RGB values per node",
  signal_modes => ["sdr","hdr10"],
  hdr10_methods => ["matrix"],
  target_gamuts => ["bt709","p3d65","p3dci","bt2020"],
  target_gammas => ["bt1886","2.2","2.4","srgb","st2084"],
  ramp_levels => [ramp_levels()],
  ramp_profile_patch_count => 65,
  ramp_drift => "start/end WRGB anchors with time-interpolated 3x3 correction",
  model => "per-luminance-level additive XYZ contributions",
  neutral_axis => "exact diagonal identity after current 1D greyscale path; adjacent neutral-neighborhood identity on legacy LG generations",
  inverse => "per-level native matrix inverse, channel EOTF lookup, clamp, peak normalize",
 });
 exit 0;
}

describe_and_exit() if($config_file eq "--describe");

sub log_line {
 my ($message)=@_;
 $message="" if(!defined($message));
 my @lt=localtime();
 print STDERR sprintf("[%02d:%02d:%02d] %s\n",$lt[2],$lt[1],$lt[0],$message);
}

sub read_file {
 my ($path)=@_;
 return "" if(!defined($path) || !-f $path);
 local $/;
 open(my $fh,"<",$path) or return "";
 binmode($fh);
 my $data=<$fh>;
 close($fh);
 return defined($data) ? $data : "";
}

sub write_file {
 my ($path,$data,$binary)=@_;
 return 0 if(!defined($path) || $path eq "");
 my $dir=$path;
 $dir=~s{/[^/]+$}{};
 eval { make_path($dir) if($dir ne "" && !-d $dir); 1; } or return 0;
 my $tmp="$path.tmp";
 open(my $fh,">",$tmp) or return 0;
 binmode($fh) if($binary);
 print $fh (defined($data) ? $data : "");
 close($fh);
 chmod(0666,$tmp);
 return rename($tmp,$path) ? 1 : 0;
}

sub decode_json_safe {
 my ($raw,$fallback)=@_;
 $fallback={} if(!defined($fallback));
 return $fallback if(!defined($raw) || $raw eq "");
 my $data;
 eval { $data=$json->decode($raw); 1; } or return $fallback;
 return defined($data) ? $data : $fallback;
}

sub write_state {
 my ($state)=@_;
 return write_file($state_file,$json->encode($state),0);
}

sub cancelled {
 return 1 if($cancelled);
 return 1 if(-f $stop_file);
 return 0;
}

sub api_json {
 my ($method,$path,$payload,$timeout)=@_;
 $method ||= "GET";
 $timeout ||= 30;
 $timeout=1 if($timeout < 1);
 my $body=defined($payload) ? $json->encode($payload) : "";
 my $deadline=time()+$timeout;
 my $socket=IO::Socket::INET->new(PeerHost=>$api_host,PeerPort=>$api_port,Proto=>"tcp",Timeout=>$timeout);
 return { status=>"error", message=>"Web UI API is unavailable" } if(!$socket);
 $socket->autoflush(1);
 my $request="$method $path HTTP/1.1\r\nHost: $api_host\r\nConnection: close\r\nAccept: application/json\r\n";
 if($method ne "GET") {
  $request.="Content-Type: application/json\r\nContent-Length: ".length($body)."\r\n\r\n".$body;
 } else {
  $request.="\r\n";
 }
 print $socket $request;
 my $raw="";
 my $buf="";
 my $selector=IO::Select->new($socket);
 while(1) {
  return { status=>"error", message=>"cancelled" } if(cancelled());
  my $remaining=$deadline-time();
  if($remaining <= 0) {
   close($socket);
   return { status=>"error", message=>"Web UI API timed out during $path" };
  }
  my @ready=$selector->can_read($remaining > 1 ? 1 : $remaining);
  next if(!@ready);
  my $len=sysread($socket,$buf,8192);
  if(!defined($len)) {
   next if($! == EINTR);
   close($socket);
   return { status=>"error", message=>"Web UI API read failed during $path" };
  }
  last if($len == 0);
  $raw.=$buf;
 }
 close($socket);
 my (undef,$content)=split(/\r?\n\r?\n/,$raw,2);
 $content="" if(!defined($content));
 my $result=decode_json_safe($content,{});
 return $result if(ref($result) eq "HASH" && %{$result});
 return { status=>"error", message=>"Invalid Web UI API response" };
}

sub clamp {
 my ($v,$lo,$hi)=@_;
 $v=0 if(!defined($v));
 return $lo if($v < $lo);
 return $hi if($v > $hi);
 return $v;
}

sub sanitize_name {
 my ($text)=@_;
 $text="" if(!defined($text));
 $text=~s/[^A-Za-z0-9_.-]+/_/g;
 $text=~s/^_+|_+$//g;
 return $text || "lg";
}

sub format_percent {
 my ($v)=@_;
 $v=0 if(!defined($v));
 my $s=sprintf("%.3f",$v+0);
 $s=~s/0+$//;
 $s=~s/\.$//;
 return $s;
}

sub first_nonempty {
 foreach my $value (@_) {
  next if(!defined($value));
  my $text="$value";
  $text=~s/^\s+|\s+$//g;
  return $text if($text ne "");
 }
 return "";
}

sub compact_token {
 my ($value)=@_;
 $value="" if(!defined($value));
 $value=lc($value);
 $value=~s/^\s+|\s+$//g;
 $value=~s/[^a-z0-9]+//g;
 return $value;
}

sub sanitize_signal_mode {
 my $raw=first_nonempty(@_);
 $raw="sdr" if($raw eq "");
 my $token=compact_token($raw);
 return ("sdr",undef) if($token eq "" || $token eq "sdr" || $token eq "rec709" || $token eq "bt709");
 return ("hdr10",undef) if($token eq "hdr" || $token eq "hdr10" || $token eq "pq" || $token eq "st2084");
 return ("sdr","Unsupported signal mode '$raw' for LG 3D LUT Auto Cal");
}

# The HDR 1D DPG is calibrated to a display gamma (2.2 by convention here,
# matching the greyscale calibration domain) while the HDR signal and the
# post-cal series reads stay PQ (st2084). The 3D LUT sits on top of the
# DPG-calibrated panel, so it must SOLVE in the DPG's gamma domain: encoding
# the per-channel correction with PQ (channel_inverse_level via target_gamma)
# inflates the small cross-channel drive (~25x, PQ is steep near black) and
# desaturates colours toward yellow. Plumbed from config (dpg_gamma /
# greyscale_target_gamma); defaults to 2.2 for HDR when not supplied. SDR's
# DPG matches its target gamma, so SDR is unchanged. The signal EOTF (st2084)
# is kept separately for reporting and the series reads.
sub dpg_calibration_gamma {
 my ($config,$signal_mode,$signal_gamma)=@_;
 $signal_mode=lc($signal_mode||"sdr");
 my $raw=compact_token(first_nonempty($config->{"dpg_gamma"},$config->{"greyscale_target_gamma"},$config->{"dpg_calibration_gamma"}));
 return "2.2" if($raw eq "22" || $raw eq "gamma22");
 return "2.4" if($raw eq "24" || $raw eq "gamma24");
 return "bt1886" if($raw eq "bt1886" || $raw eq "1886");
 return "srgb" if($raw eq "srgb");
 return "2.2" if($signal_mode eq "hdr10");
 return $signal_gamma;
}

sub sanitize_target_gamut {
 my ($raw,$signal_mode)=@_;
 $raw=first_nonempty($raw);
 my $default=(defined($signal_mode) && lc($signal_mode) eq "hdr10") ? "bt2020" : "bt709";
 my $token=compact_token($raw);
 return $default if($token eq "" || $token eq "auto");
 return "p3d65" if($token eq "p3" || $token eq "p3d65" || $token eq "displayp3");
 return "p3dci" if($token eq "dci" || $token eq "dcip3" || $token eq "p3dci");
 return "bt2020" if($token eq "2020" || $token eq "rec2020" || $token eq "bt2020");
 return $default;
}

sub sanitize_target_gamma {
 my ($raw,$signal_mode)=@_;
 my $is_hdr=(defined($signal_mode) && lc($signal_mode) eq "hdr10") ? 1 : 0;
 my $default=$is_hdr ? "st2084" : "bt1886";
 $raw=first_nonempty($raw);
 return $default if($raw eq "");
 my $token=compact_token($raw);
 return "bt1886" if($token eq "bt1886" || $token eq "1886");
 return "srgb" if($token eq "srgb");
 return "2.2" if($token eq "22" || $token eq "gamma22");
 return "2.4" if($token eq "24" || $token eq "gamma24");
 return $is_hdr ? "st2084" : "bt1886" if($token eq "st2084" || $token eq "smpte2084" || $token eq "pq");
 return $default;
}

sub signal_mode_label {
 my ($signal_mode)=@_;
 $signal_mode=lc($signal_mode||"sdr");
 return "HDR10" if($signal_mode eq "hdr10");
 return "SDR";
}

sub target_gamut_label {
 my ($target_gamut)=@_;
 $target_gamut=sanitize_target_gamut($target_gamut);
 return "P3-D65" if($target_gamut eq "p3d65");
 return "P3-DCI" if($target_gamut eq "p3dci");
 return "BT.2020" if($target_gamut eq "bt2020");
 return "BT.709";
}

sub target_gamma_label {
 my ($target_gamma)=@_;
 $target_gamma=lc($target_gamma||"bt1886");
 return "BT.1886" if($target_gamma eq "bt1886");
 return "sRGB" if($target_gamma eq "srgb");
 return "ST2084" if($target_gamma eq "st2084");
 return $target_gamma;
}

sub patch_code_for_percent {
	 my ($pct,$signal_range)=@_;
	 $pct=clamp($pct,0,100);
	 my $limited=(!defined($signal_range) || $signal_range eq "" || int($signal_range)==1) ? 1 : 0;
	 return $limited ? int(16 + ($pct/100)*219 + 0.5) : int(($pct/100)*255 + 0.5);
}

sub patch_code_for_8bit_value {
	 my ($value,$signal_range)=@_;
	 $value=clamp($value,0,255);
	 my $limited=(!defined($signal_range) || $signal_range eq "" || int($signal_range)==1) ? 1 : 0;
	 return $limited ? int(16 + ($value/255)*219 + 0.5) : int($value + 0.5);
}

sub patch_step {
	 my ($kind,$level,$phase,$config)=@_;
	 my $signal_range=$config->{"pattern_signal_range"}||$config->{"signal_range"}||"1";
	 my $code=patch_code_for_percent($level,$signal_range);
	 my $black_code=patch_code_for_percent(0,$signal_range);
	 my %rgb=(r=>$black_code,g=>$black_code,b=>$black_code);
	 if($kind eq "white") { %rgb=(r=>$code,g=>$code,b=>$code); }
	 elsif($kind eq "red") { $rgb{r}=$code; }
	 elsif($kind eq "green") { $rgb{g}=$code; }
	 elsif($kind eq "blue") { $rgb{b}=$code; }
 my $name=($phase ? "$phase " : "").uc(substr($kind,0,1))." ".format_percent($level)."%";
 return {
  kind => $kind,
  level => $level+0,
  phase => $phase||"profile",
  name => $name,
  ire => $level+0,
  stimulus => $level+0,
  signal_r_pct => ($kind eq "white" || $kind eq "red") ? $level+0 : 0,
  signal_g_pct => ($kind eq "white" || $kind eq "green") ? $level+0 : 0,
  signal_b_pct => ($kind eq "white" || $kind eq "blue") ? $level+0 : 0,
  r => $rgb{r},
  g => $rgb{g},
  b => $rgb{b},
  input_max => 255,
 };
}

sub high_low_stride_381 {
 my (@items)=@_;
 @items=sort { ($a->{"level"}||0) <=> ($b->{"level"}||0) || ($a->{"kind"}||"") cmp ($b->{"kind"}||"") } @items;
 my @hi_low;
 while(@items) {
  push @hi_low,pop @items;
  push @hi_low,shift @items if(@items);
 }
 my $n=scalar(@hi_low);
 return @hi_low if($n <= 2);
 my @out;
 my %used;
 my $idx=381 % $n;
 for(my $i=0;$i<$n;$i++) {
  $idx=($idx+1)%$n while($used{$idx});
  push @out,$hi_low[$idx];
  $used{$idx}=1;
  $idx=($idx+381)%$n;
 }
 return @out;
}

sub build_matrix_steps {
 my ($config)=@_;
 return (
  patch_step("white",100,"profile",$config),
  patch_step("red",100,"profile",$config),
  patch_step("green",100,"profile",$config),
  patch_step("blue",100,"profile",$config),
  patch_step("black",0,"profile",$config),
 );
}

sub build_ramp_steps {
 my ($config)=@_;
 my @levels=ramp_levels();
 my @steps;
 push @steps,patch_step("black",0,"profile",$config);
 foreach my $kind (qw(white red green blue)) {
  push @steps,patch_step($kind,100,"drift_start",$config);
 }
 my @profile;
 foreach my $level (@levels) {
  next if($level <= 0 || $level >= 100);
  foreach my $kind (qw(white red green blue)) {
   push @profile,patch_step($kind,$level,"profile",$config);
  }
 }
 push @steps,high_low_stride_381(@profile);
 foreach my $kind (qw(white red green blue)) {
  push @steps,patch_step($kind,100,"drift_end",$config);
 }
 return @steps;
}

sub reading_xyz {
 my ($reading)=@_;
 return undef if(ref($reading) ne "HASH");
 if(defined($reading->{"X"}) && defined($reading->{"Y"}) && defined($reading->{"Z"})) {
  return [ $reading->{"X"}+0, $reading->{"Y"}+0, $reading->{"Z"}+0 ];
 }
 my $Y=defined($reading->{"luminance"}) ? ($reading->{"luminance"}+0) : (defined($reading->{"Y"}) ? ($reading->{"Y"}+0) : undef);
 my $x=defined($reading->{"x"}) ? ($reading->{"x"}+0) : undef;
 my $y=defined($reading->{"y"}) ? ($reading->{"y"}+0) : undef;
 return undef if(!defined($Y) || !defined($x) || !defined($y) || $y <= 0);
 return [ ($x/$y)*$Y, $Y, ((1-$x-$y)/$y)*$Y ];
}

sub vec_add { return [ $_[0][0]+$_[1][0], $_[0][1]+$_[1][1], $_[0][2]+$_[1][2] ]; }
sub vec_sub { return [ $_[0][0]-$_[1][0], $_[0][1]-$_[1][1], $_[0][2]-$_[1][2] ]; }
sub vec_scale { return [ $_[0][0]*$_[1], $_[0][1]*$_[1], $_[0][2]*$_[1] ]; }

sub matrix_from_columns {
 my ($r,$g,$b)=@_;
 return [
  [ $r->[0], $g->[0], $b->[0] ],
  [ $r->[1], $g->[1], $b->[1] ],
  [ $r->[2], $g->[2], $b->[2] ],
 ];
}

sub matrix_mul_vec {
 my ($m,$v)=@_;
 return [
  $m->[0][0]*$v->[0]+$m->[0][1]*$v->[1]+$m->[0][2]*$v->[2],
  $m->[1][0]*$v->[0]+$m->[1][1]*$v->[1]+$m->[1][2]*$v->[2],
  $m->[2][0]*$v->[0]+$m->[2][1]*$v->[1]+$m->[2][2]*$v->[2],
 ];
}

sub matrix_mul {
 my ($a,$b)=@_;
 my @m;
 for(my $r=0;$r<3;$r++) {
  for(my $c=0;$c<3;$c++) {
   $m[$r][$c]=$a->[$r][0]*$b->[0][$c]+$a->[$r][1]*$b->[1][$c]+$a->[$r][2]*$b->[2][$c];
  }
 }
 return \@m;
}

sub matrix_inverse {
 my ($m)=@_;
 my $a=$m->[0][0]; my $b=$m->[0][1]; my $c=$m->[0][2];
 my $d=$m->[1][0]; my $e=$m->[1][1]; my $f=$m->[1][2];
 my $g=$m->[2][0]; my $h=$m->[2][1]; my $i=$m->[2][2];
 my $det=$a*($e*$i-$f*$h)-$b*($d*$i-$f*$g)+$c*($d*$h-$e*$g);
 return undef if(abs($det) < 1e-12);
 my $id=1/$det;
 return [
  [ ($e*$i-$f*$h)*$id, ($c*$h-$b*$i)*$id, ($b*$f-$c*$e)*$id ],
  [ ($f*$g-$d*$i)*$id, ($a*$i-$c*$g)*$id, ($c*$d-$a*$f)*$id ],
  [ ($d*$h-$e*$g)*$id, ($b*$g-$a*$h)*$id, ($a*$e-$b*$d)*$id ],
 ];
}

my %rgb_to_xyz_matrix_cache;

sub xy_to_xyz_unit {
 my ($x,$y)=@_;
 $y=1 if(!defined($y) || $y <= 0);
 return [ $x/$y, 1, (1-$x-$y)/$y ];
}

sub gamut_xy_definition {
 my ($target_gamut)=@_;
 $target_gamut=sanitize_target_gamut($target_gamut);
 return {
  red => [0.680,0.320], green => [0.265,0.690], blue => [0.150,0.060], white => [0.3127,0.3290],
 } if($target_gamut eq "p3d65");
 return {
  red => [0.680,0.320], green => [0.265,0.690], blue => [0.150,0.060], white => [0.314,0.351],
 } if($target_gamut eq "p3dci");
 return {
  red => [0.708,0.292], green => [0.170,0.797], blue => [0.131,0.046], white => [0.3127,0.3290],
 } if($target_gamut eq "bt2020");
 return {
  red => [0.640,0.330], green => [0.300,0.600], blue => [0.150,0.060], white => [0.3127,0.3290],
 };
}

sub rgb_to_xyz_matrix_for_gamut {
 my ($target_gamut)=@_;
 $target_gamut=sanitize_target_gamut($target_gamut);
 return $rgb_to_xyz_matrix_cache{$target_gamut} if($rgb_to_xyz_matrix_cache{$target_gamut});
 my $def=gamut_xy_definition($target_gamut);
 my $r=xy_to_xyz_unit(@{$def->{"red"}});
 my $g=xy_to_xyz_unit(@{$def->{"green"}});
 my $b=xy_to_xyz_unit(@{$def->{"blue"}});
 my $w=xy_to_xyz_unit(@{$def->{"white"}});
 my $m=matrix_from_columns($r,$g,$b);
 my $inv=matrix_inverse($m);
 my $scale=$inv ? matrix_mul_vec($inv,$w) : [1,1,1];
 my $matrix=matrix_from_columns(vec_scale($r,$scale->[0]),vec_scale($g,$scale->[1]),vec_scale($b,$scale->[2]));
 $rgb_to_xyz_matrix_cache{$target_gamut}=$matrix;
 return $matrix;
}

sub rgb_to_xyz_for_gamut {
 my ($target_gamut,$r,$g,$b,$white_y)=@_;
 $white_y=100 if(!defined($white_y) || $white_y <= 0);
 my $m=rgb_to_xyz_matrix_for_gamut($target_gamut);
 return [
  ($m->[0][0]*$r + $m->[0][1]*$g + $m->[0][2]*$b) * $white_y,
  ($m->[1][0]*$r + $m->[1][1]*$g + $m->[1][2]*$b) * $white_y,
  ($m->[2][0]*$r + $m->[2][1]*$g + $m->[2][2]*$b) * $white_y,
 ];
}

sub xyz_to_rgb_inverse_for_gamut {
 my ($target_gamut,$white_y)=@_;
 $white_y=100 if(!defined($white_y) || $white_y <= 0);
 my $inv=matrix_inverse(rgb_to_xyz_matrix_for_gamut($target_gamut));
 return undef if(!$inv);
 foreach my $row (@{$inv}) {
  foreach my $v (@{$row}) {
   $v/=$white_y;
  }
 }
 return $inv;
}

sub st2084_pq_to_linear {
 my ($signal)=@_;
 $signal=clamp($signal,0,1);
 my $m1=2610/16384;
 my $m2=2523/32;
 my $c1=3424/4096;
 my $c2=2413/128;
 my $c3=2392/128;
 my $n=$signal ** (1/$m2);
 my $den=$c2 - $c3*$n;
 return 0 if($den <= 0);
 my $l=($n - $c1)/$den;
 $l=0 if($l < 0);
 return clamp($l ** (1/$m1),0,1);
}

sub target_gamma_linear {
 my ($signal,$gamma)=@_;
 $signal=clamp($signal,0,1);
 $gamma=lc($gamma||"bt1886");
 return ($signal <= 0.04045) ? ($signal/12.92) : ((($signal+0.055)/1.055) ** 2.4) if($gamma eq "srgb");
 return st2084_pq_to_linear($signal) if($gamma eq "st2084");
 my $g=($gamma eq "2.2") ? 2.2 : 2.4;
 return $signal ** $g;
}

sub bt1886_luminance_y {
 my ($signal,$white_y,$black_y)=@_;
 $signal=clamp($signal,0,1);
 $white_y=100 if(!defined($white_y) || $white_y <= 0);
 $black_y=0 if(!defined($black_y) || $black_y < 0);
 $black_y=0 if($black_y >= $white_y);
 my $g=2.4;
 return (($white_y ** (1/$g) - $black_y ** (1/$g))*$signal + $black_y ** (1/$g)) ** $g;
}

sub bt1886_relative_luminance {
 my ($signal,$white_y,$black_y)=@_;
 $white_y=100 if(!defined($white_y) || $white_y <= 0);
 $black_y=0 if(!defined($black_y) || $black_y < 0);
 my $range=$white_y-$black_y;
 return target_gamma_linear($signal,"2.4") if($range <= 1e-9);
 return clamp((bt1886_luminance_y($signal,$white_y,$black_y)-$black_y)/$range,0,1);
}

sub target_relative_luminance {
 my ($signal,$gamma,$white_y,$black_y)=@_;
 $gamma=lc($gamma||"bt1886");
 return bt1886_relative_luminance($signal,$white_y,$black_y) if($gamma eq "bt1886");
 return target_gamma_linear($signal,$gamma);
}

sub bt709_rgb_to_xyz { return rgb_to_xyz_for_gamut("bt709",@_); }

sub target_rgb_to_xyz {
 my ($r,$g,$b,$gamma,$white_y,$black,$target_gamut)=@_;
 $white_y=100 if(!defined($white_y) || $white_y <= 0);
 $gamma=lc($gamma||"bt1886");
 $target_gamut=sanitize_target_gamut($target_gamut);
 if($gamma eq "bt1886") {
  $black=[0,0,0] if(ref($black) ne "ARRAY");
  my $black_y=$black->[1] || 0;
  my $range=$white_y-$black_y;
  $range=$white_y if($range <= 1e-9);
  my $lr=target_relative_luminance($r,$gamma,$white_y,$black_y);
  my $lg=target_relative_luminance($g,$gamma,$white_y,$black_y);
  my $lb=target_relative_luminance($b,$gamma,$white_y,$black_y);
  return vec_add($black,rgb_to_xyz_for_gamut($target_gamut,$lr,$lg,$lb,$range));
 }
 my $lr=target_gamma_linear($r,$gamma);
 my $lg=target_gamma_linear($g,$gamma);
 my $lb=target_gamma_linear($b,$gamma);
 return rgb_to_xyz_for_gamut($target_gamut,$lr,$lg,$lb,$white_y);
}

sub interpolate_vec_by_level {
 my ($samples,$level)=@_;
 return [0,0,0] if(ref($samples) ne "HASH");
 my @levels=sort { $a <=> $b } map { $_+0 } keys %{$samples};
 return [0,0,0] if(!@levels);
 return $samples->{$levels[0]} if($level <= $levels[0]);
 return $samples->{$levels[$#levels]} if($level >= $levels[$#levels]);
 for(my $i=1;$i<@levels;$i++) {
  next if($level > $levels[$i]);
  my $l0=$levels[$i-1]; my $l1=$levels[$i];
  my $t=($level-$l0)/($l1-$l0);
  return vec_add(vec_scale($samples->{$l0},1-$t),vec_scale($samples->{$l1},$t));
 }
 return $samples->{$levels[$#levels]};
}

sub channel_inverse_level {
 my ($model,$kind,$linear)=@_;
 $linear=clamp($linear,0,1);
 my $peak=$model->{"peak_y"}{$kind} || 1;
 my @levels=ramp_levels();
 my @curve;
 foreach my $level (@levels) {
  my $y=0;
  if($level == 0) {
   $y=0;
  } else {
   my $v=$model->{"contrib"}{$kind}{$level} || [0,0,0];
   $y=($v->[1] || 0)/$peak;
  }
  $y=0 if($y < 0);
  push @curve,{ level=>$level, y=>$y };
 }
 for(my $i=1;$i<@curve;$i++) {
  next if($linear > $curve[$i]{y});
  my $y0=$curve[$i-1]{y}; my $y1=$curve[$i]{y};
  my $l0=$curve[$i-1]{level}; my $l1=$curve[$i]{level};
  return $l1 if(abs($y1-$y0) < 1e-9);
  return $l0 + (($linear-$y0)/($y1-$y0))*($l1-$l0);
 }
 return 100;
}

sub matrix_for_level {
 my ($model,$level)=@_;
 my $black=$model->{"black"} || [0,0,0];
 my $lin=target_relative_luminance($level/100,$model->{"target_gamma"},$model->{"white_y"},$black->[1]||0);
 $lin=1 if($lin <= 1e-9);
 my @cols;
 foreach my $kind (qw(red green blue)) {
  my $v=interpolate_vec_by_level($model->{"contrib"}{$kind},$level);
  push @cols,vec_scale($v,1/$lin);
 }
 return matrix_from_columns($cols[0],$cols[1],$cols[2]);
}

sub target_xyz_for_node {
 my ($model,$ri,$gi,$bi,$size)=@_;
 my $r=$ri/($size-1);
 my $g=$gi/($size-1);
 my $b=$bi/($size-1);
 if($ri==$gi && $gi==$bi && ref($model->{"white_axis"}) eq "HASH") {
  return interpolate_vec_by_level($model->{"white_axis"},$r*100);
 }
 # Chromatic nodes reference the additive primary white (WRGB self-detection);
 # see model_from_readings. Falls back to white_y on additive displays.
 my $cw=$model->{"chromatic_white_y"} || $model->{"white_y"};
 return target_rgb_to_xyz($r,$g,$b,$model->{"target_gamma"},$cw,$model->{"black"},$model->{"target_gamut"});
}

sub srgb_to_linear {
 my $v=shift;
 $v=clamp($v,0,1);
 return ($v <= 0.04045) ? ($v/12.92) : ((($v+0.055)/1.055)**2.4);
}

sub post_check_target_xyz {
	 my ($step,$white_y,$target_gamma,$black,$target_gamut,$chromatic_white_y)=@_;
	 $white_y=100 if(!defined($white_y) || $white_y <= 0);
	 # Chromatic patches score against the additive primary white (WRGB
	 # self-detection); neutral patches keep white_y. Mirrors target_xyz_for_node
	 # so the post-check dE matches what the cube actually calibrated to.
	 $chromatic_white_y=$white_y if(!defined($chromatic_white_y) || $chromatic_white_y <= 0);
	 my $pick=sub { my ($r,$g,$b)=@_; return ($r==$g && $g==$b) ? $white_y : $chromatic_white_y; };
	 $target_gamma||="bt1886";
	 $target_gamut=sanitize_target_gamut($target_gamut);
	 my $gamma=lc($target_gamma);
	 my ($r,$g,$b)=(0,0,0);
	 if($gamma eq "bt1886" && (defined($step->{"signal_r_pct"}) || defined($step->{"signal_g_pct"}) || defined($step->{"signal_b_pct"}))) {
	  my ($rr,$gg,$bb)=(($step->{"signal_r_pct"}||0)/100,($step->{"signal_g_pct"}||0)/100,($step->{"signal_b_pct"}||0)/100);
	  return target_rgb_to_xyz($rr,$gg,$bb,$target_gamma,$pick->($rr,$gg,$bb),$black,$target_gamut);
	 } elsif(defined($step->{"target_linear_r"}) && defined($step->{"target_linear_g"}) && defined($step->{"target_linear_b"})) {
	  $r=clamp($step->{"target_linear_r"}+0,0,1);
	  $g=clamp($step->{"target_linear_g"}+0,0,1);
	  $b=clamp($step->{"target_linear_b"}+0,0,1);
	  return rgb_to_xyz_for_gamut($target_gamut,$r,$g,$b,$pick->($r,$g,$b));
	 } elsif(($step->{"name"}||"") =~ /^Sat\s+([A-Za-z]+)\s+([0-9.]+)%/) {
	  my $color=lc($1);
	  my $sat=clamp(($2+0)/100,0,1);
	  $r=($color eq "red" || $color eq "magenta" || $color eq "yellow") ? $sat : 0;
	  $g=($color eq "green" || $color eq "cyan" || $color eq "yellow") ? $sat : 0;
	  $b=($color eq "blue" || $color eq "cyan" || $color eq "magenta") ? $sat : 0;
	 } else {
	  $r=($step->{"signal_r_pct"}||0)/100;
	  $g=($step->{"signal_g_pct"}||0)/100;
	  $b=($step->{"signal_b_pct"}||0)/100;
	 }
 return target_rgb_to_xyz($r,$g,$b,$target_gamma,$pick->($r,$g,$b),$black,$target_gamut);
}

sub lab_f {
 my $t=shift;
 my $e=216/24389;
 my $k=24389/27;
 return ($t > $e) ? ($t ** (1/3)) : (($k*$t+16)/116);
}

sub xyz_to_lab {
 my ($xyz,$white_y)=@_;
 $white_y=100 if(!defined($white_y) || $white_y <= 0);
 my $xr=($xyz->[0]||0)/(0.95047*$white_y);
 my $yr=($xyz->[1]||0)/$white_y;
 my $zr=($xyz->[2]||0)/(1.08883*$white_y);
 my $fx=lab_f($xr);
 my $fy=lab_f($yr);
 my $fz=lab_f($zr);
 return [116*$fy-16,500*($fx-$fy),200*($fy-$fz)];
}

sub deg2rad { return $_[0]*4*atan2(1,1)/180; }
sub rad2deg { return $_[0]*180/(4*atan2(1,1)); }

sub delta_e_2000 {
 my ($xyz1,$xyz2,$white_y)=@_;
 my $lab1=xyz_to_lab($xyz1,$white_y);
 my $lab2=xyz_to_lab($xyz2,$white_y);
 my ($l1,$a1,$b1)=@{$lab1};
 my ($l2,$a2,$b2)=@{$lab2};
 my $c1=sqrt($a1*$a1+$b1*$b1);
 my $c2=sqrt($a2*$a2+$b2*$b2);
 my $avg_c=($c1+$c2)/2;
 my $avg_c7=$avg_c**7;
 my $g=0.5*(1-sqrt($avg_c7/($avg_c7+25**7)));
 my $a1p=(1+$g)*$a1;
 my $a2p=(1+$g)*$a2;
 my $c1p=sqrt($a1p*$a1p+$b1*$b1);
 my $c2p=sqrt($a2p*$a2p+$b2*$b2);
 my $h1p=($c1p==0) ? 0 : rad2deg(atan2($b1,$a1p));
 my $h2p=($c2p==0) ? 0 : rad2deg(atan2($b2,$a2p));
 $h1p+=360 if($h1p < 0);
 $h2p+=360 if($h2p < 0);
 my $dlp=$l2-$l1;
 my $dcp=$c2p-$c1p;
 my $dhp=0;
 if($c1p*$c2p != 0) {
  my $dh=$h2p-$h1p;
  if(abs($dh) <= 180) { $dhp=$dh; }
  elsif($h2p <= $h1p) { $dhp=$dh+360; }
  else { $dhp=$dh-360; }
 }
 my $dhp_term=2*sqrt($c1p*$c2p)*sin(deg2rad($dhp/2));
 my $avg_lp=($l1+$l2)/2;
 my $avg_cp=($c1p+$c2p)/2;
 my $avg_hp=0;
 if($c1p*$c2p == 0) {
  $avg_hp=$h1p+$h2p;
 } elsif(abs($h1p-$h2p) <= 180) {
  $avg_hp=($h1p+$h2p)/2;
 } elsif($h1p+$h2p < 360) {
  $avg_hp=($h1p+$h2p+360)/2;
 } else {
  $avg_hp=($h1p+$h2p-360)/2;
 }
 my $t=1 - 0.17*cos(deg2rad($avg_hp-30)) + 0.24*cos(deg2rad(2*$avg_hp)) + 0.32*cos(deg2rad(3*$avg_hp+6)) - 0.20*cos(deg2rad(4*$avg_hp-63));
 my $delta_theta=30*exp(-((($avg_hp-275)/25)**2));
 my $avg_cp7=$avg_cp**7;
 my $rc=2*sqrt($avg_cp7/($avg_cp7+25**7));
 my $sl=1+(0.015*(($avg_lp-50)**2))/sqrt(20+(($avg_lp-50)**2));
 my $sc=1+0.045*$avg_cp;
 my $sh=1+0.015*$avg_cp*$t;
 my $rt=-sin(deg2rad(2*$delta_theta))*$rc;
 my $v1=$dlp/$sl;
 my $v2=$dcp/$sc;
 my $v3=$dhp_term/$sh;
 return sqrt($v1*$v1+$v2*$v2+$v3*$v3+$rt*$v2*$v3);
}

sub summarize_post_check {
 my $readings=shift;
 $readings=[] if(ref($readings) ne "ARRAY");
 my @rows=grep { ref($_) eq "HASH" && defined($_->{"delta_e_2000"}) } @{$readings};
 return { count => 0 } if(!@rows);
 my $sum=0;
 my $max=$rows[0];
 foreach my $row (@rows) {
  $sum+=$row->{"delta_e_2000"};
  $max=$row if($row->{"delta_e_2000"} > $max->{"delta_e_2000"});
 }
 return {
  count => scalar(@rows),
  mean_delta_e_2000 => $sum/@rows,
  max_delta_e_2000 => $max->{"delta_e_2000"},
  max_name => $max->{"name"}||"",
 };
}

sub solve_output_rgb {
 my ($model,$target,$ri,$gi,$bi,$size)=@_;
 my $black=$model->{"black"} || [0,0,0];
 my $delta=vec_sub($target,$black);
 my $node_peak=100*(($ri>$gi?$ri:$gi)>$bi ? ($ri>$gi?$ri:$gi) : $bi)/($size-1);
 my $m=matrix_for_level($model,$node_peak);
 my $inv=matrix_inverse($m) || $model->{"peak_inverse"};
 my $lin=matrix_mul_vec($inv,$delta);
 my @pct;
 foreach my $idx (0..2) {
  my $kind=(qw(red green blue))[$idx];
  push @pct,channel_inverse_level($model,$kind,clamp($lin->[$idx],0,1));
 }
 my $max=$pct[0];
 $max=$pct[1] if($pct[1] > $max);
 $max=$pct[2] if($pct[2] > $max);
 if($max > 100) {
  @pct=map { $_*(100/$max) } @pct;
 }
 @pct=map { clamp($_,0,100) } @pct;
 return \@pct;
}

sub drift_matrix_at {
 my ($start,$end,$fraction)=@_;
 $fraction=clamp($fraction,0,1);
 my @cols;
 foreach my $kind (qw(red green blue)) {
  my $s=$start->{$kind} || [0,0,0];
  my $e=$end->{$kind} || $s;
  push @cols,vec_add(vec_scale($s,1-$fraction),vec_scale($e,$fraction));
 }
 return matrix_from_columns($cols[0],$cols[1],$cols[2]);
}

sub apply_drift_correction {
 my ($xyz,$black,$read_time,$drift)=@_;
 return $xyz if(ref($drift) ne "HASH" || !$drift->{"enabled"});
 my $start_t=$drift->{"start_time"} || 0;
 my $end_t=$drift->{"end_time"} || $start_t;
 return $xyz if($end_t <= $start_t);
 my $f=($read_time-$start_t)/($end_t-$start_t);
 my $current=drift_matrix_at($drift->{"start"},$drift->{"end"},$f);
 my $start=drift_matrix_at($drift->{"start"},$drift->{"start"},0);
 my $inv_current=matrix_inverse($current);
 return $xyz if(!$inv_current);
 my $relative=vec_sub($xyz,$black);
 my $corrected=matrix_mul_vec(matrix_mul($start,$inv_current),$relative);
 return vec_add($black,$corrected);
}

sub model_from_readings {
 my ($method,$readings,$config)=@_;
 my $signal_mode=$config->{"signal_mode"}||"sdr";
 my $signal_gamma=sanitize_target_gamma($config->{"target_gamma"},$signal_mode);
 # Solve/encode the cube in the DPG calibration domain (HDR: ~2.2), not the
 # PQ signal EOTF -- see dpg_calibration_gamma(). signal_gamma (st2084 for HDR)
 # is retained only for reporting and the post-cal series reads.
 my $target_gamma=dpg_calibration_gamma($config,$signal_mode,$signal_gamma);
 my $target_gamut=sanitize_target_gamut($config->{"target_gamut"},$signal_mode);
 # The LG BT2020_3D_LUT operates on the BT.2020-decoded signal: we upload an
 # IDENTITY 3x3 gamut matrix (lg_bt2020_identity_3x3_payload in pgenerator-lg),
 # so the cube nodes ARE BT.2020 inputs and MUST be solved in the BT.2020
 # container. Solving in P3 treated BT.2020 inputs as P3 and compressed
 # P3-in-BT.2020 content (~72% of BT.2020) down into P3 -> ~Rec.709 sized
 # (undersaturated, CalMAN-measured). P3 is the panel's achievable gamut and the
 # series SCORING target -- NOT the cube's solve domain.
 $target_gamut="bt2020" if(lc($signal_mode) eq "hdr10");
 my %by;
 foreach my $entry (@{$readings}) {
  next if(ref($entry) ne "HASH");
  my $step=$entry->{"step"} || {};
  my $reading=$entry->{"reading"} || {};
  my $kind=$step->{"kind"} || "";
  my $level=defined($step->{"level"}) ? ($step->{"level"}+0) : undef;
  next if($kind eq "" || !defined($level));
  my $xyz=reading_xyz($reading);
  next if(!$xyz);
  my $phase=$step->{"phase"}||"profile";
  $by{$phase}{$kind}{$level}={ xyz=>$xyz, time=>($entry->{"read_time"}||$reading->{"timestamp"}||time()) };
 }
 my $black=$by{"profile"}{"black"}{0}{xyz} || [0,0,0];
 my $black_y=$black->[1] || 0;
 my $fallback_white=rgb_to_xyz_for_gamut($target_gamut,1,1,1,100);
 my $profile_white=$by{"profile"}{"white"}{100}{xyz} || $fallback_white;
 my $profile_white_y=$profile_white->[1] || 100;
 # Calibration-card Target White / Target Black overrides: anchor the target
 # gamma-curve reference (target_relative_luminance) to the operator's entered
 # white-peak / black-floor instead of the measured profile endpoints. The
 # measured black XYZ and measured white matrix are retained for the physical
 # drift / additive-primary math.
 if(ref($config) eq "HASH") {
  if(defined($config->{"target_white_luminance"}) && !$config->{"target_white_use_measured"} && ($config->{"target_white_luminance"}+0) > 0) {
   $profile_white_y = $config->{"target_white_luminance"}+0;
  }
  if(defined($config->{"target_black_luminance"}) && !$config->{"target_black_use_measured"} && ($config->{"target_black_luminance"}+0) >= 0) {
   $black_y = $config->{"target_black_luminance"}+0;
  }
 }
 my %start; my %end;
 foreach my $kind (qw(white red green blue)) {
  my $sx=$by{"drift_start"}{$kind}{100}{xyz} || $by{"profile"}{$kind}{100}{xyz};
  my $ex=$by{"drift_end"}{$kind}{100}{xyz} || $sx;
  $start{$kind}=vec_sub($sx,$black) if($sx);
  $end{$kind}=vec_sub($ex,$black) if($ex);
 }
 my $drift={
  enabled => ($method eq "ramp" && $by{"drift_end"}{"white"}{100}) ? json_true() : json_false(),
  start => \%start,
  end => \%end,
  start_time => $by{"drift_start"}{"white"}{100}{time} || 0,
  end_time => $by{"drift_end"}{"white"}{100}{time} || 0,
 };
 my %contrib;
 my %white_axis;
 foreach my $level (ramp_levels()) {
  if($level == 0) {
   $white_axis{$level}=$black;
   foreach my $kind (qw(red green blue)) { $contrib{$kind}{$level}=[0,0,0]; }
   next;
  }
  foreach my $kind (qw(red green blue)) {
   my $src=$by{"profile"}{$kind}{$level} || $by{"drift_start"}{$kind}{$level};
   if(!$src && $method eq "matrix") {
    my $peak=$by{"profile"}{$kind}{100};
    my $lin=target_relative_luminance($level/100,$target_gamma,$profile_white_y,$black_y);
    $contrib{$kind}{$level}=vec_scale(vec_sub($peak->{xyz},$black),$lin) if($peak);
    next;
   }
   next if(!$src);
   my $xyz=apply_drift_correction($src->{xyz},$black,$src->{time},$drift);
   $contrib{$kind}{$level}=vec_sub($xyz,$black);
  }
  my $wsrc=$by{"profile"}{"white"}{$level} || $by{"drift_start"}{"white"}{$level};
  if($wsrc) {
   $white_axis{$level}=apply_drift_correction($wsrc->{xyz},$black,$wsrc->{time},$drift);
  } elsif($method eq "matrix") {
   my $peak=$by{"profile"}{"white"}{100};
   my $lin=target_relative_luminance($level/100,$target_gamma,$profile_white_y,$black_y);
   $white_axis{$level}=vec_add($black,vec_scale(vec_sub($peak->{xyz},$black),$lin)) if($peak);
  } else {
   $white_axis{$level}=vec_add($black,vec_add($contrib{"red"}{$level}||[0,0,0],vec_add($contrib{"green"}{$level}||[0,0,0],$contrib{"blue"}{$level}||[0,0,0])));
  }
 }
 my $white100=$white_axis{100} || $by{"profile"}{"white"}{100}{xyz} || $fallback_white;
 my $white_y=$white100->[1] || 100;
 my $peak_matrix=matrix_for_level({
  method=>$method,
  contrib=>\%contrib,
  target_gamma=>$target_gamma,
  black=>$black,
  white_y=>$white_y,
 },100);
 my $peak_inverse=matrix_inverse($peak_matrix);
 $peak_inverse ||= xyz_to_rgb_inverse_for_gamut($target_gamut,$white_y);
 $peak_inverse ||= [
  [ 3.2406/$white_y, -1.5372/$white_y, -0.4986/$white_y ],
  [ -0.9689/$white_y, 1.8758/$white_y, 0.0415/$white_y ],
  [ 0.0557/$white_y, -0.2040/$white_y, 1.0570/$white_y ],
 ];
 my %peak_y;
 foreach my $kind (qw(red green blue)) {
  $peak_y{$kind}=($contrib{$kind}{100} && $contrib{$kind}{100}[1] > 0) ? $contrib{$kind}{100}[1] : 1;
 }
 # Chromatic-node luminance reference (WRGB self-detection).
 # A WRGB OLED forms white largely with a dedicated white sub-pixel, so the
 # measured white (white_y) is brighter than the additive sum of the R+G+B
 # primaries. Chromatic content is produced WITHOUT the white sub-pixel and can
 # only reach that additive sum -- referencing chromatic-node targets to white_y
 # therefore over-drives every sub-saturation node (measured ~1.785x over-target
 # on the C2, the residual positive skew). Reference chromatic targets to the
 # measured additive primary luminance instead. On an additive RGB display white
 # == R+G+B, so add_y == white_y and this is a no-op: the WRGB correction is
 # auto-detected per panel from its own profile, never hardcoded. The neutral
 # axis keeps using white_y (grey IS made with the white sub-pixel).
 my $add_y=0; my $have_primaries=1;
 foreach my $kind (qw(red green blue)) {
  my $py=($contrib{$kind}{100} && $contrib{$kind}{100}[1] > 0) ? $contrib{$kind}{100}[1] : 0;
  $have_primaries=0 if($py <= 0);
  $add_y+=$py;
 }
 my $chromatic_white_y=$white_y;
 my $wrgb_white_ratio=1;
 # Only correct when the additive sum is meaningfully below the measured white
 # (a >2% gap distinguishes a real white sub-pixel from measurement noise on an
 # additive panel where the two are nominally equal).
 if($have_primaries && $add_y > 0 && $add_y < $white_y*0.98) {
  $chromatic_white_y=$add_y;
  $wrgb_white_ratio=$white_y/$add_y;
 }
 my $neutral_neighborhood_identity=neutral_neighborhood_identity_enabled($config);
 return {
  method => $method,
  signal_mode => $signal_mode,
  target_gamma => $target_gamma,
  signal_gamma => $signal_gamma,
  target_gamut => $target_gamut,
  black => $black,
  black_y => $black_y,
  contrib => \%contrib,
  white_axis => \%white_axis,
  white_y => $white_y,
  chromatic_white_y => $chromatic_white_y,
  wrgb_white_ratio => $wrgb_white_ratio,
  gamut_drive_matrix => build_gamut_drive_matrix(\%contrib,$target_gamut,$signal_mode,$target_gamma),
  peak_y => \%peak_y,
  peak_inverse => $peak_inverse,
  drift => $drift,
  neutral_neighborhood_identity_enabled => json_bool($neutral_neighborhood_identity),
  neutral_axis_source => $neutral_neighborhood_identity
   ? "exact diagonal identity plus adjacent neutral-neighborhood identity after current 1D greyscale path"
   : "exact diagonal identity after current 1D greyscale path",
 };
}

sub native_rgb_to_xyz_matrix {
 # White-preserving RGB->XYZ built from the MEASURED native primary
 # chromaticities, normalized so RGB(1,1,1) maps to D65 (the greyscale
 # calibration white). Luminance cancels in the downstream gamut matrix.
 my ($contrib)=@_;
 my @cols;
 foreach my $kind (qw(red green blue)) {
  my $xyz=$contrib->{$kind}{100};
  return undef if(ref($xyz) ne "ARRAY");
  my $sum=($xyz->[0]||0)+($xyz->[1]||0)+($xyz->[2]||0);
  return undef if($sum <= 0);
  push @cols,xy_to_xyz_unit($xyz->[0]/$sum,$xyz->[1]/$sum);
 }
 my $m=matrix_from_columns($cols[0],$cols[1],$cols[2]);
 my $inv=matrix_inverse($m);
 return undef if(!$inv);
 my $w=xy_to_xyz_unit(0.3127,0.3290);
 my $scale=matrix_mul_vec($inv,$w);
 return matrix_from_columns(vec_scale($cols[0],$scale->[0]),vec_scale($cols[1],$scale->[1]),vec_scale($cols[2],$scale->[2]));
}

sub build_gamut_drive_matrix {
 # CalMAN-matching cube build: a WHITE-PRESERVING 3x3 gamut matrix mapping the
 # container primaries (BT.2020) onto the panel's MEASURED native primaries,
 # applied in the DPG calibration gamma domain (2.2 for HDR). Decoded from
 # CalMAN's own C2 cube, out_gamma = M x in_gamma fits to <3 codes RMS and M's
 # rows sum to 1.0 (neutral preserved). Our previous per-node XYZ solve produced
 # a NON-white-preserving matrix (rows summed ~1.08/0.97/0.89) that pushed
 # colours red-up/blue-down as they leave the neutral axis -- the residual
 # saturation-sweep skew. Scoped to HDR with a numeric calibration gamma; SDR
 # keeps the legacy solve (no ground truth to validate a change there).
 my ($contrib,$target_gamut,$signal_mode,$target_gamma)=@_;
 return undef unless(lc($signal_mode||"") =~ /^(hdr10|hlg|dv)$/);
 return undef unless(defined($target_gamma) && ($target_gamma eq "2.2" || $target_gamma eq "2.4"));
 my $m_native=native_rgb_to_xyz_matrix($contrib);
 return undef if(!$m_native);
 my $inv_native=matrix_inverse($m_native);
 return undef if(!$inv_native);
 my $m_target=rgb_to_xyz_matrix_for_gamut($target_gamut);
 return matrix_mul($inv_native,$m_target);
}

sub gamut_matrix_output {
 # Node output via the white-preserving gamut matrix in the calibration gamma
 # domain. Returns per-channel drive PERCENT (0-100), matching solve_output_rgb.
 my ($model,$ri,$gi,$bi,$size)=@_;
 my $M=$model->{"gamut_drive_matrix"};
 my $gamma=$model->{"target_gamma"};
 my $gexp=($gamma eq "2.4") ? 2.4 : 2.2;
 my $lin=[
  target_gamma_linear($ri/($size-1),$gamma),
  target_gamma_linear($gi/($size-1),$gamma),
  target_gamma_linear($bi/($size-1),$gamma),
 ];
 my $out=matrix_mul_vec($M,$lin);
 return [ map { (clamp($_,0,1) ** (1.0/$gexp)) * 100 } @{$out} ];
}

sub generate_lut_cube {
 my ($model,$size)=@_;
 $size ||= 17;
 my @nodes;
 my @u16;
 for(my $r=0;$r<$size;$r++) {
  for(my $g=0;$g<$size;$g++) {
   for(my $b=0;$b<$size;$b++) {
    my $out;
    my $neutral_identity=neutral_identity_output($model,$r,$g,$b,$size);
    if($neutral_identity) {
     $out=$neutral_identity;
    } elsif($model->{"gamut_drive_matrix"}) {
     $out=gamut_matrix_output($model,$r,$g,$b,$size);
    } else {
     my $target=target_xyz_for_node($model,$r,$g,$b,$size);
     $out=solve_output_rgb($model,$target,$r,$g,$b,$size);
    }
    my @v=map { int(clamp($_,0,100)*4095/100+0.5) } @{$out};
    push @u16,@v;
    push @nodes,{ in=>[$r,$g,$b], out_pct=>$out, out_12bit=>\@v } if(@nodes < 16 || ($r==$size-1 && $g==$size-1 && $b==$size-1));
   }
  }
 }
 return (\@u16,\@nodes);
}

sub neutral_identity_output {
 my ($model,$r,$g,$b,$size)=@_;
 my $adjacent=(ref($model) eq "HASH" && $model->{"neutral_neighborhood_identity_enabled"}) ? 1 : 0;
 if(!$adjacent) {
  return undef if(!($r==$g && $g==$b));
 } else {
 my $min=$r;
 $min=$g if($g < $min);
 $min=$b if($b < $min);
 my $max=$r;
 $max=$g if($g > $max);
 $max=$b if($b > $max);
 return undef if(($max-$min) > 1);
 }
 return [
  100*$r/($size-1),
  100*$g/($size-1),
  100*$b/($size-1),
 ];
}

sub generate_lut_lg_payload {
 my ($model,$size)=@_;
 $size ||= 33;
 my @u16;
 for(my $b=0;$b<$size;$b++) {
  for(my $g=0;$g<$size;$g++) {
   for(my $r=0;$r<$size;$r++) {
    my $out;
    my $neutral_identity=neutral_identity_output($model,$r,$g,$b,$size);
    if($neutral_identity) {
     $out=$neutral_identity;
    } elsif($model->{"gamut_drive_matrix"}) {
     $out=gamut_matrix_output($model,$r,$g,$b,$size);
    } else {
     my $target=target_xyz_for_node($model,$r,$g,$b,$size);
     $out=solve_output_rgb($model,$target,$r,$g,$b,$size);
    }
    my @v=map { int(clamp($_,0,100)*4095/100+0.5) } @{$out};
    push @u16,@v;
   }
  }
 }
 return \@u16;
}

sub cube_text {
 my ($u16,$size,$title)=@_;
 my $text="TITLE \"".$title."\"\n";
 $text.="LUT_3D_SIZE $size\n";
 $text.="DOMAIN_MIN 0.0 0.0 0.0\nDOMAIN_MAX 1.0 1.0 1.0\n";
 for(my $i=0;$i<@{$u16};$i+=3) {
  $text.=sprintf("%.9f %.9f %.9f\n",$u16->[$i]/4095,$u16->[$i+1]/4095,$u16->[$i+2]/4095);
 }
 return $text;
}

sub export_lut {
 my ($cube_u16,$payload_u16,$model,$config)=@_;
 my $dir=$config->{"lut_dir"}||"/var/lib/PGenerator/lg/luts";
 my $stamp=strftime("%Y%m%d_%H%M%S",localtime());
 my $method=sanitize_name($model->{"method"}||"ramp");
 my $picture=sanitize_name($config->{"picture_mode"}||"active");
 my ($signal_mode)=sanitize_signal_mode($model->{"signal_mode"}||$config->{"signal_mode"}||"sdr");
 my $gamut=sanitize_target_gamut($model->{"target_gamut"}||$config->{"target_gamut"},$signal_mode);
 my $gamma=sanitize_target_gamma($model->{"signal_gamma"}||$config->{"target_gamma"},$signal_mode);
 my $base="$dir/${stamp}_".sanitize_name($signal_mode)."_${method}_${picture}_".sanitize_name($gamut)."_".sanitize_name($gamma);
 my $title="PGenerator LG ".signal_mode_label($signal_mode)." $method $picture ".target_gamut_label($gamut)." ".target_gamma_label($gamma);
 my $binary=pack("v*",@{$payload_u16});
 write_file("$base.bin",$binary,1) or die "Unable to write LG 3D LUT payload\n";
 write_file("$base.cube",cube_text($cube_u16,17,$title),0) or die "Unable to write cube export\n";
 write_file("$base.json",$json->encode({
  status => "ok",
  method => $method,
  picture_mode => $picture,
  signal_mode => $signal_mode,
  target_gamut => $gamut,
  target_gamma => $gamma,
  title => $title,
  lut_size => 17,
  cube_lut_size => 17,
  payload_lut_size => 33,
  payload_bits => 12,
  payload_endianness => "little-endian uint16",
  payload_axis_order => "R fastest, G middle, B slowest",
  payload_channel_order => "RGB values per node",
  neutral_axis_source => $model->{"neutral_axis_source"},
  neutral_axis_protection => $model->{"neutral_neighborhood_identity_enabled"}
   ? "exact diagonal and adjacent neutral-neighborhood identity"
   : "exact diagonal identity",
  neutral_neighborhood_identity_enabled => json_bool($model->{"neutral_neighborhood_identity_enabled"}),
  lg_generation => (ref($config->{"lg_generation"}) eq "HASH") ? $config->{"lg_generation"} : undef,
  drift => $model->{"drift"},
 }),0);
 return {
  cube_path => "$base.cube",
  payload_path => "$base.bin",
  metadata_path => "$base.json",
  cube_values => scalar(@{$cube_u16}),
  payload_values => scalar(@{$payload_u16}),
  payload_bytes => length($binary),
 };
}

our $lg_low_light_active_mode="off";

# Per-step read deadline for the 3D profile (W/R/G/B at IRE 100, Black at IRE 0).
# Mirrors the IRE-bucketed table in meter_lg_autocal.pl but with the 3D set
# in mind: peak (>=80 IRE) gets the standard 110s, low IRE/black gets the long
# tail so spotread averaging has time to return a clean reading.
sub read_timeout_for_step {
 my ($step,$override)=@_;
 if(defined($override) && $override =~ /^\d+$/ && $override >= 10) {
  return $override+20;
 }
 my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : 100;
 return 240 if($ire <= 5);
 return 210 if($ire <= 10);
 return 180 if($ire <= 25);
 return 150 if($ire <= 50);
 return 120;
}

# Pick the per-read Low Light Handler mode based on the AUTOCAL step's IRE.
# Same hard guards as the 1D worker: IRE >= 80 NEVER engages averaging (peak
# panels can't be averaged meaningfully), IRE < very_low_ire_threshold (default
# 2%) ALWAYS engages the strongest averaging (aaa, 5 reads) so a noise-floor
# black read is reliable. Middle band uses the operator's selected mode if the
# trigger allows it.
sub low_light_mode_for_reading {
 my ($config,$rs)=@_;
 return "off" if(ref($config) ne "HASH" || ref($config->{"low_light"}) ne "HASH" || !$config->{"low_light"}{"enabled"});
 if(ref($rs) eq "HASH") {
  my $step_ire_guard=(defined($rs->{"ire"}) ? ($rs->{"ire"}+0) : (defined($rs->{"stimulus"}) ? ($rs->{"stimulus"}+0) : undef));
  return "off" if(defined($step_ire_guard) && $step_ire_guard+0 >= 80.0);
  my $vlow=($config->{"low_light"}{"very_low_ire_threshold"}//2.0)+0;
  if(defined($step_ire_guard) && $step_ire_guard+0 < $vlow) {
   return "aaa";
  }
 }
 my $mode=lc($config->{"low_light"}{"mode"}||"off");
 return "off" if($mode ne "a" && $mode ne "aa" && $mode ne "aaa");
 return $mode;
}

sub read_request_id {
 my ($step)=@_;
 my $name=$step->{"phase"}."_".$step->{"kind"}."_".format_percent($step->{"level"});
 $name=~s/[^A-Za-z0-9_.-]+/_/g;
 return "autocal3d_".$$."_".int(time()*1000)."_".$name."_".int(rand(1000000));
}

sub read_step_once {
 my ($config,$step)=@_;
 my $delay_ms=int($config->{"delay_ms"}||1000);
 # Settle-delay floor, signal-mode aware -- mirrors the greyscale 1D autocal
 # worker (meter_lg_autocal.pl). HDR10 patches stabilise fast, so a 1800ms
 # floor just leaves the profile patches (W/R/G/B) on screen ~800ms longer per
 # read than the greyscale stage for no accuracy gain. SDR/other keeps 1800ms.
 my $delay_floor=lc($config->{"signal_mode"}||"sdr") eq "hdr10" ? 1000 : 1800;
 $delay_ms=$delay_floor if($delay_ms < $delay_floor);
 my $request_id=read_request_id($step);
 my $payload={
  display_type => $config->{"display_type"}||"lcd",
  patch_r => int($step->{"r"}||0),
  patch_g => int($step->{"g"}||0),
  patch_b => int($step->{"b"}||0),
  ire => $step->{"ire"}+0,
  stimulus => $step->{"stimulus"}+0,
  name => $step->{"name"}||"3D LUT patch",
  signal_r_pct => $step->{"signal_r_pct"}+0,
  signal_g_pct => $step->{"signal_g_pct"}+0,
  signal_b_pct => $step->{"signal_b_pct"}+0,
  patch_size => int($config->{"patch_size"}||10),
  input_max => int($step->{"input_max"}||255),
  delay_ms => $delay_ms,
  signal_range => $config->{"pattern_signal_range"}||$config->{"signal_range"}||"1",
  transport_signal_range => $config->{"transport_signal_range"}||$config->{"signal_range"}||"1",
  signal_mode => $config->{"signal_mode"}||"sdr",
  target_gamma => $config->{"target_gamma"}||"bt1886",
  target_gamut => $config->{"target_gamut"}||"bt709",
  max_luma => $config->{"max_luma"}||1000,
  refresh_rate => $config->{"refresh_rate"}||"",
  measurement_meter_port => $config->{"measurement_meter_port"}||"",
  request_id => $request_id,
  require_device_ready => $config->{"require_device_ready"} ? json_true() : json_false(),
 };
 # Per-step read deadline mirrors the 1D autocal worker: dim/peak buckets are
 # wide so spotread averaging has time to settle without forcing the WebUI to
 # treat the read as stale (default 150s was too short for black-on-OLED).
 my $read_timeout=read_timeout_for_step($step,undef)-20;
 $read_timeout=10 if($read_timeout < 10);
 $read_timeout=300 if($read_timeout > 300);
 $payload->{"read_timeout"}=int($read_timeout);
 # Operator's STATIC low_light config (stable across reads so the session-level
 # METER_AVERAGING does not churn on every per-read flip). When the operator's
 # low_light handler is enabled, the WebUI picks the session-level averaging
 # mode from this field and the per-read low_light field below selects the
 # spotread -Y flag for THIS specific read.
 my $session_ll_mode="off";
 my $session_ll_enabled=json_false();
 if(ref($config->{"low_light"}) eq "HASH" && $config->{"low_light"}{"enabled"}) {
  my $_m=lc($config->{"low_light"}{"mode"}||"off");
  if($_m eq "a" || $_m eq "aa" || $_m eq "aaa" || $_m eq "x" || $_m eq "x_a" || $_m eq "x_aa" || $_m eq "x_aaa") {
   $session_ll_mode=$_m;
   $session_ll_enabled=json_true();
  }
 }
 $payload->{"low_light_session"}={ mode => $session_ll_mode, enabled => $session_ll_enabled };
 # Per-read low_light mode: hard-guarded so the panel-peak profile reads
 # (W/R/G/B at IRE 100) NEVER average, and the noise-floor black read ALWAYS
 # gets the strongest averaging (aaa, 5 reads) regardless of the operator's
 # selected mode. See low_light_mode_for_reading().
 my $active_mode=low_light_mode_for_reading($config,$step);
 $lg_low_light_active_mode=$active_mode;
 if($active_mode ne "off") {
  $payload->{"low_light"}={ mode => $active_mode, enabled => json_true() };
 }
 my $started=time();
 my $start=api_json("POST","/api/meter/read",$payload,55);
 return (undef,$start->{"message"}||"Unable to start meter read") if(($start->{"status"}||"") eq "error");
 my $deadline=time()+read_timeout_for_step($step,$payload->{"read_timeout"});
 while(time() < $deadline) {
  return (undef,"cancelled") if(cancelled());
  my $result=api_json("GET","/api/meter/read/result",undef,10);
  my $status=$result->{"status"}||"";
  if($status eq "ok" && ref($result->{"readings"}) eq "ARRAY" && @{$result->{"readings"}}) {
   next if(($result->{"request_id"}||"") ne "" && ($result->{"request_id"}||"") ne $request_id);
   my $reading=$result->{"readings"}[0];
   next if(($reading->{"request_id"}||"") ne "" && ($reading->{"request_id"}||"") ne $request_id);
   next if(defined($reading->{"timestamp"}) && ($reading->{"timestamp"}+1) < $started);
   $reading->{"name"}=$step->{"name"};
   $reading->{"ire"}=$step->{"ire"};
   $reading->{"stimulus"}=$step->{"stimulus"};
   $reading->{"r_code"}=$step->{"r"};
   $reading->{"g_code"}=$step->{"g"};
   $reading->{"b_code"}=$step->{"b"};
   return ($reading,undef);
  }
  return (undef,$result->{"message"}||"Meter read failed") if($status eq "error");
  sleep(0.35);
 }
 return (undef,"Meter read timed out");
}

sub fixture_reading_for_step {
 my ($step,$config)=@_;
 return undef if(!$config->{"fixture_mode"});
 my $level=($step->{"level"}||0)/100;
 my $white_y=$config->{"fixture_white_y"} || 100;
 my $black_y=$config->{"fixture_black_y"} || 0;
 my $target_gamut=$config->{"target_gamut"}||"bt709";
 $white_y=100 if($white_y <= 0);
 $black_y=0 if($black_y < 0 || $black_y >= $white_y);
 my $range_y=$white_y-$black_y;
 my $black=rgb_to_xyz_for_gamut($target_gamut,1,1,1,$black_y);
 my $gamma=target_relative_luminance($level,$config->{"target_gamma"}||"bt1886",$white_y,$black_y);
 my $kind=$step->{"kind"}||"black";
 my $xyz;
 if($kind eq "black") { $xyz=$black; }
 elsif($kind eq "white") { $xyz=vec_add($black,rgb_to_xyz_for_gamut($target_gamut,$gamma,$gamma,$gamma,$range_y)); }
 elsif($kind eq "red") { $xyz=vec_add($black,rgb_to_xyz_for_gamut($target_gamut,$gamma,0,0,$range_y)); }
 elsif($kind eq "green") { $xyz=vec_add($black,rgb_to_xyz_for_gamut($target_gamut,0,$gamma,0,$range_y)); }
 else { $xyz=vec_add($black,rgb_to_xyz_for_gamut($target_gamut,0,0,$gamma,$range_y)); }
 return { X=>$xyz->[0], Y=>$xyz->[1], Z=>$xyz->[2], x=>0, y=>0, luminance=>$xyz->[1], timestamp=>time() };
}

sub read_step {
 my ($config,$step,$state)=@_;
 my $fixture=fixture_reading_for_step($step,$config);
 if($fixture) {
  $fixture->{"signal_mode"}=$config->{"signal_mode"}||"sdr";
  $fixture->{"target_gamut"}=$config->{"target_gamut"}||"bt709";
  $fixture->{"target_gamma"}=$config->{"target_gamma"}||"bt1886";
  return ($fixture,undef);
 }
 my $attempts=3;
 my $last="";
 for(my $i=1;$i<=$attempts;$i++) {
  my ($reading,$error)=read_step_once($config,$step);
  if(!$error) {
   $reading->{"signal_mode"}=$config->{"signal_mode"}||"sdr";
   $reading->{"target_gamut"}=$config->{"target_gamut"}||"bt709";
   $reading->{"target_gamma"}=$config->{"target_gamma"}||"bt1886";
   return ($reading,undef);
  }
  return (undef,$error) if($error eq "cancelled");
  $last=$error;
  $state->{"message"}="Retrying ".($step->{"name"}||"patch")." ($i/$attempts)";
  write_state($state);
  api_json("POST","/api/meter/session/stop",undef,25) if($error =~ /timeout|session|spotread|unavailable/i);
  sleep(1+$i);
 }
 return (undef,$last||"Meter read failed");
}

sub post_check_steps {
	 my ($config)=@_;
	 my @steps;
	 my $signal_range=$config->{"pattern_signal_range"}||$config->{"signal_range"}||"1";
	 my $target_gamma=$config->{"target_gamma"}||"bt1886";
	 my @cc=(
	  ["Dark Skin",115,82,68],["Light Skin",194,150,130],["Blue Sky",98,122,157],["Foliage",87,108,67],
	  ["Blue Flower",133,128,177],["Bluish Green",103,189,170],["Orange",214,126,44],["Purplish Blue",80,91,166],
	  ["Moderate Red",193,90,99],["Purple",94,60,108],["Yellow Green",157,188,64],["Orange Yellow",224,163,46],
	  ["Blue",56,61,150],["Green",70,148,73],["Red",175,54,60],["Yellow",231,199,31],
  ["Magenta",187,86,149],["Cyan",8,133,161],["White",243,243,242],["Neutral 8",200,200,200],
  ["Neutral 6.5",160,160,160],["Neutral 5",122,122,121],["Neutral 3.5",85,85,85],["Black",52,52,52],
	 );
	 foreach my $c (@cc) {
	  my ($name,$r,$g,$b)=@{$c};
	  push @steps,{
	   kind=>"post", phase=>"post_check", level=>0, name=>"CC24 ".$name, ire=>0, stimulus=>0,
	   signal_r_pct=>$r/255*100, signal_g_pct=>$g/255*100, signal_b_pct=>$b/255*100,
	   r=>patch_code_for_8bit_value($r,$signal_range),
	   g=>patch_code_for_8bit_value($g,$signal_range),
	   b=>patch_code_for_8bit_value($b,$signal_range),
	   target_linear_r=>target_gamma_linear($r/255,$target_gamma),
	   target_linear_g=>target_gamma_linear($g/255,$target_gamma),
	   target_linear_b=>target_gamma_linear($b/255,$target_gamma),
	   input_max=>255
	  };
	 }
	 foreach my $sat (25,50,75,100) {
	  my $c=patch_code_for_percent($sat,$signal_range);
	  my $k=patch_code_for_percent(0,$signal_range);
	  my $linear=target_gamma_linear($sat/100,$target_gamma);
	  my @defs=(
	   ["Red",$c,$k,$k,$linear,0,0],["Green",$k,$c,$k,0,$linear,0],["Blue",$k,$k,$c,0,0,$linear],
	   ["Cyan",$k,$c,$c,0,$linear,$linear],["Magenta",$c,$k,$c,$linear,0,$linear],["Yellow",$c,$c,$k,$linear,$linear,0],
	  );
	  foreach my $d (@defs) {
	   push @steps,{
	    kind=>"post", phase=>"post_check", level=>$sat, name=>"Sat ".$d->[0]." $sat%", ire=>$sat, stimulus=>$sat,
	    signal_r_pct=>($d->[4] > 0 ? $sat : 0), signal_g_pct=>($d->[5] > 0 ? $sat : 0), signal_b_pct=>($d->[6] > 0 ? $sat : 0),
	    r=>$d->[1], g=>$d->[2], b=>$d->[3],
	    target_linear_r=>$d->[4], target_linear_g=>$d->[5], target_linear_b=>$d->[6],
	    input_max=>255
	   };
	  }
	 }
	 return @steps;
}

sub upload_requested {
 my ($config)=@_;
 return ($config->{"upload"} || ($config->{"output"}||"") eq "upload") ? 1 : 0;
}

sub lg_generation_legacy_neutral_guard_enabled {
 my ($generation)=@_;
 return 0 if(ref($generation) ne "HASH");
 return 1 if($generation->{"ddc_only_white_balance"});
 return 1 if($generation->{"picture_mode_read_forbidden"});
 my $year=defined($generation->{"platform_year"}) ? ($generation->{"platform_year"}+0) : 0;
 return 1 if($year && $year <= 2021);
 my $webos_major=defined($generation->{"webos_major"}) ? ($generation->{"webos_major"}+0) : 0;
 return 1 if($webos_major && $webos_major <= 6);
 my $series=uc($generation->{"series"}||"");
 return 1 if($series =~ /^[BCGZ]1$/);
 return 0;
}

sub neutral_neighborhood_identity_enabled {
 my ($config)=@_;
 return 0 if(ref($config) ne "HASH");
 return 1 if($config->{"neutral_neighborhood_identity_enabled"});
 my $generation=(ref($config->{"lg_generation"}) eq "HASH") ? $config->{"lg_generation"} : $config->{"preflight_lg_generation"};
 return lg_generation_legacy_neutral_guard_enabled($generation);
}

sub reset_3d_lut_to_unity_before_profile {
 my ($config,$state)=@_;
 return undef if(!upload_requested($config) || $config->{"fixture_mode"});
 # Full autocal: the greyscale stage already opened CAL_START and uploaded
 # an identity BT2020 gamut + identity 3D LUT container (Step 1 of the
 # Calman-matching flow), and the commit path leaves CAL_START active
 # (Step 2) so this 3D LUT worker inherits it. We MUST NOT open a new
 # CAL_START/CAL_END here -- that would close the greyscale's session
 # and break the post-DPG gamut + 3D LUT rebind the tone map depends on.
 if($config->{"full_workflow"}) {
  my $source=($config->{"skip_preprofile_unity_reset"} && $config->{"preflight_3d_lut_verified"})
   ? "full_autocal_preflight"
   : "full_autocal_greyscale_stage";
  my $reset={
   status => "ok",
   skipped => json_true(),
   upload_verified => json_true(),
   source => $source,
   completed_at => $config->{"preflight_3d_lut_completed_at"}||undef,
   upload_command => $config->{"preflight_3d_lut_upload_command"}||$config->{"upload_command"}||"",
   get_command => $config->{"preflight_3d_lut_get_command"}||$config->{"get_command"}||"",
   lg_generation => (ref($config->{"preflight_lg_generation"}) eq "HASH") ? $config->{"preflight_lg_generation"} : undef,
  };
  $config->{"lg_generation"}=$reset->{"lg_generation"} if(ref($reset->{"lg_generation"}) eq "HASH");
  $state->{"unity_reset"}=$reset;
  $state->{"unity_reset_verified"}=json_true();
  $state->{"upload_supported"}=json_true();
  write_state($state);
  return $reset;
 }
 die "cancelled\n" if(cancelled());
 $state->{"phase"}="unity_reset";
 $state->{"current_step"}=0;
 $state->{"current_name"}="Resetting LG 3D LUT";
 $state->{"message"}="Writing verified unity 3D LUT before profile reads";
 write_state($state);
 my $reset=api_json("POST","/api/lg/3d-lut/reset",{
  picture_mode => $config->{"picture_mode"}||"",
  upload_command => $config->{"upload_command"}||"",
  get_command => $config->{"get_command"}||"",
  helper_timeout => 220,
 },245);
 if(ref($reset) eq "HASH" && ref($reset->{"lg_generation"}) eq "HASH") {
  $config->{"lg_generation"}=$reset->{"lg_generation"};
 }
 $state->{"unity_reset"}=$reset;
 $state->{"unity_reset_verified"}=(ref($reset) eq "HASH" && $reset->{"status"} eq "ok" && $reset->{"upload_verified"}) ? json_true() : json_false();
 $state->{"upload_supported"}=(ref($reset) eq "HASH" && $reset->{"status"} eq "ok") ? json_true() : json_false();
 write_state($state);
 if(ref($reset) ne "HASH" || $reset->{"status"} ne "ok" || !$reset->{"upload_verified"}) {
  my $message=(ref($reset) eq "HASH" && $reset->{"message"}) ? $reset->{"message"} : "LG 3D LUT reset did not verify.";
  die "Unable to reset LG 3D LUT to unity before profiling - $message\n";
 }
 return $reset;
}

my $config=decode_json_safe(read_file($config_file),{});
# Calibration-card Target White / Target Black overrides flow into the
# fixture-mode synthetic readings and the profile target curve.
if(ref($config) eq "HASH") {
 if(defined($config->{"target_white_luminance"}) && !$config->{"target_white_use_measured"} && ($config->{"target_white_luminance"}+0) > 0) {
  $config->{"fixture_white_y"} = $config->{"target_white_luminance"}+0;
 }
 if(defined($config->{"target_black_luminance"}) && !$config->{"target_black_use_measured"} && ($config->{"target_black_luminance"}+0) >= 0) {
  $config->{"fixture_black_y"} = $config->{"target_black_luminance"}+0;
 }
}
unlink($stop_file);
my $method=lc($config->{"method"}||"matrix");
$method="matrix" unless($method eq "matrix" || $method eq "ramp");
my ($signal_mode,$signal_mode_error)=sanitize_signal_mode($config->{"requested_signal_mode"},$config->{"ui_signal_mode"},$config->{"signal_mode"});
$config->{"signal_mode"}=$signal_mode;
$config->{"target_gamut"}=sanitize_target_gamut($config->{"target_gamut"},$signal_mode);
$config->{"target_gamma"}=sanitize_target_gamma($config->{"target_gamma"},$signal_mode);
$config->{"signal_range"}=$config->{"signal_range"}||"1";
$config->{"pattern_signal_range"}=$config->{"pattern_signal_range"}||$config->{"signal_range"}||"1";
$config->{"transport_signal_range"}=$config->{"transport_signal_range"}||$config->{"signal_range"}||"1";
my @steps=($method eq "matrix") ? build_matrix_steps($config) : build_ramp_steps($config);
my $started_at=int(time()*1000);

my $state={
 status => "running",
 autocal3d => json_true(),
 started_at => $started_at,
 method => $method,
 current_step => 0,
 total_steps => scalar(@steps),
 profile_patch_count => ($method eq "ramp" ? 65 : 5),
 current_name => "Preparing LG 3D LUT Auto Cal...",
 message => "Starting",
 readings => [],
 steps => \@steps,
 signal_mode => $config->{"signal_mode"},
 target_gamut => $config->{"target_gamut"},
 target_gamma => $config->{"target_gamma"},
};
if($config->{"full_workflow"}) {
 $state->{"full_workflow"}=json_true();
 $state->{"full_autocal_run_id"}=$config->{"full_autocal_run_id"} if(defined($config->{"full_autocal_run_id"}) && $config->{"full_autocal_run_id"} ne "");
 $state->{"full_autocal_phase"}=$config->{"full_autocal_phase"} if(defined($config->{"full_autocal_phase"}) && $config->{"full_autocal_phase"} ne "");
 $state->{"full_autocal_post_commit_polish"}=json_bool($config->{"full_autocal_post_commit_polish"}) if(exists($config->{"full_autocal_post_commit_polish"}));
 $state->{"full_autocal_magic_wand"}=json_bool($config->{"full_autocal_magic_wand"}) if(exists($config->{"full_autocal_magic_wand"}));
}
write_state($state);
my $upload_requested=upload_requested($config);

eval {
 die "$signal_mode_error\n" if($signal_mode_error);
 die "LG 3D LUT Auto Cal HDR10 runs are matrix-only in this version\n" if($config->{"signal_mode"} eq "hdr10" && $method ne "matrix");
 my $unity_reset=reset_3d_lut_to_unity_before_profile($config,$state);
 my @profile_readings;
 for(my $i=0;$i<@steps;$i++) {
  die "cancelled\n" if(cancelled());
  my $step=$steps[$i];
  $state->{"current_step"}=$i+1;
  $state->{"current_name"}=$step->{"name"};
  my $profile_total=scalar(@steps);
  $state->{"profile_current"}=$i+1;
  $state->{"profile_total"}=$profile_total;
  $state->{"message"}=($method eq "matrix" ? "Matrix profile " : "3D LUT profile ").($i+1)."/".$profile_total." - Reading ".($step->{"name"}||"patch");
  write_state($state);
  my ($reading,$error)=read_step($config,$step,$state);
  die "$error\n" if($error);
  my $entry={ step=>$step, reading=>$reading, read_time=>time() };
  push @profile_readings,$entry if(($step->{"phase"}||"") ne "post_check");
  push @{$state->{"readings"}},{ %{$reading}, name=>$step->{"name"}, phase=>$step->{"phase"}, kind=>$step->{"kind"}, level=>$step->{"level"} };
  write_state($state);
 }

 die "cancelled\n" if(cancelled());
 $state->{"phase"}="building";
 $state->{"current_name"}="Building 3D LUT";
 $state->{"message"}=($method eq "ramp")
  ? "Applying drift correction and solving 17-point cube plus 33-point LG payload"
  : "Solving matrix 17-point cube plus 33-point LG payload";
 write_state($state);

 my $model=model_from_readings($method,\@profile_readings,$config);
 my ($cube_u16,$preview_nodes)=generate_lut_cube($model,17);
 my $payload_u16=generate_lut_lg_payload($model,33);
 my $export=export_lut($cube_u16,$payload_u16,$model,$config);
 $state->{"export"}=$export;
 $state->{"signal_mode"}=$model->{"signal_mode"};
 $state->{"target_gamut"}=$model->{"target_gamut"};
 $state->{"target_gamma"}=$model->{"signal_gamma"}||$model->{"target_gamma"};
 $state->{"lut_solve_gamma"}=$model->{"target_gamma"};
 $state->{"white_y"}=$model->{"white_y"};
 $state->{"chromatic_white_y"}=$model->{"chromatic_white_y"};
 $state->{"wrgb_white_ratio"}=$model->{"wrgb_white_ratio"};
 $state->{"wrgb_compensation_active"}=json_bool(($model->{"wrgb_white_ratio"}||1) > 1.0001);
 $state->{"drift"}=$model->{"drift"};
 $state->{"neutral_axis_source"}=$model->{"neutral_axis_source"};
 $state->{"neutral_neighborhood_identity_enabled"}=json_bool($model->{"neutral_neighborhood_identity_enabled"});
 $state->{"lg_generation"}=$config->{"lg_generation"} if(ref($config->{"lg_generation"}) eq "HASH");
 $state->{"cube_lut_size"}=17;
 $state->{"payload_lut_size"}=33;
 $state->{"payload_bits"}=12;
 $state->{"payload_axis_order"}="R fastest, G middle, B slowest";
 $state->{"payload_channel_order"}="RGB values per node";
 $state->{"lut_preview_nodes"}=$preview_nodes;
 write_state($state);

 if($upload_requested && !$config->{"fixture_mode"}) {
  my $probe=undef;
  if(ref($unity_reset) eq "HASH" && ($unity_reset->{"status"}||"") eq "ok" && $unity_reset->{"upload_verified"}) {
   $probe={
    status => "ok",
    upload_supported => json_true(),
    upload_command => $unity_reset->{"upload_command"}||"",
    get_command => $unity_reset->{"get_command"}||"",
    message => "3D LUT upload path verified by the pre-profile unity reset.",
    reset_to_unity => json_true(),
   };
  } else {
   $state->{"phase"}="upload_probe";
   $state->{"current_name"}="Probing LG 3D LUT upload";
   $state->{"message"}="Round-tripping a unity 33x33x33 payload before upload";
   write_state($state);
   $probe=api_json("POST","/api/lg/3d-lut/probe",{
    picture_mode => $config->{"picture_mode"}||"",
    write_probe => json_true(),
    helper_timeout => 190,
   },210);
  }
   $state->{"upload_probe"}=$probe;
  if(ref($probe) eq "HASH" && $probe->{"status"} eq "ok" && $probe->{"upload_supported"}) {
   $state->{"phase"}="upload";
   $state->{"current_name"}="Uploading LG 3D LUT";
   $state->{"message"}="Writing generated ".signal_mode_label($config->{"signal_mode"})." ".target_gamut_label($config->{"target_gamut"})." 3D LUT";
   $state->{"upload_status"}="requesting";
   $state->{"upload_started_at"}=int(time()*1000);
   my $full_workflow_upload=(ref($config) eq "HASH" && $config->{"full_workflow"}) ? 1 : 0;
   $state->{"upload_request"}={
    picture_mode => $config->{"picture_mode"}||"",
    payload_path => $export->{"payload_path"},
    upload_command => $probe->{"upload_command"}||"",
    get_command => $probe->{"get_command"}||"",
    helper_timeout => 220,
    api_timeout => 240,
    # Full autocal: the greyscale stage already opened CAL_START and uploaded
    # an identity 3D LUT container. We must INHERIT that CAL_START (skip our
    # own CAL_START) and KEEP it active (skip our own CAL_END) so the
    # subsequent tone-map upload can land inside the same session. Calman's
    # HDR OLED DPG flow (relay capture) uses a single CAL_START across the
    # DPG, the 3D LUT, and the tone map -- same pattern.
    ($full_workflow_upload
     ? (keep_calibration_mode=>json_true(),calibration_mode_active=>json_true())
     : ()),
   };
   $state->{"upload_supported"}=json_true();
   log_line("3D LUT upload request start: payload=".($export->{"payload_path"}||"").", upload=".($probe->{"upload_command"}||"").", get=".($probe->{"get_command"}||"").", full_workflow=".($full_workflow_upload?1:0));
   write_state($state);
   my $upload=api_json("POST","/api/lg/3d-lut/upload",$state->{"upload_request"},240);
   $state->{"upload"}=$upload;
   $state->{"upload_completed_at"}=int(time()*1000);
   $state->{"upload_status"}=(ref($upload) eq "HASH" && ($upload->{"status"}||"") ne "") ? ($upload->{"status"}||"") : "invalid-response";
   $state->{"upload_message"}=(ref($upload) eq "HASH") ? ($upload->{"message"}||"") : "";
   $state->{"upload_supported"}=(ref($upload) eq "HASH" && $upload->{"status"} eq "ok") ? json_true() : json_false();
   $state->{"upload_verified"}=(ref($upload) eq "HASH" && $upload->{"upload_verified"}) ? json_true() : json_false();
   $state->{"upload_verify_contract"}=(ref($upload) eq "HASH") ? ($upload->{"upload_verify_contract"}||"") : "";
   $state->{"upload_readback_unavailable"}=(ref($upload) eq "HASH" && $upload->{"readback_unavailable"}) ? json_true() : json_false();
   $state->{"upload_readback_unavailable_reason"}=(ref($upload) eq "HASH") ? ($upload->{"readback_unavailable_reason"}||"") : "";
   my $upload_message=$state->{"upload_message"}||"";
   $state->{"upload_api_timeout"}=($upload_message=~/Web UI API timed out/i) ? json_true() : json_false();
   $state->{"upload_helper_timeout"}=($upload_message=~/did not finish .* within \d+s|timed out/i && $upload_message!~/Web UI API timed out/i) ? json_true() : json_false();
   $state->{"upload_json_error"}=($upload_message=~/Invalid Web UI API response|LG helper execution failed/i) ? json_true() : json_false();
    log_line("3D LUT upload response: status=".($state->{"upload_status"}||"").", verified=".($state->{"upload_verified"}?1:0).", contract=".($state->{"upload_verify_contract"}||"").", readback_unavailable=".($state->{"upload_readback_unavailable"}?1:0).", reason=".($state->{"upload_readback_unavailable_reason"}||"").", message=".$upload_message);
    write_state($state);
    # Full autocal: after the 3D LUT upload, upload the HDR tone map inside
    # the SAME active CAL_START session (the 3D LUT upload used
    # keep_calibration_mode=true). Calman uploads the tone map LAST in its
    # single CAL_START -- the tone map helper sends CAL_END on its own.
    # Source: greyscale stage's hdr20_1d_tonemap_peak_luminance + DPG array
    # (the WebUI passes them through full_workflow_peak_luminance /
    # full_workflow_dpg_data so the 3D worker doesn't have to read the
    # greyscale state file directly).
    if($full_workflow_upload && ($state->{"upload_status"}||"") eq "ok") {
     my $tone_peak=0;
     my $tone_dpg=undef;
     if(ref($config) eq "HASH") {
      if(defined($config->{"full_workflow_peak_luminance"}) && $config->{"full_workflow_peak_luminance"}+0 > 0) {
       $tone_peak=$config->{"full_workflow_peak_luminance"}+0;
      } elsif(defined($config->{"hdr20_1d_tonemap_peak_luminance"}) && $config->{"hdr20_1d_tonemap_peak_luminance"}+0 > 0) {
       $tone_peak=$config->{"hdr20_1d_tonemap_peak_luminance"}+0;
      }
      if(ref($config->{"full_workflow_dpg_data"}) eq "ARRAY" && scalar(@{$config->{"full_workflow_dpg_data"}}) == 3072) {
       $tone_dpg=$config->{"full_workflow_dpg_data"};
      } elsif(ref($config->{"hdr20_1d_dpg_data"}) eq "ARRAY" && scalar(@{$config->{"hdr20_1d_dpg_data"}}) == 3072) {
       $tone_dpg=$config->{"hdr20_1d_dpg_data"};
      }
     }
     if($tone_peak > 0) {
      $state->{"phase"}="tone_map_upload";
      $state->{"current_name"}="Uploading HDR tone map";
      $state->{"message"}="Uploading 1D_TONEMAP_PARAM (peak=".sprintf("%.2f",$tone_peak)." nits) inside the same CAL_START as the 3D LUT";
      write_state($state);
      log_line("3D LUT stage: tone map upload start (peak=".sprintf("%.4f",$tone_peak)." nits, dpg=".((ref($tone_dpg) eq "ARRAY") ? scalar(@{$tone_dpg})." ints" : "none").")");
      my $tone_req={
       picture_mode => $config->{"picture_mode"}||"",
       peak_luminance => $tone_peak+0,
       ddc_layout => "hdr20",
       keep_calibration_mode => json_true(),
       calibration_mode_active => json_true(),
       helper_timeout => 90,
      };
      $tone_req->{"dpg_data"}=$tone_dpg if(ref($tone_dpg) eq "ARRAY");
      my $tone_resp=api_json("POST","/api/lg/hdr-tone-map/upload",$tone_req,105);
      $state->{"tone_map_upload"}=$tone_resp;
      my $tone_status=(ref($tone_resp) eq "HASH") ? ($tone_resp->{status}//"") : "invalid-response";
      my $tone_message=(ref($tone_resp) eq "HASH") ? ($tone_resp->{message}//"") : "";
      $state->{"tone_map_upload_status"}=$tone_status;
      $state->{"tone_map_upload_message"}=$tone_message;
      $state->{"tone_map_uploaded"}=($tone_status eq "ok") ? json_true() : json_false();
      $state->{"tone_map_upload_peak_luminance"}=$tone_peak+0;
      log_line("3D LUT stage: tone map upload response status=".$tone_status.", message=".$tone_message);
      write_state($state);
     } else {
      log_line("3D LUT stage: full_workflow tone map upload skipped -- no peak luminance in config");
      $state->{"tone_map_upload_status"}="skipped";
      $state->{"tone_map_upload_message"}="no peak luminance in 3D worker config";
      $state->{"tone_map_uploaded"}=json_false();
      write_state($state);
     }
    }
   } else {
    $state->{"upload_supported"}=json_false();
    $state->{"message"}="3D LUT upload probe did not verify; export kept";
   }
  }

 if($config->{"post_check"} && !$config->{"fixture_mode"}) {
  my @post=post_check_steps($config);
  $state->{"phase"}="post_check";
  $state->{"post_check_total"}=scalar(@post);
 for(my $i=0;$i<@post;$i++) {
  die "cancelled\n" if(cancelled());
  my $step=$post[$i];
  $state->{"current_step"}=$i+1;
  $state->{"total_steps"}=scalar(@post);
  $state->{"post_check_current"}=$i+1;
  $state->{"current_name"}=$step->{"name"};
  $state->{"message"}="Post-check ".($i+1)."/".scalar(@post);
  write_state($state);
   my ($reading,$error)=read_step($config,$step,$state);
   die "$error\n" if($error);
   my $post_entry={ %{$reading}, name=>$step->{"name"} };
   eval {
   my $measured=reading_xyz($reading);
   my $target=post_check_target_xyz($step,$model->{"white_y"}||100,$model->{"target_gamma"}||$config->{"target_gamma"}||"bt1886",$model->{"black"},$model->{"target_gamut"}||$config->{"target_gamut"}||"bt709",$model->{"chromatic_white_y"});
   $post_entry->{"target_X"}=$target->[0];
   $post_entry->{"target_Y"}=$target->[1];
   $post_entry->{"target_Z"}=$target->[2];
   my $sum=($target->[0]||0)+($target->[1]||0)+($target->[2]||0);
   if($sum > 0 && ($target->[1]||0) > 0) {
    $post_entry->{"target_x"}=$target->[0]/$sum;
    $post_entry->{"target_y"}=$target->[1]/$sum;
    $post_entry->{"target_Yn"}=$target->[1]/($model->{"white_y"}||100);
   }
   $post_entry->{"delta_e_2000"}=delta_e_2000($measured,$target,$model->{"white_y"}||100);
   1;
  };
  if(($step->{"name"}||"") =~ /^Sat\s+([A-Za-z]+)\s+([0-9.]+)%/) {
   $post_entry->{"series_color"}=$1;
   $post_entry->{"sat_pct"}=$2+0;
  }
  $post_entry->{"r_code"}=$step->{"r"};
  $post_entry->{"g_code"}=$step->{"g"};
  $post_entry->{"b_code"}=$step->{"b"};
  $post_entry->{"phase"}="post_check";
  $post_entry->{"kind"}="post";
   push @{$state->{"post_check_readings"}},$post_entry;
   $state->{"post_check_white_y"}=$model->{"white_y"}||100;
   write_state($state);
  }
  $state->{"post_check_summary"}=summarize_post_check($state->{"post_check_readings"});
 }

 $state->{"status"}="complete";
 $state->{"phase"}="complete";
 $state->{"current_name"}="LG 3D LUT Auto Cal complete";
 $state->{"message"}=$state->{"upload_verified"} ? "3D LUT exported, uploaded, and verified" : "3D LUT exported";
 $state->{"completed_at"}=int(time()*1000);
 $state->{"elapsed_ms"}=$state->{"completed_at"}-(($state->{"started_at"}||$state->{"completed_at"})+0);
 $state->{"elapsed_ms"}=0 if($state->{"elapsed_ms"}<0);
 write_state($state);
 1;
} or do {
 my $err=$@ || "LG 3D LUT Auto Cal failed";
 $err=~s/[\r\n]+$//;
 $state->{"status"}=($err =~ /^cancelled$/i) ? "cancelled" : "error";
 $state->{"phase"}=$state->{"status"};
 $state->{"current_name"}=$state->{"status"} eq "cancelled" ? "LG 3D LUT Auto Cal cancelled" : "LG 3D LUT Auto Cal error";
 $state->{"message"}=$state->{"status"} eq "cancelled" ? "3D LUT Auto Cal stopped" : $err;
 write_state($state);
 log_line($err);
};
