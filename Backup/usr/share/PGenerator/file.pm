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
#            Write File Function              #
###############################################
sub write_file(@) {
 my $file_tmp = shift;
 my $file = shift;
 my $content = shift;
 my $do_sync = shift;
 open(FILE,">$file_tmp");
 print FILE $content;
 close(FILE);
 rename("$file_tmp","$file") if($file_tmp ne $file);
 &sync() if($do_sync);
}

###############################################
#         Read From File File Function        #
###############################################
sub read_from_file(@) {
 my $file = shift;
 my $content="";
 open(FILE,"$file");
 while(<FILE>) {
  $content.=$_;
 }
 return $content;
}

###############################################
#             Upload File Function            #
###############################################
sub upload_file(@) {
 my $name = shift;
 my $tmp_name = shift;
 my $data=shift;
 open(TMP,">$tmp_name") if(!-f "$tmp_name");
 open(TMP,">>$tmp_name");
 print TMP decode_base64($data);
 close(TMP);
}

###############################################
#       Get File Destination Function         #
###############################################
sub get_destination(@) {
 my $where = shift;
 my $dest = "$var_dir/$where";
 $dest=$pattern_images  if($where eq "IMAGES");
 $dest=$pattern_plugins if($where eq "PLUGINS");
 $dest=$pattern_video   if($where eq "VIDEO");
 return $dest;
}

###############################################
#              Remove Files Function          #
###############################################
sub remove_files(@) {
 $where = shift;
 $pattern_what = shift;
 if(-d "$where") {
  opendir(DIR,$where);
  @dir=readdir(DIR);
  for(@dir) {
   next if(!-f "$where/$_");
   next if(!/$pattern_what/);
   unlink("$where/$_");
  }
 }
}
return 1;
