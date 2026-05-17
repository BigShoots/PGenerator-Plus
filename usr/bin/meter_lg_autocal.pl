#!/usr/bin/perl

use strict;
use warnings;
use Errno qw(EINTR);
use JSON::PP ();
use IO::Select ();
use IO::Socket::INET ();
use MIME::Base64 ();
use Time::HiRes qw(sleep time);

my $config_file = shift || "/tmp/meter_lg_autocal_config.json";
my $state_file = shift || "/tmp/meter_lg_autocal.json";
my $stop_file = shift || "/tmp/meter_lg_autocal.stop";
my $api_host = "127.0.0.1";
my $api_port = 80;
my $json = JSON::PP->new->canonical(1);
my $cancelled = 0;
our $LG_AUTOCAL_HEADROOM_TARGET_LUMINANCE = 0;
our $LG_AUTOCAL_SETUP_LUMINANCE = 0;

$SIG{TERM} = sub { $cancelled = 1; };
$SIG{INT} = sub { $cancelled = 1; };

sub log_line {
 my ($message)=@_;
 $message="" if(!defined($message));
 my @lt=localtime();
 my $stamp=sprintf("%02d:%02d:%02d",$lt[2],$lt[1],$lt[0]);
 print STDERR "[$stamp] $message\n";
}

my $trace_109_file="/var/log/PGenerator/lg-autocal-109-trace.log";

sub trace_number {
 my ($value)=@_;
 return undef if(!defined($value));
 return ($value+0) if($value =~ /^-?(?:\d+(?:\.\d*)?|\.\d+)(?:e[+-]?\d+)?$/i);
 return $value;
}

sub trace_109_enabled {
 my ($step)=@_;
 return 0 if(ref($step) ne "HASH" || !defined($step->{"ire"}));
 my $ire=$step->{"ire"}+0;
 return 1 if($ire > 0 && $ire <= 10.0001);
 return 1 if(abs($ire-99) < 0.001 || abs($ire-100) < 0.001 || abs($ire-105) < 0.001);
 return abs($ire-109) < 0.001 ? 1 : 0;
}

sub trace_reading_summary {
 my ($reading)=@_;
 return undef if(ref($reading) ne "HASH");
 my %out;
 foreach my $key (qw(name ire nominal_ire plot_ire stimulus patch_stimulus patch_ire r_code g_code b_code signal_r_pct signal_g_pct signal_b_pct X Y Z x y luminance cct target_x target_y target_luminance target_Yn read_delay_ms display_type request_id timestamp)) {
  $out{$key}=trace_number($reading->{$key}) if(defined($reading->{$key}));
 }
 return \%out;
}

sub trace_adjustments_summary {
 my ($adjustments)=@_;
 return [] if(ref($adjustments) ne "ARRAY");
 my @out;
 foreach my $adj (@{$adjustments}) {
  next if(ref($adj) ne "HASH");
  my %item;
  foreach my $key (qw(channel setting current next delta damped micro sweep neutral_luminance)) {
   $item{$key}=trace_number($adj->{$key}) if(defined($adj->{$key}));
  }
  push @out,\%item;
 }
 return \@out;
}

sub trace_target_values {
 my ($arrays,$target)=@_;
 return undef if(ref($arrays) ne "HASH" || ref($target) ne "HASH");
 my $idx=$target->{"index"};
 return undef if(!defined($idx));
 my %out;
 foreach my $setting (qw(whiteBalanceRed whiteBalanceGreen whiteBalanceBlue adjustingLuminance)) {
  my $arr=$arrays->{$setting};
  next if(ref($arr) ne "ARRAY");
  $out{$setting}=trace_number($arr->[$idx]) if(defined($arr->[$idx]));
 }
 return \%out;
}

sub trace_109 {
 my ($step,$event,$data)=@_;
 return if(!trace_109_enabled($step));
 $event||="event";
 $data={} if(ref($data) ne "HASH");
 my @lt=localtime();
 my $stamp=sprintf("%04d-%02d-%02dT%02d:%02d:%02d",$lt[5]+1900,$lt[4]+1,$lt[3],$lt[2],$lt[1],$lt[0]);
 my %row=(ts=>$stamp,pid=>$$,event=>$event,ire=>($step->{"ire"}+0));
 $row{"stimulus"}=$step->{"stimulus"}+0 if(defined($step->{"stimulus"}));
 $row{"name"}=$step->{"name"} if(defined($step->{"name"}));
 foreach my $key (keys %{$data}) {
  $row{$key}=$data->{$key};
 }
 eval {
  open(my $fh,">>",$trace_109_file) or die $!;
  print $fh $json->encode(\%row)."\n";
  close($fh);
  chmod(0666,$trace_109_file);
  1;
 } or do {
  log_line("Unable to write 109 trace: $@");
 };
}

sub read_file {
 my ($path)=@_;
 return "" if(!defined($path) || !-f $path);
 open(my $fh,"<",$path) or return "";
 local $/;
 my $data=<$fh>;
 close($fh);
 return $data;
}

sub write_file {
 my ($path,$data)=@_;
 open(my $fh,">",$path) or return 0;
 print $fh $data;
 close($fh);
 chmod(0666,$path);
 return 1;
}

sub decode_json_safe {
 my ($raw,$fallback)=@_;
 $fallback={} if(!defined($fallback));
 return $fallback if(!defined($raw) || $raw eq "");
 my $data;
 eval { $data=$json->decode($raw); 1; } or return $fallback;
 return defined($data) ? $data : $fallback;
}

sub api_json {
 my ($method,$path,$payload,$timeout)=@_;
 $method ||= "GET";
 $timeout ||= 30;
 $timeout=1 if($timeout < 1);
 my $body = defined($payload) ? $json->encode($payload) : "";
 my $deadline=time()+$timeout;
 my $socket = IO::Socket::INET->new(
  PeerHost => $api_host,
  PeerPort => $api_port,
  Proto => "tcp",
  Timeout => $timeout,
 );
 return { status=>"error", message=>"Web UI API is unavailable" } if(!$socket);
 $socket->autoflush(1);
 my $request = "$method $path HTTP/1.1\r\nHost: $api_host\r\nConnection: close\r\nAccept: application/json\r\n";
 if($method ne "GET") {
  $request .= "Content-Type: application/json\r\nContent-Length: ".length($body)."\r\n\r\n".$body;
 } else {
  $request .= "\r\n";
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
   log_line("$method $path timed out after ${timeout}s");
   return { status=>"error", message=>"Web UI API timed out during $path" };
  }
  my @ready=$selector->can_read($remaining > 1 ? 1 : $remaining);
  next if(!@ready);
  my $len=sysread($socket,$buf,8192);
  if(!defined($len)) {
   next if($! == EINTR);
   close($socket);
   log_line("$method $path read failed: $!");
   return { status=>"error", message=>"Web UI API read failed during $path" };
  }
  last if($len == 0);
  $raw.=$buf;
 }
 close($socket);
 my ($headers,$content)=split(/\r?\n\r?\n/,$raw,2);
 $content="" if(!defined($content));
 my $result=decode_json_safe($content,{});
 if(ref($result) eq "HASH" && %{$result}) {
  return $result;
 }
 log_line("$method $path returned an invalid response");
 return { status=>"error", message=>"Invalid Web UI API response" };
}

sub shell_quote {
 my ($text)=@_;
 $text="" if(!defined($text));
 $text =~ s/'/'"'"'/g;
 return "'$text'";
}

sub lg_helper_json {
 my ($request,$timeout)=@_;
 $request={} if(ref($request) ne "HASH");
 $timeout ||= 170;
 my $helper="/usr/sbin/pgenerator-lg";
 return { status=>"error", message=>"LG WebOS helper is not installed" } if(!-x $helper);
 my $payload=MIME::Base64::encode_base64($json->encode($request),"");
 my $cmd="timeout ".int($timeout)."s env PGEN_LG_REQUEST_B64=".shell_quote($payload)." ".shell_quote($helper)." 2>&1";
 my $raw=`$cmd`;
 my $exit_status=$? >> 8;
 my $result=decode_json_safe($raw,{});
 return $result if(ref($result) eq "HASH" && ($result->{"status"}||"") ne "");
 return { status=>"error", message=>"LG TV did not finish the white-balance write" } if($exit_status == 124 || $exit_status == 137);
 $raw=~s/[\r\n]+/ /g;
 $raw=~s/\s+/ /g;
 $raw=~s/^\s+//;
 $raw=~s/\s+$//;
 $raw="LG helper execution failed" if($raw eq "");
 return { status=>"error", message=>$raw };
}

sub lg_clients {
 return decode_json_safe(read_file("/var/lib/PGenerator/lg/clients.json"),{});
}

sub lg_helper_picture_set {
	 my ($settings,$picture_mode,$calibration_mode_active,$verify_ddc_upload,$keep_calibration_mode)=@_;
	 $keep_calibration_mode=1 if(!defined($keep_calibration_mode));
	 my $clients=lg_clients();
 my $ip=$clients->{"manual_ip"}||$clients->{"ip"}||"";
 my $client_key=$clients->{"client_key"}||$clients->{"client-key"}||"";
 return undef if($ip eq "" || $client_key eq "");
 return lg_helper_json({
  action => "picture_set",
	  ip => $ip,
	  client_key => $client_key,
	  settings => $settings,
	  readback_keys => ["pictureMode","whiteBalanceMethod","whiteBalanceIre","whiteBalanceRed","whiteBalanceGreen","whiteBalanceBlue","adjustingLuminance"],
		  picture_mode => $picture_mode||$clients->{"calibration_picture_mode"}||"",
				  keep_calibration_mode => $keep_calibration_mode ? JSON::PP::true : JSON::PP::false,
			  calibration_mode_active => $calibration_mode_active ? JSON::PP::true : JSON::PP::false,
			  verify_ddc_upload => $verify_ddc_upload ? JSON::PP::true : JSON::PP::false,
			  force_ddc_white_balance => JSON::PP::true,
			  connect_timeout => 8,
			 },170);
		}

sub lg_helper_picture_get {
 my ($keys,$picture_mode)=@_;
 $keys=[] if(ref($keys) ne "ARRAY");
 my $clients=lg_clients();
 my $ip=$clients->{"manual_ip"}||$clients->{"ip"}||"";
 my $client_key=$clients->{"client_key"}||$clients->{"client-key"}||"";
 return undef if($ip eq "" || $client_key eq "");
 return lg_helper_json({
  action => "picture_get",
  ip => $ip,
	  client_key => $client_key,
	  keys => $keys,
	  picture_mode => $picture_mode||$clients->{"calibration_picture_mode"}||"",
	  force_ddc_white_balance => JSON::PP::true,
	  connect_timeout => 8,
	 },120);
}

sub cancelled {
 return 1 if($cancelled);
 return 1 if(-f $stop_file);
 return 0;
}

sub format_percent {
 my ($value)=@_;
 $value=0 if(!defined($value));
 my $text=sprintf("%.2f",$value+0);
 $text=~s/0+$//;
 $text=~s/\.$//;
 return $text;
}

sub ddc_slots {
 return (2.3,3,4,5,7,10,15,20,25,30,35,40,45,50,55,60,65,70,75,80,85,90,95,99,105,109);
}

sub ddc_slot_count {
 my @slots=ddc_slots();
 return scalar(@slots);
}

sub ddc_target_for_step {
 my ($step)=@_;
 return undef if(ref($step) ne "HASH");
 my $ire=defined($step->{"ddc_target_ire"}) ? $step->{"ddc_target_ire"} : $step->{"ire"};
 return undef if(!defined($ire));
 my @slots=ddc_slots();
 for(my $i=0;$i<@slots;$i++) {
  my $label=$step->{"autocal_target_label"} || format_percent($slots[$i])."%";
  return { index=>$i, ire=>format_percent($slots[$i]), label=>$label }
   if(abs(($ire+0)-$slots[$i]) < 0.001);
 }
 return undef;
}

sub steps_share_ddc_target {
 my ($a,$b)=@_;
 my $ta=ddc_target_for_step($a);
 my $tb=ddc_target_for_step($b);
 return 0 if(ref($ta) ne "HASH" || ref($tb) ne "HASH");
 return (defined($ta->{"index"}) && defined($tb->{"index"}) && $ta->{"index"} == $tb->{"index"}) ? 1 : 0;
}

sub autocal_skip_duplicate_ddc_slot {
 my ($step,$config)=@_;
 return 0 if(ref($config) ne "HASH" || !$config->{"lg_autocal_26"});
 return 1 if(ref($step) eq "HASH" && $step->{"autocal_white_reference"} && defined($step->{"ddc_target_ire"}));
 return 0;
}

sub order_autocal_steps {
 my ($steps,$config)=@_;
 return () if(ref($steps) ne "ARRAY");
 my @valid=grep { ref($_) eq "HASH" && defined($_->{"ire"}) && abs(($_->{"ire"}+0)) >= 0.001 && ddc_target_for_step($_) && !autocal_skip_duplicate_ddc_slot($_,$config) } @{$steps};
 return sort {
  my $av=defined($a->{"autocal_order_ire"}) ? ($a->{"autocal_order_ire"}+0) : ($a->{"ire"}||0);
  my $bv=defined($b->{"autocal_order_ire"}) ? ($b->{"autocal_order_ire"}+0) : ($b->{"ire"}||0);
  $bv <=> $av
 } @valid
  if(ref($config) eq "HASH" && $config->{"lg_autocal_26"});
 my @ordered;
 my %seen;
 my $add_nearest=sub {
  my ($wanted)=@_;
  my ($best,$best_distance);
  foreach my $step (@valid) {
   my $key=format_percent($step->{"ire"});
   next if($seen{$key});
   my $distance=abs(($step->{"ire"}+0)-$wanted);
   next if(defined($best_distance) && $distance >= $best_distance);
   $best=$step;
   $best_distance=$distance;
 }
 return if(!$best);
 push @ordered,$best;
  $seen{format_percent($best->{"ire"})}=1;
 };
 my ($top)=sort { ($b->{"ire"}||0) <=> ($a->{"ire"}||0) } grep { !$seen{format_percent($_->{"ire"})} } @valid;
 if($top) {
  push @ordered,$top;
  $seen{format_percent($top->{"ire"})}=1;
 }
 $add_nearest->(50);
 $add_nearest->(25);
 $add_nearest->(75);
 foreach my $step (sort { ($b->{"ire"}||0) <=> ($a->{"ire"}||0) } @valid) {
  my $key=format_percent($step->{"ire"});
  next if($seen{$key});
  push @ordered,$step;
  $seen{$key}=1;
 }
 return @ordered;
}

sub verification_autocal_steps {
 my ($steps)=@_;
 return () if(ref($steps) ne "ARRAY");
 my @verify=grep {
  ref($_) eq "HASH" &&
  defined($_->{"ire"}) &&
  abs(($_->{"ire"}+0)) >= 0.001 &&
  $_->{"autocal_read_only"} &&
  !$_->{"autocal_white_reference"} &&
  !ddc_target_for_step($_)
 } @{$steps};
 return sort { ($a->{"ire"}||0) <=> ($b->{"ire"}||0) } @verify;
}

sub ddc_step_signal_mismatch {
 my ($step,$config)=@_;
 return "" if(ref($step) ne "HASH");
 return "" if(ref($config) ne "HASH" || !$config->{"strict_lg_autocal_slot_signal"});
 my $target=ddc_target_for_step($step);
 return "" if(!$target);
 my $ire=$target->{"ire"}+0;
 foreach my $field (
  ["stimulus","stimulus"],
  ["signal_r_pct","red stimulus"],
  ["signal_g_pct","green stimulus"],
  ["signal_b_pct","blue stimulus"],
 ) {
  my ($key,$label)=@{$field};
  next if(!defined($step->{$key}));
  my $value=$step->{$key}+0;
  if(abs($value-$ire) > 0.05) {
   return $target->{"label"}." LG Auto Cal slot is using ".format_percent($value)."% ".$label.". Reload the page and start Auto Cal again.";
  }
 }
 return "";
}

sub numeric_array {
 my ($value,$count)=@_;
 $count ||= 22;
 my @out;
 if(ref($value) eq "ARRAY") {
  foreach my $entry (@{$value}) {
   my $n=defined($entry) ? ($entry+0) : 0;
   push @out,$n;
  }
 }
 while(@out < $count) { push @out,0; }
 @out=@out[0..($count-1)] if(@out > $count);
 return \@out;
}

sub clone_picture {
	 my ($picture)=@_;
	 return decode_json_safe($json->encode($picture||{}),{});
}

sub sync_state_picture {
	 my ($state,$picture,$picture_mode)=@_;
	 return if(ref($state) ne "HASH" || ref($picture) ne "HASH");
	 $state->{"picture_settings"}=clone_picture($picture);
	 $state->{"picture_mode"}=$picture_mode if(defined($picture_mode) && $picture_mode ne "");
}

sub luminance {
 my ($reading)=@_;
 return undef if(ref($reading) ne "HASH");
 return $reading->{"luminance"}+0 if(defined($reading->{"luminance"}));
 return $reading->{"Y"}+0 if(defined($reading->{"Y"}));
 return undef;
}

sub pq_encode_normalized {
 my ($nits)=@_;
 $nits=0 if(!defined($nits) || $nits < 0);
 $nits=10000 if($nits > 10000);
 return 0 if($nits <= 0);
 my $l=$nits/10000;
 my $m1=2610/16384;
 my $m2=2523/32;
 my $c1=3424/4096;
 my $c2=2413/128;
 my $c3=2392/128;
 my $p=$l ** $m1;
 return (($c1+$c2*$p)/(1+$c3*$p)) ** $m2;
}

sub reading_xyz {
 my ($reading)=@_;
 return undef if(ref($reading) ne "HASH");
 my ($X,$Y,$Z)=($reading->{"X"},$reading->{"Y"},$reading->{"Z"});
 if((!defined($X) || !defined($Y) || !defined($Z)) && defined($reading->{"x"}) && defined($reading->{"y"}) && defined(luminance($reading)) && $reading->{"y"} > 0) {
  $Y=luminance($reading);
  $X=($reading->{"x"}/$reading->{"y"})*$Y;
  $Z=((1-$reading->{"x"}-$reading->{"y"})/$reading->{"y"})*$Y;
 }
 return undef if(!defined($X) || !defined($Y) || !defined($Z));
 return [$X+0,$Y+0,$Z+0];
}

sub xyz_from_xyy {
 my ($x,$y,$Y)=@_;
 return undef if(!defined($x) || !defined($y) || !defined($Y) || $y <= 0);
 return [($x/$y)*$Y,$Y,((1-$x-$y)/$y)*$Y];
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
  P=>(17933*$Lp-17390*$Mp-543*$Sp)/4096,
 };
}

sub delta_e_itp_xyz {
 my ($actual,$target)=@_;
 return undef if(ref($actual) ne "ARRAY" || ref($target) ne "ARRAY");
 my $a=xyz_to_ictcp($actual->[0],$actual->[1],$actual->[2]);
 my $b=xyz_to_ictcp($target->[0],$target->[1],$target->[2]);
 my $dI=($a->{"I"}||0)-($b->{"I"}||0);
 my $dT=($a->{"T"}||0)-($b->{"T"}||0);
 my $dP=($a->{"P"}||0)-($b->{"P"}||0);
 return 720*sqrt($dI*$dI+0.25*$dT*$dT+$dP*$dP);
}

sub clamp_unit {
 my ($value)=@_;
 $value=0 if(!defined($value));
 $value+=0;
 return 0 if($value < 0);
 return 1 if($value > 1);
 return $value;
}

sub target_gamma_linear {
 my ($signal,$target_gamma,$signal_mode)=@_;
 $signal=0 if(!defined($signal));
 $signal+=0;
 $signal=0 if($signal < 0);
 $signal_mode=lc($signal_mode||"sdr");
 $signal=1 if($signal > 1 && $signal_mode ne "sdr");
 return 0 if($signal <= 0);
 $target_gamma=lc($target_gamma||"bt1886");
 if($target_gamma eq "srgb") {
  return ($signal <= 0.04045) ? ($signal/12.92) : ((($signal+0.055)/1.055) ** 2.4);
 }
 if($signal_mode eq "dv" && $target_gamma eq "st2084") {
  return $signal ** 2.2;
 }
 my $gamma=($target_gamma eq "2.2") ? 2.2 : 2.4;
 return $signal ** $gamma;
}

sub target_luminance_for_step {
	 my ($white_y,$step,$target_gamma,$signal_mode)=@_;
	 return undef if(ref($step) ne "HASH" || !defined($white_y) || $white_y <= 0);
	 my $stimulus=defined($step->{"stimulus"}) ? ($step->{"stimulus"}+0) : (defined($step->{"ire"}) ? ($step->{"ire"}+0) : undef);
	 return undef if(!defined($stimulus));
	 return 0 if($stimulus <= 0);
	 my $mode=lc($signal_mode||"sdr");
	 my $signal=$stimulus/100;
	 $signal=1 if($signal > 1 && $mode ne "sdr");
	 $signal=1.1 if($signal > 1.1);
	 return $white_y * target_gamma_linear($signal,$target_gamma,$signal_mode);
}

sub autocal_step_is_white {
		 my ($step)=@_;
		 return 0 if(ref($step) ne "HASH" || !defined($step->{"ire"}));
		 return 1 if($step->{"autocal_white_reference"});
		 return abs(($step->{"ire"}+0)-100) < 0.001 ? 1 : 0;
}

sub autocal_step_is_fast_headroom {
 my ($step)=@_;
 return 0 if(ref($step) ne "HASH" || !defined($step->{"ire"}));
 my $ire=$step->{"ire"}+0;
 return $ire >= 105 ? 1 : 0;
}

sub autocal_step_is_peak_headroom {
 my ($step)=@_;
 return 0 if(ref($step) ne "HASH" || !defined($step->{"ire"}));
 my $ire=$step->{"ire"}+0;
 return $ire >= 108.5 ? 1 : 0;
}

sub autocal_step_ignores_luminance_error {
 my ($step)=@_;
 return autocal_step_is_peak_headroom($step) ? 1 : 0;
}

sub autocal_step_uses_direct_headroom_balance {
 my ($step)=@_;
 return autocal_step_is_peak_headroom($step);
}

sub autocal_step_is_low_shadow {
 my ($step)=@_;
 return 0 if(ref($step) ne "HASH" || !defined($step->{"ire"}));
 my $ire=$step->{"ire"}+0;
 return ($ire > 0 && $ire <= 5.0001) ? 1 : 0;
}

sub autocal_config_is_touchup {
 my ($config)=@_;
 return (ref($config) eq "HASH" && $config->{"full_autocal_touchup"}) ? 1 : 0;
}

sub low_shadow_iteration_limit_for_step {
 my ($step,$config)=@_;
 return undef if(!autocal_step_is_low_shadow($step));
 my $ire=$step->{"ire"}+0;
 if(autocal_config_is_touchup($config)) {
  return 8 if($ire <= 3.1);
  return 10;
 }
 return 20 if($ire <= 3.1);
 return 24;
}

sub low_shadow_polish_limit_for_step {
 my ($step,$config)=@_;
 return undef if(!autocal_step_is_low_shadow($step));
 my $ire=$step->{"ire"}+0;
 if(autocal_config_is_touchup($config)) {
  return 4 if($ire <= 3.1);
  return 2;
 }
 return 12 if($ire <= 3.1);
 return 6;
}

sub low_shadow_minimum_ddc_step {
 my ($step)=@_;
 return 0.25 if(ref($step) ne "HASH" || !defined($step->{"ire"}));
 my $ire=$step->{"ire"}+0;
 return 0.10 if($ire > 0 && $ire <= 3.1);
 return 0.25;
}

sub headroom_iteration_limit_for_step {
 my ($step)=@_;
 return undef if(!autocal_step_is_fast_headroom($step));
 my $ire=$step->{"ire"}+0;
 return 60 if($ire >= 108.5);
 return 36;
}

sub headroom_polish_limit_for_step {
 my ($step)=@_;
 return undef if(!autocal_step_is_fast_headroom($step));
 my $ire=$step->{"ire"}+0;
 return 16 if($ire >= 108.5);
 return 10;
}

sub autocal_step_allows_final_fine_tune {
 my ($step,$best_de,$target_delta)=@_;
 return 1 if(!autocal_step_is_fast_headroom($step));
 return 0 if(!defined($best_de));
 $target_delta=0.5 if(!defined($target_delta) || $target_delta <= 0);
 return 1 if($best_de <= 5.0 && $best_de > headroom_fine_target_delta($step,$target_delta));
 return 0;
}

sub update_white_reference_for_step {
		 my ($step,$reading,$white_y)=@_;
		 return $white_y if(!autocal_step_is_white($step));
		 my $Y=luminance($reading);
		 return (defined($Y) && $Y > 0) ? $Y : $white_y;
}

sub target_luminance_for_autocal_step {
		 my ($white_y,$step,$target_gamma,$signal_mode)=@_;
		 return undef if(autocal_step_is_white($step));
		 if(autocal_step_is_peak_headroom($step)) {
		  my $target_lum_y=target_luminance_for_step($white_y,$step,$target_gamma,$signal_mode);
		  return $target_lum_y if(defined($target_lum_y));
		  return $LG_AUTOCAL_HEADROOM_TARGET_LUMINANCE if($LG_AUTOCAL_HEADROOM_TARGET_LUMINANCE > 0);
		  return undef;
		 }
		 return target_luminance_for_step($white_y,$step,$target_gamma,$signal_mode);
	}

sub effective_target_luminance_for_autocal_reading {
 my ($white_y,$step,$reading,$target_gamma,$signal_mode)=@_;
 my $target=target_luminance_for_autocal_step($white_y,$step,$target_gamma,$signal_mode);
 if(!defined($target) && autocal_step_is_peak_headroom($step)) {
  my $Y=luminance($reading);
  return $Y if(defined($Y) && $Y > 0);
 }
 return $target;
}

sub derived_white_reference_from_peak_headroom {
 my ($step,$reading,$target_gamma,$signal_mode)=@_;
 return undef if(!autocal_step_is_peak_headroom($step) || ref($reading) ne "HASH");
 my $Y=luminance($reading);
 return undef if(!defined($Y) || $Y <= 0);
 my $stimulus=defined($step->{"stimulus"}) ? ($step->{"stimulus"}+0) : (defined($step->{"ire"}) ? ($step->{"ire"}+0) : undef);
 return undef if(!defined($stimulus) || $stimulus <= 0);
 my $signal=$stimulus/100;
 $signal=1.1 if($signal > 1.1);
 my $linear=target_gamma_linear($signal,$target_gamma,$signal_mode);
 return undef if(!defined($linear) || $linear <= 0);
 return $Y/$linear;
}

sub apply_peak_headroom_reference {
	 my ($state,$step,$reading,$white_y_ref,$target_gamma,$signal_mode,$target_x,$target_y)=@_;
	 return undef if(ref($white_y_ref) ne "SCALAR");
	 return $$white_y_ref if(!autocal_step_is_peak_headroom($step));
	 my $derived=derived_white_reference_from_peak_headroom($step,$reading,$target_gamma,$signal_mode);
	 $$white_y_ref=$derived if(defined($derived) && $derived > 0);
	 my $effective_white=$$white_y_ref;
	 my $reading_y=luminance($reading);
	 if(ref($state) eq "HASH") {
	  $state->{"peak_headroom_luminance"}=$reading_y if(defined($reading_y));
	  $state->{"peak_headroom_reference"}=$effective_white if(defined($effective_white));
	  set_state_white_reference($state,$effective_white) if(defined($effective_white) && $effective_white > 0);
	 }
	 my $peak_target_y=(defined($effective_white) && $effective_white > 0) ? target_luminance_for_step($effective_white,$step,$target_gamma,$signal_mode) : undef;
	 if(defined($peak_target_y) && $peak_target_y > 0) {
	  $LG_AUTOCAL_HEADROOM_TARGET_LUMINANCE=$peak_target_y;
	  if(ref($state) eq "HASH") {
	   $state->{"headroom_target_luminance"}=$peak_target_y;
	   set_state_target_step_luminance($state,$peak_target_y);
	  }
	  annotate_reading_target($reading,$effective_white,$peak_target_y,$target_x,$target_y) if(ref($reading) eq "HASH");
	  return $effective_white;
	 }
	 if($LG_AUTOCAL_HEADROOM_TARGET_LUMINANCE > 0) {
	  if(ref($state) eq "HASH") {
	   $state->{"headroom_target_luminance"}=$LG_AUTOCAL_HEADROOM_TARGET_LUMINANCE;
	   set_state_target_step_luminance($state,$LG_AUTOCAL_HEADROOM_TARGET_LUMINANCE);
	  }
	  annotate_reading_target($reading,$effective_white,$LG_AUTOCAL_HEADROOM_TARGET_LUMINANCE,$target_x,$target_y)
	   if(ref($reading) eq "HASH" && defined($effective_white) && $effective_white > 0);
	  return $effective_white;
	 }
	 return $$white_y_ref if(!defined($derived) || $derived <= 0);
	 if(ref($state) eq "HASH") {
	  $state->{"peak_headroom_reference"}=$derived;
	  set_state_white_reference($state,$derived);
	 }
	 annotate_reading_target($reading,$derived,$reading_y,$target_x,$target_y) if(ref($reading) eq "HASH" && defined($reading_y) && $reading_y > 0);
	 return $derived;
	}

