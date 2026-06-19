#
# LG webOS TV helpers
#

use JSON::PP ();
use File::Path qw(make_path remove_tree);
use IO::Select ();
use IO::Socket::INET ();
use MIME::Base64 ();
use Socket qw(inet_aton sockaddr_in);

my $_LG_CEC_LG_DEVICE_CACHE={};
my $_LG_CEC_LG_DEVICE_CACHE_TIME=0;

###############################################
#                 LG Paths                     #
###############################################
sub lg_data_dir (@) {
 return "$var_dir/lg";
}

sub lg_clients_file (@) {
 return &lg_data_dir()."/clients.json";
}

sub lg_pin_sessions_dir (@) {
 return &lg_data_dir()."/pin-sessions";
}

sub lg_pin_session_dir (@) {
 my $token=shift;
 $token="" if(!defined($token));
 return &lg_pin_sessions_dir()."/$token";
}

sub lg_pin_state_file (@) {
 my $token=shift;
 return &lg_pin_session_dir($token)."/state.json";
}

sub lg_pin_input_file (@) {
 my $token=shift;
 return &lg_pin_session_dir($token)."/pin.txt";
}

sub lg_pin_log_file (@) {
 my $token=shift;
 return &lg_pin_session_dir($token)."/helper.log";
}

sub lg_helper_path (@) {
 return "/usr/sbin/pgenerator-lg";
}

sub lg_shell_quote (@) {
 my $text=shift;
 $text="" if(!defined($text));
 $text =~ s/'/'"'"'/g;
 return "'$text'";
}

###############################################
#              LG JSON Helpers                #
###############################################
sub lg_json_true (@) {
 return JSON::PP::true;
}

sub lg_json_false (@) {
 return JSON::PP::false;
}

sub lg_json_bool (@) {
 my $value=shift;
 return $value ? &lg_json_true() : &lg_json_false();
}

sub lg_decode_json (@) {
 my $raw=shift;
 return {} if(!defined($raw) || $raw eq "");
 my $data={};
 eval { $data=JSON::PP::decode_json($raw); 1; } or return {};
 return (ref($data) eq "HASH") ? $data : {};
}

sub lg_encode_json (@) {
 my $data=shift;
 return JSON::PP::encode_json($data);
}

###############################################
#             LG Persistence                  #
###############################################
sub lg_ensure_data_dir (@) {
 my $dir=&lg_data_dir();
 return 1 if(-d $dir);
 eval { make_path($dir); 1; };
 return (-d $dir) ? 1 : 0;
}

sub lg_load_clients (@) {
 my $file=&lg_clients_file();
 return {} if(!-f $file);
 return &lg_decode_json(&read_from_file($file));
}

sub lg_save_clients (@) {
 my $clients=shift;
 $clients={} if(ref($clients) ne "HASH");
 return 0 if(!&lg_ensure_data_dir());
 my $file=&lg_clients_file();
 &write_file("$file.tmp",$file,&lg_encode_json($clients),1);
 return 1;
}

sub lg_generate_token (@) {
 return sprintf("%x%x%x",time(),$$,int(rand(0x7fffffff)));
}

sub lg_load_pin_state (@) {
 my $token=shift;
 return {} if(!defined($token) || $token eq "");
 my $file=&lg_pin_state_file($token);
 return {} if(!-f $file);
 return &lg_decode_json(&read_from_file($file));
}

sub lg_clear_pin_session_files (@) {
 my $token=shift;
 return 1 if(!defined($token) || $token eq "");
 my $dir=&lg_pin_session_dir($token);
 return 1 if(!-d $dir);
 eval { remove_tree($dir); 1; };
 return (!-d $dir) ? 1 : 0;
}

sub lg_save_pin_session_meta (@) {
 my ($clients,$meta)=@_;
 $clients=&lg_load_clients() if(ref($clients) ne "HASH");
 if(ref($meta) eq "HASH") {
  $clients->{"pin_pairing"}=$meta;
 } else {
  delete($clients->{"pin_pairing"});
 }
 return &lg_save_clients($clients);
}

sub lg_reconcile_pin_pairing (@) {
 my $clients=shift;
 $clients=&lg_load_clients() if(ref($clients) ne "HASH");
 my $meta=$clients->{"pin_pairing"};
 return ($clients,{}) if(ref($meta) ne "HASH");
 my $token=$meta->{"token"}||"";
 return ($clients,{}) if($token eq "");
 my $state=&lg_load_pin_state($token);
 if(ref($state) eq "HASH" && ($state->{"status"}||"") eq "pending") {
  $state->{"token"}=$token if(($state->{"token"}||"") eq "");
  return ($clients,$state);
 }
 my $manual_ip=$clients->{"manual_ip"}||"";
 if(ref($state) eq "HASH" && ($state->{"status"}||"") eq "ok") {
  my $updated=&lg_update_connect_metadata($state,$manual_ip);
  delete($updated->{"pin_pairing"});
  &lg_save_clients($updated);
  &lg_clear_pin_session_files($token);
  return ($updated,{});
 }
 my $failure="";
 if(ref($state) eq "HASH" && ($state->{"status"}||"") eq "error") {
  $failure=$state->{"message"}||"LG PIN pairing failed.";
 } elsif(time() - int($meta->{"started_at"}||0) > 240) {
  $failure="LG PIN pairing timed out. Start PIN Pairing again.";
 }
 if($failure ne "") {
  delete($clients->{"pin_pairing"});
  $clients->{"last_error"}=$failure;
  &lg_save_clients($clients);
  &lg_clear_pin_session_files($token);
 }
 return ($clients,{});
}

sub lg_clear_pairing (@) {
 my $clients=&lg_load_clients();
 my $manual_ip=$clients->{"manual_ip"}||"";
 my $pin_pairing=$clients->{"pin_pairing"};
 if(ref($pin_pairing) eq "HASH" && ($pin_pairing->{"token"}||"") ne "") {
  &lg_clear_pin_session_files($pin_pairing->{"token"});
 }
 my $file=&lg_clients_file();
 if($manual_ip eq "") {
  unlink($file) if(-f $file);
  return 1;
 }
 return &lg_save_clients({ manual_ip => $manual_ip });
}

###############################################
#              LG Data Helpers                #
###############################################
sub lg_valid_ipv4 (@) {
 my $ip=shift;
 return 0 if(!defined($ip) || $ip eq "");
 return 0 if($ip !~ /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/);
 foreach my $octet ($1,$2,$3,$4) {
  return 0 if($octet < 0 || $octet > 255);
 }
 return 1;
}

sub lg_normalize_pairing_mode (@) {
 my $mode=uc(shift||"PIN");
 return $mode if($mode =~ /^(PIN|COMBINED|LGSWITCH-PIN)$/);
 return "PIN";
}

sub lg_primary_client (@) {
 my $clients=shift;
 $clients=&lg_load_clients() if(ref($clients) ne "HASH");
 if((($clients->{"client_key"}||"") ne "") || (($clients->{"ip"}||"") ne "") || (($clients->{"model_name"}||"") ne "") || (($clients->{"name"}||"") ne "")) {
  return $clients;
 }
 foreach my $key ("devices","clients") {
  next if(ref($clients->{$key}) ne "ARRAY");
  foreach my $entry (@{$clients->{$key}}) {
   next if(ref($entry) ne "HASH");
   my $client_key=$entry->{"client_key"}||$entry->{"client-key"}||"";
   my $ip=$entry->{"ip"}||"";
   next if($client_key eq "" && $ip eq "");
   return $entry;
  }
 }
 return {};
}

sub lg_client_key_present (@) {
 my $clients=shift;
 my $client=&lg_primary_client($clients);
 my $client_key=$client->{"client_key"}||$client->{"client-key"}||"";
 return $client_key ne "" ? 1 : 0;
}

sub lg_clients_disconnected (@) {
 my $clients=shift;
 $clients=&lg_load_clients() if(ref($clients) ne "HASH");
 return ($clients->{"disconnected"} && &lg_client_key_present($clients)) ? 1 : 0;
}

sub lg_mark_disconnected (@) {
 my $clients=&lg_load_clients();
 my $pin_pairing=$clients->{"pin_pairing"};
 if(ref($pin_pairing) eq "HASH" && ($pin_pairing->{"token"}||"") ne "") {
  &lg_clear_pin_session_files($pin_pairing->{"token"});
 }
 delete($clients->{"pin_pairing"});
 $clients->{"disconnected"}=&lg_json_true();
 $clients->{"disconnected_at"}=time();
 return &lg_save_clients($clients);
}

sub lg_cec_status (@) {
 my $raw="";
 eval { $raw=&webui_cec("status"); 1; };
 return &lg_decode_json($raw);
}

sub lg_detect_from_cec (@) {
 my $cec=shift;
 return 0 if(ref($cec) ne "HASH");
 my $osd_name=lc($cec->{"osd_name"}||"");
 return 1 if($osd_name =~ /\blg\b/);
 return 0;
}

sub lg_boot_id (@) {
 my $path="/proc/sys/kernel/random/boot_id";
 return "" if(!open(my $fh,"<",$path));
 my $id=<$fh>;
 close($fh);
 chomp($id);
 $id=~s/[^A-Za-z0-9-]//g;
 return $id;
}

sub lg_cec_vendor_is_lg (@) {
 my $vendor=lc(shift||"");
 $vendor=~s/^0x//;
 $vendor=~s/[^0-9a-f]//g;
 return ($vendor eq "00e091") ? 1 : 0;
}

sub lg_clean_cec_name (@) {
 my $name=shift;
 $name="" if(!defined($name));
 $name=~s/[\x00-\x1f\x7f]+//g;
 $name=~s/^\s+|\s+$//g;
 return $name;
}

sub lg_cec_lg_device (@) {
 return {};
}

sub lg_input_from_cec (@) {
 my $cec=&lg_cec_status();
 return "" if(ref($cec) ne "HASH");
 my $phys=$cec->{"phys_addr"}||"";
 return "hdmi$1" if($phys =~ /^([1-4])(?:\.|$)/);
 return "";
}

sub lg_discovery_hosts (@) {
 return ("lgwebostv.local","LGwebOSTV.local");
}

sub lg_mdns_encode_name (@) {
 my $name=shift;
 $name=lc($name||"");
 return "" if($name eq "");
 my $out="";
 foreach my $label (split(/\./,$name)) {
  return "" if($label eq "" || length($label) > 63);
  $out.=chr(length($label)).$label;
 }
 return $out."\0";
}

sub lg_mdns_read_name (@) {
 my ($packet,$offset,$depth)=@_;
 $depth=int($depth||0);
 return ("",$offset) if($offset < 0 || $offset >= length($packet) || $depth > 10);
 my $name="";
 my $pos=$offset;
 my $next=$offset;
 my $jumped=0;
 while($pos < length($packet)) {
  my $len=ord(substr($packet,$pos,1));
  $pos++;
  if($len == 0) {
   $next=$pos if(!$jumped);
   last;
  }
  if(($len & 0xC0) == 0xC0) {
   return ("",$offset) if($pos >= length($packet));
   my $pointer=(($len & 0x3F) << 8) | ord(substr($packet,$pos,1));
   $pos++;
   my ($suffix)=&lg_mdns_read_name($packet,$pointer,$depth + 1);
   $name.="." if($name ne "" && $suffix ne "");
   $name.=$suffix;
   $next=$pos if(!$jumped);
   $jumped=1;
   last;
  }
  return ("",$offset) if($pos + $len > length($packet));
  my $label=substr($packet,$pos,$len);
  $pos+=$len;
  $name.="." if($name ne "");
  $name.=$label;
  $next=$pos if(!$jumped);
 }
 return (lc($name),$next);
}

sub lg_mdns_parse_ipv4 (@) {
 my ($packet,$wanted_name)=@_;
 return "" if(!defined($packet) || length($packet) < 12 || !defined($wanted_name) || $wanted_name eq "");
 my (undef,$flags,$qdcount,$ancount,$nscount,$arcount)=unpack("n6",substr($packet,0,12));
 return "" if(($flags & 0x8000) == 0);
 my $offset=12;
 for(my $i=0;$i<$qdcount;$i++) {
  my (undef,$next)=&lg_mdns_read_name($packet,$offset,0);
  return "" if($next <= $offset || $next + 4 > length($packet));
  $offset=$next + 4;
 }
 my $records=$ancount + $nscount + $arcount;
 for(my $i=0;$i<$records;$i++) {
  my ($name,$next)=&lg_mdns_read_name($packet,$offset,0);
  return "" if($next <= $offset || $next + 10 > length($packet));
  $offset=$next;
  my ($type,$class,$ttl,$rdlength)=unpack("nnNn",substr($packet,$offset,10));
  $offset+=10;
  return "" if($offset + $rdlength > length($packet));
  if(lc($name) eq lc($wanted_name) && $type == 1 && ($class & 0x7FFF) == 1 && $rdlength == 4) {
   return join('.',unpack('C4',substr($packet,$offset,4)));
  }
  $offset+=$rdlength;
 }
 return "";
}

sub lg_mdns_lookup_host (@) {
 my ($host,$timeout)=@_;
 $host=lc($host||"");
 return "" if($host eq "");
 $timeout=1.2 if(!defined($timeout) || $timeout <= 0);
 my $socket=IO::Socket::INET->new(
  Proto => 'udp',
  LocalPort => 0,
  ReuseAddr => 1,
 );
 return "" if(!$socket);
 my $target=inet_aton("224.0.0.251");
 if(!$target) {
  close($socket);
  return "";
 }
 my $packet=pack("n6",0,0,1,0,0,0).&lg_mdns_encode_name($host).pack("nn",1,0x8001);
 if($packet eq "") {
  close($socket);
  return "";
 }
 send($socket,$packet,0,sockaddr_in(5353,$target));
 my $select=IO::Select->new($socket);
 my $deadline=time() + $timeout;
 while(time() < $deadline) {
  my $remaining=$deadline - time();
  last if($remaining <= 0);
  my @ready=$select->can_read($remaining);
  next if(!@ready);
  my $response="";
  recv($socket,$response,1500,0);
  my $ip=&lg_mdns_parse_ipv4($response,$host);
  if(&lg_valid_ipv4($ip)) {
   close($socket);
   return $ip;
  }
 }
 close($socket);
 return "";
}

sub lg_autodetect_info (@) {
 my ($clients,$force_refresh)=@_;
 $clients=&lg_load_clients() if(ref($clients) ne "HASH");
 $force_refresh=$force_refresh ? 1 : 0;
 my $cached_ip=$clients->{"auto_ip"}||"";
 my $cached_host=$clients->{"auto_host"}||"";
 my $cached_at=int($clients->{"auto_detected_at"}||0);
 my $rejected_ip=$clients->{"auto_rejected_ip"}||"";
 my $rejected_at=int($clients->{"auto_rejected_at"}||0);
 if(!$force_refresh && &lg_valid_ipv4($cached_ip) && $cached_at > 0 && (time() - $cached_at) < 60) {
  return { ip => $cached_ip, host => $cached_host, source => "mdns-cache" };
 }
 if(!$force_refresh && &lg_valid_ipv4($rejected_ip) && $rejected_at > 0 && (time() - $rejected_at) < 120) {
  return {};
 }
 foreach my $host (&lg_discovery_hosts()) {
  my $ip=&lg_mdns_lookup_host($host,1.2);
  next if(!&lg_valid_ipv4($ip));
  if(!$force_refresh && $ip eq $rejected_ip && $rejected_at > 0 && (time() - $rejected_at) < 120) {
   next;
  }
  my $probe=&lg_probe_device($ip);
  if(ref($probe) ne "HASH" || ($probe->{"status"}||"") ne "ok" || !$probe->{"is_lg_tv"}) {
   delete($clients->{"auto_ip"});
   delete($clients->{"auto_host"});
   delete($clients->{"auto_detected_at"});
   $clients->{"auto_rejected_ip"}=$ip;
   $clients->{"auto_rejected_host"}=lc($host);
   $clients->{"auto_rejected_at"}=time();
   &lg_save_clients($clients);
   next;
  }
  $clients->{"auto_ip"}=$ip;
  $clients->{"auto_host"}=lc($host);
  $clients->{"auto_detected_at"}=time();
  delete($clients->{"auto_rejected_ip"});
  delete($clients->{"auto_rejected_host"});
  delete($clients->{"auto_rejected_at"});
  &lg_save_clients($clients);
  return { ip => $ip, host => lc($host), source => "mdns-hostname" };
 }
 if(&lg_valid_ipv4($cached_ip)) {
  return { ip => $cached_ip, host => $cached_host, source => "mdns-cache" };
 }
 return {};
}

sub lg_scan_add_device (@) {
 my ($devices,$seen,$ip,$source,$name,$model)=@_;
 return if(ref($devices) ne "ARRAY" || ref($seen) ne "HASH" || !&lg_valid_ipv4($ip));
 return if($seen->{$ip});
 $seen->{$ip}=1;
 $name="" if(!defined($name));
 $model="" if(!defined($model));
 push(@{$devices},{
  ip => $ip,
  source => $source||"scan",
  name => $name,
  model_name => $model,
  label => ($name ne "" ? $name : ($model ne "" ? $model : "LG WebOS TV"))." ($ip)",
 });
}

my $_LG_PROBE_CACHE={};

sub lg_probe_device (@) {
 my $ip=shift;
 return {} if(!&lg_valid_ipv4($ip));
 return $_LG_PROBE_CACHE->{$ip} if(ref($_LG_PROBE_CACHE->{$ip}) eq "HASH");
 my $result=&lg_helper_run({
  action => "probe",
  ip => $ip,
  connect_timeout => 1,
 });
 $_LG_PROBE_CACHE->{$ip}=$result;
 return $result;
}

sub lg_scan_add_probe_device (@) {
 my ($devices,$seen,$ip,$source,$name,$model)=@_;
 return if(ref($devices) ne "ARRAY" || ref($seen) ne "HASH" || !&lg_valid_ipv4($ip));
 return if($seen->{$ip});
 my $probe=&lg_probe_device($ip);
 return if(ref($probe) ne "HASH" || ($probe->{"status"}||"") ne "ok" || !$probe->{"is_lg_tv"});
 $name=$probe->{"name"}||$name||"";
 $model=$probe->{"model_name"}||$model||"";
 &lg_scan_add_device($devices,$seen,$ip,$source,$name,$model);
}

sub lg_ipv4_to_int (@) {
 my $ip=shift;
 return undef if(!&lg_valid_ipv4($ip));
 my @p=split(/\./,$ip);
 return (($p[0]<<24) | ($p[1]<<16) | ($p[2]<<8) | $p[3]);
}

sub lg_int_to_ipv4 (@) {
 my $value=shift;
 return join(".",(($value>>24)&255),(($value>>16)&255),(($value>>8)&255),($value&255));
}

sub lg_local_broadcasts (@) {
 my @broadcasts=();
 my %seen=();
 my $raw=`ip -o -4 addr show scope global 2>/dev/null`;
 foreach my $line (split(/\n/,$raw)) {
  my ($ip,$prefix,$brd)=($line =~ /\binet\s+(\d+\.\d+\.\d+\.\d+)\/(\d+)(?:\s+brd\s+(\d+\.\d+\.\d+\.\d+))?/);
  next if(!&lg_valid_ipv4($ip));
  if(&lg_valid_ipv4($brd||"")) {
   next if($seen{$brd}++);
   push(@broadcasts,$brd);
   next;
  }
  next if(!defined($prefix) || $prefix < 16 || $prefix > 30);
  my $addr=&lg_ipv4_to_int($ip);
  next if(!defined($addr));
  my $mask=(0xffffffff << (32-$prefix)) & 0xffffffff;
  my $broadcast=($addr & $mask) | ((~$mask) & 0xffffffff);
  my $brd_ip=&lg_int_to_ipv4($broadcast);
  next if($seen{$brd_ip}++);
  push(@broadcasts,$brd_ip);
 }
 return @broadcasts;
}

