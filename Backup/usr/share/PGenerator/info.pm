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
#                Device Info                  #
###############################################
sub device_info (@) {
 my $cmd = "";
 mkdir("$info_dir") if (!-d "$info_dir");
 &remove_files($info_dir,"\.info\$");
 while(1) {
  foreach $cmd (@list_info_cmd) {
   $response=&write_info($cmd);
  }
  sleep($sleep_info);
 }
}

###############################################
#                Write Info                   #
###############################################
sub write_info (@) {
 my $cmd=shift;
 my $response = "";
 # mkdir
 mkdir("$info_dir") if (!-d "$info_dir");
 # Get PGeneric Conf
 if($cmd eq "GET_PGENERATOR_CONF_ALL") {
  foreach my $key (keys(%pgenerator_conf)) {
   &write_file_info("GET_PGENERATOR_CONF_".uc($key),$pgenerator_conf{$key});
  }
 }
 # Get Generic
 if($cmd eq "GET_IP_MAC_ALL") {
  &remove_files("$info_dir","GET_IP\-.*\.info\$");
  &remove_files("$info_dir","GET_MAC\-.*\.info\$");
  foreach my $interface (keys %info_var) {
   &write_file_info("GET_IP-$interface",$info_var{$interface}{addr});
   &write_file_info("GET_MAC-$interface",$info_var{$interface}{mac});
  }
 }
 $response=&get_cmd_generic($cmd);
 # Write
 &write_file_info($cmd,$response);
 # Return
 return $response;
}

###############################################
#            Write File Info                  #
###############################################
sub write_file_info(@) {
 my $cmd = shift;
 my $response = shift;
 &write_file("$info_dir/$cmd.info.tmp","$info_dir/$cmd.info","$response"); 
}

return 1;