sub refresh_headroom_targets_from_white_reference {
 my ($state,$white_y,$target_x,$target_y,$target_gamma,$signal_mode)=@_;
 return 0 if(ref($state) ne "HASH" || ref($state->{"readings"}) ne "ARRAY");
 return 0 if(!defined($white_y) || $white_y <= 0);
 my $updated=0;
 my $peak_target_luminance=undef;
 foreach my $reading (@{$state->{"readings"}}) {
  next if(ref($reading) ne "HASH" || !defined($reading->{"ire"}));
  my $ire=$reading->{"ire"}+0;
  next if($ire < 105);
  my $step=clone_picture($reading);
	  if(!defined($step->{"stimulus"})) {
	   my $fixed=fixed_lg_autocal_stimulus($step);
	   $step->{"stimulus"}=defined($fixed) ? $fixed : $ire;
	  }
	  delete $step->{"target_luminance"};
	  delete $step->{"target_Yn"};
	  my $target_lum_y=target_luminance_for_step($white_y,$step,$target_gamma,$signal_mode);
	  next if(!defined($target_lum_y));
	  annotate_reading_target($reading,$white_y,$target_lum_y,$target_x,$target_y);
  $updated++;
  $peak_target_luminance=$target_lum_y if(autocal_step_is_peak_headroom($step));
	 }
	 if(!defined($peak_target_luminance) && ref($state->{"steps"}) eq "ARRAY") {
	  foreach my $candidate (@{$state->{"steps"}}) {
	   next if(ref($candidate) ne "HASH" || !autocal_step_is_peak_headroom($candidate));
	   my $step=clone_picture($candidate);
	   my $ire=$step->{"ire"}+0;
	   if(!defined($step->{"stimulus"})) {
	    my $fixed=fixed_lg_autocal_stimulus($step);
	    $step->{"stimulus"}=defined($fixed) ? $fixed : $ire;
	   }
	   delete $step->{"target_luminance"};
	   delete $step->{"target_Yn"};
	   my $target_lum_y=target_luminance_for_step($white_y,$step,$target_gamma,$signal_mode);
	   next if(!defined($target_lum_y));
	   $peak_target_luminance=$target_lum_y;
	   last;
	  }
	 }
	 if(defined($peak_target_luminance) && $peak_target_luminance > 0) {
	  $state->{"headroom_target_luminance"}=$peak_target_luminance;
	  $LG_AUTOCAL_HEADROOM_TARGET_LUMINANCE=$peak_target_luminance;
 }
 return $updated;
}

sub lg_extended_sdr_16_255_enabled {
 my ($config)=@_;
 return 0 if(ref($config) ne "HASH");
 return 1 if($config->{"lg_extended_sdr_16_255"});
 return 1 if($config->{"lg_greyscale_21"} && ($config->{"signal_mode"}||"sdr") eq "sdr");
 return 0;
}

sub patch_code_for_stimulus {
	 my ($config,$stimulus)=@_;
	 $stimulus=0 if(!defined($stimulus));
	 $stimulus=0 if($stimulus < 0);
	 my $headroom=(ref($config) eq "HASH" && $config->{"lg_autocal_26"}) ? 109.5 : 100;
	 $stimulus=$headroom if($stimulus > $headroom);
	 my $pattern_range=$config->{"pattern_signal_range"}||$config->{"signal_range"}||$config->{"transport_signal_range"}||"";
	 my $limited=($pattern_range ne "" && int($pattern_range)==1) ? 1 : 0;
	 my $code;
	 if($limited && ref($config) eq "HASH" && $config->{"lg_autocal_26"}) {
	  $code=int(64 + ($stimulus/100)*876 + .5);
	 } elsif($limited && lg_extended_sdr_16_255_enabled($config)) {
	  $code=($stimulus <= 0) ? 0 : int(16 + ($stimulus/100)*239 + .5);
	 } else {
	  $code=$limited ? int(16 + ($stimulus/100)*219 + .5) : int(($stimulus/100)*255 + .5);
	 }
	 $code=($limited && ref($config) eq "HASH" && $config->{"lg_autocal_26"}) ? 64 : 0 if($code < 0);
	 $code=(ref($config) eq "HASH" && $config->{"lg_autocal_26"}) ? 1023 : 255 if($code > ((ref($config) eq "HASH" && $config->{"lg_autocal_26"}) ? 1023 : 255));
	 return $code;
}

sub shifted_stimulus_step {
	 my ($config,$step,$stimulus)=@_;
	 return undef if(ref($step) ne "HASH" || !defined($stimulus));
	 $stimulus=0 if($stimulus < 0);
	 my $headroom=(ref($config) eq "HASH" && $config->{"lg_autocal_26"}) ? 109.5 : 100;
	 $stimulus=$headroom if($stimulus > $headroom);
	 my $clone=clone_picture($step);
	 my $code=patch_code_for_stimulus($config,$stimulus);
	 my $expected=defined($step->{"expected_stimulus"}) ? ($step->{"expected_stimulus"}+0) : (defined($step->{"stimulus"}) ? ($step->{"stimulus"}+0) : ($stimulus+0));
	 $clone->{"stimulus"}=$stimulus+0;
	 $clone->{"expected_stimulus"}=$expected;
	 $clone->{"signal_r_pct"}=$stimulus+0;
	 $clone->{"signal_g_pct"}=$stimulus+0;
	 $clone->{"signal_b_pct"}=$stimulus+0;
	 $clone->{"r"}=$code;
	 $clone->{"g"}=$code;
	 $clone->{"b"}=$code;
	 $clone->{"input_max"}=1023 if(ref($config) eq "HASH" && $config->{"lg_autocal_26"});
	 $clone->{"autocal_probe_stimulus"}=JSON::PP::true if(abs(($stimulus+0)-(($step->{"ire"}||0)+0))>0.001);
		 return $clone;
}

sub fixed_lg_autocal_stimulus {
	 my ($step)=@_;
	 return undef if(ref($step) ne "HASH" || !defined($step->{"ire"}));
		 my %map=(
		  "2.3" => 2.28310502283105,
		  "3" => 3.19634703196347,
		  "4" => 4.10958904109589,
		  "5" => 5.02283105022831,
		  "7" => 6.84931506849315,
		  "10" => 10.0456621004566,
		  "15" => 15.0684931506849,
		  "20" => 20.0913242009132,
		  "25" => 25.1141552511416,
		  "30" => 30.1369863013699,
		  "35" => 35.1598173515982,
		  "40" => 40.1826484018265,
		  "45" => 45.2054794520548,
		  "50" => 50.2283105022831,
		  "55" => 54.7945205479452,
		  "60" => 59.8173515981735,
		  "65" => 64.8401826484018,
		  "70" => 69.8630136986301,
		  "75" => 74.8858447488585,
		  "80" => 79.9086757990868,
		  "85" => 84.9315068493151,
		  "90" => 89.9543378995434,
		  "95" => 94.9771689497717,
		  "99" => 99.0867579908676,
		  "105" => 105.022831050228,
		  "109" => 109.474885844749,
		 );
	 my $key=format_percent($step->{"ire"});
	 return $map{$key} if(exists($map{$key}));
	 return undef;
}

sub target_ire_value {
 my ($target)=@_;
 return undef if(ref($target) ne "HASH" || !defined($target->{"ire"}));
 return $target->{"ire"}+0;
}

sub target_is_low_shadow_slot {
 my ($target)=@_;
 my $ire=target_ire_value($target);
 return 0 if(!defined($ire));
 return ($ire > 0 && $ire <= 5.0001) ? 1 : 0;
}

sub fixed_lg_autocal_step {
	 my ($config,$step)=@_;
	 return $step if(ref($step) ne "HASH");
	 return $step if(!$config->{"use_shifted_lg_autocal_stimulus"});
	 return $step if(!ddc_target_for_step($step));
	 my $stimulus=fixed_lg_autocal_stimulus($step);
	 return $step if(!defined($stimulus));
	 my $current=defined($step->{"stimulus"}) ? ($step->{"stimulus"}+0) : ($step->{"ire"}+0);
	 return $step if(abs($current-$stimulus) < 0.001);
	 my $mapped=shifted_stimulus_step($config,$step,$stimulus);
	 return $step if(!$mapped);
	 $mapped->{"autocal_fixed_stimulus"}=JSON::PP::true;
	 $mapped->{"expected_stimulus"}=$stimulus+0;
	 return $mapped;
}

sub stimulus_probe_key {
	 my ($step)=@_;
	 return "" if(ref($step) ne "HASH");
	 my $stimulus=defined($step->{"stimulus"}) ? ($step->{"stimulus"}+0) : (defined($step->{"ire"}) ? ($step->{"ire"}+0) : undef);
	 return "" if(!defined($stimulus));
	 return format_percent($stimulus);
}

sub stimulus_probe_enabled {
	 my ($config)=@_;
	 return 0 if(ref($config) eq "HASH" && $config->{"lg_autocal_26"});
	 return (ref($config) eq "HASH" && $config->{"stimulus_probe_enabled"}) ? 1 : 0;
}

sub mark_stimulus_probe_tried {
	 my ($tried,$step)=@_;
	 return if(ref($tried) ne "HASH");
	 my $key=stimulus_probe_key($step);
	 $tried->{$key}=1 if($key ne "");
}

sub stimulus_probe_steps {
		 my ($config,$step,$tried)=@_;
		 return () if(ref($step) ne "HASH" || !defined($step->{"ire"}));
		 return () if(autocal_step_is_white($step));
		 my $base=defined($step->{"stimulus"}) ? ($step->{"stimulus"}+0) : ($step->{"ire"}+0);
		 my $anchor=defined($step->{"expected_stimulus"}) ? ($step->{"expected_stimulus"}+0) : $base;
		 my $headroom=(ref($config) eq "HASH" && $config->{"lg_autocal_26"}) ? 109.5 : 100;
		 my @offsets=($base >= 100) ? (-2,-4,-6,-8) : (($base <= 20) ? (-2,-4,-6,-8,2,4,6,8) : (2,-2,4,-4,6,-6,8,-8));
		 my @out;
		 my %seen;
		 foreach my $offset (@offsets) {
		  my $stimulus=$base+$offset;
		  next if($stimulus < 0 || $stimulus > $headroom);
		  next if(abs($stimulus-$base) > 8.0001);
		  next if(abs($stimulus-$anchor) > 8.0001);
		  my $key=format_percent($stimulus);
		  next if($seen{$key});
		  next if(ref($tried) eq "HASH" && $tried->{$key});
		  $seen{$key}=1;
		  my $probe=shifted_stimulus_step($config,$step,$stimulus);
		  push @out,$probe if($probe);
	 }
	 return @out;
}

sub stimulus_scan_steps {
		 my ($config,$step,$tried)=@_;
		 return () if(ref($step) ne "HASH" || !defined($step->{"ire"}));
		 return () if(autocal_step_is_white($step));
		 my $base=defined($step->{"stimulus"}) ? ($step->{"stimulus"}+0) : ($step->{"ire"}+0);
		 my $anchor=defined($step->{"expected_stimulus"}) ? ($step->{"expected_stimulus"}+0) : $base;
		 my $headroom=(ref($config) eq "HASH" && $config->{"lg_autocal_26"}) ? 109.5 : 100;
		 my @offsets=($base >= 100) ? (0,-2,-4,-6,-8) : (($base <= 20) ? (0,-2,-4,-6,-8,2,4,6,8) : (0,2,-2,4,-4,6,-6,8,-8));
		 my @out;
	 my %seen;
	 foreach my $offset (@offsets) {
	  my $stimulus=$base+$offset;
	  next if($stimulus < 0 || $stimulus > $headroom);
	  next if(abs($stimulus-$base) > 8.0001);
	  next if(abs($stimulus-$anchor) > 8.0001);
	  my $key=format_percent($stimulus);
	  next if($seen{$key});
	  next if(ref($tried) eq "HASH" && $tried->{$key});
	  $seen{$key}=1;
	  my $probe=shifted_stimulus_step($config,$step,$stimulus);
	  push @out,$probe if($probe);
	 }
	 return @out;
}

sub delta_e_itp {
 my ($reading,$target_x,$target_y,$target_luminance,$chroma_only)=@_;
 my $actual=reading_xyz($reading);
 return undef if(ref($actual) ne "ARRAY");
 my $Y=$chroma_only ? luminance($reading) : $target_luminance;
 return undef if(!defined($Y));
 my $target=xyz_from_xyy($target_x,$target_y,$Y);
 return undef if(ref($target) ne "ARRAY");
 return delta_e_itp_xyz($actual,$target);
}

sub autocal_delta_e_for_step {
 my ($reading,$white_y,$target_x,$target_y,$target_luminance,$step)=@_;
 return delta_e_itp($reading,$target_x,$target_y,$target_luminance,autocal_step_ignores_luminance_error($step));
}

sub luminance_error_ratio {
 my ($reading,$target_luminance)=@_;
 return 0 if(ref($reading) ne "HASH" || !defined($target_luminance) || $target_luminance <= 0);
 my $Y=luminance($reading);
 return 0 if(!defined($Y));
 my $err=($Y-$target_luminance)/$target_luminance;
 return 0 if(abs($err) < 0.003);
 $err=0.60 if($err > 0.60);
 $err=-0.60 if($err < -0.60);
 return $err;
}

sub luminance_adjustment_drive {
	 my ($luminance_err)=@_;
	 $luminance_err=0 if(!defined($luminance_err));
	 return 0 if(abs($luminance_err) < 0.005);
	 my $drive=$luminance_err*0.8;
	 $drive=0.20 if($drive > 0.20);
	 $drive=-0.20 if($drive < -0.20);
	 return $drive;
}

sub luminance_error_percent {
	 my ($reading,$target_luminance)=@_;
	 return undef if(ref($reading) ne "HASH" || !defined($target_luminance) || $target_luminance <= 0);
 my $Y=luminance($reading);
 return undef if(!defined($Y));
	 return (($Y-$target_luminance)/$target_luminance)*100;
}

sub reading_change_score {
	 my ($before,$after)=@_;
	 return 0 if(ref($before) ne "HASH" || ref($after) ne "HASH");
	 my $score=0;
	 my $y1=luminance($before);
	 my $y2=luminance($after);
	 if(defined($y1) && defined($y2)) {
	  my $max_y=abs($y1) > abs($y2) ? abs($y1) : abs($y2);
	  $max_y=0.05 if($max_y < 0.05);
	  my $dy=abs($y2-$y1)/$max_y;
	  $score=$dy if($dy > $score);
	 }
	 if(defined($before->{"x"}) && defined($before->{"y"}) && defined($after->{"x"}) && defined($after->{"y"})) {
	  my $dx=($after->{"x"}+0)-($before->{"x"}+0);
	  my $dy=($after->{"y"}+0)-($before->{"y"}+0);
	  my $dxy=sqrt($dx*$dx+$dy*$dy)*80;
	  $score=$dxy if($dxy > $score);
	 }
	 my $e1=rgb_error($before);
	 my $e2=rgb_error($after);
	 if(ref($e1) eq "HASH" && ref($e2) eq "HASH") {
	  my $rgb_delta=0;
	  foreach my $ch (qw(r g b)) {
	   $rgb_delta+=abs(($e2->{$ch}||0)-($e1->{$ch}||0));
	  }
	  $rgb_delta/=3;
	  $score=$rgb_delta if($rgb_delta > $score);
	 }
	 return $score;
}

sub luminance_tolerance_percent {
			 my ($step)=@_;
			 my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : 100;
			 return 3 if($ire >= 108.5);
			 return 4 if($ire <= 3.1);
			 return 3.5 if($ire <= 5);
			 return 3 if($ire <= 7.5);
			 return 2.5 if($ire <= 10);
			 return 3 if($ire <= 25);
		 return 2 if($ire <= 50);
		 return 1.25 if($ire < 75);
	 return 0.9 if($ire < 85);
	 return 0.65 if($ire < 90);
	 return 0.45;
}

sub low_shadow_delta_acceptance {
 my ($step,$target_delta)=@_;
 $target_delta=0.5 if(!defined($target_delta) || $target_delta <= 0);
 my $accept=autocal_step_is_low_shadow($step) ? ($target_delta+0.75) : $target_delta;
 my $limit=itp_luminance_included_acceptance_limit($step);
 $accept=$limit if(defined($limit) && $accept > $limit);
 return $accept;
}

sub itp_luminance_included_acceptance_limit {
 my ($step)=@_;
 return undef if(autocal_step_ignores_luminance_error($step));
 return 1.0;
}

sub within_itp_luminance_included_acceptance {
 my ($de,$step)=@_;
 my $limit=itp_luminance_included_acceptance_limit($step);
 return 1 if(!defined($limit));
 return (defined($de) && $de <= $limit) ? 1 : 0;
}

sub target_reached {
			 my ($de,$lum_pct,$target_delta,$step)=@_;
				 return 0 if(!defined($de));
				 my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : 100;
				 return 0 if(low_ire_luminance_needs_lift($step,$lum_pct));
				 return 0 if(low_ire_luminance_needs_tuning($step,$lum_pct));
				 return 1 if(autocal_step_is_low_shadow($step) && $de <= low_shadow_delta_acceptance($step,$target_delta));
			 return 0 if(!within_itp_luminance_included_acceptance($de,$step));
			 my $low_delta_allow=($ire <= 10) ? 0.75 : 0.30;
			 return 0 if($de > $target_delta && !($ire <= 10 && $de <= $target_delta+$low_delta_allow));
			 return 1 if($ire >= 99.9 && !defined($lum_pct));
			 return 1 if(!defined($lum_pct));
			 return 1 if(autocal_result_score($de,$lum_pct,$step) <= $target_delta+0.08);
		 return abs($lum_pct) <= luminance_tolerance_percent($step);
}

sub low_ire_luminance_needs_lift {
 my ($step,$lum_pct)=@_;
 return 0 if(!defined($lum_pct));
 my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : 100;
 return 0 if($ire <= 0 || $ire > 5.0001);
 my $floor=($ire <= 3.1) ? -30 : -22;
 return ($lum_pct < $floor) ? 1 : 0;
}

sub low_ire_luminance_needs_tuning {
 my ($step,$lum_pct)=@_;
 return 0 if(!defined($lum_pct));
 my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : 100;
 return 0 if($ire <= 0 || $ire > 10.0001);
 return abs($lum_pct) > luminance_tolerance_percent($step) ? 1 : 0;
}

sub close_enough_stalled {
		 my ($best_de,$best_lum_pct,$target_delta,$step,$stalls,$iter)=@_;
		 return 0 if(!defined($best_de));
	 my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : 100;
	 return 0 if($ire < 90);
	 return 0 if(($iter||0) < 40 || ($stalls||0) < 16);
	 return 0 if($best_de > ($target_delta+0.10));
	 return 0 if(!within_itp_luminance_included_acceptance($best_de,$step));
	 return 1 if($ire >= 99.9 && !defined($best_lum_pct));
	 return 1 if(!defined($best_lum_pct));
		 return abs($best_lum_pct) <= luminance_tolerance_percent($step);
}

sub autocal_result_score {
		 my ($de,$lum_pct,$step)=@_;
			 my $score=defined($de) ? ($de+0) : 9999;
			 my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : 100;
			 return $score if(autocal_step_ignores_luminance_error($step));
			 return $score if($ire <= 5 && $score <= 4.0 && !low_ire_luminance_needs_tuning($step,$lum_pct));
			 return $score if(!defined($lum_pct));
		 my $tol=luminance_tolerance_percent($step);
		 my $excess=abs($lum_pct)-$tol;
		 return $score if($excess <= 0);
		 # ΔE ITP already contains a perceptual luminance term. Keep
		 # Y/gamma as a tie-breaker, but do not let it preserve a visibly worse
		 # RGB balance just because the luminance was slightly closer.
		 my $penalty=$excess*0.35;
		 $penalty=4 if($penalty > 4);
		 return $score+$penalty;
}

sub headroom_autocal_result_score {
 my ($de,$reading,$step)=@_;
 if(autocal_step_is_peak_headroom($step)) {
  my $floor=headroom_floor_balance($reading);
  return $floor->{"score"} if(ref($floor) eq "HASH");
 }
 my $err=rgb_error($reading);
 return defined($de) ? ($de+0) : 9999 if(ref($err) ne "HASH");
 my $max=0;
 my $sum=0;
 foreach my $ch (qw(r g b)) {
  my $v=abs($err->{$ch}||0);
  $max=$v if($v > $max);
  $sum+=$v;
 }
 my $de_tiebreak=defined($de) ? (($de+0)*0.05) : 9999;
 return ($max*100)+($sum*10)+$de_tiebreak;
}

sub headroom_floor_balance {
 my ($reading)=@_;
 my $err=rgb_balance_error($reading);
 return undef if(ref($err) ne "HASH");
 my @channels=qw(r g b);
 my @ordered=sort { ($err->{$a}||0) <=> ($err->{$b}||0) } @channels;
 my $floor_ch=$ordered[0];
 my $floor=$err->{$floor_ch}||0;
 my $max_gap=0;
 my $sum_gap=0;
 my %gaps;
 foreach my $ch (@channels) {
  my $gap=($err->{$ch}||0)-$floor;
  $gap=0 if($gap < 0);
  $gaps{$ch}=$gap;
  $max_gap=$gap if($gap > $max_gap);
  $sum_gap+=$gap;
 }
 return {
  floor_channel=>$floor_ch,
  floor=>$floor,
  max_gap=>$max_gap,
  sum_gap=>$sum_gap,
  gaps=>\%gaps,
  errors=>$err,
  score=>($max_gap*100)+($sum_gap*5),
 };
}

sub headroom_rgb_balance_error {
 my ($reading,$step)=@_;
 if(autocal_step_is_peak_headroom($step)) {
  my $floor=headroom_floor_balance($reading);
  return $floor->{"max_gap"} if(ref($floor) eq "HASH");
 }
 my $err=rgb_error($reading);
 return undef if(ref($err) ne "HASH");
 my $max=0;
 foreach my $ch (qw(r g b)) {
  my $v=abs($err->{$ch}||0);
  $max=$v if($v > $max);
 }
 return $max;
}

sub headroom_rgb_balance_limit {
 my ($target_delta)=@_;
 $target_delta=0.5 if(!defined($target_delta) || $target_delta <= 0);
 my $limit=$target_delta/100;
 $limit=0.003 if($limit < 0.003);
 $limit=0.010 if($limit > 0.010);
 return $limit;
}

sub headroom_rgb_balanced {
 my ($reading,$target_delta,$step)=@_;
 my $max=headroom_rgb_balance_error($reading,$step);
 return 0 if(!defined($max));
 return $max <= headroom_rgb_balance_limit($target_delta) ? 1 : 0;
}

sub headroom_fine_target_delta {
 my ($step,$target_delta)=@_;
 $target_delta=0.5 if(!defined($target_delta) || $target_delta <= 0);
 return $target_delta if(!autocal_step_is_fast_headroom($step));
 my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : 100;
 my $fine=($ire >= 108.5) ? 0.18 : 0.28;
 $fine=$target_delta if($fine > $target_delta);
 return $fine;
}

sub headroom_needs_fine_tune {
 my ($de,$target_delta,$reading,$step)=@_;
 return 0 if(!autocal_step_is_fast_headroom($step));
 return 1 if(!defined($de));
 if(!autocal_step_ignores_luminance_error($step) && ref($reading) eq "HASH" && defined($reading->{"target_luminance"})) {
  my $lum_pct=luminance_error_percent($reading,$reading->{"target_luminance"});
  return 1 if(defined($lum_pct) && abs($lum_pct) > luminance_tolerance_percent($step));
 }
 return 1 if($de > headroom_fine_target_delta($step,$target_delta));
 return 1 if(!headroom_rgb_balanced($reading,$target_delta,$step));
 return 0;
}

sub white_luminance_floor_ratio {
 return 0.78;
}

sub white_luminance_guard_failed {
 my ($step,$reading,$reference_y)=@_;
 return 0 if(!autocal_step_is_white($step));
 return 0 if(ref($reading) ne "HASH" || !defined($reference_y) || $reference_y <= 1);
 my $Y=luminance($reading);
 return 0 if(!defined($Y));
 return $Y < ($reference_y * white_luminance_floor_ratio()) ? 1 : 0;
}

sub guarded_autocal_result_score {
 my ($de,$lum_pct,$step,$reading,$white_guard_y)=@_;
 my $score=autocal_result_score($de,$lum_pct,$step);
 if(white_luminance_guard_failed($step,$reading,$white_guard_y)) {
  my $Y=luminance($reading);
  my $ratio=(defined($Y) && defined($white_guard_y) && $white_guard_y > 0) ? ($Y/$white_guard_y) : 0;
  my $penalty=(1-$ratio)*100;
  $penalty=0 if($penalty < 0);
  return 9999+$penalty;
 }
	 if(autocal_step_is_fast_headroom($step)) {
	  my $headroom_score=headroom_autocal_result_score($de,$reading,$step);
	  if(defined($lum_pct) && !autocal_step_ignores_luminance_error($step)) {
	   my $excess=abs($lum_pct)-luminance_tolerance_percent($step);
	   if($excess > 0) {
	    my $penalty=$excess*1.60;
	    $penalty=35 if($penalty > 35);
	    $headroom_score+=$penalty;
	   }
	  }
	  return $headroom_score;
 }
 return $score;
}

sub autocal_de_epsilon_for_best_update {
 my ($step)=@_;
 my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : 100;
 return 0.08 if(autocal_step_is_fast_headroom($step));
 return 0.02 if($ire <= 10);
 return 0.04;
}

sub autocal_step_uses_raw_itp_best_update {
 my ($step)=@_;
 return 0 if(ref($step) ne "HASH" || !defined($step->{"ire"}));
 my $ire=$step->{"ire"}+0;
 return ($ire > 0 && $ire <= 7.5001) ? 1 : 0;
}

sub autocal_luminance_regresses_too_far_for_best_update {
 my ($candidate_lum_pct,$best_lum_pct,$step)=@_;
 return 0 if(!defined($candidate_lum_pct) || !defined($best_lum_pct));
 my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : 100;
 if(autocal_step_is_fast_headroom($step)) {
  my $limit=luminance_tolerance_percent($step)*6;
  $limit=10 if($limit < 10);
  return abs($candidate_lum_pct) > $limit ? 1 : 0;
 }
 my $tol=luminance_tolerance_percent($step);
 my $candidate_excess=abs($candidate_lum_pct)-$tol;
 my $best_excess=abs($best_lum_pct)-$tol;
 $candidate_excess=0 if($candidate_excess < 0);
 $best_excess=0 if($best_excess < 0);
 my $allow=($ire <= 10) ? $tol : (($ire <= 25) ? ($tol*0.5) : 0.25);
 return $candidate_excess > ($best_excess+$allow) ? 1 : 0;
}

sub autocal_best_update_reason {
 my ($candidate_de,$candidate_score,$best_de,$best_score,$candidate_lum_pct,$best_lum_pct,$step,$reading,$white_guard_y)=@_;
 return undef if(!defined($candidate_de));
 return undef if(white_luminance_guard_failed($step,$reading,$white_guard_y));
 if(autocal_step_ignores_luminance_error($step)) {
  return undef if(!defined($candidate_score) || !defined($best_score));
  return ($candidate_score + 0.0001 < $best_score) ? "headroom_balance" : undef;
 }
 if(autocal_step_uses_raw_itp_best_update($step)) {
  return "raw_itp_delta_e" if(!defined($best_de) || ($candidate_de+0) < ($best_de+0));
  return undef;
 }
 return "delta_e_fallback" if(
  defined($best_de) &&
  ($candidate_de+autocal_de_epsilon_for_best_update($step)) < ($best_de+0) &&
  !autocal_luminance_regresses_too_far_for_best_update($candidate_lum_pct,$best_lum_pct,$step)
 );
 return undef if(!defined($candidate_score) || !defined($best_score));
 return undef if($candidate_score + 0.0001 >= $best_score);
 return "score" if(!defined($best_de));
 return "score" if($candidate_de <= ($best_de+autocal_de_epsilon_for_best_update($step)));
 return undef;
}

sub guarded_target_reached {
 my ($de,$lum_pct,$target_delta,$step,$reading,$white_guard_y)=@_;
 return 0 if(white_luminance_guard_failed($step,$reading,$white_guard_y));
 return 0 if(headroom_needs_fine_tune($de,$target_delta,$reading,$step));
 return target_reached($de,$lum_pct,$target_delta,$step);
}

