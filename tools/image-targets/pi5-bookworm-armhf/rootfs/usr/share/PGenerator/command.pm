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
#      Auto-Select 4K 30Hz Mode (KMS)        #
###############################################
sub find_4k30_mode_idx (@) {
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
 return $target_idx;
}

sub auto_select_4k_mode (@) {
 return if($pgenerator_conf{"mode_idx"} ne "");
 return if(!$is_kms);
 my $target_idx=&find_4k30_mode_idx();
 if($target_idx ne "") {
  &sudo("SET_PGENERATOR_CONF","mode_idx","$target_idx");
  $pgenerator_conf{"mode_idx"}="$target_idx";
  &log("Auto-selected 4K 30Hz mode_idx=$target_idx");
 }
}

sub webui_preferred_rgb_quant_range (@) {
 my $quant_range=$webui_rgb_quant_range_preferred;
 $quant_range=$pgenerator_conf{"rgb_quant_range"} if($quant_range eq "");
 $quant_range=2 if($quant_range !~/^[12]$/);
 return $quant_range;
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
  &apply_drm_properties() if($owner_changed);
  return 1;
 }
 &sudo("SET_PGENERATOR_CONF","rgb_quant_range","$quant_range");
 $pgenerator_conf{"rgb_quant_range"}="$quant_range";
 $rgb_quant_range_source=$source;
 &log("Signal range owner: source=$source rgb_quant_range=$quant_range");
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

###############################################
#  Apply DRM Connector Properties (KMS only)  #
###############################################
sub kms_connector_has_property(@) {
 my $prop_name=shift;
 return 0 if(!$is_kms || $prop_name eq "");
 open(MT_PROP,"timeout 3 $modetest -a -c 2>/dev/null|");
 while(<MT_PROP>) {
  if(/^[ \t]*[0-9]+[ \t]+\Q$prop_name\E:/) {
   close(MT_PROP);
   return 1;
  }
 }
 close(MT_PROP);
 return 0;
}