sub lg_prime_neighbor_table (@) {
 return;
 foreach my $broadcast (&lg_local_broadcasts()) {
  next if(!&lg_valid_ipv4($broadcast));
  `timeout 2 ping -b -c 1 -W 1 $broadcast >/dev/null 2>&1`;
 }
}

sub lg_neighbor_ips (@) {
 my %ips=();
 my $raw=`ip -4 neigh show 2>/dev/null`;
 foreach my $line (split(/\n/,$raw)) {
  my ($ip)=($line =~ /^(\d+\.\d+\.\d+\.\d+)\s+/);
  next if(!&lg_valid_ipv4($ip));
  next if($line =~ /\b(?:FAILED|INCOMPLETE)\b/i);
  next if($line !~ /\b(?:REACHABLE|DELAY|PROBE)\b/i);
  $ips{$ip}=1;
 }
 $raw=`timeout 1 arp -an 2>/dev/null`;
 foreach my $line (split(/\n/,$raw)) {
  next if($line !~ /\b(?:REACHABLE|DELAY|PROBE)\b/i);
  my ($ip)=($line =~ /\((\d+\.\d+\.\d+\.\d+)\)/);
  $ips{$ip}=1 if(&lg_valid_ipv4($ip));
 }
 return sort(keys(%ips));
}

sub lg_webos_port_open (@) {
 my $ip=shift;
 return 0 if(!&lg_valid_ipv4($ip));
 foreach my $port (3000,3001) {
  my $sock=IO::Socket::INET->new(
   PeerHost => $ip,
   PeerPort => $port,
   Proto => 'tcp',
   Timeout => 0.22,
  );
  if($sock) {
   close($sock);
   return $port;
  }
 }
 return 0;
}

sub lg_ssdp_devices (@) {
 my @devices=();
 my %seen=();
 my $sock=IO::Socket::INET->new(
  Proto => "udp",
  PeerAddr => "239.255.255.250",
  PeerPort => 1900,
  Timeout => 0.4,
 );
 return \@devices if(!$sock);
 my @st=(
  "urn:lge-com:service:webos-second-screen:1",
  "urn:lge-com:device:webos:1",
  "ssdp:all",
 );
 foreach my $st (@st) {
  my $msg="M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: $st\r\n\r\n";
  eval { $sock->send($msg); 1; };
 }
 my $select=IO::Select->new($sock);
 my $deadline=time()+2;
 while(time() < $deadline) {
  my $remaining=$deadline-time();
  $remaining=0.1 if($remaining < 0.1);
  my @ready=$select->can_read($remaining);
  last if(!@ready);
  my $buf="";
  my $peer=$sock->recv($buf,4096);
  next if(!defined($buf) || $buf eq "");
  my $lc=lc($buf);
  next if($lc !~ /(lge|webos|lg electronics|second-screen)/);
  my $ip="";
  if($buf =~ /^LOCATION:\s*https?:\/\/(\d+\.\d+\.\d+\.\d+)(?::\d+)?\//im) {
   $ip=$1;
  } elsif(defined($peer)) {
   my ($port,$addr)=sockaddr_in($peer);
   $ip=join(".",unpack("C4",$addr)) if(defined($addr));
  }
  next if(!&lg_valid_ipv4($ip) || $seen{$ip}++);
  my $name="LG WebOS TV";
  if($buf =~ /^SERVER:\s*(.+)$/im) {
   my $server=$1;
   $server=~s/\r//g;
   if($server =~ /(webos[^\s;]*)/i) { $name="LG WebOS TV"; }
  }
  push(@devices,{ ip => $ip, source => "ssdp", name => $name, model_name => "" });
 }
 close($sock);
 return \@devices;
}

sub lg_default_lan_subnets (@) {
 my @subnets=();
 my %seen=();
 my $route=`ip route show default 2>/dev/null | head -n 1`;
 my ($iface)=($route =~ /\bdev\s+(\S+)/);
 return @subnets if(!defined($iface) || $iface eq "");
 my $raw=`ip -o -4 addr show dev $iface scope global 2>/dev/null`;
 foreach my $line (split(/\n/,$raw)) {
  my ($ip,$prefix)=($line =~ /\binet\s+(\d+\.\d+\.\d+\.\d+)\/(\d+)/);
  next if(!&lg_valid_ipv4($ip) || !defined($prefix));
  next if($prefix != 24);
  my @p=split(/\./,$ip);
  my $base=join(".",@p[0..2]);
  next if($seen{$base}++);
  push(@subnets,{ iface => $iface, base => $base, self => $ip });
 }
 return @subnets;
}

sub lg_webos_port_sweep_devices (@) {
 my @devices=();
 my %seen=();
 foreach my $subnet (&lg_default_lan_subnets()) {
  next if(ref($subnet) ne "HASH");
  my $base=$subnet->{"base"}||"";
  next if($base !~ /^\d+\.\d+\.\d+$/);
  my $script='for i in $(seq 1 254); do (ip='.$base.'.$i; timeout 0.35 bash -c "echo >/dev/tcp/$ip/3000" >/dev/null 2>&1 && echo "$ip 3000"; timeout 0.35 bash -c "echo >/dev/tcp/$ip/3001" >/dev/null 2>&1 && echo "$ip 3001")& done; wait';
  my $cmd="timeout 5 bash -c ".&lg_shell_quote($script)." 2>/dev/null";
  my $raw=`$cmd`;
  foreach my $line (split(/\n/,$raw)) {
   my ($ip,$port)=($line =~ /^(\d+\.\d+\.\d+\.\d+)\s+(300[01])$/);
   next if(!&lg_valid_ipv4($ip) || $seen{$ip}++);
   push(@devices,{ ip => $ip, source => "webos-sweep:$port", name => "LG WebOS TV", model_name => "" });
  }
 }
 return \@devices;
}

sub lg_scan_devices (@) {
 $_LG_PROBE_CACHE={};
 my $clients=&lg_load_clients();
 ($clients,my $pin_state)=&lg_reconcile_pin_pairing($clients);
 my $client=&lg_primary_client($clients);
 my @devices=();
 my %seen=();
 my $stored_name=$client->{"name"}||$client->{"model_name"}||"";
 &lg_scan_add_probe_device(\@devices,\%seen,$clients->{"manual_ip"}||"","saved",$stored_name,$client->{"model_name"}||"");
 &lg_scan_add_probe_device(\@devices,\%seen,$client->{"ip"}||"","paired",$stored_name,$client->{"model_name"}||"");
 my $auto=&lg_autodetect_info($clients,1);
 &lg_scan_add_probe_device(\@devices,\%seen,$auto->{"ip"}||"",$auto->{"source"}||"mdns","LG WebOS TV","");
 foreach my $device (@{&lg_webos_port_sweep_devices()}) {
  next if(ref($device) ne "HASH");
  &lg_scan_add_probe_device(\@devices,\%seen,$device->{"ip"}||"",$device->{"source"}||"webos-sweep",$device->{"name"}||"LG WebOS TV",$device->{"model_name"}||"");
 }
 &lg_prime_neighbor_table();
 my $count=0;
 foreach my $ip (&lg_neighbor_ips()) {
  last if($count > 80);
  next if($seen{$ip});
  my $port=&lg_webos_port_open($ip);
  next if(!$port);
  $count++;
  &lg_scan_add_probe_device(\@devices,\%seen,$ip,"webos:$port","LG WebOS TV","");
 }
 if(&lg_valid_ipv4($auto->{"ip"}||"") && !$seen{$auto->{"ip"}}) {
  delete($clients->{"auto_ip"});
  delete($clients->{"auto_host"});
  delete($clients->{"auto_detected_at"});
  &lg_save_clients($clients);
 }
 return {
  status => "ok",
  devices => \@devices,
  count => scalar(@devices),
  message => @devices ? "LG TV scan complete." : "No LG WebOS TVs were found on the network scan.",
 };
}

sub lg_target_ip (@) {
 my ($payload,$clients)=@_;
 $payload={} if(ref($payload) ne "HASH");
 $clients=&lg_load_clients() if(ref($clients) ne "HASH");
 my $body_ip=$payload->{"ip"}||"";
 return $body_ip if(&lg_valid_ipv4($body_ip));
 my $stored_ip=$clients->{"ip"}||"";
 return $stored_ip if(&lg_valid_ipv4($stored_ip));
 my $manual_ip=$clients->{"manual_ip"}||"";
 return $manual_ip if(&lg_valid_ipv4($manual_ip));
 my $auto=&lg_autodetect_info($clients,1);
 my $auto_ip=$auto->{"ip"}||"";
 return $auto_ip if(&lg_valid_ipv4($auto_ip));
 return "";
}

sub lg_helper_run (@) {
 my $request=shift;
 $request={} if(ref($request) ne "HASH");
 my $helper=&lg_helper_path();
 return { status => "error", message => "LG WebOS helper is not installed" } if(!-x $helper);
 my $payload=MIME::Base64::encode_base64(&lg_encode_json($request),"");
 my $timeout=&lg_helper_timeout($request);
 my $cmd="timeout ${timeout}s env PGEN_LG_REQUEST_B64=".&lg_shell_quote($payload)." ".&lg_shell_quote($helper)." 2>&1";
 my $raw=`$cmd`;
 my $exit_status=$? >> 8;
 my $result=&lg_decode_json($raw);
 if(ref($result) eq "HASH" && ($result->{"status"}||"") ne "") {
    return $result;
 }
 if($exit_status == 124 || $exit_status == 137) {
  return { status => "error", message => &lg_helper_timeout_message($request,$timeout) };
 }
 $raw =~ s/[\r\n]+/ /g;
 $raw =~ s/\s+/ /g;
 $raw =~ s/^\s+//;
 $raw =~ s/\s+$//;
 $raw="LG helper execution failed" if($raw eq "");
 return { status => "error", message => $raw };
}

sub lg_helper_timeout (@) {
 my $request=shift;
 $request={} if(ref($request) ne "HASH");
 my $override=int($request->{"helper_timeout"}||0);
 return $override if($override > 0);
 my $action=$request->{"action"}||"";
 if($action eq "picture_set") {
  my $settings=$request->{"settings"};
  if(ref($settings) eq "HASH" && (ref($settings->{"whiteBalanceRed"}) eq "ARRAY" || ref($settings->{"whiteBalanceGreen"}) eq "ARRAY" || ref($settings->{"whiteBalanceBlue"}) eq "ARRAY")) {
   return 150;
  }
  return 45;
 }
 return 180 if($action eq "3d_lut_probe" || $action eq "3d_lut_upload" || $action eq "3d_lut_reset");
 return 130 if($action eq "picture_reset");
 return 75 if($action eq "calibration_mode" || $action eq "hdr_tone_map_upload" || $action eq "hdr_calman_reset" || $action eq "1d_dpg_read");
 return 80 if($action eq "1d_dpg_upload");
 return 60 if($action eq "picture_get");
 return 90;
}

sub lg_helper_timeout_message (@) {
 my ($request,$timeout)=@_;
 $request={} if(ref($request) ne "HASH");
 my $action=$request->{"action"}||"";
 return "LG TV did not finish the white-balance write within ${timeout}s." if($action eq "picture_set");
 return "LG TV did not finish the 3D LUT command within ${timeout}s." if($action eq "3d_lut_probe" || $action eq "3d_lut_upload" || $action eq "3d_lut_reset");
 return "LG TV did not finish the HDR tone-map upload within ${timeout}s." if($action eq "hdr_tone_map_upload");
 return "LG TV did not finish the HDR20 1D DPG upload within ${timeout}s." if($action eq "1d_dpg_upload");
 return "LG TV did not finish the HDR20 1D DPG readback within ${timeout}s." if($action eq "1d_dpg_read");
 return "LG TV did not finish the HDR calibration reset within ${timeout}s." if($action eq "hdr_calman_reset");
 return "LG TV did not finish the picture-mode reset within ${timeout}s." if($action eq "picture_reset");
 return "LG TV did not answer the picture-settings request within ${timeout}s." if($action eq "picture_get");
 return "LG TV command timed out after ${timeout}s.";
}

sub lg_helper_start_async (@) {
 my ($request,$log_file)=@_;
 $request={} if(ref($request) ne "HASH");
 my $helper=&lg_helper_path();
 return 0 if(!-x $helper);
 my $payload=MIME::Base64::encode_base64(&lg_encode_json($request),"");
 my $cmd="nohup env PGEN_LG_REQUEST_B64=".&lg_shell_quote($payload)." ".&lg_shell_quote($helper)." >".&lg_shell_quote($log_file)." 2>&1 </dev/null & echo \$!";
 my $pid=`$cmd`;
 $pid=~s/\D+//g;
 return int($pid||0);
}

sub lg_pin_pair_start (@) {
 my ($ip,$manual_ip,$pairing_mode)=@_;
 $pairing_mode=&lg_normalize_pairing_mode($pairing_mode);
 my $clients=&lg_load_clients();
 ($clients,my $pending)=&lg_reconcile_pin_pairing($clients);
 if(ref($pending) eq "HASH" && ($pending->{"status"}||"") eq "pending") {
  return &lg_status_response("ok",$pending->{"message"}||"LG TV is waiting for pairing confirmation.",{ %{$pending}, pin_pairing_pending => &lg_json_true(), prompt_style => ($pending->{"prompt_style"}||"controller-pin"), pairing_mode => ($pending->{"pairing_mode"}||"PIN"), paired => &lg_json_false(), client_key_present => &lg_json_false() });
 }
 my $token=&lg_generate_token();
 my $dir=&lg_pin_session_dir($token);
 eval { make_path($dir); 1; };
 return &lg_status_response("error","Unable to prepare LG PIN pairing storage.",{}) if(!-d $dir);
 my $prompt_style=($pairing_mode eq "PIN") ? "controller-pin" : "mixed-prompt";
 my $client_key="";
 my $pid=&lg_helper_start_async({
  action => "connect_pin_wait",
  ip => $ip,
  client_key => $client_key,
  pairing_type => $pairing_mode,
  connect_timeout => 5,
  pair_timeout => 55,
  pin_wait_timeout => 150,
  state_file => &lg_pin_state_file($token),
  pin_file => &lg_pin_input_file($token),
  token => $token,
 },&lg_pin_log_file($token));
 $clients->{"pin_pairing"}={ token => $token, ip => $ip, pairing_mode => $pairing_mode, started_at => time(), pid => $pid };
 &lg_save_clients($clients);
 my $state={};
 for(my $i=0;$i<40;$i++) {
  $state=&lg_load_pin_state($token);
  last if(ref($state) eq "HASH" && ($state->{"status"}||"") ne "");
  select(undef,undef,undef,0.25);
 }
 if($pid <= 0 && (ref($state) ne "HASH" || ($state->{"status"}||"") eq "")) {
  delete($clients->{"pin_pairing"});
  &lg_save_clients($clients);
  &lg_clear_pin_session_files($token);
  return &lg_status_response("error","Unable to start LG PIN pairing.",{});
 }
 if(ref($state) eq "HASH" && ($state->{"status"}||"") eq "ok") {
  my $updated=&lg_update_connect_metadata($state,$manual_ip || $ip);
  delete($updated->{"pin_pairing"});
  &lg_save_clients($updated);
  &lg_clear_pin_session_files($token);
  return &lg_status_response("ok",$state->{"message"}||"LG TV connected using PIN pairing.",$state);
 }
 if(ref($state) eq "HASH" && ($state->{"status"}||"") eq "error") {
  delete($clients->{"pin_pairing"});
  $clients->{"last_error"}=$state->{"message"}||"LG PIN pairing failed.";
  &lg_save_clients($clients);
  &lg_clear_pin_session_files($token);
  return &lg_status_response("error",$state->{"message"}||"LG PIN pairing failed.",$state);
 }
 $state={
  status => "pending",
   message => ($pairing_mode eq "PIN")
    ? "LG TV should now be showing a PIN. Enter it below and click Submit PIN to finish pairing."
    : "LG TV should now be showing a pairing prompt or PIN. Accept it on the TV, or enter the PIN below if one appears.",
  pin_pairing_pending => &lg_json_true(),
   prompt_style => $prompt_style,
   pairing_mode => $pairing_mode,
  token => $token,
  ip => $ip,
 } if(ref($state) ne "HASH" || !%{$state});
 return &lg_status_response("ok",$state->{"message"},$state);
}

sub lg_pin_pair_submit (@) {
 my ($pin,$manual_ip)=@_;
 my $clients=&lg_load_clients();
 ($clients,my $pending)=&lg_reconcile_pin_pairing($clients);
 my $meta=$clients->{"pin_pairing"};
 return &lg_status_response("error","Start PIN Pairing before submitting the TV PIN.",{}) if(ref($meta) ne "HASH");
 my $token=$meta->{"token"}||"";
 return &lg_status_response("error","Start PIN Pairing before submitting the TV PIN.",{}) if($token eq "");
 return &lg_status_response("error","Enter the numeric PIN currently shown on the LG TV.",{}) if($pin !~ /^\d{4,8}$/);
 return &lg_status_response("error","LG PIN pairing is no longer waiting for a PIN. Start it again.",{}) if(ref($pending) ne "HASH" || ($pending->{"status"}||"") ne "pending");
 &write_file(&lg_pin_input_file($token).".tmp",&lg_pin_input_file($token),$pin."\n",1);
 my $state={};
 for(my $i=0;$i<240;$i++) {
  $state=&lg_load_pin_state($token);
  last if(ref($state) eq "HASH" && ($state->{"status"}||"") ne "pending" && ($state->{"status"}||"") ne "");
  select(undef,undef,undef,0.25);
 }
 if(ref($state) eq "HASH" && ($state->{"status"}||"") eq "ok") {
  my $updated=&lg_update_connect_metadata($state,$manual_ip || $meta->{"ip"}||"");
  delete($updated->{"pin_pairing"});
  &lg_save_clients($updated);
  &lg_clear_pin_session_files($token);
  return &lg_status_response("ok",$state->{"message"}||"LG TV connected using PIN pairing.",$state);
 }
 my $message="LG PIN pairing did not complete. Start PIN Pairing again.";
 $message=$state->{"message"} if(ref($state) eq "HASH" && ($state->{"message"}||"") ne "");
 delete($clients->{"pin_pairing"});
 $clients->{"last_error"}=$message;
 &lg_save_clients($clients);
 &lg_clear_pin_session_files($token);
 return &lg_status_response("error",$message,$state);
}

sub lg_update_connect_metadata (@) {
 my ($result,$manual_ip)=@_;
 my $clients=&lg_load_clients();
 $manual_ip="" if(!defined($manual_ip));
 if($manual_ip ne "") {
    $clients->{"manual_ip"}=$manual_ip;
 }
 if(ref($result) ne "HASH") {
    &lg_save_clients($clients);
    return $clients;
 }
 if(($result->{"status"}||"") eq "ok") {
    my $ip=$result->{"ip"}||$manual_ip||"";
    $clients->{"ip"}=$ip if($ip ne "");
    $clients->{"client_key"}=$result->{"client_key"} if(($result->{"client_key"}||"") ne "");
    $clients->{"name"}=$result->{"name"} if(($result->{"name"}||"") ne "");
    $clients->{"model_name"}=$result->{"model_name"} if(($result->{"model_name"}||"") ne "");
    $clients->{"software_version"}=$result->{"software_version"} if(($result->{"software_version"}||"") ne "");
    $clients->{"transport"}=$result->{"transport"} if(($result->{"transport"}||"") ne "");
    $clients->{"hello_info"}=$result->{"hello_info"} if(ref($result->{"hello_info"}) eq "HASH");
    $clients->{"system_info"}=$result->{"system_info"} if(ref($result->{"system_info"}) eq "HASH");
    $clients->{"software_info"}=$result->{"software_info"} if(ref($result->{"software_info"}) eq "HASH");
    $clients->{"last_seen"}=time();
    delete($clients->{"disconnected"});
    delete($clients->{"disconnected_at"});
    delete($clients->{"last_error"});
 } else {
    $clients->{"last_error"}=$result->{"message"}||"LG connection failed";
 }
 &lg_save_clients($clients);
 return $clients;
}

