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
  ramp_levels => [ramp_levels()],
  ramp_profile_patch_count => 65,
  ramp_drift => "start/end WRGB anchors with time-interpolated 3x3 correction",
  model => "per-luminance-level additive XYZ contributions",
  neutral_axis => "exact diagonal identity after current 1D greyscale path",
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

sub target_gamma_linear {
 my ($signal,$gamma)=@_;
 $signal=clamp($signal,0,1);
 $gamma=lc($gamma||"bt1886");
 return ($signal <= 0.04045) ? ($signal/12.92) : ((($signal+0.055)/1.055) ** 2.4) if($gamma eq "srgb");
 my $g=($gamma eq "2.2") ? 2.2 : 2.4;
 return $signal ** $g;
}

sub bt709_rgb_to_xyz {
 my ($r,$g,$b,$white_y)=@_;
 $white_y=100 if(!defined($white_y) || $white_y <= 0);
 return [
  (0.4123908*$r + 0.3575843*$g + 0.1804808*$b) * $white_y,
  (0.2126390*$r + 0.7151687*$g + 0.0721923*$b) * $white_y,
  (0.0193308*$r + 0.1191948*$g + 0.9505322*$b) * $white_y,
 ];
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
 my $lin=target_gamma_linear($level/100,$model->{"target_gamma"});
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
 my $lr=target_gamma_linear($r,$model->{"target_gamma"});
 my $lg=target_gamma_linear($g,$model->{"target_gamma"});
 my $lb=target_gamma_linear($b,$model->{"target_gamma"});
 return bt709_rgb_to_xyz($lr,$lg,$lb,$model->{"white_y"});
}

sub srgb_to_linear {
 my $v=shift;
 $v=clamp($v,0,1);
 return ($v <= 0.04045) ? ($v/12.92) : ((($v+0.055)/1.055)**2.4);
}

