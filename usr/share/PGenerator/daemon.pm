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
#            Fork Daemon Function             #
###############################################
sub fork_pattern_daemon (@) {
 my $pid_killed="";
 chdir($pwd);
 mkdir("$var_dir") if (!-d "$var_dir");
 $|=1;
 if(fork() == 0 ){
  $SIG{PIPE}='IGNORE';
  open(STDERR,">>/tmp/pg_stderr.log");
  &boot_time_mark("daemon: start");
  # A refusal ends with the daemon; what a refused apply goes back to until
  # the first one passes is the conf found now.
  &signal_state_reset();
  # The WebUI first: it answers while the renderer starts (it already runs
  # beside every later renderer restart), so a slow HDMI handshake no
  # longer delays it. The pattern ports open after the boot plate.
  &lg_startup_scan_prepare();
  threads->create(\&webui_http)->detach();
  threads->create(\&webui_mdns)->detach();
  &pattern_generator_start();
  &boot_time_mark("daemon: renderer ".(&pattern_generator_is_running() ? "running" : "not running"));
  &show_boot_pattern();
  &boot_time_mark("daemon: boot plate done");
  threads->create(\&device_info)->detach();
  threads->create(\&discovery_devicecontrol)->detach();
  threads->create(\&discovery_lightspace)->detach();
  threads->create(\&discovery_rpc)->detach();
  threads->create(\&resolve_connection_thread)->detach();
  threads->create(\&lg_startup_scan_worker)->detach();
  # HDMI link interruptions during measurements (refused settings' sibling).
  threads->create(\&webui_hdmi_link_watch)->detach() if($is_kms);
  # TV remote listener for the on-screen menu (setting on by default).
  &webui_tvmenu_boot();
  &pattern_daemon();
  exit;
 }
}

###############################################
#            Reference APL Helpers            #
###############################################
sub calman_apl_levels (@) {
 my $full_max=&calman_target_max();
 my %bit_depth_for_max=(255 => 8, 1023 => 10, 4095 => 12);
 my $bits=$bit_depth_for_max{$full_max} || int($bits_default || 8);
 my $shift=$bits - 8;
 my $range_mode=int($pgenerator_conf{"rgb_quant_range"} || 0);
 my $limited_min=16 << $shift;
 my $limited_span=219 << $shift;
 return ($limited_min,$limited_span,$limited_min + $limited_span,"limited") if($range_mode == 1);
 return (0,$full_max,$full_max,"full");
}

sub calman_dv_source_max (@) {
 return 4095 if(int($pgenerator_conf{"dv_status"} || 0) == 1 &&
                int($pgenerator_conf{"is_std_dovi"} || 0) == 1);
 return 0;
}

sub calman_target_max (@) {
 my $dv_source_max=&calman_dv_source_max();
 return $dv_source_max if($dv_source_max > 0);
 # $bits_default is per thread but %pgenerator_conf is shared: a bit depth
 # the WebUI set while Calman was connected left this thread at the old one.
 &sync_pattern_bits_default();
 my $bits=int($bits_default || 8);
 return 1023 if($bits == 10);
 return 4095 if($bits == 12);
 return 255;
}

sub calman_scale_value (@) {
 my $value=int(shift);
 my $input_max=int(shift);
 my $target_max=&calman_target_max();
 my %bit_depth_for_max=(255 => 8, 1023 => 10, 4095 => 12);
 $input_max=255 if($input_max <= 0);
 $value=0 if($value < 0);
 $value=$input_max if($value > $input_max);
 return $value if($input_max == $target_max);
 if($bit_depth_for_max{$input_max} && $bit_depth_for_max{$target_max}) {
  my $src_bits=$bit_depth_for_max{$input_max};
  my $dst_bits=$bit_depth_for_max{$target_max};
  return $target_max if($value >= $input_max);
  return $value << ($dst_bits - $src_bits) if($dst_bits > $src_bits);
  if($dst_bits < $src_bits) {
   # Round to the nearest code instead of dropping the low bits (283 at
   # 10 bit is 70.75 at 8 bit: 71, not 70). Codes that are exact multiples
   # (an 8 bit Calman sends 4*v) are unchanged. A code that cannot be
   # represented is flagged so the caller can tell the user once.
   my $shift=$src_bits - $dst_bits;
   $calman_precision_lost=1 if($value & ((1 << $shift) - 1));
   my $rounded=($value + (1 << ($shift - 1))) >> $shift;
   return $rounded > $target_max ? $target_max : $rounded;
  }
 }
 return int($value/$input_max*$target_max + 0.5);
}

sub calman_scale_triplet_8bit (@) {
 my $r=shift;
 my $g=shift;
 my $b=shift;
 return &calman_scale_value($r,255).",".&calman_scale_value($g,255).",".&calman_scale_value($b,255);
}

sub calman_valid_bpc (@) {
 my $value=int(shift || 0);
 return "$value" if($value == 8 || $value == 10 || $value == 12);
 return "";
}

sub calman_choose_bpc (@) {
 my ($explicit_bpc,$current_bpc,$fallback_bpc,$preserve_current)=@_;
 my $explicit=&calman_valid_bpc($explicit_bpc);
 return $explicit if($explicit ne "");
 if($preserve_current) {
  my $current=&calman_valid_bpc($current_bpc);
  return $current if($current ne "");
 }
 my $fallback=&calman_valid_bpc($fallback_bpc);
 return $fallback if($fallback ne "");
 return "10";
}

sub calman_parse_source_format_payload (@) {
 my $payload=shift || "";
 my $default_format_bpc=int(shift || 0);
 my %parsed=(color_format=>"",max_bpc=>"",range=>"");
 my $format_text="";
 if($payload =~/(?:^|[,;])\s*(?:1_)?FORMAT\s*=\s*([^,;]+)/i) {
  $format_text=$1;
 } elsif($payload =~/(?:^|[,;])\s*Color\s*Format\s*=\s*([^,;]+)/i) {
  $format_text=$1;
 } elsif($payload !~/=/) {
  $format_text=$payload;
  $format_text=~s/^\s*Format\s+//i;
 }
 $format_text=~s/^\s+|\s+$//g;
 if($format_text ne "") {
  my $fmt_norm=uc($format_text);
  $fmt_norm=~s/[^A-Z0-9]//g;
  if($fmt_norm =~/(?:YCBCR|YCC|YUV)444/) {
   $parsed{color_format}="1";
  } elsif($fmt_norm =~/(?:YCBCR|YCC|YUV)422/) {
   $parsed{color_format}="2";
  } elsif($fmt_norm =~/(?:YCBCR|YCC|YUV)420/) {
   $parsed{color_format}="3";
  } elsif($fmt_norm =~/RGB/) {
   $parsed{color_format}="0";
  }
  if($format_text =~/(?:^|[^0-9])(8|10|12)\s*(?:[-_\s])*(?:bit|bpc)\b/i ||
     $format_text =~/(?:RGB|YCC|YCBCR|YUV)[A-Z0-9:_\s-]*?(8|10|12)\s*$/i) {
   $parsed{max_bpc}=&calman_valid_bpc($1);
  }
 }
 if($payload =~/(?:^|[,;])\s*Bits?\s*=\s*(8|10|12)\b/i ||
    $payload =~/(?:^|\s)Bits?\s+(8|10|12)\b/i) {
  $parsed{max_bpc}=&calman_valid_bpc($1);
 }
 if($default_format_bpc && $parsed{color_format} ne "" && $parsed{max_bpc} eq "") {
  $parsed{max_bpc}="8";
 }
 if($payload =~/(?:^|[,;])\s*Range\s*=\s*([^,;]+)/i ||
    $payload =~/(?:^|\s)Range\s+(.+)$/i) {
  my $range_text=$1;
  $range_text=~s/^\s+|\s+$//g;
  if($range_text =~/(full|pc)/i) {
   $parsed{range}="2";
  } elsif($range_text =~/(limit|video|smpte)/i) {
   $parsed{range}="1";
  } elsif($range_text =~/default/i) {
   $parsed{range}="0";
  }
 }
 return %parsed;
}

sub calman_split_command (@) {
 my $key=shift || "";
 return ("","") if($key !~/:/);
 my ($type,$payload)=split(/:/,$key,2);
 return ($type,$payload);
}

sub calman_apl_bg (@) {
 my $rgb=shift;
 my $win_pct=shift;
 my $source=shift;
 my $bg=&calman_current_bg();
 return $bg if(!$calman_apl_enabled);
 return &calman_apl_bg_value($rgb,$win_pct,$calman_apl,$source,$bg);
}

sub calman_apl_bg_value (@) {
 my $rgb=shift;
 my $win_pct=shift;
 my $apl_pct=shift;
 my $source=shift;
 my $fallback_bg=shift;
 my ($r,$g,$b)=split(",",$rgb);
 $fallback_bg="0,0,0" if($fallback_bg eq "");
 return $fallback_bg if($r eq "" || $g eq "" || $b eq "");
 $win_pct=$calman_win_size if($win_pct eq "" || $win_pct <= 0);
 $win_pct=100 if($win_pct > 100);
 if($win_pct >= 100) {
  &log("Calman APL: source=$source size=$win_pct% is full field, background ignored");
  return $fallback_bg;
 }
 $apl_pct=$apl_pct + 0;
 $apl_pct=0 if($apl_pct < 0);
 $apl_pct=100 if($apl_pct > 100);
 my ($min_level,$range_span,$max_level,$range_name)=&calman_apl_levels();
 return $fallback_bg if($range_span <= 0);
 my $y=(0.2126 * $r) + (0.7152 * $g) + (0.0722 * $b);
 my $fg_pct=(($y - $min_level) * 100 / $range_span);
 $fg_pct=0 if($fg_pct < 0);
 my $win_frac=$win_pct / 100;
 my $bg_frac=1 - $win_frac;
 return $fallback_bg if($bg_frac <= 0);
 my $fg_contrib=$fg_pct * $win_frac;
 my $bg_pct=($apl_pct - $fg_contrib) / $bg_frac;
 $bg_pct=0 if($bg_pct < 0);
 $bg_pct=100 if($bg_pct > 100);
 my $bg_y=$min_level + ($bg_pct * $range_span / 100);
 $bg_y=int($bg_y + 0.5);
 $bg_y=0 if($bg_y < 0);
 $bg_y=$max_level if($bg_y > $max_level);
 my $bg_str="$bg_y,$bg_y,$bg_y";
 &log("Calman APL: source=$source apl=$apl_pct% size=$win_pct% fg=$rgb fg_pct=$fg_pct bg_pct=$bg_pct bg=$bg_str range=$range_name");
 return $bg_str;
}

sub calman_commandrgb_window (@) {
 my $rgb=shift;
 my $size_token=int(shift);
 my $source=shift;
 my $win_pct=10;
 my $apl_pct=18;
 my $bg_str=&calman_black_bg();
 if($size_token >= 1 && $size_token <= 100) {
  $win_pct=$size_token;
  &log("Calman: $source direct window token=$size_token -> size=$win_pct apl=0");
  return ($win_pct,$bg_str);
 }
 if($size_token >= 101 && $size_token <= 998) {
  $win_pct=10;
  $apl_pct=$size_token - 100;
  $bg_str=&calman_apl_bg_value($rgb,$win_pct,$apl_pct,"$source preset",&calman_black_bg());
  &log("Calman: $source preset APL token=$size_token -> size=$win_pct apl=$apl_pct");
  return ($win_pct,$bg_str);
 }
 if($size_token == 999) {
  $win_pct=$calman_win_size if($calman_win_size > 0);
  $win_pct=10 if($win_pct < 1);
  $win_pct=100 if($win_pct > 100);
  $apl_pct=$calman_apl + 0;
  $bg_str=&calman_apl_bg_value($rgb,$win_pct,$apl_pct,"$source custom",&calman_black_bg());
  &log("Calman: $source custom token=999 -> size=$win_pct apl=$apl_pct");
  return ($win_pct,$bg_str);
 }
 $win_pct=$calman_win_size if($calman_win_size > 0);
 $win_pct=10 if($win_pct < 1);
 $win_pct=100 if($win_pct > 100);
 &log("Calman: $source legacy token=$size_token -> size=$win_pct apl=0");
 return ($win_pct,$bg_str);
}

sub calman_reset_pattern_state (@) {
 my $source=shift;
 $calman_apl=18;
 $calman_apl_enabled=0;
 $calman_bg="";
 $calman_win_size=10;
 $calman_explicit_max_bpc=0;
 # 0: the client has not asked for a range; the WebUI setting applies.
 $calman_rgb_quant_range=0;
 &calman_clear_last_pattern();
 &log("Calman: reset pattern state ($source)") if($source ne "");
}

