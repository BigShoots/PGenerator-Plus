#!/usr/bin/perl
# Dolby Vision panel-profile measurement worker: measures black, white, red,
# green, and blue at peak code while a genuine Dolby Vision signal is active,
# then hands the result to /api/lg/dv-profile/upload. No 3D LUT / matrix
# solve happens here -- Dolby Vision AutoCal only ever writes the greyscale
# 1D DPG (via the existing HDR20 path) plus this one profile upload.
use strict;
use warnings;
use Errno qw(EINTR);
use IO::Select ();
use IO::Socket::INET ();
use JSON::PP;
use Time::HiRes ();

my ($config_file,$state_file,$stop_file)=@ARGV;
die "Usage: $0 <config.json> <state.json> <stop-file>\n" if(!defined($config_file) || !defined($state_file) || !defined($stop_file));

my $json=JSON::PP->new->canonical->allow_nonref;
my $api_host="127.0.0.1";
my $api_port=80;

sub read_file {
 my ($path)=@_;
 open(my $fh,'<',$path) or return "";
 local $/; my $t=<$fh>; close($fh);
 return defined($t) ? $t : "";
}

sub write_state {
 my (%state)=@_;
 open(my $fh,'>',$state_file) or return;
 print $fh $json->encode(\%state);
 close($fh);
 chmod(0666,$state_file);
}

sub cancelled { return -e $stop_file; }

sub api_json {
 my ($method,$path,$payload,$timeout)=@_;
 $method||="GET";
 $timeout||=30;
 $timeout=1 if($timeout < 1);
 my $body=defined($payload) ? $json->encode($payload) : "";
 my $deadline=time()+$timeout;
 my $socket=IO::Socket::INET->new(
  PeerHost=>$api_host,
  PeerPort=>$api_port,
  Proto=>"tcp",
  Timeout=>$timeout,
 );
 return {status=>"error",message=>"Web UI API is unavailable"} if(!$socket);
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
  if(cancelled()) {
   close($socket);
   return {status=>"error",message=>"cancelled"};
  }
  my $remaining=$deadline-time();
  if($remaining <= 0) {
   close($socket);
   return {status=>"error",message=>"Web UI API timed out during $path"};
  }
  my @ready=$selector->can_read($remaining > 1 ? 1 : $remaining);
  next if(!@ready);
  my $len=sysread($socket,$buf,8192);
  if(!defined($len)) {
   next if($! == EINTR);
   close($socket);
   return {status=>"error",message=>"Web UI API read failed during $path"};
  }
  last if($len == 0);
  $raw.=$buf;
 }
 close($socket);
 my (undef,$content)=split(/\r?\n\r?\n/,$raw,2);
 $content="" if(!defined($content));
 my $result=eval { $json->decode($content) } || {};
 return $result if(ref($result) eq "HASH" && %{$result});
 return {status=>"error",message=>"Invalid Web UI API response"};
}

my $config=eval { $json->decode(read_file($config_file)) } || {};
die "Empty/invalid config\n" if(ref($config) ne "HASH");

write_state(status=>"running",message=>"Starting Dolby Vision profile measurement",steps=>[]);

# Standard DV uses legal-range 12-bit source RGB inside the packed RGB
# 8-bit Full transport. Measure the profile with the same exact source
# domain as the greyscale and colour-series paths.
my $input_max=4095;
my $black_code=256;
my $white_code=3760;
my @patches=(
 { name=>"black", r=>$black_code, g=>$black_code, b=>$black_code, kind=>"black" },
 { name=>"white", r=>$white_code, g=>$white_code, b=>$white_code, kind=>"white" },
 { name=>"red",   r=>$white_code, g=>$black_code, b=>$black_code, kind=>"red" },
 { name=>"green", r=>$black_code, g=>$white_code, b=>$black_code, kind=>"green" },
 { name=>"blue",  r=>$black_code, g=>$black_code, b=>$white_code, kind=>"blue" },
);

