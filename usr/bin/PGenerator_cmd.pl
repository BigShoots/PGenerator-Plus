#!/usr/bin/perl
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
# Program: PGenerator_cmd.pl            
# Version: 1.0                         
#########################################
#                Modules                #
#########################################
use Cwd;
use Config;
use Time::HiRes qw(usleep);
use IO::Socket::INET;
use IO::Select;
use Getopt::Long;
use File::Copy;
use File::Basename;
use threads;
use threads::shared;
use MIME::Base64;
use IPC::Open2;
use File::Path;
use Digest::MD5;
use List::Util qw(sum);
use POSIX qw(setsid WNOHANG);

#########################################
#              Shared Dir               #
#########################################
BEGIN { use lib $shared_dir="/usr/share/PGenerator"; }
chdir($shared_dir);

#########################################
#                 My pm                 #
#########################################
do "version.pm"       || die "Error";
do "command.pm"       || die "Error";
do "variables.pm"     || die "Error";
do "conf.pm"          || die "Error";
do "info.pm"          || die "Error";
do "file.pm"          || die "Error";
do "log.pm"           || die "Error";
do "pattern.pm"       || die "Error";
do "daemon.pm"        || die "Error";
do "client.pm"        || die "Error";
do "discovery.pm"     || die "Error";

#########################################
#               Variables               #
#########################################
$i=0;
for(split(" ",$ENV{$pg_cmd_env})) { $ARGV[$i++]=decode_base64($_); }
$action=$ARGV[0];
$0=basename($0)." $action";
$root_video_pid_file="/tmp/PGenerator_video.pid";

#
# main
#
&reboot()                 if($action eq "REBOOT");
&halt()                   if($action eq "HALT");
&set_gpu_memory()         if($action eq "SET_GPU_MEMORY");
&set_cma_memory()         if($action eq "SET_CMA_MEMORY");
&set_boot_memory()        if($action eq "SET_BOOT_MEMORY");
&set_dtoverlay()          if($action eq "SET_DTOVERLAY");
&set_boot_config()        if($action eq "SET_BOOT_CONFIG");
&set_refresh()            if($action eq "SET_REFRESH");
&set_cea_dmt()            if($action eq "SET_CEA_DMT");
&set_hostname()           if($action eq "SET_HOSTNAME");
&set_net_to_use()         if($action eq "SET_NET_TO_USE");
&set_output_range()       if($action eq "SET_OUTPUT_RANGE");
&set_scaling_governor()   if($action eq "SET_SCALING_GOVERNOR");
&set_discoverable()       if($action eq "SET_DISCOVERABLE");
&wifi_status()            if($action eq "GET_WIFI_STATUS");
&wifi_scan()              if($action eq "WIFI_SCAN");
&wifi_set_country()       if($action eq "WIFI_SET_COUNTRY");
&wifi_apply_conf()        if($action eq "WIFI_APPLYCONF");
&wifi_disconnect()        if($action eq "WIFI_DISCONNECT");
&wifi_forget()            if($action eq "WIFI_FORGET");
&wifi_ap_apply_conf()     if($action eq "WIFI_AP_APPLYCONF");
&open_iptables_for_ls()   if($action eq "OPEN_IPTABLES_FOR_LS");
&set_pgenerator_conf()    if($action eq "SET_PGENERATOR_CONF");
&set_plugin()             if($action eq "SET_PLUGIN");
&bash_cmd()               if($action eq "BASH_CMD");
&ensure_ccss_storage()    if($action eq "ENSURE_CCSS_STORAGE");
&play_video_root()        if($action eq "PLAY_VIDEO");
&stop_video_root()        if($action eq "STOP_VIDEO");
&bt_status()              if($action eq "BT_STATUS");
&bt_set_discoverable()    if($action eq "BT_SET_DISCOVERABLE");
&bt_set_powered()         if($action eq "BT_SET_POWERED");
&bt_set_name()            if($action eq "BT_SET_NAME");
&bt_set_pan_ip()          if($action eq "BT_SET_PAN_IP");
&bt_restart_pan()         if($action eq "BT_RESTART_PAN");
&bt_remove_device()       if($action eq "BT_REMOVE_DEVICE");
&bt_set_agent()           if($action eq "BT_SET_AGENT");


#
# functions 
#

###############################################
#             Wifi Scan function              #
###############################################
sub wifi_status (@) {
 my $response = "";
 $interface=$ARGV[1];
 # validation
 $interface=~s/ //g;
 return if($interface eq "");
 chomp($response=`$wpa_cli -i $interface status`);
 print $response;
}

