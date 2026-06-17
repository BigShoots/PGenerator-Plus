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
&wifi_ap_status()         if($action eq "WIFI_AP_STATUS");
&wifi_ap_enable()         if($action eq "WIFI_AP_ENABLE");
&wifi_ap_disable()        if($action eq "WIFI_AP_DISABLE");
&open_iptables_for_ls()   if($action eq "OPEN_IPTABLES_FOR_LS");
&set_pgenerator_conf()    if($action eq "SET_PGENERATOR_CONF");
&set_plugin()             if($action eq "SET_PLUGIN");
&bash_cmd()               if($action eq "BASH_CMD");
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

sub pgen_cmd_exists(@) {
 my $cmd=shift;
 return (defined $cmd && $cmd ne "" && -x $cmd) ? 1 : 0;
}

sub pgen_capture(@) {
 my @cmd=@_;
 return "" if(!@cmd || !&pgen_cmd_exists($cmd[0]));
 my $response="";
 if(open(my $fh,"-|",@cmd)) {
  while(<$fh>) { $response.=$_; }
  close($fh);
 }
 return $response;
}

sub pgen_system_quiet(@) {
 my @cmd=@_;
 return 127 if(!@cmd || !&pgen_cmd_exists($cmd[0]));
 my $pid=fork();
 return system(@cmd) if(!defined $pid);
 if($pid==0) {
  open(STDOUT,">","/dev/null");
  open(STDERR,">","/dev/null");
  exec @cmd;
  exit 127;
 }
 waitpid($pid,0);
 return $? >> 8;
}

sub pgen_service_action(@) {
 my ($init,$service,$verb)=@_;
 if(defined $init && $init ne "" && -x $init) {
  return &pgen_system_quiet($init,$verb);
 }
 if(defined $systemctl && &pgen_cmd_exists($systemctl) && defined $service && $service ne "") {
  return &pgen_system_quiet($systemctl,$verb,$service);
 }
 if(defined $service_cmd && &pgen_cmd_exists($service_cmd) && defined $service && $service ne "") {
  return &pgen_system_quiet($service_cmd,$service,$verb);
 }
 return 127;
}

sub pgen_service_active(@) {
 my ($process,$service)=@_;
 if(defined $systemctl && &pgen_cmd_exists($systemctl) && defined $service && $service ne "") {
  my $active=&pgen_capture($systemctl,"is-active",$service);
  chomp($active);
  return 1 if($active eq "active");
 }
 my $ps=`ps aux 2>/dev/null`;
 return ($ps=~/\b\Q$process\E\b/) ? 1 : 0;
}

sub pgen_service_exists(@) {
 my $service=shift;
 return 0 if(!defined $service || $service eq "");
 my $unit=($service=~/\.service$/) ? $service : "$service.service";
 my $init=$service;
 $init=~s/\.service$//;
 return 1 if(-e "/etc/systemd/system/$unit" || -e "/lib/systemd/system/$unit");
 return 1 if(-x "/etc/init.d/$init");
 return 0;
}

sub ensure_wifi_conf(@) {
 my $dir=dirname($wifi_conf);
 mkpath($dir) if(!-d $dir);
 if(!-f $wifi_conf) {
  my $content="ctrl_interface=DIR=$dir_wpa GROUP=pgenerator\nupdate_config=1\ncountry=US\n";
  &write_file("$wifi_conf.tmp",$wifi_conf,$content);
  chmod 0600, $wifi_conf if(-f $wifi_conf);
  return;
 }
 my $content=&read_from_file($wifi_conf);
 if($content!~/^ctrl_interface=/m) {
  $content="ctrl_interface=DIR=$dir_wpa GROUP=pgenerator\n".$content;
 } else {
  $content=~s|^ctrl_interface=.*|ctrl_interface=DIR=$dir_wpa GROUP=pgenerator|m;
 }
 if($content!~/^update_config=/m) {
  $content.="\n" if($content!~/\n$/);
  $content.="update_config=1\n";
 }
 &write_file("$wifi_conf.tmp",$wifi_conf,$content);
 chmod 0600, $wifi_conf if(-f $wifi_conf);
}

sub ensure_wlan_client_ready(@) {
 my $interface=shift;
 &ensure_wifi_conf();
 &pgen_system_quiet($rfkill,"unblock","wifi") if(defined $rfkill && &pgen_cmd_exists($rfkill));
 &pgen_system_quiet($ip,"link","set",$interface,"up") if(defined $ip && &pgen_cmd_exists($ip));
 &pgen_service_action("","wpa_supplicant","start");
 if(defined $wpa_supplicant && &pgen_cmd_exists($wpa_supplicant) && !-S "$dir_wpa/$interface") {
  &pgen_system_quiet($wpa_supplicant,"-B","-i",$interface,"-c",$wifi_conf);
 }
}

