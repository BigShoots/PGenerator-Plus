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
our $LG_AUTOCAL_DELTA_E_FORMULA = "deitp";
our $LG_AUTOCAL_CONFIG;
our $LG_AUTOCAL_STATE;

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
 return 1;
 return 1 if(abs($ire-109) < 0.001);
 return 1 if(abs($ire-105) < 0.001);
 return 1 if(abs($ire-100) < 0.001);
 return 1 if(abs($ire-99) < 0.001);
 return 1 if($ire > 0 && $ire <= 10.0001);
 return 0;
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
	  foreach my $key (qw(channel setting current next delta damped micro sweep neutral_luminance paired_luminance high_end_paired_luma response_probe response_model learned_response_model slope predicted_error peak_match_low peak_wrgb_seed headroom_105_seed legal_white_pair_seed frozen_channel error_gap body_final_micro body_luminance_priority low_shadow_luminance post_commit_low_shadow capped_post_commit_low_shadow source samples)) {
	   $item{$key}=trace_number($adj->{$key}) if(defined($adj->{$key}));
	  }
	  push @out,\%item;
	 }
		 return \@out;
	}

sub adjustments_have_flag {
 my ($adjustments,$flag)=@_;
 return 0 if(ref($adjustments) ne "ARRAY" || !defined($flag) || $flag eq "");
 foreach my $adj (@{$adjustments}) {
  return 1 if(ref($adj) eq "HASH" && $adj->{$flag});
 }
 return 0;
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

sub drift_matrix_trace_enabled {
 my ($config,$step)=@_;
 return 0 if(ref($config) ne "HASH");
 return 0 if(!$config->{"drift_matrix_trace"} && !$config->{"lg_autocal_drift_matrix_trace"} && !$config->{"trace_drift_matrix"});
 return trace_109_enabled($step);
}

sub trace_drift_matrix_final_kept {
 my ($config,$state,$step,$picture_mode,$target_gamma,$target_luminance,$delta_e,$luminance_error_pct,$reading,$arrays,$target)=@_;
 return if(!drift_matrix_trace_enabled($config,$step));
 return if(ref($reading) ne "HASH");
 my %row=(
  run_id=>(ref($state) eq "HASH" ? $state->{"run_id"} : undef),
  picture_mode=>$picture_mode,
  display_type=>$reading->{"display_type"} || (ref($state) eq "HASH" ? $state->{"display_type"} : undef) || $config->{"display_type"} || "lcd",
  target_gamma=>$target_gamma,
  patch_insert=>$config->{"patch_insert"} ? JSON::PP::true : JSON::PP::false,
  ire=>(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : undef,
  measured_Y=>defined($reading->{"Y"}) ? trace_number($reading->{"Y"}) : undef,
  measured_x=>defined($reading->{"x"}) ? trace_number($reading->{"x"}) : undef,
  measured_y=>defined($reading->{"y"}) ? trace_number($reading->{"y"}) : undef,
  target_luminance=>defined($target_luminance) ? ($target_luminance+0) : undef,
  delta_e=>defined($delta_e) ? ($delta_e+0) : undef,
  luminance_error_pct=>defined($luminance_error_pct) ? ($luminance_error_pct+0) : undef,
  ddc_values=>trace_target_values($arrays,$target)
 );
 trace_109($step,"drift_matrix_final_kept",\%row);
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

sub autocal_skip_duplicate_ddc_slot {
 my ($step)=@_;
 return 0;
}

sub lg_autocal_26_full_ddc_spine_enabled {
 my ($config)=@_;
 return (ref($config) eq "HASH" && $config->{"lg_autocal_26"} && $config->{"lg_autocal_26_full_ddc_spine"}) ? 1 : 0;
}

sub lg_autocal_26_full_ddc_spine_anchor_ires {
 return (109,85,65,45,25);
}

sub lg_autocal_26_full_ddc_spine_anchor {
 my ($target)=@_;
 return 0 if(ref($target) ne "HASH" || !defined($target->{"ire"}));
 my $ire=$target->{"ire"}+0;
 my $match=grep { abs($ire-$_) < 0.001 } lg_autocal_26_full_ddc_spine_anchor_ires();
 return $match ? 1 : 0;
}

sub lg_autocal_26_anchor_predrive_enabled {
 my ($config)=@_;
 return (ref($config) eq "HASH" && $config->{"lg_autocal_26"} && $config->{"lg_autocal_26_anchor_predrive"}) ? 1 : 0;
}

sub lg_autocal_26_anchor_predrive_anchor_ires {
 return (109,105,99,75,50,25,5);
}

sub lg_autocal_26_anchor_predrive_anchor_count {
 my @anchors=lg_autocal_26_anchor_predrive_anchor_ires();
 return scalar(@anchors);
}

sub lg_autocal_26_anchor_predrive_anchor {
 my ($target)=@_;
 return 0 if(ref($target) ne "HASH" || !defined($target->{"ire"}));
 my $ire=$target->{"ire"}+0;
 my $match=grep { abs($ire-$_) < 0.001 } lg_autocal_26_anchor_predrive_anchor_ires();
 return $match ? 1 : 0;
}

sub apply_lg_autocal_26_standalone_defaults {
 my ($config)=@_;
 return if(ref($config) ne "HASH");
 return if(!$config->{"lg_autocal_26"});
 return if($config->{"full_workflow"} || $config->{"full_autocal_touchup"});
 return if(exists($config->{"lg_autocal_26_anchor_predrive"}));
 $config->{"lg_autocal_26_anchor_predrive"}=JSON::PP::true;
}

sub high_low_stride_steps {
 my (@steps)=@_;
 @steps=sort { ($a->{"ire"}||0) <=> ($b->{"ire"}||0) } grep { ref($_) eq "HASH" } @steps;
 my @ordered;
 while(@steps) {
  push @ordered,pop(@steps) if(@steps);
  push @ordered,shift(@steps) if(@steps);
 }
 return @ordered;
}

sub order_autocal_steps {
	 my ($steps,$config)=@_;
	 return () if(ref($steps) ne "ARRAY");
	 my @valid=grep { ref($_) eq "HASH" && defined($_->{"ire"}) && abs(($_->{"ire"}+0)) >= 0.001 && ddc_target_for_step($_) && !autocal_skip_duplicate_ddc_slot($_) } @{$steps};
	 if(ref($config) eq "HASH" && $config->{"lg_autocal_26"}) {
  my %normal_ddc_slot;
  foreach my $step (@valid) {
   next if($step->{"autocal_white_reference"});
   my $target=ddc_target_for_step($step);
   $normal_ddc_slot{format_percent($target->{"ire"})}=1 if($target);
	  }
		 @valid=grep {
	   my $target=ddc_target_for_step($_);
	   !($_->{"autocal_white_reference"} && $target && $normal_ddc_slot{format_percent($target->{"ire"})})
		 } @valid;
	  return @valid if($config->{"lg_autocal_preserve_step_order"} || $config->{"preserve_step_order"});
		  my @lg_autocal_26_order=(109,105,99,95,90,85,80,75,70,65,60,55,50,45,40,35,30,25,20,15,10,7,5,4,3,2.3);
		  @lg_autocal_26_order=(109,85,65,45,25,105,99,95,90,80,75,70,65,60,55,50,45,40,35,30,25,20,15,10,7,5,4,3,2.3)
		   if(lg_autocal_26_full_ddc_spine_enabled($config));
		  @lg_autocal_26_order=(109,105,99,75,50,25,5,95,90,85,80,70,65,60,55,45,40,35,30,20,15,10,7,4,3,2.3)
		   if(lg_autocal_26_anchor_predrive_enabled($config));
		  my %seen_target;
		  my @ordered;
  my $target_key=sub {
   my ($step)=@_;
   my $target=ddc_target_for_step($step);
   return undef if(ref($target) ne "HASH" || !defined($target->{"ire"}));
   return format_percent($target->{"ire"});
  };
  foreach my $wanted (@lg_autocal_26_order) {
   my $wanted_key=format_percent($wanted);
   my ($match)=grep {
    my $key=$target_key->($_);
    defined($key) && !$seen_target{$key} && $key eq $wanted_key
   } @valid;
   next if(!$match);
   push @ordered,$match;
   $seen_target{$wanted_key}=1;
  }
  my @leftovers=sort {
   my $at=ddc_target_for_step($a);
   my $bt=ddc_target_for_step($b);
   (($bt && defined($bt->{"ire"})) ? ($bt->{"ire"}+0) : 0) <=>
    (($at && defined($at->{"ire"})) ? ($at->{"ire"}+0) : 0)
  } grep {
   my $key=$target_key->($_);
   defined($key) && !$seen_target{$key}
  } @valid;
  return (@ordered,@leftovers);
	 }
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

sub uv_prime {
 my ($x,$y)=@_;
 return (0,0) if(!defined($x) || !defined($y));
 my $den=(-2*$x)+(12*$y)+3;
 return (0,0) if(abs($den) < 1e-9);
 return ((4*$x)/$den,(9*$y)/$den);
}

sub lstar {
 my ($ratio)=@_;
 $ratio=0 if(!defined($ratio) || $ratio < 0);
 return (903.2963*$ratio) if($ratio <= 0.008856451679);
 return 116*($ratio ** (1/3))-16;
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
 return ($ire > 0 && $ire <= 10.0001) ? 1 : 0;
}

sub autocal_config_is_touchup {
 my ($config)=@_;
 return (ref($config) eq "HASH" && $config->{"full_autocal_touchup"}) ? 1 : 0;
}

sub config_positive_int {
 my ($config,$key,$default,$min,$max)=@_;
 my $value=$default;
 $value=int($config->{$key}) if(ref($config) eq "HASH" && defined($config->{$key}));
 $value=$min if(defined($min) && $value < $min);
 $value=$max if(defined($max) && $value > $max);
 return $value;
}

sub touchup_delta_skip_reached {
	 my ($config,$de,$target_delta,$step,$lum_pct)=@_;
	 return 0 if(!autocal_config_is_touchup($config));
	 return 0 if(!defined($de));
	 $target_delta=0.5 if(!defined($target_delta) || $target_delta <= 0);
	 return 1 if($de <= ($target_delta/6.0));
	 return 0 if(low_ire_luminance_needs_lift($step,$lum_pct));
	 return 0 if(low_ire_luminance_needs_tuning($step,$lum_pct));
	 if(autocal_step_is_low_shadow($step) && ref($step) eq "HASH" && defined($step->{"ire"}) && ($step->{"ire"}+0) <= 3.1001) {
	  return 1 if($de <= ($target_delta+0.5));
	 }
	 return ($de <= $target_delta) ? 1 : 0;
}

sub low_shadow_iteration_limit_for_step {
 my ($step,$config)=@_;
 return undef if(!autocal_step_is_low_shadow($step));
		 my $ire=$step->{"ire"}+0;
		 if(autocal_config_is_touchup($config)) {
		  return 3 if($ire <= 3.1);
		  return 5 if($ire <= 5.1);
		  return 7;
		 }
 return 8 if($ire <= 3.1);
 return 10 if($ire <= 4.1);
 return 16 if($ire <= 5.1);
 return 12;
}

sub low_shadow_polish_limit_for_step {
 my ($step,$config)=@_;
 return undef if(!autocal_step_is_low_shadow($step));
	 my $ire=$step->{"ire"}+0;
	 if(autocal_config_is_touchup($config)) {
	  return 1 if($ire <= 3.1);
	  return 3 if($ire <= 5.1);
	  return 4;
	 }
 return 2 if($ire <= 3.1);
 return 3 if($ire <= 4.1);
 return 5 if($ire <= 5.1);
 return 4;
}

sub headroom_iteration_limit_for_step {
 my ($step,$config)=@_;
 return undef if(!autocal_step_is_fast_headroom($step));
 my $ire=$step->{"ire"}+0;
 my $limit=($ire >= 108.5) ? 60 : 36;
 $limit=($ire >= 108.5) ? 10 : 8 if(autocal_config_is_touchup($config));
 if(ref($config) eq "HASH" && defined($config->{"headroom_max_iterations"})) {
  my $cap=int($config->{"headroom_max_iterations"});
  $cap=4 if($cap < 4);
  $limit=$cap if($cap < $limit);
 }
 return $limit;
}

sub headroom_polish_limit_for_step {
 my ($step,$config)=@_;
 return undef if(!autocal_step_is_fast_headroom($step));
 my $ire=$step->{"ire"}+0;
 my $limit=($ire >= 108.5) ? 16 : 10;
 $limit=3 if(autocal_config_is_touchup($config));
 if(ref($config) eq "HASH" && defined($config->{"max_polish_iterations"})) {
  my $cap=int($config->{"max_polish_iterations"});
  $cap=0 if($cap < 0);
  $limit=$cap if($cap < $limit);
 }
 return $limit;
}

sub autocal_step_allows_final_fine_tune {
 my ($step,$best_de,$target_delta)=@_;
 return 1 if(!autocal_step_is_fast_headroom($step));
 return 0 if(!defined($best_de));
 $target_delta=0.5 if(!defined($target_delta) || $target_delta <= 0);
 return 1 if($best_de <= 5.0 && $best_de > headroom_fine_target_delta($step,$target_delta));
 return 0;
}

sub autocal_step_allows_body_final_micro {
 my ($step)=@_;
 return 0 if(ref($step) ne "HASH" || !defined($step->{"ire"}));
 return 0 if(autocal_step_is_fast_headroom($step) || autocal_step_is_white($step));
 my $ire=$step->{"ire"}+0;
 return ($ire >= 9.999 && $ire <= 95.0001) ? 1 : 0;
}

sub update_white_reference_for_step {
				 my ($step,$reading,$white_y)=@_;
				 return $white_y if(!autocal_step_is_white($step));
				 my $Y=luminance($reading);
				 return (defined($Y) && $Y > 0) ? $Y : $white_y;
		}

sub target_luminance_for_autocal_step {
			 my ($white_y,$step,$target_gamma,$signal_mode)=@_;
			 return $white_y if(autocal_step_is_white($step));
			 if(autocal_step_is_peak_headroom($step)) {
			  my $target_lum_y=target_luminance_for_step($white_y,$step,$target_gamma,$signal_mode);
			  return $target_lum_y if(defined($target_lum_y));
			  return $LG_AUTOCAL_HEADROOM_TARGET_LUMINANCE if($LG_AUTOCAL_HEADROOM_TARGET_LUMINANCE > 0);
			  return undef;
			 }
			 return target_luminance_for_step($white_y,$step,$target_gamma,$signal_mode);
		}

sub body_luma_bias_display_allowed {
	 my ($config)=@_;
	 return 0 if(ref($config) ne "HASH");
	 return 1 if($config->{"body_luma_bias_display_opt_in"} || $config->{"body_luma_bias_allow_non_c2"});
	 my $display=lc($config->{"display_type"}||"");
	 return ($display =~ /lg[_ -]?c2/) ? 1 : 0;
}

sub body_luma_bias_pct_for_step {
	 my ($config,$ire)=@_;
	 my $pct=(ref($config) eq "HASH" && defined($config->{"body_luma_bias_pct"})) ? ($config->{"body_luma_bias_pct"}+0) : 0.0065;
	 my $source="scalar";
	 my $matrix=(ref($config) eq "HASH" && ref($config->{"body_luma_bias_matrix_pct"}) eq "HASH") ? $config->{"body_luma_bias_matrix_pct"} : undef;
	 $matrix=$config->{"body_luma_bias_matrix"} if(ref($config) eq "HASH" && ref($config->{"body_luma_bias_matrix"}) eq "HASH" && ref($matrix) ne "HASH");
	 if(ref($matrix) eq "HASH" && defined($ire)) {
	  foreach my $key (keys %$matrix) {
	   next if(!defined($key) || !defined($matrix->{$key}));
	   if(abs(($key+0)-($ire+0)) < 0.001) {
	    $pct=$matrix->{$key}+0;
	    $source="matrix";
	    last;
	   }
	  }
	 }
	 if($source eq "matrix") {
	  $pct=-0.12 if($pct < -0.12);
	  $pct=0.12 if($pct > 0.12);
	 } else {
	  $pct=0 if($pct < 0);
	 }
	 if($source ne "matrix" && defined($ire) && abs($ire-60) < 0.001 && $pct > 0.004) {
	  $pct=0.004;
	  $source="scalar_cap60";
	 }
	 return ($pct,$source);
}

sub body_luma_bias_decision {
	 my ($config,$state,$step,$target_gamma,$signal_mode,$base_target_y)=@_;
	 my $mode=(ref($config) eq "HASH" && defined($config->{"body_luma_bias_mode"})) ? lc($config->{"body_luma_bias_mode"}) : "observe";
	 $mode="observe" if($mode ne "apply");
	 my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : undef;
	 my ($bias_pct,$bias_source)=body_luma_bias_pct_for_step($config,$ire);
	 my $reason="eligible";
	 my $eligible=1;
 if(ref($config) ne "HASH" || !$config->{"lg_autocal_26"}) {
  ($eligible,$reason)=(0,"not_lg_autocal_26");
 } elsif(!$config->{"patch_insert"}) {
  ($eligible,$reason)=(0,"patch_insert_disabled");
 } elsif(($signal_mode||"") ne "sdr") {
  ($eligible,$reason)=(0,"not_sdr");
	 } elsif(!body_luma_bias_display_allowed($config)) {
	  ($eligible,$reason)=(0,"display_not_c2");
	 } elsif(!defined($ire) || ($bias_source ne "matrix" && !grep { abs($ire-$_) < 0.001 } (55,60,65,70,75,80,85))) {
	  ($eligible,$reason)=(0,"ire_not_eligible");
	 } elsif(!defined($base_target_y) || $base_target_y <= 0) {
	  ($eligible,$reason)=(0,"missing_target");
	 }
	 my $applied=($eligible && $mode eq "apply" && ($bias_source eq "matrix" ? abs($bias_pct) > 0.0000001 : $bias_pct > 0)) ? 1 : 0;
	 my $effective_target_y=$applied ? $base_target_y*(1+$bias_pct) : $base_target_y;
	 if(defined($ire) && ($bias_source eq "matrix" || grep { abs($ire-$_) < 0.001 } (55,60,65,70,75,80,85))) {
  trace_109($step,"body_luma_bias_decision",{
   ire=>defined($ire)?$ire+0:undef,
   mode=>$mode,
   base_target_y=>defined($base_target_y)?$base_target_y+0:undef,
   biased_target_y=>defined($effective_target_y)?$effective_target_y+0:undef,
	   effective_target_y=>defined($effective_target_y)?$effective_target_y+0:undef,
	   bias_pct=>$bias_pct+0,
	   bias_source=>$bias_source,
	   bias_applied=>$applied?JSON::PP::true:JSON::PP::false,
	   applied=>$applied?JSON::PP::true:JSON::PP::false,
   bias_disabled_reason=>$applied ? undef : $reason,
   reason=>$applied ? "applied" : $reason
  });
 }
 return $effective_target_y;
}

sub effective_target_luminance_for_autocal_reading {
 my ($white_y,$step,$reading,$target_gamma,$signal_mode,$config,$state)=@_;
 my $target=target_luminance_for_autocal_step($white_y,$step,$target_gamma,$signal_mode);
 if(!defined($target) && autocal_step_is_peak_headroom($step)) {
  my $Y=luminance($reading);
  return $Y if(defined($Y) && $Y > 0);
 }
 $target=body_luma_bias_decision($config || $LG_AUTOCAL_CONFIG,$state || $LG_AUTOCAL_STATE,$step,$target_gamma,$signal_mode,$target);
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
	  $state->{"peak_headroom_measured_reference"}=$derived if(defined($derived) && $derived > 0);
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
	 return $$white_y_ref if(!defined($effective_white) || $effective_white <= 0);
		 annotate_reading_target($reading,$effective_white,$reading_y,$target_x,$target_y) if(ref($reading) eq "HASH" && defined($reading_y) && $reading_y > 0);
		 return $effective_white;
	}

sub keep_peak_headroom_white_reference {
	 my ($config,$state)=@_;
	 return 0 if(ref($config) ne "HASH" || !$config->{"lg_autocal_26"});
	 return 0 if(ref($state) ne "HASH");
	 return (defined($state->{"peak_headroom_reference"}) && ($state->{"peak_headroom_reference"}+0) > 0) ? 1 : 0;
}

sub update_white_reference_for_autocal_step {
	 my ($config,$state,$step,$reading,$white_y)=@_;
	 return $white_y if(keep_peak_headroom_white_reference($config,$state) && !autocal_step_is_peak_headroom($step));
	 return update_white_reference_for_step($step,$reading,$white_y);
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

sub refresh_headroom_targets_after_white_reference {
 my ($state,$step,$white_y,$target_x,$target_y,$target_gamma,$signal_mode)=@_;
 return 0 if(!autocal_step_is_white($step));
 return refresh_headroom_targets_from_white_reference($state,$white_y,$target_x,$target_y,$target_gamma,$signal_mode);
}

sub headroom_reference_white_from_target {
 my ($config,$steps,$target_gamma,$signal_mode)=@_;
 return undef if(ref($config) ne "HASH");
 my $headroom_y=$LG_AUTOCAL_HEADROOM_TARGET_LUMINANCE;
 $headroom_y=$config->{"headroom_target_luminance"}+0 if((!defined($headroom_y) || $headroom_y <= 0) && defined($config->{"headroom_target_luminance"}));
 return undef if(!defined($headroom_y) || $headroom_y <= 0);
 my $peak_step=undef;
 if(ref($steps) eq "ARRAY") {
  foreach my $candidate (@{$steps}) {
   next if(ref($candidate) ne "HASH");
   my $fixed=fixed_lg_autocal_step($config,$candidate);
   next if(!autocal_step_is_peak_headroom($fixed));
   if(!defined($peak_step) || (($fixed->{"ire"}||0)+0) > (($peak_step->{"ire"}||0)+0)) {
    $peak_step=$fixed;
   }
  }
 }
 return undef if(ref($peak_step) ne "HASH");
 my $stimulus=defined($peak_step->{"stimulus"}) ? ($peak_step->{"stimulus"}+0) : (defined($peak_step->{"ire"}) ? ($peak_step->{"ire"}+0) : undef);
 return undef if(!defined($stimulus) || $stimulus <= 0);
 my $signal=$stimulus/100;
 $signal=1.1 if($signal > 1.1);
 my $linear=target_gamma_linear($signal,$target_gamma,$signal_mode);
 return undef if(!defined($linear) || $linear <= 0);
 my $white_y=$headroom_y/$linear;
 return ($white_y > 0 && $white_y < 10000) ? $white_y : undef;
}

sub committed_polish_reference_white_y {
 my ($config,$state,$steps,$target_gamma,$signal_mode,$fallback)=@_;
 if(ref($state) eq "HASH" && defined($state->{"committed_polish_white_y"}) && ($state->{"committed_polish_white_y"}+0) > 0) {
  return $state->{"committed_polish_white_y"}+0;
 }
 if(ref($state) eq "HASH" && defined($state->{"peak_headroom_reference"}) && ($state->{"peak_headroom_reference"}+0) > 0) {
  return $state->{"peak_headroom_reference"}+0;
 }
 if(ref($state) eq "HASH" && ref($state->{"readings"}) eq "ARRAY") {
  my $best_ire=-1;
  my $best_ref=undef;
  foreach my $reading (@{$state->{"readings"}}) {
   next if(ref($reading) ne "HASH" || !defined($reading->{"ire"}));
   my $step=fixed_lg_autocal_step($config,clone_picture($reading));
   next if(!autocal_step_is_peak_headroom($step));
   my $derived=derived_white_reference_from_peak_headroom($step,$reading,$target_gamma,$signal_mode);
   next if(!defined($derived) || $derived <= 0);
   my $ire=$step->{"ire"}+0;
   if($ire > $best_ire) {
    $best_ire=$ire;
    $best_ref=$derived;
   }
  }
  return $best_ref if(defined($best_ref) && $best_ref > 0);
 }
 my $from_headroom=headroom_reference_white_from_target($config,$steps,$target_gamma,$signal_mode);
 return $from_headroom if(defined($from_headroom) && $from_headroom > 0);
 if(ref($state) eq "HASH" && defined($state->{"target_luminance"}) && ($state->{"target_luminance"}+0) > 0) {
  return $state->{"target_luminance"}+0;
 }
 return (defined($fallback) && $fallback > 0) ? $fallback : undef;
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
 return ($ire > 0 && $ire <= 10.0001) ? 1 : 0;
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

sub delta_e_luv_chroma {
 my ($reading,$white_y,$target_x,$target_y)=@_;
 return undef if(ref($reading) ne "HASH");
 my $x=$reading->{"x"};
 my $y=$reading->{"y"};
 my $Y=luminance($reading);
 return undef if(!defined($x) || !defined($y) || !defined($Y) || !defined($white_y) || $white_y <= 0);
 return undef if($x <= 0 || $y <= 0);
 my ($u,$v)=uv_prime($x+0,$y+0);
 my ($tu,$tv)=uv_prime($target_x,$target_y);
 my $L=lstar($Y/$white_y);
 return 13*$L*sqrt(($u-$tu)*($u-$tu)+($v-$tv)*($v-$tv));
}

sub delta_e_luv_gamma {
 my ($reading,$white_y,$target_x,$target_y,$target_luminance)=@_;
 my $chroma=delta_e_luv_chroma($reading,$white_y,$target_x,$target_y);
 return $chroma if(!defined($target_luminance) || !defined($white_y) || $white_y <= 0 || $target_luminance <= 0);
 my $Y=luminance($reading);
 return $chroma if(!defined($Y));
 my $luma=abs(lstar($Y/$white_y)-lstar($target_luminance/$white_y));
 $chroma=0 if(!defined($chroma));
 return sqrt($chroma*$chroma + $luma*$luma);
}

sub xyz_from_xy_y {
 my ($x,$y,$Y)=@_;
 return (undef,undef,undef) if(!defined($x) || !defined($y) || !defined($Y));
 $x+=0; $y+=0; $Y+=0;
 return (undef,undef,undef) if($y <= 0);
 return (($x*$Y)/$y,$Y,((1-$x-$y)*$Y)/$y);
}

sub reading_xyz {
 my ($reading)=@_;
 return (undef,undef,undef) if(ref($reading) ne "HASH");
 if(defined($reading->{"X"}) && defined($reading->{"Y"}) && defined($reading->{"Z"})) {
  return ($reading->{"X"}+0,$reading->{"Y"}+0,$reading->{"Z"}+0);
 }
 my $Y=luminance($reading);
 return (undef,undef,undef) if(!defined($Y) || !defined($reading->{"x"}) || !defined($reading->{"y"}));
 return xyz_from_xy_y($reading->{"x"},$reading->{"y"},$Y);
}

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

sub delta_e_itp_gamma {
 my ($reading,$white_y,$target_x,$target_y,$target_luminance)=@_;
 my ($X,$Y,$Z)=reading_xyz($reading);
 return undef if(!defined($X) || !defined($Y) || !defined($Z));
 my $targetY=(defined($target_luminance) && $target_luminance > 0) ? ($target_luminance+0) : $Y;
 my ($Xr,$Yr,$Zr)=xyz_from_xy_y($target_x,$target_y,$targetY);
 return undef if(!defined($Xr) || !defined($Yr) || !defined($Zr));
 return delta_e_itp_xyz($X,$Y,$Z,$Xr,$Yr,$Zr);
}

sub normalize_autocal_delta_e_formula {
 return "deitp";
}

sub autocal_delta_e_formula {
 my ($config)=@_;
 if(ref($config) eq "HASH") {
  foreach my $key (qw(delta_e_formula de_formula grey_delta_e_formula)) {
   return normalize_autocal_delta_e_formula($config->{$key}) if(defined($config->{$key}));
  }
 }
 return normalize_autocal_delta_e_formula($LG_AUTOCAL_DELTA_E_FORMULA);
}

sub autocal_uses_itp {
	 return $LG_AUTOCAL_DELTA_E_FORMULA eq "deitp" ? 1 : 0;
}

sub autocal_itp_precision_polish_needed {
	 my ($de,$target_delta,$step)=@_;
	 return 0 if(!autocal_uses_itp());
	 return 0 if(!defined($de));
	 return 0 if(autocal_step_is_fast_headroom($step));
	 return 0 if(autocal_step_is_low_shadow($step));
	 $target_delta=0.5 if(!defined($target_delta) || $target_delta <= 0);
	 return 0 if(body_itp_near_target_reached($step,$de,undef,$target_delta));
	 return ($de > ($target_delta+0.12)) ? 1 : 0;
}

sub autocal_itp_precision_stall_limit {
 my ($de,$target_delta,$step)=@_;
	 if(autocal_step_is_low_shadow($step)) {
	  my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : 5;
	  return 2 if($ire <= 3.1001);
	  return 3 if($ire <= 5.1001);
	  return 4;
	 }
	 return autocal_itp_precision_polish_needed($de,$target_delta,$step) ? 28 : 14;
}

sub autocal_delta_e {
	 my ($config,$reading,$white_y,$target_x,$target_y,$target_luminance)=@_;
	 return delta_e_itp_gamma($reading,$white_y,$target_x,$target_y,$target_luminance)
	  if(autocal_delta_e_formula($config) eq "deitp");
	 return delta_e_luv_gamma($reading,$white_y,$target_x,$target_y,$target_luminance);
}

sub autocal_delta_target_luminance_for_step {
		 my ($reading,$step,$target_luminance)=@_;
		 if(autocal_step_ignores_luminance_error($step)) {
		  my $Y=luminance($reading);
		  return $Y if(defined($Y) && $Y > 0);
		 }
		 return $target_luminance;
}

sub autocal_delta_e_for_step {
	 my ($config,$reading,$step,$white_y,$target_x,$target_y,$target_luminance)=@_;
	 my $delta_target_luminance=autocal_delta_target_luminance_for_step($reading,$step,$target_luminance);
	 return autocal_delta_e($config,$reading,$white_y,$target_x,$target_y,$delta_target_luminance);
}

sub autocal_chroma_delta_e_for_step {
	 my ($config,$reading,$step,$white_y,$target_x,$target_y)=@_;
	 return undef if(ref($reading) ne "HASH");
	 my $Y=luminance($reading);
	 return undef if(!defined($Y) || $Y <= 0);
	 return autocal_delta_e($config,$reading,$white_y,$target_x,$target_y,$Y);
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
				 # 105%+ are headroom/chroma points. Let luminance steer them only when
				 # it is clearly out of range; small Y misses otherwise cause cycling.
				 return 8 if(autocal_step_is_peak_headroom($step));
				 return 1 if($ire >= 105);
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

sub headroom_luminance_control_gate_percent {
 my ($step,$fraction)=@_;
 my $tol=luminance_tolerance_percent($step);
 return $tol if(autocal_step_is_peak_headroom($step));
 $fraction=1 if(!defined($fraction));
 return $tol*$fraction;
}

sub low_shadow_delta_acceptance {
 my ($step,$target_delta)=@_;
 $target_delta=0.5 if(!defined($target_delta) || $target_delta <= 0);
 return $target_delta if(!autocal_step_is_low_shadow($step));
 my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : 5;
 if(autocal_uses_itp()) {
  return $target_delta;
 }
 my $limit=($ire <= 3.1) ? 5.0 : 4.0;
 my $floor=$target_delta+0.75;
 return $limit > $floor ? $limit : $floor;
}

sub itp_luminance_included_acceptance_limit {
 my ($step)=@_;
 return undef if(!autocal_uses_itp());
 return undef if(autocal_step_ignores_luminance_error($step));
 return undef if(ref($step) ne "HASH" || !defined($step->{"ire"}));
 my $ire=$step->{"ire"}+0;
 return 1.0 if($ire >= 99 && $ire <= 105.0001);
 return undef;
}

sub within_itp_luminance_included_acceptance {
 my ($de,$step)=@_;
 my $limit=itp_luminance_included_acceptance_limit($step);
 return 1 if(!defined($limit));
 return (defined($de) && $de <= $limit) ? 1 : 0;
}

sub low_shadow_luminance_acceptance_percent {
 my ($step)=@_;
 my $tol=luminance_tolerance_percent($step);
 my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : 5;
 my $extra=($ire <= 3.1001) ? 1.5 : (($ire <= 5.1001) ? 1.2 : 0.8);
 return $tol+$extra;
}

sub low_shadow_luminance_close_enough {
 my ($step,$lum_pct)=@_;
 return 1 if(!defined($lum_pct));
 return 0 if(low_ire_luminance_needs_lift($step,$lum_pct));
 return abs($lum_pct) <= low_shadow_luminance_acceptance_percent($step) ? 1 : 0;
}

sub low_shadow_itp_near_target_reached {
 my ($step,$de,$lum_pct,$target_delta)=@_;
 return 0 if(!autocal_step_is_low_shadow($step));
 return 0 if(!autocal_uses_itp());
 return 0 if(!defined($de));
 $target_delta=0.5 if(!defined($target_delta) || $target_delta <= 0);
 return 0 if(!low_shadow_luminance_close_enough($step,$lum_pct));
 return ($de <= $target_delta) ? 1 : 0;
}

sub low_shadow_good_enough {
 my ($step,$de,$lum_pct,$target_delta)=@_;
 return 0 if(!autocal_step_is_low_shadow($step));
 return 0 if(!defined($de));
 $target_delta=0.5 if(!defined($target_delta) || $target_delta <= 0);
 if(autocal_uses_itp()) {
  return 0 if(!low_shadow_luminance_close_enough($step,$lum_pct));
  return ($de <= $target_delta) ? 1 : 0;
 }
 return ($de <= low_shadow_delta_acceptance($step,$target_delta)) ? 1 : 0;
}

sub committed_low_shadow_good_enough {
 my ($step,$de,$lum_pct,$target_delta)=@_;
 return 0 if(!autocal_step_is_low_shadow($step));
 return 0 if(!defined($de));
 $target_delta=0.5 if(!defined($target_delta) || $target_delta <= 0);
 my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : 5;
 my $allow=($ire <= 3.1001) ? ($target_delta+0.30) : (($ire <= 4.1001) ? ($target_delta+0.28) : (($ire <= 5.1001) ? ($target_delta+0.25) : ($target_delta+0.25)));
 return 0 if(autocal_uses_itp() && !low_shadow_luminance_close_enough($step,$lum_pct));
 return ($de <= $allow) ? 1 : 0;
}

sub body_itp_near_target_reached {
 my ($step,$de,$lum_pct,$target_delta)=@_;
 return 0 if(!autocal_uses_itp());
 return 0 if(!defined($de));
 return 0 if(ref($step) ne "HASH" || !defined($step->{"ire"}));
 return 0 if(autocal_step_is_fast_headroom($step) || autocal_step_is_low_shadow($step) || autocal_step_is_white($step));
 my $ire=$step->{"ire"}+0;
 return 0 if($ire <= 10.0001 || $ire >= 99);
 $target_delta=0.5 if(!defined($target_delta) || $target_delta <= 0);
 return ($de <= ($target_delta+0.25)) ? 1 : 0;
}

sub target_reached {
			 my ($de,$lum_pct,$target_delta,$step)=@_;
				 return 0 if(!defined($de));
				 my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : 100;
				 return 1 if(low_shadow_itp_near_target_reached($step,$de,$lum_pct,$target_delta));
				 return 0 if(low_ire_luminance_needs_lift($step,$lum_pct));
					 return 0 if(low_ire_luminance_needs_tuning($step,$lum_pct));
					 return 1 if(autocal_step_is_low_shadow($step) && $de <= low_shadow_delta_acceptance($step,$target_delta));
					 return 1 if(body_itp_near_target_reached($step,$de,$lum_pct,$target_delta));
				 return 0 if(!within_itp_luminance_included_acceptance($de,$step));
				 my $low_delta_allow=autocal_uses_itp() ? 0 : (($ire <= 10) ? 0.75 : 0.30);
				 return 0 if($de > $target_delta && !($ire <= 10 && $de <= $target_delta+$low_delta_allow));
			 return 1 if($ire >= 99.9 && !defined($lum_pct));
			 return 1 if(!defined($lum_pct));
			 return 1 if(autocal_result_score($de,$lum_pct,$step) <= $target_delta+0.08);
		 return abs($lum_pct) <= luminance_tolerance_percent($step);
}

sub max_defined_delta {
 my @values=grep { defined($_) } @_;
 return undef if(!@values);
 my $max=$values[0];
 foreach my $value (@values) {
  $max=$value if($value > $max);
 }
 return $max;
}

sub committed_polish_far_from_target {
 my ($de,$target_delta)=@_;
 return 0 if(!defined($de));
 $target_delta=0.5 if(!defined($target_delta) || $target_delta <= 0);
 return ($de > ($target_delta*2.0)) ? 1 : 0;
}

sub committed_polish_stall_limit {
 my ($step,$de,$target_delta)=@_;
 my $limit=2;
 $limit=3 if(autocal_step_is_low_shadow($step));
 if(committed_polish_far_from_target($de,$target_delta)) {
  $limit=autocal_step_is_low_shadow($step) ? 5 : 4;
 }
 return $limit;
}

sub committed_polish_min_iteration_limit {
 my ($step,$de,$target_delta)=@_;
 return 0 if(!committed_polish_far_from_target($de,$target_delta));
 return autocal_step_is_low_shadow($step) ? 5 : 4;
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
	 if(low_shadow_good_enough($step,$best_de,$best_lum_pct,$target_delta)) {
	  if(autocal_step_is_low_shadow($step)) {
	   return 1 if($ire <= 3.1001 && ($iter||0) >= 2 && ($stalls||0) >= 1);
	   return 1 if($ire <= 3.1001 && ($iter||0) >= 4);
	   return 1 if($ire <= 5.1001 && ($iter||0) >= 3 && ($stalls||0) >= 1);
	   return 1 if($ire <= 5.1001 && ($iter||0) >= 5);
	   return 1 if(($iter||0) >= 4 && ($stalls||0) >= 1);
	   return 1 if(($iter||0) >= 6);
	  }
	  return 1 if(($iter||0) >= 4 && ($stalls||0) >= 2);
	  return 1 if(($iter||0) >= 7);
	 }
	 if(body_itp_near_target_reached($step,$best_de,$best_lum_pct,$target_delta)) {
	  return 1 if(($iter||0) >= 4 && ($stalls||0) >= 1 && $best_de <= ($target_delta+0.25));
	  return 1 if(($iter||0) >= 5 && ($stalls||0) >= 2);
	  return 1 if(($iter||0) >= 8 && ($stalls||0) >= 3);
		 }
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
			 if(autocal_uses_itp()) {
				 if(autocal_step_is_low_shadow($step) && autocal_uses_itp() && defined($lum_pct)) {
				  my $shadow_lum_excess=abs($lum_pct)-low_shadow_luminance_acceptance_percent($step);
				  return $score if($shadow_lum_excess <= 0);
				  my $shadow_lum_penalty=$shadow_lum_excess*0.45;
				  $shadow_lum_penalty=4 if($shadow_lum_penalty > 4);
				  return $score+$shadow_lum_penalty;
				 }
				 return $score;
			 }
			 return $score if($ire <= 5 && $score <= 4.0 && !low_ire_luminance_needs_tuning($step,$lum_pct));
			 return $score if(!defined($lum_pct));
		 my $tol=luminance_tolerance_percent($step);
		 my $excess=abs($lum_pct)-$tol;
		 return $score if($excess <= 0);
		 # The AutoCal delta score already contains a perceptual luminance term. Keep
		 # Y/gamma as a tie-breaker, but do not let it preserve a visibly worse
		 # RGB balance just because the luminance was slightly closer.
		 my $penalty=$excess*0.35;
		 $penalty=4 if($penalty > 4);
		 return $score+$penalty;
}

sub autocal_measurement_not_worse_than_best {
 my ($de,$lum_pct,$best_de,$best_lum_pct)=@_;
 return 0 if(!defined($de));
 return 1 if(!defined($best_de));
 my $de_delta=($de+0)-($best_de+0);
 return 1 if($de_delta < -0.0001);
 return 0 if($de_delta > 0.0001);
 if(defined($lum_pct) && defined($best_lum_pct)) {
  return 0 if(abs($lum_pct) > abs($best_lum_pct)+0.05);
 }
 return 1;
}

sub lg_autocal_26_best_known_key {
 my ($step_or_ire)=@_;
 my $ire;
 if(ref($step_or_ire) eq "HASH") {
  $ire=$step_or_ire->{"ire"} if(defined($step_or_ire->{"ire"}));
 } else {
  $ire=$step_or_ire if(defined($step_or_ire));
 }
 return undef if(!defined($ire));
 return format_percent($ire);
}

sub lg_autocal_26_measurement_score {
 my ($step,$de,$lum_pct)=@_;
 return autocal_result_score($de,$lum_pct,$step);
}

sub lg_autocal_26_candidate_better_than_entry {
 my ($step,$de,$lum_pct,$entry)=@_;
 return 0 if(!defined($de));
 return 1 if(ref($entry) ne "HASH" || !defined($entry->{"delta_e"}));
 my $score=lg_autocal_26_measurement_score($step,$de,$lum_pct);
 my $best_score=defined($entry->{"score"}) ? ($entry->{"score"}+0) : lg_autocal_26_measurement_score($step,$entry->{"delta_e"},$entry->{"luminance_error_pct"});
 return 1 if($score + 0.0001 < $best_score);
 return 0 if($score > $best_score + 0.0001);
 return autocal_measurement_not_worse_than_best($de,$lum_pct,$entry->{"delta_e"},$entry->{"luminance_error_pct"});
}

sub lg_autocal_26_best_known_entry {
 my ($step,$reading,$de,$lum_pct,$target_luminance,$arrays,$target,$reason)=@_;
 return undef if(ref($step) ne "HASH" || ref($reading) ne "HASH" || !defined($de));
 my $score=lg_autocal_26_measurement_score($step,$de,$lum_pct);
 return {
  ire=>($step->{"ire"}+0),
  delta_e=>$de+0,
  luminance_error_pct=>defined($lum_pct) ? ($lum_pct+0) : undef,
  target_luminance=>defined($target_luminance) ? ($target_luminance+0) : undef,
  score=>$score+0,
  reason=>$reason||"best_known",
  reading=>trace_reading_summary($reading),
  ddc_values=>trace_target_values($arrays,$target),
 };
}

sub remember_lg_autocal_26_best_known {
 my ($config,$state,$step,$reading,$de,$lum_pct,$target_luminance,$arrays,$target,$reason)=@_;
 return if(ref($config) ne "HASH" || !$config->{"lg_autocal_26"});
 return if(ref($state) ne "HASH");
 my $entry=lg_autocal_26_best_known_entry($step,$reading,$de,$lum_pct,$target_luminance,$arrays,$target,$reason);
 return if(ref($entry) ne "HASH");
 my $key=lg_autocal_26_best_known_key($step);
 return if(!defined($key));
 $state->{"lg_autocal_26_best_known"}={} if(ref($state->{"lg_autocal_26_best_known"}) ne "HASH");
 my $existing=$state->{"lg_autocal_26_best_known"}{$key};
 return if(!lg_autocal_26_candidate_better_than_entry($step,$de,$lum_pct,$existing));
 $state->{"lg_autocal_26_best_known"}{$key}=$entry;
}

sub lg_autocal_26_best_known_for_step {
	 my ($state,$step)=@_;
	 return undef if(ref($state) ne "HASH" || ref($state->{"lg_autocal_26_best_known"}) ne "HASH");
	 my $key=lg_autocal_26_best_known_key($step);
	 return undef if(!defined($key));
	 my $entry=$state->{"lg_autocal_26_best_known"}{$key};
	 return (ref($entry) eq "HASH") ? $entry : undef;
	}

sub remember_lg_autocal_26_response_axis {
	 my ($bucket,$group,$axis,$slope,$delta,$before_error,$after_error,$source)=@_;
	 return undef if(ref($bucket) ne "HASH" || !defined($group) || !defined($axis));
	 return undef if(!defined($slope) || abs($slope) < 0.000001 || !defined($delta) || abs($delta) < 0.0001);
	 $bucket->{$group}={} if(ref($bucket->{$group}) ne "HASH");
	 my $existing=$bucket->{$group}{$axis};
	 my $samples=1;
	 if(ref($existing) eq "HASH" && defined($existing->{"slope"})) {
	  my $old=$existing->{"slope"}+0;
	  if(($old < 0 && $slope < 0) || ($old > 0 && $slope > 0)) {
	   my $old_samples=$existing->{"samples"}||1;
	   $old_samples=5 if($old_samples > 5);
	   $slope=(($old*$old_samples)+$slope)/($old_samples+1);
	   $samples=($existing->{"samples"}||1)+1;
	  }
	 }
	 $bucket->{$group}{$axis}={
	  slope=>$slope+0,
	  samples=>$samples+0,
	  delta=>$delta+0,
	  before_error=>defined($before_error) ? ($before_error+0) : undef,
	  after_error=>defined($after_error) ? ($after_error+0) : undef,
	  source=>$source||"calibration",
	  updated_at=>time()+0
	 };
	 return $bucket->{$group}{$axis};
	}

sub remember_lg_autocal_26_response_model {
	 my ($config,$state,$step,$adjustments,$before,$after,$source)=@_;
	 return undef if(ref($config) ne "HASH" || !$config->{"lg_autocal_26"});
	 return undef if(ref($state) ne "HASH" || ref($step) ne "HASH");
	 return undef if(ref($adjustments) ne "ARRAY" || @{$adjustments} != 1);
	 return undef if(ref($before) ne "HASH" || ref($after) ne "HASH");
	 my $adj=$adjustments->[0];
	 return undef if(ref($adj) ne "HASH");
	 my $delta=defined($adj->{"delta"}) ? ($adj->{"delta"}+0) : undef;
	 if(!defined($delta) && defined($adj->{"current"}) && defined($adj->{"next"})) {
	  $delta=($adj->{"next"}+0)-($adj->{"current"}+0);
	 }
	 return undef if(!defined($delta) || abs($delta) < 0.0001 || abs($delta) > 12.0001);
	 my $key=lg_autocal_26_best_known_key($step);
	 return undef if(!defined($key));
	 $state->{"lg_autocal_26_response_model"}={} if(ref($state->{"lg_autocal_26_response_model"}) ne "HASH");
	 $state->{"lg_autocal_26_response_model"}{$key}={} if(ref($state->{"lg_autocal_26_response_model"}{$key}) ne "HASH");
	 my $bucket=$state->{"lg_autocal_26_response_model"}{$key};
	 my %updates;
	 my $ch=$adj->{"channel"}||"";
	 if($ch =~ /^(?:r|g|b)$/) {
	  my $before_err=autocal_adjustment_error($before,$step);
	  my $after_err=autocal_adjustment_error($after,$step);
	  if(ref($before_err) eq "HASH" && ref($after_err) eq "HASH" && defined($before_err->{$ch}) && defined($after_err->{$ch})) {
	   my $slope=(($after_err->{$ch}+0)-($before_err->{$ch}+0))/$delta;
	   my $entry=remember_lg_autocal_26_response_axis($bucket,"rgb",$ch,$slope,$delta,$before_err->{$ch},$after_err->{$ch},$source);
	   $updates{"rgb"}{$ch}=$entry if(ref($entry) eq "HASH");
	  }
	 }
	 if(($adj->{"setting"}||"") eq "adjustingLuminance") {
	  my $target_y=$after->{"target_luminance"};
	  $target_y=$before->{"target_luminance"} if(!defined($target_y));
	  if(defined($target_y) && $target_y > 0) {
	   my $before_lum_pct=luminance_error_percent($before,$target_y);
	   my $after_lum_pct=luminance_error_percent($after,$target_y);
	   if(defined($before_lum_pct) && defined($after_lum_pct)) {
	    my $slope=($after_lum_pct-$before_lum_pct)/$delta;
	    my $entry=remember_lg_autocal_26_response_axis($bucket,"luminance","adjustingLuminance",$slope,$delta,$before_lum_pct,$after_lum_pct,$source);
	    $updates{"luminance"}{"adjustingLuminance"}=$entry if(ref($entry) eq "HASH");
	   }
	  }
	 }
	 return %updates ? \%updates : undef;
	}

sub lg_autocal_26_response_model_for_step {
	 my ($state,$step)=@_;
	 return undef if(ref($state) ne "HASH" || ref($state->{"lg_autocal_26_response_model"}) ne "HASH");
	 my $key=lg_autocal_26_best_known_key($step);
	 return undef if(!defined($key));
	 my $entry=$state->{"lg_autocal_26_response_model"}{$key};
	 return (ref($entry) eq "HASH") ? $entry : undef;
	}

sub lg_autocal_26_learned_luminance_adjustment {
	 my ($state,$arrays,$target,$step,$lum_pct,$tried,$cap,$source)=@_;
	 return undef if(ref($arrays) ne "HASH" || ref($target) ne "HASH" || !defined($lum_pct));
	 return undef if(!has_luminance_channel($arrays,$target));
	 my $model=lg_autocal_26_response_model_for_step($state,$step);
	 my $entry=(ref($model) eq "HASH" && ref($model->{"luminance"}) eq "HASH") ? $model->{"luminance"}{"adjustingLuminance"} : undef;
	 return undef if(ref($entry) ne "HASH" || !defined($entry->{"slope"}));
	 my $tol=luminance_tolerance_percent($step);
	 return undef if(defined($tol) && abs($lum_pct) <= $tol);
	 my $slope=$entry->{"slope"}+0;
	 return undef if(abs($slope) < 0.05);
	 my $idx=$target->{"index"};
	 return undef if(!defined($idx) || ref($arrays->{"adjustingLuminance"}) ne "ARRAY");
	 my $current=$arrays->{"adjustingLuminance"}[$idx]||0;
	 my $raw_delta=-($lum_pct+0)/$slope;
	 return undef if(abs($raw_delta) < 0.10);
	 $cap=final_all_level_verify_adjustment_cap($step,"adjustingLuminance") if(!defined($cap) || $cap <= 0);
	 $raw_delta=$cap if($raw_delta > $cap);
	 $raw_delta=-$cap if($raw_delta < -$cap);
	 foreach my $scale (1,0.75,0.50,0.25) {
	  my $next=round_ddc_quarter($current+($raw_delta*$scale));
	  next if(abs($next-$current) < 0.0999);
	  next if(tried_value_exists($tried,"adjustingLuminance",$next));
	  my $actual_delta=$next-$current;
	  my $predicted=($lum_pct+0)+($slope*$actual_delta);
	  next if(abs($predicted) >= abs($lum_pct)*0.92 && abs($actual_delta) > 0.21);
	  return [{ channel=>"lum", setting=>"adjustingLuminance", current=>$current, next=>$next, delta=>$actual_delta, response_model=>1, learned_response_model=>1, slope=>$slope, predicted_error=>$predicted, source=>$source||"learned_luminance", samples=>$entry->{"samples"}||1 }];
	 }
	 return undef;
	}

sub lg_autocal_26_learned_rgb_adjustment {
	 my ($state,$arrays,$target,$step,$reading,$de,$target_delta,$tried,$cap,$source)=@_;
	 return undef if(ref($arrays) ne "HASH" || ref($target) ne "HASH" || ref($reading) ne "HASH");
	 return undef if(autocal_step_is_peak_headroom($step));
	 my $model=lg_autocal_26_response_model_for_step($state,$step);
	 return undef if(ref($model) ne "HASH" || ref($model->{"rgb"}) ne "HASH");
	 my $error=autocal_adjustment_error($reading,$step);
	 return undef if(ref($error) ne "HASH");
	 my ($ch,$err,$max_err)=furthest_rgb_error_channel($error);
	 return undef if(!$ch);
	 my $threshold=rgb_response_close_threshold($de,$target_delta);
	 return undef if($max_err < $threshold);
	 my $entry=$model->{"rgb"}{$ch};
	 return undef if(ref($entry) ne "HASH" || !defined($entry->{"slope"}));
	 my $slope=$entry->{"slope"}+0;
	 return undef if(abs($slope) < 0.00005);
	 my $setting=channel_setting($ch);
	 my $idx=$target->{"index"};
	 return undef if(!defined($idx) || ref($arrays->{$setting}) ne "ARRAY");
	 my $current=$arrays->{$setting}[$idx]||0;
	 my $raw_delta=-($err+0)/$slope;
	 return undef if(abs($raw_delta) < 0.10);
	 $cap=final_all_level_verify_adjustment_cap($step,$setting) if(!defined($cap) || $cap <= 0);
	 $raw_delta=$cap if($raw_delta > $cap);
	 $raw_delta=-$cap if($raw_delta < -$cap);
	 foreach my $scale (1,0.75,0.50,0.25) {
	  my $next=round_ddc_quarter($current+($raw_delta*$scale));
	  next if(abs($next-$current) < 0.0999);
	  next if(tried_value_exists($tried,$setting,$next));
	  my $actual_delta=$next-$current;
	  my $predicted=($err+0)+($slope*$actual_delta);
	  next if(abs($predicted) >= abs($err)*0.92 && abs($actual_delta) > 0.21);
	  return [{ channel=>$ch, setting=>$setting, current=>$current, next=>$next, delta=>$actual_delta, response_model=>1, learned_response_model=>1, slope=>$slope, predicted_error=>$predicted, source=>$source||"learned_rgb", samples=>$entry->{"samples"}||1 }];
	 }
	 return undef;
	}

sub lg_autocal_26_best_known_values_available {
 my ($entry,$target,$arrays)=@_;
 return 0 if(ref($entry) ne "HASH" || ref($entry->{"ddc_values"}) ne "HASH" || ref($target) ne "HASH" || ref($arrays) ne "HASH");
 my $idx=$target->{"index"};
 return 0 if(!defined($idx));
 foreach my $setting (qw(whiteBalanceRed whiteBalanceGreen whiteBalanceBlue adjustingLuminance)) {
  next if(!exists($entry->{"ddc_values"}{$setting}));
  return 1 if(ref($arrays->{$setting}) eq "ARRAY" && $idx < @{$arrays->{$setting}});
 }
 return 0;
}

sub lg_autocal_26_best_known_committed_state {
 my ($entry)=@_;
 return 0 if(ref($entry) ne "HASH");
 my $reason=$entry->{"reason"};
 return 0 if(!defined($reason));
 return 1 if($reason =~ /^(?:committed_|final_all_level_verify_|post_commit_|off_cal_)/);
 return 0;
}

sub lg_autocal_26_arrays_with_best_known_values {
 my ($arrays,$target,$entry)=@_;
 return undef if(!lg_autocal_26_best_known_values_available($entry,$target,$arrays));
 my $next=clone_arrays($arrays);
 my $idx=$target->{"index"};
 foreach my $setting (qw(whiteBalanceRed whiteBalanceGreen whiteBalanceBlue adjustingLuminance)) {
  next if(!exists($entry->{"ddc_values"}{$setting}));
  next if(ref($next->{$setting}) ne "ARRAY" || $idx >= @{$next->{$setting}});
  $next->{$setting}[$idx]=$entry->{"ddc_values"}{$setting}+0;
 }
 return $next;
}

sub headroom_autocal_result_score {
	 my ($de,$reading,$step)=@_;
	 my $err=rgb_error($reading);
	 return defined($de) ? ($de+0) : 9999 if(ref($err) ne "HASH");
	 return defined($de) ? ($de+0) : 9999 if(autocal_step_is_fast_headroom($step) && !autocal_step_is_peak_headroom($step));
	 my $max=0;
	 my $sum=0;
 foreach my $ch (qw(r g b)) {
  my $v=abs($err->{$ch}||0);
  $max=$v if($v > $max);
  $sum+=$v;
 }
 my $de_score=defined($de) ? ($de+0) : 9999;
 return $de_score+($max*12)+($sum*3);
}

sub headroom_rgb_balance_error {
 my ($reading,$step)=@_;
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
 my $fine=($ire >= 108.5) ? $target_delta : 0.28;
 $fine=$target_delta if($fine > $target_delta);
 return $fine;
}

sub headroom_needs_fine_tune {
	 my ($de,$target_delta,$reading,$step)=@_;
	 return 0 if(!autocal_step_is_fast_headroom($step));
 return 1 if(!defined($de));
 if(!autocal_step_is_peak_headroom($step) && ref($reading) eq "HASH" && defined($reading->{"target_luminance"})) {
  my $lum_pct=luminance_error_percent($reading,$reading->{"target_luminance"});
  return 1 if(defined($lum_pct) && abs($lum_pct) > luminance_tolerance_percent($step));
 }
 return 1 if($de > headroom_fine_target_delta($step,$target_delta));
	 return 1 if(!headroom_rgb_balanced($reading,$target_delta,$step));
	 return 0;
}

sub headroom_luminance_anchor_working_state {
	 my ($step,$lum_pct,$best_lum_pct,$de,$best_de)=@_;
	 return 0 if(!autocal_step_is_fast_headroom($step) || autocal_step_is_peak_headroom($step));
	 return 0 if(!defined($lum_pct));
	 my $tol=luminance_tolerance_percent($step);
	 return 0 if(!defined($tol) || $tol <= 0);
	 my $candidate_abs=abs($lum_pct);
	 my $best_abs=defined($best_lum_pct) ? abs($best_lum_pct) : 999;
	 return 1 if($candidate_abs <= $tol && $best_abs > $tol);
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
	  if(!autocal_step_is_peak_headroom($step) && defined($lum_pct)) {
	   my $excess=abs($lum_pct)-luminance_tolerance_percent($step);
	   if($excess > 0) {
	    my $penalty=$excess*0.35;
	    $penalty=4 if($penalty > 4);
	    $headroom_score+=$penalty;
	   }
	  }
	  return $headroom_score;
 }
 return $score;
}

sub guarded_target_reached {
 my ($de,$lum_pct,$target_delta,$step,$reading,$white_guard_y)=@_;
 return 0 if(white_luminance_guard_failed($step,$reading,$white_guard_y));
 return 0 if(headroom_needs_fine_tune($de,$target_delta,$reading,$step));
 return target_reached($de,$lum_pct,$target_delta,$step);
}

sub legal_white_pair_reference_step {
 my ($steps,$target,$step,$config)=@_;
 return undef if(ref($config) ne "HASH" || !$config->{"lg_autocal_26"});
 return undef if(ref($target) ne "HASH" || !defined($target->{"ire"}) || abs(($target->{"ire"}+0)-99) > 0.001);
 return undef if(ref($step) ne "HASH" || $step->{"autocal_white_reference"});
 return undef if(ref($steps) ne "ARRAY");
 foreach my $candidate (@{$steps}) {
  next if(ref($candidate) ne "HASH" || !$candidate->{"autocal_white_reference"});
  my $candidate_target=ddc_target_for_step($candidate);
  next if(!$candidate_target || abs(($candidate_target->{"ire"}+0)-99) > 0.001);
  return $candidate;
 }
 return undef;
}

sub legal_white_pair_spread_limit {
 my ($target_delta)=@_;
 $target_delta=0.5 if(!defined($target_delta) || $target_delta <= 0);
 my $limit=$target_delta*0.45;
 $limit=0.08 if($limit < 0.08);
 $limit=0.25 if($limit > 0.25);
 return $limit;
}

sub legal_white_pair_score {
 my ($de_a,$lum_a,$step_a,$reading_a,$de_b,$lum_b,$step_b,$reading_b,$white_guard_y)=@_;
 return guarded_autocal_result_score($de_a,$lum_a,$step_a,$reading_a,$white_guard_y) if(ref($step_b) ne "HASH" || ref($reading_b) ne "HASH");
 my $score_a=guarded_autocal_result_score($de_a,$lum_a,$step_a,$reading_a,$white_guard_y);
 my $score_b=guarded_autocal_result_score($de_b,$lum_b,$step_b,$reading_b,$white_guard_y);
 my $worst=$score_a > $score_b ? $score_a : $score_b;
 my $best=$score_a > $score_b ? $score_b : $score_a;
 my $spread=abs((defined($de_a)?$de_a:9999)-(defined($de_b)?$de_b:9999));
 my $pair_avg=legal_white_pair_delta_average($de_a,$de_b);
 return ($worst*1.45)+($best*0.20)+($pair_avg*0.10)+($spread*1.25);
}

sub legal_white_pair_delta_average {
	 my ($de_a,$de_b)=@_;
	 return defined($de_a) ? ($de_a+0) : 9999 if(!defined($de_b));
	 return defined($de_b) ? ($de_b+0) : 9999 if(!defined($de_a));
	 return (($de_a+0)+($de_b+0))/2;
}

sub legal_white_pair_worst_delta {
	 my ($de_a,$de_b)=@_;
	 my $a=defined($de_a) ? ($de_a+0) : 9999;
	 my $b=defined($de_b) ? ($de_b+0) : 9999;
	 return $a > $b ? $a : $b;
}

sub legal_white_pair_spread_delta {
	 my ($de_a,$de_b)=@_;
	 my $a=defined($de_a) ? ($de_a+0) : 9999;
	 my $b=defined($de_b) ? ($de_b+0) : 9999;
	 return abs($a-$b);
}

sub legal_white_pair_best_update_allowed {
	 my ($candidate_score,$best_score,$de_a,$de_b,$best_de_a,$best_de_b,$target_delta)=@_;
	 return defined(legal_white_pair_best_update_reason($candidate_score,$best_score,$de_a,$de_b,$best_de_a,$best_de_b,$target_delta)) ? 1 : 0;
}

sub legal_white_pair_best_update_reason {
	 my ($candidate_score,$best_score,$de_a,$de_b,$best_de_a,$best_de_b,$target_delta)=@_;
	 return undef if(!defined($candidate_score) || !defined($best_score));
	 return "score_improved" if(!defined($de_b) || !defined($best_de_b)) && $candidate_score + 0.0001 < $best_score;
	 $target_delta=0.5 if(!defined($target_delta) || $target_delta <= 0);
	 my $candidate_worst=legal_white_pair_worst_delta($de_a,$de_b);
	 my $best_worst=legal_white_pair_worst_delta($best_de_a,$best_de_b);
	 return "paired_score_improved" if($candidate_worst + 0.0001 < $best_worst);
	 return undef if($candidate_worst > $best_worst + 0.03);
	 my $candidate_avg=legal_white_pair_delta_average($de_a,$de_b);
	 my $best_avg=legal_white_pair_delta_average($best_de_a,$best_de_b);
	 return "paired_score_improved" if($candidate_worst <= $best_worst + 0.0001 && $candidate_avg + 0.0001 < $best_avg);
	 my $candidate_spread=legal_white_pair_spread_delta($de_a,$de_b);
	 my $best_spread=legal_white_pair_spread_delta($best_de_a,$best_de_b);
	 return "paired_score_improved" if($candidate_score + 0.0001 < $best_score && $candidate_spread + 0.02 < $best_spread);
	 return "paired_score_improved" if($candidate_worst <= $target_delta+0.30 && $candidate_score + 0.0001 < $best_score);
	 return undef;
}

sub legal_white_pair_target_reached {
	 my ($de_a,$lum_a,$step_a,$reading_a,$de_b,$lum_b,$step_b,$reading_b,$target_delta,$white_guard_y)=@_;
	 return guarded_target_reached($de_a,$lum_a,$target_delta,$step_a,$reading_a,$white_guard_y) if(ref($step_b) ne "HASH" || ref($reading_b) ne "HASH");
	 return 0 if(!guarded_target_reached($de_a,$lum_a,$target_delta,$step_a,$reading_a,$white_guard_y));
	 return 0 if(!guarded_target_reached($de_b,$lum_b,$target_delta,$step_b,$reading_b,$white_guard_y));
	 return 0 if(abs((defined($de_a)?$de_a:9999)-(defined($de_b)?$de_b:9999)) > legal_white_pair_spread_limit($target_delta));
	 return 1;
}

sub legal_white_pair_luminance_close_enough {
	 my ($step,$lum_pct)=@_;
	 return 1 if(autocal_uses_itp());
	 return 1 if(!defined($lum_pct));
	 my $tol=luminance_tolerance_percent($step);
	 my $allow=$tol+0.35;
	 $allow=1.0 if($allow > 1.0);
	 return abs($lum_pct) <= $allow ? 1 : 0;
}

sub legal_white_pair_close_enough {
	 my ($de_a,$lum_a,$step_a,$reading_a,$de_b,$lum_b,$step_b,$reading_b,$target_delta,$white_guard_y)=@_;
		 return 0 if(ref($step_b) ne "HASH" || ref($reading_b) ne "HASH");
		 return 0 if(!defined($de_a) || !defined($de_b));
		 $target_delta=0.5 if(!defined($target_delta) || $target_delta <= 0);
		 return 0 if(!within_itp_luminance_included_acceptance($de_a,$step_a));
		 return 0 if(!within_itp_luminance_included_acceptance($de_b,$step_b));
		 my $allow=$target_delta+0.20;
		 return 0 if($de_a > $allow || $de_b > $allow);
	 return 0 if(abs($de_a-$de_b) > legal_white_pair_spread_limit($target_delta)+0.12);
	 return 0 if(white_luminance_guard_failed($step_a,$reading_a,$white_guard_y));
	 return 0 if(white_luminance_guard_failed($step_b,$reading_b,$white_guard_y));
	 return 0 if(!legal_white_pair_luminance_close_enough($step_a,$lum_a));
	 return 0 if(!legal_white_pair_luminance_close_enough($step_b,$lum_b));
	 return 1;
}

sub legal_white_pair_close_enough_stalled {
	 my ($de_a,$lum_a,$step_a,$reading_a,$de_b,$lum_b,$step_b,$reading_b,$target_delta,$white_guard_y,$stalls,$iter)=@_;
	 return 0 if(($iter||0) < 6 || ($stalls||0) < 2);
	 return legal_white_pair_close_enough($de_a,$lum_a,$step_a,$reading_a,$de_b,$lum_b,$step_b,$reading_b,$target_delta,$white_guard_y);
}

sub legal_white_pair_precision_stall_limit {
	 my ($de_a,$de_b,$target_delta)=@_;
		 $target_delta=0.5 if(!defined($target_delta) || $target_delta <= 0);
		 my $worst=defined($de_a) ? ($de_a+0) : 9999;
		 $worst=$de_b if(defined($de_b) && $de_b > $worst);
		 return 16 if($worst > 1.0);
		 return $worst <= ($target_delta+0.25) ? 6 : 10;
}

sub legal_white_pair_needs_work {
	 my ($de,$lum_pct,$step,$reading,$target_delta,$white_guard_y)=@_;
	 return 1 if(!defined($de));
	 return guarded_target_reached($de,$lum_pct,$target_delta,$step,$reading,$white_guard_y) ? 0 : 1;
}

sub legal_white_pair_luminance_priority_adjustments {
	 my ($arrays,$target,$luminance_err,$de,$stalls,$tried,$step,$pair_lum_pct,$micro)=@_;
	 return undef if(!strict_tried_for_step($step));
	 return undef if(!has_luminance_channel($arrays,$target));
	 return undef if(!defined($luminance_err));
	 my $lum_pct=$luminance_err*100;
	 my $active_abs=abs($lum_pct);
	 my $paired_abs=defined($pair_lum_pct) ? abs($pair_lum_pct) : 0;
	 my $tol=luminance_tolerance_percent($step);
	 my $threshold=$tol*1.20;
	 $threshold=0.90 if($threshold < 0.90);
	 return undef if($active_abs <= $threshold && $paired_abs <= $threshold);
	 if(defined($pair_lum_pct) && $paired_abs > $threshold) {
	  my $same_sign=(($lum_pct >= 0 && $pair_lum_pct >= 0) || ($lum_pct <= 0 && $pair_lum_pct <= 0)) ? 1 : 0;
	  return undef if(!$same_sign && $active_abs < ($threshold*2.5));
	 }
	 my $max_step;
	 if($micro) {
	  $max_step=($active_abs >= 8) ? 2 : (($active_abs >= 3) ? 1 : 0.5);
	 } else {
	  $max_step=($active_abs >= 12) ? 4 : (($active_abs >= 4) ? 2 : 1);
	 }
	 my $neutral=neutral_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,0.25,$max_step,1);
	 if(ref($neutral) eq "ARRAY") {
	  foreach my $adj (@{$neutral}) {
	   $adj->{"paired_luminance"}=1 if(ref($adj) eq "HASH");
	  }
	 }
	 return $neutral;
}

sub near_target_for_probe_skip {
			 my ($de,$lum_pct,$target_delta,$step)=@_;
			 return 0 if(!defined($de));
			 $target_delta=0.5 if(!defined($target_delta));
			 my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : 100;
			 return 1 if($ire <= 5 && $de <= low_shadow_delta_acceptance($step,$target_delta) && !low_ire_luminance_needs_tuning($step,$lum_pct));
			 return 0 if($de > ($target_delta+0.35));
			 return 1 if(!defined($lum_pct));
			 return abs($lum_pct) <= luminance_tolerance_percent($step)*1.25;
}

sub iteration_limit_for_step {
				 my ($step,$default,$config)=@_;
				 $default=50 if(!defined($default) || $default < 1);
				 my $headroom_limit=headroom_iteration_limit_for_step($step,$config);
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
	 my ($step,$override)=@_;
	 if(defined($override) && $override =~ /^\d+$/ && $override >= 10) {
	  return $override+20;
	 }
	 my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : 100;
	 return 60 if(ref($step) eq "HASH" && $step->{"autocal_probe_stimulus"});
	 return 210 if($ire <= 5);
	 return 180 if($ire <= 10);
	 return 150 if($ire <= 25);
	 return 120 if($ire <= 50);
	 return 110;
}

sub low_shadow_sample_count_for_step {
	 my ($config,$step)=@_;
		 return 1 if(ref($config) eq "HASH" && $config->{"disable_low_shadow_median"});
		 my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : 100;
		 if(autocal_config_is_touchup($config)) {
		  return 1 if($ire <= 5.1001);
		  return 1 if($ire <= 10.0001);
		 }
		 return 2 if($ire <= 5.1001);
		 return 1 if($ire <= 10.0001);
	 return 2 if(!autocal_config_is_touchup($config));
 return 2;
}

sub low_shadow_sample_read_timeout {
 my ($config,$step)=@_;
	 return undef if(!autocal_step_is_low_shadow($step));
	 my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : 100;
	 return 30 if(autocal_config_is_touchup($config) && $ire <= 3.1001);
	 return 35 if(autocal_config_is_touchup($config) && $ire <= 5.0001);
 return 30 if(autocal_config_is_touchup($config) && $ire <= 10.0001);
 return 55 if($ire <= 5.0001);
 return 45;
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

sub headroom_adjustment_step {
	 my ($abs_err,$stalls,$min_step,$max_step,$micro)=@_;
	 $abs_err=0 if(!defined($abs_err));
	 $stalls=0 if(!defined($stalls));
	 $min_step ||= 0.20;
	 $max_step ||= 6;
	 my $step=0.20;
	 if($abs_err >= 0.20) {
	  $step=8;
	 } elsif($abs_err >= 0.12) {
	  $step=6;
	 } elsif($abs_err >= 0.06) {
	  $step=4;
	 } elsif($abs_err >= 0.035) {
	  $step=2;
	 } elsif($abs_err >= 0.018) {
	  $step=1;
	 } elsif($abs_err >= 0.010) {
	  $step=0.5;
	 } elsif($abs_err >= 0.004) {
	  $step=0.25;
	 }
	 if($micro) {
	  $step=1 if($step > 1);
	  $step=0.5 if($abs_err < 0.018 && $step > 0.5);
	  $step=0.25 if($abs_err < 0.010 && $step > 0.25);
	 }
	 if($stalls >= 2 && $abs_err < 0.020 && $step > 0.25) {
	  $step=0.25;
	 } elsif($stalls >= 2 && $abs_err < 0.040 && $step > 0.5) {
	  $step=0.5;
	 }
	 $step=$min_step if($step < $min_step);
	 $step=$max_step if(defined($max_step) && $step > $max_step);
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

sub lg_autocal_26_lut_indexes {
 return (21,30,38,47,64,94,141,188,235,282,329,375,422,469,512,559,606,653,700,747,794,841,888,926,981,1023);
}

sub lg_autocal_26_black_lut_anchor {
 return 0;
}

sub clone_calibrated_26pt_slot_mask {
 my ($calibrated_slot_mask)=@_;
 return undef if(ref($calibrated_slot_mask) ne "ARRAY");
 return [ map { $_ ? 1 : 0 } @{$calibrated_slot_mask} ];
}

sub promote_calibrated_26pt_slot_mask {
 my ($calibrated_slot_mask,$candidate_slot_mask)=@_;
 return if(ref($calibrated_slot_mask) ne "ARRAY" || ref($candidate_slot_mask) ne "ARRAY");
 my $count=ddc_slot_count();
 for(my $idx=0;$idx<$count;$idx++) {
  $calibrated_slot_mask->[$idx]=$candidate_slot_mask->[$idx] ? 1 : 0;
 }
}

sub mark_calibrated_26pt_slot_index {
 my ($calibrated_slot_mask,$idx)=@_;
 return if(ref($calibrated_slot_mask) ne "ARRAY");
 return if(!defined($idx) || $idx < 0 || $idx >= ddc_slot_count());
 $calibrated_slot_mask->[$idx]=1;
}

sub mark_calibrated_26pt_slot {
 my ($calibrated_slot_mask,$target)=@_;
 return if(ref($calibrated_slot_mask) ne "ARRAY" || ref($target) ne "HASH");
 my $idx=$target->{"index"};
 mark_calibrated_26pt_slot_index($calibrated_slot_mask,$idx);
}

sub mark_calibrated_26pt_candidate_slots {
 my ($calibrated_slot_mask,$candidate)=@_;
 return if(ref($calibrated_slot_mask) ne "ARRAY" || ref($candidate) ne "HASH" || ref($candidate->{"changes"}) ne "ARRAY");
 foreach my $change (@{$candidate->{"changes"}}) {
  next if(ref($change) ne "HASH");
  mark_calibrated_26pt_slot_index($calibrated_slot_mask,$change->{"index"});
 }
}

sub calibrated_non_black_26pt_anchor_count {
 my ($calibrated_slot_mask)=@_;
 return 0 if(ref($calibrated_slot_mask) ne "ARRAY");
 my @slots=ddc_slots();
 my $count=0;
 for(my $idx=0;$idx<@slots;$idx++) {
  next if(!$calibrated_slot_mask->[$idx]);
  next if(defined($slots[$idx]) && ($slots[$idx]+0) <= 0.0001);
  $count++;
 }
 return $count;
}

sub calibrated_26pt_slot_ires {
 my ($calibrated_slot_mask)=@_;
 return () if(ref($calibrated_slot_mask) ne "ARRAY");
 my @slots=ddc_slots();
 my @ires;
 for(my $idx=0;$idx<@slots;$idx++) {
  next if(!$calibrated_slot_mask->[$idx]);
  push @ires,$slots[$idx]+0;
 }
 return @ires;
}

sub completed_lg_autocal_26_full_ddc_spine_anchor_ires {
 my ($calibrated_slot_mask)=@_;
 my %calibrated=map { format_percent($_) => 1 } calibrated_26pt_slot_ires($calibrated_slot_mask);
 return grep { $calibrated{format_percent($_)} } lg_autocal_26_full_ddc_spine_anchor_ires();
}

sub completed_lg_autocal_26_anchor_predrive_anchor_ires {
 my ($calibrated_slot_mask)=@_;
 my %calibrated=map { format_percent($_) => 1 } calibrated_26pt_slot_ires($calibrated_slot_mask);
 return grep { $calibrated{format_percent($_)} } lg_autocal_26_anchor_predrive_anchor_ires();
}

sub lg_autocal_26_calibrated_slot_mask_for_ires {
 my ($calibrated_slot_mask,@ires)=@_;
 my @mask=map { 0 } (1..ddc_slot_count());
 return \@mask if(ref($calibrated_slot_mask) ne "ARRAY");
 my %wanted=map { format_percent($_) => 1 } @ires;
 my @slots=ddc_slots();
 for(my $idx=0;$idx<@slots;$idx++) {
  next if(!$calibrated_slot_mask->[$idx]);
  next if(!$wanted{format_percent($slots[$idx])});
  $mask[$idx]=1;
 }
 return \@mask;
}

sub lg_autocal_26_anchor_predrive_source_slot_mask {
 my ($calibrated_slot_mask)=@_;
 return lg_autocal_26_calibrated_slot_mask_for_ires($calibrated_slot_mask,lg_autocal_26_anchor_predrive_anchor_ires());
}

sub linear_interpolated_26pt_curve_value {
 my ($x,$left,$right)=@_;
 return undef if(ref($left) ne "HASH" || ref($right) ne "HASH");
 my $span=($right->{"x"}+0)-($left->{"x"}+0);
 return undef if($span == 0);
 my $ratio=(($x+0)-($left->{"x"}+0))/$span;
 return ($left->{"y"}+0)+((($right->{"y"}+0)-($left->{"y"}+0))*$ratio);
}

sub bounded_hermite_26pt_curve_value {
 my ($x,$knots,$left_idx)=@_;
 return undef if(ref($knots) ne "ARRAY" || !defined($left_idx) || $left_idx < 0 || $left_idx+1 >= @{$knots});
 my $left=$knots->[$left_idx];
 my $right=$knots->[$left_idx+1];
 return undef if(ref($left) ne "HASH" || ref($right) ne "HASH");
 my $span=($right->{"x"}+0)-($left->{"x"}+0);
 return undef if($span == 0);
 my $slope_for=sub {
  my ($from,$to)=@_;
  return 0 if($from < 0 || $to < 0 || $from >= @{$knots} || $to >= @{$knots});
  my $dx=($knots->[$to]{"x"}+0)-($knots->[$from]{"x"}+0);
  return 0 if($dx == 0);
  return (($knots->[$to]{"y"}+0)-($knots->[$from]{"y"}+0))/$dx;
 };
 my $m_left=($left_idx > 0) ? $slope_for->($left_idx-1,$left_idx+1) : $slope_for->($left_idx,$left_idx+1);
 my $m_right=($left_idx+2 < @{$knots}) ? $slope_for->($left_idx,$left_idx+2) : $slope_for->($left_idx,$left_idx+1);
 my $t=(($x+0)-($left->{"x"}+0))/$span;
 my $t2=$t*$t;
 my $t3=$t2*$t;
 my $y=((2*$t3)-(3*$t2)+1)*($left->{"y"}+0)
  +(($t3-(2*$t2)+$t)*$span*$m_left)
  +(((-2*$t3)+(3*$t2))*($right->{"y"}+0))
  +(($t3-$t2)*$span*$m_right);
 my $min_y=($left->{"y"}+0) < ($right->{"y"}+0) ? ($left->{"y"}+0) : ($right->{"y"}+0);
 my $max_y=($left->{"y"}+0) > ($right->{"y"}+0) ? ($left->{"y"}+0) : ($right->{"y"}+0);
 $y=$min_y if($y < $min_y);
 $y=$max_y if($y > $max_y);
 return $y;
}

sub interpolated_26pt_curve_value {
 my ($x,$knots)=@_;
 return undef if(ref($knots) ne "ARRAY" || @{$knots} < 2);
 for(my $idx=0;$idx<@{$knots};$idx++) {
  next if(ref($knots->[$idx]) ne "HASH");
  return $knots->[$idx]{"y"}+0 if(abs(($x+0)-($knots->[$idx]{"x"}+0)) < 0.000001);
 }
 my $left_idx;
 for(my $idx=0;$idx+1<@{$knots};$idx++) {
  next if(ref($knots->[$idx]) ne "HASH" || ref($knots->[$idx+1]) ne "HASH");
  if(($x+0) >= ($knots->[$idx]{"x"}+0) && ($x+0) <= ($knots->[$idx+1]{"x"}+0)) {
   $left_idx=$idx;
   last;
  }
 }
 return undef if(!defined($left_idx));
 return linear_interpolated_26pt_curve_value($x,$knots->[$left_idx],$knots->[$left_idx+1]) if(@{$knots} < 5);
 return bounded_hermite_26pt_curve_value($x,$knots,$left_idx);
}

sub propagate_uncalibrated_26pt_slots {
 my ($arrays,$calibrated_slot_mask,$source_slot_mask)=@_;
 return 0 if(ref($arrays) ne "HASH" || ref($calibrated_slot_mask) ne "ARRAY");
 $source_slot_mask=$calibrated_slot_mask if(ref($source_slot_mask) ne "ARRAY");
 my @lut_indexes=lg_autocal_26_lut_indexes();
 my $black_anchor=lg_autocal_26_black_lut_anchor();
 my @settings=qw(whiteBalanceRed whiteBalanceGreen whiteBalanceBlue adjustingLuminance);
 my %setting_knots;
 foreach my $setting (@settings) {
  my $arr=$arrays->{$setting};
	  next if(ref($arr) ne "ARRAY");
	  my @knots=({ x=>$black_anchor+0, y=>0 });
	  for(my $idx=0;$idx<@lut_indexes;$idx++) {
	   next if(!$source_slot_mask->[$idx]);
	   next if(!defined($arr->[$idx]));
	   push @knots,{ x=>$lut_indexes[$idx]+0, y=>$arr->[$idx]+0 };
	  }
  @knots=sort { ($a->{"x"}||0) <=> ($b->{"x"}||0) } @knots;
  $setting_knots{$setting}=\@knots;
 }
 my $filled=0;
 for(my $idx=0;$idx<@lut_indexes;$idx++) {
  next if($calibrated_slot_mask->[$idx]);
  my $slot_filled=0;
  foreach my $setting (@settings) {
   my $arr=$arrays->{$setting};
   next if(ref($arr) ne "ARRAY");
   my $value=interpolated_26pt_curve_value($lut_indexes[$idx]+0,$setting_knots{$setting});
   next if(!defined($value));
   $arr->[$idx]=clamp_ddc_value($value);
   $slot_filled=1;
  }
  $filled++ if($slot_filled);
 }
 return $filled;
}

sub refresh_propagated_uncalibrated_26pt_slots {
 my ($config,$arrays,$calibrated_slot_mask)=@_;
 return 0 if(ref($config) ne "HASH" || !$config->{"lg_autocal_26"});
 my $minimum_anchors=lg_autocal_26_full_ddc_spine_enabled($config) ? 1 : 3;
 my $source_slot_mask=$calibrated_slot_mask;
 if(lg_autocal_26_anchor_predrive_enabled($config)) {
  $minimum_anchors=lg_autocal_26_anchor_predrive_anchor_count();
  $source_slot_mask=lg_autocal_26_anchor_predrive_source_slot_mask($calibrated_slot_mask);
 }
 return 0 if(calibrated_non_black_26pt_anchor_count($source_slot_mask) < $minimum_anchors);
 return propagate_uncalibrated_26pt_slots($arrays,$calibrated_slot_mask,$source_slot_mask);
}

sub seed_target_from_prior_slot {
		 my ($arrays,$target,$calibrated_slot_mask,$config)=@_;
	 return 0 if(ref($arrays) ne "HASH" || ref($target) ne "HASH");
	 my $idx=$target->{"index"};
	 return 0 if(!defined($idx));
	 my @settings=ddc_adjustment_settings($arrays);
	 my @slots=ddc_slots();
	 return 0 if(!defined($slots[$idx]));
	 my $target_slot_ire=$slots[$idx]+0;
	 return 0 if(ref($calibrated_slot_mask) eq "ARRAY" && $calibrated_slot_mask->[$idx]);
	 my %target_before;
	 foreach my $setting (@settings) {
	  my $arr=$arrays->{$setting};
	  next if(ref($arr) ne "ARRAY");
	  $target_before{$setting}=defined($arr->[$idx]) ? ($arr->[$idx]+0) : 0;
	 }
	 my $all_zero=1;
	 foreach my $setting (@settings) {
	  if(abs($target_before{$setting}||0) > 0.0001) {
	   $all_zero=0;
	   last;
	  }
	 }
	 if($all_zero) {
	  my @probe_indices;
	  if(target_is_low_shadow_slot($target)) {
	   @probe_indices=reverse(0..($idx-1)) if($idx > 0);
	  } else {
	   @probe_indices=($idx+1)..(ddc_slot_count()-1) if($idx+1 < ddc_slot_count());
	  }
	  my $source_idx;
	  foreach my $probe (@probe_indices) {
	   next if(!defined($slots[$probe]));
	   next if($target_slot_ire <= 100.0001 && ($slots[$probe]+0) >= 105);
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
	  return 0 if(!defined($slots[$idx]) || !defined($slots[$source_idx]));
	  return 0 if(abs(($slots[$source_idx]+0)-($slots[$idx]+0)) > 12);
	  return 0 if($target_slot_ire >= 105 && $target_slot_ire < 108.5 && ($slots[$source_idx]+0) >= 108.5);
	  return 0 if(target_is_low_shadow_slot($target) && abs(($slots[$source_idx]+0)-($slots[$idx]+0)) > 3.1001);
	  my $copied=0;
	  foreach my $setting (@settings) {
	   my $arr=$arrays->{$setting};
	   next if(ref($arr) ne "ARRAY");
	   my $value=$arr->[$source_idx]||0;
	   $value=0 if($setting eq "adjustingLuminance" && target_is_low_shadow_slot($target) && $value < 0);
	   $arr->[$idx]=$value;
	   $copied=1 if(abs($value) > 0.0001);
	  }
	  return 0 if(!$copied);
	  my %target_after;
	  foreach my $setting (@settings) {
	   my $arr=$arrays->{$setting};
	   next if(ref($arr) ne "ARRAY");
	   $target_after{$setting}=defined($arr->[$idx]) ? ($arr->[$idx]+0) : 0;
	  }
	  return {
	   mode=>"full-copy",
	   source_index=>$source_idx+0,
	   source_ire=>defined($slots[$source_idx]) ? ($slots[$source_idx]+0) : undef,
	   target_index=>$idx+0,
	   target_ire=>$target_slot_ire+0,
	   before=>\%target_before,
	   after=>\%target_after
	  };
	 }
	 return 0 if(ref($config) ne "HASH" || !$config->{"lg_autocal_26"});
	 return 0 if(ref($calibrated_slot_mask) ne "ARRAY");
	 return 0 if(!grep { abs($target_slot_ire-$_) < 0.001 } (75,50,25,5));
	 return 0 if(ref($arrays->{"adjustingLuminance"}) ne "ARRAY");
	 my $source_idx;
	 for(my $probe=$idx+1;$probe<ddc_slot_count();$probe++) {
	  next if(!$calibrated_slot_mask->[$probe]);
	  next if(!defined($slots[$probe]));
	  next if($target_slot_ire <= 100.0001 && ($slots[$probe]+0) >= 105);
	  next if(abs(($slots[$probe]+0)-$target_slot_ire) > 25.0001);
	  $source_idx=$probe;
	  last;
	 }
	 return 0 if(!defined($source_idx));
	 my $luma_arr=$arrays->{"adjustingLuminance"};
	 my $source_luma=defined($luma_arr->[$source_idx]) ? ($luma_arr->[$source_idx]+0) : 0;
	 my $current_luma=defined($luma_arr->[$idx]) ? ($luma_arr->[$idx]+0) : 0;
	 return 0 if(abs($source_luma) <= 0.0001);
	 return 0 if(abs($source_luma) <= abs($current_luma)+0.0001);
	 return 0 if(abs($current_luma) > 0.0001 && (($current_luma > 0) != ($source_luma > 0)));
	 my $after_luma=clamp_ddc_value($source_luma);
	 return 0 if(abs($after_luma-$current_luma) <= 0.0001);
	 $luma_arr->[$idx]=$after_luma;
	 return {
	  mode=>"luma-only",
	  source_index=>$source_idx+0,
	  source_ire=>defined($slots[$source_idx]) ? ($slots[$source_idx]+0) : undef,
	  target_index=>$idx+0,
	  target_ire=>$target_slot_ire+0,
	  before=>{ adjustingLuminance=>$current_luma+0 },
	  after=>{ adjustingLuminance=>$after_luma+0 }
	 };
	}

sub repeated_value {
			 my ($tried,$setting,$value)=@_;
			 return 0 if(ref($tried) ne "HASH" || ref($tried->{$setting}) ne "HASH");
			 my $entry=$tried->{$setting}{ddc_value_key($value)};
			 return 0 if(ref($entry) ne "HASH");
			 return (($entry->{"count"}||0) >= 2) ? 1 : 0;
	}

sub strict_tried_for_step {
	 my ($step)=@_;
	 return (ref($step) eq "HASH" && $step->{"legal_white_pair_active"}) ? 1 : 0;
}

sub next_untried_value {
	 my ($current,$delta,$tried,$setting,$min_step,$strict)=@_;
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
	  my $seen=$strict ? tried_value_exists($tried,$setting,$next) : repeated_value($tried,$setting,$next);
	  return ($next,($mag != abs($delta))) if(!$seen);
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

sub neutral_luminance_step_cap_for_target {
	 my ($target)=@_;
	 return undef if(ref($target) ne "HASH" || !defined($target->{"ire"}));
	 my $ire=$target->{"ire"}+0;
	 return 0.5 if($ire > 10.0001 && $ire <= 25.0001);
	 return 1.0 if($ire > 25.0001 && $ire <= 35.0001);
	 return 1.5 if($ire > 35.0001 && $ire <= 50.0001);
	 return undef;
}

sub neutral_luminance_adjustments {
	 my ($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_step,$max_step,$strict_tried)=@_;
	 return undef if(ref($arrays) ne "HASH" || ref($target) ne "HASH");
	 $luminance_err=0 if(!defined($luminance_err));
	 return undef if(abs($luminance_err) < 0.0035);
	 my $idx=$target->{"index"};
	 return undef if(!defined($idx));
	 $min_step ||= 0.25;
	 my $cap=neutral_luminance_step_cap_for_target($target);
	 $max_step=$cap if(defined($cap) && (!defined($max_step) || $max_step > $cap));
	 my $direction=($luminance_err > 0) ? -1 : 1;
	 my $step=neutral_luminance_step($luminance_err,$de,$stalls,$min_step,$max_step);
		 my @magnitudes=($step);
		 push @magnitudes,0.5 if($step > 0.5);
		 push @magnitudes,0.25 if($step > 0.25);
			 if(has_luminance_channel($arrays,$target)) {
			  my $setting="adjustingLuminance";
				  my $arr=$arrays->{$setting};
				  foreach my $mag (@magnitudes) {
				   my $current=$arr->[$idx]||0;
				   my $next=clamp_ddc_value($current+($direction*$mag));
				   my $seen=$strict_tried ? tried_value_exists($tried,$setting,$next) : repeated_value($tried,$setting,$next);
				   next if(abs($next-$current) < 0.0001 || $seen);
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

sub low_shadow_luminance_max_step {
	 my ($luminance_err,$stalls,$step)=@_;
	 $luminance_err=0 if(!defined($luminance_err));
	 $stalls=0 if(!defined($stalls));
	 my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : 100;
	 my $abs=abs($luminance_err);
	 my $max=0.5;
	 if($abs >= 0.35) {
	  $max=8;
	 } elsif($abs >= 0.25) {
	  $max=6;
	 } elsif($abs >= 0.18) {
	  $max=5;
	 } elsif($abs >= 0.10) {
	  $max=4;
	 } elsif($abs >= 0.05) {
	  $max=2;
	 } elsif($abs >= 0.02) {
	  $max=1;
	 }
	 my $low_cap=undef;
	 if($ire > 0 && $ire <= 5.1001) {
	  $low_cap=0.5;
	  $low_cap=1 if($abs >= 0.08);
	  $low_cap=2 if($abs >= 0.20);
	  $low_cap=4 if($abs >= 0.40);
	  if($ire <= 3.1001) {
	   $low_cap=0.5;
	   $low_cap=1 if($abs >= 0.20);
	   $low_cap=2 if($abs >= 0.50);
	  }
	 } elsif($ire > 0 && $ire <= 10.1001) {
	  $low_cap=1;
	  $low_cap=2 if($abs >= 0.20);
	 }
	 $max=$low_cap if(defined($low_cap) && $max > $low_cap);
	 $max=1 if($stalls >= 3 && $max < 1);
	 $max=$low_cap if(defined($low_cap) && $max > $low_cap);
	 return $max;
}

sub force_low_shadow_luminance_adjustment {
 my ($arrays,$target,$luminance_err,$tried,$min_step,$max_step)=@_;
 return undef if(ref($arrays) ne "HASH" || ref($target) ne "HASH");
 return undef if(!has_luminance_channel($arrays,$target));
 my $idx=$target->{"index"};
 return undef if(!defined($idx));
 my $arr=$arrays->{"adjustingLuminance"};
 return undef if(ref($arr) ne "ARRAY" || $idx >= @{$arr});
 $min_step ||= 0.25;
 $max_step ||= 4;
 my $direction=($luminance_err > 0) ? -1 : 1;
 my $current=$arr->[$idx]||0;
 my @magnitudes;
 foreach my $candidate ($max_step,1,0.5,0.25) {
  next if($candidate > $max_step+0.0001);
  next if(grep { abs($_-$candidate) < 0.0001 } @magnitudes);
  push @magnitudes,$candidate;
 }
 foreach my $mag (@magnitudes) {
  next if($mag < $min_step-0.0001);
  my $next=clamp_ddc_value($current+($direction*$mag));
  next if(abs($next-$current) < 0.0001);
  next if(tried_value_exists($tried,"adjustingLuminance",$next));
  return [{ channel=>"lum", setting=>"adjustingLuminance", current=>$current, next=>$next, delta=>$next-$current, neutral_luminance=>1, low_shadow_luminance=>1, forced_luminance=>1 }];
 }
 return undef;
}

sub low_shadow_luminance_response_cap {
 my ($step,$lum_pct)=@_;
 my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : 5;
 my $abs=defined($lum_pct) ? abs($lum_pct) : 0;
 return ($abs >= 40) ? 2 : 1 if($ire <= 3.1001);
 return 2 if($ire <= 5.1001);
 return 4 if($ire <= 10.1001);
 return 2;
}

sub low_shadow_luminance_response_adjustment {
 my ($step,$adjustments,$before,$after,$arrays,$target,$tried,$from_start)=@_;
 return undef if(!autocal_step_is_low_shadow($step));
 return undef if(ref($adjustments) ne "ARRAY" || @{$adjustments} != 1);
 return undef if(ref($before) ne "HASH" || ref($after) ne "HASH" || ref($arrays) ne "HASH" || ref($target) ne "HASH");
 my $adj=$adjustments->[0];
 return undef if(ref($adj) ne "HASH");
 return undef if(($adj->{"setting"}||"") ne "adjustingLuminance");
 my $idx=$target->{"index"};
 return undef if(!defined($idx) || ref($arrays->{"adjustingLuminance"}) ne "ARRAY");
 my $start=defined($adj->{"current"}) ? ($adj->{"current"}+0) : undef;
 my $end=defined($adj->{"next"}) ? ($adj->{"next"}+0) : undef;
 return undef if(!defined($start) || !defined($end) || abs($end-$start) < 0.0001);
 my $target_y=$after->{"target_luminance"};
 $target_y=$before->{"target_luminance"} if(!defined($target_y));
 return undef if(!defined($target_y) || $target_y <= 0);
 my $before_lum_pct=luminance_error_percent($before,$target_y);
 my $after_lum_pct=luminance_error_percent($after,$target_y);
 return undef if(!defined($before_lum_pct) || !defined($after_lum_pct));
 my $slope=($after_lum_pct-$before_lum_pct)/($end-$start);
 return undef if(abs($slope) < 0.25);
 my $ideal=$start-($before_lum_pct/$slope);
 my $current=$from_start ? $start : ($arrays->{"adjustingLuminance"}[$idx]||0);
 my $delta=$ideal-$current;
 return undef if(abs($delta) < 0.18);
 my $cap=low_shadow_luminance_response_cap($step,$after_lum_pct);
 $delta=$cap if($delta > $cap);
 $delta=-$cap if($delta < -$cap);
 my $next=round_ddc_quarter($current+$delta);
 return undef if(abs($next-$current) < 0.0001);
 return undef if(tried_value_exists($tried,"adjustingLuminance",$next));
 return [{ channel=>"lum", setting=>"adjustingLuminance", current=>$current, next=>$next, delta=>$next-$current, neutral_luminance=>1, low_shadow_luminance=>1, response_model=>1, slope=>$slope+0, predicted_error=>($after_lum_pct+($slope*($next-$end)))+0 }];
}

sub body_luminance_response_cap {
 my ($step)=@_;
 return undef if(ref($step) ne "HASH" || !defined($step->{"ire"}));
 my $ire=$step->{"ire"}+0;
 return 1.5 if($ire > 10.0001 && $ire <= 25.0001);
 return 2.0 if($ire > 25.0001 && $ire <= 35.0001);
 return 2.5 if($ire > 35.0001 && $ire <= 50.0001);
 return 2.0 if($ire > 50.0001 && $ire <= 70.0001);
 return 1.5 if($ire > 70.0001 && $ire <= 85.0001);
 return 1.0 if($ire > 85.0001 && $ire <= 95.0001);
 return undef;
}

sub body_luminance_response_adjustment {
 my ($step,$adjustments,$before,$after,$arrays,$target,$tried,$from_start)=@_;
 return undef if(autocal_step_is_low_shadow($step) || autocal_step_is_fast_headroom($step) || autocal_step_is_white($step));
 my $cap=body_luminance_response_cap($step);
 return undef if(!defined($cap));
 return undef if(ref($adjustments) ne "ARRAY" || @{$adjustments} != 1);
 return undef if(ref($before) ne "HASH" || ref($after) ne "HASH" || ref($arrays) ne "HASH" || ref($target) ne "HASH");
 my $adj=$adjustments->[0];
 return undef if(ref($adj) ne "HASH");
 return undef if(($adj->{"setting"}||"") ne "adjustingLuminance");
 my $idx=$target->{"index"};
 return undef if(!defined($idx) || ref($arrays->{"adjustingLuminance"}) ne "ARRAY");
 my $start=defined($adj->{"current"}) ? ($adj->{"current"}+0) : undef;
 my $end=defined($adj->{"next"}) ? ($adj->{"next"}+0) : undef;
 return undef if(!defined($start) || !defined($end) || abs($end-$start) < 0.0001);
 my $target_y=$after->{"target_luminance"};
 $target_y=$before->{"target_luminance"} if(!defined($target_y));
 return undef if(!defined($target_y) || $target_y <= 0);
 my $before_lum_pct=luminance_error_percent($before,$target_y);
 my $after_lum_pct=luminance_error_percent($after,$target_y);
 return undef if(!defined($before_lum_pct) || !defined($after_lum_pct));
 my $slope=($after_lum_pct-$before_lum_pct)/($end-$start);
 return undef if(abs($slope) < 0.10);
 my $current=$from_start ? $start : ($arrays->{"adjustingLuminance"}[$idx]||0);
 my $current_error=$before_lum_pct+($slope*($current-$start));
 my $ideal=$current-($current_error/$slope);
 my $delta=$ideal-$current;
 return undef if(abs($delta) < 0.18);
 my $direction=($delta < 0) ? -1 : 1;
 my $mag=abs($delta);
 $mag=$cap if($mag > $cap);
 $mag=0.25 if($mag < 0.25);
 my @magnitudes;
 while($mag >= 0.25-0.0001) {
  push @magnitudes,$mag;
  $mag-=0.25;
 }
 foreach my $candidate_mag (@magnitudes) {
  my $next=round_ddc_quarter($current+($direction*$candidate_mag));
  next if(abs($next-$current) < 0.0001);
  next if(tried_value_exists($tried,"adjustingLuminance",$next));
  my $predicted=$before_lum_pct+($slope*($next-$start));
  next if(abs($predicted) + 0.0001 >= abs($current_error));
  return [{ channel=>"lum", setting=>"adjustingLuminance", current=>$current, next=>$next, delta=>$next-$current, neutral_luminance=>1, body_luminance=>1, response_model=>1, slope=>$slope+0, predicted_error=>$predicted+0 }];
 }
 return undef;
}

sub high_end_paired_luma_allowed {
 my ($config,$step,$target,$paired_white_step)=@_;
 return 0 if($paired_white_step);
 return 0 if(lg_autocal_26_anchor_predrive_enabled($config));
 return 0 if(!lg_autocal_26_full_ddc_spine_enabled($config));
 return 0 if(!autocal_step_is_fast_headroom($step) || autocal_step_is_peak_headroom($step));
 return 0 if(ref($target) ne "HASH" || !defined($target->{"ire"}));
 my $ire=$target->{"ire"}+0;
 return ($ire >= 104.5 && $ire < 108.5) ? 1 : 0;
}

sub high_end_rgb_move_summary {
 my ($adjustments)=@_;
 return undef if(ref($adjustments) ne "ARRAY");
 my @moves;
 my $max=0;
 foreach my $adj (@{$adjustments}) {
  next if(ref($adj) ne "HASH");
  my $ch=$adj->{"channel"}||"";
  return undef if($ch eq "lum" || ($adj->{"setting"}||"") eq "adjustingLuminance");
  next if($ch !~ /^(?:r|g|b)$/);
  my $setting=$adj->{"setting"}||"";
  next if($setting !~ /^whiteBalance(?:Red|Green|Blue)$/);
  my $delta=defined($adj->{"delta"}) ? ($adj->{"delta"}+0) : 0;
  next if(abs($delta) < 0.0001);
  push @moves,{ channel=>$ch, setting=>$setting, delta=>$delta+0 };
  $max=abs($delta) if(abs($delta) > $max);
 }
 return undef if(!@moves || $max < 0.0001);
 return { moves=>\@moves, max_abs_delta=>$max+0 };
}

sub high_end_paired_luma_adjustment {
 my ($config,$step,$target,$arrays,$adjustments,$candidate_lum_pct,$best_lum_pct,$candidate_chroma,$best_chroma,$tried,$paired_white_step)=@_;
 return undef if(!high_end_paired_luma_allowed($config,$step,$target,$paired_white_step));
 return undef if(!has_luminance_channel($arrays,$target));
 return undef if(!defined($candidate_lum_pct) || $candidate_lum_pct <= 0.35);
 return undef if(defined($best_lum_pct) && abs($candidate_lum_pct) <= abs($best_lum_pct)+0.35);
 return undef if(!defined($candidate_chroma) || !defined($best_chroma));
 return undef if($candidate_chroma + 0.0001 >= $best_chroma);
 my $move=high_end_rgb_move_summary($adjustments);
 return undef if(ref($move) ne "HASH");
 my $idx=$target->{"index"};
 return undef if(!defined($idx));
 my $arr=$arrays->{"adjustingLuminance"};
 return undef if(ref($arr) ne "ARRAY" || $idx >= @{$arr});
 my $current=defined($arr->[$idx]) ? ($arr->[$idx]+0) : 0;
 my $excess=defined($best_lum_pct) ? (($candidate_lum_pct+0)-($best_lum_pct+0)) : ($candidate_lum_pct+0);
 $excess=$candidate_lum_pct+0 if($excess < 0);
 my $mag=($move->{"max_abs_delta"}||0)*0.50;
 my $luma_mag=$excess*0.35;
 $mag=$luma_mag if($luma_mag > $mag);
 $mag=0.5 if($mag < 0.5);
 $mag=3.0 if($mag > 3.0);
 $mag=round_ddc_quarter($mag);
 $mag=0.5 if($mag < 0.5);
 my $next=clamp_ddc_value($current-$mag);
 return undef if(abs($next-$current) < 0.0001);
 return undef if(tried_value_exists($tried,"adjustingLuminance",$next));
 my $luma={ channel=>"lum", setting=>"adjustingLuminance", current=>$current, next=>$next, delta=>$next-$current, high_end_paired_luma=>1 };
 return { luma_adjustment=>$luma, rgb_move=>$move, luma_delta=>$next-$current };
}

sub body_luminance_priority_adjustments {
 my ($arrays,$target,$luminance_err,$de,$stalls,$tried,$step)=@_;
 return undef if(autocal_step_is_low_shadow($step) || autocal_step_is_fast_headroom($step) || autocal_step_is_white($step) || strict_tried_for_step($step));
 return undef if(!has_luminance_channel($arrays,$target));
 $luminance_err=0 if(!defined($luminance_err));
 my $lum_pct=$luminance_err*100;
 my $threshold=luminance_tolerance_percent($step)*3;
 $threshold=8 if($threshold < 8);
 return undef if(abs($lum_pct) < $threshold);
 my $max_step=abs($luminance_err) >= 0.20 ? 4 : (abs($luminance_err) >= 0.12 ? 2 : 1);
 my $adjustments=neutral_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,0.25,$max_step,0);
 if(ref($adjustments) eq "ARRAY") {
  foreach my $adj (@{$adjustments}) {
   next if(ref($adj) ne "HASH");
   $adj->{"body_luminance_priority"}=1;
  }
 }
 return $adjustments;
}

sub low_shadow_luminance_priority_adjustments {
 my ($arrays,$target,$luminance_err,$de,$stalls,$tried,$step,$micro)=@_;
 return undef if(!autocal_step_is_low_shadow($step));
 return undef if(!has_luminance_channel($arrays,$target));
 $luminance_err=0 if(!defined($luminance_err));
 my $lum_pct=$luminance_err*100;
 my $tol=luminance_tolerance_percent($step);
 my $threshold=$tol*($micro ? 0.70 : 1.00);
 if(!$micro) {
  my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : 100;
  $threshold=$tol*1.5 if($ire > 0 && $ire <= 3.1001);
 }
 $threshold=0.6 if($threshold < 0.6);
 return undef if(abs($lum_pct) <= $threshold);
	 my $max_step=low_shadow_luminance_max_step($luminance_err,$stalls,$step);
	 $max_step=1 if($micro && $max_step > 1);
	 my $adjustments=neutral_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,0.25,$max_step,1);
 if(!$adjustments && abs($lum_pct) > ($tol*2.0)) {
  $adjustments=force_low_shadow_luminance_adjustment($arrays,$target,$luminance_err,$tried,0.25,$max_step);
 }
 if(ref($adjustments) eq "ARRAY") {
  foreach my $adj (@{$adjustments}) {
   $adj->{"low_shadow_luminance"}=1 if(ref($adj) eq "HASH");
  }
 }
	 return $adjustments;
}

sub cap_post_commit_low_shadow_adjustment {
 my ($adj,$ire)=@_;
 return undef if(ref($adj) ne "HASH");
 my $channel=$adj->{"channel"}||"";
 my $is_lum=($channel eq "lum" || ($adj->{"setting"}||"") eq "adjustingLuminance") ? 1 : 0;
 my $cap;
 if($is_lum) {
  $cap=($ire <= 3.1001) ? 0.25 : (($ire <= 5.1001) ? 0.5 : 1);
 } else {
  $cap=($ire <= 4.1001) ? 0.20 : (($ire <= 5.1001) ? 0.25 : 0.5);
 }
 my $delta=$adj->{"delta"};
 if(defined($delta)) {
  $delta+=0;
  return undef if(abs($delta) < 0.0001);
  if(abs($delta) > $cap) {
   my $current=defined($adj->{"current"}) ? ($adj->{"current"}+0) : undef;
   $current=($adj->{"next"}+0)-$delta if(!defined($current) && defined($adj->{"next"}));
   $current=0 if(!defined($current));
   my $next=clamp_ddc_value($current+(($delta < 0) ? -$cap : $cap));
   return undef if(abs($next-$current) < 0.0001);
   $adj={%{$adj}, current=>$current, next=>$next, delta=>$next-$current, capped_post_commit_low_shadow=>1};
  }
 }
 $adj->{"post_commit_low_shadow"}=1;
 return $adj;
}

sub post_commit_low_shadow_adjustments {
 my ($adjustments,$step,$lum_pct)=@_;
 return $adjustments if(!autocal_step_is_low_shadow($step));
 return undef if(ref($adjustments) ne "ARRAY" || !@{$adjustments});
 my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : 5;
 my @lum=grep {
  ref($_) eq "HASH" &&
  ((($_->{"channel"}||"") eq "lum") || (($_->{"setting"}||"") eq "adjustingLuminance"))
 } @{$adjustments};

	 if(@lum && low_ire_luminance_needs_tuning($step,$lum_pct)) {
	  my @capped=grep { defined($_) } map { cap_post_commit_low_shadow_adjustment($_,$ire) } @lum;
	  return \@capped if(@capped);
	 }

 my @filtered;
 foreach my $adj (@{$adjustments}) {
  my $capped=cap_post_commit_low_shadow_adjustment($adj,$ire);
  push @filtered,$capped if(ref($capped) eq "HASH");
 }
 return @filtered ? \@filtered : undef;
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
	 my $headroom_floor=$micro ? 0.0020 : 0.0030;
	 $floor=$headroom_floor if($floor < $headroom_floor);
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
	  my $step=headroom_adjustment_step(abs($err),$stalls,$min_step,$max_step,$micro);
	  $step=$max_step if(defined($max_step) && $step > $max_step);
	  my $direction=($err > 0) ? -1 : 1;
	  my ($next,$damped)=next_new_headroom_value($current,$direction*$step,$tried,$setting,$min_step);
	  next if(!defined($next) || abs($next-$current) < 0.0001);
	  return [{ channel=>$ch, setting=>$setting, current=>$current, next=>$next, delta=>$next-$current, damped=>$damped ? 1 : 0, headroom_chroma=>1, micro=>$micro ? 1 : 0 }];
	 }
	 return undef;
}

sub headroom_reduce_only_chroma_adjustment {
	 my ($error,$arrays,$target,$de,$stalls,$tried,$min_step,$max_step,$micro)=@_;
	 return undef if(ref($error) ne "HASH" || ref($arrays) ne "HASH" || ref($target) ne "HASH");
	 $min_step ||= 0.25;
	 $max_step ||= ($micro ? 1 : 4);
	 my $floor=rgb_error_floor($de,0.5,$micro ? 1 : 0);
	 my $headroom_floor=$micro ? 0.0020 : 0.0030;
	 $floor=$headroom_floor if($floor < $headroom_floor);
	 my @channels=sort { ($error->{$b}||0) <=> ($error->{$a}||0) } grep { ($error->{$_}||0) > $floor } qw(r g b);
	 foreach my $ch (@channels) {
	  my $setting=channel_setting($ch);
	  my $arr=$arrays->{$setting};
	  next if(ref($arr) ne "ARRAY");
	  my $idx=$target->{"index"};
	  next if(!defined($idx) || $idx >= @{$arr});
	  my $current=$arr->[$idx]||0;
	  my $step=headroom_adjustment_step(abs($error->{$ch}||0),$stalls,$min_step,$max_step,$micro);
	  $step=$max_step if(defined($max_step) && $step > $max_step);
	  my ($next,$damped)=next_new_headroom_value($current,-$step,$tried,$setting,$min_step);
	  next if(!defined($next) || abs($next-$current) < 0.0001);
	  return [{ channel=>$ch, setting=>$setting, current=>$current, next=>$next, delta=>$next-$current, damped=>$damped ? 1 : 0, headroom_reduce_only=>1, micro=>$micro ? 1 : 0 }];
	 }
	 return undef;
}

sub headroom_combo_key {
	 my ($adjustments)=@_;
	 return "" if(ref($adjustments) ne "ARRAY");
	 return join("|",sort map {
	  my $adj=$_;
	  (ref($adj) eq "HASH") ? (($adj->{"setting"}||"")."=".ddc_value_key($adj->{"next"})) : ()
	 } @{$adjustments});
}

sub headroom_pair_adjustment {
	 my ($error,$arrays,$target,$de,$stalls,$tried,$min_step,$max_step,$micro)=@_;
	 return undef if(($stalls||0) < 2);
	 return undef if(ref($error) ne "HASH" || ref($arrays) ne "HASH" || ref($target) ne "HASH" || ref($tried) ne "HASH");
	 $min_step ||= 0.25;
	 $max_step ||= 1;
	 my $floor=$micro ? 0.0020 : 0.0030;
	 my @channels=sort { abs($error->{$b}||0) <=> abs($error->{$a}||0) } grep { abs($error->{$_}||0) >= $floor } qw(r g b);
	 return undef if(@channels < 2);
	 $tried->{"__headroom_combo"}={} if(ref($tried->{"__headroom_combo"}) ne "HASH");
	 for(my $span=2;$span<=@channels && $span<=3;$span++) {
	  my @out;
	  my $blocked=0;
	  for(my $i=0;$i<$span;$i++) {
	   my $ch=$channels[$i];
	   my $err=$error->{$ch}||0;
	   my $setting=channel_setting($ch);
	   my $arr=$arrays->{$setting};
	   my $idx=$target->{"index"};
	   if(ref($arr) ne "ARRAY" || !defined($idx) || $idx >= @{$arr}) { $blocked=1; last; }
	   my $current=$arr->[$idx]||0;
	   my $step=headroom_adjustment_step(abs($err),$stalls,$min_step,$max_step,1);
	   my $direction=($err > 0) ? -1 : 1;
	   my $next=clamp_ddc_value($current+($direction*$step));
	   if(abs($next-$current) < 0.0001) { $blocked=1; last; }
	   push @out,{ channel=>$ch, setting=>$setting, current=>$current, next=>$next, delta=>$next-$current, damped=>0, headroom_pair=>1, micro=>$micro ? 1 : 0 };
	  }
	  next if($blocked || @out < 2);
	  my $key=headroom_combo_key(\@out);
	  next if($key eq "" || $tried->{"__headroom_combo"}{$key});
	  $tried->{"__headroom_combo"}{$key}={ count=>1, de=>defined($de) ? $de+0 : undef };
	  return \@out;
	 }
	 return undef;
}

sub headroom_peak_clip_relief_adjustment {
	 my ($error,$arrays,$target,$de,$stalls,$tried,$min_step,$max_step,$micro,$step)=@_;
	 return undef if(!autocal_step_is_peak_headroom($step || $target));
	 return undef if(($stalls||0) < 2);
	 return undef if(ref($error) ne "HASH" || ref($arrays) ne "HASH" || ref($target) ne "HASH");
	 $min_step ||= 0.25;
	 $max_step ||= ($micro ? 0.5 : 2);
	 my @low=sort { abs($error->{$b}||0) <=> abs($error->{$a}||0) } grep { ($error->{$_}||0) < -0.0030 } qw(r g b);
	 my @high=sort { ($error->{$b}||0) <=> ($error->{$a}||0) } grep { ($error->{$_}||0) > 0.0030 } qw(r g b);
	 return undef if(!@low || !@high);
	 my $drive=abs($error->{$low[0]}||0);
	 return undef if($drive < ($micro ? 0.004 : 0.008));
	 foreach my $ch (@high) {
	  my $setting=channel_setting($ch);
	  my $arr=$arrays->{$setting};
	  my $idx=$target->{"index"};
	  next if(ref($arr) ne "ARRAY" || !defined($idx) || $idx >= @{$arr});
	  my $current=$arr->[$idx]||0;
	  my $step_size=headroom_adjustment_step($drive,$stalls,$min_step,$max_step,$micro);
	  my ($next,$damped)=next_new_headroom_value($current,-$step_size,$tried,$setting,$min_step);
	  next if(!defined($next) || abs($next-$current) < 0.0001);
	  return [{ channel=>$ch, setting=>$setting, current=>$current, next=>$next, delta=>$next-$current, damped=>$damped ? 1 : 0, peak_clip_relief=>1, micro=>$micro ? 1 : 0 }];
	 }
	 return undef;
}

sub headroom_peak_combo_key {
	 my ($arrays,$target,$setting,$next)=@_;
	 return undef if(ref($arrays) ne "HASH" || ref($target) ne "HASH");
	 my $idx=$target->{"index"};
	 return undef if(!defined($idx));
	 my @parts;
	 foreach my $name (qw(whiteBalanceRed whiteBalanceGreen whiteBalanceBlue adjustingLuminance)) {
	  my $arr=$arrays->{$name};
	  next if(ref($arr) ne "ARRAY" || $idx >= @{$arr});
	  my $value=($name eq $setting) ? $next : ($arr->[$idx]||0);
	  push @parts,$name."=".ddc_value_key($value);
	 }
	 return join("|",@parts);
}

sub headroom_peak_combo_seen {
	 my ($tried,$arrays,$target,$setting,$next)=@_;
	 return 0 if(ref($tried) ne "HASH");
	 my $key=headroom_peak_combo_key($arrays,$target,$setting,$next);
	 return 0 if(!defined($key) || $key eq "");
	 $tried->{"__peak_headroom_combo"}={} if(ref($tried->{"__peak_headroom_combo"}) ne "HASH");
	 return 1 if($tried->{"__peak_headroom_combo"}{$key});
	 $tried->{"__peak_headroom_combo"}{$key}=1;
	 return 0;
}

sub headroom_peak_adjustment_combo_seen {
	 my ($tried,$arrays,$target,$adjustments)=@_;
	 return 0 if(ref($tried) ne "HASH" || ref($adjustments) ne "ARRAY");
	 return 0 if(ref($arrays) ne "HASH" || ref($target) ne "HASH");
	 my $idx=$target->{"index"};
	 return 0 if(!defined($idx));
	 my %override;
	 foreach my $adj (@{$adjustments}) {
	  next if(ref($adj) ne "HASH" || !defined($adj->{"setting"}));
	  $override{$adj->{"setting"}}=$adj->{"next"};
	 }
	 my @parts;
	 foreach my $name (qw(whiteBalanceRed whiteBalanceGreen whiteBalanceBlue adjustingLuminance)) {
	  my $arr=$arrays->{$name};
	  next if(ref($arr) ne "ARRAY" || $idx >= @{$arr});
	  my $value=exists($override{$name}) ? $override{$name} : ($arr->[$idx]||0);
	  push @parts,$name."=".ddc_value_key($value);
	 }
	 my $key=join("|",@parts);
	 return 0 if($key eq "");
	 $tried->{"__peak_headroom_combo"}={} if(ref($tried->{"__peak_headroom_combo"}) ne "HASH");
	 return 1 if($tried->{"__peak_headroom_combo"}{$key});
	 $tried->{"__peak_headroom_combo"}{$key}=1;
	 return 0;
}

sub next_peak_headroom_combo_value {
	 my ($arrays,$target,$current,$delta,$tried,$setting,$min_step)=@_;
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
	  return ($next,($mag != abs($delta))) if(!headroom_peak_combo_seen($tried,$arrays,$target,$setting,$next));
	 }
	 return (undef,0);
}

sub headroom_peak_wrgb_seed_adjustment {
	 my ($error,$arrays,$target,$de,$tried)=@_;
	 return undef if(ref($error) ne "HASH" || ref($arrays) ne "HASH" || ref($target) ne "HASH");
	 return undef if(!defined($de) || $de < 8);
	 return undef if(($error->{"b"}||0) < 0.08 || ($error->{"r"}||0) > -0.03);
	 my $idx=$target->{"index"};
	 return undef if(!defined($idx));
	 my %next=(
	  whiteBalanceRed => 9,
	  whiteBalanceGreen => -6,
	  whiteBalanceBlue => -13,
	 );
	 my @out;
	 foreach my $ch (qw(r g b)) {
	  my $setting=channel_setting($ch);
	  my $arr=$arrays->{$setting};
	  return undef if(ref($arr) ne "ARRAY" || $idx >= @{$arr});
	  my $current=$arr->[$idx]||0;
	  return undef if(abs($current) > 1.0001);
	  my $next=$next{$setting};
	  next if(abs($next-$current) < 0.0001);
	  push @out,{ channel=>$ch, setting=>$setting, current=>$current, next=>$next, delta=>$next-$current, peak_wrgb_seed=>1 };
	 }
	 return undef if(!@out || headroom_peak_adjustment_combo_seen($tried,$arrays,$target,\@out));
	 return \@out;
}

sub ddc_seed_adjustment {
	 my ($arrays,$target,$tried,$seed,$flag)=@_;
	 return undef if(ref($arrays) ne "HASH" || ref($target) ne "HASH" || ref($seed) ne "HASH");
	 my $idx=$target->{"index"};
	 return undef if(!defined($idx));
	 my @out;
	 foreach my $ch (qw(r g b lum)) {
	  my $setting=channel_setting($ch);
	  my $arr=$arrays->{$setting};
	  next if(ref($arr) ne "ARRAY" || $idx >= @{$arr} || !exists($seed->{$setting}));
	  my $current=$arr->[$idx]||0;
	  my $next=$seed->{$setting}+0;
	  next if(abs($next-$current) < 0.0001);
	  push @out,{ channel=>$ch, setting=>$setting, current=>$current, next=>$next, delta=>$next-$current, $flag=>1 };
	 }
	 return undef if(!@out || headroom_peak_adjustment_combo_seen($tried,$arrays,$target,\@out));
	 return \@out;
}

sub headroom_105_wrgb_seed_adjustment {
	 my ($error,$arrays,$target,$de,$tried,$step,$luminance_err)=@_;
	 return undef if(!autocal_step_is_fast_headroom($step) || autocal_step_is_peak_headroom($step));
	 return undef if(!defined($de) || $de < 2.5);
	 if(defined($luminance_err) && ($luminance_err*100) > headroom_luminance_control_gate_percent($step,0.50)) {
	  return undef;
	 }
	 return undef if(ref($arrays) ne "HASH" || ref($target) ne "HASH");
	 my $idx=$target->{"index"};
	 return undef if(!defined($idx));
	 my $lum_arr=$arrays->{"adjustingLuminance"};
	 if(ref($lum_arr) eq "ARRAY" && $idx < @{$lum_arr}) {
	  my $lum=$lum_arr->[$idx]||0;
	  return undef if(abs($lum) > 0.0001);
	 }
	 my $r=$arrays->{"whiteBalanceRed"}[$idx]||0;
	 my $g=$arrays->{"whiteBalanceGreen"}[$idx]||0;
	 my $b=$arrays->{"whiteBalanceBlue"}[$idx]||0;
	 return undef if(!(abs($r) <= 1.0001 && abs($g) <= 1.0001 && abs($b) <= 1.0001) && !(abs($r-9) <= 2.5001 && abs($g+6) <= 2.0001 && abs($b+13) <= 2.5001));
	 return ddc_seed_adjustment($arrays,$target,$tried,{
	  whiteBalanceRed => 4.25,
	  whiteBalanceGreen => -5.5,
	  whiteBalanceBlue => -13,
	 },"headroom_105_seed");
}

sub legal_white_pair_wrgb_seed_adjustment {
	 my ($arrays,$target,$de,$tried,$step)=@_;
	 return undef if(!strict_tried_for_step($step));
	 return undef if(!defined($de) || $de < 4);
	 return undef if(ref($arrays) ne "HASH" || ref($target) ne "HASH");
	 my $idx=$target->{"index"};
	 return undef if(!defined($idx));
	 my $r=$arrays->{"whiteBalanceRed"}[$idx]||0;
	 my $g=$arrays->{"whiteBalanceGreen"}[$idx]||0;
	 my $b=$arrays->{"whiteBalanceBlue"}[$idx]||0;
	 return undef if(abs($r) > 1.0001 || abs($g) > 1.0001 || abs($b) > 1.0001);
	 return ddc_seed_adjustment($arrays,$target,$tried,{
	  whiteBalanceRed => 3,
	  whiteBalanceGreen => 1,
	  whiteBalanceBlue => -7,
	 },"legal_white_pair_seed");
}

sub headroom_peak_match_low_adjustment {
	 my ($error,$arrays,$target,$de,$stalls,$tried,$min_step,$max_step,$micro,$step)=@_;
	 return undef if(!autocal_step_is_peak_headroom($step || $target));
	 return undef if(ref($error) ne "HASH" || ref($arrays) ne "HASH" || ref($target) ne "HASH");
	 $min_step ||= ($micro ? 0.10 : 0.25);
	 $max_step ||= ($micro ? 0.5 : 6);
	 my @ordered=sort { ($error->{$a}||0) <=> ($error->{$b}||0) } qw(r g b);
	 my $low=$ordered[0];
	 return undef if(!$low || !defined($error->{$low}));
	 my $low_err=$error->{$low}+0;
	 my $floor=$micro ? 0.0018 : 0.0040;
	 my @positive=sort { ($error->{$b}||0) <=> ($error->{$a}||0) }
	  grep { $_ ne $low && defined($error->{$_}) && ($error->{$_}+0) > $floor } qw(r g b);
	 my $match_low_mode=@positive ? 0 : 1;
	 my @high=@positive;
	 if(!@high) {
	  @high=sort { (($error->{$b}||0)-$low_err) <=> (($error->{$a}||0)-$low_err) }
	   grep { $_ ne $low && defined($error->{$_}) && (($error->{$_}+0)-$low_err) > $floor } qw(r g b);
	 }
	 return undef if(!@high);
	 my $idx=$target->{"index"};
	 return undef if(!defined($idx));
	 my @out;
	 my $limit=$micro ? 1 : 2;
	 foreach my $ch (@high) {
	  last if(@out >= $limit);
	  my $setting=channel_setting($ch);
	  my $arr=$arrays->{$setting};
	  next if(ref($arr) ne "ARRAY" || $idx >= @{$arr});
	  my $current=$arr->[$idx]||0;
	  my $gap=$match_low_mode ? (($error->{$ch}+0)-$low_err) : ($error->{$ch}+0);
	  my $step_size=headroom_adjustment_step($gap,$stalls,$min_step,$max_step,$micro);
	  $step_size=$max_step if(defined($max_step) && $step_size > $max_step);
	  my ($next,$damped)=next_peak_headroom_combo_value($arrays,$target,$current,-$step_size,$tried,$setting,$min_step);
	  next if(!defined($next) || abs($next-$current) < 0.0001);
	  push @out,{ channel=>$ch, setting=>$setting, current=>$current, next=>$next, delta=>$next-$current, damped=>$damped ? 1 : 0, peak_match_low=>1, frozen_channel=>$low, error_gap=>$gap+0, positive_headroom=>$match_low_mode ? 0 : 1, micro=>$micro ? 1 : 0 };
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
	 my $current_de=autocal_delta_e_for_step($config,$reading,$step,$white_y,$target_x,$target_y,$target_step_y);
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
		  my $candidate_de=autocal_delta_e_for_step($config,$before,$probe_step,$white_y,$target_x,$target_y,$candidate_target_y);
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
		 $step_size=headroom_adjustment_step(abs($err),$stalls,$min_step,10,0);
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

sub round_ddc_fifth {
	 my ($value)=@_;
	 $value=0 if(!defined($value));
	 my $rounded=($value >= 0) ? int($value*5+0.5)/5 : int($value*5-0.5)/5;
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
 my $before_err=autocal_adjustment_error($before,$step);
 my $after_err=autocal_adjustment_error($after,$step);
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

sub headroom_queued_adjustment_still_best {
 my ($adjustments,$error,$de,$target_delta,$step)=@_;
 return 0 if(!autocal_step_is_fast_headroom($step));
 return 0 if(ref($adjustments) ne "ARRAY" || @{$adjustments} != 1 || ref($error) ne "HASH");
 my $adj=$adjustments->[0];
 return 0 if(ref($adj) ne "HASH");
 my $ch=$adj->{"channel"}||"";
 return 0 if($ch !~ /^(?:r|g|b)$/);
 my $ch_err=abs($error->{$ch}||0);
 my $floor=rgb_error_floor($de,$target_delta,0);
 $floor=0.00055 if($floor < 0.00055);
 return 0 if($ch_err < $floor);
 foreach my $other (qw(r g b)) {
  next if($other eq $ch);
  my $other_err=abs($error->{$other}||0);
  return 0 if($other_err > $ch_err+0.00025);
 }
 return 1;
}

sub rgb_response_close_threshold {
	 my ($de,$target_delta)=@_;
	 $target_delta=0.5 if(!defined($target_delta) || $target_delta <= 0);
	 return 0.0020 if(defined($de) && $de <= ($target_delta+0.20));
	 return 0.0030 if(defined($de) && $de <= 1.0);
	 return 0.0040 if(defined($de) && $de <= 2.0);
	 return 0.0050;
}

sub furthest_rgb_error_channel {
	 my ($error)=@_;
	 return (undef,undef,0) if(ref($error) ne "HASH");
	 my ($best_ch,$best_err,$best_abs);
	 foreach my $ch (qw(r g b)) {
	  next if(!defined($error->{$ch}));
	  my $err=$error->{$ch}+0;
	  my $abs=abs($err);
	  if(!defined($best_abs) || $abs > $best_abs) {
	   ($best_ch,$best_err,$best_abs)=($ch,$err,$abs);
	  }
	 }
	 return ($best_ch,$best_err,$best_abs||0);
}

sub body_final_micro_threshold {
 my ($de,$target_delta)=@_;
 $target_delta=0.5 if(!defined($target_delta) || $target_delta <= 0);
 return 0.0022 if(defined($de) && $de <= ($target_delta+0.12));
 return 0.0028 if(defined($de) && $de <= ($target_delta+0.30));
 return 0.0035;
}

sub body_final_micro_near_target_reached {
 my ($step,$de,$lum_pct,$target_delta)=@_;
 my $near=body_itp_near_target_reached($step,$de,$lum_pct,$target_delta);
 if(!$near && ref($step) eq "HASH" && defined($step->{"ire"}) && ($step->{"ire"}+0) <= 10.0001) {
  $near=low_shadow_itp_near_target_reached($step,$de,$lum_pct,$target_delta) || low_shadow_good_enough($step,$de,$lum_pct,$target_delta);
 }
 return $near ? 1 : 0;
}

sub body_final_micro_adjustments {
 my ($reading,$arrays,$target,$step,$target_delta,$de,$lum_pct,$tried)=@_;
 return undef if(!autocal_step_allows_body_final_micro($step));
 return undef if(ref($reading) ne "HASH" || ref($arrays) ne "HASH" || ref($target) ne "HASH");
 return undef if(!body_final_micro_near_target_reached($step,$de,$lum_pct,$target_delta));
 my $error=autocal_adjustment_error($reading,$step);
 my ($ch,$err,$max_err)=furthest_rgb_error_channel($error);
 return undef if(!$ch);
 my $threshold=body_final_micro_threshold($de,$target_delta);
 return undef if($max_err < $threshold);
 my $setting=channel_setting($ch);
 my $arr=$arrays->{$setting};
 my $idx=$target->{"index"};
 return undef if(ref($arr) ne "ARRAY" || !defined($idx) || $idx >= @{$arr});
 my $current=defined($arr->[$idx]) ? ($arr->[$idx]+0) : 0;
 my $direction=($err > 0) ? -1 : 1;
 foreach my $step_size (0.20,0.10) {
  my ($next,$damped)=next_untried_value($current,$direction*$step_size,$tried,$setting,$step_size,strict_tried_for_step($step));
  next if(!defined($next) || abs($next-$current) < 0.0001);
  return [{ channel=>$ch, setting=>$setting, current=>$current, next=>$next, delta=>$next-$current, damped=>$damped ? 1 : 0, micro=>1, body_final_micro=>1 }];
 }
 return undef;
}

sub update_rgb_response_model {
	 my ($model,$adjustments,$before,$after,$step)=@_;
	 return undef if(ref($model) ne "HASH" || ref($adjustments) ne "ARRAY" || @{$adjustments} != 1);
	 return undef if(ref($before) ne "HASH" || ref($after) ne "HASH");
	 my $adj=$adjustments->[0];
	 return undef if(ref($adj) ne "HASH");
	 my $ch=$adj->{"channel"}||"";
	 return undef if($ch !~ /^(?:r|g|b)$/);
	 return undef if($adj->{"neutral_luminance"} || $adj->{"green_luminance"} || $adj->{"brightness_luminance"} || $adj->{"match_green"});
	 my $delta=defined($adj->{"delta"}) ? ($adj->{"delta"}+0) : 0;
	 return undef if(abs($delta) < 0.0001 || abs($delta) > 1.0001);
	 my $before_err=autocal_adjustment_error($before,$step);
	 my $after_err=autocal_adjustment_error($after,$step);
	 return undef if(ref($before_err) ne "HASH" || ref($after_err) ne "HASH");
	 return undef if(!defined($before_err->{$ch}) || !defined($after_err->{$ch}));
	 my $e0=$before_err->{$ch}+0;
	 my $e1=$after_err->{$ch}+0;
	 my $slope=($e1-$e0)/$delta;
	 return undef if(abs($slope) < 0.00005);
	 my $samples=1;
	 if(ref($model->{$ch}) eq "HASH" && defined($model->{$ch}{"slope"})) {
	  my $old=$model->{$ch}{"slope"}+0;
	  if(($old < 0 && $slope < 0) || ($old > 0 && $slope > 0)) {
	   $slope=($old*0.65)+($slope*0.35);
	   $samples=($model->{$ch}{"samples"}||1)+1;
	  }
	 }
	 $model->{$ch}={
	  slope=>$slope+0,
	  samples=>$samples+0,
	  before_error=>$e0+0,
	  after_error=>$e1+0,
	  delta=>$delta+0
	 };
	 return $model->{$ch};
}

sub choose_rgb_response_adjustments {
	 my ($error,$arrays,$target,$model,$tried,$de,$step,$target_delta,$stalls)=@_;
	 return undef if(autocal_step_is_fast_headroom($step));
	 return undef if(ref($error) ne "HASH" || ref($arrays) ne "HASH" || ref($target) ne "HASH");
	 my $paired_white=strict_tried_for_step($step);
	 my ($ch,$err,$max_err)=furthest_rgb_error_channel($error);
	 return undef if(!$ch);
	 my $threshold=rgb_response_close_threshold($de,$target_delta);
	 return undef if($max_err < $threshold);
	 my $setting=channel_setting($ch);
	 my $arr=$arrays->{$setting};
	 my $idx=$target->{"index"};
	 return undef if(ref($arr) ne "ARRAY" || !defined($idx) || $idx >= @{$arr});
	 my $current=defined($arr->[$idx]) ? ($arr->[$idx]+0) : 0;
	 my $entry=(ref($model) eq "HASH") ? $model->{$ch} : undef;
	 if(ref($entry) eq "HASH" && defined($entry->{"slope"}) && abs($entry->{"slope"}) >= 0.00005) {
	  my $slope=$entry->{"slope"}+0;
	  my $raw_delta=-$err/$slope;
	  my $max_jump=(defined($de) && $de > 4) ? 10 : ((defined($de) && $de > 2) ? 6 : 4);
	  if($paired_white) {
	   $max_jump=(defined($de) && $de > (($target_delta||0.5)+1.0) && $max_err > 0.018) ? 1.0 : 0.5;
	  } else {
	   $max_jump=12 if(($stalls||0) >= 2 && $max_jump < 12);
	  }
	  $raw_delta=$max_jump if($raw_delta > $max_jump);
	  $raw_delta=-$max_jump if($raw_delta < -$max_jump);
	  my $min_delta=$paired_white ? 0.10 : 0.20;
	  return undef if(abs($raw_delta) < $min_delta);
	  foreach my $scale (1,0.75,0.50,0.25) {
	   my $next=$paired_white ? round_ddc_quarter($current+($raw_delta*$scale)) : round_ddc_fifth($current+($raw_delta*$scale));
	   next if(abs($next-$current) < ($paired_white ? 0.0999 : 0.1999));
	   next if(tried_value_exists($tried,$setting,$next));
	   my $actual_delta=$next-$current;
	   my $predicted=$err+($slope*$actual_delta);
	   next if(abs($predicted) >= abs($err)*0.92 && abs($actual_delta) > 0.21);
	   return [{ channel=>$ch, setting=>$setting, current=>$current, next=>$next, delta=>$actual_delta, response_model=>1, slope=>$slope, predicted_error=>$predicted, paired_white=>$paired_white ? 1 : 0 }];
	  }
	 }
	 my $direction=($err > 0) ? -1 : 1;
	 my $probe_step=$paired_white ? ((defined($de) && $de > (($target_delta||0.5)+1.0) && $max_err > 0.018) ? 0.5 : 0.25) : 1;
	 my ($next,$damped)=next_untried_value($current,$direction*$probe_step,$tried,$setting,0.25,$paired_white);
	 return undef if(!defined($next) || abs($next-$current) < 0.0001);
	 return [{ channel=>$ch, setting=>$setting, current=>$current, next=>$next, delta=>$next-$current, response_probe=>1, damped=>$damped ? 1 : 0, paired_white=>$paired_white ? 1 : 0 }];
	}

sub choose_adjustments {
					 my ($error,$arrays,$target,$de,$min_step,$stalls,$luminance_err,$tried,$step)=@_;
				 return undef if(ref($error) ne "HASH" || ref($target) ne "HASH");
			 $min_step ||= 0.25;
				 $luminance_err=0 if(!defined($luminance_err));
				 my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : 100;
				 my $strict_tried=strict_tried_for_step($step);
				 $luminance_err=0 if($ire >= 99.9 && !autocal_step_is_fast_headroom($step));
				 if(autocal_step_is_fast_headroom($step)) {
				  my $lum_pct=$luminance_err*100;
				  my $luma_tol=headroom_luminance_control_gate_percent($step,1);
				  my $chroma_mag=chroma_error_magnitude($error);
					  if(!autocal_step_is_peak_headroom($step) && has_luminance_channel($arrays,$target) && abs($lum_pct) > $luma_tol) {
					   my $max_luma_step=abs($luminance_err) >= 0.035 ? 4 : (abs($luminance_err) >= 0.015 ? 2 : 1);
					   my $rgb_luma=headroom_rgb_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_step,$max_luma_step);
					   return $rgb_luma if($rgb_luma);
					  }
					  if(!autocal_step_is_peak_headroom($step) && $lum_pct > $luma_tol) {
					   my $reduce=headroom_reduce_only_chroma_adjustment($error,$arrays,$target,$de,$stalls,$tried,$min_step,4,0);
					   return $reduce if($reduce);
					  }
				  my $headroom_seed=headroom_105_wrgb_seed_adjustment($error,$arrays,$target,$de,$tried,$step,$luminance_err);
				  return $headroom_seed if($headroom_seed);
				  if(autocal_step_is_peak_headroom($step)) {
				   my $wrgb_seed=headroom_peak_wrgb_seed_adjustment($error,$arrays,$target,$de,$tried);
				   return $wrgb_seed if($wrgb_seed);
			   my $match_low=headroom_peak_match_low_adjustment($error,$arrays,$target,$de,$stalls,$tried,$min_step,6,0,$step);
			   return $match_low if($match_low);
			   return undef;
			  }
			  if(!autocal_step_is_peak_headroom($step) && abs($lum_pct) > $luma_tol && $chroma_mag < 0.035) {
			   my $max_luma_step=abs($luminance_err) >= 0.035 ? 4 : (abs($luminance_err) >= 0.015 ? 2 : 1);
			   my $rgb_luma=headroom_rgb_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_step,$max_luma_step);
			   return $rgb_luma if($rgb_luma);
			  }
			  my $clip=headroom_peak_clip_relief_adjustment($error,$arrays,$target,$de,$stalls,$tried,$min_step,2,0,$step);
			  return $clip if($clip);
			  if(!autocal_step_is_peak_headroom($step) && $lum_pct > $luma_tol) {
			   my $reduce=headroom_reduce_only_chroma_adjustment($error,$arrays,$target,$de,$stalls,$tried,$min_step,4,0);
			   return $reduce if($reduce);
			   return undef;
			  }
			  my $pair=headroom_pair_adjustment($error,$arrays,$target,$de,$stalls,$tried,$min_step,1,0);
			  return $pair if($pair);
			  my $chroma=headroom_chroma_adjustment($error,$arrays,$target,$de,$stalls,$tried,$min_step,6,0);
			  return $chroma if($chroma);
			  if(!autocal_step_is_peak_headroom($step) && abs($lum_pct) > $luma_tol) {
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
			  my $shadow_luma=low_shadow_luminance_priority_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,$step,0);
			  return $shadow_luma if($shadow_luma);
			 }
				 if($strict_tried) {
				  my $pair_seed=legal_white_pair_wrgb_seed_adjustment($arrays,$target,$de,$tried,$step);
				  return $pair_seed if($pair_seed);
				 }
				 if($ire <= 10.0001 && has_luminance_channel($arrays,$target) && abs($lum_pct) > ($luma_tol*1.05)) {
				  my $max_luma_step=abs($luminance_err) >= 0.20 ? 4 : (abs($luminance_err) >= 0.08 ? 2 : 1);
				  my $neutral=neutral_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,0.25,$max_luma_step,$strict_tried);
				  return $neutral if($neutral);
				 }
				 if($ire > 10.0001 && $ire <= 35.0001 && has_luminance_channel($arrays,$target) && abs($lum_pct) > ($luma_tol*0.75)) {
				  my $neutral=neutral_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,0.25,1,$strict_tried);
				  return $neutral if($neutral);
				 }
				 if($ire > 35.0001 && $ire <= 50.0001 && has_luminance_channel($arrays,$target) && abs($lum_pct) > ($luma_tol*0.80)) {
				  my $neutral=neutral_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,0.25,1,$strict_tried);
				  return $neutral if($neutral);
				 }
				 if($ire < 90 && has_luminance_channel($arrays,$target) && abs($lum_pct) > (($luma_tol*3) > 8 ? ($luma_tol*3) : 8)) {
				  my $max_luma_step=abs($luminance_err) >= 0.20 ? 6 : 4;
				  my $neutral=neutral_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_step,$max_luma_step,$strict_tried);
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
				 if(has_luminance_channel($arrays,$target) && abs($lum_pct) > ($luma_tol*0.35)) {
				  my $max_luma_step=abs($luminance_err) >= 0.20 ? 6 : 3;
				  my $neutral=neutral_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_step,$max_luma_step,$strict_tried);
				  if($neutral) {
				   my $luma_takeover=($chroma_mag < 0.012 || ($near_fine && $chroma_mag < 0.020) || (defined($de) && $de <= 3.0 && $chroma_mag < 0.035 && abs($lum_pct) > ($luma_tol*1.10))) ? 1 : 0;
			   return $neutral if($luma_takeover);
			   push @out,@{$neutral} if($chroma_mag < 0.025 && abs($lum_pct) > ($luma_tol*0.75));
			  }
			 }
			 if(abs($lum_pct) > ($luma_tol*0.55) && chroma_error_magnitude($error) < 0.020) {
			  my $neutral=neutral_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_step,2,$strict_tried);
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
			   my ($next,$damped)=next_untried_value($current,$try_delta,$tried,$setting,$min_step,$strict_tried);
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
					 my ($error,$arrays,$target,$luminance_err,$tried,$max_step,$de,$stalls,$step,$target_delta)=@_;
					 return undef if(ref($error) ne "HASH" || ref($arrays) ne "HASH" || ref($target) ne "HASH");
					 $luminance_err=0 if(!defined($luminance_err));
						 my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : 100;
						 my $strict_tried=strict_tried_for_step($step);
						 $luminance_err=0 if($ire >= 99.9 && !autocal_step_is_fast_headroom($step));
				 $target_delta=0.5 if(!defined($target_delta) || $target_delta <= 0);
				 my $itp_precision=autocal_itp_precision_polish_needed($de,$target_delta,$step);
				 my $paired_white=$strict_tried ? 1 : 0;
				 $max_step=0.10 if(!defined($max_step) || $max_step < 0.10);
				 if($paired_white) {
				  my $pair_cap=(defined($de) && $de > ($target_delta+0.75)) ? 0.25 : 0.10;
				  $max_step=$pair_cap if($max_step > $pair_cap);
				 } else {
				  $max_step=1.0 if($itp_precision && defined($de) && $de > ($target_delta*1.8) && $max_step < 1.0);
				  $max_step=($itp_precision ? 1.0 : 0.5) if($max_step > ($itp_precision ? 1.0 : 0.5));
				 }
				 my $min_micro_step=($max_step < 0.20) ? $max_step : 0.20;
			 my $lum_pct=$luminance_err*100;
			 my $luma_tol=luminance_tolerance_percent($step);
			 if(autocal_step_is_low_shadow($step)) {
			  my $shadow_luma=low_shadow_luminance_priority_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,$step,1);
			  return $shadow_luma if($shadow_luma);
			 }
				 if($ire <= 10.0001 && has_luminance_channel($arrays,$target) && abs($lum_pct) > ($luma_tol*0.85)) {
				  my $luma_max_step=abs($luminance_err) >= 0.20 ? 4 : (abs($luminance_err) >= 0.08 ? 2 : $max_step);
				  my $neutral=neutral_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,0.25,$luma_max_step,$strict_tried);
				  return $neutral if($neutral);
				 }
				 if($ire > 10.0001 && $ire <= 35.0001 && has_luminance_channel($arrays,$target) && abs($lum_pct) > ($luma_tol*0.60)) {
				  my $neutral=neutral_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,0.25,$max_step,$strict_tried);
				  return $neutral if($neutral);
				 }
				 if($ire > 35.0001 && $ire <= 50.0001 && has_luminance_channel($arrays,$target) && abs($lum_pct) > ($luma_tol*0.70)) {
				  my $neutral=neutral_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,0.25,$max_step,$strict_tried);
				  return $neutral if($neutral);
				 }
				 if(autocal_step_is_fast_headroom($step)) {
				  my $chroma_mag=chroma_error_magnitude($error);
				  my $luma_gate=headroom_luminance_control_gate_percent($step,0.45);
				  if(autocal_step_is_peak_headroom($step)) {
				   my $wrgb_seed=headroom_peak_wrgb_seed_adjustment($error,$arrays,$target,$de,$tried);
				   return $wrgb_seed if($wrgb_seed);
				   my $match_low=headroom_peak_match_low_adjustment($error,$arrays,$target,$de,$stalls,$tried,$min_micro_step,$max_step,1,$step);
				   return $match_low if($match_low);
				   return undef;
				  }
					  if(has_luminance_channel($arrays,$target) && abs($lum_pct) > $luma_gate) {
					   my $luma_max_step=abs($luminance_err) >= 0.035 ? 2 : (abs($luminance_err) >= 0.015 ? 1 : $max_step);
					   my $rgb_luma=headroom_rgb_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_micro_step,$luma_max_step);
					   return $rgb_luma if($rgb_luma);
					   if($lum_pct > $luma_gate) {
					    my $reduce=headroom_reduce_only_chroma_adjustment($error,$arrays,$target,$de,$stalls,$tried,$min_micro_step,$max_step,1);
					    return $reduce if($reduce);
					   }
					  }
				  my $headroom_seed=headroom_105_wrgb_seed_adjustment($error,$arrays,$target,$de,$tried,$step,$luminance_err);
				  return $headroom_seed if($headroom_seed);
			  if(!autocal_step_is_peak_headroom($step) && abs($lum_pct) > $luma_gate && $chroma_mag < 0.030) {
			   my $luma_max_step=abs($luminance_err) >= 0.035 ? 2 : (abs($luminance_err) >= 0.015 ? 1 : $max_step);
			   my $rgb_luma=headroom_rgb_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_micro_step,$luma_max_step);
			   return $rgb_luma if($rgb_luma);
			  }
			  my $clip=headroom_peak_clip_relief_adjustment($error,$arrays,$target,$de,$stalls,$tried,$min_micro_step,$max_step,1,$step);
			  return $clip if($clip);
			  if(!autocal_step_is_peak_headroom($step) && $lum_pct > $luma_gate) {
			   my $reduce=headroom_reduce_only_chroma_adjustment($error,$arrays,$target,$de,$stalls,$tried,$min_micro_step,$max_step,1);
			   return $reduce if($reduce);
			   return undef;
			  }
			  my $pair=headroom_pair_adjustment($error,$arrays,$target,$de,$stalls,$tried,$min_micro_step,$max_step,1);
			  return $pair if($pair);
			  my $chroma=headroom_chroma_adjustment($error,$arrays,$target,$de,$stalls,$tried,$min_micro_step,$max_step,1);
			  return $chroma if($chroma);
			  if(!autocal_step_is_peak_headroom($step) && abs($lum_pct) > $luma_gate) {
			   my $luma_max_step=abs($luminance_err) >= 0.04 ? 1 : $max_step;
			   my $rgb_luma=headroom_rgb_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_micro_step,$luma_max_step);
			   return $rgb_luma if($rgb_luma);
			  }
			  my $fine_chroma=headroom_chroma_adjustment($error,$arrays,$target,$de,$stalls,$tried,$min_micro_step,$max_step,1);
			  return $fine_chroma if($fine_chroma);
			  if(!autocal_step_is_peak_headroom($step) && abs($lum_pct) > headroom_luminance_control_gate_percent($step,0.20)) {
			   my $rgb_luma=headroom_rgb_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_micro_step,$max_step);
			   return $rgb_luma if($rgb_luma);
			  }
			  return undef;
			 }
				 if($paired_white) {
				  my $pair_seed=legal_white_pair_wrgb_seed_adjustment($arrays,$target,$de,$tried,$step);
				  return $pair_seed if($pair_seed);
				 }
					 if(has_luminance_channel($arrays,$target) && abs($lum_pct) > ($luma_tol*0.35)) {
					  my $luma_max_step=$max_step;
					  $luma_max_step=4 if(abs($luminance_err) >= 0.20 && $luma_max_step < 4);
					  $luma_max_step=2 if(abs($luminance_err) >= 0.08 && $luma_max_step < 2);
					  my $neutral=neutral_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,0.25,$luma_max_step,$strict_tried);
					  return $neutral if($neutral && ((defined($de) && $de <= 3.0) || chroma_error_magnitude($error) < 0.015));
					 }
				 if(abs($lum_pct) > ($luma_tol*0.45) && chroma_error_magnitude($error) < 0.016) {
				  my $neutral=neutral_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,0.25,$max_step,$strict_tried);
				  return $neutral if($neutral);
				 }
				 my $luminance_drive=has_luminance_channel($arrays,$target) ? 0 : luminance_adjustment_drive($luminance_err);
	 my %combined=map { $_ => (($error->{$_}||0)+$luminance_drive) } qw(r g b);
	 my @channels=sort { abs($combined{$b}||0) <=> abs($combined{$a}||0) } qw(r g b);
	 my @magnitudes;
	 foreach my $mag ($max_step,1.0,0.5,0.20) {
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
			    my ($next,$damped)=next_untried_value($current,$dir*$mag,$tried,$setting,$min_micro_step,$strict_tried);
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
				    my ($next,$damped)=next_untried_value($current,$dir*$mag,$tried,$setting,$min_micro_step,$strict_tried);
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

sub clear_state_step_measurements {
 my ($state)=@_;
 return if(ref($state) ne "HASH");
 foreach my $key (qw(current_delta_e best_delta_e best_score response_score luminance_error_pct target_step_luminance current_luminance iteration paired_delta_e paired_luminance_error_pct paired_current_name meter_read_retry implausible_read_retry)) {
  delete($state->{$key});
 }
}

sub set_state_calibration_mode {
 my ($state,$active,$picture_mode)=@_;
 return if(ref($state) ne "HASH");
 $state->{"calibration_mode"}=$active ? JSON::PP::true : JSON::PP::false;
 if($active) {
  $state->{"calibration_picture_mode"}=$picture_mode if(defined($picture_mode) && $picture_mode ne "");
 } else {
  delete($state->{"calibration_picture_mode"});
 }
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
	  if($verify_ddc_upload && (!$response->{"ddc_1d_lut"} || !$response->{"ddc_upload_verified"})) {
	   $last_message=$response->{"message"}||"LG DDC 1D LUT upload did not verify against the TV readback";
	   last;
	  }
	  if(ref($state) eq "HASH") {
	   $state->{"ddc_1d_lut"}=JSON::PP::true if($response->{"ddc_1d_lut"});
	   $state->{"ddc_upload_verified"}=$response->{"ddc_upload_verified"} ? JSON::PP::true : JSON::PP::false
	    if(exists($response->{"ddc_upload_verified"}) || $verify_ddc_upload);
	  }
	  set_state_calibration_mode($state,$response->{"calibration_mode"} ? 1 : 0,$response->{"calibration_picture_mode"}||$picture_mode||($picture->{"pictureMode"}||"")) if(exists($response->{"calibration_mode"}));
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
	 if(!$calibration_mode_active) {
	  $state->{"final_1d_lut_uploaded"}=JSON::PP::false if(ref($state) eq "HASH");
	  return ($picture,"Final LG 1D LUT was not uploaded because calibration mode was not active",0);
	 }
 my $target=undef;
 if(ref($ordered) eq "ARRAY") {
  foreach my $step (@{$ordered}) {
   $target=ddc_target_for_step($step);
   last if($target);
  }
 }
 # The final write uploads the full 1D arrays; this target only identifies the
 # helper's active/readback DDC slot.
	 if(ref($target) ne "HASH") {
	  $state->{"final_1d_lut_uploaded"}=JSON::PP::false if(ref($state) eq "HASH");
	  return ($picture,"Final LG 1D LUT was not uploaded because no DDC target was available",0);
	 }
 $state->{"current_name"}="Auto Cal commit";
 $state->{"phase"}="writing";
 $state->{"message"}="Uploading final 1024-point LG 1D LUT";
 write_state($state);
			 my ($next_picture,$error)=set_picture_values($picture,$arrays,$target,$picture_mode,1,$state,1,0);
			 return ($picture,$error,0) if($error);
			 sync_state_picture($state,$next_picture,$picture_mode);
			 end_calibration_mode($picture_mode);
			 set_state_calibration_mode($state,0,"");
			 $state->{"final_1d_lut_uploaded"}=JSON::PP::true;
			 $state->{"final_1d_lut_upload_verified"}=JSON::PP::true;
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

sub post_commit_polish_enabled {
	 my ($config)=@_;
	 return 0 if(ref($config) ne "HASH" || !$config->{"lg_autocal_26"});
	 return 1 if(!exists($config->{"post_commit_polish"}));
	 return $config->{"post_commit_polish"} ? 1 : 0;
}

sub committed_top_window_score {
 my ($window)=@_;
 return { score=>9999, worst=>9999, avg=>9999, over=>9999 } if(ref($window) ne "HASH" || ref($window->{"points"}) ne "HASH");
 my @ires=(109,105,99,100,95);
 my $sum=0;
 my $count=0;
 my $worst=0;
 my $over=0;
 foreach my $ire (@ires) {
  my $rec=$window->{"points"}{$ire};
  return { score=>9999, worst=>9999, avg=>9999, over=>9999 } if(ref($rec) ne "HASH" || !defined($rec->{"de"}));
  my $de=$rec->{"de"}+0;
  $sum+=$de;
  $count++;
  $worst=$de if($de > $worst);
  $over++ if($de > 1.0);
 }
 my $avg=$count ? ($sum/$count) : 9999;
 return {
  score => ($over*10)+$worst+($avg*0.25),
  worst => $worst,
  avg => $avg,
  over => $over,
 };
}

sub committed_top_window_score_passed {
 my ($score)=@_;
 return 0 if(ref($score) ne "HASH");
 return (($score->{"over"}||0) == 0 && ($score->{"worst"}||9999) <= 1.0) ? 1 : 0;
}

sub committed_top_window_candidate_allowed {
 my ($candidate,$best)=@_;
 return 0 if(ref($candidate) ne "HASH" || ref($best) ne "HASH");
 my $candidate_over=defined($candidate->{"over"}) ? ($candidate->{"over"}+0) : 9999;
 my $best_over=defined($best->{"over"}) ? ($best->{"over"}+0) : 9999;
 my $candidate_worst=defined($candidate->{"worst"}) ? ($candidate->{"worst"}+0) : 9999;
 my $best_worst=defined($best->{"worst"}) ? ($best->{"worst"}+0) : 9999;
 my $candidate_score=defined($candidate->{"score"}) ? ($candidate->{"score"}+0) : 9999;
 my $best_score=defined($best->{"score"}) ? ($best->{"score"}+0) : 9999;
 return 1 if($candidate_over < $best_over);
 return 0 if($candidate_over > $best_over);
 return 1 if($candidate_worst+0.03 < $best_worst);
 return 1 if($candidate_score+0.03 < $best_score && $candidate_worst <= ($best_worst+0.06));
 return 0;
}

sub committed_top_window_protected_worsened {
 my ($candidate_window,$best_window)=@_;
 return 0 if(ref($candidate_window) ne "HASH" || ref($best_window) ne "HASH");
 return 0 if(ref($candidate_window->{"points"}) ne "HASH" || ref($best_window->{"points"}) ne "HASH");
 my $candidate_score=committed_top_window_score($candidate_window);
 my $best_score=committed_top_window_score($best_window);
 my $candidate_over=defined($candidate_score->{"over"}) ? ($candidate_score->{"over"}+0) : 9999;
 my $best_over=defined($best_score->{"over"}) ? ($best_score->{"over"}+0) : 9999;
 my $candidate_worst=defined($candidate_score->{"worst"}) ? ($candidate_score->{"worst"}+0) : 9999;
 my $best_worst=defined($best_score->{"worst"}) ? ($best_score->{"worst"}+0) : 9999;
 my $candidate_total=defined($candidate_score->{"score"}) ? ($candidate_score->{"score"}+0) : 9999;
 my $best_total=defined($best_score->{"score"}) ? ($best_score->{"score"}+0) : 9999;
 # The guard is only meant to block trading one already-bad top-end point for
 # another. If a candidate materially reduces the number of failing points, keep
 # it instead of restoring a globally worse window.
 return 0 if($candidate_over < $best_over);
 return 0 if($candidate_worst+0.25 < $best_worst && $candidate_total+1.0 < $best_total);
 foreach my $ire (95,99,100,105) {
  my $candidate=$candidate_window->{"points"}{$ire};
  my $best=$best_window->{"points"}{$ire};
  next if(ref($candidate) ne "HASH" || ref($best) ne "HASH");
  next if(!defined($candidate->{"de"}) || !defined($best->{"de"}));
  my $candidate_de=$candidate->{"de"}+0;
  my $best_de=$best->{"de"}+0;
  return 1 if($candidate_de > 1.0 && $candidate_de > ($best_de+0.0001));
 }
 return 0;
}

sub committed_top_window_add_candidate {
 my ($out,$seen,$label,$changes)=@_;
 return if(ref($out) ne "ARRAY" || ref($seen) ne "HASH" || ref($changes) ne "ARRAY" || !@{$changes});
 my @parts;
 foreach my $change (@{$changes}) {
  next if(ref($change) ne "HASH");
  push @parts,join(":",$change->{"setting"}||"",defined($change->{"index"})?$change->{"index"}:"",ddc_value_key($change->{"delta"}));
 }
 return if(!@parts);
 my $key=join("|",sort @parts);
 return if($seen->{$key});
 $seen->{$key}=1;
 push @{$out},{ label=>$label, changes=>$changes };
}

sub committed_top_window_candidates {
 my ($window,$config)=@_;
 my @out;
 my %seen;
 my %influence=(
  95 => [22],
  99 => [23],
  100 => [23,24],
  105 => [24,25],
  109 => [25],
 );
 my @ranked=sort {
  (($window->{"points"}{$b}||{})->{"de"}||0) <=> (($window->{"points"}{$a}||{})->{"de"}||0)
 } grep { ref(($window->{"points"}{$_}||{})->{"reading"}) eq "HASH" } (95,99,100,105,109);
 my $rank_count=0;
 my $rank_limit=config_positive_int($config,"post_commit_top_window_worst_points",2,1,3);
 foreach my $ire (@ranked) {
  last if($rank_count++ >= $rank_limit);
	  my $reading=$window->{"points"}{$ire}{"reading"};
	  my $err=rgb_error($reading);
  my $lum_pct=$window->{"points"}{$ire}{"luminance_error_pct"};
  if(defined($lum_pct) && abs($lum_pct) >= 0.35) {
   my $dir=($lum_pct > 0) ? -1 : 1;
   foreach my $idx (@{$influence{$ire}||[]}) {
    foreach my $mag (0.25,0.50,0.125) {
     committed_top_window_add_candidate(\@out,\%seen,"top_${ire}_lum_${idx}_".ddc_value_key($dir*$mag),[
      { setting=>"adjustingLuminance", index=>$idx, delta=>$dir*$mag },
     ]);
    }
   }
  }
	  next if(ref($err) ne "HASH");
  my @channels=sort { abs($err->{$b}||0) <=> abs($err->{$a}||0) } qw(r g b);
  @channels=@channels[0,1] if(@channels > 2);
  foreach my $ch (@channels) {
   my $abs=abs($err->{$ch}||0);
   next if($abs < 0.0007);
   my $dir=($err->{$ch} > 0) ? -1 : 1;
   my $setting=channel_setting($ch);
   foreach my $idx (@{$influence{$ire}||[]}) {
    foreach my $mag (0.25,0.50,0.125) {
     committed_top_window_add_candidate(\@out,\%seen,"top_${ire}_${ch}_${idx}_".ddc_value_key($dir*$mag),[
      { setting=>$setting, index=>$idx, delta=>$dir*$mag },
     ]);
    }
	   }
	  }
	 }
	 foreach my $ch (qw(r g b)) {
	  my $setting=channel_setting($ch);
	  next if(!$setting);
	  my $err99=(ref($window->{"points"}{99}) eq "HASH" && ref($window->{"points"}{99}{"reading"}) eq "HASH") ? ((rgb_error($window->{"points"}{99}{"reading"})||{})->{$ch}) : undef;
	  my $err100=(ref($window->{"points"}{100}) eq "HASH" && ref($window->{"points"}{100}{"reading"}) eq "HASH") ? ((rgb_error($window->{"points"}{100}{"reading"})||{})->{$ch}) : undef;
	  my $err105=(ref($window->{"points"}{105}) eq "HASH" && ref($window->{"points"}{105}{"reading"}) eq "HASH") ? ((rgb_error($window->{"points"}{105}{"reading"})||{})->{$ch}) : undef;
	  my $err109=(ref($window->{"points"}{109}) eq "HASH" && ref($window->{"points"}{109}{"reading"}) eq "HASH") ? ((rgb_error($window->{"points"}{109}{"reading"})||{})->{$ch}) : undef;
	  foreach my $mag (0.125,0.25,0.50) {
	   if(defined($err99) && defined($err100) && abs($err99) >= 0.003 && abs($err100) >= 0.003 && (($err99 > 0 && $err100 < 0) || ($err99 < 0 && $err100 > 0))) {
	    committed_top_window_add_candidate(\@out,\%seen,"top_chain_99_100_${ch}_".ddc_value_key($mag),[
	     { setting=>$setting, index=>23, delta=>(($err99 > 0) ? -$mag : $mag) },
	     { setting=>$setting, index=>24, delta=>(($err100 > 0) ? -$mag : $mag) },
	    ]);
	   }
	   if(defined($err100) && defined($err105) && abs($err100) >= 0.003 && abs($err105) >= 0.003 && (($err100 > 0 && $err105 < 0) || ($err100 < 0 && $err105 > 0))) {
	    committed_top_window_add_candidate(\@out,\%seen,"top_chain_100_105_${ch}_".ddc_value_key($mag),[
	     { setting=>$setting, index=>24, delta=>(($err100 > 0) ? -$mag : $mag) },
	     { setting=>$setting, index=>25, delta=>(($err105 > 0) ? -$mag : $mag) },
	    ]);
	   }
	   if(
	    defined($err99) && defined($err100) && defined($err105) &&
	    abs($err99) >= 0.003 && abs($err100) >= 0.003 && abs($err105) >= 0.003 &&
	    (($err99 > 0 && $err100 < 0) || ($err99 < 0 && $err100 > 0)) &&
	    (($err100 > 0 && $err105 < 0) || ($err100 < 0 && $err105 > 0))
	   ) {
	    committed_top_window_add_candidate(\@out,\%seen,"top_chain_99_100_105_${ch}_".ddc_value_key($mag),[
	     { setting=>$setting, index=>23, delta=>(($err99 > 0) ? -$mag : $mag) },
	     { setting=>$setting, index=>24, delta=>(($err100 > 0) ? -$mag : $mag) },
	     { setting=>$setting, index=>25, delta=>(($err105 > 0) ? -$mag : $mag) },
	    ]);
	   }
	   if(defined($err105) && defined($err109) && abs($err105) >= 0.003 && abs($err109) >= 0.003 && (($err105 > 0 && $err109 < 0) || ($err105 < 0 && $err109 > 0))) {
	    committed_top_window_add_candidate(\@out,\%seen,"top_chain_105_109_${ch}_".ddc_value_key($mag),[
	     { setting=>$setting, index=>24, delta=>(($err105 > 0) ? -$mag : $mag) },
	     { setting=>$setting, index=>25, delta=>(($err109 > 0) ? -$mag : $mag) },
	    ]);
	   }
	  }
	 }
 if(ref($config) eq "HASH" && $config->{"post_commit_top_window_special_candidates"}) {
	 committed_top_window_add_candidate(\@out,\%seen,"top_pair_99r_down_105g_up",[
  { setting=>"whiteBalanceRed", index=>23, delta=>-0.25 },
  { setting=>"whiteBalanceGreen", index=>24, delta=>0.25 },
 ]);
 committed_top_window_add_candidate(\@out,\%seen,"top_tail_105r_down_109r_up",[
  { setting=>"whiteBalanceRed", index=>24, delta=>-0.125 },
  { setting=>"whiteBalanceRed", index=>25, delta=>1.0 },
 ]);
 committed_top_window_add_candidate(\@out,\%seen,"top_tail_105r_down",[
  { setting=>"whiteBalanceRed", index=>24, delta=>-0.125 },
 ]);
 committed_top_window_add_candidate(\@out,\%seen,"top_99_red_restore",[
  { setting=>"whiteBalanceRed", index=>23, delta=>0.25 },
 ]);
 committed_top_window_add_candidate(\@out,\%seen,"top_opposed_small",[
  { setting=>"whiteBalanceRed", index=>23, delta=>0.125 },
  { setting=>"whiteBalanceGreen", index=>23, delta=>-0.125 },
  { setting=>"whiteBalanceBlue", index=>23, delta=>-0.125 },
  { setting=>"whiteBalanceRed", index=>24, delta=>-0.125 },
  { setting=>"whiteBalanceGreen", index=>24, delta=>0.125 },
  { setting=>"whiteBalanceBlue", index=>24, delta=>0.125 },
 ]);
 }
 return @out;
}

sub committed_top_window_apply_candidate {
 my ($arrays,$candidate)=@_;
 my $next=clone_arrays($arrays);
 return $next if(ref($next) ne "HASH" || ref($candidate) ne "HASH" || ref($candidate->{"changes"}) ne "ARRAY");
 foreach my $change (@{$candidate->{"changes"}}) {
  next if(ref($change) ne "HASH");
  my $setting=$change->{"setting"};
  my $idx=$change->{"index"};
  next if(!defined($setting) || !defined($idx) || ref($next->{$setting}) ne "ARRAY");
  my $current=defined($next->{$setting}[$idx]) ? ($next->{$setting}[$idx]+0) : 0;
  $next->{$setting}[$idx]=clamp_ddc_value($current+($change->{"delta"}||0));
 }
 return $next;
}

sub committed_top_window_read {
 my ($config,$state,$steps_by_ire,$white_y,$target_x,$target_y,$target_gamma,$signal_mode,$tag)=@_;
 my %points;
 my $window_white_y=(defined($white_y) && $white_y > 0) ? ($white_y+0) : $white_y;
 foreach my $ire (109,105,100,99,95) {
  my $step=$steps_by_ire->{$ire};
  next if(ref($step) ne "HASH");
  my $read_step=fixed_lg_autocal_step($config,clone_picture($step));
  $state->{"current_name"}="Committed top window";
  $state->{"phase"}="reading";
  $state->{"message"}="Reading committed top window $ire%".($tag ? " ($tag)" : "");
  $state->{"active_stimulus"}=$read_step->{"stimulus"}+0 if(defined($read_step->{"stimulus"}));
  write_state($state);
  my ($reading,$read_error)=read_step($config,$read_step,$state);
  return (undef,$read_error) if($read_error && $read_error ne "cancelled");
  return (undef,"cancelled") if($read_error && $read_error eq "cancelled");
  next if(ref($reading) ne "HASH");
  my $target_step_y=effective_target_luminance_for_autocal_reading($window_white_y,$read_step,$reading,$target_gamma,$signal_mode);
  annotate_reading_target($reading,$window_white_y,$target_step_y,$target_x,$target_y);
  my $de=autocal_delta_e_for_step($config,$reading,$read_step,$window_white_y,$target_x,$target_y,$target_step_y);
  my $lum_pct=luminance_error_percent($reading,$target_step_y);
  $state->{"readings"}=merge_reading($state->{"readings"},$reading);
  $state->{"current_delta_e"}=defined($de) ? $de : undef;
  $state->{"current_luminance"}=luminance($reading);
  set_state_target_step_luminance($state,$target_step_y);
  $points{$ire}={
	   reading => clone_picture($reading),
	   de => defined($de) ? ($de+0) : undef,
   luminance_error_pct => defined($lum_pct) ? ($lum_pct+0) : undef,
	   target_luminance => $target_step_y,
	  };
	  trace_109($read_step,"committed_top_window_read",{
	   tag=>$tag,
	   delta_e=>defined($de)?$de+0:undef,
   luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef,
   white_y=>defined($window_white_y)?$window_white_y+0:undef,
   target_luminance=>defined($target_step_y)?$target_step_y+0:undef,
	   reading=>trace_reading_summary($reading)
	  });
  write_state($state);
 }
 my $window={ points=>\%points };
 my $score=committed_top_window_score($window);
 foreach my $key (qw(score worst avg over)) {
  $window->{$key}=$score->{$key};
 }
 return ($window,undef);
}

sub remember_lg_autocal_26_window_best_known {
 my ($config,$state,$steps_by_ire,$window,$arrays,$reason)=@_;
 return if(ref($config) ne "HASH" || !$config->{"lg_autocal_26"});
 return if(ref($steps_by_ire) ne "HASH" || ref($window) ne "HASH" || ref($window->{"points"}) ne "HASH");
 foreach my $ire (keys %{$window->{"points"}}) {
  my $point=$window->{"points"}{$ire};
  next if(ref($point) ne "HASH" || ref($point->{"reading"}) ne "HASH");
  my $step=$steps_by_ire->{$ire};
  next if(ref($step) ne "HASH");
  my $target=ddc_target_for_step($step);
  remember_lg_autocal_26_best_known(
   $config,$state,$step,$point->{"reading"},$point->{"de"},$point->{"luminance_error_pct"},
   $point->{"target_luminance"},$arrays,$target,$reason||"top_window"
  );
 }
}

sub committed_top_window_polish {
 my ($config,$state,$picture,$arrays,$picture_mode,$steps,$white_y,$target_x,$target_y,$target_gamma,$signal_mode,$calibrated_slot_mask)=@_;
 return ($picture,$arrays,undef) if(ref($config) ne "HASH" || !$config->{"lg_autocal_26"});
 return ($picture,$arrays,undef) if(exists($config->{"post_commit_top_window"}) && !$config->{"post_commit_top_window"});
 return ($picture,$arrays,undef) if(ref($steps) ne "ARRAY" || ref($arrays) ne "HASH");
 my %steps_by_ire;
 foreach my $step (@{$steps}) {
  next if(ref($step) ne "HASH" || !defined($step->{"ire"}));
  my $ire=$step->{"ire"}+0;
  foreach my $wanted (95,99,100,105,109) {
   $steps_by_ire{$wanted}=$step if(abs($ire-$wanted) < 0.001);
  }
 }
 return ($picture,$arrays,undef) if(!defined($steps_by_ire{99}) || !defined($steps_by_ire{100}) || !defined($steps_by_ire{105}));
 my $anchor=ddc_target_for_step($steps_by_ire{99}) || ddc_target_for_step($steps_by_ire{105});
 return ($picture,$arrays,undef) if(ref($anchor) ne "HASH");
 park_black_for_settle($config,$state,"Settling before committed top-window verification",config_positive_int($config,"post_commit_top_window_settle_ms",12000,0,60000));
 my ($best_window,$read_error)=committed_top_window_read($config,$state,\%steps_by_ire,$white_y,$target_x,$target_y,$target_gamma,$signal_mode,"base");
 return ($picture,$arrays,$read_error) if($read_error && $read_error ne "cancelled");
 return ($picture,$arrays,undef) if($read_error && $read_error eq "cancelled");
 return ($picture,$arrays,undef) if(ref($best_window) ne "HASH");
 my $best_score=committed_top_window_score($best_window);
 remember_lg_autocal_26_window_best_known($config,$state,\%steps_by_ire,$best_window,$arrays,"committed_top_window_base");
	 trace_109($steps_by_ire{99},"committed_top_window_base",{
	  score=>$best_score->{"score"}+0,
	  worst=>$best_score->{"worst"}+0,
	  over=>$best_score->{"over"}+0
	 });
	 if(committed_top_window_score_passed($best_score)) {
	  $state->{"committed_top_window_passed"}=1;
	  $state->{"committed_top_window_no_material_gain"}=0;
	  $state->{"committed_top_window_worst"}=$best_score->{"worst"}+0;
	  write_state($state);
	  return ($picture,$arrays,undef);
	 }
	 my $best_arrays=clone_arrays($arrays);
	 my $current_calibrated_slot_mask=clone_calibrated_26pt_slot_mask($calibrated_slot_mask);
	 my $best_calibrated_slot_mask=clone_calibrated_26pt_slot_mask($current_calibrated_slot_mask);
	 my $limit=config_positive_int($config,"post_commit_top_window_candidates",7,0,40);
	 if($state->{"committed_top_window_no_material_gain"} && !(ref($config) eq "HASH" && exists($config->{"post_commit_top_window_candidates"}))) {
	  $limit=2 if($limit > 2);
	 }
	 my $round_limit=config_positive_int($config,"post_commit_top_window_rounds",3,1,5);
	 my $tested_total=0;
	 my $accepted_total=0;
	 $state->{"current_name"}="Committed top window";
	 $state->{"phase"}="writing";
	 $state->{"message"}="Starting fresh LG calibration mode for committed top-window writes";
	 write_state($state);
	 my $start_error=start_calibration_mode($picture_mode,$state,"Committed top-window calibration mode enabled");
	 return ($picture,$arrays,$start_error) if($start_error);
	 my $top_window_calibration_mode_active=1;
	 my $finish_top_window=sub {
	  my ($error)=@_;
	  if($top_window_calibration_mode_active) {
	   end_calibration_mode($picture_mode);
	   set_state_calibration_mode($state,0,"");
	   $top_window_calibration_mode_active=0;
	  }
	  return ($picture,$arrays,$error);
	 };
	 for(my $round=1;$round<=$round_limit;$round++) {
	  last if(cancelled() || $tested_total >= $limit);
	  my @candidates=committed_top_window_candidates($best_window,$config);
	  my $round_improved=0;
	  my $round_budget=$limit-$tested_total;
	  $round_budget=8 if($round_budget > 8);
	  my $tested_round=0;
	  foreach my $candidate (@candidates) {
	   last if(cancelled());
	   last if($tested_total >= $limit || $tested_round++ >= $round_budget);
	   $tested_total++;
	   my $candidate_arrays=committed_top_window_apply_candidate($best_arrays,$candidate);
	   my $candidate_calibrated_slot_mask=clone_calibrated_26pt_slot_mask($best_calibrated_slot_mask);
	   mark_calibrated_26pt_candidate_slots($candidate_calibrated_slot_mask,$candidate);
	   refresh_propagated_uncalibrated_26pt_slots($config,$candidate_arrays,$candidate_calibrated_slot_mask);
	   $state->{"current_name"}="Committed top window";
	   $state->{"phase"}="writing";
	   $state->{"message"}="Testing top-window ".($candidate->{"label"}||"candidate")." ($tested_total/$limit)";
	   write_state($state);
	   my $write_error;
   ($picture,$write_error)=set_picture_values($picture,$candidate_arrays,$anchor,$picture_mode,1,$state,1,1);
	   return $finish_top_window->($write_error) if($write_error);
	   sync_state_picture($state,$picture,$picture_mode);
	   select(undef,undef,undef,0.6);
	   my ($candidate_window,$candidate_error)=committed_top_window_read($config,$state,\%steps_by_ire,$white_y,$target_x,$target_y,$target_gamma,$signal_mode,$candidate->{"label"}||"candidate");
	   return $finish_top_window->($candidate_error) if($candidate_error && $candidate_error ne "cancelled");
	   last if($candidate_error && $candidate_error eq "cancelled");
	   my $candidate_score=committed_top_window_score($candidate_window);
	   my $protected_worsened=committed_top_window_protected_worsened($candidate_window,$best_window);
	   trace_109($steps_by_ire{99},"committed_top_window_candidate",{
	    label=>$candidate->{"label"},
	    round=>$round+0,
	    score=>$candidate_score->{"score"}+0,
	    worst=>$candidate_score->{"worst"}+0,
	    over=>$candidate_score->{"over"}+0,
	    best_score=>$best_score->{"score"}+0,
	    best_worst=>$best_score->{"worst"}+0,
	    best_over=>$best_score->{"over"}+0,
	    protected_worsened=>$protected_worsened?1:0
	   });
	   if(!$protected_worsened && committed_top_window_candidate_allowed($candidate_score,$best_score)) {
	    $best_score=$candidate_score;
	    $best_window=$candidate_window;
	    $best_arrays=clone_arrays($candidate_arrays);
	    $arrays=clone_arrays($candidate_arrays);
	    $best_calibrated_slot_mask=clone_calibrated_26pt_slot_mask($candidate_calibrated_slot_mask);
	    $current_calibrated_slot_mask=clone_calibrated_26pt_slot_mask($candidate_calibrated_slot_mask);
	    promote_calibrated_26pt_slot_mask($calibrated_slot_mask,$current_calibrated_slot_mask);
	    remember_lg_autocal_26_window_best_known($config,$state,\%steps_by_ire,$candidate_window,$candidate_arrays,"committed_top_window_candidate_accepted");
	    $round_improved=1;
	    $accepted_total++;
	    trace_109($steps_by_ire{99},"committed_top_window_candidate_accepted",{
	     label=>$candidate->{"label"},
	     round=>$round+0,
	     accepted_total=>$accepted_total+0,
	     score=>$best_score->{"score"}+0,
	     worst=>$best_score->{"worst"}+0,
	     over=>$best_score->{"over"}+0
	    });
	    last if(committed_top_window_score_passed($best_score));
	   } else {
	    trace_109($steps_by_ire{99},"committed_top_window_candidate_rejected",{
	     label=>$candidate->{"label"},
	     round=>$round+0,
	     score=>$candidate_score->{"score"}+0,
	     worst=>$candidate_score->{"worst"}+0,
	     over=>$candidate_score->{"over"}+0,
	     best_score=>$best_score->{"score"}+0,
	     best_worst=>$best_score->{"worst"}+0,
	     best_over=>$best_score->{"over"}+0,
	     protected_worsened=>$protected_worsened?1:0
	    });
	    $state->{"phase"}="writing";
	    $state->{"message"}="Restoring top-window best";
	    write_state($state);
	    my $restore_error;
	    $current_calibrated_slot_mask=clone_calibrated_26pt_slot_mask($best_calibrated_slot_mask);
	    refresh_propagated_uncalibrated_26pt_slots($config,$best_arrays,$current_calibrated_slot_mask);
	    promote_calibrated_26pt_slot_mask($calibrated_slot_mask,$current_calibrated_slot_mask);
    ($picture,$restore_error)=set_picture_values($picture,$best_arrays,$anchor,$picture_mode,1,$state,1,1);
	    return $finish_top_window->($restore_error) if($restore_error);
	    sync_state_picture($state,$picture,$picture_mode);
	    trace_109($steps_by_ire{99},"committed_top_window_restored",{
	     label=>$candidate->{"label"},
	     round=>$round+0,
	     score=>$best_score->{"score"}+0,
	     worst=>$best_score->{"worst"}+0,
	     over=>$best_score->{"over"}+0
	    });
	   }
	  }
	  last if(committed_top_window_score_passed($best_score));
	  last if(!$round_improved);
	 }
	 if(ref($best_arrays) eq "HASH") {
	  $arrays=clone_arrays($best_arrays);
	  $current_calibrated_slot_mask=clone_calibrated_26pt_slot_mask($best_calibrated_slot_mask);
	  refresh_propagated_uncalibrated_26pt_slots($config,$arrays,$current_calibrated_slot_mask);
	  promote_calibrated_26pt_slot_mask($calibrated_slot_mask,$current_calibrated_slot_mask);
	  my $restore_error;
	  ($picture,$restore_error)=set_picture_values($picture,$arrays,$anchor,$picture_mode,1,$state,1,1);
	  return $finish_top_window->($restore_error) if($restore_error);
	  sync_state_picture($state,$picture,$picture_mode);
	  if($top_window_calibration_mode_active) {
	   end_calibration_mode($picture_mode);
	   set_state_calibration_mode($state,0,"");
	   $top_window_calibration_mode_active=0;
	  }
	  park_black_for_settle($config,$state,"Settling after committed top-window restore",config_positive_int($config,"post_commit_top_window_final_settle_ms",6000,0,60000));
	  my ($final_window,$final_error)=committed_top_window_read($config,$state,\%steps_by_ire,$white_y,$target_x,$target_y,$target_gamma,$signal_mode,"post_cal_final");
	  return $finish_top_window->($final_error) if($final_error && $final_error ne "cancelled");
	   if(ref($final_window) eq "HASH") {
	    my $final_score=committed_top_window_score($final_window);
	    remember_lg_autocal_26_window_best_known($config,$state,\%steps_by_ire,$final_window,$arrays,"committed_top_window_post_cal_final");
	    if(!committed_top_window_candidate_allowed($final_score,$best_score) && ($final_score->{"score"}||9999) > (($best_score->{"score"}||9999)+0.03)) {
	     trace_109($steps_by_ire{99},"committed_top_window_post_cal_drift",{
	     final_score=>$final_score->{"score"}+0,
	     final_worst=>$final_score->{"worst"}+0,
	     final_over=>$final_score->{"over"}+0,
	     best_score=>$best_score->{"score"}+0,
	     best_worst=>$best_score->{"worst"}+0,
	     best_over=>$best_score->{"over"}+0,
	     accepted_total=>$accepted_total+0
	    });
	   }
	   $best_window=$final_window;
	   $best_score=$final_score;
	  }
	 }
	 ($picture,$arrays,undef)=$finish_top_window->(undef);
 if(ref($best_window) eq "HASH" && ref($best_window->{"points"}) eq "HASH") {
  foreach my $ire (keys %{$best_window->{"points"}}) {
   my $reading=$best_window->{"points"}{$ire}{"reading"};
   $state->{"readings"}=merge_reading($state->{"readings"},$reading) if(ref($reading) eq "HASH");
  }
  $state->{"current_delta_e"}=$best_score->{"worst"};
  $state->{"committed_top_window_passed"}=committed_top_window_score_passed($best_score) ? 1 : 0;
  $state->{"committed_top_window_no_material_gain"}=(!$state->{"committed_top_window_passed"} && !$accepted_total) ? 1 : 0;
  $state->{"committed_top_window_worst"}=$best_score->{"worst"}+0;
  $state->{"message"}="Committed top window best kept (worst ".sprintf("%.2f",$best_score->{"worst"}).")";
  write_state($state);
 }
 return ($picture,$arrays,undef);
}

sub start_calibration_mode {
 my ($picture_mode,$state,$message)=@_;
 $message||="LG calibration mode enabled.";
 my $result=api_json("POST","/api/lg/calibration-mode",{
  enabled => JSON::PP::true,
  picture_mode => $picture_mode||"",
 },90);
 if(ref($result) eq "HASH" && ($result->{"status"}||"") eq "ok") {
  set_state_calibration_mode($state,1,$result->{"calibration_picture_mode"}||$result->{"active_picture_mode"}||$picture_mode||"");
  log_line("CAL_START: ".($result->{"message"}||$message));
  return undef;
 }
 my $error=(ref($result) eq "HASH") ? ($result->{"message"}||"LG TV rejected calibration mode start.") : "LG TV rejected calibration mode start.";
 log_line("CAL_START failed: $error");
 return $error;
}

sub committed_body_verify_step {
 my ($step)=@_;
 return 0 if(ref($step) ne "HASH" || !defined($step->{"ire"}));
 return 0 if(autocal_step_is_low_shadow($step) || autocal_step_is_fast_headroom($step) || autocal_step_is_white($step));
 my $ire=$step->{"ire"}+0;
 return ($ire >= 24.999 && $ire <= 75.0001) ? 1 : 0;
}

sub committed_body_verify_luminance_adjustment {
 my ($arrays,$target,$step,$de,$lum_pct,$target_delta)=@_;
 return undef if(!committed_body_verify_step($step));
 return undef if(!has_luminance_channel($arrays,$target));
 return undef if(!defined($lum_pct));
 my $abs=abs($lum_pct);
 my $threshold=0.80;
 $threshold=0.50 if(defined($de) && defined($target_delta) && $target_delta > 0 && $de > $target_delta);
 return undef if($abs < $threshold);
 my $idx=$target->{"index"};
 return undef if(!defined($idx) || ref($arrays->{"adjustingLuminance"}) ne "ARRAY");
 my $current=$arrays->{"adjustingLuminance"}[$idx]||0;
 my $direction=($lum_pct > 0) ? -1 : 1;
 my $mag=0.25;
 $mag=0.50 if($abs >= 1.0);
 $mag=0.75 if($abs >= 2.0);
 $mag=1.00 if($abs >= 3.0);
 my $cap=body_luminance_response_cap($step);
 $cap=1.0 if(!defined($cap) || $cap > 1.0);
 $mag=$cap if($mag > $cap);
 my $next=round_ddc_quarter($current+($direction*$mag));
 return undef if(abs($next-$current) < 0.0001);
 return [{ channel=>"lum", setting=>"adjustingLuminance", current=>$current, next=>$next, delta=>$next-$current, committed_body_verify=>1 }];
}

sub committed_body_verify_candidate_kept {
 my ($de,$lum_pct,$best_de,$best_lum_pct,$step)=@_;
 return 0 if(!defined($de));
 return 1 if(!defined($best_de));
 my $best_lum_abs=defined($best_lum_pct) ? abs($best_lum_pct) : undef;
 my $lum_abs=defined($lum_pct) ? abs($lum_pct) : undef;
 return 1 if(($de+0) < ($best_de+0)-0.0001 && (!defined($best_lum_abs) || !defined($lum_abs) || $lum_abs <= $best_lum_abs+0.05));
 return 1 if(($de+0) <= ($best_de+0)+0.0001 && defined($best_lum_abs) && defined($lum_abs) && $lum_abs+0.05 < $best_lum_abs);
 return 0;
}

sub committed_body_verify_off_cal {
 my ($config,$state,$picture,$arrays,$picture_mode,$steps,$white_y,$target_x,$target_y,$target_gamma,$signal_mode,$target_delta,$calibrated_slot_mask)=@_;
 return ($picture,$arrays,undef) if(ref($config) ne "HASH" || !$config->{"lg_autocal_26"});
 return ($picture,$arrays,undef) if(ref($steps) ne "ARRAY" || ref($arrays) ne "HASH");
 return ($picture,$arrays,undef) if(exists($config->{"post_commit_body_verify"}) && !$config->{"post_commit_body_verify"});
 return ($picture,$arrays,undef) if(!defined($white_y) || $white_y <= 0);
 my @body=sort { ($b->{"ire"}||0) <=> ($a->{"ire"}||0) } grep {
  ref($_) eq "HASH" &&
  committed_body_verify_step($_) &&
  ddc_target_for_step($_)
	 } @{$steps};
	 return ($picture,$arrays,undef) if(!@body);
	 my $current_calibrated_slot_mask=clone_calibrated_26pt_slot_mask($calibrated_slot_mask);
	 my $body_total=scalar(@body);
	 my ($body_index,$body_touches,$body_kept,$body_restored)=(0,0,0,0);
	 $state->{"current_name"}="Committed body verify";
	 $state->{"phase"}="reading";
	 $state->{"message"}="Starting committed body verify with calibration mode off";
	 $state->{"committed_body_verify"}={ status=>"running", total=>$body_total+0, current_index=>0, touches=>0, kept=>0, restored=>0 };
	 set_state_calibration_mode($state,0,"");
	 write_state($state);
	 foreach my $step (@body) {
  last if(cancelled());
  my $target=ddc_target_for_step($step);
  next if(ref($target) ne "HASH" || !has_luminance_channel($arrays,$target));
	  my $read_step=fixed_lg_autocal_step($config,$step);
	  next if(!committed_body_verify_step($read_step));
	  my $label=$target->{"label"};
	  $body_index++;
	  $state->{"committed_body_verify"}={ status=>"running", total=>$body_total+0, current_index=>$body_index+0, current=>$label, touches=>$body_touches+0, kept=>$body_kept+0, restored=>$body_restored+0 };
	  $state->{"current_name"}="Committed body verify $label";
	  $state->{"phase"}="reading";
	  $state->{"message"}="Reading committed body $label with calibration mode off";
  $state->{"active_stimulus"}=$read_step->{"stimulus"}+0 if(defined($read_step->{"stimulus"}));
  write_state($state);
  my ($reading,$read_error)=read_step($config,$read_step,$state);
  return ($picture,$arrays,$read_error) if($read_error && $read_error ne "cancelled");
  last if($read_error && $read_error eq "cancelled");
  next if(ref($reading) ne "HASH");
  my $target_step_y=effective_target_luminance_for_autocal_reading($white_y,$read_step,$reading,$target_gamma,$signal_mode);
  annotate_reading_target($reading,$white_y,$target_step_y,$target_x,$target_y);
  my $de=autocal_delta_e_for_step($config,$reading,$read_step,$white_y,$target_x,$target_y,$target_step_y);
  my $lum_pct=luminance_error_percent($reading,$target_step_y);
  $state->{"readings"}=merge_reading($state->{"readings"},$reading);
  $state->{"current_delta_e"}=defined($de) ? $de : undef;
  $state->{"current_luminance"}=luminance($reading);
  set_state_target_step_luminance($state,$target_step_y);
  $state->{"luminance_error_pct"}=defined($lum_pct) ? $lum_pct : undef;
  trace_109($read_step,"committed_body_verify_off_cal_read",{
   label=>$label,
   calibration_mode_active=>JSON::PP::false,
   delta_e=>defined($de)?$de+0:undef,
   luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef,
   target_luminance=>defined($target_step_y)?$target_step_y+0:undef,
   values=>trace_target_values($arrays,$target),
   reading=>trace_reading_summary($reading)
	  });
	  remember_lg_autocal_26_best_known($config,$state,$read_step,$reading,$de,$lum_pct,$target_step_y,$arrays,$target,"committed_body_verify_read");
	  write_state($state);
	  my %verify_tried;
	  mark_tried_values(\%verify_tried,$arrays,$target,$de);
	  my $body_cap=body_luminance_response_cap($read_step);
	  $body_cap=1.0 if(!defined($body_cap) || $body_cap > 1.0);
	  my $adjustments=lg_autocal_26_learned_luminance_adjustment($state,$arrays,$target,$read_step,$lum_pct,\%verify_tried,$body_cap,"committed_body_verify_luminance");
	  $adjustments=committed_body_verify_luminance_adjustment($arrays,$target,$read_step,$de,$lum_pct,$target_delta) if(!$adjustments);
	  next if(ref($adjustments) ne "ARRAY" || @{$adjustments} != 1);
  my $best_arrays=clone_arrays($arrays);
  my $best_calibrated_slot_mask=clone_calibrated_26pt_slot_mask($current_calibrated_slot_mask);
  my $best_reading=clone_picture($reading);
  my $best_de=$de;
  my $best_lum_pct=$lum_pct;
  my $candidate_arrays=clone_arrays($arrays);
  foreach my $adj (@{$adjustments}) {
   next if(ref($adj) ne "HASH");
   $candidate_arrays->{$adj->{"setting"}}[$target->{"index"}]=$adj->{"next"};
  }
  my $candidate_calibrated_slot_mask=clone_calibrated_26pt_slot_mask($best_calibrated_slot_mask);
  mark_calibrated_26pt_slot($candidate_calibrated_slot_mask,$target);
  refresh_propagated_uncalibrated_26pt_slots($config,$candidate_arrays,$candidate_calibrated_slot_mask);
  $state->{"phase"}="writing";
  $state->{"message"}="Committed body verify $label ".describe_adjustments($adjustments)." with calibration mode off";
  trace_109($read_step,"committed_body_verify_off_cal_adjustment",{
   label=>$label,
   calibration_mode_active=>JSON::PP::false,
   delta_e=>defined($de)?$de+0:undef,
   luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef,
   adjustments=>trace_adjustments_summary($adjustments),
   values_after=>trace_target_values($candidate_arrays,$target)
  });
	  write_state($state);
	  my $write_error;
	  $body_touches++;
	  $state->{"committed_body_verify"}={ status=>"running", total=>$body_total+0, current_index=>$body_index+0, current=>$label, touches=>$body_touches+0, kept=>$body_kept+0, restored=>$body_restored+0 };
	  ($picture,$write_error)=set_picture_values($picture,$candidate_arrays,$target,$picture_mode,0,$state,0,1);
	  return ($picture,$arrays,$write_error) if($write_error);
  set_state_calibration_mode($state,0,"");
  sync_state_picture($state,$picture,$picture_mode);
  my $read_settle_ms=config_positive_int($config,"post_commit_body_verify_read_settle_ms",2000,0,20000);
  select(undef,undef,undef,$read_settle_ms/1000) if($read_settle_ms > 0);
  $state->{"phase"}="reading";
  $state->{"message"}="Reading committed body $label after off-CAL verify adjustment";
  write_state($state);
  ($reading,$read_error)=read_step($config,$read_step,$state);
  return ($picture,$arrays,$read_error) if($read_error && $read_error ne "cancelled");
  last if($read_error && $read_error eq "cancelled");
  if(ref($reading) eq "HASH") {
   $target_step_y=effective_target_luminance_for_autocal_reading($white_y,$read_step,$reading,$target_gamma,$signal_mode);
   annotate_reading_target($reading,$white_y,$target_step_y,$target_x,$target_y);
   $de=autocal_delta_e_for_step($config,$reading,$read_step,$white_y,$target_x,$target_y,$target_step_y);
   $lum_pct=luminance_error_percent($reading,$target_step_y);
   $state->{"readings"}=merge_reading($state->{"readings"},$reading);
   $state->{"current_delta_e"}=defined($de) ? $de : undef;
   $state->{"current_luminance"}=luminance($reading);
   set_state_target_step_luminance($state,$target_step_y);
   $state->{"luminance_error_pct"}=defined($lum_pct) ? $lum_pct : undef;
   my $kept=committed_body_verify_candidate_kept($de,$lum_pct,$best_de,$best_lum_pct,$read_step);
   trace_109($read_step,"committed_body_verify_off_cal_measurement",{
    label=>$label,
    calibration_mode_active=>JSON::PP::false,
    kept=>$kept?1:0,
    delta_e=>defined($de)?$de+0:undef,
    luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef,
    best_delta_e=>defined($best_de)?$best_de+0:undef,
    best_luminance_error_pct=>defined($best_lum_pct)?$best_lum_pct+0:undef,
    values=>trace_target_values($candidate_arrays,$target),
    reading=>trace_reading_summary($reading)
	   });
	   if($kept) {
	   $body_kept++;
	   $state->{"committed_body_verify"}={ status=>"running", total=>$body_total+0, current_index=>$body_index+0, current=>$label, touches=>$body_touches+0, kept=>$body_kept+0, restored=>$body_restored+0 };
	   $arrays=clone_arrays($candidate_arrays);
	   $current_calibrated_slot_mask=clone_calibrated_26pt_slot_mask($candidate_calibrated_slot_mask);
	   promote_calibrated_26pt_slot_mask($calibrated_slot_mask,$current_calibrated_slot_mask);
   remember_lg_autocal_26_best_known($config,$state,$read_step,$reading,$de,$lum_pct,$target_step_y,$candidate_arrays,$target,"committed_body_verify_keep");
   write_state($state);
   next;
  }
  }
  $arrays=clone_arrays($best_arrays);
  $current_calibrated_slot_mask=clone_calibrated_26pt_slot_mask($best_calibrated_slot_mask);
	  $state->{"phase"}="writing";
	  $state->{"message"}="Restoring committed body $label verify best with calibration mode off";
	  write_state($state);
	  my $restore_error;
	  $body_restored++;
	  $state->{"committed_body_verify"}={ status=>"running", total=>$body_total+0, current_index=>$body_index+0, current=>$label, touches=>$body_touches+0, kept=>$body_kept+0, restored=>$body_restored+0 };
	  refresh_propagated_uncalibrated_26pt_slots($config,$arrays,$current_calibrated_slot_mask);
	  promote_calibrated_26pt_slot_mask($calibrated_slot_mask,$current_calibrated_slot_mask);
  ($picture,$restore_error)=set_picture_values($picture,$arrays,$target,$picture_mode,0,$state,0,1);
  return ($picture,$arrays,$restore_error) if($restore_error);
  set_state_calibration_mode($state,0,"");
  sync_state_picture($state,$picture,$picture_mode);
  $state->{"readings"}=merge_reading($state->{"readings"},$best_reading) if(ref($best_reading) eq "HASH");
  $state->{"current_delta_e"}=defined($best_de) ? $best_de : undef;
  $state->{"current_luminance"}=luminance($best_reading) if(ref($best_reading) eq "HASH");
  $state->{"luminance_error_pct"}=defined($best_lum_pct) ? $best_lum_pct : undef;
  trace_109($read_step,"committed_body_verify_off_cal_restored",{
   label=>$label,
   calibration_mode_active=>JSON::PP::false,
   best_delta_e=>defined($best_de)?$best_de+0:undef,
   best_luminance_error_pct=>defined($best_lum_pct)?$best_lum_pct+0:undef,
   values=>trace_target_values($arrays,$target)
  });
  remember_lg_autocal_26_best_known($config,$state,$read_step,$best_reading,$best_de,$best_lum_pct,$target_step_y,$arrays,$target,"committed_body_verify_restore");
  write_state($state);
	 }
	 promote_calibrated_26pt_slot_mask($calibrated_slot_mask,$current_calibrated_slot_mask);
	 $state->{"committed_body_verify"}={ status=>"complete", total=>$body_total+0, current_index=>$body_index+0, touches=>$body_touches+0, kept=>$body_kept+0, restored=>$body_restored+0 };
	 return ($picture,$arrays,undef);
	}

sub final_all_level_verify_order {
 return (109,105,100,99,95,90,85,80,75,70,65,60,55,50,45,40,35,30,25,20,15,10,7,5,4,3,2.3);
}

sub final_all_level_verify_steps_by_ire {
 my ($steps)=@_;
 my %wanted=map { format_percent($_)=>1 } final_all_level_verify_order();
 my %out;
 return \%out if(ref($steps) ne "ARRAY");
 foreach my $step (@{$steps}) {
  next if(ref($step) ne "HASH" || !defined($step->{"ire"}));
  my $key=format_percent($step->{"ire"});
  next if(!$wanted{$key});
  if(!defined($out{$key}) || ($step->{"autocal_white_reference"} && abs(($step->{"ire"}+0)-100) < 0.001)) {
   $out{$key}=$step;
  }
 }
 return \%out;
}

sub final_all_level_verify_de_limit {
 my ($target_delta)=@_;
 $target_delta=0.5 if(!defined($target_delta) || $target_delta <= 0);
 my $limit=$target_delta+0.15;
 $limit=0.75 if($limit < 0.75);
 return $limit;
}

sub final_all_level_verify_protected_step {
 my (@steps)=@_;
 foreach my $step (@steps) {
  next if(ref($step) ne "HASH");
  return 1 if($step->{"autocal_read_only"} || $step->{"autocal_white_reference"} || $step->{"autocal_reference_only"});
 }
 return 0;
}

sub final_all_level_verify_touchable_step {
 my ($step,$read_step,$target)=@_;
 return 0 if(ref($target) ne "HASH");
 return 0 if(final_all_level_verify_protected_step($step,$read_step));
 return 0 if(autocal_step_is_peak_headroom($read_step));
 return 1;
}

sub final_all_level_verify_outlier_reason {
 my ($step,$de,$lum_pct,$target_delta)=@_;
 return "missing_delta_e" if(!defined($de));
 return "" if(autocal_step_is_low_shadow($step) && committed_low_shadow_good_enough($step,$de,$lum_pct,$target_delta));
 my @reasons;
 my $de_limit=final_all_level_verify_de_limit($target_delta);
 push @reasons,"delta_e" if($de > $de_limit);
 if(defined($lum_pct)) {
  my $tol=luminance_tolerance_percent($step);
  push @reasons,"luminance" if(defined($tol) && abs($lum_pct) > $tol);
 }
 return join("+",@reasons);
}

sub final_all_level_verify_adjustment_cap {
 my ($step,$setting)=@_;
 my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : 50;
 my $is_luma=($setting||"") eq "adjustingLuminance" ? 1 : 0;
 if($ire <= 10.0001) {
  return $is_luma ? low_shadow_luminance_response_cap($step,undef) : (($ire <= 4.1001) ? 0.20 : 0.25);
 }
 return $is_luma ? 2.0 : 0.50 if($ire <= 30.0001);
 return $is_luma ? 1.5 : 0.35 if($ire <= 50.0001);
 return $is_luma ? 1.0 : 0.25 if($ire <= 85.0001);
 return $is_luma ? 0.5 : 0.25;
}

sub final_all_level_verify_luminance_adjustment {
 my ($arrays,$target,$step,$lum_pct)=@_;
 return undef if(ref($arrays) ne "HASH" || ref($target) ne "HASH" || !defined($lum_pct));
 return undef if(final_all_level_verify_protected_step($step));
 return undef if(!has_luminance_channel($arrays,$target));
 my $tol=luminance_tolerance_percent($step);
 return undef if(!defined($tol) || abs($lum_pct) <= $tol);
 my $idx=$target->{"index"};
 return undef if(!defined($idx) || ref($arrays->{"adjustingLuminance"}) ne "ARRAY");
 my $current=$arrays->{"adjustingLuminance"}[$idx]||0;
 my $direction=($lum_pct > 0) ? -1 : 1;
 my $abs=abs($lum_pct);
 my $mag=0.25;
 $mag=0.50 if($abs >= 2.0);
 $mag=1.00 if($abs >= 4.0);
 $mag=1.50 if($abs >= 8.0);
 $mag=2.00 if($abs >= 14.0);
 my $cap=final_all_level_verify_adjustment_cap($step,"adjustingLuminance");
 $mag=$cap if(defined($cap) && $mag > $cap);
 my $next=round_ddc_quarter($current+($direction*$mag));
 return undef if(abs($next-$current) < 0.0001);
 return [{ channel=>"lum", setting=>"adjustingLuminance", current=>$current, next=>$next, delta=>$next-$current, final_all_level_verify=>1 }];
}

sub final_all_level_verify_cap_adjustments {
 my ($adjustments,$step)=@_;
 return undef if(ref($adjustments) ne "ARRAY" || !@{$adjustments});
 my @out;
 foreach my $adj (@{$adjustments}) {
  next if(ref($adj) ne "HASH" || !defined($adj->{"setting"}));
  my $current=defined($adj->{"current"}) ? ($adj->{"current"}+0) : undef;
  my $next=defined($adj->{"next"}) ? ($adj->{"next"}+0) : undef;
  my $delta=defined($adj->{"delta"}) ? ($adj->{"delta"}+0) : undef;
  next if(!defined($next));
  if(!defined($current)) {
   $current=defined($delta) ? ($next-$delta) : 0;
  }
  $delta=$next-$current if(!defined($delta));
  my $cap=final_all_level_verify_adjustment_cap($step,$adj->{"setting"});
  if(defined($cap) && abs($delta) > $cap) {
   $delta=($delta < 0) ? -$cap : $cap;
   $next=clamp_ddc_value($current+$delta);
  }
  next if(abs($next-$current) < 0.0001);
  my %copy=%{$adj};
  $copy{"current"}=$current+0;
  $copy{"next"}=$next+0;
  $copy{"delta"}=$next-$current;
  $copy{"final_all_level_verify"}=1;
  push @out,\%copy;
 }
 return @out ? \@out : undef;
}

sub final_all_level_verify_adjustments {
		 my ($state,$arrays,$target,$step,$reading,$de,$lum_pct,$target_luminance,$target_delta,$tried,$stalls)=@_;
		 return undef if(final_all_level_verify_protected_step($step));
		 my $cap_lum=final_all_level_verify_adjustment_cap($step,"adjustingLuminance");
		 my $learned_lum=lg_autocal_26_learned_luminance_adjustment($state,$arrays,$target,$step,$lum_pct,$tried,$cap_lum,"final_all_level_verify_luminance");
		 return $learned_lum if($learned_lum);
	 my $lum=final_all_level_verify_luminance_adjustment($arrays,$target,$step,$lum_pct);
	 return $lum if($lum);
	 my $err=autocal_adjustment_error($reading,$step);
	 return undef if(ref($err) ne "HASH");
	 my $lum_err=luminance_error_ratio($reading,$target_luminance);
	 my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : 50;
	 my $max_step=($ire <= 30.0001) ? 0.50 : 0.25;
	 $max_step=0.25 if($ire >= 90);
	 my ($learned_ch)=furthest_rgb_error_channel($err);
	 my $learned_setting=$learned_ch ? channel_setting($learned_ch) : undef;
	 my $learned_rgb_cap=$learned_setting ? final_all_level_verify_adjustment_cap($step,$learned_setting) : undef;
	 my $learned_rgb=lg_autocal_26_learned_rgb_adjustment($state,$arrays,$target,$step,$reading,$de,$target_delta,$tried,$learned_rgb_cap,"final_all_level_verify_rgb");
	 return final_all_level_verify_cap_adjustments($learned_rgb,$step) if($learned_rgb);
	 my $adjustments=choose_micro_adjustments($err,$arrays,$target,$lum_err,$tried,$max_step,$de,$stalls,$step,$target_delta);
	 $adjustments=post_commit_low_shadow_adjustments($adjustments,$step,$lum_pct) if(autocal_step_is_low_shadow($step));
	 return final_all_level_verify_cap_adjustments($adjustments,$step);
	}

sub final_all_level_verify_step_read {
 my ($config,$state,$step,$white_y,$target_x,$target_y,$target_gamma,$signal_mode,$label,$event,$arrays,$target)=@_;
 my $read_step=fixed_lg_autocal_step($config,clone_picture($step));
 $state->{"current_name"}="Final all-level verify ".($label||($read_step->{"name"}||""));
 $state->{"phase"}="reading";
 $state->{"message"}="Reading final committed verify ".($label||($read_step->{"name"}||"patch"));
 $state->{"active_stimulus"}=$read_step->{"stimulus"}+0 if(defined($read_step->{"stimulus"}));
 write_state($state);
 my ($reading,$read_error)=read_step($config,$read_step,$state);
 return (undef,undef,undef,undef,$read_step,$read_error) if($read_error);
 return (undef,undef,undef,undef,$read_step,"Final committed verify read failed") if(ref($reading) ne "HASH");
 my $target_step_y=effective_target_luminance_for_autocal_reading($white_y,$read_step,$reading,$target_gamma,$signal_mode);
 annotate_reading_target($reading,$white_y,$target_step_y,$target_x,$target_y);
 my $de=autocal_delta_e_for_step($config,$reading,$read_step,$white_y,$target_x,$target_y,$target_step_y);
 my $lum_pct=luminance_error_percent($reading,$target_step_y);
 $state->{"readings"}=merge_reading($state->{"readings"},$reading);
 $state->{"current_delta_e"}=defined($de) ? $de : undef;
 $state->{"current_luminance"}=luminance($reading);
 set_state_target_step_luminance($state,$target_step_y);
 $state->{"luminance_error_pct"}=defined($lum_pct) ? $lum_pct : undef;
 trace_109($read_step,$event||"final_all_level_verify_read",{
  label=>$label,
  delta_e=>defined($de)?$de+0:undef,
  luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef,
  target_luminance=>defined($target_step_y)?$target_step_y+0:undef,
  white_y=>defined($white_y)?$white_y+0:undef,
  values=>trace_target_values($arrays,$target),
  reading=>trace_reading_summary($reading)
 });
 write_state($state);
 return ($reading,$de,$lum_pct,$target_step_y,$read_step,undef);
}

sub committed_final_all_level_verify {
 my ($config,$state,$picture,$arrays,$picture_mode,$steps,$white_y,$target_x,$target_y,$target_gamma,$signal_mode,$target_delta,$calibrated_slot_mask)=@_;
 return ($picture,$arrays,undef) if(ref($config) ne "HASH" || !$config->{"lg_autocal_26"});
 return ($picture,$arrays,undef) if(exists($config->{"post_commit_final_all_level_verify"}) && !$config->{"post_commit_final_all_level_verify"});
 return ($picture,$arrays,undef) if(ref($steps) ne "ARRAY" || ref($arrays) ne "HASH");
 return ($picture,$arrays,undef) if(!defined($white_y) || $white_y <= 0);
 my $steps_by_ire=final_all_level_verify_steps_by_ire($steps);
 my @ordered;
 foreach my $ire (final_all_level_verify_order()) {
  my $step=$steps_by_ire->{format_percent($ire)};
  push @ordered,$step if(ref($step) eq "HASH");
 }
 return ($picture,$arrays,undef) if(!@ordered);
 my $current_calibrated_slot_mask=clone_calibrated_26pt_slot_mask($calibrated_slot_mask);
 my $limit=config_positive_int($config,"post_commit_final_all_level_verify_outlier_iterations",1,0,3);
 my $read_settle_ms=config_positive_int($config,"post_commit_final_all_level_verify_read_settle_ms",2000,0,20000);
 my @outliers;
 my $read_count=0;
 my ($touch_count,$keep_count,$restore_count)=(0,0,0);
 my %current_pass_best_known;
 my $verify_total=scalar(@ordered);
 trace_109($ordered[0],"final_all_level_verify_start",{
  order=>[final_all_level_verify_order()],
  white_y=>$white_y+0,
  target_delta_e=>$target_delta+0,
  de_limit=>final_all_level_verify_de_limit($target_delta)+0
 });
 $state->{"current_name"}="Final all-level verify";
 $state->{"phase"}="reading";
 $state->{"message"}="Starting final top-down committed verify pass";
 $state->{"final_all_level_verify"}={ status=>"running", order=>[final_all_level_verify_order()], total=>$verify_total+0, reads=>0, outliers=>0, touches=>0, kept=>0, restored=>0 };
 set_state_calibration_mode($state,0,"");
 set_state_white_reference($state,$white_y);
 write_state($state);
 my $verify_index=0;
 foreach my $step (@ordered) {
  last if(cancelled());
  $verify_index++;
  my $target=ddc_target_for_step($step);
  my $label=(ref($target) eq "HASH" ? $target->{"label"} : ($step->{"name"}||format_percent($step->{"ire"})."%"));
  $state->{"final_all_level_verify"}={
   status=>"running",
   order=>[final_all_level_verify_order()],
   total=>$verify_total+0,
   current_index=>$verify_index+0,
   current=>$label,
   reads=>$read_count+0,
   outliers=>scalar(@outliers)+0,
   touches=>$touch_count+0,
   kept=>$keep_count+0,
   restored=>$restore_count+0,
  };
  my ($reading,$de,$lum_pct,$target_step_y,$read_step,$read_error)=final_all_level_verify_step_read(
   $config,$state,$step,$white_y,$target_x,$target_y,$target_gamma,$signal_mode,$label,"final_all_level_verify_read",$arrays,$target
  );
  return ($picture,$arrays,$read_error) if($read_error && $read_error ne "cancelled");
  last if($read_error && $read_error eq "cancelled");
  next if(ref($reading) ne "HASH" || ref($read_step) ne "HASH");
  $read_count++;
  my $current_best_key=lg_autocal_26_best_known_key($read_step);
  my $current_best_entry=lg_autocal_26_best_known_entry($read_step,$reading,$de,$lum_pct,$target_step_y,$arrays,$target,"final_all_level_verify_read");
  $current_pass_best_known{$current_best_key}=$current_best_entry if(defined($current_best_key) && ref($current_best_entry) eq "HASH");
  remember_lg_autocal_26_best_known($config,$state,$read_step,$reading,$de,$lum_pct,$target_step_y,$arrays,$target,"final_all_level_verify_read");
  my $reason=final_all_level_verify_outlier_reason($read_step,$de,$lum_pct,$target_delta);
  next if($reason eq "");
  my $touchable=final_all_level_verify_touchable_step($step,$read_step,$target) ? 1 : 0;
  push @outliers,{
   step=>$step,
   read_step=>$read_step,
   target=>$target,
   label=>$label,
   reading=>$reading,
   delta_e=>$de,
   luminance_error_pct=>$lum_pct,
   target_luminance=>$target_step_y,
   reason=>$touchable ? $reason : "read_only_".$reason,
  } if($touchable);
  trace_109($read_step,"final_all_level_verify_outlier",{
   label=>$label,
   reason=>$touchable ? $reason : "read_only_".$reason,
   touchable=>$touchable?JSON::PP::true:JSON::PP::false,
   delta_e=>defined($de)?$de+0:undef,
   luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef,
   target_luminance=>defined($target_step_y)?$target_step_y+0:undef,
   values=>trace_target_values($arrays,$target)
  });
 }
 foreach my $item (@outliers) {
  last if(cancelled());
  last if($limit <= 0);
  my $target=$item->{"target"};
  next if(ref($target) ne "HASH");
  my $read_step=$item->{"read_step"};
  my $label=$item->{"label"};
  next if(!final_all_level_verify_touchable_step($item->{"step"},$read_step,$target));
  my $reading=$item->{"reading"};
  my $de=$item->{"delta_e"};
  my $lum_pct=$item->{"luminance_error_pct"};
  my $target_step_y=$item->{"target_luminance"};
  my $best_arrays=clone_arrays($arrays);
  my $best_reading=clone_picture($reading);
  my $best_de=$de;
  my $best_lum_pct=$lum_pct;
  my $best_score=lg_autocal_26_measurement_score($read_step,$de,$lum_pct);
  my $stored_best_key=lg_autocal_26_best_known_key($read_step);
  my $stored_best=defined($stored_best_key) ? $current_pass_best_known{$stored_best_key} : undef;
  my $stored_best_score=(ref($stored_best) eq "HASH" && defined($stored_best->{"score"})) ? ($stored_best->{"score"}+0) : undef;
  my %tried_values;
  mark_tried_values(\%tried_values,$arrays,$target,$de);
  my $stalls=0;
  for(my $iter=1;$iter<=$limit;$iter++) {
   last if(cancelled());
   last if(final_all_level_verify_outlier_reason($read_step,$best_de,$best_lum_pct,$target_delta) eq "");
	   my $adjustments=final_all_level_verify_adjustments($state,$arrays,$target,$read_step,$reading,$de,$lum_pct,$target_step_y,$target_delta,\%tried_values,$stalls);
   last if(!$adjustments);
   my $values_before=trace_target_values($arrays,$target);
   my $candidate_arrays=clone_arrays($arrays);
   foreach my $adj (@{$adjustments}) {
    next if(ref($adj) ne "HASH" || !defined($adj->{"setting"}));
    $candidate_arrays->{$adj->{"setting"}}[$target->{"index"}]=$adj->{"next"};
   }
   my $candidate_calibrated_slot_mask=clone_calibrated_26pt_slot_mask($current_calibrated_slot_mask);
   mark_calibrated_26pt_slot($candidate_calibrated_slot_mask,$target);
   refresh_propagated_uncalibrated_26pt_slots($config,$candidate_arrays,$candidate_calibrated_slot_mask);
   $state->{"phase"}="writing";
   $state->{"message"}="Final verify $label ".describe_adjustments($adjustments)." ($iter/$limit)";
   trace_109($read_step,"final_all_level_verify_touch_keep",{
    label=>$label,
    planned=>JSON::PP::true,
    reason=>$item->{"reason"},
    iteration=>$iter+0,
    delta_e=>defined($de)?$de+0:undef,
    luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef,
    target_luminance=>defined($target_step_y)?$target_step_y+0:undef,
    adjustments=>trace_adjustments_summary($adjustments),
    values_before=>$values_before,
    values_after=>trace_target_values($candidate_arrays,$target)
   });
   write_state($state);
   my $write_error;
   $touch_count++;
   $state->{"final_all_level_verify"}={
    status=>"running",
    order=>[final_all_level_verify_order()],
    total=>$verify_total+0,
    current=>$label,
    reads=>$read_count+0,
    outliers=>scalar(@outliers)+0,
    touches=>$touch_count+0,
    kept=>$keep_count+0,
    restored=>$restore_count+0,
   };
   ($picture,$write_error)=set_picture_values($picture,$candidate_arrays,$target,$picture_mode,0,$state,0,1);
   return ($picture,$arrays,$write_error) if($write_error);
   set_state_calibration_mode($state,0,"");
   sync_state_picture($state,$picture,$picture_mode);
   select(undef,undef,undef,$read_settle_ms/1000) if($read_settle_ms > 0);
   my ($candidate_reading,$candidate_error)=read_step($config,$read_step,$state);
   return ($picture,$arrays,$candidate_error) if($candidate_error && $candidate_error ne "cancelled");
   last if($candidate_error && $candidate_error eq "cancelled");
   last if(ref($candidate_reading) ne "HASH");
   $target_step_y=effective_target_luminance_for_autocal_reading($white_y,$read_step,$candidate_reading,$target_gamma,$signal_mode);
   annotate_reading_target($candidate_reading,$white_y,$target_step_y,$target_x,$target_y);
   my $candidate_de=autocal_delta_e_for_step($config,$candidate_reading,$read_step,$white_y,$target_x,$target_y,$target_step_y);
   my $candidate_lum_pct=luminance_error_percent($candidate_reading,$target_step_y);
   mark_tried_values(\%tried_values,$candidate_arrays,$target,$candidate_de);
   my $candidate_score=lg_autocal_26_measurement_score($read_step,$candidate_de,$candidate_lum_pct);
   my $improved=defined($candidate_de) && $candidate_score + 0.0001 < $best_score;
   if($improved) {
    $arrays=clone_arrays($candidate_arrays);
    $current_calibrated_slot_mask=clone_calibrated_26pt_slot_mask($candidate_calibrated_slot_mask);
    promote_calibrated_26pt_slot_mask($calibrated_slot_mask,$current_calibrated_slot_mask);
    $best_arrays=clone_arrays($candidate_arrays);
    $best_reading=clone_picture($candidate_reading);
    $best_de=$candidate_de;
    $best_lum_pct=$candidate_lum_pct;
    $best_score=$candidate_score;
    $reading=$candidate_reading;
    $de=$candidate_de;
    $lum_pct=$candidate_lum_pct;
    $keep_count++;
    $state->{"final_all_level_verify"}={
     status=>"running",
     order=>[final_all_level_verify_order()],
     total=>$verify_total+0,
     current=>$label,
     reads=>$read_count+0,
     outliers=>scalar(@outliers)+0,
     touches=>$touch_count+0,
     kept=>$keep_count+0,
     restored=>$restore_count+0,
    };
    $state->{"readings"}=merge_reading($state->{"readings"},$candidate_reading);
    $state->{"current_delta_e"}=defined($candidate_de) ? $candidate_de : undef;
    $state->{"current_luminance"}=luminance($candidate_reading);
    set_state_target_step_luminance($state,$target_step_y);
    $state->{"luminance_error_pct"}=defined($candidate_lum_pct) ? $candidate_lum_pct : undef;
    my $current_best_entry=lg_autocal_26_best_known_entry($read_step,$candidate_reading,$candidate_de,$candidate_lum_pct,$target_step_y,$candidate_arrays,$target,"final_all_level_verify_touch_keep");
    if(defined($stored_best_key) && ref($current_best_entry) eq "HASH") {
     $current_pass_best_known{$stored_best_key}=$current_best_entry;
     $stored_best=$current_best_entry;
     $stored_best_score=(defined($current_best_entry->{"score"})) ? ($current_best_entry->{"score"}+0) : undef;
    }
    remember_lg_autocal_26_best_known($config,$state,$read_step,$candidate_reading,$candidate_de,$candidate_lum_pct,$target_step_y,$candidate_arrays,$target,"final_all_level_verify_touch_keep");
    trace_109($read_step,"final_all_level_verify_touch_keep",{
     label=>$label,
     planned=>JSON::PP::false,
     kept=>JSON::PP::true,
     reason=>$item->{"reason"},
     iteration=>$iter+0,
     delta_e=>defined($candidate_de)?$candidate_de+0:undef,
     luminance_error_pct=>defined($candidate_lum_pct)?$candidate_lum_pct+0:undef,
     target_luminance=>defined($target_step_y)?$target_step_y+0:undef,
     best_delta_e=>defined($best_de)?$best_de+0:undef,
     best_luminance_error_pct=>defined($best_lum_pct)?$best_lum_pct+0:undef,
     values_before=>$values_before,
     values_after=>trace_target_values($arrays,$target)
    });
    write_state($state);
    next;
   }
   my $stored_best_blocks=0;
   $stored_best_blocks=1 if(
    defined($stored_best_score)
    && $candidate_score > $stored_best_score+0.05
    && lg_autocal_26_best_known_values_available($stored_best,$target,$candidate_arrays)
   );
   my $restore_arrays=clone_arrays($best_arrays);
   my $restore_reason=$stored_best_blocks ? "stored_best_known_better" : "candidate_not_improved";
   if($stored_best_blocks) {
    my $stored_arrays=lg_autocal_26_arrays_with_best_known_values($candidate_arrays,$target,$stored_best);
    $restore_arrays=$stored_arrays if(ref($stored_arrays) eq "HASH");
   }
   refresh_propagated_uncalibrated_26pt_slots($config,$restore_arrays,$current_calibrated_slot_mask);
   $state->{"phase"}="writing";
   $state->{"message"}="Restoring final verify $label best";
   write_state($state);
   my $restore_error;
   ($picture,$restore_error)=set_picture_values($picture,$restore_arrays,$target,$picture_mode,0,$state,0,1);
   return ($picture,$arrays,$restore_error) if($restore_error);
   set_state_calibration_mode($state,0,"");
   sync_state_picture($state,$picture,$picture_mode);
   $arrays=clone_arrays($restore_arrays);
   $restore_count++;
   $state->{"final_all_level_verify"}={
    status=>"running",
    order=>[final_all_level_verify_order()],
    total=>$verify_total+0,
    current=>$label,
    reads=>$read_count+0,
    outliers=>scalar(@outliers)+0,
    touches=>$touch_count+0,
    kept=>$keep_count+0,
    restored=>$restore_count+0,
   };
   $stalls++;
   trace_109($read_step,"final_all_level_verify_touch_restore",{
    label=>$label,
    reason=>$restore_reason,
    iteration=>$iter+0,
    candidate_delta_e=>defined($candidate_de)?$candidate_de+0:undef,
    candidate_luminance_error_pct=>defined($candidate_lum_pct)?$candidate_lum_pct+0:undef,
    best_delta_e=>defined($best_de)?$best_de+0:undef,
    best_luminance_error_pct=>defined($best_lum_pct)?$best_lum_pct+0:undef,
    stored_best_delta_e=>(ref($stored_best) eq "HASH" && defined($stored_best->{"delta_e"})) ? ($stored_best->{"delta_e"}+0) : undef,
    stored_best_luminance_error_pct=>(ref($stored_best) eq "HASH" && defined($stored_best->{"luminance_error_pct"})) ? ($stored_best->{"luminance_error_pct"}+0) : undef,
    target_luminance=>defined($target_step_y)?$target_step_y+0:undef,
    values_before=>$values_before,
    values_after=>trace_target_values($arrays,$target)
   });
   $reading=clone_picture($best_reading);
   $de=$best_de;
   $lum_pct=$best_lum_pct;
   $state->{"readings"}=merge_reading($state->{"readings"},$best_reading) if(ref($best_reading) eq "HASH");
   $state->{"current_delta_e"}=defined($best_de) ? $best_de : undef;
   $state->{"current_luminance"}=luminance($best_reading) if(ref($best_reading) eq "HASH");
   $state->{"luminance_error_pct"}=defined($best_lum_pct) ? $best_lum_pct : undef;
   write_state($state);
   last;
  }
 }
 promote_calibrated_26pt_slot_mask($calibrated_slot_mask,$current_calibrated_slot_mask);
 $state->{"final_all_level_verify"}={
  status=>"complete",
  total=>$verify_total+0,
  reads=>$read_count+0,
  outliers=>scalar(@outliers)+0,
  touches=>$touch_count+0,
  kept=>$keep_count+0,
  restored=>$restore_count+0,
  white_y=>$white_y+0,
 };
 trace_109($ordered[0],"final_all_level_verify_complete",{
  reads=>$read_count+0,
  outliers=>scalar(@outliers)+0,
  touches=>$touch_count+0,
  kept=>$keep_count+0,
  restored=>$restore_count+0,
  white_y=>$white_y+0
 });
 write_state($state);
 return ($picture,$arrays,undef);
}

sub committed_state_polish {
 my ($config,$state,$picture,$arrays,$picture_mode,$steps,$target_x,$target_y,$target_gamma,$signal_mode,$target_delta,$polish_steps,$calibrated_slot_mask)=@_;
 return ($picture,undef) if(!post_commit_polish_enabled($config));
 return ($picture,undef) if(ref($steps) ne "ARRAY" || ref($arrays) ne "HASH");
 my $current_calibrated_slot_mask=clone_calibrated_26pt_slot_mask($calibrated_slot_mask);
 my ($white_step)=grep { ref($_) eq "HASH" && $_->{"autocal_white_reference"} } @{$steps};
 park_black_for_settle($config,$state);
 my $white_y=committed_polish_reference_white_y($config,$state,$steps,$target_gamma,$signal_mode,undef);
 return ($picture,undef) if(!defined($white_y) || $white_y <= 0);
 set_state_white_reference($state,$white_y);
 $state->{"message"}="Committed polish using fixed headroom white reference";
 write_state($state);

		 my $candidate_steps=(ref($polish_steps) eq "ARRAY") ? $polish_steps : $steps;
			 my @polish_candidates=grep {
			  ref($_) eq "HASH" &&
			  defined($_->{"ire"}) &&
			  ($_->{"ire"}+0) > 0 &&
			  !$_->{"autocal_read_only"} &&
			  !$_->{"autocal_white_reference"} &&
			  !$_->{"autocal_reference_only"} &&
			  ddc_target_for_step($_)
			 } @{$candidate_steps};
	 my @headroom=sort { ($b->{"ire"}||0) <=> ($a->{"ire"}||0) } grep { ($_->{"ire"}+0) >= 105 } @polish_candidates;
	 my @legal_white=sort {
	  (($a->{"ire"}+0) == 99 ? 0 : 1) <=> (($b->{"ire"}+0) == 99 ? 0 : 1)
	 } grep { abs(($_->{"ire"}+0)-99) < 0.001 || abs(($_->{"ire"}+0)-100) < 0.001 } @polish_candidates;
	 my @shadow=sort { ($a->{"ire"}||0) <=> ($b->{"ire"}||0) } grep { ($_->{"ire"}+0) <= 10.0001 } @polish_candidates;
	 my @body=sort { ($b->{"ire"}||0) <=> ($a->{"ire"}||0) } grep { ($_->{"ire"}+0) > 10.0001 && ($_->{"ire"}+0) < 99 } @polish_candidates;
	 my $include_body=(ref($config) eq "HASH" && exists($config->{"post_commit_body_polish"}))
	  ? ($config->{"post_commit_body_polish"} ? 1 : 0)
	  : (autocal_config_is_touchup($config) ? 0 : 1);
	 my $include_shadow=!(ref($config) eq "HASH" && exists($config->{"post_commit_true_low_shadow"}) && !$config->{"post_commit_true_low_shadow"});
	 my @polish=$include_body ? (@headroom,@legal_white,@body) : (@headroom,@legal_white);
	 push @polish,@shadow if($include_shadow);
		 my $limit=defined($config->{"post_commit_polish_iterations"}) ? int($config->{"post_commit_polish_iterations"}) : 8;
		 $limit=1 if($limit < 1);
		 $limit=12 if($limit > 12);
	 my $polish_total=scalar(@polish);
	 my ($polish_index,$polish_touches,$polish_kept,$polish_restored)=(0,0,0,0);
	 $state->{"current_name"}="Committed polish";
	 $state->{"phase"}="writing";
	 $state->{"message"}="Starting fresh LG calibration mode for committed polish writes";
	 $state->{"committed_polish"}={ status=>"running", total=>$polish_total+0, current_index=>0, touches=>0, kept=>0, restored=>0 };
	 write_state($state);
 my $start_error=start_calibration_mode($picture_mode,$state,"Committed polish calibration mode enabled");
 return ($picture,$start_error) if($start_error);
 my $polish_calibration_mode_active=1;
 my $finish_polish=sub {
  my ($error)=@_;
  if($polish_calibration_mode_active) {
   end_calibration_mode($picture_mode);
   set_state_calibration_mode($state,0,"");
   $polish_calibration_mode_active=0;
  }
  return ($picture,$error);
	 };
	 my $low_shadow_polish_settled=0;
	 foreach my $step (@polish) {
	  last if(cancelled());
	  my $target=ddc_target_for_step($step);
	  next if(!$target);
		  my $read_step=fixed_lg_autocal_step($config,$step);
		  my $label=$target->{"label"};
		  $polish_index++;
		  $state->{"committed_polish"}={ status=>"running", total=>$polish_total+0, current_index=>$polish_index+0, current=>$label, touches=>$polish_touches+0, kept=>$polish_kept+0, restored=>$polish_restored+0 };
		  if(autocal_step_is_low_shadow($read_step) && !$low_shadow_polish_settled) {
		   my $settle_ms=config_positive_int($config,"post_commit_low_shadow_settle_ms",12000,0,60000);
	   park_black_for_settle($config,$state,"Settling panel before committed low-shadow polish",$settle_ms);
	   $low_shadow_polish_settled=1;
	  }
	  $state->{"current_name"}="Committed polish $label";
	  $state->{"phase"}="reading";
	  $state->{"message"}="Reading committed $label";
  $state->{"active_stimulus"}=$read_step->{"stimulus"}+0 if(defined($read_step->{"stimulus"}));
  write_state($state);
  my ($reading,$read_error)=read_step($config,$read_step,$state);
  return $finish_polish->($read_error) if($read_error && $read_error ne "cancelled");
  last if($read_error && $read_error eq "cancelled");
  next if(ref($reading) ne "HASH");
  my $target_step_y=effective_target_luminance_for_autocal_reading($white_y,$read_step,$reading,$target_gamma,$signal_mode);
  annotate_reading_target($reading,$white_y,$target_step_y,$target_x,$target_y);
  my $de=autocal_delta_e_for_step($config,$reading,$read_step,$white_y,$target_x,$target_y,$target_step_y);
  my $lum_pct=luminance_error_percent($reading,$target_step_y);
  $state->{"readings"}=merge_reading($state->{"readings"},$reading);
  $state->{"current_delta_e"}=defined($de) ? $de : undef;
  $state->{"current_luminance"}=luminance($reading);
  set_state_target_step_luminance($state,$target_step_y);
  $state->{"luminance_error_pct"}=defined($lum_pct) ? $lum_pct : undef;
  trace_109($read_step,"committed_polish_read",{
   label=>$label,
   delta_e=>defined($de)?$de+0:undef,
   luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef,
   values=>trace_target_values($arrays,$target),
   reading=>trace_reading_summary($reading)
  });
  remember_lg_autocal_26_best_known($config,$state,$read_step,$reading,$de,$lum_pct,$target_step_y,$arrays,$target,"committed_polish_read");
  write_state($state);
  my ($committed_pair_step,$committed_pair_reading,$committed_pair_de,$committed_pair_lum_pct,$committed_pair_target_step_y);
  if(defined($step->{"ire"}) && abs(($step->{"ire"}+0)-99) < 0.001 && ref($white_step) eq "HASH") {
   $committed_pair_step=fixed_lg_autocal_step($config,clone_picture($white_step));
  }
  my $read_committed_pair=sub {
   my ($reason)=@_;
   return undef if(ref($committed_pair_step) ne "HASH");
   $committed_pair_reading=undef;
   $committed_pair_de=undef;
   $committed_pair_lum_pct=undef;
   $committed_pair_target_step_y=undef;
   $state->{"paired_delta_e"}=undef;
   $state->{"paired_luminance_error_pct"}=undef;
   $state->{"paired_target_luminance"}=undef;
   $state->{"current_name"}="Committed polish $label";
   $state->{"phase"}="reading";
   $state->{"message"}=($reason||"Checking committed 100% legal white");
   $state->{"active_stimulus"}=$committed_pair_step->{"stimulus"}+0 if(defined($committed_pair_step->{"stimulus"}));
   write_state($state);
   my ($pair_reading,$pair_error)=read_step($config,clone_picture($committed_pair_step),$state);
   return $pair_error if($pair_error);
   return "Committed 100% legal white read failed" if(ref($pair_reading) ne "HASH");
   my $pair_target_y=effective_target_luminance_for_autocal_reading($white_y,$committed_pair_step,$pair_reading,$target_gamma,$signal_mode);
   annotate_reading_target($pair_reading,$white_y,$pair_target_y,$target_x,$target_y);
   $committed_pair_reading=$pair_reading;
   $committed_pair_target_step_y=$pair_target_y;
   $committed_pair_de=autocal_delta_e_for_step($config,$pair_reading,$committed_pair_step,$white_y,$target_x,$target_y,$pair_target_y);
   $committed_pair_lum_pct=luminance_error_percent($pair_reading,$pair_target_y);
   $state->{"readings"}=merge_reading($state->{"readings"},$pair_reading);
   $state->{"paired_delta_e"}=defined($committed_pair_de) ? $committed_pair_de : undef;
   $state->{"paired_luminance_error_pct"}=defined($committed_pair_lum_pct) ? $committed_pair_lum_pct : undef;
   $state->{"paired_target_luminance"}=defined($committed_pair_target_step_y) ? $committed_pair_target_step_y : undef;
   trace_109($committed_pair_step,"committed_polish_pair_read",{
    label=>$label,
    delta_e=>defined($committed_pair_de)?$committed_pair_de+0:undef,
    luminance_error_pct=>defined($committed_pair_lum_pct)?$committed_pair_lum_pct+0:undef,
    white_y=>defined($white_y)?$white_y+0:undef,
    target_luminance=>defined($committed_pair_target_step_y)?$committed_pair_target_step_y+0:undef,
    pair_score=>legal_white_pair_score($de,$lum_pct,$read_step,$reading,$committed_pair_de,$committed_pair_lum_pct,$committed_pair_step,$committed_pair_reading,undef)+0,
    reading=>trace_reading_summary($pair_reading)
   });
   write_state($state);
   return undef;
  };
  my $committed_pair_score_now=sub {
   return legal_white_pair_score($de,$lum_pct,$read_step,$reading,$committed_pair_de,$committed_pair_lum_pct,$committed_pair_step,$committed_pair_reading,undef)
    if(ref($committed_pair_step) eq "HASH" && ref($committed_pair_reading) eq "HASH");
   return autocal_result_score($de,$lum_pct,$read_step);
  };
  my $committed_pair_target_reached=sub {
   return legal_white_pair_target_reached($de,$lum_pct,$read_step,$reading,$committed_pair_de,$committed_pair_lum_pct,$committed_pair_step,$committed_pair_reading,$target_delta,undef)
    if(ref($committed_pair_step) eq "HASH" && ref($committed_pair_reading) eq "HASH");
   return target_reached($de,$lum_pct,$target_delta,$read_step);
  };
  my $pair_error=$read_committed_pair->("Checking committed 99% / 100% legal-white pair");
  return $finish_polish->($pair_error) if($pair_error && $pair_error ne "cancelled");
  last if($pair_error && $pair_error eq "cancelled");
	  if(autocal_step_is_low_shadow($read_step)) {
	   next if(committed_low_shadow_good_enough($read_step,$de,$lum_pct,$target_delta));
	  } else {
	   next if($committed_pair_target_reached->());
	   next if(low_shadow_good_enough($read_step,$de,$lum_pct,$target_delta));
	  }

  my $best_score=$committed_pair_score_now->();
  my $best_arrays=clone_arrays($arrays);
  my $best_calibrated_slot_mask=clone_calibrated_26pt_slot_mask($current_calibrated_slot_mask);
  my $best_reading=clone_picture($reading);
  my $best_de=$de;
  my $best_lum_pct=$lum_pct;
  my $best_pair_reading=clone_picture($committed_pair_reading) if(ref($committed_pair_reading) eq "HASH");
  my $best_pair_de=$committed_pair_de;
  my $best_pair_lum_pct=$committed_pair_lum_pct;
  my $best_pair_target_step_y=$committed_pair_target_step_y;
  my %tried_values;
	  mark_tried_values(\%tried_values,$arrays,$target,$de);
	  my $stalls=0;
	  my $step_limit=$limit;
	  $step_limit=config_positive_int($config,"post_commit_low_shadow_iterations",4,0,8) if(autocal_step_is_low_shadow($read_step));
	  my $initial_worst_de=max_defined_delta($de,$committed_pair_de);
	  my $far_min_limit=committed_polish_min_iteration_limit($read_step,$initial_worst_de,$target_delta);
	  $step_limit=$far_min_limit if($far_min_limit && $step_limit < $far_min_limit);
	  for(my $iter=1;$iter<=$step_limit;$iter++) {
	   last if(cancelled());
	   my $err=autocal_adjustment_error($reading,$read_step);
	   my $lum_err=luminance_error_ratio($reading,$target_step_y);
	   my $adjustments;
	   if(!strict_tried_for_step($read_step)) {
	    $adjustments=lg_autocal_26_learned_luminance_adjustment($state,$arrays,$target,$read_step,$lum_pct,\%tried_values,final_all_level_verify_adjustment_cap($read_step,"adjustingLuminance"),"committed_polish_luminance");
	    if(!$adjustments) {
	     my ($learned_ch)=furthest_rgb_error_channel($err);
	     my $learned_setting=$learned_ch ? channel_setting($learned_ch) : undef;
	     my $learned_rgb_cap=$learned_setting ? final_all_level_verify_adjustment_cap($read_step,$learned_setting) : undef;
	     $adjustments=lg_autocal_26_learned_rgb_adjustment($state,$arrays,$target,$read_step,$reading,$de,$target_delta,\%tried_values,$learned_rgb_cap,"committed_polish_rgb");
	    }
	   }
	   if(!$adjustments && !autocal_step_is_low_shadow($read_step) && !autocal_step_is_fast_headroom($read_step)) {
	    $adjustments=choose_micro_adjustments($err,$arrays,$target,$lum_err,\%tried_values,0.25,$best_de,$stalls,$read_step,$target_delta);
	   } else {
		    $adjustments=choose_adjustments($err,$arrays,$target,$de,0.25,$stalls,$lum_err,\%tried_values,$read_step) if(!$adjustments);
		    $adjustments=post_commit_low_shadow_adjustments($adjustments,$read_step,$lum_pct) if(autocal_step_is_low_shadow($read_step));
	   }
   last if(!$adjustments);
   foreach my $adj (@{$adjustments}) {
    $arrays->{$adj->{"setting"}}[$target->{"index"}]=$adj->{"next"};
	   }
	   my $candidate_calibrated_slot_mask=clone_calibrated_26pt_slot_mask($best_calibrated_slot_mask);
	   mark_calibrated_26pt_slot($candidate_calibrated_slot_mask,$target);
	   refresh_propagated_uncalibrated_26pt_slots($config,$arrays,$candidate_calibrated_slot_mask);
	   $state->{"phase"}="writing";
	   $state->{"message"}="Committed polish $label ".describe_adjustments($adjustments)." ($iter/$step_limit)";
	   trace_109($read_step,"committed_polish_adjustment",{
	    label=>$label,
	    iteration=>$iter+0,
	    delta_e=>defined($de)?$de+0:undef,
	    luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef,
	    adjustments=>trace_adjustments_summary($adjustments),
	    values_after=>trace_target_values($arrays,$target)
		   });
		   write_state($state);
	   my $write_error;
	   $polish_touches++;
	   $state->{"committed_polish"}={ status=>"running", total=>$polish_total+0, current_index=>$polish_index+0, current=>$label, touches=>$polish_touches+0, kept=>$polish_kept+0, restored=>$polish_restored+0 };
	   ($picture,$write_error)=set_picture_values($picture,$arrays,$target,$picture_mode,1,$state,1,1);
	   return $finish_polish->($write_error) if($write_error);
	   sync_state_picture($state,$picture,$picture_mode);
	   $state->{"phase"}="reading";
	   $state->{"message"}="Reading committed $label polish ($iter/$step_limit)";
   write_state($state);
   ($reading,$read_error)=read_step($config,$read_step,$state);
   return $finish_polish->($read_error) if($read_error && $read_error ne "cancelled");
   last if($read_error && $read_error eq "cancelled");
   last if(ref($reading) ne "HASH");
   $target_step_y=effective_target_luminance_for_autocal_reading($white_y,$read_step,$reading,$target_gamma,$signal_mode);
   annotate_reading_target($reading,$white_y,$target_step_y,$target_x,$target_y);
   $de=autocal_delta_e_for_step($config,$reading,$read_step,$white_y,$target_x,$target_y,$target_step_y);
   $lum_pct=luminance_error_percent($reading,$target_step_y);
   mark_tried_values(\%tried_values,$arrays,$target,$de);
   $state->{"readings"}=merge_reading($state->{"readings"},$reading);
   $state->{"current_delta_e"}=defined($de) ? $de : undef;
   $state->{"current_luminance"}=luminance($reading);
   set_state_target_step_luminance($state,$target_step_y);
   $state->{"luminance_error_pct"}=defined($lum_pct) ? $lum_pct : undef;
   my $pair_error=$read_committed_pair->("Checking committed 99% / 100% legal-white pair after polish");
   return $finish_polish->($pair_error) if($pair_error && $pair_error ne "cancelled");
   last if($pair_error && $pair_error eq "cancelled");
   my $score=$committed_pair_score_now->();
   trace_109($read_step,"committed_polish_measurement",{
    label=>$label,
    iteration=>$iter+0,
    delta_e=>defined($de)?$de+0:undef,
    luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef,
    score=>$score+0,
    best_delta_e=>defined($best_de)?$best_de+0:undef,
    best_luminance_error_pct=>defined($best_lum_pct)?$best_lum_pct+0:undef,
    best_score=>$best_score+0,
    paired_delta_e=>defined($committed_pair_de)?$committed_pair_de+0:undef,
    paired_luminance_error_pct=>defined($committed_pair_lum_pct)?$committed_pair_lum_pct+0:undef,
    values=>trace_target_values($arrays,$target),
    reading=>trace_reading_summary($reading)
   });
	   my $not_worse_measurement=autocal_measurement_not_worse_than_best($de,$lum_pct,$best_de,$best_lum_pct);
	   $not_worse_measurement=0 if(ref($best_pair_reading) eq "HASH" && !autocal_measurement_not_worse_than_best($committed_pair_de,$committed_pair_lum_pct,$best_pair_de,$best_pair_lum_pct));
		   my $best_update_reason;
		   my $keep_committed_candidate=0;
		   if(ref($committed_pair_step) eq "HASH") {
		    $best_update_reason=legal_white_pair_best_update_reason($score,$best_score,$de,$committed_pair_de,$best_de,$best_pair_de,$target_delta);
		    $keep_committed_candidate=defined($best_update_reason) ? 1 : 0;
		   } else {
		    $best_update_reason="score_improved" if($score + 0.0001 < $best_score);
		    $keep_committed_candidate=(defined($best_update_reason) && $not_worse_measurement) ? 1 : 0;
		   }
		   trace_109($read_step,"committed_polish_best_candidate",{
		    label=>$label,
		    iteration=>$iter+0,
		    keep=>$keep_committed_candidate?JSON::PP::true:JSON::PP::false,
		    reason=>defined($best_update_reason)?$best_update_reason:"",
		    not_worse_measurement=>$not_worse_measurement?JSON::PP::true:JSON::PP::false,
		    candidate_delta_e=>defined($de)?$de+0:undef,
		    paired_candidate_delta_e=>defined($committed_pair_de)?$committed_pair_de+0:undef,
		    best_delta_e=>defined($best_de)?$best_de+0:undef,
		    best_paired_delta_e=>defined($best_pair_de)?$best_pair_de+0:undef,
		    candidate_score=>$score+0,
		    best_score=>$best_score+0
		   });
		   if($keep_committed_candidate) {
	   $polish_kept++;
	   $state->{"committed_polish"}={ status=>"running", total=>$polish_total+0, current_index=>$polish_index+0, current=>$label, touches=>$polish_touches+0, kept=>$polish_kept+0, restored=>$polish_restored+0 };
	   $best_score=$score;
	    $best_arrays=clone_arrays($arrays);
    $best_calibrated_slot_mask=clone_calibrated_26pt_slot_mask($candidate_calibrated_slot_mask);
    $current_calibrated_slot_mask=clone_calibrated_26pt_slot_mask($candidate_calibrated_slot_mask);
    promote_calibrated_26pt_slot_mask($calibrated_slot_mask,$current_calibrated_slot_mask);
    $best_reading=clone_picture($reading);
    $best_de=$de;
    $best_lum_pct=$lum_pct;
    $best_pair_reading=clone_picture($committed_pair_reading) if(ref($committed_pair_reading) eq "HASH");
    $best_pair_de=$committed_pair_de;
    $best_pair_lum_pct=$committed_pair_lum_pct;
    $best_pair_target_step_y=$committed_pair_target_step_y;
    remember_lg_autocal_26_best_known($config,$state,$read_step,$reading,$de,$lum_pct,$target_step_y,$arrays,$target,"committed_polish_keep");
    $stalls=0;
	   } else {
	    $stalls++;
	    $polish_restored++;
	    $state->{"committed_polish"}={ status=>"running", total=>$polish_total+0, current_index=>$polish_index+0, current=>$label, touches=>$polish_touches+0, kept=>$polish_kept+0, restored=>$polish_restored+0 };
	    $arrays=clone_arrays($best_arrays);
	    $current_calibrated_slot_mask=clone_calibrated_26pt_slot_mask($best_calibrated_slot_mask);
    $state->{"phase"}="writing";
    $state->{"message"}="Restoring committed $label polish";
    write_state($state);
    refresh_propagated_uncalibrated_26pt_slots($config,$arrays,$current_calibrated_slot_mask);
    promote_calibrated_26pt_slot_mask($calibrated_slot_mask,$current_calibrated_slot_mask);
    ($picture,$write_error)=set_picture_values($picture,$arrays,$target,$picture_mode,1,$state,1,1);
    return $finish_polish->($write_error) if($write_error);
    sync_state_picture($state,$picture,$picture_mode);
	    $reading=clone_picture($best_reading);
	    $de=$best_de;
	    $lum_pct=$best_lum_pct;
	    $committed_pair_reading=clone_picture($best_pair_reading) if(ref($best_pair_reading) eq "HASH");
	    $committed_pair_de=$best_pair_de;
	    $committed_pair_lum_pct=$best_pair_lum_pct;
	    $committed_pair_target_step_y=$best_pair_target_step_y;
	    $state->{"readings"}=merge_reading($state->{"readings"},$best_reading) if(ref($best_reading) eq "HASH");
	    $state->{"current_delta_e"}=defined($best_de) ? $best_de : undef;
	    $state->{"current_luminance"}=luminance($best_reading) if(ref($best_reading) eq "HASH");
	    $state->{"luminance_error_pct"}=defined($best_lum_pct) ? $best_lum_pct : undef;
	    $state->{"paired_delta_e"}=defined($best_pair_de) ? $best_pair_de : undef;
	    $state->{"paired_luminance_error_pct"}=defined($best_pair_lum_pct) ? $best_pair_lum_pct : undef;
	    last if(committed_low_shadow_good_enough($read_step,$best_de,$best_lum_pct,$target_delta));
	    my $stall_de=max_defined_delta($best_de,$best_pair_de);
	    last if($stalls >= committed_polish_stall_limit($read_step,$stall_de,$target_delta));
	   }
	   write_state($state);
	   if(autocal_step_is_low_shadow($read_step)) {
	    last if(committed_low_shadow_good_enough($read_step,$de,$lum_pct,$target_delta));
	   } else {
	    last if($committed_pair_target_reached->());
	    last if(low_shadow_good_enough($read_step,$de,$lum_pct,$target_delta));
	   }
	  }
	 }
		 $finish_polish->(undef);
		 my $body_verify_error;
		 ($picture,$arrays,$body_verify_error)=committed_body_verify_off_cal(
		  $config,$state,$picture,$arrays,$picture_mode,\@body,$white_y,
		  $target_x,$target_y,$target_gamma,$signal_mode,$target_delta,$current_calibrated_slot_mask
		 );
		 return ($picture,$body_verify_error) if($body_verify_error && $body_verify_error ne "cancelled");
		 delete $state->{"committed_top_window_passed"};
		 delete $state->{"committed_top_window_worst"};
		 my $top_window_error;
		 ($picture,$arrays,$top_window_error)=committed_top_window_polish(
		  $config,$state,$picture,$arrays,$picture_mode,$steps,$white_y,
		  $target_x,$target_y,$target_gamma,$signal_mode,$current_calibrated_slot_mask
		 );
		 return ($picture,$top_window_error) if($top_window_error && $top_window_error ne "cancelled");
		 if(!(ref($config) eq "HASH" && exists($config->{"post_commit_true_low_shadow"}) && !$config->{"post_commit_true_low_shadow"})) {
	  my @committed_shadow=sort { ($a->{"ire"}||0) <=> ($b->{"ire"}||0) } grep {
	   ref($_) eq "HASH" &&
	   defined($_->{"ire"}) &&
	   ($_->{"ire"}+0) > 0 &&
	   ($_->{"ire"}+0) <= 10.0001 &&
	   ddc_target_for_step($_)
	  } @polish_candidates;
	  my $committed_limit=config_positive_int($config,"post_commit_low_shadow_committed_iterations",3,0,6);
	  foreach my $step (@committed_shadow) {
	   last if(cancelled());
	   last if($committed_limit <= 0);
	   my $target=ddc_target_for_step($step);
	   next if(!$target);
	   my $read_step=fixed_lg_autocal_step($config,$step);
	   my $label=$target->{"label"};
	   my $settle_ms=config_positive_int($config,"post_commit_low_shadow_settle_ms",12000,0,60000);
	   park_black_for_settle($config,$state,"Settling panel before committed $label verification",$settle_ms);
	   $state->{"current_name"}="Committed verify $label";
	   $state->{"phase"}="reading";
	   $state->{"message"}="Reading committed $label with calibration mode off";
	   $state->{"active_stimulus"}=$read_step->{"stimulus"}+0 if(defined($read_step->{"stimulus"}));
	   write_state($state);
	   my ($reading,$read_error)=read_step($config,$read_step,$state);
	   return ($picture,$read_error) if($read_error && $read_error ne "cancelled");
	   last if($read_error && $read_error eq "cancelled");
	   next if(ref($reading) ne "HASH");
	   my $target_step_y=effective_target_luminance_for_autocal_reading($white_y,$read_step,$reading,$target_gamma,$signal_mode);
	   annotate_reading_target($reading,$white_y,$target_step_y,$target_x,$target_y);
	   my $de=autocal_delta_e_for_step($config,$reading,$read_step,$white_y,$target_x,$target_y,$target_step_y);
	   my $lum_pct=luminance_error_percent($reading,$target_step_y);
	   $state->{"readings"}=merge_reading($state->{"readings"},$reading);
	   $state->{"current_delta_e"}=defined($de) ? $de : undef;
	   $state->{"current_luminance"}=luminance($reading);
	   set_state_target_step_luminance($state,$target_step_y);
	   $state->{"luminance_error_pct"}=defined($lum_pct) ? $lum_pct : undef;
	   trace_109($read_step,"committed_low_shadow_read",{
	    label=>$label,
	    delta_e=>defined($de)?$de+0:undef,
	    luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef,
	    values=>trace_target_values($arrays,$target)
	   });
	   remember_lg_autocal_26_best_known($config,$state,$read_step,$reading,$de,$lum_pct,$target_step_y,$arrays,$target,"committed_low_shadow_read");
	   write_state($state);
		   next if(committed_low_shadow_good_enough($read_step,$de,$lum_pct,$target_delta));
	   my $best_score=autocal_result_score($de,$lum_pct,$read_step);
	   my $best_arrays=clone_arrays($arrays);
	   my $best_calibrated_slot_mask=clone_calibrated_26pt_slot_mask($current_calibrated_slot_mask);
	   my $best_reading=clone_picture($reading);
	   my $best_de=$de;
	   my $best_lum_pct=$lum_pct;
	   my %tried_values;
	   mark_tried_values(\%tried_values,$arrays,$target,$de);
	   my $stalls=0;
	   my $far_min_limit=committed_polish_min_iteration_limit($read_step,$de,$target_delta);
	   my $step_committed_limit=$committed_limit;
	   $step_committed_limit=$far_min_limit if($far_min_limit && $step_committed_limit < $far_min_limit);
		  for(my $iter=1;$iter<=$step_committed_limit;$iter++) {
		    last if(cancelled());
		    my $err=autocal_adjustment_error($reading,$read_step);
		    my $lum_err=luminance_error_ratio($reading,$target_step_y);
			    my $adjustments=lg_autocal_26_learned_luminance_adjustment($state,$arrays,$target,$read_step,$lum_pct,\%tried_values,final_all_level_verify_adjustment_cap($read_step,"adjustingLuminance"),"committed_low_shadow_luminance");
			    if(!$adjustments) {
			     my ($learned_ch)=furthest_rgb_error_channel($err);
			     my $learned_setting=$learned_ch ? channel_setting($learned_ch) : undef;
			     my $learned_rgb_cap=$learned_setting ? final_all_level_verify_adjustment_cap($read_step,$learned_setting) : undef;
			     $adjustments=lg_autocal_26_learned_rgb_adjustment($state,$arrays,$target,$read_step,$reading,$de,$target_delta,\%tried_values,$learned_rgb_cap,"committed_low_shadow_rgb");
			    }
			    $adjustments=choose_adjustments($err,$arrays,$target,$de,0.25,$stalls,$lum_err,\%tried_values,$read_step) if(!$adjustments);
			    $adjustments=post_commit_low_shadow_adjustments($adjustments,$read_step,$lum_pct) if(autocal_step_is_low_shadow($read_step));
	    last if(!$adjustments);
	    foreach my $adj (@{$adjustments}) {
	     $arrays->{$adj->{"setting"}}[$target->{"index"}]=$adj->{"next"};
	    }
	    my $candidate_calibrated_slot_mask=clone_calibrated_26pt_slot_mask($best_calibrated_slot_mask);
	    mark_calibrated_26pt_slot($candidate_calibrated_slot_mask,$target);
	    refresh_propagated_uncalibrated_26pt_slots($config,$arrays,$candidate_calibrated_slot_mask);
	    $state->{"phase"}="writing";
	    $state->{"message"}="Committed verify $label ".describe_adjustments($adjustments)." ($iter/$step_committed_limit)";
	    trace_109($read_step,"committed_low_shadow_adjustment",{
	     label=>$label,
	     iteration=>$iter+0,
	     delta_e=>defined($de)?$de+0:undef,
	     luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef,
	     adjustments=>trace_adjustments_summary($adjustments),
	     values_after=>trace_target_values($arrays,$target)
	    });
	    write_state($state);
	    my $write_error;
	    ($picture,$write_error)=set_picture_values($picture,$arrays,$target,$picture_mode,0,$state,0,1);
	    return ($picture,$write_error) if($write_error);
	    set_state_calibration_mode($state,0,"");
	    sync_state_picture($state,$picture,$picture_mode);
	    my $read_settle_ms=config_positive_int($config,"post_commit_low_shadow_read_settle_ms",2500,0,20000);
	    select(undef,undef,undef,$read_settle_ms/1000) if($read_settle_ms > 0);
	    $state->{"phase"}="reading";
	    $state->{"message"}="Reading committed $label after verify adjustment ($iter/$committed_limit)";
	    write_state($state);
	    ($reading,$read_error)=read_step($config,$read_step,$state);
	    return ($picture,$read_error) if($read_error && $read_error ne "cancelled");
	    last if($read_error && $read_error eq "cancelled");
	    last if(ref($reading) ne "HASH");
	    $target_step_y=effective_target_luminance_for_autocal_reading($white_y,$read_step,$reading,$target_gamma,$signal_mode);
	    annotate_reading_target($reading,$white_y,$target_step_y,$target_x,$target_y);
	    $de=autocal_delta_e_for_step($config,$reading,$read_step,$white_y,$target_x,$target_y,$target_step_y);
	    $lum_pct=luminance_error_percent($reading,$target_step_y);
	    mark_tried_values(\%tried_values,$arrays,$target,$de);
	    $state->{"readings"}=merge_reading($state->{"readings"},$reading);
	    $state->{"current_delta_e"}=defined($de) ? $de : undef;
	    $state->{"current_luminance"}=luminance($reading);
	    set_state_target_step_luminance($state,$target_step_y);
	    $state->{"luminance_error_pct"}=defined($lum_pct) ? $lum_pct : undef;
	    my $score=autocal_result_score($de,$lum_pct,$read_step);
	    trace_109($read_step,"committed_low_shadow_measurement",{
	     label=>$label,
	     iteration=>$iter+0,
	     delta_e=>defined($de)?$de+0:undef,
	     luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef,
	     score=>$score+0,
	     best_delta_e=>defined($best_de)?$best_de+0:undef,
	     best_luminance_error_pct=>defined($best_lum_pct)?$best_lum_pct+0:undef,
	     best_score=>$best_score+0,
	     values=>trace_target_values($arrays,$target)
	    });
	    if(defined($de) && $score + 0.0001 < $best_score) {
	     $best_score=$score;
	     $best_arrays=clone_arrays($arrays);
	     $best_calibrated_slot_mask=clone_calibrated_26pt_slot_mask($candidate_calibrated_slot_mask);
	     $current_calibrated_slot_mask=clone_calibrated_26pt_slot_mask($candidate_calibrated_slot_mask);
	     promote_calibrated_26pt_slot_mask($calibrated_slot_mask,$current_calibrated_slot_mask);
	     $best_reading=clone_picture($reading);
	     $best_de=$de;
	     $best_lum_pct=$lum_pct;
	     remember_lg_autocal_26_best_known($config,$state,$read_step,$reading,$de,$lum_pct,$target_step_y,$arrays,$target,"committed_low_shadow_keep");
	     $stalls=0;
		    } else {
		     $stalls++;
		     $arrays=clone_arrays($best_arrays);
		     $current_calibrated_slot_mask=clone_calibrated_26pt_slot_mask($best_calibrated_slot_mask);
		     $state->{"phase"}="writing";
		     $state->{"message"}="Restoring committed $label verify best";
		     write_state($state);
		     my $restore_error;
		     refresh_propagated_uncalibrated_26pt_slots($config,$arrays,$current_calibrated_slot_mask);
		     promote_calibrated_26pt_slot_mask($calibrated_slot_mask,$current_calibrated_slot_mask);
		     ($picture,$restore_error)=set_picture_values($picture,$arrays,$target,$picture_mode,0,$state,0,1);
		     return ($picture,$restore_error) if($restore_error);
		     set_state_calibration_mode($state,0,"");
		     sync_state_picture($state,$picture,$picture_mode);
		     $reading=clone_picture($best_reading);
		     $de=$best_de;
		     $lum_pct=$best_lum_pct;
		     $state->{"readings"}=merge_reading($state->{"readings"},$best_reading) if(ref($best_reading) eq "HASH");
		     $state->{"current_delta_e"}=defined($best_de) ? $best_de : undef;
		     $state->{"current_luminance"}=luminance($best_reading) if(ref($best_reading) eq "HASH");
		     $state->{"luminance_error_pct"}=defined($best_lum_pct) ? $best_lum_pct : undef;
		     last if(committed_low_shadow_good_enough($read_step,$best_de,$best_lum_pct,$target_delta));
		     last if($stalls >= committed_polish_stall_limit($read_step,$best_de,$target_delta));
		    }
		    write_state($state);
		    last if(committed_low_shadow_good_enough($read_step,$de,$lum_pct,$target_delta));
		   }
	   if(ref($best_arrays) eq "HASH" && ref($best_reading) eq "HASH" && $best_score + 0.0001 < autocal_result_score($de,$lum_pct,$read_step)) {
	    $arrays=clone_arrays($best_arrays);
	    $current_calibrated_slot_mask=clone_calibrated_26pt_slot_mask($best_calibrated_slot_mask);
	    $state->{"phase"}="writing";
	    $state->{"message"}="Restoring committed $label verify best";
	    write_state($state);
	    my $restore_error;
	    refresh_propagated_uncalibrated_26pt_slots($config,$arrays,$current_calibrated_slot_mask);
	    promote_calibrated_26pt_slot_mask($calibrated_slot_mask,$current_calibrated_slot_mask);
	    ($picture,$restore_error)=set_picture_values($picture,$arrays,$target,$picture_mode,0,$state,0,1);
	    return ($picture,$restore_error) if($restore_error);
	    set_state_calibration_mode($state,0,"");
	    sync_state_picture($state,$picture,$picture_mode);
	    $reading=clone_picture($best_reading);
	    $de=$best_de;
	    $lum_pct=$best_lum_pct;
	   }
	   $state->{"readings"}=merge_reading($state->{"readings"},$reading) if(ref($reading) eq "HASH");
	   $state->{"current_delta_e"}=defined($de) ? $de : undef;
	   $state->{"current_luminance"}=luminance($reading);
	   $state->{"luminance_error_pct"}=defined($lum_pct) ? $lum_pct : undef;
	   write_state($state);
	  }
	 }
	 if(!(ref($config) eq "HASH" && exists($config->{"post_commit_final_top_window"}) && !$config->{"post_commit_final_top_window"})) {
	  if(!$state->{"committed_top_window_passed"}) {
	   park_black_for_settle($config,$state,"Settling post-polish committed state before final top-window verification");
	   my $final_top_window_error;
	   ($picture,$arrays,$final_top_window_error)=committed_top_window_polish(
	    $config,$state,$picture,$arrays,$picture_mode,$steps,$white_y,
	    $target_x,$target_y,$target_gamma,$signal_mode,$current_calibrated_slot_mask
	   );
	   return ($picture,$final_top_window_error) if($final_top_window_error && $final_top_window_error ne "cancelled");
	  }
	 }
	 my $final_all_level_error;
	 ($picture,$arrays,$final_all_level_error)=committed_final_all_level_verify(
	  $config,$state,$picture,$arrays,$picture_mode,$steps,$white_y,
	  $target_x,$target_y,$target_gamma,$signal_mode,$target_delta,$current_calibrated_slot_mask
		 );
		 return ($picture,$final_all_level_error) if($final_all_level_error && $final_all_level_error ne "cancelled");
		 promote_calibrated_26pt_slot_mask($calibrated_slot_mask,$current_calibrated_slot_mask);
		 $state->{"committed_polish"}={ status=>"complete", total=>$polish_total+0, current_index=>$polish_index+0, touches=>$polish_touches+0, kept=>$polish_kept+0, restored=>$polish_restored+0 };
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

sub autocal_completion_pattern_cleanup {
 my ($config,$state)=@_;
 return if(ref($config) ne "HASH" || !$config->{"lg_autocal_26"});
 return if(exists($config->{"autocal_completion_pattern_cleanup"}) && !$config->{"autocal_completion_pattern_cleanup"});
 my $stop_result=api_json("POST","/api/pattern",{ name=>"stop" },10);
 my $mode="stop";
 my $ok=(ref($stop_result) eq "HASH" && ($stop_result->{"status"}||"") ne "error") ? 1 : 0;
 if(!$ok) {
  my $pattern_range=$config->{"pattern_signal_range"}||$config->{"signal_range"}||"";
  my $transport_range=$config->{"transport_signal_range"}||$config->{"signal_range"}||"";
  my $payload={
   name => "patch",
   r => 0,
   g => 0,
   b => 0,
   size => 100,
   input_max => 255,
   signal_mode => $config->{"signal_mode"}||"sdr",
   max_luma => $config->{"max_luma"}||1000,
  };
  $payload->{"signal_range"}=$pattern_range if($pattern_range ne "");
  $payload->{"transport_signal_range"}=$transport_range if($transport_range ne "");
  my $black_result=api_json("POST","/api/pattern",$payload,10);
  $mode="black";
  $ok=(ref($black_result) eq "HASH" && ($black_result->{"status"}||"") ne "error") ? 1 : 0;
 }
 if(ref($state) eq "HASH") {
  $state->{"completion_pattern_cleanup"}={
   mode=>$mode,
   ok=>$ok ? JSON::PP::true : JSON::PP::false,
  };
  write_state($state);
 }
 log_line("Auto Cal completion pattern cleanup: $mode ".($ok ? "ok" : "failed"));
}

sub median_numeric {
 my (@values)=grep { defined($_) && $_ =~ /^-?(?:\d+(?:\.\d*)?|\.\d+)(?:e[+-]?\d+)?$/i } @_;
 return undef if(!@values);
 @values=sort { $a <=> $b } map { $_+0 } @values;
 my $n=scalar(@values);
 return $values[int($n/2)] if($n % 2);
 return ($values[$n/2-1]+$values[$n/2])/2;
}

sub median_autocal_readings {
	 my ($readings)=@_;
	 return undef if(ref($readings) ne "ARRAY" || !@{$readings});
 return clone_picture($readings->[0]) if(@{$readings} == 1);
 my $merged=clone_picture($readings->[0]);
 foreach my $key (qw(X Y Z x y luminance cct)) {
  my $median=median_numeric(map { ref($_) eq "HASH" ? $_->{$key} : undef } @{$readings});
  $merged->{$key}=$median if(defined($median));
 }
 $merged->{"timestamp"}=time();
 $merged->{"request_id"}=join("+",map { $_->{"request_id"}||() } @{$readings});
	 $merged->{"sample_count"}=scalar(@{$readings});
	 return $merged;
}

sub invalid_low_shadow_reading {
 my ($reading,$step)=@_;
 return 0 if(!autocal_step_is_low_shadow($step));
 return 1 if(ref($reading) ne "HASH");
 my $Y=luminance($reading);
 return 1 if(defined($Y) && $Y <= 0);
 my $x=defined($reading->{"x"}) ? ($reading->{"x"}+0) : undef;
 my $y=defined($reading->{"y"}) ? ($reading->{"y"}+0) : undef;
 return 1 if(defined($Y) && $Y < 0.5 && defined($x) && defined($y) && abs($x-0.333333) < 0.0002 && abs($y-0.333333) < 0.0002);
 return 0;
}

sub read_step {
		 my ($config,$step,$state_ref)=@_;
		 my $attempts=defined($config->{"read_attempts"}) ? int($config->{"read_attempts"}) : 5;
 $attempts=1 if($attempts < 1);
 $attempts=5 if($attempts > 5);
 my $last_error="";
	 if(autocal_step_is_low_shadow($step) && !(ref($config) eq "HASH" && $config->{"disable_low_shadow_median"})) {
	  my @samples;
	  my $sample_count=low_shadow_sample_count_for_step($config,$step);
	  my $sample_timeout=low_shadow_sample_read_timeout($config,$step);
	  my $max_sample_attempts=$sample_count+2;
	  for(my $sample=1;$sample<=$max_sample_attempts && @samples < $sample_count;$sample++) {
	   my $sample_index=@samples+1;
	   if(ref($state_ref) eq "HASH") {
	    $state_ref->{"message"}="Reading ".($step->{"name"}||"low shadow")." sample $sample_index/$sample_count";
	    write_state($state_ref);
	   }
	   my ($reading,$error)=read_step_once($config,$step,$sample,{ read_timeout=>$sample_timeout, low_shadow_sample=>1 });
	   if(!$error && ref($reading) eq "HASH") {
	    if(invalid_low_shadow_reading($reading,$step)) {
	     log_line("Discarding invalid low-shadow sample for ".($step->{"name"}||format_percent($step->{"ire"}||0)."%"));
	     if(ref($state_ref) eq "HASH") {
	      $state_ref->{"message"}="Discarded invalid low-shadow sample; rereading ".($step->{"name"}||"patch");
	      write_state($state_ref);
	     }
	     select(undef,undef,undef,0.4);
	     next;
	    }
	    push @samples,$reading;
	    next;
	   }
   $last_error=$error||$last_error;
   return (undef,$error) if(defined($error) && $error eq "cancelled");
   reset_meter_session_after_read_error($error) if(defined($error) && transient_read_error($error));
   last if(defined($error) && !transient_read_error($error));
  }
  return (median_autocal_readings(\@samples),undef) if(@samples >= 2);
  return ($samples[0],undef) if(@samples == 1);
 }
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
  my $target_step_y=effective_target_luminance_for_autocal_reading($white_y,$step,$reading,$target_gamma,$signal_mode,$config,$state_ref);
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
 return undef if(autocal_config_is_touchup($config));
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
 return undef if(autocal_config_is_touchup($config));
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
		 my ($config,$step,$attempt,$opts)=@_;
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
		 my $session_read_timeout=read_timeout_for_step($step,undef)-20;
		 $session_read_timeout=10 if($session_read_timeout < 10);
		 $session_read_timeout=300 if($session_read_timeout > 300);
		 $payload->{"read_timeout"}=int($session_read_timeout);
		 if(ref($opts) eq "HASH" && defined($opts->{"read_timeout"}) && $opts->{"read_timeout"} > 0) {
		  $payload->{"read_timeout"}=int($opts->{"read_timeout"});
		 }
		 my $read_started=time();
			 my $insert_error=apply_pattern_insert_before_read($config,$step);
			 return (undef,$insert_error) if(defined($insert_error) && $insert_error ne "");
			 $read_sequence++;
			 my $start_timeout=(ref($step) eq "HASH" && $step->{"autocal_probe_stimulus"}) ? 35 : 55;
			 $start_timeout=70 if($ire <= 5 && !(ref($step) eq "HASH" && $step->{"autocal_probe_stimulus"}));
			 my $start=api_json("POST","/api/meter/read",$payload,$start_timeout);
		 return (undef,$start->{"message"}||"Unable to start meter read") if(($start->{"status"}||"") eq "error");
		 my $deadline=time()+read_timeout_for_step($step,$payload->{"read_timeout"});
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
apply_lg_autocal_26_standalone_defaults($config);
$LG_AUTOCAL_CONFIG=$config;
my $steps=(ref($config->{"steps"}) eq "ARRAY") ? $config->{"steps"} : [];
unlink($trace_109_file) if(ref($config) eq "HASH" && $config->{"lg_autocal_26"});
$LG_AUTOCAL_DELTA_E_FORMULA=autocal_delta_e_formula($config);
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
my $min_iterations=autocal_config_is_touchup($config) ? 4 : 12;
$max_iterations=$min_iterations if($max_iterations < $min_iterations);
my ($target_x,$target_y)=(0.3127,0.3290);
if(ref($config->{"target_white"}) eq "HASH" && ($config->{"target_white"}{"x"}||0)>0 && ($config->{"target_white"}{"y"}||0)>0) {
 ($target_x,$target_y)=($config->{"target_white"}{"x"}+0,$config->{"target_white"}{"y"}+0);
}
my $full_workflow=(ref($config) eq "HASH" && $config->{"full_workflow"}) ? 1 : 0;
my $full_autocal_phase=(ref($config) eq "HASH") ? ($config->{"full_autocal_phase"}||"") : "";
$full_autocal_phase="touchup-greyscale" if($full_workflow && $full_autocal_phase eq "" && autocal_config_is_touchup($config));
my $run_id=(ref($config) eq "HASH" && defined($config->{"full_autocal_run_id"}) && $config->{"full_autocal_run_id"} ne "")
 ? $config->{"full_autocal_run_id"}
 : ("lg-grey-".$$."-".int(time()*1000));
my $started_at=int(time()*1000);

unlink($stop_file);
my $state={
 run_id=>$run_id,
 full_autocal_run_id=>$full_workflow ? $run_id : undef,
 started_at=>$started_at,
 status=>"running",
 autocal=>JSON::PP::true,
 current_step=>0,
 total_steps=>scalar(@{$steps}),
 current_name=>"Preparing LG Auto Cal...",
 readings=>[],
 steps=>$steps,
	 target_delta_e=>$target_delta,
	 delta_e_formula=>$LG_AUTOCAL_DELTA_E_FORMULA,
		 target_luminance=>$target_luminance||undef,
		 setup_luminance_reference=>$setup_luminance_reference||$target_luminance||undef,
		 headroom_target_luminance=>$headroom_target_luminance||undef,
		 target_gamma=>$target_gamma,
		 display_type=>$config->{"display_type"}||"lcd",
		 configured_delay_ms=>int($config->{"delay_ms"}||500),
		 full_workflow=>$full_workflow ? JSON::PP::true : JSON::PP::false,
		 full_autocal_phase=>$full_autocal_phase||undef,
		 full_autocal_touchup=>autocal_config_is_touchup($config) ? JSON::PP::true : JSON::PP::false,
		 final_1d_lut_uploaded=>JSON::PP::false,
		 final_1d_lut_upload_verified=>JSON::PP::false,
		 calibration_mode=>JSON::PP::false,
			 message=>"Starting",
			};
	if(lg_autocal_26_anchor_predrive_enabled($config)) {
	 $state->{"lg_autocal_26_mode"}="anchor_predrive";
	 $state->{"lg_autocal_26_anchor_predrive"}=JSON::PP::true;
	 $state->{"lg_autocal_26_anchor_predrive_anchors"}=[lg_autocal_26_anchor_predrive_anchor_ires()];
	 $state->{"lg_autocal_26_anchor_predrive_completed_anchors"}=[];
	 $state->{"lg_autocal_26_anchor_predrive_completed_slots"}=[];
	 $state->{"lg_autocal_26_anchor_predrive_synthesized_slots"}=[];
	 $state->{"lg_autocal_26_anchor_predrive_synthesized_ires"}=[];
	 $state->{"lg_autocal_26_anchor_predrive_propagation_events"}=0;
	} elsif(lg_autocal_26_full_ddc_spine_enabled($config)) {
	 $state->{"lg_autocal_26_mode"}="full_ddc_spine";
	 $state->{"lg_autocal_26_full_ddc_spine"}=JSON::PP::true;
	 $state->{"lg_autocal_26_full_ddc_spine_anchors"}=[lg_autocal_26_full_ddc_spine_anchor_ires()];
 $state->{"lg_autocal_26_full_ddc_spine_completed_anchors"}=[];
 $state->{"lg_autocal_26_full_ddc_spine_synthesized_slots"}=[];
}
	write_state($state);
	$LG_AUTOCAL_STATE=$state;
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
	 my @calibrated_ddc_slots=map { 0 } (1..ddc_slot_count());
	 my $finalize_calibrated_26pt_slot=sub {
	  my ($final_target,$final_read_step,$final_label)=@_;
	  mark_calibrated_26pt_slot(\@calibrated_ddc_slots,$final_target);
		  return 0 if(ref($config) ne "HASH" || !$config->{"lg_autocal_26"});
			  return 0 if(ref($arrays) ne "HASH" || ref($final_target) ne "HASH");
			  my @dynamic_seed_slots=ddc_slots();
			  my $calibrated_non_black_anchors=calibrated_non_black_26pt_anchor_count(\@calibrated_ddc_slots);
			  my $anchor_predrive_mode=lg_autocal_26_anchor_predrive_enabled($config);
			  my $full_ddc_spine_mode=lg_autocal_26_full_ddc_spine_enabled($config) && !$anchor_predrive_mode;
			  my @completed_anchor_ires=calibrated_26pt_slot_ires(\@calibrated_ddc_slots);
			  my @completed_spine_anchors=completed_lg_autocal_26_full_ddc_spine_anchor_ires(\@calibrated_ddc_slots);
			  my @completed_predrive_anchors=completed_lg_autocal_26_anchor_predrive_anchor_ires(\@calibrated_ddc_slots);
			  my $anchor_predrive_anchors_complete=(scalar(@completed_predrive_anchors) >= lg_autocal_26_anchor_predrive_anchor_count()) ? 1 : 0;
			  if($anchor_predrive_mode) {
			   $state->{"lg_autocal_26_mode"}="anchor_predrive";
			   $state->{"lg_autocal_26_anchor_predrive"}=JSON::PP::true;
			   $state->{"lg_autocal_26_anchor_predrive_completed_anchors"}=\@completed_predrive_anchors;
			   $state->{"lg_autocal_26_anchor_predrive_completed_slots"}=\@completed_anchor_ires;
			   $state->{"lg_autocal_26_anchor_predrive_last_completed_anchor"}=($final_target->{"ire"}+0) if(lg_autocal_26_anchor_predrive_anchor($final_target));
			  } elsif($full_ddc_spine_mode) {
			   $state->{"lg_autocal_26_mode"}="full_ddc_spine";
			   $state->{"lg_autocal_26_full_ddc_spine"}=JSON::PP::true;
			   $state->{"lg_autocal_26_full_ddc_spine_completed_anchors"}=\@completed_spine_anchors;
		   $state->{"lg_autocal_26_full_ddc_spine_completed_slots"}=\@completed_anchor_ires;
		   $state->{"lg_autocal_26_full_ddc_spine_last_completed_anchor"}=($final_target->{"ire"}+0) if(lg_autocal_26_full_ddc_spine_anchor($final_target));
		  }
		  my @dynamic_seed_settings=qw(whiteBalanceRed whiteBalanceGreen whiteBalanceBlue adjustingLuminance);
		  my $before_arrays=clone_arrays($arrays);
		  my $propagated_slots=refresh_propagated_uncalibrated_26pt_slots($config,$arrays,\@calibrated_ddc_slots);
		  my $after_arrays=clone_arrays($arrays);
		  my $changed_slots=0;
		  my @changed_slot_details;
	  for(my $idx=0;$idx<@dynamic_seed_slots;$idx++) {
	   next if($calibrated_ddc_slots[$idx]);
	   my $slot_changed=0;
	   my %changed_settings;
	   foreach my $setting (@dynamic_seed_settings) {
	    next if(ref($before_arrays->{$setting}) ne "ARRAY" || ref($after_arrays->{$setting}) ne "ARRAY");
	    my $before=defined($before_arrays->{$setting}[$idx]) ? ($before_arrays->{$setting}[$idx]+0) : 0;
	    my $after=defined($after_arrays->{$setting}[$idx]) ? ($after_arrays->{$setting}[$idx]+0) : 0;
	    if(abs($after-$before) > 0.0001) {
	     $slot_changed=1;
	     $changed_settings{$setting}={ before=>$before+0, after=>$after+0 };
	    }
	   }
	   if($slot_changed) {
	    $changed_slots++;
	    push @changed_slot_details,{
	     index=>$idx+0,
	     ire=>defined($dynamic_seed_slots[$idx]) ? ($dynamic_seed_slots[$idx]+0) : undef,
	     settings=>\%changed_settings
		    };
		   }
			  }
			  my @changed_slot_ires=map { $_->{"ire"} } @changed_slot_details;
			  if($anchor_predrive_mode) {
			   if($anchor_predrive_anchors_complete) {
			    my $propagation_events=($state->{"lg_autocal_26_anchor_predrive_propagation_events"}||0)+1;
			    $state->{"lg_autocal_26_anchor_predrive_synthesized_slots"}=\@changed_slot_details;
			    $state->{"lg_autocal_26_anchor_predrive_synthesized_ires"}=\@changed_slot_ires;
			    $state->{"lg_autocal_26_anchor_predrive_propagated_slots"}=$propagated_slots+0;
			    $state->{"lg_autocal_26_anchor_predrive_changed_slots"}=$changed_slots+0;
			    $state->{"lg_autocal_26_anchor_predrive_propagation_events"}=$propagation_events+0;
			    $state->{"lg_autocal_26_anchor_predrive_last_propagation"}={
			     event=>$propagation_events+0,
			     label=>$final_label||$final_target->{"label"}||"",
			     completed_anchors=>\@completed_predrive_anchors,
			     completed_slots=>\@completed_anchor_ires,
			     propagated_slots=>$propagated_slots+0,
			     changed_slots=>$changed_slots+0,
			     synthesized_ires=>\@changed_slot_ires
			    };
			    trace_109($final_read_step || $final_target,"anchor_predrive_seed_propagation",{
			     mode=>"anchor_predrive",
			     label=>$final_label||$final_target->{"label"}||"",
			     target=>$final_target,
			     completed_anchors=>\@completed_predrive_anchors,
			     completed_slots=>\@completed_anchor_ires,
			     completed_anchor_count=>scalar(@completed_predrive_anchors)+0,
			     anchor=>lg_autocal_26_anchor_predrive_anchor($final_target) ? JSON::PP::true : JSON::PP::false,
			     propagated_slots=>$propagated_slots+0,
			     synthesized_seeded_slots=>\@changed_slot_details,
			     synthesized_seeded_ires=>\@changed_slot_ires,
			     changed_slots=>$changed_slots+0,
			     propagation_event=>$propagation_events+0,
			     calibrated_non_black_anchors=>$calibrated_non_black_anchors+0
			    });
			   }
			  } elsif($full_ddc_spine_mode) {
			   $state->{"lg_autocal_26_full_ddc_spine_synthesized_slots"}=\@changed_slot_details;
			   $state->{"lg_autocal_26_full_ddc_spine_synthesized_ires"}=\@changed_slot_ires;
			   $state->{"lg_autocal_26_full_ddc_spine_propagated_slots"}=$propagated_slots+0;
		   trace_109($final_read_step || $final_target,"full_ddc_spine_seed_propagation",{
		    mode=>"full_ddc_spine",
		    label=>$final_label||$final_target->{"label"}||"",
		    target=>$final_target,
		    completed_anchors=>\@completed_anchor_ires,
		    completed_spine_anchors=>\@completed_spine_anchors,
		    completed_anchor_count=>scalar(@completed_anchor_ires)+0,
		    completed_spine_anchor_count=>scalar(@completed_spine_anchors)+0,
		    spine_anchor=>lg_autocal_26_full_ddc_spine_anchor($final_target) ? JSON::PP::true : JSON::PP::false,
		    propagated_slots=>$propagated_slots+0,
		    synthesized_seeded_slots=>\@changed_slot_details,
		    synthesized_seeded_ires=>\@changed_slot_ires,
		    changed_slots=>$changed_slots+0,
			    calibrated_non_black_anchors=>$calibrated_non_black_anchors+0
			   });
			  }
			  write_state($state) if($anchor_predrive_mode || $full_ddc_spine_mode);
			  return 0 if(!$propagated_slots);
			  return 0 if(!$changed_slots);
		  $state->{"dynamic_propagated_26pt_slots"}=$changed_slots+0;
			  $state->{"propagated_26pt_slots"}=$changed_slots+0;
			  $state->{"dynamic_propagated_26pt_slot_details"}=\@changed_slot_details;
			  trace_109($final_read_step || $final_target,"dynamic_26pt_seed_propagation",{
			   mode=>$anchor_predrive_mode ? "anchor_predrive" : ($full_ddc_spine_mode ? "full_ddc_spine" : "dynamic"),
			   label=>$final_label||$final_target->{"label"}||"",
			   changed_slots=>$changed_slots+0,
			   changed_slot_details=>\@changed_slot_details,
			   synthesized_seeded_slots=>\@changed_slot_details,
			   completed_anchors=>\@completed_anchor_ires,
			   completed_spine_anchors=>\@completed_spine_anchors,
			   completed_anchor_predrive_anchors=>\@completed_predrive_anchors,
			   propagated_slots=>$propagated_slots+0,
			   calibrated_non_black_anchors=>$calibrated_non_black_anchors+0,
			   target=>$final_target
	  });
	  if(!cancelled()) {
	   $state->{"phase"}="writing";
	   $state->{"message"}="Dynamic 26pt seed propagation updated $changed_slots pending slots";
	   write_state($state);
	   my $dynamic_seed_error;
	   ($picture,$dynamic_seed_error)=set_picture_values($picture,$arrays,$final_target,$picture_mode,$calibration_mode_active,$state);
	   die $dynamic_seed_error if($dynamic_seed_error);
	   $calibration_mode_active=1;
	   sync_state_picture($state,$picture,$picture_mode);
	  }
	  return $changed_slots;
	 };
	 sync_state_picture($state,$picture,$picture_mode);
	 write_state($state);
		 my @ordered=order_autocal_steps($steps,$config);
	 die "No adjustable LG greyscale steps were supplied" if(!@ordered);
		 my @verification=verification_autocal_steps($steps);
		 my ($black_step)=grep { ref($_) eq "HASH" && defined($_->{"ire"}) && abs(($_->{"ire"}+0)) < 0.001 } @{$steps};
		 my ($white_reference_step)=grep { ref($_) eq "HASH" && $_->{"autocal_white_reference"} } @{$steps};
		 my $white_reference_is_adjustable=($white_reference_step && ddc_target_for_step($white_reference_step)) ? 1 : 0;
		 my $refresh_white_after_headroom=0;
		 my $total_ordered_steps=scalar(@ordered)+scalar(@verification)+($black_step ? 1 : 0);

		 my $white_y=($target_luminance > 0) ? $target_luminance : undef;
		 set_state_white_reference($state,$white_y) if(defined($white_y) && $white_y > 0);
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
			  $white_y=update_white_reference_for_autocal_step($config,$state,$read_step,$ref_reading,$white_y);
			  $white_y ||= 100;
			  refresh_headroom_targets_after_white_reference($state,$read_step,$white_y,$target_x,$target_y,$target_gamma,$signal_mode);
			  my $target_lum_y=target_luminance_for_step($white_y,$read_step,$target_gamma,$signal_mode);
		  annotate_reading_target($ref_reading,$white_y,$target_lum_y,$target_x,$target_y);
		  $state->{"readings"}=merge_reading($state->{"readings"},$ref_reading);
		  $state->{"current_luminance"}=luminance($ref_reading);
		  $state->{"current_delta_e"}=undef;
		  set_state_white_reference($state,$white_y) if(autocal_step_is_white($read_step));
		  set_state_target_step_luminance($state,$target_lum_y);
		  write_state($state);
		  return $ref_reading;
			 };
			 my $white_refreshed_after_headroom=0;
			 my $low_shadow_calibration_settled=0;
		 foreach my $step (@ordered) {
		  last if(cancelled());
		  $step_num++;
		  my $target=ddc_target_for_step($step);
		  next if(!$target);
		  my $mismatch=ddc_step_signal_mismatch($step,$config);
		  die $mismatch if($mismatch ne "");
				  my $label=$target->{"label"};
					  my $slot_read_step=fixed_lg_autocal_step($config,$step);
					  my $read_step=clone_picture($slot_read_step);
				  if(ref($config) eq "HASH" && $config->{"lg_autocal_26"} && autocal_step_is_low_shadow($read_step) && !$low_shadow_calibration_settled) {
				   my $settle_ms=config_positive_int($config,"low_shadow_pre_settle_ms",12000,0,60000);
				   park_black_for_settle($config,$state,"Settling panel before low-shadow greyscale calibration",$settle_ms);
				   $low_shadow_calibration_settled=1;
					  }
					  my $paired_white_step=legal_white_pair_reference_step($steps,$target,$step,$config);
				  $paired_white_step=fixed_lg_autocal_step($config,$paired_white_step) if($paired_white_step);
				  if($paired_white_step) {
				   $slot_read_step->{"legal_white_pair_active"}=JSON::PP::true if(ref($slot_read_step) eq "HASH");
				   $read_step->{"legal_white_pair_active"}=JSON::PP::true if(ref($read_step) eq "HASH");
				   $paired_white_step->{"legal_white_pair_active"}=JSON::PP::true if(ref($paired_white_step) eq "HASH");
				  }
				  trace_109($read_step,"start_step",{
			   label=>$label,
			   target=>$target,
			   target_values=>trace_target_values($arrays,$target)
			  });
			  my $seed_from_prior_slot=0;
			  $seed_from_prior_slot=seed_target_from_prior_slot($arrays,$target,\@calibrated_ddc_slots,$config)
			   if(ref($config) eq "HASH" && $config->{"lg_autocal_26"});
			  if($seed_from_prior_slot) {
			   trace_109($read_step,"seed_from_prior_slot",{
			    label=>$label,
			    target_values=>trace_target_values($arrays,$target),
			    seed=>$seed_from_prior_slot
			   });
			   $state->{"current_step"}=$step_num;
		   $state->{"total_steps"}=$total_ordered_steps;
		   $state->{"current_name"}="Auto Cal $label";
		   $state->{"phase"}="writing";
		   $state->{"message"}=(ref($seed_from_prior_slot) eq "HASH" && ($seed_from_prior_slot->{"mode"}||"") eq "luma-only")
		    ? "Refining $label spline seed from nearest calibrated anchor"
		    : "Seeding $label from nearest calibrated point";
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
			  $state->{"current_name"}="Auto Cal $label";
  $state->{"phase"}="reading";
  $state->{"message"}="Reading $label";
  $state->{"active_stimulus"}=$read_step->{"stimulus"}+0 if(defined($read_step->{"stimulus"}));
  clear_state_step_measurements($state);
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
	  $white_y=update_white_reference_for_autocal_step($config,$state,$read_step,$reading,$white_y);
	  $white_y ||= 100;
			  refresh_headroom_targets_after_white_reference($state,$read_step,$white_y,$target_x,$target_y,$target_gamma,$signal_mode);
			  my $target_step_y=defined($guarded_target_step_y) ? $guarded_target_step_y : effective_target_luminance_for_autocal_reading($white_y,$read_step,$reading,$target_gamma,$signal_mode);
	  annotate_reading_target($reading,$white_y,$target_step_y,$target_x,$target_y);
	  my $de=autocal_delta_e_for_step($config,$reading,$read_step,$white_y,$target_x,$target_y,$target_step_y);
		  my $best_de=defined($de) ? $de : 9999;
			  my $best_lum_pct=undef;
			  my $best_arrays=decode_json_safe($json->encode($arrays),{});
			  my $best_reading=clone_picture($reading);
			  my $best_read_step=clone_picture($read_step);
			  my $slot_default_arrays=clone_arrays($arrays);
	  $state->{"readings"}=merge_reading($state->{"readings"},$reading);
	  $state->{"current_delta_e"}=defined($de) ? $de : undef;
	  $state->{"best_delta_e"}=$best_de;
	  $state->{"current_luminance"}=luminance($reading);
	  set_state_target_step_luminance($state,$target_step_y);
		  my $lum_pct=luminance_error_percent($reading,$target_step_y);
		  $best_lum_pct=$lum_pct;
		  my $best_score=guarded_autocal_result_score($best_de,$best_lum_pct,$read_step,$best_reading,$white_guard_y);
			  my ($pair_step,$pair_reading,$pair_de,$pair_lum_pct,$pair_target_step_y);
			  my ($best_pair_step,$best_pair_reading,$best_pair_de,$best_pair_lum_pct,$best_pair_target_step_y);
			  my $pair_score_now=sub {
			   return legal_white_pair_score($de,$lum_pct,$read_step,$reading,$pair_de,$pair_lum_pct,$pair_step,$pair_reading,$white_guard_y);
			  };
			  my $pair_target_reached_now=sub {
			   return legal_white_pair_target_reached($de,$lum_pct,$read_step,$reading,$pair_de,$pair_lum_pct,$pair_step,$pair_reading,$target_delta,$white_guard_y);
			  };
			  my $store_best_pair=sub {
			   $best_pair_step=clone_picture($pair_step) if(ref($pair_step) eq "HASH");
			   $best_pair_reading=clone_picture($pair_reading) if(ref($pair_reading) eq "HASH");
			   $best_pair_de=$pair_de;
			   $best_pair_lum_pct=$pair_lum_pct;
			   $best_pair_target_step_y=$pair_target_step_y;
			  };
				  my $pair_best_update_reason=sub {
					   my ($candidate_score)=@_;
					   return undef if(!defined($de));
						   if(!$paired_white_step) {
						    return undef if(!autocal_measurement_not_worse_than_best($de,$lum_pct,$best_de,$best_lum_pct));
						    return ($candidate_score + 0.0001 < $best_score) ? "score_improved" : undef;
						   }
						   return undef if(
						    defined($best_de) &&
						    within_itp_luminance_included_acceptance($best_de,$best_read_step) &&
						    !within_itp_luminance_included_acceptance($de,$read_step)
					   );
					   return undef if(
						    defined($best_pair_de) &&
						    within_itp_luminance_included_acceptance($best_pair_de,$best_pair_step) &&
						    !within_itp_luminance_included_acceptance($pair_de,$pair_step)
						   );
					   # For 99/100, the shared DDC slot must keep the best combined pair.
					   # A candidate may make the active side slightly worse while pulling the
					   # paired legal-white read materially closer; score the pair before the
					   # single-side "not worse" gate rejects it.
						   return legal_white_pair_best_update_reason(
						    $candidate_score,$best_score,
					    $de,$pair_de,$best_de,$best_pair_de,$target_delta
				   );
			  };
			  my $read_legal_white_pair_counterpart=sub {
			   my ($reason)=@_;
			   return 1 if(!$paired_white_step);
			   my $other_step=autocal_step_is_white($read_step) ? clone_picture($slot_read_step) : clone_picture($paired_white_step);
			   return 0 if(ref($other_step) ne "HASH");
			   my $other_label=autocal_step_is_white($other_step) ? "100% legal white" : $label;
			   $state->{"phase"}="reading";
			   $state->{"current_name"}="Auto Cal $label";
			   $state->{"message"}=($reason||"Balancing paired 99% and 100% reads").": reading $other_label";
			   $state->{"active_stimulus"}=$other_step->{"stimulus"}+0 if(defined($other_step->{"stimulus"}));
			   write_state($state);
			   my ($other_reading,$other_error,$other_guarded_y)=read_step_guarded($config,$other_step,$state,$white_y,$target_gamma,$signal_mode,$target_x,$target_y,$other_label);
			   die $other_error if($other_error && $other_error ne "cancelled");
			   return 0 if($other_error && $other_error eq "cancelled");
				   return 0 if(ref($other_reading) ne "HASH");
					   $white_y=update_white_reference_for_autocal_step($config,$state,$other_step,$other_reading,$white_y);
				   $white_y ||= 100;
				   refresh_headroom_targets_after_white_reference($state,$other_step,$white_y,$target_x,$target_y,$target_gamma,$signal_mode);
				   my $other_target_step_y=defined($other_guarded_y) ? $other_guarded_y : effective_target_luminance_for_autocal_reading($white_y,$other_step,$other_reading,$target_gamma,$signal_mode);
			   annotate_reading_target($other_reading,$white_y,$other_target_step_y,$target_x,$target_y);
			   my $other_de=autocal_delta_e_for_step($config,$other_reading,$other_step,$white_y,$target_x,$target_y,$other_target_step_y);
			   my $other_lum_pct=luminance_error_percent($other_reading,$other_target_step_y);
			   $pair_step=$other_step;
			   $pair_reading=$other_reading;
			   $pair_de=$other_de;
			   $pair_lum_pct=$other_lum_pct;
			   $pair_target_step_y=$other_target_step_y;
			   $state->{"readings"}=merge_reading($state->{"readings"},$other_reading);
			   $state->{"paired_delta_e"}=defined($pair_de) ? $pair_de : undef;
			   $state->{"paired_luminance_error_pct"}=defined($pair_lum_pct) ? $pair_lum_pct : undef;
			   $state->{"paired_current_name"}=$other_label;
			   set_state_target_step_luminance($state,$target_step_y);
			   write_state($state);
			   trace_109($other_step,"legal_white_pair_measurement",{
			    label=>$label,
			    reason=>$reason||"",
			    paired_label=>$other_label,
			    reading=>trace_reading_summary($other_reading),
			    target_luminance=>$other_target_step_y,
			    white_y=>$white_y,
			    delta_e=>defined($pair_de)?$pair_de+0:undef,
			    luminance_error_pct=>defined($pair_lum_pct)?$pair_lum_pct+0:undef,
			    pair_score=>$pair_score_now->()+0,
			    target_values=>trace_target_values($arrays,$target)
			   });
			   return 1;
			  };
			  my $switch_to_worst_pair_step=sub {
			   my ($reason)=@_;
			   return 0 if(!$paired_white_step || ref($pair_step) ne "HASH" || ref($pair_reading) ne "HASH");
			   my $current_score=guarded_autocal_result_score($de,$lum_pct,$read_step,$reading,$white_guard_y);
			   my $other_score=guarded_autocal_result_score($pair_de,$pair_lum_pct,$pair_step,$pair_reading,$white_guard_y);
			   my $spread_limit=legal_white_pair_spread_limit($target_delta);
			   my $current_needs_work=legal_white_pair_needs_work($de,$lum_pct,$read_step,$reading,$target_delta,$white_guard_y);
			   my $other_needs_work=legal_white_pair_needs_work($pair_de,$pair_lum_pct,$pair_step,$pair_reading,$target_delta,$white_guard_y);
			   my $other_de=defined($pair_de) ? ($pair_de+0) : 9999;
			   my $current_de=defined($de) ? ($de+0) : 9999;
			   my $force_other_focus=0;
			   if($other_needs_work) {
			    $force_other_focus=1 if(!$current_needs_work);
			    $force_other_focus=1 if($other_de > $target_delta+0.10 && $other_de > $current_de+0.08);
			    # The shared LG 99/100 DDC slot can only tune 99% luminance when
			    # the active side is the 99% patch. Do not let a cleaner 100% read
			    # hide a visibly worse 99% read.
			    $force_other_focus=1 if(autocal_step_is_white($read_step) && !autocal_step_is_white($pair_step) && $other_de > $target_delta+0.10);
			   }
			   return 0 if(!$force_other_focus && $other_score <= $current_score+$spread_limit);
			   my ($old_step,$old_reading,$old_de,$old_lum_pct,$old_target_step_y)=(
			    clone_picture($read_step),clone_picture($reading),$de,$lum_pct,$target_step_y
			   );
			   $read_step=clone_picture($pair_step);
			   $reading=clone_picture($pair_reading);
			   $de=$pair_de;
			   $lum_pct=$pair_lum_pct;
			   $target_step_y=$pair_target_step_y;
			   $pair_step=$old_step;
			   $pair_reading=$old_reading;
			   $pair_de=$old_de;
			   $pair_lum_pct=$old_lum_pct;
			   $pair_target_step_y=$old_target_step_y;
			   $state->{"current_delta_e"}=defined($de) ? $de : undef;
			   $state->{"current_luminance"}=luminance($reading);
			   $state->{"luminance_error_pct"}=defined($lum_pct) ? $lum_pct : undef;
			   $state->{"active_stimulus"}=$read_step->{"stimulus"}+0 if(defined($read_step->{"stimulus"}));
			   set_state_target_step_luminance($state,$target_step_y);
			   trace_109($read_step,"legal_white_pair_switch",{
			    label=>$label,
			    reason=>$reason||"",
			    current_score=>$current_score+0,
			    paired_score=>$other_score+0,
			    spread_limit=>$spread_limit+0,
			    forced_focus=>$force_other_focus?JSON::PP::true:JSON::PP::false,
			    next_delta_e=>defined($de)?$de+0:undef,
			    next_luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef
			   });
			   return 1;
			  };
			  my $body_final_micro_done=0;
			  my $run_body_final_micro_once=sub {
			   my ($reason)=@_;
			   return 0 if($body_final_micro_done || $paired_white_step || cancelled());
			   return 0 if(ref($best_arrays) ne "HASH" || ref($best_reading) ne "HASH" || ref($best_read_step) ne "HASH");
			   my $micro_step=clone_picture($best_read_step);
			   return 0 if(!autocal_step_allows_body_final_micro($micro_step));
			   my $micro_arrays=clone_arrays($best_arrays);
			   my $micro_reading=clone_picture($best_reading);
			   my $micro_target_y=effective_target_luminance_for_autocal_reading($white_y,$micro_step,$micro_reading,$target_gamma,$signal_mode);
			   annotate_reading_target($micro_reading,$white_y,$micro_target_y,$target_x,$target_y);
			   my $micro_de=defined($best_de) ? $best_de : autocal_delta_e_for_step($config,$micro_reading,$micro_step,$white_y,$target_x,$target_y,$micro_target_y);
			   my $micro_lum_pct=defined($best_lum_pct) ? $best_lum_pct : luminance_error_percent($micro_reading,$micro_target_y);
			   my $before_error=autocal_adjustment_error($micro_reading,$micro_step);
			   my ($before_rgb_ch,$before_rgb_err,$before_rgb_max)=furthest_rgb_error_channel($before_error);
			   my %micro_tried;
			   mark_tried_values(\%micro_tried,$micro_arrays,$target,$micro_de);
			   my $adjustments=body_final_micro_adjustments($micro_reading,$micro_arrays,$target,$micro_step,$target_delta,$micro_de,$micro_lum_pct,\%micro_tried);
			   return 0 if(!$adjustments);
			   $body_final_micro_done=1;
			   $arrays=$micro_arrays;
			   $read_step=$micro_step;
			   $reading=$micro_reading;
			   $de=$micro_de;
			   $lum_pct=$micro_lum_pct;
			   $target_step_y=$micro_target_y;
			   foreach my $adj (@{$adjustments}) {
			    $arrays->{$adj->{"setting"}}[$target->{"index"}]=$adj->{"next"};
			   }
			   trace_109($read_step,"body_final_micro_plan",{
			    label=>$label,
			    reason=>$reason||"Final body RGB micro-balance",
			    delta_e=>defined($de)?$de+0:undef,
			    luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef,
			    rgb_error=>$before_error,
			    rgb_max_error=>$before_rgb_max+0,
			    adjustments=>trace_adjustments_summary($adjustments),
			    values_before=>trace_target_values($best_arrays,$target),
			    values_after=>trace_target_values($arrays,$target)
			   });
			   $state->{"phase"}="writing";
			   $state->{"message"}=($reason||"Final micro-balancing $label")." ".describe_adjustments($adjustments);
			   write_state($state);
			   my $write_error;
			   ($picture,$write_error)=set_picture_values($picture,$arrays,$target,$picture_mode,$calibration_mode_active,$state);
			   die $write_error if($write_error);
			   $calibration_mode_active=1;
			   sync_state_picture($state,$picture,$picture_mode);
			   return 1 if(cancelled());
			   $state->{"phase"}="reading";
			   $state->{"message"}="Reading $label final micro-balance";
			   write_state($state);
			   ($reading,$read_error,$guarded_target_step_y)=read_step_guarded($config,$read_step,$state,$white_y,$target_gamma,$signal_mode,$target_x,$target_y,$label);
				   die $read_error if($read_error && $read_error ne "cancelled");
				   return 1 if($read_error && $read_error eq "cancelled");
				   $white_y=update_white_reference_for_autocal_step($config,$state,$read_step,$reading,$white_y);
				   refresh_headroom_targets_after_white_reference($state,$read_step,$white_y,$target_x,$target_y,$target_gamma,$signal_mode);
				   $target_step_y=defined($guarded_target_step_y) ? $guarded_target_step_y : effective_target_luminance_for_autocal_reading($white_y,$read_step,$reading,$target_gamma,$signal_mode);
			   annotate_reading_target($reading,$white_y,$target_step_y,$target_x,$target_y);
			   $de=autocal_delta_e_for_step($config,$reading,$read_step,$white_y,$target_x,$target_y,$target_step_y);
			   $lum_pct=luminance_error_percent($reading,$target_step_y);
			   my $candidate_score=guarded_autocal_result_score($de,$lum_pct,$read_step,$reading,$white_guard_y);
			   my $after_error=autocal_adjustment_error($reading,$read_step);
			   my ($after_rgb_ch,$after_rgb_err,$after_rgb_max)=furthest_rgb_error_channel($after_error);
			   my $not_worse_measurement=autocal_measurement_not_worse_than_best($de,$lum_pct,$best_de,$best_lum_pct);
			   my $improved_score=(defined($de) && $not_worse_measurement && $candidate_score + 0.0001 < $best_score) ? 1 : 0;
			   my $improved_balance=(defined($de) && $not_worse_measurement && $candidate_score <= $best_score+0.03 && $after_rgb_max+0.0002 < $before_rgb_max) ? 1 : 0;
				   my $keep=($improved_score || $improved_balance) && body_final_micro_near_target_reached($read_step,$de,$lum_pct,$target_delta);
			   trace_109($read_step,"body_final_micro_measurement",{
			    label=>$label,
			    reason=>$reason||"Final body RGB micro-balance",
			    reading=>trace_reading_summary($reading),
			    delta_e=>defined($de)?$de+0:undef,
			    luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef,
			    score=>$candidate_score+0,
			    best_delta_e=>defined($best_de)?$best_de+0:undef,
			    best_score=>$best_score+0,
			    rgb_error=>$after_error,
			    rgb_max_error=>$after_rgb_max+0,
			    previous_rgb_max_error=>$before_rgb_max+0,
			    not_worse_measurement=>$not_worse_measurement?JSON::PP::true:JSON::PP::false,
			    kept=>$keep?JSON::PP::true:JSON::PP::false,
			    target_values=>trace_target_values($arrays,$target)
			   });
			   if($keep) {
			    $best_de=$de;
			    $best_lum_pct=$lum_pct;
			    $best_score=$candidate_score;
			    $best_arrays=clone_arrays($arrays);
			    $best_reading=clone_picture($reading);
			    $best_read_step=clone_picture($read_step);
			    $state->{"readings"}=merge_reading($state->{"readings"},$reading) if(ref($reading) eq "HASH");
			    $state->{"current_delta_e"}=defined($de) ? $de : undef;
			    $state->{"current_luminance"}=luminance($reading);
			    $state->{"luminance_error_pct"}=defined($lum_pct) ? $lum_pct : undef;
			    $state->{"best_delta_e"}=$best_de;
			    $state->{"best_score"}=$best_score;
			    set_state_target_step_luminance($state,$target_step_y);
			    write_state($state);
			    return 1;
			   }
			   $arrays=clone_arrays($best_arrays);
			   $state->{"phase"}="restoring";
			   $state->{"message"}="Restoring closest $label result after final micro-balance";
			   write_state($state);
			   ($picture,$write_error)=set_picture_values($picture,$arrays,$target,$picture_mode,$calibration_mode_active,$state);
			   die $write_error if($write_error);
			   $calibration_mode_active=1;
			   sync_state_picture($state,$picture,$picture_mode);
			   $read_step=clone_picture($best_read_step);
			   $reading=clone_picture($best_reading);
			   $de=$best_de;
			   $lum_pct=$best_lum_pct;
			   $target_step_y=effective_target_luminance_for_autocal_reading($white_y,$read_step,$reading,$target_gamma,$signal_mode);
			   $state->{"readings"}=merge_reading($state->{"readings"},$reading) if(ref($reading) eq "HASH");
			   $state->{"current_delta_e"}=defined($de) ? $de : undef;
			   $state->{"current_luminance"}=luminance($reading);
			   $state->{"luminance_error_pct"}=defined($lum_pct) ? $lum_pct : undef;
			   $state->{"best_delta_e"}=$best_de;
			   $state->{"best_score"}=$best_score;
			   set_state_target_step_luminance($state,$target_step_y);
			   write_state($state);
			   return 1;
			  };
			  if($paired_white_step) {
			   last if(!$read_legal_white_pair_counterpart->("Balancing 99% DDC slot") && cancelled());
			   $best_score=$pair_score_now->();
			   $store_best_pair->();
			   if($switch_to_worst_pair_step->("Initial paired read")) {
			    $best_de=$de;
			    $best_lum_pct=$lum_pct;
			    $best_reading=clone_picture($reading);
			    $best_read_step=clone_picture($read_step);
			    $best_score=$pair_score_now->();
			    $store_best_pair->();
			   }
			  }
			  $state->{"luminance_error_pct"}=defined($lum_pct) ? $lum_pct : undef;
			  $state->{"best_score"}=$best_score;
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
						  if(touchup_delta_skip_reached($config,$de,$target_delta,$read_step,$lum_pct) && (!$paired_white_step || $pair_target_reached_now->())) {
						   $state->{"message"}="$label already within touch-up target; moving to next patch";
					   $state->{"best_delta_e"}=$best_de;
					   $state->{"best_score"}=$best_score;
					   write_state($state);
					   remember_lg_autocal_26_best_known(
					    $config,$state,$read_step,$reading,$de,$lum_pct,
					    $target_step_y,$arrays,$target,"main_initial_touchup_target"
					   );
					   $finalize_calibrated_26pt_slot->($target,$read_step,$label);
					   next;
					  }
					  if($pair_target_reached_now->()) {
					   $run_body_final_micro_once->("Final micro-balancing $label before moving on");
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
				   if($pair_target_reached_now->()) {
				    remember_lg_autocal_26_best_known(
				     $config,$state,$read_step,$reading,$de,$lum_pct,
				     $target_step_y,$arrays,$target,"main_initial_target_reached"
				    );
				    $finalize_calibrated_26pt_slot->($target,$read_step,$label);
				    next;
				   }
				  }

				  my $last_de=$best_de;
				  my $stalls=0;
					  my $no_response_stalls=0;
					  my %tried_values;
					  my %rgb_response_model;
					  my $headroom_next_adjustments;
					  my $low_shadow_next_adjustments;
					  my $body_luminance_next_adjustments;
				  mark_tried_values(\%tried_values,$arrays,$target,$de);
				  my $restore_best_branch=sub {
				   my ($reason)=@_;
				   return 0 if(ref($best_arrays) ne "HASH" || ref($best_reading) ne "HASH");
				   trace_109($read_step,"restore_best_branch",{
				    label=>$label,
				    reason=>$reason||"Backtracking to best $label result",
				    current_delta_e=>defined($de)?$de+0:undef,
				    current_luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef,
					    current_score=>($paired_white_step ? $pair_score_now->() : guarded_autocal_result_score($de,$lum_pct,$read_step,$reading,$white_guard_y))+0,
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
			   $read_step=clone_picture($best_read_step) if(ref($best_read_step) eq "HASH");
			   $reading=clone_picture($best_reading);
			   $de=$best_de;
			   $lum_pct=$best_lum_pct;
			   if($paired_white_step && ref($best_pair_step) eq "HASH" && ref($best_pair_reading) eq "HASH") {
			    $pair_step=clone_picture($best_pair_step);
			    $pair_reading=clone_picture($best_pair_reading);
			    $pair_de=$best_pair_de;
			    $pair_lum_pct=$best_pair_lum_pct;
			    $pair_target_step_y=$best_pair_target_step_y;
			    $state->{"readings"}=merge_reading($state->{"readings"},$pair_reading);
				   }
				   $white_y=update_white_reference_for_autocal_step($config,$state,$read_step,$reading,$white_y);
				   refresh_headroom_targets_after_white_reference($state,$read_step,$white_y,$target_x,$target_y,$target_gamma,$signal_mode);
				   $target_step_y=effective_target_luminance_for_autocal_reading($white_y,$read_step,$reading,$target_gamma,$signal_mode);
			   return 1;
			  };
			  my $apply_probe_result=sub {
		   my ($probe_step,$probe_reading,$probe_arrays,$probe_picture)=@_;
		   return 0 if(!$probe_step || ref($probe_reading) ne "HASH" || ref($probe_arrays) ne "HASH");
		   $read_step=$probe_step;
		   $arrays=$probe_arrays;
			   $picture=$probe_picture if(ref($probe_picture) eq "HASH");
			   $reading=$probe_reading;
			   $white_y=update_white_reference_for_autocal_step($config,$state,$read_step,$reading,$white_y);
			   refresh_headroom_targets_after_white_reference($state,$read_step,$white_y,$target_x,$target_y,$target_gamma,$signal_mode);
			   $target_step_y=effective_target_luminance_for_autocal_reading($white_y,$read_step,$reading,$target_gamma,$signal_mode);
			   annotate_reading_target($reading,$white_y,$target_step_y,$target_x,$target_y);
			   $de=autocal_delta_e_for_step($config,$reading,$read_step,$white_y,$target_x,$target_y,$target_step_y);
			   $lum_pct=luminance_error_percent($reading,$target_step_y);
				   my $probe_score=guarded_autocal_result_score($de,$lum_pct,$read_step,$reading,$white_guard_y);
					   if(defined($de) && autocal_measurement_not_worse_than_best($de,$lum_pct,$best_de,$best_lum_pct) && $probe_score + 0.0001 < $best_score) {
					    $best_de=$de;
				    $best_lum_pct=$lum_pct;
				    $best_score=$probe_score;
				    $best_arrays=clone_arrays($arrays);
					    $best_reading=clone_picture($reading);
					    $best_read_step=clone_picture($read_step);
					   }
					   trace_109($read_step,"probe_applied",{
					    label=>$label,
					    reading=>trace_reading_summary($reading),
					    delta_e=>defined($de)?$de+0:undef,
					    luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef,
					    score=>$probe_score+0,
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
				   %rgb_response_model=();
			   mark_tried_values(\%tried_values,$arrays,$target,$de);
			   $stalls=0;
			   $no_response_stalls=0;
		   return 1;
		  };
				  my $candidate_chroma_keep=sub {
				   return (0,undef,undef) if(!defined($de));
				   return (0,undef,undef) if(white_luminance_guard_failed($read_step,$reading,$white_guard_y));
				   return (0,undef,undef) if($paired_white_step);
					   return (0,undef,undef) if(!autocal_step_is_fast_headroom($read_step));
					   my $candidate_chroma=autocal_chroma_delta_e_for_step($config,$reading,$read_step,$white_y,$target_x,$target_y);
					   my $best_chroma=autocal_chroma_delta_e_for_step($config,$best_reading,$best_read_step,$white_y,$target_x,$target_y);
					   return (0,$candidate_chroma,$best_chroma) if(!defined($candidate_chroma) || !defined($best_chroma));
					   if(!autocal_step_is_peak_headroom($read_step) && defined($best_de) && ($de+0.0001) >= ($best_de+0)) {
					    return (0,$candidate_chroma,$best_chroma);
					   }
					   return (0,$candidate_chroma,$best_chroma) if($candidate_chroma + 0.0001 >= $best_chroma);
				   my $gain=$best_chroma-$candidate_chroma;
				   return (0,$candidate_chroma,$best_chroma) if($candidate_chroma > 1.05 && $gain < 0.25);
				   if(!autocal_step_is_peak_headroom($read_step)) {
				   return (0,$candidate_chroma,$best_chroma) if(defined($lum_pct) && abs($lum_pct) > 5 && $candidate_chroma > 1.05);
				   }
				   return (1,$candidate_chroma,$best_chroma);
				  };
				  my $candidate_delta_keep=sub {
				   return 0 if(!autocal_step_is_low_shadow($read_step));
				   return 0 if(!defined($de) || !defined($best_de));
				   return 0 if(low_ire_luminance_needs_lift($read_step,$lum_pct));
				   return ($de + 0.0001 < $best_de) ? 1 : 0;
				  };
				  my $try_high_end_paired_luma_probe=sub {
				   my ($attempt_adjustments,$candidate_score,$candidate_chroma,$best_chroma,$tried_ref,$phase_label,$phase_index)=@_;
				   my $probe=high_end_paired_luma_adjustment(
				    $config,$read_step,$target,$arrays,$attempt_adjustments,$lum_pct,$best_lum_pct,
				    $candidate_chroma,$best_chroma,$tried_ref,$paired_white_step
				   );
				   return 0 if(ref($probe) ne "HASH" || ref($probe->{"luma_adjustment"}) ne "HASH");
				   my $luma_adj=$probe->{"luma_adjustment"};
				   my $before_probe_reading=clone_picture($reading);
				   my $before_probe_values=trace_target_values($arrays,$target);
				   trace_109($read_step,"high_end_paired_luma_probe",{
				    label=>$label,
				    phase=>$phase_label||"",
				    index=>defined($phase_index)?$phase_index+0:undef,
				    rgb_move=>$probe->{"rgb_move"},
				    luma_compensation=>$luma_adj->{"delta"}+0,
				    prior_score=>defined($best_score)?$best_score+0:undef,
				    rejected_candidate_score=>defined($candidate_score)?$candidate_score+0:undef,
				    rejected_candidate_delta_e=>defined($de)?$de+0:undef,
				    rejected_candidate_luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef,
				    rejected_candidate_chroma_delta_e=>defined($candidate_chroma)?$candidate_chroma+0:undef,
				    best_chroma_delta_e=>defined($best_chroma)?$best_chroma+0:undef,
				    values_before=>$before_probe_values
				   });
				   $arrays->{$luma_adj->{"setting"}}[$target->{"index"}]=$luma_adj->{"next"};
				   $state->{"phase"}="writing";
				   $state->{"message"}="Trying paired luminance compensation for $label ".describe_adjustments([$luma_adj]);
				   write_state($state);
				   my $write_error;
				   ($picture,$write_error)=set_picture_values($picture,$arrays,$target,$picture_mode,$calibration_mode_active,$state);
				   die $write_error if($write_error);
				   $calibration_mode_active=1;
				   sync_state_picture($state,$picture,$picture_mode);
				   return 0 if(cancelled());
				   $state->{"phase"}="reading";
				   $state->{"message"}="Reading $label paired luminance compensation";
				   write_state($state);
				   ($reading,$read_error,$guarded_target_step_y)=read_step_guarded($config,$read_step,$state,$white_y,$target_gamma,$signal_mode,$target_x,$target_y,$label);
				   die $read_error if($read_error && $read_error ne "cancelled");
				   return 0 if($read_error && $read_error eq "cancelled");
				   $white_y=update_white_reference_for_autocal_step($config,$state,$read_step,$reading,$white_y);
				   refresh_headroom_targets_after_white_reference($state,$read_step,$white_y,$target_x,$target_y,$target_gamma,$signal_mode);
				   $target_step_y=defined($guarded_target_step_y) ? $guarded_target_step_y : effective_target_luminance_for_autocal_reading($white_y,$read_step,$reading,$target_gamma,$signal_mode);
				   annotate_reading_target($reading,$white_y,$target_step_y,$target_x,$target_y);
				   $de=autocal_delta_e_for_step($config,$reading,$read_step,$white_y,$target_x,$target_y,$target_step_y);
				   $lum_pct=luminance_error_percent($reading,$target_step_y);
				   my $paired_score=guarded_autocal_result_score($de,$lum_pct,$read_step,$reading,$white_guard_y);
				   mark_tried_values($tried_ref,$arrays,$target,$de) if(ref($tried_ref) eq "HASH");
				   $state->{"readings"}=merge_reading($state->{"readings"},$reading) if(ref($reading) eq "HASH");
				   $state->{"current_delta_e"}=defined($de) ? $de : undef;
				   $state->{"current_luminance"}=luminance($reading);
				   set_state_target_step_luminance($state,$target_step_y);
				   $state->{"luminance_error_pct"}=defined($lum_pct) ? $lum_pct : undef;
				   my $paired_chroma=autocal_chroma_delta_e_for_step($config,$reading,$read_step,$white_y,$target_x,$target_y);
				   my $not_worse_measurement=autocal_measurement_not_worse_than_best($de,$lum_pct,$best_de,$best_lum_pct);
				   my $previous_best_score=$best_score;
				   my $keep=(defined($de) && $not_worse_measurement && $paired_score + 0.0001 < $best_score) ? 1 : 0;
				   if($keep) {
				    $best_de=$de;
				    $best_lum_pct=$lum_pct;
				    $best_score=$paired_score;
				    $best_arrays=clone_arrays($arrays);
				    $best_reading=clone_picture($reading);
				    $best_read_step=clone_picture($read_step);
				   }
				   trace_109($read_step,$keep ? "high_end_paired_luma_kept" : "high_end_paired_luma_rejected",{
				    label=>$label,
				    phase=>$phase_label||"",
				    index=>defined($phase_index)?$phase_index+0:undef,
				    reading=>trace_reading_summary($reading),
				    previous_reading=>trace_reading_summary($before_probe_reading),
				    luma_compensation=>$luma_adj->{"delta"}+0,
				    prior_score=>defined($candidate_score)?$candidate_score+0:undef,
				    previous_best_score=>defined($previous_best_score)?$previous_best_score+0:undef,
				    best_score=>defined($best_score)?$best_score+0:undef,
				    paired_candidate_score=>$paired_score+0,
				    paired_candidate_delta_e=>defined($de)?$de+0:undef,
				    paired_candidate_luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef,
				    paired_candidate_chroma_delta_e=>defined($paired_chroma)?$paired_chroma+0:undef,
				    previous_candidate_chroma_delta_e=>defined($candidate_chroma)?$candidate_chroma+0:undef,
				    best_chroma_delta_e=>defined($best_chroma)?$best_chroma+0:undef,
				    not_worse_measurement=>$not_worse_measurement?JSON::PP::true:JSON::PP::false,
				    target_values=>trace_target_values($arrays,$target)
				   });
				   return $keep;
				  };
				  my $iteration_limit=iteration_limit_for_step($step,$max_iterations,$config);
				  $iteration_limit=48 if($paired_white_step && !autocal_config_is_touchup($config) && $iteration_limit < 48);
				  for(my $iter=1;$iter<=$iteration_limit;$iter++) {
				   last if(cancelled());
				   my $err=autocal_adjustment_error($reading,$read_step);
				   my $lum_err=luminance_error_ratio($reading,$target_step_y);
						   my $adjustments;
								   if(
								    autocal_step_is_low_shadow($read_step) &&
								    ref($low_shadow_next_adjustments) eq "ARRAY"
								   ) {
								    $adjustments=$low_shadow_next_adjustments;
								    $low_shadow_next_adjustments=undef;
								   }
								   if(
								    !$adjustments &&
								    !autocal_step_is_low_shadow($read_step) &&
								    ref($body_luminance_next_adjustments) eq "ARRAY"
								   ) {
								    $adjustments=$body_luminance_next_adjustments;
								    $body_luminance_next_adjustments=undef;
								   }
								   if(!$adjustments && autocal_step_is_low_shadow($read_step)) {
								    $adjustments=low_shadow_luminance_priority_adjustments($arrays,$target,$lum_err,$de,$stalls,\%tried_values,$read_step,0);
								   }
							   if(!$adjustments && $paired_white_step) {
							    $adjustments=legal_white_pair_wrgb_seed_adjustment($arrays,$target,$de,\%tried_values,$read_step);
							   }
							   if(!$adjustments && $paired_white_step) {
							    my $pair_chroma_mag=chroma_error_magnitude($err);
							    if($pair_chroma_mag < 0.035 || (defined($de) && $de <= ($target_delta+1.0)) || (defined($lum_err) && abs($lum_err*100) > 12)) {
							     $adjustments=legal_white_pair_luminance_priority_adjustments($arrays,$target,$lum_err,$de,$stalls,\%tried_values,$read_step,$pair_lum_pct,0);
							    }
							   }
							   if(!$adjustments) {
							    $adjustments=body_luminance_priority_adjustments($arrays,$target,$lum_err,$de,$stalls,\%tried_values,$read_step);
							   }
							   if(
							    !$adjustments &&
							    autocal_step_is_fast_headroom($read_step) &&
						    ref($headroom_next_adjustments) eq "ARRAY" &&
						    headroom_queued_adjustment_still_best($headroom_next_adjustments,$err,$de,$target_delta,$read_step)
						   ) {
						    $adjustments=$headroom_next_adjustments;
						    $headroom_next_adjustments=undef;
						   } else {
						    $headroom_next_adjustments=undef if(autocal_step_is_fast_headroom($read_step));
						    $adjustments=choose_rgb_response_adjustments($err,$arrays,$target,\%rgb_response_model,\%tried_values,$de,$read_step,$target_delta,$stalls) if(!$adjustments);
						    $adjustments=choose_adjustments($err,$arrays,$target,$de,0.25,$stalls,$lum_err,\%tried_values,$read_step) if(!$adjustments);
						   }
					   if(!$adjustments && stimulus_probe_enabled($config) && !autocal_step_is_peak_headroom($read_step) && !$pair_target_reached_now->()) {
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
					     iteration=>$iter+0,
					     iteration_limit=>$iteration_limit+0,
					     delta_e=>defined($de)?$de+0:undef,
					     luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef,
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
		    iteration=>$iter+0,
		    iteration_limit=>$iteration_limit+0,
		    delta_e=>defined($de)?$de+0:undef,
		    luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef,
		    score=>guarded_autocal_result_score($de,$lum_pct,$read_step,$reading,$white_guard_y)+0,
		    best_delta_e=>defined($best_de)?$best_de+0:undef,
		    best_score=>$best_score+0,
		    rgb_error=>$err,
		    luminance_error_ratio=>defined($lum_err)?$lum_err+0:undef,
		    adjustments=>trace_adjustments_summary($adjustments),
		    values_before=>$before_values,
		    values_after=>trace_target_values($arrays,$target)
		   });
	   $state->{"phase"}="writing";
	   $state->{"message"}="Writing $label ".describe_adjustments($adjustments)." ($iter/$iteration_limit)";
	   $state->{"iteration"}=$iter;
	   write_state($state);
	   my $write_error;
	   ($picture,$write_error)=set_picture_values($picture,$arrays,$target,$picture_mode,$calibration_mode_active,$state);
	   die $write_error if($write_error);
	   $calibration_mode_active=1;
	   sync_state_picture($state,$picture,$picture_mode);
	   last if(cancelled());
	   $state->{"phase"}="reading";
	   $state->{"message"}="Reading $label after adjustment ($iter/$iteration_limit)";
	   write_state($state);
		   ($reading,$read_error,$guarded_target_step_y)=read_step_guarded($config,$read_step,$state,$white_y,$target_gamma,$signal_mode,$target_x,$target_y,$label);
		  die $read_error if($read_error && $read_error ne "cancelled");
		  last if($read_error && $read_error eq "cancelled");
			   $white_y=update_white_reference_for_autocal_step($config,$state,$read_step,$reading,$white_y);
			   refresh_headroom_targets_after_white_reference($state,$read_step,$white_y,$target_x,$target_y,$target_gamma,$signal_mode);
			   $target_step_y=defined($guarded_target_step_y) ? $guarded_target_step_y : effective_target_luminance_for_autocal_reading($white_y,$read_step,$reading,$target_gamma,$signal_mode);
		   annotate_reading_target($reading,$white_y,$target_step_y,$target_x,$target_y);
		   $de=autocal_delta_e_for_step($config,$reading,$read_step,$white_y,$target_x,$target_y,$target_step_y);
	   $state->{"readings"}=merge_reading($state->{"readings"},$reading) if(ref($reading) eq "HASH");
	   $state->{"current_delta_e"}=defined($de) ? $de : undef;
	   $state->{"current_luminance"}=luminance($reading);
	   set_state_target_step_luminance($state,$target_step_y);
			   $lum_pct=luminance_error_percent($reading,$target_step_y);
			   $state->{"luminance_error_pct"}=defined($lum_pct) ? $lum_pct : undef;
				   mark_tried_values(\%tried_values,$arrays,$target,$de);
						   $headroom_next_adjustments=headroom_proportional_adjustment($read_step,$adjustments,$before_adjustment_reading,$reading,$arrays,$target,\%tried_values);
						   my $low_shadow_candidate_next_adjustments=low_shadow_luminance_response_adjustment($read_step,$adjustments,$before_adjustment_reading,$reading,$arrays,$target,\%tried_values,0);
						   my $low_shadow_restore_next_adjustments=low_shadow_luminance_response_adjustment($read_step,$adjustments,$before_adjustment_reading,$reading,$arrays,$target,\%tried_values,1);
						   my $body_candidate_next_adjustments=body_luminance_response_adjustment($read_step,$adjustments,$before_adjustment_reading,$reading,$arrays,$target,\%tried_values,0);
						   my $body_restore_next_adjustments=body_luminance_response_adjustment($read_step,$adjustments,$before_adjustment_reading,$reading,$arrays,$target,\%tried_values,1);
						   my $response_score=reading_change_score($before_adjustment_reading,$reading);
						   my $rgb_response_update=update_rgb_response_model(\%rgb_response_model,$adjustments,$before_adjustment_reading,$reading,$read_step);
						   my $saved_response_model=remember_lg_autocal_26_response_model($config,$state,$read_step,$adjustments,$before_adjustment_reading,$reading,"main_adjustment");
						   $state->{"response_score"}=$response_score;
						   if($paired_white_step) {
						    last if(!$read_legal_white_pair_counterpart->("Balancing 99% and 100% after adjustment") && cancelled());
						    my $pair_switched=$switch_to_worst_pair_step->("Paired result after adjustment");
						    if($pair_switched) {
						     %rgb_response_model=();
						     $headroom_next_adjustments=undef;
						     $body_luminance_next_adjustments=undef;
						    }
						   }
				   my $candidate_score_after=$paired_white_step ? $pair_score_now->() : guarded_autocal_result_score($de,$lum_pct,$read_step,$reading,$white_guard_y);
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
						    rgb_response_model=>$rgb_response_update,
						    saved_response_model=>$saved_response_model,
						    target_values=>trace_target_values($arrays,$target)
						   });
					   if(touchup_delta_skip_reached($config,$de,$target_delta,$read_step,$lum_pct) && (!$paired_white_step || $pair_target_reached_now->())) {
					    my $best_update_reason=$pair_best_update_reason->($candidate_score_after);
					    if(defined($best_update_reason)) {
					     $best_de=$de;
					     $best_lum_pct=$lum_pct;
					     $best_score=$candidate_score_after;
				     $best_arrays=clone_arrays($arrays);
				     $best_reading=clone_picture($reading);
				     $best_read_step=clone_picture($read_step);
				     $store_best_pair->() if($paired_white_step);
				    }
					    $state->{"message"}="$label within touch-up target; closest result kept";
				    write_state($state);
				    last;
				   }
				   my $no_response_threshold=(ref($read_step) eq "HASH" && defined($read_step->{"ire"}) && ($read_step->{"ire"}+0) <= 25) ? 0.012 : 0.006;
			   if(adjustment_total($adjustments) >= 1 && $response_score < $no_response_threshold) {
			    $no_response_stalls++;
			   } else {
			    $no_response_stalls=0;
			   }
				   my $probe_found=0;
						   my $needs_stimulus_probe=0;
						   if(!$pair_target_reached_now->()) {
						    my $near_probe_skip=near_target_for_probe_skip($de,$lum_pct,$target_delta,$read_step);
						    my $keep_tuning_luma=0;
						    if(has_luminance_channel($arrays,$target) && defined($lum_pct)) {
						     my $luma_gate=headroom_luminance_control_gate_percent($read_step,0.65);
						     $keep_tuning_luma=1 if(abs($lum_pct) > $luma_gate && !ddc_target_near_limit($arrays,$target,42));
						    }
						    if(!$keep_tuning_luma) {
							     if(!autocal_step_is_peak_headroom($read_step)) {
							      $needs_stimulus_probe=1 if(!$near_probe_skip && ddc_target_near_limit($arrays,$target,45));
							      $needs_stimulus_probe=1 if(!$near_probe_skip && $no_response_stalls >= 2);
							      $needs_stimulus_probe=1 if(!$near_probe_skip && $iter >= 4 && ddc_target_max_delta($arrays,$slot_default_arrays,$target) >= 12);
							      $needs_stimulus_probe=1 if(!$near_probe_skip && $iter >= 6 && far_from_target($de,$lum_pct,$target_delta,$read_step));
							     }
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
					   if($probe_found) {
					    # The probe already reset the baseline to the responsive patch stimulus.
					    $iter-- if($iter > 0);
					   } else {
					    my ($chroma_keep,$candidate_chroma,$best_chroma)=$candidate_chroma_keep->();
					    my $delta_keep=$candidate_delta_keep->();
						    my $not_worse_measurement=autocal_measurement_not_worse_than_best($de,$lum_pct,$best_de,$best_lum_pct);
							    my $best_update_reason=$paired_white_step ? $pair_best_update_reason->($candidate_score_after) : undef;
							    my $keep_candidate=$paired_white_step
							     ? defined($best_update_reason)
							     : (defined($de) && $not_worse_measurement && ($candidate_score_after + 0.0001 < $best_score || $chroma_keep || $delta_keep));
					    if($keep_candidate) {
				    $best_de=$de;
				    $best_lum_pct=$lum_pct;
				    $best_score=$candidate_score_after;
					    $best_arrays=clone_arrays($arrays);
						    $best_reading=clone_picture($reading);
						    $best_read_step=clone_picture($read_step);
						    $store_best_pair->() if($paired_white_step);
						    $low_shadow_next_adjustments=$low_shadow_candidate_next_adjustments if(ref($low_shadow_candidate_next_adjustments) eq "ARRAY");
						    $body_luminance_next_adjustments=$body_candidate_next_adjustments if(ref($body_candidate_next_adjustments) eq "ARRAY");
						    $stalls=0;
					    trace_109($read_step,"best_updated",{
					     label=>$label,
					     iteration=>$iter+0,
					     best_delta_e=>defined($best_de)?$best_de+0:undef,
					     best_luminance_error_pct=>defined($best_lum_pct)?$best_lum_pct+0:undef,
						     best_score=>$best_score+0,
						     reason=>defined($best_update_reason)?$best_update_reason:($chroma_keep?"chroma_keep":($delta_keep?"delta_keep":"score_improved")),
					     chroma_keep=>$chroma_keep?JSON::PP::true:JSON::PP::false,
				     delta_keep=>$delta_keep?JSON::PP::true:JSON::PP::false,
					     not_worse_measurement=>$not_worse_measurement?JSON::PP::true:JSON::PP::false,
					     candidate_chroma_delta_e=>defined($candidate_chroma)?$candidate_chroma+0:undef,
					     previous_chroma_delta_e=>defined($best_chroma)?$best_chroma+0:undef,
					     best_values=>trace_target_values($best_arrays,$target)
					    });
			   } else {
				    $stalls++;
				    my $candidate_score=$candidate_score_after;
				    my ($chroma_keep,$candidate_chroma,$best_chroma)=$candidate_chroma_keep->();
				    my $delta_keep=$candidate_delta_keep->();
				    my $luma_anchor_working=headroom_luminance_anchor_working_state($read_step,$lum_pct,$best_lum_pct,$de,$best_de);
				    $luma_anchor_working=0 if(autocal_step_is_fast_headroom($read_step) && !autocal_step_is_peak_headroom($read_step));
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
			     chroma_keep=>$chroma_keep?JSON::PP::true:JSON::PP::false,
			     delta_keep=>$delta_keep?JSON::PP::true:JSON::PP::false,
				     candidate_chroma_delta_e=>defined($candidate_chroma)?$candidate_chroma+0:undef,
				     best_chroma_delta_e=>defined($best_chroma)?$best_chroma+0:undef,
				     luma_anchor_working=>$luma_anchor_working?JSON::PP::true:JSON::PP::false,
				     candidate_values=>trace_target_values($arrays,$target),
				     best_values=>trace_target_values($best_arrays,$target)
				    });
					    my $paired_luma_kept=$try_high_end_paired_luma_probe->($adjustments,$candidate_score,$candidate_chroma,$best_chroma,\%tried_values,"iteration",$iter);
					    if($paired_luma_kept) {
					     $stalls=0;
					    } elsif($luma_anchor_working) {
					     $stalls=0;
					     trace_109($read_step,"keep_luminance_anchor_working_state",{
					      label=>$label,
					      iteration=>$iter+0,
					      candidate_delta_e=>defined($de)?$de+0:undef,
					      candidate_luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef,
					      best_delta_e=>defined($best_de)?$best_de+0:undef,
					      best_luminance_error_pct=>defined($best_lum_pct)?$best_lum_pct+0:undef,
					      working_values=>trace_target_values($arrays,$target)
					     });
						    } else {
						     $low_shadow_next_adjustments=$low_shadow_restore_next_adjustments if(ref($low_shadow_restore_next_adjustments) eq "ARRAY");
						     $body_luminance_next_adjustments=$body_restore_next_adjustments if(ref($body_restore_next_adjustments) eq "ARRAY");
						     $restore_best_branch->("Backtracking to best $label result after rejected adjustment");
						    }
			   }
		   }
		   $state->{"best_delta_e"}=$best_de;
		   $state->{"best_score"}=$best_score;
		   write_state($state);
			   last if($pair_target_reached_now->());
			   if($paired_white_step && legal_white_pair_close_enough_stalled($best_de,$best_lum_pct,$best_read_step,$best_reading,$best_pair_de,$best_pair_lum_pct,$best_pair_step,$best_pair_reading,$target_delta,$white_guard_y,$stalls,$iter)) {
		    $state->{"message"}="$label and 100% legal white close pair kept after stalled fine-tune";
		    trace_109($read_step,"legal_white_pair_close_enough_stalled",{
		     label=>$label,
		     iteration=>$iter+0,
		     stalls=>$stalls+0,
		     best_delta_e=>defined($best_de)?$best_de+0:undef,
		     best_luminance_error_pct=>defined($best_lum_pct)?$best_lum_pct+0:undef,
		     paired_delta_e=>defined($best_pair_de)?$best_pair_de+0:undef,
		     paired_luminance_error_pct=>defined($best_pair_lum_pct)?$best_pair_lum_pct+0:undef,
		     best_score=>$best_score+0,
		     best_values=>trace_target_values($best_arrays,$target)
		    });
		    write_state($state);
		    last;
		   }
			   my $no_response_stall_limit=$paired_white_step ? 6 : 2;
			   my $no_response_iter_floor=$paired_white_step ? 12 : 4;
			   if(!$probe_found && $no_response_stalls >= $no_response_stall_limit && $iter >= $no_response_iter_floor && !stimulus_scan_steps($config,$read_step,\%stimulus_probe_tried)) {
		    $state->{"message"}="$label uncorrectable within stimulus window; closest result kept";
		    write_state($state);
		    last;
		   }
			   if(!$paired_white_step && !white_luminance_guard_failed($read_step,$best_reading,$white_guard_y) && close_enough_stalled($best_de,$best_lum_pct,$target_delta,$read_step,$stalls,$iter)) {
		    $state->{"message"}="$label close result kept after stalled fine-tune";
		    write_state($state);
		    last;
		   }
		   $last_de=defined($de) ? $de : $last_de;
		  }
			  my $restore_best_if_better=sub {
			   my ($reason)=@_;
			   my $current_score=$paired_white_step ? $pair_score_now->() : guarded_autocal_result_score($de,$lum_pct,$read_step,$reading,$white_guard_y);
			   my $best_score_better=$best_score + 0.0001 < $current_score ? 1 : 0;
			   my $current_measurement_worse=autocal_measurement_not_worse_than_best($de,$lum_pct,$best_de,$best_lum_pct) ? 0 : 1;
			   if($paired_white_step && ref($best_pair_reading) eq "HASH") {
			    $current_measurement_worse=1 if(!autocal_measurement_not_worse_than_best($pair_de,$pair_lum_pct,$best_pair_de,$best_pair_lum_pct));
			   }
			   return 0 if(cancelled() || ref($best_arrays) ne "HASH" || !defined($de) || (!$best_score_better && !$current_measurement_worse));
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
			    current_measurement_worse=>$current_measurement_worse?JSON::PP::true:JSON::PP::false,
			    best_values=>trace_target_values($best_arrays,$target)
			   });
			   $arrays=clone_arrays($best_arrays);
		   $state->{"phase"}="restoring";
		   $state->{"message"}=$reason||"Restoring closest $label result";
		   write_state($state);
		   my $write_error;
			   ($picture,$write_error)=set_picture_values($picture,$arrays,$target,$picture_mode,$calibration_mode_active,$state);
		   die $write_error if($write_error);
		   $calibration_mode_active=1;
		   sync_state_picture($state,$picture,$picture_mode);
		   $read_step=clone_picture($best_read_step) if(ref($best_read_step) eq "HASH");
		   $reading=clone_picture($best_reading) if(ref($best_reading) eq "HASH");
		   if($paired_white_step && ref($best_pair_step) eq "HASH" && ref($best_pair_reading) eq "HASH") {
		    $pair_step=clone_picture($best_pair_step);
		    $pair_reading=clone_picture($best_pair_reading);
		    $pair_de=$best_pair_de;
		    $pair_lum_pct=$best_pair_lum_pct;
		    $pair_target_step_y=$best_pair_target_step_y;
		    $state->{"readings"}=merge_reading($state->{"readings"},$pair_reading);
			   }
			   $white_y=update_white_reference_for_autocal_step($config,$state,$read_step,$reading,$white_y);
			   refresh_headroom_targets_after_white_reference($state,$read_step,$white_y,$target_x,$target_y,$target_gamma,$signal_mode);
			   $target_step_y=effective_target_luminance_for_autocal_reading($white_y,$read_step,$reading,$target_gamma,$signal_mode);
		   $de=$best_de;
		   $lum_pct=$best_lum_pct;
		   $state->{"readings"}=merge_reading($state->{"readings"},$best_reading) if(ref($best_reading) eq "HASH");
		   return 1;
		  };
			  $restore_best_if_better->($paired_white_step ? "Restoring closest 99/100 paired result" : "Restoring closest $label result");
		  $run_body_final_micro_once->("Final micro-balancing $label before moving on");
			  my $paired_white_close_enough=$paired_white_step ? legal_white_pair_close_enough($best_de,$best_lum_pct,$best_read_step,$best_reading,$best_pair_de,$best_pair_lum_pct,$best_pair_step,$best_pair_reading,$target_delta,$white_guard_y) : 0;
			  if($paired_white_close_enough) {
			   $state->{"message"}="$label and 100% legal white close pair kept";
			   trace_109($read_step,"legal_white_pair_close_enough",{
			    label=>$label,
			    best_delta_e=>defined($best_de)?$best_de+0:undef,
			    best_luminance_error_pct=>defined($best_lum_pct)?$best_lum_pct+0:undef,
			    paired_delta_e=>defined($best_pair_de)?$best_pair_de+0:undef,
			    paired_luminance_error_pct=>defined($best_pair_lum_pct)?$best_pair_lum_pct+0:undef,
			    best_score=>$best_score+0,
			    best_values=>trace_target_values($best_arrays,$target)
			   });
			   write_state($state);
			  }
			  if(!cancelled() && autocal_step_allows_final_fine_tune($read_step,$best_de,$target_delta) && !low_shadow_good_enough($read_step,$best_de,$best_lum_pct,$target_delta) && ref($best_arrays) eq "HASH" && ref($best_reading) eq "HASH" && !$pair_target_reached_now->() && !$paired_white_close_enough) {
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
			   my $polish_limit=headroom_polish_limit_for_step($read_step,$config);
			   $polish_limit=48 if(!defined($polish_limit));
			   my $shadow_polish_limit=low_shadow_polish_limit_for_step($read_step,$config);
			   $polish_limit=$shadow_polish_limit if(defined($shadow_polish_limit));
			   my $precision_needed=autocal_itp_precision_polish_needed($best_de,$target_delta,$read_step);
				   my $precision_polish_limit=config_positive_int($config,"precision_polish_iterations",72,0,72);
				   if($precision_needed) {
				    if(ref($config) eq "HASH" && defined($config->{"precision_polish_iterations"})) {
				     $polish_limit=$precision_polish_limit;
				    } elsif($polish_limit < $precision_polish_limit) {
				     $polish_limit=$precision_polish_limit;
				    }
				   }
			   if(!$precision_needed && ref($config) eq "HASH" && defined($config->{"max_polish_iterations"})) {
			    my $configured_polish=config_positive_int($config,"max_polish_iterations",$polish_limit,0,72);
			    $polish_limit=$configured_polish if($configured_polish < $polish_limit);
			   }
					   if($paired_white_step && !autocal_config_is_touchup($config)) {
					    my $paired_polish_limit=config_positive_int($config,"paired_white_polish_iterations",8,1,28);
					    $polish_limit=$paired_polish_limit if($polish_limit > $paired_polish_limit);
					   }
			   my $polish_stalls=0;
			   for(my $polish=1;$polish<=$polish_limit;$polish++) {
			    last if(cancelled());
			    last if($pair_target_reached_now->());
				    my $err=autocal_adjustment_error($reading,$read_step);
				    my $lum_err=luminance_error_ratio($reading,$target_step_y);
				    my $micro_step=(defined($best_de) && $best_de <= ($target_delta+0.15)) ? 0.20 : ((defined($best_de) && $best_de > ($target_delta*2)) ? 0.5 : 0.20);
				    if($paired_white_step) {
				     $micro_step=(defined($best_de) && $best_de > ($target_delta+0.75)) ? 0.25 : 0.10;
				    } elsif(autocal_itp_precision_polish_needed($best_de,$target_delta,$read_step)) {
				     $micro_step=(defined($best_de) && $best_de <= ($target_delta+0.15)) ? 0.20 : ((defined($best_de) && $best_de > ($target_delta*1.8)) ? 1.0 : 0.5);
				    }
					    my $adjustments;
					    if($paired_white_step) {
					     my $pair_chroma_mag=chroma_error_magnitude($err);
					     if($pair_chroma_mag < 0.025 || (defined($best_de) && $best_de <= ($target_delta+0.75)) || (defined($lum_err) && abs($lum_err*100) > 12)) {
					      $adjustments=legal_white_pair_luminance_priority_adjustments($arrays,$target,$lum_err,$best_de,$polish_stalls,\%polish_tried,$read_step,$pair_lum_pct,1);
					     }
					    }
					    $adjustments=choose_micro_adjustments($err,$arrays,$target,$lum_err,\%polish_tried,$micro_step,$best_de,$polish_stalls,$read_step,$target_delta) if(!$adjustments);
			    if(!$adjustments) {
			     trace_109($read_step,"no_fine_tune_adjustment_chosen",{
			      label=>$label,
			      polish=>$polish+0,
			      polish_limit=>$polish_limit+0,
			      delta_e=>defined($de)?$de+0:undef,
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
			     polish=>$polish+0,
			     polish_limit=>$polish_limit+0,
			     delta_e=>defined($de)?$de+0:undef,
			     luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef,
			     best_delta_e=>defined($best_de)?$best_de+0:undef,
			     best_score=>$best_score+0,
			     rgb_error=>$err,
			     luminance_error_ratio=>defined($lum_err)?$lum_err+0:undef,
			     micro_step=>$micro_step+0,
			     adjustments=>trace_adjustments_summary($adjustments),
			     values_before=>$before_values,
			     values_after=>trace_target_values($arrays,$target)
			    });
		    $state->{"phase"}="writing";
		    $state->{"message"}="Fine tuning $label ".describe_adjustments($adjustments)." ($polish/$polish_limit)";
		    write_state($state);
		    my $write_error;
			    ($picture,$write_error)=set_picture_values($picture,$arrays,$target,$picture_mode,$calibration_mode_active,$state);
		    die $write_error if($write_error);
		    $calibration_mode_active=1;
		    sync_state_picture($state,$picture,$picture_mode);
		    last if(cancelled());
		    $state->{"phase"}="reading";
		    $state->{"message"}="Reading $label fine tune ($polish/$polish_limit)";
		    write_state($state);
		    ($reading,$read_error,$guarded_target_step_y)=read_step_guarded($config,$read_step,$state,$white_y,$target_gamma,$signal_mode,$target_x,$target_y,$label);
			    die $read_error if($read_error && $read_error ne "cancelled");
			    last if($read_error && $read_error eq "cancelled");
			    $white_y=update_white_reference_for_autocal_step($config,$state,$read_step,$reading,$white_y);
			    refresh_headroom_targets_after_white_reference($state,$read_step,$white_y,$target_x,$target_y,$target_gamma,$signal_mode);
			    $target_step_y=defined($guarded_target_step_y) ? $guarded_target_step_y : effective_target_luminance_for_autocal_reading($white_y,$read_step,$reading,$target_gamma,$signal_mode);
		    annotate_reading_target($reading,$white_y,$target_step_y,$target_x,$target_y);
		    $de=autocal_delta_e_for_step($config,$reading,$read_step,$white_y,$target_x,$target_y,$target_step_y);
		    $lum_pct=luminance_error_percent($reading,$target_step_y);
		    mark_tried_values(\%polish_tried,$arrays,$target,$de);
		    $state->{"readings"}=merge_reading($state->{"readings"},$reading) if(ref($reading) eq "HASH");
		    $state->{"current_delta_e"}=defined($de) ? $de : undef;
		    $state->{"current_luminance"}=luminance($reading);
		    set_state_target_step_luminance($state,$target_step_y);
		    $state->{"luminance_error_pct"}=defined($lum_pct) ? $lum_pct : undef;
				    if($paired_white_step) {
				     last if(!$read_legal_white_pair_counterpart->("Balancing 99% and 100% fine tune") && cancelled());
				     $switch_to_worst_pair_step->("Paired fine-tune result");
				    }
				    my $candidate_score=$paired_white_step ? $pair_score_now->() : guarded_autocal_result_score($de,$lum_pct,$read_step,$reading,$white_guard_y);
				    my $saved_response_model=remember_lg_autocal_26_response_model($config,$state,$read_step,$adjustments,$before_polish,$reading,"fine_tune");
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
				     saved_response_model=>$saved_response_model,
				     target_values=>trace_target_values($arrays,$target)
				    });
			    my ($chroma_keep,$candidate_chroma,$best_chroma)=$candidate_chroma_keep->();
			    my $delta_keep=$candidate_delta_keep->();
				    my $not_worse_measurement=autocal_measurement_not_worse_than_best($de,$lum_pct,$best_de,$best_lum_pct);
					    my $best_update_reason=$paired_white_step ? $pair_best_update_reason->($candidate_score) : undef;
					    my $keep_candidate=$paired_white_step
					     ? defined($best_update_reason)
					     : (defined($de) && $not_worse_measurement && ($candidate_score + 0.0001 < $best_score || $chroma_keep || $delta_keep));
			    if($keep_candidate) {
			     $best_de=$de;
		     $best_lum_pct=$lum_pct;
			     $best_score=$candidate_score;
			     $best_arrays=clone_arrays($arrays);
			     $best_reading=clone_picture($reading);
			     $best_read_step=clone_picture($read_step);
			     $store_best_pair->() if($paired_white_step);
			     $polish_stalls=0;
			     trace_109($read_step,"fine_tune_best_updated",{
			      label=>$label,
			      polish=>$polish+0,
			      best_delta_e=>defined($best_de)?$best_de+0:undef,
			      best_luminance_error_pct=>defined($best_lum_pct)?$best_lum_pct+0:undef,
				      best_score=>$best_score+0,
				      reason=>defined($best_update_reason)?$best_update_reason:($chroma_keep?"chroma_keep":($delta_keep?"delta_keep":"score_improved")),
					      chroma_keep=>$chroma_keep?JSON::PP::true:JSON::PP::false,
				      delta_keep=>$delta_keep?JSON::PP::true:JSON::PP::false,
				      not_worse_measurement=>$not_worse_measurement?JSON::PP::true:JSON::PP::false,
				      candidate_chroma_delta_e=>defined($candidate_chroma)?$candidate_chroma+0:undef,
			      previous_chroma_delta_e=>defined($best_chroma)?$best_chroma+0:undef,
			      best_values=>trace_target_values($best_arrays,$target)
			     });
				    } else {
				     $polish_stalls++;
				     my $luma_anchor_working=headroom_luminance_anchor_working_state($read_step,$lum_pct,$best_lum_pct,$de,$best_de);
				     $luma_anchor_working=0 if(autocal_step_is_fast_headroom($read_step) && !autocal_step_is_peak_headroom($read_step));
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
				      best_values=>trace_target_values($best_arrays,$target),
				      luma_anchor_working=>$luma_anchor_working?JSON::PP::true:JSON::PP::false
				     });
						     my $paired_luma_kept=$try_high_end_paired_luma_probe->($adjustments,$candidate_score,$candidate_chroma,$best_chroma,\%polish_tried,"fine_tune",$polish);
						     if($paired_luma_kept) {
						      $polish_stalls=0;
						     } elsif($luma_anchor_working) {
						      $polish_stalls=0;
						      trace_109($read_step,"keep_luminance_anchor_working_state",{
						       label=>$label,
						       polish=>$polish+0,
						       candidate_delta_e=>defined($de)?$de+0:undef,
						       candidate_luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef,
						       best_delta_e=>defined($best_de)?$best_de+0:undef,
						       best_luminance_error_pct=>defined($best_lum_pct)?$best_lum_pct+0:undef,
						       working_values=>trace_target_values($arrays,$target)
						      });
						     } else {
						      $restore_best_branch->("Backtracking $label fine tune after rejected adjustment");
						     }
		     if($paired_white_step && legal_white_pair_close_enough_stalled($best_de,$best_lum_pct,$best_read_step,$best_reading,$best_pair_de,$best_pair_lum_pct,$best_pair_step,$best_pair_reading,$target_delta,$white_guard_y,$polish_stalls,$polish)) {
		      $state->{"message"}="$label and 100% legal white close pair kept after stalled polish";
		      trace_109($read_step,"legal_white_pair_close_enough_stalled",{
		       label=>$label,
		       polish=>$polish+0,
		       polish_stalls=>$polish_stalls+0,
		       best_delta_e=>defined($best_de)?$best_de+0:undef,
		       best_luminance_error_pct=>defined($best_lum_pct)?$best_lum_pct+0:undef,
		       paired_delta_e=>defined($best_pair_de)?$best_pair_de+0:undef,
		       paired_luminance_error_pct=>defined($best_pair_lum_pct)?$best_pair_lum_pct+0:undef,
		       best_score=>$best_score+0,
		       best_values=>trace_target_values($best_arrays,$target)
		      });
		      write_state($state);
		      last;
		     }
		     my $precision_stall_limit=$paired_white_step ? legal_white_pair_precision_stall_limit($best_de,$best_pair_de,$target_delta) : autocal_itp_precision_stall_limit($best_de,$target_delta,$read_step);
		     last if($polish_stalls >= $precision_stall_limit);
		    }
		    $state->{"best_delta_e"}=$best_de;
		    $state->{"best_score"}=$best_score;
		    write_state($state);
		   }
			   $restore_best_if_better->($paired_white_step ? "Restoring closest 99/100 paired result after fine tune" : "Restoring closest $label result after fine tune");
			  }
				  $restore_best_branch->($paired_white_step ? "Keeping best 99/100 paired result" : "Keeping best $label result") if(!cancelled() && ref($best_arrays) eq "HASH" && ref($best_reading) eq "HASH");
					  if($paired_white_step) {
					   if(ref($best_pair_reading) eq "HASH") {
					    $state->{"readings"}=merge_reading($state->{"readings"},$best_pair_reading);
					    if(ref($best_pair_step) eq "HASH") {
						     $white_y=update_white_reference_for_autocal_step($config,$state,$best_pair_step,$best_pair_reading,$white_y);
					     refresh_headroom_targets_after_white_reference($state,$best_pair_step,$white_y,$target_x,$target_y,$target_gamma,$signal_mode);
					    }
					   }
					   set_state_white_reference($state,$white_y);
					   set_state_target_step_luminance($state,$target_step_y);
					  } elsif(autocal_step_is_white($read_step)) {
					   $white_y=update_white_reference_for_autocal_step($config,$state,$read_step,$best_reading,$white_y);
					   refresh_headroom_targets_after_white_reference($state,$read_step,$white_y,$target_x,$target_y,$target_gamma,$signal_mode);
					   set_state_white_reference($state,$white_y);
				   $best_lum_pct=undef;
				   set_state_target_step_luminance($state,undef);
				  } elsif(autocal_step_is_peak_headroom($read_step)) {
				   my $peak_target_y=effective_target_luminance_for_autocal_reading($white_y,$read_step,$best_reading,$target_gamma,$signal_mode);
				   apply_peak_headroom_reference($state,$read_step,$best_reading,\$white_y,$target_gamma,$signal_mode,$target_x,$target_y);
				   $best_lum_pct=luminance_error_percent($best_reading,$peak_target_y);
				   set_state_target_step_luminance($state,$peak_target_y);
				  }
				  if(ref($best_reading) eq "HASH") {
				   $state->{"readings"}=merge_reading($state->{"readings"},$best_reading);
				   $state->{"current_luminance"}=luminance($best_reading);
				  }
				  $state->{"current_delta_e"}=$best_de;
		  $state->{"best_delta_e"}=$best_de;
		  $state->{"luminance_error_pct"}=defined($best_lum_pct) ? $best_lum_pct : undef;
				  my $final_reached=$pair_target_reached_now->();
				  $state->{"message"}=$paired_white_step
				   ? ($final_reached ? "$label and 100% legal white reached target" : "$label paired closest result kept")
				   : ($final_reached ? "$label reached target" : "$label closest result kept");
				  trace_109($read_step,"final_step_result",{
				   label=>$label,
				   reached_target=>$final_reached?JSON::PP::true:JSON::PP::false,
				   best_delta_e=>defined($best_de)?$best_de+0:undef,
				   best_luminance_error_pct=>defined($best_lum_pct)?$best_lum_pct+0:undef,
				   paired_delta_e=>defined($best_pair_de)?$best_pair_de+0:undef,
				   paired_luminance_error_pct=>defined($best_pair_lum_pct)?$best_pair_lum_pct+0:undef,
				   best_score=>$best_score+0,
				   best_reading=>trace_reading_summary($best_reading),
				   paired_reading=>trace_reading_summary($best_pair_reading),
				   final_values=>trace_target_values($best_arrays,$target)
				  });
				  trace_drift_matrix_final_kept(
				   $config,$state,$read_step,$picture_mode,$target_gamma,$target_step_y,
				   $best_de,$best_lum_pct,$best_reading,$best_arrays,$target
				  );
				  remember_lg_autocal_26_best_known(
				   $config,$state,$read_step,$best_reading,$best_de,$best_lum_pct,
				   $target_step_y,$best_arrays,$target,"main_final_step_result"
				  );
			  $finalize_calibrated_26pt_slot->($target,$read_step,$label);
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
			   my $verify_de=autocal_delta_e_for_step($config,$verify_reading,$verify_step,$white_y,$target_x,$target_y,$verify_target_y);
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
						  if(defined($white_y) && $white_y > 0) {
						   $state->{"committed_polish_white_y"}=$white_y+0;
						   $state->{"committed_polish_reference_locked"}=JSON::PP::true;
						   write_state($state);
						  }
						  if(ref($config) eq "HASH" && $config->{"lg_autocal_26"}) {
						   my $propagated_slots=refresh_propagated_uncalibrated_26pt_slots($config,$arrays,\@calibrated_ddc_slots);
						   if($propagated_slots) {
						    $state->{"propagated_26pt_slots"}=$propagated_slots+0;
						    write_state($state);
						   }
						  }
						  ($picture,$commit_error,$commit_ended_calibration)=commit_final_1d_lut($state,$picture,$arrays,$picture_mode,\@ordered,$calibration_mode_active);
						  die $commit_error if($commit_error);
						  $calibration_mode_active=0 if($commit_ended_calibration);
						  log_line("Final 1D LUT commit result: ended_calibration=".($commit_ended_calibration?1:0).", uploaded=".(($state->{"final_1d_lut_uploaded"})?1:0).", verified=".(($state->{"final_1d_lut_upload_verified"})?1:0));
						  if(($commit_ended_calibration || $state->{"final_1d_lut_uploaded"}) && ref($config) eq "HASH" && $config->{"lg_autocal_26"} && !cancelled()) {
						   if(post_commit_polish_enabled($config)) {
						    my $polish_error=undef;
						    ($picture,$polish_error)=committed_state_polish(
						     $config,
						     $state,
						     $picture,
						     $arrays,
						     $active_picture_mode_for_cleanup || $picture_mode,
						     $steps,
						     $target_x,
						     $target_y,
						     $target_gamma,
						     $signal_mode,
						     $target_delta,
						     \@ordered,
						     \@calibrated_ddc_slots
						    );
					    die $polish_error if($polish_error && $polish_error ne "cancelled");
					   } else {
					    park_black_for_settle($config,$state,"Settling post-CAL_END committed state before completion");
					   }
					  }
					 }
			 if(cancelled()) {
	  $state->{"status"}="cancelled";
	  $state->{"current_name"}="Auto Cal cancelled";
	  $state->{"message"}="Auto Cal stopped";
	 } else {
	 $state->{"status"}="complete";
	 $state->{"current_name"}="Auto Cal complete";
	 $state->{"message"}="Auto Cal complete";
	 $state->{"completed_at"}=int(time()*1000);
	 $state->{"elapsed_ms"}=$state->{"completed_at"}-(($state->{"started_at"}||$state->{"completed_at"})+0);
	 $state->{"elapsed_ms"}=0 if($state->{"elapsed_ms"}<0);
	 }
	 write_state($state);
			 if(ref($config) eq "HASH" && $config->{"lg_autocal_26"}) {
			  # Some LG DDC write paths can leave the TV's calibration-mode
			  # flag active even after the worker state believes CAL_END ran.
			  # Write the terminal state first so a final cleanup hiccup cannot
			  # strand a successful verified LUT upload as "running".
			  end_calibration_mode($active_picture_mode_for_cleanup || $picture_mode);
			  $calibration_mode_active=0;
			  set_state_calibration_mode($state,0,"");
			 }
	 if($calibration_mode_active) {
	  end_calibration_mode($active_picture_mode_for_cleanup);
	  $calibration_mode_active=0;
	  set_state_calibration_mode($state,0,"");
	 }
	 write_state($state);
	 autocal_completion_pattern_cleanup($config,$state) if(!cancelled());
  1;
} or do {
 my $err=$@ || "Auto Cal failed";
 $err=~s/[\r\n]+/ /g;
 if($calibration_mode_active) {
  end_calibration_mode($active_picture_mode_for_cleanup);
  $calibration_mode_active=0;
  set_state_calibration_mode($state,0,"");
 }
 $state->{"status"}=cancelled() ? "cancelled" : "error";
 $state->{"current_name"}=cancelled() ? "Auto Cal cancelled" : "Auto Cal error";
 $state->{"message"}=cancelled() ? "Auto Cal stopped" : $err;
 write_state($state);
};

exit 0;
