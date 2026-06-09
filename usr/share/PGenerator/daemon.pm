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
  &pattern_generator_start();
  threads->create(\&device_info)->detach();
  threads->create(\&discovery_devicecontrol)->detach();
  threads->create(\&discovery_lightspace)->detach();
  threads->create(\&discovery_rpc)->detach();
  threads->create(\&resolve_connection_thread)->detach();
  threads->create(\&webui_http)->detach();
  threads->create(\&webui_mdns)->detach();
  &pattern_daemon();
  exit;
 }
}

###############################################
#            Calman APL Helpers               #
###############################################
sub calman_apl_levels (@) {
 my $bits=int($bits_default || 8);
 my $full_max=(1 << $bits) - 1;
 my $shift=$bits - 8;
 my $range_mode=int($pgenerator_conf{"rgb_quant_range"} || 0);
 my $limited_min=16 << $shift;
 my $limited_span=219 << $shift;
 return ($limited_min,$limited_span,$limited_min + $limited_span,"limited") if($range_mode == 1);
 return (0,$full_max,$full_max,"full");
}

sub calman_target_max (@) {
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
  return $value >> ($src_bits - $dst_bits) if($dst_bits < $src_bits);
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
 return $calman_bg if(!$calman_apl_enabled);
 return &calman_apl_bg_value($rgb,$win_pct,$calman_apl,$source,$calman_bg);
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
 my $bg_str="0,0,0";
 if($size_token >= 1 && $size_token <= 100) {
  $win_pct=$size_token;
  &log("Calman: $source direct window token=$size_token -> size=$win_pct apl=0");
  return ($win_pct,$bg_str);
 }
 if($size_token >= 101 && $size_token <= 998) {
  $win_pct=10;
  $apl_pct=$size_token - 100;
  $bg_str=&calman_apl_bg_value($rgb,$win_pct,$apl_pct,"$source preset","0,0,0");
  &log("Calman: $source preset APL token=$size_token -> size=$win_pct apl=$apl_pct");
  return ($win_pct,$bg_str);
 }
 if($size_token == 999) {
  $win_pct=$calman_win_size if($calman_win_size > 0);
  $win_pct=10 if($win_pct < 1);
  $win_pct=100 if($win_pct > 100);
  $apl_pct=$calman_apl + 0;
  $bg_str=&calman_apl_bg_value($rgb,$win_pct,$apl_pct,"$source custom","0,0,0");
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
 $calman_bg="0,0,0";
 $calman_win_size=10;
 $calman_explicit_max_bpc=0;
 $calman_rgb_quant_range=($pgenerator_conf{"rgb_quant_range"}||"2") + 0;
 &calman_clear_last_pattern();
 &log("Calman: reset pattern state ($source)") if($source ne "");
}

sub calman_find_mode_idx (@) {
 my ($req_w,$req_h,$req_ip,$req_rate)=@_;
 return -1 if(!$req_h || !$req_rate);
 $req_ip=defined($req_ip) && $req_ip ne "" ? lc($req_ip) : "p";
 my $best_idx=-1;
 my $best_score=0;
 open(my $mt_fh,"$modetest 2>/dev/null|");
 my $mt_connected=0;
 while(my $ml=<$mt_fh>) {
  $mt_connected=1 if($ml =~/\s+connected/);
  next if(!$mt_connected);
  next if($ml !~/^\s*#(\d+)\s+(\d+)x(\d+)(i?)\s+([\d.]+)\s+.*type:\s*(.*)/);
  my ($m_idx,$m_w,$m_h,$m_i,$m_rate,$m_type)=($1,int($2),int($3),$4,$5,$6);
  next if($m_h != $req_h);
  my $m_ip=($m_i eq "i") ? "i" : "p";
  next if($m_ip ne $req_ip);
  my $m_rate_num=$m_rate + 0;
  my $rate_match=(int($m_rate_num) == int($req_rate)) || (abs($m_rate_num - ($req_rate + 0)) < 0.25);
  next if(!$rate_match);
  my $score=0;
  $score+=100 if($req_w && $m_w == $req_w);
  $score+=10  if($m_type =~/userdef/);
  $score+=5   if($m_type =~/preferred/);
  $score+=1;
  if($score > $best_score) {
   $best_idx=$m_idx;
   $best_score=$score;
  }
 }
 close($mt_fh);
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
 if(($pgenerator_conf{"mode_idx"} || "") ne $init_mode_idx) {
  &log("Calman: INIT applying remembered mode_idx=$init_mode_idx");
  &pgenerator_cmd("SET_MODE:$init_mode_idx");
 }
}

sub calman_pattern_source_range (@) {
 return "LIMITED" if($calman_rgb_quant_range == 1);
 return "";
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
 my $input_max=$cr_tenBit ? 1023 : 255;
 my $cr_r=&calman_scale_value($cr_r_in,$input_max);
 my $cr_g=&calman_scale_value($cr_g_in,$input_max);
 my $cr_b=&calman_scale_value($cr_b_in,$input_max);
 my ($cr_size_effective,$cr_bg)=&calman_commandrgb_window("$cr_r,$cr_g,$cr_b",$cr_size,"CommandRGB");
 my $cr_rgb="$cr_r,$cr_g,$cr_b";
 &apply_source_rgb_quant_range("calman",$calman_rgb_quant_range);
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
  &create_pattern_file("RECTANGLE","$w_s,$h_s",100,"$cr_rgb","$cr_bg","","","",1,"calman",$cr_source_range);
 } else {
  my $sqrt_val=sqrt($cr_size_effective/100);
  my $win_w=int($sqrt_val*$max_x);
  my $win_h=int($sqrt_val*$max_y);
  &create_pattern_file("RECTANGLE","$win_w,$win_h",100,"$cr_rgb","$cr_bg","$position_default","","",1,"calman",$cr_source_range);
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
 my $rgb_raw="$el_cmd[0],$el_cmd[1],$el_cmd[2]";
 &log("Calman PATTERN: type=$type raw=$rgb_raw bits_default=$bits_default target_max=$target_max");
 my $r=&calman_scale_value($el_cmd[0],$calman_max);
 my $g=&calman_scale_value($el_cmd[1],$calman_max);
 my $b=&calman_scale_value($el_cmd[2],$calman_max);
 my $patch_context=&calman_patch_context();
 &log("Calman PATTERN: scaled=$r,$g,$b bg=$calman_bg max_bpc=$pgenerator_conf{'max_bpc'} $patch_context");
 &log_calman_patch(type=>$type,
                   raw=>$rgb_raw,
                   scaled=>"$r,$g,$b",
                   win=>$calman_win_size,
                   bg=>$calman_bg,
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
  &get_pattern($test_template_command,$pattern_dynamic,"$r,$g,$b;$calman_bg","calman",$source_range);
  return 1;
 }
 if($type =~/RGB_S/) {
  my $win_pct=int($el_cmd[3]);
  $win_pct=$calman_win_size if($win_pct < 1);
  $win_pct=100 if($win_pct > 100);
  $calman_win_size=$win_pct if($win_pct > 0);
  my $effective_bg=$calman_bg;
  &log("Calman: RGB_S direct window size=$win_pct% bg=$effective_bg");
  if($win_pct >= 100) {
   $pname_file="FullField";
   &clean_pattern_files();
   &create_pattern_file("RECTANGLE","$w_s,$h_s",100,"$r,$g,$b","$effective_bg","","","",1,"calman",$source_range);
   return 1;
  }
  my $sqrt_val=sqrt($win_pct/100);
  my $win_w=int($sqrt_val*$max_x);
  my $win_h=int($sqrt_val*$max_y);
  &clean_pattern_files();
  &create_pattern_file("RECTANGLE","$win_w,$win_h",100,"$r,$g,$b","$effective_bg","$position_default","","",1,"calman",$source_range);
  return 1;
 }
 if($type =~/RGB_A/) {
  my $win_pct=$calman_win_size;
  my $effective_bg=$calman_bg;
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
   &create_pattern_file("RECTANGLE","$w_s,$h_s",100,"$r,$g,$b","$effective_bg","","","",1,"calman",$source_range);
   return 1;
  }
  my $sqrt_val=sqrt($win_pct/100);
  my $win_w=int($sqrt_val*$max_x);
  my $win_h=int($sqrt_val*$max_y);
  &clean_pattern_files();
  &create_pattern_file("RECTANGLE","$win_w,$win_h",100,"$r,$g,$b","$effective_bg","$position_default","","",1,"calman",$source_range);
  return 1;
 }
 my $effective_bg=&calman_apl_bg("$r,$g,$b",$calman_win_size,$type);
 &clean_pattern_files();
 &get_pattern($test_template_command,$pattern_dynamic,"$r,$g,$b;$effective_bg","calman",$source_range);
 return 1;
}

sub calman_render_specialty_pattern (@) {
 my $pattern_cmd=shift;
 my $sp_name=uc($pattern_cmd);
 $sp_name=~s/^\s+|\s+$//g;
 &clean_pattern_files();
 my $source_range=&calman_pattern_source_range();
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
   &create_pattern_file("RECTANGLE","$w_s,$h_s",100,"$black_rgb","$calman_bg","","","",1,"calman",$source_range);
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
   &create_pattern_file("RECTANGLE","$w_s,$h_s",100,"$white_rgb","$calman_bg","","","",1,"calman",$source_range);
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
   &create_pattern_file("RECTANGLE","$w_s,$h_s",100,"$gray128_rgb","$calman_bg","","","",1,"calman",$source_range);
  }
 } else {
  &log("Calman: unknown specialty pattern: $sp_name");
  &create_pattern_file("RECTANGLE","$w_s,$h_s",100,"$gray128_rgb","$calman_bg","","","",1,"calman",$source_range);
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
 $calibration_client_ip=$client_ip{$connection} || $client_address;
 $calibration_client_software=$software;
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
  my @ready = $select->can_read(5);
  next if(!@ready);
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
    my $rv=$connection->recv($key,1024);
    if(!defined $rv) {
     my $recv_error="$!";
     my $recv_timeout=($!{EAGAIN} || $!{EWOULDBLOCK} || $recv_error=~/timed out|temporarily unavailable|would block/i) ? 1 : 0;
     if($recv_timeout && ($pattern_socket_kind{$connection} || "") eq "classic") {
      next;
     }
     my $close_reason=$recv_timeout ? "recv timeout" : "recv error: $recv_error";
     &close_connection($connection,$close_reason);
     last;
    }
    #&stats("bytes",length($key));
    #
    # variables initialization
    #
    $scaling_done=0;
    #
    # Calman Unified Pattern Generator Control Interface Init Request
    # INIT:1.2
    #
    $calman{$connection}=0;
    if($key =~/$end_cmd_string_calman$/ || $rpc_client{$connection}) {
     $calman{$connection}=1;
     $calibration_client_ip=$client_ip{$connection} || $client_address;
     $calibration_client_software="Calman";
    }
    #
    # GET HTML IMAGE LIST
    # GET /frames/index.html HTTP/1.1
    #
    if($key =~/GET \/(.*)\/index.html /) {
     my (@dir_parts,$html_image_list_disabled,$dir_el)=(split("/",uri_unescape($1)),0,"");
     for(@dir_parts) {
       $dir_el.="$_/";
       $html_image_list_disabled=1 if(-f "$var_dir/$dir_el/HTMLIMAGELIST.disabled");
     }
     if($html_image_list_disabled) {
      &send_key_to_client($connection,"HTTP/1.0 404 Not Found\r\n");
      &close_connection($connection);
      last;
     }
     $prefix=$1;
     $content_type="text/html";
     opendir(DIR,"$var_dir/".uri_unescape($1)."/");
     @list_images=readdir(DIR);
     closedir(DIR);
     $img_content="<body style='background-color:#adadad;'>\n";
     $img_content.="<center>\n";
     for(@list_images) {
      if(/(\.jpg|\.png)/) {
       $file_path="/$prefix/$_-".time();
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
     $img_content="";
     $img_file=uri_unescape("$var_dir/$1/$2.$3");
     $img_extension=$3;
     $img_file="$convert -resize $img_width"."x$img_height '$img_file' $img_extension:-|" if($key=~/\&preview=1/);
     $img_file="$convert -resize $1 '$img_file' $img_extension:-|"                        if($key=~/\&resize=(\d+x\d+)/);
     open(IMG,$img_file);
     $img_content.=$_ while(<IMG>);
     close(IMG);
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
    if($rpc_client{$connection}) {
     $cmd{$connection}="";
    } elsif($key =~/$end_cmd_string|$end_cmd_string_calman/) {
     $cmd{$connection}.=$key;
     $key=$cmd{$connection};
     $cmd{$connection}="";
    } else {
     $cmd{$connection}.=$key;
     if($cmd{$connection} =~/$end_cmd_string|$end_cmd_string_calman/) { $key=$cmd{$connection}; $cmd{$connection}=""; }
     else                                                             { last;                                         }
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
     if(!$f_size) {
      &send_key_to_client($connection,&error());
      last;
     }
     $f_content=~s/.*;base64,//g;
     if(!$uploading_file) {
      $f_tmp_name="$upload_tmp_dir/UPLOAD_FILE.".time().".".$$;
      $uploading_file=1;
     }
     &upload_file($f_name,$f_tmp_name,$f_content);
     $f_perc=int((100*$f_start)/$f_size)."%";
     if($f_status eq "END_UPLOAD") {
      $uploading_file=0;
      my $dir_file=&get_destination($f_where);
      if($f_where eq "PLUGINS") { $response_to_send=&sudo("SET_PLUGIN",$f_tmp_name,$f_name,$f_where,"install.sh") if($f_where eq "PLUGINS"); }
      else                      {                     
       # Check uploadef file type
       open(CMD,"$file_command $f_tmp_name|");
       my $file_type=<CMD>;
       close(CMD);
       # Add support to extract Zip archive data
       if($file_type =~/Zip archive data/) {
        system("$unzip -o -d $dir_file $f_tmp_name 1>/dev/null");
        unlink($f_tmp_name);
       } else {
        rename($f_tmp_name,"$dir_file/$f_name");
       }
      }
      $f_perc="100%";
     }
     &send_key_to_client($connection,"$response_to_send:$f_perc");
     last;
    }
    #
    # Calman Unified Pattern Generator Control Interface Command Request
    # TERM — graceful disconnect (no colon, handle separately)
    #
    if($calman{$connection} && $key=~/TERM/) {
     &calman_reset_pattern_state("TERM");
     &release_source_rgb_quant_range("calman");
     $calibration_client_ip="";
     $calibration_client_software="";
     &send_key_to_client($connection,"");
     &close_connection($connection,"calman TERM");
     last;
    }
    #
    # Calman Unified Pattern Generator Control Interface Command Request
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
      # Capabilities — report HDR, DV, window size, bit depth, colorspace, range
      my $caps="HDR,DOLBYVISION,CONF_FORMAT,CONF_HDR,SIZE,10_SIZE,11_APL,CommandRGB,BITDEPTH,COLORSPACE,RANGE";
      &log("Calman: CAP request, returning $caps");
      &send_calman_payload_to_client($connection,$caps);
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
      &log("Calman: FIRMWARE request, returning $version");
      &send_calman_payload_to_client($connection,$version);
      last;
     }
     if($clean_key eq "STATUS") {
      my $status_caps="STATUS,CONF_FORMAT,CONF_HDR,CONF_LEVEL,CONF_DV,HDR_ENABLE,IMAGE,PUSH,RGB_S,RGB_B,RGB_A,CommandRGB,10_SIZE,11_APL,SPECIALTY,UPDATE,YCC_A,YCC_B,YCC_S";
      &log("Calman: STATUS request, returning $status_caps");
      &send_calman_payload_to_client($connection,$status_caps);
      last;
     }
     if($clean_key eq "SHUTDOWN" || $clean_key eq "QUIT") {
      &log("Calman: $clean_key received, closing connection");
      &calman_reset_pattern_state($clean_key);
      &release_source_rgb_quant_range("calman");
      $calibration_client_ip="";
      $calibration_client_software="";
      &send_key_to_client($connection,"");
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
      # Return current resolution/format/range/bits settings
      # The client expects these fields: Resolution, Refresh, 1_FORMAT, Range, Bits, Dolby
      my $cur_res="${w_s}x${h_s}";
      my $cur_refresh="60";
      my $cur_format="RGB 8-bit";
      my $cur_range="Full";
      my $cur_bits=$pgenerator_conf{"max_bpc"} || "8";
      my $cur_dolby=($pgenerator_conf{"dv_status"} eq "1") ? "On" : "Off";
      # Parse current mode for refresh rate
      if($preferred_mode =~/(\d+)\[.*\s([\d.]+)Hz/) {
       $cur_refresh=int($2);
      }
      # Build color format string from config
      my $cf=$pgenerator_conf{"color_format"} || "0";
      if($cf eq "0")    { $cur_format="RGB $cur_bits-bit"; }
      elsif($cf eq "1") { $cur_format="YCbCr 444 $cur_bits-bit"; }
      elsif($cf eq "2") { $cur_format="YCbCr 422 $cur_bits-bit"; }
      elsif($cf eq "3") { $cur_format="YCbCr 420 $cur_bits-bit"; }
      # Build range string from config
      my $rq=$pgenerator_conf{"rgb_quant_range"} || "0";
      $cur_range="Limited" if($rq eq "1");
      $cur_range="Full"    if($rq eq "2");
      my $settings="Resolution=$cur_res,Refresh=$cur_refresh,1_FORMAT=$cur_format,Range=$cur_range,Bits=$cur_bits,Dolby=$cur_dolby";
      &log("Calman: GET_SETTINGS returning: $settings");
      &send_calman_payload_to_client($connection,$settings);
      last;
     }
    }
    if($calman{$connection} && $key=~/:/) {
     ($type,$pattern_cmd)=&calman_split_command($key);
     $type=~s/^\x02//;
     &log("Calman UPGCI: type=$type cmd=$pattern_cmd");
     #
    # INIT — client handshake. Calman does not always send its selected
    # resolution on connect, so apply the remembered/default Calman mode.
     #
     if($type eq "INIT") {
      &calman_reset_pattern_state("INIT");
      &calman_apply_init_mode();
      &send_key_to_client($connection,"");
      last;
     }
     #
     # Helper: save a PGenerator conf key and mark settings dirty
     # (defers the pattern generator restart until a pattern command arrives)
     #
	     my $calman_save_setting = sub {
	      my ($conf_key,$conf_val)=@_;
	      &sudo("SET_PGENERATOR_CONF",$conf_key,$conf_val);
	      $pgenerator_conf{$conf_key}="$conf_val";
	      &sync_pattern_bits_default();
	      $calman_settings_dirty=1;
	      &log("Calman: saved $conf_key=$conf_val (dirty flag set)");
	     };
	     my $calman_note_explicit_bpc = sub {
	      my $bpc=&calman_valid_bpc(shift);
	      return "" if($bpc eq "");
	      $calman_explicit_max_bpc=$bpc;
	      &log("Calman: explicit bit depth set to ${bpc}bpc");
	      return $bpc;
	     };
	     my $calman_preferred_bpc = sub {
	      my $fallback=shift;
	      my $explicit=&calman_valid_bpc($calman_explicit_max_bpc);
	      return $explicit if($explicit ne "");
	      return &calman_valid_bpc($fallback) if(&calman_valid_bpc($fallback) ne "");
	      return "10";
	     };
	     my $calman_apply_source_payload = sub {
	      my ($payload,$default_format_bpc)=@_;
	      my %parsed=&calman_parse_source_format_payload($payload,$default_format_bpc);
	      my $changed=0;
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
	        $calman_rgb_quant_range=$parsed{range} + 0;
	        &log("Calman: external range set to $calman_rgb_quant_range via source settings");
	        &apply_source_rgb_quant_range("calman",$calman_rgb_quant_range);
	       } else {
	        &log("Calman: releasing external range via source settings");
	        &release_source_rgb_quant_range("calman");
	        $calman_rgb_quant_range=&webui_preferred_rgb_quant_range() + 0;
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
     # Later generic Calman format/range/bit-depth commands must not undo it.
     #
     my $calman_dv_active = sub {
      return 1 if(int($pgenerator_conf{"dv_status"} || 0) == 1);
      return 1 if(int($pgenerator_conf{"is_ll_dovi"} || 0) == 1);
      return 1 if(int($pgenerator_conf{"is_std_dovi"} || 0) == 1);
      return 0;
     };
     my $calman_force_dv_rgb = sub {
      return if(!$calman_dv_active->());
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
	      $calman_save_setting->("rgb_quant_range","2");
	      $calman_save_setting->("dv_metadata",$calman_dv_metadata_for_map_mode->($pgenerator_conf{"dv_map_mode"}));
      $calman_rgb_quant_range=2;
      &apply_source_rgb_quant_range("calman",2);
     };
     #
     # Helper: apply pending settings — restart pattern generator if dirty
     #
     my $calman_apply = sub {
      my $replay_after=shift;
      $replay_after=1 if(!defined $replay_after);
      if($calman_settings_dirty) {
       $calman_force_dv_rgb->();
       &log("Calman: applying pending settings (restarting pattern generator)");
       &pattern_generator_stop();
       &pattern_generator_start();
       $calman_settings_dirty=0;
       &calman_replay_last_pattern("settings apply") if($replay_after);
       return 1;
      }
      return 0;
     };
    #
    # Helper: Calman DV calibration uses Standard Dolby Vision transport.
    # Absolute/Relative select the renderer map mode and matching legacy
    # metadata-mode value; they do not switch to Low Latency transport.
    #
    my $calman_set_dv_rgb = sub {
     my ($dv_map_mode,$dv_metadata)=@_;
     my $dv_transport="standard";
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
	     $calman_save_setting->("rgb_quant_range","2");
     $calman_rgb_quant_range=2;
     &apply_source_rgb_quant_range("calman",2);
     $calman_save_setting->("dv_map_mode","$dv_map_mode") if(defined $dv_map_mode && $dv_map_mode ne "");
     if(!defined $dv_metadata || $dv_metadata eq "") {
      $dv_metadata=$calman_dv_metadata_for_map_mode->((defined $dv_map_mode && $dv_map_mode ne "") ? $dv_map_mode : $pgenerator_conf{"dv_map_mode"});
     }
     $calman_save_setting->("dv_metadata","$dv_metadata");
    };

    my $calman_set_non_dv_mode = sub {
     my ($mode,$eotf_val,$colorimetry,$max_bpc)=@_;
	     $mode=lc($mode || "sdr");
	     $eotf_val=0 if(!defined $eotf_val || $eotf_val eq "");
	     $colorimetry=($eotf_val >= 2) ? "9" : "2" if(!defined $colorimetry || $colorimetry eq "");
	     $max_bpc=($eotf_val >= 2) ? "10" : "8" if(!defined $max_bpc || $max_bpc eq "");
	     $max_bpc=$calman_preferred_bpc->($max_bpc);
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
       $calman_rgb_quant_range=&webui_preferred_rgb_quant_range() + 0;
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
       if($range_val eq "1" || $range_val eq "2") {
        $calman_rgb_quant_range=$range_val + 0;
        &log("Calman: external range set to $calman_rgb_quant_range via RPC CMD");
        &apply_source_rgb_quant_range("calman",$calman_rgb_quant_range);
       } else {
        &log("Calman: releasing external range via RPC CMD");
        &release_source_rgb_quant_range("calman");
        $calman_rgb_quant_range=&webui_preferred_rgb_quant_range() + 0;
       }
       &calman_replay_last_pattern("RPC CMD range");
       return 1;
      }
     }
     return 0;
    };

    if($calman_handle_rpc_source_alias->($type,$pattern_cmd)) {
     &send_key_to_client($connection,"");
     last;
    }

    if($key =~/^\x02?SPECIALTY:([^\x02\x03]+)\x02CONF_LEVEL:Range\s+([^\x03]+)\x03?$/i) {
     my ($specialty,$range_val)=($1,$2);
     $specialty=~s/^\s+|\s+$//g;
     $range_val=~s/^\s+|\s+$//g;
     &log("Calman: split combined SPECIALTY=$specialty + CONF_LEVEL=Range $range_val");
     if($range_val =~/full/i) {
      $calman_rgb_quant_range=2;
      &apply_source_rgb_quant_range("calman",$calman_rgb_quant_range);
     } elsif($range_val =~/limit/i) {
      $calman_rgb_quant_range=1;
      &apply_source_rgb_quant_range("calman",$calman_rgb_quant_range);
     } else {
      &release_source_rgb_quant_range("calman");
      $calman_rgb_quant_range=&webui_preferred_rgb_quant_range() + 0;
     }
     $calman_apply->(0);
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
        $calman_set_non_dv_mode->("sdr",0,"2","8");
        # Apply immediately — DRM properties must change now, not on next pattern
        $calman_apply->();
      }
      if($pattern_cmd =~/^True$/i) {
       &log("Calman: HDR_ENABLE=True — HDR requested, awaiting CONF_HDR");
       # Don't set HDR yet; CONF_HDR will follow with full metadata
       # But mark HDR intent so if no CONF_HDR comes, next pattern apply will enable HDR
       $calman_set_non_dv_mode->("hdr",2,"9","10");
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
      my $hdr_min_luma=$hdr_f[9]+0;
      my $hdr_max_luma=int($hdr_f[10]);
      my $hdr_max_cll=int($hdr_f[11]);
      # Last field is 5-digit zero-padded MaxFALL + gamma (e.g. "004002.2000" = 400 + γ2.2)
      my $hdr_max_fall=int(substr($hdr_f[12],0,5));
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
	      # Set bit depth based on EOTF unless Calman sent an explicit source bit depth.
	      $calman_save_setting->("max_bpc",$calman_preferred_bpc->($eotf_val >= 2 ? "10" : "8"));
      # Luminance metadata
      $calman_save_setting->("min_luma","$hdr_min_luma") if($hdr_min_luma > 0);
      $calman_save_setting->("max_luma","$hdr_max_luma") if($hdr_max_luma > 0);
      $calman_save_setting->("max_cll","$hdr_max_cll") if($hdr_max_cll > 0);
      $calman_save_setting->("max_fall","$hdr_max_fall") if($hdr_max_fall > 0);
      &log("Calman: CONF_HDR parsed — eotf=$eotf_val prim=$prim_val maxL=$hdr_max_luma minL=$hdr_min_luma maxCLL=$hdr_max_cll maxFALL=$hdr_max_fall");
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
	       # Dolby Vision modes — drive both the renderer map mode and Calman's
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
      if($qrng_val eq "1" || $qrng_val eq "2") {
       $calman_rgb_quant_range=$qrng_val + 0;
       &log("Calman: external range set to $calman_rgb_quant_range via QRNG");
       &apply_source_rgb_quant_range("calman",$calman_rgb_quant_range);
      } else {
       &log("Calman: releasing external range via QRNG=$pattern_cmd");
       &release_source_rgb_quant_range("calman");
       $calman_rgb_quant_range=&webui_preferred_rgb_quant_range() + 0;
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
          &log("Calman: external range set to $calman_rgb_quant_range");
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
      &calman_render_commandrgb_pattern($pattern_cmd,$connection);
      &calman_remember_pattern("CommandRGB",$type,$pattern_cmd);
      &send_key_to_client($connection,"");
      last;
     }
     #
    # RGB Pattern Commands (legacy external wire protocol)
    # RGB_B:R,G,B,BG  RGB_S:R,G,B,SIZE  RGB_A:R,G,B,BG_R,BG_G,BG_B,SIZE
    # The client sends 10-bit values (0-1023); scale to the current output depth
     #
     if($type =~/RGB_/) {
      # Apply any pending display mode settings before showing pattern
      $calman_apply->(0);
      &calman_render_rgb_pattern($type,$pattern_cmd,$key,$connection);
      &calman_remember_pattern("RGB",$type,$pattern_cmd);
      &send_key_to_client($connection,"");
      last;
     }
     #
     # CONF_FORMAT — Resolution/format configuration
     # Parses resolution string (e.g. "1080p60", "720p50") and switches
    &apply_source_rgb_quant_range("calman",$calman_rgb_quant_range);
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
       # Scan modetest for matching mode
       my $best_idx=-1;
       my $best_score=0;
       open(my $mt_fh,"$modetest 2>/dev/null|");
       my $mt_connected=0;
       while(my $ml=<$mt_fh>) {
        $mt_connected=1 if($ml =~/\s+connected/);
        next if(!$mt_connected);
        # Mode line: #idx WxH[i] rate ... flags ...; type: ...
        next if($ml !~/^\s*#(\d+)\s+(\d+)x(\d+)(i?)\s+([\d.]+)\s+.*type:\s*(.*)/);
        my ($m_idx,$m_w,$m_h,$m_i,$m_rate,$m_type)=($1,int($2),int($3),$4,$5,$6);
        # Match height
        next if($m_h != $req_h);
        # Match interlaced/progressive
        my $m_ip=($m_i eq "i") ? "i" : "p";
        next if($m_ip ne $req_ip);
        # Match refresh rate; tolerate Calman integer labels for fractional HDMI modes.
        my $m_rate_num=$m_rate + 0;
        my $rate_match=(int($m_rate_num) == int($req_rate)) || (abs($m_rate_num - ($req_rate + 0)) < 0.25);
        next if(!$rate_match);
        # Score: exact width match > standard width > any width; userdef > preferred > driver
        my $score=0;
        $score+=100 if($req_w && $m_w == $req_w);
        $score+=10  if($m_type =~/userdef/);
        $score+=5   if($m_type =~/preferred/);
        $score+=1;
        if($score > $best_score) {
         $best_idx=$m_idx;
         $best_score=$score;
        }
       }
       close($mt_fh);
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
      } elsif($cl =~/^Range\s+(.*)/i) {
       my $rv=lc($1);
       if($rv =~/full/) {
       $calman_rgb_quant_range=2;
        &log("Calman: external range set to $calman_rgb_quant_range via CONF_LEVEL");
        &apply_source_rgb_quant_range("calman",$calman_rgb_quant_range);
        &calman_replay_last_pattern("CONF_LEVEL range");
       } elsif($rv =~/limit/) {
        $calman_rgb_quant_range=1;
        &log("Calman: external range set to $calman_rgb_quant_range via CONF_LEVEL");
        &apply_source_rgb_quant_range("calman",$calman_rgb_quant_range);
        &calman_replay_last_pattern("CONF_LEVEL range");
       } else {
        &log("Calman: releasing external range via CONF_LEVEL=$cl");
        &release_source_rgb_quant_range("calman");
        $calman_rgb_quant_range=&webui_preferred_rgb_quant_range() + 0;
        &calman_replay_last_pattern("CONF_LEVEL range");
       }
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
         # Calman metadata mode values:
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
     &pattern_generator_stop();
     &pattern_generator_start();
     &send_key_to_client($connection,$ok_response);
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
    #
    if($key=~/$status_command/) {
     $response="$ok_response:$status";
     &send_key_to_client($connection,$response);
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
     $response_to_send=&sudo("SET_PLUGIN","$dir_file/$f_name",$plugin_archive_file,$f_where,"uninstall.sh") if($f_where eq "PLUGINS");
     unlink("$dir_file/$f_name");
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
      $payload=&legacy_external_hcfr_template_payload($payload);
      $source_range=&legacy_external_hcfr_source_range($payload);
     } else {
      &legacy_external_set_status($connection,"DeviceControl");
     }
      $response=&get_pattern($1,$2,$payload,"TESTTEMPLATE:$2",$source_range);
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
      my $source_range="";
      if($hcfr_client{$connection}) {
       &legacy_external_set_status($connection,"HCFR");
       $draw=&legacy_external_hcfr_draw($draw);
       $source_range=&legacy_external_hcfr_source_range($5);
      } else {
       &legacy_external_set_status($connection,"DeviceControl");
      }
     $pname_file=$1;
     &clean_pattern_files();
      $response="$ok_response:".&create_pattern_file($draw,$3,$4,"$5","","","","",1,"TESTPATTERN",$source_range);
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
     $command_found=1;
     if($hcfr_marker_text) {
      $log_string="Received hcfr marker text command";
      $log_string.=" ($key)" if($key ne "");
      &log($log_string);
      &send_key_to_client($connection,$ok_response);
      last;
     }
     &clean_pattern_files();
     $log_string="Received rgb triplet request command";
     $log_string.=" ($key)" if($key ne "");
     &log($log_string);
    &create_pattern_file($draw,"$dim",$res,"$rgb","$bg","$position","$text","",1,"RGB",$source_range);
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

###############################################
#          Send Key To Client function        #
###############################################
sub send_key_to_client (@) {
 my $connection = shift;
 my $response = shift;
 $response.=$end_cmd_string;
 $response=$ack_cmd_string if($calman{$connection});
 eval { $connection->send("$response"); };
 if($@) {
  my $send_error="$@";
  $send_error=~s/\s+$//;
  &close_connection($connection,"send error: $send_error");
 }
}

###############################################
#        Send Calman Payload To Client        #
###############################################
sub send_calman_payload_to_client (@) {
 my $connection = shift;
 my $response = shift;
 $response="" if(!defined($response));
 $response.=$end_cmd_string_calman if(!$rpc_client{$connection});
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
 $socket_kind="rpc" if($socket_kind eq "" && $rpc_client{$connection});
 $socket_kind="calman" if($socket_kind eq "" && $calman{$connection});
 $socket_kind="classic" if($socket_kind eq "");
 &log("Pattern socket close: type=$socket_kind peer=$conn_ip reason=$reason") if($reason ne "");
 my $is_hcfr=delete $hcfr_client{$connection};
 if($calman{$connection} || ($conn_ip ne "" && $conn_ip eq $calibration_client_ip)) {
  &log("Calman: socket disconnected, preserving pattern state");
  $calibration_client_ip="";
  $calibration_client_software="";
 }
 &release_source_rgb_quant_range("hcfr") if($is_hcfr);
 $calman{$connection}=0;
 $cmd{$connection}="";
 delete $client_ip{$connection};
 delete $hcfr_client_quant_range{$connection};
 delete $rpc_client{$connection};
 #$connection->send("");
 $select->remove($connection);
 eval { $connection->close(); };
 $uploading_file=0;
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
return 1;
