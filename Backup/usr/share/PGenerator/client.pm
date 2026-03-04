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
#            Socket Create Function           #
###############################################
sub create_socket(@){
 my $ip = shift;
 my $port = shift;
 my $timeout = shift;
 my $receive_banner = shift;
 my $socket = "";
 $socket = new IO::Socket::INET (
  PeerHost => $ip,
  PeerPort => $port,
  Timeout => $timeout,
  Proto => 'tcp',
 ) || die "Error";
 if($receive_banner) {
  $socket->recv($banner, 1024);
  $banner=&remove_char($banner);
 }
 return $socket;
}

###############################################
#                LightSpace Connect           #
###############################################
sub lightspace_connect() {
 my $ip_ls=shift;
 my $port_ls=shift;
 $socket_lightspace=&create_socket($ip_ls,$port_ls,$timeout_client,0);
 while() {
  $select = IO::Select->new();
  $select->add($socket_lightspace);
  if(!$select->can_read($timeout_client)) {
   $socket_lightspace->send("Command:IsAlive");
   if(!$select->can_read($timeout_client)) {
    $socket_lightspace->close();
    threads->exit() if threads->can('exit');
    exit;
   }
  }
  $socket_lightspace->recv($command, 1024);
  return if($command eq "");
  if($command=~/<calibration>/) {
   my $start=time;
   my ($dim_perc,$pos_perc,$dim,$pos,$rgb)="";
   my ($r_p,$g_p,$b_p,$r_c,$g_c,$bits,$b_c,$x,$y,$cs,$cy)="";
   my ($r_bg,$g_bg,$b_bg)="";
   $command=~s/.*\<calibration\>/\<calibration\>/s;
   $command=~s/\<\/calibration\>.*/\<\/calibration\>/s;
   my $command_hash=XMLin($command);
   if(ref($command_hash->{shapes}->{rectangle}) eq 'ARRAY') {
    # LS with background
    $r_bg=$command_hash->{shapes}->{rectangle}[0]->{color}->{red};
    $g_bg=$command_hash->{shapes}->{rectangle}[0]->{color}->{green};
    $b_bg=$command_hash->{shapes}->{rectangle}[0]->{color}->{blue};
    $r_p=$command_hash->{shapes}->{rectangle}[1]->{color}->{red};
    $g_p=$command_hash->{shapes}->{rectangle}[1]->{color}->{green};
    $b_p=$command_hash->{shapes}->{rectangle}[1]->{color}->{blue};
    $r_c=$command_hash->{shapes}->{rectangle}[1]->{colex}->{red};
    $g_c=$command_hash->{shapes}->{rectangle}[1]->{colex}->{green};
    $b_c=$command_hash->{shapes}->{rectangle}[1]->{colex}->{blue};
    $bits=$command_hash->{shapes}->{rectangle}[1]->{colex}->{bits};
    $x=$command_hash->{shapes}->{rectangle}[1]->{geometry}->{x};
    $y=$command_hash->{shapes}->{rectangle}[1]->{geometry}->{y};
    $cx=$command_hash->{shapes}->{rectangle}[1]->{geometry}->{cx};
    $cy=$command_hash->{shapes}->{rectangle}[1]->{geometry}->{cy};
    $rgb="$r_p,$g_p,$b_p;$r_bg,$g_bg,$b_bg";
    $rgb="$r_c,$g_c,$b_c;$r_bg,$g_bg,$b_bg" if($is_rpi_4 && $bits ne "");
   } else {
    # LS without background
    $r_p=$command_hash->{shapes}->{rectangle}->{color}->{red};
    $g_p=$command_hash->{shapes}->{rectangle}->{color}->{green};
    $b_p=$command_hash->{shapes}->{rectangle}->{color}->{blue};
    $r_c=$command_hash->{shapes}->{rectangle}->{colex}->{red};
    $g_c=$command_hash->{shapes}->{rectangle}->{colex}->{green};
    $b_c=$command_hash->{shapes}->{rectangle}->{colex}->{blue};
    $bits=$command_hash->{shapes}->{rectangle}->{colex}->{bits};
    $x=$command_hash->{shapes}->{rectangle}->{geometry}->{x};
    $y=$command_hash->{shapes}->{rectangle}->{geometry}->{y};
    $cx=$command_hash->{shapes}->{rectangle}->{geometry}->{cx};
    $cy=$command_hash->{shapes}->{rectangle}->{geometry}->{cy};
    $rgb="$r_p,$g_p,$b_p;$bg_default";
    $rgb="$r_c,$g_c,$b_c;$bg_default" if($is_rpi_4 && $bits ne "");
   }
   $pos_perc=&get_float_from_string($x).",".&get_float_from_string($y);
   $dim_perc=&get_float_from_string($cx).",".&get_float_from_string($cy);
   $dim=&get_val_from_perc($dim_perc);
   $pos=&get_val_from_perc($pos_perc);
   $rgb.=";$draw_default;$dim;$pos;$res_default;;;";
   $rgb.="$bits" if($is_rpi_4 && $bits ne "");
   next if($rgb eq $last_rgb);
   $last_rgb=$rgb;
   &get_pattern($test_template_command,"$pattern_dynamic","$rgb","lightspace");
  }
 }
}

###############################################
#             Get Val From Perc               #
###############################################
sub get_val_from_perc(@) {
 my $val = shift;
 my @el=split(",",$val);
 return &round_val($el[0]*$w_s).",".&round_val($el[1]*$h_s);
}


###############################################
#             Get Float From String           #
###############################################
sub get_float_from_string(@) {
 my $val = shift;
 return  $val=~s/,/\./gr;
}

return 1;
