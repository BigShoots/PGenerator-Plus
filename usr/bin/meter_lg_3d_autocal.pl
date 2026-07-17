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

our $PGAC_LOADED = 0;
eval { require '/usr/share/PGenerator/PGAutoCalRun.pm'; $PGAC_LOADED = 1; 1 };

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
  cube_axis_order => "R fastest, G middle, B slowest (standard .cube)",
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
 # Never let an unencodable value (scalar/code ref) in $state kill the
 # worker: the error handlers themselves call write_state, so an encode
 # die here cascades straight to process death (seen 2026-07-03: a
 # ref-to-hashref in a pass field killed a full autocal mid-shadow).
 my $encoded;
 eval { $encoded=$json->encode($state); 1; } or do {
  my $err=$@; $err=~s/[\r\n]+/ /g;
  log_line("write_state: state not encodable, writing minimal state: ".$err);
  my %fallback;
  foreach my $k (keys %{$state}) {
   my $v=$state->{$k};
   next if(ref($v) && ref($v) !~ /^(HASH|ARRAY|JSON::PP::Boolean)$/);
   eval { $json->encode({ $k => $v }); $fallback{$k}=$v; 1; } or next;
  }
  $fallback{"state_encode_error"}=$err;
  $encoded=$json->encode(\%fallback);
 };
 return write_file($state_file,$encoded,0);
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

# Bit-depth aware patch code generation: when max_bpc >= 10 (10-bit link),
# the 8-bit codes below would land on a 10-bit wire as ~23% signal (e.g.
# 8-bit 235 / 1023 = 23%), crushing the entire stimulus range. Mirror the
# webui.pm greyscale fix (commit 79b2c2c9): 10-bit Limited = min 64, span 876
# (matches the HDR10 10-bit Limited table: 100% -> 940), 10-bit Full = min 0,
# span 1023 (matches the HDR10 10-bit Full table: 100% -> 1023). Default
# to 8-bit when max_bpc is missing or empty so legacy callers keep their
# existing wire format.
sub patch_code_for_percent {
 my ($pct,$signal_range,$max_bpc)=@_;
 $pct=clamp($pct,0,100);
 my $limited=(!defined($signal_range) || $signal_range eq "" || int($signal_range)==1) ? 1 : 0;
 my $bits=(!defined($max_bpc) || $max_bpc eq "" || int($max_bpc) >= 10) ? 10 : 8;
 if($bits == 10) {
  return $limited ? int(64 + ($pct/100)*876 + 0.5) : int(($pct/100)*1023 + 0.5);
 }
 return $limited ? int(16 + ($pct/100)*219 + 0.5) : int(($pct/100)*255 + 0.5);
}

sub patch_code_for_8bit_value {
 my ($value,$signal_range,$max_bpc)=@_;
 $value=clamp($value,0,255);
 my $limited=(!defined($signal_range) || $signal_range eq "" || int($signal_range)==1) ? 1 : 0;
 my $bits=(!defined($max_bpc) || $max_bpc eq "" || int($max_bpc) >= 10) ? 10 : 8;
 if($bits == 10) {
  return $limited ? int(64 + ($value/255)*876 + 0.5) : int(($value/255)*1023 + 0.5);
 }
 return $limited ? int(16 + ($value/255)*219 + 0.5) : int($value + 0.5);
}