sub paired_white_primary_regression_reason {
 my ($de,$lum_pct,$best_de,$best_lum_pct,$target_delta,$step,$reading,$best_reading,$white_guard_y,$cap_only)=@_;
 return undef if(!defined($de));
 $target_delta=0.5 if(!defined($target_delta) || $target_delta <= 0);
 my $limit=$target_delta+0.25;
 $limit=1.0 if($limit > 1.0);
 return "primary exceeds luminance-included ITP cap" if(!within_itp_luminance_included_acceptance($de,$step));
 return undef if($cap_only);
 return "primary exceeds paired white limit" if($de > $limit);
 if(
  guarded_target_reached($best_de,$best_lum_pct,$target_delta,$step,$best_reading,$white_guard_y) &&
  !guarded_target_reached($de,$lum_pct,$target_delta,$step,$reading,$white_guard_y)
 ) {
  return "primary lost target after paired white adjustment";
 }
 return "primary materially worse than best" if(defined($best_de) && $de > ($best_de+0.35) && $de > ($target_delta+0.10));
 return undef;
}

sub near_target_for_probe_skip {
		 my ($de,$lum_pct,$target_delta,$step)=@_;
		 return 0 if(!defined($de));
			 $target_delta=0.5 if(!defined($target_delta));
			 my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : 100;
			 return 1 if($ire <= 5 && $de <= 4.0 && !low_ire_luminance_needs_tuning($step,$lum_pct));
			 return 0 if($de > ($target_delta+0.35));
			 return 1 if(!defined($lum_pct));
			 return abs($lum_pct) <= luminance_tolerance_percent($step)*1.25;
}

sub iteration_limit_for_step {
				 my ($step,$default,$config)=@_;
				 $default=50 if(!defined($default) || $default < 1);
				 my $headroom_limit=headroom_iteration_limit_for_step($step);
				 return $headroom_limit if(defined($headroom_limit));
				 my $shadow_limit=low_shadow_iteration_limit_for_step($step,$config);
				 return $shadow_limit if(defined($shadow_limit));
			 return $default;
}

sub annotate_reading_target {
 my ($reading,$white_y,$target_luminance,$target_x,$target_y)=@_;
 return $reading if(ref($reading) ne "HASH");
 $reading->{"target_x"}=$target_x if(defined($target_x));
 $reading->{"target_y"}=$target_y if(defined($target_y));
 $reading->{"autocal_white_y"}=$white_y if(defined($white_y) && $white_y > 0);
 if(defined($white_y) && $white_y > 0 && defined($target_luminance)) {
  $reading->{"target_Yn"}=$target_luminance/$white_y;
  $reading->{"target_luminance"}=$target_luminance;
 }
 return $reading;
}

sub set_state_target_step_luminance {
	 my ($state,$target_luminance)=@_;
	 return if(ref($state) ne "HASH");
	 if(defined($target_luminance)) {
	  $state->{"target_step_luminance"}=$target_luminance;
	 } else {
	  delete $state->{"target_step_luminance"};
	 }
}

sub set_state_white_reference {
	 my ($state,$white_y)=@_;
	 return if(ref($state) ne "HASH" || !defined($white_y) || $white_y <= 0);
	 $state->{"target_luminance"}=$white_y;
	 $state->{"calibrated_white_luminance"}=$white_y;
}

sub read_request_id {
	 my ($step)=@_;
	 my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? format_percent($step->{"ire"}) : "step";
	 $ire=~s/[^A-Za-z0-9.:-]+/_/g;
	 return "autocal_".$$."_".int(time()*1000)."_".$ire."_".int(rand(1000000));
}

sub read_timeout_for_step {
	 my ($step)=@_;
	 my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : 100;
	 return 60 if(ref($step) eq "HASH" && $step->{"autocal_probe_stimulus"});
	 return 210 if($ire <= 5);
	 return 180 if($ire <= 10);
	 return 150 if($ire <= 25);
	 return 120 if($ire <= 50);
	 return 110;
}

sub transient_read_error {
 my ($error)=@_;
 return 0 if(!defined($error) || $error eq "");
 return ($error =~ /tim(?:e|ed)\s*out|timeout|communication|fifo|session|spotread|unavailable|invalid web ui api|unable to start meter read/i) ? 1 : 0;
}

sub reset_meter_session_after_read_error {
 my ($error)=@_;
 $error="" if(!defined($error));
 $error=~s/[\r\n]+/ /g;
 log_line("Resetting meter session after transient read error: $error");
 api_json("POST","/api/meter/session/stop",undef,25);
}

my $read_sequence=0;

sub patch_payload_for_step {
	 my ($config,$step)=@_;
	 my $pattern_range=$config->{"pattern_signal_range"}||$config->{"signal_range"}||"";
	 my $transport_range=$config->{"transport_signal_range"}||$config->{"signal_range"}||"";
	 my $input_max=(ref($step) eq "HASH" && defined($step->{"input_max"})) ? int($step->{"input_max"}) : 255;
	 $input_max=255 if($input_max <= 0);
	 my $payload={
	  name => "patch",
	  r => int($step->{"r"}||0),
	  g => int($step->{"g"}||0),
	  b => int($step->{"b"}||0),
	  size => int($config->{"patch_size"}||10),
	  input_max => $input_max,
	  signal_mode => $config->{"signal_mode"}||"sdr",
	  max_luma => $config->{"max_luma"}||1000,
	 };
 $payload->{"signal_range"}=$pattern_range if($pattern_range ne "");
 $payload->{"transport_signal_range"}=$transport_range if($transport_range ne "");
 return $payload;
}

sub apply_pattern_insert_before_read {
 my ($config,$step)=@_;
 return undef if(ref($config) ne "HASH" || !$config->{"patch_insert"} || $read_sequence <= 0);
 my $pattern_range=$config->{"pattern_signal_range"}||$config->{"signal_range"}||"";
 my $transport_range=$config->{"transport_signal_range"}||$config->{"signal_range"}||"";
 my $payload={
  name => "patch",
  r => 64,
  g => 64,
  b => 64,
  size => 100,
  input_max => 255,
  signal_mode => $config->{"signal_mode"}||"sdr",
  max_luma => $config->{"max_luma"}||1000,
 };
 $payload->{"signal_range"}=$pattern_range if($pattern_range ne "");
 $payload->{"transport_signal_range"}=$transport_range if($transport_range ne "");
 my $insert_result=api_json("POST","/api/pattern",$payload,10);
 return $insert_result->{"message"}||"Unable to display pattern insertion patch" if(($insert_result->{"status"}||"") eq "error");
 select(undef,undef,undef,1.5);
 my $restore_result=api_json("POST","/api/pattern",patch_payload_for_step($config,$step),10);
 return $restore_result->{"message"}||"Unable to restore greyscale patch after pattern insertion" if(($restore_result->{"status"}||"") eq "error");
 return undef;
}

sub rgb_error {
	 my ($reading)=@_;
	 return undef if(ref($reading) ne "HASH");
 my ($X,$Y,$Z)=($reading->{"X"},$reading->{"Y"},$reading->{"Z"});
 if((!defined($X) || !defined($Y) || !defined($Z)) && defined($reading->{"x"}) && defined($reading->{"y"}) && defined(luminance($reading)) && $reading->{"y"} > 0) {
  $Y=luminance($reading);
  $X=($reading->{"x"}/$reading->{"y"})*$Y;
  $Z=((1-$reading->{"x"}-$reading->{"y"})/$reading->{"y"})*$Y;
 }
 return undef if(!defined($X) || !defined($Y) || !defined($Z));
 my $r= 3.2406*$X - 1.5372*$Y - 0.4986*$Z;
 my $g=-0.9689*$X + 1.8758*$Y + 0.0415*$Z;
 my $b= 0.0557*$X - 0.2040*$Y + 1.0570*$Z;
 $r=0 if($r < 0); $g=0 if($g < 0); $b=0 if($b < 0);
 my $avg=($r+$g+$b)/3;
 return undef if($avg <= 0);
 return { r=>($r/$avg)-1, g=>($g/$avg)-1, b=>($b/$avg)-1 };
}

sub signed_lstar {
 my ($ratio)=@_;
 $ratio=0 if(!defined($ratio));
 my $sign=($ratio < 0) ? -1 : 1;
 my $abs=abs($ratio);
 my $L=($abs <= 0.008856451679) ? (903.2963*$abs) : (116*($abs ** (1/3))-16);
 return $sign*$L;
}

sub xyz_to_linear_rgb {
 my ($X,$Y,$Z)=@_;
 return undef if(!defined($X) || !defined($Y) || !defined($Z));
 return [
   3.2406*$X - 1.5372*$Y - 0.4986*$Z,
  -0.9689*$X + 1.8758*$Y + 0.0415*$Z,
   0.0557*$X - 0.2040*$Y + 1.0570*$Z
 ];
}

sub rgb_balance_error {
 my ($reading)=@_;
 return undef if(ref($reading) ne "HASH");
 my ($X,$Y,$Z)=($reading->{"X"},$reading->{"Y"},$reading->{"Z"});
 if((!defined($X) || !defined($Y) || !defined($Z)) && defined($reading->{"x"}) && defined($reading->{"y"}) && defined(luminance($reading)) && $reading->{"y"} > 0) {
  $Y=luminance($reading);
  $X=($reading->{"x"}/$reading->{"y"})*$Y;
  $Z=((1-$reading->{"x"}-$reading->{"y"})/$reading->{"y"})*$Y;
 }
 return undef if(!defined($X) || !defined($Y) || !defined($Z) || !defined($Y) || $Y <= 0);
 my $tx=defined($reading->{"target_x"}) ? ($reading->{"target_x"}+0) : 0.3127;
 my $ty=defined($reading->{"target_y"}) ? ($reading->{"target_y"}+0) : 0.3290;
 return undef if($ty <= 0);
 my $white_y=defined($reading->{"autocal_white_y"}) ? ($reading->{"autocal_white_y"}+0) : $Y;
 $white_y=$Y if($white_y <= 0);
 my $m_rgb=xyz_to_linear_rgb($X/$white_y,$Y/$white_y,$Z/$white_y);
 my $tY=$Y/$white_y;
 my $tX=($tx/$ty)*$tY;
 my $tZ=((1-$tx-$ty)/$ty)*$tY;
 my $t_rgb=xyz_to_linear_rgb($tX,$tY,$tZ);
 return undef if(ref($m_rgb) ne "ARRAY" || ref($t_rgb) ne "ARRAY");
 return {
  r=>(signed_lstar($m_rgb->[0])-signed_lstar($t_rgb->[0]))/100,
  g=>(signed_lstar($m_rgb->[1])-signed_lstar($t_rgb->[1]))/100,
  b=>(signed_lstar($m_rgb->[2])-signed_lstar($t_rgb->[2]))/100
 };
}

sub autocal_adjustment_error {
 my ($reading,$step)=@_;
 return rgb_balance_error($reading) if(autocal_step_uses_direct_headroom_balance($step));
 return rgb_error($reading);
}

sub adjustment_step {
		 my ($abs_err,$de,$stalls,$min_step)=@_;
		 $abs_err=0 if(!defined($abs_err));
		 $de=0 if(!defined($de));
		 $stalls=0 if(!defined($stalls));
		 $min_step ||= 0.25;
		 my $stall_floor=stalled_step_floor($stalls,$de,$abs_err);
		 $min_step=$stall_floor if($min_step < $stall_floor);
		 my $step=0.25;
	 if($abs_err >= 0.30 || $de >= 30) {
	  $step=8;
	 } elsif($abs_err >= 0.20 || $de >= 20) {
	  $step=6;
	 } elsif($abs_err >= 0.12 || $de >= 10) {
	  $step=4;
	 } elsif($abs_err >= 0.06 || $de >= 4) {
	  $step=2;
	 } elsif($abs_err >= 0.025 || $de >= 2) {
	  $step=1;
	 } elsif($abs_err >= 0.012 || $de >= 1) {
	  $step=0.5;
	 }
		 $step=$min_step if($step < $min_step);
		 return $step;
}

sub rgb_error_floor {
	 my ($de,$target_delta,$polish)=@_;
	 $target_delta=0.5 if(!defined($target_delta) || $target_delta <= 0);
	 return 0.00025 if($polish && defined($de) && $de <= $target_delta+0.25);
	 return 0.00055 if(defined($de) && $de <= 1.0);
	 return 0.0012 if(defined($de) && $de <= 2.0);
	 return 0.0020;
}

sub stalled_step_floor {
	 my ($stalls,$de,$abs_err)=@_;
 $stalls=0 if(!defined($stalls));
 $de=0 if(!defined($de));
 $abs_err=0 if(!defined($abs_err));
 my $floor=0.25;
 if($stalls >= 8) {
  $floor=5;
 } elsif($stalls >= 6) {
  $floor=2;
 } elsif($stalls >= 4) {
  $floor=1;
 } elsif($stalls >= 2) {
  $floor=0.5;
 }
 my $cap=5;
 if($de <= 1.0 || $abs_err < 0.01) {
  $cap=0.25;
 } elsif($de <= 2.0 || $abs_err < 0.02) {
  $cap=0.5;
 } elsif($de <= 4.0 || $abs_err < 0.04) {
  $cap=1;
 } elsif($de <= 8.0 || $abs_err < 0.08) {
  $cap=2;
 }
 return $cap if($floor > $cap);
	 return $floor;
}

sub ddc_value_key {
	 my ($value)=@_;
	 $value=0 if(!defined($value));
	 return sprintf("%.2f",$value+0);
}

sub clamp_ddc_value {
	 my ($value)=@_;
	 $value=0 if(!defined($value));
	 $value=50 if($value > 50);
	 $value=-50 if($value < -50);
	 return sprintf("%.2f",$value)+0;
}

sub channel_setting {
		 my ($ch)=@_;
		 return "whiteBalanceRed" if($ch eq "r");
	 return "whiteBalanceGreen" if($ch eq "g");
	 return "adjustingLuminance" if($ch eq "lum" || $ch eq "luma" || $ch eq "y");
		 return "whiteBalanceBlue";
	}

sub ddc_adjustment_settings {
	 my ($arrays)=@_;
	 my @settings=qw(whiteBalanceRed whiteBalanceGreen whiteBalanceBlue);
	 push @settings,"adjustingLuminance" if(ref($arrays) eq "HASH" && ref($arrays->{"adjustingLuminance"}) eq "ARRAY");
	 return @settings;
}

sub has_luminance_channel {
	 my ($arrays,$target)=@_;
	 return 0 if(ref($arrays) ne "HASH" || ref($arrays->{"adjustingLuminance"}) ne "ARRAY");
	 my $idx=(ref($target) eq "HASH") ? $target->{"index"} : undef;
	 return 0 if(!defined($idx) || $idx >= @{$arrays->{"adjustingLuminance"}});
	 return 1;
}

sub mark_tried_values {
	 my ($tried,$arrays,$target,$de)=@_;
	 return if(ref($tried) ne "HASH" || ref($arrays) ne "HASH" || ref($target) ne "HASH");
	 my $idx=$target->{"index"};
	 return if(!defined($idx));
		 foreach my $ch (qw(r g b lum)) {
		  my $setting=channel_setting($ch);
		  my $arr=$arrays->{$setting};
	  next if(ref($arr) ne "ARRAY");
	  my $value=defined($arr->[$idx]) ? ($arr->[$idx]+0) : 0;
	  my $key=ddc_value_key($value);
	  $tried->{$setting}={} if(ref($tried->{$setting}) ne "HASH");
	  $tried->{$setting}{$key}={
	   count => (($tried->{$setting}{$key} && $tried->{$setting}{$key}->{"count"})||0)+1,
	   de => defined($de) ? $de+0 : undef,
	  };
	 }
}

sub clone_arrays {
	 my ($arrays)=@_;
	 return decode_json_safe($json->encode($arrays||{}),{});
}

sub seed_target_from_prior_slot {
		 my ($arrays,$target)=@_;
	 return 0 if(ref($arrays) ne "HASH" || ref($target) ne "HASH");
	 return 0 if(autocal_step_is_fast_headroom($target));
	 my $idx=$target->{"index"};
	 return 0 if(!defined($idx));
	 my @settings=ddc_adjustment_settings($arrays);
	 foreach my $setting (@settings) {
	  my $arr=$arrays->{$setting};
	  next if(ref($arr) ne "ARRAY");
	  return 0 if(abs($arr->[$idx]||0) > 0.0001);
	 }
	 my $source_idx;
	 for(my $probe=$idx+1;$probe<ddc_slot_count();$probe++) {
	  my $has_value=0;
	  foreach my $setting (@settings) {
	   my $arr=$arrays->{$setting};
	   next if(ref($arr) ne "ARRAY");
	   if(abs($arr->[$probe]||0) > 0.0001) {
	    $has_value=1;
	    last;
	   }
	  }
	  if($has_value) {
	   $source_idx=$probe;
	   last;
	  }
	 }
	 return 0 if(!defined($source_idx));
		 my $copied=0;
		 foreach my $setting (@settings) {
		  my $arr=$arrays->{$setting};
		  next if(ref($arr) ne "ARRAY");
		  my $value=$arr->[$source_idx]||0;
		  $value=0 if($setting eq "adjustingLuminance" && target_is_low_shadow_slot($target) && $value < 0);
		  $arr->[$idx]=$value;
		  $copied=1 if(abs($value) > 0.0001);
		 }
		 return $copied;
	}

sub repeated_value {
		 my ($tried,$setting,$value)=@_;
		 return 0 if(ref($tried) ne "HASH" || ref($tried->{$setting}) ne "HASH");
		 my $entry=$tried->{$setting}{ddc_value_key($value)};
		 return 0 if(ref($entry) ne "HASH");
		 return (($entry->{"count"}||0) >= 2) ? 1 : 0;
}

sub next_untried_value {
	 my ($current,$delta,$tried,$setting,$min_step)=@_;
	 $current=0 if(!defined($current));
	 $delta=0 if(!defined($delta));
	 $min_step ||= 0.25;
	 my $direction=($delta < 0) ? -1 : 1;
	 my $magnitude=abs($delta);
	 my @magnitudes;
	 while($magnitude >= $min_step-0.0001) {
	  push @magnitudes,$magnitude;
	  $magnitude/=2;
	 }
	 push @magnitudes,$min_step if(!@magnitudes);
	 foreach my $mag (@magnitudes) {
	  my $next=clamp_ddc_value($current+($direction*$mag));
	  next if(abs($next-$current) < 0.0001);
	  return ($next,($mag != abs($delta))) if(!repeated_value($tried,$setting,$next));
	 }
	 return (undef,0);
}

sub tried_value_exists {
	 my ($tried,$setting,$value)=@_;
	 return 0 if(ref($tried) ne "HASH" || ref($tried->{$setting}) ne "HASH");
	 return exists($tried->{$setting}{ddc_value_key($value)}) ? 1 : 0;
}

sub next_new_headroom_value {
	 my ($current,$delta,$tried,$setting,$min_step)=@_;
	 $current=0 if(!defined($current));
	 $delta=0 if(!defined($delta));
	 $min_step ||= 0.25;
	 my $direction=($delta < 0) ? -1 : 1;
	 my $magnitude=abs($delta);
	 my @magnitudes;
	 while($magnitude >= $min_step-0.0001) {
	  push @magnitudes,$magnitude;
	  $magnitude/=2;
	 }
	 push @magnitudes,$min_step if(!@magnitudes);
	 foreach my $mag (@magnitudes) {
	  my $next=clamp_ddc_value($current+($direction*$mag));
	  next if(abs($next-$current) < 0.0001);
	  return ($next,($mag != abs($delta))) if(!tried_value_exists($tried,$setting,$next));
	 }
	 return (undef,0);
}

sub adjustment_total {
		 my ($adjustments)=@_;
		 return 0 if(ref($adjustments) ne "ARRAY");
	 my $total=0;
	 foreach my $adj (@{$adjustments}) {
	  next if(ref($adj) ne "HASH");
	  $total+=abs($adj->{"delta"}||0);
	 }
		 return $total;
	}

sub chroma_error_magnitude {
	 my ($error)=@_;
	 return 999 if(ref($error) ne "HASH");
	 my $max=0;
	 foreach my $ch (qw(r g b)) {
	  my $value=abs($error->{$ch}||0);
	  $max=$value if($value > $max);
	 }
	 return $max;
}

sub neutral_luminance_step {
	 my ($luminance_err,$de,$stalls,$min_step,$max_step)=@_;
	 $luminance_err=0 if(!defined($luminance_err));
	 $de=0 if(!defined($de));
	 $stalls=0 if(!defined($stalls));
	 $min_step ||= 0.25;
	 $max_step ||= 2;
	 my $abs=abs($luminance_err);
	 my $step=0.25;
	 if($abs >= 0.08 || $de >= 12) {
	  $step=4;
	 } elsif($abs >= 0.04 || $de >= 8) {
	  $step=2;
	 } elsif($abs >= 0.02 || $de >= 4) {
	  $step=1;
	 } elsif($abs >= 0.008) {
	  $step=0.5;
	 }
	 $step=1 if($stalls >= 4 && $step < 1);
	 $step=$min_step if($step < $min_step);
	 $step=$max_step if($step > $max_step);
	 return $step;
}

sub neutral_luminance_adjustments {
	 my ($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_step,$max_step)=@_;
	 return undef if(ref($arrays) ne "HASH" || ref($target) ne "HASH");
	 $luminance_err=0 if(!defined($luminance_err));
	 return undef if(abs($luminance_err) < 0.0035);
	 my $idx=$target->{"index"};
	 return undef if(!defined($idx));
	 $min_step ||= 0.25;
	 my $direction=($luminance_err > 0) ? -1 : 1;
	 my $step=neutral_luminance_step($luminance_err,$de,$stalls,$min_step,$max_step);
		 my @magnitudes=($step);
		 push @magnitudes,0.5 if($step > 0.5);
		 push @magnitudes,0.25 if($step > 0.25);
		 push @magnitudes,$min_step if($min_step < 0.25 && $step > $min_step);
			 if(has_luminance_channel($arrays,$target)) {
			  my $setting="adjustingLuminance";
			  my $arr=$arrays->{$setting};
			  foreach my $mag (@magnitudes) {
			   my $current=$arr->[$idx]||0;
			   my $next=clamp_ddc_value($current+($direction*$mag));
			   next if(abs($next-$current) < 0.0001 || repeated_value($tried,$setting,$next));
			   return [{ channel=>"lum", setting=>$setting, current=>$current, next=>$next, delta=>$next-$current, neutral_luminance=>1 }];
			  }
		  return undef;
		 }
		 foreach my $mag (@magnitudes) {
	  my @out;
	  my $blocked=0;
	  foreach my $ch (qw(r g b)) {
	   my $setting=channel_setting($ch);
	   my $arr=$arrays->{$setting};
	   if(ref($arr) ne "ARRAY") { $blocked=1; last; }
	   my $current=$arr->[$idx]||0;
	   my $next=clamp_ddc_value($current+($direction*$mag));
	   if(abs($next-$current) < 0.0001 || repeated_value($tried,$setting,$next)) { $blocked=1; last; }
	   push @out,{ channel=>$ch, setting=>$setting, current=>$current, next=>$next, delta=>$next-$current, neutral_luminance=>1 };
	  }
	  return \@out if(!$blocked && @out == 3);
	 }
	 return undef;
}

sub common_rgb_luminance_adjustments {
	 my ($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_step,$max_step)=@_;
	 return undef if(ref($arrays) ne "HASH" || ref($target) ne "HASH");
	 $luminance_err=0 if(!defined($luminance_err));
	 return undef if(abs($luminance_err) < 0.0035);
	 my $idx=$target->{"index"};
	 return undef if(!defined($idx));
	 $min_step ||= 0.25;
	 my $direction=($luminance_err > 0) ? -1 : 1;
	 my $step=neutral_luminance_step($luminance_err,$de,$stalls,$min_step,$max_step);
	 my @magnitudes=($step);
	 push @magnitudes,0.5 if($step > 0.5);
	 push @magnitudes,0.25 if($step > 0.25);
	 foreach my $mag (@magnitudes) {
	  my @out;
	  my $blocked=0;
	  foreach my $ch (qw(r g b)) {
	   my $setting=channel_setting($ch);
	   my $arr=$arrays->{$setting};
	   if(ref($arr) ne "ARRAY") { $blocked=1; last; }
	   my $current=$arr->[$idx]||0;
	   my $next=clamp_ddc_value($current+($direction*$mag));
	   if(abs($next-$current) < 0.0001 || repeated_value($tried,$setting,$next)) { $blocked=1; last; }
	   push @out,{ channel=>$ch, setting=>$setting, current=>$current, next=>$next, delta=>$next-$current, neutral_luminance=>1, common_rgb_luminance=>1 };
	  }
	  return \@out if(!$blocked && @out == 3);
	 }
	 return undef;
}

sub low_shadow_luminance_max_step {
 my ($luminance_err,$stalls,$step)=@_;
 $luminance_err=0 if(!defined($luminance_err));
 $stalls=0 if(!defined($stalls));
 my $abs=abs($luminance_err);
 my $max=0.5;
 if($abs >= 0.30) {
  $max=5;
 } elsif($abs >= 0.18) {
  $max=4;
 } elsif($abs >= 0.10) {
  $max=3;
 } elsif($abs >= 0.05) {
  $max=2;
 } elsif($abs >= 0.02) {
  $max=1;
 }
 my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : undef;
 if(defined($ire) && $ire > 0 && $ire <= 2.31) {
  $max=0.5 if($max > 0.5);
 } elsif(defined($ire) && $ire > 0 && $ire <= 3.1) {
  $max=0.5 if($max > 0.5);
 } elsif(defined($ire) && $ire > 0 && $ire <= 5.0001) {
  $max=1 if($max > 1);
  $max=1 if($stalls >= 3 && $max < 1);
 } else {
  $max=1 if($stalls >= 3 && $max < 1);
 }
 return $max;
}

sub low_shadow_luminance_priority_adjustments {
 my ($arrays,$target,$luminance_err,$de,$stalls,$tried,$step,$micro)=@_;
 return undef if(!autocal_step_is_low_shadow($step));
 return undef if(!has_luminance_channel($arrays,$target));
 $luminance_err=0 if(!defined($luminance_err));
 my $lum_pct=$luminance_err*100;
 my $tol=luminance_tolerance_percent($step);
 my $threshold=$tol*($micro ? 0.22 : 0.30);
 $threshold=0.6 if($threshold < 0.6);
 return undef if(abs($lum_pct) <= $threshold);
 my $max_step=low_shadow_luminance_max_step($luminance_err,$stalls,$step);
 $max_step=1 if($micro && $max_step > 1);
 my $min_step=$micro ? low_shadow_minimum_ddc_step($step) : 0.25;
 my $adjustments=neutral_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_step,$max_step);
 if(ref($adjustments) eq "ARRAY") {
  foreach my $adj (@{$adjustments}) {
   $adj->{"low_shadow_luminance"}=1 if(ref($adj) eq "HASH");
  }
 }
 return $adjustments;
}

