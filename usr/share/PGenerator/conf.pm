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
#           Get Conf Function                 #
###############################################
sub get_conf (@) {
 my $section=-1;
 my $ok = 0;
 my $string = "";
 # Check Distro
 $ok++ if(-f "/etc/BiasiLinux/system_info");
 $ok++ if(-f "/etc/BiasiLinux/packages.conf");
 $ok++ if(-f "/etc/BiasiLinux/boot_device.conf");
 $ok++ if(-f "/var/lib/BiasiLinux/PGenerator");
 $ok++ if(-f "/var/lib/BiasiLinux/linux");
 $ok++ if(-f "/usr/bin/pkg");
 $ok++ if(-f "/usr/bin/rcset");
 $ok++ if(-f "/usr/bin/bootloader");
 $ok++ if(-f "$proc_device_model");
 if($ok != 9 ) {
  print("\nOnly on Distro BiasiLinux with PGenerator installed can be executed this program!\n\n");
  exit(1);
 }
 # Check Device
 $ok=0;
 $device_model=&read_from_file($proc_device_model);
 if($device_model !~/Raspberry/) {
  print("\nOnly on Raspberry Device can be executed this program!\n\n");
  exit(1);
 }
 # Start for RPI p4
 $is_rpi_4=1 if($device_model =~/Raspberry Pi 4|Raspberry Pi Compute Module 4/);
 open(CMD_TVSERVICE,"$tvservice -s 2>/dev/stdout|");
 $is_kms=1 if((<CMD_TVSERVICE>) =~/when using the vc4-kms-v3d driver/);
 close(CMD_TVSERVICE);
 $tvservice_is_working=1 if($? == 0);
 $device_model.=" (KMS)" if($is_rpi_4 && $is_kms);
 # End for RPI p4
 &get_pgenerator_conf();
}

###############################################
#       Get PGenerator Conf Function          #
###############################################
sub get_pgenerator_conf(@) {
 open(CONF,"$pattern_conf");
 while(<CONF>) {
  $_=~s/\r|\n//g;
  next if($_=~/^#/ || $_ eq "");
  $_=~s/^\s//g;
  $pgenerator_conf{$1}=$2 if($_=~/(.*)=(.*)/);
 }
 close(CONF);
}

###############################################
#        Get Conf Pattern Function            #
###############################################
sub get_conf_pattern (@) {
 my $pattern = shift;
 my $type = shift;
 my $str = "";
 my $val = "";
 open(PATTERN,"$pattern_templates/$pattern");
 while(<PATTERN>) {
  $str.=$_;
  if($_=~/^$type=(.*)/) {
   chomp($val=$1);
   return $val;
   last;
  }
 }
 close(PATTERN);
 chomp($str);
 return $str;
}

###############################################
#        Set Conf Pattern Function            #
###############################################
sub set_conf_pattern (@) {
 my $pattern = shift;
 my $type = shift;
 my $val = shift;
 my $pattern_dir=$pattern_templates;
 $pattern_dir="$var_dir/running/tmp" if($type eq "TEMPLATERAMDISK");
 my $str = '';
 if($type eq "TESTCMD") {
  copy("$pattern_dir/$pattern","$command_file");
  return;
 }
 if($type !~/^TEMPLATE/) {
  open(PATTERN,"$pattern_dir/$pattern");
  while(<PATTERN>) {
   next if($_=~/^$type=(.*)/ || $_=~/^END=1/);
   $str.=$_;
  }
 }
 # Start Patch for HCFR
 if($pattern eq "HCFR") {
  $val=~/(.*)(DRAW=.*)(DRAW=.*)/s;
  $val="$1$3\n$2";
  $val=~s/BG=-1,-1,-1/BG=DYNAMIC/;
  $val=~s/(BG=DYNAMIC.*)BG=DYNAMIC/\1BG=-1,-1,-1/s;
  chomp($val);
 }
 # End Patch for HCFR
 open(PATTERN,">$pattern_dir/$pattern.tmp");
 print PATTERN "$type=" if($type !~/^TEMPLATE/);
 print PATTERN "$val\n";
 print PATTERN "$str";
 print PATTERN "END=1\n" if($type !~/^TEMPLATE/);
 close(PATTERN);
 rename("$pattern_dir/$pattern.tmp","$pattern_dir/$pattern");
}

return 1;