sub wifi_ipv4(@) {
 my $interface=shift;
 return "" if(!defined $interface || $interface eq "");
 if(defined $ip && &pgen_cmd_exists($ip)) {
  my $addr=&pgen_capture($ip,"-o","-4","addr","show","dev",$interface,"scope","global");
  foreach my $line (split(/\n/,$addr)) {
   return $1 if($line=~/\sinet\s+(\d+\.\d+\.\d+\.\d+)\/\d+/);
  }
 } elsif(defined $ifconfig && &pgen_cmd_exists($ifconfig)) {
  my $addr=&pgen_capture($ifconfig,$interface);
  return $1 if($addr=~/inet\s+(?:addr:)?(\d+\.\d+\.\d+\.\d+)/);
 }
 return "";
}

sub wifi_dhcp_process_running(@) {
 my $interface=shift;
 return 0 if(!defined $interface || $interface eq "");
 my $ps=`ps aux 2>/dev/null`;
 return ($ps=~/\bdhclient\b[^\n]*\b\Q$interface\E\b/ || $ps=~/\bdhcpcd\b[^\n]*\b\Q$interface\E\b/ || $ps=~/\budhcpc\b[^\n]*\b\Q$interface\E\b/) ? 1 : 0;
}

sub wifi_set_route_metric(@) {
 my ($interface,$metric)=@_;
 return if(!defined $interface || $interface eq "" || !defined $metric || $metric eq "");
 return if(!defined $ip || !&pgen_cmd_exists($ip));
 my $routes=&pgen_capture($ip,"-o","route","show","default","dev",$interface);
 foreach my $line (split(/\n/,$routes)) {
  next if($line !~ /\bvia\s+(\d+\.\d+\.\d+\.\d+)/);
  my $gateway=$1;
  &pgen_system_quiet($ip,"route","del","default","via",$gateway,"dev",$interface);
  &pgen_system_quiet($ip,"route","replace","default","via",$gateway,"dev",$interface,"metric",$metric);
 }
}

sub wifi_start_dhcp(@) {
 my ($interface,$wait_seconds)=@_;
 $wait_seconds=0 if(!defined $wait_seconds);
 my $addr=&wifi_ipv4($interface);
 if($addr ne "") {
  &wifi_set_route_metric($interface,600) if($interface ne $eth_interface);
  return $addr;
 }
 return "" if(!defined $interface || $interface eq "");

 if(defined $dhclient && &pgen_cmd_exists($dhclient)) {
  if($wait_seconds > 0 && defined $timeout && &pgen_cmd_exists($timeout)) {
   &pgen_system_quiet($timeout,"$wait_seconds",$dhclient,"-1","-q",$interface);
  } elsif(!&wifi_dhcp_process_running($interface)) {
   &pgen_system_quiet($dhclient,"-nw",$interface);
  }
 } elsif(defined $dhcpcd && &pgen_cmd_exists($dhcpcd)) {
  if($wait_seconds > 0 && defined $timeout && &pgen_cmd_exists($timeout)) {
   &pgen_system_quiet($timeout,"$wait_seconds",$dhcpcd,"-n",$interface);
  } elsif(!&wifi_dhcp_process_running($interface)) {
   &pgen_system_quiet($dhcpcd,"-n",$interface);
  }
 } elsif(defined $udhcpc && &pgen_cmd_exists($udhcpc)) {
  if($wait_seconds > 0 && defined $timeout && &pgen_cmd_exists($timeout)) {
   &pgen_system_quiet($timeout,"$wait_seconds",$udhcpc,"-i",$interface,"-q");
  } elsif(!&wifi_dhcp_process_running($interface)) {
   &pgen_system_quiet($udhcpc,"-i",$interface,"-q","-b");
  }
 }

 $addr=&wifi_ipv4($interface);
 &wifi_set_route_metric($interface,600) if($addr ne "" && $interface ne $eth_interface);
 return $addr;
}

sub wifi_release_dhcp(@) {
 my $interface=shift;
 return if(!defined $interface || $interface eq "");
 &pgen_system_quiet($dhclient,"-r",$interface) if(defined $dhclient && &pgen_cmd_exists($dhclient));
 &pgen_system_quiet($dhcpcd,"-k",$interface) if(defined $dhcpcd && &pgen_cmd_exists($dhcpcd));
 &pgen_system_quiet($ip,"addr","flush","dev",$interface,"scope","global") if(defined $ip && &pgen_cmd_exists($ip));
}