sub lg_status_response (@) {
 my ($status,$message,$extra)=@_;
 my $payload=&lg_status_data($message);
 $payload->{"status"}=$status if(defined($status) && $status ne "");
 if(ref($extra) eq "HASH") {
    foreach my $key (keys(%{$extra})) {
     next if($key eq "status" || $key eq "message");
     $payload->{$key}=$extra->{$key};
    }
 }
 if($payload->{"pin_pairing_pending"}) {
    $payload->{"paired"}=&lg_json_false();
    $payload->{"client_key_present"}=&lg_json_false();
 }
 return $payload;
}

sub lg_status_data (@) {
 my $message_override=shift;
 my $clients=&lg_load_clients();
 ($clients,my $pin_state)=&lg_reconcile_pin_pairing($clients);
 my $client=&lg_primary_client($clients);
 my $client_key=$client->{"client_key"}||$client->{"client-key"}||"";
 my $manual_ip=$clients->{"manual_ip"}||"";
 my $stored_ip=$client->{"ip"}||"";
 my $has_saved_tv=(($client_key ne "") || ($manual_ip ne "") || ($stored_ip ne "")) ? 1 : 0;
 my $auto={};
 if($has_saved_tv) {
  my $cached_ip=$clients->{"auto_ip"}||"";
  my $cached_host=$clients->{"auto_host"}||"";
  if(&lg_valid_ipv4($cached_ip)) {
   $auto={ ip => $cached_ip, host => $cached_host, source => "mdns-cache" };
  }
 } else {
  $auto=&lg_autodetect_info($clients,0);
 }
 my $auto_ip=$auto->{"ip"}||"";
 my $auto_host=$auto->{"host"}||"";
 my $stored_name=$client->{"name"}||$client->{"model_name"}||"";
 my $model_name=$client->{"model_name"}||"";
 my $software_version=$client->{"software_version"}||"";
 my $transport=$client->{"transport"}||"";
 my $last_error=$client->{"last_error"}||$clients->{"last_error"}||"";
 my $last_seen=$client->{"last_seen"}||"";
 my $calibration_mode=$clients->{"calibration_mode"} ? 1 : 0;
 my $calibration_picture_mode=$clients->{"calibration_picture_mode"}||"";
 my $cec=&lg_cec_status();
 my $osd_name=$cec->{"osd_name"}||"";
 my $cec_tv_name=($model_name ne "" || $stored_name ne "" || $auto_ip ne "" || $manual_ip ne "" || $stored_ip ne "") ? "LG TV" : "";
 my $cec_tv_vendor="";
 my $detected=&lg_detect_from_cec($cec);
 my $pin_pending=(ref($pin_state) eq "HASH" && ($pin_state->{"status"}||"") eq "pending") ? 1 : 0;
 my $paired=($client_key ne "" && !$pin_pending) ? 1 : 0;
 my $disconnected=($clients->{"disconnected"} && $paired) ? 1 : 0;
 my $connected=($paired && !$disconnected) ? 1 : 0;
 my $supported=($detected || $paired || $stored_ip ne "" || $manual_ip ne "" || $auto_ip ne "") ? 1 : 0;
 my $detection_source=$auto_ip ne "" ? ($auto->{"source"}||"mdns-hostname") : ($detected ? ($cec_tv_vendor ne "" ? "cec-vendor" : "cec-osd-name") : "manual-only");
 my $message=$message_override;

 if(!defined($message) || $message eq "") {
    if($pin_pending) {
     $message=$pin_state->{"message"}||"LG TV should now be showing a PIN. Enter it below and click Submit PIN to finish pairing.";
    } elsif($disconnected) {
     $message="LG TV is disconnected. Connect will reuse the saved key without another PIN.";
    } elsif($paired && $stored_name ne "") {
     $message="Stored LG WebOS pairing is ready for $stored_name. Click Connect to reconnect or refresh TV info.";
  } elsif($paired) {
     $message="Stored LG WebOS pairing is available. Click Connect to refresh the connection.";
    } elsif($stored_ip ne "") {
     $message="LG TV IP is saved. Click Pair With PIN if no saved key is available.";
    } elsif($auto_ip ne "") {
     $message="LG TV was auto-detected from $auto_host at $auto_ip.";
    } elsif($detected) {
     $message="CEC currently looks like an LG TV. Enter the TV IP to start WebOS pairing.";
  } else {
     $message="Enter the LG TV IP, or let PGenerator try lgwebostv.local on your network.";
  }
  if(!$detected && $auto_ip eq "") {
     $message.=" CEC auto-detection is still limited to the local OSD name until vendor/model data is exposed.";
  }
 }

 return {
  status => "ok",
    supported => &lg_json_bool($supported),
  detected => &lg_json_bool($detected || $auto_ip ne ""),
  detection_limited => ($auto_ip ne "") ? &lg_json_false() : &lg_json_true(),
  detection_source => $detection_source,
  paired => &lg_json_bool($paired),
  connected => &lg_json_bool($connected),
  disconnected => &lg_json_bool($disconnected),
      pair_prompted => $pin_pending ? &lg_json_true() : &lg_json_false(),
      prompt_style => $pin_pending ? ($pin_state->{"prompt_style"}||"controller-pin") : "tv-prompt",
   pairing_mode => $pin_pending ? ($pin_state->{"pairing_mode"}||"PIN") : "",
   client_key_present => &lg_json_bool(($client_key ne "") && !$pin_pending),
   disconnected_at => $clients->{"disconnected_at"}||"",
   pin_pairing_pending => &lg_json_bool($pin_pending),
   pin_pairing_ip => $pin_state->{"ip"}||"",
  cec_osd_name => $osd_name,
  cec_tv_name => $cec_tv_name,
  cec_tv_vendor => $cec_tv_vendor,
  tv_power => $cec->{"tv_power"}||"",
  phys_addr => $cec->{"phys_addr"}||"",
  log_addr => $cec->{"log_addr"}||"",
  manual_ip => $manual_ip,
  stored_ip => $stored_ip,
   auto_ip => $auto_ip,
   auto_host => $auto_host,
  stored_name => $stored_name,
    model_name => $model_name,
    software_version => $software_version,
    transport => $transport,
    calibration_mode => &lg_json_bool($calibration_mode),
  calibration_picture_mode => $calibration_picture_mode,
    boot_id => &lg_boot_id(),
    last_error => $last_error,
    last_seen => $last_seen,
  message => $message,
 };
}

sub lg_picture_default_keys (@) {
 return [
  "pictureMode",
  "whiteBalanceMethod",
  "whiteBalancePoint",
  "whiteBalanceIre",
  "whiteBalanceIre10pt",
  "whiteBalanceCodeValue",
  "whiteBalanceCodeValue10pt",
  "whiteBalanceLuminance",
  "whiteBalanceColorTemperature",
  "colorTemperature",
  "whiteBalanceRed",
  "whiteBalanceGreen",
  "whiteBalanceBlue",
  "whiteBalanceRed10pt",
  "whiteBalanceGreen10pt",
  "whiteBalanceBlue10pt",
  "whiteBalanceRedGain",
  "whiteBalanceGreenGain",
  "whiteBalanceBlueGain",
  "whiteBalanceRedOffset",
  "whiteBalanceGreenOffset",
  "whiteBalanceBlueOffset",
  "oledLight",
  "backlight",
  "adjustingLuminance",
  "adjustingLuminance10pt"
 ];
}

sub lg_picture_diagnostic_keys (@) {
 my @keys=(@{&lg_picture_default_keys()},
  "brightness","contrast","blackLevel","blackLevelAdjust",
  "oledPixelBrightness","peakBrightness","color","colorDepth","tint",
  "sharpness","hSharpness","vSharpness","gamma","colorGamut",
  "energySaving","dynamicContrast","dynamicColor","localDimming",
  "noiseReduction","mpegNoiseReduction","smoothGradation","superResolution",
  "realCinema","eyeComfortMode","blackFrameInsertion","truMotionMode",
  "deJudder","deBlur"
 );
 my %seen;
 return [grep { !$seen{$_}++ } @keys];
}

sub lg_picture_needs_repair (@) {
 my $result=shift;
 return 0 if(ref($result) ne "HASH");
 return 0 if(($result->{"error_code"}||"") eq "lg-calibration-permission");
 return 0 if($result->{"ddc_1d_lut"} && (($result->{"message"}||"") =~ /CAL_START returned 401/i));
 return 1 if(($result->{"needs_repair"}||0));
 return 1 if(($result->{"error_code"}||"") eq "insufficient-permissions");
 my $message=$result->{"message"}||"";
 return ($message =~ /insufficient permissions/i) ? 1 : 0;
}

###############################################
#              LG API Helpers                 #
###############################################
sub webui_lg_status_json (@) {
 my $message=shift;
 return &lg_encode_json(&lg_status_response("ok",$message,{}));
}

sub webui_lg_manual_ip (@) {
 my $body=shift;
 my $payload=&lg_decode_json($body);
 my $ip=$payload->{"ip"}||"";
 return &lg_encode_json({ status => "error", message => "Enter a valid IPv4 address" }) if($ip ne "" && !&lg_valid_ipv4($ip));
 my $clients=&lg_load_clients();
 if($ip eq "") {
  delete($clients->{"manual_ip"});
 } else {
  $clients->{"manual_ip"}=$ip;
 }
 return &lg_encode_json({ status => "error", message => "Unable to save LG TV IP" }) if(!&lg_save_clients($clients));
 my $message=($ip eq "") ? "LG TV IP cleared." : "LG TV IP saved.";
 return &webui_lg_status_json($message);
}

sub webui_lg_forget (@) {
 return &lg_encode_json({ status => "error", message => "Unable to clear stored LG pairing" }) if(!&lg_clear_pairing());
 return &webui_lg_status_json("Stored LG pairing metadata cleared.");
}

sub webui_lg_disconnect (@) {
 return &lg_encode_json({ status => "error", message => "Unable to disconnect LG TV" }) if(!&lg_mark_disconnected());
 return &webui_lg_status_json("LG TV disconnected. Saved pairing is kept for the next Connect.");
}

sub webui_lg_pin_pair_start (@) {
 my $body=shift;
 my $payload=&lg_decode_json($body);
 my $clients=&lg_load_clients();
 my $manual_ip=$payload->{"ip"}||"";
 my $pairing_mode=&lg_normalize_pairing_mode($payload->{"pairing_mode"}||$payload->{"pairingType"}||"PIN");
 return &lg_encode_json({ status => "error", message => "Enter a valid IPv4 address" }) if($manual_ip ne "" && !&lg_valid_ipv4($manual_ip));
 if($manual_ip ne "") {
  $clients->{"manual_ip"}=$manual_ip;
  return &lg_encode_json({ status => "error", message => "Unable to save LG TV IP" }) if(!&lg_save_clients($clients));
 }
 my $ip=&lg_target_ip($payload,$clients);
 return &lg_encode_json(&lg_status_response("error","Enter and save the LG TV IP before starting PIN pairing.",{})) if($ip eq "");
 my $result=&lg_pin_pair_start($ip,$manual_ip || $ip,$pairing_mode);
 return &lg_encode_json($result);
}

sub webui_lg_pin_pair_submit (@) {
 my $body=shift;
 my $payload=&lg_decode_json($body);
 my $pin=$payload->{"pin"}||"";
 $pin =~ s/\D+//g;
 my $clients=&lg_load_clients();
 my $manual_ip=$clients->{"manual_ip"}||"";
 my $result=&lg_pin_pair_submit($pin,$manual_ip);
 return &lg_encode_json($result);
}

sub webui_lg_connect (@) {
 my $body=shift;
 my $payload=&lg_decode_json($body);
 my $clients=&lg_load_clients();
 my $manual_ip=$payload->{"ip"}||"";
 return &lg_encode_json({ status => "error", message => "Enter a valid IPv4 address" }) if($manual_ip ne "" && !&lg_valid_ipv4($manual_ip));
 if($manual_ip ne "") {
  $clients->{"manual_ip"}=$manual_ip;
  return &lg_encode_json({ status => "error", message => "Unable to save LG TV IP" }) if(!&lg_save_clients($clients));
 }
 my $ip=&lg_target_ip($payload,$clients);
 return &lg_encode_json(&lg_status_response("error","Enter and save the LG TV IP before connecting.",{})) if($ip eq "");
 my $client=&lg_primary_client($clients);
 my $client_key=$client->{"client_key"}||$client->{"client-key"}||"";
 my $result=&lg_helper_run({
  action => "connect",
  ip => $ip,
  client_key => $client_key,
  connect_timeout => 5,
  pair_timeout => 55,
 });
 &lg_update_connect_metadata($result,$manual_ip || $ip);
 return &lg_encode_json(&lg_status_response($result->{"status"}||"error",$result->{"message"}||"LG connection failed",$result));
}

sub webui_lg_scan (@) {
 return &lg_encode_json(&lg_scan_devices());
}

sub webui_lg_calibration_mode (@) {
 my $body=shift;
 my $payload=&lg_decode_json($body);
 my $enabled=$payload->{"enabled"} ? 1 : 0;
 my $clients=&lg_load_clients();
 ($clients,my $pin_state)=&lg_reconcile_pin_pairing($clients);
	 if(ref($pin_state) eq "HASH" && ($pin_state->{"status"}||"") eq "pending") {
	  return &lg_encode_json({ status => "error", message => "Complete LG PIN pairing before changing calibration mode." });
	 }
	 return &lg_encode_json({ status => "error", message => "Connect the LG TV before changing calibration mode." }) if(&lg_clients_disconnected($clients));
	 my $ip=&lg_target_ip($payload,$clients);
 return &lg_encode_json({ status => "error", message => "Connect the LG TV before changing calibration mode." }) if($ip eq "");
 my $client=&lg_primary_client($clients);
 my $client_key=$client->{"client_key"}||$client->{"client-key"}||"";
 return &lg_encode_json({ status => "error", message => "Connect the LG TV before changing calibration mode." }) if($client_key eq "");
 my $result=&lg_helper_run({
  action => "calibration_mode",
  ip => $ip,
  client_key => $client_key,
  enable => $enabled,
  picture_mode => $payload->{"picture_mode"}||"",
  connect_timeout => 5,
 });
 if(($result->{"status"}||"") eq "ok") {
  $clients=&lg_update_connect_metadata($result,$clients->{"manual_ip"} || $ip);
  $clients->{"calibration_mode"}=$enabled ? &lg_json_true() : &lg_json_false();
  if($enabled) {
   $clients->{"calibration_picture_mode"}=$result->{"calibration_picture_mode"}||$result->{"active_picture_mode"}||"";
  } else {
   delete($clients->{"calibration_picture_mode"});
  }
  &lg_save_clients($clients);
 }
 return &lg_encode_json(&lg_status_response($result->{"status"}||"error",$result->{"message"}||"Unable to change LG calibration mode.",$result));
}

sub webui_lg_picture_settings (@) {
 my $body=shift;
 my $payload=&lg_decode_json($body);
 my $clients=&lg_load_clients();
 ($clients,my $pin_state)=&lg_reconcile_pin_pairing($clients);
	 if(ref($pin_state) eq "HASH" && ($pin_state->{"status"}||"") eq "pending") {
	  return &lg_encode_json({ status => "error", message => "Complete LG PIN pairing first by entering the PIN shown on the TV.", needs_repair => &lg_json_true() });
	 }
	 return &lg_encode_json({ status => "error", message => "Connect the LG TV before reading picture settings." }) if(&lg_clients_disconnected($clients));
	 my $ip=&lg_target_ip($payload,$clients);
 return &lg_encode_json({ status => "error", message => "Connect the LG TV before reading picture settings." }) if($ip eq "");
 my $client=&lg_primary_client($clients);
 my $client_key=$client->{"client_key"}||$client->{"client-key"}||"";
 return &lg_encode_json({ status => "error", message => "Connect the LG TV before reading picture settings." }) if($client_key eq "");
 my $keys=$payload->{"keys"};
 $keys=&lg_picture_default_keys() if(ref($keys) ne "ARRAY" || !@{$keys});
 my $ignore_calibration_picture_mode=$payload->{"ignore_calibration_picture_mode"} ? 1 : 0;
 my $picture_mode=$payload->{"picture_mode"}||"";
 $picture_mode=$clients->{"calibration_picture_mode"}||"" if($picture_mode eq "" && !$ignore_calibration_picture_mode);
my $result=&lg_helper_run({
 action => "picture_get",
 ip => $ip,
 client_key => $client_key,
  keys => $keys,
	  picture_mode => $picture_mode,
	  tv_input => &lg_input_from_cec(),
	  force_ddc_white_balance => $payload->{"force_ddc_white_balance"} ? &lg_json_true() : &lg_json_false(),
	  helper_timeout => int($payload->{"helper_timeout"}||0),
	  connect_timeout => 5,
	 });
 &lg_update_connect_metadata($result,$clients->{"manual_ip"} || $ip) if(($result->{"status"}||"") eq "ok");
 return &lg_encode_json($result);
}

sub lg_settings_are_ddc_white_balance (@) {
 my $settings=shift;
 return 0 if(ref($settings) ne "HASH");
 return 0 if(($settings->{"whiteBalanceMethod"}||"") ne "22");
 return 0 if(ref($settings->{"whiteBalanceRed"}) ne "ARRAY");
 return 0 if(ref($settings->{"whiteBalanceGreen"}) ne "ARRAY");
 return 0 if(ref($settings->{"whiteBalanceBlue"}) ne "ARRAY");
 return 1;
}

