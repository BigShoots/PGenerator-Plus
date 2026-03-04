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
#               Log Function                  #
###############################################
sub log (@) {
 my $str = shift;
 my $force_stdout = shift;
 my $time = time();
 return if(!$debug && !$force_stdout);
 $str=~s/(\n|\r)//;
 $section=$program_name if($section eq "");
 my $content="$time [$section] $str";
 #
 # print log string
 #
 print " $content\n";
 #
 # write log string to file
 #
 if($debug eq "file") {
  open(LOG,">>$log_file");
  print LOG "$content\n";
  close(LOG);
 }
}

#############################################
#            Log And Die Function           #
#############################################
sub log_and_die (@) {
 my $text = shift;
 &log($text);
 die $text;
}

#############################################
#            Program fatal error            #
#############################################
sub fatal_error(@) {
 my $error=shift;
 &log($error,1);
 &pattern_generator_stop();
 print "\n Press enter to exit...";
 <STDIN>;
 exit;
}

return 1;
