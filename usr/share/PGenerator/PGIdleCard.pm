package PGIdleCard;

# Idle information card: a dim, moving description of the HDMI signal shown
# while nothing owns the display. Everything here is pure (text in, data out)
# so the parsing, the requested/sent comparison and the layout can be tested
# without an appliance; webui.pm supplies the files, the conf and the writer.

use strict;
use warnings;
use Exporter qw(import);
use File::Basename ();
use lib File::Basename::dirname(__FILE__);
use PGMath qw(pq_encode_normalized);

our @EXPORT_OK=qw(
 parse_modetest_connectors
 parse_debugfs_active_mode
 parse_hdmi_packet_config
 decode_hdr_output_metadata
 requested_signal
 sent_signal
 card_model
 model_signature
 text_levels
 hop_positions
 convert_arguments
 png_dimensions
 sequence_pattern
 meter_name_for_usb_id
 picture_mode_label
);

# Output luminance for the two text tones. Values are 25 nits so the card can
# be read across a lit room; labels sit lower so the eye lands on the sent
# signal first. SDR and HLG are relative formats: both are placed against a
# 100-nit reference white (HLG through a 1000-nit display's system gamma).
our $VALUE_NITS=25;
our $LABEL_NITS=12;
our $HOP_MS=20000;
our $HOP_COUNT=120;

# Dolby Vision carries the PNG through the RGB tunnel, so its codes come from
# i1d3 readings on the reference G3 (21 September 2026, standard transport,
# 10% window): 52 -> 24.3 nits, 42 -> 11.6 nits, 16 -> 0.000 nits. LLDV
# could not be measured (that build sent a flat green field even for stop),
# so it shares the standard codes until it can be.
our %DV_LEVELS=(
 standard => {value=>52,label=>42,black=>16},
 lldv     => {value=>52,label=>42,black=>16},
);

# USB ids of the meters spotread_wrapper.sh recognises, named as a user would
# see them on the instrument.
my %KNOWN_METERS=(
 "0765:5020" => "i1Display Pro Plus",
 "0765:5001" => "HueyL",
 "0765:6008" => "i1Studio",
 "0765:6009" => "i1Pro 3",
 "0971:2000" => "i1Pro",
 "0971:2007" => "ColorMunki",
 "085c:0500" => "Spyder 5",
 "085c:0a00" => "SpyderX",
 "04db:0100" => "Spyder",
 "0670:0001" => "Chroma 5",
);

# webOS picture-mode keys as the TV reports them, mapped to the menu names.
my %PICTURE_MODES=(
 filmMaker => "Filmmaker", expert1 => "Expert (bright room)", expert2 => "Expert (dark room)",
 cinema => "Cinema", cinemaBright => "Cinema home", standard => "Standard", vivid => "Vivid",
 eco => "Eco", game => "Game optimiser", sports => "Sports", normal => "Standard",
 hdrFilmMaker => "Filmmaker", hdrCinema => "Cinema", hdrCinemaBright => "Cinema home",
 hdrStandard => "Standard", hdrVivid => "Vivid", hdrGame => "Game optimiser",
 dolbyHdrCinema => "Cinema", dolbyHdrCinemaBright => "Cinema home", dolbyHdrStandard => "Standard",
 dolbyHdrVivid => "Vivid", dolbyHdrGame => "Game optimiser", dolbyHdrFilmMaker => "Filmmaker",
 dolbyHdrDarkAmazon => "Cinema",
);

# DRM "Colorimetry" enum values, shared by PGenerator.conf and the connector.
my %COLORIMETRY=(
 0 => "Default", 1 => "BT.601", 2 => "BT.709", 3 => "xvYCC 601", 4 => "xvYCC 709",
 5 => "sYCC 601", 6 => "opYCC 601", 7 => "opRGB", 8 => "BT.2020 constant",
 9 => "BT.2020", 10 => "BT.2020", 11 => "DCI-P3 D65", 12 => "DCI-P3 theatre",
);

my %PRIMARY_SETS=(
 "BT.709"  => [[0.640,0.330],[0.300,0.600],[0.150,0.060],[0.3127,0.3290]],
 "DCI-P3 D65" => [[0.680,0.320],[0.265,0.690],[0.150,0.060],[0.3127,0.3290]],
 "DCI-P3 DCI" => [[0.680,0.320],[0.265,0.690],[0.150,0.060],[0.3140,0.3510]],
 "BT.2020" => [[0.708,0.292],[0.170,0.797],[0.131,0.046],[0.3127,0.3290]],
);