###############################################
#             Wifi Scan function              #
###############################################
sub wifi_scan (@) {
 my $response = "";
 $interface=$ARGV[1];
 # validation
 $interface=~s/ //g;
 return if($interface eq "");
 # Auto-set regulatory domain from wpa_supplicant.conf for 5GHz support
 if(-f $wifi_conf) {
  my $content=&read_from_file($wifi_conf);
  if($content=~/^country=([A-Za-z]{2})/m) {
   my $cc=uc($1);
   system("/usr/sbin/iw reg set $cc 2>/dev/null");
  }
 }
 system("$wpa_cli -i $interface scan &>/dev/null");
 sleep(3);
 $response=`$wpa_cli -i $interface scan_results`;
 print $response;
}

###############################################
#        Wifi Set Country function            #
###############################################
sub wifi_set_country (@) {
 $interface=$ARGV[1];
 my $country=$ARGV[2];
 $interface=~s/ //g;
 $country=~s/[^A-Za-z]//g;
 $country=uc($country);
 return if($interface eq "" || length($country) != 2);
 system("$wpa_cli -i $interface set country $country &>/dev/null");
 system("$wpa_cli -i $interface save_config &>/dev/null");
 system("/usr/sbin/iw reg set $country 2>/dev/null");
 # Also persist in wpa_supplicant.conf
 if(-f $wifi_conf) {
  my $content=&read_from_file($wifi_conf);
  if($content=~/^country=/m) {
   $content=~s/^country=.*/country=$country/m;
  } else {
   $content=~s/(ctrl_interface=.*\n)/$1country=$country\n/;
  }
  &write_file("$wifi_conf.tmp",$wifi_conf,$content);
 }
 system("$wpa_cli -i $interface disconnect &>/dev/null");
 sleep(1);
 system("$wpa_cli -i $interface reconnect &>/dev/null");
 print "OK";
}

###############################################
#          Wifi AP Password function          #
###############################################
sub normalize_hostapd_ap_security (@) {
 my ($content)=@_;
 $content="" if(!defined $content);
 my %wanted=(
  auth_algs=>"1",
  wpa=>"2",
  wpa_key_mgmt=>"WPA-PSK",
  wpa_pairwise=>"CCMP",
  rsn_pairwise=>"CCMP",
  ignore_broadcast_ssid=>"0"
 );
 foreach my $key (qw(auth_algs wpa wpa_key_mgmt wpa_pairwise rsn_pairwise ignore_broadcast_ssid)) {
  if($content=~/^$key=/m) {
   $content=~s/^$key=.*/$key=$wanted{$key}/m;
  } else {
   $content.="\n" if($content ne "" && $content!~/\n$/);
   $content.="$key=$wanted{$key}\n";
  }
 }
 return $content;
}

sub wifi_ap_apply_conf (@) {
 my $response = "";
 $ssid=$ARGV[1];
 $password=$ARGV[2];
 my $content=&read_from_file($hostapd_conf);
 $content=~s/ssid=.*/ssid=$ssid/;
 $content=~s/wpa_passphrase=.*/wpa_passphrase=$password/;
 $content=&normalize_hostapd_ap_security($content);
 &write_file("$hostapd_conf.tmp",$hostapd_conf,$content);
 system("$hostapd_init restart");
}

