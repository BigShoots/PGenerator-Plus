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
our $LG_AUTOCAL_DDC_LAYOUT = "sdr26";
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
  foreach my $key (qw(channel setting current next delta damped micro sweep neutral_luminance paired_luminance high_end_paired_luma near_white_95_luma committed_polish_near_white_95_luma headroom_chroma_luma headroom_105_luma_priority headroom_105_near_y_cleanup headroom_105_luma_coupled_rgb headroom_105_main_polish_refine headroom_105_response_scaled low_shadow_luminance_response_scaled low_shadow_chroma_luma response_multiplier hdr20_body_balanced_chroma_luma cap_reason remaining_error headroom_105_all_down_luma headroom_105_floor_luma_coupled response_probe response_model learned_response_model learned_target_move target_move_reason activation_reason adaptive_luminance insufficient_luminance_response headroom_luminance headroom_105_body_refinement slope ddc_per_error x_delta x_per_ddc y_delta y_per_ddc Y_delta Y_per_ddc luminance_delta luminance_per_ddc predicted_error previous_delta previous_before_error previous_after_error peak_match_low peak_wrgb_seed headroom_105_seed headroom_105_seed_luma_refine_cap headroom_105_near_target_luma_cap legal_white_pair_seed seeded_move_damping full_ddc_spine_anchor full_ddc_spine_anchor_revisit anchor_dominant_chroma anchor_luma_aligned anchor_paired_luminance anchor_luminance_only anchor_move_cap frozen_channel error_gap body_final_micro body_luminance_priority full_ddc_spine_seeded_body_luminance_priority low_shadow_luminance post_commit_low_shadow capped_post_commit_low_shadow post_cal_one_shot post_cal_luma_cap post_cal_response_table smoothed_response_model smoothed_neighbors exact_samples source samples remaining_budget_pct)) {
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

sub ddc_layout_for_signal_mode {
 my ($signal_mode)=@_;
 $signal_mode=lc($signal_mode||"sdr");
 return "hdr20" if($signal_mode eq "hdr10");
 return "sdr26";
}

sub ddc_slots_for_layout {
 my ($layout)=@_;
 $layout=lc($layout||$LG_AUTOCAL_DDC_LAYOUT||"sdr26");
 return (1.37,1.83,2.74,4.11,5.02,6.85,10.05,15.07,20.09,25.11,30.14,40.18,50.23,59.82,69.86,79.91,84.93,89.95,94.98,100) if($layout eq "hdr20");
 return (2.3,3,4,5,7,10,15,20,25,30,35,40,45,50,55,60,65,70,75,80,85,90,95,99,105,109);
}

sub hdr20_effective_ddc_array_ire {
 my ($ire)=@_;
 return undef if(!defined($ire));
 my $value=$ire+0;
 return 84.93 if(abs($value-79.91) < 0.001);
 return 89.95 if(abs($value-84.93) < 0.001);
 return 94.98 if(abs($value-89.95) < 0.001);
 return 100 if(abs($value-94.98) < 0.001);
 return $value;
}

sub hdr20_shared_top_white_pair_target {
 my ($target)=@_;
 return 0 if(ref($target) ne "HASH");
 my $layout=lc($target->{"ddc_layout"} || $LG_AUTOCAL_DDC_LAYOUT || "");
 return 0 if($layout ne "hdr20");
 return 0 if(!defined($target->{"ire"}) || !defined($target->{"array_ire"}));
 return (abs(($target->{"ire"}+0)-94.98) < 0.02 && abs(($target->{"array_ire"}+0)-100) < 0.02) ? 1 : 0;
}

sub hdr20_shared_top_white_pair_step {
 my ($target,$step)=@_;
 return 0 if(!hdr20_shared_top_white_pair_target($target));
 return 0 if(ref($step) ne "HASH" || !defined($step->{"ire"}));
 my $layout=lc($step->{"ddc_layout"} || $LG_AUTOCAL_DDC_LAYOUT || "");
 return 0 if($layout ne "hdr20");
 return abs(($step->{"ire"}+0)-94.98) < 0.02 ? 1 : 0;
}

sub ddc_slots {
 return ddc_slots_for_layout($LG_AUTOCAL_DDC_LAYOUT);
}

sub ddc_slot_count {
 my @slots=ddc_slots();
 return scalar(@slots);
}

sub ddc_target_for_step {
 my ($step)=@_;
 return undef if(ref($step) ne "HASH");
 if(($step->{"autocal_reference_only"} || $step->{"autocal_read_only"}) && !defined($step->{"ddc_target_ire"}) && !defined($step->{"ddc_array_ire"})) {
  return undef;
 }
 my $ire=defined($step->{"ddc_target_ire"}) ? $step->{"ddc_target_ire"} : $step->{"ire"};
 return undef if(!defined($ire));
 my $layout=$step->{"ddc_layout"} || $LG_AUTOCAL_DDC_LAYOUT;
 my $array_ire=defined($step->{"ddc_array_ire"}) ? $step->{"ddc_array_ire"} : $ire;
 if(lc($layout||"") eq "hdr20" && abs(($array_ire+0)-($ire+0)) < 0.001) {
  my $effective=hdr20_effective_ddc_array_ire($ire);
  $array_ire=$effective if(defined($effective));
 }
 my @slots=ddc_slots_for_layout($layout);
 for(my $i=0;$i<@slots;$i++) {
  my $label=$step->{"autocal_target_label"} || format_percent($ire)."%";
  return { index=>$i, ire=>format_percent($ire), array_ire=>format_percent($slots[$i]), label=>$label }
   if(abs(($array_ire+0)-$slots[$i]) < 0.001);
 }
 return undef;
}

sub autocal_skip_duplicate_ddc_slot {
 my ($step)=@_;
 return 0;
}

sub lg_autocal_26_full_ddc_spine_enabled {
 my ($config)=@_;
 return 0 if(ref($config) ne "HASH" || !$config->{"lg_autocal_26"} || !$config->{"lg_autocal_26_full_ddc_spine"});
 return 1 if(lg_autocal_26_sdr_headroom_enabled($config));
 return 1 if(lg_autocal_26_hdr20_seed_enabled($config));
 return 0;
}

sub lg_autocal_26_sdr_headroom_enabled {
 my ($config)=@_;
 return 0 if(ref($config) ne "HASH" || !$config->{"lg_autocal_26"});
 my $signal_mode=lc($config->{"signal_mode"}||"sdr");
 return ($signal_mode eq "sdr") ? 1 : 0;
}

sub lg_autocal_26_hdr20_seed_enabled {
 my ($config)=@_;
 return 0 if(ref($config) ne "HASH" || !$config->{"lg_autocal_26"});
 my $signal_mode=lc($config->{"signal_mode"}||"sdr");
 return 0 if($signal_mode ne "hdr10");
 my $layout=lc($config->{"ddc_layout"} || ddc_layout_for_signal_mode($signal_mode) || $LG_AUTOCAL_DDC_LAYOUT || "");
 return ($layout eq "hdr20") ? 1 : 0;
}

sub lg_autocal_26_full_ddc_spine_anchor_ires_for_layout {
 my ($layout)=@_;
 $layout=lc($layout||$LG_AUTOCAL_DDC_LAYOUT||"sdr26");
 return (100,20.09,40.18,59.82,79.91) if($layout eq "hdr20");
 return (109,20,40,60,80);
}

sub lg_autocal_26_full_ddc_spine_anchor_ddc_ires_for_layout {
 my ($layout)=@_;
 $layout=lc($layout||$LG_AUTOCAL_DDC_LAYOUT||"sdr26");
 my @anchors=lg_autocal_26_full_ddc_spine_anchor_ires_for_layout($layout);
 return map { hdr20_effective_ddc_array_ire($_) || $_ } @anchors if($layout eq "hdr20");
 return @anchors;
}

sub lg_autocal_26_full_ddc_spine_anchor_ires {
 my ($config)=@_;
 my $layout;
 if(ref($config) eq "HASH") {
  $layout=$config->{"ddc_layout"} || ddc_layout_for_signal_mode(lc($config->{"signal_mode"}||"sdr"));
 }
 $layout ||= $LG_AUTOCAL_DDC_LAYOUT || "sdr26";
 return lg_autocal_26_full_ddc_spine_anchor_ires_for_layout($layout);
}

sub lg_autocal_26_full_ddc_spine_anchor_ddc_ires {
 my ($config)=@_;
 my $layout;
 if(ref($config) eq "HASH") {
  $layout=$config->{"ddc_layout"} || ddc_layout_for_signal_mode(lc($config->{"signal_mode"}||"sdr"));
 }
 $layout ||= $LG_AUTOCAL_DDC_LAYOUT || "sdr26";
 return lg_autocal_26_full_ddc_spine_anchor_ddc_ires_for_layout($layout);
}

sub lg_autocal_26_full_ddc_spine_anchor_count {
 my @anchors=lg_autocal_26_full_ddc_spine_anchor_ires();
 return scalar(@anchors);
}

sub lg_autocal_26_full_ddc_spine_anchor {
 my ($target)=@_;
 return 0 if(ref($target) ne "HASH" || !defined($target->{"ire"}));
 my $layout=$target->{"ddc_layout"} || $LG_AUTOCAL_DDC_LAYOUT || "sdr26";
 my $ire=(lc($layout||"") eq "hdr20") ? ($target->{"ire"}+0) :
  (defined($target->{"array_ire"}) ? ($target->{"array_ire"}+0) : ($target->{"ire"}+0));
 my $match=grep { abs($ire-$_) < 0.001 } lg_autocal_26_full_ddc_spine_anchor_ires_for_layout($layout);
 return $match ? 1 : 0;
}

sub lg_autocal_26_full_ddc_spine_body_anchor {
 my ($target)=@_;
 return 0 if(!lg_autocal_26_full_ddc_spine_anchor($target));
 my $ire=$target->{"ire"}+0;
 return ($ire > 0 && $ire < 99.9) ? 1 : 0;
}

sub lg_autocal_26_full_ddc_spine_anchor_revisit_step {
 my ($step)=@_;
 return (ref($step) eq "HASH" && $step->{"lg_autocal_26_full_ddc_spine_anchor_revisit"}) ? 1 : 0;
}

sub lg_autocal_26_anchor_predrive_enabled {
 my ($config)=@_;
 return (ref($config) eq "HASH" && lg_autocal_26_sdr_headroom_enabled($config) && $config->{"lg_autocal_26_anchor_predrive"}) ? 1 : 0;
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

sub apply_lg_autocal_26_default_modes {
 my ($config)=@_;
 return if(ref($config) ne "HASH");
 return if(!$config->{"lg_autocal_26"});
 if(lg_autocal_26_hdr20_seed_enabled($config)) {
  $config->{"lg_autocal_26_full_ddc_spine"}=JSON::PP::true if(!exists($config->{"lg_autocal_26_full_ddc_spine"}));
  $config->{"lg_autocal_26_anchor_predrive"}=JSON::PP::false if(!exists($config->{"lg_autocal_26_anchor_predrive"}));
  $config->{"patch_insert"}=JSON::PP::false if(!$config->{"patch_insert"});
  return;
 }
 if(!lg_autocal_26_sdr_headroom_enabled($config)) {
  $config->{"lg_autocal_26_full_ddc_spine"}=JSON::PP::false;
  $config->{"lg_autocal_26_anchor_predrive"}=JSON::PP::false;
  $config->{"patch_insert"}=JSON::PP::false;
  return;
 }
 # Standalone and Full AutoCal greyscale now share the same LG 26pt
 # full-DDC spine path. Explicit callers can still override both flags.
 if(!exists($config->{"lg_autocal_26_full_ddc_spine"}) && !exists($config->{"lg_autocal_26_anchor_predrive"})) {
  $config->{"lg_autocal_26_full_ddc_spine"}=JSON::PP::true;
  $config->{"lg_autocal_26_anchor_predrive"}=JSON::PP::false;
  return;
 }
 if($config->{"lg_autocal_26_full_ddc_spine"} && !exists($config->{"lg_autocal_26_anchor_predrive"})) {
  $config->{"lg_autocal_26_anchor_predrive"}=JSON::PP::false;
  return;
 }
 return if(exists($config->{"lg_autocal_26_anchor_predrive"}));
 $config->{"lg_autocal_26_anchor_predrive"}=JSON::PP::true;
}

sub apply_post_commit_verify_gate {
 my ($config)=@_;
 return if(ref($config) ne "HASH");
 return if(!exists($config->{"post_commit_verify"}) || $config->{"post_commit_verify"});
 foreach my $key (qw(post_commit_body_verify post_commit_final_all_level_verify post_commit_final_top_window)) {
  $config->{$key}=JSON::PP::false;
 }
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
	 if(ref($config) eq "HASH" && lg_autocal_26_sdr_headroom_enabled($config)) {
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
				  @lg_autocal_26_order=(109,20,40,60,80,105,99,95,90,85,80,75,70,65,60,55,50,45,40,35,30,25,20,15,10,7,5,4,3,2.3)
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
   if($seen_target{$wanted_key} && lg_autocal_26_full_ddc_spine_enabled($config)) {
    my ($anchor_match)=grep {
     my $key=$target_key->($_);
     defined($key) && $key eq $wanted_key
    } @valid;
    if($anchor_match) {
     my $anchor_target=ddc_target_for_step($anchor_match);
     if(lg_autocal_26_full_ddc_spine_body_anchor($anchor_target)) {
      my $revisit=clone_picture($anchor_match);
      $revisit->{"lg_autocal_26_full_ddc_spine_anchor_revisit"}=JSON::PP::true;
      $revisit->{"lg_autocal_26_seeded_move_damping"}=JSON::PP::true;
      $revisit->{"autocal_target_label"}=format_percent($anchor_target->{"ire"})."% anchor revisit";
      push @ordered,$revisit;
     }
    }
    next;
   }
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
	 if(ref($config) eq "HASH" && lg_autocal_26_hdr20_seed_enabled($config) && lg_autocal_26_full_ddc_spine_enabled($config)) {
	  return @valid if($config->{"lg_autocal_preserve_step_order"} || $config->{"preserve_step_order"});
	  my @top_down=sort { $b <=> $a } ddc_slots_for_layout("hdr20");
	  my @hdr_autocal_26_order=(lg_autocal_26_full_ddc_spine_anchor_ires_for_layout("hdr20"),@top_down);
	  my %seen_target;
	  my @ordered;
	  my $target_key=sub {
	   my ($step)=@_;
	   my $target=ddc_target_for_step($step);
	   return undef if(ref($target) ne "HASH" || !defined($target->{"ire"}));
	   return format_percent($target->{"ire"});
	  };
	  foreach my $wanted (@hdr_autocal_26_order) {
	   my $wanted_key=format_percent($wanted);
		   next if($seen_target{$wanted_key});
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

sub pq_decode_normalized {
 my ($signal)=@_;
 $signal=clamp_unit($signal);
 return 0 if($signal <= 0);
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
 return clamp_unit($l ** (1/$m1));
}

sub pq_decode_nits {
 my ($signal)=@_;
 return pq_decode_normalized($signal) * 10000;
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
 if($target_gamma eq "st2084") {
  return pq_decode_normalized($signal);
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
	 if($mode eq "hdr10" && lc($target_gamma||"") eq "st2084") {
	  my $pq_y=pq_decode_nits($signal);
	  return ($pq_y > $white_y) ? $white_y : $pq_y;
	 }
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

sub autocal_step_suppresses_luminance_adjustment {
 my ($step)=@_;
 return 0 if(ref($step) ne "HASH" || !defined($step->{"ire"}));
 my $layout=lc($step->{"ddc_layout"} || $LG_AUTOCAL_DDC_LAYOUT || "");
 return 0 if($layout eq "hdr20");
 my $ire=$step->{"ire"}+0;
 return ($ire >= 99.9 && !autocal_step_is_fast_headroom($step)) ? 1 : 0;
}

sub autocal_step_is_hdr20_top_white {
	 my ($step)=@_;
	 return 0 if(ref($step) ne "HASH" || !defined($step->{"ire"}));
	 my $layout=lc($step->{"ddc_layout"} || $LG_AUTOCAL_DDC_LAYOUT || "");
	 return 0 if($layout ne "hdr20");
	 my $ire=$step->{"ire"}+0;
	 return ($ire >= 99.9 && $ire <= 100.1) ? 1 : 0;
}

sub autocal_step_is_hdr20_body {
	 my ($step)=@_;
	 return 0 if(ref($step) ne "HASH" || !defined($step->{"ire"}));
	 my $layout=lc($step->{"ddc_layout"} || $LG_AUTOCAL_DDC_LAYOUT || "");
	 return 0 if($layout ne "hdr20");
	 my $ire=$step->{"ire"}+0;
	 return ($ire > 0.001 && $ire < 99.9) ? 1 : 0;
}

sub hdr20_top_white_luminance_priority_needed {
	 my ($step,$lum_pct,$fraction)=@_;
	 return 0 if(!autocal_step_is_hdr20_top_white($step));
	 return 0 if(!defined($lum_pct));
 $fraction=0.35 if(!defined($fraction) || $fraction <= 0);
 my $tol=luminance_tolerance_percent($step);
 $tol=0.45 if(!defined($tol) || $tol <= 0);
 return abs($lum_pct+0) > ($tol*$fraction) ? 1 : 0;
}

sub hdr20_top_white_chroma_priority_needed {
	 my ($step,$error,$de,$target_delta)=@_;
	 return 0 if(!autocal_step_is_hdr20_top_white($step));
	 return 0 if(ref($error) ne "HASH");
	 $target_delta=0.5 if(!defined($target_delta) || $target_delta <= 0);
	 my $chroma=chroma_error_magnitude($error);
	 return ($chroma >= 0.020 && (!defined($de) || $de > ($target_delta+0.75))) ? 1 : 0;
}

sub hdr20_body_chroma_priority_needed {
	 my ($step,$error,$de,$target_delta)=@_;
	 return 0 if(!autocal_step_is_hdr20_body($step));
	 return 0 if(ref($error) ne "HASH");
	 $target_delta=0.5 if(!defined($target_delta) || $target_delta <= 0);
	 my $chroma=chroma_error_magnitude($error);
	 return 1 if($chroma >= 0.035);
	 return ($chroma >= 0.020 && (!defined($de) || $de > ($target_delta+1.0))) ? 1 : 0;
}

sub autocal_step_ignores_luminance_error {
	 my ($step)=@_;
	 return 1 if(autocal_step_is_hdr20_top_white($step));
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

sub autocal_config_is_post_3d_polish {
 my ($config)=@_;
 return (ref($config) eq "HASH" && $config->{"full_autocal_post_3d_polish"}) ? 1 : 0;
}

sub autocal_config_is_post_series_adjust {
	 my ($config)=@_;
	 return (ref($config) eq "HASH" && $config->{"full_autocal_post_series_adjust"}) ? 1 : 0;
}

sub autocal_config_is_post_series_revert {
 my ($config)=@_;
 return (ref($config) eq "HASH" && $config->{"full_autocal_post_series_revert"}) ? 1 : 0;
}

sub lg_autocal_26_standalone_committed_cleanup_enabled {
 my ($config)=@_;
 return 0 if(ref($config) ne "HASH" || !$config->{"lg_autocal_26"});
 return 1 if(autocal_config_is_post_3d_polish($config));
 return 0 if($config->{"full_workflow"} || autocal_config_is_touchup($config));
 return 1;
}

sub lg_autocal_26_oled_shadow_detail_compensation_enabled {
 my ($config)=@_;
 return 0; # Disabled: this pre-commit OLED shadow bias made low-shadow points read too bright after calibration.
}

sub oled_shadow_detail_bias_pct_for_ire {
 my ($config,$ire)=@_;
 my %default=(
  "2.3" => 14.0,
  "3" => 4.0,
  "4" => 3.0,
  "5" => 1.5,
 );
 my $key=format_percent($ire);
 my $matrix=(ref($config) eq "HASH" && ref($config->{"lg_autocal_26_oled_shadow_detail_bias_pct"}) eq "HASH")
  ? $config->{"lg_autocal_26_oled_shadow_detail_bias_pct"} : undef;
 if(ref($matrix) eq "HASH") {
  foreach my $candidate (keys %$matrix) {
   next if(!defined($candidate) || !defined($matrix->{$candidate}));
   if(abs(($candidate+0)-($ire+0)) < 0.001) {
    my $pct=$matrix->{$candidate}+0;
    $pct=0 if($pct < 0);
    $pct=25 if($pct > 25);
    return $pct;
   }
  }
 }
 return exists($default{$key}) ? $default{$key} : undef;
}

sub oled_shadow_detail_default_slope_for_ire {
 my ($ire)=@_;
 return 30 if(defined($ire) && $ire <= 2.5001);
 return 15 if(defined($ire) && $ire <= 3.1001);
 return 10 if(defined($ire) && $ire <= 4.1001);
 return 7 if(defined($ire) && $ire <= 5.1001);
 return undef;
}

sub oled_shadow_detail_max_delta_for_ire {
 my ($config,$ire)=@_;
 my $default=(defined($ire) && $ire <= 2.5001) ? 0.75 : 0.50;
 my $configured=(ref($config) eq "HASH" && defined($config->{"lg_autocal_26_oled_shadow_detail_max_delta"}))
  ? ($config->{"lg_autocal_26_oled_shadow_detail_max_delta"}+0) : $default;
 $configured=0.25 if($configured < 0.25);
 $configured=2.0 if($configured > 2.0);
 return $configured;
}

sub apply_lg_autocal_26_oled_shadow_detail_compensation {
 my ($config,$state,$arrays,$ordered,$calibrated_slot_mask)=@_;
 return 0 if(!lg_autocal_26_oled_shadow_detail_compensation_enabled($config));
 return 0 if(ref($state) ne "HASH" || ref($arrays) ne "HASH" || ref($ordered) ne "ARRAY");
 return 0 if(ref($arrays->{"adjustingLuminance"}) ne "ARRAY");
 my @changes;
 foreach my $step (@{$ordered}) {
  next if(ref($step) ne "HASH" || !defined($step->{"ire"}));
  next if(!autocal_step_is_low_shadow($step));
  my $ire=$step->{"ire"}+0;
  my $target_bias=oled_shadow_detail_bias_pct_for_ire($config,$ire);
  next if(!defined($target_bias) || $target_bias <= 0);
  my $target=ddc_target_for_step($step);
  next if(ref($target) ne "HASH");
  my $idx=$target->{"index"};
  next if(!defined($idx) || $idx >= @{$arrays->{"adjustingLuminance"}});
  next if(ref($calibrated_slot_mask) eq "ARRAY" && !$calibrated_slot_mask->[$idx]);
  my $entry=lg_autocal_26_best_known_for_step($state,$step);
  next if(ref($entry) ne "HASH" || lg_autocal_26_best_known_committed_state($entry));
  my $lum_pct=defined($entry->{"luminance_error_pct"}) ? ($entry->{"luminance_error_pct"}+0) : undef;
  next if(!defined($lum_pct));
  my $remaining_bias=$target_bias-$lum_pct;
  next if($remaining_bias <= 0.25);
  my $model=lg_autocal_26_response_model_for_step($state,$step);
  my $response=(ref($model) eq "HASH" && ref($model->{"luminance"}) eq "HASH" && ref($model->{"luminance"}{"adjustingLuminance"}) eq "HASH")
   ? $model->{"luminance"}{"adjustingLuminance"} : undef;
  my $slope=(ref($response) eq "HASH" && defined($response->{"slope"})) ? ($response->{"slope"}+0) : oled_shadow_detail_default_slope_for_ire($ire);
  next if(!defined($slope) || $slope <= 0.05);
  my $raw_delta=$remaining_bias/$slope;
  my $cap=oled_shadow_detail_max_delta_for_ire($config,$ire);
  $raw_delta=$cap if($raw_delta > $cap);
  next if($raw_delta < 0.10);
  my $current=defined($arrays->{"adjustingLuminance"}[$idx]) ? ($arrays->{"adjustingLuminance"}[$idx]+0) : 0;
  my $next=round_ddc_quarter($current+$raw_delta);
  next if($next <= $current+0.0001);
  $arrays->{"adjustingLuminance"}[$idx]=$next;
  my $change={
   ire=>$ire+0,
   index=>$idx+0,
   current=>$current+0,
   next=>$next+0,
   delta=>($next-$current)+0,
   source_luminance_error_pct=>$lum_pct+0,
   target_bias_pct=>$target_bias+0,
   remaining_bias_pct=>$remaining_bias+0,
   slope=>$slope+0,
   slope_source=>(ref($response) eq "HASH" ? "learned" : "default"),
   source_reason=>$entry->{"reason"}||"best_known",
  };
  push @changes,$change;
  trace_109($step,"oled_shadow_detail_compensation",$change);
 }
 if(@changes) {
  $state->{"oled_shadow_detail_compensation"}=\@changes;
  $state->{"oled_shadow_detail_compensation_applied"}=scalar(@changes)+0;
  write_state($state);
 }
 return scalar(@changes);
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
	 return 0 if(near_white_95_luma_needs_fine_tune($step,$lum_pct,$de,$target_delta,0));
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
 $limit=18 if($ire < 108.5 && lg_autocal_26_full_ddc_spine_enabled($config));
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

sub low_shadow_committed_target_bias_pct_for_step {
 my ($config,$step)=@_;
 return (0,"not_lg_autocal_26") if(ref($config) ne "HASH" || !$config->{"lg_autocal_26"});
 return (0,"not_low_shadow") if(ref($step) ne "HASH" || !defined($step->{"ire"}));
 my $ire=$step->{"ire"}+0;
 return (0,"not_low_shadow") if($ire <= 0 || $ire > 10.0001);
 my $mode=defined($config->{"low_shadow_committed_target_bias_mode"}) ? lc($config->{"low_shadow_committed_target_bias_mode"}) : "off";
 return (0,"disabled") if($mode eq "off" || $mode eq "disabled" || $mode eq "none");
 my %default=();
 my $matrix=(ref($config->{"low_shadow_committed_target_bias_matrix_pct"}) eq "HASH")
  ? $config->{"low_shadow_committed_target_bias_matrix_pct"} : undef;
 $matrix=$config->{"low_shadow_committed_target_bias_matrix"} if(ref($matrix) ne "HASH" && ref($config->{"low_shadow_committed_target_bias_matrix"}) eq "HASH");
 my $source="default";
 my $bias;
 if(ref($matrix) eq "HASH") {
  foreach my $key (keys %$matrix) {
   next if(!defined($key) || !defined($matrix->{$key}));
   if(abs(($key+0)-$ire) < 0.001) {
    $bias=$matrix->{$key}+0;
    $source="matrix";
    last;
   }
  }
 }
 if(!defined($bias)) {
  my $key=format_percent($ire);
  return (0,"not_configured") if(!exists($default{$key}));
  $bias=$default{$key};
 }
 $bias=-0.25 if($bias < -0.25);
 $bias=0.05 if($bias > 0.05);
 return (0,"zero_bias") if(abs($bias) < 0.0000001);
 return ($bias,$source);
}

sub low_shadow_committed_target_bias_allowed {
 my ($config,$state,$signal_mode,$base_target_y)=@_;
 return (0,"not_lg_autocal_26") if(ref($config) ne "HASH" || !$config->{"lg_autocal_26"});
 return (0,"not_sdr") if(lc($signal_mode||"sdr") ne "sdr");
 return (0,"missing_target") if(!defined($base_target_y) || $base_target_y <= 0);
 return (0,"touchup") if(autocal_config_is_touchup($config));
 return (0,"post_3d_polish") if(autocal_config_is_post_3d_polish($config));
 return (0,"post_series_adjust") if(autocal_config_is_post_series_adjust($config));
 return (0,"post_series_revert") if(autocal_config_is_post_series_revert($config));
 if(ref($state) eq "HASH") {
  return (0,"final_lut_uploaded") if($state->{"final_1d_lut_uploaded"});
  my $phase=lc($state->{"phase"}||"");
  my $name=lc($state->{"current_name"}||"");
  return (0,"committed_phase") if($phase =~ /(committed|polish|verify|post|series|settling)/ || $name =~ /(committed|polish|verify|post|series|magic wand)/);
 }
 return (1,"eligible");
}

sub low_shadow_committed_target_bias_decision {
 my ($config,$state,$step,$signal_mode,$base_target_y)=@_;
 my ($bias_pct,$bias_source)=low_shadow_committed_target_bias_pct_for_step($config,$step);
 my ($eligible,$allowed_reason)=low_shadow_committed_target_bias_allowed($config,$state,$signal_mode,$base_target_y);
 my $applied=($eligible && abs($bias_pct) > 0.0000001) ? 1 : 0;
 my $effective_target_y=$applied ? $base_target_y*(1+$bias_pct) : $base_target_y;
 my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : undef;
 my $reason=$applied ? "applied" : (!$eligible ? $allowed_reason : $bias_source);
 if(defined($ire) && $ire > 0 && $ire <= 10.0001 && ($applied || $reason ne "not_configured")) {
  trace_109($step,"low_shadow_committed_target_bias_decision",{
   ire=>$ire+0,
   base_target_y=>defined($base_target_y)?$base_target_y+0:undef,
   biased_target_y=>defined($effective_target_y)?$effective_target_y+0:undef,
   effective_target_y=>defined($effective_target_y)?$effective_target_y+0:undef,
   bias_pct=>$bias_pct+0,
   bias_source=>$bias_source,
   bias_applied=>$applied?JSON::PP::true:JSON::PP::false,
   applied=>$applied?JSON::PP::true:JSON::PP::false,
   reason=>$reason
  });
 }
 return $effective_target_y;
}

sub effective_target_luminance_for_autocal_reading {
	 my ($white_y,$step,$reading,$target_gamma,$signal_mode,$config,$state)=@_;
	 if(autocal_step_ignores_luminance_error($step)) {
	  my $Y=luminance($reading);
	  return $Y if(defined($Y) && $Y > 0);
	 }
	 my $target=target_luminance_for_autocal_step($white_y,$step,$target_gamma,$signal_mode);
	 if(!defined($target) && autocal_step_is_peak_headroom($step)) {
	  my $Y=luminance($reading);
	  return $Y if(defined($Y) && $Y > 0);
	 }
	 $target=body_luma_bias_decision($config || $LG_AUTOCAL_CONFIG,$state || $LG_AUTOCAL_STATE,$step,$target_gamma,$signal_mode,$target);
	 $target=low_shadow_committed_target_bias_decision($config || $LG_AUTOCAL_CONFIG,$state || $LG_AUTOCAL_STATE,$step,$signal_mode,$target);
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
	 return 0 if(ref($config) ne "HASH" || !lg_autocal_26_sdr_headroom_enabled($config));
	 return 0 if(ref($state) ne "HASH");
	 return (defined($state->{"peak_headroom_reference"}) && ($state->{"peak_headroom_reference"}+0) > 0) ? 1 : 0;
}

sub update_white_reference_for_autocal_step {
	 my ($config,$state,$step,$reading,$white_y)=@_;
	 return $white_y if(keep_peak_headroom_white_reference($config,$state) && !autocal_step_is_peak_headroom($step));
	 if(ref($config) eq "HASH" && lc($config->{"signal_mode"}||"sdr") ne "sdr" && autocal_step_is_white($step) && !$step->{"autocal_white_reference"} && ddc_target_for_step($step)) {
	  return update_white_reference_for_step($step,$reading,$white_y) if(autocal_step_is_hdr20_top_white($step));
	  return $white_y;
	 }
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
 my $prefer_headroom=lg_autocal_26_sdr_headroom_enabled($config) ? 1 : 0;
 my $committed_ref=(ref($state) eq "HASH" && defined($state->{"committed_polish_white_y"}) && ($state->{"committed_polish_white_y"}+0) > 0)
  ? ($state->{"committed_polish_white_y"}+0) : undef;
 my $peak_ref=(ref($state) eq "HASH" && defined($state->{"peak_headroom_reference"}) && ($state->{"peak_headroom_reference"}+0) > 0)
  ? ($state->{"peak_headroom_reference"}+0) : undef;
 return $peak_ref if($prefer_headroom && defined($peak_ref));
 if($prefer_headroom && ref($state) eq "HASH" && ref($state->{"readings"}) eq "ARRAY") {
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
 return $from_headroom if($prefer_headroom && defined($from_headroom) && $from_headroom > 0);
 return $committed_ref if(defined($committed_ref));
 return $peak_ref if($prefer_headroom && defined($peak_ref));
 return $from_headroom if($prefer_headroom && defined($from_headroom) && $from_headroom > 0);
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
	 my $sdr_headroom=lg_autocal_26_sdr_headroom_enabled($config);
	 my $headroom=$sdr_headroom ? 109.5 : 100;
	 $stimulus=$headroom if($stimulus > $headroom);
	 my $pattern_range=$config->{"pattern_signal_range"}||$config->{"signal_range"}||$config->{"transport_signal_range"}||"";
	 my $limited=($pattern_range ne "" && int($pattern_range)==1) ? 1 : 0;
	 my $code;
	 if($limited && $sdr_headroom) {
	  $code=int(64 + ($stimulus/100)*876 + .5);
	 } elsif($limited && lg_extended_sdr_16_255_enabled($config)) {
	  $code=($stimulus <= 0) ? 0 : int(16 + ($stimulus/100)*239 + .5);
	 } else {
	  $code=$limited ? int(16 + ($stimulus/100)*219 + .5) : int(($stimulus/100)*255 + .5);
	 }
	 $code=($limited && $sdr_headroom) ? 64 : 0 if($code < 0);
	 $code=$sdr_headroom ? 1023 : 255 if($code > ($sdr_headroom ? 1023 : 255));
	 return $code;
}

sub shifted_stimulus_step {
	 my ($config,$step,$stimulus)=@_;
	 return undef if(ref($step) ne "HASH" || !defined($stimulus));
	 return undef if(!lg_autocal_26_sdr_headroom_enabled($config));
	 $stimulus=0 if($stimulus < 0);
	 my $sdr_headroom=lg_autocal_26_sdr_headroom_enabled($config);
	 my $headroom=$sdr_headroom ? 109.5 : 100;
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
	 $clone->{"input_max"}=1023 if($sdr_headroom);
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
	 return $step if(!lg_autocal_26_sdr_headroom_enabled($config));
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
		 my $headroom=lg_autocal_26_sdr_headroom_enabled($config) ? 109.5 : 100;
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
		 my $headroom=lg_autocal_26_sdr_headroom_enabled($config) ? 109.5 : 100;
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
	 if(autocal_step_is_hdr20_body($step)) {
	  $target_delta=0.5 if(!defined($target_delta) || $target_delta <= 0);
	  return 3 if(defined($de) && $de <= ($target_delta+1.5));
	  return 5;
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
 my ($de,$step,$target_delta)=@_;
 my $limit=itp_luminance_included_acceptance_limit($step);
 return 1 if(!defined($limit));
 return (defined($de) && $de <= $target_delta) ? 1 : 0 if(defined($target_delta) && $target_delta > $limit);
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

sub low_shadow_strict_itp_y_step {
 my ($step)=@_;
 return 0 if(!autocal_uses_itp());
 return 0 if(ref($step) ne "HASH" || !defined($step->{"ire"}));
 my $ire=$step->{"ire"}+0;
 return ($ire >= 2.999 && $ire <= 5.1001) ? 1 : 0;
}

sub low_shadow_strict_luminance_close_enough {
 my ($step,$lum_pct)=@_;
 return 0 if(!defined($lum_pct));
 return 0 if(low_ire_luminance_needs_lift($step,$lum_pct));
 return abs($lum_pct) <= luminance_tolerance_percent($step) ? 1 : 0;
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
 if(low_shadow_strict_itp_y_step($step)) {
  return 0 if(!low_shadow_strict_luminance_close_enough($step,$lum_pct));
  return ($de <= $target_delta) ? 1 : 0;
 }
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
	 if(autocal_step_is_hdr20_body($step)) {
	  return 0 if(!defined($lum_pct));
	  return 0 if(abs($lum_pct) > luminance_tolerance_percent($step));
	 }
	 return ($de <= ($target_delta+0.25)) ? 1 : 0;
}

sub target_reached {
			 my ($de,$lum_pct,$target_delta,$step)=@_;
				 return 0 if(!defined($de));
				 my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : 100;
				 return 1 if(low_shadow_itp_near_target_reached($step,$de,$lum_pct,$target_delta));
				 return 0 if(low_ire_luminance_needs_lift($step,$lum_pct));
					 return 0 if(low_ire_luminance_needs_tuning($step,$lum_pct));
					 return 0 if(near_white_95_luma_needs_fine_tune($step,$lum_pct,$de,$target_delta,0));
					 return 1 if(autocal_step_is_low_shadow($step) && $de <= low_shadow_delta_acceptance($step,$target_delta));
					 return 1 if(body_itp_near_target_reached($step,$de,$lum_pct,$target_delta));
				 return 0 if(!within_itp_luminance_included_acceptance($de,$step,$target_delta));
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
	 return 0 if(near_white_95_luma_needs_fine_tune($step,$best_lum_pct,$best_de,$target_delta,0));
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
						 if(autocal_step_is_hdr20_body($step) && defined($lum_pct)) {
						  my $excess=abs($lum_pct)-luminance_tolerance_percent($step);
						  return $score if($excess <= 0);
						  my $penalty=$excess*0.45;
						  $penalty=8 if($penalty > 8);
						  return $score+$penalty;
						 }
						 if(autocal_step_is_low_shadow($step) && autocal_uses_itp() && defined($lum_pct)) {
						  my $shadow_lum_excess=abs($lum_pct)-low_shadow_luminance_acceptance_percent($step);
						  return $score if($shadow_lum_excess <= 0);
					  my $shadow_lum_penalty=$shadow_lum_excess*0.45;
					  $shadow_lum_penalty=4 if($shadow_lum_penalty > 4);
					  return $score+$shadow_lum_penalty;
					 }
					 if(autocal_step_is_fast_headroom($step) && !autocal_step_is_peak_headroom($step) && defined($lum_pct)) {
					  my $excess=abs($lum_pct)-luminance_tolerance_percent($step);
					  return $score if($excess <= 0);
					  my $penalty=$excess*0.35;
					  $penalty=4 if($penalty > 4);
					  return $score+$penalty;
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
 my ($step,$reading,$de,$lum_pct,$target_luminance,$arrays,$target,$reason,$reached_target)=@_;
 return undef if(ref($step) ne "HASH" || ref($reading) ne "HASH" || !defined($de));
 my $score=lg_autocal_26_measurement_score($step,$de,$lum_pct);
 my $entry={
  ire=>($step->{"ire"}+0),
  delta_e=>$de+0,
  luminance_error_pct=>defined($lum_pct) ? ($lum_pct+0) : undef,
  target_luminance=>defined($target_luminance) ? ($target_luminance+0) : undef,
  score=>$score+0,
  reason=>$reason||"best_known",
  reading=>trace_reading_summary($reading),
  ddc_values=>trace_target_values($arrays,$target),
 };
 $entry->{"reached_target"}=$reached_target ? JSON::PP::true : JSON::PP::false if(defined($reached_target));
 return $entry;
}

sub remember_lg_autocal_26_best_known {
 my ($config,$state,$step,$reading,$de,$lum_pct,$target_luminance,$arrays,$target,$reason,$reached_target)=@_;
 return if(ref($config) ne "HASH" || !$config->{"lg_autocal_26"});
 return if(ref($state) ne "HASH");
 my $entry=lg_autocal_26_best_known_entry($step,$reading,$de,$lum_pct,$target_luminance,$arrays,$target,$reason,$reached_target);
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

sub lg_autocal_26_full_ddc_spine_anchor_seed_gate {
 my ($config,$target,$entry,$target_delta)=@_;
 my %decision=(accepted=>JSON::PP::true,reason=>"not_hdr_full_ddc_spine");
 return \%decision if(ref($config) ne "HASH" || !lg_autocal_26_full_ddc_spine_enabled($config));
 return \%decision if(ref($target) ne "HASH");
 return \%decision if(lc($config->{"signal_mode"}||"sdr") ne "hdr10");
 if(ref($entry) ne "HASH") {
  return {
   accepted=>JSON::PP::false,
   reason=>"missing_best_known_anchor_result",
  };
 }
 my $de=defined($entry->{"delta_e"}) ? ($entry->{"delta_e"}+0) : undef;
 my $lum=defined($entry->{"luminance_error_pct"}) ? ($entry->{"luminance_error_pct"}+0) : undef;
 my $reached=$entry->{"reached_target"} ? 1 : 0;
 my $de_limit=defined($target_delta) ? (($target_delta+0)+3.5) : 4.0;
 $de_limit=4.0 if($de_limit < 4.0);
 my $lum_limit=10.0;
 if($reached) {
  return {
   accepted=>JSON::PP::true,
   reason=>"anchor_reached_target",
   delta_e=>defined($de) ? $de+0 : undef,
   luminance_error_pct=>defined($lum) ? $lum+0 : undef,
   reached_target=>JSON::PP::true,
  };
 }
 if(defined($de) && $de > $de_limit) {
  return {
   accepted=>JSON::PP::false,
   reason=>"anchor_delta_e_too_high_for_spine_seed",
   delta_e=>$de+0,
   luminance_error_pct=>defined($lum) ? $lum+0 : undef,
   delta_e_limit=>$de_limit+0,
   luminance_error_limit=>$lum_limit+0,
   reached_target=>JSON::PP::false,
  };
 }
 if(defined($lum) && abs($lum) > $lum_limit) {
  return {
   accepted=>JSON::PP::false,
   reason=>"anchor_luminance_error_too_high_for_spine_seed",
   delta_e=>defined($de) ? $de+0 : undef,
   luminance_error_pct=>$lum+0,
   delta_e_limit=>$de_limit+0,
   luminance_error_limit=>$lum_limit+0,
   reached_target=>JSON::PP::false,
  };
 }
 return {
  accepted=>JSON::PP::true,
  reason=>"anchor_within_spine_seed_guard",
  delta_e=>defined($de) ? $de+0 : undef,
  luminance_error_pct=>defined($lum) ? $lum+0 : undef,
  delta_e_limit=>$de_limit+0,
  luminance_error_limit=>$lum_limit+0,
  reached_target=>JSON::PP::false,
 };
}

sub lg_autocal_26_is_105_step {
 my ($step)=@_;
 return 0 if(ref($step) ne "HASH" || !defined($step->{"ire"}));
 my $ire=$step->{"ire"}+0;
 return (abs($ire-105) < 0.001) ? 1 : 0;
}

sub lg_autocal_26_good_105_best_known_limit {
 my ($target_delta)=@_;
 my $limit=defined($target_delta) ? (($target_delta+0)+0.40) : 0.90;
 $limit=0.90 if($limit > 0.90);
 $limit=0.60 if($limit < 0.60);
 return $limit;
}

sub lg_autocal_26_good_105_best_known {
 my ($step,$entry,$target_delta)=@_;
 return 0 if(!lg_autocal_26_is_105_step($step));
 return 0 if(ref($entry) ne "HASH" || !defined($entry->{"delta_e"}));
 return (($entry->{"delta_e"}+0) <= lg_autocal_26_good_105_best_known_limit($target_delta)+0.0001) ? 1 : 0;
}

sub lg_autocal_26_candidate_beats_good_105_best_known {
 my ($step,$candidate_score,$entry,$target_delta)=@_;
 return 1 if(!lg_autocal_26_good_105_best_known($step,$entry,$target_delta));
 return 0 if(!defined($candidate_score));
 my $best_score=defined($entry->{"score"}) ? ($entry->{"score"}+0) : lg_autocal_26_measurement_score($step,$entry->{"delta_e"},$entry->{"luminance_error_pct"});
 return (($candidate_score+0) + 0.03 < $best_score) ? 1 : 0;
}

sub lg_autocal_26_reading_response_for_delta {
 my ($before,$after,$delta)=@_;
 return undef if(ref($before) ne "HASH" || ref($after) ne "HASH");
 return undef if(!defined($delta) || abs($delta) < 0.0001);
 my %response;
 foreach my $key (qw(x y Y)) {
  next if(!defined($before->{$key}) || !defined($after->{$key}));
  my $change=($after->{$key}+0)-($before->{$key}+0);
  $response{$key."_delta"}=$change+0;
  $response{$key."_per_ddc"}=$change/$delta;
 }
 if(defined($before->{"luminance"}) && defined($after->{"luminance"})) {
  my $change=($after->{"luminance"}+0)-($before->{"luminance"}+0);
  $response{"luminance_delta"}=$change+0;
  $response{"luminance_per_ddc"}=$change/$delta;
 }
 return %response ? \%response : undef;
}

sub remember_lg_autocal_26_response_axis {
	 my ($bucket,$group,$axis,$slope,$delta,$before_error,$after_error,$source,$reading_response)=@_;
	 return undef if(ref($bucket) ne "HASH" || !defined($group) || !defined($axis));
	 return undef if(!defined($slope) || abs($slope) < 0.000001 || !defined($delta) || abs($delta) < 0.0001);
 my $error_delta=(defined($before_error) && defined($after_error)) ? (($after_error+0)-($before_error+0)) : undef;
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
 my $ddc_per_error=(abs($slope) >= 0.000001) ? (1/$slope) : undef;
 my %reading_fields;
 if(ref($reading_response) eq "HASH") {
  foreach my $key (qw(x_delta x_per_ddc y_delta y_per_ddc Y_delta Y_per_ddc luminance_delta luminance_per_ddc)) {
   next if(!defined($reading_response->{$key}));
   my $value=$reading_response->{$key}+0;
   if(ref($existing) eq "HASH" && defined($existing->{$key}) && $samples > 1) {
    my $old_samples=($samples-1);
    $old_samples=5 if($old_samples > 5);
    $value=(($existing->{$key}+0)*$old_samples+$value)/($old_samples+1);
   }
   $reading_fields{$key}=$value+0;
  }
 }
	 $bucket->{$group}{$axis}={
	  slope=>$slope+0,
  ddc_per_error=>defined($ddc_per_error) ? ($ddc_per_error+0) : undef,
	  samples=>$samples+0,
	  delta=>$delta+0,
  error_delta=>defined($error_delta) ? ($error_delta+0) : undef,
  %reading_fields,
	  before_error=>defined($before_error) ? ($before_error+0) : undef,
	  after_error=>defined($after_error) ? ($after_error+0) : undef,
	  source=>$source||"calibration",
	  updated_at=>time()+0
	 };
	 return $bucket->{$group}{$axis};
	}

sub lg_autocal_26_expected_headroom_luminance_direction {
	 my ($step,$lum_pct,$gate_fraction)=@_;
	 return 0 if(ref($step) ne "HASH" || !autocal_step_is_fast_headroom($step) || autocal_step_is_peak_headroom($step));
	 return 0 if(!defined($lum_pct));
	 my $gate=headroom_luminance_control_gate_percent($step,defined($gate_fraction) ? $gate_fraction : 0.35);
	 $gate=0.15 if(!defined($gate) || $gate < 0.15);
	 return -1 if($lum_pct > $gate);
	 return 1 if($lum_pct < -$gate);
	 return 0;
	}

sub lg_autocal_26_headroom_luminance_response_acceptable {
	 my ($step,$delta,$before_lum_pct,$after_lum_pct)=@_;
	 return 1 if(ref($step) ne "HASH" || !autocal_step_is_fast_headroom($step) || autocal_step_is_peak_headroom($step));
	 return 1 if(!defined($delta) || !defined($before_lum_pct) || !defined($after_lum_pct));
	 my $expected=lg_autocal_26_expected_headroom_luminance_direction($step,$before_lum_pct,0.35);
	 my $change=($after_lum_pct+0)-($before_lum_pct+0);
	 return 0 if($expected && (($delta+0)*$expected) <= 0);
	 return 0 if($expected && ($change*$expected) < -0.05);
	 return 0 if(!$expected && (($delta+0)*$change) < -0.05);
	 return 1;
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
  my $reading_response=lg_autocal_26_reading_response_for_delta($before,$after,$delta);
	 my $ch=$adj->{"channel"}||"";
	 if($ch =~ /^(?:r|g|b)$/) {
	  my $before_err=autocal_adjustment_error($before,$step);
	  my $after_err=autocal_adjustment_error($after,$step);
	  if(ref($before_err) eq "HASH" && ref($after_err) eq "HASH" && defined($before_err->{$ch}) && defined($after_err->{$ch})) {
	   my $slope=(($after_err->{$ch}+0)-($before_err->{$ch}+0))/$delta;
	   my $entry=remember_lg_autocal_26_response_axis($bucket,"rgb",$ch,$slope,$delta,$before_err->{$ch},$after_err->{$ch},$source,$reading_response);
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
	    return undef if(!lg_autocal_26_headroom_luminance_response_acceptable($step,$delta,$before_lum_pct,$after_lum_pct));
	    my $slope=($after_lum_pct-$before_lum_pct)/$delta;
	    my $entry=remember_lg_autocal_26_response_axis($bucket,"luminance","adjustingLuminance",$slope,$delta,$before_lum_pct,$after_lum_pct,$source,$reading_response);
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
	  next if(luma_probe_family_suppressed($tried,$target,$current,$next,$step,$source||"learned_luminance",$state));
	  my $actual_delta=$next-$current;
	  my $predicted=($lum_pct+0)+($slope*$actual_delta);
	  next if(abs($predicted) >= abs($lum_pct)*0.92 && abs($actual_delta) > 0.21);
	  my $ddc_per_error=(abs($slope) >= 0.000001) ? (1/$slope) : undef;
	  return [{ channel=>"lum", setting=>"adjustingLuminance", current=>$current, next=>$next, delta=>$actual_delta, response_model=>1, learned_response_model=>1, slope=>$slope, ddc_per_error=>defined($ddc_per_error)?$ddc_per_error:undef, predicted_error=>$predicted, source=>$source||"learned_luminance", samples=>$entry->{"samples"}||1 }];
	 }
		 return undef;
		}

sub lg_autocal_26_adaptive_headroom_luminance_adjustment {
		 my ($state,$arrays,$target,$step,$lum_pct,$tried,$stalls,$source)=@_;
		 return undef if(ref($step) ne "HASH" || !autocal_step_is_fast_headroom($step) || autocal_step_is_peak_headroom($step));
		 return undef if(headroom_105_post_seed_body_refinement($step,$arrays,$target,$tried));
		 return undef if(ref($arrays) ne "HASH" || ref($target) ne "HASH" || !defined($lum_pct));
		 return undef if(!has_luminance_channel($arrays,$target));
		 my $luma_gate=headroom_luminance_control_gate_percent($step,0.65);
		 return undef if(abs($lum_pct) <= $luma_gate);
		 my $model=lg_autocal_26_response_model_for_step($state,$step);
		 my $entry=(ref($model) eq "HASH" && ref($model->{"luminance"}) eq "HASH") ? $model->{"luminance"}{"adjustingLuminance"} : undef;
		 return undef if(ref($entry) ne "HASH" || !defined($entry->{"slope"}));
		 my $idx=$target->{"index"};
		 return undef if(!defined($idx) || ref($arrays->{"adjustingLuminance"}) ne "ARRAY");
		 my $current=$arrays->{"adjustingLuminance"}[$idx]||0;
		 my $slope=$entry->{"slope"}+0;
		 my $prev_delta=defined($entry->{"delta"}) ? ($entry->{"delta"}+0) : 0;
		 my $before_error=defined($entry->{"before_error"}) ? ($entry->{"before_error"}+0) : undef;
		 my $after_error=defined($entry->{"after_error"}) ? ($entry->{"after_error"}+0) : undef;
		 my $observed_change=(defined($before_error) && defined($after_error)) ? abs($after_error-$before_error) : undef;
		 my $improvement=(defined($before_error) && defined($after_error)) ? (abs($before_error)-abs($after_error)) : undef;
		 my $ineffective=0;
		 $ineffective=1 if(defined($observed_change) && abs($prev_delta) >= 0.2499 && $observed_change < 0.35);
		 $ineffective=1 if(defined($improvement) && $improvement <= 0.05 && abs($prev_delta) >= 0.2499);
		 $stalls=0 if(!defined($stalls));
		 my $cap=abs($lum_pct) >= 10 ? 8 : (abs($lum_pct) >= 5 ? 6 : (abs($lum_pct) >= 2 ? 4 : 2));
		 $cap=4 if($cap > 4 && $stalls < 2 && !$ineffective);
		 my $raw_delta;
		 my $weak_response=0;
			 if(abs($slope) >= 0.05) {
			  $raw_delta=-($lum_pct+0)/$slope;
			 } else {
			  $weak_response=1;
			  my $direction=($lum_pct > 0) ? -1 : 1;
			  $raw_delta=$direction*$cap;
			 }
			 my $expected_direction=lg_autocal_26_expected_headroom_luminance_direction($step,$lum_pct,0.35);
			 if($expected_direction && $raw_delta*$expected_direction <= 0) {
			  trace_109($step,"adaptive_luminance_wrong_direction",{
			   luminance_error_pct=>$lum_pct+0,
			   slope=>$slope+0,
			   planned_delta=>$raw_delta+0,
			   expected_direction=>$expected_direction+0,
			   previous_delta=>$prev_delta+0,
			   previous_before_error=>$before_error,
			   previous_after_error=>$after_error,
			   source=>$source||"adaptive_headroom_luminance"
			  });
			  return undef;
			 }
			 my $min_escalated=0;
			 if(($ineffective || $weak_response) && abs($prev_delta) >= 0.2499) {
			  $min_escalated=abs($prev_delta)*2;
			  $min_escalated=$cap if($min_escalated > $cap);
			  if(abs($raw_delta) < $min_escalated) {
		   my $direction=($raw_delta < 0) ? -1 : 1;
		   $direction=(($lum_pct > 0) ? -1 : 1) if(abs($raw_delta) < 0.0001);
		   $raw_delta=$direction*$min_escalated;
		  }
		 }
		 $raw_delta=$cap if($raw_delta > $cap);
		 $raw_delta=-$cap if($raw_delta < -$cap);
		 return undef if(abs($raw_delta) < 0.20);
		 foreach my $scale (1,0.75,0.50,0.25) {
		  my $next=round_ddc_quarter($current+($raw_delta*$scale));
			  next if(abs($next-$current) < 0.1999);
			  next if(tried_value_exists($tried,"adjustingLuminance",$next));
			  next if(luma_probe_family_suppressed($tried,$target,$current,$next,$step,$source||"adaptive_headroom_luminance",$state));
			  my $actual_delta=$next-$current;
			  next if($expected_direction && $actual_delta*$expected_direction <= 0);
			  my $predicted=(abs($slope) >= 0.05) ? (($lum_pct+0)+($slope*$actual_delta)) : undef;
			  return [{ channel=>"lum", setting=>"adjustingLuminance", current=>$current, next=>$next, delta=>$actual_delta, adaptive_luminance=>1, headroom_luminance=>1, response_model=>1, slope=>$slope, predicted_error=>$predicted, previous_delta=>$prev_delta+0, previous_before_error=>$before_error, previous_after_error=>$after_error, insufficient_luminance_response=>($ineffective||$weak_response)?1:0, source=>$source||"adaptive_headroom_luminance" }];
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
	  my $ddc_per_error=(abs($slope) >= 0.000001) ? (1/$slope) : undef;
	  return [{ channel=>$ch, setting=>$setting, current=>$current, next=>$next, delta=>$actual_delta, response_model=>1, learned_response_model=>1, slope=>$slope, ddc_per_error=>defined($ddc_per_error)?$ddc_per_error:undef, predicted_error=>$predicted, source=>$source||"learned_rgb", samples=>$entry->{"samples"}||1 }];
	 }
	 return undef;
	}

sub lg_autocal_26_response_axis_entry {
 my ($state,$step,$group,$axis)=@_;
 my $model=lg_autocal_26_response_model_for_step($state,$step);
 return undef if(ref($model) ne "HASH" || ref($model->{$group}) ne "HASH");
 my $entry=$model->{$group}{$axis};
 return (ref($entry) eq "HASH") ? $entry : undef;
}

sub lg_autocal_26_response_axis_samples {
 my ($state,$step,$group,$axis)=@_;
 my $entry=lg_autocal_26_response_axis_entry($state,$step,$group,$axis);
 return 0 if(ref($entry) ne "HASH");
 return $entry->{"samples"} ? ($entry->{"samples"}+0) : 0;
}

sub lg_autocal_26_initial_target_move_active {
 my ($iter,$iteration_limit,$stalls,$step,$de,$target_delta)=@_;
 return 0 if(ref($step) ne "HASH");
 return 0 if(autocal_step_is_peak_headroom($step));
 $iter=0 if(!defined($iter));
 $iteration_limit=0 if(!defined($iteration_limit));
 $stalls=0 if(!defined($stalls));
 $target_delta=0.5 if(!defined($target_delta) || $target_delta <= 0);
 my $remaining_pct=100;
 if($iteration_limit > 0) {
  $remaining_pct=(($iteration_limit-$iter+1)/$iteration_limit)*100;
 }
 return 1 if($stalls >= 2);
 return 1 if($iteration_limit > 0 && $remaining_pct <= 35);
 return 1 if(autocal_step_is_low_shadow($step) && defined($de) && $de > $target_delta+1.0 && $iter >= 4);
 return 1 if(legal_white_pair_side_ire($step) && defined($de) && $de > $target_delta+0.50 && $iter >= 6);
 return 0;
}

sub lg_autocal_26_initial_target_move_cap {
 my ($step,$setting,$lum_pct,$de,$target_delta)=@_;
 my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : 50;
 my $is_luma=($setting||"") eq "adjustingLuminance" ? 1 : 0;
 if($ire >= 99 && $ire <= 105.0001) {
  return $is_luma ? 1.50 : 0.75;
 }
 if($ire <= 4.1001) {
  return $is_luma ? 0.75 : 0.50;
 }
 if($ire <= 5.1001) {
  return $is_luma ? 1.00 : 0.75;
 }
 if($ire <= 10.0001) {
  return $is_luma ? 1.25 : 0.75;
 }
 return $is_luma ? 2.00 : 1.00;
}

sub annotate_lg_autocal_26_initial_target_move {
 my ($adjustments,$reason,$activation,$remaining_pct)=@_;
 return $adjustments if(ref($adjustments) ne "ARRAY");
 foreach my $adj (@{$adjustments}) {
  next if(ref($adj) ne "HASH");
  $adj->{"learned_target_move"}=1;
  $adj->{"target_move_reason"}=$reason if(defined($reason));
  $adj->{"activation_reason"}=$activation if(defined($activation));
  $adj->{"remaining_budget_pct"}=$remaining_pct+0 if(defined($remaining_pct));
 }
 return $adjustments;
}

sub lg_autocal_26_initial_learned_target_adjustments {
 my ($state,$arrays,$target,$step,$reading,$de,$target_delta,$lum_pct,$tried,$iter,$iteration_limit,$stalls,$paired_white_step)=@_;
 return undef if(ref($state) ne "HASH" || ref($arrays) ne "HASH" || ref($target) ne "HASH" || ref($step) ne "HASH" || ref($reading) ne "HASH");
 return undef if(!lg_autocal_26_initial_target_move_active($iter,$iteration_limit,$stalls,$step,$de,$target_delta));
 $target_delta=0.5 if(!defined($target_delta) || $target_delta <= 0);
 my $remaining_pct=100;
 $remaining_pct=(($iteration_limit-$iter+1)/$iteration_limit)*100 if(defined($iteration_limit) && $iteration_limit > 0);
 my $activation=($stalls >= 2) ? "stalled" : (($remaining_pct <= 35) ? "late_budget" : "high_error");
 my $tol=luminance_tolerance_percent($step);
 my $luma_far=(defined($lum_pct) && defined($tol) && abs($lum_pct) > ($tol*1.10)) ? 1 : 0;
 my $luma_very_far=(defined($lum_pct) && defined($tol) && abs($lum_pct) > ($tol*1.75)) ? 1 : 0;
 my $error=autocal_adjustment_error($reading,$step);
	 my $hdr20_chroma_priority=hdr20_top_white_chroma_priority_needed($step,$error,$de,$target_delta) || hdr20_body_chroma_priority_needed($step,$error,$de,$target_delta);
 if($luma_far && !$hdr20_chroma_priority && lg_autocal_26_response_axis_samples($state,$step,"luminance","adjustingLuminance") >= 2) {
  my $cap=lg_autocal_26_initial_target_move_cap($step,"adjustingLuminance",$lum_pct,$de,$target_delta);
  my $adjustments=lg_autocal_26_learned_luminance_adjustment($state,$arrays,$target,$step,$lum_pct,$tried,$cap,"initial_learned_luminance");
  return annotate_lg_autocal_26_initial_target_move($adjustments,"luminance",$activation,$remaining_pct) if(ref($adjustments) eq "ARRAY");
  return undef if(autocal_step_is_low_shadow($step) && $luma_very_far);
 }
 return undef if(!$hdr20_chroma_priority && hdr20_top_white_luminance_priority_needed($step,$lum_pct,0.35));
 my ($ch,$err,$max_err)=furthest_rgb_error_channel($error);
 if($ch && lg_autocal_26_response_axis_samples($state,$step,"rgb",$ch) >= 2) {
  my $threshold=rgb_response_close_threshold($de,$target_delta);
  my $chroma_allowed=1;
  $chroma_allowed=0 if(autocal_step_is_low_shadow($step) && $luma_very_far);
  $chroma_allowed=0 if($paired_white_step && $luma_very_far && defined($de) && $de <= $target_delta+0.75);
  if($chroma_allowed && $max_err >= $threshold) {
   my $setting=channel_setting($ch);
   my $cap=lg_autocal_26_initial_target_move_cap($step,$setting,$lum_pct,$de,$target_delta);
   my $adjustments=lg_autocal_26_learned_rgb_adjustment($state,$arrays,$target,$step,$reading,$de,$target_delta,$tried,$cap,"initial_learned_rgb");
   return annotate_lg_autocal_26_initial_target_move($adjustments,"rgb",$activation,$remaining_pct) if(ref($adjustments) eq "ARRAY");
  }
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

sub apply_lg_autocal_26_best_known_values_to_target {
		 my ($arrays,$target,$entry)=@_;
		 return 0 if(!lg_autocal_26_best_known_values_available($entry,$target,$arrays));
	 my $idx=$target->{"index"};
	 my $applied=0;
	 foreach my $setting (qw(whiteBalanceRed whiteBalanceGreen whiteBalanceBlue adjustingLuminance)) {
	  next if(!exists($entry->{"ddc_values"}{$setting}));
	  next if(ref($arrays->{$setting}) ne "ARRAY" || $idx >= @{$arrays->{$setting}});
	  $arrays->{$setting}[$idx]=$entry->{"ddc_values"}{$setting}+0;
	  $applied++;
	 }
		 return $applied;
		}

sub lg_autocal_26_legal_white_seed_source_gate {
 my ($entry,$target_delta)=@_;
 $target_delta=0.5 if(!defined($target_delta) || $target_delta <= 0);
 my $delta_limit=($target_delta*2 > 1.25) ? ($target_delta*2) : 1.25;
 my $luma_limit=2.0;
 my %decision=(
  accepted=>JSON::PP::false,
  reason=>"missing_final_best_source",
  delta_e_limit=>$delta_limit+0,
  luminance_error_limit_pct=>$luma_limit+0
 );
 return \%decision if(ref($entry) ne "HASH");
 my $de=defined($entry->{"delta_e"}) ? ($entry->{"delta_e"}+0) : undef;
 my $lum_pct=defined($entry->{"luminance_error_pct"}) ? ($entry->{"luminance_error_pct"}+0) : undef;
 my $reached=$entry->{"reached_target"} ? 1 : 0;
 $decision{"source_delta_e"}=$de if(defined($de));
 $decision{"source_luminance_error_pct"}=$lum_pct if(defined($lum_pct));
 $decision{"source_reached_target"}=$reached ? JSON::PP::true : JSON::PP::false;
 if(!defined($de)) {
  $decision{"reason"}="missing_source_delta_e";
  return \%decision;
 }
 if(!defined($lum_pct)) {
  $decision{"reason"}="missing_source_luminance_error";
  return \%decision;
 }
 my $de_ok=($de <= $delta_limit) ? 1 : 0;
 my $luma_ok=(abs($lum_pct) <= $luma_limit) ? 1 : 0;
 $decision{"source_delta_e_ok"}=$de_ok ? JSON::PP::true : JSON::PP::false;
 $decision{"source_luminance_error_ok"}=$luma_ok ? JSON::PP::true : JSON::PP::false;
 if($luma_ok && ($reached || $de_ok)) {
  $decision{"accepted"}=JSON::PP::true;
  $decision{"reason"}=$reached ? "source_reached_target" : "source_within_seed_gate";
  return \%decision;
 }
 $decision{"reason"}=$luma_ok ? "source_delta_e_exceeds_gate" : "source_luminance_error_exceeds_gate";
 return \%decision;
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

sub headroom_105_luminance_progress_working_state {
	 my ($step,$arrays,$target,$tried,$lum_pct,$best_lum_pct,$de,$best_de,$candidate_score,$best_score)=@_;
	 return 0 if(!headroom_105_post_seed_body_refinement($step,$arrays,$target,$tried));
	 return 0 if(!defined($lum_pct) || !defined($best_lum_pct) || !defined($de) || !defined($best_de));
	 return 0 if($lum_pct <= 0 || $best_lum_pct <= 0);
	 my $candidate_abs=abs($lum_pct);
	 my $best_abs=abs($best_lum_pct);
	 return 0 if($candidate_abs+0.50 >= $best_abs);
	 my $far_luma=($best_lum_pct > headroom_luminance_control_gate_percent($step,3.0)) ? 1 : 0;
	 my $near_target=($candidate_abs <= luminance_tolerance_percent($step) && $best_abs > luminance_tolerance_percent($step)) ? 1 : 0;
	 my $de_allowance=$near_target ? 4.00 : ($far_luma ? 2.50 : 1.25);
	 my $score_allowance=$near_target ? 3.00 : ($far_luma ? 1.00 : 0.25);
	 return 0 if($de > $best_de+$de_allowance);
	 return 0 if(defined($candidate_score) && defined($best_score) && $candidate_score > $best_score+$score_allowance);
	 return 1;
}

sub headroom_105_near_y_cleanup_gate_percent {
	 my ($step)=@_;
	 my $gate=luminance_tolerance_percent($step)*2.0;
	 $gate=1.5 if($gate < 1.5);
	 $gate=2.0 if($gate > 2.0);
	 return $gate;
}

sub headroom_105_near_y_luminance {
	 my ($step,$lum_pct)=@_;
	 return 0 if(!defined($lum_pct));
	 return abs($lum_pct) <= headroom_105_near_y_cleanup_gate_percent($step) ? 1 : 0;
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
 return undef if(ref($config) ne "HASH");
 return undef if(ref($target) ne "HASH" || !defined($target->{"ire"}));
 return undef if(ref($step) ne "HASH" || $step->{"autocal_white_reference"});
 return undef if(ref($steps) ne "ARRAY");
 if(lg_autocal_26_sdr_headroom_enabled($config)) {
  # Full-DDC spine still needs the hidden 100% legal-white read while solving
  # the shared 99% LG DDC slot. Otherwise 99 can look clean while the user's
  # visible 100% white read keeps a red/blue imbalance.
  return undef if(abs(($target->{"ire"}+0)-99) > 0.001);
  foreach my $candidate (@{$steps}) {
   next if(ref($candidate) ne "HASH" || !$candidate->{"autocal_white_reference"});
   my $candidate_target=ddc_target_for_step($candidate);
   next if(!$candidate_target || abs(($candidate_target->{"ire"}+0)-99) > 0.001);
   return $candidate;
  }
  return undef;
 }
 if(lg_autocal_26_hdr20_seed_enabled($config) && hdr20_shared_top_white_pair_target($target)) {
  foreach my $candidate (@{$steps}) {
   next if(ref($candidate) ne "HASH" || $candidate->{"autocal_reference_only"} || $candidate->{"autocal_read_only"});
   next if(!defined($candidate->{"ire"}) || abs(($candidate->{"ire"}+0)-100) > 0.02);
   my $candidate_target=ddc_target_for_step($candidate);
   next if(!$candidate_target || abs(($candidate_target->{"array_ire"}+0)-100) > 0.02);
   return $candidate;
  }
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
 my $rgb_a=legal_white_pair_rgb_imbalance($reading_a,$step_a);
 my $rgb_b=legal_white_pair_rgb_imbalance($reading_b,$step_b);
 my $worst_rgb=$rgb_a > $rgb_b ? $rgb_a : $rgb_b;
 my $white_rgb=autocal_step_is_white($step_a) ? $rgb_a : (autocal_step_is_white($step_b) ? $rgb_b : $worst_rgb);
 return ($worst*1.40)+($best*0.18)+($pair_avg*0.12)+($spread*1.20)+($worst_rgb*0.30)+($white_rgb*0.45);
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

sub legal_white_pair_rgb_imbalance {
 my ($reading,$step)=@_;
 return 0 if(ref($reading) ne "HASH" || ref($step) ne "HASH");
 my $error=autocal_adjustment_error($reading,$step);
 return 0 if(ref($error) ne "HASH");
 my $max=chroma_error_magnitude($error);
 return 0 if(!defined($max) || $max >= 999);
 return $max*50;
}

sub legal_white_pair_side_ire {
	 my ($step)=@_;
	 return undef if(ref($step) ne "HASH");
	 if(defined($step->{"ire"})) {
	  my $ire=$step->{"ire"}+0;
	  return 95 if(abs($ire-94.98) < 0.02);
	  return 99 if(abs($ire-99) < 0.001);
	  return 100 if(abs($ire-100) < 0.001);
	 }
	 return 100 if(autocal_step_is_white($step));
	 return undef;
}

sub legal_white_pair_side_metrics {
	 my ($de_a,$lum_a,$step_a,$reading_a,$de_b,$lum_b,$step_b,$reading_b)=@_;
	 my %out;
	 foreach my $entry (
	  [ $de_a,$lum_a,$step_a,$reading_a ],
	  [ $de_b,$lum_b,$step_b,$reading_b ]
	 ) {
	  my ($de,$lum,$step,$reading)=@{$entry};
	  my $ire=legal_white_pair_side_ire($step);
	  next if(!defined($ire));
	  $out{$ire}={
	   delta_e=>$de,
	   luminance_error_pct=>$lum,
	   rgb_imbalance=>legal_white_pair_rgb_imbalance($reading,$step),
	   step=>$step
	  };
	 }
	 return \%out;
}

sub legal_white_pair_metric_delta {
	 my ($metrics,$ire)=@_;
	 return undef if(ref($metrics) ne "HASH" || ref($metrics->{$ire}) ne "HASH");
	 return defined($metrics->{$ire}{"delta_e"}) ? $metrics->{$ire}{"delta_e"}+0 : undef;
}

sub legal_white_pair_metric_rgb_imbalance {
	 my ($metrics,$ire)=@_;
	 return undef if(ref($metrics) ne "HASH" || ref($metrics->{$ire}) ne "HASH");
	 return defined($metrics->{$ire}{"rgb_imbalance"}) ? $metrics->{$ire}{"rgb_imbalance"}+0 : undef;
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
		 return 5 if($worst > 3.0);
		 return 6 if($worst > 1.5);
		 return 8 if($worst > 1.0);
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
	 my $neutral=neutral_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,0.25,$max_step,1,$step,($micro ? "fine_paired_luminance" : "main_paired_luminance"));
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
				 if(lg_autocal_26_full_ddc_spine_enabled($config)) {
				  return 22 if(lg_autocal_26_full_ddc_spine_body_anchor($step));
				  return 12 if(ref($step) eq "HASH" && defined($step->{"ire"}));
				 }
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

sub clear_committed_measurement_state {
 my ($state,$clear_pair)=@_;
 return if(ref($state) ne "HASH");
 foreach my $key (qw(current_delta_e current_luminance luminance_error_pct target_step_luminance)) {
  delete $state->{$key};
 }
 if($clear_pair) {
  foreach my $key (qw(paired_delta_e paired_luminance_error_pct paired_target_luminance paired_current_name)) {
   delete $state->{$key};
  }
 }
}

sub prepare_standalone_committed_off_cal_read {
 my ($config,$state,$picture_mode,$step,$reason,$settle_key,$default_ms)=@_;
 return if(!lg_autocal_26_standalone_committed_cleanup_enabled($config));
 end_calibration_mode($picture_mode);
 set_state_calibration_mode($state,0,"");
 my $settle_ms=config_positive_int($config,$settle_key||"post_commit_read_cal_off_settle_ms",defined($default_ms)?$default_ms:3500,0,30000);
 trace_109($step,"committed_read_calibration_off",{
  reason=>defined($reason)?$reason:"",
  settle_ms=>$settle_ms+0
 });
 select(undef,undef,undef,$settle_ms/1000) if($settle_ms > 0);
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
 my $insert_code=64;
 my $payload={
  name => "patch",
  r => $insert_code,
  g => $insert_code,
  b => $insert_code,
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

sub tried_setting_value_count {
	 my ($tried,$setting)=@_;
	 return 0 if(ref($tried) ne "HASH" || ref($tried->{$setting}) ne "HASH");
	 return scalar keys %{$tried->{$setting}};
}

sub exhaust_adjustment_next_values {
	 my ($tried,$adjustments,$de)=@_;
	 return 0 if(ref($tried) ne "HASH" || ref($adjustments) ne "ARRAY");
 my $count=0;
 foreach my $adj (@{$adjustments}) {
  next if(ref($adj) ne "HASH");
  my $setting=$adj->{"setting"};
  my $next=$adj->{"next"};
  next if(!defined($setting) || !defined($next));
  $tried->{$setting}={} if(ref($tried->{$setting}) ne "HASH");
  my $key=ddc_value_key($next);
  my $prior=(ref($tried->{$setting}{$key}) eq "HASH") ? (($tried->{$setting}{$key}->{"count"}||0)+0) : 0;
  $tried->{$setting}{$key}={
   count => $prior >= 2 ? $prior : 2,
   de => defined($de) ? $de+0 : undef,
   rejected => JSON::PP::true,
  };
  $count++;
 }
 return $count;
}

sub clone_arrays {
	 my ($arrays)=@_;
	 return decode_json_safe($json->encode($arrays||{}),{});
}

sub lg_autocal_26_lut_indexes {
 my ($layout)=@_;
 $layout=lc($layout||$LG_AUTOCAL_DDC_LAYOUT||"sdr26");
 return ddc_slots_for_layout("hdr20") if($layout eq "hdr20");
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
 return grep { $calibrated{format_percent($_)} } lg_autocal_26_full_ddc_spine_anchor_ddc_ires();
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

sub ddc_slot_index_for_ire {
 my ($wanted_ire)=@_;
 return undef if(!defined($wanted_ire));
 my @slots=ddc_slots();
 for(my $idx=0;$idx<@slots;$idx++) {
  return $idx if(abs(($wanted_ire+0)-($slots[$idx]+0)) < 0.001);
 }
 return undef;
}

sub copy_lg_26pt_ddc_slot_values {
 my ($arrays,$source_ire,$target_ire,$copy_luminance)=@_;
 return 0 if(ref($arrays) ne "HASH");
 my $source_idx=ddc_slot_index_for_ire($source_ire);
 my $target_idx=ddc_slot_index_for_ire($target_ire);
 return 0 if(!defined($source_idx) || !defined($target_idx));
 my @settings=ddc_adjustment_settings($arrays);
 my (%source,%before,%after,%changed_settings);
 my $copied=0;
 my $changed=0;
 foreach my $setting (@settings) {
  next if($setting eq "adjustingLuminance" && !$copy_luminance);
  my $arr=$arrays->{$setting};
  next if(ref($arr) ne "ARRAY" || $source_idx >= @{$arr} || $target_idx >= @{$arr});
  my $source_value=defined($arr->[$source_idx]) ? ($arr->[$source_idx]+0) : 0;
  my $before_value=defined($arr->[$target_idx]) ? ($arr->[$target_idx]+0) : 0;
  my $after_value=clamp_ddc_value($source_value);
  $source{$setting}=$source_value+0;
  $before{$setting}=$before_value+0;
  $arr->[$target_idx]=$after_value;
  $after{$setting}=$after_value+0;
  $copied++;
  if(abs($after_value-$before_value) > 0.0001) {
   $changed++;
   $changed_settings{$setting}={ before=>$before_value+0, after=>$after_value+0 };
  }
 }
 return 0 if(!$copied);
 return {
  mode=>"adjacent-anchor-copy",
  source_index=>$source_idx+0,
  source_ire=>$source_ire+0,
  target_index=>$target_idx+0,
  target_ire=>$target_ire+0,
  copied_settings=>$copied+0,
  changed_settings_count=>$changed+0,
  copy_luminance=>$copy_luminance ? JSON::PP::true : JSON::PP::false,
  source=>\%source,
  before=>\%before,
  after=>\%after,
  changed_settings=>\%changed_settings
 };
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

sub calibrated_26pt_slot_for_ire {
 my ($calibrated_slot_mask,$ire)=@_;
 return 0 if(ref($calibrated_slot_mask) ne "ARRAY" || !defined($ire));
 my $idx=ddc_slot_index_for_ire($ire);
 return 0 if(!defined($idx));
 return $calibrated_slot_mask->[$idx] ? 1 : 0;
}

sub full_ddc_spine_shadow_seed_links {
 return (
  { source=>20, target=>15, offsets=>{ adjustingLuminance=>-0.50, whiteBalanceRed=>-0.40, whiteBalanceGreen=>-0.60, whiteBalanceBlue=>-0.60 } },
  { source=>15, target=>10, offsets=>{ adjustingLuminance=> 3.50, whiteBalanceRed=>-0.10, whiteBalanceGreen=> 0.50, whiteBalanceBlue=> 0.40 } },
  { source=>10, target=>7,  offsets=>{ adjustingLuminance=> 2.25, whiteBalanceRed=>-0.10, whiteBalanceGreen=> 0.20, whiteBalanceBlue=> 2.50 } },
  { source=>7,  target=>5,  offsets=>{ adjustingLuminance=> 3.25, whiteBalanceRed=>-0.60, whiteBalanceGreen=>-0.10, whiteBalanceBlue=> 2.00 } },
  { source=>5,  target=>4,  offsets=>{ adjustingLuminance=>-0.50, whiteBalanceRed=> 0.65, whiteBalanceGreen=> 0.30, whiteBalanceBlue=>-0.20 } },
  { source=>4,  target=>3,  offsets=>{ adjustingLuminance=> 1.00, whiteBalanceRed=>-0.60, whiteBalanceGreen=> 0.40, whiteBalanceBlue=> 1.75 } },
  { source=>3,  target=>2.3,offsets=>{ adjustingLuminance=> 3.25, whiteBalanceRed=> 0.00, whiteBalanceGreen=> 0.60, whiteBalanceBlue=> 0.00 } },
 );
}

sub apply_full_ddc_spine_shadow_seeds {
 my ($config,$arrays,$calibrated_slot_mask)=@_;
 return 0 if(!lg_autocal_26_full_ddc_spine_enabled($config));
 return 0 if(lg_autocal_26_hdr20_seed_enabled($config));
 return 0 if(ref($arrays) ne "HASH" || ref($calibrated_slot_mask) ne "ARRAY");
 return 0 if(!calibrated_26pt_slot_for_ire($calibrated_slot_mask,20));
 my $changed=0;
 foreach my $link (full_ddc_spine_shadow_seed_links()) {
  next if(ref($link) ne "HASH" || ref($link->{"offsets"}) ne "HASH");
  my $source_idx=ddc_slot_index_for_ire($link->{"source"});
  my $target_idx=ddc_slot_index_for_ire($link->{"target"});
  next if(!defined($source_idx) || !defined($target_idx));
  next if($calibrated_slot_mask->[$target_idx]);
  foreach my $setting (qw(whiteBalanceRed whiteBalanceGreen whiteBalanceBlue adjustingLuminance)) {
   next if(!defined($link->{"offsets"}{$setting}));
   next if(ref($arrays->{$setting}) ne "ARRAY" || $source_idx >= @{$arrays->{$setting}} || $target_idx >= @{$arrays->{$setting}});
   next if(!defined($arrays->{$setting}[$source_idx]));
   my $before=defined($arrays->{$setting}[$target_idx]) ? ($arrays->{$setting}[$target_idx]+0) : 0;
   my $after=clamp_ddc_value(($arrays->{$setting}[$source_idx]+0)+($link->{"offsets"}{$setting}+0));
   $after=round_ddc_quarter($after);
   next if(abs($after-$before) < 0.0001);
   $arrays->{$setting}[$target_idx]=$after;
   $changed++;
  }
 }
 return $changed;
}

sub full_ddc_spine_seed_correction_deltas {
 my ($ire,$calibrated_slot_mask)=@_;
 return undef if(!defined($ire));
 my $key=format_percent($ire);
 if(calibrated_26pt_slot_for_ire($calibrated_slot_mask,105)) {
  my %post_105_deltas=(
   "99" => { adjustingLuminance => 1.20, whiteBalanceRed => 7.50, whiteBalanceGreen => 5.50, whiteBalanceBlue => 5.30 },
   "95" => { adjustingLuminance => 1.00, whiteBalanceRed => 6.10, whiteBalanceGreen => 4.10, whiteBalanceBlue => 3.80 },
   "90" => { adjustingLuminance => 0.65, whiteBalanceRed => 4.30, whiteBalanceGreen => 2.55, whiteBalanceBlue => 2.60 },
  );
  return $post_105_deltas{$key} if($key eq "99");
  return undef if($key eq "95" && calibrated_26pt_slot_for_ire($calibrated_slot_mask,99));
  return undef if($key eq "90" && (calibrated_26pt_slot_for_ire($calibrated_slot_mask,95) || calibrated_26pt_slot_for_ire($calibrated_slot_mask,99)));
  return $post_105_deltas{$key} if(exists($post_105_deltas{$key}));
 }
 my %deltas=(
  "105" => { adjustingLuminance => -4.90 },
  "99"  => { adjustingLuminance => -3.25, whiteBalanceRed => -2.00, whiteBalanceGreen => 5.50, whiteBalanceBlue => 5.50 },
  "95"  => { adjustingLuminance => -2.40, whiteBalanceRed => -1.40, whiteBalanceGreen => 4.25, whiteBalanceBlue => 4.50 },
  "90"  => { adjustingLuminance => -1.45, whiteBalanceRed => -0.80, whiteBalanceGreen => 2.60, whiteBalanceBlue => 3.00 },
 );
 return $deltas{$key};
}

sub apply_full_ddc_spine_seed_corrections {
 my ($config,$arrays,$calibrated_slot_mask)=@_;
 return 0 if(!lg_autocal_26_full_ddc_spine_enabled($config));
 return 0 if(lg_autocal_26_hdr20_seed_enabled($config));
 return 0 if(ref($arrays) ne "HASH" || ref($calibrated_slot_mask) ne "ARRAY");
 my $changed=0;
 $changed+=apply_full_ddc_spine_shadow_seeds($config,$arrays,$calibrated_slot_mask);
 foreach my $ire (qw(105 99 95 90)) {
  my $idx=ddc_slot_index_for_ire($ire);
  next if(!defined($idx) || $calibrated_slot_mask->[$idx]);
  my $deltas=full_ddc_spine_seed_correction_deltas($ire,$calibrated_slot_mask);
  next if(ref($deltas) ne "HASH");
  if(abs(($ire+0)-105) < 0.001) {
   my $seed=headroom_105_hard_seed_values();
   if(ref($seed) eq "HASH") {
    foreach my $setting (qw(whiteBalanceRed whiteBalanceGreen whiteBalanceBlue)) {
     next if(ref($arrays->{$setting}) ne "ARRAY" || $idx >= @{$arrays->{$setting}});
     next if(!defined($seed->{$setting}));
     my $before=defined($arrays->{$setting}[$idx]) ? ($arrays->{$setting}[$idx]+0) : 0;
     my $after=clamp_ddc_value($seed->{$setting});
     next if(abs($after-$before) < 0.0001);
     $arrays->{$setting}[$idx]=$after;
     $changed++;
    }
   }
  }
  foreach my $setting (qw(whiteBalanceRed whiteBalanceGreen whiteBalanceBlue adjustingLuminance)) {
   next if(!defined($deltas->{$setting}));
   next if(ref($arrays->{$setting}) ne "ARRAY" || $idx >= @{$arrays->{$setting}});
   my $before=defined($arrays->{$setting}[$idx]) ? ($arrays->{$setting}[$idx]+0) : 0;
   my $after=clamp_ddc_value($before+($deltas->{$setting}+0));
   next if(abs($after-$before) < 0.0001);
   $arrays->{$setting}[$idx]=$after;
   $changed++;
  }
 }
 return $changed;
}

sub apply_full_ddc_spine_headroom_seed_overrides {
 return apply_full_ddc_spine_seed_corrections(@_);
}

sub refresh_propagated_uncalibrated_26pt_slots {
	 my ($config,$arrays,$calibrated_slot_mask)=@_;
	 return 0 if(ref($config) ne "HASH" || !$config->{"lg_autocal_26"});
	 my $hdr20_seed=lg_autocal_26_hdr20_seed_enabled($config);
	 return 0 if(lc($config->{"signal_mode"}||"sdr") eq "hdr10" && !$hdr20_seed);
	 my $minimum_anchors=3;
	 my $source_slot_mask=$calibrated_slot_mask;
	 if($hdr20_seed) {
	  $minimum_anchors=2;
	 }
	 if(lg_autocal_26_full_ddc_spine_enabled($config)) {
	  my @completed=completed_lg_autocal_26_full_ddc_spine_anchor_ires($calibrated_slot_mask);
	  my @anchors=lg_autocal_26_full_ddc_spine_anchor_ires();
	  $minimum_anchors=scalar(@anchors);
	  return 0 if(scalar(@completed) < $minimum_anchors);
	 }
 if(lg_autocal_26_anchor_predrive_enabled($config)) {
  $minimum_anchors=lg_autocal_26_anchor_predrive_anchor_count();
  $source_slot_mask=lg_autocal_26_anchor_predrive_source_slot_mask($calibrated_slot_mask);
 }
	 return 0 if(calibrated_non_black_26pt_anchor_count($source_slot_mask) < $minimum_anchors);
	 my $filled=propagate_uncalibrated_26pt_slots($arrays,$calibrated_slot_mask,$source_slot_mask);
	 my $overrides=apply_full_ddc_spine_headroom_seed_overrides($config,$arrays,$calibrated_slot_mask);
	 return $filled+$overrides;
	}

sub lg_autocal_26_seeded_move_damping_ready {
	 my ($config,$calibrated_slot_mask)=@_;
	 return 0 if(ref($config) ne "HASH" || !$config->{"lg_autocal_26"});
	 return 0 if(ref($calibrated_slot_mask) ne "ARRAY");
	 if(lg_autocal_26_anchor_predrive_enabled($config)) {
	  my @completed=completed_lg_autocal_26_anchor_predrive_anchor_ires($calibrated_slot_mask);
	  return scalar(@completed) >= lg_autocal_26_anchor_predrive_anchor_count() ? 1 : 0;
	 }
	 if(lg_autocal_26_full_ddc_spine_enabled($config)) {
	  my @completed=completed_lg_autocal_26_full_ddc_spine_anchor_ires($calibrated_slot_mask);
	  return scalar(@completed) >= lg_autocal_26_full_ddc_spine_anchor_count() ? 1 : 0;
	 }
	 return 0;
}

sub lg_autocal_26_seeded_move_damping_for_step {
	 my ($config,$target,$step,$calibrated_slot_mask,$seed_from_prior_slot)=@_;
	 return 0 if(ref($config) ne "HASH" || !$config->{"lg_autocal_26"});
	 return 0 if(ref($target) ne "HASH" || ref($step) ne "HASH");
	 return 0 if(strict_tried_for_step($step) || autocal_step_is_fast_headroom($step));
	 return 1 if(hdr20_shared_top_white_pair_step($target,$step));
	 return 1 if(lg_autocal_26_hdr20_seed_enabled($config) && autocal_step_is_hdr20_body($step) && $seed_from_prior_slot);
	 my $anchor_revisit=lg_autocal_26_full_ddc_spine_anchor_revisit_step($step);
	 return 0 if(lg_autocal_26_full_ddc_spine_enabled($config) && lg_autocal_26_full_ddc_spine_anchor($target) && !$anchor_revisit);
	 my $idx=$target->{"index"};
	 return 1 if($anchor_revisit);
	 return 0 if(!defined($idx) || (ref($calibrated_slot_mask) eq "ARRAY" && $calibrated_slot_mask->[$idx]));
	 my $mode_active=(lg_autocal_26_anchor_predrive_enabled($config) || lg_autocal_26_full_ddc_spine_enabled($config)) ? 1 : 0;
	 return 1 if($mode_active && $seed_from_prior_slot);
	 return 1 if($mode_active && lg_autocal_26_seeded_move_damping_ready($config,$calibrated_slot_mask));
	 return 0;
}

sub seed_target_from_prior_slot {
			 my ($arrays,$target,$calibrated_slot_mask,$config)=@_;
	 return 0 if(ref($arrays) ne "HASH" || ref($target) ne "HASH");
	 my $hdr20_seed=lg_autocal_26_hdr20_seed_enabled($config);
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
	  return 0 if($hdr20_seed && lg_autocal_26_full_ddc_spine_enabled($config));
	  my @probe_indices;
	  if($hdr20_seed) {
	   @probe_indices=($idx+1)..(ddc_slot_count()-1) if($idx+1 < ddc_slot_count());
	  } elsif(target_is_low_shadow_slot($target)) {
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
	   mode=>$hdr20_seed ? "hdr20-adjacent-copy" : "full-copy",
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

sub luma_probe_guarded_target {
 my ($target,$step)=@_;
 my $ire;
 $ire=$target->{"ire"} if(ref($target) eq "HASH" && defined($target->{"ire"}));
 $ire=$step->{"ire"} if(!defined($ire) && ref($step) eq "HASH" && defined($step->{"ire"}));
 return 0 if(!defined($ire));
 $ire+=0;
 return 1 if(abs($ire-105) < 0.001);
 return 1 if(abs($ire-99) < 0.001);
 return 1 if(abs($ire-100) < 0.001);
 return 0;
}

sub luma_probe_family_key {
	 my ($target,$current,$next,$step)=@_;
	 return undef if(!defined($current) || !defined($next));
	 my $target_key=luma_probe_target_key($target,$step);
	 return undef if(!defined($target_key));
	 my $delta=($next+0)-($current+0);
	 return undef if(abs($delta) < 0.0001);
	 my $direction=$delta < 0 ? -1 : 1;
	 my $magnitude=ddc_value_key(abs($delta));
	 return join("|",$target_key,ddc_value_key($current),$direction,$magnitude);
}

sub luma_probe_target_key {
 my ($target,$step)=@_;
 my $ire;
 $ire=$target->{"ire"} if(ref($target) eq "HASH" && defined($target->{"ire"}));
 $ire=$step->{"ire"} if(!defined($ire) && ref($step) eq "HASH" && defined($step->{"ire"}));
 return undef if(!defined($ire));
 return format_percent($ire);
}

sub luma_probe_state_family_store {
 my ($state,$target,$step,$create)=@_;
 $state=$LG_AUTOCAL_STATE if(ref($state) ne "HASH");
 return undef if(ref($state) ne "HASH");
 my $target_key=luma_probe_target_key($target,$step);
 return undef if(!defined($target_key));
 if(ref($state->{"lg_autocal_bad_luma_probe_families"}) ne "HASH") {
  return undef if(!$create);
  $state->{"lg_autocal_bad_luma_probe_families"}={};
 }
 if(ref($state->{"lg_autocal_bad_luma_probe_families"}{$target_key}) ne "HASH") {
  return undef if(!$create);
  $state->{"lg_autocal_bad_luma_probe_families"}{$target_key}={};
 }
 return $state->{"lg_autocal_bad_luma_probe_families"}{$target_key};
}

sub clone_luma_probe_entry {
 my ($entry)=@_;
 return {} if(ref($entry) ne "HASH");
 my %copy=%{$entry};
 return \%copy;
}

sub luma_probe_entry_suppressed {
 my ($entry)=@_;
 return 0 if(ref($entry) ne "HASH");
 return 1 if(($entry->{"severe_count"}||0) >= 1);
 return 1 if(($entry->{"count"}||0) >= 2);
 return 0;
}

sub luma_only_adjustment {
 my ($adjustments)=@_;
 return undef if(ref($adjustments) ne "ARRAY" || @{$adjustments} != 1);
 my $adj=$adjustments->[0];
 return undef if(ref($adj) ne "HASH");
 return undef if(($adj->{"setting"}||"") ne "adjustingLuminance");
 return $adj;
}

sub luma_probe_family_suppressed {
 my ($tried,$target,$current,$next,$step,$source,$state)=@_;
 return 0 if(!luma_probe_guarded_target($target,$step));
 my $key=luma_probe_family_key($target,$current,$next,$step);
 return 0 if(!defined($key));
 my @entries;
 push @entries,$tried->{"__bad_luma_family"}{$key}
  if(ref($tried) eq "HASH" && ref($tried->{"__bad_luma_family"}) eq "HASH" && ref($tried->{"__bad_luma_family"}{$key}) eq "HASH");
 my $state_store=luma_probe_state_family_store($state,$target,$step,0);
 push @entries,$state_store->{$key}
  if(ref($state_store) eq "HASH" && ref($state_store->{$key}) eq "HASH");
 foreach my $entry (@entries) {
  next if(!luma_probe_entry_suppressed($entry));
  my $trace_step=(ref($step) eq "HASH") ? $step : $target;
  trace_109($trace_step,"luma_probe_family_suppressed",{
   target=>luma_probe_target_key($target,$step),
   source=>$source||$entry->{"source"}||"luma_planner",
	   family_key=>$key,
	   current=>defined($current)?$current+0:undef,
	   next=>defined($next)?$next+0:undef,
	   magnitude=>defined($next)&&defined($current)?abs(($next+0)-($current+0)):undef,
	   direction=>defined($next)&&defined($current)?(($next-$current)<0?-1:1):undef,
   count=>$entry->{"count"}||0,
   severe_count=>$entry->{"severe_count"}||0,
   before_delta_e=>$entry->{"before_delta_e"},
   after_delta_e=>$entry->{"after_delta_e"},
   before_luminance_error_pct=>$entry->{"before_luminance_error_pct"},
   after_luminance_error_pct=>$entry->{"after_luminance_error_pct"},
   before_score=>$entry->{"before_score"},
   after_score=>$entry->{"after_score"}
  });
  return 1;
 }
 return 0;
}

sub record_bad_luma_probe_family {
 my ($tried,$target,$adjustments,$before_de,$after_de,$before_lum_pct,$after_lum_pct,$before_score,$after_score,$step,$source,$state)=@_;
 return undef if(ref($tried) ne "HASH" || !luma_probe_guarded_target($target,$step));
 return undef if(ref($step) eq "HASH" && autocal_step_is_peak_headroom($step));
 my $adj=luma_only_adjustment($adjustments);
 return undef if(ref($adj) ne "HASH");
 return undef if(!defined($before_de) || !defined($after_de));
 return undef if(!defined($before_lum_pct) || !defined($after_lum_pct));
	 my $before_abs=abs($before_lum_pct+0);
	 my $after_abs=abs($after_lum_pct+0);
	 my $y_improved=($after_abs + 0.10 < $before_abs) ? 1 : 0;
	 my $y_worse=($after_abs > $before_abs + 0.10) ? 1 : 0;
	 my $de_worse=(($after_de+0) > ($before_de+0)+0.35) ? 1 : 0;
	 my $score_worse=0;
	 $score_worse=1 if(defined($before_score) && defined($after_score) && ($after_score+0) > ($before_score+0)+0.35);
	 return undef if(!$y_worse && (!$y_improved || (!$de_worse && !$score_worse)));
 my $current=defined($adj->{"current"}) ? ($adj->{"current"}+0) : undef;
 my $next=defined($adj->{"next"}) ? ($adj->{"next"}+0) : undef;
 my $key=luma_probe_family_key($target,$current,$next,$step);
 return undef if(!defined($key));
	 my $severe=($y_worse || ($after_de+0) > ($before_de+0)+1.0 || (defined($before_score) && defined($after_score) && ($after_score+0) > ($before_score+0)+1.0)) ? 1 : 0;
 $tried->{"__bad_luma_family"}={} if(ref($tried->{"__bad_luma_family"}) ne "HASH");
 my $state_store=luma_probe_state_family_store($state,$target,$step,1);
 my $entry=clone_luma_probe_entry(
  ref($tried->{"__bad_luma_family"}{$key}) eq "HASH"
   ? $tried->{"__bad_luma_family"}{$key}
   : ((ref($state_store) eq "HASH" && ref($state_store->{$key}) eq "HASH") ? $state_store->{$key} : {})
 );
 $entry->{"count"}=($entry->{"count"}||0)+1;
 $entry->{"severe_count"}=($entry->{"severe_count"}||0)+($severe ? 1 : 0);
	 $entry->{"current"}=defined($current) ? $current+0 : undef;
	 $entry->{"next"}=defined($next) ? $next+0 : undef;
	 $entry->{"magnitude"}=abs(($next+0)-($current+0)) if(defined($current) && defined($next));
	 $entry->{"direction"}=(($next-$current) < 0) ? -1 : 1 if(defined($current) && defined($next));
 $entry->{"target"}=luma_probe_target_key($target,$step);
 $entry->{"source"}=$source||$adj->{"source"}||"luma_probe";
 $entry->{"before_delta_e"}=$before_de+0;
 $entry->{"after_delta_e"}=$after_de+0;
 $entry->{"before_luminance_error_pct"}=$before_lum_pct+0;
 $entry->{"after_luminance_error_pct"}=$after_lum_pct+0;
 $entry->{"before_score"}=$before_score+0 if(defined($before_score));
 $entry->{"after_score"}=$after_score+0 if(defined($after_score));
 $entry->{"family_key"}=$key;
 $tried->{"__bad_luma_family"}{$key}=clone_luma_probe_entry($entry);
 $state_store->{$key}=clone_luma_probe_entry($entry) if(ref($state_store) eq "HASH");
 $entry->{"suppressed"}=luma_probe_family_suppressed($tried,$target,$current,$next,$step,$source,$state) ? JSON::PP::true : JSON::PP::false;
 my $trace_step=(ref($step) eq "HASH") ? $step : $target;
 trace_109($trace_step,"bad_luma_probe",{
  target=>$entry->{"target"},
  source=>$entry->{"source"},
  family_key=>$key,
	  current=>defined($current)?$current+0:undef,
	  next=>defined($next)?$next+0:undef,
	  magnitude=>$entry->{"magnitude"},
	  direction=>$entry->{"direction"},
  count=>$entry->{"count"}||0,
  severe_count=>$entry->{"severe_count"}||0,
  before_delta_e=>$before_de+0,
  after_delta_e=>$after_de+0,
  before_luminance_error_pct=>$before_lum_pct+0,
  after_luminance_error_pct=>$after_lum_pct+0,
  before_score=>defined($before_score)?$before_score+0:undef,
  after_score=>defined($after_score)?$after_score+0:undef,
  suppressed=>$entry->{"suppressed"}
 });
 return $entry;
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

sub seeded_move_damping_cap {
	 my ($step,$error,$de,$target_delta,$stalls)=@_;
	 return undef if(ref($step) ne "HASH" || !$step->{"lg_autocal_26_seeded_move_damping"});
	 return undef if(strict_tried_for_step($step) || autocal_step_is_fast_headroom($step));
	 return undef if(!defined($de));
	 $target_delta=0.5 if(!defined($target_delta) || $target_delta <= 0);
	 $stalls=0 if(!defined($stalls));
	 return undef if($stalls >= 4);
	 my $chroma=chroma_error_magnitude($error);
	 my $cap;
	 if($de <= ($target_delta+0.50) && $chroma <= 0.012) {
	  $cap=0.25;
	 } elsif($de <= ($target_delta+1.25) && $chroma <= 0.020) {
	  $cap=0.50;
	 }
	 return undef if(!defined($cap));
	 $cap=0.50 if($stalls >= 2 && $cap < 0.50);
	 return $cap;
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

sub headroom_105_seed_luma_refine_cap {
	 my ($arrays,$target,$step,$luminance_err)=@_;
	 return undef if(!autocal_step_is_fast_headroom($step) || autocal_step_is_peak_headroom($step));
	 return undef if(ref($arrays) ne "HASH" || ref($target) ne "HASH");
	 return undef if(!defined($luminance_err) || $luminance_err <= 0);
	 my $ire=(defined($target->{"ire"}) ? ($target->{"ire"}+0) : ((ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : 0));
	 return undef if($ire < 104.5 || $ire >= 108.5);
	 my $idx=$target->{"index"};
	 return undef if(!defined($idx));
	 my $lum_arr=$arrays->{"adjustingLuminance"};
	 return undef if(ref($lum_arr) ne "ARRAY" || $idx >= @{$lum_arr});
	 my $current_luma=$lum_arr->[$idx]||0;
	 return undef if(abs($current_luma) > 0.0001);
	 return undef if(($luminance_err*100) <= headroom_luminance_control_gate_percent($step,0.65));
	 my $r_arr=$arrays->{"whiteBalanceRed"};
	 my $g_arr=$arrays->{"whiteBalanceGreen"};
	 my $b_arr=$arrays->{"whiteBalanceBlue"};
	 return undef if(ref($r_arr) ne "ARRAY" || ref($g_arr) ne "ARRAY" || ref($b_arr) ne "ARRAY");
	 return undef if($idx >= @{$r_arr} || $idx >= @{$g_arr} || $idx >= @{$b_arr});
	 my $r=$r_arr->[$idx]||0;
	 my $g=$g_arr->[$idx]||0;
	 my $b=$b_arr->[$idx]||0;
	 my $seed=headroom_105_hard_seed_values();
	 return undef if(abs($r-($seed->{"whiteBalanceRed"}+0)) > 0.7501 || abs($g-($seed->{"whiteBalanceGreen"}+0)) > 0.7501 || abs($b-($seed->{"whiteBalanceBlue"}+0)) > 1.0001);
	 return 1.0;
}

sub headroom_105_hard_seed_values {
	 return weighted_headroom_105_seed_values(headroom_105_seed_weight());
}

sub headroom_105_seed_base_values {
	 return {
	  whiteBalanceRed => 2.5,
	  whiteBalanceGreen => 2.5,
	  whiteBalanceBlue => -12.5,
	 };
}

sub headroom_105_seed_weight {
	 return 0.5;
}

sub weighted_headroom_105_seed_values {
	 my ($weight)=@_;
	 $weight=1 if(!defined($weight));
	 my $base=headroom_105_seed_base_values();
	 my %weighted;
	 foreach my $setting (keys %{$base}) {
	  $weighted{$setting}=round_ddc_quarter(($base->{$setting}+0)*$weight);
	 }
	 return \%weighted;
}

sub headroom_105_post_seed_candidate {
	 my ($step,$target)=@_;
	 return 0 if(!autocal_step_is_fast_headroom($step) || autocal_step_is_peak_headroom($step));
	 my $ire=(ref($target) eq "HASH" && defined($target->{"ire"})) ? ($target->{"ire"}+0) : ((ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : undef);
	 return 0 if(!defined($ire));
	 return ($ire >= 104.5 && $ire < 108.5) ? 1 : 0;
}

sub headroom_105_seed_value_seen {
	 my ($arrays,$target,$tried,$setting,$seed_value,$tolerance)=@_;
	 $tolerance=0.0001 if(!defined($tolerance));
	 return 1 if(tried_value_exists($tried,$setting,$seed_value));
	 return 0 if(ref($arrays) ne "HASH" || ref($target) ne "HASH");
	 my $idx=$target->{"index"};
	 return 0 if(!defined($idx) || ref($arrays->{$setting}) ne "ARRAY" || $idx >= @{$arrays->{$setting}});
	 my $current=$arrays->{$setting}[$idx]||0;
	 return abs($current-($seed_value+0)) <= $tolerance ? 1 : 0;
}

sub headroom_105_post_seed_body_refinement {
	 my ($step,$arrays,$target,$tried)=@_;
	 return 0 if(!headroom_105_post_seed_candidate($step,$target));
	 my $seed=headroom_105_hard_seed_values();
	 return 0 if(ref($seed) ne "HASH");
	 return 0 if(!headroom_105_seed_value_seen($arrays,$target,$tried,"whiteBalanceRed",$seed->{"whiteBalanceRed"},0.1001));
	 return 0 if(!headroom_105_seed_value_seen($arrays,$target,$tried,"whiteBalanceGreen",$seed->{"whiteBalanceGreen"},0.1001));
	 return 0 if(!headroom_105_seed_value_seen($arrays,$target,$tried,"whiteBalanceBlue",$seed->{"whiteBalanceBlue"},0.1001));
	 return 1;
}

sub mark_headroom_105_body_refinement_adjustments {
	 my ($adjustments)=@_;
	 return $adjustments if(ref($adjustments) ne "ARRAY");
	 foreach my $adj (@{$adjustments}) {
	  next if(ref($adj) ne "HASH");
	  $adj->{"headroom_105_body_refinement"}=1;
	  $adj->{"source"}="headroom_105_body_refinement" if(!defined($adj->{"source"}));
	 }
	 return $adjustments;
}

sub headroom_105_near_y_cleanup_branch {
	 my ($tried)=@_;
	 return undef if(ref($tried) ne "HASH" || ref($tried->{"__headroom_105_near_y_cleanup"}) ne "HASH");
	 return $tried->{"__headroom_105_near_y_cleanup"};
}

sub headroom_105_near_y_cleanup_branch_active {
	 my ($tried,$step,$arrays,$target,$luminance_err)=@_;
	 my $branch=headroom_105_near_y_cleanup_branch($tried);
	 return 0 if(ref($branch) ne "HASH" || !$branch->{"active"});
	 return 0 if(($branch->{"mode"}||"near_y_cleanup") ne "near_y_cleanup");
	 return 0 if(!headroom_105_post_seed_body_refinement($step,$arrays,$target,$tried));
	 return 0 if(!defined($luminance_err));
	 return headroom_105_near_y_luminance($step,$luminance_err*100);
}

sub headroom_105_score_y_branch_active {
	 my ($tried,$step,$arrays,$target,$luminance_err)=@_;
	 my $branch=headroom_105_near_y_cleanup_branch($tried);
	 return 0 if(ref($branch) ne "HASH" || !$branch->{"active"});
	 return 0 if(($branch->{"mode"}||"") ne "score_y_recovery");
	 return 0 if(!headroom_105_post_seed_body_refinement($step,$arrays,$target,$tried));
	 return 0 if(!defined($luminance_err));
	 return abs(($luminance_err+0)*100) > luminance_tolerance_percent($step) ? 1 : 0;
}

sub headroom_105_near_y_cleanup_rgb_cap {
	 my ($tried,$step,$arrays,$target,$luminance_err,$micro)=@_;
	 return undef if(!headroom_105_near_y_cleanup_branch_active($tried,$step,$arrays,$target,$luminance_err));
	 return $micro ? 0.25 : 0.50;
}

sub headroom_105_near_y_cleanup_working_candidate {
	 my ($step,$arrays,$target,$tried,$adjustments,$before_lum_pct,$after_lum_pct,$before_de,$after_de,$before_score,$after_score)=@_;
	 return 0 if(!headroom_105_post_seed_body_refinement($step,$arrays,$target,$tried));
	 my $adj=luma_only_adjustment($adjustments);
	 return 0 if(ref($adj) ne "HASH");
	 return 0 if(abs($adj->{"delta"}||0) > 1.0001);
	 return 0 if(!defined($before_lum_pct) || !defined($after_lum_pct));
	 return 0 if(!defined($before_de) || !defined($after_de));
	 my $before_abs=abs($before_lum_pct+0);
	 my $after_abs=abs($after_lum_pct+0);
	 return 0 if(!headroom_105_near_y_luminance($step,$after_lum_pct));
	 return 0 if($after_abs+0.10 >= $before_abs);
	 my $de_worse=(($after_de+0) > ($before_de+0)+0.35) ? 1 : 0;
	 my $score_worse=(defined($before_score) && defined($after_score) && ($after_score+0) > ($before_score+0)+0.35) ? 1 : 0;
	 return ($de_worse || $score_worse) ? 1 : 0;
}

sub headroom_105_score_y_working_candidate {
	 my ($step,$arrays,$target,$tried,$adjustments,$before_lum_pct,$after_lum_pct,$before_score,$after_score,$best_lum_pct,$best_score,$before_de,$after_de)=@_;
	 return 0 if(!headroom_105_post_seed_body_refinement($step,$arrays,$target,$tried));
	 return 0 if(!headroom_105_rgb_cleanup_adjustment($adjustments));
	 return 0 if(!defined($before_lum_pct) || !defined($after_lum_pct));
	 return 0 if(!defined($after_score) || !defined($best_score));
	 my $before_abs=abs($before_lum_pct+0);
	 my $after_abs=abs($after_lum_pct+0);
	 my $best_abs=defined($best_lum_pct) ? abs($best_lum_pct+0) : $before_abs;
	 return 0 if($after_abs <= luminance_tolerance_percent($step));
	 return 0 if($after_abs <= $before_abs+0.35 && $after_abs <= $best_abs+0.35);
	 return 0 if(($after_score+0) > ($best_score+0)-0.50);
	 return 0 if(defined($before_score) && ($after_score+0) > ($before_score+0)-0.35);
	 return 1 if(!defined($before_de) || !defined($after_de));
	 return (($after_de+0) < ($before_de+0)-0.35) ? 1 : 0;
}

sub headroom_105_score_branch_adjustment {
	 my ($adjustments)=@_;
	 return 0 if(ref($adjustments) ne "ARRAY" || !@{$adjustments});
	 my $has_rgb=0;
	 foreach my $adj (@{$adjustments}) {
	  return 0 if(ref($adj) ne "HASH");
	  return 0 if($adj->{"headroom_105_all_down_luma"} || $adj->{"headroom_105_floor_luma_coupled"});
	  my $setting=$adj->{"setting"}||"";
	  my $channel=$adj->{"channel"}||"";
	  $has_rgb=1 if($channel =~ /^(?:r|g|b)$/ || $setting =~ /^whiteBalance(?:Red|Green|Blue)$/);
	 }
	 return $has_rgb ? 1 : 0;
}

sub headroom_105_score_branch_promote_candidate {
	 my ($step,$arrays,$target,$tried,$adjustments,$after_lum_pct,$after_score,$best_lum_pct,$best_score,$after_de,$best_de)=@_;
	 return 0 if(!headroom_105_post_seed_body_refinement($step,$arrays,$target,$tried));
	 return 0 if(!headroom_105_score_branch_adjustment($adjustments));
	 return 0 if(!defined($after_lum_pct) || !defined($best_lum_pct));
	 return 0 if(!defined($after_score) || !defined($best_score));
	 return 0 if(!defined($after_de) || !defined($best_de));
	 return 0 if(($best_de+0) <= 2.50);
	 return 0 if(!headroom_105_near_y_luminance($step,$best_lum_pct));
	 return 0 if(($after_score+0) + 0.50 >= ($best_score+0));
	 return 0 if(($after_de+0) + 0.75 >= ($best_de+0));
	 my $after_abs=abs($after_lum_pct+0);
	 my $max_lum=headroom_105_near_y_cleanup_gate_percent($step)+6.0;
	 $max_lum=8.0 if($max_lum > 8.0);
	 return 0 if($after_abs > $max_lum);
	 return 1;
}

sub headroom_105_main_polish_refine_active {
	 my ($step,$arrays,$target,$tried,$de,$lum_pct,$target_delta)=@_;
	 return 0 if(!headroom_105_post_seed_body_refinement($step,$arrays,$target,$tried));
	 return 0 if(!defined($de) || !defined($lum_pct));
	 $target_delta=0.5 if(!defined($target_delta) || $target_delta <= 0);
	 return 0 if(($de+0) <= ($target_delta+1.0));
	 my $abs=abs($lum_pct+0);
	 my $max=headroom_105_near_y_cleanup_gate_percent($step)+2.0;
	 $max=4.0 if($max > 4.0);
	 return ($abs <= $max) ? 1 : 0;
}

sub mark_headroom_105_main_polish_refine_adjustments {
	 my ($adjustments,$source)=@_;
	 return $adjustments if(ref($adjustments) ne "ARRAY");
	 foreach my $adj (@{$adjustments}) {
	  next if(ref($adj) ne "HASH");
	  $adj->{"headroom_105_main_polish_refine"}=1;
	  $adj->{"headroom_105_body_refinement"}=1;
	  $adj->{"source"}=$source if(defined($source) && !defined($adj->{"source"}));
	 }
	 return $adjustments;
}

sub headroom_105_main_polish_refine_adjustment {
	 my ($adjustments)=@_;
	 return 0 if(ref($adjustments) ne "ARRAY");
	 foreach my $adj (@{$adjustments}) {
	  next if(ref($adj) ne "HASH");
	  return 1 if($adj->{"headroom_105_main_polish_refine"});
	 }
	 return 0;
}

sub headroom_105_main_polish_refine_adjustments {
	 my ($state,$arrays,$target,$step,$reading,$de,$lum_pct,$target_delta,$tried,$stalls,$lum_err,$rgb_response_model,$err)=@_;
	 return undef if(!headroom_105_main_polish_refine_active($step,$arrays,$target,$tried,$de,$lum_pct,$target_delta));
	 return undef if(strict_tried_for_step($step));
	 $err=autocal_adjustment_error($reading,$step) if(ref($err) ne "HASH");
	 my ($adjustments,$source);
	 $adjustments=lg_autocal_26_learned_luminance_adjustment($state,$arrays,$target,$step,$lum_pct,$tried,final_all_level_verify_adjustment_cap($step,"adjustingLuminance"),"headroom_105_main_polish_luminance");
	 $source="headroom_105_main_polish_luminance" if($adjustments);
	 if(!$adjustments && ref($err) eq "HASH") {
	  my ($learned_ch)=furthest_rgb_error_channel($err);
	  my $learned_setting=$learned_ch ? channel_setting($learned_ch) : undef;
	  my $learned_rgb_cap=$learned_setting ? final_all_level_verify_adjustment_cap($step,$learned_setting) : undef;
	  $adjustments=lg_autocal_26_learned_rgb_adjustment($state,$arrays,$target,$step,$reading,$de,$target_delta,$tried,$learned_rgb_cap,"headroom_105_main_polish_rgb");
	  $source="headroom_105_main_polish_rgb" if($adjustments);
	 }
	 if(!$adjustments && ref($err) eq "HASH") {
	  $adjustments=choose_rgb_response_adjustments($err,$arrays,$target,$rgb_response_model,$tried,$de,$step,$target_delta,$stalls,$lum_err);
	  $source="headroom_105_main_polish_response_rgb" if($adjustments);
	 }
	 if(!$adjustments && ref($err) eq "HASH") {
	  $adjustments=choose_adjustments($err,$arrays,$target,$de,0.25,$stalls,$lum_err,$tried,$step);
	  $source="headroom_105_main_polish_fallback" if($adjustments);
	 }
	 return undef if(!$adjustments);
	 mark_headroom_105_main_polish_refine_adjustments($adjustments,$source);
	 trace_109($step,"headroom_105_main_polish_refine_plan",{
	  source=>$source,
	  delta_e=>defined($de)?$de+0:undef,
	  luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef,
	  score=>lg_autocal_26_measurement_score($step,$de,$lum_pct)+0,
	  adjustments=>trace_adjustments_summary($adjustments),
	  values_before=>trace_target_values($arrays,$target)
	 });
	 return $adjustments;
}

sub headroom_105_rgb_cleanup_adjustment {
	 my ($adjustments)=@_;
	 return 0 if(ref($adjustments) ne "ARRAY" || !@{$adjustments});
	 foreach my $adj (@{$adjustments}) {
	  return 0 if(ref($adj) ne "HASH");
	  return 0 if(($adj->{"setting"}||"") eq "adjustingLuminance");
	  return 0 if($adj->{"headroom_105_all_down_luma"} || $adj->{"headroom_105_floor_luma_coupled"});
	 }
	 return 1;
}

sub headroom_105_rgb_luma_assist {
	 my ($adjustments,$luminance_err)=@_;
	 return 0 if(ref($adjustments) ne "ARRAY" || !defined($luminance_err));
	 my $desired=($luminance_err > 0) ? -1 : 1;
	 my $sum=0;
	 foreach my $adj (@{$adjustments}) {
	  next if(ref($adj) ne "HASH");
	  next if(($adj->{"channel"}||"") !~ /^(?:r|g|b)$/);
	  $sum+=$adj->{"delta"}||0;
	 }
	 return ($sum*$desired > 0) ? abs($sum) : 0;
}

sub headroom_105_rgb_luma_opposition {
	 my ($adjustments,$luminance_err)=@_;
	 return 0 if(ref($adjustments) ne "ARRAY" || !defined($luminance_err));
	 my $desired=($luminance_err > 0) ? -1 : (($luminance_err < 0) ? 1 : 0);
	 my $sum=0;
	 foreach my $adj (@{$adjustments}) {
	  next if(ref($adj) ne "HASH");
	  next if(($adj->{"channel"}||"") !~ /^(?:r|g|b)$/);
	  $sum+=$adj->{"delta"}||0;
	 }
	 if(!$desired && abs($sum) > 0.0001) {
	  $desired=($sum > 0) ? -1 : 1;
	 }
	 return ($desired && $sum*$desired < 0) ? abs($sum) : 0;
}

sub headroom_105_luma_coupling_adjustment {
	 my ($adjustments,$arrays,$target,$step,$luminance_err,$tried,$micro,$state)=@_;
	 return undef if(!headroom_105_post_seed_body_refinement($step,$arrays,$target,$tried));
	 return undef if(strict_tried_for_step($step));
	 return undef if(headroom_105_family_suppressed($tried,"headroom_105_luma_coupled_rgb"));
	 return undef if(ref($adjustments) ne "ARRAY" || ref($arrays) ne "HASH" || ref($target) ne "HASH" || ref($tried) ne "HASH");
	 return undef if(!has_luminance_channel($arrays,$target));
	 return undef if(!defined($luminance_err));
	 return undef if(!headroom_105_rgb_cleanup_adjustment($adjustments));
	 my $lum_pct=$luminance_err*100;
	 my $tol=luminance_tolerance_percent($step);
	 my $assist=headroom_105_rgb_luma_assist($adjustments,$luminance_err);
	 my $opposition=headroom_105_rgb_luma_opposition($adjustments,$luminance_err);
	 return undef if(abs($lum_pct) <= $tol && $opposition < 0.4999);
	 my $idx=$target->{"index"};
	 return undef if(!defined($idx) || ref($arrays->{"adjustingLuminance"}) ne "ARRAY" || $idx >= @{$arrays->{"adjustingLuminance"}});
	 my $current=$arrays->{"adjustingLuminance"}[$idx]||0;
	 my $near=headroom_105_near_y_luminance($step,$lum_pct);
	 my $cap=$near ? 0.25 : 0.50;
	 $cap=0.25 if($micro && $cap > 0.25);
	 if(!$micro && $near && $opposition >= 0.9999 && $cap < 0.50) {
	  $cap=0.50;
	 }
	 if(!$micro && $near && $opposition >= 2.0001 && $cap < 1.00) {
	  $cap=1.00;
	 }
	 if($assist >= 0.4999 && $cap > 0.25) {
	  $cap=0.25;
	 }
	 my $direction=($luminance_err > 0) ? -1 : (($luminance_err < 0) ? 1 : 0);
	 if(!$direction && $opposition >= 0.4999) {
	  my $sum=0;
	  foreach my $adj (@{$adjustments}) {
	   next if(ref($adj) ne "HASH" || ($adj->{"channel"}||"") !~ /^(?:r|g|b)$/);
	   $sum+=$adj->{"delta"}||0;
	  }
	  $direction=($sum > 0) ? -1 : 1 if(abs($sum) > 0.0001);
	 }
	 return undef if(!$direction);
	 my $projected_lum_pct=$lum_pct;
	 if($opposition >= 0.4999) {
	  my $extra=$opposition*1.25;
	  $projected_lum_pct += ($direction < 0 ? $extra : -$extra);
	 }
	 my $model=lg_autocal_26_response_model_for_step($state || $LG_AUTOCAL_STATE,$step);
	 my $entry=(ref($model) eq "HASH" && ref($model->{"luminance"}) eq "HASH") ? $model->{"luminance"}{"adjustingLuminance"} : undef;
	 my ($slope,$predicted,$raw_delta,$reason,$response_multiplier,$response_cap_reason,$response_entry);
	 if(ref($entry) eq "HASH" && defined($entry->{"slope"}) && abs($entry->{"slope"}+0) >= 0.05) {
	  $slope=$entry->{"slope"}+0;
	  $raw_delta=-($projected_lum_pct+0)/$slope;
	  if($raw_delta*$direction <= 0) {
	   $raw_delta=$direction*$cap;
	   $reason="fallback_direction";
	  } else {
	   $reason="measured_luminance_response";
	  }
	 } else {
	  $raw_delta=$direction*$cap;
	  $reason="default_luminance_coupling";
	 }
	 $raw_delta=$cap if($raw_delta > $cap);
	 $raw_delta=-$cap if($raw_delta < -$cap);
	 my $base_abs=abs($raw_delta);
	 my $response_cap=$cap;
	 if(!$micro && !$near) {
	  $response_cap=($assist >= 0.4999) ? 0.50 : 1.00;
	 }
	 my $remaining=abs($lum_pct);
	 $remaining=abs($projected_lum_pct) if(abs($projected_lum_pct) > $remaining);
	 my ($scaled_abs,$scaled_mult,$scaled_reason,$scaled_entry)=headroom_105_response_scaled_step(
	  $tried,$step,"adjustingLuminance",$direction,$base_abs,$response_cap,$remaining,"headroom_105_luma_coupled_rgb"
	 );
	 return undef if(!defined($scaled_abs));
	 if($scaled_abs > $base_abs+0.0001) {
	  $raw_delta=$direction*$scaled_abs;
	  $response_multiplier=$scaled_mult;
	  $response_cap_reason=$scaled_reason;
	  $response_entry=$scaled_entry;
	  $reason.=";response_scaled";
	 }
	 return undef if(abs($raw_delta) < 0.0999);
	 foreach my $scale (1,0.5) {
	  my $next=round_ddc_quarter($current+($raw_delta*$scale));
	  next if(abs($next-$current) < 0.0999);
	  next if(($next-$current)*$direction <= 0);
	  next if(tried_value_exists($tried,"adjustingLuminance",$next));
	  next if(luma_probe_family_suppressed($tried,$target,$current,$next,$step,"headroom_105_luma_coupled_rgb",$state));
	  my $actual_delta=$next-$current;
	  $predicted=defined($slope) ? (($projected_lum_pct+0)+($slope*$actual_delta)) : undef;
		  trace_109($step,"headroom_105_luma_coupled_rgb",{
		   reason=>$reason,
		   luminance_error_pct=>$lum_pct+0,
		   projected_luminance_error_pct=>$projected_lum_pct+0,
		   tolerance_pct=>$tol+0,
		   near_y=>$near?JSON::PP::true:JSON::PP::false,
		   rgb_luma_assist=>$assist+0,
		   rgb_luma_opposition=>$opposition+0,
	   cap=>$cap+0,
	   current=>$current+0,
	   next=>$next+0,
		   delta=>$actual_delta+0,
		   response_multiplier=>defined($response_multiplier)?$response_multiplier+0:undef,
		   cap_reason=>$response_cap_reason,
		   remaining_error=>$remaining+0,
		   previous_delta=>(ref($response_entry) eq "HASH" && defined($response_entry->{"delta"})) ? $response_entry->{"delta"}+0 : undef,
		   previous_before_error=>(ref($response_entry) eq "HASH" && defined($response_entry->{"before_error"})) ? $response_entry->{"before_error"}+0 : undef,
		   previous_after_error=>(ref($response_entry) eq "HASH" && defined($response_entry->{"after_error"})) ? $response_entry->{"after_error"}+0 : undef,
		   slope=>defined($slope)?$slope+0:undef,
		   predicted_error=>defined($predicted)?$predicted+0:undef,
		   rgb_adjustments=>trace_adjustments_summary($adjustments),
	   target_values=>trace_target_values($arrays,$target)
	  });
	  return {
	   channel=>"lum",
	   setting=>"adjustingLuminance",
	   current=>$current,
	   next=>$next,
	   delta=>$actual_delta,
	   neutral_luminance=>1,
		   headroom_105_luma_coupled_rgb=>1,
		   headroom_105_response_scaled=>defined($response_multiplier) ? 1 : undef,
		   response_multiplier=>defined($response_multiplier) ? $response_multiplier+0 : undef,
		   cap_reason=>$response_cap_reason,
		   remaining_error=>$remaining+0,
		   headroom_105_body_refinement=>1,
		   response_model=>defined($slope) ? 1 : undef,
	   slope=>defined($slope) ? $slope+0 : undef,
	   predicted_error=>defined($predicted) ? $predicted+0 : undef,
	   source=>"headroom_105_luma_coupled_rgb",
	   micro=>$micro ? 1 : 0,
	  };
	 }
	 return undef;
}

sub append_headroom_105_luma_coupling {
	 my ($adjustments,$arrays,$target,$step,$luminance_err,$tried,$micro,$state)=@_;
	 return $adjustments if(ref($adjustments) ne "ARRAY");
	 my $luma=headroom_105_luma_coupling_adjustment($adjustments,$arrays,$target,$step,$luminance_err,$tried,$micro,$state);
	 return $adjustments if(ref($luma) ne "HASH");
	 push @{$adjustments},$luma;
	 return mark_headroom_105_body_refinement_adjustments($adjustments);
}

sub headroom_105_response_entry {
	 my ($tried,$setting)=@_;
	 return undef if(ref($tried) ne "HASH" || ref($tried->{"__headroom_105_response"}) ne "HASH");
	 my $entry=$tried->{"__headroom_105_response"}{$setting};
	 return ref($entry) eq "HASH" ? $entry : undef;
}

sub headroom_105_response_scaled_step {
	 my ($tried,$step,$setting,$direction,$base_step,$cap,$remaining_error,$source)=@_;
	 return ($base_step,1,"initial_probe",undef) if(ref($tried) ne "HASH");
	 my $entry=headroom_105_response_entry($tried,$setting);
	 return ($base_step,1,"initial_probe",undef) if(ref($entry) ne "HASH");
	 if(($entry->{"direction"}||0) == ($direction||0) && $entry->{"wrong_direction"}) {
	  trace_109($step,"headroom_105_response_direction_suppressed",{
	   setting=>$setting,
	   source=>$source||"headroom_105_response",
	   direction=>$direction+0,
	   previous_delta=>$entry->{"delta"},
	   before_error=>$entry->{"before_error"},
	   after_error=>$entry->{"after_error"},
	   slope=>$entry->{"slope"},
	   remaining_error=>defined($remaining_error)?$remaining_error+0:undef
	  });
	  return (undef,0,"wrong_direction_suppressed",$entry);
	 }
	 return ($base_step,1,"adequate_response",$entry) if(!$entry->{"insufficient_response"});
	 my $mult=($entry->{"samples"}||1) >= 2 ? 2.0 : 1.5;
	 my $next=$base_step*$mult;
	 $next=$cap if(defined($cap) && $next > $cap);
	 $next=$base_step if($next < $base_step);
	 return ($next,$mult,"insufficient_response",$entry);
}

sub mark_headroom_105_response_scaled_adjustments {
	 my ($adjustments,$setting,$mult,$reason,$entry,$cap)=@_;
	 return $adjustments if(ref($adjustments) ne "ARRAY" || !defined($mult) || $mult <= 1.0001);
	 foreach my $adj (@{$adjustments}) {
	  next if(ref($adj) ne "HASH" || ($adj->{"setting"}||"") ne $setting);
	  $adj->{"headroom_105_response_scaled"}=1;
	  $adj->{"response_multiplier"}=$mult+0;
	  $adj->{"cap_reason"}=$reason if(defined($reason));
	  $adj->{"previous_delta"}=$entry->{"delta"} if(ref($entry) eq "HASH" && defined($entry->{"delta"}));
	  $adj->{"previous_before_error"}=$entry->{"before_error"} if(ref($entry) eq "HASH" && defined($entry->{"before_error"}));
	  $adj->{"previous_after_error"}=$entry->{"after_error"} if(ref($entry) eq "HASH" && defined($entry->{"after_error"}));
	  $adj->{"slope"}=$entry->{"slope"} if(ref($entry) eq "HASH" && defined($entry->{"slope"}));
	 }
	 return $adjustments;
}

sub record_headroom_105_response {
	 my ($tried,$target,$step,$adjustments,$before,$after,$before_lum_pct,$after_lum_pct,$before_de,$after_de,$before_score,$after_score)=@_;
	 return undef if(ref($tried) ne "HASH" || !headroom_105_post_seed_candidate($step,$target));
	 return undef if(strict_tried_for_step($step));
	 return undef if(ref($adjustments) ne "ARRAY" || ref($before) ne "HASH" || ref($after) ne "HASH");
	 my $before_err=autocal_adjustment_error($before,$step);
	 my $after_err=autocal_adjustment_error($after,$step);
	 $tried->{"__headroom_105_response"}={} if(ref($tried->{"__headroom_105_response"}) ne "HASH");
	 my @updates;
	 foreach my $adj (@{$adjustments}) {
	  next if(ref($adj) ne "HASH");
	  my $setting=$adj->{"setting"}||"";
	  my $delta=defined($adj->{"delta"}) ? ($adj->{"delta"}+0) : undef;
	  next if(!defined($delta) || abs($delta) < 0.0001);
	  my ($before_error,$after_error,$remaining,$floor);
	  if($setting eq "adjustingLuminance") {
	   next if(!defined($before_lum_pct) || !defined($after_lum_pct));
	   ($before_error,$after_error)=($before_lum_pct+0,$after_lum_pct+0);
	   $remaining=abs($after_error);
	   $floor=luminance_tolerance_percent($step);
	  } else {
	   my $ch=$adj->{"channel"}||"";
	   next if($ch !~ /^(?:r|g|b)$/ || ref($before_err) ne "HASH" || ref($after_err) ne "HASH");
	   next if(!defined($before_err->{$ch}) || !defined($after_err->{$ch}));
	   ($before_error,$after_error)=($before_err->{$ch}+0,$after_err->{$ch}+0);
	   $remaining=abs($after_error);
	   $floor=0.0030;
	  }
	  my $change=$after_error-$before_error;
	  my $slope=$change/$delta;
		  my $before_abs=abs($before_error);
		  my $after_abs=abs($after_error);
		  my $improvement=$before_abs-$after_abs;
		  my $wrong=($after_abs > $before_abs+($setting eq "adjustingLuminance" ? 0.10 : 0.0005)) ? 1 : 0;
		  my $y_worse=(defined($before_lum_pct) && defined($after_lum_pct) && abs($after_lum_pct+0) > abs($before_lum_pct+0)+0.05) ? 1 : 0;
		  my $score_worse=(defined($before_score) && defined($after_score) && ($after_score+0) > ($before_score+0)+0.25) ? 1 : 0;
		  my $de_worse=(defined($before_de) && defined($after_de) && ($after_de+0) > ($before_de+0)+0.25) ? 1 : 0;
		  $wrong=1 if(!$wrong && $y_worse && ($score_worse || $de_worse));
		  my $insufficient=(!$wrong && $after_abs > $floor && $improvement < (($before_abs*0.35) > ($setting eq "adjustingLuminance" ? 0.30 : 0.0010) ? ($before_abs*0.35) : ($setting eq "adjustingLuminance" ? 0.30 : 0.0010))) ? 1 : 0;
	  my $prior=headroom_105_response_entry($tried,$setting);
	  my $samples=(ref($prior) eq "HASH" ? ($prior->{"samples"}||1) : 0)+1;
	  my $entry={
	   setting=>$setting,
	   delta=>$delta+0,
	   direction=>$delta < 0 ? -1 : 1,
	   before_error=>$before_error+0,
	   after_error=>$after_error+0,
	   remaining_error=>$remaining+0,
	   slope=>$slope+0,
	   improvement=>$improvement+0,
	   insufficient_response=>$insufficient,
		   wrong_direction=>$wrong,
		   y_worse=>$y_worse,
		   score_worse=>$score_worse,
		   de_worse=>$de_worse,
	   samples=>$samples+0,
	   before_delta_e=>defined($before_de)?$before_de+0:undef,
	   after_delta_e=>defined($after_de)?$after_de+0:undef,
	   before_score=>defined($before_score)?$before_score+0:undef,
	   after_score=>defined($after_score)?$after_score+0:undef,
	  };
	  $tried->{"__headroom_105_response"}{$setting}=$entry;
	  push @updates,$entry;
	  trace_109($step,"headroom_105_response_measured",$entry);
	 }
	 return @updates ? \@updates : undef;
}

sub headroom_105_family_suppressed {
	 my ($tried,$family)=@_;
	 return 0 if(ref($tried) ne "HASH" || ref($tried->{"__headroom_105_suppressed_family"}) ne "HASH");
	 return $tried->{"__headroom_105_suppressed_family"}{$family} ? 1 : 0;
}

sub suppress_headroom_105_family {
	 my ($tried,$step,$target,$family,$reason,$before_lum_pct,$after_lum_pct,$before_score,$after_score)=@_;
	 return 0 if(ref($tried) ne "HASH" || !$family);
	 return 0 if(!headroom_105_post_seed_candidate($step,$target));
	 $tried->{"__headroom_105_suppressed_family"}={} if(ref($tried->{"__headroom_105_suppressed_family"}) ne "HASH");
	 return 0 if($tried->{"__headroom_105_suppressed_family"}{$family});
	 $tried->{"__headroom_105_suppressed_family"}{$family}=1;
	 trace_109($step,"headroom_105_family_suppressed",{
	  family=>$family,
	  reason=>$reason||"suppressed",
	  before_luminance_error_pct=>defined($before_lum_pct)?$before_lum_pct+0:undef,
	  after_luminance_error_pct=>defined($after_lum_pct)?$after_lum_pct+0:undef,
	  before_score=>defined($before_score)?$before_score+0:undef,
	  after_score=>defined($after_score)?$after_score+0:undef
	 });
	 return 1;
}

sub record_headroom_105_bad_adjustment_family {
	 my ($tried,$target,$adjustments,$before_lum_pct,$after_lum_pct,$before_score,$after_score,$step,$before_de,$after_de)=@_;
	 return undef if(ref($tried) ne "HASH" || !headroom_105_post_seed_candidate($step,$target));
	 return undef if(!defined($before_lum_pct) || !defined($after_lum_pct));
	 my $family;
	 foreach my $adj (@{ref($adjustments) eq "ARRAY" ? $adjustments : []}) {
	  next if(ref($adj) ne "HASH");
	  $family="headroom_105_all_down_luma" if($adj->{"headroom_105_all_down_luma"});
	  $family="headroom_105_floor_luma_coupled" if($adj->{"headroom_105_floor_luma_coupled"});
	  $family="headroom_105_luma_coupled_rgb" if($adj->{"headroom_105_luma_coupled_rgb"});
	  last if($family);
	 }
	 return undef if(!$family);
	 my $before_abs=abs($before_lum_pct+0);
	 my $after_abs=abs($after_lum_pct+0);
	 my $y_worse=($after_abs > $before_abs+0.05) ? 1 : 0;
	 my $score_worse=(defined($before_score) && defined($after_score) && ($after_score+0) > ($before_score+0)+0.25) ? 1 : 0;
	 my $de_worse=(defined($before_de) && defined($after_de) && ($after_de+0) > ($before_de+0)+0.25) ? 1 : 0;
	 if($family eq "headroom_105_luma_coupled_rgb") {
	  return undef if(!$y_worse || (!$score_worse && !$de_worse));
	 } else {
	  return undef if(!$y_worse && !$score_worse);
	 }
	 suppress_headroom_105_family($tried,$step,$target,$family,$y_worse ? "luminance_worse" : "score_worse",$before_lum_pct,$after_lum_pct,$before_score,$after_score);
	 return $family;
}

sub headroom_105_luma_priority_active {
	 my ($step,$arrays,$target,$tried,$luminance_err)=@_;
	 return 0 if(!headroom_105_luma_blocking_active($step,$arrays,$target,$tried,$luminance_err));
	 $luminance_err=0 if(!defined($luminance_err));
	 my $lum_pct=$luminance_err*100;
	 return abs($lum_pct) > headroom_luminance_control_gate_percent($step,1.0) ? 1 : 0;
}

sub headroom_105_luma_blocking_active {
	 my ($step,$arrays,$target,$tried,$luminance_err)=@_;
	 return 0 if(!headroom_105_post_seed_body_refinement($step,$arrays,$target,$tried));
	 return 0 if(!has_luminance_channel($arrays,$target));
	 $luminance_err=0 if(!defined($luminance_err));
	 my $lum_pct=$luminance_err*100;
	 return 0 if(headroom_105_near_y_luminance($step,$lum_pct));
	 return abs($lum_pct) > luminance_tolerance_percent($step) ? 1 : 0;
}

sub headroom_105_luma_priority_adjustment {
	 my ($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_step,$max_step,$micro,$step)=@_;
	 return undef if(!headroom_105_luma_priority_active($step,$arrays,$target,$tried,$luminance_err));
	 return undef if(headroom_105_family_suppressed($tried,"headroom_105_luma_priority") && !headroom_105_score_y_branch_active($tried,$step,$arrays,$target,$luminance_err));
	 return undef if(headroom_105_near_y_cleanup_branch_active($tried,$step,$arrays,$target,$luminance_err));
	 return undef if(ref($arrays) ne "HASH" || ref($target) ne "HASH" || ref($tried) ne "HASH");
	 my $idx=$target->{"index"};
	 return undef if(!defined($idx) || ref($arrays->{"adjustingLuminance"}) ne "ARRAY" || $idx >= @{$arrays->{"adjustingLuminance"}});
	 $min_step ||= ($micro ? 0.20 : 0.25);
	 $max_step ||= ($micro ? 1.00 : 4.00);
	 my $authority=1.00;
	 $max_step=$authority if($max_step > $authority);
	 my $direction=($luminance_err > 0) ? -1 : 1;
	 my $planned=neutral_luminance_step($luminance_err,$de,$stalls,$min_step,$max_step);
	 my ($scaled_planned,$response_multiplier,$response_cap_reason,$response_entry)=headroom_105_response_scaled_step(
	  $tried,$step,"adjustingLuminance",$direction,$planned,$max_step,abs(($luminance_err||0)*100),"headroom_105_luma_priority"
	 );
	 return undef if(!defined($scaled_planned));
	 $planned=$scaled_planned;
	 my @magnitudes=($planned);
	 push @magnitudes,4 if($planned > 4.0001 && !$micro);
	 push @magnitudes,2 if($planned > 2.0001);
	 push @magnitudes,1 if($planned > 1.0001);
	 push @magnitudes,0.5 if($planned > 0.5001);
	 push @magnitudes,0.25 if($planned > 0.2501 && $min_step <= 0.25);
	 my %seen_mag;
	 my $current=$arrays->{"adjustingLuminance"}[$idx]||0;
	 foreach my $mag (@magnitudes) {
	  next if($mag < $min_step-0.0001);
	  next if($seen_mag{ddc_value_key($mag)}++);
	  my $next=clamp_ddc_value($current+($direction*$mag));
	  next if(abs($next-$current) < 0.0001);
	  next if(tried_value_exists($tried,"adjustingLuminance",$next));
	  next if(luma_probe_family_suppressed($tried,$target,$current,$next,$step,"headroom_105_luma_priority",$LG_AUTOCAL_STATE));
	  trace_109($step,"headroom_105_luma_priority",{
	   delta_e=>defined($de)?$de+0:undef,
	   luminance_error_pct=>($luminance_err*100)+0,
	   magnitude=>$mag+0,
	   response_multiplier=>defined($response_multiplier) && $response_multiplier > 1.0001 ? $response_multiplier+0 : undef,
	   cap_reason=>$response_cap_reason,
	   remaining_error=>abs(($luminance_err||0)*100),
	   previous_delta=>(ref($response_entry) eq "HASH" && defined($response_entry->{"delta"})) ? $response_entry->{"delta"}+0 : undef,
	   previous_before_error=>(ref($response_entry) eq "HASH" && defined($response_entry->{"before_error"})) ? $response_entry->{"before_error"}+0 : undef,
	   previous_after_error=>(ref($response_entry) eq "HASH" && defined($response_entry->{"after_error"})) ? $response_entry->{"after_error"}+0 : undef,
	   current=>$current+0,
	   next=>$next+0,
	   target_values=>trace_target_values($arrays,$target)
	  });
	  my $out=[{
	   channel=>"lum",
	   setting=>"adjustingLuminance",
	   current=>$current,
	   next=>$next,
	   delta=>$next-$current,
	   neutral_luminance=>1,
	   headroom_105_luma_priority=>1,
	   headroom_105_body_refinement=>1,
	   source=>"headroom_105_luma_priority",
	   micro=>$micro ? 1 : 0,
	  }];
	  return mark_headroom_105_response_scaled_adjustments($out,"adjustingLuminance",$response_multiplier,$response_cap_reason,$response_entry,$max_step);
	 }
	 return undef;
}

sub headroom_105_all_down_luma_adjustment {
	 my ($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_step,$max_rgb_step,$micro,$step)=@_;
	 return undef if(!headroom_105_post_seed_body_refinement($step,$arrays,$target,$tried));
	 return undef if(headroom_105_family_suppressed($tried,"headroom_105_all_down_luma"));
	 return undef if(headroom_105_near_y_cleanup_branch_active($tried,$step,$arrays,$target,$luminance_err));
	 return undef if(ref($arrays) ne "HASH" || ref($target) ne "HASH" || ref($tried) ne "HASH");
	 $luminance_err=0 if(!defined($luminance_err));
	 my $lum_pct=$luminance_err*100;
	 return undef if($lum_pct <= headroom_luminance_control_gate_percent($step,2.0));
	 my $idx=$target->{"index"};
	 return undef if(!defined($idx));
	 $min_step ||= ($micro ? 0.20 : 0.25);
	 $max_rgb_step ||= ($micro ? 0.50 : 2.00);
	 my $planned=neutral_luminance_step($luminance_err,$de,$stalls,$min_step,$max_rgb_step);
	 my @magnitudes=($planned);
	 push @magnitudes,2 if($planned > 2.0001 && !$micro);
	 push @magnitudes,1 if($planned > 1.0001);
	 push @magnitudes,0.5 if($planned > 0.5001);
	 push @magnitudes,0.25 if($planned > 0.2501 && $min_step <= 0.25);
	 my %seen_mag;
	 foreach my $mag (@magnitudes) {
	  next if($mag < $min_step-0.0001);
	  next if($seen_mag{ddc_value_key($mag)}++);
	  my @out;
	  my $blocked=0;
	  foreach my $control (
	   { channel=>"r", setting=>"whiteBalanceRed" },
	   { channel=>"g", setting=>"whiteBalanceGreen" },
	   { channel=>"b", setting=>"whiteBalanceBlue" },
	  ) {
	   my $arr=$arrays->{$control->{"setting"}};
	   if(ref($arr) ne "ARRAY" || $idx >= @{$arr}) { $blocked=1; last; }
	   my $current=$arr->[$idx]||0;
	   my $next=clamp_ddc_value($current-$mag);
	   if(abs($next-$current) < 0.0001) { $blocked=1; last; }
	   push @out,{
	    channel=>$control->{"channel"},
	    setting=>$control->{"setting"},
	    current=>$current,
	    next=>$next,
	    delta=>$next-$current,
	    neutral_luminance=>1,
	    headroom_105_all_down_luma=>1,
	    headroom_105_body_refinement=>1,
	    source=>"headroom_105_all_down_luma",
	    micro=>$micro ? 1 : 0,
	   };
	  }
	  next if($blocked || @out != 3);
	  my $key=headroom_combo_key(\@out);
	  next if($key eq "");
	  $tried->{"__headroom_combo"}={} if(ref($tried->{"__headroom_combo"}) ne "HASH");
	  next if($tried->{"__headroom_combo"}{$key});
	  $tried->{"__headroom_combo"}{$key}={ count=>1, de=>defined($de) ? $de+0 : undef, source=>"headroom_105_all_down_luma" };
	  trace_109($step,"headroom_105_all_down_luma",{
	   delta_e=>defined($de)?$de+0:undef,
	   luminance_error_pct=>$lum_pct+0,
	   magnitude=>$mag+0,
	   target_values=>trace_target_values($arrays,$target)
	  });
	  return \@out;
	 }
	 return undef;
}

sub headroom_105_floor_luma_coupled_adjustment {
	 my ($error,$arrays,$target,$luminance_err,$de,$stalls,$tried,$min_step,$max_rgb_step,$micro,$step)=@_;
	 return undef if(!headroom_105_post_seed_body_refinement($step,$arrays,$target,$tried));
	 return undef if(headroom_105_family_suppressed($tried,"headroom_105_floor_luma_coupled"));
	 return undef if(headroom_105_near_y_cleanup_branch_active($tried,$step,$arrays,$target,$luminance_err));
	 return undef if(ref($arrays) ne "HASH" || ref($target) ne "HASH" || ref($tried) ne "HASH");
	 return undef if(!has_luminance_channel($arrays,$target));
	 $luminance_err=0 if(!defined($luminance_err));
	 my $lum_pct=$luminance_err*100;
	 return undef if($lum_pct <= headroom_luminance_control_gate_percent($step,1.0));
	 my $idx=$target->{"index"};
	 return undef if(!defined($idx));
	 my @controls=(
	  { channel=>"r", setting=>"whiteBalanceRed" },
	  { channel=>"g", setting=>"whiteBalanceGreen" },
	  { channel=>"b", setting=>"whiteBalanceBlue" },
	 );
	 my $floor;
	 foreach my $control (@controls) {
	  my $arr=$arrays->{$control->{"setting"}};
	  return undef if(ref($arr) ne "ARRAY" || $idx >= @{$arr});
	  my $current=$arr->[$idx]||0;
	  $control->{"current"}=$current+0;
	  $floor=$current+0 if(!defined($floor) || ($current+0) < $floor);
	 }
	 $min_step ||= ($micro ? 0.20 : 0.25);
	 $max_rgb_step ||= ($micro ? 0.50 : 1.00);
	 my @magnitudes=($max_rgb_step);
	 push @magnitudes,$max_rgb_step/2 if($max_rgb_step/2 >= $min_step-0.0001);
	 push @magnitudes,$min_step if($max_rgb_step > $min_step+0.0001);
	 my %seen_mag;
	 foreach my $mag (@magnitudes) {
	  next if($seen_mag{ddc_value_key($mag)}++);
	  my @out;
	  foreach my $control (@controls) {
	   my $current=$control->{"current"};
	   my $gap=$current-$floor;
	   next if($gap < $min_step-0.0001);
	   my $step_mag=($gap < $mag) ? $gap : $mag;
	   $step_mag=round_ddc_quarter($step_mag);
	   next if($step_mag < $min_step-0.0001);
	   my $next=clamp_ddc_value($current-$step_mag);
	   $next=$floor if($next < $floor);
	   next if(abs($next-$current) < 0.0001);
	   push @out,{
	    channel=>$control->{"channel"},
	    setting=>$control->{"setting"},
	    current=>$current,
	    next=>$next,
	    delta=>$next-$current,
	    damped=>($step_mag < $max_rgb_step) ? 1 : 0,
	    headroom_105_floor_luma_coupled=>1,
	    headroom_105_body_refinement=>1,
	    source=>"headroom_105_floor_luma_coupled",
	    micro=>$micro ? 1 : 0,
	   };
	  }
	  next if(!@out);
	  my $key=headroom_combo_key(\@out);
	  next if($key eq "");
	  $tried->{"__headroom_combo"}={} if(ref($tried->{"__headroom_combo"}) ne "HASH");
	  next if($tried->{"__headroom_combo"}{$key});
	  $tried->{"__headroom_combo"}{$key}={ count=>1, de=>defined($de) ? $de+0 : undef, source=>"headroom_105_floor_luma_coupled" };
	  trace_109($step,"headroom_105_floor_luma_coupled",{
	   delta_e=>defined($de)?$de+0:undef,
	   luminance_error_pct=>$lum_pct+0,
	   rgb_error=>$error,
	   floor=>$floor+0,
	   magnitude=>$mag+0,
	   target_values=>trace_target_values($arrays,$target)
	  });
	  return \@out;
	 }
	 return undef;
}

sub apply_headroom_105_seed_luma_refine_cap {
	 my ($arrays,$target,$step,$luminance_err,$planned_step,$source)=@_;
	 return ($planned_step,0,undef) if(!defined($planned_step));
	 return ($planned_step,0,undef) if(defined($source) && $source =~ /^(?:main_luminance|fine_luminance|body_luminance_priority|headroom_105_body_refinement)$/);
	 my $cap=headroom_105_seed_luma_refine_cap($arrays,$target,$step,$luminance_err);
	 return ($planned_step,0,undef) if(!defined($cap) || $planned_step <= $cap+0.0001);
	 trace_109($step,"headroom_105_seed_luma_refine_cap",{
	  source=>$source||"neutral_luminance",
	  planned_step=>$planned_step+0,
	  capped_step=>$cap+0,
	  luminance_error_pct=>defined($luminance_err) ? (($luminance_err*100)+0) : undef,
	  target_values=>trace_target_values($arrays,$target)
	 });
	 return ($cap,1,$cap);
}

sub headroom_105_near_target_luma_cap {
	 my ($step,$arrays,$target,$tried,$luminance_err,$planned_step,$source)=@_;
	 return ($planned_step,0) if(!defined($planned_step));
	 return ($planned_step,0) if(!headroom_105_post_seed_body_refinement($step,$arrays,$target,$tried));
	 return ($planned_step,0) if(!defined($luminance_err));
	 my $lum_pct=($luminance_err+0)*100;
	 return ($planned_step,0) if(!headroom_105_near_y_luminance($step,$lum_pct));
	 my $cap=0.25;
	 return ($planned_step,0) if($planned_step <= $cap+0.0001);
	 trace_109($step,"headroom_105_near_target_luma_cap",{
	  source=>$source||"neutral_luminance",
	  planned_step=>$planned_step+0,
	  capped_step=>$cap+0,
	  luminance_error_pct=>$lum_pct+0,
	  target_values=>trace_target_values($arrays,$target)
	 });
	 return ($cap,1);
}

sub neutral_luminance_adjustments {
	 my ($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_step,$max_step,$strict_tried,$step,$source,$state)=@_;
	 return undef if(ref($arrays) ne "HASH" || ref($target) ne "HASH");
	 $luminance_err=0 if(!defined($luminance_err));
	 return undef if(abs($luminance_err) < 0.0035);
	 my $idx=$target->{"index"};
	 return undef if(!defined($idx));
	 $min_step ||= 0.25;
	 my $cap=neutral_luminance_step_cap_for_target($target);
	 $max_step=$cap if(defined($cap) && (!defined($max_step) || $max_step > $cap));
	 my $direction=($luminance_err > 0) ? -1 : 1;
	 my $planned_step=neutral_luminance_step($luminance_err,$de,$stalls,$min_step,$max_step);
	 my ($capped_step,$seed_luma_capped)=apply_headroom_105_seed_luma_refine_cap($arrays,$target,$step,$luminance_err,$planned_step,$source||"neutral_luminance");
	 $planned_step=$capped_step;
	 my ($near_target_capped_step,$near_target_luma_capped)=headroom_105_near_target_luma_cap($step,$arrays,$target,$tried,$luminance_err,$planned_step,$source||"neutral_luminance");
	 $planned_step=$near_target_capped_step;
	 if(headroom_105_post_seed_body_refinement($step,$arrays,$target,$tried) && !$strict_tried) {
	  my ($guarded_step)=headroom_105_response_scaled_step(
	   $tried,$step,"adjustingLuminance",$direction,$planned_step,$planned_step,abs(($luminance_err||0)*100),$source||"neutral_luminance"
	  );
	  return undef if(!defined($guarded_step));
	  $planned_step=$guarded_step if($guarded_step < $planned_step);
	 }
		 my @magnitudes=($planned_step);
		 push @magnitudes,0.5 if($planned_step > 0.5);
		 push @magnitudes,0.25 if($planned_step > 0.25);
			 if(has_luminance_channel($arrays,$target)) {
			  my $setting="adjustingLuminance";
				  my $arr=$arrays->{$setting};
				  foreach my $mag (@magnitudes) {
				   my $current=$arr->[$idx]||0;
				   my $next=clamp_ddc_value($current+($direction*$mag));
				   my $seen=$strict_tried ? tried_value_exists($tried,$setting,$next) : repeated_value($tried,$setting,$next);
				   $seen=1 if(!$seen && luma_probe_family_suppressed($tried,$target,$current,$next,$step,$source||"neutral_luminance",$state));
				   next if(abs($next-$current) < 0.0001 || $seen);
				   return [{ channel=>"lum", setting=>$setting, current=>$current, next=>$next, delta=>$next-$current, neutral_luminance=>1, headroom_105_seed_luma_refine_cap=>$seed_luma_capped ? 1 : undef, headroom_105_near_target_luma_cap=>$near_target_luma_capped ? 1 : undef, source=>$source||"neutral_luminance" }];
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

sub near_white_95_luma_step {
 my ($step)=@_;
 return 0 if(ref($step) ne "HASH" || !defined($step->{"ire"}));
 my $ire=$step->{"ire"}+0;
 return 1 if(abs($ire-95) < 0.001);
 return 1 if(abs($ire-99) < 0.001);
 return 1 if(abs($ire-105) < 0.001 && !autocal_step_is_peak_headroom($step));
 return 0;
}

sub near_white_95_luma_gate_percent {
 my ($step,$polish,$target_delta,$de)=@_;
 my $tol=luminance_tolerance_percent($step);
 $tol=0.45 if(!defined($tol) || $tol <= 0);
 my $gate=$polish ? ($tol*0.85) : $tol;
 my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : 100;
 my $seeded_context=(ref($step) eq "HASH" && ($step->{"lg_autocal_26_seeded_move_damping"} || lg_autocal_26_full_ddc_spine_anchor_revisit_step($step))) ? 1 : 0;
 $gate=0.35 if(!$polish && $seeded_context && abs($ire-95) < 0.001 && $gate > 0.35);
 if($polish && defined($target_delta) && $target_delta > 0 && defined($de) && $de > $target_delta) {
  my $active_gate=$tol*0.75;
  $gate=$active_gate if($active_gate < $gate);
 }
 $gate=0.30 if($gate < 0.30);
 return $gate;
}

sub near_white_95_luma_needs_fine_tune {
 my ($step,$lum_pct,$de,$target_delta,$polish)=@_;
 return 0 if(!near_white_95_luma_step($step));
 return 0 if(ref($step) ne "HASH" || (!$step->{"lg_autocal_26_seeded_move_damping"} && !lg_autocal_26_full_ddc_spine_anchor_revisit_step($step)));
 return 0 if(!defined($lum_pct));
 my $gate=near_white_95_luma_gate_percent($step,$polish,$target_delta,$de);
 return abs($lum_pct+0) > $gate ? 1 : 0;
}

sub near_white_95_luma_max_step {
 my ($lum_pct,$polish)=@_;
 my $abs=defined($lum_pct) ? abs($lum_pct+0) : 0;
 return 0.25 if($polish && $abs < 1.20);
 return 0.50 if($polish);
 return 0.25 if($abs < 0.75);
 return 0.50 if($abs < 2.00);
 return 1.00;
}

sub near_white_95_luma_adjustments {
 my ($arrays,$target,$step,$lum_pct,$de,$target_delta,$tried,$stalls,$source,$state,$polish)=@_;
 return undef if(!near_white_95_luma_step($step));
 my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : 100;
 return undef if($ire >= 98.9 && ref($step) eq "HASH" && !$step->{"lg_autocal_26_seeded_move_damping"} && !lg_autocal_26_full_ddc_spine_anchor_revisit_step($step));
 return undef if(ref($arrays) ne "HASH" || ref($target) ne "HASH");
 return undef if(!has_luminance_channel($arrays,$target));
 return undef if(!defined($lum_pct));
 my $gate=near_white_95_luma_gate_percent($step,$polish,$target_delta,$de);
 return undef if(abs($lum_pct) <= $gate);
 my $max_step=near_white_95_luma_max_step($lum_pct,$polish);
 my $adjustments=neutral_luminance_adjustments($arrays,$target,($lum_pct/100),$de,$stalls,$tried,0.25,$max_step,0,$step,$source||"near_white_95_luma",$state);
 return undef if(ref($adjustments) ne "ARRAY");
 foreach my $adj (@{$adjustments}) {
  next if(ref($adj) ne "HASH");
  $adj->{"near_white_95_luma"}=1;
  $adj->{"committed_polish_near_white_95_luma"}=1 if(($source||"") =~ /^committed_polish/);
 }
 return $adjustments;
}

sub low_shadow_3_4_luma_far_from_target {
 my ($step,$lum_pct)=@_;
 return 0 if(ref($step) ne "HASH" || !defined($step->{"ire"}) || !defined($lum_pct));
 my $ire=$step->{"ire"}+0;
 return 0 if($ire <= 2.5001 || $ire > 4.1001);
 return abs($lum_pct) >= (luminance_tolerance_percent($step)*2.0) ? 1 : 0;
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
	  $low_cap=1 if(low_shadow_3_4_luma_far_from_target($step,$luminance_err*100) && $low_cap < 1);
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

sub low_shadow_luminance_response_escalation {
 my ($step,$before_lum_pct,$after_lum_pct,$base_cap)=@_;
 return ($base_cap,1,"adequate_response",0) if(!defined($before_lum_pct) || !defined($after_lum_pct));
 my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : 5;
 return ($base_cap,1,"protected_noise_floor",0) if($ire > 0 && $ire <= 2.5001);
 my $before_abs=abs($before_lum_pct);
 my $after_abs=abs($after_lum_pct);
 my $accept=low_shadow_luminance_acceptance_percent($step);
 return ($base_cap,1,"near_target",0) if($after_abs <= $accept*1.25);
 my $improvement=$before_abs-$after_abs;
 my $same_side=(($before_lum_pct < 0 && $after_lum_pct < 0) || ($before_lum_pct > 0 && $after_lum_pct > 0)) ? 1 : 0;
 return ($base_cap,1,"crossed_target",0) if(!$same_side && $after_abs <= $before_abs);
 return ($base_cap,1,"wrong_direction",0) if($improvement < -0.05);
 my $ratio=($before_abs > 0.0001) ? ($improvement/$before_abs) : 1;
 my $mult=1;
 my $reason="adequate_response";
 if($improvement < 0.20 || $ratio < 0.18) {
  $mult=2.0;
  $reason="insufficient_response_x2";
 } elsif($improvement < 0.45 || $ratio < 0.32) {
  $mult=1.5;
  $reason="insufficient_response_x1_5";
 }
 return ($base_cap,$mult,$reason,0) if($mult <= 1.0001);
 my $limit=2;
 $limit=3 if($ire > 3.1001 && $ire <= 4.1001);
 $limit=4 if($ire > 4.1001 && $ire <= 5.1001);
 $limit=6 if($ire > 5.1001 && $ire <= 10.1001);
 my $cap=$base_cap*$mult;
 $cap=$limit if($cap > $limit);
 $cap=$base_cap if($cap < $base_cap);
 return ($cap,$mult,$reason,1);
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
 my $previous_improvement=abs($before_lum_pct)-abs($after_lum_pct);
 return undef if($previous_improvement < -0.05);
 my $ideal=$start-($before_lum_pct/$slope);
 my $current=$from_start ? $start : ($arrays->{"adjustingLuminance"}[$idx]||0);
 my $delta=$ideal-$current;
 return undef if(abs($delta) < 0.18);
 my $cap=low_shadow_luminance_response_cap($step,$after_lum_pct);
 my ($scaled_cap,$response_multiplier,$cap_reason,$insufficient)=low_shadow_luminance_response_escalation($step,$before_lum_pct,$after_lum_pct,$cap);
 $cap=$scaled_cap if(defined($scaled_cap) && $scaled_cap > $cap);
 $delta=$cap if($delta > $cap);
 $delta=-$cap if($delta < -$cap);
 my $next=round_ddc_quarter($current+$delta);
 return undef if(abs($next-$current) < 0.0001);
 return undef if(tried_value_exists($tried,"adjustingLuminance",$next));
 return [{ channel=>"lum", setting=>"adjustingLuminance", current=>$current, next=>$next, delta=>$next-$current, neutral_luminance=>1, low_shadow_luminance=>1, low_shadow_luminance_response_scaled=>($response_multiplier > 1.0001 ? 1 : undef), response_multiplier=>$response_multiplier+0, cap_reason=>$cap_reason, insufficient_luminance_response=>$insufficient ? 1 : undef, response_model=>1, slope=>$slope+0, predicted_error=>($after_lum_pct+($slope*($next-$end)))+0, previous_delta=>$end-$start, previous_before_error=>$before_lum_pct+0, previous_after_error=>$after_lum_pct+0, remaining_error=>abs($after_lum_pct)+0 }];
}

sub body_luminance_response_cap {
 my ($step,$headroom_105_body_refinement)=@_;
 return undef if(ref($step) ne "HASH" || !defined($step->{"ire"}));
 my $ire=$step->{"ire"}+0;
 return 1.0 if($headroom_105_body_refinement && $ire >= 104.5 && $ire < 108.5);
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
 my $headroom_105_body=headroom_105_post_seed_body_refinement($step,$arrays,$target,$tried);
 return undef if(autocal_step_is_low_shadow($step) || (autocal_step_is_fast_headroom($step) && !$headroom_105_body) || autocal_step_is_white($step));
 my $cap=body_luminance_response_cap($step,$headroom_105_body);
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
  return [{ channel=>"lum", setting=>"adjustingLuminance", current=>$current, next=>$next, delta=>$next-$current, neutral_luminance=>1, body_luminance=>1, response_model=>1, slope=>$slope+0, predicted_error=>$predicted+0, headroom_105_body_refinement=>$headroom_105_body ? 1 : undef }];
 }
 return undef;
}

sub high_end_paired_luma_allowed {
 my ($config,$step,$target,$paired_white_step)=@_;
 return 0 if($paired_white_step);
 return 0 if(lg_autocal_26_anchor_predrive_enabled($config));
 my $standalone_non_spine=(ref($config) eq "HASH" && $config->{"lg_autocal_26"} && !$config->{"full_workflow"} && !autocal_config_is_touchup($config) && !autocal_config_is_post_3d_polish($config) && !lg_autocal_26_full_ddc_spine_enabled($config)) ? 1 : 0;
 my $full_workflow_first_greyscale_non_spine=(ref($config) eq "HASH" && $config->{"lg_autocal_26"} && $config->{"full_workflow"} && !autocal_config_is_touchup($config) && !autocal_config_is_post_3d_polish($config) && !lg_autocal_26_full_ddc_spine_enabled($config)) ? 1 : 0;
 return 0 if(!lg_autocal_26_full_ddc_spine_enabled($config) && !$standalone_non_spine && !$full_workflow_first_greyscale_non_spine);
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
 return undef if(luma_probe_family_suppressed($tried,$target,$current,$next,$step,"high_end_paired_luma"));
 my $luma={ channel=>"lum", setting=>"adjustingLuminance", current=>$current, next=>$next, delta=>$next-$current, high_end_paired_luma=>1 };
 return { luma_adjustment=>$luma, rgb_move=>$move, luma_delta=>$next-$current };
}

sub body_luminance_priority_adjustments {
	 my ($arrays,$target,$luminance_err,$de,$stalls,$tried,$step)=@_;
	 my $headroom_105_body=headroom_105_post_seed_body_refinement($step,$arrays,$target,$tried);
	 return undef if(autocal_step_is_low_shadow($step) || (autocal_step_is_fast_headroom($step) && !$headroom_105_body) || autocal_step_is_white($step) || strict_tried_for_step($step));
	 return undef if(!has_luminance_channel($arrays,$target));
	 $luminance_err=0 if(!defined($luminance_err));
	 my $lum_pct=$luminance_err*100;
 my $threshold=luminance_tolerance_percent($step)*3;
 $threshold=8 if($threshold < 8);
 return undef if(abs($lum_pct) < $threshold);
 my $max_step=abs($luminance_err) >= 0.20 ? 4 : (abs($luminance_err) >= 0.12 ? 2 : 1);
 my $adjustments=neutral_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,0.25,$max_step,0,$step,"body_luminance_priority");
 if(ref($adjustments) eq "ARRAY") {
  foreach my $adj (@{$adjustments}) {
   next if(ref($adj) ne "HASH");
   $adj->{"body_luminance_priority"}=1;
   $adj->{"headroom_105_body_refinement"}=1 if($headroom_105_body);
  }
 }
 return $adjustments;
}

sub full_ddc_spine_seeded_body_luminance_priority_adjustments {
	 my ($config,$arrays,$target,$luminance_err,$de,$stalls,$tried,$step)=@_;
	 return undef if(!lg_autocal_26_full_ddc_spine_enabled($config));
	 return undef if(ref($step) ne "HASH" || !$step->{"lg_autocal_26_seeded_move_damping"});
	 return undef if(ref($target) ne "HASH" || lg_autocal_26_full_ddc_spine_body_anchor($target));
	 return undef if(autocal_step_is_low_shadow($step) || autocal_step_is_fast_headroom($step) || autocal_step_is_white($step) || strict_tried_for_step($step));
	 return undef if(!has_luminance_channel($arrays,$target));
 $luminance_err=0 if(!defined($luminance_err));
 my $lum_pct=$luminance_err*100;
 my $tol=luminance_tolerance_percent($step);
 $tol=2 if(!defined($tol) || $tol <= 0);
 my $threshold=$tol*1.05;
 $threshold=2.0 if($threshold < 2.0);
 return undef if(abs($lum_pct) < $threshold);
 my $ire=(defined($step->{"ire"})) ? ($step->{"ire"}+0) : 50;
 my $max_step=1;
 $max_step=2 if(abs($lum_pct) >= 10 && $ire >= 15);
 $max_step=1 if($ire <= 35 && $max_step > 1);
 my $adjustments=neutral_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,0.25,$max_step,0,$step,"full_ddc_spine_seeded_body_luminance");
 if(ref($adjustments) eq "ARRAY") {
  foreach my $adj (@{$adjustments}) {
   next if(ref($adj) ne "HASH");
   $adj->{"body_luminance_priority"}=1;
   $adj->{"full_ddc_spine_seeded_body_luminance_priority"}=1;
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
	 my $adjustments=neutral_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,0.25,$max_step,1,$step,($micro ? "fine_low_shadow_luminance" : "main_low_shadow_luminance"));
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

sub low_shadow_chroma_luminance_coupled_adjustments {
 my ($error,$arrays,$target,$luminance_err,$de,$target_delta,$tried,$step,$micro)=@_;
 return undef if(!autocal_step_is_low_shadow($step));
 return undef if(ref($error) ne "HASH" || ref($arrays) ne "HASH" || ref($target) ne "HASH");
 return undef if(!has_luminance_channel($arrays,$target));
 my $idx=$target->{"index"};
 return undef if(!defined($idx));
 $target_delta=0.5 if(!defined($target_delta) || $target_delta <= 0);
 $luminance_err=0 if(!defined($luminance_err));
 my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : 5;
 return undef if($ire > 0 && $ire <= 2.5001);
 my $lum_pct=$luminance_err*100;
 my $luma_tol=luminance_tolerance_percent($step);
 my $wild_luma_gate=$luma_tol*1.25;
 $wild_luma_gate=5.0 if($wild_luma_gate < 5.0);
 return undef if(abs($lum_pct) > $wild_luma_gate);
 my $chroma_mag=chroma_error_magnitude($error);
 return undef if($chroma_mag < 0.035 && (!defined($de) || $de <= ($target_delta+1.0)));
 my $far_3_4_luma=(!$micro && low_shadow_3_4_luma_far_from_target($step,$lum_pct) && defined($de) && $de > ($target_delta+1.0)) ? 1 : 0;
 my $rgb_cap=1.5;
 $rgb_cap=1.0 if($ire <= 5.1001);
 $rgb_cap=0.5 if($ire <= 4.1001);
 $rgb_cap=0.25 if($ire <= 2.5001);
 $rgb_cap=0.5 if($micro && $rgb_cap > 0.5);
 my $floor=rgb_error_floor($de,$target_delta,$micro ? 1 : 0);
 $floor=0.004 if($floor < 0.004);
 my $max_abs=0;
 foreach my $ch (qw(r g b)) {
  my $abs=abs($error->{$ch}||0);
  $max_abs=$abs if($abs > $max_abs);
 }
 return undef if($max_abs < $floor);
 my $strict_tried=1;
 my @out;
 foreach my $ch (sort { abs($error->{$b}||0) <=> abs($error->{$a}||0) } qw(r g b)) {
  my $err=$error->{$ch}||0;
  next if(abs($err) < $floor);
  my $setting=channel_setting($ch);
  my $arr=$arrays->{$setting};
  next if(ref($arr) ne "ARRAY" || $idx >= @{$arr});
  my $current=defined($arr->[$idx]) ? ($arr->[$idx]+0) : 0;
  my $direction=($err > 0) ? -1 : 1;
  my $mag=round_ddc_quarter($rgb_cap*(abs($err)/$max_abs));
  $mag=0.25 if($mag < 0.25);
  $mag=$rgb_cap if($mag > $rgb_cap);
  my ($next,$damped)=next_untried_value($current,$direction*$mag,$tried,$setting,0.25,$strict_tried);
  next if(!defined($next) || abs($next-$current) < 0.0001);
  push @out,{
   channel=>$ch, setting=>$setting, current=>$current, next=>$next, delta=>$next-$current,
   damped=>$damped ? 1 : 0, micro=>$micro ? 1 : undef, low_shadow_chroma_luma=>1,
   source=>"low_shadow_chroma_luma", remaining_error=>abs($err)
  };
 }
 return undef if(!@out);
 my $luma_meaningful=$luma_tol*0.20;
 $luma_meaningful=0.5 if($luma_meaningful < 0.5);
 if(abs($lum_pct) >= $luma_meaningful) {
  my $arr=$arrays->{"adjustingLuminance"};
  if(ref($arr) eq "ARRAY" && $idx < @{$arr}) {
   my $current=defined($arr->[$idx]) ? ($arr->[$idx]+0) : 0;
   my $direction=($lum_pct > 0) ? -1 : 1;
   my $luma_cap=1.0;
   $luma_cap=0.5 if($ire <= 5.1001);
   $luma_cap=0.25 if($ire <= 4.1001);
   $luma_cap=0.5 if($far_3_4_luma && $luma_cap < 0.5);
   $luma_cap=0.25 if($micro && $luma_cap > 0.25);
   my $mag=round_ddc_quarter(abs($lum_pct)*0.20);
   $mag=0.25 if($mag < 0.25);
   $mag=$luma_cap if($mag > $luma_cap);
   my ($next,$damped)=next_untried_value($current,$direction*$mag,$tried,"adjustingLuminance",0.25,$strict_tried);
   if(defined($next) && abs($next-$current) >= 0.0001 && !luma_probe_family_suppressed($tried,$target,$current,$next,$step,"low_shadow_chroma_luma",$LG_AUTOCAL_STATE)) {
    push @out,{
     channel=>"lum", setting=>"adjustingLuminance", current=>$current, next=>$next, delta=>$next-$current,
     damped=>$damped ? 1 : 0, micro=>$micro ? 1 : undef, neutral_luminance=>1,
     low_shadow_luminance=>1, low_shadow_chroma_luma=>1, source=>"low_shadow_chroma_luma",
     remaining_error=>abs($lum_pct)
    };
   }
  }
 }
 return \@out;
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
	 my $planned_step=neutral_luminance_step($luminance_err,$de,$stalls,$min_step,$max_step);
	 my @magnitudes=($planned_step);
	 push @magnitudes,1 if($planned_step > 1);
	 push @magnitudes,0.5 if($planned_step > 0.5);
	 push @magnitudes,0.25 if($planned_step > 0.25 && $min_step <= 0.25);
	 push @magnitudes,0.10 if($planned_step > 0.10 && $min_step <= 0.10);
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

sub hdr20_body_chroma_luma_adjustments {
	 my ($error,$arrays,$target,$step,$de,$target_delta,$luminance_err,$stalls,$tried,$min_step,$micro)=@_;
	 return undef if(!hdr20_body_chroma_priority_needed($step,$error,$de,$target_delta));
	 return undef if(ref($arrays) ne "HASH" || ref($target) ne "HASH");
	 $min_step ||= ($micro ? 0.20 : 0.25);
	 $target_delta=0.5 if(!defined($target_delta) || $target_delta <= 0);
	 my $idx=$target->{"index"};
	 return undef if(!defined($idx));
	 my $chroma=chroma_error_magnitude($error);
	 my $lum_pct=defined($luminance_err) ? ($luminance_err+0)*100 : 0;
	 my $tol=luminance_tolerance_percent($step);
	 $tol=2 if(!defined($tol) || $tol <= 0);
	 my $max_step=($micro ? 0.5 : ((defined($de) && $de > 12) ? 2.0 : ((defined($de) && $de > 4) ? 1.0 : 0.5)));
	 my $floor=rgb_error_floor($de,$target_delta,$micro ? 1 : 0);
	 $floor=0.0030 if(!$micro && $floor < 0.0030);
	 $floor=0.0020 if($micro && $floor < 0.0020);
	 my $max_channels=($chroma >= 0.060 && !$micro) ? 1 : ($micro ? 1 : 2);
	 my @channels=sort {
	  my $sa=tried_setting_value_count($tried,channel_setting($a));
	  my $sb=tried_setting_value_count($tried,channel_setting($b));
	  (($sa >= 5) <=> ($sb >= 5)) || (abs($error->{$b}||0) <=> abs($error->{$a}||0))
	 } qw(r g b);
	 my @fresh=grep { tried_setting_value_count($tried,channel_setting($_)) < 5 } @channels;
	 @channels=@fresh if(@fresh);
	 my @out;
	 foreach my $ch (@channels) {
	  my $err=$error->{$ch}||0;
	  next if(abs($err) < $floor);
	  my $setting=channel_setting($ch);
	  my $arr=$arrays->{$setting};
	  next if(ref($arr) ne "ARRAY" || $idx >= @{$arr});
	  my $current=defined($arr->[$idx]) ? ($arr->[$idx]+0) : 0;
	  my $step_size=headroom_adjustment_step(abs($err),$stalls,$min_step,$max_step,$micro ? 1 : 0);
	  $step_size=$max_step if($step_size > $max_step);
	  my $direction=($err > 0) ? -1 : 1;
	  my ($next,$damped)=next_untried_value($current,$direction*$step_size,$tried,$setting,$min_step,0);
	  next if(!defined($next) || abs($next-$current) < 0.0001);
	  push @out,{ channel=>$ch, setting=>$setting, current=>$current, next=>$next, delta=>$next-$current, damped=>$damped ? 1 : 0, hdr20_body_chroma_luma=>1, hdr20_body_chroma_priority=>1, chroma_error=>$chroma+0, luminance_error_pct=>$lum_pct+0, micro=>$micro ? 1 : 0 };
	  last if(@out >= $max_channels);
	 }
	 return undef if(!@out);
	 return \@out;
	}

sub hdr20_body_mixed_rgb_error {
	 my ($error,$floor)=@_;
	 return 0 if(ref($error) ne "HASH");
	 $floor=0.020 if(!defined($floor) || $floor <= 0);
	 my ($pos,$neg,$max_abs)=(0,0,0);
	 foreach my $ch (qw(r g b)) {
	  my $err=$error->{$ch}||0;
	  my $abs=abs($err);
	  $max_abs=$abs if($abs > $max_abs);
	  $pos=1 if($err > $floor);
	  $neg=1 if($err < -$floor);
	 }
	 return ($pos && $neg && $max_abs >= $floor) ? 1 : 0;
}

sub hdr20_body_balanced_chroma_luma_adjustments {
	 my ($error,$arrays,$target,$step,$de,$target_delta,$luminance_err,$stalls,$tried,$min_step,$micro)=@_;
	 return undef if(!autocal_step_is_hdr20_body($step));
	 return undef if(ref($error) ne "HASH" || ref($arrays) ne "HASH" || ref($target) ne "HASH");
	 return undef if(!hdr20_body_chroma_priority_needed($step,$error,$de,$target_delta));
	 $min_step ||= ($micro ? 0.20 : 0.25);
	 $target_delta=0.5 if(!defined($target_delta) || $target_delta <= 0);
	 my $idx=$target->{"index"};
	 return undef if(!defined($idx));
	 my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : 0;
	 my $lum_pct=defined($luminance_err) ? ($luminance_err+0)*100 : 0;
	 my $chroma=chroma_error_magnitude($error);
	 my $max_abs=0;
	 foreach my $ch (qw(r g b)) {
	  my $abs=abs($error->{$ch}||0);
	  $max_abs=$abs if($abs > $max_abs);
	 }
	 return undef if($max_abs < 0.020);

	 my $rgb_cap=$micro ? 1.0 : 4.0;
	 $rgb_cap=6.0 if(!$micro && (defined($de) && $de > 10 || $chroma >= 0.120));
	 $rgb_cap=8.0 if(!$micro && $chroma >= 0.220);
	 if($ire < 80 && $rgb_cap > 2.0) {
	  my $keep_fast_body=(defined($de) && $de > ($target_delta+2.0) && $chroma >= 0.035) ? 1 : 0;
	  $rgb_cap=$keep_fast_body ? 4.0 : 2.0;
	 }
	 if($micro && defined($de) && $de > ($target_delta+2.0) && $chroma >= 0.035) {
	  $rgb_cap=1.5;
	 }
	 $rgb_cap+=1.0 if(!$micro && ($stalls||0) >= 2 && $rgb_cap < 8.0);
	 my $floor=rgb_error_floor($de,$target_delta,$micro ? 1 : 0);
	 $floor=0.0060 if(!$micro && $floor < 0.0060);
	 $floor=0.0030 if($micro && $floor < 0.0030);

	 my @out;
	 foreach my $ch (sort { abs($error->{$b}||0) <=> abs($error->{$a}||0) } qw(r g b)) {
	  my $err=$error->{$ch}||0;
	  next if(abs($err) < $floor);
	  my $setting=channel_setting($ch);
	  my $arr=$arrays->{$setting};
	  next if(ref($arr) ne "ARRAY" || $idx >= @{$arr});
	  my $current=defined($arr->[$idx]) ? ($arr->[$idx]+0) : 0;
	  my $direction=($err > 0) ? -1 : 1;
	  my $mag=round_ddc_quarter($rgb_cap*(abs($err)/$max_abs));
	  $mag=$min_step if($mag < $min_step);
	  $mag=$rgb_cap if($mag > $rgb_cap);
	  my ($next,$damped)=next_untried_value($current,$direction*$mag,$tried,$setting,$min_step,0);
	  next if(!defined($next) || abs($next-$current) < 0.0001);
	  push @out,{
	   channel=>$ch,
	   setting=>$setting,
	   current=>$current,
	   next=>$next,
	   delta=>$next-$current,
	   damped=>$damped ? 1 : 0,
	   hdr20_body_balanced_chroma_luma=>1,
	   hdr20_body_chroma_priority=>1,
	   chroma_error=>$chroma+0,
	   luminance_error_pct=>$lum_pct+0,
	   remaining_error=>abs($err),
	   micro=>$micro ? 1 : 0
	  };
	 }
	 return undef if(!@out);

	 if(has_luminance_channel($arrays,$target)) {
	  my $tol=luminance_tolerance_percent($step);
	  $tol=2 if(!defined($tol) || $tol <= 0);
	  my $luma_gate=$micro ? ($tol*0.45) : ($tol*0.65);
	  $luma_gate=0.35 if($luma_gate < 0.35);
		  my $chroma_luma_compensation=(@out && defined($de) && $de > ($target_delta+1.5) && $chroma >= 0.030 && abs($lum_pct) >= ($micro ? 0.45 : 0.25)) ? 1 : 0;
		  if(abs($lum_pct) >= $luma_gate || $chroma_luma_compensation) {
		   my $arr=$arrays->{"adjustingLuminance"};
		   if(ref($arr) eq "ARRAY" && $idx < @{$arr}) {
		    my $current=defined($arr->[$idx]) ? ($arr->[$idx]+0) : 0;
		    my $direction=($lum_pct > 0) ? -1 : 1;
	    my $luma_cap=$micro ? 1.0 : 4.0;
	    $luma_cap=6.0 if(!$micro && abs($lum_pct) >= 8.0);
	    $luma_cap=8.0 if(!$micro && abs($lum_pct) >= 14.0);
		    my $mag=round_ddc_quarter(abs($lum_pct)*0.45);
		    $mag=$min_step if($mag < $min_step);
		    $mag=0.50 if($chroma_luma_compensation && $mag < 0.50);
		    $mag=$luma_cap if($mag > $luma_cap);
		    my ($next,$damped)=next_untried_value($current,$direction*$mag,$tried,"adjustingLuminance",$min_step,0);
		    if(
		     defined($next) &&
		     abs($next-$current) >= 0.0001 &&
		     ($chroma_luma_compensation || !hdr20_body_family_suppressed($tried,"luminance",$direction)) &&
		     hdr20_body_luminance_response_allows_move($step,$lum_pct,$next-$current,"hdr20_body_balanced_chroma_luma") &&
		     !luma_probe_family_suppressed($tried,$target,$current,$next,$step,"hdr20_body_balanced_chroma_luma",$LG_AUTOCAL_STATE)
		    ) {
		     push @out,{
		      channel=>"lum",
		      setting=>"adjustingLuminance",
	      current=>$current,
	      next=>$next,
	      delta=>$next-$current,
	      damped=>$damped ? 1 : 0,
	      neutral_luminance=>1,
	      hdr20_body_luminance=>1,
	      hdr20_body_balanced_chroma_luma=>1,
	      hdr20_body_chroma_luma_compensation=>$chroma_luma_compensation ? 1 : undef,
	      luminance_error_pct=>$lum_pct+0,
	      micro=>$micro ? 1 : 0
	     };
	    }
	   }
	  }
	 }

	 trace_109($step,"hdr20_body_balanced_chroma_luma_plan",{
	  ire=>$ire+0,
	  index=>$idx+0,
	  delta_e=>defined($de)?$de+0:undef,
	  chroma_error=>$chroma+0,
	  luminance_error_pct=>$lum_pct+0,
	  rgb_cap=>$rgb_cap+0,
	  rgb_error=>$error,
	  adjustment_count=>scalar(@out),
	  values=>trace_target_values($arrays,$target)
	 });
	 return \@out;
}

sub hdr20_body_family_suppressed {
	 my ($tried,$family,$direction)=@_;
	 return 0 if(ref($tried) ne "HASH" || !$family);
	 $direction=0 if(!defined($direction));
	 return 0 if(ref($tried->{"__hdr20_body_suppressed_family"}) ne "HASH");
	 return $tried->{"__hdr20_body_suppressed_family"}{$family."|".$direction} ? 1 : 0;
}

sub hdr20_body_luminance_response_allows_move {
	 my ($step,$lum_pct,$delta,$source)=@_;
	 return 1 if(ref($step) ne "HASH" || !autocal_step_is_hdr20_body($step));
	 return 1 if(!defined($lum_pct) || !defined($delta) || abs($delta) < 0.0001);
	 my $model=lg_autocal_26_response_model_for_step($LG_AUTOCAL_STATE,$step);
	 my $entry=(ref($model) eq "HASH" && ref($model->{"luminance"}) eq "HASH") ? $model->{"luminance"}{"adjustingLuminance"} : undef;
	 return 1 if(ref($entry) ne "HASH" || !defined($entry->{"slope"}));
	 my $slope=$entry->{"slope"}+0;
	 return 1 if(abs($slope) < 0.05);
	 my $predicted=($lum_pct+0)+($slope*($delta+0));
	 return 1 if(abs($predicted) <= abs($lum_pct+0)-0.05);
	 trace_109($step,"hdr20_body_luminance_response_blocked",{
	  source=>$source||"hdr20_body_luminance",
	  luminance_error_pct=>$lum_pct+0,
	  planned_delta=>$delta+0,
	  slope=>$slope+0,
	  predicted_error=>$predicted+0
	 });
	 return 0;
}

sub suppress_hdr20_body_family {
	 my ($tried,$step,$family,$direction,$reason,$before_lum_pct,$after_lum_pct,$before_de,$after_de)=@_;
	 return 0 if(ref($tried) ne "HASH" || !$family);
	 $direction=0 if(!defined($direction));
	 my $key=$family."|".$direction;
	 $tried->{"__hdr20_body_suppressed_family"}={} if(ref($tried->{"__hdr20_body_suppressed_family"}) ne "HASH");
	 return 0 if($tried->{"__hdr20_body_suppressed_family"}{$key});
	 $tried->{"__hdr20_body_suppressed_family"}{$key}=1;
	 trace_109($step,"hdr20_body_family_suppressed",{
	  family=>$family,
	  direction=>$direction+0,
	  reason=>$reason||"rejected",
	  before_luminance_error_pct=>defined($before_lum_pct)?$before_lum_pct+0:undef,
	  after_luminance_error_pct=>defined($after_lum_pct)?$after_lum_pct+0:undef,
	  before_delta_e=>defined($before_de)?$before_de+0:undef,
	  after_delta_e=>defined($after_de)?$after_de+0:undef
	 });
	 return 1;
}

sub hdr20_body_luminance_rgb_direction {
	 my ($adjustments)=@_;
	 return undef if(ref($adjustments) ne "ARRAY" || @{$adjustments} < 3);
	 my $direction;
	 my $count=0;
	 foreach my $adj (@{$adjustments}) {
	  return undef if(ref($adj) ne "HASH" || !$adj->{"hdr20_body_luminance_rgb"});
	  my $delta=defined($adj->{"delta"}) ? ($adj->{"delta"}+0) : undef;
	  return undef if(!defined($delta) || abs($delta) < 0.0001);
	  my $dir=$delta < 0 ? -1 : 1;
	  $direction=$dir if(!defined($direction));
	  return undef if($direction != $dir);
	  $count++;
	 }
	 return undef if($count < 3);
	 return $direction;
}

sub hdr20_body_luma_direction {
	 my ($adjustments)=@_;
	 my $adj=luma_only_adjustment($adjustments);
	 return undef if(ref($adj) ne "HASH");
	 my $delta=defined($adj->{"delta"}) ? ($adj->{"delta"}+0) : undef;
	 return undef if(!defined($delta) || abs($delta) < 0.0001);
	 return $delta < 0 ? -1 : 1;
}

sub record_hdr20_body_bad_adjustment_family {
	 my ($tried,$step,$adjustments,$before_lum_pct,$after_lum_pct,$before_de,$after_de,$before_score,$after_score)=@_;
	 return undef if(ref($step) ne "HASH" || !autocal_step_is_hdr20_body($step));
	 return undef if(ref($tried) ne "HASH" || ref($adjustments) ne "ARRAY");
	 my $family;
	 my $direction;
	 $direction=hdr20_body_luminance_rgb_direction($adjustments);
	 $family="rgb_luminance" if(defined($direction));
	 if(!$family) {
	  $direction=hdr20_body_luma_direction($adjustments);
	  $family="luminance" if(defined($direction));
	 }
	 return undef if(!$family || !defined($direction));
	 my $before_abs=defined($before_lum_pct) ? abs($before_lum_pct+0) : undef;
	 my $after_abs=defined($after_lum_pct) ? abs($after_lum_pct+0) : undef;
	 my $y_worse=(defined($before_abs) && defined($after_abs) && $after_abs > $before_abs+0.05) ? 1 : 0;
	 my $de_worse=(defined($before_de) && defined($after_de) && ($after_de+0) > ($before_de+0)+0.05) ? 1 : 0;
	 my $score_worse=(defined($before_score) && defined($after_score) && ($after_score+0) > ($before_score+0)+0.05) ? 1 : 0;
	 return undef if(!$y_worse && !$de_worse && !$score_worse);
	 suppress_hdr20_body_family($tried,$step,$family,$direction,$y_worse ? "luminance_worse" : "score_worse",$before_lum_pct,$after_lum_pct,$before_de,$after_de);
	 return { family=>$family, direction=>$direction+0, reason=>$y_worse ? "luminance_worse" : "score_worse" };
}

sub hdr20_body_rgb_luminance_vector_adjustments {
	 my ($error,$arrays,$target,$step,$de,$target_delta,$luminance_err,$stalls,$tried,$min_step,$micro,$reason)=@_;
	 return undef if(!autocal_step_is_hdr20_body($step));
	 return undef if(ref($error) ne "HASH" || ref($arrays) ne "HASH" || ref($target) ne "HASH");
	 return undef if(!defined($luminance_err));
	 $min_step ||= ($micro ? 0.20 : 0.25);
	 $target_delta=0.5 if(!defined($target_delta) || $target_delta <= 0);
	 my $idx=$target->{"index"};
	 return undef if(!defined($idx));
	 my $lum_pct=($luminance_err+0)*100;
	 my $tol=luminance_tolerance_percent($step);
	 $tol=2 if(!defined($tol) || $tol <= 0);
	 my $chroma=chroma_error_magnitude($error);
	 my $needs_luma_help=abs($lum_pct) >= ($tol*1.25) ? 1 : 0;
	 $needs_luma_help=1 if(defined($de) && $de > ($target_delta+2.0) && abs($lum_pct) >= 0.75);
	 return undef if(!$needs_luma_help);
	 my $direction=($lum_pct > 0) ? -1 : 1;
	 my $abs_lum=abs($lum_pct);
	 my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : 0;
	 my $mixed_chroma=hdr20_body_mixed_rgb_error($error,0.018);
	 my $force_luma_clamp=(!$micro && $direction < 0 && $ire >= 70 && $abs_lum >= 8.0) ? 1 : 0;
	 return undef if(!$force_luma_clamp && hdr20_body_family_suppressed($tried,"rgb_luminance",$direction));
	 my $base=$micro ? 0.25 : 0.50;
	 if(!$micro) {
	  $base=1.0 if($abs_lum >= 2.0 || (defined($de) && $de >= 3.0));
	  $base=2.0 if($abs_lum >= 5.0 || (defined($de) && $de >= 7.0));
	  $base=3.0 if($abs_lum >= 9.0 || (defined($de) && $de >= 12.0));
	  $base=4.0 if($abs_lum >= 14.0);
	  $base=6.0 if($abs_lum >= 22.0);
	  $base+=0.5*($stalls||0) if(($stalls||0) >= 2);
	  if($force_luma_clamp) {
	   $base=6.0 if($base < 6.0);
	   $base+=1.0*($stalls||0) if(($stalls||0) >= 1);
	  }
	 }
	 my $cap=$micro ? 1.0 : 8.0;
	 $base=$cap if($base > $cap);
	 my $max_abs=0;
	 foreach my $ch (qw(r g b)) {
	  my $abs=abs($error->{$ch}||0);
	  $max_abs=$abs if($abs > $max_abs);
	 }
	 my @out;
	 foreach my $ch (sort { abs($error->{$b}||0) <=> abs($error->{$a}||0) } qw(r g b)) {
	  my $setting=channel_setting($ch);
	  my $arr=$arrays->{$setting};
	  next if(ref($arr) ne "ARRAY" || $idx >= @{$arr});
		  my $current=defined($arr->[$idx]) ? ($arr->[$idx]+0) : 0;
		  my $err=$error->{$ch}||0;
		  my $scale=0.80;
		  my $rgb_direction=$direction;
		  if($mixed_chroma) {
		   $rgb_direction=($err > 0) ? -1 : 1;
		   my $ratio=$max_abs > 0 ? abs($err)/$max_abs : 1;
		   $scale=0.25+(0.75*$ratio);
		   $scale=1.15 if($scale > 1.15);
		   $scale=0.35 if($scale < 0.35);
		  } elsif($force_luma_clamp) {
		   $scale=1.0;
		  } elsif($direction < 0) {
	   $scale=1.35 if($err > 0.003);
	   $scale=0.45 if($err < -0.010 && $chroma > 0.025);
	  } else {
	   $scale=1.35 if($err < -0.003);
	   $scale=0.45 if($err > 0.010 && $chroma > 0.025);
	  }
	  $scale=1.0 if($max_abs < 0.006);
		  my $mag=round_ddc_quarter($base*$scale);
		  $mag=$min_step if($mag < $min_step);
		  $mag=$cap if($mag > $cap);
		  my ($next,$damped)=next_untried_value($current,$rgb_direction*$mag,$tried,$setting,$min_step,0);
	  next if(!defined($next) || abs($next-$current) < 0.0001);
	  push @out,{
	   channel=>$ch,
	   setting=>$setting,
	   current=>$current,
	   next=>$next,
	   delta=>$next-$current,
	   damped=>$damped ? 1 : 0,
		   hdr20_body_luminance_rgb=>1,
		   hdr20_body_mixed_rgb_luma=>$mixed_chroma ? 1 : undef,
		   hdr20_body_balanced_chroma_luma=>1,
	   hdr20_body_force_luma_clamp=>$force_luma_clamp ? 1 : undef,
	   luminance_error_pct=>$lum_pct+0,
	   chroma_error=>$chroma+0,
	   source=>$reason||"hdr20_body_rgb_luminance_vector",
	   micro=>$micro ? 1 : 0
	  };
	 }
	 if(has_luminance_channel($arrays,$target) && !hdr20_body_family_suppressed($tried,"luminance",$direction)) {
	  my $arr=$arrays->{"adjustingLuminance"};
		  if(ref($arr) eq "ARRAY" && $idx < @{$arr}) {
		   my $current=defined($arr->[$idx]) ? ($arr->[$idx]+0) : 0;
		   my $mag=$micro ? 0.25 : $base;
		   $mag=abs($lum_pct)*0.22 if(!$micro && $mixed_chroma && abs($lum_pct)*0.22 > $mag);
		   my $luma_cap=$force_luma_clamp ? 8.0 : (($ire <= 25.0001) ? 10.0 : (($ire <= 60.0001) ? 8.0 : 6.0));
	   $mag=$luma_cap if($mag > $luma_cap);
	   my ($next,$damped)=next_untried_value($current,$direction*$mag,$tried,"adjustingLuminance",$min_step,0);
	   if(
	    defined($next) &&
	    abs($next-$current) >= 0.0001 &&
	    hdr20_body_luminance_response_allows_move($step,$lum_pct,$next-$current,"hdr20_body_rgb_luminance_vector") &&
	    !luma_probe_family_suppressed($tried,$target,$current,$next,$step,"hdr20_body_rgb_luminance_vector",$LG_AUTOCAL_STATE)
	   ) {
	    push @out,{
	     channel=>"lum",
	     setting=>"adjustingLuminance",
	     current=>$current,
	     next=>$next,
	     delta=>$next-$current,
	     damped=>$damped ? 1 : 0,
		     neutral_luminance=>1,
		     hdr20_body_luminance_rgb=>1,
		     hdr20_body_mixed_rgb_luma=>$mixed_chroma ? 1 : undef,
		     hdr20_body_balanced_chroma_luma=>1,
	     hdr20_body_force_luma_clamp=>$force_luma_clamp ? 1 : undef,
	     luminance_error_pct=>$lum_pct+0,
	     source=>$reason||"hdr20_body_rgb_luminance_vector",
	     micro=>$micro ? 1 : 0
	    };
	   }
	  }
	 }
	 return undef if(@out < 2);
	 trace_109($step,"hdr20_body_rgb_luminance_vector_plan",{
	  luminance_error_pct=>$lum_pct+0,
	  delta_e=>defined($de)?$de+0:undef,
	  base_step=>$base+0,
	  direction=>$direction+0,
	  mixed_chroma=>$mixed_chroma ? 1 : 0,
	  force_luma_clamp=>$force_luma_clamp ? 1 : 0,
	  adjustment_count=>scalar(@out),
	  reason=>$reason||"hdr20_body_rgb_luminance_vector",
	  target_values=>trace_target_values($arrays,$target)
	 });
	 return \@out;
}

sub hdr20_body_vector_response_adjustments {
	 my ($step,$adjustments,$before,$after,$arrays,$target,$tried,$source)=@_;
	 return undef if(!autocal_step_is_hdr20_body($step));
	 return undef if(ref($adjustments) ne "ARRAY" || @{$adjustments} < 2);
	 return undef if(ref($before) ne "HASH" || ref($after) ne "HASH" || ref($arrays) ne "HASH" || ref($target) ne "HASH");
	 my @vector=grep {
	  ref($_) eq "HASH" &&
	  ($_->{'hdr20_body_luminance_rgb'} || (defined($_->{'source'}) && $_->{'source'} =~ /hdr20_body.*(?:rgb|luma|luminance)/))
	 } @{$adjustments};
	 return undef if(@vector < 2);
	 return undef if(grep { ref($_) eq "HASH" && $_->{"hdr20_body_mixed_rgb_luma"} } @vector);
	 my ($luma_adj)=grep { ($_->{'setting'}||"") eq "adjustingLuminance" } @vector;
	 return undef if(ref($luma_adj) ne "HASH" || !defined($luma_adj->{"delta"}) || abs($luma_adj->{"delta"}+0) < 0.2499);
	 my $target_y=$after->{"target_luminance"};
	 $target_y=$before->{"target_luminance"} if(!defined($target_y));
	 return undef if(!defined($target_y) || $target_y <= 0);
	 my $before_lum_pct=luminance_error_percent($before,$target_y);
	 my $after_lum_pct=luminance_error_percent($after,$target_y);
	 return undef if(!defined($before_lum_pct) || !defined($after_lum_pct));
	 my $before_abs=abs($before_lum_pct+0);
	 my $after_abs=abs($after_lum_pct+0);
	 my $improvement=$before_abs-$after_abs;
	 return undef if($improvement < 0.35);
	 my $tol=luminance_tolerance_percent($step);
	 $tol=2 if(!defined($tol) || $tol <= 0);
	 return undef if($after_abs <= ($tol*1.15));
	 return undef if(($before_lum_pct+0)*($after_lum_pct+0) < 0 && $after_abs > $tol);
	 my $direction=($after_lum_pct > 0) ? -1 : 1;
	 return undef if(($luma_adj->{"delta"}+0)*$direction <= 0);
	 my $scale=$after_abs/$improvement;
	 $scale=0.50 if($scale < 0.50);
	 $scale=2.25 if($scale > 2.25);
	 my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : 50;
	 my $luma_cap=($ire <= 25.0001) ? 10.0 : (($ire <= 60.0001) ? 8.0 : 6.0);
	 my $rgb_cap=($ire <= 25.0001) ? 12.0 : (($ire <= 60.0001) ? 10.0 : 7.0);
	 my $idx=$target->{"index"};
	 return undef if(!defined($idx));
	 my @out;
	 foreach my $prev (@vector) {
	  next if(ref($prev) ne "HASH");
	  my $setting=$prev->{"setting"}||"";
	  next if($setting !~ /^(?:whiteBalanceRed|whiteBalanceGreen|whiteBalanceBlue|adjustingLuminance)$/);
	  my $arr=$arrays->{$setting};
	  next if(ref($arr) ne "ARRAY" || $idx >= @{$arr});
	  my $current=defined($arr->[$idx]) ? ($arr->[$idx]+0) : 0;
	  my $prior_delta=defined($prev->{"delta"}) ? ($prev->{"delta"}+0) : undef;
	  next if(!defined($prior_delta) || abs($prior_delta) < 0.0001);
	  next if($prior_delta*$direction <= 0);
	  my $cap=($setting eq "adjustingLuminance") ? $luma_cap : $rgb_cap;
	  my $raw_delta=$prior_delta*$scale;
	  $raw_delta=$cap if($raw_delta > $cap);
	  $raw_delta=-$cap if($raw_delta < -$cap);
	  next if(abs($raw_delta) < 0.2499);
	  my ($next,$damped)=next_untried_value($current,$raw_delta,$tried,$setting,0.25,0);
	  next if(!defined($next) || abs($next-$current) < 0.0001);
	  if($setting eq "adjustingLuminance") {
	   next if(!hdr20_body_luminance_response_allows_move($step,$after_lum_pct,$next-$current,"hdr20_body_vector_response"));
	   next if(luma_probe_family_suppressed($tried,$target,$current,$next,$step,"hdr20_body_vector_response",$LG_AUTOCAL_STATE));
	  }
	  my $channel=($setting eq "adjustingLuminance") ? "lum" : ($setting eq "whiteBalanceRed" ? "r" : ($setting eq "whiteBalanceGreen" ? "g" : "b"));
	  push @out,{
	   channel=>$channel,
	   setting=>$setting,
	   current=>$current,
	   next=>$next,
	   delta=>$next-$current,
	   damped=>$damped ? 1 : 0,
	   hdr20_body_luminance_rgb=>1,
	   hdr20_body_vector_response=>1,
	   neutral_luminance=>($setting eq "adjustingLuminance" ? 1 : undef),
	   response_multiplier=>$scale+0,
	   previous_delta=>$prior_delta+0,
	   previous_before_error=>$before_lum_pct+0,
	   previous_after_error=>$after_lum_pct+0,
	   source=>$source||"hdr20_body_vector_response"
	  };
	 }
	 return undef if(@out < 2);
	 trace_109($step,"hdr20_body_vector_response_plan",{
	  before_luminance_error_pct=>$before_lum_pct+0,
	  after_luminance_error_pct=>$after_lum_pct+0,
	  improvement_pct=>$improvement+0,
	  response_multiplier=>$scale+0,
	  adjustment_count=>scalar(@out),
	  reason=>$source||"hdr20_body_vector_response",
	  target_values=>trace_target_values($arrays,$target)
	 });
	 return \@out;
}

sub hdr20_body_luminance_rgb_adjustments {
	 my ($arrays,$target,$step,$luminance_err,$de,$stalls,$tried,$min_step)=@_;
	 return undef if(!autocal_step_is_hdr20_body($step));
	 return undef if(ref($arrays) ne "HASH" || ref($target) ne "HASH");
	 return undef if(!defined($luminance_err));
	 $min_step ||= 0.25;
	 my $lum_pct=($luminance_err+0)*100;
		 my $tol=luminance_tolerance_percent($step);
		 $tol=2 if(!defined($tol) || $tol <= 0);
		 my $threshold=$tol*1.20;
		 my $ire=(defined($target->{"ire"}) ? ($target->{"ire"}+0) : ((ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : 0));
		 my $floor=($ire >= 80) ? 0.6 : 3;
		 $threshold=$floor if($threshold < $floor);
		 $threshold=8 if($threshold > 8);
		 return undef if(abs($lum_pct) < $threshold);
		 my $idx=$target->{"index"};
		 return undef if(!defined($idx));
	 my $mag=1.0;
	 if($ire >= 80) {
	  $mag=2.0 if(abs($lum_pct) >= 2);
	  $mag=4.0 if(abs($lum_pct) >= 6);
	  $mag=6.0 if(abs($lum_pct) >= 12);
	  $mag=8.0 if(abs($lum_pct) >= 20);
	 } else {
	  $mag=2.0 if(abs($lum_pct) >= 6);
	  $mag=4.0 if(abs($lum_pct) >= 12);
	 }
	 $mag+=1.0 if($stalls >= 2 && $mag < 6.0);
	 $mag=8.0 if($mag > 8.0);
	 my $direction=($lum_pct > 0) ? -1 : 1;
		 if(has_luminance_channel($arrays,$target) && !hdr20_body_family_suppressed($tried,"luminance",$direction)) {
		  my $arr=$arrays->{"adjustingLuminance"};
			  if(ref($arr) eq "ARRAY" && $idx < @{$arr}) {
		   my $current=defined($arr->[$idx]) ? ($arr->[$idx]+0) : 0;
		   my ($next,$damped)=next_untried_value($current,$direction*$mag,$tried,"adjustingLuminance",$min_step,0);
		   if(defined($next) && abs($next-$current) >= 0.0001 && hdr20_body_luminance_response_allows_move($step,$lum_pct,$next-$current,"hdr20_body_luminance") && !luma_probe_family_suppressed($tried,$target,$current,$next,$step,"hdr20_body_luminance",$LG_AUTOCAL_STATE)) {
		    return [{
		     channel=>"lum",
	     setting=>"adjustingLuminance",
	     current=>$current,
	     next=>$next,
	     delta=>$next-$current,
	     damped=>$damped ? 1 : 0,
	     neutral_luminance=>1,
	     hdr20_body_luminance=>1,
	     luminance_error_pct=>$lum_pct+0
		    }];
		   }
		  }
		 }
		 trace_109($step,"hdr20_body_luminance_no_adjustment",{
		  ire=>$ire+0,
		  index=>$idx+0,
		  luminance_error_pct=>$lum_pct+0,
		  direction=>$direction+0,
		  magnitude=>$mag+0,
		  has_luminance=>has_luminance_channel($arrays,$target) ? 1 : 0,
		  luminance_suppressed=>hdr20_body_family_suppressed($tried,"luminance",$direction) ? 1 : 0
		 });
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
	  return undef if(chroma_error_magnitude($error) < 0.035);
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
	 return ddc_seed_adjustment($arrays,$target,$tried,headroom_105_hard_seed_values(),"headroom_105_seed");
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
	 my ($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_step,$max_step,$step,$source,$state)=@_;
	 return undef if(ref($arrays) ne "HASH" || ref($target) ne "HASH");
	 $luminance_err=0 if(!defined($luminance_err));
	 return undef if(abs($luminance_err) < 0.0025);
	 # The LG 1D LUT upload treats RGB white-balance arrays as chroma-only:
	 # their mean is subtracted before upload. Headroom Y must therefore use
	 # the per-point luminance channel when the TV exposes it.
	 if(has_luminance_channel($arrays,$target)) {
	  my $luma=neutral_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_step,$max_step,0,$step,$source||"headroom_luminance",$state);
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
	 my $planned_step=neutral_luminance_step($luminance_err,$de,$stalls,$min_step,$max_step);
	 my @magnitudes=($planned_step);
	 push @magnitudes,1 if($planned_step > 1);
	 push @magnitudes,0.5 if($planned_step > 0.5);
	 push @magnitudes,0.25 if($planned_step > 0.25 && $min_step <= 0.25);
	 push @magnitudes,0.10 if($planned_step > 0.10 && $min_step <= 0.10);
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

sub headroom_chroma_luma_adjustment {
	 my ($error,$arrays,$target,$luminance_err,$de,$stalls,$tried,$min_step,$max_step,$micro,$step)=@_;
	 return undef if(!autocal_step_is_fast_headroom($step) || autocal_step_is_peak_headroom($step));
	 return undef if(ref($error) ne "HASH" || ref($arrays) ne "HASH" || ref($target) ne "HASH");
	 return undef if(!has_luminance_channel($arrays,$target));
	 $luminance_err=0 if(!defined($luminance_err));
	 my $lum_pct=$luminance_err*100;
	 return undef if(abs($lum_pct) <= headroom_luminance_control_gate_percent($step,0.65));
	 return undef if(chroma_error_magnitude($error) < ($micro ? 0.022 : 0.030));
	 $min_step ||= ($micro ? 0.20 : 0.25);
	 $max_step ||= ($micro ? 0.5 : 1);
	 my $rgb=headroom_chroma_adjustment($error,$arrays,$target,$de,$stalls,$tried,$min_step,$max_step,$micro);
	 return undef if(ref($rgb) ne "ARRAY" || @{$rgb} != 1);
	 my $idx=$target->{"index"};
	 return undef if(!defined($idx) || ref($arrays->{"adjustingLuminance"}) ne "ARRAY");
	 my $current=$arrays->{"adjustingLuminance"}[$idx]||0;
	 my $direction=($luminance_err > 0) ? -1 : 1;
	 my $luma_mag=neutral_luminance_step($luminance_err,$de,$stalls,0.25,$micro ? 0.75 : 1.25);
	 my ($capped_luma_mag,$seed_luma_capped)=apply_headroom_105_seed_luma_refine_cap($arrays,$target,$step,$luminance_err,$luma_mag,"headroom_chroma_luma");
	 $luma_mag=$capped_luma_mag;
	 $luma_mag=0.25 if($luma_mag < 0.25);
	 my @magnitudes=($luma_mag,0.75,0.50,0.25);
	 my %seen_mag;
	 foreach my $mag (@magnitudes) {
	  next if($mag > $luma_mag+0.0001);
	  next if($seen_mag{ddc_value_key($mag)}++);
	  my $next=clamp_ddc_value($current+($direction*$mag));
	  next if(abs($next-$current) < 0.0001);
	  next if(tried_value_exists($tried,"adjustingLuminance",$next));
	  my @out=map { { %{$_} } } @{$rgb};
	  push @out,{ channel=>"lum", setting=>"adjustingLuminance", current=>$current, next=>$next, delta=>$next-$current, neutral_luminance=>1, headroom_chroma_luma=>1, headroom_105_seed_luma_refine_cap=>$seed_luma_capped ? 1 : undef, micro=>$micro ? 1 : 0 };
	  foreach my $adj (@out) {
	   $adj->{"headroom_chroma_luma"}=1 if(ref($adj) eq "HASH");
	  }
	  my $key=headroom_combo_key(\@out);
	  next if($key eq "");
	  $tried->{"__headroom_combo"}={} if(ref($tried->{"__headroom_combo"}) ne "HASH");
	  next if($tried->{"__headroom_combo"}{$key});
	  $tried->{"__headroom_combo"}{$key}={ count=>1, de=>defined($de) ? $de+0 : undef };
	  return \@out;
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
	 my ($error,$arrays,$target,$model,$tried,$de,$step,$target_delta,$stalls,$luminance_err)=@_;
	 my $headroom_105_body=headroom_105_post_seed_body_refinement($step,$arrays,$target,$tried);
	 return undef if(autocal_step_is_fast_headroom($step) && !$headroom_105_body);
	 return undef if(headroom_105_luma_blocking_active($step,$arrays,$target,$tried,$luminance_err));
	 return undef if(ref($error) ne "HASH" || ref($arrays) ne "HASH" || ref($target) ne "HASH");
	 my $response_lum_pct=defined($luminance_err) ? (($luminance_err+0)*100) : undef;
		 return undef if(!hdr20_top_white_chroma_priority_needed($step,$error,$de,$target_delta) && hdr20_top_white_luminance_priority_needed($step,$response_lum_pct,0.35));
	 my $paired_white=strict_tried_for_step($step);
		 my ($ch,$err,$max_err)=furthest_rgb_error_channel($error);
		 return undef if(!$ch);
	 my $threshold=rgb_response_close_threshold($de,$target_delta);
	 return undef if($max_err < $threshold);
	 my $seeded_cap=seeded_move_damping_cap($step,$error,$de,$target_delta,$stalls);
	 my $near_y_cleanup_cap=headroom_105_near_y_cleanup_rgb_cap($tried,$step,$arrays,$target,$luminance_err,0);
	 my $setting=channel_setting($ch);
	 my $arr=$arrays->{$setting};
	 my $idx=$target->{"index"};
	 return undef if(ref($arr) ne "ARRAY" || !defined($idx) || $idx >= @{$arr});
	 my $current=defined($arr->[$idx]) ? ($arr->[$idx]+0) : 0;
	 my $direction=($err > 0) ? -1 : 1;
	 my $entry=(ref($model) eq "HASH") ? $model->{$ch} : undef;
	 if(ref($entry) eq "HASH" && defined($entry->{"slope"}) && abs($entry->{"slope"}) >= 0.00005) {
	  my $slope=$entry->{"slope"}+0;
	  my $raw_delta=-$err/$slope;
	  my $max_jump=(defined($de) && $de > 4) ? 10 : ((defined($de) && $de > 2) ? 6 : 4);
		  if($paired_white) {
		   $max_jump=(defined($de) && $de > (($target_delta||0.5)+1.0) && $max_err > 0.018) ? 1.0 : 0.5;
		  } else {
		   $max_jump=12 if(($stalls||0) >= 2 && $max_jump < 12);
		   $max_jump=$seeded_cap if(defined($seeded_cap) && $max_jump > $seeded_cap);
		   $max_jump=$near_y_cleanup_cap if(defined($near_y_cleanup_cap) && $max_jump > $near_y_cleanup_cap);
		  }
		  my ($response_multiplier,$response_cap_reason,$response_entry);
		  if($headroom_105_body && !$paired_white) {
		   my $response_cap=defined($near_y_cleanup_cap) ? $near_y_cleanup_cap : 2.0;
		   my ($scaled_cap,$scaled_mult,$scaled_reason,$scaled_entry)=headroom_105_response_scaled_step(
		    $tried,$step,$setting,$direction,$max_jump,$response_cap,abs($err),"rgb_response_model"
		   );
		   return undef if(!defined($scaled_cap));
		   if($scaled_cap > $max_jump+0.0001) {
		    $max_jump=$scaled_cap;
		    $response_multiplier=$scaled_mult;
		    $response_cap_reason=$scaled_reason;
		    $response_entry=$scaled_entry;
		   }
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
		   next if(abs($predicted) >= abs($err)*0.92 && abs($actual_delta) > 0.21 && !defined($response_multiplier));
			   my $out=[{ channel=>$ch, setting=>$setting, current=>$current, next=>$next, delta=>$actual_delta, response_model=>1, slope=>$slope, predicted_error=>$predicted, paired_white=>$paired_white ? 1 : 0, seeded_move_damping=>defined($seeded_cap) ? $seeded_cap+0 : undef, headroom_105_near_y_cleanup=>defined($near_y_cleanup_cap) ? 1 : undef, headroom_105_body_refinement=>$headroom_105_body ? 1 : undef, remaining_error=>abs($err) }];
			   mark_headroom_105_response_scaled_adjustments($out,$setting,$response_multiplier,$response_cap_reason,$response_entry,$max_jump);
			   return append_headroom_105_luma_coupling($out,$arrays,$target,$step,$luminance_err,$tried,0,$LG_AUTOCAL_STATE);
			  }
			 }
			 my $probe_step=$paired_white ? ((defined($de) && $de > (($target_delta||0.5)+1.0) && $max_err > 0.018) ? 0.5 : 0.25) : 1;
			 $probe_step=$seeded_cap if(!$paired_white && defined($seeded_cap) && $probe_step > $seeded_cap);
			 $probe_step=$near_y_cleanup_cap if(!$paired_white && defined($near_y_cleanup_cap) && $probe_step > $near_y_cleanup_cap);
			 my ($response_multiplier,$response_cap_reason,$response_entry);
			 if($headroom_105_body && !$paired_white) {
			  my $response_cap=defined($near_y_cleanup_cap) ? $near_y_cleanup_cap : 2.0;
			  my ($scaled_probe,$scaled_mult,$scaled_reason,$scaled_entry)=headroom_105_response_scaled_step(
			   $tried,$step,$setting,$direction,$probe_step,$response_cap,abs($err),"rgb_response_probe"
			  );
			  return undef if(!defined($scaled_probe));
			  if($scaled_probe > $probe_step+0.0001) {
			   $probe_step=$scaled_probe;
			   $response_multiplier=$scaled_mult;
			   $response_cap_reason=$scaled_reason;
			   $response_entry=$scaled_entry;
			  }
			 }
			 my ($next,$damped)=next_untried_value($current,$direction*$probe_step,$tried,$setting,0.25,$paired_white);
			 return undef if(!defined($next) || abs($next-$current) < 0.0001);
			 my $out=[{ channel=>$ch, setting=>$setting, current=>$current, next=>$next, delta=>$next-$current, response_probe=>1, damped=>$damped ? 1 : 0, paired_white=>$paired_white ? 1 : 0, seeded_move_damping=>defined($seeded_cap) ? $seeded_cap+0 : undef, headroom_105_near_y_cleanup=>defined($near_y_cleanup_cap) ? 1 : undef, headroom_105_body_refinement=>$headroom_105_body ? 1 : undef, remaining_error=>abs($err) }];
			 mark_headroom_105_response_scaled_adjustments($out,$setting,$response_multiplier,$response_cap_reason,$response_entry,$probe_step);
			 return append_headroom_105_luma_coupling($out,$arrays,$target,$step,$luminance_err,$tried,0,$LG_AUTOCAL_STATE);
		}

sub full_ddc_spine_anchor_luminance_adjustment {
 my ($arrays,$target,$step,$de,$luminance_err,$stalls,$tried,$paired,$luma_aligned)=@_;
 return undef if(ref($arrays) ne "HASH" || ref($target) ne "HASH");
 return undef if(!has_luminance_channel($arrays,$target));
 return undef if(!defined($luminance_err));
 my $lum_pct=($luminance_err+0)*100;
 my $threshold=$paired ? ($luma_aligned ? 3.0 : 2.5) : 3.0;
 return undef if(abs($lum_pct) < $threshold);
 my $idx=$target->{"index"};
 return undef if(!defined($idx));
 my $arr=$arrays->{"adjustingLuminance"};
 return undef if(ref($arr) ne "ARRAY" || $idx >= @{$arr});
 my $current=defined($arr->[$idx]) ? ($arr->[$idx]+0) : 0;
 my $abs=abs($luminance_err+0);
 my $cap=0.5;
 if($abs >= 0.55 || (defined($de) && $de >= 25)) {
  $cap=8;
 } elsif($abs >= 0.35 || (defined($de) && $de >= 18)) {
  $cap=6;
 } elsif($abs >= 0.18 || (defined($de) && $de >= 10)) {
  $cap=4;
 } elsif($abs >= 0.08 || (defined($de) && $de >= 6)) {
  $cap=2;
 } elsif($abs >= 0.035 || (defined($de) && $de >= 3)) {
  $cap=1;
 }
 $cap=1 if($paired && !$luma_aligned && $cap > 1);
 my $tries=(ref($tried) eq "HASH" && ref($tried->{"adjustingLuminance"}) eq "HASH") ? scalar(keys %{$tried->{"adjustingLuminance"}}) : 0;
 if($abs >= 0.35) {
  $cap=6 if($cap > 6);
  $cap=4 if(($stalls||0) >= 2 && $cap > 4);
  $cap=2 if(($stalls||0) >= 4 && $cap > 2);
 } elsif($abs >= 0.18) {
  $cap=4 if($cap > 4);
  $cap=3 if($tries >= 3 && $cap > 3);
  $cap=2 if(($stalls||0) >= 2 && $cap > 2);
  $cap=1 if(($stalls||0) >= 4 && $cap > 1);
 } else {
  $cap=4 if($tries >= 1 && $cap > 4);
  $cap=2 if($tries >= 2 && $cap > 2);
  $cap=1 if(($tries >= 3 || ($stalls||0) >= 2) && $cap > 1);
  $cap=0.5 if(($stalls||0) >= 4 && $cap > 0.5);
 }
 my $direction=($luminance_err > 0) ? -1 : 1;
 my ($next,$damped)=next_untried_value($current,$direction*$cap,$tried,"adjustingLuminance",0.25,0);
 return undef if(!defined($next) || abs($next-$current) < 0.0001);
 return {
  channel=>"lum",
  setting=>"adjustingLuminance",
  current=>$current,
  next=>$next,
  delta=>$next-$current,
  damped=>$damped ? 1 : 0,
  neutral_luminance=>1,
  full_ddc_spine_anchor=>1,
  anchor_luma_aligned=>$luma_aligned ? 1 : 0,
  anchor_paired_luminance=>$paired ? 1 : undef,
  anchor_luminance_only=>$paired ? undef : 1,
  anchor_move_cap=>$cap+0,
  remaining_error=>abs($lum_pct)+0,
  source=>$paired ? "full_ddc_spine_anchor_paired_luminance" : "full_ddc_spine_anchor_luminance"
 };
}

sub full_ddc_spine_anchor_adjustments {
 my ($config,$error,$arrays,$target,$step,$de,$luminance_err,$stalls,$tried,$target_delta)=@_;
 return undef if(!lg_autocal_26_full_ddc_spine_enabled($config));
 return undef if(ref($error) ne "HASH" || ref($arrays) ne "HASH" || ref($target) ne "HASH" || ref($step) ne "HASH");
 return undef if(lg_autocal_26_full_ddc_spine_anchor_revisit_step($step));
 return undef if(!lg_autocal_26_full_ddc_spine_body_anchor($target));
 my $idx=$target->{"index"};
 return undef if(!defined($idx));
	 my $lum_pct=defined($luminance_err) ? (($luminance_err+0)*100) : 0;
	 if(autocal_step_is_hdr20_body($step)) {
	  my $mixed_chroma=hdr20_body_mixed_rgb_error($error,0.018);
	  if($mixed_chroma) {
	   my $balanced=hdr20_body_balanced_chroma_luma_adjustments(
	    $error,$arrays,$target,$step,$de,$target_delta,$luminance_err,$stalls,$tried,0.25,0
	   );
	   if(ref($balanced) eq "ARRAY" && @{$balanced}) {
	    foreach my $adj (@{$balanced}) {
	     next if(ref($adj) ne "HASH");
	     $adj->{"full_ddc_spine_anchor"}=1;
	     $adj->{"source"}="full_ddc_spine_anchor_balanced_chroma_luma" if(!defined($adj->{"source"}));
	    }
	    return $balanced;
	   }
	  }
	  my $vector=hdr20_body_rgb_luminance_vector_adjustments(
	   $error,$arrays,$target,$step,$de,$target_delta,$luminance_err,$stalls,$tried,0.25,0,
	   "full_ddc_spine_anchor_rgb_luma"
	  );
	  return $vector if(ref($vector) eq "ARRAY" && @{$vector});
  my $balanced=hdr20_body_balanced_chroma_luma_adjustments(
   $error,$arrays,$target,$step,$de,$target_delta,$luminance_err,$stalls,$tried,0.25,0
  );
  if(ref($balanced) eq "ARRAY" && @{$balanced}) {
   foreach my $adj (@{$balanced}) {
    next if(ref($adj) ne "HASH");
    $adj->{"full_ddc_spine_anchor"}=1;
    $adj->{"source"}="full_ddc_spine_anchor_balanced_chroma_luma" if(!defined($adj->{"source"}));
   }
   return $balanced;
  }
 }
 my @channels=sort { abs($error->{$b}||0) <=> abs($error->{$a}||0) } qw(r g b);
 my $ch=$channels[0];
 my $err=$error->{$ch}||0;
 my $abs_err=abs($err);
 $target_delta=0.5 if(!defined($target_delta) || $target_delta <= 0);
 my $below_rgb_floor=($abs_err < rgb_error_floor($de,$target_delta,0)) ? 1 : 0;
 my $second=abs($error->{$channels[1]}||0);
 my $dominant=($abs_err >= 0.030 || ($abs_err >= 0.016 && $abs_err >= ($second*1.22))) ? 1 : 0;
 my $direction=($err > 0) ? -1 : 1;
 my $luma_aligned=(($lum_pct > 0.35 && $direction < 0) || ($lum_pct < -0.35 && $direction > 0)) ? 1 : 0;
 my $luma_adj=full_ddc_spine_anchor_luminance_adjustment($arrays,$target,$step,$de,$luminance_err,$stalls,$tried,$dominant ? 1 : 0,$luma_aligned);
 return [$luma_adj] if($below_rgb_floor && ref($luma_adj) eq "HASH");
 return undef if($below_rgb_floor);
 return [$luma_adj] if(!$dominant && ref($luma_adj) eq "HASH");
 return undef if(!$dominant);
 my $setting=channel_setting($ch);
 my $arr=$arrays->{$setting};
 return undef if(ref($arr) ne "ARRAY" || $idx >= @{$arr});
 my $current=defined($arr->[$idx]) ? ($arr->[$idx]+0) : 0;
 my $cap=1;
 if(defined($de) && $de > ($target_delta+5.0)) {
  $cap=8;
 } elsif(defined($de) && $de > ($target_delta+3.0)) {
  $cap=6;
 } elsif($abs_err >= 0.060) {
  $cap=8;
 } elsif($abs_err >= 0.042) {
  $cap=6;
 } elsif($abs_err >= 0.026) {
  $cap=4;
 } elsif($abs_err >= 0.016) {
  $cap=2;
 }
 $cap=4 if(!$luma_aligned && $cap > 4);
 my $tries=(ref($tried) eq "HASH" && ref($tried->{$setting}) eq "HASH") ? scalar(keys %{$tried->{$setting}}) : 0;
 $cap=4 if($tries >= 1 && $cap > 4);
 $cap=2 if($tries >= 2 && $cap > 2);
 $cap=1 if(($tries >= 3 || ($stalls||0) >= 2) && $cap > 1);
 $cap=0.5 if(($stalls||0) >= 4 && $cap > 0.5);
 my ($next,$damped)=next_untried_value($current,$direction*$cap,$tried,$setting,0.25,0);
 return undef if(!defined($next) || abs($next-$current) < 0.0001);
 my @out=({
  channel=>$ch,
  setting=>$setting,
  current=>$current,
  next=>$next,
  delta=>$next-$current,
  damped=>$damped ? 1 : 0,
  full_ddc_spine_anchor=>1,
  anchor_dominant_chroma=>1,
  anchor_luma_aligned=>$luma_aligned ? 1 : 0,
  anchor_move_cap=>$cap+0,
  remaining_error=>$abs_err+0,
  source=>"full_ddc_spine_anchor_dominant_channel"
 });
 push @out,$luma_adj if(ref($luma_adj) eq "HASH");
 return \@out;
}

sub full_ddc_spine_anchor_luma_progress_keep {
 my ($config,$target,$step,$adjustments,$lum_pct,$best_lum_pct,$de,$best_de,$candidate_score,$best_score)=@_;
 return 0 if(!lg_autocal_26_full_ddc_spine_enabled($config));
 return 0 if(!lg_autocal_26_full_ddc_spine_body_anchor($target));
 return 0 if(ref($adjustments) ne "ARRAY" || !adjustments_have_flag($adjustments,"full_ddc_spine_anchor"));
 return 0 if(!defined($lum_pct) || !defined($best_lum_pct) || !defined($de) || !defined($best_de));
 my $candidate_abs=abs($lum_pct+0);
 my $best_abs=abs($best_lum_pct+0);
 my $tol=luminance_tolerance_percent($step);
 $tol=1.0 if(!defined($tol) || $tol <= 0);
 my $near_target=($candidate_abs <= $tol && $best_abs > $tol) ? 1 : 0;
 my $large_y_gain=($candidate_abs + 2.0 < $best_abs) ? 1 : 0;
 return 0 if(!$near_target && !$large_y_gain);
 my $de_allowance=$near_target ? 1.25 : (($best_abs >= 10.0) ? 2.00 : 0.75);
 my $score_allowance=$near_target ? 1.25 : (($best_abs >= 10.0) ? 1.50 : 0.75);
 return 0 if(($de+0) > ($best_de+0)+$de_allowance);
 return 0 if(defined($candidate_score) && defined($best_score) && ($candidate_score+0) > ($best_score+0)+$score_allowance);
 return 1;
}

sub choose_adjustments {
					 my ($error,$arrays,$target,$de,$min_step,$stalls,$luminance_err,$tried,$step)=@_;
				 return undef if(ref($error) ne "HASH" || ref($target) ne "HASH");
			 $min_step ||= 0.25;
				 $luminance_err=0 if(!defined($luminance_err));
				 my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : 100;
				 my $strict_tried=strict_tried_for_step($step);
				 $luminance_err=0 if(autocal_step_suppresses_luminance_adjustment($step));
				 my $headroom_105_body=headroom_105_post_seed_body_refinement($step,$arrays,$target,$tried);
						 if(autocal_step_is_hdr20_body($step)) {
						  my $lum_pct=$luminance_err*100;
						  my $hdr_body_balanced=hdr20_body_balanced_chroma_luma_adjustments($error,$arrays,$target,$step,$de,0.5,$luminance_err,$stalls,$tried,$min_step,0);
						  return $hdr_body_balanced if($hdr_body_balanced);
						  my $hdr_body_vector=hdr20_body_rgb_luminance_vector_adjustments($error,$arrays,$target,$step,$de,0.5,$luminance_err,$stalls,$tried,$min_step,0,"choose_adjustments");
						  return $hdr_body_vector if($hdr_body_vector);
						  if(abs($lum_pct) >= 8) {
						   my $hdr_body_luma_first=hdr20_body_luminance_rgb_adjustments($arrays,$target,$step,$luminance_err,$de,$stalls,$tried,$min_step);
						   return $hdr_body_luma_first if($hdr_body_luma_first);
					  }
					  my $hdr_body=hdr20_body_chroma_luma_adjustments($error,$arrays,$target,$step,$de,0.5,$luminance_err,$stalls,$tried,$min_step,0);
					  return $hdr_body if($hdr_body);
					  $hdr_body_vector=hdr20_body_rgb_luminance_vector_adjustments($error,$arrays,$target,$step,$de,0.5,$luminance_err,$stalls,$tried,$min_step,0,"choose_adjustments_fallback");
					  return $hdr_body_vector if($hdr_body_vector);
					  my $hdr_body_luma=hdr20_body_luminance_rgb_adjustments($arrays,$target,$step,$luminance_err,$de,$stalls,$tried,$min_step);
					  return $hdr_body_luma if($hdr_body_luma);
					  return undef;
					 }
				 if(autocal_step_is_fast_headroom($step) && !$headroom_105_body) {
				  my $lum_pct=$luminance_err*100;
				  my $luma_tol=headroom_luminance_control_gate_percent($step,1);
				  my $chroma_mag=chroma_error_magnitude($error);
				  my $dominant_chroma_first=(!autocal_step_is_peak_headroom($step) && $chroma_mag >= 0.035 && defined($de) && $de > 2.0) ? 1 : 0;
				  if($dominant_chroma_first) {
				   my $headroom_seed=headroom_105_wrgb_seed_adjustment($error,$arrays,$target,$de,$tried,$step,$luminance_err);
				   return $headroom_seed if($headroom_seed);
				   my $combo=headroom_chroma_luma_adjustment($error,$arrays,$target,$luminance_err,$de,$stalls,$tried,$min_step,1,0,$step);
				   return $combo if($combo);
				   if($lum_pct > $luma_tol) {
				    my $reduce=headroom_reduce_only_chroma_adjustment($error,$arrays,$target,$de,$stalls,$tried,$min_step,4,0);
				    return $reduce if($reduce);
				   }
				   my $chroma=headroom_chroma_adjustment($error,$arrays,$target,$de,$stalls,$tried,$min_step,2,0);
				   return $chroma if($chroma);
				  }
					  if(!autocal_step_is_peak_headroom($step) && has_luminance_channel($arrays,$target) && abs($lum_pct) > $luma_tol) {
					   my $max_luma_step=abs($luminance_err) >= 0.035 ? 4 : (abs($luminance_err) >= 0.015 ? 2 : 1);
					   my $rgb_luma=headroom_rgb_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_step,$max_luma_step,$step,"main_headroom_luminance");
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
			   my $rgb_luma=headroom_rgb_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_step,$max_luma_step,$step,"main_headroom_luminance");
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
			   my $rgb_luma=headroom_rgb_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_step,$max_luma_step,$step,"main_headroom_luminance");
			   return $rgb_luma if($rgb_luma);
			  }
			  my $fine_chroma=headroom_chroma_adjustment($error,$arrays,$target,$de,$stalls,$tried,$min_step,2,0);
			  return $fine_chroma if($fine_chroma);
			  return undef;
			 }
			 if($headroom_105_body) {
			  trace_109($step,"headroom_105_body_refinement_path",{
			   planner=>"main",
			   delta_e=>defined($de)?$de+0:undef,
			   luminance_error_pct=>($luminance_err*100)+0,
			   rgb_error=>$error,
			   target_values=>trace_target_values($arrays,$target)
			  });
			 }
				 my $lum_pct=$luminance_err*100;
				 my $luma_tol=luminance_tolerance_percent($step);
					 my $hdr20_top_white=autocal_step_is_hdr20_top_white($step);
				 my $headroom_105_luma_blocking=headroom_105_luma_blocking_active($step,$arrays,$target,$tried,$luminance_err);
				 my $headroom_105_luma_priority=headroom_105_luma_priority_active($step,$arrays,$target,$tried,$luminance_err);
			 if($headroom_105_luma_priority) {
			  my $luma_priority=headroom_105_luma_priority_adjustment($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_step,1,0,$step);
			  return $luma_priority if($luma_priority);
			 }
			 my $all_down_luma=headroom_105_all_down_luma_adjustment($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_step,2,0,$step);
			 return $all_down_luma if($all_down_luma);
			 my $floor_luma_coupled=headroom_105_floor_luma_coupled_adjustment($error,$arrays,$target,$luminance_err,$de,$stalls,$tried,$min_step,1,0,$step);
			 return $floor_luma_coupled if($floor_luma_coupled);
			 return undef if($headroom_105_luma_blocking);
			 my $near_white_95_luma=near_white_95_luma_adjustments($arrays,$target,$step,$lum_pct,$de,0.5,$tried,$stalls,"near_white_95_luma",$LG_AUTOCAL_STATE,0);
			 return $near_white_95_luma if($near_white_95_luma);
			 if(autocal_step_is_low_shadow($step)) {
			  my $shadow_luma=low_shadow_luminance_priority_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,$step,0);
			  return $shadow_luma if($shadow_luma);
			  my $shadow_chroma_luma=low_shadow_chroma_luminance_coupled_adjustments($error,$arrays,$target,$luminance_err,$de,0.5,$tried,$step,0);
			  return $shadow_chroma_luma if($shadow_chroma_luma);
			 }
				 if($strict_tried) {
				  my $pair_seed=legal_white_pair_wrgb_seed_adjustment($arrays,$target,$de,$tried,$step);
				  return $pair_seed if($pair_seed);
				 }
				 if($ire <= 10.0001 && has_luminance_channel($arrays,$target) && abs($lum_pct) > ($luma_tol*1.05)) {
				  my $max_luma_step=abs($luminance_err) >= 0.20 ? 4 : (abs($luminance_err) >= 0.08 ? 2 : 1);
				  my $neutral=neutral_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,0.25,$max_luma_step,$strict_tried,$step,"main_luminance");
				  return $neutral if($neutral);
				 }
				 if($ire > 10.0001 && $ire <= 35.0001 && has_luminance_channel($arrays,$target) && abs($lum_pct) > ($luma_tol*0.75)) {
				  my $neutral=neutral_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,0.25,1,$strict_tried,$step,"main_luminance");
				  return $neutral if($neutral);
				 }
				 if($ire > 35.0001 && $ire <= 50.0001 && has_luminance_channel($arrays,$target) && abs($lum_pct) > ($luma_tol*0.80)) {
				  my $neutral=neutral_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,0.25,1,$strict_tried,$step,"main_luminance");
				  return $neutral if($neutral);
				 }
				 if($ire < 90 && has_luminance_channel($arrays,$target) && abs($lum_pct) > (($luma_tol*3) > 8 ? ($luma_tol*3) : 8)) {
				  my $max_luma_step=abs($luminance_err) >= 0.20 ? 6 : 4;
				  my $neutral=neutral_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_step,$max_luma_step,$strict_tried,$step,"main_luminance");
				  return $neutral if($neutral);
				 }
					 if($hdr20_top_white && hdr20_top_white_chroma_priority_needed($step,$error,$de,0.5)) {
					  my $chroma=headroom_chroma_adjustment($error,$arrays,$target,$de,$stalls,$tried,$min_step,8,0);
					  return $chroma if($chroma);
					 }
					 if($hdr20_top_white && has_luminance_channel($arrays,$target) && abs($lum_pct) > ($luma_tol*0.35) && !hdr20_top_white_chroma_priority_needed($step,$error,$de,0.5)) {
					  my $max_luma_step=abs($luminance_err) >= 0.05 ? 3 : (abs($luminance_err) >= 0.02 ? 2 : 1);
					  my $neutral=neutral_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_step,$max_luma_step,$strict_tried,$step,"main_hdr100_luminance");
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
			 my $seeded_cap=seeded_move_damping_cap($step,$error,$de,0.5,$stalls);
			 my $near_y_cleanup_cap=headroom_105_near_y_cleanup_rgb_cap($tried,$step,$arrays,$target,$luminance_err,0);
			 $seeded_cap=$near_y_cleanup_cap if(defined($near_y_cleanup_cap) && (!defined($seeded_cap) || $seeded_cap > $near_y_cleanup_cap));
				 if(has_luminance_channel($arrays,$target) && abs($lum_pct) > ($luma_tol*0.35)) {
				  my $max_luma_step=abs($luminance_err) >= 0.20 ? 6 : 3;
				  my $neutral=neutral_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_step,$max_luma_step,$strict_tried,$step,"main_luminance");
				  if($neutral) {
				   my $luma_takeover=($chroma_mag < 0.012 || ($near_fine && $chroma_mag < 0.020) || (defined($de) && $de <= 3.0 && $chroma_mag < 0.035 && abs($lum_pct) > ($luma_tol*1.10))) ? 1 : 0;
			   return ($headroom_105_body ? mark_headroom_105_body_refinement_adjustments($neutral) : $neutral) if($luma_takeover);
			   push @out,@{$neutral} if($chroma_mag < 0.025 && abs($lum_pct) > ($luma_tol*0.75));
			  }
			 }
			 if(abs($lum_pct) > ($luma_tol*0.55) && chroma_error_magnitude($error) < 0.020) {
			  my $neutral=neutral_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_step,2,$strict_tried,$step,"main_luminance");
			  return ($headroom_105_body ? mark_headroom_105_body_refinement_adjustments($neutral) : $neutral) if($neutral);
			 }
		 foreach my $ch (@channels) {
	  my $err=$combined{$ch}||0;
		  next if(abs($err) < rgb_error_floor($de,0.5,0));
  my $setting=channel_setting($ch);
  my $arr=$arrays->{$setting};
	  next if(ref($arr) ne "ARRAY");
	  my $idx=$target->{"index"};
		  my $current=$arr->[$idx]||0;
						  my $rgb_step=adjustment_step(abs($err),$de,$stalls,$min_step);
						  $rgb_step=$seeded_cap if(defined($seeded_cap) && $rgb_step > $seeded_cap);
						  my $direction=($err > 0) ? -1 : 1;
						  my ($response_multiplier,$response_cap_reason,$response_entry);
						  if($headroom_105_body && !$strict_tried) {
						   my $response_cap=defined($near_y_cleanup_cap) ? $near_y_cleanup_cap : 2.0;
						   my ($scaled_step,$scaled_mult,$scaled_reason,$scaled_entry)=headroom_105_response_scaled_step(
						    $tried,$step,$setting,$direction,$rgb_step,$response_cap,abs($err),"main_rgb"
						   );
						   next if(!defined($scaled_step));
						   if($scaled_step > $rgb_step+0.0001) {
						    $rgb_step=$scaled_step;
						    $response_multiplier=$scaled_mult;
						    $response_cap_reason=$scaled_reason;
						    $response_entry=$scaled_entry;
						   }
						  }
					  my $delta = $direction*$rgb_step;
					  foreach my $try_delta ($delta,-$delta) {
					   my ($next,$damped)=next_untried_value($current,$try_delta,$tried,$setting,$min_step,$strict_tried);
					   next if(!defined($next));
					   next if(abs($next-$current) < 0.0001);
				   my $adj={ channel=>$ch, setting=>$setting, current=>$current, next=>$next, delta=>$next-$current, damped=>$damped ? 1 : 0, seeded_move_damping=>defined($seeded_cap) ? $seeded_cap+0 : undef, headroom_105_near_y_cleanup=>defined($near_y_cleanup_cap) ? 1 : undef, remaining_error=>abs($err) };
				   my $single=[$adj];
				   mark_headroom_105_response_scaled_adjustments($single,$setting,$response_multiplier,$response_cap_reason,$response_entry,$rgb_step);
				   push @out,$adj;
				   last;
				  }
		  last if(@out && $near_fine && !$luma_priority);
		 }
		 if(@out && $headroom_105_body) {
		  my $coupled=append_headroom_105_luma_coupling(\@out,$arrays,$target,$step,$luminance_err,$tried,0,$LG_AUTOCAL_STATE);
		  return $coupled;
		 }
		 return @out ? \@out : undef;
}

sub choose_micro_adjustments {
					 my ($error,$arrays,$target,$luminance_err,$tried,$max_step,$de,$stalls,$step,$target_delta)=@_;
					 return undef if(ref($error) ne "HASH" || ref($arrays) ne "HASH" || ref($target) ne "HASH");
					 $luminance_err=0 if(!defined($luminance_err));
						 my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : 100;
						 my $strict_tried=strict_tried_for_step($step);
						 $luminance_err=0 if(autocal_step_suppresses_luminance_adjustment($step));
				 my $headroom_105_body=headroom_105_post_seed_body_refinement($step,$arrays,$target,$tried);
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
			 my $hdr20_top_white=autocal_step_is_hdr20_top_white($step);
				 if(autocal_step_is_hdr20_body($step) && abs($lum_pct) > ($luma_tol*1.20)) {
				  my $hdr_body_balanced=hdr20_body_balanced_chroma_luma_adjustments($error,$arrays,$target,$step,$de,$target_delta,$luminance_err,$stalls,$tried,$min_micro_step,1);
				  return $hdr_body_balanced if($hdr_body_balanced);
				  my $hdr_body_luma=hdr20_body_luminance_rgb_adjustments($arrays,$target,$step,$luminance_err,$de,$stalls,$tried,$min_micro_step);
				  return $hdr_body_luma if($hdr_body_luma);
				 }
				 if(autocal_step_is_hdr20_body($step)) {
				  my $hdr_body_balanced=hdr20_body_balanced_chroma_luma_adjustments($error,$arrays,$target,$step,$de,$target_delta,$luminance_err,$stalls,$tried,$min_micro_step,1);
				  return $hdr_body_balanced if($hdr_body_balanced);
				 }
			 if(autocal_step_is_low_shadow($step)) {
			  my $shadow_luma=low_shadow_luminance_priority_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,$step,1);
			  return $shadow_luma if($shadow_luma);
			  my $shadow_chroma_luma=low_shadow_chroma_luminance_coupled_adjustments($error,$arrays,$target,$luminance_err,$de,$target_delta,$tried,$step,1);
			  return $shadow_chroma_luma if($shadow_chroma_luma);
			 }
				 if($ire <= 10.0001 && has_luminance_channel($arrays,$target) && abs($lum_pct) > ($luma_tol*0.85)) {
				  my $luma_max_step=abs($luminance_err) >= 0.20 ? 4 : (abs($luminance_err) >= 0.08 ? 2 : $max_step);
				  my $neutral=neutral_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,0.25,$luma_max_step,$strict_tried,$step,"fine_luminance");
				  return $neutral if($neutral);
				 }
				 if($ire > 10.0001 && $ire <= 35.0001 && has_luminance_channel($arrays,$target) && abs($lum_pct) > ($luma_tol*0.60)) {
				  my $neutral=neutral_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,0.25,$max_step,$strict_tried,$step,"fine_luminance");
				  return $neutral if($neutral);
				 }
				 if($ire > 35.0001 && $ire <= 50.0001 && has_luminance_channel($arrays,$target) && abs($lum_pct) > ($luma_tol*0.70)) {
				  my $neutral=neutral_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,0.25,$max_step,$strict_tried,$step,"fine_luminance");
				  return $neutral if($neutral);
				 }
				 if(autocal_step_is_fast_headroom($step) && !$headroom_105_body) {
				  my $chroma_mag=chroma_error_magnitude($error);
				  my $luma_gate=headroom_luminance_control_gate_percent($step,0.45);
				  if(autocal_step_is_peak_headroom($step)) {
				   my $wrgb_seed=headroom_peak_wrgb_seed_adjustment($error,$arrays,$target,$de,$tried);
				   return $wrgb_seed if($wrgb_seed);
				   my $match_low=headroom_peak_match_low_adjustment($error,$arrays,$target,$de,$stalls,$tried,$min_micro_step,$max_step,1,$step);
				   return $match_low if($match_low);
				   return undef;
				  }
				  my $dominant_chroma_first=(!autocal_step_is_peak_headroom($step) && $chroma_mag >= 0.030 && defined($de) && $de > ($target_delta+0.75)) ? 1 : 0;
				  if($dominant_chroma_first) {
				   my $headroom_seed=headroom_105_wrgb_seed_adjustment($error,$arrays,$target,$de,$tried,$step,$luminance_err);
				   return $headroom_seed if($headroom_seed);
				   my $combo=headroom_chroma_luma_adjustment($error,$arrays,$target,$luminance_err,$de,$stalls,$tried,$min_micro_step,$max_step,1,$step);
				   return $combo if($combo);
				   if($lum_pct > $luma_gate) {
				    my $reduce=headroom_reduce_only_chroma_adjustment($error,$arrays,$target,$de,$stalls,$tried,$min_micro_step,$max_step,1);
				    return $reduce if($reduce);
				   }
				   my $chroma=headroom_chroma_adjustment($error,$arrays,$target,$de,$stalls,$tried,$min_micro_step,$max_step,1);
				   return $chroma if($chroma);
				  }
					  if(has_luminance_channel($arrays,$target) && abs($lum_pct) > $luma_gate) {
					   my $luma_max_step=abs($luminance_err) >= 0.035 ? 2 : (abs($luminance_err) >= 0.015 ? 1 : $max_step);
					   my $rgb_luma=headroom_rgb_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_micro_step,$luma_max_step,$step,"fine_headroom_luminance");
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
			   my $rgb_luma=headroom_rgb_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_micro_step,$luma_max_step,$step,"fine_headroom_luminance");
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
			   my $rgb_luma=headroom_rgb_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_micro_step,$luma_max_step,$step,"fine_headroom_luminance");
			   return $rgb_luma if($rgb_luma);
			  }
			  my $fine_chroma=headroom_chroma_adjustment($error,$arrays,$target,$de,$stalls,$tried,$min_micro_step,$max_step,1);
			  return $fine_chroma if($fine_chroma);
			  if(!autocal_step_is_peak_headroom($step) && abs($lum_pct) > headroom_luminance_control_gate_percent($step,0.20)) {
			   my $rgb_luma=headroom_rgb_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_micro_step,$max_step,$step,"fine_headroom_luminance");
			   return $rgb_luma if($rgb_luma);
			  }
			  return undef;
			 }
			 if($headroom_105_body) {
			  trace_109($step,"headroom_105_body_refinement_path",{
			   planner=>"fine",
			   delta_e=>defined($de)?$de+0:undef,
			   luminance_error_pct=>($luminance_err*100)+0,
			   rgb_error=>$error,
			   target_values=>trace_target_values($arrays,$target)
			  });
			 }
				 my $all_down_luma=headroom_105_all_down_luma_adjustment($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_micro_step,$max_step < 0.5 ? $max_step : 0.5,1,$step);
				 my $headroom_105_luma_blocking=headroom_105_luma_blocking_active($step,$arrays,$target,$tried,$luminance_err);
				 my $headroom_105_luma_priority=headroom_105_luma_priority_active($step,$arrays,$target,$tried,$luminance_err);
				 if($headroom_105_luma_priority) {
				  my $luma_priority=headroom_105_luma_priority_adjustment($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_micro_step,1,1,$step);
				  return $luma_priority if($luma_priority);
				 }
				 $all_down_luma=headroom_105_all_down_luma_adjustment($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_micro_step,$max_step < 0.5 ? $max_step : 0.5,1,$step);
				 return $all_down_luma if($all_down_luma);
				 my $floor_luma_coupled=headroom_105_floor_luma_coupled_adjustment($error,$arrays,$target,$luminance_err,$de,$stalls,$tried,$min_micro_step,$max_step < 0.5 ? $max_step : 0.5,1,$step);
				 return $floor_luma_coupled if($floor_luma_coupled);
				 return undef if($headroom_105_luma_blocking);
				 my $near_white_95_luma=near_white_95_luma_adjustments($arrays,$target,$step,$lum_pct,$de,$target_delta,$tried,$stalls,"near_white_95_luma_verify",$LG_AUTOCAL_STATE,1);
				 return $near_white_95_luma if($near_white_95_luma);
				 if($paired_white) {
				  my $pair_seed=legal_white_pair_wrgb_seed_adjustment($arrays,$target,$de,$tried,$step);
				  return $pair_seed if($pair_seed);
				 }
					 if($hdr20_top_white && hdr20_top_white_chroma_priority_needed($step,$error,$de,$target_delta)) {
					  my $chroma=headroom_chroma_adjustment($error,$arrays,$target,$de,$stalls,$tried,$min_micro_step,$max_step > 1 ? 1 : $max_step,1);
					  return $chroma if($chroma);
					 }
						 if(has_luminance_channel($arrays,$target) && abs($lum_pct) > ($luma_tol*0.35) && !hdr20_top_white_chroma_priority_needed($step,$error,$de,$target_delta)) {
						  my $luma_max_step=$max_step;
						  $luma_max_step=4 if(abs($luminance_err) >= 0.20 && $luma_max_step < 4);
						  $luma_max_step=2 if(abs($luminance_err) >= 0.08 && $luma_max_step < 2);
						  my $neutral=neutral_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,0.25,$luma_max_step,$strict_tried,$step,"fine_luminance");
						  return ($headroom_105_body ? mark_headroom_105_body_refinement_adjustments($neutral) : $neutral) if($neutral && ((defined($de) && $de <= 3.0) || chroma_error_magnitude($error) < 0.015));
						 }
					 if($hdr20_top_white && has_luminance_channel($arrays,$target) && abs($lum_pct) > ($luma_tol*0.30) && !hdr20_top_white_chroma_priority_needed($step,$error,$de,$target_delta)) {
					  my $luma_max_step=$max_step;
					  $luma_max_step=2 if(abs($luminance_err) >= 0.05 && $luma_max_step < 2);
					  $luma_max_step=1 if(abs($luminance_err) >= 0.02 && $luma_max_step < 1);
				  my $neutral=neutral_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,0.20,$luma_max_step,$strict_tried,$step,"fine_hdr100_luminance");
				  return ($headroom_105_body ? mark_headroom_105_body_refinement_adjustments($neutral) : $neutral) if($neutral);
				 }
				 if(abs($lum_pct) > ($luma_tol*0.45) && chroma_error_magnitude($error) < 0.016) {
				  my $neutral=neutral_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,0.25,$max_step,$strict_tried,$step,"fine_luminance");
				  return ($headroom_105_body ? mark_headroom_105_body_refinement_adjustments($neutral) : $neutral) if($neutral);
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
				    my $effective_mag=$mag;
				    my ($response_multiplier,$response_cap_reason,$response_entry);
				    if($headroom_105_body && !$strict_tried) {
				     my $near_y_cleanup_cap=headroom_105_near_y_cleanup_rgb_cap($tried,$step,$arrays,$target,$luminance_err,1);
				     my $response_cap=defined($near_y_cleanup_cap) ? $near_y_cleanup_cap : 1.0;
				     my ($scaled_mag,$scaled_mult,$scaled_reason,$scaled_entry)=headroom_105_response_scaled_step(
				      $tried,$step,$setting,$dir,$effective_mag,$response_cap,abs($err),"fine_rgb"
				     );
				     next if(!defined($scaled_mag));
				     if($scaled_mag > $effective_mag+0.0001) {
				      $effective_mag=$scaled_mag;
				      $response_multiplier=$scaled_mult;
				      $response_cap_reason=$scaled_reason;
				      $response_entry=$scaled_entry;
				     }
				    }
				    my ($next,$damped)=next_untried_value($current,$dir*$effective_mag,$tried,$setting,$min_micro_step,$strict_tried);
				    next if(!defined($next));
			    next if(abs($next-$current) < 0.0001);
			    my $out=[{ channel=>$ch, setting=>$setting, current=>$current, next=>$next, delta=>$next-$current, damped=>$damped ? 1 : 0, micro=>1, remaining_error=>abs($err) }];
			    mark_headroom_105_response_scaled_adjustments($out,$setting,$response_multiplier,$response_cap_reason,$response_entry,$effective_mag);
			    return $headroom_105_body ? append_headroom_105_luma_coupling($out,$arrays,$target,$step,$luminance_err,$tried,1,$LG_AUTOCAL_STATE) : $out;
			   }
				  }
			 }
			 my @sweep_channels=qw(r g b);
			 push @sweep_channels,"lum" if(has_luminance_channel($arrays,$target) && ($ire < 99.9 || autocal_step_is_fast_headroom($step) || $hdr20_top_white));
			 foreach my $mag (@magnitudes) {
			  foreach my $ch (@sweep_channels) {
			   my $setting=channel_setting($ch);
			   my $arr=$arrays->{$setting};
			   next if(ref($arr) ne "ARRAY");
			   my $idx=$target->{"index"};
			   next if(!defined($idx) || $idx >= @{$arr});
					   my $current=$arr->[$idx]||0;
					   foreach my $dir (1,-1) {
					    my $effective_mag=$mag;
					    my ($response_multiplier,$response_cap_reason,$response_entry);
					    if($headroom_105_body && !$strict_tried) {
					     my $near_y_cleanup_cap=headroom_105_near_y_cleanup_rgb_cap($tried,$step,$arrays,$target,$luminance_err,1);
					     my $response_cap=defined($near_y_cleanup_cap) ? $near_y_cleanup_cap : ($ch eq "lum" ? 1.0 : 1.0);
					     my ($scaled_mag,$scaled_mult,$scaled_reason,$scaled_entry)=headroom_105_response_scaled_step(
					      $tried,$step,$setting,$dir,$effective_mag,$response_cap,undef,"fine_sweep"
					     );
					     next if(!defined($scaled_mag));
					     if($scaled_mag > $effective_mag+0.0001) {
					      $effective_mag=$scaled_mag;
					      $response_multiplier=$scaled_mult;
					      $response_cap_reason=$scaled_reason;
					      $response_entry=$scaled_entry;
					     }
					    }
					    my ($next,$damped)=next_untried_value($current,$dir*$effective_mag,$tried,$setting,$min_micro_step,$strict_tried);
					    next if(!defined($next));
				    next if(abs($next-$current) < 0.0001);
				    next if($ch eq "lum" && luma_probe_family_suppressed($tried,$target,$current,$next,$step,"fine_sweep_luminance"));
				    my $out=[{ channel=>$ch, setting=>$setting, current=>$current, next=>$next, delta=>$next-$current, damped=>$damped ? 1 : 0, micro=>1, sweep=>1 }];
				    mark_headroom_105_response_scaled_adjustments($out,$setting,$response_multiplier,$response_cap_reason,$response_entry,$effective_mag);
				    return $headroom_105_body ? append_headroom_105_luma_coupling($out,$arrays,$target,$step,$luminance_err,$tried,1,$LG_AUTOCAL_STATE) : $out;
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
		  ddc_layout => $LG_AUTOCAL_DDC_LAYOUT,
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
	   $state->{"ddc_picture_write_count"}=($state->{"ddc_picture_write_count"}||0)+1;
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
	  if(ref($state) eq "HASH" && !($state->{"ddc_picture_write_count"}||0)) {
	   $state->{"final_1d_lut_uploaded"}=JSON::PP::false;
	   $state->{"final_1d_lut_upload_verified"}=JSON::PP::true;
	   $state->{"final_1d_lut_skipped"}=JSON::PP::true;
	   $state->{"message"}="No LG DDC adjustments were needed; final 1D LUT upload skipped";
	   write_state($state);
	   return ($picture,undef,0);
	  }
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

sub post_3d_committed_polish_requested {
 my ($config)=@_;
 return 0 if(ref($config) ne "HASH" || !$config->{"lg_autocal_26"});
 return 0 if(!autocal_config_is_post_3d_polish($config));
 return (exists($config->{"post_commit_polish"}) && $config->{"post_commit_polish"}) ? 1 : 0;
}

sub post_commit_verify_enabled {
 my ($config)=@_;
 return 0 if(ref($config) ne "HASH" || !$config->{"lg_autocal_26"});
 return 0 if(exists($config->{"post_commit_verify"}) && !$config->{"post_commit_verify"});
 return 1 if(exists($config->{"post_commit_verify"}) && $config->{"post_commit_verify"});
 foreach my $key (qw(post_commit_body_verify post_commit_final_all_level_verify post_commit_final_top_window)) {
  return 1 if(exists($config->{$key}) && $config->{$key});
 }
 return 0;
}

sub committed_top_window_score {
		 my ($window)=@_;
	 return { score=>9999, worst=>9999, avg=>9999, over=>9999 } if(ref($window) ne "HASH" || ref($window->{"points"}) ne "HASH");
 my @ires=grep { ref($window->{"points"}{$_}) eq "HASH" && defined($window->{"points"}{$_}{"de"}) } (109,105,99,100,95);
 return { score=>9999, worst=>9999, avg=>9999, over=>9999 } if(!@ires);
 my $sum=0;
 my $count=0;
 my $worst=0;
 my $over=0;
	 foreach my $ire (@ires) {
	  my $rec=$window->{"points"}{$ire};
	  my $point_score=committed_top_window_point_score($ire,$rec);
	  $sum+=$point_score;
	  $count++;
	  $worst=$point_score if($point_score > $worst);
	  $over++ if($point_score > 1.0);
	 }
 my $avg=$count ? ($sum/$count) : 9999;
 return {
  score => ($over*10)+$worst+($avg*0.25),
  worst => $worst,
  avg => $avg,
  over => $over,
	 };
}

sub committed_top_window_point_score {
 my ($ire,$point)=@_;
 return 9999 if(ref($point) ne "HASH" || !defined($point->{"de"}));
 my $score=$point->{"de"}+0;
 return $score if(abs(($ire||0)-105) >= 0.001);
 return $score if(!defined($point->{"luminance_error_pct"}));
 my $excess=abs($point->{"luminance_error_pct"}+0)-luminance_tolerance_percent({ ire=>105 });
 return $score if($excess <= 0);
 my $penalty=$excess*0.35;
 $penalty=4 if($penalty > 4);
 return $score+$penalty;
}

sub committed_top_window_score_passed {
 my ($score)=@_;
 return 0 if(ref($score) ne "HASH");
 return (($score->{"over"}||0) == 0 && ($score->{"worst"}||9999) <= 1.0) ? 1 : 0;
}

sub committed_top_window_good_105_point {
 my ($window,$target_delta)=@_;
 return undef if(ref($window) ne "HASH" || ref($window->{"points"}) ne "HASH");
 my $point=$window->{"points"}{105};
 return undef if(ref($point) ne "HASH" || !defined($point->{"de"}));
 return undef if(($point->{"de"}+0) > lg_autocal_26_good_105_best_known_limit($target_delta)+0.0001);
 return $point;
}

sub committed_top_window_105_best_blocks_final {
 my ($best_window,$final_window,$target_delta)=@_;
 my $best=committed_top_window_good_105_point($best_window,$target_delta);
 return 0 if(ref($best) ne "HASH");
 return 0 if(ref($final_window) ne "HASH" || ref($final_window->{"points"}) ne "HASH");
 my $final=$final_window->{"points"}{105};
 return 0 if(ref($final) ne "HASH" || !defined($final->{"de"}));
 return (($final->{"de"}+0) > ($best->{"de"}+0)+0.03) ? 1 : 0;
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

sub committed_top_window_luma_candidate_change {
 my ($candidate)=@_;
 return undef if(ref($candidate) ne "HASH" || ref($candidate->{"changes"}) ne "ARRAY");
 return undef if(@{$candidate->{"changes"}} != 1);
 my $change=$candidate->{"changes"}[0];
 return undef if(ref($change) ne "HASH" || ($change->{"setting"}||"") ne "adjustingLuminance");
 return $change;
}

sub committed_top_window_luma_family_key {
 my ($candidate,$arrays)=@_;
 my $change=committed_top_window_luma_candidate_change($candidate);
 return undef if(ref($change) ne "HASH");
 my $ire;
 $ire=$1+0 if(($candidate->{"label"}||"") =~ /^top_([0-9.]+)_/);
 my $idx=$change->{"index"};
 my $delta=$change->{"delta"};
 return undef if(!defined($ire) || !defined($idx) || !defined($delta) || abs($delta+0) < 0.0001);
	 my $arr=(ref($arrays) eq "HASH") ? $arrays->{"adjustingLuminance"} : undef;
	 my $current=(ref($arr) eq "ARRAY" && defined($arr->[$idx])) ? ($arr->[$idx]+0) : 0;
	 my $direction=($delta+0) < 0 ? -1 : 1;
	 my $magnitude=ddc_value_key(abs($delta+0));
	 return join("|",format_percent($ire),ddc_value_key($current),$direction,$magnitude);
}

sub committed_top_window_luma_suppressed {
 my ($bad_luma,$candidate,$arrays)=@_;
 return 0 if(ref($bad_luma) ne "HASH");
 my $key=committed_top_window_luma_family_key($candidate,$arrays);
 return 0 if(!defined($key));
 my $entry=$bad_luma->{$key};
 return 0 if(ref($entry) ne "HASH");
 return 1 if(($entry->{"severe_count"}||0) >= 1);
 return 1 if(($entry->{"count"}||0) >= 2);
 return 0;
}

sub committed_top_window_point_chroma_magnitude {
 my ($point)=@_;
 return 999 if(ref($point) ne "HASH" || ref($point->{"reading"}) ne "HASH");
 return chroma_error_magnitude(rgb_error($point->{"reading"}));
}

sub committed_top_window_luma_allowed {
 my ($window,$ire,$candidate,$arrays,$bad_luma)=@_;
 return 0 if(committed_top_window_luma_suppressed($bad_luma,$candidate,$arrays));
 return 1 if(ref($window) ne "HASH" || ref($window->{"points"}) ne "HASH");
 my $point=$window->{"points"}{$ire};
 return 1 if(ref($point) ne "HASH");
 my $chroma=committed_top_window_point_chroma_magnitude($point);
 my $de=defined($point->{"de"}) ? ($point->{"de"}+0) : 0;
 my $lum_abs=defined($point->{"luminance_error_pct"}) ? abs($point->{"luminance_error_pct"}+0) : 0;
 # 105% is a chroma/RGB headroom point; do not spend the top-window budget on
 # luma-only probes while its RGB error is still the dominant failure.
 return 0 if(abs(($ire||0)-105) < 0.001 && $de > 2.0 && $chroma >= 0.030);
 # The legal-white side should also avoid luma-only hammering when chroma is
 # clearly bad and Y is not the dominant problem for the pair.
 return 0 if((abs(($ire||0)-99) < 0.001 || abs(($ire||0)-100) < 0.001) && $chroma >= 0.035 && $lum_abs < 4.0);
 return 1;
}

sub record_committed_top_window_bad_luma {
 my ($bad_luma,$candidate,$arrays,$best_window,$candidate_window,$best_score,$candidate_score)=@_;
 return undef if(ref($bad_luma) ne "HASH");
 my $change=committed_top_window_luma_candidate_change($candidate);
 return undef if(ref($change) ne "HASH");
 my $label=$candidate->{"label"}||"";
 my $ire;
 $ire=$1+0 if($label =~ /^top_([0-9.]+)_lum_/);
 return undef if(!defined($ire));
 return undef if(ref($best_window) ne "HASH" || ref($candidate_window) ne "HASH");
 my $before=(ref($best_window->{"points"}) eq "HASH") ? $best_window->{"points"}{$ire} : undef;
 my $after=(ref($candidate_window->{"points"}) eq "HASH") ? $candidate_window->{"points"}{$ire} : undef;
 return undef if(ref($before) ne "HASH" || ref($after) ne "HASH");
 return undef if(!defined($before->{"luminance_error_pct"}) || !defined($after->{"luminance_error_pct"}));
 return undef if(!defined($before->{"de"}) || !defined($after->{"de"}));
 my $before_lum=$before->{"luminance_error_pct"}+0;
 my $after_lum=$after->{"luminance_error_pct"}+0;
 return undef if(abs($after_lum)+0.10 >= abs($before_lum));
 my $before_de=$before->{"de"}+0;
 my $after_de=$after->{"de"}+0;
 my $before_chroma=committed_top_window_point_chroma_magnitude($before);
 my $after_chroma=committed_top_window_point_chroma_magnitude($after);
 my $score_worse=0;
 $score_worse=1 if(ref($best_score) eq "HASH" && ref($candidate_score) eq "HASH" && ($candidate_score->{"score"}||9999) > (($best_score->{"score"}||9999)+0.25));
 my $de_worse=($after_de > $before_de+0.10) ? 1 : 0;
 my $chroma_worse=($after_chroma > $before_chroma+0.004) ? 1 : 0;
 return undef if(!$de_worse && !$chroma_worse && !$score_worse);
 my $key=committed_top_window_luma_family_key($candidate,$arrays);
 return undef if(!defined($key));
 my $entry=$bad_luma->{$key};
 $entry={} if(ref($entry) ne "HASH");
 my $severe=($after_de > $before_de+0.25 || $after_chroma > $before_chroma+0.008 || $score_worse) ? 1 : 0;
 $entry->{"count"}=($entry->{"count"}||0)+1;
 $entry->{"severe_count"}=($entry->{"severe_count"}||0)+($severe ? 1 : 0);
 $entry->{"label"}=$label;
 $entry->{"ire"}=$ire+0;
	 $entry->{"index"}=$change->{"index"}+0 if(defined($change->{"index"}));
	 $entry->{"direction"}=($change->{"delta"}+0) < 0 ? -1 : 1;
	 $entry->{"magnitude"}=abs($change->{"delta"}+0);
	 $entry->{"family_key"}=$key;
 $entry->{"before_delta_e"}=$before_de;
 $entry->{"after_delta_e"}=$after_de;
 $entry->{"before_luminance_error_pct"}=$before_lum;
 $entry->{"after_luminance_error_pct"}=$after_lum;
 $entry->{"before_chroma"}=$before_chroma;
 $entry->{"after_chroma"}=$after_chroma;
 $bad_luma->{$key}=$entry;
 $entry->{"suppressed"}=committed_top_window_luma_suppressed($bad_luma,$candidate,$arrays) ? JSON::PP::true : JSON::PP::false;
 return $entry;
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
 my ($window,$config,$arrays,$bad_luma)=@_;
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
	  next if(ref($err) ne "HASH");
  my $chroma_mag=chroma_error_magnitude($err);
  my $de=defined($window->{"points"}{$ire}{"de"}) ? ($window->{"points"}{$ire}{"de"}+0) : 0;
  my $rgb_first=(abs($ire-105) < 0.001 && $de > 2.0 && $chroma_mag >= 0.030) ? 1 : 0;
  my $add_luma_candidates=sub {
   return if(!defined($lum_pct) || abs($lum_pct) < 0.35);
   my $dir=($lum_pct > 0) ? -1 : 1;
   foreach my $idx (@{$influence{$ire}||[]}) {
    foreach my $mag (0.25,0.50,0.125) {
     my $label="top_${ire}_lum_${idx}_".ddc_value_key($dir*$mag);
     my $changes=[{ setting=>"adjustingLuminance", index=>$idx, delta=>$dir*$mag }];
     my $probe={ label=>$label, changes=>$changes };
     next if(!committed_top_window_luma_allowed($window,$ire,$probe,$arrays,$bad_luma));
     committed_top_window_add_candidate(\@out,\%seen,$label,$changes);
    }
   }
  };
  $add_luma_candidates->() if(!$rgb_first);
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
  $add_luma_candidates->() if($rgb_first);
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
	 my %bad_luma_candidates;
		 $state->{"current_name"}="Committed top window";
		 $state->{"phase"}="writing";
		 $state->{"message"}="Committed top-window writes will use fresh LG calibration mode";
		 write_state($state);
		 my $top_window_calibration_mode_active=0;
		 my $ensure_top_window_write_mode=sub {
		  return undef if($top_window_calibration_mode_active);
		  my $start_error=start_calibration_mode($picture_mode,$state,"Committed top-window calibration mode enabled");
		  return $start_error if($start_error);
		  $top_window_calibration_mode_active=1;
		  return undef;
		 };
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
	  my @candidates=committed_top_window_candidates($best_window,$config,$best_arrays,\%bad_luma_candidates);
	  my $round_improved=0;
	  my $round_budget=$limit-$tested_total;
	  $round_budget=8 if($round_budget > 8);
	  my $tested_round=0;
	  foreach my $candidate (@candidates) {
	   last if(cancelled());
	   last if($tested_total >= $limit);
	   next if(committed_top_window_luma_suppressed(\%bad_luma_candidates,$candidate,$best_arrays));
	   last if($tested_round++ >= $round_budget);
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
		   $write_error=$ensure_top_window_write_mode->();
		   return $finish_top_window->($write_error) if($write_error);
	   ($picture,$write_error)=set_picture_values($picture,$candidate_arrays,$anchor,$picture_mode,1,$state,1,1);
		   return $finish_top_window->($write_error) if($write_error);
		   sync_state_picture($state,$picture,$picture_mode);
		   if($top_window_calibration_mode_active) {
		    end_calibration_mode($picture_mode);
		    set_state_calibration_mode($state,0,"");
		    $top_window_calibration_mode_active=0;
		   }
		   select(undef,undef,undef,0.6);
		   my ($candidate_window,$candidate_error)=committed_top_window_read($config,$state,\%steps_by_ire,$white_y,$target_x,$target_y,$target_gamma,$signal_mode,$candidate->{"label"}||"candidate");
	   return $finish_top_window->($candidate_error) if($candidate_error && $candidate_error ne "cancelled");
	   last if($candidate_error && $candidate_error eq "cancelled");
	   my $candidate_score=committed_top_window_score($candidate_window);
	   my $protected_worsened=committed_top_window_protected_worsened($candidate_window,$best_window);
	   my $bad_luma_candidate=record_committed_top_window_bad_luma(
	    \%bad_luma_candidates,$candidate,$best_arrays,$best_window,$candidate_window,$best_score,$candidate_score
	   );
	   trace_109($steps_by_ire{99},"committed_top_window_candidate",{
	    label=>$candidate->{"label"},
	    round=>$round+0,
	    score=>$candidate_score->{"score"}+0,
	    worst=>$candidate_score->{"worst"}+0,
	    over=>$candidate_score->{"over"}+0,
	    best_score=>$best_score->{"score"}+0,
	    best_worst=>$best_score->{"worst"}+0,
	    best_over=>$best_score->{"over"}+0,
	    protected_worsened=>$protected_worsened?1:0,
	    bad_luma_candidate=>$bad_luma_candidate
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
	     protected_worsened=>$protected_worsened?1:0,
	     bad_luma_candidate=>$bad_luma_candidate
	    });
	    $state->{"phase"}="writing";
	    $state->{"message"}="Restoring top-window best";
	    write_state($state);
		    my $restore_error;
		    $current_calibrated_slot_mask=clone_calibrated_26pt_slot_mask($best_calibrated_slot_mask);
		    refresh_propagated_uncalibrated_26pt_slots($config,$best_arrays,$current_calibrated_slot_mask);
		    promote_calibrated_26pt_slot_mask($calibrated_slot_mask,$current_calibrated_slot_mask);
		    $restore_error=$ensure_top_window_write_mode->();
		    return $finish_top_window->($restore_error) if($restore_error);
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
		  $restore_error=$ensure_top_window_write_mode->();
		  return $finish_top_window->($restore_error) if($restore_error);
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
	    my $good_105_best_blocks_final=committed_top_window_105_best_blocks_final($best_window,$final_window,undef);
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
	   if($good_105_best_blocks_final) {
	    my $best_105=(ref($best_window->{"points"}) eq "HASH") ? $best_window->{"points"}{105} : undef;
	    my $final_105=(ref($final_window->{"points"}) eq "HASH") ? $final_window->{"points"}{105} : undef;
	    trace_109($steps_by_ire{105},"committed_top_window_105_best_known_guard",{
	     reason=>"post_cal_final_did_not_beat_good_105_best_known",
	     best_delta_e=>(ref($best_105) eq "HASH" && defined($best_105->{"de"})) ? ($best_105->{"de"}+0) : undef,
	     best_luminance_error_pct=>(ref($best_105) eq "HASH" && defined($best_105->{"luminance_error_pct"})) ? ($best_105->{"luminance_error_pct"}+0) : undef,
	     final_delta_e=>(ref($final_105) eq "HASH" && defined($final_105->{"de"})) ? ($final_105->{"de"}+0) : undef,
	     final_luminance_error_pct=>(ref($final_105) eq "HASH" && defined($final_105->{"luminance_error_pct"})) ? ($final_105->{"luminance_error_pct"}+0) : undef,
	     best_score=>$best_score->{"score"}+0,
	     final_score=>$final_score->{"score"}+0
	    });
	   } else {
	    $best_window=$final_window;
	    $best_score=$final_score;
	   }
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
  prepare_standalone_committed_off_cal_read($config,$state,$picture_mode,$read_step,"committed_body_verify_read");
  clear_committed_measurement_state($state,1) if(lg_autocal_26_standalone_committed_cleanup_enabled($config));
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
  select(undef,undef,undef,$read_settle_ms/1000) if($read_settle_ms > 0 && !lg_autocal_26_standalone_committed_cleanup_enabled($config));
  $state->{"phase"}="reading";
  $state->{"message"}="Reading committed body $label after off-CAL verify adjustment";
  prepare_standalone_committed_off_cal_read($config,$state,$picture_mode,$read_step,"committed_body_verify_after_adjustment","post_commit_body_verify_read_settle_ms",2000);
  clear_committed_measurement_state($state,1) if(lg_autocal_26_standalone_committed_cleanup_enabled($config));
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
  if(lg_autocal_26_standalone_committed_cleanup_enabled($config)) {
   my $restore_read_settle_ms=config_positive_int($config,"post_commit_restore_read_settle_ms",2500,0,20000);
   select(undef,undef,undef,$restore_read_settle_ms/1000) if($restore_read_settle_ms > 0 && !lg_autocal_26_standalone_committed_cleanup_enabled($config));
   $state->{"phase"}="reading";
   $state->{"message"}="Reading restored committed body $label verify best";
   prepare_standalone_committed_off_cal_read($config,$state,$picture_mode,$read_step,"committed_body_verify_restore_read","post_commit_restore_read_settle_ms",2500);
   clear_committed_measurement_state($state,1);
   $state->{"active_stimulus"}=$read_step->{"stimulus"}+0 if(defined($read_step->{"stimulus"}));
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
    trace_109($read_step,"committed_body_verify_off_cal_restore_read",{
     label=>$label,
     calibration_mode_active=>JSON::PP::false,
     delta_e=>defined($de)?$de+0:undef,
     luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef,
     target_luminance=>defined($target_step_y)?$target_step_y+0:undef,
     values=>trace_target_values($arrays,$target),
     reading=>trace_reading_summary($reading)
    });
    remember_lg_autocal_26_best_known($config,$state,$read_step,$reading,$de,$lum_pct,$target_step_y,$arrays,$target,"committed_body_verify_restore_read");
   }
  } else {
   $state->{"readings"}=merge_reading($state->{"readings"},$best_reading) if(ref($best_reading) eq "HASH");
   $state->{"current_delta_e"}=defined($best_de) ? $best_de : undef;
   $state->{"current_luminance"}=luminance($best_reading) if(ref($best_reading) eq "HASH");
   $state->{"luminance_error_pct"}=defined($best_lum_pct) ? $best_lum_pct : undef;
  }
  trace_109($read_step,"committed_body_verify_off_cal_restored",{
   label=>$label,
   calibration_mode_active=>JSON::PP::false,
   best_delta_e=>defined($best_de)?$best_de+0:undef,
   best_luminance_error_pct=>defined($best_lum_pct)?$best_lum_pct+0:undef,
   values=>trace_target_values($arrays,$target)
  });
  remember_lg_autocal_26_best_known($config,$state,$read_step,$best_reading,$best_de,$best_lum_pct,$target_step_y,$arrays,$target,"committed_body_verify_restore")
   if(!lg_autocal_26_standalone_committed_cleanup_enabled($config));
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
 $de_limit=$target_delta if(low_shadow_strict_itp_y_step($step));
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
 my ($arrays,$target,$step,$lum_pct,$tried,$state)=@_;
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
 return undef if(luma_probe_family_suppressed($tried,$target,$current,$next,$step,"final_all_level_verify_luminance",$state));
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
	 my $lum=final_all_level_verify_luminance_adjustment($arrays,$target,$step,$lum_pct,$tried,$state);
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
 my %prior_good_105_best_known;
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
  my $prior_best_entry=lg_autocal_26_best_known_for_step($state,$read_step);
  if(
   defined($current_best_key) &&
   lg_autocal_26_good_105_best_known($read_step,$prior_best_entry,$target_delta) &&
   lg_autocal_26_best_known_values_available($prior_best_entry,$target,$arrays)
  ) {
   $prior_good_105_best_known{$current_best_key}=$prior_best_entry;
  }
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
  my $prior_good_105_best=defined($stored_best_key) ? $prior_good_105_best_known{$stored_best_key} : undef;
  my $stored_best_score=(ref($stored_best) eq "HASH" && defined($stored_best->{"score"})) ? ($stored_best->{"score"}+0) : undef;
  my %tried_values;
  mark_tried_values(\%tried_values,$arrays,$target,$de);
  my $stalls=0;
  my $step_limit=$limit;
  $step_limit=3 if(low_shadow_strict_itp_y_step($read_step) && $step_limit < 3);
  for(my $iter=1;$iter<=$step_limit;$iter++) {
   last if(cancelled());
   last if(final_all_level_verify_outlier_reason($read_step,$best_de,$best_lum_pct,$target_delta) eq "");
   my $adjustments=final_all_level_verify_adjustments($state,$arrays,$target,$read_step,$reading,$de,$lum_pct,$target_step_y,$target_delta,\%tried_values,$stalls);
   last if(!$adjustments);
   my $values_before=trace_target_values($arrays,$target);
   my $before_de_for_verify=$de;
   my $before_lum_pct_for_verify=$lum_pct;
   my $before_score_for_verify=$best_score;
   my $candidate_arrays=clone_arrays($arrays);
   foreach my $adj (@{$adjustments}) {
    next if(ref($adj) ne "HASH" || !defined($adj->{"setting"}));
    $candidate_arrays->{$adj->{"setting"}}[$target->{"index"}]=$adj->{"next"};
   }
   my $candidate_calibrated_slot_mask=clone_calibrated_26pt_slot_mask($current_calibrated_slot_mask);
   mark_calibrated_26pt_slot($candidate_calibrated_slot_mask,$target);
   refresh_propagated_uncalibrated_26pt_slots($config,$candidate_arrays,$candidate_calibrated_slot_mask);
   $state->{"phase"}="writing";
   $state->{"message"}="Final verify $label ".describe_adjustments($adjustments)." ($iter/$step_limit)";
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
   my $candidate_y_better=(defined($candidate_lum_pct) && defined($lum_pct) && abs($candidate_lum_pct) + 0.0001 < abs($lum_pct)) ? 1 : 0;
   my $candidate_worse_score_y=(defined($candidate_score) && defined($before_score_for_verify) && $candidate_score > $before_score_for_verify+0.0001 && defined($candidate_lum_pct) && defined($before_lum_pct_for_verify) && abs($candidate_lum_pct) > abs($before_lum_pct_for_verify)+0.05) ? 1 : 0;
   my $low_shadow_reject_reason="";
   $low_shadow_reject_reason=final_all_level_verify_outlier_reason($read_step,$candidate_de,$candidate_lum_pct,$target_delta)
    if(low_shadow_strict_itp_y_step($read_step));
   my $low_shadow_touch_still_outlier=($low_shadow_reject_reason ne "") ? 1 : 0;
   my $good_105_best_blocks=0;
   $good_105_best_blocks=1 if(
    $improved &&
    ref($prior_good_105_best) eq "HASH" &&
    !lg_autocal_26_candidate_beats_good_105_best_known($read_step,$candidate_score,$prior_good_105_best,$target_delta) &&
    lg_autocal_26_best_known_values_available($prior_good_105_best,$target,$candidate_arrays)
   );
   if($improved && !$good_105_best_blocks && !$low_shadow_touch_still_outlier) {
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
   if($low_shadow_touch_still_outlier && $improved && !$candidate_worse_score_y) {
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
    $stalls=0;
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
    my $current_best_entry=lg_autocal_26_best_known_entry($read_step,$candidate_reading,$candidate_de,$candidate_lum_pct,$target_step_y,$candidate_arrays,$target,"final_all_level_verify_low_shadow_retry");
    if(defined($stored_best_key) && ref($current_best_entry) eq "HASH") {
     $current_pass_best_known{$stored_best_key}=$current_best_entry;
     $stored_best=$current_best_entry;
     $stored_best_score=(defined($current_best_entry->{"score"})) ? ($current_best_entry->{"score"}+0) : undef;
    }
    trace_109($read_step,"final_all_level_verify_low_shadow_retry",{
     label=>$label,
     ire=>(defined($read_step->{"ire"}) ? $read_step->{"ire"}+0 : undef),
     reason=>"improved_working_branch_still_outlier",
     outlier_reason=>$low_shadow_reject_reason,
     iteration=>$iter+0,
     retry_limit=>$step_limit+0,
     target_delta_e=>$target_delta+0,
     current_delta_e=>defined($de)?$de+0:undef,
     current_luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef,
     previous_delta_e=>defined($before_de_for_verify)?$before_de_for_verify+0:undef,
     previous_luminance_error_pct=>defined($before_lum_pct_for_verify)?$before_lum_pct_for_verify+0:undef,
     previous_score=>defined($before_score_for_verify)?$before_score_for_verify+0:undef,
     candidate_delta_e=>defined($candidate_de)?$candidate_de+0:undef,
     candidate_luminance_error_pct=>defined($candidate_lum_pct)?$candidate_lum_pct+0:undef,
     candidate_score=>defined($candidate_score)?$candidate_score+0:undef,
     candidate_luminance_better=>$candidate_y_better?JSON::PP::true:JSON::PP::false,
     values_before=>$values_before,
     candidate_values=>trace_target_values($candidate_arrays,$target),
     working_values=>trace_target_values($arrays,$target)
    });
    write_state($state);
    next;
   }
   if($low_shadow_touch_still_outlier) {
    trace_109($read_step,"final_all_level_verify_low_shadow_touch_rejected",{
     label=>$label,
     ire=>(defined($read_step->{"ire"}) ? $read_step->{"ire"}+0 : undef),
     reason=>$candidate_worse_score_y ? "worsened_score_and_luminance" : "retry_limit_or_not_improved",
     outlier_reason=>$low_shadow_reject_reason,
     iteration=>$iter+0,
     retry_limit=>$step_limit+0,
     target_delta_e=>$target_delta+0,
     current_delta_e=>defined($de)?$de+0:undef,
     current_luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef,
     current_score=>defined($best_score)?$best_score+0:undef,
     candidate_delta_e=>defined($candidate_de)?$candidate_de+0:undef,
     candidate_luminance_error_pct=>defined($candidate_lum_pct)?$candidate_lum_pct+0:undef,
     candidate_score=>defined($candidate_score)?$candidate_score+0:undef,
     values_before=>$values_before,
     candidate_values=>trace_target_values($candidate_arrays,$target),
     restored_values=>trace_target_values($best_arrays,$target)
    });
   }
   if($good_105_best_blocks) {
    trace_109($read_step,"final_all_level_verify_105_best_known_guard",{
     label=>$label,
     reason=>"touch_did_not_beat_good_105_best_known",
     iteration=>$iter+0,
     candidate_delta_e=>defined($candidate_de)?$candidate_de+0:undef,
     candidate_luminance_error_pct=>defined($candidate_lum_pct)?$candidate_lum_pct+0:undef,
     candidate_score=>defined($candidate_score)?$candidate_score+0:undef,
     best_known_delta_e=>(ref($prior_good_105_best) eq "HASH" && defined($prior_good_105_best->{"delta_e"})) ? ($prior_good_105_best->{"delta_e"}+0) : undef,
     best_known_luminance_error_pct=>(ref($prior_good_105_best) eq "HASH" && defined($prior_good_105_best->{"luminance_error_pct"})) ? ($prior_good_105_best->{"luminance_error_pct"}+0) : undef,
     best_known_score=>(ref($prior_good_105_best) eq "HASH" && defined($prior_good_105_best->{"score"})) ? ($prior_good_105_best->{"score"}+0) : undef,
     best_known_reason=>(ref($prior_good_105_best) eq "HASH") ? $prior_good_105_best->{"reason"} : undef,
     values_before=>$values_before,
     candidate_values=>trace_target_values($candidate_arrays,$target),
     restored_values=>(ref($prior_good_105_best) eq "HASH") ? $prior_good_105_best->{"ddc_values"} : undef
    });
   }
   my $bad_luma_probe=record_bad_luma_probe_family(
    \%tried_values,$target,$adjustments,
    $before_de_for_verify,$candidate_de,
    $before_lum_pct_for_verify,$candidate_lum_pct,
    $before_score_for_verify,$candidate_score,
    $read_step,"final_all_level_verify",$state
   );
   my $stored_best_blocks=0;
   $stored_best_blocks=1 if(
    !$low_shadow_touch_still_outlier &&
    !$good_105_best_blocks &&
    defined($stored_best_score)
    && $candidate_score > $stored_best_score+0.05
    && lg_autocal_26_best_known_values_available($stored_best,$target,$candidate_arrays)
   );
   my $restore_arrays=clone_arrays($best_arrays);
   my $restore_entry=$good_105_best_blocks ? $prior_good_105_best : ($stored_best_blocks ? $stored_best : undef);
   my $restore_reason=$low_shadow_touch_still_outlier ? "low_shadow_touch_still_outlier" : ($good_105_best_blocks ? "good_105_best_known_better" : ($stored_best_blocks ? "stored_best_known_better" : "candidate_not_improved"));
   if(ref($restore_entry) eq "HASH") {
    my $stored_arrays=lg_autocal_26_arrays_with_best_known_values($candidate_arrays,$target,$restore_entry);
    $restore_arrays=$stored_arrays if(ref($stored_arrays) eq "HASH");
   }
   if($good_105_best_blocks && ref($prior_good_105_best) eq "HASH") {
    $best_arrays=clone_arrays($restore_arrays);
    $best_de=$prior_good_105_best->{"delta_e"}+0 if(defined($prior_good_105_best->{"delta_e"}));
    $best_lum_pct=$prior_good_105_best->{"luminance_error_pct"}+0 if(defined($prior_good_105_best->{"luminance_error_pct"}));
    $best_score=$prior_good_105_best->{"score"}+0 if(defined($prior_good_105_best->{"score"}));
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
    good_105_best_known_guard=>$good_105_best_blocks?JSON::PP::true:JSON::PP::false,
    good_105_best_delta_e=>(ref($prior_good_105_best) eq "HASH" && defined($prior_good_105_best->{"delta_e"})) ? ($prior_good_105_best->{"delta_e"}+0) : undef,
    good_105_best_luminance_error_pct=>(ref($prior_good_105_best) eq "HASH" && defined($prior_good_105_best->{"luminance_error_pct"})) ? ($prior_good_105_best->{"luminance_error_pct"}+0) : undef,
    target_luminance=>defined($target_step_y)?$target_step_y+0:undef,
    bad_luma_probe=>$bad_luma_probe,
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

sub post_cal_series_reference_white_y {
 my ($config,$state,$readings)=@_;
 if(ref($readings) eq "ARRAY") {
  foreach my $reading (@{$readings}) {
   next if(ref($reading) ne "HASH");
   foreach my $key (qw(lg_target_white_y series_target_white_y autocal_white_y)) {
    my $value=$reading->{$key};
    return $value+0 if(defined($value) && $value > 0);
   }
  }
 }
 foreach my $source ($config,$state) {
  next if(ref($source) ne "HASH");
  foreach my $key (qw(committed_polish_white_y target_luminance calibrated_white_luminance setup_luminance_reference)) {
   my $value=$source->{$key};
   return $value+0 if(defined($value) && $value > 0);
  }
 }
 return undef;
}

sub post_cal_series_reading_for_step {
 my ($readings,$step)=@_;
 return undef if(ref($readings) ne "ARRAY" || ref($step) ne "HASH" || !defined($step->{"ire"}));
 my $wanted=$step->{"ire"}+0;
 foreach my $reading (@{$readings}) {
  next if(ref($reading) ne "HASH" || !defined($reading->{"ire"}));
  return $reading if(abs(($reading->{"ire"}+0)-$wanted) < 0.001);
 }
 return undef;
}

sub post_cal_series_legal_white_reference_step {
 my ($steps)=@_;
 return undef if(ref($steps) ne "ARRAY");
 foreach my $step (@{$steps}) {
  next if(ref($step) ne "HASH" || !$step->{"autocal_white_reference"});
  next if(!defined($step->{"ire"}) || abs(($step->{"ire"}+0)-100) > 0.001);
  return $step;
 }
 foreach my $step (@{$steps}) {
  next if(ref($step) ne "HASH" || !defined($step->{"ire"}));
  return $step if(abs(($step->{"ire"}+0)-100) < 0.001);
 }
 return undef;
}

sub post_cal_series_shared_legal_white_target {
 my ($target)=@_;
 return 0 if(ref($target) ne "HASH" || !defined($target->{"ire"}));
 return abs(($target->{"ire"}+0)-99) < 0.001 ? 1 : 0;
}

sub post_cal_series_adjustment_luma_cap {
 my ($config,$step,$lum_pct)=@_;
 my $configured=(ref($config) eq "HASH" && defined($config->{"post_cal_series_luma_cap"})) ? ($config->{"post_cal_series_luma_cap"}+0) : undef;
 if(defined($configured) && $configured > 0) {
  $configured=0.25 if($configured < 0.25);
  $configured=6 if($configured > 6);
  return $configured;
 }
 my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : 50;
 my $abs=defined($lum_pct) ? abs($lum_pct+0) : 0;
 if($ire <= 3.1001) {
  return 1.50 if($abs >= 25);
  return 1.25 if($abs >= 15);
  return 0.50;
 }
 if($ire > 4.1001 && $ire <= 5.1001) {
  return 2.50 if($abs >= 12);
  return 1.00 if($abs >= 8);
  return 0.50;
 }
 if($ire <= 5.1001) {
  return 2.00 if($abs >= 15);
  return 1.00 if($abs >= 8);
  return 0.50;
 }
 return 0.50 if($ire <= 10.1001);
 return 0.75 if($ire >= 85 && $ire < 99 && $abs >= 2.5);
 return 1.0 if($abs >= 8);
 return 0.75 if($abs >= 4);
 return 0.50 if($abs >= 2);
 return 0.25;
}

sub post_cal_series_luma_only_deadband {
	 my ($step)=@_;
	 my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : 50;
	 return 0.80 if($ire >= 90 && $ire < 105);
	 return 0;
}

sub post_cal_series_luminance_error_for_ire {
 my ($readings,$steps,$ire,$white_y,$target_gamma,$signal_mode,$config,$state)=@_;
 return undef if(ref($readings) ne "ARRAY" || ref($steps) ne "ARRAY" || !defined($ire));
 foreach my $step (@{$steps}) {
  next if(ref($step) ne "HASH" || !defined($step->{"ire"}));
  next if(abs(($step->{"ire"}+0)-($ire+0)) > 0.001);
  my $read_step=fixed_lg_autocal_step($config,clone_picture($step));
  my $reading=post_cal_series_reading_for_step($readings,$read_step);
  next if(ref($reading) ne "HASH" || $reading->{"error"});
  my $target_step_y=effective_target_luminance_for_autocal_reading($white_y,$read_step,$reading,$target_gamma,$signal_mode,$config,$state);
  return luminance_error_percent($reading,$target_step_y);
 }
 return undef;
}

sub post_cal_series_neighbor_protected_luma_cap {
 my ($cap,$read_step,$lum_pct,$readings,$steps,$white_y,$target_gamma,$signal_mode,$config,$state)=@_;
 return $cap if(!defined($cap) || !autocal_step_is_low_shadow($read_step) || !defined($lum_pct));
 my $ire=(ref($read_step) eq "HASH" && defined($read_step->{"ire"})) ? ($read_step->{"ire"}+0) : 50;
 return $cap if(!($ire > 4.1001 && $ire <= 5.1001 && ($lum_pct+0) > 0 && abs($lum_pct+0) >= 15));
 foreach my $neighbor_ire (4,3,2.3) {
  my $neighbor_lum=post_cal_series_luminance_error_for_ire($readings,$steps,$neighbor_ire,$white_y,$target_gamma,$signal_mode,$config,$state);
  next if(!defined($neighbor_lum));
  if($neighbor_lum < -4.0) {
   return $cap < 2.0 ? $cap : 2.0;
  }
 }
 return $cap;
}

sub post_cal_series_direct_luminance_fallback_enabled {
	 my ($step,$lum_pct)=@_;
	 return 0 if(!defined($lum_pct));
	 my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : 50;
 my $abs=abs($lum_pct+0);
 return 1 if(autocal_step_is_low_shadow($step));
 return 1 if($ire <= 20.1001 && $abs >= 1.50);
 return 1 if($ire <= 30.1001 && $abs >= 2.00);
 return 0;
}

sub post_cal_series_low_shadow_unstable_skip {
 my ($step,$lum_pct,$de,$target_delta)=@_;
 return 0 if(!autocal_step_is_low_shadow($step) || !defined($lum_pct));
 my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : 50;
 my $base_delta=(defined($target_delta) && ($target_delta+0) > 0) ? ($target_delta+0) : 0.5;
 my $de_limit=($ire <= 2.3001) ? ($base_delta+0.75) : ($base_delta+0.25);
 return 0 if(defined($de) && $de > $de_limit);
 return 1 if($ire <= 2.3001 && abs($lum_pct+0) < 8.0);
 return 1 if($ire > 3.1001 && $ire <= 4.1001 && abs($lum_pct+0) < 8.0);
 return 0;
}

sub post_cal_series_luma_scales {
 my ($step,$lum_pct)=@_;
 my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : 50;
 my $abs=defined($lum_pct) ? abs($lum_pct+0) : 0;
 return (0.25,0.50) if($ire <= 5.1001 && $abs < 8);
 return (0.50,0.25) if($ire <= 10.1001 && $abs < 4);
 return (1,0.75,0.50,0.25);
}

sub post_cal_series_capped_luma_next {
 my ($current,$raw_delta,$cap)=@_;
 $current=0 if(!defined($current));
 $raw_delta=0 if(!defined($raw_delta));
 if(defined($cap) && $cap > 0) {
  $raw_delta=$cap if($raw_delta > $cap);
  $raw_delta=-$cap if($raw_delta < -$cap);
 }
 my $next=round_ddc_quarter($current+$raw_delta);
 if(defined($cap) && $cap > 0) {
  my $delta=$next-$current;
  while(abs($delta) > $cap+0.0001) {
   my $step=($delta > 0) ? -0.25 : 0.25;
   my $candidate=round_ddc_quarter($next+$step);
   last if(abs($candidate-$next) < 0.0001);
   $next=$candidate;
   $delta=$next-$current;
  }
 }
 return ($next,$next-$current);
}

sub post_cal_series_allow_rgb_adjustment {
 my ($step,$lum_pct,$luma_adjustments)=@_;
 return 0 if(autocal_step_is_peak_headroom($step));
 return 1 if(ref($luma_adjustments) ne "ARRAY" || !@{$luma_adjustments});
 return 1 if(!defined($lum_pct));
 my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : 50;
 my $abs=abs($lum_pct+0);
 return 0 if($ire <= 10.1001 && $abs >= 2.0 && $abs < 4.5);
 return 1;
}

sub post_cal_series_direct_luminance_adjustment {
	 my ($arrays,$target,$step,$lum_pct,$tried,$state,$cap,$source)=@_;
	 return undef if(ref($arrays) ne "HASH" || ref($target) ne "HASH" || !defined($lum_pct));
	 return undef if(!has_luminance_channel($arrays,$target));
	 my $tol=luminance_tolerance_percent($step);
	 my $deltae_assist=(defined($source) && $source eq "post_cal_series_deltae_luminance_assist") ? 1 : 0;
	 return undef if(!$deltae_assist && defined($tol) && abs($lum_pct) <= $tol);
 my $idx=$target->{"index"};
 return undef if(!defined($idx) || ref($arrays->{"adjustingLuminance"}) ne "ARRAY");
 my $current=$arrays->{"adjustingLuminance"}[$idx]||0;
 my $direction=($lum_pct > 0) ? -1 : 1;
 my $abs=abs($lum_pct);
 my $mag=0.25;
 $mag=0.50 if($abs >= 2.0);
 $mag=0.75 if($abs >= 8.0);
 $mag=1.00 if($abs >= 20.0);
 $cap=post_cal_series_adjustment_luma_cap(undef,$step,$lum_pct) if(!defined($cap) || $cap <= 0);
 $mag=$cap if($mag > $cap);
 my ($next,$actual_delta)=post_cal_series_capped_luma_next($current,$direction*$mag,$cap);
 return undef if(abs($next-$current) < 0.0001);
 return undef if(tried_value_exists($tried,"adjustingLuminance",$next));
 return undef if(luma_probe_family_suppressed($tried,$target,$current,$next,$step,$source||"post_cal_series_direct_luminance",$state));
 return [{
  channel=>"lum",
	  setting=>"adjustingLuminance",
	  current=>$current,
	  next=>$next,
	  delta=>$actual_delta,
	  source=>$source||"post_cal_series_direct_luminance",
	  post_cal_one_shot=>1
		 }];
	}

sub post_cal_series_deltae_luminance_assist_enabled {
 my ($step,$de,$lum_pct)=@_;
 return 0 if(!defined($de) || !defined($lum_pct));
 return 0 if($de <= 1.0);
 return 0 if(autocal_step_is_peak_headroom($step));
 my $ire=(ref($step) eq "HASH" && defined($step->{"ire"})) ? ($step->{"ire"}+0) : 50;
 return 0 if($ire > 50.1001);
 return abs($lum_pct+0) >= 1.25 ? 1 : 0;
}

sub post_cal_series_generic_rgb_adjustment {
 my ($state,$arrays,$target,$step,$reading,$de,$lum_pct,$target_delta,$tried)=@_;
 return undef if(ref($arrays) ne "HASH" || ref($target) ne "HASH" || ref($reading) ne "HASH");
 return undef if(!defined($de) || $de <= 1.0);
 return undef if(autocal_step_is_peak_headroom($step));
 my $error=autocal_adjustment_error($reading,$step);
 return undef if(ref($error) ne "HASH");
 my $lum_err=defined($lum_pct) ? (($lum_pct+0)/100) : undef;
 my $adjustments=choose_rgb_response_adjustments($error,$arrays,$target,undef,$tried,$de,$step,$target_delta,0,$lum_err);
 $adjustments=final_all_level_verify_cap_adjustments($adjustments,$step);
 return undef if(ref($adjustments) ne "ARRAY" || !@{$adjustments});
 foreach my $adj (@{$adjustments}) {
  next if(ref($adj) ne "HASH");
  $adj->{"post_cal_one_shot"}=1;
  $adj->{"post_cal_generic_rgb_fallback"}=1;
  $adj->{"source"}="post_cal_series_generic_rgb" if(!defined($adj->{"source"}));
 }
 return $adjustments;
}

sub post_cal_series_cap_luminance_adjustments {
 my ($adjustments,$cap)=@_;
 return undef if(ref($adjustments) ne "ARRAY" || !@{$adjustments});
 return $adjustments if(!defined($cap) || $cap <= 0);
 my @out;
 foreach my $adj (@{$adjustments}) {
  next if(ref($adj) ne "HASH" || !defined($adj->{"setting"}));
  my %copy=%{$adj};
  if($copy{"setting"} eq "adjustingLuminance") {
   my $current=defined($copy{"current"}) ? ($copy{"current"}+0) : undef;
   my $next=defined($copy{"next"}) ? ($copy{"next"}+0) : undef;
   my $delta=defined($copy{"delta"}) ? ($copy{"delta"}+0) : undef;
   $current=defined($delta) ? ($next-$delta) : 0 if(!defined($current) && defined($next));
   $delta=$next-$current if(defined($current) && defined($next) && !defined($delta));
	   if(defined($current) && defined($delta) && abs($delta) > $cap) {
	    $delta=($delta < 0) ? -$cap : $cap;
	    my ($capped_next,$capped_delta)=post_cal_series_capped_luma_next($current,$delta,$cap);
	    $copy{"next"}=$capped_next;
	    $copy{"delta"}=$capped_delta;
	    $copy{"post_cal_luma_cap"}=$cap+0;
	   }
  }
  push @out,\%copy;
 }
 return @out ? \@out : undef;
}

sub post_cal_series_response_axis_entry {
 my ($state,$ire,$group,$axis,$expected_sign)=@_;
 return undef if(ref($state) ne "HASH" || ref($state->{"lg_autocal_26_response_model"}) ne "HASH");
 return undef if(!defined($ire) || !defined($group) || !defined($axis));
 my $key=lg_autocal_26_best_known_key({ ire=>$ire+0 });
 return undef if(!defined($key));
 my $model=$state->{"lg_autocal_26_response_model"}{$key};
 my $entry=(ref($model) eq "HASH" && ref($model->{$group}) eq "HASH") ? $model->{$group}{$axis} : undef;
 return undef if(ref($entry) ne "HASH" || !defined($entry->{"slope"}));
 my $slope=$entry->{"slope"}+0;
 return undef if(abs($slope) < 0.000001);
 if(defined($expected_sign) && $expected_sign != 0) {
  return undef if(($slope*$expected_sign) <= 0);
 }
 my %copy=%{$entry};
 $copy{"ire"}=$ire+0;
 $copy{"samples"}=1 if(!defined($copy{"samples"}) || $copy{"samples"} <= 0);
 return \%copy;
}

sub post_cal_series_smoothed_response_axis {
 my ($state,$step,$group,$axis,$expected_sign)=@_;
 return undef if(ref($step) ne "HASH" || !defined($step->{"ire"}));
 my $ire=$step->{"ire"}+0;
 my @slots=ddc_slots();
 my $slot_index;
 for(my $i=0;$i<@slots;$i++) {
  if(abs(($slots[$i]+0)-$ire) < 0.001) { $slot_index=$i; last; }
 }
 return undef if(!defined($slot_index));
 my $exact=post_cal_series_response_axis_entry($state,$ire,$group,$axis,$expected_sign);
 my $exact_samples=(ref($exact) eq "HASH" && defined($exact->{"samples"})) ? ($exact->{"samples"}+0) : 0;
 return $exact if(ref($exact) eq "HASH" && $exact_samples >= 3);
 my @contributors;
 if(ref($exact) eq "HASH") {
  push @contributors,{ entry=>$exact, distance=>0, exact=>1 };
 }
 foreach my $direction (-1,1) {
  for(my $i=$slot_index+$direction;$i>=0 && $i<@slots;$i+=$direction) {
   my $neighbor=post_cal_series_response_axis_entry($state,$slots[$i],$group,$axis,$expected_sign);
   next if(ref($neighbor) ne "HASH");
   push @contributors,{ entry=>$neighbor, distance=>abs(($slots[$i]+0)-$ire), exact=>0 };
   last;
  }
 }
 return $exact if(@contributors < 2 && ref($exact) eq "HASH");
 return undef if(!@contributors);
 my ($weighted,$weight_total,$neighbor_count,$sample_total)=(0,0,0,0);
 my (%field_weighted,%field_weight_total);
 foreach my $item (@contributors) {
  my $entry=$item->{"entry"};
  next if(ref($entry) ne "HASH" || !defined($entry->{"slope"}));
  my $samples=$entry->{"samples"}||1;
  $samples=5 if($samples > 5);
  my $distance=$item->{"distance"}||0;
  my $weight=$samples/(1+($distance/10));
  $weight*=1.5 if($item->{"exact"});
  $weighted+=($entry->{"slope"}+0)*$weight;
  $weight_total+=$weight;
  $sample_total+=$samples;
  $neighbor_count++ if(!$item->{"exact"});
  foreach my $field (qw(x_delta x_per_ddc y_delta y_per_ddc Y_delta Y_per_ddc luminance_delta luminance_per_ddc)) {
   next if(!defined($entry->{$field}));
   $field_weighted{$field}+=($entry->{$field}+0)*$weight;
   $field_weight_total{$field}+=$weight;
  }
 }
 return $exact if($weight_total <= 0 && ref($exact) eq "HASH");
 return undef if($weight_total <= 0);
 my $slope=$weighted/$weight_total;
 return undef if(abs($slope) < 0.000001);
 if(defined($expected_sign) && $expected_sign != 0) {
  return undef if(($slope*$expected_sign) <= 0);
 }
 my %reading_fields;
 foreach my $field (keys %field_weighted) {
  next if(!$field_weight_total{$field});
  $reading_fields{$field}=$field_weighted{$field}/$field_weight_total{$field};
 }
 return {
  slope=>$slope+0,
  ddc_per_error=>1/$slope,
  samples=>$sample_total+0,
  exact_samples=>$exact_samples+0,
  %reading_fields,
  smoothed_response_model=>JSON::PP::true,
  smoothed_neighbors=>$neighbor_count+0,
  source=>"post_cal_series_smoothed_response"
 };
}

sub post_cal_series_response_table_luminance_adjustment {
 my ($state,$arrays,$target,$step,$lum_pct,$tried,$cap)=@_;
 return undef if(ref($arrays) ne "HASH" || ref($target) ne "HASH" || !defined($lum_pct));
 return undef if(!has_luminance_channel($arrays,$target));
 my $entry=post_cal_series_smoothed_response_axis($state,$step,"luminance","adjustingLuminance",1);
 return undef if(ref($entry) ne "HASH" || !defined($entry->{"slope"}));
 my $slope=$entry->{"slope"}+0;
 return undef if($slope <= 0);
 my $tol=luminance_tolerance_percent($step);
 return undef if(defined($tol) && abs($lum_pct) <= $tol);
 my $idx=$target->{"index"};
 return undef if(!defined($idx) || ref($arrays->{"adjustingLuminance"}) ne "ARRAY");
 my $current=$arrays->{"adjustingLuminance"}[$idx]||0;
 my $raw_delta=-($lum_pct+0)/$slope;
 return undef if(abs($raw_delta) < 0.10);
 $cap=post_cal_series_adjustment_luma_cap(undef,$step,$lum_pct) if(!defined($cap) || $cap <= 0);
 $raw_delta=$cap if($raw_delta > $cap);
 $raw_delta=-$cap if($raw_delta < -$cap);
 foreach my $scale (post_cal_series_luma_scales($step,$lum_pct)) {
  my ($next,$actual_delta)=post_cal_series_capped_luma_next($current,$raw_delta*$scale,$cap);
  next if(abs($next-$current) < 0.0999);
  next if(tried_value_exists($tried,"adjustingLuminance",$next));
  next if(luma_probe_family_suppressed($tried,$target,$current,$next,$step,"post_cal_series_luminance",$state));
  my $predicted=($lum_pct+0)+($slope*$actual_delta);
  next if(abs($predicted) >= abs($lum_pct)*0.92 && abs($actual_delta) > 0.21);
  return [{
   channel=>"lum",
   setting=>"adjustingLuminance",
   current=>$current,
   next=>$next,
   delta=>$actual_delta,
   map { defined($entry->{$_}) ? ($_=>$entry->{$_}+0) : () } qw(x_delta x_per_ddc y_delta y_per_ddc Y_delta Y_per_ddc luminance_delta luminance_per_ddc),
   response_model=>1,
   learned_response_model=>1,
   post_cal_response_table=>1,
   smoothed_response_model=>$entry->{"smoothed_response_model"} ? 1 : undef,
   smoothed_neighbors=>$entry->{"smoothed_neighbors"},
   exact_samples=>$entry->{"exact_samples"},
   slope=>$slope,
   ddc_per_error=>defined($entry->{"ddc_per_error"}) ? ($entry->{"ddc_per_error"}+0) : (1/$slope),
   predicted_error=>$predicted,
   source=>"post_cal_series_luminance",
   samples=>$entry->{"samples"}||1
  }];
 }
 return undef;
}

sub post_cal_series_learned_luminance_adjustment {
 my ($state,$arrays,$target,$step,$lum_pct,$tried,$cap)=@_;
 return post_cal_series_response_table_luminance_adjustment($state,$arrays,$target,$step,$lum_pct,$tried,$cap);
}

sub post_cal_series_response_table_rgb_adjustment {
 my ($state,$arrays,$target,$step,$reading,$de,$target_delta,$tried,$cap,$source)=@_;
 return undef if(ref($arrays) ne "HASH" || ref($target) ne "HASH" || ref($reading) ne "HASH");
 return undef if(autocal_step_is_peak_headroom($step));
 my $error=autocal_adjustment_error($reading,$step);
 return undef if(ref($error) ne "HASH");
 my ($ch,$err,$max_err)=furthest_rgb_error_channel($error);
 return undef if(!$ch);
 my $threshold=rgb_response_close_threshold($de,$target_delta);
 return undef if($max_err < $threshold);
 my $entry=post_cal_series_smoothed_response_axis($state,$step,"rgb",$ch,1);
 return undef if(ref($entry) ne "HASH" || !defined($entry->{"slope"}));
 my $slope=$entry->{"slope"}+0;
 return undef if($slope <= 0);
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
  return [{
   channel=>$ch,
   setting=>$setting,
   current=>$current,
   next=>$next,
   delta=>$actual_delta,
   map { defined($entry->{$_}) ? ($_=>$entry->{$_}+0) : () } qw(x_delta x_per_ddc y_delta y_per_ddc Y_delta Y_per_ddc luminance_delta luminance_per_ddc),
   response_model=>1,
   learned_response_model=>1,
   post_cal_response_table=>1,
   smoothed_response_model=>$entry->{"smoothed_response_model"} ? 1 : undef,
   smoothed_neighbors=>$entry->{"smoothed_neighbors"},
   exact_samples=>$entry->{"exact_samples"},
   slope=>$slope,
   ddc_per_error=>defined($entry->{"ddc_per_error"}) ? ($entry->{"ddc_per_error"}+0) : (1/$slope),
   predicted_error=>$predicted,
   source=>$source||"post_cal_series_rgb",
   samples=>$entry->{"samples"}||1
  }];
 }
 return undef;
}

sub post_cal_series_mark_response_table_adjustments {
 my ($adjustments)=@_;
 return undef if(ref($adjustments) ne "ARRAY" || !@{$adjustments});
 foreach my $adj (@{$adjustments}) {
  next if(ref($adj) ne "HASH");
  $adj->{"post_cal_response_table"}=JSON::PP::true if($adj->{"learned_response_model"});
 }
 return $adjustments;
}

sub post_cal_series_merge_adjustments {
	 my (@sets)=@_;
	 my @merged;
	 my %settings;
 foreach my $set (@sets) {
  next if(ref($set) ne "ARRAY");
  foreach my $adj (@{$set}) {
   next if(ref($adj) ne "HASH" || !defined($adj->{"setting"}));
   next if($settings{$adj->{"setting"}});
   push @merged,$adj;
   $settings{$adj->{"setting"}}=1;
  }
 }
	 return @merged ? \@merged : undef;
}

sub post_cal_series_revert_margin {
 my ($config)=@_;
 my $margin=(ref($config) eq "HASH" && defined($config->{"post_cal_series_revert_margin"})) ? ($config->{"post_cal_series_revert_margin"}+0) : 0.05;
 $margin=0 if($margin < 0);
 $margin=0.50 if($margin > 0.50);
 return $margin;
}

sub post_cal_series_restore_values_before {
 my ($arrays,$target,$values_before)=@_;
 return 0 if(ref($arrays) ne "HASH" || ref($target) ne "HASH" || ref($values_before) ne "HASH");
 my $idx=$target->{"index"};
 return 0 if(!defined($idx));
 my $restored=0;
 foreach my $setting (qw(adjustingLuminance whiteBalanceRed whiteBalanceGreen whiteBalanceBlue)) {
  next if(ref($arrays->{$setting}) ne "ARRAY" || !defined($values_before->{$setting}));
  next if($idx >= @{$arrays->{$setting}});
  $arrays->{$setting}[$idx]=$values_before->{$setting}+0;
  $restored=1;
 }
 return $restored;
}

sub post_cal_series_adjustment_change_for_step {
 my ($changes,$step)=@_;
 return undef if(ref($changes) ne "ARRAY" || ref($step) ne "HASH" || !defined($step->{"ire"}));
 my $ire=$step->{"ire"}+0;
 foreach my $change (@{$changes}) {
  next if(ref($change) ne "HASH" || !defined($change->{"ire"}));
  return $change if(abs(($change->{"ire"}+0)-$ire) < 0.001);
 }
 return undef;
}

sub post_cal_series_revert_worse_adjustments {
 my ($config,$state,$picture,$arrays,$picture_mode,$steps,$target_x,$target_y,$target_gamma,$signal_mode,$target_delta)=@_;
 return ($picture,"Post-cal revert requires LG 26pt steps") if(ref($steps) ne "ARRAY" || !@{$steps});
 return ($picture,"Post-cal revert requires current LG DDC arrays") if(ref($arrays) ne "HASH");
 my $after_readings=(ref($config) eq "HASH" && ref($config->{"post_cal_series_after_readings"}) eq "ARRAY") ? $config->{"post_cal_series_after_readings"} : [];
 return ($picture,"Magic Wand failsafe requires the verification series read") if(!@{$after_readings});
 my $adjustment=(ref($config) eq "HASH" && ref($config->{"post_cal_series_adjustment_status"}) eq "HASH") ? $config->{"post_cal_series_adjustment_status"} : {};
 my $changes=(ref($adjustment->{"changes"}) eq "ARRAY") ? $adjustment->{"changes"} : [];
 return ($picture,"Post-cal revert requires adjustment change metadata") if(!@{$changes});
	 my $white_y=post_cal_series_reference_white_y($config,$state,$after_readings);
	 return ($picture,"Post-cal revert is missing a target white reference") if(!defined($white_y) || $white_y <= 0);
	 set_state_white_reference($state,$white_y);
	 my $margin=post_cal_series_revert_margin($config);
	 my $legal_white_step=post_cal_series_legal_white_reference_step($steps);
	 my ($legal_white_read_step,$legal_white_after_reading);
	 if(ref($legal_white_step) eq "HASH") {
	  $legal_white_read_step=fixed_lg_autocal_step($config,clone_picture($legal_white_step));
	  $legal_white_after_reading=post_cal_series_reading_for_step($after_readings,$legal_white_read_step);
	 }
	 my (@verified,@reverted);
 foreach my $step (@{$steps}) {
  last if(cancelled());
  next if(ref($step) ne "HASH" || !defined($step->{"ire"}));
  my $target=ddc_target_for_step($step);
  next if(ref($target) ne "HASH");
  my $change=post_cal_series_adjustment_change_for_step($changes,$step);
  next if(ref($change) ne "HASH" || ref($change->{"values_before"}) ne "HASH");
  my $read_step=fixed_lg_autocal_step($config,clone_picture($step));
  my $reading=post_cal_series_reading_for_step($after_readings,$read_step);
  next if(ref($reading) ne "HASH" || $reading->{"error"});
  my $target_step_y=effective_target_luminance_for_autocal_reading($white_y,$read_step,$reading,$target_gamma,$signal_mode,$config,$state);
  annotate_reading_target($reading,$white_y,$target_step_y,$target_x,$target_y);
	  my $after_de=autocal_delta_e_for_step($config,$reading,$read_step,$white_y,$target_x,$target_y,$target_step_y);
	  my $after_lum_pct=luminance_error_percent($reading,$target_step_y);
	  my $before_de=defined($change->{"before_delta_e"}) ? ($change->{"before_delta_e"}+0) : undef;
	  my ($legal_after_de,$legal_after_lum_pct,$pair_before_de,$pair_after_de);
	  if($change->{"shared_legal_white_pair"} && ref($legal_white_after_reading) eq "HASH" && !$legal_white_after_reading->{"error"} && ref($legal_white_read_step) eq "HASH") {
	   my $legal_target_y=effective_target_luminance_for_autocal_reading($white_y,$legal_white_read_step,$legal_white_after_reading,$target_gamma,$signal_mode,$config,$state);
	   annotate_reading_target($legal_white_after_reading,$white_y,$legal_target_y,$target_x,$target_y);
	   $legal_after_de=autocal_delta_e_for_step($config,$legal_white_after_reading,$legal_white_read_step,$white_y,$target_x,$target_y,$legal_target_y);
	   $legal_after_lum_pct=luminance_error_percent($legal_white_after_reading,$legal_target_y);
	   $pair_before_de=$before_de;
	   $pair_before_de=$change->{"legal_white_before_delta_e"}+0 if(defined($change->{"legal_white_before_delta_e"}) && (!defined($pair_before_de) || ($change->{"legal_white_before_delta_e"}+0) > $pair_before_de));
	   $pair_after_de=$after_de;
	   $pair_after_de=$legal_after_de+0 if(defined($legal_after_de) && (!defined($pair_after_de) || ($legal_after_de+0) > $pair_after_de));
	  }
	  my %entry=(
	   ire=>$read_step->{"ire"}+0,
	   label=>$target->{"label"},
	   before_delta_e=>defined($before_de) ? $before_de+0 : undef,
	   after_delta_e=>defined($after_de) ? $after_de+0 : undef,
	   after_luminance_error_pct=>defined($after_lum_pct) ? $after_lum_pct+0 : undef,
	   shared_legal_white_pair=>$change->{"shared_legal_white_pair"} ? JSON::PP::true : undef,
	   legal_white_before_delta_e=>defined($change->{"legal_white_before_delta_e"}) ? $change->{"legal_white_before_delta_e"}+0 : undef,
	   legal_white_after_delta_e=>defined($legal_after_de) ? $legal_after_de+0 : undef,
	   legal_white_after_luminance_error_pct=>defined($legal_after_lum_pct) ? $legal_after_lum_pct+0 : undef,
	   pair_worst_before_delta_e=>defined($pair_before_de) ? $pair_before_de+0 : undef,
	   pair_worst_after_delta_e=>defined($pair_after_de) ? $pair_after_de+0 : undef,
	   revert_margin=>$margin+0,
	  );
	  my $compare_before=defined($pair_before_de) ? $pair_before_de : $before_de;
	  my $compare_after=defined($pair_after_de) ? $pair_after_de : $after_de;
	  my $worse=(defined($compare_before) && defined($compare_after) && $compare_after > ($compare_before+$margin)) ? 1 : 0;
  if($worse && post_cal_series_restore_values_before($arrays,$target,$change->{"values_before"})) {
   $entry{"reverted"}=JSON::PP::true;
   $entry{"values_restored"}=trace_target_values($arrays,$target);
   push @reverted,{ %entry };
  }
  push @verified,\%entry;
 }
 $state->{"post_cal_series_revert"}={
  status=>@reverted ? "writing" : "complete",
  verified=>\@verified,
  reverted=>\@reverted,
  revert_margin=>$margin+0,
 };
 $state->{"current_name"}=@reverted ? "Restoring worse post-cal corrections" : "Post-cal correction failsafe complete";
 $state->{"phase"}=@reverted ? "writing" : "complete";
 $state->{"message"}=@reverted ? ("Restoring ".scalar(@reverted)." DDC correction".(@reverted==1?"":"s")." that read worse") : "Post-cal correction failsafe found no worse points";
 write_state($state);
 return ($picture,undef) if(!@reverted);
 my $write_target;
 foreach my $step (reverse @{$steps}) {
  my $target=ddc_target_for_step($step);
  if(ref($target) eq "HASH") { $write_target=$target; last; }
 }
 return ($picture,"Post-cal revert had changes but no writable target") if(ref($write_target) ne "HASH");
 my $start_error=start_calibration_mode($picture_mode,$state,"Post-cal series revert calibration mode enabled");
 return ($picture,$start_error) if($start_error);
 my $write_error;
 ($picture,$write_error)=set_picture_values($picture,$arrays,$write_target,$picture_mode,1,$state,1,1);
 end_calibration_mode($picture_mode);
 set_state_calibration_mode($state,0,"");
 return ($picture,$write_error) if($write_error);
 sync_state_picture($state,$picture,$picture_mode);
 $state->{"post_cal_series_revert"}{"status"}="complete";
 $state->{"post_cal_series_revert"}{"ddc_restored"}=JSON::PP::true;
 $state->{"phase"}="complete";
 $state->{"message"}="Restored worse post-cal DDC corrections";
 write_state($state);
 return ($picture,undef);
}

sub post_cal_series_adjustment_reference {
 my ($config)=@_;
 return undef if(ref($config) ne "HASH");
 return $config->{"post_cal_adjustment_reference"} if(ref($config->{"post_cal_adjustment_reference"}) eq "HASH");
 return $config->{"prior_autocal_state"} if(ref($config->{"prior_autocal_state"}) eq "HASH");
 return undef;
}

sub import_post_cal_series_adjustment_reference {
 my ($config,$state)=@_;
 return 0 if(ref($state) ne "HASH");
 my $reference=post_cal_series_adjustment_reference($config);
 return 0 if(ref($reference) ne "HASH");
 my $imported=0;
 foreach my $key (qw(lg_autocal_26_response_model lg_autocal_26_best_known)) {
  next if(ref($reference->{$key}) ne "HASH");
  $state->{$key}=clone_picture($reference->{$key});
  $imported++;
 }
 $state->{"post_cal_adjustment_reference_imported"}=$imported+0 if($imported);
 return $imported;
}

sub post_cal_series_adjustment {
 my ($config,$state,$picture,$arrays,$picture_mode,$steps,$target_x,$target_y,$target_gamma,$signal_mode,$target_delta)=@_;
 return ($picture,"Post-cal series adjustment requires LG 26pt steps") if(ref($steps) ne "ARRAY" || !@{$steps});
 return ($picture,"Post-cal series adjustment requires current LG DDC arrays") if(ref($arrays) ne "HASH");
 my $readings=(ref($config) eq "HASH" && ref($config->{"post_cal_series_readings"}) eq "ARRAY") ? $config->{"post_cal_series_readings"} : [];
 return ($picture,"Post-cal series adjustment requires a completed 26pt series read") if(!@{$readings});
 import_post_cal_series_adjustment_reference($config,$state);
 my $white_y=post_cal_series_reference_white_y($config,$state,$readings);
 return ($picture,"Post-cal series adjustment is missing a target white reference") if(!defined($white_y) || $white_y <= 0);
 set_state_white_reference($state,$white_y);
 my $legal_white_step=post_cal_series_legal_white_reference_step($steps);
 my ($legal_white_read_step,$legal_white_reading,$legal_white_de,$legal_white_lum_pct,$legal_white_target_step_y,$legal_white_outlier);
 if(ref($legal_white_step) eq "HASH") {
  $legal_white_read_step=fixed_lg_autocal_step($config,clone_picture($legal_white_step));
  my $raw_legal_white_reading=post_cal_series_reading_for_step($readings,$legal_white_read_step);
  if(ref($raw_legal_white_reading) eq "HASH" && !$raw_legal_white_reading->{"error"}) {
   $legal_white_reading=clone_picture($raw_legal_white_reading);
   $legal_white_target_step_y=effective_target_luminance_for_autocal_reading($white_y,$legal_white_read_step,$legal_white_reading,$target_gamma,$signal_mode,$config,$state);
	   annotate_reading_target($legal_white_reading,$white_y,$legal_white_target_step_y,$target_x,$target_y);
	   $legal_white_de=autocal_delta_e_for_step($config,$legal_white_reading,$legal_white_read_step,$white_y,$target_x,$target_y,$legal_white_target_step_y);
	   $legal_white_lum_pct=luminance_error_percent($legal_white_reading,$legal_white_target_step_y);
	   $legal_white_outlier=final_all_level_verify_outlier_reason($legal_white_read_step,$legal_white_de,$legal_white_lum_pct,$target_delta);
	   $state->{"readings"}=merge_reading($state->{"readings"},$legal_white_reading);
	  }
	 }
 my @candidates=grep {
  ref($_) eq "HASH" &&
  defined($_->{"ire"}) &&
  !$_->{"autocal_read_only"} &&
  !$_->{"autocal_white_reference"} &&
  !$_->{"autocal_reference_only"} &&
  ddc_target_for_step($_)
 } @{$steps};
	 my @changed;
	 my @evaluated;
	 my $pre_adjust_arrays=clone_arrays($arrays);
 my $changed_count=0;
 my $total=scalar(@candidates);
 my $index=0;
 $state->{"current_name"}="Post-cal series adjustment";
 $state->{"phase"}="analyzing";
 $state->{"post_cal_series_adjustment"}={ status=>"running", total=>$total+0, current_index=>0, changed=>0 };
 write_state($state);
 foreach my $step (@candidates) {
  last if(cancelled());
  my $target=ddc_target_for_step($step);
  next if(ref($target) ne "HASH");
  my $read_step=fixed_lg_autocal_step($config,clone_picture($step));
  my $reading=post_cal_series_reading_for_step($readings,$read_step);
  $index++;
  $state->{"post_cal_series_adjustment"}={ status=>"running", total=>$total+0, current_index=>$index+0, current=>$target->{"label"}, changed=>$changed_count+0 };
  next if(ref($reading) ne "HASH" || $reading->{"error"});
  $reading=clone_picture($reading);
  my $target_step_y=effective_target_luminance_for_autocal_reading($white_y,$read_step,$reading,$target_gamma,$signal_mode,$config,$state);
  annotate_reading_target($reading,$white_y,$target_step_y,$target_x,$target_y);
  my $de=autocal_delta_e_for_step($config,$reading,$read_step,$white_y,$target_x,$target_y,$target_step_y);
  my $lum_pct=luminance_error_percent($reading,$target_step_y);
  $state->{"readings"}=merge_reading($state->{"readings"},$reading);
  push @evaluated,{
   ire=>$read_step->{"ire"}+0,
   label=>$target->{"label"},
   delta_e=>defined($de) ? $de+0 : undef,
   luminance_error_pct=>defined($lum_pct) ? $lum_pct+0 : undef,
   target_luminance=>defined($target_step_y) ? $target_step_y+0 : undef,
	  };
		  my $outlier=final_all_level_verify_outlier_reason($read_step,$de,$lum_pct,$target_delta);
		  my $shared_legal_white_pair=(post_cal_series_shared_legal_white_target($target) && ref($legal_white_reading) eq "HASH") ? 1 : 0;
		  my $legal_white_pair_worst_de=$de;
		  if($shared_legal_white_pair) {
		   $legal_white_pair_worst_de=$legal_white_de if(defined($legal_white_de) && (!defined($legal_white_pair_worst_de) || $legal_white_de > $legal_white_pair_worst_de));
		   if(@evaluated) {
		    $evaluated[-1]{"shared_legal_white_pair"}=JSON::PP::true;
		    $evaluated[-1]{"legal_white_delta_e"}=defined($legal_white_de) ? $legal_white_de+0 : undef;
		    $evaluated[-1]{"legal_white_luminance_error_pct"}=defined($legal_white_lum_pct) ? $legal_white_lum_pct+0 : undef;
		    $evaluated[-1]{"pair_worst_delta_e"}=defined($legal_white_pair_worst_de) ? $legal_white_pair_worst_de+0 : undef;
		   }
		  }
		  my $paired_outlier=$outlier;
		  $paired_outlier=$legal_white_outlier if($shared_legal_white_pair && $paired_outlier eq "" && defined($legal_white_outlier) && $legal_white_outlier ne "");
		  next if($paired_outlier eq "");
		  next if(autocal_step_is_peak_headroom($read_step));
			  if(post_cal_series_low_shadow_unstable_skip($read_step,$lum_pct,$de,$target_delta)) {
			   $evaluated[-1]{"skipped_reason"}="post_cal_low_shadow_unstable_deadband" if(@evaluated);
			   trace_109($read_step,"post_cal_series_low_shadow_unstable_deadband",{
		    label=>$target->{"label"},
	    reason=>$outlier,
	    delta_e=>defined($de)?$de+0:undef,
	    luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef,
	    skipped_reason=>"post_cal_low_shadow_unstable_deadband"
		   });
		   next;
		  }
		  my $adjust_read_step=$read_step;
			  my $adjust_reading=$reading;
			  my $adjust_de=$de;
			  my $adjust_lum_pct=$lum_pct;
		  my $control_step=$read_step;
			  my $adjust_outlier=$paired_outlier;
			  my $legal_white_drives_adjustment=0;
			  if($outlier eq "luminance") {
			   my $luma_deadband=post_cal_series_luma_only_deadband($read_step);
			   if(defined($lum_pct) && $luma_deadband > 0 && abs($lum_pct) <= $luma_deadband) {
	    $evaluated[-1]{"skipped_reason"}="post_cal_luma_only_deadband" if(@evaluated);
	    $evaluated[-1]{"post_cal_luma_only_deadband_pct"}=$luma_deadband+0 if(@evaluated);
	    trace_109($read_step,"post_cal_series_luma_only_deadband",{
	     label=>$target->{"label"},
	     reason=>$outlier,
	     delta_e=>defined($de)?$de+0:undef,
	     luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef,
	     deadband_pct=>$luma_deadband+0,
	     skipped_reason=>"post_cal_luma_only_deadband"
	    });
		    next;
		   }
			  }
		  if(post_cal_series_shared_legal_white_target($target) && ref($legal_white_reading) eq "HASH") {
		   if(defined($legal_white_de) && (!defined($de) || $legal_white_de > ($de+0.15) || (defined($legal_white_outlier) && $legal_white_outlier ne "" && $outlier eq ""))) {
		    $adjust_read_step=$legal_white_read_step;
		    $adjust_reading=$legal_white_reading;
		    $adjust_de=$legal_white_de;
		    $adjust_lum_pct=$legal_white_lum_pct;
		    # 100% legal white is read-only on LG, but it shares the 99% DDC slot.
		    # Let its measurement drive the error while the writable 99% step drives
		    # caps, luma eligibility, and tried-value policy.
		    $control_step=$read_step;
		    $control_step->{"legal_white_pair_active"}=JSON::PP::true if(ref($control_step) eq "HASH");
		    $adjust_read_step->{"legal_white_pair_active"}=JSON::PP::true if(ref($adjust_read_step) eq "HASH");
		    $adjust_outlier=defined($legal_white_outlier) && $legal_white_outlier ne "" ? $legal_white_outlier : $outlier;
		    $legal_white_drives_adjustment=1;
		   }
		   trace_109($read_step,"post_cal_series_legal_white_pair",{
		    label=>$target->{"label"},
		    reason=>$outlier,
		    delta_e=>defined($de)?$de+0:undef,
		    luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef,
		    legal_white_delta_e=>defined($legal_white_de)?$legal_white_de+0:undef,
		    legal_white_luminance_error_pct=>defined($legal_white_lum_pct)?$legal_white_lum_pct+0:undef,
		    legal_white_target_luminance=>defined($legal_white_target_step_y)?$legal_white_target_step_y+0:undef,
		    legal_white_reading=>trace_reading_summary($legal_white_reading),
		    legal_white_drives_adjustment=>$legal_white_drives_adjustment?JSON::PP::true:JSON::PP::false,
		    values_before=>trace_target_values($arrays,$target),
		   });
		  }
		  my %tried_values;
		  mark_tried_values(\%tried_values,$arrays,$target,$adjust_de);
		  my $luma_cap=post_cal_series_adjustment_luma_cap($config,$control_step,$adjust_lum_pct);
		  $luma_cap=post_cal_series_neighbor_protected_luma_cap($luma_cap,$control_step,$adjust_lum_pct,$readings,$steps,$white_y,$target_gamma,$signal_mode,$config,$state);
			  my $luma_adjustments=post_cal_series_learned_luminance_adjustment(
			   $state,$arrays,$target,$control_step,$adjust_lum_pct,\%tried_values,
			   $luma_cap
		  );
		  $luma_adjustments=post_cal_series_mark_response_table_adjustments($luma_adjustments) if($luma_adjustments);
		  if(!$luma_adjustments && post_cal_series_direct_luminance_fallback_enabled($control_step,$adjust_lum_pct)) {
		   $luma_adjustments=post_cal_series_direct_luminance_adjustment(
		    $arrays,$target,$control_step,$adjust_lum_pct,\%tried_values,$state,$luma_cap,"post_cal_series_direct_luminance"
		   );
		  }
		  if(!$luma_adjustments) {
		   $luma_adjustments=final_all_level_verify_luminance_adjustment($arrays,$target,$control_step,$adjust_lum_pct,\%tried_values,$state);
		   $luma_adjustments=post_cal_series_cap_luminance_adjustments($luma_adjustments,$luma_cap) if($luma_adjustments);
		  }
		  if(!$luma_adjustments && post_cal_series_deltae_luminance_assist_enabled($control_step,$adjust_de,$adjust_lum_pct)) {
		   $luma_adjustments=post_cal_series_direct_luminance_adjustment(
		    $arrays,$target,$control_step,$adjust_lum_pct,\%tried_values,$state,$luma_cap,"post_cal_series_deltae_luminance_assist"
		   );
		  }
		  my ($learned_ch)=furthest_rgb_error_channel(autocal_adjustment_error($adjust_reading,$adjust_read_step));
		  my $learned_setting=$learned_ch ? channel_setting($learned_ch) : undef;
		  my $learned_rgb_cap=$learned_setting ? final_all_level_verify_adjustment_cap($control_step,$learned_setting) : undef;
		  my $rgb_adjustments=post_cal_series_allow_rgb_adjustment($control_step,$adjust_lum_pct,$luma_adjustments)
		   ? post_cal_series_response_table_rgb_adjustment($state,$arrays,$target,$adjust_read_step,$adjust_reading,$adjust_de,$target_delta,\%tried_values,$learned_rgb_cap,"post_cal_series_rgb")
		   : undef;
		  $rgb_adjustments=post_cal_series_generic_rgb_adjustment($state,$arrays,$target,$adjust_read_step,$adjust_reading,$adjust_de,$adjust_lum_pct,$target_delta,\%tried_values) if(!$rgb_adjustments);
	  $rgb_adjustments=post_cal_series_mark_response_table_adjustments($rgb_adjustments) if($rgb_adjustments);
	  my $adjustments=post_cal_series_merge_adjustments($luma_adjustments,$rgb_adjustments);
  next if(ref($adjustments) ne "ARRAY" || !@{$adjustments});
  foreach my $adj (@{$adjustments}) {
   next if(ref($adj) ne "HASH" || !defined($adj->{"setting"}));
   next if(ref($arrays->{$adj->{"setting"}}) ne "ARRAY");
   $arrays->{$adj->{"setting"}}[$target->{"index"}]=$adj->{"next"};
  }
  $changed_count++;
	  push @changed,{
	   ire=>$read_step->{"ire"}+0,
	   label=>$target->{"label"},
	   reason=>$adjust_outlier,
		   before_delta_e=>defined($de) ? $de+0 : undef,
		   before_luminance_error_pct=>defined($lum_pct) ? $lum_pct+0 : undef,
		   shared_legal_white_pair=>$shared_legal_white_pair?JSON::PP::true:undef,
		   legal_white_before_delta_e=>defined($legal_white_de) && $shared_legal_white_pair ? $legal_white_de+0 : undef,
		   legal_white_before_luminance_error_pct=>defined($legal_white_lum_pct) && $shared_legal_white_pair ? $legal_white_lum_pct+0 : undef,
		   pair_worst_before_delta_e=>defined($legal_white_pair_worst_de) && $shared_legal_white_pair ? $legal_white_pair_worst_de+0 : undef,
		   legal_white_drives_adjustment=>$legal_white_drives_adjustment?JSON::PP::true:undef,
		   adjustments=>trace_adjustments_summary($adjustments),
		   target_index=>$target->{"index"}+0,
		   ddc_ire=>$target->{"ire"},
	   values_before=>trace_target_values($pre_adjust_arrays,$target),
	   values_after=>trace_target_values($arrays,$target),
	  };
	  trace_109($read_step,"post_cal_series_adjustment",{
	   label=>$target->{"label"},
	   reason=>$adjust_outlier,
	   delta_e=>defined($de)?$de+0:undef,
	   luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef,
	   shared_legal_white_pair=>$shared_legal_white_pair?JSON::PP::true:JSON::PP::false,
	   legal_white_delta_e=>defined($legal_white_de) && $shared_legal_white_pair ? $legal_white_de+0 : undef,
	   legal_white_luminance_error_pct=>defined($legal_white_lum_pct) && $shared_legal_white_pair ? $legal_white_lum_pct+0 : undef,
	   legal_white_drives_adjustment=>$legal_white_drives_adjustment?JSON::PP::true:JSON::PP::false,
	   adjustments=>trace_adjustments_summary($adjustments),
	   values_after=>trace_target_values($arrays,$target),
	  });
 }
 $state->{"post_cal_series_adjustment"}={
  status=>$changed_count ? "writing" : "complete",
  total=>$total+0,
  current_index=>$index+0,
  changed=>$changed_count+0,
  evaluated=>\@evaluated,
	  changes=>\@changed,
	  white_y=>$white_y+0,
	  pre_adjust_arrays=>$pre_adjust_arrays,
	 };
 write_state($state);
 return ($picture,undef) if(!$changed_count);
 my $write_target;
 foreach my $step (reverse @candidates) {
  my $target=ddc_target_for_step($step);
  if(ref($target) eq "HASH") { $write_target=$target; last; }
 }
 return ($picture,"Post-cal series adjustment had changes but no writable target") if(ref($write_target) ne "HASH");
 $state->{"phase"}="writing";
 $state->{"current_name"}="Applying post-cal series adjustment";
 $state->{"message"}="Applying $changed_count estimated DDC correction".($changed_count==1?"":"s")." from post-cal series";
 write_state($state);
 my $start_error=start_calibration_mode($picture_mode,$state,"Post-cal series adjustment calibration mode enabled");
 return ($picture,$start_error) if($start_error);
 my $write_error;
 ($picture,$write_error)=set_picture_values($picture,$arrays,$write_target,$picture_mode,1,$state,1,1);
 if($write_error) {
  end_calibration_mode($picture_mode);
  set_state_calibration_mode($state,0,"");
  return ($picture,$write_error);
 }
 sync_state_picture($state,$picture,$picture_mode);
 end_calibration_mode($picture_mode);
 set_state_calibration_mode($state,0,"");
 my $settle_ms=config_positive_int($config,"post_cal_series_adjust_settle_ms",6000,0,60000);
 $state->{"phase"}="settling";
 $state->{"message"}="Settling after post-cal series adjustment";
 $state->{"post_cal_series_adjustment"}{"settle_ms"}=$settle_ms+0;
 write_state($state);
 select(undef,undef,undef,$settle_ms/1000) if($settle_ms > 0);
 $state->{"post_cal_series_adjustment"}{"status"}="complete";
 write_state($state);
 return ($picture,undef);
}

sub committed_state_polish {
	 my ($config,$state,$picture,$arrays,$picture_mode,$steps,$target_x,$target_y,$target_gamma,$signal_mode,$target_delta,$polish_steps,$calibrated_slot_mask)=@_;
	 my $polish_enabled=post_commit_polish_enabled($config);
	 return ($picture,undef) if(!$polish_enabled);
	 return ($picture,undef) if(ref($steps) ne "ARRAY" || ref($arrays) ne "HASH");
 my $current_calibrated_slot_mask=clone_calibrated_26pt_slot_mask($calibrated_slot_mask);
 my ($white_step)=grep { ref($_) eq "HASH" && $_->{"autocal_white_reference"} } @{$steps};
 park_black_for_settle($config,$state);
 my $white_y=committed_polish_reference_white_y($config,$state,$steps,$target_gamma,$signal_mode,undef);
 return ($picture,undef) if(!defined($white_y) || $white_y <= 0);
 set_state_white_reference($state,$white_y);
	 $state->{"message"}="Committed polish using committed headroom white reference";
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
	 my @shadow=sort { ($b->{"ire"}||0) <=> ($a->{"ire"}||0) } grep { ($_->{"ire"}+0) <= 10.0001 } @polish_candidates;
	 my @body=sort { ($b->{"ire"}||0) <=> ($a->{"ire"}||0) } grep { ($_->{"ire"}+0) > 10.0001 && ($_->{"ire"}+0) < 99 } @polish_candidates;
	 my $include_body=(ref($config) eq "HASH" && exists($config->{"post_commit_body_polish"}))
	  ? ($config->{"post_commit_body_polish"} ? 1 : 0)
	  : (autocal_config_is_touchup($config) ? 0 : 1);
	 my $include_shadow=!(ref($config) eq "HASH" && exists($config->{"post_commit_true_low_shadow"}) && !$config->{"post_commit_true_low_shadow"});
		 my @polish=$include_body ? (@headroom,@legal_white,@body) : (@headroom,@legal_white);
		 push @polish,@shadow if($include_shadow);
		 @polish=() if(!$polish_enabled);
			 my $limit=defined($config->{"post_commit_polish_iterations"}) ? int($config->{"post_commit_polish_iterations"}) : 8;
		 $limit=1 if($limit < 1);
		 $limit=12 if($limit > 12);
	 my $polish_total=scalar(@polish);
		 my ($polish_index,$polish_touches,$polish_kept,$polish_restored)=(0,0,0,0);
		 $state->{"current_name"}="Committed polish";
		 $state->{"phase"}="writing";
		 $state->{"message"}="Committed polish writes will use fresh LG calibration mode";
		 $state->{"committed_polish"}={ status=>"running", total=>$polish_total+0, current_index=>0, touches=>0, kept=>0, restored=>0 };
		 write_state($state);
	 my $polish_calibration_mode_active=0;
	 my $ensure_polish_write_mode=sub {
	  return undef if($polish_calibration_mode_active);
	  my $start_error=start_calibration_mode($picture_mode,$state,"Committed polish calibration mode enabled");
	  return $start_error if($start_error);
	  $polish_calibration_mode_active=1;
	  return undef;
	 };
	 my $finish_polish=sub {
	  my ($error)=@_;
  if($polish_calibration_mode_active) {
   end_calibration_mode($picture_mode);
   set_state_calibration_mode($state,0,"");
   $polish_calibration_mode_active=0;
  }
  return ($picture,$error);
	 };
	 my $lock_committed_polish_white_reference=sub {
	  my ($read_step,$reading)=@_;
	  return if(!autocal_step_is_peak_headroom($read_step) || ref($reading) ne "HASH");
	  my $updated=apply_peak_headroom_reference($state,$read_step,$reading,\$white_y,$target_gamma,$signal_mode,$target_x,$target_y);
	  return if(!defined($updated) || $updated <= 0);
	  $state->{"committed_polish_white_y"}=$updated+0;
	  $state->{"committed_polish_reference_locked"}=JSON::PP::true;
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
  prepare_standalone_committed_off_cal_read($config,$state,$picture_mode,$read_step,"committed_polish_read","post_commit_polish_read_settle_ms",6000);
  clear_committed_measurement_state($state,1) if(lg_autocal_26_standalone_committed_cleanup_enabled($config));
  $state->{"active_stimulus"}=$read_step->{"stimulus"}+0 if(defined($read_step->{"stimulus"}));
  write_state($state);
	  my ($reading,$read_error)=read_step($config,$read_step,$state);
	  return $finish_polish->($read_error) if($read_error && $read_error ne "cancelled");
	  last if($read_error && $read_error eq "cancelled");
	  next if(ref($reading) ne "HASH");
	  $lock_committed_polish_white_reference->($read_step,$reading);
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
   prepare_standalone_committed_off_cal_read($config,$state,$picture_mode,$committed_pair_step,"committed_polish_pair_read","post_commit_polish_read_settle_ms",6000);
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
	     $adjustments=near_white_95_luma_adjustments($arrays,$target,$read_step,$lum_pct,$de,$target_delta,\%tried_values,$stalls,"committed_polish_near_white_95_luma",$state,1);
	    }
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
   my $before_de_for_committed_polish=$de;
   my $before_lum_pct_for_committed_polish=$lum_pct;
   my $before_score_for_committed_polish=$committed_pair_score_now->();
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
		   $write_error=$ensure_polish_write_mode->();
		   return $finish_polish->($write_error) if($write_error);
		   ($picture,$write_error)=set_picture_values($picture,$arrays,$target,$picture_mode,1,$state,1,1);
		   return $finish_polish->($write_error) if($write_error);
		   sync_state_picture($state,$picture,$picture_mode);
		   if($polish_calibration_mode_active) {
		    end_calibration_mode($picture_mode);
		    set_state_calibration_mode($state,0,"");
		    $polish_calibration_mode_active=0;
		   }
		   $state->{"phase"}="reading";
		   $state->{"message"}="Reading committed $label polish ($iter/$step_limit)";
   if(lg_autocal_26_standalone_committed_cleanup_enabled($config)) {
    prepare_standalone_committed_off_cal_read($config,$state,$picture_mode,$read_step,"committed_polish_measurement","post_commit_polish_read_settle_ms",6000);
    clear_committed_measurement_state($state,1);
   }
   write_state($state);
   ($reading,$read_error)=read_step($config,$read_step,$state);
   return $finish_polish->($read_error) if($read_error && $read_error ne "cancelled");
	   last if($read_error && $read_error eq "cancelled");
	   last if(ref($reading) ne "HASH");
	   $lock_committed_polish_white_reference->($read_step,$reading);
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
			   my $pair_update_reject_reason=(ref($committed_pair_step) eq "HASH" && !defined($best_update_reason)) ? "paired_score_not_improved" : "";
			   my $bad_luma_probe;
			   if(!$keep_committed_candidate) {
			    $bad_luma_probe=record_bad_luma_probe_family(
			     \%tried_values,$target,$adjustments,
			     $before_de_for_committed_polish,$de,
			     $before_lum_pct_for_committed_polish,$lum_pct,
			     $before_score_for_committed_polish,$score,
			     $read_step,"committed_polish",$state
			    );
			   }
			   trace_109($read_step,"committed_polish_best_candidate",{
			    label=>$label,
			    iteration=>$iter+0,
			    keep=>$keep_committed_candidate?JSON::PP::true:JSON::PP::false,
			    reason=>defined($best_update_reason)?$best_update_reason:"",
			    pair_update_reject_reason=>$pair_update_reject_reason,
			    not_worse_measurement=>$not_worse_measurement?JSON::PP::true:JSON::PP::false,
			    candidate_delta_e=>defined($de)?$de+0:undef,
			    paired_candidate_delta_e=>defined($committed_pair_de)?$committed_pair_de+0:undef,
			    candidate_99_delta_e=>defined($de)?$de+0:undef,
			    candidate_100_delta_e=>defined($committed_pair_de)?$committed_pair_de+0:undef,
			    best_delta_e=>defined($best_de)?$best_de+0:undef,
			    best_paired_delta_e=>defined($best_pair_de)?$best_pair_de+0:undef,
			    best_99_delta_e=>defined($best_de)?$best_de+0:undef,
			    best_100_delta_e=>defined($best_pair_de)?$best_pair_de+0:undef,
			    candidate_score=>$score+0,
			    best_score=>$best_score+0,
			    bad_luma_probe=>$bad_luma_probe
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
	    $write_error=$ensure_polish_write_mode->();
	    return $finish_polish->($write_error) if($write_error);
	    ($picture,$write_error)=set_picture_values($picture,$arrays,$target,$picture_mode,1,$state,1,1);
	    return $finish_polish->($write_error) if($write_error);
	    sync_state_picture($state,$picture,$picture_mode);
	    if($polish_calibration_mode_active) {
	     end_calibration_mode($picture_mode);
	     set_state_calibration_mode($state,0,"");
	     $polish_calibration_mode_active=0;
	    }
	    if(lg_autocal_26_standalone_committed_cleanup_enabled($config)) {
	     my $restore_read_settle_ms=config_positive_int($config,"post_commit_restore_read_settle_ms",2500,0,20000);
	     select(undef,undef,undef,$restore_read_settle_ms/1000) if($restore_read_settle_ms > 0 && !lg_autocal_26_standalone_committed_cleanup_enabled($config));
	     $state->{"phase"}="reading";
	     $state->{"message"}="Reading restored committed $label polish";
	     prepare_standalone_committed_off_cal_read($config,$state,$picture_mode,$read_step,"committed_polish_restore_read","post_commit_restore_read_settle_ms",6000);
	     clear_committed_measurement_state($state,1);
	     $state->{"active_stimulus"}=$read_step->{"stimulus"}+0 if(defined($read_step->{"stimulus"}));
	     write_state($state);
	     ($reading,$read_error)=read_step($config,$read_step,$state);
	     return $finish_polish->($read_error) if($read_error && $read_error ne "cancelled");
	     last if($read_error && $read_error eq "cancelled");
		     if(ref($reading) eq "HASH") {
		      $lock_committed_polish_white_reference->($read_step,$reading);
		      $target_step_y=effective_target_luminance_for_autocal_reading($white_y,$read_step,$reading,$target_gamma,$signal_mode);
	      annotate_reading_target($reading,$white_y,$target_step_y,$target_x,$target_y);
	      $de=autocal_delta_e_for_step($config,$reading,$read_step,$white_y,$target_x,$target_y,$target_step_y);
	      $lum_pct=luminance_error_percent($reading,$target_step_y);
	      $state->{"readings"}=merge_reading($state->{"readings"},$reading);
	      $state->{"current_delta_e"}=defined($de) ? $de : undef;
	      $state->{"current_luminance"}=luminance($reading);
	      set_state_target_step_luminance($state,$target_step_y);
	      $state->{"luminance_error_pct"}=defined($lum_pct) ? $lum_pct : undef;
	      trace_109($read_step,"committed_polish_restore_read",{
	       label=>$label,
	       delta_e=>defined($de)?$de+0:undef,
	       luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef,
	       values=>trace_target_values($arrays,$target),
	       reading=>trace_reading_summary($reading)
	      });
	      remember_lg_autocal_26_best_known($config,$state,$read_step,$reading,$de,$lum_pct,$target_step_y,$arrays,$target,"committed_polish_restore_read");
	     } else {
	      $reading=clone_picture($best_reading);
	      $de=$best_de;
	      $lum_pct=$best_lum_pct;
	     }
	    } else {
		    $reading=clone_picture($best_reading);
	     $de=$best_de;
	     $lum_pct=$best_lum_pct;
	     $state->{"readings"}=merge_reading($state->{"readings"},$best_reading) if(ref($best_reading) eq "HASH");
	     $state->{"current_delta_e"}=defined($best_de) ? $best_de : undef;
	     $state->{"current_luminance"}=luminance($best_reading) if(ref($best_reading) eq "HASH");
	     $state->{"luminance_error_pct"}=defined($best_lum_pct) ? $best_lum_pct : undef;
	    }
	    $committed_pair_reading=clone_picture($best_pair_reading) if(ref($best_pair_reading) eq "HASH");
	    $committed_pair_de=$best_pair_de;
	    $committed_pair_lum_pct=$best_pair_lum_pct;
	    $committed_pair_target_step_y=$best_pair_target_step_y;
	    $state->{"paired_delta_e"}=defined($best_pair_de) ? $best_pair_de : undef;
	    $state->{"paired_luminance_error_pct"}=defined($best_pair_lum_pct) ? $best_pair_lum_pct : undef;
	    my $restore_exit_de=lg_autocal_26_standalone_committed_cleanup_enabled($config) ? $de : $best_de;
	    my $restore_exit_lum_pct=lg_autocal_26_standalone_committed_cleanup_enabled($config) ? $lum_pct : $best_lum_pct;
	    last if(committed_low_shadow_good_enough($read_step,$restore_exit_de,$restore_exit_lum_pct,$target_delta));
	    my $stall_de=max_defined_delta($restore_exit_de,$best_pair_de);
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
			 promote_calibrated_26pt_slot_mask($calibrated_slot_mask,$current_calibrated_slot_mask);
			 $state->{"committed_polish"}={ status=>"complete", total=>$polish_total+0, current_index=>$polish_index+0, touches=>$polish_touches+0, kept=>$polish_kept+0, restored=>$polish_restored+0 };
			 write_state($state);
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
    ddc_layout => $LG_AUTOCAL_DDC_LAYOUT,
    whiteBalanceRed => \@zero,
    whiteBalanceGreen => \@zero,
    whiteBalanceBlue => \@zero,
    adjustingLuminance => \@zero,
   },
   picture_mode => $picture_mode,
   reset_ddc_baseline => JSON::PP::true,
   force_ddc_white_balance => JSON::PP::true,
   helper_timeout => 170,
   readback_keys => ["pictureMode","ddc_layout","whiteBalanceMethod","whiteBalanceIre","whiteBalanceRed","whiteBalanceGreen","whiteBalanceBlue","adjustingLuminance"],
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
		 my $delay_ms=int($config->{"delay_ms"}||1000);
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
apply_lg_autocal_26_default_modes($config);
apply_post_commit_verify_gate($config);
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
$LG_AUTOCAL_DDC_LAYOUT=ddc_layout_for_signal_mode($signal_mode);
my $max_iterations=defined($config->{"max_iterations"}) ? int($config->{"max_iterations"}) : 80;
my $min_iterations=autocal_config_is_touchup($config) ? 4 : 12;
if(defined($config->{"max_iterations"})) {
 $max_iterations=1 if($max_iterations < 1);
} else {
 $max_iterations=$min_iterations if($max_iterations < $min_iterations);
}
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
			 ddc_layout=>$LG_AUTOCAL_DDC_LAYOUT,
			 display_type=>$config->{"display_type"}||"lcd",
		 configured_delay_ms=>int($config->{"delay_ms"}||1000),
		 patch_insert=>$config->{"patch_insert"} ? JSON::PP::true : JSON::PP::false,
		 full_workflow=>$full_workflow ? JSON::PP::true : JSON::PP::false,
		 full_autocal_phase=>$full_autocal_phase||undef,
		 full_autocal_touchup=>autocal_config_is_touchup($config) ? JSON::PP::true : JSON::PP::false,
		 final_1d_lut_uploaded=>JSON::PP::false,
		 final_1d_lut_upload_verified=>JSON::PP::false,
		 calibration_mode=>JSON::PP::false,
			 message=>"Starting",
			};
if($full_workflow) {
 $state->{"full_autocal_post_commit_polish"}=$config->{"full_autocal_post_commit_polish"} ? JSON::PP::true : JSON::PP::false if(exists($config->{"full_autocal_post_commit_polish"}));
 $state->{"full_autocal_magic_wand"}=$config->{"full_autocal_magic_wand"} ? JSON::PP::true : JSON::PP::false if(exists($config->{"full_autocal_magic_wand"}));
}
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
			 if(autocal_config_is_post_series_revert($config)) {
			  foreach my $step (@{$steps}) {
			   my $target=ddc_target_for_step($step);
			   mark_calibrated_26pt_slot(\@calibrated_ddc_slots,$target) if(ref($target) eq "HASH");
			  }
				  $state->{"current_name"}="Magic Wand failsafe";
				  $state->{"phase"}="analyzing";
				  $state->{"message"}="Checking Magic Wand results for worse DDC corrections";
			  $state->{"full_autocal_post_series_revert"}=JSON::PP::true;
			  write_state($state);
			  my $revert_error=undef;
			  ($picture,$revert_error)=post_cal_series_revert_worse_adjustments(
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
			   $target_delta
			  );
			  die $revert_error if($revert_error && $revert_error ne "cancelled");
			 } elsif(autocal_config_is_post_series_adjust($config)) {
			  foreach my $step (@{$steps}) {
		   my $target=ddc_target_for_step($step);
		   mark_calibrated_26pt_slot(\@calibrated_ddc_slots,$target) if(ref($target) eq "HASH");
		  }
			  $state->{"current_name"}="Magic Wand";
			  $state->{"phase"}="analyzing";
			  $state->{"message"}="Estimating committed greyscale DDC corrections from the Magic Wand read";
		  $state->{"full_autocal_post_series_adjust"}=JSON::PP::true;
		  write_state($state);
		  my $adjust_error=undef;
		  ($picture,$adjust_error)=post_cal_series_adjustment(
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
		   $target_delta
		  );
		  die $adjust_error if($adjust_error && $adjust_error ne "cancelled");
			 } elsif(autocal_config_is_post_3d_polish($config)) {
			  if(!post_3d_committed_polish_requested($config)) {
				   $state->{"current_name"}="Committed polish skipped";
			   $state->{"phase"}="complete";
			   $state->{"message"}="Committed polish disabled by Full AutoCal options";
			   $state->{"post_3d_committed_polish"}=JSON::PP::false;
			   $state->{"post_3d_committed_polish_skipped"}=JSON::PP::true;
			   write_state($state);
			  } else {
			  foreach my $step (@{$steps}) {
			   my $target=ddc_target_for_step($step);
			   mark_calibrated_26pt_slot(\@calibrated_ddc_slots,$target) if(ref($target) eq "HASH");
			  }
				  $state->{"current_name"}="Committed polish";
		  $state->{"phase"}="reading";
		  $state->{"message"}="Polishing committed greyscale state after 3D LUT";
		  $state->{"post_3d_committed_polish"}=JSON::PP::true;
		  write_state($state);
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
		   $steps,
		   \@calibrated_ddc_slots
			  );
			  die $polish_error if($polish_error && $polish_error ne "cancelled");
			  }
			 } else {
		 my $finalize_calibrated_26pt_slot=sub {
		  my ($final_target,$final_read_step,$final_label)=@_;
		  if(
		   ref($config) eq "HASH" &&
		   ref($final_target) eq "HASH" &&
		   lg_autocal_26_full_ddc_spine_enabled($config)
		  ) {
		   my $anchor_entry=lg_autocal_26_best_known_for_step($state,$final_read_step || $final_target);
		   my $anchor_gate=lg_autocal_26_full_ddc_spine_anchor_seed_gate($config,$final_target,$anchor_entry,$target_delta);
		   if(ref($anchor_gate) eq "HASH" && !$anchor_gate->{"accepted"}) {
		    $state->{"lg_autocal_26_full_ddc_spine_last_rejected_anchor"}={
		     label=>$final_label||$final_target->{"label"}||"",
		     target=>$final_target,
		     gate=>$anchor_gate,
		    };
		    $state->{"message"}=($final_label||$final_target->{"label"}||"Anchor")." failed spine seed guard; leaving pending slots unseeded";
		    trace_109($final_read_step || $final_target,"full_ddc_spine_anchor_seed_guard_rejected",{
		     mode=>"full_ddc_spine",
		     label=>$final_label||$final_target->{"label"}||"",
		     target=>$final_target,
		     gate=>$anchor_gate,
		     best_known=>$anchor_entry,
		    });
		    write_state($state);
		    return 0;
		   }
		  }
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
			  my $adjacent_seed=0;
			  my $adjacent_seed_target;
			  my $final_ire=defined($final_target->{"ire"}) ? ($final_target->{"ire"}+0) : undef;
				  my $adjacent_seed_source_best;
				  my $adjacent_seed_source_best_applied=0;
				  my $adjacent_seed_skip_reason="";
				  my $adjacent_seed_source_gate;
				  if($anchor_predrive_mode && defined($final_ire)) {
				   $adjacent_seed_source_best=lg_autocal_26_best_known_for_step($state,{ ire=>$final_ire });
				   if(ref($adjacent_seed_source_best) eq "HASH") {
				    $adjacent_seed_source_best_applied=apply_lg_autocal_26_best_known_values_to_target($arrays,$final_target,$adjacent_seed_source_best);
			   } else {
			    $adjacent_seed_skip_reason="missing_final_best_source";
			   }
			   if(abs($final_ire-109) < 0.001 && ref($adjacent_seed_source_best) eq "HASH") {
			    $adjacent_seed_skip_reason="source_is_chroma_only";
				   } elsif(abs($final_ire-105) < 0.001 && ref($adjacent_seed_source_best) eq "HASH") {
				    $adjacent_seed_source_gate=lg_autocal_26_legal_white_seed_source_gate($adjacent_seed_source_best,$target_delta);
				    if(ref($adjacent_seed_source_gate) eq "HASH" && $adjacent_seed_source_gate->{"accepted"}) {
				     $adjacent_seed=copy_lg_26pt_ddc_slot_values($arrays,105,99,1);
				     $adjacent_seed->{"message"}="seeded 99 legal-white from 105" if(ref($adjacent_seed) eq "HASH");
				     $adjacent_seed->{"label"}="99% legal-white" if(ref($adjacent_seed) eq "HASH");
				     $adjacent_seed_target={ index=>ddc_slot_index_for_ire(99), ire=>format_percent(99), label=>"99% legal-white" } if(ref($adjacent_seed) eq "HASH");
				    } else {
				     $adjacent_seed_skip_reason=(ref($adjacent_seed_source_gate) eq "HASH" && defined($adjacent_seed_source_gate->{"reason"})) ? $adjacent_seed_source_gate->{"reason"} : "source_quality_gate_rejected";
				    }
				   }
				  }
				  if($anchor_predrive_mode && defined($final_ire) && $adjacent_seed_skip_reason ne "" && (abs($final_ire-109) < 0.001 || abs($final_ire-105) < 0.001)) {
				   trace_109($final_read_step || $final_target,"anchor_predrive_adjacent_seed_skipped",{
				    mode=>"anchor_predrive",
				    reason=>$adjacent_seed_skip_reason,
				    label=>$final_label||$final_target->{"label"}||"",
				    source_ire=>$final_ire+0,
				    source_final_best_reason=>ref($adjacent_seed_source_best) eq "HASH" ? ($adjacent_seed_source_best->{"reason"}||"") : "",
				    source_final_best_delta_e=>ref($adjacent_seed_source_best) eq "HASH" && defined($adjacent_seed_source_best->{"delta_e"}) ? ($adjacent_seed_source_best->{"delta_e"}+0) : undef,
				    source_final_best_luminance_error_pct=>ref($adjacent_seed_source_best) eq "HASH" && defined($adjacent_seed_source_best->{"luminance_error_pct"}) ? ($adjacent_seed_source_best->{"luminance_error_pct"}+0) : undef,
				    source_final_best_reached_target=>ref($adjacent_seed_source_best) eq "HASH" && defined($adjacent_seed_source_best->{"reached_target"}) ? $adjacent_seed_source_best->{"reached_target"} : undef,
				    legal_white_seed_gate=>$adjacent_seed_source_gate
				   });
				  }
				  if(ref($adjacent_seed) eq "HASH" && ref($adjacent_seed_target) eq "HASH" && defined($adjacent_seed_target->{"index"})) {
			   $state->{"lg_autocal_26_anchor_predrive_last_adjacent_seed"}=$adjacent_seed;
			   $state->{"lg_autocal_26_anchor_predrive_adjacent_seed_message"}=$adjacent_seed->{"message"};
			   trace_109($final_read_step || $final_target,"anchor_predrive_adjacent_seed",{
		    mode=>"anchor_predrive",
		    message=>$adjacent_seed->{"message"},
		    label=>$final_label||$final_target->{"label"}||"",
		    source_ire=>$adjacent_seed->{"source_ire"},
		    target_ire=>$adjacent_seed->{"target_ire"},
			    copy_luminance=>$adjacent_seed->{"copy_luminance"},
			    seed=>$adjacent_seed,
			    source_values=>$adjacent_seed->{"source"},
			    source_final_best_applied=>$adjacent_seed_source_best_applied+0,
				    source_final_best_reason=>ref($adjacent_seed_source_best) eq "HASH" ? ($adjacent_seed_source_best->{"reason"}||"") : "",
				    source_final_best_delta_e=>ref($adjacent_seed_source_best) eq "HASH" && defined($adjacent_seed_source_best->{"delta_e"}) ? ($adjacent_seed_source_best->{"delta_e"}+0) : undef,
				    source_final_best_luminance_error_pct=>ref($adjacent_seed_source_best) eq "HASH" && defined($adjacent_seed_source_best->{"luminance_error_pct"}) ? ($adjacent_seed_source_best->{"luminance_error_pct"}+0) : undef,
				    source_final_best_reached_target=>ref($adjacent_seed_source_best) eq "HASH" && defined($adjacent_seed_source_best->{"reached_target"}) ? $adjacent_seed_source_best->{"reached_target"} : undef,
				    legal_white_seed_gate=>$adjacent_seed_source_gate,
				    source_final_best_values=>ref($adjacent_seed_source_best) eq "HASH" ? $adjacent_seed_source_best->{"ddc_values"} : undef,
				    target_values_before=>$adjacent_seed->{"before"},
				    target_values_after=>$adjacent_seed->{"after"}
			   });
		   if(!cancelled()) {
		    $state->{"phase"}="writing";
		    $state->{"message"}=$adjacent_seed->{"message"};
		    write_state($state);
		    my $adjacent_seed_error;
		    ($picture,$adjacent_seed_error)=set_picture_values($picture,$arrays,$adjacent_seed_target,$picture_mode,$calibration_mode_active,$state);
		    die $adjacent_seed_error if($adjacent_seed_error);
		    $calibration_mode_active=1;
		    sync_state_picture($state,$picture,$picture_mode);
		   }
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
				  my $target_lum_y=effective_target_luminance_for_autocal_reading($white_y,$read_step,$ref_reading,$target_gamma,$signal_mode,$config,$state);
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
			  my $seeded_move_damping=lg_autocal_26_seeded_move_damping_for_step($config,$target,$read_step,\@calibrated_ddc_slots,$seed_from_prior_slot);
			  if($seeded_move_damping) {
			   $slot_read_step->{"lg_autocal_26_seeded_move_damping"}=JSON::PP::true if(ref($slot_read_step) eq "HASH");
			   $read_step->{"lg_autocal_26_seeded_move_damping"}=JSON::PP::true;
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
				  my $pair_best_reject_reason;
				  my $pair_side_trace_fields=sub {
				   return () if(!$paired_white_step);
				   my $candidate_metrics=legal_white_pair_side_metrics($de,$lum_pct,$read_step,$reading,$pair_de,$pair_lum_pct,$pair_step,$pair_reading);
				   my $best_metrics=legal_white_pair_side_metrics($best_de,$best_lum_pct,$best_read_step,$best_reading,$best_pair_de,$best_pair_lum_pct,$best_pair_step,$best_pair_reading);
				   return (
				    candidate_95_delta_e=>legal_white_pair_metric_delta($candidate_metrics,95),
				    candidate_99_delta_e=>legal_white_pair_metric_delta($candidate_metrics,99),
				    candidate_100_delta_e=>legal_white_pair_metric_delta($candidate_metrics,100),
				    best_95_delta_e=>legal_white_pair_metric_delta($best_metrics,95),
				    best_99_delta_e=>legal_white_pair_metric_delta($best_metrics,99),
				    best_100_delta_e=>legal_white_pair_metric_delta($best_metrics,100),
				    candidate_95_rgb_imbalance=>legal_white_pair_metric_rgb_imbalance($candidate_metrics,95),
				    candidate_99_rgb_imbalance=>legal_white_pair_metric_rgb_imbalance($candidate_metrics,99),
				    candidate_100_rgb_imbalance=>legal_white_pair_metric_rgb_imbalance($candidate_metrics,100),
				    best_95_rgb_imbalance=>legal_white_pair_metric_rgb_imbalance($best_metrics,95),
				    best_99_rgb_imbalance=>legal_white_pair_metric_rgb_imbalance($best_metrics,99),
				    best_100_rgb_imbalance=>legal_white_pair_metric_rgb_imbalance($best_metrics,100),
				    pair_update_reject_reason=>defined($pair_best_reject_reason)?$pair_best_reject_reason:""
				   );
				  };
					  my $pair_best_update_reason=sub {
						   my ($candidate_score)=@_;
						   $pair_best_reject_reason=undef;
						   return undef if(!defined($de));
							   if(!$paired_white_step) {
							    return undef if(!autocal_measurement_not_worse_than_best($de,$lum_pct,$best_de,$best_lum_pct));
							    return ($candidate_score + 0.0001 < $best_score) ? "score_improved" : undef;
							   }
						   my $candidate_metrics=legal_white_pair_side_metrics($de,$lum_pct,$read_step,$reading,$pair_de,$pair_lum_pct,$pair_step,$pair_reading);
						   my $best_metrics=legal_white_pair_side_metrics($best_de,$best_lum_pct,$best_read_step,$best_reading,$best_pair_de,$best_pair_lum_pct,$best_pair_step,$best_pair_reading);
						   foreach my $ire (95,99,100) {
						    my $candidate_side=ref($candidate_metrics) eq "HASH" ? $candidate_metrics->{$ire} : undef;
						    my $best_side=ref($best_metrics) eq "HASH" ? $best_metrics->{$ire} : undef;
						    next if(ref($candidate_side) ne "HASH" || ref($best_side) ne "HASH");
						    next if(!defined($candidate_side->{"delta_e"}) || !defined($best_side->{"delta_e"}));
						    if(
						     within_itp_luminance_included_acceptance($best_side->{"delta_e"},$best_side->{"step"}) &&
						     !within_itp_luminance_included_acceptance($candidate_side->{"delta_e"},$candidate_side->{"step"})
						    ) {
						     $pair_best_reject_reason="same_ire_${ire}_itp_guard";
						     return undef;
						    }
						   }
						   # For 99/100, the shared DDC slot must keep the best combined pair.
						   # A candidate may make the active side slightly worse while pulling the
						   # paired legal-white read materially closer; score the pair before the
						   # single-side "not worse" gate rejects it.
							   my $reason=legal_white_pair_best_update_reason(
							    $candidate_score,$best_score,
						    $de,$pair_de,$best_de,$best_pair_de,$target_delta
					   );
					   if(defined($reason)) {
					    my $candidate_worst=legal_white_pair_worst_delta($de,$pair_de);
					    my $best_worst=legal_white_pair_worst_delta($best_de,$best_pair_de);
					    my $worst_meaningfully_improved=($candidate_worst + 0.10 < $best_worst) ? 1 : 0;
					    my $candidate_100_de=legal_white_pair_metric_delta($candidate_metrics,100);
					    my $best_100_de=legal_white_pair_metric_delta($best_metrics,100);
					    my $candidate_100_rgb=legal_white_pair_metric_rgb_imbalance($candidate_metrics,100);
					    my $best_100_rgb=legal_white_pair_metric_rgb_imbalance($best_metrics,100);
					    if(!$worst_meaningfully_improved && defined($candidate_100_de) && defined($best_100_de) && $candidate_100_de > $best_100_de+0.15) {
					     $pair_best_reject_reason="100_delta_guard";
					     return undef;
					    }
					    if(!$worst_meaningfully_improved && defined($candidate_100_rgb) && defined($best_100_rgb) && $candidate_100_rgb > $best_100_rgb+0.12) {
					     $pair_best_reject_reason="100_rgb_guard";
					     return undef;
					    }
					   }
					   $pair_best_reject_reason="paired_score_not_improved" if(!defined($reason));
					   return $reason;
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
				    $pair_side_trace_fields->(),
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
					   seeded_move_damping=>$seeded_move_damping?JSON::PP::true:JSON::PP::false,
					   $pair_side_trace_fields->(),
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
						    $target_step_y,$arrays,$target,"main_initial_touchup_target",1
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
					    $lum_pct=luminance_error_percent($reading,$target_step_y);
					    set_state_target_step_luminance($state,$target_step_y);
					    $state->{"readings"}=merge_reading($state->{"readings"},$reading);
					    write_state($state);
						   } elsif(autocal_step_is_white($read_step)) {
						    set_state_white_reference($state,$white_y);
						    if(autocal_step_ignores_luminance_error($read_step)) {
						     $target_step_y=effective_target_luminance_for_autocal_reading($white_y,$read_step,$reading,$target_gamma,$signal_mode,$config,$state);
						     annotate_reading_target($reading,$white_y,$target_step_y,$target_x,$target_y);
						     $lum_pct=luminance_error_percent($reading,$target_step_y);
						     set_state_target_step_luminance($state,$target_step_y);
						    }
						    write_state($state);
						   }
				   if($pair_target_reached_now->()) {
					    remember_lg_autocal_26_best_known(
					     $config,$state,$read_step,$reading,$de,$lum_pct,
						     $target_step_y,$arrays,$target,"main_initial_target_reached",1
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
						  my $hdr20_body_vector_next_adjustments;
						  my $legal_white_pair_score_stalled=0;
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
					    $pair_side_trace_fields->(),
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
			   $state->{"current_delta_e"}=defined($de) ? $de+0 : undef;
			   $state->{"current_luminance"}=luminance($reading);
			   set_state_target_step_luminance($state,$target_step_y);
			   $state->{"luminance_error_pct"}=defined($lum_pct) ? $lum_pct+0 : undef;
			   $state->{"readings"}=merge_reading($state->{"readings"},$reading);
			   write_state($state);
			   return 1;
			  };
			  my $restore_headroom_105_near_y_cleanup_branch=sub {
			   my ($reason)=@_;
			   my $branch=headroom_105_near_y_cleanup_branch(\%tried_values);
			   return 0 if(ref($branch) ne "HASH" || ref($branch->{"arrays"}) ne "HASH" || ref($branch->{"reading"}) ne "HASH");
			   trace_109($read_step,"restore_headroom_105_near_y_cleanup_branch",{
			    label=>$label,
			    reason=>$reason||"Restoring 105 near-Y cleanup branch",
			    attempts=>$branch->{"attempts"}||0,
			    candidate_delta_e=>defined($de)?$de+0:undef,
			    candidate_luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef,
			    branch_delta_e=>defined($branch->{"de"})?$branch->{"de"}+0:undef,
			    branch_luminance_error_pct=>defined($branch->{"lum_pct"})?$branch->{"lum_pct"}+0:undef,
			    branch_values=>trace_target_values($branch->{"arrays"},$target)
			   });
			   $arrays=clone_arrays($branch->{"arrays"});
			   $state->{"phase"}="restoring";
			   $state->{"message"}=$reason||"Restoring 105 near-Y cleanup branch";
			   write_state($state);
			   my $restore_error;
			   ($picture,$restore_error)=set_picture_values($picture,$arrays,$target,$picture_mode,$calibration_mode_active,$state);
			   die $restore_error if($restore_error);
			   $calibration_mode_active=1;
			   sync_state_picture($state,$picture,$picture_mode);
			   $read_step=clone_picture($branch->{"read_step"}) if(ref($branch->{"read_step"}) eq "HASH");
			   $reading=clone_picture($branch->{"reading"});
			   $de=$branch->{"de"};
			   $lum_pct=$branch->{"lum_pct"};
			   $white_y=update_white_reference_for_autocal_step($config,$state,$read_step,$reading,$white_y);
			   refresh_headroom_targets_after_white_reference($state,$read_step,$white_y,$target_x,$target_y,$target_gamma,$signal_mode);
			   $target_step_y=effective_target_luminance_for_autocal_reading($white_y,$read_step,$reading,$target_gamma,$signal_mode);
			   $state->{"readings"}=merge_reading($state->{"readings"},$reading) if(ref($reading) eq "HASH");
			   $state->{"current_delta_e"}=defined($de) ? $de : undef;
			   $state->{"current_luminance"}=luminance($reading);
			   $state->{"luminance_error_pct"}=defined($lum_pct) ? $lum_pct : undef;
			   set_state_target_step_luminance($state,$target_step_y);
			   write_state($state);
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
				   my $before_probe_de=$de;
				   my $before_probe_lum_pct=$lum_pct;
				   my $before_probe_score=$candidate_score;
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
				   my $bad_luma_probe;
				   if(!$keep) {
				    $bad_luma_probe=record_bad_luma_probe_family(
				     $tried_ref,$target,[$luma_adj],
				     $before_probe_de,$de,
				     $before_probe_lum_pct,$lum_pct,
				     $before_probe_score,$paired_score,
				     $read_step,"high_end_paired_luma",$state
				    );
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
				    bad_luma_probe=>$bad_luma_probe,
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
					   my $headroom_105_luma_blocking=headroom_105_luma_blocking_active($read_step,$arrays,$target,\%tried_values,$lum_err);
					   my $headroom_105_luma_priority=headroom_105_luma_priority_active($read_step,$arrays,$target,\%tried_values,$lum_err);
					   my $headroom_105_near_y_cleanup_active=headroom_105_near_y_cleanup_branch_active(\%tried_values,$read_step,$arrays,$target,$lum_err);
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
										    $adjustments=$body_luminance_next_adjustments if(!$headroom_105_near_y_cleanup_active && (!$headroom_105_luma_priority || ref(luma_only_adjustment($body_luminance_next_adjustments)) eq "HASH"));
										    $body_luminance_next_adjustments=undef;
										   }
								   if(
								    !$adjustments &&
								    autocal_step_is_hdr20_body($read_step) &&
								    ref($hdr20_body_vector_next_adjustments) eq "ARRAY"
								   ) {
								    $adjustments=$hdr20_body_vector_next_adjustments;
								    $hdr20_body_vector_next_adjustments=undef;
								   }
								   if(!$adjustments && autocal_step_is_low_shadow($read_step)) {
								    $adjustments=low_shadow_luminance_priority_adjustments($arrays,$target,$lum_err,$de,$stalls,\%tried_values,$read_step,0);
								    $adjustments=low_shadow_chroma_luminance_coupled_adjustments($err,$arrays,$target,$lum_err,$de,$target_delta,\%tried_values,$read_step,0) if(!$adjustments);
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
								   if(
								    !$adjustments &&
								    lg_autocal_26_full_ddc_spine_body_anchor($target) &&
								    !lg_autocal_26_full_ddc_spine_anchor_revisit_step($read_step)
								   ) {
								    $adjustments=full_ddc_spine_anchor_adjustments($config,$err,$arrays,$target,$read_step,$de,$lum_err,$stalls,\%tried_values,$target_delta);
								   }
												   if(!$adjustments && autocal_step_is_hdr20_body($read_step)) {
												    $adjustments=hdr20_body_balanced_chroma_luma_adjustments($err,$arrays,$target,$read_step,$de,$target_delta,$lum_err,$stalls,\%tried_values,0.25,0);
												   }
												   if(!$adjustments && autocal_step_is_hdr20_body($read_step)) {
												    $adjustments=hdr20_body_rgb_luminance_vector_adjustments($err,$arrays,$target,$read_step,$de,$target_delta,$lum_err,$stalls,\%tried_values,0.25,0,"main_hdr20_body");
												   }
												   if(!$adjustments && autocal_step_is_hdr20_body($read_step) && abs(($lum_err||0)*100) >= 8) {
												    $adjustments=hdr20_body_luminance_rgb_adjustments($arrays,$target,$read_step,$lum_err,$de,$stalls,\%tried_values,0.25);
												   }
											   if(!$adjustments) {
											    $adjustments=hdr20_body_chroma_luma_adjustments($err,$arrays,$target,$read_step,$de,$target_delta,$lum_err,$stalls,\%tried_values,0.25,0);
											   }
											   if(!$adjustments && autocal_step_is_hdr20_body($read_step)) {
											    $adjustments=hdr20_body_rgb_luminance_vector_adjustments($err,$arrays,$target,$read_step,$de,$target_delta,$lum_err,$stalls,\%tried_values,0.25,0,"main_hdr20_body_fallback");
											   }
											   if(!$adjustments) {
											    $adjustments=hdr20_body_luminance_rgb_adjustments($arrays,$target,$read_step,$lum_err,$de,$stalls,\%tried_values,0.25);
											   }
									   if(!$adjustments) {
									    $adjustments=lg_autocal_26_initial_learned_target_adjustments(
									     $state,$arrays,$target,$read_step,$reading,$de,$target_delta,$lum_pct,\%tried_values,
									     $iter,$iteration_limit,$stalls,$paired_white_step
									    );
									   }
									   if(!$adjustments) {
									    $adjustments=headroom_105_main_polish_refine_adjustments($state,$arrays,$target,$read_step,$reading,$de,$lum_pct,$target_delta,\%tried_values,$stalls,$lum_err,\%rgb_response_model,$err);
									   }
								   if(!$adjustments) {
								    $adjustments=headroom_105_luma_priority_adjustment($arrays,$target,$lum_err,$de,$stalls,\%tried_values,0.25,1,0,$read_step);
								   }
								   if(!$adjustments) {
								    $adjustments=headroom_105_all_down_luma_adjustment($arrays,$target,$lum_err,$de,$stalls,\%tried_values,0.25,2,0,$read_step);
								   }
								   if(!$adjustments) {
								    $adjustments=headroom_105_floor_luma_coupled_adjustment($err,$arrays,$target,$lum_err,$de,$stalls,\%tried_values,0.25,1,0,$read_step);
								   }
								   if(!$adjustments) {
								    $adjustments=full_ddc_spine_anchor_adjustments($config,$err,$arrays,$target,$read_step,$de,$lum_err,$stalls,\%tried_values,$target_delta);
								   }
								   if(!$adjustments && !$headroom_105_luma_blocking && !$headroom_105_near_y_cleanup_active) {
								    $adjustments=body_luminance_priority_adjustments($arrays,$target,$lum_err,$de,$stalls,\%tried_values,$read_step);
								    $adjustments=undef if($adjustments && autocal_step_is_hdr20_body($read_step) && ref(luma_only_adjustment($adjustments)) eq "HASH");
								   }
								   if(!$adjustments && !$headroom_105_luma_blocking && !$headroom_105_near_y_cleanup_active) {
								    $adjustments=full_ddc_spine_seeded_body_luminance_priority_adjustments($config,$arrays,$target,$lum_err,$de,$stalls,\%tried_values,$read_step);
								    $adjustments=undef if($adjustments && autocal_step_is_hdr20_body($read_step) && ref(luma_only_adjustment($adjustments)) eq "HASH");
								   }
								   if(
								    !$adjustments &&
								    !$headroom_105_luma_blocking &&
								    autocal_step_is_fast_headroom($read_step) &&
							    ref($headroom_next_adjustments) eq "ARRAY" &&
							    headroom_queued_adjustment_still_best($headroom_next_adjustments,$err,$de,$target_delta,$read_step)
							   ) {
							    $adjustments=$headroom_next_adjustments;
							    $headroom_next_adjustments=undef;
								   } else {
								    $headroom_next_adjustments=undef if(autocal_step_is_fast_headroom($read_step));
								    my $hdr20_body_far_luma=(autocal_step_is_hdr20_body($read_step) && abs(($lum_err||0)*100) >= 8) ? 1 : 0;
								    if(!$hdr20_body_far_luma) {
								     $adjustments=choose_rgb_response_adjustments($err,$arrays,$target,\%rgb_response_model,\%tried_values,$de,$read_step,$target_delta,$stalls,$lum_err) if(!$adjustments && !$headroom_105_luma_blocking);
								    }
								    $adjustments=lg_autocal_26_adaptive_headroom_luminance_adjustment($state,$arrays,$target,$read_step,$lum_pct,\%tried_values,$stalls,"main_headroom_luminance") if(!$adjustments && !$headroom_105_near_y_cleanup_active);
								    $adjustments=undef if($adjustments && autocal_step_is_hdr20_body($read_step) && ref(luma_only_adjustment($adjustments)) eq "HASH");
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
					   my $before_de_for_adjustment=$de;
					   my $before_lum_pct_for_adjustment=$lum_pct;
					   my $before_score_for_adjustment=$paired_white_step ? $pair_score_now->() : guarded_autocal_result_score($de,$lum_pct,$read_step,$reading,$white_guard_y);
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
							   my $hdr20_candidate_next_adjustments=hdr20_body_vector_response_adjustments($read_step,$adjustments,$before_adjustment_reading,$reading,$arrays,$target,\%tried_values,"main_hdr20_body_vector_response");
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
							     $hdr20_body_vector_next_adjustments=undef;
							    }
						   }
						   my $candidate_score_after=$paired_white_step ? $pair_score_now->() : guarded_autocal_result_score($de,$lum_pct,$read_step,$reading,$white_guard_y);
						   my $hdr20_luminance_progress=0;
						   if(autocal_step_is_hdr20_body($read_step) && defined($before_lum_pct_for_adjustment) && defined($lum_pct)) {
						    my $before_abs=abs($before_lum_pct_for_adjustment+0);
						    my $after_abs=abs($lum_pct+0);
						    $hdr20_luminance_progress=1 if($after_abs + 0.08 < $before_abs);
						   }
						   my $headroom_105_response_update=record_headroom_105_response(
						    \%tried_values,$target,$read_step,$adjustments,
						    $before_adjustment_reading,$reading,
					    $before_lum_pct_for_adjustment,$lum_pct,
					    $before_de_for_adjustment,$de,
					    $before_score_for_adjustment,$candidate_score_after
					   );
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
								    hdr20_luminance_progress=>$hdr20_luminance_progress?JSON::PP::true:JSON::PP::false,
									    rgb_response_model=>$rgb_response_update,
									    saved_response_model=>$saved_response_model,
								    headroom_105_response_update=>$headroom_105_response_update,
								    $pair_side_trace_fields->(),
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
				   if(adjustment_total($adjustments) >= 1 && $response_score < $no_response_threshold && !$hdr20_luminance_progress) {
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
								    my $headroom_105_score_keep=0;
								    my $headroom_105_score_branch_promote=0;
								    my $headroom_105_main_polish_refine=headroom_105_main_polish_refine_adjustment($adjustments);
								    my $headroom_105_main_polish_keep=0;
								    my $full_ddc_spine_anchor_y_keep=0;
								    my $headroom_105_luma_blocking_after=(!$paired_white_step && defined($lum_pct))
								     ? headroom_105_luma_blocking_active($read_step,$arrays,$target,\%tried_values,$lum_pct/100)
								     : 0;
								    if(
								     !$paired_white_step &&
								     headroom_105_post_seed_body_refinement($read_step,$arrays,$target,\%tried_values) &&
								     defined($candidate_score_after) && defined($best_score) &&
								     defined($lum_pct) && defined($best_lum_pct) &&
								     abs($lum_pct) + 0.05 < abs($best_lum_pct) &&
								     $candidate_score_after + 0.0001 < $best_score &&
								     (!defined($de) || !defined($best_de) || ($best_de > 1.25) || ($de <= $best_de+0.020))
								    ) {
								     $headroom_105_score_keep=1;
								     $best_update_reason="headroom_105_y_score_keep";
								    }
								    if(
								     !$headroom_105_score_keep &&
								     !$paired_white_step &&
								     headroom_105_score_branch_promote_candidate(
								      $read_step,$arrays,$target,\%tried_values,$adjustments,
								      $lum_pct,$candidate_score_after,$best_lum_pct,$best_score,$de,$best_de
								     )
								    ) {
								     $headroom_105_score_branch_promote=1;
								     $best_update_reason="headroom_105_score_branch_promoted";
								    }
								    if(
								     !$paired_white_step &&
								     $headroom_105_main_polish_refine &&
								     defined($candidate_score_after) && defined($best_score) &&
								     $candidate_score_after + 0.0001 < $best_score
								    ) {
								     my $candidate_y_worse=(defined($lum_pct) && defined($before_lum_pct_for_adjustment) && abs($lum_pct) > abs($before_lum_pct_for_adjustment)+0.05) ? 1 : 0;
								     my $candidate_de_worse=(defined($de) && defined($before_de_for_adjustment) && ($de+0) > ($before_de_for_adjustment+0)+0.25) ? 1 : 0;
								     if(!$candidate_y_worse || !$candidate_de_worse) {
								      $headroom_105_main_polish_keep=1;
								      $best_update_reason="headroom_105_main_polish_refine_score_keep" if(!defined($best_update_reason));
								     }
								    }
								    if(
								     !$paired_white_step &&
								     full_ddc_spine_anchor_luma_progress_keep(
								      $config,$target,$read_step,$adjustments,
								      $lum_pct,$best_lum_pct,$de,$best_de,$candidate_score_after,$best_score
								     )
								    ) {
								     $full_ddc_spine_anchor_y_keep=1;
								     $best_update_reason="full_ddc_spine_anchor_y_keep" if(!defined($best_update_reason));
								    }
								    my $keep_candidate=$paired_white_step
								     ? defined($best_update_reason)
								     : (defined($de) && ($headroom_105_luma_blocking_after
								      ? ($headroom_105_score_keep || $headroom_105_score_branch_promote || $headroom_105_main_polish_keep)
								      : (($not_worse_measurement && ($candidate_score_after + 0.0001 < $best_score || $chroma_keep || $delta_keep)) || $headroom_105_score_keep || $headroom_105_score_branch_promote || $headroom_105_main_polish_keep || $full_ddc_spine_anchor_y_keep)));
					    if($keep_candidate) {
					    if($headroom_105_score_branch_promote) {
					     trace_109($read_step,"headroom_105_score_branch_promoted",{
					      label=>$label,
					      iteration=>$iter+0,
					      prior_delta_e=>defined($best_de)?$best_de+0:undef,
					      prior_luminance_error_pct=>defined($best_lum_pct)?$best_lum_pct+0:undef,
					      prior_score=>defined($best_score)?$best_score+0:undef,
					      candidate_delta_e=>defined($de)?$de+0:undef,
					      candidate_luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef,
					      candidate_score=>defined($candidate_score_after)?$candidate_score_after+0:undef,
					      reason=>"rgb_branch_lower_combined_score",
					      adjustments=>trace_adjustments_summary($adjustments),
					      prior_values=>trace_target_values($best_arrays,$target),
					      candidate_values=>trace_target_values($arrays,$target)
					     });
					    }
					    if($headroom_105_main_polish_refine) {
					     trace_109($read_step,"headroom_105_main_polish_refine_keep",{
					      label=>$label,
					      iteration=>$iter+0,
					      reason=>$headroom_105_main_polish_keep ? "score_improved" : "normal_keep",
					      before_delta_e=>defined($before_de_for_adjustment)?$before_de_for_adjustment+0:undef,
					      before_luminance_error_pct=>defined($before_lum_pct_for_adjustment)?$before_lum_pct_for_adjustment+0:undef,
					      before_score=>defined($before_score_for_adjustment)?$before_score_for_adjustment+0:undef,
					      previous_best_delta_e=>defined($best_de)?$best_de+0:undef,
					      previous_best_luminance_error_pct=>defined($best_lum_pct)?$best_lum_pct+0:undef,
					      previous_best_score=>defined($best_score)?$best_score+0:undef,
					      candidate_delta_e=>defined($de)?$de+0:undef,
					      candidate_luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef,
					      candidate_score=>defined($candidate_score_after)?$candidate_score_after+0:undef,
					      adjustments=>trace_adjustments_summary($adjustments),
					      values_before=>$before_values,
					      candidate_values=>trace_target_values($arrays,$target)
					     });
					    }
				    $best_de=$de;
				    $best_lum_pct=$lum_pct;
				    $best_score=$candidate_score_after;
					    $best_arrays=clone_arrays($arrays);
						    $best_reading=clone_picture($reading);
						    $best_read_step=clone_picture($read_step);
						    delete($tried_values{"__headroom_105_near_y_cleanup"});
							    $store_best_pair->() if($paired_white_step);
							    $low_shadow_next_adjustments=$low_shadow_candidate_next_adjustments if(ref($low_shadow_candidate_next_adjustments) eq "ARRAY");
							    $body_luminance_next_adjustments=$body_candidate_next_adjustments if(ref($body_candidate_next_adjustments) eq "ARRAY");
							    $hdr20_body_vector_next_adjustments=$hdr20_candidate_next_adjustments if(ref($hdr20_candidate_next_adjustments) eq "ARRAY");
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
					     headroom_105_score_branch_promoted=>$headroom_105_score_branch_promote?JSON::PP::true:JSON::PP::false,
					     headroom_105_main_polish_refine=>$headroom_105_main_polish_refine?JSON::PP::true:JSON::PP::false,
					     full_ddc_spine_anchor_y_keep=>$full_ddc_spine_anchor_y_keep?JSON::PP::true:JSON::PP::false,
						     not_worse_measurement=>$not_worse_measurement?JSON::PP::true:JSON::PP::false,
						     candidate_chroma_delta_e=>defined($candidate_chroma)?$candidate_chroma+0:undef,
						     previous_chroma_delta_e=>defined($best_chroma)?$best_chroma+0:undef,
						     $pair_side_trace_fields->(),
						     best_values=>trace_target_values($best_arrays,$target)
						    });
			   } else {
				    $stalls++;
				    my $candidate_score=$candidate_score_after;
				    my ($chroma_keep,$candidate_chroma,$best_chroma)=$candidate_chroma_keep->();
				    my $delta_keep=$candidate_delta_keep->();
				    my $luma_anchor_working=headroom_luminance_anchor_working_state($read_step,$lum_pct,$best_lum_pct,$de,$best_de);
				    if(autocal_step_is_fast_headroom($read_step) && !autocal_step_is_peak_headroom($read_step)) {
				     $luma_anchor_working=headroom_105_luminance_progress_working_state($read_step,$arrays,$target,\%tried_values,$lum_pct,$best_lum_pct,$de,$best_de,$candidate_score_after,$best_score);
				    }
					    my $bad_luma_probe=record_bad_luma_probe_family(
					     \%tried_values,$target,$adjustments,
					     $before_de_for_adjustment,$de,
					     $before_lum_pct_for_adjustment,$lum_pct,
					     $before_score_for_adjustment,$candidate_score_after,
					     $read_step,"main",$state
					    );
					    my $bad_hdr20_body_family=record_hdr20_body_bad_adjustment_family(
					     \%tried_values,$read_step,$adjustments,
					     $before_lum_pct_for_adjustment,$lum_pct,
					     $before_de_for_adjustment,$de,
					     $before_score_for_adjustment,$candidate_score_after
					    );
					    my $headroom_105_near_y_working=headroom_105_near_y_cleanup_working_candidate(
				     $read_step,$arrays,$target,\%tried_values,$adjustments,
				     $before_lum_pct_for_adjustment,$lum_pct,
				     $before_de_for_adjustment,$de,
				     $before_score_for_adjustment,$candidate_score_after
				    );
					    if($headroom_105_near_y_working) {
					     $tried_values{"__headroom_105_near_y_cleanup"}={
					      active=>1,
					      mode=>"near_y_cleanup",
					      attempts=>0,
					      max_attempts=>2,
				      arrays=>clone_arrays($arrays),
				      reading=>clone_picture($reading),
				      read_step=>clone_picture($read_step),
				      de=>defined($de)?$de+0:undef,
				      lum_pct=>defined($lum_pct)?$lum_pct+0:undef,
				      score=>defined($candidate_score_after)?$candidate_score_after+0:undef
				     };
				     $luma_anchor_working=1;
				     trace_109($read_step,"headroom_105_near_y_cleanup_branch_started",{
				      label=>$label,
				      iteration=>$iter+0,
				      candidate_delta_e=>defined($de)?$de+0:undef,
				      candidate_luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef,
				      best_delta_e=>defined($best_de)?$best_de+0:undef,
				      best_luminance_error_pct=>defined($best_lum_pct)?$best_lum_pct+0:undef,
				      best_score=>$best_score+0,
				      candidate_score=>defined($candidate_score_after)?$candidate_score_after+0:undef,
					      working_values=>trace_target_values($arrays,$target)
					     });
					    } elsif(headroom_105_score_y_working_candidate(
					     $read_step,$arrays,$target,\%tried_values,$adjustments,
					     $before_lum_pct_for_adjustment,$lum_pct,
					     $before_score_for_adjustment,$candidate_score_after,
					     $best_lum_pct,$best_score,
					     $before_de_for_adjustment,$de
					    )) {
					     $tried_values{"__headroom_105_near_y_cleanup"}={
					      active=>1,
					      mode=>"score_y_recovery",
					      attempts=>0,
					      max_attempts=>3,
					      arrays=>clone_arrays($arrays),
					      reading=>clone_picture($reading),
					      read_step=>clone_picture($read_step),
					      de=>defined($de)?$de+0:undef,
					      lum_pct=>defined($lum_pct)?$lum_pct+0:undef,
					      score=>defined($candidate_score_after)?$candidate_score_after+0:undef
					     };
					     $luma_anchor_working=1;
					     trace_109($read_step,"headroom_105_score_y_branch_started",{
					      label=>$label,
					      iteration=>$iter+0,
					      before_luminance_error_pct=>defined($before_lum_pct_for_adjustment)?$before_lum_pct_for_adjustment+0:undef,
					      candidate_delta_e=>defined($de)?$de+0:undef,
					      candidate_luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef,
					      candidate_score=>defined($candidate_score_after)?$candidate_score_after+0:undef,
					      best_delta_e=>defined($best_de)?$best_de+0:undef,
					      best_luminance_error_pct=>defined($best_lum_pct)?$best_lum_pct+0:undef,
					      best_score=>$best_score+0,
					      adjustments=>trace_adjustments_summary($adjustments),
					      working_values=>trace_target_values($arrays,$target)
					     });
					    } else {
					     $luma_anchor_working=0 if(ref($bad_luma_probe) eq "HASH");
					    }
				    my $bad_headroom_105_family=record_headroom_105_bad_adjustment_family(
				     \%tried_values,$target,$adjustments,
				     $before_lum_pct_for_adjustment,$lum_pct,
				     $before_score_for_adjustment,$candidate_score_after,
				     $read_step,$before_de_for_adjustment,$de
				    );
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
				     bad_luma_probe=>$bad_luma_probe,
				     bad_hdr20_body_family=>$bad_hdr20_body_family,
				     bad_headroom_105_family=>$bad_headroom_105_family,
					     $pair_side_trace_fields->(),
					     candidate_values=>trace_target_values($arrays,$target),
					     best_values=>trace_target_values($best_arrays,$target)
					    });
					    if($headroom_105_main_polish_refine) {
					     my $reject_reason=(defined($candidate_score_after) && defined($best_score) && $candidate_score_after + 0.0001 >= $best_score) ? "score_not_improved" : "sanity_gate";
					     trace_109($read_step,"headroom_105_main_polish_refine_reject",{
					      label=>$label,
					      iteration=>$iter+0,
					      reason=>$reject_reason,
					      before_delta_e=>defined($before_de_for_adjustment)?$before_de_for_adjustment+0:undef,
					      before_luminance_error_pct=>defined($before_lum_pct_for_adjustment)?$before_lum_pct_for_adjustment+0:undef,
					      before_score=>defined($before_score_for_adjustment)?$before_score_for_adjustment+0:undef,
					      best_delta_e=>defined($best_de)?$best_de+0:undef,
					      best_luminance_error_pct=>defined($best_lum_pct)?$best_lum_pct+0:undef,
					      best_score=>defined($best_score)?$best_score+0:undef,
					      candidate_delta_e=>defined($de)?$de+0:undef,
					      candidate_luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef,
					      candidate_score=>defined($candidate_score_after)?$candidate_score_after+0:undef,
					      adjustments=>trace_adjustments_summary($adjustments),
					      candidate_values=>trace_target_values($arrays,$target),
					      best_values=>trace_target_values($best_arrays,$target)
					     });
					    }
					    my $near_y_cleanup_branch=headroom_105_near_y_cleanup_branch(\%tried_values);
					    my $near_y_cleanup_rgb_failed=(ref($near_y_cleanup_branch) eq "HASH" && $near_y_cleanup_branch->{"active"} && headroom_105_rgb_cleanup_adjustment($adjustments)) ? 1 : 0;
					    my $paired_luma_kept=$try_high_end_paired_luma_probe->($adjustments,$candidate_score,$candidate_chroma,$best_chroma,\%tried_values,"iteration",$iter);
					    if($near_y_cleanup_rgb_failed) {
					     my $branch=headroom_105_near_y_cleanup_branch(\%tried_values);
					     $branch->{"attempts"}=($branch->{"attempts"}||0)+1 if(ref($branch) eq "HASH");
					     my $attempts=(ref($branch) eq "HASH") ? ($branch->{"attempts"}||0) : 1;
					     my $max_attempts=(ref($branch) eq "HASH" && defined($branch->{"max_attempts"})) ? ($branch->{"max_attempts"}+0) : 2;
					     trace_109($read_step,"headroom_105_near_y_cleanup_rejected",{
					      label=>$label,
					      iteration=>$iter+0,
					      attempts=>$attempts+0,
					      max_attempts=>$max_attempts+0,
					      candidate_delta_e=>defined($de)?$de+0:undef,
					      candidate_luminance_error_pct=>defined($lum_pct)?$lum_pct+0:undef,
					      candidate_score=>$candidate_score+0,
					      best_delta_e=>defined($best_de)?$best_de+0:undef,
					      best_luminance_error_pct=>defined($best_lum_pct)?$best_lum_pct+0:undef,
					      best_score=>$best_score+0,
					      adjustments=>trace_adjustments_summary($adjustments),
					      candidate_values=>trace_target_values($arrays,$target)
					     });
					     if($attempts >= $max_attempts) {
					      suppress_headroom_105_family(\%tried_values,$read_step,$target,"headroom_105_luma_priority","near_y_cleanup_exhausted",$before_lum_pct_for_adjustment,$lum_pct,$before_score_for_adjustment,$candidate_score_after);
					      suppress_headroom_105_family(\%tried_values,$read_step,$target,"headroom_105_all_down_luma","near_y_cleanup_exhausted",$before_lum_pct_for_adjustment,$lum_pct,$before_score_for_adjustment,$candidate_score_after);
					      suppress_headroom_105_family(\%tried_values,$read_step,$target,"headroom_105_floor_luma_coupled","near_y_cleanup_exhausted",$before_lum_pct_for_adjustment,$lum_pct,$before_score_for_adjustment,$candidate_score_after);
					      delete($tried_values{"__headroom_105_near_y_cleanup"});
					      $restore_best_branch->("105 near-Y RGB cleanup exhausted; keeping best $label result");
					      last;
					     }
					     $restore_headroom_105_near_y_cleanup_branch->("Retrying 105 near-Y RGB cleanup from luma branch");
					     $stalls=0;
					     next;
					    } elsif($paired_luma_kept) {
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
							     $hdr20_body_vector_next_adjustments=undef;
							     exhaust_adjustment_next_values(\%tried_values,$adjustments,$de)
						      if(lg_autocal_26_full_ddc_spine_enabled($config) || $seeded_move_damping || autocal_step_is_hdr20_body($read_step));
						     $restore_best_branch->("Backtracking to best $label result after rejected adjustment");
						    }
						    if(
						     $paired_white_step &&
						     $stalls >= legal_white_pair_precision_stall_limit($best_de,$best_pair_de,$target_delta) &&
						     defined($pair_best_reject_reason) &&
						     $pair_best_reject_reason =~ /^(?:paired_score_not_improved|same_ire_)/ &&
						     !$pair_target_reached_now->()
						    ) {
						     trace_109($read_step,"legal_white_pair_score_stalled",{
						      label=>$label,
						      iteration=>$iter+0,
						      stalls=>$stalls+0,
						      reason=>$pair_best_reject_reason,
						      best_delta_e=>defined($best_de)?$best_de+0:undef,
						      best_luminance_error_pct=>defined($best_lum_pct)?$best_lum_pct+0:undef,
						      paired_delta_e=>defined($best_pair_de)?$best_pair_de+0:undef,
						      paired_luminance_error_pct=>defined($best_pair_lum_pct)?$best_pair_lum_pct+0:undef,
						      best_score=>$best_score+0,
						      best_values=>trace_target_values($best_arrays,$target)
						     });
						     $legal_white_pair_score_stalled=1;
						     last;
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
			  if(!cancelled() && !$legal_white_pair_score_stalled && autocal_step_allows_final_fine_tune($read_step,$best_de,$target_delta) && !low_shadow_good_enough($read_step,$best_de,$best_lum_pct,$target_delta) && ref($best_arrays) eq "HASH" && ref($best_reading) eq "HASH" && !$pair_target_reached_now->() && !$paired_white_close_enough) {
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
			    my $before_de_for_polish=$de;
			    my $before_lum_pct_for_polish=$lum_pct;
			    my $before_score_for_polish=$paired_white_step ? $pair_score_now->() : guarded_autocal_result_score($de,$lum_pct,$read_step,$reading,$white_guard_y);
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
					    my $headroom_105_response_update=record_headroom_105_response(
					     \%polish_tried,$target,$read_step,$adjustments,
					     $before_polish,$reading,
					     $before_lum_pct_for_polish,$lum_pct,
					     $before_de_for_polish,$de,
					     $before_score_for_polish,$candidate_score
					    );
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
						     headroom_105_response_update=>$headroom_105_response_update,
						     $pair_side_trace_fields->(),
					     target_values=>trace_target_values($arrays,$target)
					    });
			    my ($chroma_keep,$candidate_chroma,$best_chroma)=$candidate_chroma_keep->();
			    my $delta_keep=$candidate_delta_keep->();
				    my $not_worse_measurement=autocal_measurement_not_worse_than_best($de,$lum_pct,$best_de,$best_lum_pct);
					    my $best_update_reason=$paired_white_step ? $pair_best_update_reason->($candidate_score) : undef;
					    my $headroom_105_score_keep=0;
					    my $headroom_105_luma_blocking_after=(!$paired_white_step && defined($lum_pct))
					     ? headroom_105_luma_blocking_active($read_step,$arrays,$target,\%polish_tried,$lum_pct/100)
					     : 0;
					    if(
					     !$paired_white_step &&
					     headroom_105_post_seed_body_refinement($read_step,$arrays,$target,\%polish_tried) &&
					     defined($candidate_score) && defined($best_score) &&
					     defined($lum_pct) && defined($best_lum_pct) &&
					     abs($lum_pct) + 0.05 < abs($best_lum_pct) &&
					     $candidate_score + 0.0001 < $best_score &&
					     (!defined($de) || !defined($best_de) || ($best_de > 1.25) || ($de <= $best_de+0.020))
					    ) {
					     $headroom_105_score_keep=1;
					     $best_update_reason="headroom_105_y_score_keep";
					    }
					    my $keep_candidate=$paired_white_step
					     ? defined($best_update_reason)
					     : (defined($de) && ($headroom_105_luma_blocking_after
					      ? $headroom_105_score_keep
					      : (($not_worse_measurement && ($candidate_score + 0.0001 < $best_score || $chroma_keep || $delta_keep)) || $headroom_105_score_keep)));
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
				      $pair_side_trace_fields->(),
				      best_values=>trace_target_values($best_arrays,$target)
				     });
				    } else {
				     $polish_stalls++;
				     my $luma_anchor_working=headroom_luminance_anchor_working_state($read_step,$lum_pct,$best_lum_pct,$de,$best_de);
				     if(autocal_step_is_fast_headroom($read_step) && !autocal_step_is_peak_headroom($read_step)) {
				      $luma_anchor_working=headroom_105_luminance_progress_working_state($read_step,$arrays,$target,\%polish_tried,$lum_pct,$best_lum_pct,$de,$best_de,$candidate_score,$best_score);
				     }
				     my $bad_luma_probe=record_bad_luma_probe_family(
				      \%polish_tried,$target,$adjustments,
				      $before_de_for_polish,$de,
				      $before_lum_pct_for_polish,$lum_pct,
				      $before_score_for_polish,$candidate_score,
				      $read_step,"fine_tune",$state
				     );
				     $luma_anchor_working=0 if(ref($bad_luma_probe) eq "HASH");
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
					      luma_anchor_working=>$luma_anchor_working?JSON::PP::true:JSON::PP::false,
					      bad_luma_probe=>$bad_luma_probe,
					      $pair_side_trace_fields->()
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
						   if(autocal_step_ignores_luminance_error($read_step)) {
						    $target_step_y=effective_target_luminance_for_autocal_reading($white_y,$read_step,$best_reading,$target_gamma,$signal_mode,$config,$state);
						    annotate_reading_target($best_reading,$white_y,$target_step_y,$target_x,$target_y);
						    $best_lum_pct=luminance_error_percent($best_reading,$target_step_y);
						    set_state_target_step_luminance($state,$target_step_y);
						   } else {
					    $best_lum_pct=undef;
					    set_state_target_step_luminance($state,undef);
						   }
					  } elsif(autocal_step_is_peak_headroom($read_step)) {
				   apply_peak_headroom_reference($state,$read_step,$best_reading,\$white_y,$target_gamma,$signal_mode,$target_x,$target_y);
				   $target_step_y=effective_target_luminance_for_autocal_reading($white_y,$read_step,$best_reading,$target_gamma,$signal_mode);
				   $best_lum_pct=luminance_error_percent($best_reading,$target_step_y);
				   set_state_target_step_luminance($state,$target_step_y);
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
					   $target_step_y,$best_arrays,$target,"main_final_step_result",$final_reached
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
				   my $verify_target_y=effective_target_luminance_for_autocal_reading($white_y,$verify_step,$verify_reading,$target_gamma,$signal_mode,$config,$state);
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
						   my $shadow_detail_adjusted=apply_lg_autocal_26_oled_shadow_detail_compensation(
						    $config,$state,$arrays,\@ordered,\@calibrated_ddc_slots
						   );
						   if($shadow_detail_adjusted) {
						    $state->{"message"}="Applied OLED shadow detail pre-commit compensation";
						    write_state($state);
						   }
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
