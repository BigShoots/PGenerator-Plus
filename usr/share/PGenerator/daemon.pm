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

sub calman_expand_limited_value (@) {
 my $value=int(shift);
 my $range_mode=int($pgenerator_conf{"rgb_quant_range"} || 0);
 return $value if($range_mode != 1);
 # Only expand for RGB — YCbCr uses limited range natively
 my $color_fmt=int($pgenerator_conf{"color_format"} || 0);
 return $value if($color_fmt != 0);
 my $bits=int($bits_default || 8);
 my $shift=$bits - 8;
 my $limited_min=16 << $shift;
 my $limited_span=219 << $shift;
 my $full_max=(1 << $bits) - 1;
 return 0 if($value <= $limited_min);
 return $full_max if($value >= $limited_min + $limited_span);
 return int(($value - $limited_min) * $full_max / $limited_span + 0.5);
}

sub calman_expand_limited_triplet (@) {
 my $rgb=shift;
 my $range_mode=int($pgenerator_conf{"rgb_quant_range"} || 0);
 return $rgb if($range_mode != 1);
 my $color_fmt=int($pgenerator_conf{"color_format"} || 0);
 return $rgb if($color_fmt != 0);
 my ($r,$g,$b)=split(",",$rgb);
 return &calman_expand_limited_value($r).",".&calman_expand_limited_value($g).",".&calman_expand_limited_value($b);
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
 &log("Calman: reset pattern state ($source)") if($source ne "");
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
  my @ready = $select->can_read();
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
    $client_address=$client_socket->peerhost();
    $client_port=$client_socket->peerport();
    $client_ip{$client_socket}=$client_address;
    $rpc_client{$client_socket}=1 if($connection == $server_rpc);
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
     &log("recv failed: $!");
     &close_connection($connection);
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
     $log_string="Received close command";
     $log_string.=" ($key)" if($key ne "");
     &log($log_string);
     &close_connection($connection);
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
     $log_string="Received close command";
     $log_string.=" ($key)" if($key ne "");
     &log($log_string);
     &close_connection($connection);
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
     $calibration_client_ip="";
     $calibration_client_software="";
     &send_key_to_client($connection,"");
     &close_connection($connection);
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
     # No-colon Calman commands (SN, CAP, ENABLE PATTERNS)
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
      if($rpc_client{$connection}) {
       eval { $connection->send("$sn"); };
       &close_connection($connection) if($@);
      } else {
       &send_key_to_client($connection,$sn);
      }
      last;
     }
     if($clean_key eq "CAP") {
      # Capabilities — report HDR, DV, window size, bit depth, colorspace, range
      my $caps="HDR,DOLBYVISION,CONF_HDR,SIZE,10_SIZE,11_APL,CommandRGB,BITDEPTH,COLORSPACE,RANGE";
      &log("Calman: CAP request, returning $caps");
      if($rpc_client{$connection}) {
       eval { $connection->send("$caps"); };
       &close_connection($connection) if($@);
      } else {
       &send_key_to_client($connection,$caps);
      }
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
      if($rpc_client{$connection}) {
       eval { $connection->send("$version"); };
       &close_connection($connection) if($@);
      } else {
       &send_key_to_client($connection,"");
      }
      last;
     }
     if($clean_key eq "STATUS") {
      my $status_caps="STATUS,CONF_FORMAT,CONF_HDR,CONF_LEVEL,CONF_DV,HDR_ENABLE,IMAGE,PUSH,RGB_S,RGB_B,RGB_A,CommandRGB,10_SIZE,11_APL,SPECIALTY,UPDATE,YCC_A,YCC_B,YCC_S";
      &log("Calman: STATUS request, returning $status_caps");
      if($rpc_client{$connection}) {
       eval { $connection->send("$status_caps"); };
       &close_connection($connection) if($@);
      } else {
       &send_key_to_client($connection,"");
      }
      last;
     }
     if($clean_key eq "SHUTDOWN" || $clean_key eq "QUIT") {
      &log("Calman: $clean_key received, closing connection");
      &calman_reset_pattern_state($clean_key);
      $calibration_client_ip="";
      $calibration_client_software="";
      &send_key_to_client($connection,"");
      &close_connection($connection);
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
      # CalMAN parses fields: Resolution, Refresh, 1_FORMAT, Range, Bits, Dolby
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
      if($rpc_client{$connection}) {
       eval { $connection->send("$settings"); };
       &close_connection($connection) if($@);
      } else {
       &send_key_to_client($connection,"");
      }
      last;
     }
    }
    if($calman{$connection} && $key=~/(.*):(.*)/) {
     $type=$1;
     $pattern_cmd=$2;
     $type=~s/^\x02//;
     &log("Calman UPGCI: type=$type cmd=$pattern_cmd");
     #
     # INIT — Calman handshake (just ACK, no state change)
     #
     if($type eq "INIT") {
      &calman_reset_pattern_state("INIT");
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
     #
     # Helper: apply pending settings — restart pattern generator if dirty
     #
     my $calman_apply = sub {
      if($calman_settings_dirty) {
       &log("Calman: applying pending settings (restarting pattern generator)");
       &pattern_generator_stop();
       &pattern_generator_start();
       $calman_settings_dirty=0;
      }
     };
    #
    # Helper: align CalMAN DV mode with the existing RGB LLDV path used by
    # the Web UI / legacy DeviceControl profiles. The renderer stays 8-bit,
    # while max_bpc=12 requests a 12-bit HDMI link for Dolby Vision RGB
    # tunneling on the wire.
    #
    my $calman_set_dv_rgb = sub {
     my ($dv_map_mode,$dv_metadata)=@_;
     $calman_save_setting->("is_sdr","0");
     $calman_save_setting->("is_hdr","1");
     $calman_save_setting->("is_ll_dovi","1");
     $calman_save_setting->("is_std_dovi","1");
     $calman_save_setting->("dv_status","1");
     $calman_save_setting->("dv_interface","1");
     $calman_save_setting->("color_format","0");
     $calman_save_setting->("colorimetry","9");
     $calman_save_setting->("primaries","1");
     $calman_save_setting->("max_bpc","12");
     $calman_save_setting->("rgb_quant_range","2");
     $calman_save_setting->("dv_map_mode","$dv_map_mode") if(defined $dv_map_mode && $dv_map_mode ne "");
     $calman_save_setting->("dv_metadata","$dv_metadata") if(defined $dv_metadata && $dv_metadata ne "");
    };

    #
    # HDR_ENABLE — Calman proprietary HDR toggle
    # HDR_ENABLE:True → prepare for HDR (CONF_HDR follows with details)
    # HDR_ENABLE:False → switch to SDR
    #
     if($type eq "HDR_ENABLE") {
      if($pattern_cmd =~/^False$/i) {
       &log("Calman: HDR_ENABLE=False — switching to SDR");
       $calman_save_setting->("is_sdr","1");
       $calman_save_setting->("is_hdr","0");
       $calman_save_setting->("is_ll_dovi","0");
       $calman_save_setting->("is_std_dovi","0");
       $calman_save_setting->("dv_status","0");
       $calman_save_setting->("eotf","0");
       $calman_save_setting->("color_format","0");
       $calman_save_setting->("colorimetry","2");
       $calman_save_setting->("max_bpc","8");
       # Apply immediately — DRM properties must change now, not on next pattern
       $calman_apply->();
      }
      if($pattern_cmd =~/^True$/i) {
       &log("Calman: HDR_ENABLE=True — HDR requested, awaiting CONF_HDR");
       # Don't set HDR yet; CONF_HDR will follow with full metadata
       # But mark HDR intent so if no CONF_HDR comes, next pattern apply will enable HDR
       $calman_save_setting->("is_sdr","0");
       $calman_save_setting->("is_hdr","1");
       $calman_save_setting->("eotf","2");
       $calman_save_setting->("colorimetry","9");
       $calman_save_setting->("max_bpc","10");
      }
      &send_key_to_client($connection,"");
      last;
     }
     #
     # CONF_HDR — Calman proprietary full HDR metadata configuration
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
       $calman_save_setting->("is_hdr","1");
       $calman_save_setting->("is_sdr","0");
      } else {
       $calman_save_setting->("is_hdr","0");
       $calman_save_setting->("is_sdr","1");
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
      # Set bit depth based on EOTF (PQ/HLG=10bit, SDR=8bit)
      $calman_save_setting->("max_bpc",$eotf_val >= 2 ? "10" : "8");
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
       $calman_save_setting->("is_sdr","1");
       $calman_save_setting->("is_hdr","0");
       $calman_save_setting->("is_ll_dovi","0");
       $calman_save_setting->("is_std_dovi","0");
       $calman_save_setting->("dv_status","0");
       $calman_save_setting->("eotf","0");
       $calman_save_setting->("color_format","0");
       $calman_save_setting->("colorimetry","2");
       $calman_save_setting->("max_bpc","8");
       $need_restart=1;
      }
      if($pattern_cmd =~/^HDR10$/i) {
       $calman_save_setting->("is_sdr","0");
       $calman_save_setting->("is_hdr","1");
       $calman_save_setting->("is_ll_dovi","0");
       $calman_save_setting->("is_std_dovi","0");
       $calman_save_setting->("dv_status","0");
       $calman_save_setting->("eotf","2");
       $calman_save_setting->("color_format","0");
       $calman_save_setting->("colorimetry","9");
       $calman_save_setting->("primaries","1");
       $calman_save_setting->("max_bpc","10");
       $need_restart=1;
      }
      if($pattern_cmd =~/^HLG$/i) {
       $calman_save_setting->("is_sdr","0");
       $calman_save_setting->("is_hdr","1");
       $calman_save_setting->("is_ll_dovi","0");
       $calman_save_setting->("is_std_dovi","0");
       $calman_save_setting->("dv_status","0");
       $calman_save_setting->("eotf","3");
       $calman_save_setting->("color_format","0");
       $calman_save_setting->("colorimetry","9");
       $calman_save_setting->("primaries","1");
       $calman_save_setting->("max_bpc","10");
       $need_restart=1;
      }
      if($pattern_cmd =~/^DOLBYVISION$/i || $pattern_cmd =~/^DV$/i) {
       # Generic DV enable — preserve current map mode (Absolute/Relative).
       $calman_set_dv_rgb->("","1");
       $need_restart=1;
      }
      if($need_restart) {
       &pattern_generator_stop();
       &pattern_generator_start();
       $calman_settings_dirty=0;
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
       $calman_save_setting->("is_sdr","1");
       $calman_save_setting->("is_hdr","0");
       $calman_save_setting->("is_ll_dovi","0");
       $calman_save_setting->("is_std_dovi","0");
       $calman_save_setting->("dv_status","0");
       $calman_save_setting->("eotf","0");
       $calman_save_setting->("color_format","0");
       $calman_save_setting->("colorimetry","2");
       $calman_save_setting->("max_bpc","8");
      } elsif($mm_val >= 1 && $mm_val <= 4) {
       # Dolby Vision modes — the renderer consumes dv_map_mode for Absolute
       # / Relative, not dv_metadata.  Keep dv_metadata in sync for logging and
       # compatibility, but switch the real renderer key here.
       if($mm_val == 3) {
        $calman_set_dv_rgb->("1","3"); # Absolute
       } elsif($mm_val == 4) {
        $calman_set_dv_rgb->("2","4"); # Relative
       } else {
        # 1=RGB tunneling, 2=Perceptual. Preserve current map mode because the
        # renderer only exposes Absolute/Relative via dv_map_mode.
        $calman_set_dv_rgb->("","$mm_val");
        &log("Calman: 21_HDR_MetadataMode=$mm_val requested — preserving dv_map_mode=$pgenerator_conf{'dv_map_mode'}");
       }
      }
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
        $calman_save_setting->("is_hdr","1");
        $calman_save_setting->("is_sdr","0");
       } else {
        $calman_save_setting->("is_hdr","0");
        $calman_save_setting->("is_sdr","1");
       }
      }
      &send_key_to_client($connection,"");
      last;
     }
     #
     # PRIM / HDR_PRIMARIES — Mastering display primaries
     # PGenerator: 0=custom, 1=BT2020/D65, 2=P3/D65, 3=P3/DCI
     # Calman sends: 0=P3, 1=BT709, 2=BT2020, or string names
     #
     if($type eq "PRIM" || $type eq "HDR_PRIMARIES") {
      my $prim_val=$pattern_cmd;
      # Map Calman UPGCI numeric enum → PGenerator values
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
      my $bitd_val=int($pattern_cmd);
      if($bitd_val == 8 || $bitd_val == 10 || $bitd_val == 12) {
       $calman_save_setting->("max_bpc","$bitd_val");
      }
      &send_key_to_client($connection,"");
      last;
     }
     #
     # COLF — Color Format (RGB, YCbCr444, YCbCr422, YCbCr420)
     # PGenerator: 0=RGB, 1=YCbCr444, 2=YCbCr422, 3=YCbCr420
     #
     if($type eq "COLF") {
      my $colf_val="0";
      $colf_val="1" if($pattern_cmd =~/YCBCR444|YUV444|444/i);
      $colf_val="2" if($pattern_cmd =~/YCBCR422|YUV422|422/i);
      $colf_val="3" if($pattern_cmd =~/YCBCR420|YUV420|420/i);
      $calman_save_setting->("color_format","$colf_val");
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
      $calman_save_setting->("rgb_quant_range","$qrng_val");
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
       $calman_save_setting->("rgb_quant_range","1");  # limited/video
      } else {
       $calman_save_setting->("rgb_quant_range","2");  # full/PC
      }
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
      &send_key_to_client($connection,"");
      last;
     }
     #
     # 303_UPDATE / APPLY — Force apply pending settings now
     #
     if($type eq "303_UPDATE" || $type eq "APPLY") {
      $calman_apply->();
      &send_key_to_client($connection,"");
      last;
     }
     #
     # CommandRGB — Direct RGB pattern (from UPGCI DispId 31)
     # Format: CommandRGB:R,G,B,tenBit,size
     #
     if($type eq "CommandRGB") {
      @el_cmd=split(",",$pattern_cmd);
      my $cr_r=int($el_cmd[0]);
      my $cr_g=int($el_cmd[1]);
      my $cr_b=int($el_cmd[2]);
      my $cr_tenBit=int($el_cmd[3]);
      my $cr_size=int($el_cmd[4]);
        my $target_max=&calman_target_max();
      my $input_max=$cr_tenBit ? 1023 : 255;
      # Scale CommandRGB to the current output bit depth.  Only reduce to 8-bit
      # when output is explicitly configured for 8bpc.
        $cr_r=&calman_scale_value($cr_r,$input_max);
        $cr_g=&calman_scale_value($cr_g,$input_max);
        $cr_b=&calman_scale_value($cr_b,$input_max);
        my ($cr_size_effective,$cr_bg)=&calman_commandrgb_window("$cr_r,$cr_g,$cr_b",$cr_size,"CommandRGB");
      # Expand limited-range values to full range — GPU handles compression via DRM rgb_quant_range
      my $cr_rgb=&calman_expand_limited_triplet("$cr_r,$cr_g,$cr_b");
      $cr_bg=&calman_expand_limited_triplet($cr_bg);
      # Apply any pending settings before showing pattern
      $calman_apply->();
      &clean_pattern_files();
        if($cr_size_effective >= 100) {
       &create_pattern_file("RECTANGLE","$w_s,$h_s",100,"$cr_rgb","$cr_bg","","","",1,"calman");
      } else {
         my $sqrt_val=sqrt($cr_size_effective/100);
       my $win_w=int($sqrt_val*$max_x);
       my $win_h=int($sqrt_val*$max_y);
       &create_pattern_file("RECTANGLE","$win_w,$win_h",100,"$cr_rgb","$cr_bg","$position_default","","",1,"calman");
      }
      &send_key_to_client($connection,"");
      last;
     }
     #
    # RGB Pattern Commands (original Calman wire protocol)
    # RGB_B:R,G,B,BG  RGB_S:R,G,B,SIZE  RGB_A:R,G,B,BG_R,BG_G,BG_B,SIZE
    # Calman sends 10-bit values (0-1023); scale to the current output depth
     #
     if($type =~/RGB_/) {
      @el_cmd=split(",",$pattern_cmd);
      my $calman_max=1023;
        my $target_max=&calman_target_max();
      &log("Calman PATTERN: type=$type raw=$el_cmd[0],$el_cmd[1],$el_cmd[2] bits_default=$bits_default target_max=$target_max");
        $r=&calman_scale_value($el_cmd[0],$calman_max);
        $g=&calman_scale_value($el_cmd[1],$calman_max);
        $b=&calman_scale_value($el_cmd[2],$calman_max);
      &log("Calman PATTERN: scaled=$r,$g,$b bg=$calman_bg max_bpc=$pgenerator_conf{'max_bpc'}");
      if($calman_special_pattern{$key} ne "" &&  -f "$pattern_templates/$calman_special_pattern{$key}") {
       $response=&get_pattern("TESTTEMPLATE","$calman_special_pattern{$key}","","TESTTEMPLATE:$calman_special_pattern{$key}");
       &send_key_to_client($connection,$response);
       &clean_pattern_files();
       last;
      }
      # Apply any pending display mode settings before showing pattern
      $calman_apply->();
      # RGB_B: 4th field is background grey level (10-bit, scale to target bits)
      if($type =~/RGB_B/) {
        my $bg_val=&calman_scale_value($el_cmd[3],$calman_max);
        $calman_apl_enabled=0;
       $calman_bg="$bg_val,$bg_val,$bg_val";
       my $fg_ex=&calman_expand_limited_triplet("$r,$g,$b");
       my $bg_ex=&calman_expand_limited_triplet($calman_bg);
       &clean_pattern_files();
       &get_pattern($test_template_command,$pattern_dynamic,"$fg_ex;$bg_ex","calman");
       &send_key_to_client($connection,"");
       last;
      }
            # RGB_S: 4th field is window size percentage (direct window path)
      if($type =~/RGB_S/) {
       my $win_pct=int($el_cmd[3]);
        $win_pct=$calman_win_size if($win_pct < 1);
        $win_pct=100 if($win_pct > 100);
       $calman_win_size=$win_pct if($win_pct > 0);
        my $effective_bg=$calman_bg;
       my $fg_ex=&calman_expand_limited_triplet("$r,$g,$b");
       $effective_bg=&calman_expand_limited_triplet($effective_bg);
        &log("Calman: RGB_S direct window size=$win_pct% bg=$effective_bg");
       # full field pattern
       if($win_pct >= 100) {
        $pname_file="FullField";
        &clean_pattern_files();
        &create_pattern_file("RECTANGLE","$w_s,$h_s",100,"$fg_ex","$effective_bg","","","",1,"calman");
        &send_key_to_client($connection,"");
        last;
       }
       # windowed pattern - calculate dimensions from percentage
       my $sqrt_val=sqrt($win_pct/100);
       my $win_w=int($sqrt_val*$max_x);
       my $win_h=int($sqrt_val*$max_y);
       &clean_pattern_files();
       &create_pattern_file("RECTANGLE","$win_w,$win_h",100,"$fg_ex","$effective_bg","$position_default","","",1,"calman");
       &send_key_to_client($connection,"");
       last;
      }
      # RGB_A: explicit background RGB and window size
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
       my $fg_ex=&calman_expand_limited_triplet("$r,$g,$b");
       $effective_bg=&calman_expand_limited_triplet($effective_bg);
       &log("Calman: RGB_A explicit bg=$effective_bg size=$win_pct%");
       if($win_pct >= 100) {
        $pname_file="FullField";
        &clean_pattern_files();
        &create_pattern_file("RECTANGLE","$w_s,$h_s",100,"$fg_ex","$effective_bg","","","",1,"calman");
        &send_key_to_client($connection,"");
        last;
       }
       my $sqrt_val=sqrt($win_pct/100);
       my $win_w=int($sqrt_val*$max_x);
       my $win_h=int($sqrt_val*$max_y);
       &clean_pattern_files();
       &create_pattern_file("RECTANGLE","$win_w,$win_h",100,"$fg_ex","$effective_bg","$position_default","","",1,"calman");
       &send_key_to_client($connection,"");
       last;
      }
      # Default fallback
      my $effective_bg=&calman_apl_bg("$r,$g,$b",$calman_win_size,$type);
      my $fg_ex=&calman_expand_limited_triplet("$r,$g,$b");
      $effective_bg=&calman_expand_limited_triplet($effective_bg);
      &clean_pattern_files();
      &get_pattern($test_template_command,$pattern_dynamic,"$fg_ex;$effective_bg","calman");
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
      # Parse resolution string: <height><p|i><rate> e.g. 1080p60, 720p50, 480i30
      # Also accept WxH format: 1920x1080p60, 1920x1080p 60, 3840x2160p30
      my ($req_w,$req_h,$req_ip,$req_rate);
      if($fmt =~/^(\d+)x(\d+)\s*(p|i)\s*(\d+)/i) {
       $req_w=int($1);
       $req_h=int($2);
       $req_ip=lc($3);
       $req_rate=int($4);
      } elsif($fmt =~/^(\d+)\s*(p|i)\s*(\d+)/i) {
       $req_h=int($1);
       $req_ip=lc($2);
       $req_rate=int($3);
       # Standard TV widths for each height (prefer these over non-standard like 4096x2160)
       my %std_w=(2160=>3840,1080=>1920,720=>1280,576=>720,480=>720);
       $req_w=$std_w{$req_h} if(exists $std_w{$req_h});
      }
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
        # Match refresh rate (CalMAN uses integer: 59=59.94, 60=60.00, 23=23.98, 24=24.00)
        next if(int($m_rate) != $req_rate);
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
        # Update cached resolution
        &get_hdmi_info();
       } else {
        &log("Calman: CONF_FORMAT no matching mode for ${req_h}${req_ip}${req_rate}");
       }
      } else {
       &log("Calman: CONF_FORMAT unrecognized format: $fmt");
      }
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
       my $bd=int($1);
       if($bd == 8 || $bd == 10 || $bd == 12) {
        $calman_save_setting->("max_bpc","$bd");
       }
       # Apply immediately — DRM max_bpc must change now
       $calman_apply->();
      } elsif($cl =~/^Range\s+(.*)/i) {
       my $rv=lc($1);
       if($rv =~/full/) {
        $calman_save_setting->("rgb_quant_range","2");
       } elsif($rv =~/limit/) {
        $calman_save_setting->("rgb_quant_range","1");
       } else {
        $calman_save_setting->("rgb_quant_range","0");
       }
       # Apply immediately — DRM range must change now
       $calman_apply->();
      } elsif($cl =~/^Format\s+(.*)/i) {
       my $fv=$1;
       my $colf_val="0";
       $colf_val="1" if($fv =~/444/i);
       $colf_val="2" if($fv =~/422/i);
       $colf_val="3" if($fv =~/420/i);
       $calman_save_setting->("color_format","$colf_val");
       # Extract bit depth from format string (e.g. "YCC444_10", "RGB 8-bit")
       if($fv =~/_(\d+)$/ || $fv =~/(\d+)-bit/i) {
        my $fmt_bits=int($1);
        $calman_save_setting->("max_bpc","$fmt_bits") if($fmt_bits == 8 || $fmt_bits == 10 || $fmt_bits == 12);
       } else {
        # No bit depth suffix (e.g. "RGB", "YCC420") — default to 8bpc
        $calman_save_setting->("max_bpc","8");
       }
       # Apply immediately — DRM output format must change now
       $calman_apply->();
      } elsif($cl =~/^Gamma-HDR$/i) {
       $calman_save_setting->("is_sdr","0");
       $calman_save_setting->("is_hdr","1");
       $calman_save_setting->("eotf","2");
       $calman_save_setting->("colorimetry","9");
       $calman_save_setting->("max_bpc","10");
      } elsif($cl =~/^Gamma-SDR$/i) {
       $calman_save_setting->("is_sdr","1");
       $calman_save_setting->("is_hdr","0");
       $calman_save_setting->("eotf","0");
       $calman_save_setting->("colorimetry","2");
       $calman_save_setting->("max_bpc","8");
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
         # The renderer switches between Absolute and Relative via dv_map_mode:
         #   1 = Absolute
         #   2 = Relative
         # Preserve the incoming CalMAN enum in dv_metadata for visibility.
         if($dv_mode eq "ABSOLUTE") {
          $calman_set_dv_rgb->("1","3");
         } elsif($dv_mode eq "RELATIVE") {
          $calman_set_dv_rgb->("2","4");
         } else {
          # Perceptual has no distinct dv_map_mode in the renderer. Keep the
          # existing Absolute/Relative selection and record the CalMAN request.
          $calman_set_dv_rgb->("","2");
          &log("Calman: CONF_DV=PERCEPTUAL requested — preserving dv_map_mode=$pgenerator_conf{'dv_map_mode'}");
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
      $calman_apply->();
      &clean_pattern_files();
      my $sp_name=uc($pattern_cmd);
      $sp_name=~s/^\s+|\s+$//g;
      my $black_rgb=&calman_scale_triplet_8bit(0,0,0);
      my $white_rgb=&calman_scale_triplet_8bit(255,255,255);
      my $gray20_rgb=&calman_scale_triplet_8bit(20,20,20);
      my $gray128_rgb=&calman_scale_triplet_8bit(128,128,128);
      my $gray235_rgb=&calman_scale_triplet_8bit(235,235,235);
      if($sp_name eq "BRIGHTNESS") {
       &create_pattern_file("RECTANGLE","$w_s,$h_s",100,"$gray20_rgb","$calman_bg","","","",1,"calman");
      } elsif($sp_name eq "CONTRAST") {
       &create_pattern_file("RECTANGLE","$w_s,$h_s",100,"$gray235_rgb","$calman_bg","","","",1,"calman");
      } elsif($sp_name eq "ALIGNMENT" || $sp_name eq "OVERSCAN") {
        # White border frame pattern for alignment/overscan check
        &create_pattern_file("RECTANGLE","$w_s,$h_s",100,"$black_rgb","$black_rgb","","","",1,"calman");
        &create_pattern_file("RECTANGLE","$w_s,2",100,"$white_rgb","","0,0","","",0,"calman");
        &create_pattern_file("RECTANGLE","$w_s,2",100,"$white_rgb","","0,".($h_s-2),"","",0,"calman");
        &create_pattern_file("RECTANGLE","2,$h_s",100,"$white_rgb","","0,0","","",0,"calman");
        &create_pattern_file("RECTANGLE","2,$h_s",100,"$white_rgb","","".($w_s-2).",0","","",0,"calman");
        &create_pattern_file("RECTANGLE","2,$h_s",100,"$white_rgb","","".(int($w_s/2)-1).",0","","",0,"calman");
        &create_pattern_file("RECTANGLE","$w_s,2",100,"$white_rgb","","0,".(int($h_s/2)-1),"","",0,"calman");
      } else {
       &log("Calman: unknown specialty pattern: $sp_name");
       &create_pattern_file("RECTANGLE","$w_s,$h_s",100,"$gray128_rgb","$calman_bg","","","",1,"calman");
      }
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
     $calibration_client_ip=$client_ip{$connection} || $client_address;
     $calibration_client_software="DeviceControl";
     $response=&get_pattern($1,$2,$3,"TESTTEMPLATE:$2");
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
     $calibration_client_ip=$client_ip{$connection} || $client_address;
     $calibration_client_software="DeviceControl";
     $pname_file=$1;
     &clean_pattern_files();
     $response="$ok_response:".&create_pattern_file($2,$3,$4,"$5","","","","",1,"TESTPATTERN");
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
     $calibration_client_ip=$client_ip{$connection} || $client_address;
     $calibration_client_software="DeviceControl";
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
     $calibration_client_ip=$client_ip{$connection} || $client_address;
     $calibration_client_software="DeviceControl";
     $command_found=1;
     &clean_pattern_files();
     my ($draw,$dim,$res,$rgb,$bg,$position,$text)=split($separator,$1);
     $log_string="Received rgb triplet request command";
     $log_string.=" ($key)" if($key ne "");
     &log($log_string);
     &create_pattern_file($draw,"$dim",$res,"$rgb","$bg","$position","$text","",1,"RGB");
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
 &close_connection($connection) if($@);
}

###############################################
#          Close Connection function          #
###############################################
sub close_connection {
 my $connection = shift;
 return if(!$connection);
 my $conn_ip=$client_ip{$connection} || "";
 if($calman{$connection} || ($conn_ip ne "" && $conn_ip eq $calibration_client_ip)) {
  &calman_reset_pattern_state("disconnect");
  $calibration_client_ip="";
  $calibration_client_software="";
 }
 $calman{$connection}=0;
 $cmd{$connection}="";
 delete $client_ip{$connection};
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