###############################################
#            Apply Conf function              #
###############################################
sub wifi_apply_conf (@) {
 my ($response,$psk_pass) = "";
 $interface=$ARGV[1];
 $ssid=$ARGV[2];
 $password=$ARGV[3];
 return if($interface eq "");
 $pid = open2($CMD_READ, $CMD_WRITE, "$wpa_passphrase '$ssid'");
 print $CMD_WRITE "$password\n";
 close(CMD_WRITE);
 while(<$CMD_READ>) {
  chomp($_);
  next if(!/psk/ || /#/);
  /psk=(.*)/;
  $psk_pass=$1;
 }
 close(CMD_READ);
 system("$wpa_cli -i $interface remove_network 0 &>/dev/null");
 system("$wpa_cli -i $interface flush &>/dev/null");
 system("$wpa_cli -i $interface add_network 0 &>/dev/null");
 system("$wpa_cli -i $interface set_network 0 ssid '\"$ssid\"' &>/dev/null");
 system("$wpa_cli -i $interface set_network 0 psk $psk_pass &>/dev/null");
 system("$wpa_cli -i $interface enable_network 0 &>/dev/null");
 system("$wpa_cli -i $interface save_config &>/dev/null");
 print $response;
}

###############################################
#           Wifi Disconnect function          #
###############################################
sub wifi_disconnect (@) {
 my $response = "";
 $interface=$ARGV[1];
 $interface=~s/ //g;
 return if($interface eq "");
 system("$wpa_cli -i $interface disconnect &>/dev/null");
 print "OK";
}

sub wifi_forget (@) {
 $interface=$ARGV[1];
 $interface=~s/ //g;
 return if($interface eq "");
 system("$wpa_cli -i $interface remove_network 0 &>/dev/null");
 system("$wpa_cli -i $interface save_config &>/dev/null");
 system("$wpa_cli -i $interface disconnect &>/dev/null");
 print "OK";
}

###############################################
#              Apply Bootloader               #
###############################################
sub apply_bootloader () {
 my $no_reboot = shift;
 $ENV{COPY_ONLY_FILES}=$bootloader_config_file;
 system("$boot_loader_bin");
 return if($no_reboot);
 &reboot();
}

###############################################
#               Reboot function               #
###############################################
sub reboot(@) {
 &persist_meter_settings_legacy();
 &process_pid("$pattern_generator.pl","kill");
 system("$reboot");
}

###############################################
#                Halt function                #
###############################################
sub halt(@) {
 &persist_meter_settings_legacy();
 system("$halt");
}

sub persist_meter_settings_legacy(@) {
 my $src="/var/lib/PGenerator/meter_settings.json";
 my $dst="/usr/share/PGenerator/meter_settings.json";
 return if(!-f $src);
 my $json=&read_from_file($src);
 return if($json eq "" || $json!~/^\{/);
 my $tmp="$dst.tmp";
 if(open(my $fh,">",$tmp)) {
  print $fh $json;
  close($fh);
  chmod 0644, $tmp;
  if(rename($tmp,$dst)) {
   system("timeout 3 $sync >/dev/null 2>&1");
   return;
  }
  unlink($tmp) if(-f $tmp);
 }
}

###############################################
#       Set Discovery Status function         #
###############################################
sub set_discoverable(@) {
 $status=$ARGV[1];
 &write_file($discoverable_disabled_file,"","DISABLED")  if(!$status); 
 unlink($discoverable_disabled_file)                      if($status);
}

###############################################
#          Set dtoverlay function             #
###############################################
sub set_dtoverlay(@) {
 my ($dtoverlay,$enabled)=split(":",$ARGV[1]);
 my $content="";
 $content="dtoverlay=$dtoverlay\n" if($enabled);
 my @row=split("\n",&read_from_file($bootloader_file));
 for(@row) {
  next if(/dtoverlay=$dtoverlay/);
  $content.="$_\n";
 }
 &write_file("$bootloader_file.tmp",$bootloader_file,$content);
 &apply_bootloader();
}

###############################################
#          Set boot config function           #
###############################################
sub set_boot_config(@) {
 my @boot_config=split("\\\\n",$ARGV[1]);
 my @row=split("\n",&read_from_file($bootloader_file));
 my $content="";
 for(@boot_config) { 
  my ($field,$value)=split("=",$_,2);
  next if($value eq "");
  $content.="$_\n";
 }
 foreach my $row (@row) {
  my $find=0;
  for(@boot_config) { 
   my ($field,$value)=split("=",$_,2);
   if($row=~/^$field=/) {
    $find=1;
    last;
   }
  }
  next if($find);
  $content.="$row\n";
 }
 &write_file("$bootloader_file.tmp",$bootloader_file,$content);
 &apply_bootloader();
}

###############################################
#         Set GPU Memory function             #
###############################################
sub set_gpu_memory(@) {
 $g_mem=$ARGV[1];
 # validation
 if($g_mem =~/^64$|^128$|^192$|^256$/) {
  my $content=&read_from_file($bootloader_file);
  $content=~s/\ngpu_mem=.*/\ngpu_mem=$g_mem/;
  &write_file("$bootloader_file.tmp",$bootloader_file,$content);
  &apply_bootloader();
 }
}

###############################################
#         Set CMA Memory function             #
###############################################
sub set_cma_memory(@) {
 my $cma_val=$ARGV[1];
 # validation: 128, 256, 384, 512, or default (remove cma param)
 if($cma_val =~/^default$|^128$|^256$|^384$|^512$/) {
  my $content=&read_from_file($bootloader_file);
  if($cma_val eq "default") {
   $content=~s/dtoverlay=vc4-kms-v3d,cma-\d+/dtoverlay=vc4-kms-v3d/;
  } else {
   if($content=~/dtoverlay=vc4-kms-v3d,cma-\d+/) {
    $content=~s/dtoverlay=vc4-kms-v3d,cma-\d+/dtoverlay=vc4-kms-v3d,cma-$cma_val/;
   } elsif($content=~/dtoverlay=vc4-kms-v3d/) {
    $content=~s/dtoverlay=vc4-kms-v3d/dtoverlay=vc4-kms-v3d,cma-$cma_val/;
   }
  }
  &write_file("$bootloader_file.tmp",$bootloader_file,$content);
  &apply_bootloader();
 }
}

###############################################
#       Set Boot Memory function              #
#  Sets gpu_mem and CMA in one operation      #
###############################################
sub set_boot_memory(@) {
 my $gpu_val=$ARGV[1];
 my $cma_val=$ARGV[2];
 my $changed=0;
 my $content=&read_from_file($bootloader_file);
 # Set gpu_mem
 if($gpu_val =~/^64$|^128$|^192$|^256$/) {
  $content=~s/\ngpu_mem=.*/\ngpu_mem=$gpu_val/;
  $changed=1;
 }
 # Set CMA overlay parameter
 if($cma_val =~/^default$|^128$|^256$|^384$|^512$/) {
  if($cma_val eq "default") {
   $content=~s/dtoverlay=vc4-kms-v3d,cma-\d+/dtoverlay=vc4-kms-v3d/;
  } else {
   if($content=~/dtoverlay=vc4-kms-v3d,cma-\d+/) {
    $content=~s/dtoverlay=vc4-kms-v3d,cma-\d+/dtoverlay=vc4-kms-v3d,cma-$cma_val/;
   } elsif($content=~/dtoverlay=vc4-kms-v3d/) {
    $content=~s/dtoverlay=vc4-kms-v3d/dtoverlay=vc4-kms-v3d,cma-$cma_val/;
   }
  }
  $changed=1;
 }
 if($changed) {
  &write_file("$bootloader_file.tmp",$bootloader_file,$content);
  &apply_bootloader();
 }
}

###############################################
#            Set CEA DMT function             #
###############################################
sub set_cea_dmt(@) {
 my $group_mode=$ARGV[1];
 &set_refresh($group_mode);
 &reboot();
}

###############################################
#            Set Refresh function             #
###############################################
sub set_refresh(@) {
 my ($group,$mode)=split(" ",$ARGV[1]);
 my $group_n="1";
 $group_n="2" if($group eq "DMT");
 # validation
 if($group =~/^CEA$|^DMT$/) {
  my $content=&read_from_file($bootloader_file);
  $content=~s/\nhdmi_group=.*/\nhdmi_group=$group_n/g;
  $content=~s/\nhdmi_mode=.*/\nhdmi_mode=$mode/g;
  &write_file("$bootloader_file.tmp",$bootloader_file,$content);
  &apply_bootloader(1);
 }
}

###############################################
#           Set Hostname  function           #
###############################################
sub set_hostname(@) {
 $host_name=$ARGV[1];
 # validation
 if($host_name ne "") {
  open(CMD_HOSTNAME,"|$pkg --set_hostname");
  print CMD_HOSTNAME $host_name;
  close(CMD_HOSTNAME);
 }
}

###############################################
#          Set Output Range Function          #
###############################################
sub set_output_range(@) {
 $o_range=$ARGV[1];
 # validation
 if($o_range =~/^0$|^1$|^2$|^3$|^4$/) {
  my $content=&read_from_file($bootloader_file);
  $content=~s/\nhdmi_pixel_encoding=.*/\nhdmi_pixel_encoding=$o_range/g;
  &write_file("$bootloader_file.tmp",$bootloader_file,$content);
  &apply_bootloader();
 }
}

###############################################
#          Set Output Range Function          #
###############################################
sub set_scaling_governor(@) {
 %found_scal=();
 $scal=$ARGV[1];
 $all_scal=&read_from_file("$scaling_available_file");
 chomp($all_scal);
 @el_scal=split(" ",$all_scal);
 for(@el_scal) {
  $found_scal{$_}=1;
 }
 # validation
 if($found_scal{$scal}) {
  ($scaling_file_perl=$scaling_file)=~s/\//\//g;
  my $content=&read_from_file($rcPGenerator_default_file);
  $content=~s/.*SCALING_GOVERNOR.*/SCALING_GOVERNOR=\"$scal\"/;
  $content="SCALING_GOVERNOR=\"$scal\"" if($content !~/.*SCALING_GOVERNOR.*/);
  &write_file("$rcPGenerator_default_file.tmp",$rcPGenerator_default_file,$content);
  &write_file($scaling_file,$scaling_file,$scal);
 }
}

###############################################
#            Set Net To Use Function          #
###############################################
sub set_net_to_use(@) {
 my $net_start=$ARGV[1];
 my $net_subclass=$ARGV[2];
 my $net_to_use=$ARGV[3];
 my @subclass=split(",",$net_subclass);
 # change pand default file
 open(DEFAULT_PAND_FILE,">$pand_default_file");
 print DEFAULT_PAND_FILE "PAND_NET=\"$net_start.$net_to_use.$subclass[1]\"";
 close(DEFAULT_PAND_FILE);
 # change rcPGenerator config file
 my $content=&read_from_file($rcPGenerator_default_file);
 $content=~s/.*AP_NET=.*/AP_NET=\"$net_start.$net_to_use.$subclass[0]\"/;
 $content=~s/.*PAND_NET=.*/PAND_NET=\"$net_start.$net_to_use.$subclass[1]\"/;
 $content=~s/.*USB_NET=.*/USB_NET=\"$net_start.$net_to_use.$subclass[2]\"/;
 $content=~s/.*DIRECT_NET=.*/DIRECT_NET=\"$net_start.$net_to_use.$subclass[3]\"/ if($subclass[3] ne "");
 &write_file("$rcPGenerator_default_file.tmp",$rcPGenerator_default_file,$content);
 # reboot
 &reboot();
}

###############################################
#       Open iptables For LS Function         #
###############################################
sub open_iptables_for_ls(@) {
 my $ip_ls=$ARGV[1];
 my $port_ls=$ARGV[2];
 my ($found,$ip_is_not_local) = (0,0);
 # validation
 return "" if($ip_ls eq "" || $port_ls eq "");
 open(IP,"$ip route get $ip_ls|");
 while(<IP>) {
  if(/ via /) {
   $ip_is_not_local=1;
   last;
  }
 }
 close(IP);
 return "" if($ip_is_not_local);
 system("$iptables -C OUTPUT -p tcp -d $ip_ls --dport $port_ls -j ACCEPT 2>/dev/null");
 return if(!$?);
 system("$iptables -I OUTPUT -p tcp -d $ip_ls/32 --dport $port_ls -j ACCEPT");
}

###############################################
#       Set PGenerator Conf Function          #
###############################################
sub set_pgenerator_conf (@) {
 my $var_to_set = $ARGV[1];
 my $value = $ARGV[2];
 my $content = "";
 return print $error_response if($var_to_set =~/^(ip_pattern|^port_pattern)$/);
 open(CONF,"$pattern_conf");
 while(<CONF>) {
  next if (/^$var_to_set=/);
  $content.=$_;
 }
 chomp($content);
 $content.="\n$var_to_set=$value" if($value ne "");
 &write_file("$pattern_conf.tmp","$pattern_conf","$content\n");
 print $ok_response;
}

###############################################
#             Set Plugin Function             #
###############################################
sub set_plugin (@) {
 my $f_tmp_name = $ARGV[1];
 my $f_name = $ARGV[2];
 my $f_where = $ARGV[3];
 my $script = $ARGV[4];
 my $ctx = Digest::MD5->new;
 open(PLUGIN,"<:raw",$f_tmp_name);
 $ctx->addfile(*PLUGIN);
 close(PLUGIN);
 my $digest = $ctx->hexdigest;
 return print $error_response if(!$plugin_permitted{$digest});
 return print $error_response if($f_name !~/$plugin_archive_file/);
 system("$tar zxf $f_tmp_name -C $upload_tmp_dir 2>/dev/null");
 return print $error_response if($? != 0);
 chdir("$plugin_dir") || return print $error_response;
 open(CONF,"$plugin_conf_file");
 while(<CONF>) {
  chomp($_);
  $_=~s/\r//g;
  $do_reboot=1        if(/^reboot=yes/);
  $do_bootloader=1    if(/^bootloader=yes/);
  $plugin_name=$1 if(/^name=(.*)/);
 }
 close(CONF);
 if(-f "$script") {
  system("./$script &>/dev/null");
  return print $error_response if($? != 0);
 }
 chdir($shared_dir);
 rmtree($plugin_dir) || return print $error_response;
 rename($f_tmp_name,&get_destination($f_where)."/$plugin_name") if($script eq "install.sh");
 unlink("$f_tmp_name")                                          if($script eq "uninstall.sh");
 &apply_bootloader(1)  if($do_bootloader);
 &reboot()             if($do_reboot);
 print $ok_response;
}

###############################################
#             Pkg Update Function             #
###############################################
sub bash_cmd(@) {
 my $cmd = $ARGV[1];
 my $argument = $ARGV[2];
 my $ris_cmd = "";
 if($cmd eq "PKG_UPDATE") {
  if (`$pkg --check_for_update=all --no_restart 2>/dev/stderr` =~/need to be updated/) {
   system("$setsid $pkg --check_for_update=all --update -force_answer=n --skip_installed_from_check 1>/dev/stderr");
   print STDERR "The device will reboot, press enter to continue...";
   <STDIN>;
   print "REBOOT";
   &reboot();
  } else {
   print STDERR "No packages to update\n\n";
  }
 }
 if($cmd eq "PGPLUS_CHECK") {
  my $out=`/usr/sbin/pgenerator-update check 2>/dev/null`;
  chomp($out);
  print $out;
 }
 if($cmd eq "PGPLUS_APPLY") {
  my $out=`/usr/sbin/pgenerator-update apply 2>/dev/null`;
  chomp($out);
  print $out;
 }
 if($cmd eq "SAVE_METER_SETTINGS") {
  my $path="/usr/share/PGenerator/meter_settings.json";
  my $tmp="$path.tmp";
  if(open(my $fh,">",$tmp)) {
   print $fh $argument;
   close($fh);
   chmod 0644, $tmp;
   if(rename($tmp,$path)) {
    system("timeout 3 $sync >/dev/null 2>&1");
    print "OK";
   } else {
    unlink($tmp) if(-f $tmp);
    print "ERR";
   }
  } else {
   unlink($tmp) if(-f $tmp);
   print "ERR";
  }
 }
 system("$passwd $argument 1>/dev/stderr")                             if($cmd eq "CHANGE_PASSWORD");
 system("$perl -p -i -e \"s/$distro_name.*/$argument/\" $distro_conf") if($cmd eq "PKG_SUBSCRIBE");
}

sub ensure_ccss_storage(@) {
 my $dir=$ARGV[1]||"";
 $dir=~s{/+}{/}g;
 return if($dir ne "/var/lib/PGenerator/ccss/custom" && $dir ne "/usr/share/PGenerator/ccss/custom");
 eval {
  File::Path::make_path($dir) if(!-d $dir);
  my $uid=getpwnam("pgenerator");
  my $gid=getgrnam("pgenerator");
  if($dir eq "/var/lib/PGenerator/ccss/custom") {
   my $parent="/var/lib/PGenerator/ccss";
   File::Path::make_path($parent) if(!-d $parent);
   chown($uid,$gid,$parent) if(defined($uid) && defined($gid));
   chmod(0775,$parent);
  }
  chown($uid,$gid,$dir) if(defined($uid) && defined($gid));
  chmod(0775,$dir);
 };
 print((-d $dir && -w $dir) ? "OK" : "ERR");
}

###############################################
#             Root Video Functions            #
###############################################
sub stop_video_root_process (@) {
 my $program = shift;
 my $program_name=basename($program || "");
 my $pid="";
 if(-f $root_video_pid_file) {
  open(PID,"$root_video_pid_file");
  $pid=<PID>;
  close(PID);
  chomp($pid);
  if($pid =~ /^\d+$/) {
   kill("TERM",-$pid);
   usleep(250000);
   kill("KILL",-$pid);
  }
  unlink($root_video_pid_file);
 }
 if($program_name =~ /^omxplayer(\.bin)?$/) {
    system("/usr/bin/pkill","-TERM","-x","omxplayer");
    system("/usr/bin/pkill","-TERM","-x","omxplayer.bin");
  usleep(250000);
    system("/usr/bin/pkill","-KILL","-x","omxplayer");
    system("/usr/bin/pkill","-KILL","-x","omxplayer.bin");
 }
 if($program_name eq "pg_diag_video_player") {
  for my $name ("pg_diag_video_player","ffmpeg","drm_player","fb_player","omxplayer","omxplayer.bin") {
   system("/usr/bin/pkill","-TERM","-x",$name);
  }
  usleep(250000);
  for my $name ("pg_diag_video_player","ffmpeg","drm_player","fb_player","omxplayer","omxplayer.bin") {
   system("/usr/bin/pkill","-KILL","-x",$name);
  }
 }
}

sub root_video_error_message (@) {
 my $log_file="/tmp/omxplayer.log";
 my $log_content="";
 return "Video playback failed to start" if(!-f $log_file);
 $log_content=&read_from_file($log_file);
 return "Video playback backend unavailable on this image (OpenMAX init failed)" if($log_content =~ /OMXCore failed to init|OMX\.broadcom\.clock/i);
 return $1 if($log_content =~ /([^\r\n]+)\s*$/ && $1 !~ /^have a nice day/i);
 return "Video playback failed to start";
}

sub play_video_root (@) {
 my $program_name=basename($ARGV[1] || "");
 my $video=$ARGV[2];
 my $duration=$ARGV[3];
 my $repeat=$ARGV[4];
 my $program_path="/usr/bin/$program_name";
 my $log_file="/tmp/omxplayer.log";
 my $video_path="";
 my $pid=0;
 my $status="";
 my ($status_read,$status_write);
 return print "ERR:Video playback failed to start" if($program_name !~ /^(?:omxplayer(?:\.bin)?|pg_diag_video_player)$/);
 if($program_name eq "pg_diag_video_player") {
  $program_path="/usr/sbin/pg_diag_video_player";
 } else {
  $program_path="/usr/bin/omxplayer" if(-x "/usr/bin/omxplayer");
 }
 return print "ERR:Video playback failed to start" if(!-x $program_path);
 return print "ERR:Video playback failed to start" if(!defined $video || $video eq "");
 return print "ERR:Video playback failed to start" if($video =~ /(^\/|\.\.|[\r\n\0])/);
 return print "ERR:Video playback failed to start" if($video !~ /^[A-Za-z0-9 _\.\-\/()]+$/);
 return print "ERR:Video playback failed to start" if(!defined $duration || $duration !~ /^\d+[smhd]?$/);
 $repeat=0 if(!defined $repeat || $repeat ne "1");
 $video_path="$video_dir/$video";
 return print "ERR:Video playback failed to start" if(!-f $video_path);
 return print "ERR:Video playback failed to start" if(!pipe($status_read,$status_write));
 &stop_video_root_process($program_name);
 unlink($log_file);
 $pid=fork();
 return print "ERR:Video playback failed to start" if(!defined $pid);
 if($pid == 0) {
  my $status_sent=0;
  my $play_pid=0;
  my $wait_pid=0;
  close($status_read);
  eval { setsid(); };
  $SIG{"TERM"}=sub { exit 0; };
  open(STDIN,"</dev/null");
    open(STDOUT,">>$log_file");
    open(STDERR,">&STDOUT");
  while(1) {
   $play_pid=fork();
   if(!defined $play_pid) {
    print $status_write "ERR:Video playback failed to start\n" if(!$status_sent);
    close($status_write) if(!$status_sent);
    exit 1;
   }
   if($play_pid == 0) {
    if($program_name eq "pg_diag_video_player") {
     my $width=$ARGV[5] || "";
     my $height=$ARGV[6] || "";
     exec($timeout,"-k","$duration","$duration","$program_path","$video_path","$width","$height");
    }
    exec($timeout,"-k","$duration","$duration","$program_path","$video_path");
    exit 127;
   }
   usleep(2500000);
   $wait_pid=waitpid($play_pid,WNOHANG);
   if($wait_pid == 0) {
    if(!$status_sent) {
     print $status_write "OK\n";
     close($status_write);
     $status_sent=1;
    }
    waitpid($play_pid,0);
   } else {
    if(!$status_sent) {
     print $status_write "ERR:".&root_video_error_message()."\n";
     close($status_write);
    }
    exit 1 if(!$status_sent);
   }
   last if((($? >> 8) == 143) || !$repeat);
  }
  close($status_write) if(!$status_sent);
  exit 0;
 }
 close($status_write);
 if(open(PID,">$root_video_pid_file")) {
  print PID $pid;
  close(PID);
 }
 eval {
  local $SIG{ALRM}=sub { die "status timeout\n"; };
  alarm(5);
  $status=<$status_read>;
  alarm(0);
 };
 alarm(0);
 close($status_read);
 chomp($status) if(defined $status);
 if(!defined $status || $status eq "" || $status !~ /^OK$/) {
  &stop_video_root_process($program_name);
  $status=~s/^ERR:// if(defined $status);
  $status="Video playback failed to start" if(!defined $status || $status eq "");
  return print "ERR:$status";
 }
 print "OK";
}

sub stop_video_root (@) {
 &stop_video_root_process($ARGV[1]);
 print "OK";
}

###############################################
#           Bluetooth PAN Functions           #
###############################################
sub bt_status (@) {
 my $hci=`/usr/bin/hciconfig $hci_interface 2>/dev/null`;
 my $adapter=`/usr/bin/bluez-test-adapter list 2>/dev/null`;
 my $devices=`/usr/bin/bluez-test-device list 2>/dev/null`;
 my $pan_ip=`/sbin/ifconfig $bt_interface 2>/dev/null`;
 my $pan_net="";
 if(-f $pand_default_file) {
  my $pf=&read_from_file($pand_default_file);
  ($pan_net)=$pf=~/PAND_NET="([^"]*)"/;
 }
 $pan_net="10.10.11" if($pan_net eq "");
 my $agent_running=`ps aux 2>/dev/null | grep pgenerator-bt-agent | grep -v grep`;
 chomp($agent_running);
 my $agent_status=($agent_running ne "")?"1":"0";
 print "HCI_BEGIN\n$hci\nHCI_END\n";
 print "ADAPTER_BEGIN\n$adapter\nADAPTER_END\n";
 print "DEVICES_BEGIN\n$devices\nDEVICES_END\n";
 print "PAN_BEGIN\n$pan_ip\nPAN_END\n";
 print "PAND_NET=$pan_net\n";
 print "AGENT=$agent_status\n";
}