sub webui_lg_picture_settings_set (@) {
 my $body=shift;
 my $payload=&lg_decode_json($body);
 my $clients=&lg_load_clients();
 ($clients,my $pin_state)=&lg_reconcile_pin_pairing($clients);
	 if(ref($pin_state) eq "HASH" && ($pin_state->{"status"}||"") eq "pending") {
	  return &lg_encode_json({
	   status => "error",
	   message => "Complete LG PIN pairing first by entering the PIN shown on the TV.",
	   needs_repair => &lg_json_true(),
	   repair_hint => "Use Display and click Submit PIN after typing the code shown on the TV.",
	  });
	 }
	 return &lg_encode_json({ status => "error", message => "Connect the LG TV before changing picture settings." }) if(&lg_clients_disconnected($clients));
	 my $ip=&lg_target_ip($payload,$clients);
 return &lg_encode_json({ status => "error", message => "Connect the LG TV before changing picture settings." }) if($ip eq "");
 my $client=&lg_primary_client($clients);
 my $client_key=$client->{"client_key"}||$client->{"client-key"}||"";
 return &lg_encode_json({ status => "error", message => "Connect the LG TV before changing picture settings." }) if($client_key eq "");
 my $settings=$payload->{"settings"};
 return &lg_encode_json({ status => "error", message => "No LG picture settings were provided." }) if(ref($settings) ne "HASH" || !%{$settings});
 my $readback_keys=$payload->{"readback_keys"};
 if($payload->{"skip_readback"}) {
  $readback_keys=[];
 } elsif(ref($readback_keys) ne "ARRAY" || !@{$readback_keys}) {
  $readback_keys=[keys(%{$settings})];
 }
 my $ignore_calibration_picture_mode=$payload->{"ignore_calibration_picture_mode"} ? 1 : 0;
 my $picture_mode=$payload->{"picture_mode"}||"";
 $picture_mode=$clients->{"calibration_picture_mode"}||"" if($picture_mode eq "" && !$ignore_calibration_picture_mode);
	 my $ddc_white_balance=&lg_settings_are_ddc_white_balance($settings);
	 my $keep_calibration_mode=exists($payload->{"keep_calibration_mode"})
	  ? ($payload->{"keep_calibration_mode"} ? 1 : 0)
	  : (($clients->{"calibration_mode"}||$ddc_white_balance) ? 1 : 0);
 my $calibration_mode_active=($payload->{"calibration_mode_active"}||($ddc_white_balance&&$keep_calibration_mode&&$clients->{"calibration_mode"})) ? 1 : 0;
 $calibration_mode_active=0 if($payload->{"reset_ddc_baseline"}||$payload->{"clear_ddc_baseline"});
 my $result=&lg_helper_run({
  action => "picture_set",
  ip => $ip,
  client_key => $client_key,
  settings => $settings,
  readback_keys => $readback_keys,
	  picture_mode => $picture_mode,
	  signal_mode => $payload->{"signal_mode"}||"",
	  tv_input => &lg_input_from_cec(),
		  keep_calibration_mode => $keep_calibration_mode,
		  calibration_mode_active => $calibration_mode_active,
		  reset_ddc_baseline => ($payload->{"reset_ddc_baseline"}||$payload->{"clear_ddc_baseline"}) ? &lg_json_true() : &lg_json_false(),
		  verify_ddc_upload => $payload->{"verify_ddc_upload"} ? &lg_json_true() : &lg_json_false(),
		  force_ddc_white_balance => $payload->{"force_ddc_white_balance"} ? &lg_json_true() : &lg_json_false(),
		  helper_timeout => int($payload->{"helper_timeout"}||0),
	  connect_timeout => 5,
	 });
 my $updated_clients=$clients;
 $updated_clients=&lg_update_connect_metadata($result,$clients->{"manual_ip"} || $ip) if(($result->{"status"}||"") eq "ok");
	 if(($result->{"status"}||"") eq "ok" && $ddc_white_balance && ($result->{"ddc_1d_lut"} || exists($result->{"calibration_mode"}))) {
	  $updated_clients->{"calibration_mode"}=$keep_calibration_mode ? &lg_json_true() : &lg_json_false();
	  my $cal_mode=$result->{"calibration_picture_mode"}||$result->{"active_picture_mode"}||$payload->{"picture_mode"}||$clients->{"calibration_picture_mode"}||"";
	  if($keep_calibration_mode) {
	   $updated_clients->{"calibration_picture_mode"}=$cal_mode if($cal_mode ne "");
	  } else {
	   delete($updated_clients->{"calibration_picture_mode"});
	  }
	  &lg_save_clients($updated_clients);
	  $result->{"calibration_mode"}=$keep_calibration_mode ? &lg_json_true() : &lg_json_false();
	  $result->{"calibration_picture_mode"}=$cal_mode if($cal_mode ne "");
	 }
 if(&lg_picture_needs_repair($result)) {
   $result->{"message"}="The saved LG client key does not have picture-control permission. Use Display -> Pair With PIN once, enter the TV PIN, then reconnects will use the saved key without another PIN.";
   $result->{"repair_hint"}="Use Display -> Pair With PIN once, then submit the PIN shown on the TV.";
 } elsif(($result->{"error_code"}||"") eq "lg-calibration-permission") {
   $result->{"repair_hint"}="The TV accepted pairing but denied LG calibration/DDC access. Clear the existing LG Connect Apps entry for PGenerator/LG Remote App on the TV, then pair from Display again.";
 }
 return &lg_encode_json($result);
}

sub webui_lg_picture_reset (@) {
 my $body=shift;
 my $payload=&lg_decode_json($body);
 my $clients=&lg_load_clients();
 ($clients,my $pin_state)=&lg_reconcile_pin_pairing($clients);
	 if(ref($pin_state) eq "HASH" && ($pin_state->{"status"}||"") eq "pending") {
	  return &lg_encode_json({
	   status => "error",
	   message => "Complete LG PIN pairing first by entering the PIN shown on the TV.",
	   needs_repair => &lg_json_true(),
	  });
	 }
	 return &lg_encode_json({ status => "error", message => "Connect the LG TV before resetting picture settings." }) if(&lg_clients_disconnected($clients));
	 my $ip=&lg_target_ip($payload,$clients);
 return &lg_encode_json({ status => "error", message => "Connect the LG TV before resetting picture settings." }) if($ip eq "");
 my $client=&lg_primary_client($clients);
 my $client_key=$client->{"client_key"}||$client->{"client-key"}||"";
 return &lg_encode_json({ status => "error", message => "Connect the LG TV before resetting picture settings." }) if($client_key eq "");
 my $result=&lg_helper_run({
  action => "picture_reset",
	  ip => $ip,
	  client_key => $client_key,
	  picture_mode => $payload->{"picture_mode"}||"",
	  signal_mode => $payload->{"signal_mode"}||"",
	  require_white_balance_reset => $payload->{"require_white_balance_reset"} ? &lg_json_true() : &lg_json_false(),
	  reset_ddc_state => $payload->{"require_white_balance_reset"} ? 1 : 0,
	  tv_input => &lg_input_from_cec(),
	  connect_timeout => 5,
	 });
 &lg_update_connect_metadata($result,$clients->{"manual_ip"} || $ip) if(($result->{"status"}||"") eq "ok");
 if(&lg_picture_needs_repair($result)) {
  $result->{"message"}="The saved LG client key does not have picture-control permission. Use Display -> Pair With PIN once, enter the TV PIN, then reconnects will use the saved key without another PIN.";
  $result->{"repair_hint"}="Use Display -> Pair With PIN once, then submit the PIN shown on the TV.";
 }
 return &lg_encode_json($result);
}

sub webui_lg_cec_fallback (@) {
 my $command=shift;
 $command=lc($command||"");
 return {} if($command !~ /^(?:active|input|volup|voldown|mute)$/);
 my $clients=&lg_load_clients();
 ($clients,my $pin_state)=&lg_reconcile_pin_pairing($clients);
 return {} if(ref($pin_state) eq "HASH" && ($pin_state->{"status"}||"") eq "pending");
 my $ip=&lg_target_ip({},$clients);
 return {} if($ip eq "");
 my $client=&lg_primary_client($clients);
 my $client_key=$client->{"client_key"}||$client->{"client-key"}||"";
 return {} if($client_key eq "");
 my $target_input="";
 if($command eq "active" || $command eq "input") {
  $target_input=&lg_input_from_cec();
  $target_input="hdmi1" if($target_input eq "");
 }
 my $result=&lg_helper_run({
  action => "remote_control",
  ip => $ip,
  client_key => $client_key,
  command => $command,
  target_input => $target_input,
  connect_timeout => 4,
 });
 &lg_update_connect_metadata($result,$clients->{"manual_ip"} || $ip) if(ref($result) eq "HASH" && ($result->{"status"}||"") eq "ok");
 return $result;
}

sub lg_3d_lut_payload_path_ok (@) {
 my $path=shift;
 $path="" if(!defined($path));
 return ($path =~ m{^/var/lib/PGenerator/lg/luts/[A-Za-z0-9_.-]+\.bin$}) ? 1 : 0;
}

sub webui_lg_3d_lut_probe (@) {
 my $body=shift;
 my $payload=&lg_decode_json($body);
 my $clients=&lg_load_clients();
 ($clients,my $pin_state)=&lg_reconcile_pin_pairing($clients);
	 if(ref($pin_state) eq "HASH" && ($pin_state->{"status"}||"") eq "pending") {
	  return &lg_encode_json({ status => "error", message => "Complete LG PIN pairing before probing 3D LUT support.", needs_repair => &lg_json_true() });
	 }
	 return &lg_encode_json({ status => "error", message => "Connect the LG TV before probing 3D LUT support." }) if(&lg_clients_disconnected($clients));
	 my $ip=&lg_target_ip($payload,$clients);
 return &lg_encode_json({ status => "error", message => "Connect the LG TV before probing 3D LUT support." }) if($ip eq "");
 my $client=&lg_primary_client($clients);
 my $client_key=$client->{"client_key"}||$client->{"client-key"}||"";
 return &lg_encode_json({ status => "error", message => "Connect the LG TV before probing 3D LUT support." }) if($client_key eq "");
 my $result=&lg_helper_run({
  action => "3d_lut_probe",
  ip => $ip,
  client_key => $client_key,
  picture_mode => $payload->{"picture_mode"}||$clients->{"calibration_picture_mode"}||"",
  write_probe => $payload->{"write_probe"} ? &lg_json_true() : &lg_json_false(),
  helper_timeout => int($payload->{"helper_timeout"}||0),
  connect_timeout => 5,
 });
 &lg_update_connect_metadata($result,$clients->{"manual_ip"} || $ip) if(($result->{"status"}||"") eq "ok");
 if(&lg_picture_needs_repair($result)) {
  $result->{"message"}="The saved LG client key does not have calibration permission. Use Display -> Pair With PIN once, enter the TV PIN, then try the 3D LUT probe again.";
  $result->{"repair_hint"}="Use Display -> Pair With PIN once, then submit the PIN shown on the TV.";
 }
 return &lg_encode_json($result);
}

sub webui_lg_3d_lut_upload (@) {
 my $body=shift;
 my $payload=&lg_decode_json($body);
 my $payload_path=$payload->{"payload_path"}||"";
 return &lg_encode_json({ status => "error", message => "LG 3D LUT upload requires an exported payload under /var/lib/PGenerator/lg/luts." }) if(!&lg_3d_lut_payload_path_ok($payload_path) || !-f $payload_path);
 my $clients=&lg_load_clients();
 ($clients,my $pin_state)=&lg_reconcile_pin_pairing($clients);
	 if(ref($pin_state) eq "HASH" && ($pin_state->{"status"}||"") eq "pending") {
	  return &lg_encode_json({ status => "error", message => "Complete LG PIN pairing before uploading a 3D LUT.", needs_repair => &lg_json_true() });
	 }
	 return &lg_encode_json({ status => "error", message => "Connect the LG TV before uploading a 3D LUT." }) if(&lg_clients_disconnected($clients));
	 my $ip=&lg_target_ip($payload,$clients);
 return &lg_encode_json({ status => "error", message => "Connect the LG TV before uploading a 3D LUT." }) if($ip eq "");
 my $client=&lg_primary_client($clients);
 my $client_key=$client->{"client_key"}||$client->{"client-key"}||"";
 return &lg_encode_json({ status => "error", message => "Connect the LG TV before uploading a 3D LUT." }) if($client_key eq "");
 my $result=&lg_helper_run({
  action => "3d_lut_upload",
  ip => $ip,
  client_key => $client_key,
  picture_mode => $payload->{"picture_mode"}||$clients->{"calibration_picture_mode"}||"",
  payload_path => $payload_path,
  upload_command => $payload->{"upload_command"}||"",
  get_command => $payload->{"get_command"}||"",
  keep_calibration_mode => $payload->{"keep_calibration_mode"} ? 1 : 0,
  calibration_mode_active => $payload->{"calibration_mode_active"} ? 1 : 0,
  helper_timeout => int($payload->{"helper_timeout"}||0),
  connect_timeout => 5,
 });
 &lg_update_connect_metadata($result,$clients->{"manual_ip"} || $ip) if(($result->{"status"}||"") eq "ok");
 if(&lg_picture_needs_repair($result)) {
  $result->{"message"}="The saved LG client key does not have calibration permission. Use Display -> Pair With PIN once, enter the TV PIN, then try the 3D LUT upload again.";
  $result->{"repair_hint"}="Use Display -> Pair With PIN once, then submit the PIN shown on the TV.";
 }
 return &lg_encode_json($result);
}

sub webui_lg_3d_lut_reset (@) {
 my $body=shift;
 my $payload=&lg_decode_json($body);
 my $clients=&lg_load_clients();
 ($clients,my $pin_state)=&lg_reconcile_pin_pairing($clients);
	 if(ref($pin_state) eq "HASH" && ($pin_state->{"status"}||"") eq "pending") {
	  return &lg_encode_json({ status => "error", message => "Complete LG PIN pairing before resetting the 3D LUT.", needs_repair => &lg_json_true() });
	 }
	 return &lg_encode_json({ status => "error", message => "Connect the LG TV before resetting the 3D LUT." }) if(&lg_clients_disconnected($clients));
	 my $ip=&lg_target_ip($payload,$clients);
 return &lg_encode_json({ status => "error", message => "Connect the LG TV before resetting the 3D LUT." }) if($ip eq "");
 my $client=&lg_primary_client($clients);
 my $client_key=$client->{"client_key"}||$client->{"client-key"}||"";
 return &lg_encode_json({ status => "error", message => "Connect the LG TV before resetting the 3D LUT." }) if($client_key eq "");
 my $result=&lg_helper_run({
  action => "3d_lut_reset",
  ip => $ip,
  client_key => $client_key,
  picture_mode => $payload->{"picture_mode"}||$clients->{"calibration_picture_mode"}||"",
  upload_command => $payload->{"upload_command"}||"",
  get_command => $payload->{"get_command"}||"",
  keep_calibration_mode => $payload->{"keep_calibration_mode"} ? 1 : 0,
  calibration_mode_active => $payload->{"calibration_mode_active"} ? 1 : 0,
  helper_timeout => int($payload->{"helper_timeout"}||0),
  connect_timeout => 5,
 });
 &lg_update_connect_metadata($result,$clients->{"manual_ip"} || $ip) if(($result->{"status"}||"") eq "ok");
 return &lg_encode_json($result);
}

sub webui_lg_hdr_tone_map_upload (@) {
 my $body=shift;
 my $payload=&lg_decode_json($body);
 my $peak_luminance=0+$payload->{"peak_luminance"};
 return &lg_encode_json({ status => "error", message => "HDR tone-map upload requires a measured peak luminance." }) if($peak_luminance <= 0);
 my $clients=&lg_load_clients();
 ($clients,my $pin_state)=&lg_reconcile_pin_pairing($clients);
	 if(ref($pin_state) eq "HASH" && ($pin_state->{"status"}||"") eq "pending") {
	  return &lg_encode_json({ status => "error", message => "Complete LG PIN pairing before uploading HDR tone-map data.", needs_repair => &lg_json_true() });
	 }
	 return &lg_encode_json({ status => "error", message => "Connect the LG TV before uploading HDR tone-map data." }) if(&lg_clients_disconnected($clients));
	 my $ip=&lg_target_ip($payload,$clients);
 return &lg_encode_json({ status => "error", message => "Connect the LG TV before uploading HDR tone-map data." }) if($ip eq "");
 my $client=&lg_primary_client($clients);
 my $client_key=$client->{"client_key"}||$client->{"client-key"}||"";
 return &lg_encode_json({ status => "error", message => "Connect the LG TV before uploading HDR tone-map data." }) if($client_key eq "");
 # If dpg_data is supplied, upload the 1D DPG first inside the same
 # CAL_START/CAL_END session as the tone map. Calman binds the DPG and
 # the tone map inside a single session; PGen previously uploaded them
 # in separate sessions and the tone-map roll-off did not bind against
 # the previously-uploaded 1D DPG (5-20% IRE luma collapsed ~10x in the
 # post-call PQ series read). The autocal commit path passes dpg_data
 # here so both land in one session.
 my $dpg_data=$payload->{"dpg_data"};
 if(defined $dpg_data) {
  return &lg_encode_json({ status => "error", message => "HDR20 1D DPG upload requires dpg_data." }) if(ref($dpg_data) ne "ARRAY");
  return &lg_encode_json({ status => "error", message => "HDR20 1D DPG upload requires a 3072-value (3 channels x 1024 points) uint16 array.", expected_count => 3072, received_count => scalar(@{$dpg_data}) }) if(scalar(@{$dpg_data}) != 3072);
 }
  my $result=&lg_helper_run({
   action => "hdr_tone_map_upload",
   ip => $ip,
   client_key => $client_key,
   picture_mode => $payload->{"picture_mode"}||$clients->{"calibration_picture_mode"}||"",
   peak_luminance => $peak_luminance,
   dpg_data => $dpg_data,
   ddc_layout => "hdr20",
   keep_calibration_mode => $payload->{"keep_calibration_mode"} ? 1 : 0,
   calibration_mode_active => $payload->{"calibration_mode_active"} ? 1 : 0,
   helper_timeout => int($payload->{"helper_timeout"}||0),
   connect_timeout => 5,
  });
 &lg_update_connect_metadata($result,$clients->{"manual_ip"} || $ip) if(($result->{"status"}||"") eq "ok");
 if(&lg_picture_needs_repair($result)) {
  $result->{"message"}="The saved LG client key does not have calibration permission. Use Display -> Pair With PIN once, enter the TV PIN, then try the HDR tone-map upload again.";
  $result->{"repair_hint"}="Use Display -> Pair With PIN once, then submit the PIN shown on the TV.";
 }
 return &lg_encode_json($result);
}

sub webui_lg_1d_dpg_read (@) {
 my $body=shift;
 my $payload=&lg_decode_json($body);
 my $clients=&lg_load_clients();
 ($clients,my $pin_state)=&lg_reconcile_pin_pairing($clients);
	 if(ref($pin_state) eq "HASH" && ($pin_state->{"status"}||"") eq "pending") {
	  return &lg_encode_json({ status => "error", message => "Complete LG PIN pairing before reading the HDR20 1D DPG.", needs_repair => &lg_json_true() });
	 }
	 return &lg_encode_json({ status => "error", message => "Connect the LG TV before reading the HDR20 1D DPG." }) if(&lg_clients_disconnected($clients));
	 my $ip=&lg_target_ip($payload,$clients);
 return &lg_encode_json({ status => "error", message => "Connect the LG TV before reading the HDR20 1D DPG." }) if($ip eq "");
 my $client=&lg_primary_client($clients);
 my $client_key=$client->{"client_key"}||$client->{"client-key"}||"";
 return &lg_encode_json({ status => "error", message => "Connect the LG TV before reading the HDR20 1D DPG." }) if($client_key eq "");
 my $result=&lg_helper_run({
  action => "1d_dpg_read",
  ip => $ip,
  client_key => $client_key,
  picture_mode => $payload->{"picture_mode"}||$clients->{"calibration_picture_mode"}||"",
  helper_timeout => int($payload->{"helper_timeout"}||0),
  connect_timeout => 5,
 });
 &lg_update_connect_metadata($result,$clients->{"manual_ip"} || $ip) if(($result->{"status"}||"") eq "ok");
 return &lg_encode_json($result);
}

sub webui_lg_1d_dpg_upload (@) {
 my $body=shift;
 my $payload=&lg_decode_json($body);
 my $dpg_data=$payload->{"dpg_data"};
 return &lg_encode_json({ status => "error", message => "HDR20 1D DPG upload requires dpg_data." }) if(!defined($dpg_data));
 return &lg_encode_json({ status => "error", message => "HDR20 1D DPG upload requires a 3072-value (3 channels x 1024 points) uint16 array.", expected_count => 3072, received_count => (ref($dpg_data) eq "ARRAY") ? scalar(@{$dpg_data}) : -1 }) if(ref($dpg_data) ne "ARRAY" || @{$dpg_data} != 3072);
 my @normalized=map { my $i=int($_+0); $i=0 if($i < 0); $i=65535 if($i > 65535); $i; } @{$dpg_data};
 my $clients=&lg_load_clients();
 ($clients,my $pin_state)=&lg_reconcile_pin_pairing($clients);
	 if(ref($pin_state) eq "HASH" && ($pin_state->{"status"}||"") eq "pending") {
	  return &lg_encode_json({ status => "error", message => "Complete LG PIN pairing before uploading the HDR20 1D DPG.", needs_repair => &lg_json_true() });
	 }
	 return &lg_encode_json({ status => "error", message => "Connect the LG TV before uploading the HDR20 1D DPG." }) if(&lg_clients_disconnected($clients));
	 my $ip=&lg_target_ip($payload,$clients);
 return &lg_encode_json({ status => "error", message => "Connect the LG TV before uploading the HDR20 1D DPG." }) if($ip eq "");
 my $client=&lg_primary_client($clients);
 my $client_key=$client->{"client_key"}||$client->{"client-key"}||"";
 return &lg_encode_json({ status => "error", message => "Connect the LG TV before uploading the HDR20 1D DPG." }) if($client_key eq "");
 my $result=&lg_helper_run({
  action => "1d_dpg_upload",
  ip => $ip,
  client_key => $client_key,
  picture_mode => $payload->{"picture_mode"}||$clients->{"calibration_picture_mode"}||"",
  dpg_data => \@normalized,
  helper_timeout => int($payload->{"helper_timeout"}||0),
  connect_timeout => 5,
  keep_calibration_mode => ($payload->{"keep_calibration_mode"} ? 1 : 0),
  calibration_mode_active => ($payload->{"calibration_mode_active"} ? 1 : 0),
 });
 &lg_update_connect_metadata($result,$clients->{"manual_ip"} || $ip) if(($result->{"status"}||"") eq "ok");
 if(&lg_picture_needs_repair($result)) {
  $result->{"message"}="The saved LG client key does not have calibration permission. Use Display -> Pair With PIN once, enter the TV PIN, then try the HDR20 1D DPG upload again.";
  $result->{"repair_hint"}="Use Display -> Pair With PIN once, then submit the PIN shown on the TV.";
 }
 return &lg_encode_json($result);
}

