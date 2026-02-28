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

###############################################
#              mDNS Responder                 #
###############################################
sub webui_mdns (@) {
 my $MDNS_ADDR="224.0.0.251";
 my $MDNS_PORT=5353;
 my $mdns_hostname="pgenerator";

 # Create UDP socket bound to mDNS port
 socket(my $sock, Socket::PF_INET, Socket::SOCK_DGRAM, getprotobyname('udp'))
  || do { &log("mDNS: socket failed: $!"); return; };
 setsockopt($sock, Socket::SOL_SOCKET, Socket::SO_REUSEADDR, pack("l",1));

 # SO_REUSEPORT if available
 eval { setsockopt($sock, Socket::SOL_SOCKET, 15, pack("l",1)); };

 bind($sock, Socket::sockaddr_in($MDNS_PORT, Socket::INADDR_ANY))
  || do { &log("mDNS: bind failed: $!"); return; };

 # Join multicast group on all interfaces
 my $mreq = Socket::inet_aton($MDNS_ADDR) . Socket::INADDR_ANY;
 my $IP_ADD_MEMBERSHIP=eval { Socket::IP_ADD_MEMBERSHIP() } || 35; # 35 on Linux
 setsockopt($sock, 0, $IP_ADD_MEMBERSHIP, $mreq)
  || do { &log("mDNS: multicast join failed: $!"); };

 &log("mDNS: responder started for $mdns_hostname.local on port $MDNS_PORT");

 while(1) {
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

  # Parse first question
  my $offset=12;
  my $qname="";
  while($offset < length($buf)) {
   my $len=ord(substr($buf,$offset,1));
   last if($len == 0);
   $offset++;
   $qname.="." if($qname ne "");
   $qname.=substr($buf,$offset,$len);
   $offset+=$len;
  }
  $offset++; # skip null terminator
  next if($offset+4 > length($buf));
  my ($qtype,$qclass)=unpack("nn",substr($buf,$offset,4));

  # Respond to A record queries for pgenerator.local
  next unless(lc($qname) eq "$mdns_hostname.local" && ($qtype == 1 || $qtype == 255));

  # Get our IP addresses with subnet masks
  my @ifaces;
  my $ifdata=`ip -4 addr show 2>/dev/null`;
  while($ifdata=~/inet\s+(\d+\.\d+\.\d+\.\d+)\/(\d+)/g) {
   next if($1 eq "127.0.0.1");
   push @ifaces, { ip => $1, prefix => $2 };
  }

  # Find the best IP to respond with by matching querier's subnet
  my $querier_ip=Socket::inet_ntoa($qaddr);
  my $best_ip="";
  foreach my $iface (@ifaces) {
   my $mask = (0xFFFFFFFF << (32 - $iface->{prefix})) & 0xFFFFFFFF;
   my $net_a = unpack("N", Socket::inet_aton($iface->{ip})) & $mask;
   my $net_q = unpack("N", Socket::inet_aton($querier_ip)) & $mask;
   if($net_a == $net_q) {
    $best_ip=$iface->{ip};
    last;
   }
  }
  # Fallback to first non-loopback IP if no subnet match
  $best_ip=$ifaces[0]->{ip} if($best_ip eq "" && @ifaces);
  next if($best_ip eq "");

  # Build mDNS response with single A record
  my $resp=pack("n",0);           # ID=0 for mDNS
  $resp.=pack("n",0x8400);        # flags: QR=1, AA=1
  $resp.=pack("nnnn",0,1,0,0);    # 0 questions, 1 answer, 0 auth, 0 additional

  # Encode name
  foreach my $label (split(/\./,$qname)) {
   $resp.=pack("C",length($label)).$label;
  }
  $resp.=pack("C",0);             # null terminator
  $resp.=pack("nn",1,0x8001);     # type=A, class=IN+cache-flush
  $resp.=pack("N",120);           # TTL=120s
  $resp.=pack("n",4);             # RDLENGTH=4
  $resp.=Socket::inet_aton($best_ip); # RDATA=IP

  # Send to multicast group
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

sub webui_http (@) {
 $SIG{PIPE}='IGNORE';
 my $http_port=80;

 my $http_server = IO::Socket::INET->new(
  LocalHost => "0.0.0.0",
  LocalPort => $http_port,
  Proto     => 'tcp',
  Listen    => 10,
  ReuseAddr => 1,
 );
 if(!$http_server) {
  &log("WebUI: failed to bind port $http_port: $! — trying 8080");
  $http_port=8080;
  $http_server = IO::Socket::INET->new(
   LocalHost => "0.0.0.0",
   LocalPort => $http_port,
   Proto     => 'tcp',
   Listen    => 10,
   ReuseAddr => 1,
  ) || do { &log("WebUI: failed to bind port $http_port: $!"); return; };
 }
 &log("WebUI: HTTP server started on port $http_port");

 while(1) {
  my $client=$http_server->accept();
  next if(!$client);
  eval {
   # Per-socket read timeout (thread-safe, unlike alarm/SIGALRM which is process-wide)
   setsockopt($client, Socket::SOL_SOCKET(), Socket::SO_RCVTIMEO(), pack('l!l!', 10, 0));
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
    read($client,$body,$cl);
   }

   my ($method,$path)=$req=~/^(GET|POST|PUT|OPTIONS)\s+(\S+)/;
   $path="" if(!defined $path);
   &log("WebUI: $method $path");

   # CORS headers for API
   my $cors="Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\n";

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
     my $result=&webui_apply_config($body);
     my $len=length($result);
     print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
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
   elsif($path eq "/api/restart") {
    &pattern_generator_stop();
    &pattern_generator_start();
    my $r='{"status":"ok","message":"Pattern generator restarted"}';
    my $len=length($r);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$r";
   }
   elsif($path eq "/api/reboot") {
    my $r='{"status":"ok","message":"Rebooting..."}';
    my $len=length($r);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$r";
    close($client);
    system("$reboot &");
    return;
   }
   elsif($path eq "/api/modes") {
    my $json=&webui_modes_json();
    my $len=length($json);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$json";
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
   elsif($path eq "/api/pattern" && $method eq "POST") {
    my $result=&webui_pattern($body);
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/update/check") {
    my $result=&sudo("BASH_CMD", "PGPLUS_CHECK");
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
    my $cmd_b64=encode_base64("BASH_CMD","")." ".encode_base64("PGPLUS_APPLY","");
    system("(sleep 2 && PG_CMD=\"$cmd_b64\" sudo -E /usr/bin/PGenerator_cmd.pl) &");
    return;
   }
   else {
    my $msg="404 Not Found";
    print $client "HTTP/1.1 404 Not Found\r\nContent-Length: ".length($msg)."\r\n\r\n$msg";
   }
  };
  if($@) {
   &log("WebUI: request error: $@");
  }
  eval { close($client); };
 }
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
 # Keys that require pattern generator restart
 my %restart_keys=map{$_=>1} qw(mode_idx eotf is_hdr is_sdr colorimetry primaries
  min_luma max_luma max_cll max_fall color_format rgb_quant_range max_bpc
  dv_status is_ll_dovi is_std_dovi dv_interface dv_metadata dv_color_space);

 foreach my $k (sort keys %changes) {
  next if($k eq "ip_pattern" || $k eq "port_pattern"); # read-only
  &sudo("SET_PGENERATOR_CONF",$k,$changes{$k});
  $pgenerator_conf{$k}=$changes{$k};
  $need_restart=1 if($restart_keys{$k});
 }
 if($need_restart) {
  &pattern_generator_stop();
  &pattern_generator_start();
 }
 return '{"status":"ok","restart":'.($need_restart ? 'true' : 'false').'}';
}

sub webui_info_json (@) {
 my $hostname=&read_from_file($hostname_file);
 $hostname=~s/\s+//g;
 my $temp=&get_temperature();
 $temp=~s/[^\d.]//g;
 my $uptime=&read_from_file($uptime_file);
 ($uptime)=$uptime=~/^([\d.]+)/;
 my $ip_info=`ip -4 addr show 2>/dev/null`;
 my @ips;
 while($ip_info=~/inet\s+([\d.\/]+)\s.*?(\S+)\s*$/gm) {
  my ($addr,$iface)=($1,$2);
  next if($addr=~/^127\./);
  push @ips, "\"$iface\":\"$addr\"";
 }
 my $ip_json="{".join(",",@ips)."}";
 my $ver=$version;

 # Current resolution
 my $resolution="unknown";
 if($hdmi_info=~/(\d+)x(\d+)\s*\@\s*([\d.]+)/) {
  my $hz=int($3+0.5);
  $resolution="${1}x${2}\@${hz}Hz";
 } elsif(defined $w_s && defined $h_s && $w_s > 0) {
  $resolution="${w_s}x${h_s}";
 }

 # Get WiFi connection info
 my $wifi_ssid="";
 my $wifi_freq="";
 my $wifi_signal="";
 my $wifi_state="";
 my $wifi_status=&sudo("GET_WIFI_STATUS","wlan0");
 foreach my $wline (split(/\n/,$wifi_status)) {
  if($wline=~/^ssid\s*=\s*(.*)/) { $wifi_ssid=$1; }
  if($wline=~/^freq\s*=\s*(\d+)/) { $wifi_freq=$1; }
  if($wline=~/^wpa_state\s*=\s*(.*)/) { $wifi_state=$1; }
 }
 $wifi_ssid=~s/"/\\"/g;
 my $wifi_band="";
 if($wifi_freq=~/^\d+$/) {
  $wifi_band=($wifi_freq>=5000)?"5 GHz":"2.4 GHz";
 }
 my $iw_out=`iw dev wlan0 station dump 2>/dev/null`;
 if($iw_out=~/signal:\s*(-?\d+)/){ $wifi_signal=$1; }

 my $cal_ip=$calibration_client_ip; $cal_ip=~s/"/\\"/g;
 my $cal_sw=$calibration_client_software; $cal_sw=~s/"/\\"/g;
 my $cal_conn=($cal_ip ne "")?"true":"false";
 return "{\"hostname\":\"$hostname\",\"version\":\"$ver\",\"temperature\":\"$temp\",\"uptime\":\"$uptime\",\"resolution\":\"$resolution\",\"interfaces\":$ip_json,\"wifi\":{\"ssid\":\"$wifi_ssid\",\"freq\":\"$wifi_freq\",\"band\":\"$wifi_band\",\"signal\":\"$wifi_signal\",\"state\":\"$wifi_state\"},\"calibration\":{\"connected\":$cal_conn,\"ip\":\"$cal_ip\",\"software\":\"$cal_sw\"}}";
}

sub webui_modes_json (@) {
 my @modes;
 my $output=`$modetest -c 2>/dev/null`;
 # Parse modes from modetest output
 while($output=~/^\s*#?(\d+)\s+(\d+x\d+)\s+([\d.]+)\s+/gm) {
  my ($idx,$res,$hz)=($1,$2,$3);
  push @modes, "{\"idx\":$idx,\"resolution\":\"$res\",\"refresh\":\"$hz\"}";
 }
 return "[".join(",",@modes)."]";
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
 my $status=&sudo("GET_WIFI_STATUS","wlan0");
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
 my $iw_out=`iw dev wlan0 station dump 2>/dev/null`;
 if($iw_out=~/signal:\s*(-?\d+)/){ $signal=$1; }
 my $band="";
 if($freq=~/^\d+$/) {
  $band=($freq>=5000)?"5 GHz":"2.4 GHz";
 }
 return "{\"status\":\"ok\",\"wpa_state\":\"$state\",\"ssid\":\"$ssid\",\"freq\":\"$freq\",\"band\":\"$band\",\"signal\":\"$signal\",\"ip\":\"$ip\",\"bssid\":\"$bssid\"}";
}

sub webui_infoframes_json (@) {
 my $dmesg=`/bin/dmesg 2>/dev/null`;
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
 my $cec_bin="/usr/sbin/pgenerator-cec";
 if(!-x $cec_bin) {
  return '{"status":"error","message":"CEC tool not found"}';
 }
 # Validate command
 if($cmd!~/^(status|power|on|off|as|wake)$/) {
  return '{"status":"error","message":"Invalid CEC command: '.$cmd.'"}';
 }
 my $output=`$cec_bin $cmd 2>&1`;
 my $rc=$?>>8;
 $output=~s/"/\\"/g;
 $output=~s/\n/\\n/g;
 if($rc == 0) {
  return "{\"status\":\"ok\",\"output\":\"$output\"}";
 } else {
  return "{\"status\":\"error\",\"output\":\"$output\"}";
 }
}

sub webui_pattern (@) {
 my $body=shift;
 my ($name)=$body=~/"name"\s*:\s*"([^"]+)"/;
 return '{"status":"error","message":"Missing pattern name"}' if(!$name);
 $name=~s/[^a-zA-Z0-9_ -]//g;
 my $w=$w_s || 1920; my $h=$h_s || 1080;
 my $pat=""; my $img="$var_dir/running/webui_pattern.ppm";
 # Complex patterns use ImageMagick to composite into a PPM image (DRAW=IMAGE),
 # because PGeneratord clears the entire frame for each DRAW=RECTANGLE entry.
 #
 # White Clipping — 9 near-white bars on 85% gray (AVS HD 709 style)
 # All bars should be individually visible when contrast is set correctly
 if($name eq "white_clipping") {
  my @levels=(230,234,238,242,246,250,253,254,255);
  my $cols=scalar @levels;
  my $bg_v=int(255*0.85);
  my $bar_w=int($w*0.8/$cols);
  my $gap=int($w*0.005);
  my $start_x=int($w*0.1);
  my $bar_top=int($h*0.15);
  my $bar_h=int($h*0.7);
  my $ref_v=int(255*0.5);
  my $cmd="convert -size ${w}x${h} -depth 8 xc:\'rgb($bg_v,$bg_v,$bg_v)\'";
  for(my $i=0;$i<$cols;$i++){
   my $v=$levels[$i];
   my $x=$start_x+$i*$bar_w+$gap;
   my $x2=$x+($bar_w-$gap*2)-1;
   my $y2=$bar_top+$bar_h-1;
   $cmd.=" -fill \'rgb($v,$v,$v)\' -draw \'rectangle $x,$bar_top $x2,$y2\'";
  }
  my $ref_y=$bar_top+$bar_h+int($h*0.02);
  my $ref_h=int($h*0.04);
  my $ref_x=int($w*0.2);
  $cmd.=" -fill \'rgb($ref_v,$ref_v,$ref_v)\' -draw \'rectangle $ref_x,$ref_y ".($ref_x+int($w*0.6)-1).",".($ref_y+$ref_h-1)."\'";
  system("$cmd $img");
  $pat="DRAW=IMAGE\nDIM=$w,$h\nRGB=0,0,0\nBG=0,0,0\nPOSITION=0,0\nIMAGE=$img\nEND=1\n";
 }
 # Black Clipping / PLUGE — below-black through +10% (ITU-R BT.814 style)
 # Below-black bar should be invisible; +2% bar barely visible
 elsif($name eq "black_clipping") {
  my $bg_v=int(255*0.05);
  my @levels=(0,0,int(255*0.02),int(255*0.04),int(255*0.06),int(255*0.08),int(255*0.10));
  my $cols=scalar @levels;
  my $bar_w=int($w*0.7/$cols);
  my $gap=int($w*0.005);
  my $start_x=int($w*0.15);
  my $bar_top=int($h*0.2);
  my $bar_h=int($h*0.6);
  my $cmd="convert -size ${w}x${h} -depth 8 xc:\'rgb($bg_v,$bg_v,$bg_v)\'";
  for(my $i=0;$i<$cols;$i++){
   my $v=$levels[$i];
   my $x=$start_x+$i*$bar_w+$gap;
   my $x2=$x+($bar_w-$gap*2)-1;
   my $y2=$bar_top+$bar_h-1;
   $cmd.=" -fill \'rgb($v,$v,$v)\' -draw \'rectangle $x,$bar_top $x2,$y2\'";
  }
  my $mk_y=$bar_top-int($h*0.04);
  my $mk_h=int($h*0.02);
  my $mk_x=$start_x+$gap;
  my $mk_x2=$mk_x+($bar_w-$gap*2)-1;
  my $mk_y2=$mk_y+$mk_h-1;
  $cmd.=" -fill \'rgb(51,0,0)\' -draw \'rectangle $mk_x,$mk_y $mk_x2,$mk_y2\'";
  $mk_x=$start_x+$bar_w+$gap;
  $mk_x2=$mk_x+($bar_w-$gap*2)-1;
  $cmd.=" -fill \'rgb(51,51,51)\' -draw \'rectangle $mk_x,$mk_y $mk_x2,$mk_y2\'";
  system("$cmd $img");
  $pat="DRAW=IMAGE\nDIM=$w,$h\nRGB=0,0,0\nBG=0,0,0\nPOSITION=0,0\nIMAGE=$img\nEND=1\n";
 }
 # Color Bars — 75% Rec.709 SMPTE-style with PLUGE bottom section
 elsif($name eq "color_bars") {
  my $l75=int(255*0.75);
  my @top_r=($l75,$l75,0,0,$l75,$l75,0);
  my @top_g=($l75,$l75,$l75,$l75,0,0,0);
  my @top_b=($l75,0,$l75,0,$l75,0,$l75);
  my @rev_r=(0,0,$l75,0,0,0,$l75);
  my @rev_g=(0,0,0,0,$l75,0,$l75);
  my @rev_b=($l75,0,$l75,0,$l75,0,$l75);
  my $cols=7;
  my $pw=int($w/$cols);
  my $split_y=int($h*0.75);
  my $mid_h=int($h*0.075);
  my $cmd="convert -size ${w}x${h} -depth 8 xc:black";
  for(my $i=0;$i<$cols;$i++){
   my $x1=$i*$pw;
   my $x2=($i==$cols-1) ? $w-1 : ($i+1)*$pw-1;
   $cmd.=" -fill \'rgb($top_r[$i],$top_g[$i],$top_b[$i])\' -draw \'rectangle $x1,0 $x2,".($split_y-1)."\'";
  }
  for(my $i=0;$i<$cols;$i++){
   my $x1=$i*$pw;
   my $x2=($i==$cols-1) ? $w-1 : ($i+1)*$pw-1;
   $cmd.=" -fill \'rgb($rev_r[$i],$rev_g[$i],$rev_b[$i])\' -draw \'rectangle $x1,$split_y $x2,".($split_y+$mid_h-1)."\'";
  }
  my $bot_y=$split_y+$mid_h;
  my $third_w=int($w/3);
  my $pluge_w=int($third_w/3);
  my $above_v=int(255*0.04);
  $cmd.=" -fill \'rgb(0,0,0)\' -draw \'rectangle 0,$bot_y ".($pluge_w-1).",".($h-1)."\'";
  $cmd.=" -fill \'rgb(0,0,0)\' -draw \'rectangle $pluge_w,$bot_y ".($pluge_w*2-1).",".($h-1)."\'";
  $cmd.=" -fill \'rgb($above_v,$above_v,$above_v)\' -draw \'rectangle ".($pluge_w*2).",$bot_y ".($pluge_w*3-1).",".($h-1)."\'";
  $cmd.=" -fill \'rgb(255,255,255)\' -draw \'rectangle $third_w,$bot_y ".($third_w*2-1).",".($h-1)."\'";
  system("$cmd $img");
  $pat="DRAW=IMAGE\nDIM=$w,$h\nRGB=0,0,0\nBG=0,0,0\nPOSITION=0,0\nIMAGE=$img\nEND=1\n";
 }
 # Gray Ramp — 32 fine steps from black to white (top) + 11 IRE steps (bottom)
 elsif($name eq "gray_ramp") {
  my $ramp_steps=32;
  my $ramp_pw=int($w/$ramp_steps);
  my $ramp_h=int($h*0.6);
  my $cmd="convert -size ${w}x${h} -depth 8 xc:black";
  for(my $i=0;$i<$ramp_steps;$i++){
   my $v=int($i*255/($ramp_steps-1));
   my $x1=$i*$ramp_pw;
   my $x2=($i==$ramp_steps-1) ? $w-1 : ($i+1)*$ramp_pw-1;
   $cmd.=" -fill \'rgb($v,$v,$v)\' -draw \'rectangle $x1,0 $x2,".($ramp_h-1)."\'";
  }
  my $step_steps=11;
  my $step_pw=int($w/$step_steps);
  my $step_top=int($h*0.65);
  for(my $i=0;$i<$step_steps;$i++){
   my $v=int($i*255/($step_steps-1));
   my $x1=$i*$step_pw;
   my $x2=($i==$step_steps-1) ? $w-1 : ($i+1)*$step_pw-1;
   $cmd.=" -fill \'rgb($v,$v,$v)\' -draw \'rectangle $x1,$step_top $x2,".($h-1)."\'";
  }
  system("$cmd $img");
  $pat="DRAW=IMAGE\nDIM=$w,$h\nRGB=0,0,0\nBG=0,0,0\nPOSITION=0,0\nIMAGE=$img\nEND=1\n";
 }
 # Full field solid colors
 elsif($name eq "white")   { $pat="DRAW=RECTANGLE\nDIM=$w,$h\nRGB=255,255,255\nBG=0,0,0\nPOSITION=0,0\nEND=1\n"; }
 elsif($name eq "black")   { $pat="DRAW=RECTANGLE\nDIM=$w,$h\nRGB=0,0,0\nBG=0,0,0\nPOSITION=0,0\nEND=1\n"; }
 elsif($name eq "red")     { $pat="DRAW=RECTANGLE\nDIM=$w,$h\nRGB=255,0,0\nBG=0,0,0\nPOSITION=0,0\nEND=1\n"; }
 elsif($name eq "green")   { $pat="DRAW=RECTANGLE\nDIM=$w,$h\nRGB=0,255,0\nBG=0,0,0\nPOSITION=0,0\nEND=1\n"; }
 elsif($name eq "blue")    { $pat="DRAW=RECTANGLE\nDIM=$w,$h\nRGB=0,0,255\nBG=0,0,0\nPOSITION=0,0\nEND=1\n"; }
 elsif($name eq "cyan")    { $pat="DRAW=RECTANGLE\nDIM=$w,$h\nRGB=0,255,255\nBG=0,0,0\nPOSITION=0,0\nEND=1\n"; }
 elsif($name eq "magenta") { $pat="DRAW=RECTANGLE\nDIM=$w,$h\nRGB=255,0,255\nBG=0,0,0\nPOSITION=0,0\nEND=1\n"; }
 elsif($name eq "yellow")  { $pat="DRAW=RECTANGLE\nDIM=$w,$h\nRGB=255,255,0\nBG=0,0,0\nPOSITION=0,0\nEND=1\n"; }
 # 50% Gray
 elsif($name eq "gray50")  { $pat="DRAW=RECTANGLE\nDIM=$w,$h\nRGB=128,128,128\nBG=0,0,0\nPOSITION=0,0\nEND=1\n"; }
 # Window pattern — centered white window on black (18% of screen area)
 elsif($name eq "window") {
  my $s=sqrt(0.18); my $ww=int($w*$s); my $wh=int($h*$s);
  my $wx=int(($w-$ww)/2); my $wy=int(($h-$wh)/2);
  $pat="DRAW=RECTANGLE\nDIM=$ww,$wh\nRGB=255,255,255\nBG=0,0,0\nPOSITION=$wx,$wy\nEND=1\n";
 }
 # Overscan — borders at 0%, 2.5%, 5% with corner brackets and crosshair
 elsif($name eq "overscan") {
  my $bw=2;
  my $g=76; my $g2=128;
  my $cmd="convert -size ${w}x${h} -depth 8 xc:black";
  # 0% border (screen edge) — white
  $cmd.=" -fill \'rgb(255,255,255)\' -draw \'rectangle 0,0 ".($w-1).",".($bw-1)."\'";
  $cmd.=" -fill \'rgb(255,255,255)\' -draw \'rectangle 0,".($h-$bw)." ".($w-1).",".($h-1)."\'";
  $cmd.=" -fill \'rgb(255,255,255)\' -draw \'rectangle 0,0 ".($bw-1).",".($h-1)."\'";
  $cmd.=" -fill \'rgb(255,255,255)\' -draw \'rectangle ".($w-$bw).",0 ".($w-1).",".($h-1)."\'";
  # 5% border — dark gray
  my $m5x=int($w*0.05); my $m5y=int($h*0.05);
  my $inner5w=$w-$m5x*2; my $inner5h=$h-$m5y*2;
  $cmd.=" -fill \'rgb($g,$g,$g)\' -draw \'rectangle $m5x,$m5y ".($m5x+$inner5w-1).",".($m5y+$bw-1)."\'";
  $cmd.=" -fill \'rgb($g,$g,$g)\' -draw \'rectangle $m5x,".($h-$m5y-$bw)." ".($m5x+$inner5w-1).",".($h-$m5y-1)."\'";
  $cmd.=" -fill \'rgb($g,$g,$g)\' -draw \'rectangle $m5x,$m5y ".($m5x+$bw-1).",".($m5y+$inner5h-1)."\'";
  $cmd.=" -fill \'rgb($g,$g,$g)\' -draw \'rectangle ".($w-$m5x-$bw).",$m5y ".($w-$m5x-1).",".($m5y+$inner5h-1)."\'";
  # 2.5% border — mid gray
  my $m25x=int($w*0.025); my $m25y=int($h*0.025);
  my $inner25w=$w-$m25x*2; my $inner25h=$h-$m25y*2;
  $cmd.=" -fill \'rgb($g2,$g2,$g2)\' -draw \'rectangle $m25x,$m25y ".($m25x+$inner25w-1).",".($m25y+$bw-1)."\'";
  $cmd.=" -fill \'rgb($g2,$g2,$g2)\' -draw \'rectangle $m25x,".($h-$m25y-$bw)." ".($m25x+$inner25w-1).",".($h-$m25y-1)."\'";
  $cmd.=" -fill \'rgb($g2,$g2,$g2)\' -draw \'rectangle $m25x,$m25y ".($m25x+$bw-1).",".($m25y+$inner25h-1)."\'";
  $cmd.=" -fill \'rgb($g2,$g2,$g2)\' -draw \'rectangle ".($w-$m25x-$bw).",$m25y ".($w-$m25x-1).",".($m25y+$inner25h-1)."\'";
  # Center crosshair — white
  my $cross_len=int($w*0.075); my $cross_t=2;
  my $cx=int($w/2); my $cy=int($h/2);
  $cmd.=" -fill \'rgb(255,255,255)\' -draw \'rectangle ".($cx-$cross_len).",".($cy-int($cross_t/2))." ".($cx+$cross_len-1).",".($cy+int($cross_t/2)-1)."\'";
  $cmd.=" -fill \'rgb(255,255,255)\' -draw \'rectangle ".($cx-int($cross_t/2)).",".($cy-$cross_len)." ".($cx+int($cross_t/2)-1).",".($cy+$cross_len-1)."\'";
  # Corner L-brackets at 5% mark — white
  my $cm=int($w*0.04); my $ct=3;
  $cmd.=" -fill \'rgb(255,255,255)\' -draw \'rectangle $m5x,$m5y ".($m5x+$cm-1).",".($m5y+$ct-1)."\'";
  $cmd.=" -fill \'rgb(255,255,255)\' -draw \'rectangle $m5x,$m5y ".($m5x+$ct-1).",".($m5y+$cm-1)."\'";
  $cmd.=" -fill \'rgb(255,255,255)\' -draw \'rectangle ".($w-$m5x-$cm).",$m5y ".($w-$m5x-1).",".($m5y+$ct-1)."\'";
  $cmd.=" -fill \'rgb(255,255,255)\' -draw \'rectangle ".($w-$m5x-$ct).",$m5y ".($w-$m5x-1).",".($m5y+$cm-1)."\'";
  $cmd.=" -fill \'rgb(255,255,255)\' -draw \'rectangle $m5x,".($h-$m5y-$ct)." ".($m5x+$cm-1).",".($h-$m5y-1)."\'";
  $cmd.=" -fill \'rgb(255,255,255)\' -draw \'rectangle $m5x,".($h-$m5y-$cm)." ".($m5x+$ct-1).",".($h-$m5y-1)."\'";
  $cmd.=" -fill \'rgb(255,255,255)\' -draw \'rectangle ".($w-$m5x-$cm).",".($h-$m5y-$ct)." ".($w-$m5x-1).",".($h-$m5y-1)."\'";
  $cmd.=" -fill \'rgb(255,255,255)\' -draw \'rectangle ".($w-$m5x-$ct).",".($h-$m5y-$cm)." ".($w-$m5x-1).",".($h-$m5y-1)."\'";
  system("$cmd $img");
  $pat="DRAW=IMAGE\nDIM=$w,$h\nRGB=0,0,0\nBG=0,0,0\nPOSITION=0,0\nIMAGE=$img\nEND=1\n";
 }
 # Generic patch — takes r,g,b,size params from JSON body
 elsif($name eq "patch") {
  my ($pr)=$body=~/"r"\s*:\s*(\d+)/; $pr=0 if(!defined $pr);
  my ($pg)=$body=~/"g"\s*:\s*(\d+)/; $pg=0 if(!defined $pg);
  my ($pb)=$body=~/"b"\s*:\s*(\d+)/; $pb=0 if(!defined $pb);
  my ($sz)=$body=~/"size"\s*:\s*(\d+)/; $sz=100 if(!defined $sz);
  $pr=255 if($pr>255); $pg=255 if($pg>255); $pb=255 if($pb>255);
  if($sz>=100) {
   $pat="DRAW=RECTANGLE\nDIM=$w,$h\nRGB=$pr,$pg,$pb\nBG=0,0,0\nPOSITION=0,0\nEND=1\n";
  } else {
   my $s=sqrt($sz/100); my $pw=int($w*$s); my $ph=int($h*$s);
   my $px=int(($w-$pw)/2); my $py=int(($h-$ph)/2);
   $pat="DRAW=RECTANGLE\nDIM=$pw,$ph\nRGB=$pr,$pg,$pb\nBG=0,0,0\nPOSITION=$px,$py\nEND=1\n";
  }
 }
 # Stop — full black (idle)
 elsif($name eq "stop") { $pat="DRAW=RECTANGLE\nDIM=$w,$h\nRGB=0,0,0\nBG=0,0,0\nPOSITION=0,0\nEND=1\n"; }
 else {
  return '{"status":"error","message":"Unknown pattern: '.$name.'"}';
 }
 # Write the pattern
 $pat="PATTERN_NAME=$name\nBITS=$bits_default\n".$pat."FRAME=$frame_default\n";
 open(my $fh,">","$command_file.tmp");
 print $fh $pat;
 close($fh);
 rename("$command_file.tmp","$command_file");
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
padding:0 20px;border-bottom:1px solid var(--border);display:flex;
align-items:center;justify-content:space-between;flex-wrap:wrap;gap:8px}
.logo{display:flex;align-items:center;gap:10px}
.logo img{height:96px;width:auto}
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
.info-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(120px,1fr));gap:6px}
.info-item{background:#0d0d15;padding:8px;border-radius:6px}
.info-item .label{font-size:.6rem;color:var(--text2);text-transform:uppercase}
.info-item .value{font-size:.85rem;margin-top:1px;word-break:break-all}
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
[data-widget].drag-over{outline:2px dashed var(--accent);outline-offset:-2px}
[data-widget].dragging{opacity:.4}
@media(max-width:800px){.dashboard{grid-template-columns:1fr}
.card.span2{grid-column:span 1}.grid3{grid-template-columns:1fr 1fr}}
@media(max-width:480px){.grid{grid-template-columns:1fr}
.hdr-actions{flex-wrap:wrap}.header{padding:10px 12px}.dashboard{padding:8px}}
</style>
</head>
<body>

<div class="header">
 <div class="logo">
   <img src="data:image/png;base64,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5yU/kxwkz6IME+2PntRQOlh/iL3vgGEvYbYwSFTn/m4x/skstur996Mw+f1yeTrDeLyS9eapWXrTFYA06DyJWOzo/4LuuOYuL4S53DgAYX9/fzRfr+9tF6uPgTRS769btAeGdBsGV8Yl70NkT4C9ZNiT4cBHaGlobPfLYDgX0gZFp0scT11jMpiLcm7VsBRH60qalMB2s7paOAhKKI1kKl1pHtiJZBElAKhLheg6JRse8E/o0+Lr5DQMNoCc+4ViamYvYGljZluILrwLR6r257ZtD+GwDRpmevXql8vZ7BhAFJH1Jc/TKr/j58ZlSGKxI3pNEcQlHeEbL3XdvXt3PJ1Or2232/fX6/WN7v/13jeqH6Qkt2JsPzTDPhADAAcRL0AA9KYAPzHIe2ZpVI5Y+FIttLRCXaBd6fLKmmt/eO9cHazP/Gy4q6Z7z3IGvoatWt+95WGaUcQEJhGCMwG+M7MjmJ3Vtg9mLSD5eyS68KH5ShG/3aT0Em27BhBDCPHatWv/ePjw4bNHjx7F1xSwi/cGt6NDG3z+RCx2RG/jGpULhfHiTTf92I8gENy+fXtycHA6Al66Cx9ruJFCx+OxMzNnZh6ANwsOuQMV780DwBYAEBCwRdvqKn9uG5eL2CgBmygircg6rlaIOD+U2AYtY9rf39/MZrMTVbV/o1hd9r2UHX/GJQWNiMWO6B2+nuUV1/aut1++sebd4l7zmrVXvI3dGPHmQERv/Fp4W68Z+w+9DxERERERERERERERERERERERERERERERERERERERERERERERERERERERERERERERERERERERERERERERERERERERERERERERERERERERERERERERERERERERERERERERERERERHR2/UvPjSkdrHS6OsAAAAASUVORK5CYII=" alt="PGenerator+ logo" style="display:block;">
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
    <label>Quantization</label>
    <select id="rgb_quant_range">
     <option value="0">Default</option>
     <option value="1">Limited (16-235)</option>
     <option value="2">Full (0-255)</option>
    </select>
   </div>
   <div class="field">
    <label>Colorimetry</label>
    <select id="colorimetry">
     <option value="2">BT.709</option>
     <option value="9">BT.2020</option>
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
  <div class="grid">
   <div class="field">
    <label>DV Mode</label>
    <select id="dv_type">
     <option value="ll">Low-Latency (LLDV)</option>
     <option value="std">Standard</option>
    </select>
   </div>
   <div class="field">
    <label>Metadata Mode</label>
    <select id="dv_metadata">
     <option value="0">None</option>
     <option value="1">RGB Tunneling</option>
     <option value="2">Perceptual</option>
     <option value="3">Absolute</option>
     <option value="4">Relative</option>
    </select>
   </div>
   <div class="field">
    <label>Interface</label>
    <select id="dv_interface">
     <option value="0">Standard</option>
     <option value="1">Low-Latency</option>
    </select>
   </div>
   <div class="field">
    <label>Color Space</label>
    <select id="dv_color_space">
     <option value="0">YCbCr</option>
     <option value="1">RGB</option>
     <option value="2">IPT</option>
    </select>
   </div>
  </div>
 </div>

 <!-- Apply Settings Bar -->
 <div class="card span2" id="applyBar" style="display:none">
  <div style="display:flex;align-items:center;justify-content:space-between">
   <span style="color:var(--text2);font-size:.85rem">Settings changed</span>
   <button class="btn btn-sm btn-primary" onclick="applySettings()">Apply &amp; Restart</button>
  </div>
 </div>

 <!-- Test Patterns -->
 <div class="card span2" data-widget="patterns" draggable="true">
  <h2><span class="drag-handle">&#9776;</span>Test Patterns</h2>
  <div class="pat-section">
   <div class="pat-section-title" onclick="toggleSection(this)">Diagnostic</div>
   <div class="pat-content">
    <div style="font-size:.65rem;color:var(--text2);margin-bottom:6px;line-height:1.4">Visual setup patterns for display calibration. Use these to verify your display&#39;s basic picture settings before running a full calibration.</div>
    <div class="pat-grid">
     <button class="pat-btn" onclick="showPattern('white_clipping')">White Clipping</button>
     <button class="pat-btn" onclick="showPattern('black_clipping')">Black Clipping</button>
     <button class="pat-btn" onclick="showPattern('color_bars')">Color Bars</button>
     <button class="pat-btn" onclick="showPattern('gray_ramp')">Gray Ramp</button>
     <button class="pat-btn" onclick="showPattern('overscan')">Overscan</button>
    </div>
    <div id="diagInfo" style="font-size:.7rem;color:var(--text2);margin-top:8px;padding:8px 10px;background:#0d0d15;border-radius:6px;line-height:1.5;display:none"></div>
   </div>
  </div>
  <div class="patch-size-bar">
   <div class="field" style="flex:0 0 auto">
    <label>Patch Size</label>
    <select id="patchSize">
     <option value="10">10% Window</option>
     <option value="18" selected>18% Window</option>
     <option value="50">50% Window</option>
     <option value="100">Full Field</option>
    </select>
   </div>
  </div>
  <div class="pat-section collapsed">
   <div class="pat-section-title" onclick="toggleSection(this)">Grayscale (10-Point)</div>
   <div class="pat-content">
    <div class="pat-grid-sm" id="gs10grid"></div>
   </div>
  </div>
  <div class="pat-section collapsed">
   <div class="pat-section-title" onclick="toggleSection(this)">Grayscale (20-Point)</div>
   <div class="pat-content">
    <div class="pat-grid-sm" id="gs20grid"></div>
   </div>
  </div>
  <div class="pat-section collapsed">
   <div class="pat-section-title" onclick="toggleSection(this)">Color Checker</div>
   <div class="pat-content">
    <div style="font-size:.6rem;color:var(--text2);margin-bottom:4px">75% Stimulus</div>
    <div class="pat-grid" id="cc75grid"></div>
    <div style="font-size:.6rem;color:var(--text2);margin:6px 0 4px">100% Stimulus</div>
    <div class="pat-grid" id="cc100grid"></div>
   </div>
  </div>
  <div class="pat-section collapsed">
   <div class="pat-section-title" onclick="toggleSection(this)">Saturation Sweeps</div>
   <div class="pat-content" id="satGrid"></div>
  </div>

 </div>

 <!-- Device Info -->
 <div class="card" data-widget="info" draggable="true">
  <h2><span class="drag-handle">&#9776;</span>Device Info</h2>
  <div class="info-grid" id="infoGrid"></div>
 </div>

 <!-- WiFi Client -->
 <div class="card" data-widget="wifi" draggable="true">
  <h2><span class="drag-handle">&#9776;</span>WiFi Client</h2>
  <div class="btn-row" style="margin-bottom:8px">
   <button class="btn btn-sm btn-secondary" onclick="scanWifi()">Scan Networks</button>
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
  <div class="btn-row">
   <button class="btn btn-sm btn-success" onclick="cecCmd('wake')">Wake TV</button>
   <button class="btn btn-sm btn-secondary" onclick="cecCmd('on')">On</button>
   <button class="btn btn-sm btn-secondary" onclick="cecCmd('as')">Input</button>
   <button class="btn btn-sm btn-danger" onclick="cecCmd('off')">Standby</button>
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
 <div class="card span2" data-widget="infoframes" draggable="true">
  <h2><span class="drag-handle">&#9776;</span>HDMI Infoframes</h2>
  <div class="btn-row" style="margin-bottom:8px">
   <button class="btn btn-sm btn-secondary" onclick="loadInfoframes()">Refresh</button>
  </div>
  <div style="display:grid;grid-template-columns:1fr 1fr;gap:8px">
   <div>
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

async function fetchJSON(url,opts){
 try{const r=await fetch(API+url,opts);return await r.json();}
 catch(e){toast('Connection error','err');return null;}
}

async function loadConfig(){
 config=await fetchJSON('/api/config');
 if(!config)return;
 // Derive signal mode from flags
 let sm='sdr';
 if(config.dv_status==='1'||config.is_ll_dovi==='1'||config.is_std_dovi==='1') sm='dv';
 else if(config.is_hdr==='1'){
  sm=(config.eotf==='3')?'hlg':'hdr10';
 }
 setVal('signal_mode',sm);
 setVal('max_bpc',config.max_bpc||'8');
 setVal('color_format',config.color_format||'0');
 setVal('rgb_quant_range',config.rgb_quant_range||'0');
 setVal('colorimetry',config.colorimetry||'0');
 setVal('eotf',config.eotf||'0');
 setVal('primaries',config.primaries||'0');
 document.getElementById('max_luma').value=config.max_luma||'1000';
 document.getElementById('min_luma').value=config.min_luma||'0.005';
 document.getElementById('max_cll').value=config.max_cll||'1000';
 document.getElementById('max_fall').value=config.max_fall||'400';
 // DV settings
 setVal('dv_type',(config.is_std_dovi==='1')?'std':'ll');
 setVal('dv_metadata',config.dv_metadata||'0');
 setVal('dv_interface',config.dv_interface||'0');
 setVal('dv_color_space',config.dv_color_space||'0');
 updateModeVisibility();
 window._savedConfig=captureSettings();
}

function setVal(id,v){const el=document.getElementById(id);if(el)el.value=v;}
function getVal(id){const el=document.getElementById(id);return el?el.value:'';}

function captureSettings(){
 return JSON.stringify({
  mode_idx:getVal('mode_idx'),signal_mode:getVal('signal_mode'),
  max_bpc:getVal('max_bpc'),color_format:getVal('color_format'),
  rgb_quant_range:getVal('rgb_quant_range'),colorimetry:getVal('colorimetry'),
  eotf:getVal('eotf'),primaries:getVal('primaries'),
  max_luma:document.getElementById('max_luma').value,
  min_luma:document.getElementById('min_luma').value,
  max_cll:document.getElementById('max_cll').value,
  max_fall:document.getElementById('max_fall').value,
  dv_type:getVal('dv_type'),dv_metadata:getVal('dv_metadata'),
  dv_interface:getVal('dv_interface'),dv_color_space:getVal('dv_color_space')
 });
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

['mode_idx','signal_mode','max_bpc','color_format','rgb_quant_range','colorimetry',
 'eotf','primaries','dv_type','dv_metadata','dv_interface','dv_color_space'].forEach(function(id){
 document.getElementById(id).addEventListener('change',checkSettingsChanged);
});
['max_luma','min_luma','max_cll','max_fall'].forEach(function(id){
 document.getElementById(id).addEventListener('input',checkSettingsChanged);
});
document.getElementById('signal_mode').addEventListener('change',function(){
 updateModeVisibility();
 checkSettingsChanged();
 const sm=this.value;
 if(sm==='sdr'){setVal('eotf','0');setVal('colorimetry','2');setVal('max_bpc','8');}
 else if(sm==='hdr10'){setVal('eotf','2');setVal('colorimetry','9');setVal('primaries','1');setVal('max_bpc','10');}
 else if(sm==='hlg'){setVal('eotf','3');setVal('colorimetry','9');setVal('primaries','1');setVal('max_bpc','10');}
 else if(sm==='dv'){setVal('colorimetry','9');setVal('max_bpc','12');}
});

async function loadModes(){
 modes=await fetchJSON('/api/modes');
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

async function checkPing(){
 const t0=performance.now();
 try{
  const r=await fetch(API+'/api/ping',{signal:AbortSignal.timeout(5000)});
  if(!r.ok) throw new Error(r.status);
  await r.json();
 }catch(e){
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

async function loadInfo(){
 const info=await fetchJSON('/api/info');
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
 if(info.interfaces){
  Object.entries(info.interfaces).forEach(([iface,ip])=>{
   const name=IFACE_NAMES[iface]||iface;
   addInfo(g,name,ip);
  });
 }
 if(info.wifi && info.wifi.state==='COMPLETED' && info.wifi.ssid){
  addInfo(g,'WiFi Network',info.wifi.ssid);
  if(info.wifi.band) addInfo(g,'WiFi Band',info.wifi.band+' ('+info.wifi.freq+' MHz)');
  if(info.wifi.signal) addInfo(g,'WiFi Signal',info.wifi.signal+' dBm');
 }
 if(info.calibration && info.calibration.connected){
  addInfo(g,'Calibration SW',info.calibration.software+' ('+info.calibration.ip+')');
 }
 // Auto-refresh config when calibration software is connected
 if(info.calibration && info.calibration.connected && !window._calmanPoll){
  window._calmanPoll=setInterval(loadConfig,10000);
 } else if((!info.calibration || !info.calibration.connected) && window._calmanPoll){
  clearInterval(window._calmanPoll); window._calmanPoll=null;
 }
}

function addInfo(g,label,value){
 const d=document.createElement('div');d.className='info-item';
 d.innerHTML='<div class="label">'+label+'</div><div class="value">'+value+'</div>';
 g.appendChild(d);
}
function formatUptime(s){
 s=parseFloat(s);if(isNaN(s))return'?';
 const d=Math.floor(s/86400),h=Math.floor((s%86400)/3600),m=Math.floor((s%3600)/60);
 return(d?d+'d ':'')+(h?h+'h ':'')+(m?m+'m':'<1m');
}

const DIAG_DESCRIPTIONS={
 white_clipping:'<b>White Clipping (Contrast)</b> &mdash; 9 vertical bars from 90% to 100% white on an 85% gray background. Reduce your TV\u2019s Contrast/White Level until all 9 bars are individually visible.',
 black_clipping:'<b>Black Clipping / PLUGE (Brightness)</b> &mdash; 7 bars from below-black through +10% on a 5% gray background. Raise Brightness until the leftmost below-black bar just disappears while the +2% bar remains barely visible.',
 color_bars:'<b>Color Bars</b> &mdash; SMPTE-style 75% Rec.709 color bars. Top section has 7 primary/secondary bars. Bottom has a reverse-order reference strip, PLUGE blacks, and 100% white.',
 gray_ramp:'<b>Gray Ramp</b> &mdash; Top: 32-step fine gradient from black to white. Bottom: 11 stepped bars at 0% to 100% in 10% increments. Check for smooth transitions and no banding.',
 overscan:'<b>Overscan</b> &mdash; Border lines at 0%, 2.5%, and 5% from screen edges with corner L-brackets and center crosshair. All lines should be visible &mdash; if not, disable overscan in your TV settings.',
};
let activePattern=null;
function clearActive(){document.querySelectorAll('.pat-btn').forEach(b=>b.classList.remove('active'));activePattern=null;}
function updateDiagInfo(name){
 const el=document.getElementById('diagInfo');
 if(el&&DIAG_DESCRIPTIONS[name]){el.innerHTML=DIAG_DESCRIPTIONS[name];el.style.display='';}
 else if(el){el.style.display='none';}
}
async function showPattern(name){
 if(activePattern===name){stopPattern();return;}
 clearActive();
 event.currentTarget.classList.add('active');
 activePattern=name;
 updateDiagInfo(name);
 const r=await fetchJSON('/api/pattern',{method:'POST',headers:{'Content-Type':'application/json'},
  body:JSON.stringify({name:name})});
 if(r&&r.status==='ok') toast('Pattern: '+name.replace(/_/g,' '));
 else toast(r?r.message:'Pattern error',true);
}
async function showPatch(id,pr,pg,pb,ev){
 if(activePattern===id){stopPattern();return;}
 clearActive();
 var sz=parseInt(document.getElementById('patchSize').value);
 if(ev&&ev.currentTarget)ev.currentTarget.classList.add('active');
 activePattern=id;
 const r=await fetchJSON('/api/pattern',{method:'POST',headers:{'Content-Type':'application/json'},
  body:JSON.stringify({name:'patch',r:pr,g:pg,b:pb,size:sz})});
 if(r&&r.status==='ok') toast(id.replace(/_/g,' '));
 else toast(r?r.message:'Pattern error',true);
}
async function stopPattern(){
 clearActive();
 var di=document.getElementById('diagInfo');if(di)di.style.display='none';
 const r=await fetchJSON('/api/pattern',{method:'POST',headers:{'Content-Type':'application/json'},
  body:JSON.stringify({name:'stop'})});
 if(r&&r.status==='ok') toast('Pattern stopped');
}
function toggleSection(el){el.parentElement.classList.toggle('collapsed');}
function buildCalPatterns(){
 var gs10=document.getElementById('gs10grid');
 var gs20=document.getElementById('gs20grid');
 [0,10,20,30,40,50,60,70,80,90,100].forEach(function(l){
  var v=Math.round(l*255/100);
  var b=document.createElement('button');
  b.className='pat-btn pat-btn-sm';
  b.textContent=l+'%';
  b.onclick=function(ev){showPatch('gs_'+l,v,v,v,ev);};
  gs10.appendChild(b);
 });
 for(var l=0;l<=100;l+=5){
  var v=Math.round(l*255/100);
  var b=document.createElement('button');
  b.className='pat-btn pat-btn-sm';
  b.textContent=l+'%';
  b.onclick=(function(ll,vv){return function(ev){showPatch('gs_'+ll,vv,vv,vv,ev);};})(l,v);
  gs20.appendChild(b);
 }
 var colors=[{n:'red',c:'#f44',ch:[1,0,0]},{n:'green',c:'var(--green)',ch:[0,1,0]},{n:'blue',c:'#5b7fff',ch:[0,0,1]},
  {n:'cyan',c:'#0ff',ch:[0,1,1]},{n:'magenta',c:'#f0f',ch:[1,0,1]},{n:'yellow',c:'#ff0',ch:[1,1,0]}];
 var cc75=document.getElementById('cc75grid');
 var cc100=document.getElementById('cc100grid');
 var ccAll=colors.concat([{n:'white',c:'#fff',ch:[1,1,1]},{n:'50% gray',c:'var(--text2)',ch:[0.5,0.5,0.5]},{n:'black',c:'var(--text)',ch:[0,0,0]}]);
 ccAll.forEach(function(co){
  [75,100].forEach(function(lv){
   var v=Math.round(lv*255/100);
   var r=Math.round(co.ch[0]*v),g=Math.round(co.ch[1]*v),b2=Math.round(co.ch[2]*v);
   var btn=document.createElement('button');
   btn.className='pat-btn';
   var label=co.n.charAt(0).toUpperCase()+co.n.slice(1);
   btn.innerHTML='<span style="color:'+co.c+'">'+label+'</span>';
   btn.onclick=function(ev){showPatch('cc_'+co.n.replace(/\s+/g,'')+'_'+lv,r,g,b2,ev);};
   (lv===75?cc75:cc100).appendChild(btn);
  });
 });
 var satDiv=document.getElementById('satGrid');
 colors.forEach(function(co){
  var row=document.createElement('div');row.className='sat-row';
  var lbl=document.createElement('span');lbl.className='sat-label';lbl.style.color=co.c;
  lbl.textContent=co.n.charAt(0).toUpperCase()+co.n.slice(1);
  row.appendChild(lbl);
  var btns=document.createElement('div');btns.className='sat-btns';
  [25,50,75,100].forEach(function(s){
   var off=Math.round(255*(1-s/100));
   var r=co.ch[0]?255:off,g=co.ch[1]?255:off,b2=co.ch[2]?255:off;
   var btn=document.createElement('button');
   btn.className='pat-btn pat-btn-sm';
   btn.textContent=s+'%';
   btn.onclick=function(ev){showPatch('sat_'+co.n+'_'+s,r,g,b2,ev);};
   btns.appendChild(btn);
  });
  row.appendChild(btns);
  satDiv.appendChild(row);
 });
}
buildCalPatterns();

function resetDefaults(){
 setVal('signal_mode','sdr');
 setVal('max_bpc','8');
 setVal('color_format','0');
 setVal('rgb_quant_range','0');
 setVal('colorimetry','2');
 setVal('eotf','0');
 setVal('primaries','0');
 document.getElementById('max_luma').value='1000';
 document.getElementById('min_luma').value='0.005';
 document.getElementById('max_cll').value='1000';
 document.getElementById('max_fall').value='400';
 setVal('dv_type','ll');
 setVal('dv_metadata','0');
 setVal('dv_interface','0');
 setVal('dv_color_space','0');
 updateModeVisibility();
 checkSettingsChanged();
 toast('Defaults loaded \u2014 click Apply to save and restart');
}

async function applySettings(){
 const sm=getVal('signal_mode');
 const changes={
  mode_idx:getVal('mode_idx'),
  max_bpc:getVal('max_bpc'),
  color_format:getVal('color_format'),
  rgb_quant_range:getVal('rgb_quant_range'),
  colorimetry:getVal('colorimetry'),
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
  const isStd=getVal('dv_type')==='std';
  Object.assign(changes,{is_sdr:'0',is_hdr:'0',
   is_ll_dovi:isStd?'0':'1',is_std_dovi:isStd?'1':'0',
   dv_status:'1',dv_metadata:getVal('dv_metadata'),
   dv_interface:getVal('dv_interface'),dv_color_space:getVal('dv_color_space')});
 }
 const r=await fetchJSON('/api/config',{method:'POST',
  headers:{'Content-Type':'application/json'},body:JSON.stringify(changes)});
 if(r&&r.status==='ok'){
  toast('Applying settings...');
  document.getElementById('applyBar').style.display='none';
  await fetchJSON('/api/restart',{method:'POST'});
  setTimeout(()=>{loadConfig();loadInfo();toast('Settings applied');},3000);
 }else toast('Failed to apply','err');
}

async function rebootDevice(){
 toast('Rebooting device...');
 await fetchJSON('/api/reboot',{method:'POST'});
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

async function cecCmd(cmd){
 const r=await fetchJSON('/api/cec/'+cmd);
 if(r){
  if(r.status==='ok') toast('CEC: '+cmd+' OK');
  else toast('CEC error','err');
  setTimeout(loadCecStatus,cmd==='wake'?2000:500);
 }
}

async function loadCecStatus(){
 const r=await fetchJSON('/api/cec/status');
 const el=document.getElementById('cecStatus');
 if(r&&r.status==='ok'){
  const raw=(r.output||'');
  const lines=raw.split('\n');
  const pwrColors={on:'#4caf50',standby:'var(--orange)','standby-to-on':'var(--orange)','on-to-standby':'var(--orange)',unknown:'var(--text2)'};
  const pwrLabels={on:'On',standby:'Standby','standby-to-on':'Waking Up','on-to-standby':'Going to Standby',unknown:'Unknown'};
  let pwr='unknown';let tvName='';
  lines.forEach(l=>{
   let m=l.match(/^tv_power:\s*(.+)/);if(m)pwr=m[1].trim();
   m=l.match(/^tv_name:\s*(.+)/);if(m)tvName=m[1].trim();
  });
  const c=pwrColors[pwr]||'var(--text2)';
  const lbl=pwrLabels[pwr]||pwr;
  let html='TV Power: <span style="color:'+c+';font-weight:600">'+lbl+'</span>';
  if(tvName) html+=' &mdash; '+tvName;
  el.innerHTML=html;
  if(pwr==='unknown'&&raw){el.title=raw;}
 }else{
  const msg=(r&&r.message)?r.message:'Not available';
  el.innerHTML='CEC: '+msg;
  el.style.color='var(--text2)';
  if(r&&r.output)el.title=r.output;
 }
}

async function loadAP(){
 const r=await fetchJSON('/api/wifi/ap');
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

async function loadInfoframes(){
 const r=await fetchJSON('/api/infoframes');
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
 document.getElementById('updateStatus').textContent='Checking...';
 const r=await fetchJSON('/api/update/check');
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
function showUpdateCard(){
 document.getElementById('updateCard').style.display='';
 document.getElementById('updateCard').scrollIntoView({behavior:'smooth'});
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

// Init
(async()=>{
 await loadConfig();
 await loadModes();
 await checkPing();
 await loadInfo();
 loadCecStatus();
 loadAP();
 loadInfoframes();
 checkUpdate();
 setInterval(checkPing,10000);
 setInterval(loadInfo,30000);
})();
</script>
</body>
</html>
WEBUI_HTML
}

return 1;