# --- Pattern insertion -------------------------------------------------------
# This worker previously forwarded the patch_insert* config keys to
# /api/meter/read and assumed that was enough. It is not: that endpoint does
# not consume them. Pattern insertion is driven by the WORKER in this codebase
# (see apply_pattern_insert_before_read in meter_lg_autocal.pl), so forwarding
# the keys was silently a no-op and the DV profile measured with no insertion
# at all -- on a WRGB OLED that lets ABL/pixel-charge history accumulate across
# the five patches, and the white peak it records becomes the uploaded DV
# config's Tmax. Same class of error as the missing patch_size/refresh_rate.
our $_patch_insert_counter=0;
our $_patch_insert_last_time_ts=0;

sub sanitize_ms {
 my ($raw,$fallback,$max)=@_;
 $fallback//=0; $max//=120000;
 $raw=int($raw//0);
 $raw=$fallback if($raw < 0);
 $raw=$max if($raw > $max);
 return $raw;
}

sub sanitize_count {
 my ($raw,$fallback,$max)=@_;
 $fallback//=1; $max//=999;
 $raw=int($raw//1);
 $raw=$fallback if($raw < 1);
 $raw=$max if($raw > $max);
 return $raw;
}

# Returns ($code,$input_max) for one insertion type. The webui start handler
# precomputes a mode-correct code via webui_grey_code_for_stimulus so the
# insertion flash matches the level the greyscale ladder would emit for the
# same stimulus in the active output mode. Older callers do not inject the
# pair, so their fallback is generated directly in standard-DV's legal 12-bit
# source domain rather than rounded through an 8-bit percentage first.
sub patch_insert_resolve {
 my ($config,$kind,$level)=@_;
 my $code_key="patch_insert_".$kind."_code";
 my $im_key="patch_insert_".$kind."_input_max";
 if(defined($config->{$code_key}) && $config->{$code_key} ne "") {
  my $im=int($config->{$im_key} // 255);
  $im=255 if($im <= 0);
  return (int($config->{$code_key}+0),$im);
 }
 my $pct=$level+0;
 $pct=0 if($pct < 0);
 $pct=100 if($pct > 100);
 return (int(256.0+($pct/100.0)*3504.0+0.5),4095);
}

# Grey flash -> black -> settle, before the caller measures. Unlike the
# greyscale worker there is no "restore the measurement patch" step: read_patch
# measures through /api/meter/read, which posts the measurement pattern itself.
# The 15s time-frequency cap the greyscale worker applies to its inner loops is
# deliberately NOT applied here -- this is a five-patch one-shot run, so the
# operator's own frequency setting is the right granularity, and patch-mode
# insertion (default: every patch) is what actually conditions the panel.
sub apply_pattern_insert_before_read {
 my ($config,$patch)=@_;
 return undef if(ref($config) ne "HASH" || !$config->{"patch_insert"});
 my $pattern_range=$config->{"pattern_signal_range"}||$config->{"signal_range"}||"";
 my $transport_range=$config->{"transport_signal_range"}||$config->{"signal_range"}||"";
 my $patch_enabled=$config->{"patch_insert_patch_enabled"} ? 1 : 0;
 my $patch_every=sanitize_count($config->{"patch_insert_patch_every"},1,999);
 my $patch_duration_ms=sanitize_ms($config->{"patch_insert_patch_duration_ms"},1000,30000);
 my $patch_level=($config->{"patch_insert_patch_level"}//10)+0;
 my $time_enabled=$config->{"patch_insert_time_enabled"} ? 1 : 0;
 my $time_frequency_ms=sanitize_ms($config->{"patch_insert_time_frequency_ms"},5000,120000);
 my $time_duration_ms=sanitize_ms($config->{"patch_insert_time_duration_ms"},5000,30000);
 my $time_level=($config->{"patch_insert_time_level"}//25)+0;
 my @inserts;
 my $now=int(Time::HiRes::time()*1000);
 if($time_enabled && ($_patch_insert_last_time_ts == 0 || ($now - $_patch_insert_last_time_ts) >= $time_frequency_ms)) {
  push @inserts,{ level => $time_level, duration_ms => $time_duration_ms, kind => "time" };
  $_patch_insert_last_time_ts=$now;
 }
 if($patch_enabled) {
  $_patch_insert_counter++;
  push @inserts,{ level => $patch_level, duration_ms => $patch_duration_ms, kind => "patch" }
   if(($_patch_insert_counter % $patch_every) == 0);
 }
 return undef unless(@inserts);
 my $base={
  name => "patch",
  size => 100,
  input_max => 255,
  signal_mode => "dv",
  max_luma => $config->{"max_luma"}||1000,
  # The meter session holds a pattern stop guard while a read is in progress;
  # without allow_after_stop the renderer answers {"pattern":"stop"} and the
  # insertion flash never reaches the panel.
  allow_after_stop => JSON::PP::true,
 };
 $base->{"signal_range"}=$pattern_range if($pattern_range ne "");
 $base->{"transport_signal_range"}=$transport_range if($transport_range ne "");
 for my $ins (@inserts) {
  return "cancelled" if(cancelled());
  my ($code,$input_max)=patch_insert_resolve($config,$ins->{"kind"},$ins->{"level"});
  my $flash=api_json("POST","/api/pattern",{%{$base},input_max=>$input_max,r=>(0+$code),g=>(0+$code),b=>(0+$code)},10);
  return ($flash->{"message"}||"Unable to display pattern insertion patch") if(($flash->{"status"}||"") eq "error");
  select(undef,undef,undef,$ins->{"duration_ms"}/1000.0);
  my $black=api_json("POST","/api/pattern",{%{$base},input_max=>4095,r=>256,g=>256,b=>256},10);
  return ($black->{"message"}||"Unable to display black insertion patch") if(($black->{"status"}||"") eq "error");
  select(undef,undef,undef,0.5);
 }
 # Let the panel leave the black reset before /api/meter/read posts the
 # measurement patch and immediately starts counting its own delay_ms.
 my $settle_ms=defined($config->{"patch_insert_post_settle_ms"}) ? int($config->{"patch_insert_post_settle_ms"}) : 400;
 $settle_ms=0 if($settle_ms < 0);
 $settle_ms=5000 if($settle_ms > 5000);
 select(undef,undef,undef,$settle_ms/1000.0) if($settle_ms > 0);
 return undef;
}

sub fixture_reading_for_patch {
 my ($patch,$config)=@_;
 return undef if(!$config->{"fixture_mode"});
 my $white_y=$config->{"fixture_white_y"}||500;
 my $black_y=$config->{"fixture_black_y"}||0;
 # Fixed, well-known bt709 primaries stand in for "the paired TV's actual
 # native gamut" in fixture mode -- there is no real panel to measure.
 my %xy=(
  red   => [0.64,0.33],
  green => [0.30,0.60],
  blue  => [0.15,0.06],
  white => [0.3127,0.3290],
  black => [0.3127,0.3290],
 );
 my $kind=$patch->{"kind"};
 my $y=($kind eq "white") ? $white_y : ($kind eq "black") ? $black_y : ($white_y*0.2126);
 $y=$black_y+($white_y-$black_y)*0.2126 if($kind eq "red" || $kind eq "green" || $kind eq "blue");
 return { x=>$xy{$kind}[0], y=>$xy{$kind}[1], luminance=>$y, timestamp=>time() };
}

# Measures one patch via a SINGLE /api/meter/read call -- that endpoint sets
# the pattern itself from patch_r/patch_g/patch_b (there is no separate
# /api/pattern step), exactly matching the established convention in
# meter_lg_3d_autocal.pl's read_step_once, which this mirrors. Returns
# ($reading,undef) on success, or (undef,$error) where $error is the literal
# string "cancelled" when the stop file appeared, distinct from any other
# failure message, so the caller can report a clean "stopped" state instead
# of a generic error.
sub read_patch {
 my ($patch,$config)=@_;
 my $fixture=fixture_reading_for_patch($patch,$config);
 return ($fixture,undef) if($fixture);
 return (undef,"cancelled") if(cancelled());
 my $read_delay_ms=int($config->{"delay_ms"}||1800);
 # The full greyscale workflow gives its 100% anchor a longer stabilization
 # delay. Match that operating point when this standalone five-patch pass has
 # to supply Tmax itself instead of inheriting the calibrated peak.
 if(($patch->{"kind"}||"") eq "white") {
  my $white_delay_ms=int($config->{"white_read_delay_ms"}||3000);
  $read_delay_ms=$white_delay_ms if($white_delay_ms > $read_delay_ms);
 }
 my $payload={
  display_type => $config->{"display_type"}||"lcd",
  ccss_override => $config->{"ccss_override"}||"",
  patch_r => int($patch->{"r"}||0),
  patch_g => int($patch->{"g"}||0),
  patch_b => int($patch->{"b"}||0),
  name => $patch->{"name"},
  input_max => $input_max,
  # Do not make the WebUI infer this from 12-bit wire codes. In particular,
  # legal black is code 256 rather than zero in standard Dolby Vision.
  ire => (($patch->{"kind"}||"") eq "white" ? 100 : 0),
  stimulus => (($patch->{"kind"}||"") eq "white" ? 100 : 0),
  delay_ms => $read_delay_ms,
  signal_range => $config->{"pattern_signal_range"}||$config->{"signal_range"}||"1",
  transport_signal_range => $config->{"transport_signal_range"}||$config->{"signal_range"}||"1",
  signal_mode => "dv",
 };
 # Measure with the SAME patch geometry the greyscale pass used, or the
 # profile characterises a different operating point than the calibration it
 # belongs to. This worker previously sent no patch_size and no pattern
 # insertion, so white was read full-field: on a WRGB OLED that engages ABL
 # and reads far below the windowed peak. Hardware: the greyscale measured
 # 100% white at 729-730 cd/m2 with patch_size 10 + insertion, while this
 # worker measured 531.47 -- and that low value was then written into the
 # uploaded DV config as Tmax, telling the TV the panel is ~27% dimmer than it
 # is. Forward whatever the caller stamped (patch size, refresh rate and the
 # whole patch_insert* group) instead of silently taking the endpoint default.
 $payload->{"patch_size"}=int($config->{"patch_size"}) if(defined $config->{"patch_size"} && $config->{"patch_size"} ne "");
 $payload->{"refresh_rate"}=$config->{"refresh_rate"} if(defined $config->{"refresh_rate"} && $config->{"refresh_rate"} ne "");
 # Pattern insertion is NOT forwarded to /api/meter/read -- that endpoint does
 # not implement it. apply_pattern_insert_before_read (called by the patch loop)
 # drives it here, the same way the greyscale worker does.
 my $start=api_json("POST","/api/meter/read",$payload,55);
 return (undef,"cancelled") if(cancelled());
 return (undef,$start->{"message"}||"Unable to start meter read") if(($start->{"status"}||"") eq "error");
 my $deadline=time()+60;
 while(time() < $deadline) {
  return (undef,"cancelled") if(cancelled());
  my $result=api_json("GET","/api/meter/read/result",undef,10);
  if((($result->{"status"}||"") eq "ok") && ref($result->{"readings"}) eq "ARRAY" && @{$result->{"readings"}}) {
   my $reading=$result->{"readings"}[0];
   # meter_session.sh owns the null-read detection and the re-measure (it is
   # the only layer that knows the requested patch AND can trigger a genuinely
   # new spotread measurement). It stamps null_read when an all-zero reading
   # survived every re-read of a patch that drives light. This worker measures
   # white, black and the three primaries: a zero on anything but black would
   # be written into the uploaded profile as the panel's peak or a primary, so
   # stop rather than record it.
   if(ref($reading) eq "HASH" && $reading->{"null_read"} && ($patch->{"kind"}||"") ne "black") {
    my $label=$patch->{"kind"}||$patch->{"name"}||"patch";
    my $retries=($reading->{"null_read_retries"}||0)+0;
    return (undef,"Meter returned an unusable all-zero reading for the $label patch that survived $retries re-measures; check the meter is aimed at the patch, awake, and still connected");
   }
   return ($reading,undef);
  }
  return (undef,$result->{"message"}||"Meter read failed") if(($result->{"status"}||"") eq "error");
  select(undef,undef,undef,0.35);
 }
 return (undef,"Meter read timed out");
}

my @steps;
my %by_kind;
for my $patch (@patches) {
 if(cancelled()) {
  write_state(status=>"cancelled",message=>"Dolby Vision profile measurement cancelled",steps=>\@steps);
  exit(1);
 }
 if(!$config->{"fixture_mode"}) {
  my $ins_err=apply_pattern_insert_before_read($config,$patch);
  if(defined($ins_err)) {
   if($ins_err eq "cancelled") {
    write_state(status=>"cancelled",message=>"Dolby Vision profile measurement cancelled",steps=>\@steps);
    exit(1);
   }
   write_state(status=>"error",message=>$ins_err,steps=>\@steps);
   exit(1);
  }
 }
 my ($reading,$err)=read_patch($patch,$config);
 if(!$reading) {
  if(defined($err) && $err eq "cancelled") {
   write_state(status=>"cancelled",message=>"Dolby Vision profile measurement cancelled",steps=>\@steps);
   exit(1);
  }
  write_state(status=>"error",message=>($err||"Meter read failed for patch \"".$patch->{"name"}."\""),steps=>\@steps);
  exit(1);
 }
 my $step={ name=>$patch->{"name"}, kind=>$patch->{"kind"}, x=>$reading->{"x"}, y=>$reading->{"y"}, luminance=>$reading->{"luminance"} };
 push(@steps,$step);
 $by_kind{$patch->{"kind"}}=$step;
 write_state(status=>"running",message=>"Measured ".$patch->{"name"},steps=>\@steps);
}

my $measured_white_luminance=$by_kind{"white"}{"luminance"}+0;
my $calibrated_peak_luminance=0+($config->{"calibrated_peak_luminance"}//0);
my %measurements=(
 # Use the fresh white measured with the profile primaries. The calibrated
 # greyscale peak is retained only for diagnostics so Tmax and the panel
 # primaries always describe the same short measurement pass.
 white_luminance => $measured_white_luminance,
 measured_white_luminance => $measured_white_luminance,
 calibrated_peak_luminance => $calibrated_peak_luminance,
 white_luminance_source => "profile-white-read",
 black_luminance => $by_kind{"black"}{"luminance"},
 red_x => $by_kind{"red"}{"x"}, red_y => $by_kind{"red"}{"y"},
 green_x => $by_kind{"green"}{"x"}, green_y => $by_kind{"green"}{"y"},
 blue_x => $by_kind{"blue"}{"x"}, blue_y => $by_kind{"blue"}{"y"},
);

if($config->{"upload"} && !$config->{"fixture_mode"}) {
 my $upload=api_json("POST","/api/lg/dv-profile/upload",{
  picture_mode => $config->{"picture_mode"}||"",
  measurements => \%measurements,
  keep_calibration_mode => $config->{"keep_calibration_mode"}?1:0,
  calibration_mode_active => $config->{"calibration_mode_active"}?1:0,
 },60);
 if(($upload->{"status"}||"") ne "ok") {
  write_state(status=>"error",message=>$upload->{"message"}||"Dolby Vision profile upload failed",steps=>\@steps,measurements=>\%measurements);
  exit(1);
 }
 write_state(status=>"complete",message=>"Dolby Vision profile measured and uploaded",steps=>\@steps,measurements=>\%measurements,upload=>$upload);
 exit(0);
}

write_state(status=>"complete",message=>"Dolby Vision profile measured",steps=>\@steps,measurements=>\%measurements);
exit(0);