sub webui_lg_hdr_calman_reset (@) {
 my $body=shift;
 my $payload=&lg_decode_json($body);
 my $clients=&lg_load_clients();
 ($clients,my $pin_state)=&lg_reconcile_pin_pairing($clients);
	 if(ref($pin_state) eq "HASH" && ($pin_state->{"status"}||"") eq "pending") {
	  return &lg_encode_json({ status => "error", message => "Complete LG PIN pairing before resetting HDR calibration state.", needs_repair => &lg_json_true() });
	 }
	 return &lg_encode_json({ status => "error", message => "Connect the LG TV before resetting HDR calibration state." }) if(&lg_clients_disconnected($clients));
	 my $ip=&lg_target_ip($payload,$clients);
 return &lg_encode_json({ status => "error", message => "Connect the LG TV before resetting HDR calibration state." }) if($ip eq "");
 my $client=&lg_primary_client($clients);
 my $client_key=$client->{"client_key"}||$client->{"client-key"}||"";
 return &lg_encode_json({ status => "error", message => "Connect the LG TV before resetting HDR calibration state." }) if($client_key eq "");
 my $result=&lg_helper_run({
  action => "hdr_calman_reset",
  ip => $ip,
  client_key => $client_key,
  picture_mode => $payload->{"picture_mode"}||$clients->{"calibration_picture_mode"}||"",
  ddc_layout => $payload->{"ddc_layout"}||"hdr20",
  helper_timeout => int($payload->{"helper_timeout"}||0),
  connect_timeout => 5,
 });
 &lg_update_connect_metadata($result,$clients->{"manual_ip"} || $ip) if(($result->{"status"}||"") eq "ok");
 if(&lg_picture_needs_repair($result)) {
  $result->{"message"}="The saved LG client key does not have calibration permission. Use Display -> Pair With PIN once, enter the TV PIN, then try the HDR calibration reset again.";
  $result->{"repair_hint"}="Use Display -> Pair With PIN once, then submit the PIN shown on the TV.";
 }
 return &lg_encode_json($result);
}

sub webui_lg_api (@) {
 my $path=shift;
 my $method=shift;
 my $body=shift;
 if(($path eq "/api/lg/status" || $path eq "/api/lg/detect") && $method eq "GET") {
  return &webui_lg_status_json();
 }
 if($path eq "/api/lg/manual-ip" && $method eq "POST") {
  return &webui_lg_manual_ip($body);
 }
	 if($path eq "/api/lg/connect" && $method eq "POST") {
	  return &webui_lg_connect($body);
	 }
	 if($path eq "/api/lg/disconnect" && $method eq "POST") {
	  return &webui_lg_disconnect();
	 }
	 if($path eq "/api/lg/scan" && $method eq "GET") {
  return &webui_lg_scan();
 }
 if($path eq "/api/lg/calibration-mode" && $method eq "POST") {
  return &webui_lg_calibration_mode($body);
 }
 if($path eq "/api/lg/3d-lut/probe" && $method eq "POST") {
  return &webui_lg_3d_lut_probe($body);
 }
 if($path eq "/api/lg/3d-lut/upload" && $method eq "POST") {
  return &webui_lg_3d_lut_upload($body);
 }
 if($path eq "/api/lg/3d-lut/reset" && $method eq "POST") {
  return &webui_lg_3d_lut_reset($body);
 }
 if($path eq "/api/lg/hdr-tone-map/upload" && $method eq "POST") {
  return &webui_lg_hdr_tone_map_upload($body);
 }
 if($path eq "/api/lg/hdr-calman-reset" && $method eq "POST") {
  return &webui_lg_hdr_calman_reset($body);
 }
 if($path eq "/api/lg/1d-dpg/upload" && $method eq "POST") {
  return &webui_lg_1d_dpg_upload($body);
 }
 if($path eq "/api/lg/1d-dpg/read" && $method eq "POST") {
  return &webui_lg_1d_dpg_read($body);
 }
 if($path eq "/api/lg/pair-pin/start" && $method eq "POST") {
  return &webui_lg_pin_pair_start($body);
 }
 if($path eq "/api/lg/pair-pin/submit" && $method eq "POST") {
  return &webui_lg_pin_pair_submit($body);
 }
 if($path eq "/api/lg/picture-settings" && ($method eq "GET" || $method eq "POST")) {
  return &webui_lg_picture_settings($body);
 }
 if($path eq "/api/lg/picture-settings/set" && $method eq "POST") {
  return &webui_lg_picture_settings_set($body);
 }
 if($path eq "/api/lg/picture-settings/reset" && $method eq "POST") {
  return &webui_lg_picture_reset($body);
 }
 if($path eq "/api/lg/forget" && $method eq "POST") {
  return &webui_lg_forget();
 }
 return &lg_encode_json({ status => "error", message => "Unknown LG route" });
}

