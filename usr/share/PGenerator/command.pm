#
# Copyright (c) 2017-2018 Biasiotto Riccardo
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
# See the File README and COPYING for more detail about License
#

###############################################
#   Auto-Select 4K 30Hz Mode (Pi 4 KMS)      #
###############################################
sub auto_select_4k_mode (@) {
 return if($pgenerator_conf{"mode_idx"} ne "");
 return if(!$is_kms);
 my $target_idx="";
 my $found_connector=0;
 open(CMD_MODETEST,"timeout 3 $modetest 2>/dev/null|");
 while(<CMD_MODETEST>) {
  $found_connector=1 if(/\s+connected/);
  next if(!$found_connector);
  # Match progressive 3840x2160 @ 30 Hz  (e.g. #123 3840x2160 30.00 ...)
  if(/#(\d+)\s+3840x2160\s+30\.\d+/ && !/interlace/) {
   $target_idx=$1;
   last;
  }
 }
 close(CMD_MODETEST);
 if($target_idx ne "") {
  &sudo("SET_PGENERATOR_CONF","mode_idx","$target_idx");
  $pgenerator_conf{"mode_idx"}="$target_idx";
  &log("Auto-selected 4K 30Hz mode_idx=$target_idx");
 }
}

###############################################
#   Keep the chosen mode across mode lists    #
###############################################
# mode_idx indexes the connected connector's mode list, and that list
# depends on the port and the EDID: on a Pi 4 with the same TV, #21 was
# 1080p60 at HDMI0 and 1080p29.97 at HDMI1 (HDMI1 lists no modes above
# 340 MHz). mode_timing holds the full timing mode_idx had when it was
# recorded, mode_timing_idx the index it was recorded for.

# {idx => timing} of the first connected connector in modetest -c output.
# Timing: name@refresh:h,v timings:clock:flags, e.g.
# 1920x1080@60.00:1920,2008,2052,2200,1080,1084,1089,1125:148500:phsync,pvsync
sub mode_timing_modes (@) {
 my $out=shift;
 my %modes;
 my $in=0;
 foreach my $line (split(/\n/,defined $out ? $out : "")) {
  if($line=~/^\d+\s+\d+\s+(connected|disconnected|unknown)\s/) {
   last if($in);
   $in=($1 eq "connected") ? 1 : 0;
   next;
  }
  next if(!$in);
  if($line=~/^\s*#(\d+)\s+(\S+)\s+([\d.]+)\s+((?:\d+\s+){8})(\d+)\s+flags:\s*([^;]*);/) {
   my ($idx,$name,$refresh,$t,$clock,$flags)=($1,$2,$3,$4,$5,$6);
   $t=~s/\s+$//; $t=~s/\s+/,/g;
   $flags=~s/\s+//g;
   $modes{$idx}="$name\@$refresh:$t:$clock:$flags";
  }
 }
 return \%modes;
}

# Before a renderer start: a mode_idx that someone set since the last record
# is recorded with its timing; a mode_idx that still is the recorded one but
# now names another timing (the list changed under it) is moved to the index
# that has the recorded timing. Without that timing on this display, or
# without a display, nothing changes.
sub mode_idx_follow_timing (@) {
 my $out=shift;
 return if(!$is_kms);
 my $idx=$pgenerator_conf{"mode_idx"};
 return if(!defined $idx || $idx!~/^\d+$/);
 $out=`timeout 3 $modetest -c 2>/dev/null` if(!defined $out);
 my $modes=&mode_timing_modes($out);
 return if(!%$modes);
 my $rec=defined $pgenerator_conf{"mode_timing"} ? $pgenerator_conf{"mode_timing"} : "";
 my $rec_idx=defined $pgenerator_conf{"mode_timing_idx"} ? $pgenerator_conf{"mode_timing_idx"} : "";
 if($rec eq "" || $rec_idx ne $idx) {
  if(defined $modes->{$idx}) {
   my %before=map { ($_ => $pgenerator_conf{$_}) } qw(mode_timing mode_timing_idx);
   if((&set_pgenerator_conf_runtime_multi("mode_timing",$modes->{$idx},"mode_timing_idx",$idx) || "")!~/^\Q$ok_response\E/) {
    @pgenerator_conf{keys %before}=values %before;
    &log("Mode: could not record the timing of mode_idx $idx (conf not written)");
   }
  }
  return;
 }
 return if(defined $modes->{$idx} && $modes->{$idx} eq $rec);
 my ($to)=sort { $a <=> $b } grep { $modes->{$_} eq $rec } keys %$modes;
 if(!defined $to) {
  &log("Mode: mode_idx $idx is no longer $rec and this display has no such mode; left as is");
  return;
 }
 # The renderer reads mode_idx from the file: only a written move counts.
 if((&set_pgenerator_conf_runtime_multi("mode_idx",$to,"mode_timing_idx",$to) || "")!~/^\Q$ok_response\E/) {
  @pgenerator_conf{qw(mode_idx mode_timing_idx)}=($idx,$rec_idx);
  &log("Mode: mode_idx $idx should follow $rec to $to, but the conf could not be written; left as is");
  return;
 }
 &log("Mode: mode_idx $idx -> $to: the display's mode list changed (port or EDID); $rec kept");
}

sub webui_preferred_rgb_quant_range (@) {
 my $quant_range=$webui_rgb_quant_range_preferred;
 $quant_range=$pgenerator_conf{"rgb_quant_range"} if($quant_range eq "");
 $quant_range=2 if($quant_range !~/^[12]$/);
 return $quant_range;
}

# Range on the wire: 1 Limited, 2 Full. Default (0) is Limited for YCbCr
# (the renderer's YCbCr scaling); for RGB the kernel picks it per mode and
# the renderer, which resolves it the same way, records the result.
sub effective_rgb_quant_range (@) {
 my $quant_range=$pgenerator_conf{"rgb_quant_range"} || "0";
 return $quant_range + 0 if($quant_range =~/^[12]$/);
 return 1 if(($pgenerator_conf{"color_format"} || "0") ne "0");
 if(open(my $fh,"<",$renderer_default_range_file)) {
  my $line=<$fh> || "";
  close($fh);
  return $1 + 0 if($line =~/^([12])/);
 }
 return 2;
}

sub apply_source_rgb_quant_range (@) {
 my $source=lc(shift || "webui");
 my $quant_range=shift;
 my $owner_changed=0;
 if($source eq "webui") {
  $quant_range=&webui_preferred_rgb_quant_range() if($quant_range !~/^[12]$/);
  $webui_rgb_quant_range_preferred=$quant_range;
  $external_rgb_quant_range_active=0;
 } else {
  $quant_range=2 if($quant_range !~/^[12]$/);
  $webui_rgb_quant_range_preferred=$pgenerator_conf{"rgb_quant_range"} if($webui_rgb_quant_range_preferred eq "");
  $external_rgb_quant_range_active=1;
 }
 return 0 if(($pgenerator_conf{"rgb_quant_range"}||"") eq "$quant_range" && $rgb_quant_range_source eq $source);
 if(($pgenerator_conf{"rgb_quant_range"}||"") eq "$quant_range") {
  $owner_changed=($rgb_quant_range_source ne $source);
  $rgb_quant_range_source=$source;
  &log("Signal range owner: source=$source rgb_quant_range=$quant_range (no restart)");
  if($owner_changed) {
   # The value on the wire is unchanged. A running renderer owns the
   # connector properties (and DRM master): modetest -w here would steal
   # master from it. Ask it to re-assert the range in place instead; if it
   # cannot, nothing needs to change, so no restart either.
   if(&pattern_generator_is_running()) {
    &renderer_reconfigure_in_place({rgb_quant_range=>1}) if(&pattern_generator_has_drm_master());
   } else {
    &apply_drm_properties();
   }
  }
  return 1;
 }
 my $dv_before=&renderer_dv_conf_active();
 &sudo("SET_PGENERATOR_CONF","rgb_quant_range","$quant_range");
 $pgenerator_conf{"rgb_quant_range"}="$quant_range";
 $rgb_quant_range_source=$source;
 &log("Signal range owner: source=$source rgb_quant_range=$quant_range");
 return 1 if(&renderer_reconfigure_in_place({rgb_quant_range=>1},$dv_before));
 &pattern_generator_stop();
 &pattern_generator_start();
 return 1;
}

sub release_source_rgb_quant_range (@) {
 my $source=lc(shift || "");
 return 0 if($source eq "");
 return 0 if($rgb_quant_range_source ne $source && !($source ne "webui" && $external_rgb_quant_range_active));
 return &apply_source_rgb_quant_range("webui",&webui_preferred_rgb_quant_range());
}

sub set_pgenerator_conf_runtime(@) {
 my ($key,$value)=@_;
 &sudo("SET_PGENERATOR_CONF",$key,$value);
 $pgenerator_conf{$key}="$value";
}

# Several keys in one root-helper call (each sudo spawn costs ~0.35s) and
# one write. An empty value deletes its key; deletes go first, as when
# they were written singly before the batch (the helper pairs dv_metadata
# with dv_map_mode, so the order counts).
sub set_pgenerator_conf_runtime_multi(@) {
 my @pairs=@_;
 my (@deletes,@batch);
 for(my $i=0; $i+1 <= $#pairs; $i+=2) {
  my ($key,$value)=($pairs[$i],$pairs[$i+1]);
  if("$value" eq "") { push(@deletes,$key,""); }
  else { push(@batch,$key,$value); }
  $pgenerator_conf{$key}="$value";
 }
 # The helper's answer ("OK" when the file was written), for callers
 # that must not go on with a value only held in memory.
 return (@deletes || @batch) ? &sudo("SET_PGENERATOR_CONF_MULTI",@deletes,@batch) : $ok_response;
}

# Classic CMD protocol (DeviceControl / custom clients) uses 1.6 wire units for
# MIN_LUMA: integer steps of 0.0001 nits (e.g. 5 = 0.0005 nits). Plus stores
# conf min_luma as nits for the WebUI/renderer, so convert at the CMD boundary.
sub pg_min_luma_cmd_wire_to_nits(@) {
 my ($wire)=@_;
 $wire=0 if(!defined($wire) || $wire eq "");
 $wire=$wire+0;
 $wire=0 if($wire < 0);
 $wire=65535 if($wire > 65535);
 my $nits=$wire * 0.0001;
 return sprintf("%.10g",$nits);
}

sub pg_min_luma_cmd_nits_to_wire(@) {
 my ($nits)=@_;
 $nits=0 if(!defined($nits) || $nits eq "");
 $nits=$nits+0;
 return 0 if($nits <= 0);
 my $wire=int(($nits / 0.0001) + 0.5);
 $wire=0 if($wire < 0);
 $wire=65535 if($wire > 65535);
 return $wire;
}

sub dv_metadata_for_map_mode(@) {
 my $dv_map_mode=shift;
 return "3" if(defined $dv_map_mode && $dv_map_mode eq "1");
 return "4" if(defined $dv_map_mode && $dv_map_mode eq "2");
 return "2";
}

sub dv_map_mode_for_metadata(@) {
 my $dv_metadata=shift;
 return "0" if(defined $dv_metadata && $dv_metadata eq "2");
 return "1" if(defined $dv_metadata && $dv_metadata eq "3");
 return "2" if(defined $dv_metadata && $dv_metadata eq "4");
 return "";
}

# The keys and values the root helper leaves for SET_PGENERATOR_CONF_MULTI
# key value ... (PGenerator_cmd.pl pgenerator_conf_set_pair): it applies the
# pairs in order and rewrites dv_metadata and dv_map_mode as each other's
# pair, so a later one of the two decides both. An empty value deletes.
sub conf_after_helper_writes(@) {
 my @pairs=@_;
 my %after=();
 for(my $i=0; $i+1 <= $#pairs; $i+=2) {
  my ($key,$value)=($pairs[$i],defined $pairs[$i+1] ? "$pairs[$i+1]" : "");
  $after{$key}=$value;
  if($key eq "dv_metadata") {
   my $pair=&dv_map_mode_for_metadata($value);
   $after{"dv_map_mode"}=$pair if($pair ne "");
  } elsif($key eq "dv_map_mode" && $value ne "") {
   $after{"dv_metadata"}=&dv_metadata_for_map_mode($value);
  }
 }
 return %after;
}

sub normalize_dv_transport_conf(@) {
 return if(
  int($pgenerator_conf{"dv_status"} || 0) != 1 &&
  int($pgenerator_conf{"is_ll_dovi"} || 0) != 1 &&
  int($pgenerator_conf{"is_std_dovi"} || 0) != 1
 );
 my $dv_map_mode=$pgenerator_conf{"dv_map_mode"};
 my $dv_metadata=&dv_metadata_for_map_mode($dv_map_mode);
 my $dv_transport=&pg_dv_transport_mode();
 my %wanted=(
  signal_mode=>"dv",
  is_sdr=>"0",
  is_hdr=>"1",
  eotf=>"2",
  dv_transport=>"$dv_transport",
  is_ll_dovi=>&pg_dv_transport_ll_flag($dv_transport),
  is_std_dovi=>&pg_dv_transport_std_flag($dv_transport),
  dv_status=>"1",
  dv_interface=>&pg_dv_transport_interface($dv_transport),
  dv_profile=>"1",
  dv_metadata=>"$dv_metadata",
  dv_color_space=>"0",
  color_format=>&pg_dv_transport_color_format($dv_transport),
  colorimetry=>"9",
  primaries=>"1",
  max_bpc=>&pg_dv_transport_max_bpc($dv_transport),
  rgb_quant_range=>&pg_dv_transport_quant_range($dv_transport)
 );
 my @writes=();
 for my $key (sort keys %wanted) {
  # A stored "0" is a value: is_sdr=0 must not be rewritten on every start.
  next if((defined $pgenerator_conf{$key} ? $pgenerator_conf{$key} : "") eq $wanted{$key});
  push(@writes,$key,$wanted{$key});
 }
 &normalize_conf_write("DV",@writes);
}

# The renderer reads the conf file, not this memory: only a written value
# counts. Without an OK from the root helper the file may still hold the
# write (its timeout can end it after the rename) or another thread's write
# of the same key: memory takes these keys from the file, so the daemon
# reports what the renderer reads, and the next start writes what is still
# missing. An unreadable file leaves memory as it was before the write.
sub normalize_conf_write(@) {
 my ($what,@writes)=@_;
 return 1 if(!@writes);
 my %keys=@writes;
 my %before=map { ($_ => $pgenerator_conf{$_}) } keys %keys;
 return 1 if((&set_pgenerator_conf_runtime_multi(@writes) || "")=~/^\Q$ok_response\E/);
 my $file=&renderer_conf_read();
 my @missing=();
 for my $key (keys %keys) {
  my $value=$file ? $file->{$key} : $before{$key};
  if(defined $value) { $pgenerator_conf{$key}=$value; }
  else { delete $pgenerator_conf{$key}; }
  push(@missing,$key) if(!defined $value || "$value" ne "$keys{$key}");
 }
 if(!@missing) {
  &log("Signal: $what conf helper gave no OK, but PGenerator.conf reads back as written");
  return 1;
 }
 &log("Signal: $what conf could not be written (".join(",",sort @missing)."); the renderer starts with the stored values");
 return 0;
}