sub deep_shadow_chroma_priority_adjustment {
 my ($error,$arrays,$target,$luminance_err,$de,$stalls,$tried,$step,$min_step,$max_step,$micro)=@_;
 my $trace_shadow=sub {
  my ($reason,$extra)=@_;
  $extra={} if(ref($extra) ne "HASH");
  my %data=(reason=>$reason);
  foreach my $key (keys %{$extra}) {
   $data{$key}=$extra->{$key};
  }
  trace_109($step,"deep_shadow_chroma_priority_adjustment",\%data);
 };
 if(ref($error) ne "HASH" || ref($arrays) ne "HASH" || ref($target) ne "HASH") {
  $trace_shadow->("invalid_input",{de=>defined($de)?$de+0:undef});
  return undef;
 }
 if(!has_luminance_channel($arrays,$target)) {
  $trace_shadow->("no_luminance_channel",{de=>defined($de)?$de+0:undef});
  return undef;
 }
 if(ref($step) ne "HASH" || !defined($step->{"ire"})) {
  $trace_shadow->("invalid_input",{de=>defined($de)?$de+0:undef});
  return undef;
 }
 my $ire=$step->{"ire"}+0;
 if($ire <= 0 || $ire > 3.1) {
  $trace_shadow->("not_deep_shadow",{ire=>$ire,de=>defined($de)?$de+0:undef});
  return undef;
 }
 $luminance_err=0 if(!defined($luminance_err));
 my $lum_pct=$luminance_err*100;
 my $luma_tol=luminance_tolerance_percent($step);
 if(abs($lum_pct) > $luma_tol) {
  $trace_shadow->("luma_not_close",{ire=>$ire,de=>defined($de)?$de+0:undef,luminance_error_pct=>$lum_pct+0,luminance_tolerance_pct=>$luma_tol+0});
  return undef;
 }
 my $accept_limit=itp_luminance_included_acceptance_limit($step);
 $accept_limit=1.0 if(!defined($accept_limit));
 if(!defined($de) || $de <= $accept_limit) {
  $trace_shadow->("de_too_low",{ire=>$ire,de=>defined($de)?$de+0:undef,luminance_error_pct=>$lum_pct+0,luminance_tolerance_pct=>$luma_tol+0,acceptance_limit=>$accept_limit+0});
  return undef;
 }
 my $chroma_mag=chroma_error_magnitude($error);
 if($chroma_mag < 0.020) {
  $trace_shadow->("chroma_too_low",{ire=>$ire,de=>$de+0,luminance_error_pct=>$lum_pct+0,luminance_tolerance_pct=>$luma_tol+0,chroma_mag=>$chroma_mag+0});
  return undef;
 }
 $min_step ||= 0.25;
 $max_step ||= ($micro ? 0.5 : 2);
 $max_step=0.5 if(defined($de) && $de <= 2.0 && $max_step > 0.5);
 if($micro && $ire <= 3.1) {
  my $shadow_step=low_shadow_minimum_ddc_step($step);
  $min_step=$shadow_step if($min_step > $shadow_step);
  $max_step=$shadow_step if($max_step > $shadow_step);
 }
 my @channels=sort { abs($error->{$b}||0) <=> abs($error->{$a}||0) } qw(r g b);
 foreach my $ch (@channels) {
  my $err=$error->{$ch}||0;
  next if(abs($err) < rgb_error_floor($de,0.5,$micro ? 1 : 0));
  my $setting=channel_setting($ch);
  my $arr=$arrays->{$setting};
  next if(ref($arr) ne "ARRAY");
  my $idx=$target->{"index"};
  next if(!defined($idx) || $idx >= @{$arr});
  my $current=$arr->[$idx]||0;
  my $step_size=adjustment_step(abs($err),$de,$stalls,$min_step);
  $step_size=$max_step if($step_size > $max_step);
  my $direction=($err > 0) ? -1 : 1;
  foreach my $dir ($direction,-$direction) {
   my ($next,$damped)=next_untried_value($current,$dir*$step_size,$tried,$setting,$min_step);
   next if(!defined($next));
   next if(abs($next-$current) < 0.0001);
   $trace_shadow->("selected",{ire=>$ire,de=>$de+0,luminance_error_pct=>$lum_pct+0,luminance_tolerance_pct=>$luma_tol+0,chroma_mag=>$chroma_mag+0,channel=>$ch,setting=>$setting,current=>$current+0,next=>$next+0,delta=>$next-$current,damped=>$damped ? 1 : 0,micro=>$micro ? 1 : 0});
   return [{ channel=>$ch, setting=>$setting, current=>$current, next=>$next, delta=>$next-$current, damped=>$damped ? 1 : 0, deep_shadow_chroma=>1, micro=>$micro ? 1 : 0 }];
  }
 }
 $trace_shadow->("no_untried_channel",{ire=>$ire,de=>$de+0,luminance_error_pct=>$lum_pct+0,luminance_tolerance_pct=>$luma_tol+0,chroma_mag=>$chroma_mag+0});
 return undef;
}

sub headroom_green_luminance_adjustment {
	 my ($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_step,$max_step,$error)=@_;
	 return undef if(ref($arrays) ne "HASH" || ref($target) ne "HASH");
	 $luminance_err=0 if(!defined($luminance_err));
	 return undef if(abs($luminance_err) < 0.0015);
	 my $idx=$target->{"index"};
	 return undef if(!defined($idx));
	 my $setting="whiteBalanceGreen";
	 my $arr=$arrays->{$setting};
	 return undef if(ref($arr) ne "ARRAY" || $idx >= @{$arr});
	 $min_step ||= 0.25;
	 my $direction=($luminance_err > 0) ? -1 : 1;
	 my $step=neutral_luminance_step($luminance_err,$de,$stalls,$min_step,$max_step);
	 my @magnitudes=($step);
	 push @magnitudes,1 if($step > 1);
	 push @magnitudes,0.5 if($step > 0.5);
	 push @magnitudes,0.25 if($step > 0.25 && $min_step <= 0.25);
	 push @magnitudes,0.10 if($step > 0.10 && $min_step <= 0.10);
	 my $blue_minus_green=(ref($error) eq "HASH") ? (($error->{"b"}||0)-($error->{"g"}||0)) : 0;
	 my $balance_floor=rgb_error_floor($de,0.5,0);
	 foreach my $mag (@magnitudes) {
	  my @out;
	  my ($green_scale,$luma_scale)=(1,1);
	  if(abs($blue_minus_green) > $balance_floor) {
	   if($direction > 0) {
	    ($green_scale,$luma_scale)=($blue_minus_green > 0) ? (1,0.5) : (0.5,1);
	   } else {
	    ($green_scale,$luma_scale)=($blue_minus_green > 0) ? (0.5,1) : (1,0.5);
	   }
	  }
	  my $green_mag=$mag*$green_scale;
	  my $luma_mag=$mag*$luma_scale;
	  $green_mag=$min_step if($green_mag < $min_step);
	  $luma_mag=$min_step if($luma_mag < $min_step);
	  my $current=$arr->[$idx]||0;
	  my ($next,$damped)=next_new_headroom_value($current,$direction*$green_mag,$tried,$setting,$min_step);
	  if(defined($next) && abs($next-$current) >= 0.0001) {
	   push @out,{ channel=>"g", setting=>$setting, current=>$current, next=>$next, delta=>$next-$current, damped=>$damped ? 1 : 0, green_luminance=>1 };
	  }
	  my $luma_arr=$arrays->{"adjustingLuminance"};
	  if(ref($luma_arr) eq "ARRAY" && $idx < @{$luma_arr}) {
	   my $luma_current=$luma_arr->[$idx]||0;
	   my ($luma_next,$luma_damped)=next_new_headroom_value($luma_current,$direction*$luma_mag,$tried,"adjustingLuminance",$min_step);
	   if(defined($luma_next) && abs($luma_next-$luma_current) >= 0.0001) {
	    push @out,{ channel=>"lum", setting=>"adjustingLuminance", current=>$luma_current, next=>$luma_next, delta=>$luma_next-$luma_current, damped=>$luma_damped ? 1 : 0, brightness_luminance=>1 };
	   }
	  }
	  return \@out if(@out);
	 }
	 return undef;
}

sub headroom_chroma_adjustment {
	 my ($error,$arrays,$target,$de,$stalls,$tried,$min_step,$max_step,$micro)=@_;
	 return undef if(ref($error) ne "HASH" || ref($arrays) ne "HASH" || ref($target) ne "HASH");
	 $min_step ||= 0.25;
	 $max_step ||= 6;
	 my $floor=rgb_error_floor($de,0.5,$micro ? 1 : 0);
	 $floor=0.00055 if($floor < 0.00055);
	 my @channels=sort { abs($error->{$b}||0) <=> abs($error->{$a}||0) } qw(r g b);
	 foreach my $ch (@channels) {
	  my $err=$error->{$ch}||0;
	  next if(abs($err) < $floor);
	  my $setting=channel_setting($ch);
	  my $arr=$arrays->{$setting};
	  next if(ref($arr) ne "ARRAY");
	  my $idx=$target->{"index"};
	  next if(!defined($idx) || $idx >= @{$arr});
	  my $current=$arr->[$idx]||0;
	  my $step=adjustment_step(abs($err),$de,$stalls,$min_step);
	  $step=$max_step if(defined($max_step) && $step > $max_step);
	  my $direction=($err > 0) ? -1 : 1;
	  my ($next,$damped)=next_new_headroom_value($current,$direction*$step,$tried,$setting,$min_step);
	  next if(!defined($next) || abs($next-$current) < 0.0001);
	  return [{ channel=>$ch, setting=>$setting, current=>$current, next=>$next, delta=>$next-$current, damped=>$damped ? 1 : 0, headroom_chroma=>1, micro=>$micro ? 1 : 0 }];
	 }
	 return undef;
}

sub peak_headroom_floor_adjustments {
 my ($error,$arrays,$target,$de,$stalls,$tried,$min_step,$max_step)=@_;
 return undef if(ref($error) ne "HASH" || ref($arrays) ne "HASH" || ref($target) ne "HASH");
 $min_step ||= 0.25;
 $max_step ||= 10;
 my $idx=$target->{"index"};
 return undef if(!defined($idx));
 my @channels=qw(r g b);
 my $floor_ch=$target->{"peak_headroom_floor_channel"};
 if(!$floor_ch || $floor_ch !~ /^(?:r|g|b)$/) {
  my @ordered=sort { ($error->{$a}||0) <=> ($error->{$b}||0) } @channels;
  $floor_ch=$ordered[0];
  $target->{"peak_headroom_floor_channel"}=$floor_ch;
 }
 my $floor=$error->{$floor_ch}||0;
 my $min_gap=rgb_error_floor($de,0.5,0);
 $min_gap=0.0015 if($min_gap < 0.0015);
 my @out;
 foreach my $ch (sort { (($error->{$b}||0)-$floor) <=> (($error->{$a}||0)-$floor) } grep { $_ ne $floor_ch } @channels) {
  my $gap=($error->{$ch}||0)-$floor;
  next if($gap < $min_gap);
  my $setting=channel_setting($ch);
  my $arr=$arrays->{$setting};
  next if(ref($arr) ne "ARRAY" || $idx >= @{$arr});
  my $current=$arr->[$idx]||0;
  my $step=adjustment_step($gap,$de,$stalls,$min_step);
  $step=$max_step if($step > $max_step);
  my ($next,$damped)=next_new_headroom_value($current,-$step,$tried,$setting,$min_step);
  next if(!defined($next) || abs($next-$current) < 0.0001);
  push @out,{
   channel=>$ch,
   setting=>$setting,
   current=>$current,
   next=>$next,
   delta=>$next-$current,
   damped=>$damped ? 1 : 0,
   peak_floor_balance=>1,
   floor_channel=>$floor_ch,
  };
 }
 return @out ? \@out : undef;
}

sub headroom_rgb_luminance_adjustments {
	 my ($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_step,$max_step)=@_;
	 return undef if(ref($arrays) ne "HASH" || ref($target) ne "HASH");
	 $luminance_err=0 if(!defined($luminance_err));
	 return undef if(abs($luminance_err) < 0.0025);
	 # The LG 1D LUT upload treats RGB white-balance arrays as chroma-only:
	 # their mean is subtracted before upload. Headroom Y must therefore use
	 # the per-point luminance channel when the TV exposes it.
	 if(has_luminance_channel($arrays,$target)) {
	  my $luma=neutral_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_step,$max_step);
	  if($luma) {
	   foreach my $adj (@{$luma}) {
	    $adj->{"headroom_luminance"}=1 if(ref($adj) eq "HASH");
	   }
	   return $luma;
	  }
	  return undef;
	 }
	 my $idx=$target->{"index"};
	 return undef if(!defined($idx));
	 $min_step ||= 0.25;
	 my $direction=($luminance_err > 0) ? -1 : 1;
	 my $step=neutral_luminance_step($luminance_err,$de,$stalls,$min_step,$max_step);
	 my @magnitudes=($step);
	 push @magnitudes,1 if($step > 1);
	 push @magnitudes,0.5 if($step > 0.5);
	 push @magnitudes,0.25 if($step > 0.25 && $min_step <= 0.25);
	 push @magnitudes,0.10 if($step > 0.10 && $min_step <= 0.10);
	 foreach my $mag (@magnitudes) {
	  my @out;
	  my $blocked=0;
	  foreach my $ch (qw(r g b)) {
	   my $setting=channel_setting($ch);
	   my $arr=$arrays->{$setting};
	   if(ref($arr) ne "ARRAY" || $idx >= @{$arr}) { $blocked=1; last; }
	   my $current=$arr->[$idx]||0;
	   my ($next,$damped)=next_new_headroom_value($current,$direction*$mag,$tried,$setting,$min_step);
	   if(!defined($next) || abs($next-$current) < 0.0001) { $blocked=1; last; }
	   push @out,{ channel=>$ch, setting=>$setting, current=>$current, next=>$next, delta=>$next-$current, damped=>$damped ? 1 : 0, neutral_luminance=>1, headroom_rgb_luminance=>1 };
	  }
	  return \@out if(!$blocked && @out == 3);
	 }
	 return undef;
}

sub headroom_match_green_adjustment {
	 my ($error,$arrays,$target,$de,$stalls,$tried,$min_step,$max_step)=@_;
	 return undef if(ref($error) ne "HASH" || ref($arrays) ne "HASH" || ref($target) ne "HASH");
	 return undef if(!defined($error->{"g"}));
	 my $idx=$target->{"index"};
	 return undef if(!defined($idx));
	 $min_step ||= 0.25;
	 my $floor=rgb_error_floor($de,0.5,0);
	 $floor=0.00055 if($floor < 0.00055);
	 my @channels=sort {
	  abs(($error->{$b}||0)-($error->{"g"}||0)) <=> abs(($error->{$a}||0)-($error->{"g"}||0))
	 } qw(r b);
	 foreach my $ch (@channels) {
	  my $diff=($error->{$ch}||0)-($error->{"g"}||0);
	  next if(abs($diff) < $floor);
	  my $setting=channel_setting($ch);
	  my $arr=$arrays->{$setting};
	  next if(ref($arr) ne "ARRAY" || $idx >= @{$arr});
	  my $current=$arr->[$idx]||0;
	  my $step=adjustment_step(abs($diff),$de,$stalls,$min_step);
	  $step=$max_step if(defined($max_step) && $step > $max_step);
	  my $direction=($diff > 0) ? -1 : 1;
	  my ($next,$damped)=next_new_headroom_value($current,$direction*$step,$tried,$setting,$min_step);
	  next if(!defined($next) || abs($next-$current) < 0.0001);
	  return [{ channel=>$ch, setting=>$setting, current=>$current, next=>$next, delta=>$next-$current, damped=>$damped ? 1 : 0, match_green=>1 }];
	 }
	 return undef;
}

sub ddc_target_max_delta {
	 my ($arrays,$baseline,$target)=@_;
	 return 0 if(ref($arrays) ne "HASH" || ref($baseline) ne "HASH" || ref($target) ne "HASH");
	 my $idx=$target->{"index"};
	 return 0 if(!defined($idx));
	 my $max_delta=0;
		 foreach my $setting (ddc_adjustment_settings($arrays)) {
	  my $arr=$arrays->{$setting};
	  my $base_arr=$baseline->{$setting};
	  next if(ref($arr) ne "ARRAY" || ref($base_arr) ne "ARRAY");
	  my $value=defined($arr->[$idx]) ? ($arr->[$idx]+0) : 0;
	  my $base=defined($base_arr->[$idx]) ? ($base_arr->[$idx]+0) : 0;
	  my $delta=abs($value-$base);
	  $max_delta=$delta if($delta > $max_delta);
	 }
		 return $max_delta;
}

sub ddc_target_near_limit {
	 my ($arrays,$target,$limit)=@_;
	 $limit=45 if(!defined($limit));
	 return 0 if(ref($arrays) ne "HASH" || ref($target) ne "HASH");
	 my $idx=$target->{"index"};
	 return 0 if(!defined($idx));
		 foreach my $setting (ddc_adjustment_settings($arrays)) {
	  my $arr=$arrays->{$setting};
	  next if(ref($arr) ne "ARRAY");
	  my $value=defined($arr->[$idx]) ? ($arr->[$idx]+0) : 0;
	  return 1 if(abs($value) >= $limit);
	 }
	 return 0;
}

sub restore_target_slot_arrays {
	 my ($arrays,$baseline,$target)=@_;
	 my $restored=clone_arrays($arrays);
	 return $restored if(ref($baseline) ne "HASH" || ref($target) ne "HASH");
	 my $idx=$target->{"index"};
	 return $restored if(!defined($idx));
		 foreach my $setting (ddc_adjustment_settings($arrays)) {
	  my $arr=$restored->{$setting};
	  my $base_arr=$baseline->{$setting};
	  next if(ref($arr) ne "ARRAY" || ref($base_arr) ne "ARRAY");
	  $arr->[$idx]=defined($base_arr->[$idx]) ? ($base_arr->[$idx]+0) : 0;
	 }
	 return $restored;
}

sub far_from_target {
	 my ($de,$lum_pct,$target_delta,$step)=@_;
	 return 1 if(defined($de) && $de > (($target_delta||0.5)*4));
	 return 0 if(!defined($lum_pct));
	 return abs($lum_pct) > luminance_tolerance_percent($step)*1.5;
}

sub probe_adjustment {
	 my ($error,$arrays,$target,$de,$luminance_err)=@_;
	 return undef if(ref($error) ne "HASH" || ref($arrays) ne "HASH" || ref($target) ne "HASH");
			 $luminance_err=0 if(!defined($luminance_err));
			 if(has_luminance_channel($arrays,$target) && abs($luminance_err) >= 0.012) {
			  my $setting="adjustingLuminance";
			  my $arr=$arrays->{$setting};
			  my $idx=$target->{"index"};
			  my $current=$arr->[$idx]||0;
			  my $direction=($luminance_err > 0) ? -1 : 1;
			  my $step=abs($luminance_err) >= 0.20 ? 8 : 4;
			  foreach my $dir ($direction,-$direction) {
			   my $next=clamp_ddc_value($current+($dir*$step));
			   next if(abs($next-$current) < 0.0001);
			   return { channel=>"lum", setting=>$setting, current=>$current, next=>$next, delta=>$next-$current };
			  }
			 }
			 my $luminance_drive=has_luminance_channel($arrays,$target) ? 0 : luminance_adjustment_drive($luminance_err);
			 my %combined=map { $_ => (($error->{$_}||0)+$luminance_drive) } qw(r g b);
	 my @channels=sort { abs($combined{$b}||0) <=> abs($combined{$a}||0) } qw(r g b);
	 foreach my $ch (@channels) {
	  my $setting=channel_setting($ch);
	  my $arr=$arrays->{$setting};
	  next if(ref($arr) ne "ARRAY");
	  my $idx=$target->{"index"};
	  next if(!defined($idx) || $idx >= @{$arr});
	  my $current=$arr->[$idx]||0;
	  my $direction=(($combined{$ch}||0) > 0) ? -1 : 1;
	  foreach my $dir ($direction,-$direction) {
	   my $next=clamp_ddc_value($current+($dir*8));
	   next if(abs($next-$current) < 0.0001);
	   return { channel=>$ch, setting=>$setting, current=>$current, next=>$next, delta=>$next-$current };
	  }
	 }
	 return undef;
}

sub probe_responsive_stimulus {
	 my ($config,$state,$step,$arrays,$slot_default_arrays,$target,$picture,$picture_mode,$calibration_mode_active,$reading,$white_y,$target_gamma,$signal_mode,$target_x,$target_y,$probe_tried)=@_;
	 return (undef,$reading,$arrays,$picture,undef) if(ref($step) ne "HASH" || ref($arrays) ne "HASH" || ref($target) ne "HASH");
	 return (undef,$reading,$arrays,$picture,undef) if(!stimulus_probe_enabled($config));
	 my @probe_steps=stimulus_scan_steps($config,$step,$probe_tried);
	 return (undef,$reading,$arrays,$picture,undef) if(!@probe_steps);
	 my $err=rgb_error($reading);
	 my $target_step_y=effective_target_luminance_for_autocal_reading($white_y,$step,$reading,$target_gamma,$signal_mode);
	 my $lum_err=luminance_error_ratio($reading,$target_step_y);
	 my $current_de=autocal_delta_e_for_step($reading,$white_y,$target_x,$target_y,$target_step_y,$step);
	 my $current_lum_pct=luminance_error_percent($reading,$target_step_y);
	 my $current_score=autocal_result_score($current_de,$current_lum_pct,$step);
	 my $probe_adj=probe_adjustment($err,$arrays,$target,undef,$lum_err);
	 return (undef,$reading,$arrays,$picture,undef) if(!$probe_adj);
	 my $base_arrays=restore_target_slot_arrays($arrays,$slot_default_arrays,$target);
	 my $base_picture=$picture;
	 my $best_probe_score=0;
	 my $scan_count=scalar(@probe_steps);
	 my $best_probe_metric=undef;
	 my ($best_probe_step,$best_before,$best_restore_arrays,$best_picture);
	 foreach my $probe_step (@probe_steps) {
	  last if(cancelled());
	  mark_stimulus_probe_tried($probe_tried,$probe_step);
	  my $stimulus=format_percent($probe_step->{"stimulus"});
	  $state->{"phase"}="probing";
	  $state->{"message"}="Scanning ".$target->{"label"}." response at ".$stimulus."% patch stimulus";
	  $state->{"probe_stimulus"}=$probe_step->{"stimulus"}+0;
	  write_state($state);
	  my $write_error;
	  my $base_write_arrays=clone_arrays($base_arrays);
	  ($picture,$write_error)=set_picture_values($base_picture,$base_write_arrays,$target,$picture_mode,$calibration_mode_active,$state);
	  return (undef,$reading,$arrays,$picture,$write_error) if($write_error);
	  sync_state_picture($state,$picture,$picture_mode);
	  my ($before,$read_error)=read_step($config,$probe_step,$state);
	  return (undef,$reading,$arrays,$picture,$read_error) if($read_error && $read_error ne "cancelled");
	  last if($read_error && $read_error eq "cancelled");
		  next if(ref($before) ne "HASH");
		  my $candidate_target_y=effective_target_luminance_for_autocal_reading($white_y,$probe_step,$before,$target_gamma,$signal_mode);
		  annotate_reading_target($before,$white_y,$candidate_target_y,$target_x,$target_y);
		  my $candidate_de=autocal_delta_e_for_step($before,$white_y,$target_x,$target_y,$candidate_target_y,$probe_step);
		  my $candidate_lum_pct=luminance_error_percent($before,$candidate_target_y);
		  my $test_arrays=clone_arrays($base_arrays);
	  $test_arrays->{$probe_adj->{"setting"}}[$target->{"index"}]=$probe_adj->{"next"};
	  $state->{"message"}="Testing ".$target->{"label"}." response at ".$stimulus."% with ".uc($probe_adj->{"channel"})." ".sprintf("%+.2f",$probe_adj->{"delta"});
	  write_state($state);
	  ($picture,$write_error)=set_picture_values($picture,$test_arrays,$target,$picture_mode,1,$state);
	  return (undef,$reading,$arrays,$picture,$write_error) if($write_error);
	  sync_state_picture($state,$picture,$picture_mode);
	  my ($after,$after_error)=read_step($config,$probe_step,$state);
	  return (undef,$reading,$test_arrays,$picture,$after_error) if($after_error && $after_error ne "cancelled");
	  last if($after_error && $after_error eq "cancelled");
	  next if(ref($after) ne "HASH");
		  my $score=reading_change_score($before,$after);
		  $best_probe_score=$score if($score > $best_probe_score);
	  my $restore_arrays=clone_arrays($base_arrays);
	  my $restore_error;
	  ($picture,$restore_error)=set_picture_values($picture,$restore_arrays,$target,$picture_mode,1,$state);
	  return (undef,$reading,$restore_arrays,$picture,$restore_error) if($restore_error);
	  sync_state_picture($state,$picture,$picture_mode);
		  my $candidate_score=autocal_result_score($candidate_de,$candidate_lum_pct,$probe_step);
		  my $allowance=($current_score > 8) ? 6 : (($current_score > 4) ? 3 : 1.5);
		  next if($candidate_score > $current_score+$allowance);
		  my $response_bonus=$score;
		  $response_bonus=0.5 if($response_bonus > 0.5);
		  my $metric=$candidate_score-$response_bonus;
		  if($score >= 0.004 && (!defined($best_probe_metric) || $metric < $best_probe_metric)) {
		   $best_probe_metric=$metric;
		   $best_probe_step=$probe_step;
		   $best_before=$before;
		   $best_restore_arrays=$restore_arrays;
		   $best_picture=$picture;
		  }
		 }
		 if($best_probe_step) {
		  $state->{"message"}=$target->{"label"}." strongest DDC response at ".format_percent($best_probe_step->{"stimulus"})."% patch stimulus";
		  $state->{"active_stimulus"}=$best_probe_step->{"stimulus"}+0;
		  write_state($state);
		  return ($best_probe_step,$best_before,$best_restore_arrays,$best_picture,undef);
		 }
	 my $restore_arrays=clone_arrays($base_arrays);
	 my $write_error;
	 ($picture,$write_error)=set_picture_values($picture,$restore_arrays,$target,$picture_mode,1,$state);
	 sync_state_picture($state,$picture,$picture_mode) if(!$write_error);
	 $state->{"message"}="No responsive patch stimulus found within +/-8% for ".$target->{"label"};
	 $state->{"probe_score"}=$best_probe_score;
	 write_state($state);
	 return (undef,$reading,$restore_arrays,$picture,$write_error);
}

sub choose_headroom_single_adjustment {
			 my ($error,$arrays,$target,$de,$min_step,$stalls,$tried,$step)=@_;
		 return undef if(!autocal_step_is_fast_headroom($step));
		 return undef if(ref($error) ne "HASH" || ref($arrays) ne "HASH" || ref($target) ne "HASH");
		 $min_step ||= 0.25;
		 $stalls=0 if(!defined($stalls));
		 my $floor=rgb_error_floor($de,0.5,0);
		 my @channels;
		 if(autocal_step_is_peak_headroom($step)) {
		  my @weakest=sort { ($error->{$a}||0) <=> ($error->{$b}||0) } qw(r g b);
		  my $frozen=$weakest[0];
		  my @high=sort { ($error->{$b}||0) <=> ($error->{$a}||0) } grep { $_ ne $frozen && ($error->{$_}||0) > $floor } qw(r g b);
		  @channels=@high;
		  if(!@channels) {
		   @channels=sort { abs($error->{$b}||0) <=> abs($error->{$a}||0) } grep { $_ ne $frozen } qw(r g b);
		  }
		 } else {
		  @channels=sort { abs($error->{$b}||0) <=> abs($error->{$a}||0) } qw(r g b);
		 }
		 my $ch=$channels[0];
		 return undef if(!$ch);
		 my $err=$error->{$ch}||0;
		 return undef if(abs($err) < $floor);
		 my $setting=channel_setting($ch);
		 my $arr=$arrays->{$setting};
		 return undef if(ref($arr) ne "ARRAY");
		 my $idx=$target->{"index"};
		 return undef if(!defined($idx) || $idx >= @{$arr});
		 my $current=$arr->[$idx]||0;
		 my $step_size=adjustment_step(abs($err),$de,$stalls,$min_step);
		 $step_size=10 if(abs($err) >= 0.08 && $step_size < 10);
		 my $direction=($err > 0) ? -1 : 1;
		 my ($next,$damped)=next_new_headroom_value($current,$direction*$step_size,$tried,$setting,$min_step);
		 return undef if(!defined($next) || abs($next-$current) < 0.0001);
		 return [{ channel=>$ch, setting=>$setting, current=>$current, next=>$next, delta=>$next-$current, damped=>$damped ? 1 : 0, headroom_single=>1, strict_furthest=>1 }];
		 return undef;
}

sub round_ddc_quarter {
 my ($value)=@_;
 $value=0 if(!defined($value));
 my $rounded=($value >= 0) ? int($value*4+0.5)/4 : int($value*4-0.5)/4;
 return clamp_ddc_value($rounded);
}

sub headroom_proportional_adjustment {
 my ($step,$adjustments,$before,$after,$arrays,$target,$tried)=@_;
 return undef if(!autocal_step_is_fast_headroom($step));
 return undef if(ref($adjustments) ne "ARRAY" || @{$adjustments} != 1);
 return undef if(ref($before) ne "HASH" || ref($after) ne "HASH" || ref($arrays) ne "HASH" || ref($target) ne "HASH");
 my $adj=$adjustments->[0];
 return undef if(ref($adj) ne "HASH");
 return undef if($adj->{"green_luminance"} || $adj->{"brightness_luminance"} || $adj->{"match_green"});
 my $ch=$adj->{"channel"}||"";
 return undef if($ch !~ /^(?:r|g|b)$/);
 my $setting=$adj->{"setting"};
 my $idx=$target->{"index"};
 return undef if(!$setting || !defined($idx) || ref($arrays->{$setting}) ne "ARRAY");
 my $before_err=rgb_error($before);
 my $after_err=rgb_error($after);
 return undef if(ref($before_err) ne "HASH" || ref($after_err) ne "HASH");
 my $e0=$before_err->{$ch};
 my $e1=$after_err->{$ch};
 return undef if(!defined($e0) || !defined($e1));
 return undef if($e0 == 0 || abs($e1-$e0) < 0.0005);
 return undef if(($e0 > 0 && $e1 > 0) || ($e0 < 0 && $e1 < 0));
 my $current=defined($arrays->{$setting}[$idx]) ? ($arrays->{$setting}[$idx]+0) : 0;
 my $start=defined($adj->{"current"}) ? ($adj->{"current"}+0) : ($current-($adj->{"delta"}||0));
 my $end=defined($adj->{"next"}) ? ($adj->{"next"}+0) : $current;
 my $ideal=$start - ($e0*($end-$start)/($e1-$e0));
 $ideal=round_ddc_quarter($ideal);
 my $lo=$start < $end ? $start : $end;
 my $hi=$start > $end ? $start : $end;
 return undef if($ideal < $lo-0.0001 || $ideal > $hi+0.0001);
 return undef if(abs($ideal-$current) < 0.0001);
 return undef if(tried_value_exists($tried,$setting,$ideal));
 return [{ channel=>$ch, setting=>$setting, current=>$current, next=>$ideal, delta=>$ideal-$current, damped=>0, headroom_single=>1, proportional=>1 }];
}