sub modetest_connector_write(@) {
 my ($connector_id,$prop_name,$value)=@_;
 return 0 if(!$is_kms || $connector_id eq "" || $prop_name eq "");
 system("timeout 3 $modetest -a -w '$connector_id:$prop_name:$value' 2>/dev/null");
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

sub drm_mode_info_for_idx(@) {
 my $mode_idx=shift;
 return () if($mode_idx eq "" || $mode_idx !~/^\d+$/);
 open(MT_MODE,"timeout 3 $modetest -c 2>/dev/null|");
 while(<MT_MODE>) {
  if(/^\s*#\Q$mode_idx\E\s+(\S+)\s+([\d.]+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+/) {
   my @mode=($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11);
   close(MT_MODE);
   return @mode;
  }
 }
 close(MT_MODE);
 return ();
}

sub requested_hdmi_tmds_khz(@) {
 my ($pixel_clock,$color_fmt,$max_bpc,$is_dv)=@_;
 return 0 if($pixel_clock eq "" || $pixel_clock <= 0);
 return $pixel_clock if($is_dv);
 return $pixel_clock if($color_fmt == 2);
 $max_bpc=8 if($max_bpc eq "" || $max_bpc < 8);
 return int($pixel_clock * $max_bpc / 8 + 0.5);
}

sub dv_low_latency_enabled(@) {
 return 0 if(!int($pgenerator_conf{"dv_status"} || 0));
 return 1 if(int($pgenerator_conf{"dv_interface"} || 0) == 1);
 return 1 if(int($pgenerator_conf{"is_ll_dovi"} || 0) == 1);
 return 0;
}

sub ensure_hdmi_bandwidth_mode(@) {
 return if(!$is_kms);
 my $is_dv=int($pgenerator_conf{"dv_status"} || 0);
 my $is_lldv=&dv_low_latency_enabled();
 my $color_fmt=$pgenerator_conf{"color_format"};
 my $max_bpc=$pgenerator_conf{"max_bpc"};
 my $mode_idx=$pgenerator_conf{"mode_idx"};
 $color_fmt=($is_lldv ? 2 : 0) if($is_dv);
 $color_fmt=0 if($color_fmt eq "");
 if($is_dv) {
  if($is_lldv) {
   $max_bpc=12 if($max_bpc ne "10" && $max_bpc ne "12");
  } else {
   $max_bpc=8;
  }
 }
 $max_bpc=8 if($max_bpc eq "" || $max_bpc < 8);
 return if($mode_idx eq "");

 my @mode=&drm_mode_info_for_idx($mode_idx);
 return if(!@mode);
 my $pixel_clock=$mode[10];
 my $tmds=&requested_hdmi_tmds_khz($pixel_clock,$color_fmt,$max_bpc,$is_dv);
 return if($tmds <= 600000);

 my $target_idx=&find_4k30_mode_idx();
 if($target_idx ne "" && $target_idx ne $mode_idx) {
  &sudo("SET_PGENERATOR_CONF","mode_idx","$target_idx");
  $pgenerator_conf{"mode_idx"}="$target_idx";
  &log("Adjusted mode_idx from $mode_idx to 4K30 mode_idx=$target_idx for requested HDMI bandwidth ${tmds}kHz");
 } else {
  &log("Requested HDMI bandwidth ${tmds}kHz exceeds 600000kHz and no 4K30 fallback mode was found");
 }
}

sub drm_current_crtc_for_connector(@) {
 my $connector_id=shift;
 my $inside=0;
 my $want_value=0;
 return "" if($connector_id eq "");
 open(MT_CONN,"timeout 3 $modetest -a -c 2>/dev/null|");
 while(<MT_CONN>) {
  if(/^(\d+)\s+\d+\s+(connected|disconnected)\s+/) {
   $inside=($1 == $connector_id) ? 1 : 0;
   $want_value=0;
   next;
  }
  next if(!$inside);
  if(/^\s+\d+\s+CRTC_ID:/) {
   $want_value=1;
   next;
  }
  if($want_value && /^\s+value:\s+(\d+)/) {
   my $crtc_id=$1;
   close(MT_CONN);
   return $crtc_id;
  }
 }
 close(MT_CONN);
 return "";
}

sub drm_primary_plane_for_crtc(@) {
 my $crtc_id=shift;
 return "" if($crtc_id eq "");
 my $mt=`timeout 3 $modetest -a -p 2>/dev/null`;
 my @crtc_ids=();
 my $section="";
 foreach my $line (split(/\n/,$mt)) {
  if($line=~/^CRTCs:/) { $section="crtcs"; next; }
  if($line=~/^Planes:/) { last; }
  if($section eq "crtcs" && $line=~/^(\d+)\s+/) {
   push(@crtc_ids,$1);
  }
 }
 my $crtc_bit=-1;
 for(my $i=0;$i<@crtc_ids;$i++) {
  if($crtc_ids[$i] == $crtc_id) {
   $crtc_bit=1 << $i;
   last;
  }
 }
 return "" if($crtc_bit < 0);

 $section="";
 my $candidate_id="";
 my $candidate_possible=0;
 my $fallback_id="";
 my $reading_type=0;
 foreach my $line (split(/\n/,$mt)) {
  if($line=~/^Planes:/) { $section="planes"; next; }
  next if($section ne "planes");
  if($line=~/^(\d+)\s+\d+\s+\d+\s+.*\s(0x[0-9a-fA-F]+)\s*$/) {
   $candidate_id=$1;
   $candidate_possible=hex($2);
   $reading_type=0;
   if(($candidate_possible & $crtc_bit) && $fallback_id eq "") {
    $fallback_id=$candidate_id;
   }
   next;
  }
  if($candidate_id ne "" && $line=~/^\s+\d+\s+type:/) {
   $reading_type=1;
   next;
  }
  if($reading_type && $line=~/^\s+value:\s+(\d+)/) {
   if($1 == 1 && ($candidate_possible & $crtc_bit)) {
    return $candidate_id;
   }
   $reading_type=0;
  }
 }
 return $fallback_id;
}

sub prearm_drm_mode(@) {
 return if(!$is_kms);
 my $is_dv=int($pgenerator_conf{"dv_status"} || 0);
 my $is_lldv=&dv_low_latency_enabled();
 my $is_hdr=int($pgenerator_conf{"is_hdr"} || 0);
 my $color_fmt=$pgenerator_conf{"color_format"};
 my $max_bpc=$pgenerator_conf{"max_bpc"};
 my $mode_idx=$pgenerator_conf{"mode_idx"};
 $color_fmt=($is_lldv ? 2 : 0) if($is_dv);
 $color_fmt=0 if($color_fmt eq "");
 if($is_dv) {
  if($is_lldv) {
   $max_bpc=12 if($max_bpc ne "10" && $max_bpc ne "12");
  } else {
   $max_bpc=8;
  }
 }
 $max_bpc=8 if($max_bpc eq "" || $max_bpc < 8);
 return if($mode_idx eq "");
 return if($color_fmt == 0 && $max_bpc <= 8 && !$is_hdr && !$is_dv);

 my $connector_id="";
 open(MT,"timeout 3 $modetest -a -c 2>/dev/null|");
 while(<MT>) {
  if(/^(\d+)\s+\d+\s+connected\s+HDMI/) {
   $connector_id=$1;
   last;
  }
 }
 close(MT);
 return if($connector_id eq "");

 my @mode=&drm_mode_info_for_idx($mode_idx);
 if(!@mode) {
  &log("DRM: pre-arm skipped; mode_idx=$mode_idx was not found");
  return;
 }
 my ($mode_name,$refresh,$hdisp,$hss,$hse,$htot,$vdisp,$vss,$vse,$vtot,$clock)=@mode;
 my $crtc_id=&drm_current_crtc_for_connector($connector_id);
 my $plane_id=&drm_primary_plane_for_crtc($crtc_id);
 if($crtc_id eq "" || $plane_id eq "") {
  &log("DRM: pre-arm skipped; connector=$connector_id crtc=$crtc_id plane=$plane_id");
  return;
 }

 my $colorspace=&map_kms_colorspace($pgenerator_conf{"colorimetry"},$color_fmt);
 my $broadcast_rgb=&map_broadcast_rgb($pgenerator_conf{"rgb_quant_range"});
 my $fb_fmt=($max_bpc > 8) ? "XR30" : "XR24";
 my $refresh_int=int($refresh + 0.5);
 $refresh_int=30 if($refresh_int < 1);
 my $mode_arg="$hdisp,$hss,$hse,$htot,$vdisp,$vss,$vse,$vtot-$refresh_int";
 my $cmd="timeout 3 $modetest -a -v ".
  "-w '$connector_id:max bpc:$max_bpc' ".
  "-w '$connector_id:output format:$color_fmt' ".
  "-w '$connector_id:Colorspace:$colorspace' ".
  "-w '$connector_id:Broadcast RGB:$broadcast_rgb' ".
  "-s '$connector_id\@$crtc_id:$mode_arg\@$fb_fmt' ".
  ">/tmp/pgenerator_prearm.log 2>&1";
 system($cmd);
 &log("DRM: pre-armed connector=$connector_id crtc=$crtc_id plane=$plane_id mode=$mode_name/${refresh}Hz bpc=$max_bpc output_format=$color_fmt fb=$fb_fmt");
}

###############################################
#  Apply DRM Connector Properties (KMS only)  #
###############################################
sub apply_drm_properties (@) {
 return if(!$is_kms);
 my $is_dv=int($pgenerator_conf{"dv_status"} || 0);
 my $is_lldv=&dv_low_latency_enabled();
 # Find connected HDMI connector ID
 my $connector_id="";
 open(MT,"timeout 3 $modetest -c 2>/dev/null|");
 while(<MT>) {
  if(/^(\d+)\s+\d+\s+connected\s+HDMI/) {
   $connector_id=$1;
   last;
  }
 }
 close(MT);
 return if($connector_id eq "");
 # Set max bpc — the binary fails to apply this property
 my $max_bpc=$pgenerator_conf{"max_bpc"};
 if($is_dv) {
  if($is_lldv) {
   $max_bpc=12 if($max_bpc ne "10" && $max_bpc ne "12");
  } else {
   $max_bpc=8;
  }
 }
 if($max_bpc ne "" && $max_bpc > 0) {
  if(&modetest_connector_write($connector_id,"max bpc",$max_bpc)) {
   &log("DRM: Set max bpc=$max_bpc on connector $connector_id");
  } else {
   &log("DRM: Failed to set max bpc=$max_bpc on connector $connector_id");
  }
 }
 # Reset output format — kernel retains previous value across binary
 # restarts.  A previous 10bpc run may have caused a YCbCr 4:2:2
 # fallback that sticks even after switching back to 8bpc RGB.
 my $color_fmt=$pgenerator_conf{"color_format"};
 $color_fmt=($is_lldv ? 2 : 0) if($is_dv);
 $color_fmt=0 if($color_fmt eq "");
 if($color_fmt > 2) {
  &log("DRM: output format=$color_fmt is unsupported on Pi 5; using RGB output");
  $color_fmt=0;
 }
 if(&kms_connector_has_property("output format")) {
  if(&modetest_connector_write($connector_id,"output format",$color_fmt)) {
   &log("DRM: Set output format=$color_fmt on connector $connector_id");
  } else {
   &log("DRM: Failed to set output format=$color_fmt on connector $connector_id");
  }
 } elsif($color_fmt != 0) {
  &log("DRM: output format property missing; YCbCr request cannot change HDMI transport");
 }
 # Set quantization range (enums: Default=0 Limited=1 Full=2)
 my $quant_range=$pgenerator_conf{"rgb_quant_range"};
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
  &modetest_connector_write($connector_id,"Colorimetry",$colorimetry);
  &modetest_connector_write($connector_id,"Colorspace",$colorspace);
  &log("DRM: Set Colorimetry=$colorimetry / Colorspace=$colorspace on connector $connector_id");
 }
}