###############################################
#             LG Web UI Helpers               #
###############################################
sub webui_lg_card_html (@) {
 return <<'LG_CARD';
 <!-- Display -->
 <div id="lgConnectPrompt" style="display:none;position:fixed;inset:0;z-index:10000;background:rgba(0,0,0,.62);align-items:center;justify-content:center;padding:18px">
  <div style="width:min(540px,calc(100vw - 36px));background:var(--card);border:1px solid var(--border);border-radius:8px;box-shadow:0 20px 60px rgba(0,0,0,.45);padding:18px">
   <h2 style="margin:0 0 10px">LG TV detected</h2>
   <div id="lgConnectPromptText" style="font-size:.9rem;color:var(--text2);line-height:1.45;margin-bottom:12px"></div>
   <div class="field" style="margin-bottom:10px">
    <label>Found TVs</label>
    <select id="lgPromptDeviceList" size="4" style="width:100%;min-height:98px" onchange="lgUsePromptSelectedIp()">
     <option value="">Scanning...</option>
    </select>
   </div>
	   <div class="field" style="margin-bottom:12px">
	    <label>TV IP</label>
	    <input type="text" id="lgPromptManualIp" placeholder="192.168.1.x" oninput="lgPromptManualIpChanged()">
	   </div>
   <div id="lgConnectScanStatus" style="font-size:.75rem;color:var(--text2);line-height:1.35;margin-bottom:12px">Scanning the local network...</div>
   <div class="btn-row" style="justify-content:flex-end">
    <button class="btn btn-sm btn-secondary" onclick="lgScanTvs(true)">Scan Again</button>
    <button class="btn btn-sm btn-secondary" onclick="lgDismissDetectedPrompt()">Not Now</button>
    <button class="btn btn-sm btn-success" id="lgConnectPromptBtn" onclick="lgPromptConnect()">Connect</button>
   </div>
  </div>
	 </div>
	 <div class="card" data-widget="lg" draggable="true">
	  <style>
	   #lgDeviceList::-webkit-scrollbar{width:10px}
	   #lgDeviceList::-webkit-scrollbar-track{background:#0d0d15;border-radius:6px}
	   #lgDeviceList::-webkit-scrollbar-thumb{background:#2a2a3a;border-radius:999px;border:2px solid #0d0d15}
	   #lgDeviceList::-webkit-scrollbar-thumb:hover{background:#3a3a4a}
	   #lgDeviceList .lg-device-item:hover{background:#171a25!important}
	   #lgDeviceList .lg-device-item.selected{background:#10131d!important;color:#fff;box-shadow:inset 3px 0 0 var(--green)}
	   #lgCardTitle::after{margin-left:0}
	   #lgDisplayControlModal{display:none;position:fixed;inset:0;z-index:10000;background:rgba(0,0,0,.7);align-items:center;justify-content:center;padding:18px;box-sizing:border-box}
	   #lgDisplayControlPanel{width:min(920px,calc(100vw - 36px));max-height:min(760px,calc(100vh - 36px));overflow:auto;background:var(--card);border:1px solid var(--border);border-radius:8px;box-shadow:0 20px 60px rgba(0,0,0,.45);padding:16px;box-sizing:border-box;scrollbar-color:#525264 #232330;scrollbar-width:auto;scrollbar-gutter:stable}
	   #lgDisplayControlPanel::-webkit-scrollbar{width:14px;height:14px}
	   #lgDisplayControlPanel::-webkit-scrollbar-track{background:linear-gradient(90deg,#20202d 0%,#272736 100%);border-radius:999px;border:1px solid #3a3a4a}
	   #lgDisplayControlPanel::-webkit-scrollbar-thumb{background:linear-gradient(90deg,#58586c 0%,#38384a 100%);border-radius:999px;border:1px solid #6c6c82;box-shadow:inset 1px 0 0 rgba(255,255,255,.12)}
	   #lgDisplayControlPanel::-webkit-scrollbar-thumb:hover{background:linear-gradient(90deg,#67677c 0%,#434356 100%)}
	   #lgDisplayControlGrid{display:grid;grid-template-columns:repeat(auto-fit,minmax(230px,1fr));gap:10px}
	   .lg-display-control-item{border:1px solid var(--border);border-radius:6px;padding:9px;background:#10131d;min-height:74px}
	   .lg-display-control-top{display:flex;align-items:center;justify-content:space-between;gap:8px;margin-bottom:7px}
	   .lg-display-control-label{font-size:.78rem;color:var(--text);font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
	   .lg-display-control-value{font-size:.72rem;color:var(--text2);min-width:34px;text-align:right}
	   .lg-display-control-row{display:flex;align-items:center;gap:8px}
	   .lg-display-control-row input[type="range"]{flex:1;min-width:0}
	   .lg-display-control-row input[type="number"]{width:68px}
	   .lg-display-control-row select,.lg-display-control-row input[type="text"]{width:100%}
	   #lgDisplayControlPanel .lg-display-control-row select,#lgDisplayControlPanel .lg-display-control-row input[type="number"],#lgDisplayControlPanel .lg-display-control-row input[type="text"]{min-height:32px;background:#0d0d15;border:1px solid var(--border);border-radius:6px;color:var(--text);outline:none;box-sizing:border-box;color-scheme:dark}
	   #lgDisplayControlPanel .lg-display-control-row input[type="number"],#lgDisplayControlPanel .lg-display-control-row input[type="text"]{padding:6px 8px}
	   #lgDisplayControlPanel .lg-display-control-row select{padding:6px 30px 6px 8px;-webkit-appearance:none;appearance:none;cursor:pointer;background-color:#0d0d15;background-image:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='10' height='10' fill='%23888'%3E%3Cpath d='M5 7L0 2h10z'/%3E%3C/svg%3E");background-repeat:no-repeat;background-position:right 10px center}
	   #lgDisplayControlPanel .lg-display-control-row select option{background:#0d0d15;color:var(--text)}
	   #lgDisplayControlPanel .lg-display-control-row select:focus,#lgDisplayControlPanel .lg-display-control-row input[type="number"]:focus,#lgDisplayControlPanel .lg-display-control-row input[type="text"]:focus{border-color:var(--accent)}
	   #lgDisplayControlPanel .lg-display-control-row select:disabled,#lgDisplayControlPanel .lg-display-control-row input:disabled{opacity:.65;cursor:not-allowed}
	  </style>
	  <h2 id="lgCardTitle" style="gap:8px"><span class="drag-handle">&#9776;</span>Display <span id="lgStatusBadge" style="font-size:.7rem;padding:2px 8px;border-radius:4px;background:var(--text2);color:#000;margin-left:8px">Checking...</span><button class="btn btn-sm btn-secondary" id="lgDisplayControlOpenBtn" style="margin-left:auto" onclick="lgOpenDisplayControl()">Display Control</button></h2>
  <div id="lgCommandStatus" style="display:none;align-items:center;gap:8px;font-size:.78rem;color:var(--text);background:#101522;border:1px solid var(--border);border-radius:6px;padding:7px 9px;margin-bottom:8px">
   <span class="spinner"></span>
   <span id="lgCommandStatusText">Communicating with LG TV...</span>
   <span id="lgCommandElapsed" style="margin-left:auto;color:var(--text2);font-size:.72rem"></span>
  </div>
  <div id="lgStatusText" style="font-size:.8rem;color:var(--text2);line-height:1.45;margin-bottom:8px">Checking current CEC state for an LG TV...</div>
	  <div id="lgStatusMeta" style="font-size:.75rem;color:var(--text2);margin-bottom:8px"></div>
		  <div class="grid">
		   <div class="field">
		    <label>TV IP</label>
		    <input type="text" id="lgManualIp" placeholder="192.168.1.x">
		   </div>
	   <div class="field">
	    <label>Picture Mode</label>
    <select id="lgPictureMode" onchange="lgSetPictureMode()" disabled>
     <option value="">Connect display</option>
    </select>
   </div>
   <div class="field">
    <label style="display:flex;align-items:center;gap:8px;margin-top:20px">
     <input type="checkbox" id="lgCalibrationMode" onchange="lgSetCalibrationMode()" disabled>
     <span>Calibration mode</span>
    </label>
	   </div>
	  </div>
		  <div class="field" style="margin-top:8px;width:min(560px,100%)">
		   <label>Found LG TVs</label>
		   <div id="lgDeviceList" role="listbox" aria-label="Found LG TVs" style="width:100%;height:90px;max-height:90px;background:#0d0d15;border:1px solid var(--border);border-radius:6px;overflow:hidden;color:var(--text);font-size:.82rem">
		    <div style="height:30px;display:flex;align-items:center;padding:0 10px;color:var(--text2)">Scanning...</div>
		   </div>
	   <div style="display:flex;align-items:center;justify-content:space-between;gap:8px;margin-top:6px">
	    <span id="lgCardScanStatus" style="font-size:.7rem;color:var(--text2);line-height:1.3">Scanning the local network...</span>
	    <button type="button" class="btn btn-sm btn-secondary" style="padding:4px 8px;font-size:.68rem" onclick="lgScanTvs(true)">Scan</button>
	   </div>
	  </div>
	   <div class="grid" id="lgPinRow" style="display:none;margin-top:8px">
    <div class="field">
      <label>TV PIN</label>
         <input type="text" id="lgPairPin" inputmode="numeric" pattern="[0-9]*" maxlength="8" autocomplete="one-time-code" placeholder="Enter PIN shown on TV" onkeydown="lgPinKeydown(event)">
    </div>
   </div>
	  <div class="btn-row" style="margin-top:8px">
	      <button class="btn btn-sm btn-success" id="lgConnectBtn" onclick="lgConnect()">Connect</button>
	    <button class="btn btn-sm btn-secondary" id="lgDisconnectBtn" onclick="lgDisconnectClient()" disabled>Disconnect</button>
	    <button class="btn btn-sm btn-warning" id="lgPinSubmitBtn" style="display:none" onclick="lgSubmitPin()">Submit PIN</button>
   <button class="btn btn-sm btn-primary" onclick="loadLgStatus()">Refresh</button>
   <button class="btn btn-sm btn-secondary" onclick="lgSaveManualIp()">Save IP</button>
   <button class="btn btn-sm btn-danger" onclick="lgForgetClient()">Forget Pairing</button>
  </div>
    <div id="lgWorkflowHint" style="font-size:.75rem;color:var(--text2);margin-top:8px;line-height:1.45">Display detection is checking for an LG TV.</div>
 </div>
 <div id="lgDisplayControlModal" onclick="if(event.target===this) lgCloseDisplayControl()">
  <div id="lgDisplayControlPanel">
  <div style="display:flex;align-items:center;justify-content:space-between;gap:12px;margin-bottom:10px">
   <h2 style="margin:0">Display Control <span id="lgDisplayControlBadge" style="font-size:.7rem;padding:2px 8px;border-radius:4px;background:var(--text2);color:#000;margin-left:8px">Idle</span></h2>
   <button class="btn btn-sm btn-secondary" onclick="lgCloseDisplayControl()">Close</button>
  </div>
  <div id="lgDisplayControlStatus" style="font-size:.8rem;color:var(--text2);line-height:1.45;margin-bottom:8px">Connect display</div>
	  <div class="btn-row" style="margin-bottom:10px">
	   <button class="btn btn-sm btn-primary" id="lgDisplayControlRefreshBtn" onclick="lgDisplayControlRefresh(true)">Refresh Settings</button>
	   <button class="btn btn-sm btn-warning" id="lgDisplayControlResetBtn" onclick="lgResetPictureMode()" disabled>&#8634; Reset Picture Mode</button>
	  </div>
	  <div id="lgDisplayControlGrid"></div>
  </div>
 </div>
LG_CARD
}

sub webui_lg_js (@) {
 return <<'LG_JS';
let lgStatusPending=false;
let lgLastPinPending=false;
let lgDetectedPromptShown=false;
let lgPictureModePending=false;
let lgPictureModeValue='';
let lgPictureModeSignalMode='';
let lgPictureModeRefreshTimer=null;
let lgScanPending=false;
let lgCalibrationModePending=false;
window.lgStatusState=window.lgStatusState||{paired:false,connected:false,disconnected:false,detected:false,hasIp:false,checked:false,clientKeyPresent:false,pinPending:false};

function lgStatusHasSavedKey(state){
 state=state||{};
 return !!(state.clientKeyPresent||state.client_key_present||state.paired);
}

function lgStatusConnected(state){
 state=state||{};
 if(Object.prototype.hasOwnProperty.call(state,'connected')) return !!state.connected&&!state.pinPending;
 return !!(lgStatusHasSavedKey(state)&&!state.pinPending&&!state.disconnected);
}

function lgIsPGeneratorDisplayName(name){
 const normalized=String(name||'').trim().toLowerCase().replace(/[\s_-]+/g,'');
 return /^(?:pgenerator|pgeneratorplus|pgenerator\+)$/.test(normalized);
}

function lgDisplayNameFromStatus(r){
 const candidates=[
  r&&r.model_name,
  r&&r.modelName,
  r&&r.product_name,
  r&&r.productName,
  r&&r.displayName,
  r&&r.stored_name,
  r&&r.cec_osd_name,
  r&&r.cec_tv_name
 ];
 for(const candidate of candidates){
  const name=String(candidate||'').trim();
  if(name&&!lgIsPGeneratorDisplayName(name)) return name;
 }
 return 'LG TV';
}

function renderLgTopStatus(r){
 const wrap=document.getElementById('lgTopStatusWrap');
 const dot=document.getElementById('lgTopDot');
 const text=document.getElementById('lgTopStatusText');
 if(!wrap||!dot||!text) return;
 const paired=lgStatusConnected(r);
 const pinPending=!!(r&&(r.pin_pairing_pending||r.pinPending));
 if(!paired||pinPending){
  wrap.style.display='none';
  if(typeof syncTopStatusStack==='function') syncTopStatusStack();
  return;
 }
 const rawName=lgDisplayNameFromStatus(r);
 const ip=String((r&&(r.manual_ip||r.stored_ip||r.auto_ip||r.ip))||'').trim();
 const name=rawName;
 const label=name+(ip?' ['+ip+']':'');
 const power=String((r&&(r.tv_power||r.tvPower))||'').trim();
 const powerKey=power.toLowerCase();
 dot.style.background=/^(off|standby)$/.test(powerKey)?'var(--orange)':'var(--green)';
 text.textContent=label;
 text.style.color='var(--text)';
 wrap.title='Display: '+label+(power?(' | Power: '+power):'');
 wrap.style.display='flex';
 if(typeof syncTopStatusStack==='function') syncTopStatusStack();
}

const LG_PICTURE_MODES_BY_SIGNAL={
 sdr:[
  ['expert1','SDR Expert Bright'],
  ['expert2','SDR Expert Dark'],
  ['cinema','SDR Cinema'],
  ['filmMaker','SDR Filmmaker'],
  ['technicolorExpert','SDR Technicolor Expert'],
  ['game','SDR Game Optimizer'],
  ['standard','SDR Standard'],
  ['vivid','SDR Vivid']
 ],
 hdr10:[
  ['hdrCinema','HDR Cinema'],
  ['hdrFilmMaker','HDR Filmmaker'],
  ['hdrGame','HDR Game Optimizer'],
  ['hdrStandard','HDR Standard'],
  ['hdrVivid','HDR Vivid'],
  ['hdrTechnicolorExpert','HDR Technicolor Expert']
 ],
 hlg:[
  ['hdrCinema','HLG Cinema'],
  ['hdrFilmMaker','HLG Filmmaker'],
  ['hdrGame','HLG Game Optimizer'],
  ['hdrStandard','HLG Standard'],
  ['hdrVivid','HLG Vivid'],
  ['hdrTechnicolorExpert','HLG Technicolor Expert']
 ],
 dv:[
  ['dolbyVisionCinema','DV Cinema'],
  ['dolbyVisionCinemaBright','DV Cinema Home'],
  ['dolbyVisionGame','DV Game Optimizer'],
  ['dolbyVisionVivid','DV Vivid']
 ]
};

const LG_DISPLAY_CONTROL_ITEMS=[
 {key:'brightness',label:'Brightness',type:'number',min:0,max:100,step:1},
 {key:'contrast',label:'Contrast',type:'number',min:0,max:100,step:1},
 {key:'blackLevel',label:'Black Level / Range',type:'select',options:['auto','low','high','limited','full']},
 {key:'blackLevelAdjust',label:'Black Level Adjust',type:'number',min:0,max:100,step:1},
 {key:'backlight',label:'Backlight',type:'number',min:0,max:100,step:1},
 {key:'oledLight',label:'OLED Light',type:'number',min:0,max:100,step:1},
 {key:'oledPixelBrightness',label:'OLED Pixel Brightness',type:'number',min:0,max:100,step:1},
 {key:'peakBrightness',label:'Peak Brightness',type:'select',options:['off','low','medium','high']},
 {key:'color',label:'Color',type:'number',min:0,max:100,step:1},
 {key:'colorDepth',label:'Color Depth',type:'number',min:0,max:100,step:1},
 {key:'tint',label:'Tint',type:'number',min:0,max:100,step:1},
 {key:'sharpness',label:'Sharpness',type:'number',min:0,max:100,step:1},
 {key:'hSharpness',label:'H Sharpness',type:'number',min:0,max:100,step:1},
 {key:'vSharpness',label:'V Sharpness',type:'number',min:0,max:100,step:1},
 {key:'gamma',label:'Gamma',type:'select',options:['1.9','2.2','2.4','bt1886','BT.1886']},
 {key:'colorTemperature',label:'Color Temperature',type:'select',options:['cool','medium','warm','warm1','warm2','warm3','expert1','expert2']},
 {key:'colorGamut',label:'Color Gamut',type:'select',options:['auto','native','extended','wide']},
 {key:'energySaving',label:'Energy Saving',type:'select',options:['off','minimum','medium','maximum','auto','screenOff']},
 {key:'dynamicContrast',label:'Dynamic Contrast',type:'select',options:['off','low','medium','high']},
 {key:'dynamicColor',label:'Dynamic Color',type:'select',options:['off','low','medium','high']},
 {key:'localDimming',label:'Local Dimming',type:'select',options:['off','low','medium','high']},
 {key:'noiseReduction',label:'Noise Reduction',type:'select',options:['off','low','medium','high','auto']},
 {key:'mpegNoiseReduction',label:'MPEG Noise Reduction',type:'select',options:['off','low','medium','high','auto']},
 {key:'smoothGradation',label:'Smooth Gradation',type:'select',options:['off','low','medium','high']},
 {key:'superResolution',label:'Super Resolution',type:'select',options:['off','low','medium','high']},
 {key:'realCinema',label:'Real Cinema',type:'select',options:['off','on']},
 {key:'eyeComfortMode',label:'Eye Comfort Mode',type:'select',options:['off','on']},
 {key:'blackFrameInsertion',label:'Black Frame Insertion',type:'select',options:['off','low','medium','high']},
 {key:'truMotionMode',label:'TruMotion Mode',type:'select',options:['off','cinematicMovement','natural','smooth','user']},
 {key:'deJudder',label:'De-Judder',type:'number',min:0,max:10,step:1},
 {key:'deBlur',label:'De-Blur',type:'number',min:0,max:10,step:1}
];
const LG_DISPLAY_CONTROL_KEYS=LG_DISPLAY_CONTROL_ITEMS.map(item=>item.key);
let lgDisplayControlPending=false;
let lgDisplayControlValues={};
let lgDisplayControlCapabilities={supportedKeys:[],unsupportedKeys:{}};
let lgDisplayControlLoaded=false;
let lgDisplayControlError='';

function lgEscapeHtml(value){
 return String(value==null?'':value).replace(/[&<>"']/g,(ch)=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]));
}

function lgSignalModeKey(){
 const sm=String((document.getElementById('signal_mode')||{}).value||'sdr').toLowerCase();
 if(sm==='dv') return 'dv';
 if(sm==='hlg') return 'hlg';
 if(sm==='hdr10') return 'hdr10';
 return 'sdr';
}

function lgPictureModeEntries(){
 return [
  ...LG_PICTURE_MODES_BY_SIGNAL.sdr,
  ...LG_PICTURE_MODES_BY_SIGNAL.hdr10,
  ...LG_PICTURE_MODES_BY_SIGNAL.dv
 ];
}

function lgPictureModeToken(value){
 return String(value||'').trim().replace(/[\s_-]+/g,'').toLowerCase();
}

function lgPictureModeCanonicalValue(value){
 const raw=String(value||'').trim();
 if(!raw) return '';
 const exact=lgPictureModeEntries().find(item=>item[0]===raw);
 if(exact) return exact[0];
 const token=lgPictureModeToken(raw);
 const aliases={
  isfexpert1:'expert1',
  isfexpertbright:'expert1',
  expertbright:'expert1',
  isfexpert2:'expert2',
  isfexpertdark:'expert2',
  expertdark:'expert2',
  isfdarkroom:'expert2',
  isfdark:'expert2',
  darkroom:'expert2',
  brightroom:'expert1',
  technicolorexpert:'technicolorExpert',
  filmmaker:'filmMaker',
  filmmakermode:'filmMaker',
  filmlmakermode:'filmMaker',
  filmlmaker:'filmMaker',
  filmlmak:'filmMaker',
  filmlmamaker:'filmMaker',
  filmamker:'filmMaker',
  gameoptimizer:'game',
  hdrcinema:'hdrCinema',
  hdr_cinema:'hdrCinema',
  hdrfilmamker:'hdrFilmMaker',
  hdrfilmmaker:'hdrFilmMaker',
  hdr_filmmaker:'hdrFilmMaker',
  hdr_filmmakermode:'hdrFilmMaker',
  hdrfilmmakermode:'hdrFilmMaker',
  hdrgame:'hdrGame',
  hdr_game:'hdrGame',
  hdrgameoptimizer:'hdrGame',
  hdrstandard:'hdrStandard',
  hdr_standard:'hdrStandard',
  hdrvivid:'hdrVivid',
  hdr_vivid:'hdrVivid',
  hdrtechnicolorexpert:'hdrTechnicolorExpert',
  hdr_technicolorexpert:'hdrTechnicolorExpert',
  dolbyvisioncinema:'dolbyVisionCinema',
  dolby_hdr_cinema:'dolbyVisionCinema',
  dolbyvisioncinemahome:'dolbyVisionCinemaBright',
  dolbyvisioncinemabright:'dolbyVisionCinemaBright',
  dolby_hdr_cinema_bright:'dolbyVisionCinemaBright',
  dolbyhdrgame:'dolbyVisionGame',
  dolby_hdr_game:'dolbyVisionGame',
  dolbyvisiongame:'dolbyVisionGame',
  dolbyhdrgameoptimizer:'dolbyVisionGame',
  dolbyvisiongameoptimizer:'dolbyVisionGame',
  dolbyvisionvivid:'dolbyVisionVivid',
  dolbyhdrvivid:'dolbyVisionVivid',
  dolby_hdr_vivid:'dolbyVisionVivid',
  aps:'standard',
  eco:'standard',
  normal:'standard',
  sports:'vivid'
 };
 if(aliases[token]) return aliases[token];
 const normalized=lgPictureModeEntries().find(item=>lgPictureModeToken(item[0])===token);
 return normalized?normalized[0]:raw;
}

function lgPictureModeEffectiveSignal(current){
 const configured=lgSignalModeKey();
 const modeSignal=lgPictureModeSignalForValue(current||lgPictureModeValue);
 if(modeSignal==='hdr10'&&configured==='hlg') return 'hlg';
 return modeSignal||configured;
}

function lgPictureModeStorageKey(signalMode){
 return 'lgPictureMode:'+String(signalMode||lgSignalModeKey());
}

function lgPictureModeSignalForValue(value){
 const mode=lgPictureModeCanonicalValue(value);
 if(!mode) return '';
 for(const entry of Object.entries(LG_PICTURE_MODES_BY_SIGNAL)){
  const signal=entry[0];
  const modes=entry[1]||[];
  if(modes.some(item=>item[0]===mode)) return signal;
 }
 if(/^dolby_hdr_/i.test(mode)) return 'dv';
 if(/^hdr_/i.test(mode)) return 'hdr10';
 const token=lgPictureModeToken(mode);
 if(token.indexOf('dolbyhdr')===0) return 'dv';
 if(token.indexOf('hdr')===0) return 'hdr10';
 return '';
}

function lgPictureModeMatchesSignal(value,signalMode){
 const signal=signalMode||lgSignalModeKey();
 const modeSignal=lgPictureModeSignalForValue(value);
 if(!modeSignal) return false;
 if(signal==='hdr10'||signal==='hlg') return modeSignal==='hdr10'||modeSignal==='hlg';
 return modeSignal===signal;
}

function lgRememberPictureMode(value,signalMode){
 if(!value) return;
 const mode=lgPictureModeCanonicalValue(value);
 const signal=signalMode||lgPictureModeEffectiveSignal(mode);
 if(!lgPictureModeMatchesSignal(mode,signal)) return;
 try{localStorage.setItem(lgPictureModeStorageKey(signal),mode);}catch(e){}
}

function lgStoredPictureMode(signalMode){
 try{return localStorage.getItem(lgPictureModeStorageKey(signalMode))||'';}catch(e){return '';}
}

function lgPictureModeLabel(value){
 const mode=lgPictureModeCanonicalValue(value);
 const signal=lgPictureModeEffectiveSignal(mode);
 const all=[...(LG_PICTURE_MODES_BY_SIGNAL[signal]||[]),...lgPictureModeEntries()];
 const found=all.find(item=>item[0]===mode);
 if(found) return found[1];
 return mode.replace(/^hdr_/,'HDR ').replace(/^dolby_hdr_/,'Dolby Vision ').replace(/_/g,' ').replace(/([a-z])([A-Z])/g,'$1 $2').replace(/\b\w/g,ch=>ch.toUpperCase());
}

function lgPictureModeOptions(signalMode,current){
 const mode=signalMode||lgPictureModeEffectiveSignal(current);
 const options=(LG_PICTURE_MODES_BY_SIGNAL[mode]||LG_PICTURE_MODES_BY_SIGNAL.sdr).map(item=>item.slice());
 const stored=lgPictureModeCanonicalValue(lgStoredPictureMode(mode));
 const extras=[];
 if(stored&&lgPictureModeMatchesSignal(stored,mode)) extras.push(stored);
 const canonicalCurrent=lgPictureModeCanonicalValue(current);
 if(canonicalCurrent&&lgPictureModeMatchesSignal(canonicalCurrent,mode)) extras.push(canonicalCurrent);
 extras.forEach(value=>{
  if(value&&!options.some(item=>item[0]===value)) options.unshift([value,lgPictureModeLabel(value)]);
 });
 return options;
}

function lgPopulatePictureModeSelect(current){
 const select=document.getElementById('lgPictureMode');
 if(!select) return;
 const state=window.lgStatusState||{};
 const selected=lgPictureModeCanonicalValue(current);
 const signal=lgPictureModeEffectiveSignal(selected);
 const options=lgPictureModeOptions(signal,selected);
 let html='<option value="">Select mode</option>';
 options.forEach(item=>{html+='<option value="'+lgEscapeHtml(item[0])+'">'+lgEscapeHtml(item[1])+'</option>';});
 select.innerHTML=html;
 select.value=options.some(item=>item[0]===selected)?selected:'';
 select.disabled=lgPictureModePending||!lgStatusConnected(state);
}

function lgSelectedPairingMode(){
 const select=document.getElementById('lgPairingMode');
 const mode=select&&select.value?String(select.value).toUpperCase():'PIN';
 return /^(PIN|COMBINED|LGSWITCH-PIN)$/.test(mode)?mode:'PIN';
}

function lgRevealPinEntry(){
 const pinInput=document.getElementById('lgPairPin');
 const card=(pinInput&&pinInput.closest('.card'))||document.querySelector('.card[data-widget="lg"]');
 if(card&&card.classList.contains('collapsed')){
  card.classList.remove('collapsed');
  try{
   const key=card.dataset.collapseKey||card.id||card.getAttribute('data-widget');
   if(key){
    const state=JSON.parse(localStorage.getItem('cardCollapse')||'{}')||{};
    delete state[key];
    localStorage.setItem('cardCollapse',JSON.stringify(state));
   }
  }catch(e){}
 }
 if(card&&card.scrollIntoView) card.scrollIntoView({behavior:'smooth',block:'center'});
 if(pinInput){
  try{ pinInput.focus({preventScroll:true}); }catch(e){ pinInput.focus(); }
  if(pinInput.select) pinInput.select();
 }
}

function lgDetectedPromptKey(r){
 const boot=r.boot_id||'boot-unknown';
 const cec=[r.cec_tv_vendor||'',r.cec_tv_name||'',r.cec_osd_name||'',r.phys_addr||'',r.log_addr||''].join('@');
 return boot+'|'+cec;
}

function lgDetectedPromptSeenStorageKey(key){
 return 'lgDetectedPromptSeen:'+String(key||'');
}

function lgDetectedPromptWasHandled(key){
 if(!key) return false;
 try{
  if(localStorage.getItem(lgDetectedPromptSeenStorageKey(key))==='1') return true;
 }catch(e){}
 try{
  if(sessionStorage.getItem('lgDetectedPromptDismissed')===key) return true;
 }catch(e){}
 return false;
}

function lgMarkDetectedPromptHandled(r){
 const key=(typeof r==='string')?r:lgDetectedPromptKey(r||{});
 if(!key) return;
 try{localStorage.setItem(lgDetectedPromptSeenStorageKey(key),'1');}catch(e){}
 try{sessionStorage.setItem('lgDetectedPromptDismissed',key);}catch(e){}
}

function lgDismissDetectedPrompt(){
 const modal=document.getElementById('lgConnectPrompt');
 if(modal) modal.style.display='none';
 const key=(window.lgStatusState&&window.lgStatusState.promptKey)||'';
 lgMarkDetectedPromptHandled(key);
}

	function lgPromptSelectedIp(){
	 const manual=document.getElementById('lgPromptManualIp');
	 const typed=manual?manual.value.trim():'';
	 if(typed) return typed;
	 const select=document.getElementById('lgPromptDeviceList');
	 return select?String(select.value||'').trim():'';
	}

		function lgSelectedDeviceIp(selectId){
		 const el=document.getElementById(selectId);
		 if(!el) return '';
		 if(typeof el.value!=='undefined') return String(el.value||'').trim();
		 const selected=el.querySelector('[data-lg-tv-ip].selected')||el.querySelector('[data-lg-tv-ip]');
		 return selected?String(selected.getAttribute('data-lg-tv-ip')||'').trim():'';
		}

	function lgApplySelectedIp(ip){
	 ip=String(ip||'').trim();
	 if(!/^\d+\.\d+\.\d+\.\d+$/.test(ip)) return;
	 const input=document.getElementById('lgManualIp');
	 const promptInput=document.getElementById('lgPromptManualIp');
	 if(input) input.value=ip;
	 if(promptInput) promptInput.value=ip;
	}

	function lgUsePromptSelectedIp(){
	 lgApplySelectedIp(lgSelectedDeviceIp('lgPromptDeviceList')||lgPromptSelectedIp());
	}

		function lgUseCardSelectedIp(){
		 lgApplySelectedIp(lgSelectedDeviceIp('lgDeviceList'));
		}

		function lgCardDeviceClicked(ip){
		 const list=document.getElementById('lgDeviceList');
		 if(list){
		  Array.from(list.querySelectorAll('[data-lg-tv-ip]')).forEach(item=>{
		   const selected=String(item.getAttribute('data-lg-tv-ip')||'')===String(ip||'');
		   item.classList.toggle('selected',selected);
		   item.setAttribute('aria-selected',selected?'true':'false');
		   item.style.background=selected?'#10131d':'transparent';
		   item.style.boxShadow=selected?'inset 3px 0 0 var(--green)':'none';
		  });
		 }
		 lgApplySelectedIp(ip);
		}

	function lgPromptManualIpChanged(){
	 const ip=lgPromptSelectedIp();
	 lgApplySelectedIp(ip);
	}

	function lgRenderScanResults(r){
	 const promptSelect=document.getElementById('lgPromptDeviceList');
	 const cardSelect=document.getElementById('lgDeviceList');
	 const promptStatus=document.getElementById('lgConnectScanStatus');
	 const cardStatus=document.getElementById('lgCardScanStatus');
		 const setPromptSelectRows=(select,count)=>{
		  if(!select||typeof select.size==='undefined') return;
		  const rows=count>1?Math.min(4,count):1;
		  select.size=rows;
		  select.style.minHeight=(rows>1)?'92px':'';
		 };
			 const setCardListHeight=(list,count)=>{
			  if(!list) return;
			  list.style.height='90px';
			  list.style.maxHeight='90px';
			  list.style.overflowY=(count>3)?'auto':'hidden';
			  list.style.scrollbarColor='var(--border) #0d0d15';
			  list.style.scrollbarWidth='thin';
		 };
		 const devices=(r&&Array.isArray(r.devices))?r.devices:[];
		 if(!devices.length){
			  const emptyHtml='<option value="">No TVs found</option>';
			  const emptyBox='<div style="height:30px;display:flex;align-items:center;padding:0 10px;color:var(--text2)">No TVs found</div>';
			  if(promptSelect) promptSelect.innerHTML=emptyHtml;
			  if(cardSelect) cardSelect.innerHTML=emptyBox;
			  setPromptSelectRows(promptSelect,1);
			  setCardListHeight(cardSelect,1);
			  const message=(r&&r.message)||'No LG WebOS TVs were found. Enter the TV IP manually.';
	  if(promptStatus) promptStatus.textContent=message;
	  if(cardStatus) cardStatus.textContent=message;
	  return;
	 }
		 let html='';
		 let cardHtml='';
		 devices.forEach((d,idx)=>{
		  const ip=String(d.ip||'');
		  const label=String(d.label||((d.name||d.model_name||'LG WebOS TV')+' ('+ip+')'));
		  html+='<option value="'+lgEscapeHtml(ip)+'" '+(idx===0?'selected':'')+'>'+lgEscapeHtml(label)+'</option>';
		  cardHtml+='<button type="button" data-lg-tv-ip="'+lgEscapeHtml(ip)+'" role="option" aria-selected="'+(idx===0?'true':'false')+'" class="lg-device-item '+(idx===0?'selected':'')+'" onclick="lgCardDeviceClicked(\''+lgEscapeHtml(ip)+'\')" style="display:flex;align-items:center;width:100%;height:30px;min-height:30px;padding:0 10px;text-align:left;background:'+(idx===0?'#10131d':'transparent')+';box-shadow:'+(idx===0?'inset 3px 0 0 var(--green)':'none')+';border:0;border-bottom:1px solid var(--border);color:var(--text);font-size:.82rem;line-height:1.15;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;cursor:pointer">'+lgEscapeHtml(label)+'</button>';
			 });
			 if(promptSelect) promptSelect.innerHTML=html;
			 if(cardSelect) cardSelect.innerHTML=cardHtml;
			 setPromptSelectRows(promptSelect,devices.length);
			 setCardListHeight(cardSelect,devices.length);
		 if(promptStatus) promptStatus.textContent='Choose a detected TV, or enter an IP manually.';
	 if(cardStatus) cardStatus.textContent=devices.length+' LG TV'+(devices.length===1?'':'s')+' found. Click one to use its IP.';
	 const input=document.getElementById('lgManualIp');
	 const currentIp=input?String(input.value||'').trim():'';
		 if(currentIp){
		  if(promptSelect) promptSelect.value=currentIp;
		  if(cardSelect) lgCardDeviceClicked(currentIp);
		 }else{
		  lgUseCardSelectedIp();
		 }
	}

	async function lgScanTvs(force){
	 if(lgScanPending&&!force) return;
	 lgScanPending=true;
		 const promptSelect=document.getElementById('lgPromptDeviceList');
		 const cardSelect=document.getElementById('lgDeviceList');
	 const promptStatus=document.getElementById('lgConnectScanStatus');
	 const cardStatus=document.getElementById('lgCardScanStatus');
			 if(promptSelect) promptSelect.innerHTML='<option value="">Scanning...</option>';
			 if(cardSelect) {
			  cardSelect.innerHTML='<div style="height:30px;display:flex;align-items:center;padding:0 10px;color:var(--text2)">Scanning...</div>';
			  cardSelect.style.height='90px';
			  cardSelect.style.maxHeight='90px';
			  cardSelect.style.overflowY='hidden';
			 }
			 if(promptSelect) { promptSelect.size=1; promptSelect.style.minHeight=''; }
	 if(promptStatus) promptStatus.textContent='Scanning the local network for LG WebOS TVs...';
	 if(cardStatus) cardStatus.textContent='Scanning the local network for LG WebOS TVs...';
	 try{
	  const r=await fetchJSON('/api/lg/scan',{_quiet:true,_timeoutMs:12000});
	  lgRenderScanResults(r);
	 }catch(e){
		  if(promptSelect) promptSelect.innerHTML='<option value="">Scan failed</option>';
		  if(cardSelect) cardSelect.innerHTML='<div style="height:30px;display:flex;align-items:center;padding:0 10px;color:#f7b0b0">Scan failed</div>';
	  if(promptStatus) promptStatus.textContent='Scan failed. Enter the TV IP manually.';
	  if(cardStatus) cardStatus.textContent='Scan failed. Enter the TV IP manually.';
	 }finally{
	  lgScanPending=false;
	 }
}

function lgPromptConnect(){
 const modal=document.getElementById('lgConnectPrompt');
 if(modal) modal.style.display='none';
 lgDetectedPromptShown=true;
 const ip=lgPromptSelectedIp();
 const input=document.getElementById('lgManualIp');
 if(ip&&input) input.value=ip;
 lgConnect();
}

function lgMaybeShowDetectedPrompt(r){
 if(!r||r.pin_pairing_pending) return;
 if(r.paired||r.client_key_present) return;
 const detected=!!r.detected;
 const hasIp=!!(r.manual_ip||r.stored_ip||r.auto_ip);
 if(!detected||lgDetectedPromptShown) return;
 const key=lgDetectedPromptKey(r);
 if(lgDetectedPromptWasHandled(key)) return;
 const modal=document.getElementById('lgConnectPrompt');
 const text=document.getElementById('lgConnectPromptText');
 const button=document.getElementById('lgConnectPromptBtn');
 if(!modal||!text) return;
 const name=r.model_name||r.stored_name||r.cec_tv_name||(r.auto_ip?'LG WebOS TV':r.cec_osd_name)||'LG TV';
 const loc=r.phys_addr?(' on HDMI '+r.phys_addr):'';
 const ip=r.auto_ip||r.stored_ip||r.manual_ip||'';
 text.textContent=name+' detected'+loc+(ip?(' at '+ip):'')+'. Choose a TV from the scan or enter its IP.';
 if(button) button.textContent=(r.client_key_present||r.paired)?'Connect':'Pair With PIN';
 window.lgStatusState.promptKey=key;
 modal.style.display='flex';
 lgDetectedPromptShown=true;
 lgMarkDetectedPromptHandled(key);
 lgScanTvs(false);
}

function lgSchedulePictureModeRefresh(force){
 if(lgPictureModeRefreshTimer) return;
 lgPictureModeRefreshTimer=setTimeout(()=>{
  lgPictureModeRefreshTimer=null;
  lgRefreshPictureMode(!!force);
 },80);
}

function lgClearPictureModeForSignalChange(){
 lgPictureModeValue='';
 lgPictureModeSignalMode=lgSignalModeKey();
 lgDisplayControlInvalidate();
 lgPopulatePictureModeSelect('');
}

function lgRefreshPictureModeAfterOutputApply(){
 if(!lgDisplayControlConnected()) return;
 lgClearPictureModeForSignalChange();
 [250,1500,3500,6500].forEach(delay=>{
  setTimeout(()=>lgRefreshPictureMode(true),delay);
 });
}

function lgBindDisplayModeControl(){
 const signal=document.getElementById('signal_mode');
 if(signal&&!signal.dataset.lgPictureModeBound){
  signal.dataset.lgPictureModeBound='1';
  signal.addEventListener('change',()=>{
   lgClearPictureModeForSignalChange();
  });
 }
 lgPopulatePictureModeSelect(lgPictureModeValue);
}

function lgDisplayControlConnected(){
 const state=window.lgStatusState||{};
 return lgStatusConnected(state);
}

function lgSelectedPictureModeValue(){
 const select=document.getElementById('lgPictureMode');
 if(select&&select.value) return select.value;
 return lgPictureModeCanonicalValue(lgPictureModeValue);
}

function lgDisplayControlPictureMode(){
 return lgSelectedPictureModeValue();
}

function lgPictureResetButtons(){
 return ['lgPictureResetBtn','lgDisplayControlResetBtn'].map(id=>document.getElementById(id)).filter(Boolean);
}

function lgSetPictureResetButtonsDisabled(disabled){
 lgPictureResetButtons().forEach(button=>{button.disabled=!!disabled;});
}

function lgDisplayControlSetStatus(text,error){
 const status=document.getElementById('lgDisplayControlStatus');
 const badge=document.getElementById('lgDisplayControlBadge');
 if(status){
  status.textContent=text||'';
  status.style.color=error?'var(--red)':'var(--text2)';
 }
 if(badge){
  badge.textContent=lgDisplayControlPending?'Busy':(lgDisplayControlConnected()?(lgDisplayControlLoaded?'Ready':'Refresh'):'Connect');
  badge.style.background=lgDisplayControlPending?'var(--orange)':(lgDisplayControlConnected()?'var(--green)':'var(--text2)');
 }
}

function lgOpenDisplayControl(){
 const modal=document.getElementById('lgDisplayControlModal');
 if(!modal) return;
 modal.style.display='flex';
 lgDisplayControlRender();
 lgDisplayControlRefresh(false);
 if(typeof uiSyncBodyScrollLock==='function') uiSyncBodyScrollLock();
}

function lgCloseDisplayControl(){
 const modal=document.getElementById('lgDisplayControlModal');
 if(modal) modal.style.display='none';
 if(typeof uiSyncBodyScrollLock==='function') uiSyncBodyScrollLock();
}

function lgDisplayControlCurrentValue(key){
 return Object.prototype.hasOwnProperty.call(lgDisplayControlValues,key)?lgDisplayControlValues[key]:null;
}

function lgDisplayControlOptionHtml(meta,value){
 const raw=String(value==null?'':value);
 const seen={};
 let html='';
 (meta.options||[]).forEach(opt=>{
  const val=String(opt);
  seen[val]=true;
  html+='<option value="'+lgEscapeHtml(val)+'"'+(raw===val?' selected':'')+'>'+lgEscapeHtml(lgPictureModeLabel(val))+'</option>';
 });
 if(raw!==''&&!seen[raw]){
  html='<option value="'+lgEscapeHtml(raw)+'" selected>'+lgEscapeHtml(raw)+'</option>'+html;
 }
 return html;
}

function lgDisplayControlInvalidate(){
 lgDisplayControlLoaded=false;
 lgDisplayControlValues={};
 lgDisplayControlCapabilities={supportedKeys:[],unsupportedKeys:{}};
 lgDisplayControlError='';
 lgDisplayControlRender();
}

function lgDisplayControlRender(){
 const grid=document.getElementById('lgDisplayControlGrid');
 const refreshBtn=document.getElementById('lgDisplayControlRefreshBtn');
 const resetBtn=document.getElementById('lgDisplayControlResetBtn');
 if(refreshBtn) refreshBtn.disabled=lgDisplayControlPending||!lgDisplayControlConnected();
 if(resetBtn) resetBtn.disabled=lgDisplayControlPending||!lgDisplayControlConnected()||lgPictureModePending||lgCalibrationModePending;
 if(!grid) return;
 const connected=lgDisplayControlConnected();
 if(!connected){
  grid.innerHTML='';
  lgDisplayControlSetStatus('Connect display',false);
  return;
 }
 let html='';
 LG_DISPLAY_CONTROL_ITEMS.forEach(meta=>{
  const value=lgDisplayControlCurrentValue(meta.key);
  const supported=value!==null&&value!==undefined;
  const disabled=(!supported||lgDisplayControlPending)?' disabled':'';
  const displayValue=supported?String(value):'--';
  html+='<div class="lg-display-control-item" data-lg-display-control="'+lgEscapeHtml(meta.key)+'">';
  html+='<div class="lg-display-control-top"><div class="lg-display-control-label">'+lgEscapeHtml(meta.label)+'</div><div class="lg-display-control-value" id="lgDcValue_'+lgEscapeHtml(meta.key)+'">'+lgEscapeHtml(displayValue)+'</div></div>';
  html+='<div class="lg-display-control-row">';
  if(meta.type==='number'){
   const numeric=Number(value);
   const safe=Number.isFinite(numeric)?numeric:(meta.min||0);
   html+='<input type="range" id="lgDcRange_'+lgEscapeHtml(meta.key)+'" min="'+meta.min+'" max="'+meta.max+'" step="'+meta.step+'" value="'+safe+'" oninput="lgDisplayControlSyncNumber(\''+lgEscapeHtml(meta.key)+'\',this.value)" onchange="lgDisplayControlCommit(\''+lgEscapeHtml(meta.key)+'\')"'+disabled+'>';
   html+='<input type="number" id="lgDcInput_'+lgEscapeHtml(meta.key)+'" min="'+meta.min+'" max="'+meta.max+'" step="'+meta.step+'" value="'+safe+'" oninput="lgDisplayControlSyncRange(\''+lgEscapeHtml(meta.key)+'\',this.value)" onchange="lgDisplayControlCommit(\''+lgEscapeHtml(meta.key)+'\')"'+disabled+'>';
  }else{
   html+='<select id="lgDcInput_'+lgEscapeHtml(meta.key)+'" onchange="lgDisplayControlCommit(\''+lgEscapeHtml(meta.key)+'\')"'+disabled+'>'+lgDisplayControlOptionHtml(meta,value)+'</select>';
  }
  html+='</div></div>';
 });
 grid.innerHTML=html;
 lgDisplayControlSetStatus(lgDisplayControlError||(lgDisplayControlLoaded?'Picture controls loaded':'Refresh settings'),!!lgDisplayControlError);
}

function lgDisplayControlSyncNumber(key,value){
 const number=document.getElementById('lgDcInput_'+key);
 const label=document.getElementById('lgDcValue_'+key);
 if(number&&document.activeElement!==number) number.value=value;
 if(label) label.textContent=String(value);
}

function lgDisplayControlSyncRange(key,value){
 const range=document.getElementById('lgDcRange_'+key);
 const label=document.getElementById('lgDcValue_'+key);
 if(range&&document.activeElement!==range) range.value=value;
 if(label) label.textContent=String(value);
}

async function lgDisplayControlRefresh(force){
 if(lgDisplayControlPending) return;
 if(!lgDisplayControlConnected()){
  lgDisplayControlInvalidate();
  return;
 }
 if(!force&&lgDisplayControlLoaded) return;
 lgDisplayControlPending=true;
 lgDisplayControlError='';
 lgDisplayControlRender();
 try{
  const r=await fetchJSON('/api/lg/picture-settings',{
   method:'POST',
   headers:{'Content-Type':'application/json'},
   body:JSON.stringify({keys:['pictureMode',...LG_DISPLAY_CONTROL_KEYS],picture_mode:lgDisplayControlPictureMode(),ignore_calibration_picture_mode:true}),
   _quiet:true,
   _timeoutMs:18000
  });
	  if(r&&r.status==='ok'&&r.picture_settings){
	   lgDisplayControlValues=r.picture_settings||{};
	   lgDisplayControlCapabilities={
	    supportedKeys:Array.isArray(r.supported_picture_keys)?r.supported_picture_keys:[],
	    unsupportedKeys:(r.unsupported_picture_keys&&typeof r.unsupported_picture_keys==='object')?r.unsupported_picture_keys:{}
	   };
	   lgDisplayControlLoaded=true;
   lgDisplayControlError='';
   if(r.picture_settings.pictureMode){
    const mode=r.picture_settings.pictureMode;
    const signal=lgPictureModeEffectiveSignal(mode);
    lgPictureModeValue=mode;
    lgPictureModeSignalMode=signal;
    lgRememberPictureMode(mode,signal);
    lgPopulatePictureModeSelect(mode);
   }
  }else{
   lgDisplayControlError=(r&&r.message)||'Unable to read display controls';
  }
 }catch(e){
  lgDisplayControlError='Unable to read display controls';
 }finally{
  lgDisplayControlPending=false;
  lgDisplayControlRender();
 }
}

async function lgDisplayControlCommit(key){
 const meta=LG_DISPLAY_CONTROL_ITEMS.find(item=>item.key===key);
 if(!meta||!lgDisplayControlConnected()||lgDisplayControlPending) return;
 const input=document.getElementById('lgDcInput_'+key);
 if(!input) return;
 let value=meta.type==='number'?Number(input.value):input.value;
 if(meta.type==='number'){
  if(!Number.isFinite(value)) return;
  value=Math.max(Number(meta.min),Math.min(Number(meta.max),value));
 }
 const previousValue=lgDisplayControlValues[key];
 lgDisplayControlValues[key]=value;
 lgDisplayControlPending=true;
 lgDisplayControlError='';
 lgDisplayControlRender();
 const commandHandle=lgBeginCommand('Changing '+meta.label);
 let refreshAfter=false;
 try{
  const settings={};
  settings[key]=value;
  const r=await fetchJSON('/api/lg/picture-settings/set',{
   method:'POST',
   headers:{'Content-Type':'application/json'},
   body:JSON.stringify({settings:settings,picture_mode:lgDisplayControlPictureMode(),ignore_calibration_picture_mode:true,readback_keys:[key,'pictureMode']}),
   _timeoutMs:30000
  });
  if(r&&r.status==='ok'){
   const picture=r.picture_settings||{};
   lgDisplayControlValues[key]=(picture[key]!==undefined)?picture[key]:value;
   if(picture.pictureMode){
    lgPictureModeValue=picture.pictureMode;
    lgPictureModeSignalMode=lgPictureModeEffectiveSignal(lgPictureModeValue);
    lgRememberPictureMode(lgPictureModeValue,lgPictureModeSignalMode);
    lgPopulatePictureModeSelect(lgPictureModeValue);
   }
   lgDisplayControlLoaded=true;
   lgDisplayControlError='';
   toast(meta.label+' updated');
  }else{
   lgDisplayControlValues[key]=previousValue;
   toast((r&&r.message)||('Unable to update '+meta.label),'err');
   refreshAfter=true;
  }
 }catch(e){
  lgDisplayControlValues[key]=previousValue;
  toast('Unable to update '+meta.label,'err');
  refreshAfter=true;
 }finally{
  lgEndCommand(commandHandle);
  lgDisplayControlPending=false;
  if(refreshAfter) await lgDisplayControlRefresh(true);
  else lgDisplayControlRender();
 }
}

function renderLgStatus(r){
 const badge=document.getElementById('lgStatusBadge');
 const text=document.getElementById('lgStatusText');
 const meta=document.getElementById('lgStatusMeta');
 const input=document.getElementById('lgManualIp');
 const pinInput=document.getElementById('lgPairPin');
 const pairingModeSelect=document.getElementById('lgPairingMode');
 const connectBtn=document.getElementById('lgConnectBtn');
 const disconnectBtn=document.getElementById('lgDisconnectBtn');
 const pinStartBtn=document.getElementById('lgPinStartBtn');
 const pinSubmitBtn=document.getElementById('lgPinSubmitBtn');
 const resetButtons=lgPictureResetButtons();
 const pinRow=document.getElementById('lgPinRow');
 const calibrationMode=document.getElementById('lgCalibrationMode');
 const hint=document.getElementById('lgWorkflowHint');
 if(!badge||!text||!meta) return;
 const detected=!!r.detected;
 const paired=!!r.paired;
 const pinPending=!!r.pin_pairing_pending;
	 const pairingMode=r.pairing_mode||'';
	 const promptStyle=r.prompt_style||'';
	 const hasIp=!!(r.manual_ip||r.stored_ip||r.auto_ip);
	 const clientKeyPresent=!!r.client_key_present;
	 const disconnected=!!r.disconnected;
	 const connected=Object.prototype.hasOwnProperty.call(r,'connected')?!!r.connected:!!((paired||clientKeyPresent)&&!pinPending&&!disconnected);
	 const previousPaired=!!(window.lgStatusState&&window.lgStatusState.paired);
	 const promptKey=lgDetectedPromptKey(r);
	 window.lgStatusState={
		  paired:paired,
		  connected:connected,
		  disconnected:disconnected,
		  detected:detected,
	  hasIp:hasIp,
	  checked:true,
	  clientKeyPresent:clientKeyPresent,
	  pinPending:pinPending,
		  calibrationMode:!!r.calibration_mode,
		  promptKey:promptKey,
		  ip:r.manual_ip||r.stored_ip||r.auto_ip||'',
		  modelName:lgDisplayNameFromStatus(r),
		  displayName:lgDisplayNameFromStatus(r),
		  tvPower:r.tv_power||''
		 };
	 renderLgTopStatus(r);
	 if(pinPending){
    badge.textContent=promptStyle==='controller-pin'?'Enter PIN':'Pairing';
   badge.style.background='var(--orange)';
	 }else if(connected){
	    badge.textContent='Connected';
	  badge.style.background='var(--green)';
	 }else if(disconnected&&clientKeyPresent){
	    badge.textContent='Disconnected';
	  badge.style.background='var(--text2)';
	 }else if(paired||clientKeyPresent){
	    badge.textContent='Paired';
	  badge.style.background='var(--green)';
 }else if(hasIp){
    badge.textContent='Ready to Pair';
  badge.style.background='var(--orange)';
 }else if(detected){
    badge.textContent='Detected';
    badge.style.background='var(--orange)';
 }else{
    badge.textContent='Needs IP';
  badge.style.background='var(--text2)';
 }
		 if(connectBtn) connectBtn.textContent=(paired||clientKeyPresent)?'Connect':'Pair With PIN';
		 if(disconnectBtn) disconnectBtn.disabled=pinPending||!clientKeyPresent||!connected;
 const parts=[];
 if(r.cec_osd_name) parts.push('CEC OSD: '+r.cec_osd_name);
 if(r.cec_tv_vendor) parts.push('CEC TV vendor: '+r.cec_tv_vendor);
 if(r.phys_addr) parts.push('HDMI '+r.phys_addr);
 if(r.manual_ip) parts.push('Manual IP: '+r.manual_ip);
 else if(r.stored_ip) parts.push('Stored IP: '+r.stored_ip);
 else if(r.auto_ip) parts.push('Auto IP: '+r.auto_ip);
 if(r.auto_host) parts.push('Host: '+r.auto_host);
 if(r.stored_name) parts.push('TV: '+r.stored_name);
 else if(r.model_name) parts.push('Model: '+r.model_name);
 if(r.software_version) parts.push('SW: '+r.software_version);
	 if(pairingMode) parts.push('Pairing: '+pairingMode);
	 if(r.client_key_present) parts.push('Client key saved');
	 if(disconnected) parts.push('Disconnected');
    if(r.transport) parts.push('Transport: '+r.transport.toUpperCase());
 if(r.detection_source) parts.push('Detect: '+r.detection_source);
 text.textContent=r.message||'LG status unavailable';
	 meta.textContent=parts.join(' | ');
	 if(input&&document.activeElement!==input) input.value=r.manual_ip||r.stored_ip||r.auto_ip||'';
	 const activeIp=r.manual_ip||r.stored_ip||r.auto_ip||'';
		 ['lgDeviceList','lgPromptDeviceList'].forEach(id=>{
		  const el=document.getElementById(id);
		  if(!el||!activeIp) return;
		  if(typeof el.value!=='undefined') el.value=activeIp;
		  else if(id==='lgDeviceList') lgCardDeviceClicked(activeIp);
		 });
	 if(pairingModeSelect){
  if(pairingMode && pairingModeSelect.value!==pairingMode) pairingModeSelect.value=pairingMode;
  pairingModeSelect.disabled=pinPending;
 }
 if(pinRow) pinRow.style.display=pinPending?'grid':'none';
 if(pinInput){
  pinInput.disabled=!pinPending;
  if(!pinPending && document.activeElement!==pinInput) pinInput.value='';
 }
	 if(calibrationMode){
	  calibrationMode.disabled=lgCalibrationModePending||pinPending||!connected;
	  calibrationMode.checked=!!r.calibration_mode;
 }
 if(pinPending && !lgLastPinPending) lgRevealPinEntry();
	 if(pinStartBtn){
	  pinStartBtn.disabled=pinPending;
	  pinStartBtn.textContent=pinPending?'Pairing Active':'Pair With PIN';
	 }
 if(pinSubmitBtn) pinSubmitBtn.style.display=pinPending?'':'none';
	 resetButtons.forEach(button=>{button.disabled=pinPending||!connected||lgPictureModePending||lgCalibrationModePending;});
	 if(hint){
	  if(pinPending){
	   hint.textContent=promptStyle==='controller-pin'
	    ? 'Enter the PIN shown on the LG TV to finish pairing.'
	    : 'Finish the pairing prompt shown on the LG TV.';
		  }else if(disconnected&&clientKeyPresent){
		   hint.textContent='LG TV is disconnected. Connect reuses the saved key without another PIN.';
		  }else if(connected){
		   hint.textContent='Saved LG pairing is available. Connect uses the stored key without another PIN.';
	  }else if(r.auto_ip){
	   hint.textContent='LG TV auto-detected via '+(r.auto_host||'lgwebostv.local')+'.';
	  }else if(hasIp){
	   hint.textContent='LG TV IP is ready.';
	  }else{
	   hint.textContent='No LG TV IP is available yet.';
	  }
	 }
	 lgPopulatePictureModeSelect(lgPictureModeValue);
	 lgDisplayControlRender();
	 if(typeof meterUpdateSeriesTabUi==='function') meterUpdateSeriesTabUi();
	 else if(typeof meterUpdateSeriesLabels==='function') meterUpdateSeriesLabels();
	 if(typeof meterUpdateReadButtons==='function') meterUpdateReadButtons();
		 if(connected&&!pinPending) {
	  lgSchedulePictureModeRefresh(false);
	  setTimeout(()=>lgDisplayControlRefresh(false),650);
	 } else {
	  lgDisplayControlInvalidate();
	 }
	 lgMaybeShowDetectedPrompt(r);
	 lgLastPinPending=pinPending;
		 if(previousPaired!==paired && typeof meterRefreshActiveSeriesCharts==='function') meterRefreshActiveSeriesCharts();
	  else if(typeof meterLgGreySyncForCurrentStep==='function') meterLgGreySyncForCurrentStep(false);
	  if(typeof updateLgCommandBusyUi==='function') updateLgCommandBusyUi();
			}

async function loadLgStatus(quiet){
	 if(typeof lgIsCommandBusy==='function'&&lgIsCommandBusy()){
	  if(typeof updateLgCommandBusyUi==='function') updateLgCommandBusyUi();
	  return;
	 }
	 if(lgStatusPending) return;
 lgStatusPending=true;
 try{
  const r=await fetchJSON('/api/lg/status',{_quiet:!!quiet,_timeoutMs:8000});
  if(r&&r.status==='ok') renderLgStatus(r);
  else renderLgStatus({message:'LG status unavailable'});
 }catch(e){
  renderLgStatus({message:'LG status unavailable'});
 }finally{
  lgStatusPending=false;
 }
}

async function lgSaveManualIp(){
 const input=document.getElementById('lgManualIp');
 if(!input) return;
 const ip=input.value.trim();
 if(ip&&!/^\d+\.\d+\.\d+\.\d+$/.test(ip)){toast('Enter a valid LG TV IP','err');return;}
 const r=await fetchJSON('/api/lg/manual-ip',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({ip})});
 if(r&&r.status==='ok'){
  renderLgStatus(r);
  toast(ip?'LG TV IP saved':'LG TV IP cleared');
 }else{
  toast(r&&r.message?r.message:'Unable to save LG TV IP','err');
 }
}

async function lgConnect(){
 const input=document.getElementById('lgManualIp');
 const button=document.getElementById('lgConnectBtn');
	 const ip=input?input.value.trim():'';
	 const state=window.lgStatusState||{};
	 const hasSavedKey=lgStatusHasSavedKey(state);
 if(ip&&!/^\d+\.\d+\.\d+\.\d+$/.test(ip)){toast('Enter a valid LG TV IP','err');return;}
 if(!hasSavedKey){
  if(button){button.disabled=true;button.textContent='Starting Pairing...';}
  try{
   await lgStartPinPairing();
  }finally{
   if(button){button.disabled=false;button.textContent='Pair With PIN';}
  }
  return;
	 }
	 if(button){button.disabled=true;button.textContent='Connecting...';}
	 const commandHandle=lgBeginCommand('Connecting to LG TV');
	 try{
	  toast('Connecting to the LG TV with the saved key.');
  const r=await fetchJSON('/api/lg/connect',{
   method:'POST',
   headers:{'Content-Type':'application/json'},
   body:JSON.stringify({ip}),
   _timeoutMs:70000
  });
  if(r){
   renderLgStatus(r);
   if(r.status==='ok') toast(r.message||'LG TV connected');
   else toast(r.message||'Unable to connect to LG TV','err');
  }else{
   toast('Unable to connect to LG TV','err');
  }
	 }catch(e){
	  toast('Unable to connect to LG TV','err');
	 }finally{
	  lgEndCommand(commandHandle);
	  if(button){button.disabled=false;button.textContent='Connect';}
	 }
}

async function lgStartPinPairing(){
 const input=document.getElementById('lgManualIp');
 const button=document.getElementById('lgPinStartBtn');
 const ip=input?input.value.trim():'';
 const pairingMode=lgSelectedPairingMode();
	 if(ip&&!/^\d+\.\d+\.\d+\.\d+$/.test(ip)){toast('Enter a valid LG TV IP','err');return;}
	 if(button){button.disabled=true;button.textContent='Starting Pairing...';}
	 const commandHandle=lgBeginCommand('Starting LG PIN pairing');
	 try{
	   toast('Starting LG PIN pairing. Watch the TV for a PIN.');
  const r=await fetchJSON('/api/lg/pair-pin/start',{
   method:'POST',
   headers:{'Content-Type':'application/json'},
    body:JSON.stringify({ip,pairing_mode:pairingMode}),
   _timeoutMs:15000
  });
  if(r){
   renderLgStatus(r);
   if(r.status==='ok') {
      toast(r.message||'LG TV pairing started');
    if(r.pin_pairing_pending) lgRevealPinEntry();
   }
    else toast(r.message||'Unable to start LG TV pairing','err');
  }else{
    toast('Unable to start LG TV pairing','err');
  }
	 }catch(e){
	   toast('Unable to start LG TV pairing','err');
	 }finally{
	   lgEndCommand(commandHandle);
	   if(button){
    button.disabled=false;
    const badge=document.getElementById('lgStatusBadge');
    const badgeText=badge?badge.textContent:'';
	    button.textContent=(badgeText==='Enter PIN'||badgeText==='Pairing')?'Pairing Active':'Pair With PIN';
   }
 }
}

async function lgSubmitPin(){
 const pinInput=document.getElementById('lgPairPin');
 const button=document.getElementById('lgPinSubmitBtn');
	 const pin=pinInput?pinInput.value.replace(/\D+/g,''):'';
	 if(!/^\d{4,8}$/.test(pin)){toast('Enter the numeric PIN shown on the TV','err');return;}
	 if(button){button.disabled=true;button.textContent='Submitting PIN...';}
	 const commandHandle=lgBeginCommand('Submitting LG TV PIN');
	 try{
  const r=await fetchJSON('/api/lg/pair-pin/submit',{
   method:'POST',
   headers:{'Content-Type':'application/json'},
   body:JSON.stringify({pin}),
   _timeoutMs:70000
  });
  if(r){
   renderLgStatus(r);
   if(r.status==='ok') toast(r.message||'LG TV paired using PIN');
   else toast(r.message||'Unable to complete LG PIN pairing','err');
  }else{
   toast('Unable to complete LG PIN pairing','err');
  }
	 }catch(e){
	  toast('Unable to complete LG PIN pairing','err');
	 }finally{
	  lgEndCommand(commandHandle);
	  if(button){button.disabled=false;button.textContent='Submit PIN';}
	 }
}

function lgPinKeydown(event){
 if(!event||event.key!=='Enter') return;
 event.preventDefault();
 lgSubmitPin();
}

async function lgRefreshPictureMode(force){
 const state=window.lgStatusState||{};
 let signal=lgPictureModeEffectiveSignal(lgPictureModeValue);
			 if(!lgStatusConnected(state)){
		  lgPictureModeValue='';
		  lgPictureModeSignalMode=signal;
		  lgPopulatePictureModeSelect('');
		  lgDisplayControlInvalidate();
		  return;
		 }
	 if(typeof lgIsCommandBusy==='function'&&lgIsCommandBusy()) return;
	 if(lgPictureModePending) return;
 if(!force&&lgPictureModeValue&&lgPictureModeSignalMode===signal){
  lgPopulatePictureModeSelect(lgPictureModeValue);
  return;
 }
 lgPictureModePending=true;
 lgPopulatePictureModeSelect(lgPictureModeValue);
 try{
  const r=await fetchJSON('/api/lg/picture-settings',{
   method:'POST',
   headers:{'Content-Type':'application/json'},
   body:JSON.stringify({keys:['pictureMode'],picture_mode:'',ignore_calibration_picture_mode:true}),
   _quiet:true,
   _timeoutMs:9000
  });
  if(r&&r.status==='ok'&&r.picture_settings){
   const mode=r.picture_settings.pictureMode||'';
   signal=lgPictureModeEffectiveSignal(mode);
   lgPictureModeValue=mode;
   lgPictureModeSignalMode=signal;
   if(mode){
    lgRememberPictureMode(mode,signal);
    lgDisplayControlInvalidate();
    setTimeout(()=>lgDisplayControlRefresh(true),650);
   }
	  }
 }catch(e){
	 }finally{
	  lgPictureModePending=false;
	  lgPopulatePictureModeSelect(lgPictureModeValue);
	  lgDisplayControlRender();
	 }
}

async function lgSetPictureMode(){
 const select=document.getElementById('lgPictureMode');
 if(!select) return;
 const value=select.value||'';
 if(!value) return;
 const state=window.lgStatusState||{};
 const signal=lgPictureModeEffectiveSignal(value);
 lgRememberPictureMode(value,signal);
	 if(!lgStatusConnected(state)){
  toast('Connect the LG TV first','err');
  lgPopulatePictureModeSelect(lgPictureModeValue);
  return;
	 }
	 lgPictureModePending=true;
	 select.disabled=true;
	 const commandHandle=lgBeginCommand('Changing LG picture mode');
	 try{
  const r=await fetchJSON('/api/lg/picture-settings/set',{
   method:'POST',
   headers:{'Content-Type':'application/json'},
   body:JSON.stringify({settings:{pictureMode:value},picture_mode:value,signal_mode:lgSignalModeKey(),readback_keys:['pictureMode']}),
   _timeoutMs:15000
  });
  if(r&&r.status==='ok'){
   const mode=(r.picture_settings&&r.picture_settings.pictureMode)||value;
   lgPictureModeValue=mode;
   lgPictureModeSignalMode=signal;
   lgRememberPictureMode(mode,signal);
   toast('LG picture mode set to '+lgPictureModeLabel(mode));
	   if(typeof meterLgGreySyncForCurrentStep==='function'){
	    try{meterLgGreyState={status:'idle',picture:null,message:'',needsRepair:false};}catch(e){}
	    meterLgGreySyncForCurrentStep(true);
	   }
	   lgDisplayControlInvalidate();
	   lgDisplayControlRefresh(true);
	  }else{
   toast(r&&r.message?r.message:'Unable to change LG picture mode','err');
  }
	 }catch(e){
	  toast('Unable to change LG picture mode','err');
	 }finally{
	  lgEndCommand(commandHandle);
	  lgPictureModePending=false;
	 lgPopulatePictureModeSelect(lgPictureModeValue);
 }
}

async function lgResetPictureMode(){
 const state=window.lgStatusState||{};
	 if(!lgStatusConnected(state)){
  toast('Connect the LG TV first','err');
  return;
	 }
	 const signal=lgSignalModeKey();
	 const mode=lgSelectedPictureModeValue();
	 if(!mode){
	  toast('Select the LG picture mode before resetting picture settings','err');
	  return;
 }
 const label=mode?lgPictureModeLabel(mode):'the active mode';
 if(!confirm('Reset '+label+' picture settings? This resets the mode before calibration.')) return;
 lgSetPictureResetButtonsDisabled(true);
 const commandHandle=lgBeginCommand('Resetting LG picture mode');
 try{
  const r=await fetchJSON('/api/lg/picture-settings/reset',{
   method:'POST',
   headers:{'Content-Type':'application/json'},
   body:JSON.stringify({picture_mode:mode,signal_mode:signal,require_white_balance_reset:false}),
   _timeoutMs:90000
  });
  if(r&&r.status==='ok'){
   toast(r.message||'LG picture mode reset complete');
   if(r.active_picture_mode){
    lgPictureModeValue=r.active_picture_mode;
    lgPictureModeSignalMode=lgPictureModeEffectiveSignal(r.active_picture_mode);
    lgRememberPictureMode(r.active_picture_mode,lgPictureModeSignalMode);
   }
	   if(typeof meterLgGreySyncForCurrentStep==='function'){
	    try{meterLgGreyState={status:'idle',picture:null,message:'',needsRepair:false};}catch(e){}
	    meterLgGreySyncForCurrentStep(true);
	   }
	   lgRefreshPictureMode(true);
	   lgDisplayControlInvalidate();
	   lgDisplayControlRefresh(true);
	  }else{
   toast(r&&r.message?r.message:'Unable to reset LG picture mode','err');
  }
 }catch(e){
  toast('Unable to reset LG picture mode','err');
 }finally{
  lgEndCommand(commandHandle);
  await loadLgStatus(true);
  lgDisplayControlRender();
 }
}

async function lgSetCalibrationMode(){
 const checkbox=document.getElementById('lgCalibrationMode');
 if(!checkbox) return;
 const enabled=!!checkbox.checked;
 const state=window.lgStatusState||{};
	 if(!lgStatusConnected(state)){
  checkbox.checked=!enabled;
  toast('Connect the LG TV first','err');
  return;
	 }
	 lgCalibrationModePending=true;
	 checkbox.disabled=true;
	 const commandHandle=lgBeginCommand(enabled?'Enabling LG calibration mode':'Disabling LG calibration mode');
	 try{
  const r=await fetchJSON('/api/lg/calibration-mode',{
   method:'POST',
   headers:{'Content-Type':'application/json'},
   body:JSON.stringify({enabled,picture_mode:lgSelectedPictureModeValue()||''}),
   _timeoutMs:18000
  });
  if(r&&r.status==='ok'){
   renderLgStatus(r);
   toast(enabled?'LG calibration mode enabled':'LG calibration mode disabled');
  }else{
   checkbox.checked=!enabled;
   toast(r&&r.message?r.message:'Unable to change LG calibration mode','err');
   loadLgStatus(true);
  }
	 }catch(e){
	  checkbox.checked=!enabled;
	  toast('Unable to change LG calibration mode','err');
	  loadLgStatus(true);
	 }finally{
	  lgEndCommand(commandHandle);
	  lgCalibrationModePending=false;
  const fresh=window.lgStatusState||{};
	  checkbox.disabled=!lgStatusConnected(fresh)||!!fresh.pinPending;
 }
}

async function lgForgetClient(){
 const r=await fetchJSON('/api/lg/forget',{method:'POST'});
 if(r&&r.status==='ok'){
	  lgPictureModeValue='';
	  lgPictureModeSignalMode='';
  lgDisplayControlInvalidate();
	  lgMarkDetectedPromptHandled(r);
  renderLgStatus(r);
  toast('Stored LG pairing cleared');
 }else{
  toast(r&&r.message?r.message:'Unable to clear LG pairing','err');
 }
}

async function lgDisconnectClient(){
 const button=document.getElementById('lgDisconnectBtn');
 if(button) button.disabled=true;
 try{
  const r=await fetchJSON('/api/lg/disconnect',{method:'POST'});
  if(r&&r.status==='ok'){
   lgPictureModeValue='';
   lgPictureModeSignalMode='';
   lgDisplayControlInvalidate();
   renderLgStatus(r);
   toast('LG TV disconnected; pairing saved');
  }else{
   toast(r&&r.message?r.message:'Unable to disconnect LG TV','err');
  }
 }catch(e){
  toast('Unable to disconnect LG TV','err');
 }finally{
  const fresh=window.lgStatusState||{};
  if(button) button.disabled=!lgStatusConnected(fresh)||!lgStatusHasSavedKey(fresh)||!!fresh.pinPending;
 }
}
LG_JS
}

sub webui_lg_load_info_js (@) {
 return 'lgBindDisplayModeControl();lgDisplayControlRender();loadLgStatus(true);';
}

sub webui_lg_init_js (@) {
 return 'lgBindDisplayModeControl();lgDisplayControlRender();setTimeout(()=>loadLgStatus(),750);setTimeout(()=>lgScanTvs(false),1200);';
}

return 1;
