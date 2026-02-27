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
 open(CMD_MODETEST,"$modetest 2>/dev/null|");
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
#       Pattern Generator Start Function      #
###############################################
sub pattern_generator_start(@) {
 my $no_clean_files = shift;
 &clean_files() if(!$no_clean_files);
 symlink("running/operations.txt","$var_dir/operations.txt") if(!-l "$var_dir/operations.txt");
 mkdir("$var_dir/running/tmp") if(!-d "$var_dir/running/tmp");
 &auto_select_4k_mode();
 &get_hdmi_info();
 my $pg_bin = $pattern_generator;
 if($pgenerator_conf{"dv_status"} eq "1" && -f "$pattern_generator.dv") {
  $pg_bin = "$pattern_generator.dv";
 }
 system("$pg_bin $w_s $h_s &>/dev/null &");
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
 usleep(500000);
 while(($pid=&process_pid("$pattern_generator","get"))) {
  &process_pid("$pattern_generator","kill");
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
  &process_pid("$program","kill");
  &pattern_generator_start(1) if((&process_pid("$pattern_generator","get")) eq "");
 }
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
 &remove_files("$var_dir/running/tmp/",".*");
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
   open(CMD_TVSERVICE,"$tvservice -e \"$2\" 2>/dev/null|");
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
   open(CMD_TVSERVICE,"$tvservice -e \"CEA $1\" 2>/dev/null|");
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
sub get_cpu () {
 my $idle_old = 0;
 my $total_old = 0;
 open ($STAT,"/proc/stat");
 for($i=0;$i<2;$i++) {
  seek ($STAT, Fcntl::SEEK_SET, 0);
  while (<$STAT>) {
   next unless ("$_" =~ m/^cpu\s+/);
   my @cpu_time_info = split (/\s+/, "$_");
   shift @cpu_time_info;
   my $total = sum(@cpu_time_info);
   my $idle = $cpu_time_info[3];
   my $del_idle = $idle - $idle_old;
   my $del_total = $total - $total_old;
   $usage = 100 * (($del_total - $del_idle)/$del_total);
   $idle_old = $idle;
   $total_old = $total;
  }
  sleep(1) if($i==0);
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
 open(CMD_IP,"ip a|");
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
    open(CMD_BT,"$hcitool dev|");
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
 open(CMD_IP,"$ip addr show dev $interface|");
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
  open(CMD_BT,"$hcitool dev|");
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
 open(CMD_IP,"$ip addr show dev $interface|");
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
   open(TVSERVICE,"$tvservice -l 2>/dev/null|");
   while(<TVSERVICE>) {
    next if(!/Display Number (\d+), type (.*)/);
    system("$tvservice -v $1 -d $info_dir/GET_EDID_INFO_$1.tmp &>/dev/null");
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
  open(CMD_DF,"$df -kh|");
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
  open(CMD_VCGENCMD,"$vcgencmd get_mem gpu|");
  chomp($response=<CMD_VCGENCMD>);
  close(CMD_VCGENCMD);
  $response=~s/gpu=//g;
 }
 if($cmd eq "GET_CORE_VOLTAGE") {
  open(CMD_VCGENCMD,"$vcgencmd measure_volts core|");
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
  open(DMESG,"$dmesg|");
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
 return `$pg_cmd_env="@arg_base64" $sudo_cmd`;
}

###############################################
#              Sync function                  #
###############################################
sub sync(@) {
 system("$sync");
}

###############################################
#         Get Hdmi Info function              #
###############################################
sub get_hdmi_info() {
 my ($response,$res_mode,$selected_mode,$userdef_mode,$range,$output,$ratio,$type)=("");
 my @field=();
 %hash_mode=();
 $preferred_mode="";
 $found=$found_range=$found_output=0;
 if(!$is_kms && $tvservice_is_working) {
  open(CMD_TVSERVICE,"$tvservice -s 2>/dev/stdout|");
  ($response=<CMD_TVSERVICE>)=~s/ x[0-9]\]/\]/;
  close(CMD_TVSERVICE);
  open(CMD_TVSERVICE,"$tvservice -m CEA 2>/dev/null|");
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
  open(CMD_TVSERVICE,"$tvservice -m DMT 2>/dev/null|");
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
  open(CMD_MODETEST,"$modetest 2>/dev/null|");
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
 open(CMD_PARSER,"$edidparser $file|");
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