sub apply_hdr_metadata_helper (@) {
 my $helper="/usr/bin/pgsethdr";
 return if(!$is_kms || !-x $helper);
 if(int($pgenerator_conf{"dv_status"} || 0) == 1 || int($pgenerator_conf{"is_ll_dovi"} || 0) == 1 || int($pgenerator_conf{"is_std_dovi"} || 0) == 1) {
  &log("DRM: skipping HDR metadata helper while Dolby Vision metadata is active");
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

sub kms_connector_has_hdr_metadata(@) {
 return 0 if(!$is_kms);
 my $mt=`timeout 3 $modetest -a -c 2>/dev/null`;
 my $inside_connected=0;
 my $in_hdr=0;
 my $lines_left=0;
 foreach my $line (split(/\n/,$mt)) {
  if($line=~/^(\d+)\s+\d+\s+(connected|disconnected)\s+HDMI/) {
   $inside_connected=($2 eq "connected") ? 1 : 0;
   $in_hdr=0;
   $lines_left=0;
   next;
  }
  next if(!$inside_connected);
  if($line=~/^\s+\d+\s+HDR_OUTPUT_METADATA:/) {
   $in_hdr=1;
   $lines_left=8;
   next;
  }
  if($in_hdr) {
   return 1 if($line=~/^\s+[0-9a-fA-F]{16,}\s*$/);
   $lines_left--;
   if($lines_left <= 0 || $line=~/^\s+\d+\s+\S.*:/) {
    $in_hdr=0;
    $lines_left=0;
   }
  }
 }
 return 0;
}

sub set_pgenerator_conf_runtime(@) {
 my ($key,$value)=@_;
 &sudo("SET_PGENERATOR_CONF",$key,$value);
 $pgenerator_conf{$key}="$value";
}

sub warm_hdr_rgb_transport(@) {
 return if(!$is_kms);
 return if(&kms_connector_has_hdr_metadata());
 return if(int($pgenerator_conf{"is_hdr"} || 0) != 1);
 return if(int($pgenerator_conf{"dv_status"} || 0) == 1);
 return if(int($pgenerator_conf{"is_ll_dovi"} || 0) == 1);
 return if(int($pgenerator_conf{"is_std_dovi"} || 0) == 1);
 return if(($pgenerator_conf{"color_format"} || "0") ne "0");
 return if(($pgenerator_conf{"max_bpc"} || 8) < 10);

 my %orig=(
  color_format => ($pgenerator_conf{"color_format"} || "0"),
  rgb_quant_range => ($pgenerator_conf{"rgb_quant_range"} || "2"),
  colorimetry => ($pgenerator_conf{"colorimetry"} || "9"),
  max_bpc => ($pgenerator_conf{"max_bpc"} || "10")
 );

 &log("DRM: warming HDR RGB with temporary YCbCr 4:4:4 10-bit start");
 &set_pgenerator_conf_runtime("color_format","1");
 &set_pgenerator_conf_runtime("rgb_quant_range","1");
 &set_pgenerator_conf_runtime("colorimetry","9");
 &set_pgenerator_conf_runtime("max_bpc","10");

 &apply_drm_properties();
 &prearm_drm_mode();
 system("MALLOC_CHECK_=0 LD_PRELOAD=/usr/lib/drm_override.so LD_LIBRARY_PATH=/usr/lib $pattern_generator $w_s $h_s >/dev/null 2>&1 &");
 usleep(2200000);
 &apply_drm_properties();
 usleep(800000);
 &process_pid("$pattern_generator","kill");
 usleep(500000);

 foreach my $key (keys %orig) {
  &set_pgenerator_conf_runtime($key,$orig{$key});
 }
 &apply_drm_properties();
 &prearm_drm_mode();
 &log("DRM: restored requested HDR RGB output after warm-up");
}

###############################################
#       Pattern Generator Start Function      #
###############################################
sub pattern_generator_start(@) {
 my $no_clean_files = shift;
 my $use_drm_override=1;
 my $has_dovi_metadata=1;
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
 &auto_select_4k_mode();
 &ensure_hdmi_bandwidth_mode();
 &apply_drm_properties();
 &prearm_drm_mode();
 &warm_hdr_rgb_transport();
 &get_hdmi_info();
 if($is_kms && &kms_connector_has_property("Colorspace") && !&kms_connector_has_property("Colorimetry") && !&kms_connector_has_property("output format")) {
  $use_drm_override=0;
  &log("DRM: Colorspace-only kernel detected; starting renderer without drm_override.so");
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
 if($use_drm_override) {
  system("MALLOC_CHECK_=0 LD_PRELOAD=/usr/lib/drm_override.so LD_LIBRARY_PATH=/usr/lib $binary $w_s $h_s >/dev/null 2>&1 &");
 } else {
  system("MALLOC_CHECK_=0 LD_LIBRARY_PATH=/usr/lib $binary $w_s $h_s >/dev/null 2>&1 &");
 }
 usleep(750000);
 # The renderer performs the real KMS modeset. Reapply connector properties
 # after launch so deep-color RGB/4:4:4 is checked against the new mode.
 &apply_drm_properties();
 if(!$use_drm_override) {
  &log("DRM: skipping post-launch modetest reapply on Colorspace-only kernel");
  &apply_hdr_metadata_helper();
  unlink("$info_dir/GET_PGENERATOR_IS_EXECUTED.info");
  &get_pattern($test_template_command,"$pattern_start","$rgb","pattern_generator_start") if(!$no_clean_files);
  return;
 }
 if(!$no_clean_files && !&pattern_generator_is_running()) {
  &log("DRM: renderer did not stay running after launch");
 }
 &apply_hdr_metadata_helper();
 unlink("$info_dir/GET_PGENERATOR_IS_EXECUTED.info");
 &get_pattern($test_template_command,"$pattern_start","$rgb","pattern_generator_start") if(!$no_clean_files);
}

###############################################
#      Pattern Generator Stop Function        #
###############################################
sub pattern_generator_stop {
 my $pid = "";
 &video_program_stop("$program_video_to_kill");
 &process_pid("$pattern_generator","kill");
 # Also kill the .dv variant in case we're switching modes
 &process_pid("${pattern_generator}.dv","kill") if(-x "${pattern_generator}.dv");
 usleep(500000);
 while(($pid=&process_pid("$pattern_generator","get"))) {
  &process_pid("$pattern_generator","kill");
  usleep(500000);
 }
 # Ensure .dv variant is also gone
 while(-x "${pattern_generator}.dv" && ($pid=&process_pid("${pattern_generator}.dv","get"))) {
  &process_pid("${pattern_generator}.dv","kill");
  usleep(500000);
 }
 &clean_files();
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
 &remove_files("$var_dir",".*");
 &remove_files("$var_dir/frames/",".*");
 &remove_files("$var_dir/running/",".*");
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
 if($cmd =~/SET_PGENERATOR_CONF_(IS_SDR|IS_HDR|IS_LL_DOVI|IS_STD_DOVI|EOTF|PRIMARIES|MAX_LUMA|MIN_LUMA|MAX_CLL|MAX_FALL|COLOR_FORMAT|COLORIMETRY|RGB_QUANT_RANGE|MAX_BPC|DV_STATUS|DV_INTERFACE|DV_PROFILE|DV_MAP_MODE|DV_MINPQ|DV_MAXPQ|DV_DIAGONAL|MODE_IDX|DV_METADATA|DV_COLOR_SPACE):(.*)/) {
  &sudo("SET_PGENERATOR_CONF",lc($1),$2);
  $pgenerator_conf{lc($1)}=$2;
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
   &sudo("SET_PGENERATOR_CONF","mode_idx",$2);
   $pgenerator_conf{"mode_idx"}=$2;
   unlink("$info_dir/GET_MODES_AVAILABLE.info");
   unlink("$info_dir/GET_MODE.info");
   unlink("$info_dir/GET_HDMI_INFO.info");
   unlink("$info_dir/GET_REFRESH.info");
   unlink("$info_dir/GET_OUTPUT_RANGE.info");
   unlink("$info_dir/GET_RESOLUTION.info");
  }
  # End for RPI p4
  &pattern_generator_stop();
  &pattern_generator_start();
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
 return if(($process_pid=&process_pid("$wpa_cli","get")) eq "");
 return &sudo("$el[0]","$interface") if($el[0] eq "WIFI_SCAN" || $el[0] eq "GET_WIFI_STATUS");
 if($el[0] eq "GETNETCONFIGURED") {
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
 my $ps_proc = "";
 my $ps_proc=&process_pid("$pattern_generator","get");
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
sub sudo(@) {
 my @arg_base64 = ();
 for(@_) { 
  push(@arg_base64,encode_base64($_,""));
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
   $found_output=1    if(/active color format|output format/);
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
  $hdmi_range="limited"   if($range == 1);
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
