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
#           Discovery Name                    #
###############################################
sub discovery_name (@) {
 my $hostname=&read_from_file($hostname_file);
 chomp($hostname);
 $hostname=~s/^\s+|\s+$//g;
 my $name=$hostname;
 $name=$version_plus if($name eq "" || lc($name) eq "pgenerator");
 return substr($name,0,24);
}

###############################################
#           DeviceControl Discovery           #
###############################################
sub discovery_devicecontrol (@) {
 my ($message,$reply_discovery) = "";
 my $socket_server = IO::Socket::INET -> new (
                                              LocalPort=>$port_discovery_devicecontrol,
                                              Broadcast=>1,
                                              Proto=>'udp'
 );
 $socket_server->setsockopt(SOL_SOCKET, SO_RCVTIMEO, pack('l!l!', 5, 0)) if($socket_server);
 while (1) { 
  $socket_server->recv($message, 1024);
  next if(!$message || $message eq "");
  if(!-f $discoverable_disabled_file && $message=~/$message_discovery_devicecontrol/) {
     $reply_discovery=$reply_discovery_devicecontrol." ".&discovery_name();
   $socket_server->send($reply_discovery) if(!-f $discoverable_disabled_file && $message=~/$message_discovery_devicecontrol/);
  }
 }
}

###############################################
#           LightSpace Discovery           #
###############################################
sub discovery_lightspace (@) {
 my $message = "";
 my $socket_server = IO::Socket::INET -> new (
                                              LocalPort=>$port_discovery_lightspace,
                                              ReuseAddr=>1,
                                              Broadcast=>1,
                                              Proto=>'udp'
 );
 $socket_server->setsockopt(SOL_SOCKET, SO_RCVTIMEO, pack('l!l!', 5, 0)) if($socket_server);
 while (1) {
  $socket_server->recv($message, 1024);
  next if(!$message || $message eq "");
  my ($all_ip,$ls_port)=$message=~/(.*):(.*)/;
  if(!-f $discoverable_disabled_file && $message=~/LS:/ && $ls_port ne "") {
   my $ip_ls=$socket_server->peerhost;
   $socket_server->close();
   &stats("connections",1);
   &sudo("OPEN_IPTABLES_FOR_LS",@{[$ip_ls]},$ls_port);
   $calibration_client_ip=$ip_ls;
   $calibration_client_software="LightSpace";
   $thr=threads->create(\&lightspace_connect,$ip_ls,$ls_port)->join;
   $calibration_client_ip="";
   $calibration_client_software="";
   &create_pattern_file("RECTANGLE","$w_s,$h_s",100,"$bg_default","","","","",1,"lightspace"); # when LS disconnects a black pattern is displayed
   &discovery_lightspace();
  }
 }
}

###############################################
#           RPC Discovery                     #
###############################################
sub discovery_rpc (@) {
 my $message = "";
 my $socket_server = IO::Socket::INET->new(
  LocalPort => $port_rpc_discovery,
  Proto => 'udp',
  Broadcast => 1,
  ReuseAddr => 1,
 );
 if(!$socket_server) {
  &log("RPC discovery: bind failed on port $port_rpc_discovery: $!");
  return;
 }
 $socket_server->setsockopt(SOL_SOCKET, SO_RCVTIMEO, pack('l!l!', 5, 0)) if($socket_server);
 while (1) {
  $socket_server->recv($message, 1024);
  next if(-f $discoverable_disabled_file);
  next if(!$message || $message eq "");
  my $caller_ip = $socket_server->peerhost();
  next if(!$caller_ip);
    my $response = pack("a24 v v", &discovery_name(), $port_rpc, $port_rpc);
  my $dest = Socket::sockaddr_in($port_rpc_response, Socket::inet_aton($caller_ip));
  CORE::send($socket_server, $response, 0, $dest);
 }
}

return 1;