# Reconcile the legacy, independently-written signal flags at the renderer
# restart boundary. HCFR 4.1 writes IS_HDR, IS_LL_DOVI, IS_STD_DOVI,
# DV_STATUS, and DV_INTERFACE as separate classic-protocol commands. Its DV
# bundle deliberately sets both DV transport flags and does not write the
# newer signal_mode key. normalize_dv_transport_conf() resolves the transport
# conflict from the operator's saved dv_transport preference; this helper also
# keeps signal_mode coherent when entering or leaving DV before the renderer
# binary is selected.
sub normalize_signal_mode_conf(@) {
 if(int($pgenerator_conf{"dv_status"} || 0) == 1 ||
    int($pgenerator_conf{"is_ll_dovi"} || 0) == 1 ||
    int($pgenerator_conf{"is_std_dovi"} || 0) == 1) {
  &normalize_dv_transport_conf();
  return;
 }

 my $signal_mode="sdr";
 if(int($pgenerator_conf{"is_hdr"} || 0) == 1) {
  $signal_mode=(int($pgenerator_conf{"eotf"} || 0) == 3) ? "hlg" : "hdr10";
 }
 my @writes=();
 push(@writes,"signal_mode",$signal_mode)
  if(($pgenerator_conf{"signal_mode"} || "") ne $signal_mode);
 # HDR10/HLG are BT.2020 signals. A BT.709 colorimetry left over from SDR
 # made the AVI infoframe contradict the HDR metadata, and sinks that trust
 # the AVI colorimetry then map the patches to the wrong gamut.
 push(@writes,"colorimetry","9")
  if($signal_mode ne "sdr" && ($pgenerator_conf{"colorimetry"} || "") ne "9");
 &normalize_conf_write(uc($signal_mode),@writes);
}

###############################################
#  Apply DRM Connector Properties (KMS only)  #
###############################################
sub kms_connector_has_property(@) {
 my $prop_name=shift;
 return 0 if(!$is_kms || $prop_name eq "");
 # Properties created with DRM_MODE_PROP_ATOMIC (e.g. the Pi5 kernel's
 # "output format") are hidden from legacy clients, so list with the
 # atomic cap first and fall back to the legacy listing for older
 # modetest builds (Pi4 BiasiLinux).
 for my $mt_flags ("-a","") {
  open(MT_PROP,"timeout 3 $modetest $mt_flags -c 2>/dev/null|");
  my $seen_any=0;
  while(<MT_PROP>) {
   $seen_any=1;
   if(/^[ \t]*[0-9]+[ \t]+\Q$prop_name\E:/) {
    close(MT_PROP);
    return 1;
   }
  }
  close(MT_PROP);
  last if($seen_any);
 }
 return 0;
}

sub kms_connector_blob_active(@) {
 my $prop_name=shift;
 return 0 if(!$is_kms || $prop_name eq "");
 # Reports whether a connector blob property currently carries a payload
 # (e.g. DOVI_OUTPUT_METADATA after the renderer's first page flip). Same
 # listing strategy as kms_connector_has_property: atomic cap first so
 # DRM_MODE_PROP_ATOMIC properties are visible, then the legacy listing.
 for my $mt_flags ("-a","") {
  open(MT_BLOB,"timeout 3 $modetest $mt_flags -c 2>/dev/null|");
  my $seen_any=0;
  my $in_prop=0;
  my $in_value=0;
  my $active=0;
  while(<MT_BLOB>) {
   $seen_any=1;
   if(/^[ \t]*[0-9]+[ \t]+(\S+):/) {
    # Next property header: if we just left the target property without
    # seeing a value payload, the blob is unset on this connector.
    last if($in_prop);
    $in_prop=($1 eq $prop_name) ? 1 : 0;
    $in_value=0;
    next;
   }
   next if(!$in_prop);
   if(/^[ \t]*value:\s*$/) { $in_value=1; next; }
   if($in_value && /^[ \t]*[0-9a-fA-F]{8,}\s*$/) {
    $active=1;
    last;
   }
  }
  close(MT_BLOB);
  return 1 if($active);
  last if($seen_any);
 }
 return 0;
}

my $modetest_atomic_writes;
sub modetest_connector_write(@) {
 my ($connector_id,$prop_name,$value)=@_;
 return 0 if(!$is_kms || $connector_id eq "" || $prop_name eq "");
 # Platform-keyed write mode, decided once per process:
 # - Bookworm vc4 (Colorspace property, no Colorimetry - Pi5) needs the
 #   atomic API for connector property writes (DRM_MODE_PROP_ATOMIC
 #   properties are invisible/unwritable via the legacy API).
 # - The legacy Pi4 kernel (Colorimetry property) must use legacy
 #   writes: an atomic commit from modetest holds DRM master longer and
 #   can trigger a modeset, which kills a renderer that is starting up
 #   (observed: SDR applies began failing on the Pi4 when these writes
 #   were atomic-first).
 if(!defined $modetest_atomic_writes) {
  $modetest_atomic_writes=(&kms_connector_has_property("Colorspace") && !&kms_connector_has_property("Colorimetry")) ? 1 : 0;
 }
 my $primary=$modetest_atomic_writes ? "-a" : "";
 my $fallback=$modetest_atomic_writes ? "" : "-a";
 system("timeout 3 $modetest $primary -w '$connector_id:$prop_name:$value' 2>/dev/null");
 return 1 if($? == 0);
 system("timeout 3 $modetest $fallback -w '$connector_id:$prop_name:$value' 2>/dev/null");
 return ($? == 0) ? 1 : 0;
}

sub map_kms_colorspace(@) {
 my $colorimetry=shift;
 my $color_fmt=shift;
 $color_fmt=0 if($color_fmt eq "");
 return 0 if($colorimetry eq "" || $colorimetry == 0);
 return 0 if($colorimetry == 2 && $color_fmt == 0);
 return 2 if($colorimetry == 2);
 return 9 if($colorimetry == 9 && $color_fmt == 0);
 return 10 if($colorimetry == 9);
 return $colorimetry;
}

sub map_broadcast_rgb(@) {
 my $quant_range=shift;
 return 0 if($quant_range eq "");
 return 2 if($quant_range == 1);
 return 1 if($quant_range == 2);
 return 0;
}