sub choose_adjustments {
			 my ($error,$arrays,$target,$de,$min_step,$stalls,$luminance_err,$tried,$step)=@_;
		 return undef if(ref($error) ne "HASH" || ref($target) ne "HASH");
		 $min_step ||= 0.25;
			 $luminance_err=0 if(!defined($luminance_err));
			 my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : 100;
			 $luminance_err=0 if($ire >= 99.9 && !autocal_step_is_fast_headroom($step));
			 if(autocal_step_is_fast_headroom($step)) {
			  if(autocal_step_is_peak_headroom($step)) {
			   return peak_headroom_floor_adjustments($error,$arrays,$target,$de,$stalls,$tried,$min_step,10);
			  }
			  my $lum_pct=$luminance_err*100;
			  my $luma_tol=luminance_tolerance_percent($step);
			  my $chroma_mag=chroma_error_magnitude($error);
			  if(abs($lum_pct) > $luma_tol && $chroma_mag < 0.035) {
			   my $max_luma_step=abs($luminance_err) >= 0.12 ? 4 : (abs($luminance_err) >= 0.04 ? 2 : 1);
			   my $rgb_luma=headroom_rgb_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_step,$max_luma_step);
			   return $rgb_luma if($rgb_luma);
			  }
			  my $chroma=headroom_chroma_adjustment($error,$arrays,$target,$de,$stalls,$tried,$min_step,6,0);
			  return $chroma if($chroma);
			  if(abs($lum_pct) > $luma_tol) {
			   my $max_luma_step=abs($luminance_err) >= 0.12 ? 4 : (abs($luminance_err) >= 0.04 ? 2 : 1);
			   my $rgb_luma=headroom_rgb_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_step,$max_luma_step);
			   return $rgb_luma if($rgb_luma);
			  }
			  my $fine_chroma=headroom_chroma_adjustment($error,$arrays,$target,$de,$stalls,$tried,$min_step,2,0);
			  return $fine_chroma if($fine_chroma);
			  return undef;
			 }
			 my $lum_pct=$luminance_err*100;
			 my $luma_tol=luminance_tolerance_percent($step);
			 if(autocal_step_is_low_shadow($step)) {
			  my $shadow_chroma=deep_shadow_chroma_priority_adjustment($error,$arrays,$target,$luminance_err,$de,$stalls,$tried,$step,$min_step,2,0);
			  return $shadow_chroma if($shadow_chroma);
			  my $shadow_luma=low_shadow_luminance_priority_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,$step,0);
			  return $shadow_luma if($shadow_luma);
			 }
			 if($ire <= 10.0001 && has_luminance_channel($arrays,$target) && abs($lum_pct) > ($luma_tol*1.05)) {
			  my $max_luma_step=abs($luminance_err) >= 0.20 ? 4 : (abs($luminance_err) >= 0.08 ? 2 : 1);
			  my $neutral=neutral_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,0.25,$max_luma_step);
			  return $neutral if($neutral);
			 }
			 if($ire < 90 && has_luminance_channel($arrays,$target) && abs($lum_pct) > (($luma_tol*3) > 8 ? ($luma_tol*3) : 8)) {
			  my $max_luma_step=abs($luminance_err) >= 0.20 ? 6 : 4;
			  my $neutral=neutral_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_step,$max_luma_step);
			  return $neutral if($neutral);
			 }
			 my $luminance_drive=has_luminance_channel($arrays,$target) ? 0 : luminance_adjustment_drive($luminance_err);
	 my %combined=map { $_ => (($error->{$_}||0)+$luminance_drive) } qw(r g b);
		 my @channels=sort { abs($combined{$b}||0) <=> abs($combined{$a}||0) } qw(r g b);
		 my @out;
		 my $near_fine=(defined($de) && $de <= 2.0) ? 1 : 0;
		 $near_fine=0 if($ire >= 99.9 && defined($de) && $de > 0.75);
		 my $luma_priority=(abs($luminance_drive) >= 0.012) ? 1 : 0;
		 my $chroma_mag=chroma_error_magnitude($error);
			 if($ire > 10.0001 && $ire < 99.9 && $chroma_mag < 0.012 && abs($lum_pct) > ($luma_tol*0.35)) {
			  my $max_luma_step=abs($luminance_err) >= 0.08 ? 2 : 1;
			  my $common_luma=common_rgb_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_step,$max_luma_step);
			  return $common_luma if($common_luma);
			 }
			 if(has_luminance_channel($arrays,$target) && abs($lum_pct) > ($luma_tol*0.35)) {
			  my $max_luma_step=abs($luminance_err) >= 0.20 ? 6 : 3;
			  my $neutral=neutral_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_step,$max_luma_step);
			  if($neutral) {
			   my $luma_takeover=($chroma_mag < 0.012 || ($near_fine && $chroma_mag < 0.020) || (defined($de) && $de <= 3.0 && $chroma_mag < 0.035 && abs($lum_pct) > ($luma_tol*1.10))) ? 1 : 0;
			   return $neutral if($luma_takeover);
			   push @out,@{$neutral} if($chroma_mag < 0.025 && abs($lum_pct) > ($luma_tol*0.75));
			  }
			 }
		 if(abs($lum_pct) > ($luma_tol*0.55) && chroma_error_magnitude($error) < 0.020) {
		  my $neutral=neutral_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_step,2);
		  return $neutral if($neutral);
		 }
		 foreach my $ch (@channels) {
	  my $err=$combined{$ch}||0;
		  next if(abs($err) < rgb_error_floor($de,0.5,0));
  my $setting=channel_setting($ch);
  my $arr=$arrays->{$setting};
	  next if(ref($arr) ne "ARRAY");
	  my $idx=$target->{"index"};
		  my $current=$arr->[$idx]||0;
			  my $step=adjustment_step(abs($err),$de,$stalls,$min_step);
		  my $delta = ($err > 0) ? -$step : $step;
		  foreach my $try_delta ($delta,-$delta) {
		   my ($next,$damped)=next_untried_value($current,$try_delta,$tried,$setting,$min_step);
		   next if(!defined($next));
		   next if(abs($next-$current) < 0.0001);
		   push @out,{ channel=>$ch, setting=>$setting, current=>$current, next=>$next, delta=>$next-$current, damped=>$damped ? 1 : 0 };
		   last;
		  }
		  last if(@out && $near_fine && !$luma_priority);
		 }
		 return @out ? \@out : undef;
}

sub choose_micro_adjustments {
			 my ($error,$arrays,$target,$luminance_err,$tried,$max_step,$de,$stalls,$step)=@_;
			 return undef if(ref($error) ne "HASH" || ref($arrays) ne "HASH" || ref($target) ne "HASH");
			 $luminance_err=0 if(!defined($luminance_err));
				 my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : 100;
				 $luminance_err=0 if($ire >= 99.9 && !autocal_step_is_fast_headroom($step));
			 $max_step=0.10 if(!defined($max_step) || $max_step < 0.10);
			 $max_step=0.5 if($max_step > 0.5);
			 my $min_micro_step=($max_step < 0.25) ? $max_step : 0.25;
			 $min_micro_step=low_shadow_minimum_ddc_step($step) if(autocal_step_is_low_shadow($step) && $ire <= 3.1);
			 my $lum_pct=$luminance_err*100;
			 my $luma_tol=luminance_tolerance_percent($step);
			 if(autocal_step_is_low_shadow($step)) {
			  my $shadow_chroma=deep_shadow_chroma_priority_adjustment($error,$arrays,$target,$luminance_err,$de,$stalls,$tried,$step,$min_micro_step,$max_step,1);
			  return $shadow_chroma if($shadow_chroma);
			  my $shadow_luma=low_shadow_luminance_priority_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,$step,1);
			  return $shadow_luma if($shadow_luma);
			 }
			 if($ire <= 10.0001 && has_luminance_channel($arrays,$target) && abs($lum_pct) > ($luma_tol*0.85)) {
			  my $luma_max_step=abs($luminance_err) >= 0.20 ? 4 : (abs($luminance_err) >= 0.08 ? 2 : $max_step);
			  my $neutral=neutral_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,0.25,$luma_max_step);
			  return $neutral if($neutral);
			 }
			 if(autocal_step_is_fast_headroom($step)) {
			  if(autocal_step_is_peak_headroom($step)) {
			   return peak_headroom_floor_adjustments($error,$arrays,$target,$de,$stalls,$tried,$min_micro_step,$max_step);
			  }
			  my $chroma_mag=chroma_error_magnitude($error);
			  if(abs($lum_pct) > ($luma_tol*0.45) && $chroma_mag < 0.030) {
			   my $luma_max_step=abs($luminance_err) >= 0.04 ? 1 : $max_step;
			   my $rgb_luma=headroom_rgb_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_micro_step,$luma_max_step);
			   return $rgb_luma if($rgb_luma);
			  }
			  my $chroma=headroom_chroma_adjustment($error,$arrays,$target,$de,$stalls,$tried,$min_micro_step,$max_step,1);
			  return $chroma if($chroma);
			  if(abs($lum_pct) > ($luma_tol*0.45)) {
			   my $luma_max_step=abs($luminance_err) >= 0.04 ? 1 : $max_step;
			   my $rgb_luma=headroom_rgb_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_micro_step,$luma_max_step);
			   return $rgb_luma if($rgb_luma);
			  }
			  my $fine_chroma=headroom_chroma_adjustment($error,$arrays,$target,$de,$stalls,$tried,$min_micro_step,$max_step,1);
			  return $fine_chroma if($fine_chroma);
			  if(abs($lum_pct) > ($luma_tol*0.20)) {
			   my $rgb_luma=headroom_rgb_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_micro_step,$max_step);
			   return $rgb_luma if($rgb_luma);
			  }
			  return undef;
			 }
				 if(has_luminance_channel($arrays,$target) && abs($lum_pct) > ($luma_tol*0.35)) {
				  my $luma_max_step=$max_step;
				  $luma_max_step=4 if(abs($luminance_err) >= 0.20 && $luma_max_step < 4);
				  $luma_max_step=2 if(abs($luminance_err) >= 0.08 && $luma_max_step < 2);
				  if($ire > 10.0001 && $ire < 99.9 && chroma_error_magnitude($error) < 0.012) {
				   my $common_luma=common_rgb_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,0.25,$luma_max_step);
				   return $common_luma if($common_luma);
				  }
				  my $neutral=neutral_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,0.25,$luma_max_step);
				  return $neutral if($neutral && ((defined($de) && $de <= 3.0) || chroma_error_magnitude($error) < 0.015));
				 }
			 if(abs($lum_pct) > ($luma_tol*0.45) && chroma_error_magnitude($error) < 0.016) {
			  my $neutral=neutral_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,0.25,$max_step);
			  return $neutral if($neutral);
			 }
				 my $luminance_drive=has_luminance_channel($arrays,$target) ? 0 : luminance_adjustment_drive($luminance_err);
		 my %combined=map { $_ => (($error->{$_}||0)+$luminance_drive) } qw(r g b);
		 my @channels=sort { abs($combined{$b}||0) <=> abs($combined{$a}||0) } qw(r g b);
		 my @magnitudes;
		 foreach my $mag ($max_step,0.25,0.10) {
		  next if($mag > $max_step+0.0001 || $mag < $min_micro_step-0.0001);
		  push @magnitudes,$mag if(!grep { abs($_-$mag)<0.0001 } @magnitudes);
		 }
		 foreach my $ch (@channels) {
		  my $err=$combined{$ch}||0;
			  next if(abs($err) < rgb_error_floor($de,0.5,1));
		  my $setting=channel_setting($ch);
		  my $arr=$arrays->{$setting};
		  next if(ref($arr) ne "ARRAY");
		  my $idx=$target->{"index"};
		  next if(!defined($idx) || $idx >= @{$arr});
		  my $current=$arr->[$idx]||0;
		  my $direction=($err > 0) ? -1 : 1;
		  foreach my $mag (@magnitudes) {
		   foreach my $dir ($direction,-$direction) {
		    my ($next,$damped)=next_untried_value($current,$dir*$mag,$tried,$setting,$min_micro_step);
		    next if(!defined($next));
		    next if(abs($next-$current) < 0.0001);
		    return [{ channel=>$ch, setting=>$setting, current=>$current, next=>$next, delta=>$next-$current, damped=>$damped ? 1 : 0, micro=>1 }];
		   }
			  }
			 }
			 my @sweep_channels=qw(r g b);
			 push @sweep_channels,"lum" if(has_luminance_channel($arrays,$target) && ($ire < 99.9 || autocal_step_is_fast_headroom($step)));
			 foreach my $mag (@magnitudes) {
			  foreach my $ch (@sweep_channels) {
			   my $setting=channel_setting($ch);
			   my $arr=$arrays->{$setting};
			   next if(ref($arr) ne "ARRAY");
			   my $idx=$target->{"index"};
			   next if(!defined($idx) || $idx >= @{$arr});
			   my $current=$arr->[$idx]||0;
			   foreach my $dir (1,-1) {
			    my ($next,$damped)=next_untried_value($current,$dir*$mag,$tried,$setting,$min_micro_step);
			    next if(!defined($next));
			    next if(abs($next-$current) < 0.0001);
			    return [{ channel=>$ch, setting=>$setting, current=>$current, next=>$next, delta=>$next-$current, damped=>$damped ? 1 : 0, micro=>1, sweep=>1 }];
			   }
			  }
			 }
			 return undef;
	}

sub describe_adjustments {
			 my ($adjustments)=@_;
			 return "" if(ref($adjustments) ne "ARRAY");
			 return join(" ",map { (($_->{"channel"}||"") eq "lum" ? "Brightness" : uc($_->{"channel"}||"?"))." ".sprintf("%+.2f",$_->{"delta"}||0).($_->{"neutral_luminance"}?" Y":"").($_->{"damped"}?" damped":"") } @{$adjustments});
		}

sub merge_reading {
 my ($readings,$reading)=@_;
 $readings=[] if(ref($readings) ne "ARRAY");
 return $readings if(ref($reading) ne "HASH");
 my $name=$reading->{"name"}||"";
 my $ire=defined($reading->{"ire"}) ? $reading->{"ire"} : "";
 for(my $i=0;$i<@{$readings};$i++) {
  my $item=$readings->[$i];
  next if(ref($item) ne "HASH");
  if(($name ne "" && ($item->{"name"}||"") eq $name) || ($ire ne "" && defined($item->{"ire"}) && abs(($item->{"ire"}+0)-($ire+0))<0.001)) {
   $readings->[$i]=$reading;
   return $readings;
  }
 }
 push @{$readings},$reading;
 return $readings;
}

sub write_state {
 my ($state)=@_;
 $state={} if(ref($state) ne "HASH");
 $state->{"autocal"}=JSON::PP::true;
 write_file($state_file,$json->encode($state));
}

sub lg_write_error_is_transient {
 my ($message)=@_;
 $message="" if(!defined($message));
 return ($message =~ /(?:Unable to connect to LG WebOS TV|unexpected hello response|no hello response|connection|connect|timed?\s*out|timeout|closed|broken pipe|reset by peer|no route|network is unreachable|temporar|did not finish the white-balance write|Web UI API timed out)/i) ? 1 : 0;
}

sub set_picture_values {
 my ($picture,$arrays,$target,$picture_mode,$calibration_mode_active,$state,$verify_ddc_upload,$keep_calibration_mode)=@_;
 $keep_calibration_mode=1 if(!defined($keep_calibration_mode));
	 my $settings={
	  whiteBalanceMethod => "22",
	  whiteBalanceIre => $target->{"ire"},
	  whiteBalanceRed => $arrays->{"whiteBalanceRed"},
		  whiteBalanceGreen => $arrays->{"whiteBalanceGreen"},
		  whiteBalanceBlue => $arrays->{"whiteBalanceBlue"},
		 };
	 $settings->{"adjustingLuminance"}=$arrays->{"adjustingLuminance"} if(ref($arrays->{"adjustingLuminance"}) eq "ARRAY");
	 my $attempts=4;
	 my $last_message="LG white-balance write failed";
	 for(my $attempt=1;$attempt<=$attempts;$attempt++) {
			 my $response=lg_helper_picture_set($settings,$picture_mode || ($picture->{"pictureMode"}||""),$calibration_mode_active,$verify_ddc_upload,$keep_calibration_mode);
		 $response=api_json("POST","/api/lg/picture-settings/set",{
		  settings => $settings,
		  picture_mode => $picture_mode || ($picture->{"pictureMode"}||""),
			  keep_calibration_mode => $keep_calibration_mode ? JSON::PP::true : JSON::PP::false,
			  calibration_mode_active => $calibration_mode_active ? JSON::PP::true : JSON::PP::false,
			  verify_ddc_upload => $verify_ddc_upload ? JSON::PP::true : JSON::PP::false,
			  force_ddc_white_balance => JSON::PP::true,
			  readback_keys => ["pictureMode","whiteBalanceMethod","whiteBalanceIre","whiteBalanceRed","whiteBalanceGreen","whiteBalanceBlue","adjustingLuminance"],
			 },170) if(ref($response) ne "HASH");
		 if(ref($response) eq "HASH" && ($response->{"status"}||"") eq "ok") {
	  my $pic=$response->{"picture_settings"};
		  if(ref($pic) eq "HASH") {
		   $arrays->{"whiteBalanceRed"}=numeric_array($pic->{"whiteBalanceRed"},ddc_slot_count());
		   $arrays->{"whiteBalanceGreen"}=numeric_array($pic->{"whiteBalanceGreen"},ddc_slot_count());
		   $arrays->{"whiteBalanceBlue"}=numeric_array($pic->{"whiteBalanceBlue"},ddc_slot_count());
		   $arrays->{"adjustingLuminance"}=numeric_array($pic->{"adjustingLuminance"},ddc_slot_count());
		   return ($pic,undef);
		  }
	  my $next_picture=clone_picture($picture);
	  $next_picture->{"pictureMode"}=$picture_mode if(defined($picture_mode) && $picture_mode ne "");
	  $next_picture->{"whiteBalanceMethod"}=$settings->{"whiteBalanceMethod"};
	  $next_picture->{"whiteBalanceIre"}=$settings->{"whiteBalanceIre"};
		  $next_picture->{"whiteBalanceRed"}=numeric_array($arrays->{"whiteBalanceRed"},ddc_slot_count());
		  $next_picture->{"whiteBalanceGreen"}=numeric_array($arrays->{"whiteBalanceGreen"},ddc_slot_count());
		  $next_picture->{"whiteBalanceBlue"}=numeric_array($arrays->{"whiteBalanceBlue"},ddc_slot_count());
		  $next_picture->{"adjustingLuminance"}=numeric_array($arrays->{"adjustingLuminance"},ddc_slot_count());
		  return ($next_picture,undef);
	 }
	 $last_message=(ref($response) eq "HASH") ? ($response->{"message"}||"LG white-balance write failed") : "LG white-balance write failed";
	 last if(cancelled() || $attempt >= $attempts || !lg_write_error_is_transient($last_message));
	 if(ref($state) eq "HASH") {
	  $state->{"phase"}="writing";
	  $state->{"message"}="LG TV connection missed; retrying write ".($attempt+1)."/$attempts";
	  write_state($state);
	 }
	 select(undef,undef,undef,0.65*$attempt);
	}
	 return ($picture,$last_message);
}

sub commit_final_1d_lut {
	 my ($state,$picture,$arrays,$picture_mode,$ordered,$calibration_mode_active)=@_;
	 return ($picture,undef,0) if(!$calibration_mode_active);
 my $target=undef;
 if(ref($ordered) eq "ARRAY") {
  foreach my $step (@{$ordered}) {
   $target=ddc_target_for_step($step);
   last if($target);
  }
 }
	 return ($picture,undef,0) if(ref($target) ne "HASH");
 $state->{"current_name"}="Auto Cal commit";
 $state->{"phase"}="writing";
 $state->{"message"}="Uploading final 1024-point LG 1D LUT";
 write_state($state);
		 my ($next_picture,$error)=set_picture_values($picture,$arrays,$target,$picture_mode,1,$state,1,0);
		 return ($picture,$error,0) if($error);
		 sync_state_picture($state,$next_picture,$picture_mode);
		 $state->{"message"}="Final 1D LUT uploaded, verified, and calibration mode ended";
	 write_state($state);
	 return ($next_picture,undef,1);
}

sub park_black_for_settle {
 my ($config,$state,$message,$override_ms)=@_;
 $message||="Settling display on black before committed-state verification";
 if(ref($state) eq "HASH") {
  $state->{"current_name"}="Committed state settle";
  $state->{"phase"}="settling";
  $state->{"message"}=$message;
  write_state($state);
 }
 my $pattern_range=(ref($config) eq "HASH" ? ($config->{"pattern_signal_range"}||$config->{"signal_range"}||"") : "");
 my $transport_range=(ref($config) eq "HASH" ? ($config->{"transport_signal_range"}||$config->{"signal_range"}||"") : "");
 my $payload={
  name => "patch",
  r => 0,
  g => 0,
  b => 0,
  size => 100,
  input_max => 255,
  signal_mode => (ref($config) eq "HASH" ? ($config->{"signal_mode"}||"sdr") : "sdr"),
  max_luma => (ref($config) eq "HASH" ? ($config->{"max_luma"}||1000) : 1000),
 };
 $payload->{"signal_range"}=$pattern_range if($pattern_range ne "");
 $payload->{"transport_signal_range"}=$transport_range if($transport_range ne "");
 api_json("POST","/api/pattern",$payload,10);
 my $settle_ms=defined($override_ms) ? int($override_ms) : ((ref($config) eq "HASH" && defined($config->{"post_commit_settle_ms"})) ? int($config->{"post_commit_settle_ms"}) : 25000);
 $settle_ms=0 if($settle_ms < 0);
 $settle_ms=60000 if($settle_ms > 60000);
 select(undef,undef,undef,$settle_ms/1000) if($settle_ms > 0);
}

sub committed_state_polish {
 my ($config,$state,$picture,$arrays,$picture_mode,$steps,$target_x,$target_y,$target_gamma,$signal_mode,$target_delta)=@_;
 return ($picture,undef);
 return ($picture,undef) if(ref($config) ne "HASH" || !$config->{"lg_autocal_26"});
 return ($picture,undef) if(exists($config->{"post_commit_polish"}) && !$config->{"post_commit_polish"});
 return ($picture,undef) if(ref($steps) ne "ARRAY" || ref($arrays) ne "HASH");
 my ($white_step)=grep { ref($_) eq "HASH" && $_->{"autocal_white_reference"} } @{$steps};
 return ($picture,undef) if(!$white_step);
 park_black_for_settle($config,$state);
 my $white_reading=undef;
 my $white_y=undef;
 my $previous_white_y=undef;
 my $white_resettle_ms=(ref($config) eq "HASH" && defined($config->{"post_commit_white_resettle_ms"})) ? int($config->{"post_commit_white_resettle_ms"}) : 30000;
 $white_resettle_ms=0 if($white_resettle_ms < 0);
 $white_resettle_ms=60000 if($white_resettle_ms > 60000);
 for(my $white_attempt=1;$white_attempt<=3;$white_attempt++) {
  $state->{"current_name"}="Committed state check";
  $state->{"phase"}="reading";
  $state->{"message"}="Reading committed 100% white reference".($white_attempt>1 ? " ($white_attempt/3)" : "");
  write_state($state);
  my ($candidate_white,$white_error)=read_step($config,clone_picture($white_step),$state);
  return ($picture,$white_error) if($white_error && $white_error ne "cancelled");
  last if($white_error && $white_error eq "cancelled");
  last if(ref($candidate_white) ne "HASH");
  my $candidate_y=luminance($candidate_white);
  if(defined($candidate_y) && $candidate_y > 0 && (!defined($white_y) || $candidate_y > $white_y)) {
   $white_y=$candidate_y;
   $white_reading=$candidate_white;
  }
  if(defined($candidate_y) && defined($previous_white_y) && $candidate_y > 0) {
   my $delta=abs($candidate_y-$previous_white_y)/$candidate_y;
   last if($delta < 0.006);
  }
  $previous_white_y=$candidate_y if(defined($candidate_y));
  park_black_for_settle($config,$state,"Settling display on black before another white reference read",$white_resettle_ms) if($white_attempt < 3);
 }
 return ($picture,undef) if(!defined($white_y) || $white_y <= 0);
 annotate_reading_target($white_reading,$white_y,$white_y,$target_x,$target_y);
 $state->{"readings"}=merge_reading($state->{"readings"},$white_reading);
 set_state_white_reference($state,$white_y);
 refresh_headroom_targets_from_white_reference($state,$white_y,$target_x,$target_y,$target_gamma,$signal_mode);
 $state->{"message"}="Committed white reference read complete";
 write_state($state);

 my @polish_candidates=grep {
  ref($_) eq "HASH" &&
  defined($_->{"ire"}) &&
  ($_->{"ire"}+0) > 10 &&
  ddc_target_for_step($_)
 } @{$steps};
 my @headroom=sort { ($b->{"ire"}||0) <=> ($a->{"ire"}||0) } grep { ($_->{"ire"}+0) >= 99 } @polish_candidates;
 my @body=sort { ($a->{"ire"}||0) <=> ($b->{"ire"}||0) } grep { ($_->{"ire"}+0) < 99 } @polish_candidates;
 my @polish=(@headroom,@body,@body);
 my $limit=defined($config->{"post_commit_polish_iterations"}) ? int($config->{"post_commit_polish_iterations"}) : 8;
 $limit=1 if($limit < 1);
 $limit=12 if($limit > 12);
 my $white_refreshed_after_headroom=0;
 foreach my $step (@polish) {
  last if(cancelled());
  my $target=ddc_target_for_step($step);
  next if(!$target);
  my $read_step=fixed_lg_autocal_step($config,$step);
  my $label=$target->{"label"};
  $state->{"current_name"}="Committed polish $label";
  $state->{"phase"}="reading";
  $state->{"message"}="Reading committed $label";
  $state->{"active_stimulus"}=$read_step->{"stimulus"}+0 if(defined($read_step->{"stimulus"}));
  write_state($state);
  my ($reading,$read_error)=read_step($config,$read_step,$state);
  return ($picture,$read_error) if($read_error && $read_error ne "cancelled");
  last if($read_error && $read_error eq "cancelled");
  next if(ref($reading) ne "HASH");
  my $target_step_y=effective_target_luminance_for_autocal_reading($white_y,$read_step,$reading,$target_gamma,$signal_mode);
  annotate_reading_target($reading,$white_y,$target_step_y,$target_x,$target_y);
  my $de=autocal_delta_e_for_step($reading,$white_y,$target_x,$target_y,$target_step_y,$read_step);
  my $lum_pct=luminance_error_percent($reading,$target_step_y);
  $state->{"readings"}=merge_reading($state->{"readings"},$reading);
  $state->{"current_delta_e"}=defined($de) ? $de : undef;
  $state->{"current_luminance"}=luminance($reading);
  set_state_target_step_luminance($state,$target_step_y);
  $state->{"luminance_error_pct"}=defined($lum_pct) ? $lum_pct : undef;
  write_state($state);
  next if(target_reached($de,$lum_pct,$target_delta,$read_step));

  my $best_score=autocal_result_score($de,$lum_pct,$read_step);
  my $best_arrays=clone_arrays($arrays);
  my $best_reading=clone_picture($reading);
  my %tried_values;
  mark_tried_values(\%tried_values,$arrays,$target,$de);
  my $stalls=0;
  for(my $iter=1;$iter<=$limit;$iter++) {
   last if(cancelled());
   my $err=autocal_adjustment_error($reading,$read_step);
   my $lum_err=luminance_error_ratio($reading,$target_step_y);
   my $adjustments=choose_adjustments($err,$arrays,$target,$de,0.25,$stalls,$lum_err,\%tried_values,$read_step);
   last if(!$adjustments);
   foreach my $adj (@{$adjustments}) {
    $arrays->{$adj->{"setting"}}[$target->{"index"}]=$adj->{"next"};
   }
   $state->{"phase"}="writing";
   $state->{"message"}="Committed polish $label ".describe_adjustments($adjustments)." ($iter/$limit)";
   write_state($state);
   my $write_error;
   ($picture,$write_error)=set_picture_values($picture,$arrays,$target,$picture_mode,0,$state,1,0);
   return ($picture,$write_error) if($write_error);
   sync_state_picture($state,$picture,$picture_mode);
   $state->{"phase"}="reading";
   $state->{"message"}="Reading committed $label polish ($iter/$limit)";
   write_state($state);
   ($reading,$read_error)=read_step($config,$read_step,$state);
   return ($picture,$read_error) if($read_error && $read_error ne "cancelled");
   last if($read_error && $read_error eq "cancelled");
   last if(ref($reading) ne "HASH");
   $target_step_y=effective_target_luminance_for_autocal_reading($white_y,$read_step,$reading,$target_gamma,$signal_mode);
   annotate_reading_target($reading,$white_y,$target_step_y,$target_x,$target_y);
   $de=autocal_delta_e_for_step($reading,$white_y,$target_x,$target_y,$target_step_y,$read_step);
   $lum_pct=luminance_error_percent($reading,$target_step_y);
   mark_tried_values(\%tried_values,$arrays,$target,$de);
   $state->{"readings"}=merge_reading($state->{"readings"},$reading);
   $state->{"current_delta_e"}=defined($de) ? $de : undef;
   $state->{"current_luminance"}=luminance($reading);
   set_state_target_step_luminance($state,$target_step_y);
   $state->{"luminance_error_pct"}=defined($lum_pct) ? $lum_pct : undef;
   my $score=autocal_result_score($de,$lum_pct,$read_step);
   if($score + 0.0001 < $best_score) {
    $best_score=$score;
    $best_arrays=clone_arrays($arrays);
    $best_reading=clone_picture($reading);
    $stalls=0;
   } else {
    $stalls++;
    $arrays=clone_arrays($best_arrays);
    $state->{"phase"}="writing";
    $state->{"message"}="Restoring committed $label polish";
    write_state($state);
    ($picture,$write_error)=set_picture_values($picture,$arrays,$target,$picture_mode,0,$state,1,0);
    return ($picture,$write_error) if($write_error);
    sync_state_picture($state,$picture,$picture_mode);
    $reading=clone_picture($best_reading);
    last if($stalls >= 2);
   }
   write_state($state);
   last if(target_reached($de,$lum_pct,$target_delta,$read_step));
  }
  if(
   !$white_refreshed_after_headroom &&
   defined($step->{"ire"}) &&
   abs(($step->{"ire"}+0)-99) < 0.001
  ) {
   $white_refreshed_after_headroom=1;
   $state->{"current_name"}="Committed state check";
   $state->{"phase"}="reading";
   $state->{"message"}="Refreshing committed 100% white after top-end polish";
   write_state($state);
   my ($candidate_white,$white_error)=read_step($config,clone_picture($white_step),$state);
   return ($picture,$white_error) if($white_error && $white_error ne "cancelled");
   last if($white_error && $white_error eq "cancelled");
   if(ref($candidate_white) eq "HASH") {
    my $candidate_y=luminance($candidate_white);
    if(defined($candidate_y) && $candidate_y > 0) {
     $white_y=$candidate_y;
     annotate_reading_target($candidate_white,$white_y,$white_y,$target_x,$target_y);
     $state->{"readings"}=merge_reading($state->{"readings"},$candidate_white);
     $state->{"current_luminance"}=$candidate_y;
     set_state_white_reference($state,$white_y);
     refresh_headroom_targets_from_white_reference($state,$white_y,$target_x,$target_y,$target_gamma,$signal_mode);
     set_state_target_step_luminance($state,$white_y);
     $state->{"message"}="Committed white reference refreshed";
     write_state($state);
    }
   }
  }
 }
 return ($picture,undef);
}

