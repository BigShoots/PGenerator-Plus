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
  threads->create(\&webui_http)->detach();
  threads->create(\&webui_mdns)->detach();
  &pattern_daemon();
  exit;
 }
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
 $select = IO::Select->new();
 $select->add($server,$server_calman);

 ############################
 #                          #
 #      LOOP Request        #
 #                          #
 ############################
 while ($select->count()) {
  my @ready = $select->can_read();
  foreach my $connection (@ready) {
   if ($connection == $server || $connection == $server_calman) {
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
    if($key =~/$end_cmd_string_calman$/) {
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
    if($key =~/$end_cmd_string|$end_cmd_string_calman/) {
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
    $key=~s/\r$//;
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
      $sn="PGenerator" if($sn eq "");
      &log("Calman: SN request, returning $sn");
      &send_key_to_client($connection,$sn);
      last;
     }
     if($clean_key eq "CAP") {
      # Capabilities — report HDR + window size + bit depth support
      my $caps="HDR,CONF_HDR,SIZE,BITDEPTH,COLORSPACE,RANGE";
      &log("Calman: CAP request, returning $caps");
      &send_key_to_client($connection,$caps);
      last;
     }
     if($clean_key eq "ENABLE PATTERNS" || $clean_key eq "ENABLEPATTERNS") {
      &log("Calman: ENABLE PATTERNS acknowledged");
      &send_key_to_client($connection,"");
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
       $calman_save_setting->("colorimetry","2");
       $calman_save_setting->("max_bpc","8");
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
       $calman_save_setting->("colorimetry","9");
       $calman_save_setting->("primaries","1");
       $calman_save_setting->("max_bpc","10");
       $need_restart=1;
      }
      if($pattern_cmd =~/^DOLBYVISION$/i || $pattern_cmd =~/^DV$/i) {
       $calman_save_setting->("is_sdr","0");
       $calman_save_setting->("is_hdr","0");
       $calman_save_setting->("is_ll_dovi","1");
       $calman_save_setting->("is_std_dovi","0");
       $calman_save_setting->("dv_status","1");
       $calman_save_setting->("colorimetry","9");
       $calman_save_setting->("max_bpc","12");
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
       $calman_save_setting->("colorimetry","2");
       $calman_save_setting->("max_bpc","8");
      } elsif($mm_val >= 1 && $mm_val <= 4) {
       # Dolby Vision modes
       $calman_save_setting->("is_sdr","0");
       $calman_save_setting->("is_hdr","0");
       $calman_save_setting->("is_ll_dovi","1");
       $calman_save_setting->("is_std_dovi","0");
       $calman_save_setting->("dv_status","1");
       $calman_save_setting->("dv_metadata","$mm_val");
       $calman_save_setting->("colorimetry","9");
       $calman_save_setting->("max_bpc","12");
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
     # Acknowledged but not configurable on PGenerator hardware
     #
     if($type eq "11_APL") {
      &log("Calman: APL=$pattern_cmd% (acknowledged)");
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
      # Convert 10-bit to 8-bit if needed
      if($cr_tenBit) {
       $cr_r=int($cr_r/1024*256);
       $cr_g=int($cr_g/1024*256);
       $cr_b=int($cr_b/1024*256);
      }
      $cr_size=$calman_win_size if(!$cr_size || $cr_size < 1);
      # Apply any pending settings before showing pattern
      $calman_apply->();
      &clean_pattern_files();
      if($cr_size >= 100) {
       &create_pattern_file("RECTANGLE","$w_s,$h_s",100,"$cr_r,$cr_g,$cr_b","$calman_bg","","","",1,"calman");
      } else {
       my $sqrt_val=sqrt($cr_size/100);
       my $win_w=int($sqrt_val*$max_x);
       my $win_h=int($sqrt_val*$max_y);
       &create_pattern_file("RECTANGLE","$win_w,$win_h",100,"$cr_r,$cr_g,$cr_b","$calman_bg","$position_default","","",1,"calman");
      }
      &send_key_to_client($connection,"");
      last;
     }
     #
     # RGB Pattern Commands (original Calman wire protocol)
     # RGB_B:R,G,B,BG  RGB_S:R,G,B,SIZE  RGB_A:R,G,B
     #
     if($type =~/RGB_/) {
      @el_cmd=split(",",$pattern_cmd);
      $r=int($el_cmd[0]/1024*256);
      $g=int($el_cmd[1]/1024*256);
      $b=int($el_cmd[2]/1024*256);
      if($calman_special_pattern{$key} ne "" &&  -f "$pattern_templates/$calman_special_pattern{$key}") {
       $response=&get_pattern("TESTTEMPLATE","$calman_special_pattern{$key}","","TESTTEMPLATE:$calman_special_pattern{$key}");
       &send_key_to_client($connection,$response);
       &clean_pattern_files();
       last;
      }
      # Apply any pending display mode settings before showing pattern
      $calman_apply->();
      # RGB_B: 4th field is background grey level (10-bit, scale to 8-bit)
      if($type =~/RGB_B/) {
       my $bg_val=int($el_cmd[3]/1024*256);
       $calman_bg="$bg_val,$bg_val,$bg_val";
       &clean_pattern_files();
       &get_pattern($test_template_command,$pattern_dynamic,"$r,$g,$b;$calman_bg","calman");
       &send_key_to_client($connection,"");
       last;
      }
      # RGB_S: 4th field is window size percentage
      if($type =~/RGB_S/) {
       my $win_pct=int($el_cmd[3]);
       $calman_win_size=$win_pct if($win_pct > 0);
       # full field pattern
       if($win_pct >= 100) {
        $pname_file="FullField";
        &clean_pattern_files();
        &create_pattern_file("RECTANGLE","$w_s,$h_s",100,"$r,$g,$b","$calman_bg","","","",1,"calman");
        &send_key_to_client($connection,"");
        last;
       }
       # windowed pattern - calculate dimensions from percentage
       my $sqrt_val=sqrt($win_pct/100);
       my $win_w=int($sqrt_val*$max_x);
       my $win_h=int($sqrt_val*$max_y);
       &clean_pattern_files();
       &create_pattern_file("RECTANGLE","$win_w,$win_h",100,"$r,$g,$b","$calman_bg","$position_default","","",1,"calman");
       &send_key_to_client($connection,"");
       last;
      }
      # Default fallback (e.g. RGB_A)
      &clean_pattern_files();
      &get_pattern($test_template_command,$pattern_dynamic,"$r,$g,$b;$calman_bg","calman");
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
  $calibration_client_ip="";
  $calibration_client_software="";
 }
 $calman{$connection}=0;
 $cmd{$connection}="";
 delete $client_ip{$connection};
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
