#
# PGenerator Web UI & mDNS Responder
#
# Provides:
#   - HTTP server on port 80 serving settings UI
#   - JSON API for reading/writing PGenerator.conf
#   - mDNS responder so device is reachable at pgenerator.local
#
# Threads:
#   webui_http()  — HTTP server (port 80)
#   webui_mdns()  — mDNS responder (port 5353, multicast 224.0.0.251)
#

BEGIN { require bytes; }
use Time::HiRes ();

###############################################
#             mDNS Route Helpers              #
###############################################
sub webui_mdns_routes (@) {
 my @routes;
 my $route_out=`ip -o -4 route show scope link 2>/dev/null`;
 foreach my $line (split(/\n/,$route_out)) {
  next if($line =~ /\blinkdown\b/);
  if($line =~ /^(\d+\.\d+\.\d+\.\d+)\/(\d+)\s+dev\s+(\S+).*?\bsrc\s+(\d+\.\d+\.\d+\.\d+)/) {
    my $network=$1;
    my $prefix=int($2);
    my $iface=$3;
    my $ip=$4;
    my $ifindex=&read_from_file("/sys/class/net/$iface/ifindex");
  $ifindex=~s/\s+//g;
  $ifindex=int($ifindex||0);
    push @routes,{ network => $network, prefix => $prefix, iface => $iface, ip => $ip, ifindex => $ifindex };
  }
 }
 return @routes;
}

sub webui_mdns_match_prefix (@) {
 my $ip=shift;
 my $network=shift;
 my $prefix=int(shift);
 my $mask=0;
 return 0 if($ip eq "" || $network eq "" || $prefix < 0 || $prefix > 32);
 $mask=((0xFFFFFFFF << (32 - $prefix)) & 0xFFFFFFFF) if($prefix > 0);
 return ((unpack("N",Socket::inet_aton($ip)) & $mask) == (unpack("N",Socket::inet_aton($network)) & $mask)) ? 1 : 0;
}

sub webui_mdns_best_ip (@) {
 my $querier_ip=shift;
 my @routes=&webui_mdns_routes();
 foreach my $route (@routes) {
  return $route->{ip} if(&webui_mdns_match_prefix($querier_ip,$route->{network},$route->{prefix}));
 }
 my $default_route=`ip -o -4 route show default 2>/dev/null`;
 if($default_route =~ /\bdev\s+(\S+)/) {
  my $default_iface=$1;
  foreach my $route (@routes) {
   return $route->{ip} if($route->{iface} eq $default_iface);
  }
 }
 return $routes[0]->{ip} if(@routes);
 return "";
}

sub webui_mdns_read_name (@) {
 my $buf=shift;
 my $offset=int(shift);
 my $name="";
 my $next_offset=$offset;
 my $jumped=0;
 my $jumps_left=10;

 while($offset < length($buf)) {
  my $len=ord(substr($buf,$offset,1));
  if(($len & 0xC0) == 0xC0) {
   return ("",$next_offset,0) if($offset + 1 >= length($buf) || $jumps_left <= 0);
   my $ptr=(($len & 0x3F) << 8) | ord(substr($buf,$offset + 1,1));
   $next_offset=$offset + 2 if(!$jumped);
   $offset=$ptr;
   $jumped=1;
   $jumps_left--;
   next;
  }
  if($len == 0) {
   $next_offset=$offset + 1 if(!$jumped);
   return ($name,$next_offset,1);
  }
  $offset++;
  return ("",$next_offset,0) if($offset + $len > length($buf));
  $name.="." if($name ne "");
  $name.=substr($buf,$offset,$len);
  $offset+=$len;
  $next_offset=$offset if(!$jumped);
 }

 return ("",$next_offset,0);
}

###############################################
#              mDNS Responder                 #
###############################################
sub webui_mdns (@) {
 my $MDNS_ADDR="224.0.0.251";
 my $MDNS_PORT=5353;
 my $mdns_hostname="pgenerator";
 my $MDNS_REJOIN_INTERVAL=30; # seconds between multicast re-join checks

 # Create UDP socket bound to mDNS port
 socket(my $sock, Socket::PF_INET, Socket::SOCK_DGRAM, getprotobyname('udp'))
  || do { &log("mDNS: socket failed: $!"); return; };
 setsockopt($sock, Socket::SOL_SOCKET, Socket::SO_REUSEADDR, pack("l",1));

 # SO_REUSEPORT if available
 eval { setsockopt($sock, Socket::SOL_SOCKET, 15, pack("l",1)); };

 bind($sock, Socket::sockaddr_in($MDNS_PORT, Socket::INADDR_ANY))
  || do { &log("mDNS: bind failed: $!"); return; };

 my $IP_ADD_MEMBERSHIP=eval { Socket::IP_ADD_MEMBERSHIP() } || 35; # 35 on Linux
 my $IP_DROP_MEMBERSHIP=eval { Socket::IP_DROP_MEMBERSHIP() } || 36;
 my $IPPROTO_IP=eval { Socket::IPPROTO_IP() } || 0;
 my $IP_MULTICAST_TTL=eval { Socket::IP_MULTICAST_TTL() } || 33;
 my $IP_TTL=eval { Socket::IP_TTL() } || 2;
 setsockopt($sock, $IPPROTO_IP, $IP_MULTICAST_TTL, pack("C",255));
 setsockopt($sock, $IPPROTO_IP, $IP_TTL, pack("I",255));

 # Join multicast group on each active IPv4 interface so queries work across
 # Wi-Fi client, AP mode, Bluetooth PAN, USB gadget, etc.
 # Track joined interfaces so we can re-join after hotplug events.
 my %mdns_joined; # key="iface:ip" value=1
 my $mdns_join_time=0;

 my $mdns_rejoin=sub {
  my @routes=&webui_mdns_routes();
  my %current;
  foreach my $route (@routes) {
   my $key="$route->{iface}:$route->{ip}";
   $current{$key}=1;
   next if($mdns_joined{$key});
   my $joined=0;
   if($route->{ifindex} > 0) {
    my $mreqn=pack("a4 a4 i",Socket::inet_aton($MDNS_ADDR),pack("N",0),$route->{ifindex});
    $joined=setsockopt($sock, $IPPROTO_IP, $IP_ADD_MEMBERSHIP, $mreqn) ? 1 : 0;
   }
   if(!$joined) {
    my $mreq = Socket::inet_aton($MDNS_ADDR) . Socket::inet_aton($route->{ip});
    $joined=setsockopt($sock, $IPPROTO_IP, $IP_ADD_MEMBERSHIP, $mreq) ? 1 : 0;
   }
   if($joined) {
    $mdns_joined{$key}=1;
    &log("mDNS: joined multicast on $route->{iface} ($route->{ip})");
   } else {
    &log("mDNS: multicast join failed on $route->{iface} ($route->{ip}): $!");
   }
  }
  # Drop stale memberships for interfaces that disappeared
  foreach my $key (keys %mdns_joined) {
   next if($current{$key});
   delete $mdns_joined{$key};
  }
  &log("mDNS: no active IPv4 interfaces found for multicast join") if(!@routes && !keys %mdns_joined);
  $mdns_join_time=time();
 };
 $mdns_rejoin->();

 &log("mDNS: responder started for $mdns_hostname.local on port $MDNS_PORT");

 my $sel=IO::Select->new($sock);
 while(1) {
  # Re-join multicast groups periodically to handle hotplug
  if(time() - $mdns_join_time >= $MDNS_REJOIN_INTERVAL) {
   $mdns_rejoin->();
  }
  my @ready=$sel->can_read($MDNS_REJOIN_INTERVAL);
  next if(!@ready);
  my $buf="";
  my $from=recv($sock, $buf, 4096, 0);
  next if(!defined $from);
  my ($qport,$qaddr)=Socket::sockaddr_in($from);

  # Parse DNS query header
  next if(length($buf) < 12);
  my ($id,$flags,$qdcount)=unpack("nnn",substr($buf,0,6));
  # Only respond to queries (QR=0)
  next if($flags & 0x8000);
  next if($qdcount < 1);

  my $offset=12;
  my $matched=0;
  for(my $i=0;$i<$qdcount;$i++) {
   my ($qname,$next_offset,$ok)=&webui_mdns_read_name($buf,$offset);
   last if(!$ok);
   $offset=$next_offset;
   last if($offset + 4 > length($buf));
   my ($qtype,$qclass)=unpack("nn",substr($buf,$offset,4));
   $offset+=4;
   if(lc($qname) eq "$mdns_hostname.local" && ($qclass & 0x7FFF) == 1 && ($qtype == 1 || $qtype == 255)) {
    $matched=1;
    last;
   }
  }

  # Respond to A record queries for pgenerator.local, even when bundled with
  # compressed AAAA questions in the same packet.
  next if(!$matched);

  my $querier_ip=Socket::inet_ntoa($qaddr);
  my $best_ip=&webui_mdns_best_ip($querier_ip);
  next if($best_ip eq "");

  my $resp=pack("n",0);           # ID=0 for mDNS
  $resp.=pack("n",0x8400);        # flags: QR=1, AA=1
  $resp.=pack("nnnn",0,1,0,0);

  foreach my $label (split(/\./,"$mdns_hostname.local")) {
   $resp.=pack("C",length($label)).$label;
  }
  $resp.=pack("C",0);
  $resp.=pack("nn",1,0x8001);
  $resp.=pack("N",120);
  $resp.=pack("n",4);
  $resp.=Socket::inet_aton($best_ip);

  my $IP_MULTICAST_IF=eval { Socket::IP_MULTICAST_IF() } || 32;
  setsockopt($sock, $IPPROTO_IP, $IP_MULTICAST_IF, Socket::inet_aton($best_ip));
  my $mcast_dest=Socket::sockaddr_in($MDNS_PORT, Socket::inet_aton($MDNS_ADDR));
  send($sock, $resp, 0, $mcast_dest);

  # Also send unicast reply directly to the querier (RFC 6762 compatibility)
  send($sock, $resp, 0, $from);

  &log("mDNS: replied $mdns_hostname.local -> $best_ip (querier=$querier_ip)");
 }
}

###############################################
#              HTTP Server                    #
###############################################
my $_info_cache="";
my $_info_cache_time=0;
my $_INFO_CACHE_TTL=5;

my $_cec_cache="";
my $_cec_cache_time=0;
my $_CEC_CACHE_TTL=30;

my $_caps_cache="";
my $_caps_cache_time=0;
my $_stats_cache="";
my $_stats_cache_time=0;
my $_STATS_CACHE_TTL=2;
my $_stats_cpu_total=0;
my $_stats_cpu_idle=0;
my $_stats_cpu_last=0;

# Meter state
my $_meter_series_file="/tmp/meter_series.json";
my $_meter_wrapper="/usr/bin/spotread_wrapper.sh";
my $_meter_session="/usr/bin/meter_session.sh";
my $_meter_read_file="/tmp/meter_read.json";
my $_meter_session_pid_file="/tmp/meter_session.pid";
my $_meter_session_fifo="/tmp/meter_session.cmd";
my $_meter_session_config_file="/tmp/meter_session.config";
my $_meter_last_read_time=0;
my $_ccss_dir="/usr/share/PGenerator/ccss";

# Display technology map: key => [spotread_y_flag, ccss_filename]
my $_dtype_info={
 "lcd"          => ["l",""],
 "oled"         => ["c",""],
 "projector"    => ["p",""],
 "oled_generic" => ["c","WRGB_OLED_LG.ccss"],
 "qdoled"       => ["c","QD-OLED_Generic.ccss"],
 "lcd_wled"     => ["l","WLEDFamily_07Feb11.ccss"],
 "lcd_ccfl"     => ["l","CCFLFamily_07Feb11.ccss"],
 "lcd_wgccfl"   => ["l","WGCCFLFamily_07Feb11.ccss"],
 "lcd_rgbled"   => ["l","RGBLEDFamily_07Feb11.ccss"],
 "plasma"       => ["c","PlasmaFamily_20Jul12.ccss"],
 "projector_ccss"=>["p","ProjectorFamily_07Feb11.ccss"],
 "crt"          => ["c","CRT.ccss"],
 "l"            => ["l",""],
 "c"            => ["c",""],
 "p"            => ["p",""],
};

sub resolve_display_type (@) {
 my ($key)=@_;
 # ccss_FILENAME or custom_FILENAME: look up a .ccss file in system or custom dir
 if($key=~/^(?:ccss|custom)_(.+)$/) {
  my $fname=$1;
  $fname=~s{[/\\]}{}g; # strip path separators
  # allow letters, digits, dot, underscore, dash, parentheses, spaces (ccss filenames include these)
  $fname=~s/[^a-zA-Z0-9._\-()\[\] ]//g;
  my $sys="$_ccss_dir/$fname";
  my $cust="$_ccss_dir/custom/$fname";
  if(-f $sys)  { return ("c",$sys); }
  if(-f $cust) { return ("c",$cust); }
  return ("c","");
 }
 my $info=$_dtype_info->{lc($key)}||["l",""];
 my $y_flag=$info->[0];
 my $ccss_file=$info->[1]ne""?"$_ccss_dir/$info->[1]":"";
 return ($y_flag,$ccss_file);
}

sub webui_http (@) {
 $SIG{PIPE}='IGNORE';
 my $http_port=80;

 my $http_server = IO::Socket::INET->new(
  LocalHost => "0.0.0.0",
  LocalPort => $http_port,
  Proto     => 'tcp',
  Listen    => 128,
  ReuseAddr => 1,
 );
 if(!$http_server) {
  &log("WebUI: failed to bind port $http_port: $! — trying 8080");
  $http_port=8080;
  $http_server = IO::Socket::INET->new(
   LocalHost => "0.0.0.0",
   LocalPort => $http_port,
   Proto     => 'tcp',
   Listen    => 128,
   ReuseAddr => 1,
  ) || do { &log("WebUI: failed to bind port $http_port: $!"); return; };
 }
 &log("WebUI: HTTP server started on port $http_port");

 while(1) {
  my $client=$http_server->accept();
  next if(!$client);
  eval {
   # Per-socket read/write timeout (thread-safe, unlike alarm/SIGALRM which is process-wide)
   setsockopt($client, Socket::SOL_SOCKET(), Socket::SO_RCVTIMEO(), pack('l!l!', 5, 0));
   setsockopt($client, Socket::SOL_SOCKET(), Socket::SO_SNDTIMEO(), pack('l!l!', 5, 0));
   # Read request
   my $req="";
   while(my $line=<$client>) {
    $req.=$line;
    last if($line=~/^\r?\n$/);
   }
   # Read body if Content-Length present
   my $body="";
   if($req=~/Content-Length:\s*(\d+)/i) {
    my $cl=$1;
    while(length($body) < $cl) {
     my $chunk="";
     my $read_bytes=read($client,$chunk,$cl-length($body));
     last if(!defined $read_bytes || $read_bytes <= 0);
     $body.=$chunk;
    }
   }

   my ($method,$path)=$req=~/^(GET|POST|PUT|OPTIONS)\s+(\S+)/;
   $path="" if(!defined $path);
   &log("WebUI: $method $path");

   # CORS headers for API
   my $cors="Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\nConnection: close\r\n";

   if($method eq "OPTIONS") {
    print $client "HTTP/1.1 204 No Content\r\n$cors\r\n";
   }
   elsif($path eq "/" || $path eq "/index.html") {
    my $html=&webui_html();
    my $len=length($html);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: $len\r\n$cors\r\n$html";
   }
   elsif($path eq "/favicon.ico") {
    my $ico_path="/usr/share/PGenerator/favicon.ico";
    if(-f $ico_path) {
     open(my $fh, "<:raw", $ico_path);
     my $ico_data; { local $/; $ico_data=<$fh>; } close($fh);
     my $len=length($ico_data);
     print $client "HTTP/1.1 200 OK\r\nContent-Type: image/x-icon\r\nContent-Length: $len\r\nCache-Control: public, max-age=604800\r\n\r\n";
     print $client $ico_data;
    } else {
     print $client "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n";
    }
   }
   elsif($path eq "/api/config") {
    if($method eq "GET") {
     # Return current config as JSON
     my $json=&webui_config_json();
     my $len=length($json);
     print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$json";
    }
    elsif($method eq "POST") {
     # Apply config changes
     my ($result,$need_restart)=&webui_apply_config($body);
     my $len=length($result);
     print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
     if($need_restart) {
      close($client);
      undef $client;
      &pattern_generator_stop();
      &pattern_generator_start();
     }
    }
   }
   elsif($path eq "/api/ping") {
    my $r='{"ok":1}';
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 8\r\n$cors\r\n$r";
   }
   elsif($path eq "/api/info") {
    my $now=time();
    if(!$_info_cache || ($now - $_info_cache_time) >= $_INFO_CACHE_TTL) {
     $_info_cache=&webui_info_json();
     $_info_cache_time=$now;
    }
    my $len=length($_info_cache);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$_info_cache";
   }
  elsif($path eq "/api/stats") {
   my $now=time();
   if(!$_stats_cache || ($now - $_stats_cache_time) >= $_STATS_CACHE_TTL) {
    $_stats_cache=&webui_stats_json();
    $_stats_cache_time=$now;
   }
   my $len=length($_stats_cache);
   print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$_stats_cache";
  }
   elsif($path eq "/api/restart") {
    my $r='{"status":"ok","message":"Pattern generator restarted"}';
    my $len=length($r);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$r";
    close($client);
    undef $client;
    &pattern_generator_stop();
    &pattern_generator_start();
   }
   elsif($path eq "/api/submit_logs" && $method eq "POST") {
    my $tmp=&webui_create_logs_bundle();
    if(!$tmp || !-f $tmp) {
     my $r='{"status":"error","message":"Could not create log bundle"}';
     my $len=length($r);
     print $client "HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$r";
    } else {
     if(open(my $fh,"<:raw",$tmp)) {
      my $size=-s $tmp;
      my $fname="PGenerator_diag_${version}.txt";
      print $client "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Disposition: attachment; filename=\"$fname\"\r\nContent-Length: $size\r\n$cors\r\n";
      while(read($fh,my $buf,16384)){ print $client $buf; }
      close($fh);
     } else {
      my $r='{"status":"error","message":"Failed to read bundle"}';
      my $len=length($r);
      print $client "HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$r";
     }
     unlink $tmp;
    }
   }
   elsif($path eq "/api/reboot") {
    my $r='{"status":"ok","message":"Rebooting..."}';
    my $len=length($r);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$r";
    close($client);
    undef $client;
    my $cmd_b64=encode_base64("REBOOT","");
    system("(sleep 2 && PG_CMD=\"$cmd_b64\" sudo -E /usr/bin/PGenerator_cmd.pl) &");
   }
   elsif($path eq "/api/modes") {
    my $json=&webui_modes_json();
    my $len=length($json);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$json";
   }
   elsif($path eq "/api/capabilities") {
    my $now=time();
    if(!$_caps_cache || ($now - $_caps_cache_time) >= 300) {
     $_caps_cache=&webui_capabilities_json();
     $_caps_cache_time=$now;
    }
    my $len=length($_caps_cache);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$_caps_cache";
   }
   elsif($path eq "/api/wifi/scan") {
    my $json=&webui_wifi_scan_json();
    my $len=length($json);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$json";
   }
   elsif($path eq "/api/wifi/connect" && $method eq "POST") {
    my $result=&webui_wifi_connect($body);
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
  elsif($path eq "/api/wifi/disconnect" && $method eq "POST") {
   my $result='{"status":"ok","message":"Disconnecting WiFi client"}';
   my $len=length($result);
   print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   close($client);
   undef $client;
   &sudo("WIFI_DISCONNECT","wlan0");
  }
  elsif($path eq "/api/wifi/forget" && $method eq "POST") {
   my $result='{"status":"ok","message":"Forgetting WiFi network"}';
   my $len=length($result);
   print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   close($client);
   undef $client;
   &sudo("WIFI_FORGET","wlan0");
  }
   elsif($path eq "/api/wifi/ap" && $method eq "GET") {
    my $json=&webui_wifi_ap_json();
    my $len=length($json);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$json";
   }
   elsif($path eq "/api/wifi/status") {
    my $json=&webui_wifi_status_json();
    my $len=length($json);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$json";
   }
   elsif($path eq "/api/wifi/ap" && $method eq "POST") {
    my $result=&webui_wifi_ap_apply($body);
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/infoframes") {
    my $json=&webui_infoframes_json();
    my $len=length($json);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$json";
   }
   elsif($path=~/^\/api\/cec\/(\w+)/) {
    my $cec_cmd=$1;
    my $result;
    if($cec_cmd eq "status") {
     my $now=time();
     if(!$_cec_cache || ($now - $_cec_cache_time) >= $_CEC_CACHE_TTL) {
      $_cec_cache=&webui_cec($cec_cmd);
      $_cec_cache_time=$now;
     }
     $result=$_cec_cache;
    } else {
     $result=&webui_cec($cec_cmd);
     $_cec_cache="";
     $_cec_cache_time=0;
    }
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/resolve/connect" && $method eq "POST") {
    my $result=&webui_resolve_connect($body);
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/resolve/disconnect" && $method eq "POST") {
    my $result=&webui_resolve_disconnect();
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/resolve/status") {
    my $connected=($calibration_client_software eq "Resolve") ? "true" : "false";
    my $ip=$calibration_client_ip||"";
    my $result="{\"connected\":$connected,\"ip\":\"$ip\"}";
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/pattern" && $method eq "POST") {
    my $result=&webui_pattern($body);
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/update/check") {
    # Run update check with a 10s cap to avoid blocking HTTP thread
    my @args_b64=map { encode_base64($_,"") } ("BASH_CMD","PGPLUS_CHECK");
    my $result=`timeout 10 env $pg_cmd_env="@args_b64" $sudo_cmd 2>/dev/null`;
    chomp($result);
    $result='{"status":"error","message":"Update check failed"}' if($result eq "" || $result!~/^\{/);
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/update/apply" && $method eq "POST") {
    my $r='{"status":"ok","message":"Update started. The device will restart shortly."}';
    my $len=length($r);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$r";
    close($client);
    undef $client;
    my $cmd_b64=encode_base64("BASH_CMD","")." ".encode_base64("PGPLUS_APPLY","");
    system("(sleep 2 && PG_CMD=\"$cmd_b64\" sudo -E /usr/bin/PGenerator_cmd.pl) &");
   }
   elsif($path eq "/api/boot/memory") {
    if($method eq "GET") {
     my $gpu_mem=&pgenerator_cmd("GET_GPU_MEMORY");
     chomp($gpu_mem);
     $gpu_mem=~s/M$//;
     $gpu_mem||="64";
     my $json="{\"gpu_mem\":\"$gpu_mem\"}";
     my $len=length($json);
     print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$json";
    }
    elsif($method eq "POST") {
     my $gpu_val;
     $gpu_val=$1 if($body=~/"gpu_mem"\s*:\s*"(\d+)"/);
     if($gpu_val && $gpu_val=~/^(64|128|192|256)$/) {
      my $r="{\"status\":\"ok\",\"message\":\"GPU memory set to ${gpu_val}MB. Rebooting...\"}";
      my $len=length($r);
      print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$r";
      close($client);
      undef $client;
      my $cmd_b64=encode_base64("SET_GPU_MEMORY","")." ".encode_base64("$gpu_val","");
      system("(sleep 2 && PG_CMD=\"$cmd_b64\" sudo -E /usr/bin/PGenerator_cmd.pl) &");
     } else {
      my $r='{"status":"error","message":"Invalid GPU memory value"}';
      my $len=length($r);
      print $client "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$r";
     }
    }
   }
   ###############################################
   #           Meter API Endpoints               #
   ###############################################
   elsif($path eq "/api/meter/status") {
    my $result=&webui_meter_status();
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/meter/read" && $method eq "POST") {
    my $result=&webui_meter_read($body);
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/meter/read/result") {
    my $result=&webui_meter_read_result();
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/meter/series" && $method eq "POST") {
    my $result=&webui_meter_series_start($body);
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/meter/series/status") {
    my $result=&webui_meter_series_status();
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/meter/stop" && $method eq "POST") {
    my $result=&webui_meter_stop();
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/meter/clear" && $method eq "POST") {
    my $result=&webui_meter_clear();
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/meter/reset" && $method eq "POST") {
    my $result=&webui_meter_reset();
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/meter/settings") {
    if($method eq "POST") {
     my $result=&webui_meter_settings_save($body);
     my $len=length($result);
     print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
    } else {
     my $result=&webui_meter_settings_load();
     my $len=length($result);
     print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
    }
   }
   elsif($path eq "/api/ccss/list") {
    my $result=&webui_ccss_list();
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/ccss/all") {
    my $result=&webui_ccss_all();
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/ccss/upload" && $method eq "POST") {
    my $result=&webui_ccss_upload($body);
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path=~/^\/api\/ccss\/delete\/(.+)/ && $method eq "POST") {
    my $fname=$1;
    my $result=&webui_ccss_delete($fname);
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   else {
    my $msg="404 Not Found";
    print $client "HTTP/1.1 404 Not Found\r\nContent-Length: ".length($msg)."\r\n\r\n$msg";
   }
  };
  if($@) {
   &log("WebUI: request error: $@");
  }
  if($client) {
   eval { shutdown($client, 2); };
   eval { close($client); };
  }
 }
}

###############################################
#         Meter API Functions                 #
###############################################
my $_meter_was_detected=0;

sub webui_meter_status (@) {
 my $json=`sudo bash $_meter_wrapper --detect 2>/dev/null`;
 chomp($json);
 $json='{"detected":false,"name":null,"usb_id":null,"spotread_available":false}' if($json eq "" || $json!~/^\{/);
 # Track detection state for auto-reset
 if($json=~/"detected"\s*:\s*true/) {
  $_meter_was_detected=1;
 } elsif($_meter_was_detected) {
  # Meter was previously detected but now gone — try USB reset once
  # But NOT if a series scan is running (would kill spotread)
  $_meter_was_detected=0;
  my $series_running=`pgrep -f meter_series.sh 2>/dev/null`;
  if($series_running=~/\d/) {
   &log("WebUI: meter disappeared but series is running, skipping USB reset");
  } else {
   &log("WebUI: meter disappeared, attempting USB reset");
   &webui_meter_reset();
   $json=`sudo bash $_meter_wrapper --detect 2>/dev/null`;
   chomp($json);
   $json='{"detected":false,"name":null,"usb_id":null,"spotread_available":false}' if($json eq "" || $json!~/^\{/);
   if($json=~/"detected"\s*:\s*true/) {
    $_meter_was_detected=1;
    &log("WebUI: meter recovered after USB reset");
   }
  }
 }
 return $json;
}

sub webui_meter_session_alive (@) {
 return 0 unless(-f $_meter_session_pid_file);
 my $pid="";
 if(open(my $fh,"<",$_meter_session_pid_file)) { local $/; $pid=<$fh>; close($fh); }
 chomp $pid;
 return 0 unless($pid=~/^\d+$/);
 # The daemon runs as root but webui runs as the pgenerator user, so
 # kill(0,$pid) fails with EPERM on a live daemon. Check /proc instead —
 # /proc/$pid is readable by anyone on Linux.
 return -d "/proc/$pid" ? $pid : 0;
}

sub webui_meter_session_config_matches (@) {
 my ($want)=@_;
 return 0 unless(-f $_meter_session_config_file);
 my $cur="";
 if(open(my $fh,"<",$_meter_session_config_file)) { local $/; $cur=<$fh>; close($fh); }
 chomp $cur;
 return $cur eq $want ? 1 : 0;
}

sub webui_meter_session_stop (@) {
 # Try graceful STOP via FIFO first (lets the daemon quit spotread cleanly).
 if(-p $_meter_session_fifo) {
  if(open(my $fh,">",$_meter_session_fifo)) { print $fh "STOP\n"; close($fh); }
 }
 # Wait briefly for the daemon to exit on its own.
 my $waited=0;
 while($waited < 20 && &webui_meter_session_alive()) {
  Time::HiRes::sleep(0.1);
  $waited++;
 }
 # Hard kill anything still hanging on.
 if(&webui_meter_session_alive()) {
  system("sudo pkill -9 -f 'meter_session.sh' 2>/dev/null");
  system("sudo pkill -9 -x spotread 2>/dev/null");
  Time::HiRes::sleep(0.2);
 }
 unlink($_meter_session_pid_file, $_meter_session_config_file, $_meter_session_fifo);
}

sub webui_meter_session_start (@) {
 my ($display_type,$ccss_file,$refresh_rate,$disable_aio,$config)=@_;
 # Persist the config the daemon should advertise (used for change detection).
 if(open(my $fh,">",$_meter_session_config_file)) { print $fh $config; close($fh); }
 # Launch detached as root. The daemon writes its own PID file once it grabs
 # the lock; we wait for the FIFO to appear before returning.
 my $aio_flag=$disable_aio ? "1" : "0";
 system("setsid sudo /bin/bash $_meter_session '$display_type' '$ccss_file' '$refresh_rate' '$aio_flag' </dev/null >/dev/null 2>&1 &");
 my $waited=0;
 while($waited < 200 && ! -p $_meter_session_fifo) {
  Time::HiRes::sleep(0.1);
  $waited++;
  # If the daemon died early (init failure), the read result file will
  # contain a status:error — surface that quickly instead of waiting 20 s.
  if(-f $_meter_read_file) {
   my $check="";
   if(open(my $fh,"<",$_meter_read_file)) { local $/; $check=<$fh>; close($fh); }
   last if($check=~/"status"\s*:\s*"error"/);
  }
 }
 return -p $_meter_session_fifo ? 1 : 0;
}

sub webui_meter_read (@) {
 my ($body)=@_;

 # Refuse single reads while a series is actively running
 if(-f $_meter_series_file) {
  my $scheck="";
  if(open(my $fh,"<",$_meter_series_file)) { local $/; $scheck=<$fh>; close($fh); }
  if($scheck=~/"status"\s*:\s*"running"/) {
   my $alive=`pgrep -f meter_series.sh 2>/dev/null`;
   if($alive=~/\d/) {
     &log("WebUI: manual meter read requested while series helper still running; stopping stale series first");
     &webui_meter_stop();
     select(undef,undef,undef,0.5);
   }
  }
 }

 # Debounce: coalesce accidental double-clicks. The session daemon serializes
 # the actual reads, so this is purely a UI-side protection.
 my $now=Time::HiRes::time();
 if($now - $_meter_last_read_time < 0.25) {
  return '{"status":"measuring"}';
 }
 $_meter_last_read_time=$now;

 my $display_type_key="lcd";
 $display_type_key=$1 if($body=~/"display_type"\s*:\s*"([^"\\]{1,160})"/);
 my ($display_type,$ccss_file)=&resolve_display_type($display_type_key);
 my $refresh_rate="";
 $refresh_rate=$1 if($body=~/"refresh_rate"\s*:\s*"([\d.]+)"/);
 my $disable_aio=0;
 $disable_aio=1 if($body=~/"disable_aio"\s*:\s*true/i);
 my $patch_r="";
 $patch_r=$1 if($body=~/"patch_r"\s*:\s*(\d+)/);
 my $patch_g="";
 $patch_g=$1 if($body=~/"patch_g"\s*:\s*(\d+)/);
 my $patch_b="";
 $patch_b=$1 if($body=~/"patch_b"\s*:\s*(\d+)/);
 my $patch_size=10;
 $patch_size=$1 if($body=~/"patch_size"\s*:\s*(\d+)/);
 my $delay_ms=2000;
 $delay_ms=$1 if($body=~/"delay_ms"\s*:\s*(\d+)/);
 # Default to a 50% mid-grey patch when the caller didn't specify RGB —
 # the persistent session always displays a patch before reading.
 if($patch_r eq "" || $patch_g eq "" || $patch_b eq "") {
  $patch_r=128; $patch_g=128; $patch_b=128;
 }
 my $patch_name="Manual";
 my $patch_ire=0;
 if($patch_r==$patch_g && $patch_g==$patch_b) {
  $patch_ire=int(($patch_r/255)*100+0.5);
  $patch_name="${patch_ire}pct";
 }

 # The session daemon starts spotread once and reuses it for every read.
 # Restart only when the meter config (display type, ccss, refresh, AIO) changes
 # or the daemon isn't running.
 my $aio_flag=$disable_aio ? "1" : "0";
 my $want_config="$display_type|$ccss_file|$refresh_rate|$aio_flag";
 my $alive=&webui_meter_session_alive();
 my $needs_restart= !$alive || !&webui_meter_session_config_matches($want_config);
 if($needs_restart) {
  if($alive) {
   &log("WebUI: meter session config changed, restarting daemon");
   &webui_meter_session_stop();
  } else {
   # Belt-and-suspenders: clear any lingering spotread holding the meter.
   system("sudo bash $_meter_wrapper --kill 2>/dev/null");
   select(undef,undef,undef,0.2);
  }
  unlink($_meter_read_file);
  &log("WebUI: starting meter session (display_type=$display_type, ccss=$ccss_file, refresh=$refresh_rate, aio_off=$disable_aio)");
  if(!&webui_meter_session_start($display_type,$ccss_file,$refresh_rate,$disable_aio,$want_config)) {
   &log("WebUI: meter session failed to start");
   if(open(my $fh,">",$_meter_read_file)) { print $fh '{"status":"error","message":"Meter session failed to start"}'; close($fh); }
   return '{"status":"error","message":"Meter session failed to start"}';
  }
 }

 # Mark measuring so the polling endpoint sees a fresh in-flight state and
 # can't return the previous reading by mistake.
 if(open(my $fh,">",$_meter_read_file)) { print $fh '{"status":"measuring"}'; close($fh); }

 # Send the READ command to the daemon. The settle delay is only applied
 # by the daemon when the patch RGB actually changes — repeat reads on the
 # same patch (Continuous mode) skip both the redisplay and the wait.
 if(open(my $fh,">>",$_meter_session_fifo)) {
  print $fh "READ $patch_r $patch_g $patch_b $patch_size $patch_ire $patch_name $delay_ms\n";
  close($fh);
 } else {
  &log("WebUI: meter session FIFO open failed: $!");
  return '{"status":"error","message":"Session FIFO unavailable"}';
 }

 return '{"status":"measuring"}';
}

sub webui_meter_read_result (@) {
 if(-f $_meter_read_file) {
  my $json="";
  if(open(my $fh,"<",$_meter_read_file)) { local $/; $json=<$fh>; close($fh); }
  chomp($json);
  if($json ne "") {
   if($json=~/measuring/ || $json=~/"status"\s*:\s*"running"/) {
    my $age=time() - (stat($_meter_read_file))[9];
    if($age > 90) {
     return '{"status":"error","message":"Read timed out"}';
    }
    return '{"status":"measuring"}';
   }
   if($json=~/"status"\s*:\s*"complete"/) {
    $json=~s/"status"\s*:\s*"complete"/"status":"ok"/;
    return $json;
   }
   if($json=~/"status"\s*:\s*"cancelled"/) {
    return '{"status":"error","message":"Read cancelled"}';
   }
   return $json;
  }
 }
 return '{"status":"idle"}';
}

sub webui_meter_series_start (@) {
 my ($body)=@_;
 # Parse request
 my $type="greyscale";
 $type=$1 if($body=~/"type"\s*:\s*"(\w+)"/);
 my $points=21;
 $points=$1 if($body=~/"points"\s*:\s*(\d+)/);
 my $display_type_key="lcd";
 $display_type_key=$1 if($body=~/"display_type"\s*:\s*"([^"\\]{1,160})"/);
 my ($display_type,$ccss_file)=&resolve_display_type($display_type_key);
 my $delay_ms=3000;
 $delay_ms=$1 if($body=~/"delay_ms"\s*:\s*(\d+)/);
 my $patch_size=10;
 $patch_size=$1 if($body=~/"patch_size"\s*:\s*(\d+)/);
 my $signal_range=0;
 $signal_range=$1 if($body=~/"signal_range"\s*:\s*"?(\d+)"?/);
 my $patch_insert=0;
 $patch_insert=1 if($body=~/"patch_insert"\s*:\s*true/i);
 my $refresh_rate="";
 $refresh_rate=$1 if($body=~/"refresh_rate"\s*:\s*"([\d.]+)"/);
 my $disable_aio=0;
 $disable_aio=1 if($body=~/"disable_aio"\s*:\s*true/i);
 my $target_gamut="";
 $target_gamut=lc($1) if($body=~/"target_gamut"\s*:\s*"([A-Za-z0-9_]+)"/);
 $target_gamut="" unless($target_gamut eq "bt709" || $target_gamut eq "bt2020" || $target_gamut eq "p3d65");

 # Cancel any running series and clean up
 &webui_meter_stop();
 # Brief pause to let killed processes release USB device
 select(undef,undef,undef,0.5);

 # Build step list as JSON array for the helper script
 # Measurement order: WHITE first (reference), then 0%→95% ascending
 my @steps;
 my $dv_series=(int($pgenerator_conf{"dv_status"} || 0) == 1 || int($pgenerator_conf{"is_ll_dovi"} || 0) == 1 || int($pgenerator_conf{"is_std_dovi"} || 0) == 1) ? 1 : 0;
 if($type eq "greyscale") {
  my @ire_vals;
  if($points==11) {
   @ire_vals=(0,10,20,30,40,50,60,70,80,90,100);
  } else {
   @ire_vals=(0,5,10,15,20,25,30,35,40,45,50,55,60,65,70,75,80,85,90,95,100);
  }
  # 100% first (white reference), then 0%→95% ascending.
  # Reading white first lets every subsequent ΔE be computed immediately
  # and never change — HCFR achieves this with a pre-configured target
  # luminance; we use the actual measured white instead.
  my @ordered = (100, sort { $a <=> $b } grep { $_ != 100 } @ire_vals);
  my $lim=($signal_range==1)?1:0;
  @steps=map {
   my $v=$_;
   my $c=0;
   if($dv_series) {
    my $stim=$v/100;
    $c=$lim ? int(16 + (($stim ** (1/2.2)) * 219) + .5) : int((($stim ** (1/2.2)) * 255) + .5);
   } else {
    my $level=int($v/100*219+.5);
    $c=$lim?($level+16):int($level*255/219+.5);
   }
   "{\"ire\":$v,\"r\":$c,\"g\":$c,\"b\":$c,\"name\":\"${v}%\"}";
  } @ordered;
 } elsif($type eq "colors") {
  my $signal_mode=&webui_pattern_signal_mode("");
  my $min_code=($signal_range==1)?16:0;
  my $span_code=($signal_range==1)?219:255;
    my $max_code=$min_code+$span_code;
    my %primaries=(
     bt709=>{M=>[[3.2406,-1.5372,-0.4986],[-0.9689,1.8758,0.0415],[0.0557,-0.2040,1.0570]],RGB_TO_XYZ=>[[0.4124564,0.3575761,0.1804375],[0.2126729,0.7151522,0.0721750],[0.0193339,0.1191920,0.9503041]]},
     bt2020=>{M=>[[1.7166511880,-0.3556707838,-0.2533662814],[-0.6666843518,1.6164812366,0.0157685458],[0.0176398574,-0.0427706133,0.9421031212]],RGB_TO_XYZ=>[[0.6369580483,0.1446169036,0.1688809752],[0.2627002120,0.6779980715,0.0593017165],[0.0000000000,0.0280726930,1.0609850577]]},
     p3d65=>{M=>[[2.4934969119,-0.9313836179,-0.4027107845],[-0.8294889696,1.7626640603,0.0236246858],[0.0358458302,-0.0761723893,0.9568845240]],RGB_TO_XYZ=>[[0.4865709486,0.2656676932,0.1982172852],[0.2289745641,0.6917385218,0.0792869141],[0.0000000000,0.0451133819,1.0439443689]]}
    );
    my $gamut_key="bt709";
    if($signal_mode eq "dv") {
     $gamut_key="p3d65";
    } elsif($signal_mode eq "hdr10" || $signal_mode eq "hlg") {
     $gamut_key="bt2020";
    } elsif(int($pgenerator_conf{"primaries"} || 0) == 1) {
     $gamut_key="bt2020";
    } elsif(int($pgenerator_conf{"primaries"} || 0) == 2) {
     $gamut_key="p3d65";
    }
    my $container_key=$gamut_key;
    my $target_key=$target_gamut ne "" ? $target_gamut : $container_key;
    my @MI=@{$primaries{$container_key}{M}};
    my @RGB_TO_XYZ=@{$primaries{$target_key}{RGB_TO_XYZ}};
    my $encode_linear=sub {
     my ($linear)=@_;
     $linear=0 if(!defined $linear || $linear < 0);
     $linear=1 if($linear > 1);
     my $encoded=($signal_mode eq "hdr10") ? &webui_pattern_pq_encode_normalized($linear*100) : ($linear**(1/2.2));
     return int($min_code + $encoded*$span_code + .5);
    };
    my @classic=(
     ["Gray 35","gray",0.35],
     ["Gray 50","gray",0.50],
     ["Gray 65","gray",0.65],
     ["Gray 80","gray",0.80],
     ["Dark Skin","xyYn",0.405119,0.36253,0.096774],
     ["Light Skin","xyYn",0.379756,0.357031,0.353705],
     ["Blue Sky","xyYn",0.249396,0.266854,0.18913],
     ["Foliage","xyYn",0.338784,0.433265,0.132836],
     ["Blue Flower","xyYn",0.267688,0.25314,0.235775],
     ["Bluish Green","xyYn",0.261653,0.359045,0.425252],
     ["Orange","xyYn",0.512087,0.410373,0.287229],
     ["Purplish Blue","xyYn",0.213095,0.186377,0.115692],
     ["Moderate Red","xyYn",0.461291,0.312073,0.187204],
     ["Purple","xyYn",0.288075,0.217532,0.064716],
     ["Yellow Green","xyYn",0.37852,0.496473,0.436288],
     ["Orange Yellow","xyYn",0.473379,0.443246,0.433456],
     ["Blue","xyYn",0.186955,0.133934,0.060722],
     ["Green","xyYn",0.306493,0.495107,0.234403],
     ["Red","xyYn",0.547377,0.317462,0.114731],
     ["Yellow","xyYn",0.44792,0.475618,0.597462],
     ["Magenta","xyYn",0.371346,0.24177,0.187509],
     ["Cyan","xyYn",0.19619,0.266985,0.193415]
    );
    push @steps, "{\"ire\":100,\"r\":$max_code,\"g\":$max_code,\"b\":$max_code,\"name\":\"White\"}";
    push @steps, "{\"ire\":0,\"r\":$min_code,\"g\":$min_code,\"b\":$min_code,\"name\":\"Black\"}";
    foreach my $src (@classic) {
     my ($name,$kind,@vals)=@$src;
     if($kind eq "gray") {
      my $level=$vals[0];
      my $code=$encode_linear->($level);
      my $ire=int($level*100 + .5);
      push @steps, "{\"ire\":$ire,\"r\":$code,\"g\":$code,\"b\":$code,\"name\":\"$name\"}";
      next;
     }
     my ($x,$y,$Yn)=@vals;
     my $X=$x/$y*$Yn;
     my $Y=$Yn;
     my $Z=(1-$x-$y)/$y*$Yn;
     my $rl=$MI[0][0]*$X+$MI[0][1]*$Y+$MI[0][2]*$Z;
     my $gl=$MI[1][0]*$X+$MI[1][1]*$Y+$MI[1][2]*$Z;
     my $bl=$MI[2][0]*$X+$MI[2][1]*$Y+$MI[2][2]*$Z;
     my $mx=$rl;$mx=$gl if $gl>$mx;$mx=$bl if $bl>$mx;
     if($mx>1){$rl/=$mx;$gl/=$mx;$bl/=$mx;}
     $rl=0 if $rl<0;$gl=0 if $gl<0;$bl=0 if $bl<0;
     my $r=$encode_linear->($rl);
     my $g=$encode_linear->($gl);
     my $b=$encode_linear->($bl);
     my $ire=int($Yn*100 + .5);
     push @steps, "{\"ire\":$ire,\"r\":$r,\"g\":$g,\"b\":$b,\"name\":\"$name\",\"target_x\":$x,\"target_y\":$y,\"target_Yn\":$Yn}";
    }
    foreach my $sat (
     ["100% Red","Red",1,0,0],
     ["100% Green","Green",0,1,0],
     ["100% Blue","Blue",0,0,1],
     ["100% Cyan","Cyan",0,1,1],
     ["100% Magenta","Magenta",1,0,1],
     ["100% Yellow","Yellow",1,1,0]
    ) {
     my ($name,$series_color,$r_mix,$g_mix,$b_mix)=@$sat;
     my $mix_X=$RGB_TO_XYZ[0][0]*$r_mix+$RGB_TO_XYZ[0][1]*$g_mix+$RGB_TO_XYZ[0][2]*$b_mix;
     my $mix_Y=$RGB_TO_XYZ[1][0]*$r_mix+$RGB_TO_XYZ[1][1]*$g_mix+$RGB_TO_XYZ[1][2]*$b_mix;
     my $mix_Z=$RGB_TO_XYZ[2][0]*$r_mix+$RGB_TO_XYZ[2][1]*$g_mix+$RGB_TO_XYZ[2][2]*$b_mix;
     my $mix_sum=$mix_X+$mix_Y+$mix_Z;
     my $px=$mix_sum>0?$mix_X/$mix_sum:0.3127;
     my $py=$mix_sum>0?$mix_Y/$mix_sum:0.329;
     my $X=$px/$py; my $Y=1; my $Z=(1-$px-$py)/$py;
     my $rl=$MI[0][0]*$X+$MI[0][1]*$Y+$MI[0][2]*$Z;
     my $gl=$MI[1][0]*$X+$MI[1][1]*$Y+$MI[1][2]*$Z;
     my $bl=$MI[2][0]*$X+$MI[2][1]*$Y+$MI[2][2]*$Z;
     my $mx=$rl;$mx=$gl if $gl>$mx;$mx=$bl if $bl>$mx;
     if($mx>0){$rl/=$mx;$gl/=$mx;$bl/=$mx;}
     $rl=0 if $rl<0;$gl=0 if $gl<0;$bl=0 if $bl<0;
     my $r=$encode_linear->($rl);
     my $g=$encode_linear->($gl);
     my $b=$encode_linear->($bl);
     push @steps, "{\"ire\":100,\"r\":$r,\"g\":$g,\"b\":$b,\"name\":\"$name\",\"series_color\":\"$series_color\",\"sat_pct\":100}";
    }
 } elsif($type eq "saturations") {
  my $signal_mode=&webui_pattern_signal_mode("");
  my $min_code=($signal_range==1)?16:0;
  my $span_code=($signal_range==1)?219:255;
  my $encode_channel=sub {
   my ($linear)=@_;
   $linear=0 if(!defined $linear || $linear < 0);
   $linear=1 if($linear > 1);
   my $encoded=$linear;
   if($signal_mode eq "dv") {
    $encoded=$linear**(1/2.2);
   } elsif($signal_mode eq "hdr10") {
      $encoded=&webui_pattern_pq_encode_normalized($linear*100);
   } else {
      $encoded=$linear**(1/2.2);
   }
   return int($min_code + $encoded*$span_code + .5);
  };
  my $level_pct=($signal_mode eq "hdr10" || $signal_mode eq "dv") ? 50 : 75;
  my $level_code=int($min_code + ($level_pct/100)*$span_code + .5);
  my $level_signal=$span_code>0 ? (($level_code-$min_code)/$span_code) : 0;
  my $level_linear=($signal_mode eq "hdr10") ? (&webui_pattern_pq_decode_normalized($level_signal)/10000) : ($level_signal**2.2);
  my %primaries=(
   bt709=>{R=>[0.64,0.33],G=>[0.30,0.60],B=>[0.15,0.06],M=>[[3.2406,-1.5372,-0.4986],[-0.9689,1.8758,0.0415],[0.0557,-0.2040,1.0570]],RGB_TO_XYZ=>[[0.4124564,0.3575761,0.1804375],[0.2126729,0.7151522,0.0721750],[0.0193339,0.1191920,0.9503041]]},
   bt2020=>{R=>[0.708,0.292],G=>[0.170,0.797],B=>[0.131,0.046],M=>[[1.7166511880,-0.3556707838,-0.2533662814],[-0.6666843518,1.6164812366,0.0157685458],[0.0176398574,-0.0427706133,0.9421031212]],RGB_TO_XYZ=>[[0.6369580483,0.1446169036,0.1688809752],[0.2627002120,0.6779980715,0.0593017165],[0.0000000000,0.0280726930,1.0609850577]]},
   p3d65=>{R=>[0.680,0.320],G=>[0.265,0.690],B=>[0.150,0.060],M=>[[2.4934969119,-0.9313836179,-0.4027107845],[-0.8294889696,1.7626640603,0.0236246858],[0.0358458302,-0.0761723893,0.9568845240]],RGB_TO_XYZ=>[[0.4865709486,0.2656676932,0.1982172852],[0.2289745641,0.6917385218,0.0792869141],[0.0000000000,0.0451133819,1.0439443689]]}
  );
  my $gamut_key="bt709";
  if($signal_mode eq "dv") {
   $gamut_key="p3d65";
  } elsif($signal_mode eq "hdr10" || $signal_mode eq "hlg") {
   $gamut_key="bt2020";
  } elsif(int($pgenerator_conf{"primaries"} || 0) == 1) {
   $gamut_key="bt2020";
  } elsif(int($pgenerator_conf{"primaries"} || 0) == 2) {
   $gamut_key="p3d65";
  }
  my $container_key=$gamut_key;
  my $target_key=$target_gamut ne "" ? $target_gamut : $container_key;
  my $g_target=$primaries{$target_key};
  my $g_container=$primaries{$container_key};
  my @MI=@{$g_container->{M}};
  my @RGB_TO_XYZ=@{$g_target->{RGB_TO_XYZ}};
  foreach my $color (["Red",1,0,0],["Green",0,1,0],["Blue",0,0,1],["Cyan",0,1,1],["Magenta",1,0,1],["Yellow",1,1,0]) {
   my ($name,$r_mix,$g_mix,$b_mix)=@$color;
   my $mix_X=$RGB_TO_XYZ[0][0]*$r_mix+$RGB_TO_XYZ[0][1]*$g_mix+$RGB_TO_XYZ[0][2]*$b_mix;
   my $mix_Y=$RGB_TO_XYZ[1][0]*$r_mix+$RGB_TO_XYZ[1][1]*$g_mix+$RGB_TO_XYZ[1][2]*$b_mix;
   my $mix_Z=$RGB_TO_XYZ[2][0]*$r_mix+$RGB_TO_XYZ[2][1]*$g_mix+$RGB_TO_XYZ[2][2]*$b_mix;
   my $mix_sum=$mix_X+$mix_Y+$mix_Z;
   my $px=$mix_sum>0?$mix_X/$mix_sum:0.3127;
   my $py=$mix_sum>0?$mix_Y/$mix_sum:0.329;
   foreach my $sat (25,50,75,100) {
    my $f=$sat/100;
    my $tx=0.3127+$f*($px-0.3127); my $ty=0.329+$f*($py-0.329);
    my $X=$tx/$ty; my $Y=1; my $Z=(1-$tx-$ty)/$ty;
    my $rl=$MI[0][0]*$X+$MI[0][1]*$Y+$MI[0][2]*$Z;
    my $gl=$MI[1][0]*$X+$MI[1][1]*$Y+$MI[1][2]*$Z;
    my $bl=$MI[2][0]*$X+$MI[2][1]*$Y+$MI[2][2]*$Z;
    my $mx=$rl;$mx=$gl if $gl>$mx;$mx=$bl if $bl>$mx;
    if($mx>0){$rl/=$mx;$gl/=$mx;$bl/=$mx;}
    $rl=0 if $rl<0;$gl=0 if $gl<0;$bl=0 if $bl<0;
    $rl*=$level_linear;$gl*=$level_linear;$bl*=$level_linear;
    my $r=$signal_mode eq "hdr10" ? int($min_code + &webui_pattern_pq_encode_normalized($rl*10000)*$span_code + .5) : $encode_channel->($rl);
    my $g=$signal_mode eq "hdr10" ? int($min_code + &webui_pattern_pq_encode_normalized($gl*10000)*$span_code + .5) : $encode_channel->($gl);
    my $b=$signal_mode eq "hdr10" ? int($min_code + &webui_pattern_pq_encode_normalized($bl*10000)*$span_code + .5) : $encode_channel->($bl);
    push @steps, "{\"ire\":$sat,\"r\":$r,\"g\":$g,\"b\":$b,\"name\":\"$name $sat%\"}";
   }
  }
 }

 my $series_id="${type}_".time();
 my $total=scalar(@steps);

 # Write steps to temp file for helper script
 my $steps_file="/tmp/meter_series_steps.json";
 if(open(my $fh,">",$steps_file)) {
  print $fh "[".join(",",@steps)."]";
  close($fh);
 }

 # Write initial state
 my $init_json="{\"status\":\"running\",\"series_id\":\"$series_id\",\"current_step\":0,\"total_steps\":$total,\"current_name\":\"\",\"readings\":[]}";
 if(open(my $fh,">",$_meter_series_file)) { print $fh $init_json; close($fh); }

 # Launch series helper script in background (setsid to detach from daemon threads)
 # sudo required: daemon runs as pgenerator user, spotread needs root for USB access
 system("setsid sudo /bin/bash /usr/bin/meter_series.sh '$series_id' '$display_type' '$delay_ms' '$patch_size' '$steps_file' '$_meter_series_file' '$ccss_file' '$patch_insert' '$refresh_rate' '$disable_aio' </dev/null >/dev/null 2>&1 &");

 return "{\"status\":\"started\",\"series_id\":\"$series_id\",\"total_steps\":$total,\"steps\":[".join(",",@steps)."]}";
}

sub webui_meter_series_status (@) {
 if(-f $_meter_series_file) {
  my $json="";
  if(open(my $fh,"<",$_meter_series_file)) { local $/; $json=<$fh>; close($fh); }
  if($json ne "") {
   # If status is "running", verify the process is still alive
   if($json=~/"status"\s*:\s*"running"/) {
    my $alive=`pgrep -f meter_series.sh 2>/dev/null`;
    if($alive!~/\d/) {
     # Process died — mark as error so client knows
     $json=~s/"status"\s*:\s*"running"/"status":"error"/;
     $json=~s/"current_name"\s*:\s*"[^"]*"/"current_name":"Process died unexpectedly"/;
     if(open(my $wf,">",$_meter_series_file)) { print $wf $json; close($wf); }
    }
   }
   # Include steps from steps file so any client can reconstruct the UI
   if(-f "/tmp/meter_series_steps.json" && $json=~/"status"\s*:\s*"(running|complete|error|cancelled)"/) {
    my $steps="";
    if(open(my $sf,"<","/tmp/meter_series_steps.json")) { local $/; $steps=<$sf>; close($sf); }
    if($steps ne "" && $json!~/"steps"/) {
     $json=~s/\}$/,"steps":$steps}/;
    }
   }
   return $json;
  }
 }
 return '{"status":"idle"}';
}

sub webui_meter_stop (@) {
 # Stop the persistent session daemon first (graceful, then force).
 &webui_meter_session_stop() if(&webui_meter_session_alive());
 # Kill any running spotread/meter processes (sudo required: they run as root)
 system("sudo pkill -9 -f 'meter_session.sh' 2>/dev/null");
 system("sudo pkill -9 -f 'meter_series.sh' 2>/dev/null");
 system("sudo pkill -9 -f 'spotread_wrapper' 2>/dev/null");
 system("sudo pkill -9 -x spotread 2>/dev/null");
 system("sudo pkill -9 -f 'script.*spotread' 2>/dev/null");
 system("sudo pkill -9 -f 'cat.*spotread_cmd' 2>/dev/null");
 unlink($_meter_session_pid_file, $_meter_session_config_file, $_meter_session_fifo);
 # Mark state as cancelled (if still running)
 if(-f $_meter_series_file) {
  my $json="";
  if(open(my $fh,"<",$_meter_series_file)) { local $/; $json=<$fh>; close($fh); }
  if($json=~/"status"\s*:\s*"running"/) {
   $json=~s/"status"\s*:\s*"running"/"status":"cancelled"/;
   if(open(my $fh,">",$_meter_series_file)) { print $fh $json; close($fh); }
  }
 }
 # Clean up stale temp files so new series starts fresh
 unlink("/tmp/spotread_port_cache");
 # Remove any leftover spotread pipes/output files
 my @stale=glob("/tmp/spotread_series_* /tmp/spotread_cmd_*");
 unlink(@stale) if @stale;
 return '{"status":"ok","message":"Measurement stopped"}';
}

sub webui_meter_clear (@) {
 &webui_meter_stop();
 unlink($_meter_read_file);
 unlink("${_meter_read_file}.tmp");
 unlink("/tmp/meter_series_steps.json");
 unlink("/tmp/meter_read_steps.json");
 my $stamp=time();
 my $json="{\"status\":\"cleared\",\"timestamp\":$stamp,\"readings\":[]}";
 if(open(my $fh,">",$_meter_series_file)) { print $fh $json; close($fh); }
 return '{"status":"ok","message":"Chart data cleared"}';
}

sub webui_meter_reset (@) {
 # Kill any spotread processes first
 system("sudo bash $_meter_wrapper --kill 2>/dev/null");
 select(undef,undef,undef,0.3);
 # Reset USB hub via helper script (needs root for sysfs writes)
 system("sudo /bin/bash /usr/bin/meter_usb_reset.sh 2>/dev/null");
 select(undef,undef,undef,2);
 # Clear stale port cache
 unlink("/tmp/spotread_port_cache");
 &log("WebUI: USB hub reset performed");
 return '{"status":"ok","message":"USB reset performed"}';
}

my $_meter_settings_file="/tmp/meter_settings.json";

sub webui_meter_settings_save (@) {
 my ($body)=@_;
 # Validate: only allow known keys
 my %allowed=map {$_=>1} qw(display_type target_gamut delay patch_size patch_insert disable_aio refresh_rate ccss_file);
 my $safe="{";
 my @parts;
 while($body=~/"(\w+)"\s*:\s*("(?:[^"\\]|\\.)*"|\d+|true|false|null)/g) {
  push @parts, "\"$1\":$2" if($allowed{$1});
 }
 $safe="{".join(",",@parts)."}";
 if(open(my $fh,">",$_meter_settings_file)) { print $fh $safe; close($fh); }
 return '{"status":"ok"}';
}

sub webui_meter_settings_load (@) {
 if(-f $_meter_settings_file) {
  my $json="";
  if(open(my $fh,"<",$_meter_settings_file)) { local $/; $json=<$fh>; close($fh); }
  return $json if($json ne "" && $json=~/^\{/);
 }
 return '{}';
}

###############################################
#         Custom CCSS API Functions           #
###############################################
my $_custom_ccss_dir="$_ccss_dir/custom";

sub _webui_json_escape (@) {
 my $s="".shift;
 $s=~s/\\/\\\\/g;
 $s=~s/"/\\"/g;
 $s=~s/\r/\\r/g;
 $s=~s/\n/\\n/g;
 $s=~s/\t/\\t/g;
 return $s;
}

sub _webui_ccss_meta (@) {
 my ($path)=@_;
 my %meta=(display=>"",technology=>"");
 return \%meta if(!$path || !-f $path);
 if(open(my $fh,"<",$path)) {
  my $count=0;
  while(my $line=<$fh>) {
   $count++;
   last if($count>80);
   last if($line=~/^(?:BEGIN_DATA_FORMAT|BEGIN_DATA)\b/);
   chomp($line);
   $meta{display}=$1 if(!$meta{display} && $line=~/^DISPLAY\s+"([^"]*)"/i);
   $meta{technology}=$1 if(!$meta{technology} && $line=~/^TECHNOLOGY\s+"([^"]*)"/i);
  }
  close($fh);
 }
 return \%meta;
}

sub webui_ccss_list (@) {
 my @files;
 if(-d $_custom_ccss_dir && opendir(my $dh, $_custom_ccss_dir)) {
  while(my $f=readdir($dh)) {
   next unless($f=~/\.ccss$/);
   push @files, "\"$f\"";
  }
  closedir($dh);
 }
 return '{"files":['.join(",",sort @files).']}';
}

sub webui_ccss_all (@) {
 # Returns combined list of system + custom ccss files (alphabetical).
 # Each entry: {"name":"...", "source":"system"|"custom", "display":"...", "technology":"..."}
 my @out;
 my %seen;
 # System dir (excluding the 'custom' subdir)
 if(-d $_ccss_dir && opendir(my $dh, $_ccss_dir)) {
  while(my $f=readdir($dh)) {
   next unless($f=~/\.ccss$/i);
   next if($seen{lc $f}++);
   my $meta=&_webui_ccss_meta("$_ccss_dir/$f");
   my $e=&_webui_json_escape($f);
   my $d=&_webui_json_escape($meta->{display});
   my $t=&_webui_json_escape($meta->{technology});
   push @out, [lc $f, "{\"name\":\"$e\",\"source\":\"system\",\"display\":\"$d\",\"technology\":\"$t\"}"];
  }
  closedir($dh);
 }
 if(-d $_custom_ccss_dir && opendir(my $dh, $_custom_ccss_dir)) {
  while(my $f=readdir($dh)) {
   next unless($f=~/\.ccss$/i);
   next if($seen{lc $f}++);
   my $meta=&_webui_ccss_meta("$_custom_ccss_dir/$f");
   my $e=&_webui_json_escape($f);
   my $d=&_webui_json_escape($meta->{display});
   my $t=&_webui_json_escape($meta->{technology});
   push @out, [lc $f, "{\"name\":\"$e\",\"source\":\"custom\",\"display\":\"$d\",\"technology\":\"$t\"}"];
  }
  closedir($dh);
 }
 my @sorted=map { $_->[1] } sort { $a->[0] cmp $b->[0] } @out;
 return '{"files":['.join(",",@sorted).']}';
}

sub webui_ccss_upload (@) {
 my ($body)=@_;
 # Expect JSON: { name: "...", content: "base64...", filename: "..." }
 my $name="";
 $name=$1 if($body=~/"name"\s*:\s*"([^"]{1,80})"/);
 my $content_b64="";
 $content_b64=$1 if($body=~/"content"\s*:\s*"([^"]+)"/);
 my $orig_filename="";
 $orig_filename=$1 if($body=~/"filename"\s*:\s*"([^"]{1,200})"/);

 if($name eq "" || $content_b64 eq "") {
  return '{"status":"error","message":"Name and file content required"}';
 }

 # Sanitize name for filesystem use
 my $safe_name=$name;
 $safe_name=~s/[^a-zA-Z0-9._\- ]//g;
 $safe_name=~s/\s+/_/g;
 $safe_name=substr($safe_name,0,60) if(length($safe_name)>60);
 $safe_name.=".ccss" unless($safe_name=~/\.ccss$/i);

 my $raw=decode_base64($content_b64);
 if(length($raw) < 10 || length($raw) > 5*1024*1024) {
  return '{"status":"error","message":"Invalid file size"}';
 }

 # Create custom dir if needed
 if(!-d $_custom_ccss_dir) {
  system("mkdir -p $_custom_ccss_dir");
 }

 # Detect file type: CSV or CCSS
 if($raw=~/^CCSS\s/) {
  # Already a CCSS file — validate basic structure
  if($raw!~/BEGIN_DATA/ || $raw!~/END_DATA/) {
   return '{"status":"error","message":"Invalid CCSS file: missing data section"}';
  }
  my $out_path="$_custom_ccss_dir/$safe_name";
  if(open(my $fh,">:raw",$out_path)) {
   print $fh $raw;
   close($fh);
   &log("WebUI: custom CCSS uploaded: $safe_name");
   return "{\"status\":\"ok\",\"filename\":\"$safe_name\",\"message\":\"CCSS profile saved\"}";
  }
  return '{"status":"error","message":"Failed to write file"}';
 }

 # Assume CSV — try to convert
 my $ccss_content=&csv_to_ccss($raw,$name,$orig_filename);
 if(!$ccss_content) {
  return '{"status":"error","message":"Failed to parse CSV. Expected: wavelength,R,G,B,W columns (380-780nm)"}';
 }

 my $out_path="$_custom_ccss_dir/$safe_name";
 if(open(my $fh,">",$out_path)) {
  print $fh $ccss_content;
  close($fh);
  &log("WebUI: custom CCSS converted from CSV: $safe_name");
  return "{\"status\":\"ok\",\"filename\":\"$safe_name\",\"message\":\"CSV converted to CCSS\"}";
 }
 return '{"status":"error","message":"Failed to write file"}';
}

sub webui_ccss_delete (@) {
 my ($fname)=@_;
 $fname=~s/[^a-zA-Z0-9._-]//g;
 if($fname eq "" || $fname=~/\.\./) {
  return '{"status":"error","message":"Invalid filename"}';
 }
 my $path="$_custom_ccss_dir/$fname";
 if(-f $path) {
  unlink($path);
  &log("WebUI: custom CCSS deleted: $fname");
  return '{"status":"ok","message":"Deleted"}';
 }
 return '{"status":"error","message":"File not found"}';
}

sub _webui_ccss_clean_name (@) {
 my ($text)=@_;
 $text="" if(!defined $text);
 $text=~s/\.ccss$//i;
 $text=~s/\.csv$//i;
 $text=~s/_-_.*$//;
 $text=~s/_/ /g;
 $text=~s/\s+/ /g;
 $text=~s/^\s+|\s+$//g;
 return $text;
}

sub _webui_ccss_guess_meta (@) {
 my ($profile_name,$orig_filename)=@_;
 my $source=$profile_name ne "" ? $profile_name : $orig_filename;
 my $base=&_webui_ccss_clean_name($source);
 my $display=$base;
 my $technology="";
 if($base =~ /^(.*)\s+\(([^)]+)\)$/) {
  $display=&_webui_ccss_clean_name($1);
  $technology=&_webui_ccss_clean_name($2);
 } elsif($base =~ /^(QD-OLED|WRGB OLED|RGB OLED|LCD|CRT|Plasma|Projector|White LED|RGB LED|CCFL|Wide Gamut CCFL|PFS Phosphor|RG Phosphor)\s+(.+)$/i) {
  $display=&_webui_ccss_clean_name($2);
  $technology=&_webui_ccss_clean_name($1);
 }
 $display=$profile_name if($display eq "" && $profile_name ne "");
 return ($display,$technology);
}

sub csv_to_ccss (@) {
 my ($csv_text,$profile_name,$orig_filename)=@_;
 my @lines=split(/\r?\n/,$csv_text);
 # Parse header to find columns
 my $header=shift @lines;
 return undef if(!$header);
 my @cols=split(/[,\t]/,$header);
 # Find wavelength and R/G/B/W columns (case-insensitive)
 my ($wl_col,$r_col,$g_col,$b_col,$w_col)=(-1,-1,-1,-1,-1);
 for(my $i=0;$i<scalar(@cols);$i++) {
  my $c=lc($cols[$i]);
  $c=~s/^\s+|\s+$//g;
  $c=~s/^"(.*)"$/$1/;
  if($c=~/^(wavelength|nm|lambda|wl)$/) { $wl_col=$i; }
  elsif($c=~/^(red|r)$/) { $r_col=$i; }
  elsif($c=~/^(green|g)$/) { $g_col=$i; }
  elsif($c=~/^(blue|b)$/) { $b_col=$i; }
  elsif($c=~/^(white|w)$/) { $w_col=$i; }
 }
 # If no header match, try numeric detection
 if($wl_col<0) {
  # Check if first column looks like wavelengths (380-780)
  my @first_vals;
  for my $line (@lines) {
   my @v=split(/[,\t]/,$line);
   if($v[0]=~/^\s*(\d+\.?\d*)/) { push @first_vals,$1; last if(scalar(@first_vals)>=3); }
  }
  if(@first_vals && $first_vals[0]>=300 && $first_vals[0]<=400) {
   $wl_col=0;
   if(scalar(@cols)>=5) { $r_col=1;$g_col=2;$b_col=3;$w_col=4; }
   elsif(scalar(@cols)>=4) { $r_col=1;$g_col=2;$b_col=3; }
   else { return undef; }
  }
 }
 return undef if($wl_col<0 || $r_col<0 || $g_col<0 || $b_col<0);

 # Parse data rows
 my @data;
 for my $line (@lines) {
  next if($line=~/^\s*$/ || $line=~/^\s*#/);
  my @v=split(/[,\t]/,$line);
  my $wl=$v[$wl_col]; $wl=~s/[^\d.]//g;
  next if($wl eq "" || $wl<300 || $wl>900);
  my %row=(wl=>$wl+0);
  for my $ch (["r",$r_col],["g",$g_col],["b",$b_col]) {
   my $val=$v[$ch->[1]]||0; $val=~s/[^\d.eE\-+]//g; $val=($val+0);
   $row{$ch->[0]}=$val;
  }
  if($w_col>=0 && defined $v[$w_col]) {
   my $val=$v[$w_col]||0; $val=~s/[^\d.eE\-+]//g;
   $row{w}=$val+0;
  }
  push @data,\%row;
 }
 return undef if(scalar(@data)<10);

 # Interpolate/resample to 1nm from 380-780
 my @resampled;
 for(my $nm=380;$nm<=780;$nm++) {
  my %pt=(wl=>$nm);
  for my $ch ("r","g","b","w") {
   next if($ch eq "w" && $w_col<0);
   $pt{$ch}=&_interp_spectral(\@data,$ch,$nm);
  }
  push @resampled,\%pt;
 }

 # Determine number of sets (3 if no white, 4 if white)
 my $has_white=($w_col>=0)?1:0;
 my $num_sets=$has_white?4:3;

 # Find spectral norm (max value across all channels and wavelengths)
 my $norm=0;
 for my $pt (@resampled) {
  for my $ch ("r","g","b",($has_white?"w":())) {
   $norm=$pt->{$ch} if($pt->{$ch}>$norm);
  }
 }
 $norm=1 if($norm<=0);

 # Build CCSS
 my $bands=scalar(@resampled);
 my $now_str=localtime();
 my ($display_name,$technology_name)=&_webui_ccss_guess_meta($profile_name,$orig_filename);
 my $ccss="CCSS   \n\n";
 $ccss.="DESCRIPTOR \"$profile_name\"\n";
 $ccss.="ORIGINATOR \"PGenerator+ csv2ccss converter\"\n";
 $ccss.="CREATED \"$now_str\"\n";
 $ccss.="DISPLAY \"$display_name\"\n";
 $ccss.="TECHNOLOGY \"$technology_name\"\n" if($technology_name ne "");
 $ccss.="KEYWORD \"DISPLAY_TYPE_REFRESH\"\n";
 $ccss.="DISPLAY_TYPE_REFRESH \"NO\"\n";
 $ccss.="REFERENCE \"User provided\"\n";
 $ccss.="SPECTRAL_BANDS \"$bands\"\n";
 $ccss.="SPECTRAL_START_NM \"380.000000\"\n";
 $ccss.="SPECTRAL_END_NM \"780.000000\"\n";
 $ccss.=sprintf("SPECTRAL_NORM \"%f\"\n",$norm);
 $ccss.="\n";
 $ccss.="NUMBER_OF_FIELDS ".($bands+1)."\n";
 $ccss.="BEGIN_DATA_FORMAT\n";
 $ccss.="SAMPLE_ID";
 for(my $nm=380;$nm<=780;$nm++) { $ccss.=" SPEC_$nm"; }
 $ccss.="\nEND_DATA_FORMAT\n\n";
 $ccss.="NUMBER_OF_SETS $num_sets\n";
 $ccss.="BEGIN_DATA\n";
 # Write R, G, B (and optionally W) as separate rows
 my @channels=("r","g","b");
 push @channels,"w" if($has_white);
 my $set_id=1;
 for my $ch (@channels) {
  $ccss.=$set_id;
  for my $pt (@resampled) { $ccss.=sprintf(" %f",$pt->{$ch}); }
  $ccss.="\n";
  $set_id++;
 }
 $ccss.="END_DATA\n";
 return $ccss;
}

sub _interp_spectral (@) {
 my ($data,$ch,$target_nm)=@_;
 # Find bracketing points
 my $n=scalar(@$data);
 return 0 if($n==0);
 # Clamp to range
 if($target_nm<=$data->[0]{wl}) { return $data->[0]{$ch}||0; }
 if($target_nm>=$data->[$n-1]{wl}) { return $data->[$n-1]{$ch}||0; }
 for(my $i=0;$i<$n-1;$i++) {
  if($data->[$i]{wl}<=$target_nm && $data->[$i+1]{wl}>=$target_nm) {
   my $t=($target_nm-$data->[$i]{wl})/($data->[$i+1]{wl}-$data->[$i]{wl});
   my $v0=$data->[$i]{$ch}||0;
   my $v1=$data->[$i+1]{$ch}||0;
   return $v0+$t*($v1-$v0);
  }
 }
 return 0;
}

###############################################
#           API Helper Functions              #
###############################################
sub webui_config_json (@) {
 # Re-read config from file
 my %conf;
 if(open(my $fh, "<", $pattern_conf)) {
  while(<$fh>) {
   chomp;
   next if(/^\s*#/ || /^\s*$/);
   if(/^(\S+?)=(.*)/) { $conf{$1}=$2; }
  }
  close($fh);
 }
 my $json="{";
 my $first=1;
 foreach my $k (sort keys %conf) {
  $json.="," if(!$first);
  my $v=$conf{$k};
  $v=~s/"/\\"/g;
  $json.="\"$k\":\"$v\"";
  $first=0;
 }
 $json.="}";
 return $json;
}

sub webui_apply_config (@) {
 my $body=shift;
 my $need_restart=0;
 # Parse simple JSON: {"key":"val","key2":"val2"}
 my %changes;
 while($body=~/"(\w+)"\s*:\s*"([^"]*)"/g) {
  $changes{$1}=$2;
 }
 my %effective=%pgenerator_conf;
 foreach my $k (keys %changes) {
  $effective{$k}=$changes{$k};
 }
 my $dv_on=int($effective{"dv_status"} || 0);
 $dv_on=1 if(int($effective{"is_ll_dovi"} || 0) || int($effective{"is_std_dovi"} || 0));
 if($dv_on) {
  $changes{"max_bpc"}="12";
  $changes{"color_format"}="0";
  $changes{"colorimetry"}="9";
  $changes{"primaries"}="1";
  $changes{"rgb_quant_range"}="2";
  # DV 12-bit RGB tunneling needs 1.5× the pixel clock — reject modes that
  # exceed HDMI 2.0 TMDS bandwidth (600 MHz) to avoid green-screen artifacts.
  if(defined $changes{"mode_idx"} && $changes{"mode_idx"} ne "") {
   my $mode_clk=0;
   my $mt=`timeout 5 $modetest -c 2>/dev/null`;
   if($mt=~/^\s*#$changes{"mode_idx"}\s+\S+\s+[\d.]+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+(\d+)\s+/m) {
    $mode_clk=$1;
   }
   if($mode_clk > 0 && $mode_clk * 1.5 > 600000) {
    my $result='{"status":"error","message":"This resolution exceeds HDMI bandwidth for Dolby Vision (12-bit RGB tunneling). Use 4K@30Hz or lower."}';
    return wantarray ? ($result,0) : $result;
   }
  }
 }
 # Keys that require pattern generator restart
 my %restart_keys=map{$_=>1} qw(mode_idx eotf is_hdr is_sdr colorimetry primaries
  min_luma max_luma max_cll max_fall color_format max_bpc rgb_quant_range
  dv_status is_ll_dovi is_std_dovi dv_interface dv_metadata dv_color_space dv_map_mode);

 foreach my $k (sort keys %changes) {
  next if($k eq "ip_pattern" || $k eq "port_pattern"); # read-only
  &sudo("SET_PGENERATOR_CONF",$k,$changes{$k});
  $pgenerator_conf{$k}=$changes{$k};
  $need_restart=1 if($restart_keys{$k});
 }
 &sync_pattern_bits_default() if(%changes);
 my $result='{"status":"ok","restart":'.($need_restart ? 'true' : 'false').'}';
 return wantarray ? ($result,$need_restart) : $result;
}

sub webui_hdmi_connected (@) {
 foreach my $port ($hdmi_2,$hdmi_1) {
  foreach my $card (0..3) {
   my $p="/sys/class/drm/card${card}-${port}";
   if(-d $p) {
    my $st=`cat $p/status 2>/dev/null`; chomp $st;
    return 1 if($st eq "connected");
   }
  }
 }
 return 0;
}

sub webui_hdmi_port_status (@) {
 my %ports;
 foreach my $port ($hdmi_1,$hdmi_2) {
  foreach my $card (0..3) {
   my $p="/sys/class/drm/card${card}-${port}";
   if(-d $p) {
    my $st=`cat $p/status 2>/dev/null`; chomp $st;
    $ports{$port}=$st if($st ne "");
    last;
   }
  }
 }
 # Preferred port: HDMI-A-1 (closest to USB-C on Pi 4, furthest on Pi 400)
 my $preferred=$hdmi_1;
 my $pref_ok=($ports{$preferred} eq "connected") ? 1 : 0;
 my $wrong_port=0;
 if(!$pref_ok) {
  foreach my $port (keys %ports) {
   $wrong_port=1 if($port ne $preferred && $ports{$port} eq "connected");
  }
 }
 my $p1_st=$ports{$hdmi_1} || "absent";
 my $p2_st=$ports{$hdmi_2} || "absent";
 return "{\"preferred\":\"$preferred\",\"correct\":".($pref_ok?"true":"false").",\"wrong_port\":".($wrong_port?"true":"false").",\"ports\":{\"HDMI-A-1\":\"$p1_st\",\"HDMI-A-2\":\"$p2_st\"}}";
}

sub webui_info_json (@) {
 my $hostname=&read_from_file($hostname_file);
 $hostname=~s/\s+//g;
 my $temp=&get_temperature();
 $temp=~s/[^\d.]//g;
 my $uptime=&read_from_file($uptime_file);
 ($uptime)=$uptime=~/^([\d.]+)/;

 # Read network info from device_info cached .info files (non-blocking)
 my @ips;
 my @ip_files=glob("$info_dir/GET_IP-*.info");
 foreach my $f (@ip_files) {
  my ($iface)=$f=~/GET_IP-(.+)\.info$/;
  next if(!$iface || $iface eq "lo");
  my $addr=&read_from_file($f);
  chomp($addr);
  next if(!$addr || $addr eq "N/A" || $addr eq "None" || $addr eq "");
  $addr=~s/"/\\"/g;
  push @ips, "\"$iface\":\"$addr\"";
 }
 my $ip_json="{".join(",",@ips)."}";
 my $ver=$version;

 # Current resolution
 my $resolution="No display";
 if($hdmi_info=~/(\d+)x(\d+)\s*\@\s*([\d.]+)/) {
  my $hz=int($3+0.5);
  $resolution="${1}x${2}\@${hz}Hz";
 } elsif(defined $w_s && defined $h_s && $w_s > 0) {
  $resolution="${w_s}x${h_s}";
 }

 # Read WiFi info from device_info cached .info file (non-blocking)
 my $wifi_ssid="";
 my $wifi_freq="";
 my $wifi_signal="";
 my $wifi_state="";
 my $wifi_cached=&read_from_file("$info_dir/GET_WIFI_STATUS.info");
 if($wifi_cached) {
  $wifi_cached=decode_base64($wifi_cached);
  foreach my $wline (split(/\n/,$wifi_cached)) {
   if($wline=~/^ssid\s*=\s*(.*)/) { $wifi_ssid=$1; }
   if($wline=~/^freq\s*=\s*(\d+)/) { $wifi_freq=$1; }
   if($wline=~/^wpa_state\s*=\s*(.*)/) { $wifi_state=$1; }
  }
 }
 $wifi_ssid=~s/"/\\"/g;
 my $wifi_band="";
 if($wifi_freq=~/^\d+$/) {
  $wifi_band=($wifi_freq>=5000)?"5 GHz":"2.4 GHz";
 }

 my $cal_ip=$calibration_client_ip; $cal_ip=~s/"/\\"/g;
 my $cal_sw=$calibration_client_software; $cal_sw=~s/"/\\"/g;
 my $cal_conn=($cal_ip ne "")?"true":"false";
 my $meminfo=&read_from_file("/proc/meminfo");
 my $total_ram="";
 if($meminfo=~/MemTotal:\s*(\d+)/) { $total_ram=int($1/1024); }
 my $gpu_mem=&read_from_file("$info_dir/GET_GPU_MEMORY.info");
 chomp($gpu_mem);
 $gpu_mem=~s/\s//g;
 my $hdmi_port_json=&webui_hdmi_port_status();
 return "{\"hostname\":\"$hostname\",\"version\":\"$ver\",\"temperature\":\"$temp\",\"uptime\":\"$uptime\",\"resolution\":\"$resolution\",\"interfaces\":$ip_json,\"wifi\":{\"ssid\":\"$wifi_ssid\",\"freq\":\"$wifi_freq\",\"band\":\"$wifi_band\",\"signal\":\"$wifi_signal\",\"state\":\"$wifi_state\"},\"calibration\":{\"connected\":$cal_conn,\"ip\":\"$cal_ip\",\"software\":\"$cal_sw\"},\"total_ram\":\"$total_ram\",\"gpu_mem\":\"$gpu_mem\",\"hdmi_port\":$hdmi_port_json}";
}

sub webui_create_logs_bundle (@) {
 my $ts=time();
 my $tmp="/tmp/pg_diag_${ts}.txt";
 my $hostname=`hostname 2>/dev/null`; chomp($hostname);
 my @out;
 push @out, "=" x 72;
 push @out, "  PGenerator+ Diagnostic Report";
 push @out, "  Host: $hostname   Version: $version   Date: ".`date -u '+%Y-%m-%d %H:%M:%S UTC'`;
 chomp($out[$#out]);
 push @out, "=" x 72;

 # System info
 push @out, "", "--- System Info ---";
 push @out, `uptime 2>/dev/null`; chomp($out[$#out]);
 push @out, `cat /proc/version 2>/dev/null`; chomp($out[$#out]);
 my $model=`cat /proc/device-tree/model 2>/dev/null`; chomp($model);
 push @out, "Model: $model" if($model);
 my $mem=`grep -E 'MemTotal|MemAvailable' /proc/meminfo 2>/dev/null`; chomp($mem);
 push @out, $mem;
 my $gpu_mem=&pgenerator_cmd("GET_GPU_MEMORY"); chomp($gpu_mem);
 push @out, "GPU Memory: $gpu_mem";

 # PGenerator config
 push @out, "", "--- PGenerator.conf ---";
 push @out, `cat /etc/PGenerator/PGenerator.conf 2>/dev/null`;
 chomp($out[$#out]);

 # Network
 push @out, "", "--- Network Interfaces ---";
 push @out, `ip -br addr show 2>/dev/null`; chomp($out[$#out]);
 push @out, "", "--- Routes ---";
 push @out, `ip route show 2>/dev/null`; chomp($out[$#out]);
 push @out, "", "--- DNS (resolv.conf) ---";
 push @out, `cat /etc/resolv.conf 2>/dev/null`; chomp($out[$#out]);
 push @out, "", "--- WiFi Status ---";
 push @out, `timeout 3 wpa_cli -i wlan0 status 2>/dev/null`; chomp($out[$#out]);

 # HDMI / Display
 push @out, "", "--- HDMI Mode ---";
 push @out, `timeout 5 $modetest -c 2>/dev/null | head -80`; chomp($out[$#out]);
 push @out, "", "--- EDID ---";
 my $edid_hex=`timeout 5 cat /sys/class/drm/card?-HDMI-A-1/edid 2>/dev/null | xxd -p 2>/dev/null`;
 chomp($edid_hex);
 if($edid_hex) {
  push @out, $edid_hex;
  push @out, "", "--- EDID Decoded ---";
  push @out, `timeout 5 edid-decode /sys/class/drm/card?-HDMI-A-1/edid 2>&1`;
  chomp($out[$#out]);
 } else {
  push @out, "(no EDID — display not connected)";
 }

 # Infoframes
 push @out, "", "--- HDMI Infoframes (dmesg) ---";
 my $dmesg=`timeout 3 /bin/dmesg 2>/dev/null`;
 my ($avi_hex,$drm_hex)=("","");
 foreach my $line (split(/\n/,$dmesg)) {
  if($line=~/AVI IF:\s*(.+)/) { $avi_hex=$1; }
  if($line=~/DRM IF:\s*(.+)/) { $drm_hex=$1; }
 }
 push @out, "AVI: $avi_hex" if($avi_hex);
 push @out, "DRM: $drm_hex" if($drm_hex);
 push @out, "(none found)" if(!$avi_hex && !$drm_hex);

 # Operations file
 push @out, "", "--- operations.txt ---";
 push @out, `cat /var/lib/PGenerator/operations.txt 2>/dev/null`; chomp($out[$#out]);

 # Processes
 push @out, "", "--- Processes (PGenerator) ---";
 push @out, `ps aux | grep -E 'PGenerator|dhcpcd|dhclient|wpa_|hostapd' | grep -v grep 2>/dev/null`;
 chomp($out[$#out]);

 # File descriptors
 my $pid=`ps aux | awk '/[P]Generatord/ {print \$2; exit}'`; chomp($pid);
 if($pid) {
  push @out, "", "--- PGeneratord FDs (pid $pid) ---";
  push @out, `ls -l /proc/$pid/fd 2>/dev/null`; chomp($out[$#out]);
 }

 # Info cache files
 push @out, "", "--- Info Cache ---";
 my @infos=glob("/var/lib/PGenerator/running/*.info");
 foreach my $f (@infos) {
  my $name=$f; $name=~s|.*/||;
  my $content=`cat $f 2>/dev/null`; chomp($content);
  push @out, "$name: $content";
 }

 # Syslog (PGenerator entries)
 push @out, "", "--- Syslog (last 500 PGenerator lines) ---";
 push @out, `grep -i PGeneratord /var/log/syslog* /var/log/messages* 2>/dev/null | tail -n 500`;
 chomp($out[$#out]);
 push @out, `tail -n 200 /var/log/daemon.log 2>/dev/null`; chomp($out[$#out]);

 # dmesg tail
 push @out, "", "--- dmesg (last 200 lines) ---";
 push @out, `dmesg | tail -200 2>/dev/null`; chomp($out[$#out]);

 push @out, "", "=" x 72;
 push @out, "  End of diagnostic report";
 push @out, "=" x 72, "";

 my $text=join("\n",@out);
 if(open(my $fh,">:raw",$tmp)) {
  print $fh $text;
  close($fh);
 }
 return (-f $tmp) ? $tmp : "";
}

sub webui_cpu_snapshot (@) {
 my $stat=&read_from_file("/proc/stat");
 foreach my $line (split(/\n/,$stat)) {
  next if($line !~ /^cpu\s+/);
  my @fields=split(/\s+/,$line);
  shift @fields;
  my $total=0;
  $total+=$_ for(@fields);
  my $idle=int($fields[3]||0)+int($fields[4]||0);
  return ($total,$idle);
 }
 return (0,0);
}

sub webui_stats_json (@) {
 my ($cpu_total,$cpu_idle)=&webui_cpu_snapshot();
 if($_stats_cpu_total <= 0 || $cpu_total <= $_stats_cpu_total) {
  $_stats_cpu_total=$cpu_total;
  $_stats_cpu_idle=$cpu_idle;
  select(undef,undef,undef,0.1);
  ($cpu_total,$cpu_idle)=&webui_cpu_snapshot();
 }

 my $cpu_percent=int($_stats_cpu_last||0);
 my $delta_total=$cpu_total-$_stats_cpu_total;
 my $delta_idle=$cpu_idle-$_stats_cpu_idle;
 if($delta_total > 0) {
  $cpu_percent=int((100*(($delta_total-$delta_idle)/$delta_total))+0.5);
  $cpu_percent=0 if($cpu_percent < 0);
  $cpu_percent=100 if($cpu_percent > 100);
  $_stats_cpu_last=$cpu_percent;
 }
 $_stats_cpu_total=$cpu_total;
 $_stats_cpu_idle=$cpu_idle;

 my ($mem_total_kb,$mem_avail_kb,$mem_free_kb)=(0,0,0);
 foreach my $line (split(/\n/,&read_from_file($mem_info_file))) {
  $mem_total_kb=$1 if($line =~ /^MemTotal:\s+(\d+)/);
  $mem_avail_kb=$1 if($line =~ /^MemAvailable:\s+(\d+)/);
  $mem_free_kb=$1 if($line =~ /^MemFree:\s+(\d+)/);
 }
 $mem_avail_kb=$mem_free_kb if($mem_avail_kb <= 0);
 my $mem_used_kb=$mem_total_kb-$mem_avail_kb;
 $mem_used_kb=0 if($mem_used_kb < 0);
 my $mem_percent=($mem_total_kb > 0) ? int((100*$mem_used_kb/$mem_total_kb)+0.5) : 0;
 my $mem_used_mb=int($mem_used_kb/1024);
 my $mem_total_mb=int($mem_total_kb/1024);
 my $mem_avail_mb=int($mem_avail_kb/1024);

 my $freq_raw=&read_from_file($scaling_freq_file);
 $freq_raw=~s/\s+//g;
 my $cpu_freq_mhz=($freq_raw =~ /^\d+$/) ? int($freq_raw/1000) : 0;

 my $load_avg=&read_from_file($load_avg_file);
 my ($load_1,$load_5,$load_15)=split(/\s+/,$load_avg);
 $load_1="" if(!defined $load_1);
 $load_5="" if(!defined $load_5);
 $load_15="" if(!defined $load_15);

 return "{\"cpu_percent\":$cpu_percent,\"cpu_freq_mhz\":$cpu_freq_mhz,\"memory_percent\":$mem_percent,\"memory_used_mb\":$mem_used_mb,\"memory_total_mb\":$mem_total_mb,\"memory_available_mb\":$mem_avail_mb,\"load_1\":\"$load_1\",\"load_5\":\"$load_5\",\"load_15\":\"$load_15\"}";
}

sub webui_modes_json (@) {
 my @modes;
 return "[]" if(!&webui_hdmi_connected());
 my $output=`timeout 5 $modetest -c 2>/dev/null`;
 # Parse modes from modetest output — capture index, resolution, refresh, and pixel clock (kHz)
 while($output=~/^\s*#(\d+)\s+(\d+x\d+i?)\s+([\d.]+)\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+(\d+)\s+/gm) {
  my ($idx,$res,$hz,$clock)=($1,$2,$3,$4);
  push @modes, "{\"idx\":$idx,\"resolution\":\"$res\",\"refresh\":\"$hz\",\"clock\":$clock}";
 }
 return "[".join(",",@modes)."]";
}

sub webui_capabilities_json (@) {
 # Find connected HDMI port and its EDID
 my $edid_path="";
 foreach my $port ($hdmi_2,$hdmi_1) {
  foreach my $card (0..3) {
   my $p="/sys/class/drm/card${card}-${port}";
   if(-d $p) {
    my $st=`cat $p/status 2>/dev/null`; chomp $st;
    if($st eq "connected") {
     $edid_path="$p/edid";
     last;
    }
   }
  }
  last if($edid_path ne "");
 }

 # Defaults (conservative — no deep color, no 420)
 my $dc_30=0; my $dc_36=0; my $dc_y444=0;
 my $dc_420_10=0; my $dc_420_12=0;
 my $max_tmds=340; my $scdc=0;
 my $has_444=0; my $has_422=0;
 my $has_st2084=0; my $has_hlg=0;
 my $has_dv=0; my $dv_444_10b12b=0;
 my %vic_420; # "WxH@HZi" => 1

 if($edid_path ne "" && -e $edid_path) {
  my $e=`timeout 5 $edidparser $edid_path 2>/dev/null`;

  # Base color format support (CTA header)
  $has_444=1 if($e=~/Supports YCbCr 4:4:4/);
  $has_422=1 if($e=~/Supports YCbCr 4:2:2/);

  # HDMI VSDB deep color flags
  $dc_30=1 if($e=~/DC_30bit/);
  $dc_36=1 if($e=~/DC_36bit/);
  $dc_y444=1 if($e=~/DC_Y444/);

  # HDMI VSDB Max TMDS (1.4 block)
  if($e=~/Maximum TMDS clock:\s*(\d+)\s*MHz/) {
   $max_tmds=$1 if($1 > $max_tmds);
  }
  # HDMI Forum VSDB (2.x block)
  if($e=~/Maximum TMDS Character Rate:\s*(\d+)\s*MHz/) {
   $max_tmds=$1 if($1 > $max_tmds);
  }
  $scdc=1 if($e=~/SCDC Present/);
  $dc_420_10=1 if($e=~/10-bits\/component Deep Color 4:2:0/);
  $dc_420_12=1 if($e=~/12-bits\/component Deep Color 4:2:0/);

  # HDR support
  $has_st2084=1 if($e=~/SMPTE ST2084/);
  $has_hlg=1 if($e=~/Hybrid Log-Gamma/);

  # Dolby Vision VSVDB
  if($e=~/Vendor-Specific Video Data Block \(Dolby\)/) {
   $has_dv=1;
   $dv_444_10b12b=1 if($e=~/Supports 10b 12b 444:\s*Supported/i);
  }

  # Parse 4:2:0 Capability Map VICs (resolution@integer_hz)
  my $in_420=0;
  foreach my $line (split /\n/,$e) {
   if($line=~/4:2:0 Capability Map/) { $in_420=1; next; }
   if($in_420) {
    if($line=~/VIC\s+\d+:\s+(\d+x\d+i?)\s+([\d.]+)\s*Hz/) {
     my $key=$1."\@".int($2+0.5);
     $vic_420{$key}=1;
    } elsif($line=~/Data Block|Checksum/) {
     $in_420=0;
    }
   }
  }
 }

 # Build 4:2:0 VIC array
 my @v420=map{"\"$_\""} sort keys %vic_420;

 return "{\"dc_30bit\":".($dc_30?"true":"false")
  .",\"dc_36bit\":".($dc_36?"true":"false")
  .",\"dc_y444\":".($dc_y444?"true":"false")
  .",\"dc_420_10bit\":".($dc_420_10?"true":"false")
  .",\"dc_420_12bit\":".($dc_420_12?"true":"false")
  .",\"max_tmds\":$max_tmds"
  .",\"scdc\":".($scdc?"true":"false")
  .",\"has_ycbcr444\":".($has_444?"true":"false")
  .",\"has_ycbcr422\":".($has_422?"true":"false")
  .",\"has_hdr_st2084\":".($has_st2084?"true":"false")
  .",\"has_hdr_hlg\":".($has_hlg?"true":"false")
  .",\"has_dv\":".($has_dv?"true":"false")
  .",\"dv_444_10b12b\":".($dv_444_10b12b?"true":"false")
  .",\"vic_420\":[".join(",",@v420)."]}";
}

sub webui_wifi_scan_json (@) {
 my @networks;
 my $scan=&sudo("WIFI_SCAN","wlan0");
 foreach my $line (split(/\n/,$scan)) {
  next if($line=~/^bssid|^Selected|^OK/i);
  my @f=split(/\t/,$line);
  next if(scalar @f < 5 || $f[4] eq "");
  my $ssid=$f[4];
  # Skip hidden networks (SSIDs with \x00 or empty/whitespace-only)
  next if($ssid=~/\\x00/ || $ssid=~/^\s*$/);
  $ssid=~s/"/\\"/g;
  # Sanitize: remove any remaining non-printable characters
  $ssid=~s/[^\x20-\x7e]//g;
  next if($ssid eq "");
  my $signal=$f[2];
  my $security=$f[3]=~/WPA/ ? "WPA" : ($f[3]=~/WEP/ ? "WEP" : "Open");
  push @networks, "{\"ssid\":\"$ssid\",\"signal\":$signal,\"security\":\"$security\"}";
 }
 return "[".join(",",@networks)."]";
}

sub webui_wifi_connect (@) {
 my $body=shift;
 my ($ssid,$psk);
 ($ssid)=$body=~/"ssid"\s*:\s*"([^"]*)"/;
 ($psk)=$body=~/"psk"\s*:\s*"([^"]*)"/;
 if(!$ssid) {
  return '{"status":"error","message":"Missing SSID"}';
 }
 &sudo("WIFI_APPLYCONF","wlan0",$ssid,$psk||"");
 return "{\"status\":\"ok\",\"message\":\"Connecting to $ssid\"}";
}

sub webui_wifi_ap_json (@) {
 my %ap;
 if(open(my $fh, "<", $hostapd_conf)) {
  while(<$fh>) {
   chomp;
   if(/^(ssid|wpa_passphrase)=(.*)/) { $ap{$1}=$2; }
  }
  close($fh);
 }
 my $ssid=$ap{ssid}||"";
 my $pass=$ap{wpa_passphrase}||"";
 $ssid=~s/"/\\"/g;
 $pass=~s/"/\\"/g;
 return "{\"status\":\"ok\",\"ssid\":\"$ssid\",\"password\":\"$pass\"}";
}

sub webui_wifi_ap_apply (@) {
 my $body=shift;
 my ($ssid)=$body=~/"ssid"\s*:\s*"([^"]*)"/;
 my ($pass)=$body=~/"password"\s*:\s*"([^"]*)"/;
 if(!$ssid || length($ssid)<1) {
  return '{"status":"error","message":"SSID required"}';
 }
 if(length($pass)<8) {
  return '{"status":"error","message":"Password must be at least 8 characters"}';
 }
 &sudo("WIFI_AP_APPLYCONF","$ssid","$pass");
 return '{"status":"ok","message":"WiFi AP updated and restarted"}';
}

sub webui_wifi_status_json (@) {
 my $status=`timeout 3 wpa_cli -i wlan0 status 2>/dev/null`;
 my %info;
 foreach my $line (split(/\n/,$status)) {
  if($line=~/^(\w+)\s*=\s*(.*)/) { $info{$1}=$2; }
 }
 my $ssid=$info{ssid}||"";
 $ssid=~s/"/\\"/g;
 my $state=$info{wpa_state}||"UNKNOWN";
 my $freq=$info{freq}||"";
 my $ip=$info{ip_address}||"";
 my $bssid=$info{bssid}||"";
 # Get signal strength via iw
 my $signal="";
 my $iw_out=`timeout 3 iw dev wlan0 station dump 2>/dev/null`;
 if($iw_out=~/signal:\s*(-?\d+)/){ $signal=$1; }
 my $band="";
 if($freq=~/^\d+$/) {
  $band=($freq>=5000)?"5 GHz":"2.4 GHz";
 }
 return "{\"status\":\"ok\",\"wpa_state\":\"$state\",\"ssid\":\"$ssid\",\"freq\":\"$freq\",\"band\":\"$band\",\"signal\":\"$signal\",\"ip\":\"$ip\",\"bssid\":\"$bssid\"}";
}

sub webui_infoframes_json (@) {
 my $dmesg=`timeout 3 /bin/dmesg 2>/dev/null`;
 my ($avi_hex,$drm_hex)=("","");
 foreach my $line (split(/\n/,$dmesg)) {
  if($line=~/AVI IF:\s*(.+)/) { $avi_hex=$1; }
  if($line=~/DRM IF:\s*(.+)/) { $drm_hex=$1; }
 }
 $avi_hex=~s/"/\\"/g;
 $drm_hex=~s/"/\\"/g;
 $avi_hex=~s/\s+$//;
 $drm_hex=~s/\s+$//;
 return "{\"status\":\"ok\",\"avi\":\"$avi_hex\",\"drm\":\"$drm_hex\"}";
}

sub webui_cec (@) {
 my $cmd=shift;
 my $cec_bin="/usr/bin/pgcec";
 if(!-x $cec_bin) {
  return '{"status":"error","message":"CEC tool not installed"}';
 }
 # Map legacy commands and validate
 my %cmd_map=("wake"=>"on","as"=>"active");
 $cmd=$cmd_map{$cmd} if(exists $cmd_map{$cmd});
 if($cmd!~/^(status|power|on|off|active|inactive|volup|voldown|mute|input|scan)$/) {
  return '{"status":"error","message":"Invalid CEC command: '.$cmd.'"}';
 }
 # scan returns JSON directly from pgcec scan-json
 if($cmd eq "scan") {
  my $json=`timeout 8 $cec_bin scan-json 2>/dev/null`;
  my $rc=$?>>8;
  chomp($json);
  if($rc == 0 && $json=~/^\{/) {
   return "{\"status\":\"ok\",\"data\":$json}";
  } else {
   $json=~s/"/\\"/g;
   return "{\"status\":\"error\",\"message\":\"Scan failed\",\"output\":\"$json\"}";
  }
 }
 # status returns structured JSON
 if($cmd eq "status") {
  if(!&webui_hdmi_connected()) {
   return '{"status":"ok","tv_power":"unknown","phys_addr":"","log_addr":"","osd_name":"","driver":""}';
  }
  my $power=`timeout 5 $cec_bin power 2>/dev/null`;
  chomp($power);
  my $st=`timeout 5 $cec_bin status 2>/dev/null`;
  my $rc=$?>>8;
  my ($phys,$log,$osd,$driver)=("","","","");
  foreach my $line (split(/\n/,$st)) {
   if($line=~/^physical_addr:\s*(.+)/) { $phys=$1; }
   if($line=~/^logical_addr:\s*(.+)/) { $log=$1; }
   if($line=~/^osd_name:\s*(.+)/) { $osd=$1; }
   if($line=~/^driver:\s*(.+)/) { $driver=$1; }
  }
  $power=~s/"/\\"/g;
  $osd=~s/"/\\"/g;
  $driver=~s/"/\\"/g;
  return "{\"status\":\"ok\",\"tv_power\":\"$power\",\"phys_addr\":\"$phys\",\"log_addr\":\"$log\",\"osd_name\":\"$osd\",\"driver\":\"$driver\"}";
 }
 # action commands
 my $output=`timeout 5 $cec_bin $cmd 2>&1`;
 my $rc=$?>>8;
 $output=~s/"/\\"/g;
 $output=~s/\n/\\n/g;
 if($rc == 0) {
  return "{\"status\":\"ok\",\"output\":\"$output\"}";
 } else {
  return "{\"status\":\"error\",\"output\":\"$output\"}";
 }
}

###############################################
#        Resolve Connect / Disconnect         #
###############################################
sub webui_resolve_connect (@) {
 my $body=shift;
 my ($ip)=$body=~/"ip"\s*:\s*"([^"]+)"/;
 my ($port)=$body=~/"port"\s*:\s*(\d+)/;
 $port=$port_resolve if(!$port);
 return '{"status":"error","message":"Missing ip"}' if(!$ip);
 $ip=~s/[^0-9\.]//g;
 return '{"status":"error","message":"Invalid IP"}' if($ip!~/^\d+\.\d+\.\d+\.\d+$/);
 &resolve_trigger_connect($ip,$port);
 return "{\"status\":\"ok\",\"message\":\"Connecting to $ip:$port\"}";
}

sub webui_resolve_disconnect (@) {
 # Setting request IP to a special value that the thread recognizes as disconnect
 # Actually, we just kill the TCP connection by setting a flag
 # For now, the simplest approach: write to the shared var to signal disconnect
 $calibration_client_ip="";
 $calibration_client_software="";
 return '{"status":"ok","message":"Disconnect requested"}';
}

sub webui_pattern_target_max (@) {
 my $bits=int($bits_default || 8);
 return 1023 if($bits == 10);
 return 4095 if($bits == 12);
 return 255;
}

sub webui_pattern_scale_value (@) {
 my $value=int(shift);
 my $input_max=int(shift);
 my $target_max=&webui_pattern_target_max();
 my %bit_depth_for_max=(255 => 8, 1023 => 10, 4095 => 12);
 $input_max=255 if($input_max <= 0);
 $value=0 if($value < 0);
 $value=$input_max if($value > $input_max);
 return $value if($input_max == $target_max);
 if($bit_depth_for_max{$input_max} && $bit_depth_for_max{$target_max}) {
  my $src_bits=$bit_depth_for_max{$input_max};
  my $dst_bits=$bit_depth_for_max{$target_max};
  return $target_max if($value >= $input_max);
  return $value << ($dst_bits - $src_bits) if($dst_bits > $src_bits);
  return $value >> ($src_bits - $dst_bits) if($dst_bits < $src_bits);
 }
 return int($value/$input_max*$target_max + 0.5);
}

sub webui_pattern_scale_triplet (@) {
 my $r=shift;
 my $g=shift;
 my $b=shift;
 my $input_max=int(shift);
 $input_max=255 if($input_max <= 0);
 return &webui_pattern_scale_value($r,$input_max).",".&webui_pattern_scale_value($g,$input_max).",".&webui_pattern_scale_value($b,$input_max);
}

sub webui_pattern_signal_mode (@) {
 my $body="".shift;
 my ($signal_mode)=$body=~/"signal_mode"\s*:\s*"([^"]+)"/;
 $signal_mode=lc($signal_mode || "");
 $signal_mode=~s/[^a-z0-9]//g;
 if($signal_mode eq "") {
  if(int($pgenerator_conf{"dv_status"} || 0) == 1 || int($pgenerator_conf{"is_ll_dovi"} || 0) == 1 || int($pgenerator_conf{"is_std_dovi"} || 0) == 1) {
   return "dv";
  }
  if(int($pgenerator_conf{"is_hdr"} || 0) == 1) {
   return (int($pgenerator_conf{"eotf"} || 0) == 3) ? "hlg" : "hdr10";
  }
  return "sdr";
 }
 return $signal_mode;
}

sub webui_pattern_max_luma (@) {
 my $body="".shift;
 my ($max_luma)=$body=~/"max_luma"\s*:\s*"?([0-9.]+)"?/;
 $max_luma=$pgenerator_conf{"max_luma"} if(!defined $max_luma || $max_luma eq "");
 $max_luma=1000 if(!defined $max_luma || $max_luma eq "" || $max_luma <= 0);
 $max_luma=10000 if($max_luma > 10000);
 return $max_luma + 0;
}

sub webui_pattern_is_pq_mode (@) {
 my $signal_mode=lc(shift || "");
 return 1 if($signal_mode eq "hdr10" || $signal_mode eq "dv");
 return 0;
}

sub webui_pattern_pq_encode_normalized (@) {
 my $nits=shift;
 $nits=0 if($nits < 0);
 $nits=10000 if($nits > 10000);
 return 0 if($nits <= 0);
 my $l=$nits/10000;
 my $m1=2610/16384;
 my $m2=2523/32;
 my $c1=3424/4096;
 my $c2=2413/128;
 my $c3=2392/128;
 my $p=$l**$m1;
 return (($c1 + $c2*$p)/(1 + $c3*$p))**$m2;
}

sub webui_pattern_pq_decode_normalized (@) {
 my $code=shift;
 $code=0 if($code < 0);
 $code=1 if($code > 1);
 return 0 if($code <= 0);
 my $m1=2610/16384;
 my $m2=2523/32;
 my $c1=3424/4096;
 my $c2=2413/128;
 my $c3=2392/128;
 my $p=$code**(1/$m2);
 my $num=$p-$c1;
 $num=0 if($num < 0);
 my $den=$c2-$c3*$p;
 return 10000 if($den <= 0);
 return 10000*(($num/$den)**(1/$m1));
}

sub webui_pattern_peak_code (@) {
 my $max_code=int(shift);
 my $signal_mode=shift;
 my $max_luma=shift;
 $max_code=255 if($max_code <= 0);
 return $max_code if(!&webui_pattern_is_pq_mode($signal_mode));
 return int(&webui_pattern_pq_encode_normalized($max_luma)*$max_code + 0.5);
}

sub webui_pattern_peak_byte (@) {
 my $signal_mode=shift;
 my $max_luma=shift;
 return &webui_pattern_peak_code(255,$signal_mode,$max_luma);
}

sub webui_pattern_legacy_byte (@) {
 my $value=int(shift);
 my $signal_mode=shift;
 my $max_luma=shift;
 $value=0 if($value < 0);
 $value=255 if($value > 255);
 return $value if(!&webui_pattern_is_pq_mode($signal_mode));
 return 0 if($value == 0);
 # Gamma 2.2 decode to linear light, scale to max_luma nits, PQ encode.
 # DV patterns use gamma 2.2 encoding, so we match that.
 # The old linear mapping (value*peak/255) crushed blacks because PQ is
 # perceptual — a linear fraction of PQ codes does not correspond to a
 # linear fraction of perceived brightness.
 my $linear=($value/255.0)**2.2;
 my $nits=$linear*$max_luma;
 return int(&webui_pattern_pq_encode_normalized($nits)*255 + 0.5);
}

sub webui_pattern_image_new (@) {
 my $w=int(shift);
 my $h=int(shift);
 my $r=int(shift);
 my $g=int(shift);
 my $b=int(shift);
 my $pixel=pack("C3",$r,$g,$b);
 return {"w" => $w, "h" => $h, "buf" => $pixel x ($w*$h)};
}

sub webui_pattern_write_all (@) {
 use bytes;
 my $fh=shift;
 my $buf=shift;
 my $len=length($buf);
 my $off=0;
 while($off < $len) {
  my $written=syswrite($fh,$buf,$len-$off,$off);
  return 0 if(!defined $written || $written <= 0);
  $off+=$written;
 }
 return 1;
}

sub webui_pattern_image_rect (@) {
 my $image=shift;
 my $x1=int(shift);
 my $y1=int(shift);
 my $x2=int(shift);
 my $y2=int(shift);
 my $r=int(shift);
 my $g=int(shift);
 my $b=int(shift);
 return if(!$image);
 $x1=0 if($x1 < 0);
 $y1=0 if($y1 < 0);
 $x2=$image->{"w"}-1 if($x2 >= $image->{"w"});
 $y2=$image->{"h"}-1 if($y2 >= $image->{"h"});
 return if($x2 < $x1 || $y2 < $y1);
 my $row=(pack("C3",$r,$g,$b)) x ($x2-$x1+1);
 my $row_len=bytes::length($row);
 for(my $y=$y1;$y<=$y2;$y++) {
  bytes::substr($image->{"buf"},($y*$image->{"w"}+$x1)*3,$row_len,$row);
 }
}

sub webui_pattern_image_box (@) {
 my $image=shift;
 my $x1=int(shift);
 my $y1=int(shift);
 my $x2=int(shift);
 my $y2=int(shift);
 my $t=int(shift);
 my $r=int(shift);
 my $g=int(shift);
 my $b=int(shift);
 $t=1 if($t < 1);
 &webui_pattern_image_rect($image,$x1,$y1,$x2,$y1+$t-1,$r,$g,$b);
 &webui_pattern_image_rect($image,$x1,$y2-$t+1,$x2,$y2,$r,$g,$b);
 &webui_pattern_image_rect($image,$x1,$y1,$x1+$t-1,$y2,$r,$g,$b);
 &webui_pattern_image_rect($image,$x2-$t+1,$y1,$x2,$y2,$r,$g,$b);
}

sub webui_pattern_digit_rows (@) {
 my $char=shift;
 my %font=(
  "0" => ["111","101","101","101","111"],
  "1" => ["010","110","010","010","111"],
  "2" => ["111","001","111","100","111"],
  "3" => ["111","001","111","001","111"],
  "4" => ["101","101","111","001","001"],
  "5" => ["111","100","111","001","111"],
  "6" => ["111","100","111","101","111"],
  "7" => ["111","001","001","001","001"],
  "8" => ["111","101","111","101","111"],
  "9" => ["111","101","111","001","111"],
  "-" => ["000","000","111","000","000"],
  " " => ["000","000","000","000","000"],
 );
 return $font{$char} if(exists $font{$char});
 return $font{" "};
}

sub webui_pattern_text_width (@) {
 my $text="".shift;
 my $scale=int(shift);
 my $chars=length($text);
 $scale=1 if($scale < 1);
 return 0 if($chars <= 0);
 return $chars*3*$scale + ($chars-1)*$scale;
}

sub webui_pattern_image_char (@) {
 my $image=shift;
 my $char=shift;
 my $x=int(shift);
 my $y=int(shift);
 my $scale=int(shift);
 my $r=int(shift);
 my $g=int(shift);
 my $b=int(shift);
 $scale=1 if($scale < 1);
 my $rows=&webui_pattern_digit_rows($char);
 for(my $row=0;$row<scalar(@$rows);$row++) {
  my $pattern=$rows->[$row];
  for(my $col=0;$col<length($pattern);$col++) {
   next if(substr($pattern,$col,1) ne "1");
   &webui_pattern_image_rect(
    $image,
    $x+$col*$scale,
    $y+$row*$scale,
    $x+(($col+1)*$scale)-1,
    $y+(($row+1)*$scale)-1,
    $r,$g,$b
   );
  }
 }
}

sub webui_pattern_image_text (@) {
 my $image=shift;
 my $text="".shift;
 my $x=int(shift);
 my $y=int(shift);
 my $scale=int(shift);
 my $r=int(shift);
 my $g=int(shift);
 my $b=int(shift);
 my $cursor=$x;
 for(my $i=0;$i<length($text);$i++) {
  my $char=substr($text,$i,1);
  &webui_pattern_image_char($image,$char,$cursor,$y,$scale,$r,$g,$b);
  $cursor+=3*$scale+$scale;
 }
}

sub webui_pattern_image_text_center (@) {
 my $image=shift;
 my $text="".shift;
 my $x1=int(shift);
 my $x2=int(shift);
 my $y=int(shift);
 my $scale=int(shift);
 my $r=int(shift);
 my $g=int(shift);
 my $b=int(shift);
 my $text_w=&webui_pattern_text_width($text,$scale);
 my $x=$x1+int((($x2-$x1+1)-$text_w)/2);
 $x=$x1 if($x < $x1);
 &webui_pattern_image_text($image,$text,$x,$y,$scale,$r,$g,$b);
}

sub webui_pattern_image_save (@) {
 my $image=shift;
 my $file=shift;
 return 0 if(!$image || $file eq "");
 my $buf=$image->{"buf"};
 utf8::downgrade($buf,1);
 if($file=~/\.png$/i) {
  return 0 if(!$convert || !-x $convert);
  unlink($file);
  return 0 if(!open(my $fh,"|-",$convert,"-size",$image->{"w"}."x".$image->{"h"},"-depth","8","rgb:-","PNG24:$file"));
  binmode($fh);
  return 0 if(!&webui_pattern_write_all($fh,$buf));
  return (close($fh) && -f $file) ? 1 : 0;
 }
 return 0 if(!open(my $fh,">",$file));
 binmode($fh);
 return 0 if(!&webui_pattern_write_all($fh,"P6\n".$image->{"w"}." ".$image->{"h"}."\n255\n"));
 return 0 if(!&webui_pattern_write_all($fh,$buf));
 close($fh);
 return 1;
}

sub webui_pattern_label_scale (@) {
 my $h=int(shift);
 my $scale=int($h/270);
 $scale=2 if($scale < 2);
 $scale=7 if($scale > 7);
 return $scale;
}

sub webui_pattern_diag_image_file (@) {
 my $name=lc("".shift);
 $name=~s/[^a-z0-9_]+/_/g;
 $name="diag" if($name eq "");
 my $base="$var_dir/running/webui_pattern_".$name;
 return "$base.png" if($convert && -x $convert);
 return "$var_dir/tmp/webui_pattern_".$name.".ppm";
}

sub webui_pattern_effective_bits (@) {
 my $draw=shift;
 # Diagnostic IMAGE patterns are generated as 8-bit PNG/PPM assets.  Keep the
 # pattern header at 8-bit even on HDR links so the renderer stays on its
 # stable 8-bit IMAGE decode path.
 return 8 if($draw eq "IMAGE");
 my $bits=int($bits_default || 8);
 return 8 if($bits != 10 && $bits != 12);
 return $bits;
}

sub webui_pattern_image_pattern (@) {
 my $w=int(shift);
 my $h=int(shift);
 my $img=shift;
 return "DRAW=IMAGE\nDIM=$w,$h\nRGB=0,0,0\nBG=0,0,0\nPOSITION=0,0\nIMAGE=$img\nEND=1\n";
}

sub webui_pattern_render_white_clipping (@) {
 my $file=shift;
 my $w=int(shift);
 my $h=int(shift);
 my $signal_mode=shift;
 my $max_luma=shift;
 my $image=&webui_pattern_image_new($w,$h,0,0,0);
 my @levels=(232,234,236,238,240,242,244,246,248,250,252,254,255);
 my @labels=@levels;
 my $panel_x=int($w*0.06);
 my $panel_y=int($h*0.15);
 my $panel_w=$w-$panel_x*2;
 my $panel_h=int($h*0.52);
 my $footer_y=$panel_y+$panel_h+int($h*0.045);
 my $footer_h=int($h*0.11);
 my $panel_bg=235;
 my $frame_t=int($h/360);
 my $gap=int($panel_w/(scalar(@levels)*10));
 my $scale=&webui_pattern_label_scale($h);
 my $bar_y1=$panel_y+int($panel_h*0.10);
 my $bar_y2=$panel_y+$panel_h-int($panel_h*0.10)-1;
 $frame_t=2 if($frame_t < 2);
 $gap=2 if($gap < 2);
 $panel_bg=&webui_pattern_legacy_byte($panel_bg,$signal_mode,$max_luma);
 @levels=map { &webui_pattern_legacy_byte($_,$signal_mode,$max_luma) } @levels;
 &webui_pattern_image_rect($image,$panel_x,$panel_y,$panel_x+$panel_w-1,$panel_y+$panel_h-1,$panel_bg,$panel_bg,$panel_bg);
 &webui_pattern_image_box($image,$panel_x,$panel_y,$panel_x+$panel_w-1,$panel_y+$panel_h-1,$frame_t,96,96,96);
 &webui_pattern_image_rect($image,$panel_x,$footer_y,$panel_x+$panel_w-1,$footer_y+$footer_h-1,0,0,0);
 &webui_pattern_image_box($image,$panel_x,$footer_y,$panel_x+$panel_w-1,$footer_y+$footer_h-1,$frame_t,48,48,48);
 for(my $i=0;$i<scalar(@levels);$i++) {
  my $slot_x1=$panel_x+int($i*$panel_w/scalar(@levels));
  my $slot_x2=$panel_x+int((($i+1)*$panel_w)/scalar(@levels))-1;
  $slot_x2=$panel_x+$panel_w-1 if($i == scalar(@levels)-1);
  my $x1=$slot_x1+$gap;
  my $x2=$slot_x2-$gap;
  my $v=$levels[$i];
  my $label=$labels[$i];
  $x1=$slot_x1 if($x1 > $x2);
  $x2=$slot_x2 if($x2 < $x1);
  &webui_pattern_image_rect($image,$x1,$bar_y1,$x2,$bar_y2,$v,$v,$v);
  &webui_pattern_image_text_center($image,$label,$slot_x1,$slot_x2,$footer_y+int(($footer_h-5*$scale)/2),$scale,255,255,255);
 }
 return &webui_pattern_image_save($image,$file);
}

sub webui_pattern_render_black_clipping (@) {
 my $file=shift;
 my $w=int(shift);
 my $h=int(shift);
 my $signal_mode=shift;
 my $max_luma=shift;
 my $image=&webui_pattern_image_new($w,$h,0,0,0);
 my @levels=(2,4,6,8,10,12,14,16,18,20,22,24,25);
 my @labels=@levels;
 my $panel_x=int($w*0.06);
 my $panel_y=int($h*0.18);
 my $panel_w=$w-$panel_x*2;
 my $panel_h=int($h*0.48);
 my $footer_y=$panel_y+$panel_h+int($h*0.05);
 my $footer_h=int($h*0.11);
 my $frame_t=int($h/360);
 my $gap=int($panel_w/(scalar(@levels)*10));
 my $scale=&webui_pattern_label_scale($h);
 my $bar_y1=$panel_y+int($panel_h*0.08);
 my $bar_y2=$panel_y+$panel_h-int($panel_h*0.08)-1;
 $frame_t=2 if($frame_t < 2);
 $gap=2 if($gap < 2);
 @levels=map { &webui_pattern_legacy_byte($_,$signal_mode,$max_luma) } @levels;
 &webui_pattern_image_box($image,$panel_x,$panel_y,$panel_x+$panel_w-1,$panel_y+$panel_h-1,$frame_t,56,56,56);
 &webui_pattern_image_rect($image,$panel_x,$footer_y,$panel_x+$panel_w-1,$footer_y+$footer_h-1,0,0,0);
 &webui_pattern_image_box($image,$panel_x,$footer_y,$panel_x+$panel_w-1,$footer_y+$footer_h-1,$frame_t,48,48,48);
 for(my $i=0;$i<scalar(@levels);$i++) {
  my $slot_x1=$panel_x+int($i*$panel_w/scalar(@levels));
  my $slot_x2=$panel_x+int((($i+1)*$panel_w)/scalar(@levels))-1;
  $slot_x2=$panel_x+$panel_w-1 if($i == scalar(@levels)-1);
  my $x1=$slot_x1+$gap;
  my $x2=$slot_x2-$gap;
  my $v=$levels[$i];
  my $label=$labels[$i];
  $x1=$slot_x1 if($x1 > $x2);
  $x2=$slot_x2 if($x2 < $x1);
  &webui_pattern_image_rect($image,$x1,$bar_y1,$x2,$bar_y2,$v,$v,$v);
  &webui_pattern_image_text_center($image,$label,$slot_x1,$slot_x2,$footer_y+int(($footer_h-5*$scale)/2),$scale,220,220,220);
 }
 return &webui_pattern_image_save($image,$file);
}

sub webui_pattern_render_color_bars (@) {
 my $file=shift;
 my $w=int(shift);
 my $h=int(shift);
 my $signal_mode=shift;
 my $max_luma=shift;
 my $image=&webui_pattern_image_new($w,$h,0,0,0);
 my $l75=&webui_pattern_legacy_byte(int(255*0.75),$signal_mode,$max_luma);
 my @top=(
  [$l75,$l75,$l75],
  [$l75,$l75,0],
  [0,$l75,$l75],
  [0,$l75,0],
  [$l75,0,$l75],
  [$l75,0,0],
  [0,0,$l75],
 );
 my @mid=(
  [0,0,$l75],
  [0,0,0],
  [$l75,0,$l75],
  [0,0,0],
  [0,$l75,$l75],
  [0,0,0],
  [$l75,$l75,$l75],
 );
 my $top_h=int($h*0.67);
 my $mid_y=$top_h;
 my $mid_h=int($h*0.08);
 my $bottom_y=$mid_y+$mid_h;
 for(my $i=0;$i<7;$i++) {
  my $x1=int($i*$w/7);
  my $x2=int((($i+1)*$w)/7)-1;
  $x2=$w-1 if($i == 6);
  &webui_pattern_image_rect($image,$x1,0,$x2,$top_h-1,@{$top[$i]});
  &webui_pattern_image_rect($image,$x1,$mid_y,$x2,$mid_y+$mid_h-1,@{$mid[$i]});
 }
 my $pluge_y1=$bottom_y+int(($h-$bottom_y)*0.18);
 my $pluge_y2=$h-int(($h-$bottom_y)*0.18)-1;
 my $pluge_x=int($w*0.08);
 my $pluge_gap=int($w*0.01);
 my $pluge_w=int($w*0.08);
 my @pluge=(0,8,16,25);
 $pluge_gap=2 if($pluge_gap < 2);
 $pluge_w=20 if($pluge_w < 20);
 for(my $i=0;$i<scalar(@pluge);$i++) {
  my $x1=$pluge_x+$i*($pluge_w+$pluge_gap);
  my $x2=$x1+$pluge_w-1;
  my $v=&webui_pattern_legacy_byte($pluge[$i],$signal_mode,$max_luma);
  &webui_pattern_image_rect($image,$x1,$pluge_y1,$x2,$pluge_y2,$v,$v,$v);
 }
 my $white_x1=int($w*0.39);
 my $white_x2=int($w*0.61)-1;
 my $white_ref=&webui_pattern_peak_byte($signal_mode,$max_luma);
 &webui_pattern_image_rect($image,$white_x1,$bottom_y,$white_x2,$h-1,$white_ref,$white_ref,$white_ref);
 return &webui_pattern_image_save($image,$file);
}

sub webui_pattern_render_gray_ramp (@) {
 my $file=shift;
 my $w=int(shift);
 my $h=int(shift);
 my $signal_mode=shift;
 my $max_luma=shift;
 my $image=&webui_pattern_image_new($w,$h,0,0,0);
 my $peak_byte=&webui_pattern_peak_byte($signal_mode,$max_luma);
 my $ramp_h=int($h*0.68);
 my $row="";
 for(my $x=0;$x<$w;$x++) {
  my $v=int($x*$peak_byte/($w-1) + 0.5);
  $row.=pack("C3",$v,$v,$v);
 }
 my $row_len=bytes::length($row);
 for(my $y=0;$y<$ramp_h;$y++) {
  bytes::substr($image->{"buf"},$y*$row_len,$row_len,$row);
 }
 my $step_y=$ramp_h+int($h*0.05);
 my $steps=11;
 if($step_y < $h) {
  for(my $i=0;$i<$steps;$i++) {
   my $x1=int($i*$w/$steps);
   my $x2=int((($i+1)*$w)/$steps)-1;
   my $v=int($i*$peak_byte/($steps-1) + 0.5);
   $x2=$w-1 if($i == $steps-1);
   &webui_pattern_image_rect($image,$x1,$step_y,$x2,$h-1,$v,$v,$v);
  }
 }
 return &webui_pattern_image_save($image,$file);
}

sub webui_pattern_render_overscan (@) {
 my $file=shift;
 my $w=int(shift);
 my $h=int(shift);
 my $image=&webui_pattern_image_new($w,$h,0,0,0);
 my $bw=int($h/360);
 my $m25x=int($w*0.025);
 my $m25y=int($h*0.025);
 my $m5x=int($w*0.05);
 my $m5y=int($h*0.05);
 my $min_dim=($w < $h) ? $w : $h;
 my $cross=int($min_dim*0.08);
 my $bracket=int($min_dim*0.04);
 my $cx=int($w/2);
 my $cy=int($h/2);
 $bw=2 if($bw < 2);
 $bracket=20 if($bracket < 20);
 &webui_pattern_image_box($image,0,0,$w-1,$h-1,$bw,255,255,255);
 &webui_pattern_image_box($image,$m25x,$m25y,$w-$m25x-1,$h-$m25y-1,$bw,160,160,160);
 &webui_pattern_image_box($image,$m5x,$m5y,$w-$m5x-1,$h-$m5y-1,$bw,96,96,96);
 &webui_pattern_image_rect($image,$cx-$cross,$cy-int($bw/2),$cx+$cross-1,$cy+int(($bw-1)/2),255,255,255);
 &webui_pattern_image_rect($image,$cx-int($bw/2),$cy-$cross,$cx+int(($bw-1)/2),$cy+$cross-1,255,255,255);
 &webui_pattern_image_rect($image,$m5x,$m5y,$m5x+$bracket-1,$m5y+$bw-1,255,255,255);
 &webui_pattern_image_rect($image,$m5x,$m5y,$m5x+$bw-1,$m5y+$bracket-1,255,255,255);
 &webui_pattern_image_rect($image,$w-$m5x-$bracket,$m5y,$w-$m5x-1,$m5y+$bw-1,255,255,255);
 &webui_pattern_image_rect($image,$w-$m5x-$bw,$m5y,$w-$m5x-1,$m5y+$bracket-1,255,255,255);
 &webui_pattern_image_rect($image,$m5x,$h-$m5y-$bw,$m5x+$bracket-1,$h-$m5y-1,255,255,255);
 &webui_pattern_image_rect($image,$m5x,$h-$m5y-$bracket,$m5x+$bw-1,$h-$m5y-1,255,255,255);
 &webui_pattern_image_rect($image,$w-$m5x-$bracket,$h-$m5y-$bw,$w-$m5x-1,$h-$m5y-1,255,255,255);
 &webui_pattern_image_rect($image,$w-$m5x-$bw,$h-$m5y-$bracket,$w-$m5x-1,$h-$m5y-1,255,255,255);
 return &webui_pattern_image_save($image,$file);
}

sub webui_pattern (@) {
 my $body=shift;
 my ($name)=$body=~/"name"\s*:\s*"([^"]+)"/;
 return '{"status":"error","message":"Missing pattern name"}' if(!$name);
 $name=~s/[^a-zA-Z0-9_ -]//g;
 my $signal_mode=&webui_pattern_signal_mode($body);
 my $max_luma=&webui_pattern_max_luma($body);
 my $w=$w_s || 1920; my $h=$h_s || 1080;
 my $pat=""; my $img=&webui_pattern_diag_image_file($name); my $pat_bits=&webui_pattern_effective_bits("");
 my $white_rgb=&webui_pattern_scale_triplet(255,255,255,255);
 my $black_rgb=&webui_pattern_scale_triplet(0,0,0,255);
 my $red_rgb=&webui_pattern_scale_triplet(255,0,0,255);
 my $green_rgb=&webui_pattern_scale_triplet(0,255,0,255);
 my $blue_rgb=&webui_pattern_scale_triplet(0,0,255,255);
 my $cyan_rgb=&webui_pattern_scale_triplet(0,255,255,255);
 my $magenta_rgb=&webui_pattern_scale_triplet(255,0,255,255);
 my $yellow_rgb=&webui_pattern_scale_triplet(255,255,0,255);
 my $gray50_rgb=&webui_pattern_scale_triplet(128,128,128,255);
 # Complex patterns are rendered directly into a temporary image (DRAW=IMAGE),
 # because PGeneratord clears the entire frame for each DRAW=RECTANGLE entry.
 # Prefer PNG for renderer compatibility; fall back to raw PPM only if convert
 # is unavailable on the target system.
 #
 # White Clipping — near-white bar plate with labeled 232-255 bars on a 235 field
 if($name eq "white_clipping") {
  return '{"status":"error","message":"Failed to generate image pattern"}' if(!&webui_pattern_render_white_clipping($img,$w,$h,$signal_mode,$max_luma));
  $pat=&webui_pattern_image_pattern($w,$h,$img);
  $pat_bits=&webui_pattern_effective_bits("IMAGE");
 }
 # Black Clipping — near-black bar plate with labeled 2-25 bars on black
 elsif($name eq "black_clipping") {
  return '{"status":"error","message":"Failed to generate image pattern"}' if(!&webui_pattern_render_black_clipping($img,$w,$h,$signal_mode,$max_luma));
  $pat=&webui_pattern_image_pattern($w,$h,$img);
  $pat_bits=&webui_pattern_effective_bits("IMAGE");
 }
 # Color Bars — 75% Rec.709 bars with a bottom PLUGE/reference section
 elsif($name eq "color_bars") {
  return '{"status":"error","message":"Failed to generate image pattern"}' if(!&webui_pattern_render_color_bars($img,$w,$h,$signal_mode,$max_luma));
  $pat=&webui_pattern_image_pattern($w,$h,$img);
  $pat_bits=&webui_pattern_effective_bits("IMAGE");
 }
 # Gray Ramp — smooth top gradient with 11 stepped bars underneath
 elsif($name eq "gray_ramp") {
  return '{"status":"error","message":"Failed to generate image pattern"}' if(!&webui_pattern_render_gray_ramp($img,$w,$h,$signal_mode,$max_luma));
  $pat=&webui_pattern_image_pattern($w,$h,$img);
  $pat_bits=&webui_pattern_effective_bits("IMAGE");
 }
 # Full field solid colors
   elsif($name eq "white")   { $pat="DRAW=RECTANGLE\nDIM=$w,$h\nRGB=$white_rgb\nBG=$black_rgb\nPOSITION=0,0\nEND=1\n"; }
   elsif($name eq "black")   { $pat="DRAW=RECTANGLE\nDIM=$w,$h\nRGB=$black_rgb\nBG=$black_rgb\nPOSITION=0,0\nEND=1\n"; }
   elsif($name eq "red")     { $pat="DRAW=RECTANGLE\nDIM=$w,$h\nRGB=$red_rgb\nBG=$black_rgb\nPOSITION=0,0\nEND=1\n"; }
   elsif($name eq "green")   { $pat="DRAW=RECTANGLE\nDIM=$w,$h\nRGB=$green_rgb\nBG=$black_rgb\nPOSITION=0,0\nEND=1\n"; }
   elsif($name eq "blue")    { $pat="DRAW=RECTANGLE\nDIM=$w,$h\nRGB=$blue_rgb\nBG=$black_rgb\nPOSITION=0,0\nEND=1\n"; }
   elsif($name eq "cyan")    { $pat="DRAW=RECTANGLE\nDIM=$w,$h\nRGB=$cyan_rgb\nBG=$black_rgb\nPOSITION=0,0\nEND=1\n"; }
   elsif($name eq "magenta") { $pat="DRAW=RECTANGLE\nDIM=$w,$h\nRGB=$magenta_rgb\nBG=$black_rgb\nPOSITION=0,0\nEND=1\n"; }
   elsif($name eq "yellow")  { $pat="DRAW=RECTANGLE\nDIM=$w,$h\nRGB=$yellow_rgb\nBG=$black_rgb\nPOSITION=0,0\nEND=1\n"; }
 # 50% Gray
   elsif($name eq "gray50")  { $pat="DRAW=RECTANGLE\nDIM=$w,$h\nRGB=$gray50_rgb\nBG=$black_rgb\nPOSITION=0,0\nEND=1\n"; }
 # Window pattern — centered white window on black (18% of screen area)
 elsif($name eq "window") {
  my $s=sqrt(0.18); my $ww=int($w*$s); my $wh=int($h*$s);
  my $wx=int(($w-$ww)/2); my $wy=int(($h-$wh)/2);
    $pat="DRAW=RECTANGLE\nDIM=$ww,$wh\nRGB=$white_rgb\nBG=$black_rgb\nPOSITION=$wx,$wy\nEND=1\n";
 }
 # Overscan — borders at 0%, 2.5%, 5% with corner brackets and crosshair
 elsif($name eq "overscan") {
  return '{"status":"error","message":"Failed to generate image pattern"}' if(!&webui_pattern_render_overscan($img,$w,$h));
  $pat=&webui_pattern_image_pattern($w,$h,$img);
  $pat_bits=&webui_pattern_effective_bits("IMAGE");
 }
 # Generic patch — takes r,g,b,size params from JSON body
 elsif($name eq "patch") {
  my ($pr)=$body=~/"r"\s*:\s*(\d+)/; $pr=0 if(!defined $pr);
  my ($pg)=$body=~/"g"\s*:\s*(\d+)/; $pg=0 if(!defined $pg);
  my ($pb)=$body=~/"b"\s*:\s*(\d+)/; $pb=0 if(!defined $pb);
  my ($sz)=$body=~/"size"\s*:\s*(\d+)/; $sz=100 if(!defined $sz);
  my ($imax)=$body=~/"input_max"\s*:\s*(\d+)/;
  my $input_max=$imax ? int($imax) : 255;
  my $target_max=&webui_pattern_target_max();
  $input_max=$target_max if(!$imax && ($pr > 255 || $pg > 255 || $pb > 255));
  $pr=&webui_pattern_scale_value($pr,$input_max);
  $pg=&webui_pattern_scale_value($pg,$input_max);
  $pb=&webui_pattern_scale_value($pb,$input_max);
  if($sz>=100) {
   $pat="DRAW=RECTANGLE\nDIM=$w,$h\nRGB=$pr,$pg,$pb\nBG=$black_rgb\nPOSITION=0,0\nEND=1\n";
  } else {
   my $s=sqrt($sz/100); my $pw=int($w*$s); my $ph=int($h*$s);
   my $px=int(($w-$pw)/2); my $py=int(($h-$ph)/2);
   $pat="DRAW=RECTANGLE\nDIM=$pw,$ph\nRGB=$pr,$pg,$pb\nBG=$black_rgb\nPOSITION=$px,$py\nEND=1\n";
  }
 }
 # Stop — full black (idle)
 elsif($name eq "stop") { $pat="DRAW=RECTANGLE\nDIM=$w,$h\nRGB=$black_rgb\nBG=$black_rgb\nPOSITION=0,0\nEND=1\n"; }
 else {
  return '{"status":"error","message":"Unknown pattern: '.$name.'"}';
 }
 # Ensure the C renderer binary is running (auto-start on first pattern)
 if(&process_pid("$pattern_generator","get") eq "") {
  &pattern_generator_start(1);
 }
 # Write the pattern
 $pat="PATTERN_NAME=$name\nBITS=$pat_bits\n".$pat."FRAME=$frame_default\n";
 open(my $fh,">","$command_file.tmp");
 print $fh $pat;
 close($fh);
 rename("$command_file.tmp","$command_file");
 &create_return_file();
 return '{"status":"ok","pattern":"'.$name.'"}';
}


###############################################
#              HTML Page                      #
###############################################
sub webui_html (@) {
 return <<'WEBUI_HTML';
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>PGenerator+</title>
<link rel="icon" href="/favicon.ico" type="image/x-icon">
<style>
*{margin:0;padding:0;box-sizing:border-box}
:root{--bg:#0a0a0f;--card:#14141f;--border:#2a2a3a;--accent:#5b7fff;--accent2:#7c5bff;
--text:#e0e0e8;--text2:#888898;--green:#4caf50;--red:#f44;--orange:#ff9800;--dv:#b388ff}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;
background:var(--bg);color:var(--text);min-height:100vh;padding:0}
.header{background:linear-gradient(135deg,#1a1a2e 0%,#16213e 100%);
padding:10px 16px;border-bottom:1px solid var(--border);display:flex;
align-items:center;justify-content:space-between;flex-wrap:wrap;gap:8px}
.logo{display:flex;align-items:center;gap:10px}
.logo img{height:40px;width:auto}
.logo h1{font-size:1.3rem;font-weight:700;background:linear-gradient(135deg,var(--accent),var(--accent2));
-webkit-background-clip:text;-webkit-text-fill-color:transparent}
.logo .ver{color:var(--text2);font-size:.85rem;font-weight:600}
.hdr-right{display:flex;align-items:center;gap:12px}
.hdr-actions{display:flex;gap:6px}
.status-bar{display:flex;gap:12px;font-size:.8rem;color:var(--text2)}
.status-bar span{display:flex;align-items:center;gap:4px}
.status-dot{width:8px;height:8px;border-radius:50%;background:var(--text2);display:inline-block;
transition:background .3s;cursor:default;position:relative}
.status-bar span[title]{cursor:default}
.dashboard{max-width:1200px;margin:0 auto;padding:12px;display:grid;
grid-template-columns:1fr 1fr;gap:12px}
.card{background:var(--card);border:1px solid var(--border);border-radius:10px;padding:14px}
.card h2{font-size:.95rem;margin-bottom:10px;color:var(--accent);
display:flex;align-items:center;gap:6px}
.card h2 .icon{font-size:1rem}
.card.span2{grid-column:span 2}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(160px,1fr));gap:8px}
.grid3{display:grid;grid-template-columns:repeat(3,1fr);gap:8px}
.field{display:flex;flex-direction:column;gap:3px}
.field label{font-size:.65rem;color:var(--text2);text-transform:uppercase;letter-spacing:.5px}
.field select,.field input{background:#0d0d15;border:1px solid var(--border);color:var(--text);
padding:6px 10px;border-radius:6px;font-size:.82rem;outline:none;transition:border .2s}
.field select:focus,.field input:focus{border-color:var(--accent)}
.field select{cursor:pointer;-webkit-appearance:none;appearance:none;
background-image:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='10' height='10' fill='%23888'%3E%3Cpath d='M5 7L0 2h10z'/%3E%3C/svg%3E");
background-repeat:no-repeat;background-position:right 8px center;padding-right:24px}
.btn-row{display:flex;gap:6px;flex-wrap:wrap}
.btn{padding:7px 14px;border:none;border-radius:6px;font-size:.8rem;cursor:pointer;
font-weight:600;transition:all .2s;display:flex;align-items:center;gap:4px;white-space:nowrap}
.btn-sm{padding:5px 10px;font-size:.75rem;border-radius:5px}
.btn-primary{background:linear-gradient(135deg,var(--accent),var(--accent2));color:#fff}
.btn-primary:hover{opacity:.9;transform:translateY(-1px)}
.btn-danger{background:var(--red);color:#fff}
.btn-danger:hover{opacity:.9}
.btn-secondary{background:var(--border);color:var(--text)}
.btn-secondary:hover{background:#3a3a4a}
.btn-success{background:var(--green);color:#fff}
.btn-success:hover{opacity:.9}
.toast{position:fixed;bottom:20px;right:20px;background:var(--green);color:#fff;
padding:10px 16px;border-radius:6px;font-size:.85rem;opacity:0;transform:translateY(20px);
transition:all .3s;z-index:999;pointer-events:none}
.toast.show{opacity:1;transform:translateY(0)}
.toast.error{background:var(--red)}
.info-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(145px,1fr));gap:6px}
.info-item{background:#0d0d15;padding:8px;border-radius:6px;min-width:0}
.info-item .label{font-size:.6rem;color:var(--text2);text-transform:uppercase}
.info-item .value{font-size:.82rem;margin-top:1px;line-height:1.2;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;word-break:normal;overflow-wrap:normal}
.stat-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:6px}
.stat-card{background:#0d0d15;padding:8px;border-radius:8px}
.stat-label{font-size:.6rem;color:var(--text2);text-transform:uppercase;letter-spacing:.5px}
.stat-value{font-size:1.05rem;font-weight:700;margin:3px 0 4px}
.stat-value.warn{color:#ffeb3b}.stat-value.hot{color:var(--orange)}.stat-value.bad{color:var(--red)}
.stat-sub{font-size:.68rem;color:var(--text2);line-height:1.3}
.meter{height:5px;background:#1d1d29;border-radius:999px;overflow:hidden;margin-bottom:4px}
.meter-fill{height:100%;width:0;background:linear-gradient(135deg,var(--accent),var(--accent2));transition:width .35s ease}
.wifi-list{max-height:150px;overflow-y:auto;margin:6px 0}
.wifi-item{display:flex;justify-content:space-between;align-items:center;
padding:6px 10px;border-radius:5px;cursor:pointer;transition:background .2s}
.wifi-item:hover{background:#1a1a2e}
.wifi-item .name{font-size:.85rem}
.wifi-item .meta{font-size:.7rem;color:var(--text2)}
.spinner{display:inline-block;width:14px;height:14px;border:2px solid var(--border);
border-top-color:var(--accent);border-radius:50%;animation:spin .6s linear infinite}
@keyframes spin{to{transform:rotate(360deg)}}
.hidden{display:none}
.dv-badge{background:var(--dv);color:#000;padding:2px 8px;border-radius:4px;
font-size:.7rem;font-weight:700;letter-spacing:.5px}
.if-hex{font-family:'Courier New',monospace;font-size:.78rem;color:var(--accent);
background:#0d0d15;padding:8px;border-radius:6px;word-break:break-all;line-height:1.4}
.if-decoded{margin-top:6px;font-size:.75rem;color:var(--text2);line-height:1.5}
.pat-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(100px,1fr));gap:6px}
.pat-grid-sm{display:grid;grid-template-columns:repeat(auto-fill,minmax(55px,1fr));gap:4px}
.pat-btn{padding:8px 4px;border:1px solid var(--border);border-radius:6px;
background:#0d0d15;color:var(--text);font-size:.72rem;cursor:pointer;text-align:center;
transition:all .2s;line-height:1.2;font-weight:500}
.pat-btn:hover{border-color:var(--accent);background:#1a1a2e;transform:translateY(-1px)}
.pat-btn.active{border-color:var(--accent);background:rgba(91,127,255,.15)}
.pat-btn-sm{padding:5px 2px;font-size:.65rem}
.pat-section{margin-bottom:8px}
.pat-section-title{font-size:.65rem;color:var(--text2);text-transform:uppercase;
letter-spacing:.5px;margin-bottom:4px;padding-bottom:2px;border-bottom:1px solid var(--border);
cursor:pointer;user-select:none;display:flex;align-items:center;gap:4px}
.pat-section-title::before{content:'\25BE';font-size:.8em;transition:transform .2s}
.pat-section.collapsed .pat-section-title::before{content:'\25B8'}
.pat-section.collapsed .pat-content{display:none}
.sat-row{display:flex;align-items:center;gap:4px;margin-bottom:4px}
.sat-label{width:52px;font-size:.65rem;font-weight:600;flex-shrink:0}
.sat-btns{display:flex;gap:4px;flex:1;flex-wrap:wrap}
.sat-btns .pat-btn{flex:1;min-width:40px}
.patch-size-bar{display:flex;align-items:center;gap:8px;margin-bottom:12px;padding-bottom:8px;border-bottom:1px solid var(--border)}
.patch-size-bar .field{flex-direction:row;align-items:center;gap:8px}
.patch-size-bar .field label{white-space:nowrap}
.drag-handle{cursor:grab;opacity:.3;margin-right:6px;font-size:.8rem;vertical-align:middle}
.drag-handle:hover{opacity:.7}
.update-pulse{animation:updatePulse 2s ease-in-out infinite}
@keyframes updatePulse{0%,100%{opacity:1}50%{opacity:.6}}
@keyframes thumbPulse{0%,100%{box-shadow:0 0 0 3px #fff}50%{box-shadow:0 0 0 3px rgba(255,255,255,.25)}}
#meterCard.meter-patterns-only #meterSettingsGrid,
#meterCard.meter-patterns-only #meterLiveReading,
#meterCard.meter-patterns-only #meterReadSeriesBtn,
#meterCard.meter-patterns-only #meterCharts,
#meterCard.meter-patterns-only #meterExportRow,
#meterCard.meter-patterns-only #meterSeriesHeader,
#meterCard.meter-patterns-only #meterReadOnce,
#meterCard.meter-patterns-only #meterContinuous,
#meterCard.meter-patterns-only #meterResetRow,
#meterCard.meter-patterns-only #meterProgress,
#meterCard.meter-patterns-only #meterStopBtn{display:none !important}
[data-widget].drag-over{outline:2px dashed var(--accent);outline-offset:-2px}
[data-widget].dragging{opacity:.4}
@media(max-width:800px){.dashboard{grid-template-columns:1fr}
.card.span2{grid-column:span 1}.grid3{grid-template-columns:1fr 1fr}}
@media(max-width:480px){.grid{grid-template-columns:1fr}
.hdr-actions{flex-wrap:wrap}.header{padding:2px 12px}.dashboard{padding:8px}}
#hdmiOverlay{display:none;position:fixed;top:0;left:0;width:100%;height:100%;
background:rgba(0,0,0,.75);z-index:9999;justify-content:center;align-items:center;
backdrop-filter:blur(4px)}
#hdmiOverlay.active{display:flex}
#hdmiOverlay .hdmi-box{background:var(--card);border:1px solid #ff6b35;border-radius:14px;
padding:32px 36px;max-width:480px;width:90%;text-align:center;position:relative;
box-shadow:0 8px 32px rgba(255,107,53,.2)}
#hdmiOverlay .hdmi-box h2{color:#ff6b35;font-size:1.3rem;margin-bottom:12px;
display:flex;align-items:center;justify-content:center;gap:8px}
#hdmiOverlay .hdmi-box p{color:var(--text);font-size:.9rem;line-height:1.5;margin-bottom:20px}
#hdmiOverlay .hdmi-box .hdmi-port{font-weight:700;color:var(--accent)}
#hdmiOverlay .hdmi-actions{display:flex;justify-content:space-between;align-items:center}
#hdmiOverlay .hdmi-dismiss{padding:10px 24px;background:var(--accent);color:#fff;border:none;
border-radius:8px;cursor:pointer;font-size:.85rem;font-weight:600}
#hdmiOverlay .hdmi-dismiss:hover{filter:brightness(1.15)}
#hdmiOverlay .hdmi-ignore{color:var(--text2);background:none;border:none;cursor:pointer;
font-size:.75rem;text-decoration:underline;opacity:.6}
#hdmiOverlay .hdmi-ignore:hover{opacity:1}
#hdmiWarnBadge{display:none;color:#e53935;font-size:.75rem;font-weight:700;
cursor:pointer;animation:updatePulse 2s ease-in-out infinite}
.hdmi-note{color:var(--text2);font-size:.8rem;line-height:1.4;margin-bottom:16px;font-style:italic}
.hdmi-downtime{color:var(--text2);font-size:.75rem;margin-top:12px;opacity:.8}
</style>
</head>
<body>

<div id="hdmiOverlay">
 <div class="hdmi-box">
  <h2>&#9888; Wrong HDMI Port</h2>
  <p>Your HDMI cable is plugged into the wrong port.<br>
  <span class="hdmi-port" id="hdmiPreferred">HDMI-A-1</span> is required.
  Output format, bit depth, and quantization range settings will not work on the secondary port.</p>
  <div class="hdmi-actions">
   <button class="hdmi-ignore" onclick="hdmiIgnore()">Ignore</button>
   <button class="hdmi-dismiss" id="hdmiRecheckBtn" onclick="hdmiRecheck()">I've switched &mdash; Recheck</button>
  </div>
  <p class="hdmi-downtime">The web interface will be unavailable for ~15 seconds while the display reconnects.</p>
 </div>
</div>

<div class="header">
 <div class="logo">
   <img src="data:image/png;base64,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" alt="PGenerator+ logo" style="display:block;">
  <div><div class="ver" id="verDisplay"></div></div>
 </div>
 <div class="hdr-right">
  <div class="hdr-actions">
   <button class="btn btn-sm btn-secondary" id="updateBtn" style="display:none" onclick="showUpdateCard()">Update Available</button>
   <button class="btn btn-sm btn-danger" onclick="if(confirm('Reboot device?'))rebootDevice()">Reboot</button>
  </div>
  <div class="status-bar">
   <span title="" id="statusWrap"><span class="status-dot" id="statusDot"></span><span id="statusText">...</span></span>
   <span id="tempDisplay"></span>
   <span id="calStatusWrap" title="No calibration software connected"><span class="status-dot" id="calDot" style="background:var(--text2)"></span><span id="calStatusText" style="color:var(--text2)">No SW</span></span>
   <span id="meterStatusWrap" style="display:none" title="Colorimeter"><span class="status-dot" id="meterDot" style="background:var(--text2)"></span><span id="meterStatusText" style="color:var(--text2)">Meter</span></span>
   <span id="hdmiWarnBadge" onclick="hdmiShowOverlay()" title="HDMI cable is on the wrong port">&#9888; Wrong HDMI Port</span>
  </div>
 </div>
</div>

<div class="dashboard">

 <!-- Display Settings -->
 <div class="card">
  <h2>Display Settings <button class="btn btn-sm btn-secondary" style="float:right;font-size:.65rem;padding:2px 8px" onclick="resetDefaults()">Defaults</button></h2>
  <div class="grid">
   <div class="field">
    <label>Resolution</label>
    <select id="mode_idx"></select>
   </div>
   <div class="field">
    <label>Signal Mode</label>
    <select id="signal_mode">
     <option value="sdr">SDR</option>
     <option value="hdr10">HDR10 (PQ)</option>
     <option value="hlg">HLG</option>
     <option value="dv">Dolby Vision</option>
    </select>
   </div>
   <div class="field">
    <label>Bit Depth</label>
    <select id="max_bpc">
     <option value="8">8-bit</option>
     <option value="10">10-bit</option>
     <option value="12">12-bit</option>
    </select>
   </div>
   <div class="field">
    <label>Color Format</label>
    <select id="color_format">
     <option value="0">RGB</option>
     <option value="1">YCbCr 4:4:4</option>
     <option value="2">YCbCr 4:2:2</option>
     <option value="3">YCbCr 4:2:0</option>
    </select>
   </div>
   <div class="field">
    <label>Colorimetry</label>
    <select id="colorimetry">
     <option value="2">BT.709</option>
     <option value="9">BT.2020</option>
    </select>
   </div>
   <div class="field">
    <label>Range</label>
    <select id="rgb_quant_range">
     <option value="0">Default</option>
     <option value="1">Limited (16-235)</option>
     <option value="2">Full (0-255)</option>
    </select>
   </div>
  </div>
 </div>

 <!-- HDR Metadata -->
 <div class="card" id="hdrCard">
  <h2>HDR Metadata</h2>
  <div class="grid">
   <div class="field">
    <label>EOTF</label>
    <select id="eotf">
     <option value="0">SDR Gamma</option>
     <option value="1">HDR Gamma</option>
     <option value="2">ST.2084 (PQ)</option>
     <option value="3">HLG</option>
    </select>
   </div>
   <div class="field">
    <label>Primaries</label>
    <select id="primaries">
     <option value="0">Custom / BT.709</option>
     <option value="1">BT.2020 / D65</option>
     <option value="2">DCI-P3 / D65</option>
     <option value="3">DCI-P3 / DCI</option>
    </select>
   </div>
   <div class="field">
    <label>Max Luma (nits)</label>
    <input type="number" id="max_luma" min="0" max="10000" step="1">
   </div>
   <div class="field">
    <label>Min Luma (nits)</label>
    <input type="number" id="min_luma" min="0" max="100" step="0.0001">
   </div>
   <div class="field">
    <label>MaxCLL</label>
    <input type="number" id="max_cll" min="0" max="10000" step="1">
   </div>
   <div class="field">
    <label>MaxFALL</label>
    <input type="number" id="max_fall" min="0" max="10000" step="1">
   </div>
  </div>
 </div>

 <!-- Dolby Vision Settings -->
 <div class="card" id="dvCard">
  <h2><span class="dv-badge">DV</span> Dolby Vision</h2>
  <div style="font-size:.7rem;color:var(--text2);margin-bottom:10px;line-height:1.4">Enables Dolby Vision LLDV output. RGB color format (color_format=0) and BT.2020 primaries are set automatically.</div>
  <div class="grid">
   <div class="field">
    <label>Map Mode</label>
    <select id="dv_map_mode">
     <option value="2">Relative</option>
     <option value="1">Absolute</option>
    </select>
   </div>
   <input type="hidden" id="dv_interface" value="1">
  </div>
 </div>

 <!-- Apply Settings Bar -->
 <div class="card span2" id="applyBar" style="display:none">
  <div style="display:flex;align-items:center;justify-content:space-between">
   <span style="color:var(--text2);font-size:.85rem">Settings changed</span>
   <button class="btn btn-sm btn-primary" onclick="applySettings()">Apply &amp; Restart</button>
  </div>
 </div>

 <!-- Diagnostic Patterns -->
 <div class="card span2" data-widget="patterns" draggable="true">
  <h2><span class="drag-handle">&#9776;</span>Diagnostic Patterns</h2>
  <div class="pat-section">
   <div class="pat-content">
    <div style="font-size:.65rem;color:var(--text2);margin-bottom:6px;line-height:1.4">Visual setup patterns for display calibration. Use these to verify your display&#39;s basic picture settings before running a full calibration.</div>
    <div class="pat-grid">
    <button class="pat-btn" onclick="showPattern('white_clipping',event)">White Clipping</button>
    <button class="pat-btn" onclick="showPattern('black_clipping',event)">Black Clipping</button>
    <button class="pat-btn" onclick="showPattern('color_bars',event)">Color Bars</button>
    <button class="pat-btn" onclick="showPattern('gray_ramp',event)">Gray Ramp</button>
    <button class="pat-btn" onclick="showPattern('overscan',event)">Overscan</button>
    </div>
    <div id="diagInfo" style="font-size:.7rem;color:var(--text2);margin-top:8px;padding:8px 10px;background:#0d0d15;border-radius:6px;line-height:1.5;display:none"></div>
   </div>
  </div>

 </div>

 <!-- Meter & Measurements -->
 <div class="card span2 meter-patterns-only" data-widget="meter" draggable="true" id="meterCard">
  <h2 id="meterCardTitle"><span class="drag-handle">&#9776;</span>Test Patterns</h2>
  <div id="meterResetRow" style="display:none;background:#3a2020;border-radius:6px;padding:8px 12px;margin-bottom:10px;align-items:center;gap:10px">
   <span style="color:var(--orange);font-size:.85rem">&#9888; Meter disconnected &mdash; USB may need a reset</span>
   <button class="btn btn-sm" style="margin-left:auto" onclick="meterResetUSB()">&#128260; Reset USB</button>
  </div>
  <div class="grid" id="meterSettingsGrid" style="margin-bottom:10px">
   <div class="field">
    <label>Display Type</label>
    <select id="meterDisplayType">
     <optgroup label="Generic" id="meterDtGeneric">
      <option value="oled_generic">Generic (WRGB OLED)</option>
      <option value="qdoled">Generic (QD-OLED)</option>
      <option value="lcd_wled">LCD - White LED</option>
      <option value="lcd_rgbled">LCD - RGB LED</option>
      <option value="lcd_ccfl">LCD - CCFL</option>
      <option value="lcd_wgccfl">LCD - Wide Gamut CCFL</option>
      <option value="plasma">Plasma</option>
      <option value="projector_ccss">Projector</option>
      <option value="crt">CRT</option>
      <option value="lcd">None (no correction)</option>
      <option value="custom">Custom CCSS...</option>
     </optgroup>
     <optgroup label="Display-specific CCSS" id="meterDtCcss"></optgroup>
    </select>
    <div id="customCcssPanel" style="display:none;margin-top:6px;padding:8px;background:#1a1a2e;border-radius:6px;border:1px solid #333">
     <label style="font-size:.72rem;color:var(--text2);display:block;margin-bottom:4px">Upload CCSS or spectral CSV</label>
     <input type="file" id="ccssFileInput" accept=".ccss,.csv" style="font-size:.72rem;width:100%;margin-bottom:6px">
     <div style="display:flex;gap:6px;align-items:center">
      <input type="text" id="ccssName" placeholder="Profile name" style="flex:1;font-size:.78rem;padding:3px 6px;background:#12121e;border:1px solid #444;border-radius:4px;color:var(--text)">
      <button id="ccssUploadBtn" class="btn btn-sm btn-secondary" style="white-space:nowrap;font-size:.72rem;padding:3px 10px" disabled>Upload</button>
     </div>
     <div id="ccssUploadStatus" style="font-size:.7rem;color:var(--text2);margin-top:4px"></div>
     <div id="customCcssList" style="margin-top:6px"></div>
    </div>
    <label style="display:flex;align-items:center;gap:4px;font-size:.72rem;color:var(--text2);cursor:pointer;margin-top:4px" title="Insert a neutral patch between measurement patterns to stabilize OLED ABL">
     <input type="checkbox" id="meterPatchInsert" checked> Pattern Insertion
    </label>
   </div>
   <div class="field">
    <label>Target Colorspace</label>
    <select id="meterTargetGamut">
     <option value="auto" selected>Auto (match signal)</option>
     <option value="bt709">BT.709</option>
     <option value="bt2020">BT.2020</option>
     <option value="p3d65">DCI-P3 / D65</option>
    </select>
   </div>
   <div class="field">
    <label>Target Gamma</label>
    <select id="meterTargetGamma">
     <option value="bt1886">BT.1886 (2.4)</option>
     <option value="2.2">Gamma 2.2</option>
     <option value="2.4">Gamma 2.4</option>
     <option value="srgb">sRGB</option>
    </select>
   </div>
   <div class="field">
    <label>Settle Delay</label>
    <select id="meterDelay">
     <option value="1000">1 second</option>
     <option value="2000" selected>2 seconds</option>
     <option value="3000">3 seconds</option>
     <option value="5000">5 seconds</option>
     <option value="8000">8 seconds</option>
    </select>
   </div>
   <div class="field">
    <label>Patch Size</label>
    <select id="meterPatchSize">
     <option value="2">2% Window</option>
     <option value="5">5% Window</option>
     <option value="10">10% Window</option>
     <option value="18" selected>18% Window</option>
     <option value="25">25% Window</option>
     <option value="50">50% Window</option>
     <option value="75">75% Window</option>
     <option value="100">100% Full Field</option>
     <option disabled>─── APL ───</option>
     <option value="apl_5">5% APL (window on black)</option>
     <option value="apl_10">10% APL (window on black)</option>
     <option value="apl_18">18% APL (window on grey)</option>
     <option value="apl_25">25% APL (window on grey)</option>
     <option value="apl_50">50% APL (window on grey)</option>
    </select>
   </div>
   <div class="field">
    <label>Refresh Rate</label>
    <select id="meterRefreshRate">
     <option value="" selected>Match Display Setting</option>
     <option value="23.976">23.976 Hz</option>
     <option value="24">24 Hz</option>
     <option value="25">25 Hz</option>
     <option value="29.97">29.97 Hz</option>
     <option value="30">30 Hz</option>
     <option value="50">50 Hz</option>
     <option value="59.94">59.94 Hz</option>
     <option value="60">60 Hz</option>
     <option value="100">100 Hz</option>
     <option value="120">120 Hz</option>
    </select>
   </div>
   <label style="display:flex;align-items:center;gap:4px;font-size:.72rem;color:var(--text2);cursor:pointer;margin-top:4px" title="Disable Adaptive Integration Optimization for i1Display3 meters. May improve accuracy at low and high luminance levels.">
    <input type="checkbox" id="meterDisableAIO" checked> Disable AIO (i1D3)
   </label>
  </div>

  <!-- Live Reading -->
  <div id="meterLiveReading" style="display:none;margin-bottom:12px">
   <div style="font-size:.65rem;color:var(--text2);text-transform:uppercase;margin-bottom:4px">Live Reading</div>
   <div style="background:#0d0d15;padding:10px;border-radius:6px">
    <div style="display:flex;gap:16px;flex-wrap:wrap;margin-bottom:8px;font-size:.82rem">
     <span>Luminance: <strong id="meterLum">--</strong> cd/m&sup2;</span>
     <span>CCT: <strong id="meterCCT">--</strong>K</span>
     <span>CIE x: <strong id="meterCIEx">--</strong></span>
     <span>CIE y: <strong id="meterCIEy">--</strong></span>
    </div>
    <div id="meterRGBBars">
     <canvas id="meterRGBCanvas" width="600" height="60" style="width:100%;height:60px;border-radius:4px"></canvas>
    </div>
   </div>
  </div>

  <!-- Series Controls -->
  <div id="meterSeriesHeader" style="font-size:.65rem;color:var(--text2);text-transform:uppercase;margin-bottom:4px;padding-top:8px;border-top:1px solid var(--border)">Series Measurements</div>
  <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:8px;flex-wrap:wrap;gap:4px">
   <div class="btn-row" id="meterSeriesBtnRow" style="margin:0">
    <button class="btn btn-sm btn-secondary" data-series="greyscale-21" onclick="meterSelectSeries('greyscale',21)">Greyscale 21pt</button>
    <button class="btn btn-sm btn-secondary" data-series="greyscale-11" onclick="meterSelectSeries('greyscale',11)">Greyscale 11pt</button>
    <button class="btn btn-sm btn-secondary" data-series="colors-30" onclick="meterSelectSeries('colors',30)">Colors</button>
    <button class="btn btn-sm btn-secondary" data-series="saturations-24" onclick="meterSelectSeries('saturations',24)">Sat Sweep</button>
   </div>
   <div class="btn-row" id="meterReadBtnRow" style="margin:0">
    <button class="btn btn-sm btn-secondary" id="meterReadOnce" onclick="meterReadOnce()" style="display:none" disabled>&#9679; Read Once</button>
    <button class="btn btn-sm btn-secondary" id="meterContinuous" onclick="meterToggleContinuous()" style="display:none" disabled>&#8635; Continuous</button>
    <button class="btn btn-sm btn-secondary" id="meterReadSeriesBtn" onclick="meterRunSeries()" style="display:none">&#9654; Read Series</button>
    <button class="btn btn-sm btn-danger" id="meterStopBtn" onclick="meterStop()" style="display:none">&#9632; Stop</button>
   </div>
  </div>
  <div id="meterThumbsRow" style="display:none;margin-bottom:10px">
   <div id="meterPatchThumbs" style="display:flex;gap:2px;width:100%"></div>
  </div>

  <!-- Series Status -->
  <div id="meterProgress" style="display:none;margin-bottom:6px">
   <div style="display:flex;justify-content:space-between;font-size:.75rem">
    <span id="meterProgressLabel">Ready</span>
   </div>
  </div>

  <!-- Charts Container -->
  <div id="meterCharts" style="display:none">
   <div style="display:flex;justify-content:flex-end;gap:8px;margin-bottom:10px">
    <button class="btn btn-sm btn-danger" onclick="meterClearResults()">Clear Chart Data</button>
   </div>
   <div id="chartsGreyscaleWrap">
    <div style="margin-bottom:10px">
     <div style="font-size:.65rem;color:var(--text2);text-transform:uppercase;margin-bottom:4px">RGB Balance</div>
     <canvas id="chartRGB" width="800" height="220" style="width:100%;background:#0d0d15;border-radius:6px"></canvas>
    </div>
    <div style="margin-bottom:10px">
     <div style="display:flex;align-items:center;gap:10px;margin-bottom:4px;flex-wrap:wrap">
      <label style="font-size:.7rem;color:var(--text2);cursor:pointer;user-select:none">
       <input type="checkbox" id="meterIncludeLumError" onchange="if(meterReadings&&meterReadings.length)drawAllCharts(meterReadings)" style="vertical-align:middle"> Include luminance error
      </label>
     </div>
     <div style="font-size:.65rem;color:var(--text2);text-transform:uppercase;margin-bottom:4px" id="chartDeltaELabel">&Delta;E CIELUV</div>
     <canvas id="chartDeltaE" width="800" height="132" style="width:100%;background:#0d0d15;border-radius:6px"></canvas>
    </div>
    <div style="margin-bottom:10px">
     <div style="font-size:.65rem;color:var(--text2);text-transform:uppercase;margin-bottom:4px" id="chartDeltaE2000Label">&Delta;E 2000 (CIEDE2000)</div>
     <canvas id="chartDeltaE2000" width="800" height="132" style="width:100%;background:#0d0d15;border-radius:6px"></canvas>
    </div>
    <div id="chartTooltip" style="display:none;position:fixed;pointer-events:none;z-index:9999;background:rgba(13,13,21,0.95);border:1px solid #555;border-radius:5px;padding:6px 10px;font-size:12px;color:#ddd;white-space:nowrap;box-shadow:0 2px 8px rgba(0,0,0,0.5)"></div>
    <div style="display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-bottom:10px">
     <div>
      <div style="font-size:.65rem;color:var(--text2);text-transform:uppercase;margin-bottom:4px">EOTF</div>
      <canvas id="chartEOTF" width="500" height="280" style="width:100%;background:#0d0d15;border-radius:6px"></canvas>
     </div>
     <div>
      <div style="font-size:.65rem;color:var(--text2);text-transform:uppercase;margin-bottom:4px">Luminance</div>
      <canvas id="chartGamma" width="500" height="280" style="width:100%;background:#0d0d15;border-radius:6px"></canvas>
     </div>
    </div>
   </div>
   <div id="chartsColorWrap" style="display:none">
    <div style="margin-bottom:10px">
     <div style="font-size:.65rem;color:var(--text2);text-transform:uppercase;margin-bottom:4px">CIE 1931 Chromaticity</div>
     <div id="colorTopLayout" style="display:flex;gap:10px;align-items:flex-start;flex-wrap:wrap">
      <canvas id="chartCIE" width="600" height="600" style="flex:1;min-width:0;max-width:450px;background:#0d0d15;border-radius:6px;aspect-ratio:1/1"></canvas>
      <div id="colorReadingDetail" style="width:190px;flex:0 0 190px;background:#0d0d15;border-radius:6px;padding:10px;font-size:11px;color:#888">
       <div id="colorDetailContent" style="text-align:center;padding:30px 0;color:#555">Select a color<br>to see details</div>
      </div>
      <div id="colorSeriesAveragesWrap" style="flex:1;min-width:260px;display:none">
       <div style="font-size:.65rem;color:var(--text2);text-transform:uppercase;margin-bottom:4px">Series Averages</div>
       <div style="overflow-x:auto;border-radius:6px;background:#0d0d15">
        <table id="colorSeriesAveragesTable" style="width:100%;border-collapse:collapse;font-size:11px;color:#ccc;white-space:nowrap">
         <thead><tr style="border-bottom:1px solid #333;color:#888;text-align:right">
          <th style="text-align:left;padding:6px 8px">Group</th>
          <th style="padding:6px 6px">n</th>
          <th style="padding:6px 6px">Avg |&Delta;x|</th>
          <th style="padding:6px 6px">Avg |&Delta;y|</th>
          <th style="padding:6px 6px">Avg Y cd/m&sup2;</th>
          <th style="padding:6px 6px">Avg &Delta;E 2000</th>
          <th style="padding:6px 6px">Max &Delta;E 2000</th>
         </tr></thead>
         <tbody></tbody>
        </table>
       </div>
      </div>
     </div>
    </div>
    <div style="margin-bottom:10px">
    <div style="font-size:.65rem;color:var(--text2);text-transform:uppercase;margin-bottom:4px" id="chartColorDELabel">&Delta;E 2000 (Color Accuracy)</div>
     <canvas id="chartColorDE" width="800" height="180" style="width:100%;background:#0d0d15;border-radius:6px"></canvas>
    </div>
    <div id="colorReadingsTableWrap" style="margin-bottom:10px;display:none">
     <div style="font-size:.65rem;color:var(--text2);text-transform:uppercase;margin-bottom:4px">Color Readings</div>
     <div style="overflow-x:auto;border-radius:6px;background:#0d0d15">
      <table id="colorReadingsTable" style="width:100%;border-collapse:collapse;font-size:11px;color:#ccc;white-space:nowrap">
       <thead><tr style="border-bottom:1px solid #333;color:#888;text-align:right">
        <th style="text-align:left;padding:6px 8px">Color</th>
        <th style="padding:6px 6px">Tgt x</th><th style="padding:6px 6px">Tgt y</th>
        <th style="padding:6px 6px">x</th><th style="padding:6px 6px">y</th>
        <th style="padding:6px 6px">Y cd/m&sup2;</th>
        <th style="padding:6px 6px">&Delta;x</th><th style="padding:6px 6px">&Delta;y</th>
        <th style="padding:6px 6px">&Delta;E 2000</th>
       </tr></thead>
       <tbody></tbody>
      </table>
     </div>
    </div>
   </div>
  </div>

  <!-- Export / Report -->
  <div class="btn-row" id="meterExportRow" style="display:none">
   <button class="btn btn-sm btn-secondary" onclick="meterExportCSV()">&#128190; Export CSV</button>
   <button class="btn btn-sm btn-secondary" onclick="meterOpenReportDialog()">&#128196; Generate Report</button>
  </div>

  <div id="meterReportOverlay" style="display:none;position:fixed;inset:0;background:rgba(0,0,0,.7);z-index:10000;align-items:center;justify-content:center;padding:16px">
   <div style="width:min(460px,96vw);background:#111522;border:1px solid #2d3348;border-radius:10px;padding:14px;box-shadow:0 12px 40px rgba(0,0,0,.45)">
    <div style="display:flex;align-items:center;justify-content:space-between;gap:10px;margin-bottom:10px">
     <div style="font-size:.95rem;font-weight:700;color:var(--text)">Generate Measurement Report</div>
     <button class="btn btn-sm btn-secondary" onclick="meterCloseReportDialog()">Close</button>
    </div>
    <div style="font-size:.72rem;color:var(--text2);margin-bottom:8px">Choose which measured series to include and export as HTML or PDF.</div>
    <div style="font-size:.7rem;color:var(--text2);text-transform:uppercase;margin:10px 0 6px">Include Series Data</div>
    <div id="meterReportSeriesList" style="display:grid;gap:6px;margin-bottom:12px"></div>
    <div style="font-size:.7rem;color:var(--text2);text-transform:uppercase;margin:10px 0 6px">Output Format</div>
    <div style="display:flex;gap:14px;flex-wrap:wrap;margin-bottom:14px">
     <label style="display:flex;align-items:center;gap:6px;cursor:pointer"><input type="radio" name="meterReportFormat" value="html" checked> HTML</label>
     <label style="display:flex;align-items:center;gap:6px;cursor:pointer"><input type="radio" name="meterReportFormat" value="pdf"> PDF</label>
    </div>
    <div class="btn-row" style="justify-content:flex-end;margin:0">
     <button class="btn btn-sm btn-secondary" onclick="meterCloseReportDialog()">Cancel</button>
     <button class="btn btn-sm btn-primary" id="meterReportGenerateBtn" onclick="meterGenerateReport()">Generate</button>
    </div>
   </div>
  </div>
 </div>

 <!-- Device Info -->
 <div class="card span2" data-widget="info" draggable="true">
  <h2><span class="drag-handle">&#9776;</span>Device Info</h2>
  <div class="stat-grid" style="margin-bottom:8px">
   <div class="stat-card">
    <div class="stat-label">CPU Usage</div>
    <div class="stat-value" id="cpuUsageValue">--%</div>
    <div class="meter"><div class="meter-fill" id="cpuUsageBar"></div></div>
    <div class="stat-sub" id="cpuUsageSub">--</div>
   </div>
   <div class="stat-card">
    <div class="stat-label">Memory Usage</div>
    <div class="stat-value" id="memUsageValue">--%</div>
    <div class="meter"><div class="meter-fill" id="memUsageBar"></div></div>
    <div class="stat-sub" id="memUsageSub">--</div>
   </div>
  </div>
  <div class="info-grid" id="infoGrid"></div>
 </div>

 <!-- WiFi Client -->
 <div class="card" data-widget="wifi" draggable="true">
  <h2><span class="drag-handle">&#9776;</span>WiFi Client</h2>
  <div class="info-grid" id="wifiStatus" style="margin-bottom:8px"></div>
  <div class="btn-row" style="margin-bottom:8px">
   <button class="btn btn-sm btn-secondary" onclick="scanWifi()">Scan Networks</button>
     <button class="btn btn-sm btn-danger" id="wifiDisconnectBtn" onclick="disconnectWifi()" style="display:none">Disconnect</button>
     <button class="btn btn-sm btn-danger" id="wifiForgetBtn" onclick="forgetWifi()" style="display:none">Forget</button>
  </div>
  <div id="wifiList" class="wifi-list"></div>
  <div id="wifiConnect" class="hidden" style="margin-top:8px">
   <div class="grid">
    <div class="field">
     <label>Network</label>
     <input type="text" id="wifiSsid" readonly>
    </div>
    <div class="field">
     <label>Password</label>
     <input type="password" id="wifiPsk" placeholder="Enter password">
    </div>
   </div>
   <div class="btn-row" style="margin-top:8px">
    <button class="btn btn-sm btn-primary" onclick="connectWifi()">Connect</button>
    <button class="btn btn-sm btn-secondary" onclick="hideWifiForm()">Cancel</button>
   </div>
  </div>
 </div>

 <!-- HDMI-CEC TV Control -->
 <div class="card" data-widget="cec" draggable="true">
  <h2><span class="drag-handle">&#9776;</span>HDMI-CEC</h2>
  <div style="display:flex;align-items:center;gap:12px;margin-bottom:8px">
   <span id="cecStatus" style="font-size:.85rem;color:var(--text2)">Checking...</span>
  </div>
  <div class="btn-row" style="margin-bottom:8px">
   <button class="btn btn-sm btn-success" onclick="cecCmd('on')" title="Wake TV and switch to PGenerator input">&#9654; Power On</button>
   <button class="btn btn-sm btn-danger" onclick="cecCmd('off')" title="Put TV in standby">&#9724; Standby</button>
   <button class="btn btn-sm btn-secondary" onclick="cecCmd('active')" title="Switch TV to PGenerator HDMI input">&#8594; Switch Input</button>
  </div>
  <div class="btn-row" style="margin-bottom:8px">
   <button class="btn btn-sm btn-secondary" onclick="cecCmd('volup')" title="Volume Up">&#128266;+</button>
   <button class="btn btn-sm btn-secondary" onclick="cecCmd('voldown')" title="Volume Down">&#128264;-</button>
   <button class="btn btn-sm btn-secondary" onclick="cecCmd('mute')" title="Toggle Mute">&#128263; Mute</button>
  </div>
  <details style="margin-top:4px">
   <summary style="cursor:pointer;font-size:.85rem;color:var(--text2)">CEC Bus Devices</summary>
   <div id="cecDevices" style="font-size:.8rem;margin-top:6px;color:var(--text2)">
    <button class="btn btn-sm btn-secondary" onclick="cecScan()" style="margin-bottom:6px">Scan CEC Bus</button>
    <div id="cecDeviceList">Not scanned yet</div>
   </div>
  </details>
 </div>

 <!-- Resolve Protocol -->
 <div class="card" data-widget="resolve" draggable="true">
  <h2><span class="drag-handle">&#9776;</span>Resolve Protocol <span id="resolveStatusBadge" style="font-size:.7rem;padding:2px 8px;border-radius:4px;background:var(--text2);color:#000;margin-left:8px">Disconnected</span></h2>
  <div style="font-size:.7rem;color:var(--text2);margin-bottom:8px;line-height:1.4">Connect via HCFR / DisplayCAL Resolve protocol. Enter the IP of the PC running calibration software.</div>
  <div class="grid">
   <div class="field">
    <label>Calibration PC IP</label>
    <input type="text" id="resolveIp" placeholder="192.168.1.x">
   </div>
   <div class="field">
    <label>Port</label>
    <input type="number" id="resolvePort" value="20002" min="1" max="65535">
   </div>
  </div>
  <div class="btn-row" style="margin-top:8px">
   <button class="btn btn-sm btn-success" id="resolveConnectBtn" onclick="resolveConnect()">&#9654; Connect</button>
   <button class="btn btn-sm btn-danger" id="resolveDisconnectBtn" onclick="resolveDisconnect()" style="display:none">&#9724; Disconnect</button>
  </div>
 </div>

 <!-- WiFi AP (PAN) -->
 <div class="card" data-widget="ap" draggable="true">
  <h2><span class="drag-handle">&#9776;</span>WiFi Access Point</h2>
  <div class="grid">
   <div class="field">
    <label>SSID</label>
    <input type="text" id="apSsid" placeholder="PGenerator">
   </div>
   <div class="field">
    <label>Password</label>
    <input type="text" id="apPass" placeholder="Min 8 characters">
   </div>
  </div>
  <div class="btn-row" style="margin-top:8px">
   <button class="btn btn-sm btn-primary" onclick="applyAP()">Save AP Settings</button>
  </div>
  <div style="margin-top:6px;font-size:.7rem;color:var(--text2)">Connect to this AP at 10.10.10.1</div>
 </div>

 <!-- HDMI Infoframes -->
 <div class="card" data-widget="infoframes" draggable="true">
  <h2><span class="drag-handle">&#9776;</span>HDMI Infoframes</h2>
  <div class="btn-row" style="margin-bottom:8px">
   <button class="btn btn-sm btn-secondary" onclick="loadInfoframes()">Refresh</button>
  </div>
  <div>
   <div style="margin-bottom:10px">
    <div style="font-size:.7rem;color:var(--text2);text-transform:uppercase;margin-bottom:4px">AVI InfoFrame</div>
    <div id="aviIF" class="if-hex">-</div>
    <div id="aviDecoded" class="if-decoded"></div>
   </div>
   <div>
    <div style="font-size:.7rem;color:var(--text2);text-transform:uppercase;margin-bottom:4px">DRM InfoFrame</div>
    <div id="drmIF" class="if-hex">-</div>
    <div id="drmDecoded" class="if-decoded"></div>
   </div>
  </div>
 </div>

 <!-- GPU Memory -->
 <div class="card" data-widget="gpu_memory" draggable="true">
  <h2><span class="drag-handle">&#9776;</span>GPU Memory</h2>
  <div class="info-grid" id="gpuMemInfo" style="margin-bottom:8px"></div>
  <div class="grid">
   <div class="field">
    <label>GPU Memory Allocation</label>
    <select id="gpu_mem">
     <option value="64">64 MB</option>
     <option value="128">128 MB</option>
     <option value="192">192 MB</option>
     <option value="256">256 MB</option>
    </select>
   </div>
  </div>
  <div class="btn-row" style="margin-top:10px">
   <button class="btn btn-sm btn-success" onclick="applyMemory()">Apply &amp; Reboot</button>
  </div>
  <div style="margin-top:6px;font-size:.7rem;color:var(--text2)">Changes require a reboot. Increase if calibration software reports insufficient GPU memory.</div>
 </div>

 <!-- Software Update -->
 <div class="card span2" data-widget="update" draggable="true" id="updateCard">
  <h2><span class="drag-handle">&#9776;</span>Software Update</h2>
  <div id="updateContent">
   <div class="info-grid">
    <div class="info-item"><div class="label">Current</div><div class="value" id="updateCurrent">-</div></div>
    <div class="info-item"><div class="label">Latest</div><div class="value" id="updateLatest">-</div></div>
    <div class="info-item"><div class="label">Published</div><div class="value" id="updatePublished">-</div></div>
   </div>
   <div id="updateChangelog" style="margin-top:8px;font-size:.75rem;color:var(--text2);max-height:80px;overflow-y:auto"></div>
   <div class="btn-row" style="margin-top:10px">
    <button class="btn btn-sm btn-secondary" onclick="checkUpdate()">Check for Updates</button>
    <button class="btn btn-sm btn-success" id="applyUpdateBtn" style="display:none" onclick="applyUpdate()">Install Update</button>
    <button class="btn btn-sm btn-secondary" id="submitLogsBtn" onclick="submitLogs()" title="Download a diagnostic log bundle">&#128230; Submit Logs</button>
   </div>
   <div id="updateStatus" style="margin-top:6px;font-size:.7rem;color:var(--text2)"></div>
  </div>
 </div>

</div>

<div class="toast" id="toast"></div>

<script>
const API=window.location.origin;
let config={};
let modes=[];
let caps=null;

const IFACE_NAMES={
 eth0:'Ethernet',
 usb0:'Ethernet (USB)',
 wlan0:'WiFi',
 ap0:'WiFi AP',
 bnep:'Bluetooth PAN',
 bnep0:'Bluetooth PAN',
};

function toast(msg,err){
 const t=document.getElementById('toast');
 t.textContent=msg;t.className='toast'+(err?' error':'')+' show';
 setTimeout(()=>t.className='toast',3000);
}

let _pingFailCount=0;

async function fetchJSON(url,opts){
 const req=Object.assign({},opts||{});
 const quiet=!!req._quiet;
 const timeoutMs=req._timeoutMs||8000;
 delete req._quiet;
 delete req._timeoutMs;
 let timer=null;
 if(!req.signal){
  const controller=new AbortController();
  req.signal=controller.signal;
  timer=setTimeout(()=>controller.abort(),timeoutMs);
 }
 try{
  const r=await fetch(API+url,req);
  return await r.json();
 }
 catch(e){
  if(!quiet)toast('Connection error','err');
  return null;
 }
 finally{
  if(timer)clearTimeout(timer);
 }
}

async function loadConfig(quiet){
 if(quiet&&shouldPauseAutoRefresh()) return;
 const loadedConfig=await fetchJSON('/api/config',{_quiet:!!quiet,_timeoutMs:10000});
 if(!loadedConfig)return;
 applyConfigState(loadedConfig);
}

function applyConfigState(nextConfig){
 config=nextConfig;
 window._remoteConfigSnapshot=JSON.stringify(nextConfig);
 // Derive signal mode from flags
 let sm='sdr';
 if(config.dv_status==='1'||config.is_ll_dovi==='1'||config.is_std_dovi==='1') sm='dv';
 else if(config.is_hdr==='1'){
  sm=(config.eotf==='3')?'hlg':'hdr10';
 }
 setVal('mode_idx',config.mode_idx||'');
 setVal('signal_mode',sm);
 setVal('max_bpc',config.max_bpc||'8');
 setVal('color_format',config.color_format||'0');
 setVal('colorimetry',config.colorimetry||'0');
 setVal('rgb_quant_range',config.rgb_quant_range||'0');
 setVal('eotf',config.eotf||'0');
 setVal('primaries',config.primaries||'0');
 document.getElementById('max_luma').value=config.max_luma||'1000';
 document.getElementById('min_luma').value=config.min_luma||'0.005';
 document.getElementById('max_cll').value=config.max_cll||'1000';
 document.getElementById('max_fall').value=config.max_fall||'400';
 // DV settings
 setVal('dv_map_mode',config.dv_map_mode||'2');
 if(sm==='dv'){
  setVal('max_bpc','12');
  setVal('color_format','0');
  setVal('colorimetry','9');
  setVal('primaries','1');
  setVal('rgb_quant_range','2');
 }
 updateModeVisibility();
 updateDropdowns();
 refreshSavedSettingsSnapshot();
}

async function syncRemoteConfig(){
 if(shouldPauseAutoRefresh()||window._configSyncBusy) return;
 window._configSyncBusy=true;
 try{
  const remoteConfig=await fetchJSON('/api/config',{_quiet:true,_timeoutMs:10000});
  if(!remoteConfig)return;
  const remoteSnapshot=JSON.stringify(remoteConfig);
  if(!window._remoteConfigSnapshot||remoteSnapshot!==window._remoteConfigSnapshot){
   applyConfigState(remoteConfig);
  }
 }
 finally{
  window._configSyncBusy=false;
 }
}

function setVal(id,v){const el=document.getElementById(id);if(el)el.value=v;}
function getVal(id){const el=document.getElementById(id);return el?el.value:'';}

function captureSettings(){
 return JSON.stringify({
  mode_idx:getVal('mode_idx'),signal_mode:getVal('signal_mode'),
  max_bpc:getVal('max_bpc'),color_format:getVal('color_format'),
  colorimetry:getVal('colorimetry'),rgb_quant_range:getVal('rgb_quant_range'),
  eotf:getVal('eotf'),primaries:getVal('primaries'),
  max_luma:document.getElementById('max_luma').value,
  min_luma:document.getElementById('min_luma').value,
  max_cll:document.getElementById('max_cll').value,
  max_fall:document.getElementById('max_fall').value,
  dv_map_mode:getVal('dv_map_mode')
 });
}

function refreshSavedSettingsSnapshot(){
 window._savedConfig=captureSettings();
 checkSettingsChanged();
}

function hasUnsavedSettings(){
 if(!window._savedConfig)return false;
 return captureSettings()!==window._savedConfig;
}

function isSettingsFieldActive(){
 const el=document.activeElement;
 if(!el||!el.id)return false;
 return ['mode_idx','signal_mode','max_bpc','color_format','colorimetry','rgb_quant_range',
  'eotf','primaries','dv_map_mode','max_luma','min_luma','max_cll','max_fall'].includes(el.id);
}

function shouldPauseAutoRefresh(){
 return isSettingsFieldActive()||hasUnsavedSettings();
}

function checkSettingsChanged(){
 if(!window._savedConfig)return;
 var changed=captureSettings()!==window._savedConfig;
 document.getElementById('applyBar').style.display=changed?'':'none';
}

function updateModeVisibility(){
 const sm=getVal('signal_mode');
 document.getElementById('hdrCard').style.display=(sm==='hdr10'||sm==='hlg')?'':'none';
 document.getElementById('dvCard').style.display=(sm==='dv')?'':'none';
}

['mode_idx','signal_mode','max_bpc','color_format','colorimetry','rgb_quant_range',
 'eotf','primaries','dv_map_mode'].forEach(function(id){
 document.getElementById(id).addEventListener('change',checkSettingsChanged);
});
['max_luma','min_luma','max_cll','max_fall'].forEach(function(id){
 document.getElementById(id).addEventListener('input',checkSettingsChanged);
});
// Re-filter dropdowns when mode, bit depth, or color format changes
['mode_idx','max_bpc','color_format'].forEach(function(id){
 document.getElementById(id).addEventListener('change',updateDropdowns);
});

function applyMeterTargetGammaDefault(){
 const g=document.getElementById('meterTargetGamma');
 const sm=document.getElementById('signal_mode').value;
 const displayType=document.getElementById('meterDisplayType').value;
 if(sm==='dv'){
  g.value='2.2';
  return;
 }
 if(displayType.startsWith('projector')) g.value='2.2';
 else g.value='bt1886';
}

document.getElementById('signal_mode').addEventListener('change',function(){
 const sm=this.value;
 // Set sensible defaults per mode. Users can still adjust the fields after
 // switching modes, but picking the mode should land on a working baseline.
 if(sm==='sdr'){
  setVal('eotf','0');
  setVal('colorimetry','2');
  setVal('max_bpc','8');
 }else if(sm==='hdr10'){
  setVal('eotf','2');
  setVal('colorimetry','9');
  setVal('primaries','1');
  setVal('max_bpc','10');
 }else if(sm==='hlg'){
  setVal('eotf','3');
  setVal('colorimetry','9');
  setVal('primaries','1');
  setVal('max_bpc','10');
 }else if(sm==='dv'){
  setVal('color_format','0');
  setVal('colorimetry','9');
  setVal('primaries','1');
  setVal('max_bpc','12');
  setVal('rgb_quant_range','2');
 }
 applyMeterTargetGammaDefault();
 updateModeVisibility();
 updateDropdowns();
 checkSettingsChanged();
});

async function loadModes(quiet){
 modes=await fetchJSON('/api/modes',{_quiet:!!quiet,_timeoutMs:10000});
 if(!modes)return;
 const sel=document.getElementById('mode_idx');
 sel.innerHTML='';
 modes.forEach(m=>{
  const o=document.createElement('option');
  o.value=m.idx;o.textContent=m.resolution+' @ '+m.refresh+'Hz';
  sel.appendChild(o);
 });
 if(config.mode_idx)sel.value=config.mode_idx;
}

async function loadCapabilities(quiet){
 caps=await fetchJSON('/api/capabilities',{_quiet:!!quiet,_timeoutMs:10000});
}

// Determine which color formats are valid for a given mode + bit depth
function getValidFormats(modeIdx,bpc){
 if(!caps)return [0,1,2,3]; // fallback: all formats
 const mode=modes.find(m=>String(m.idx)===String(modeIdx));
 const clock=mode?mode.clock:148500; // default 1080p60 if unknown
 const maxTmds=caps.max_tmds*1000; // MHz to kHz
 const res=mode?mode.resolution:'1920x1080';
 const hz=mode?Math.round(parseFloat(mode.refresh)):60;
 const vic420Key=res+'@'+hz;
 const has420=caps.vic_420&&caps.vic_420.indexOf(vic420Key)>=0;
 const valid=[];

 // RGB (format 0)
 const rgb_ok=(bpc===8)||(bpc===10&&caps.dc_30bit)||(bpc===12&&caps.dc_36bit);
 if(rgb_ok&&(bpc===8?clock:clock*bpc/8)<=maxTmds) valid.push(0);

 // YCbCr 4:4:4 (format 1)
 const y444_ok=caps.has_ycbcr444&&((bpc===8)||(bpc===10&&caps.dc_30bit&&caps.dc_y444)||(bpc===12&&caps.dc_36bit&&caps.dc_y444));
 if(y444_ok&&(bpc===8?clock:clock*bpc/8)<=maxTmds) valid.push(1);

 // YCbCr 4:2:2 (format 2) — always carries up to 12bpc in 8bpc bandwidth
 if(caps.has_ycbcr422&&clock<=maxTmds) valid.push(2);

 // YCbCr 4:2:0 (format 3) — only for modes in 4:2:0 VIC map
 if(has420){
  const y420_ok=(bpc===8)||(bpc===10&&caps.dc_420_10bit)||(bpc===12&&caps.dc_420_12bit);
  const tmds420=Math.ceil(clock/2*(bpc/8));
  if(y420_ok&&tmds420<=maxTmds) valid.push(3);
 }
 return valid;
}

// Determine which bit depths are valid for a given mode + color format
function getValidBpc(modeIdx,fmt){
 if(!caps)return [8,10,12];
 const mode=modes.find(m=>String(m.idx)===String(modeIdx));
 const clock=mode?mode.clock:148500;
 const maxTmds=caps.max_tmds*1000;
 const res=mode?mode.resolution:'1920x1080';
 const hz=mode?Math.round(parseFloat(mode.refresh)):60;
 const vic420Key=res+'@'+hz;
 const has420=caps.vic_420&&caps.vic_420.indexOf(vic420Key)>=0;
 const valid=[];

 [8,10,12].forEach(function(bpc){
  let ok=false;
  if(fmt===0){ // RGB
   ok=(bpc===8)||(bpc===10&&caps.dc_30bit)||(bpc===12&&caps.dc_36bit);
   if(ok) ok=(bpc===8?clock:clock*bpc/8)<=maxTmds;
  }else if(fmt===1){ // YCbCr 4:4:4
   ok=caps.has_ycbcr444&&((bpc===8)||(bpc===10&&caps.dc_30bit&&caps.dc_y444)||(bpc===12&&caps.dc_36bit&&caps.dc_y444));
   if(ok) ok=(bpc===8?clock:clock*bpc/8)<=maxTmds;
  }else if(fmt===2){ // YCbCr 4:2:2
   ok=caps.has_ycbcr422&&clock<=maxTmds;
  }else if(fmt===3){ // YCbCr 4:2:0
   if(!has420){ok=false;}
   else{
    ok=(bpc===8)||(bpc===10&&caps.dc_420_10bit)||(bpc===12&&caps.dc_420_12bit);
    if(ok) ok=Math.ceil(clock/2*(bpc/8))<=maxTmds;
   }
  }
  if(ok) valid.push(bpc);
 });
 return valid;
}

// Update the dropdowns to only show valid options
function updateDropdowns(){
 if(!caps||!modes.length)return;
 const modeIdx=getVal('mode_idx');
 const curBpc=parseInt(getVal('max_bpc'))||8;
 const curFmt=parseInt(getVal('color_format'))||0;
 const sm=getVal('signal_mode');

 // Signal mode filtering
 const smSel=document.getElementById('signal_mode');
 const smOpts={sdr:true,hdr10:caps.has_hdr_st2084,hlg:caps.has_hdr_hlg,dv:caps.has_dv};
 Array.from(smSel.options).forEach(function(o){o.disabled=!smOpts[o.value];o.style.display=smOpts[o.value]?'':'none';});

 // In DV mode, color format is forced to RGB
 const fmtSel=document.getElementById('color_format');
 const bpcSel=document.getElementById('max_bpc');
 const modeSel=document.getElementById('mode_idx');
 if(sm==='dv'){
  Array.from(fmtSel.options).forEach(function(o){o.disabled=o.value!=='0';o.style.display=o.value==='0'?'':'none';});
  fmtSel.value='0';
  // Dolby Vision RGB tunneling uses a 12-bit HDMI link.
  Array.from(bpcSel.options).forEach(function(o){o.disabled=o.value!=='12';o.style.display=o.value==='12'?'':'none';});
  bpcSel.value='12';
  // DV requires Full range
  const rngSel=document.getElementById('rgb_quant_range');
  Array.from(rngSel.options).forEach(function(o){o.disabled=o.value!=='2';o.style.display=o.value==='2'?'':'none';});
  rngSel.value='2';
  // DV 12-bit RGB tunneling needs clock*1.5 bandwidth — disable modes that exceed TMDS limit
  const maxTmds=caps.max_tmds?caps.max_tmds*1000:600000;
  let curModeValid=false;
  Array.from(modeSel.options).forEach(function(o){
   const m=modes.find(x=>String(x.idx)===o.value);
   const ok=m?(m.clock*1.5<=maxTmds):true;
   o.disabled=!ok;o.style.display=ok?'':'none';
   if(ok&&o.value===modeIdx)curModeValid=true;
  });
  if(!curModeValid){
   const first=Array.from(modeSel.options).find(o=>!o.disabled);
   if(first)modeSel.value=first.value;
  }
  checkSettingsChanged();
  return;
 }
 // Non-DV: re-enable all mode options
 Array.from(modeSel.options).forEach(function(o){o.disabled=false;o.style.display='';});
 // Re-enable all range options
 const rngSel=document.getElementById('rgb_quant_range');
 Array.from(rngSel.options).forEach(function(o){o.disabled=false;o.style.display='';});

 // Color format filtering based on current mode + bpc
 const validFmts=getValidFormats(modeIdx,curBpc);
 Array.from(fmtSel.options).forEach(function(o){
  const v=parseInt(o.value);
  o.disabled=validFmts.indexOf(v)<0;
  o.style.display=validFmts.indexOf(v)>=0?'':'none';
 });
 // If current format is no longer valid, switch to first valid
 if(validFmts.indexOf(curFmt)<0&&validFmts.length>0){
  fmtSel.value=String(validFmts[0]);
 }

 // Bit depth filtering based on current mode + format
 const activeFmt=parseInt(getVal('color_format'))||0;
 const validBpc=getValidBpc(modeIdx,activeFmt);
 Array.from(bpcSel.options).forEach(function(o){
  const v=parseInt(o.value);
  o.disabled=validBpc.indexOf(v)<0;
  o.style.display=validBpc.indexOf(v)>=0?'':'none';
 });
 // If current bpc is no longer valid, switch to first valid
 if(validBpc.indexOf(curBpc)<0&&validBpc.length>0){
  bpcSel.value=String(validBpc[0]);
 }
 checkSettingsChanged();
}

async function checkPing(){
 if(shouldPauseAutoRefresh()) return;
 const t0=performance.now();
 try{
  const r=await fetch(API+'/api/ping',{signal:AbortSignal.timeout(8000)});
  if(!r.ok) throw new Error(r.status);
  await r.json();
  const wasOffline=_pingFailCount>=3;
  _pingFailCount=0;
  if(wasOffline){loadInfo();loadMemory();}
 }catch(e){
  _pingFailCount++;
  if(_pingFailCount<3){
   document.getElementById('statusDot').style.background='var(--orange)';
   document.getElementById('statusText').textContent='Retry';
   document.getElementById('statusWrap').title='Transient timeout';
   return;
  }
  document.getElementById('statusDot').style.background='var(--red)';
  document.getElementById('statusText').textContent='Offline';
  document.getElementById('statusWrap').title='No response';
  return;
 }
 const latency=Math.round(performance.now()-t0);
 var col='#4caf50';
 if(latency>500)col='var(--red)'; else if(latency>200)col='var(--orange)'; else if(latency>100)col='#ffeb3b';
 document.getElementById('statusDot').style.background=col;
 document.getElementById('statusText').textContent=latency+'ms';
 document.getElementById('statusWrap').title='Response time: '+latency+'ms';
}

async function loadInfo(quiet){
 if(quiet&&shouldPauseAutoRefresh()) return;
 const info=await fetchJSON('/api/info',{_quiet:!!quiet,_timeoutMs:10000});
 if(!info) return;
 document.getElementById('tempDisplay').textContent=info.temperature?info.temperature+'\u00B0C':'';
 if(info.version){
  document.getElementById('verDisplay').textContent='v'+info.version;
  document.getElementById('updateCurrent').textContent='v'+info.version;
 }
 const g=document.getElementById('infoGrid');
 g.innerHTML='';
 addInfo(g,'Hostname',info.hostname);
 addInfo(g,'Resolution',info.resolution);
 addInfo(g,'Uptime',formatUptime(info.uptime));
 addInfo(g,'Temp',info.temperature+'\u00B0C');
 if(info.total_ram) addInfo(g,'RAM',info.total_ram+'MB');
 if(info.gpu_mem) addInfo(g,'GPU Mem',info.gpu_mem);
 // Update GPU Memory card readout
 if(info.gpu_mem){
  const gi=document.getElementById('gpuMemInfo');
  if(gi){gi.innerHTML='';addInfo(gi,'Current',info.gpu_mem);}
 }
 if(info.interfaces){
  Object.entries(info.interfaces).forEach(([iface,ip])=>{
   const name=IFACE_NAMES[iface]||iface;
   addInfo(g,name,ip);
  });
 }
 const wifiDisconnectBtn=document.getElementById('wifiDisconnectBtn');
 if(info.wifi && info.wifi.state==='COMPLETED' && info.wifi.ssid){
  const ws=document.getElementById('wifiStatus');
  ws.innerHTML='';
  addInfo(ws,'Network',info.wifi.ssid);
  if(info.wifi.band) addInfo(ws,'Band',info.wifi.band+' ('+info.wifi.freq+' MHz)');
  if(info.wifi.signal) addInfo(ws,'Signal',info.wifi.signal+' dBm');
  if(wifiDisconnectBtn) wifiDisconnectBtn.style.display='';
  const wifiForgetBtn=document.getElementById('wifiForgetBtn');
  if(wifiForgetBtn) wifiForgetBtn.style.display='';
 }else{
  const ws=document.getElementById('wifiStatus');
  ws.innerHTML='<div style="font-size:.8rem;color:var(--text2)">Not connected</div>';
  if(wifiDisconnectBtn) wifiDisconnectBtn.style.display='none';
  const wifiForgetBtn=document.getElementById('wifiForgetBtn');
  if(wifiForgetBtn) wifiForgetBtn.style.display='none';
 }
 // Update top-bar calibration indicator
 const calWrap=document.getElementById('calStatusWrap');
 const calDot=document.getElementById('calDot');
 const calText=document.getElementById('calStatusText');
 if(info.calibration && info.calibration.connected){
  calDot.style.background='#4caf50';
  calText.style.color='';
  calText.textContent=info.calibration.software||'Connected';
  calWrap.title=(info.calibration.software||'Calibration')+' ('+info.calibration.ip+')';
 }else{
  calDot.style.background='var(--text2)';
  calText.style.color='var(--text2)';
  calText.textContent='No SW';
  calWrap.title='No calibration software connected';
 }
 // Update Resolve card status
 const rBadge=document.getElementById('resolveStatusBadge');
 const rConn=document.getElementById('resolveConnectBtn');
 const rDisc=document.getElementById('resolveDisconnectBtn');
 if(rBadge){
  const isResolve=info.calibration&&info.calibration.connected&&info.calibration.software==='Resolve';
  if(isResolve){
   rBadge.textContent='Connected ('+info.calibration.ip+')';
   rBadge.style.background='var(--green)';
   rConn.style.display='none';
   rDisc.style.display='';
  }else{
   rBadge.textContent='Disconnected';
   rBadge.style.background='var(--text2)';
   rConn.style.display='';
   rDisc.style.display='none';
  }
 }
 // HDMI port check
 if(info.hdmi_port) updateHdmiPortWarning(info.hdmi_port);
}

let _hdmiIgnored=false;
function updateHdmiPortWarning(hp){
 const overlay=document.getElementById('hdmiOverlay');
 const badge=document.getElementById('hdmiWarnBadge');
 const prefSpan=document.getElementById('hdmiPreferred');
 if(prefSpan) prefSpan.textContent=hp.preferred;
 if(hp.wrong_port){
  badge.style.display='inline';
  if(!_hdmiIgnored) overlay.classList.add('active');
 }else{
  badge.style.display='none';
  overlay.classList.remove('active');
 }
}
function hdmiIgnore(){
 _hdmiIgnored=true;
 document.getElementById('hdmiOverlay').classList.remove('active');
}
async function hdmiRecheck(){
 const btn=document.getElementById('hdmiRecheckBtn');
 btn.disabled=true;btn.textContent='Checking\u2026';
 let ok=false;
 for(let i=0;i<20;i++){
  try{
   const info=await fetchJSON('/api/info',{_timeoutMs:5000});
   if(info&&info.hdmi_port){
    if(!info.hdmi_port.wrong_port){
     btn.textContent='Restarting display\u2026';
     // Restart pattern generator so it re-targets the correct connector
     await fetchJSON('/api/restart',{_timeoutMs:10000}).catch(function(){});
     _hdmiIgnored=false;
     document.getElementById('hdmiOverlay').classList.remove('active');
     document.getElementById('hdmiWarnBadge').style.display='none';
     toast('Correct port detected \u2014 display restarted');loadInfo();ok=true;break;
    }else{
     toast('Still on wrong port \u2014 please switch to '+info.hdmi_port.preferred,'error');
     ok=true;break;
    }
   }
  }catch(e){}
  await new Promise(r=>setTimeout(r,2000));
 }
 btn.disabled=false;btn.textContent="I've switched \u2014 Recheck";
 if(!ok) toast('Could not reconnect \u2014 try refreshing the page','error');
}
function hdmiShowOverlay(){
 _hdmiIgnored=false;
 document.getElementById('hdmiOverlay').classList.add('active');
}

function statToneClass(pct){
 pct=Number(pct)||0;
 if(pct>=90)return' bad';
 if(pct>=75)return' hot';
 if(pct>=60)return' warn';
 return'';
}
function setMeter(id,pct){
 const el=document.getElementById(id);
 if(el)el.style.width=Math.max(0,Math.min(100,Number(pct)||0))+'%';
}
async function loadStats(quiet){
 const stats=await fetchJSON('/api/stats',{_quiet:!!quiet,_timeoutMs:5000});
 if(!stats)return;
 const cpuPct=Number(stats.cpu_percent),memPct=Number(stats.memory_percent);
 const cpuVal=document.getElementById('cpuUsageValue');
 const memVal=document.getElementById('memUsageValue');
 if(cpuVal){
  cpuVal.className='stat-value'+statToneClass(cpuPct);
  cpuVal.textContent=isNaN(cpuPct)?'--%':cpuPct+'%';
 }
 if(memVal){
  memVal.className='stat-value'+statToneClass(memPct);
  memVal.textContent=isNaN(memPct)?'--%':memPct+'%';
 }
 setMeter('cpuUsageBar',cpuPct);
 setMeter('memUsageBar',memPct);
 const cpuBits=[];
 if(stats.cpu_freq_mhz)cpuBits.push(stats.cpu_freq_mhz+' MHz');
 if(stats.load_1)cpuBits.push('LA '+stats.load_1);
 document.getElementById('cpuUsageSub').textContent=cpuBits.join(' • ')||'--';
 let memText='--';
 if(stats.memory_total_mb){
  memText=stats.memory_used_mb+' / '+stats.memory_total_mb+' MB';
  if(stats.memory_available_mb)memText+=' • Avail '+stats.memory_available_mb+' MB';
 }
 document.getElementById('memUsageSub').textContent=memText;
}
function addInfo(g,label,value){
 const d=document.createElement('div');d.className='info-item';
 const l=document.createElement('div');l.className='label';l.textContent=label;
 const v=document.createElement('div');v.className='value';v.textContent=value==null?'':String(value);v.title=v.textContent;
 d.appendChild(l);d.appendChild(v);
 g.appendChild(d);
}
function formatUptime(s){
 s=parseFloat(s);if(isNaN(s))return'?';
 const d=Math.floor(s/86400),h=Math.floor((s%86400)/3600),m=Math.floor((s%3600)/60);
 return(d?d+'d ':'')+(h?h+'h ':'')+(m?m+'m':'<1m');
}

const DIAG_DESCRIPTIONS={
 white_clipping:'<b>White Clipping (Contrast)</b> &mdash; Labeled near-white bars from 232 to 255 on a reference-white field. Set HDMI output to RGB, then lower Contrast/White Level until the 236+ bars separate cleanly and 255 is not clipped into the background.',
 black_clipping:'<b>Black Clipping / PLUGE (Brightness)</b> &mdash; Labeled near-black bars from 2 to 25 on black. Set HDMI output to RGB, then raise Brightness until the first few bars above black become barely visible without turning the whole background gray.',
 color_bars:'<b>Color Bars</b> &mdash; 75% Rec.709 bars with a mid reference strip and a bottom PLUGE/white section for quick color and level checks. Use this pattern with HDMI output set to RGB.',
 gray_ramp:'<b>Gray Ramp</b> &mdash; Smooth black-to-white ramp across the top with 11 stepped gray bars underneath. Use HDMI RGB output and check for smooth transitions, neutral grayscale, and no banding.',
 overscan:'<b>Overscan</b> &mdash; Border lines at 0%, 2.5%, and 5% from screen edges with corner L-brackets and center crosshair. Use HDMI RGB output, and all lines should be visible &mdash; if not, disable overscan in your TV settings.',
};
let activePattern=null;
function clearActive(){document.querySelectorAll('.pat-btn').forEach(b=>b.classList.remove('active'));activePattern=null;}
function updateDiagInfo(name){
 const el=document.getElementById('diagInfo');
 if(el&&DIAG_DESCRIPTIONS[name]){el.innerHTML=DIAG_DESCRIPTIONS[name];el.style.display='';}
 else if(el){el.style.display='none';}
}
async function showPattern(name,ev){
 if(activePattern===name){stopPattern();return;}
 clearActive();
 if(ev&&ev.currentTarget)ev.currentTarget.classList.add('active');
 activePattern=name;
 updateDiagInfo(name);
 const r=await fetchJSON('/api/pattern',{method:'POST',headers:{'Content-Type':'application/json'},
  body:JSON.stringify({name:name,signal_mode:getVal('signal_mode'),
   max_luma:document.getElementById('max_luma').value})});
 if(r&&r.status==='ok') toast('Pattern: '+name.replace(/_/g,' '));
 else toast(r?r.message:'Pattern error',true);
}
async function showPatch(id,pr,pg,pb,ev){
 // Greyscale/color/saturation patches are now driven by the Meter & Measurements
 // series readings card. This stub remains only so any legacy handler is a no-op.
 if(ev&&ev.currentTarget)ev.currentTarget.classList.remove('active');
}
async function stopPattern(){
 clearActive();
 var di=document.getElementById('diagInfo');if(di)di.style.display='none';
 const r=await fetchJSON('/api/pattern',{method:'POST',headers:{'Content-Type':'application/json'},
  body:JSON.stringify({name:'stop'})});
 if(r&&r.status==='ok') toast('Pattern stopped');
}
function toggleSection(el){el.parentElement.classList.toggle('collapsed');}
function getPatternTargetMax(){
 const sm=getVal('signal_mode');
 if(sm==='dv')return 255;
 const bits=parseInt(getVal('max_bpc')||'8',10);
 if(bits>=12)return 4095;
 if(bits>=10)return 1023;
 return 255;
}
function isPqStimulusMode(){
 const sm=getVal('signal_mode');
 return sm==='hdr10'||sm==='dv';
}
function clampNum(v,min,max){
 v=parseFloat(v);
 if(isNaN(v))v=min;
 if(v<min)return min;
 if(v>max)return max;
 return v;
}
function pqEncodeNormalized(nits){
 const l=clampNum(nits,0,10000)/10000;
 if(l<=0)return 0;
 const m1=2610/16384,m2=2523/32,c1=3424/4096,c2=2413/128,c3=2392/128;
 const p=Math.pow(l,m1);
 return Math.pow((c1+c2*p)/(1+c3*p),m2);
}
function getPatternPeakCode(){
 const maxCode=getPatternTargetMax();
 if(isPqStimulusMode()){
  const peak=clampNum(document.getElementById('max_luma').value||1000,0,10000);
  return Math.round(pqEncodeNormalized(peak)*maxCode);
 }
 return maxCode;
}
function stimulusPercentToCode(percent){
 const pct=clampNum(percent,0,100);
 return Math.round(getPatternPeakCode()*pct/100);
}
function buildCalPatterns(){
 // Greyscale, Color Checker and Saturation Sweep grids were removed from the
 // Test Patterns card — those series are now driven exclusively by the Meter
 // & Measurements card. Kept as a no-op so the init call at module load works.
}
buildCalPatterns();

function resetDefaults(){
 setVal('signal_mode','sdr');
 setVal('max_bpc','8');
 setVal('color_format','0');
 setVal('colorimetry','2');
 setVal('rgb_quant_range','2');
 setVal('eotf','0');
 setVal('primaries','0');
 document.getElementById('max_luma').value='1000';
 document.getElementById('min_luma').value='0.005';
 document.getElementById('max_cll').value='1000';
 document.getElementById('max_fall').value='400';
 setVal('dv_map_mode','2');
 updateModeVisibility();
 updateDropdowns();
 checkSettingsChanged();
 toast('Defaults loaded \u2014 click Apply to save and restart');
}

async function applySettings(){
 const sm=getVal('signal_mode');
 const changes={
  mode_idx:getVal('mode_idx'),
  max_bpc:getVal('max_bpc'),
  color_format:getVal('color_format'),
  colorimetry:getVal('colorimetry'),
  rgb_quant_range:getVal('rgb_quant_range'),
 };
 if(sm==='sdr'){
  Object.assign(changes,{is_sdr:'1',is_hdr:'0',eotf:'0',
   is_ll_dovi:'0',is_std_dovi:'0',dv_status:'0',dv_metadata:'0'});
 }else if(sm==='hdr10'||sm==='hlg'){
  Object.assign(changes,{is_sdr:'0',is_hdr:'1',
   is_ll_dovi:'0',is_std_dovi:'0',dv_status:'0',dv_metadata:'0',
   eotf:getVal('eotf'),primaries:getVal('primaries'),
   max_luma:document.getElementById('max_luma').value,
   min_luma:document.getElementById('min_luma').value,
   max_cll:document.getElementById('max_cll').value,
   max_fall:document.getElementById('max_fall').value});
 }else if(sm==='dv'){
  Object.assign(changes,{is_sdr:'0',is_hdr:'1',
   is_ll_dovi:'1',is_std_dovi:'1',
   dv_status:'1',primaries:'1',color_format:'0',colorimetry:'9',max_bpc:'12',
   rgb_quant_range:'2',
   dv_interface:getVal('dv_interface'),
   dv_map_mode:getVal('dv_map_mode'),
   dv_metadata:getVal('dv_map_mode')==='1'?'3':'2'});
 }
 clearActive();
 var di=document.getElementById('diagInfo');if(di)di.style.display='none';
 const r=await fetchJSON('/api/config',{method:'POST',
  headers:{'Content-Type':'application/json'},body:JSON.stringify(changes)});
 if(r&&r.status==='ok'){
  toast('Applying settings...');
  document.getElementById('applyBar').style.display='none';
  setTimeout(()=>{loadConfig().then(()=>updateDropdowns());loadInfo();toast('Settings applied');},3000);
 }else toast(r&&r.message?r.message:'Failed to apply','err');
}

async function rebootDevice(){
 toast('Rebooting device...');
 await fetchJSON('/api/reboot',{method:'POST'});
}

async function loadMemory(){
 const m=await fetchJSON('/api/boot/memory',{_quiet:true});
 if(!m)return;
 setVal('gpu_mem',m.gpu_mem||'64');
 const g=document.getElementById('gpuMemInfo');
 if(g){
  g.innerHTML='';
  addInfo(g,'Current',m.gpu_mem+'MB');
 }
}

async function applyMemory(){
 const gpu=getVal('gpu_mem');
 if(!confirm('Set GPU memory to '+gpu+'MB and reboot?'))return;
 const r=await fetchJSON('/api/boot/memory',{method:'POST',
  headers:{'Content-Type':'application/json'},body:JSON.stringify({gpu_mem:gpu})});
 if(r&&r.status==='ok') toast(r.message);
 else toast(r&&r.message?r.message:'Failed to apply','err');
}

async function scanWifi(){
 document.getElementById('wifiList').innerHTML='<div class="spinner"></div> Scanning...';
 const nets=await fetchJSON('/api/wifi/scan');
 const list=document.getElementById('wifiList');
 if(!nets||!nets.length){list.innerHTML='<div style="color:var(--text2)">No networks found</div>';return;}
 list.innerHTML='';
 const seen={};
 nets.filter(n=>{if(seen[n.ssid])return false;seen[n.ssid]=1;return true;})
 .sort((a,b)=>b.signal-a.signal)
 .forEach(n=>{
  const d=document.createElement('div');d.className='wifi-item';
  d.innerHTML='<div><div class="name">'+n.ssid+'</div><div class="meta">'+n.security+'</div></div><div class="meta">'+n.signal+' dBm</div>';
  d.onclick=()=>showWifiForm(n.ssid,n.security);
  list.appendChild(d);
 });
}

function showWifiForm(ssid,sec){
 document.getElementById('wifiSsid').value=ssid;
 document.getElementById('wifiPsk').value='';
 document.getElementById('wifiConnect').className='';
 document.getElementById('wifiPsk').placeholder=sec==='Open'?'No password needed':'Enter password';
}
function hideWifiForm(){document.getElementById('wifiConnect').className='hidden';}

async function connectWifi(){
 const ssid=document.getElementById('wifiSsid').value;
 const psk=document.getElementById('wifiPsk').value;
 const btn=event.target;btn.disabled=true;btn.textContent='Connecting...';
 const r=await fetchJSON('/api/wifi/connect',{method:'POST',
  headers:{'Content-Type':'application/json'},body:JSON.stringify({ssid,psk})});
 if(r&&r.status==='ok'){
  toast('Connecting to '+ssid+'...');
  hideWifiForm();
  // Poll wifi status for up to 15 seconds
  let attempts=0;
  const poll=setInterval(async()=>{
   attempts++;
   const ws=await fetchJSON('/api/wifi/status');
   if(ws&&ws.wpa_state==='COMPLETED'&&ws.ssid===ssid){
    clearInterval(poll);
    const bandInfo=ws.band?' on '+ws.band:'';
    const sigInfo=ws.signal?' ('+ws.signal+' dBm)':'';
    toast('Connected to '+ssid+bandInfo+sigInfo);
    loadInfo();
   }else if(attempts>=10){
    clearInterval(poll);
    if(ws&&ws.wpa_state==='COMPLETED') toast('Connected to '+ws.ssid);
    else toast('Connection to '+ssid+' may have failed — check status','err');
    loadInfo();
   }
  },1500);
 }else toast('Connection failed','err');
 btn.disabled=false;btn.textContent='Connect';
}

async function disconnectWifi(){
 const btn=document.getElementById('wifiDisconnectBtn');
 if(btn) btn.disabled=true;
 if(!window.confirm('Disconnect the current WiFi client connection?')){
  if(btn) btn.disabled=false;
  return;
 }
 const r=await fetchJSON('/api/wifi/disconnect',{method:'POST'});
 if(r&&r.status==='ok'){
  toast('Disconnecting WiFi...');
  hideWifiForm();
  setTimeout(()=>{loadInfo();if(btn) btn.disabled=false;},1500);
 }else{
  toast('WiFi disconnect failed','err');
  if(btn) btn.disabled=false;
 }
}
async function forgetWifi(){
 const btn=document.getElementById('wifiForgetBtn');
 if(btn) btn.disabled=true;
 if(!window.confirm('Forget WiFi network? Stored credentials will be deleted and WiFi will not reconnect on reboot.')){
  if(btn) btn.disabled=false;
  return;
 }
 const r=await fetchJSON('/api/wifi/forget',{method:'POST'});
 if(r&&r.status==='ok'){
  toast('WiFi network forgotten');
  hideWifiForm();
  setTimeout(()=>{loadInfo();if(btn) btn.disabled=false;},1500);
 }else{
  toast('WiFi forget failed','err');
  if(btn) btn.disabled=false;
 }
}

async function cecCmd(cmd){
 const r=await fetchJSON('/api/cec/'+cmd);
 if(r){
  if(r.status==='ok') toast('CEC: '+cmd+' OK');
  else toast('CEC: '+(r.message||r.output||'error'),'err');
  const delay=(cmd==='on')?2500:500;
  setTimeout(loadCecStatus,delay);
 }
}

async function cecScan(){
 const el=document.getElementById('cecDeviceList');
 el.innerHTML='Scanning... (may take 15-30s)';
 const r=await fetchJSON('/api/cec/scan');
 if(r&&r.status==='ok'&&r.data&&r.data.devices){
  const devs=r.data.devices;
  if(devs.length===0){el.innerHTML='No devices found';return;}
  const typeNames={0:'TV',1:'Recording',3:'Tuner',4:'Playback',5:'Audio System'};
  const pwrNames={0:'On',1:'Standby',2:'Powering On',3:'Powering Off'};
  let html='<table style="width:100%;border-collapse:collapse;font-size:.8rem">';
  html+='<tr style="border-bottom:1px solid var(--border)"><th style="text-align:left;padding:2px 6px">Device</th><th style="text-align:left;padding:2px 6px">Type</th><th style="text-align:left;padding:2px 6px">Address</th><th style="text-align:left;padding:2px 6px">Power</th></tr>';
  devs.forEach(d=>{
   const name=d.name||('Device '+d.addr);
   const type=typeNames[d.type]||(d.type!==undefined?'Type '+d.type:'');
   const pwr=pwrNames[d.power]||(d.power!==undefined?''+d.power:'?');
   const pwrColor=d.power===0?'#4caf50':d.power===1?'var(--orange)':'var(--text2)';
   html+='<tr style="border-bottom:1px solid var(--border)">';
   html+='<td style="padding:2px 6px">'+name+'</td>';
   html+='<td style="padding:2px 6px">'+type+'</td>';
   html+='<td style="padding:2px 6px">'+(d.phys||'')+'</td>';
   html+='<td style="padding:2px 6px;color:'+pwrColor+'">'+pwr+'</td>';
   html+='</tr>';
  });
  html+='</table>';
  html+='<div style="margin-top:4px;color:var(--text2)">PGenerator: '+r.data.self.phys+' (logical '+r.data.self.log+')</div>';
  el.innerHTML=html;
 }else{
  el.innerHTML='Scan failed: '+(r&&r.message?r.message:'unknown error');
 }
}

async function loadCecStatus(){
 const r=await fetchJSON('/api/cec/status',{_quiet:true,_timeoutMs:8000});
 const el=document.getElementById('cecStatus');
 if(r&&r.status==='ok'){
  const pwr=r.tv_power||'unknown';
  const pwrColors={on:'#4caf50',standby:'var(--orange)','powering-on':'var(--orange)','powering-off':'var(--orange)',unknown:'var(--text2)'};
  const pwrLabels={on:'On',standby:'Standby','powering-on':'Waking Up','powering-off':'Going to Standby',unknown:'Unknown'};
  const c=pwrColors[pwr]||'var(--text2)';
  const lbl=pwrLabels[pwr]||pwr;
  let html='TV: <span style="color:'+c+';font-weight:600">'+lbl+'</span>';
  if(r.phys_addr) html+=' &bull; HDMI '+r.phys_addr;
  el.innerHTML=html;
 }else{
  const msg=(r&&r.message)?r.message:'Not available';
  el.innerHTML='CEC: '+msg;
  el.style.color='var(--text2)';
 }
}

async function loadAP(){
 const r=await fetchJSON('/api/wifi/ap',{_quiet:true,_timeoutMs:10000});
 if(r&&r.status==='ok'){
  document.getElementById('apSsid').value=r.ssid||'';
  document.getElementById('apPass').value=r.password||'';
 }
}

async function applyAP(){
 const ssid=document.getElementById('apSsid').value.trim();
 const password=document.getElementById('apPass').value;
 if(!ssid){toast('SSID is required','err');return;}
 if(password.length<8){toast('Password must be at least 8 characters','err');return;}
 const r=await fetchJSON('/api/wifi/ap',{method:'POST',
  headers:{'Content-Type':'application/json'},body:JSON.stringify({ssid,password})});
 if(r&&r.status==='ok') toast('AP settings saved — reconnect to new SSID');
 else toast(r&&r.error?r.error:'AP apply failed','err');
}

async function resolveConnect(){
 const ip=document.getElementById('resolveIp').value.trim();
 const port=parseInt(document.getElementById('resolvePort').value)||20002;
 if(!ip||!/^\d+\.\d+\.\d+\.\d+$/.test(ip)){toast('Enter a valid IP address','err');return;}
 const r=await fetchJSON('/api/resolve/connect',{method:'POST',
  headers:{'Content-Type':'application/json'},body:JSON.stringify({ip,port})});
 if(r&&r.status==='ok'){toast('Connecting to '+ip+':'+port+'...');setTimeout(loadInfo,2000);}
 else toast(r&&r.message?r.message:'Connect failed','err');
}
async function resolveDisconnect(){
 const r=await fetchJSON('/api/resolve/disconnect',{method:'POST'});
 if(r&&r.status==='ok'){toast('Disconnected');setTimeout(loadInfo,500);}
 else toast('Disconnect failed','err');
}

async function loadInfoframes(){
 const r=await fetchJSON('/api/infoframes',{_quiet:true,_timeoutMs:10000});
 if(!r||r.status!=='ok') return;
 const ae=document.getElementById('aviIF');
 const ad=document.getElementById('aviDecoded');
 const de=document.getElementById('drmIF');
 const dd=document.getElementById('drmDecoded');
 /* AVI InfoFrame */
 if(r.avi){
  ae.textContent=r.avi;
  const b=r.avi.split(':').map(x=>parseInt(x,16));
  if(b.length>=5){
   const y=(b[4]>>5)&3;const yName=['RGB','YCbCr 4:2:2','YCbCr 4:4:4','YCbCr 4:2:0'][y]||'?';
   const q=(b[6]>>2)&3;const qName=['Default','Limited','Full','Reserved'][q]||'?';
   const c=(b[5]>>6)&3;const cName=['None','SMPTE 170M','BT.709','Extended'][c]||'?';
   const vic=b[7]&0x7f;
   let lines=['Color: '+yName,'Quant: '+qName,'Colorimetry: '+cName,'VIC: '+vic];
   if(c===3&&b.length>=7){
    const ec=b[6]&0x70;const ecName={0:'xvYCC 601',0x10:'xvYCC 709',0x20:'sYCC',
     0x30:'opYCC',0x40:'opRGB',0x50:'BT.2020 cYCC',0x60:'BT.2020 YCC/RGB',0x70:'Reserved'}[ec]||'?';
    lines[2]='Colorimetry: '+ecName;
   }
   ad.innerHTML=lines.join('<br>');
  }
 }else{ae.textContent='-';ad.innerHTML='';}
 /* DRM InfoFrame */
 if(r.drm){
  de.textContent=r.drm;
  const b=r.drm.split(':').map(x=>parseInt(x,16));
  if(b.length>=6){
   const eotf=b[4];const eotfName=['SDR','HDR (traditional)','PQ (ST 2084)','HLG'][eotf]||'Unknown ('+eotf+')';
   let lines=['EOTF: '+eotfName];
   if(b.length>=26){
    const u16=(l,h)=>l|(h<<8);
    const maxLum=u16(b[22],b[23]);
    const minLum=u16(b[24],b[25]);
    lines.push('Max Lum: '+maxLum+' cd/m²');
    lines.push('Min Lum: '+(minLum/10000).toFixed(4)+' cd/m²');
    if(b.length>=30){
     const maxCLL=u16(b[26],b[27]);
     const maxFALL=u16(b[28],b[29]);
     lines.push('Max CLL: '+maxCLL+' cd/m²');
     lines.push('Max FALL: '+maxFALL+' cd/m²');
    }
   }
   dd.innerHTML=lines.join('<br>');
  }
 }else{de.textContent='-';dd.innerHTML='';}
}

// Widget drag-and-drop reordering
(function(){
 const dash=document.querySelector('.dashboard');
 const widgets=()=>[...dash.querySelectorAll('[data-widget]')];
 let dragEl=null;
 function saveOrder(){
  const order=widgets().map(w=>w.dataset.widget);
  localStorage.setItem('pg_widget_order',JSON.stringify(order));
 }
 function restoreOrder(){
  try{
   const order=JSON.parse(localStorage.getItem('pg_widget_order'));
   if(!order||!Array.isArray(order))return;
   const map={};widgets().forEach(w=>{map[w.dataset.widget]=w;});
   const end=dash.querySelector('.toast')||null;
   order.forEach(id=>{if(map[id])dash.insertBefore(map[id],end);});
  }catch(e){}
 }
 dash.addEventListener('dragstart',e=>{
  const w=e.target.closest('[data-widget]');
  if(!w)return;
  dragEl=w;w.classList.add('dragging');
  e.dataTransfer.effectAllowed='move';
  e.dataTransfer.setData('text/plain',w.dataset.widget);
 });
 dash.addEventListener('dragend',e=>{
  if(dragEl)dragEl.classList.remove('dragging');
  widgets().forEach(w=>w.classList.remove('drag-over'));
  dragEl=null;
 });
 dash.addEventListener('dragover',e=>{
  e.preventDefault();e.dataTransfer.dropEffect='move';
  const w=e.target.closest('[data-widget]');
  widgets().forEach(c=>c.classList.remove('drag-over'));
  if(w&&w!==dragEl)w.classList.add('drag-over');
 });
 dash.addEventListener('drop',e=>{
  e.preventDefault();
  const target=e.target.closest('[data-widget]');
  if(!target||!dragEl||target===dragEl)return;
  const all=widgets();
  const di=all.indexOf(dragEl),ti=all.indexOf(target);
  if(di<ti)target.after(dragEl);else target.before(dragEl);
  saveOrder();
 });
 restoreOrder();
})();

async function checkUpdate(){
 _updateChecked=true;
 document.getElementById('updateStatus').textContent='Checking...';
 const r=await fetchJSON('/api/update/check',{_quiet:true,_timeoutMs:15000});
 if(!r||r.status==='error'){
  document.getElementById('updateStatus').textContent=r?r.message:'Check failed — no internet?';
  return;
 }
 document.getElementById('updateCurrent').textContent='v'+r.current;
 document.getElementById('updateLatest').textContent='v'+r.latest;
 document.getElementById('updatePublished').textContent=r.published?r.published.split('T')[0]:'-';
 if(r.changelog){
  document.getElementById('updateChangelog').textContent=r.changelog;
 }
 if(r.update_available){
  document.getElementById('applyUpdateBtn').style.display='';
  document.getElementById('updateBtn').style.display='';
  document.getElementById('updateBtn').classList.add('update-pulse');
  document.getElementById('updateStatus').textContent='A new version is available.';
 } else {
  document.getElementById('applyUpdateBtn').style.display='none';
  document.getElementById('updateBtn').style.display='none';
  document.getElementById('updateStatus').textContent='You are running the latest version.';
 }
}
let _updateChecked=false;
function showUpdateCard(){
 document.getElementById('updateCard').style.display='';
 document.getElementById('updateCard').scrollIntoView({behavior:'smooth'});
 if(!_updateChecked) checkUpdate();
}
async function applyUpdate(){
 if(!confirm('Install update now? PGenerator will restart.'))return;
 document.getElementById('applyUpdateBtn').disabled=true;
 document.getElementById('updateStatus').innerHTML='<span class="spinner"></span> Downloading and installing...';
 const r=await fetchJSON('/api/update/apply',{method:'POST'});
 if(r&&r.status==='ok'){
  document.getElementById('updateStatus').textContent='Update started. The page will reload when PGenerator restarts...';
  setTimeout(()=>location.reload(),30000);
  let checks=0;
  const poll=setInterval(async()=>{
   checks++;
   try{const p=await fetch(API+'/api/ping',{signal:AbortSignal.timeout(3000)});if(p.ok){clearInterval(poll);location.reload();}}catch(e){}
   if(checks>60)clearInterval(poll);
  },5000);
 } else {
  document.getElementById('updateStatus').textContent=r?r.message:'Update failed';
  document.getElementById('applyUpdateBtn').disabled=false;
 }
}
async function submitLogs(){
 const btn=document.getElementById('submitLogsBtn');
 btn.disabled=true;btn.textContent='Collecting...';
 try{
  const res=await fetch('/api/submit_logs',{method:'POST'});
  if(res.ok){
   const blob=await res.blob();
   const cd=res.headers.get('Content-Disposition')||'';
   const m=cd.match(/filename="([^"]+)"/);
   const fname=m?m[1]:'PGenerator_diag.txt';
   const a=document.createElement('a');
   a.href=URL.createObjectURL(blob);
   a.download=fname;
   document.body.appendChild(a);a.click();a.remove();
   URL.revokeObjectURL(a.href);
   toast('Diagnostic report downloaded');
  }else{
   const j=await res.json().catch(()=>null);
   toast(j?j.message:'Failed to collect logs','error');
  }
 }catch(e){toast('Error: '+e.message,'error');}
 btn.disabled=false;btn.innerHTML='&#128230; Submit Logs';
}

///////////////////////////////////////////////
//        Meter & Measurements JS            //
///////////////////////////////////////////////
let meterDetected=false;
let meterContinuousActive=false;
let meterContinuousTimer=null;
let meterSeriesPolling=null;
let meterReadings=[];
let meterWhiteReading=null;
let meterLastChartCount=0; // track reading count to skip redundant chart redraws
let meterSeriesCache={};

// D65 reference white chromaticity
const D65={x:0.3127,y:0.3290,X:0.9505,Y:1.0,Z:1.0890};

const GAMUT_PRESETS={
 bt709:{
  label:'BT.709 / D65',
  primaries:{R:{x:0.64,y:0.33},G:{x:0.30,y:0.60},B:{x:0.15,y:0.06}},
  xyzToRgb:[
   [3.2406,-1.5372,-0.4986],
   [-0.9689,1.8758,0.0415],
   [0.0557,-0.2040,1.0570]
  ],
  rgbToXyz:[
   [0.4124564,0.3575761,0.1804375],
   [0.2126729,0.7151522,0.0721750],
   [0.0193339,0.1191920,0.9503041]
  ]
 },
 bt2020:{
  label:'BT.2020 / D65',
  primaries:{R:{x:0.708,y:0.292},G:{x:0.170,y:0.797},B:{x:0.131,y:0.046}},
  xyzToRgb:[
   [1.7166511880,-0.3556707838,-0.2533662814],
   [-0.6666843518,1.6164812366,0.0157685458],
   [0.0176398574,-0.0427706133,0.9421031212]
  ],
  rgbToXyz:[
   [0.6369580483,0.1446169036,0.1688809752],
   [0.2627002120,0.6779980715,0.0593017165],
   [0.0000000000,0.0280726930,1.0609850577]
  ]
 },
 p3d65:{
  label:'P3 / D65',
  primaries:{R:{x:0.680,y:0.320},G:{x:0.265,y:0.690},B:{x:0.150,y:0.060}},
  xyzToRgb:[
   [2.4934969119,-0.9313836179,-0.4027107845],
   [-0.8294889696,1.7626640603,0.0236246858],
   [0.0358458302,-0.0761723893,0.9568845240]
  ],
  rgbToXyz:[
   [0.4865709486,0.2656676932,0.1982172852],
   [0.2289745641,0.6917385218,0.0792869141],
   [0.0000000000,0.0451133819,1.0439443689]
  ]
 }
};

const M_XYZ_TO_RGB=GAMUT_PRESETS.bt709.xyzToRgb;
const M_RGB_TO_XYZ=GAMUT_PRESETS.bt709.rgbToXyz;

function meterContainerGamutKey(){
 const prim=parseInt((config&&config.primaries)||'0',10);
 if(prim===2) return 'p3d65';
 if(prim===1) return 'bt2020';
 if(meterChartIsDv()) return 'p3d65';
 return 'bt709';
}

function meterSelectedTargetGamutKey(){
 const el=document.getElementById('meterTargetGamut');
 const val=String(el&&el.value||'auto').toLowerCase();
 return /^(bt709|bt2020|p3d65)$/.test(val)?val:'';
}

function meterActiveGamutKey(){
 const forced=meterSelectedTargetGamutKey();
 return forced||meterContainerGamutKey();
}

function meterContainerGamut(){
 return GAMUT_PRESETS[meterContainerGamutKey()]||GAMUT_PRESETS.bt709;
}

function meterActiveGamut(){
 return GAMUT_PRESETS[meterActiveGamutKey()]||GAMUT_PRESETS.bt709;
}

function xyzToLinRgb(X,Y,Z,matrix){
 const M=matrix||M_XYZ_TO_RGB;
 return M.map(r=>r[0]*X+r[1]*Y+r[2]*Z);
}

function linRgbToXyz(R,G,B,matrix){
 const M=matrix||M_RGB_TO_XYZ;
 return {
  X:M[0][0]*R+M[0][1]*G+M[0][2]*B,
  Y:M[1][0]*R+M[1][1]*G+M[1][2]*B,
  Z:M[2][0]*R+M[2][1]*G+M[2][2]*B
 };
}

function meterIsLimitedRange(){
 const rangeEl=document.getElementById('rgb_quant_range');
 return !!(rangeEl&&rangeEl.value==='1');
}

function meterRangeMin(){
 return meterIsLimitedRange()?16:0;
}

function meterRangeSpan(){
 return meterIsLimitedRange()?219:255;
}

function meterSignalFractionFromCode(code){
 const min=meterRangeMin();
 const span=meterRangeSpan();
 return Math.max(0,Math.min(1,((code||0)-min)/span));
}

function meterDecodeSignalChannel(code){
 const norm=meterSignalFractionFromCode(code);
 if(meterChartIsDv()) return Math.pow(norm,2.2);
 if(meterChartIsPq()){
  const peak=meterChartHdrPeak();
  if(!(peak>0)) return norm;
  return Math.max(0,Math.min(1,meterChartPqDecodeNormalized(norm)/peak));
 }
 return Math.pow(norm,2.4);
}

function meterEncodeSignalChannel(linear){
 const min=meterRangeMin();
 const span=meterRangeSpan();
 const clamped=Math.max(0,Math.min(1,linear||0));
 let encoded=clamped;
 if(meterChartIsDv()) encoded=Math.pow(clamped,1/2.2);
 else if(meterChartIsPq()){
  const peak=meterChartHdrPeak();
  const peakCode=meterChartPqEncodeNormalized(peak)||1;
  encoded=meterChartPqEncodeNormalized(clamped*peak)/peakCode;
 }
 else encoded=Math.pow(clamped,1/2.4);
 return Math.round(min+encoded*span);
}

function meterCodeFromSignalPercent(percent){
 return Math.round(meterRangeMin()+clampNum(percent,0,100)/100*meterRangeSpan());
}

function meterActualSignalPercent(percent){
 return meterSignalFractionFromCode(meterCodeFromSignalPercent(percent))*100;
}

function meterColorLevelPercent(){
 return meterChartIsHdr()?50:75;
}

function meterColorReferenceNits(){
 if(meterChartIsPq()&&!meterChartIsDv()) return meterChartHdrPeak();
 const white=meterWhiteReading;
 if(white&&white.Y>0) return white.Y;
 if(meterChartIsHdr()) return meterChartHdrPeak();
 return 100;
}

function meterColorLabWhite(){
 const white=meterWhiteReading;
 if(white&&white.X>0&&white.Y>0&&white.Z>0) return {X:white.X,Y:white.Y,Z:white.Z};
 const refY=Math.max(1,meterColorReferenceNits());
 return {X:D65.X*refY,Y:refY,Z:D65.Z*refY};
}

function meterEncodeColorCheckerLinear(linear){
 const min=meterRangeMin();
 const span=meterRangeSpan();
 const clamped=Math.max(0,Math.min(1,linear||0));
 if(meterChartIsPq()&&!meterChartIsDv()) return Math.round(min+meterChartPqEncodeNormalized(clamped*100)*span);
 return Math.round(min+Math.pow(clamped,1/2.2)*span);
}

function meterEncodeColorCheckerFullSatChannel(active){
 const min=meterRangeMin();
 const span=meterRangeSpan();
 if(!active) return min;
 if(meterChartIsPq()&&!meterChartIsDv()) return Math.round(min+meterChartPqEncodeNormalized(100)*span);
 return min+span;
}

function meterEncodeSaturationLinear(linear){
 const min=meterRangeMin();
 const span=meterRangeSpan();
 const clamped=Math.max(0,Math.min(1,linear||0));
 if(meterChartIsPq()&&!meterChartIsDv()) return Math.round(min+meterChartPqEncodeNormalized(clamped*10000)*span);
 return Math.round(min+Math.pow(clamped,1/2.2)*span);
}

function meterGamutStimulusLinearLevel(){
 if(meterChartIsPq()&&!meterChartIsDv()) return 1;
 return Math.pow(meterColorLevelPercent()/100,2.2);
}

function meterSaturationStimulusLinearLevel(){
 const actualPercent=meterActualSignalPercent(meterColorLevelPercent())/100;
 if(meterChartIsPq()&&!meterChartIsDv()) return meterChartPqDecodeNormalized(actualPercent)/10000;
 return Math.pow(actualPercent,2.2);
}

function meterGamutColorEndpointRgb(colorName){
 switch(String(colorName||'').toLowerCase()){
  case 'red': return [1,0,0];
  case 'green': return [0,1,0];
  case 'blue': return [0,0,1];
  case 'cyan': return [0,1,1];
  case 'magenta': return [1,0,1];
  case 'yellow': return [1,1,0];
  default: return [1,1,1];
 }
}

function meterGamutColorEndpointXY(colorName){
 const gamut=meterActiveGamut();
 const rgb=meterGamutColorEndpointRgb(colorName);
 const xyz=linRgbToXyz(rgb[0],rgb[1],rgb[2],gamut.rgbToXyz);
 const sum=xyz.X+xyz.Y+xyz.Z;
 return sum>0?{x:xyz.X/sum,y:xyz.Y/sum}:{x:D65.x,y:D65.y};
}

function meterBuildSaturationTargetLinearRgb(colorName,satPercent){
 // The selected target colorspace defines the intended endpoint chromaticity,
 // but the actual RGB code values must still be solved in the active signal
 // container gamut (for HDR10, usually BT.2020) so the emitted patch matches
 // the intended target inside that container.
 const containerGamut=meterContainerGamut();
 const sat=Math.max(0,Math.min(100,satPercent||0))/100;
 const endpoint=meterGamutColorEndpointXY(colorName);
 const x=D65.x+sat*(endpoint.x-D65.x);
 const y=D65.y+sat*(endpoint.y-D65.y);
 if(y<=0) return [0,0,0];
 const coeffs=xyzToLinRgb(x/y,1,(1-x-y)/y,containerGamut.xyzToRgb);
 const maxCoeff=Math.max(coeffs[0],coeffs[1],coeffs[2],1e-9);
 const level=meterSaturationStimulusLinearLevel();
 return coeffs.map(v=>Math.max(0,v/maxCoeff)*level);
}

function meterBuildFullGamutTargetLinearRgb(colorName){
 const containerGamut=meterContainerGamut();
 const endpoint=meterGamutColorEndpointXY(colorName);
 const x=endpoint.x;
 const y=endpoint.y;
 if(y<=0) return [0,0,0];
 const coeffs=xyzToLinRgb(x/y,1,(1-x-y)/y,containerGamut.xyzToRgb);
 const maxCoeff=Math.max(coeffs[0],coeffs[1],coeffs[2],1e-9);
 return coeffs.map(v=>Math.max(0,v/maxCoeff));
}

function meterSaturationTargetXYZ(colorName,satPercent){
 // Decode with the active signal container matrix because the patch RGB was
 // solved in that container to hit the selected target chromaticity.
 const rgb=meterBuildSaturationTargetLinearRgb(colorName,satPercent);
 return linRgbToXyz(rgb[0],rgb[1],rgb[2],meterContainerGamut().rgbToXyz);
}

function meterParseSaturationReading(reading){
 if(!reading) return null;
 if(reading.series_color&&reading.sat_pct!=null){
  return {color:String(reading.series_color),sat:parseFloat(reading.sat_pct)||0};
 }
 const name=String(reading.name||'').trim();
 let match=name.match(/^(Red|Green|Blue|Cyan|Magenta|Yellow)\s+(\d+)%$/i);
 if(match) return {color:match[1],sat:parseFloat(match[2])||0};
 match=name.match(/^(\d+)%\s+(Red|Green|Blue|Cyan|Magenta|Yellow)$/i);
 if(match) return {color:match[2],sat:parseFloat(match[1])||0};
 return null;
}

function meterDecodeColorTargetChannel(code){
 const norm=meterSignalFractionFromCode(code);
 if(meterChartIsPq()&&!meterChartIsDv()) return Math.min(meterChartPqDecodeNormalized(norm),meterChartHdrPeak());
 return Math.pow(norm,2.2)*meterColorReferenceNits();
}

function targetColorXYZAbs(r,g,b){
 const gamut=meterContainerGamut();
 return linRgbToXyz(
  meterDecodeColorTargetChannel(r),
  meterDecodeColorTargetChannel(g),
  meterDecodeColorTargetChannel(b),
  gamut.rgbToXyz
 );
}

function targetChromaticityXY(r,g,b){
 const xyz=targetColorXYZAbs(r,g,b);
 const s=xyz.X+xyz.Y+xyz.Z;
 return s>0?{x:xyz.X/s,y:xyz.Y/s}:{x:D65.x,y:D65.y};
}

function meterTargetXYZForReading(reading){
 if(!reading) return {X:0,Y:0,Z:0};
 const tx=parseFloat(reading.target_x);
 const ty=parseFloat(reading.target_y);
 const tYn=parseFloat(reading.target_Yn);
 if(Number.isFinite(tx)&&Number.isFinite(ty)&&ty>0&&Number.isFinite(tYn)&&tYn>=0){
  if(tYn<=0) return {X:0,Y:0,Z:0};
  const refY=Math.max(1,meterColorReferenceNits());
  const Y=tYn*refY;
  return {X:(tx/ty)*Y,Y:Y,Z:((1-tx-ty)/ty)*Y};
 }
 const satInfo=meterParseSaturationReading(reading);
 if(satInfo) return meterSaturationTargetXYZ(satInfo.color,satInfo.sat);
 return targetColorXYZAbs(reading.r_code,reading.g_code,reading.b_code);
}

function meterTargetChromaticityForReading(reading){
 const xyz=meterTargetXYZForReading(reading);
 const s=xyz.X+xyz.Y+xyz.Z;
 return s>0?{x:xyz.X/s,y:xyz.Y/s}:{x:D65.x,y:D65.y};
}

function meterColorDeltaTargetXYZ(reading,inclLum){
 const xyz=meterTargetXYZForReading(reading);
 if(inclLum||!reading||reading.Y==null||!(reading.Y>0)||!(xyz.Y>0)) return xyz;
 const scale=reading.Y/xyz.Y;
 return {X:xyz.X*scale,Y:reading.Y,Z:xyz.Z*scale};
}

function meterColorDeltaE2000(reading,inclLum){
 if(!reading) return 0;
 const wR=meterColorLabWhite();
 const target=meterColorDeltaTargetXYZ(reading,inclLum);
 const labM=xyzToLab(reading.X||0,reading.Y||0,reading.Z||0,wR.X,wR.Y,wR.Z);
 const labT=xyzToLab(target.X,target.Y,target.Z,wR.X,wR.Y,wR.Z);
 return deltaE2000(labM,labT);
}

function meterColorCheckerClassicSource(){
 return [
  {name:'Gray 35',gray:0.35},
  {name:'Gray 50',gray:0.50},
  {name:'Gray 65',gray:0.65},
  {name:'Gray 80',gray:0.80},
  {name:'Dark Skin',x:0.405119,y:0.36253,Yn:0.096774},
  {name:'Light Skin',x:0.379756,y:0.357031,Yn:0.353705},
  {name:'Blue Sky',x:0.249396,y:0.266854,Yn:0.18913},
  {name:'Foliage',x:0.338784,y:0.433265,Yn:0.132836},
  {name:'Blue Flower',x:0.267688,y:0.25314,Yn:0.235775},
  {name:'Bluish Green',x:0.261653,y:0.359045,Yn:0.425252},
  {name:'Orange',x:0.512087,y:0.410373,Yn:0.287229},
  {name:'Purplish Blue',x:0.213095,y:0.186377,Yn:0.115692},
  {name:'Moderate Red',x:0.461291,y:0.312073,Yn:0.187204},
  {name:'Purple',x:0.288075,y:0.217532,Yn:0.064716},
  {name:'Yellow Green',x:0.37852,y:0.496473,Yn:0.436288},
  {name:'Orange Yellow',x:0.473379,y:0.443246,Yn:0.433456},
  {name:'Blue',x:0.186955,y:0.133934,Yn:0.060722},
  {name:'Green',x:0.306493,y:0.495107,Yn:0.234403},
  {name:'Red',x:0.547377,y:0.317462,Yn:0.114731},
  {name:'Yellow',x:0.44792,y:0.475618,Yn:0.597462},
  {name:'Magenta',x:0.371346,y:0.24177,Yn:0.187509},
  {name:'Cyan',x:0.19619,y:0.266985,Yn:0.193415}
 ];
}

function meterBuildColorCheckerStepsJS(){
 const steps=[];
 const min=meterRangeMin();
 const max=min+meterRangeSpan();
 const containerGamut=meterContainerGamut();
 steps.push({ire:100,r:max,g:max,b:max,name:'White'});
 steps.push({ire:0,r:min,g:min,b:min,name:'Black'});
 meterColorCheckerClassicSource().forEach(src=>{
  if(src.gray!=null){
   const code=meterEncodeColorCheckerLinear(src.gray);
   steps.push({ire:Math.round(src.gray*100),r:code,g:code,b:code,name:src.name});
   return;
  }
  const X=(src.x/src.y)*src.Yn;
  const Y=src.Yn;
  const Z=((1-src.x-src.y)/src.y)*src.Yn;
  let rl=containerGamut.xyzToRgb[0][0]*X+containerGamut.xyzToRgb[0][1]*Y+containerGamut.xyzToRgb[0][2]*Z;
  let gl=containerGamut.xyzToRgb[1][0]*X+containerGamut.xyzToRgb[1][1]*Y+containerGamut.xyzToRgb[1][2]*Z;
  let bl=containerGamut.xyzToRgb[2][0]*X+containerGamut.xyzToRgb[2][1]*Y+containerGamut.xyzToRgb[2][2]*Z;
  const mx=Math.max(rl,gl,bl);
  if(mx>1){rl/=mx;gl/=mx;bl/=mx;}
  rl=Math.max(0,rl);
  gl=Math.max(0,gl);
  bl=Math.max(0,bl);
  steps.push({
   ire:Math.round(src.Yn*100),
   r:meterEncodeColorCheckerLinear(rl),
   g:meterEncodeColorCheckerLinear(gl),
   b:meterEncodeColorCheckerLinear(bl),
   name:src.name,
   target_x:src.x,
   target_y:src.y,
   target_Yn:src.Yn
  });
 });
 [
  ['100% Red','Red'],
  ['100% Green','Green'],
  ['100% Blue','Blue'],
  ['100% Cyan','Cyan'],
  ['100% Magenta','Magenta'],
  ['100% Yellow','Yellow']
 ].forEach(([name,colorName])=>{
  const rgb=meterBuildFullGamutTargetLinearRgb(colorName);
  steps.push({
   ire:100,
   r:meterEncodeColorCheckerLinear(rgb[0]),
   g:meterEncodeColorCheckerLinear(rgb[1]),
   b:meterEncodeColorCheckerLinear(rgb[2]),
   name:name,
   series_color:colorName,
   sat_pct:100
  });
 });
 return steps;
}

function meterStepNameKey(step){
 if(!step) return '';
 return step.name||(((step.ire!=null)?step.ire:'')+'-'+(step.r||0)+'-'+(step.g||0)+'-'+(step.b||0));
}

function meterLinearToSrgbChannel(linear){
 const c=Math.max(0,Math.min(1,linear||0));
 return c<=0.0031308 ? 12.92*c : 1.055*Math.pow(c,1/2.4)-0.055;
}

function meterPreviewCssFromLinearRgb(rgb,normalize){
 let vals=(rgb||[0,0,0]).map(v=>Number.isFinite(v)?Math.max(0,v):0);
 const isGrey=Math.abs(vals[0]-vals[1])<1e-4&&Math.abs(vals[1]-vals[2])<1e-4;
 const mx=Math.max(vals[0],vals[1],vals[2],0);
 if(mx>0){
  if(normalize&&!isGrey) vals=vals.map(v=>v/mx);
  else if(mx>1) vals=vals.map(v=>v/mx);
 }
 const enc=vals.map(v=>Math.round(255*meterLinearToSrgbChannel(v)));
 return 'rgb('+enc[0]+','+enc[1]+','+enc[2]+')';
}

function meterPreviewCssFromXYZ(X,Y,Z,normalize){
 return meterPreviewCssFromLinearRgb(xyzToLinRgb(X,Y,Z,GAMUT_PRESETS.bt709.xyzToRgb),normalize!==false);
}

function meterSignalPreviewColor(r,g,b){
 if(r==null||g==null||b==null) return '#aaa';
 if(r===g&&g===b) return 'rgb('+r+','+g+','+b+')';
 const xyz=linRgbToXyz(
  meterDecodeSignalChannel(r),
  meterDecodeSignalChannel(g),
  meterDecodeSignalChannel(b),
  meterContainerGamut().rgbToXyz
 );
 return meterPreviewCssFromXYZ(xyz.X,xyz.Y,xyz.Z,true);
}

function meterPreviewColorForReading(reading,mode){
 if(!reading) return '#aaa';
 const r=reading.r_code!=null?reading.r_code:reading.r;
 const g=reading.g_code!=null?reading.g_code:reading.g;
 const b=reading.b_code!=null?reading.b_code:reading.b;
 if(r!=null&&g!=null&&b!=null&&r===g&&g===b) return meterSignalPreviewColor(r,g,b);
 if(mode==='measured'&&reading.X!=null&&reading.Y!=null&&reading.Z!=null&&reading.Y>0){
  return meterPreviewCssFromXYZ(reading.X,reading.Y,reading.Z,true);
 }
 const target=meterTargetXYZForReading(reading);
 if(target&&target.Y>0) return meterPreviewCssFromXYZ(target.X,target.Y,target.Z,true);
 return meterSignalPreviewColor(r,g,b);
}

function meterPreviewColorForStep(step){
 if(!step) return '#aaa';
 return meterPreviewColorForReading({
  r_code:step.r,
  g_code:step.g,
  b_code:step.b,
  series_color:step.series_color,
  sat_pct:step.sat_pct,
  name:step.name
 },'target');
}

function meterContrastTextColor(css){
 const m=String(css||'').match(/\d+/g)||[];
 if(m.length<3) return '#222';
 const lum=0.299*parseInt(m[0],10)+0.587*parseInt(m[1],10)+0.114*parseInt(m[2],10);
 return lum<145?'#eee':'#222';
}

// Display color for a stimulus RGB triplet using a browser-safe preview of the
// actual emitted signal patch inside the current signal container.
function stimulusColor(r,g,b){
 return meterSignalPreviewColor(r,g,b);
}

// CIE 1931 spectral locus xy coordinates (5nm intervals, 380-700nm)
const CIE_LOCUS=[[.1741,.005],[.174,.005],[.1733,.0048],[.1726,.0048],[.1714,.0051],[.1703,.0058],[.1689,.0069],[.1669,.0086],[.1644,.0109],[.1611,.0138],[.1566,.0177],[.151,.0227],[.144,.0297],[.1355,.0399],[.1241,.0578],[.1096,.0868],[.0913,.1327],[.0687,.2007],[.0454,.295],[.0235,.4127],[.0082,.5384],[.0039,.6548],[.0139,.7502],[.0389,.812],[.0743,.8338],[.1142,.8262],[.1547,.8059],[.1929,.7816],[.2296,.7543],[.2658,.7243],[.3016,.6923],[.3373,.6589],[.3731,.6245],[.4087,.5896],[.4441,.5547],[.4788,.5202],[.5125,.4866],[.5448,.4544],[.5752,.4242],[.6029,.3965],[.627,.3725],[.6482,.3514],[.6658,.334],[.6801,.3197],[.6915,.3083],[.7006,.2993],[.7079,.292],[.714,.2859],[.719,.2809],[.723,.277],[.726,.274],[.7283,.2717],[.73,.27],[.732,.268],[.7334,.2666],[.7347,.2653]];

// CIE L* from Y/Yn (normalized luminance 0-1) — perceptual lightness
function ynToLstar(yn){
 const a=Math.abs(yn);
 const f=a>0.008856451679?Math.pow(a,1/3):(903.2963*a+16)/116;
 const L=116*f-16;
 return yn>=0?L:-L;
}

function rgbBalance(reading,whiteRef,inclLum){
 if(!whiteRef||whiteRef.Y<=0) return {R:100,G:100,B:100};
 // Use D65 chromaticity as target — Calman uses gamut white (D65 for BT.709)
 const wXn=D65.X, wZn=D65.Z;
 // Measured XYZ normalized by white Y
 const mXn=reading.X/whiteRef.Y, mYn=reading.Y/whiteRef.Y, mZn=reading.Z/whiteRef.Y;
 const ire=reading.ire;
 let lcXn,lcYn,lcZn;
 if(ire!=null&&ire>0){
  // Target: measured white chromaticity at the active grey-target luminance.
  const Lw=whiteRef.Y, Lb=0;
  const tgtLum=meterGreyTargetLuminance(ire,Lw,Lb,reading.r_code);
  const tYn=tgtLum/whiteRef.Y;
  const tXn=wXn*tYn;
  const tZn=wZn*tYn;
  // Calman RGB balance always uses the luminance-compensated target rather
  // than following the delta-E checkbox state.
  const lumRatio=(mYn>0&&tYn>0)?mYn/tYn:1;
  lcXn=tXn*lumRatio; lcYn=mYn; lcZn=tZn*lumRatio;
 } else {
  // No IRE: scale white chromaticity to measured luminance
  lcXn=wXn*mYn; lcYn=mYn; lcZn=wZn*mYn;
 }
 // Convert both to linear RGB via Rec.709 matrix
 const gamut=meterActiveGamut();
 const mRgb=xyzToLinRgb(mXn,mYn,mZn,gamut.xyzToRgb);
 const tRgb=xyzToLinRgb(lcXn,lcYn,lcZn,gamut.xyzToRgb);
 // Per-channel percent: L*(measured) - L*(target) + 100 (perceptual balance)
 return {
  R:ynToLstar(mRgb[0])-ynToLstar(tRgb[0])+100,
  G:ynToLstar(mRgb[1])-ynToLstar(tRgb[1])+100,
  B:ynToLstar(mRgb[2])-ynToLstar(tRgb[2])+100
 };
}

function meterLiveRgbData(reading){
 if(!reading) return {mode:'balance',R:100,G:100,B:100};
 const isColorSeries=meterActiveSeriesType==='colors'||meterActiveSeriesType==='saturations';
 if(!isColorSeries||reading.X==null||reading.Y==null||reading.Z==null){
  return meterWhiteReading?{mode:'balance',...rgbBalance(reading,meterWhiteReading,meterIncludeLum())}:{mode:'balance',R:100,G:100,B:100};
 }
 const gamut=meterActiveGamut();
   const target=meterTargetXYZForReading(reading);
 const ref=Math.max(1,meterColorReferenceNits());
 const mRgb=xyzToLinRgb(reading.X,reading.Y,reading.Z,gamut.xyzToRgb);
 const tRgb=xyzToLinRgb(target.X,target.Y,target.Z,gamut.xyzToRgb);
 return {
  mode:'delta',
  R:((mRgb[0]||0)-(tRgb[0]||0))/ref*100,
  G:((mRgb[1]||0)-(tRgb[1]||0))/ref*100,
  B:((mRgb[2]||0)-(tRgb[2]||0))/ref*100
 };
}

function effectiveGamma(Y,Yw,ire){
 if(ire<=0||Y<=0||Yw<=0) return null;
 return Math.log(Y/Yw)/Math.log(ire/100);
}

function bt1886Eotf(v,Lw,Lb){
 Lw=Lw||100;Lb=Lb||0;
 const g=2.4;
 const a=Math.pow(Math.pow(Lw,1/g)-Math.pow(Lb,1/g),g);
 const b=Math.pow(Lb,1/g)/(Math.pow(Lw,1/g)-Math.pow(Lb,1/g));
 return a*Math.pow(Math.max(0,v+b),g);
}

function gammaEotf(v,gamma){return Math.pow(Math.max(0,v),gamma);}

function srgbEotf(v){return v<=0.04045?v/12.92:Math.pow((v+0.055)/1.055,2.4);}

function targetEotf(v,Lw,Lb){
 const tgt=document.getElementById('meterTargetGamma').value;
 if(tgt==='bt1886') return bt1886Eotf(v,Lw,Lb);
 if(tgt==='srgb') return srgbEotf(v)*Lw;
 return gammaEotf(v,parseFloat(tgt))*Lw;
}

function meterGreyStimulusFraction(ire){
 const pct=Math.max(0,Math.min(100,ire||0));
 const isLimited=meterIsLimitedRange();
 const dvMode=meterChartIsDv();
 const code=dvMode
  ? (isLimited?Math.round(16+Math.pow(pct/100,1/2.2)*219):Math.round(Math.pow(pct/100,1/2.2)*255))
  : (isLimited?Math.round(16+pct/100*(235-16)):Math.round(pct*255/100));
 return meterSignalFractionFromCode(code);
}

function meterGreyTargetLuminance(ire,Lw,Lb,code){
 const peak=meterChartIsHdr()?meterChartHdrPeak():(Lw>0?Lw:1);
 const v=Math.max(0,ire||0)/100;
 const signal=(code!=null)?meterSignalFractionFromCode(code):(meterChartIsPq()?meterGreyStimulusFraction(ire):v);
 return meterChartTargetLuminance(signal,peak,Lb||0);
}

function meterGreyTargetChartValue(ire,Lw,Lb,code){
 return meterGreyTargetLuminance(ire,Lw,Lb,code);
}

function meterGreyTargetChartPoints(steps,Lw,Lb,scale){
 const pts=[];
 const seen={};
 const addPoint=(ire,code)=>{
  const key=''+ire+':'+(code==null?'':code);
  if(seen[key]) return;
  seen[key]=1;
  pts.push([Math.max(0,Math.min(100,ire))/100,meterGreyTargetChartValue(ire,Lw,Lb,code)/scale]);
 };
 addPoint(0,0);
 (steps||[]).forEach(s=>addPoint(s.ire||0,s.r_code!=null?s.r_code:s.r));
 addPoint(100,meterRangeMin()+meterRangeSpan());
 pts.sort((a,b)=>a[0]-b[0]);
 return pts;
}

function targetGammaValue(){
 const tgt=document.getElementById('meterTargetGamma').value;
 if(tgt==='bt1886') return 2.4;
 if(tgt==='srgb') return 2.2;
 return parseFloat(tgt);
}

function meterChartSignalMode(){
 if(config&&config.dv_status==='1') return 'dv';
 if(config&&config.is_hdr==='1') return (config.eotf==='3')?'hlg':'hdr10';
 return 'sdr';
}

function meterChartIsHdr(){
 return meterChartSignalMode()!=='sdr';
}

function meterChartIsPq(){
 const sm=meterChartSignalMode();
 return sm==='hdr10'||sm==='dv';
}

function meterChartIsDv(){
 return meterChartSignalMode()==='dv';
}

function meterChartHdrPeak(){
 const peak=parseFloat((config&&config.max_luma)||'1000');
 if(!(peak>0)) return 1000;
 return Math.min(10000,peak);
}

function meterChartPqEncodeNormalized(nits){
 const clamped=Math.max(0,Math.min(10000,nits||0));
 if(clamped<=0) return 0;
 const l=clamped/10000;
 const m1=2610/16384;
 const m2=2523/32;
 const c1=3424/4096;
 const c2=2413/128;
 const c3=2392/128;
 const p=Math.pow(l,m1);
 return Math.pow((c1+c2*p)/(1+c3*p),m2);
}

function meterChartPqDecodeNormalized(code){
 const clamped=Math.max(0,Math.min(1,code||0));
 if(clamped<=0) return 0;
 const m1=2610/16384;
 const m2=2523/32;
 const c1=3424/4096;
 const c2=2413/128;
 const c3=2392/128;
 const p=Math.pow(clamped,1/m2);
 const num=Math.max(p-c1,0);
 const den=c2-c3*p;
 if(den<=0) return 10000;
 return 10000*Math.pow(num/den,1/m1);
}

function meterChartHdrStimulusLuminance(v){
 return Math.pow(Math.max(0,Math.min(1,v)),2.2)*meterChartHdrPeak();
}

function meterChartHdrCodeLuminance(v,clipPeak){
 const peak=(clipPeak>0)?clipPeak:meterChartHdrPeak();
 return Math.min(meterChartPqDecodeNormalized(v),peak);
}

function meterChartDvClipPeak(){
 const contentPeak=meterChartHdrPeak();
 const whitePeak=(meterWhiteReading&&meterWhiteReading.luminance>0)?meterWhiteReading.luminance:0;
 return whitePeak>0?Math.min(contentPeak,whitePeak):contentPeak;
}

function meterChartTrackingLuminance(v,clipPeak,Lw,Lb){
 const clamped=Math.max(0,Math.min(1,v));
 if(meterChartIsDv()){
  const contentPeak=meterChartHdrPeak();
  const peak=(clipPeak>0)?clipPeak:meterChartDvClipPeak();
  return Math.min(Math.pow(clamped,2.2)*contentPeak,peak);
 }
 if(meterChartIsPq()) return meterChartHdrCodeLuminance(clamped,clipPeak);
 return targetEotf(clamped,Lw,Lb);
}

function meterChartTargetLuminance(v,Lw,Lb){
 if(meterChartIsDv()) return meterChartTrackingLuminance(v,meterChartDvClipPeak(),Lw,Lb);
 if(meterChartIsHdr()) return meterChartTrackingLuminance(v,meterChartHdrPeak(),Lw,Lb);
 return meterChartTrackingLuminance(v,Lw,Lw,Lb);
}

// CIE L* from Y with white reference Yn
function cieLstar(Y,Yn){
 if(Yn<=0) return 0;
 const r=Y/Yn;
 return r>0.008856?116*Math.cbrt(r)-16:903.3*r;
}

// CIELUV chromaticity-only ΔE: 1300 * Δu'v' (HCFR old formula)
function deltaEuv(X,Y,Z,Xr,Yr,Zr){
 const d=X+15*Y+3*Z, dr=Xr+15*Yr+3*Zr;
 if(d<=0||dr<=0) return 0;
 const u=4*X/d, v=9*Y/d;
 const ur=4*Xr/dr, vr=9*Yr/dr;
 return 1300*Math.sqrt((u-ur)*(u-ur)+(v-vr)*(v-vr));
}

// Full CIELUV ΔE*uv (HCFR 3.5.4.4 new formula)
// Yw1/Yw2 = white Y for L* scaling of measured/reference
// (Xn,Yn,Zn) = adaptation white for u'n,v'n
function deltaELuv(X1,Y1,Z1,Yw1, X2,Y2,Z2,Yw2, Xn,Yn,Zn){
 const L1=cieLstar(Y1,Yw1), L2=cieLstar(Y2,Yw2);
 const d1=X1+15*Y1+3*Z1, d2=X2+15*Y2+3*Z2, dn=Xn+15*Yn+3*Zn;
 if(d1<=0||dn<=0) return Math.abs(L1-L2);
 const un=4*Xn/dn, vn=9*Yn/dn;
 const u1s=13*L1*(4*X1/d1-un), v1s=13*L1*(9*Y1/d1-vn);
 const u2s=d2>0?13*L2*(4*X2/d2-un):0, v2s=d2>0?13*L2*(9*Y2/d2-vn):0;
 return Math.sqrt((L1-L2)*(L1-L2)+(u1s-u2s)*(u1s-u2s)+(v1s-v2s)*(v1s-v2s));
}

// XYZ to Lab (optional white point, defaults to D65 Y=1)
function xyzToLab(X,Y,Z,Xn,Yn,Zn){
 if(!Xn){Xn=D65.X;Yn=D65.Y;Zn=D65.Z;}
 const e=216/24389, k=24389/27;
 function f(t){return t>e?Math.cbrt(t):(k*t+16)/116;}
 const fx=f(X/Xn),fy=f(Y/Yn),fz=f(Z/Zn);
 return {L:116*fy-16, a:500*(fx-fy), b:200*(fy-fz)};
}

// HCFR's CIELUV ΔE — matches libHCFR/Color.cpp ColorLuv ctor bit-for-bit.
// HCFR's u-prime has a bug (12*x instead of 12*y in the denominator):
//   u = 4x / (-2x + 12x + 3)   [should be 12y, but HCFR uses 12x]
//   v = 9y / (-2x + 12y + 3)   [correct]
// u_white, v_white use the same formulas applied to the CColorReference
// white point (D65 for BT.709/BT.2020). refColor's chromaticity is NOT the
// subtraction target — the cRef white is.
// YWhite / YWhiteRef scale L* via var_Y = Y/YWhite (epsilon branch for low Y).
function lstar(Y,YW){
 const e=216/24389, k=24389/27;
 if(YW<=0||Y<=0) return 0;
 const v=Y/YW;
 return v>e ? 116*Math.cbrt(v)-16 : (k*v+16)/116*116-16;
}
function _hcfrUV(X,Y,Z){
 const s=X+Y+Z; if(s<=0) return {u:0,v:0};
 const x=X/s, y=Y/s;
 const u=4*x/(10*x+3);        // HCFR's buggy u: -2x+12x+3 = 10x+3
 const v=9*y/(-2*x+12*y+3);   // standard v
 return {u:u,v:v};
}
function deltaELuvHCFR(X1,Y1,Z1,YW1, X2,Y2,Z2,YW2){
 // L* from each sample's own YWhite (matches HCFR: Luv(*this, YWhite, cRef)
 // for measured, LuvRef(refColor, YWhiteRef, cRef) for reference).
 const L1=lstar(Y1,YW1), L2=lstar(Y2,YW2);
 // u_white, v_white are always from cRef (D65 for our BT.709/2020 pipeline)
 const uw=4*D65.x/(10*D65.x+3);
 const vw=9*D65.y/(-2*D65.x+12*D65.y+3);
 const m1=_hcfrUV(X1,Y1,Z1);
 const m2=_hcfrUV(X2,Y2,Z2);
 const u1s=13*L1*(m1.u-uw), v1s=13*L1*(m1.v-vw);
 const u2s=13*L2*(m2.u-uw), v2s=13*L2*(m2.v-vw);
 const dL=L1-L2, du=u1s-u2s, dv=v1s-v2s;
 return Math.sqrt(dL*dL+du*du+dv*dv);
}

// Returns whether the "Include luminance error" checkbox is ticked.
function meterIncludeLum(){
 const el=document.getElementById('meterIncludeLumError');
 return !!(el&&el.checked);
}

// Greyscale reference builder for ΔE calculation.
//
//   inclLum === false : chroma-only. Reference is D65 at the measured Y
//     normalized by peak, so ΔL* = 0 and only u'v' / a*b* chromaticity
//     error contributes. Matches the chroma-only readout used by most
//     calibration tools.
//   inclLum === true  : Calman-style "include luminance error". The checkbox
//     itself is mode-agnostic in Calman; SDR/HDR/DV differences come from the
//     active target colorspace and transfer function behind each point.
//     Both measured and reference L* use the same peak normalization so ΔL*
//     is the real luminance error against the tracking target.
function hcfrGreyRef(ire, Ym, Lw, Lb, inclLum, code){
 const peak = meterChartIsHdr() ? meterChartHdrPeak() : (Lw>0 ? Lw : (Ym>0?Ym:1));
 if(!inclLum){
  const vy = peak>0 ? Ym/peak : 0;
  return {
   YWhite: peak,
   refX: D65.X*vy, refY: vy, refZ: D65.Z*vy,
   YWhiteRef: 1.0
  };
 }
 // Calman-style: active grey target (absolute luminance) vs peak reference.
 const tgtY = meterGreyTargetLuminance(ire, peak, Lb||0, code);
 const vy = peak>0 ? tgtY/peak : 0;
 return {
  YWhite: peak,
  refX: D65.X*vy, refY: vy, refZ: D65.Z*vy,
  YWhiteRef: 1.0
 };
}

// Simplified deltaE2000
function deltaE2000(lab1,lab2){ const dL=lab2.L-lab1.L;
 const C1=Math.sqrt(lab1.a*lab1.a+lab1.b*lab1.b);
 const C2=Math.sqrt(lab2.a*lab2.a+lab2.b*lab2.b);
 const Cb=(C1+C2)/2;
 const G=0.5*(1-Math.sqrt(Math.pow(Cb,7)/(Math.pow(Cb,7)+Math.pow(25,7))));
 const a1p=lab1.a*(1+G),a2p=lab2.a*(1+G);
 const C1p=Math.sqrt(a1p*a1p+lab1.b*lab1.b);
 const C2p=Math.sqrt(a2p*a2p+lab2.b*lab2.b);
 const dCp=C2p-C1p;
 let h1p=(a1p===0&&lab1.b===0)?0:Math.atan2(lab1.b,a1p)*180/Math.PI; if(h1p<0) h1p+=360;
 let h2p=(a2p===0&&lab2.b===0)?0:Math.atan2(lab2.b,a2p)*180/Math.PI; if(h2p<0) h2p+=360;
 const Cprod=C1p*C2p;
 let dhp;
 if(Cprod===0){ dhp=0; }
 else {
  dhp=h2p-h1p;
  if(dhp>180) dhp-=360;
  else if(dhp<-180) dhp+=360;
 }
 const dHp=2*Math.sqrt(Cprod)*Math.sin(dhp*Math.PI/360);
 const Lbp=(lab1.L+lab2.L)/2;
 const Cbp=(C1p+C2p)/2;
 let Hbp;
 if(Cprod===0){ Hbp=h1p+h2p; }
 else {
  const dh=Math.abs(h1p-h2p);
  if(dh<=180) Hbp=(h1p+h2p)/2;
  else if(h1p+h2p<360) Hbp=(h1p+h2p+360)/2;
  else Hbp=(h1p+h2p-360)/2;
 }
 const T=1-0.17*Math.cos((Hbp-30)*Math.PI/180)+0.24*Math.cos(2*Hbp*Math.PI/180)+0.32*Math.cos((3*Hbp+6)*Math.PI/180)-0.20*Math.cos((4*Hbp-63)*Math.PI/180);
 const SL=1+0.015*Math.pow(Lbp-50,2)/Math.sqrt(20+Math.pow(Lbp-50,2));
 const SC=1+0.045*Cbp;
 const SH=1+0.015*Cbp*T;
 const RT=-2*Math.sqrt(Math.pow(Cbp,7)/(Math.pow(Cbp,7)+Math.pow(25,7)))*Math.sin(60*Math.exp(-Math.pow((Hbp-275)/25,2))*Math.PI/180);
 return Math.sqrt(Math.pow(dL/SL,2)+Math.pow(dCp/SC,2)+Math.pow(dHp/SH,2)+RT*(dCp/SC)*(dHp/SH));
}

async function meterCheckStatus(){
 const r=await fetchJSON('/api/meter/status',{_quiet:true,_timeoutMs:5000});
 if(r&&r.detected){
  meterDetected=true;
  document.getElementById('meterCard').style.display='';
  document.getElementById('meterStatusWrap').style.display='';
  document.getElementById('meterDot').style.background='var(--green)';
  document.getElementById('meterStatusText').textContent=r.name||'Meter';
  document.getElementById('meterStatusText').style.color='var(--text)';
  document.getElementById('meterResetRow').style.display='none';
  meterUpdateCardMode();
  meterUpdateReadButtons();
 } else {
  meterDetected=false;
  // Card stays visible in Patterns mode — always show series buttons + thumbs.
  document.getElementById('meterCard').style.display='';
  document.getElementById('meterStatusWrap').style.display='';
  document.getElementById('meterDot').style.background='var(--text2)';
  document.getElementById('meterStatusText').textContent='No Meter';
  document.getElementById('meterStatusText').style.color='var(--text2)';
  meterUpdateCardMode();
  meterUpdateReadButtons();
 }
 // Sync shared series state across browsers. Recover shared data only when
 // this browser doesn't already have its own locally selected series.
 if(!meterSeriesRunning && !meterSeriesPolling && !meterContinuousActive){
  const s=await fetchJSON('/api/meter/series/status',{_quiet:true,_timeoutMs:5000});
  if(s){
   if(s.status==='cleared'){
    if(meterSharedSeriesId || !meterActiveSeriesKey){
     meterSharedSeriesId=null;
     meterApplyClearedState(false);
    }
   } else if(!meterActiveSeriesKey && s.series_id && (s.status==='running'||s.status==='complete'||s.status==='cancelled'||s.status==='error')){
    meterRecoverSeries(s);
   }
  }
 }
}

function meterRecoverSeries(s){
 // Determine series type and points from series_id or the recovered steps.
 let type='greyscale',points=21;
 if(s.series_id){
  const m=s.series_id.match(/^(greyscale|colors|saturations)_/);
  if(m) type=m[1];
 }
 // Recover steps: prefer server-provided steps, else rebuild client-side
 let steps=null;
 if(s.steps&&Array.isArray(s.steps)&&s.steps.length>0){
  steps=s.steps;
  if(type!=='greyscale'&&type!=='colors'&&type!=='saturations'){
   const allGrey=steps.every(st=>Number(st.r)===Number(st.g)&&Number(st.g)===Number(st.b));
   if(allGrey){type='greyscale';}
   else if(steps.length===6){type='colors';}
   else if(steps.length===24){type='saturations';}
  }
 } else {
  if(s.total_steps){
   if(type==='greyscale') points=s.total_steps<=11?11:21;
   else if(type==='colors'||type==='saturations') points=s.total_steps;
  }
  steps=meterBuildStepsJS(type,points);
 }
 if(s.total_steps){
  if(type==='greyscale') points=s.total_steps<=11?11:21;
  else if(type==='colors'||type==='saturations') points=s.total_steps;
 }
 meterSeriesSteps=steps;
 meterActiveSeriesType=type;
 meterActiveSeriesPoints=points;
 meterActiveSeriesKey=type+'-'+points;
 meterSharedSeriesId=s.series_id||null;
 // Restore readings
 if(s.readings&&s.readings.length>0){
  meterReadings=s.readings;
  const white=s.readings.find(rd=>rd.ire===100&&rd.r_code===rd.g_code&&rd.g_code===rd.b_code&&rd.luminance!=null);
  if(white) meterWhiteReading=white;
 }
 // Show UI elements — ensure card is visible even if meter is disconnected
 document.getElementById('meterCard').style.display='';
 document.getElementById('meterCharts').style.display='';
 // Toggle greyscale vs color chart sections
 if(type==='greyscale'){
  document.getElementById('chartsGreyscaleWrap').style.display='';
  document.getElementById('chartsColorWrap').style.display='none';
 } else {
  document.getElementById('chartsGreyscaleWrap').style.display='none';
  document.getElementById('chartsColorWrap').style.display='';
 }
 document.getElementById('meterExportRow').style.display='';
 document.getElementById('meterReadSeriesBtn').style.display='';
 document.getElementById('meterThumbsRow').style.display='';
 document.getElementById('meterLiveReading').style.display='';
 // Highlight correct series button
 meterResetSeriesButtons();
 const activeBtn=document.querySelector('#meterSeriesBtnRow button[data-series="'+meterActiveSeriesKey+'"]');
 if(activeBtn){activeBtn.classList.remove('btn-secondary');activeBtn.classList.add('btn-primary');}
 // Build thumbs and charts
 const sortedSteps=(type==='colors'||type==='saturations')?[...steps]:[...steps].sort((a,b)=>(a.ire||0)-(b.ire||0));
 const completedIres=new Set();
 if(meterReadings) meterReadings.forEach(rd=>{if(rd.luminance!=null) completedIres.add(meterStepNameKey(rd));});
 let currentIre=s.current_name||null;
 meterBuildPatchThumbs(sortedSteps,completedIres,currentIre);
 // Draw charts with available readings
 if(meterReadings&&meterReadings.length>0){
  const sorted=(type==='colors'||type==='saturations')?[...meterReadings]:[...meterReadings].sort((a,b)=>(a.ire||0)-(b.ire||0));
  drawAllCharts(sorted);
  const lastValid=[...meterReadings].reverse().find(rd=>rd.luminance!=null);
  if(lastValid) updateLiveReading(lastValid);
 } else {
  drawAllChartsPreset(sortedSteps);
 }
 meterCacheSeriesState(s.status||'complete');
 if(s.status==='running'){
  // Series is still running — start polling and show stop button
  meterSeriesRunning=true;
  document.getElementById('meterProgress').style.display='';
  document.getElementById('meterStopBtn').style.display='';
  document.getElementById('meterReadSeriesBtn').classList.remove('btn-secondary');
  document.getElementById('meterReadSeriesBtn').classList.add('btn-success');
  document.getElementById('meterProgressLabel').textContent=s.current_name||'Running...';
  document.getElementById('meterDot').style.background='var(--orange)';
  if(meterSeriesPolling) clearInterval(meterSeriesPolling);
  meterSeriesPolling=setInterval(meterPollSeries,2000);
 } else {
  // Complete/cancelled/error — just show results, no polling
  meterSeriesRunning=false;
  document.getElementById('meterStopBtn').style.display='none';
  document.getElementById('meterReadSeriesBtn').classList.add('btn-secondary');
  document.getElementById('meterReadSeriesBtn').classList.remove('btn-success');
  if(s.status==='error'){
   document.getElementById('meterProgress').style.display='';
   document.getElementById('meterProgressLabel').textContent=s.current_name||'Error';
  }
 }
 meterUpdateReadButtons();
}

function meterStampReadingStepMeta(reading,step){
 if(!reading||!step) return reading;
 if(step.ire!=null) reading.ire=step.ire;
 if(step.name!=null) reading.name=step.name;
 if(step.r!=null) reading.r_code=step.r;
 if(step.g!=null) reading.g_code=step.g;
 if(step.b!=null) reading.b_code=step.b;
 if(step.series_color!=null) reading.series_color=step.series_color;
 if(step.sat_pct!=null) reading.sat_pct=step.sat_pct;
 if(step.target_x!=null) reading.target_x=step.target_x;
 if(step.target_y!=null) reading.target_y=step.target_y;
 if(step.target_Yn!=null) reading.target_Yn=step.target_Yn;
 return reading;
}

function meterAttachSeriesMeta(readings){
 if(!Array.isArray(readings)||!meterSeriesSteps) return readings||[];
 return readings.map(rd=>{
  const step=meterSeriesSteps.find(s=>meterStepNameKey(s)===meterStepNameKey(rd)||((s.name||'')===(rd.name||'')&&Number(s.r||0)===Number(rd.r_code||0)&&Number(s.g||0)===Number(rd.g_code||0)&&Number(s.b||0)===Number(rd.b_code||0)));
  return step?meterStampReadingStepMeta(rd,step):rd;
 });
}

function meterReadingHasLuminance(rd){
 return !!rd&&((rd.luminance!=null&&rd.luminance>=0)||(rd.Y!=null&&rd.Y>=0));
}

function meterReadingHasChromaticity(rd){
 return !!rd&&rd.x!=null&&rd.y!=null&&rd.x>0&&rd.y>0;
}

function meterCacheSeriesState(status){
 if(!meterActiveSeriesKey||!meterSeriesSteps||meterSeriesSteps.length===0) return;
 meterSeriesCache[meterActiveSeriesKey]={
  type:meterActiveSeriesType,
  points:meterActiveSeriesPoints,
  steps:JSON.parse(JSON.stringify(meterSeriesSteps||[])),
  readings:JSON.parse(JSON.stringify(meterReadings||[])),
  status:status||(meterSeriesRunning?'running':'complete'),
  series_id:meterSharedSeriesId||null
 };
}

function meterRestoreSeriesFromCache(key){
 const cached=meterSeriesCache[key];
 if(!cached||!cached.steps||cached.steps.length===0) return false;
 meterRecoverSeries({
  series_id:cached.series_id||(cached.type+'_cached'),
  status:cached.status||'complete',
  total_steps:cached.steps.length,
  steps:JSON.parse(JSON.stringify(cached.steps)),
  readings:JSON.parse(JSON.stringify(cached.readings||[]))
 });
 return true;
}

function updateLiveReading(reading){
 if((meterActiveSeriesType==='colors'||meterActiveSeriesType==='saturations')&&_colorDetailPinned&&_selectedColorReadingName&&Array.isArray(meterReadings)){
  const selected=meterReadings.find(r=>r&&r.name===_selectedColorReadingName);
  if(selected) reading=selected;
 }
 document.getElementById('meterLiveReading').style.display='';
 document.getElementById('meterLum').textContent=reading.luminance!=null?reading.luminance.toFixed(2):'--';
 document.getElementById('meterCCT').textContent=reading.cct||'--';
 document.getElementById('meterCIEx').textContent=reading.x!=null?reading.x.toFixed(4):'--';
 document.getElementById('meterCIEy').textContent=reading.y!=null?reading.y.toFixed(4):'--';

 const liveRgb=meterLiveRgbData(reading);
 drawRGBBars(liveRgb);
}

function drawRGBBars(bal){
 const c=document.getElementById('meterRGBCanvas');
 if(!c) return;
 const dpr=window.devicePixelRatio||1;
 const rect=c.getBoundingClientRect();
 c.width=rect.width*dpr;
 c.height=rect.height*dpr;
 const ctx=c.getContext('2d');
 ctx.scale(dpr,dpr);
 const W=rect.width,H=rect.height;
 ctx.fillStyle='#1d1d29';ctx.fillRect(0,0,W,H);
 const isDelta=bal&&bal.mode==='delta';
 const center=isDelta?0:100;
 const maxDev=Math.max(Math.abs((bal.R||0)-center),Math.abs((bal.G||0)-center),Math.abs((bal.B||0)-center),1);
 const halfRange=Math.max(isDelta?2:5,Math.ceil(maxDev/5)*5+(isDelta?1:2));
 const lo=center-halfRange,hi=center+halfRange;
 const labelW=20,barL=labelW+4,barR=W-40;
 const barW=barR-barL;
 function valToX(v){return barL+(v-lo)/(hi-lo)*barW;}
 // Gridlines at 5-unit intervals
 ctx.font='8px sans-serif';ctx.textAlign='center';ctx.fillStyle='#666';
 for(let g=Math.ceil(lo/5)*5;g<=hi;g+=5){
  const x=valToX(g);
  ctx.strokeStyle=g===center?'#888':'#2a2a3a';
  ctx.lineWidth=g===center?1.5:0.5;
  ctx.beginPath();ctx.moveTo(x,0);ctx.lineTo(x,H);ctx.stroke();
  ctx.fillStyle=g===center?'#aaa':'#555';
  ctx.fillText(g,x,H-1);
 }
 // Bars
 const channels=[{ch:'R',color:'#f44',v:bal.R},{ch:'G',color:'#4caf50',v:bal.G},{ch:'B',color:'#42a5f5',v:bal.B}];
 const barH=Math.min(12,(H-16)/3-2);
 const topPad=2;
 channels.forEach((c,i)=>{
  const cy=topPad+i*(barH+3)+barH/2;
  const x100=valToX(center);
  const xVal=valToX(c.v);
  // Bar from center to value
  const bx=Math.min(x100,xVal),bw=Math.abs(xVal-x100);
  ctx.fillStyle=c.color;
  ctx.globalAlpha=0.85;
  ctx.fillRect(bx,cy-barH/2,Math.max(bw,1),barH);
  ctx.globalAlpha=1;
  // Dot at value
  ctx.beginPath();ctx.arc(xVal,cy,3,0,Math.PI*2);ctx.fillStyle=c.color;ctx.fill();
  // Channel label
  ctx.fillStyle=c.color;ctx.font='bold 9px sans-serif';ctx.textAlign='right';
  ctx.fillText(c.ch,labelW,cy+3);
  // Value label at right
  ctx.fillStyle='#ccc';ctx.font='9px sans-serif';ctx.textAlign='left';
  const prefix=isDelta&&c.v>0?'+':'';
  ctx.fillText(prefix+c.v.toFixed(1)+'%',barR+4,cy+3);
 });
}

async function meterReadOnce(){
 if(!meterDetected){toast('No meter detected',true);return;}
 if(meterSeriesRunning){toast('Series scan is running \u2014 stop it first',true);return;}
 // Enter manual mode: shut down any leftover series poller/state so stale
 // series snapshots cannot repaint the charts after this manual read.
 meterSharedSeriesId=null;
 meterSeriesRunning=false;
 if(meterSeriesPolling){
  clearInterval(meterSeriesPolling);
  meterSeriesPolling=null;
 }
 fetchJSON('/api/meter/stop',{method:'POST',_quiet:true,_timeoutMs:5000});
 document.getElementById('meterStopBtn').style.display='none';
 document.getElementById('meterReadOnce').disabled=true;
 document.getElementById('meterReadOnce').textContent='\u23F3 Reading\u2026';
 document.getElementById('meterDot').style.background='var(--orange)';
 // Pulse ONLY the thumb we're reading (selected patch), clear any stale state
 // from a previous series on all other thumbs.
 const readIre=meterCurrentPatchStep?meterStepNameKey(meterCurrentPatchStep):null;
 if(meterSeriesSteps){
  const isColor0=meterActiveSeriesType==='colors'||meterActiveSeriesType==='saturations';
  const sortedSteps0=isColor0?[...meterSeriesSteps]:[...meterSeriesSteps].sort((a,b)=>(a.ire||0)-(b.ire||0));
  const doneIres=new Set();
  meterReadings.forEach(r=>{if(r.luminance!=null) doneIres.add(meterStepNameKey(r));});
  meterBuildPatchThumbs(sortedSteps0,doneIres,readIre);
 }
 if(meterCurrentPatchStep){
  document.getElementById('meterProgress').style.display='';
  document.getElementById('meterProgressLabel').textContent=(meterCurrentPatchStep.name||meterCurrentPatchStep.ire+'%')+' (reading)';
 }
 try{
  const dtype=getEffectiveDisplayType();
  const rr=getMeterRefreshRate();
  const aio=document.getElementById('meterDisableAIO').checked;
  const delay=parseInt(document.getElementById('meterDelay').value||'2000',10);
  const requestedStep=meterCurrentPatchStep?{...meterCurrentPatchStep}:null;
  const readPayload={display_type:dtype,refresh_rate:rr||undefined,disable_aio:aio,delay_ms:delay};
  if(requestedStep){
   readPayload.patch_r=requestedStep.r;
   readPayload.patch_g=requestedStep.g;
   readPayload.patch_b=requestedStep.b;
   readPayload.patch_size=getMeterPatchSize();
  }
  const initR=await fetchJSON('/api/meter/read',{method:'POST',headers:{'Content-Type':'application/json'},
   body:JSON.stringify(readPayload),_timeoutMs:5000});
  if(initR&&initR.status==='error'){toast(initR.message||'Read failed',true);throw new Error(initR.message);}
  // Poll for result
  const result=await meterPollRead(60000);
  if(result&&result.status==='ok'&&result.readings&&result.readings.length>0){
   const rd=result.readings[0];
   updateLiveReading(rd);
   // If a series is loaded and a patch is selected, store reading in series results
   if(meterSeriesSteps&&requestedStep){
    meterStampReadingStepMeta(rd,requestedStep);
    // Replace existing reading for this patch or add new
    const idx=meterReadings.findIndex(r=>r.ire===rd.ire&&r.r_code===rd.r_code&&r.g_code===rd.g_code&&r.b_code===rd.b_code);
    if(idx>=0) meterReadings[idx]=rd; else meterReadings.push(rd);
    // Auto-detect white reference
    const white=meterReadings.find(r=>r.ire===100&&r.r_code===r.g_code&&r.g_code===r.b_code);
    if(white) meterWhiteReading=white;
    // Update charts and thumbnails
    const completedIres=new Set();
    meterReadings.forEach(r=>{if(r.luminance!=null) completedIres.add(meterStepNameKey(r));});
    const isColor=meterActiveSeriesType==='colors'||meterActiveSeriesType==='saturations';
    const sorted=isColor?[...meterReadings]:[...meterReadings].sort((a,b)=>(a.ire||0)-(b.ire||0));
    drawAllCharts(sorted);
    meterCacheSeriesState('complete');
    const sortedSteps=isColor?[...meterSeriesSteps]:[...meterSeriesSteps].sort((a,b)=>(a.ire||0)-(b.ire||0));
    meterBuildPatchThumbs(sortedSteps,completedIres,null);
   }
   toast('Reading: '+rd.luminance.toFixed(2)+' cd/m\\u00B2');
  } else {
   toast(result&&result.message?result.message:'Measurement failed',true);
  }
 }catch(e){toast('Meter read error: '+e.message,true);}
 document.getElementById('meterReadOnce').innerHTML='&#9679; Read Once';
 meterUpdateReadButtons();
 document.getElementById('meterDot').style.background=meterDetected?'var(--green)':'var(--text2)';
 if(meterCurrentPatchStep){
  document.getElementById('meterProgressLabel').textContent=meterCurrentPatchStep.name||meterCurrentPatchStep.ire+'%';
 }
 // Always clear the \"reading\" pulse once Read Once returns (success or error).
 if(meterSeriesSteps){
  const isColorE=meterActiveSeriesType==='colors'||meterActiveSeriesType==='saturations';
  const sortedStepsE=isColorE?[...meterSeriesSteps]:[...meterSeriesSteps].sort((a,b)=>(a.ire||0)-(b.ire||0));
  const doneE=new Set();
  meterReadings.forEach(r=>{if(r.luminance!=null) doneE.add(meterStepNameKey(r));});
  meterBuildPatchThumbs(sortedStepsE,doneE,null);
 }
}

async function meterPollRead(timeoutMs){
 const start=Date.now();
 // Tiny initial delay so the backend has time to write the 'measuring' marker
 // before we poll. Then poll quickly — finer than the wrapper's own poll
 // granularity gives diminishing returns, but 200ms keeps UI responsiveness.
 await new Promise(r=>setTimeout(r,100));
 while(Date.now()-start<timeoutMs){
  try{
   const r=await fetchJSON('/api/meter/read/result',{_timeoutMs:5000});
   if(r&&r.status!=='measuring') return r;
  }catch(e){}
  await new Promise(r=>setTimeout(r,200));
 }
 return {status:'error',message:'Timeout waiting for reading'};
}

function meterToggleContinuous(){
 if(meterContinuousActive){
  meterStopContinuous();
 } else {
  // Enter manual continuous mode and cut off any leftover series state.
  meterSharedSeriesId=null;
  meterSeriesRunning=false;
  if(meterSeriesPolling){
   clearInterval(meterSeriesPolling);
   meterSeriesPolling=null;
  }
  fetchJSON('/api/meter/stop',{method:'POST',_quiet:true,_timeoutMs:5000});
  // Continuous is its own toggle; don't show the series Stop button here.
  document.getElementById('meterStopBtn').style.display='none';
  meterContinuousActive=true;
  document.getElementById('meterContinuous').classList.add('btn-success');
  document.getElementById('meterContinuous').classList.remove('btn-secondary');
  meterContinuousLoop();
 }
}

async function meterContinuousLoop(){
 if(!meterContinuousActive) return;
 if(meterSeriesRunning){toast('Series scan is running',true);meterStopContinuous();return;}
 document.getElementById('meterDot').style.background='var(--orange)';
 // Pulse ONLY the selected thumb during continuous reads.
 const contIre=meterCurrentPatchStep?meterStepNameKey(meterCurrentPatchStep):null;
 if(meterSeriesSteps){
  const isColorC=meterActiveSeriesType==='colors'||meterActiveSeriesType==='saturations';
  const sortedStepsC=isColorC?[...meterSeriesSteps]:[...meterSeriesSteps].sort((a,b)=>(a.ire||0)-(b.ire||0));
  const doneC=new Set();
  meterReadings.forEach(r=>{if(r.luminance!=null) doneC.add(meterStepNameKey(r));});
  meterBuildPatchThumbs(sortedStepsC,doneC,contIre);
 }
 if(meterCurrentPatchStep){
  document.getElementById('meterProgress').style.display='';
  document.getElementById('meterProgressLabel').textContent=(meterCurrentPatchStep.name||meterCurrentPatchStep.ire+'%')+' (reading)';
 }
 try{
  const dtype=getEffectiveDisplayType();
  const rr=getMeterRefreshRate();
  const aio=document.getElementById('meterDisableAIO').checked;
  const delay=parseInt(document.getElementById('meterDelay').value||'2000',10);
  const requestedStep=meterCurrentPatchStep?{...meterCurrentPatchStep}:null;
  const readPayload={display_type:dtype,refresh_rate:rr||undefined,disable_aio:aio,delay_ms:delay};
  if(requestedStep){
   readPayload.patch_r=requestedStep.r;
   readPayload.patch_g=requestedStep.g;
   readPayload.patch_b=requestedStep.b;
   readPayload.patch_size=getMeterPatchSize();
  }
  const initR=await fetchJSON('/api/meter/read',{method:'POST',headers:{'Content-Type':'application/json'},
   body:JSON.stringify(readPayload),_timeoutMs:5000});
  if(initR&&initR.status==='error'){meterStopContinuous();return;}
  const r=await meterPollRead(60000);
  if(r&&r.status==='ok'&&r.readings&&r.readings.length>0){
   const rd=r.readings[0];
   updateLiveReading(rd);
   const stampStep=requestedStep;
   if(meterSeriesSteps&&stampStep){
    meterStampReadingStepMeta(rd,stampStep);
    const idx=meterReadings.findIndex(x=>x.ire===rd.ire&&x.r_code===rd.r_code&&x.g_code===rd.g_code&&x.b_code===rd.b_code);
    if(idx>=0) meterReadings[idx]=rd; else meterReadings.push(rd);
    const white=meterReadings.find(x=>x.ire===100&&x.r_code===x.g_code&&x.g_code===x.b_code);
    if(white) meterWhiteReading=white;
    const completedIresC=new Set();
    meterReadings.forEach(x=>{if(x.luminance!=null) completedIresC.add(meterStepNameKey(x));});
    const isColorL=meterActiveSeriesType==='colors'||meterActiveSeriesType==='saturations';
    const sortedL=isColorL?[...meterReadings]:[...meterReadings].sort((a,b)=>(a.ire||0)-(b.ire||0));
    drawAllCharts(sortedL);
    meterCacheSeriesState(meterContinuousActive?'running':'complete');
    const sortedStepsL=isColorL?[...meterSeriesSteps]:[...meterSeriesSteps].sort((a,b)=>(a.ire||0)-(b.ire||0));
    // Keep pulsing on whatever patch is CURRENTLY selected (user may have
    // clicked a different thumb while the read was in flight).
    const nowIre=meterCurrentPatchStep?meterStepNameKey(meterCurrentPatchStep):null;
    meterBuildPatchThumbs(sortedStepsL,completedIresC,nowIre);
   }
  }
 }catch(e){}
 document.getElementById('meterDot').style.background=meterDetected?'var(--green)':'var(--text2)';
 if(meterContinuousActive) meterContinuousTimer=setTimeout(meterContinuousLoop,50);
}

function meterStopContinuous(){
 const wasActive=meterContinuousActive;
 meterContinuousActive=false;
 if(meterContinuousTimer) clearTimeout(meterContinuousTimer);
 meterContinuousTimer=null;
 document.getElementById('meterContinuous').classList.remove('btn-success');
 document.getElementById('meterContinuous').classList.add('btn-secondary');
 document.getElementById('meterStopBtn').style.display='none';
 if(wasActive){
  fetchJSON('/api/meter/stop',{method:'POST',_quiet:true,_timeoutMs:5000});
 }
 document.getElementById('meterDot').style.background=meterDetected?'var(--green)':'var(--text2)';
 if(meterCurrentPatchStep&&!meterSeriesRunning){
  document.getElementById('meterProgressLabel').textContent=meterCurrentPatchStep.name||meterCurrentPatchStep.ire+'%';
 }
 // Clear continuous-read pulse.
 if(meterSeriesSteps){
  const isColorCS=meterActiveSeriesType==='colors'||meterActiveSeriesType==='saturations';
  const sortedStepsCS=isColorCS?[...meterSeriesSteps]:[...meterSeriesSteps].sort((a,b)=>(a.ire||0)-(b.ire||0));
  const doneCS=new Set();
  meterReadings.forEach(r=>{if(r.luminance!=null) doneCS.add(meterStepNameKey(r));});
  meterBuildPatchThumbs(sortedStepsCS,doneCS,null);
 }
}

function meterStop(){
 meterStopContinuous();
 if(meterSeriesPolling){clearInterval(meterSeriesPolling);meterSeriesPolling=null;}
 meterSeriesRunning=false;
 fetchJSON('/api/meter/stop',{method:'POST',_quiet:true,_timeoutMs:5000});
 document.getElementById('meterStopBtn').style.display='none';
 document.getElementById('meterReadSeriesBtn').innerHTML='&#9654; Read Series';
 document.getElementById('meterReadSeriesBtn').classList.add('btn-secondary');
 document.getElementById('meterReadSeriesBtn').classList.remove('btn-success');
 // Clear the "currently reading" pulse animation on whichever thumb was last
 // being measured — without this, the last-polled thumb keeps pulsing as if
 // the series is still running.
 if(meterSeriesSteps){
  const isColor=meterActiveSeriesType==='colors'||meterActiveSeriesType==='saturations';
  const sortedSteps=isColor?[...meterSeriesSteps]:[...meterSeriesSteps].sort((a,b)=>(a.ire||0)-(b.ire||0));
  const completedIres=new Set();
  meterReadings.forEach(r=>{if(r.luminance!=null) completedIres.add(meterStepNameKey(r));});
  meterBuildPatchThumbs(sortedSteps,completedIres,null);
 }
 document.getElementById('meterProgress').style.display='none';
}

async function meterResetUSB(){
 toast('Resetting USB...');
 const r=await fetchJSON('/api/meter/reset',{method:'POST',_timeoutMs:15000});
 if(r&&r.status==='ok'){
  toast('USB reset done, checking meter...');
  await new Promise(r=>setTimeout(r,2000));
  await meterCheckStatus();
  if(meterDetected) toast('Meter reconnected!');
  else toast('Meter still not detected after USB reset',true);
 } else {
  toast(r&&r.message?r.message:'USB reset failed',true);
 }
}

let meterSeriesSteps=null; // steps for loaded series
let meterActiveSeriesKey=null; // track which series button is active
let meterActiveSeriesType=null; // series type (greyscale/colors/saturations)
let meterActiveSeriesPoints=null; // series point count
let meterCurrentPatchStep=null; // currently displayed patch step object
let meterSeriesRunning=false; // true when Read Series is actively running
function meterUpdateReadButtons(){
 const hasSelection=meterSelectedThumbIre!=null;
 const hasSeries=meterSeriesSteps&&meterSeriesSteps.length>0;
 const show=hasSeries&&hasSelection&&meterDetected;
 document.getElementById('meterReadOnce').style.display=show?'':'none';
 document.getElementById('meterContinuous').style.display=show?'':'none';
 document.getElementById('meterReadOnce').disabled=!hasSelection||!meterDetected;
 document.getElementById('meterContinuous').disabled=!hasSelection||!meterDetected;
}
function meterUpdateCardMode(){
 const card=document.getElementById('meterCard');
 const title=document.getElementById('meterCardTitle');
 if(!card||!title) return;
 if(meterDetected){
  card.classList.remove('meter-patterns-only');
  title.innerHTML='<span class="drag-handle">&#9776;</span>Meter &amp; Measurements';
 } else {
  card.classList.add('meter-patterns-only');
  title.innerHTML='<span class="drag-handle">&#9776;</span>Test Patterns';
 }
}
function meterResetSeriesButtons(){
 document.querySelectorAll('#meterSeriesBtnRow button').forEach(b=>{
  b.classList.remove('btn-primary');b.classList.add('btn-secondary');
 });
}
// Build steps client-side (mirrors server logic in webui_meter_series_start)
function meterBuildStepsJS(type,points){
 const steps=[];
 if(type==='greyscale'){
  const ires=points===11?[0,10,20,30,40,50,60,70,80,90,100]
   :[0,5,10,15,20,25,30,35,40,45,50,55,60,65,70,75,80,85,90,95,100];
  // Measurement order: 100% first (white reference), then 0%→95% ascending
  const ordered=[100,...ires.filter(v=>v!==100).sort((a,b)=>a-b)];
  ordered.forEach(v=>{
   // Account for signal range when generating code values
   const signalMode=meterChartSignalMode();
   const isDv=signalMode==='dv';
   const isLimited=meterIsLimitedRange();
   const c=isDv
  ? (isLimited?Math.round(16+Math.pow(v/100,1/2.2)*219):Math.round(Math.pow(v/100,1/2.2)*255))
  : (isLimited?Math.round(16+v/100*(235-16)):Math.round(v*255/100));
   steps.push({ire:v,r:c,g:c,b:c,name:v+'%'});
  });
 } else if(type==='colors'){
  steps.push(...meterBuildColorCheckerStepsJS());
 } else if(type==='saturations'){
  ['Red','Green','Blue','Cyan','Magenta','Yellow'].forEach(name=>{
   [25,50,75,100].forEach(sat=>{
    const rgb=meterBuildSaturationTargetLinearRgb(name,sat);
    steps.push({ire:sat,r:meterEncodeSaturationLinear(rgb[0]),g:meterEncodeSaturationLinear(rgb[1]),b:meterEncodeSaturationLinear(rgb[2]),name:name+' '+sat+'%',series_color:name,sat_pct:sat});
   });
  });
 }
 return steps;
}
// Select a series: load thumbnails + display first patch, no reading
function meterSelectSeries(type,points){
 meterStopContinuous();
 if(meterSeriesRunning) meterStop();
 const key=type+'-'+points;
 if(meterActiveSeriesKey===key&&meterReadings&&meterReadings.length>0){
  meterUpdateReadButtons();
  return;
 }
 if(meterActiveSeriesKey&&meterSeriesSteps&&meterSeriesSteps.length>0){
  meterCacheSeriesState(meterSeriesRunning?'running':'complete');
 }
 _selectedColorReadingName=null;
 _colorDetailPinned=false;
 meterCurrentPatchStep=null;
 meterSelectedThumbIre=null;
 document.getElementById('meterLiveReading').style.display='none';
 document.getElementById('meterProgress').style.display='none';
 if(meterRestoreSeriesFromCache(key)){
  meterUpdateReadButtons();
  return;
 }
 // From this point the UI is operating on a local selection, not a
 // recovered shared series snapshot.
 meterSharedSeriesId=null;
 meterReadings=[];
 meterWhiteReading=null;
 meterSeriesSteps=null;
 meterActiveSeriesType=type;
 meterActiveSeriesPoints=points;
 meterLastChartCount=0;
 // Highlight the clicked button
 meterResetSeriesButtons();
 meterActiveSeriesKey=key;
 const activeBtn=document.querySelector('#meterSeriesBtnRow button[data-series="'+key+'"]');
 if(activeBtn){activeBtn.classList.remove('btn-secondary');activeBtn.classList.add('btn-primary');}
 // Build steps
 const steps=meterBuildStepsJS(type,points);
 meterSeriesSteps=steps;
 // Sort for display
 const sortedSteps=(type==='colors'||type==='saturations')?[...steps]:[...steps].sort((a,b)=>(a.ire||0)-(b.ire||0));
 // Show UI — toggle greyscale vs color chart sections
 if(type==='greyscale'){
  document.getElementById('chartsGreyscaleWrap').style.display='';
  document.getElementById('chartsColorWrap').style.display='none';
 } else {
  document.getElementById('chartsGreyscaleWrap').style.display='none';
  document.getElementById('chartsColorWrap').style.display='';
 }
 document.getElementById('meterCharts').style.display='';
 document.getElementById('meterExportRow').style.display='';
 document.getElementById('meterReadSeriesBtn').style.display='';
 document.getElementById('meterThumbsRow').style.display='';
 document.getElementById('meterProgress').style.display='none';
 // Build thumbnails and pre-populate all charts
 meterBuildPatchThumbs(sortedSteps,null);
 drawAllChartsPreset(sortedSteps);
 // No default patch selection — user must click a thumbnail
 meterUpdateThumbStyles(document.getElementById('meterPatchThumbs'),null,null);
 meterUpdateReadButtons();
 toast(type.charAt(0).toUpperCase()+type.slice(1)+' '+steps.length+'pt loaded');
}
// Display a patch on PGenerator without reading
async function meterDisplayPatch(step){
 meterCurrentPatchStep=step;
 const psize=getMeterPatchSize();
 await fetchJSON('/api/pattern',{method:'POST',headers:{'Content-Type':'application/json'},
  body:JSON.stringify({name:'patch',r:step.r,g:step.g,b:step.b,size:psize,input_max:255}),_timeoutMs:5000});
}
// Run full automated series (Read Series button)
async function meterRunSeries(){
 if(!meterDetected){toast('No meter detected',true);return;}
 if(!meterSeriesSteps||!meterActiveSeriesType){toast('Select a series first',true);return;}
 meterStopContinuous();
 meterSelectedThumbIre=null;
 meterReadings=[];
 meterWhiteReading=null;
 meterSeriesRunning=true;
 meterLastChartCount=0;
 document.getElementById('meterProgress').style.display='';
 document.getElementById('meterStopBtn').style.display='';
 document.getElementById('meterReadSeriesBtn').innerHTML='&#9209; Reading Series';
 document.getElementById('meterReadSeriesBtn').classList.remove('btn-secondary');
 document.getElementById('meterReadSeriesBtn').classList.add('btn-success');
 const dtype=getEffectiveDisplayType();
 const delay=parseInt(document.getElementById('meterDelay').value);
 const psize=getMeterPatchSize();
 const r=await fetchJSON('/api/meter/series',{method:'POST',headers:{'Content-Type':'application/json'},
  body:JSON.stringify({type:meterActiveSeriesType,points:meterActiveSeriesPoints,display_type:dtype,target_gamut:(document.getElementById('meterTargetGamut')||{}).value||'auto',delay_ms:delay,patch_size:psize,signal_range:getVal('rgb_quant_range'),patch_insert:document.getElementById('meterPatchInsert').checked,refresh_rate:getMeterRefreshRate()||undefined,disable_aio:document.getElementById('meterDisableAIO').checked}),_timeoutMs:10000});
 if(!r||r.status!=='started'){
  toast(r&&r.message?r.message:'Failed to start series',true);
  meterSeriesRunning=false;
  document.getElementById('meterReadSeriesBtn').innerHTML='&#9654; Read Series';
  document.getElementById('meterReadSeriesBtn').classList.add('btn-secondary');
  document.getElementById('meterReadSeriesBtn').classList.remove('btn-success');
  return;
 }
 toast('Series started: '+r.total_steps+' steps');
 if(meterSeriesPolling) clearInterval(meterSeriesPolling);
 meterSeriesPolling=setInterval(meterPollSeries,2000);
}

async function meterPollSeries(){
 const r=await fetchJSON('/api/meter/series/status',{_quiet:true,_timeoutMs:5000});
 if(!r) return;
 if(r.status==='cleared'){
  if(meterSeriesPolling){
   clearInterval(meterSeriesPolling);
   meterSeriesPolling=null;
  }
  meterSeriesRunning=false;
  meterSharedSeriesId=null;
  meterApplyClearedState(false);
  return;
 }
 // If the UI is no longer in active series mode, ignore ALL series snapshots
 // so stale pollers can never overwrite newer Read Once / Continuous data.
 if(!meterSeriesRunning){
  if(meterSeriesPolling){
   clearInterval(meterSeriesPolling);
   meterSeriesPolling=null;
  }
  return;
 }
 // Build set of completed IRE values for thumbnail highlighting
 const completedIres=new Set();
 let currentIre=null;

 if(r.readings&&r.readings.length>0) {
  meterReadings=meterAttachSeriesMeta(r.readings);
  // Only set white reference from actual 100% reading — never use
  // "brightest so far" during a running series, because that changes
  // every poll cycle and causes all ΔE / RGB balance values to shift.
  const white=r.readings.find(rd=>rd.ire===100&&rd.r_code===rd.g_code&&rd.g_code===rd.b_code&&rd.luminance!=null);
  if(white) meterWhiteReading=white;
  // If we don't yet have an actual 100% measurement, allow a configured
  // target luminance (config.max_luma) as a synthetic white reference so
  // ΔE/RGB can be computed per-reading consistently (matches HCFR style).
  if(!meterWhiteReading && config && config.max_luma){
   const maxL=parseFloat(config.max_luma);
   if(maxL>0){
    meterWhiteReading={
     X:D65.X*maxL,
     Y:maxL,
     Z:D65.Z*maxL,
     luminance:maxL,
     x:D65.x,
     y:D65.y,
     cct:null
    };
   }
  }
  r.readings.forEach(rd=>{if(rd.luminance!=null) completedIres.add(meterStepNameKey(rd));});
  // Only redraw charts when reading count changes (avoids flicker)
  const validCount=r.readings.filter(rd=>rd.luminance!=null).length;
  if(validCount!==meterLastChartCount){
   meterLastChartCount=validCount;
   const isColor=meterActiveSeriesType==='colors'||meterActiveSeriesType==='saturations';
   const sorted=isColor?[...r.readings]:[...r.readings].sort((a,b)=>(a.ire||0)-(b.ire||0));
   drawAllCharts(sorted);
   meterCacheSeriesState(r.status||'running');
  }
 }

 if(r.total_steps>0){
  const label=r.current_name||('Step '+r.current_step+'/'+r.total_steps);
  document.getElementById('meterProgressLabel').textContent=label;
  // Parse current IRE from name like "70% (reading)"
  currentIre=r.current_name||null;
 }

 // Update patch thumbnails with completion state
 if(meterSeriesSteps){
  const isColor2=meterActiveSeriesType==='colors'||meterActiveSeriesType==='saturations';
  const sortedSteps=isColor2?[...meterSeriesSteps]:[...meterSeriesSteps].sort((a,b)=>(a.ire||0)-(b.ire||0));
  meterBuildPatchThumbs(sortedSteps,completedIres,currentIre);
 }

 // Update live reading with latest valid reading
 if(r.readings&&r.readings.length>0){
  const lastValid=[...r.readings].reverse().find(rd=>rd.luminance!=null);
  if(lastValid) updateLiveReading(lastValid);
 }

 if(r.status==='complete'||r.status==='cancelled'||r.status==='error'){
  clearInterval(meterSeriesPolling);
  meterSeriesPolling=null;
  meterSeriesRunning=false;
  document.getElementById('meterStopBtn').style.display='none';
  document.getElementById('meterDot').style.background=meterDetected?'var(--green)':'var(--text2)';
  document.getElementById('meterReadSeriesBtn').innerHTML='&#9654; Read Series';
  document.getElementById('meterReadSeriesBtn').classList.add('btn-secondary');
  document.getElementById('meterReadSeriesBtn').classList.remove('btn-success');
  // Clear the "currently reading" pulse on the last-polled thumb.
  if(meterSeriesSteps){
   const isColor3=meterActiveSeriesType==='colors'||meterActiveSeriesType==='saturations';
   const sortedSteps2=isColor3?[...meterSeriesSteps]:[...meterSeriesSteps].sort((a,b)=>(a.ire||0)-(b.ire||0));
   meterBuildPatchThumbs(sortedSteps2,completedIres,null);
  }
  document.getElementById('meterProgress').style.display='none';
  toast(r.status==='complete'?'Series complete!':r.status==='error'?'Series error: '+(r.current_name||'process died'):'Series cancelled');
 }
}

let meterSelectedThumbIre=null;
let meterThumbsBuilt=false; // track if thumbnails are already built for current series
function meterBuildPatchThumbs(sortedSteps,completedIres,currentIre){
 const container=document.getElementById('meterPatchThumbs');
 if(!container) return;
 const needsRebuild=(container.children.length!==sortedSteps.length)||sortedSteps.some((step,idx)=>{
  const child=container.children[idx];
  const isGrey=step.r===step.g&&step.g===step.b;
  const label=isGrey?(step.ire+'%'):(step.name||'');
  return !child||(child.dataset.key||'')!==meterStepNameKey(step)||(child.textContent||'')!==label;
 });
 if(needsRebuild){
  container.innerHTML='';
  meterThumbsBuilt=true;
  sortedSteps.forEach(step=>{
   const thumb=document.createElement('div');
   const isGrey=step.r===step.g&&step.g===step.b;
   const bgColor=meterPreviewColorForStep(step);
   const textColor=meterContrastTextColor(bgColor);
   const textShadow=textColor==='#eee'?'0 1px 2px rgba(0,0,0,.75)':'0 1px 1px rgba(255,255,255,.18)';
   const label=isGrey?(step.ire+'%'):(step.name||'');
   thumb.style.cssText='flex:1;display:flex;align-items:center;justify-content:center;height:28px;border-radius:3px;cursor:pointer;box-sizing:border-box;font-size:8px;font-weight:700;user-select:none;transition:box-shadow .2s;color:'+textColor+';background:'+bgColor+';text-align:center;line-height:1.1;padding:0 2px;text-shadow:'+textShadow;
   thumb.textContent=label;
   thumb.dataset.ire=step.ire;
   thumb.dataset.r=step.r;
   thumb.dataset.g=step.g;
   thumb.dataset.b=step.b;
   thumb.dataset.name=step.name||'';
  thumb.dataset.key=meterStepNameKey(step);
   thumb.addEventListener('click',function(){
    if(meterSeriesRunning) return;
    const isColor=meterActiveSeriesType==='colors'||meterActiveSeriesType==='saturations';
    if(isColor){
     // For color series, toggle by name (multiple steps share same ire)
     const wasSelected=_selectedColorReadingName===step.name;
     if(wasSelected){
      _selectedColorReadingName=null;
      showColorReadingDetail(null);
     } else {
      // Find matching reading if we have one
      const rd=meterReadings?meterReadings.find(r=>r.name===step.name):null;
      if(rd) showColorReadingDetail(rd);
      else colorHighlightThumb(step.name);
     }
     meterDisplayPatch(step);
     document.getElementById('meterLiveReading').style.display='';
     document.getElementById('meterProgress').style.display='';
     document.getElementById('meterProgressLabel').textContent=step.name||step.ire+'%';
    } else {
     meterSelectedThumbIre=(meterSelectedThumbIre===step.ire)?null:step.ire;
     meterUpdateThumbStyles(container,completedIres,currentIre);
     if(meterSelectedThumbIre!=null){
      meterDisplayPatch(step);
      document.getElementById('meterLiveReading').style.display='';
      document.getElementById('meterProgress').style.display='';
      document.getElementById('meterProgressLabel').textContent=step.name||step.ire+'%';
     } else {
      document.getElementById('meterProgress').style.display='none';
     }
    }
    meterUpdateReadButtons();
   });
   container.appendChild(thumb);
  });
 }
 meterUpdateThumbStyles(container,completedIres,currentIre);
}
function meterUpdateThumbStyles(container,completedIres,currentIre){
 const hasReadings=completedIres&&completedIres.size>0;
 for(let i=0;i<container.children.length;i++){
  const thumb=container.children[i];
  const ire=parseInt(thumb.dataset.ire);
  const key=thumb.dataset.key||thumb.dataset.name||String(ire);
  const done=completedIres&&completedIres.has(key);
  // All thumbs fully visible always; completed ones get a checkmark overlay
  thumb.style.opacity='1';
  const isReading=(currentIre!=null&&key===currentIre);
  const isSelected=(meterSelectedThumbIre!=null&&ire===meterSelectedThumbIre);
  if(isReading){
   thumb.style.boxShadow='';
   thumb.style.animation='thumbPulse 1s ease-in-out infinite';
   thumb.style.zIndex='1';
  } else if(isSelected){
   thumb.style.animation='none';
   thumb.style.boxShadow='0 0 0 3px #fff';
   thumb.style.zIndex='1';
  } else if(done){
   thumb.style.animation='none';
   thumb.style.boxShadow='0 0 0 2px #4caf50';
   thumb.style.zIndex='';
  } else {
   thumb.style.animation='none';
   thumb.style.boxShadow='none';
   thumb.style.zIndex='';
  }
 }
}

// Pre-populate ALL charts with grids and placeholder points before readings
function drawAllChartsPreset(sortedSteps){
 if(meterActiveSeriesType==='greyscale'||!meterActiveSeriesType){
  const gsSteps=sortedSteps.filter(s=>s.r===s.g&&s.g===s.b);
  if(gsSteps.length===0) return;
  drawRGBChartPreset(gsSteps);
  drawDeltaEPreset(gsSteps);
  drawDeltaE2000Preset(gsSteps);
  drawEOTFPreset(gsSteps);
  drawGammaPreset(gsSteps);
 } else {
  drawCIEChartPreset(sortedSteps);
  drawColorDeltaE2000Preset(sortedSteps);
  const wrap=document.getElementById('colorReadingsTableWrap');
  if(wrap) wrap.style.display='none';
  const avgWrap=document.getElementById('colorSeriesAveragesWrap');
  if(avgWrap) avgWrap.style.display='none';
  _selectedColorReadingName=null;
  showColorReadingDetail(null);
 }
}
function drawRGBChartPreset(gsSteps){
 const ctx=getChartCtx('chartRGB');
 if(!ctx) return;
 if(gsSteps.length===0) return;
 const yMin=95,yMax=105;
 const chart=drawChartGrid(ctx,{
  xSteps:gsSteps.length-1||1,ySteps:4,
  xLabel:(i,n)=>i<gsSteps.length?gsSteps[i].ire+'%':'',
  yLabel:(i,n)=>(yMin+(yMax-yMin)*i/n).toFixed(0)
 });
 const refY=(100-yMin)/(yMax-yMin);
 drawDashedLine(ctx,chart,[[0,refY],[1,refY]],'#555');
 // Placeholder dots at 100 for each point
 const pts=gsSteps.map((s,i)=>[gsSteps.length>1?i/(gsSteps.length-1):0.5,refY]);
 drawDots(ctx,chart,pts,'#33333380',3);
}
function drawDeltaEPreset(gsSteps){
 const ctx=getChartCtx('chartDeltaE');
 if(!ctx) return;
 const yMax=5;
 const chart=drawChartGrid(ctx,{
  xSteps:gsSteps.length-1||1,ySteps:5,
  xLabel:(i)=>i<gsSteps.length?gsSteps[i].ire+'%':'',
  yLabel:(i,n)=>(yMax*i/n).toFixed(1)
 });
 if(1/yMax<=1) drawDashedLine(ctx,chart,[[0,1/yMax],[1,1/yMax]],'#4caf5080');
 if(3/yMax<=1) drawDashedLine(ctx,chart,[[0,3/yMax],[1,3/yMax]],'#ff980080');
}
function drawEOTFPreset(gsSteps){
 const ctx=getChartCtx('chartEOTF');
 if(!ctx) return;
 const Lw=(meterWhiteReading&&meterWhiteReading.luminance>0)?meterWhiteReading.luminance:100;
 const refPeak=meterChartIsHdr()?meterChartHdrPeak():Lw;
 const measuredRatio=refPeak>0?(Lw/refPeak):1;
 const yTop=Math.max(1,Math.ceil(Math.max(1,measuredRatio)*1.05*10)/10);
 const chart=drawChartGrid(ctx,{
  xSteps:10,ySteps:5,
  xLabel:(i)=>(i*10)+'',
  yLabel:(i,n)=>(yTop*i/n).toFixed(1)
 });
 const tgtPts=meterGreyTargetChartPoints(gsSteps,Lw,0,refPeak*yTop);
 drawDashedLine(ctx,chart,tgtPts,'#666');
 const pts=gsSteps.map(s=>{
  const v=s.ire/100;
  return [v,meterGreyTargetChartValue(s.ire,Lw,0,s.r)/refPeak/yTop];
 });
 drawDots(ctx,chart,pts,'#33333380',3);
}
function drawGammaPreset(gsSteps){
 const ctx=getChartCtx('chartGamma');
 if(!ctx) return;
 const Lw=(meterWhiteReading&&meterWhiteReading.luminance>0)?meterWhiteReading.luminance:100;
 const refPeak=meterChartIsHdr()?meterChartHdrPeak():Lw;
 // Luminance preset: absolute cd/m²
 const yTop=Math.ceil(Math.max(Lw,refPeak)*1.1/10)*10||Math.max(Lw,refPeak);
 const chart=drawChartGrid(ctx,{
  xSteps:10,ySteps:5,
  xLabel:(i)=>(i*10)+'',
  yLabel:(i,n)=>(yTop*i/n).toFixed(0)
 });
 // Target EOTF curve (absolute)
 const tgtPts=meterGreyTargetChartPoints(gsSteps,Lw,0,yTop);
 drawDashedLine(ctx,chart,tgtPts,'#666');
 const pts=gsSteps.map(s=>{
  const v=s.ire/100;
  return [v,meterGreyTargetChartValue(s.ire,Lw,0,s.r)/yTop];
 });
 drawDots(ctx,chart,pts,'#33333380',3);
}

///////////////////////////////////////////////
//           Canvas Chart Drawing            //
///////////////////////////////////////////////
function drawAllCharts(readings){
 if(!readings||readings.length===0) return;
 if(meterActiveSeriesType==='colors'||meterActiveSeriesType==='saturations'){
  // Color/saturation series — CIE chromaticity + color ΔE + readings table
  const cr=readings.filter(r=>r.luminance!=null&&r.luminance>=0);
  if(cr.length>0){
   drawCIEChart(cr);
   drawColorDeltaE2000Chart(cr);
   drawColorReadingsTable(cr);
   colorChartRegisterInteraction(cr);
   if(_colorDetailPinned&&_selectedColorReadingName){
    const sel=cr.find(r=>r.name===_selectedColorReadingName);
    if(sel) showColorReadingDetail(sel,{pin:true});
    else showColorReadingDetail(cr[cr.length-1],{pin:false});
   } else {
    showColorReadingDetail(cr[cr.length-1],{pin:false});
   }
  }
  return;
 }
 // Greyscale series
 const allSteps=meterSeriesSteps?[...meterSeriesSteps].filter(s=>s.r===s.g&&s.g===s.b).sort((a,b)=>a.ire-b.ire):null;
 const readingMap={};
 readings.forEach(r=>{if(r.luminance!=null&&r.r_code===r.g_code&&r.g_code===r.b_code) readingMap[r.ire]=r;});
 const gs=readings.filter(r=>r.luminance!=null&&r.luminance>=0&&r.r_code===r.g_code&&r.g_code===r.b_code)
  .sort((a,b)=>(a.ire||0)-(b.ire||0));
 if(gs.length>0){
  drawRGBChart(gs,allSteps,readingMap);
  drawEOTFChart(gs,allSteps,readingMap);
  drawGammaChart(gs,allSteps,readingMap);
  drawDeltaEChart(gs,allSteps,readingMap);
  drawDeltaE2000Chart(gs,allSteps,readingMap);
  chartRegisterInteraction();
 }
}

function getChartCtx(id){
 const c=document.getElementById(id);
 if(!c) return null;
 const dpr=window.devicePixelRatio||1;
 const rect=c.getBoundingClientRect();
 // Guard: if canvas not visible (VS Code webview, hidden panel), skip
 if(rect.width<10||rect.height<10) return null;
 const newW=Math.round(rect.width*dpr), newH=Math.round(rect.height*dpr);
 // Only resize canvas buffer if dimensions actually changed (avoids unnecessary clear)
 if(c.width!==newW||c.height!==newH){ c.width=newW; c.height=newH; }
 const ctx=c.getContext('2d');
 ctx.setTransform(dpr,0,0,dpr,0,0);
 ctx.w=rect.width;
 ctx.h=rect.height;
 return ctx;
}

function drawChartGrid(ctx,opts){
 const pad=opts.pad||{t:20,r:15,b:30,l:45};
 const w=ctx.w-pad.l-pad.r, h=ctx.h-pad.t-pad.b;
 const xIn=opts.xInset||0, dw=w-2*xIn;
 // Background
 ctx.fillStyle='#0d0d15';
 ctx.fillRect(0,0,ctx.w,ctx.h);
 // Grid
 ctx.strokeStyle='#1d1d29';
 ctx.lineWidth=1;
 const xSteps=opts.xSteps||10, ySteps=opts.ySteps||5;
 for(let i=0;i<=xSteps;i++){
  const x=pad.l+xIn+dw*(i/xSteps);
  ctx.beginPath();ctx.moveTo(x,pad.t);ctx.lineTo(x,pad.t+h);ctx.stroke();
 }
 for(let i=0;i<=ySteps;i++){
  const y=pad.t+h*(i/ySteps);
  ctx.beginPath();ctx.moveTo(pad.l,y);ctx.lineTo(pad.l+w,y);ctx.stroke();
 }
 // Axes
 ctx.strokeStyle='#3a3a4a';
 ctx.beginPath();ctx.moveTo(pad.l,pad.t);ctx.lineTo(pad.l,pad.t+h);ctx.lineTo(pad.l+w,pad.t+h);ctx.stroke();
 // X labels. When opts.rotateX is set, draw them angled so long names
 // (e.g. "Magenta 100%") don't overlap on dense series.
 ctx.fillStyle='#888898';ctx.font='11px sans-serif';
 if(opts.rotateX){
  for(let i=0;i<=xSteps;i++){
   const lbl=opts.xLabel?opts.xLabel(i,xSteps):(i*100/xSteps).toFixed(0);
   if(!lbl) continue;
   const x=pad.l+xIn+dw*(i/xSteps);
   ctx.save();
   ctx.translate(x,pad.t+h+6);
   ctx.rotate(-Math.PI/4);
   ctx.textAlign='right';
   ctx.fillText(lbl,0,4);
   ctx.restore();
  }
 } else {
  ctx.textAlign='center';
  for(let i=0;i<=xSteps;i++){
   const lbl=opts.xLabel?opts.xLabel(i,xSteps):(i*100/xSteps).toFixed(0);
   ctx.fillText(lbl,pad.l+xIn+dw*(i/xSteps),pad.t+h+14);
  }
 }
 // Y labels
 ctx.textAlign='right';
 for(let i=0;i<=ySteps;i++){
  const lbl=opts.yLabel?opts.yLabel(i,ySteps):'';
  ctx.fillText(lbl,pad.l-4,pad.t+h-h*(i/ySteps)+3);
 }
 return {pad,w,h,dw,toX:v=>pad.l+xIn+v*dw, toY:v=>pad.t+h-v*h};
}

function drawLine(ctx,chart,points,color,width){
 if(points.length<2) return;
 ctx.strokeStyle=color;ctx.lineWidth=width||1.5;
 ctx.beginPath();
 points.forEach((p,i)=>{
  const x=chart.toX(p[0]),y=chart.toY(p[1]);
  if(i===0) ctx.moveTo(x,y); else ctx.lineTo(x,y);
 });
 ctx.stroke();
}

function drawDots(ctx,chart,points,color,radius){
 ctx.fillStyle=color;
 points.forEach(p=>{
  ctx.beginPath();
  ctx.arc(chart.toX(p[0]),chart.toY(p[1]),radius||2.5,0,Math.PI*2);
  ctx.fill();
 });
}

function drawDashedLine(ctx,chart,points,color){
 ctx.setLineDash([4,4]);
 drawLine(ctx,chart,points,color,1);
 ctx.setLineDash([]);
}

function drawRGBChart(gs,allSteps,readingMap){
 const ctx=getChartCtx('chartRGB');
 if(!ctx) return;
 let effectiveWhiteRGB=meterWhiteReading;
 // For manual single reads before 100% is measured, still plot RGB balance
 // using either configured target luminance or a white level inferred from
 // the brightest available grey patch.
 if((!effectiveWhiteRGB||effectiveWhiteRGB.Y<=0) && config && config.max_luma){
  const maxL=parseFloat(config.max_luma);
  if(maxL>0){
   effectiveWhiteRGB={X:D65.X*maxL,Y:maxL,Z:D65.Z*maxL,luminance:maxL,x:D65.x,y:D65.y,cct:null};
  }
 }
 if((!effectiveWhiteRGB||effectiveWhiteRGB.Y<=0) && gs && gs.length>0){
  const brightest=[...gs].sort((a,b)=>(b.luminance||0)-(a.luminance||0))[0];
  if(brightest && (brightest.luminance||brightest.Y||0)>0){
   let inferredYw=brightest.luminance||brightest.Y;
   const ire=Math.max(1,brightest.ire||100);
   if(ire<100){
    const frac=Math.max(targetEotf(ire/100,1,0),0.02);
    inferredYw=inferredYw/frac;
   }
   effectiveWhiteRGB={X:D65.X*inferredYw,Y:inferredYw,Z:D65.Z*inferredYw,luminance:inferredYw,x:D65.x,y:D65.y,cct:null};
  }
 }
 if(!effectiveWhiteRGB||effectiveWhiteRGB.Y<=0){
  if(allSteps) drawRGBChartPreset(allSteps);
  return;
 }
 // Use all series steps for x-axis (include 0%)
 const xSteps=allSteps?[...allSteps]:gs.sort((a,b)=>a.ire-b.ire);
 if(xSteps.length===0) return;
 // Compute RGB balance for all available readings (include 0%)
 const inclLum=meterIncludeLum();
 const balMap={};
 gs.forEach(rd=>{balMap[rd.ire]=rgbBalance(rd,effectiveWhiteRGB,inclLum);});
 // Auto-scale Y axis based on actual data — zoom in tight
 const allVals=Object.values(balMap).flatMap(b=>[b.R,b.G,b.B]);
 let yMin,yMax;
 if(allVals.length>0){
  const dataMin=Math.min(...allVals),dataMax=Math.max(...allVals);
  const margin=Math.max(1,(dataMax-dataMin)*0.15);
  yMin=Math.floor((dataMin-margin)*2)/2;
  yMax=Math.ceil((dataMax+margin)*2)/2;
  // Ensure 100 is always visible
  if(yMin>99) yMin=99; if(yMax<101) yMax=101;
  if(yMax-yMin<4){const mid=(yMin+yMax)/2;yMin=mid-2;yMax=mid+2;}
 } else {yMin=95;yMax=105;}
 const chart=drawChartGrid(ctx,{
  xInset:15,
  xSteps:xSteps.length-1||1,ySteps:4,
  xLabel:(i)=>i<xSteps.length?xSteps[i].ire+'%':'',
  yLabel:(i,n)=>(yMin+(yMax-yMin)*i/n).toFixed(1)
 });
 // Reference line at 100%
 const refY=(100-yMin)/(yMax-yMin);
 drawDashedLine(ctx,chart,[[0,refY],[1,refY]],'#555');
 // Plot all x-axis points: measured = colored, missing = grey placeholder
 const rPts=[],gPts=[],bPts=[],emptyPts=[];
 xSteps.forEach((step,idx)=>{
  const x=xSteps.length>1?idx/(xSteps.length-1):0.5;
  const bal=balMap[step.ire];
  if(bal){
   rPts.push([x,Math.max(0,Math.min(1,(bal.R-yMin)/(yMax-yMin)))]);
   gPts.push([x,Math.max(0,Math.min(1,(bal.G-yMin)/(yMax-yMin)))]);
   bPts.push([x,Math.max(0,Math.min(1,(bal.B-yMin)/(yMax-yMin)))]);
  } else {
   emptyPts.push([x,refY]);
  }
 });
 // Draw placeholder dots for missing
 drawDots(ctx,chart,emptyPts,'#33333380',3);
 // Draw measured lines and dots
 if(rPts.length>1){drawLine(ctx,chart,rPts,'#f44',2);drawLine(ctx,chart,gPts,'#4caf50',2);drawLine(ctx,chart,bPts,'#42a5f5',2);}
 drawDots(ctx,chart,rPts,'#f44');
 drawDots(ctx,chart,gPts,'#4caf50');
 drawDots(ctx,chart,bPts,'#42a5f5');
 // R/G/B label at right
 if(rPts.length>0){
  const last=rPts.length-1;
  ctx.font='11px sans-serif';ctx.textAlign='left';
  const xOff=chart.toX(rPts[last][0])+6;
  ctx.fillStyle='#f44';ctx.fillText('R',xOff,chart.toY(rPts[last][1])+3);
  ctx.fillStyle='#4caf50';ctx.fillText('G',xOff,chart.toY(gPts[last][1])+3);
  ctx.fillStyle='#42a5f5';ctx.fillText('B',xOff,chart.toY(bPts[last][1])+3);
 }
}

function drawEOTFChart(gs,allSteps,readingMap){
 const ctx=getChartCtx('chartEOTF');
 if(!ctx) return;
 const sorted=[...gs].sort((a,b)=>a.ire-b.ire);
 const Lw=sorted.reduce((mx,r)=>Math.max(mx,r.luminance||0),0);
 const blacks=sorted.filter(r=>r.ire<=5&&r.luminance!=null);
 const Lb=blacks.length>0?Math.min(...blacks.map(r=>r.luminance)):0;
 const refPeak=meterChartIsHdr()?meterChartHdrPeak():Lw;
 const targetPeak=meterChartIsDv()?meterChartDvClipPeak():refPeak;
 if(refPeak<=0) return;
 const measuredRatio=Lw>0?(Lw/refPeak):1;
 const yTop=Math.max(1,Math.ceil(Math.max(1,measuredRatio)*1.05*10)/10);
 const chart=drawChartGrid(ctx,{
  xSteps:10,ySteps:5,
  xLabel:(i)=>(i*10)+'',
  yLabel:(i,n)=>(yTop*i/n).toFixed(1)
 });
 const targetSteps=allSteps||sorted.map(r=>({ire:r.ire||0}));
 const tgtPts=meterGreyTargetChartPoints(targetSteps,Lw,Lb,refPeak*yTop);
 drawDashedLine(ctx,chart,tgtPts,'#666');
 if(allSteps){
  const emptyPts=allSteps.filter(s=>!readingMap[s.ire]).map(s=>{
   const v=s.ire/100;
   return [v,meterGreyTargetChartValue(s.ire,Lw,Lb)/refPeak/yTop];
  });
  drawDots(ctx,chart,emptyPts,'#33333380',3);
 }
 const valid=sorted.filter(r=>r.luminance!=null && r.luminance>=0);
 const mPts=valid.map(r=>[r.ire/100,(r.luminance/refPeak)/yTop]);
 if(mPts.length>1) drawLine(ctx,chart,mPts,'#ffeb3b',2);
 drawDots(ctx,chart,mPts,'#ffeb3b',3);
 // Show max luminance annotation (Calman style)
 if(meterChartIsHdr()){
  ctx.fillStyle='#aaa';ctx.font='11px sans-serif';ctx.textAlign='left';
  ctx.fillText(meterChartIsDv()?'Target: '+refPeak.toFixed(0)+' cd/m\u00B2  Clip: '+targetPeak.toFixed(0)+' cd/m\u00B2':'Target: '+refPeak.toFixed(0)+' cd/m\u00B2',chart.pad.l,chart.pad.t+14);
 }
 ctx.fillStyle='#ffeb3b';ctx.font='11px sans-serif';ctx.textAlign='right';
 ctx.fillText('Max: '+Lw.toFixed(1)+' cd/m\u00B2',ctx.w-chart.pad.r,chart.pad.t+14);
}

function drawGammaChart(gs,allSteps,readingMap){
 const ctx=getChartCtx('chartGamma');
 if(!ctx) return;
 const sorted=[...gs].sort((a,b)=>a.ire-b.ire);
 const Lw=sorted.reduce((mx,r)=>Math.max(mx,r.luminance||0),0);
 const blacks=sorted.filter(r=>r.ire<=5&&r.luminance!=null);
 const Lb=blacks.length>0?Math.min(...blacks.map(r=>r.luminance)):0;
 const refPeak=meterChartIsHdr()?meterChartHdrPeak():Lw;
 const targetPeak=meterChartIsDv()?meterChartDvClipPeak():refPeak;
 if(Math.max(Lw,targetPeak)<=0) return;
 const maxLumBase=Math.max(Lw,targetPeak);
 const yTop=Math.ceil(maxLumBase*1.1/10)*10||maxLumBase;
 const chart=drawChartGrid(ctx,{
  xSteps:10,ySteps:5,
  xLabel:(i)=>(i*10)+'',
  yLabel:(i,n)=>(yTop*i/n).toFixed(0)
 });
 const targetSteps=allSteps||sorted.map(r=>({ire:r.ire||0}));
 const tgtPts=meterGreyTargetChartPoints(targetSteps,Lw,Lb,yTop);
 drawDashedLine(ctx,chart,tgtPts,'#666');
 if(allSteps){
  allSteps.filter(s=>!readingMap[s.ire]).forEach(s=>{
   const v=s.ire/100;
   drawDots(ctx,chart,[[v,meterGreyTargetChartValue(s.ire,Lw,Lb)/yTop]],'#33333380',3);
  });
 }
 // Measured points (absolute cd/m²) — keep true 0.0 black readings for OLEDs,
 // but still ignore missing luminance values.
 const validG=sorted.filter(r=>r.luminance!=null && r.luminance>=0);
 const mPts=validG.map(r=>[r.ire/100,Math.min(1,r.luminance/yTop)]);
 if(mPts.length>1) drawLine(ctx,chart,mPts,'#ffeb3b',2);
 drawDots(ctx,chart,mPts,'#ffeb3b',3);
 // Min/Max annotations like Calman
 ctx.fillStyle='#aaa';ctx.font='11px sans-serif';
 ctx.textAlign='left';
 ctx.fillText('Min cd/m\u00B2: '+Lb.toFixed(2),chart.pad.l,ctx.h-2);
 if(meterChartIsHdr()) ctx.fillText('Target cd/m\u00B2: '+targetPeak.toFixed(0),chart.pad.l,chart.pad.t+14);
 ctx.textAlign='right';
 ctx.fillText('Max cd/m\u00B2: '+Lw.toFixed(2),ctx.w-chart.pad.r,ctx.h-2);
}

function drawDeltaEChart(gs,allSteps,readingMap){
 const ctx=getChartCtx('chartDeltaE');
 if(!ctx) return;
 const inclLum=meterIncludeLum();
 // Update chart label based on mode
 const lbl=document.getElementById('chartDeltaELabel');
 if(lbl) lbl.textContent = inclLum ? "ΔE CIELUV (+ Luminance)" : "ΔE CIELUV (chroma only)";
 // Only compute ΔE when actual 100% white is measured — using "brightest so
 // far" causes all values to shift every time a brighter patch arrives.
 const whiteR=gs.find(r=>r.ire===100);
 // If the 100% measurement isn't present yet, allow a configured target
 // luminance (`config.max_luma`) to act as the white reference. This
 // mirrors HCFR's use of a pre-configured target luminance so ΔE values
 // can be computed per-reading and remain stable.
 let effectiveWhite=whiteR;
 if((!effectiveWhite||effectiveWhite.Y<=0) && config && config.max_luma){
  const maxL=parseFloat(config.max_luma);
  if(maxL>0){
   effectiveWhite={X:D65.X*maxL, Y:maxL, Z:D65.Z*maxL, luminance:maxL, x:D65.x, y:D65.y, cct:null};
  }
 }
 if(!effectiveWhite||effectiveWhite.Y<=0){
  if(allSteps) drawDeltaEPreset(allSteps);
  return;
 }
 const Lw=effectiveWhite.luminance||effectiveWhite.Y;
 const blacksL=gs.filter(r=>(r.ire||0)<=5&&r.luminance!=null);
 const Lb=blacksL.length>0?Math.min(...blacksL.map(r=>r.luminance)):0;
 // Use all series steps for x-axis
 const xSteps=allSteps||[...gs].sort((a,b)=>a.ire-b.ire);
 // Compute deltaE for available readings
 const deMap={};
 gs.forEach(rd=>{
  const X=rd.X||0,Y=rd.Y||0,Z=rd.Z||0;
  if(Y<=0){deMap[rd.ire]=0;return;} // true black: no chroma target
  const ref=hcfrGreyRef(rd.ire, Y, Lw, Lb, inclLum, rd.r_code);
  deMap[rd.ire]=deltaELuvHCFR(X,Y,Z,ref.YWhite, ref.refX,ref.refY,ref.refZ,ref.YWhiteRef);
 });
 const deValues=Object.values(deMap);
 // Auto-scale Y: zoom to fit tightest range
 let yMax;
 if(deValues.length>0){
  const maxDE=Math.max(...deValues);
  yMax=Math.max(2,Math.ceil(maxDE*1.2*2)/2);
 } else {yMax=5;}
 const n=xSteps.length;
 const rawW=ctx.w-55-15;
 const estBarW=Math.max(8,Math.min(30,rawW/(n*1.5)));
 const chart=drawChartGrid(ctx,{
  pad:{t:20,r:15,b:30,l:55},
  xInset:estBarW/2+4,
  xSteps:n-1||1,ySteps:Math.min(5,Math.ceil(yMax)),
  xLabel:(i)=>i<n?xSteps[i].ire+'%':'',
  yLabel:(i,nn)=>(yMax*i/nn).toFixed(yMax>5?0:1)
 });
 // Reference lines
 if(1/yMax<=1) drawDashedLine(ctx,chart,[[0,1/yMax],[1,1/yMax]],'#4caf5080');
 if(3/yMax<=1) drawDashedLine(ctx,chart,[[0,3/yMax],[1,3/yMax]],'#ff980080');
 // Draw bars for each x-axis step
 const barW=Math.max(8,Math.min(30,(chart.dw||chart.w)/(n*1.5)));
 xSteps.forEach((step,i)=>{
  const cx=chart.toX(n>1?i/(n-1):0.5);
  const dE=deMap[step.ire];
  if(dE!=null){
   const barH=Math.max(0.005,Math.min(dE/yMax,1));
   const y=chart.pad.t+chart.h-barH*chart.h;
   ctx.fillStyle=dE<1?'#4caf50':dE<3?'#ff9800':'#f44';
   ctx.fillRect(cx-barW/2,y,barW,Math.max(2,barH*chart.h));
   ctx.fillStyle='#ccc';ctx.font='11px sans-serif';
   ctx.textAlign='center';
   ctx.fillText(dE.toFixed(2),cx,y-4);
  } else {
   // Placeholder: thin grey line
   ctx.fillStyle='#33333380';
   ctx.fillRect(cx-1,chart.pad.t+chart.h-2,2,2);
  }
 });
 // Average dE line
 if(deValues.length>0){
  const avgDE=deValues.reduce((s,v)=>s+v,0)/deValues.length;
  ctx.fillStyle='#888';ctx.font='11px sans-serif';ctx.textAlign='right';
  ctx.fillText('Avg: '+avgDE.toFixed(2),chart.pad.l+chart.w,chart.pad.t-4);
 }
 // White point info (CCT, Δxy from D65)
 if(whiteR&&whiteR.x>0&&whiteR.y>0){
  const dxy=Math.sqrt(Math.pow(whiteR.x-0.31271,2)+Math.pow(whiteR.y-0.32902,2));
  ctx.fillStyle='#888';ctx.font='11px sans-serif';ctx.textAlign='left';
  const wpText=(whiteR.cct?whiteR.cct+'K  ':'')+'\u0394xy '+dxy.toFixed(4);
  ctx.fillText(wpText,chart.pad.l,chart.pad.t-4);
 }
}

function drawDeltaE2000Chart(gs,allSteps,readingMap){
 const ctx=getChartCtx('chartDeltaE2000');
 if(!ctx) return;
 const inclLum=meterIncludeLum();
 const lbl=document.getElementById('chartDeltaE2000Label');
 if(lbl) lbl.textContent = inclLum ? "ΔE 2000 (+ Luminance)" : "ΔE 2000 (chroma only)";
 const whiteR=gs.find(r=>r.ire===100);
 // Use configured target luminance as synthetic white when 100% not yet measured
 let effectiveWhite2000=whiteR;
 if((!effectiveWhite2000||effectiveWhite2000.Y<=0) && config && config.max_luma){
  const maxL=parseFloat(config.max_luma);
  if(maxL>0){
   effectiveWhite2000={X:D65.X*maxL, Y:maxL, Z:D65.Z*maxL, luminance:maxL, x:D65.x, y:D65.y, cct:null};
  }
 }
 if(!effectiveWhite2000||effectiveWhite2000.Y<=0){
  if(allSteps) drawDeltaE2000Preset(allSteps);
  return;
 }
 const Lw=effectiveWhite2000.luminance||effectiveWhite2000.Y;
 const blacksL=gs.filter(r=>(r.ire||0)<=5&&r.luminance!=null);
 const Lb=blacksL.length>0?Math.min(...blacksL.map(r=>r.luminance)):0;
 const xSteps=allSteps||[...gs].sort((a,b)=>a.ire-b.ire);
 // Lab normalization: Xn = D65.X * YWhite, Yn = YWhite, Zn = D65.Z * YWhite.
 // Reference Y per hcfrGreyRef (chroma-only or target-EOTF luminance).
 const deMap={};
 gs.forEach(rd=>{
  const X=rd.X||0,Y=rd.Y||0,Z=rd.Z||0;
  if(Y<=0){deMap[rd.ire]=0;return;} // true black: no chroma target
  const ref=hcfrGreyRef(rd.ire, Y, Lw, Lb, inclLum, rd.r_code);
  const XnM=D65.X*ref.YWhite, YnM=ref.YWhite, ZnM=D65.Z*ref.YWhite;
  const XnR=D65.X*ref.YWhiteRef, YnR=ref.YWhiteRef, ZnR=D65.Z*ref.YWhiteRef;
  const labM=xyzToLab(X,Y,Z,XnM,YnM,ZnM);
  const labR=xyzToLab(ref.refX,ref.refY,ref.refZ,XnR,YnR,ZnR);
  deMap[rd.ire]=deltaE2000(labM,labR);
 });
 const deValues=Object.values(deMap);
 let yMax;
 if(deValues.length>0){
  const maxDE=Math.max(...deValues);
  yMax=Math.max(2,Math.ceil(maxDE*1.2*2)/2);
 } else {yMax=5;}
 const n=xSteps.length;
 const rawW=ctx.w-55-15;
 const estBarW=Math.max(8,Math.min(30,rawW/(n*1.5)));
 const chart=drawChartGrid(ctx,{
  pad:{t:20,r:15,b:30,l:55},
  xInset:estBarW/2+4,
  xSteps:n-1||1,ySteps:Math.min(5,Math.ceil(yMax)),
  xLabel:(i)=>i<n?xSteps[i].ire+'%':'',
  yLabel:(i,nn)=>(yMax*i/nn).toFixed(yMax>5?0:1)
 });
 if(1/yMax<=1) drawDashedLine(ctx,chart,[[0,1/yMax],[1,1/yMax]],'#4caf5080');
 if(3/yMax<=1) drawDashedLine(ctx,chart,[[0,3/yMax],[1,3/yMax]],'#ff980080');
 const barW=Math.max(8,Math.min(30,(chart.dw||chart.w)/(n*1.5)));
 xSteps.forEach((step,i)=>{
  const cx=chart.toX(n>1?i/(n-1):0.5);
  const dE=deMap[step.ire];
  if(dE!=null){
   const barH=Math.max(0.005,Math.min(dE/yMax,1));
   const y=chart.pad.t+chart.h-barH*chart.h;
   ctx.fillStyle=dE<1?'#4caf50':dE<3?'#ff9800':'#f44';
   ctx.fillRect(cx-barW/2,y,barW,Math.max(2,barH*chart.h));
   ctx.fillStyle='#ccc';ctx.font='11px sans-serif';
   ctx.textAlign='center';
   ctx.fillText(dE.toFixed(2),cx,y-4);
  } else {
   ctx.fillStyle='#33333380';
   ctx.fillRect(cx-1,chart.pad.t+chart.h-2,2,2);
  }
 });
 if(deValues.length>0){
  const avgDE=deValues.reduce((s,v)=>s+v,0)/deValues.length;
  ctx.fillStyle='#888';ctx.font='11px sans-serif';ctx.textAlign='right';
  ctx.fillText('Avg: '+avgDE.toFixed(2),chart.pad.l+chart.w,chart.pad.t-4);
 }
}

function drawDeltaE2000Preset(gsSteps){
 const ctx=getChartCtx('chartDeltaE2000');
 if(!ctx) return;
 const yMax=5;
 const chart=drawChartGrid(ctx,{
  xSteps:gsSteps.length-1||1,ySteps:5,
  xLabel:(i)=>i<gsSteps.length?gsSteps[i].ire+'%':'',
  yLabel:(i,n)=>(yMax*i/n).toFixed(1)
 });
 if(1/yMax<=1) drawDashedLine(ctx,chart,[[0,1/yMax],[1,1/yMax]],'#4caf5080');
 if(3/yMax<=1) drawDashedLine(ctx,chart,[[0,3/yMax],[1,3/yMax]],'#ff980080');
}

///////////////////////////////////////////////
//     CIE Chromaticity + Color Charts       //
///////////////////////////////////////////////

function drawColorReadingsTable(readings){
 const wrap=document.getElementById('colorReadingsTableWrap');
 const tbody=document.querySelector('#colorReadingsTable tbody');
 if(!wrap||!tbody) return;
 if(!readings||readings.length===0){
  wrap.style.display='none';
  const avgWrap=document.getElementById('colorSeriesAveragesWrap');
  if(avgWrap) avgWrap.style.display='none';
  return;
 }
 const inclLum=meterIncludeLum();
 let html='';
 let deSum=0,deCount=0;
 readings.forEach(rd=>{
  if(!meterReadingHasLuminance(rd)) return;
  const hasChroma=meterReadingHasChromaticity(rd);
  const targetXYZ=meterTargetXYZForReading(rd);
  const tgt=(targetXYZ&&targetXYZ.Y>0)?meterTargetChromaticityForReading(rd):null;
  const dx=(hasChroma&&tgt)?(rd.x-tgt.x):null;
  const dy=(hasChroma&&tgt)?(rd.y-tgt.y):null;
  const pc=meterPreviewColorForReading(rd,'target');
  const de=meterColorDeltaE2000(rd,inclLum);
  deSum+=de;deCount++;
  const deCol=de<1?'#4caf50':de<3?'#ff9800':'#f44';
  const dxCol=dx==null?'#888':(Math.abs(dx)<0.005?'#4caf50':Math.abs(dx)<0.01?'#ff9800':'#f44');
  const dyCol=dy==null?'#888':(Math.abs(dy)<0.005?'#4caf50':Math.abs(dy)<0.01?'#ff9800':'#f44');
  html+='<tr data-name=\"'+(rd.name||'').replace(/"/g,'&quot;')+'\" style=\"border-bottom:1px solid #1a1a28;cursor:pointer\" onclick=\"colorTableRowClick(this)\">';
  html+='<td style="padding:5px 8px;text-align:left"><span style="display:inline-block;width:10px;height:10px;border-radius:2px;background:'+pc+';vertical-align:middle;margin-right:5px"></span>'+(rd.name||'')+'</td>';
  html+='<td style="padding:5px 6px;text-align:right;color:#888">'+(tgt?tgt.x.toFixed(4):'--')+'</td>';
  html+='<td style="padding:5px 6px;text-align:right;color:#888">'+(tgt?tgt.y.toFixed(4):'--')+'</td>';
  html+='<td style="padding:5px 6px;text-align:right">'+(hasChroma?rd.x.toFixed(4):'--')+'</td>';
  html+='<td style="padding:5px 6px;text-align:right">'+(hasChroma?rd.y.toFixed(4):'--')+'</td>';
  html+='<td style="padding:5px 6px;text-align:right">'+((rd.Y!=null?rd.Y:(rd.luminance||0)).toFixed(1))+'</td>';
  html+='<td style="padding:5px 6px;text-align:right;color:'+dxCol+'">'+(dx==null?'--':(dx>=0?'+':'')+dx.toFixed(4))+'</td>';
  html+='<td style="padding:5px 6px;text-align:right;color:'+dyCol+'">'+(dy==null?'--':(dy>=0?'+':'')+dy.toFixed(4))+'</td>';
  html+='<td style="padding:5px 6px;text-align:right;font-weight:600;color:'+deCol+'">'+de.toFixed(2)+'</td>';
  html+='</tr>';
 });
 if(deCount>0){
  const avg=deSum/deCount;
  const avgCol=avg<1?'#4caf50':avg<3?'#ff9800':'#f44';
  html+='<tr style="border-top:2px solid #333;font-weight:600">';
  html+='<td style="padding:5px 8px;text-align:left;color:#aaa" colspan="8">Average</td>';
  html+='<td style="padding:5px 6px;text-align:right;color:'+avgCol+'">'+avg.toFixed(2)+'</td>';
  html+='</tr>';
 }
 tbody.innerHTML=html;
 wrap.style.display='';
 drawColorSeriesAverages(readings,inclLum);
}

// Per-color/grand-total averages across the current series. For saturation
// sweeps we group by color family (Red/Green/Blue/Cyan/Magenta/Yellow); for
// flat color lists we just show the overall average.
function drawColorSeriesAverages(readings,inclLum){
 const wrap=document.getElementById('colorSeriesAveragesWrap');
 const tbody=document.querySelector('#colorSeriesAveragesTable tbody');
 if(!wrap||!tbody) return;
 const valid=(readings||[]).filter(rd=>meterReadingHasLuminance(rd));
 if(valid.length===0){wrap.style.display='none';return;}
 const isSat=(meterActiveSeriesType==='saturations');
 const groups={};
 const order=[];
 valid.forEach(rd=>{
  let key='All';
  if(isSat){
   const sat=meterParseSaturationReading(rd);
   key=sat&&sat.color?sat.color:(rd.name||'Other');
  }
  if(!groups[key]){groups[key]={de:[],dx:[],dy:[],Y:[],color:meterPreviewColorForReading(rd,'target')};order.push(key);}
  const tgt=meterReadingHasChromaticity(rd)?meterTargetChromaticityForReading(rd):null;
  groups[key].de.push(meterColorDeltaE2000(rd,inclLum));
  if(tgt){
   groups[key].dx.push(Math.abs(rd.x-tgt.x));
   groups[key].dy.push(Math.abs(rd.y-tgt.y));
  }
  groups[key].Y.push(rd.Y!=null?rd.Y:(rd.luminance||0));
 });
 const avg=a=>a.length?a.reduce((s,v)=>s+v,0)/a.length:0;
 const mx=a=>a.length?Math.max(...a):0;
 const rowFor=(label,g,bold)=>{
  const aDE=avg(g.de), mDE=mx(g.de);
  const aDx=avg(g.dx), aDy=avg(g.dy), aY=avg(g.Y);
  const c=aDE<1?'#4caf50':aDE<3?'#ff9800':'#f44';
  const cMax=mDE<1?'#4caf50':mDE<3?'#ff9800':'#f44';
  let r='<tr'+(bold?' style="border-top:2px solid #333;font-weight:600"':' style="border-bottom:1px solid #1a1a28"')+'>';
  r+='<td style="padding:5px 8px;text-align:left"><span style="display:inline-block;width:10px;height:10px;border-radius:2px;background:'+(g.color||'#666')+';vertical-align:middle;margin-right:5px"></span>'+label+'</td>';
  r+='<td style="padding:5px 6px;text-align:right;color:#888">'+g.de.length+'</td>';
  r+='<td style="padding:5px 6px;text-align:right">'+aDx.toFixed(4)+'</td>';
  r+='<td style="padding:5px 6px;text-align:right">'+aDy.toFixed(4)+'</td>';
  r+='<td style="padding:5px 6px;text-align:right">'+aY.toFixed(1)+'</td>';
  r+='<td style="padding:5px 6px;text-align:right;color:'+c+'">'+aDE.toFixed(2)+'</td>';
  r+='<td style="padding:5px 6px;text-align:right;color:'+cMax+'">'+mDE.toFixed(2)+'</td>';
  r+='</tr>';
  return r;
 };
 let html='';
 if(isSat){
  order.forEach(k=>{html+=rowFor(k,groups[k],false);});
 }
 const overall={de:[],dx:[],dy:[],Y:[],color:'#888'};
 Object.keys(groups).forEach(k=>{
  const g=groups[k];
  overall.de=overall.de.concat(g.de);
  overall.dx=overall.dx.concat(g.dx);
  overall.dy=overall.dy.concat(g.dy);
  overall.Y=overall.Y.concat(g.Y);
 });
 html+=rowFor(isSat?'Overall':'Average',overall,true);
 tbody.innerHTML=html;
 wrap.style.display='';
}

// Cached CIE 1931 xy chromaticity gradient (offscreen canvas)
let _cieGrad=null,_cieGradKey='';
function getCIEGradient(chartW,chartH,pad){
 const gw=chartW-pad.l-pad.r, gh=chartH-pad.t-pad.b;
 const key=gw+'x'+gh;
 if(_cieGrad&&_cieGradKey===key) return _cieGrad;
 const oc=document.createElement('canvas');oc.width=gw;oc.height=gh;
 const ox=oc.getContext('2d');
 const img=ox.createImageData(gw,gh);
 const d=img.data;
 const xMn=0,xMx=0.8,yMn=0,yMx=0.9;
 const locus=CIE_LOCUS, M=M_XYZ_TO_RGB;
 function pip(px,py){
  let ins=false;
  for(let i=0,j=locus.length-1;i<locus.length;j=i++){
   const xi=locus[i][0],yi=locus[i][1],xj=locus[j][0],yj=locus[j][1];
   if((yi>py)!==(yj>py)&&px<(xj-xi)*(py-yi)/(yj-yi)+xi) ins=!ins;
  }
  return ins;
 }
 for(let py=0;py<gh;py++){
  for(let px=0;px<gw;px++){
   const cx=xMn+(px/gw)*(xMx-xMn);
   const cy=yMx-(py/gh)*(yMx-yMn);
   const idx=(py*gw+px)*4;
   if(cy<0.005||!pip(cx,cy)){d[idx+3]=0;continue;}
   const X=cx/cy, Y=1.0, Z=(1-cx-cy)/cy;
   let rl=M[0][0]*X+M[0][1]*Y+M[0][2]*Z;
   let gl=M[1][0]*X+M[1][1]*Y+M[1][2]*Z;
   let bl=M[2][0]*X+M[2][1]*Y+M[2][2]*Z;
   const mx=Math.max(rl,gl,bl);
   if(mx>0){rl/=mx;gl/=mx;bl/=mx;}
   rl=Math.max(0,rl);gl=Math.max(0,gl);bl=Math.max(0,bl);
   d[idx]=Math.round(255*Math.pow(rl,1/2.2));
   d[idx+1]=Math.round(255*Math.pow(gl,1/2.2));
   d[idx+2]=Math.round(255*Math.pow(bl,1/2.2));
   d[idx+3]=50;
  }
 }
 ox.putImageData(img,0,0);
 _cieGrad=oc;_cieGradKey=key;
 return oc;
}

// Color reading detail box (beside CIE chart)
let _selectedColorReadingName=null;
let _colorDetailPinned=false;
function showColorReadingDetail(rd,opts){
 const el=document.getElementById('colorDetailContent');
 if(!el) return;
 if(!rd){
  el.innerHTML='<div style="text-align:center;padding:30px 0;color:#555">Select a color<br>to see details</div>';
  _selectedColorReadingName=null;
  _colorDetailPinned=false;
  return;
 }
 const pin=!(opts&&opts.pin===false);
 _selectedColorReadingName=rd.name||null;
 _colorDetailPinned=pin&&!!_selectedColorReadingName;
 updateLiveReading(rd);
 const inclLum=meterIncludeLum();
 const hasChroma=meterReadingHasChromaticity(rd);
 const targetXYZ=meterTargetXYZForReading(rd);
 const tgt=(targetXYZ&&targetXYZ.Y>0)?meterTargetChromaticityForReading(rd):null;
 const targetColor=meterPreviewColorForReading(rd,'target');
 const measuredColor=meterPreviewColorForReading(rd,'measured');
 const dx=(hasChroma&&tgt)?(rd.x-tgt.x):null;
 const dy=(hasChroma&&tgt)?(rd.y-tgt.y):null;
 const de=meterColorDeltaE2000(rd,inclLum);
 const deCol=de<1?'#4caf50':de<3?'#ff9800':'#f44';
 const dxCol=dx==null?'#888':(Math.abs(dx)<0.005?'#4caf50':Math.abs(dx)<0.01?'#ff9800':'#f44');
 const dyCol=dy==null?'#888':(Math.abs(dy)<0.005?'#4caf50':Math.abs(dy)<0.01?'#ff9800':'#f44');
 let h='<div style="margin-bottom:8px;text-align:center">';
 h+='<span style="display:inline-block;width:12px;height:12px;border-radius:2px;background:'+targetColor+';vertical-align:middle;margin-right:4px"></span>';
 h+='<span style="color:#eee;font-weight:600;font-size:12px">'+(rd.name||'')+'</span></div>';
 h+='<div style="display:flex;gap:6px;margin-bottom:8px;justify-content:center">';
 h+='<div style="text-align:center"><div style="width:36px;height:24px;border-radius:3px;border:1px solid #333;background:'+targetColor+'"></div><div style="font-size:8px;color:#555;margin-top:1px">Target</div></div>';
 h+='<div style="text-align:center"><div style="width:36px;height:24px;border-radius:3px;border:1px solid #333;background:'+measuredColor+'"></div><div style="font-size:8px;color:#555;margin-top:1px">Measured</div></div></div>';
 h+='<table style="width:100%;font-size:10px;border-collapse:collapse">';
 h+='<tr><td style="padding:2px 0;color:#666">Target x</td><td style="text-align:right;padding:2px 0;color:#aaa">'+(tgt?tgt.x.toFixed(4):'--')+'</td></tr>';
 h+='<tr><td style="padding:2px 0;color:#666">Target y</td><td style="text-align:right;padding:2px 0;color:#aaa">'+(tgt?tgt.y.toFixed(4):'--')+'</td></tr>';
 h+='<tr style="border-top:1px solid #1a1a28"><td style="padding:2px 0;color:#666">Meas. x</td><td style="text-align:right;padding:2px 0;color:#ccc">'+(hasChroma?rd.x.toFixed(4):'--')+'</td></tr>';
 h+='<tr><td style="padding:2px 0;color:#666">Meas. y</td><td style="text-align:right;padding:2px 0;color:#ccc">'+(hasChroma?rd.y.toFixed(4):'--')+'</td></tr>';
 h+='<tr style="border-top:1px solid #1a1a28"><td style="padding:2px 0;color:#666">Y cd/m\u00B2</td><td style="text-align:right;padding:2px 0;color:#ccc">'+((rd.Y!=null?rd.Y:(rd.luminance||0)).toFixed(1))+'</td></tr>';
 h+='<tr style="border-top:1px solid #1a1a28"><td style="padding:2px 0;color:#666">\u0394x</td><td style="text-align:right;padding:2px 0;color:'+dxCol+'">'+(dx==null?'--':(dx>=0?'+':'')+dx.toFixed(4))+'</td></tr>';
 h+='<tr><td style="padding:2px 0;color:#666">\u0394y</td><td style="text-align:right;padding:2px 0;color:'+dyCol+'">'+(dy==null?'--':(dy>=0?'+':'')+dy.toFixed(4))+'</td></tr>';
 h+='<tr style="border-top:1px solid #1a1a28"><td style="padding:2px 0;color:#666;font-weight:600">\u0394E 2000</td><td style="text-align:right;padding:2px 0;color:'+deCol+';font-weight:700;font-size:13px">'+de.toFixed(2)+'</td></tr>';
 h+='</table>';
 el.innerHTML=h;
 // Highlight corresponding thumb and table row by name
 colorHighlightThumb(rd.name);
 colorHighlightTableRow(rd.name);
}
function colorHighlightThumb(name){
 const container=document.getElementById('meterPatchThumbs');
 if(!container) return;
 const hasReadings=meterReadings&&meterReadings.length>0;
 const completedNames=hasReadings?new Set(meterReadings.filter(r=>r.luminance!=null).map(r=>r.name)):new Set();
 for(let i=0;i<container.children.length;i++){
  const t=container.children[i];
  const isMatch=t.dataset.name===name;
  const done=completedNames.has(t.dataset.name);
  t.style.boxShadow=isMatch?'0 0 0 3px #fff':(done?'0 0 0 2px #4caf50':'none');
  t.style.animation='none';
  t.style.zIndex=isMatch?'1':'';
 }
}
function colorTableRowClick(tr){
 const name=tr.getAttribute('data-name');
 if(!name||!meterReadings) return;
 const rd=meterReadings.find(r=>r.name===name);
 if(rd) showColorReadingDetail(rd);
}
// Highlight table row for selected reading
function colorHighlightTableRow(name){
 const rows=document.querySelectorAll('#colorReadingsTable tbody tr[data-name]');
 rows.forEach(tr=>{
  tr.style.background=tr.getAttribute('data-name')===name?'#1a1a2f':'';
 });
}
// Color chart interaction (CIE + ΔE bar chart)
let _colorChartHitZones=[];
function colorChartRegisterInteraction(readings){
 _colorChartHitZones=[];
 if(!readings||readings.length===0) return;
 // CIE chart hit zones (use measured xy positions)
 const cieCanvas=document.getElementById('chartCIE');
 if(cieCanvas){
  const rect=cieCanvas.getBoundingClientRect();
  const cW=rect.width,cH=rect.height;
  const pad={t:15,r:15,b:35,l:45};
  const w=cW-pad.l-pad.r, h=cH-pad.t-pad.b;
  const xMin=0,xMax=0.8,yMin=0,yMax=0.9;
  readings.forEach(rd=>{
   if(!rd.x||!rd.y||rd.x<=0||rd.y<=0) return;
   const px=pad.l+(rd.x-xMin)/(xMax-xMin)*w;
   const py=pad.t+h-(rd.y-yMin)/(yMax-yMin)*h;
   _colorChartHitZones.push({canvasId:'chartCIE',cx:px,cy:py,radius:12,reading:rd});
  });
  cieCanvas.onmousemove=function(e){colorChartHandleHover(e,'chartCIE');};
  cieCanvas.onmouseleave=function(){document.getElementById('chartTooltip').style.display='none';};
  cieCanvas.onclick=function(e){colorChartHandleClick(e,'chartCIE');};
  cieCanvas.style.cursor='crosshair';
 }
 // ΔE bar chart hit zones
 const deCanvas=document.getElementById('chartColorDE');
 if(deCanvas){
  const rect=deCanvas.getBoundingClientRect();
  const cW=rect.width;
  const valid=readings.filter(rd=>meterReadingHasLuminance(rd));
  const n=valid.length;
  if(n>0){
   const pad2={t:20,r:15,b:30,l:55};
   const w2=cW-pad2.l-pad2.r;
   const estBarW=Math.max(8,Math.min(30,w2/(n*1.5)));
   const xInset=estBarW/2+4;
   const dw=w2-2*xInset;
   valid.forEach((rd,idx)=>{
    const cx=pad2.l+xInset+(n>1?idx/(n-1):0.5)*dw;
    _colorChartHitZones.push({canvasId:'chartColorDE',cx:cx,cy:0,radius:estBarW,reading:rd});
   });
  }
  deCanvas.onmousemove=function(e){colorChartHandleHover(e,'chartColorDE');};
  deCanvas.onmouseleave=function(){document.getElementById('chartTooltip').style.display='none';};
  deCanvas.onclick=function(e){colorChartHandleClick(e,'chartColorDE');};
  deCanvas.style.cursor='crosshair';
 }
}
function colorChartFindHit(e,canvasId){
 const canvas=document.getElementById(canvasId);
 if(!canvas) return null;
 const rect=canvas.getBoundingClientRect();
 const mx=e.clientX-rect.left, my=e.clientY-rect.top;
 let best=null,bestDist=Infinity;
 _colorChartHitZones.filter(z=>z.canvasId===canvasId).forEach(z=>{
  const dx2=mx-z.cx, dy2=canvasId==='chartColorDE'?0:(my-z.cy);
  const dist=Math.sqrt(dx2*dx2+dy2*dy2);
  if(dist<Math.max(z.radius,20)&&dist<bestDist){bestDist=dist; best=z;}
 });
 return best;
}
function colorChartHandleHover(e,canvasId){
 const hit=colorChartFindHit(e,canvasId);
 const tip=document.getElementById('chartTooltip');
 if(!hit){tip.style.display='none';return;}
 const rd=hit.reading;
 const hasChroma=meterReadingHasChromaticity(rd);
 const targetXYZ=meterTargetXYZForReading(rd);
 const tgt=(targetXYZ&&targetXYZ.Y>0)?meterTargetChromaticityForReading(rd):null;
 const dx=(hasChroma&&tgt)?(rd.x-tgt.x):null;
 const dy=(hasChroma&&tgt)?(rd.y-tgt.y):null;
 let html='<b>'+(rd.name||'')+'</b><br>';
 html+='Target: '+(tgt?'('+tgt.x.toFixed(4)+', '+tgt.y.toFixed(4)+')':'--')+'<br>';
 html+='Measured: '+(hasChroma?'('+rd.x.toFixed(4)+', '+rd.y.toFixed(4)+')':'--')+'<br>';
 html+='\u0394x: '+(dx==null?'--':(dx>=0?'+':'')+dx.toFixed(4))+' &nbsp;\u0394y: '+(dy==null?'--':(dy>=0?'+':'')+dy.toFixed(4))+'<br>';
 html+='Y: '+((rd.Y!=null?rd.Y:(rd.luminance||0)).toFixed(1))+' cd/m\u00B2';
 tip.innerHTML=html;
 tip.style.display='block';
 const tx=e.clientX+14, ty=e.clientY-10;
 tip.style.left=Math.min(tx,window.innerWidth-tip.offsetWidth-10)+'px';
 tip.style.top=Math.min(ty,window.innerHeight-tip.offsetHeight-10)+'px';
}
function colorChartHandleClick(e,canvasId){
 const hit=colorChartFindHit(e,canvasId);
 if(!hit) return;
 document.getElementById('chartTooltip').style.display='none';
 showColorReadingDetail(hit.reading);
}

function drawCIEChart(readings){
 const ctx=getChartCtx('chartCIE');
 if(!ctx) return;
 const pad={t:15,r:15,b:35,l:45};
 const w=ctx.w-pad.l-pad.r, h=ctx.h-pad.t-pad.b;
 const xMin=0,xMax=0.8,yMin=0,yMax=0.9;
 const toX=v=>pad.l+(v-xMin)/(xMax-xMin)*w;
 const toY=v=>pad.t+h-(v-yMin)/(yMax-yMin)*h;
 // Background
 ctx.fillStyle='#0d0d15';ctx.fillRect(0,0,ctx.w,ctx.h);
 // Grid
 ctx.strokeStyle='#1a1a28';ctx.lineWidth=1;
 for(let x=0;x<=xMax;x+=0.1){ctx.beginPath();ctx.moveTo(toX(x),pad.t);ctx.lineTo(toX(x),pad.t+h);ctx.stroke();}
 for(let y=0;y<=yMax;y+=0.1){ctx.beginPath();ctx.moveTo(pad.l,toY(y));ctx.lineTo(pad.l+w,toY(y));ctx.stroke();}
 // Axes
 ctx.strokeStyle='#3a3a4a';ctx.beginPath();ctx.moveTo(pad.l,pad.t);ctx.lineTo(pad.l,pad.t+h);ctx.lineTo(pad.l+w,pad.t+h);ctx.stroke();
 // Axis labels
 ctx.fillStyle='#777';ctx.font='10px sans-serif';ctx.textAlign='center';
 for(let x=0;x<=xMax;x+=0.1) ctx.fillText(x.toFixed(1),toX(x),pad.t+h+14);
 ctx.textAlign='right';
 for(let y=0;y<=yMax;y+=0.1) ctx.fillText(y.toFixed(1),pad.l-4,toY(y)+3);
 // Axis titles
 ctx.fillStyle='#666';ctx.font='11px sans-serif';ctx.textAlign='center';
 ctx.fillText('x',pad.l+w/2,ctx.h-2);
 ctx.save();ctx.translate(10,pad.t+h/2);ctx.rotate(-Math.PI/2);ctx.fillText('y',0,0);ctx.restore();
 // CIE spectral locus
 ctx.strokeStyle='#556';ctx.lineWidth=1.5;ctx.beginPath();
 CIE_LOCUS.forEach((p,i)=>{if(i===0)ctx.moveTo(toX(p[0]),toY(p[1]));else ctx.lineTo(toX(p[0]),toY(p[1]));});
 ctx.closePath();ctx.stroke();
 // CIE xy color gradient inside locus
 ctx.drawImage(getCIEGradient(ctx.w,ctx.h,pad),pad.l,pad.t);
 const gamut=meterActiveGamut();
 const prim=gamut.primaries;
 ctx.strokeStyle='#888';ctx.lineWidth=1.5;ctx.setLineDash([5,3]);
 ctx.beginPath();ctx.moveTo(toX(prim.R.x),toY(prim.R.y));ctx.lineTo(toX(prim.G.x),toY(prim.G.y));ctx.lineTo(toX(prim.B.x),toY(prim.B.y));ctx.closePath();ctx.stroke();
 ctx.setLineDash([]);
 ctx.fillStyle='#888';ctx.font='9px sans-serif';
 ctx.textAlign='left';ctx.fillText('R',toX(prim.R.x)+4,toY(prim.R.y)-4);
 ctx.fillText('G',toX(prim.G.x)-12,toY(prim.G.y)-6);
 ctx.textAlign='right';ctx.fillText('B',toX(prim.B.x)-4,toY(prim.B.y)+12);
 // D65 white point
 ctx.fillStyle='#fff';ctx.beginPath();ctx.arc(toX(.3127),toY(.329),3,0,Math.PI*2);ctx.fill();
 ctx.fillStyle='#999';ctx.font='9px sans-serif';ctx.textAlign='left';ctx.fillText('D65',toX(.3127)+5,toY(.329)+3);
 ctx.fillStyle='#777';ctx.font='10px sans-serif';ctx.textAlign='right';ctx.fillText(gamut.label,ctx.w-pad.r,pad.t+10);
 // Plot target and measured points
 readings.forEach(rd=>{
  if(!rd.x||!rd.y||rd.x<=0||rd.y<=0) return;
  const tgt=meterTargetChromaticityForReading(rd);
  const mx=rd.x, my=rd.y;
  const targetColor=meterPreviewColorForReading(rd,'target');
  const measuredColor=meterPreviewColorForReading(rd,'measured');
  // Error line
  ctx.strokeStyle=targetColor+'60';ctx.lineWidth=1;ctx.beginPath();ctx.moveTo(toX(tgt.x),toY(tgt.y));ctx.lineTo(toX(mx),toY(my));ctx.stroke();
  // Target: hollow square (Calman style)
  const sq=6;
  ctx.strokeStyle=targetColor;ctx.lineWidth=1.5;ctx.strokeRect(toX(tgt.x)-sq,toY(tgt.y)-sq,sq*2,sq*2);
  // Measured: filled circle
  ctx.fillStyle=measuredColor;ctx.beginPath();
  ctx.arc(toX(mx),toY(my),4,0,Math.PI*2);
  ctx.fill();
 });
}

function drawCIEChartPreset(steps){
 const ctx=getChartCtx('chartCIE');
 if(!ctx) return;
 const pad={t:15,r:15,b:35,l:45};
 const w=ctx.w-pad.l-pad.r, h=ctx.h-pad.t-pad.b;
 const xMin=0,xMax=0.8,yMin=0,yMax=0.9;
 const toX=v=>pad.l+(v-xMin)/(xMax-xMin)*w;
 const toY=v=>pad.t+h-(v-yMin)/(yMax-yMin)*h;
 ctx.fillStyle='#0d0d15';ctx.fillRect(0,0,ctx.w,ctx.h);
 ctx.strokeStyle='#1a1a28';ctx.lineWidth=1;
 for(let x=0;x<=xMax;x+=0.1){ctx.beginPath();ctx.moveTo(toX(x),pad.t);ctx.lineTo(toX(x),pad.t+h);ctx.stroke();}
 for(let y=0;y<=yMax;y+=0.1){ctx.beginPath();ctx.moveTo(pad.l,toY(y));ctx.lineTo(pad.l+w,toY(y));ctx.stroke();}
 ctx.strokeStyle='#3a3a4a';ctx.beginPath();ctx.moveTo(pad.l,pad.t);ctx.lineTo(pad.l,pad.t+h);ctx.lineTo(pad.l+w,pad.t+h);ctx.stroke();
 ctx.fillStyle='#777';ctx.font='10px sans-serif';ctx.textAlign='center';
 for(let x=0;x<=xMax;x+=0.1) ctx.fillText(x.toFixed(1),toX(x),pad.t+h+14);
 ctx.textAlign='right';
 for(let y=0;y<=yMax;y+=0.1) ctx.fillText(y.toFixed(1),pad.l-4,toY(y)+3);
 ctx.fillStyle='#666';ctx.font='11px sans-serif';ctx.textAlign='center';
 ctx.fillText('x',pad.l+w/2,ctx.h-2);
 ctx.save();ctx.translate(10,pad.t+h/2);ctx.rotate(-Math.PI/2);ctx.fillText('y',0,0);ctx.restore();
 // Locus
 ctx.strokeStyle='#556';ctx.lineWidth=1.5;ctx.beginPath();
 CIE_LOCUS.forEach((p,i)=>{if(i===0)ctx.moveTo(toX(p[0]),toY(p[1]));else ctx.lineTo(toX(p[0]),toY(p[1]));});
 ctx.closePath();ctx.stroke();
 ctx.drawImage(getCIEGradient(ctx.w,ctx.h,pad),pad.l,pad.t);
 const gamut=meterActiveGamut();
 const prim=gamut.primaries;
 ctx.strokeStyle='#888';ctx.lineWidth=1.5;ctx.setLineDash([5,3]);
 ctx.beginPath();ctx.moveTo(toX(prim.R.x),toY(prim.R.y));ctx.lineTo(toX(prim.G.x),toY(prim.G.y));ctx.lineTo(toX(prim.B.x),toY(prim.B.y));ctx.closePath();ctx.stroke();ctx.setLineDash([]);
 ctx.fillStyle='#888';ctx.font='9px sans-serif';
 ctx.textAlign='left';ctx.fillText('R',toX(prim.R.x)+4,toY(prim.R.y)-4);ctx.fillText('G',toX(prim.G.x)-12,toY(prim.G.y)-6);
 ctx.textAlign='right';ctx.fillText('B',toX(prim.B.x)-4,toY(prim.B.y)+12);
 // D65
 ctx.fillStyle='#fff';ctx.beginPath();ctx.arc(toX(.3127),toY(.329),3,0,Math.PI*2);ctx.fill();
 ctx.fillStyle='#999';ctx.font='9px sans-serif';ctx.textAlign='left';ctx.fillText('D65',toX(.3127)+5,toY(.329)+3);
 ctx.fillStyle='#777';ctx.font='10px sans-serif';ctx.textAlign='right';ctx.fillText(gamut.label,ctx.w-pad.r,pad.t+10);
 // Target placeholders (squares — Calman style)
 steps.forEach(s=>{
  const tgt=(s.series_color&&s.sat_pct!=null)?meterTargetChromaticityForReading(s):targetChromaticityXY(s.r,s.g,s.b);
  const pc=meterPreviewColorForStep(s);
  const sq=6;
  ctx.strokeStyle=pc+'80';ctx.lineWidth=1.5;ctx.strokeRect(toX(tgt.x)-sq,toY(tgt.y)-sq,sq*2,sq*2);
 });
}

function drawColorDeltaE2000Chart(readings){
 const ctx=getChartCtx('chartColorDE');
 if(!ctx) return;
 const inclLum=meterIncludeLum();
 const lbl=document.getElementById('chartColorDELabel');
 if(lbl) lbl.textContent = inclLum ? 'ΔE 2000 (Color Accuracy + Luminance)' : 'ΔE 2000 (Color Accuracy, Chroma Only)';
 const deData=[];
 readings.forEach(rd=>{
  if(!meterReadingHasLuminance(rd)) return;
  deData.push({name:rd.name||'',de:meterColorDeltaE2000(rd,inclLum),color:meterPreviewColorForReading(rd,'target')});
 });
 if(deData.length===0) return;
 const deValues=deData.map(d=>d.de);
 let yMaxDE;
 if(deValues.length>0){const mx=Math.max(...deValues);yMaxDE=Math.max(2,Math.ceil(mx*1.2*2)/2);}else{yMaxDE=5;}
 const n=deData.length;
 const rawW=ctx.w-55-15;
 const estBarW=Math.max(8,Math.min(30,rawW/(n*1.5)));
 const chart=drawChartGrid(ctx,{
  pad:{t:20,r:15,b:60,l:55},xInset:estBarW/2+4,
  xSteps:n-1||1,ySteps:Math.min(5,Math.ceil(yMaxDE)),
  xLabel:(i)=>i<n?deData[i].name:'',
  yLabel:(i,nn)=>(yMaxDE*i/nn).toFixed(yMaxDE>5?0:1),
  rotateX:true
 });
 if(1/yMaxDE<=1) drawDashedLine(ctx,chart,[[0,1/yMaxDE],[1,1/yMaxDE]],'#4caf5080');
 if(3/yMaxDE<=1) drawDashedLine(ctx,chart,[[0,3/yMaxDE],[1,3/yMaxDE]],'#ff980080');
 const barW=Math.max(8,Math.min(30,(chart.dw||chart.w)/(n*1.5)));
 deData.forEach((d,i)=>{
  const cx=chart.toX(n>1?i/(n-1):0.5);
  const barH=Math.max(0.005,Math.min(d.de/yMaxDE,1));
  const y=chart.pad.t+chart.h-barH*chart.h;
  ctx.fillStyle=d.de<1?'#4caf50':d.de<3?'#ff9800':'#f44';
  ctx.fillRect(cx-barW/2,y,barW,Math.max(2,barH*chart.h));
  ctx.fillStyle='#ccc';ctx.font='11px sans-serif';ctx.textAlign='center';
  ctx.fillText(d.de.toFixed(2),cx,y-4);
 });
 if(deValues.length>0){
  const avg=deValues.reduce((s,v)=>s+v,0)/deValues.length;
  ctx.fillStyle='#888';ctx.font='11px sans-serif';ctx.textAlign='right';
  ctx.fillText('Avg: '+avg.toFixed(2),chart.pad.l+chart.w,chart.pad.t-4);
 }
}

function drawColorDeltaE2000Preset(steps){
 const ctx=getChartCtx('chartColorDE');
 if(!ctx) return;
 const yMax=5;
 const n=steps.length;
 const rawW=ctx.w-55-15;
 const estBarW=Math.max(8,Math.min(30,rawW/(n*1.5)));
 const chart=drawChartGrid(ctx,{
  pad:{t:20,r:15,b:60,l:55},xInset:estBarW/2+4,
  xSteps:n-1||1,ySteps:5,
  xLabel:(i)=>i<n?(steps[i].name||''):'',
  yLabel:(i,nn)=>(yMax*i/nn).toFixed(1),
  rotateX:true
 });
 if(1/yMax<=1) drawDashedLine(ctx,chart,[[0,1/yMax],[1,1/yMax]],'#4caf5080');
 if(3/yMax<=1) drawDashedLine(ctx,chart,[[0,3/yMax],[1,3/yMax]],'#ff980080');
}

// Chart interaction: hover tooltip + click to show reading
let _chartHitZones=[];
function chartRegisterInteraction(){
 _chartHitZones=[];
 if(!meterReadings||meterReadings.length===0) return;
 const gs=meterReadings.filter(r=>r.luminance!=null&&r.luminance>=0&&r.r_code===r.g_code&&r.g_code===r.b_code);
 if(gs.length===0) return;
 const whiteR=gs.find(r=>r.ire===100);
 if(!whiteR) return;
 const Lw=whiteR.luminance||whiteR.Y;
 const blacks=gs.filter(r=>r.ire<=5&&r.luminance!=null);
 const Lb=blacks.length>0?Math.min(...blacks.map(r=>r.luminance)):0;
 const inclLum=meterIncludeLum();
 const allSteps=meterSeriesSteps?[...meterSeriesSteps].filter(s=>s.r===s.g&&s.g===s.b).sort((a,b)=>a.ire-b.ire):null;
 const xSteps=allSteps||[...gs].sort((a,b)=>a.ire-b.ire);
 const readingByIre={};
 gs.forEach(r=>{readingByIre[r.ire]=r;});
 // Pre-compute dE values for tooltips
 const deLuv={},de2000={};
 gs.forEach(rd=>{
  const X=rd.X||0,Y=rd.Y||0,Z=rd.Z||0;
  if(Y<=0){deLuv[rd.ire]=0;de2000[rd.ire]=0;return;} // true black: no chroma target
    const ref=hcfrGreyRef(rd.ire, Y, Lw, Lb, inclLum, rd.r_code);
  deLuv[rd.ire]=deltaELuvHCFR(X,Y,Z,ref.YWhite, ref.refX,ref.refY,ref.refZ,ref.YWhiteRef);
  const XnM=D65.X*ref.YWhite, YnM=ref.YWhite, ZnM=D65.Z*ref.YWhite;
  const XnR=D65.X*ref.YWhiteRef, YnR=ref.YWhiteRef, ZnR=D65.Z*ref.YWhiteRef;
  const labM=xyzToLab(X,Y,Z,XnM,YnM,ZnM);
  const labR=xyzToLab(ref.refX,ref.refY,ref.refZ,XnR,YnR,ZnR);
  de2000[rd.ire]=deltaE2000(labM,labR);
 });
 // Register hit zones for each chart canvas
 const canvasIds=['chartRGB','chartDeltaE','chartDeltaE2000','chartEOTF','chartGamma'];
 canvasIds.forEach(cid=>{
  const canvas=document.getElementById(cid);
  if(!canvas) return;
  const dpr=window.devicePixelRatio||1;
  const rect=canvas.getBoundingClientRect();
  const cW=rect.width, cH=rect.height;
  // Estimate chart padding and step positions
  const isBarChart=cid.indexOf('DeltaE')>=0;
  const isSmall=cid==='chartEOTF'||cid==='chartGamma';
  const pad=isBarChart?{t:20,r:15,b:30,l:55}:{t:20,r:15,b:30,l:45};
  const w=cW-pad.l-pad.r;
  const n=xSteps.length;
  const xInset=isBarChart?(Math.max(8,Math.min(30,w/(n*1.5)))/2+4):((cid==='chartRGB')?15:0);
  const dw=w-2*xInset;
  // Build hit zones for each step
  xSteps.forEach((step,idx)=>{
   const rd=readingByIre[step.ire];
   if(!rd) return;
   let cx;
   if(cid==='chartEOTF'||cid==='chartGamma'){
    cx=pad.l+step.ire/100*w;
   } else {
    cx=pad.l+xInset+(n>1?idx/(n-1):0.5)*dw;
   }
   _chartHitZones.push({canvasId:cid, cx:cx, cy:cH/2, radius:isBarChart?18:8, ire:step.ire, reading:rd,
    deLuv:deLuv[rd.ire], de2000:de2000[rd.ire]});
  });
  // Attach event handlers (remove old ones first)
  canvas.onmousemove=function(e){chartHandleHover(e,cid);};
  canvas.onmouseleave=function(){document.getElementById('chartTooltip').style.display='none';};
  canvas.onclick=function(e){chartHandleClick(e,cid);};
  canvas.style.cursor='crosshair';
 });
}

function chartFindHit(e,canvasId){
 const canvas=document.getElementById(canvasId);
 if(!canvas) return null;
 const rect=canvas.getBoundingClientRect();
 const mx=e.clientX-rect.left, my=e.clientY-rect.top;
 let best=null, bestDist=Infinity;
 _chartHitZones.filter(z=>z.canvasId===canvasId).forEach(z=>{
  const dx=mx-z.cx;
  const dist=Math.abs(dx);
  if(dist<Math.max(z.radius,25)&&dist<bestDist){
   bestDist=dist; best=z;
  }
 });
 return best;
}

function chartHandleHover(e,canvasId){
 const hit=chartFindHit(e,canvasId);
 const tip=document.getElementById('chartTooltip');
 if(!hit){tip.style.display='none';return;}
 const rd=hit.reading;
 const bal=meterWhiteReading?rgbBalance(rd,meterWhiteReading,meterIncludeLum()):{R:100,G:100,B:100};
 const gamma=effectiveGamma(rd.luminance,meterWhiteReading?meterWhiteReading.Y:rd.Y,rd.ire);
 let html='<b>'+rd.ire+'%</b><br>';
 html+='Lum: '+(rd.luminance!=null?rd.luminance.toFixed(2):'--')+' cd/m\u00B2';
 if(rd.cct) html+='&nbsp; CCT: '+rd.cct+'K';
 html+='<br>x: '+(rd.x!=null?rd.x.toFixed(4):'--')+' &nbsp;y: '+(rd.y!=null?rd.y.toFixed(4):'--');
 html+='<br>R: '+bal.R.toFixed(1)+' &nbsp;G: '+bal.G.toFixed(1)+' &nbsp;B: '+bal.B.toFixed(1);
 if(gamma!=null) html+='<br>Gamma: '+gamma.toFixed(2);
 if(hit.deLuv!=null) html+='<br>\u0394E CIE76(u\\\'v\\\'): '+hit.deLuv.toFixed(2);
 if(hit.de2000!=null) html+='<br>\u0394E CIEDE2000: '+hit.de2000.toFixed(2);
 tip.innerHTML=html;
 tip.style.display='block';
 // Position near cursor
 const tx=e.clientX+14, ty=e.clientY-10;
 tip.style.left=Math.min(tx,window.innerWidth-tip.offsetWidth-10)+'px';
 tip.style.top=Math.min(ty,window.innerHeight-tip.offsetHeight-10)+'px';
}

function chartHandleClick(e,canvasId){
 const hit=chartFindHit(e,canvasId);
 if(!hit) return;
 const rd=hit.reading;
 updateLiveReading(rd);
 document.getElementById('meterLiveReading').style.display='';
 // Highlight the corresponding thumbnail
 meterSelectedThumbIre=rd.ire;
 const container=document.getElementById('meterPatchThumbs');
 if(container&&container.children.length>0){
  const completedIres=new Set(meterReadings.filter(r=>r.luminance!=null).map(r=>meterStepNameKey(r)));
  meterUpdateThumbStyles(container,completedIres,null);
 }
 document.getElementById('meterProgress').style.display='';
 document.getElementById('meterProgressLabel').textContent=rd.ire+'%';
}

function meterSeriesLabelFromKey(key){
 return {
  'greyscale-21':'Greyscale 21pt',
  'greyscale-11':'Greyscale 11pt',
  'colors-30':'Colors',
  'saturations-24':'Sat Sweep'
 }[key]||String(key||'Series');
}

function meterGetSeriesSnapshotByKey(key){
 if(!key) return null;
 if(key===meterActiveSeriesKey&&meterSeriesSteps&&meterSeriesSteps.length>0){
  meterCacheSeriesState(meterSeriesRunning?'running':'complete');
 }
 const snap=meterSeriesCache[key];
 if(!snap||!snap.steps||snap.steps.length===0) return null;
 const readings=(snap.readings||[]).filter(rd=>meterReadingHasLuminance(rd));
 return {...snap,readings:readings};
}

function meterAllSeriesReportOptions(){
 return [
  {key:'greyscale-21',label:'Greyscale 21pt'},
  {key:'greyscale-11',label:'Greyscale 11pt'},
  {key:'colors-30',label:'Colors'},
  {key:'saturations-24',label:'Sat Sweep'}
 ].map(item=>{
  const snap=meterGetSeriesSnapshotByKey(item.key);
  const count=snap&&snap.readings?snap.readings.length:0;
  return {...item,count:count,hasData:count>0};
 });
}

function meterOpenReportDialog(){
 if(meterActiveSeriesKey&&meterSeriesSteps&&meterSeriesSteps.length>0){
  meterCacheSeriesState(meterSeriesRunning?'running':'complete');
 }
 const items=meterAllSeriesReportOptions();
 const list=document.getElementById('meterReportSeriesList');
 list.innerHTML=items.map(item=>
  '<label style="display:flex;align-items:center;justify-content:space-between;gap:8px;background:#0d0d15;border:1px solid #262b3b;border-radius:6px;padding:8px 10px;cursor:pointer">'
  +'<span style="display:flex;align-items:center;gap:8px"><input type="checkbox" value="'+item.key+'" checked> '+item.label+'</span>'
  +'<span style="font-size:.72rem;color:var(--text2)">'+(item.hasData?(item.count+' readings'):'No data yet')+'</span>'
  +'</label>'
 ).join('');
 document.getElementById('meterReportOverlay').style.display='flex';
}

function meterCloseReportDialog(){
 const overlay=document.getElementById('meterReportOverlay');
 if(overlay) overlay.style.display='none';
}

function meterCloneReportNodeHTML(el){
 if(!el) return '';
 const clone=el.cloneNode(true);
 const sourceCanvases=el.querySelectorAll('canvas');
 const cloneCanvases=clone.querySelectorAll('canvas');
 sourceCanvases.forEach((cv,i)=>{
  const cloneCv=cloneCanvases[i];
  if(!cloneCv) return;
  const img=document.createElement('img');
  try{ img.src=cv.toDataURL('image/png'); }catch(e){ img.src=''; }
  img.style.cssText='width:100%;display:block;background:#0d0d15;border-radius:6px';
  cloneCv.replaceWith(img);
 });
 clone.querySelectorAll('[id]').forEach(node=>node.removeAttribute('id'));
 clone.style.display='';
 return clone.outerHTML;
}

function meterBuildEmptySeriesReportSection(title){
 let html='<section class="report-section">';
 html+='<div class="report-section-title">'+title+'</div>';
 html+='<div class="report-section-meta">0 readings captured</div>';
 html+='<div class="report-empty">No measurement data has been captured for this series yet.</div>';
 html+='</section>';
 return html;
}

function meterBuildCurrentSeriesReportSection(title){
 const count=(meterReadings||[]).filter(rd=>meterReadingHasLuminance(rd)).length;
 let html='<section class="report-section">';
 html+='<div class="report-section-title">'+title+'</div>';
 html+='<div class="report-section-meta">'+count+' readings captured</div>';
 if(meterActiveSeriesType==='greyscale'||!meterActiveSeriesType){
  html+='<div class="report-grid">';
  html+=meterCloneReportNodeHTML(document.getElementById('meterLiveReading'));
  html+=meterCloneReportNodeHTML(document.getElementById('chartRGB')?.parentElement);
  html+=meterCloneReportNodeHTML(document.getElementById('chartDeltaE')?.parentElement);
  html+=meterCloneReportNodeHTML(document.getElementById('chartDeltaE2000')?.parentElement);
  html+=meterCloneReportNodeHTML(document.getElementById('chartEOTF')?.parentElement);
  html+=meterCloneReportNodeHTML(document.getElementById('chartGamma')?.parentElement);
  html+='</div>';
 } else {
  html+='<div class="report-grid">';
  html+=meterCloneReportNodeHTML(document.getElementById('meterLiveReading'));
  html+=meterCloneReportNodeHTML(document.getElementById('chartCIE')?.parentElement);
  html+=meterCloneReportNodeHTML(document.getElementById('chartColorDE')?.parentElement);
  html+='</div>';
  const detail=document.getElementById('colorReadingDetail');
  if(detail) html+=meterCloneReportNodeHTML(detail);
  const avgWrap=document.getElementById('colorSeriesAveragesWrap');
  if(avgWrap&&getComputedStyle(avgWrap).display!=='none') html+=meterCloneReportNodeHTML(avgWrap);
  const tblWrap=document.getElementById('colorReadingsTableWrap');
  if(tblWrap&&getComputedStyle(tblWrap).display!=='none') html+=meterCloneReportNodeHTML(tblWrap);
 }
 html+='</section>';
 return html;
}

function meterBuildReportDocument(sectionHtml){
 return '<!DOCTYPE html><html><head><meta charset="utf-8"><title>PGenerator Measurement Report</title>'
 +'<style>'
 +'body{font-family:Arial,sans-serif;background:#0b1020;color:#e8ecf3;margin:0;padding:24px;} '
 +'.report-header{margin-bottom:18px;padding-bottom:10px;border-bottom:2px solid #2b3350;} '
 +'.report-title{font-size:24px;font-weight:700;margin-bottom:4px;} '
 +'.report-sub{font-size:12px;color:#9aa4bf;} '
 +'.report-section{margin:0 0 22px 0;padding:14px;background:#111522;border:1px solid #2d3348;border-radius:10px;page-break-inside:avoid;} '
 +'.report-section-title{font-size:18px;font-weight:700;margin-bottom:4px;} '
 +'.report-section-meta{font-size:12px;color:#9aa4bf;margin-bottom:10px;} '
 +'.report-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:12px;align-items:start;} '
 +'.report-empty{padding:16px;border:1px dashed #4a5478;border-radius:8px;color:#bcc6df;background:#0d0d15;font-size:13px;} '
 +'canvas,img{max-width:100%;} table{width:100%;} @media print{body{background:#fff;color:#000;padding:0;} .report-section{border:1px solid #ccc;background:#fff;} .report-empty{background:#f7f7f7;color:#444;border-color:#bbb;} }'
 +'</style></head><body>'
 +'<div class="report-header"><div class="report-title">PGenerator Measurement Report</div><div class="report-sub">Generated '+new Date().toLocaleString()+'</div></div>'
 +sectionHtml+'</body></html>';
}

async function meterGenerateReport(){
 const selected=[...document.querySelectorAll('#meterReportSeriesList input[type="checkbox"]:checked')].map(x=>x.value);
 if(selected.length===0){toast('Select at least one series to include',true);return;}
 const format=(document.querySelector('input[name="meterReportFormat"]:checked')||{}).value||'html';
 const btn=document.getElementById('meterReportGenerateBtn');
 if(btn){btn.disabled=true;btn.textContent='Generating…';}
 const restore={
  key:meterActiveSeriesKey,
  selectedName:_selectedColorReadingName,
  pinned:_colorDetailPinned,
  currentPatch:meterCurrentPatchStep?{...meterCurrentPatchStep}:null,
  selectedThumb:meterSelectedThumbIre
 };
 if(restore.key&&meterSeriesSteps&&meterSeriesSteps.length>0){
  meterCacheSeriesState(meterSeriesRunning?'running':'complete');
 }
 let sectionHtml='';
 try{
  for(const key of selected){
   const snap=meterGetSeriesSnapshotByKey(key);
   if(!snap||!snap.readings||snap.readings.length===0){
    sectionHtml+=meterBuildEmptySeriesReportSection(meterSeriesLabelFromKey(key));
    continue;
   }
   meterRestoreSeriesFromCache(key);
   await new Promise(resolve=>requestAnimationFrame(resolve));
   sectionHtml+=meterBuildCurrentSeriesReportSection(meterSeriesLabelFromKey(key));
  }
 } finally {
  if(restore.key){
   meterRestoreSeriesFromCache(restore.key);
   if(restore.selectedName&&restore.pinned){
    const sel=(meterReadings||[]).find(r=>r&&r.name===restore.selectedName);
    if(sel) showColorReadingDetail(sel,{pin:true});
   }
   meterCurrentPatchStep=restore.currentPatch;
   meterSelectedThumbIre=restore.selectedThumb;
  }
  if(btn){btn.disabled=false;btn.textContent='Generate';}
 }
 if(!sectionHtml){toast('No reportable series data found',true);return;}
 const html=meterBuildReportDocument(sectionHtml);
 meterCloseReportDialog();
 if(format==='pdf'){
  const win=window.open('','_blank');
  if(!win){toast('Pop-up blocked — allow pop-ups to create PDF',true);return;}
  win.document.open();
  win.document.write(html);
  win.document.close();
  setTimeout(()=>{win.focus();win.print();},400);
  toast('Print dialog opened — choose Save as PDF');
 } else {
  const blob=new Blob([html],{type:'text/html'});
  const a=document.createElement('a');
  a.href=URL.createObjectURL(blob);
  a.download='pgenerator_measurement_report.html';
  a.click();
  setTimeout(()=>URL.revokeObjectURL(a.href),1000);
  toast('HTML report downloaded');
 }
}

function meterExportCSV(){
 if(!meterReadings||meterReadings.length===0){toast('No data to export',true);return;}
 const sorted=[...meterReadings].sort((a,b)=>(a.ire||0)-(b.ire||0));
 const whiteR=meterWhiteReading||sorted.find(r=>r.ire===100);
 if(!whiteR){toast('No 100% white reading \u2014 run a full series first',true);return;}
 const Lw=whiteR.luminance||whiteR.Y;
 // Measured-white adaptation for grey tracking (matching chart)
 const Xn=whiteR?whiteR.X:(D65.X*Lw);
 const Yn=whiteR?whiteR.Y:Lw;
 const Zn=whiteR?whiteR.Z:(D65.Z*Lw);
 const blacks=meterReadings.filter(r=>(r.ire||0)<=5&&r.luminance!=null);
 const Lb=blacks.length>0?Math.min(...blacks.map(r=>r.luminance)):0;
 const inclLum=meterIncludeLum();
 let csv='Step,Name,IRE,R_code,G_code,B_code,X,Y,Z,x,y,Luminance,CCT,Gamma,R_bal,G_bal,B_bal,dEuv,dE2000\n';
 // Helper: is this reading a neutral-grey patch (greyscale sweep) vs a chroma
 // patch (colors / saturations)? Greyscale uses the hcfr greyRef path; chroma
 // uses the per-color target so each patch gets its own ΔE instead of a
 // single IRE-keyed value.
 const isGrey=rd=>(rd.r_code||0)===(rd.g_code||0)&&(rd.g_code||0)===(rd.b_code||0);
 sorted.forEach((rd,i)=>{
  const X=rd.X||0,Y=rd.Y||0,Z=rd.Z||0;
  let dE=0,dE2k=0;
  if(Y>0){
   if(isGrey(rd)){
    const ref=hcfrGreyRef(rd.ire||0,Y,Lw,Lb,inclLum,rd.r_code);
    dE=deltaELuvHCFR(X,Y,Z,ref.YWhite, ref.refX,ref.refY,ref.refZ,ref.YWhiteRef);
    const labM=xyzToLab(X,Y,Z, D65.X*ref.YWhite, ref.YWhite, D65.Z*ref.YWhite);
    const labR=xyzToLab(ref.refX,ref.refY,ref.refZ, D65.X*ref.YWhiteRef, ref.YWhiteRef, D65.Z*ref.YWhiteRef);
    dE2k=deltaE2000(labM,labR);
   } else {
      // Color / sat-sweep patch: use the per-patch target generated from the
      // active gamut so export matches the live charts.
    const tgt=meterTargetChromaticityForReading(rd);
    const du=4*(rd.x||0)/(-2*(rd.x||0)+12*(rd.y||0)+3)-4*tgt.x/(-2*tgt.x+12*tgt.y+3);
    const dv=9*(rd.y||0)/(-2*(rd.x||0)+12*(rd.y||0)+3)-9*tgt.y/(-2*tgt.x+12*tgt.y+3);
    dE=Math.sqrt(du*du+dv*dv)*1000; // scaled u'v' distance — rough dEuv stand-in
    dE2k=meterColorDeltaE2000(rd,inclLum);
   }
  }
  const g=effectiveGamma(rd.luminance,Lw,rd.ire);
  const bal=meterWhiteReading?rgbBalance(rd,meterWhiteReading,inclLum):{R:100,G:100,B:100};
  csv+=[i+1,rd.name||'',rd.ire||'',rd.r_code||0,rd.g_code||0,rd.b_code||0,
   (rd.X||0).toFixed(4),(rd.Y||0).toFixed(4),(rd.Z||0).toFixed(4),
   (rd.x||0).toFixed(4),(rd.y||0).toFixed(4),(rd.luminance||0).toFixed(4),
   rd.cct||'',g!==null?g.toFixed(2):'',bal.R.toFixed(1),bal.G.toFixed(1),bal.B.toFixed(1),
   dE.toFixed(2),dE2k.toFixed(2)
  ].join(',')+'\n';
 });
 const blob=new Blob([csv],{type:'text/csv'});
 const a=document.createElement('a');
 a.href=URL.createObjectURL(blob);
 a.download='pgenerator_measurements.csv';
 a.click();
}

let meterSharedSeriesId=null;

function meterApplyClearedState(showToastMsg){
 if(meterActiveSeriesKey) delete meterSeriesCache[meterActiveSeriesKey];
 meterReadings=[];
 meterWhiteReading=null;
 meterLastChartCount=0;
 meterCurrentPatchStep=null;
 meterSelectedThumbIre=null;
 _selectedColorReadingName=null;
 _colorDetailPinned=false;
 document.getElementById('meterProgress').style.display='none';
 document.getElementById('meterLiveReading').style.display='none';
 document.getElementById('meterExportRow').style.display='none';
 document.getElementById('meterStopBtn').style.display='none';
 if(meterSeriesSteps&&meterSeriesSteps.length>0){
  const isColor=meterActiveSeriesType==='colors'||meterActiveSeriesType==='saturations';
  const sortedSteps=isColor?[...meterSeriesSteps]:[...meterSeriesSteps].sort((a,b)=>(a.ire||0)-(b.ire||0));
  document.getElementById('meterCharts').style.display='';
  document.getElementById('meterThumbsRow').style.display='';
  document.getElementById('meterReadSeriesBtn').style.display='';
  meterBuildPatchThumbs(sortedSteps,new Set(),null);
  drawAllChartsPreset(sortedSteps);
  meterResetSeriesButtons();
  if(meterActiveSeriesKey){
   const activeBtn=document.querySelector('#meterSeriesBtnRow button[data-series="'+meterActiveSeriesKey+'"]');
   if(activeBtn){activeBtn.classList.remove('btn-secondary');activeBtn.classList.add('btn-primary');}
  }
 } else {
  meterResetSeriesButtons();
  meterActiveSeriesKey=null;
  meterActiveSeriesType=null;
  meterActiveSeriesPoints=null;
  document.getElementById('meterPatchThumbs').innerHTML='';
  document.getElementById('meterThumbsRow').style.display='none';
  document.getElementById('meterReadSeriesBtn').style.display='none';
  document.getElementById('meterCharts').style.display='none';
 }
 meterUpdateReadButtons();
 if(showToastMsg) toast('Chart data cleared');
}

async function meterClearResults(){
 meterStopContinuous();
 if(meterSeriesPolling){clearInterval(meterSeriesPolling);meterSeriesPolling=null;}
 meterSeriesRunning=false;
 meterSharedSeriesId=null;
 try{await fetchJSON('/api/meter/clear',{method:'POST',_quiet:true,_timeoutMs:5000});}catch(e){}
 meterApplyClearedState(true);
}

// Display type → gamma auto-selection + custom CCSS panel
let customCcssFile=null;
loadMeterCcssOptions();
document.getElementById('meterDisplayType').addEventListener('change',function(){
 const v=this.value;
 applyMeterTargetGammaDefault();
 // Emissive if selecting an emissive generic type, any display-specific CCSS,
 // or the custom-upload panel.
 const vl=v.toLowerCase();
 const ccssEmissive=vl.startsWith('ccss_')&&/(oled|plasma|crt)/i.test(vl);
 const emissive=v.startsWith('oled')||v.startsWith('qdoled')||v==='plasma'||v==='crt'||v==='custom'||ccssEmissive;
 document.getElementById('meterPatchInsert').checked=emissive;
 document.getElementById('customCcssPanel').style.display=v==='custom'?'':'none';
 if(v==='custom') loadCustomCcssList();
});

// Custom CCSS file input
document.getElementById('ccssFileInput').addEventListener('change',function(){
 const file=this.files[0];
 const nameInput=document.getElementById('ccssName');
 const btn=document.getElementById('ccssUploadBtn');
 if(file){
  let baseName=file.name.replace(/\.(ccss|csv)$/i,'');
  nameInput.value=baseName;
  btn.disabled=false;
 } else {
  nameInput.value='';
  btn.disabled=true;
 }
});

document.getElementById('ccssUploadBtn').addEventListener('click',async function(){
 const file=document.getElementById('ccssFileInput').files[0];
 const name=document.getElementById('ccssName').value.trim();
 if(!file||!name){toast('Select a file and enter a name',true);return;}
 const status=document.getElementById('ccssUploadStatus');
 status.textContent='Uploading...';
 this.disabled=true;
 try{
  const buf=await file.arrayBuffer();
  const b64=btoa(String.fromCharCode(...new Uint8Array(buf)));
  const r=await fetchJSON('/api/ccss/upload',{method:'POST',headers:{'Content-Type':'application/json'},
   body:JSON.stringify({name:name,content:b64,filename:file.name}),_timeoutMs:15000});
  if(r&&r.status==='ok'){
   status.textContent=r.message||'Uploaded';
   status.style.color='var(--green)';
   customCcssFile=r.filename;
   document.getElementById('ccssFileInput').value='';
   document.getElementById('ccssName').value='';
   loadCustomCcssList();
   toast(r.message||'CCSS profile saved');
  } else {
   status.textContent=r&&r.message?r.message:'Upload failed';
   status.style.color='var(--red)';
   toast(r&&r.message?r.message:'Upload failed',true);
  }
 }catch(e){
  status.textContent='Upload error';
  status.style.color='var(--red)';
 }
 this.disabled=false;
 setTimeout(()=>{status.textContent='';status.style.color='var(--text2)';},5000);
});

async function loadCustomCcssList(){
 const r=await fetchJSON('/api/ccss/list',{_quiet:true,_timeoutMs:5000});
 const el=document.getElementById('customCcssList');
 if(!r||!r.files||r.files.length===0){el.innerHTML='<div style="font-size:.7rem;color:var(--text2)">No custom profiles</div>';return;}
 el.innerHTML=r.files.map(f=>{
  const label=f.replace(/\.ccss$/i,'');
  const active=customCcssFile===f;
  return '<div style="display:flex;align-items:center;gap:6px;margin-bottom:3px">'
  +'<button class="btn btn-sm '+(active?'btn-success':'btn-secondary')+'" style="flex:1;font-size:.7rem;padding:2px 6px;text-align:left" onclick="selectCustomCcss(\''+f+'\')">'+(active?'\u2713 ':'')+label+'</button>'
  +'<button class="btn btn-sm" style="font-size:.68rem;padding:2px 6px;color:var(--red)" onclick="deleteCustomCcss(\''+f+'\')">\u2715</button></div>';
 }).join('');
}

function selectCustomCcss(filename){
 customCcssFile=filename;
 loadCustomCcssList();
}

function ccssCleanLabelPart(text){
 return String(text||'').replace(/\.ccss$/i,'').replace(/_/g,' ').replace(/\s+/g,' ').trim();
}

function ccssPrettyTechnology(text){
 let tech=ccssCleanLabelPart(text)
  .replace(/\bQD OLED\b/gi,'QD-OLED')
  .replace(/\bWRGB OLED\b/gi,'WRGB OLED')
  .replace(/\bRGB OLED\b/gi,'RGB OLED')
  .replace(/\bJOLED\b/g,'JOLED')
  .replace(/\bWLED\b/g,'W-LED')
  .replace(/\bQD Mini LED\b/gi,'QD-Mini LED')
  .replace(/\bMini LED\b/gi,'Mini-LED')
  .replace(/\bGB R LED\b/gi,'GB-R LED')
  .replace(/\bRG Phosphor\b/gi,'RG Phosphor')
  .replace(/\bPFS Phosphor\b/gi,'PFS Phosphor')
  .replace(/\bLCD White LED IPS\b/gi,'W-LED IPS LCD');
 return tech;
}

function ccssDisplayStartsWithType(display){
 return /^(?:white led|w-?led|qd-?oled|wrgb oled|rgb qd-?oled|rgb oled|oled|lcd|plasma|projector|crt|ccfl|rgb led|pfs phosphor|rg phosphor)\b/i.test(String(display||'').trim());
}

function ccssDisplayLooksIncomplete(display){
 const text=String(display||'').trim();
 if(!text) return true;
 const open=(text.match(/\(/g)||[]).length;
 const close=(text.match(/\)/g)||[]).length;
 if(open!==close) return true;
 if(/\((?:RGB|WRGB|QD|W|GB|VA|IPS)\s*$/i.test(text)) return true;
 return false;
}

function ccssLabelLooksGeneric(label){
 return ccssDisplayStartsWithType(label) || /(?:^|\s)(?:generic|family)(?:\s|$)/i.test(String(label||''));
}

function ccssIsGenericProfile(entry){
 const name=String((entry&&entry.name)||'');
 const display=String((entry&&entry.display)||'');
 return /^(?:WRGB_OLED_LG|QD-OLED_Generic|WLEDFamily_07Feb11|CCFLFamily_07Feb11|WGCCFLFamily_07Feb11|RGBLEDFamily_07Feb11|PlasmaFamily_20Jul12|ProjectorFamily_07Feb11|CRT)\.ccss$/i.test(name)
  || /^(?:White_LED|RGB_LED|CCFL|Wide_Gamut_CCFL|PFS_Phosphor|RG_Phosphor|Plasma|Projector)_/i.test(name)
  || /(?:^|\s)(?:Generic|Family)(?:\s|$)/i.test(display);
}

function ccssFormatNameFromFilename(name){
 const base=String(name||'').replace(/\.ccss$/i,'').replace(/_-_.*/,'');
 let match=base.match(/^(.*)_\(([^)]+)\)$/);
 if(match){
  return ccssCleanLabelPart(match[1])+' ('+ccssPrettyTechnology(match[2])+')';
 }
 match=base.match(/^(QD-OLED|WRGB_OLED|RGB_OLED|LCD|CRT|Plasma|Projector|White_LED|RGB_LED|CCFL|Wide_Gamut_CCFL|PFS_Phosphor|RG_Phosphor)_(.+)$/i);
 if(match){
  return ccssCleanLabelPart(match[2])+' ('+ccssPrettyTechnology(match[1])+')';
 }
 return ccssCleanLabelPart(base);
}

  function ccssLegacyTechFirstName(name){
   return /^(?:QD-OLED|WRGB_OLED|RGB_OLED|LCD|CRT|Plasma|Projector|White_LED|RGB_LED|CCFL|Wide_Gamut_CCFL|PFS_Phosphor|RG_Phosphor)_/i.test(String(name||''));
  }

function ccssFormatDropdownLabel(entry){
 const display=ccssCleanLabelPart(entry&&entry.display);
 const technology=ccssPrettyTechnology(entry&&entry.technology);
 const filenameLabel=ccssFormatNameFromFilename(entry&&entry.name);
 const hasKnownTechnology=technology && !/^unknown$/i.test(technology);
 const displayHasCompleteType=/\([^)]*\)\s*$/.test(display) && !ccssDisplayLooksIncomplete(display);
 const metadataLabel=displayHasCompleteType ? display : (display && hasKnownTechnology ? display+' ('+technology+')' : display);
 const metadataBad=!display || ccssDisplayLooksIncomplete(display) || ccssLabelLooksGeneric(display);
 const filenameBetter=filenameLabel && /\([^)]*\)/.test(filenameLabel) && (!metadataLabel || ccssDisplayLooksIncomplete(metadataLabel) || ccssLabelLooksGeneric(metadataLabel) || filenameLabel.length>metadataLabel.length);
 if(filenameBetter || metadataBad) return filenameLabel||metadataLabel||display;
 if(metadataLabel) return metadataLabel;
 return filenameLabel;
}

// Populate the display-specific CCSS optgroup with all .ccss files on the device,
// sorted alphabetically. Option value is "ccss_FILENAME" (for system) or
// "custom_FILENAME" (for user-uploaded). The backend's resolve_display_type()
// handles both prefixes identically.
async function loadMeterCcssOptions(){
 const r=await fetchJSON('/api/ccss/all',{_quiet:true,_timeoutMs:5000});
 const grp=document.getElementById('meterDtCcss');
 if(!grp) return;
 grp.innerHTML='';
 if(!r||!r.files||r.files.length===0) return;
 const sel=document.getElementById('meterDisplayType');
 const prev=sel.value;
 const byLabel=new Map();
 r.files.forEach(f=>{
  if(f.source==='system'&&ccssIsGenericProfile(f)) return;
  const label=ccssFormatDropdownLabel(f);
  if(!label) return;
  const score=(f.source==='custom'?1000:0)
   +(ccssLegacyTechFirstName(f.name)?0:100)
   +((f.display&&f.technology)?20:0)
   +(String(f.name||'').length>0?Math.min(String(f.name).length,50):0);
  const current=byLabel.get(label);
  if(!current||score>current.score){
   byLabel.set(label,{entry:f,label:label,score:score});
  }
 });
 [...byLabel.values()].sort((a,b)=>a.label.localeCompare(b.label)).forEach(item=>{
  const f=item.entry;
  const prefix=f.source==='custom'?'custom_':'ccss_';
  const opt=document.createElement('option');
  opt.value=prefix+f.name;
  opt.textContent=item.label+(f.source==='custom'?' (custom)':'');
  grp.appendChild(opt);
 });
 // restore previous selection if still present
 if(prev) sel.value=prev;
}

function getMeterPatchSize(){
 // Accepts plain integer ("10", "18", ...) or APL-prefixed ("apl_5").
 // APL options currently render as a window of N% on black = N% APL.
 const raw=document.getElementById('meterPatchSize').value;
 const m=String(raw).match(/^apl_(\d+)/i);
 if(m) return parseInt(m[1],10);
 return parseInt(raw,10);
}

function getEffectiveDisplayType(){
 const v=document.getElementById('meterDisplayType').value;
 if(v==='custom'&&customCcssFile) return 'custom_'+customCcssFile;
 return v;
}

function getMeterRefreshRate(){
 const sel=document.getElementById('meterRefreshRate');
 if(sel.value) return sel.value;
 // "Display Setting" — look up current mode's refresh from modes array
 if(modes&&config.mode_idx!=null){
  const m=modes.find(m=>String(m.idx)===String(config.mode_idx));
  if(m&&m.refresh) return m.refresh;
 }
 return '';
}

async function deleteCustomCcss(filename){
 if(!confirm('Delete '+filename+'?')) return;
 const r=await fetchJSON('/api/ccss/delete/'+encodeURIComponent(filename),{method:'POST',_timeoutMs:5000});
 if(r&&r.status==='ok'){
  if(customCcssFile===filename) customCcssFile=null;
  loadCustomCcssList();
  toast('Deleted');
 } else { toast(r&&r.message?r.message:'Delete failed',true); }
}

// Meter settings persistence — save to server so all clients share the same settings
function saveMeterSettings(){
 const s={
  display_type:document.getElementById('meterDisplayType').value,
  target_gamut:(document.getElementById('meterTargetGamut')||{}).value||'auto',
  delay:document.getElementById('meterDelay').value,
  patch_size:document.getElementById('meterPatchSize').value,
  patch_insert:document.getElementById('meterPatchInsert').checked,
  disable_aio:document.getElementById('meterDisableAIO').checked,
  refresh_rate:document.getElementById('meterRefreshRate').value,
  ccss_file:customCcssFile||''
 };
 fetchJSON('/api/meter/settings',{method:'POST',headers:{'Content-Type':'application/json'},
  body:JSON.stringify(s),_quiet:true,_timeoutMs:5000});
}
async function loadMeterSettings(){
 const s=await fetchJSON('/api/meter/settings',{_quiet:true,_timeoutMs:5000});
 if(!s||!s.display_type) return;
 if(s.display_type) document.getElementById('meterDisplayType').value=s.display_type;
 if(s.target_gamut!=null) document.getElementById('meterTargetGamut').value=s.target_gamut||'auto';
 if(s.delay) document.getElementById('meterDelay').value=s.delay;
 if(s.patch_size) document.getElementById('meterPatchSize').value=s.patch_size;
 if(s.patch_insert!=null) document.getElementById('meterPatchInsert').checked=!!s.patch_insert;
 if(s.disable_aio!=null) document.getElementById('meterDisableAIO').checked=!!s.disable_aio;
 if(s.refresh_rate!=null) document.getElementById('meterRefreshRate').value=s.refresh_rate;
 if(s.ccss_file) customCcssFile=s.ccss_file;
 document.getElementById('customCcssPanel').style.display=s.display_type==='custom'?'':'none';
 applyMeterTargetGammaDefault();
}
// Add change listeners for auto-save
['meterDisplayType','meterTargetGamut','meterDelay','meterPatchSize','meterRefreshRate'].forEach(id=>{
 document.getElementById(id).addEventListener('change',saveMeterSettings);
});
['meterPatchInsert','meterDisableAIO'].forEach(id=>{
 document.getElementById(id).addEventListener('change',saveMeterSettings);
});

document.getElementById('meterTargetGamut').addEventListener('change',()=>{
 if(!meterActiveSeriesType||!meterActiveSeriesPoints||meterSeriesRunning) return;
 meterSeriesSteps=meterBuildStepsJS(meterActiveSeriesType,meterActiveSeriesPoints);
 const isColor=meterActiveSeriesType==='colors'||meterActiveSeriesType==='saturations';
 const sortedSteps=isColor?[...meterSeriesSteps]:[...meterSeriesSteps].sort((a,b)=>(a.ire||0)-(b.ire||0));
 const done=new Set();
 (meterReadings||[]).forEach(r=>{if(r.luminance!=null) done.add(meterStepNameKey(r));});
 meterBuildPatchThumbs(sortedSteps,done,meterCurrentPatchStep?meterStepNameKey(meterCurrentPatchStep):null);
 if(meterReadings&&meterReadings.length){
  const sorted=isColor?[...meterReadings]:[...meterReadings].sort((a,b)=>(a.ire||0)-(b.ire||0));
  drawAllCharts(sorted);
 } else {
  drawAllChartsPreset(sortedSteps);
 }
});

// Init
(async()=>{
 await loadConfig(true);
 await Promise.all([loadModes(true),loadCapabilities(true)]);
 updateDropdowns();
 refreshSavedSettingsSnapshot();
 await Promise.all([checkPing(),loadStats(true),loadInfo()]);
 loadMemory();
 setTimeout(()=>loadMeterSettings(),500);
 setTimeout(()=>loadCecStatus(),500);
 setTimeout(()=>loadAP(),1000);
 setTimeout(()=>loadInfoframes(),1500);
 setTimeout(()=>checkUpdate(),60000);
 setInterval(checkPing,10000);
 setInterval(()=>loadStats(true),3000);
 setInterval(syncRemoteConfig,10000);
 setInterval(()=>loadInfo(true),30000);
 // Meter: check on startup, poll every 10s
 setTimeout(()=>meterCheckStatus(),2000);
 setInterval(()=>meterCheckStatus(),10000);
})();
</script>
</body>
</html>
WEBUI_HTML
}

return 1;