sub end_calibration_mode {
 my ($picture_mode)=@_;
 my $result=api_json("POST","/api/lg/calibration-mode",{
  enabled => JSON::PP::false,
  picture_mode => $picture_mode||"",
 },90);
 log_line("CAL_END cleanup: ".($result->{"message"}||$result->{"status"}||"done"));
 return $result;
}

sub read_step {
	 my ($config,$step,$state_ref)=@_;
	 my $attempts=defined($config->{"read_attempts"}) ? int($config->{"read_attempts"}) : 5;
 $attempts=1 if($attempts < 1);
 $attempts=5 if($attempts > 5);
 my $last_error="";
	 for(my $attempt=1;$attempt<=$attempts;$attempt++) {
	  my ($reading,$error)=read_step_once($config,$step,$attempt);
	  if(!$error) {
	   delete $state_ref->{"meter_read_retry"} if(ref($state_ref) eq "HASH");
	   return ($reading,undef);
	  }
  $last_error=$error;
  return (undef,$error) if($error eq "cancelled");
  last if(!transient_read_error($error) || $attempt >= $attempts);
  if(ref($state_ref) eq "HASH") {
   $state_ref->{"message"}="Meter read timed out; retrying ".($step->{"name"}||"patch")." ($attempt/$attempts)";
   $state_ref->{"meter_read_retry"}=$attempt;
   write_state($state_ref);
  }
  reset_meter_session_after_read_error($error);
  select(undef,undef,undef,1.0+$attempt);
 }
 return (undef,"Meter read failed after retry: ".($last_error||"unknown meter read error"));
}

sub implausible_autocal_read {
 my ($reading,$target_luminance,$step)=@_;
 return "" if(ref($reading) ne "HASH" || ref($step) ne "HASH");
 return "" if(!defined($target_luminance) || $target_luminance <= 1);
 my $ire=defined($step->{"ire"}) ? ($step->{"ire"}+0) : 100;
 return "" if($ire < 15);
 my $Y=luminance($reading);
 return "" if(!defined($Y) || $Y < 0);
 my $ratio=$Y/$target_luminance;
 return "" if($ratio >= 0.35 && $ratio <= 2.20);
 return ($step->{"name"}||format_percent($ire)."%")." meter read is implausible: ".sprintf("%.2f",$Y)." cd/m2 for ".sprintf("%.2f",$target_luminance)." cd/m2 target";
}

sub read_step_guarded {
 my ($config,$step,$state_ref,$white_y,$target_gamma,$signal_mode,$target_x,$target_y,$label)=@_;
 my $last_error="";
 for(my $attempt=1;$attempt<=3;$attempt++) {
  my ($reading,$error)=read_step($config,$step,$state_ref);
  return ($reading,$error,undef) if($error);
  my $target_step_y=target_luminance_for_autocal_step($white_y,$step,$target_gamma,$signal_mode);
  annotate_reading_target($reading,$white_y,$target_step_y,$target_x,$target_y);
  my $bad=implausible_autocal_read($reading,$target_step_y,$step);
  return ($reading,undef,$target_step_y) if($bad eq "");
  $last_error=$bad;
  log_line("Rejecting implausible Auto Cal read: $bad");
  if(ref($state_ref) eq "HASH") {
   $state_ref->{"message"}="Retrying ".($label||$step->{"name"}||"patch")." after implausible meter read ($attempt/3)";
   $state_ref->{"implausible_read_retry"}=$attempt;
   write_state($state_ref);
  }
  api_json("POST","/api/pattern",patch_payload_for_step($config,$step),10);
  select(undef,undef,undef,1.2+$attempt);
 }
 delete $state_ref->{"implausible_read_retry"} if(ref($state_ref) eq "HASH");
 return (undef,$last_error||"Implausible meter read rejected",undef);
}

sub read_initial_picture_settings {
 my ($config,$state)=@_;
 my $keys=["pictureMode","whiteBalanceMethod","whiteBalanceIre","whiteBalanceRed","whiteBalanceGreen","whiteBalanceBlue","adjustingLuminance"];
 my $picture_mode=(ref($config) eq "HASH") ? ($config->{"picture_mode"}||"") : "";
 my $last_message="Unable to read LG white-balance settings";
 my $attempts=3;
 for(my $attempt=1;$attempt<=$attempts;$attempt++) {
  if(ref($state) eq "HASH") {
   $state->{"phase"}="preparing";
   $state->{"message"}="Reading LG picture settings ($attempt/$attempts)";
   write_state($state);
  }
  my $picture_response=api_json("POST","/api/lg/picture-settings",{
	   keys=>$keys,
	   picture_mode=>$picture_mode,
	   force_ddc_white_balance=>JSON::PP::true,
	   helper_timeout=>90,
	  },95);
  if(ref($picture_response) eq "HASH" && ($picture_response->{"status"}||"") eq "ok" && ref($picture_response->{"picture_settings"}) eq "HASH") {
   return $picture_response;
  }
  $last_message=(ref($picture_response) eq "HASH") ? ($picture_response->{"message"}||$last_message) : $last_message;
  log_line("LG picture-settings read failed on attempt $attempt/$attempts: $last_message");
  if($last_message =~ /Web UI API timed out|timed?\s*out|timeout|connection|connect|closed|broken pipe|reset by peer/i) {
   if(ref($state) eq "HASH") {
    $state->{"message"}="Retrying LG picture settings through direct helper ($attempt/$attempts)";
    write_state($state);
   }
   my $helper_response=lg_helper_picture_get($keys,$picture_mode);
   if(ref($helper_response) eq "HASH" && ($helper_response->{"status"}||"") eq "ok" && ref($helper_response->{"picture_settings"}) eq "HASH") {
    return $helper_response;
   }
   $last_message=(ref($helper_response) eq "HASH") ? ($helper_response->{"message"}||$last_message) : $last_message;
   log_line("Direct LG helper picture-settings fallback failed on attempt $attempt/$attempts: $last_message");
  } else {
   last;
  }
  last if(cancelled() || $attempt >= $attempts);
  sleep(1.5*$attempt);
 }
 return { status=>"error", message=>$last_message };
}

sub restore_factory_levels_for_autocal {
 my ($config,$state)=@_;
 return undef if(ref($config) ne "HASH" || exists($config->{"restore_factory_levels"}) && !$config->{"restore_factory_levels"});
 my $signal_mode=lc($config->{"signal_mode"}||"sdr");
 return undef if($signal_mode ne "" && $signal_mode ne "sdr");
 my $picture_mode=$config->{"picture_mode"}||"";
 my $contrast=defined($config->{"factory_contrast"}) ? int($config->{"factory_contrast"}) : 85;
 my $brightness=defined($config->{"factory_brightness"}) ? int($config->{"factory_brightness"}) : 50;
 $contrast=0 if($contrast < 0);
 $contrast=100 if($contrast > 100);
 $brightness=0 if($brightness < 0);
 $brightness=100 if($brightness > 100);
 my $last_message="Unable to restore LG factory brightness/contrast";
 for(my $attempt=1;$attempt<=3;$attempt++) {
  if(ref($state) eq "HASH") {
   $state->{"phase"}="preparing";
   $state->{"current_name"}="Restoring LG picture defaults";
   $state->{"message"}="Setting contrast $contrast and brightness $brightness".($attempt>1 ? " ($attempt/3)" : "");
   write_state($state);
  }
  my $response=api_json("POST","/api/lg/picture-settings/set",{
   settings => {
    contrast => $contrast,
    brightness => $brightness,
   },
   picture_mode => $picture_mode,
   helper_timeout => 90,
   readback_keys => ["pictureMode","contrast","brightness"],
  },120);
  if(ref($response) eq "HASH" && ($response->{"status"}||"") eq "ok") {
   my $pic=$response->{"picture_settings"};
   my $actual_contrast=(ref($pic) eq "HASH" && defined($pic->{"contrast"})) ? int($pic->{"contrast"}) : $contrast;
   my $actual_brightness=(ref($pic) eq "HASH" && defined($pic->{"brightness"})) ? int($pic->{"brightness"}) : $brightness;
   return undef if($actual_contrast == $contrast && $actual_brightness == $brightness);
   $last_message="LG reported contrast $actual_contrast and brightness $actual_brightness after factory-level restore";
  } else {
   $last_message=(ref($response) eq "HASH") ? ($response->{"message"}||$last_message) : $last_message;
  }
  log_line("LG factory brightness/contrast restore failed on attempt $attempt/3: $last_message");
  last if(cancelled() || $attempt >= 3);
  sleep(1.2*$attempt);
 }
 return $last_message;
}

sub reset_ddc_baseline_for_autocal {
 my ($config,$state)=@_;
 return undef if(ref($config) ne "HASH" || !$config->{"reset_ddc_baseline"});
	 my @zero=map { 0 } (1..ddc_slot_count());
 my $picture_mode=$config->{"picture_mode"}||"";
 my $last_message="Unable to reset LG DDC baseline";
 if(ref($state) eq "HASH") {
  $state->{"phase"}="preparing";
  $state->{"current_name"}="Resetting LG DDC";
  $state->{"message"}="Ending any active LG calibration session before reset";
  write_state($state);
 }
 my $end_result=end_calibration_mode($picture_mode);
 log_line("Pre-reset CAL_END result: ".((ref($end_result) eq "HASH") ? ($end_result->{"message"}||$end_result->{"status"}||"done") : "unknown"));
 for(my $attempt=1;$attempt<=3;$attempt++) {
  if(ref($state) eq "HASH") {
   $state->{"phase"}="preparing";
   $state->{"current_name"}="Resetting LG DDC";
   $state->{"message"}="Clearing LG 1D LUT baseline before Auto Cal".($attempt>1 ? " ($attempt/3)" : "");
   write_state($state);
  }
  my $response=api_json("POST","/api/lg/picture-settings/set",{
   settings => {
    whiteBalanceMethod => "22",
    whiteBalanceIre => "100",
    whiteBalanceRed => \@zero,
    whiteBalanceGreen => \@zero,
    whiteBalanceBlue => \@zero,
    adjustingLuminance => \@zero,
   },
   picture_mode => $picture_mode,
   reset_ddc_baseline => JSON::PP::true,
   force_ddc_white_balance => JSON::PP::true,
   helper_timeout => 170,
   readback_keys => ["pictureMode","whiteBalanceMethod","whiteBalanceIre","whiteBalanceRed","whiteBalanceGreen","whiteBalanceBlue","adjustingLuminance"],
  },190);
  if(ref($response) eq "HASH" && ($response->{"status"}||"") eq "ok") {
   return undef if($response->{"ddc_baseline_reset"} && $response->{"ddc_1d_lut"} && $response->{"ddc_reset_verified"});
   $last_message="LG DDC reset did not verify the 1D LUT baseline";
  } else {
   $last_message=(ref($response) eq "HASH") ? ($response->{"message"}||$last_message) : $last_message;
  }
  log_line("LG DDC reset failed on attempt $attempt/3: $last_message");
  last if(cancelled() || $attempt >= 3);
  sleep(1.4*$attempt);
 }
 return $last_message;
}

sub read_step_once {
		 my ($config,$step,$attempt)=@_;
		 my $pattern_range=$config->{"pattern_signal_range"}||$config->{"signal_range"}||"";
		 my $ire=defined($step->{"ire"}) ? ($step->{"ire"}+0) : 100;
		 my $delay_ms=int($config->{"delay_ms"}||500);
		 $delay_ms=1800 if($delay_ms < 1800);
		 $delay_ms=5000 if($ire <= 5 && $delay_ms < 5000);
		 $delay_ms=4200 if($ire > 5 && $ire <= 10 && $delay_ms < 4200);
		 $delay_ms=3200 if($ire > 10 && $ire <= 25 && $delay_ms < 3200);
		 $delay_ms=2400 if($ire > 25 && $ire <= 50 && $delay_ms < 2400);
	 my $request_id=read_request_id($step);
	 my $payload={
	  display_type => $config->{"display_type"}||"lcd",
	  patch_r => int($step->{"r"}||0),
	  patch_g => int($step->{"g"}||0),
	  patch_b => int($step->{"b"}||0),
	  ire => $step->{"ire"}+0,
	  stimulus => defined($step->{"stimulus"}) ? ($step->{"stimulus"}+0) : ($step->{"ire"}+0),
	  name => $step->{"name"}||($step->{"ire"}."%"),
	  signal_r_pct => defined($step->{"signal_r_pct"}) ? ($step->{"signal_r_pct"}+0) : ($step->{"ire"}+0),
	  signal_g_pct => defined($step->{"signal_g_pct"}) ? ($step->{"signal_g_pct"}+0) : ($step->{"ire"}+0),
	  signal_b_pct => defined($step->{"signal_b_pct"}) ? ($step->{"signal_b_pct"}+0) : ($step->{"ire"}+0),
			  patch_size => int($config->{"patch_size"}||10),
			  input_max => (defined($step->{"input_max"}) ? int($step->{"input_max"}) : 255),
		  delay_ms => $delay_ms,
		  signal_range => $pattern_range,
		  transport_signal_range => $config->{"transport_signal_range"}||$config->{"signal_range"}||"",
		  signal_mode => $config->{"signal_mode"}||"sdr",
		  target_gamma => $config->{"target_gamma"}||"bt1886",
		  target_gamut => $config->{"target_gamut"}||"auto",
		  max_luma => $config->{"max_luma"}||1000,
		  refresh_rate => $config->{"refresh_rate"}||"",
		  measurement_meter_port => $config->{"measurement_meter_port"}||"",
		  request_id => $request_id,
		  require_device_ready => $config->{"require_device_ready"} ? JSON::PP::true : JSON::PP::false,
		 };
		 my $read_started=time();
			 my $insert_error=apply_pattern_insert_before_read($config,$step);
			 return (undef,$insert_error) if(defined($insert_error) && $insert_error ne "");
			 $read_sequence++;
			 my $start_timeout=(ref($step) eq "HASH" && $step->{"autocal_probe_stimulus"}) ? 35 : 55;
			 $start_timeout=70 if($ire <= 5 && !(ref($step) eq "HASH" && $step->{"autocal_probe_stimulus"}));
			 my $start=api_json("POST","/api/meter/read",$payload,$start_timeout);
		 return (undef,$start->{"message"}||"Unable to start meter read") if(($start->{"status"}||"") eq "error");
		 my $deadline=time()+read_timeout_for_step($step);
		 while(time() < $deadline) {
		  return (undef,"cancelled") if(cancelled());
  my $result=api_json("GET","/api/meter/read/result",undef,10);
	  my $status=$result->{"status"}||"";
	  if($status eq "ok" && ref($result->{"readings"}) eq "ARRAY" && @{$result->{"readings"}}) {
	   my $result_request_id=$result->{"request_id"}||"";
	   if($result_request_id ne $request_id) {
	    log_line("Ignoring mismatched meter result for ".($step->{"name"}||"step")." request_id=$request_id result_request_id=$result_request_id");
	    sleep(0.25);
	    next;
	   }
	   my $reading=$result->{"readings"}[0];
	   my $reading_request_id=$reading->{"request_id"}||"";
	   if($reading_request_id ne "" && $reading_request_id ne $request_id) {
	    log_line("Ignoring mismatched meter reading for ".($step->{"name"}||"step")." request_id=$request_id reading_request_id=$reading_request_id");
	    sleep(0.25);
	    next;
	   }
	   my $timestamp=defined($reading->{"timestamp"}) ? ($reading->{"timestamp"}+0) : 0;
	   if($timestamp > 0 && ($timestamp+1) < $read_started) {
	    log_line("Ignoring stale meter result for ".($step->{"name"}||"step")." timestamp=$timestamp read_started=$read_started");
	    sleep(0.25);
	    next;
	   }
			   $reading->{"ire"}=$step->{"ire"} if(defined($step->{"ire"}));
			   $reading->{"nominal_ire"}=$step->{"ire"} if(defined($step->{"ire"}));
			   $reading->{"plot_ire"}=$step->{"ire"} if(defined($step->{"ire"}));
			   $reading->{"stimulus"}=$step->{"stimulus"} if(defined($step->{"stimulus"}));
			   $reading->{"patch_stimulus"}=$step->{"stimulus"} if(defined($step->{"stimulus"}));
			   $reading->{"patch_ire"}=$step->{"stimulus"} if(defined($step->{"stimulus"}));
			   if(defined($step->{"stimulus"}) && defined($step->{"ire"}) && abs(($step->{"stimulus"}+0)-($step->{"ire"}+0))>0.001) {
			    $reading->{"autocal_probe_stimulus"}=JSON::PP::true;
			   }
			   $reading->{"autocal_fixed_stimulus"}=JSON::PP::true if($step->{"autocal_fixed_stimulus"});
			   $reading->{"name"}=$step->{"name"} if(defined($step->{"name"}));
		   $reading->{"r_code"}=$step->{"r"};
		   $reading->{"g_code"}=$step->{"g"};
		   $reading->{"b_code"}=$step->{"b"};
		   $reading->{"signal_r_pct"}=$step->{"signal_r_pct"} if(defined($step->{"signal_r_pct"}));
		   $reading->{"signal_g_pct"}=$step->{"signal_g_pct"} if(defined($step->{"signal_g_pct"}));
		   $reading->{"signal_b_pct"}=$step->{"signal_b_pct"} if(defined($step->{"signal_b_pct"}));
	   $reading->{"read_delay_ms"}=$delay_ms;
	   $reading->{"display_type"}=$payload->{"display_type"};
	   return ($reading,undef);
	  }
  return (undef,$result->{"message"}||"Meter read failed") if($status eq "error");
  sleep(0.35);
 }
	 return (undef,"Meter read timed out");
}

my $config=decode_json_safe(read_file($config_file),{});
my $steps=(ref($config->{"steps"}) eq "ARRAY") ? $config->{"steps"} : [];
unlink($trace_109_file) if(ref($config) eq "HASH" && $config->{"lg_autocal_26"});
my $target_delta=defined($config->{"target_delta_e"}) ? ($config->{"target_delta_e"}+0) : 0.5;
$target_delta=0.1 if($target_delta < 0.1);
my $target_luminance=defined($config->{"target_luminance"}) ? ($config->{"target_luminance"}+0) : 0;
$target_luminance=0 if($target_luminance < 1);
my $setup_luminance_reference=defined($config->{"setup_luminance_reference"}) ? ($config->{"setup_luminance_reference"}+0) : 0;
$setup_luminance_reference=0 if($setup_luminance_reference < 1);
my $headroom_target_luminance=defined($config->{"headroom_target_luminance"}) ? ($config->{"headroom_target_luminance"}+0) : 0;
$headroom_target_luminance=0 if($headroom_target_luminance < 1);
$LG_AUTOCAL_SETUP_LUMINANCE=$setup_luminance_reference;
$LG_AUTOCAL_HEADROOM_TARGET_LUMINANCE=$headroom_target_luminance;
my $target_gamma=lc($config->{"target_gamma"}||"bt1886");
$target_gamma="bt1886" unless($target_gamma eq "bt1886" || $target_gamma eq "2.2" || $target_gamma eq "2.4" || $target_gamma eq "srgb" || $target_gamma eq "st2084");
my $signal_mode=lc($config->{"signal_mode"}||"sdr");
my $max_iterations=defined($config->{"max_iterations"}) ? int($config->{"max_iterations"}) : 80;
$max_iterations=20 if($max_iterations < 20);
my ($target_x,$target_y)=(0.3127,0.3290);
if(ref($config->{"target_white"}) eq "HASH" && ($config->{"target_white"}{"x"}||0)>0 && ($config->{"target_white"}{"y"}||0)>0) {
 ($target_x,$target_y)=($config->{"target_white"}{"x"}+0,$config->{"target_white"}{"y"}+0);
}

unlink($stop_file);
my $state={
 status=>"running",
 current_step=>0,
 total_steps=>scalar(@{$steps}),
 current_name=>"Preparing LG Auto Cal...",
 readings=>[],
 steps=>$steps,
	 target_delta_e=>$target_delta,
		 target_luminance=>$target_luminance||undef,
		 setup_luminance_reference=>$setup_luminance_reference||$target_luminance||undef,
		 headroom_target_luminance=>$headroom_target_luminance||undef,
		 target_gamma=>$target_gamma,
		 display_type=>$config->{"display_type"}||"lcd",
		 configured_delay_ms=>int($config->{"delay_ms"}||500),
		 message=>"Starting",
		};
write_state($state);
my $calibration_mode_active=0;
my $active_picture_mode_for_cleanup="";