sub wifi_wait_completed(@) {
 my ($interface,$ssid,$seconds)=@_;
 $seconds=15 if(!defined $seconds || $seconds <= 0);
 my $tries=$seconds*2;
 for(my $i=0;$i<$tries;$i++) {
  my $status=&pgen_capture($wpa_cli,"-i",$interface,"status");
  my $state="";
  my $connected_ssid="";
  $state=$1 if($status=~/^wpa_state=(.*)$/m);
  $connected_ssid=$1 if($status=~/^ssid=(.*)$/m);
  return 1 if($state eq "COMPLETED" && (!defined $ssid || $ssid eq "" || $connected_ssid eq $ssid));
  usleep(500000);
 }
 return 0;
}

###############################################
#             Wifi Scan function              #
###############################################
sub wifi_status (@) {
 my $response = "";
 $interface=$ARGV[1];
 # validation
 $interface=~s/ //g;
 return if($interface eq "");
 if(!&pgen_cmd_exists($wpa_cli)) {
  print "PGEN_ERROR=wpa_cli not found\n";
  return;
 }
 &ensure_wlan_client_ready($interface);
 $response=&pgen_capture($wpa_cli,"-i",$interface,"status");
 chomp($response);
 my $has_ip=($response=~/^ip_address=/m) ? 1 : 0;
 my $state="";
 $state=$1 if($response=~/^wpa_state=(.*)$/m);
 if($state eq "COMPLETED" && $has_ip) {
  &wifi_set_route_metric($interface,600) if($interface ne $eth_interface);
 } elsif($state eq "COMPLETED" && !$has_ip) {
  my $addr=&wifi_ipv4($interface);
  $addr=&wifi_start_dhcp($interface,5) if($addr eq "");
  $addr=&wifi_start_dhcp($interface,0) if($addr eq "");
  if($addr ne "") {
   $response.="\n" if($response ne "" && $response!~/\n$/);
   $response.="ip_address=$addr";
  }
 }
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
 if(!&pgen_cmd_exists($wpa_cli)) {
  print "PGEN_ERROR=wpa_cli not found\n";
  return;
 }
 &ensure_wlan_client_ready($interface);
 # Auto-set regulatory domain from wpa_supplicant.conf for 5GHz support
 if(-f $wifi_conf) {
  my $content=&read_from_file($wifi_conf);
  if($content=~/^country=([A-Za-z]{2})/m) {
   my $cc=uc($1);
   &pgen_system_quiet($iw,"reg","set",$cc) if(defined $iw && &pgen_cmd_exists($iw));
  }
 }
 &pgen_system_quiet($wpa_cli,"-i",$interface,"scan");
 sleep(3);
 $response=&pgen_capture($wpa_cli,"-i",$interface,"scan_results");
 if($response=~/^FAIL/m || $response eq "") {
  print "PGEN_ERROR=WiFi scan failed\n$response";
  return;
 }
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
 return print "ERR" if(!&pgen_cmd_exists($wpa_cli));
 &ensure_wlan_client_ready($interface);
 &pgen_system_quiet($wpa_cli,"-i",$interface,"set","country",$country);
 &pgen_system_quiet($wpa_cli,"-i",$interface,"save_config");
 &pgen_system_quiet($iw,"reg","set",$country) if(defined $iw && &pgen_cmd_exists($iw));
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
 &pgen_system_quiet($wpa_cli,"-i",$interface,"disconnect");
 sleep(1);
 &pgen_system_quiet($wpa_cli,"-i",$interface,"reconnect");
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

sub pgen_ap_net(@) {
 my $ap_net="10.10.10";
 if(-f $rcPGenerator_default_file) {
  my $content=&read_from_file($rcPGenerator_default_file);
  if($content=~/^AP_NET="?([0-9]+\.[0-9]+\.[0-9]+)"?/m) {
   $ap_net=$1;
  }
 }
 return $ap_net;
}

sub hostapd_conf_value(@) {
 my ($key,$default)=@_;
 return $default if(!-f $hostapd_conf);
 my $content=&read_from_file($hostapd_conf);
 return $1 if($content=~/^\Q$key\E=(.*)$/m);
 return $default;
}

sub update_hostapd_conf(@) {
 my ($ssid,$password,$interface)=@_;
 my $content=&read_from_file($hostapd_conf);
 $content="interface=$interface\ndriver=nl80211\nhw_mode=g\nchannel=11\nssid=$ssid\nwpa_passphrase=$password\n" if($content eq "");
 $content=~s/^interface=.*/interface=$interface/m if(defined $interface && $interface ne "");
 $content=~s/^ssid=.*/ssid=$ssid/m if(defined $ssid && $ssid ne "");
 $content=~s/^wpa_passphrase=.*/wpa_passphrase=$password/m if(defined $password && $password ne "");
 $content=&normalize_hostapd_ap_security($content);
 mkpath(dirname($hostapd_conf)) if(!-d dirname($hostapd_conf));
 &write_file("$hostapd_conf.tmp",$hostapd_conf,$content);
}

sub configure_dnsmasq_ap(@) {
 my ($interface,$ap_net)=@_;
 return 1 if(!defined $dnsmasq_bin || !&pgen_cmd_exists($dnsmasq_bin));
 my $dir="/etc/dnsmasq.d";
 mkpath($dir) if(!-d $dir);
 my $conf="$dir/pgenerator-ap.conf";
 my $content="interface=$interface\nbind-dynamic\ndhcp-range=$ap_net.50,$ap_net.150,255.255.255.0,12h\ndhcp-option=3,$ap_net.1\ndhcp-option=6,$ap_net.1\n";
 if(open(my $fh,">",$conf)) {
  print $fh $content;
  close($fh);
 }
 &pgen_service_action("","dnsmasq","restart");
 return 1;
}

sub wifi_ap_gateway_ready(@) {
 my ($interface,$ap_net)=@_;
 return 0 if(!defined $interface || $interface eq "" || !defined $ap_net || $ap_net eq "");
 if(defined $ip && &pgen_cmd_exists($ip)) {
  my $addr=&pgen_capture($ip,"-o","-4","addr","show","dev",$interface);
  return 1 if($addr=~/\b\Q$ap_net\E\.1\/24\b/);
 } elsif(defined $ifconfig && &pgen_cmd_exists($ifconfig)) {
  my $addr=&pgen_capture($ifconfig,$interface);
  return 1 if($addr=~/\b\Q$ap_net\E\.1\b/);
 }
 return 0;
}

sub wifi_ap_ensure_gateway(@) {
 my ($interface,$ap_net)=@_;
 return 0 if(!defined $interface || $interface eq "" || !defined $ap_net || $ap_net eq "");
 &pgen_system_quiet($ip,"link","set",$interface,"up") if(defined $ip && &pgen_cmd_exists($ip));
 if(!&wifi_ap_gateway_ready($interface,$ap_net)) {
  if(defined $ip && &pgen_cmd_exists($ip)) {
   &pgen_system_quiet($ip,"addr","add","$ap_net.1/24","dev",$interface);
  } elsif(defined $ifconfig && &pgen_cmd_exists($ifconfig)) {
   &pgen_system_quiet($ifconfig,$interface,"$ap_net.1","netmask","255.255.255.0","up");
  }
 }
 return &wifi_ap_gateway_ready($interface,$ap_net);
}

sub wifi_ap_prepare_interface(@) {
 my $base_interface=shift || "wlan0";
 my $ap_interface="ap0";
 my $ap_net=&pgen_ap_net();
 &pgen_system_quiet($rfkill,"unblock","wifi") if(defined $rfkill && &pgen_cmd_exists($rfkill));
 if(defined $iw && &pgen_cmd_exists($iw)) {
  my $base_info=&pgen_capture($iw,"dev",$base_interface,"info");
  if($base_info=~/\btype\s+AP\b/) {
   &pgen_service_action($hostapd_init,"hostapd","stop");
   &pgen_system_quiet($ip,"link","set",$base_interface,"down") if(defined $ip && &pgen_cmd_exists($ip));
   &pgen_system_quiet($iw,"dev",$base_interface,"set","type","managed");
   &pgen_system_quiet($ip,"link","set",$base_interface,"up") if(defined $ip && &pgen_cmd_exists($ip));
  }
  my $ap_info=&pgen_capture($iw,"dev","ap0","info");
  if($ap_info eq "") {
   &pgen_system_quiet($iw,"dev",$base_interface,"interface","add","ap0","type","__ap");
   $ap_info=&pgen_capture($iw,"dev","ap0","info");
  }
  $ap_interface="ap0" if($ap_info ne "");
 }
 $ap_interface=$base_interface if($ap_interface eq "");
 &pgen_system_quiet($ip,"link","set",$ap_interface,"up") if(defined $ip && &pgen_cmd_exists($ip));
 if(defined $ip && &pgen_cmd_exists($ip)) {
  &pgen_system_quiet($ip,"addr","flush","dev",$ap_interface);
  &pgen_system_quiet($ip,"addr","add","$ap_net.1/24","dev",$ap_interface);
 } elsif(defined $ifconfig && &pgen_cmd_exists($ifconfig)) {
  &pgen_system_quiet($ifconfig,$ap_interface,"$ap_net.1","netmask","255.255.255.0","up");
 }
 return ($ap_interface,$ap_net);
}

sub wifi_ap_apply_conf (@) {
 $ssid=$ARGV[1];
 $password=$ARGV[2];
 return print "ERR:SSID required" if($ssid eq "");
 return print "ERR:Password must be at least 8 characters" if(length($password)<8);
 return print "ERR:hostapd not installed" if(!&pgen_cmd_exists($hostapd_bin) && !&pgen_service_exists("hostapd.service"));
 my $interface=&hostapd_conf_value("interface","wlan0");
 &update_hostapd_conf($ssid,$password,$interface);
 my $restart=&wifi_ap_enable_impl("wlan0");
 if($restart !~ /^OK/) {
  print $restart;
 } else {
  print "OK";
 }
}

sub wifi_ap_status (@) {
 my $interface=&hostapd_conf_value("interface","wlan0");
 my $ap_net=&pgen_ap_net();
 my $hostapd_available=(&pgen_cmd_exists($hostapd_bin) || -x $hostapd_init || &pgen_cmd_exists($systemctl) || &pgen_cmd_exists($service_cmd)) ? 1 : 0;
 my $dnsmasq_available=&pgen_cmd_exists($dnsmasq_bin) ? 1 : 0;
 my $active=&pgen_service_active("hostapd","hostapd");
 my $dnsmasq_active=&pgen_service_active("dnsmasq","dnsmasq");
 my $gateway_ready=0;
 if($active) {
  $gateway_ready=&wifi_ap_ensure_gateway($interface,$ap_net);
  &configure_dnsmasq_ap($interface,$ap_net) if($gateway_ready && !$dnsmasq_active);
  $dnsmasq_active=&pgen_service_active("dnsmasq","dnsmasq");
 }
 $active=0 if($active && !$gateway_ready);
 print "AP_AVAILABLE=$hostapd_available\n";
 print "AP_ACTIVE=$active\n";
 print "AP_INTERFACE=$interface\n";
 print "AP_NET=$ap_net\n";
 print "AP_ADDRESS=$ap_net.1\n";
 print "AP_GATEWAY_READY=$gateway_ready\n";
 print "DNSMASQ_AVAILABLE=$dnsmasq_available\n";
 print "DNSMASQ_ACTIVE=$dnsmasq_active\n";
}

sub wifi_ap_enable_impl (@) {
 my $base_interface=$ARGV[1] || $_[0] || "wlan0";
 my $ssid=&hostapd_conf_value("ssid","PGenerator");
 my $password=&hostapd_conf_value("wpa_passphrase","PGenerator");
 return "ERR:hostapd not installed" if(!&pgen_cmd_exists($hostapd_bin) && !&pgen_service_exists("hostapd.service"));
 return "ERR:AP password must be at least 8 characters" if(length($password)<8);
 my ($ap_interface,$ap_net)=&wifi_ap_prepare_interface($base_interface);
 &update_hostapd_conf($ssid,$password,$ap_interface);
 &configure_dnsmasq_ap($ap_interface,$ap_net);
 my $start=&pgen_service_action($hostapd_init,"hostapd","restart");
 &wifi_ap_ensure_gateway($ap_interface,$ap_net);
 if($start!=0) {
  return "ERR:hostapd failed to start";
 } else {
  return "OK";
 }
}

sub wifi_ap_enable (@) {
 print &wifi_ap_enable_impl($ARGV[1] || "wlan0");
}

sub wifi_ap_disable (@) {
 my $stop=&pgen_service_action($hostapd_init,"hostapd","stop");
 if(-f "/etc/dnsmasq.d/pgenerator-ap.conf") {
  unlink("/etc/dnsmasq.d/pgenerator-ap.conf");
  &pgen_service_action("","dnsmasq","restart");
 }
 if($stop==127) {
  print "ERR:hostapd service not available";
 } else {
  print "OK";
 }
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
 return print "ERR:wpa_cli not found" if(!&pgen_cmd_exists($wpa_cli));
 &ensure_wlan_client_ready($interface);
 if(defined $password && $password ne "") {
  return print "ERR:wpa_passphrase not found" if(!&pgen_cmd_exists($wpa_passphrase));
  $pid = open2($CMD_READ, $CMD_WRITE, $wpa_passphrase, $ssid);
  print $CMD_WRITE "$password\n";
  close(CMD_WRITE);
  while(<$CMD_READ>) {
   chomp($_);
   next if(!/psk/ || /#/);
   /psk=(.*)/;
   $psk_pass=$1;
  }
  close(CMD_READ);
  waitpid($pid,0);
  return print "ERR:Unable to generate WiFi PSK" if($psk_pass eq "");
 }
 &pgen_system_quiet($wpa_cli,"-i",$interface,"remove_network","all");
 &pgen_system_quiet($wpa_cli,"-i",$interface,"flush");
 my $netid=&pgen_capture($wpa_cli,"-i",$interface,"add_network");
 chomp($netid);
 $netid=0 if($netid!~/^\d+$/);
 &pgen_system_quiet($wpa_cli,"-i",$interface,"set_network",$netid,"ssid","\"$ssid\"");
 if(defined $password && $password ne "") {
  &pgen_system_quiet($wpa_cli,"-i",$interface,"set_network",$netid,"psk",$psk_pass);
 } else {
  &pgen_system_quiet($wpa_cli,"-i",$interface,"set_network",$netid,"key_mgmt","NONE");
 }
 &pgen_system_quiet($wpa_cli,"-i",$interface,"enable_network",$netid);
 &pgen_system_quiet($wpa_cli,"-i",$interface,"select_network",$netid);
 &pgen_system_quiet($wpa_cli,"-i",$interface,"save_config");
 &wifi_release_dhcp($interface);
 &pgen_system_quiet($wpa_cli,"-i",$interface,"reconfigure");
 &pgen_system_quiet($wpa_cli,"-i",$interface,"reconnect");
 if(!&wifi_wait_completed($interface,$ssid,20)) {
  print "ERR:WiFi association timed out";
  return;
 }
 my $addr=&wifi_start_dhcp($interface,18);
 if($addr ne "") {
  print "OK\nip_address=$addr";
 } else {
  print "OK\nwarning=Associated but no IPv4 lease yet";
 }
}

###############################################
#           Wifi Disconnect function          #
###############################################
sub wifi_disconnect (@) {
 my $response = "";
 $interface=$ARGV[1];
 $interface=~s/ //g;
 return if($interface eq "");
 return print "ERR:wpa_cli not found" if(!&pgen_cmd_exists($wpa_cli));
 &pgen_system_quiet($wpa_cli,"-i",$interface,"disconnect");
 &wifi_release_dhcp($interface);
 print "OK";
}

sub wifi_forget (@) {
 $interface=$ARGV[1];
 $interface=~s/ //g;
 return if($interface eq "");
 return print "ERR:wpa_cli not found" if(!&pgen_cmd_exists($wpa_cli));
 &pgen_system_quiet($wpa_cli,"-i",$interface,"remove_network","all");
 &pgen_system_quiet($wpa_cli,"-i",$interface,"save_config");
 &pgen_system_quiet($wpa_cli,"-i",$interface,"disconnect");
 &wifi_release_dhcp($interface);
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
 my $paired_var = "";
 my $paired_value = "";
 return print $error_response if($var_to_set =~/^(ip_pattern|^port_pattern)$/);
 if($var_to_set eq "dv_metadata") {
  $paired_var = "dv_map_mode";
  $paired_value = "0" if($value eq "2");
  $paired_value = "1" if($value eq "3");
  $paired_value = "2" if($value eq "4");
 } elsif($var_to_set eq "dv_map_mode") {
  $paired_var = "dv_metadata";
  $paired_value = "3" if($value eq "1");
  $paired_value = "4" if($value eq "2");
  $paired_value = "2" if($paired_value eq "");
 }
 open(CONF,"$pattern_conf");
 while(<CONF>) {
  next if(/^$var_to_set=/);
  next if($paired_var ne "" && /^$paired_var=/);
  $content.=$_;
 }
 chomp($content);
 $content.="\n$var_to_set=$value" if($value ne "");
 $content.="\n$paired_var=$paired_value" if($paired_var ne "" && $paired_value ne "");
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
 my $hci="";
 my $adapter="";
 my $devices="";
 my $pan_ip="";
 $hci=&pgen_capture($hciconfig,$hci_interface) if(defined $hciconfig && &pgen_cmd_exists($hciconfig));
 if($hci eq "" && defined $bluetoothctl && &pgen_cmd_exists($bluetoothctl)) {
  $hci=&pgen_capture($bluetoothctl,"show");
 }
 if(-x "/usr/bin/bluez-test-adapter") {
  $adapter=`/usr/bin/bluez-test-adapter list 2>/dev/null`;
 } elsif(defined $bluetoothctl && &pgen_cmd_exists($bluetoothctl)) {
  $adapter=&pgen_capture($bluetoothctl,"show");
 }
 if(-x "/usr/bin/bluez-test-device") {
  $devices=`/usr/bin/bluez-test-device list 2>/dev/null`;
 } elsif(defined $bluetoothctl && &pgen_cmd_exists($bluetoothctl)) {
  $devices=&pgen_capture($bluetoothctl,"devices");
 }
 if(defined $ifconfig && &pgen_cmd_exists($ifconfig)) {
  $pan_ip=&pgen_capture($ifconfig,"pan0");
  $pan_ip.=&pgen_capture($ifconfig,$bt_interface);
  $pan_ip.=&pgen_capture($ifconfig,"bnep0") if($bt_interface ne "bnep0");
 } elsif(defined $ip && &pgen_cmd_exists($ip)) {
  $pan_ip=&pgen_capture($ip,"addr","show","dev","pan0");
  $pan_ip.=&pgen_capture($ip,"addr","show","dev",$bt_interface);
  $pan_ip.=&pgen_capture($ip,"addr","show","dev","bnep0") if($bt_interface ne "bnep0");
 }
 my $pan_net="";
 if(-f $pand_default_file) {
  my $pf=&read_from_file($pand_default_file);
  ($pan_net)=$pf=~/PAND_NET="([^"]*)"/;
 }
 $pan_net="10.10.11" if($pan_net eq "");
 my $agent_running=`ps aux 2>/dev/null | grep pgenerator-bt-agent | grep -v grep`;
 chomp($agent_running);
 my $agent_status=($agent_running ne "")?"1":"0";
 my $nap_running=(`pgrep -f 'bt-network.*-s nap' 2>/dev/null` ne "")?"1":"0";
 my $pand_available=(-x "/etc/init.d/pand") ? 1 : 0;
 my $bt_network_available=(-x "/usr/bin/bt-network" || -x "/usr/sbin/bt-network") ? 1 : 0;
 my $bluez_modern=(defined $bluetoothctl && &pgen_cmd_exists($bluetoothctl)) ? 1 : 0;
 print "HCI_BEGIN\n$hci\nHCI_END\n";
 print "ADAPTER_BEGIN\n$adapter\nADAPTER_END\n";
 print "DEVICES_BEGIN\n$devices\nDEVICES_END\n";
 print "PAN_BEGIN\n$pan_ip\nPAN_END\n";
 print "PAND_NET=$pan_net\n";
 print "PAND_AVAILABLE=$pand_available\n";
 print "BT_NETWORK_AVAILABLE=$bt_network_available\n";
 print "NAP_RUNNING=$nap_running\n";
 print "BLUETOOTHCTL_AVAILABLE=$bluez_modern\n";
 print "AGENT=$agent_status\n";
 my $bt_soft_blocked=0;
 if(defined $rfkill && &pgen_cmd_exists($rfkill)) {
  my $rf=&pgen_capture($rfkill,"list","bluetooth");
  $bt_soft_blocked=1 if($rf=~/soft\s+blocked:\s*yes/i);
 }
 print "SOFT_BLOCKED=$bt_soft_blocked\n";
}