sub bt_set_discoverable (@) {
 my $val=$ARGV[1];
 if($val eq "on" || $val eq "off") {
  system("/usr/bin/bluez-test-adapter discoverable $val");
  print $ok_response;
 } else {
  print $error_response;
 }
}

sub bt_set_powered (@) {
 my $val=$ARGV[1];
 if($val eq "on" || $val eq "off") {
  if($val eq "on") {
   system("/usr/bin/hciconfig $hci_interface up");
   system("/usr/bin/bluez-test-adapter powered on");
  } else {
   system("/usr/bin/bluez-test-adapter powered off");
   system("/usr/bin/hciconfig $hci_interface down");
  }
  print $ok_response;
 } else {
  print $error_response;
 }
}

sub bt_set_name (@) {
 my $name=$ARGV[1];
 $name=~s/[^a-zA-Z0-9_ -]//g;
 if($name ne "") {
  system("/usr/bin/hciconfig $hci_interface name '$name'");
  print $ok_response;
 } else {
  print $error_response;
 }
}

sub bt_set_pan_ip (@) {
 my $net=$ARGV[1];
 if($net=~/^\d{1,3}\.\d{1,3}\.\d{1,3}$/) {
  open(DEFAULT_PAND_FILE,">$pand_default_file");
  print DEFAULT_PAND_FILE "PAND_NET=\"$net\"\n";
  close(DEFAULT_PAND_FILE);
  system("/etc/init.d/pand restart");
  print $ok_response;
 } else {
  print $error_response;
 }
}

sub bt_restart_pan (@) {
 system("/etc/init.d/pand restart");
 print $ok_response;
}

sub bt_remove_device (@) {
 my $mac=$ARGV[1];
 if($mac=~/^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/) {
  system("/usr/bin/bluez-test-device remove $mac");
  print $ok_response;
 } else {
  print $error_response;
 }
}

sub bt_set_agent (@) {
 my $val=$ARGV[1];
 my $agent="/usr/bin/pgenerator-bt-agent";
 if($val eq "on") {
  system("pkill -f pgenerator-bt-agent 2>/dev/null");
  sleep(1);
  system("setsid $agent </dev/null >/dev/null 2>&1 &");
  sleep(2);
  my $check=`ps aux 2>/dev/null | grep pgenerator-bt-agent | grep -v grep`;
  chomp($check);
  if($check ne "") {
   print $ok_response;
  } else {
   print $error_response;
  }
 } elsif($val eq "off") {
  system("pkill -f pgenerator-bt-agent 2>/dev/null");
  print $ok_response;
 } else {
  print $error_response;
 }
}
