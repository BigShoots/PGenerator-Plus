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

###############################################
#         Calman Patch Logger                 #
# Writes one structured line per patch the    #
# Calman client pushes, regardless of $debug. #
# Fields: ts, type, raw, scaled, win, bg,     #
#         range, peer, extra                  #
###############################################
sub log_calman_patch (@) {
 my %f=@_;
 my $path=$calman_patch_log || "/tmp/calman-patches.log";
 my $dir=$path; $dir=~s|/[^/]+$||;
 if($dir ne "" && ! -d $dir) {
  mkdir $dir;
  if(! -d $dir) { $path="/tmp/calman-patches.log"; }
 }
 my $ts=Time::HiRes::time();
 my $type=defined($f{type})?$f{type}:"";
 my $raw=defined($f{raw})?$f{raw}:"";
 my $scaled=defined($f{scaled})?$f{scaled}:"";
 my $win=defined($f{win})?$f{win}:"";
 my $bg=defined($f{bg})?$f{bg}:"";
 my $range=defined($f{range})?$f{range}:"";
 my $peer=defined($f{peer})?$f{peer}:"";
 my $extra=defined($f{extra})?$f{extra}:"";
 for($raw,$scaled,$win,$bg,$range,$peer,$extra) { s/[\r\n\t]/ /g; }
 my $line=sprintf("%.6f\ttype=%s\traw=%s\tscaled=%s\twin=%s\tbg=%s\trange=%s\tpeer=%s\textra=%s\n",
                  $ts,$type,$raw,$scaled,$win,$bg,$range,$peer,$extra);
 if(open(my $fh,">>",$path)) {
  print $fh $line;
  close($fh);
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
