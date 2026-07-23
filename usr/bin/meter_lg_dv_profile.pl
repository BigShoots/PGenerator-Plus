#!/usr/bin/perl
# Dolby Vision panel-profile measurement worker: measures black, white, red,
# green, and blue at peak code while a genuine Dolby Vision signal is active,
# then hands the result to /api/lg/dv-profile/upload. No 3D LUT / matrix
# solve happens here -- Dolby Vision AutoCal only ever writes the greyscale
# 1D DPG (via the existing HDR20 path) plus this one profile upload.
use strict;
use warnings;
use JSON::PP;
use LWP::UserAgent;
use HTTP::Request;

my ($config_file,$state_file,$stop_file)=@ARGV;
die "Usage: $0 <config.json> <state.json> <stop-file>\n" if(!defined($config_file) || !defined($state_file) || !defined($stop_file));

my $json=JSON::PP->new->canonical->allow_nonref;
my $ua=LWP::UserAgent->new(timeout=>30);

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
 my $req=HTTP::Request->new($method=>"http://127.0.0.1$path");
 if(defined($payload)) {
  $req->header('Content-Type'=>'application/json');
  $req->content($json->encode($payload));
 }
 $ua->timeout($timeout||30);
 my $resp=$ua->request($req);
 my $body=eval { $json->decode($resp->decoded_content||"{}") } || {};
 return $body;
}

my $config=eval { $json->decode(read_file($config_file)) } || {};
die "Empty/invalid config\n" if(ref($config) ne "HASH");

write_state(status=>"running",message=>"Starting Dolby Vision profile measurement",steps=>[]);

# Patch list: black at 0%, white/red/green/blue at peak (100%) code. Uses the
# same 0..input_max code convention as the greyscale/3D-LUT workers so the
# renderer's already-implemented DV signal-generation path
# receives ordinary RGB triplets.
my $input_max=int($config->{"input_max"}||1023);
my @patches=(
 { name=>"black", r=>0,         g=>0,         b=>0,         kind=>"black" },
 { name=>"white", r=>$input_max, g=>$input_max, b=>$input_max, kind=>"white" },
 { name=>"red",   r=>$input_max, g=>0,          b=>0,          kind=>"red" },
 { name=>"green", r=>0,          g=>$input_max, b=>0,          kind=>"green" },
 { name=>"blue",  r=>0,          g=>0,          b=>$input_max, kind=>"blue" },
);

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
 my $payload={
  display_type => $config->{"display_type"}||"lcd",
  ccss_override => $config->{"ccss_override"}||"",
  patch_r => int($patch->{"r"}||0),
  patch_g => int($patch->{"g"}||0),
  patch_b => int($patch->{"b"}||0),
  name => $patch->{"name"},
  input_max => $input_max,
  delay_ms => int($config->{"delay_ms"}||1800),
  signal_range => $config->{"pattern_signal_range"}||$config->{"signal_range"}||"1",
  transport_signal_range => $config->{"transport_signal_range"}||$config->{"signal_range"}||"1",
  signal_mode => "dv",
 };
 my $start=api_json("POST","/api/meter/read",$payload,55);
 return (undef,"cancelled") if(cancelled());
 return (undef,$start->{"message"}||"Unable to start meter read") if(($start->{"status"}||"") eq "error");
 my $deadline=time()+60;
 while(time() < $deadline) {
  return (undef,"cancelled") if(cancelled());
  my $result=api_json("GET","/api/meter/read/result",undef,10);
  if((($result->{"status"}||"") eq "ok") && ref($result->{"readings"}) eq "ARRAY" && @{$result->{"readings"}}) {
   return ($result->{"readings"}[0],undef);
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

my %measurements=(
 white_luminance => $by_kind{"white"}{"luminance"},
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