sub bt_set_discoverable (@) {
 my $val=$ARGV[1];
 if($val eq "on" || $val eq "off") {
  if(-x "/usr/bin/bluez-test-adapter") {
   system("/usr/bin/bluez-test-adapter discoverable $val");
   print $ok_response;
  } elsif(defined $bluetoothctl && &pgen_cmd_exists($bluetoothctl)) {
   &pgen_system_quiet($bluetoothctl,"discoverable",$val);
   &pgen_system_quiet($bluetoothctl,"pairable",$val);
   print $ok_response;
  } else {
   print "$error_response:bluetoothctl not found";
  }
 } else {
  print $error_response;
 }
}

sub bt_set_powered (@) {
 my $val=$ARGV[1];
 if($val eq "on" || $val eq "off") {
  if($val eq "on") {
   &pgen_system_quiet($rfkill,"unblock","bluetooth") if(defined $rfkill && &pgen_cmd_exists($rfkill));
   &pgen_system_quiet($hciconfig,$hci_interface,"up") if(defined $hciconfig && &pgen_cmd_exists($hciconfig));
   if(-x "/usr/bin/bluez-test-adapter") {
    system("/usr/bin/bluez-test-adapter powered on");
   } elsif(defined $bluetoothctl && &pgen_cmd_exists($bluetoothctl)) {
    &pgen_system_quiet($bluetoothctl,"power","on");
   }
  } else {
   if(-x "/usr/bin/bluez-test-adapter") {
    system("/usr/bin/bluez-test-adapter powered off");
   } elsif(defined $bluetoothctl && &pgen_cmd_exists($bluetoothctl)) {
    &pgen_system_quiet($bluetoothctl,"power","off");
   }
   &pgen_system_quiet($hciconfig,$hci_interface,"down") if(defined $hciconfig && &pgen_cmd_exists($hciconfig));
   &pgen_system_quiet($rfkill,"block","bluetooth") if(defined $rfkill && &pgen_cmd_exists($rfkill));
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
  &pgen_system_quiet($hciconfig,$hci_interface,"name",$name) if(defined $hciconfig && &pgen_cmd_exists($hciconfig));
  &pgen_system_quiet($bluetoothctl,"system-alias",$name) if(defined $bluetoothctl && &pgen_cmd_exists($bluetoothctl));
  print $ok_response;
 } else {
  print $error_response;
 }
}

sub bt_set_pan_ip (@) {
 my $net=$ARGV[1];
 if($net=~/^\d{1,3}\.\d{1,3}\.\d{1,3}$/) {
  mkpath(dirname($pand_default_file)) if(!-d dirname($pand_default_file));
  open(DEFAULT_PAND_FILE,">$pand_default_file");
  print DEFAULT_PAND_FILE "PAND_NET=\"$net\"\n";
  close(DEFAULT_PAND_FILE);
  &bt_restart_pan();
 } else {
  print $error_response;
 }
}

sub bt_restart_pan (@) {
 if(-x "/etc/init.d/pand") {
  &pgen_system_quiet("/etc/init.d/pand","restart");
  print $ok_response;
 } elsif(-x "/usr/bin/bt-network" || -x "/usr/sbin/bt-network") {
  my $bt_network=(-x "/usr/bin/bt-network") ? "/usr/bin/bt-network" : "/usr/sbin/bt-network";
  my $pan_net="10.10.11";
  if(-f $pand_default_file) {
   my $pf=&read_from_file($pand_default_file);
   ($pan_net)=$pf=~/PAND_NET="([^"]*)"/;
  }
  $pan_net="10.10.11" if($pan_net eq "");
  if(defined $ip && &pgen_cmd_exists($ip)) {
   &pgen_system_quiet($ip,"link","add","pan0","type","bridge");
   &pgen_system_quiet($ip,"addr","flush","dev","pan0");
   &pgen_system_quiet($ip,"addr","add","$pan_net.1/24","dev","pan0");
   &pgen_system_quiet($ip,"link","set","pan0","up");
  } elsif(defined $ifconfig && &pgen_cmd_exists($ifconfig)) {
   &pgen_system_quiet($ifconfig,"pan0","$pan_net.1","netmask","255.255.255.0","up");
  }
  if(defined $dnsmasq_bin && &pgen_cmd_exists($dnsmasq_bin)) {
   my $dir="/etc/dnsmasq.d";
   mkpath($dir) if(!-d $dir);
   if(open(my $fh,">","$dir/pgenerator-bt-pan.conf")) {
    print $fh "interface=pan0\nbind-dynamic\ndhcp-range=$pan_net.50,$pan_net.150,255.255.255.0,12h\ndhcp-option=3,$pan_net.1\ndhcp-option=6,$pan_net.1\n";
    close($fh);
   }
   &pgen_service_action("","dnsmasq","restart");
  }
  mkpath("/var/log/PGenerator") if(!-d "/var/log/PGenerator");
  system("pkill -f '[b]t-network.*-s nap' >/dev/null 2>&1");
  system("setsid $bt_network -d -s nap pan0 >/var/log/PGenerator/bt-network.log 2>&1 </dev/null &");
  sleep(1);
  if(`pgrep -f 'bt-network.*-s nap' 2>/dev/null` ne "") {
   print $ok_response;
  } else {
   print "$error_response:bt-network failed to start";
  }
 } else {
  print "$error_response:Bluetooth PAN service not available";
 }
}

sub bt_remove_device (@) {
 my $mac=$ARGV[1];
 if($mac=~/^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/) {
  if(-x "/usr/bin/bluez-test-device") {
   system("/usr/bin/bluez-test-device remove $mac");
   print $ok_response;
  } elsif(defined $bluetoothctl && &pgen_cmd_exists($bluetoothctl)) {
   &pgen_system_quiet($bluetoothctl,"remove",$mac);
   print $ok_response;
  } else {
   print "$error_response:bluetoothctl not found";
  }
 } else {
  print $error_response;
 }
}

sub bt_set_agent (@) {
 my $val=$ARGV[1];
 my $agent="/usr/bin/pgenerator-bt-agent";
 if($val eq "on") {
  return print "$error_response:pgenerator-bt-agent not found" if(!-x $agent);
  system("pkill -f '[p]generator-bt-agent' 2>/dev/null");
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
  system("pkill -f '[p]generator-bt-agent' 2>/dev/null");
  print $ok_response;
 } else {
  print $error_response;
 }
}