sub _trim { my $v=shift; $v="" if(!defined($v)); $v=~s/^\s+|\s+$//g; return $v; }

# `modetest -c` prints one block per connector: a tab-separated header line,
# the mode list, then "props:" with name/flags/enums/value lines. Blob values
# are hex lines under "value:". Returns {NAME => {status, props => {...}}}.
sub parse_modetest_connectors {
 my ($text)=@_;
 my %out;
 my ($current,$prop,$in_blob);
 foreach my $line (split(/\n/,defined($text)?$text:"")) {
  if($line=~/^(\d+)\t\d*\t(connected|disconnected|unknown)\t(\S+)/) {
   $current=$3;
   $out{$current}={status=>$2,props=>{}};
   ($prop,$in_blob)=(undef,0);
   next;
  }
  next if(!defined($current));
  if($line=~/^\t(\d+) ([^:]+):\s*$/) {
   $prop=$2;
   $out{$current}{props}{$prop}={enums=>{},value=>undef,blob=>""};
   $in_blob=0;
   next;
  }
  next if(!defined($prop));
  my $entry=$out{$current}{props}{$prop};
  if($line=~/^\t\tenums:\s*(.*)$/) {
   my $enums=$1;
   while($enums=~/(\S+?)=(\d+)(?:\s|$)/g) { $entry->{enums}{$2}=$1; }
   next;
  }
  if($line=~/^\t\tvalues:\s*(.*)$/) { $entry->{values}=$1; next; }
  if($line=~/^\t\tvalue:\s*(.*)$/) {
   my $value=_trim($1);
   $entry->{value_read}=1;
   $entry->{value}=$value if($value ne "");
   $in_blob=($value eq "") ? 1 : 0;
   next;
  }
  if($in_blob && $line=~/^\t\t\t([0-9a-fA-F]+)\s*$/) { $entry->{blob}.=lc($1); next; }
  $in_blob=0 if($line!~/^\t\t\t/);
 }
 return \%out;
}

# debugfs dri/N/state lists every CRTC; the enabled one carries the live mode:
#   mode: "1920x1080": 24 74250 1920 2558 2602 2750 1080 1084 1089 1125 0x40 0x5
# (vrefresh, clock kHz, h timings, v timings, type, flags).
sub parse_debugfs_active_mode {
 my ($text)=@_;
 my $enabled=0;
 foreach my $line (split(/\n/,defined($text)?$text:"")) {
  if($line=~/^crtc\[/) { $enabled=0; next; }
  $enabled=1 if($line=~/^\s+enable=1\s*$/);
  next if(!$enabled);
  if($line=~/^\s+mode:\s+"[^"]*":\s+(\d+)\s+(\d+)\s+(\d+)\s+\d+\s+\d+\s+(\d+)\s+(\d+)\s+\d+\s+\d+\s+(\d+)\s+\S+\s+(0x[0-9a-fA-F]+)/) {
   my ($vrefresh,$clock,$hdisplay,$htotal,$vdisplay,$vtotal,$flags)=($1,$2,$3,$4,$5,$6,hex($7));
   next if(!$clock || !$htotal || !$vtotal);
   my $interlaced=($flags & 0x10) ? 1 : 0;
   my $refresh=$clock*1000/($htotal*$vtotal);
   $refresh*=2 if($interlaced);
   return {w=>$hdisplay+0,h=>$vdisplay+0,clock_khz=>$clock+0,refresh=>$refresh,interlaced=>$interlaced};
  }
 }
 return undef;
}

# vc4 keeps one RAM packet slot per infoframe type (type - 0x80): bit 1 is the
# vendor-specific frame, 2 AVI, 3 SPD, 4 audio and 7 the HDR (DRM) frame.
sub parse_hdmi_packet_config {
 my ($text)=@_;
 return undef if(!defined($text) || $text!~/HDMI_RAM_PACKET_CONFIG\s*=\s*0x([0-9a-fA-F]+)/);
 my $bits=hex($1);
 return {raw=>$bits,vendor=>($bits>>1)&1,avi=>($bits>>2)&1,hdr=>($bits>>7)&1};
}

# struct hdr_output_metadata: u32 type, then hdr_metadata_infoframe {u8 eotf,
# u8 type, u16 primaries[3][2], u16 white[2], u16 max_dml, u16 min_dml,
# u16 max_cll, u16 max_fall}, little-endian, chromaticity in 0.00002 steps.
sub decode_hdr_output_metadata {
 my ($hex)=@_;
 $hex=lc(defined($hex)?$hex:"");
 $hex=~s/[^0-9a-f]//g;
 return undef if(length($hex) < 60);
 my $bytes=pack("H*",$hex);
 my ($type,$eotf,undef,@u16)=unpack("V C C v12",$bytes);
 my @xy=map { $_*0.00002 } @u16[0..7];
 return {
  eotf=>$eotf,
  primaries=>[[@xy[0,1]],[@xy[2,3]],[@xy[4,5]]],
  white=>[@xy[6,7]],
  max_luminance=>$u16[8],
  min_luminance=>$u16[9]*0.0001,
  max_cll=>$u16[10],
  max_fall=>$u16[11],
 };
}

sub _primaries_name {
 my ($primaries,$white)=@_;
 return "" if(ref($primaries) ne "ARRAY" || ref($white) ne "ARRAY");
 return "None" if(!grep { $_->[0] || $_->[1] } @$primaries);
 NAME: foreach my $name (sort keys %PRIMARY_SETS) {
  my $set=$PRIMARY_SETS{$name};
  # Senders disagree on the order of the three primaries; match as a set.
  foreach my $reference (@{$set}[0..2]) {
   next NAME if(!grep { abs($_->[0]-$reference->[0]) < 0.005 && abs($_->[1]-$reference->[1]) < 0.005 } @$primaries);
  }
  next if(abs($white->[0]-$set->[3][0]) > 0.005 || abs($white->[1]-$set->[3][1]) > 0.005);
  return $name;
 }
 return "Custom";
}

# 23.976, 24 and 59.94 read as broadcast engineers write them: three decimals
# at most, trailing zeros dropped.
sub _refresh_text {
 my $hz=shift;
 return "" if(!defined($hz) || $hz <= 0);
 my $text=sprintf("%.3f",$hz);
 $text=~s/0+$//;
 $text=~s/\.$//;
 return "$text Hz";
}

sub _resolution_text {
 my ($w,$h,$hz,$interlaced)=@_;
 return "" if(!$w || !$h);
 my $text="$w \x{00D7} $h".($interlaced ? "i" : "");
 my $refresh=_refresh_text($hz);
 return $refresh eq "" ? $text : "$text at $refresh";
}

sub _nits_text {
 my $value=shift;
 return "" if(!defined($value) || $value eq "");
 $value+=0;
 return sprintf("%d",$value) if($value >= 1 && abs($value-int($value+0.5)) < 0.001);
 my $text=sprintf("%.4f",$value);
 $text=~s/0+$//;
 $text=~s/\.$//;
 return $text;
}

sub _mode_label {
 my ($mode,$transport)=@_;
 return "SDR" if($mode eq "sdr");
 return "HDR10" if($mode eq "hdr10");
 return "HLG" if($mode eq "hlg");
 return (($transport||"") eq "lldv") ? "Dolby Vision LL" : "Dolby Vision" if($mode eq "dv");
 return "";
}

# DRM output-format index, the same numbering as PGenerator.conf color_format.
sub _format_label {
 my $index=shift;
 return "" if(!defined($index) || $index eq "");
 return ("RGB","YCbCr 4:4:4","YCbCr 4:2:2","YCbCr 4:2:0")[$index] || "";
}

sub _transfer_label {
 my $eotf=shift;
 return "" if(!defined($eotf));
 return ("SDR gamma","HDR gamma","PQ (ST 2084)","HLG")[$eotf] || "";
}

# What the Output settings ask for, from PGenerator.conf plus the mode line the
# daemon resolved from mode_idx ("... 1920x1080 @ 24.00Hz").
sub requested_signal {
 my ($conf,$hdmi_info)=@_;
 $conf={} if(ref($conf) ne "HASH");
 my $mode=lc($conf->{signal_mode}||"");
 if($mode!~/^(?:sdr|hdr10|hlg|dv)$/) {
  $mode=(int($conf->{dv_status}||0)==1 || int($conf->{is_ll_dovi}||0)==1 || int($conf->{is_std_dovi}||0)==1) ? "dv"
   : int($conf->{is_hdr}||0)==1 ? ((int($conf->{eotf}||0)==3) ? "hlg" : "hdr10") : "sdr";
 }
 my $transport=lc($conf->{dv_transport}||"standard");
 $transport="standard" if($transport ne "lldv");
 my %out=(mode=>$mode,mode_label=>_mode_label($mode,$transport),transport=>$transport);
 if(defined($hdmi_info) && $hdmi_info=~/(\d+)x(\d+)(i?)\s*\@\s*([\d.]+)/) {
  @out{qw(w h interlaced refresh)}=($1+0,$2+0,$3 ? 1 : 0,$4+0);
 }
 my $format=$conf->{color_format};
 $out{format}=_format_label(defined($format) && $format ne "" ? int($format) : 0);
 $out{bits}=int($conf->{max_bpc}||8)."-bit";
 # "Default" leaves the range to the driver, so it is shown but never compared.
 my $range=int($conf->{rgb_quant_range}||0);
 $out{range}=$range==1 ? "Limited" : $range==2 ? "Full" : "Default";
 my $colorimetry=$conf->{colorimetry};
 $out{colorimetry}=(defined($colorimetry) && $colorimetry ne "") ? ($COLORIMETRY{int($colorimetry)}||"Other") : "Default";
 $out{transfer}=$mode eq "sdr" ? "SDR gamma" : $mode eq "hlg" ? "HLG" : $mode eq "dv" ? "Dolby Vision" : "PQ (ST 2084)";
 if($mode eq "hdr10" || $mode eq "hlg") {
  my %primaries=(0=>"BT.709",1=>"BT.2020",2=>"DCI-P3 D65",3=>"DCI-P3 DCI");
  $out{primaries}=$primaries{int($conf->{primaries}||0)}||"Custom";
  $out{mastering}=_nits_text($conf->{max_luma})." / "._nits_text($conf->{min_luma})." nits";
  $out{light_levels}=int($conf->{max_cll}||0)." / ".int($conf->{max_fall}||0);
 }
 if($mode eq "dv") {
  $out{dv_transport}=$transport eq "lldv" ? "Low latency" : "Standard";
  $out{dv_map}=int($conf->{dv_map_mode}||2)==1 ? "Absolute" : "Relative";
  $out{dv_metadata}="Attached";
 }
 return \%out;
}

# What the HDMI output is actually set to: the connector state the driver
# applied, the live CRTC timing and the infoframe slots the encoder sends.
sub sent_signal {
 my (%in)=@_;
 my %out=(readable=>0);
 my $mode=$in{mode};
 if(ref($mode) eq "HASH") {
  @out{qw(w h refresh interlaced)}=@{$mode}{qw(w h refresh interlaced)};
  $out{readable}=1;
 }
 my $props=(ref($in{connector}) eq "HASH") ? $in{connector}{props} : undef;
 my $packets=$in{packets};
 return \%out if(ref($props) ne "HASH");
 $out{readable}=1;
 # (value, enum name) of one connector property, or () when it is absent.
 my $enum=sub {
  my $name=shift;
  my $entry=$props->{$name};
  return undef if(ref($entry) ne "HASH" || !defined($entry->{value}));
  return ($entry->{value},$entry->{enums}{$entry->{value}});
 };
 my ($format)=$enum->("active color format");
 ($format)=$enum->("output format") if(!defined($format));
 $out{format}=_format_label($format) if(defined($format));
 my ($colorimetry)=$enum->("Colorimetry");
 ($colorimetry)=$enum->("Colorspace") if(!defined($colorimetry));
 $out{colorimetry}=$COLORIMETRY{$colorimetry}||"Other" if(defined($colorimetry));
 my ($range)=$enum->("rgb quant range");
 # YCbCr is always sent at limited (video) range whatever the RGB property says.
 # 3 (HDMI_QUANTIZATION_RANGE_RESERVED) is the RQ3V1 unity-CSC kernel's Limited
 # signalling (issue 74) — same label, like get_hdmi_info().
 $out{range}=(defined($format) && $format != 0) ? "Limited"
  : defined($range) && $range==2 ? "Full"
  : defined($range) && ($range==1 || $range==3) ? "Limited" : undef;
 # Deep colour shows up as a faster pixel rate than the mode's own clock.
 my ($rate)=$enum->("active pixel rate");
 if(defined($rate) && ref($mode) eq "HASH" && $mode->{clock_khz}) {
  my $ratio=$rate/($mode->{clock_khz}*1000);
  $ratio*=2 if(defined($format) && $format == 3);
  # vc4 reports the rate doubled on some links (185.6 MHz for 1080p24 at
  # 10-bit); deep colour only ever adds 25 or 50 %, so fold octaves away.
  $ratio/=2 while($ratio >= 1.9);
  if(defined($format) && $format == 2) { $out{bits}="12-bit container"; }
  elsif(abs($ratio-1.5) < 0.05) { $out{bits}="12-bit"; }
  elsif(abs($ratio-1.25) < 0.05) { $out{bits}="10-bit"; }
  elsif(abs($ratio-1.0) < 0.05) { $out{bits}="8-bit"; }
 }
 my $hdr=decode_hdr_output_metadata(ref($props->{HDR_OUTPUT_METADATA}) eq "HASH" ? $props->{HDR_OUTPUT_METADATA}{blob} : "");
 # An absent or truncated property is unknown, not an empty metadata blob.
 my $empty_blob=sub {
  my $entry=shift;
  return ref($entry) eq "HASH" && $entry->{value_read}
   && ($entry->{blob}||"") eq "" && (!defined($entry->{value}) || $entry->{value} eq "0");
 };
 my $dv_prop=$props->{DOVI_OUTPUT_METADATA};
 my $dovi=(ref($dv_prop) eq "HASH" && ($dv_prop->{blob}||"")=~/[1-9a-f]/) ? 1
  : $empty_blob->($dv_prop) ? 0 : undef;
 # A metadata blob left on the connector is not proof it is being sent; the
 # encoder's packet slot is, when the register dump is readable.
 my $hdr_sent=$hdr ? 1 : $empty_blob->($props->{HDR_OUTPUT_METADATA}) ? 0 : undef;
 my $dv_sent=$dovi;
 if(ref($packets) eq "HASH") {
  $hdr_sent=0 if(defined($packets->{hdr}) && !$packets->{hdr});
  $hdr_sent=undef if($packets->{hdr} && !$hdr);
  $dv_sent=0 if(defined($packets->{vendor}) && !$packets->{vendor});
 }
 $out{dv_metadata}=$dovi ? "Attached" : "Not attached" if(defined($dovi));
 if($dv_sent) {
  $out{mode_label}="Dolby Vision";
  $out{transfer}="Dolby Vision";
 } elsif($hdr_sent && ($hdr->{eotf}==2 || $hdr->{eotf}==3)) {
  $out{mode_label}=$hdr->{eotf}==3 ? "HLG" : "HDR10";
  $out{transfer}=_transfer_label($hdr->{eotf});
 } elsif(defined($dv_sent) && !$dv_sent && defined($hdr_sent) && !$hdr_sent) {
  $out{mode_label}="SDR";
  $out{transfer}="SDR gamma";
 }
 if($hdr_sent) {
  $out{primaries}=_primaries_name($hdr->{primaries},$hdr->{white});
  $out{mastering}=_nits_text($hdr->{max_luminance})." / "._nits_text($hdr->{min_luminance})." nits";
  $out{light_levels}=$hdr->{max_cll}." / ".$hdr->{max_fall};
 } elsif(defined($hdr_sent) && !$hdr_sent && !$dv_sent) {
  $out{primaries}=$out{mastering}=$out{light_levels}="No HDR metadata";
 }
 return \%out;
}

# Rows are compared only where both sides are known and the comparison means
# something: "Default" range defers to the driver, and Dolby Vision owns the
# tunnel's format, depth and range regardless of the Output settings.
sub card_model {
 my ($requested,$sent,$kit)=@_;
 $requested={} if(ref($requested) ne "HASH");
 $sent={} if(ref($sent) ne "HASH");
 $kit={} if(ref($kit) ne "HASH");
 my $dv=($requested->{mode} || "") eq "dv";
 my $hdr=($requested->{mode} || "")=~/^(?:hdr10|hlg)$/ || ($sent->{mode_label} || "")=~/^(?:HDR10|HLG)$/;
 # Each row is [label, model key, compare?].
 my @rows=(
  ["Signal","mode_label",1],
  ["Resolution","resolution",1],
  ["Pixel format","format",!$dv],
  # YCbCr 4:2:2 always travels in HDMI's 12-bit container, which carries the
  # requested 8 or 10 bits unchanged, so the container depth is not a mismatch.
  ["Bit depth","bits",!$dv && ($sent->{format}||"") ne "YCbCr 4:2:2"],
  ["Range","range",!$dv && ($requested->{range}||"") ne "Default"],
  ["Colorimetry","colorimetry",!$dv && ($requested->{colorimetry}||"") ne "Default"],
  ["Transfer","transfer",1],
 );
 # HLG's HDR infoframe normally carries no primaries, so a zero set there is
 # not a disagreement with the settings.
 my $hlg=($requested->{mode} || "") eq "hlg";
 push @rows,(["Primaries","primaries",!$hlg],["Mastering","mastering",1],["MaxCLL / MaxFALL","light_levels",1]) if($hdr);
 push @rows,(["DV transport","dv_transport",0],["DV mapping","dv_map",0],["DV metadata","dv_metadata",1]) if($dv);
 my %req=%$requested;
 my %got=%$sent;
 $req{resolution}=_resolution_text(@req{qw(w h refresh interlaced)});
 $got{resolution}=_resolution_text(@got{qw(w h refresh interlaced)});
 my @out;
 my $mismatches=0;
 foreach my $row (@rows) {
  my ($label,$key,$compare)=@$row;
  my $want=defined($req{$key}) && $req{$key} ne "" ? $req{$key} : "\x{2014}";
  my $have=defined($got{$key}) && $got{$key} ne "" ? $got{$key} : "Unknown";
  $have="\x{2014}" if($key=~/^dv_(?:transport|map)$/);
  my $differs=0;
  if($compare && $want ne "\x{2014}" && $have ne "Unknown" && $have ne "\x{2014}") {
   if($key eq "resolution") {
    # The daemon rounds refresh to two decimals; compare at that precision.
    $differs=1 if(($req{w}||0) != ($got{w}||0) || ($req{h}||0) != ($got{h}||0)
     || (defined($req{refresh}) && defined($got{refresh}) && abs($req{refresh}-$got{refresh}) > 0.011)
     || (defined($req{interlaced}) && defined($got{interlaced}) && $req{interlaced} != $got{interlaced}));
   } elsif($key eq "mode_label" && $want=~/^Dolby Vision/ && $have eq "Dolby Vision") {
    # The connector state shows Dolby Vision metadata but not its transport.
    $differs=0;
   } else {
    $differs=($want ne $have) ? 1 : 0;
   }
  }
  $mismatches+=$differs;
  push @out,{label=>$label,requested=>$want,sent=>$have,differs=>$differs};
 }
 my $headline=$sent->{mode_label} || $requested->{mode_label} || "No signal";
 my $headline_source=$sent->{mode_label} ? "sent" : "requested";
 my $detail=$got{resolution} || $req{resolution} || "";
 my $footer="";
 if(!$sent->{readable}) {
  $footer="The HDMI driver could not be read, so sent values are unknown.";
 } elsif($mismatches) {
  $footer="Sent signal differs from the settings in $mismatches ".($mismatches==1 ? "field." : "fields.");
 }
 my @kit;
 push @kit,["Generator",$kit->{generator}] if(($kit->{generator}||"") ne "");
 push @kit,["TV",$kit->{tv}] if(($kit->{tv}||"") ne "");
 push @kit,["Meter",$kit->{meter}] if(($kit->{meter}||"") ne "");
 return {headline=>$headline,headline_source=>$headline_source,detail=>$detail,
  rows=>\@out,mismatches=>$mismatches,footer=>$footer,kit=>\@kit};
}

sub model_signature {
 my ($model,$extra)=@_;
 return "" if(ref($model) ne "HASH");
 my @parts=($model->{headline},$model->{detail},$model->{footer},defined($extra)?$extra:"");
 push @parts,map { join("|",$_->{label},$_->{requested},$_->{sent},$_->{differs}) } @{$model->{rows}||[]};
 push @parts,map { join("|",@$_) } @{$model->{kit}||[]};
 return join("\n",map { defined($_) ? $_ : "" } @parts);
}

sub _hlg_code_for_nits {
 my $nits=shift;
 # BT.2100 HLG on a 1000-nit display: system gamma 1.2, black lift ignored.
 my $scene=($nits/1000) ** (1/1.2);
 return sqrt(3*$scene) if($scene <= 1/12);
 my ($a,$b,$c)=(0.17883277,0.28466892,0.55991073);
 return $a*log(12*$scene-$b)+$c;
}

# 8-bit PNG codes (full-range normalised) for value text, label text and the
# card's own black for the signal mode in use.
sub text_levels {
 my ($mode,$transport)=@_;
 $mode=lc($mode||"sdr");
 if($mode eq "dv") {
  my $levels=$DV_LEVELS{(($transport||"") eq "lldv") ? "lldv" : "standard"};
  return {%$levels};
 }
 my $code=sub {
  my $nits=shift;
  my $signal=$mode eq "hdr10" ? pq_encode_normalized($nits)
   : $mode eq "hlg" ? _hlg_code_for_nits($nits)
   : ($nits/100) ** (1/2.4);
  return int($signal*255+0.5);
 };
 return {value=>$code->($VALUE_NITS),label=>$code->($LABEL_NITS),black=>0};
}

# Random hop targets. Each lands fully inside a safe area and at least a third
# of the free travel away from the previous spot (the loop's wrap included),
# so consecutive positions barely overlap and wear spreads over the panel.
sub hop_positions {
 my ($screen_w,$screen_h,$card_w,$card_h,$count,$random)=@_;
 $random=sub { rand() } if(ref($random) ne "CODE");
 $count=$HOP_COUNT if(!$count || $count < 1);
 # A 3 % margin keeps the card clear of TVs that still overscan.
 my $margin_x=int($screen_w*0.03);
 my $margin_y=int($screen_h*0.03);
 my $free_w=$screen_w-2*$margin_x-$card_w;
 my $free_h=$screen_h-2*$margin_y-$card_h;
 if($free_w < 0) { $margin_x=0; $free_w=$screen_w-$card_w; }
 if($free_h < 0) { $margin_y=0; $free_h=$screen_h-$card_h; }
 $free_w=0 if($free_w < 0);
 $free_h=0 if($free_h < 0);
 my $far=sub {
  my ($a,$b)=@_;
  my $dx=$free_w ? ($a->[0]-$b->[0])/$free_w : 0;
  my $dy=$free_h ? ($a->[1]-$b->[1])/$free_h : 0;
  return sqrt($dx*$dx+$dy*$dy) >= 1/3;
 };
 # Rejection sampling: 40 draws always find a far spot unless the card nearly
 # fills the screen, in which case the last draw is used as it stands.
 my @positions;
 for(my $i=0;$i<$count;$i++) {
  my $pick;
  for(my $try=0;$try<40;$try++) {
   my $candidate=[$margin_x+int($random->()*($free_w+1)),$margin_y+int($random->()*($free_h+1))];
   $pick=$candidate;
   last if(!@positions);
   next if(!$far->($candidate,$positions[-1]));
   last if($i<$count-1 || $far->($candidate,$positions[0]));
  }
  push @positions,$pick;
 }
 return \@positions;
}

# ImageMagick treats a leading "@" as a file to read and "%" as an escape;
# neither may reach it from a hostname or a TV model string.
sub _im_text {
 my $text=shift;
 $text="" if(!defined($text));
 $text=~s/[\r\n\t]+/ /g;
 $text=~s/\\/\\\\/g;
 $text=~s/%/%%/g;
 $text="\\$text" if($text=~/^@/);
 return $text;
}

# A multi-line label; zero-width spaces keep blank cells from being trimmed
# by ImageMagick, so headers and mismatch markers stay level with their rows.
sub _column {
 my ($lines,$font,$size,$fill,$spacing)=@_;
 my $text=join("\n",map { _im_text($_ eq "" ? "\x{200b}" : $_) } @$lines);
 return ("(","-font",$font,"-pointsize",$size,"-interline-spacing",$spacing,"-fill",$fill,"label:$text",")");
}

sub _gap {
 my ($w,$h)=@_;
 # -size is a persistent setting in ImageMagick 6; clear it again or every
 # later label is squeezed into the gap's box.
 return ("(","-size",int($w<1?1:$w)."x".int($h<1?1:$h),"xc:#000000","+size",")");
}

# One convert invocation builds the whole card: the headline, then a table of
# four columns (label, requested, marker, sent) whose lines share a font, size
# and spacing so every row stays aligned, then the footer and the kit block.
# ImageMagick 6 settings outlive parentheses, so gravity is set at each step:
# NorthWest keeps multi-line labels left-aligned and appended blocks top-aligned.
sub convert_arguments {
 my ($model,%opt)=@_;
 my $scale=$opt{scale} || 1;
 my $fonts=$opt{fonts} || {};
 my $levels=$opt{levels} || {value=>200,label=>140,black=>0};
 my $px=sub { my $v=int(shift()*$scale+0.5); return $v < 1 ? 1 : $v; };
 my $grey=sub { my $c=int(shift); return sprintf("#%02x%02x%02x",$c,$c,$c); };
 my ($value,$label,$black)=($grey->($levels->{value}),$grey->($levels->{label}),$grey->($levels->{black}));
 my $body=$fonts->{regular};
 my ($head_size,$row_size,$kit_size)=($px->(72),$px->(24),$px->(20));
 my @rows=@{$model->{rows}||[]};
 my @labels=("",map { $_->{label} } @rows);
 my @requested=("Requested",map { $_->{requested} } @rows);
 my @markers=("",map { $_->{differs} ? "\x{2260}" : "" } @rows);
 my @sent=("Sent",map { $_->{sent} } @rows);
 # The mode is the one thing to read from across the room; the table below
 # carries resolution and everything else, so the headline stands alone.
 my @args=("-background",$black,"-gravity","NorthWest");
 push @args,"(","-font",$fonts->{bold},"-pointsize",$head_size,"-fill",$value,"label:"._im_text($model->{headline}),")";
 push @args,_gap(1,$px->(18));
 push @args,"(";
 push @args,_column(\@labels,$body,$row_size,$label,$px->(8));
 push @args,_gap($px->(30),1);
 push @args,_column(\@requested,$body,$row_size,$label,$px->(8));
 push @args,_gap($px->(14),1);
 # Recent ImageMagick 6/7 releases reject an entirely whitespace label.
 # With no differences the surrounding gaps provide the empty marker space.
 push @args,_column(\@markers,$body,$row_size,$value,$px->(8)) if(grep { $_ ne "" } @markers);
 push @args,_gap($px->(14),1);
 push @args,_column(\@sent,$body,$row_size,$value,$px->(8));
 push @args,"+append",")";
 if(($model->{footer}||"") ne "") {
  push @args,_gap(1,$px->(16));
  push @args,"(","-font",$body,"-pointsize",$row_size,"-fill",$value,"label:"._im_text($model->{footer}),")";
 }
 my @kit=@{$model->{kit}||[]};
 if(@kit) {
  push @args,_gap(1,$px->(28));
  push @args,"(";
  push @args,_column([map { $_->[0] } @kit],$body,$kit_size,$label,$px->(6));
  push @args,_gap($px->(30),1);
  push @args,_column([map { $_->[1] } @kit],$body,$kit_size,$label,$px->(6));
  push @args,"+append",")";
 }
 push @args,"-append";
 push @args,"-bordercolor",$black,"-border",$px->(24);
 push @args,"-depth","8","-type","TrueColor";
 return @args;
}

# Width and height from the PNG's IHDR chunk, without loading the image.
sub png_dimensions {
 my ($file)=@_;
 return () if(!defined($file) || !open(my $fh,"<:raw",$file));
 my $head="";
 read($fh,$head,24);
 close($fh);
 return () if(length($head) < 24 || substr($head,0,8) ne "\x89PNG\r\n\x1a\n" || substr($head,12,4) ne "IHDR");
 return unpack("N N",substr($head,16,8));
}

# One frame per hop; the renderer loads the PNG once and only moves it.
sub sequence_pattern {
 my (%opt)=@_;
 my $pat="";
 foreach my $position (@{$opt{positions}||[]}) {
  $pat.="DRAW=IMAGE\nDIM=$opt{w},$opt{h}\nRGB=0,0,0\nBG=$opt{bg}\nPOSITION=$position->[0],$position->[1]\n";
  $pat.="IMAGE=$opt{image}\nSOURCE_RANGE=FULL\nEND=1\nFRAME=".($opt{hop_ms}||$HOP_MS)."\n";
 }
 return $pat;
}

sub meter_name_for_usb_id {
 my $id=lc(defined($_[0]) ? $_[0] : "");
 return $KNOWN_METERS{$id} || "";
}

sub picture_mode_label {
 my $mode=defined($_[0]) ? $_[0] : "";
 return "" if($mode eq "");
 return $PICTURE_MODES{$mode} if($PICTURE_MODES{$mode});
 $mode=~s/([a-z])([A-Z])/$1 \L$2/g;
 return ucfirst($mode);
}

1;