# Modes of the connected HDMI connector as modetest lists them.
sub calman_connected_modes (@) {
 my @modes=();
 open(my $mt_fh,"$modetest 2>/dev/null|");
 my $mt_connected=0;
 while(my $ml=<$mt_fh>) {
  $mt_connected=1 if($ml =~/\s+connected/);
  next if(!$mt_connected);
  # Mode line: #idx WxH[i] rate ... flags ...; type: ...
  next if($ml !~/^\s*#(\d+)\s+(\d+)x(\d+)(i?)\s+([\d.]+)\s+.*type:\s*(.*)/);
  push(@modes,{idx=>$1,w=>int($2),h=>int($3),ip=>($4 eq "i") ? "i" : "p",rate=>$5 + 0,type=>$6});
 }
 close($mt_fh);
 return @modes;
}

sub calman_find_mode_idx (@) {
 my ($req_w,$req_h,$req_ip,$req_rate)=@_;
 return -1 if(!$req_h || !$req_rate);
 $req_ip=defined($req_ip) && $req_ip ne "" ? lc($req_ip) : "p";
 my $best_idx=-1;
 my $best_score=0;
 foreach my $m (&calman_connected_modes()) {
  next if($m->{h} != $req_h || $m->{ip} ne $req_ip);
  # Tolerate reference integer labels for fractional HDMI modes.
  my $rate_match=(int($m->{rate}) == int($req_rate)) || (abs($m->{rate} - ($req_rate + 0)) < 0.25);
  next if(!$rate_match);
  # Score: exact width > exact rate > EDID timing > preferred. The userdef
  # mode from the video= boot argument has no CTA sync polarity, so the
  # kernel sends it with VIC 0 and a full-range AVI infoframe; the EDID
  # copy of the same timing carries the VIC and the limited range.
  my $score=1;
  $score+=100 if($req_w && $m->{w} == $req_w);
  $score+=20  if(abs($m->{rate} - ($req_rate + 0)) < 0.01);
  $score+=10  if($m->{type} !~/userdef/);
  $score+=5   if($m->{type} =~/preferred/);
  if($score > $best_score) {
   $best_idx=$m->{idx};
   $best_score=$score;
  }
 }
 return $best_idx;
}

sub calman_apply_init_mode (@) {
 my $init_mode_idx=$pgenerator_conf{"calman_mode_idx"} || "";
 if($init_mode_idx eq "" || $init_mode_idx !~/^\d+$/) {
  my $default_idx=&calman_find_mode_idx(1920,1080,"p",24);
  if($default_idx >= 0) {
   $init_mode_idx=$default_idx;
   &sudo("SET_PGENERATOR_CONF","calman_mode_idx","$init_mode_idx");
   $pgenerator_conf{"calman_mode_idx"}="$init_mode_idx";
   &log("Calman: default init mode remembered as 1080p24 mode_idx=$init_mode_idx");
  }
 }
 return if($init_mode_idx eq "" || $init_mode_idx !~/^\d+$/);
 # Remembered before the EDID timing was preferred: move to the same mode
 # from the EDID so the infoframe carries the VIC and the range.
 my ($remembered)=grep { $_->{idx} == $init_mode_idx } &calman_connected_modes();
 if($remembered && $remembered->{type} =~/userdef/) {
  my $edid_idx=&calman_find_mode_idx($remembered->{w},$remembered->{h},$remembered->{ip},$remembered->{rate});
  if($edid_idx >= 0 && $edid_idx != $init_mode_idx) {
   &log("Calman: remembered mode_idx=$init_mode_idx is the userdef boot mode, using mode_idx=$edid_idx");
   $init_mode_idx=$edid_idx;
   &sudo("SET_PGENERATOR_CONF","calman_mode_idx","$init_mode_idx");
   $pgenerator_conf{"calman_mode_idx"}="$init_mode_idx";
  }
 }
 if(($pgenerator_conf{"mode_idx"} || "") ne $init_mode_idx) {
  &log("Calman: INIT applying remembered mode_idx=$init_mode_idx");
  &pgenerator_cmd("SET_MODE:$init_mode_idx");
 }
}
#
# Track whether any reference connection is currently using the GCI
# (UPGCI 2.0) control plane. The flag is mirrored into PGenerator.conf
# so that drm_override.so can suppress its connector-property overrides
# while GCI is driving PGenerator. The flag is per-connection
# ($calman_gci{$connection}) and global ($calman_gci_active_count) so
# we can clear the conf key only when the last GCI client disconnects.
#
sub calman_set_gci_active (@) {
 my $active=shift;
 if($active) {
  $calman_gci_active_count++ if(!$calman_gci_active_count);
  $calman_gci_active_count=1 if($calman_gci_active_count < 1);
  &sudo("SET_PGENERATOR_CONF","calman_gci","1") if(($pgenerator_conf{"calman_gci"} || "") ne "1");
  $pgenerator_conf{"calman_gci"}="1";
  &log("Calman GCI: control plane active — drm_override will not override connector properties");
  return;
 }
 $calman_gci_active_count=0 if(!defined $calman_gci_active_count || $calman_gci_active_count < 1);
 # Caller (close_connection / TERM / SHUTDOWN / QUIT) is responsible
 # for having decremented $calman_gci_active_count and deleting the
 # per-connection entry from %calman_gci before calling this with 0.
 &sudo("SET_PGENERATOR_CONF","calman_gci","0") if(($pgenerator_conf{"calman_gci"} || "") ne "0");
 $pgenerator_conf{"calman_gci"}="0";
 &log("Calman GCI: control plane cleared — drm_override may resume overriding connector properties");
}
#
# Drop the per-connection GCI flag and, if this was the last GCI
# client, clear the global PGenerator.conf flag so drm_override.so
# resumes overriding connector properties. Safe to call from any
# teardown path (close_connection, TERM, SHUTDOWN, QUIT).
#
sub calman_clear_gci_connection (@) {
 my $connection=shift;
 return if(!$connection);
 return if(!$calman_gci{$connection});
 delete $calman_gci{$connection};
 $calman_gci_active_count-- if(defined $calman_gci_active_count && $calman_gci_active_count > 0);
 if(!defined $calman_gci_active_count || $calman_gci_active_count < 1) {
  $calman_gci_active_count=0;
  &calman_set_gci_active(0);
 }
}

# Every range the client sets is applied to the conf, and the WebUI can
# change it during or between sessions: read the conf, not a session copy.
sub calman_pattern_source_range (@) {
 return "LIMITED" if(&effective_rgb_quant_range() == 1);
 return "";
}

# Black in the codes the renderer gets. SOURCE_RANGE=LIMITED codes are
# video levels, so code 0 would sit below black: YCbCr links carry it as
# Y=0 instead of 16/64/256.
sub calman_black_bg (@) {
 return "0,0,0" if(&calman_pattern_source_range() ne "LIMITED");
 my $black=16*(&calman_target_max()+1)/256;
 return "$black,$black,$black";
}

# Background Calman set with RGB_B, or black when it has not set one.
sub calman_current_bg (@) {
 return ($calman_bg ne "") ? $calman_bg : &calman_black_bg();
}

# Black of the start pattern (PatternStart, drawn on every renderer start:
# boot, /api/restart, hotplug): the same codes as an idle Calman window,
# with the SOURCE_RANGE and SOURCE_MAX the renderer needs to read them.
# The template's code 0 put Y=0 on a Limited YCbCr link instead of 16/64.
# Returns (triplet, source range, source max).
sub pattern_start_black (@) {
 return (&calman_black_bg(),&calman_pattern_source_range(),&calman_dv_source_max());
}

sub calman_patch_context (@) {
 return "mode_idx=".($pgenerator_conf{"mode_idx"}||"").
        " renderer=${w_s}x${h_s}".
        " is_hdr=".($pgenerator_conf{"is_hdr"}||"0").
        " eotf=".($pgenerator_conf{"eotf"}||"").
        " dv_status=".($pgenerator_conf{"dv_status"}||"0").
        " is_std_dovi=".($pgenerator_conf{"is_std_dovi"}||"0").
        " dv_map_mode=".($pgenerator_conf{"dv_map_mode"}||"").
        " dv_metadata=".($pgenerator_conf{"dv_metadata"}||"").
        " color_format=".($pgenerator_conf{"color_format"}||"").
        " colorimetry=".($pgenerator_conf{"colorimetry"}||"").
        " max_bpc=".($pgenerator_conf{"max_bpc"}||"").
        " rgb_quant_range=".($pgenerator_conf{"rgb_quant_range"}||"");
}

sub calman_clear_last_pattern (@) {
 $calman_last_pattern_kind="";
 $calman_last_pattern_type="";
 $calman_last_pattern_cmd="";
}

sub calman_remember_pattern (@) {
 my $kind=shift;
 my $type=shift;
 my $cmd=shift;
 return if($calman_replaying_last_pattern);
 $calman_last_pattern_kind="$kind";
 $calman_last_pattern_type="$type";
 $calman_last_pattern_cmd="$cmd";
 &log("Calman: remembered last pattern kind=$kind type=$type");
}

sub calman_render_commandrgb_pattern (@) {
 my $pattern_cmd=shift;
 my $connection=shift;
 my @el_cmd=split(",",$pattern_cmd);
 my $cr_r_in=int($el_cmd[0]);
 my $cr_g_in=int($el_cmd[1]);
 my $cr_b_in=int($el_cmd[2]);
 my $cr_tenBit=int($el_cmd[3]);
 my $cr_size=int($el_cmd[4]);
 my $target_max=&calman_target_max();
 my $source_max=&calman_dv_source_max();
 my $input_max=$cr_tenBit ? 1023 : 255;
 my $cr_r=&calman_scale_value($cr_r_in,$input_max);
 my $cr_g=&calman_scale_value($cr_g_in,$input_max);
 my $cr_b=&calman_scale_value($cr_b_in,$input_max);
 my ($cr_size_effective,$cr_bg)=&calman_commandrgb_window("$cr_r,$cr_g,$cr_b",$cr_size,"CommandRGB");
 my $cr_rgb="$cr_r,$cr_g,$cr_b";
 &apply_source_rgb_quant_range("calman",$calman_rgb_quant_range) if($calman_rgb_quant_range =~/^[12]$/);
 my $cr_source_range=&calman_pattern_source_range();
 &log_calman_patch(type=>"CommandRGB",
                   raw=>"$cr_r_in,$cr_g_in,$cr_b_in",
                   scaled=>"$cr_r,$cr_g,$cr_b",
                   win=>$cr_size_effective,
                   bg=>$cr_bg,
                   range=>$cr_source_range,
                   peer=>$connection ? $client_ip{$connection} : "",
                   extra=>"tenBit=$cr_tenBit size_token=$cr_size target_max=$target_max input_max=$input_max ".&calman_patch_context());
 &clean_pattern_files();
 if($cr_size_effective >= 100) {
  &create_pattern_file("RECTANGLE","$w_s,$h_s",100,"$cr_rgb","$cr_bg","","","",1,"calman",$cr_source_range,$source_max);
 } else {
  my $sqrt_val=sqrt($cr_size_effective/100);
  my $win_w=int($sqrt_val*$max_x);
  my $win_h=int($sqrt_val*$max_y);
  &create_pattern_file("RECTANGLE","$win_w,$win_h",100,"$cr_rgb","$cr_bg","$position_default","","",1,"calman",$cr_source_range,$source_max);
 }
 return 1;
}

sub calman_render_rgb_pattern (@) {
 my $type=shift;
 my $pattern_cmd=shift;
 my $full_key=shift;
 my $connection=shift;
 my @el_cmd=split(",",$pattern_cmd);
 my $calman_max=1023;
 my $target_max=&calman_target_max();
 my $source_max=&calman_dv_source_max();
 my $rgb_raw="$el_cmd[0],$el_cmd[1],$el_cmd[2]";
 &log("Calman PATTERN: type=$type raw=$rgb_raw bits_default=$bits_default target_max=$target_max");
 $calman_precision_lost=0;
 my $r=&calman_scale_value($el_cmd[0],$calman_max);
 my $g=&calman_scale_value($el_cmd[1],$calman_max);
 my $b=&calman_scale_value($el_cmd[2],$calman_max);
 if($calman_precision_lost) {
  &log("Calman PATTERN: $rgb_raw at 10 bit has no exact code at ".($target_max == 255 ? 8 : 10)." bit output; rounded to $r,$g,$b");
  # Once per 10 minutes: Calman works at a finer bit depth than the output.
  if(time() - ($calman_precision_notice_time || 0) > 600) {
   $calman_precision_notice_time=time();
   my $out_bits=$target_max == 255 ? 8 : 10;
   my $sent=join(",",map { int($_) } @el_cmd[0..2]);
   &webui_notice("Calman sends finer codes than the output carries","Calman sent $sent (10 bit), but PGenerator+ outputs $out_bits bit, so the patch was rounded to $r,$g,$b. For bit-exact patches set the same bit depth in Calman and in PGenerator+.");
  }
 }
 my $patch_context=&calman_patch_context();
 my $current_bg=&calman_current_bg();
 &log("Calman PATTERN: scaled=$r,$g,$b bg=$current_bg max_bpc=$pgenerator_conf{'max_bpc'} $patch_context");
 &log_calman_patch(type=>$type,
                   raw=>$rgb_raw,
                   scaled=>"$r,$g,$b",
                   win=>$calman_win_size,
                   bg=>$current_bg,
                   range=>&calman_pattern_source_range(),
                   peer=>$connection ? $client_ip{$connection} : "",
                   extra=>"raw_extra=".join(",",@el_cmd[3..$#el_cmd])." target_max=$target_max calman_max=$calman_max $patch_context");
 if($full_key eq "") {
  $full_key=$start_cmd_string_calman.$type.":".$pattern_cmd;
 }
 if($calman_special_pattern{$full_key} ne "" && -f "$pattern_templates/$calman_special_pattern{$full_key}") {
  &get_pattern("TESTTEMPLATE","$calman_special_pattern{$full_key}","","TESTTEMPLATE:$calman_special_pattern{$full_key}");
  &clean_pattern_files();
  return 1;
 }
 my $source_range=&calman_pattern_source_range();
 if($type =~/RGB_B/) {
  my $bg_val=&calman_scale_value($el_cmd[3],$calman_max);
  $calman_apl_enabled=0;
  $calman_bg="$bg_val,$bg_val,$bg_val";
  &clean_pattern_files();
  &get_pattern($test_template_command,$pattern_dynamic,"$r,$g,$b;$calman_bg","calman",$source_range,$source_max);
  return 1;
 }
 if($type =~/RGB_S/) {
  my $win_pct=int($el_cmd[3]);
  $win_pct=$calman_win_size if($win_pct < 1);
  $win_pct=100 if($win_pct > 100);
  $calman_win_size=$win_pct if($win_pct > 0);
  my $effective_bg=$current_bg;
  &log("Calman: RGB_S direct window size=$win_pct% bg=$effective_bg");
  if($win_pct >= 100) {
   $pname_file="FullField";
   &clean_pattern_files();
   &create_pattern_file("RECTANGLE","$w_s,$h_s",100,"$r,$g,$b","$effective_bg","","","",1,"calman",$source_range,$source_max);
   return 1;
  }
  my $sqrt_val=sqrt($win_pct/100);
  my $win_w=int($sqrt_val*$max_x);
  my $win_h=int($sqrt_val*$max_y);
  &clean_pattern_files();
  &create_pattern_file("RECTANGLE","$win_w,$win_h",100,"$r,$g,$b","$effective_bg","$position_default","","",1,"calman",$source_range,$source_max);
  return 1;
 }
 if($type =~/RGB_A/) {
  my $win_pct=$calman_win_size;
  my $effective_bg=$current_bg;
  if(scalar(@el_cmd) >= 7) {
   my $bg_r=&calman_scale_value($el_cmd[3],$calman_max);
   my $bg_g=&calman_scale_value($el_cmd[4],$calman_max);
   my $bg_b=&calman_scale_value($el_cmd[5],$calman_max);
   $effective_bg="$bg_r,$bg_g,$bg_b";
   $win_pct=int($el_cmd[6]);
  } elsif(scalar(@el_cmd) >= 4) {
   $win_pct=int($el_cmd[3]);
  }
  $win_pct=$calman_win_size if($win_pct < 1);
  $win_pct=100 if($win_pct > 100);
  $calman_win_size=$win_pct if($win_pct > 0);
  &log("Calman: RGB_A explicit bg=$effective_bg size=$win_pct%");
  if($win_pct >= 100) {
   $pname_file="FullField";
   &clean_pattern_files();
   &create_pattern_file("RECTANGLE","$w_s,$h_s",100,"$r,$g,$b","$effective_bg","","","",1,"calman",$source_range,$source_max);
   return 1;
  }
  my $sqrt_val=sqrt($win_pct/100);
  my $win_w=int($sqrt_val*$max_x);
  my $win_h=int($sqrt_val*$max_y);
  &clean_pattern_files();
  &create_pattern_file("RECTANGLE","$win_w,$win_h",100,"$r,$g,$b","$effective_bg","$position_default","","",1,"calman",$source_range,$source_max);
  return 1;
 }
 my $effective_bg=&calman_apl_bg("$r,$g,$b",$calman_win_size,$type);
 &clean_pattern_files();
 &get_pattern($test_template_command,$pattern_dynamic,"$r,$g,$b;$effective_bg","calman",$source_range,$source_max);
 return 1;
}

###############################################
#     Portrait Displays G1 specialty patterns  #
###############################################
use PGG1Patterns qw(g1_pattern_key g1_pattern_render g1_pattern_level g1_pattern_has_10bit);
# PiTPG protocol 2 framing: port 85 tells its clients apart with it.
use PGPiTPG ();

# Rendered plates are kept across patterns (clean_pattern_files() empties
# running/ on every pattern) and dropped when the pattern code changes.
sub calman_g1_cache_dir (@) {
 my $dir="$var_dir/g1patterns";
 mkdir($dir) if(!-d $dir);
 my $stamp="$dir/VERSION";
 my $current="";
 if(open(my $fh,"<",$stamp)) { $current=<$fh> // ""; close($fh); }
 $current=~s/\s+//g;
 if($current ne $PGG1Patterns::VERSION) {
  &remove_files($dir,"\.(png|ppm)\$");
  if(open(my $fh,">",$stamp)) { print $fh "$PGG1Patterns::VERSION\n"; close($fh); }
 }
 return $dir;
}

# Write an RGB buffer as PNG (scaled to $out_w x $out_h when given).
sub calman_g1_save_image (@) {
 my ($img,$file,$out_w,$out_h)=@_;
 return 0 if(!$img || !$convert || !-x $convert);
 my @resize=();
 @resize=("-filter","Triangle","-resize","${out_w}x${out_h}!") if($out_w && ($out_w != $img->{w} || $out_h != $img->{h}));
 # 10-bit plates carry their codes in 16-bit samples: PNG48, never resized.
 # The buffer is big-endian (pack "n"); raw rgb: input defaults to the
 # host order, which swapped the bytes on the Pi.
 my $depth=(($img->{depth} || 8) == 16) ? 16 : 8;
 @resize=() if($depth == 16);
 my $tmp="$file.tmp.png";
 unlink($tmp);
 return 0 if(!open(my $fh,"|-",$convert,"-size",$img->{w}."x".$img->{h},"-depth",$depth,"-endian","MSB","rgb:-",@resize,($depth == 16 ? "PNG48:$tmp" : "PNG24:$tmp")));
 binmode($fh);
 my $buf=$img->{buf};
 utf8::downgrade($buf,1);
 my $ok=&webui_pattern_write_all($fh,$buf);
 $ok=0 if(!close($fh));
 return 0 if(!$ok || !-f $tmp);
 return rename($tmp,$file) ? 1 : 0;
}

# Bit depth of the HDMI link in SDR, as drm_override.so forces it from the
# conf: 10 and 12 bpc run at 10 bit outside Dolby Vision, YCbCr 4:2:2 at
# least 10. The G1 shows its 10-bit Brightness/Contrast plates there.
sub calman_g1_wire_bits (@) {
 return 8 if(int($pgenerator_conf{"is_hdr"} || 0) || int($pgenerator_conf{"dv_status"} || 0));
 return 10 if(int($pgenerator_conf{"max_bpc"} || 8) >= 10 || int($pgenerator_conf{"color_format"} || 0) == 2);
 return 8;
}

# Convert a picture file to a PNG of $w x $h (Skintones photo, logo).
sub calman_g1_convert_file (@) {
 my ($src,$file,@args)=@_;
 return 0 if(!$convert || !-x $convert || !-f $src);
 my $tmp="$file.tmp.png";
 unlink($tmp);
 system($convert,$src,@args,"PNG24:$tmp");
 return 0 if(!-f $tmp);
 return rename($tmp,$file) ? 1 : 0;
}

sub calman_g1_logo (@) {
 my ($h,$range)=@_;
 my $src="$shared_dir/pgen-logo-light.png";
 return undef if(!$convert || !-x $convert || !-f $src);
 my $lh=int($h/12+0.5);
 my $lw=int($lh*751/240+0.5);
 my $bg=&g1_pattern_level($range,94);
 return undef if(!open(my $fh,"-|",$convert,$src,"-background","rgb($bg,$bg,$bg)","-flatten","-resize","${lw}x${lh}!","-depth","8","rgb:-"));
 binmode($fh);
 my $buf=do { local $/; <$fh> };
 close($fh);
 return undef if(!defined $buf || length($buf) != $lw*$lh*3);
 return {w => $lw, h => $lh, buf => $buf};
}

sub calman_g1_skintones_photo (@) {
 for my $ext ("png","jpg","jpeg","bmp") {
  my $f="$var_dir/g1-images/skintones.$ext";
  return $f if(-f $f);
 }
 return "";
}

sub calman_g1_ip (@) {
 for my $if ($eth_interface,$wlan_interface) {
  next if(($if // "") eq "");
  my $ip=&get_ip($if);
  return $ip if($ip ne "" && $ip ne $none);
 }
 return "";
}

# Show a G1 pattern. Returns 0 if it could not be drawn so the caller can
# fall back. $o (optional): source_range => "LIMITED" or "" to draw for that
# range instead of the configured one; load => 0 to only write the command
# file (the caller loads it); check => [verdict,basis] for the Range Check
# (PGG1Patterns g1_pattern_render).
sub calman_render_g1_pattern (@) {
 my ($key,$pattern_name,$o)=@_;
 $o={} if(ref($o) ne "HASH");
 my $source_range=exists $o->{source_range} ? $o->{source_range} : &calman_pattern_source_range();
 my $range=($source_range eq "LIMITED") ? "limited" : "full";
 my ($w,$h)=(int($w_s),int($h_s));
 return 0 if($w < 64 || $h < 64);
 my $dir=&calman_g1_cache_dir();
 my %opt=(range => $range);
 # Animations step once per refresh, so they need the output rate.
 $opt{hz}=$1 + 0 if($preferred_mode =~/\s([\d.]+)Hz/);
 my $tag="${key}_${w}x${h}_$range";
 if(ref($o->{check}) eq "ARRAY") {
  $opt{check}=$o->{check};
  (my $check_tag=join("_",@{$o->{check}}))=~s/[^0-9A-Za-z]+/-/g;
  $tag.="_$check_tag";
 }
 # Granger is a smooth field: render a quarter of the pixels and let
 # convert scale it, which keeps the first draw well inside Calman's
 # 10 s command timeout on a Pi.
 my $scale=($key eq "granger") ? 4 : 1;
 # Warm-Up scrolls a strip twice the screen size; keep its texture within
 # 4096 px by drawing it at half resolution on 4K outputs.
 $scale=2 if($key eq "warmup" && 2*$w > 4096);
 if($key eq "warmup") {
  $opt{ip}=&calman_g1_ip();
  (my $ip_tag=$opt{ip})=~s/[^0-9A-Za-z]+/-/g;
  $tag.="_$ip_tag";
 }
 my $bits=(&g1_pattern_has_10bit($key) && &calman_g1_wire_bits() == 10) ? 10 : 8;
 if($bits == 10) {
  $opt{bits}=10;
  $tag.="_10bit";
 }
 if($key eq "screensaver") {
  my $logo=&calman_g1_logo($h,$range);
  $opt{logo}=$logo if($logo);
 }
 my $photo=($key eq "skintones") ? &calman_g1_skintones_photo() : "";
 if($photo ne "") {
  $tag.="_photo".((stat($photo))[9] || 0);
 }
 my @frames;
 my $bg=[0,0,0];
 my $first="$dir/$tag-0.png";
 if($photo ne "") {
  # Photos are full range pictures; pattern codes are video levels on
  # limited links, so squeeze 0-255 into 16-235 there.
  my @levels=($range eq "limited") ? ("+level",(16/255*100)."%,".(235/255*100)."%") : ();
  if(!-f $first && !&calman_g1_convert_file($photo,$first,"-resize","${w}x${h}!",@levels,"-depth","8")) {
   &log("Calman G1: could not convert $photo");
   return 0;
  }
  @frames=({file => $first, w => $w, h => $h, x => 0, y => 0, ms => $frame_default});
 } else {
  my $out=&g1_pattern_render($key,int($w/$scale),int($h/$scale),\%opt);
  return 0 if(!$out || !@{$out->{frames}});
  my %files=();
  my $n=0;
  my $draw_scale=($key eq "granger") ? 1 : $scale;
  for my $f (@{$out->{frames}}) {
   my $img=$f->{img};
   my $file=$files{"$img"};
   if(!defined $file) {
    $file="$dir/$tag-".($n++).".png";
    my ($ow,$oh)=($key eq "granger") ? ($w,$h) : ($img->{w},$img->{h});
    if(!-f $file && !&calman_g1_save_image($img,$file,$ow,$oh)) {
     &log("Calman G1: could not write $file");
     return 0;
    }
    $files{"$img"}=$file;
   }
   my ($iw,$ih)=($key eq "granger") ? ($w,$h) : ($img->{w}*$draw_scale,$img->{h}*$draw_scale);
   my ($x,$y)=(int(($f->{x} // 0)*$draw_scale),int(($f->{y} // 0)*$draw_scale));
   # POSITION=-1,-1 means "centre" to the renderer.
   $x=-2 if($x == -1);
   push(@frames,{file => $file, w => $iw, h => $ih, x => $x, y => $y, ms => ($f->{ms} || $frame_default)});
  }
  $bg=$out->{bg} if($out->{bg});
 }
 my $bg_str=join(",",@$bg);
 &clean_pattern_files();
 # A PATTERN_NAME marks the plate as chosen in the WebUI, so its idle
 # refresh leaves it on screen.
 my $ps=(defined $pattern_name ? "PATTERN_NAME=$pattern_name\n" : "")."MOVIE_NAME=TestPattern\nBITS=$bits\n";
 for(my $i=0;$i<scalar(@frames);$i++) {
  my $f=$frames[$i];
  $ps.="DRAW=IMAGE\nDIM=$f->{w},$f->{h}\nRGB=0,0,0\nBG=$bg_str\nPOSITION=$f->{x},$f->{y}\nIMAGE=$f->{file}\nEND=1\n";
  $ps.="FRAME_NAME=G1_${key}_$i\nFRAME=$f->{ms}\n";
 }
 &create_tmp_file($ps,$source_range);
 &load_new_pattern_file("calman") if(!exists $o->{load} || $o->{load});
 &log("Calman G1: $key ${w}x${h} range=$range bits=$bits frames=".scalar(@frames).(scalar(@frames) > 1 ? " hz=".($opt{hz} || "default") : ""));
 return 1;
}

# After the daemon starts, show the G1 Basic Alignment plate instead of
# black, drawn in the range the WebUI has set. Not when the renderer start
# just before it failed: drawing it would run load_new_pattern_file's retry
# ladder (five starts, about a minute) before the WebUI and the pattern
# ports open, and the watchdog restarted a daemon that was still in it.
# The next pattern request runs the ladder from its own thread instead.
sub show_boot_pattern (@) {
 return if(!&hdmi_sink_connected());
 if(!&pattern_generator_is_running()) {
  &log("Boot: renderer not running, Basic Alignment skipped; the next pattern request starts it");
  return;
 }
 &log("Boot: showing Basic Alignment") if(&calman_render_g1_pattern("basic_alignment"));
}

sub calman_render_specialty_pattern (@) {
 my $pattern_cmd=shift;
 my $sp_name=uc($pattern_cmd);
 $sp_name=~s/^\s+|\s+$//g;
 my $g1_key=&g1_pattern_key($sp_name);
 return 1 if(defined $g1_key && &calman_render_g1_pattern($g1_key));
 &clean_pattern_files();
 my $source_range=&calman_pattern_source_range();
 my $target_max=&calman_target_max();
 my $source_max=&calman_dv_source_max();
 my $black_rgb=&calman_scale_triplet_8bit(0,0,0);
 my $white_rgb=&calman_scale_triplet_8bit(255,255,255);
 my $gray128_rgb=&calman_scale_triplet_8bit(128,128,128);
 my $sp_signal_mode=&webui_pattern_signal_mode("");
 my $sp_max_luma=&webui_pattern_max_luma("");
 if($sp_name eq "BRIGHTNESS") {
  my $img=&webui_pattern_diag_image_file("calman_brightness");
  if(&webui_pattern_render_black_clipping($img,$w_s,$h_s,$sp_signal_mode,$sp_max_luma)) {
   my $ps="MOVIE_NAME=TestPattern\nBITS=8\n";
   $ps.=&webui_pattern_image_pattern($w_s,$h_s,$img);
   $ps.="FRAME_NAME=TestPattern\nFRAME=$frame_default\n";
   &create_tmp_file($ps,$source_range);
   &load_new_pattern_file("calman");
  } else {
   &log("Calman: BRIGHTNESS image render failed, falling back to flat patch");
   &create_pattern_file("RECTANGLE","$w_s,$h_s",100,"$black_rgb",&calman_current_bg(),"","","",1,"calman",$source_range,$source_max);
  }
 } elsif($sp_name eq "CONTRAST") {
  my $img=&webui_pattern_diag_image_file("calman_contrast");
  if(&webui_pattern_render_white_clipping($img,$w_s,$h_s,$sp_signal_mode,$sp_max_luma)) {
   my $ps="MOVIE_NAME=TestPattern\nBITS=8\n";
   $ps.=&webui_pattern_image_pattern($w_s,$h_s,$img);
   $ps.="FRAME_NAME=TestPattern\nFRAME=$frame_default\n";
   &create_tmp_file($ps,$source_range);
   &load_new_pattern_file("calman");
  } else {
   &log("Calman: CONTRAST image render failed, falling back to flat patch");
   &create_pattern_file("RECTANGLE","$w_s,$h_s",100,"$white_rgb",&calman_current_bg(),"","","",1,"calman",$source_range,$source_max);
  }
 } elsif($sp_name eq "ALIGNMENT" || $sp_name eq "OVERSCAN") {
  my $img=&webui_pattern_diag_image_file("calman_alignment");
  if(&webui_pattern_render_overscan($img,$w_s,$h_s)) {
   my $ps="MOVIE_NAME=TestPattern\nBITS=8\n";
   $ps.=&webui_pattern_image_pattern($w_s,$h_s,$img);
   $ps.="FRAME_NAME=TestPattern\nFRAME=$frame_default\n";
   &create_tmp_file($ps,$source_range);
   &load_new_pattern_file("calman");
  } else {
   &log("Calman: ALIGNMENT image render failed, falling back to flat patch");
   &create_pattern_file("RECTANGLE","$w_s,$h_s",100,"$gray128_rgb",&calman_current_bg(),"","","",1,"calman",$source_range,$source_max);
  }
 } else {
  &log("Calman: unknown specialty pattern: $sp_name");
  &create_pattern_file("RECTANGLE","$w_s,$h_s",100,"$gray128_rgb",&calman_current_bg(),"","","",1,"calman",$source_range,$source_max);
 }
 return 1;
}

sub calman_replay_last_pattern (@) {
 my $source=shift;
 return 0 if($calman_replaying_last_pattern);
 return 0 if($calman_last_pattern_kind eq "");
 $calman_replaying_last_pattern=1;
 my $ok=0;
 &log("Calman: replaying last pattern after $source kind=$calman_last_pattern_kind type=$calman_last_pattern_type");
 if($calman_last_pattern_kind eq "CommandRGB") {
  $ok=&calman_render_commandrgb_pattern($calman_last_pattern_cmd,"");
 } elsif($calman_last_pattern_kind eq "RGB") {
  $ok=&calman_render_rgb_pattern($calman_last_pattern_type,$calman_last_pattern_cmd,"","");
 } elsif($calman_last_pattern_kind eq "SPECIALTY") {
  $ok=&calman_render_specialty_pattern($calman_last_pattern_cmd);
 }
 $calman_replaying_last_pattern=0;
 &log("Calman: replay last pattern ".($ok ? "complete" : "skipped"));
 return $ok;
}

sub legacy_external_set_status (@) {
 my $connection=shift;
 my $software=shift;
 $software="DeviceControl" if($software eq "");
 if($software eq "DeviceControl" && ($legacy_external_client_name{$connection} || "") ne "") {
  $software=$legacy_external_client_name{$connection};
 }
 &calibration_session_open($connection,$software);
}

###############################################
#        Calibration sessions per socket      #
###############################################
# One entry per pattern socket that opened a session; the status bar and the
# WebUI signal lock (webui_signal_owner) read the published summary. Each
# port has its own protocol and its own start:
#  - port 85 (classic: ColourSpace, HCFR, DeviceControl): the first pattern
#    or client identity (legacy_external_set_status), not the bare connect;
#  - port 2100 (Calman UPGCI) and 2101 (Calman G1 RPC): INIT or the first
#    command that is not a probe. Calman's G1 discovery (SN, CAP,
#    GET_SETTINGS, then close) and the STATUS/FIRMWARE queries open nothing.
# A session ends with SHUTDOWN/QUIT/TERM or when its socket closes; one of
# several sockets from the same peer closing ends only its own session.
# A peer that vanishes without closing (VM paused, cable pulled) is found by
# TCP keepalive (calibration_socket_keepalive) and closed like any other.
our %calibration_session=();
our $calibration_sessions_owner="";
sub calibration_session_protocol (@) {
 my $connection=shift;
 my $kind=$pattern_socket_kind{$connection} || "";
 return "PiTPG" if($pitpg_conn{$connection});
 return "G1 RPC" if($kind eq "rpc" || $rpc_client{$connection});
 return "UPGCI" if($kind eq "calman");
 return "classic";
}
sub calibration_session_port (@) {
 my $connection=shift;
 my $port=eval { $connection->sockport() };
 return (defined $port && $port=~/^\d+$/) ? $port : "";
}
sub calibration_session_open (@) {
 my ($connection,$software)=@_;
 return if(!$connection);
 my $now=time();
 my $s=$calibration_session{$connection};
 if(!$s) {
  $s=$calibration_session{$connection}={since=>$now,ip=>($client_ip{$connection} || $client_address || ""),
   protocol=>&calibration_session_protocol($connection),port=>&calibration_session_port($connection)};
  &log("Calibration session open: software=$software protocol=$s->{protocol} port=$s->{port} peer=$s->{ip}");
 }
 $s->{software}=$software;
 $s->{last_rx}=$now;
 &calibration_sessions_publish();
}
sub calibration_session_touch (@) {
 my $connection=shift;
 my $s=$calibration_session{$connection};
 return if(!$s);
 my $now=time();
 return if(($s->{last_rx} || 0) == $now);
 $s->{last_rx}=$now;
 &calibration_sessions_publish();
}
# Returns 1 when the socket had a session.
sub calibration_session_close (@) {
 my ($connection,$reason)=@_;
 my $s=delete $calibration_session{$connection};
 return 0 if(!$s);
 &log("Calibration session closed: software=$s->{software} protocol=$s->{protocol} port=$s->{port} peer=$s->{ip}".(($reason || "") ne "" ? " reason=$reason" : ""));
 &calibration_sessions_publish();
 return 1;
}
# Newest session wins the status bar. Resolve (resolve.pm) and LightSpace
# (discovery.pm) set the status from their own threads: it is cleared here
# only if this thread wrote it.
sub calibration_sessions_publish (@) {
 my @s=sort { $b->{since} <=> $a->{since} } values %calibration_session;
 $calibration_sessions=join("\n",map { join("|",map { my $v=defined($_) ? "$_" : ""; $v=~s/[|\n]//g; $v } @$_{qw(software protocol port ip since last_rx)}) } @s);
 if(@s) {
  $calibration_client_ip=$s[0]->{ip};
  $calibration_client_software=$s[0]->{software};
  $calibration_sessions_owner="$s[0]->{ip}|$s[0]->{software}";
 } elsif($calibration_sessions_owner ne "") {
  if("$calibration_client_ip|$calibration_client_software" eq $calibration_sessions_owner) {
   $calibration_client_ip="";
   $calibration_client_software="";
  }
  $calibration_sessions_owner="";
 }
}
# Dead peers: probe after 30 s idle, 3 probes 10 s apart, so a vanished
# client is closed after about a minute. A live client answers the probes
# from its TCP stack even while its program sends nothing (Calman stays
# silent for minutes between patterns), so an idle session is kept.
sub calibration_socket_keepalive (@) {
 my $sock=shift;
 eval { setsockopt($sock,Socket::SOL_SOCKET(),Socket::SO_KEEPALIVE(),1) } or return 0;
 eval {
  setsockopt($sock,Socket::IPPROTO_TCP(),Socket::TCP_KEEPIDLE(),30);
  setsockopt($sock,Socket::IPPROTO_TCP(),Socket::TCP_KEEPINTVL(),10);
  setsockopt($sock,Socket::IPPROTO_TCP(),Socket::TCP_KEEPCNT(),3);
 };
 return 1;
}

sub legacy_external_set_client_name (@) {
 my $connection=shift;
 my $software=shift || "";
 $software=~s/^\s+|\s+$//g;
 $software=~s/[^A-Za-z0-9 ._+()\/-]//g;
 $software=substr($software,0,64);
 return "" if($software eq "");
 $legacy_external_client_name{$connection}=$software;
 &legacy_external_set_status($connection,$software);
 return $software;
}

sub legacy_external_client_name_from_marker (@) {
 my $connection=shift;
 my $marker=shift || "";
 return "" if($marker !~/^\s*(?:CLIENTNAME|CLIENT_NAME|SOFTWARE)\s*[:=]\s*(.*?)\s*$/i);
 return &legacy_external_set_client_name($connection,$1);
}

sub legacy_external_mark_hcfr (@) {
 my $connection=shift;
 $hcfr_client{$connection}=1;
 &legacy_external_set_status($connection,"HCFR");
}

sub legacy_external_dv_active (@) {
 return 1 if(int($pgenerator_conf{"dv_status"} || 0) == 1);
 return 1 if(int($pgenerator_conf{"is_ll_dovi"} || 0) == 1);
 return 1 if(int($pgenerator_conf{"is_std_dovi"} || 0) == 1);
 return 0;
}

sub legacy_external_dv_source_max (@) {
 return 4095 if(int($pgenerator_conf{"dv_status"} || 0) == 1 &&
                int($pgenerator_conf{"is_std_dovi"} || 0) == 1);
 return 0;
}

sub legacy_external_source_bits (@) {
 my $declared=shift;
 my $draw=shift || "";
 return int($1) if($draw =~/(8|10|12)bit$/i);
 return int($declared) if(defined $declared && $declared =~/^(8|10|12)$/);
 return 8;
}

sub legacy_external_scale_dv_value (@) {
 my $value=shift;
 my $source_bits=int(shift || 8);
 return $value if($value !~/^\d+$/);
 return $value if(&legacy_external_dv_source_max() != 4095);
 my $source_max=(1 << $source_bits) - 1;
 if($source_bits == 12) {
  return 4095 if($value > 4095);
  return $value;
 }
 return 4095 if($value >= $source_max);
 return $value << (12 - $source_bits);
}

sub legacy_external_scale_dv_triplet (@) {
 my $triplet=shift;
 my $source_bits=shift;
 return $triplet if(!defined $triplet || $triplet eq "" || &legacy_external_dv_source_max() != 4095);
 my @values=split(/,/,$triplet,-1);
 return $triplet if(@values != 3);
 foreach my $value (@values) {
  return $triplet if($value !~/^\d+$/);
  $value=&legacy_external_scale_dv_value($value,$source_bits);
 }
 return join(",",@values);
}

sub legacy_external_prepare_dv_pattern (@) {
 my ($draw,$rgb,$bg,$declared_bits)=@_;
 my $source_max=&legacy_external_dv_source_max();
 return ($draw,$rgb,$bg,0) if($source_max != 4095);
 my $source_bits=&legacy_external_source_bits($declared_bits,$draw);
 $rgb=&legacy_external_scale_dv_triplet($rgb,$source_bits);
 $bg=&legacy_external_scale_dv_triplet($bg,$source_bits);
 $draw=~s/(?:8|10|12)bit$//i;
 return ($draw,$rgb,$bg,$source_max);
}

sub legacy_external_prepare_dv_template_payload (@) {
 my $payload=shift;
 my $source_max=&legacy_external_dv_source_max();
 return ($payload,0) if($source_max != 4095);
 my @fields=split(/;/,$payload || "",-1);
 for my $idx (0..8) {
  $fields[$idx]="" if(!defined $fields[$idx]);
 }
 my $source_bits=&legacy_external_source_bits($fields[8],$fields[2]);
 $fields[0]=&legacy_external_scale_dv_triplet($fields[0],$source_bits);
 $fields[1]=&legacy_external_scale_dv_triplet($fields[1],$source_bits);
 $fields[2]=~s/(?:8|10|12)bit$//i;
 $fields[8]="8";
 return (join(";",@fields),$source_max);
}

sub legacy_external_prepare_hcfr_dv_template_payload (@) {
 my $payload=shift;
 # HCFR can send 10-bit classic-protocol values even though it has no Dolby
 # Vision mode of its own. Preserve that declared source precision while the
 # standard-DV renderer keeps its RGB tunnel at 8-bit. The old ordering first
 # forced HCFR's bits field to 8, then interpreted 10-bit values as 8-bit;
 # values at or above 255 consequently collapsed to full white.
 my ($prepared,$source_max)=&legacy_external_prepare_dv_template_payload($payload);
 $prepared=&legacy_external_hcfr_template_payload($prepared);
 return ($prepared,$source_max);
}

sub legacy_external_hcfr_triplet_quant_range (@) {
 my $triplet=shift;
 my $allow_full=shift;
 return "" if(!defined $triplet || $triplet eq "");
 my @values=split(/,/,$triplet);
 return "" if($#values != 2);
 my $limited_anchor=0;
 for(@values) {
  return "" if($_ !~/^-?\d+$/);
  return "" if($_ < 0);
  return 2 if($allow_full && $_ > 255);
  return 2 if($allow_full && ($_ < 16 || $_ > 235));
  $limited_anchor=1 if($_ == 16 || $_ == 235);
 }
 return 1 if($limited_anchor);
 return "";
}

sub legacy_external_hcfr_quant_range (@) {
 my $payload=shift;
 my @fields=split(/;/,$payload || "",-1);
 my $primary_range=&legacy_external_hcfr_triplet_quant_range($fields[0],1);
 return 2 if($primary_range eq "2");
 my $background_range=&legacy_external_hcfr_triplet_quant_range($fields[1],0);
 return 1 if($primary_range eq "1" || $background_range eq "1");
 return "";
}

sub legacy_external_hcfr_source_range (@) {
 my $payload=shift;
 return "" if(defined &legacy_external_dv_active && &legacy_external_dv_active());
 return "LIMITED" if(&legacy_external_hcfr_quant_range($payload) eq "1");
 return "";
}

sub legacy_external_hcfr_template_payload (@) {
 my $payload=shift;
 my @fields=split(/;/,$payload || "",-1);
 for my $idx (0..8) {
  $fields[$idx]="" if(!defined $fields[$idx]);
 }
 $fields[8]="8";
 return join(";",@fields[0..8]);
}

sub legacy_external_hcfr_draw (@) {
 my $draw=shift;
 return "" if(!defined $draw);
 return $draw if($draw =~/\d+bit$/i);
 my $draw_upper=uc($draw);
 return "${draw_upper}8bit" if($draw_upper =~/^(RECTANGLE|CIRCLE|TRIANGLE|TEXT|IMAGE)$/);
 return $draw;
}

sub legacy_external_detect_hcfr_rgb (@) {
 my $draw=uc(shift || "");
 my $text=shift;
 return 1 if($draw eq "IMAGE" && $text =~m{^/var/lib/PGenerator/images-HCFR/}i);
 return 1 if($draw eq "TEXT" && $text =~/^(Init|End of sequence|Initializing PGenerator at:)/);
 return 0;
}

###############################################
#             Pattern function                #
###############################################
sub pattern_daemon { 
 ############################
 #                          #
 #       Variables          #
 #                          #
 ############################
 my $socket_id=shift;
 $0=$program_name;
 $section="ProxyDaemon";
 $device_type=$device_type{$socket_id};
 ############################
 #                          #
 #        Create Pid        #
 #                          #
 ############################
 open(PID,">$pid_file");
 print PID $$;
 close(PID);
 ############################
 #                          #
 #      Create Socket       #
 #                          #
 ############################
 $server=&create_socket_daemon($socket_id,$pgenerator_conf{"ip_pattern"},$pgenerator_conf{"port_pattern"}); # server classic
 $server_calman=&create_socket_daemon($socket_id,$pgenerator_conf{"ip_pattern"},$port_server_calman);       # server for Calman unified pattern generator control interface
 $server_rpc=&create_socket_daemon($socket_id,$pgenerator_conf{"ip_pattern"},$port_rpc);                    # RPC service
 $select = IO::Select->new();
 $select->add($server,$server_calman,$server_rpc);

 ############################
 #                          #
 #      LOOP Request        #
 #                          #
 ############################
 while ($select->count()) {
  # Commands read but not handled yet (one read carried several) go first,
  # without waiting for their socket to become readable again.
  my @ready = grep { $pending_cmd{$_} && @{$pending_cmd{$_}} } $select->handles();
  @ready = $select->can_read(5) if(!@ready);
  if(!@ready) {
   &renderer_start_when_hdmi_connected();
   next;
  }
  foreach my $connection (@ready) {
   if ($connection == $server || $connection == $server_calman || $connection == $server_rpc) {
    ############################
    #                          #
    #      Accept Request      #
    #                          #
    ############################
    $client_socket=$connection->accept();
    if(!$client_socket) {
     &log("Accept failed: $!");
     next;
    }
    my $pattern_socket_type=($connection == $server_rpc) ? "rpc" : (($connection == $server_calman) ? "calman" : "classic");
    $pattern_socket_kind{$client_socket}=$pattern_socket_type;
    $client_socket->setsockopt(SOL_SOCKET, SO_RCVTIMEO, pack('l!l!', 30, 0)) if($pattern_socket_type ne "classic");
    &calibration_socket_keepalive($client_socket);
    $client_address=$client_socket->peerhost();
    $client_port=$client_socket->peerport();
    $client_ip{$client_socket}=$client_address;
    $rpc_client{$client_socket}=1 if($connection == $server_rpc);
    $hcfr_client{$client_socket}=0;
    $select->add($client_socket);
    &stats("connections",1);
    #&send_key_to_client($client_socket,$banner);
   } else {
    ############################
    #                          #
    #    Receive from client   #
    #                          #
    ############################
    my $key_framed=0;
    my $http_request=0;
    if($pending_cmd{$connection} && @{$pending_cmd{$connection}}) {
     $key=shift(@{$pending_cmd{$connection}});
     $key_framed=1;
    } else {
     my $rv=$connection->recv($key,1024);
     if(!defined $rv) {
      my $recv_error="$!";
      # ETIMEDOUT ("Connection timed out") is keepalive finding a dead peer,
      # not SO_RCVTIMEO (EAGAIN): that socket is closed on every port.
      my $recv_timeout=(!$!{ETIMEDOUT} && ($!{EAGAIN} || $!{EWOULDBLOCK} || $recv_error=~/temporarily unavailable|would block/i)) ? 1 : 0;
      if($recv_timeout && ($pattern_socket_kind{$connection} || "") eq "classic") {
       next;
      }
      my $close_reason=$recv_timeout ? "recv timeout" : "recv error: $recv_error";
      &close_connection($connection,$close_reason);
      last;
     }
     # PiTPG protocol 2 (ColourSpace's "PiTPG" entry, pitpg.pm) on port 85:
     # told apart from a classic client by its first 4 bytes, "PTG2". Until
     # 4 bytes are in, a prefix of the magic waits in $cmd.
     if(($pattern_socket_kind{$connection} || "") eq "classic") {
      if($pitpg_conn{$connection}) {
       &pitpg_receive($connection,$key);
       last;
      }
      if(!$pitpg_checked{$connection}) {
       my $start=($cmd{$connection} // "").$key;
       my $is_pitpg=PGPiTPG::detect($start);
       if(!defined($is_pitpg) && $key ne "") {
        $cmd{$connection}=$start;
        last;
       }
       $pitpg_checked{$connection}=1;
       if($is_pitpg) {
        $cmd{$connection}="";
        &pitpg_open($connection,substr($start,length($PGPiTPG::MAGIC)));
        last;
       }
      }
     }
     # Port 85 and 2100 commands end with a terminator ($end_cmd_string,
     # $end_cmd_string_calman). One read can carry several commands, or the
     # start of the next: cut the buffered bytes into whole commands, handle
     # the first now and queue the rest. Bytes after the last terminator
     # wait for the next read. Only a read that holds a terminator, or
     # finishes one begun by the last byte buffered, completes a command:
     # the buffer is cut only then, so an upload whose base64 is wrapped in
     # CRLF lines is not copied on every read.
     # A line break a client sends after the terminator ("\x02\r\n")
     # belongs to the command before it, as when one read held one command.
     my $last_byte=length($cmd{$connection} // "") ? substr($cmd{$connection},-1) : "";
     if(!$rpc_client{$connection} && $key ne "" && ($last_byte.$key)=~/$end_cmd_string|$end_cmd_string_calman/) {
      my $buffered=($cmd{$connection} // "").$key;
      my @frames=();
      push(@frames,$1) while($buffered=~s/^[\r\n]*(.*?(?:$end_cmd_string|$end_cmd_string_calman))//s);
      if(@frames) {
       $cmd{$connection}=$buffered;
       $key=shift(@frames);
       push(@{$pending_cmd{$connection}},@frames);
       $key_framed=1;
      }
     }
     # An HTTP request (image list, image) ends with an empty line, not with
     # a terminator: gather it across reads like a command and route it
     # whole, or as far as it got once the client ends its side (EOF).
     # Only a buffer starting with "GET /" is touched: upload chunks keep
     # appending below without being copied on every read.
     if(!$key_framed && !$rpc_client{$connection}) {
      my $had=length($cmd{$connection} // "");
      my $head=($had >= 5) ? substr($cmd{$connection},0,5) : substr(($cmd{$connection} // "").$key,0,5);
      if($head eq "GET /") {
       $cmd{$connection}.=$key;
       # The empty line can straddle two reads: look from just before the
       # new bytes, not through the whole buffer again.
       my $from=($had > 3) ? $had-3 : 0;
       if($key ne "" && substr($cmd{$connection},$from)!~/\n\r?\n/) {
        &close_connection($connection,"HTTP request longer than $pattern_cmd_max_bytes bytes") if(length($cmd{$connection}) > $pattern_cmd_max_bytes);
        last;
       }
       $key=$cmd{$connection};
       $cmd{$connection}="";
       $http_request=1;
      }
     }
    }
    #&stats("bytes",length($key));
    #
    # variables initialization
    #
    $scaling_done=0;
    $signal_gate_owner="$connection";
    #
    # Reference Unified Pattern Generator Control Interface Init Request
    # INIT:1.2
    #
    $calman{$connection}=0;
    if($key =~/$end_cmd_string_calman$/ || $rpc_client{$connection}) {
     $calman{$connection}=1;
     my $probe_key=$key;
     $probe_key=~s/[\x02\x03]//g;
     $probe_key=~s/^\s+|\s+$//g;
     # EOF arrives here as an empty key: it ends the socket, it opens nothing.
     if($probe_key=~/^(?:|SN|CAP|GET_SETTINGS|STATUS|FIRMWARE)$/) { &calibration_session_touch($connection); }
     else { &calibration_session_open($connection,"Calman"); }
    } else {
     &calibration_session_touch($connection);
    }
    #
    # GET HTML IMAGE LIST
    # GET /frames/index.html HTTP/1.1
    #
    if($key =~/GET \/(.*)\/index.html /) {
     my $list_rel=uri_unescape($1);
     my $list_dir=&path_inside($var_dir,$list_rel);
     my (@dir_parts,$html_image_list_disabled,$dir_el)=(split("/",$list_rel),0,"");
     for(@dir_parts) {
       $dir_el.="$_/";
       $html_image_list_disabled=1 if(-f "$var_dir/$dir_el/HTMLIMAGELIST.disabled");
     }
     # Only folders inside $var_dir are listed.
     if($html_image_list_disabled || $list_dir eq "" || !-d $list_dir) {
      &send_key_to_client($connection,"HTTP/1.0 404 Not Found\r\n");
      &close_connection($connection);
      last;
     }
     $prefix=&pattern_html_escape($1);
     $content_type="text/html";
     opendir(DIR,$list_dir);
     @list_images=readdir(DIR);
     closedir(DIR);
     $img_content="<body style='background-color:#adadad;'>\n";
     $img_content.="<center>\n";
     for(@list_images) {
      if(/(\.jpg|\.png)/) {
       $file_path="/$prefix/".&pattern_html_escape($_)."-".time();
       $img_content.="<a target=new href=\"$file_path\">";
       $img_content.="<img style='border:1px solid black' src=\"$file_path\" width=$img_width height=$img_height>";
       $img_content.="</a>";
       $img_content.="<br><br>\n";
      }
     }
     $img_content.="</center>\n";
     $img_content.="</body>\n";
     $img_content="HTTP/1.0 200 OK\r\nContent-Type: $content_type\r\nConnection: close\r\n\r\n".$img_content;
     &send_key_to_client($connection,$img_content);
     &close_connection($connection);
     last;
    }
    #
    # GET IMAGE CONTENT
    # GET /frames/1-TEST,,,,3000000.png HTTP/1.1
    #
    if($key =~/GET \/(.*)\/(.*)\.(jpg|png)-.* /) {
     my $img_extension=$3;
     # Only an existing image inside $var_dir is served.
     my $img_file=&path_inside($var_dir,uri_unescape("$1/$2.$3"));
     if($img_file eq "" || !-f $img_file) {
      &send_key_to_client($connection,"HTTP/1.0 404 Not Found\r\n");
      &close_connection($connection);
      last;
     }
     my $img_size="";
     $img_size=$img_width."x".$img_height if($key=~/\&preview=1/);
     $img_size=$1                         if($key=~/\&resize=(\d+x\d+)/);
     # convert runs from an argument list, never through a shell: the path
     # comes from the client.
     my $img_fh;
     my $img_opened=($img_size ne "") ? open($img_fh,"-|",$convert,"-resize",$img_size,$img_file,"$img_extension:-")
                                      : open($img_fh,"<",$img_file);
     $img_content="";
     if($img_opened) {
      binmode($img_fh);
      local $/;
      $img_content=<$img_fh> // "";
      close($img_fh);
     }
     $content_type="image/$img_extension";
     if($key=~/\&inline=1/) {
      $img_content='<img src="data:'.$content_type.';base64,'.encode_base64($img_content,"").'" />';
      $content_type="text/html";
     }
     $img_content="HTTP/1.0 200 OK\r\nAccess-Control-Allow-Origin:*\r\nContent-Type: $content_type\r\nConnection: close\r\n\r\n".$img_content;
     &send_key_to_client($connection,$img_content);
     &close_connection($connection);
     last;
    }
    # A whole HTTP request the port has no route for gets an answer too.
    if($http_request) {
     &send_key_to_client($connection,"HTTP/1.0 404 Not Found\r\n");
     &close_connection($connection);
     last;
    }
    #
    # CONNECTION INTERRUPT
    #
    if($key eq "") {
     $command_found=1;
     &close_connection($connection,"client eof");
     last;
    }
    #
    # END CMD STRING
    #
    # $key is one whole command here (cut on receive), or bytes of one
    # still missing its terminator: those wait in $cmd for the next read.
    if($rpc_client{$connection}) {
     $cmd{$connection}="";
    } elsif(!$key_framed) {
     $cmd{$connection}.=$key;
     if(length($cmd{$connection}) > $pattern_cmd_max_bytes) {
      &close_connection($connection,"command longer than $pattern_cmd_max_bytes bytes");
     }
     last;
    }
    #$key=~s/\n|\r//g;
    $key=~s/$end_cmd_string|$end_cmd_string_calman//;
    $key=~s/[\r\n]+$//;
    $command_found=0;
    #
    # CLOSE COMMAND
    #
    if($key eq "" || $key=~/^$close_command/) {
     &close_connection($connection,"client close command");
     last;
    }
    #
    # UPLOAD_FILE:VIDEO:FILE.txt:text/plain:END_UPLOAD:1024:207:FileContent
    #
    if($key=~/^$upload_file_command:(.*)/) {
     my $response_to_send=$ok_response;
     ($packet=$key)=~s/^$upload_file_command://;
     ($f_where,$f_name,$f_type,$f_status,$f_start,$f_size,$f_content)=split(":",$packet,7);
     # A file name, never a path, into a known target folder.
     my $dir_file=&get_destination($f_where);
     my $safe_name=&safe_file_name($f_name);
     # The size divides the progress below: a size that is not a whole
     # number above 0 ("abc", "0.0") would stop the daemon.
     if($f_size !~ /^\d+$/ || $f_size == 0) {
      # A refused chunk of the running upload ends it like a lost one.
      my $running=$upload_state{$connection};
      &upload_fail($connection,$f_where,$safe_name,$f_status,$f_start) if($running && $running->{where} eq $f_where && $running->{name} eq $safe_name);
      &send_key_to_client($connection,&error());
      last;
     }
     if($dir_file eq "" || $safe_name eq "") {
      &log("Upload refused: target \"$f_where\", name \"$f_name\"");
      &upload_abort($connection);
      &send_key_to_client($connection,&error());
      last;
     }
     $f_content=~s/.*;base64,//g;
     # Each connection uploads into its own temp file, kept for the target
     # and name it was started for: two uploads at once, or another target
     # or name after an unfinished one, never add to each other's bytes.
     # The same target and name continue the file: START only feeds the
     # progress, and what it counts is not known from any client here.
     my $upload=$upload_state{$connection};
     if($upload && ($upload->{where} ne $f_where || $upload->{name} ne $safe_name)) {
      &upload_abort($connection);
      $upload=undef;
     }
     # The chunks a client sent after one was refused belong to that upload:
     # refused as well, up to its END_UPLOAD. Only a chunk with the start
     # value the upload's first chunk had is the client sending the file
     # again from its beginning, and begins a new upload; what the start
     # value counts is not known, so no other value is taken for a restart.
     if($upload && $upload->{failed}) {
      if(($f_start // "") ne $upload->{first}) {
       delete $upload_state{$connection} if($f_status eq "END_UPLOAD");
       &send_key_to_client($connection,&error());
       last;
      }
      delete $upload_state{$connection};
      $upload=undef;
     }
     if(!$upload) {
      my $tmp_file=&upload_tmp_create();
      if($tmp_file eq "") {
       &log("Upload: cannot create a temp file in $upload_tmp_dir: $!");
       &upload_fail($connection,$f_where,$safe_name,$f_status,$f_start);
       &send_key_to_client($connection,&error());
       last;
      }
      $upload=$upload_state{$connection}={tmp=>$tmp_file,where=>$f_where,name=>$safe_name,first=>($f_start // "")};
     }
     $f_tmp_name=$upload->{tmp};
     # A temp file that is gone lost the chunks before this one, and a chunk
     # that is not written leaves a hole: either ends the upload with an
     # error instead of storing what happened to land.
     if(!-f $f_tmp_name || !&upload_file($f_name,$f_tmp_name,$f_content)) {
      &log("Upload: chunk of \"$safe_name\" not written to $f_tmp_name");
      &upload_fail($connection,$f_where,$safe_name,$f_status,$f_start);
      &send_key_to_client($connection,&error());
      last;
     }
     $f_perc=int((100*$f_start)/$f_size)."%";
     if($f_status eq "END_UPLOAD") {
      delete $upload_state{$connection};
      if($f_where eq "PLUGINS") { $response_to_send=&sudo("SET_PLUGIN",$f_tmp_name,$safe_name,$f_where,"install.sh"); }
      else                      {
       require File::Copy;
       # Check uploaded file type
       my $file_type="";
       if(open(my $type_fh,"-|",$file_command,$f_tmp_name)) {
        $file_type=<$type_fh> // "";
        close($type_fh);
       }
       # Add support to extract Zip archive data
       if($file_type =~/Zip archive data/) {
        $response_to_send=$error_response if(!&upload_extract_zip($f_tmp_name,$dir_file));
        unlink($f_tmp_name);
       } elsif(!File::Copy::move($f_tmp_name,"$dir_file/$safe_name")) {
        &log("Upload: cannot store $dir_file/$safe_name: $!");
        unlink($f_tmp_name);
        $response_to_send=$error_response;
       }
      }
      $f_perc="100%";
     }
     &send_key_to_client($connection,"$response_to_send:$f_perc");
     last;
    }
    #
    # Reference Unified Pattern Generator Control Interface Command Request
    # TERM — graceful disconnect (no colon, handle separately)
    #
    if($calman{$connection} && $key=~/TERM/) {
     &calman_reset_pattern_state("TERM");
     &release_source_rgb_quant_range("calman");
     &calibration_session_close($connection,"TERM");
     &send_key_to_client($connection,"");
     &calman_clear_gci_connection($connection);
     &close_connection($connection,"calman TERM");
     last;
    }
    #
    # Reference Unified Pattern Generator Control Interface Command Request
    # RGB_S|B|A:0512,0512,0512,0512
    # Display mode: DSMD:SDR|HDR10|HLG|DOLBYVISION
    # EOTF:0-3  PRIM:0-3  BITD:8|10|12  CLSP:BT709|BT2020
    # MAXL:nits  MINL:nits  MAXCLL:nits  MAXFALL:nits
    # COLF:RGB|YCBCR444|YCBCR422  QRNG:FULL|LIMITED|DEFAULT
    # 
    if($calman{$connection}) {
     # Log raw data for debugging (hex + ascii)
     my $hex_key=join(' ',map { sprintf("%02x",ord($_)) } split(//,$key));
     &log("Calman RAW: [$hex_key] ascii=[$key]");
     #
    # No-colon client commands (SN, CAP, ENABLE PATTERNS)
     #
     my $clean_key=$key;
     $clean_key=~s/^\x02//;
     $clean_key=~s/\x03$//;
     $clean_key=~s/^\s+|\s+$//g;
     if($clean_key eq "SN") {
      # Serial number — return CPU serial
      my $sn=`cat /proc/cpuinfo 2>/dev/null | grep Serial | awk '{print \$3}'`;
      $sn=~s/\s+//g;
        $sn=$version_plus if($sn eq "");
      &log("Calman: SN request, returning $sn");
      &send_calman_payload_to_client($connection,$sn);
      last;
     }
     if($clean_key eq "CAP") {
      # Capabilities. Calman stores the tokens as the device's command set
      # (with no usable CAP reply it falls back to the same UPGCI list), so
      # report the UPGCI commands first, then the PGenerator+ extensions.
      # Calman only sends GET_SETTINGS when CAP lists it, and it ignores a
      # CAP reply that does not start with ACK.
      my $caps="GET_SETTINGS,STATUS,CONF_FORMAT,CONF_HDR,CONF_LEVEL,CONF_DV,HDR_ENABLE,IMAGE,PUSH,RGB_S,RGB_B,RGB_A,SPECIALTY,UPDATE,YCC_A,YCC_B,YCC_S,HDR,DOLBYVISION,SIZE,10_SIZE,11_APL,CommandRGB,BITDEPTH,COLORSPACE,RANGE";
      # The G1 source (port 2101) gets exactly its built-in list, without
      # GET_SETTINGS. Its UI does not show what GET_SETTINGS reports: after
      # reading "Format YCC444_10" it still showed RGB 8-bit (Calman's
      # Color Format list has "YCbCr 444 10-bit"). The output then has to
      # follow Calman's start-up format instead (see calman_g1_startup), so
      # the cable and Calman's display agree.
      $caps="STATUS,CONF_FORMAT,CONF_HDR,CONF_LEVEL,CONF_DV,HDR_ENABLE,IMAGE,PUSH,RGB_S,RGB_B,RGB_A,SPECIALTY,UPDATE,YCC_A,YCC_B,YCC_S" if($rpc_client{$connection});
      &log("Calman: CAP request, returning $caps");
      &send_calman_payload_to_client($connection,$caps,1);
      last;
     }
     if($clean_key eq "ENABLE PATTERNS" || $clean_key eq "ENABLEPATTERNS") {
      &log("Calman: ENABLE PATTERNS acknowledged");
      &send_key_to_client($connection,"");
      last;
     }
     if($clean_key eq "DISABLE PATTERNS" || $clean_key eq "DISABLEPATTERNS") {
      &log("Calman: DISABLE PATTERNS acknowledged");
      &send_key_to_client($connection,"");
      last;
     }
     if($clean_key eq "FIRMWARE") {
      # Only the G1 source asks for FIRMWARE during its handshake.
      $calman_g1_startup{$connection}=1;
      &log("Calman: FIRMWARE request, returning $version");
      &send_calman_payload_to_client($connection,$version);
      last;
     }
     if($clean_key eq "STATUS") {
      # Calman (G1/PatternForge sources) puts this into its
      # "SN:%s VER:%s STATUS:%s" device string and keeps at most 63 chars;
      # the command list belongs in CAP.
      my $status="OK";
      &log("Calman: STATUS request, returning $status");
      &send_calman_payload_to_client($connection,$status);
      last;
     }
     if($clean_key eq "SHUTDOWN" || $clean_key eq "QUIT") {
      &log("Calman: $clean_key received, closing connection");
      &calman_reset_pattern_state($clean_key);
      &release_source_rgb_quant_range("calman");
      &calibration_session_close($connection,$clean_key);
      &send_key_to_client($connection,"");
      &calman_clear_gci_connection($connection);
      &close_connection($connection,"calman $clean_key");
      last;
     }
     if($clean_key eq "UPDATE") {
      &log("Calman: UPDATE acknowledged");
      &send_key_to_client($connection,"");
      last;
     }
     if($clean_key eq "IS_ALIVE" || $clean_key eq "ISALIVE") {
      &log("Calman: IS_ALIVE acknowledged");
      &send_key_to_client($connection,"");
      last;
     }
     if($clean_key eq "GET_SETTINGS") {
      delete $calman_g1_startup{$connection};
      # Calman splits the reply into "Key Value" pairs at "," and the first
      # space. It maps Format (RGB, YCC444, YCC422, YCC420 and the _10
      # variants) to its colour format list, Range (Full/Limited) and Bits
      # (8/10/12) to its controls and matches "Resolution Refresh" against
      # the source's mode list, whose entries look like CONF_FORMAT's
      # "1920x1080p 60". Without a usable reply a G1 source falls back to
      # Limited range.
      my $cur_scan=($preferred_mode =~/\d+x\d+i/) ? "i" : "p";
      my $cur_res="${w_s}x${h_s}${cur_scan}";
      my $cur_refresh="60";
      $cur_refresh=$1 + 0 if($preferred_mode =~/\s([\d.]+)Hz/);
      my $cur_bits=$pgenerator_conf{"max_bpc"} || "8";
      $cur_bits="8" if($cur_bits !~/^(8|10|12)$/);
      # Outside Dolby Vision 12 bpc goes out as 10 bpc (see sync_pattern_bits_default).
      $cur_bits="10" if($cur_bits eq "12" && int($pgenerator_conf{"dv_status"} || 0) != 1);
      my %ycc_format=("1"=>"YCC444","2"=>"YCC422","3"=>"YCC420");
      my $cf=$pgenerator_conf{"color_format"} || "0";
      my $cur_format="RGB";
      if(exists $ycc_format{$cf}) {
       $cur_format=$ycc_format{$cf};
       $cur_format.="_10" if($cur_bits ne "8");
      }
      # The range on the cable: "Default" is Limited for YCbCr and the
      # renderer's default for RGB.
      my $cur_range=(&effective_rgb_quant_range() == 1) ? "Limited" : "Full";
      my $cur_hdr=(($pgenerator_conf{"is_hdr"} || "") eq "1") ? "On" : "Off";
      my $cur_dolby=(($pgenerator_conf{"dv_status"} || "") eq "1") ? "On" : "Off";
      my $settings="Resolution $cur_res,Refresh $cur_refresh,Format $cur_format,Range $cur_range,Bits $cur_bits,HDR $cur_hdr,Dolby $cur_dolby";
      &log("Calman: GET_SETTINGS returning: $settings");
      &send_calman_payload_to_client($connection,$settings,1);
      last;
     }
    }
    if($calman{$connection} && $key=~/:/) {
     ($type,$pattern_cmd)=&calman_split_command($key);
     $type=~s/^\x02//;
     &log("Calman UPGCI: type=$type cmd=$pattern_cmd");
     #
    # INIT — client handshake. The reference does not always send its selected
    # resolution on connect, so apply the remembered/default reference mode.
     #
     if($type eq "INIT") {
      &calman_reset_pattern_state("INIT");
      &calman_apply_init_mode();
      # The reference's UPGCI 2.0 is the GCI plugin's handshake. The reference RPC
      # plugin connects to the RPC socket and never sends INIT:2.0, so
      # this branch is GCI-only. Mark the connection (and the global
      # PGenerator.conf) so that drm_override.so can stop overwriting
      # the user's signal-mode WebUI settings for the lifetime of the
      # GCI session.
      if($pattern_cmd =~/\s*2\.0/) {
       $calman_gci{$connection}=1;
       &calman_set_gci_active(1);
      }
      &send_key_to_client($connection,"");
      last;
     }
     #
     # Helper: save a PGenerator conf key and mark settings dirty
     # (defers the pattern generator restart until a pattern command arrives)
     #
	     # Reference GCI control plane: runtime range overrides also
	     # bypass user WebUI config. Wrap the source-range helpers
	     # so that GCI connections are no-ops while RPC connections
	     # keep their existing behavior.
	     my $calman_apply_source_range = sub {
	      return 0 if($calman_gci{$connection});
	      my $range=shift;
	      $calman_rgb_quant_range=$range + 0;
	      &apply_source_rgb_quant_range("calman",$calman_rgb_quant_range);
	      return 1;
	     };
	     my $calman_release_source_range = sub {
	      return 0 if($calman_gci{$connection});
	      &release_source_rgb_quant_range("calman");
	      $calman_rgb_quant_range=0;
	      return 1;
	     };
	     #
	     # Helper: enforce signal-mode coherence on the conf as a
	     # daemon-derived update, not a reference write. When the GCI
	     # gate is active, the helper-mode transition (HDR_ENABLE,
	     # CONF_HDR, CONF_SDR, DSMD, EOTF) writes eotf/is_hdr/
	     # primaries via calman_save_setting (allow-listed), but the
	     # gate suppresses reference saves of the mode-coupled keys
	     # (signal_mode, is_sdr, colorimetry, dv_status,
	     # is_ll_dovi, is_std_dovi) — which are WebUI-owned
	     # preferences and must NOT be writable by the reference. Without
	     # this, the conf is left incoherent (is_hdr=1, eotf=2
	     # with signal_mode=sdr, is_sdr=1, colorimetry=2), the
	     # renderer's wire colorimetry (10) is then rewritten back
	     # to 2 by drm_override.so on every atomic commit, and the
	     # LG C2 reports BT.709 instead of BT.2020.
	     #
	     # This helper recomputes the mode-coupled keys from the
	     # post-save conf and writes them directly via sudo, so the
	     # gate is bypassed (it is a daemon write, not a reference
	     # write). Preference keys (rgb_quant_range, max_bpc,
	     # color_format, min_luma, max_luma, max_cll, max_fall)
	     # are not touched — they remain strictly WebUI-owned and
	     # reference writes of them stay suppressed.
	     #
	     # DV transitions (calman_set_dv_rgb / DSMD:DOLBYVISION /
	     # 21_HDR_MetadataMode 1-4) set the $calman_dv_transition_active
	     # flag before their saves run. While the flag is set, this
	     # helper writes dv_status=1 and the standard-transport DV
	     # flags (is_ll_dovi=0, is_std_dovi=1) as daemon-derived
	     # updates, so the GCI gate does not silently drop the DV
	     # enable and leave the renderer in HDR10 mode. The flag is
	     # unset by the DV handler after all its saves complete.
	     #
	     my $calman_dv_transition_active=0;
	     my $calman_enforce_mode_coherence = sub {
	      return if(!$calman_gci{$connection});
	      my $eotf_val=int($pgenerator_conf{"eotf"} || 0);
	      my $prim_val=int($pgenerator_conf{"primaries"} || 0);
	      my $is_hdr_val=int($pgenerator_conf{"is_hdr"} || 0);
	      # Treat as a non-DV transition when the post-save eotf
	      # is one of the SDR/PQ/HLG values (0/2/3). eotf=1 is
	      # "HDR gamma" which the legacy code mapped to non-DV HDR.
	      my $non_dv=(defined $eotf_val && $eotf_val >= 0 && $eotf_val <= 3);
	      my $want_signal_mode="sdr";
	      $want_signal_mode=($eotf_val == 3) ? "hlg" : "hdr10" if($eotf_val >= 2);
	      $want_signal_mode="hdr10" if($eotf_val == 1);
	      my $want_is_sdr=($eotf_val >= 2) ? "0" : "1";
	      my $want_is_hdr=($eotf_val >= 2) ? "1" : "0";
	      # Colorimetry: BT.2020 (9) for HDR/HLG, whatever the gamut
	      # target (BT.709 primaries are patches inside the BT.2020
	      # container; a renderer start pins 9 too,
	      # normalize_signal_mode_conf); BT.709 (2) for SDR.
	      my $want_colorimetry=($eotf_val >= 2) ? "9" : "2";
	      # Resolve the final signal_mode / DV flags before building
	      # the write list, so a DV transition overrides the
	      # eotf-derived signal_mode (otherwise the initial hdr10
	      # entry would win and the conf would still look like HDR).
	      if($calman_dv_transition_active) {
	       $want_signal_mode="dv";
	      }
	      my @coherence_writes=(
	       ["signal_mode",$want_signal_mode],
	       ["is_sdr",$want_is_sdr],
	       ["is_hdr",$want_is_hdr],
	       ["colorimetry",$want_colorimetry],
	      );
	      if($calman_dv_transition_active) {
	       # DV transition: write the standard-transport DV flags
	       # as daemon-derived updates. The GCI gate would have
	       # suppressed calman_set_dv_rgb's saves of these, so the
	       # conf would otherwise stay at dv_status=0 (HDR10) even
	       # though the reference asked for DV.
	       # Calman requests the standard (TV-led) RGB tunnel: it sends
	       # 8 bpc, RGB and Full range before CONF_DV. Switch the saved
	       # transport too, first, so normalize_dv_transport_conf()
	       # (run by every SET_PGENERATOR_CONF below) agrees instead of
	       # pulling an LLDV WebUI preference back in between writes.
	       push @coherence_writes,["dv_transport","standard"];
	       push @coherence_writes,["dv_interface",&pg_dv_transport_interface("standard")];
	       push @coherence_writes,["dv_status","1"];
	       push @coherence_writes,["is_ll_dovi","0"];
	       push @coherence_writes,["is_std_dovi","1"];
	      } elsif($non_dv) {
	       push @coherence_writes,["dv_status","0"];
	       push @coherence_writes,["is_ll_dovi","0"];
	       push @coherence_writes,["is_std_dovi","0"];
	      }
	      my $changed=0;
	      foreach my $cw (@coherence_writes) {
	       my ($k,$v)=@$cw;
	       my $cur="$pgenerator_conf{$k}";
	       $cur="" if(!defined $cur);
	       next if($cur eq "$v");
	       &sudo("SET_PGENERATOR_CONF",$k,$v);
	       $pgenerator_conf{$k}="$v";
	       $changed=1;
	       &log("Calman GCI: coherence update $k=$v (WebUI-owned, but mode transition implied it)");
	      }
	      if($changed) {
	       $calman_settings_dirty=1;
	       &log("Calman GCI: signal-mode coherence enforced (eotf=$eotf_val primaries=$prim_val is_hdr=$is_hdr_val)");
	      }
	     };
	     my $calman_save_setting = sub {
	      my ($conf_key,$conf_val)=@_;
	      # The reference GCI plugin (UPGCI 2.0 control plane) must not
	      # override the user's WebUI signal-mode settings. The
	      # reference-controlled values that affect the HDR plane
	      # encoding are is_hdr, primaries, and eotf; everything
	      # else (signal_mode, is_sdr, colorimetry, dv_*, etc.) is
	      # left to the WebUI configuration. is_hdr is allow-listed
	      # so the GCI plugin's HDR_ENABLE command actually turns
	      # HDR on; without it the GCI HDR enable toggle is
	      # silently dropped. color_format and max_bpc are also
	      # allow-listed so that the reference source-format /
	      # bit-depth controls (COLF:YCBCR444, BITD:10, etc.)
	      # actually take effect on the wire; the WebUI's
	      # color_format and max_bpc preference is only meaningful
	      # as a fallback when the reference isn't driving these.
	      # min_luma, max_luma, max_cll and max_fall are
	      # allow-listed so that the MAXL / MINL / MAXCLL /
	      # MAXFALL (HDR mastering display luminance metadata)
	      # actually take effect — the renderer's
	      # updateHDR_Infoframe() reads these from the conf on
	      # every page flip, so saving them is harmless and is
	      # the only way the GCI client can drive luminance during
	      # a calibration pass under GCI. rgb_quant_range is
	      # also allow-listed so that the source-range
	      # commands (CONF_LEVEL:Range Limited, QRNG:LIMITED,
	      # SetRange:1) actually stick — without it the WebUI
	      # can show "Limited" while the server-side
	      # rgb_quant_range stays at the last value the reference
	      # sent (typically Full for HDR), and the next poll
	      # flips the UI back. The reference RPC plugin never
	      # sets $calman_gci, so the RPC path is unaffected.
	      # dv_map_mode / dv_metadata are allow-listed so CONF_DV
	      # (PERCEPTUAL / ABSOLUTE / RELATIVE) can switch the
	      # renderer map mode under GCI. Without them Absolute
	      # was silently dropped and the conf stayed on the last
	      # WebUI map mode while the wire still looked like HDR10
	      # (dv_status never reached 1 either — see the explicit
	      # coherence call at the end of calman_set_dv_rgb).
	      if($calman_gci{$connection} &&
	        $conf_key ne "primaries" && $conf_key ne "eotf" && $conf_key ne "is_hdr" &&
	        $conf_key ne "color_format" && $conf_key ne "max_bpc" &&
	        $conf_key ne "min_luma" && $conf_key ne "max_luma" &&
	        $conf_key ne "max_cll" && $conf_key ne "max_fall" &&
	        $conf_key ne "rgb_quant_range" &&
	        $conf_key ne "dv_map_mode" && $conf_key ne "dv_metadata") {
	       &log("Calman GCI: suppressed save $conf_key=$conf_val (WebUI owns this key)");
	       return;
	      }
	      # Skip no-op writes. calman_apply always calls
	      # calman_force_dv_rgb, which re-asserts the DV RGB
	      # transport keys (is_hdr/eotf/color_format/max_bpc/
	      # rgb_quant_range/primaries). Without this guard each
	      # of those re-saves set calman_settings_dirty even when
	      # the value already matched, so the apply while-loop
	      # never exited: it spun replaying SPECIALTY:ALIGNMENT
	      # forever and starved the GCI socket of RGB_S / 100% /
	      # 109% pattern commands (DV Autocal stuck on alignment).
	      # HDR10/HLG/DV are BT.2020 signals: a gamut or colour-space
	      # command (PRIM, CLSP, CONF_HDR with BT.709 primaries) does not
	      # turn the colorimetry to BT.709 while HDR is on. drm_override
	      # reads the conf on every commit, so it would reach the wire.
	      # Calman's mode switches write is_hdr before the colorimetry.
	      $conf_val="9" if($conf_key eq "colorimetry" && int($pgenerator_conf{"is_hdr"} || 0) == 1);
	      my $new_val=defined($conf_val) ? "$conf_val" : "";
	      my $cur_val=defined($pgenerator_conf{$conf_key}) ? "$pgenerator_conf{$conf_key}" : "";
	      if($cur_val eq $new_val) {
	       # A refused apply put the conf back to the kept output; Calman
	       # choosing those working settings again must still reach the
	       # apply, which ends the refused state (signal_gate_conf).
	       $calman_settings_dirty=1 if(&signal_patches_refused() ne "");
	       return;
	      }
	      &sudo("SET_PGENERATOR_CONF",$conf_key,$conf_val);
	      $pgenerator_conf{$conf_key}="$conf_val";
	      &sync_pattern_bits_default();
	      $calman_settings_dirty=1;
	      &log("Calman: saved $conf_key=$conf_val (dirty flag set)");
	      # If the GCI gate just allowed a mode-affecting save
	      # (eotf/is_hdr/primaries), the helper above that issued
	      # the save also tried to write the mode-coupled keys
	      # (signal_mode, is_sdr, colorimetry, dv_*, …) but those
	      # were suppressed by the same gate. Recompute them here
	      # as a daemon-derived update so the conf stays coherent
	      # and drm_override.so stops rewriting the renderer's
	      # wire colorimetry back to 2.
	      $calman_enforce_mode_coherence->() if($calman_gci{$connection} &&
	        ($conf_key eq "eotf" || $conf_key eq "is_hdr" || $conf_key eq "primaries"));
	     };
	     my $calman_note_explicit_bpc = sub {
	      my $bpc=&calman_valid_bpc(shift);
	      return "" if($bpc eq "");
	      $calman_explicit_max_bpc=$bpc;
	      &log("Calman: explicit bit depth set to ${bpc}bpc");
	      return $bpc;
	     };
	     my $calman_preferred_bpc = sub {
	      my ($fallback,$preserve_current)=@_;
	      return &calman_choose_bpc($calman_explicit_max_bpc,$pgenerator_conf{"max_bpc"},$fallback,$preserve_current);
	     };
	     my $calman_apply_source_payload = sub {
	      my ($payload,$default_format_bpc)=@_;
	      my %parsed=&calman_parse_source_format_payload($payload,$default_format_bpc);
	      my $changed=0;
	      # The renderer has no YCbCr 4:2:0 encode path and the link stays
	      # RGB, so the drawn codes would not match the signal. Keep the
	      # current format and its bit depth instead.
	      if($parsed{color_format} eq "3") {
	       &log("Calman: YCbCr 4:2:0 is not supported, keeping color_format=".($pgenerator_conf{"color_format"} // "0")." max_bpc=".($pgenerator_conf{"max_bpc"} // "8"));
	       my %fmt_name=("0"=>"RGB","1"=>"YCbCr 4:4:4","2"=>"YCbCr 4:2:2");
	       my $kept=($fmt_name{$pgenerator_conf{"color_format"} // "0"} || "RGB")." ".($pgenerator_conf{"max_bpc"} || 8)."-bit";
	       &webui_notice("YCbCr 4:2:0 is not supported","Calman requested YCbCr 4:2:0. PGenerator+ has no YCbCr 4:2:0 output, so the output stays $kept.\nChoose RGB or YCbCr 4:4:4 in Calman for bit-exact measurements.");
	       $parsed{color_format}="";
	       $parsed{max_bpc}="";
	      }
	      if($parsed{color_format} ne "") {
	       $calman_save_setting->("color_format",$parsed{color_format});
	       $changed=1;
	      }
	      if($parsed{max_bpc} ne "") {
	       my $bpc=$calman_note_explicit_bpc->($parsed{max_bpc});
	       if($bpc ne "") {
	        $calman_save_setting->("max_bpc",$bpc);
	        $changed=1;
	       }
	      }
	      if($parsed{range} ne "") {
	       if($parsed{range} eq "1" || $parsed{range} eq "2") {
	        if($calman_gci{$connection}) {
	         &log("Calman GCI: source-format range=$parsed{range} ignored (WebUI owns rgb_quant_range)");
	        } else {
	         $calman_rgb_quant_range=$parsed{range} + 0;
	         &log("Calman: external range set to $calman_rgb_quant_range via source settings");
	         &apply_source_rgb_quant_range("calman",$calman_rgb_quant_range);
	        }
	       } else {
	        if($calman_gci{$connection}) {
	         &log("Calman GCI: source-format range release ignored (WebUI owns rgb_quant_range)");
	        } else {
	         &log("Calman: releasing external range via source settings");
	         &release_source_rgb_quant_range("calman");
	         $calman_rgb_quant_range=0;
	        }
	       }
	      }
	      return $changed;
	     };
	     my $calman_dv_metadata_for_map_mode = sub {
	      my $map_mode=shift;
	      return "2" if(defined $map_mode && $map_mode eq "0");
      return "3" if(defined $map_mode && $map_mode eq "1");
      return "4" if(defined $map_mode && $map_mode eq "2");
      return "2";
     };
     #
     # Helper: Dolby Vision transport is platform-specific. Pi 5 uses RGB
     # tunneling; Pi 4-family keeps the historical 2.6.x RGB/full/12b path.
     # Later generic reference format/range/bit-depth commands must not undo it.
     #
     my $calman_dv_active = sub {
      return 1 if(int($pgenerator_conf{"dv_status"} || 0) == 1);
      return 1 if(int($pgenerator_conf{"is_ll_dovi"} || 0) == 1);
      return 1 if(int($pgenerator_conf{"is_std_dovi"} || 0) == 1);
      return 0;
     };
     my $calman_force_dv_rgb = sub {
      return if(!$calman_dv_active->());
     $calman_dv_transition_active=1;
     $calman_save_setting->("is_sdr","0");
     $calman_save_setting->("is_hdr","1");
     $calman_save_setting->("eotf","2");
      my $dv_transport="standard";
      $calman_save_setting->("dv_transport",$dv_transport);
      $calman_save_setting->("is_ll_dovi",&pg_dv_transport_ll_flag($dv_transport));
      $calman_save_setting->("is_std_dovi",&pg_dv_transport_std_flag($dv_transport));
      $calman_save_setting->("dv_status","1");
      $calman_save_setting->("dv_interface",&pg_dv_transport_interface($dv_transport));
      $calman_save_setting->("dv_color_space","0");
	      $calman_save_setting->("color_format",&pg_dv_transport_color_format($dv_transport));
	      $calman_save_setting->("colorimetry","9");
	      $calman_save_setting->("primaries","1");
	      $calman_save_setting->("max_bpc",$calman_preferred_bpc->(&pg_dv_transport_max_bpc($dv_transport)));
	      $calman_save_setting->("rgb_quant_range",&pg_dv_transport_quant_range($dv_transport));
	      $calman_save_setting->("dv_metadata",$calman_dv_metadata_for_map_mode->($pgenerator_conf{"dv_map_mode"}));
      if(!$calman_gci{$connection}) {
       $calman_rgb_quant_range=2;
       &apply_source_rgb_quant_range("calman",2);
      }
      # Same as calman_set_dv_rgb: re-assert DV coherence even when
      # the is_hdr/eotf/primaries writes were no-ops, so an apply
      # mid-DV session cannot leave dv_status=0 / signal_mode=hdr10.
      $calman_enforce_mode_coherence->() if($calman_gci{$connection});
      $calman_dv_transition_active=0;
     };
     #
     # Helper: apply pending settings — restart pattern generator if dirty
     #
     #
     # Apply-queue flag: set when calman_apply is called while an
     # apply is already in progress. When the current apply finishes,
     # if this flag is set we re-enter apply to pick up the latest
     # conf (subsequent commands during the in-flight apply may have
     # updated the conf further). Without this serialization, rapid
     # reference setting changes (e.g. CONF_HDR + COLF + BITD in quick
     # succession) trigger back-to-back pattern_generator_stop/start
     # cycles that hit the documented DRM-master race persistently
     # and the renderer stays dead. With serialization only one
     # stop/start cycle is in flight at a time; further requests
     # are coalesced into a single follow-up apply.
     #
     my $calman_apply_in_progress=0;
     # Snapshot of the mode-affecting conf keys as of the last
     # successful stop/start apply. If the current conf matches
     # this snapshot, no renderer restart is needed — the
     # renderer's updateHDR_Infoframe() reads min/max luminance,
     # CLL and FALL from the conf on every page flip, and
     # drm_override.so re-applies connector properties (Colorimetry,
     # output_format, max_bpc, rgb_quant_range) on every atomic
     # commit. Skipping the stop+start cycle for non-mode changes
     # (the common case: reference adjusting luminance, or
     # rgb_quant_range during a calibration pass) avoids the
     # documented DRM-master race that was killing the renderer
     # on every "apply" call. Stored in a package-global hash keyed
     # by the connection handle because the per-command handler
     # block is re-entered for every incoming command and a
     # lexical my() here would be re-initialized each time.
     my %calman_applied_mode_keys=%{$main::calman_applied_mode_keys{$connection} || {}};
     my $calman_mode_key_snapshot = sub {
      my $conf=shift || \%pgenerator_conf;
      my %k=();
      # dv_map_mode is included because the pattern renderer only
      # loads it from conf at process start (main.cpp → ofApp /
      # ofxRPI4Window). CONF_DV Absolute↔Relative/Perceptual must
      # therefore force a stop+start; treating it as a non-mode
      # conf write left the wire on the previous map mode while
      # conf already said Absolute/Relative (operator saw no
      # change on PGen when flipping Calman DV map mode).
      for my $k (qw(mode_idx is_hdr eotf colorimetry
                    color_format max_bpc dv_status is_ll_dovi is_std_dovi
                    dv_map_mode)) {
       $k{$k}=defined($conf->{$k}) ? "$conf->{$k}" : "";
      }
      # signal_mode and is_sdr are daemon bookkeeping, not renderer inputs
      # (main.cpp): the mode as the flags above give it, so "hdr" saved by
      # a Calman mode command and the "hdr10" a renderer start writes back
      # are the same mode, not a restart on every command.
      $k{"signal_mode"}=&signal_mode_from_conf($conf);
      # The other DV keys main.cpp reads at start only (interface,
      # profile, colour space, min/max PQ, diagonal) go into the DV
      # metadata (ofApp.cpp) and nowhere else: they count in DV only.
      # Entering or leaving DV changes dv_status, which restarts anyway.
      if(&signal_mode_from_conf($conf) eq "dv") {
       for my $k (qw(dv_interface dv_profile dv_color_space dv_minpq dv_maxpq dv_diagonal)) {
        $k{$k}=defined($conf->{$k}) ? "$conf->{$k}" : "";
       }
      }
      # Keys the renderer can take in place (SIGHUP reconfigure) but that
      # do not count as a mode change: tracked so a non-mode apply knows
      # what actually changed.
      for my $k (qw(rgb_quant_range primaries min_luma max_luma max_cll max_fall)) {
       $k{"meta:$k"}=defined($conf->{$k}) ? "$conf->{$k}" : "";
      }
      return \%k;
     };
     my $calman_apply = sub {
      my $replay_after=shift;
      $replay_after=1 if(!defined $replay_after);
      # Coalesce: if an apply is already running, mark that another
      # is needed and return. The in-flight apply will loop and
      # re-enter calman_apply at the end if dirty stays set.
      if($calman_apply_in_progress) {
       $calman_settings_dirty=1;
       return 0;
      }
      my $did_work=0;
      while($calman_settings_dirty && !$calman_apply_in_progress) {
       $calman_apply_in_progress=1;
       # Clear dirty BEFORE the work so any save that happens
       # during the in-flight apply (from a concurrent command or
       # the coalescing path) sets it back to 1, and the loop
       # re-runs to pick up the latest conf.
       $calman_settings_dirty=0;
       eval {
        $calman_force_dv_rgb->();
        # Refused settings: a signal the board or display cannot carry
        # is not applied. The gate puts the conf back to the kept output
        # and leaves the refused state, which refuses patches until
        # Calman chooses settings that work (return leaves the eval).
        if(!&signal_gate_conf(&signal_source_label("Calman"))) {
         &log("Calman: apply refused, output unchanged");
         return;
        }
        # Compare the current mode-affecting conf to the last
        # applied snapshot. If they match, the connector mode
        # (resolution, color format, colorimetry, max_bpc,
        # signal/eotf/DV flags) is already what the renderer and
        # wire are showing. The change is limited to luminance,
        # primaries, rgb_quant_range, or other keys that the
        # renderer reads on every frame — no stop+start needed,
        # just refresh the HDR metadata blob and connector props.
        my $now=$calman_mode_key_snapshot->();
        # What the running renderer was started with (or reconfigured to in
        # place) decides whether a mode key changed: a connection that has
        # applied nothing yet has no snapshot, and one from an earlier
        # connection on the same handle is stale, so the first apply after
        # connecting restarted the renderer for every key, even when the
        # output already was what the conf says. The metadata keys follow
        # the record too: primaries is read at start and on SIGHUP only.
        # The renderer reads the file, so the file is compared with it: a
        # conf write that did not land (memory set, sudo failed) restarts
        # nothing that would read the old file again.
        my $renderer_conf=&renderer_running_conf();
        my $disk_conf=$renderer_conf ? &renderer_conf_read() : undef;
        if($renderer_conf && $disk_conf) {
         %calman_applied_mode_keys=%{$calman_mode_key_snapshot->($renderer_conf)};
         $now=$calman_mode_key_snapshot->($disk_conf);
        }
        my $mode_changed=0;
        my %changed_keys=();
        for my $k (keys %$now) {
         if((defined $calman_applied_mode_keys{$k} && $calman_applied_mode_keys{$k} ne $now->{$k}) ||
            (!defined $calman_applied_mode_keys{$k} && $now->{$k} ne "")) {
          my $conf_key=$k;
          $mode_changed=1 if($conf_key !~ s/^meta://);
          # signal_mode is daemon bookkeeping, not a renderer input: the
          # renderer-visible part of a signal-mode switch shows up as
          # is_hdr / eotf / dv_* changes, which decide in-place vs restart.
          $changed_keys{$conf_key}=1 if($conf_key ne "signal_mode");
         }
        }
        # Snapshots persisted before the meta: keys existed would report
        # every metadata key as changed once; that is harmless (the renderer
        # simply re-reads them).
        my $renderer_running=&pattern_generator_is_running();
        # apply_source_rgb_quant_range() usually already pushed a range
        # change to the renderer (in place or by restarting it); only a
        # range the running renderer process has not taken yet needs work.
        delete $changed_keys{"rgb_quant_range"} if($renderer_running && &renderer_has_applied_range());
        my $range_changed=$changed_keys{"rgb_quant_range"} ? 1 : 0;
        # The renderer re-reads luminance, CLL and FALL on every frame, the
        # primaries only at start and on SIGHUP: in HDR10 (the DRM infoframe
        # carries them; HLG sends them as zero) a change it did not take in
        # place needs a restart. The mode comes from the same conf as the
        # changed keys: the file a restart would read, when it decided them.
        my $primaries_changed=($changed_keys{"primaries"} &&
                               &signal_mode_from_conf(($renderer_conf && $disk_conf) ? $disk_conf : \%pgenerator_conf) eq "hdr10") ? 1 : 0;
        my $applied_in_place=0;
        if($renderer_running && %changed_keys) {
         # Same-transport changes (format, range, colorimetry, bpc, HDR
         # metadata; DV off) are applied by the running renderer itself.
         # renderer_reconfigure_in_place() refuses DV, is_hdr/mode_idx
         # changes and renderers without SIGHUP support.
         $applied_in_place=&renderer_reconfigure_in_place(\%changed_keys);
        }
        if($applied_in_place) {
         &log("Calman: applied ".join(",",sort keys %changed_keys)." in place (no renderer restart)");
         # The reconfigure may have changed the conf itself (HDR pins
         # colorimetry 9): the snapshot is what the renderer re-read, taken
         # after it, from the same source as $now. One taken before made the
         # next apply see the pinned key as changed and signal again.
         my $after=($renderer_conf && $disk_conf) ? &renderer_conf_read() : \%pgenerator_conf;
         $now=$calman_mode_key_snapshot->($after) if($after);
         %calman_applied_mode_keys=%$now;
        } elsif(!$mode_changed && (!$renderer_running || (!$range_changed && !$primaries_changed))) {
         # Mode unchanged — only metadata / luminance / range
         # changed. The renderer's updateHDR_Infoframe() reads
         # min_luma / max_luma / max_cll / max_fall
         # from the conf on every page flip, so the new values
         # take effect on the next atomic commit without touching
         # the renderer. We re-apply connector properties
         # (apply_drm_properties uses modetest_connector_write,
         # which does NOT touch DRM master) in case colorimetry
         # / rgb_quant_range were changed via the GCI-allow-listed
         # keys. We deliberately do NOT call apply_hdr_metadata_helper
         # (pgsethdr) here because pgsethdr steals DRM master from
         # the running renderer, which would break the renderer's
         # atomic commits. pgsethdr is only needed when the
         # renderer is being (re)started.
          # A running renderer owns the connector properties and DRM
          # master; modetest -w writes (apply_drm_properties) would steal
          # master from it. Luminance, CLL and FALL are re-read from conf
          # by updateHDR_Infoframe() on every flip, so nothing else is
          # needed. Range and HDR primaries changes on a running renderer
          # that could not take them in place go through the restart
          # branch below.
          if($renderer_running) {
           &log("Calman: applying non-mode changes (no renderer restart) — renderer re-reads HDR metadata per frame");
          } else {
           &log("Calman: applying non-mode changes (no renderer restart) — refreshing connector properties");
           &apply_drm_properties();
          }
          %calman_applied_mode_keys=%$now;
         } else {
          &log("Calman: applying pending settings (restarting pattern generator)");
          &pattern_generator_stop();
          &pattern_generator_start();
          # The first start attempt may lose the documented
          # DRM-master race. Retry up to three more times with
          # increasing delays so the apply itself guarantees the
          # renderer is alive before returning, rather than
          # leaving it dead and relying on the next pattern
          # request to trigger a recovery. This is the same
          # retry ladder as load_new_pattern_file in pattern.pm.
          # Without a display the start is deferred, so the ladder
          # would only block the daemon for ~6s.
          if(!&pattern_generator_is_running() && &hdmi_sink_connected()) {
           select(undef,undef,undef,0.6);
           if(!&pattern_generator_is_running()) {
            &log("Calman: apply — renderer not running after first start, retrying (DRM master race)");
            select(undef,undef,undef,0.4);
            &pattern_generator_stop();
            &pattern_generator_start();
            select(undef,undef,undef,0.6);
           }
           if(!&pattern_generator_is_running()) {
            &log("Calman: apply — renderer not running after second start, final retry");
            select(undef,undef,undef,1.0);
            &pattern_generator_stop();
            &pattern_generator_start();
            select(undef,undef,undef,0.6);
           }
           if(!&pattern_generator_is_running()) {
            &log("Calman: apply — renderer failed after 3 starts, waiting 3s for DRM master to settle");
            select(undef,undef,undef,3.0);
            &pattern_generator_stop();
            &pattern_generator_start();
            select(undef,undef,undef,0.8);
           }
           if(!&pattern_generator_is_running()) {
            &log("Calman: apply — renderer failed to start after all retries; wire properties were set but no pattern will render until the next pattern request recovers it");
           }
          }
          %calman_applied_mode_keys=%$now;
         }
         # Persist the snapshot in the package-global hash so it
         # survives across command invocations on the same
         # connection (the per-command handler block is re-entered
         # for every incoming command and a lexical my() would be
         # re-initialized).
         $main::calman_applied_mode_keys{$connection}={%calman_applied_mode_keys};
        &calman_replay_last_pattern("settings apply") if($replay_after);
       };
       $calman_apply_in_progress=0;
       $did_work=1;
      }
      return ($did_work ? 1 : 0);
     };
    #
    # Helper: The reference's DV calibration uses Standard Dolby Vision transport.
    # Absolute/Relative select the renderer map mode and matching legacy
    # metadata-mode value; they do not switch to Low Latency transport.
    #
    my $calman_set_dv_rgb = sub {
     my ($dv_map_mode,$dv_metadata)=@_;
     my $dv_transport="standard";
     # Mark a DV transition in progress so $calman_enforce_mode_coherence
     # writes dv_status=1 (and the standard-transport DV flags) as a
     # daemon-derived update when is_hdr/eotf/primaries are saved below.
     # Without this, the GCI gate suppresses dv_status=1 and the conf
     # ends up as HDR10 instead of DV.
     $calman_dv_transition_active=1;
     $calman_save_setting->("signal_mode","dv");
     $calman_save_setting->("is_sdr","0");
     $calman_save_setting->("is_hdr","1");
     $calman_save_setting->("eotf","2");
     $calman_save_setting->("dv_transport",$dv_transport);
     $calman_save_setting->("is_ll_dovi",&pg_dv_transport_ll_flag($dv_transport));
     $calman_save_setting->("is_std_dovi",&pg_dv_transport_std_flag($dv_transport));
     $calman_save_setting->("dv_status","1");
     $calman_save_setting->("dv_interface",&pg_dv_transport_interface($dv_transport));
     $calman_save_setting->("dv_color_space","0");
	     $calman_save_setting->("color_format",&pg_dv_transport_color_format($dv_transport));
	     $calman_save_setting->("colorimetry","9");
	     $calman_save_setting->("primaries","1");
	     $calman_save_setting->("max_bpc",$calman_preferred_bpc->(&pg_dv_transport_max_bpc($dv_transport)));
	     $calman_save_setting->("rgb_quant_range",&pg_dv_transport_quant_range($dv_transport));
     if(!$calman_gci{$connection}) {
      $calman_rgb_quant_range=2;
      &apply_source_rgb_quant_range("calman",2);
     }
     $calman_save_setting->("dv_map_mode","$dv_map_mode") if(defined $dv_map_mode && $dv_map_mode ne "");
     if(!defined $dv_metadata || $dv_metadata eq "") {
      $dv_metadata=$calman_dv_metadata_for_map_mode->((defined $dv_map_mode && $dv_map_mode ne "") ? $dv_map_mode : $pgenerator_conf{"dv_map_mode"});
     }
     $calman_save_setting->("dv_metadata","$dv_metadata");
     # Always run mode coherence before clearing the transition
     # flag. calman_save_setting only triggers coherence when an
     # allow-listed key actually changes; under GCI, CONF_DV after
     # HDR_ENABLE often re-asserts is_hdr=1 / eotf=2 / primaries=1
     # as no-ops, so coherence never ran, the GCI gate kept
     # suppressing dv_status/signal_mode, and the conf stayed
     # HDR10 (dv_status=0, signal_mode=hdr10) even though Calman
     # asked for DV. Force the daemon-derived write while the
     # transition flag still tells coherence to set signal_mode=dv
     # and dv_status=1.
     $calman_enforce_mode_coherence->() if($calman_gci{$connection});
     # End of DV transition — clear the flag so subsequent non-DV
     # saves in the same connection fall back to the standard
     # dv_status=0 reset path.
     $calman_dv_transition_active=0;
    };

    my $calman_set_non_dv_mode = sub {
     my ($mode,$eotf_val,$colorimetry,$max_bpc)=@_;
	     $mode=lc($mode || "sdr");
	     $eotf_val=0 if(!defined $eotf_val || $eotf_val eq "");
	     $colorimetry=($eotf_val >= 2) ? "9" : "2" if(!defined $colorimetry || $colorimetry eq "");
	     $max_bpc=($eotf_val >= 2) ? "10" : "8" if(!defined $max_bpc || $max_bpc eq "");
	     $max_bpc=$calman_preferred_bpc->($max_bpc,$eotf_val >= 2);
	     # LLDV forces YCbCr 4:2:2; leaving DV must not keep it for SDR/HDR10.
	     my $dv_color_format=(int($pgenerator_conf{"dv_status"} || 0) == 1) ? &pg_dv_transport_color_format() : "0";
	     $calman_save_setting->("signal_mode",$mode);
     $calman_save_setting->("is_sdr",$eotf_val >= 2 ? "0" : "1");
     $calman_save_setting->("is_hdr",$eotf_val >= 2 ? "1" : "0");
     $calman_save_setting->("is_ll_dovi","0");
     $calman_save_setting->("is_std_dovi","0");
     $calman_save_setting->("dv_status","0");
     $calman_save_setting->("eotf","$eotf_val");
     $calman_save_setting->("colorimetry","$colorimetry");
     $calman_save_setting->("max_bpc","$max_bpc");
     $calman_save_setting->("primaries",$eotf_val >= 2 ? "1" : "0");
     if($dv_color_format ne "0" && ($pgenerator_conf{"color_format"} || "0") eq $dv_color_format) {
      &log("Calman: leaving Dolby Vision, color_format $dv_color_format from the DV transport reset to RGB");
      $calman_save_setting->("color_format","0");
     }
    };

    my $calman_handle_rpc_source_alias = sub {
     my ($rpc_type,$rpc_payload)=@_;
     return 0 if(!$rpc_client{$connection});
     my $alias=uc($rpc_type || "");
     $rpc_payload="" if(!defined $rpc_payload);
     if($alias eq "BITDEPTH" || $alias eq "BITS") {
      my $bpc=$calman_note_explicit_bpc->($rpc_payload);
      if($bpc ne "") {
       $calman_save_setting->("max_bpc","$bpc");
       $calman_apply->();
      }
      return 1;
     }
     if($alias eq "COLORSPACE" || $alias eq "COLOR_FORMAT" || $alias eq "FORMAT") {
      $calman_apply_source_payload->($rpc_payload,0);
      $calman_apply->();
      return 1;
     }
     if($alias eq "RANGE") {
      my %range_parsed=&calman_parse_source_format_payload("Range=$rpc_payload",0);
      if($range_parsed{range} eq "1" || $range_parsed{range} eq "2") {
       $calman_rgb_quant_range=$range_parsed{range} + 0;
       &log("Calman: external range set to $calman_rgb_quant_range via RPC RANGE");
       &apply_source_rgb_quant_range("calman",$calman_rgb_quant_range);
      } else {
       &log("Calman: releasing external range via RPC RANGE=$rpc_payload");
       &release_source_rgb_quant_range("calman");
       $calman_rgb_quant_range=0;
      }
      &calman_replay_last_pattern("RPC RANGE");
      return 1;
     }
     if($alias eq "CMD") {
      if($rpc_payload =~/^SET_PGENERATOR_CONF_MAX_BPC:(8|10|12)$/i) {
       my $bpc=$calman_note_explicit_bpc->($1);
       if($bpc ne "") {
        $calman_save_setting->("max_bpc","$bpc");
        $calman_apply->();
       }
       return 1;
      }
      if($rpc_payload =~/^SET_PGENERATOR_CONF_COLOR_FORMAT:([0-3])$/i) {
       $calman_save_setting->("color_format","$1");
       $calman_apply->();
       return 1;
      }
      if($rpc_payload =~/^SET_PGENERATOR_CONF_RGB_QUANT_RANGE:([012])$/i) {
       my $range_val=$1;
       $calman_save_setting->("rgb_quant_range","$range_val");
       if($calman_gci{$connection}) {
        &log("Calman GCI: RPC CMD rgb_quant_range ignored at runtime (WebUI owns it)");
       } elsif($range_val eq "1" || $range_val eq "2") {
        $calman_rgb_quant_range=$range_val + 0;
        &log("Calman: external range set to $calman_rgb_quant_range via RPC CMD");
        &apply_source_rgb_quant_range("calman",$calman_rgb_quant_range);
       } else {
        &log("Calman: releasing external range via RPC CMD");
        &release_source_rgb_quant_range("calman");
        $calman_rgb_quant_range=0;
       }
       &calman_replay_last_pattern("RPC CMD range");
       return 1;
      }
     }
     return 0;
    };

    # The G1 source is not offered GET_SETTINGS (see CAP). It starts the
    # connection at RGB 8-bit (its constructor default), sends only Range
    # Limited and sends CONF_LEVEL:Format only when the user changes the
    # colour format. Match that default on the first command so the
    # output agrees with what Calman shows.
    if($type ne "INIT" && delete $calman_g1_startup{$connection}) {
     &log("Calman G1: no GET_SETTINGS after the handshake, using Calman's start-up format RGB 8-bit");
     $calman_apply_source_payload->("RGB",1);
     $calman_apply->();
    }

    if($calman_handle_rpc_source_alias->($type,$pattern_cmd)) {
     &send_key_to_client($connection,"");
     last;
    }

      if($key =~/^\x02?SPECIALTY:([^\x02\x03]+)\x02CONF_LEVEL:Range\s+([^\x03]+)\x03?$/i) {
       my ($specialty,$range_val)=($1,$2);
       $specialty=~s/^\s+|\s+$//g;
       $range_val=~s/^\s+|\s+$//g;
       &log("Calman: split combined SPECIALTY=$specialty + CONF_LEVEL=Range $range_val");
       # rgb_quant_range is now in the GCI allow-list, so all
       # branches (GCI and non-GCI) take the same path: save
       # the conf and apply the source range.
       if($range_val =~/full/i) {
        $calman_rgb_quant_range=2;
        $calman_save_setting->("rgb_quant_range","$calman_rgb_quant_range");
        &apply_source_rgb_quant_range("calman",$calman_rgb_quant_range);
       } elsif($range_val =~/limit/i) {
        $calman_rgb_quant_range=1;
        $calman_save_setting->("rgb_quant_range","$calman_rgb_quant_range");
        &apply_source_rgb_quant_range("calman",$calman_rgb_quant_range);
       } else {
        &release_source_rgb_quant_range("calman");
        $calman_rgb_quant_range=0;
        $calman_save_setting->("rgb_quant_range",&webui_preferred_rgb_quant_range());
       }
       $calman_apply->(0) if(!$calman_gci{$connection});
       &calman_render_specialty_pattern($specialty);
       &calman_remember_pattern("SPECIALTY","SPECIALTY",$specialty);
       &send_key_to_client($connection,"");
      last;
     }

    #
    # HDR_ENABLE — external HDR toggle
    # HDR_ENABLE:True -> prepare for HDR (CONF_HDR follows with details)
    # HDR_ENABLE:False -> switch to SDR. A later CONF_DV command can re-enter DV.
    #
      if($type eq "HDR_ENABLE") {
       if($pattern_cmd =~/^False$/i) {
         &log("Calman: HDR_ENABLE=False — switching to SDR");
         # The G1 source sends HDR_ENABLE:False in every handshake, right
         # after GET_SETTINGS, and it carries no bit depth. Already in SDR
         # it must not reset the depth the WebUI set; leaving HDR or DV
         # still falls back to 8 bpc.
         my $sdr_bpc="8";
         if(int($pgenerator_conf{"dv_status"} || 0) != 1 && ($pgenerator_conf{"is_hdr"} || "0") ne "1") {
          my $cur_bpc=&calman_valid_bpc($pgenerator_conf{"max_bpc"});
          $sdr_bpc=$cur_bpc if($cur_bpc ne "");
         }
         $calman_set_non_dv_mode->("sdr",0,"2",$sdr_bpc);
         # Apply immediately — DRM properties must change now, not on next pattern
         $calman_apply->();
       }
       if($pattern_cmd =~/^True$/i) {
        &log("Calman: HDR_ENABLE=True — HDR requested, awaiting CONF_HDR");
        # Don't set HDR yet; CONF_HDR will follow with full metadata
        # But mark HDR intent so if no CONF_HDR comes, next pattern apply will enable HDR
        $calman_set_non_dv_mode->("hdr",2,"9","10");
        # Apply immediately so the TV gets the new HDR mode without
        # waiting for the next pattern. If CONF_HDR follows with
        # refined primaries/luminance, it will trigger a second apply
        # (idempotent, picks up the refined values).
        $calman_apply->();
       }
       &send_key_to_client($connection,"");
       last;
      }
     #
    # CONF_HDR — external full HDR metadata configuration
     # Format: CONF_HDR:EOTF,Rx,Ry,Gx,Gy,Bx,By,Wx,Wy,MinL,MaxL,MaxCLL,MaxFALL
     # EOTF: ST2084 | HLG | SDR
     # Primaries: CIE xy coordinates (matched to BT.2020/P3/BT.709)
     #
     if($type eq "CONF_HDR") {
      my @hdr_f=split(",",$pattern_cmd);
      my $hdr_eotf=$hdr_f[0];
      my $hdr_rx=$hdr_f[1]+0; my $hdr_ry=$hdr_f[2]+0;
      my $hdr_gx=$hdr_f[3]+0; my $hdr_gy=$hdr_f[4]+0;
      my $hdr_bx=$hdr_f[5]+0; my $hdr_by=$hdr_f[6]+0;
      my $hdr_wx=$hdr_f[7]+0; my $hdr_wy=$hdr_f[8]+0;
      my $hdr_min_luma_present=(defined($hdr_f[9]) && $hdr_f[9] ne "") ? 1 : 0;
      my $hdr_max_luma_present=(defined($hdr_f[10]) && $hdr_f[10] ne "") ? 1 : 0;
      my $hdr_max_cll_present=(defined($hdr_f[11]) && $hdr_f[11] ne "") ? 1 : 0;
      my $hdr_max_fall_present=(defined($hdr_f[12]) && $hdr_f[12] ne "") ? 1 : 0;
      my $hdr_min_luma=$hdr_min_luma_present ? $hdr_f[9]+0 : 0;
      my $hdr_max_luma=$hdr_max_luma_present ? int($hdr_f[10]) : 0;
      my $hdr_max_cll=$hdr_max_cll_present ? int($hdr_f[11]) : 0;
      # Last field is 5-digit zero-padded MaxFALL + gamma (e.g. "004002.2000" = 400 + γ2.2)
      my $hdr_max_fall=$hdr_max_fall_present ? int(substr($hdr_f[12],0,5)) : 0;
      # Map EOTF string
      my $eotf_val=2; # default PQ
      $eotf_val=0 if($hdr_eotf =~/^SDR$/i || $hdr_eotf =~/^Traditional$/i);
      $eotf_val=2 if($hdr_eotf =~/^ST2084$/i || $hdr_eotf =~/^PQ$/i);
      $eotf_val=3 if($hdr_eotf =~/^HLG$/i);
      $calman_save_setting->("eotf","$eotf_val");
      if($eotf_val >= 2) {
       $calman_set_non_dv_mode->($eotf_val == 3 ? "hlg" : "hdr",$eotf_val,"9","10");
      } else {
       $calman_set_non_dv_mode->("sdr",0,"2","8");
      }
      # Match primaries to known gamuts by checking Red x coordinate
      # BT.2020: Rx=0.708  P3: Rx=0.680  BT.709: Rx=0.640
      my $prim_val="1"; # default BT.2020
      if(abs($hdr_rx - 0.708) < 0.01) {
       $prim_val="1"; # BT.2020
       $calman_save_setting->("colorimetry","9");
      } elsif(abs($hdr_rx - 0.680) < 0.01) {
       $prim_val="2"; # DCI-P3/D65
       $calman_save_setting->("colorimetry","9");
      } else {
       $prim_val="0"; # BT.709 / custom
       $calman_save_setting->("colorimetry","2");
      }
      $calman_save_setting->("primaries","$prim_val");
	      # Set bit depth based on EOTF unless the reference sent or implied a source bit depth.
	      $calman_save_setting->("max_bpc",$calman_preferred_bpc->($eotf_val >= 2 ? "10" : "8",$eotf_val >= 2));
      # Luminance metadata
      $calman_save_setting->("min_luma","$hdr_min_luma") if($hdr_min_luma_present);
      $calman_save_setting->("max_luma","$hdr_max_luma") if($hdr_max_luma > 0);
      $calman_save_setting->("max_cll","$hdr_max_cll") if($hdr_max_cll_present);
      $calman_save_setting->("max_fall","$hdr_max_fall") if($hdr_max_fall_present);
      &log("Calman: CONF_HDR parsed — eotf=$eotf_val prim=$prim_val maxL=$hdr_max_luma minL=$hdr_min_luma maxCLL=$hdr_max_cll maxFALL=$hdr_max_fall");
      # Apply immediately so the renderer restarts with the new HDR
      # config and the wire colorimetry / HDR_OUTPUT_METADATA blob
      # update on the TV. Without this the conf would be correct and
      # the WebUI would show HDR, but the renderer (and therefore the
      # TV) would stay on the previous mode until the next pattern
      # command triggered a restart.
      $calman_apply->();
      &send_key_to_client($connection,"");
      last;
      }
     #
     # UPGCI Display Mode Commands
     #
     # DSMD — Display signal mode (SDR/HDR10/HLG/DolbyVision)
     # Composite command: sets multiple config keys and restarts immediately
     if($type eq "DSMD") {
     my $need_restart=0;
     if($pattern_cmd =~/^SDR$/i) {
       $calman_set_non_dv_mode->("sdr",0,"2","8");
       $need_restart=1;
      }
      if($pattern_cmd =~/^HDR10$/i) {
       $calman_set_non_dv_mode->("hdr",2,"9","10");
       $need_restart=1;
      }
      if($pattern_cmd =~/^HLG$/i) {
       $calman_set_non_dv_mode->("hlg",3,"9","10");
       $need_restart=1;
      }
      if($pattern_cmd =~/^DOLBYVISION$/i || $pattern_cmd =~/^DV$/i) {
       # Generic DV enable — preserve current map mode (Absolute/Relative).
       $calman_set_dv_rgb->("","1");
       $need_restart=1;
      }
      if($need_restart) {
       $calman_apply->();
      }
      &send_key_to_client($connection,"");
      last;
     }
     #
     # 21_HDR_MetadataMode — HDR Metadata Mode (from UPGCI SetControl)
     # 0=NoMetadata(SDR), 1=DV_RGB_Tunneling, 2=DV_Perceptual,
     # 3=DV_Absolute, 4=DV_Relative
     #
     if($type eq "21_HDR_MetadataMode") {
      my $mm_val=int($pattern_cmd);
      if($mm_val == 0) {
       # NoMetadata — SDR mode
       $calman_set_non_dv_mode->("sdr",0,"2","8");
	      } elsif($mm_val >= 1 && $mm_val <= 4) {
	       # Dolby Vision modes — drive both the renderer map mode and the reference's
	       # legacy metadata-mode bookkeeping.
	       if($mm_val == 2) {
	        $calman_set_dv_rgb->("0","2"); # Perceptual
	       } elsif($mm_val == 3) {
	        $calman_set_dv_rgb->("1","3"); # Absolute
	       } elsif($mm_val == 4) {
	        $calman_set_dv_rgb->("2","4"); # Relative
	       } else {
	        # 1=RGB tunneling. Preserve current map mode because transport mode is
	        # separate from the renderer's Perceptual/Absolute/Relative selector.
	        $calman_set_dv_rgb->("","$mm_val");
	        &log("Calman: 21_HDR_MetadataMode=$mm_val requested — preserving dv_map_mode=$pgenerator_conf{'dv_map_mode'}");
	       }
      }
        # This SetControl path is used for live DV mode changes, so apply
        # immediately rather than waiting for a later explicit update command.
        $calman_apply->();
      &send_key_to_client($connection,"");
      last;
     }
     #
     # EOTF / HDR_EOTF — Electro-Optical Transfer Function
     # 0=SDR gamma, 1=HDR gamma, 2=SMPTE ST.2084 (PQ), 3=HLG
     #
     if($type eq "EOTF" || $type eq "HDR_EOTF") {
      my $eotf_val=int($pattern_cmd);
      if($eotf_val >= 0 && $eotf_val <= 3) {
       $calman_save_setting->("eotf","$eotf_val");
       # PQ or HLG → enable HDR output so C binary sets HDR_OUTPUT_METADATA
       if($eotf_val >= 2) {
        $calman_set_non_dv_mode->($eotf_val == 3 ? "hlg" : "hdr",$eotf_val,"9","10");
       } else {
        $calman_set_non_dv_mode->("sdr",0,"2","8");
       }
       # Apply immediately so the renderer restarts with the new
       # EOTF and the wire updates. Same reasoning as CONF_HDR.
       $calman_apply->();
      }
      &send_key_to_client($connection,"");
      last;
     }
     #
     # PRIM / HDR_PRIMARIES — Mastering display primaries
     # PGenerator: 0=custom, 1=BT2020/D65, 2=P3/D65, 3=P3/DCI
    # The client sends: 0=P3, 1=BT709, 2=BT2020, or string names
     #
     if($type eq "PRIM" || $type eq "HDR_PRIMARIES") {
      my $prim_val=$pattern_cmd;
      # Map the client's numeric enum → PGenerator values
      if($pattern_cmd =~/^\d+$/) {
       my $calman_prim=int($pattern_cmd);
       $prim_val="0" if($calman_prim == 1);  # BT709 → custom/0
       $prim_val="1" if($calman_prim == 2);  # BT2020 → 1
       $prim_val="2" if($calman_prim == 0);  # P3 → 2
      }
      # Map string names
      $prim_val="0" if($pattern_cmd =~/^BT709$/i);
      $prim_val="1" if($pattern_cmd =~/^BT2020$/i);
      $prim_val="2" if($pattern_cmd =~/^P3$/i || $pattern_cmd =~/^DCI.?P3$/i);
      $calman_save_setting->("primaries","$prim_val");
      # Update colorimetry to match gamut (BT.709=2, BT.2020/P3=9)
      $calman_save_setting->("colorimetry",$prim_val eq "0" ? "2" : "9");
      &send_key_to_client($connection,"");
      last;
     }
     #
     # CLSP — Colorimetry / Color Space
     # PGenerator: 0=BT709, 1=BT2020
     #
     if($type eq "CLSP") {
      my $clsp_val="2";
      $clsp_val="9" if($pattern_cmd =~/^BT2020$/i || $pattern_cmd =~/^2020$/i);
      $calman_save_setting->("colorimetry","$clsp_val");
      &send_key_to_client($connection,"");
      last;
     }
     #
     # BITD — Bit depth per channel
     #
	     if($type eq "BITD") {
	      my $bitd_val=$calman_note_explicit_bpc->($pattern_cmd);
	      if($bitd_val ne "") {
	       $calman_save_setting->("max_bpc","$bitd_val");
	       $calman_apply->();
	      }
	      &send_key_to_client($connection,"");
	      last;
	     }
     #
     # COLF — Color Format (RGB, YCbCr444, YCbCr422, YCbCr420)
     # PGenerator: 0=RGB, 1=YCbCr444, 2=YCbCr422, 3=YCbCr420
     #
	     if($type eq "COLF") {
	      $calman_apply_source_payload->($pattern_cmd,0);
	      # Apply immediately — DRM output format must change now
	      $calman_apply->();
	      &send_key_to_client($connection,"");
      last;
     }
     #
     # QRNG — Quantization Range
     # PGenerator: 0=default, 1=limited, 2=full
     #
      if($type eq "QRNG") {
       my $qrng_val="0";
       $qrng_val="2" if($pattern_cmd =~/^FULL$/i);
       $qrng_val="1" if($pattern_cmd =~/^LIMITED$/i);
       # rgb_quant_range is now in the GCI allow-list, so all
       # branches take the same path: save the conf and apply
       # the source range. Previously the GCI branch rejected
       # the command and the WebUI would flip back to the stale
       # conf value on the next poll.
       if($qrng_val eq "1" || $qrng_val eq "2") {
        $calman_rgb_quant_range=$qrng_val + 0;
        &log("Calman: external range set to $calman_rgb_quant_range via QRNG");
        $calman_save_setting->("rgb_quant_range","$calman_rgb_quant_range");
        &apply_source_rgb_quant_range("calman",$calman_rgb_quant_range);
       } else {
        &log("Calman: releasing external range via QRNG=$pattern_cmd");
        &release_source_rgb_quant_range("calman");
        $calman_rgb_quant_range=0;
        $calman_save_setting->("rgb_quant_range",&webui_preferred_rgb_quant_range());
       }
      &calman_replay_last_pattern("QRNG");
      &send_key_to_client($connection,"");
      last;
     }
     #
     # MAXL / HDR_MAXL — Maximum mastering display luminance (nits)
     #
     if($type eq "MAXL" || $type eq "HDR_MAXL") {
      $calman_save_setting->("max_luma","$pattern_cmd");
      &send_key_to_client($connection,"");
      last;
     }
     #
     # MINL / HDR_MINL — Minimum mastering display luminance (nits)
     #
     if($type eq "MINL" || $type eq "HDR_MINL") {
      $calman_save_setting->("min_luma","$pattern_cmd");
      &send_key_to_client($connection,"");
      last;
     }
     #
     # MAXCLL / HDR_MAXCLL — Maximum content light level
     #
     if($type eq "MAXCLL" || $type eq "HDR_MAXCLL") {
      $calman_save_setting->("max_cll","$pattern_cmd");
      &send_key_to_client($connection,"");
      last;
     }
     #
     # MAXFALL / HDR_MAXFALL — Maximum frame-average light level
     #
     if($type eq "MAXFALL" || $type eq "HDR_MAXFALL") {
      $calman_save_setting->("max_fall","$pattern_cmd");
      &send_key_to_client($connection,"");
      last;
     }
     #
     # HDR_WHITEPOINT — White point (0=D65)
     # Stored for completeness; PGenerator always uses D65
     #
     if($type eq "HDR_WHITEPOINT") {
      &log("Calman: HDR_WHITEPOINT=$pattern_cmd (noted, PGenerator uses D65)");
      &send_key_to_client($connection,"");
      last;
     }
     #
     # SetRange — Video/PC quantization range (from UPGCI DispId 18)
     # 0=PC/Full (0-255), 1=Video (16-235)
     #
      if($type eq "SetRange") {
       my $range_val=int($pattern_cmd);
       if($range_val == 1) {
       $calman_rgb_quant_range=1;
       } else {
       $calman_rgb_quant_range=2;
       }
       # rgb_quant_range is now in the GCI allow-list, so all
       # branches (GCI and non-GCI) take the same path: save
       # the conf and apply the source range.
       &log("Calman: external range set to $calman_rgb_quant_range");
       $calman_save_setting->("rgb_quant_range","$calman_rgb_quant_range");
       &apply_source_rgb_quant_range("calman",$calman_rgb_quant_range);
       &calman_replay_last_pattern("SetRange");
      &send_key_to_client($connection,"");
      last;
     }
     #
     # 10_SIZE — Window size percentage (from UPGCI SetControl)
     #
     if($type eq "10_SIZE") {
      $calman_win_size=int($pattern_cmd);
      $calman_win_size=10 if($calman_win_size < 1);
      $calman_win_size=100 if($calman_win_size > 100);
      &log("Calman: window size set to $calman_win_size%");
      &calman_replay_last_pattern("10_SIZE");
      &send_key_to_client($connection,"");
      last;
     }
     #
     # 11_APL — Average Picture Level percentage
     # Stored and applied as a calculated background for windowed patterns
     #
     if($type eq "11_APL") {
      $calman_apl=$pattern_cmd + 0;
      $calman_apl=0 if($calman_apl < 0);
      $calman_apl=100 if($calman_apl > 100);
      $calman_apl_enabled=1;
      &log("Calman: APL target set to $calman_apl%");
      &calman_replay_last_pattern("11_APL");
      &send_key_to_client($connection,"");
      last;
     }
     #
     # 303_UPDATE / APPLY — Force apply pending settings now
     #
     if($type eq "303_UPDATE" || $type eq "APPLY") {
      my $applied=$calman_apply->();
      &calman_replay_last_pattern($type) if(!$applied);
      &send_key_to_client($connection,"");
      last;
     }
     #
     # CommandRGB — Direct RGB pattern (from UPGCI DispId 31)
     # Format: CommandRGB:R,G,B,tenBit,size
     #
     if($type eq "CommandRGB") {
      # Apply any pending settings before showing pattern
      $calman_apply->(0);
      last if(&signal_refuse_patch($connection,"Calman CommandRGB"));
      &calman_render_commandrgb_pattern($pattern_cmd,$connection);
      &calman_remember_pattern("CommandRGB",$type,$pattern_cmd);
      &send_key_to_client($connection,"");
      last;
     }
     #
    # RGB Pattern Commands (legacy external wire protocol)
    # RGB_B:R,G,B,BG  RGB_S:R,G,B,SIZE  RGB_A:R,G,B,BG_R,BG_G,BG_B,SIZE
    # The client sends 10-bit values (0-1023). Standard DV expands them to
    # 12-bit source codes while the renderer keeps the packed RGB tunnel at
    # BITS=8; other modes scale to their normal drawing precision.
     #
     if($type =~/RGB_/) {
      # Apply any pending display mode settings before showing pattern
      $calman_apply->(0);
      last if(&signal_refuse_patch($connection,"Calman $type"));
      &calman_render_rgb_pattern($type,$pattern_cmd,$key,$connection);
      &calman_remember_pattern("RGB",$type,$pattern_cmd);
      &send_key_to_client($connection,"");
      last;
     }
     #
     # CONF_FORMAT — Resolution/format configuration
     # Parses resolution string (e.g. "1080p60", "720p50") and switches
     # the HDMI output mode via modetest mode index
     #
	     if($type eq "CONF_FORMAT") {
	      my $fmt=$pattern_cmd;
	      $fmt=~s/^\s+|\s+$//g;
	      &log("Calman: CONF_FORMAT=$fmt");
	      $calman_apply_source_payload->($fmt,0);
	      # Parse resolution string: <height><p|i><rate> or WxH, with optional Hz/@ spacing.
	      my ($req_w,$req_h,$req_ip,$req_rate);
      my $explicit_rate=0;
      my $default_rate=60;
      my %std_w=(2160=>3840,1080=>1920,720=>1280,576=>720,480=>720);
      $default_rate=int($1 + 0) if($preferred_mode =~/\s([\d.]+)Hz/);
      if($fmt =~/Resolution\s*=\s*(\d+)\s*x\s*(\d+).*Refresh\s*=\s*([\d.]+)/i) {
       $req_w=int($1);
       $req_h=int($2);
       $req_ip="p";
       $req_rate=$3 + 0;
       $explicit_rate=1;
      } elsif($fmt =~/Resolution\s*=\s*(\d+)\s*([pi])?.*Refresh\s*=\s*([\d.]+)/i && exists $std_w{int($1)}) {
       $req_h=int($1);
       $req_ip=defined($2) && $2 ne "" ? lc($2) : "p";
       $req_rate=$3 + 0;
       $explicit_rate=1;
       $req_w=$std_w{$req_h};
      } elsif($fmt =~/^(\d+)\s*x\s*(\d+)\s*([pi])?\s*(?:@|\/|\s)*\s*([\d.]+)?\s*(?:Hz)?/i) {
       $req_w=int($1);
       $req_h=int($2);
       $req_ip=defined($3) && $3 ne "" ? lc($3) : "p";
       $req_rate=defined($4) && $4 ne "" ? $4 + 0 : $default_rate;
       $explicit_rate=1 if(defined($4) && $4 ne "");
      } elsif($fmt =~/^(\d+)\s*([pi])\s*(?:@|\/|\s)*\s*([\d.]+)?\s*(?:Hz)?/i) {
       $req_h=int($1);
       $req_ip=lc($2);
       $req_rate=defined($3) && $3 ne "" ? $3 + 0 : $default_rate;
       $explicit_rate=1 if(defined($3) && $3 ne "");
       # Standard TV widths for each height (prefer these over non-standard like 4096x2160)
       $req_w=$std_w{$req_h} if(exists $std_w{$req_h});
      } elsif($fmt =~/^(\d+)\s*(?:@|\/|\s)*\s*([\d.]+)?\s*(?:Hz)?$/i && exists $std_w{int($1)}) {
       $req_h=int($1);
       $req_ip="p";
       $req_rate=defined($2) && $2 ne "" ? $2 + 0 : $default_rate;
       $explicit_rate=1 if(defined($2) && $2 ne "");
       $req_w=$std_w{$req_h};
      }
      if($req_h && !$explicit_rate && $req_h <= 1080) {
       $req_rate=60;
      }
      &log("Calman: CONF_FORMAT parsed width=".($req_w||"")." height=".($req_h||"")." scan=".($req_ip||"")." rate=".($req_rate||"")) if($req_h);
      if($req_h && $req_rate) {
       my $best_idx=&calman_find_mode_idx($req_w,$req_h,$req_ip,$req_rate);
      if($best_idx >= 0) {
       &log("Calman: CONF_FORMAT matched mode_idx=$best_idx for ${req_h}${req_ip}${req_rate}");
       &pgenerator_cmd("SET_MODE:$best_idx");
       &sudo("SET_PGENERATOR_CONF","calman_mode_idx","$best_idx");
       $pgenerator_conf{"calman_mode_idx"}="$best_idx";
       &log("Calman: remembered CONF_FORMAT mode_idx=$best_idx");
       # Update cached resolution
       &get_hdmi_info();
       } else {
        &log("Calman: CONF_FORMAT no matching mode for ${req_h}${req_ip}${req_rate}");
       }
      } else {
       &log("Calman: CONF_FORMAT unrecognized format: $fmt");
      }
	      $calman_apply->(0);
	      &calman_replay_last_pattern("CONF_FORMAT");
	      &send_key_to_client($connection,"");
	      last;
	     }
     #
     # CONF_LEVEL — Level/gamma/range/bitdepth configuration
     # Handles: "Bits N", "Range X", "Format X", "Gamma-HDR", "Gamma-SDR"
     #
	     if($type eq "CONF_LEVEL") {
	      my $cl=$pattern_cmd;
	      $cl=~s/^\s+|\s+$//g;
	      if($cl =~/^Bits\s+(\d+)/i) {
	       my $bd=$calman_note_explicit_bpc->($1);
	       if($bd ne "") {
	        $calman_save_setting->("max_bpc","$bd");
	       }
	       # Apply immediately — DRM max_bpc must change now
	       $calman_apply->();
       } elsif($cl =~/^Range\s+(.*)/i && int($pgenerator_conf{"dv_status"} || 0) == 1) {
        # The DV transport sets the range (standard: full, LLDV: limited).
        # The G1 source sends "Range Full" before Dolby Vision and restores
        # its previous range after leaving it, so nothing is lost here.
        &log("Calman: CONF_LEVEL=$cl ignored while Dolby Vision is active (range ".($pgenerator_conf{"rgb_quant_range"} || "")." from the DV transport)");
       } elsif($cl =~/^Range\s+(.*)/i) {
        my $rv=lc($1);
        # rgb_quant_range is now in the GCI allow-list (see
        # $calman_save_setting), so all branches (GCI and
        # non-GCI) take the same path: save the conf key and
        # apply the source range. Previously the GCI branch
        # rejected the command and the WebUI would flip back
        # to the stale conf value on the next poll.
        if($rv =~/full/) {
        $calman_rgb_quant_range=2;
         &log("Calman: external range set to $calman_rgb_quant_range via CONF_LEVEL");
         $calman_save_setting->("rgb_quant_range","$calman_rgb_quant_range");
         &apply_source_rgb_quant_range("calman",$calman_rgb_quant_range);
         &calman_replay_last_pattern("CONF_LEVEL range");
        } elsif($rv =~/limit/) {
         $calman_rgb_quant_range=1;
         &log("Calman: external range set to $calman_rgb_quant_range via CONF_LEVEL");
         $calman_save_setting->("rgb_quant_range","$calman_rgb_quant_range");
         &apply_source_rgb_quant_range("calman",$calman_rgb_quant_range);
         &calman_replay_last_pattern("CONF_LEVEL range");
        } else {
        &log("Calman: releasing external range via CONF_LEVEL=$cl");
        &release_source_rgb_quant_range("calman");
        $calman_rgb_quant_range=0;
        &calman_replay_last_pattern("CONF_LEVEL range");
       }
	      } elsif($cl =~/^Format\s+((?:YCBCR|YCC|YUV)\s*420.*)/i) {
	       # Not supported (see calman_apply_source_payload, which logs it and
	       # leaves the WebUI notice). Answer with NAK so Calman itself
	       # reports the failed format change instead of assuming 4:2:0.
	       $calman_apply_source_payload->($1,1);
	       &log("Calman: CONF_LEVEL=$cl answered with NAK");
	       eval { $connection->send($nak_cmd_string); };
	       &close_connection($connection,"send error: $@") if($@);
	       last;
	      } elsif($cl =~/^Format\s+(.*)/i) {
	       $calman_apply_source_payload->($1,1);
	      # Apply immediately — DRM output format must change now
	      $calman_apply->();
     } elsif($cl =~/^Gamma-HDR$/i) {
       $calman_set_non_dv_mode->("hdr",2,"9","10");
     } elsif($cl =~/^Gamma-SDR$/i) {
       $calman_set_non_dv_mode->("sdr",0,"2","8");
      } else {
       &log("Calman: unknown CONF_LEVEL param: $cl");
      }
      &log("Calman: CONF_LEVEL=$cl");
      &send_key_to_client($connection,"");
      last;
     }
     #
     # CONF_DV — Dolby Vision mode configuration
     # PERCEPTUAL / ABSOLUTE / RELATIVE
      # Switches to DV binary and updates the renderer map mode
     #
     if($type eq "CONF_DV") {
      my $dv_mode=uc($pattern_cmd);
      $dv_mode=~s/^\s+|\s+$//g;
      &log("Calman: CONF_DV=$dv_mode");
      if($dv_mode eq "PERCEPTUAL" || $dv_mode eq "ABSOLUTE" || $dv_mode eq "RELATIVE") {
         # The renderer switches DV mapping via dv_map_mode:
         #   0 = Perceptual
         #   1 = Absolute
         #   2 = Relative
         # Keep dv_metadata aligned for clients that key off the legacy
         # reference metadata mode values:
         #   2 = Perceptual, 3 = Absolute, 4 = Relative
         if($dv_mode eq "PERCEPTUAL") {
          $calman_set_dv_rgb->("0","2");
         } elsif($dv_mode eq "ABSOLUTE") {
          $calman_set_dv_rgb->("1","3");
         } elsif($dv_mode eq "RELATIVE") {
          $calman_set_dv_rgb->("2","4");
         } else {
          $calman_set_dv_rgb->("","2");
         }
       # Apply immediately — must restart with DV binary
       $calman_apply->();
      } else {
       &log("Calman: CONF_DV unknown mode: $dv_mode");
      }
      &send_key_to_client($connection,"");
      last;
     }
     #
     # SPECIALTY — Specialty pattern display
     #
     if($type eq "SPECIALTY") {
      &log("Calman: SPECIALTY=$pattern_cmd");
      $calman_apply->(0);
      last if(&signal_refuse_patch($connection,"Calman SPECIALTY"));
      &calman_render_specialty_pattern($pattern_cmd);
      &calman_remember_pattern("SPECIALTY",$type,$pattern_cmd);
      &send_key_to_client($connection,"");
      last;
     }
     #
     # UPDATE — Force display refresh
     #
     if($type eq "UPDATE") {
      &log("Calman: UPDATE=$pattern_cmd (acknowledged)");
      &send_key_to_client($connection,"");
      last;
     }
     #
     # IMAGE — stored picture by name. The G1 source asks for its built-in
     # Skintones and Granger plates as IMAGE800.BMP / IMAGE801.BMP.
     #
     if($type eq "IMAGE") {
      my $g1_key=&g1_pattern_key($pattern_cmd);
      if(defined $g1_key) {
       &log("Calman: IMAGE=$pattern_cmd -> G1 $g1_key");
       $calman_apply->(0);
       last if(&signal_refuse_patch($connection,"Calman IMAGE"));
       &calman_render_specialty_pattern($pattern_cmd);
       &calman_remember_pattern("SPECIALTY",$type,$pattern_cmd);
      } else {
       &log("Calman: IMAGE=$pattern_cmd not available");
      }
      &send_key_to_client($connection,"");
      last;
     }
     # If we reach here, the command type was not handled by any specific block
     &log("Calman UNHANDLED command: type=$type cmd=$pattern_cmd");
     &send_key_to_client($connection,"");
     last;
    }
    #
    # RESTART PGENERATOR
    # RESTARTPGENERATOR
    #
    if($key=~/$restart_pgenerator_command:(.*)/) {
     # Port 85 clients set the signal keys first (CMD:SET_PGENERATOR_CONF_*)
     # and apply them with this restart; refused settings are put back and
     # the output stays as it was (signal_gate_conf). Settings that did not
     # change since the renderer started need no restart (ColourSpace sends
     # its unchanged settings and this restart on every connect).
     if(!$is_kms || &signal_gate_conf(&signal_source_label())) {
      &pattern_generator_restart_unless_current("RESTARTPGENERATOR");
      &send_key_to_client($connection,$ok_response);
     } else {
      &send_key_to_client($connection,"$error_response:Refused: ".&signal_patches_refused());
     }
     last;
    }
    #
    # KEEPALIVE
    # ISALIVE
    #
    if($key=~/$is_alive_command/) {
     &send_key_to_client($connection,$alive_response);
     last;
    }
    #
    # GET STATUS
    # GETSTATUS
    # GETSTATUS:CLIENTNAME=PerceptualPro is a side-effect-free identity form
    # that remains compatible with PGenerator 1.6. Its legacy matcher accepts
    # any command containing GETSTATUS and returns status without drawing.
    #
    if($key=~/$status_command/) {
     if($key=~/^\Q$status_command\E\s*[:;]\s*(.*)$/i) {
      &legacy_external_client_name_from_marker($connection,$1);
     }
     $response="$ok_response:$status";
     &send_key_to_client($connection,$response);
     last;
    }
    #
    # Optional classic-protocol client identity. This lets a port 85 client
    # advertise its product name in the WebUI status bar without changing
    # the behavior of clients that do not send an identity command.
    # CLIENTNAME:PerceptualPro (CLIENT_NAME/SOFTWARE and '=' are aliases).
    # Clients that must also support PGenerator 1.6 should use the extended
    # GETSTATUS form above because a standalone identity is unknown to 1.6.
    #
    if($key=~/^(?:CLIENTNAME|CLIENT_NAME|SOFTWARE)\s*[:=]\s*(.*)$/i) {
     my $software=&legacy_external_set_client_name($connection,$1);
     if($software eq "") {
      &send_key_to_client($connection,&error("invalid client name"));
     } else {
      &log("Pattern client identified: peer=".($client_ip{$connection} || "")." software=$software");
      &send_key_to_client($connection,$ok_response);
     }
     last;
    }
    #
    # PGenerator command
    # CMD:GET_CPU
    #
    if($key=~/$cmd_pgenerator_command:(.*)/) {
     @el_cmd=split(":",$1);
      if($el_cmd[0] eq "GET_RESOLUTION" || $el_cmd[0] eq "GET_GPU_MEMORY") {
       &legacy_external_mark_hcfr($connection);
      } elsif($el_cmd[0] eq "MULTIPLE") {
       foreach my $probe (@el_cmd[1..$#el_cmd]) {
        if($probe eq "GET_RESOLUTION" || $probe eq "GET_GPU_MEMORY") {
         &legacy_external_mark_hcfr($connection);
         last;
        }
       }
      }
     if($el_cmd[0] eq "MULTIPLE") {
      $response_tmp="\n";
      shift(@el_cmd);
      for(@el_cmd) {
       chomp($_);
       $response_tmp.="$_:".&pgenerator_cmd($_)."\n";
      }
     } else {
      $response_tmp=&pgenerator_cmd($1);
     }
     chomp($response_tmp);
     $response="$ok_response:".$response_tmp;
     &send_key_to_client($connection,$response);
     last;
    }
    #
    # STATS
    #
    if($key =~/STATS/) {
     my $type_cmd="READ";
     $type_cmd="RESET" if($key =~/STATSRESET/);
     $stat_content=&stats($type_cmd);
     &send_key_to_client($connection,"$ok_response:$stat_content");
     last;
    }
    #
    # Get File List
    # GETFILELIST:VIDEO
    #
    if($key=~/$get_file_list_command:(.*)/) {
     my $f_where=$1;
     my $dir_file=&get_destination($f_where);
     if($dir_file eq "") {
      &send_key_to_client($connection,&error());
      last;
     }
     $response="$ok_response:".&get_file_list($dir_file);
     &send_key_to_client($connection,$response);
     last;
    }
    #
    # DELETE:VIDEO:FileName
    #
    if($key=~/^$delete_file_command:(.*)/) {
     my $response_to_send=$ok_response;
     ($f_where,$f_name)=split(":",$1);
     my $dir_file=&get_destination($f_where);
     my $safe_name=&safe_file_name($f_name);
     if($dir_file eq "" || $safe_name eq "") {
      &send_key_to_client($connection,&error());
      last;
     }
     $response_to_send=&sudo("SET_PLUGIN","$dir_file/$safe_name",$plugin_archive_file,$f_where,"uninstall.sh") if($f_where eq "PLUGINS");
     unlink("$dir_file/$safe_name");
     &send_key_to_client($connection,$response_to_send);
     last;
    }
    # VIDEO COMMAND
    # PLAYER;VIDEO;DURATION
    # VIDEO=omxplayer.bin;PuliziaPlasma/effettoneve_med_barre_scorr_30fps_2min.mp4;5s
    #
    if($key=~/$video_command=(.*)/) {
     $command_found=1;
     my ($program,$video,$duration)=split($separator,$1);
     $log_string="Received video request command";
     $log_string.=" ($key)" if($key ne "");
     &log($log_string);
     &play_video($program,$video,$duration);
     &send_key_to_client($connection,$ok_response);
     last;
    }
    #
    # SAVEIMAGES PATTERN
    # SAVEIMAGES:NOME:
    #
    if($key=~/$save_images_command:(.*):/) {
     &save_images_pattern($1,"$pattern_frames/");
     &send_key_to_client($connection,$ok_response);
     last;
    }
    #
    # GETPATTERNIMAGE:
    # GETPATTERNIMAGE
    #
    if($key=~/$get_pattern_image_command:(.*)/) {
     $response=&get_pattern_image("$pattern_frames/",$1);
     &send_key_to_client($connection,$response);
     last;
    }
    #
    # GET PATTERNIMAGES LIST
    # GETPATTERNIMAGESLIST:
    #
    if($key=~/$get_patternimages_list_command:(.*)/) {
     $response="$ok_response:".&get_patternimages_list($1);
     &send_key_to_client($connection,$response);
     last;
    }
    #
    # TEST TEMPLATE COMMAND
    # es. DeviceControl Pattern Default Template
    # TESTTEMPLATE:Pattern
    #
    if($key=~/($test_template_command.*):(.*):(.*)/) {
      my $payload=$3;
      my $source_range="";
     if($2 eq "HCFR") {
      &legacy_external_mark_hcfr($connection);
      $source_range=&legacy_external_hcfr_source_range($payload);
     } else {
      &legacy_external_set_status($connection,"DeviceControl");
     }
      my $source_max=0;
      if($2 eq "HCFR") {
       ($payload,$source_max)=&legacy_external_prepare_hcfr_dv_template_payload($payload);
      } else {
       ($payload,$source_max)=&legacy_external_prepare_dv_template_payload($payload);
      }
      $response=&get_pattern($1,$2,$payload,"TESTTEMPLATE:$2",$source_range,$source_max);
     &send_key_to_client($connection,$response);
     &clean_pattern_files();
     last;
    }
    #
    # TEST PATTERN COMMAND
    # es. DeviceControl Pattern Simple Template
    # TESTPATTERN:Pattern:DRAW:RESOLUTION:DIM1,DIM2:RED,GREEN,BLUE:
    #
    if($key=~/$test_pattern_command:(.*):(.*):(.*):(.*):(.*):/) {
      my $draw=$2;
      my $rgb=$5;
      my $source_range="";
      if($hcfr_client{$connection}) {
       &legacy_external_set_status($connection,"HCFR");
       $draw=&legacy_external_hcfr_draw($draw);
       $source_range=&legacy_external_hcfr_source_range($5);
      } else {
       &legacy_external_set_status($connection,"DeviceControl");
      }
      my $source_max=0;
      my $unused_bg;
      ($draw,$rgb,$unused_bg,$source_max)=&legacy_external_prepare_dv_pattern($draw,$rgb,undef,undef);
     $pname_file=$1;
     &clean_pattern_files();
      $response="$ok_response:".&create_pattern_file($draw,$3,$4,$rgb,"","","","",1,"TESTPATTERN",$source_range,$source_max);
     &send_key_to_client($connection,$response);
     last;
    }
    #
    # GET CONF
    # GETCONF:CALIBRATION:DIMENSIONS
    #
    if($key=~/$get_conf_command:(.*):(.*)/) {
     $response="$ok_response:".&get_conf_pattern($1,$2);
     &send_key_to_client($connection,$response);
     last;
    }
    #
    # SET CONF
    # SETCONF:CALIBRATION:DIMENSIONS:VAL
    #
    if($key=~/$set_conf_command:(.*):(.*):(.*)/sm) {
     @el=split(":",$key,4); 
      &legacy_external_mark_hcfr($connection) if($el[1] eq "HCFR");
     &set_conf_pattern($el[1],$el[2],$el[3]);
     &send_key_to_client($connection,$ok_response);
     last;
    }
    #
    # FUNCTIONS COMMAND
    # DRAW;DIMENSIONS;RESOLUTION;FUNCTIONS
    # FUNCTIONS=RECTANGLE;500,500;0;GREY10
    #
    if($key=~/$functions_command=(.*)/) {
      if($hcfr_client{$connection}) {
       &legacy_external_set_status($connection,"HCFR");
      } else {
       &legacy_external_set_status($connection,"DeviceControl");
      }
     $command_found=1;
     last if(&signal_refuse_patch($connection,"Pattern FUNCTIONS"));
     my ($draw,$dim,$res,$functions)=split($separator,$1);
     $log_string="Received rgb triplet request command";
     $log_string.=" ($key)" if($key ne "");
     &log($log_string);
     &execute_functions($draw,$dim,$res,$functions.'.'.server);
     &send_key_to_client($connection,$ok_response);
     last;
    }
    #
    # RGB TRIPLET COMMAND
    # DRAW;DIMENSIONS;RESOLUTION;RGB;BACKGROUND;POSITION;TEXT
    # RGB=RECTANGLE;500,500;0;235,235,235;16,16,16;50,50;Testo
    #
    if($key=~/$rgb_triplet_command=(.*)/) {
      my ($draw,$dim,$res,$rgb,$bg,$position,$text)=split($separator,$1);
      my $hcfr_marker_only=&legacy_external_detect_hcfr_rgb($draw,$text);
      my $hcfr_marker_text=($hcfr_marker_only && uc($draw || "") eq "TEXT") ? 1 : 0;
      my $source_range="";
      &legacy_external_mark_hcfr($connection) if($hcfr_marker_only);
      if($hcfr_client{$connection}) {
       &legacy_external_set_status($connection,"HCFR");
       $draw=&legacy_external_hcfr_draw($draw);
       $source_range=&legacy_external_hcfr_source_range("$rgb;$bg") if(!$hcfr_marker_only);
      } else {
       &legacy_external_set_status($connection,"DeviceControl");
      }
      my $source_max=0;
      ($draw,$rgb,$bg,$source_max)=&legacy_external_prepare_dv_pattern($draw,$rgb,$bg,undef);
     $command_found=1;
     if($hcfr_marker_text) {
      $log_string="Received hcfr marker text command";
      $log_string.=" ($key)" if($key ne "");
      &log($log_string);
      &send_key_to_client($connection,$ok_response);
      last;
     }
     last if(&signal_refuse_patch($connection,"Pattern RGB"));
     &clean_pattern_files();
     $log_string="Received rgb triplet request command";
     $log_string.=" ($key)" if($key ne "");
     &log($log_string);
    &create_pattern_file($draw,"$dim",$res,"$rgb","$bg","$position","$text","",1,"RGB",$source_range,$source_max);
     &send_key_to_client($connection,$ok_response);
     last;
    }
    #
    # CHECK PROCESS
    # PGERNATORISEXECUTED
    #
    if($key=~/$pgenerator_executed_command:(.*)/) {
     $response=&pgenerator_is_executed();
     &send_key_to_client($connection,$response);
     last;
    }
    #
    # Default ERROR
    #
    &send_key_to_client($connection,&error());
   }
  }
 }
}

###############################################
#          Daemon Socket Function             #
###############################################
sub create_socket_daemon (@) {
 my $socket_id=shift;
 my $ip=shift;
 my $port=shift;
 my $text='';

 my $server = new IO::Socket::INET (
  LocalHost => $ip,
  LocalPort => $port,
  Proto     => 'tcp',
  Listen    => $listen_queue_size,
  ReuseAddr => 1,
  Timeout   => $timeout_server
 ) || &fatal_error("Error binding to $ip:$port");

 $text="Pattern Generator";
 return $server;
}

# Text from a client or a file name inside the port 85 image list page.
sub pattern_html_escape (@) {
 my $s=shift;
 $s="" if(!defined $s);
 $s=~s/&/&amp;/g;
 $s=~s/</&lt;/g;
 $s=~s/>/&gt;/g;
 $s=~s/"/&quot;/g;
 $s=~s/'/&#39;/g;
 return $s;
}

###############################################
#          Send Key To Client function        #
###############################################
sub send_key_to_client (@) {
 my $connection = shift;
 my $response = shift;
 $response.=$end_cmd_string;
 $response=$ack_cmd_string if($calman{$connection});
 # The command just handled had its settings refused (signal_gate_conf):
 # UPGCI treats any reply but ACK as a failed command, so Calman learns
 # that the change did not happen. Port 85 replies carry the error text.
 if($signal_refused_pending) {
  $signal_refused_pending=0;
  $response=$nak_cmd_string if($calman{$connection});
 }
 eval { $connection->send("$response"); };
 if($@) {
  my $send_error="$@";
  $send_error=~s/\s+$//;
  &close_connection($connection,"send error: $send_error");
 }
}

# Patches while a refused state is active (signal_gate_conf): Calman gets
# NAK, a port 85 client an error, so neither measures an output it did not
# choose. Returns 1 when the patch was refused (the caller stops there).
sub signal_refuse_patch (@) {
 my ($connection,$what)=@_;
 my $reason=&signal_patches_refused();
 return 0 if($reason eq "");
 &log("Signal: $what refused, settings are refused: $reason");
 $signal_refused_pending=0;
 if($calman{$connection}) {
  eval { $connection->send($nak_cmd_string); };
  &close_connection($connection,"send error: $@") if($@);
 } else {
  &send_key_to_client($connection,"$error_response:Refused: $reason");
 }
 return 1;
}

###############################################
#        Send Reference Payload To Client     #
###############################################
sub send_calman_payload_to_client (@) {
 my $connection = shift;
 my $response = shift;
 my $framed = shift || 0;
 $response="" if(!defined($response));
 # UPGCI replies are ACK + payload + ETX. Calman only reads a payload whose
 # first byte is ACK, and it reads each reply with a single recv(), so the
 # whole reply goes out in one write.
 # On the RPC port (Calman's G1 source) only the replies passed with
 # $framed are framed: CAP and GET_SETTINGS. SN, FIRMWARE and STATUS stay
 # bare there, as they always were. With an SN stored, the G1 source switches to its
 # obfuscated "CryptoII" transport, which PGenerator+ does not speak.
 $response=$ack_cmd_string.$response.$end_cmd_string_calman if(!$rpc_client{$connection} || $framed);
 eval { $connection->send("$response"); };
 if($@) {
  my $send_error="$@";
  $send_error=~s/\s+$//;
  &close_connection($connection,"send error: $send_error");
 }
}

###############################################
#          Close Connection function          #
###############################################
sub close_connection {
 my $connection = shift;
 my $reason = shift || "";
 return if(!$connection);
 $reason=~s/\s+$//;
 my $conn_ip=$client_ip{$connection} || "";
 my $socket_kind=delete $pattern_socket_kind{$connection};
 my $pitpg=delete $pitpg_conn{$connection};
 delete $pitpg_checked{$connection};
 $socket_kind="pitpg" if($pitpg);
 $socket_kind="rpc" if($socket_kind eq "" && $rpc_client{$connection});
 $socket_kind="calman" if($socket_kind eq "" && $calman{$connection});
 $socket_kind="classic" if($socket_kind eq "");
 &log("Pattern socket close: type=$socket_kind peer=$conn_ip reason=$reason") if($reason ne "");
 my $is_hcfr=delete $hcfr_client{$connection};
 delete $legacy_external_client_name{$connection};
 my $session_software=$calibration_session{$connection} ? ($calibration_session{$connection}->{software} || "") : "";
 my $had_session=&calibration_session_close($connection,$reason);
 if($calman{$connection} || $had_session) {
  &log("Calman: socket disconnected, preserving pattern state") if($calman{$connection});
  # A refusal belongs to the socket of the program that asked: a probe or
  # a second program closing leaves it in place.
  my $owner=&signal_refused_owner();
  &signal_refused_clear(($session_software || "calibration software")." disconnected")
   if($owner eq "$connection" || ($owner eq "" && $had_session));
 }
 &release_source_rgb_quant_range("hcfr") if($is_hcfr);
 &pitpg_closed($connection,$pitpg) if($pitpg);
 $calman{$connection}=0;
 $cmd{$connection}="";
 delete $pending_cmd{$connection};
 delete $client_ip{$connection};
 delete $hcfr_client_quant_range{$connection};
 delete $rpc_client{$connection};
 delete $calman_g1_startup{$connection};
 &calman_clear_gci_connection($connection);
 &upload_abort($connection);
 #$connection->send("");
 $select->remove($connection);
 eval { $connection->close(); };
}

# Drop the upload a connection left unfinished, and its temp file.
sub upload_abort (@) {
 my $connection = shift;
 my $upload = delete $upload_state{$connection};
 unlink($upload->{tmp}) if($upload && $upload->{tmp} ne "" && -f $upload->{tmp});
}

# Drop a refused upload but remember it, and the start value of its first
# chunk, until its END_UPLOAD: the chunks still on their way are refused
# too instead of starting a new file. Without a running upload the refused
# chunk is the first one.
sub upload_fail (@) {
 my ($connection,$where,$name,$status,$start) = @_;
 my $running = $upload_state{$connection};
 my $first = ($running && defined $running->{first}) ? $running->{first} : ($start // "");
 &upload_abort($connection);
 $upload_state{$connection}={failed=>1,tmp=>"",where=>$where,name=>$name,first=>$first} if($status ne "END_UPLOAD");
}

###############################################
#                Error function               #
###############################################
sub error(@) {
 my $error_message = shift;
 $error_message=$error_response if($error_message eq "");
 &stats("errors",1);
 return $error_message;
}
# Leave a notice for the WebUI (see $webui_notice_file). Written to a temp
# file and renamed so /api/stats never reads half a notice.
sub webui_notice (@) {
 my ($title,$text)=@_;
 my $tmp="$webui_notice_file.tmp";
 if(open(my $fh,">",$tmp)) {
  print $fh time()."-$$-".int(rand(1000000))."\n$title\n$text\n";
  close($fh);
  rename($tmp,$webui_notice_file) or &log("WebUI notice: rename failed: $!");
 } else {
  &log("WebUI notice: cannot write $tmp: $!");
 }
}

return 1;