sub patch_step {
 my ($kind,$level,$phase,$config)=@_;
 my $signal_range=$config->{"pattern_signal_range"}||$config->{"signal_range"}||"1";
 my $max_bpc=$config->{"max_bpc"}||"";
 my $code=patch_code_for_percent($level,$signal_range,$max_bpc);
 my $black_code=patch_code_for_percent(0,$signal_range,$max_bpc);
 my %rgb=(r=>$black_code,g=>$black_code,b=>$black_code);
 if($kind eq "white") { %rgb=(r=>$code,g=>$code,b=>$code); }
 elsif($kind eq "red") { $rgb{r}=$code; }
 elsif($kind eq "green") { $rgb{g}=$code; }
 elsif($kind eq "blue") { $rgb{b}=$code; }
 my $name=($phase ? "$phase " : "").uc(substr($kind,0,1))." ".format_percent($level)."%";
 my $input_max=(!defined($max_bpc) || $max_bpc eq "" || int($max_bpc) >= 10) ? 1023 : 255;
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
  input_max => $input_max,
  pattern_signal_range => "$signal_range",
  signal_range => "$signal_range",
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

# Lattice profiling (method=lattice): the client expands the chosen lattice
# series (meterLatticeExpandPatches — corners W,R,G,B,K lead) and posts the
# nodes as percent triplets in lattice_patches. Wire codes are computed HERE
# from this run's range/bit-depth (same rule as patch_step) so the profile
# always matches the live link, exactly like the matrix path. Corner nodes
# get their matrix kinds (white/red/green/blue/black) so model_from_readings'
# corner extraction works unchanged; interior nodes are kind "node" — the
# matrix baseline ignores them and build_residual_grid consumes them, the
# same split run_solve_only uses for the offline lattice solve.
sub build_lattice_steps {
 my ($config)=@_;
 my $patches=$config->{"lattice_patches"};
 return () if(ref($patches) ne "ARRAY" || !@{$patches});
 my $signal_range=$config->{"pattern_signal_range"}||$config->{"signal_range"}||"1";
 my $max_bpc=$config->{"max_bpc"}||"";
 my $input_max=(!defined($max_bpc) || $max_bpc eq "" || int($max_bpc) >= 10) ? 1023 : 255;
 my @steps;
 foreach my $p (@{$patches}) {
  next if(ref($p) ne "HASH");
  my ($pr,$pg,$pb);
  if(defined($p->{"name"}) && $p->{"name"} =~ m{^([0-9.]+)/([0-9.]+)/([0-9.]+)$}) {
   ($pr,$pg,$pb)=($1,$2,$3);
  } elsif(defined($p->{"r_pct"}) && defined($p->{"g_pct"}) && defined($p->{"b_pct"})) {
   ($pr,$pg,$pb)=($p->{"r_pct"},$p->{"g_pct"},$p->{"b_pct"});
  } else {
   next;
  }
  ($pr,$pg,$pb)=map { clamp($_+0,0,100) } ($pr,$pg,$pb);
  last if(@steps >= 2000);
  my $name=format_percent($pr)."/".format_percent($pg)."/".format_percent($pb);
  my $kind="node"; my $level=($pr+$pg+$pb)/3;
  if($pr>=99.9 && $pg>=99.9 && $pb>=99.9) { $kind="white"; $level=100; }
  elsif($pr<=0.1 && $pg<=0.1 && $pb<=0.1) { $kind="black"; $level=0; }
  elsif($pr>=99.9 && $pg<=0.1 && $pb<=0.1) { $kind="red"; $level=100; }
  elsif($pg>=99.9 && $pr<=0.1 && $pb<=0.1) { $kind="green"; $level=100; }
  elsif($pb>=99.9 && $pr<=0.1 && $pg<=0.1) { $kind="blue"; $level=100; }
  push @steps,{
   kind => $kind,
   level => $level+0,
   phase => "profile",
   name => $name,
   ire => int($level+0.5),
   stimulus => $level+0,
   signal_r_pct => $pr+0,
   signal_g_pct => $pg+0,
   signal_b_pct => $pb+0,
   r => patch_code_for_percent($pr,$signal_range,$max_bpc),
   g => patch_code_for_percent($pg,$signal_range,$max_bpc),
   b => patch_code_for_percent($pb,$signal_range,$max_bpc),
   input_max => $input_max,
   pattern_signal_range => "$signal_range",
   signal_range => "$signal_range",
  };
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
 # LG AutoCal solves (matrix/ramp destined for TV upload) run in the LG
 # cal-mode domain: gamma ~2.2 (dpg_calibration_gamma) with the BT.2020
 # container forced below -- the TV linearizes to 2.2 in cal mode and the
 # uploaded identity 3x3 makes the cube's inputs BT.2020. The GENERIC lattice
 # solve (solve_only, any display, export-only) honours the operator's Target
 # Gamma and Target Colorspace selections verbatim instead.
 my $solve_only=(ref($config) eq "HASH" && $config->{"solve_only"}) ? 1 : 0;
 my $target_gamma=$solve_only ? $signal_gamma : dpg_calibration_gamma($config,$signal_mode,$signal_gamma);
 my $target_gamut=sanitize_target_gamut($config->{"target_gamut"},$signal_mode);
 # The LG BT2020_3D_LUT operates on the BT.2020-decoded signal: we upload an
 # IDENTITY 3x3 gamut matrix (lg_bt2020_identity_3x3_payload in pgenerator-lg),
 # so the cube nodes ARE BT.2020 inputs and MUST be solved in the BT.2020
 # container. Solving in P3 treated BT.2020 inputs as P3 and compressed
 # P3-in-BT.2020 content (~72% of BT.2020) down into P3 -> ~Rec.709 sized
 # (undersaturated, per the reference relay capture). P3 is the panel's achievable gamut and the
 # series SCORING target -- NOT the cube's solve domain.
 $target_gamut="bt2020" if(lc($signal_mode) eq "hdr10" && !$solve_only);
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
 # WRGB detection is driven by the operator's selected display technology
 # (the CCSS/display_type choice) FIRST: a WRGB WOLED selection forces the
 # chromatic-white compensation ON so an anomalous white read can never
 # silently suppress it (seen on the C1: a half-peak profile white made
 # add_y ~= white_y and the auto-detect turned the compensation off,
 # mis-referencing every chromatic node). A known-additive selection
 # (QD-OLED, LCD, ...) forces it OFF. Only an unknown/empty display_type
 # falls back to the measured auto-detect (>2% white-vs-sum gap).
 # display_type carries the CCSS selection: builtin keys (oled_generic,
 # qdoled, lcd_wled, ...) or ccss_FILENAME / custom_FILENAME for operator
 # CCSS files -- so matching the string covers ANY wrgb/woled-named CCSS.
 # WRGB match takes precedence over the additive tokens.
 my $display_type=lc((ref($config) eq "HASH" ? ($config->{"display_type"}||"") : ""));
 my $wrgb_force="";
 if($display_type eq "oled_generic" || $display_type =~ /woled|wrgb/) {
  $wrgb_force="wrgb";
 } elsif($display_type =~ /qdoled|qd[-_]oled|lcd|crt|plasma|projector/) {
  $wrgb_force="additive";
 }
 my $wrgb_comp_source="auto";
 if($wrgb_force eq "wrgb" && $have_primaries && $add_y > 0) {
  $chromatic_white_y=$add_y;
  $wrgb_white_ratio=$white_y/$add_y;
  $wrgb_comp_source="ccss_forced_wrgb";
 } elsif($wrgb_force eq "additive") {
  $wrgb_comp_source="ccss_forced_additive";
 } elsif($have_primaries && $add_y > 0 && $add_y < $white_y*0.98) {
  # Auto-detect: only correct when the additive sum is meaningfully below
  # the measured white (a >2% gap distinguishes a real white sub-pixel
  # from measurement noise on an additive panel).
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
  wrgb_comp_source => $wrgb_comp_source,
  # Chromatic LUMINANCE compensation in the gamut-matrix cube path
  # (gamut_matrix_output). OPT-IN ONLY (lg_autocal_3dlut_chroma_luma_comp=1):
  # the mid-saturation-weighted variant measured WORSE on the C1 panel
  # (2026-07-03 A/B) despite matching the chart targets offline -- do not
  # enable by default until the interior model is validated on-panel.
  wrgb_chroma_luma_comp => (($chromatic_white_y < $white_y*0.98)
   && ref($config) eq "HASH" && ($config->{"lg_autocal_3dlut_chroma_luma_comp"}||0)+0) ? 1 : 0,
  wrgb_chroma_luma_comp_strength => (ref($config) eq "HASH" && defined($config->{"lg_autocal_3dlut_chroma_luma_comp_strength"})
   && ($config->{"lg_autocal_3dlut_chroma_luma_comp_strength"}+0) > 0)
   ? ($config->{"lg_autocal_3dlut_chroma_luma_comp_strength"}+0) : 0.8,
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
 # Reference-matching cube build: a WHITE-PRESERVING 3x3 gamut matrix mapping the
 # container primaries (BT.2020) onto the panel's MEASURED native primaries,
 # applied in the DPG calibration gamma domain (2.2 for HDR). Decoded from
 # the reference's own C2 cube, out_gamma = M x in_gamma fits to <3 codes RMS and M's
 # rows sum to 1.0 (neutral preserved). Our previous per-node XYZ solve produced
 # a NON-white-preserving matrix (rows summed ~1.08/0.97/0.89) that pushed
 # colours red-up/blue-down as they leave the neutral axis -- the residual
 # saturation-sweep skew. Covers HDR with a numeric calibration gamma and
 # SDR/bt1886 (pure 2.4 power domain, black=0 in target_gamma_linear): the
 # SDR legacy solve showed the same non-white-preserving rows
 # (1.046/0.989/0.981 on a C2) and the matching interior-patch skew
 # (post-cal Blue Sky lin R +7.5%, G -7.3%).
 my ($contrib,$target_gamut,$signal_mode,$target_gamma)=@_;
 my $mode=lc($signal_mode||"");
 my $gamma=lc($target_gamma//"");
 if($mode eq "sdr") {
  return undef unless($gamma eq "bt1886" || $gamma eq "2.2" || $gamma eq "2.4");
 } else {
  return undef unless($mode =~ /^(hdr10|hlg|dv)$/);
  return undef unless($gamma eq "2.2" || $gamma eq "2.4");
 }
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
 # bt1886 maps to a pure 2.4 power in target_gamma_linear (black=0), so the
 # inverse must be 2.4 as well or the matrix domain would be asymmetric.
 my $gexp=($gamma eq "2.4" || lc($gamma||"") eq "bt1886") ? 2.4 : 2.2;
 my $lin=[
  target_gamma_linear($ri/($size-1),$gamma),
  target_gamma_linear($gi/($size-1),$gamma),
  target_gamma_linear($bi/($size-1),$gamma),
 ];
 my $out=matrix_mul_vec($M,$lin);
 # WRGB chromatic luminance compensation, MID-saturation weighted. The
 # panel's W sub-pixel over-brightens PARTIALLY saturated colors: the
 # neutral axis is DPG-calibrated (no error) and fully saturated colors
 # are made without W (native additive ~= the additive-referenced
 # targets; measured 100% yellow -3%), but interiors engage W partially
 # and measured ~1.3-1.55x over target (C1: CC Yellow +55%, Orange
 # Yellow +53%, Orange +50%). Scale each node's LINEAR output by
 # ratio^(w(sat)*strength) with ratio = chromatic_white_y/white_y
 # (~0.55 C1), sat = (max-min)/max of the node input, and
 # w(sat) = sat^2*(1-sat)*6.75 (0 at both ends, peak 1 at sat=2/3 --
 # rises slowly from neutral so near-neutrals/skin stay untouched).
 # Validated against the measured C1 patches at strength 0.8:
 # CC Yellow 91->57 (tgt ~59), Orange 45->30 (~30), Orange Yellow
 # 67->42 (~44). Equal per-channel scaling preserves chromaticity.
 if($model->{"wrgb_chroma_luma_comp"}) {
  my $wy=$model->{"white_y"}||0;
  my $cw=$model->{"chromatic_white_y"}||0;
  if($wy > 0 && $cw > 0 && $cw < $wy*0.98) {
   my $mx=$ri; $mx=$gi if($gi > $mx); $mx=$bi if($bi > $mx);
   my $mn=$ri; $mn=$gi if($gi < $mn); $mn=$bi if($bi < $mn);
   if($mx > 0 && $mx > $mn) {
    my $sat=($mx-$mn)/$mx;
    my $w=$sat*$sat*(1-$sat)*6.75;
    $w=1 if($w > 1);
    $w=0 if($w < 0);
    my $strength=$model->{"wrgb_chroma_luma_comp_strength"};
    $strength=0.8 if(!defined($strength) || $strength+0 <= 0);
    $strength=$strength+0;
    $strength=1.5 if($strength > 1.5);
    my $scale=($cw/$wy) ** ($w*$strength);
    $out=[ map { $_*$scale } @{$out} ];
   }
  }
 }
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
    $out=apply_residual_correction($model,$out,$r,$g,$b,$size) if(!$neutral_identity && $model->{"residual_grid"});
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
    $out=apply_residual_correction($model,$out,$r,$g,$b,$size) if(!$neutral_identity && $model->{"residual_grid"});
    my @v=map { int(clamp($_,0,100)*4095/100+0.5) } @{$out};
    push @u16,@v;
   }
  }
 }
 return \@u16;
}

# ---- Lattice-cube solve (generic measure -> solve -> export path) ----
# The baseline model comes from the lattice's OWN corners (W/R/G/B/K are
# always measured first) through the proven matrix-method model builder --
# white-preserving gamut matrix, WRGB chromatic-white handling, the lot. The
# residual grid adds bounded, smoothed per-node corrections where the panel's
# measured response deviates from that additive corner model. Residuals are
# signal-domain deltas applied on top of the baseline output at generation
# time via trilinear interpolation over the measured lattice grid.

sub _trl_slope {
 # Numerical d(relative luminance)/d(signal) of the target curve at a signal
 # fraction; floored so near-black residuals cannot explode into huge
 # signal-domain moves (they are noise-dominated anyway).
 my ($f,$gamma,$white_y,$black_y)=@_;
 my $h=0.01;
 my $lo=$f-$h; $lo=0 if($lo < 0);
 my $hi=$f+$h; $hi=1 if($hi > 1);
 my $span=$hi-$lo;
 return 0.05 if($span <= 0);
 my $slope=(target_relative_luminance($hi,$gamma,$white_y,$black_y)
           -target_relative_luminance($lo,$gamma,$white_y,$black_y))/$span;
 return ($slope > 0.05) ? $slope : 0.05;
}

sub build_residual_grid {
 my ($model,$nodes,$config)=@_;
 return (undef,{reason=>"no interior nodes"}) if(ref($nodes) ne "ARRAY" || !@{$nodes});
 my $cap=(ref($config) eq "HASH" && ($config->{"solve_residual_cap"}||0) > 0) ? $config->{"solve_residual_cap"}+0 : 0.06;
 my $gamma=$model->{"target_gamma"};
 my $white_y=$model->{"white_y"}||100;
 my $black_y=$model->{"black_y"}||0;
 my $black=$model->{"black"}||[0,0,0];
 my $contrib=$model->{"contrib"};
 my $peak_inverse=$model->{"peak_inverse"};
 return (undef,{reason=>"no peak inverse"}) if(ref($peak_inverse) ne "ARRAY");
 # Shared frac axis from the measured node positions.
 my %fs;
 foreach my $n (@{$nodes}) { $fs{sprintf("%.4f",$n->{"fr"})}=1; $fs{sprintf("%.4f",$n->{"fg"})}=1; $fs{sprintf("%.4f",$n->{"fb"})}=1; }
 my @fracs=sort { $a <=> $b } map { $_+0 } keys %fs;
 return (undef,{reason=>"lattice too small (".scalar(@fracs)." axis levels)"}) if(scalar(@fracs) < 3);
 my %fidx; for(my $i=0;$i<@fracs;$i++){ $fidx{sprintf("%.4f",$fracs[$i])}=$i; }
 # OPTIONAL noise-floor soft-threshold, default OFF (0). When
 # solve_residual_noise_floor > 0, each drive-delta is shrunk toward zero by a
 # shot-noise-scaled floor (noise_floor * sqrt(white_y/node_y)) so sub-floor
 # deltas vanish. Default 0 applies NO suppression -- every measured per-node
 # correction is used, which is the whole point of a lattice profile. A prior
 # default of 0.020 zeroed the residual on a near-additive panel (lattice
 # collapsed to matrix); that DEFEATED the feature and is reverted.
 my $noise_floor=(ref($config) eq "HASH" && defined($config->{"solve_residual_noise_floor"}) && ($config->{"solve_residual_noise_floor"}+0) >= 0)
  ? $config->{"solve_residual_noise_floor"}+0 : 0.0;
 my %corr; my %raw;
 my ($used,$skipped,$capped,$shrunk)=(0,0,0,0);
 my ($rms_sum,$rms_n,$max_abs,$applied_sum,$applied_n)=(0,0,0,0,0);
 foreach my $n (@{$nodes}) {
  my ($fr,$fg,$fb)=($n->{"fr"},$n->{"fg"},$n->{"fb"});
  my $key=join(":",$fidx{sprintf("%.4f",$fr)},$fidx{sprintf("%.4f",$fg)},$fidx{sprintf("%.4f",$fb)});
  # Corners built the model; exact-neutral nodes ride the identity/greyscale
  # path -- both get zero correction (and anchor the interpolation).
  my $is_corner=(($fr>=0.999&&$fg>=0.999&&$fb>=0.999)||($fr>=0.999&&$fg<=0.001&&$fb<=0.001)
   ||($fr<=0.001&&$fg>=0.999&&$fb<=0.001)||($fr<=0.001&&$fg<=0.001&&$fb>=0.999)
   ||($fr<=0.001&&$fg<=0.001&&$fb<=0.001));
  my $is_neutral=(abs($fr-$fg) < 0.001 && abs($fg-$fb) < 0.001);
  if($is_corner || $is_neutral) { $corr{$key}=[0,0,0]; next; }
  my @lin=map { target_relative_luminance($_,$gamma,$white_y,$black_y) } ($fr,$fg,$fb);
  my $predicted=[ @{$black} ];
  my $ci=0;
  foreach my $kind (qw(red green blue)) {
   my $c=$contrib->{$kind}{100};
   next if(ref($c) ne "ARRAY");
   $predicted=vec_add($predicted,vec_scale($c,$lin[$ci]));
   $ci++;
  }
  if(($predicted->[1]||0) < 0.5) { $skipped++; next; }  # noise-dominated
  my $delta=vec_sub($n->{"xyz"},$predicted);
  my $dlin=matrix_mul_vec($peak_inverse,$delta);
  # Per-node floor scaled by shot noise: dimmer node -> larger floor. node_y is
  # the MEASURED luminance; floored at 1 nit so it cannot explode (dark nodes
  # were already dropped at <0.5 nit above).
  my $node_y=($n->{"xyz"}[1]||0); $node_y=1 if($node_y < 1);
  my $floor=($noise_floor > 0) ? $noise_floor*sqrt($white_y/$node_y) : 0;
  my @c;
  my @f=($fr,$fg,$fb);
  for(my $ch=0;$ch<3;$ch++) {
   my $slope=_trl_slope($f[$ch],$gamma,$white_y,$black_y);
   my $dsig=$dlin->[$ch]/$slope;
   my $a=abs($dsig);
   $rms_sum+=$dsig*$dsig; $rms_n++;
   $max_abs=$a if($a > $max_abs);
   # Soft-threshold toward zero by the per-node floor: kill sub-floor
   # (untrustworthy) deltas outright, keep the excess of larger ones.
   if($floor > 0) {
    if($a <= $floor) { $dsig=0; $shrunk++; }
    else { $dsig=($dsig > 0) ? ($dsig-$floor) : ($dsig+$floor); }
   }
   if(abs($dsig) > $cap) { $dsig=($dsig > 0) ? $cap : -$cap; $capped++; }
   $applied_sum+=$dsig*$dsig; $applied_n++;
   push @c,-$dsig;
  }
  $corr{$key}=\@c;
  $raw{$key}=1;
  $used++;
 }
 return (undef,{reason=>"no usable interior nodes"}) if(!$used);
 # One smoothing pass: blend each corrected node halfway toward the mean of
 # its available 6-neighbours so single-read noise cannot punch spikes into
 # the LUT. Zero-anchored corner/neutral nodes participate as neighbours.
 my %smoothed;
 foreach my $key (keys %corr) {
  next if(!$raw{$key});
  my ($i,$j,$k)=split(/:/,$key);
  my @sum=(0,0,0); my $cnt=0;
  foreach my $d ([1,0,0],[-1,0,0],[0,1,0],[0,-1,0],[0,0,1],[0,0,-1]) {
   my $nk=($i+$d->[0]).":".($j+$d->[1]).":".($k+$d->[2]);
   next if(!exists $corr{$nk});
   for(my $ch=0;$ch<3;$ch++){ $sum[$ch]+=$corr{$nk}[$ch]; }
   $cnt++;
  }
  if($cnt) {
   my $c=$corr{$key};
   $smoothed{$key}=[ map { 0.5*$c->[$_]+0.5*($sum[$_]/$cnt) } (0..2) ];
  }
 }
 foreach my $key (keys %smoothed) { $corr{$key}=$smoothed{$key}; }
 my $report={
  nodes_used => $used,
  nodes_skipped_dark => $skipped,
  channels_capped => $capped,
  channels_shrunk_to_zero => $shrunk,
  residual_cap => $cap,
  residual_noise_floor => $noise_floor,
  residual_signal_rms => $rms_n ? sqrt($rms_sum/$rms_n) : 0,
  residual_signal_max => $max_abs,
  residual_applied_rms => $applied_n ? sqrt($applied_sum/$applied_n) : 0,
  axis_levels => scalar(@fracs),
 };
 return ({ fracs=>\@fracs, corr=>\%corr },$report);
}

sub apply_residual_correction {
 my ($model,$out,$r,$g,$b,$size)=@_;
 my $grid=$model->{"residual_grid"};
 return $out if(ref($grid) ne "HASH");
 my $fracs=$grid->{"fracs"};
 my $corr=$grid->{"corr"};
 my $n=scalar(@{$fracs});
 return $out if($n < 2);
 # The grid lives in DRIVE space: each correction was measured by driving
 # the panel at that lattice node's drives. Interpolate at the drives the
 # baseline solve is about to command ($out, percent) — NOT at the LUT
 # node's input coords. On a near-identity solve the two coincide (which is
 # why the original warp fixture passed); on a real panel the solve moves
 # drives (C2 SDR: input 0.25 -> red drive 0.41) and the input-indexed
 # lookup landed every correction displaced, painting a systematic
 # undersaturation/hue bias across the whole interior. ($r,$g,$b,$size stay
 # in the signature for the call sites; the lookup no longer uses them.)
 my @f=map { my $v=($out->[$_]||0)/100; $v<0?0:($v>1?1:$v) } (0..2);
 my (@lo,@t);
 for(my $ch=0;$ch<3;$ch++) {
  my $f=$f[$ch];
  my $c=0;
  $c++ while($c < $n-2 && $fracs->[$c+1] <= $f);
  my $span=$fracs->[$c+1]-$fracs->[$c];
  my $t=($span > 0) ? (($f-$fracs->[$c])/$span) : 0;
  $t=0 if($t < 0); $t=1 if($t > 1);
  push @lo,$c; push @t,$t;
 }
 my @add=(0,0,0);
 foreach my $di (0,1) { foreach my $dj (0,1) { foreach my $dk (0,1) {
  my $w=($di ? $t[0] : 1-$t[0])*($dj ? $t[1] : 1-$t[1])*($dk ? $t[2] : 1-$t[2]);
  next if($w <= 0);
  my $c=$corr->{($lo[0]+$di).":".($lo[1]+$dj).":".($lo[2]+$dk)};
  next if(ref($c) ne "ARRAY");
  for(my $ch=0;$ch<3;$ch++){ $add[$ch]+=$w*$c->[$ch]; }
 }}}
 return [ map { $out->[$_]+100*$add[$_] } (0..2) ];
}

sub run_solve_only {
 my ($config)=@_;
 my $state={ status=>"running", solve_only=>json_true(), method=>"cube",
  current_name=>"Solving 3D LUT from lattice readings", message=>"Building model",
  started_at=>int(time()*1000) };
 write_state($state);
 my $lattice=$config->{"lattice_readings"};
 $lattice=[] if(ref($lattice) ne "ARRAY");
 my %corner_kind=( "1,1,1"=>"white", "1,0,0"=>"red", "0,1,0"=>"green", "0,0,1"=>"blue", "0,0,0"=>"black" );
 my %corners; my @nodes;
 foreach my $rd (@{$lattice}) {
  next if(ref($rd) ne "HASH");
  my $name=$rd->{"name"}||"";
  next unless($name =~ m{^([0-9.]+)/([0-9.]+)/([0-9.]+)$});
  my ($fr,$fg,$fb)=($1/100,$2/100,$3/100);
  my $xyz=reading_xyz($rd);
  next if(!$xyz && $fr+$fg+$fb > 0.001);
  $xyz ||= [0,0,0];
  my $ck=join(",",map { $_ >= 0.999 ? 1 : ($_ <= 0.001 ? 0 : "x") } ($fr,$fg,$fb));
  $corners{$corner_kind{$ck}}=$xyz if(exists $corner_kind{$ck});
  push @nodes,{ fr=>$fr, fg=>$fg, fb=>$fb, xyz=>$xyz };
 }
 foreach my $need (qw(white red green blue)) {
  if(!$corners{$need}) {
   $state->{"status"}="error";
   $state->{"message"}="Lattice readings are missing the 100% $need corner - measure the full lattice first";
   write_state($state);
   exit 1;
  }
 }
 my @profile;
 foreach my $kind (qw(white red green blue)) {
  push @profile,{ step=>{kind=>$kind,level=>100,phase=>"profile"}, reading=>{X=>$corners{$kind}[0],Y=>$corners{$kind}[1],Z=>$corners{$kind}[2]}, read_time=>time() };
 }
 my $blackc=$corners{"black"}||[0,0,0];
 push @profile,{ step=>{kind=>"black",level=>0,phase=>"profile"}, reading=>{X=>$blackc->[0],Y=>$blackc->[1],Z=>$blackc->[2]}, read_time=>time() };
 my $model=model_from_readings("matrix",\@profile,$config);
 my $solve_report={ mode=>"matrix_only" };
 if(!$config->{"solve_matrix_only"}) {
  my ($grid,$report)=build_residual_grid($model,\@nodes,$config);
  if($grid) {
   $model->{"residual_grid"}=$grid;
   $solve_report={ mode=>"matrix_plus_residuals", %{$report} };
  } else {
   $solve_report={ mode=>"matrix_only", residual_skip_reason=>(ref($report) eq "HASH" ? $report->{"reason"} : "unavailable") };
  }
 }
 $state->{"message"}="Generating LUT";
 $state->{"current_name"}="Generating 3D LUT";
 write_state($state);
 my $cube_size=int($config->{"solve_cube_size"}||33);
 $cube_size=33 unless($cube_size==17 || $cube_size==33 || $cube_size==65);
 my ($cube_u16,$preview_nodes)=generate_lut_cube($model,$cube_size);
 my $payload_u16=generate_lut_lg_payload($model,33);
 $model->{"method"}="cube";
 my $export=export_lut($cube_u16,$payload_u16,$model,$config,$cube_size);
 $state->{"status"}="complete";
 $state->{"message"}="3D LUT solved";
 $state->{"current_name"}="3D LUT solved from ".scalar(@nodes)." lattice readings";
 $state->{"export"}=$export;
 $state->{"solve_report"}=$solve_report;
 $state->{"cube_lut_size"}=$cube_size;
 $state->{"payload_lut_size"}=33;
 $state->{"lattice_nodes"}=scalar(@nodes);
 $state->{"signal_mode"}=$model->{"signal_mode"};
 $state->{"target_gamut"}=$model->{"target_gamut"};
 $state->{"target_gamma"}=$model->{"signal_gamma"}||$model->{"target_gamma"};
 write_state($state);
 log_line("solve_only complete: nodes=".scalar(@nodes)." cube=$cube_size mode=".($solve_report->{"mode"}||""));
 return 1;
}

# ---- Imported-.cube upload path (method=imported) ----
# No profiling, no solve: parse an operator-supplied .cube (saved on the Pi
# by /api/3d-lut/import), trilinearly resample it to the LG 33-point payload
# and a 17-point export cube, then run the standard probe/upload flow.

sub parse_cube_file {
 my ($path)=@_;
 open(my $fh,'<',$path) or die "Unable to read imported .cube: $!\n";
 my $size=0; my @vals;
 while(my $line=<$fh>) {
  next if($line=~/^\s*(?:#|TITLE|DOMAIN_MIN|DOMAIN_MAX|LUT_1D)/);
  if($line=~/^\s*LUT_3D_SIZE\s+(\d+)/) { $size=$1+0; next; }
  push @vals,[$1+0,$2+0,$3+0] if($line=~/^\s*([-0-9.eE]+)\s+([-0-9.eE]+)\s+([-0-9.eE]+)\s*$/);
 }
 close($fh);
 die "Imported .cube missing LUT_3D_SIZE\n" if($size < 2 || $size > 129);
 die "Imported .cube has ".scalar(@vals)." nodes, expected ".($size**3)."\n" if(scalar(@vals) != $size**3);
 # Standard .cube node order: R fastest, B slowest.
 return { size=>$size, values=>\@vals };
}

sub imported_cube_sample {
 my ($cube,$fr,$fg,$fb)=@_;
 my $n=$cube->{"size"};
 my $vals=$cube->{"values"};
 my $axis=sub {
  my ($f)=@_;
  my $x=clamp($f,0,1)*($n-1);
  my $i0=int($x);
  $i0=$n-2 if($i0 >= $n-1);
  return ($i0,$x-$i0);
 };
 my ($r0,$tr)=$axis->($fr);
 my ($g0,$tg)=$axis->($fg);
 my ($b0,$tb)=$axis->($fb);
 my @out=(0,0,0);
 foreach my $db (0,1) { foreach my $dg (0,1) { foreach my $dr (0,1) {
  my $w=($dr ? $tr : 1-$tr)*($dg ? $tg : 1-$tg)*($db ? $tb : 1-$tb);
  next if($w <= 0);
  my $v=$vals->[($r0+$dr)+($g0+$dg)*$n+($b0+$db)*$n*$n];
  for my $c (0..2) { $out[$c]+=$w*$v->[$c]; }
 }}}
 return \@out;
}

sub build_imported_lut {
 my ($config,$state)=@_;
 my $path=$config->{"imported_cube_path"}||"";
 die "Imported .cube path missing\n" if($path eq "");
 die "Imported .cube not found: $path\n" if(!-f $path);
 $state->{"current_name"}="Loading imported 3D LUT";
 $state->{"message"}="Parsing ".$path;
 write_state($state);
 my $cube=parse_cube_file($path);
 my $model={
  method => "imported",
  signal_mode => $config->{"signal_mode"}||"sdr",
  target_gamut => $config->{"target_gamut"}||"bt709",
  target_gamma => $config->{"target_gamma"}||"",
  signal_gamma => $config->{"target_gamma"}||"",
  neutral_axis_source => "imported",
  imported_cube_path => $path,
  imported_cube_size => $cube->{"size"},
 };
 # Export cube (17^3): R-SLOWEST fill to match generate_lut_cube — cube_text
 # emits through a transposed walk and assumes that memory order.
 my @cube_u16;
 my $csize=17;
 for(my $r=0;$r<$csize;$r++) { for(my $g=0;$g<$csize;$g++) { for(my $b=0;$b<$csize;$b++) {
  my $v=imported_cube_sample($cube,$r/($csize-1),$g/($csize-1),$b/($csize-1));
  push @cube_u16,map { int(clamp($_,0,1)*4095+0.5) } @{$v};
 }}}
 # LG payload (33^3): R-FASTEST fill to match generate_lut_lg_payload.
 my @payload_u16;
 my $psize=33;
 for(my $b=0;$b<$psize;$b++) { for(my $g=0;$g<$psize;$g++) { for(my $r=0;$r<$psize;$r++) {
  my $v=imported_cube_sample($cube,$r/($psize-1),$g/($psize-1),$b/($psize-1));
  push @payload_u16,map { int(clamp($_,0,1)*4095+0.5) } @{$v};
 }}}
 log_line("imported cube: path=$path size=".$cube->{"size"}." resampled to cube=$csize payload=$psize");
 return ($model,\@cube_u16,\@payload_u16);
}

sub cube_text {
 my ($u16,$size,$title)=@_;
 my $text="TITLE \"".$title."\"\n";
 $text.="LUT_3D_SIZE $size\n";
 $text.="DOMAIN_MIN 0.0 0.0 0.0\nDOMAIN_MAX 1.0 1.0 1.0\n";
 # Standard .cube node order is RED fastest / BLUE slowest. generate_lut_cube
 # fills @$u16 red-slowest (r outer loop), so emit through a transposed index
 # walk — a straight dump hands external tools an R<->B swapped lattice
 # (neutral axis looks fine, chromatic corrections land on the wrong axes).
 for(my $b=0;$b<$size;$b++) {
  for(my $g=0;$g<$size;$g++) {
   for(my $r=0;$r<$size;$r++) {
    my $i=(($r*$size+$g)*$size+$b)*3;
    $text.=sprintf("%.9f %.9f %.9f\n",$u16->[$i]/4095,$u16->[$i+1]/4095,$u16->[$i+2]/4095);
   }
  }
 }
 return $text;
}

sub export_lut {
 my ($cube_u16,$payload_u16,$model,$config,$cube_size)=@_;
 $cube_size=17 if(!defined($cube_size) || $cube_size !~ /^\d+$/ || $cube_size < 2);
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
 write_file("$base.cube",cube_text($cube_u16,$cube_size,$title),0) or die "Unable to write cube export\n";
 write_file("$base.json",$json->encode({
  status => "ok",
  method => $method,
  picture_mode => $picture,
  signal_mode => $signal_mode,
  target_gamut => $gamut,
  target_gamma => $gamma,
  title => $title,
  lut_size => $cube_size,
  cube_lut_size => $cube_size,
  payload_lut_size => 33,
  payload_bits => 12,
  payload_endianness => "little-endian uint16",
  payload_axis_order => "R fastest, G middle, B slowest",
  payload_channel_order => "RGB values per node",
  cube_axis_order => "R fastest, G middle, B slowest (standard .cube)",
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

# --- Pattern insertion (OLED stabilization) -------------------------
# Ported from usr/bin/meter_lg_autocal.pl: the 1D greyscale worker and
# meter_series.sh both honour the user's Meter Settings insertion knobs
# (grey flash + black reset between reads) to hold the OLED's ABL /
# pixel-charge state steady across long dim-patch sequences. The 3D
# worker's reads (profile patches, shadow-fix anchors, zone probe) ran
# WITHOUT insertion, letting the panel's near-black state drift across
# the loop. Same config keys, same behaviour; the "restore measurement
# patch" step is omitted because /api/meter/read displays the
# measurement patch itself and its delay_ms settle covers the
# black-to-patch transition.
our $_patch_insert_counter=0;
our $_patch_insert_last_time_ts=0;

sub _pi_sanitize_ms {
 my ($raw,$fallback,$max)=@_;
 $fallback//=0; $max//=120000;
 $raw=int($raw//0);
 $raw=$fallback if($raw < 0);
 $raw=$max if($raw > $max);
 return $raw;
}

sub _pi_sanitize_count {
 my ($raw,$fallback,$max)=@_;
 $fallback//=1; $max//=999;
 $raw=int($raw//1);
 $raw=$fallback if($raw < 1);
 $raw=$max if($raw > $max);
 return $raw;
}

sub _patch_insert_code_for_level {
 # Fallback when the webui did not inject precomputed code/input_max
 # pairs (the 3D worker config does not carry them). HDR10 codes must
 # be PQ-encoded so the configured level maps to a visible luminance.
 my ($level_pct,$signal_mode,$max_luma)=@_;
 $level_pct=0 if($level_pct+0 < 0);
 $level_pct=100 if($level_pct+0 > 100);
 $max_luma//=1000;
 if(defined($signal_mode) && lc($signal_mode) eq "hdr10") {
  my $target_nits=($level_pct/100.0)*$max_luma;
  my $pq_signal=pq_encode_normalized($target_nits);
  return int($pq_signal*255.0 + 0.5);
 }
 return int(($level_pct/100.0)*255.0 + 0.5);
}

sub _patch_insert_resolve {
 my ($config,$kind,$level)=@_;
 my $code_key="patch_insert_".$kind."_code";
 my $im_key="patch_insert_".$kind."_input_max";
 if(defined($config->{$code_key}) && $config->{$code_key} ne "") {
  my $im=int($config->{$im_key} // 255);
  $im=255 if($im <= 0);
  return (int($config->{$code_key}+0),$im);
 }
 return (_patch_insert_code_for_level($level,$config->{"signal_mode"},$config->{"max_luma"}),255);
}

sub apply_pattern_insert_before_read {
 my ($config,$step)=@_;
 return undef if(ref($config) ne "HASH" || !$config->{"patch_insert"});
 my $pattern_range=$config->{"pattern_signal_range"}||$config->{"signal_range"}||"";
 my $transport_range=$config->{"transport_signal_range"}||$config->{"signal_range"}||"";
 my $patch_enabled=$config->{"patch_insert_patch_enabled"} ? 1 : 0;
 my $patch_every=_pi_sanitize_count($config->{"patch_insert_patch_every"},1,999);
 my $patch_duration_ms=_pi_sanitize_ms($config->{"patch_insert_patch_duration_ms"},1000,30000);
 my $patch_level=($config->{"patch_insert_patch_level"}//10)+0;
 my $time_enabled=$config->{"patch_insert_time_enabled"} ? 1 : 0;
 # Same 15s frequency cap as the 1D worker's inner loops: the shadow
 # fix reads 6 anchors back-to-back per pass and needs insertions
 # BETWEEN anchors, not once per wizard step.
 my $_time_freq_max=15000;
 $_time_freq_max=int($config->{"patch_insert_time_frequency_max_ms"}) if(defined($config->{"patch_insert_time_frequency_max_ms"}) && $config->{"patch_insert_time_frequency_max_ms"}+0 == 0);
 my $time_frequency_ms=_pi_sanitize_ms($config->{"patch_insert_time_frequency_ms"},5000,120000);
 $time_frequency_ms=$_time_freq_max if($time_frequency_ms+0 > $_time_freq_max+0 && $_time_freq_max+0 > 0);
 my $time_duration_ms=_pi_sanitize_ms($config->{"patch_insert_time_duration_ms"},5000,30000);
 my $time_level=($config->{"patch_insert_time_level"}//25)+0;
 my @inserts;
 my $now=int(time()*1000);
 if($time_enabled && ($_patch_insert_last_time_ts == 0 || ($now - $_patch_insert_last_time_ts) >= $time_frequency_ms)) {
  push @inserts,{ level => $time_level, duration_ms => $time_duration_ms, reason => "time", kind => "time" };
  $_patch_insert_last_time_ts=$now;
 }
 if($patch_enabled) {
  $_patch_insert_counter++;
  if(($_patch_insert_counter % $patch_every) == 0) {
   push @inserts,{ level => $patch_level, duration_ms => $patch_duration_ms, reason => "patch", kind => "patch" };
  }
 }
 return undef unless(@inserts);
 my $base_payload={
  name => "patch",
  size => 100,
  input_max => 255,
  signal_mode => $config->{"signal_mode"}||"sdr",
  max_luma => $config->{"max_luma"}||1000,
  # The meter session arms /tmp/webui_pattern_stop_guard during reads;
  # without allow_after_stop the renderer silently replaces the
  # insertion patch with "stop" and the flash never displays.
  allow_after_stop => json_true(),
 };
 $base_payload->{"signal_range"}=$pattern_range if($pattern_range ne "");
 $base_payload->{"transport_signal_range"}=$transport_range if($transport_range ne "");
 for my $ins (@inserts) {
  my ($code,$input_max)=_patch_insert_resolve($config,$ins->{"kind"},$ins->{"level"});
  my $dur_s=$ins->{"duration_ms"}/1000.0;
  log_line(($config->{"signal_mode"}||"sdr")." pattern insertion: reason=$ins->{reason} level=$ins->{level}% code=$code input_max=$input_max duration=".sprintf("%.3f",$dur_s)."s");
  my $insert_payload={%{$base_payload},input_max=>$input_max,r=>(0+$code),g=>(0+$code),b=>(0+$code)};
  my $insert_result=api_json("POST","/api/pattern",$insert_payload,10);
  return $insert_result->{"message"}||"Unable to display pattern insertion patch" if(($insert_result->{"status"}||"") eq "error");
  select(undef,undef,undef,$dur_s);
  # Black reset between the flash and the measurement patch.
  my $black_payload={%{$base_payload},input_max=>$input_max,r=>0,g=>0,b=>0};
  my $black_result=api_json("POST","/api/pattern",$black_payload,10);
  return $black_result->{"message"}||"Unable to display black insertion patch" if(($black_result->{"status"}||"") eq "error");
  select(undef,undef,undef,0.5);
 }
 return undef;
}
# ---------------------------------------------------------------------

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
   reset_meter_session_success();
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
 if($kind eq "node") {
  # Lattice interior node: ideal additive display in the target gamut —
  # per-channel gamma-decoded drives. Makes the lattice-profiled solve's
  # residual grid ~zero in fixture mode (identity gate, like solve_only's).
  my $chan=sub { target_relative_luminance(clamp(($_[0]||0)/100,0,1),$config->{"target_gamma"}||"bt1886",$white_y,$black_y) };
  $xyz=vec_add($black,rgb_to_xyz_for_gamut($target_gamut,
   $chan->($step->{"signal_r_pct"}),$chan->($step->{"signal_g_pct"}),$chan->($step->{"signal_b_pct"}),$range_y));
 }
 elsif($kind eq "black") { $xyz=$black; }
 elsif($kind eq "white") { $xyz=vec_add($black,rgb_to_xyz_for_gamut($target_gamut,$gamma,$gamma,$gamma,$range_y)); }
 elsif($kind eq "red") { $xyz=vec_add($black,rgb_to_xyz_for_gamut($target_gamut,$gamma,0,0,$range_y)); }
 elsif($kind eq "green") { $xyz=vec_add($black,rgb_to_xyz_for_gamut($target_gamut,0,$gamma,0,$range_y)); }
 else { $xyz=vec_add($black,rgb_to_xyz_for_gamut($target_gamut,0,0,$gamma,$range_y)); }
 return { X=>$xyz->[0], Y=>$xyz->[1], Z=>$xyz->[2], x=>0, y=>0, luminance=>$xyz->[1], timestamp=>time() };
}

# Consecutive-transient-failure counter for the meter session (mirrors the
# greyscale worker's logic). A single read timeout is usually a poll hiccup
# that clears by re-reading on the EXISTING spotread session. Tearing the
# session down (/api/meter/session/stop) forces a fresh spotread to reopen +
# reclaim the i1Display3 USB interface, and that reopen races the kernel/usbhid
# state ("did not claim interface 0 before use") -> kernel device reset -> meter
# offline -> WebUI drops. So only tear down after repeated consecutive transient
# failures, not the first one. Reset to 0 on any successful read.
my $_meter_session_consecutive_transient_failures=0;
my $_METER_SESSION_TEARDOWN_THRESHOLD=2;

sub reset_meter_session_success {
 $_meter_session_consecutive_transient_failures=0;
}

sub maybe_reset_meter_session_after_read_error {
 my ($error)=@_;
 $error="" if(!defined($error));
 $error=~s/[\r\n]+/ /g;
 return unless($error =~ /timeout|session|spotread|unavailable/i);
 $_meter_session_consecutive_transient_failures++;
 if($_meter_session_consecutive_transient_failures < $_METER_SESSION_TEARDOWN_THRESHOLD) {
  log_line("Transient meter read error (attempt $_meter_session_consecutive_transient_failures/$_METER_SESSION_TEARDOWN_THRESHOLD), keeping session for retry: $error");
  return;
 }
 log_line("Resetting meter session after $_meter_session_consecutive_transient_failures consecutive transient read errors: $error");
 api_json("POST","/api/meter/session/stop",undef,25);
 $_meter_session_consecutive_transient_failures=0;
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
 # OLED stabilization per the user's Meter Settings insertion knobs --
 # once per logical read (not per retry attempt).
 my $insert_error=apply_pattern_insert_before_read($config,$step);
 log_line("pattern insertion failed (continuing to read): ".$insert_error) if(defined($insert_error));
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
  maybe_reset_meter_session_after_read_error($error);
  sleep(1+$i);
 }
 return (undef,$last||"Meter read failed");
}

sub post_check_steps {
	 my ($config)=@_;
	 my @steps;
	 my $signal_range=$config->{"pattern_signal_range"}||$config->{"signal_range"}||"1";
	 my $target_gamma=$config->{"target_gamma"}||"bt1886";
	 my $max_bpc=$config->{"max_bpc"}||"";
	 my $input_max=(!defined($max_bpc) || $max_bpc eq "" || int($max_bpc) >= 10) ? 1023 : 255;
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
	   r=>patch_code_for_8bit_value($r,$signal_range,$max_bpc),
	   g=>patch_code_for_8bit_value($g,$signal_range,$max_bpc),
	   b=>patch_code_for_8bit_value($b,$signal_range,$max_bpc),
	   target_linear_r=>target_gamma_linear($r/255,$target_gamma),
	   target_linear_g=>target_gamma_linear($g/255,$target_gamma),
	   target_linear_b=>target_gamma_linear($b/255,$target_gamma),
	   input_max=>$input_max
	  };
	 }
	 foreach my $sat (25,50,75,100) {
	  my $c=patch_code_for_percent($sat,$signal_range,$max_bpc);
	  my $k=patch_code_for_percent(0,$signal_range,$max_bpc);
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
	    input_max=>$input_max
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
 # Reference-matching flow), and the commit path leaves CAL_START active
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

# --- HDR20 post-cal shadow correction (PQ EOTF + ICtCp delta-E) ---
# Ported from usr/bin/meter_lg_autocal.pl (pq_encode_normalized +
# xyz_to_ictcp + delta_e_itp_xyz). Used to compute a ΔE(ITP) for the 5%
# grey probe so revert-if-worse has a perceptually uniform comparator
# instead of a luminance-only one.
sub pq_encode_normalized {
 my ($nits)=@_;
 $nits=0 if(!defined($nits));
 $nits+=0;
 return 0 if($nits <= 0);
 $nits=10000 if($nits > 10000);
 my $l=$nits/10000;
 my $m1=2610/16384;
 my $m2=2523/32;
 my $c1=3424/4096;
 my $c2=2413/128;
 my $c3=2392/128;
 my $p=$l ** $m1;
 return (($c1+$c2*$p)/(1+$c3*$p)) ** $m2;
}

sub xyz_to_ictcp {
 my ($X,$Y,$Z)=@_;
 $X=0 if(!defined($X)); $Y=0 if(!defined($Y)); $Z=0 if(!defined($Z));
 my $R= 1.7166511880*$X -0.3556707838*$Y -0.2533662814*$Z;
 my $G=-0.6666843518*$X +1.6164812366*$Y +0.0157685458*$Z;
 my $B= 0.0176398574*$X -0.0427706133*$Y +0.9421031212*$Z;
 $R=0 if($R < 0); $G=0 if($G < 0); $B=0 if($B < 0);
 my $L=(1688*$R+2146*$G+262*$B)/4096;
 my $M=(683*$R+2951*$G+462*$B)/4096;
 my $S=(99*$R+309*$G+3688*$B)/4096;
 my $Lp=pq_encode_normalized($L);
 my $Mp=pq_encode_normalized($M);
 my $Sp=pq_encode_normalized($S);
 return {
  I=>0.5*$Lp+0.5*$Mp,
  T=>(6610*$Lp-13613*$Mp+7003*$Sp)/4096,
  P=>(17933*$Lp-17390*$Mp-543*$Sp)/4096
 };
}

sub delta_e_itp_xyz {
 my ($X1,$Y1,$Z1,$X2,$Y2,$Z2)=@_;
 return undef if(!defined($X1) || !defined($Y1) || !defined($Z1) || !defined($X2) || !defined($Y2) || !defined($Z2));
 my $a=xyz_to_ictcp($X1,$Y1,$Z1);
 my $b=xyz_to_ictcp($X2,$Y2,$Z2);
 my $dI=$a->{"I"}-$b->{"I"};
 my $dT=$a->{"T"}-$b->{"T"};
 my $dP=$a->{"P"}-$b->{"P"};
 return 720*sqrt($dI*$dI+0.25*$dT*$dT+$dP*$dP);
}

# Taper for the HDR20 post-cal shadow correction. 0 at index 0 (true
# black pinned); linear 0->1 for 0 < i < 14 (ramp up from black;
# protects sub-1.4% IRE); 1.0 for 14 <= i <= band_top; linear 1->0 for
# band_top < i <= taper_top (tapering back to 0); 0 beyond taper_top.
# band_top / taper_top are 1024-point DPG-domain indices mapping to
# the spec's band_top_ire / taper_top_ire knobs (defaults 25 / 30 IRE
# -> indices 257 / 308). The band START is fixed at idx 14 (1.4% IRE)
# -- that anchor is a hard constraint of the HDR20 26-pt ladder and
# must not move with the band/taper knobs.
sub hdr20_postcal_taper {
 my ($i,$band_top,$taper_top)=@_;
 $band_top=257 if(!defined($band_top) || $band_top+0 <= 0);
 $band_top=$band_top+0;
 $taper_top=308 if(!defined($taper_top) || $taper_top+0 <= 0);
 $taper_top=$taper_top+0;
 $i=int($i+0) if(defined($i));
 return 0 if(!defined($i) || $i <= 0);
 return 0 if($i > $taper_top);
 my $band_start=14;
 if($i < $band_start) { return ($i+0)/$band_start; }
 if($i <= $band_top) { return 1.0; }
 my $denom=$taper_top-$band_top;
 return ($denom <= 0) ? 0 : (1.0 - (($i-$band_top)+0)/$denom);
}

# Build the corrected 3x1024 DPG array from the committed base + magnitude
# M (in DPG counts, luminance-neutral: same subtraction on R, G, B).
# DPG_base is the array the 3D worker received from the WebUI in
# full_workflow_dpg_data (or hdr20_1d_dpg_data). The output keeps the
# base's index 0 = 0 (true black pinned) and stays ascending by the
# caller's choice of monotone-clamp afterwards.
sub hdr20_postcal_apply_correction {
 # DPG_base is the planar 3072-element array committed by the worker:
 # R = [0..1023], G = [1024..2047], B = [2048..3071]. This matches the
 # identity build in usr/sbin/pgenerator-lg (channel-major push) and the
 # readback checks that key off my $base = $channel*1024.
 # Apply the same magnitude `sub` to R/G/B (luminance-neutral) and
 # return a NEW 3072-element planar array; do not mutate the input.
 # The loop walks channel-major so the output ordering matches the
 # spec: out[0..1023] = R block, out[1024..2047] = G block,
 # out[2048..3071] = B block. The taper is per-index `k` (a single
 # channel-independent shadow band), so we compute `sub` once per k and
 # apply it to all three channels.
 my ($dpg_base,$M,$band_top,$taper_top)=@_;
 return undef if(ref($dpg_base) ne "ARRAY" || scalar(@{$dpg_base}) != 3072);
 $M=0 if(!defined($M));
 $M=$M+0;
 my @out=(0) x 3072;
 for(my $channel=0;$channel<3;$channel++) {
  my $base=$channel*1024;
  for(my $k=0;$k<1024;$k++) {
   my $t=($k == 0) ? 0 : hdr20_postcal_taper($k,$band_top,$taper_top);
   my $sub=int($M*$t+0.5);
   my $v=$dpg_base->[$base+$k]-$sub;
   $v=0 if($v < 0);
   $out[$base+$k]=$v;
  }
 }
 # Pin true black at index 0 of EACH channel block.
 $out[0]=0;
 $out[1024]=0;
 $out[2048]=0;
 return \@out;
}

# Monotone-clamp each channel block of a planar 3072-element DPG
# array ascending, floor at 0, and pin block index 0 = 0 (true black).
# Block layout: R = [0..1023], G = [1024..2047], B = [2048..3071].
# Each channel's ascending walk resets at its own block boundary -- the
# "previous" value MUST NOT cross channel boundaries (B[0] must not be
# forced >= R[1023]). Returns a NEW array; does not mutate the input.
sub hdr20_postcal_monotone_clamp {
 my ($dpg)=@_;
 return undef if(ref($dpg) ne "ARRAY" || scalar(@{$dpg}) != 3072);
 my @out=(0) x 3072;
 for(my $channel=0;$channel<3;$channel++) {
  my $base=$channel*1024;
  my $prev=0;
  for(my $k=0;$k<1024;$k++) {
   my $v=$dpg->[$base+$k]+0;
   $v=0 if($k == 0);
   $v=0 if($v < 0);
   if($k > 0 && $v < $prev) { $v=$prev; }
   $out[$base+$k]=$v;
   $prev=$v;
  }
 }
 return \@out;
}

# Build the corrected 3x1024 DPG array from the committed base + a list
# of per-anchor counts. Replaces the single-M flat-taper
# (hdr20_postcal_apply_correction) approach with a PER-ANCHOR piecewise
# correction: each anchor's measured lift drives its OWN magnitude of
# roll-down, so mids don't get over-corrected when only the 5% anchor
# was lifted. Luminance-neutral: same sub on R, G, B (PQ-lifted panels
# typically lift all three channels uniformly).
#
# Shape (per DPG index k):
#   k = 0            -> 0  (true black pinned)
#   0 < k < 14       -> ramp from 0 up to c0 over k=0..14
#                      (smooth rise from black to the 1.4%-onward plateau)
#   14 <= k <= 51    -> c0 (1.4%..5% plateau at the first/5% anchor count)
#   51 < k <= 103    -> linear interp c0..c1 (between first and second anchors)
#   ...between any two anchors a..b, linear interp ca..cb...
#   lastIdx < k <= lastIdx+51 -> ramp cl down to 0
#                                 (257 < k <= 308: smooth fall from the last
#                                  anchor's count back to zero)
#   k > lastIdx+51   -> 0  (no correction above ~30% IRE)
#
# $anchors is an arrayref of [dpg_index, counts] pairs, sorted ascending
# by index, counts >= 0. The DPG base and output are planar
# channel-major: R = [0..1023], G = [1024..2047], B = [2048..3071].
# After this returns, the caller MUST run hdr20_postcal_monotone_clamp
# to enforce ascending-by-channel and pin true black.
sub hdr20_postcal_apply_profile {
 my ($dpg_base,$anchors)=@_;
 return undef if(ref($dpg_base) ne "ARRAY" || scalar(@{$dpg_base}) != 3072);
 return undef if(ref($anchors) ne "ARRAY" || scalar(@{$anchors}) == 0);
 # Normalize: drop malformed entries (not arrayref, bad index/counts),
 # floor counts at 0 (pull-DOWN only -- a sub-zero count would lift the
 # band, which the design rejects). Sort ascending by dpg index.
 my @sorted;
 for my $entry (@{$anchors}) {
  next if(ref($entry) ne "ARRAY" || scalar(@{$entry}) < 2);
  my $idx=$entry->[0];
  next if(!defined($idx) || $idx+0 < 0);
  my $cnt=$entry->[1];
  next if(!defined($cnt));
  $cnt=$cnt+0;
  $cnt=0 if($cnt < 0);
  push @sorted, [$idx+0,$cnt];
 }
 @sorted=sort { $a->[0] <=> $b->[0] } @sorted;
 return undef if(scalar(@sorted) == 0);
 my $first_idx=$sorted[0]->[0];
 my $last_idx=$sorted[-1]->[0];
 my $first_count=$sorted[0]->[1];
 my $last_count=$sorted[-1]->[1];
 # Ramp-out end-index (lastIdx + 51): beyond this is untouched.
 my $ramp_end=$last_idx+51;
 # Edge cases: first_idx==0 -> no leading ramp. first_idx==14 -> ramp
 # from 0 to first_count over k=1..14. first_idx<14 is also handled
 # (the ramp formula clamps at 0 below first_idx).
 my $leading_ramp_end=14;
 $leading_ramp_end=$first_idx if($first_idx < $leading_ramp_end);
 # Per-index correction: walk k=0..1023, compute counts_at(k), subtract
 # from each channel's block at index k.
 my @out=(0) x 3072;
 for(my $k=0;$k<1024;$k++) {
  my $ck=0;
  if($k <= 0) {
   $ck=0;
  } elsif($k > $ramp_end) {
   $ck=0;
  } elsif($k < $leading_ramp_end) {
   # Ramp from 0 at k=0 (k=1 below) up to first_count at k=leading_ramp_end.
   # ck = first_count * k / leading_ramp_end. With leading_ramp_end=14
   # this gives 0 at k=0 and first_count at k=14.
   $ck=$first_count * ($k+0) / ($leading_ramp_end+0);
  } elsif($k <= $first_idx) {
   # Plateau at first_count from leading_ramp_end up to first_idx.
   $ck=$first_count;
  } elsif($k > $last_idx) {
   # Ramp from last_count at k=last_idx+1 down to 0 at k=ramp_end.
   # Note: k > $last_idx but k <= $ramp_end so we are on the tail.
   $ck=$last_count * (($ramp_end - $k)+0) / ($ramp_end - $last_idx);
  } else {
   # Between two anchors a..b: linear interpolate ca..cb.
   # Find the anchor pair that brackets k.
   my $ca=$first_count;
   my $cb=$first_count;
   my $ia=$first_idx;
   my $ib=$first_idx;
   for(my $j=0;$j<scalar(@sorted)-1;$j++) {
    my $a=$sorted[$j]->[0];
    my $b=$sorted[$j+1]->[0];
    if($k >= $a && $k <= $b) {
     $ia=$a; $ib=$b;
     $ca=$sorted[$j]->[1];
     $cb=$sorted[$j+1]->[1];
     last;
    }
   }
   if($ib == $ia) {
    $ck=$ca;
   } else {
    $ck=$ca + ($cb - $ca) * (($k - $ia)+0) / ($ib - $ia);
   }
  }
  # Floor counts at 0 (pull-down only). The piecewise shape is non-
  # negative everywhere, but clamp defensively.
  $ck=0 if($ck < 0);
  # RATIO-PRESERVING subtraction: the greyscale cal leaves the three
  # channel curves deliberately unequal in the shadow band (grey
  # balance -- e.g. B ~13% under G on the C1), so subtracting the SAME
  # count from R/G/B cuts the smallest channel proportionally hardest
  # and skews post-cal chroma (measured: equal-count trim moved B:G at
  # idx 26 from 0.867 to 0.848 => 5% grey went yellow while cal-time
  # chroma read clean). Scale each channel's subtraction by its share
  # of the local channel mean instead: same total roll-down, R:G:B
  # ratio (and therefore the calibrated grey balance) preserved.
  my $mean=($dpg_base->[$k]+$dpg_base->[1024+$k]+$dpg_base->[2048+$k])/3;
  for(my $channel=0;$channel<3;$channel++) {
   my $base=$channel*1024;
   my $bv=$dpg_base->[$base+$k];
   my $sub=($mean > 0) ? int($ck*$bv/$mean+0.5) : int($ck+0.5);
   my $v=$bv-$sub;
   $v=0 if($v < 0);
   $out[$base+$k]=$v;
  }
 }
 # Pin true black at index 0 of EACH channel block (must stay 0 even
 # if dpg_base is somehow non-zero there -- shouldn't be, but defensive).
 $out[0]=0;
 $out[1024]=0;
 $out[2048]=0;
 return \@out;
}

# Prefix shelf for the dynamic zone probe: subtract `depth` counts
# (ratio-preserving per channel, like apply_profile) from every index in
# 14..x_end, with the standard 0->depth ramp over 1..14 protecting true
# black. The shelf ENDS with an up-jump at x_end+1, which is monotone-
# compatible (ascending is preserved), unlike a mid-curve notch whose
# leading edge the monotone clamp would flatten. Caller must still run
# hdr20_postcal_monotone_clamp on the result.
sub hdr20_postcal_prefix_shelf {
 my ($dpg_base,$x_end,$depth)=@_;
 return undef if(ref($dpg_base) ne "ARRAY" || scalar(@{$dpg_base}) != 3072);
 $x_end=int($x_end+0);
 $depth=$depth+0;
 return undef if($x_end < 14 || $depth <= 0);
 my @out=@{$dpg_base};
 for(my $k=1;$k<=$x_end && $k<1024;$k++) {
  my $ck=($k < 14) ? $depth*$k/14 : $depth;
  my $mean=($dpg_base->[$k]+$dpg_base->[1024+$k]+$dpg_base->[2048+$k])/3;
  for(my $channel=0;$channel<3;$channel++) {
   my $base=$channel*1024;
   my $bv=$dpg_base->[$base+$k];
   my $sub=($mean > 0) ? int($ck*$bv/$mean+0.5) : int($ck+0.5);
   my $v=$bv-$sub;
   $v=0 if($v < 0);
   $out[$base+$k]=$v;
  }
 }
 $out[0]=0; $out[1024]=0; $out[2048]=0;
 return \@out;
}

# One converge-step: given the current magnitude M, the measured lift
# (measY / targetY), the damper, gain, and tolerance, return the next M.
# Pushes DOWN while lift > 1 (panel lifted); clamp M >= 0. Returns undef
# if abs(lift-1) <= tol (caller treats as "converged, exit loop").
sub hdr20_postcal_converge_step {
 my ($M,$lift,$damp,$gain,$tol)=@_;
 $M=0 if(!defined($M));
 $M=$M+0;
 $lift=1 if(!defined($lift) || $lift+0 == 0);
 $lift=$lift+0;
 $damp=0.5 if(!defined($damp) || $damp+0 == 0);
 $damp=$damp+0;
 $gain=150 if(!defined($gain));
 $gain=$gain+0;
 $tol=0.15 if(!defined($tol));
 $tol=$tol+0;
 return undef if(abs($lift-1) <= $tol);
 my $delta=$damp*($lift-1)*$gain;
 my $next=$M+$delta;
 $next=0 if($next < 0);
 return $next+0;
}

# Load the per-TV seed matrix from disk. Returns the seed magnitude in
# DPG counts (>= 0). Keys the file by both lg_generation series (preferred
# when present) and a model string (fallback). Falls back to the
# configured _seed_counts when no entry matches. No-op when the file is
# missing/unreadable -- the caller treats "no seed" as 0, which still
# allows the loop to converge from the live read alone.
sub hdr20_postcal_load_matrix {
 my ($path,$lg_generation,$model,$seed_counts)=@_;
 $path="" if(!defined($path));
 $path="/etc/PGenerator/hdr20_postcal_shadow_matrix.json" if($path eq "");
 $seed_counts=0 if(!defined($seed_counts) || $seed_counts+0 < 0);
 $seed_counts=$seed_counts+0;
 return $seed_counts if($path eq "" || !-f $path);
 my $raw=read_file($path);
 return $seed_counts if($raw eq "");
 my $data=decode_json_safe($raw,undef);
 return $seed_counts if(!defined($data) || ref($data) ne "HASH");
 my $hdr=$data->{"hdr20"};
 return $seed_counts if(ref($hdr) ne "HASH");
 my $series="";
 if(ref($lg_generation) eq "HASH") {
  $series=lc($lg_generation->{"series"}||"");
  $series=~s/[^a-z0-9]+//g;
 }
 my $model_str="";
 if(defined($model)) {
  $model_str=lc($model);
  $model_str=~s/[^a-z0-9]+//g;
 }
 # Lookup order: series key first, then model string key, then the
 # explicit _seed_counts fallback. Unknown TV falls through to seed_counts
 # so the loop still converges from the live read.
 foreach my $key ($series,$model_str) {
  next if($key eq "");
  if(ref($hdr->{$key}) eq "HASH" && defined($hdr->{$key}->{"seed_counts"})) {
   my $entry_seed=$hdr->{$key}->{"seed_counts"}+0;
   return $entry_seed if($entry_seed >= 0);
  }
 }
 return $seed_counts;
}

# Persist the converged M back into the matrix for this TV. Loads the
# existing file (or starts fresh), updates the matching series/model
# entry, writes atomically. Missing directories are created. The write
# is best-effort: a failure is logged but never fatal -- the seed is a
# performance optimization, not a correctness requirement.
sub hdr20_postcal_save_matrix {
 my ($path,$lg_generation,$model,$m_counts,$band_top,$taper_top)=@_;
 $path="/etc/PGenerator/hdr20_postcal_shadow_matrix.json" if(!defined($path) || $path eq "");
 $m_counts=0 if(!defined($m_counts));
 $m_counts=$m_counts+0;
 $band_top=25 if(!defined($band_top) || $band_top+0 <= 0);
 $band_top=$band_top+0;
 $taper_top=30 if(!defined($taper_top) || $taper_top+0 <= 0);
 $taper_top=$taper_top+0;
 my $key="";
 if(ref($lg_generation) eq "HASH") {
  $key=lc($lg_generation->{"series"}||"");
  $key=~s/[^a-z0-9]+//g;
 }
 if($key eq "" && defined($model)) {
  $key=lc($model);
  $key=~s/[^a-z0-9]+//g;
 }
 return 0 if($key eq "");
 my $raw=(-f $path) ? read_file($path) : "";
 my $data={};
 if($raw ne "") { $data=decode_json_safe($raw,{}); }
 $data={} if(ref($data) ne "HASH");
 my $hdr=$data->{"hdr20"};
 $hdr={} if(ref($hdr) ne "HASH");
 my $entry=$hdr->{$key};
 $entry={} if(ref($entry) ne "HASH");
 $entry->{"seed_counts"}=int($m_counts+0.5);
 $entry->{"band_top_ire"}=$band_top;
 $entry->{"taper_top_ire"}=$taper_top;
 $entry->{"tol"}=0.15;
 $hdr->{$key}=$entry;
 $data->{"hdr20"}=$hdr;
 my $encoded=$json->encode($data);
 return 0 if(!write_file($path,$encoded,0));
 chmod(0666,$path) if(-f $path);
 return 1;
}

# PQ target luminance for the 5% grey probe step. Limited-range PQ at
# code 108 (the 5% HDR20 10-bit limited anchor the WebUI sends), clipped
# to the measured 100% white peak (PQ can't ask the panel for more than
# its calibrated peak). peak_luminance <= 0 falls back to 10000 nits
# (un-clipped target).
sub hdr20_postcal_target5_for_step {
 my ($step,$peak_luminance)=@_;
 my $r=defined($step->{"r"}) ? ($step->{"r"}+0) : 108;
 my $g=defined($step->{"g"}) ? ($step->{"g"}+0) : $r;
 my $b=defined($step->{"b"}) ? ($step->{"b"}+0) : $r;
 # Step codes differ across runs (8-bit Ltd=27, 10-bit Ltd=108, 10-bit
 # Full=51, etc.). The spec gives a single anchor (code 108, 10-bit Ltd)
 # but the WebUI sends THIS run's actual 5% code via postcal_shadow_probe_step,
 # so we derive the normalized limited-range fraction from whichever code
 # we got. Limited = (code - black_code)/span, Full = code/max. The probe
 # step carries input_max and pattern_signal_range so we can be precise.
 my $input_max=(defined($step->{"input_max"}) && $step->{"input_max"}+0 > 0) ? ($step->{"input_max"}+0) : 1023;
 my $signal_range=(defined($step->{"pattern_signal_range"}) && $step->{"pattern_signal_range"} eq "2") ? "full" : "limited";
 my $black=($signal_range eq "limited") ? 64 : 0;
 my $span=($signal_range eq "limited") ? 876 : 1023;
 my $code=$r; # grey: r=g=b, just use r
 my $norm=$input_max > 0 ? ($code/$input_max) : 0;
 my $fraction=($signal_range eq "limited") ? (($code-$black)/$span) : $norm;
 $fraction=0 if($fraction < 0);
 $fraction=1 if($fraction > 1);
 my $target_nits=st2084_pq_to_linear($fraction)*10000;
 my $peak=$peak_luminance+0;
 $peak=10000 if(!defined($peak) || $peak <= 0);
 $target_nits=$peak if($target_nits > $peak);
 return $target_nits;
}

# The main HDR20 post-cal shadow correction subroutine. Runs early in the
# 3D worker (right before reset_3d_lut_to_unity_before_profile) so the
# corrected DPG is staged into the held cal session the 3D profiling +
# final tone-map upload both inherit. The panel-side flow it coordinates:
#   1. Greyscale left a held CAL_START with identity BT2020 gamut +
#      identity 3D LUT container + the converged DPG staged.
#   2. This sub BREAKS the held session with a single-socket BIND of
#      the base DPG (keep=false, cal_active=false) so the panel commits
#      the DPG and exits cal mode into PQ. Then it reads the 5% grey
#      probe in PQ (cal OFF), iteratively rolls the 0..25% DPG band down
#      and re-commits until the 5% lift lands inside tol.
#   3. ALWAYS RE-ESTABLISHES the held session before returning (unless
#      cancelled): opens a fresh CAL_START via 3d-lut/reset with identity
#      BT2020 gamut + identity 3D LUT container (held, cal_active=false),
#      then stages the corrected DPG via 1d-dpg/upload with
#      keep=true + cal_active=true. After this, the 3D profiling +
#      subsequent 3D LUT upload + final tone-map upload inherit a held
#      session with the corrected DPG staged -- the 3D LUT upload
#      replaces the identity container, and the final tone-map upload
#      binds the corrected DPG into the panel.
# Self-gating: an 8-bit run already reads ~1.0x so the loop exits on pass
# 1 with no change. NEVER blocks status=complete on failure -- every
# error path is eval-guarded and recorded in $state. Cancellation dies
# "cancelled\n" and propagates (no re-establish -- the whole cal is
# aborting).
sub run_hdr20_postcal_shadow_correction {
 my ($config,$state,$model)=@_;
 my $status={
  status => "skipped",
  passes => 0,
  lift_before => undef,
  lift_after => undef,
  m_counts => 0,
  reverted => json_false(),
  reestablished => json_false(),
  note => "",
 };
 return $status if(ref($config) ne "HASH");
 return $status if(lc(($config->{"signal_mode"}||"")) ne "hdr10");
 return $status if(!$config->{"lg_autocal_hdr20_postcal_shadow_enable"});
 # HDR20/full_workflow only -- this sub lives inside the 3D worker's
 # full autocal path. Standalone greyscale runs don't reach it.
 return $status if(!$config->{"full_workflow"});
 my $matrix_path=$config->{"lg_autocal_hdr20_postcal_shadow_matrix_path"} || "/etc/PGenerator/hdr20_postcal_shadow_matrix.json";
 my $band_top_ire=$config->{"lg_autocal_hdr20_postcal_shadow_band_top_ire"};
 $band_top_ire=25 if(!defined($band_top_ire) || $band_top_ire+0 <= 0);
 $band_top_ire=$band_top_ire+0;
 my $taper_top_ire=$config->{"lg_autocal_hdr20_postcal_shadow_taper_top_ire"};
 $taper_top_ire=30 if(!defined($taper_top_ire) || $taper_top_ire+0 <= 0);
 $taper_top_ire=$taper_top_ire+0;
 my $tol=$config->{"lg_autocal_hdr20_postcal_shadow_tol"};
 $tol=0.05 if(!defined($tol) || $tol+0 <= 0);
 $tol=$tol+0;
 my $max_passes=$config->{"lg_autocal_hdr20_postcal_shadow_max_passes"};
 $max_passes=6 if(!defined($max_passes) || $max_passes+0 < 1);
 $max_passes=int($max_passes+0);
 my $damp=$config->{"lg_autocal_hdr20_postcal_shadow_damp"};
 $damp=0.5 if(!defined($damp) || $damp+0 <= 0);
 $damp=$damp+0;
 my $gain=$config->{"lg_autocal_hdr20_postcal_shadow_gain"};
 $gain=180 if(!defined($gain));
 $gain=$gain+0;
 my $seed_counts_cfg=$config->{"lg_autocal_hdr20_postcal_shadow_seed_counts"};
 $seed_counts_cfg=0 if(!defined($seed_counts_cfg) || $seed_counts_cfg+0 < 0);
 $seed_counts_cfg=$seed_counts_cfg+0;
 # Optional aim-low bias: the trim runs on a HOT panel (right after the
 # greyscale stage's ~50 min of reads) and OLED low-IRE output rises a
 # few % as the panel cools, so a trim that converges at exactly 1.00
 # tends to chart +3-4% bright later. target_lift < 1 pre-compensates
 # (e.g. 0.97). Default 1.0 = off.
 my $target_lift=$config->{"lg_autocal_hdr20_postcal_shadow_target_lift"};
 $target_lift=1.0 if(!defined($target_lift) || $target_lift+0 <= 0);
 $target_lift=$target_lift+0;
 $target_lift=0.90 if($target_lift < 0.90);
 $target_lift=1.10 if($target_lift > 1.10);
 # Dynamic per-run zone probe (default ON): discover each anchor's true
 # post-cal sampling index on THIS panel in THIS run instead of trusting
 # the static zone-scale table. The table remains the prior (ladder
 # boundary placement + within-bracket placement) and the fallback when
 # a probe read fails or an anchor never responds.
 my $zone_probe=$config->{"lg_autocal_hdr20_postcal_shadow_zone_probe"};
 $zone_probe=1 if(!defined($zone_probe) || $zone_probe eq "");
 $zone_probe=$zone_probe+0 ? 1 : 0;

 # 0% IRE row of the DPG array. The HDR20 ladder's index 14 is 1.4%
 # IRE, so band_top in DPG-domain = 14 (1.4%->25% spans DPG indices
 # 14..257 in the standard HDR20 anchor map). Use the configured
 # band/taper *IRE* values to derive approximate DPG-domain edges:
 # 1023 indices cover 0..100%, so index = ire/100 * 1023.
 my $band_top=int(($band_top_ire/100)*1023+0.5);
 my $taper_top=int(($taper_top_ire/100)*1023+0.5);
 $band_top=14 if($band_top < 14);
 $taper_top=$band_top if($taper_top < $band_top);
 $taper_top=308 if($taper_top > 308);

 my $step=$config->{"postcal_shadow_probe_step"};
 return $status if(ref($step) ne "HASH" || !defined($step->{"r"}));
 $step->{"r"}+=0; $step->{"g"}+=0; $step->{"b"}+=0;
 $step->{"input_max"}=1023 if(!defined($step->{"input_max"}) || $step->{"input_max"}+0 <= 0);
 $step->{"input_max"}+=0;
 $step->{"pattern_signal_range"}=$config->{"pattern_signal_range"}||$config->{"signal_range"}||"1";
 $step->{"kind"}="white";
 $step->{"name"}="5% grey probe (post-cal shadow)";
 $step->{"ire"}=5;
 $step->{"stimulus"}=5;
 $step->{"signal_r_pct"}=5;
 $step->{"signal_g_pct"}=5;
 $step->{"signal_b_pct"}=5;
 $step->{"phase"}="postcal_shadow";

 # Snapshot the committed DPG (full_workflow_dpg_data preferred,
 # hdr20_1d_dpg_data as the legacy fallback). No snapshot = no correction
 # (and no re-establish -- nothing to stage back into the held session).
 my $dpg_base=undef;
 if(ref($config->{"full_workflow_dpg_data"}) eq "ARRAY" && scalar(@{$config->{"full_workflow_dpg_data"}}) == 3072) {
  $dpg_base=$config->{"full_workflow_dpg_data"};
 } elsif(ref($config->{"hdr20_1d_dpg_data"}) eq "ARRAY" && scalar(@{$config->{"hdr20_1d_dpg_data"}}) == 3072) {
  $dpg_base=$config->{"hdr20_1d_dpg_data"};
 }
 if(!defined($dpg_base)) {
  $status->{"status"}="skipped";
  $status->{"note"}="no committed DPG snapshot in config";
  $state->{"hdr20_postcal_shadow"}=$status;
  return $status;
 }
 my $peak=0;
 if(defined($config->{"full_workflow_peak_luminance"}) && $config->{"full_workflow_peak_luminance"}+0 > 0) {
  $peak=$config->{"full_workflow_peak_luminance"}+0;
 } elsif(defined($config->{"hdr20_1d_tonemap_peak_luminance"}) && $config->{"hdr20_1d_tonemap_peak_luminance"}+0 > 0) {
  $peak=$config->{"hdr20_1d_tonemap_peak_luminance"}+0;
 } elsif(ref($model) eq "HASH" && defined($model->{"white_y"}) && $model->{"white_y"}+0 > 0) {
  $peak=$model->{"white_y"}+0;
 }
 $status->{"peak_luminance"}=$peak;
 $state->{"hdr20_postcal_shadow"}=$status;

 # Helper closure: single-socket DPG BIND. Helper sends its own
 # CAL_START + DPG + CAL_END on its own websocket; the panel binds the
 # DPG and exits cal mode into PQ. Returns the response hash (or undef).
 # Real bind requires status "ok" AND both cal_start_response / cal_end_response
 # are real type=>"response" entries (the same proven check in
 # usr/bin/meter_lg_autocal.pl:15391).
 my $bind_dpg=sub {
  my ($dpg)=@_;
  return (undef,0,"invalid dpg") if(ref($dpg) ne "ARRAY" || scalar(@{$dpg}) != 3072);
  my $resp=api_json("POST","/api/lg/1d-dpg/upload",{
   picture_mode => $config->{"picture_mode"}||"",
   ddc_layout => "hdr20",
   signal_mode => "hdr10",
   dpg_data => $dpg,
   keep_calibration_mode => json_false(),
   calibration_mode_active => json_false(),
   helper_timeout => 90,
  },120);
  my $ok=0;
  my $bound=0;
  my $msg="";
  if(ref($resp) eq "HASH") {
   $ok=(($resp->{status}//"") eq "ok") ? 1 : 0;
   $msg=(ref($resp->{message}) eq "ARRAY") ? join(" ",@{$resp->{message}}) : ($resp->{message}||"");
   my $cs=(ref($resp->{"cal_start_response"}) eq "HASH" && ($resp->{"cal_start_response"}{"type"}//"") eq "response") ? 1 : 0;
   my $ce=(ref($resp->{"cal_end_response"}) eq "HASH" && ($resp->{"cal_end_response"}{"type"}//"") eq "response") ? 1 : 0;
   $bound=($ok && $cs && $ce) ? 1 : 0;
  } else {
   $msg="no response";
  }
  return ($resp,$bound,$msg);
 };

 # Helper closure: re-establish the held cal session the 3D profiling
 # needs. (1) 3d-lut/reset with BT2020_3D_LUT_DATA + keep=true +
 # cal_active=false -> opens CAL_START + uploads identity gamut + identity
 # 3D container, held. (2) 1d-dpg/upload with ddc_layout=hdr20 +
 # dpg_data=$corrected + keep=true + cal_active=true -> stages the
 # corrected DPG in the held session. After (1)+(2) the TV is back in
 # the held cal-ON state the 3D profiling + final tone-map upload both
 # expect, with the corrected DPG staged.
 my $reestablish=sub {
  my ($dpg)=@_;
  my $r_ok=0;
  my $d_ok=0;
  my $r_msg="";
  my $d_msg="";
  my $reset_resp=api_json("POST","/api/lg/3d-lut/reset",{
   picture_mode => $config->{"picture_mode"}||"",
   upload_command => "BT2020_3D_LUT_DATA",
   keep_calibration_mode => json_true(),
   calibration_mode_active => json_false(),
   helper_timeout => 90,
  },120);
  if(ref($reset_resp) eq "HASH") {
   $r_ok=(($reset_resp->{status}//"") eq "ok") ? 1 : 0;
   $r_msg=(ref($reset_resp->{message}) eq "ARRAY") ? join(" ",@{$reset_resp->{message}}) : ($reset_resp->{message}||"");
  } else {
   $r_msg="no response";
  }
  my $dpg_resp=api_json("POST","/api/lg/1d-dpg/upload",{
   picture_mode => $config->{"picture_mode"}||"",
   ddc_layout => "hdr20",
   dpg_data => $dpg,
   keep_calibration_mode => json_true(),
   calibration_mode_active => json_true(),
   helper_timeout => 90,
  },120);
  if(ref($dpg_resp) eq "HASH") {
   $d_ok=(($dpg_resp->{status}//"") eq "ok") ? 1 : 0;
   $d_msg=(ref($dpg_resp->{message}) eq "ARRAY") ? join(" ",@{$dpg_resp->{message}}) : ($dpg_resp->{message}||"");
  } else {
   $d_msg="no response";
  }
  $state->{"postcal_shadow_reestablish_reset_ok"}=$r_ok ? json_true() : json_false();
  $state->{"postcal_shadow_reestablish_reset_message"}=$r_msg;
  $state->{"postcal_shadow_reestablish_dpg_ok"}=$d_ok ? json_true() : json_false();
  $state->{"postcal_shadow_reestablish_dpg_message"}=$d_msg;
  return ($r_ok && $d_ok) ? 1 : 0;
 };

 my $target5=hdr20_postcal_target5_for_step($step,$peak);
 my $lg_generation=(ref($config->{"lg_generation"}) eq "HASH") ? $config->{"lg_generation"} : undef;
 my $model_str=(ref($state) eq "HASH") ? ($state->{"signal_mode"}||"hdr10") : "hdr10";
 my $M=hdr20_postcal_load_matrix($matrix_path,$lg_generation,$model_str,$seed_counts_cfg);

 # Measure + converge work lives inside an inner eval so any error in
 # this block leaves $corrected = $dpg_base (revert-safe default) and
 # the sub can still proceed to re-establish. Cancellation (die
 # "cancelled\n") propagates -- the whole cal is aborting and we don't
 # want to re-establish a session we're about to tear down.
 my $corrected=[ @{$dpg_base} ]; # default: corrected = base (revert-safe)
 # Per-anchor HDR20 low-band anchors: IRE -> DPG index. These are the
 # grey anchors the HDR20 ladder runs through; each anchor's lift
 # drives its OWN magnitude of roll-down in the new piecewise profile.
 # 30% is included because a C1 committed-state series read showed +3.8%
 # residual lift at 30% video with the band ending at 25% -- the lift
 # tail extends past the old band edge (35% read +1.3%, 40% +0.4%).
 my @anchor_ire=(5,10,15,20,25,30);
 # Post-cal (cal-mode OFF) DPG index mapping. The legal-expanded table
 # (ire/100*1023: 51/103/154/206/257) is only valid while cal mode is ON
 # (panel linearized to 2.2, DPG indexed by expanded video code). With PQ
 # processing re-applied the panel samples the DPG in a COMPRESSED domain
 # well below the expanded index -- and the compression is NOT a constant
 # ratio. Narrow-notch probes on the C1 (200-count notch, +-12 idx, read
 # per level) measured the true sampled zone per video level:
 #   5% -> idx ~26 (0.505x)   10% -> ~51 (0.50x)   15% -> ~65 (0.423x)
 #   20% -> ~84 (0.41x)       25% -> ~105 (0.41x)  30% -> ~126 (0.41x)
 # A notch at the old constant-0.5 index for 20% (102) crushed the 25%
 # read and left 20% untouched -- the constant scale places the 15-30%
 # anchors in the WRONG zones. Per-IRE zone scales below are the
 # C1-measured defaults; lg_autocal_hdr20_postcal_shadow_zone_scales
 # ("ire:scale,ire:scale,...") overrides per panel, and the legacy
 # lg_autocal_hdr20_postcal_shadow_index_scale remains the fallback for
 # any IRE missing from the table.
 my $idx_scale=$config->{"lg_autocal_hdr20_postcal_shadow_index_scale"};
 $idx_scale=0.5 if(!defined($idx_scale) || $idx_scale+0 <= 0);
 $idx_scale=$idx_scale+0;
 $idx_scale=0.25 if($idx_scale < 0.25);
 $idx_scale=1.0 if($idx_scale > 1.0);
 # 15% zone revised 0.423 -> 0.36 after the first zone-table run: the
 # loop pushed the idx-65 anchor to 101 counts with ~zero 15% response
 # (1.043 -> 1.037) while all real 15% movement tracked the idx-51
 # anchor's spillover -- the 15% patch samples ~idx 55, just above the
 # 10% zone.
 my %zone_scale=(5=>0.505,10=>0.50,15=>0.36,20=>0.41,25=>0.41,30=>0.41);
 my $zone_cfg=$config->{"lg_autocal_hdr20_postcal_shadow_zone_scales"};
 if(defined($zone_cfg) && $zone_cfg ne "") {
  foreach my $pair (split(/,/,$zone_cfg)) {
   my ($z_ire,$z_scale)=split(/:/,$pair);
   next if(!defined($z_ire) || !defined($z_scale));
   $z_ire=$z_ire+0; $z_scale=$z_scale+0;
   next if($z_ire <= 0 || $z_scale < 0.25 || $z_scale > 1.0);
   $zone_scale{$z_ire}=$z_scale;
  }
 }
 my @anchor_idx=map {
  my $scale=defined($zone_scale{$_}) ? $zone_scale{$_} : $idx_scale;
  int(($_/100)*1023*$scale+0.5);
 } @anchor_ire;
 # Build a probe step per anchor from the 5% probe step. The probe
 # carries input_max + pattern_signal_range + ire + stimulus + name;
 # only r=g=b change. Code math mirrors webui.pm's _pcode derivation:
 #   10-bit: code = (range=="2") ? round(ire/100*1023)
 #                          : round(64 + ire/100*876)
 #   8-bit:  code = (range=="2") ? round(ire/100*255)
 #                          : round(16 + ire/100*219)
 my $signal_range_eq="";
 $signal_range_eq="2" if(defined($step->{"pattern_signal_range"}) && $step->{"pattern_signal_range"} eq "2");
 my $anchor_input_max=(defined($step->{"input_max"}) && $step->{"input_max"}+0 > 0) ? ($step->{"input_max"}+0) : 1023;
 my @anchor_steps;
 for(my $ai=0; $ai<scalar(@anchor_ire); $ai++) {
  my $ire=$anchor_ire[$ai]+0;
  my $code;
  if($anchor_input_max+0 >= 1023) {
   $code=($signal_range_eq eq "2") ? int($ire/100*$anchor_input_max+0.5) : int(64 + $ire/100*876 + 0.5);
  } else {
   $code=($signal_range_eq eq "2") ? int($ire/100*$anchor_input_max+0.5) : int(16 + $ire/100*219 + 0.5);
  }
  my $astep={ %{$step} };
  $astep->{"r"}=$code; $astep->{"g"}=$code; $astep->{"b"}=$code;
  $astep->{"ire"}=$ire;
  $astep->{"stimulus"}=$ire;
  $astep->{"signal_r_pct"}=$ire;
  $astep->{"signal_g_pct"}=$ire;
  $astep->{"signal_b_pct"}=$ire;
  $astep->{"name"}="HDR20 post-cal shadow ".$ire."% grey probe";
  $astep->{"phase"}="postcal_shadow";
  push @anchor_steps, $astep;
 }
 # Per-anchor PQ targets (peak-clipped). Use the existing helper so
 # limited-range PQ math + peak-clip stays in one place.
 my @anchor_targets;
 for my $astep (@anchor_steps) {
  push @anchor_targets, hdr20_postcal_target5_for_step($astep,$peak);
 }
 my $best_worst=1e9;
 my $best_dpg=[ @{$dpg_base} ];
 my %best_counts;
 my %baseline_lifts;
 my $improved=0;
 my $baseline_worst=1e9;
 my $best_m_counts=0;
 my $best_first_lift=undef;
 eval {
  # Baseline BIND -> commit base DPG and exit cal mode. Pass 1 with
  # counts=0 reads each anchor on the BASE DPG (the corrected profile
  # with all-zero counts equals base), giving us the baseline lifts
  # for both the self-gate and the revert-if-worse comparison.
  $state->{"phase"}="postcal_shadow_bind";
  $state->{"current_name"}="HDR20 post-cal shadow BIND baseline";
  $state->{"message"}="Binding committed DPG (single socket, cal off) and reading anchors";
  write_state($state);
  my ($bind_resp,$bound,$bind_msg)=$bind_dpg->($dpg_base);
  if(!$bound) {
   # Bind failed: record note; corrected stays at base; skip correction
   # but still re-establish below.
   $status->{"status"}="skipped";
   $status->{"note"}="baseline bind not real (".$bind_msg."); correction skipped";
   return 1;
  }
  my $settle_ms=$config->{"postcal_shadow_settle_ms"};
  $settle_ms=3500 if(!defined($settle_ms) || $settle_ms+0 < 100);
  $settle_ms=$settle_ms+0;

  # --- Dynamic zone probe -----------------------------------------
  # Measured on the C1: the post-cal sampling index is NOT a constant
  # fraction of the expanded index, and the loop-state zone can differ
  # from the static table (an anchor placed off-zone eats counts with
  # no effect -- the dead-anchor symptom). Discover the zones on THIS
  # panel each run: bind the base with a deep prefix shelf ending at a
  # ladder of boundary indices placed between the prior zones, read the
  # anchors after each bind, and bracket each anchor's zone by the
  # FIRST shelf end that crushes it (zones are ordered by IRE, so one
  # ascending ladder serves all anchors; already-crushed anchors are
  # not re-read). Priors place the anchor within its bracket. An anchor
  # that never responds keeps its prior and is noted.
  if($zone_probe) {
   $state->{"phase"}="postcal_shadow_probe";
   $state->{"current_name"}="HDR20 post-cal shadow zone probe";
   $state->{"message"}="Probing the panel's post-cal DPG sampling zones";
   write_state($state);
   # Reference read per anchor on the bound base.
   my %probe_base_y;
   select(undef,undef,undef,$settle_ms/1000.0);
   for(my $ai=0; $ai<scalar(@anchor_steps); $ai++) {
    die "cancelled\n" if(cancelled());
    my ($reading,$error)=read_step($config,$anchor_steps[$ai],$state);
    next if($error || !$reading);
    my $xyz=reading_xyz($reading);
    my $y=(ref($xyz) eq "ARRAY") ? ($xyz->[1]+0) : 0;
    $probe_base_y{$ai}=$y if($y > 0);
   }
   # Ladder: boundaries between consecutive prior zones, plus one top
   # boundary past the last prior so the last anchor can be confirmed.
   my @ladder;
   for(my $ai=0; $ai<scalar(@anchor_idx)-1; $ai++) {
    push @ladder, int(($anchor_idx[$ai]+$anchor_idx[$ai+1])/2+0.5);
   }
   push @ladder, int($anchor_idx[-1]*1.35+0.5);
   my %resolved;   # anchor index in @anchor_ire -> first ladder X that crushed it
   my $probe_depth=300;
   my $lo_prev=13;
   my %bracket_lo;
   for(my $li=0; $li<scalar(@ladder); $li++) {
    my $X=$ladder[$li];
    my @todo=grep { !exists($resolved{$_}) && exists($probe_base_y{$_}) } (0..scalar(@anchor_steps)-1);
    last if(!scalar(@todo));
    die "cancelled\n" if(cancelled());
    my $shelf=hdr20_postcal_prefix_shelf($dpg_base,$X,$probe_depth);
    $shelf=hdr20_postcal_monotone_clamp($shelf) if($shelf);
    if(!$shelf) { last; }
    my ($p_resp,$p_bound,$p_msg)=$bind_dpg->($shelf);
    if(!$p_bound) {
     $status->{"note"}=($status->{"note"}||"")." zone probe X=$X bind not real (".$p_msg."); probe stopped; ";
     last;
    }
    select(undef,undef,undef,$settle_ms/1000.0);
    for my $ai (@todo) {
     my ($reading,$error)=read_step($config,$anchor_steps[$ai],$state);
     next if($error || !$reading);
     my $xyz=reading_xyz($reading);
     my $y=(ref($xyz) eq "ARRAY") ? ($xyz->[1]+0) : 0;
     next if($y <= 0);
     if($y < 0.88*$probe_base_y{$ai}) {
      $resolved{$ai}=$X;
      $bracket_lo{$ai}=$lo_prev;
     }
    }
    $lo_prev=$X;
   }
   # Assign zones: clamp the prior into the measured bracket; keep the
   # prior when the anchor never responded. Enforce strictly ascending.
   my @probed_idx;
   my $probe_note="";
   for(my $ai=0; $ai<scalar(@anchor_idx); $ai++) {
    my $zone=$anchor_idx[$ai];
    if(exists($resolved{$ai})) {
     my $lo=($bracket_lo{$ai}||13)+1;
     my $hi=$resolved{$ai};
     $zone=$lo if($zone < $lo);
     $zone=$hi if($zone > $hi);
    } else {
     $probe_note.=$anchor_ire[$ai]."% unresolved(prior kept) ";
    }
    $zone=int($zone+0.5);
    $zone=$probed_idx[-1]+2 if(scalar(@probed_idx) && $zone <= $probed_idx[-1]);
    push @probed_idx, $zone;
    $state->{"postcal_shadow_zone_IRE_".$anchor_ire[$ai]}=$zone;
   }
   @anchor_idx=@probed_idx;
   log_line("HDR20 post-cal shadow zone probe: zones ".join("/",@anchor_idx)." for IRE ".join("/",@anchor_ire).($probe_note ne "" ? " (".$probe_note.")" : ""));
   $status->{"zone_probe"}=join(",",@anchor_idx);
   # No base re-bind needed here: pass 1 below binds the all-zero-counts
   # candidate, which IS the base.
  }
  # -----------------------------------------------------------------

  # Per-anchor counts hash: anchor index -> counts. Initialize to 0
  # (counts >= 0: pull-DOWN only, overshoot-to-dark self-corrects).
  my %counts;
  for my $idx (@anchor_idx) { $counts{$idx}=0; }
  # Previous pass's (counts, lift) per anchor -- the second point the
  # secant update needs from pass 2 onward.
  my %prev_counts;
  my %prev_lifts;
  # Anchors whose zone estimate proved wrong for this panel (big count
  # move, no lift response) -- frozen by the dead-anchor guard below.
  my %dead_anchor;

  for(my $pass=1; $pass<=$max_passes; $pass++) {
   die "cancelled\n" if(cancelled());

   # Build the corrected DPG from the current counts and clamp to
   # ascending-by-channel + pinned black. The apply_profile helper
   # handles the ramp/plateau/interp/ramp-out shape; monotone_clamp
   # keeps the array ascending per channel block.
   my @anchor_list;
   for my $idx (@anchor_idx) { push @anchor_list, [$idx,$counts{$idx}]; }
   my $candidate=hdr20_postcal_apply_profile($dpg_base,\@anchor_list);
   $candidate=hdr20_postcal_monotone_clamp($candidate);

   $state->{"phase"}="postcal_shadow";
   $state->{"current_name"}="HDR20 post-cal shadow correction pass $pass";
   $state->{"message"}=sprintf("Re-committing DPG (per-anchor trim, worst=%.3f)",($pass==1 ? 1e9 : 0));
   write_state($state);
   my ($cand_resp,$cand_bound,$cand_msg)=$bind_dpg->($candidate);
   $state->{"postcal_shadow_pass_".$pass."_counts"}={ %counts };
   if(!$cand_bound) {
    $status->{"note"}=($status->{"note"}||"")." pass $pass: bind not real (".$cand_msg."); ";
    last;
   }
   # Settle, then read each anchor.
   select(undef,undef,undef,$settle_ms/1000.0);
   my $worst=0;
   my %lift_for;
   for(my $ai=0; $ai<scalar(@anchor_steps); $ai++) {
    my $astep=$anchor_steps[$ai];
    my $atarget=$anchor_targets[$ai];
    my ($reading,$error)=read_step($config,$astep,$state);
    if($error || !$reading) {
     $status->{"note"}=($status->{"note"}||"")." pass $pass anchor ".$astep->{"ire"}."%: read failed (".($error||"no reading")."); ";
     last;
    }
    my $xyz=reading_xyz($reading);
    my $y=(ref($xyz) eq "ARRAY") ? ($xyz->[1]+0) : 0;
    # Single read per anchor (operator choice 2026-07-04): the
    # unconditional double-read predates the pattern-insertion port --
    # with insertion stabilizing the panel between reads the second
    # sample bought little, and the operator judged shadow detail
    # better without it. The revert-if-worse gate and best-pass
    # tracking still protect the committed result from a single noisy
    # read.
    my $lift=($atarget > 0) ? ($y/$atarget) : 0;
    $lift_for{$anchor_idx[$ai]}=$lift;
    my $excess=abs($lift-$target_lift);
    $worst=$excess if($excess > $worst);
    $state->{"postcal_shadow_pass_".$pass."_IRE_".$astep->{"ire"}."_lift"}=$lift;
   }
   # If any anchor failed to read, the inner loop bailed with $worst
   # reflecting only the partial set; treat as a hard fail for this
   # pass and bail the outer loop below.
   # If the inner anchor loop bailed out (read failure), break the
   # outer pass loop too.
   if($status->{"note"} =~ / pass $pass anchor /) {
    last;
   }
   $status->{"passes"}=$pass;
   $state->{"postcal_shadow_pass_".$pass."_worst"}=$worst;

   # Track pass-1 lifts for the lift_before status field (the 5%
   # anchor is representative of the lifted shadow region).
   if($pass == 1) {
    $baseline_worst=$worst;
    my $first_lift=$lift_for{$anchor_idx[0]};
    $status->{"lift_before"}=$first_lift if(defined($first_lift));
    foreach my $idx (@anchor_idx) {
     $baseline_lifts{$idx}=$lift_for{$idx} if(defined($lift_for{$idx}));
    }
    # Self-gating: if pass 1 (counts=0 -> correction=base) is already
    # inside tol across all anchors, do nothing. The 8-bit run lands
    # here; no upload, no further reads.
    if($worst <= $tol) {
     $status->{"status"}="self_gated";
     $status->{"lift_after"}=$first_lift if(defined($first_lift));
     $status->{"m_counts"}=0;
     $status->{"note"}=($status->{"note"}||"")." baseline already within tol on all anchors; no correction needed.";
     return 1;
    }
   }

   # Best-tracking: any pass whose worst is below the best so far wins.
   # Capture the 5%-anchor lift of the best pass so lift_after can be
   # reported accurately (single-anchor implementation had this for
   # free; per-anchor tracking has to remember explicitly).
   if($worst+0 < $best_worst+0) {
    $best_worst=$worst;
    $best_dpg=[ @{$candidate} ];
    %best_counts=%counts;
    $improved=1;
    $best_first_lift=$lift_for{$anchor_idx[0]};
   }

   # Converged across all anchors.
   if($worst <= $tol) {
    $status->{"status"}="converged";
    last;
   }

   # Update counts: pull-DOWN only (counts >= 0).
   # Pass 1 (baseline, counts all 0) has no slope information, so it
   # takes the coarse gain step: counts[idx] += gain * (lift-1).
   # Pass >= 2 solves a per-anchor SECANT from the last two
   # (counts, lift) points -- the measured sensitivity of THIS anchor
   # on THIS panel -- so refinement lands on target instead of
   # stair-stepping at a fixed gain that only matches one anchor's
   # true sensitivity. Rails:
   #  - a usable slope must be negative (more roll-down => less
   #    light); wrong-sign / near-flat slopes are read noise, not
   #    physics;
   #  - an anchor slope flatter than half the median of its peers is
   #    replaced by the median (adjacent anchors share the same DPG
   #    band; a 5x sensitivity cliff between neighbours is noise --
   #    seen at the 20% anchor on the C1);
   #  - the per-pass move is capped so one bad slope can't blow an
   #    anchor into deep overshoot.
   my %slope_for;
   my @valid_slopes;
   for my $idx (@anchor_idx) {
    next if(!defined($lift_for{$idx}) || !defined($prev_lifts{$idx}) || !defined($prev_counts{$idx}));
    my $dc=$counts{$idx}-$prev_counts{$idx};
    next if(abs($dc) < 1);
    my $s=($lift_for{$idx}-$prev_lifts{$idx})/$dc;
    next if($s >= -0.0002);
    $slope_for{$idx}=$s;
    push @valid_slopes, $s;
   }
   my $median_slope=undef;
   if(scalar(@valid_slopes)) {
    my @ss=sort { $a <=> $b } @valid_slopes;
    $median_slope=$ss[int(scalar(@ss)/2)];
   }
   for(my $ai=0; $ai<scalar(@anchor_idx); $ai++) {
    my $idx=$anchor_idx[$ai];
    my $lift=$lift_for{$idx};
    next if(!defined($lift));
    # Dead-anchor guard: if this anchor's counts already moved a lot
    # and its lift barely responded (own measured slope rejected as
    # near-flat over a >=25-count move), the anchor's zone estimate is
    # wrong for this panel -- do NOT let the median-slope substitution
    # keep inflating it (the first zone-table run pushed a dead 15%
    # anchor to 101 counts with zero effect, leaving an orphan bump in
    # the DPG). Freeze it at its current value instead.
    my $own_slope=$slope_for{$idx};
    if(!defined($own_slope) && defined($prev_counts{$idx}) && defined($prev_lifts{$idx})
       && abs($counts{$idx}-$prev_counts{$idx}) >= 25) {
     $dead_anchor{$idx}=($dead_anchor{$idx}||0)+1;
    }
    if(($dead_anchor{$idx}||0) >= 1) {
     $state->{"postcal_shadow_dead_anchor_".$idx}=json_true();
     $prev_counts{$idx}=$counts{$idx};
     $prev_lifts{$idx}=$lift;
     next;
    }
    my $slope=$own_slope;
    if(defined($median_slope) && (!defined($slope) || abs($slope) < 0.5*abs($median_slope))) {
     $slope=$median_slope;
    }
    my $next;
    if(defined($slope)) {
     $next=$counts{$idx} + ($target_lift-$lift)/$slope;
    } else {
     $next=$counts{$idx} + $gain*($lift-$target_lift);
    }
    # Cap the secant move per pass; the pass-1 gain step stays uncapped
    # (it is the coarse jump and $slope is never defined on pass 1).
    if(defined($slope)) {
     my $max_move=60;
     $next=$counts{$idx}+$max_move if($next > $counts{$idx}+$max_move);
     $next=$counts{$idx}-$max_move if($next < $counts{$idx}-$max_move);
    }
    $next=0 if($next < 0);
    $prev_counts{$idx}=$counts{$idx};
    $prev_lifts{$idx}=$lift;
    $counts{$idx}=$next+0;
   }
  }

  # best-tracking fallback: if no pass beat large (e.g. all reads
  # failed), best_dpg stays at base. The lift_after / m_counts fields
  # are populated from best_counts if any pass ran.
  my $best_5=$best_counts{$anchor_idx[0]};
  $best_m_counts=int(($best_5+0)+0.5) if(defined($best_5));
  # lift_after: the 5%-anchor lift of the best pass (or the baseline
  # 5% lift if no pass improved on the baseline).
  if(defined($best_first_lift)) {
   $status->{"lift_after"}=$best_first_lift;
  } elsif(defined($baseline_lifts{$anchor_idx[0]})) {
   $status->{"lift_after"}=$baseline_lifts{$anchor_idx[0]};
  }
  $status->{"m_counts"}=$best_m_counts;

  # Revert-if-worse: if no pass's worst beat the baseline worst
  # (pass-1 worst), keep corrected=base. The panel is already on base
  # DPG from the baseline BIND, so no rollback is needed.
  if(!$improved || $best_worst+0 >= $baseline_worst+0) {
   $status->{"reverted"}=json_true();
   $status->{"status"}="reverted" if(($status->{"status"}||"") ne "converged");
   $status->{"note"}=($status->{"note"}||"")."best pass worst (".sprintf("%.3f",$best_worst).") did not improve on baseline (".sprintf("%.3f",$baseline_worst)."); corrected=base DPG.";
   $corrected=[ @{$dpg_base} ];
  } else {
   # Apply best_counts to compute final corrected DPG and persist the
   # 5% anchor's count as the matrix seed for next time.
   my @best_anchor_list;
   for my $idx (@anchor_idx) { push @best_anchor_list, [$idx,$best_counts{$idx}]; }
   $corrected=hdr20_postcal_apply_profile($dpg_base,\@best_anchor_list);
   $corrected=hdr20_postcal_monotone_clamp($corrected);
   my $seed=$best_counts{$anchor_idx[0]};
   if(defined($seed) && $seed+0 > 0) {
    my $saved=hdr20_postcal_save_matrix($matrix_path,$lg_generation,$model_str,$seed,$band_top_ire,$taper_top_ire);
    $state->{"postcal_shadow_matrix_saved"}=$saved ? json_true() : json_false();
   }
   $status->{"status"}="converged" if(($status->{"status"}||"") ne "converged");
   $status->{"note"}=($status->{"note"}||"")."converged (worst ".sprintf("%.3f",$best_worst)." vs baseline ".sprintf("%.3f",$baseline_worst).").";
  }
  1;
 } or do {
  my $inner_err=$@ || "HDR20 post-cal shadow inner eval failed";
  $inner_err=~s/[\r\n]+/ /g;
  die $inner_err if($inner_err =~ /^cancelled$/i); # let cancellation propagate
  # Any non-cancellation error: corrected stays at base DPG, record note,
  # still re-establish below.
  $status->{"status"}="error" if(($status->{"status"}||"") ne "skipped" && ($status->{"status"}||"") ne "self_gated" && ($status->{"status"}||"") ne "converged" && ($status->{"status"}||"") ne "reverted");
  $status->{"note"}=($status->{"note"}||"")."inner eval error: ".$inner_err."; corrected=base DPG.";
 };

 # Store $corrected back into config so the final 3D commit (3D LUT +
 # tone map upload) carries it. The panel-side BIND happens later, in
 # the held session the re-establish just staged.
 $config->{"full_workflow_dpg_data"}=$corrected;
 $config->{"hdr20_1d_dpg_data"}=$corrected;

 # ALWAYS RE-ESTABLISH the held cal session before returning. The
 # sub BROKE the held session at the baseline BIND; without this, the
 # 3D worker would try to profile / upload against a stale session.
 my $re_ok=$reestablish->($corrected);
 $status->{"reestablished"}=$re_ok ? json_true() : json_false();
 if(!$re_ok) {
  $status->{"note"}=($status->{"note"}||"")."re-establish reported failure; 3D profiling will likely fail.";
 }
 $state->{"hdr20_postcal_shadow"}=$status;
 return $status;
}

unless(caller()) {
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
$method="matrix" unless($method eq "matrix" || $method eq "ramp" || $method eq "lattice" || $method eq "imported");
# Lattice profiling needs the client-expanded node list; without it fall back
# to the classic 5-point matrix rather than dying mid-wizard.
$method="matrix" if($method eq "lattice" && (ref($config->{"lattice_patches"}) ne "ARRAY" || !@{$config->{"lattice_patches"}}));
my ($signal_mode,$signal_mode_error)=sanitize_signal_mode($config->{"requested_signal_mode"},$config->{"ui_signal_mode"},$config->{"signal_mode"});
$config->{"signal_mode"}=$signal_mode;
$config->{"target_gamut"}=sanitize_target_gamut($config->{"target_gamut"},$signal_mode);
$config->{"target_gamma"}=sanitize_target_gamma($config->{"target_gamma"},$signal_mode);
# Quant range: 1=Limited, 2=Full. Prefer explicit body fields; never silently
# invent limited when the start path already aligned to conf. Empty still
# defaults to limited only as a last-resort legacy fallback (pre-fix callers).
sub _normalize_signal_range_field {
 my ($v)=@_;
 return "" if(!defined($v));
 $v="$v";
 return $v if($v eq "1" || $v eq "2");
 return "1" if(lc($v) eq "limited" || lc($v) eq "legal");
 return "2" if(lc($v) eq "full");
 return "";
}
{
 my $sr=_normalize_signal_range_field($config->{"signal_range"});
 my $psr=_normalize_signal_range_field($config->{"pattern_signal_range"});
 my $tsr=_normalize_signal_range_field($config->{"transport_signal_range"});
 # Prefer transport (HDMI out) then pattern then signal; last resort limited.
 my $eff=$tsr || $psr || $sr || "1";
 $config->{"signal_range"}=$eff;
 $config->{"pattern_signal_range"}=$eff;
 $config->{"transport_signal_range"}=$eff;
 log_line("LG 3D LUT AutoCal quant range: signal_range=$eff (1=Limited 2=Full) method=$method signal_mode=".($config->{"signal_mode"}||""));
}
# Solve-only mode (generic measure -> solve -> export path): no meter, no TV,
# no upload -- build the model from POSTed lattice readings, generate + export
# the LUT, write the state file and exit. Uses its own state/stop paths so it
# can never collide with a real AutoCal run's UI state.
if($config->{"solve_only"}) {
 eval { run_solve_only($config); };
 if($@) {
  my $err=$@; $err =~ s/\s+$//;
  write_state({ status=>"error", solve_only=>json_true(), message=>"LUT solve failed: $err" });
  exit 1;
 }
 exit 0;
}

my @steps=($method eq "matrix") ? build_matrix_steps($config)
 : ($method eq "lattice") ? build_lattice_steps($config)
 : ($method eq "imported") ? ()
 : build_ramp_steps($config);
my $started_at=int(time()*1000);

my $state={
 status => "running",
 autocal3d => json_true(),
 started_at => $started_at,
 method => $method,
 current_step => 0,
 total_steps => scalar(@steps),
 profile_patch_count => ($method eq "ramp" ? 65 : ($method eq "lattice" ? scalar(@steps) : ($method eq "imported" ? 0 : 5))),
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
 die "LG 3D LUT Auto Cal HDR10 runs are matrix- or lattice-profiled in this version\n" if($config->{"signal_mode"} eq "hdr10" && $method ne "matrix" && $method ne "lattice" && $method ne "imported");
 # HDR20 post-cal shadow correction was MOVED to after the 3D LUT +
 # tone-map commit (operator-approved reorder, 2026-07-03). Running it
 # here (before profiling) made the trim converge against a mid-workflow
 # state -- identity 3D container, unstabilized panel -- and the
 # committed result then charted +4-10% off with residual chroma error.
 # The order test (base DPG -> 3D cal -> shadow after -> re-commit)
 # verified within +-2% luminance and dxy <= 0.0016 at 15-35% on the C1.
 # Profiling now always sees the greyscale stage's converged base DPG.
 # Imported upload skips the pre-profile unity reset: there is no profiling
 # to protect and the upload itself replaces whatever cube is loaded.
 my $unity_reset=($method eq "imported") ? undef : reset_3d_lut_to_unity_before_profile($config,$state);
 my @profile_readings;
 for(my $i=0;$i<@steps;$i++) {
  die "cancelled\n" if(cancelled());
  my $step=$steps[$i];
  # The unity reset set phase=unity_reset; without this the UI's summary
  # line keeps saying "unity reset" for the entire profiling read.
  $state->{"phase"}="profile";
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

 # Drift diagnostic (lattice only): the lattice path applies NO drift correction
 # (unlike ramp), yet its read is long (corners first, then the dim interior over
 # minutes). Re-read the white corner now and compare to the START white: a
 # meaningful start->end shift means the interior deviations feeding the residual
 # carry panel thermal/ABL drift, not real non-additivity -- the leading
 # explanation for lattice trailing matrix while the solve math itself is sound.
 if($method eq "lattice" && !$config->{"fixture_mode"}) {
  eval {
   my $white_step;
   foreach my $s (@steps) { if(($s->{"kind"}||"") eq "white") { $white_step=$s; last; } }
   my ($start_white,$start_t);
   foreach my $e (@profile_readings) {
    next unless(ref($e->{"step"}) eq "HASH" && ($e->{"step"}{"kind"}||"") eq "white");
    my $x=reading_xyz($e->{"reading"}); if($x){ $start_white=$x; $start_t=$e->{"read_time"}; last; }
   }
   if($white_step && $start_white) {
    $state->{"phase"}="drift_check";
    $state->{"current_name"}="Drift check (re-reading white)";
    $state->{"message"}="Re-reading white to measure panel drift across the profile";
    write_state($state);
    my ($rw,$rerr)=read_step($config,$white_step,$state);
    my $end_white=$rerr ? undef : reading_xyz($rw);
    if($end_white) {
     my $ss=($start_white->[0]+$start_white->[1]+$start_white->[2])||1;
     my $es=($end_white->[0]+$end_white->[1]+$end_white->[2])||1;
     my $sy=$start_white->[1]||1; my $ey=$end_white->[1]||0;
     my $drift={
      start_y=>$sy, end_y=>$ey,
      dy_pct=>(($ey-$sy)/$sy*100),
      dx=>($end_white->[0]/$es - $start_white->[0]/$ss),
      dy_chroma=>($end_white->[1]/$es - $start_white->[1]/$ss),
      elapsed_s=>(time()-($start_t||time())),
     };
     $state->{"lattice_drift"}=$drift;
     log_line(sprintf("lattice drift: white Y %.3f->%.3f (%.2f%%) dxy (%.4f,%.4f) over %ds",
      $sy,$ey,$drift->{"dy_pct"},$drift->{"dx"},$drift->{"dy_chroma"},$drift->{"elapsed_s"}));
    }
   }
  };
  log_line("lattice drift check error: $@") if($@);
 }

 $state->{"phase"}="building";
 $state->{"current_name"}="Building 3D LUT";
 $state->{"message"}=($method eq "ramp")
  ? "Applying drift correction and solving 17-point cube plus 33-point LG payload"
  : ($method eq "lattice")
   ? "Solving lattice matrix + per-node residuals, 17-point cube plus 33-point LG payload"
   : ($method eq "imported")
    ? "Resampling imported .cube to 17-point cube plus 33-point LG payload"
    : "Solving matrix 17-point cube plus 33-point LG payload";
 write_state($state);

 my ($model,$cube_u16,$payload_u16,$preview_nodes);
 if($method eq "imported") {
  ($model,$cube_u16,$payload_u16)=build_imported_lut($config,$state);
 } else {
 # Lattice profiling solves the SAME model as the offline lattice solve
 # (run_solve_only): white-preserving matrix baseline from the corner reads,
 # then bounded per-node residual corrections from the interior nodes. The
 # matrix baseline reads only the white/red/green/blue/black corner kinds,
 # so passing "matrix" here is exact — interior "node" entries are inert.
 $model=model_from_readings(($method eq "lattice") ? "matrix" : $method,\@profile_readings,$config);
 if($method eq "lattice") {
  my @nodes;
  foreach my $entry (@profile_readings) {
   next if(ref($entry) ne "HASH");
   my $nm=(ref($entry->{"step"}) eq "HASH" ? $entry->{"step"}{"name"} : "")||"";
   next unless($nm =~ m{^([0-9.]+)/([0-9.]+)/([0-9.]+)$});
   my $xyz=reading_xyz($entry->{"reading"});
   next if(!$xyz);
   push @nodes,{ fr=>$1/100, fg=>$2/100, fb=>$3/100, xyz=>$xyz };
  }
  $state->{"lattice_nodes"}=scalar(@nodes);
  if(!$config->{"solve_matrix_only"}) {
   my ($grid,$report)=build_residual_grid($model,\@nodes,$config);
   if($grid) {
    $model->{"residual_grid"}=$grid;
    $state->{"lattice_solve"}={ mode=>"matrix_plus_residuals", (ref($report) eq "HASH" ? %{$report} : ()) };
   } else {
    $state->{"lattice_solve"}={ mode=>"matrix_only", residual_skip_reason=>(ref($report) eq "HASH" ? $report->{"reason"} : "unavailable") };
   }
  } else {
   $state->{"lattice_solve"}={ mode=>"matrix_only" };
  }
  $model->{"method"}="lattice";
  log_line("lattice profile solve: nodes=".scalar(@nodes)." mode=".(($state->{"lattice_solve"}||{})->{"mode"}||""));
  # Persist a diagnostic dump (raw node readings + residual grid + drift +
  # corner model) so a lattice run can be analysed offline without re-running
  # hardware -- pinpoints whether the interior deviations are real or drift.
  eval {
   my $dbgdir=$config->{"lut_dir"}||"/var/lib/PGenerator/lg/luts";
   my $dbg="$dbgdir/lattice_debug_".time().".json";
   my %dump=(
    method=>"lattice", signal_mode=>$config->{"signal_mode"},
    target_gamut=>$model->{"target_gamut"}, target_gamma=>$model->{"target_gamma"},
    solve_matrix_only=>($config->{"solve_matrix_only"}?1:0),
    white_y=>$model->{"white_y"}, black=>$model->{"black"},
    contrib_100=>{ map { ($_ => $model->{"contrib"}{$_}{100}) } qw(red green blue) },
    drift=>$state->{"lattice_drift"},
    residual_report=>$state->{"lattice_solve"},
    residual_grid=>$model->{"residual_grid"},
    nodes=>\@nodes,
   );
   if(open(my $df,">",$dbg)) { print $df $json->encode(\%dump); close($df); log_line("lattice debug dump: $dbg"); }
  };
  log_line("lattice debug dump error: $@") if($@);
 }
 ($cube_u16,$preview_nodes)=generate_lut_cube($model,17);
 $payload_u16=generate_lut_lg_payload($model,33);
 }
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
 $state->{"wrgb_comp_source"}=$model->{"wrgb_comp_source"}||"auto";
 $state->{"wrgb_chroma_luma_comp"}=json_bool($model->{"wrgb_chroma_luma_comp"});
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
    # subsequent tone-map upload can land inside the same session. The reference's
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
    # keep_calibration_mode=true). The reference uploads the tone map LAST in its
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

 # HDR20 post-cal shadow correction -- runs AFTER the 3D LUT + tone-map
 # commit (operator-approved reorder, 2026-07-03) so the trim converges
 # against the final viewing state: real cube + tone map committed, cal
 # mode off. The order test on the C1 verified +-2% luminance and
 # dxy <= 0.0016 at 15-35% where the pre-profile order left +4-10%
 # residuals and chroma error. The sub trims via single-socket binds
 # (the cube + tone-map slots persist through DPG-only sessions), then
 # re-establishes a held session with the corrected DPG and an identity
 # container staged; the re-commit below uploads the REAL cube back into
 # that session and re-sends the tone map with the corrected DPG --
 # CAL_END lands everything. Eval-guarded: a shadow failure leaves the
 # already-committed base calibration intact.
 if(lc(($config->{"signal_mode"}||"")) eq "hdr10"
   && $config->{"lg_autocal_hdr20_postcal_shadow_enable"}
   && $config->{"full_workflow"}
   && ($state->{"tone_map_upload_status"}||"") eq "ok"
   && ref($export) eq "HASH" && ($export->{"payload_path"}||"") ne "" && -f $export->{"payload_path"}) {
  eval {
   $state->{"phase"}="postcal_shadow";
   $state->{"current_name"}="HDR20 post-cal shadow correction";
   $state->{"message"}="Trimming the DPG shadow band against the committed calibration";
   write_state($state);
   run_hdr20_postcal_shadow_correction($config,$state,undef);
   my $_sb=$state->{"hdr20_postcal_shadow"};
   if(ref($_sb) eq "HASH") {
    $state->{"message"}=($_sb->{"status"}||"unknown").": 5% lift ".sprintf("%.3f",($_sb->{"lift_before"}||0))." -> ".sprintf("%.3f",($_sb->{"lift_after"}||0)).", M=".($_sb->{"m_counts"}||0)." counts";
   }
   # Re-commit: the sub left a held session (corrected DPG + identity
   # container staged). Upload the real cube into it, then the tone map
   # with the corrected DPG (the sub stored it in full_workflow_dpg_data).
   # Re-commit the calibrated 3D LUT into the held shadow session, then the
   # corrected tone map. Retry the LUT once on failure (a held CAL session can
   # drop transiently during the long shadow zone-probe window); capture the
   # full response detail (status/message/contract/verified) for BOTH uploads
   # so a failure is diagnosable instead of a bare status=error. Flag a
   # LUT-failed/tonemap-ok mismatch loudly — that leaves the panel with a
   # shadow-adjusted tone map over a stale LUT, which visibly degrades the
   # result and must never be silent.
   my $_shadow_upload_detail=sub {
    my($r)=@_;
    return { status => "invalid-response" } if(ref($r) ne "HASH");
    return {
     status => ($r->{status}//""),
     message => ($r->{message}//""),
     upload_verified => $r->{upload_verified} ? JSON::PP::true : JSON::PP::false,
     upload_verify_contract => ($r->{upload_verify_contract}//""),
     readback_unavailable => $r->{readback_unavailable} ? JSON::PP::true : JSON::PP::false,
     repair_hint => ($r->{repair_hint}//""),
    };
   };
   my $_lut_req=sub {
    return {
     picture_mode => $config->{"picture_mode"}||"",
     payload_path => $export->{"payload_path"},
     upload_command => $config->{"upload_command"}||"BT2020_3D_LUT_DATA",
     get_command => $config->{"get_command"}||"GET_3D_LUT_DATA",
     helper_timeout => 220,
     api_timeout => 240,
     keep_calibration_mode => json_true(),
     calibration_mode_active => json_true(),
    };
   };
   my $shadow_lut=api_json("POST","/api/lg/3d-lut/upload",$_lut_req->(),240);
   my $sl_detail=$_shadow_upload_detail->($shadow_lut);
   if(($sl_detail->{status}||"") ne "ok") {
    log_line("HDR20 shadow-after re-commit: 3D LUT upload failed (".($sl_detail->{message}||$sl_detail->{status})."); retrying once after settle");
    select(undef,undef,undef,2.0);
    $shadow_lut=api_json("POST","/api/lg/3d-lut/upload",$_lut_req->(),240);
    $sl_detail=$_shadow_upload_detail->($shadow_lut);
   }
   my $sl_status=$sl_detail->{status}||"";
   $state->{"postcal_shadow_recommit_lut_status"}=$sl_status;
   $state->{"postcal_shadow_recommit_lut_detail"}=$sl_detail;
   log_line("HDR20 shadow-after re-commit: 3D LUT upload status=".$sl_status.(($sl_status ne "ok" && ($sl_detail->{message}||"") ne "")?(" (".$sl_detail->{message}.")"):""));
   my $shadow_peak=0;
   $shadow_peak=$config->{"full_workflow_peak_luminance"}+0 if(defined($config->{"full_workflow_peak_luminance"}) && $config->{"full_workflow_peak_luminance"}+0 > 0);
   my $shadow_tone_req={
    picture_mode => $config->{"picture_mode"}||"",
    peak_luminance => $shadow_peak,
    ddc_layout => "hdr20",
    keep_calibration_mode => json_true(),
    calibration_mode_active => json_true(),
    helper_timeout => 90,
   };
   $shadow_tone_req->{"dpg_data"}=$config->{"full_workflow_dpg_data"} if(ref($config->{"full_workflow_dpg_data"}) eq "ARRAY" && scalar(@{$config->{"full_workflow_dpg_data"}}) == 3072);
   my $shadow_tone=api_json("POST","/api/lg/hdr-tone-map/upload",$shadow_tone_req,105);
   my $st_detail=$_shadow_upload_detail->($shadow_tone);
   my $st_status=$st_detail->{status}||"";
   $state->{"postcal_shadow_recommit_tonemap_status"}=$st_status;
   $state->{"postcal_shadow_recommit_tonemap_detail"}=$st_detail;
   log_line("HDR20 shadow-after re-commit: tone map upload status=".$st_status.(($st_status ne "ok" && ($st_detail->{message}||"") ne "")?(" (".$st_detail->{message}.")"):""));
   # LUT failed but tone map succeeded = stale-LUT/fresh-tonemap mismatch.
   # Surface it loudly so it is never a silent "worse result" mystery.
   if($sl_status ne "ok" && $st_status eq "ok") {
    $state->{"postcal_shadow_recommit_mismatch"}=JSON::PP::true;
    $state->{"postcal_shadow_recommit_mismatch_note"}="3D LUT re-commit failed but tone map succeeded — the panel may be running a shadow-adjusted tone map over a stale 3D LUT. Re-upload the 3D LUT manually.";
    log_line("HDR20 shadow-after re-commit MISMATCH: 3D LUT failed (".$sl_detail->{message}.") but tone map ok — manual 3D LUT re-upload needed");
   } else {
    $state->{"postcal_shadow_recommit_mismatch"}=JSON::PP::false;
   }
   write_state($state);
   1;
  } or do {
   my $shadow_err=$@ || "HDR20 post-cal shadow correction failed";
   $shadow_err=~s/[\r\n]+/ /g;
   die $shadow_err if($shadow_err =~ /^cancelled$/i);
   if(ref($state->{"hdr20_postcal_shadow"}) ne "HASH") { $state->{"hdr20_postcal_shadow"}={}; }
   $state->{"hdr20_postcal_shadow"}->{"status"}="error";
   $state->{"hdr20_postcal_shadow"}->{"note"}=($state->{"hdr20_postcal_shadow"}->{"note"}||"")." eval error: ".$shadow_err;
   write_state($state);
   log_line("HDR20 post-cal shadow correction (after commit) eval error: ".$shadow_err);
  };
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
 if($PGAC_LOADED) {
  eval {
   my $rid = (ref($config) eq 'HASH' ? $config->{'run_id'} : '') || PGAutoCalRun::current();
   if(defined($rid) && $rid ne '') {
    PGAutoCalRun::run_snapshot($rid, '3d-state.json', $state_file, 0);
    PGAutoCalRun::run_snapshot($rid, '3d-log.txt', '/tmp/meter_lg_3d_autocal.log', 0);
    PGAutoCalRun::run_stage($rid, '3d_generate', {
     ok            => (($state->{'status'}||'') eq 'complete') ? JSON::PP::true : JSON::PP::false,
     tv_message    => $state->{'message'} || '',
     worker_status => $state->{'status'} || '',
    });
    PGAutoCalRun::run_merge_manifest($rid, { emitted_lut => {
     lut_grid       => 33,
     lut_data_count => 35937,
     lut_bit_depth  => 12,
    }});
   }
   1;
  };
 }
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
}