###############################################
#  Apply DRM Connector Properties (KMS only)  #
###############################################
sub apply_drm_properties (@) {
 my $prelaunch=shift;
 return if(!$is_kms);
 my $is_dv=int($pgenerator_conf{"dv_status"} || 0);
 # Find connected HDMI connector ID (and its current property values)
 my $connector_id="";
 my %current=();
 my $current_prop="";
 open(MT,"timeout 3 $modetest -c 2>/dev/null|");
 while(<MT>) {
  if($connector_id eq "") {
   $connector_id=$1 if(/^(\d+)\s+\d+\s+connected\s+HDMI/);
   next;
  }
  last if(/^\d+\s+\d+\s+(connected|disconnected)/);
  if(/^\s+\d+\s+(.+):\s*$/) { $current_prop=$1; next; }
  $current{$current_prop}=$1 if($current_prop ne "" && /^\s+value:\s*(\d+)\s*$/);
 }
 close(MT);
 return if($connector_id eq "");
 # Pre-launch: every changed connector property is a separate modeset, i.e.
 # one more HDMI resync (the TV showed the boot splash again for each). The
 # renderer's first atomic commit sets max bpc, output format, quant range
 # and colorimetry together with its mode, so before a spawn only write what
 # actually differs from the current state: max bpc and the RGB guard below.
 # Quant range and colorimetry are left to the renderer.
 my $skip_unchanged=sub {
  my ($prop,$value)=@_;
  return $prelaunch && defined($current{$prop}) && "$current{$prop}" eq "$value";
 };
 # Set max bpc — the binary fails to apply this property
 my $max_bpc=$pgenerator_conf{"max_bpc"};
 # Outside Dolby Vision the renderer sends 12 bpc out as 10 (10 bit surface);
 # pre-set the same value so the first commit needs no extra modeset.
 $max_bpc=10 if($max_bpc eq "12" && int($pgenerator_conf{"dv_status"} || 0) != 1);
 # vc4 only drives YCbCr 4:2:2 with max bpc >= 10 and falls back to RGB at 8
 # (4:2:2 is a 12 bit container at the 8 bit clock either way); the renderer
 # gets the same value from drm_override.so.
 $max_bpc=10 if(!$prelaunch && $pgenerator_conf{"color_format"} eq "2" && $max_bpc ne "" && $max_bpc < 10);
 if($max_bpc ne "" && $max_bpc > 0 && !$skip_unchanged->("max bpc",$max_bpc)) {
  &modetest_connector_write($connector_id,"max bpc",$max_bpc);
  &log("DRM: Set max bpc=$max_bpc on connector $connector_id");
 }
 # Reset output format — kernel retains previous value across binary
 # restarts.  A previous 10bpc run may have caused a YCbCr 4:2:2
 # fallback that sticks even after switching back to 8bpc RGB.
 my $color_fmt=$pgenerator_conf{"color_format"};
 $color_fmt=0 if($color_fmt eq "");
 # Before a spawn the CRTC still scans out a buffer the renderer did not
 # draw (console/splash, plain RGB). The renderer writes YCbCr code values
 # straight into its RGB framebuffer and the HDMI path passes them through,
 # so flagging YCbCr on the wire now makes that RGB black (0,0,0) read as
 # Y=0/Cb=0/Cr=0, i.e. saturated green, for the whole master-handoff and
 # init window. Keep the link RGB until the renderer's first commit
 # switches it together with its own correctly encoded frame.
 $color_fmt=0 if($prelaunch);
 if(!$skip_unchanged->("output format",$color_fmt)) {
  &modetest_connector_write($connector_id,"output format",$color_fmt);
  &log("DRM: Set output format=$color_fmt on connector $connector_id".($prelaunch ? " (pre-launch, renderer sets the configured format)" : ""));
 }
 if($prelaunch) {
  &log("DRM: pre-launch connector check done (max bpc=".($current{"max bpc"} // "?").", output format=".($current{"output format"} // "?")."); quant range and colorimetry are set by the renderer");
  return;
 }
 # Set quantization range (enums: Default=0 Limited=1 Full=2)
 my $quant_range=$pgenerator_conf{"rgb_quant_range"};
 $quant_range=2 if($is_dv);
 if($quant_range ne "") {
  &modetest_connector_write($connector_id,"rgb quant range",$quant_range);
  my $broadcast_rgb=&map_broadcast_rgb($quant_range);
  &modetest_connector_write($connector_id,"Broadcast RGB",$broadcast_rgb);
  &log("DRM: Set rgb quant range=$quant_range / Broadcast RGB=$broadcast_rgb on connector $connector_id");
 }
 # Set colorimetry / colorspace.
 # Older vc4 exposes "Colorimetry" while Bookworm exposes "Colorspace".
 my $colorimetry=$pgenerator_conf{"colorimetry"};
 $colorimetry=9 if($is_dv);
 if($colorimetry ne "" && $colorimetry > 0) {
  my $colorspace=&map_kms_colorspace($colorimetry,$color_fmt);
  # The legacy Pi4 Colorimetry property uses the same signal-format specific
  # enums as the newer Colorspace property.
  &modetest_connector_write($connector_id,"Colorimetry",$colorspace);
  &modetest_connector_write($connector_id,"Colorspace",$colorspace);
  &log("DRM: Set Colorimetry=$colorspace / Colorspace=$colorspace on connector $connector_id");
 }
}

# Block until the kernel reports no DRM master on the KMS minor, or $timeout
# seconds elapse. Polls /sys/kernel/debug/dri/<N>/clients; falls back to a
# short sleep if debugfs isn't mounted.
#
# Why this exists: pattern_generator_start() calls &apply_drm_properties()
# which issues up to 6 modetest -w writes (max bpc, output format, rgb
# quant range, Broadcast RGB, Colorimetry, Colorspace). Each modetest
# child opens /dev/dri/card1, takes DRM master, writes its property, and
# releases master on fd close. In practice the kernel's close->release
# handoff is not always visible to a fresh drmSetMaster caller in the
# next few ms - when the renderer was spawned immediately after
# apply_drm_properties() returned, the renderer's first drmSetMaster raced
# the just-closed modetest and got EACCES, killing the renderer before it
# ever drew a frame. On a hot Pi4 boot this race could lose 3+
# consecutive spawns, defeating the daemons's "retry 3 times" loop and
# requiring a service restart to recover. The companion comment in
# modetest_connector_write() describes the same root cause from the
# modetest side ("an atomic commit from modetest holds DRM master longer
# and can trigger a modeset, which kills a renderer that is starting up").
#
# This helper keeps the renderer spawn out of the critical window. The
# Pi4 BiasiLinux image always mounts /sys/kernel/debug, so the polling
# branch is the common path; the sleep fallback is defensive.
sub wait_for_drm_master_unowned (@) {
 # Local import: Fcntl isn't loaded at module level (this is a 'require'd
 # .pm with no use statements) and we need O_RDWR for sysopen().
 require Fcntl;
 import Fcntl qw(O_RDWR);
 my $timeout=shift;
 $timeout=3 if(!defined $timeout || $timeout <= 0);
 # Active probe: open /dev/dri/card1 ourselves (the same node the
 # renderer opens) and call drmSetMaster. If it succeeds, the kernel's
 # drmSetMaster path is observably working right now - drop master and
 # return. If it fails with EACCES, someone else holds master; wait
 # and retry. This is more reliable than polling debugfs because the
 # debugfs view can be stale relative to the actual drmSetMaster
 # state on the Pi4 vc4 driver (2026-06-12 reproduction: debugfs
 # would show 'no master' for seconds while drmSetMaster still
 # returned EACCES - the kernel's close->release handoff is visibly
 # not synchronous with the debugfs seq_file update).
 my $DRM_IOCTL_SET_MASTER=0x641e;   # 32-bit ARM, per AGENTS.md
 my $DRM_IOCTL_DROP_MASTER=0x641f;
 my $dev="/dev/dri/card1";
 if(!-r $dev || !-w $dev) {
  &log("DRM: $dev not accessible from daemon; using 500ms fallback sleep before renderer spawn");
  select(undef,undef,undef,0.5);
  return;
 }
 my $deadline=time() + $timeout;
 my $waited_ms=0;
 while(time() < $deadline) {
  # Open the device, try to take master, drop it, close. Each iteration
  # is a fresh drmSetMaster attempt that exercises the same code path
  # the renderer's first drmSetMaster will hit.
  if(sysopen(my $fh, $dev, O_RDWR)) {
   # Use ioctl() (not syscall()) - syscall() returned ENOSYS because
   # the proper entry point on Linux for ioctls goes through the
   # architecture's ioctl multiplexer, which Perl's syscall() doesn't
   # route correctly. ioctl() does the right thing.
   my $set_arg = 0;
   if(ioctl($fh, $DRM_IOCTL_SET_MASTER, $set_arg) == 0) {
    # We have master; drop it immediately. The kernel will fully
    # release by the time the next ioctl returns.
    my $drop_arg = 0;
    ioctl($fh, $DRM_IOCTL_DROP_MASTER, $drop_arg);
    close($fh);
    # Settle: even though ioctl(DROP_MASTER) returned 0, the
    # kernel's master release is visibly not synchronous with the
    # next open() on a hot Pi4 vc4 boot. The renderer's
    # drmSetMaster was returning EBUSY (Device or resource busy)
    # even 500ms after the drop. This used to sleep 2s on every
    # renderer start; the renderer now retries drmSetMaster for 2s
    # itself (InitDRM), so only a short settle is left here.
    select(undef,undef,undef,0.1);
    last;
   }
   if($waited_ms == 0) {
    &log(sprintf("DRM: probe drmSetMaster failed on first try: errno=%d (%s); will retry",
      $!, $!));
   }
   close($fh);
  } else {
   if($waited_ms == 0) {
    &log(sprintf("DRM: probe sysopen(%s) failed: %s", $dev, $!));
   }
  }
  $waited_ms+=50;
  select(undef,undef,undef,0.05);
 }
 &log(sprintf("DRM: master probe took %dms (timeout=%ds)", $waited_ms, $timeout));
}

# Return true if the pattern renderer (PGeneratord) currently holds DRM master
# on the KMS minor. Reads /sys/kernel/debug/dri/<N>/clients and looks for a row
# whose command is the renderer and whose master column is 'y'. This is the
# positive, stable signal that pattern_generator_start() gates the post-spawn
# connector reprogramming on: once the renderer owns master its fd is
# was_master=true, so the brief master steals by the root helpers are safe -
# the renderer re-acquires master after each helper drops it.
sub pattern_generator_has_drm_master (@) {
 # debugfs clients columns: command pid dev master a uid magic
 foreach my $clients (glob("/sys/kernel/debug/dri/*/clients")) {
  open(my $fh, '<', $clients) or next;
  while(my $line=<$fh>) {
   next if($line =~ /^\s*command\s+pid\b/);
   my @f=split(' ', $line);
   next if(@f < 4);
   if($f[0] =~ /PGeneratord/ && $f[3] eq 'y') {
    close($fh);
    return 1;
   }
  }
  close($fh);
 }
 return 0;
}

# Block until the renderer holds DRM master, or $timeout seconds elapse. The
# renderer drops master transiently during its own EGL/GBM init and re-acquires
# it, so poll rather than sample once. Returns 1 if it became master, 0 on
# timeout (caller proceeds anyway).
sub wait_for_renderer_drm_master (@) {
 my $timeout=shift;
 $timeout=8 if(!defined $timeout || $timeout <= 0);
 my $deadline=time() + $timeout;
 my $waited_ms=0;
 while(time() < $deadline) {
  if(&pattern_generator_has_drm_master()) {
   &log(sprintf("DRM: renderer holds master after %dms", $waited_ms));
   return 1;
  }
  $waited_ms+=50;
  select(undef,undef,undef,0.05);
 }
 &log(sprintf("DRM: renderer did not take master within %ds; proceeding (helpers may race)", $timeout));
 return 0;
}

###############################################
#   In-Place Renderer Reconfigure (SIGHUP)    #
###############################################
# Signal-setting changes (color format, range, colorimetry, bpc, HDR
# metadata) used to kill and respawn the renderer: several seconds of TERM
# polling, modetest writes that each grab DRM master, the master-handoff
# settle and a wrong picture meanwhile. A renderer that advertises
# "sighup-reconfigure" re-reads those keys from PGenerator.conf on SIGHUP,
# applies them in-process and acknowledges in $var_dir/running/reconfigured
# with "ok" (after its next page flip) or "reject <reason>". The default
# SIGHUP action terminates a process, so the signal is only ever sent when
# the running renderer itself wrote running/renderer-features (its pid plus
# "sighup-reconfigure") at startup.
#
# Arguments: hashref of the restart keys whose value changed, and an
# optional flag saying whether Dolby Vision was active before the change.
# Returns 1 when the renderer applied the change in place; 0 when it was not
# attempted, rejected, timed out or the renderer died - the caller then
# falls back to the full restart path.
sub renderer_supports_feature (@) {
 my $feature=shift;
 my $pid=shift;
 # The running renderer advertises its own capabilities at startup
 # ("pid <pid>" followed by one feature per line). A file shipped next to
 # the binary could outlive a binary swap, and SIGHUP terminates a
 # renderer that has no handler, so only trust a record written by the
 # very process we are about to signal.
 my $features_file=$renderer_features_file || "/var/lib/PGenerator/running/renderer-features";
 open(my $fh,'<',$features_file) or return 0;
 my ($owner,$found)=("",0);
 while(my $line=<$fh>) {
  $line=~s/^\s+|\s+$//g;
  $owner=$1 if($line=~/^pid\s+(\d+)$/);
  $found=1 if($line eq $feature);
 }
 close($fh);
 return 0 if(!$found);
 return 0 if(defined($pid) && $pid ne "" && $owner ne $pid);
 return 1;
}

sub renderer_dv_conf_active (@) {
 return 1 if(int($pgenerator_conf{"dv_status"} || 0) || int($pgenerator_conf{"is_ll_dovi"} || 0) || int($pgenerator_conf{"is_std_dovi"} || 0));
 return 0;
}

# The renderer reads rgb_quant_range only at startup or on an in-place
# reconfigure. Remember which value the current renderer process runs with
# ("<pid> <range>") so callers (Calman apply) can tell whether a conf change
# still has to reach the renderer or was already applied by
# apply_source_rgb_quant_range(). A file, not a shared variable: WebUI applies
# run in forked worker processes.
sub renderer_applied_range_record (@) {
 my $pid=&process_pid("$pattern_generator","get");
 $pid=&process_pid("${pattern_generator}.dv","get") if($pid eq "" && -x "${pattern_generator}.dv");
 my $path="$var_dir/running/renderer-applied-range";
 if($pid eq "" || $pid=~/\s/) {
  unlink($path);
  return;
 }
 my $range=$pgenerator_conf{"rgb_quant_range"};
 $range="" if(!defined $range);
 if(open(my $fh,'>',"$path.tmp")) {
  print $fh "$pid $range\n";
  close($fh);
  rename("$path.tmp",$path) or unlink("$path.tmp");
 }
}

sub renderer_has_applied_range (@) {
 my $range=$pgenerator_conf{"rgb_quant_range"};
 $range="" if(!defined $range);
 open(my $fh,'<',"$var_dir/running/renderer-applied-range") or return 0;
 my $line=<$fh>;
 close($fh);
 return 0 if(!defined $line || $line!~/^(\d+) (\S*)$/);
 my ($pid,$applied)=($1,$2);
 my $running=&process_pid("$pattern_generator","get");
 $running=&process_pid("${pattern_generator}.dv","get") if($running eq "" && -x "${pattern_generator}.dv");
 return ($running eq $pid && $applied eq $range) ? 1 : 0;
}

# Classic port 85 clients send their settings and then RESTARTPGENERATOR, or
# SET_MODE with the mode already set, on every connect (ColourSpace does both,
# with unchanged values). A restart re-commits the same mode from the same
# conf, so the signal on the cable stays the same, but the display resyncs
# twice: the exiting renderer resets the connector to RGB 8 bpc. Remember the
# conf the running renderer read ("<pid>" then its key=value lines), so such
# a restart can be skipped. A file: WebUI applies run in forked workers.
sub renderer_started_conf_path () { return "$var_dir/running/renderer-started-conf"; }

# The conf file as the renderer reads it at startup: {key=>value}, undef when
# it cannot be read or is empty.
sub renderer_conf_read (@) {
 my %c=();
 open(my $fh,'<',$pattern_conf) or return undef;
 while(my $l=<$fh>) {
  $l=~s/\r|\n//g;
  next if($l=~/^#/ || $l eq "");
  $l=~s/^\s//;
  $c{$1}=$2 if($l=~/(.*)=(.*)/);
 }
 close($fh);
 return %c ? \%c : undef;
}

sub renderer_conf_text (@) {
 my $c=shift;
 return "" if(ref($c) ne "HASH");
 return join("",map { "$_=$c->{$_}\n" } sort keys %$c);
}

sub renderer_running_pid (@) {
 my $pid=&process_pid("$pattern_generator","get");
 $pid=&process_pid("${pattern_generator}.dv","get") if($pid eq "" && -x "${pattern_generator}.dv");
 return $pid;
}

# $conf: the conf read just before the spawn. Recorded only when the conf
# still reads the same once the renderer runs; a write in between leaves no
# record, so the next classic restart really restarts.
sub renderer_started_conf_record (@) {
 my $conf=shift;
 my $path=&renderer_started_conf_path();
 my $pid=&renderer_running_pid();
 my $now=&renderer_conf_read();
 if($pid eq "" || $pid=~/\s/ || ref($conf) ne "HASH" || &renderer_conf_text($now) ne &renderer_conf_text($conf)) {
  unlink($path);
  return 0;
 }
 return &renderer_started_conf_write($pid,$conf);
}

# Write the record for renderer $pid (tmp + rename). Any failed step leaves
# no record, so the next check restarts rather than trusting a stale one.
sub renderer_started_conf_write (@) {
 my ($pid,$conf)=@_;
 my $path=&renderer_started_conf_path();
 if(open(my $fh,'>',"$path.tmp")) {
  my $ok=print $fh "$pid\n".&renderer_conf_text($conf);
  $ok=close($fh) && $ok;
  return 1 if($ok && rename("$path.tmp",$path));
  unlink("$path.tmp");
 }
 unlink($path);
 return 0;
}

# The record for the running renderer: {pid, conf}, undef when there is none
# or it belongs to another process.
sub renderer_started_conf_load (@) {
 open(my $fh,'<',&renderer_started_conf_path()) or return undef;
 my $pid=<$fh>;
 my %c=();
 while(my $l=<$fh>) {
  chomp($l);
  $c{$1}=$2 if($l=~/^([^=]*)=(.*)$/);
 }
 close($fh);
 return undef if(!defined $pid);
 chomp($pid);
 my $running=&renderer_running_pid();
 return undef if($pid !~ /^\d+$/ || $running ne $pid || !%c);
 return {pid=>$pid,conf=>\%c};
}

# 1 when the running renderer started with exactly the conf on disk now.
sub renderer_started_conf_current (@) {
 my $rec=&renderer_started_conf_load();
 my $now=&renderer_conf_read();
 return 0 if(!$rec || !$now);
 return (&renderer_conf_text($rec->{conf}) eq &renderer_conf_text($now)) ? 1 : 0;
}

# The conf the running renderer works from ({key=>value}, its start record,
# kept current by in-place reconfigures); undef when there is no record for
# it or it is not up (no DRM master, stuck in the HDMI driver). A Calman
# connection that has applied nothing yet compares against this, so its
# first apply restarts the renderer only for keys that really differ.
sub renderer_running_conf (@) {
 return undef if(!$is_kms || !&pattern_generator_is_running());
 return undef if(&renderer_stuck_in_kernel() ne "" || !&pattern_generator_has_drm_master());
 my $rec=&renderer_started_conf_load();
 return $rec ? $rec->{conf} : undef;
}

# Daemon bookkeeping the renderer does not read (main.cpp readPGeneratorConf,
# drm_override.so parse_config) and no start step acts on: both follow from
# is_hdr/eotf/dv_* (normalize_signal_mode_conf rewrites signal_mode on every
# start), so a Calman "hdr" against the "hdr10" a start writes is one mode.
sub renderer_conf_bookkeeping_keys () { return qw(signal_mode is_sdr); }

# After an in-place reconfigure the renderer has re-read the keys it takes in
# place ($in_place: {key=>1}). The record follows what the renderer now
# holds: those keys and the bookkeeping above from the file, every other key
# as it read it at start. A key that still differs keeps the record unequal
# to the file, so the next classic restart restarts, and a Calman apply
# compares the renderer's real value. Dropping the record instead made the
# next connection's first apply restart for any difference, even signal_mode
# "hdr" vs "hdr10". Returns 1 when the file matches the record.
sub renderer_started_conf_refresh (@) {
 my $in_place=shift || {};
 my $rec=&renderer_started_conf_load();
 my $now=&renderer_conf_read();
 if(!$rec || !$now) {
  unlink(&renderer_started_conf_path());
  return 0;
 }
 my %bookkeeping=map { $_=>1 } &renderer_conf_bookkeeping_keys();
 my %conf=%{$rec->{conf}};
 for my $k (keys %$now) {
  # readPGeneratorConf keeps the current value of a key missing from the
  # file, so only keys present in it are taken over.
  $conf{$k}=$now->{$k} if($in_place->{$k} || $bookkeeping{$k});
 }
 for my $k (keys %bookkeeping) {
  delete $conf{$k} if(!defined $now->{$k});
 }
 return 0 if(!&renderer_started_conf_write($rec->{pid},\%conf));
 return (&renderer_conf_text(\%conf) eq &renderer_conf_text($now)) ? 1 : 0;
}

# RESTARTPGENERATOR and SET_MODE from classic clients: restart the renderer
# unless the running one already sends these settings. "Running" means it
# holds DRM master and is not stuck in the HDMI driver; anything else
# restarts as before. Returns 1 when it restarted.
sub pattern_generator_restart_unless_current (@) {
 my $who=shift || "Restart";
 my $current=0;
 if($is_kms) {
  &renderer_lock();
  $current=(&pattern_generator_is_running() && !&renderer_stuck_in_kernel() &&
            &pattern_generator_has_drm_master() && &renderer_started_conf_current()) ? 1 : 0;
  &renderer_unlock();
 }
 if($current) {
  &log("Renderer: $who with unchanged settings; the running renderer already sends them (no restart)");
  return 0;
 }
 &pattern_generator_stop();
 &pattern_generator_start();
 return 1;
}

sub renderer_reconfigure_in_place (@) {
 my ($changed,$dv_before)=@_;
 my %in_place_keys=map{$_=>1} qw(color_format rgb_quant_range colorimetry max_bpc eotf
  max_cll max_fall max_luma min_luma primaries);
 my @keys=sort grep { $changed->{$_} } keys %{$changed || {}};
 my $what=join(",",@keys);
 return 0 if(!$is_kms);
 if(!@keys) {
  &log("Renderer reconfigure: no changed keys given; using the restart path");
  return 0;
 }
 my @restart_only=grep { !$in_place_keys{$_} } @keys;
 if(@restart_only) {
  &log("Renderer reconfigure: ".join(",",@restart_only)." changed and needs a renderer restart");
  return 0;
 }
 if($dv_before || &renderer_dv_conf_active()) {
  &log("Renderer reconfigure: Dolby Vision is active; using the restart path for $what");
  return 0;
 }
  if(-x "${pattern_generator}.dv" && &process_pid("${pattern_generator}.dv","get") ne "") {
  &log("Renderer reconfigure: the Dolby Vision renderer is running; restarting for $what");
  return 0;
 }
 # HDR10/HLG are BT.2020 signals. A restart pins colorimetry 9
 # (normalize_signal_mode_conf); the reload in place keeps the same rule
 # for a value that got into the conf in HDR. The renderer reads the file,
 # so that is what counts. The memory copy changes only once the file is
 # written: after a failed write the restart path still sees the old value
 # and pins it again.
 my $file_conf=&renderer_conf_read();
 if(!$file_conf) {
  &log("Renderer reconfigure: $pattern_conf is unreadable; using the restart path for $what");
  return 0;
 }
 if(int($file_conf->{"is_hdr"} || 0) == 1 && ($file_conf->{"colorimetry"} // "") ne "9") {
  if((&sudo("SET_PGENERATOR_CONF_MULTI","colorimetry","9") || "")!~/^\Q$ok_response\E/) {
   $pgenerator_conf{"colorimetry"}=$file_conf->{"colorimetry"} // "";
   &log("Renderer reconfigure: colorimetry 9 for HDR could not be written; using the restart path for $what");
   return 0;
  }
  $pgenerator_conf{"colorimetry"}="9";
  &log("Renderer reconfigure: HDR colorimetry ".($file_conf->{"colorimetry"} // "")." set to 9 (BT.2020)");
 }
 my $pid=&process_pid("$pattern_generator","get");
 if($pid eq "" || $pid=~/\s/) {
  &log("Renderer reconfigure: ".($pid eq "" ? "renderer is not running" : "several renderer processes ($pid)")."; using the restart path for $what");
  return 0;
 }
 if(!&renderer_supports_feature("sighup-reconfigure",$pid)) {
  &log("Renderer reconfigure: renderer pid $pid does not advertise sighup-reconfigure; restarting for $what");
  return 0;
 }
 # A renderer that is still initializing may not have installed its SIGHUP
 # handler yet, and it reprograms the connector from conf on its first
 # commit anyway. Only signal a renderer that is up and owns DRM master.
 if(!&pattern_generator_has_drm_master()) {
  &log("Renderer reconfigure: renderer pid $pid does not hold DRM master yet; using the restart path for $what");
  return 0;
 }
 # Serialize reconfigures (WebUI apply worker vs. calibration threads) so
 # one caller cannot consume or delete the other's acknowledgement.
 require Fcntl;
 my $lock;
 if(open($lock,'>',&pgen_lock_path("renderer-reconfigure.lock"))) {
  flock($lock,Fcntl::LOCK_EX());
 } else {
  undef $lock;
 }
 my $ack="$var_dir/running/reconfigured";
 unlink($ack);
 if(-e $ack) {
  &log("Renderer reconfigure: cannot remove stale $ack ($!); using the restart path");
  close($lock) if($lock);
  return 0;
 }
 my $t0=Time::HiRes::time();
 if(!kill('HUP',$pid)) {
  &log("Renderer reconfigure: cannot signal renderer pid $pid ($!); using the restart path");
  close($lock) if($lock);
  return 0;
 }
 my $result=0;
 my $reason="no acknowledgement within 3s";
 my $deadline=$t0+3;
 while(Time::HiRes::time() < $deadline) {
  select(undef,undef,undef,0.05);
  if(open(my $fh,'<',$ack)) {
   my $line=<$fh>;
   close($fh);
   if(defined $line && $line=~/\n$/) {
    $line=~s/\s+$//;
    if($line eq "ok") {
     $result=1;
     $reason="";
    } elsif($line=~/^reject\s*(.*)$/) {
     $reason="renderer rejected: ".($1 ne "" ? $1 : "no reason given");
    } else {
     $reason="unexpected acknowledgement '$line'";
    }
    last;
   }
  }
  if(!kill(0,$pid)) {
   $reason="renderer pid $pid exited after SIGHUP";
   last;
  }
 }
 $result=0 if($result && !kill(0,$pid));
 close($lock) if($lock);
 my $ms=int((Time::HiRes::time()-$t0)*1000);
 if($result) {
  &log("Renderer reconfigure: applied $what in place in ${ms}ms (pid $pid)");
  &renderer_applied_range_record();
  &renderer_started_conf_refresh(\%in_place_keys);
  return 1;
 }
 &log("Renderer reconfigure: $what not applied in place after ${ms}ms ($reason); falling back to a renderer restart");
 return 0;
}

sub apply_hdr_metadata_helper (@) {
 my $helper="/usr/bin/pgsethdr";
 return if(!$is_kms || !-x $helper);
 if(int($pgenerator_conf{"dv_status"} || 0) == 1 || int($pgenerator_conf{"is_ll_dovi"} || 0) == 1 || int($pgenerator_conf{"is_std_dovi"} || 0) == 1) {
  &log("DRM: skipping HDR metadata helper while Dolby Vision metadata is active");
  return;
 }
 # pgsethdr is a pre-set safety net for when NO renderer is alive (boot,
 # idle). Since commit 84ed1cc7 the renderer reads the HDR conf on every
 # updateHDR_Infoframe() call and owns the wire blob, so running pgsethdr
 # alongside a renderer is pointless - and running it while a renderer is
 # INITIALIZING steals DRM master at the exact moment the renderer calls
 # drmSetMaster, killing it. This was the root cause of "Pattern renderer
 # failed to start" on every WebUI HDR apply (SDR applies never call this
 # helper, which is why they always survived). A/B-proven on the Pi4:
 # with pgsethdr disabled the HDR apply succeeds on the first attempt.
 if(&pattern_generator_is_running()) {
  &log("DRM: skipping pgsethdr while the renderer is running (renderer owns the HDR blob)");
  return;
 }
 my $output=`timeout 5 $helper 2>&1`;
 chomp($output);
 if($? != 0) {
  &log("DRM: pgsethdr failed".($output ne "" ? " — $output" : ""));
  return;
 }
 &log("DRM: $output") if($output ne "");
}

###############################################
#       Pattern Generator Start Function      #
###############################################
# True when an HDMI sink is attached. Without one the renderer cannot get a
# connector and exits at once, and the start/retry ladder then spends a minute
# waiting for DRM master: at boot that delays the WebUI and mDNS past the
# watchdog's probe, which restarts PGenerator every minute. Missing sysfs
# entries (non-KMS) never block a start.
# The kernel shows the fbdev buffer whenever the renderer releases DRM (every
# signal-mode switch). rcPGenerator unbinds the text console and leaves the
# boot splash in it; once a renderer has run, paint it black so switches show
# black instead of the splash. Done once per daemon (nothing else draws on it).
my $console_framebuffer_blanked=0;
sub blank_console_framebuffer (@) {
 return if($console_framebuffer_blanked || !$is_kms);
 my $fb="/dev/fb0";
 return if(! -c $fb);
 my ($w,$h,$bpp)=(0,0,0);
 if(open(my $sfh,"<","/sys/class/graphics/fb0/virtual_size")) {
  (($w,$h)=split(/,/,scalar(<$sfh>) || "")); close($sfh);
 }
 if(open(my $bfh,"<","/sys/class/graphics/fb0/bits_per_pixel")) {
  $bpp=int(scalar(<$bfh>) || 0); close($bfh);
 }
 my $size=int($w || 0)*int($h || 0)*int($bpp/8);
 return if($size <= 0);
 if(open(my $fh,">",$fb)) {
  binmode($fh);
  print $fh ("\0" x $size);
  close($fh);
  $console_framebuffer_blanked=1;
 } else {
  &log("Renderer: cannot blank $fb: $!");
 }
}

sub hdmi_sink_connected (@) {
 return 1 if(!$is_kms);
 my $seen=0;
 foreach my $status (glob("/sys/class/drm/card*-HDMI-A-*/status")) {
  $seen=1;
  open(my $fh,"<",$status) or next;
  my $state=<$fh>;
  close($fh);
  return 1 if(defined $state && $state=~/^connected/);
 }
 return $seen ? 0 : 1;
}

###############################################
#     Refused settings (PGSignalCheck.pm)     #
###############################################
# A setting the board or the display cannot carry is refused at the apply
# point instead of going out changed: the output stays as it was, the WebUI
# shows the reason, and while a calibration program is left in a refused
# state its patches are refused too, so nothing is measured in a mode that
# was not selected. The modules are loaded with require: command.pm is also
# loaded by the sudo helper, which never needs them.

# Keys that make up the signal on the cable; restored together when an
# apply is refused.
our @signal_conf_keys=qw(mode_idx signal_mode is_sdr is_hdr eotf colorimetry
 primaries color_format max_bpc rgb_quant_range dv_status is_ll_dovi
 is_std_dovi dv_interface dv_transport dv_metadata dv_map_mode dv_color_space
 dv_profile);
# HDR metadata the renderer reads while it runs: snapshotted and put back
# with the signal keys, so a refused apply leaves the output as it was.
# Optional in a snapshot: one written before they were added still
# restores the signal keys.
our @signal_metadata_keys=qw(min_luma max_luma max_cll max_fall);

# Connected HDMI port and its EDID file.
sub signal_connected_port (@) {
 foreach my $status (sort glob("/sys/class/drm/card*-HDMI-A-*/status")) {
  open(my $fh,"<",$status) or next;
  my $state=<$fh>;
  close($fh);
  next if(!defined $state || $state!~/^connected/);
  my ($dir,$port)=$status=~m{^(.*/card\d+-(HDMI-A-\d+))/status$};
  return ($port,"$dir/edid") if($port);
 }
 return ("","");
}

# The connector the renderer drives: the one bound to a CRTC in the atomic
# state, printed by drm_atomic_connector_print_state() as
# "connector[N]: HDMI-A-x" then "\tcrtc=crtc-M" or "\tcrtc=(null)". When the
# cable moves to the other port the renderer stays on the old connector
# until it restarts, so the connector status alone cannot tell.
our $dri_state_glob="/sys/kernel/debug/dri/*/state";
sub signal_renderer_port (@) {
 foreach my $st (glob($dri_state_glob)) {
  open(my $fh,"<",$st) or next;
  local $/;
  my $t=<$fh>;
  close($fh);
  next if(!defined $t);
  while($t=~/^connector\[\d+\]: (HDMI-A-\d+)\n\s*crtc=(\S+)/mg) {
   return $1 if($2 ne "(null)");
  }
 }
 return "";
}

# What the connected display declares (PGEdidCaps), its Dolby Vision block
# and the port. {known=>0} without a display or EDID.
sub signal_display_caps (@) {
 require PGEdidCaps;
 require PGEdidDolby;
 my ($port,$edid_path)=&signal_connected_port();
 my $raw="";
 if($edid_path ne "" && open(my $fh,"<:raw",$edid_path)) {
  local $/;
  $raw=<$fh>;
  close($fh);
  $raw="" if(!defined $raw);
 }
 my $caps=PGEdidCaps::edid_caps_from_raw($raw);
 my $dv=(length($raw) >= 256) ? PGEdidDolby::dolby_vsvdb_from_edid($raw) : undef;
 return ($caps,$dv,$port,$raw);
}

# Mode $idx of the connected connector as modetest lists it; -1 or empty is
# the mode the renderer falls back to (the preferred one).
sub signal_mode_info (@) {
 my $idx=shift;
 my $out=shift;
 $out=`timeout 3 $modetest -c 2>/dev/null` if(!defined $out);
 $out="" if(!defined $out);
 my ($first,$preferred,$hit);
 while($out=~/^\s*#(\d+)\s+(\d+)x(\d+)(i?)\s+([\d.]+)\s+(?:\d+\s+){8}(\d+)\s+flags:[^;\n]*;\s*type:\s*([^\n]*)/gm) {
  my $m={idx=>$1,width=>int($2),height=>int($3),interlaced=>($4 eq "i") ? 1 : 0,
         refresh=>$5+0,clock_khz=>int($6),type=>$7};
  $first=$m if(!$first);
  $preferred=$m if(!$preferred && $m->{type}=~/preferred/);
  if(defined $idx && $idx ne "" && $idx ne "-1" && $m->{idx} eq "$idx") {
   $hit=$m;
   last;
  }
 }
 return $hit if($hit);
 return {} if(defined $idx && $idx ne "" && $idx ne "-1");
 return $preferred || $first || {};
}

# Signal mode from the flags the renderer reads.
sub signal_mode_from_conf (@) {
 my $conf=shift;
 return "dv" if(int($conf->{"dv_status"} || 0) || int($conf->{"is_ll_dovi"} || 0) || int($conf->{"is_std_dovi"} || 0));
 return (int($conf->{"eotf"} || 0) == 3) ? "hlg" : "hdr10" if(int($conf->{"is_hdr"} || 0));
 return "sdr";
}

sub signal_request_from_conf (@) {
 my $conf=shift || \%pgenerator_conf;
 my $modetest_out=shift;
 my $mode=&signal_mode_info($conf->{"mode_idx"},$modetest_out);
 return {%$mode,
  color_format=>int($conf->{"color_format"} || 0),
  max_bpc=>int($conf->{"max_bpc"} || 8),
  rgb_quant_range=>int($conf->{"rgb_quant_range"} || 0),
  signal_mode=>&signal_mode_from_conf($conf),
  dv_transport=>&pg_dv_transport_mode($conf->{"dv_transport"})};
}

# Check a conf (hashref; default the live one). Returns ($result,$request).
sub signal_check_conf (@) {
 my $conf=shift || \%pgenerator_conf;
 my $modetest_out=shift;
 require PGSignalCheck;
 my ($caps,$dv,$port)=&signal_display_caps();
 my $req=&signal_request_from_conf($conf,$modetest_out);
 my $board=PGSignalCheck::signal_board_limits($device_model,$port);
 my $r=PGSignalCheck::signal_check($req,$board,$caps,dv_vsvdb=>$dv);
 return ($r,$req,$board,$caps);
}

# "10-bit RGB Full, 3840x2160 60 Hz, HDR10"
sub signal_request_label (@) {
 my $req=shift;
 require PGSignalCheck;
 my @p=(PGSignalCheck::signal_format_label($req->{color_format},$req->{color_format} == 2 ? 0 : $req->{max_bpc}));
 my %range=(1=>"Limited",2=>"Full");
 $p[0].=" ".$range{$req->{rgb_quant_range}} if($range{$req->{rgb_quant_range} || 0});
 my $mode=PGSignalCheck::signal_mode_label($req);
 push(@p,$mode) if($mode ne "");
 push(@p,PGSignalCheck::signal_hdr_label($req));
 return join(", ",@p);
}

sub _signal_state_escape (@) {
 my $v=shift;
 $v="" if(!defined $v);
 $v=~s/\\/\\\\/g;
 $v=~s/\n/\\n/g;
 return $v;
}

sub _signal_state_write (@) {
 my ($file,%f)=@_;
 mkdir($signal_state_dir) if(!-d $signal_state_dir);
 my $tmp="$file.$$.tmp";
 open(my $fh,">",$tmp) or return 0;
 print $fh "$_=".&_signal_state_escape($f{$_})."\n" foreach(sort keys %f);
 close($fh) or return 0;
 return rename($tmp,$file) ? 1 : 0;
}

sub _signal_state_read (@) {
 my $file=shift;
 open(my $fh,"<",$file) or return undef;
 my %f;
 while(my $line=<$fh>) {
  chomp($line);
  next if($line!~/^(\w+)=(.*)$/);
  my ($k,$v)=($1,$2);
  $v=~s/\\(n|\\)/$1 eq "n" ? "\n" : "\\"/ge;
  $f{$k}=$v;
 }
 close($fh);
 return \%f;
}

# The signal keys as last let through (or found at daemon start): what a
# refused apply goes back to.
sub signal_applied_snapshot_write (@) {
 my $conf=shift || \%pgenerator_conf;
 my %f=map {("conf_$_"=>defined($conf->{$_}) ? "$conf->{$_}" : "")} (@signal_conf_keys,@signal_metadata_keys);
 $f{time}=time();
 return 1 if(&_signal_state_write($signal_applied_file,%f));
 # A later refusal then goes back to an older snapshot, or refuses without
 # one (signal_gate_conf says so).
 &log("Signal: could not write $signal_applied_file: $!") if(defined &log);
 return 0;
}

sub signal_applied_snapshot_read (@) {
 my $f=&_signal_state_read($signal_applied_file);
 return undef if(!$f);
 my %conf;
 foreach my $k (@signal_conf_keys) {
  return undef if(!exists $f->{"conf_$k"});
  $conf{$k}=$f->{"conf_$k"};
 }
 foreach my $k (@signal_metadata_keys) {
  $conf{$k}=$f->{"conf_$k"} if(exists $f->{"conf_$k"});
 }
 return \%conf;
}

# Put the signal keys and the HDR metadata back to $snapshot (conf file and
# %pgenerator_conf). Returns 1 when every key was written.
sub signal_restore_conf (@) {
 my $snapshot=shift;
 return 0 if(!$snapshot);
 my @keys=(@signal_conf_keys,grep { exists $snapshot->{$_} } @signal_metadata_keys);
 my (@deletes,@batch);
 foreach my $k (@keys) {
  my $want=defined($snapshot->{$k}) ? "$snapshot->{$k}" : "";
  my $cur=defined($pgenerator_conf{$k}) ? "$pgenerator_conf{$k}" : "";
  next if($want eq $cur);
  # One write for the whole restore. An empty value deletes its key,
  # before the other keys are set (the order singly written deletes had).
  if($want eq "") { push(@deletes,$k,""); }
  else { push(@batch,$k,$want); }
  $pgenerator_conf{$k}=$want;
 }
 &sudo("SET_PGENERATOR_CONF_MULTI",@deletes,@batch) if(@deletes || @batch);
 # Read back: a failed write must not pass as restored, and memory follows
 # the file the renderer reads, so the next check sees what is really set.
 my %disk=&signal_conf_from_disk();
 my $ok=1;
 foreach my $k (@keys) {
  my $want=defined($snapshot->{$k}) ? "$snapshot->{$k}" : "";
  my $got=defined($disk{$k}) ? "$disk{$k}" : "";
  next if($want eq $got);
  $ok=0;
  $pgenerator_conf{$k}=$got;
 }
 return $ok;
}

sub signal_conf_from_disk (@) {
 my %c;
 open(my $fh,"<",$pattern_conf) or return %c;
 while(my $line=<$fh>) {
  chomp($line);
  $c{$1}=$2 if($line=~/^\s*([^=#\s]+)\s*=\s*(.*?)\s*$/);
 }
 close($fh);
 return %c;
}

# HDMI link events (webui.pm webui_hdmi_link_watch): one line each, tab
# separated: id, time, event (lost|back|changed), during (what was running,
# "" when nothing was measured), text. The last 20 are kept.
sub hdmi_link_event_add (@) {
 my %e=@_;
 mkdir($signal_state_dir) if(!-d $signal_state_dir);
 my @lines;
 if(open(my $fh,"<",$hdmi_link_events_file)) { @lines=<$fh>; close($fh); }
 my $clean=sub { my $v=shift; $v="" if(!defined $v); $v=~s/[\t\r\n]+/ /g; return $v; };
 push(@lines,join("\t",map {$clean->($_)} ($e{id},$e{time},$e{event},$e{during},$e{text}))."\n");
 @lines=@lines[-20..-1] if(@lines > 20);
 my $tmp="$hdmi_link_events_file.$$.tmp";
 open(my $out,">",$tmp) or return 0;
 print $out @lines;
 close($out);
 return rename($tmp,$hdmi_link_events_file) ? 1 : 0;
}

sub hdmi_link_events (@) {
 my @ev;
 open(my $fh,"<",$hdmi_link_events_file) or return @ev;
 while(my $line=<$fh>) {
  chomp($line);
  my @f=split(/\t/,$line,5);
  next if(@f < 4);
  push(@ev,{id=>$f[0],time=>$f[1],event=>$f[2],during=>$f[3],text=>defined($f[4]) ? $f[4] : ""});
 }
 close($fh);
 return @ev;
}

# The last interruption during a measurement, with its return if any.
sub hdmi_link_last_event (@) {
 my @ev=&hdmi_link_events();
 for(my $i=$#ev;$i>=0;$i--) {
  next if($ev[$i]{during} eq "" || $ev[$i]{event} eq "back");
  return $ev[$i];
 }
 return undef;
}

# Daemon start: no refusal carries over, the conf found now is what a
# refused apply goes back to.
# One line "<uptime> <what>" in $boot_times_file. Uptime, not the clock:
# until NTP has run the clock is whatever fake-hwclock saved.
sub boot_time_mark (@) {
 my $what=shift;
 my $up="";
 if(open(my $fh,"<","/proc/uptime")) { $up=(split(/\s+/,<$fh> // ""))[0] // ""; close($fh); }
 return 0 if($up eq "" || !defined $boot_times_file || $boot_times_file eq "");
 open(my $out,">>",$boot_times_file) or return 0;
 print $out "$up $what\n";
 close($out);
 return 1;
}

sub signal_state_reset (@) {
 mkdir($signal_state_dir) if(!-d $signal_state_dir);
 {
  lock(%signal_refused_mem);
  %signal_refused_mem=();
 }
 unlink($signal_refused_file);
 unlink($hdmi_link_events_file);
 &signal_applied_snapshot_write();
}

# Refused state: set by a refused apply from a calibration program, cleared
# by the next apply that passes, when that program disconnects, or by a
# daemon restart (signal_state_reset). The daemon holds it in
# %signal_refused_mem (shared with the WebUI and Resolve threads) and writes
# it to $signal_refused_file for the WebUI and the logs: a write that fails
# must not let the next patch through. owner is the pattern socket of the
# program that asked ($signal_gate_owner, daemon.pm close_connection).
sub signal_refused_set (@) {
 my %f=@_;
 $f{time}=time() if(!$f{time});
 {
  lock(%signal_refused_mem);
  %signal_refused_mem=map { ($_ => defined($f{$_}) ? "$f{$_}" : "") } keys(%f);
 }
 return 1 if(&_signal_state_write($signal_refused_file,%f));
 &log("Signal: could not write $signal_refused_file: $!; the refusal stays in effect") if(defined &log);
 return 0;
}

sub signal_refused_read (@) {
 {
  lock(%signal_refused_mem);
  return {%signal_refused_mem} if(%signal_refused_mem);
 }
 return undef if(!-e $signal_refused_file);
 return &_signal_state_read($signal_refused_file);
}

# The socket the refusal belongs to, "" when it was not set from one.
sub signal_refused_owner (@) {
 my $f=&signal_refused_read();
 return ($f && defined $f->{owner}) ? $f->{owner} : "";
}

sub signal_refused_clear (@) {
 my $why=shift || "";
 my $had=0;
 {
  lock(%signal_refused_mem);
  $had=1 if(%signal_refused_mem);
  %signal_refused_mem=();
 }
 $had=1 if(-e $signal_refused_file);
 unlink($signal_refused_file);
 return 0 if(!$had);
 &log("Signal: refused state cleared".($why ne "" ? " ($why)" : "")) if(defined &log);
 return 1;
}

# Reason text while patches are refused, "" otherwise.
sub signal_patches_refused (@) {
 {
  lock(%signal_refused_mem);
  return ((defined $signal_refused_mem{reason} && $signal_refused_mem{reason} ne "") ? $signal_refused_mem{reason} : "The requested signal settings were refused.") if(%signal_refused_mem);
 }
 return "" if(!-e $signal_refused_file);
 # A state file that cannot be read still means refused (fail closed).
 my $f=&signal_refused_read();
 return ($f && $f->{reason}) ? $f->{reason} : "The requested signal settings were refused.";
}

# Name for the program asking: the given one, else the connected client.
sub signal_source_label (@) {
 my $name=shift;
 return $name if(defined $name && $name ne "");
 return $calibration_client_software if(defined $calibration_client_software && $calibration_client_software ne "");
 return "Calibration software";
}

# The gate for calibration programs (Calman, port 85 clients): the conf
# already holds what they asked for. Passes: snapshot it, end any refused
# state, return 1. Refused: put the conf back to the snapshot, record the
# refusal, leave a WebUI notice, return 0. The caller then skips the
# renderer apply, so the output stays as it was.
sub signal_gate_conf (@) {
 my ($source,$modetest_out)=@_;
 $source="Calibration software" if(!$source);
 my ($r,$req)=eval { &signal_check_conf(\%pgenerator_conf,$modetest_out) };
 if(!$r) {
  # The check itself failing must not block calibration.
  &log("Signal: check failed (".($@ || "no result")."), letting the apply through") if(defined &log);
  return 1;
 }
 foreach my $a (@{$r->{adjustments} || []}) {
  &log("Signal: $source: $a") if(defined &log);
 }
 if($r->{ok}) {
  &signal_applied_snapshot_write(\%pgenerator_conf);
  &signal_refused_clear("$source chose settings that work");
  return 1;
 }
 my $requested=&signal_request_label($req);
 my $snapshot=&signal_applied_snapshot_read();
 my $restored=$snapshot ? &signal_restore_conf($snapshot) : 0;
 my $kept=$snapshot ? &signal_request_label(&signal_request_from_conf($snapshot,$modetest_out)) : "";
 my $alt=@{$r->{alternatives} || []} ? "Works here: ".join(", ",@{$r->{alternatives}})."." : "";
 # The reply to the command that asked carries the refusal (daemon.pm
 # send_key_to_client: NAK for Calman).
 $signal_refused_pending=1;
 &signal_refused_set(source=>$source,reason=>$r->{reason},code=>$r->{code},
                     requested=>$requested,kept=>$kept,alternatives=>$alt,
                     restored=>$restored ? 1 : 0,owner=>defined($signal_gate_owner) ? $signal_gate_owner : "");
 &log("Signal: $source asked for $requested: refused: $r->{reason}".($restored ? " Output kept: $kept." : " Conf could not be restored.")) if(defined &log);
 my $text="$source asked for $requested. $r->{reason}";
 $text.="\n$alt" if($alt ne "");
 $text.=$restored ? "\nThe output stays $kept, and patches are refused until settings that work are chosen."
                  : "\nThe previous settings could not be restored. Patches are refused until settings that work are chosen.";
 &webui_notice("Settings refused",$text) if(defined &webui_notice);
 return 0;
}

# Marker for a renderer start that was deferred because no display was
# attached. It lives outside $var_dir/running (clean_files wipes that) and is
# shared by the daemon and its WebUI threads/workers, so the main loop can
# start the renderer once a display is plugged in - but never restarts a
# renderer that was stopped on purpose (e.g. for video playback).
sub renderer_waiting_for_hdmi_path (@) {
 return "/tmp/pgenerator-renderer-waiting-for-hdmi";
}

sub renderer_waiting_for_hdmi (@) {
 return -e &renderer_waiting_for_hdmi_path() ? 1 : 0;
}

our $hdmi_status_glob="/sys/class/drm/card*-HDMI-A-*/status";
our $renderer_port_restart_last=0;

# Names of the connected HDMI connectors (HDMI-A-1, HDMI-A-2).
sub hdmi_connected_ports (@) {
 my @ports;
 foreach my $status (sort glob($hdmi_status_glob)) {
  open(my $fh,"<",$status) or next;
  my $state=<$fh>;
  close($fh);
  next if(!defined $state || $state!~/^connected/);
  push(@ports,$1) if($status=~m{card\d+-(HDMI-A-\d+)/status$});
 }
 return @ports;
}

# The cable moved to the other port while the renderer runs: it keeps its
# CRTC on the old, now disconnected connector and the display gets no
# signal until the renderer starts again (audit 2026-10-25, HDMI0 -> HDMI1).
# Restart it like "Restart output" does; at most once a minute, so a
# renderer that comes back on the old connector does not restart forever.
sub renderer_follow_connected_port (@) {
 my $driving=&signal_renderer_port();
 return 0 if($driving eq "");
 my @connected=&hdmi_connected_ports();
 return 0 if(!@connected || grep { $_ eq $driving } @connected);
 return 0 if(time()-$renderer_port_restart_last < 60);
 $renderer_port_restart_last=time();
 &log("Renderer: drives $driving, but the display is on ".join(",",@connected)."; restarting the renderer");
 &pattern_generator_stop();
 &pattern_generator_start();
 &load_new_pattern_file("hdmi port change") if(!&pattern_generator_is_running());
 return 1;
}

# Called from the daemon's idle tick (every 5s without socket traffic).
sub renderer_start_when_hdmi_connected (@) {
 if(!&hdmi_sink_connected()) {
  # The display went away (the renderer exits on its page-flip timeout):
  # remember it so the renderer comes back when the display does.
  if(!&renderer_waiting_for_hdmi() && open(my $wfh,">",&renderer_waiting_for_hdmi_path())) {
   close($wfh);
   &log("Renderer: HDMI display disconnected; the renderer restarts when one is plugged in");
  }
  return;
 }
 if(!&renderer_waiting_for_hdmi()) {
  &renderer_follow_connected_port() if(&pattern_generator_is_running());
  return;
 }
 if(&pattern_generator_is_running()) {
  unlink(&renderer_waiting_for_hdmi_path());
  return;
 }
 &log("Renderer: HDMI display connected; starting the deferred renderer");
 # Same start as at boot: shows PatternStart (black) instead of an empty
 # renderer. The retry ladder takes over if that start loses the DRM race.
 &pattern_generator_start();
 &load_new_pattern_file("hdmi hotplug") if(!&pattern_generator_is_running());
 # The boot start was deferred until now, so show the boot pattern here.
 &show_boot_pattern() if(defined &show_boot_pattern);
}

###############################################
#           Renderer Lock Functions           #
###############################################
# Lock files live in $var_dir/locks: clean_files() empties $var_dir and
# running/ on every renderer stop. A lock file deleted there let the next
# caller lock a new inode while the first one still held the old: with
# rapid WebUI applies two workers then started renderers at the same time
# and vc4 oopsed (drm_atomic_set_crtc_for_plane), leaving the renderer in
# D state until a reboot.
sub pgen_lock_path (@) {
 my $name=shift;
 my $dir="$var_dir/locks";
 mkdir($dir) if(!-d $dir);
 return "$dir/$name";
}

# Renderer start and stop form one critical section across threads and
# processes (flock on separate opens). A nested call from the same thread
# (stop -> video_program_stop -> start) only counts up.
my $renderer_lock_fh;
my $renderer_lock_depth=0;
sub renderer_lock () {
 return if($renderer_lock_depth++);
 require Fcntl;
 if(open($renderer_lock_fh,'>',&pgen_lock_path("renderer.lock"))) {
  flock($renderer_lock_fh,Fcntl::LOCK_EX());
 } else {
  &log("Renderer: cannot open the renderer lock: $!");
  undef $renderer_lock_fh;
 }
}

sub renderer_unlock () {
 return if($renderer_lock_depth <= 0 || --$renderer_lock_depth);
 close($renderer_lock_fh) if($renderer_lock_fh);
 undef $renderer_lock_fh;
}

# A forked child shares the open lock descriptions of every thread of its
# parent; flock locks belong to those, so the child would hold a lock it
# does not know about and block on its own next renderer_lock(). Call this
# first thing after fork().
sub pgen_drop_inherited_locks () {
 require POSIX;
 my $dir=&pgen_lock_path("");
 $dir=~s{/+$}{};
 if(opendir(my $fds,"/proc/self/fd")) {
  for my $fd (readdir($fds)) {
   next if($fd !~ /^\d+$/ || $fd <= 2);
   my $target=readlink("/proc/self/fd/$fd");
   next if(!defined $target);
   $target=~s{/+}{/}g;
   (my $want=$dir)=~s{/+}{/}g;
   POSIX::close($fd) if(index($target,"$want/") == 0);
  }
  closedir($fds);
 }
 undef $renderer_lock_fh;
 $renderer_lock_depth=0;
}

sub pattern_generator_start(@) {
 my $no_clean_files = shift;
 my $use_drm_override=1;
 my $has_dovi_metadata=1;
 &renderer_lock();
 # Another caller (Calman thread, apply worker, hotplug) may have started
 # one while this one waited: a second renderer on the same CRTC is what
 # crashed vc4.
 if(&pattern_generator_is_running()) {
  &log("Renderer: start skipped, a renderer is already running");
  &renderer_unlock();
  return;
 }
 # After a kernel oops in the HDMI driver the crashed renderer stays in the
 # kernel holding the DRM modeset lock: a new renderer would hang on it too.
 # Only a reboot clears it.
 if(my $stuck=&renderer_stuck_in_kernel()) {
  &log("Renderer: not started: renderer $stuck is stuck in the HDMI driver after a kernel error; restart the Pi");
  &renderer_unlock();
  return;
 }
 &clean_files() if(!$no_clean_files);
 mkdir("$var_dir/running/tmp") if(!-d "$var_dir/running/tmp");
 if(-e "$var_dir/operations.txt" && !-l "$var_dir/operations.txt") {
  unlink("$var_dir/operations.txt");
 }
 symlink("running/operations.txt","$var_dir/operations.txt") if(!-e "$var_dir/operations.txt");
 if(!-e "$command_file") {
  open(OPS,">$command_file");
  close(OPS);
 }
 if(!&hdmi_sink_connected()) {
  if(!&renderer_waiting_for_hdmi()) {
   &log("Renderer: no HDMI display connected; deferring the renderer start until one is plugged in");
   if(open(my $wfh,">",&renderer_waiting_for_hdmi_path())) { close($wfh); }
  }
  &renderer_unlock();
  return;
 }
 unlink(&renderer_waiting_for_hdmi_path());
 # Treat restart as the transaction boundary for classic clients which write
 # mode flags one command at a time. In particular this turns HCFR 4.1's
 # contradictory DV flag bundle into one coherent Standard- or Low-Latency-DV
 # configuration before choosing PGeneratord vs PGeneratord.dv.
 &normalize_signal_mode_conf();
 &auto_select_4k_mode();
 &mode_idx_follow_timing();
 &apply_drm_properties("prelaunch");
 # apply_drm_properties() above issued up to 6 modetest -w writes; wait for
 # the kernel to release DRM master before spawning the renderer (see
 # wait_for_drm_master_unowned() for the full root-cause story). Without
 # this, the renderer's first drmSetMaster races the just-closed modetest
 # and exits with EACCES - "Pattern renderer failed to start" on the WebUI.
 &wait_for_drm_master_unowned(3);
 &get_hdmi_info();
 if($is_kms && &kms_connector_has_property("Colorspace") && !&kms_connector_has_property("Colorimetry")) {
  $use_drm_override=0;
  &log("DRM: Colorspace-based kernel detected; starting renderer without drm_override.so");
 }
 if($is_kms && !&kms_connector_has_property("DOVI_OUTPUT_METADATA")) {
  $has_dovi_metadata=0;
 }
 # Select the DV binary when dv_status=1 — the .dv binary has native DOVI
 # metadata support that triggers DV mode on compatible TVs.
 # drm_override.so (LD_PRELOAD) provides additional overrides for max_bpc,
 # Colorimetry, output_format, and keeps the DOVI blob alive on subsequent
 # atomic commits.
 my $binary=$pattern_generator;
 if($pgenerator_conf{"dv_status"} eq "1" && -f "${pattern_generator}.dv" && $has_dovi_metadata) {
  $binary="${pattern_generator}.dv";
  &log("DV mode: using $binary (drm_override provides property overrides)");
 } elsif($pgenerator_conf{"dv_status"} eq "1" && !$has_dovi_metadata) {
  &log("DV mode requested but DOVI_OUTPUT_METADATA is unavailable on this kernel; falling back to $binary");
 }
 # Use Mesa EGL (not Broadcom) on KMS — Broadcom EGL needs dispmanx/VCHIQ
 # which is unavailable with vc4-kms-v3d. LD_LIBRARY_PATH=/usr/lib forces
 # Mesa libEGL.so + libGLESv2.so so the binary uses DRM/GBM rendering.
 # LD_PRELOAD overrides DRM property calls to fix max_bpc setting.
 # MALLOC_CHECK_=0 suppresses a benign glibc double-free abort that fires
 # right after GBM init in the SOURCE_RANGE-aware renderer; without it the
 # renderer dies before any IMAGE pattern can be drawn (diagnostics break).
  # Keep the renderer's own output: when a start fails, the renderer's
  # last words (e.g. "failed to set drm master: Device or resource busy")
  # are the only direct evidence of the cause. The renderer runs at
  # OF_LOG_VERBOSE and spews a DRM notice line on EVERY page flip
  # (~180 KB/s), so a plain redirect would fill the root disk (~15 GB/day)
  # while a single renderer instance stays alive. Cap it: keep the first
  # 512 KB (more than enough for startup diagnostics) then drain the rest
  # to /dev/null. The `exec cat >/dev/null` keeps the pipe's read end open
  # so the renderer never gets SIGPIPE once the cap is reached.
  # pgen_log_cap writes each line as it comes: `head -c` buffered it
  # (stdio), so the log of a running renderer read empty until 4 KB had
  # come together. head stays the fallback when the helper is missing.
  unlink(&renderer_started_conf_path());
  my $started_conf=&renderer_conf_read();
  my $spawn_log=(-x "/usr/bin/pgen_log_cap") ? "/usr/bin/pgen_log_cap /tmp/renderer-spawn.log 524288"
                                              : "( head -c 524288 > /tmp/renderer-spawn.log; exec cat >/dev/null )";
  if($use_drm_override) {
   system("MALLOC_CHECK_=0 LD_PRELOAD=/usr/lib/drm_override.so LD_LIBRARY_PATH=/usr/lib $binary $w_s $h_s 2>&1 | $spawn_log &");
  } else {
   system("MALLOC_CHECK_=0 LD_LIBRARY_PATH=/usr/lib $binary $w_s $h_s 2>&1 | $spawn_log &");
  }
 usleep(250000);
   # Some displays miss the first pre-launch RGB/colorspace programming and stay
   # on the splash screen until a later format toggle forces HDMI state back in.
   # Reapply connector properties once the renderer OWNS DRM MASTER so the first
   # pattern push lands on the intended format without requiring a manual YCbCr
   # detour.
   #
   # CRITICAL ORDERING (DRM master race root cause): apply_drm_properties() and
   # apply_hdr_metadata_helper() below run root modetest/pgsethdr children that
   # each take DRM master. The unprivileged renderer opens /dev/dri/card1, is
   # auto-promoted to master, then DROPS master during its EGL/GBM init and
   # re-acquires it before its first atomic commit. If any root helper holds
   # master during that init window, the renderer's open lands as a non-master
   # client (drmSetMaster -> EACCES) or its re-acquire collides with the helper
   # (drmSetMaster -> EBUSY); either way the renderer dies ("failed to set drm
   # master" / "failed to authorize drm magic") and the WebUI reports "Pattern
   # renderer failed to start". Gating on pattern_generator_is_running() (the
   # process merely EXISTS) is not enough - the process exists throughout that
   # init window. Wait until the renderer is observably the DRM master (debugfs
   # clients: PGeneratord row with master=='y'). Once it is master its fd is
   # was_master=true, so the brief master steals by the helpers below are safe.
   for(my $i=0;$i<40 && !&pattern_generator_is_running();$i++) {
    usleep(250000);
   }
   my $renderer_is_master=0;
   $renderer_is_master=&wait_for_renderer_drm_master(8) if(&pattern_generator_is_running());
   &blank_console_framebuffer() if($renderer_is_master);
   &renderer_applied_range_record();
   &renderer_started_conf_record($started_conf) if($renderer_is_master);
 # Post-spawn connector reprogramming exists for sinks that miss the
 # pre-launch programming. But once the renderer holds DRM master it already
 # sets output format / Colorimetry / rgb quant range / max bpc / COLOR_RANGE
 # itself on every updateAVI_Infoframe() atomic commit (renderer is the wire
 # source of truth). Running apply_drm_properties() then is not just
 # redundant: each modetest -w has to grab DRM master while the renderer
 # floods 60fps atomic commits, so every write hits its 3s timeout (x2
 # legacy+atomic paths, x~6 props, x2 invocations) and blocks PGeneratord for
 # up to ~70s per HDR apply - the "WebUI showed for a minute then went
 # offline" symptom. Skip it when the renderer owns master; mirrors the
 # pgsethdr skip in apply_hdr_metadata_helper().
 if($renderer_is_master) {
  &log("DRM: skipping post-spawn apply_drm_properties (renderer holds master and owns connector properties)");
 } else {
   &apply_drm_properties();
 my $startup_color_fmt=$pgenerator_conf{"color_format"};
 $startup_color_fmt=0 if($startup_color_fmt eq "");
 if($is_kms && ($pgenerator_conf{"dv_status"}||"0") ne "1" && $startup_color_fmt == 0) {
  # Some monitor-class RGB sinks take longer than TVs to latch the connector
  # state after the renderer grabs DRM master. Retry once more after the link
  # has been stable a bit longer so a manual YCbCr toggle is not needed.
  usleep(1000000);
  &apply_drm_properties();
 }
 }
 &apply_hdr_metadata_helper();
 unlink("$info_dir/GET_PGENERATOR_IS_EXECUTED.info");
 if(!$no_clean_files) {
  # Video black on Limited links (see pattern_start_black in daemon.pm).
  # "window;background": the template's 640x360 window sits on a full-screen
  # background, and both need the black.
  my ($start_black,$start_range,$start_max)=defined(&pattern_start_black) ? &pattern_start_black() : ("0,0,0","",0);
  &get_pattern($test_template_command,"$pattern_start","$start_black;$start_black","pattern_generator_start",$start_range,$start_max);
 }
 &renderer_unlock();
}

###############################################
#      Pattern Generator Stop Function        #
###############################################
sub pattern_generator_stop {
 my $pid = "";
 # Wait for a start in progress: killing a renderer before it holds DRM
 # master is the window the start path protects.
 &renderer_lock();
 &video_program_stop("$program_video_to_kill");
 &process_pid("$pattern_generator","kill");
 # Also kill the .dv variant in case we're switching modes
 &process_pid("${pattern_generator}.dv","kill") if(-x "${pattern_generator}.dv");
 # Poll every 50ms (the renderer usually exits within ~0.3s, after its exit
 # connector reset) and repeat TERM every 0.5s as before.
 my $polls=0;
 while(($pid=&process_pid("$pattern_generator","get"))
       || (-x "${pattern_generator}.dv" && ($pid=&process_pid("${pattern_generator}.dv","get")))) {
  usleep(50000);
  # A renderer stuck in the kernel never exits: give up after 5 s instead
  # of holding the renderer lock forever.
  if($polls >= 100 && (my $stuck=&renderer_stuck_in_kernel())) {
   &log("Renderer: stop gave up: renderer $stuck is stuck in the HDMI driver after a kernel error; restart the Pi");
   last;
  }
  next if(++$polls % 10);
  &process_pid("$pattern_generator","kill");
  &process_pid("${pattern_generator}.dv","kill") if(-x "${pattern_generator}.dv");
 }
 &clean_files();
 &renderer_unlock();
}

###############################################
#          Video Program Stop Function        #
###############################################
sub video_program_stop {
 my $program = shift;
 if($program ne "") {
  &sudo("STOP_VIDEO","$program") if($program =~ /(^|\/)(?:omxplayer(?:\.bin)?|pg_diag_video_player)$/);
  &process_pid("$program","kill");
  &pattern_generator_start(1) if(!&pattern_generator_is_running());
 }
}

# Pid of a renderer that is stuck in the DRM driver (state D, waiting in a
# drm_* kernel function), e.g. after a vc4 kernel oops; "" otherwise. The
# crashed process can have an empty cmdline, so it is found by name.
sub renderer_stuck_in_kernel (@) {
 opendir(my $dh,"/proc") or return "";
 my @pids=grep { /^\d+$/ } readdir($dh);
 closedir($dh);
 for my $pid (@pids) {
  open(my $cf,"<","/proc/$pid/comm") or next;
  my $comm=<$cf> || "";
  close($cf);
  next if($comm!~/^PGeneratord(\.dv)?$/);
  open(my $sf,"<","/proc/$pid/stat") or next;
  my $stat=<$sf> || "";
  close($sf);
  next if($stat!~/\)\s+D\s/);
  open(my $wf,"<","/proc/$pid/wchan") or next;
  my $wchan=<$wf> || "";
  close($wf);
  return $pid if($wchan=~/drm/);
 }
 return "";
}

sub pattern_generator_is_running () {
 return 1 if((&process_pid("$pattern_generator","get")) ne "");
 return 1 if(-x "${pattern_generator}.dv" && (&process_pid("${pattern_generator}.dv","get")) ne "");
 return 0;
}

###############################################
#              Kill Pid Function              #
###############################################
sub process_pid(@) {
 my $process = shift;
 my $action = shift;
 my @dir = "";
 my ($pid,$proc_file,$el_pid,$cmd) = "";
 opendir(PROC,"/proc");
 @dir=readdir(PROC);
 closedir(PROC);
 for(@dir) {
  next if(/[^0-9]/);
  $pid=$_;
  $proc_file="/proc/$pid/cmdline";
  if(-f "$proc_file"){
   open(CMD_PROC,"$proc_file");
   $cmd=<CMD_PROC>;
   close(CMD_PROC);
   $el_pid.="$pid "  if($cmd =~/$process/  && $action eq "get_with_pattern");
   $cmd=~s/\0.*//g;
   next if($cmd eq "");
   kill("TERM",$pid) if($cmd eq "$process" && $action eq "kill");
   $el_pid.="$pid "  if($cmd eq "$process" && $action eq "get");
  }
 }
 $el_pid=~s/ $//;
 return $el_pid;
}

###############################################
#        Pattern Clean Files Function         #
###############################################
sub clean_files(@) {
 # Meter settings are durable user preferences (meter ports, custom series,
 # grey profiles). The blanket $var_dir wipe below deleted the persist copy on
 # EVERY daemon restart, so settings only survived when an open browser tab
 # happened to re-save them. Carry the file across the wipe.
 my $keep_meter_settings="";
 if(open(my $ms,"<","$var_dir/meter_settings.json")) { local $/; $keep_meter_settings=<$ms>; close($ms); }
 &remove_files("$var_dir",".*");
 &remove_files("$var_dir/frames/",".*");
 # A pending WebUI notice (daemon.pm webui_notice) is often written just
 # before the renderer restarts, e.g. Calman's next CONF_LEVEL; keep it.
 my $keep_notice="";
 my $keep_notice_mtime=(stat($webui_notice_file))[9];
 if(open(my $nf,"<",$webui_notice_file)) { local $/; $keep_notice=<$nf>; close($nf); }
 &remove_files("$var_dir/running/",".*");
 if($keep_meter_settings ne "" && open(my $ms,">","$var_dir/meter_settings.json")) { print $ms $keep_meter_settings; close($ms); }
 if(defined($keep_notice) && $keep_notice ne "" && open(my $nf,">",$webui_notice_file)) {
  print $nf $keep_notice;
  close($nf);
  # Keep its age: /api/stats shows a notice for 10 minutes after it was written.
  utime($keep_notice_mtime,$keep_notice_mtime,$webui_notice_file) if($keep_notice_mtime);
 }
 opendir(TMP,"$var_dir/tmp");
 @dir=readdir(TMP);
 closedir(TMP);
 for(@dir) {
  next if ($_ eq "." || $_ eq "..");
  next if($_ eq $pattern_dynamic || $_ eq $pattern_profile || $_ eq $pattern_position || $_ eq $pattern_screensaver || $_ eq $pattern_start);
  next if($_ eq $pattern_calman1 || $_ eq $pattern_calman2 || $_ eq $pattern_calman3  || $_ eq $pattern_calman4);
  $deletable=1;
  open(PATTERN,"$var_dir/tmp/$_");
  $deletable=0 if(($row=<PATTERN>) =~/^PERMANENT=yes/);
  close(PATTERN);
  next if(!$deletable);
  unlink("$var_dir/tmp/$_");
 }
 rmdir("$var_dir/pattern") if(-d "$var_dir/pattern");
}


###############################################
#                CMD Function                 #
###############################################
sub pgenerator_cmd (@) {
 my $cmd = shift;
 my $response = "";
 my $ip="";
 #
 # Get CMD from cache or not
 #
 if(-f "$info_dir/$cmd.info") {
  open(INFO,"$info_dir/$cmd.info");
  while(<INFO>) {
   $response.=$_;
  }
  return $response;
 }
 $response=&get_cmd_generic($cmd);
 # 
 # Set CMD
 #
 &sudo("SET_DTOVERLAY","$1")         if($cmd =~/SET_DTOVERLAY:(.*)/);
 &sudo("SET_BOOT_CONFIG","$1")       if($cmd =~/SET_BOOT_CONFIG:(.*)/);
 &sudo("SET_GPU_MEMORY","$1")        if($cmd =~/SET_GPU_MEMORY:(.*)/);
 &sudo("SET_CMA_MEMORY","$1")        if($cmd =~/SET_CMA_MEMORY:(.*)/);
 if($cmd =~/SET_BOOT_MEMORY:(\d+),(\w+)/) {
  &sudo("SET_BOOT_MEMORY",$1,$2);
 }
 &sudo("SET_OUTPUT_RANGE","$1")      if($cmd =~/SET_OUTPUT_RANGE:(.*)/);
 if($cmd =~/SET_DISCOVERABLE:(.*)/) {
  unlink("$info_dir/GET_DISCOVERABLE.info");
  &sudo("SET_DISCOVERABLE","$1");
 }
 if($cmd =~/SET_PGENERATOR_CONF_(IS_SDR|IS_HDR|IS_LL_DOVI|IS_STD_DOVI|EOTF|PRIMARIES|MAX_LUMA|MIN_LUMA|MAX_CLL|MAX_FALL|COLOR_FORMAT|COLORIMETRY|RGB_QUANT_RANGE|MAX_BPC|DV_STATUS|DV_INTERFACE|DV_PROFILE|DV_MAP_MODE|DV_MINPQ|DV_MAXPQ|DV_DIAGONAL|MODE_IDX|DV_METADATA|DV_COLOR_SPACE|DV_TRANSPORT|SIGNAL_MODE|CALMAN_MODE_IDX):(.*)/) {
  my $conf_key=lc($1);
  my $conf_value=$2;
  # 1.6 compatibility: CMD MIN_LUMA is wire units (0.0001 nits), conf is nits.
  if($conf_key eq "min_luma") {
   $conf_value=&pg_min_luma_cmd_wire_to_nits($conf_value);
  }
  # ColourSpace writes every setting on each connect, mostly unchanged, and
  # waits only ~0.2 s per reply; a root-helper spawn takes ~0.4 s on the Pi.
  # Skip the write when the conf file (not the memory copy) already holds
  # exactly this value; a missing file or key writes as before.
  my $file_conf=&renderer_conf_read();
  if(!(ref($file_conf) eq "HASH" && exists($file_conf->{$conf_key}) && $file_conf->{$conf_key} eq "$conf_value")) {
   &sudo("SET_PGENERATOR_CONF",$conf_key,$conf_value);
  }
  $pgenerator_conf{$conf_key}=$conf_value;
  if($conf_key eq "dv_metadata") {
   my $map_mode=&dv_map_mode_for_metadata($conf_value);
   # dv_map_mode "0" (Perceptual) is a value, not empty.
   if($map_mode ne "" && ((defined $pgenerator_conf{"dv_map_mode"} ? $pgenerator_conf{"dv_map_mode"} : "") ne $map_mode)) {
    &sudo("SET_PGENERATOR_CONF","dv_map_mode",$map_mode);
    $pgenerator_conf{"dv_map_mode"}=$map_mode;
   }
  } elsif($conf_key eq "dv_map_mode" && $conf_value ne "") {
   # An empty value deletes the map mode and leaves dv_metadata as it is
   # (dv_metadata_for_map_mode("") would switch DV metadata on).
   my $metadata=&dv_metadata_for_map_mode($conf_value);
   if(($pgenerator_conf{"dv_metadata"} || "") ne $metadata) {
    &sudo("SET_PGENERATOR_CONF","dv_metadata",$metadata);
    $pgenerator_conf{"dv_metadata"}=$metadata;
   }
  }
  if(($conf_key eq "dv_status" && $conf_value eq "1") ||
     ($conf_key=~/^(is_ll_dovi|is_std_dovi)$/ && $conf_value eq "1") ||
     ($conf_key=~/^(max_bpc|color_format|rgb_quant_range|dv_interface|dv_transport)$/ && int($pgenerator_conf{"dv_status"} || 0) == 1)) {
   &normalize_dv_transport_conf();
  }
  unlink("$info_dir/GET_PGENERATOR_CONF_".uc($1).".info");
  unlink("$info_dir/GET_PGENERATOR_CONF_ALL.info");
 }
 if($cmd =~/SET_HOSTNAME:(.*)/) {
  &sudo("SET_HOSTNAME","$1");
  unlink("$info_dir/GET_HOSTNAME.info");
 }
 if($cmd =~/SET_SCALING_GOVERNOR:(.*)/) {
  &sudo("SET_SCALING_GOVERNOR","$1");
  unlink("$info_dir/GET_SCALING_GOVERNOR.info");
  unlink("$info_dir/GET_SCALING_GOVERNOR_CUR_FREQ.info");
  unlink("$info_dir/GET_CORE_VOLTAGE.info");
 }
 if($cmd =~/SET_NET_TO_USE:(.*)/) {
  $set_net_to_use=$1;
  ($net_start,$net_subclass,$net_to_use)=split("-",$set_net_to_use);
  &sudo("SET_NET_TO_USE","$net_start",$net_subclass,$net_to_use);
 }
 if($cmd =~/SET_WIFI_AP_APPLY_CONF:(.*)/) {
  $response=wpa_cli("WIFI_AP_APPLYCONF:$1");
  unlink("$info_dir/GET_WIFI_STATUS.info");
  unlink("$info_dir/GET_WIFI_NET_CONFIGURED.info");
  &remove_files("$info_dir","GET_IP\-.*\.info\$");
 }
 if($cmd =~/SET_WIFI_APPLY_CONF:(.*)/) {
  $response=wpa_cli("WIFI_APPLYCONF:$1");
  unlink("$info_dir/GET_WIFI_STATUS.info");
  unlink("$info_dir/GET_WIFI_NET_CONFIGURED.info");
  &remove_files("$info_dir","GET_IP\-.*\.info\$");
 }
 if($cmd =~/(SET_MODE|SET_CEA_DMT):(.*)/) {
  if(!$is_kms && $tvservice_is_working) {
   open(CMD_TVSERVICE,"timeout 3 $tvservice -e \"$2\" 2>/dev/null|");
   $response=<CMD_TVSERVICE>;
   close(CMD_TVSERVICE);
   sleep(1);
   #unlink("$info_dir/GET_CEA_DMT.info"); # system reboot, not necessary
   &sudo("SET_PGENERATOR_CONF","mode_idx","");
   $pgenerator_conf{"mode_idx"}="";
   &sudo("SET_CEA_DMT","$2");
  # Start for RPI p4
  } else {
   # ColourSpace sends SET_MODE with the current mode on every connect; skip
   # the root-helper spawn (~0.4 s) when the conf file already holds it, as
   # for SET_PGENERATOR_CONF_*. The caches below are cleared either way.
   my $mode_idx="$2";
   my $file_conf=&renderer_conf_read();
   if(!(ref($file_conf) eq "HASH" && exists($file_conf->{"mode_idx"}) && $file_conf->{"mode_idx"} eq $mode_idx)) {
    &sudo("SET_PGENERATOR_CONF","mode_idx",$mode_idx);
   }
   $pgenerator_conf{"mode_idx"}=$2;
   unlink("$info_dir/GET_MODES_AVAILABLE.info");
   unlink("$info_dir/GET_MODE.info");
   unlink("$info_dir/GET_HDMI_INFO.info");
   unlink("$info_dir/GET_REFRESH.info");
   unlink("$info_dir/GET_OUTPUT_RANGE.info");
   unlink("$info_dir/GET_RESOLUTION.info");
   &invalidate_hdmi_info_cache();
  }
  # End for RPI p4
  # Refused settings: a mode the link cannot carry at the current format
  # and bit depth is put back and not applied (signal_gate_conf). The mode
  # already running needs no restart (ColourSpace sends SET_MODE with the
  # current mode on every connect).
  if(!$is_kms || &signal_gate_conf(&signal_source_label())) {
   &pattern_generator_restart_unless_current("SET_MODE:$2");
  } else {
   $response="$error_response:Refused: ".&signal_patches_refused();
  }
 }
 if($cmd =~/SET_REFRESH:(.*)/) {
  if(!$is_kms && $tvservice_is_working) {
   open(CMD_TVSERVICE,"timeout 3 $tvservice -e \"CEA $1\" 2>/dev/null|");
   $response=<CMD_TVSERVICE>;
   close(CMD_TVSERVICE);
   sleep(1);
   unlink("$info_dir/GET_HDMI_INFO.info");
   unlink("$info_dir/GET_REFRESH.info");
   &sudo("SET_REFRESH","CEA $1");
   &pattern_generator_stop();
   &pattern_generator_start();
  # Start for RPI p4
  } else {
    $response="$error_response:Error with tvservice";;
  }
  # End for RPI p4
 }
 &sudo("REBOOT") if($cmd eq "REBOOT");
 &sudo("HALT")   if($cmd eq "HALT");
 #
 # return
 #
 return "$response";
}

###############################################
#              GET TEMPERATURE                #
###############################################
sub get_temperature () {
 my $temp=&read_from_file("$temperature_file");
 return int($temp/1000);
}

###############################################
#              GET DTOVERLAY                  #
###############################################
sub get_dtoverlay () {
 my $dt = "";
 for(split("\n",&read_from_file($bootloader_file))) {
  next if(!/dtoverlay=(.*)/);
  $dt.="$1\n";
 }
 return $dt;
}

###############################################
#                    GET CPU                  #
###############################################
my $_cpu_idle_prev = 0;
my $_cpu_total_prev = 0;
sub get_cpu () {
 open ($STAT,"/proc/stat");
 while (<$STAT>) {
  next unless ("$_" =~ m/^cpu\s+/);
  my @cpu_time_info = split (/\s+/, "$_");
  shift @cpu_time_info;
  my $total = sum(@cpu_time_info);
  my $idle = $cpu_time_info[3];
  my $del_total = $total - $_cpu_total_prev;
  my $del_idle = $idle - $_cpu_idle_prev;
  $usage = ($del_total > 0) ? 100 * (($del_total - $del_idle)/$del_total) : 0;
  $_cpu_idle_prev = $idle;
  $_cpu_total_prev = $total;
 }
 close ($STAT);
 return int($usage)."%";
}

###############################################
#                GET AL IP/MAC                #
###############################################
sub get_all_ipmac () {
 %info_var=();
 my ($addr,$mac)="";
 open(CMD_IP,"timeout 3 ip a|");
 my $response=$none;
 while(<CMD_IP>) {
  my @field=split(" ",$_);
  if($_=~/ mtu /) {
   ($int_name=$field[1])=~s/://;
   $int_name=~s/\@.*//;
  }
  if($_=~/link\/ether (.*) brd/) {
   $mac=$1;
   $info_var{$int_name}{mac}=uc($mac);
  }
  if($_=~/inet (.*)/) {
   ($addr=$1)=~s/ .*//;
   $addr=~s/\/.*//;
   $info_var{$int_name}{addr}=$addr;
   if($int_name eq "$bt_interface") {
    open(CMD_BT,"timeout 3 $hcitool dev|");
    while(<CMD_BT>) {
     @row_response=split(" ",$_);
     $mac_bt=$row_response[1] if(/$hci_interface/);
    }
    $mac_bt=$none if($mac_bt eq "");
    chomp($mac_bt);
    $info_var{$int_name}{mac}="$mac_bt";
    close(CMD_BT);
   }
  }
  $info_var{$int_name}{addr}=$none if($info_var{$int_name}{addr} eq "");
 }
 close(CMD_IP);
 return $response;
}

###############################################
#                   GET IP                    #
###############################################
sub get_ip (@) {
 my $interface = shift;
 my $response=$none;
 my $addr="";
 open(CMD_IP,"timeout 3 $ip addr show dev $interface|");
 while(<CMD_IP>) {
  if($_=~/inet (.*)\/(.*) /) {
  ($addr=$1)=~s/ //g;
   close(CMD_IP);
   return $addr;
  }
 }
 close(CMD_IP);
 return $none;
}

###############################################
#                  GET MAC                    #
###############################################
sub get_mac (@) {
 my $interface = shift;
 my $response=$none;
 if($interface eq "$bt_interface") {
  open(CMD_BT,"timeout 3 $hcitool dev|");
  while(<CMD_BT>) {
   @row_response=split(" ",$_);
   if(/$hci_interface/) {
     close(CMD_BT);
     return $row_response[1];
   }
  }
  close(CMD);
  return $none;
 }
 open(CMD_IP,"timeout 3 $ip addr show dev $interface|");
 while(<CMD_IP>) {
  if($_=~/link\/ether (.*) /) {
   ($mac=$1)=~s/ //g;
   close(CMD_IP);
   return uc($mac);
  }
 }
 close(CMD_IP);
 return $none;
}

###############################################
#                    WPA CLI                  #
###############################################
sub wpa_cli () {
 my $cmd = shift;
 my $interface = "wlan0";
 my @el=split(":",$cmd,2);
 return &sudo("$el[0]","$interface") if($el[0] eq "WIFI_SCAN" || $el[0] eq "GET_WIFI_STATUS");
 if($el[0] eq "GETNETCONFIGURED") {
  return "" if(!-f $wifi_conf);
  open(CONF,"$wifi_conf");
  while(<CONF>) {
   next if($_=~/^#/);
   return $1 if($_=~/ssid=\"(.*)\"/);
  }
  close(CONF);
 }
 if($el[0] eq "WIFI_AP_APPLYCONF") {
  @info=split(":",$el[1],2);
  return &sudo("$el[0]","$info[0]","$info[1]");
 }
 return &sudo("$el[0]","$interface") if($el[0] eq "WIFI_AP_STATUS" || $el[0] eq "WIFI_AP_ENABLE" || $el[0] eq "WIFI_AP_DISABLE");
 if($el[0] eq "WIFI_APPLYCONF") {
  @info=split(":",$el[1],2);
  return &sudo("$el[0]","$interface","$info[0]","$info[1]");
 }
 sleep(1);
 return "";
}

###############################################
#          PGenerator Is Executed? CLI        #
###############################################
sub pgenerator_is_executed(@) {
 my $response="Not executed";
 my $ps_proc=&process_pid("$pattern_generator","get");
 $ps_proc=&process_pid("${pattern_generator}.dv","get") if(!$ps_proc && -x "${pattern_generator}.dv");
 $response="Pid $ps_proc" if($ps_proc);
 chomp($response);
 return $response;
}

###############################################
#            Get Generic function             #
###############################################
sub get_cmd_generic(@) {
 my $cmd = shift;
 my ($response,$response_tmp)="";

 $response=&get_all_ipmac() if($cmd =~/(^GET_ALL_IPMAC|^WIFI^BT|^ETH|^GET_IP|^GET_MAC)/);
 $response=$status                                                                            if($cmd eq "GET_STATUS");
 chomp($response=&read_from_file("$scaling_file"))                                            if($cmd eq "GET_SCALING_GOVERNOR");
 chomp($response=&read_from_file("$scaling_available_file"))                                  if($cmd eq "GET_SCALING_GOVERNOR_AVAILABLE");
 chomp($response=&read_from_file("$scaling_freq_file"))                                       if($cmd eq "GET_SCALING_GOVERNOR_CUR_FREQ");
 chomp($response=&read_from_file("$proc_device_model"))                                       if($cmd eq "GET_DEVICE_MODEL");
 chomp($response=&read_from_file("$hostname_file"))                                           if($cmd eq "GET_HOSTNAME");
 $response=$device_model                                                                      if($cmd eq "GET_DEVICE_MODEL");
 $response=&stats("READ")                                                                     if($cmd eq "STATSGET" || $cmd eq "GET_STATS");
 $response=&pgenerator_is_executed()                                                          if($cmd eq "PGENERATORISEXECUTED" || $cmd eq "GET_PGENERATOR_IS_EXECUTED");
 $response=$version                                                                           if($cmd eq "GET_PGENERATOR_VERSION");
 $response=&get_temperature()                                                                 if($cmd eq "GET_TEMPERATURE");
 $response=&get_cpu()                                                                         if($cmd eq "GET_CPU");
 $response=encode_base64(&get_dtoverlay(),"")                                                 if($cmd eq "GET_DTOVERLAY");
 $response=encode_base64(&read_from_file($bootloader_file),"")                                if($cmd eq "GET_BOOT_CONFIG");
 $response=&get_ip("$wlan_interface")                                                         if($cmd eq "WIFI");
 $response=&get_mac("$wlan_interface")                                                        if($cmd eq "WIFIMAC");
 $response=&get_ip("$bt_interface")                                                           if($cmd eq "BT");
 $response=&get_mac("$bt_interface")                                                          if($cmd eq "BTMAC");
 $response=&get_ip("$eth_interface")                                                          if($cmd eq "ETH");
 $response=&get_mac("$eth_interface")                                                         if($cmd eq "ETHMAC");
 $response=&wpa_cli("GETNETCONFIGURED")                                                       if($cmd eq "GETWIFINETCONFIGURED" || $cmd eq "GET_WIFI_NET_CONFIGURED");
 $response=encode_base64(&wpa_cli("GET_WIFI_STATUS"),"")                                      if($cmd eq "GET_WIFI_STATUS");
 if($cmd =~/(^GET_CPU_INFO|^GET_CPU_HARDWARE|^GET_CPU_REVISION|^GET_CPU_SERIAL)/) {
  $response="";
  $cpu_info=&read_from_file("$cpu_file");
  @el_cpu_info=split("\n",$cpu_info);
  for(@el_cpu_info) {
   $response.="$1 " if(/Hardware.*: (.*)/);
   $response.="$1 " if(/Revision.*: (.*)/);
   $response.="$1 " if(/Serial.*: (.*)/);
  }
  $response=~s/ $//;
  chomp($response);
  @el_cpu_info=split(" ",$response);
 }
 if($cmd =~/^(GET_MODES_AVAILABLE|GET_CEA_DMT_AVAILABLE)/) {
  $response="";
  foreach my $key (reverse sort { $a <=> $b} keys %hash_mode) {
   chomp($hash_mode{$key});
   @row=split("\n",$hash_mode{$key});
   for(@row) {$response.="$_\n";}
  }
  chomp($response);
  $response=~s/\n$//;
  $response=encode_base64($response,"");
 }
 if($cmd =~/^(GET_MODE|GET_CEA_DMT)$/) {
  $response="";
  $response=$preferred_mode if($preferred_mode ne "");
  chomp($response);
 }
 if($cmd =~/GET_PGENERATOR_CONF_(.*)/) {
  $response=$none;
  $all_pgenerator_conf="";
  $conf_var=lc($1);
  foreach my $key (keys(%pgenerator_conf)) {
   next if($key ne $conf_var && $conf_var ne "all");
   $response=$pgenerator_conf{$key};
   # 1.6 compatibility: CMD MIN_LUMA is wire units; conf stores nits.
   if($key eq "min_luma") {
    $response=&pg_min_luma_cmd_nits_to_wire($response);
   }
   $all_pgenerator_conf.="$key:$response\n";
  }
  $response=encode_base64($all_pgenerator_conf,"") if($conf_var eq "all");
 }
 if($cmd =~/(^GET_EDID_INFO)/) {
  $response="";
  if(!$is_kms && $tvservice_is_working) {
   open(TVSERVICE,"timeout 3 $tvservice -l 2>/dev/null|");
   while(<TVSERVICE>) {
    next if(!/Display Number (\d+), type (.*)/);
    system("timeout 3 $tvservice -v $1 -d $info_dir/GET_EDID_INFO_$1.tmp &>/dev/null");
    $response.="$2\n".&parse_edid("$info_dir/GET_EDID_INFO_$1.tmp")."\n\n";
   }
   close(TVSERVICE);
   chomp($response);
  } else {
  # Start for RPI p4
   &get_edid(0,"$hdmi_1","$info_dir/GET_EDID_INFO_$hdmi_1.tmp");
   &get_edid(0,"$hdmi_2","$info_dir/GET_EDID_INFO_$hdmi_2.tmp");
   &get_edid(1,"$hdmi_1","$info_dir/GET_EDID_INFO_$hdmi_1.tmp");
   &get_edid(1,"$hdmi_2","$info_dir/GET_EDID_INFO_$hdmi_2.tmp");
   $response.="$hdmi_1\n".&parse_edid("$info_dir/GET_EDID_INFO_$hdmi_1.tmp");
   $response.="\n\n$hdmi_2\n".&parse_edid("$info_dir/GET_EDID_INFO_$hdmi_2.tmp");
  }
  # End for RPI p4
  chomp($response);
  $response=$no_info_available if($response eq "");
  $response=encode_base64($response,"");
 }
 if($cmd =~/(^GET_HDMI_INFO|^GET_REFRESH|^GET_OUTPUT_RANGE|^GET_RESOLUTION)$/) {
  &get_hdmi_info();
  # state 0x12000a [HDMI CEA (32) RGB full 16:9], 1920x1080 @ 24.00Hz, progressive
  $response=$hdmi_info;
  @el_hdmi_info=split(" ",$response);
  $response=~s/state.*\.*\[HDMI //;
  $response=~s/\]//;
  chomp($response);
 }
 if($cmd eq "FREE_DISK" || $cmd eq "GET_FREE_DISK") {
  open(CMD_DF,"timeout 3 $df -kh|");
  while(<CMD_DF>) {
   @row_response=split(" ",$_);
   $response=$row_response[3] if(/\/$/);
  }
  close(CMD_DF);
 }
 if($cmd eq "GET_DISCOVERABLE") {
  $response=1;
  $response=0 if(-f "$discoverable_disabled_file");
 }
 if($cmd eq "GET_GPU_MEMORY") {
  open(CMD_VCGENCMD,"timeout 3 $vcgencmd get_mem gpu 2>/dev/null|");
  chomp($response=<CMD_VCGENCMD>);
  close(CMD_VCGENCMD);
  $response=~s/gpu=//g;
 }
 if($cmd eq "GET_BOOT_MEMORY") {
  my $gpu="128";
  my $cma="default";
  if(open(my $fh,"<",$bootloader_file)) {
   while(<$fh>) {
    chomp;
    $gpu=$1 if(/^gpu_mem=(\d+)/);
    $cma=$1 if(/dtoverlay=vc4-kms-v3d,cma-(\d+)/);
   }
   close($fh);
  }
  $response="$gpu,$cma";
 }
 if($cmd eq "GET_CORE_VOLTAGE") {
  open(CMD_VCGENCMD,"timeout 3 $vcgencmd measure_volts core 2>/dev/null|");
  chomp($response=<CMD_VCGENCMD>);
  close(CMD_VCGENCMD);
  $response=~s/volt=//g;
 }
 if($cmd =~/(^GET_IP|^GET_MAC)-(.*)/) {
  $cmd_tmp=$1;
  $interface=$2;
  $response=$info_var{$interface}{addr} if($cmd_tmp =~/IP/);
  $response=$info_var{$interface}{mac}  if($cmd_tmp =~/MAC/);
  $response=$none if($response eq "");
 }
 ($response=$el_hdmi_info[4])=~s/\(|\)//g          if($cmd eq "GET_REFRESH");
 $response="$el_hdmi_info[5] $el_hdmi_info[6]"     if($cmd eq "GET_OUTPUT_RANGE");
 if($cmd eq "GET_RESOLUTION") {
  $response="$el_hdmi_info[8]";
  @el_response=split("x",$response);
  if($el_response[0] && $el_response[1] && ($w_s != $el_response[0] || $h_s != $el_response[1])) {
   $w_s=$el_response[0];
   $h_s=$el_response[1];
   $max_x=$w_s;
   $max_y=$h_s;
   &pattern_generator_stop();
   &pattern_generator_start();
  }
 }
 $response=$el_cpu_info[0]                         if($cmd eq "GET_CPU_HARDWARE");
 $response=$el_cpu_info[1]                         if($cmd eq "GET_CPU_REVISION");
 $response=$el_cpu_info[2]                         if($cmd eq "GET_CPU_SERIAL");
 if($cmd eq "GET_UP_FROM" || $cmd eq "UP_FROM") {
  $response_tmp=&read_from_file($uptime_file);
  @el_uptime=split(" ",$response_tmp);
  $response=int($el_uptime[0]);
  $final=" seconds" if($response < 60);
  if($response < 3600 && $response >=60) {
   $response=int(($response/60));
   $final=" minutes";
  }
  if($response >= 3600 && $response <86400) {
   $response=int(($response/3600));
   $final=" hours";
  }
  if($response >= 86400) {
   $response=int(($response/86400));
   $final=" days";
  }
  $response.=" $final";
 }
 if($cmd eq "GET_LA" || $cmd eq "LA") {
  $response_tmp=&read_from_file($load_avg_file);
  @el_avg=split(" ",$response_tmp);
  $response=$el_avg[0];
 }
 if($cmd eq "FREE_MEM" || $cmd eq "GET_FREE_MEM") {
  $response_tmp=&read_from_file("$mem_info_file");
  @el_response=split("\n",$response_tmp);
  for(@el_response) {
   @row_response=split(" ",$_);
   $response=int($row_response[1]/1024) if(/MemFree:/);
  }
  $response.="M";
 }
 if($cmd eq "WIFINET" || $cmd eq "GET_WIFI_NET") {
  while($doing_wifi_scan) { usleep(500000); }
  $doing_wifi_scan=1;
  $wifi=&wpa_cli("WIFI_SCAN");
  $response="";
  my @el=split("\n",$wifi);
  shift(@el);
  for(@el) {
   @el_field=split(" ",$_,5);
   $response.="$el_field[$#el_field]\n";
  }
  chomp($response);
  $response=encode_base64($response,"");
  $doing_wifi_scan=0;
 }
 if($cmd =~/^GET_DMESG/) {
  $response="";
  open(DMESG,"timeout 3 $dmesg 2>/dev/null|");
  $response.=$_ while(<DMESG>);
  close(DMESG);
  $response=encode_base64($response,"");
 }
 return $response;
}

###############################################
#                Stats function               #
###############################################
sub stats(@) {
 my $key = shift;
 my $value = shift;
 my $stat_content="";
 if($key eq "READ" && $value eq "") {
  foreach my $key (keys(%info)) {
   $stat_content.="$key: $info{$key},";
  }
  $stat_content=~s/,$//;
  return $stat_content;
 }
 $info{$key}+=$value;
 %info=() if($key eq "RESET" && $value eq "");
 unlink("$info_dir/GET_STATS.info");
}

###############################################
#                Sudo function                #
###############################################
# The helper splits $PG_CMD on spaces and decodes each word. An empty
# argument encodes to nothing and would vanish, shifting every later one
# into its place: it goes as "=", which decodes to "".
sub sudo(@) {
 my @arg_base64 = ();
 for(@_) {
  my $arg = defined($_) ? $_ : "";
  push(@arg_base64,($arg eq "") ? "=" : encode_base64($arg,""));
 }
 return `$pg_cmd_env="@arg_base64" timeout 15 $sudo_cmd`;
}

###############################################
#              Sync function                  #
###############################################
sub sync(@) {
 system("timeout 3 $sync");
}

###############################################
#         Get Hdmi Info function              #
###############################################
my $_hdmi_info_cache_time = 0;
sub invalidate_hdmi_info_cache() {
 $_hdmi_info_cache_time=0;
 $hdmi_info="";
}

sub get_hdmi_info() {
 # Cache for 3 seconds to avoid redundant modetest calls within the same info cycle
 if(time() - $_hdmi_info_cache_time < 3 && $hdmi_info ne "") {
  return $hdmi_info;
 }
 $_hdmi_info_cache_time = time();
 my ($response,$res_mode,$selected_mode,$userdef_mode,$range,$output,$ratio,$type)=("");
 my @field=();
 %hash_mode=();
 $preferred_mode="";
 $found=$found_range=$found_output=0;
 if(!$is_kms && $tvservice_is_working) {
  open(CMD_TVSERVICE,"timeout 3 $tvservice -s 2>/dev/stdout|");
  ($response=<CMD_TVSERVICE>)=~s/ x[0-9]\]/\]/;
  close(CMD_TVSERVICE);
  open(CMD_TVSERVICE,"timeout 3 $tvservice -m CEA 2>/dev/null|");
  while(<CMD_TVSERVICE>) {
   next if(!/mode \d+/);
   /mode (\d+): (.*)/;
   $res_mode="CEA $1"."[CEA $2]";
   $preferred_mode="$res_mode\n" if(/\(prefer\)/);
   my @el_cea_dmt=split(" ",$res_mode);
   /(\d+)x(\d+)/;
   $hash_mode{"$1"}.="$res_mode\n";
  }
  close(CMD_TVSERVICE);
  open(CMD_TVSERVICE,"timeout 3 $tvservice -m DMT 2>/dev/null|");
  while(<CMD_TVSERVICE>) {
   next if(!/mode \d+/);
   /mode (\d+): (.*)/;
   $res_mode="DMT $1"."[DMT $2]";
   $preferred_mode="$res_mode\n" if(/\(prefer\)/);
   /(\d+)x(\d+)/;
   $hash_mode{"$1"}.="$res_mode\n";
  }
  close(CMD_TVSERVICE);
 # Start for RPI p4
 } else {
  open(CMD_MODETEST,"timeout 3 $modetest 2>/dev/null|");
  while(<CMD_MODETEST>) { 
   $found=1           if(/\s+connected/);
   next               if(!$found);
   $found_range=1     if(/quant range/);   
   $found_output=1    if(/active color format/);   
   $range=$1          if($range  eq "" && $found_range && /value:(.*)/);
   $output=$1         if($output eq "" && $found_output && /value:(.*)/);
   next               if(!/#(\d+) (\d+)x(\d+)(.*)/);
   next               if($range ne "" && $output ne "");
   my @res_field=split(" ","$2x$3$4");
   $hash_mode{"$2"}.=(($res_mode=$1."[$res_field[0] $res_field[1]Hz ".sprintf("%.2f",($res_field[10]/1000))."MHz ".$res_field[12].$res_field[13]=~tr/;,//dr."]"))."\n";
   $selected_mode=$res_mode  if($selected_mode eq "" && $pgenerator_conf{"mode_idx"} ne "" && $1 == $pgenerator_conf{"mode_idx"});
   $userdef_mode=$res_mode   if(/#(\d+).*userdef/);
   $preferred_mode=$res_mode if(/#(\d+).*preferred/);
  }
  close(CMD_MODETEST);
  $preferred_mode=$selected_mode if($selected_mode ne "");
  $preferred_mode=$userdef_mode  if($userdef_mode ne "" && $preferred_mode eq "");
  # state 0xa [HDMI CEA (32) RGB full 16:9], 1920x1080 @ 24.00Hz, progressive
  #0 3840x2160 30.00 3840 4016 4104 4400 2160 2168 2178 2250 297000 flags: phsync, pvsync; type: preferred, driver
  # enums: RGB444=0 YCrCb444=1 YCrCb422=2 YCrCb420=3
  # enums: Default=0 Limited [16-235]=1 Full [0-255]=2 Reserved=3
  my $hdmi_output="RGB";
  $hdmi_output="YCbCr444" if($output == 1);
  $hdmi_output="YCbCr422" if($output == 2);
  $hdmi_output="YCbCr420" if($output == 3);
  my $hdmi_range="default";
  # 3: Limited without the vc4 CSC (patched vc4, PGeneratord RGB Limited)
  $hdmi_range="limited"   if($range == 1 || $range == 3);
  $hdmi_range="full"      if($range == 2);
  my @field=$preferred_mode=~/(\d+)\[(\d+x\w+) (.*Hz) (.*MHz) (.*)\]/;
  my $type="progressive";
  $type="interlaced"      if($field[1] =~/i/);
  my ($m_w,$m_h)=split("x",$field[1]);
  $m_h=int($m_h);
  my $ratio="16:9";
  $ratio="4:3" if($m_h != 0 && ($m_w/$m_h) == (4/3));
  $field[0]=~s/#//g;
  $response="state 0xa [HDMI MODETEST (".int($field[0]).") $hdmi_output $hdmi_range $ratio], $m_w"."x$m_h \@ $field[2]Hz, $type";
 }
 # End for RPI p4
 $response=~s/CUSTOM/CUSTOM ()/g; # done for compatibility with old tvservice output
 $hdmi_info=$response;
 ($w_s_t,$h_s_t)=$response=~/(\d+)x(\d+)/;
 if($w_s_t && $h_s_t) {
  $w_s=$w_s_t;
  $h_s=$h_s_t;
  $max_x=$w_s;
  $max_y=$h_s;
 }
 return $response;
}

###############################################
#             Get EDID function               #
###############################################
sub get_edid(@) {
 my $id = shift;
 my $name = shift;
 my $file = shift;
 my $edid_file="$edid_prefix/card$id/card$id-$name/edid";
 return if(!-f $edid_file);
 &write_file("$file.TMP","$file",&read_from_file("$edid_file"));
}

###############################################
#            Parse EDID function              #
###############################################
sub parse_edid(@) {
 my $file = shift;
 my $content="";
 my @arr_edid=();
 return $no_info_available if(!-e $file);
 open(CMD_PARSER,"timeout 3 $edidparser $file 2>/dev/null|");
 push(@arr_edid,$_) while(<CMD_PARSER>);
 close(CMD_PARSER);
 shift @arr_edid for 1..2;
 pop(@arr_edid);
 $content.= $_ for @arr_edid;
 unlink("$file");
 chomp($content);
 $content=$no_info_available if($content eq "");
 return $content;
}

return 1;