sub post_check_target_xyz {
	 my ($step,$white_y,$target_gamma)=@_;
	 $white_y=100 if(!defined($white_y) || $white_y <= 0);
	 $target_gamma||="bt1886";
	 my ($r,$g,$b)=(0,0,0);
	 if(defined($step->{"target_linear_r"}) && defined($step->{"target_linear_g"}) && defined($step->{"target_linear_b"})) {
	  $r=clamp($step->{"target_linear_r"}+0,0,1);
	  $g=clamp($step->{"target_linear_g"}+0,0,1);
	  $b=clamp($step->{"target_linear_b"}+0,0,1);
	 } elsif(($step->{"name"}||"") =~ /^Sat\s+([A-Za-z]+)\s+([0-9.]+)%/) {
	  my $color=lc($1);
	  my $sat=target_gamma_linear(clamp(($2+0)/100,0,1),$target_gamma);
	  $r=($color eq "red" || $color eq "magenta" || $color eq "yellow") ? $sat : 0;
	  $g=($color eq "green" || $color eq "cyan" || $color eq "yellow") ? $sat : 0;
	  $b=($color eq "blue" || $color eq "cyan" || $color eq "magenta") ? $sat : 0;
	 } else {
	  $r=target_gamma_linear(($step->{"signal_r_pct"}||0)/100,$target_gamma);
	  $g=target_gamma_linear(($step->{"signal_g_pct"}||0)/100,$target_gamma);
	  $b=target_gamma_linear(($step->{"signal_b_pct"}||0)/100,$target_gamma);
	 }
 return bt709_rgb_to_xyz($r,$g,$b,$white_y);
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
 my $target_gamma=lc($config->{"target_gamma"}||"bt1886");
 $target_gamma="bt1886" unless($target_gamma =~ /^(?:bt1886|2\.2|2\.4|srgb)$/);
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
    my $lin=target_gamma_linear($level/100,$target_gamma);
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
   my $lin=target_gamma_linear($level/100,$target_gamma);
   $white_axis{$level}=vec_add($black,vec_scale(vec_sub($peak->{xyz},$black),$lin)) if($peak);
  } else {
   $white_axis{$level}=vec_add($black,vec_add($contrib{"red"}{$level}||[0,0,0],vec_add($contrib{"green"}{$level}||[0,0,0],$contrib{"blue"}{$level}||[0,0,0])));
  }
 }
 my $white100=$white_axis{100} || $by{"profile"}{"white"}{100}{xyz} || [95.047,100,108.883];
 my $white_y=$white100->[1] || 100;
 my $peak_matrix=matrix_for_level({
  contrib=>\%contrib,
  target_gamma=>$target_gamma,
 },100);
 my $peak_inverse=matrix_inverse($peak_matrix);
 $peak_inverse ||= [
  [ 3.2406/$white_y, -1.5372/$white_y, -0.4986/$white_y ],
  [ -0.9689/$white_y, 1.8758/$white_y, 0.0415/$white_y ],
  [ 0.0557/$white_y, -0.2040/$white_y, 1.0570/$white_y ],
 ];
 my %peak_y;
 foreach my $kind (qw(red green blue)) {
  $peak_y{$kind}=($contrib{$kind}{100} && $contrib{$kind}{100}[1] > 0) ? $contrib{$kind}{100}[1] : 1;
 }
 return {
  method => $method,
  target_gamma => $target_gamma,
  black => $black,
  contrib => \%contrib,
  white_axis => \%white_axis,
  white_y => $white_y,
  peak_y => \%peak_y,
  peak_inverse => $peak_inverse,
  drift => $drift,
  neutral_axis_source => "exact diagonal identity after current 1D greyscale path",
 };
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
    if($r==$g && $g==$b) {
     my $pct=100*$r/($size-1);
     $out=[$pct,$pct,$pct];
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

sub generate_lut_lg_payload {
 my ($model,$size)=@_;
 $size ||= 33;
 my @u16;
 for(my $b=0;$b<$size;$b++) {
  for(my $g=0;$g<$size;$g++) {
   for(my $r=0;$r<$size;$r++) {
    my $out;
    if($r==$g && $g==$b) {
     my $pct=100*$r/($size-1);
     $out=[$pct,$pct,$pct];
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
 my $gamut="bt709";
 my $base="$dir/${stamp}_${method}_${picture}_${gamut}";
 my $binary=pack("v*",@{$payload_u16});
 write_file("$base.bin",$binary,1) or die "Unable to write LG 3D LUT payload\n";
 write_file("$base.cube",cube_text($cube_u16,17,"PGenerator LG SDR $method $picture $gamut"),0) or die "Unable to write cube export\n";
 write_file("$base.json",$json->encode({
  status => "ok",
  method => $method,
  picture_mode => $picture,
  target_gamut => $gamut,
  lut_size => 17,
  cube_lut_size => 17,
  payload_lut_size => 33,
  payload_bits => 12,
  payload_endianness => "little-endian uint16",
  payload_axis_order => "R fastest, G middle, B slowest",
  payload_channel_order => "RGB values per node",
  neutral_axis_source => $model->{"neutral_axis_source"},
  neutral_axis_protection => "exact diagonal identity",
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

sub read_request_id {
 my ($step)=@_;
 my $name=$step->{"phase"}."_".$step->{"kind"}."_".format_percent($step->{"level"});
 $name=~s/[^A-Za-z0-9_.-]+/_/g;
 return "autocal3d_".$$."_".int(time()*1000)."_".$name."_".int(rand(1000000));
}

sub read_step_once {
 my ($config,$step)=@_;
 my $delay_ms=int($config->{"delay_ms"}||500);
 $delay_ms=1800 if($delay_ms < 1800);
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
  signal_mode => "sdr",
  target_gamma => $config->{"target_gamma"}||"bt1886",
  target_gamut => "bt709",
  max_luma => $config->{"max_luma"}||1000,
  refresh_rate => $config->{"refresh_rate"}||"",
  measurement_meter_port => $config->{"measurement_meter_port"}||"",
  request_id => $request_id,
  require_device_ready => $config->{"require_device_ready"} ? json_true() : json_false(),
 };
 my $started=time();
 my $start=api_json("POST","/api/meter/read",$payload,55);
 return (undef,$start->{"message"}||"Unable to start meter read") if(($start->{"status"}||"") eq "error");
 my $deadline=time()+150;
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
 my $gamma=target_gamma_linear($level,$config->{"target_gamma"}||"bt1886");
 my $kind=$step->{"kind"}||"black";
 my $xyz;
 if($kind eq "black") { $xyz=[0,0,0]; }
 elsif($kind eq "white") { $xyz=bt709_rgb_to_xyz($gamma,$gamma,$gamma,100); }
 elsif($kind eq "red") { $xyz=bt709_rgb_to_xyz($gamma,0,0,100); }
 elsif($kind eq "green") { $xyz=bt709_rgb_to_xyz(0,$gamma,0,100); }
 else { $xyz=bt709_rgb_to_xyz(0,0,$gamma,100); }
 return { X=>$xyz->[0], Y=>$xyz->[1], Z=>$xyz->[2], x=>0, y=>0, luminance=>$xyz->[1], timestamp=>time() };
}

sub read_step {
 my ($config,$step,$state)=@_;
 my $fixture=fixture_reading_for_step($step,$config);
 return ($fixture,undef) if($fixture);
 my $attempts=3;
 my $last="";
 for(my $i=1;$i<=$attempts;$i++) {
  my ($reading,$error)=read_step_once($config,$step);
  return ($reading,undef) if(!$error);
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

sub reset_3d_lut_to_unity_before_profile {
 my ($config,$state)=@_;
 return undef if(!upload_requested($config) || $config->{"fixture_mode"});
 die "cancelled\n" if(cancelled());
 if($config->{"skip_preprofile_unity_reset"} && $config->{"preflight_3d_lut_verified"}) {
  $state->{"phase"}="unity_reset_skipped";
  $state->{"current_step"}=0;
  $state->{"current_name"}="Using verified LG 3D LUT baseline";
  $state->{"message"}="Skipping matrix-stage unity reset; Full AutoCal preflight already verified the 3D LUT baseline";
  my $reset={
   status => "ok",
   upload_verified => json_true(),
   upload_supported => json_true(),
   upload_command => $config->{"preflight_3d_lut_upload_command"}||$config->{"upload_command"}||"",
   get_command => $config->{"preflight_3d_lut_get_command"}||$config->{"get_command"}||"",
   message => "Using verified Full AutoCal preflight unity 3D LUT reset.",
   reset_to_unity => json_true(),
   preflight_unity_reset => json_true(),
   skipped => json_true(),
  };
  $state->{"unity_reset"}=$reset;
  $state->{"unity_reset_verified"}=json_true();
  $state->{"upload_supported"}=json_true();
  write_state($state);
  return $reset;
 }
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
unlink($stop_file);
my $method=lc($config->{"method"}||"matrix");
$method="matrix" unless($method eq "matrix" || $method eq "ramp");
$config->{"signal_mode"}="sdr";
$config->{"target_gamut"}="bt709";
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
 target_gamut => "bt709",
 target_gamma => $config->{"target_gamma"}||"bt1886",
};
write_state($state);
my $upload_requested=upload_requested($config);

eval {
 die "LG 3D LUT Auto Cal is SDR-only in this version\n" if(lc($config->{"requested_signal_mode"}||$config->{"ui_signal_mode"}||"sdr") ne "sdr");
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
 $state->{"drift"}=$model->{"drift"};
 $state->{"neutral_axis_source"}=$model->{"neutral_axis_source"};
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
   $state->{"message"}="Writing generated BT.709 3D LUT";
   write_state($state);
   my $upload=api_json("POST","/api/lg/3d-lut/upload",{
   picture_mode => $config->{"picture_mode"}||"",
   payload_path => $export->{"payload_path"},
    upload_command => $probe->{"upload_command"}||"",
    get_command => $probe->{"get_command"}||"",
    helper_timeout => 220,
   },240);
   $state->{"upload"}=$upload;
   $state->{"upload_supported"}=(ref($upload) eq "HASH" && $upload->{"status"} eq "ok") ? json_true() : json_false();
   $state->{"upload_verified"}=(ref($upload) eq "HASH" && $upload->{"upload_verified"}) ? json_true() : json_false();
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
   my $target=post_check_target_xyz($step,$model->{"white_y"}||100,$model->{"target_gamma"}||$config->{"target_gamma"}||"bt1886");
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