eval {
 die "No greyscale steps were supplied" if(!@{$steps});
 my $level_restore_error=restore_factory_levels_for_autocal($config,$state);
 die $level_restore_error if($level_restore_error);
 my $reset_error=reset_ddc_baseline_for_autocal($config,$state);
 die $reset_error if($reset_error);
 my $picture_response=read_initial_picture_settings($config,$state);
 die ($picture_response->{"message"}||"Unable to read LG white-balance settings")
  if(($picture_response->{"status"}||"") ne "ok" || ref($picture_response->{"picture_settings"}) ne "HASH");
 my $picture=$picture_response->{"picture_settings"};
 my $picture_mode=$config->{"picture_mode"}||$picture->{"pictureMode"}||"";
 $active_picture_mode_for_cleanup=$picture_mode;
	 my $arrays={
		  whiteBalanceRed => numeric_array($picture->{"whiteBalanceRed"},ddc_slot_count()),
		  whiteBalanceGreen => numeric_array($picture->{"whiteBalanceGreen"},ddc_slot_count()),
		  whiteBalanceBlue => numeric_array($picture->{"whiteBalanceBlue"},ddc_slot_count()),
		  adjustingLuminance => numeric_array($picture->{"adjustingLuminance"},ddc_slot_count()),
		 };
	 sync_state_picture($state,$picture,$picture_mode);
	 write_state($state);
		 my @ordered=order_autocal_steps($steps,$config);
	 die "No adjustable LG greyscale steps were supplied" if(!@ordered);
		 my @verification=verification_autocal_steps($steps);
		 my ($black_step)=grep { ref($_) eq "HASH" && defined($_->{"ire"}) && abs(($_->{"ire"}+0)) < 0.001 } @{$steps};
		 my ($white_reference_step)=grep { ref($_) eq "HASH" && $_->{"autocal_white_reference"} } @{$steps};
		 my $white_reference_is_adjustable=($white_reference_step && ddc_target_for_step($white_reference_step)) ? 1 : 0;
		 my $refresh_white_after_headroom=($white_reference_step && !$white_reference_is_adjustable && ref($config) eq "HASH" && $config->{"lg_autocal_26"}) ? 1 : 0;
		 my $total_ordered_steps=scalar(@ordered)+scalar(@verification)+($black_step ? 1 : 0);

		 my $white_y=($target_luminance > 0) ? $target_luminance : undef;
		 set_state_white_reference($state,$white_y) if(defined($white_y) && $white_y > 0);
		 my $apply_measured_white_reference=sub {
		  my ($read_step)=@_;
		  return 0 if(!autocal_step_is_white($read_step));
		  return 0 if(!defined($white_y) || $white_y <= 0);
		  $target_luminance=$white_y;
		  set_state_white_reference($state,$white_y);
		  refresh_headroom_targets_from_white_reference($state,$white_y,$target_x,$target_y,$target_gamma,$signal_mode)
		   if(ref($config) eq "HASH" && $config->{"lg_autocal_26"});
		  return 1;
		 };
		 my $step_num=0;
		 my $read_reference_step=sub {
		  my ($ref_step,$label,$message)=@_;
		  return undef if(ref($ref_step) ne "HASH");
		  $step_num++;
		  my $read_step=clone_picture($ref_step);
		  $state->{"current_step"}=$step_num;
		  $state->{"total_steps"}=$total_ordered_steps;
		  $state->{"current_name"}=$label;
		  $state->{"phase"}="reading";
		  $state->{"message"}=$message;
		  $state->{"active_stimulus"}=$read_step->{"stimulus"}+0 if(defined($read_step->{"stimulus"}));
		  write_state($state);
		  my ($ref_reading,$ref_error)=read_step($config,$read_step,$state);
		  die $ref_error if($ref_error && $ref_error ne "cancelled");
		  return undef if($ref_error && $ref_error eq "cancelled");
		  return undef if(ref($ref_reading) ne "HASH");
		  $white_y=update_white_reference_for_step($read_step,$ref_reading,$white_y);
		  $white_y ||= 100;
		  my $target_lum_y=target_luminance_for_step($white_y,$read_step,$target_gamma,$signal_mode);
		  annotate_reading_target($ref_reading,$white_y,$target_lum_y,$target_x,$target_y);
		  $state->{"readings"}=merge_reading($state->{"readings"},$ref_reading);
		  $state->{"current_luminance"}=luminance($ref_reading);
		  $state->{"current_delta_e"}=undef;
		  $apply_measured_white_reference->($read_step);
		  set_state_target_step_luminance($state,$target_lum_y);
		  write_state($state);
		  return $ref_reading;
		 };
		 my $paired_white_reference_for_step=sub {
		  my ($candidate)=@_;
		  return undef if(ref($config) ne "HASH" || !$config->{"lg_autocal_26"});
		  return undef if(ref($candidate) ne "HASH" || autocal_step_is_white($candidate));
		  return undef if(ref($white_reference_step) ne "HASH");
		  return undef if(!steps_share_ddc_target($candidate,$white_reference_step));
		  return clone_picture($white_reference_step);
		 };
		 my $white_refreshed_after_headroom=0;
	 foreach my $step (@ordered) {
	  last if(cancelled());
	  $step_num++;
		  my $target=ddc_target_for_step($step);
		  next if(!$target);
		  my $mismatch=ddc_step_signal_mismatch($step,$config);
		  die $mismatch if($mismatch ne "");
			  my $label=$target->{"label"};
			  my $read_step=fixed_lg_autocal_step($config,$step);
			  my $paired_white_step=$paired_white_reference_for_step->($step);
			  my $paired_label=$paired_white_step ? "$label / 100%" : $label;
			  trace_109($read_step,"start_step",{
			   label=>$label,
			   target=>$target,
			   target_values=>trace_target_values($arrays,$target)
			  });
			  if(ref($config) eq "HASH" && $config->{"lg_autocal_26"} && seed_target_from_prior_slot($arrays,$target)) {
			   trace_109($read_step,"seed_from_prior_slot",{
			    label=>$label,
			    target_values=>trace_target_values($arrays,$target)
			   });
			   $state->{"current_step"}=$step_num;
		   $state->{"total_steps"}=$total_ordered_steps;
		   $state->{"current_name"}="Auto Cal $paired_label";
		   $state->{"phase"}="writing";
		   $state->{"message"}="Seeding $label from nearest calibrated point";
		   write_state($state);
		   my $seed_error;
		   ($picture,$seed_error)=set_picture_values($picture,$arrays,$target,$picture_mode,$calibration_mode_active,$state);
		   die $seed_error if($seed_error);
		   $calibration_mode_active=1;
		   sync_state_picture($state,$picture,$picture_mode);
		  }
		  my %stimulus_probe_tried;
		  mark_stimulus_probe_tried(\%stimulus_probe_tried,$read_step);
		  $state->{"current_step"}=$step_num;
			  $state->{"total_steps"}=$total_ordered_steps;
		  $state->{"current_name"}="Auto Cal $paired_label";
  $state->{"phase"}="reading";
  $state->{"message"}="Reading $label";
  $state->{"active_stimulus"}=$read_step->{"stimulus"}+0 if(defined($read_step->{"stimulus"}));
  write_state($state);

		  my ($reading,$read_error,$guarded_target_step_y)=read_step_guarded($config,$read_step,$state,$white_y,$target_gamma,$signal_mode,$target_x,$target_y,$label);
	  die $read_error if($read_error && $read_error ne "cancelled");
	  last if($read_error && $read_error eq "cancelled");
	  next if(ref($reading) ne "HASH");
		  my $white_guard_y=autocal_step_is_white($read_step) ? luminance($reading) : undef;
		  if(defined($white_guard_y) && $white_guard_y > 0) {
		   $state->{"white_luminance_floor"}=$white_guard_y*white_luminance_floor_ratio();
		  } else {
		   delete $state->{"white_luminance_floor"};
		  }
	  $white_y=update_white_reference_for_step($read_step,$reading,$white_y);
	  $apply_measured_white_reference->($read_step);
	  $white_y ||= 100;
		  my $target_step_y=defined($guarded_target_step_y) ? $guarded_target_step_y : effective_target_luminance_for_autocal_reading($white_y,$read_step,$reading,$target_gamma,$signal_mode);
	  annotate_reading_target($reading,$white_y,$target_step_y,$target_x,$target_y);
	  my $de=autocal_delta_e_for_step($reading,$white_y,$target_x,$target_y,$target_step_y,$read_step);
		  my $best_de=defined($de) ? $de : 9999;
			  my $best_lum_pct=undef;
			  my $best_arrays=decode_json_safe($json->encode($arrays),{});
			  my $best_reading=clone_picture($reading);
			  my $slot_default_arrays=clone_arrays($arrays);
	  $state->{"readings"}=merge_reading($state->{"readings"},$reading);
	  $state->{"current_delta_e"}=defined($de) ? $de : undef;
	  $state->{"best_delta_e"}=$best_de;
	  $state->{"current_luminance"}=luminance($reading);
	  set_state_target_step_luminance($state,$target_step_y);
			  my $lum_pct=luminance_error_percent($reading,$target_step_y);
			  $best_lum_pct=$lum_pct;
			  my $best_score=guarded_autocal_result_score($best_de,$best_lum_pct,$read_step,$best_reading,$white_guard_y);
				  $state->{"luminance_error_pct"}=defined($lum_pct) ? $lum_pct : undef;
				  $state->{"best_score"}=$best_score;
			  my ($paired_pending_reading,$paired_pending_step,$paired_pending_de,$paired_pending_lum_pct,$paired_pending_target_y);
			  my ($paired_best_arrays,$paired_best_reading,$paired_best_de,$paired_best_lum_pct,$paired_best_score);
			  my ($paired_best_pair_reading,$paired_best_pair_step,$paired_best_pair_de,$paired_best_pair_lum_pct,$paired_best_pair_target_y,$paired_best_pair_score);
			  my $read_paired_white_validation=sub {
			   my ($reason)=@_;
			   return 1 if(ref($paired_white_step) ne "HASH");
			   my $pair_step=fixed_lg_autocal_step($config,clone_picture($paired_white_step));
			   $state->{"current_step"}=$step_num;
			   $state->{"total_steps"}=$total_ordered_steps;
			   $state->{"current_name"}="Auto Cal $paired_label";
			   $state->{"phase"}="reading";
			   $state->{"message"}=$reason||"Validating 100% legal white with $label";
			   $state->{"active_stimulus"}=$pair_step->{"stimulus"}+0 if(defined($pair_step->{"stimulus"}));
			   write_state($state);
			   my ($pair_reading,$pair_error)=read_step($config,$pair_step,$state);
			   die $pair_error if($pair_error && $pair_error ne "cancelled");
			   return 0 if($pair_error && $pair_error eq "cancelled");
			   return 1 if(ref($pair_reading) ne "HASH");
			   $white_y=update_white_reference_for_step($pair_step,$pair_reading,$white_y);
			   $white_y ||= 100;
			   $apply_measured_white_reference->($pair_step);
			   my $pair_target_y=target_luminance_for_step($white_y,$pair_step,$target_gamma,$signal_mode);
			   annotate_reading_target($pair_reading,$white_y,$pair_target_y,$target_x,$target_y);
			   my $pair_de=autocal_delta_e_for_step($pair_reading,$white_y,$target_x,$target_y,$pair_target_y,$pair_step);
			   my $pair_lum_pct=luminance_error_percent($pair_reading,$pair_target_y);
			   my $pair_score=guarded_autocal_result_score($pair_de,$pair_lum_pct,$pair_step,$pair_reading,undef);
			   my $primary_target_y=effective_target_luminance_for_autocal_reading($white_y,$read_step,$reading,$target_gamma,$signal_mode);
			   annotate_reading_target($reading,$white_y,$primary_target_y,$target_x,$target_y);
			   my $primary_de=autocal_delta_e_for_step($reading,$white_y,$target_x,$target_y,$primary_target_y,$read_step);
			   my $primary_lum_pct=luminance_error_percent($reading,$primary_target_y);
			   my $primary_score=guarded_autocal_result_score($primary_de,$primary_lum_pct,$read_step,$reading,$white_guard_y);
			   my $pair_combined_score=$primary_score > $pair_score ? $primary_score : $pair_score;
			   $state->{"readings"}=merge_reading($state->{"readings"},$pair_reading);
			   $state->{"current_delta_e"}=defined($pair_de) ? $pair_de : undef;
			   $state->{"current_luminance"}=luminance($pair_reading);
			   $state->{"luminance_error_pct"}=defined($pair_lum_pct) ? $pair_lum_pct : undef;
			   $state->{"paired_white_delta_e"}=defined($pair_de) ? $pair_de : undef;
			   $state->{"paired_white_score"}=$pair_score;
			   set_state_target_step_luminance($state,$pair_target_y);
			   trace_109($read_step,"paired_white_validation",{
			    label=>$label,
			    paired_label=>"100%",
			    reason=>$reason||"",
			    reading=>trace_reading_summary($pair_reading),
			    target_luminance=>$pair_target_y,
			    white_y=>$white_y,
			    delta_e=>defined($pair_de)?$pair_de+0:undef,
			    luminance_error_pct=>defined($pair_lum_pct)?$pair_lum_pct+0:undef,
			    score=>$pair_score+0,
			    primary_delta_e=>defined($primary_de)?$primary_de+0:undef,
			    primary_luminance_error_pct=>defined($primary_lum_pct)?$primary_lum_pct+0:undef,
			    primary_target_luminance=>defined($primary_target_y)?$primary_target_y+0:undef,
			    primary_score=>$primary_score+0,
			    pair_score=>$pair_combined_score+0,
			    target_values=>trace_target_values($arrays,$target)
			   });
			   write_state($state);
			   $de=$primary_de;
			   $lum_pct=$primary_lum_pct;
			   $target_step_y=$primary_target_y;
			   my $pair_primary_rejected=paired_white_primary_regression_reason($primary_de,$primary_lum_pct,$best_de,$best_lum_pct,$target_delta,$read_step,$reading,$best_reading,$white_guard_y,1);
			   my $pair_under_cap=within_itp_luminance_included_acceptance($pair_de,$pair_step);
			   if(!$pair_primary_rejected && $pair_under_cap && (!defined($paired_best_pair_score) || $pair_combined_score + 0.0001 < $paired_best_pair_score)) {
			    $paired_best_arrays=clone_arrays($arrays);
			    $paired_best_reading=clone_picture($reading);
			    $paired_best_de=$primary_de;
			    $paired_best_lum_pct=$primary_lum_pct;
			    $paired_best_score=$primary_score;
			    $paired_best_pair_reading=clone_picture($pair_reading);
			    $paired_best_pair_step=$pair_step;
			    $paired_best_pair_de=$pair_de;
			    $paired_best_pair_lum_pct=$pair_lum_pct;
			    $paired_best_pair_target_y=$pair_target_y;
			    $paired_best_pair_score=$pair_combined_score;
			    trace_109($read_step,"paired_white_best_updated",{
			     label=>$label,
			     reason=>$reason||"",
			     primary_delta_e=>defined($paired_best_de)?$paired_best_de+0:undef,
			     primary_luminance_error_pct=>defined($paired_best_lum_pct)?$paired_best_lum_pct+0:undef,
			     primary_score=>$paired_best_score+0,
			     paired_delta_e=>defined($paired_best_pair_de)?$paired_best_pair_de+0:undef,
			     paired_luminance_error_pct=>defined($paired_best_pair_lum_pct)?$paired_best_pair_lum_pct+0:undef,
			     paired_score=>$pair_score+0,
			     pair_score=>$paired_best_pair_score+0,
			     paired_values=>trace_target_values($paired_best_arrays,$target)
			    });
			   }
			   if(guarded_target_reached($pair_de,$pair_lum_pct,$target_delta,$pair_step,$pair_reading,undef) || (!$pair_primary_rejected && $pair_under_cap)) {
			    $paired_pending_reading=undef;
			    $paired_pending_step=undef;
			    $paired_pending_de=undef;
			    $paired_pending_lum_pct=undef;
			    $paired_pending_target_y=undef;
			    return 1;
			   }
			   $paired_pending_reading=clone_picture($pair_reading);
			   $paired_pending_step=$pair_step;
			   $paired_pending_de=$pair_de;
			   $paired_pending_lum_pct=$pair_lum_pct;
			   $paired_pending_target_y=$pair_target_y;
			   return 0;
			  };
				  trace_109($read_step,"initial_measurement",{
				   label=>$label,
			   reading=>trace_reading_summary($reading),
			   target_luminance=>$target_step_y,
			   white_y=>$white_y,
			   delta_e=>defined($de)?$de+0:undef,
			   luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef,
			   score=>$best_score+0,
			   best_delta_e=>$best_de+0,
			   best_score=>$best_score+0,
			   rgb_error=>rgb_error($reading),
			   target_values=>trace_target_values($arrays,$target)
			  });
				  write_state($state);
					  if(guarded_target_reached($de,$lum_pct,$target_delta,$read_step,$reading,$white_guard_y)) {
					   trace_109($read_step,"target_reached_initial",{
				    label=>$label,
				    delta_e=>defined($de)?$de+0:undef,
				    luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef,
					    score=>$best_score+0,
					    target_values=>trace_target_values($arrays,$target)
					   });
					   if(autocal_step_is_peak_headroom($read_step)) {
					    apply_peak_headroom_reference($state,$read_step,$reading,\$white_y,$target_gamma,$signal_mode,$target_x,$target_y);
					    $target_step_y=effective_target_luminance_for_autocal_reading($white_y,$read_step,$reading,$target_gamma,$signal_mode);
					    set_state_target_step_luminance($state,$target_step_y);
					    $state->{"readings"}=merge_reading($state->{"readings"},$reading);
					    write_state($state);
					   } elsif(autocal_step_is_white($read_step)) {
					    set_state_white_reference($state,$white_y);
					    write_state($state);
					   }
						   next if($read_paired_white_validation->("Validating 100% legal white with $label"));
				  }

			  my $last_de=$best_de;
			  my $stalls=0;
			  my $no_response_stalls=0;
			  my %tried_values;
			  my $headroom_next_adjustments;
			  mark_tried_values(\%tried_values,$arrays,$target,$de);
				  my $restore_best_branch=sub {
				   my ($reason)=@_;
				   return 0 if(ref($best_arrays) ne "HASH" || ref($best_reading) ne "HASH");
				   trace_109($read_step,"restore_best_branch",{
				    label=>$label,
				    reason=>$reason||"Backtracking to best $label result",
				    current_delta_e=>defined($de)?$de+0:undef,
				    current_luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef,
				    current_score=>guarded_autocal_result_score($de,$lum_pct,$read_step,$reading,$white_guard_y)+0,
				    best_delta_e=>defined($best_de)?$best_de+0:undef,
				    best_luminance_error_pct=>defined($best_lum_pct)?$best_lum_pct+0:undef,
				    best_score=>$best_score+0,
				    restoring_values=>trace_target_values($best_arrays,$target)
				   });
				   $arrays=clone_arrays($best_arrays);
			   $state->{"phase"}="restoring";
			   $state->{"message"}=$reason||"Backtracking to best $label result";
			   write_state($state);
			   my $restore_error;
				   ($picture,$restore_error)=set_picture_values($picture,$arrays,$target,$picture_mode,$calibration_mode_active,$state);
			   die $restore_error if($restore_error);
			   $calibration_mode_active=1;
			   sync_state_picture($state,$picture,$picture_mode);
			   $reading=clone_picture($best_reading);
			   $de=$best_de;
			   $lum_pct=$best_lum_pct;
			   $white_y=update_white_reference_for_step($read_step,$reading,$white_y);
			   $apply_measured_white_reference->($read_step);
				   $target_step_y=effective_target_luminance_for_autocal_reading($white_y,$read_step,$reading,$target_gamma,$signal_mode);
			   annotate_reading_target($reading,$white_y,$target_step_y,$target_x,$target_y);
			   $state->{"readings"}=merge_reading($state->{"readings"},$reading) if(ref($reading) eq "HASH");
			   $state->{"current_delta_e"}=defined($best_de) ? $best_de : undef;
			   $state->{"current_luminance"}=luminance($reading);
			   set_state_target_step_luminance($state,$target_step_y);
			   $state->{"luminance_error_pct"}=defined($best_lum_pct) ? $best_lum_pct : undef;
			   return 1;
			  };
				  my $restore_best_pair=sub {
				   my ($reason)=@_;
				   return 0 if(cancelled() || ref($paired_best_arrays) ne "HASH" || ref($paired_best_reading) ne "HASH" || !defined($paired_best_pair_score));
				   my $current_score=guarded_autocal_result_score($de,$lum_pct,$read_step,$reading,$white_guard_y);
				   trace_109($read_step,"restore_best_pair",{
				    label=>$label,
				    reason=>$reason||"Restoring best $label / 100% pair",
				    current_score=>$current_score+0,
				    pair_score=>$paired_best_pair_score+0,
				    primary_delta_e=>defined($paired_best_de)?$paired_best_de+0:undef,
				    primary_luminance_error_pct=>defined($paired_best_lum_pct)?$paired_best_lum_pct+0:undef,
				    primary_score=>defined($paired_best_score)?$paired_best_score+0:undef,
				    paired_delta_e=>defined($paired_best_pair_de)?$paired_best_pair_de+0:undef,
				    paired_luminance_error_pct=>defined($paired_best_pair_lum_pct)?$paired_best_pair_lum_pct+0:undef,
				    paired_values=>trace_target_values($paired_best_arrays,$target)
				   });
				   $arrays=clone_arrays($paired_best_arrays);
				   $best_arrays=clone_arrays($paired_best_arrays);
				   $best_reading=clone_picture($paired_best_reading);
				   $best_de=$paired_best_de;
				   $best_lum_pct=$paired_best_lum_pct;
				   $best_score=$paired_best_score;
				   $state->{"phase"}="restoring";
				   $state->{"message"}=$reason||"Restoring best $label / 100% pair";
				   write_state($state);
				   my $restore_error;
				   ($picture,$restore_error)=set_picture_values($picture,$arrays,$target,$picture_mode,$calibration_mode_active,$state);
				   die $restore_error if($restore_error);
				   $calibration_mode_active=1;
				   sync_state_picture($state,$picture,$picture_mode);
				   $reading=clone_picture($best_reading);
				   $de=$best_de;
				   $lum_pct=$best_lum_pct;
				   $white_y=update_white_reference_for_step($read_step,$reading,$white_y);
				   $apply_measured_white_reference->($read_step);
				   $target_step_y=effective_target_luminance_for_autocal_reading($white_y,$read_step,$reading,$target_gamma,$signal_mode);
				   annotate_reading_target($reading,$white_y,$target_step_y,$target_x,$target_y);
				   $state->{"readings"}=merge_reading($state->{"readings"},$reading) if(ref($reading) eq "HASH");
				   $state->{"readings"}=merge_reading($state->{"readings"},$paired_best_pair_reading) if(ref($paired_best_pair_reading) eq "HASH");
				   $state->{"current_delta_e"}=defined($best_de) ? $best_de : undef;
				   $state->{"current_luminance"}=luminance($reading);
				   set_state_target_step_luminance($state,$target_step_y);
				   $state->{"luminance_error_pct"}=defined($best_lum_pct) ? $best_lum_pct : undef;
				   $state->{"paired_white_delta_e"}=defined($paired_best_pair_de) ? $paired_best_pair_de : undef;
				   $state->{"paired_white_score"}=defined($paired_best_pair_score) ? $paired_best_pair_score : undef;
				   if(within_itp_luminance_included_acceptance($paired_best_pair_de,$paired_best_pair_step)) {
				    $paired_pending_reading=undef;
				    $paired_pending_step=undef;
				    $paired_pending_de=undef;
				    $paired_pending_lum_pct=undef;
				    $paired_pending_target_y=undef;
				   }
				   return 1;
				  };
			  my $apply_probe_result=sub {
		   my ($probe_step,$probe_reading,$probe_arrays,$probe_picture)=@_;
		   return 0 if(!$probe_step || ref($probe_reading) ne "HASH" || ref($probe_arrays) ne "HASH");
		   $read_step=$probe_step;
		   $arrays=$probe_arrays;
		   $picture=$probe_picture if(ref($probe_picture) eq "HASH");
		   $reading=$probe_reading;
		   $white_y=update_white_reference_for_step($read_step,$reading,$white_y);
		   $apply_measured_white_reference->($read_step);
		   $target_step_y=effective_target_luminance_for_autocal_reading($white_y,$read_step,$reading,$target_gamma,$signal_mode);
			   annotate_reading_target($reading,$white_y,$target_step_y,$target_x,$target_y);
			   $de=autocal_delta_e_for_step($reading,$white_y,$target_x,$target_y,$target_step_y,$read_step);
			   $lum_pct=luminance_error_percent($reading,$target_step_y);
			   my $probe_score=guarded_autocal_result_score($de,$lum_pct,$read_step,$reading,$white_guard_y);
			   my $probe_best_update_reason=autocal_best_update_reason($de,$probe_score,$best_de,$best_score,$lum_pct,$best_lum_pct,$read_step,$reading,$white_guard_y);
				   if($probe_best_update_reason) {
				    $best_de=$de;
			    $best_lum_pct=$lum_pct;
			    $best_score=$probe_score;
			    $best_arrays=clone_arrays($arrays);
				    $best_reading=clone_picture($reading);
				   }
					   trace_109($read_step,"probe_applied",{
					    label=>$label,
					    reading=>trace_reading_summary($reading),
					    delta_e=>defined($de)?$de+0:undef,
					    luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef,
				    score=>$probe_score+0,
				    best_update_reason=>$probe_best_update_reason,
				    best_delta_e=>defined($best_de)?$best_de+0:undef,
				    best_score=>$best_score+0,
					    target_values=>trace_target_values($arrays,$target)
					   });
				   $state->{"readings"}=merge_reading($state->{"readings"},$reading);
			   $state->{"current_delta_e"}=defined($de) ? $de : undef;
		   $state->{"current_luminance"}=luminance($reading);
			   set_state_target_step_luminance($state,$target_step_y);
			   $state->{"luminance_error_pct"}=defined($lum_pct) ? $lum_pct : undef;
			   $state->{"active_stimulus"}=$read_step->{"stimulus"}+0 if(defined($read_step->{"stimulus"}));
			   $state->{"best_score"}=$best_score;
			   %tried_values=();
		   mark_tried_values(\%tried_values,$arrays,$target,$de);
		   $stalls=0;
		   $no_response_stalls=0;
		   return 1;
		  };
			  my $iteration_limit=iteration_limit_for_step($step,$max_iterations,$config);
			  for(my $iter=1;$iter<=$iteration_limit;$iter++) {
			   last if(cancelled());
			   my $planning_from_paired=(ref($paired_pending_reading) eq "HASH" && ref($paired_pending_step) eq "HASH") ? 1 : 0;
			   my $plan_reading=$planning_from_paired ? $paired_pending_reading : $reading;
			   my $plan_step=$planning_from_paired ? $paired_pending_step : $read_step;
			   my $plan_de=$planning_from_paired ? $paired_pending_de : $de;
			   my $plan_lum_pct=$planning_from_paired ? $paired_pending_lum_pct : $lum_pct;
			   my $plan_target_y=$planning_from_paired ? $paired_pending_target_y : $target_step_y;
			   my $err=autocal_adjustment_error($plan_reading,$plan_step);
			   my $lum_err=luminance_error_ratio($plan_reading,$plan_target_y);
					   my $adjustments;
					   if(!$planning_from_paired && autocal_step_is_fast_headroom($read_step) && ref($headroom_next_adjustments) eq "ARRAY") {
					    $adjustments=$headroom_next_adjustments;
					    $headroom_next_adjustments=undef;
					   } else {
					    $adjustments=choose_adjustments($err,$arrays,$target,$plan_de,0.25,$stalls,$lum_err,\%tried_values,$plan_step);
					   }
				   if(!$adjustments && stimulus_probe_enabled($config) && !guarded_target_reached($de,$lum_pct,$target_delta,$read_step,$reading,$white_guard_y)) {
				    my ($probe_step,$probe_reading,$probe_arrays,$probe_picture,$probe_error)=probe_responsive_stimulus(
				     $config,$state,$read_step,$arrays,$slot_default_arrays,$target,$picture,$picture_mode,$calibration_mode_active,$reading,
				     $white_y,$target_gamma,$signal_mode,$target_x,$target_y,\%stimulus_probe_tried
				    );
				    die $probe_error if($probe_error && $probe_error ne "cancelled");
					    last if($probe_error && $probe_error eq "cancelled");
					    if($apply_probe_result->($probe_step,$probe_reading,$probe_arrays,$probe_picture)) {
					     $iter-- if($iter > 0);
					     next;
					    }
				   }
					   if(!$adjustments) {
					    trace_109($read_step,"no_adjustment_chosen",{
					     label=>$label,
					     planning_from_paired_white=>$planning_from_paired ? JSON::PP::true : JSON::PP::false,
					     iteration=>$iter+0,
					     iteration_limit=>$iteration_limit+0,
					     delta_e=>defined($plan_de)?$plan_de+0:undef,
					     luminance_error_pct=>defined($plan_lum_pct)?$plan_lum_pct+0:undef,
					     rgb_error=>$err,
					     luminance_error_ratio=>defined($lum_err)?$lum_err+0:undef,
					     target_values=>trace_target_values($arrays,$target)
					    });
					    last;
					   }
					   my $before_adjustment_reading=clone_picture($reading);
					   my $before_values=trace_target_values($arrays,$target);
		   foreach my $adj (@{$adjustments}) {
		    $arrays->{$adj->{"setting"}}[$target->{"index"}]=$adj->{"next"};
		   }
		   trace_109($read_step,"adjustment_plan",{
		    label=>$label,
		    planning_from_paired_white=>$planning_from_paired ? JSON::PP::true : JSON::PP::false,
		    iteration=>$iter+0,
		    iteration_limit=>$iteration_limit+0,
		    delta_e=>defined($plan_de)?$plan_de+0:undef,
		    luminance_error_pct=>defined($plan_lum_pct)?$plan_lum_pct+0:undef,
		    score=>guarded_autocal_result_score($de,$lum_pct,$read_step,$reading,$white_guard_y)+0,
		    best_delta_e=>defined($best_de)?$best_de+0:undef,
		    best_score=>$best_score+0,
		    rgb_error=>$err,
		    luminance_error_ratio=>defined($lum_err)?$lum_err+0:undef,
		    adjustments=>trace_adjustments_summary($adjustments),
		    values_before=>$before_values,
		    values_after=>trace_target_values($arrays,$target)
		   });
		   if($planning_from_paired) {
		    $paired_pending_reading=undef;
		    $paired_pending_step=undef;
		    $paired_pending_de=undef;
		    $paired_pending_lum_pct=undef;
		    $paired_pending_target_y=undef;
		   }
	   $state->{"phase"}="writing";
	   $state->{"message"}="Writing $paired_label ".describe_adjustments($adjustments)." ($iter/$iteration_limit)";
	   $state->{"iteration"}=$iter;
	   write_state($state);
	   my $write_error;
	   ($picture,$write_error)=set_picture_values($picture,$arrays,$target,$picture_mode,$calibration_mode_active,$state);
	   die $write_error if($write_error);
	   $calibration_mode_active=1;
	   sync_state_picture($state,$picture,$picture_mode);
	   last if(cancelled());
	   $state->{"phase"}="reading";
	   $state->{"message"}="Reading $paired_label after adjustment ($iter/$iteration_limit)";
	   write_state($state);
		   ($reading,$read_error,$guarded_target_step_y)=read_step_guarded($config,$read_step,$state,$white_y,$target_gamma,$signal_mode,$target_x,$target_y,$label);
	   die $read_error if($read_error && $read_error ne "cancelled");
	   last if($read_error && $read_error eq "cancelled");
			   $white_y=update_white_reference_for_step($read_step,$reading,$white_y);
			   $apply_measured_white_reference->($read_step);
		   $target_step_y=defined($guarded_target_step_y) ? $guarded_target_step_y : effective_target_luminance_for_autocal_reading($white_y,$read_step,$reading,$target_gamma,$signal_mode);
		   annotate_reading_target($reading,$white_y,$target_step_y,$target_x,$target_y);
		   $de=autocal_delta_e_for_step($reading,$white_y,$target_x,$target_y,$target_step_y,$read_step);
	   $state->{"readings"}=merge_reading($state->{"readings"},$reading) if(ref($reading) eq "HASH");
	   $state->{"current_delta_e"}=defined($de) ? $de : undef;
	   $state->{"current_luminance"}=luminance($reading);
	   set_state_target_step_luminance($state,$target_step_y);
			   $lum_pct=luminance_error_percent($reading,$target_step_y);
			   $state->{"luminance_error_pct"}=defined($lum_pct) ? $lum_pct : undef;
				   mark_tried_values(\%tried_values,$arrays,$target,$de);
				   $headroom_next_adjustments=headroom_proportional_adjustment($read_step,$adjustments,$before_adjustment_reading,$reading,$arrays,$target,\%tried_values);
				   my $response_score=reading_change_score($before_adjustment_reading,$reading);
				   $state->{"response_score"}=$response_score;
				   my $candidate_score_after=guarded_autocal_result_score($de,$lum_pct,$read_step,$reading,$white_guard_y);
				   trace_109($read_step,"measurement_after_adjustment",{
				    label=>$label,
				    iteration=>$iter+0,
				    iteration_limit=>$iteration_limit+0,
				    reading=>trace_reading_summary($reading),
				    previous_reading=>trace_reading_summary($before_adjustment_reading),
				    target_luminance=>$target_step_y,
				    white_y=>$white_y,
				    delta_e=>defined($de)?$de+0:undef,
				    luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef,
				    score=>$candidate_score_after+0,
				    best_delta_e=>defined($best_de)?$best_de+0:undef,
				    best_score=>$best_score+0,
				    rgb_error=>rgb_error($reading),
				    response_score=>$response_score+0,
				    target_values=>trace_target_values($arrays,$target)
				   });
				   if($planning_from_paired) {
				    my $paired_regression_reason=paired_white_primary_regression_reason($de,$lum_pct,$best_de,$best_lum_pct,$target_delta,$read_step,$reading,$best_reading,$white_guard_y,1);
				    if($paired_regression_reason) {
				     $stalls++;
				     trace_109($read_step,"paired_white_primary_rejected",{
				      label=>$label,
				      iteration=>$iter+0,
				      reason=>$paired_regression_reason,
				      candidate_delta_e=>defined($de)?$de+0:undef,
				      candidate_luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef,
				      candidate_score=>$candidate_score_after+0,
				      best_delta_e=>defined($best_de)?$best_de+0:undef,
				      best_luminance_error_pct=>defined($best_lum_pct)?$best_lum_pct+0:undef,
				      best_score=>$best_score+0,
				      candidate_values=>trace_target_values($arrays,$target),
				      best_values=>trace_target_values($best_arrays,$target)
				     });
				     $restore_best_branch->("Backtracking paired 100% adjustment that regressed $label");
				     $state->{"best_delta_e"}=$best_de;
				     $state->{"best_score"}=$best_score;
				     write_state($state);
				     next;
				    }
				    last if($read_paired_white_validation->("Validating 100% legal white after paired $label adjustment"));
				    $state->{"best_delta_e"}=$best_de;
				    $state->{"best_score"}=$best_score;
				    write_state($state);
				    next;
				   }
				   my $no_response_threshold=(ref($read_step) eq "HASH" && defined($read_step->{"ire"}) && ($read_step->{"ire"}+0) <= 25) ? 0.012 : 0.006;
			   if(adjustment_total($adjustments) >= 1 && $response_score < $no_response_threshold) {
			    $no_response_stalls++;
			   } else {
			    $no_response_stalls=0;
			   }
				   my $probe_found=0;
						   my $needs_stimulus_probe=0;
						   if(!guarded_target_reached($de,$lum_pct,$target_delta,$read_step,$reading,$white_guard_y)) {
						    my $near_probe_skip=near_target_for_probe_skip($de,$lum_pct,$target_delta,$read_step);
						    my $keep_tuning_luma=0;
						    if(has_luminance_channel($arrays,$target) && defined($lum_pct)) {
						     my $luma_tol=luminance_tolerance_percent($read_step);
						     $keep_tuning_luma=1 if(abs($lum_pct) > ($luma_tol*0.65) && !ddc_target_near_limit($arrays,$target,42));
						    }
						    if(!$keep_tuning_luma) {
						     $needs_stimulus_probe=1 if(!$near_probe_skip && ddc_target_near_limit($arrays,$target,45));
						     $needs_stimulus_probe=1 if(!$near_probe_skip && $no_response_stalls >= 2);
						     $needs_stimulus_probe=1 if(!$near_probe_skip && $iter >= 4 && ddc_target_max_delta($arrays,$slot_default_arrays,$target) >= 12);
						     $needs_stimulus_probe=1 if(!$near_probe_skip && $iter >= 6 && far_from_target($de,$lum_pct,$target_delta,$read_step));
						    }
						   }
					   if(stimulus_probe_enabled($config) && $needs_stimulus_probe) {
					    my ($probe_step,$probe_reading,$probe_arrays,$probe_picture,$probe_error)=probe_responsive_stimulus(
					     $config,$state,$read_step,$arrays,$slot_default_arrays,$target,$picture,$picture_mode,$calibration_mode_active,$reading,
					     $white_y,$target_gamma,$signal_mode,$target_x,$target_y,\%stimulus_probe_tried
					    );
				    die $probe_error if($probe_error && $probe_error ne "cancelled");
				    last if($probe_error && $probe_error eq "cancelled");
					    $probe_found=1 if($apply_probe_result->($probe_step,$probe_reading,$probe_arrays,$probe_picture));
					   }
					   my $best_update_reason=autocal_best_update_reason($de,$candidate_score_after,$best_de,$best_score,$lum_pct,$best_lum_pct,$read_step,$reading,$white_guard_y);
				   if($probe_found) {
				    # The probe already reset the baseline to the responsive patch stimulus.
				    $iter-- if($iter > 0);
				   } elsif($best_update_reason) {
			    $best_de=$de;
			    $best_lum_pct=$lum_pct;
			    $best_score=$candidate_score_after;
			    $best_arrays=clone_arrays($arrays);
				    $best_reading=clone_picture($reading);
					    $stalls=0;
					    trace_109($read_step,"best_updated",{
					     label=>$label,
					     iteration=>$iter+0,
				     best_delta_e=>defined($best_de)?$best_de+0:undef,
				     best_luminance_error_pct=>defined($best_lum_pct)?$best_lum_pct+0:undef,
				     best_score=>$best_score+0,
					     best_update_reason=>$best_update_reason,
				     best_values=>trace_target_values($best_arrays,$target)
				    });
		   } else {
			    $stalls++;
			    my $candidate_score=$candidate_score_after;
			    trace_109($read_step,"candidate_rejected",{
			     label=>$label,
			     iteration=>$iter+0,
			     stalls=>$stalls+0,
			     candidate_delta_e=>defined($de)?$de+0:undef,
			     candidate_luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef,
			     candidate_score=>$candidate_score+0,
			     best_delta_e=>defined($best_de)?$best_de+0:undef,
			     best_luminance_error_pct=>defined($best_lum_pct)?$best_lum_pct+0:undef,
			     best_score=>$best_score+0,
			     candidate_values=>trace_target_values($arrays,$target),
			     best_values=>trace_target_values($best_arrays,$target)
			    });
			    my $backtrack_ready=(defined($best_de) && $best_de <= 2.0) ? 1 : 0;
			    $backtrack_ready=1 if(!$backtrack_ready && autocal_step_is_white($read_step) && defined($best_de) && $best_de <= 5.0);
			    $backtrack_ready=1 if(!$backtrack_ready && defined($best_de) && $best_de <= 5.0 && defined($best_lum_pct) && abs($best_lum_pct) <= luminance_tolerance_percent($read_step));
			    # Re-anchor after repeated misses even when the absolute dE is still high.
			    $backtrack_ready=1 if(!$backtrack_ready && $stalls >= 3 && defined($best_de));
		    if(($backtrack_ready || white_luminance_guard_failed($read_step,$reading,$white_guard_y)) && $candidate_score > $best_score+0.02 && !guarded_target_reached($de,$lum_pct,$target_delta,$read_step,$reading,$white_guard_y)) {
		     $restore_best_branch->("Backtracking to best $label result");
		    }
		   }
		   $state->{"best_delta_e"}=$best_de;
		   $state->{"best_score"}=$best_score;
		   write_state($state);
			   if(guarded_target_reached($de,$lum_pct,$target_delta,$read_step,$reading,$white_guard_y)) {
				    last if($read_paired_white_validation->("Validating 100% legal white after $label adjustment"));
			   }
			   if(!$probe_found && $no_response_stalls >= 2 && $iter >= 4 && !stimulus_scan_steps($config,$read_step,\%stimulus_probe_tried)) {
		    $state->{"message"}="$paired_label uncorrectable within stimulus window; closest result kept";
		    write_state($state);
		    last;
		   }
			   if(!white_luminance_guard_failed($read_step,$best_reading,$white_guard_y) && close_enough_stalled($best_de,$best_lum_pct,$target_delta,$read_step,$stalls,$iter)) {
		    $state->{"message"}="$label close result kept after stalled fine-tune";
		    write_state($state);
		    last;
		   }
		   $last_de=defined($de) ? $de : $last_de;
		  }
			  my $restore_best_if_better=sub {
			   my ($reason)=@_;
			   my $current_score=guarded_autocal_result_score($de,$lum_pct,$read_step,$reading,$white_guard_y);
			   return 0 if(cancelled() || ref($best_arrays) ne "HASH" || !defined($de) || $best_score + 0.0001 >= $current_score);
			   trace_109($read_step,"restore_best_if_better",{
			    label=>$label,
			    reason=>$reason||"Restoring closest $label result",
			    current_delta_e=>defined($de)?$de+0:undef,
			    current_luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef,
			    current_score=>$current_score+0,
			    current_values=>trace_target_values($arrays,$target),
			    best_delta_e=>defined($best_de)?$best_de+0:undef,
			    best_luminance_error_pct=>defined($best_lum_pct)?$best_lum_pct+0:undef,
			    best_score=>$best_score+0,
			    best_values=>trace_target_values($best_arrays,$target)
			   });
			   $arrays=$best_arrays;
		   $state->{"phase"}="restoring";
		   $state->{"message"}=$reason||"Restoring closest $label result";
		   write_state($state);
		   my $write_error;
			   ($picture,$write_error)=set_picture_values($picture,$arrays,$target,$picture_mode,$calibration_mode_active,$state);
		   die $write_error if($write_error);
		   $calibration_mode_active=1;
		   sync_state_picture($state,$picture,$picture_mode);
			   $reading=clone_picture($best_reading) if(ref($best_reading) eq "HASH");
			   $white_y=update_white_reference_for_step($read_step,$reading,$white_y);
			   $apply_measured_white_reference->($read_step);
			   $target_step_y=effective_target_luminance_for_autocal_reading($white_y,$read_step,$reading,$target_gamma,$signal_mode);
		   $de=$best_de;
		   $lum_pct=$best_lum_pct;
		   $state->{"readings"}=merge_reading($state->{"readings"},$best_reading) if(ref($best_reading) eq "HASH");
		   return 1;
		  };
		  $restore_best_if_better->("Restoring closest $label result");
			  if(!cancelled() && autocal_step_allows_final_fine_tune($read_step,$best_de,$target_delta) && ref($best_arrays) eq "HASH" && ref($best_reading) eq "HASH" && !guarded_target_reached($best_de,$best_lum_pct,$target_delta,$read_step,$best_reading,$white_guard_y)) {
			   trace_109($read_step,"start_final_fine_tune",{
			    label=>$label,
			    best_delta_e=>defined($best_de)?$best_de+0:undef,
			    best_luminance_error_pct=>defined($best_lum_pct)?$best_lum_pct+0:undef,
			    best_score=>$best_score+0,
			    best_values=>trace_target_values($best_arrays,$target)
			   });
			   $restore_best_branch->("Starting final fine tune for $label");
		   my %polish_tried;
		   mark_tried_values(\%polish_tried,$arrays,$target,$de);
		   my $polish_limit=headroom_polish_limit_for_step($read_step);
		   $polish_limit=48 if(!defined($polish_limit));
		   my $shadow_polish_limit=low_shadow_polish_limit_for_step($read_step,$config);
		   $polish_limit=$shadow_polish_limit if(defined($shadow_polish_limit));
		   my $polish_stalls=0;
		   for(my $polish=1;$polish<=$polish_limit;$polish++) {
		    last if(cancelled());
		    if(guarded_target_reached($best_de,$best_lum_pct,$target_delta,$read_step,$best_reading,$white_guard_y)) {
		     last if($read_paired_white_validation->("Validating 100% legal white during $label fine tune"));
		    }
		    my $planning_from_paired=(ref($paired_pending_reading) eq "HASH" && ref($paired_pending_step) eq "HASH") ? 1 : 0;
		    my $plan_reading=$planning_from_paired ? $paired_pending_reading : $reading;
		    my $plan_step=$planning_from_paired ? $paired_pending_step : $read_step;
		    my $plan_de=$planning_from_paired ? $paired_pending_de : $best_de;
		    my $plan_lum_pct=$planning_from_paired ? $paired_pending_lum_pct : $lum_pct;
		    my $plan_target_y=$planning_from_paired ? $paired_pending_target_y : $target_step_y;
		    my $err=autocal_adjustment_error($plan_reading,$plan_step);
		    my $lum_err=luminance_error_ratio($plan_reading,$plan_target_y);
		    my $micro_step=(defined($best_de) && $best_de <= ($target_delta+0.15)) ? 0.10 : ((defined($best_de) && $best_de > ($target_delta*2)) ? 0.5 : 0.25);
			    my $adjustments=choose_micro_adjustments($err,$arrays,$target,$lum_err,\%polish_tried,$micro_step,$plan_de,$polish_stalls,$plan_step);
			    if(!$adjustments) {
			     trace_109($read_step,"no_fine_tune_adjustment_chosen",{
			      label=>$label,
			      planning_from_paired_white=>$planning_from_paired ? JSON::PP::true : JSON::PP::false,
			      polish=>$polish+0,
			      polish_limit=>$polish_limit+0,
			      delta_e=>defined($plan_de)?$plan_de+0:undef,
			      best_delta_e=>defined($best_de)?$best_de+0:undef,
			      rgb_error=>$err,
			      luminance_error_ratio=>defined($lum_err)?$lum_err+0:undef,
			      target_values=>trace_target_values($arrays,$target)
			     });
			     last;
			    }
			    my $before_polish=clone_picture($reading);
			    my $before_values=trace_target_values($arrays,$target);
			    foreach my $adj (@{$adjustments}) {
			     $arrays->{$adj->{"setting"}}[$target->{"index"}]=$adj->{"next"};
			    }
			    trace_109($read_step,"fine_tune_plan",{
			     label=>$label,
			     planning_from_paired_white=>$planning_from_paired ? JSON::PP::true : JSON::PP::false,
			     polish=>$polish+0,
			     polish_limit=>$polish_limit+0,
			     delta_e=>defined($plan_de)?$plan_de+0:undef,
			     luminance_error_pct=>defined($plan_lum_pct)?$plan_lum_pct+0:undef,
			     best_delta_e=>defined($best_de)?$best_de+0:undef,
			     best_score=>$best_score+0,
			     rgb_error=>$err,
			     luminance_error_ratio=>defined($lum_err)?$lum_err+0:undef,
			     micro_step=>$micro_step+0,
			     adjustments=>trace_adjustments_summary($adjustments),
			     values_before=>$before_values,
			     values_after=>trace_target_values($arrays,$target)
			    });
		    if($planning_from_paired) {
		     $paired_pending_reading=undef;
		     $paired_pending_step=undef;
		     $paired_pending_de=undef;
		     $paired_pending_lum_pct=undef;
		     $paired_pending_target_y=undef;
		    }
		    $state->{"phase"}="writing";
		    $state->{"message"}="Fine tuning $paired_label ".describe_adjustments($adjustments)." ($polish/$polish_limit)";
		    write_state($state);
		    my $write_error;
			    ($picture,$write_error)=set_picture_values($picture,$arrays,$target,$picture_mode,$calibration_mode_active,$state);
		    die $write_error if($write_error);
		    $calibration_mode_active=1;
		    sync_state_picture($state,$picture,$picture_mode);
		    last if(cancelled());
		    $state->{"phase"}="reading";
		    $state->{"message"}="Reading $paired_label fine tune ($polish/$polish_limit)";
		    write_state($state);
		    ($reading,$read_error,$guarded_target_step_y)=read_step_guarded($config,$read_step,$state,$white_y,$target_gamma,$signal_mode,$target_x,$target_y,$label);
		    die $read_error if($read_error && $read_error ne "cancelled");
		    last if($read_error && $read_error eq "cancelled");
			    $white_y=update_white_reference_for_step($read_step,$reading,$white_y);
			    $apply_measured_white_reference->($read_step);
			    $target_step_y=defined($guarded_target_step_y) ? $guarded_target_step_y : effective_target_luminance_for_autocal_reading($white_y,$read_step,$reading,$target_gamma,$signal_mode);
		    annotate_reading_target($reading,$white_y,$target_step_y,$target_x,$target_y);
		    $de=autocal_delta_e_for_step($reading,$white_y,$target_x,$target_y,$target_step_y,$read_step);
		    $lum_pct=luminance_error_percent($reading,$target_step_y);
		    mark_tried_values(\%polish_tried,$arrays,$target,$de);
		    $state->{"readings"}=merge_reading($state->{"readings"},$reading) if(ref($reading) eq "HASH");
		    $state->{"current_delta_e"}=defined($de) ? $de : undef;
		    $state->{"current_luminance"}=luminance($reading);
		    set_state_target_step_luminance($state,$target_step_y);
		    $state->{"luminance_error_pct"}=defined($lum_pct) ? $lum_pct : undef;
			    my $candidate_score=guarded_autocal_result_score($de,$lum_pct,$read_step,$reading,$white_guard_y);
			    trace_109($read_step,"fine_tune_measurement",{
			     label=>$label,
			     polish=>$polish+0,
			     polish_limit=>$polish_limit+0,
			     reading=>trace_reading_summary($reading),
			     previous_reading=>trace_reading_summary($before_polish),
			     target_luminance=>$target_step_y,
			     white_y=>$white_y,
			     delta_e=>defined($de)?$de+0:undef,
			     luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef,
			     score=>$candidate_score+0,
			     best_delta_e=>defined($best_de)?$best_de+0:undef,
			     best_score=>$best_score+0,
			     rgb_error=>rgb_error($reading),
			     target_values=>trace_target_values($arrays,$target)
			    });
			    if($planning_from_paired) {
			     my $paired_regression_reason=paired_white_primary_regression_reason($de,$lum_pct,$best_de,$best_lum_pct,$target_delta,$read_step,$reading,$best_reading,$white_guard_y,1);
			     if($paired_regression_reason) {
			      $polish_stalls++;
			      trace_109($read_step,"paired_white_fine_tune_primary_rejected",{
			       label=>$label,
			       polish=>$polish+0,
			       reason=>$paired_regression_reason,
			       candidate_delta_e=>defined($de)?$de+0:undef,
			       candidate_luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef,
			       candidate_score=>$candidate_score+0,
			       best_delta_e=>defined($best_de)?$best_de+0:undef,
			       best_luminance_error_pct=>defined($best_lum_pct)?$best_lum_pct+0:undef,
			       best_score=>$best_score+0,
			       candidate_values=>trace_target_values($arrays,$target),
			       best_values=>trace_target_values($best_arrays,$target)
			      });
			      $restore_best_branch->("Backtracking paired 100% fine tune that regressed $label");
			      last if($polish_stalls >= 14);
			      next;
			     }
			     last if($read_paired_white_validation->("Validating 100% legal white after paired $label fine tune"));
			     $state->{"best_delta_e"}=$best_de;
			     $state->{"best_score"}=$best_score;
			     write_state($state);
			     next;
			    }
			    my $fine_tune_best_update_reason=autocal_best_update_reason($de,$candidate_score,$best_de,$best_score,$lum_pct,$best_lum_pct,$read_step,$reading,$white_guard_y);
			    if($fine_tune_best_update_reason) {
			     $best_de=$de;
		     $best_lum_pct=$lum_pct;
		     $best_score=$candidate_score;
			     $best_arrays=clone_arrays($arrays);
			     $best_reading=clone_picture($reading);
			     $polish_stalls=0;
			     trace_109($read_step,"fine_tune_best_updated",{
			      label=>$label,
			      polish=>$polish+0,
			      best_delta_e=>defined($best_de)?$best_de+0:undef,
			      best_luminance_error_pct=>defined($best_lum_pct)?$best_lum_pct+0:undef,
			      best_score=>$best_score+0,
			      best_update_reason=>$fine_tune_best_update_reason,
			      best_values=>trace_target_values($best_arrays,$target)
			     });
			    } else {
			     $polish_stalls++;
			     trace_109($read_step,"fine_tune_candidate_rejected",{
			      label=>$label,
			      polish=>$polish+0,
			      polish_stalls=>$polish_stalls+0,
			      candidate_delta_e=>defined($de)?$de+0:undef,
			      candidate_luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef,
			      candidate_score=>$candidate_score+0,
			      best_delta_e=>defined($best_de)?$best_de+0:undef,
			      best_luminance_error_pct=>defined($best_lum_pct)?$best_lum_pct+0:undef,
			      best_score=>$best_score+0,
			      candidate_values=>trace_target_values($arrays,$target),
			      best_values=>trace_target_values($best_arrays,$target)
			     });
			     $restore_best_branch->("Backtracking $label fine tune");
		     last if($polish_stalls >= 14);
		    }
		    $state->{"best_delta_e"}=$best_de;
		    $state->{"best_score"}=$best_score;
		    write_state($state);
		   }
		   $restore_best_if_better->("Restoring closest $label result after fine tune");
		  }
			  $restore_best_branch->("Keeping best $label result") if(!cancelled() && ref($best_arrays) eq "HASH" && ref($best_reading) eq "HASH");
			  $restore_best_pair->("Keeping best $label / 100% pair");
				  if(autocal_step_is_white($read_step)) {
				   $white_y=update_white_reference_for_step($read_step,$best_reading,$white_y);
				   $apply_measured_white_reference->($read_step);
				   $best_lum_pct=undef;
				   set_state_target_step_luminance($state,undef);
				  } elsif(autocal_step_is_peak_headroom($read_step)) {
				   apply_peak_headroom_reference($state,$read_step,$best_reading,\$white_y,$target_gamma,$signal_mode,$target_x,$target_y);
				   my $peak_target_y=target_luminance_for_step($white_y,$read_step,$target_gamma,$signal_mode);
				   $peak_target_y=effective_target_luminance_for_autocal_reading($white_y,$read_step,$best_reading,$target_gamma,$signal_mode) if(!defined($peak_target_y));
				   if(defined($peak_target_y) && $peak_target_y > 0) {
				    $LG_AUTOCAL_HEADROOM_TARGET_LUMINANCE=$peak_target_y;
				    $state->{"headroom_target_luminance"}=$peak_target_y;
				    annotate_reading_target($best_reading,$white_y,$peak_target_y,$target_x,$target_y);
				    annotate_reading_target($reading,$white_y,$peak_target_y,$target_x,$target_y);
				   }
				   $best_lum_pct=luminance_error_percent($best_reading,$peak_target_y);
				   set_state_target_step_luminance($state,$peak_target_y);
				   $state->{"readings"}=merge_reading($state->{"readings"},$best_reading) if(ref($best_reading) eq "HASH");
				  }
					  if(!cancelled() && ref($paired_white_step) eq "HASH" && ref($paired_pending_reading) ne "HASH") {
					   $read_paired_white_validation->("Final 100% legal white validation for $label");
					  }
					  if(!cancelled() && ref($paired_white_step) eq "HASH" && ref($reading) eq "HASH") {
					   $best_reading=clone_picture($reading);
					   $best_de=$de;
					   $best_lum_pct=$lum_pct;
					   $best_score=guarded_autocal_result_score($best_de,$best_lum_pct,$read_step,$best_reading,$white_guard_y);
					   $state->{"readings"}=merge_reading($state->{"readings"},$best_reading);
					   $state->{"current_delta_e"}=defined($best_de) ? $best_de : undef;
					   $state->{"current_luminance"}=luminance($best_reading);
					   set_state_target_step_luminance($state,$target_step_y);
					   $state->{"luminance_error_pct"}=defined($best_lum_pct) ? $best_lum_pct : undef;
					  }
					  my $paired_white_pending=(ref($paired_pending_reading) eq "HASH") ? 1 : 0;
				  my $final_reached=guarded_target_reached($best_de,$best_lum_pct,$target_delta,$read_step,$best_reading,$white_guard_y) && !$paired_white_pending;
				  $state->{"current_delta_e"}=$best_de;
		  $state->{"best_delta_e"}=$best_de;
		  $state->{"luminance_error_pct"}=defined($best_lum_pct) ? $best_lum_pct : undef;
				  $state->{"message"}=$final_reached ? "$paired_label reached target" : "$paired_label closest result kept";
				  trace_109($read_step,"final_step_result",{
				   label=>$label,
				   reached_target=>$final_reached?JSON::PP::true:JSON::PP::false,
				   paired_white_pending=>$paired_white_pending?JSON::PP::true:JSON::PP::false,
				   best_delta_e=>defined($best_de)?$best_de+0:undef,
				   best_luminance_error_pct=>defined($best_lum_pct)?$best_lum_pct+0:undef,
				   best_score=>$best_score+0,
				   best_reading=>trace_reading_summary($best_reading),
				   final_values=>trace_target_values($best_arrays,$target)
				  });
			  write_state($state);
			  if(
			   !$white_refreshed_after_headroom &&
			   $refresh_white_after_headroom &&
			   defined($step->{"ire"}) &&
			   abs(($step->{"ire"}+0)-99) < 0.001
			  ) {
			   $white_refreshed_after_headroom=1;
			   $read_reference_step->($white_reference_step,"Auto Cal 100% calibrated reference","Refreshing 100% white after top-end calibration");
			  }
			 }
			 if(!cancelled() && @verification) {
			  foreach my $verify_step (@verification) {
			   last if(cancelled());
			   $step_num++;
			   my $verify_label=$verify_step->{"name"}||format_percent($verify_step->{"ire"})."%";
			   $state->{"current_step"}=$step_num;
			   $state->{"total_steps"}=$total_ordered_steps;
			   $state->{"current_name"}="Auto Cal $verify_label";
			   $state->{"phase"}="reading";
			   $state->{"message"}="Reading verification $verify_label";
			   $state->{"active_stimulus"}=$verify_step->{"stimulus"}+0 if(defined($verify_step->{"stimulus"}));
			   write_state($state);
			   my ($verify_reading,$verify_error)=read_step($config,$verify_step,$state);
			   die $verify_error if($verify_error && $verify_error ne "cancelled");
			   last if($verify_error && $verify_error eq "cancelled");
			   next if(ref($verify_reading) ne "HASH");
			   my $verify_target_y=target_luminance_for_step($white_y,$verify_step,$target_gamma,$signal_mode);
			   annotate_reading_target($verify_reading,$white_y,$verify_target_y,$target_x,$target_y);
			   my $verify_de=autocal_delta_e_for_step($verify_reading,$white_y,$target_x,$target_y,$verify_target_y,$verify_step);
			   my $verify_lum_pct=luminance_error_percent($verify_reading,$verify_target_y);
			   $state->{"readings"}=merge_reading($state->{"readings"},$verify_reading);
			   $state->{"current_delta_e"}=defined($verify_de) ? $verify_de : undef;
			   $state->{"current_luminance"}=luminance($verify_reading);
			   set_state_target_step_luminance($state,$verify_target_y);
			   $state->{"luminance_error_pct"}=defined($verify_lum_pct) ? $verify_lum_pct : undef;
			   $state->{"message"}="Verification $verify_label read complete";
			   write_state($state);
			  }
			 }
			 if(!cancelled() && $black_step) {
			  $step_num++;
			  my $black_read_step=clone_picture($black_step);
			  $black_read_step->{"stimulus"}=0 if(!defined($black_read_step->{"stimulus"}));
			  $black_read_step->{"name"}="0%" if(!defined($black_read_step->{"name"}) || $black_read_step->{"name"} eq "");
			  $state->{"current_step"}=$step_num;
			  $state->{"total_steps"}=$total_ordered_steps;
			  $state->{"current_name"}="Auto Cal 0%";
			  $state->{"phase"}="reading";
			  $state->{"message"}="Reading final 0% black";
			  $state->{"active_stimulus"}=0;
			  write_state($state);
			  my ($black_reading,$black_error)=read_step($config,$black_read_step,$state);
			  die $black_error if($black_error && $black_error ne "cancelled");
			  if(ref($black_reading) eq "HASH") {
			   my $black_target_y=target_luminance_for_step($white_y,$black_read_step,$target_gamma,$signal_mode);
			   annotate_reading_target($black_reading,$white_y,$black_target_y,$target_x,$target_y);
			   $state->{"readings"}=merge_reading($state->{"readings"},$black_reading);
			   $state->{"current_luminance"}=luminance($black_reading);
			   $state->{"current_delta_e"}=undef;
			   $state->{"luminance_error_pct"}=undef;
			   $state->{"message"}="Final 0% black read complete";
			   write_state($state);
			  }
			 }
			 if(!cancelled()) {
					  my $commit_error=undef;
					  my $commit_ended_calibration=0;
					  ($picture,$commit_error,$commit_ended_calibration)=commit_final_1d_lut($state,$picture,$arrays,$picture_mode,\@ordered,$calibration_mode_active);
					  die $commit_error if($commit_error);
					  $calibration_mode_active=0 if($commit_ended_calibration);
					 }
			 if(cancelled()) {
	  $state->{"status"}="cancelled";
	  $state->{"current_name"}="Auto Cal cancelled";
	  $state->{"message"}="Auto Cal stopped";
	 } else {
	 $state->{"status"}="complete";
	 $state->{"current_name"}="Auto Cal complete";
	 $state->{"message"}="Auto Cal complete";
	 }
	 write_state($state);
	 if($calibration_mode_active) {
	  end_calibration_mode($active_picture_mode_for_cleanup);
	  $calibration_mode_active=0;
	 }
	 write_state($state);
 1;
} or do {
 my $err=$@ || "Auto Cal failed";
 $err=~s/[\r\n]+/ /g;
 if($calibration_mode_active) {
  end_calibration_mode($active_picture_mode_for_cleanup);
  $calibration_mode_active=0;
 }
 $state->{"status"}=cancelled() ? "cancelled" : "error";
 $state->{"current_name"}=cancelled() ? "Auto Cal cancelled" : "Auto Cal error";
 $state->{"message"}=cancelled() ? "Auto Cal stopped" : $err;
 write_state($state);
};

exit 0;
