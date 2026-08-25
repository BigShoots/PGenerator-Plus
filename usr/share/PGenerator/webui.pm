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
use Fcntl qw(O_NONBLOCK O_WRONLY);
use Time::HiRes ();
# Required for the ":shared" attributes and lock() below: webui_http dispatches
# requests to a worker thread pool, so the cross-call state at this file scope
# has to be genuinely shared rather than silently cloned per thread.
use threads;
use threads::shared;
use Thread::Queue;
# POSIX::dup / POSIX::close: the accept thread hands workers a raw duplicated
# fd, because an IO::Socket object cannot cross an ithread boundary.
use POSIX ();
# Explicit rather than relying on another module in the process having loaded
# them: Socket::MSG_PEEK for the accept thread's non-consuming readiness peek,
# IO::Select for the bounded read deadlines, Errno for %! on non-blocking reads.
use Socket ();
use IO::Select ();
use Errno ();
 
###############################################
#             mDNS Route Helpers              #
###############################################
sub webui_mdns_iface_ip (@) {
 my $iface=shift;
 my $addr_out="";
 my $fallback="";
 return "" if(!defined($iface) || $iface eq "");
 $addr_out=`ip -o -4 addr show dev $iface scope global 2>/dev/null`;
 foreach my $line (split(/\n/,$addr_out)) {
  next unless($line =~ /^\d+:\s+\S+\s+inet\s+(\d+\.\d+\.\d+\.\d+)\/\d+/);
  my $ip=$1;
  return $ip if($line !~ /\bsecondary\b/);
  $fallback=$ip if($fallback eq "");
 }
 return $fallback;
}

sub webui_mdns_routes (@) {
 my @routes;
 my %seen;
 my $route_out=`ip -o -4 route show scope link 2>/dev/null`;
 foreach my $line (split(/\n/,$route_out)) {
  next if($line =~ /\blinkdown\b/);
  if($line =~ /^(\d+\.\d+\.\d+\.\d+)\/(\d+)\s+dev\s+(\S+).*?\bsrc\s+(\d+\.\d+\.\d+\.\d+)/) {
    my $network=$1;
    my $prefix=int($2);
    my $iface=$3;
    my $ip=&webui_mdns_iface_ip($iface);
    $ip=$4 if($ip eq "");
    my $ifindex=&read_from_file("/sys/class/net/$iface/ifindex");
  $ifindex=~s/\s+//g;
  $ifindex=int($ifindex||0);
    my $key="$network/$prefix:".(($ifindex > 0) ? "ifindex:$ifindex" : "iface:$iface");
    next if($seen{$key}++);
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

sub webui_mdns_build_a_response (@) {
 my $mdns_hostname=shift;
 my $best_ip=shift;
 return "" if($mdns_hostname eq "" || $best_ip eq "");
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
 return $resp;
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
 my %mdns_joined; # key="ifindex:<n>" or "iface:<name>" value=route hashref
 my $mdns_join_time=0;

 my $mdns_route_key=sub {
  my $route=shift;
  return "ifindex:$route->{ifindex}" if(int($route->{ifindex} || 0) > 0);
  return "iface:$route->{iface}";
 };

 my $mdns_drop=sub {
  my $route=shift;
  return if(!defined($route) || ref($route) ne "HASH");
  return if(!defined($route->{ip}) || $route->{ip} eq "");
  if(int($route->{ifindex} || 0) > 0) {
   my $mreqn=pack("a4 a4 i",Socket::inet_aton($MDNS_ADDR),pack("N",0),int($route->{ifindex}));
   setsockopt($sock, $IPPROTO_IP, $IP_DROP_MEMBERSHIP, $mreqn);
  }
  my $mreq=Socket::inet_aton($MDNS_ADDR) . Socket::inet_aton($route->{ip});
  setsockopt($sock, $IPPROTO_IP, $IP_DROP_MEMBERSHIP, $mreq);
 };

 my $mdns_rejoin=sub {
  my @routes=&webui_mdns_routes();
  my %current;
  foreach my $route (@routes) {
   my $key=$mdns_route_key->($route);
   $current{$key}=1;
   if($mdns_joined{$key}) {
    next if($mdns_joined{$key}->{ip} eq $route->{ip});
    $mdns_drop->($mdns_joined{$key});
    delete $mdns_joined{$key};
   }
   my $joined=0;
   my $already_joined=0;
   my $join_error="";
   if($route->{ifindex} > 0) {
    my $mreqn=pack("a4 a4 i",Socket::inet_aton($MDNS_ADDR),pack("N",0),$route->{ifindex});
    $joined=setsockopt($sock, $IPPROTO_IP, $IP_ADD_MEMBERSHIP, $mreqn) ? 1 : 0;
    $join_error="$!" if(!$joined);
   }
   if(!$joined) {
    my $mreq = Socket::inet_aton($MDNS_ADDR) . Socket::inet_aton($route->{ip});
    $joined=setsockopt($sock, $IPPROTO_IP, $IP_ADD_MEMBERSHIP, $mreq) ? 1 : 0;
    $join_error="$!" if(!$joined);
   }
   if(!$joined && $join_error=~/Address already in use/i) {
    $joined=1;
    $already_joined=1;
   }
    if($joined) {
     $mdns_joined{$key}={ %$route };
     &log("mDNS: joined multicast on $route->{iface} ($route->{ip})");
     my $announce=&webui_mdns_build_a_response($mdns_hostname,$route->{ip});
     if(!$already_joined && $announce ne "") {
      my $IP_MULTICAST_IF=eval { Socket::IP_MULTICAST_IF() } || 32;
      setsockopt($sock, $IPPROTO_IP, $IP_MULTICAST_IF, Socket::inet_aton($route->{ip}));
      my $mcast_dest=Socket::sockaddr_in($MDNS_PORT, Socket::inet_aton($MDNS_ADDR));
      send($sock, $announce, 0, $mcast_dest);
      &log("mDNS: announced $mdns_hostname.local -> $route->{ip}");
     }
    } else {
     &log("mDNS: multicast join failed on $route->{iface} ($route->{ip}): $join_error");
    }
    }
    # Drop stale memberships for interfaces that disappeared
    foreach my $key (keys %mdns_joined) {
    next if($current{$key});
    $mdns_drop->($mdns_joined{$key});
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

  my $resp=&webui_mdns_build_a_response($mdns_hostname,$best_ip);
  next if($resp eq "");

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
# THREAD LOCALITY (webui_http now dispatches to a worker pool).
#
# Every "my" variable at this file scope is cloned into each ithread, so a
# per-worker PRIVATE copy is what you get unless it is explicitly :shared.
# The triage rule used below:
#   - Pure result cache  -> a private copy only costs hit rate. The work is
#                           still correct, just repeated. Left unshared.
#   - Cross-call accumulator, once-only latch, or rate limiter for a side
#     effect -> a private copy is a CORRECTNESS bug (deltas computed against
#     a stale baseline, latches firing once per worker, throttles firing N
#     times per window). These are :shared.
my $_info_cache="";
my $_info_cache_time=0;
my $_INFO_CACHE_TTL=5;

my $_cec_cache="";
my $_cec_cache_time=0;
my $_CEC_CACHE_TTL=30;
# Throttle for live TV power queries from the status path. The single-threaded
# webui must not pay a CEC power query (~500ms worst case when the TV is off)
# on every poll, so we do at most one live query per this many seconds and
# serve the cached reading in between.
# :shared - this is a RATE LIMITER for a side effect (spawning pgcec against
# the single /dev/cec0 adapter), not a cache. A private copy per worker would
# multiply the live query rate by the pool size and silently undo a6d6b029.
my $_cec_last_power_query :shared = 0;
# 15s, not 4s: with the TV powered OFF a live power query costs the
# single-threaded daemon ~2s of wall time (pgcec tries first and gives
# nothing, then pgenerator-cec's GIVE_DEVICE_POWER_STATUS hangs until
# the outer timeout kills it). At a 4s throttle that was ~50-100% of
# the request loop consumed by CEC spawns whenever any status endpoint
# was polled -- the WebUI starved and looked "down" with the TV off.
my $_CEC_POWER_QUERY_THROTTLE=15;

# :shared - these two are caches, but they are EXPLICITLY INVALIDATED after a
# mode-changing apply (webui_apply_config clears them so the UI stops serving
# a pre-apply EDID/mode snapshot). A private copy per worker would mean the
# invalidation only cleared the applying worker's copy and the other workers
# kept serving the stale snapshot for the rest of the TTL.
my $_caps_cache :shared = "";
my $_caps_cache_time :shared = 0;
my $_modes_cache :shared = "";
my $_modes_cache_time :shared = 0;
my $_MODES_CACHE_TTL=30;
# Pure result cache, 2s TTL: a private copy per worker only costs hit rate.
my $_stats_cache="";
my $_stats_cache_time=0;
my $_STATS_CACHE_TTL=2;
# :shared - CPU% is a DELTA against the previous /api/stats call. Private
# baselines per worker make every delta span a different, staler interval and
# the reported percentage becomes erratic. One baseline for the whole pool.
my $_stats_cpu_total :shared = 0;
my $_stats_cpu_idle :shared = 0;
my $_stats_cpu_last :shared = 0;

# Meter state
our $_meter_series_file="/tmp/meter_series.json";
my $_meter_lg_autocal_file="/tmp/meter_lg_autocal.json";
my $_meter_lg_autocal_config_file="/tmp/meter_lg_autocal_config.json";
my $_meter_lg_autocal_stop_file="/tmp/meter_lg_autocal.stop";
my $_meter_lg_autocal_log_file="/tmp/meter_lg_autocal.log";
my $_meter_lg_3d_autocal_file="/tmp/meter_lg_3d_autocal.json";
my $_meter_lg_3d_autocal_config_file="/tmp/meter_lg_3d_autocal_config.json";
# Package-visible (not my) so tests can point the exact-LUT whitelist at a
# temp directory and execute the retry/recovery endpoints for real.
our $_meter_lg_3d_autocal_luts_dir="/var/lib/PGenerator/lg/luts";
my $_meter_lg_3d_autocal_stop_file="/tmp/meter_lg_3d_autocal.stop";
my $_meter_lg_3d_autocal_log_file="/tmp/meter_lg_3d_autocal.log";
my $_meter_lg_3d_autocal_start_lock :shared = 0;
my $_meter_wrapper="/usr/bin/spotread_wrapper.sh";
my $_meter_session="/usr/bin/meter_session.sh";
our $_meter_read_file="/tmp/meter_read.json";
my $_meter_session_pid_file="/tmp/meter_session.pid";
my $_meter_session_fifo="/tmp/meter_session.cmd";
my $_meter_session_config_file="/tmp/meter_session.config";
my $_meter_session_ready_file="/tmp/meter_session_ready.signal";
my $_meter_session_start_ready_file="/tmp/meter_session_start_ready.signal";
my $_meter_session_ack_file="/tmp/meter_session.ack";
my $_meter_diagnostic_read_lock="/tmp/meter_diagnostic_read.lock";
my $_meter_series_ready_glob="/tmp/meter_series_ready_*.signal";
my $_meter_series_stop_glob="/tmp/meter_series_stop_*.signal";
my $_webui_pattern_stop_guard_file="/tmp/webui_pattern_stop_guard";
my $_ccss_create_state_file="/tmp/ccss_create.json";
my $_ccss_create_pid_file="/tmp/ccss_create.pid";
my $_ccss_create_log_file="/tmp/ccss_create.log";
my $_ccss_create_continue_file="/tmp/ccss_create.cont";
my $_ccss_create_runner="/usr/bin/ccss_create.py";
my $_ccss_create_patch_cmd="/usr/bin/ccss_create_patch.sh";
my $_ccss_create_ccxxmake_bin="/usr/bin/ccxxmake_interactive";
our $_icc_profile_builder="/usr/bin/icc_profile_builder.py";
our $_icc_profile_dir="$var_dir/icc";
our $_icc_companion_packager="/usr/bin/icc_companion_package.py";
our $_icc_companion_lut_builder="/usr/bin/icc_companion_lut.py";
our $_icc_companion_dir="$var_dir/icc-companion";
our $_icc_companion_token_file="$_icc_companion_dir/pairing.token";
our $_icc_companion_command_file="$_icc_companion_dir/command.json";
our $_icc_companion_settings_file="$_icc_companion_dir/display.json";
# colprof offload: the ICC builder drops a job here and waits for result.icc.
# The Companion collects the job through its existing poll and posts the built
# profile back, so no new transport is involved.
our $_icc_companion_build_dir="$_icc_companion_dir/build";
our $_icc_companion_build_job="$_icc_companion_build_dir/job.json";
our $_icc_companion_build_ti3="$_icc_companion_build_dir/job.ti3";
our $_icc_companion_build_input="$_icc_companion_build_dir/job.input";
our $_icc_companion_build_result="$_icc_companion_build_dir/result.icc";
our $_icc_companion_build_error="$_icc_companion_build_dir/error.txt";
our $_icc_companion_build_claim="$_icc_companion_build_dir/claim.json";
our $_icc_companion_build_state="$_icc_companion_build_dir/companion.json";
our $_icc_companion_install_dir="$_icc_companion_dir/install";
our $_icc_companion_install_job="$_icc_companion_install_dir/job.json";
our $_icc_companion_install_status="$_icc_companion_install_dir/status.json";
our $_icc_companion_ack_file="/tmp/pgen_icc_companion.ack.json";
our $_icc_companion_status_file="/tmp/pgen_icc_companion.status.json";
# Pairing handshake for a Companion that arrived from the public GitHub
# release rather than the paired-download packager: it has no token yet, so it
# asks here, a human approves it in the WebUI, and only then does it get one.
our $_icc_companion_pairing_file="$_icc_companion_dir/pairing.requests.json";
# :shared - guards the pairing store's read-modify-write cycle. It is a list,
# not a single last-write-wins value like the other Companion state files, so
# two fast-lane workers racing a load against a save could silently drop
# whichever request lost the race instead of just going stale for one poll.
our $_icc_pairing_lock :shared = 0;
my $_system_backup_helper="/usr/bin/pgenerator_system_backup.py";
my $_system_backup_upload_dir="/tmp/pgenerator-system-backup-import";
my $_system_backup_max_bytes=512*1024*1024;
my $_icc_module_path=__FILE__;
$_icc_module_path=~s{webui\.pm\z}{PGICCProfile.pm};
$_icc_module_path="/usr/share/PGenerator/PGICCProfile.pm" unless(-f $_icc_module_path);
require $_icc_module_path;
# :shared - 0.25s debounce guarding a PHYSICAL meter read (see the check in
# webui_meter_read). A private copy per worker would let one read per worker
# through each window instead of one read total.
my $_meter_last_read_time :shared = 0;
my $_ccss_dir="/usr/share/PGenerator/ccss";
my $_custom_ccss_dir="$var_dir/ccss/custom";

sub webui_prepare_tmp_worker_log (@) {
 my ($preferred,$prefix)=@_;
 $preferred||="";
 $prefix||="meter_worker";
 if($preferred=~m{^/tmp/[A-Za-z0-9_.-]+$} && open(my $fh,">",$preferred)) {
  close($fh);
  chmod(0666,$preferred);
  return $preferred;
 }
 $prefix=~s/[^A-Za-z0-9_.-]/_/g;
 my $fallback="/tmp/".$prefix."_".time()."_".$$.".log";
 if(open(my $fh,">",$fallback)) {
  close($fh);
  chmod(0666,$fallback);
  return $fallback;
 }
 return "/dev/null";
}
my $_custom_ccss_legacy_dir="$_ccss_dir/custom";

# Display technology map: key => [spotread_y_flag, ccss_filename]
my $_dtype_info={
 "non_refresh"  => ["l",""],
 "refresh"      => ["c",""],
 "lcd"          => ["l",""],
 "oled"         => ["c",""],
 "projector"    => ["p",""],
 "oled_generic" => ["c","WRGB_OLED_LG.ccss"],
 "qdoled"       => ["c","QD-OLED_Generic.ccss"],
 "amoled"       => ["l","AMOLED_Generic.ccss"],
 "lcd_wled"     => ["l","WLEDFamily_07Feb11.ccss"],
 "lcd_wled_ips" => ["l","WLEDFamily_07Feb11.ccss"],
 "lcd_wled_pva" => ["l","WLEDFamily_07Feb11.ccss"],
 "lcd_wled_tft" => ["l","WLEDFamily_07Feb11.ccss"],
 "lcd_ccfl"     => ["l","CCFLFamily_07Feb11.ccss"],
 "lcd_ccfl_ips" => ["l","CCFLFamily_07Feb11.ccss"],
 "lcd_ccfl_pva" => ["l","CCFLFamily_07Feb11.ccss"],
 "lcd_ccfl_tft" => ["l","CCFLFamily_07Feb11.ccss"],
 "lcd_wgccfl"   => ["l","WGCCFLFamily_07Feb11.ccss"],
 "lcd_wgccfl_ips"=>["l","WGCCFLFamily_07Feb11.ccss"],
 "lcd_wgccfl_pva"=>["l","WGCCFLFamily_07Feb11.ccss"],
 "lcd_wgccfl_tft"=>["l","WGCCFLFamily_07Feb11.ccss"],
 "lcd_rgbled"   => ["l","RGBLEDFamily_07Feb11.ccss"],
 "lcd_rgbled_ips"=>["l","RGBLEDFamily_07Feb11.ccss"],
 "lcd_rgbled_pva"=>["l","RGBLEDFamily_07Feb11.ccss"],
 "lcd_rgbled_tft"=>["l","RGBLEDFamily_07Feb11.ccss"],
 "lcd_rgphosphor"=>["l","RG_Phosphor_-_Konica_Minolta_CS-1000_5nm.ccss"],
 "lcd_rgphosphor_ips"=>["l","RG_Phosphor_-_Konica_Minolta_CS-1000_5nm.ccss"],
 "lcd_rgphosphor_pva"=>["l","RG_Phosphor_-_Konica_Minolta_CS-1000_5nm.ccss"],
 "lcd_rgphosphor_tft"=>["l","RG_Phosphor_-_Konica_Minolta_CS-1000_5nm.ccss"],
 "lcd_pfsphosphor"=>["l","PFS_Phosphor_-_Konica_Minolta_CS-1000_5nm.ccss"],
 "lcd_pfsphosphor_ips"=>["l","PFS_Phosphor_-_Konica_Minolta_CS-1000_5nm.ccss"],
 "lcd_pfsphosphor_pva"=>["l","PFS_Phosphor_-_Konica_Minolta_CS-1000_5nm.ccss"],
 "lcd_pfsphosphor_tft"=>["l","PFS_Phosphor_-_Konica_Minolta_CS-1000_5nm.ccss"],
 "lcd_gbled"    => ["l","RG_Phosphor_-_Konica_Minolta_CS-1000_5nm.ccss"],
 "lcd_gbled_ips"=> ["l","RG_Phosphor_-_Konica_Minolta_CS-1000_5nm.ccss"],
 "lcd_gbled_pva"=> ["l","RG_Phosphor_-_Konica_Minolta_CS-1000_5nm.ccss"],
 "lcd_gbled_tft"=> ["l","RG_Phosphor_-_Konica_Minolta_CS-1000_5nm.ccss"],
 "plasma"       => ["c","PlasmaFamily_20Jul12.ccss"],
 "projector_ccss"=>["p","ProjectorFamily_07Feb11.ccss"],
 "projector_rgb"=> ["p",""],
 "projector_rgbw"=>["p",""],
 "projector_rgbcmy"=>["p",""],
 "unknown"      => ["l",""],
 "crt"          => ["c","CRT.ccss"],
 "l"            => ["l",""],
 "c"            => ["c",""],
 "p"            => ["p",""],
};

my $_ccxxmake_disptech_map={
 "non_refresh"    => "l",
 "refresh"        => "c",
 "lcd"            => "l",
 "lcd_wled"       => "e",
 "lcd_ccfl"       => "1",
 "lcd_ccfl_ips"   => "2",
 "lcd_ccfl_pva"   => "3",
 "lcd_ccfl_tft"   => "4",
 "lcd_wgccfl"     => "L",
 "lcd_wgccfl_ips" => "5",
 "lcd_wgccfl_pva" => "6",
 "lcd_wgccfl_tft" => "7",
 "lcd_rgbled"     => "b",
 "lcd_rgbled_ips" => "f",
 "lcd_rgbled_pva" => "g",
 "lcd_rgbled_tft" => "j",
 "lcd_rgphosphor" => "h",
 "lcd_rgphosphor_ips" => "k",
 "lcd_rgphosphor_pva" => "n",
 "lcd_rgphosphor_tft" => "q",
 "lcd_pfsphosphor" => "r",
 "lcd_pfsphosphor_ips" => "s",
 "lcd_pfsphosphor_pva" => "t",
 "lcd_pfsphosphor_tft" => "v",
 "lcd_gbled"      => "i",
 "lcd_gbled_ips"  => "x",
 "lcd_gbled_pva"  => "y",
 "lcd_gbled_tft"  => "z",
 "lcd_wled_ips"   => "8",
 "lcd_wled_pva"   => "9",
 "lcd_wled_tft"   => "d",
 "oled"           => "o",
 "oled_generic"   => "w",
 "qdoled"         => "o",
 "amoled"         => "a",
 "plasma"         => "m",
 "projector"      => "p",
 "projector_ccss" => "p",
 "projector_rgb"  => "A",
 "projector_rgbw" => "B",
 "projector_rgbcmy"=>"C",
 "unknown"        => "u",
 "crt"            => "c",
 "l"              => "l",
 "c"              => "c",
 "p"              => "p",
};

sub _resolve_ccss_yflag (@) {
 my ($path)=@_;
 return "l" if(!$path || !-f $path);
 return "l" if($path=~/\.ccmx$/i);
 my $txt="";
 if(open(my $fh,"<",$path)) {
  local $/;
  $txt=<$fh>;
  close($fh);
 }
 if($txt =~ /^DISPLAY_TYPE_REFRESH\s+"YES"/mi) { return "c"; }
 if($txt =~ /^DISPLAY_TYPE_REFRESH\s+"NO"/mi) {
  return "p" if($txt =~ /^(?:DISPLAY|TECHNOLOGY)\s+"[^"]*projector/mi);
  return "l";
 }
 return "p" if($txt =~ /^(?:DISPLAY|TECHNOLOGY)\s+"[^"]*projector/mi);
 return "c" if($txt =~ /^(?:DISPLAY|TECHNOLOGY)\s+"[^"]*(?:oled|plasma|crt)/mi);
 return "l";
}

sub _webui_ccss_normalize_keywords (@) {
 my ($text)=@_;
 return $text if(!defined($text) || $text eq "" || $text!~/BEGIN_DATA_FORMAT/m);
 my @lines=split(/\n/,$text,-1);
 my @header_fields=qw(DISPLAY TECHNOLOGY DISPLAY_TYPE_REFRESH REFERENCE SPECTRAL_BANDS SPECTRAL_START_NM SPECTRAL_END_NM SPECTRAL_NORM);
 my %have_keyword;
 my @format_fields;
 my $in_data_format=0;
 foreach my $line (@lines) {
  $have_keyword{$1}=1 if($line=~/^KEYWORD\s+"([^"]+)"/);
  if($line=~/^BEGIN_DATA_FORMAT/) { $in_data_format=1; next; }
  if($line=~/^END_DATA_FORMAT/) { $in_data_format=0; next; }
  next unless($in_data_format);
  foreach my $tok (split(/\s+/,$line)) {
   next unless($tok=~/^(?:SAMPLE_ID|SPEC_\d+)$/);
   push @format_fields, $tok if(!$have_keyword{$tok});
  }
 }
 my @out;
 my $format_keywords_added=0;
 foreach my $line (@lines) {
  if(!$format_keywords_added && $line=~/^NUMBER_OF_FIELDS\s/ && @format_fields) {
   foreach my $field (@format_fields) {
    next if($have_keyword{$field});
    push @out, 'KEYWORD "'.$field.'"';
    $have_keyword{$field}=1;
   }
   $format_keywords_added=1;
  }
  my $matched="";
  foreach my $field (@header_fields) {
   if($line=~/^\Q$field\E\s/) {
    $matched=$field;
    last;
   }
  }
  if($matched ne "" && !$have_keyword{$matched}) {
   push @out, 'KEYWORD "'.$matched.'"';
   $have_keyword{$matched}=1;
  }
  push @out, $line;
 }
 return join("\n",@out);
}

sub _webui_ccss_repair_file (@) {
 my ($path)=@_;
 return 0 if(!$path || !-f $path);
 my $raw=&read_from_file($path);
 return 0 if(!defined($raw) || $raw eq "");
 my $fixed=&_webui_ccss_normalize_keywords($raw);
 return 0 if($fixed eq $raw);
 if(open(my $fh,">",$path)) {
  print $fh $fixed;
  close($fh);
  return 1;
 }
 return 0;
}

sub resolve_display_type (@) {
 my ($key)=@_;
 # ccss_FILENAME or custom_FILENAME: look up a correction profile in the
 # system or custom dirs. The legacy token names are retained for API and
 # saved-settings compatibility, but the file may be CCSS or CCMX.
 if($key=~/^(?:ccss|custom)_(.+)$/) {
  my $fname=$1;
  $fname=~s{\\}{/}g;
  $fname=~s{^.*/}{}; # basename only; discard nested path / traversal attempts
  # allow letters, digits, dot, underscore, dash, parentheses, spaces (ccss filenames include these)
  $fname=~s/[^a-zA-Z0-9._\-()\[\] ]//g;
  my $sys="$_ccss_dir/$fname";
  my $cust="$_custom_ccss_dir/$fname";
  my $legacy="$_custom_ccss_legacy_dir/$fname";
  if(-f $sys)    { return (&_resolve_ccss_yflag($sys),$sys); }
  if(-f $cust)   { &_webui_ccss_repair_file($cust) if($cust=~/\.ccss$/i); return (&_resolve_ccss_yflag($cust),$cust); }
  if(-f $legacy) { &_webui_ccss_repair_file($legacy) if($legacy=~/\.ccss$/i); return (&_resolve_ccss_yflag($legacy),$legacy); }
  return ("l","");
 }
 my $info=$_dtype_info->{lc($key)}||["l",""];
 my $y_flag=$info->[0];
 my $ccss_file=$info->[1]ne""?"$_ccss_dir/$info->[1]":"";
 if($ccss_file ne "" && -f $ccss_file) {
  $y_flag=&_resolve_ccss_yflag($ccss_file);
 }
 return ($y_flag,$ccss_file);
}

# Map a correction override token (ccss_<file> | custom_<file>) to an absolute
# CCSS or CCMX path.
# Empty / whitespace token -> "" (caller falls back to the technology default).
# Missing / unreadable file -> "" (do NOT silently fall through to a different
# CCSS — the worker would print a confusing "no such file" error instead).
# Validated suffix is .ccss or .ccmx; basename only (no traversal). Used with
# the panel-technology parse so the meter session can use a real tech key for
# the spotread -y flag AND a separate CCSS file for the correction matrix.
sub resolve_ccss_override (@) {
 my ($token)=@_;
 $token="" if(!defined($token));
 $token=~s/^\s+|\s+$//g;
 return "" if($token eq "");
 # Accept either "ccss_<file>" / "custom_<file>" / bare "<file>" tokens so
 # legacy callers that already stripped the prefix keep working.
 my $fname=$token;
 $fname=$1 if($token=~/^(?:ccss|custom)_(.+)$/);
 $fname=~s{\\}{/}g;
 $fname=~s{^.*\/}{}; # basename only; discard nested path / traversal attempts
 $fname=~s/[^a-zA-Z0-9._\-()\[\] ]//g;
 return "" if($fname eq "");
 return "" if($fname !~ /\.(?:ccss|ccmx)$/i);
 my $sys="$_ccss_dir/$fname";
 my $cust="$_custom_ccss_dir/$fname";
 my $legacy="$_custom_ccss_legacy_dir/$fname";
 if(-f $sys)    { return $sys; }
 if(-f $cust)   { &_webui_ccss_repair_file($cust) if($cust=~/\.ccss$/i); return (-f $cust) ? $cust : ""; }
 if(-f $legacy) { &_webui_ccss_repair_file($legacy) if($legacy=~/\.ccss$/i); return (-f $legacy) ? $legacy : ""; }
 return "";
}

# Unsafe routes must retain the serialization that the original single HTTP
# loop provided. One general worker does that directly; multiple workers plus
# a global flock only created blocked threads and allowed an inherited or
# leaked descriptor to deadlock the entire lane.
$WEBUI_WORKER_POOL_SIZE=1;
# Longest the accept thread waits in one can_read() pass. Only bounds how
# quickly the idle sweep runs; readable sockets wake it immediately.
$WEBUI_ACCEPT_POLL_INTERVAL=0.5;
# How much of the request we MSG_PEEK looking for the header terminator. Real
# requests here are far smaller; anything at this size is treated as complete
# and handed on so a pathological header cannot be used to park a socket.
$WEBUI_HEADER_PEEK_BYTES=16384;
# A socket that connects but never delivers a complete header is reclaimed
# after this long. Matches the old socket read timeout, so a genuinely slow
# client is treated exactly as before -- it just no longer costs a worker
# while it dawdles.
$WEBUI_PENDING_IDLE_TIMEOUT=5;
# Ceiling on accepted-but-unread sockets before the oldest is shed.
$WEBUI_MAX_PENDING=512;
# Pause when a partially-sent header is present, so re-peeking the same bytes
# cannot become a busy loop.
$WEBUI_PARTIAL_HEADER_BACKOFF=0.02;
# Total budget for reading request headers in a worker. Headers arrive in a
# single packet on a LAN; this is a deadline for the whole read, not per
# recv(), so a client dribbling one byte at a time cannot extend it.
$WEBUI_HEADER_READ_TIMEOUT=2;
# Total budget for reading a request BODY, which is legitimately large and
# slow: 3D LUT and 1D DPG uploads post multi-hundred-KB JSON.
$WEBUI_BODY_READ_TIMEOUT=60;
# fds of accepted client sockets, handed from the accept thread to the workers.
$_webui_worker_queue=undef;
# Dedicated fast lane. Keeping idle sockets off the workers is not enough on
# its own: when the serialized general lane is legitimately busy (a live CEC power
# query can take ~2.4s with the TV off, /api/meter/status ~1.1s), an
# allowlisted request still had to queue behind them and the liveness probe
# blew its budget. The accept thread already has the request header in hand
# from the readiness peek, so it can route allowlisted requests to workers
# that never run anything slow. That makes the probe answerable regardless of
# what the rest of the UI is doing.
$_webui_fast_queue=undef;
$WEBUI_FAST_WORKER_COUNT=2;
# Profile fitting and display-aware patch generation can run for many minutes.
# Keep that computation off both the serialized device lane and the liveness
# lane. One worker also prevents two expensive colprof jobs from competing for
# the Pi at the same time.
$_webui_compute_queue=undef;
$WEBUI_COMPUTE_WORKER_COUNT=1;
# Bound completed-request queues. This is separate from the accepted-but-unread
# socket cap below. When a client retries aggressively during a slow operation,
# shed excess work instead of retaining an unbounded list of stale requests.
$WEBUI_GENERAL_QUEUE_MAX=128;
$WEBUI_FAST_QUEUE_MAX=256;
$WEBUI_COMPUTE_QUEUE_MAX=1;

sub webui_route_is_concurrent_safe (@) {
 # Allowlist, deliberately conservative: a route qualifies only if its handler
 # touches no shared mutable state, spawns no helper that contends for a
 # single device, and writes no file. Everything not listed here keeps the
 # old serialized behaviour.
 my ($method,$path)=@_;
 $method="" if(!defined($method));
 $path="" if(!defined($path));
 # CORS preflight: writes a constant response.
 return 1 if($method eq "OPTIONS");
 # Liveness probe: returns a literal. This is the one that matters most --
 # it is what the browser uses to decide the WebUI is up, so it must answer
 # even while the serialized device lane or compute lane is busy.
 return 1 if($path eq "/api/ping" || $path eq "/api/restart/status");
 # Static assets: read a fixed file from disk and stream it.
 return 1 if($path eq "/favicon.ico" || $path eq "/pgen-logo-light.png" || $path eq "/assets/hcfr_chc.js"
  || $path eq "/assets/icc_profile.js" || $path eq "/assets/icc_profile.css");
 # Live device health and identity are read-only. Keep both on the fast lane so
 # a long profile build or calibration worker cannot freeze Device Info.
 # /api/stats reads /proc/sysfs plus a 2s response cache; its cross-call CPU
 # delta baseline is :shared, so the pool does not corrupt the percentage.
 return 1 if($path eq "/api/stats" || $path eq "/api/info");
 # Companion traffic is authenticated and touches only its own atomic files.
 # It must not take the global WebUI mutex four times per second while a
 # measurement series and its status polling are active. The three pairing
 # endpoints join this lane too -- pair-request/pair-status run before a
 # Companion has a token at all, and pair-decide is the matching one-shot
 # click from the WebUI -- but they stay safe under two concurrent workers
 # because the pairing store's read-modify-write cycle is lock()-guarded.
 return 1 if($path eq "/api/icc/companion/poll" || $path eq "/api/icc/companion/ack" || $path eq "/api/icc/companion/status" || $path eq "/api/icc/companion/settings" || $path eq "/api/icc/companion/build-result" || $path eq "/api/icc/companion/build-ti3" || $path eq "/api/icc/companion/build-input" || $path eq "/api/icc/companion/pair-request" || $path eq "/api/icc/companion/pair-status" || $path eq "/api/icc/companion/pair-decide");
 return 0;
}

sub webui_route_is_compute (@) {
 my ($method,$path)=@_;
 return 0 if(!defined($method) || $method ne "POST");
 $path="" if(!defined($path));
 return 1 if($path eq "/api/icc/build" || $path eq "/api/icc/patches" || $path eq "/api/icc/precondition-patches" || $path eq "/api/icc/finetune" || $path eq "/api/icc/to-cube");
 return 0;
}

sub webui_renderer_restart_status_path (@) {
 my $restart_id=shift;
 return "" if(!defined($restart_id) || $restart_id !~ /^[a-f0-9-]{8,80}$/);
 return "/tmp/pgenerator-renderer-restart-$restart_id.status";
}

sub webui_renderer_restart_status_write (@) {
 my ($restart_id,$state,$message)=@_;
 my $path=&webui_renderer_restart_status_path($restart_id);
 return 0 if($path eq "");
 $state="error" if(!defined($state) || $state !~ /^(?:pending|starting|ready|error)$/);
 $message="" if(!defined($message));
 $message=~s/[\r\n]+/ /g;
 $message=substr($message,0,300);
 my $tmp=$path.".".$$ .".".threads->tid().".tmp";
 return 0 if(!open(my $fh,">",$tmp));
 print $fh "state=$state\nmessage=$message\n";
 close($fh);
 if(!rename($tmp,$path)) { unlink($tmp); return 0; }
 return 1;
}

sub webui_renderer_restart_begin (@) {
 # A per-apply token lets the browser follow the worker it started even when
 # another browser submits a later apply. Remove only stale status files.
 foreach my $old (glob("/tmp/pgenerator-renderer-restart-*.status")) {
  unlink($old) if(-f $old && -M $old > (1/24));
 }
 my $restart_id=sprintf("%x-%x-%x-%x",int(Time::HiRes::time()*1000),$$,threads->tid(),int(rand(0x7fffffff)));
 &webui_renderer_restart_status_write($restart_id,"pending","Waiting for the renderer restart worker.");
 return $restart_id;
}

sub webui_renderer_restart_status_json (@) {
 my $query=shift;
 my $restart_id="";
 $restart_id=$1 if(defined($query) && $query=~/(?:^|&)id=([a-f0-9-]{8,80})(?:&|$)/);
 my $path=&webui_renderer_restart_status_path($restart_id);
 return '{"status":"error","state":"error","message":"Invalid restart identifier."}' if($path eq "");
 return '{"status":"error","state":"error","message":"Restart status is no longer available."}' if(!-f $path);
 my ($state,$message)=("error","Restart status could not be read.");
 if(open(my $fh,"<",$path)) {
  while(<$fh>) {
   s/[\r\n]+$//;
   $state=$1 if(/^state=(pending|starting|ready|error)$/);
   $message=$1 if(/^message=(.*)$/);
  }
  close($fh);
 }
 $message=~s/\\/\\\\/g; $message=~s/"/\\"/g;
 return '{"status":"ok","state":"'.$state.'","message":"'.$message.'"}';
}

sub webui_wait_for_renderer_ready (@) {
 my $timeout=shift;
 $timeout=12 if(!defined($timeout) || $timeout <= 0);
 my $deadline=Time::HiRes::time()+$timeout;
 while(Time::HiRes::time() < $deadline) {
  if(&pattern_generator_is_running()) {
   return 1 if(!$is_kms);
   return 1 if(&pattern_generator_has_drm_master());
  }
  Time::HiRes::sleep(0.1);
 }
 return 0;
}

sub webui_wait_for_dovi_wire (@) {
 my $timeout=shift;
 $timeout=15 if(!defined($timeout) || $timeout <= 0);
 # Only meaningful on the DV-patched kernels that expose the property; on
 # anything else pattern_generator_start already fell back to the non-DV
 # renderer and there is nothing to wait for.
 return 0 if(!&kms_connector_has_property("DOVI_OUTPUT_METADATA"));
 my $deadline=Time::HiRes::time()+$timeout;
 while(Time::HiRes::time() < $deadline) {
  return 1 if(&kms_connector_blob_active("DOVI_OUTPUT_METADATA"));
  Time::HiRes::sleep(0.5);
 }
 return 0;
}

sub webui_complete_renderer_restart (@) {
 my $restart_id=shift;
 &webui_renderer_restart_status_write($restart_id,"starting","Restarting the renderer and waiting for DRM readiness.");
 &pattern_generator_stop();
 &load_new_pattern_file("webui apply");
 if(&webui_wait_for_renderer_ready(12)) {
  # DRM-master handoff completes several seconds before the renderer's
  # first page flip, and in Dolby Vision mode only that flip commits the
  # DOVI_OUTPUT_METADATA blob (the Dolby VSIF) to the connector: the DV
  # shader/FBO init at 4K keeps the wire in an intermediate BT.2020-
  # without-VSIF state for ~5s after master acquisition. Reporting
  # "ready" at master-acquisition made the WebUI claim DV was active
  # while the wire was still SDR; on sinks that evaluate the VSIF lazily
  # (reported on an XGIMI Titan projector) the picture then stays SDR
  # until the next pattern write forces a flip. Hold the apply modal
  # until the blob is actually staged so "applied" means "on the wire".
  if($pgenerator_conf{"dv_status"} eq "1" && $is_kms) {
   &webui_renderer_restart_status_write($restart_id,"starting","Waiting for the Dolby Vision infoframe to reach the display.");
   if(&webui_wait_for_dovi_wire(15)) {
    &webui_renderer_restart_status_write($restart_id,"ready","The renderer is running and the Dolby Vision infoframe is on the wire.");
    &log("WebUI: renderer restart $restart_id is ready (DV infoframe verified on the connector)");
   } else {
    &webui_renderer_restart_status_write($restart_id,"ready","The renderer is running, but the Dolby Vision infoframe was not confirmed on the connector. If the display stays in SDR, select any pattern to force it.");
    &log("WebUI: renderer restart $restart_id ready, but DOVI_OUTPUT_METADATA never became active on the connector");
   }
   return 1;
  }
  &webui_renderer_restart_status_write($restart_id,"ready","The renderer is running and owns DRM master.");
  &log("WebUI: renderer restart $restart_id is ready");
  return 1;
 }
 &webui_renderer_restart_status_write($restart_id,"error","The renderer did not become ready after restarting.");
 &log("WebUI: renderer restart $restart_id failed readiness verification");
 return 0;
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
    &log("WebUI: failed to bind port $http_port: $! - trying 8080");
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

 # NOTE: no global $SIG{CHLD} reaper here, deliberately. This process
 # runs system()/backticks/piped opens all over (modetest, helpers)
 # and checks $? afterwards; a waitpid(-1,...) reaper steals those
 # exit statuses and breaks the checks. Renderer-restart workers are
 # double-forked instead (see the /api/config POST handler) so they
 # are reparented to init and need no reaping in this process.

 # Hand each accepted socket to a pre-spawned worker instead of handling it on
 # the accept thread. Passing the raw fd through a Thread::Queue (rather than
 # the IO::Socket object, which cannot cross an ithread boundary) keeps the
 # accept loop free to drain the backlog while a slow handler runs.
 $_webui_worker_queue=Thread::Queue->new();
 $_webui_fast_queue=Thread::Queue->new();
 $_webui_compute_queue=Thread::Queue->new();
 for my $i (1..$WEBUI_WORKER_POOL_SIZE) {
  threads->create(\&webui_http_worker,$i,"general")->detach();
 }
 for my $i (1..$WEBUI_FAST_WORKER_COUNT) {
  threads->create(\&webui_http_worker,"F$i","fast")->detach();
 }
 for my $i (1..$WEBUI_COMPUTE_WORKER_COUNT) {
  threads->create(\&webui_http_worker,"C$i","compute")->detach();
 }
 &log("WebUI: request lanes started ($WEBUI_WORKER_POOL_SIZE serialized + $WEBUI_FAST_WORKER_COUNT fast + $WEBUI_COMPUTE_WORKER_COUNT compute)");

 # A worker is committed only once a COMPLETE request header has arrived.
 #
 # accept() returns as soon as the TCP handshake finishes, before a single
 # byte of request exists. Handing that bare socket straight to a worker meant
 # an idle connection owned a worker until the read timed out, and browsers
 # routinely open speculative preconnect sockets and leave them silent -- so a
 # handful of ordinary sockets could occupy the whole pool and even the
 # allowlisted liveness probe went unanswered. That is the same "WebUI is
 # offline" symptom this work exists to remove, just from a different cause.
 #
 # So the accept thread parks new sockets in a pending set and watches them
 # with MSG_PEEK, which inspects without consuming: the worker still reads the
 # request normally. Only when the header terminator is present does the fd go
 # to the queue. A socket that never speaks costs one fd here and zero
 # workers, and is reaped by the idle sweep.
 #
 # The accept thread must never block on any one client, so every wait is a
 # bounded can_read() across the whole set.
 my $sel=IO::Select->new($http_server);
 my %pending;          # fileno => [ handle, accepted_at ]
 my $listen_fno=fileno($http_server);
 while(1) {
  my @ready=$sel->can_read($WEBUI_ACCEPT_POLL_INTERVAL);
  my $saw_partial=0;
  foreach my $h (@ready) {
   my $fno=fileno($h);
   next if(!defined($fno));
   if($fno == $listen_fno) {
    my $client=$http_server->accept();
    next if(!$client);
    # Overload valve: shed the oldest waiter rather than let the pending set
    # grow without bound and exhaust our descriptors.
    if(scalar(keys %pending) >= $WEBUI_MAX_PENDING) {
     my $oldest=(sort { $pending{$a}->[1] <=> $pending{$b}->[1] } keys %pending)[0];
     if(defined($oldest)) {
      my $victim=$pending{$oldest}->[0];
      $sel->remove($victim);
      delete($pending{$oldest});
      eval { close($victim); };
     }
    }
    $client->blocking(0);
    $sel->add($client);
    $pending{fileno($client)}=[$client,Time::HiRes::time()];
    next;
   }
   # An already-accepted socket has something to say. Peek, do not consume.
   my $peek="";
   my $got=eval { recv($h,$peek,$WEBUI_HEADER_PEEK_BYTES,Socket::MSG_PEEK()) };
   if(!defined($got) || !defined($peek) || $peek eq "") {
    # EOF or error: the peer went away before completing a request.
    $sel->remove($h);
    delete($pending{$fno});
    eval { close($h); };
    next;
   }
   # Not a complete header yet. Leave it pending and keep waiting; the idle
   # sweep below will eventually reclaim it if it never finishes.
   if($peek !~ /\r\n\r\n/ && $peek !~ /\n\n/ && length($peek) < $WEBUI_HEADER_PEEK_BYTES) {
    $saw_partial=1;
    next;
   }
   # Route from the header we already peeked. The worker re-parses the
   # request itself -- this only decides which lane it waits in, so a
   # mis-parse here can never change how the request is handled.
   my ($peek_method,$peek_path)=$peek=~/^(GET|POST|PUT|OPTIONS)\s+(\S+)/;
   $peek_path="" if(!defined($peek_path));
   $peek_path=~s/\?.*$//;
   my ($queue,$lane,$queue_max);
   if(&webui_route_is_compute($peek_method,$peek_path)) {
    ($queue,$lane,$queue_max)=($_webui_compute_queue,"compute",$WEBUI_COMPUTE_QUEUE_MAX);
   } elsif(&webui_route_is_concurrent_safe($peek_method,$peek_path)) {
    ($queue,$lane,$queue_max)=($_webui_fast_queue,"fast",$WEBUI_FAST_QUEUE_MAX);
   } else {
    ($queue,$lane,$queue_max)=($_webui_worker_queue,"general",$WEBUI_GENERAL_QUEUE_MAX);
   }
   # A queued request is already complete and owns memory plus a descriptor.
   # If a client retries faster than its lane can work, reject the excess now
   # instead of turning stale requests into an unbounded backlog.
   if($queue->pending() >= $queue_max) {
    $sel->remove($h);
    delete($pending{$fno});
    $h->blocking(1);
    my $msg='{"status":"error","message":"WebUI is busy; retry shortly"}';
    print $h "HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nContent-Length: ".length($msg)."\r\nConnection: close\r\nRetry-After: 2\r\n\r\n$msg";
    eval { close($h); };
    &log("WebUI: shed $lane-lane request for $peek_path (queue limit $queue_max)");
    next;
   }
   # Complete (or oversized) header: now it is worth a worker.
   $sel->remove($h);
   delete($pending{$fno});
   my $fd=eval { POSIX::dup($fno) };
   eval { close($h); };
   if(!defined($fd)) {
    &log("WebUI: could not duplicate client fd: $!");
    next;
   }
   $queue->enqueue($fd);
  }
  # Reclaim sockets that connected but never produced a usable request.
  if(scalar(keys %pending)) {
   my $now=Time::HiRes::time();
   foreach my $fno (keys %pending) {
    next if(($now - $pending{$fno}->[1]) <= $WEBUI_PENDING_IDLE_TIMEOUT);
    my $stale=$pending{$fno}->[0];
    $sel->remove($stale);
    delete($pending{$fno});
    eval { close($stale); };
   }
  }
  # A half-sent header leaves the socket permanently readable, so without this
  # the loop would spin at full CPU re-peeking the same bytes.
  Time::HiRes::sleep($WEBUI_PARTIAL_HEADER_BACKOFF) if($saw_partial);
 }
}

###############################################
#            WebUI Request Worker             #
###############################################
# One of the pre-spawned lane workers. Created ONCE at startup:
# Perl ithreads clone the whole interpreter, so a thread-per-request would be
# ruinous on a Pi with this codebase. Each worker owns the fd it dequeues and
# is responsible for closing it on every path, including errors -- the daemon
# is long-lived and a leaked fd is eventually fatal.
sub webui_http_worker (@) {
 my $worker_id=shift;
 my $lane=shift;
 $SIG{PIPE}='IGNORE';
 my $queue=($lane eq "fast") ? $_webui_fast_queue : (($lane eq "compute") ? $_webui_compute_queue : $_webui_worker_queue);
 while(defined(my $fd=$queue->dequeue())) {
  my $client;
  eval {
   $client=IO::Socket::INET->new_from_fd($fd,"+<");
   # IO::Socket::INET->new() enables autoflush, but new_from_fd() does NOT.
   # Without this the handler's response sits in the buffer and the
   # shutdown() below discards it, so every request returns an empty body.
   $client->autoflush(1) if($client);
   1;
  };
  if(!$client) {
   &log("WebUI: worker $worker_id could not adopt fd $fd: $@");
   eval { POSIX::close($fd); };
   next;
  }
  eval { &webui_handle_request($client); };
  if($@) {
   &log("WebUI: request error: $@");
  }
  # Closing the IO::Socket closes the duplicated fd. Guard against the object
  # having gone away so the descriptor can never leak.
  if($client) {
   eval { shutdown($client, 2); };
   eval { close($client); };
  } else {
   eval { POSIX::close($fd); };
  }
 }
}

###############################################
#          WebUI Request Handler              #
###############################################
# The request body below is the former accept-loop body, moved verbatim.
sub webui_handle_request (@) {
 my $client=shift;
  {
   # Per-socket read/write timeout (thread-safe, unlike alarm/SIGALRM which is process-wide).
   # Kept as a backstop; the real bounds are the explicit deadlines below.
   setsockopt($client, Socket::SOL_SOCKET(), Socket::SO_RCVTIMEO(), pack('l!l!', 5, 0));
   setsockopt($client, Socket::SOL_SOCKET(), Socket::SO_SNDTIMEO(), pack('l!l!', 5, 0));
   $client->blocking(0);
   my $rsel=IO::Select->new($client);

   # Headers and body get SEPARATE budgets, and each is a deadline for the
   # whole read rather than a per-recv() timeout -- a peer trickling one byte
   # at a time cannot hold a worker open indefinitely by resetting the clock.
   # Headers are tiny and arrive in one packet, so their budget is short. The
   # body budget stays generous because 3D LUT and 1D DPG uploads legitimately
   # POST multi-hundred-KB payloads over a slow link.
   #
   # All reads here are sysread(): mixing buffered reads with select() would
   # strand bytes in Perl's buffer where can_read() cannot see them.
   my $req="";
   my $body="";
   my $hdr_deadline=Time::HiRes::time() + $WEBUI_HEADER_READ_TIMEOUT;
   while(1) {
    my $idx=index($req,"\r\n\r\n");
    my $term=4;
    if($idx < 0) { $idx=index($req,"\n\n"); $term=2; }
    if($idx >= 0) {
     # sysread() can overshoot the header terminator, so anything past it is
     # the first slice of the body.
     $body=substr($req,$idx+$term);
     $req=substr($req,0,$idx+$term);
     last;
    }
    my $remaining=$hdr_deadline - Time::HiRes::time();
    last if($remaining <= 0);
    last if(length($req) >= $WEBUI_HEADER_PEEK_BYTES);
    last if(!$rsel->can_read($remaining));
    my $chunk="";
    my $n=sysread($client,$chunk,4096);
    if(!defined($n)) { next if($!{EAGAIN} || $!{EWOULDBLOCK} || $!{EINTR}); last; }
    last if($n <= 0);
    $req.=$chunk;
   }

   # Read body if Content-Length present
   if($req=~/Content-Length:\s*(\d+)/i) {
    my $cl=$1;
    my $body_deadline=Time::HiRes::time() + $WEBUI_BODY_READ_TIMEOUT;
    while(length($body) < $cl) {
     my $remaining=$body_deadline - Time::HiRes::time();
     last if($remaining <= 0);
     last if(!$rsel->can_read($remaining));
     my $chunk="";
     my $n=sysread($client,$chunk,$cl-length($body));
     if(!defined($n)) { next if($!{EAGAIN} || $!{EWOULDBLOCK} || $!{EINTR}); last; }
     last if($n <= 0);
     $body.=$chunk;
    }
   } else {
    $body="";
   }
   # Responses are written with buffered print(); put the handle back into
   # blocking mode so a large body cannot come back as a short write.
   $client->blocking(1);

   my ($method,$path)=$req=~/^(GET|POST|PUT|OPTIONS)\s+(\S+)/;
    $path="" if(!defined $path);
    # Strip the query string from the path. The HTTP request line is
    # "METHOD /path?query HTTP/1.1" but our regex captures the full "/path?query"
    # as $path, which then doesn't match `eq "/"` for the main HTML route.
    # The "WebUI keeps going offline" symptom was this: any navigation
    # with a cache-buster query (e.g. the browser's "?_=12345") would
    # fall through to the 404 handler instead of serving the page.
    my $request_query="";
    $request_query=$1 if(defined($path) && $path=~/\?(.*)$/);
    $path=~s/\?.*$// if(defined($path));
    my $request_host="";
    $request_host=$1 if($req=~/^Host:\s*([A-Za-z0-9._\-\[\]:]+)\s*$/mi);
    # mDNS is useful for discovery, but keeping pgenerator.local in the
    # browser address bar makes every refresh and every new connection depend
    # on the client's mDNS resolver. Some Windows network stacks intermittently
    # fail that lookup, especially with multiple adapters or a VPN. Redirect
    # only the main page to the concrete address that accepted this socket;
    # all subsequent assets and API calls then use that stable numeric host.
    my $request_local_ip=eval { $client->sockhost() } || "";
    # Only the pairing endpoints use this -- it lets the approval prompt show
    # which machine on the network is asking, alongside its name and code.
    my $request_peer_ip=eval { $client->peerhost() } || "";
    &log("WebUI: $method $path");

   # CORS headers for API
   my $cors="Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\nConnection: close\r\n";

   if($method eq "OPTIONS") {
    print $client "HTTP/1.1 204 No Content\r\n$cors\r\n";
   }
   elsif(($path eq "/" || $path eq "/index.html") && $request_host=~/^pgenerator\.local(?::\d+)?$/i && $request_local_ip=~/^\d{1,3}(?:\.\d{1,3}){3}$/ && $request_local_ip ne "0.0.0.0") {
    my $redirect_path=$path;
    $redirect_path="/" if($redirect_path eq "/index.html");
    my $safe_query=$request_query;
    $safe_query=~s/[\r\n]//g;
    $redirect_path.="?$safe_query" if($safe_query ne "");
    my $location="http://$request_local_ip$redirect_path";
    print $client "HTTP/1.1 307 Temporary Redirect\r\nLocation: $location\r\nCache-Control: no-store\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
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
   elsif($path eq "/assets/hcfr_chc.js") {
    my $asset_path="/usr/share/PGenerator/hcfr_chc.js";
    if(-f $asset_path) {
     open(my $fh, "<:raw", $asset_path);
     my $asset_data; { local $/; $asset_data=<$fh>; } close($fh);
     my $len=length($asset_data);
     print $client "HTTP/1.1 200 OK\r\nContent-Type: application/javascript; charset=utf-8\r\nContent-Length: $len\r\nCache-Control: no-cache\r\n\r\n";
     print $client $asset_data;
    } else {
     print $client "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n";
    }
   }
   elsif($path eq "/assets/icc_profile.js" || $path eq "/assets/icc_profile.css") {
    my $asset_name=($path eq "/assets/icc_profile.css")?"icc_profile.css":"icc_profile.js";
    my $asset_data=&webui_icc_asset($asset_name);
    if($asset_data ne "") {
     my $len=length($asset_data);
     my $content_type=($asset_name=~/\.css\z/)?"text/css":"application/javascript";
     print $client "HTTP/1.1 200 OK\r\nContent-Type: $content_type; charset=utf-8\r\nContent-Length: $len\r\nCache-Control: no-cache\r\n\r\n";
     print $client $asset_data;
    } else {
     print $client "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n";
    }
   }
   elsif($path eq "/pgen-logo-light.png") {
    my $logo_path="/usr/share/PGenerator/pgen-logo-light.png";
    if(-f $logo_path) {
     open(my $fh, "<:raw", $logo_path);
     my $logo_data; { local $/; $logo_data=<$fh>; } close($fh);
     my $len=length($logo_data);
     print $client "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: $len\r\nCache-Control: public, max-age=604800\r\n\r\n";
     print $client $logo_data;
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
      my ($result,$need_restart,$restart_id)=&webui_apply_config($body);
      my $len=length($result);
      print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
      if($need_restart) {
       # The renderer restart can take 10+ seconds (the apply
       # retry ladder in daemon.pm waits 0.6+0.4+1.0+3.0 = 5s of
       # backoff plus actual start attempts, and pgsethdr steals
       # DRM master from the running renderer). Forking the
       # restart into a child keeps the HTTP server responsive
       # so the user's browser doesn't see "connection errors"
       # on the next poll, and so subsequent WebUI POSTs (e.g.
       # pattern requests) are not blocked. The child does
       # stop+start; the parent closes the client and returns
       # to the accept loop. If the fork fails (e.g. resource
       # limits), fall back to an in-process restart so the
       # user's intent is still honoured.
       my $pid=fork();
       if(!defined $pid) {
        # Fork failed — do the restart in-process as a
        # last resort. The HTTP client is already closed below.
        close($client);
        undef $client;
        &webui_complete_renderer_restart($restart_id);
       } elsif($pid == 0) {
        # Intermediate child: double-fork so the actual worker is
        # reparented to init and reaped there. A $SIG{CHLD} reaper
        # in the HTTP server would also steal exit statuses from
        # the system()/backtick/piped-open calls this process makes
        # everywhere (command.pm checks $? after modetest), so the
        # daemon must never install one. The intermediate child
        # exits immediately and the parent reaps it synchronously.
        my $worker=fork();
        if(!defined $worker || $worker == 0) {
         # Worker (or fork-failed fallback running inside the
         # intermediate child): do the restart with the same retry
         # ladder as load_new_pattern_file, which handles the
         # documented DRM-master race (pgsethdr steals DRM master
         # from the newly-spawned renderer) with up to 4 attempts
         # and settle delays. This recovers the renderer in the
         # HDR case where a single stop+start almost always loses
         # the race. load_new_pattern_file also re-pushes the last
         # remembered pattern, so the user sees a pattern on the
         # TV immediately after the apply instead of a frozen
         # splash framebuffer.
         close($client);
         $SIG{CHLD}='DEFAULT';
         # Serialize apply workers: a failed retry ladder can run for
         # 30-40s, and a second apply's pattern_generator_stop() would
         # kill the renderer the first worker just started - the two
         # ladders then interleave and both fail. The lock makes the
         # second worker wait; last writer wins with the freshest conf.
         # The lock is released automatically when the worker exits.
         &log("WebUI: apply worker started (pid $$)");
         my $pg_apply_lock;
         # The daemon runs as the pgenerator user: /var/lock is not
         # writable, so the lock lives in the daemon's own state dir.
         if(open($pg_apply_lock,'>',"$var_dir/running/webui-apply.lock")) {
          flock($pg_apply_lock,2);
          &log("WebUI: apply worker holds the restart lock (pid $$)");
         } else {
          &log("WebUI: apply worker could not open the restart lock: $!");
         }
         # Stop first: a signal-mode change requires a full renderer
         # restart (is_hdr/eotf are baked in at renderer startup),
         # and load_new_pattern_file only starts the renderer when it
         # is NOT already running. Without the stop the worker is a
         # no-op whenever the renderer survived — alive but stuck in
         # the previous mode with a stale/empty HDR blob.
         &webui_complete_renderer_restart($restart_id);
        }
        exit(0);
       } else {
        # Parent: reap the intermediate child (it exits at once;
        # the worker it spawned belongs to init now) and return to
        # the accept loop.
        waitpid($pid,0);
        close($client);
        undef $client;
       }
      }
     }
   }
   elsif($path eq "/api/restart/status" && $method eq "GET") {
    my $r=&webui_renderer_restart_status_json($request_query);
    my $len=length($r);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$r";
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
   elsif($path eq "/api/system-backup/export" && $method eq "POST") {
    my ($fname,$tmp,$message)=&webui_system_backup_export();
    if($tmp ne "" && -f $tmp) {
     if(open(my $fh,"<:raw",$tmp)) {
      my $size=-s $tmp;
      print $client "HTTP/1.1 200 OK\r\nContent-Type: application/gzip\r\nContent-Disposition: attachment; filename=\"$fname\"\r\nContent-Length: $size\r\n$cors\r\n";
      while(read($fh,my $buf,65536)){ print $client $buf; }
      close($fh);
     } else {
      my $r='{"status":"error","message":"Failed to read system backup"}';
      print $client "HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\nContent-Length: ".length($r)."\r\n$cors\r\n$r";
     }
     unlink($tmp);
    } else {
     $message="Could not create system backup" if($message eq "");
     my $r='{"status":"error","message":"'.&_webui_json_escape($message).'"}';
     print $client "HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\nContent-Length: ".length($r)."\r\n$cors\r\n$r";
    }
   }
   elsif($path eq "/api/system-backup/import" && $method eq "POST") {
    my $result=&webui_system_backup_import_chunk($body);
    my $code=($result=~/"status":"ok"/) ? 200 : 400;
    print $client "HTTP/1.1 $code ".($code==200?"OK":"Bad Request")."\r\nContent-Type: application/json\r\nContent-Length: ".length($result)."\r\n$cors\r\n$result";
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
   elsif($path eq "/api/power") {
    # Power-off request. Reply before issuing HALT so the client sees a
    # clean response before the kernel brings userspace down.
    my $r='{"status":"ok","message":"Shutting down..."}';
    my $len=length($r);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$r";
    close($client);
    undef $client;
    my $cmd_b64=encode_base64("HALT","");
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
   elsif($path eq "/api/wifi/radio" && $method eq "GET") {
    my $json=&webui_wifi_radio_status_json();
    my $len=length($json);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$json";
   }
   elsif($path eq "/api/wifi/radio" && $method eq "POST") {
    my $result=&webui_wifi_radio_control($body);
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/wifi/ap" && $method eq "POST") {
    my $result=&webui_wifi_ap_apply($body);
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/wifi/ap/status" && $method eq "GET") {
    my $json=&webui_wifi_ap_status_json();
    my $len=length($json);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$json";
   }
   elsif($path eq "/api/wifi/ap/enable" && $method eq "POST") {
    my $result=&webui_wifi_ap_control("enable");
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/wifi/ap/disable" && $method eq "POST") {
    my $result=&webui_wifi_ap_control("disable");
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/bluetooth/status" && $method eq "GET") {
    my $json=&webui_bluetooth_status_json();
    my $len=length($json);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$json";
   }
   elsif($path eq "/api/bluetooth/power" && $method eq "POST") {
    my $result=&webui_bluetooth_bool_control($body,"BT_SET_POWERED","Bluetooth power");
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/bluetooth/discoverable" && $method eq "POST") {
    my $result=&webui_bluetooth_bool_control($body,"BT_SET_DISCOVERABLE","Bluetooth discoverable");
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/bluetooth/agent" && $method eq "POST") {
    my $result=&webui_bluetooth_bool_control($body,"BT_SET_AGENT","Bluetooth pairing agent");
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/bluetooth/name" && $method eq "POST") {
    my $result=&webui_bluetooth_set_name($body);
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/bluetooth/pan/restart" && $method eq "POST") {
    my $result=&webui_bluetooth_pan_restart();
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
	     $result=&webui_cec($cec_cmd);
	     $_cec_cache=$result;
	     $_cec_cache_time=time();
	    } else {
	     $result=&webui_cec($cec_cmd);
	     $_cec_cache="";
	     $_cec_cache_time=0;
	    }
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
    elsif($path=~/^\/api\/lg\//) {
     my $result=&webui_lg_api($path,$method,$body);
     $result=&lg_public_api_json($result) if(defined(&lg_public_api_json));
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
   elsif($path eq "/api/resolve/cancel" && $method eq "POST") {
    my $result=&webui_resolve_cancel();
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
    # Allow more time here: the first check after boot may need DNS/TLS setup
    # or a one-time clock sync before GitHub responds.
    my @args_b64=map { encode_base64($_,"") } ("BASH_CMD","PGPLUS_CHECK");
    my $result=`timeout 25 env $pg_cmd_env="@args_b64" $sudo_cmd 2>/dev/null`;
    chomp($result);
    $result='{"status":"error","message":"Update check timed out — please try again in a few seconds"}' if($result eq "" || $result!~/^\{/);
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/update/apply" && $method eq "POST") {
    my $r='{"status":"ok","message":"Update started. PGenerator+ will restart shortly."}';
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
     $gpu_mem||="128";
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
   elsif($path eq "/api/meter/simulate" && $method eq "POST") {
    my $result=&webui_meter_simulation_set($body);
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/meter/read/result") {
    my $result=&webui_meter_read_result();
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
	  elsif($path eq "/api/meter/read/ready" && $method eq "POST") {
	   my $result=&webui_meter_read_ready();
	   my $len=length($result);
	   print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
	  }
	  elsif($path eq "/api/meter/setup/ack" && $method eq "POST") {
	   my $result=&webui_meter_setup_ack($body);
	   my $len=length($result);
	   print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
	  }
	  elsif($path eq "/api/meter/session/stop" && $method eq "POST") {
	   my $result=&webui_meter_session_stop_only();
	   my $len=length($result);
	   print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
	  }
	   elsif($path eq "/api/meter/series" && $method eq "POST") {
	    my $result=&webui_meter_series_start($body);
	    my $len=length($result);
	    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
	   }
   elsif($path eq "/api/meter/series/status") {
    my $summary=($request_query=~/(?:^|&)summary=1(?:&|$)/) ? 1 : 0;
    my $result=&webui_meter_series_status($summary);
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/meter/full-autocal/report-state" && $method eq "POST") {
    my $result=&webui_meter_full_autocal_report_state($body);
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/meter/lg-autocal" && $method eq "POST") {
    my $result=&webui_meter_lg_autocal_start($body);
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/meter/lg-autocal/status") {
    my $result=&webui_meter_lg_autocal_status();
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
	   elsif($path eq "/api/meter/lg-autocal/stop" && $method eq "POST") {
	    my $result=&webui_meter_lg_autocal_stop();
	    my $len=length($result);
	    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
	   }
	   elsif($path eq "/api/meter/lg-autocal/clear-tonemap-pending" && $method eq "POST") {
	    my $result=&webui_meter_lg_autocal_clear_tonemap_pending();
	    my $len=length($result);
	    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
	   }
   elsif($path eq "/api/meter/lg-3d-autocal/start" && $method eq "POST") {
    my $result=&webui_meter_lg_3d_autocal_start($body);
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/meter/lg-3d-autocal/status") {
    my $result=&webui_meter_lg_3d_autocal_status();
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/meter/lg-3d-autocal/retry-upload" && $method eq "POST") {
    my $result=&webui_meter_lg_3d_autocal_retry_upload($body);
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/meter/lg-3d-autocal/stop" && $method eq "POST") {
    my $result=&webui_meter_lg_3d_autocal_stop();
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
  elsif($path eq "/api/meter/series/ready" && $method eq "POST") {
   my $result=&webui_meter_series_ready();
   my $len=length($result);
   print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
  }
   elsif($path eq "/api/meter/stop" && $method eq "POST") {
    my $result=&webui_meter_stop();
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/meter/stop/status") {
    my $result=&webui_meter_stop_status();
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
   elsif($path eq "/api/meter/custom-series") {
    my $result=&webui_meter_custom_series_load($request_query);
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/icc/profiles") {
    my $result=&webui_icc_profile_list();
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/icc/reusable") {
    my $result=&webui_icc_reusable_measurements($request_query);
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/icc/finetune" && $method eq "POST") {
    my $result=&webui_icc_profile_finetune($body);
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/icc/build" && $method eq "POST") {
    my $result=&webui_icc_profile_build($body);
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/icc/patches" && $method eq "POST") {
    my $result=&webui_icc_patch_generate($body);
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/icc/precondition-patches" && $method eq "POST") {
    my $result=&webui_icc_precondition_patch_generate($body);
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/icc/measurements") {
    my $result=&webui_icc_profile_measurements($request_query);
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/icc/validation") {
    my $result=&webui_icc_profile_validation($request_query);
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/icc/delete" && $method eq "POST") {
    my $result=&webui_icc_profile_delete($body);
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/icc/to-cube" && $method eq "POST") {
    my $result=&webui_icc_profile_to_cube($body);
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/icc/download") {
    my ($fname,$content)=&webui_icc_profile_download($request_query);
    my $len=length($content);
    if($fname ne "") {
     print $client "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.iccprofile\r\nContent-Disposition: attachment; filename=\"$fname\"\r\nContent-Length: $len\r\n$cors\r\n";
     print $client $content;
    } else {
     my $err="{\"status\":\"error\",\"message\":\"ICC profile not found\"}";
     print $client "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: ".length($err)."\r\n$cors\r\n$err";
    }
   }
   elsif($path eq "/api/icc/companion/status") {
    my $result=&webui_icc_companion_status();
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ".length($result)."\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/icc/companion/settings" && $method eq "POST") {
    my $result=&webui_icc_companion_settings($body);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ".length($result)."\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/icc/companion/pattern" && $method eq "POST") {
    my $result=&webui_icc_companion_pattern($body);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ".length($result)."\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/icc/companion/poll") {
    my $result=&webui_icc_companion_poll($request_query);
    my $code=($result=~/\"status\":\"unauthorized\"/)?403:200;
    print $client "HTTP/1.1 $code ".($code==200?"OK":"Forbidden")."\r\nContent-Type: application/json\r\nContent-Length: ".length($result)."\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/icc/companion/build-ti3") {
    my ($ok,$data)=&webui_icc_companion_build_ti3($request_query);
    if($ok) { print $client "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: ".length($data)."\r\n$cors\r\n$data"; }
    else { print $client "HTTP/1.1 403 Forbidden\r\nContent-Type: application/json\r\nContent-Length: ".length($data)."\r\n$cors\r\n$data"; }
   }
   elsif($path eq "/api/icc/companion/build-input") {
    my ($ok,$data)=&webui_icc_companion_build_input($request_query);
    if($ok) { print $client "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: ".length($data)."\r\n$cors\r\n$data"; }
    else { print $client "HTTP/1.1 403 Forbidden\r\nContent-Type: application/json\r\nContent-Length: ".length($data)."\r\n$cors\r\n$data"; }
   }
   elsif($path eq "/api/icc/companion/build-result" && $method eq "POST") {
    my $result=&webui_icc_companion_build_result($request_query,$body);
    my $code=($result=~/\"status\":\"unauthorized\"/)?403:200;
    print $client "HTTP/1.1 $code ".($code==200?"OK":"Forbidden")."\r\nContent-Type: application/json\r\nContent-Length: ".length($result)."\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/icc/companion/profile-install" && $method eq "POST") {
    my $result=&webui_icc_companion_profile_install($body);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ".length($result)."\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/icc/companion/profile-install-status") {
    my $result=&webui_icc_companion_profile_install_status($request_query);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ".length($result)."\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/icc/companion/profile-install-data") {
    my ($ok,$data)=&webui_icc_companion_profile_install_data($request_query);
    if($ok) { print $client "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.iccprofile\r\nContent-Length: ".length($data)."\r\n$cors\r\n"; print $client $data; }
    else { print $client "HTTP/1.1 403 Forbidden\r\nContent-Type: application/json\r\nContent-Length: ".length($data)."\r\n$cors\r\n$data"; }
   }
   elsif($path eq "/api/icc/companion/profile-install-result" && $method eq "POST") {
    my $result=&webui_icc_companion_profile_install_result($request_query);
    my $code=($result=~/\"status\":\"unauthorized\"/)?403:200;
    print $client "HTTP/1.1 $code ".($code==200?"OK":"Forbidden")."\r\nContent-Type: application/json\r\nContent-Length: ".length($result)."\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/icc/companion/ack" && $method eq "POST") {
    my $result=&webui_icc_companion_ack($body);
    my $code=($result=~/\"status\":\"unauthorized\"/)?403:200;
    print $client "HTTP/1.1 $code ".($code==200?"OK":"Forbidden")."\r\nContent-Type: application/json\r\nContent-Length: ".length($result)."\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/icc/companion/pair-request" && $method eq "POST") {
    my $result=&webui_icc_pair_request($body,$request_peer_ip);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ".length($result)."\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/icc/companion/pair-status") {
    my $result=&webui_icc_pair_status($request_query);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ".length($result)."\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/icc/companion/pair-decide" && $method eq "POST") {
    my $result=&webui_icc_pair_decide($body);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ".length($result)."\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/icc/companion/download") {
    my ($fname,$content,$message)=&webui_icc_companion_download($request_query,$request_host);
    if($fname ne "") {
     my $download_type=($fname=~/\.exe\z/i) ? "application/vnd.microsoft.portable-executable" : "application/zip";
     print $client "HTTP/1.1 200 OK\r\nContent-Type: $download_type\r\nContent-Disposition: attachment; filename=\"$fname\"\r\nContent-Length: ".length($content)."\r\n$cors\r\n";
     print $client $content;
    } else {
     $message="Companion package is unavailable" if(!defined($message) || $message eq "");
     my $err='{"status":"error","message":"'.&_webui_json_escape($message).'"}';
     print $client "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: ".length($err)."\r\n$cors\r\n$err";
    }
   }
   elsif($path eq "/api/meter/settings") {
    if($method eq "POST") {
     my $result=&webui_meter_settings_save($body);
     my $len=length($result);
     print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
    } else {
     my $result=&webui_meter_settings_load($request_query);
     my $len=length($result);
     print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
    }
   }
   elsif($path eq "/api/3d-lut/luts") {
    my $result=&webui_lg_lut_list(undef);
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/3d-lut/delete" && $method eq "POST") {
    my $result=&webui_lg_lut_delete(undef,$body);
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/3d-lut/import" && $method eq "POST") {
    my $result=&webui_3d_lut_import($request_query,$body);
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/3d-lut/solve" && $method eq "POST") {
    my $result=&webui_3d_lut_solve($body);
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/3d-lut/solve/status") {
    my $result=&webui_3d_lut_solve_status();
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/3d-lut/cube") {
    my ($fname,$content)=&webui_lg_lut_download(undef,$request_query);
    my $len=length($content);
    if($fname ne "") {
     print $client "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Disposition: attachment; filename=\"$fname\"\r\nContent-Length: $len\r\n$cors\r\n";
     print $client $content;
    } else {
     my $err="{\"status\":\"error\",\"message\":\"LUT file not found\"}";
     print $client "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: ".length($err)."\r\n$cors\r\n$err";
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
    elsif($path eq "/api/diagnostic/videos") {
     my $result=&webui_diag_asset_list("video");
     my $len=length($result);
     print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
    }
    elsif($path eq "/api/diagnostic/images") {
     my $result=&webui_diag_asset_list("image");
     my $len=length($result);
     print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
    }
    elsif($path eq "/api/diagnostic/upload" && $method eq "POST") {
     my $result=&webui_diag_asset_upload($body);
     my $len=length($result);
     print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
    }
     elsif($path eq "/api/diagnostic/video-sequence" && $method eq "POST") {
      my $result=&webui_diag_video_sequence_upload($body);
      my $len=length($result);
      print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
     }
     elsif($path eq "/api/diagnostic/delete" && $method eq "POST") {
      my $result=&webui_diag_asset_delete($body);
      my $len=length($result);
      print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
     }
  elsif($path eq "/api/ccss/create/start" && $method eq "POST") {
   my $result=&webui_ccss_create_start($body);
   my $len=length($result);
   print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
  }
  elsif($path eq "/api/ccss/create/status") {
   my $result=&webui_ccss_create_status();
   my $len=length($result);
   print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
  }
  elsif($path eq "/api/ccss/create/setup/ack" && $method eq "POST") {
   my $result=&webui_ccss_create_setup_ack($body);
   my $len=length($result);
   print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
  }
  elsif($path eq "/api/ccss/create/continue" && $method eq "POST") {
   my $result=&webui_ccss_create_continue();
   my $len=length($result);
   print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
  }
  elsif($path eq "/api/ccss/create/stop" && $method eq "POST") {
   my $result=&webui_ccss_create_stop();
   my $len=length($result);
   print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
  }
   elsif($path=~/^\/api\/ccss\/delete\/(.+)/ && $method eq "POST") {
    my $fname=$1;
    my $result=&webui_ccss_delete($fname);
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
   elsif($path eq "/api/ccss/validate" && $method eq "POST") {
    my $result=&webui_ccss_validate($body);
    my $len=length($result);
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
   }
    elsif($path eq "/api/ccss/preview" && $method eq "POST") {
     my $result=&webui_ccss_preview($body);
     my $len=length($result);
     print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$result";
    }
    elsif($path eq "/api/ccss/export" && $method eq "POST") {
     my ($ok,$status,$content_type,$download_name,$content)=&webui_ccss_export($body);
     my $len=length($content);
     if($ok) {
      print $client "HTTP/1.1 200 OK\r\nContent-Type: $content_type\r\nContent-Disposition: attachment; filename=\"$download_name\"\r\nContent-Length: $len\r\n$cors\r\n";
      print $client $content;
     } else {
      my $status_text=($status==404) ? "404 Not Found" : (($status==415) ? "415 Unsupported Media Type" : "400 Bad Request");
      print $client "HTTP/1.1 $status_text\r\nContent-Type: application/json\r\nContent-Length: $len\r\n$cors\r\n$content";
     }
    }
   else {
    my $msg="404 Not Found";
    print $client "HTTP/1.1 404 Not Found\r\nContent-Length: ".length($msg)."\r\n\r\n$msg";
   }
  }
}

###############################################
#         Meter API Functions                 #
###############################################
# :shared - this is a cross-call state machine, not a cache.
# $_meter_boot_recovery_attempted is a ONCE-ONLY latch (a private copy per
# worker would run the USB recovery once per worker), $_meter_last_reset_time
# is a cooldown between physical USB resets, and $_meter_last_good_status is
# the fallback /api/meter/status serves on a transient miss -- private copies
# make consecutive polls answer differently depending on which worker they
# land on.
my $_meter_was_detected :shared = 0;
my $_meter_boot_recovery_attempted :shared = 0;
my $_meter_last_reset_time :shared = 0;
my $_meter_last_seen_time :shared = 0;
my $_meter_last_good_status :shared = '{"detected":false,"name":null,"usb_id":null,"port":null,"port_num":null,"meters":[],"spotread_available":false}';

sub webui_meter_usb_present (@) {
 my ($usb_id)=@_;
 return 0 if(!defined($usb_id) || $usb_id eq "");
 my $lsusb=`lsusb 2>/dev/null`;
 return ($lsusb =~ /\b\Q$usb_id\E\b/i) ? 1 : 0;
}

# Pure parser: scan kernel-ring-buffer (dmesg) text for the USB enumeration /
# link-failure fingerprints that show up when a colorimeter (often behind the
# Pi's internal hub) drops off the bus. These lines -- "attempt power cycle",
# "over-current", "error -71/-32/-110", "not responding to setup address",
# "unable to enumerate" -- are almost always a signal-integrity / timing /
# runtime-PM race, NOT a genuine current overload: on the Pi 400 the meter
# shares a VL817 hub with the keyboard, and a usbcore.autosuspend race or a
# marginal SET_ADDRESS handshake produces exactly this log signature while the
# SoC voltage detector stays quiet. We therefore surface them as a single
# "USB link unstable" story rather than blaming current. (The autosuspend race
# is now suppressed at the source in rcPGenerator + the 99-colorimeter udev
# rule; this badge is the backstop for the residual cases.)
# Factored out (takes dmesg text + uptime seconds) so it is unit-testable.
# dmesg timestamps are seconds-since-boot (monotonic); age = uptime - ts lets
# us separate a one-off cold-plug enumeration retry from active-session faults.
sub webui_meter_usb_power_parse (@) {
 my ($dmesg,$uptime,$cancel_suppressions)=@_;
 $dmesg="" if(!defined $dmesg);
 $uptime=(defined $uptime && $uptime=~/^[0-9.]+$/) ? ($uptime+0) : 0;
 my @cancel_times=();
 if(ref($cancel_suppressions) eq "ARRAY") {
  @cancel_times=grep { defined($_) && $_=~/^[0-9.]+$/ } @$cancel_suppressions;
 }
 # Strong = link-down events (port power-cycled, over-current status bit
 # toggled, or the host gave up enabling the port). Historically these were
 # called "power-specific"; on this hardware they are still link/enumeration
 # failures (the over-current "change" is a PORTSC bit transition, read by the
 # xHCI driver, that fires on marginal signal/timing), so they all map to the
 # single 'link' kind now. We still count them separately only to let the
 # detail copy mention a port power-cycle when one happened.
 my @strong=(qr/attempt power cycle/i, qr/over-?current/i, qr/cannot enable.*(?:cable|hub)/i);
 # Moderate = enumeration faults that, in a cluster, indicate a marginal link.
 my @moderate=(qr/not responding to setup address/i,
   qr/not accepting address.*error\s*-71/i,
   qr/device descriptor read.*error\s*-(?:32|71|110)/i,
   qr/unable to enumerate USB device/i);
 # RECENT = age < 900s window. We base the warning on RECENT activity rather
 # than all-session totals: a "device descriptor read/8" or "unable to enumerate"
 # from 2 hours ago (when a spectro was unplugged) does NOT mean the hub is
 # unhealthy RIGHT NOW, but the old code latched onto stale totals so the badge
 # stayed lit indefinitely. Track recent counts separately per class so the
 # caller can tailor the detail copy to what actually happened.
 my ($strong_n,$moderate_n,$recent_n,$recent_strong,$recent_moderate,$suppressed_n,$last_age)=(0,0,0,0,0,0,undef);
 for my $line (split /\n/, $dmesg) {
  my $is_strong   = (grep { $line =~ $_ } @strong) ? 1 : 0;
  my $is_moderate = (!$is_strong && (grep { $line =~ $_ } @moderate)) ? 1 : 0;
  next unless($is_strong || $is_moderate);
  my ($ts)=$line=~/^\[\s*([0-9.]+)\]/;
  if(defined($ts) && @cancel_times) {
   my $cancel_generated=0;
   foreach my $cancel_ts (@cancel_times) {
    # The marker is written immediately before TERM. Allow one second for a
    # kernel event already in flight and ten seconds for TERM's 5s grace,
    # final SIGKILL, and xHCI teardown. This intentionally narrow window does
    # not hide a fault that preceded Stop or continues after cancellation.
    if($ts >= ($cancel_ts-1) && $ts <= ($cancel_ts+10)) {
     $cancel_generated=1;
     last;
    }
   }
   if($cancel_generated) {
    $suppressed_n++;
    next;
   }
  }
  $strong_n++   if($is_strong);
  $moderate_n++ if($is_moderate);
  next unless defined $ts;
  my $age=$uptime-$ts; $age=0 if($age<0);
  if($age < 900) {
   $recent_n++;
   $recent_strong++   if($is_strong);
   $recent_moderate++ if($is_moderate);
  }
  $last_age=$age if(!defined $last_age || $age < $last_age);
 }
 my $total=$strong_n+$moderate_n;
 # Warn ONLY on recent activity: any recent strong (link-down) hit, or a fresh
 # cluster (>=4) of recent enumeration faults. Once the offending device is
 # gone and the 900s window slides past, the badge clears on its own. 'kind'
 # is always 'link' now: the strong-class patterns are link/enumeration faults
 # on this hardware, not current faults, so the operator-facing copy never
 # blames "overloaded". 'power_cycle' is reported as a separate boolean so the
 # detail string can mention a port reset when one actually happened.
 my $warning=($recent_strong>0 || $recent_moderate>=4) ? 1 : 0;
 return {warning=>$warning, total=>$total, strong=>$strong_n, moderate=>$moderate_n,
   recent=>$recent_n, recent_strong=>$recent_strong, recent_moderate=>$recent_moderate,
   suppressed=>$suppressed_n,
   last_age=>(defined $last_age ? int($last_age) : -1), kind=>'link',
   power_cycle=>($recent_strong>0)?1:0};
}

my %_meter_usb_power_cache;
my $_meter_series_cancel_usb_suppress_file="/tmp/meter_series_cancel_usb_suppress.uptime";
# Cached gatherer: reads dmesg + /proc/uptime (cheap, but the meter status is
# polled often, so cache for 20s). dmesg_restrict=0 on this image, so the
# unprivileged daemon can read the ring buffer directly.
sub webui_meter_usb_power_health (@) {
 my $now=time();
 my $cancel_suppression_data="";
 if(open(my $cf,"<",$_meter_series_cancel_usb_suppress_file)) {
  local $/;
  $cancel_suppression_data=<$cf>;
  close($cf);
 }
 return $_meter_usb_power_cache{result}
  if($_meter_usb_power_cache{ts} && ($now-$_meter_usb_power_cache{ts})<20
   && $_meter_usb_power_cache{result}
   && ($_meter_usb_power_cache{cancel_suppression_data}||"") eq $cancel_suppression_data);
 my $up=0;
 if(open(my $uf,"<","/proc/uptime")){ my $l=<$uf>; close($uf); ($up)=split /\s+/, ($l||""); }
 my @cancel_suppressions=grep {
  $_=~/^[0-9.]+$/ && ($_+0) <= ($up+1) && ($up-($_+0)) < 920
 } split(/\s+/,$cancel_suppression_data);
 my $dmesg=`timeout 3 /bin/dmesg 2>/dev/null`;
 my $res=&webui_meter_usb_power_parse($dmesg,$up,\@cancel_suppressions);
 %_meter_usb_power_cache=(ts=>$now, result=>$res, cancel_suppression_data=>$cancel_suppression_data);
 return $res;
}

# --- Simulated meter -------------------------------------------------------
# A virtual demo/testing meter offered when NO physical meter is detected.
# Reads are produced by /usr/bin/spotread_sim (spawned by meter_session.sh /
# meter_series.sh in place of the real spotread when port 99 is selected),
# which synthesizes XYZ from the pattern the generator is actually displaying
# (recorded by webui_meter_sim_pattern_record below).
our $_meter_sim_port="99";
my $_meter_sim_flag_primary="/var/lib/PGenerator/meter_simulation.flag";
my $_meter_sim_flag_fallback="/tmp/meter_simulation.flag";
my $_meter_sim_pattern_file="/tmp/pgen_sim_pattern.json";

sub webui_meter_simulation_enabled (@) {
 return 1 if(-f $_meter_sim_flag_primary || -f $_meter_sim_flag_fallback);
 return 0;
}

sub webui_meter_simulation_set (@) {
 my ($body)=@_;
 $body="" if(!defined($body));
 my $enable=($body=~/"enabled"\s*:\s*(?:true|1|"1")/i) ? 1 : 0;
 if($enable) {
  my $written=0;
  foreach my $path ($_meter_sim_flag_primary,$_meter_sim_flag_fallback) {
   if(open(my $fh,">",$path)) { print $fh "1\n"; close($fh); chmod(0666,$path); $written=1; last; }
  }
  return '{"status":"error","message":"Could not persist the simulation flag"}' if(!$written);
  &log("WebUI: simulated meter enabled");
 } else {
  unlink($_meter_sim_flag_primary,$_meter_sim_flag_fallback);
  # Tear down any live simulated session so a later real meter starts clean.
  system("sudo pkill -9 -x spotread_sim 2>/dev/null");
  &log("WebUI: simulated meter disabled");
 }
 return '{"status":"ok","enabled":'.($enable?"true":"false").'}';
}

sub webui_meter_port_is_simulated (@) {
 my ($port)=@_;
 $port="" if(!defined($port));
 $port=~s/[^0-9]//g;
 return ($port ne "" && $port eq $_meter_sim_port) ? 1 : 0;
}

# AutoCal launch gate: block when the run would use the simulated meter,
# either explicitly (port 99 in the payload) or implicitly (simulation is
# enabled and no real meter is detected, so the sim meter is the only one the
# worker could resolve).
sub webui_meter_autocal_blocked_for_simulation (@) {
 my ($body)=@_;
 $body="" if(!defined($body));
 my $port="";
 $port=$1 if($body=~/"(?:measurement_meter_port|meter_port)"\s*:\s*"?(\d+)"?/);
 return 1 if(&webui_meter_port_is_simulated($port));
 return 0 if(!&webui_meter_simulation_enabled());
 my $status=&webui_meter_status();
 return 1 if(defined($status) && $status=~/"simulated"\s*:\s*true/);
 return 0;
}

# Status JSON shaped exactly like a wrapper --detect result. The meter entry
# field order matches the regexes in webui_meter_status_prune_disconnected /
# webui_meter_port_is_spectro (usb_id null keeps it through lsusb pruning).
sub webui_meter_simulated_status_json (@) {
 my $entry='{"port_num":"'.$_meter_sim_port.'","port":"'.$_meter_sim_port.'","usb_id":null,"name":"Simulated Meter","meter_type":"colorimeter"}';
 return '{"detected":true,"name":"Simulated Meter","usb_id":null,"port":"'.$_meter_sim_port.'","port_num":"'.$_meter_sim_port.'","meter_type":"colorimeter","meters":['.$entry.'],"spotread_available":true,"simulated":true}';
}

# Record the pattern currently on the generator so spotread_sim can synthesize
# a reading from what is really displayed. Written on every pattern change
# while simulation is enabled (atomic replace; world-readable for the root
# helper scripts).
sub webui_meter_sim_pattern_record (@) {
 my (%f)=@_;
 return if(!&webui_meter_simulation_enabled());
 my $name=defined($f{name}) ? $f{name} : "";
 $name=~s/[^A-Za-z0-9_ .:-]//g;
 my $json='{"ts":'.time().',"name":"'.$name.'"';
 foreach my $k (qw(r g b input_max)) {
  $json.=',"'.$k.'":'.int($f{$k}) if(defined($f{$k}) && $f{$k}=~/^-?\d+(?:\.\d+)?$/);
 }
 $json.=',"signal_mode":"'.$f{signal_mode}.'"' if(defined($f{signal_mode}) && $f{signal_mode}=~/^[a-z0-9]+$/);
 $json.=',"source_range":"'.$f{source_range}.'"' if(defined($f{source_range}) && $f{source_range}=~/^(?:LIMITED|FULL)$/);
 $json.=',"max_luma":'.int($f{max_luma}) if(defined($f{max_luma}) && $f{max_luma}=~/^\d+(?:\.\d+)?$/);
 $json.=',"provider":"'.$f{provider}.'"' if(defined($f{provider}) && $f{provider}=~/^[a-z]+$/);
 $json.=',"complex":1' if($f{complex});
 $json.='}';
 my $tmp=$_meter_sim_pattern_file.".$$.tmp";
 if(open(my $fh,">",$tmp)) {
  print $fh $json;
  close($fh);
  chmod(0666,$tmp);
  rename($tmp,$_meter_sim_pattern_file);
 }
}

sub webui_meter_simulate_spectro_enabled (@) {
 foreach my $path ("/tmp/meter_settings.json", "/var/lib/PGenerator/meter_settings.json", "/usr/share/PGenerator/meter_settings.json") {
  next unless(-f $path);
  my $json="";
  if(open(my $fh,"<",$path)) { local $/; $json=<$fh>; close($fh); }
  next if($json eq "");
  return 1 if($json =~ /"simulate_spectro"\s*:\s*(?:true|1|"1")/i);
 }
 return 0;
}

sub webui_meter_status_apply_overrides (@) {
 my ($json)=@_;
 return $json if(!defined($json) || $json eq "");
 if(&webui_meter_simulate_spectro_enabled()) {
  $json =~ s/"meter_type"\s*:\s*"[^"]*"/"meter_type":"spectro"/g;
 }
 # Surface meter USB link/enumeration instability seen in the kernel log so
 # the operator knows a failed/garbage read is a USB link issue (not a
 # calibration fault). On this hardware the "over-current"/"power cycle"/
 # "error -71" log lines are almost always a signal-integrity / runtime-PM
 # race on the shared internal hub, NOT real over-current, so the copy never
 # blames current. Only added when a warning is active so a healthy link does
 # not bloat every status poll.
 my $h=&webui_meter_usb_power_health();
 if(ref($h) eq 'HASH' && $h->{warning} && $json=~/\}\s*$/) {
  my $age=$h->{last_age};
  my $when=($age<0) ? "this session"
   : ($age<90) ? "just now"
   : ($age<5400) ? sprintf("%dm ago",int($age/60+.5))
   : sprintf("%.1fh ago",$age/3600);
  # Single 'link' story. Mention a port power-cycle when one actually happened
  # (it is the most dramatic symptom and worth flagging) but frame it as a link
  # reset, not a current overload. Use the RECENT count (last 900s) so the
  # number reflects what the hub is doing now, not stale session totals.
  my $pc=(defined $h->{power_cycle} && $h->{power_cycle}) ? 'The hub even power-cycled a port - ' : '';
  my $detail=sprintf("USB link unstable - a device is not enumerating reliably on the hub (%d recent USB errors, last %s). %sThis is usually a cable, hub port, or signal-integrity issue, not a power overload - try a different port/cable or a powered USB hub.", $h->{recent}, $when, $pc);
  $detail=~s/(["\\])/\\$1/g;
  $json=~s/\}\s*$/,"usb_power_warning":true,"usb_power_detail":"$detail","usb_power_kind":"link"}/;
 }
 return $json;
}

# Drop cached meters whose USB device is no longer present. The status cache
# is served while a meter session is alive (a live probe would disturb the
# running spotread), which previously meant an unplugged meter stayed listed
# - and selectable - indefinitely, even across page reloads. lsusb does not
# touch the meters, so presence pruning is safe mid-session.
sub webui_meter_status_prune_disconnected (@) {
 my ($json)=@_;
 return $json if(!defined($json) || $json!~/"detected"\s*:\s*true/);
 my @entries;
 while($json=~/(\{"port_num":"[^"]*","port":"[^"]*","usb_id":(?:null|"([^"]*)"),"name":"[^"]*","meter_type":"[^"]*"(?:,"physical_port":"[^"]*")?\})/g) {
  push @entries,{raw=>$1,usb_id=>(defined($2)?$2:"")};
 }
 return $json if(!@entries);
 my $lsusb=`lsusb 2>/dev/null`;
 my @kept=grep { $_->{usb_id} eq "" || $lsusb=~/\b\Q$_->{usb_id}\E\b/i } @entries;
 return $json if(scalar(@kept)==scalar(@entries));
 if(!@kept) {
  return '{"detected":false,"name":null,"usb_id":null,"port":null,"port_num":null,"meters":[],"spotread_available":false}';
 }
 my $meters=join(",",map { $_->{raw} } @kept);
 my $first=$kept[0]->{raw};
 my ($port_num)=$first=~/"port_num":"([^"]*)"/;
 my ($port)=$first=~/"port":"([^"]*)"/;
 my ($usb_id)=$first=~/"usb_id":(?:null|"([^"]*)")/;
 my ($name)=$first=~/"name":"([^"]*)"/;
 my ($mtype)=$first=~/"meter_type":"([^"]*)"/;
 my $spot=($json=~/"spotread_available"\s*:\s*true/)?"true":"false";
 my $usb_field=defined($usb_id)?'"'.$usb_id.'"':"null";
 return '{"detected":true,"name":"'.($name||"").'","usb_id":'.$usb_field.',"port":"'.($port||"").'","port_num":"'.($port_num||"").'","meter_type":"'.($mtype||"").'","meters":['.$meters.'],"spotread_available":'.$spot.'}';
}

sub webui_meter_status (@) {
 my $spotread_running=`pgrep -x spotread 2>/dev/null; pgrep -x spotread_sim 2>/dev/null`;
 my $session_alive=&webui_meter_session_alive();
 my $busy=(&webui_meter_series_alive() || $spotread_running=~/\d/ || $session_alive) ? 1 : 0;
 if($busy && $_meter_last_good_status =~ /"detected"\s*:\s*true/) {
  my $pruned=&webui_meter_status_prune_disconnected($_meter_last_good_status);
  if($pruned ne $_meter_last_good_status) {
   $_meter_last_good_status=$pruned;
   if($pruned!~/"detected"\s*:\s*true/) {
    $_meter_was_detected=0;
    $_meter_last_seen_time=0;
   }
  }
  return &webui_meter_status_apply_overrides($_meter_last_good_status);
 }
 # Busy with no real meter on record: a simulated session (spotread_sim) may
 # own the "meter" right now. Keep reporting the virtual instrument instead
 # of probing (the probe is real-USB only and would report detected:false).
 if($busy && &webui_meter_simulation_enabled()) {
  return &webui_meter_status_apply_overrides(&webui_meter_simulated_status_json());
 }
 my $json=`sudo bash $_meter_wrapper --detect 2>/dev/null`;
 chomp($json);
 $json='{"detected":false,"name":null,"usb_id":null,"port":null,"port_num":null,"meters":[],"spotread_available":false}' if($json eq "" || $json!~/^\{/);
 # Keep the last known-good detection through transient startup hiccups, but
 # do not auto-reset USB here. Aggressive reset/re-enumeration from the status
 # poller can knock an otherwise connected meter fully offline.
 if($json=~/"detected"\s*:\s*true/) {
  $_meter_was_detected=1;
  $_meter_boot_recovery_attempted=0;
  $_meter_last_seen_time=time();
  $_meter_last_good_status=$json;
  return &webui_meter_status_apply_overrides($json);
 }
 if($_meter_was_detected) {
  my $age=time()-($_meter_last_seen_time||0);
  my $last_usb_id="";
  $last_usb_id=$1 if($_meter_last_good_status =~ /"usb_id"\s*:\s*"([^"]+)"/);
  my $usb_still_present=($last_usb_id ne "") ? &webui_meter_usb_present($last_usb_id) : 0;
  if($last_usb_id ne "" && !$usb_still_present) {
   $_meter_was_detected=0;
   $_meter_boot_recovery_attempted=0;
   $_meter_last_seen_time=0;
    $_meter_last_good_status='{"detected":false,"name":null,"usb_id":null,"port":null,"port_num":null,"meters":[],"spotread_available":false}';
   return $json;
  }
  if($busy || ($usb_still_present && $age < 15)) {
   &log("WebUI: transient meter probe miss, keeping last known detection") if($busy || $age < 15);
   return &webui_meter_status_apply_overrides($_meter_last_good_status);
  }
 }
 # No physical meter present: offer the simulated meter when it is enabled.
 # A detected real meter always wins (the branches above return first).
 if(&webui_meter_simulation_enabled() && $json!~/"detected"\s*:\s*true/) {
  return &webui_meter_status_apply_overrides(&webui_meter_simulated_status_json());
 }
 return &webui_meter_status_apply_overrides($json);
}

sub webui_meter_port_is_spectro (@) {
 my ($port)=@_;
 $port="" if(!defined($port));
 $port=~s/[^0-9]//g;
 my $json=&webui_meter_status();
 return 0 if(!defined($json) || $json eq "");
 while($json=~/\{"port_num":"([^"]*)","port":"[^"]*","usb_id":(?:null|"[^"]*"),"name":"[^"]*","meter_type":"([^"]*)"(?:,"physical_port":"[^"]*")?\}/g) {
  my $meter_port=$1;
  my $meter_type=lc($2||"");
  next if($port ne "" && $meter_port ne $port);
  return 1 if($meter_type eq "spectro");
 }
 if($port eq "" && $json=~/"meter_type"\s*:\s*"spectro"/i) {
  return 1;
 }
 return 0;
}

sub webui_meter_usb_id_for_port (@) {
 my ($port)=@_;
 $port="" if(!defined($port));
 $port=~s/[^0-9]//g;
 # AutoCal workers intentionally send only the selected spotread port. Reuse
 # the live session identity or last successful inventory first so every patch
 # read does not launch a fresh spotread enumeration probe.
 if(-f $_meter_session_config_file && open(my $cfh,"<",$_meter_session_config_file)) {
  local $/;
  my $config=<$cfh>;
  close($cfh);
  my @fields=split(/\|/,$config||"",-1);
  my $config_port=defined($fields[4]) ? $fields[4] : "";
  my $config_usb=defined($fields[7]) ? lc($fields[7]) : "";
  $config_usb=~s/\s+$//;
  return $config_usb
   if(($port eq "" || $config_port eq $port) && $config_usb=~/^[0-9a-f]{4}:[0-9a-f]{4}$/);
 }
 my $json=$_meter_last_good_status;
 $json=&webui_meter_status() if(!defined($json) || $json eq "" || $json!~/"detected"\s*:\s*true/);
 return "" if(!defined($json) || $json eq "");
 while($json=~/\{"port_num":"([^"]*)","port":"[^"]*","usb_id":(?:null|"([^"]*)"),"name":"[^"]*","meter_type":"[^"]*"(?:,"physical_port":"[^"]*")?\}/g) {
  my ($meter_port,$usb_id)=($1,lc($2||""));
  next if($port ne "" && $meter_port ne $port);
  return $usb_id if($usb_id=~/^[0-9a-f]{4}:[0-9a-f]{4}$/);
 }
 return lc($1) if($port eq "" && $json=~/"usb_id"\s*:\s*"([0-9a-fA-F]{4}:[0-9a-fA-F]{4})"/);
 return "";
}

sub webui_meter_is_spyderx (@) {
 my ($usb_id,$port)=@_;
 $usb_id="" if(!defined($usb_id));
 $usb_id=lc($usb_id);
 $usb_id=&webui_meter_usb_id_for_port($port) if($usb_id eq "");
 return $usb_id eq "085c:0a00" ? 1 : 0;
}

sub webui_spyderx_native_display_type (@) {
 my ($display_type_key)=@_;
 my $key=lc($display_type_key||"");
 return "e" if($key=~/^lcd_wled(?:_|$)/);
 return "b" if($key=~/^lcd_rgbled(?:_|$)/);
 return "i" if($key=~/^lcd_gbled(?:_|$)/);
 # SpyderX has no native OLED, AMOLED, plasma, projector, CCFL or QD-OLED spectral
 # calibration. Its General mode is the least-assumptive native fallback.
 return "l";
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
	 return 0 unless(-d "/proc/$pid");
	 my $cmd="";
	 if(open(my $fh,"<","/proc/$pid/cmdline")) {
	  local $/;
	  $cmd=<$fh>;
	  close($fh);
	  $cmd=~tr/\0/ /;
	 }
	 return 0 if($cmd ne "" && $cmd!~/meter_session\.sh/);
	 return $pid;
}

sub webui_meter_session_config_matches (@) {
 my ($want)=@_;
 return 0 unless(-f $_meter_session_config_file);
 my $cur="";
 if(open(my $fh,"<",$_meter_session_config_file)) { local $/; $cur=<$fh>; close($fh); }
 chomp $cur;
 return $cur eq $want ? 1 : 0;
}

sub webui_meter_session_fifo_ready () {
 return 0 unless(-p $_meter_session_fifo);
 return 0 unless(&webui_meter_session_alive());
 if(sysopen(my $fh,$_meter_session_fifo,O_WRONLY | O_NONBLOCK)) {
  close($fh);
  return 1;
 }
 return 0;
}

sub webui_meter_session_start_ready () {
 return 0 unless(-f $_meter_session_start_ready_file);
 return 0 unless(&webui_meter_session_alive());
 return 1;
}

sub webui_meter_read_state_write (@) {
 my ($json)=@_;
 $json='{"status":"idle"}' if(!defined($json) || $json eq "");
 if(open(my $fh,">",$_meter_read_file)) {
  print $fh $json;
  close($fh);
  chmod(0666,$_meter_read_file);
 }
}

sub webui_meter_read_state_read () {
 my $json="";
 return $json unless(-f $_meter_read_file);
 if(open(my $fh,"<",$_meter_read_file)) {
  local $/;
  $json=<$fh>;
  close($fh);
 }
 chomp $json;
 return $json;
}

sub webui_meter_session_start_error_json (@) {
 my ($config)=@_;
 my $config_ready=&webui_meter_session_config_matches($config) ? 1 : 0;
 my $fifo_ready=&webui_meter_session_fifo_ready() ? 1 : 0;
 my $start_ready=&webui_meter_session_start_ready() ? 1 : 0;
 my $state=&webui_meter_read_state_read();
 my $state_log=$state;
 $state_log='(none)' if(!defined($state_log) || $state_log eq "");
 $state_log=~s/\s+/ /g;
 &log("WebUI: meter session failed to start (config_ready=$config_ready fifo_ready=$fifo_ready start_ready=$start_ready state=$state_log)");
 if($state=~/"status"\s*:\s*"error"/) {
  &webui_meter_read_state_write($state);
  return $state;
 }
 return '{"status":"error","message":"Meter session failed to start"}';
}

sub webui_meter_series_ready_file (@) {
 my ($series_id)=@_;
 $series_id="" if(!defined($series_id));
 $series_id=~s/[^A-Za-z0-9_.-]//g;
 return "" if($series_id eq "");
 return "/tmp/meter_series_ready_${series_id}.signal";
}

sub webui_meter_series_ready_cleanup (@) {
 my @paths=glob($_meter_series_ready_glob);
 unlink(@paths) if(@paths);
}

sub webui_meter_series_stop_file (@) {
 my ($series_id)=@_;
 $series_id="" if(!defined($series_id));
 $series_id=~s/[^A-Za-z0-9_.-]//g;
 return "" if($series_id eq "");
 return "/tmp/meter_series_stop_${series_id}.signal";
}

sub webui_meter_series_stop_cleanup (@) {
 my @paths=glob($_meter_series_stop_glob);
 unlink(@paths) if(@paths);
}

sub webui_pattern_stop_guard_set (@) {
 my ($reason)=@_;
 $reason="" if(!defined($reason));
 $reason=~s/[^A-Za-z0-9_.:-]+/_/g;
 if(open(my $fh,">",$_webui_pattern_stop_guard_file)) {
  print $fh time()." ".$reason;
  close($fh);
  chmod(0666,$_webui_pattern_stop_guard_file);
 }
}

sub webui_pattern_stop_guard_clear (@) {
 unlink($_webui_pattern_stop_guard_file) if(-e $_webui_pattern_stop_guard_file);
}

sub webui_pattern_stop_guard_active (@) {
 return (-f $_webui_pattern_stop_guard_file) ? 1 : 0;
}

sub webui_pattern_stop_guard_allows_patch (@) {
 my ($body)=@_;
 return 0 if(!defined($body));
 return 1 if($body=~/"allow_after_stop"\s*:\s*true/i);
 return 0;
}

sub webui_meter_series_pids (@) {
 return map { $_->{"pid"} } &webui_meter_series_processes();
}

sub webui_meter_series_processes (@) {
 my @procs;
 foreach my $path (glob("/proc/[0-9]*/cmdline")) {
  next unless($path=~/\/proc\/(\d+)\/cmdline$/);
  my $pid=$1;
  my $cmd="";
  if(open(my $fh,"<",$path)) {
   local $/;
   binmode($fh);
   $cmd=<$fh>;
   close($fh);
  }
  next if($cmd eq "");
  next unless($cmd=~/(?:^|\0)\/usr\/bin\/meter_series\.sh(?:\0|$)/);
  my @args=split(/\0/,$cmd);
  my $series_id="";
  for(my $i=0;$i<=$#args;$i++) {
   if($args[$i] eq "/usr/bin/meter_series.sh" && defined($args[$i+1])) {
    $series_id=$args[$i+1];
    last;
   }
  }
  $series_id=~s/[^A-Za-z0-9_.-]//g;
  push @procs,{ "pid"=>int($pid), "series_id"=>$series_id };
 }
 return @procs;
}

sub webui_proc_pgrp (@) {
 my ($pid)=@_;
 $pid=int($pid || 0);
 return 0 if($pid<=0);
 my $stat="";
 if(open(my $fh,"<","/proc/$pid/stat")) {
  local $/;
  $stat=<$fh>;
  close($fh);
 }
 return 0 if($stat eq "");
 return int($1) if($stat=~/^\d+\s+\(.*\)\s+\S+\s+\d+\s+(\d+)/);
 return 0;
}

sub webui_meter_series_alive (@) {
 return scalar(&webui_meter_series_pids()) ? 1 : 0;
}

sub webui_meter_series_kill (@) {
 my ($signal)=@_;
 $signal="-TERM" if(!defined($signal) || $signal eq "");
 my @pids=&webui_meter_series_pids();
 return 0 unless(@pids);
 my %targets;
 my $self_pgrp=getpgrp(0);
 foreach my $pid (@pids) {
  $pid=int($pid);
  next if($pid<=0);
  $targets{$pid}=1;
  my $pgrp=&webui_proc_pgrp($pid);
  $targets{"-$pgrp"}=1 if($pgrp>1 && $pgrp!=$self_pgrp);
 }
 my $target_list=join(" ",sort { $a <=> $b } keys %targets);
 system("sudo kill $signal $target_list 2>/dev/null") if($target_list ne "");
 return scalar(@pids);
}

sub webui_meter_series_signal_stop (@) {
 my %series_ids;
 if(-f $_meter_series_file) {
  my $json="";
  if(open(my $fh,"<",$_meter_series_file)) { local $/; $json=<$fh>; close($fh); }
  $series_ids{$1}=1 if($json=~/"series_id"\s*:\s*"([^"]+)"/);
 }
 foreach my $proc (&webui_meter_series_processes()) {
  my $series_id=$proc->{"series_id"} || "";
  $series_ids{$series_id}=1 if($series_id ne "");
 }
 my $count=0;
 foreach my $series_id (keys %series_ids) {
  my $stop_file=&webui_meter_series_stop_file($series_id);
  next if($stop_file eq "");
  if(open(my $fh,">",$stop_file)) {
   print $fh time();
   close($fh);
   chmod(0666,$stop_file);
   $count++;
  }
 }
 return $count;
}

sub webui_meter_series_cancel_state (@) {
 return unless(-f $_meter_series_file);
 my $json="";
 if(open(my $fh,"<",$_meter_series_file)) { local $/; $json=<$fh>; close($fh); }
 if($json=~/"status"\s*:\s*"(?:running|setup)"/) {
  $json=~s/"status"\s*:\s*"(?:running|setup)"/"status":"cancelled"/;
  $json=~s/,\s*"awaiting_ready"\s*:\s*true//g;
  $json=~s/,\s*"awaiting_ready_reason"\s*:\s*"[^"]*"//g;
  $json=~s/"current_name"\s*:\s*"[^"]*"/"current_name":"Cancelled"/;
  if(open(my $fh,">",$_meter_series_file)) { print $fh $json; close($fh); chmod(0666,$_meter_series_file); }
 }
}

sub webui_meter_session_ready_cleanup () {
 unlink($_meter_session_ready_file) if(-e $_meter_session_ready_file);
 unlink($_meter_session_start_ready_file) if(-e $_meter_session_start_ready_file);
}

sub webui_meter_setup_ack (@) {
 my ($body)=@_;
 my $step_id="";
 $step_id=$1 if($body=~/"step_id"\s*:\s*"?(\d+)"?/);
 return '{"status":"error","message":"Missing step_id"}' if($step_id eq "");
 my $json=&webui_meter_read_state_read();
 return '{"status":"ignored","message":"No setup step active"}' if($json eq "" || $json!~/"status"\s*:\s*"setup"/i);
 # Only the current step's id may advance the session; stale acks are ignored.
 return '{"status":"ignored","message":"Step already advanced"}' if($json!~/"step_id"\s*:\s*$step_id\b/);
 if(open(my $fh,">",$_meter_session_ack_file)) {
  print $fh $step_id;
  close($fh);
  chmod(0666,$_meter_session_ack_file);
  return '{"status":"ok"}';
 }
 return '{"status":"error","message":"Could not signal setup ack"}';
}

sub webui_meter_read_ready (@) {
 my $json=&webui_meter_read_state_read();
 return '{"status":"error","message":"Manual read is not waiting for device readiness"}' if($json eq "" || $json!~/"awaiting_ready"\s*:\s*true/i);
 if(open(my $fh,">",$_meter_session_ready_file)) {
  print $fh time();
  close($fh);
  chmod(0666,$_meter_session_ready_file);
  return '{"status":"ok","message":"Measurement resumed"}';
 }
 return '{"status":"error","message":"Failed to signal manual read readiness"}';
}

sub webui_meter_session_send_command (@) {
 my ($command)=@_;
 return 0 if(!defined($command) || $command eq "");
 return 0 unless(-p $_meter_session_fifo);
 return 0 unless(&webui_meter_session_alive());
 if(sysopen(my $fh,$_meter_session_fifo,O_WRONLY | O_NONBLOCK)) {
  print $fh $command;
  close($fh);
  return 1;
 }
 &log("WebUI: meter session FIFO write failed: $!");
 return 0;
}

# Wait for spotread to be really gone after a kill, instead of assuming a fixed
# sleep is long enough.
#
# A SIGKILLed spotread does not release its USB claim on the colorimeter the
# instant the signal is delivered -- the kernel still has to tear down the
# libusb handle. Spawning a new spotread inside that window is how a stalled
# read happens: the new process cannot talk to the instrument, Argyll reports
# "Spot read failed due to communication problem", and dmesg is completely
# clean (no -71/-32) because nothing is wrong electrically -- the device claim
# is simply still held. The session layer then sits on its read timeout
# (90s normal / 120s <=25 IRE / 140s <=5 IRE, +30s for the comm retry) with the
# measurement patch parked on screen, and meter_series.sh layers two more
# retries on top, so ONE contention event can hold a single patch for minutes.
# Observed on hardware 2026-07-25: session 20485 (04:08:16) was killed without
# its cleanup ever running -- no "STOP received", no "cleanup: tearing down
# spotread" in meter_session.log, unlike every other transition in that log --
# then session 24582 spawned a second spotread at 04:11:27 and the next 100%
# read died after the full 120s.
sub webui_meter_spotread_settled (@) {
 my ($limit_ms)=@_;
 $limit_ms=4000 if(!defined($limit_ms) || $limit_ms <= 0);
 my $waited=0;
 while($waited < $limit_ms) {
  my $still=`pgrep -x spotread 2>/dev/null; pgrep -x spotread_sim 2>/dev/null`;
  if(!defined($still) || $still!~/\d/) {
   return 1;
  }
  # A lingering simulator holds no USB claim; a -9 is always safe for it.
  system("sudo pkill -9 -x spotread_sim 2>/dev/null") if($still=~/\d/ && `pgrep -x spotread 2>/dev/null`!~/\d/);
  Time::HiRes::sleep(0.1);
  $waited+=100;
 }
 &log("WebUI: spotread still present ${limit_ms}ms after kill -- starting a new session anyway may stall the next read");
 return 0;
}

sub webui_meter_session_stop (@) {
	 my $state=&webui_meter_read_state_read();
	 my $setup_blocked=($state=~/"status"\s*:\s*"setup"/i || $state=~/"setup_busy"\s*:\s*true/i) ? 1 : 0;
	 # Try graceful STOP via FIFO first (lets the daemon quit spotread cleanly).
	 &webui_meter_session_send_command("STOP\n") if(-p $_meter_session_fifo);
 # Wait briefly for the daemon to exit on its own.
 # Wait for the daemon to tear down on its own. Its cleanup quits spotread
 # cleanly and waits for any in-flight USB read to finish before killing it;
 # force-killing spotread mid-transaction wedges the Pi's USB controller
 # ("communication failed during init" next time), so allow several seconds.
 my $waited=0;
	 my $wait_limit=$setup_blocked ? 5 : 130;
	 while($waited < $wait_limit && &webui_meter_session_alive()) {
	  Time::HiRes::sleep(0.1);
	  $waited++;
	 }
 # Still alive after the graceful path: TERM (its trap re-runs the graceful
 # teardown), then escalate to SIGKILL only as a last resort.
 if(&webui_meter_session_alive()) {
  system("sudo pkill -TERM -f 'meter_session.sh' 2>/dev/null");
  my $tw=0;
  while($tw < 30 && &webui_meter_session_alive()) {
   Time::HiRes::sleep(0.1);
   $tw++;
  }
 }
 if(&webui_meter_session_alive()) {
  system("sudo pkill -9 -f 'meter_session.sh' 2>/dev/null");
  Time::HiRes::sleep(0.2);
 }
 # Backstop: only -9 a spotread/helper that is STILL running (orphaned), so we
 # never kill a fresh read mid-USB transaction.
	 system("sudo pkill -9 -x spotread 2>/dev/null");
	 system("sudo pkill -9 -f 'script.*spotread' 2>/dev/null");
	 system("sudo pkill -9 -f 'cat.*spotread_cmd' 2>/dev/null");
		 # Do not return until the instrument is actually free: the next request
		 # may start a new session immediately, and an overlapping spotread is a
		 # multi-minute stall (see webui_meter_spotread_settled).
		 &webui_meter_spotread_settled(4000);
		 &webui_meter_session_ready_cleanup();
		 unlink($_meter_session_pid_file, $_meter_session_config_file, $_meter_session_fifo);
	}

sub webui_meter_session_stop_only (@) {
 &webui_meter_session_stop() if(&webui_meter_session_alive());
 system("sudo pkill -9 -x spotread 2>/dev/null");
 system("sudo pkill -9 -f 'script.*spotread' 2>/dev/null");
 system("sudo pkill -9 -f 'cat.*spotread_cmd' 2>/dev/null");
 &webui_meter_spotread_settled(4000);
 &webui_meter_session_ready_cleanup();
 unlink($_meter_session_pid_file, $_meter_session_config_file, $_meter_session_fifo);
 &webui_meter_read_state_write('{"status":"idle","message":"Meter session reset"}');
 return '{"status":"ok","message":"Meter session reset"}';
}

sub webui_meter_session_start (@) {
 my ($display_type,$ccss_file,$refresh_rate,$disable_aio,$config,$signal_mode,$max_luma,$meter_port,$require_device_ready,$averaging,$meter_usb_id,$observer,$pattern_provider)= @_;
 $averaging="" if(!defined($averaging));
 $meter_usb_id="" if(!defined($meter_usb_id));
 $meter_usb_id="" if($meter_usb_id!~/^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$/);
 $observer="1931_2" if(!defined($observer) || $observer!~/^(?:1931_2|1964_10|2015_2|2015_10)$/);
 $pattern_provider="local" if(!defined($pattern_provider) || $pattern_provider ne "companion");
 my $aio_flag=$disable_aio ? "1" : "0";
 $require_device_ready=0 if(!defined($require_device_ready) || $require_device_ready!~/^1$/);
 $signal_mode=&webui_pattern_signal_mode("") if(!defined($signal_mode) || $signal_mode eq "");
 $max_luma=&webui_pattern_max_luma("") if(!defined($max_luma) || $max_luma eq "");
 my $max_attempts=3;
 for(my $attempt=1;$attempt<=$max_attempts;$attempt++) {
  # Start from a clean slate. Only the session daemon itself should write the
  # advertised config file once it has actually grabbed the lock. Report
  # success only after startup has reached either a real ready state or an
  # explicit awaiting-ready prompt that the UI can surface to the user.
  &webui_meter_session_ready_cleanup();
  unlink($_meter_session_pid_file, $_meter_session_config_file, $_meter_session_fifo);
  &webui_meter_read_state_write('{"status":"starting"}');
  &log("WebUI: meter session startup retry attempt $attempt/$max_attempts") if($attempt > 1);
  # Launch detached as root. The daemon writes its own PID/config files once it
  # grabs the lock; wait for an actionable startup state before reporting success.
  my $started_at=time();
  system("setsid sudo /bin/bash $_meter_session '$display_type' '$ccss_file' '$refresh_rate' '$aio_flag' '$signal_mode' '$max_luma' '$meter_port' '900' '$require_device_ready' '$averaging' '$meter_usb_id' '$observer' '$pattern_provider' </dev/null >/dev/null 2>&1 &");
  my $waited=0;
  # Some CCSS/meter combinations trigger spotread refresh calibration on first
  # start and can legitimately take 35-45 seconds before the helper reaches a
  # real ready state or emits an explicit operator prompt.
  while($waited < 900) {
   my $state="";
   my $state_mtime=0;
   my $awaiting_ready=0;
   my $state_error=0;
   if(-f $_meter_read_file) {
    if(open(my $fh,"<",$_meter_read_file)) { local $/; $state=<$fh>; close($fh); }
    $state_mtime=(stat($_meter_read_file))[9] || 0;
    if($state_mtime >= $started_at) {
     $awaiting_ready=1 if($state=~/"awaiting_ready"\s*:\s*true/i || $state=~/"status"\s*:\s*"setup"/i);
     $state_error=1 if($state=~/"status"\s*:\s*"error"/);
    }
   }
   last if($state_error);
   last if(&webui_meter_session_config_matches($config) && &webui_meter_session_fifo_ready() && (&webui_meter_session_start_ready() || $awaiting_ready));
   Time::HiRes::sleep(0.1);
   $waited++;
  }
  my $final_state=&webui_meter_read_state_read();
  my $final_config_ready=&webui_meter_session_config_matches($config) ? 1 : 0;
  my $final_fifo_ready=&webui_meter_session_fifo_ready() ? 1 : 0;
  my $final_start_ready=&webui_meter_session_start_ready() ? 1 : 0;
  return 1 if($final_config_ready && $final_fifo_ready && ($final_start_ready || $final_state=~/"awaiting_ready"\s*:\s*true/i || $final_state=~/"status"\s*:\s*"setup"/i));
  my $retryable=0;
  $retryable=1 if($final_state=~/"message"\s*:\s*"[^"]*(?:communication failed during init|meter init failed|meter enumeration failed|failed to enumerate)[^"]*"/i);
  $retryable=1 if($final_config_ready && $final_start_ready && !$final_fifo_ready);
  last if(!$retryable || $attempt >= $max_attempts);
  my $state_log=$final_state;
  $state_log='(none)' if(!defined($state_log) || $state_log eq "");
  $state_log=~s/\s+/ /g;
  &log("WebUI: meter session startup attempt $attempt failed with transient init state=$state_log config_ready=$final_config_ready fifo_ready=$final_fifo_ready start_ready=$final_start_ready; retrying");
  &webui_meter_session_stop();
  system("sudo pkill -9 -f 'meter_session.sh' 2>/dev/null");
  system("sudo pkill -9 -x spotread 2>/dev/null");
  system("sudo pkill -9 -f 'script.*spotread' 2>/dev/null");
  system("sudo pkill -9 -f 'cat.*spotread_cmd' 2>/dev/null");
  unlink($_meter_session_pid_file, $_meter_session_config_file, $_meter_session_fifo, "/tmp/meter_session.lock", "/tmp/spotread_port_cache");
  my @stale=glob("/tmp/spotread_series_* /tmp/spotread_cmd_* /tmp/spotread_session_*");
  unlink(@stale) if @stale;
  Time::HiRes::sleep(1.5);
 }
 &webui_meter_session_stop();
 system("sudo pkill -9 -f 'meter_session.sh' 2>/dev/null");
 system("sudo pkill -9 -x spotread 2>/dev/null");
 unlink("/tmp/spotread_port_cache");
 return 0;
}

sub webui_meter_read (@) {
 my ($body)=@_;

 # The meter is exclusively owned by ccxxmake during profile creation. Refuse to
 # (re)start the spotread session so a stray continuous-read loop (e.g. a stale
 # browser tab still polling) cannot reclaim the instrument out from under
 # ccxxmake -- that contention is what produces "Instrument Access Failed".
 if(&_webui_ccss_create_alive()) {
  return '{"status":"idle","message":"Selected meters are busy creating a meter profile"}';
 }

 &webui_pattern_stop_guard_clear();

 # Refuse single reads while a series still owns the meter, including the
 # cooperative drain window after its state has already changed to cancelled.
 if(&webui_meter_series_alive()) {
  my $scheck="";
  if(-f $_meter_series_file && open(my $fh,"<",$_meter_series_file)) { local $/; $scheck=<$fh>; close($fh); }
  if($scheck=~/"status"\s*:\s*"running"/) {
   &log("WebUI: manual meter read requested while series helper still running; stopping stale series first");
   &webui_meter_stop();
   &webui_pattern_stop_guard_clear();
   select(undef,undef,undef,0.5);
  }
  if(&webui_meter_series_alive()) {
   return '{"status":"idle","message":"Previous meter series is still stopping"}';
  }
 }

 # Debounce: coalesce accidental double-clicks. The session daemon serializes
 # the actual reads, so this is purely a UI-side protection.
 my $now=Time::HiRes::time();
 my $is_continuous=0;
 $is_continuous=1 if($body=~/"continuous"\s*:\s*true/i);
 my $calibrate_only=($body=~/"calibrate_only"\s*:\s*true/i) ? 1 : 0;
 if(!$is_continuous && !$calibrate_only && ($now - $_meter_last_read_time < 0.25)) {
  return '{"status":"measuring"}';
 }
 $_meter_last_read_time=$now if(!$is_continuous);

 my $display_type_key="lcd";
 $display_type_key=$1 if($body=~/"display_type"\s*:\s*"([^"\\]{1,160})"/);
 my ($display_type,$ccss_file)=&resolve_display_type($display_type_key);
 # ccss_override: an explicit CCSS token (ccss_<file>/custom_<file>) the
 # operator picked instead of the technology default. Maps to an absolute path
 # via resolve_ccss_override(); empty token => fall back to the technology's
 # $_dtype_info CCSS. Keeps the WRGB/y-flag side driven by display_type while
 # the correction matrix / -X file can be a custom profile.
 my $ccss_override_token="";
 $ccss_override_token=$1 if($body=~/"ccss_override"\s*:\s*"([^"\\]{0,160})"/);
 if($ccss_override_token ne "") {
  if(lc($ccss_override_token) eq "none") {
   $ccss_file="";
  } else {
   my $override_path=&resolve_ccss_override($ccss_override_token);
   $ccss_file=$override_path if($override_path ne "");
  }
 }
 my $refresh_rate="";
 $refresh_rate=$1 if($body=~/"refresh_rate"\s*:\s*"([\d.]+)"/);
 my $measurement_meter_port="";
 $measurement_meter_port=$1 if($body=~/"measurement_meter_port"\s*:\s*"?(\d+)"?/);
 my $measurement_meter_usb_id="";
 $measurement_meter_usb_id=lc($1) if($body=~/"measurement_meter_usb_id"\s*:\s*"([0-9a-fA-F]{4}:[0-9a-fA-F]{4})"/);
 if($measurement_meter_usb_id eq "" && $measurement_meter_port ne "") {
  $measurement_meter_usb_id=&webui_meter_usb_id_for_port($measurement_meter_port);
 }
 my $observer="1931_2";
 $observer=$1 if($body=~/"observer"\s*:\s*"(1931_2|1964_10|2015_2|2015_10)"/);
 my $pattern_provider=($body=~/"pattern_provider"\s*:\s*"companion"/i)?"companion":"local";
 if(&webui_meter_is_spyderx($measurement_meter_usb_id,$measurement_meter_port)) {
  # SpyderX exposes four built-in display calibrations and device-specific
  # CCMX matrices, but not CCSS spectral corrections. Keep a selected CCMX;
  # clear CCSS and the unsupported manual refresh override. Alternate CIE
  # observers also require spectra or CCSS, so SpyderX must remain 1931 2 deg.
  $display_type=&webui_spyderx_native_display_type($display_type_key);
  $ccss_file="" if($ccss_file!~/\.ccmx$/i);
  $refresh_rate="";
  $observer="1931_2";
 }
 # Alternate observers require spectral samples. Keep every colorimeter on
 # the standard observer even if a stale client submits another selection.
 $observer="1931_2" if(!&webui_meter_port_is_spectro($measurement_meter_port));
 # Session identity stickiness: an ABSENT field means "unspecified", not
 # "changed".
 #
 # The spotread session is meant to be long-lived -- FIFO-driven, 900s idle --
 # and should only respawn when a spotread SPAWN-TIME argument genuinely
 # changes (-y display type, -X ccss, -Y R:refresh, -c port, averaging),
 # because Argyll gives no way to change any of those on a live process. But
 # those fields are part of the identity key and only SOME callers populate
 # them: the browser sends measurement_meter_port AND measurement_meter_usb_id,
 # meter_lg_autocal.pl / meter_lg_3d_autocal.pl send the port but no usb_id,
 # and meter_lg_dv_profile.pl / meter_series.sh send neither. Every handoff
 # between the browser and a worker therefore built a DIFFERENT key for the
 # SAME physical meter and respawned spotread. That is both slow (a respawn
 # costs 35-90s on OLED) and the contention window behind the stalled reads --
 # see webui_meter_spotread_settled. It also silently changed measurement
 # conditions: a respawn with an empty refresh_rate drops -Y R: altogether, so
 # spotread stops refresh-syncing mid-run. meter_session.log shows refresh
 # flipping between "", 24.00 and 120.00, and port between "" and 1, for one
 # unchanged physical setup.
 # Inherit ONLY what this caller left unspecified; a field the caller actually
 # sends still wins, so changing meter / CCSS / refresh in the UI respawns
 # exactly as it did before.
 if(&webui_meter_session_alive()) {
  my $live_config="";
  if(open(my $sfh,"<",$_meter_session_config_file)) { local $/; $live_config=<$sfh>; close($sfh); }
  $live_config="" if(!defined($live_config));
  chomp($live_config);
  if($live_config ne "") {
   my @live=split(/\|/,$live_config,-1);
   my $live_port=defined($live[4]) ? $live[4] : "";
   # refresh_rate is deliberately NOT inherited. It is an operator-selected
   # MEASUREMENT option (the meter refresh-rate dropdown) that becomes
   # spotread's -Y R: flag, not part of the meter's identity: an empty value
   # means "the operator did not ask for refresh sync". Inheriting it would
   # silently resurrect -Y R: from an earlier session after the operator turned
   # it off, which changes how the instrument integrates. Only the meter
   # identity fields below are safe to carry forward.
   $measurement_meter_port=$live_port if($measurement_meter_port eq "" && $live_port ne "");
   # Adopt the live usb_id ONLY while this request still refers to the same
   # port. Pairing a caller-specified NEW port with the previous meter's
   # usb_id would let the stale usb_id win at read time and land on the wrong
   # instrument -- precisely the failure the usb_id pinning exists to prevent.
   $measurement_meter_usb_id=$live[7]
    if($measurement_meter_usb_id eq "" && defined($live[7]) && $live[7] ne ""
       && $measurement_meter_port eq $live_port);
  }
 }
 my $require_device_ready=0;
 $require_device_ready=1 if($body=~/"require_device_ready"\s*:\s*true/i);
 $require_device_ready=1 if(!$require_device_ready && &webui_meter_port_is_spectro($measurement_meter_port));
 my $disable_aio=0;
 $disable_aio=1 if($body=~/"disable_aio"\s*:\s*true/i);
 my $patch_r="";
 $patch_r=$1 if($body=~/"patch_r"\s*:\s*(\d+)/);
 my $patch_g="";
 $patch_g=$1 if($body=~/"patch_g"\s*:\s*(\d+)/);
	 my $patch_b="";
	 $patch_b=$1 if($body=~/"patch_b"\s*:\s*(\d+)/);
	 my $patch_input_max=255;
	 $patch_input_max=$1 if($body=~/"(?:patch_input_max|input_max)"\s*:\s*(\d+)/);
	 $patch_input_max=255 if($patch_input_max <= 0);
	 my $patch_size=10;
	 $patch_size=$1 if($body=~/"patch_size"\s*:\s*(\d+)/);
	 my $delay_ms=1000;
	 $delay_ms=$1 if($body=~/"delay_ms"\s*:\s*(\d+)/);
	 my $read_timeout=0;
	 $read_timeout=$1 if($body=~/"read_timeout"\s*:\s*(\d+)/);
	 $read_timeout=0 if($read_timeout < 0);
	 $read_timeout=300 if($read_timeout > 300);
	 my $patch_ire_explicit="";
	 $patch_ire_explicit=$1 if($body=~/"(?:patch_ire|ire|stimulus)"\s*:\s*"?(-?\d+(?:\.\d+)?)"?/);
	 my $patch_name_explicit="";
	 $patch_name_explicit=$1 if($body=~/"(?:patch_name|name)"\s*:\s*"([^"\\]{1,120})"/);
	 my $signal_range="";
	 $signal_range=$1 if($body=~/"signal_range"\s*:\s*"?(\d+)"?/);
		 my $transport_signal_range="";
		 $transport_signal_range=$1 if($body=~/"transport_signal_range"\s*:\s*"?(\d+)"?/);
		 my $request_id="";
		 $request_id=$1 if($body=~/"request_id"\s*:\s*"([A-Za-z0-9_.:-]{1,96})"/);
			 # Low Light Handler averaging mode for this read (off/a/aa/aaa).
			 # Passed to the meter session so dim autocal/single reads use
			 # multi-read averaging instead of a noisy single read. The
			 # per-read mode flows via the READ command so the SESSION-LEVEL
			 # METER_AVERAGING (and the want_config 7th field) can stay
			 # stable across reads even when this value flips every read.
			 my $avg_mode="off";
			 my $avg_enabled=($body=~/"low_light"\s*:\s*\{[\s\S]{0,400}?"enabled"\s*:\s*true/i) ? 1 : 0;
			 $avg_mode=lc($1) if($avg_enabled && $body=~/"low_light"\s*:\s*\{[\s\S]{0,400}?"mode"\s*:\s*"(a|aa|aaa)"/);
			 $avg_mode="off" unless($avg_enabled && ($avg_mode eq "a" || $avg_mode eq "aa" || $avg_mode eq "aaa"));
			 # An EXPLICIT per-read "off" must reach the READ command as "off",
			 # not be coerced to ""/"-" (inherit): "-" inherits whatever mode the
			 # running spotread was last respawned with, so a worker that only
			 # ever sends the averaging transitions IN would latch averaging on
			 # for reads that must not average (the 3D profile's peak reads).
			 # Keep the wrapper/session identity stable at explicit off. Averaging is
			 # a property of the spotread child for this read, carried by READ below.
			 # Copying the per-read mode into METER_AVERAGING makes the whole wrapper
			 # session effectively averaged and defeats the luminance trigger.
			 my $session_avg_mode="off";
		 if(-f $_meter_diagnostic_read_lock) {
		  my $diag_token="";
		  if(open(my $dfh,"<",$_meter_diagnostic_read_lock)) { local $/; $diag_token=<$dfh>; close($dfh); }
		  chomp $diag_token;
		  $diag_token=~s/[^A-Za-z0-9_.:-]//g;
		  if($diag_token ne "" && $request_id!~/^\Q$diag_token\E(?:_|:|-)/) {
		   return '{"status":"error","message":"Meter diagnostic is running"}';
		  }
		 }
		 my $signal_mode=&webui_pattern_signal_mode($body);
 my $max_luma=&webui_pattern_max_luma($body);
 $transport_signal_range=$signal_range if($transport_signal_range eq "");
 $transport_signal_range=&webui_preferred_rgb_quant_range() if($transport_signal_range eq "");
 $signal_range=$transport_signal_range if($signal_range eq "");
 my $patch_target_max=&webui_pattern_target_max(&webui_pattern_effective_bits("RECTANGLE",$signal_mode));
 # Default to a 50% mid-grey patch when the caller didn't specify RGB —
 # the persistent session always displays a patch before reading.
 if($patch_r eq "" || $patch_g eq "" || $patch_b eq "") {
  $patch_r=128; $patch_g=128; $patch_b=128;
	 }
	 if($patch_input_max <= 255 && ($patch_r > 255 || $patch_g > 255 || $patch_b > 255)) {
	  $patch_input_max=$patch_target_max;
	 }
	 my $patch_name="Manual";
	 my $patch_ire=0;
	 if($patch_ire_explicit ne "") {
	  $patch_ire=$patch_ire_explicit+0;
	 } elsif($patch_r==$patch_g && $patch_g==$patch_b) {
	  # Infer an achromatic patch's stimulus in the same code domain the
	  # caller supplied. The old fixed 8-bit 16..235 calculation interpreted
	  # standard-DV 12-bit black (256/4095) as 100% white. That made the meter
	  # session reject a legitimate all-zero black measurement as a null read.
	  my $code_scale=($patch_input_max+1)/256;
	  my $limited_black=int(16*$code_scale+0.5);
	  my $limited_white=int(235*$code_scale+0.5);
	  if(int($signal_range)==1 && $limited_white>$limited_black) {
	   $patch_ire=int((($patch_r-$limited_black)/($limited_white-$limited_black))*100+0.5);
	  } else {
	   $patch_ire=int(($patch_r/$patch_input_max)*100+0.5);
	  }
	  $patch_ire=0 if($patch_ire < 0);
	  $patch_ire=100 if($patch_ire > 100);
	 }
	 if($patch_name_explicit ne "") {
	  $patch_name=$patch_name_explicit;
	 } elsif($patch_r==$patch_g && $patch_g==$patch_b) {
	  $patch_name="${patch_ire}pct";
	 }
	 $patch_name=~s/%/pct/g;
	 $patch_name=~s/[^A-Za-z0-9_.:-]+/_/g;
	 $patch_name="Manual" if($patch_name eq "");

 # The session daemon starts spotread once and reuses it for every read.
 # Restart only when the meter config (display type, ccss, refresh, AIO) changes
 # or the daemon isn't running.
 my $aio_flag=$disable_aio ? "1" : "0";
 # The 7th field stays at off for the wrapper's whole life. Only the spotread
 # child changes mode through the per-read READ field below.
 my $want_config="$display_type|$ccss_file|$refresh_rate|$aio_flag|$measurement_meter_port|$require_device_ready|$session_avg_mode|$measurement_meter_usb_id|$observer|$pattern_provider";
 my $alive=&webui_meter_session_alive();
 my $needs_restart= !$alive || !&webui_meter_session_config_matches($want_config);
 if($needs_restart) {
  if($alive) {
   &log("WebUI: meter session config changed, restarting daemon");
   &webui_meter_session_stop();
  } else {
     # If the session PID disappeared but helper children are still around,
     # they can keep the session lock/FIFO namespace busy and make the next
     # start fail with a stale-session error.
     &log("WebUI: meter session missing its PID, clearing stale helpers");
     system("sudo pkill -9 -f 'meter_session.sh' 2>/dev/null");
     system("sudo pkill -9 -x spotread 2>/dev/null");
     system("sudo pkill -9 -f 'script.*spotread' 2>/dev/null");
     system("sudo pkill -9 -f 'cat.*spotread_cmd' 2>/dev/null");
   system("sudo bash $_meter_wrapper --kill 2>/dev/null");
     &webui_meter_session_ready_cleanup();
     unlink($_meter_session_pid_file, $_meter_session_config_file, $_meter_session_fifo, "/tmp/meter_session.lock");
     my @stale=glob("/tmp/spotread_series_* /tmp/spotread_cmd_* /tmp/spotread_session_*");
     unlink(@stale) if @stale;
     # This is the path that produced the observed stall: the session PID was
     # gone (its cleanup never ran, so it was SIGKILLed) while its spotread was
     # still holding the instrument. A fixed 300ms is not long enough for the
     # kernel to release a SIGKILLed process's USB claim, and the new spotread
     # spawned below then cannot talk to the meter -- a clean-dmesg
     # "communication problem" and a multi-minute parked patch. Confirm instead.
     &webui_meter_spotread_settled(4000);
  }
  &webui_meter_read_state_write('{"status":"starting"}');
  # The refresh-display (-y c) startup path can ask for an 80% white patch
  # during initialization. Pre-show it here so the background session helper
  # does not need to call back into the active HTTP request path.
  if($display_type eq "c") {
   my $startup_level=int($signal_range)==1 ? int(16 + 0.8 * 219 + .5) : int(0.8 * 255 + .5);
   my $startup_patch='{"name":"patch","r":'.$startup_level.',"g":'.$startup_level.',"b":'.$startup_level.',"size":100,"input_max":255,"signal_mode":"'.$signal_mode.'","max_luma":'.$max_luma.',"signal_range":"'.$signal_range.'","transport_signal_range":"'.$transport_signal_range.'"}';
   if($pattern_provider eq "companion") { &webui_icc_companion_pattern($startup_patch); }
   else { &webui_pattern($startup_patch); }
   select(undef,undef,undef,0.5);
  }
  &log("WebUI: starting meter session (display_type=$display_type, ccss=$ccss_file, refresh=$refresh_rate, aio_off=$disable_aio, port=$measurement_meter_port, ready_gate=$require_device_ready)");
  # Session-level averaging is always off. Per-read averaging is applied by
  # respawning only the spotread child after the explicit READ mode is parsed.
  if(!&webui_meter_session_start($display_type,$ccss_file,$refresh_rate,$disable_aio,$want_config,$signal_mode,$max_luma,$measurement_meter_port,$require_device_ready,$session_avg_mode,$measurement_meter_usb_id,$observer,$pattern_provider)) {
    return &webui_meter_session_start_error_json($want_config);
  }
 }

 # Mark measuring so the polling endpoint sees a fresh in-flight state and
 # can't return the previous reading by mistake.
 my $state_before_send=&webui_meter_read_state_read();
 if($state_before_send!~/"awaiting_ready"\s*:\s*true/i && $state_before_send!~/"status"\s*:\s*"setup"/i) {
	  my $pending_state=$calibrate_only
	   ? '{"status":"measuring","setup_busy":true,"message":"Preparing meter calibration...","timeout_sec":210}'
	   : '{"status":"measuring","request_id":"'.$request_id.'","timeout_sec":'.$read_timeout.'}';
	  if(open(my $fh,">",$_meter_read_file)) { print $fh $pending_state; close($fh); }
 }

 # Send the READ command to the daemon. The session helper applies this
 # settle delay before each reading, even when the current patch is reused.
 # The trailing 15th field is the PER-READ low_light mode: meter_session.sh
 # uses it to decide whether to respawn spotread with -Y averaging flags for this
 # specific read (the session-level METER_AVERAGING stays put).
			 my $read_command=$calibrate_only ? "CALIBRATE" : "READ $patch_r $patch_g $patch_b $patch_size $patch_ire $patch_name $delay_ms $signal_mode $max_luma";
			 my $cmd_signal_range=($signal_range ne "") ? $signal_range : "-";
			 my $cmd_transport_signal_range=($transport_signal_range ne "") ? $transport_signal_range : "-";
			 my $cmd_request_id=($request_id ne "") ? $request_id : "-";
			 my $cmd_read_timeout=($read_timeout > 0) ? $read_timeout : "-";
			 my $cmd_low_light_mode=$avg_mode;
			 my $cmd_continuous=$is_continuous ? "1" : "0";
			 $read_command.=" $cmd_signal_range $cmd_transport_signal_range $cmd_request_id $patch_input_max $cmd_read_timeout $cmd_low_light_mode $cmd_continuous" if(!$calibrate_only);
		 $read_command.="\n";
 if(!&webui_meter_session_send_command($read_command)) {
  &log("WebUI: meter session command send failed, restarting daemon");
  &webui_meter_session_stop();
  &webui_meter_read_state_write('{"status":"starting"}');
  if(!&webui_meter_session_start($display_type,$ccss_file,$refresh_rate,$disable_aio,$want_config,$signal_mode,$max_luma,$measurement_meter_port,$require_device_ready,$session_avg_mode,$measurement_meter_usb_id,$observer,$pattern_provider)) {
     &log("WebUI: meter session restart failed after FIFO send error");
     return &webui_meter_session_start_error_json($want_config);
  }
  if(!&webui_meter_session_send_command($read_command)) {
   &log("WebUI: meter session retry send failed");
   return '{"status":"error","message":"Session FIFO unavailable"}';
  }
 }

 return '{"status":"measuring"}';
}

sub webui_meter_read_result (@) {
 if(-f $_meter_read_file) {
  my $json="";
  if(open(my $fh,"<",$_meter_read_file)) { local $/; $json=<$fh>; close($fh); }
  chomp($json);
  if($json ne "") {
    if($json=~/"awaiting_ready"\s*:\s*true/i) {
      return $json;
     }
    if($json=~/"setup_busy"\s*:\s*true/i) {
      # 'Working...' state between setup steps (e.g. calibrating after the tile
      # ack). Pass it through with its message so the wizard popup can stay
      # visible, instead of reconstructing a bare 'measuring' that hides it.
      return $json;
     }
  if($json=~/"status"\s*:\s*"(starting|measuring|running)"/) {
    my $age=time() - (stat($_meter_read_file))[9];
    my $timeout_sec=170;
    if($json=~/"timeout_sec"\s*:\s*(\d+)/) {
     my $requested=$1+0;
     $timeout_sec=$requested+30 if($requested >= 10);
     $timeout_sec=40 if($timeout_sec < 40);
     $timeout_sec=330 if($timeout_sec > 330);
    }
    if($age > $timeout_sec) {
     &log("WebUI: meter read state stale for ${age}s; stopping meter session");
     &webui_meter_session_stop();
     &webui_meter_read_state_write('{"status":"error","message":"Read timed out"}');
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

our $WEBUI_METER_GAMUT_DEFS;

sub webui_meter_gamut_definitions (@) {
 if(!$WEBUI_METER_GAMUT_DEFS) {
  $WEBUI_METER_GAMUT_DEFS={
   bt709=>{
    label=>'BT.709 / D65',
    WHITE=>['0.3127','0.3290'],
    PRIMARIES=>{R=>['0.64','0.33'],G=>['0.30','0.60'],B=>['0.15','0.06']},
    # Exact inverse of RGB_TO_XYZ. The former four-decimal sRGB inverse
    # introduced small non-zero channels in BT.709 RGB -> XYZ -> RGB paths.
    M=>[['3.2404548360','-1.5371388501','-0.4985315469'],['-0.9692663899','1.8760109288','0.0415560823'],['0.0556434196','-0.2040258543','1.0572251625']],
    RGB_TO_XYZ=>[['0.4124564','0.3575761','0.1804375'],['0.2126729','0.7151522','0.0721750'],['0.0193339','0.1191920','0.9503041']]
   },
   bt2020=>{
    label=>'BT.2020 / D65',
    WHITE=>['0.3127','0.3290'],
    PRIMARIES=>{R=>['0.708','0.292'],G=>['0.170','0.797'],B=>['0.131','0.046']},
    M=>[['1.7166511880','-0.3556707838','-0.2533662814'],['-0.6666843518','1.6164812366','0.0157685458'],['0.0176398574','-0.0427706133','0.9421031212']],
    RGB_TO_XYZ=>[['0.6369580483','0.1446169036','0.1688809752'],['0.2627002120','0.6779980715','0.0593017165'],['0.0000000000','0.0280726930','1.0609850577']]
   },
   p3d65=>{
    label=>'P3 / D65',
    WHITE=>['0.3127','0.3290'],
    PRIMARIES=>{R=>['0.680','0.320'],G=>['0.265','0.690'],B=>['0.150','0.060']},
    M=>[['2.4934969119','-0.9313836179','-0.4027107845'],['-0.8294889696','1.7626640603','0.0236246858'],['0.0358458302','-0.0761723893','0.9568845240']],
    RGB_TO_XYZ=>[['0.4865709486','0.2656676932','0.1982172852'],['0.2289745641','0.6917385218','0.0792869141'],['0.0000000000','0.0451133819','1.0439443689']]
   },
   p3dci=>{
    label=>'P3 / DCI',
    WHITE=>['0.3140','0.3510'],
    PRIMARIES=>{R=>['0.680','0.320'],G=>['0.265','0.690'],B=>['0.150','0.060']},
    M=>[['2.7253940305','-1.0180030062','-0.4401631952'],['-0.7951680258','1.6897320548','0.0226471906'],['0.0412418914','-0.0876390192','1.1009293786']],
    RGB_TO_XYZ=>[['0.4451698156','0.2771344092','0.1722826698'],['0.2094916779','0.7215952542','0.0689130679'],['0.0000000000','0.0470605601','0.9073553944']]
   }
  };
 }
 return $WEBUI_METER_GAMUT_DEFS;
}

sub webui_meter_gamut_js_literal (@) {
 my $defs=&webui_meter_gamut_definitions();
 my @keys=qw(bt709 bt2020 p3d65 p3dci);
 my @blocks;
 foreach my $key (@keys) {
  my $def=$defs->{$key};
  my @matrix_rows=map { '   ['.join(',',@$_).']' } @{$def->{M}};
  my @rgb_rows=map { '   ['.join(',',@$_).']' } @{$def->{RGB_TO_XYZ}};
  my @primaries=map {
   my ($x,$y)=@{$def->{PRIMARIES}{$_}};
   "$_:{x:$x,y:$y}"
  } qw(R G B);
  my ($wx,$wy)=@{$def->{WHITE}};
  push @blocks,
   " $key:{\n".
   "  label:'$def->{label}',\n".
   "  white:{x:$wx,y:$wy},\n".
   "  primaries:{".join(',',@primaries)."},\n".
   "  xyzToRgb:[\n".join(",\n",@matrix_rows)."\n  ],\n".
   "  rgbToXyz:[\n".join(",\n",@rgb_rows)."\n  ]\n".
   " }";
 }
 return "{\n".join(",\n",@blocks)."\n}";
}

# Bradford-adapt a D65 ColorChecker reference to the selected target white.
# This is intentionally scoped to the meter reference-color builders.
sub webui_meter_bradford_adapt_xyz (@) {
 my ($X,$Y,$Z,$fx,$fy,$tx,$ty)=@_;
 return ($X,$Y,$Z) unless($fx>0 && $fy>0 && $tx>0 && $ty>0);
 return ($X,$Y,$Z) if(abs($fx-$tx)<1e-7 && abs($fy-$ty)<1e-7);
 my @M=([0.8951,0.2664,-0.1614],[-0.7502,1.7135,0.0367],[0.0389,-0.0685,1.0296]);
 my @MI=([0.9869929,-0.1470543,0.1599627],[0.4323053,0.5183603,0.0492912],[-0.0085287,0.0400428,0.9684867]);
 my $mul=sub { my ($m,$v)=@_; return map { my $r=$_; $$m[$r][0]*$$v[0]+$$m[$r][1]*$$v[1]+$$m[$r][2]*$$v[2] } (0,1,2); };
 my @ws=($fx/$fy,1,(1-$fx-$fy)/$fy);
 my @wd=($tx/$ty,1,(1-$tx-$ty)/$ty);
 my @cs=$mul->(\@M,\@ws);
 my @cd=$mul->(\@M,\@wd);
 my @c=$mul->(\@M,[$X,$Y,$Z]);
 my @scaled=map { $c[$_]*($cs[$_]!=0 ? $cd[$_]/$cs[$_] : 1) } (0,1,2);
 return $mul->(\@MI,\@scaled);
}

sub _webui_meter_lg_autocal_norm_text (@) {
 my ($value)=@_;
 $value="" if(!defined($value) || ref($value));
 $value="$value";
 $value=~s/^\s+|\s+$//g;
 return lc($value);
}

sub _webui_meter_lg_autocal_completed_ms (@) {
 my ($value)=@_;
 return undef if(!defined($value) || ref($value));
 my $text="$value";
 $text=~s/^\s+|\s+$//g;
 return undef unless($text=~/^\d+(?:\.\d+)?$/);
 my $num=$text+0;
 return undef if($num<=0);
 $num*=1000 if($num < 100000000000);
 return int($num+0.5);
}

sub webui_meter_lg_autocal_series_target_reference (@) {
 my (%opts)=@_;
 return undef if($opts{"explicit_series_target_white_y"});
 return undef unless(&_webui_meter_lg_autocal_norm_text($opts{"type"}) eq "greyscale");
 return undef unless(int($opts{"points"}||0)==26);
 return undef unless($opts{"lg_autocal_26"});
 my $req_signal_mode=&_webui_meter_lg_autocal_norm_text($opts{"signal_mode"}||"sdr");
 return undef unless($req_signal_mode eq "sdr" || $req_signal_mode eq "hdr10");

 my $state_file=$opts{"state_file"} || $_meter_lg_autocal_file;
 return undef if(!$state_file || !-f $state_file);
 my $json="";
 if(open(my $fh,"<",$state_file)) { local $/; $json=<$fh>; close($fh); }
 return undef if($json eq "");
 my $state=eval {
  require JSON::PP;
  JSON::PP::decode_json($json);
 };
 return undef if($@ || ref($state) ne "HASH");
 return undef unless(&_webui_meter_lg_autocal_norm_text($state->{"status"}) eq "complete");

 my $state_picture=&_webui_meter_lg_autocal_norm_text($state->{"picture_mode"} || $state->{"calibration_picture_mode"} || "");
 my $req_picture=&_webui_meter_lg_autocal_norm_text($opts{"picture_mode"} || "");
 return undef if($state_picture ne "" && $req_picture eq "");
 return undef if($state_picture ne "" && $req_picture ne $state_picture);

 my $state_display=&_webui_meter_lg_autocal_norm_text($state->{"display_type"} || "");
 if($state_display ne "") {
  my %request_display=();
  foreach my $display ($opts{"display_type_key"},$opts{"display_type"}) {
   my $norm=&_webui_meter_lg_autocal_norm_text($display);
   $request_display{$norm}=1 if($norm ne "");
  }
  return undef unless($request_display{$state_display});
 }

 my $state_gamma=&_webui_meter_lg_autocal_norm_text($state->{"target_gamma"} || "");
 my $req_gamma=&_webui_meter_lg_autocal_norm_text($opts{"target_gamma"} || "");
 return undef if($state_gamma ne "" && $req_gamma eq "");
 return undef if($state_gamma ne "" && $req_gamma ne $state_gamma);

 my @state_runs=grep { $_ ne "" } map { &_webui_meter_lg_autocal_norm_text($_) } ($state->{"full_autocal_run_id"},$state->{"run_id"});
 my @request_runs=grep { $_ ne "" } map { &_webui_meter_lg_autocal_norm_text($_) } ($opts{"full_autocal_run_id"},$opts{"run_id"});
 my $explicit_run_match=0;
 foreach my $req (@request_runs) {
  foreach my $state_run (@state_runs) {
   if($req eq $state_run) { $explicit_run_match=1; last; }
  }
  last if($explicit_run_match);
 }

 my $completed_ms=&_webui_meter_lg_autocal_completed_ms($state->{"completed_at"});
 if(!$explicit_run_match) {
  return undef if(!defined($completed_ms));
  my $now_ms=defined($opts{"now_ms"}) ? ($opts{"now_ms"}+0) : int(Time::HiRes::time()*1000);
  my $age_ms=$now_ms-$completed_ms;
  return undef if($age_ms < 0 || $age_ms > 30*60*1000);
 }

 my @candidates=(
  ["committed_polish_white_y","lg-autocal-committed"],
  ["calibrated_white_luminance","lg-autocal-calibrated"],
  ["target_luminance","lg-autocal-target"]
 );
 foreach my $candidate (@candidates) {
  my ($field,$source)=@$candidate;
  next if(!defined($state->{$field}) || ref($state->{$field}));
  my $white_y=$state->{$field}+0;
  next if($white_y<=0);
  next if($field eq "committed_polish_white_y" && !$state->{"committed_polish_reference_locked"});
  my $run_id=$state->{"full_autocal_run_id"} || $state->{"run_id"} || "";
  return {
   white_y=>$white_y,
   source=>$source,
   field=>$field,
   run_id=>$run_id,
   completed_at=>$state->{"completed_at"},
   picture_mode=>$state->{"picture_mode"} || $state->{"calibration_picture_mode"} || "",
   display_type=>$state->{"display_type"} || "",
   target_gamma=>$state->{"target_gamma"} || ""
  };
 }
 return undef;
}

# Custom user-defined series: the client sends the fully-built patch list
# (codes already in the wire bit depth) as "custom_steps". Rebuild each step
# from a strict field whitelist so nothing from the request body reaches the
# steps file verbatim. Downstream stampers (series white/black, signal-mode
# meta) regex-append to these strings, so the shape must match the derived
# step strings exactly.
# Parameter-defined lattice series: expand generator params into measurement
# steps. MUST stay algorithm-identical to the client's meterLatticeExpandPatches
# (grid order r-slowest/b-fastest, golden-ratio spread stride, Rec.709-signal
# threshold, grey ramp 100%-first, percent names, ire from 1). Locked by
# tests/lattice-server-steps-regression.pl + tests/lattice-expansion-regression.js.
sub webui_lattice_series_steps_from_body (@) {
 my ($body,$chroma_min,$chroma_span,$input_max)=@_;
 return () unless($body=~/"custom_series"\s*:\s*true/i);
 return () unless($body=~/"lattice_params"\s*:\s*\{([^{}]*)\}/s);
 my $obj=$1;
 my %p;
 foreach my $key (qw(size grey_points threshold_pct)) {
  $p{$key}=$1 if($obj=~/"$key"\s*:\s*(-?\d+(?:\.\d+)?)/);
 }
 my $order=($obj=~/"order"\s*:\s*"grid"/)?"grid":"spread";
 my $reverse=($obj=~/"reverse"\s*:\s*true/i)?1:0;
 my $size=defined($p{"size"})?int($p{"size"}):9;
 $size=3 if($size<3);
 $size=50 if($size>50);
 my $grey=defined($p{"grey_points"})?int($p{"grey_points"}):0;
 $grey=0 if($grey<2);
 $grey=101 if($grey>101);
 my $threshold=defined($p{"threshold_pct"})?$p{"threshold_pct"}+0:0;
 $threshold=0 if($threshold<0);
 $threshold=50 if($threshold>50);
 # Node spacing (MUST mirror meterLatticeAxisFracs): 'light' spaces node
 # values uniformly in decoded light up to peak_nits (PQ encode for HDR
 # lattices, 2.4 power law for SDR), normalized so corners hit 100% signal.
 my $spacing=($obj=~/"spacing"\s*:\s*"light"/)?"light":"signal";
 my $lat_pq=($obj=~/"pq"\s*:\s*true/i)?1:0;
 my $peak_nits=1000;
 $peak_nits=$1+0 if($obj=~/"peak_nits"\s*:\s*(-?\d+(?:\.\d+)?)/);
 $peak_nits=100 if($peak_nits<100);
 $peak_nits=10000 if($peak_nits>10000);
 my $pq_encode=sub {
  my ($L)=@_;
  my $m1=2610/16384; my $m2=2523/32; my $c1=3424/4096; my $c2=2413/128; my $c3=2392/128;
  my $y=($L<0?0:$L)/10000;
  my $pp=$y**$m1;
  return (($c1+$c2*$pp)/(1+$c3*$pp))**$m2;
 };
 my $axis_frac=sub {
  my ($i,$div)=@_;
  my $t=$i/$div;
  return $t if($spacing ne "light");
  # Endpoints pinned EXACTLY (mirror of meterLatticeAxisFracs): pqe(0) is
  # ~7e-7, not 0, and a non-zero black frac breaks frac-exact corner
  # detection in the client ordering parity.
  return 0 if($i==0);
  return 1 if($i==$div);
  if($lat_pq) {
   my $top=$pq_encode->($peak_nits);
   return $top>0 ? $pq_encode->($t*$peak_nits)/$top : $t;
  }
  return $t**(1/2.4);
 };
 my @steps;
 my $ire=1;
 my $pctf=sub {
  my($f)=@_;
  my $v=int($f*1000+0.5)/10;
  return ($v==int($v))?int($v):$v;
 };
 my $push_step=sub {
  my($name,$fr,$fg,$fb)=@_;
  my $r=int($chroma_min+$fr*$chroma_span+0.5);
  my $g=int($chroma_min+$fg*$chroma_span+0.5);
  my $b=int($chroma_min+$fb*$chroma_span+0.5);
  push @steps,"{\"ire\":$ire,\"r\":$r,\"g\":$g,\"b\":$b,\"name\":\"".&_webui_json_escape($name)."\",\"input_max\":$input_max}";
  $ire++;
 };
 if($grey>=2) {
  $push_step->("G 100%",1,1,1);
  for(my $i=0;$i<$grey;$i++) {
   my $f=$i/($grey-1);
   next if($f>=1);
   $push_step->("G ".$pctf->($f)."%",$f,$f,$f);
  }
 }
 my @nodes;
 my $div=$size-1;
 my @axis_fracs=map { $axis_frac->($_,$div) } (0..$size-1);
 for(my $ri=0;$ri<$size;$ri++) {
  for(my $gi=0;$gi<$size;$gi++) {
   for(my $bi=0;$bi<$size;$bi++) {
    my ($fr,$fg,$fb)=($axis_fracs[$ri],$axis_fracs[$gi],$axis_fracs[$bi]);
    next if($threshold>0 && (0.2126*$fr+0.7152*$fg+0.0722*$fb)*100 < $threshold);
    push @nodes,[$fr,$fg,$fb];
   }
  }
 }
 my @ordered=@nodes;
 if($order eq "spread" && scalar(@nodes)>1) {
  my $total=scalar(@nodes);
  my $stride=int($total*0.618034);
  $stride=1 if($stride<1);
  my $a=$stride; my $b2=$total;
  my $gcd=sub { my($x,$y)=@_; while($y){ my $t=$x%$y; $x=$y; $y=$t; } return $x; };
  $stride++ while($gcd->($stride,$total)!=1);
  @ordered=();
  my $idx=0;
  for(my $k=0;$k<$total;$k++) { push @ordered,$nodes[$idx]; $idx=($idx+$stride)%$total; }
 }
 @ordered=reverse(@ordered) if($reverse);
 # Reference corners first: W, R, G, B (then K when present) lead the run so
 # the client's display-referenced chart targets have their measured white
 # peak + additive per-channel ceilings from the first handful of patches.
 # MUST stay algorithm-identical to the client's meterLatticeExpandPatches
 # (parity-locked by the lattice tests).
 my $corner_rank=sub {
  my($fr,$fg,$fb)=@_;
  my $one=sub { $_[0]>=1 }; my $zero=sub { $_[0]<=0 };
  return 0 if($one->($fr) && $one->($fg) && $one->($fb));
  return 1 if($one->($fr) && $zero->($fg) && $zero->($fb));
  return 2 if($zero->($fr) && $one->($fg) && $zero->($fb));
  return 3 if($zero->($fr) && $zero->($fg) && $one->($fb));
  return 4 if($zero->($fr) && $zero->($fg) && $zero->($fb));
  return -1;
 };
 my @corner_lead=sort { $corner_rank->(@$a) <=> $corner_rank->(@$b) } grep { $corner_rank->(@$_)>=0 } @ordered;
 @ordered=(@corner_lead, grep { $corner_rank->(@$_)<0 } @ordered) if(scalar(@corner_lead));
 foreach my $node (@ordered) {
  my($fr,$fg,$fb)=@$node;
  $push_step->($pctf->($fr)."/".$pctf->($fg)."/".$pctf->($fb),$fr,$fg,$fb);
 }
 return @steps;
}
sub webui_custom_series_steps_from_body (@) {
 my ($body)=@_;
 return () unless($body=~/"custom_series"\s*:\s*true/i);
 return () unless($body=~/"custom_steps"\s*:\s*\[(.*?)\](?=\s*[,}])/s);
 my $list=$1;
 my @out;
 # Match WebUI METER_CUSTOM_SERIES_MAX_PATCHES (large CalMAN/ColourSpace imports).
 my $max_patches=3000;
 while($list=~/\{([^{}]*)\}/g) {
  last if(scalar(@out)>=$max_patches);
  my $obj=$1;
  my %num;
  foreach my $key (qw(ire r g b input_max patch_size target_x target_y target_Yn custom_target_nits stimulus signal_r_pct signal_g_pct signal_b_pct sat_pct)) {
   $num{$key}=$1 if($obj=~/"$key"\s*:\s*(-?\d+(?:\.\d+)?)/);
  }
  next unless(defined $num{"r"} && defined $num{"g"} && defined $num{"b"});
  # Prefer the client's input_max. Fall back by magnitude of the RGB codes so
  # 10-bit ColorChecker selection steps that omit input_max are not clamped to 255.
  my $input_max=255;
  if(defined $num{"input_max"}) {
   my $im=int($num{"input_max"});
   $input_max=($im==4095||$im==1023||$im==255)?$im:255;
  } else {
   my $peak=0;
   foreach my $ch (qw(r g b)) { $peak=$num{$ch} if(defined $num{$ch} && $num{$ch}>$peak); }
   $input_max=4095 if($peak>1023);
   $input_max=1023 if($peak>255 && $peak<=1023);
  }
  foreach my $ch (qw(r g b)) {
   $num{$ch}=int($num{$ch}+0.5);
   $num{$ch}=0 if($num{$ch}<0);
   $num{$ch}=$input_max if($num{$ch}>$input_max);
  }
  my $name="";
  $name=$1 if($obj=~/"name"\s*:\s*"([^"\\]*(?:\\.[^"\\]*)*)"/);
  $name=~s/\\(.)/$1/g;
  # Keep "/" so lattice/hybrid/skeleton names stay "R/G/B" percent triplets
  # (e.g. 100/0/0). Stripping slashes made "100/100/100" → "100100100" and
  # offline Build 3D LUT silently failed (no triplet names → no solve).
  $name=~s/[^A-Za-z0-9 ._%#()+\-\/]//g;
  $name=substr($name,0,48);
  $name="Patch ".(scalar(@out)+1) if($name eq "");
  my $ire=(defined $num{"ire"})?$num{"ire"}+0:0;
  $ire=0 if($ire<0);
  $ire=110 if($ire>110);
  my $step="{\"ire\":$ire,\"r\":$num{r},\"g\":$num{g},\"b\":$num{b},\"name\":\"".&_webui_json_escape($name)."\",\"input_max\":$input_max";
  if($obj=~/"icc_reuse_signature"\s*:\s*"([a-fA-F0-9]{16})"/) {
   $step.=',"icc_reuse_signature":"'.lc($1).'"';
  }
  if(defined $num{"patch_size"}) {
   my $patch_size=$num{"patch_size"}+0;
   $patch_size=1 if($patch_size<1);
   $patch_size=100 if($patch_size>100);
   $step.=",\"patch_size\":$patch_size";
  }
  $step.=",\"target_x\":".($num{"target_x"}+0) if(defined $num{"target_x"});
  $step.=",\"target_y\":".($num{"target_y"}+0) if(defined $num{"target_y"});
  $step.=",\"target_Yn\":".($num{"target_Yn"}+0) if(defined $num{"target_Yn"});
  $step.=",\"custom_target_nits\":".($num{"custom_target_nits"}+0) if(defined $num{"custom_target_nits"});
  $step.="}";
  push @out,$step;
 }
 return @out;
}

sub webui_meter_series_start (@) {
 my ($body)=@_;
 # A cooperatively-cancelled series may still be finishing its current USB
 # transaction after the Stop API has returned. Never start a second owner of
 # the meter during that short drain window.
 if(&webui_meter_series_alive()) {
  return '{"status":"error","message":"Previous meter series is still stopping"}';
 }
 # A series run owns its own persistent spotread process. Read Once /
 # Continuous keeps a reusable meter_session daemon alive, so shut that down
 # before launching the series helper or two spotread instances can fight over
 # the same USB meter and produce intermittent bad/stale reads.
 &webui_meter_session_stop_only() if(&webui_meter_session_alive());
 &webui_pattern_stop_guard_clear();
 # Parse request
 my $type="greyscale";
 $type=$1 if($body=~/"type"\s*:\s*"(\w+)"/);
 my $points=21;
 $points=$1 if($body=~/"points"\s*:\s*(\d+)/);
 $points=100 if($type eq "greyscale" && $points==256);
 my $display_type_key="lcd";
 $display_type_key=$1 if($body=~/"display_type"\s*:\s*"([^"\\]{1,160})"/);
 my ($display_type,$ccss_file)=&resolve_display_type($display_type_key);
 # ccss_override: same parsing rule as webui_meter_read. The single-read and
 # series paths now share the same override-token contract so the worker can
 # always derive y_flag from display_type and the correction matrix from the
 # (override or technology default) CCSS path.
 my $ccss_override_token="";
 $ccss_override_token=$1 if($body=~/"ccss_override"\s*:\s*"([^"\\]{0,160})"/);
 if($ccss_override_token ne "") {
  if(lc($ccss_override_token) eq "none") {
   $ccss_file="";
  } else {
   my $override_path=&resolve_ccss_override($ccss_override_token);
   $ccss_file=$override_path if($override_path ne "");
  }
 }
 my $delay_ms=1000;
 $delay_ms=$1 if($body=~/"delay_ms"\s*:\s*(\d+)/);
 my $patch_size=10;
 $patch_size=$1 if($body=~/"patch_size"\s*:\s*(\d+)/);
 my $signal_range="";
 $signal_range=$1 if($body=~/"signal_range"\s*:\s*"?(\d+)"?/);
 my $pattern_signal_range="";
 $pattern_signal_range=$1 if($body=~/"pattern_signal_range"\s*:\s*"?(\d+)"?/);
 my $transport_signal_range="";
 $transport_signal_range=$1 if($body=~/"transport_signal_range"\s*:\s*"?(\d+)"?/);
 my $series_color_format=0;
 $series_color_format=$1 if($body=~/"color_format"\s*:\s*"?(\d+)"?/);
my $patch_insert=0;
$patch_insert=1 if($body=~/"patch_insert"\s*:\s*true/i);
my $pattern_delay_ms=0;
$pattern_delay_ms=$1 if($body=~/"pattern_delay_ms"\s*:\s*(\d+)/);
$pattern_delay_ms=0 if($pattern_delay_ms < 0);
$pattern_delay_ms=120000 if($pattern_delay_ms > 120000);
my $patch_insert_patch_enabled=0;
if($body=~/"patch_insert_patch_enabled"\s*:/i) {
 $patch_insert_patch_enabled=1 if($body=~/"patch_insert_patch_enabled"\s*:\s*true/i);
} else {
 $patch_insert_patch_enabled=$patch_insert ? 1 : 0;
}
my $patch_insert_patch_every=1;
$patch_insert_patch_every=$1 if($body=~/"patch_insert_patch_every"\s*:\s*(\d+)/);
$patch_insert_patch_every=1 if($patch_insert_patch_every < 1);
$patch_insert_patch_every=999 if($patch_insert_patch_every > 999);
my $patch_insert_patch_duration_ms=1000;
$patch_insert_patch_duration_ms=$1 if($body=~/"patch_insert_patch_duration_ms"\s*:\s*(\d+)/);
$patch_insert_patch_duration_ms=0 if($patch_insert_patch_duration_ms < 0);
$patch_insert_patch_duration_ms=120000 if($patch_insert_patch_duration_ms > 120000);
my $patch_insert_patch_level=10;
$patch_insert_patch_level=$1 if($body=~/"patch_insert_patch_level"\s*:\s*([0-9.]+)/);
$patch_insert_patch_level=0 if($patch_insert_patch_level < 0);
$patch_insert_patch_level=100 if($patch_insert_patch_level > 100);
my $patch_insert_time_enabled=0;
$patch_insert_time_enabled=1 if($body=~/"patch_insert_time_enabled"\s*:\s*true/i);
my $patch_insert_time_frequency_ms=5000;
$patch_insert_time_frequency_ms=$1 if($body=~/"patch_insert_time_frequency_ms"\s*:\s*(\d+)/);
$patch_insert_time_frequency_ms=1 if($patch_insert_time_frequency_ms < 1);
$patch_insert_time_frequency_ms=120000 if($patch_insert_time_frequency_ms > 120000);
my $patch_insert_time_duration_ms=5000;
$patch_insert_time_duration_ms=$1 if($body=~/"patch_insert_time_duration_ms"\s*:\s*(\d+)/);
$patch_insert_time_duration_ms=0 if($patch_insert_time_duration_ms < 0);
$patch_insert_time_duration_ms=120000 if($patch_insert_time_duration_ms > 120000);
my $patch_insert_time_level=25;
$patch_insert_time_level=$1 if($body=~/"patch_insert_time_level"\s*:\s*([0-9.]+)/);
$patch_insert_time_level=0 if($patch_insert_time_level < 0);
$patch_insert_time_level=100 if($patch_insert_time_level > 100);
 my $refresh_rate="";
 $refresh_rate=$1 if($body=~/"refresh_rate"\s*:\s*"([\d.]+)"/);
 my $measurement_meter_port="";
 $measurement_meter_port=$1 if($body=~/"measurement_meter_port"\s*:\s*"?(\d+)"?/);
 my $disable_aio=0;
 $disable_aio=1 if($body=~/"disable_aio"\s*:\s*true/i);
 # Low-light handler configuration for the series worker. The selected mode
 # and trigger remain separate so meter_series.sh can choose the effective
 # child mode from each serialized step's expected target luminance.
 my $low_light_mode="off";
 my $low_light_enabled=($body=~/"low_light"\s*:\s*\{[\s\S]{0,500}?"enabled"\s*:\s*true/i) ? 1 : 0;
 if($low_light_enabled && $body=~/"low_light"\s*:\s*\{[\s\S]{0,500}?"mode"\s*:\s*"([a-z_]+)"/){
  $low_light_mode=lc($1);
  $low_light_mode="off" unless($low_light_mode eq "a" || $low_light_mode eq "aa" || $low_light_mode eq "aaa");
 }
 my $low_light_trigger="";
 $low_light_trigger=$1+0 if($low_light_enabled && $body=~/"low_light"\s*:\s*\{[\s\S]{0,700}?"trigger"\s*:\s*"?([0-9]+(?:\.[0-9]+)?)"?/i);
 $low_light_trigger="" if($low_light_trigger ne "" && $low_light_trigger<=0);
 my $measurement_meter_usb_id="";
 $measurement_meter_usb_id=lc($1) if($body=~/"measurement_meter_usb_id"\s*:\s*"([0-9a-fA-F]{4}:[0-9a-fA-F]{4})"/);
 if($measurement_meter_usb_id eq "" && $measurement_meter_port ne "") {
  $measurement_meter_usb_id=&webui_meter_usb_id_for_port($measurement_meter_port);
 }
 my $observer="1931_2";
 $observer=$1 if($body=~/"observer"\s*:\s*"(1931_2|1964_10|2015_2|2015_10)"/);
 # ICC characterisation is defined in the standard CIE 1931 observer. Keep
 # this independent of the chart observer and of transient meter inventory
 # state so tristimulus meters never receive an unsupported spectral mode.
 $observer="1931_2" if($points==990001);
 my $pattern_provider=($body=~/"pattern_provider"\s*:\s*"companion"/i)?"companion":"local";
 if(&webui_meter_is_spyderx($measurement_meter_usb_id,$measurement_meter_port)) {
  $display_type=&webui_spyderx_native_display_type($display_type_key);
  $ccss_file="" if($ccss_file!~/\.ccmx$/i);
  $refresh_rate="";
  # ArgyllCMS can only apply a non-default observer to spectral data or a
  # CCSS-capable colorimeter. SpyderX supports neither path.
  $observer="1931_2";
 }
 # Series requests use the same capability rule as single/continuous reads.
 $observer="1931_2" if(!&webui_meter_port_is_spectro($measurement_meter_port));
 my $require_device_ready=0;
 $require_device_ready=1 if($body=~/"require_device_ready"\s*:\s*true/i);
 $require_device_ready=1 if(!$require_device_ready && &webui_meter_port_is_spectro($measurement_meter_port));
 my $target_gamut="";
 $target_gamut=lc($1) if($body=~/"target_gamut"\s*:\s*"([A-Za-z0-9_]+)"/);
$target_gamut="" unless($target_gamut eq "bt709" || $target_gamut eq "bt2020" || $target_gamut eq "p3d65" || $target_gamut eq "p3dci" || $target_gamut eq "customd65");
 my $custom_d65_enabled=0;
 $custom_d65_enabled=1 if($body=~/"custom_d65_enabled"\s*:\s*true/i || $target_gamut eq "customd65");
 $target_gamut="bt709" if($target_gamut eq "customd65");
 my $target_white_x="";
 $target_white_x=$1 if($body=~/"target_white_x"\s*:\s*"?([0-9.]+)"?/);
 my $target_white_y="";
 $target_white_y=$1 if($body=~/"target_white_y"\s*:\s*"?([0-9.]+)"?/);
 my $series_target_white_y="";
 $series_target_white_y=$1 if($body=~/"series_target_white_y"\s*:\s*"?([0-9.]+)"?/);
 my $series_target_white_y_provided=($body=~/"series_target_white_y"\s*:/) ? 1 : 0;
 my $series_target_white_y_num=($series_target_white_y ne "") ? ($series_target_white_y+0) : 0;
 # Target White / Target Black overrides from the calibration card. A manual
 # white value forces the series white reference; a manual black value is
 # stamped onto every step so chart/server target math anchors to it.
 my $target_white_luminance="";
 $target_white_luminance=$1 if($body=~/"target_white_luminance"\s*:\s*"?([0-9.]+)"?/);
 my $target_black_luminance="";
 $target_black_luminance=$1 if($body=~/"target_black_luminance"\s*:\s*"?([0-9.]+)"?/);
 my $target_white_use_measured=($body=~/"target_white_use_measured"\s*:\s*true/i) ? 1 : 0;
 my $target_black_use_measured=($body=~/"target_black_use_measured"\s*:\s*true/i) ? 1 : 0;
 my $series_has_saved_white_reference=($body=~/"series_has_saved_white_reference"\s*:\s*true/i) ? 1 : 0;
 my $series_has_saved_black_reference=($body=~/"series_has_saved_black_reference"\s*:\s*true/i) ? 1 : 0;
 my $series_reference_white_code=255;
 my $series_reference_black_code=0;
 my $series_reference_input_max=255;
 $series_reference_white_code=int($1) if($body=~/"series_reference_white_code"\s*:\s*(\d+)/);
 $series_reference_black_code=int($1) if($body=~/"series_reference_black_code"\s*:\s*(\d+)/);
 $series_reference_input_max=int($1) if($body=~/"series_reference_input_max"\s*:\s*(\d+)/);
 $series_reference_input_max=255 if($series_reference_input_max<1);
 $series_reference_white_code=$series_reference_input_max if($series_reference_white_code>$series_reference_input_max);
 $series_reference_black_code=$series_reference_input_max if($series_reference_black_code>$series_reference_input_max);
 # Manual white override takes precedence over the measured/autocal reference.
 if(!$target_white_use_measured && $target_white_luminance ne "" && ($target_white_luminance+0)>0) {
  $series_target_white_y_num=$target_white_luminance+0;
  $series_target_white_y_provided=1;
 }
 my $series_target_black_y_num="";
 my $series_target_black_y_source="";
 if(!$target_black_use_measured && $target_black_luminance ne "") {
  $series_target_black_y_num=$target_black_luminance+0;
  $series_target_black_y_source="manual";
 }
 # "Use measured" path: the 0% IRE step is measured early (second, right
 # after the 100% white anchor) but not at t=0, so the chart would sit at
 # 0 nits for the first few patches without a seed. Look up
 # the most recent measured 0% black from the per-signal-mode cache (the
 # worker writes /var/lib/PGenerator/cache/last_black_<sig>_<bpc>_<cf>_<rr>.json
 # at series completion) and stamp it on every step so the chart target
 # is correct from t=0.
 if($target_black_use_measured && $series_target_black_y_num eq "") {
  # $signal_mode is parsed further down in this handler. Pull the cache-key
  # variant inline so this lookup doesn't see undef.
  my $_lb_sig=lc(&webui_pattern_signal_mode($body) || "");
  # Worker names the cache by input_max (1023=10b, 255=8b, 4095=12b), not
  # by max_bpc. Derive input_max from the conf so the keys line up.
  my $_lb_bpc=(defined $pgenerator_conf{"max_bpc"} && $pgenerator_conf{"max_bpc"} ne "") ? int($pgenerator_conf{"max_bpc"}) : 10;
  $_lb_bpc=10 if($_lb_bpc != 8 && $_lb_bpc != 12);
  my $_lb_input_max=($_lb_bpc == 8) ? 255 : (($_lb_bpc == 12) ? 4095 : 1023);
  my $_lb_cf=$series_color_format ne "" ? int($series_color_format) : (int($pgenerator_conf{"color_format"} || 1));
  # Default the cache-key range to FULL (2) when the request omits
  # transport_signal_range. The legacy default of 1 (limited) silently
  # bifurcated the cache between limited and full reads, so a full read
  # after a limited session would miss the stored black and refall
  # through to a meter-floor estimate. The canonical SDR stimulus->code
  # model treats FULL as the source of truth, so FULL is the natural
  # default when no range is specified.
  my $_lb_rr=$transport_signal_range ne "" ? int($transport_signal_range) : 2;
  my $_lb_path="/var/lib/PGenerator/cache/last_black_${_lb_sig}_${_lb_input_max}_${_lb_cf}_${_lb_rr}.json";
  if(-f $_lb_path) {
   my $_lb_json="";
   if(open(my $_lb_fh,"<",$_lb_path)) { local $/; $_lb_json=<$_lb_fh>; close($_lb_fh); }
   if($_lb_json ne "") {
    my $_lb_d=eval { require JSON::PP; JSON::PP::decode_json($_lb_json); };
    if(ref($_lb_d) eq "HASH"
       && ($_lb_d->{"source"} || "") eq "greyscale-0-percent"
       && defined $_lb_d->{"luminance"}) {
     my $_lb_y=$_lb_d->{"luminance"}+0;
     if($_lb_y>=0) {
      $series_target_black_y_num=$_lb_y;
      # Record provenance so the autocal report and chart debug show this
      # is a cached measured black, not a manual override.
      $series_target_black_y_source="cached_measured:" . $_lb_path;
     }
    }
   }
  }
 }
 my $custom_target_white;
 if($custom_d65_enabled && $target_white_x ne "" && $target_white_y ne "") {
  my $x=$target_white_x+0;
  my $y=$target_white_y+0;
  $custom_target_white=[$x,$y] if($x>0 && $y>0 && $x<1 && $y<1 && ($x+$y)<1);
 }
 my $target_gamma="";
 $target_gamma=lc($1) if($body=~/"target_gamma"\s*:\s*"([A-Za-z0-9_.\-]+)"/);
$target_gamma="bt1886" unless($target_gamma eq "bt1886" || $target_gamma eq "2.2" || $target_gamma eq "2.4" || $target_gamma eq "srgb" || $target_gamma eq "st2084");
 my $picture_mode="";
 $picture_mode=$1 if($body=~/"picture_mode"\s*:\s*"([^"\\]{0,160})"/);
 my $request_full_autocal_run_id="";
 $request_full_autocal_run_id=$1 if($body=~/"full_autocal_run_id"\s*:\s*"([^"\\]{1,200})"/);
 my $request_run_id="";
 $request_run_id=$1 if($body=~/"run_id"\s*:\s*"([^"\\]{1,200})"/);
my $signal_mode=&webui_pattern_signal_mode($body);
my $max_luma=&webui_pattern_max_luma($body);
my $min_luma=defined($pgenerator_conf{"min_luma"}) ? ($pgenerator_conf{"min_luma"}+0) : 0.005;
my $max_cll=defined($pgenerator_conf{"max_cll"}) ? ($pgenerator_conf{"max_cll"}+0) : $max_luma;
my $max_fall=defined($pgenerator_conf{"max_fall"}) ? ($pgenerator_conf{"max_fall"}+0) : 400;
$min_luma=$1+0 if($body=~/"min_luma"\s*:\s*"?(\d+(?:\.\d+)?)"?/);
$max_cll=$1+0 if($body=~/"max_cll"\s*:\s*"?(\d+(?:\.\d+)?)"?/);
$max_fall=$1+0 if($body=~/"max_fall"\s*:\s*"?(\d+(?:\.\d+)?)"?/);
my $request_dv_map_mode="";
$request_dv_map_mode=$1 if($body=~/"dv_map_mode"\s*:\s*"?([0-9])"?/);
$request_dv_map_mode="" unless($request_dv_map_mode eq "1" || $request_dv_map_mode eq "2");
my $request_dv_interface="";
$request_dv_interface=$1 if($body=~/"dv_interface"\s*:\s*"?([012])"?/);
my $request_dv_transport="";
$request_dv_transport=$1 if($body=~/"dv_transport"\s*:\s*"([^"\\]{1,32})"/);
$request_dv_transport=&pg_dv_transport_mode($request_dv_transport);
if($signal_mode eq "dv") {
 my $effective_dv_map_mode=$request_dv_map_mode || $pgenerator_conf{"dv_map_mode"} || "2";
 $target_gamma=($effective_dv_map_mode eq "2") ? "2.2" : "st2084";
}
 $transport_signal_range=$signal_range if($transport_signal_range eq "");
 $transport_signal_range=&webui_preferred_rgb_quant_range() if($transport_signal_range eq "");
 $signal_range=$transport_signal_range if($signal_range eq "");
 $pattern_signal_range=$signal_range if($pattern_signal_range eq "");
 $pattern_signal_range=$transport_signal_range if($pattern_signal_range eq "");
		 my $grey_custom_enabled=0;
		 $grey_custom_enabled=1 if($body=~/"grey_custom_enabled"\s*:\s*true/i);
			 my $lg_greyscale_21=0;
			 $lg_greyscale_21=1 if($body=~/"lg_greyscale_21"\s*:\s*true/i);
			 # The LG 22pt manual map was captured for a specific TV's DDC slots.
			 # Keep it gated off so the public 21pt series uses normal stimulus points.
			 $lg_greyscale_21=0;
				 my $lg_autocal_26=0;
				 $lg_autocal_26=1 if($body=~/"lg_autocal_26"\s*:\s*true/i);
				 if($type eq "greyscale" && $signal_mode eq "sdr" && (($points==21 && $lg_greyscale_21) || ($points==26 && $lg_autocal_26))) {
				  # Align the pattern range to the output range (rgb_quant_range, via
				  # signal_range/transport) instead of hardcoding limited. The renderer
				  # outputs per rgb_quant_range, so limited pattern codes on a full
				  # output read dim at 100%. Limited displays still resolve to 1.
				  $pattern_signal_range=$signal_range if($signal_range=~/^[12]$/);
				  $pattern_signal_range=$transport_signal_range if($pattern_signal_range !~ /^[12]$/ && $transport_signal_range=~/^[12]$/);
				 }
 my $series_target_white_reference;
 if(!$series_target_white_y_provided) {
  $series_target_white_reference=&webui_meter_lg_autocal_series_target_reference(
   type=>$type,
   points=>$points,
   lg_autocal_26=>$lg_autocal_26,
   signal_mode=>$signal_mode,
   display_type_key=>$display_type_key,
   display_type=>$display_type,
   target_gamma=>$target_gamma,
   picture_mode=>$picture_mode,
   full_autocal_run_id=>$request_full_autocal_run_id,
   run_id=>$request_run_id
  );
  $series_target_white_y_num=$series_target_white_reference->{"white_y"}+0
   if($series_target_white_reference && ($series_target_white_reference->{"white_y"}+0)>0);
 }
			 my $grey_custom_allowed=$grey_custom_enabled ? 1 : 0;
	 my $grey_steps_11="";
	 $grey_steps_11=$1 if($body=~/"grey_steps_11"\s*:\s*"([0-9.,\s]+)"/);
 my $grey_steps_21="";
 $grey_steps_21=$1 if($body=~/"grey_steps_21"\s*:\s*"([0-9.,\s]+)"/);
 my $grey_steps_30="";
 $grey_steps_30=$1 if($body=~/"grey_steps_30"\s*:\s*"([0-9.,\s]+)"/);
 my $grey_steps_100="";
 $grey_steps_100=$1 if($body=~/"grey_steps_100"\s*:\s*"([0-9.,\s]+)"/);
 my $grey_steps_11_r="";
 $grey_steps_11_r=$1 if($body=~/"grey_steps_11_r"\s*:\s*"([0-9.,\s]+)"/);
 my $grey_steps_11_g="";
 $grey_steps_11_g=$1 if($body=~/"grey_steps_11_g"\s*:\s*"([0-9.,\s]+)"/);
 my $grey_steps_11_b="";
 $grey_steps_11_b=$1 if($body=~/"grey_steps_11_b"\s*:\s*"([0-9.,\s]+)"/);
 my $grey_steps_21_r="";
 $grey_steps_21_r=$1 if($body=~/"grey_steps_21_r"\s*:\s*"([0-9.,\s]+)"/);
 my $grey_steps_21_g="";
 $grey_steps_21_g=$1 if($body=~/"grey_steps_21_g"\s*:\s*"([0-9.,\s]+)"/);
 my $grey_steps_21_b="";
 $grey_steps_21_b=$1 if($body=~/"grey_steps_21_b"\s*:\s*"([0-9.,\s]+)"/);
 my $grey_steps_30_r="";
 $grey_steps_30_r=$1 if($body=~/"grey_steps_30_r"\s*:\s*"([0-9.,\s]+)"/);
 my $grey_steps_30_g="";
 $grey_steps_30_g=$1 if($body=~/"grey_steps_30_g"\s*:\s*"([0-9.,\s]+)"/);
 my $grey_steps_30_b="";
 $grey_steps_30_b=$1 if($body=~/"grey_steps_30_b"\s*:\s*"([0-9.,\s]+)"/);
 my $grey_steps_100_r="";
 $grey_steps_100_r=$1 if($body=~/"grey_steps_100_r"\s*:\s*"([0-9.,\s]+)"/);
 my $grey_steps_100_g="";
 $grey_steps_100_g=$1 if($body=~/"grey_steps_100_g"\s*:\s*"([0-9.,\s]+)"/);
 my $grey_steps_100_b="";
 $grey_steps_100_b=$1 if($body=~/"grey_steps_100_b"\s*:\s*"([0-9.,\s]+)"/);
 my $grey_two_point_low="";
 $grey_two_point_low=$1 if($body=~/"grey_two_point_low"\s*:\s*"?([0-9.]+)"?/);
 my $grey_two_point_high="";
 $grey_two_point_high=$1 if($body=~/"grey_two_point_high"\s*:\s*"?([0-9.]+)"?/);
 # Stimulus must invert the display's target EOTF so the decoded linear on a
 # tracking display lands on the target linear — otherwise chromaticities
 # shift outward (measured appears oversaturated vs target xy).
 my $target_gamma_exp_resolved=($target_gamma eq "bt1886")?2.4:(($target_gamma eq "srgb")?2.4:($target_gamma+0.0));
my $dv_map_mode=($signal_mode eq "dv") ? ($request_dv_map_mode || $pgenerator_conf{"dv_map_mode"} || "2") : "";
my $dv_interface=($signal_mode eq "dv") ? &pg_dv_transport_interface($request_dv_transport) : 0;
 my $target_linear_to_signal=sub {
  my ($v)=@_;
  return 0 if(!defined $v || $v<=0);
  $v=1 if($v>1);
  if($signal_mode eq "dv") {
   return &webui_pattern_pq_encode_normalized($v*10000) if($dv_map_mode eq "1");
   return $v;
  }
  if($target_gamma eq "srgb") {
   return ($v<=0.0031308) ? 12.92*$v : 1.055*($v**(1/2.4))-0.055;
  }
  if($signal_mode eq "hdr10" && $target_gamma eq "st2084") {
   return &webui_pattern_pq_encode_normalized($v*10000);
  }
  return $v**(1/$target_gamma_exp_resolved);
 };
 my $target_signal_to_linear=sub {
  my ($v)=@_;
  return 0 if(!defined $v || $v<=0);
  $v=1 if($v>1);
  if($signal_mode eq "dv") {
   return &webui_pattern_pq_decode_normalized($v)/10000 if($dv_map_mode eq "1");
   return $v;
  }
  if($target_gamma eq "srgb") {
   return ($v<=0.04045) ? $v/12.92 : ((($v+0.055)/1.055)**2.4);
  }
  if($signal_mode eq "hdr10" && $target_gamma eq "st2084") {
   return &webui_pattern_pq_decode_normalized($v)/10000;
  }
  return $v**$target_gamma_exp_resolved;
 };
 my $lg_autocal_26_target_yn_for_stimulus=sub {
  my ($stimulus)=@_;
  return 0 if(!defined $stimulus);
  # Match meter_lg_autocal.pl autocal_sdr_signal_peak():
  #  - Limited + YCbCr: normalize to 109 (super-white peak)
  #  - Full, or Limited + RGB: normalize to 100 (no usable super-white)
  my $peak_div=100.0;
  if($greyscale_patch_limited && int($series_color_format||0) != 0) {
   $peak_div=109.0;
  }
  my $signal=($stimulus+0)/$peak_div;
  $signal=0 if($signal < 0);
  # Limited YCbCr may sit slightly above 1.0 at 109; Full clamps at 1.0.
  my $sig_cap=($peak_div > 100.0) ? 1.1 : 1.0;
  $signal=$sig_cap if($signal > $sig_cap);
  return 0 if($signal <= 0);
  if($target_gamma eq "srgb") {
   return ($signal <= 0.04045) ? ($signal/12.92) : ((($signal+0.055)/1.055)**2.4);
  }
  if($signal_mode eq "dv" && $target_gamma eq "st2084") {
   return &webui_pattern_pq_decode_normalized($signal)/10000;
  }
  if($signal_mode eq "hdr10" && $target_gamma eq "st2084") {
   return &webui_pattern_pq_decode_normalized($signal)/10000;
  }
  my $gamma=($target_gamma eq "2.2") ? 2.2 : 2.4;
  return $signal**$gamma;
 };
 # Cancel any running series and clean up
 &webui_meter_stop();
 &webui_pattern_stop_guard_clear();
 # Brief pause to let killed processes release USB device
 select(undef,undef,undef,0.5);
 if(&webui_meter_series_alive()) {
  return '{"status":"error","message":"Previous meter series is still stopping"}';
 }

 my $series_colorimetry=2;
 $series_colorimetry=$1 if($body=~/"colorimetry"\s*:\s*"?(\d+)"?/);
 $series_colorimetry=int($pgenerator_conf{"colorimetry"} || 2) if($series_colorimetry eq "");
 my $series_primaries=0;
 $series_primaries=$1 if($body=~/"primaries"\s*:\s*"?(\d+)"?/);
 $series_primaries=int($pgenerator_conf{"primaries"} || 0) if($series_primaries eq "");
 $series_color_format=int($pgenerator_conf{"color_format"} || 0) if($series_color_format eq "");
 my $patch_limited=(int($signal_range)==1) ? 1 : 0;
 my $greyscale_patch_limited=$patch_limited;
 if($type eq "greyscale" && $signal_mode eq "sdr" && $pattern_signal_range=~/^[12]$/) {
  $greyscale_patch_limited=(int($pattern_signal_range)==1) ? 1 : 0;
 }
 my $chroma_patch_limited=$patch_limited;
 # Color / saturation patches must honor the active max_bpc the same way
 # the greyscale ladder does (see the bit-depth plumbing in
 # webui_grey_code_for_stimulus and the target_Yn stamp in
 # webui_meter_series_start). The colors and saturations builders
 # hardcoded 8-bit min/span (16..235 Limited / 0..255 Full); on a
 # max_bpc=10 link those 8-bit codes shipped at ~23% of full signal
 # and every patch crushed (the 2026-06-29 SDR greyscale series-read
 # regression, applied here to color / saturation). Mirror the JS
 # bit-depth scaling (meterGreyCodeRange + meterPatchBitDepth): 10-bit
 # Limited min=64 span=876 (matches the HDR10 10-bit Limited table
 # 100%->940 = 64 + 876), 10-bit Full min=0 span=1023 (matches the
 # HDR10 10-bit Full table 100%->1023). 12-bit links are coerced to
 # 10-bit here, matching meterPatchBitDepth().
 my $_chroma_max_bpc=(defined $pgenerator_conf{"max_bpc"} && $pgenerator_conf{"max_bpc"} ne "" && int($pgenerator_conf{"max_bpc"}) >= 10) ? 10 : 8;
 # A paired Companion renders in the target computer's HDR swapchain. Its
 # source-code precision must not follow the unrelated Pi HDMI max_bpc setting.
 # Doing so made otherwise identical HDR series alternate between 8-bit and
 # 10-bit codes whenever the Pi output configuration changed.
 $_chroma_max_bpc=10 if($pattern_provider eq "companion" && $signal_mode eq "hdr10");
 my $chroma_min_code=$chroma_patch_limited ? ($_chroma_max_bpc==10 ? 64 : 16) : 0;
 my $chroma_span_code=$chroma_patch_limited ? ($_chroma_max_bpc==10 ? 876 : 219) : ($_chroma_max_bpc==10 ? 1023 : 255);
 my $chroma_max_code=$chroma_min_code + $chroma_span_code;
 my $chroma_input_max=($_chroma_max_bpc==10) ? 1023 : 255;

 # Build step list as JSON array for the helper script
 # Measurement order: WHITE first (reference), then 0%→95% ascending
 my @steps;
 my $dv_series=($signal_mode eq "dv") ? 1 : 0;
 if($dv_series) {
  # Standard DV carries legal-range 12-bit source RGB inside an RGB 8-bit
  # Full tunnel. Use that source domain for every generated/custom colour.
  $chroma_min_code=256;
  $chroma_span_code=3504;
  $chroma_max_code=3760;
  $chroma_input_max=4095;
 }
 my $dv_greyscale_tunnel_codes=($dv_series && $type eq "greyscale") ? 1 : 0;
 my $dv_series_code_bits=$dv_series ? 12 : 8;
 my $dv_series_code_max=$dv_series ? 4095 : 255;
 my $dv_series_full_range=0;
 my $dv_series_code_min=$dv_series ? 256 : 0;
 my $dv_series_code_span=$dv_series ? 3504 : 255;
 my $dv_series_code_limit=$dv_series_code_min + $dv_series_code_span;
 my @custom_series_steps=&webui_lattice_series_steps_from_body($body,$chroma_min_code,$chroma_span_code,$chroma_input_max);
 @custom_series_steps=&webui_custom_series_steps_from_body($body) if(!scalar(@custom_series_steps));
 if($body=~/"custom_series"\s*:\s*true/i && !scalar(@custom_series_steps)) {
  return "{\"status\":\"error\",\"message\":\"Custom series has no valid patches\"}";
 }
 if(scalar(@custom_series_steps)) {
  # Full custom greyscale runs use measured endpoint patches as references.
  # Keep this server-side ordering guard so a stale/cached WebUI cannot put
  # those references back in import order. The current WebUI also supplies a
  # missing endpoint using the active signal range before posting the queue.
  if($type eq "greyscale" && ($target_white_use_measured || $target_black_use_measured)) {
   # Reorder only. The WebUI is responsible for injecting missing 0%/100%
   # endpoints when Use measured is set and no saved white/black exists
   # (full series via meterCustomGreyscaleRunSteps; Read Selection via
   # meterSelectionRunStepsWithMeasuredEndpoints). Synthesizing here would
   # force a re-measure even when the client intentionally skipped an end
   # because a saved measurement was already available.
   my @remaining=@custom_series_steps;
   my $take_endpoint=sub {
    my($wanted)=@_;
    for(my $i=0;$i<scalar(@remaining);$i++) {
     if($remaining[$i]=~/"ire"\s*:\s*(-?\d+(?:\.\d+)?)/ && abs(($1+0)-$wanted)<0.05) {
      return splice(@remaining,$i,1);
     }
    }
    return ();
   };
   my @leading;
   push @leading,$take_endpoint->(100) if($target_white_use_measured);
   push @leading,$take_endpoint->(0) if($target_black_use_measured);
   @custom_series_steps=(@leading,@remaining);
  }
  @steps=@custom_series_steps;
 } elsif($type eq "greyscale") {
   my @ire_vals;
   my %step_names;
   if($points==2) {
    my $low=30;
    my $high=100;
    my $two_point_max_stimulus=(int($series_color_format||0) != 0 && $signal_mode ne "dv") ? 109 : 100;
    $low=$grey_two_point_low+0 if($grey_two_point_low ne "");
    $high=$grey_two_point_high+0 if($grey_two_point_high ne "");
    $low=0 if($low < 0);
    $low=$two_point_max_stimulus if($low > $two_point_max_stimulus);
    $high=0 if($high < 0);
    $high=$two_point_max_stimulus if($high > $two_point_max_stimulus);
    if($high <= $low) {
     if($low >= $two_point_max_stimulus) { $high=$two_point_max_stimulus; $low=$two_point_max_stimulus-1; }
     else { $high=$low+1; }
    }
    @ire_vals=($low,$high);
    foreach my $v (@ire_vals) {
     my $label=sprintf("%.4f",$v);
     $label=~s/0+$//;
     $label=~s/\.$//;
     my $role=(abs($v-$high)<0.0001)?"High":"Low";
     $step_names{$v}="$role ${label}%";
    }
   } elsif($points==11) {
   @ire_vals=(0,10,20,30,40,50,60,70,80,90,100);
	   } elsif($points==100) {
	    @ire_vals=(0..100);
			   } elsif($points==30 && $signal_mode eq "hdr10") {
				    @ire_vals=(0,1,1.4,2,2.3,2.7,3,3.7,4,6,8,10,15,20,25,30,35,40,45,50,55,60,65,70,75,80,85,90,95,100);
				   } elsif($points==26 && $lg_autocal_26 && ($signal_mode eq "hdr10" || $signal_mode eq "dv")) {
						    @ire_vals=(100,0,90,80,70,60,50,45,40,35,30,25,20,15,10,7,5,4,2.7,2,1.4);
			   } elsif($points==26 && $lg_autocal_26) {
					    # Limited: legal-expanded 26-pt with super-white 105/109.
					    # Full: body 2.3..95 + peak 100 (no 99/105/109). Matches Full
					    # SDR 1D-DPG greyscale anchors (wire/DPG domain 0..1023 1:1).
					    if($greyscale_patch_limited) {
					     @ire_vals=(100,0,2.3,3,4,5,7,10,15,20,25,30,35,40,45,50,55,60,65,70,75,80,85,90,95,99,105,109);
					    } else {
					     @ire_vals=(100,0,2.3,3,4,5,7,10,15,20,25,30,35,40,45,50,55,60,65,70,75,80,85,90,95);
					    }
			   } elsif($points==21 && $lg_greyscale_21) {
					    @ire_vals=(0,2.5,5,7.5,10,15,20,25,30,35,40,45,50,55,60,65,70,75,80,85,90,95,100);
	   } else {
	    @ire_vals=(0,5,10,15,20,25,30,35,40,45,50,55,60,65,70,75,80,85,90,95,100);
	   }
	   my %stimulus_for_slot=map { $_ => $_ } @ire_vals;
			   my $lg_autocal_26_codes=($points==26 && $lg_autocal_26 && $signal_mode eq "sdr") ? 1 : 0;
			   my $lg_hdr20_codes=($points==26 && $lg_autocal_26 && $signal_mode eq "hdr10") ? 1 : 0;
			   my $lg_extended_sdr_codes=(!$lg_autocal_26_codes && (($points==26 && $lg_autocal_26) || ($points==21 && $lg_greyscale_21)) && $signal_mode eq "sdr") ? 1 : 0;
			   my $lg_legal_sdr_ddc_codes=0;
				   # LG manual greyscale follows the TV's 22-point white-balance menu.
				   # Auto Cal builds its own extended 26-point sequence separately.
				   # SDR26 26-anchor table selection dispatches on bit-depth
				   # (max_bpc) AND transport (rgb_quant_range) the same way
				   # the HDR20 ladder below does, so the chart's stimulus
				   # label, the wire code the panel decodes, and the
				   # worker's autocal-26 patch are all consistent for every
				   # combo. The 0% IRE anchor is NOT in the tables -- the
				   # 0%-aware fallback below handles 0% via the active
				   # range's min/span.
				   my %lg_autocal_26_code_10bit_limited=(
				    "2.3"=>84,"3"=>92,"4"=>100,"5"=>108,"7"=>124,"10"=>152,"15"=>196,"20"=>240,"25"=>284,"30"=>328,"35"=>372,"40"=>416,"45"=>460,
				    "50"=>504,"55"=>544,"60"=>588,"65"=>632,"70"=>676,"75"=>720,"80"=>764,"85"=>808,"90"=>852,"95"=>896,"99"=>932,"105"=>984,"109"=>1023
				   );
				   # 10-bit Full: 8bit<<2 (LG DPG index map), peak=1023.
				   # Not linear *1023 — that is off-by-2..4 at mid anchors
				   # (55% 563 vs 560) so the patch and DPG solver diverge.
				   my %lg_autocal_26_code_10bit_full=();
				   # 8-bit Limited: legal-expanded (16..235) extended ladder.
				   my %lg_autocal_26_code_8bit_limited=();
				   # 8-bit Full: linear 0..255, super-white clamps to peak.
				   my %lg_autocal_26_code_8bit_full=();
				   foreach my $k (@ire_vals) {
				    next if($k+0 == 0);
				    my $s=$k+0;
				    my $key=sprintf("%.1f",$k);
				    # 10-bit Full
				    my $sclamp=$s; $sclamp=100 if($sclamp > 100);
				    if($sclamp+0 >= 99.95) {
				     $lg_autocal_26_code_10bit_full{$key}=1023;
				    } else {
				     my $b8=int($sclamp/100*255+0.5);
				     $b8=0 if($b8 < 0); $b8=255 if($b8 > 255);
				     $lg_autocal_26_code_10bit_full{$key}=($b8 << 2);
				    }
				    # 10-bit Limited already in the table above.
				    # 8-bit Full
				    $lg_autocal_26_code_8bit_full{$key}=int($sclamp/100*255+0.5);
				    # 8-bit Limited
				    my $code;
				    if($s <= 100) {
				     $code=int(16 + $s/100*219 + 0.5);
				    } else {
				     $code=int(235 + ($s-100)/9*(255-235) + 0.5);
				    }
				    $lg_autocal_26_code_8bit_limited{$key}=$code;
				   }
				   # SDR26 bit-depth + transport dispatch. Mirrors the
				   # HDR20 4-table pattern below so the chart stimulus
				   # label maps correctly on every (max_bpc ×
				   # rgb_quant_range) combination.
				   my $_ac26_bits=(defined $pgenerator_conf{"max_bpc"} && $pgenerator_conf{"max_bpc"} ne "") ? int($pgenerator_conf{"max_bpc"}) : 10;
				   $_ac26_bits=10 if($_ac26_bits == 12);
				   my %lg_autocal_26_code;
				   if($_ac26_bits == 10 && $greyscale_patch_limited) {
				    %lg_autocal_26_code=%lg_autocal_26_code_10bit_limited;
				   } elsif($_ac26_bits == 10 && !$greyscale_patch_limited) {
				    %lg_autocal_26_code=%lg_autocal_26_code_10bit_full;
				   } elsif($_ac26_bits == 8 && $greyscale_patch_limited) {
				    %lg_autocal_26_code=%lg_autocal_26_code_8bit_limited;
				   } else {
				    %lg_autocal_26_code=%lg_autocal_26_code_8bit_full;
				   }
				   my %lg_autocal_26_stimulus=();
				   foreach my $key (keys %lg_autocal_26_code) {
				    my $code=$lg_autocal_26_code{$key};
				    # Inverse-map the wire code back to stimulus %.
				    # Dispatch on the same bit-depth + transport axes as
				    # the active table (not always the 10-bit Limited
				    # formula) so the chart's stimulus label matches
				    # what the panel actually decoded.
				    my $inv;
				    if($_ac26_bits == 10 && $greyscale_patch_limited) {
				     $inv=($code-64)*100/876;
				    } elsif($_ac26_bits == 10 && !$greyscale_patch_limited) {
				     $inv=($code/1023)*100;
				    } elsif($_ac26_bits == 8 && $greyscale_patch_limited) {
				     $inv=($code-16)*100/219;
				    } else {
				     $inv=($code/255)*100;
				    }
				    $lg_autocal_26_stimulus{$key}=$inv;
			   }
				   # HDR10 26pt table selection follows the live max_bpc
				   # (the WebUI Bit Depth dropdown / PGenerator.conf).
				   # max_bpc=8 → 8-bit codes (limited 16..235 or full 0..255)
				   # and 8-bit link; max_bpc=10 → 10-bit codes (limited
				   # 64..940 or full 0..1023). The 0% step is NOT in the table —
				   # the 0%-aware fallback below uses the active range's
				   # min/span. JS HDR20 build at meterBuildLgAutoCalSteps
				   # honors the same max_bpc so the JS-built steps and the
				   # server-built series read stay in sync.
				   my $_hdr20_bits=(defined $pgenerator_conf{"max_bpc"} && $pgenerator_conf{"max_bpc"} ne "") ? int($pgenerator_conf{"max_bpc"}) : 10;
				   $_hdr20_bits=10 if($_hdr20_bits != 8 && $_hdr20_bits != 10);
				   my %lg_hdr20_code=(
				    "1.4"=>19,"2"=>20,"2.7"=>22,"4"=>25,"5"=>27,"7"=>31,"10"=>38,"15"=>49,"20"=>60,"25"=>71,
				    "30"=>82,"35"=>93,"40"=>104,"45"=>115,"50"=>126,"60"=>147,"70"=>169,"80"=>191,"90"=>213,"100"=>235
				   );
				   my %lg_hdr20_code_10bit_limited=(
				    "1.4"=>76,"2"=>80,"2.7"=>88,"4"=>100,"5"=>108,"7"=>124,"10"=>152,"15"=>196,"20"=>240,"25"=>284,
				    "30"=>328,"35"=>372,"40"=>416,"45"=>460,"50"=>504,"60"=>588,"70"=>676,"80"=>764,"90"=>852,"100"=>940
				   );
				   my %lg_hdr20_code_10bit_full=(
				    "1.4"=>14,"2"=>20,"2.7"=>28,"4"=>41,"5"=>51,"7"=>72,"10"=>102,"15"=>153,"20"=>205,"25"=>256,
				    "30"=>307,"35"=>358,"40"=>409,"45"=>460,"50"=>512,"60"=>614,"70"=>716,"80"=>818,"90"=>921,"100"=>1023
				   );
				   # HDR10 8-bit full table (0..255 range), slot codes are
				   # int(stimulus_pct/100*255+0.5). 100% -> 255, 1.4% -> 4.
				   my %lg_hdr20_code_8bit_full=(
				    "1.4"=>4,"2"=>5,"2.7"=>7,"4"=>10,"5"=>13,"7"=>18,"10"=>26,"15"=>38,"20"=>51,"25"=>64,
				    "30"=>77,"35"=>89,"40"=>102,"45"=>115,"50"=>128,"60"=>153,"70"=>179,"80"=>204,"90"=>230,"100"=>255
				   );
				   my %lg_hdr20_stimulus=();
					   foreach my $key (keys %lg_hdr20_code) {
					    $lg_hdr20_stimulus{$key}=$key+0;
					   }
				   my $lg_hdr20_active_table=\%lg_hdr20_code;
				   if($lg_hdr20_codes && $_hdr20_bits == 10) {
				    $lg_hdr20_active_table=\%lg_hdr20_code_10bit_limited;
				    $lg_hdr20_active_table=\%lg_hdr20_code_10bit_full if(!$greyscale_patch_limited);
				   } elsif($lg_hdr20_codes && $_hdr20_bits == 8) {
				    # 8-bit limited (16..235) shares the numeric table with
				    # %lg_hdr20_code, so that selection is already correct for
				    # Limited panels. For Full panels, switch to the 8-bit
				    # full table (0..255).
				    $lg_hdr20_active_table=\%lg_hdr20_code_8bit_full if(!$greyscale_patch_limited);
				   }
				   my $lg_hdr20_min_code=(!$lg_hdr20_codes) ? 64
				    : ($_hdr20_bits == 10 && !$greyscale_patch_limited) ? 0
				    : ($_hdr20_bits == 8) ? 0
				    : 64;
				   my $lg_hdr20_span_code=(!$lg_hdr20_codes) ? 876
				    : ($_hdr20_bits == 10 && !$greyscale_patch_limited) ? 1023
				    : ($_hdr20_bits == 10) ? 876
				    : 255;
			   if($points==26 && $lg_autocal_26 && $signal_mode eq "sdr") {
			    foreach my $slot (@ire_vals) {
			     my $key=$slot;
			     $key=~s/\.0$//;
			     $stimulus_for_slot{$slot}=$lg_autocal_26_stimulus{$key} if(exists($lg_autocal_26_stimulus{$key}));
			    }
			   } elsif($lg_hdr20_codes) {
			    foreach my $slot (@ire_vals) {
			     my $key=$slot;
			     $key=~s/\.0$//;
			     $stimulus_for_slot{$slot}=$lg_hdr20_stimulus{$key} if(exists($lg_hdr20_stimulus{$key}));
			    }
			   } elsif($points==21 && $lg_greyscale_21) {
			    my %lg_autocal_stimulus=(
			     "0"=>0,"2.1"=>2.1,"3.8"=>3.8,"5.9"=>5.9,
			     "2.5"=>6.7,"5"=>9.2,"7.5"=>11.3,"10"=>13.8,"15"=>18.4,"20"=>23,"25"=>27.6,"30"=>32.2,
			     "35"=>34.3,"40"=>38.9,"45"=>43.5,"50"=>48.1,"55"=>52.7,"60"=>57.3,"65"=>61.9,
			     "70"=>64,"75"=>68.6,"80"=>73.2,"85"=>77.8,"90"=>82.4,"95"=>87,"100"=>91.6
			    );
			    foreach my $slot (@ire_vals) {
			     my $key=$slot;
			     $key=~s/\.0$//;
			     $stimulus_for_slot{$slot}=$lg_autocal_stimulus{$key} if(exists($lg_autocal_stimulus{$key}));
			    }
			   }
  my %channel_stimulus_for_slot;
	   if($grey_custom_allowed && $points!=2) {
   my $csv=$points==11 ? $grey_steps_11 : ($points==30 ? $grey_steps_30 : ($points==100 ? $grey_steps_100 : $grey_steps_21));
    my @vals=grep { $_ ne "" } map { my $v=$_; $v=~s/^\s+|\s+$//g; $v } split(/,/,$csv || "");
    if(@vals == @ire_vals) {
     my $prev=-1;
     for(my $idx=0;$idx<scalar(@ire_vals);$idx++) {
      my $stim=$vals[$idx] + 0;
      $stim=0 if($stim < 0);
      $stim=100 if($stim > 100);
      $stim=$prev if($stim < $prev);
      $stimulus_for_slot{$ire_vals[$idx]}=$stim;
      $prev=$stim;
     }
    }
   }
   foreach my $channel (qw(r g b)) {
    $channel_stimulus_for_slot{$channel}={ map { $_ => $stimulus_for_slot{$_} } @ire_vals };
   }
	   if($grey_custom_allowed && $points!=2) {
    my %channel_csv=(
     "r" => ($points==11 ? $grey_steps_11_r : ($points==30 ? $grey_steps_30_r : ($points==100 ? $grey_steps_100_r : $grey_steps_21_r))),
     "g" => ($points==11 ? $grey_steps_11_g : ($points==30 ? $grey_steps_30_g : ($points==100 ? $grey_steps_100_g : $grey_steps_21_g))),
     "b" => ($points==11 ? $grey_steps_11_b : ($points==30 ? $grey_steps_30_b : ($points==100 ? $grey_steps_100_b : $grey_steps_21_b)))
    );
    foreach my $channel (keys %channel_csv) {
     my @vals=grep { $_ ne "" } map { my $v=$_; $v=~s/^\s+|\s+$//g; $v } split(/,/,$channel_csv{$channel} || "");
     next unless(@vals == @ire_vals);
     for(my $idx=0;$idx<scalar(@ire_vals);$idx++) {
      my $stim=$vals[$idx] + 0;
      $stim=0 if($stim < 0);
      $stim=100 if($stim > 100);
      $channel_stimulus_for_slot{$channel}{$ire_vals[$idx]}=$stim;
     }
    }
   }
     my $lim=$greyscale_patch_limited;
    # Delegate stimulus->code to the shared helper. Pass the active HDR20
    # table directly so a custom DDC upload stays in sync with the ladder.
    # max_bpc flows through so the HDR20 branch picks 8-bit codes when the
    # operator has the link at 8-bit (1.6 WORKING A/B test).
    my %_opts_for_grey=(
     hdr20_codes => ($lg_hdr20_codes ? 1 : 0),
     max_bpc => ($pattern_provider eq "companion" && $signal_mode eq "hdr10") ? 10
      : ((defined $pgenerator_conf{"max_bpc"} && $pgenerator_conf{"max_bpc"} ne "") ? $pgenerator_conf{"max_bpc"} : ""),
     autocal_26 => (($points==26 && $lg_autocal_26) ? 1 : 0),
     autocal_26_codes => ($lg_autocal_26_codes ? 1 : 0),
     extended_sdr_codes => ($lg_extended_sdr_codes ? 1 : 0),
     legal_sdr_ddc_codes => ($lg_legal_sdr_ddc_codes ? 1 : 0),
     two_point_ycbcr_headroom => (($points==2 && int($series_color_format||0) != 0 && $signal_mode ne "dv") ? 1 : 0),
     dv_series => ($dv_series ? 1 : 0),
     dv_series_code_bits => (defined($dv_series_code_bits) ? $dv_series_code_bits : 8),
     dv_series_full_range => ($dv_series_full_range ? 1 : 0),
    );
    $_opts_for_grey{"active_table"}=$lg_hdr20_active_table if($lg_hdr20_codes && ref($lg_hdr20_active_table) eq "HASH");
    my $grey_code_for_stim=sub {
     my ($stimulus_pct)=@_;
     my ($c,$im)=&webui_grey_code_for_stimulus($stimulus_pct,$signal_mode,$target_gamma,$lim,\%_opts_for_grey);
     return $c;
    };
   # Sample the helper once to discover the series-level input_max. The
   # standard SDR/HDR10/HLG/extended/legal-SDR-DDC branches now honor the
   # conf max_bpc (was hardcoded 255), and webui_meter_series_start must
   # stamp the matching input_max on every step so meter_series.sh +
   # pattern_request_body dispatch a bit-perfect pattern over the wire.
   # The autocal-26 / DV / HDR20 branches above stamp their own input_max
   # via the $extra lines below; this default branch covers everything
   # else. Sample at 50% IRE — mid-range, inside the bit-depth math —
   # and stash the returned input_max for the $extra stamp below.
   my $series_input_max=255;
   my ($_sample_c,$_sample_im)=&webui_grey_code_for_stimulus(50,$signal_mode,$target_gamma,$lim,\%_opts_for_grey);
   $series_input_max=$_sample_im if(defined $_sample_im && $_sample_im >= 0 && ($_sample_im == 255 || $_sample_im == 1023));
   # Reference first, then black for contrast, then the remaining LG 26pt
   # steps ascend from near black through headroom. The delayed legal-white
   # read gives post-cal charts a fresh target-Y basis before any low-level
   # reads are taken.
  my @ordered;
  if($points==2) {
   @ordered=((sort { $a <=> $b } @ire_vals)[1], (sort { $a <=> $b } @ire_vals)[0]);
  } elsif($points==26 && $lg_autocal_26 && ($signal_mode eq "hdr10" || $signal_mode eq "dv")) {
   # The hdr20 ladder ends at a REAL 100% DDC slot, so there is no separate
   # legal-white reference step (that is an SDR 99/105/109 headroom concept);
   # the worker derives its white reference from the hdr20 top slot itself.
   # Emitting the SDR-style reference here duplicated the 100% step and made
   # the top-slot solve fight a locked twin. Note: $lg_autocal_26_codes is
   # defined as sdr-only, so the prior "&& $lg_autocal_26_codes && hdr10"
   # form of this branch was dead code; the condition here keys off
   # $lg_autocal_26 + hdr10 directly so the branch is actually taken.
   @ordered=(0,sort { $a <=> $b } grep { $_>0 } @ire_vals);
  } elsif($lg_autocal_26_codes) {
   if($greyscale_patch_limited) {
    # Limited: legal white first, black, then ascending body/headroom.
    @ordered=(100,0,sort { $a <=> $b } grep { $_>0 && abs($_-100)>0.001 } @ire_vals);
   } else {
    # Full: 0 → 100 → 50 → 25 → 75 → 100(recal) → descend 95..2.3 (no 99/105/109).
    # Series list cannot duplicate IRE 100 as two thumbs; worker still runs a
    # second peak pass after 75% (sdr26_white_recal). Flow shows single 100.
    # Mid-spine 50/25/75 are solved early then revisited on the way down
    # (after 80 / 55 / 30) so neighbors can pull them. Matches worker order.
    my @full_flow=(0,100,50,25,75,95,90,85,80,75,70,65,60,55,50,45,40,35,30,25,20,15,10,7,5,4,3,2.3);
    my %have=map { (0+$_) => 1 } @ire_vals;
    $have{0}=1; # always allow black even if missing from @ire_vals
    @ordered=grep { $have{0+$_} } @full_flow;
    foreach my $v (@ire_vals) {
     next if(grep { abs((0+$_)-(0+$v)) < 0.001 } @ordered);
     push @ordered,$v;
    }
   }
  } else {
   @ordered=(100, sort { $a <=> $b } grep { $_ != 100 } @ire_vals);
  }
   foreach my $v (@ordered) {
    $stimulus_for_slot{$v}=$v if(!defined($stimulus_for_slot{$v}));
    foreach my $channel (qw(r g b)) {
     $channel_stimulus_for_slot{$channel}{$v}=$stimulus_for_slot{$v} if(!defined($channel_stimulus_for_slot{$channel}{$v}));
    }
   }
   @steps=map {
    my $v=$_;
     my $stim=$stimulus_for_slot{$v};
    my $r_stim=$channel_stimulus_for_slot{"r"}{$v};
    my $g_stim=$channel_stimulus_for_slot{"g"}{$v};
    my $b_stim=$channel_stimulus_for_slot{"b"}{$v};
    my $r_code=$grey_code_for_stim->($r_stim);
    my $g_code=$grey_code_for_stim->($g_stim);
    my $b_code=$grey_code_for_stim->($b_stim);
    my $analysis_ire=$v;
    if($points==21 && $lg_greyscale_21) {
     my $analysis_code=($g_code+0);
     $analysis_ire=($analysis_code<=16) ? 0 : (($analysis_code-16)*100/219);
     $analysis_ire=100 if($analysis_ire > 100);
     $analysis_ire=0 if($analysis_ire < 0);
     $analysis_ire=sprintf("%.4f",$analysis_ire)+0;
    }
     my $name=exists $step_names{$v} ? $step_names{$v} : "${v}%";
     my $role="";
     $role="high" if($points==2 && $name=~/^High /);
     $role="low" if($points==2 && $name=~/^Low /);
    my $extra="";
    $extra.=",\"point_role\":\"$role\"" if($points==2);
	    $extra.=",\"series_type\":\"greyscale\",\"signal_r_pct\":$r_stim,\"signal_g_pct\":$g_stim,\"signal_b_pct\":$b_stim";
	    $extra.=",\"final_white_refresh\":true" if($points==21 && !$lg_greyscale_21 && !$lg_autocal_26 && abs($v-100)<0.001);
	    $extra.=",\"analysis_ire\":$analysis_ire,\"target_ire\":$analysis_ire,\"transport_stimulus\":$stim" if($points==21 && $lg_greyscale_21);
		    $extra.=",\"input_max\":1023" if($lg_autocal_26_codes);
		    $extra.=",\"input_max\":4095" if($dv_series && $dv_series_code_bits == 12);
		    # HDR10 26pt: input_max follows max_bpc. 10 → input_max=1023 (10-bit codes);
		    # 8 → input_max=255 (8-bit codes; matches the 1.6 WORKING
		    # YCbCr limited 8-bit A/B test). meter_series.sh / patch_request_body
		    # read input_max to decide the scale-on-the-wire conversion.
		    $extra.=",\"input_max\":1023" if($lg_hdr20_codes && $_hdr20_bits == 10);
		    $extra.=",\"input_max\":255" if($lg_hdr20_codes && $_hdr20_bits == 8);
		    # Standard SDR / HDR10 / HLG / extended-SDR / legal-SDR-DDC greyscale:
		    # stamp the bit-depth-aware input_max ($series_input_max, sampled
		    # from the helper above) so meter_series.sh + pattern_request_body
		    # dispatch a bit-perfect pattern. Mutually exclusive with the
		    # autocal-26 / DV / HDR20 stamps above; this branch only fires
		    # when none of those are active. Two-point steps need the same
		    # explicit input_max: without it the Companion path treated HDR
		    # codes such as 307 as 8-bit and clamped the low patch to white.
		    if(!$lg_autocal_26_codes && !$dv_series && !$lg_hdr20_codes) {
		     $extra.=",\"input_max\":$series_input_max";
		    }
		    if($lg_autocal_26_codes) {
		     my $step_read_delay_ms=0;
		     $step_read_delay_ms=3000 if(abs($v-100)<0.001);
		     $step_read_delay_ms=6000 if($v > 0 && $v <= 10);
		     $step_read_delay_ms=3200 if($v > 10 && $v <= 25);
		     $extra.=",\"read_delay_ms\":$step_read_delay_ms" if($step_read_delay_ms > $delay_ms);
		    }
		    if($lg_autocal_26_codes) {
		     my $target_Yn_for_step=$lg_autocal_26_target_yn_for_stimulus->($stim);
		     $extra.=",\"target_x\":0.3127,\"target_y\":0.329,\"target_Yn\":$target_Yn_for_step";
		    }
		    if(!$lg_autocal_26_codes && $signal_mode eq "sdr" && $r_code==$g_code && $g_code==$b_code) {
		     my $target_min_code=$dv_series ? 16 : ($lg_extended_sdr_codes ? 16 : ($lg_legal_sdr_ddc_codes ? 16 : ($lim ? 16 : 0)));
		     my $target_span_code=$dv_series ? 219 : ($lg_extended_sdr_codes ? 239 : ($lg_legal_sdr_ddc_codes ? 219 : ($lim ? 219 : 255)));
		     # Greyscale target_Yn is the relative signal (code-min)/span
		     # converted to linear via the active EOTF; chart then scales it
		     # to measured white. After the 10-bit code fix above the codes
		     # are 10-bit Limited (min=64 span=876), 10-bit Full (min=0
		     # span=1023), or 10-bit extended-sdr (min=64 span=956) when
		     # max_bpc=10, so the legacy 8-bit (min=16 span=219) formula
		     # produces target_signal = 4.22 at 100% IRE → clamped to 1.0
		     # (and ~0.42 at 5% IRE, which then chart-scales to ~28 nits
		     # on a 244-nit panel). Mirror the bit-depth scaling from
		     # webui_grey_code_for_stimulus so target_Yn == 1.0 at 100%
		     # IRE, ~0.05^2.4 at 5% IRE, regardless of the active max_bpc.
		     # $series_input_max is the bit-depth probe sampled from the
		     # helper at series-build time (1023 at 10-bit, 255 at 8-bit).
		     # DV's target math is its own 8/10-bit ladder via
		     # $dv_series_code_bits; the existing 16/219 formula was a
		     # pre-existing approximation we leave untouched.
		     if(!$dv_series && $points==2 && int($series_color_format||0) != 0) {
		      # YCbCr Default is Limited even when signal_range is 0. Its
		      # two-point code field can extend above legal white, but target
		      # normalisation remains anchored at 940/235 and clamps the
		      # 100..109% headroom segment at reference white.
		      if($series_input_max == 1023) { $target_min_code=64; $target_span_code=876; }
		      else { $target_min_code=16; $target_span_code=219; }
		     } elsif(!$dv_series && $series_input_max == 1023) {
		      if($lg_extended_sdr_codes) {
		       # Extended SDR tops out at FULL scale, so 10-bit is 64..1023
		       # (span 959). 956 was the 8-bit span 239 upshifted by 4.
		       $target_min_code=64; $target_span_code=959;
		      } elsif($lg_legal_sdr_ddc_codes) {
		       $target_min_code=64; $target_span_code=876;
		      } elsif($lim) {
		       $target_min_code=64; $target_span_code=876;
		      } else {
		       $target_min_code=0; $target_span_code=1023;
		      }
		     }
		     # Custom greyscale must only change the patch code that is sent
		     # ($r/$g/$b above, derived from $stim), NOT the target. The target
		     # signal is the nominal slot position on the EOTF ($v/100), so the
		     # stamped target_Yn and the chart target line stay anchored to the
		     # slot regardless of the custom stimulus value. The code-derived
		     # formula below is preserved for every other path (autocal-26 uses
		     # its own branch above; DV/HDR20/2-point/non-custom all need the
		     # emitted code's signal).
		     my $target_signal;
		     if($grey_custom_allowed && !$lg_autocal_26_codes && !$lg_hdr20_codes && !$dv_series && $points!=2) {
		      $target_signal=($v+0)/100;
		     } else {
		      $target_signal=$target_span_code>0 ? (($g_code-$target_min_code)/$target_span_code) : 0;
		     }
		     $target_signal=0 if($target_signal < 0);
		     $target_signal=1 if($target_signal > 1);
		     my $target_Yn_for_step=$target_signal_to_linear->($target_signal);
		     $target_Yn_for_step=0 if($target_Yn_for_step < 0);
		     $extra.=",\"target_Yn\":$target_Yn_for_step";
		    }
		    if($lg_autocal_26_codes && $signal_mode ne "hdr10" && abs($v-100)<0.001) {
		     if($greyscale_patch_limited) {
		      # Limited: 100% patch is the legal-white reference (maps to DDC 99).
		      $extra.=",\"autocal_white_reference\":true,\"autocal_reference_only\":true,\"autocal_read_only\":true,\"autocal_slot_locked\":true,\"ddc_slot_locked\":true,\"autocal_legal_white_anchor\":true,\"ddc_target_ire\":99,\"autocal_order_ire\":98.95,\"autocal_target_label\":\"100% legal white\"";
		     } else {
		      # Full: 100% is the true peak (no legal-white / 99 overlay).
		      $extra.=",\"autocal_white_reference\":true,\"autocal_slot_locked\":true,\"ddc_slot_locked\":true,\"autocal_order_ire\":100,\"autocal_target_label\":\"100% full peak\"";
		     }
		    }
    "{\"ire\":$v,\"stimulus\":$stim,\"r\":$r_code,\"g\":$g_code,\"b\":$b_code,\"name\":\"$name\"$extra}";
   } @ordered;
 } elsif($type eq "colors") {
  # min/span/max_code are computed bit-depth-aware in the outer scope
  # (chroma_min_code etc., set just above the step-build) so the colors
  # ladder honors max_bpc like the greyscale ladder. See comment above
  # on $_chroma_max_bpc for the 10-bit Limited / Full math.
  my $min_code=$chroma_min_code;
  my $span_code=$chroma_span_code;
    my $max_code=$chroma_max_code;
      my %primaries=%{&webui_meter_gamut_definitions()};
    my $colorimetry=int($series_colorimetry);
    my $primaries_idx=int($series_primaries);
    my $container_key="bt709";
    if($signal_mode eq "dv") {
     $container_key="bt2020";
    } elsif($signal_mode eq "hdr10" || $signal_mode eq "hlg") {
     $container_key="bt2020";
    } elsif($colorimetry == 9) {
     $container_key="bt2020";
    }
    my $auto_target_key=$container_key;
    if($signal_mode eq "dv") {
     $auto_target_key="p3d65";
    } elsif($signal_mode eq "hdr10") {
      # HDR10 targets P3-D65 by default (consumer HDR is mastered to P3 inside
      # the BT.2020 container); an explicit DCI primaries pick selects P3-DCI.
      $auto_target_key="p3d65";
      $auto_target_key="p3dci" if($primaries_idx == 3);
    } elsif($signal_mode eq "hlg") {
      $auto_target_key="p3d65" if($primaries_idx == 2);
      $auto_target_key="p3dci" if($primaries_idx == 3);
    }
    my $target_key=$target_gamut ne "" ? $target_gamut : $auto_target_key;
    # Relative DV retains its established target-gamut solve. Absolute DV uses
    # PQ RGB carried in the BT.2020 container, so its target chromaticity must
    # be solved into BT.2020 RGB just like HDR10. Sending P3 RGB coefficients
    # in that container expands the measured chromaticity beyond the P3 target.
    # HDR10 uses the same container solve. target_key remains the scoring gamut
    # and the mastering metadata may still advertise P3 primaries.
    my $solve_key=($signal_mode eq "hlg" || $signal_mode eq "hdr10" || ($signal_mode eq "dv" && $dv_map_mode eq "1")) ? $container_key : $target_key;
    my @target_white=@{$primaries{$target_key}{WHITE}};
    @target_white=@$custom_target_white if($custom_target_white && ($target_key eq "bt709" || $target_key eq "bt2020" || $target_key eq "p3d65"));
    my ($target_wx,$target_wy)=@target_white;
    my @solve_white=@{$primaries{$solve_key}{WHITE}};
    @solve_white=@target_white if($custom_target_white && ($solve_key eq "bt709" || $solve_key eq "bt2020" || $solve_key eq "p3d65"));
    my ($solve_wx,$solve_wy)=@solve_white;
    my @MI=@{$primaries{$solve_key}{M}};
    my @SOLVE_RGB_TO_XYZ=@{$primaries{$solve_key}{RGB_TO_XYZ}};
    my @RGB_TO_XYZ=@{$primaries{$target_key}{RGB_TO_XYZ}};
    my $dv_classic_scale=0.68;
    # BT.2408 HDR Reference White for ColorChecker patches in HDR10 and
    # DV-Absolute. Both neutral and chromatic reflectance samples are anchored
    # to the same 203 cd/m^2 diffuse white. The separate White patch remains
    # full code so it can establish the display peak.
    my $bt2408_ref_white_nits=203;
    my $encode_linear=sub {
     my ($linear,$ref_nits_override)=@_;
     $linear=0 if(!defined $linear || $linear < 0);
     $linear=1 if($linear > 1);
     if($signal_mode eq "dv" && $dv_map_mode ne "1") {
      $linear*=$dv_classic_scale;
      $linear=1 if($linear > 1);
     }
      my $encoded=0;
      if($signal_mode eq "hdr10" || ($signal_mode eq "dv" && $dv_map_mode eq "1")) {
       # Callers for HDR10 and DV-Absolute ColorChecker reflectance patches
       # pass the BT.2408 203 cd/m^2 reference explicitly. Other PQ callers
       # retain the measured-white/mastering-peak fallback below.
       my $cc_ref=($series_target_white_y_num>0)?$series_target_white_y_num:((($max_luma+0)>0)?($max_luma+0):100);
       my $ref=(defined $ref_nits_override && $ref_nits_override>0)?$ref_nits_override:$cc_ref;
       $encoded=&webui_pattern_pq_encode_normalized($linear*$ref);
      } elsif($signal_mode eq "hlg") {
       # Keep HLG correction local to ColorChecker. The shared target encoder
       # also serves saturation sweeps whose inverse model is still separate.
       my $x=$linear*12;
       $encoded=($x<=1) ? .5*sqrt($x) : .17883277*log($x-.28466892)+.55991073;
      } elsif($signal_mode eq "dv") {
        $encoded=$linear>0 ? $linear**(1/2.2) : 0;
      } else {
       $encoded=$target_linear_to_signal->($linear);
      }
     return int($min_code + $encoded*$span_code + .5);
    };
    my $decode_linear=sub {
     my ($signal)=@_;
     $signal=0 if(!defined $signal || $signal < 0);
     $signal=1 if($signal > 1);
     if($signal_mode eq "hdr10" || ($signal_mode eq "dv" && $dv_map_mode eq "1")) {
      return &webui_pattern_pq_decode_normalized($signal)/100;
     }
     if($signal_mode eq "dv") {
      return ($signal**2.2)/$dv_classic_scale;
     }
     return $target_signal_to_linear->($signal);
    };
    my @solve_xy=map {
     my $sum=$SOLVE_RGB_TO_XYZ[0][$_]+$SOLVE_RGB_TO_XYZ[1][$_]+$SOLVE_RGB_TO_XYZ[2][$_];
     [
      $sum>0 ? $SOLVE_RGB_TO_XYZ[0][$_]/$sum : $solve_wx,
      $sum>0 ? $SOLVE_RGB_TO_XYZ[1][$_]/$sum : $solve_wy
     ]
    } (0,1,2);
    my $remap_relative_dv_color_xy=sub {
     my ($sx,$sy)=@_;
     return ($sx,$sy) unless($signal_mode eq "dv" && $dv_map_mode ne "1");
         my ($wx,$wy)=($solve_wx,$solve_wy);
     my ($dx,$dy)=($sx-$wx,$sy-$wy);
     return ($sx,$sy) if(abs($dx)<1e-9 && abs($dy)<1e-9);
     my $best_t;
     for(my $idx=0;$idx<@solve_xy;$idx++) {
      my ($ax,$ay)=@{$solve_xy[$idx]};
      my ($bx,$by)=@{$solve_xy[($idx+1)%@solve_xy]};
      my ($ex,$ey)=($bx-$ax,$by-$ay);
      my ($qx,$qy)=($ax-$wx,$ay-$wy);
      my $den=$dx*$ey-$dy*$ex;
      next if(abs($den)<1e-9);
      my $t=($qx*$ey-$qy*$ex)/$den;
      my $u=($qx*$dy-$qy*$dx)/$den;
      next unless($t>0 && $u>=-1e-9 && $u<=1+1e-9);
      $best_t=$t if(!defined $best_t || $t<$best_t);
     }
     return ($sx,$sy) unless(defined $best_t && $best_t>0);
     my $f=1/$best_t;
     $f=0 if($f<0);
     $f=1 if($f>1);
     my $compressed=$f-0.8*$f*$f*(1-$f);
     return ($wx,$wy) unless($f>1e-9);
     my $scale=$compressed/$f;
     return ($wx+$dx*$scale,$wy+$dy*$scale);
    };
    my @classic=(
    ["Gray 35","gray",0.090],
    ["Gray 50","gray",0.198],
    ["Gray 65","gray",0.362],
    ["Gray 80","gray",0.591],
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
    if($points==29) {
     # HCFR Classic GCD is defined by fixed legal-range video RGB levels,
     # not by reverse-solving xyY through PGenerator's selected transfer.
     # HDR uses the same source values and applies HCFR's conversion below.
     @classic=(
      ["Gray 35","hcfr_rgb",62.10,62.10,62.10],["Gray 50","hcfr_rgb",73.06,73.06,73.06],
      ["Gray 65","hcfr_rgb",82.19,82.19,82.19],["Gray 80","hcfr_rgb",89.95,89.95,89.95],
      ["Dark Skin","hcfr_rgb",45.20,31.96,26.03],["Light Skin","hcfr_rgb",75.80,58.90,51.14],
      ["Blue Sky","hcfr_rgb",36.99,47.95,61.19],["Foliage","hcfr_rgb",35.16,42.01,26.03],
      ["Blue Flower","hcfr_rgb",51.14,50.23,68.95],["Bluish Green","hcfr_rgb",38.81,73.97,66.21],
      ["Orange","hcfr_rgb",84.93,47.03,15.98],["Purplish Blue","hcfr_rgb",29.22,36.07,63.93],
      ["Moderate Red","hcfr_rgb",75.80,32.88,37.90],["Purple","hcfr_rgb",36.07,24.20,42.01],
      ["Yellow Green","hcfr_rgb",62.10,73.06,25.11],["Orange Yellow","hcfr_rgb",89.95,63.01,17.81],
      ["Blue","hcfr_rgb",20.09,24.20,58.90],["Green","hcfr_rgb",27.85,57.99,27.85],
      ["Red","hcfr_rgb",68.95,19.18,22.83],["Yellow","hcfr_rgb",93.15,78.08,12.79],
      ["Magenta","hcfr_rgb",73.06,32.88,57.08],["Cyan","hcfr_rgb",0,52.05,63.93]
     );
    }
    # Solve a D65-referred ColorChecker xyY into the active transport gamut
    # while keeping its adapted reference as the scoring target.
    my $build_reference_color=sub {
     my ($target_x,$target_y,$Yn)=@_;
     $Yn=0 if(!defined $Yn || $Yn<0);
     if($target_y>0) {
      my ($aX,$aY,$aZ)=&webui_meter_bradford_adapt_xyz($target_x/$target_y*$Yn,$Yn,(1-$target_x-$target_y)/$target_y*$Yn,0.3127,0.3290,$target_wx,$target_wy);
      my $sum=$aX+$aY+$aZ;
      ($target_x,$target_y)=($sum>0?$aX/$sum:$target_wx,$sum>0?$aY/$sum:$target_wy);
      $Yn=$aY>0?$aY:0;
     }
     my ($emit_x,$emit_y)=($target_x,$target_y);
     ($emit_x,$emit_y)=$remap_relative_dv_color_xy->($emit_x,$emit_y);
     my $X=$emit_y>0 ? $emit_x/$emit_y*$Yn : 0;
     my $Y=$Yn;
     my $Z=$emit_y>0 ? (1-$emit_x-$emit_y)/$emit_y*$Yn : 0;
     my $rl=$MI[0][0]*$X+$MI[0][1]*$Y+$MI[0][2]*$Z;
     my $gl=$MI[1][0]*$X+$MI[1][1]*$Y+$MI[1][2]*$Z;
     my $bl=$MI[2][0]*$X+$MI[2][1]*$Y+$MI[2][2]*$Z;
     my $mx=$rl;$mx=$gl if($gl>$mx);$mx=$bl if($bl>$mx);
     my $stimulus_scale=1;
     if($mx>1+1e-6){$rl/=$mx;$gl/=$mx;$bl/=$mx;$stimulus_scale=1/$mx;}
     $rl=0 if($rl<0);$gl=0 if($gl<0);$bl=0 if($bl<0);
     my $scaled_Yn=$Yn*$stimulus_scale;
     my $target_Yn=$scaled_Yn;
     my ($r,$g,$b);
     if($signal_mode eq "hdr10" || ($signal_mode eq "dv" && $dv_map_mode eq "1")) {
      my $cc_white=($series_target_white_y_num>0)?$series_target_white_y_num:((($max_luma+0)>0)?($max_luma+0):100);
      $r=$encode_linear->($rl,$bt2408_ref_white_nits);
      $g=$encode_linear->($gl,$bt2408_ref_white_nits);
      $b=$encode_linear->($bl,$bt2408_ref_white_nits);
      $target_Yn=$cc_white>0 ? $scaled_Yn*$bt2408_ref_white_nits/$cc_white : 0;
     } else {
      $r=$encode_linear->($rl);
      $g=$encode_linear->($gl);
      $b=$encode_linear->($bl);
      if($signal_mode eq "dv" && $span_code>0) {
       my @norm=map { my $v=($_-$min_code)/$span_code;$v=0 if($v<0);$v=1 if($v>1);$v } ($r,$g,$b);
       my @lin=map { $decode_linear->($_) } @norm;
       $target_Yn=$RGB_TO_XYZ[1][0]*$lin[0]+$RGB_TO_XYZ[1][1]*$lin[1]+$RGB_TO_XYZ[1][2]*$lin[2];
       $target_Yn=0 if($target_Yn<0);
      }
     }
     return ($r,$g,$b,$target_x,$target_y,$target_Yn,$Yn);
    };
    my $build_hcfr_fixed_rgb=sub {
     my ($r_pct,$g_pct,$b_pct)=@_;
     my @source_signal=map { my $v=($_+0)/100; $v=0 if($v<0); $v=1 if($v>1); $v } ($r_pct,$g_pct,$b_pct);
     if($signal_mode eq "hdr10" || $signal_mode eq "hlg") {
      my @source_linear=map { $_**2.22 } @source_signal;
      my @SRC=@{$primaries{bt709}{RGB_TO_XYZ}};
      my @DST_INV=@{$primaries{bt2020}{M}};
      my @DST=@{$primaries{bt2020}{RGB_TO_XYZ}};
      my $X=$SRC[0][0]*$source_linear[0]+$SRC[0][1]*$source_linear[1]+$SRC[0][2]*$source_linear[2];
      my $Y=$SRC[1][0]*$source_linear[0]+$SRC[1][1]*$source_linear[1]+$SRC[1][2]*$source_linear[2];
      my $Z=$SRC[2][0]*$source_linear[0]+$SRC[2][1]*$source_linear[1]+$SRC[2][2]*$source_linear[2];
      my $scale=($signal_mode eq "hdr10") ? (94.37844/10000) : 1;
      my @container=(
       ($DST_INV[0][0]*$X+$DST_INV[0][1]*$Y+$DST_INV[0][2]*$Z)*$scale,
       ($DST_INV[1][0]*$X+$DST_INV[1][1]*$Y+$DST_INV[1][2]*$Z)*$scale,
       ($DST_INV[2][0]*$X+$DST_INV[2][1]*$Y+$DST_INV[2][2]*$Z)*$scale
      );
      @container=map { $_<0?0:($_>1?1:$_) } @container;
      my @encoded=map {
       if($signal_mode eq "hdr10") { &webui_pattern_pq_encode_normalized($_*10000) }
       else { my $x=$_*12; $x<=1 ? .5*sqrt($x) : .17883277*log($x-.28466892)+.55991073 }
      } @container;
      my @q=map { int($_*219+.5)/219 } @encoded;
      my @codes=map { int($min_code+$_*$span_code+.5) } @q;
      my @decoded=map {
       if($signal_mode eq "hdr10") { &webui_pattern_pq_decode_normalized($_)/10000 }
       elsif($_<=.5) { 4*$_*$_/12 }
       else { (exp(($_-.55991073)/.17883277)+.28466892)/12 }
      } @q;
      my $tX=$DST[0][0]*$decoded[0]+$DST[0][1]*$decoded[1]+$DST[0][2]*$decoded[2];
      my $tY=$DST[1][0]*$decoded[0]+$DST[1][1]*$decoded[1]+$DST[1][2]*$decoded[2];
      my $tZ=$DST[2][0]*$decoded[0]+$DST[2][1]*$decoded[1]+$DST[2][2]*$decoded[2];
      my $sum=$tX+$tY+$tZ;
      my $tx=$sum>0?$tX/$sum:$target_wx; my $ty=$sum>0?$tY/$sum:$target_wy;
      my $target_Yn=$tY;
      if($signal_mode eq "hdr10") {
       my $white_ref=($series_target_white_y_num>0)?$series_target_white_y_num:((($max_luma+0)>0)?($max_luma+0):100);
       $target_Yn=$white_ref>0 ? $tY*10000/$white_ref : 0;
      }
      return (\@codes,$tx,$ty,$target_Yn,$Y);
     }
     my @codes=map { int($min_code+$_*$span_code+.5) } @source_signal;
     my @linear=($signal_mode eq "sdr")
      ? (map { $target_signal_to_linear->($_) } @source_signal)
      : (map { $decode_linear->($span_code>0?(($_-$min_code)/$span_code):0) } @codes);
     my @FIXED=@{$primaries{bt709}{RGB_TO_XYZ}};
     my $X=$FIXED[0][0]*$linear[0]+$FIXED[0][1]*$linear[1]+$FIXED[0][2]*$linear[2];
     my $Y=$FIXED[1][0]*$linear[0]+$FIXED[1][1]*$linear[1]+$FIXED[1][2]*$linear[2];
     my $Z=$FIXED[2][0]*$linear[0]+$FIXED[2][1]*$linear[1]+$FIXED[2][2]*$linear[2];
     my $sum=$X+$Y+$Z;
     my $neutral=(abs($source_signal[0]-$source_signal[1])<1e-9 && abs($source_signal[1]-$source_signal[2])<1e-9) ? 1 : 0;
     if($neutral && ($source_signal[0]<=1e-9 || $source_signal[0]>=1-1e-9)) {
      my $level=$source_signal[0]>=1-1e-9?1:0;
      my $code=$level?$max_code:$min_code;
      return ([$code,$code,$code],$target_wx,$target_wy,$level,$level);
     }
     # Preserve the existing relative-DV tunnel; only SDR fixed-code colors are
     # re-solved here. HCFR HDR10/HLG returned from the branch above.
     if($signal_mode eq "dv") {
      return (\@codes,$sum>0?$X/$sum:$target_wx,$sum>0?$Y/$sum:$target_wy,$Y,$Y);
     }
     if($neutral) {
      return (\@codes,$target_wx,$target_wy,$Y,$Y);
     }
     my ($r,$g,$b,$tx,$ty,$target_Yn,$nominal_Y)=$build_reference_color->($X/$sum,$Y/$sum,$Y);
     return ([$r,$g,$b],$tx,$ty,$target_Yn,$nominal_Y);
    };
    if($points==29) {
     foreach my $endpoint (["White",100,100,100],["Black",0,0,0]) {
      my ($name,$rp,$gp,$bp)=@$endpoint;
      my ($codes,$tx,$ty,$target_Yn,$nominal_Y)=$build_hcfr_fixed_rgb->($rp,$gp,$bp);
      my $ire=int($nominal_Y*100+.5);
      push @steps, "{\"ire\":$ire,\"r\":$$codes[0],\"g\":$$codes[1],\"b\":$$codes[2],\"name\":\"$name\",\"target_x\":$tx,\"target_y\":$ty,\"target_Yn\":$target_Yn,\"input_max\":$chroma_input_max,\"series_mode\":\"hcfr-gcd-$signal_mode\"}";
     }
    } else {
     push @steps, "{\"ire\":100,\"r\":$max_code,\"g\":$max_code,\"b\":$max_code,\"name\":\"White\",\"target_x\":$target_wx,\"target_y\":$target_wy,\"target_Yn\":1,\"input_max\":$chroma_input_max}";
     push @steps, "{\"ire\":0,\"r\":$min_code,\"g\":$min_code,\"b\":$min_code,\"name\":\"Black\",\"target_x\":$target_wx,\"target_y\":$target_wy,\"target_Yn\":0,\"input_max\":$chroma_input_max}";
    }
    foreach my $src (@classic) {
     my ($name,$kind,@vals)=@$src;
	     if($kind eq "hcfr_rgb") {
	      my ($codes,$tx,$ty,$target_Yn,$nominal_Y)=$build_hcfr_fixed_rgb->(@vals[0..2]);
	      my $ire=int($nominal_Y*100+.5);
	      push @steps, "{\"ire\":$ire,\"r\":$$codes[0],\"g\":$$codes[1],\"b\":$$codes[2],\"name\":\"$name\",\"target_x\":$tx,\"target_y\":$ty,\"target_Yn\":$target_Yn,\"input_max\":$chroma_input_max,\"series_mode\":\"hcfr-gcd-$signal_mode\"}";
	      next;
	     }
	     if($kind eq "gray") {
	      my $level=$vals[0];
	      my $absolute_hdr_colorchecker=($signal_mode eq "hdr10" || ($signal_mode eq "dv" && $dv_map_mode eq "1")) ? 1 : 0;
	      my $code=$absolute_hdr_colorchecker
	       ? $encode_linear->($level,$bt2408_ref_white_nits)
	       : $encode_linear->($level);
	      my $ire=int($level*100 + .5);
	      my $target_Yn_for_step=$level;
	      if($absolute_hdr_colorchecker) {
	       my $cc_white=($series_target_white_y_num>0)?$series_target_white_y_num:((($max_luma+0)>0)?($max_luma+0):100);
	       $target_Yn_for_step=$cc_white>0 ? $level*$bt2408_ref_white_nits/$cc_white : 0;
	      } elsif($signal_mode eq "dv" && $span_code>0) {
	       my $norm=($code-$min_code)/$span_code;
	       $norm=0 if($norm < 0); $norm=1 if($norm > 1);
	       $target_Yn_for_step=$decode_linear->($norm);
	       $target_Yn_for_step=0 if($target_Yn_for_step < 0);
	      }
	      push @steps, "{\"ire\":$ire,\"r\":$code,\"g\":$code,\"b\":$code,\"name\":\"$name\",\"target_x\":$target_wx,\"target_y\":$target_wy,\"target_Yn\":$target_Yn_for_step,\"input_max\":$chroma_input_max}";
	      next;
	     }
      my ($target_x,$target_y,$Yn)=@vals;
      my ($r,$g,$b,$chart_tx,$chart_ty,$target_Yn_for_step,$nominal_Yn)=$build_reference_color->($target_x,$target_y,$Yn);
      my $ire=int($nominal_Yn*100 + .5);
      push @steps, "{\"ire\":$ire,\"r\":$r,\"g\":$g,\"b\":$b,\"name\":\"$name\",\"target_x\":$chart_tx,\"target_y\":$chart_ty,\"target_Yn\":$target_Yn_for_step,\"input_max\":$chroma_input_max}";
     }
  # Endpoint names describe the selected target gamut. In HDR10 that is
  # normally P3-D65 carried in a BT.2020 container, so derive the endpoint xy
  # from the target matrix and reverse-solve it through the container matrix
  # $MI. The measured-white stimulus level below keeps those mixed BT.2020
  # codes inside the characterized range instead of driving them at 10,000
  # cd/m2.
  my @STIM_RGB_TO_XYZ=@{$primaries{$target_key}{RGB_TO_XYZ}};
  my $series_level_pct=(($signal_mode eq "hdr10") ? 100 : (($signal_mode eq "dv") ? 50 : 75));
   my $encode_saturation_linear=sub {
    my ($linear)=@_;
    $linear=0 if(!defined $linear || $linear < 0);
    $linear=1 if($linear > 1);
    if($signal_mode eq "hdr10" || ($signal_mode eq "dv" && $dv_map_mode eq "1")) {
     my $signal=&webui_pattern_pq_encode_normalized($linear*10000);
     $signal=int($signal*219+.5)/219 if($points==29);
     return int($min_code + $signal*$span_code + .5);
    }
	   if($signal_mode eq "dv") {
	    # The standard-DV tunnel declares Tgamma=2.2. Encode linear RGB
	    # through that transfer function, matching the saturation-series
	    # builder below; a raw-linear code is decoded by the TV a second
	    # time and makes these ColorChecker gamut endpoints far too dim.
	    return int($min_code + ($linear ** (1/2.2))*$span_code + .5);
	   }
    my $signal=$target_linear_to_signal->($linear);
    $signal=int($signal*219+.5)/219 if($points==29);
    return int($min_code + $signal*$span_code + .5);
   };
   my $series_level_request=$series_level_pct/100;
  my $series_level_code=0;
  {
   my $series_level_encoded=$series_level_request;
   if($signal_mode eq "dv" && $dv_map_mode ne "1") {
    $series_level_encoded=$target_linear_to_signal->($series_level_request);
   }
   $series_level_code=int($min_code + $series_level_encoded*$span_code + .5);
   }
   my $series_level_signal=$span_code>0?($series_level_code-$min_code)/$span_code:0;
	  my $series_level_linear=($signal_mode eq "hdr10" || ($signal_mode eq "dv" && $dv_map_mode eq "1")) ? (&webui_pattern_pq_decode_normalized($series_level_signal)/10000) : $target_signal_to_linear->($series_level_signal);
   if($points==29) {
    $series_level_linear=94.37844/10000 if($signal_mode eq "hdr10");
    $series_level_linear=1 if($signal_mode eq "sdr" || $signal_mode eq "hlg");
    $series_level_linear=.5 if($signal_mode eq "dv");
   }
   # 100% colour endpoints must stay inside the measured display range. In
   # HDR10 the full-drive container level is 10,000 cd/m2: encoding endpoints
   # there sends codes the characterization never measured, so every corrected
   # path (compositor or application cLUT) grades them against inverse-table
   # extrapolation and the reads collapse toward white. Anchor the wire
   # stimulus to the measured series white instead. Target math is unchanged:
   # target_Yn stays relative to the same measured white, and WRGB displays
   # keep their separate endpoint grading.
   my $series_stimulus_linear=$series_level_linear;
   if($signal_mode eq "hdr10" && $points!=29) {
    my $white_ref=($series_target_white_y_num>0)?$series_target_white_y_num:((($max_luma+0)>0)?($max_luma+0):1000);
    $series_stimulus_linear=$white_ref/10000 if($white_ref>0 && $white_ref<=10000);
   }
   my $build_color_series_full_sat_codes=sub {
    my ($r_mix,$g_mix,$b_mix)=@_;
    my $mix_X=$STIM_RGB_TO_XYZ[0][0]*$r_mix+$STIM_RGB_TO_XYZ[0][1]*$g_mix+$STIM_RGB_TO_XYZ[0][2]*$b_mix;
    my $mix_Y=$STIM_RGB_TO_XYZ[1][0]*$r_mix+$STIM_RGB_TO_XYZ[1][1]*$g_mix+$STIM_RGB_TO_XYZ[1][2]*$b_mix;
    my $mix_Z=$STIM_RGB_TO_XYZ[2][0]*$r_mix+$STIM_RGB_TO_XYZ[2][1]*$g_mix+$STIM_RGB_TO_XYZ[2][2]*$b_mix;
    my $mix_sum=$mix_X+$mix_Y+$mix_Z;
    my $px=$mix_sum>0?$mix_X/$mix_sum:$solve_wx;
    my $py=$mix_sum>0?$mix_Y/$mix_sum:$solve_wy;
    my ($r,$g,$b)=($min_code,$min_code,$min_code);
    if($py>0) {
     my $X=$px/$py; my $Y=1; my $Z=(1-$px-$py)/$py;
     my $rl=$MI[0][0]*$X+$MI[0][1]*$Y+$MI[0][2]*$Z;
     my $gl=$MI[1][0]*$X+$MI[1][1]*$Y+$MI[1][2]*$Z;
     my $bl=$MI[2][0]*$X+$MI[2][1]*$Y+$MI[2][2]*$Z;
     my $mx=$rl;$mx=$gl if $gl>$mx;$mx=$bl if $bl>$mx;
     if($mx>0){$rl/=$mx;$gl/=$mx;$bl/=$mx;}
     $rl=0 if $rl<0;$gl=0 if $gl<0;$bl=0 if $bl<0;
     $rl*=$series_stimulus_linear;$gl*=$series_stimulus_linear;$bl*=$series_stimulus_linear;
     $r=$encode_saturation_linear->($rl);
     $g=$encode_saturation_linear->($gl);
     $b=$encode_saturation_linear->($bl);
    }
    return ($r,$g,$b);
   };
    foreach my $sat (
     ["100% Red","Red",1,0,0],
     ["100% Green","Green",0,1,0],
     ["100% Blue","Blue",0,0,1],
     ["100% Cyan","Cyan",0,1,1],
     ["100% Magenta","Magenta",1,0,1],
     ["100% Yellow","Yellow",1,1,0]
	    ) {
	     my ($name,$series_color,$r_mix,$g_mix,$b_mix)=@$sat;
	     my ($r,$g,$b)=$build_color_series_full_sat_codes->($r_mix,$g_mix,$b_mix);
	     my $target_mix_X=$RGB_TO_XYZ[0][0]*$r_mix+$RGB_TO_XYZ[0][1]*$g_mix+$RGB_TO_XYZ[0][2]*$b_mix;
	     my $target_mix_Y=$RGB_TO_XYZ[1][0]*$r_mix+$RGB_TO_XYZ[1][1]*$g_mix+$RGB_TO_XYZ[1][2]*$b_mix;
	     my $target_mix_Z=$RGB_TO_XYZ[2][0]*$r_mix+$RGB_TO_XYZ[2][1]*$g_mix+$RGB_TO_XYZ[2][2]*$b_mix;
	     my $target_mix_sum=$target_mix_X+$target_mix_Y+$target_mix_Z;
	     my $target_x=$target_mix_sum>0?$target_mix_X/$target_mix_sum:$target_wx;
	     my $target_y=$target_mix_sum>0?$target_mix_Y/$target_mix_sum:$target_wy;
	     my $target_Yn_for_step=$series_level_linear*$target_mix_Y;
	     if($points==29 && $signal_mode eq "hdr10") {
	      my $white_ref=($series_target_white_y_num>0)?$series_target_white_y_num:((($max_luma+0)>0)?($max_luma+0):100);
	      $target_Yn_for_step=$white_ref>0 ? (94.37844/$white_ref)*$target_mix_Y : 0;
	     }
	     $target_Yn_for_step=0 if($target_Yn_for_step < 0);
	     my $series_mode_json=$points==29?',\"series_mode\":\"hcfr-constant-luminance\"':'';
	     push @steps, "{\"ire\":100,\"r\":$r,\"g\":$g,\"b\":$b,\"name\":\"$name\",\"series_color\":\"$series_color\",\"sat_pct\":100,\"target_x\":$target_x,\"target_y\":$target_y,\"target_Yn\":$target_Yn_for_step,\"input_max\":$chroma_input_max$series_mode_json}";
	    }
 } elsif($type eq "saturations") {
  # min/span/max_code are computed bit-depth-aware in the outer scope
  # (chroma_min_code etc., set just above the step-build) so the
  # saturation sweep honors max_bpc like the greyscale ladder. See
  # comment above on $_chroma_max_bpc for the 10-bit Limited / Full
  # math.
  my $min_code=$chroma_min_code;
  my $span_code=$chroma_span_code;
  my $max_code=$chroma_max_code;
  my %primaries=%{&webui_meter_gamut_definitions()};
  my $colorimetry=int($series_colorimetry);
  my $primaries_idx=int($series_primaries);
  my $container_key="bt709";
  if($signal_mode eq "dv") {
   $container_key="bt2020";
  } elsif($signal_mode eq "hdr10" || $signal_mode eq "hlg") {
   $container_key="bt2020";
  } elsif($colorimetry == 9) {
   $container_key="bt2020";
  }
  my $auto_target_key=$container_key;
  if($signal_mode eq "dv") {
   $auto_target_key="p3d65";
  } elsif($signal_mode eq "hdr10") {
    # HDR10 targets P3-D65 by default (consumer HDR is mastered to P3 inside
    # the BT.2020 container); an explicit DCI primaries pick selects P3-DCI.
    $auto_target_key="p3d65";
    $auto_target_key="p3dci" if($primaries_idx == 3);
  } elsif($signal_mode eq "hlg") {
    $auto_target_key="p3d65" if($primaries_idx == 2);
    $auto_target_key="p3dci" if($primaries_idx == 3);
  }
  my $target_key=$target_gamut ne "" ? $target_gamut : $auto_target_key;
  my @target_white=@{$primaries{$target_key}{WHITE}};
  @target_white=@$custom_target_white if($custom_target_white && ($target_key eq "bt709" || $target_key eq "bt2020" || $target_key eq "p3d65"));
  my ($target_wx,$target_wy)=@target_white;
  # HDR10 and DV Absolute both carry PQ RGB in the BT.2020 container. Express
  # the selected target chromaticities (normally P3-D65) as BT.2020 RGB so the
  # wire stimulus and the P3 scoring target describe the same colour. Relative
  # DV retains its established target-gamut tunnel behavior; HLG stays on the
  # BT.2020 container too.
  my $solve_key=($signal_mode eq "hlg" || $signal_mode eq "hdr10" || ($signal_mode eq "dv" && $dv_map_mode eq "1")) ? $container_key : $target_key;
  my @solve_white=@{$primaries{$solve_key}{WHITE}};
  @solve_white=@target_white if($custom_target_white && ($solve_key eq "bt709" || $solve_key eq "bt2020" || $solve_key eq "p3d65"));
  my ($solve_wx,$solve_wy)=@solve_white;
  my @MI=@{$primaries{$solve_key}{M}};
  my @AXIS_RGB_TO_XYZ=@{$primaries{$target_key}{RGB_TO_XYZ}};
  # The native sweep runs at a sub-peak level so sub-100% saturations do not
  # clip to white. HCFR authors a different, constant-Y sequence: SDR and HLG
  # use a unit-linear reference, while HDR10 maps that reference to HCFR's
  # fixed 94.37844 cd/m2 diffuse white before applying the PQ OETF.
  my $level_pct=((($signal_mode eq "hdr10") || ($signal_mode eq "dv")) ? 50 : 75);
  my $hcfr_constant_luminance=($points==25)?1:0;
  # $max_code is the outer-scope bit-depth-aware $chroma_max_code set
  # at the top of the step-build; no need to recompute here.
	  # White first (reference Y), then saturation sweeps.
	  push @steps, "{\"ire\":100,\"r\":$max_code,\"g\":$max_code,\"b\":$max_code,\"name\":\"White\",\"target_x\":$target_wx,\"target_y\":$target_wy,\"target_Yn\":1,\"input_max\":$chroma_input_max}";
	  my $encode_channel=sub {
   my ($linear,$color_name)=@_;
   $linear=0 if(!defined $linear || $linear < 0);
   $linear=1 if($linear > 1);
   if($signal_mode eq "hdr10" || ($signal_mode eq "dv" && $dv_map_mode eq "1")) {
    return int($min_code + &webui_pattern_pq_encode_normalized($linear*10000)*$span_code + .5);
   }
	   if($signal_mode eq "dv") {
	    # Dolby Vision patches ride a GAMMA 2.2 tunnel (Tgamma = 2.2 in the
	    # DOLBY_CFG_DATA we upload), so a linear channel value has to be
	    # gamma-encoded like every other mode encodes for its own transfer
	    # function. This used to write the raw LINEAR value straight into the
	    # code -- the same bug class as the three raw-linear series/level writes
	    # removed earlier -- and $target_linear_to_signal is identity for DV, so
	    # falling through would not have fixed it either.
	    #
	    # Effect on hardware: the panel applied 2.2 to a value that was already
	    # linear, crushing the two minor channels of every saturation patch and
	    # pushing it out to the gamut edge. A DV RGB-Full sweep measured Red
	    # 50/75/100% at x=0.6783 -- identical to 4dp, i.e. all three sitting on
	    # the red primary -- with under 0.3 cd/m2 between them. Modelling the raw
	    # linear write predicts those measurements to mean |dxy| 0.0149 against
	    # 0.0787 for a correct encode, and reproduces the collapse exactly
	    # (predicted Red 50/75/100 = 0.6720/0.6795/0.6800).
	    return int($min_code + ($linear ** (1/2.2))*$span_code + .5);
	   }
   return int($min_code + $target_linear_to_signal->($linear)*$span_code + .5);
  };
  # Match frontend meterActualSignalPercent()/meterCodeFromSignalPercent().
  # In DV + ST2084 target mode the requested level is treated as a direct
  # tunnel code percentage first, then decoded back through the active DV
  # tunnel EOTF to get the actual linear stimulus after quantization.
  my $level_request=$level_pct/100;
  my $level_code=0;
  {
   my $level_encoded=$level_request;
   if($signal_mode eq "dv" && $dv_map_mode ne "1") {
    $level_encoded=$target_linear_to_signal->($level_request);
   }
   $level_code=int($min_code + $level_encoded*$span_code + .5);
  }
  my $level_signal=$span_code>0?($level_code-$min_code)/$span_code:0;
  my $hcfr_pq_reference_nits=94.37844;
  my $hcfr_level_linear=1;
  $hcfr_level_linear=$hcfr_pq_reference_nits/10000 if($signal_mode eq "hdr10");
  # HCFR has no Dolby Vision generator mode. Preserve PGenerator's existing
  # safe DV adaptation instead of presenting an invented full-scale stimulus.
  $hcfr_level_linear=0.5 if($signal_mode eq "dv");
  my $encode_hcfr_channel=sub {
   my ($linear)=@_;
   $linear=0 if(!defined $linear || $linear < 0);
   $linear=1 if($linear > 1);
   my $signal=0;
   if($signal_mode eq "hdr10") {
    $signal=&webui_pattern_pq_encode_normalized($linear*10000);
   } elsif($signal_mode eq "hlg") {
    # ITU-R BT.2100 HLG OETF, matching HCFR getL_EOTF(..., mode=-7).
    $signal=($linear<=1/12)
     ? sqrt(3*$linear)
     : 0.17883277*log(12*$linear-0.28466892)+0.55991073;
   } elsif($signal_mode eq "dv") {
    $signal=$linear**(1/2.2);
   } else {
    # HCFR fixes saturation-pattern encoding at gamma 2.22, independently of
    # the analysis gamma selected by the user.
    $signal=$linear**(1/2.22);
   }
   $signal=0 if($signal<0);$signal=1 if($signal>1);
   # HCFR re-quantizes generated HDR patterns to its 8-bit legal-video
   # lattice before handing them to the generator. Keep those same 219
   # intervals when PGenerator transports the patch at 8 or 10 bits.
   my $quantized=int($signal*219+.5)/219;
   return int($min_code+$quantized*$span_code+.5);
  };
  # The two DV saturation-fraction remaps that used to live here are gone.
  # Absolute applied  f + 0.8*f*(1-f)  and Relative  f - 0.8*f*f*(1-f), so a
  # patch labelled "Red 25%" actually targeted 40% saturation (25/50/75/100 ->
  # 40/70/90/100), which is what a DV RGB-Full sweep measured its targets
  # sitting at. Both were empirical pre-distortions compensating for the
  # raw-linear channel encode fixed above in $encode_channel: they bent the
  # TARGET toward the broken measurement instead of correcting the signal, so
  # the sweep was neither a true saturation sweep nor comparable with any other
  # tool. With the encode correct, DV uses the same f = sat/100 as every other
  # signal mode, and any residual DV-engine error now shows up as measured
  # error rather than being hidden inside the target.
  # Reference sat-sweep target_Yn to measured white so target_Yn*measured = the
  # patch's reachable absolute luminance (sweep runs sub-peak/50% so it is
  # reachable) and the white patch (target_Yn=1) targets the measured peak
  # instead of 10000. series_target_white_y is the measured white the client
  # passes; fall back to mastering peak.
  my $sat_white_ref=($series_target_white_y_num>0)?$series_target_white_y_num:((($max_luma+0)>0)?($max_luma+0):10000);
  foreach my $color (["Red",1,0,0],["Green",0,1,0],["Blue",0,0,1],["Cyan",0,1,1],["Magenta",1,0,1],["Yellow",1,1,0]) {
   my ($name,$r_mix,$g_mix,$b_mix)=@$color;
	    my $level_linear=($signal_mode eq "hdr10" || ($signal_mode eq "dv" && $dv_map_mode eq "1"))
	     ? (&webui_pattern_pq_decode_normalized($level_signal)/10000)
	     : $target_signal_to_linear->($level_signal);
    my $mix_X=$AXIS_RGB_TO_XYZ[0][0]*$r_mix+$AXIS_RGB_TO_XYZ[0][1]*$g_mix+$AXIS_RGB_TO_XYZ[0][2]*$b_mix;
    my $mix_Y=$AXIS_RGB_TO_XYZ[1][0]*$r_mix+$AXIS_RGB_TO_XYZ[1][1]*$g_mix+$AXIS_RGB_TO_XYZ[1][2]*$b_mix;
    my $mix_Z=$AXIS_RGB_TO_XYZ[2][0]*$r_mix+$AXIS_RGB_TO_XYZ[2][1]*$g_mix+$AXIS_RGB_TO_XYZ[2][2]*$b_mix;
   my $mix_sum=$mix_X+$mix_Y+$mix_Z;
  my $px=$mix_sum>0?$mix_X/$mix_sum:$target_wx;
  my $py=$mix_sum>0?$mix_Y/$mix_sum:$target_wy;
   my @sat_levels=$hcfr_constant_luminance ? (0,25,50,75,100) : (25,50,75,100);
   foreach my $sat (@sat_levels) {
    my $f=$sat/100;
    my $tx=$target_wx+$f*($px-$target_wx);
    my $ty=$target_wy+$f*($py-$target_wy);
    my ($r,$g,$b)=($min_code,$min_code,$min_code);
	    my $target_Yn_for_step=0;
	    if($ty>0){
	     my $X=$tx/$ty; my $Y=1; my $Z=(1-$tx-$ty)/$ty;
	     my $rl=$MI[0][0]*$X+$MI[0][1]*$Y+$MI[0][2]*$Z;
	     my $gl=$MI[1][0]*$X+$MI[1][1]*$Y+$MI[1][2]*$Z;
	     my $bl=$MI[2][0]*$X+$MI[2][1]*$Y+$MI[2][2]*$Z;
	     my $mx=$rl;$mx=$gl if $gl>$mx;$mx=$bl if $bl>$mx;
	     if($hcfr_constant_luminance) {
	      # HCFR saturation sweeps keep Y fixed at the endpoint luma K while
	      # chromaticity moves from white to the primary/secondary. Each hue has
	      # its own 0% neutral (RGB=K), so all five HCFR CHC slots are measured.
	      $rl*=$mix_Y;$gl*=$mix_Y;$bl*=$mix_Y;
	      $target_Yn_for_step=($signal_mode eq "hdr10" && $sat_white_ref>0)
	       ? (($hcfr_pq_reference_nits/$sat_white_ref)*$mix_Y)
	       : ($hcfr_level_linear*$mix_Y);
	     } else {
	      # Native PGenerator sweep keeps the maximum channel fixed.
	      $target_Yn_for_step=($level_linear/$mx)*(($signal_mode eq "sdr") ? 1 : (($sat_white_ref>0)?(10000/$sat_white_ref):1)) if($mx>0);
	      if($mx>0){$rl/=$mx;$gl/=$mx;$bl/=$mx;}
	     }
	     $rl=0 if $rl<0;$gl=0 if $gl<0;$bl=0 if $bl<0;
	     my $stimulus_level=$hcfr_constant_luminance?$hcfr_level_linear:$level_linear;
	     $rl*=$stimulus_level;$gl*=$stimulus_level;$bl*=$stimulus_level;
	    $r=$hcfr_constant_luminance?$encode_hcfr_channel->($rl):$encode_channel->($rl,$name);
	    $g=$hcfr_constant_luminance?$encode_hcfr_channel->($gl):$encode_channel->($gl,$name);
	    $b=$hcfr_constant_luminance?$encode_hcfr_channel->($bl):$encode_channel->($bl,$name);
	    }
	    $target_Yn_for_step=0 if($target_Yn_for_step < 0);
	    my $series_mode_json=$hcfr_constant_luminance?',\"series_mode\":\"hcfr-constant-luminance\"':'';
	    push @steps, "{\"ire\":$sat,\"r\":$r,\"g\":$g,\"b\":$b,\"name\":\"$name $sat%\",\"series_color\":\"$name\",\"sat_pct\":$sat,\"target_x\":$tx,\"target_y\":$ty,\"target_Yn\":$target_Yn_for_step,\"input_max\":$chroma_input_max$series_mode_json}";
	   }
	  }
	 }

	 # Colour, saturation, and profiling series do not necessarily contain
	 # neutral endpoints. When "Use measured" is enabled, prepend reference-only
	 # white/black reads before any scored patch. The cached black luminance is
	 # useful for target math while a run starts, but it is not a measurement in
	 # this series and cannot be exported. Always acquire a real black reference
	 # unless the client supplied an actual saved reading.
	 if($type ne "greyscale") {
	  my($white_index,$black_index)=(-1,-1);
	  for(my $index=0;$index<scalar(@steps);$index++) {
	   my $step=$steps[$index];
	   my $decoded=eval { require JSON::PP; JSON::PP::decode_json($step); };
	   next unless(ref($decoded) eq "HASH");
	   my $name=lc($decoded->{"name"} || "");
	   my $r=defined($decoded->{"r"}) ? $decoded->{"r"}+0 : -1;
	   my $g=defined($decoded->{"g"}) ? $decoded->{"g"}+0 : -2;
	   my $b=defined($decoded->{"b"}) ? $decoded->{"b"}+0 : -3;
	   next unless($r==$g && $g==$b);
	   $white_index=$index if($white_index<0
	    &&($r==$series_reference_white_code || $name eq "white" || $name eq "100% white" || $name eq "white ref"));
	   $black_index=$index if($black_index<0
	    &&($r==$series_reference_black_code || $name eq "black" || $name eq "0% black" || $name eq "black ref"));
	  }
	  my @reference_steps;
	  if($target_white_use_measured && !$series_has_saved_white_reference) {
	   if($white_index>=0) {
	    my $white_step=splice(@steps,$white_index,1);
	    # Custom series often name full-scale neutral by source code (for
	    # example "255"). Mark the endpoint so the worker publishes the same
	    # measurement as white_reading instead of using a synthetic target.
	    if($white_step!~/"series_white_reference"\s*:/) {
	     $white_step=~s/\}\s*$//;
	     $white_step.=',"series_white_reference":true}';
	    }
	    push @reference_steps,$white_step;
	    $black_index-- if($black_index>$white_index);
	   } else {
	    push @reference_steps,'{"ire":100,"stimulus":100,"signal_r_pct":100,"signal_g_pct":100,"signal_b_pct":100'
	     .',"r":'.$series_reference_white_code.',"g":'.$series_reference_white_code.',"b":'.$series_reference_white_code
	     .',"input_max":'.$series_reference_input_max.',"name":"White Ref","series_type":"reference","series_white_reference":true}';
	   }
	  }
	  if($target_black_use_measured && !$series_has_saved_black_reference) {
	   if($black_index>=0) {
	    push @reference_steps,splice(@steps,$black_index,1);
	   } else {
	    push @reference_steps,'{"ire":0,"stimulus":0,"signal_r_pct":0,"signal_g_pct":0,"signal_b_pct":0'
	     .',"r":'.$series_reference_black_code.',"g":'.$series_reference_black_code.',"b":'.$series_reference_black_code
	     .',"input_max":'.$series_reference_input_max.',"name":"Black Ref","series_type":"reference"}';
	   }
	  }
	  @steps=(@reference_steps,@steps) if(@reference_steps);
	 }

	 my $stamp_series_target_white_y=0;
	 # LG 26pt greyscale post-cal reads must target the series' own 100% white
	 # read. AutoCal-derived white is useful audit context, but stamping it as
	 # series_target_white_y makes post-cal charts use the old calibration basis.
	 # Stamp manual/explicit white peak on greyscale and on color/sat steps so
	 # Read Selection custom_steps (and full custom color runs) honor the
	 # calibration-card Target White the same way greyscale already does.
	 $stamp_series_target_white_y=1 if($series_target_white_y_provided
	  && !($type eq "greyscale" && $points==26 && $lg_autocal_26)
	  && ($type eq "greyscale" || $type eq "colors" || $type eq "saturations"));
 my $series_target_white_audit="";
 if($series_target_white_reference && $series_target_white_y_num>0) {
  my @audit_fields;
  my $source=$series_target_white_reference->{"source"} || "";
  my $run_id=$series_target_white_reference->{"run_id"} || "";
  my $field=$series_target_white_reference->{"field"} || "";
  my $completed_at=$series_target_white_reference->{"completed_at"};
  push @audit_fields, "\"series_target_white_source\":\"".&_webui_json_escape($source)."\"" if($source ne "");
  push @audit_fields, "\"series_target_autocal_run_id\":\"".&_webui_json_escape($run_id)."\"" if($run_id ne "");
  push @audit_fields, "\"series_target_autocal_field\":\"".&_webui_json_escape($field)."\"" if($field ne "");
  push @audit_fields, "\"series_target_autocal_completed_at\":".int($completed_at+0) if(defined($completed_at) && !ref($completed_at) && "$completed_at"=~/^\d+(?:\.\d+)?$/);
  $series_target_white_audit=",".join(",",@audit_fields) if(@audit_fields);
 }
	 if($stamp_series_target_white_y && $series_target_white_y_num>0) {
 	  @steps=map {
 	   my $step=$_;
 	   if($step!~/"series_target_white_y"\s*:/) {
 	    $step=~s/\}\s*$//;
 	    $step.=",\"series_target_white_y\":$series_target_white_y_num,\"lg_target_white_y\":$series_target_white_y_num$series_target_white_audit}";
 	   }
 	   $step;
 	  } @steps;
 	 }
	 # Stamp a manual Target Black override onto every step so chart/server
	 # target math anchors the black floor to the operator's value.
	 if($series_target_black_y_num ne "" && $series_target_black_y_num>=0) {
	  @steps=map {
	   my $step=$_;
	   if($step!~/"series_target_black_y"\s*:/) {
	    $step=~s/\}\s*$//;
	    $step.=",\"series_target_black_y\":$series_target_black_y_num";
	    $step.="}";
	   }
	   $step;
	  } @steps;
	 }


	 my $series_id="${type}_".int(Time::HiRes::time()*1000)."_".int(rand(1000000));
	 my $total=scalar(@steps);
	 my $series_type_json=&_webui_json_escape($type);
	 my $series_signal_mode_json=&_webui_json_escape($signal_mode);
	 my $series_target_gamma_json=&_webui_json_escape($target_gamma);
	 my $series_dv_map_mode_json=&_webui_json_escape($dv_map_mode);
	 my $series_dv_interface_json=&_webui_json_escape(($signal_mode eq "dv") ? "$dv_interface" : "");
	 my $series_max_luma_num=($max_luma+0);
	 my $series_meta_json="\"type\":\"$series_type_json\",\"points\":".($points+0).",\"signal_mode\":\"$series_signal_mode_json\",\"target_gamma\":\"$series_target_gamma_json\",\"max_luma\":$series_max_luma_num,\"dv_map_mode\":\"$series_dv_map_mode_json\",\"dv_interface\":\"$series_dv_interface_json\"";
	 my $series_step_meta=",\"signal_mode\":\"$series_signal_mode_json\",\"target_gamma\":\"$series_target_gamma_json\",\"max_luma\":$series_max_luma_num,\"dv_map_mode\":\"$series_dv_map_mode_json\",\"dv_interface\":\"$series_dv_interface_json\"";
	 @steps=map {
	  my $step=$_;
	  if($step!~/"signal_mode"\s*:/) {
	   $step=~s/\}\s*$//;
	   $step.=$series_step_meta."}";
	  }
	  $step;
	 } @steps;

	 # Write steps to temp file for helper script
	 my $steps_file="/tmp/meter_series_steps_${series_id}.json";
	 if(open(my $fh,">",$steps_file)) {
	  print $fh "[".join(",",@steps)."]";
	  close($fh);
	  chmod 0644, $steps_file;
	 } else {
	  return "{\"status\":\"error\",\"message\":\"Failed to write series steps file\"}";
	 }

	 # Write initial state
	 my $init_json="{\"status\":\"running\",\"series_id\":\"$series_id\",\"current_step\":0,\"total_steps\":$total,\"current_name\":\"\",\"readings\":[],$series_meta_json}";
 if(open(my $fh,">",$_meter_series_file)) { print $fh $init_json; close($fh); }
 my $ready_file=&webui_meter_series_ready_file($series_id);
 &webui_meter_series_ready_cleanup();
 &webui_meter_series_stop_cleanup();
 unlink($ready_file) if($ready_file ne "");

 # Launch series helper script in background (setsid to detach from daemon threads)
 # sudo required: daemon runs as pgenerator user, spotread needs root for USB access
 # Low-light mode and trigger are positional arguments, not environment
 # prefixes. The mode remains the operator-selected a/aa/aaa value; the
 # series worker starts spotread at off and applies the trigger per step.
 # Precompute the mode-correct insertion codes via the shared helper so the
 # worker just SENDS them rather than recomputing. Without this, the
 # insertion flash used a hard-coded linear 0..255 formula and was wrong on
 # HDR/DV/HLG wires (way too dim, or in HDR10 too bright). The two args are
 # colon-joined "<code>:<input_max>" so the authorized
 # "/usr/bin/meter_series.sh *" arg pattern still matches. Applies to ANY
 # series type (greyscale, colors, ...) that has the patch_insert flag set
 # -- the helper handles the SDR/HDR10/DV/HLG mapping from signal_mode.
 my $insert_patch_code="";
 my $insert_patch_input_max=255;
 my $insert_time_code="";
 my $insert_time_input_max=255;
 if($patch_insert_patch_enabled || $patch_insert_time_enabled) {
  my %series_opts=(
   hdr20_codes => (($type eq "greyscale" && $points==26 && $lg_autocal_26 && $signal_mode eq "hdr10") ? 1 : 0),
   max_bpc => (defined $pgenerator_conf{"max_bpc"} && $pgenerator_conf{"max_bpc"} ne "") ? $pgenerator_conf{"max_bpc"} : "",
   autocal_26 => (($type eq "greyscale" && $points==26 && $lg_autocal_26) ? 1 : 0),
   autocal_26_codes => (($type eq "greyscale" && $points==26 && $lg_autocal_26 && $signal_mode eq "sdr") ? 1 : 0),
   extended_sdr_codes => (($type eq "greyscale" && !$lg_autocal_26_codes && (($points==26 && $lg_autocal_26) || ($points==21 && $lg_greyscale_21)) && $signal_mode eq "sdr") ? 1 : 0),
   dv_series => (($signal_mode eq "dv") ? 1 : 0),
   dv_series_code_bits => (($signal_mode eq "dv") ? 12 : 8),
  );
  ($insert_patch_code,$insert_patch_input_max)=&webui_grey_code_for_stimulus($patch_insert_patch_level,$signal_mode,$target_gamma,$greyscale_patch_limited,\%series_opts) if($patch_insert_patch_enabled);
  ($insert_time_code,$insert_time_input_max)=&webui_grey_code_for_stimulus($patch_insert_time_level,$signal_mode,$target_gamma,$greyscale_patch_limited,\%series_opts) if($patch_insert_time_enabled);
 }
 # environment-variable prefix on the sudo command. The daemon's sudo
 # NOPASSWD rule only authorizes "/bin/bash /usr/bin/meter_series.sh *";
 # any env-prefixed form (e.g. an "env KEY=VAL" prefix on the bash
 # command) makes the sudo invocation match no rule, so sudo demands a
 # password and the launch silently fails ("Process died unexpectedly").
 # Trailing args keep the authorized command intact.
 my $cmd="setsid sudo /bin/bash /usr/bin/meter_series.sh '$series_id' '$display_type' '$delay_ms' '$patch_size' '$steps_file' '$_meter_series_file' '$ccss_file' '$patch_insert' '$refresh_rate' '$disable_aio' '$signal_mode' '$max_luma' '$dv_map_mode' '$measurement_meter_port' '$ready_file' '$require_device_ready' '$pattern_signal_range' '$transport_signal_range' '$pattern_delay_ms' '$patch_insert_patch_enabled' '$patch_insert_patch_every' '$patch_insert_patch_duration_ms' '$patch_insert_patch_level' '$patch_insert_time_enabled' '$patch_insert_time_frequency_ms' '$patch_insert_time_duration_ms' '$patch_insert_time_level' '$low_light_mode' '${insert_patch_code}:${insert_patch_input_max}' '${insert_time_code}:${insert_time_input_max}' '$series_color_format' '$measurement_meter_usb_id' '$observer' '$pattern_provider' '$min_luma' '$max_cll' '$max_fall' '$low_light_trigger' </dev/null >/dev/null 2>&1 &";
	 open(my $debug_log,">>/tmp/webui_series_debug.log");
	 print $debug_log "[".scalar(localtime())."] Launching series: type=$type series_id=$series_id\n";
	 if($type eq "greyscale" && $points==26 && $lg_autocal_26) {
	  my $autocal_ref_source=(ref($series_target_white_reference) eq "HASH") ? ($series_target_white_reference->{"source"}||"") : "";
	  my $autocal_ref_field=(ref($series_target_white_reference) eq "HASH") ? ($series_target_white_reference->{"field"}||"") : "";
	  my $autocal_ref_run=(ref($series_target_white_reference) eq "HASH") ? ($series_target_white_reference->{"run_id"}||"") : "";
	  my $autocal_ref_white=(ref($series_target_white_reference) eq "HASH" && defined($series_target_white_reference->{"white_y"})) ? ($series_target_white_reference->{"white_y"}+0) : "";
	  print $debug_log "[".scalar(localtime())."] LG26 series target context: signal_mode=$signal_mode target_gamma=$target_gamma target_gamut=".($target_gamut||"auto")." target_white_x=0.3127 target_white_y=0.329 explicit_series_target_white_y=$series_target_white_y_provided series_target_white_y_num=$series_target_white_y_num stamp_series_target_white_y=$stamp_series_target_white_y autocal_ref_source=$autocal_ref_source autocal_ref_field=$autocal_ref_field autocal_ref_run_id=$autocal_ref_run autocal_ref_white_y=$autocal_ref_white\n";
	 }
	 print $debug_log "[".scalar(localtime())."] Command: $cmd\n";
	 close($debug_log);
 system($cmd);

	 return "{\"status\":\"started\",\"series_id\":\"$series_id\",\"total_steps\":$total,$series_meta_json,\"steps\":[".join(",",@steps)."]}";
}

sub webui_meter_series_status (@) {
 my ($summary)=@_;
 if(-f $_meter_series_file) {
  my $json="";
  if(open(my $fh,"<",$_meter_series_file)) { local $/; $json=<$fh>; close($fh); }
  if($json ne "") {
	   # If status is "running", verify the process is still alive
	   if($json=~/"status"\s*:\s*"running"/) {
	    if(!&webui_meter_series_alive()) {
	     # setsid/sudo needs a short moment to replace the launcher with the
	     # meter_series process. The browser polls immediately after POST, so
	     # treating that launch window as a dead worker made Read Series flash
	     # "starting" and then silently terminate. Keep the initial state alive
	     # for three seconds; a real launch failure is still reported after it.
	     my @state_stat=stat($_meter_series_file);
	     my $state_age=@state_stat ? time()-($state_stat[9]||0) : 99;
	     if($state_age>=3) {
	      $json=~s/"status"\s*:\s*"running"/"status":"error"/;
      $json=~s/"current_name"\s*:\s*"[^"]*"/"current_name":"Process died unexpectedly"/;
      if(open(my $wf,">",$_meter_series_file)) { print $wf $json; close($wf); }
     }
    }
   }
	   # Include steps from steps file so any client can reconstruct the UI.
	   # The helper may rewrite DV Absolute codes in-place as root, so every run
	   # uses a unique path instead of reusing a stale fixed /tmp file.
	   my $steps_file="";
	   if($json=~/"series_id"\s*:\s*"([A-Za-z0-9_.-]+)"/) {
	    my $sid=$1;
	    my $candidate="/tmp/meter_series_steps_${sid}.json";
	    $steps_file=$candidate if(-f $candidate);
	   }
	   $steps_file="/tmp/meter_series_steps.json" if($steps_file eq "" && -f "/tmp/meter_series_steps.json");
	   if($steps_file ne "" && $json=~/"status"\s*:\s*"(running|complete|error|cancelled)"/) {
	    my $steps="";
	    if(open(my $sf,"<",$steps_file)) { local $/; $steps=<$sf>; close($sf); }
	    if($steps ne "" && $json!~/"steps"/) {
	     $json=~s/\}$/,"steps":$steps}/;
	    }
   }
   if($summary) {
    # Remote ICC clients only need progress while a run is active. Removing
    # accumulated readings and the repeated step list keeps VPN polling fast;
    # the completed run is fetched once in full before profile generation.
    $json=~s/"readings"\s*:\s*\[[^\]]*\]/"readings":[]/s;
    $json=~s/,"steps"\s*:\s*\[[^\]]*\]//s;
   }
   return $json;
  }
 }
 return '{"status":"idle"}';
}

sub webui_meter_full_autocal_report_state (@) {
 my ($body)=@_;
 return '{"status":"error","message":"Full AutoCal report state payload required"}' if(!defined($body) || $body eq "" || $body!~/^\s*\{/);
 my $run="unknown";
 $run=$1 if($body=~/"run_id"\s*:\s*"([^"]+)"/);
 $run=$1 if($run eq "unknown" && $body=~/"runId"\s*:\s*"([^"]+)"/);
 $run=~s/[^A-Za-z0-9_.-]/_/g;
 $run="unknown" if($run eq "");
 my @dirs=("/var/lib/PGenerator/reports/full-autocal","/tmp/PGenerator_full_autocal_reports");
 foreach my $dir (@dirs) {
  system("mkdir","-p",$dir);
  if(!-d $dir && $dir=~m{^/var/lib/PGenerator/}) {
   system("sudo","mkdir","-p",$dir);
   system("sudo","chmod","0777","/var/lib/PGenerator/reports");
   system("sudo","chmod","0777",$dir);
  }
  system("chmod","0777",$dir) if(-d $dir);
  next unless(-d $dir && -w $dir);
  my $file="$dir/$run.json";
  my $tmp="$file.tmp";
  if(open(my $fh,">",$tmp)) {
   print $fh $body;
   close($fh);
   rename($tmp,$file);
   chmod(0666,$file);
   my $safe_file=$file;
   $safe_file=~s/"/\\"/g;
   return "{\"status\":\"ok\",\"path\":\"$safe_file\"}";
  }
 }
 return '{"status":"error","message":"Unable to save Full AutoCal report state"}';
}

sub webui_meter_series_ready (@) {
 return '{"status":"error","message":"No active series"}' unless(-f $_meter_series_file);
 my $json="";
 if(open(my $fh,"<",$_meter_series_file)) { local $/; $json=<$fh>; close($fh); }
 return '{"status":"error","message":"No active series"}' if($json eq "");
 my $series_id="";
 $series_id=$1 if($json=~/"series_id"\s*:\s*"([^"]+)"/);
 my $waiting=($json=~/"awaiting_ready"\s*:\s*true/i || $json=~/"status"\s*:\s*"setup"/i) ? 1 : 0;
 return '{"status":"error","message":"Series is not waiting for device readiness"}' if(!$waiting || $series_id eq "");
 my $ready_file=&webui_meter_series_ready_file($series_id);
 return '{"status":"error","message":"Series ready signal unavailable"}' if($ready_file eq "");
 if(open(my $fh,">",$ready_file)) {
  print $fh time();
  close($fh);
  chmod(0666,$ready_file);
  return '{"status":"ok","message":"Measurement resumed"}';
 }
 return '{"status":"error","message":"Failed to signal series readiness"}';
}

sub webui_meter_lg_autocal_running (@) {
 my $alive=`pgrep -f '[m]eter_lg_autocal\\.pl' 2>/dev/null`;
 return ($alive=~/\d/) ? 1 : 0;
}

# A completed greyscale worker may remain alive briefly while it exits
# calibration mode, clears the pattern and archives its state. Follow-on
# stages must wait for that process rather than treating the safe overlap
# rejection as a failed Full AutoCal run.
sub webui_meter_lg_autocal_handoff_guard (@) {
 return undef if(!&webui_meter_lg_autocal_running());
 my $state="";
 if(open(my $fh,"<",$_meter_lg_autocal_file)) { local $/; $state=<$fh>; close($fh); }
 # Decode and inspect only the TOP-LEVEL status/phase. The state document
 # embeds nested helper responses (upload_probe etc.) that legitimately
 # carry their own "status":"error" -- an unanchored regex classified a
 # genuinely running AutoCal as "finishing" whenever one appeared. The
 # worker writes this file atomically (tmp + rename), so an undecodable
 # document means corruption, not a torn read: treat that as active, not
 # finishing.
 my $decoded=eval { require JSON::PP; JSON::PP::decode_json($state); };
 my ($top_status,$top_phase)=("","");
 if(ref($decoded) eq "HASH") {
  $top_status=lc($decoded->{"status"}||"");
  $top_phase=lc($decoded->{"phase"}||"");
 }
 my $finishing=($top_phase eq "finalising"
  || $top_status eq "complete" || $top_status eq "cancelled" || $top_status eq "error") ? 1 : 0;
 if($finishing) {
  return '{"status":"retry","error_code":"lg-autocal-finishing","retryable":true,"retry_after_ms":600,"message":"LG Auto Cal is finishing TV and pattern cleanup"}';
 }
 return '{"status":"error","error_code":"lg-autocal-active","retryable":false,"message":"LG Auto Cal is already running"}';
}

sub webui_meter_lg_autocal_same_run_running (@) {
 my ($body)=@_;
 return 0 if(!defined($body) || $body eq "" || !-f $_meter_lg_autocal_file);
 my $run="";
 $run=$1 if($body=~/"full_autocal_run_id"\s*:\s*"([^"]+)"/);
 $run=$1 if($run eq "" && $body=~/"run_id"\s*:\s*"([^"]+)"/);
 return 0 if($run eq "");
 my $json="";
 if(open(my $fh,"<",$_meter_lg_autocal_file)) { local $/; $json=<$fh>; close($fh); }
 return 0 if($json eq "" || $json!~/"status"\s*:\s*"running"/);
 return 1 if($json=~/"full_autocal_run_id"\s*:\s*"\Q$run\E"/);
 return 1 if($json=~/"run_id"\s*:\s*"\Q$run\E"/);
 return 0;
}

sub webui_meter_lg_autocal_mark_cancelled (@) {
 return unless(-f $_meter_lg_autocal_file);
 my $json="";
 if(open(my $fh,"<",$_meter_lg_autocal_file)) { local $/; $json=<$fh>; close($fh); }
 return if($json eq "");
 # Always force cancelled on an explicit Stop — including over a raced
 # process-died promotion to "complete" (final_1d flags set while the
 # worker was killed). Leaving complete here is what resurrects the
 # "Auto Cal complete" popup on the next page refresh.
 if($json=~/"status"\s*:\s*"[^"]*"/) {
  $json=~s/"status"\s*:\s*"[^"]*"/"status":"cancelled"/;
 } else {
  $json=~s/\}$/,"status":"cancelled"}/;
 }
 if($json=~/"autocal"\s*:\s*(?:true|false)/) {
  $json=~s/"autocal"\s*:\s*(?:true|false)/"autocal":false/;
 } else {
  $json=~s/\}$/,"autocal":false}/;
 }
 if($json=~/"calibration_mode"\s*:\s*(?:true|false)/) {
  $json=~s/"calibration_mode"\s*:\s*(?:true|false)/"calibration_mode":false/;
 } else {
  $json=~s/\}$/,"calibration_mode":false}/;
 }
 if($json=~/"phase"\s*:\s*"[^"]*"/) {
  $json=~s/"phase"\s*:\s*"[^"]*"/"phase":"cancelled"/;
 } else {
  $json=~s/\}$/,"phase":"cancelled"}/;
 }
 if($json=~/"current_name"\s*:\s*"[^"]*"/) {
  $json=~s/"current_name"\s*:\s*"[^"]*"/"current_name":"Auto Cal cancelled"/;
 } else {
  $json=~s/\}$/,"current_name":"Auto Cal cancelled"}/;
 }
 if($json=~/"message"\s*:\s*"[^"]*"/) {
  $json=~s/"message"\s*:\s*"[^"]*"/"message":"Auto Cal stopped"/;
 } else {
  $json=~s/\}$/,"message":"Auto Cal stopped"}/;
 }
 if(open(my $fh,">",$_meter_lg_autocal_file)) { print $fh $json; close($fh); chmod(0666,$_meter_lg_autocal_file); }
}

# Clear the full-workflow + HDR tone-map metadata from the persisted
# autocal state. Called from the dedicated completion signals
# (/api/lg/autocal/run/end on full-workflow complete/abort, and the
# standalone-greyscale completion path) -- NOT from the status endpoint,
# which is read mid-workflow by the active session to advance
# greyscale -> 3D-LUT.
#
# Two phantom fresh-browser bugs are defused by clearing these keys once
# the workflow (or standalone greyscale run) is genuinely finished:
#
#  * full_workflow / full_autocal_phase / full_autocal_run_id /
#    full_autocal_post_* /
#    full_autocal_touchup: the greyscale worker stamps these at run
#    start and never clears them. A fresh browser (no localStorage
#    completion-token) reads them on its first status poll and the JS's
#    meterFullAutoCalEnsureStatusPhase treats the completed phase as
#    'ready to start next phase', dispatching a phantom 3D-LUT autocal
#    with skipConfirm:true.
#
#  * hdr20_1d_tonemap_pending (+ siblings except peak_luminance): the
#    worker stamps pending=true on the wizard-owns-upload branch and
#    only the inline/kill-switch branches clear it. A fresh browser
#    reads pending=true and the standalone-greyscale poller fires
#    meterAutoCalPromptHdrToneMapUpload -- a "Upload HDR tone map" modal
#    that only hides client-side, so every fresh browser re-fires it.
#
# hdr20_1d_tonemap_peak_luminance is intentionally KEPT (it is pure
# data, drives no fresh-browser decision, and is harmless once the
# decision flags above are cleared).
sub webui_meter_lg_autocal_clear_full_workflow_state (@) {
 # Clear full-workflow decision keys from BOTH greyscale and 3D status
 # files. Leaving full_workflow=true on a terminal 3D complete status is
 # what resurrects the "Full Auto Cal complete / Generate Post-Cal Report"
 # popup after Stop + page refresh (the JS ensureStatusPhase re-adopts the
 # finished run). Keep hdr20_1d_tonemap_peak_luminance (data, not a
 # decision flag).
 my @keys=(
  "full_workflow",
  "full_autocal_phase",
  "full_autocal_run_id",
  "full_autocal_touchup",
   "full_autocal_post_commit_polish",
   "full_autocal_post_3d_polish",
  "full_autocal_post_series_adjust",
  "full_autocal_post_series_revert",
  "hdr20_1d_tonemap_pending",
  "hdr20_1d_tonemap_uploaded",
  "hdr20_1d_tonemap_upload_enabled",
  "hdr20_1d_tonemap_upload_message",
  "hdr20_1d_tonemap_wizard_handled",
  "hdr20_1d_tonemap_wizard_owns_upload",
 );
 my $any=0;
 for my $file ($_meter_lg_autocal_file,$_meter_lg_3d_autocal_file) {
  next unless(defined($file) && $file ne "" && -f $file);
  my $json="";
  if(open(my $fh,"<",$file)) { local $/; $json=<$fh>; close($fh); }
  next if($json eq "");
  my $changed=0;
  for my $k (@keys) {
   next if($json!~/"\Q$k\E"\s*:/);
   # Match `"key": <value>` for true/false/null/string/number; eat a
   # trailing comma.
   $json=~s/"\Q$k\E"\s*:\s*(?:true|false|null|"[^"\\]*(?:\\.[^"\\]*)*"|-?\d+(?:\.\d+)?)\s*,?\s*//;
   $changed=1;
  }
  # Collapse a comma left dangling before the closing brace.
  $json=~s/,(\s*\})/$1/g if($changed);
  if($changed && open(my $fh,">",$file)) { print $fh $json; close($fh); chmod(0666,$file); $any=1; }
 }
 return $any;
}

# Clear ONLY the HDR tone-map pending/decision keys from the persisted
# autocal state -- NOT the full_workflow / full_autocal_phase / peak
# keys (those drive the mid-workflow advance and must survive). Called
# the moment the operator resolves the wizard tone-map prompt (Upload
# OR Skip) via /api/meter/lg-autocal/clear-tonemap-pending, so the
# transient hdr20_1d_tonemap_pending flag -- which only the
# standalone-greyscale HDR path sets (the full-workflow HDR20 path
# returns early and never sets it) -- can never linger in /tmp across a
# PGenerator restart to re-fire the "Upload HDR tone map" popup on a
# fresh browser. Safe mid-full-workflow: it touches none of the
# full-workflow advance keys.
sub webui_meter_lg_autocal_clear_tonemap_pending (@) {
 return unless(-f $_meter_lg_autocal_file);
 my $json="";
 if(open(my $fh,"<",$_meter_lg_autocal_file)) { local $/; $json=<$fh>; close($fh); }
 return if($json eq "");
 my $changed=0;
 for my $k (qw(hdr20_1d_tonemap_pending hdr20_1d_tonemap_wizard_handled hdr20_1d_tonemap_wizard_owns_upload)) {
  next if($json!~/"\Q$k\E"\s*:/);
  $json=~s/"\Q$k\E"\s*:\s*(?:true|false|null|"[^"\\]*(?:\\.[^"\\]*)*"|-?\d+(?:\.\d+)?)\s*,?\s*//;
  $changed=1;
 }
 $json=~s/,(\s*\})/$1/g if($changed);
 if($changed && open(my $fh,">",$_meter_lg_autocal_file)) { print $fh $json; close($fh); chmod(0666,$_meter_lg_autocal_file); }
 return &webui_meter_lg_autocal_status();
}

sub webui_meter_lg_autocal_kill (@) {
 my $mark=shift;
 if(open(my $fh,">",$_meter_lg_autocal_stop_file)) { print $fh time(); close($fh); chmod(0666,$_meter_lg_autocal_stop_file); }
 system("sudo pkill -TERM -f '[m]eter_lg_autocal\\.pl' 2>/dev/null");
 select(undef,undef,undef,0.4);
 system("sudo pkill -9 -f '[m]eter_lg_autocal\\.pl' 2>/dev/null") if(&webui_meter_lg_autocal_running());
 &webui_meter_lg_autocal_mark_cancelled() if($mark);
}

sub webui_meter_lg_autocal_body_with_defaults (@) {
 my ($body)=@_;
 return $body if(!defined($body) || $body eq "" || $body!~/^\s*\{/);
 return $body unless($body=~/"type"\s*:\s*"greyscale"/i && $body=~/"points"\s*:\s*26\b/ && $body=~/"lg_autocal_26"\s*:\s*true/i);
 # Route HDR10 greyscale autocal through the 1D-DPG path (test/opt-in; no third-party software names)
 if($body=~/"signal_mode"\s*:\s*"hdr10"/i) {
  return $body if($body=~/"lg_autocal_hdr20_dpg_mode"\s*:/);
  $body=~s/\}\s*\z/,"lg_autocal_hdr20_dpg_mode":true}/;
  return $body;
 }
 # Route Dolby Vision greyscale autocal through the SAME 1D-DPG convergence
 # loop as HDR10: the panel's DV engine is calibrated in a fixed
 # pass-through mode against a plain 2.2 gamma target (see
 # target_gamma_linear in meter_lg_autocal.pl), so it shares the HDR20 DDC
 # ladder end to end rather than needing its own convergence path.
 if($body=~/"signal_mode"\s*:\s*"dv"/i) {
  return $body if($body=~/"lg_autocal_hdr20_dpg_mode"\s*:/);
  $body=~s/\}\s*\z/,"lg_autocal_hdr20_dpg_mode":true}/;
  return $body;
 }
 # Route SDR26 greyscale autocal through the 1D-DPG convergence loop
 # (test/opt-in; no third-party software names). Mirrors the HDR20 routing
 # above; SDR26 uses BT.709/D65 + gamma 2.2 instead of HDR's BT.2020/PQ.
 if($body=~/"signal_mode"\s*:\s*"sdr"/i) {
  return $body if($body=~/"lg_autocal_sdr_1d_dpg_mode"\s*:/);
  $body=~s/\}\s*\z/,"lg_autocal_sdr_1d_dpg_mode":true}/;
  return $body;
 }
 return $body if($body=~/"lg_autocal_26_full_ddc_spine"\s*:/ || $body=~/"lg_autocal_26_anchor_predrive"\s*:/);
 $body=~s/\}\s*\z/,"lg_autocal_26_full_ddc_spine":true,"lg_autocal_26_anchor_predrive":false}/;
 return $body;
}

# Promote the active link to 10-bit before launching an SDR autocal.
# The LG 26pt autocal ladder (SDR + HDR10) and the 3D LUT autocal's
# greyscale anchors are bit-depth-aware: the SDR 26pt code table is
# intrinsically 10-bit (codes 64..1023) and the HDR20 10-bit Limited /
# Full tables top out at 940 / 1023. When the operator has the link at
# max_bpc=8 those 10-bit codes get scaled back down to 8-bit on the wire
# (or, in the case the user reported, ship as 8-bit and land as 23% of
# full signal on a 10-bit link). Auto-bump to max_bpc=10 + restart the
# renderer so the worker spawns against a 10-bit link.
#
# Returns 1 if a promotion happened (caller should surface
# max_bpc_promoted:true to the UI), 0 if no-op, -1 on error.
sub webui_meter_lg_autocal_ensure_10b (@) {
 my ($signal_mode)=@_;
 $signal_mode=lc($signal_mode||"");
 # Only SDR is auto-promoted here. HDR10/HLG/DV paths already have their
 # own 10-bit ladders in webui_grey_code_for_stimulus and the existing
 # HDR10 26pt table selection follows max_bpc via $_hdr20_bits; the
 # legacy 8-bit YCbCr limited HDR10 test deliberately pins
 # max_bpc=8 and would be broken by an auto-promote.
 return 0 if($signal_mode ne "sdr");
 &webui_reload_pgenerator_conf();
 my $cur_bpc=int($pgenerator_conf{"max_bpc"} || 0);
 return 0 if($cur_bpc >= 10);
 my $restart_log="/tmp/pgen-autocal-10b-promote.log";
 if(open(my $lfh,">>",$restart_log)) {
  print $lfh "[".scalar(localtime())."] promoting max_bpc $cur_bpc -> 10 for SDR autocal (signal_mode=$signal_mode)\n";
  close($lfh);
 }
 # set_pgenerator_conf_runtime() (command.pm) writes /etc/PGenerator/
 # PGenerator.conf via SET_PGENERATOR_CONF and updates the in-memory
 # $pgenerator_conf hash so the same-process call sites below see the
 # new value without a separate reload.
 &set_pgenerator_conf_runtime("max_bpc","10");
 # Restart the renderer so it picks up the new link bit-depth. Same pair
 # /api/restart uses; pattern_generator_start() blocks until the
 # renderer is up and holds DRM master.
 &pattern_generator_stop();
 &pattern_generator_start();
 # Reload in-memory conf so any subsequent reader in this request sees
 # max_bpc=10. The renderer's restart already re-reads the conf itself.
 &webui_reload_pgenerator_conf();
 if(open(my $lfh,">>",$restart_log)) {
  print $lfh "[".scalar(localtime())."] restart done; renderer should be on max_bpc=10 now\n";
  close($lfh);
 }
 return 1;
}

sub webui_meter_autocal_force_standard_observer (@) {
 my ($body)=@_;
 return $body if(!defined($body) || $body!~/^\s*\{/);
 if($body=~/"observer"\s*:/) {
  $body=~s/"observer"\s*:\s*"[^"]*"/"observer":"1931_2"/;
 } else {
  $body=~s/\}\s*$/,"observer":"1931_2"}/;
 }
 return $body;
}

sub webui_meter_lg_body_with_display_model (@) {
 my ($body)=@_;
 return $body if(!defined($body) || $body!~/^\s*\{/ || $body=~/"display_model"\s*:/);
 return $body unless(defined(&webui_lg_display_model_name));
 my $model=eval { &webui_lg_display_model_name({}) } || "";
 return $body if($model eq "");
 $model=~s/\\/\\\\/g; $model=~s/"/\\"/g;
 $body=~s/\}\s*\z/,"display_model":"$model"}/;
 return $body;
}

sub webui_meter_lg_autocal_start (@) {
 my ($body)=@_;
 return '{"status":"error","message":"LG Auto Cal payload required"}' if(!defined($body) || $body eq "" || $body!~/^\s*\{/);
 # AutoCal writes calibration data into a real TV; simulated readings would
 # upload garbage. Block every launch that would run on the simulated meter.
 if(&webui_meter_autocal_blocked_for_simulation($body)) {
  return '{"status":"error","message":"AutoCal is not available with the Simulated Meter. Connect a real meter to calibrate a display."}';
 }
 $body=&webui_meter_lg_autocal_body_with_defaults($body);
 $body=&webui_meter_autocal_force_standard_observer($body);
 $body=&webui_meter_lg_body_with_display_model($body);
 if(&webui_meter_lg_autocal_running()) {
  return '{"status":"started","message":"LG Auto Cal already running"}' if(&webui_meter_lg_autocal_same_run_running($body));
  return '{"status":"error","message":"LG Auto Cal is already running"}';
 }
 return '{"status":"error","message":"LG 3D LUT AutoCal is already running"}' if(&webui_meter_lg_3d_autocal_running());
 # Final server-side power gate immediately before any meter/session teardown
 # or worker launch. Block a definite CEC off state, but fail open when CEC is
 # unknown or remains powering-on. Older adapters can keep those advisory
 # states long after WebOS and the HDMI signal are usable; the authenticated LG
 # reset/session preflight remains the authoritative launch check.
 if(defined(&lg_cec_status)) {
  my $tv_status=eval { &lg_cec_status() };
  if(ref($tv_status) eq "HASH") {
   my $power=lc($tv_status->{"tv_power"}||"");
   $power=~s/^\s+|\s+$//g;
   if($power eq "standby" || $power eq "off" || $power eq "powering-off") {
    return '{"status":"error","message":"LG TV is powered off. Turn it on and wait for it to finish starting before Auto Cal."}';
   }
  }
 }
 &webui_meter_stop();
 # Drop any stale stop file before launch. A root-owned leftover in sticky
 # /tmp cannot be unlinked by the pgenerator webui user, and the worker
 # treats -f stop as cancelled -- wizard completes, charts open, cal dies
 # instantly with "Auto Cal stopped". Force-remove via sudo when plain
 # unlink leaves the file behind.
 unlink($_meter_lg_autocal_stop_file);
 if(-e $_meter_lg_autocal_stop_file) {
  system("sudo rm -f ".quotemeta($_meter_lg_autocal_stop_file)." 2>/dev/null");
  unlink($_meter_lg_autocal_stop_file);
 }
 # Inject precomputed pattern-insertion codes (mode-correct) so the worker
 # sends the same code the greyscale ladder would emit for that stimulus.
 # The autocal body does not carry every flag the series closure has, so
 # derive opts from the body itself (lg_autocal_26, signal_mode, etc.).
 my $_ac_signal_mode="sdr";
 $_ac_signal_mode=$1 if($body=~/"signal_mode"\s*:\s*"([^"]+)"/);
 # Honor the selected bit depth -- do NOT force-promote SDR to 10-bit. The
 # 26pt worker now drives proper 8-bit codes when max_bpc=8 (see
 # lg_autocal_26_sdr_headroom_enabled in meter_lg_autocal.pl), so the prior
 # ~25% under-signal regression that the forced promotion guarded against no
 # longer applies. A 10-bit selection already sets max_bpc=10 in the conf, so
 # no promotion is needed; an 8-bit selection now stays 8-bit (full or
 # limited per the Range selector) instead of being silently bumped to 10-bit.
 my $_ac_max_bpc_promoted=0;
my $_ac_target_gamma="bt1886";
  $_ac_target_gamma=$1 if($body=~/"target_gamma"\s*:\s*"([^"]+)"/);
 my $_ac_signal_range="";
 $_ac_signal_range=$1 if($body=~/"signal_range"\s*:\s*"?(\d+)"?/);
 my $_ac_pattern_signal_range=$_ac_signal_range;
 $_ac_pattern_signal_range=$1 if($body=~/"pattern_signal_range"\s*:\s*"?(\d+)"?/);
 my $_ac_lg_autocal_26=($body=~/"lg_autocal_26"\s*:\s*true/i) ? 1 : 0;
 my $_ac_lg_greyscale_21=($body=~/"lg_greyscale_21"\s*:\s*true/i) ? 1 : 0;
 my $_ac_patch_insert_patch_enabled=($body=~/"patch_insert_patch_enabled"\s*:\s*true/i) ? 1 : 0;
 my $_ac_patch_insert_time_enabled=($body=~/"patch_insert_time_enabled"\s*:\s*true/i) ? 1 : 0;
 my $_ac_patch_insert_patch_level=10;
 $_ac_patch_insert_patch_level=$1 if($body=~/"patch_insert_patch_level"\s*:\s*([0-9.]+)/);
 my $_ac_patch_insert_time_level=25;
 $_ac_patch_insert_time_level=$1 if($body=~/"patch_insert_time_level"\s*:\s*([0-9.]+)/);
 my $_ac_lim=(defined($_ac_pattern_signal_range) && $_ac_pattern_signal_range ne "" && int($_ac_pattern_signal_range)==1) ? 1 : 0;
 $_ac_lim=((defined($_ac_signal_range) && $_ac_signal_range ne "" && int($_ac_signal_range)==1) ? 1 : 0) if(!$_ac_lim && $_ac_signal_mode eq "sdr");
 # HDR10 fallback: when the body omits both pattern_signal_range and
 # signal_range, resolve the effective range from the active output
 # (rgb_quant_range). Mirrors webui_meter_series_start at lines ~2298-2302
 # so a limited-configured TV (rgb_quant_range=1) yields $_ac_lim=1 even
 # if the JS did not POST signal_range. A JS that DOES post signal_range
 # still wins (the body field is set first above).
 if(!$_ac_lim && $_ac_signal_mode eq "hdr10") {
  my $_ac_conf_range=&webui_preferred_rgb_quant_range();
  $_ac_lim=1 if(defined($_ac_conf_range) && $_ac_conf_range ne "" && int($_ac_conf_range)==1);
 }
 # SDR: the renderer outputs per rgb_quant_range, so the autocal PATTERN codes
 # must use the SAME range. The JS pins pattern_signal_range=1 for the SDR26
 # ladder (legacy "always limited legal-expanded" assumption) even when the
 # display is full -- that makes the worker emit limited codes (100%->235),
 # which a full renderer then sends as ~92% so 100% reads dim. Align the
 # pattern range to the effective output range (signal_range, which the JS
 # sets from rgb_quant_range; fall back to the conf) and rewrite the body so
 # the worker config (written from $body) is consistent.
 if($_ac_signal_mode eq "sdr") {
  my $_ac_eff_range=$_ac_signal_range;
  $_ac_eff_range=&webui_preferred_rgb_quant_range() if(!defined($_ac_eff_range) || $_ac_eff_range !~ /^[12]$/);
  if(defined($_ac_eff_range) && $_ac_eff_range=~/^[12]$/) {
   $_ac_pattern_signal_range=$_ac_eff_range;
   $_ac_lim=(int($_ac_eff_range)==1) ? 1 : 0;
   if($body=~/"pattern_signal_range"\s*:/) {
    $body=~s/"pattern_signal_range"\s*:\s*"?\d+"?/"pattern_signal_range":"$_ac_eff_range"/;
   } else {
    $body=~s/\}\s*\z/,"pattern_signal_range":"$_ac_eff_range"}/;
   }
  }
 }
 my %_ac_opts=(
  hdr20_codes => (($_ac_lg_autocal_26 && $_ac_signal_mode eq "hdr10") ? 1 : 0),
  # Wire $_ac_lim into the HDR20 table selection so a limited/full autocal
  # uses the matching 10-bit table (limited 100%->940, full 100%->1023)
  # instead of falling through to the 8-bit HDR20 table. Only meaningful
  # when hdr20_codes is set in webui_grey_code_for_stimulus; harmless for
  # SDR/DV/HLG because the HDR20 branch is skipped for those modes.
  hdr20_use_limited => (($_ac_signal_mode eq "hdr10") ? 1 : 0),
  hdr20_full => (($_ac_signal_mode eq "hdr10" && !$_ac_lim) ? 1 : 0),
  autocal_26 => ($_ac_lg_autocal_26 ? 1 : 0),
  autocal_26_codes => (($_ac_lg_autocal_26 && $_ac_signal_mode eq "sdr") ? 1 : 0),
  extended_sdr_codes => (($_ac_lg_autocal_26 || $_ac_lg_greyscale_21) && $_ac_signal_mode eq "sdr" ? 1 : 0),
  # Push the conf max_bpc through to webui_grey_code_for_stimulus so the
  # insertion-flash codes the autocal helper emits are bit-depth-aware
  # (matches the new bit-depth scaling in the standard / extended-SDR /
  # legal-SDR-DDC branches). Previously the helper unconditionally returned
  # 8-bit codes for these branches and the autocal insertion flash landed
  # as ~23% signal on a 10-bit wire.
  max_bpc => (defined $pgenerator_conf{"max_bpc"} && $pgenerator_conf{"max_bpc"} ne "") ? $pgenerator_conf{"max_bpc"} : "",
  dv_series => (($_ac_signal_mode eq "dv") ? 1 : 0),
  dv_series_code_bits => (($_ac_signal_mode eq "dv") ? 12 : 8),
 );
 my $_ac_insert_patch_code="";
 my $_ac_insert_patch_input_max=255;
 my $_ac_insert_time_code="";
 my $_ac_insert_time_input_max=255;
 if($_ac_patch_insert_patch_enabled) {
  ($_ac_insert_patch_code,$_ac_insert_patch_input_max)=&webui_grey_code_for_stimulus($_ac_patch_insert_patch_level,$_ac_signal_mode,$_ac_target_gamma,$_ac_lim,\%_ac_opts);
 }
 if($_ac_patch_insert_time_enabled) {
  ($_ac_insert_time_code,$_ac_insert_time_input_max)=&webui_grey_code_for_stimulus($_ac_patch_insert_time_level,$_ac_signal_mode,$_ac_target_gamma,$_ac_lim,\%_ac_opts);
 }
 # Guard against empty/invalid insertion codes. When pattern insertion is
 # disabled the *_code vars stay "" (and webui_grey_code_for_stimulus can
 # return "" even when enabled); interpolating "" below produced invalid
 # JSON ("patch_insert_patch_code":,) which made the autocal worker fail to
 # parse the config and report "No greyscale steps were supplied". Normalise
 # all four interpolated values to valid JSON integers. The worker only
 # consumes the codes when the matching *_enabled flag is set, so the
 # fallback value is never used as a real insertion code.
 $_ac_insert_patch_code=0 if(!defined($_ac_insert_patch_code) || $_ac_insert_patch_code !~ /^-?\d+$/);
 $_ac_insert_time_code=0 if(!defined($_ac_insert_time_code) || $_ac_insert_time_code !~ /^-?\d+$/);
 $_ac_insert_patch_input_max=255 if(!defined($_ac_insert_patch_input_max) || $_ac_insert_patch_input_max !~ /^-?\d+$/);
 $_ac_insert_time_input_max=255 if(!defined($_ac_insert_time_input_max) || $_ac_insert_time_input_max !~ /^-?\d+$/);
 $body=~s/\}\s*\z/,"patch_insert_patch_code":$_ac_insert_patch_code,"patch_insert_patch_input_max":$_ac_insert_patch_input_max,"patch_insert_time_code":$_ac_insert_time_code,"patch_insert_time_input_max":$_ac_insert_time_input_max}/;
 # The HDR20 DPG curvature smoother is baked at a FIXED 0.15 in the worker
 # (meter_lg_autocal.pl) and is intentionally NOT user-tunable: no smoother
 # strength is routed from PGenerator.conf, so no conf edit can change it.
 if(open(my $fh,">",$_meter_lg_autocal_config_file)) {
  print $fh $body;
  close($fh);
  chmod(0666,$_meter_lg_autocal_config_file);
 } else {
  return '{"status":"error","message":"Unable to prepare LG Auto Cal config"}';
 }
	 my $init='{"status":"running","autocal":true,"current_step":0,"total_steps":0,"current_name":"Starting LG Auto Cal...","message":"Starting","readings":[]}';
	 if(open(my $sf,">",$_meter_lg_autocal_file)) { print $sf $init; close($sf); chmod(0666,$_meter_lg_autocal_file); }
	 my $log_file=&webui_prepare_tmp_worker_log($_meter_lg_autocal_log_file,"meter_lg_autocal");
	 my $cmd="setsid /usr/bin/perl /usr/bin/meter_lg_autocal.pl '$_meter_lg_autocal_config_file' '$_meter_lg_autocal_file' '$_meter_lg_autocal_stop_file' </dev/null >'$log_file' 2>&1 &";
	 system($cmd);
	 my $resp='{"status":"started","message":"LG Auto Cal started"}';
	 if($_ac_max_bpc_promoted) {
	  $resp='{"status":"started","message":"LG Auto Cal started (display link promoted to 10-bit)","max_bpc_promoted":true}';
	 }
	 return $resp;
	}

sub webui_meter_lg_autocal_status (@) {
 if(-f $_meter_lg_autocal_file) {
  my $json="";
  if(open(my $fh,"<",$_meter_lg_autocal_file)) { local $/; $json=<$fh>; close($fh); }
	  if($json ne "") {
	   # When the autocal worker has finished (status=complete or cancelled)
	   # and isn't actually running anymore, the persisted state can still
	   # have stale autocal=true / calibration_mode=true (the meter_lg_autocal.pl
	   # worker exits before clearing these flags in some code paths). Force
	   # them to false so the WebUI checkbox and "Busy" indicator update
	   # without waiting for the next request to overwrite the file.
	   if(($json=~/"status"\s*:\s*"cancelled"/ || $json=~/"status"\s*:\s*"complete"/)
	      && !&webui_meter_lg_autocal_running()) {
	    my $changed=0;
	    if($json=~/"autocal"\s*:\s*true/) {
	     $json=~s/"autocal"\s*:\s*true/"autocal":false/;
	     $changed=1;
	    } elsif($json!~/"autocal"\s*:/) {
	     $json=~s/\}$/,"autocal":false}/;
	     $changed=1;
	    }
	    if($json=~/"calibration_mode"\s*:\s*true/) {
	     $json=~s/"calibration_mode"\s*:\s*true/"calibration_mode":false/;
	     $changed=1;
	    } elsif($json!~/"calibration_mode"\s*:/) {
	     $json=~s/\}$/,"calibration_mode":false}/;
	     $changed=1;
	    }
		    if($json=~/"phase"\s*:\s*"restoring"/) {
		     $json=~s/"phase"\s*:\s*"restoring"/"phase":"cancelled"/;
		     $changed=1;
		    }
		    # NOTE: the full-workflow metadata (full_workflow /
		    # full_autocal_phase / full_autocal_run_id / full_autocal_post_*
		    # / full_autocal_touchup) and the
		    # hdr20_1d_tonemap_* group MUST NOT be stripped here. This
		    # status endpoint is read by BOTH (a) the active full-workflow
		    # session -- which uses full_workflow / full_autocal_phase /
		    # hdr20_1d_tonemap_peak_luminance on the greyscale->3D-LUT
		    # advance -- and (b) a fresh browser that would otherwise
		    # see a phantom 3D-LUT restart / phantom tone-map popup.
		    # Stripping on terminal+idle cannot distinguish a mid-workflow
		    # stage boundary from a genuinely-finished workflow, so it
		    # races the auto-advance: the greyscale completion status is
		    # stripped before the JS can read full_workflow to dispatch
		    # the 3D-LUT stage, so the workflow stalls after greyscale
		    # (and the HDR tone-map upload + HDR20 post-cal shadow fix,
		    # which run in the 3D stage, never execute). The phantom
		    # fresh-browser bugs are defused instead at the dedicated
		    # completion signals: see
		    # webui_meter_lg_autocal_clear_full_workflow_state(), called
		    # from /api/lg/autocal/run/end (full-workflow complete/abort)
		    # and the standalone-greyscale completion path. That clears
		     # the keys exactly once, after the whole workflow (or the
		     # standalone greyscale run) is truly done.
		    if($changed && open(my $wf,">",$_meter_lg_autocal_file)) { print $wf $json; close($wf); chmod(0666,$_meter_lg_autocal_file); }
	   }
	   if($json=~/"status"\s*:\s*"running"/) {
	    # Debounce "process died". webui_meter_lg_autocal_running() is a single
	    # pgrep of meter_lg_autocal.pl, and the worker is momentarily out of
	    # pgrep's view during every meter-session teardown/restart (each
	    # restart re-acquires the i1d3 colorimeter, which briefly drops the
	    # worker). A one-shot miss must not flip a healthy run to
	    # "process died", so we persist the first-miss time in a sidecar
	    # (across the per-request forks) and only declare death after a grace
	    # window of sustained absence. The timer is cleared as soon as the
	    # worker reappears or the status leaves "running".
	    my $_dmf="$_meter_lg_autocal_file.misses";
	    if(!&webui_meter_lg_autocal_running()) {
	     my $_now=int(time()*1000);
	     my $_first_miss=0;
	     if(open(my $mf,"<",$_dmf)) { local $/; my $m=<$mf>; close($mf); $_first_miss=($m=~/(\d+)/?$1:0); }
	     $_first_miss=$_now if($_first_miss<=0 || $_first_miss>$_now);
	     if(($_now-$_first_miss) < 15000) {
	      if(open(my $mf,">",$_dmf)) { print $mf $_first_miss; close($mf); chmod(0666,$_dmf); }
	      return $json;
	     }
	     unlink($_dmf);
	     # Explicit Stop (stop-file present) always wins over the
	     # final-1D "looks complete" promotion. Otherwise a kill during
	     # end-of-run upload leaves status=complete and the next page
	     # refresh opens the success popup for a cancelled cal.
	     if(-f $_meter_lg_autocal_stop_file) {
	      $json=~s/"status"\s*:\s*"running"/"status":"cancelled"/;
	      if($json=~/"current_name"\s*:\s*"[^"]*"/) {
	       $json=~s/"current_name"\s*:\s*"[^"]*"/"current_name":"Auto Cal cancelled"/;
	      } else {
	       $json=~s/\}$/,"current_name":"Auto Cal cancelled"}/;
	      }
	      if($json=~/"message"\s*:\s*"[^"]*"/) {
	       $json=~s/"message"\s*:\s*"[^"]*"/"message":"Auto Cal stopped"/;
	      } else {
	       $json=~s/\}$/,"message":"Auto Cal stopped"}/;
	      }
	      if($json=~/"phase"\s*:\s*"[^"]*"/) {
	       $json=~s/"phase"\s*:\s*"[^"]*"/"phase":"cancelled"/;
	      } else {
	       $json=~s/\}$/,"phase":"cancelled"}/;
	      }
	      if($json=~/"autocal"\s*:\s*(?:true|false)/) {
	       $json=~s/"autocal"\s*:\s*(?:true|false)/"autocal":false/;
	      } else {
	       $json=~s/\}$/,"autocal":false}/;
	      }
	      if($json=~/"calibration_mode"\s*:\s*(?:true|false)/) {
	       $json=~s/"calibration_mode"\s*:\s*(?:true|false)/"calibration_mode":false/;
	      }
	     } elsif(
	      $json=~/"final_1d_lut_uploaded"\s*:\s*true/ &&
	      $json=~/"final_1d_lut_upload_verified"\s*:\s*true/ &&
	      $json=~/"calibration_mode"\s*:\s*false/
	     ) {
	      my $now=$_now;
	      $json=~s/"status"\s*:\s*"running"/"status":"complete"/;
	      if($json=~/"current_name"\s*:\s*"[^"]*"/) {
	       $json=~s/"current_name"\s*:\s*"[^"]*"/"current_name":"Auto Cal complete"/;
	      } else {
	       $json=~s/\}$/,"current_name":"Auto Cal complete"}/;
	      }
	      if($json=~/"message"\s*:\s*"[^"]*"/) {
	       $json=~s/"message"\s*:\s*"[^"]*"/"message":"Auto Cal complete"/;
	      } else {
	       $json=~s/\}$/,"message":"Auto Cal complete"}/;
	      }
	      $json=~s/\}$/,"completed_at":$now}/ if($json!~/"completed_at"\s*:/);
	      if($json!~/"elapsed_ms"\s*:/) {
	       my $elapsed=0;
	       $elapsed=$now-($1+0) if($json=~/"started_at"\s*:\s*(\d+)/);
	       $elapsed=0 if($elapsed<0);
	       $json=~s/\}$/,"elapsed_ms":$elapsed}/;
	      }
	     } else {
	      $json=~s/"status"\s*:\s*"running"/"status":"error"/;
	      if($json=~/"current_name"\s*:\s*"[^"]*"/) {
	       $json=~s/"current_name"\s*:\s*"[^"]*"/"current_name":"Auto Cal process died"/;
	      }
	      # Preserve any real error message the worker already wrote (the
	      # eval `or do {}` block writes $state->{message}=$err before
	      # exit). Only fall back to the generic "stopped unexpectedly"
	      # rewrite when the existing message is empty, the default
	      # "Starting" placeholder, or itself the generic string from a
	      # prior rewrite (which would otherwise loop). Without this guard
	      # the rewrite silently overwrites the actual die() error string,
	      # making "auto cal died" indistinguishable from "auto cal
	      # completed with an unreported exception".
	      my $_existing_msg="";
	      $_existing_msg=$1 if($json=~/"message"\s*:\s*"([^"]*)"/);
	      if($_existing_msg eq ""
	       || $_existing_msg eq "Starting"
	       || $_existing_msg eq "Starting LG Auto Cal..."
	       || $_existing_msg eq "Auto Cal complete"
	       || $_existing_msg eq "LG Auto Cal stopped unexpectedly") {
	       $json=~s/"message"\s*:\s*"[^"]*"/"message":"LG Auto Cal stopped unexpectedly"/;
	      }
	     }
	     if(open(my $wf,">",$_meter_lg_autocal_file)) { print $wf $json; close($wf); chmod(0666,$_meter_lg_autocal_file); }
	    } else {
	     unlink($_dmf);
	    }
	   } else {
	    unlink("$_meter_lg_autocal_file.misses");
	   }
	   return $json;
  }
 }
 return '{"status":"idle"}';
}

sub webui_meter_lg_autocal_stop (@) {
 &webui_meter_lg_autocal_kill(1);
 # Full Auto Cal may already have finished greyscale (status=complete +
 # full_workflow) and be in/after the 3D stage. Kill 3D too and strip the
 # full-workflow keys so a refresh cannot re-adopt the finished run and
 # open the Generate Post-Cal Report popup.
 &webui_meter_lg_3d_autocal_kill(1);
 &webui_meter_lg_autocal_clear_full_workflow_state();
 &webui_meter_stop();
 return '{"status":"ok","message":"LG Auto Cal stopped"}';
}

sub webui_meter_lg_3d_autocal_running (@) {
 my $alive=`pgrep -f '[m]eter_lg_3d_autocal\\.pl' 2>/dev/null`;
 return ($alive=~/\d/) ? 1 : 0;
}

sub webui_meter_lg_3d_autocal_same_run_running (@) {
 my ($body)=@_;
 return 0 if(!defined($body) || $body eq "" || !-f $_meter_lg_3d_autocal_file);
 my $run="";
 $run=$1 if($body=~/"full_autocal_run_id"\s*:\s*"([^"]+)"/);
 $run=$1 if($run eq "" && $body=~/"run_id"\s*:\s*"([^"]+)"/);
 return 0 if($run eq "");
 my $json="";
 if(open(my $fh,"<",$_meter_lg_3d_autocal_file)) { local $/; $json=<$fh>; close($fh); }
 return 0 if($json eq "" || $json!~/"status"\s*:\s*"running"/);
 return 1 if($json=~/"full_autocal_run_id"\s*:\s*"\Q$run\E"/);
 return 1 if($json=~/"run_id"\s*:\s*"\Q$run\E"/);
 return 0;
}

sub webui_meter_lg_3d_autocal_mark_cancelled (@) {
 return unless(-f $_meter_lg_3d_autocal_file);
 my $json="";
 if(open(my $fh,"<",$_meter_lg_3d_autocal_file)) { local $/; $json=<$fh>; close($fh); }
 return if($json eq "");
 # Force cancelled over running/complete (same race as greyscale: process-
 # died or a finished 3D stage left status=complete with full_workflow).
 if($json=~/"status"\s*:\s*"[^"]*"/) {
  $json=~s/"status"\s*:\s*"[^"]*"/"status":"cancelled"/;
 } else {
  $json=~s/\}$/,"status":"cancelled"}/;
 }
 if($json=~/"current_name"\s*:\s*"[^"]*"/) {
  $json=~s/"current_name"\s*:\s*"[^"]*"/"current_name":"3D LUT AutoCal cancelled"/;
 } else {
  $json=~s/\}$/,"current_name":"3D LUT AutoCal cancelled"}/;
 }
 if($json=~/"message"\s*:\s*"[^"]*"/) {
  $json=~s/"message"\s*:\s*"[^"]*"/"message":"3D LUT AutoCal stopped"/;
 } else {
  $json=~s/\}$/,"message":"3D LUT AutoCal stopped"}/;
 }
 if(open(my $fh,">",$_meter_lg_3d_autocal_file)) { print $fh $json; close($fh); chmod(0666,$_meter_lg_3d_autocal_file); }
}

sub webui_meter_lg_3d_autocal_kill (@) {
 my $mark=shift;
 if(open(my $fh,">",$_meter_lg_3d_autocal_stop_file)) { print $fh time(); close($fh); chmod(0666,$_meter_lg_3d_autocal_stop_file); }
 system("sudo pkill -TERM -f '[m]eter_lg_3d_autocal\\.pl' 2>/dev/null");
 select(undef,undef,undef,0.4);
 system("sudo pkill -9 -f '[m]eter_lg_3d_autocal\\.pl' 2>/dev/null") if(&webui_meter_lg_3d_autocal_running());
 &webui_meter_lg_3d_autocal_mark_cancelled() if($mark);
}

sub webui_meter_lg_3d_autocal_start (@) {
 my ($body)=@_;
 lock($_meter_lg_3d_autocal_start_lock);
 return '{"status":"error","message":"LG 3D LUT AutoCal payload required"}' if(!defined($body) || $body eq "" || $body!~/^\s*\{/);
 if(&webui_meter_autocal_blocked_for_simulation($body)) {
  return '{"status":"error","message":"AutoCal is not available with the Simulated Meter. Connect a real meter to calibrate a display."}';
 }
 $body=&webui_meter_autocal_force_standard_observer($body);
 $body=&webui_meter_lg_body_with_display_model($body);
 my $_autocal_handoff_guard=&webui_meter_lg_autocal_handoff_guard();
 return $_autocal_handoff_guard if(defined($_autocal_handoff_guard));
 if(&webui_meter_lg_3d_autocal_running()) {
  return '{"status":"started","message":"LG 3D LUT AutoCal already running"}' if(&webui_meter_lg_3d_autocal_same_run_running($body));
  # retryable:false: a DIFFERENT run's worker is alive. The busy regex must
  # not treat this as a transient hand-off wait (see the run-id check in the
  # browser's adoption probe).
  return '{"status":"error","retryable":false,"message":"LG 3D LUT AutoCal is already running"}';
 }
 &webui_meter_stop();
 system("mkdir -p /var/lib/PGenerator/lg/luts 2>/dev/null");
 system("chmod 0777 /var/lib/PGenerator/lg /var/lib/PGenerator/lg/luts 2>/dev/null");
 unlink($_meter_lg_3d_autocal_stop_file);
 if(-e $_meter_lg_3d_autocal_stop_file) {
  system("sudo rm -f ".quotemeta($_meter_lg_3d_autocal_stop_file)." 2>/dev/null");
  unlink($_meter_lg_3d_autocal_stop_file);
 }
 # The 3D LUT body may or may not carry signal_mode (it usually inherits
 # from the active display state). Resolve signal_mode the same way the
 # server-side greyscale path does: body first, then the active conf's
 # signal_mode (dv_status/is_hdr/eotf). Same helper as the greyscale
 # autocal — promotes the link to max_bpc=10 when SDR + max_bpc<10.
 my $_ac3_signal_mode="";
 $_ac3_signal_mode=$1 if($body=~/"signal_mode"\s*:\s*"([^"]+)"/);
 if($_ac3_signal_mode eq "") {
  &webui_reload_pgenerator_conf();
  if(int($pgenerator_conf{"dv_status"} || 0) || int($pgenerator_conf{"is_std_dovi"} || 0) || int($pgenerator_conf{"is_ll_dovi"} || 0)) {
   $_ac3_signal_mode="dv";
  } elsif(int($pgenerator_conf{"is_hdr"} || 0)) {
   $_ac3_signal_mode=(int($pgenerator_conf{"eotf"} || 0) == 3) ? "hlg" : "hdr10";
  } else {
   $_ac3_signal_mode="sdr";
  }
 }
 my $_ac3_max_bpc_promoted=&webui_meter_lg_autocal_ensure_10b($_ac3_signal_mode);
 # Range alignment (SDR + HDR10): pattern codes MUST match the live HDMI
 # quant range (rgb_quant_range). Defaulting missing/wrong body fields to
 # limited ("1") made Full-range Full AutoCal profile 3D LUTs against 16-235
 # / 64-940 codes while the renderer was Full 0-255 / 0-1023 -- the matrix
 # then baked the wrong legal-range crush into the LUT. Same intent as
 # greyscale autocal (webui_meter_lg_autocal_start): conf wins over stale
 # body defaults (e.g. Full AutoCal patternSignalRange leftover "1").
 {
  &webui_reload_pgenerator_conf();
  my $_ac3_eff=&webui_preferred_rgb_quant_range();
  $_ac3_eff="2" if(!defined($_ac3_eff) || $_ac3_eff !~ /^[12]$/);
  if($_ac3_eff =~ /^[12]$/) {
   foreach my $key ("signal_range","pattern_signal_range","transport_signal_range") {
    if($body =~ /"${key}"\s*:/) {
     $body =~ s/"${key}"\s*:\s*"?\d+"?/"${key}":"$_ac3_eff"/;
    } else {
     $body =~ s/\}\s*\z/,"${key}":"$_ac3_eff"}/;
    }
   }
  }
 }
 # HDR20 post-cal shadow correction (terminal sub-phase of the 3D LUT
 # autocal). Append the config knobs from PGenerator.conf and the 5%
 # grey probe step so the 3D worker can run the correction loop after
 # the tone-map upload completes. Only active on HDR/HDR20 runs --
 # SDR and DV are untouched. See
 # docs/superpowers/specs/2026-07-02-hdr20-postcal-shadow-correction-design.md.
 if(lc($_ac3_signal_mode) eq "hdr10") {
  &webui_reload_pgenerator_conf();
  my %_hdr20_shadow_knobs=(
   "lg_autocal_hdr20_postcal_shadow_enable" => ["int", 0],
   "lg_autocal_hdr20_postcal_shadow_band_top_ire" => ["int", 25],
   "lg_autocal_hdr20_postcal_shadow_taper_top_ire" => ["int", 30],
   "lg_autocal_hdr20_postcal_shadow_tol" => ["num", 0.05],
   "lg_autocal_hdr20_postcal_shadow_max_passes" => ["int", 6],
   "lg_autocal_hdr20_postcal_shadow_damp" => ["num", 0.5],
   "lg_autocal_hdr20_postcal_shadow_gain" => ["int", 150],
   "lg_autocal_hdr20_postcal_shadow_seed_counts" => ["int", 0],
   "lg_autocal_hdr20_postcal_shadow_index_scale" => ["num", 0.5],
   "lg_autocal_hdr20_postcal_shadow_zone_scales" => ["str", "5:0.505,10:0.50,15:0.36,20:0.41,25:0.41,30:0.41"],
   "lg_autocal_hdr20_postcal_shadow_target_lift" => ["num", 1.0],
   "lg_autocal_hdr20_postcal_shadow_zone_probe" => ["int", 1],
   "lg_autocal_hdr20_postcal_shadow_matrix_path" => ["str", "/etc/PGenerator/hdr20_postcal_shadow_matrix.json"],
  );
  foreach my $k (sort keys %_hdr20_shadow_knobs) {
   next if($body =~ /"${k}"/);
   my ($type,$default)=@{$_hdr20_shadow_knobs{$k}};
   my $v=$pgenerator_conf{$k};
   $v=$default if(!defined($v) || $v eq "");
   my $literal;
   if($type eq "str") {
    $v=~s/\\/\\\\/g; $v=~s/"/\\"/g;
    $literal='"'.$v.'"';
   } elsif($type eq "num") {
    $v+=0;
    $literal=sprintf("%.4f",$v);
    $literal=~s/0+$//; $literal=~s/\.$//;
    $literal=$literal+0;
   } else {
    $v+=0; $v=0 if($v < 0);
    $literal=int($v);
   }
   $body=~s/\}\s*\z/,"${k}":${literal}}/;
  }
  # Build the 5% grey probe step (r=g=b grey) from THIS run's
  # bit-depth + range so codes always match the greyscale stage's 5%
  # anchor. The 3D worker's read_step reads whatever r/g/b it gets.
  if($body !~ /"postcal_shadow_probe_step"/) {
   my $_psr=""; $_psr=$1 if($body=~/"pattern_signal_range"\s*:\s*"([12])"/);
   $_psr="1" if($_psr ne "1" && $_psr ne "2");
   my $_pmb=""; $_pmb=$1 if($body=~/"max_bpc"\s*:\s*"([0-9]+)"/);
   $_pmb="10" if($_pmb ne "8" && $_pmb ne "10");
   my $_pcode;
   if($_pmb eq "10") {
    $_pcode=($_psr eq "2") ? int((5/100)*1023+0.5) : int(64 + (5/100)*876 + 0.5);
   } else {
    $_pcode=($_psr eq "2") ? int((5/100)*255+0.5) : int(16 + (5/100)*219 + 0.5);
   }
   my $_pinput_max=($_pmb eq "10") ? 1023 : 255;
   $body=~s/\}\s*\z/,"postcal_shadow_probe_step":{"r":$_pcode,"g":$_pcode,"b":$_pcode,"input_max":$_pinput_max,"pattern_signal_range":"$_psr","ire":5,"stimulus":5,"name":"5% grey (post-cal shadow)","signal_r_pct":5,"signal_g_pct":5,"signal_b_pct":5,"kind":"white","phase":"postcal_shadow"}}/;
  }
 }
 if(open(my $fh,">",$_meter_lg_3d_autocal_config_file)) {
  print $fh $body;
  close($fh);
  chmod(0666,$_meter_lg_3d_autocal_config_file);
 } else {
  return '{"status":"error","message":"Unable to prepare LG 3D LUT AutoCal config"}';
	 }
	 # Stamp the Full AutoCal run id (if the body carries one) into the initial
	 # status: the worker only writes it on its FIRST write_state, and the
	 # browser's adoption probe requires a run-id match -- without this stamp
	 # the spawn-to-first-write window would refuse to adopt our own worker.
	 # Mirrors webui_meter_lg_dv_profile_start.
	 my $_ac3_run_id="";
	 $_ac3_run_id=$1 if($body=~/"full_autocal_run_id"\s*:\s*"([^"\\]{1,200})"/);
	 my $init=($_ac3_run_id ne "")
	  ? '{"status":"running","autocal3d":true,"autocal_3d":true,"full_autocal_run_id":"'.$_ac3_run_id.'","current_step":0,"total_steps":0,"current_name":"Starting LG 3D LUT AutoCal...","message":"Starting","readings":[]}'
	  : '{"status":"running","autocal3d":true,"autocal_3d":true,"current_step":0,"total_steps":0,"current_name":"Starting LG 3D LUT AutoCal...","message":"Starting","readings":[]}';
	 if(open(my $sf,">",$_meter_lg_3d_autocal_file)) { print $sf $init; close($sf); chmod(0666,$_meter_lg_3d_autocal_file); }
	 my $log_file=&webui_prepare_tmp_worker_log($_meter_lg_3d_autocal_log_file,"meter_lg_3d_autocal");
	 my $cmd="setsid /usr/bin/perl /usr/bin/meter_lg_3d_autocal.pl '$_meter_lg_3d_autocal_config_file' '$_meter_lg_3d_autocal_file' '$_meter_lg_3d_autocal_stop_file' </dev/null >'$log_file' 2>&1 &";
	 system($cmd);
	 my $resp='{"status":"started","message":"LG 3D LUT AutoCal started"}';
	 if($_ac3_max_bpc_promoted) {
	  $resp='{"status":"started","message":"LG 3D LUT AutoCal started (display link promoted to 10-bit)","max_bpc_promoted":true}';
	 }
	 return $resp;
	}

# Retry only the TV commit/finalisation phase after a failed commit (3D LUT,
# tone map or shadow finalisation). The original solved cube and exact
# 33-point binary stay on disk, so this path neither re-runs the meter nor
# reconstructs the payload from a smaller export cube. {dismiss:true} retires
# the offer instead.
sub webui_meter_lg_3d_autocal_retry_upload (@) {
 my ($body)=@_;
 lock($_meter_lg_3d_autocal_start_lock);
 return '{"status":"error","message":"LG 3D LUT AutoCal is already running"}' if(&webui_meter_lg_3d_autocal_running());
 return '{"status":"error","message":"No failed 3D LUT upload is available to retry"}'
  if(!-f $_meter_lg_3d_autocal_file || !-f $_meter_lg_3d_autocal_config_file);
 my ($state_raw,$config_raw)=("","");
 if(open(my $sf,"<",$_meter_lg_3d_autocal_file)) { local $/; $state_raw=<$sf>; close($sf); }
 if(open(my $cf,"<",$_meter_lg_3d_autocal_config_file)) { local $/; $config_raw=<$cf>; close($cf); }
 my $state=eval { require JSON::PP; JSON::PP::decode_json($state_raw); };
 my $config=eval { require JSON::PP; JSON::PP::decode_json($config_raw); };
 my $request=eval { require JSON::PP; JSON::PP::decode_json($body||'{}'); };
 $request={} if(ref($request) ne "HASH");
 return '{"status":"error","message":"The saved 3D LUT retry state is invalid"}'
  if(ref($state) ne "HASH" || ref($config) ne "HASH");
 return '{"status":"error","message":"The 3D LUT run is not waiting for an upload retry"}'
  if(($state->{"status"}||"") ne "error" || !$state->{"upload_retry_available"});
 my $encoder=JSON::PP->new->canonical(1);
 if($request->{"dismiss"}) {
  # Operator closed the retry box: retire the offer on disk so the next page
  # load does not re-raise it. The generated files stay where they are.
  $state->{"upload_retry_available"}=JSON::PP::false;
  $state->{"upload_retry_dismissed"}=JSON::PP::true;
  my $tmp=$_meter_lg_3d_autocal_file.".dismiss.$$";
  # The handle lexical must be declared before the statement that writes
  # through it: `open(my $sf,...) && print $sf ...` in one expression leaves
  # `print` looking at the not-yet-visible name and dies at runtime.
  my $sf;
  if(open($sf,">",$tmp) && (print $sf $encoder->encode($state)) && close($sf) && chmod(0666,$tmp) && rename($tmp,$_meter_lg_3d_autocal_file)) {
   return '{"status":"ok","message":"3D LUT upload retry dismissed"}';
  }
  unlink($tmp);
  return '{"status":"error","message":"Unable to dismiss the 3D LUT upload retry"}';
 }
 my $requested_run=$request->{"run_id"}||"";
 my $saved_run=$state->{"full_autocal_run_id"}||$config->{"full_autocal_run_id"}||$config->{"run_id"}||"";
 return '{"status":"error","message":"The retry belongs to a different AutoCal run"}'
  if($requested_run ne "" && $saved_run ne "" && $requested_run ne $saved_run);
 my $export=ref($state->{"export"}) eq "HASH" ? $state->{"export"} : {};
 my $cube_path=$export->{"cube_path"}||"";
 my $payload_path=$export->{"payload_path"}||"";
 return '{"status":"error","message":"The exact generated LUT files are no longer available"}'
  if($cube_path !~ m{^\Q$_meter_lg_3d_autocal_luts_dir\E/[A-Za-z0-9._-]+\.cube$}
   || $payload_path !~ m{^\Q$_meter_lg_3d_autocal_luts_dir\E/[A-Za-z0-9._-]+\.bin$}
   || !-f $cube_path || !-f $payload_path || -s $payload_path != (33**3*3*2));
 my $upload_request=ref($state->{"upload_request"}) eq "HASH" ? $state->{"upload_request"} : {};
 my $probe=ref($state->{"upload_probe"}) eq "HASH" ? $state->{"upload_probe"} : {};
 my $parent_method=$state->{"method"}||$config->{"method"}||"matrix";
 $config->{"retry_upload_only"}=JSON::PP::true;
 $config->{"retry_parent_method"}=$parent_method;
 $config->{"method"}="imported";
 $config->{"imported_cube_path"}=$cube_path;
 $config->{"imported_payload_path"}=$payload_path;
 $config->{"upload"}=JSON::PP::true;
 $config->{"output"}="upload";
 $config->{"post_check"}=JSON::PP::false;
 $config->{"upload_command"}=$upload_request->{"upload_command"}||$probe->{"upload_command"}||$config->{"upload_command"}||"";
 $config->{"get_command"}=$upload_request->{"get_command"}||$probe->{"get_command"}||$config->{"get_command"}||"";
 my $shadow=ref($state->{"hdr20_postcal_shadow"}) eq "HASH" ? $state->{"hdr20_postcal_shadow"} : {};
 my $shadow_dpg=$state->{"hdr20_postcal_shadow_dpg_data"};
 my $shadow_complete=(ref($shadow_dpg) eq "ARRAY" && scalar(@{$shadow_dpg}) == 3072
   && ($shadow->{"status"}||"") =~ /^(?:self_gated|converged|best_effort|reverted)$/
   && $shadow->{"reestablished"}) ? 1 : 0;
 my $shadow_measurements_pending=($config->{"full_workflow"}
  && lc($config->{"signal_mode"}||"") eq "hdr10"
  && $config->{"lg_autocal_hdr20_postcal_shadow_enable"}
  && !$shadow_complete) ? 1 : 0;
 if($shadow_complete) {
  $config->{"full_workflow_dpg_data"}=$shadow_dpg;
  $config->{"hdr20_1d_dpg_data"}=$shadow_dpg;
  $config->{"retry_shadow_finalisation_only"}=JSON::PP::true;
 }
 delete $config->{"solve_only"};
 delete $config->{"fixture_mode"};
 my $retry_message=$shadow_measurements_pending
  ? "Reusing the exact generated payload; unfinished shadow validation measurements will still run"
  : "Reusing the exact generated payload; no measurements will be repeated";
 $state->{"status"}="running";
 $state->{"phase"}="upload_retry";
 $state->{"current_name"}="Retrying LG 3D LUT upload";
 $state->{"message"}=$retry_message;
 $state->{"upload_retry_available"}=JSON::PP::false;
 $state->{"retry_requested_at"}=int(time()*1000);
 $state->{"retry_shadow_measurements_pending"}=$shadow_measurements_pending ? JSON::PP::true : JSON::PP::false;
 delete $state->{"terminal_commit_verified"};
 # Prepare both documents before replacing either live file. The worker is
 # launched only after both renames succeed. If the state rename fails after
 # the config rename, restore the original config so a later retry cannot
 # inherit a half-applied transaction.
 my $config_tmp=$_meter_lg_3d_autocal_config_file.".retry.$$";
 my $state_tmp=$_meter_lg_3d_autocal_file.".retry.$$";
 # Same scoping trap as the dismiss branch above: a `my` inside the if
 # condition is not in scope for the `print` on the next statement.
 my $cf;
 if(!open($cf,">",$config_tmp)) {
  return '{"status":"error","message":"Unable to prepare the 3D LUT upload retry"}';
 }
 my $config_written=(print $cf $encoder->encode($config)) && close($cf);
 $config_written=0 if(!chmod(0666,$config_tmp));
 my $state_written=0;
 if(open(my $sf,">",$state_tmp)) {
  $state_written=(print $sf $encoder->encode($state)) && close($sf);
  $state_written=0 if(!chmod(0666,$state_tmp));
 }
 if(!$config_written || !$state_written) {
  unlink($config_tmp);
  unlink($state_tmp);
  return '{"status":"error","message":"Unable to prepare the 3D LUT upload retry state"}';
 }
 if(!rename($config_tmp,$_meter_lg_3d_autocal_config_file)) {
  unlink($config_tmp);
  unlink($state_tmp);
  return '{"status":"error","message":"Unable to save the 3D LUT upload retry config"}';
 }
 if(!rename($state_tmp,$_meter_lg_3d_autocal_file)) {
  my $rollback_tmp=$_meter_lg_3d_autocal_config_file.".rollback.$$";
  my $rolled_back=0;
  if(open(my $rf,">",$rollback_tmp)) {
   my $rollback_written=(print $rf $config_raw) && close($rf);
   chmod(0666,$rollback_tmp);
   $rolled_back=rename($rollback_tmp,$_meter_lg_3d_autocal_config_file) if($rollback_written);
  }
  unlink($rollback_tmp);
  unlink($state_tmp);
  return $rolled_back
   ? '{"status":"error","message":"Unable to save the 3D LUT retry state; the original config was restored"}'
   : '{"status":"error","message":"Unable to save the 3D LUT retry state or restore its original config"}';
 }
 unlink($_meter_lg_3d_autocal_stop_file);
 if(open(my $lf,">>",$_meter_lg_3d_autocal_log_file)) {
  print $lf "\n--- manual 3D LUT upload retry ".time()." ---\n";
  close($lf);
 }
 my $cmd="setsid /usr/bin/perl /usr/bin/meter_lg_3d_autocal.pl '$_meter_lg_3d_autocal_config_file' '$_meter_lg_3d_autocal_file' '$_meter_lg_3d_autocal_stop_file' </dev/null >>'$_meter_lg_3d_autocal_log_file' 2>&1 &";
 system($cmd);
 return JSON::PP::encode_json({
  status => "started",
  message => $retry_message,
  profile_measurements_reused => JSON::PP::true,
  shadow_measurements_pending => $shadow_measurements_pending ? JSON::PP::true : JSON::PP::false,
  payload_reused => JSON::PP::true,
 });
}

sub webui_meter_lg_3d_autocal_compact_status_json (@) {
 my $json=shift;
 return $json if(!defined($json) || $json eq "");
 # LG readback responses can include the full 33^3 payload data. Keep the
 # verification metadata, but do not send the huge raw payload through the UI
 # status poller.
 $json=~s/"data"\s*:\s*"[^"]{1024,}"/"data":"(omitted from status)"/g;
 # The corrected shadow DPG is a 3072-element ARRAY the string elision above
 # cannot catch (~18KB in every 1.5s poll). Only the webui retry endpoint
 # reads it, and that reads the state FILE, not this projection.
 $json=~s/"hdr20_postcal_shadow_dpg_data"\s*:\s*\[[-0-9.eE,\s]{256,}\]/"hdr20_postcal_shadow_dpg_data":"(omitted from status)"/g;
 return $json;
}

# Older workers could write status=complete after an upload failure. Recover
# only those impossible "success" records where the saved run explicitly
# requested a TV upload and both exact generated files are still present.
# Genuine export-only completions remain untouched.
sub webui_meter_lg_3d_autocal_recover_unverified_complete (@) {
 my ($raw)=@_;
 return $raw if(!defined($raw) || $raw eq "" || $raw!~/"status"\s*:\s*"complete"/);
 my $state=eval { require JSON::PP; JSON::PP::decode_json($raw); };
 return $raw if(ref($state) ne "HASH" || $state->{"upload_verified"});
 return $raw if(!-f $_meter_lg_3d_autocal_config_file);
 my $config_raw="";
 if(open(my $cf,"<",$_meter_lg_3d_autocal_config_file)) { local $/; $config_raw=<$cf>; close($cf); }
 my $config=eval { require JSON::PP; JSON::PP::decode_json($config_raw); };
 return $raw if(ref($config) ne "HASH" || (!$config->{"upload"} && ($config->{"output"}||"") ne "upload") || $config->{"fixture_mode"});
 my $export=ref($state->{"export"}) eq "HASH" ? $state->{"export"} : {};
 my $cube_path=$export->{"cube_path"}||"";
 my $payload_path=$export->{"payload_path"}||"";
 return $raw if($cube_path !~ m{^\Q$_meter_lg_3d_autocal_luts_dir\E/[A-Za-z0-9._-]+\.cube$}
  || $payload_path !~ m{^\Q$_meter_lg_3d_autocal_luts_dir\E/[A-Za-z0-9._-]+\.bin$}
  || !-f $cube_path || !-f $payload_path || -s $payload_path != (33**3*3*2));
 my $detail=$state->{"upload_message"}||"the TV did not verify the generated payload";
 my $reason="A previous 3D LUT run was marked complete without a verified TV upload: $detail";
 $state->{"status"}="error";
 $state->{"phase"}="upload_failed";
 $state->{"current_name"}="3D LUT was not committed to the TV";
 $state->{"message"}=$reason;
 $state->{"upload_retry_reason"}=$reason;
 $state->{"upload_retry_available"}=JSON::PP::true;
 $state->{"legacy_unverified_complete_recovered"}=JSON::PP::true;
 my $encoder=JSON::PP->new->canonical(1);
 my $recovered=$encoder->encode($state);
 my $tmp=$_meter_lg_3d_autocal_file.".recover.$$";
 if(open(my $sf,">",$tmp)) {
  print $sf $recovered;
  close($sf);
  chmod(0666,$tmp);
  if(rename($tmp,$_meter_lg_3d_autocal_file)) { return $recovered; }
  unlink($tmp);
 }
 return $raw;
}

sub webui_meter_lg_3d_autocal_status (@) {
 if(-f $_meter_lg_3d_autocal_file) {
  my $json="";
  if(open(my $fh,"<",$_meter_lg_3d_autocal_file)) { local $/; $json=<$fh>; close($fh); }
  if($json ne "") {
    $json=&webui_meter_lg_3d_autocal_recover_unverified_complete($json);
    if($json=~/"status"\s*:\s*"running"/) {
     # Debounce "process died" (see the 1D monitor for rationale): the worker
     # is momentarily out of pgrep's view during meter-session teardown/restart
     # (each restart re-acquires the i1d3 colorimeter), so ride out a grace
     # window of sustained absence before declaring death. Persist the
     # first-miss time in a sidecar; clear it when the worker reappears or the
     # status leaves "running".
     my $_dmf="$_meter_lg_3d_autocal_file.misses";
     if(!&webui_meter_lg_3d_autocal_running()) {
      my $_now=int(time()*1000);
      my $_first_miss=0;
      if(open(my $mf,"<",$_dmf)) { local $/; my $m=<$mf>; close($mf); $_first_miss=($m=~/(\d+)/?$1:0); }
      $_first_miss=$_now if($_first_miss<=0 || $_first_miss>$_now);
      if(($_now-$_first_miss) < 15000) {
       if(open(my $mf,">",$_dmf)) { print $mf $_first_miss; close($mf); chmod(0666,$_dmf); }
       return &webui_meter_lg_3d_autocal_compact_status_json($json);
      }
      unlink($_dmf);
      # The worker process is gone while still marked "running". Mirror the 1D
      # monitor's verified-marker fallback: if the 3D LUT was uploaded AND
      # verified (and the tone-map step, when present, succeeded),
      # the calibration actually landed on the TV -- the tone-map helper sends
      # CAL_END as part of its upload, so a verified upload means the cal
      # persisted. The worker was just killed at the very end (e.g. a meter read
      # stall during finalize) before it could write status=complete. Report
      # that as complete instead of a spurious "process died". Only fall back to
      # the died/error path when the LUT did not verify (a genuine failure), the
      # worker left its own specific error message, or the worker never recorded
      # terminal_commit_verified (set only after the commit gate passes).
      my $_uv=($json=~/"upload_verified"\s*:\s*true/) ? 1 : 0;
      my $_terminal_commit=($json=~/"terminal_commit_verified"\s*:\s*true/) ? 1 : 0;
      my $_tm_status=($json=~/"tone_map_upload_status"\s*:\s*"([^"]*)"/) ? $1 : "";
      my $_tm_ok=($_tm_status eq "" || $_tm_status eq "ok") ? 1 : 0;
      if($_uv && $_tm_ok && $_terminal_commit) {
       my $now=$_now;
       $json=~s/"status"\s*:\s*"running"/"status":"complete"/;
       $json=~s/"current_name"\s*:\s*"[^"]*"/"current_name":"LG 3D LUT Auto Cal complete"/ if($json=~/"current_name"\s*:\s*"[^"]*"/);
       my $_msg="3D LUT exported, uploaded, and verified";
       if($json=~/"message"\s*:\s*"[^"]*"/) { $json=~s/"message"\s*:\s*"[^"]*"/"message":"$_msg"/; } else { $json=~s/\}$/,"message":"$_msg"}/; }
       if($json=~/"phase"\s*:\s*"[^"]*"/) { $json=~s/"phase"\s*:\s*"[^"]*"/"phase":"complete"/; } else { $json=~s/\}$/,"phase":"complete"}/; }
       $json=~s/\}$/,"completed_at":$now}/ if($json!~/"completed_at"\s*:/);
      } else {
       $json=~s/"status"\s*:\s*"running"/"status":"error"/;
       if($json=~/"current_name"\s*:\s*"[^"]*"/) {
        $json=~s/"current_name"\s*:\s*"[^"]*"/"current_name":"3D LUT AutoCal process died"/;
       }
       # Preserve a real worker error message; only fall back to the generic
       # string when empty/placeholder/the generic itself.
       my $_em=""; $_em=$1 if($json=~/"message"\s*:\s*"([^"]*)"/);
       if($_tm_status eq "skipped" || $json=~/"tone_map_upload_error_code"\s*:\s*"lg-tone-map-peak-missing"/) {
        my $_peak_msg="HDR tone-map finalisation failed because the measured peak luminance was missing. The calibration session may still be held; restart the TV before another calibration.";
        if($json=~/"message"\s*:\s*"[^"]*"/) { $json=~s/"message"\s*:\s*"[^"]*"/"message":"$_peak_msg"/; } else { $json=~s/\}$/,"message":"$_peak_msg"}/; }
       } elsif($_em eq "" || $_em eq "Starting" || $_em=~/^Starting LG 3D/ || $_em eq "LG 3D LUT AutoCal stopped unexpectedly") {
        $json=~s/"message"\s*:\s*"[^"]*"/"message":"LG 3D LUT AutoCal stopped unexpectedly"/;
       }
      }
      if(open(my $wf,">",$_meter_lg_3d_autocal_file)) { print $wf $json; close($wf); chmod(0666,$_meter_lg_3d_autocal_file); }
     } else {
      unlink($_dmf);
     }
    } else {
     unlink("$_meter_lg_3d_autocal_file.misses");
    }
   return &webui_meter_lg_3d_autocal_compact_status_json($json);
  }
 }
 return '{"status":"idle"}';
}

sub webui_meter_lg_3d_autocal_stop (@) {
 &webui_meter_lg_3d_autocal_kill(1);
 # Strip full-workflow keys from greyscale+3D status so a refresh after
 # Stop cannot re-adopt a finished 3D stage as "Full Auto Cal complete".
 &webui_meter_lg_autocal_clear_full_workflow_state();
 &webui_meter_stop();
 return '{"status":"ok","message":"LG 3D LUT AutoCal stopped"}';
}

sub webui_meter_stop (@) {
 &webui_pattern_stop_guard_set("meter_stop");
 &webui_meter_lg_3d_autocal_kill(1) if(&webui_meter_lg_3d_autocal_running());
 &webui_meter_lg_autocal_kill(1) if(&webui_meter_lg_autocal_running());
 &webui_meter_lg_dv_profile_kill(1) if(defined(&webui_meter_lg_dv_profile_running) && &webui_meter_lg_dv_profile_running());
 # Stop the persistent session daemon first (graceful, then force).
 &webui_meter_session_stop() if(&webui_meter_session_alive());
 my $series_was_alive=&webui_meter_series_alive();
 if($series_was_alive) {
  &webui_meter_series_signal_stop();
  &webui_meter_series_cancel_state();
  # Do not wait here: meter_series may currently be blocked posting its patch
  # to this same single-threaded HTTP server. Waiting used to deadlock until
  # the 8s+3s escalation forcibly killed spotread mid-USB transaction. Return
  # so the queued request can drain; the pattern stop guard replaces it with
  # idle, and meter_series owns graceful spotread shutdown (with its own
  # read-timeout-aware TERM/SIGKILL fallback).
  &log("WebUI: cooperative meter series stop requested; helper owns spotread shutdown");
 } else {
  # No series owns the instrument. Explicit Stop may be releasing an idle
  # manual-read session or a genuinely stale wrapper, so the general cleanup
  # remains available for those paths.
  system("sudo pkill -9 -f 'meter_session.sh' 2>/dev/null");
  system("sudo pkill -9 -f 'spotread_wrapper' 2>/dev/null");
  system("sudo pkill -9 -x spotread 2>/dev/null");
  system("sudo pkill -9 -f 'script.*spotread' 2>/dev/null");
  system("sudo pkill -9 -f 'cat.*spotread_cmd' 2>/dev/null");
  system("sudo pkill -9 -f 'sudo.*spotread' 2>/dev/null");
 }
 &webui_meter_session_ready_cleanup();
 &webui_meter_series_ready_cleanup();
 &webui_meter_series_stop_cleanup() if(!$series_was_alive);
 unlink($_meter_session_pid_file, $_meter_session_config_file, $_meter_session_fifo);
 &webui_meter_read_state_write('{"status":"idle","message":"Measurement stopped"}');
 # Mark state as cancelled (if still running or paused in a setup wizard)
 &webui_meter_series_cancel_state();
 # Clean up stale temp files so new series starts fresh
 unlink("/tmp/spotread_port_cache");
 # Do not unlink the live series' pipe/output while its cooperative shutdown is
 # still draining. The helper removes its own files after spotread exits.
 if(!$series_was_alive) {
  my @stale=glob("/tmp/spotread_series_* /tmp/spotread_cmd_* /tmp/spotread_session_*");
  unlink(@stale) if @stale;
 }
 return '{"status":"ok","message":"Measurement stopped"}';
}

sub webui_meter_stop_status (@) {
 my $series_alive=&webui_meter_series_alive() ? 1 : 0;
 # A series helper normally owns the only spotread process and does not exit
 # until it has gracefully reaped that child. Check both so an abnormal helper
 # exit cannot make the UI claim cancellation is complete while an orphaned
 # meter transaction is still holding USB.
 my $spotread_pids=`pgrep -x spotread 2>/dev/null`;
 my $spotread_alive=(defined($spotread_pids) && $spotread_pids=~/\d/) ? 1 : 0;
 my $stopping=($series_alive || $spotread_alive) ? 1 : 0;
 return '{"status":"'.($stopping ? "stopping" : "stopped").'","series_alive":'.($series_alive ? "true" : "false").',"spotread_alive":'.($spotread_alive ? "true" : "false").'}';
}

sub webui_meter_clear (@) {
 # Clearing CHART DATA must not tear down the meter session. Previously this
 # called webui_meter_stop(), which killed spotread -- so a spectrophotometer
 # had to re-run the calibrate/aim wizard after every clear. The frontend
 # already halts any active read loop; the idle session is reused by the next
 # read. (Series/AutoCal/explicit-Stop still free the meter when they need it.)
 &webui_meter_read_state_write('{"status":"idle"}');
	 unlink("${_meter_read_file}.tmp");
	 unlink("/tmp/meter_series_steps.json");
	 unlink(glob("/tmp/meter_series_steps_*.json"));
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

my $_meter_settings_runtime="$var_dir/running/meter_settings.json";
my $_meter_settings_file="/tmp/meter_settings.json";
# Persistent copy — reloaded on daemon start and mirrored whenever the
# transient /tmp copy is written. Survives reboots and must stay writable
# by the unprivileged pgenerator daemon user.
my $_meter_settings_persist="/var/lib/PGenerator/meter_settings.json";
my $_meter_settings_persist_legacy="/usr/share/PGenerator/meter_settings.json";
# Custom series are user data, not merely a UI preference.  Keep an independent
# authoritative copy below a persistent subdirectory so daemon cleanup of
# top-level runtime/settings files cannot make every imported series vanish.
my $_custom_series_store="/var/lib/PGenerator/custom-series/series.json";

sub _webui_meter_settings_write_json (@) {
 my ($path,$json)=@_;
 return 0 if(!defined($path) || $path eq "");
 my $dir=$path;
 $dir=~s{/[^/]+$}{};
 if($dir ne "" && !-d $dir) {
  system("mkdir -p '$dir' >/dev/null 2>&1");
 }
 my $tmp="$path.tmp";
 if(open(my $fh,">",$tmp)) {
  print $fh $json;
  close($fh);
  return 1 if(rename($tmp,$path));
  unlink($tmp) if(-f $tmp);
 }
 return 0;
}

sub _webui_meter_settings_boot_id (@) {
 my $boot_id="";
 if(open(my $fh,"<","/proc/sys/kernel/random/boot_id")) {
  local $/;
  $boot_id=<$fh>;
  close($fh);
 }
 chomp($boot_id);
 $boot_id=~s/[^A-Za-z0-9_-]//g;
 $boot_id="boot_".time() if($boot_id eq "");
 return $boot_id;
}

# Linear (non-regex) extractor for a JSON string value. The generic key/value
# regex in webui_meter_settings_save uses a repeated group that hits Perl's
# "Complex regular subexpression recursion limit (32766) exceeded" on large
# escaped strings (a multi-series custom_series_json blob has tens of thousands
# of escaped quotes), silently dropping the value. Scan for the closing quote
# by hand instead so blobs of any size round-trip. Returns the quoted value
# (including the surrounding quotes) or undef.
sub _webui_json_str_value (@) {
 my ($src,$key)=@_;
 return undef if(!defined($src) || $src eq "");
 my $anchor="\"$key\"";
 my $ki=index($src,$anchor);
 return undef if($ki < 0);
 my $ci=index($src,":",$ki+length($anchor));
 return undef if($ci < 0);
 my $len=length($src);
 my $i=$ci+1;
 $i++ while($i < $len && substr($src,$i,1)=~/\s/);
 return undef unless($i < $len && substr($src,$i,1) eq '"');
 my $start=$i; $i++;
 while($i < $len) {
  my $c=substr($src,$i,1);
  if($c eq "\\") { $i+=2; next; }
  if($c eq '"') { return substr($src,$start,$i-$start+1); }
  $i++;
 }
 return undef;
}

# Remove every occurrence of a JSON string property without parsing the whole
# document. meter_settings.json from older builds can contain the multi-megabyte
# custom-series value, and the settings response used to append the independent
# store as a second copy. New clients request ordinary settings without that
# blob and load the library from its dedicated endpoint.
sub _webui_json_without_str_key (@) {
 my ($src,$key)=@_;
 return $src if(!defined($src) || $src eq "");
 my $anchor="\"$key\"";
 while(1) {
  my $ki=index($src,$anchor);
  last if($ki < 0);
  my $ci=index($src,":",$ki+length($anchor));
  last if($ci < 0);
  my $len=length($src);
  my $vi=$ci+1;
  $vi++ while($vi < $len && substr($src,$vi,1)=~/\s/);
  last unless($vi < $len && substr($src,$vi,1) eq '"');
  my $i=$vi+1;
  while($i < $len) {
   my $c=substr($src,$i,1);
   if($c eq "\\") { $i+=2; next; }
   if($c eq '"') { $i++; last; }
   $i++;
  }
  last if($i > $len);
  my $start=$ki;
  $start-- while($start > 0 && substr($src,$start-1,1)=~/\s/);
  if($start > 0 && substr($src,$start-1,1) eq ",") {
   $start--;
  } else {
   my $tail=$i;
   $tail++ while($tail < $len && substr($src,$tail,1)=~/\s/);
   $tail++ if($tail < $len && substr($src,$tail,1) eq ",");
   $i=$tail;
  }
  substr($src,$start,$i-$start,"");
 }
 return $src;
}

sub webui_meter_custom_series_load (@) {
 my ($query)=@_;
 my @st=stat($_custom_series_store);
 my $revision=@st ? (($st[9]||0)."-".($st[7]||0)) : "empty";
 return "{\"status\":\"ok\",\"revision\":\"$revision\"}" if(defined($query) && $query=~/(?:^|&)meta=1(?:&|$)/);
 return "{\"status\":\"ok\",\"revision\":\"$revision\",\"state_json\":\"{\\\"format\\\":\\\"pgenerator-custom-series-v1\\\",\\\"next_id\\\":1001,\\\"series\\\":[]}\"}" if(!@st);
 my $quoted="";
 if(open(my $fh,"<",$_custom_series_store)) { local $/; $quoted=<$fh>; close($fh); }
 return '{"status":"error","message":"Custom series store is invalid"}'
  if($quoted!~/^".*"\s*$/s);
 # Keep the stored JSON string quoted and escaped. Decoding this multi-megabyte
 # value with JSON::PP takes many seconds on the Pi4, while the browser parses
 # it in milliseconds. This also lets the server stream the authoritative file
 # without allocating a second expanded copy.
 return "{\"status\":\"ok\",\"revision\":\"$revision\",\"state_json\":$quoted}";
}

sub webui_meter_settings_save (@) {
 my ($body)=@_;
 # Validate: only allow known keys. New color-science keys are additive.
 my %allowed=map {$_=>1} qw(
	 display_type ccss_override pattern_provider target_gamut delay delay_user_set delay_explicit pattern_delay patch_size patch_insert disable_aio
	  patch_insert_patch_enabled patch_insert_patch_every patch_insert_patch_duration patch_insert_patch_level
	  patch_insert_time_enabled patch_insert_time_frequency patch_insert_time_duration patch_insert_time_level
    stabilization_pattern_enabled stabilization_pattern_stimulus stabilization_pattern_size stabilization_pattern_measurement_only
    refresh_rate ccss_file ccss_create_display_type measurement_meter_port profiling_meter_port custom_series_dirty
    low_light_enabled low_light_mode low_light_trigger
  grey_two_point_low grey_two_point_high
  grey_ref_mode gray_world rgb_formula de_form color_de_form target_gamma
  target_white_x target_white_y custom_d65_enabled
  hdr_bt2390 hdr_diffuse_white hdr_diffuse_white_auto incl_lum sep_lum color_incl_lum color_sep_lum simulate_spectro
 );
 my @parts;
 while($body=~/"(\w+)"\s*:\s*("[^"\\]*(?:\\.[^"\\]*)*"|-?\d+(?:\.\d+)?|true|false|null)/g) {
  push @parts, "\"$1\":$2" if($allowed{$1});
 }
 my $safe="{".join(",",@parts)."}";
 if($safe=~/"delay_user_set"\s*:\s*true/i) {
  $safe=~s/,?\s*"delay_explicit"\s*:\s*(?:true|false|null|"[^"]*"|-?\d+(?:\.\d+)?)//g;
  $safe=~s/\{\s*,/\{/g;
  $safe=~s/\}\s*$//;
  $safe.="," if($safe!~/\{\s*$/);
  $safe.='"delay_explicit":true}';
 }
 # Sticky JSON-blob keys: a settings POST from a stale client (an older UI
 # build that predates a key) must not wipe user data a newer build saved.
 # The rebuild above keeps only keys present in the POST body, so a tab
 # running old JS silently dropped custom_series_json on every save. If the
 # incoming body omits one of these keys but the stored settings carry it,
 # preserve the stored value.
 # Big JSON-blob keys (custom_series_json, grey_patch_profiles_json) are handled
 # OUTSIDE the generic regex above (removed from %allowed) because that regex
 # dies on large escaped strings (Perl 32766 recursion limit) -- the cause of
 # large/many custom series silently "disappearing". Extract + preserve them by
 # linear scan, then append to $safe.
 my $custom_series_store_ok=1;
 foreach my $sticky (qw(grey_patch_profiles_json custom_series_json)) {
  my $posted=_webui_json_str_value($body,$sticky);
  $posted="" if(!defined($posted));
  # A stale tab (older JS build) posts the custom-series blob EMPTY without the
  # dirty marker newer builds send. An empty blob only wins when the session
  # explicitly touched custom series; otherwise preserve the stored value so an
  # open old tab can't wipe user data.
  my $posted_empty_stale=($sticky eq "custom_series_json" && $posted ne "" && index($posted,'\\"series\\":[]')>=0 && $body!~/"custom_series_dirty"\s*:\s*true/) ? 1 : 0;
  # Custom series now live only in their independent authoritative store.
  # Keep accepting them on the settings POST for older clients, but do not
  # duplicate the multi-megabyte blob inside meter_settings.json.
  if($sticky eq "custom_series_json") {
   if($posted ne "" && !$posted_empty_stale) {
    $custom_series_store_ok=&_webui_meter_settings_write_json($_custom_series_store,$posted) ? 1 : 0;
   }
   next;
  }
  my $value_to_write="";
  if($posted ne "" && !$posted_empty_stale) {
   $value_to_write=$posted;
  } else {
   foreach my $path ($_meter_settings_runtime,$_meter_settings_persist) {
    next unless(-f $path);
    my $candidate="";
    if(open(my $fh,"<",$path)) { local $/; $candidate=<$fh>; close($fh); }
    my $sv=_webui_json_str_value($candidate,$sticky);
    next unless(defined($sv) && $sv ne "");
    next if($posted_empty_stale && index($sv,'\\"series\\":[{')<0);
    $value_to_write=$sv; last;
   }
  }
  next if($value_to_write eq "");
  $safe=~s/\}\s*$//;
  $safe.="," if($safe!~/\{\s*$/);
  $safe.="\"$sticky\":$value_to_write}";
 }
 my $saved_runtime=&_webui_meter_settings_write_json($_meter_settings_runtime,$safe);
 my $saved_persist=&_webui_meter_settings_write_json($_meter_settings_persist,$safe);
 return '{"status":"ok"}' if(($saved_runtime || $saved_persist) && $custom_series_store_ok);
 &log("WebUI: meter settings save failed (runtime=$_meter_settings_runtime persist=$_meter_settings_persist)");
 return '{"status":"error","message":"Failed to save meter settings"}';
}

# Solved 3D-LUT listing/download for the WebUI (files written by
# meter_lg_3d_autocal.pl's export_lut). Name whitelist keeps this endpoint
# from serving anything outside the luts directory.
# Generic lattice-cube solve (measure -> solve -> export, any display): runs
# meter_lg_3d_autocal.pl in solve_only mode with its OWN config/state/stop
# paths -- no meter, no TV, no upload, no collision with a real AutoCal run.
# Offline solve exports .cube + .json (host apps). AutoCal upload also writes
# the LG .bin payload. Files land in the standard solved-LUT dir so LUT Tools
# lists them immediately.
my $_lut_solve_config_file="/tmp/lut_solve_config.json";
my $_lut_solve_state_file="/tmp/lut_solve_state.json";
my $_lut_solve_stop_file="/tmp/lut_solve_stop.signal";
sub webui_3d_lut_solve (@) {
 my ($body)=@_;
 return '{"status":"error","message":"Solve payload required"}' if(!defined($body) || $body eq "" || $body!~/^\s*\{/);
 return '{"status":"error","message":"lattice_readings required"}' if($body!~/"lattice_readings"\s*:\s*\[/);
 if(-f $_lut_solve_state_file) {
  my $age=time()-(stat($_lut_solve_state_file))[9];
  my $prev="";
  if(open(my $fh,'<',$_lut_solve_state_file)) { local $/; $prev=<$fh>; close($fh); }
  return '{"status":"error","message":"A LUT solve is already running"}' if($age < 120 && $prev=~/"status"\s*:\s*"running"/);
 }
 my $cfg=$body;
 $cfg=~s/\}\s*\z/,"solve_only":1}/ unless($cfg=~/"solve_only"/);
 if(open(my $fh,'>',$_lut_solve_config_file)) { print $fh $cfg; close($fh); }
 else { return '{"status":"error","message":"Unable to write solve config"}'; }
 if(open(my $fh,'>',$_lut_solve_state_file)) { print $fh '{"status":"running","solve_only":true,"message":"Starting LUT solve..."}'; close($fh); }
 unlink($_lut_solve_stop_file);
 my $log_file="/tmp/lut_solve.log";
 my $cmd="setsid /usr/bin/perl /usr/bin/meter_lg_3d_autocal.pl '$_lut_solve_config_file' '$_lut_solve_state_file' '$_lut_solve_stop_file' </dev/null >'$log_file' 2>&1 &";
 system($cmd);
 return '{"status":"started","message":"LUT solve started"}';
}

sub webui_3d_lut_solve_status (@) {
 if(open(my $fh,'<',$_lut_solve_state_file)) {
  local $/;
  my $json=<$fh>;
  close($fh);
  return $json if(defined($json) && $json=~/^\s*\{/);
 }
 return '{"status":"idle"}';
}

# Save an operator-imported .cube on the Pi for the upload-only 3D LUT
# AutoCal path (worker method=imported). The raw .cube text travels as the
# POST body — no JSON escaping, these files run to megabytes — and the
# filename rides the query string under the same strict whitelist as the
# download route. Validation here is light (LUT_3D_SIZE + node count); the
# worker re-parses strictly before building the LG payload.
sub webui_3d_lut_import (@) {
 my ($query,$body,$dir)=@_;
 $dir="/var/lib/PGenerator/lg/luts" if(!defined($dir) || $dir eq "");
 return '{"status":"error","message":".cube body required"}' if(!defined($body) || $body eq "");
 return '{"status":"error","message":".cube missing LUT_3D_SIZE"}' if($body!~/^\s*LUT_3D_SIZE\s+(\d+)\s*$/m);
 my $size=$1+0;
 return '{"status":"error","message":"Unsupported LUT_3D_SIZE"}' if($size < 2 || $size > 129);
 my $rows=0;
 $rows++ while($body=~/^\s*[-0-9.eE]+\s+[-0-9.eE]+\s+[-0-9.eE]+\s*$/mg);
 my $want=$size*$size*$size;
 return "{\"status\":\"error\",\"message\":\".cube node count $rows does not match LUT_3D_SIZE $size ($want)\"}" if($rows != $want);
 my $name="";
 $name=$1 if(defined($query) && $query=~/(?:^|&)name=([^&]{1,120})(?:&|$)/);
 $name=~s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
 $name=~s/\.cube\s*$//i;
 $name=~s/[^A-Za-z0-9._-]+/_/g;
 $name=~s/^[._]+//;
 $name="lut" if($name eq "");
 system("mkdir -p $dir 2>/dev/null");
 my $file="imported_".$name."_".time().".cube";
 my $path="$dir/$file";
 if(open(my $fh,'>',$path)) { print $fh $body; close($fh); chmod(0666,$path); }
 else { return '{"status":"error","message":"Unable to save imported .cube"}'; }
 return "{\"status\":\"ok\",\"file\":\"".&_webui_json_escape($file)."\",\"path\":\"".&_webui_json_escape($path)."\",\"size\":$size,\"nodes\":$rows}";
}

sub webui_lg_lut_list (@) {
 my ($dir)=@_;
 $dir="/var/lib/PGenerator/lg/luts" if(!defined($dir) || $dir eq "");
 my @out;
 if(opendir(my $dh,$dir)) {
  foreach my $f (sort readdir($dh)) {
   next unless($f=~/^[A-Za-z0-9._-]+\.cube$/);
   my @st=stat("$dir/$f");
   push @out,"{\"name\":\"".&_webui_json_escape($f)."\",\"size\":".(($st[7]||0)+0).",\"mtime\":".(($st[9]||0)+0)."}";
  }
  closedir($dh);
 }
 return "{\"status\":\"ok\",\"luts\":[".join(",",@out)."]}";
}

# ICC profile backend handlers are loaded from PGICCProfile.pm.

sub webui_lg_lut_download (@) {
 my ($dir,$query)=@_;
 $dir="/var/lib/PGenerator/lg/luts" if(!defined($dir) || $dir eq "");
 my $file="";
 $file=$1 if(defined($query) && $query=~/(?:^|&)file=([A-Za-z0-9._-]+\.cube)(?:&|$)/);
 return ("","") if($file eq "" || $file=~m{/} || $file=~/\.\./);
 my $path="$dir/$file";
 return ("","") unless(-f $path);
 my $data="";
 if(open(my $fh,"<",$path)) { local $/; $data=<$fh>; close($fh); }
 return ($file,$data);
}

# Delete a solved LUT from the history: the .cube plus its same-basename
# .bin/.json companions (export_lut always writes the triple together). The
# display keeps whatever payload was already uploaded — this only prunes the
# on-disk history. Same strict name whitelist as the download route.
sub webui_lg_lut_delete (@) {
 my ($dir,$body)=@_;
 $dir="/var/lib/PGenerator/lg/luts" if(!defined($dir) || $dir eq "");
 my $file="";
 $file=$1 if(defined($body) && $body=~/"file"\s*:\s*"([A-Za-z0-9._-]+\.cube)"/);
 return '{"status":"error","message":"Invalid LUT file name"}' if($file eq "" || $file=~m{/} || $file=~/\.\./);
 return '{"status":"error","message":"LUT file not found"}' unless(-f "$dir/$file");
 my $base=$file;
 $base=~s/\.cube$//;
 my $removed=0;
 foreach my $ext (qw(cube bin json)) {
  my $path="$dir/$base.$ext";
  $removed++ if(-f $path && unlink($path));
 }
 return "{\"status\":\"ok\",\"removed\":$removed}";
}

sub webui_meter_settings_load (@) {
 my ($query)=@_;
 my $omit_custom=(defined($query) && $query=~/(?:^|&)custom_series=0(?:&|$)/) ? 1 : 0;
 my $peak=$pgenerator_conf{"max_luma"};
 $peak=1000 if(!defined $peak || $peak eq "");
 my $min=$pgenerator_conf{"min_luma"};
 $min=0.005 if(!defined $min || $min eq "");
 my $delay_default_ms=1000;
 my $meter_target_gamma_auto="";
 my $meter_target_gamut_auto="";
 if(($pgenerator_conf{"dv_status"}||"0") eq "1") {
  my $dv_map_mode=$pgenerator_conf{"dv_map_mode"};
  $dv_map_mode="2" if(!defined $dv_map_mode || $dv_map_mode eq "");
  # DV Target Gamma defaults to ST 2084 (PQ target curve) for the chart/series
  # UI; the calibration solver pins 2.2 for relative (map mode 2) at run time.
  $meter_target_gamma_auto="st2084";
  $meter_target_gamut_auto="p3d65";
 }
 my $boot_id=&_webui_meter_settings_boot_id();
 my $custom_series_value="";
 if(-f $_custom_series_store && open(my $cs,"<",$_custom_series_store)) {
  local $/;
  $custom_series_value=<$cs>;
  close($cs);
  $custom_series_value="" unless($custom_series_value=~/^".*"\s*$/s);
 }
 # Current saves update the runtime and persistent files, not the historical
 # /tmp copy. Keep /tmp last so stale pre-migration settings cannot override
 # the durable copy after a daemon restart or OTA reboot.
 foreach my $path ($_meter_settings_runtime, $_meter_settings_persist, $_meter_settings_persist_legacy, $_meter_settings_file) {
  next unless(-f $path);
  my $json="";
  if(open(my $fh,"<",$path)) { local $/; $json=<$fh>; close($fh); }
  if($json ne "" && $json=~/^\{/) {
     my $had_embedded_custom=(index($json,'"custom_series_json"')>=0) ? 1 : 0;
     # One-time migration for installations that already persisted custom
     # series inside meter_settings.json before the independent store existed.
     if($custom_series_value eq "") {
      my $legacy_custom=_webui_json_str_value($json,"custom_series_json");
      if(defined($legacy_custom) && $legacy_custom ne ""
       && &_webui_meter_settings_write_json($_custom_series_store,$legacy_custom)) {
       $custom_series_value=$legacy_custom;
      }
     }
     # The independent store is authoritative. Strip any legacy embedded copy
     # after migration and before optionally appending it once, avoiding the
     # former 2x payload.
     $json=&_webui_json_without_str_key($json,"custom_series_json");
     # One-time compaction for settings files written before the independent
     # store became authoritative. Future settings and status requests no
     # longer have to read and scan a 7+ MB legacy copy.
     if($omit_custom && $had_embedded_custom) {
      &_webui_meter_settings_write_json($_meter_settings_runtime,$json);
      &_webui_meter_settings_write_json($_meter_settings_persist,$json);
     }
     my $delay_user_set=($json=~/"delay_user_set"\s*:\s*true/i) ? 1 : 0;
     my $delay_explicit=$delay_user_set ? 1 : 0;
     my $delay_value;
     my $has_delay=0;
     if($json=~/"delay"\s*:\s*"?(-?\d+(?:\.\d+)?)"?/) {
      $delay_value=$1+0;
      $has_delay=1;
     }
   $json=~s/,?\s*"hdr_master_peak"\s*:\s*"[^"]*"//g;
   $json=~s/,?\s*"hdr_master_min"\s*:\s*"[^"]*"//g;
   $json=~s/,?\s*"boot_id"\s*:\s*"[^"]*"//g;
     if(!$delay_explicit) {
      if(!$has_delay) {
       $json=~s/\{\s*/{"delay":"$delay_default_ms",/;
      } elsif(!defined($delay_value) || $delay_value <= 0 || abs($delay_value-500) < 0.0001 || abs($delay_value-0.5) < 0.0001) {
       $json=~s/"delay"\s*:\s*"?0+(?:\.0+)?"?/"delay":"$delay_default_ms"/g;
       $json=~s/"delay"\s*:\s*"?500(?:\.0+)?"?/"delay":"$delay_default_ms"/g;
       $json=~s/"delay"\s*:\s*"?0\.5(?:0+)?"?/"delay":"$delay_default_ms"/g;
      }
     }
     $json=~s/,?\s*"delay_explicit"\s*:\s*(?:true|false|null|"[^"]*"|-?\d+(?:\.\d+)?)//g;
     $json=~s/,?\s*"delay_user_set"\s*:\s*(?:true|false|null|"[^"]*"|-?\d+(?:\.\d+)?)//g;
     if($delay_user_set) {
      $json=~s/\{\s*/{"delay_user_set":true,"delay_explicit":true,/;
     }
  # Absolute is the baseline RGB-balance presentation. Perceptual remains an
  # explicit shadow-detail view and must only be restored when it was saved.
  if($json!~/"rgb_formula"\s*:/) {
   $json=~s/\{\s*/{"rgb_formula":"absolute",/;
  }
  if($meter_target_gamma_auto ne "") {
   # Only seed the DV target gamma as a first-run default when none is
   # stored. Do NOT overwrite an operator-chosen value — the dropdown is
   # selectable for DV (2.2 or ST 2084); the calibration solver still
   # pins the curve from the DV map mode at run time.
   if($json!~/"target_gamma"\s*:/) {
    $json=~s/\{\s*/{"target_gamma":"$meter_target_gamma_auto",/;
   }
  }
  if($meter_target_gamut_auto ne "") {
   if($json=~/"target_gamut"\s*:/) {
    $json=~s/"target_gamut"\s*:\s*"[^"]*"/"target_gamut":"$meter_target_gamut_auto"/g;
   } else {
    $json=~s/\{\s*/{"target_gamut":"$meter_target_gamut_auto",/;
   }
  }
   $json=~s/\{\s*,/\{/g;
   $json=~s/,\s*,/,/g;
   $json=~s/,\s*\}/}/g;
   $json=~s/\s*\}\s*$//;
   $json.="," if($json!~/\{\s*$/);
   $json.="\"hdr_master_peak\":\"$peak\",\"hdr_master_min\":\"$min\",\"boot_id\":\"$boot_id\"}";
   # Append the independent persistent store once for older clients. New
   # clients omit it here and use /api/meter/custom-series.
   if(!$omit_custom && $custom_series_value ne "") {
    $json=~s/\}\s*$//;
    $json.=',"custom_series_json":'.$custom_series_value.'}';
   }
   return $json;
  }
 }
   my @fallback_parts;
   push @fallback_parts, '"rgb_formula":"absolute"';
   push @fallback_parts, "\"target_gamut\":\"$meter_target_gamut_auto\"" if($meter_target_gamut_auto ne "");
   push @fallback_parts, "\"target_gamma\":\"$meter_target_gamma_auto\"" if($meter_target_gamma_auto ne "");
   push @fallback_parts, "\"hdr_master_peak\":\"$peak\"";
   push @fallback_parts, "\"hdr_master_min\":\"$min\"";
   push @fallback_parts, "\"boot_id\":\"$boot_id\"";
   push @fallback_parts, '"custom_series_json":'.$custom_series_value if(!$omit_custom && $custom_series_value ne "");
   return "{".join(",",@fallback_parts)."}";
}

###############################################
#         Custom CCSS API Functions           #
###############################################

sub _webui_json_escape (@) {
 my $s="".shift;
 $s=~s/\\/\\\\/g;
 $s=~s/"/\\"/g;
 $s=~s/\r/\\r/g;
 $s=~s/\n/\\n/g;
 $s=~s/\t/\\t/g;
 $s=~s/([\x00-\x08\x0b\x0c\x0e-\x1f\x7f])/sprintf("\\u%04x",ord($1))/ge;
 return $s;
}

sub _webui_system_backup_busy (@) {
 my $running=`pgrep -f '([s]potread|[m]eter_(session|series|lg_)|[i]cc_profile_builder|[c]olprof|[t]argen|[c]cxxmake_interactive|[c]css_create)' 2>/dev/null`;
 $running=~s/\s+//g;
 return $running ne "" ? 1 : 0;
}

sub _webui_system_backup_run (@) {
 my @args=@_;
 return ('{"status":"error","message":"System backup helper is unavailable"}',0) if(!-f $_system_backup_helper);
 my $output="";
 my $ok=0;
 if(open(my $pipe,"-|","sudo","/usr/bin/python3",$_system_backup_helper,@args)) {
  local $/;
  $output=<$pipe>;
  close($pipe);
  $ok=($? == 0) ? 1 : 0;
 }
 $output="" if(!defined($output));
 $output=~s/^\s+|\s+$//g;
 $output='{"status":"error","message":"System backup helper failed"}' if($output!~/^\{.*\}$/s);
 return ($output,$ok);
}

sub webui_system_backup_export (@) {
 return ("","","A calibration, meter read, or profile build is active") if(&_webui_system_backup_busy());
 my $stamp=`date -u +%Y%m%d-%H%M%S 2>/dev/null`;
 chomp($stamp);
 $stamp=time() if($stamp!~/^\d{8}-\d{6}$/);
 my $safe_version=$version||"unknown";
 $safe_version=~s/[^A-Za-z0-9._-]+/_/g;
 my $tmp="/tmp/pgenerator-system-backup-$$-$stamp.pgbackup";
 my ($result,$ok)=&_webui_system_backup_run("export","--output",$tmp,"--version",$safe_version);
 if(!$ok || !-f $tmp || (-s $tmp) <= 0) {
  unlink($tmp) if(-f $tmp);
  my $message="Could not create system backup";
  $message=$1 if($result=~/"message"\s*:\s*"([^"\\]*(?:\\.[^"\\]*)*)"/);
  return ("","",$message);
 }
 return ("PGenerator_plus_system_backup_v${safe_version}_${stamp}.pgbackup",$tmp,"");
}

sub webui_system_backup_import_chunk (@) {
 my ($body)=@_;
 return '{"status":"error","message":"Stop the active calibration, meter read, or profile build before importing"}' if(&_webui_system_backup_busy());
 my $upload_id="";
 $upload_id=$1 if($body=~/"upload_id"\s*:\s*"([A-Za-z0-9_-]{1,80})"/);
 my $filename="";
 $filename=$1 if($body=~/"filename"\s*:\s*"([^"\\]{1,240})"/);
 my $offset=-1;
 $offset=int($1) if($body=~/"offset"\s*:\s*(\d+)/);
 my $total_size=0;
 $total_size=int($1) if($body=~/"total_size"\s*:\s*(\d+)/);
 my $is_final=($body=~/"is_final"\s*:\s*true/i) ? 1 : 0;
 my $content_b64="";
 $content_b64=$1 if($body=~/"content"\s*:\s*"([A-Za-z0-9+\/=]+)"/);
 return '{"status":"error","message":"Backup upload metadata is incomplete"}' if($upload_id eq "" || $filename eq "" || $offset < 0 || $total_size <= 0 || $content_b64 eq "");
 return '{"status":"error","message":"Select a PGenerator+ .pgbackup file"}' if($filename!~/\.pgbackup$/i);
 return '{"status":"error","message":"System backup exceeds the 512 MB size limit"}' if($total_size > $_system_backup_max_bytes);
 mkdir($_system_backup_upload_dir,0700) if(!-d $_system_backup_upload_dir);
 return '{"status":"error","message":"Backup upload storage is unavailable"}' if(!-d $_system_backup_upload_dir);
 my $tmp="$_system_backup_upload_dir/$upload_id.pgbackup.part";
 unlink($tmp) if($offset == 0 && -f $tmp);
 my $current=(-f $tmp) ? (-s $tmp) : 0;
 return '{"status":"error","message":"Backup upload offset mismatch"}' if($current != $offset);
 my $raw=decode_base64($content_b64);
 return '{"status":"error","message":"Backup upload chunk is empty"}' if(length($raw) <= 0);
 if(open(my $fh,">>:raw",$tmp)) { print $fh $raw; close($fh); }
 else { return '{"status":"error","message":"Could not write backup upload"}'; }
 my $received=-s $tmp;
 if($received > $total_size || $received > $_system_backup_max_bytes) {
  unlink($tmp);
  return '{"status":"error","message":"Backup upload exceeds its declared size"}';
 }
 return '{"status":"ok","received":'.$received.',"total_size":'.$total_size.'}' if(!$is_final);
 if($received != $total_size) {
  unlink($tmp);
  return '{"status":"error","message":"Backup upload is incomplete"}';
 }
 my ($result,$ok)=&_webui_system_backup_run("import","--input",$tmp,"--version",$version||"unknown");
 unlink($tmp);
 return $result if($ok && $result=~/"status":"ok"/);
 return $result if($result=~/^\{/);
 return '{"status":"error","message":"System backup import failed"}';
}

my $_diag_video_sequence_root="$video_dir/.diagseq";
my $_DIAG_VIDEO_SEQUENCE_MAX_FRAMES=24;

sub _webui_diag_asset_sequence_key (@) {
 my $name=lc("".shift);
 $name=~s/[^a-z0-9_]+/_/g;
 $name=~s/_+/_/g;
 $name=~s/^_+//;
 $name=~s/_+$//;
 return $name eq "" ? "asset" : $name;
}

sub _webui_diag_asset_video_sequence_dir (@) {
 my $fname=shift;
 my $safe_name=&_webui_diag_asset_safe_filename($fname,"video");
 return "" if($safe_name eq "");
 return "$_diag_video_sequence_root/".&_webui_diag_asset_sequence_key($safe_name);
}

sub _webui_diag_asset_sequence_frame_count (@) {
 my $dir="".shift;
 my $count=0;
 return 0 if($dir eq "" || !-d $dir);
 if(opendir(my $dh,$dir)) {
  while(my $f=readdir($dh)) {
   next if($f !~ /\.(?:png|jpe?g|ppm)$/i);
   next if(!-f "$dir/$f");
   $count++;
  }
  closedir($dh);
 }
 return $count;
}

sub _webui_diag_asset_reset_dir (@) {
 my $dir="".shift;
 return 0 if($dir eq "" || $dir !~ /^\Q$_diag_video_sequence_root\E(?:\/|$)/);
 system("/bin/rm","-rf",$dir);
 return !-e $dir ? 1 : 0;
}

sub _webui_diag_asset_write_base64_file (@) {
 my ($path,$content_b64)=@_;
 return 0 if(!defined($path) || $path eq "" || !defined($content_b64) || $content_b64 eq "");
 my $raw=decode_base64($content_b64);
 return 0 if(length($raw) <= 0 || length($raw) > 8*1024*1024);
 my $dir=$path;
 $dir=~s{/[^/]+$}{};
 if($dir ne "" && !-d $dir) {
  system("/bin/mkdir","-p",$dir);
 }
 return 0 if($dir ne "" && !-d $dir);
 my $tmp="$path.tmp";
 if(open(my $fh,">",$tmp)) {
  binmode($fh);
  print $fh $raw;
  close($fh);
  return 1 if(rename($tmp,$path));
  unlink($tmp) if(-f $tmp);
 }
 return 0;
}

sub _webui_diag_asset_kind_info (@) {
 my $kind=lc(shift || "");
 return ("video",$video_dir,"custom_video",512*1024*1024) if($kind eq "video");
 return ("image",$pattern_images,"custom_image",64*1024*1024) if($kind eq "image");
 return ("","","",0);
}

sub _webui_diag_asset_extension_allowed (@) {
 my ($kind,$ext)=@_;
 $kind=lc($kind || "");
 $ext=lc($ext || "");
 return ($ext =~ /^\.(?:mp4|m4v|mov|webm|mkv|avi|hevc|h265|h264|ts|m2ts)$/) ? 1 : 0 if($kind eq "video");
 return ($ext =~ /^\.(?:png|jpe?g|bmp|ppm|gif)$/) ? 1 : 0 if($kind eq "image");
 return 0;
}

sub _webui_diag_asset_safe_filename (@) {
 my ($name,$kind)=@_;
 my ($resolved_kind,undef,$default_base)=&_webui_diag_asset_kind_info($kind);
 return "" if($resolved_kind eq "");
 $name="" if(!defined $name);
 $name=~s{\\}{/}g;
 $name=~s{^.*/}{};
 my $ext="";
 $ext=lc($1) if($name =~ /(\.[^.]{1,10})$/);
 $ext="" if(!_webui_diag_asset_extension_allowed($resolved_kind,$ext));
 $ext=".mp4" if($ext eq "" && $resolved_kind eq "video");
 $ext=".png" if($ext eq "" && $resolved_kind eq "image");
 my $base=$name;
 $base=~s/\.[^.]+$//;
 $base=~s/[^a-zA-Z0-9._\- ]//g;
 $base=~s/\s+/_/g;
 $base=~s/_+/_/g;
 $base=substr($base,0,80) if(length($base) > 80);
 $base=$default_base if($base eq "");
 return $base.$ext;
}

sub _webui_diag_asset_resolve_path (@) {
 my ($kind,$fname)=@_;
 my ($resolved_kind,$dir)=&_webui_diag_asset_kind_info($kind);
 return ("","") if($resolved_kind eq "" || $dir eq "");
 my $safe_name=&_webui_diag_asset_safe_filename($fname,$resolved_kind);
 return ("","") if($safe_name eq "");
 my $path="$dir/$safe_name";
 return ("","") if(!-f $path);
 return ($safe_name,$path);
}

sub webui_diag_asset_list (@) {
 my ($kind)=@_;
 my ($resolved_kind,$dir)=&_webui_diag_asset_kind_info($kind);
 return '{"files":[]}' if($resolved_kind eq "" || $dir eq "" || !-d $dir);
 my @out;
 if(opendir(my $dh,$dir)) {
  while(my $f=readdir($dh)) {
   next if($f =~ /^\./);
   next if(!-f "$dir/$f");
   next if(!_webui_diag_asset_extension_allowed($resolved_kind,($f =~ /(\.[^.]+)$/ ? $1 : "")));
   push @out, '"'.&_webui_json_escape($f).'"';
  }
  closedir($dh);
 }
 @out=sort { lc($a) cmp lc($b) } @out;
 return '{"files":['.join(',',@out).']}';
}

sub webui_diag_asset_upload (@) {
 my ($body)=@_;
 my $kind="";
 $kind=lc($1) if($body =~ /"kind"\s*:\s*"(video|image)"/i);
 my ($resolved_kind,$dir,undef,$max_size)=&_webui_diag_asset_kind_info($kind);
 return '{"status":"error","message":"Invalid asset type"}' if($resolved_kind eq "" || $dir eq "");

 my $upload_id="";
 $upload_id=$1 if($body =~ /"upload_id"\s*:\s*"([A-Za-z0-9_-]{1,80})"/);
 my $orig_filename="";
 $orig_filename=$1 if($body =~ /"filename"\s*:\s*"([^"]{1,240})"/);
 my $content_b64="";
 $content_b64=$1 if($body =~ /"content"\s*:\s*"([^"]+)"/);
 my $offset=-1;
 $offset=$1 if($body =~ /"offset"\s*:\s*(\d+)/);
 my $total_size=0;
 $total_size=$1 if($body =~ /"total_size"\s*:\s*(\d+)/);
 my $is_final=0;
 $is_final=1 if($body =~ /"is_final"\s*:\s*true/i);

 return '{"status":"error","message":"Upload metadata required"}' if($upload_id eq "" || $orig_filename eq "" || $content_b64 eq "" || $offset < 0 || $total_size <= 0);
 return '{"status":"error","message":"File exceeds size limit"}' if($total_size > $max_size);

 my $safe_name=&_webui_diag_asset_safe_filename($orig_filename,$resolved_kind);
 return '{"status":"error","message":"Unsupported file type"}' if($safe_name eq "");

 if(!-d $dir) {
  system("mkdir -p '$dir' >/dev/null 2>&1");
 }
 return '{"status":"error","message":"Diagnostic storage unavailable"}' if(!-d $dir);
 my $tmp_path="$dir/.WEBUI_DIAG_".$resolved_kind."_".$upload_id.".part";
 unlink($tmp_path) if($offset == 0 && -f $tmp_path);
 my $current_size=(-f $tmp_path) ? (-s $tmp_path) : 0;
 return '{"status":"error","message":"Upload offset mismatch"}' if($current_size != $offset);
 $content_b64 =~ s/.*;base64,//;
 &upload_file($safe_name,$tmp_path,$content_b64);
 my $written=(-f $tmp_path) ? (-s $tmp_path) : 0;
 return '{"status":"error","message":"Upload failed"}' if($written <= 0);
 return '{"status":"error","message":"Uploaded data exceeds size limit"}' if($written > $max_size);

 if(!$is_final) {
  return '{"status":"ok","received":'.$written.',"filename":"'.&_webui_json_escape($safe_name).'"}';
 }

 return '{"status":"error","message":"Upload incomplete"}' if($written != $total_size);
 my $dest_path="$dir/$safe_name";
 unlink($dest_path) if(-f $dest_path);
 if(!rename($tmp_path,$dest_path)) {
  unlink($tmp_path);
  return '{"status":"error","message":"Failed to save upload"}';
 }
 if($resolved_kind eq "video") {
  my $seq_dir=&_webui_diag_asset_video_sequence_dir($safe_name);
  &_webui_diag_asset_reset_dir($seq_dir) if($seq_dir ne "");
 }
 &log("WebUI: custom diagnostic $resolved_kind uploaded: $safe_name");
 return '{"status":"ok","filename":"'.&_webui_json_escape($safe_name).'","message":"Uploaded '.($resolved_kind eq "video" ? 'diagnostic video' : 'diagnostic image').'"}';
}

sub webui_diag_video_sequence_upload (@) {
 my ($body)=@_;
 my $upload_id="";
 $upload_id=$1 if($body =~ /"upload_id"\s*:\s*"([A-Za-z0-9_-]{1,80})"/);
 my $video_filename="";
 $video_filename=$1 if($body =~ /"video_filename"\s*:\s*"([^"]{1,240})"/);
 my $content_b64="";
 $content_b64=$1 if($body =~ /"content"\s*:\s*"([^"]+)"/);
 my $frame_index=-1;
 $frame_index=$1 if($body =~ /"frame_index"\s*:\s*(\d+)/);
 my $frame_total=0;
 $frame_total=$1 if($body =~ /"frame_total"\s*:\s*(\d+)/);
 return '{"status":"error","message":"Sequence upload metadata required"}' if($upload_id eq "" || $video_filename eq "" || $content_b64 eq "" || $frame_index < 0 || $frame_total <= 0);
 return '{"status":"error","message":"Too many sequence frames"}' if($frame_total > $_DIAG_VIDEO_SEQUENCE_MAX_FRAMES);
 return '{"status":"error","message":"Sequence frame index out of range"}' if($frame_index >= $frame_total);
 my ($safe_name,undef)=&_webui_diag_asset_resolve_path("video",$video_filename);
 return '{"status":"error","message":"Diagnostic video not found"}' if($safe_name eq "");
 my $seq_dir=&_webui_diag_asset_video_sequence_dir($safe_name);
 return '{"status":"error","message":"Sequence storage unavailable"}' if($seq_dir eq "");
 my $tmp_dir=$seq_dir.".upload_".$upload_id;
 if($frame_index == 0) {
  &_webui_diag_asset_reset_dir($tmp_dir);
 }
 system("/bin/mkdir","-p",$_diag_video_sequence_root);
 system("/bin/mkdir","-p",$tmp_dir);
 return '{"status":"error","message":"Sequence storage unavailable"}' if(!-d $tmp_dir);
 my $existing=&_webui_diag_asset_sequence_frame_count($tmp_dir);
 return '{"status":"error","message":"Sequence frame order mismatch"}' if($existing != $frame_index);
 my $frame_name=sprintf("f%03d.png",$frame_index+1);
 return '{"status":"error","message":"Failed to store sequence frame"}' if(!&_webui_diag_asset_write_base64_file("$tmp_dir/$frame_name",$content_b64));
 my $received=$frame_index+1;
 if($received < $frame_total) {
  return '{"status":"ok","received":'.$received.',"frame_total":'.$frame_total.',"filename":"'.&_webui_json_escape($safe_name).'"}';
 }
 return '{"status":"error","message":"Sequence upload incomplete"}' if(&_webui_diag_asset_sequence_frame_count($tmp_dir) != $frame_total);
 &_webui_diag_asset_reset_dir($seq_dir);
 if(!rename($tmp_dir,$seq_dir)) {
  &_webui_diag_asset_reset_dir($tmp_dir);
  return '{"status":"error","message":"Failed to finalize video sequence"}';
 }
  &log("WebUI: diagnostic video sequence uploaded: $safe_name ($frame_total frames)");
  return '{"status":"ok","filename":"'.&_webui_json_escape($safe_name).'","frame_total":'.$frame_total.',"message":"Prepared diagnostic video renderer sequence"}';
}

sub webui_diag_asset_delete (@) {
 my ($body)=@_;
 my $kind="";
 $kind=lc($1) if($body =~ /"kind"\s*:\s*"(video|image)"/i);
 my $fname="";
 $fname=$1 if($body =~ /"filename"\s*:\s*"([^"]{1,240})"/);
 my ($resolved_kind,$dir)=&_webui_diag_asset_kind_info($kind);
 return '{"status":"error","message":"Invalid asset type"}' if($resolved_kind eq "" || $dir eq "");
 my $safe_name=&_webui_diag_asset_safe_filename($fname,$resolved_kind);
 return '{"status":"error","message":"Invalid filename"}' if($safe_name eq "");
 my $path="$dir/$safe_name";
 return '{"status":"error","message":"File not found"}' if(!-f $path);
 my $deleted=unlink($path) ? 1 : 0;
 if($resolved_kind eq "video") {
  my $seq_dir=&_webui_diag_asset_video_sequence_dir($safe_name);
  &_webui_diag_asset_reset_dir($seq_dir) if($seq_dir ne "");
 }
 return '{"status":"error","message":"Delete failed"}' if(!$deleted);
 &log("WebUI: custom diagnostic $resolved_kind deleted: $safe_name");
 return '{"status":"ok","filename":"'.&_webui_json_escape($safe_name).'"}';
}

sub _webui_ccss_meta (@) {
 my ($path)=@_;
 my %meta=(display=>"",technology=>"",instrument=>"",reference=>"",format=>($path=~/\.ccmx$/i ? "ccmx" : "ccss"));
 return \%meta if(!$path || !-f $path);
 if(open(my $fh,"<",$path)) {
  local $/="\n";
  my $count=0;
  while(my $line=<$fh>) {
   $count++;
   last if($count>80);
   last if($line=~/^(?:BEGIN_DATA_FORMAT|BEGIN_DATA)\b/);
   chomp($line);
   $meta{display}=$1 if(!$meta{display} && $line=~/^DISPLAY\s+"([^"]*)"/i);
   $meta{technology}=$1 if(!$meta{technology} && $line=~/^TECHNOLOGY\s+"([^"]*)"/i);
   $meta{instrument}=$1 if(!$meta{instrument} && $line=~/^INSTRUMENT\s+"([^"]*)"/i);
   $meta{reference}=$1 if(!$meta{reference} && $line=~/^REFERENCE\s+"([^"]*)"/i);
  }
  close($fh);
 }
 return \%meta;
}

sub _webui_ccss_ccxxmake_disptech (@) {
 my ($display_type_key)=@_;
 $display_type_key="" if(!defined($display_type_key));
 $display_type_key=lc($display_type_key);
 return $_ccxxmake_disptech_map->{$display_type_key} || "";
}

sub _webui_ccmx_base_yflag (@) {
 my ($display_type_key)=@_;
 $display_type_key=lc($display_type_key||"");
 return "c" if($display_type_key=~/^(?:refresh|plasma|crt)$/);
 return "p" if($display_type_key=~/^projector/);
 return "l";
}

# ArgyllCMS exposes reconstructed high-resolution spectral sampling for the
# i1Pro family and the ColorMunki spectro family. Keep this allow-list aligned
# with the instrument drivers rather than enabling -H for every spectro.
sub _webui_meter_supports_highres (@) {
 my ($meter)=@_;
 return 0 if(ref($meter) ne "HASH" || lc($meter->{meter_type}||"") ne "spectro");
 my $usb_id=lc($meter->{usb_id}||"");
 return 1 if($usb_id=~/^(?:0971:2000|0971:2007|0765:6008|0765:6009)$/);
 my $name=lc($meter->{name}||"");
 return 0 if($name=~/(?:colormunki|colorchecker|i1)\s*display|display\s*(?:pro|plus|studio)/);
 return 1 if($name=~/(?:eye[- ]?one|i1)\s*pro(?:\s*(?:2|3|3\s*plus))?/);
 return 1 if($name=~/(?:efi\s*es[- ]?(?:1000|2000|3000)|colormunki(?:\s*(?:photo|design))?|i1\s*studio|colorchecker\s*studio)/);
 return 0;
}

sub _webui_ccss_from_ti3 (@) {
 my ($raw,$profile_name,$display_type_key)=@_;
 my $ccxxmake_bin="/usr/bin/ccxxmake";
 return (0,"ccxxmake is not installed on this image","") if(!-x $ccxxmake_bin);

 my $disptech=&_webui_ccss_ccxxmake_disptech($display_type_key);
 return (0,"Choose a concrete display type before importing a TI3 file","") if($disptech eq "");

 my $tmp_root="/tmp/pg_ccss_make_$$"."_".time();
 my $in_path="$tmp_root/input.ti3";
 my $out_path="$tmp_root/output.ccss";
 my $log_path="$tmp_root/ccxxmake.log";

 if(!mkdir($tmp_root,0700)) {
  return (0,"Failed to create temporary workspace","");
 }

 my $ok=0;
 my $message="Unknown ccxxmake failure";
 my $content="";

 eval {
  open(my $in_fh,">:raw",$in_path) or die "write input failed";
  print $in_fh $raw;
  close($in_fh);

  my $cmd="$ccxxmake_bin -S -t $disptech -f '$in_path' '$out_path' >'$log_path' 2>&1";
  my $rc=system($cmd);
  my $log="";
  if(open(my $log_fh,"<:raw",$log_path)) {
   local $/;
   $log=<$log_fh>;
   close($log_fh);
  }

  if($rc != 0 || !-f $out_path) {
   $log=~s/\r/ /g;
   $log=~s/\n+/ /g;
   $log=~s/\s+/ /g;
   $log=~s/^\s+|\s+$//g;
   $message=$log ne "" ? $log : "ccxxmake failed to build a CCSS from the TI3 file";
   die "ccxxmake failed";
  }

  open(my $out_fh,"<:raw",$out_path) or die "read output failed";
  local $/;
  $content=<$out_fh>;
  close($out_fh);
  $ok=1;
  $message="TI3 converted to CCSS";
 };

 my @cleanup=($in_path,$out_path,$log_path);
 unlink(@cleanup);
 rmdir($tmp_root);

 return ($ok,$message,$content);
 }

 sub _webui_ccss_from_edr (@) {
  my ($raw,$profile_name,$orig_filename)=@_;

  # Argyll EDR DATA1 container. This is the format produced by Argyll's
  # ccxxmake/ccss2edr and by this WebUI's own EDR export, and it is also the
  # on-disk container used by genuine X-Rite i1d3 .edr corrections. Layout is
  # reverse-engineered from Argyll's parse_EDR() in spectro/oemarch.c.
  if(length($raw)>=600 && substr($raw,0,9) eq "EDR DATA1") {
   return &_webui_ccss_from_edr_argyll($raw,$profile_name,$orig_filename);
  }

  # Anything else (X-Rite setup.exe / .dll / .cab archives wrapping EDR data)
  # is handled by oeminst, which can crack those containers.
  return &_webui_ccss_from_edr_oeminst($raw,$profile_name);
 }

 sub _webui_ccss_from_edr_argyll (@) {
  my ($raw,$profile_name,$orig_filename)=@_;
  $profile_name="" if(!defined($profile_name));
  $orig_filename="" if(!defined($orig_filename));

  my $len=length($raw);
  if($len<600 || substr($raw,0,9) ne "EDR DATA1") {
   return (0,"Not an Argyll EDR DATA1 file","");
  }

  my $nsets=unpack("L<",substr($raw,0x164,4));
  my $nmstart=unpack("d<",substr($raw,0x230,8));
  my $nmend=unpack("d<",substr($raw,0x238,8));
  my $nmspace=unpack("d<",substr($raw,0x240,8));

  if($nsets<3 || $nsets>100) {
   return (0,"EDR has invalid data set count ($nsets)","");
  }
  if($nmspace<=0 || $nmend<=$nmstart) {
   return (0,"EDR has invalid wavelength range","");
  }
  my $spec_n=int(1.0+($nmend-$nmstart)/$nmspace+0.5);
  if($spec_n<10 || $spec_n>2000) {
   return (0,"EDR has invalid band count ($spec_n)","");
  }

  my $has_white=($nsets>=4)?1:0;
  my @sets;
  my $off=600;
  for my $set (0..$nsets-1) {
   last if($off+128+28+8*$spec_n>$len);
   if(substr($raw,$off,12) ne "DISPLAY DATA") {
    return (0,"EDR set $set missing DISPLAY DATA header","");
   }
   $off+=128;
   if(substr($raw,$off,13) ne "SPECTRAL DATA") {
    return (0,"EDR set $set missing SPECTRAL DATA header","");
   }
   my $nsamples=unpack("L<",substr($raw,$off+0x10,4));
   if($nsamples!=$spec_n) {
    return (0,"EDR set $set band count $nsamples != $spec_n","");
   }
   $off+=28;
   my @vals;
   for my $j (0..$spec_n-1) {
    push @vals,(unpack("d<",substr($raw,$off+8*$j,8))*1000.0);
   }
   $off+=8*$spec_n;
   push @sets,\@vals;
  }

  if(scalar(@sets)<3) {
   return (0,"EDR did not contain enough spectral sets","");
  }

  # Optional CORRECTION DATA section (present in genuine X-Rite i1d3 EDRs;
  # absent from Argyll ccss2edr files such as those shared on calibration
  # forums). When present, Argyll multiplies each spectral sample by the
  # interpolated correction curve (parse_EDR in spectro/oemarch.c).
  if($off+92<=$len && substr($raw,$off,15) eq "CORRECTION DATA") {
   my $cns=unpack("L<",substr($raw,$off+0x50,4));
   if(($cns==351 || $cns==401) && $off+92+8*$cns<=$len) {
    my $cstart=380.0;
    my $cend=($cns==401)?780.0:730.0;
    my $coff=$off+92;
    my @cor;
    for my $j (0..$cns-1) {
     push @cor,unpack("d<",substr($raw,$coff+8*$j,8));
    }
    my $den=($spec_n>1)?$spec_n-1:1;
    for my $s (@sets) {
     for my $j (0..$spec_n-1) {
      my $wl=$nmstart+($j*($nmend-$nmstart)/$den);
      my $cv;
      if($wl<=$cstart) { $cv=$cor[0]; }
      elsif($wl>=$cend) { $cv=$cor[-1]; }
      else {
       my $t=($wl-$cstart)/($cend-$cstart)*($cns-1);
       my $i=int($t);
       my $f=$t-$i;
       $i=$cns-2 if($i>$cns-2);
       $cv=$cor[$i]+$f*($cor[$i+1]-$cor[$i]);
      }
      $s->[$j]*=$cv;
     }
    }
    $off=$coff+8*$cns;
   }
  }

  # Build the per-wavelength data structure used by the shared CCSS builder.
  my @data;
  for my $j (0..$spec_n-1) {
   my $wl=$nmstart+($j*($nmend-$nmstart)/($spec_n>1?$spec_n-1:1));
   my %pt=(wl=>$wl,r=>$sets[0]->[$j],g=>$sets[1]->[$j],b=>$sets[2]->[$j]);
   $pt{w}=$sets[3]->[$j] if($has_white);
   push @data,\%pt;
  }

  my $ccss_content=&_webui_csv_data_to_ccss(\@data,$profile_name,$orig_filename,$has_white);
  if(!$ccss_content) {
   return (0,"Failed to build CCSS from EDR spectral data","");
  }
  return (1,"EDR converted to CCSS",$ccss_content);
 }

 sub _webui_ccss_from_edr_oeminst (@) {
  my ($raw,$profile_name)=@_;
  my $oeminst_bin="/usr/bin/oeminst";
  return (0,"oeminst is not installed on this image","") if(!-x $oeminst_bin);

  my $tmp_root="/tmp/pg_ccss_edr_$$"."_".time();
  my $in_path="$tmp_root/input.edr";
  my $log_path="$tmp_root/oeminst.log";

  if(!mkdir($tmp_root,0700)) {
   return (0,"Failed to create temporary workspace","");
  }

  my $ok=0;
  my $message="Unknown oeminst failure";
  my $content="";

  eval {
   open(my $in_fh,">:raw",$in_path) or die "write input failed";
   print $in_fh $raw;
   close($in_fh);

   # oeminst -c reads the EDR and writes the translated .ccss to the cwd.
   # /usr/ref does not exist on this image, so no stock reference profiles
   # are emitted alongside the converted file.
   my $cmd="cd '$tmp_root' && $oeminst_bin -c '$in_path' >'$log_path' 2>&1";
   my $rc=system($cmd);

   my @ccss=sort { -M $a <=> -M $b } glob("$tmp_root/*.ccss");
   my $log="";
   if(open(my $log_fh,"<:raw",$log_path)) {
    local $/;
    $log=<$log_fh>;
    close($log_fh);
   }

   if($rc != 0 || !@ccss) {
    $log=~s/\r/ /g;
    $log=~s/\n+/ /g;
    $log=~s/\s+/ /g;
    $log=~s/^\s+|\s+$//g;
    $message=$log ne "" ? $log : "oeminst failed to convert the EDR file";
    die "oeminst failed";
   }

   open(my $out_fh,"<:raw",$ccss[0]) or die "read output failed";
   local $/;
   $content=<$out_fh>;
   close($out_fh);
   $ok=1;
   $message="EDR converted to CCSS";
  };

  unlink(glob("$tmp_root/*"));
  rmdir($tmp_root);

  return ($ok,$message,$content);
 }

 sub _webui_ccss_resolve_named_path (@) {
 my ($fname,$source)=@_;
 $fname="" if(!defined($fname));
 $source=lc(defined($source) ? $source : "");
 $fname=~s{\\}{/}g;
 $fname=~s{^.*/}{};
 $fname=~s/[^a-zA-Z0-9._\-()\[\] ]//g;
 return ("","","") if($fname eq "" || $fname=~/\.\./);

 my @candidates;
 if($source eq "custom") {
  @candidates=([$_custom_ccss_dir,"custom"],[$_custom_ccss_legacy_dir,"custom"]);
 } elsif($source eq "system") {
  @candidates=([$_ccss_dir,"system"]);
 } else {
  @candidates=([$_ccss_dir,"system"],[$_custom_ccss_dir,"custom"],[$_custom_ccss_legacy_dir,"custom"]);
 }

 foreach my $candidate (@candidates) {
  my ($base,$resolved_source)=@$candidate;
  my $path="$base/$fname";
  next unless(-f $path);
  &_webui_ccss_repair_file($path) if($resolved_source eq "custom" && $path=~/\.ccss$/i);
  return ($path,$resolved_source,$fname);
 }
 return ("","",$fname);
}

sub webui_ccss_list (@) {
 my @files;
 my %seen;
 foreach my $dir ($_custom_ccss_dir,$_custom_ccss_legacy_dir) {
  next unless(-d $dir && opendir(my $dh, $dir));
  while(my $f=readdir($dh)) {
   next unless($f=~/\.(?:ccss|ccmx)$/i);
   next if($seen{lc $f}++);
   push @files, "\"$f\"";
  }
  closedir($dh);
 }
 return '{"files":['.join(",",sort @files).']}';
}

sub webui_ccss_all (@) {
 # Returns combined list of system CCSS plus custom CCSS/CCMX profiles.
 my @out;
 my %seen;
 # System dir (excluding the 'custom' subdir)
 if(-d $_ccss_dir && opendir(my $dh, $_ccss_dir)) {
  while(my $f=readdir($dh)) {
   next unless($f=~/\.(?:ccss|ccmx)$/i);
   next if($seen{lc $f}++);
   my $meta=&_webui_ccss_meta("$_ccss_dir/$f");
   my $e=&_webui_json_escape($f);
   my $d=&_webui_json_escape($meta->{display});
   my $t=&_webui_json_escape($meta->{technology});
   my $i=&_webui_json_escape($meta->{instrument});
   my $r=&_webui_json_escape($meta->{reference});
   my $format=$meta->{format} eq "ccmx" ? "ccmx" : "ccss";
   push @out, [lc $f, "{\"name\":\"$e\",\"source\":\"system\",\"format\":\"$format\",\"display\":\"$d\",\"technology\":\"$t\",\"instrument\":\"$i\",\"reference\":\"$r\"}"];
  }
  closedir($dh);
 }
 foreach my $dir ($_custom_ccss_dir,$_custom_ccss_legacy_dir) {
  next unless(-d $dir && opendir(my $dh, $dir));
  while(my $f=readdir($dh)) {
   next unless($f=~/\.(?:ccss|ccmx)$/i);
   next if($seen{lc $f}++);
   my $meta=&_webui_ccss_meta("$dir/$f");
   my $e=&_webui_json_escape($f);
   my $d=&_webui_json_escape($meta->{display});
   my $t=&_webui_json_escape($meta->{technology});
   my $i=&_webui_json_escape($meta->{instrument});
   my $r=&_webui_json_escape($meta->{reference});
   my $format=$meta->{format} eq "ccmx" ? "ccmx" : "ccss";
   push @out, [lc $f, "{\"name\":\"$e\",\"source\":\"custom\",\"format\":\"$format\",\"display\":\"$d\",\"technology\":\"$t\",\"instrument\":\"$i\",\"reference\":\"$r\"}"];
  }
  closedir($dh);
 }
 my @sorted=map { $_->[1] } sort { $a->[0] cmp $b->[0] } @out;
 return '{"files":['.join(",",@sorted).']}';
}

sub _webui_ensure_custom_storage_dir (@) {
 my ($dir)=@_;
 return 0 if(!defined($dir) || $dir eq "");
 return 1 if(-d $dir && -w $dir);
 if(!-d $dir) {
  my $safe_dir=$dir;
  $safe_dir=~s/'/'"'"'/g;
  system("/bin/mkdir -p '$safe_dir' >/dev/null 2>&1");
 }
 if((!-d $dir || !-w $dir) && defined($pg_cmd_env) && $pg_cmd_env ne "" && defined($sudo_cmd) && $sudo_cmd ne "") {
  my @args_b64=map { encode_base64($_,"") } ("ENSURE_CCSS_STORAGE",$dir);
  system("timeout 5 env $pg_cmd_env=\"@args_b64\" $sudo_cmd >/dev/null 2>&1");
 }
 return (-d $dir && -w $dir) ? 1 : 0;
}

sub _webui_custom_ccss_storage_dir (@) {
 foreach my $dir ($_custom_ccss_dir,$_custom_ccss_legacy_dir) {
  if(&_webui_ensure_custom_storage_dir($dir)) {
   return $dir;
  }
 }
 &log("WebUI: custom CCSS storage unavailable (tried $_custom_ccss_dir and $_custom_ccss_legacy_dir)");
 return "";
}

sub _webui_ccmx_validate_content (@) {
 my ($raw)=@_;
 return (0,"Not a CCMX file") if(!defined($raw) || $raw!~/\ACCMX[ \t]*(?:\r?\n|$)/i);
 return (0,"Invalid CCMX file: missing instrument") if($raw!~/^INSTRUMENT\s+"[^"]+"/mi);
 return (0,"Invalid CCMX file: COLOR_REP must be XYZ") if($raw!~/^COLOR_REP\s+"?XYZ"?[ \t]*$/mi);
 return (0,"Invalid CCMX file: expected a 3 by 3 matrix") if($raw!~/^NUMBER_OF_FIELDS\s+3[ \t]*$/mi || $raw!~/^NUMBER_OF_SETS\s+3[ \t]*$/mi);
 return (0,"Invalid CCMX file: missing XYZ data format") if($raw!~/^BEGIN_DATA_FORMAT[ \t]*\r?\n\s*XYZ_X\s+XYZ_Y\s+XYZ_Z\s*\r?\nEND_DATA_FORMAT[ \t]*$/mi);
 my ($data)=$raw=~/^BEGIN_DATA[ \t]*\r?\n(.*?)^END_DATA[ \t]*$/mis;
 return (0,"Invalid CCMX file: missing matrix data") if(!defined($data));
 my @rows=grep { $_!~/^\s*$/ } split(/\r?\n/,$data);
 return (0,"Invalid CCMX file: expected exactly three matrix rows") if(@rows != 3);
 foreach my $row (@rows) {
  my @values=grep { $_ ne "" } split(/\s+/,$row);
  return (0,"Invalid CCMX file: each matrix row must contain three numbers") if(@values != 3);
  foreach my $value (@values) {
   return (0,"Invalid CCMX file: non-numeric matrix value") if($value!~/^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/);
  }
 }
 return (1,"");
}

sub webui_ccss_upload (@) {
 my ($body)=@_;
 # Expect JSON: { name: "...", content: "base64...", filename: "...", display_type: "..." }
 my $name="";
 $name=$1 if($body=~/"name"\s*:\s*"([^"]{1,80})"/);
 my $content_b64="";
 $content_b64=$1 if($body=~/"content"\s*:\s*"([^"]+)"/);
 my $orig_filename="";
 $orig_filename=$1 if($body=~/"filename"\s*:\s*"([^"]{1,200})"/);
 my $display_type_key="";
 $display_type_key=$1 if($body=~/"display_type"\s*:\s*"([^"]{1,80})"/);

 if($name eq "" || $content_b64 eq "") {
  return '{"status":"error","message":"Name and file content required"}';
 }

 my $raw=decode_base64($content_b64);
 if(length($raw) < 10 || length($raw) > 5*1024*1024) {
  return '{"status":"error","message":"Invalid file size"}';
 }

 # Prefer the persistent runtime location, but fall back to the legacy custom
 # folder when upgrading older images that already had it prepared.
 my $custom_storage_dir=&_webui_custom_ccss_storage_dir();
 if($custom_storage_dir eq "") {
  return '{"status":"error","message":"Custom storage unavailable"}';
 }

 # A CCMX is already the finished, instrument-specific 3x3 correction. It
 # cannot be synthesized from a CCSS alone because the target colorimeter's
 # measurements are required.
 if($raw=~/\ACCMX[ \t]*(?:\r?\n|$)/i || $orig_filename=~/\.ccmx$/i) {
  my ($valid,$error)=&_webui_ccmx_validate_content($raw);
  return '{"status":"error","message":"'.&_webui_json_escape($error).'"}' if(!$valid);
  my $safe_name=&_webui_ccss_safe_filename($name,"ccmx");
  my $out_path="$custom_storage_dir/$safe_name";
  if(open(my $fh,">:raw",$out_path)) {
   print $fh $raw;
   close($fh);
   &log("WebUI: custom CCMX uploaded: $safe_name");
   return "{\"status\":\"ok\",\"filename\":\"$safe_name\",\"format\":\"ccmx\",\"message\":\"CCMX profile saved\"}";
  }
  return '{"status":"error","message":"Failed to write CCMX file"}';
 }

 # Remaining imports produce or contain CCSS data.
 my $safe_name=&_webui_ccss_safe_filename($name,"ccss");

 # Detect file type: CCSS, TI3, or CSV.
 if($raw=~/^CCSS\s/) {
  # Already a CCSS file — validate basic structure
  if($raw!~/BEGIN_DATA/ || $raw!~/END_DATA/) {
   return '{"status":"error","message":"Invalid CCSS file: missing data section"}';
  }
  $raw=&_webui_ccss_normalize_keywords($raw);
  my $out_path="$custom_storage_dir/$safe_name";
  if(open(my $fh,">:raw",$out_path)) {
   print $fh $raw;
   close($fh);
   &_webui_ccss_repair_file($out_path);
   &log("WebUI: custom CCSS uploaded: $safe_name");
   return "{\"status\":\"ok\",\"filename\":\"$safe_name\",\"message\":\"CCSS profile saved\"}";
  }
  return '{"status":"error","message":"Failed to write file"}';
 }

 if($raw=~/(?:^|\n)TARGET_INSTRUMENT\s+"[^"]+"/ && $raw=~/(?:^|\n)SPECTRAL_BANDS\s+"?[0-9]+"?/ && $raw=~/(?:^|\n)BEGIN_DATA_FORMAT(?:\n|\r\n)/) {
  my ($ok,$message,$ccss_content)=&_webui_ccss_from_ti3($raw,$name,$display_type_key);
  if(!$ok) {
   $message=&_webui_json_escape($message);
   return "{\"status\":\"error\",\"message\":\"$message\"}";
  }
  my $out_path="$custom_storage_dir/$safe_name";
  if(open(my $fh,">",$out_path)) {
   print $fh &_webui_ccss_normalize_keywords($ccss_content);
   close($fh);
   &_webui_ccss_repair_file($out_path);
   &log("WebUI: custom CCSS converted from TI3: $safe_name");
   return "{\"status\":\"ok\",\"filename\":\"$safe_name\",\"message\":\"TI3 converted to CCSS\"}";
  }
  return '{"status":"error","message":"Failed to write converted CCSS file"}';
 }

 # EDR (binary X-Rite/i1Display correction) — convert via oeminst.
 # CCSS/TI3 are text and handled above; any remaining binary payload is an EDR.
 if($orig_filename=~/\.edr$/i || $raw=~ /\x00/) {
  my ($ok,$message,$ccss_content)=&_webui_ccss_from_edr($raw,$name,$orig_filename);
  if(!$ok) {
   $message=&_webui_json_escape($message);
   return "{\"status\":\"error\",\"message\":\"$message\"}";
  }
  my $out_path="$custom_storage_dir/$safe_name";
  if(open(my $fh,">",$out_path)) {
   print $fh &_webui_ccss_normalize_keywords($ccss_content);
   close($fh);
   &_webui_ccss_repair_file($out_path);
   &log("WebUI: custom CCSS converted from EDR: $safe_name");
   return "{\"status\":\"ok\",\"filename\":\"$safe_name\",\"message\":\"EDR converted to CCSS\"}";
  }
  return '{"status":"error","message":"Failed to write converted CCSS file"}';
 }

 # Assume CSV — try to convert
 my $ccss_content=&csv_to_ccss($raw,$name,$orig_filename);
 if(!$ccss_content) {
   return '{"status":"error","message":"Failed to parse upload. Supported formats: CCSS, EDR, TI3, CSV with wavelength,R,G,B,W columns, or raw 3/4-row spectral CSV (380-780nm)"}';
 }

 my $out_path="$custom_storage_dir/$safe_name";
 if(open(my $fh,">",$out_path)) {
  print $fh &_webui_ccss_normalize_keywords($ccss_content);
  close($fh);
  &_webui_ccss_repair_file($out_path);
  &log("WebUI: custom CCSS converted from CSV: $safe_name");
  return "{\"status\":\"ok\",\"filename\":\"$safe_name\",\"message\":\"CSV converted to CCSS\"}";
 }
 return '{"status":"error","message":"Failed to write file"}';
}

sub _webui_ccss_create_write_state (@) {
 my ($json)=@_;
 $json='{"status":"idle"}' if(!defined($json) || $json eq "");
 my $tmp="${_ccss_create_state_file}.tmp";
 if(open(my $fh,">",$tmp)) {
  print $fh $json;
  close($fh);
  rename($tmp,$_ccss_create_state_file);
 }
}

sub _webui_ccss_create_read_state (@) {
 return '{"status":"idle"}' unless(-f $_ccss_create_state_file);
 my $json="";
 if(open(my $fh,"<",$_ccss_create_state_file)) { local $/; $json=<$fh>; close($fh); }
 return ($json ne "" && $json=~/^\{/) ? $json : '{"status":"idle"}';
}

sub _webui_ccss_create_alive (@) {
 return 0 unless(-f $_ccss_create_pid_file);
 my $pid="";
 if(open(my $fh,"<",$_ccss_create_pid_file)) { local $/; $pid=<$fh>; close($fh); }
 $pid=~s/\D//g;
 return 0 if($pid eq "");
 # The helper runs as root (sudo) but the web daemon runs as 'pgenerator', so
 # kill(0,$pid) returns EPERM (not ESRCH) on a LIVE helper and falsely reports
 # it dead -- which made webui_ccss_create_status rewrite every 'running' state
 # to error, hiding the wizard popup mid-flow. Check /proc instead; /proc/$pid
 # is readable by anyone on Linux. (Same fix as webui_meter_session_alive.)
 return (-d "/proc/$pid") ? 1 : 0;
}

sub webui_ccss_create_status (@) {
 my $json=&_webui_ccss_create_read_state();
 if($json=~/"status"\s*:\s*"(starting|running)"/ && !&_webui_ccss_create_alive()) {
  # The helper exited with state still 'running'. Surface a CURATED message --
  # never the raw ccxxmake log (it reads like a wall of internal errors). Keep
  # the raw tail in the daemon log for our own diagnostics only.
  if(-f $_ccss_create_log_file) {
   my $tail=`tail -n 20 $_ccss_create_log_file 2>/dev/null`;
   $tail=~s/\s+/ /g;
   $tail=~s/^\s+|\s+$//g;
   &log("WebUI: meter profile create helper exited unexpectedly; ccxxmake log tail: $tail") if($tail ne "");
  }
  my $msg="Meter profile creation stopped unexpectedly. Make sure no other measurement is running and the selected meters are still connected, then try again.";
  my $escaped=&_webui_json_escape($msg);
  $json="{\"status\":\"error\",\"message\":\"$escaped\"}";
  &_webui_ccss_create_write_state($json);
 }
 return $json;
}

sub webui_ccss_create_stop (@) {
 if(&_webui_ccss_create_alive()) {
  my $pid="";
  if(open(my $fh,"<",$_ccss_create_pid_file)) { local $/; $pid=<$fh>; close($fh); }
  $pid=~s/\D//g;
  system("sudo kill -TERM $pid 2>/dev/null") if($pid ne "");
  my $waited=0;
  while($waited < 30 && &_webui_ccss_create_alive()) {
   Time::HiRes::sleep(0.1);
   $waited++;
  }
  if(&_webui_ccss_create_alive() && $pid ne "") {
   system("sudo kill -KILL $pid 2>/dev/null");
  }
 }
 # Also clear any orphaned ccxxmake: a SIGKILLed helper can leave its child
 # behind, holding the meter so the next read/CCSS fails to claim it.
 system("sudo pkill -9 -f 'ccxxmake' 2>/dev/null");
 unlink($_ccss_create_pid_file);
 my $json='{"status":"cancelled","message":"Meter profile creation cancelled"}';
 &_webui_ccss_create_write_state($json);
 return '{"status":"ok","message":"Meter profile creation stopped"}';
}

sub webui_ccss_create_start (@) {
 my ($body)=@_;
 my $request=eval { require JSON::PP; JSON::PP::decode_json($body); };
 $request={} if($@ || ref($request) ne "HASH");
 my $name=defined($request->{"name"}) && !ref($request->{"name"}) ? "$request->{name}" : "";
 $name=~s/^\s+|\s+$//g;
 my $display_type_key=defined($request->{"display_type"}) && !ref($request->{"display_type"}) ? "$request->{display_type}" : "";
 my $format="ccss";
 $format=lc($1) if($body=~/"format"\s*:\s*"(ccss|ccmx)"/i);
 my $signal_mode=&webui_pattern_signal_mode($body);
 my $max_luma=&webui_pattern_max_luma($body);
 my $patch_size=18;
 $patch_size=$1 if($body=~/"patch_size"\s*:\s*(\d+)/);
 my $refresh_rate="";
 $refresh_rate=$1 if($body=~/"refresh_rate"\s*:\s*"([\d.]+)"/);
 my $profiling_port="";
 $profiling_port=$1 if($body=~/"profiling_meter_port"\s*:\s*"?(\d+)"?/);
 my $target_port="";
 $target_port=$1 if($body=~/"target_meter_port"\s*:\s*"?(\d+)"?/);
 my $high_resolution=0;
 $high_resolution=1 if($body=~/"high_resolution"\s*:\s*(?:true|1|"true"|"1"|"yes")/i);

 return '{"status":"error","message":"Enter a profile name"}' if($name eq "");
 return '{"status":"error","message":"Profile name must be 80 characters or fewer"}' if(length($name)>80);
 return '{"status":"error","message":"Interactive meter profile creator is not installed on this image"}' if(!-x $_ccss_create_ccxxmake_bin);
 return '{"status":"error","message":"Meter profile create helper is missing"}' if(!-x $_ccss_create_runner || !-x $_ccss_create_patch_cmd);
 my $python_runner=`command -v python3 2>/dev/null || command -v python2 2>/dev/null || command -v python 2>/dev/null`;
 chomp($python_runner);
 $python_runner=~s/[^A-Za-z0-9_\/.-]//g;
 return '{"status":"error","message":"python2 or python3 is required for live meter profile creation on this image"}' if($python_runner eq "");

 my $disptech=&_webui_ccss_ccxxmake_disptech($display_type_key);
 return '{"status":"error","message":"Choose a concrete display technology before creating the profile"}' if($disptech eq "");

 my $status_json=`sudo bash $_meter_wrapper --detect 2>/dev/null`;
 my @meters;
 while($status_json=~/\{"port_num":"([^"]*)","port":"([^"]*)","usb_id":(?:null|"([^"]*)"),"name":"([^"]*)","meter_type":"([^"]*)"(?:,"physical_port":"([^"]*)")?\}/g) {
  push @meters,{port_num=>$1,port=>$2,usb_id=>$3||"",name=>$4,meter_type=>lc($5||""),physical_port=>$6||""};
 }
 my @spectros=grep { ($_->{meter_type}||"") eq "spectro" } @meters;
 my @colorimeters=grep { ($_->{meter_type}||"") eq "colorimeter" } @meters;
 my @references=$format eq "ccmx" ? @meters : @spectros;
 return '{"status":"error","message":"Connect a reference meter before creating the profile"}' if(!@references);
 # A CCSS needs spectral data. A CCMX may use either a spectrophotometer or a
 # colorimeter as its reference, provided the target is a different colorimeter.
 my ($chosen)=grep { $_->{port_num} eq $profiling_port } @references;
 ($chosen)=@references if(!$chosen && scalar(@references) == 1);
 return '{"status":"error","message":"Select which reference meter to use"}' if(!$chosen);
 return '{"status":"error","message":"The selected reference meter does not support high-resolution spectral mode"}' if($high_resolution && !&_webui_meter_supports_highres($chosen));
 my $chosen_port=$chosen->{port_num};
 $chosen_port=~s/[^0-9]//g;
 return '{"status":"error","message":"Selected reference meter has no usable port"}' if($chosen_port eq "");
 my $target;
 if($format eq "ccmx") {
  ($target)=grep { $_->{port_num} eq $target_port } @colorimeters;
  ($target)=@colorimeters if(!$target && scalar(@colorimeters) == 1);
  return '{"status":"error","message":"Connect and select the target colorimeter for CCMX creation"}' if(!$target);
  $target_port=$target->{port_num};
  $target_port=~s/[^0-9]//g;
  return '{"status":"error","message":"The target colorimeter has no usable Argyll port"}' if($target_port!~/^[1-9]$/);
  return '{"status":"error","message":"Reference and target must be different meters"}' if($target_port eq $chosen_port);
 }

 my $custom_storage_dir=&_webui_custom_ccss_storage_dir();
 return '{"status":"error","message":"Custom storage unavailable"}' if($custom_storage_dir eq "");

 my $safe_name=&_webui_ccss_safe_filename($name,$format);
 my $out_path="$custom_storage_dir/$safe_name";
 return '{"status":"error","message":"A custom '.uc($format).' with that name already exists"}' if(-f $out_path);
 return '{"status":"error","message":"A meter profile creation job is already running"}' if(&_webui_ccss_create_alive());

 &webui_meter_stop();
 &webui_pattern_stop_guard_clear();
 system("sudo bash $_meter_wrapper --kill 2>/dev/null");
 # Kill any stray helper/ccxxmake from a prior attempt. If a previous run's
 # python helper was force-killed, its ccxxmake child orphans and keeps the
 # i1 Pro's interface 0 claimed, so the next ccxxmake fails with "Instrument
 # Access Failed". Clear them before launching a fresh one.
 system("sudo pkill -9 -f 'ccss_create.py' 2>/dev/null");
 system("sudo pkill -9 -f 'ccxxmake' 2>/dev/null");
 # Give the kernel a moment to release the i1 Pro USB interface after spotread
 # and ccxxmake exit, so the new ccxxmake can claim it.
 select(undef,undef,undef,1.5);
 unlink($_ccss_create_pid_file);
 unlink($_ccss_create_log_file);
 unlink($_ccss_create_continue_file);

 my $escaped_name=&_webui_json_escape($safe_name);
 my $format_upper=uc($format);
 &_webui_ccss_create_write_state("{\"status\":\"starting\",\"message\":\"Preparing $format_upper creation...\",\"filename\":\"$escaped_name\",\"format\":\"$format\",\"target_port\":\"$target_port\"}");

 my $profile_label=$name;
 $profile_label=~s/'/'"'"'/g;
 my $cmd="setsid sudo $python_runner $_ccss_create_runner --state-file '$_ccss_create_state_file' --pid-file '$_ccss_create_pid_file' --log-file '$_ccss_create_log_file' --patch-cmd '$_ccss_create_patch_cmd' --output-path '$out_path' --format '$format' --disptech '$disptech' --display-name '$profile_label' --signal-mode '$signal_mode' --max-luma '$max_luma' --patch-size '$patch_size' --ccxxmake-bin '$_ccss_create_ccxxmake_bin'";
 $cmd.=" --high-resolution" if($high_resolution);
 $cmd.=" --refresh-rate '$refresh_rate'" if($refresh_rate ne "");
 $cmd.=" --comport '$chosen_port'" if($chosen_port ne "");
 if($format eq "ccmx") {
  my $target_label=$target->{name}||"target colorimeter";
  $target_label=~s/'/'"'"'/g;
  my $target_yflag=&_webui_ccmx_base_yflag($display_type_key);
  $cmd.=" --target-comport '$target_port' --target-label '$target_label' --target-display-type '$target_yflag'";
 }
 $cmd.=" --continue-file '$_ccss_create_continue_file'";
 $cmd.=" </dev/null >/dev/null 2>&1 &";
 system($cmd);

 my $waited=0;
 my $saw_helper=0;
 my $dead_settle=0;
 while($waited < 80) {
  my $state_json=&_webui_ccss_create_read_state();
  last if($state_json!~/"status"\s*:\s*"starting"/);
  my $alive=&_webui_ccss_create_alive() ? 1 : 0;
  my $has_pid=-f $_ccss_create_pid_file ? 1 : 0;
  if($alive || $has_pid) {
   $saw_helper=1;
   $dead_settle=0;
  }
  elsif($saw_helper) {
   # If the helper started and then exited quickly, give it a short grace
   # window to flush its final error state instead of collapsing that path
   # into a generic "stopped unexpectedly" response.
   $dead_settle++;
   last if($dead_settle >= 10);
  }
  elsif($waited >= 10) {
   last;
  }
  Time::HiRes::sleep(0.1);
  $waited++;
 }
 return &webui_ccss_create_status();
}

sub webui_ccss_create_continue (@) {
 # Headless "press any key" bridge: the UI calls this when the user has
 # positioned the meter, and the runner injects the keypress into ccxxmake.
 return '{"status":"error","message":"No CCSS creation job is running"}' if(!&_webui_ccss_create_alive());
 if(open(my $fh,">",$_ccss_create_continue_file)) {
  print $fh "1";
  close($fh);
  return '{"status":"ok"}';
 }
 return '{"status":"error","message":"Could not signal continue"}';
}

sub webui_ccss_create_setup_ack (@) {
 # Step-ID ack for the CCSS-create setup wizard (mirrors webui_meter_setup_ack):
 # only the current step's id may advance the runner; stale acks are ignored.
 my ($body)=@_;
 my $step_id="";
 $step_id=$1 if($body=~/"step_id"\s*:\s*"?(\d+)"?/);
 return '{"status":"error","message":"Missing step_id"}' if($step_id eq "");
 my $json=&_webui_ccss_create_read_state();
 return '{"status":"ignored","message":"No setup step active"}' if($json eq "" || $json!~/"status"\s*:\s*"setup"/i);
 return '{"status":"ignored","message":"Step already advanced"}' if($json!~/"step_id"\s*:\s*$step_id\b/);
 if(open(my $fh,">",$_ccss_create_continue_file)) {
  print $fh $step_id;
  close($fh);
  return '{"status":"ok"}';
 }
 return '{"status":"error","message":"Could not signal setup ack"}';
}

sub webui_ccss_delete (@) {
 my ($fname)=@_;
 $fname=~s/[^a-zA-Z0-9._-]//g;
 if($fname eq "" || $fname=~/\.\./) {
  return '{"status":"error","message":"Invalid filename"}';
 }
 foreach my $path ("$_custom_ccss_dir/$fname","$_custom_ccss_legacy_dir/$fname") {
  next unless(-f $path);
  unlink($path);
  &log("WebUI: custom CCSS deleted: $fname");
  return '{"status":"ok","message":"Deleted"}';
 }
 return '{"status":"error","message":"File not found"}';
}

# CCSS dry-run validator. Parses the file header to confirm it looks like
# a spectral-sample file, then optionally attempts a short spotread probe
# to verify the active meter accepts the upload. Returns:
#   {ok:true,  description:"…", technology:"…", display_type_refresh:"YES|NO", yflag:"l|c|p"}
#   {ok:false, error:"…"}
sub webui_ccss_validate (@) {
 my ($body)=@_;
 my $fname="";
 $fname=$1 if($body=~/"ccss_file"\s*:\s*"([^"]+)"/);
 # Strip any path components (guard against traversal) but keep just the
 # basename so the resolver below can find it in either $_ccss_dir or
 # $_ccss_dir/custom. Clients typically send "custom/foo.ccss".
 $fname=~s{\\}{/}g;
 $fname=~s{^.*/}{};
 $fname=~s/[^a-zA-Z0-9._\-()\[\] ]//g;
 return '{"ok":false,"error":"Missing or invalid ccss_file"}' if($fname eq "");
 my $resolved="";
 foreach my $base ($_ccss_dir,$_custom_ccss_dir,$_custom_ccss_legacy_dir) {
  my $p="$base/$fname";
  if(-f $p) { $resolved=$p; last; }
 }
 return '{"ok":false,"error":"File not found"}' if($resolved eq "");
 my ($sz)=(-s $resolved);
 return '{"ok":false,"error":"File is empty"}' if(!$sz || $sz<200);

 if($resolved=~/\.ccmx$/i) {
  my $raw=&read_from_file($resolved);
  my ($valid,$error)=&_webui_ccmx_validate_content($raw);
  return '{"ok":false,"error":"'.&_webui_json_escape($error).'"}' if(!$valid);
  my $meta=&_webui_ccss_meta($resolved);
  my $desc=$meta->{display} ne "" ? $meta->{display} : $fname;
  return '{"ok":true'
   .',"format":"ccmx"'
   .',"description":"'.&_webui_json_escape($desc).'"'
   .',"instrument":"'.&_webui_json_escape($meta->{instrument}).'"'
   .',"reference":"'.&_webui_json_escape($meta->{reference}).'"'
   .',"path":"'.&_webui_json_escape($resolved).'"'
   .'}';
 }

 my ($display,$technology,$refresh)=("","","");
 my $has_spectral_format=0;
 my $has_spectral_data=0;
 if(open(my $fh,"<",$resolved)) {
  my $count=0;
  while(my $line=<$fh>) {
   $count++;
   # Some valid Argyll CCSS files have hundreds of SPEC_* header lines before
   # BEGIN_DATA, so allow a much deeper scan before giving up.
   last if($count>1200);
   chomp($line);
   $display=$1    if(!$display    && $line=~/^DISPLAY\s+"([^"]*)"/i);
   $technology=$1 if(!$technology && $line=~/^TECHNOLOGY\s+"([^"]*)"/i);
   $refresh=$1    if(!$refresh    && $line=~/^DISPLAY_TYPE_REFRESH\s+"([^"]*)"/i);
   $has_spectral_format=1 if($line=~/^SPECTRAL_BANDS\b/);
   $has_spectral_format=1 if($line=~/^BEGIN_DATA_FORMAT\b/ && !$has_spectral_format);
   $has_spectral_data=1   if($line=~/^BEGIN_DATA\b/);
   last if($has_spectral_data);
  }
  close($fh);
 } else {
  return '{"ok":false,"error":"Cannot open file for reading"}';
 }
 if(!$has_spectral_format || !$has_spectral_data) {
  return '{"ok":false,"error":"Not a CCSS file (missing spectral bands or data section)"}';
 }
 my $yflag=&_resolve_ccss_yflag($resolved);
 my $desc=$display ne "" ? $display : $fname;
 my $r='{"ok":true'
  .',"description":"'.&_webui_json_escape($desc).'"'
  .',"technology":"'.&_webui_json_escape($technology).'"'
  .',"display_type_refresh":"'.&_webui_json_escape($refresh).'"'
  .',"yflag":"'.&_webui_json_escape($yflag).'"'
  .',"path":"'.&_webui_json_escape($resolved).'"'
  .'}';
 return $r;
}

  sub _webui_ccss_body_target (@) {
   my ($body)=@_;
   my ($fname,$source)=("","");
   $fname=$1 if($body=~/"filename"\s*:\s*"([^"]+)"/);
   $source=lc($1) if($body=~/"source"\s*:\s*"(system|custom)"/i);
   if($fname eq "" && $body=~/"ccss_file"\s*:\s*"([^"]+)"/) {
    $fname=$1;
    if($fname=~m{^custom/(.+)$}i) {
     $source="custom";
     $fname=$1;
    } elsif($fname=~m{^custom_(.+)$}i) {
     $source="custom";
     $fname=$1;
    } elsif($fname=~m{^ccss_(.+)$}i) {
     $source="system";
     $fname=$1;
    }
   }
   return ($fname,$source);
  }

  sub _webui_ccss_format_number (@) {
   my ($value,$precision)=@_;
   $precision=6 if(!defined($precision) || $precision eq "");
   my $text=sprintf("%.".int($precision)."f",$value+0);
   $text=~s/\.0+$//;
   $text=~s/(\.\d*?)0+$/$1/;
   return $text;
  }

  sub _webui_ccss_parse_file (@) {
   my ($resolved,$safe_name)=@_;
   my ($descriptor,$display,$technology,$reference,$refresh)=("","","","","");
   my ($originator,$manufacturer,$manufacturer_id,$created_raw)=("","","","");
   my ($bands,$start_nm,$end_nm,$norm)=(0,0,0,0);
   my @wavelengths=();
   my @samples=();
   my ($in_format,$in_data)=(0,0);

   my $content=&read_from_file($resolved);
   return (undef,"Cannot open CCSS file") if(!defined($content) || $content eq "");

   foreach my $line (split(/\r?\n/,$content // "")) {
    if(!$in_format && !$in_data) {
     $descriptor=$1 if($descriptor eq "" && $line=~/^DESCRIPTOR\s+"([^"]*)"/i);
    $originator=$1 if($originator eq "" && $line=~/^ORIGINATOR\s+"([^"]*)"/i);
    $created_raw=$1 if($created_raw eq "" && $line=~/^CREATED\s+"([^"]*)"/i);
    $manufacturer=$1 if($manufacturer eq "" && $line=~/^MANUFACTURER\s+"([^"]*)"/i);
    $manufacturer_id=$1 if($manufacturer_id eq "" && $line=~/^MANUFACTURER_ID\s+"([^"]*)"/i);
     $display=$1 if($display eq "" && $line=~/^DISPLAY\s+"([^"]*)"/i);
     $technology=$1 if($technology eq "" && $line=~/^TECHNOLOGY\s+"([^"]*)"/i);
     $reference=$1 if($reference eq "" && $line=~/^REFERENCE\s+"([^"]*)"/i);
     $refresh=$1 if($refresh eq "" && $line=~/^DISPLAY_TYPE_REFRESH\s+"([^"]*)"/i);
     $bands=$1+0 if(!$bands && $line=~/^SPECTRAL_BANDS\s+"?([0-9.]+)"?/i);
     $start_nm=$1+0 if(!$start_nm && $line=~/^SPECTRAL_START_NM\s+"?([0-9eE.\-+]+)"?/i);
     $end_nm=$1+0 if(!$end_nm && $line=~/^SPECTRAL_END_NM\s+"?([0-9eE.\-+]+)"?/i);
     $norm=$1+0 if(!$norm && $line=~/^SPECTRAL_NORM\s+"?([0-9eE.\-+]+)"?/i);
     if($line=~/^BEGIN_DATA_FORMAT\b/i) {
      $in_format=1;
      next;
     }
     if($line=~/^BEGIN_DATA\b/i) {
      $in_data=1;
      next;
     }
    }
    if($in_format) {
     if($line=~/^END_DATA_FORMAT\b/i) {
      $in_format=0;
      next;
     }
     next if($line=~/^\s*$/);
     if(!@wavelengths) {
      my @fields=grep { $_ ne "" } split(/\s+/,$line);
      shift @fields if(@fields && uc($fields[0]) eq "SAMPLE_ID");
      foreach my $field (@fields) {
       push @wavelengths, $1+0 if($field=~/^SPEC_([0-9]+(?:\.[0-9]+)?)$/i);
      }
     }
     next;
    }
    if($in_data) {
     last if($line=~/^END_DATA\b/i);
     next if($line=~/^\s*$/);
     my @fields=grep { $_ ne "" } split(/\s+/,$line);
     next unless(@fields>=2);
     my $sample_id=shift @fields;
     my $limit=@wavelengths ? scalar(@wavelengths) : scalar(@fields);
     my @values;
     for(my $i=0;$i<$limit && $i<scalar(@fields);$i++) {
      my $value=$fields[$i];
      $value=~s/[^0-9eE.\-+]//g;
      push @values, ($value ne "" ? $value+0 : 0);
     }
     push @samples, { id=>$sample_id, values=>\@values } if(@values);
    }
   }

   if(!@wavelengths && $bands>0 && $end_nm>$start_nm) {
    my $step=$bands>1 ? (($end_nm-$start_nm)/($bands-1)) : 1;
    for(my $i=0;$i<$bands;$i++) {
     push @wavelengths, $start_nm+($step*$i);
    }
   }
   return (undef,"No spectral data found in CCSS file") if(!@wavelengths || !@samples);

   $bands=scalar(@wavelengths) if(!$bands && @wavelengths);
   $start_nm=$wavelengths[0] if(!$start_nm && @wavelengths);
   $end_nm=$wavelengths[-1] if(!$end_nm && @wavelengths);

   my $global_max=0;
   my @parsed_samples;
   my @default_labels=("Red","Green","Blue","White");
   for(my $idx=0;$idx<scalar(@samples);$idx++) {
    my $sample=$samples[$idx];
    my @values=@{$sample->{values}||[]};
    my $limit=scalar(@values) < scalar(@wavelengths) ? scalar(@values) : scalar(@wavelengths);
    next if($limit<=0);
    $#values=$limit-1;
    my ($peak_idx,$peak_val)=(0,-1);
    for(my $i=0;$i<$limit;$i++) {
     my $value=$values[$i]+0;
     if($value>$peak_val) {
      $peak_val=$value;
      $peak_idx=$i;
     }
     $global_max=$value if($value>$global_max);
    }
    my $label=$default_labels[$idx] || ("Set ".($idx+1));
    my $peak_nm=$wavelengths[$peak_idx] || 0;
    push @parsed_samples, {
     id=>$sample->{id},
     label=>$label,
     peak_nm=>$peak_nm+0,
     peak_value=>($peak_val>0 ? $peak_val+0 : 0),
     values=>\@values
    };
   }
   return (undef,"No usable spectral samples found") if(!@parsed_samples);
   $global_max=1 if($global_max<=0);

   return ({
    safe_name=>$safe_name,
    descriptor=>$descriptor,
    originator=>$originator,
    manufacturer=>$manufacturer,
    manufacturer_id=>$manufacturer_id,
    created_raw=>$created_raw,
    display=>$display,
    technology=>$technology,
    reference=>$reference,
    display_type_refresh=>$refresh,
    bands=>$bands+0,
    start_nm=>$start_nm+0,
    end_nm=>$end_nm+0,
    norm=>$norm+0,
    max_value=>$global_max+0,
    wavelengths=>\@wavelengths,
    samples=>\@parsed_samples,
    raw_content=>$content
   },"");
  }

  sub _webui_ccss_preview_payload (@) {
   my ($parsed,$resolved_source)=@_;
   my @sample_json;
   foreach my $sample (@{$parsed->{samples}||[]}) {
    my @values_json=map { &_webui_ccss_format_number($_,6) } @{$sample->{values}||[]};
    push @sample_json,
     '{"id":"'.&_webui_json_escape($sample->{id}).'"'
     .',"label":"'.&_webui_json_escape($sample->{label}).'"'
     .',"peak_nm":'.&_webui_ccss_format_number($sample->{peak_nm},3)
     .',"peak_value":'.&_webui_ccss_format_number($sample->{peak_value},6)
     .',"values":['.join(',',@values_json).']}'
    ;
   }

   my @wavelengths_json=map { &_webui_ccss_format_number($_,3) } @{$parsed->{wavelengths}||[]};
   my $desc=$parsed->{descriptor} ne "" ? $parsed->{descriptor} : ($parsed->{display} ne "" ? $parsed->{display} : $parsed->{safe_name});
   return '{"ok":true'
    .',"name":"'.&_webui_json_escape($parsed->{safe_name}).'"'
    .',"source":"'.&_webui_json_escape($resolved_source).'"'
    .',"description":"'.&_webui_json_escape($desc).'"'
    .',"display":"'.&_webui_json_escape($parsed->{display}).'"'
    .',"technology":"'.&_webui_json_escape($parsed->{technology}).'"'
    .',"reference":"'.&_webui_json_escape($parsed->{reference}).'"'
    .',"display_type_refresh":"'.&_webui_json_escape($parsed->{display_type_refresh}).'"'
    .',"bands":'.($parsed->{bands}+0)
    .',"start_nm":'.&_webui_ccss_format_number($parsed->{start_nm},3)
    .',"end_nm":'.&_webui_ccss_format_number($parsed->{end_nm},3)
    .',"norm":'.&_webui_ccss_format_number($parsed->{norm},6)
    .',"max_value":'.&_webui_ccss_format_number($parsed->{max_value},6)
    .',"wavelengths":['.join(',',@wavelengths_json).']'
    .',"samples":['.join(',',@sample_json).']'
    .'}';
  }

  sub _webui_ccss_export_csv (@) {
   my ($parsed)=@_;
   my @samples=@{$parsed->{samples}||[]};
    my @wavelengths=@{$parsed->{wavelengths}||[]};
    my $can_emit_raw_rows=((scalar(@samples)==3 || scalar(@samples)==4) && scalar(@wavelengths)==401);
    if($can_emit_raw_rows) {
     my $is_uniform_1nm=1;
     $is_uniform_1nm=0 if(abs((($wavelengths[0]||0)+0)-380)>0.01 || abs((($wavelengths[-1]||0)+0)-780)>0.01);
     for(my $i=1;$i<scalar(@wavelengths) && $is_uniform_1nm;$i++) {
      my $step=(($wavelengths[$i]||0)+0)-(($wavelengths[$i-1]||0)+0);
      $is_uniform_1nm=0 if(abs($step-1)>0.01);
     }
     if($is_uniform_1nm) {
      my @lines;
      foreach my $sample (@samples) {
      my @values=map { sprintf("%.2E",(defined($_) ? $_ : 0)+0) } @{$sample->{values}||[]};
      push @lines, join(',',@values);
      }
      return join("\n",@lines)."\n";
     }
    }
   my @headers=("wavelength");
   for(my $idx=0;$idx<scalar(@samples);$idx++) {
    push @headers, ($idx==0 ? "R" : $idx==1 ? "G" : $idx==2 ? "B" : $idx==3 ? "W" : ("Set".($idx+1)));
   }
   my @lines=(join(',',@headers));
   for(my $i=0;$i<scalar(@wavelengths);$i++) {
    my @row=(&_webui_ccss_format_number($wavelengths[$i],3));
    foreach my $sample (@samples) {
     my $value=(ref($sample->{values}) eq "ARRAY" && defined($sample->{values}->[$i])) ? $sample->{values}->[$i] : 0;
     push @row, &_webui_ccss_format_number($value,6);
    }
    push @lines, join(',',@row);
   }
   return join("\n",@lines)."\n";
  }

  sub _webui_ccss_ascii_field (@) {
   my ($text)=@_;
   $text="" if(!defined($text));
   $text=~s/\r?\n/ /g;
   $text=~s/[^\x20-\x7E]//g;
   $text=~s/\s+/ /g;
   $text=~s/^\s+|\s+$//g;
   return $text;
  }

  sub _webui_ccss_interp_linear (@) {
   my ($target,$wavelengths,$values)=@_;
   return 0 if(ref($wavelengths) ne "ARRAY" || ref($values) ne "ARRAY" || !@{$wavelengths} || !@{$values});
   my $last_index=scalar(@{$wavelengths})-1;
   return 0 if($last_index<0);

   my $first_nm=($wavelengths->[0]||0)+0;
   my $last_nm=($wavelengths->[$last_index]||0)+0;
   return (($values->[0]||0)+0) if(abs($target-$first_nm)<0.000001);
   return (($values->[$last_index]||0)+0) if(abs($target-$last_nm)<0.000001);
   return 0 if($target<$first_nm || $target>$last_nm);

   for(my $i=0;$i<$last_index;$i++) {
    my $x1=($wavelengths->[$i]||0)+0;
    my $x2=($wavelengths->[$i+1]||0)+0;
    my $y1=(defined($values->[$i]) ? $values->[$i] : 0)+0;
    my $y2=(defined($values->[$i+1]) ? $values->[$i+1] : 0)+0;
    return $y1 if(abs($target-$x1)<0.000001);
    return $y2 if(abs($target-$x2)<0.000001);
    next if($target>$x2);
    return $y1 if($x2<=$x1);
    my $ratio=($target-$x1)/($x2-$x1);
    return $y1+(($y2-$y1)*$ratio);
   }
   return 0;
  }

  sub _webui_ccss_resample_series (@) {
   my ($wavelengths,$values)=@_;
   my @resampled=();
   for(my $nm=380;$nm<=780;$nm++) {
    my $value=&_webui_ccss_interp_linear($nm,$wavelengths,$values);
    $value=0 if($value<0);
    push @resampled, $value+0;
   }
   return \@resampled;
  }

  sub _webui_ccss_edr_tech_type (@) {
   my ($technology,$display,$safe_name)=@_;
   my %exact=(
    "CUSTOM"=>1,
    "CRT"=>2,
    "LCD CCFL IPS"=>3,
    "LCD CCFL VPA"=>4,
    "LCD CCFL TFT"=>5,
    "LCD CCFL WIDE GAMUT IPS"=>6,
    "LCD CCFL WIDE GAMUT VPA"=>7,
    "LCD CCFL WIDE GAMUT TFT"=>8,
    "LCD WHITE LED IPS"=>9,
    "LCD WHITE LED VPA"=>10,
    "LCD WHITE LED TFT"=>11,
    "LCD RGB LED IPS"=>12,
    "LCD RGB LED VPA"=>13,
    "LCD RGB LED TFT"=>14,
    "LED OLED"=>15,
    "LED AMOLED"=>16,
    "PLASMA"=>17,
    "LCD RG PHOSPHOR"=>18,
    "PROJECTOR RGB FILTER WHEEL"=>19,
    "PROJECTOR RGBW FILTER WHEEL"=>20,
    "PROJECTOR RGBCMY FILTER WHEEL"=>21,
    "PROJECTOR"=>22,
    "LCD PFS PHOSPHOR"=>23,
    "LED WOLED"=>24,
    "LCD GB R PHOSPHOR IPS"=>64
   );
   my $text=uc(&_webui_ccss_ascii_field(join(" ",grep { defined($_) && $_ ne "" } ($technology,$display,$safe_name))));
   $text=~s/[\/_\-]+/ /g;
   $text=~s/\s+/ /g;
   $text=~s/^\s+|\s+$//g;
   return $exact{$text} if(exists $exact{$text});

   my $suffix=" IPS" if($text=~/\bIPS\b/);
   $suffix=" VPA" if($text!~/\bIPS\b/ && $text=~/\bVPA\b/);
   $suffix=" TFT" if($text!~/\bIPS\b/ && $text!~/\bVPA\b/ && $text=~/\bTFT\b/);

   return 21 if($text=~/PROJECTOR\s+RGBCMY/);
   return 20 if($text=~/PROJECTOR\s+RGBW/);
   return 19 if($text=~/PROJECTOR\s+RGB/);
   return 22 if($text=~/PROJECTOR/);
   return 64 if($text=~/GB\s*R\s+PHOSPHOR/);
   return 23 if($text=~/PFS\s+PHOSPHOR/);
   return 18 if($text=~/RG\s+PHOSPHOR/);
   return ($exact{"LCD RGB LED$suffix"} || 12) if($text=~/RGB\s+LED/);
   return ($exact{"LCD WHITE LED$suffix"} || 9) if($text=~/(?:WHITE|W)\s*LED/);
   return ($exact{"LCD CCFL WIDE GAMUT$suffix"} || 6) if($text=~/WIDE\s+GAMUT\s+CCFL|WGCCFL/);
   return ($exact{"LCD CCFL$suffix"} || 3) if($text=~/CCFL/);
   return 24 if($text=~/WRGB\s+OLED|WOLED/);
   return 16 if($text=~/AMOLED/);
   return 15 if($text=~/QD\s*OLED|RGB\s+OLED|OLED/);
   return 17 if($text=~/PLASMA/);
   return 2 if($text=~/CRT/);
   return 1;
  }

  sub _webui_ccss_pack_u64le (@) {
   my ($value)=@_;
   $value=0 if(!defined($value) || $value<0);
   my $low=$value % 4294967296;
   my $high=int($value / 4294967296);
   return pack("L< L<",$low,$high);
  }

  sub _webui_ccss_export_edr (@) {
   my ($parsed)=@_;
   my @samples=@{$parsed->{samples}||[]};
   my @wavelengths=@{$parsed->{wavelengths}||[]};
   return "" if(!@samples || !@wavelengths);

   my $desc=$parsed->{descriptor} ne "" ? $parsed->{descriptor} : ($parsed->{display} ne "" ? $parsed->{display} : $parsed->{safe_name});
   my $display=$parsed->{display} ne "" ? $parsed->{display} : $parsed->{safe_name};
   my $creation_tool="PGenerator+ CCSS export";
   $creation_tool.=" - ".$parsed->{originator} if($parsed->{originator});
   my $tech_type=&_webui_ccss_edr_tech_type($parsed->{technology},$parsed->{display},$parsed->{safe_name});
   my $norm=($parsed->{norm}||0)+0;

  my $edr=pack(
   "a9 x7 L< L<",
    "EDR DATA1",
    1,
   1
  );
  $edr.=&_webui_ccss_pack_u64le(int(time()));
  $edr.=pack(
   "a64 a256 L< L< a64 a64 a64 L< S< S< d< d< d< L< x12",
    &_webui_ccss_ascii_field($creation_tool),
    &_webui_ccss_ascii_field($desc),
    $tech_type,
    scalar(@samples),
    &_webui_ccss_ascii_field($parsed->{manufacturer}),
    &_webui_ccss_ascii_field($parsed->{manufacturer_id}),
    &_webui_ccss_ascii_field($display),
    0,
    1,
    1,
    380.0,
    780.0,
    $norm,
    0
   );

   my $display_header=pack(
    "a12 x68 S< S< S< a2 d< d< d< d< d<",
    "DISPLAY DATA",
    255,
    255,
    255,
    "c",
    0,
    0,
    0,
    0,
    0
   );

   foreach my $sample (@samples) {
    my $series=&_webui_ccss_resample_series(\@wavelengths,$sample->{values});
    my $spectral_header=pack("a13 x3 L< L< a4","SPECTRAL DATA",scalar(@{$series}),0,"0000");
    $edr.=$display_header;
    $edr.=$spectral_header;
    foreach my $value (@{$series}) {
     my $watts=($value+0)/1000.0;
     $watts=0 if($watts<0);
     $edr.=pack("d<",$watts);
    }
   }

   return $edr;
  }

  sub webui_ccss_export (@) {
   my ($body)=@_;
   my ($fname,$source)=&_webui_ccss_body_target($body);
   my $format="ccss";
   $format=lc($1) if($body=~/"format"\s*:\s*"([^"]+)"/i);
   $format=~s/^\.+//;
   $format=~s/[^a-z0-9]//g;
   $format="ccss" if($format eq "" || $format eq "raw" || $format eq "txt");

   my ($resolved,$resolved_source,$safe_name)=&_webui_ccss_resolve_named_path($fname,$source);
   return (0,400,'application/json','',"{\"status\":\"error\",\"message\":\"Missing or invalid filename\"}") if($safe_name eq "");
   return (0,404,'application/json','',"{\"status\":\"error\",\"message\":\"Correction profile not found\"}") if($resolved eq "");

   if($resolved=~/\.ccmx$/i) {
    my $raw=&read_from_file($resolved);
    my ($valid,$error)=&_webui_ccmx_validate_content($raw);
    return (0,400,'application/json','',"{\"status\":\"error\",\"message\":\"".&_webui_json_escape($error)."\"}") if(!$valid);
    my $base_name=$safe_name;
    $base_name=~s/\.[^.]+$//;
    $base_name=~s/[^a-zA-Z0-9._\-]+/_/g;
    return (1,200,'text/plain; charset=utf-8',"${base_name}.ccmx",$raw) if($format eq "ccmx" || $format eq "ccss");
    return (0,415,'application/json','',"{\"status\":\"error\",\"message\":\"CCMX profiles can only be exported as CCMX\"}");
   }

   my ($parsed,$error)=&_webui_ccss_parse_file($resolved,$safe_name);
   if(!$parsed) {
    my $message=&_webui_json_escape($error||"Unable to parse CCSS file");
    return (0,400,'application/json','',"{\"status\":\"error\",\"message\":\"$message\"}");
   }

   my $base_name=$safe_name;
   $base_name=~s/\.[^.]+$//;
   $base_name=~s/[^a-zA-Z0-9._\-]+/_/g;
   $base_name=~s/_+/_/g;
   $base_name=~s/^_+|_+$//g;
   $base_name="ccss_profile" if($base_name eq "");

   if($format eq "ccss") {
    return (1,200,'text/plain; charset=utf-8',"${base_name}.ccss",&_webui_ccss_normalize_keywords($parsed->{raw_content}));
   }
   if($format eq "csv") {
    return (1,200,'text/csv; charset=utf-8',"${base_name}.csv",&_webui_ccss_export_csv($parsed));
   }
  if($format eq "edr") {
   my $edr=&_webui_ccss_export_edr($parsed);
   return (0,400,'application/json','',"{\"status\":\"error\",\"message\":\"Unable to build EDR export\"}") if($edr eq "");
   return (1,200,'application/octet-stream',"${base_name}.edr",$edr);
   }

   my $message=&_webui_json_escape("Unsupported export format");
   return (0,415,'application/json','',"{\"status\":\"error\",\"message\":\"$message\"}");
  }

sub webui_ccss_preview (@) {
 my ($body)=@_;
   my ($fname,$source)=&_webui_ccss_body_target($body);

 my ($resolved,$resolved_source,$safe_name)=&_webui_ccss_resolve_named_path($fname,$source);
 return '{"ok":false,"error":"Missing or invalid filename"}' if($safe_name eq "");
 return '{"ok":false,"error":"Correction profile not found"}' if($resolved eq "");

 if($resolved=~/\.ccmx$/i) {
  my $raw=&read_from_file($resolved);
  my ($valid,$error)=&_webui_ccmx_validate_content($raw);
  return '{"ok":false,"error":"'.&_webui_json_escape($error).'"}' if(!$valid);
  my $meta=&_webui_ccss_meta($resolved);
  my ($data)=$raw=~/^BEGIN_DATA[ \t]*\r?\n(.*?)^END_DATA[ \t]*$/mis;
  my @rows;
  foreach my $line (grep { $_!~/^\s*$/ } split(/\r?\n/,$data||"")) {
   my @values=grep { $_ ne "" } split(/\s+/,$line);
   push @rows, '['.join(',',map { 0+$_ } @values).']';
  }
  my $desc=$meta->{display} ne "" ? $meta->{display} : $safe_name;
  return '{"ok":true'
   .',"format":"ccmx"'
   .',"name":"'.&_webui_json_escape($safe_name).'"'
   .',"source":"'.&_webui_json_escape($resolved_source).'"'
   .',"description":"'.&_webui_json_escape($desc).'"'
   .',"display":"'.&_webui_json_escape($meta->{display}).'"'
   .',"instrument":"'.&_webui_json_escape($meta->{instrument}).'"'
   .',"reference":"'.&_webui_json_escape($meta->{reference}).'"'
   .',"matrix":['.join(',',@rows).']'
   .'}';
 }

   my ($parsed,$error)=&_webui_ccss_parse_file($resolved,$safe_name);
   return '{"ok":false,"error":"'.&_webui_json_escape($error||"Unable to parse CCSS file").'"}' if(!$parsed);
   return &_webui_ccss_preview_payload($parsed,$resolved_source);
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

sub _webui_ccss_safe_filename (@) {
 my ($name,$format)=@_;
 $name="" if(!defined $name);
 $format=lc($format||"ccss");
 $format="ccss" if($format ne "ccmx");
 my $safe=$name;
 $safe=~s/[^a-zA-Z0-9._\- ]//g;
 $safe=~s/\s+/_/g;
 $safe=substr($safe,0,60) if(length($safe)>60);
 $safe="custom_$format" if($safe eq "");
 $safe=~s/\.(?:ccss|ccmx)$//i;
 $safe.=".$format";
 return $safe;
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

sub _webui_csv_data_to_ccss (@) {
 my ($data,$profile_name,$orig_filename,$has_white)=@_;
 return undef if(ref($data) ne "ARRAY" || scalar(@{$data})<10);

 my @resampled;
 for(my $nm=380;$nm<=780;$nm++) {
  my %pt=(wl=>$nm);
  for my $ch ("r","g","b","w") {
   next if($ch eq "w" && !$has_white);
   $pt{$ch}=&_interp_spectral($data,$ch,$nm);
  }
  push @resampled,\%pt;
 }

 my $num_sets=$has_white?4:3;
 my $norm=0;
 for my $pt (@resampled) {
  for my $ch ("r","g","b",($has_white?"w":())) {
   $norm=$pt->{$ch} if($pt->{$ch}>$norm);
  }
 }
 $norm=1 if($norm<=0);

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

sub csv_to_ccss (@) {
 my ($csv_text,$profile_name,$orig_filename)=@_;
 my @all_lines=grep { $_!~/^\s*$/ && $_!~/^\s*#/ } split(/\r?\n/,$csv_text);
 return undef if(!@all_lines);

 my @first_cols=split(/[,\t]/,$all_lines[0],-1);
 if((scalar(@all_lines)==3 || scalar(@all_lines)==4) && scalar(@first_cols)>=50) {
  my $bands=scalar(@first_cols);
  my $raw_row_major=1;
  foreach my $line (@all_lines) {
   my @cells=split(/[,\t]/,$line,-1);
   if(scalar(@cells)!=$bands) { $raw_row_major=0; last; }
   for(my $i=0;$i<$bands;$i++) {
    my $val=$cells[$i];
    $val=~s/^\x{FEFF}// if($i==0);
    $val=~s/[^\d.eE\-+]//g;
    if($val eq "") { $raw_row_major=0; last; }
   }
   last if(!$raw_row_major);
  }
  if($raw_row_major) {
   my $step=$bands>1 ? (400/($bands-1)) : 1;
   return undef if($step<=0);
   my @rows;
   foreach my $line (@all_lines) {
    my @cells=split(/[,\t]/,$line,-1);
    my @values;
    for(my $i=0;$i<$bands;$i++) {
     my $val=$cells[$i];
     $val=~s/^\x{FEFF}// if($i==0);
     $val=~s/[^\d.eE\-+]//g;
     push @values, ($val ne "" ? $val+0 : 0);
    }
    push @rows,\@values;
   }
   my $has_white=(scalar(@rows)>=4)?1:0;
   my @data;
   for(my $idx=0;$idx<$bands;$idx++) {
    my %row=(
     wl=>380+($idx*$step),
     r=>$rows[0]->[$idx],
     g=>$rows[1]->[$idx],
     b=>$rows[2]->[$idx]
    );
    $row{w}=$rows[3]->[$idx] if($has_white);
    push @data,\%row;
   }
   return &_webui_csv_data_to_ccss(\@data,$profile_name,$orig_filename,$has_white);
  }
 }

 my @lines=@all_lines;
 my $header=shift @lines;
 return undef if(!$header);
 my @cols=split(/[,\t]/,$header);
 my ($wl_col,$r_col,$g_col,$b_col,$w_col)=(-1,-1,-1,-1,-1);
 for(my $i=0;$i<scalar(@cols);$i++) {
  my $c=lc($cols[$i]);
  $c=~s/^\s+|\s+$//g;
  $c=~s/^\x{FEFF}//;
  $c=~s/^"(.*)"$/$1/;
  if($c=~/^(wavelength|nm|lambda|wl)$/) { $wl_col=$i; }
  elsif($c=~/^(red|r)$/) { $r_col=$i; }
  elsif($c=~/^(green|g)$/) { $g_col=$i; }
  elsif($c=~/^(blue|b)$/) { $b_col=$i; }
  elsif($c=~/^(white|w)$/) { $w_col=$i; }
 }
 if($wl_col<0) {
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
 return &_webui_csv_data_to_ccss(\@data,$profile_name,$orig_filename,($w_col>=0)?1:0);
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
sub webui_reload_pgenerator_conf (@) {
 # This used to be "%pgenerator_conf=(); &get_pgenerator_conf();".
 #
 # %pgenerator_conf is share()d (variables.pm), so that clear published an
 # EMPTY conf to every other thread for the whole duration of the file read,
 # and every reader degrades silently to its "|| 0" / "|| ''" defaults -- a
 # plain /api/config poll could blank the conf out from under a concurrent
 # pattern request. Parse into a private hash first, then apply the delta
 # under a lock, so readers always observe a complete, consistent conf.
 my %fresh;
 if(open(my $fh,"<",$pattern_conf)) {
  while(my $line=<$fh>) {
   $line=~s/\r|\n//g;
   next if($line=~/^#/ || $line eq "");
   $line=~s/^\s//g;
   $fresh{$1}=$2 if($line=~/(.*)=(.*)/);
  }
  close($fh);
 } else {
  # Could not read the conf at all: leave the live hash untouched rather than
  # publishing a half-empty one.
  &sync_pattern_bits_default();
  return;
 }
 {
  lock(%pgenerator_conf);
  foreach my $k (keys %fresh) {
   $pgenerator_conf{$k}=$fresh{$k} if(!exists($pgenerator_conf{$k}) || $pgenerator_conf{$k} ne $fresh{$k});
  }
  foreach my $k (keys %pgenerator_conf) {
   delete($pgenerator_conf{$k}) if(!exists($fresh{$k}));
  }
 }
 &sync_pattern_bits_default();
}

sub webui_config_json (@) {
 &webui_reload_pgenerator_conf();
 my %json_conf=%pgenerator_conf;
 my $json_dv_transport=&pg_dv_transport_mode();
 $json_conf{"dv_transport"}=$json_dv_transport;
 if(int($json_conf{"dv_status"} || 0) || int($json_conf{"is_ll_dovi"} || 0) || int($json_conf{"is_std_dovi"} || 0)) {
  $json_conf{"is_ll_dovi"}=&pg_dv_transport_ll_flag($json_dv_transport);
  $json_conf{"is_std_dovi"}=&pg_dv_transport_std_flag($json_dv_transport);
  $json_conf{"dv_interface"}=&pg_dv_transport_interface($json_dv_transport);
  $json_conf{"color_format"}=&pg_dv_transport_color_format($json_dv_transport);
  $json_conf{"max_bpc"}=&pg_dv_transport_max_bpc($json_conf{"max_bpc"});
 }
 my $json="{";
 my $first=1;
 foreach my $k (sort keys %json_conf) {
  $json.="," if(!$first);
  my $v=$json_conf{$k};
  $v=&webui_preferred_rgb_quant_range() if($k eq "rgb_quant_range" && $external_rgb_quant_range_active);
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
 &webui_reload_pgenerator_conf();
 # Parse simple JSON: {"key":"val","key2":"val2"}
 my %changes;
  while($body=~/"(\w+)"\s*:\s*(?:"([^"]*)"|(-?\d+(?:\.\d+)?))/g) {
   $changes{$1}=defined $2 ? $2 : $3;
  }
  my $requested_dv_transport=&pg_dv_transport_mode($changes{"dv_transport"} || $pgenerator_conf{"dv_transport"});
 if(defined $changes{"signal_mode"}) {
  my $signal_mode=lc($changes{"signal_mode"});
  if($signal_mode eq "sdr") {
   $changes{"is_sdr"}="1";
   $changes{"is_hdr"}="0";
   $changes{"is_ll_dovi"}="0";
   $changes{"is_std_dovi"}="0";
   $changes{"dv_status"}="0";
   $changes{"dv_interface"}="0";
   $changes{"dv_metadata"}="0";
   $changes{"eotf"}="0";
   $changes{"primaries"}="0";
  } elsif($signal_mode eq "hdr10" || $signal_mode eq "hlg") {
   $changes{"is_sdr"}="0";
   $changes{"is_hdr"}="1";
   $changes{"is_ll_dovi"}="0";
   $changes{"is_std_dovi"}="0";
   $changes{"dv_status"}="0";
   $changes{"dv_interface"}="0";
   $changes{"dv_metadata"}="0";
   $changes{"eotf"}=($signal_mode eq "hlg") ? "3" : "2";
   $changes{"primaries"}="2";
  } elsif($signal_mode eq "dv") {
   $changes{"is_sdr"}="0";
   $changes{"is_hdr"}="1";
   $changes{"dv_transport"}=$requested_dv_transport;
   $changes{"is_ll_dovi"}=&pg_dv_transport_ll_flag($requested_dv_transport);
   $changes{"is_std_dovi"}=&pg_dv_transport_std_flag($requested_dv_transport);
   $changes{"dv_status"}="1";
   $changes{"dv_interface"}=&pg_dv_transport_interface($requested_dv_transport);
   $changes{"eotf"}="2";
   $changes{"primaries"}="2";
   $changes{"max_bpc"}=&pg_dv_transport_max_bpc($requested_dv_transport, $changes{"max_bpc"} || $pgenerator_conf{"max_bpc"});
   $changes{"color_format"}=&pg_dv_transport_color_format($requested_dv_transport);
   $changes{"colorimetry"}="9";
   $changes{"rgb_quant_range"}="2";
  }
 }
 my %effective=%pgenerator_conf;
 foreach my $k (keys %changes) {
  $effective{$k}=$changes{$k};
 }
 if(!defined $changes{"signal_mode"}) {
  if(int($effective{"dv_status"} || 0) || int($effective{"is_ll_dovi"} || 0) || int($effective{"is_std_dovi"} || 0)) {
   $changes{"signal_mode"}="dv";
  } elsif(int($effective{"is_hdr"} || 0)) {
   $changes{"signal_mode"}=(int($effective{"eotf"} || 0) == 3) ? "hlg" : "hdr10";
 } else {
   $changes{"signal_mode"}="sdr";
  }
 }
 my $requested_mode_clock=0;
 if(defined $changes{"mode_idx"} && $changes{"mode_idx"} ne "" && $changes{"mode_idx"} ne "-1") {
  if($changes{"mode_idx"} !~ /^\d+$/) {
   my $result='{"status":"error","message":"Invalid display mode index."}';
   return wantarray ? ($result,0) : $result;
  }
  my $mode_idx=$changes{"mode_idx"};
  my $mt=`timeout 3 $modetest -c 2>/dev/null`;
  if($mt=~/^\s*#$mode_idx\s+\S+\s+[\d.]+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+(\d+)\s+/m) {
   $requested_mode_clock=$1;
  } else {
   my $result='{"status":"error","message":"Display mode is no longer available. Refresh the page and choose a connected HDMI mode."}';
   return wantarray ? ($result,0) : $result;
  }
 }
 my $dv_on=int($effective{"dv_status"} || 0);
 $dv_on=1 if(int($effective{"is_ll_dovi"} || 0) || int($effective{"is_std_dovi"} || 0));
 if($dv_on) {
  my $dv_transport=&pg_dv_transport_mode($effective{"dv_transport"} || $requested_dv_transport);
  my $dv_map_mode=(defined $changes{"dv_map_mode"} && $changes{"dv_map_mode"} ne "") ? $changes{"dv_map_mode"} : ($effective{"dv_map_mode"} || "2");
  my $dv_metadata=(defined $changes{"dv_metadata"} && $changes{"dv_metadata"} ne "") ? $changes{"dv_metadata"} : (($dv_map_mode eq "1") ? "3" : (($dv_map_mode eq "2") ? "4" : "2"));
  if(!defined $changes{"dv_map_mode"} || $changes{"dv_map_mode"} eq "") {
   $dv_map_mode="0" if($dv_metadata eq "2");
   $dv_map_mode="1" if($dv_metadata eq "3");
   $dv_map_mode="2" if($dv_metadata eq "4");
  }
  $changes{"dv_transport"}=$dv_transport;
  $changes{"max_bpc"}=&pg_dv_transport_max_bpc($changes{"max_bpc"} || $effective{"max_bpc"} || $pgenerator_conf{"max_bpc"});
  $changes{"is_ll_dovi"}=&pg_dv_transport_ll_flag($dv_transport);
  $changes{"is_std_dovi"}=&pg_dv_transport_std_flag($dv_transport);
  $changes{"dv_status"}="1";
  $changes{"color_format"}=&pg_dv_transport_color_format($dv_transport);
  $changes{"colorimetry"}="9";
  $changes{"eotf"}="2";
  $changes{"primaries"}="2";
  $changes{"rgb_quant_range"}="2";
 $changes{"dv_profile"}="1";
 $changes{"dv_color_space"}="0";
  $changes{"dv_interface"}=&pg_dv_transport_interface($dv_transport);
  $changes{"dv_map_mode"}=$dv_map_mode;
  $changes{"dv_metadata"}=$dv_metadata;
  # Dolby Vision calibration uses a platform-specific transport; reject modes
  # above HDMI 2.0 TMDS bandwidth (600 MHz).
  if($requested_mode_clock > 0) {
   if($requested_mode_clock > 600000) {
    my $result='{"status":"error","message":"This resolution exceeds HDMI bandwidth for the selected Dolby Vision transport. Use 4K@60Hz or lower."}';
    return wantarray ? ($result,0) : $result;
   }
  }
 } else {
  $changes{"dv_status"}="0";
  $changes{"is_ll_dovi"}="0";
  $changes{"is_std_dovi"}="0";
  $changes{"dv_interface"}="0";
  $changes{"dv_metadata"}="0";
 }
 my $effective_color_format=(defined $changes{"color_format"} && $changes{"color_format"} ne "") ? int($changes{"color_format"}) : int($pgenerator_conf{"color_format"} || 0);
 my $effective_signal_mode=lc($changes{"signal_mode"} || "");
 my $effective_rgb_quant_range=(defined $changes{"rgb_quant_range"} && $changes{"rgb_quant_range"} ne "") ? int($changes{"rgb_quant_range"}) : int($pgenerator_conf{"rgb_quant_range"} || 0);
 if($effective_color_format > 2) {
  my $result='{"status":"error","message":"YCbCr 4:2:0 is not supported by the current HDMI driver. Use RGB, YCbCr 4:4:4, or YCbCr 4:2:2."}';
  return wantarray ? ($result,0) : $result;
 }
 if(($effective_color_format == 1 || $effective_color_format == 2) && $effective_rgb_quant_range == 2) {
  # YCbCr transports are Limited-range on the wire; Full range is an
  # RGB-only concept. Coerce (rather than error) so older saved configs
  # normalize on their next apply. The UI mirrors this by disabling the
  # Full option whenever a YCbCr colour format is selected.
  $changes{"rgb_quant_range"}="1";
  $effective_rgb_quant_range=1;
 }
 if(($effective_signal_mode eq "hdr10" || $effective_signal_mode eq "hlg") && $effective_rgb_quant_range == 1 && !$dv_on) {
  # Honor max_bpc end-to-end: when the operator sets max_bpc=8 (via the
  # WebUI Bit Depth dropdown or directly in PGenerator.conf), the link
  # is 8-bit, the autocal wizard emits 8-bit codes, and the renderer
  # receives 8-bit values that go out 8-bit to the TV. This supports the
  # 1.6 WORKING YCbCr limited 8-bit A/B test. The previous
  # "force 10-bit for HDR/HLG limited" rule was Pi5-specific; Pi4 honors
  # the operator's choice. YCbCr 4:2:2 (handled below) is the one path
  # that still has a renderer-side 10-bit requirement.
 }
 if($effective_color_format == 2 && !$dv_on) {
  # YCbCr 4:2:2 renderer path is supported at 10-bit only.
  $changes{"max_bpc"}="10";
 }
 # Keys that require pattern generator restart
 my %restart_keys=map{$_=>1} qw(mode_idx eotf is_hdr is_sdr colorimetry primaries
  min_luma max_luma max_cll max_fall color_format max_bpc rgb_quant_range
    dv_status is_ll_dovi is_std_dovi dv_interface dv_profile dv_metadata dv_color_space dv_map_mode dv_transport);

  foreach my $k (sort keys %changes) {
   next if($k eq "ip_pattern" || $k eq "port_pattern"); # read-only
   my $cur=defined($pgenerator_conf{$k}) ? "$pgenerator_conf{$k}" : "";
   my $value_changed=("$changes{$k}" ne $cur);
   &sudo("SET_PGENERATOR_CONF",$k,$changes{$k});
   $pgenerator_conf{$k}=$changes{$k};
   $webui_rgb_quant_range_preferred=$changes{$k} if($k eq "rgb_quant_range");
   # Only a restart-key whose value actually CHANGED bounces the renderer.
   # The derivation above backfills keys unconditionally (signal_mode on
   # every POST; max_bpc=10 whenever the live color format is YCbCr 422),
   # so a single-knob POST (e.g. the Resolve card's patch-size override)
   # was restarting the renderer and blanking the output for a no-op.
   $need_restart=1 if($restart_keys{$k} && $value_changed);
  }
 # Resolve card knobs: redraw the live Resolve patch immediately so the
 # operator sees the change without waiting for the calibration software's
 # next pattern message.
 if((exists($changes{"resolve_patch_size"}) || exists($changes{"resolve_force_center"}))
    && $calibration_client_software eq "Resolve") {
  eval { &resolve_redraw_last(); };
 }
 # A mode change (mode_idx or any signal-attribute restart key) re-negotiates
 # the HDMI link, so the connector's available modes and the sink's advertised
 # capabilities can change. Drop the cached mode list and EDID/caps so the next
 # /api/modes and /api/capabilities calls re-read them live instead of serving a
 # stale snapshot that desyncs the WebUI dropdown from the actual output.
 if(%changes && $need_restart) {
  $_modes_cache=""; $_modes_cache_time=0;
  $_caps_cache=""; $_caps_cache_time=0;
 }
 &sync_pattern_bits_default() if(%changes);
 my $restart_id=$need_restart ? &webui_renderer_restart_begin() : "";
 my $result='{"status":"ok","restart":'.($need_restart ? 'true' : 'false');
 $result.=',"restart_id":"'.$restart_id.'"' if($restart_id ne "");
 $result.='}';
 return wantarray ? ($result,$need_restart,$restart_id) : $result;
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
 my %ip_seen;
 my @ip_files=glob("$info_dir/GET_IP-*.info");
 foreach my $f (@ip_files) {
  my ($iface)=$f=~/GET_IP-(.+)\.info$/;
  next if(!$iface || $iface eq "lo");
  my $addr=&read_from_file($f);
  chomp($addr);
  next if(!$addr || $addr eq "N/A" || $addr eq "None" || $addr eq "");
  $addr=~s/"/\\"/g;
  push @ips, "\"$iface\":\"$addr\"";
  $ip_seen{$iface}=1;
 }
 my $live_ip_out=`ip -o -4 addr show scope global 2>/dev/null`;
 foreach my $line (split(/\n/,$live_ip_out)) {
  next if($line !~ /^\d+:\s+(\S+)\s+inet\s+(\d+\.\d+\.\d+\.\d+)\/\d+/);
  my ($iface,$addr)=($1,$2);
  next if(!$iface || $iface eq "lo" || $ip_seen{$iface});
  $iface=~s/"/\\"/g;
  $addr=~s/"/\\"/g;
  push @ips, "\"$iface\":\"$addr\"";
  $ip_seen{$iface}=1;
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

sub _webui_log_ipv4_class (@) {
 my $addr=shift;
 my @octets=split(/\./,$addr||"");
 return "" if(@octets != 4);
 foreach my $octet (@octets) {
  return "" if($octet !~ /^\d{1,3}$/ || int($octet) > 255);
 }
 return "unspecified" if($addr eq "0.0.0.0");
 return "broadcast" if($addr eq "255.255.255.255");
 return "loopback" if($octets[0] == 127);
 return "link-local" if($octets[0] == 169 && $octets[1] == 254);
 return "private" if($octets[0] == 10
  || ($octets[0] == 172 && $octets[1] >= 16 && $octets[1] <= 31)
  || ($octets[0] == 192 && $octets[1] == 168));
 return "multicast" if($octets[0] >= 224 && $octets[0] <= 239);
 return "public";
}

sub _webui_log_ipv6_class (@) {
 my $addr=shift;
 return "" if(!defined($addr) || $addr eq "" || !defined(&Socket::inet_pton));
 my $packed=eval { Socket::inet_pton(Socket::AF_INET6(),$addr) };
 return "" if(!defined($packed) || length($packed) != 16);
 my $lower=lc($addr);
 return "loopback" if($lower eq "::1" || $packed eq (("\0" x 15)."\1"));
 return "unspecified" if($lower eq "::" || $packed eq ("\0" x 16));
 my $first=ord(substr($packed,0,1));
 my $second=ord(substr($packed,1,1));
 return "link-local" if($first == 0xfe && (($second & 0xc0) == 0x80));
 return "private" if(($first & 0xfe) == 0xfc);
 return "multicast" if($first == 0xff);
 return "public";
}

sub webui_redact_sensitive_log_text (@) {
 my $text=shift;
 $text="" if(!defined($text));

 # Secrets can appear in config, JSON helper output, or wpa_cli output.
 my $secret_key=qr/(?:client[_-]?key|password|passwd|psk|secret|(?:access|auth|pairing)?[_-]?token|pin|(?:private|identity|link|long[_-]?term|local[_-]?identity|remote[_-]?identity)[_-]?key|irk|ltk|csrk)/i;
 $text =~ s{("?$secret_key"?\s*:\s*)"(?:\\.|[^"\\])*"}{$1"<redacted>"}gi;
 $text =~ s{("?$secret_key"?\s*:\s*)(?:-?\d+(?:\.\d+)?|true|false|null)}{$1"<redacted>"}gi;
 $text =~ s{^(\s*$secret_key\s*[:=]\s*).*$}{$1<redacted>}gim;
 $text =~ s{(://[^/\s:@]+:)[^@\s/]+@}{$1<redacted>@}g;

 # Names and stable hardware/account identifiers are not needed to diagnose
 # their state. Cover JSON, config/udev key-value output, and CGATS-style
 # whitespace fields such as INSTRUMENT_SERIAL "12345".
 my $identity_key=qr/(?:ssid|bssid|hostname|host_name|auto_host|user(?:name)?|email|s[\/_-]?n|serial(?:[_-]?(?:number|no))?|(?:device|meter|display|instrument|board|cpu|soc|system|product|chassis|baseboard|edid|adapter|controller)[_-]?serial(?:[_-]?(?:number|no))?|id[_-]?serial(?:[_-]?short)?|uuid|guid|udid|unique[_-]?id|partuuid|(?:boot|machine|product|system|hardware|device|client|installation|instance|network|connection|adapter|interface|wifi|wi[_-]?fi|bluetooth|bt|filesystem|fs|partition|part[_-]?(?:entry|table)|dm)[_-]?(?:uuid|guid|id)|id[_-]?(?:fs|part[_-]?(?:entry|table))[_-]?uuid(?:[_-]?enc)?|(?:device|adapter|controller|interface|wifi|wi[_-]?fi|bluetooth|bt)[_-]?mac(?:[_-]?address)?|mac(?:[_-]?address)?|hwaddr|bdaddr|wwn|wwid|id[_-]?(?:wwn|wwid)|stored_name|cec_osd_name|cec_tv_name|friendly_name|device_name|tv_name)/i;
 $text =~ s{("$identity_key"\s*:\s*)"(?:\\.|[^"\\])*"}{$1"<redacted>"}gi;
 $text =~ s{("$identity_key"\s*:\s*)(?:-?\d+(?:\.\d+)?|true|false|null)}{$1"<redacted>"}gi;
 $text =~ s{("$identity_key"\s*:\s*)\[(?:\\.|[^\]])*\]}{$1["<redacted>"]}gi;
 $text =~ s{^(\s*$identity_key\s*[:=]\s*).*$}{$1<redacted>}gim;
 $text =~ s{^(\s*$identity_key\s+)(?:"(?:\\.|[^"\\])*"|'[^']*'|\S+).*$}{$1<redacted>}gim;
 $text =~ s{^(\s*(?:(?:display product|device|meter|instrument)\s+)?serial(?:\s*(?:number|no\.?|#))?\s*[:=]\s*).*$}{$1<redacted>}gim;
 $text =~ s{(\bserial(?:[_\s-]?(?:number|no\.?))\s*[:=]\s*)(?:"(?:\\.|[^"\\])*"|'[^']*'|[^\s,\}\]]+)}{$1<redacted>}gi;
 $text =~ s{(\b(?:display product|device|meter|instrument)\s+serial(?:\s*(?:number|no\.?|#))?\s+(?:is\s+)?)(?:"(?:\\.|[^"\\])*"|'[^']*'|[^\s,\}\]]+)}{$1<redacted>}gi;
 $text =~ s{^(\s*Host:\s*)\S+(\s+Version:)}{$1<redacted>$2}gim;
 $text =~ s{^(\s*(?:search|domain)\s+).*$}{$1<redacted>}gim;
 $text =~ s{(?<![A-Za-z0-9._%+-])([A-Za-z0-9._%+-]+\@[A-Za-z0-9.-]+\.[A-Za-z]{2,})(?![A-Za-z0-9._%+-])}{<email-redacted>}g;
 $text =~ s{/home/[^/\s]+}{/home/<user>}g;

 # UUIDs/GUIDs also appear without a useful key (Bluetooth service listings,
 # WiFi connection records, D-Bus output and filesystem paths). Preserve only
 # equality within the report so repeated references remain diagnosable.
 my (%uuid_alias,$uuid_count);
 $text =~ s{
  (?<![A-Fa-f0-9])
  (\{?[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}\}?)
  (?![A-Fa-f0-9])
 }{
  my $id=lc($1);
  $id=~s/^\{//; $id=~s/\}$//;
  $uuid_alias{$id} ||= "<uuid-".(++$uuid_count).">";
 }gex;

 # Preserve whether addresses are private/public/link-local and preserve
 # equality within one report, without exposing the actual network topology.
 my (%ipv6_alias,%ipv6_count);
 $text =~ s{
  (?<![A-Za-z0-9_.:])
  ([0-9A-Fa-f:.]*:[0-9A-Fa-f:.]+)
  (?![A-Za-z0-9_.:])
 }{
  my $addr=$1;
  my $class=&_webui_log_ipv6_class($addr);
  $class eq "" ? $addr
   : ($ipv6_alias{$addr} ||= "<ipv6-$class-".(++$ipv6_count{$class}).">");
 }gex;

 my (%ipv4_alias,%ipv4_count);
 $text =~ s{
  (?<![A-Za-z0-9_.])
  ((?:\d{1,3}\.){3}\d{1,3})
  (?![A-Za-z0-9_.])
 }{
  my $addr=$1;
  my $class=&_webui_log_ipv4_class($addr);
  $class eq "" ? $addr
   : ($ipv4_alias{$addr} ||= "<ipv4-$class-".(++$ipv4_count{$class}).">");
 }gex;

 my (%mac_alias,$mac_count);
 $text =~ s{
  (?<![A-Fa-f0-9])
  ((?:(?:[A-Fa-f0-9]{2}[:-]){7}[A-Fa-f0-9]{2})|(?:(?:[A-Fa-f0-9]{2}[:-]){5}[A-Fa-f0-9]{2})|(?:[A-Fa-f0-9]{4}\.){2}[A-Fa-f0-9]{4})
  (?![A-Fa-f0-9])
 }{
  my $addr=lc($1);
  $mac_alias{$addr} ||= "<mac-".(++$mac_count).">";
 }gex;
 return $text;
}

sub webui_sanitize_edid_hex (@) {
 my $edid_hex=shift;
 $edid_hex="" if(!defined($edid_hex));
 $edid_hex=~s/\s+//g;
 return "" if($edid_hex eq "");
 return "(EDID hex unavailable after privacy sanitization)"
  if($edid_hex=~/[^A-Fa-f0-9]/ || (length($edid_hex) % 256) != 0);
 my @bytes=unpack("C*",pack("H*",$edid_hex));
 return "(EDID hex unavailable after privacy sanitization)" if(@bytes < 128);

 # The base block stores a numeric serial and can also carry a serial text
 # descriptor. Neither affects display capability diagnosis.
 @bytes[12..15]=(0,0,0,0);
 foreach my $offset (54,72,90,108) {
  next if($offset + 17 >= 128);
  next if($bytes[$offset] != 0 || $bytes[$offset+1] != 0 || $bytes[$offset+2] != 0 || $bytes[$offset+3] != 0xff);
  for(my $i=$offset+5;$i<=$offset+17;$i++) { $bytes[$i]=0x20; }
 }
 my $sum=0;
 $sum+=$bytes[$_] for(0..126);
 $bytes[127]=(-$sum) & 0xff;

 my @out;
 for(my $offset=0;$offset<@bytes;$offset+=128) {
  if($offset > 0 && $bytes[$offset] == 0x70) {
   push @out, "<DisplayID extension omitted: may contain a device serial>";
   next;
  }
  my $block=pack("C*",@bytes[$offset..$offset+127]);
  my $hex=unpack("H*",$block);
  push @out, ($hex=~/.{1,64}/g);
 }
 return join("\n",@out);
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
 push @out, "  PRIVACY: Network addresses retain only their address class and stable alias.";
 push @out, "  Host/user names, WiFi/Bluetooth identity, UUIDs, credentials, and hardware serials are redacted.";
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
 my $diag_wifi_status=`timeout 3 wpa_cli -i wlan0 status 2>/dev/null`;
 chomp($diag_wifi_status);
 my $diag_wifi_ssid="";
 $diag_wifi_ssid=$1 if($diag_wifi_status=~/^ssid=(.*)$/m);
 push @out, $diag_wifi_status;

 # HDMI / Display
 push @out, "", "--- HDMI Mode ---";
 push @out, `timeout 5 $modetest -c 2>/dev/null | head -80`; chomp($out[$#out]);
 push @out, "", "--- EDID ---";
 my $edid_hex=`timeout 5 cat /sys/class/drm/card?-HDMI-A-1/edid 2>/dev/null | xxd -p 2>/dev/null`;
 chomp($edid_hex);
 if($edid_hex) {
  push @out, &webui_sanitize_edid_hex($edid_hex);
  push @out, "", "--- EDID Decoded ---";
  push @out, `timeout 5 edid-decode /sys/class/drm/card?-HDMI-A-1/edid 2>&1`;
  chomp($out[$#out]);
 } else {
  push @out, "(no EDID — display not connected)";
 }

 # Infoframes
 push @out, "", "--- HDMI Infoframes (dmesg) ---";
 my $dmesg=`timeout 3 /bin/dmesg 2>/dev/null`;
 my ($avi_hex,$drm_hex,$hvs_hex)=("","","");
 foreach my $line (split(/\n/,$dmesg)) {
  if($line=~/AVI IF:\s*(.+)/) { $avi_hex=$1; }
  if($line=~/DRM IF:\s*(.+)/) { $drm_hex=$1; }
  if($line=~/HVS IF:\s*(.+)/) { $hvs_hex=$1; }
 }
 push @out, "AVI: $avi_hex" if($avi_hex);
 push @out, "DRM: $drm_hex" if($drm_hex);
 push @out, "HVS (vendor/DV): $hvs_hex" if($hvs_hex);
 push @out, "(none found)" if(!$avi_hex && !$drm_hex && !$hvs_hex);

 # DV / HDR wire state: the connector blob properties are past the head -80
 # cut of the HDMI Mode section above, so dump them explicitly. This is the
 # ground truth for "the WebUI says DV but the display shows SDR" reports:
 # an empty DOVI_OUTPUT_METADATA value here means the Dolby VSIF is NOT
 # being transmitted, whatever the conf says.
 push @out, "", "--- DV / HDR wire state (connector blobs) ---";
 my $wire_props=`timeout 5 $modetest -a -c 2>/dev/null`;
 $wire_props=`timeout 5 $modetest -c 2>/dev/null` if($wire_props!~/\S/);
 my $wire_report="";
 my $wire_current="";
 foreach my $line (split(/\n/,$wire_props)) {
  if($line=~/^[ \t]*[0-9]+[ \t]+(\S+):/) {
   $wire_current=($1 eq "DOVI_OUTPUT_METADATA" || $1 eq "HDR_OUTPUT_METADATA") ? $1 : "";
   $wire_report.="$line\n" if($wire_current ne "");
   next;
  }
  $wire_report.="$line\n" if($wire_current ne "");
 }
 push @out, ($wire_report ne "" ? $wire_report : "(no DOVI/HDR blob properties on this kernel)");
 my $ram_packet=`grep RAM_PACKET_CONFIG /sys/kernel/debug/dri/*/hdmi*_regs 2>/dev/null`;
 chomp($ram_packet);
 push @out, "RAM_PACKET_CONFIG (bit1=vendor/DV VSIF, bit2=AVI, bit7=DRM/HDR):", ($ram_packet ne "" ? $ram_packet : "(debugfs unavailable)");

	 # Operations file
	 push @out, "", "--- operations.txt ---";
	 push @out, `cat /var/lib/PGenerator/operations.txt 2>/dev/null`; chomp($out[$#out]);

	 # LG display endpoint capabilities
	 push @out, "", "--- LG Display Status API ---";
	 my $lg_status="";
	 $lg_status=&webui_lg_status_json("Diagnostic snapshot") if(defined(&webui_lg_status_json));
	 chomp($lg_status);
	 push @out, ($lg_status ne "") ? $lg_status : "(LG display helper unavailable)";
	 push @out, "", "--- LG Picture Endpoint Capabilities ---";
	 my $lg_caps="";
	 if(defined(&webui_lg_picture_settings) && defined(&lg_encode_json)) {
	  my $keys=defined(&lg_picture_diagnostic_keys) ? &lg_picture_diagnostic_keys() : (defined(&lg_picture_default_keys) ? &lg_picture_default_keys() : []);
	  my $body=&lg_encode_json({ keys => $keys, helper_timeout => 90 });
	  $lg_caps=&webui_lg_picture_settings($body);
	 }
	 chomp($lg_caps);
	 push @out, ($lg_caps ne "") ? $lg_caps : "(LG TV not connected or picture capabilities unavailable)";
	 push @out, "", "--- LG Last Write / Capability Log ---";
	 my $lg_write_log=`tail -n 500 /var/lib/PGenerator/lg/last-write.log 2>/dev/null`; chomp($lg_write_log);
	 push @out, ($lg_write_log ne "") ? $lg_write_log : "(none found)";

	 # Pattern generator state
 push @out, "", "--- Generator Status ---";
 my $pg_status=&pgenerator_cmd("GET_STATUS"); chomp($pg_status);
 my $pg_mode=&pgenerator_cmd("GET_MODE"); chomp($pg_mode);
 push @out, "GET_STATUS: ".($pg_status ne "" ? $pg_status : "(none found)");
 push @out, "GET_MODE: ".($pg_mode ne "" ? $pg_mode : "(none found)");

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
 if(!@infos) {
  push @out, "(none found)";
 }

 # Meter / measurement state
 push @out, "", "--- Meter Session (log tail) ---";
 my $meter_log=`tail -n 500 /tmp/meter_session.log 2>/dev/null`; chomp($meter_log);
 push @out, ($meter_log ne "") ? $meter_log : "(none found)";
 push @out, "", "--- Meter Session Config ---";
 my $meter_cfg=`cat /tmp/meter_session.config 2>/dev/null`; chomp($meter_cfg);
 push @out, ($meter_cfg ne "") ? $meter_cfg : "(none found)";
 push @out, "", "--- Meter Session PID ---";
 my $meter_pid=`cat /tmp/meter_session.pid 2>/dev/null`; chomp($meter_pid);
 push @out, ($meter_pid ne "") ? $meter_pid : "(none found)";
 foreach my $f (qw(/tmp/meter_read.json /tmp/meter_read_steps.json /tmp/meter_series.json /tmp/meter_series_steps.json /tmp/meter_settings.json)) {
  push @out, "", "--- $f ---";
  my $content=`cat $f 2>/dev/null`; chomp($content);
  push @out, ($content ne "") ? $content : "(none found)";
 }
 push @out, "", "--- Meter Series API Status (/api/meter/series/status) ---";
 my $series_status=&webui_meter_series_status(); chomp($series_status);
 push @out, ($series_status ne "") ? $series_status : "(none found)";
 push @out, "", "--- Meter Series Debug Log (/tmp/meter_series_debug.log, last 500 lines) ---";
 my $series_debug=`tail -n 500 /tmp/meter_series_debug.log 2>/dev/null`; chomp($series_debug);
 push @out, ($series_debug ne "") ? $series_debug : "(none found)";

 # LG AutoCal — the last session's worker state and logs. The state
 # JSONs carry the per-IRE adjustment trail (greyscale per-anchor
 # iterations; 3D worker postcal_shadow_pass_N_IRE_X_lift / _counts and
 # the postcal_shadow_zone_IRE_* probe results); the logs carry the
 # per-iteration dE lines. The full-autocal report state is the saved
 # pre/post-cal series reads of the most recent run.
 push @out, "", "--- LG Greyscale AutoCal State (/tmp/meter_lg_autocal.json) ---";
 my $ac1_state=`cat /tmp/meter_lg_autocal.json 2>/dev/null`; chomp($ac1_state);
 push @out, ($ac1_state ne "") ? $ac1_state : "(none found)";
 push @out, "", "--- LG Greyscale AutoCal Log (/tmp/meter_lg_autocal.log, last 2000 lines) ---";
 my $ac1_log=`tail -n 2000 /tmp/meter_lg_autocal.log 2>/dev/null`; chomp($ac1_log);
 push @out, ($ac1_log ne "") ? $ac1_log : "(none found)";
 push @out, "", "--- LG 3D LUT AutoCal State (/tmp/meter_lg_3d_autocal.json) ---";
 my $ac3_state=`cat /tmp/meter_lg_3d_autocal.json 2>/dev/null`; chomp($ac3_state);
 push @out, ($ac3_state ne "") ? $ac3_state : "(none found)";
 push @out, "", "--- LG 3D LUT AutoCal Log (/tmp/meter_lg_3d_autocal.log, last 1000 lines) ---";
 my $ac3_log=`tail -n 1000 /tmp/meter_lg_3d_autocal.log 2>/dev/null`; chomp($ac3_log);
 push @out, ($ac3_log ne "") ? $ac3_log : "(none found)";
 push @out, "", "--- Standalone 3D LUT Solve State (/tmp/lut_solve_state.json) ---";
 my $lut_solve_state=`cat /tmp/lut_solve_state.json 2>/dev/null`; chomp($lut_solve_state);
 push @out, ($lut_solve_state ne "") ? $lut_solve_state : "(none found)";
 push @out, "", "--- Standalone 3D LUT Solve Log (/tmp/lut_solve.log, last 1000 lines) ---";
 my $lut_solve_log=`tail -n 1000 /tmp/lut_solve.log 2>/dev/null`; chomp($lut_solve_log);
 push @out, ($lut_solve_log ne "") ? $lut_solve_log : "(none found)";
 push @out, "", "--- Recent Solved 3D LUT Files ---";
 my $lut_solve_files=`ls -lt /var/lib/PGenerator/lg/luts/*.cube /var/lib/PGenerator/lg/luts/*.3dl /var/lib/PGenerator/lg/luts/*.json 2>/dev/null | head -n 30`; chomp($lut_solve_files);
 push @out, ($lut_solve_files ne "") ? $lut_solve_files : "(none found)";
 # Inline every retained AutoCal run (newest first), each with its full per-
 # session grey/3D logs. PGAutoCalRun retains ten runs; using the same limit
 # here prevents a later SDR attempt from pushing the HDR10 and DV evidence
 # out of the built-in diagnostic report.
 my $_RUN_RECORD_KEEP=10;
 push @out, "", "--- LG Auto Cal Run Records (last $_RUN_RECORD_KEEP) ---";
 my @run_dirs = sort { ((stat($b))[9]||0) <=> ((stat($a))[9]||0) }
  grep { -d $_ } glob("/var/lib/PGenerator/lg/autocal-runs/*");
 if(@run_dirs) {
  my $shown=0;
  for my $rundir (@run_dirs) {
   last if($shown >= $_RUN_RECORD_KEEP);
   $shown++;
   push @out, "", "=== run dir: $rundir ===";
   for my $f (qw(manifest.json summary.json stages.ndjson grey-state.json 3d-state.json dv-profile-measurements.json colour-series.json grey-log.txt 3d-log.txt)) {
    my $path = "$rundir/$f";
    next if(!-f $path);
    my $content = `cat '$path' 2>/dev/null`;
    chomp($content);
    push @out, "", "[$f]";
    push @out, ($content ne "") ? $content : "(empty)";
   }
  }
 } else {
  push @out, "(no autocal run records found)";
 }
 push @out, "", "--- Full AutoCal Report State (latest run: pre/post-cal series reads) ---";
 my @report_files=sort { ((stat($b))[9]||0) <=> ((stat($a))[9]||0) }
  (glob("/var/lib/PGenerator/reports/full-autocal/*.json"),glob("/tmp/PGenerator_full_autocal_reports/*.json"));
 if(scalar(@report_files)) {
  push @out, "File: ".$report_files[0];
  my $report=`cat "$report_files[0]" 2>/dev/null`; chomp($report);
  push @out, ($report ne "") ? $report : "(unreadable)";
 } else {
  push @out, "(no full-autocal report state found)";
 }

 push @out, "", "--- USB / Serial ---";
 my $lsusb=`lsusb 2>/dev/null`; chomp($lsusb);
 push @out, ($lsusb ne "") ? $lsusb : "(none found)";
 my @serial_nodes=glob("/dev/serial/by-id/*");
 if(@serial_nodes) {
  my $serial_index=0;
  foreach my $serial_node (@serial_nodes) {
   $serial_index++;
   my $target=readlink($serial_node);
   $target="" if(!defined($target));
   push @out, "USB serial device $serial_index -> ".($target ne "" ? $target : "(target unavailable)");
  }
 } else {
  push @out, "(none found)";
 }
 my $tty_nodes=`ls -l /dev/ttyACM* /dev/ttyUSB* 2>/dev/null`; chomp($tty_nodes);
 push @out, ($tty_nodes ne "") ? $tty_nodes : "(none found)";
 push @out, "", "--- spotread Version ---";
 my $spot_ver=`spotread -? 2>&1 | head -4`; chomp($spot_ver);
 push @out, ($spot_ver ne "") ? $spot_ver : "(none found)";
 push @out, "", "--- spotread Capabilities ---";
 my $spot_caps=`timeout 5 spotread -D1 -? 2>&1 | tail -40`; chomp($spot_caps);
 push @out, ($spot_caps ne "") ? $spot_caps : "(none found)";
 push @out, "", "--- Meter Correction Profiles ---";
 my $ccss_dir=`ls -la /usr/share/PGenerator/ccss/ 2>/dev/null`; chomp($ccss_dir);
 push @out, ($ccss_dir ne "") ? $ccss_dir : "(none found)";
 my $selected_ccss="";
 my $meter_settings=&read_from_file($_meter_settings_file);
 if($meter_settings ne "" && $meter_settings=~/"ccss_override"\s*:\s*"([^"]+)"/) {
  my $token=$1;
  $selected_ccss=&resolve_ccss_override($token) if(lc($token) ne "none");
 } elsif($meter_settings ne "" && $meter_settings=~/"ccss_file"\s*:\s*"([^"]+)"/) {
  my $ccss_name=$1;
  if($ccss_name=~m{^custom/([A-Za-z0-9._-]+)$}) {
   $selected_ccss="$_custom_ccss_dir/$1";
  } elsif($ccss_name=~m{^ccss_([A-Za-z0-9._-]+)$}) {
   $selected_ccss="$_ccss_dir/$1";
  }
 }
 if($selected_ccss ne "" && -f $selected_ccss) {
  my $ccss_content=&read_from_file($selected_ccss);
  my @ccss_lines=split(/\n/,$ccss_content||"");
  if(@ccss_lines>40) {
   @ccss_lines=@ccss_lines[0..39];
   push @ccss_lines, "...";
  }
  push @out, "", "--- Selected Correction Profile ($selected_ccss) ---";
  push @out, join("\n",@ccss_lines);
 }
 my @csv_candidates=sort { ((stat($b))[9]||0) <=> ((stat($a))[9]||0) } (glob("/var/lib/PGenerator/reports/*.csv"),glob("/var/lib/PGenerator/*.csv"),glob("/tmp/*.csv"));
 if(@csv_candidates) {
  my $latest_csv=$csv_candidates[0];
  my $csv_content=&read_from_file($latest_csv);
  my @csv_lines=split(/\n/,$csv_content||"");
  if(@csv_lines>200) {
   @csv_lines=@csv_lines[0..199];
   push @csv_lines, "...";
  }
  push @out, "", "--- Latest Series CSV ($latest_csv) ---";
  push @out, join("\n",@csv_lines);
 }

 # Syslog (PGenerator entries)
 push @out, "", "--- Syslog (last 500 PGenerator lines) ---";
 push @out, `grep -i PGeneratord /var/log/syslog* /var/log/messages* 2>/dev/null | tail -n 500`;
 chomp($out[$#out]);
 push @out, `tail -n 200 /var/log/daemon.log 2>/dev/null`; chomp($out[$#out]);

 # dmesg tail
 push @out, "", "--- dmesg (last 200 lines) ---";
 push @out, `dmesg | tail -200 2>/dev/null`; chomp($out[$#out]);
 push @out, "", "--- dmesg (USB/serial, last 80) ---";
 my $usb_dmesg=`dmesg 2>/dev/null | grep -iE 'usb|ttyACM|ttyUSB' | tail -n 80`; chomp($usb_dmesg);
 push @out, ($usb_dmesg ne "") ? $usb_dmesg : "(none found)";

 push @out, "", "=" x 72;
 push @out, "  End of diagnostic report";
 push @out, "=" x 72, "";

 my $text=join("\n",@out);
 # Factory/generic hostnames are also the product/process name; replacing every
 # occurrence would corrupt useful labels such as PGenerator.conf and
 # PGeneratord. Custom hostnames are replaced wherever syslog repeats them.
 if($hostname ne "" && lc($hostname) !~ /^(?:pgenerator|raspberrypi|localhost)$/) {
  $text=~s{(?<![A-Za-z0-9_-])\Q$hostname\E(?![A-Za-z0-9_-])}{<hostname>}gi;
 }
 if($diag_wifi_ssid ne "") {
  $text=~s{\Q$diag_wifi_ssid\E}{<ssid>}g;
 }
 $text=&webui_redact_sensitive_log_text($text);
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

 my $cpu_percent=0+($_stats_cpu_last||0);
 my $delta_total=$cpu_total-$_stats_cpu_total;
 my $delta_idle=$cpu_idle-$_stats_cpu_idle;
 if($delta_total > 0) {
  $cpu_percent=0+sprintf("%.1f",100*(($delta_total-$delta_idle)/$delta_total));
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
 my $mem_percent=($mem_total_kb > 0) ? 0+sprintf("%.1f",100*$mem_used_kb/$mem_total_kb) : 0;
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

 my $temperature_raw=&read_from_file($temperature_file);
 $temperature_raw=~s/\s+//g;
 my $temperature=($temperature_raw=~/^\d+$/)
  ? 0+sprintf("%.1f",$temperature_raw/1000)
  : &get_temperature();
 $temperature=~s/[^\d.]//g;
 my $temperature_json=($temperature=~/^\d+(?:\.\d+)?$/)?$temperature:"null";
 my $uptime=&read_from_file($uptime_file);
 ($uptime)=$uptime=~/^([\d.]+)/;
 $uptime=0 if(!defined($uptime) || $uptime!~/^\d+(?:\.\d+)?$/);

 return "{\"cpu_percent\":$cpu_percent,\"cpu_freq_mhz\":$cpu_freq_mhz,\"memory_percent\":$mem_percent,\"memory_used_mb\":$mem_used_mb,\"memory_total_mb\":$mem_total_mb,\"memory_available_mb\":$mem_avail_mb,\"temperature_c\":$temperature_json,\"uptime_seconds\":$uptime,\"load_1\":\"$load_1\",\"load_5\":\"$load_5\",\"load_15\":\"$load_15\"}";
}

sub webui_modes_json (@) {
 my @modes;
 my $now=time();
 return $_modes_cache if($_modes_cache ne "" && ($now - $_modes_cache_time) < $_MODES_CACHE_TTL);
 return ($_modes_cache ne "" ? $_modes_cache : "[]") if(!&webui_hdmi_connected());
  my $output=`timeout 3 $modetest -c 2>/dev/null`;
  return ($_modes_cache ne "" ? $_modes_cache : "[]") if(!defined($output) || $output eq "");
  my %seen;
  # Strict parse: the classic modetest column layout
  # (#idx WxH[i] refresh hdisp hss hse htot vdisp vss vse vtot clock flags:...).
  # This is what every CEA/VIC-advertising display produces, so working
  # monitors are unaffected.
  while($output=~/^\s*#(\d+)\s+(\d+x\d+i?)\s+([\d.]+)\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+(\d+)\s+flags:\s+([^;\n]+)/gm) {
   my ($idx,$res,$hz,$clock,$flags)=($1,$2,$3,$4,$5);
   next if($seen{$idx}++);
   $flags=~s/^\s+|\s+$//g;
   push @modes, "{\"idx\":$idx,\"resolution\":\"$res\",\"refresh\":\"$hz\",\"clock\":$clock,\"flags\":\"$flags\"}";
  }
  # Lenient fallback parse: only when the strict pass found nothing. Some
  # displays (e.g. pure DVI/DMT monitors that advertise no CEA VICs, or
  # different libdrm modetest builds) emit mode lines the strict regex
  # misses, which left the resolution dropdown empty even though real KMS
  # modes exist. Match the same fields loosely: the last integer before
  # "flags:" is the pixel clock. These are still REAL connector-mode
  # indices, so selecting one actually switches the display.
  if(!@modes){
   while($output=~/^\s*#?(\d+)\s+(\d+x\d+i?)\s+([\d.]+)\s+[^\n]*?(\d+)\s+flags:\s+([^;\n]+)/gm) {
    my ($idx,$res,$hz,$clock,$flags)=($1,$2,$3,$4,$5);
    next if($seen{$idx}++);
    $flags=~s/^\s+|\s+$//g;
    push @modes, "{\"idx\":$idx,\"resolution\":\"$res\",\"refresh\":\"$hz\",\"clock\":$clock,\"flags\":\"$flags\"}";
   }
  }
  my $json="[".join(",",@modes)."]";
 if(@modes) {
  $_modes_cache=$json;
  $_modes_cache_time=$now;
 }
 return $json;
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
 my $edid_decode_available=(-x $edidparser) ? 1 : 0;
 my $edid_parsed=0;
 my $kms_output_format=0;
 my $kms_dovi_output_metadata=0;
 my %vic_420; # "WxH@HZi" => 1

 if($is_kms) {
  my $mt=`timeout 5 $modetest -a -c 2>/dev/null`;
  $kms_output_format=1 if($mt=~/\boutput format\b/);
  $kms_dovi_output_metadata=1 if($mt=~/\bDOVI_OUTPUT_METADATA\b/);
 }

 if($edid_decode_available && $edid_path ne "" && -e $edid_path) {
  my $e=`timeout 5 $edidparser $edid_path 2>/dev/null`;
  $edid_parsed=1 if(defined($e) && $e ne "");

  # Base color format support (CTA header)
  $has_444=1 if($e=~/(?:Supports\s+)?YCbCr\s+4:4:4/i);
  $has_422=1 if($e=~/(?:Supports\s+)?YCbCr\s+4:2:2/i);

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
 $dc_420_10=0;
 $dc_420_12=0;
 %vic_420=();
 my @v420=map{"\"$_\""} sort keys %vic_420;

	 my $dv_transport_is_ll=&pg_dv_transport_ll_flag();
	 my $dv_transport_is_std=&pg_dv_transport_std_flag();
	 my $dv_transport_interface=&pg_dv_transport_interface();
	 my $dv_transport_color_format=&pg_dv_transport_color_format();
	 my $dv_transport_max_bpc=&pg_dv_transport_max_bpc();
	 my $dv_transport_mode=&pg_dv_transport_mode();
	 my $dv_transport_modes='"standard","lldv"';

		 return "{\"dc_30bit\":".($dc_30?"true":"false")
		  .",\"dc_36bit\":".($dc_36?"true":"false")
	  .",\"dc_y444\":".($dc_y444?"true":"false")
  .",\"dc_420_10bit\":".($dc_420_10?"true":"false")
  .",\"dc_420_12bit\":".($dc_420_12?"true":"false")
  .",\"max_tmds\":$max_tmds"
  .",\"scdc\":".($scdc?"true":"false")
  .",\"kms_output_format\":".($kms_output_format?"true":"false")
  .",\"kms_dovi_output_metadata\":".($kms_dovi_output_metadata?"true":"false")
  .",\"has_ycbcr444\":".($has_444?"true":"false")
  .",\"has_ycbcr422\":".($has_422?"true":"false")
  .",\"has_hdr_st2084\":".($has_st2084?"true":"false")
  .",\"has_hdr_hlg\":".($has_hlg?"true":"false")
		  .",\"has_dv\":".($has_dv?"true":"false")
		  .",\"dv_444_10b12b\":".($dv_444_10b12b?"true":"false")
		  .",\"dv_transport_is_ll_dovi\":\"$dv_transport_is_ll\""
		  .",\"dv_transport_is_std_dovi\":\"$dv_transport_is_std\""
		  .",\"dv_transport_interface\":\"$dv_transport_interface\""
		  .",\"dv_transport_color_format\":\"$dv_transport_color_format\""
		  .",\"dv_transport_max_bpc\":\"$dv_transport_max_bpc\""
		  .",\"dv_transport\":\"$dv_transport_mode\""
		  .",\"dv_transport_modes\":[$dv_transport_modes]"
	  .",\"edid_decode_available\":".($edid_decode_available?"true":"false")
  .",\"edid_parsed\":".($edid_parsed?"true":"false")
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
 my $raw=&sudo("WIFI_APPLYCONF","wlan0",$ssid,$psk||"");
 chomp($raw);
 if($raw!~/^OK\b/) {
  $raw=~s/^ERR:?//;
  $raw=&_webui_json_escape($raw||"WiFi connection failed");
  return "{\"status\":\"error\",\"message\":\"$raw\"}";
 }
 my $safe_ssid=&_webui_json_escape($ssid);
 my $ip="";
 $ip=$1 if($raw=~/^ip_address=([0-9.]+)/m);
 my $message=($ip ne "") ? "Connected to $safe_ssid" : "Connecting to $safe_ssid";
 return "{\"status\":\"ok\",\"message\":\"$message\",\"ip\":\"$ip\"}";
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
 my $raw=&sudo("WIFI_AP_APPLYCONF","$ssid","$pass");
 chomp($raw);
 if($raw=~/^OK/) {
  return '{"status":"ok","message":"WiFi AP updated and restarted"}';
 }
 $raw=~s/^ERR:?//;
 $raw=&_webui_json_escape($raw||"WiFi AP apply failed");
 return '{"status":"error","message":"'.$raw.'"}';
}

sub webui_wifi_ap_control (@) {
 my $action=shift;
 my $raw="";
 if($action eq "enable") {
  $raw=&sudo("WIFI_AP_ENABLE","wlan0");
 } elsif($action eq "disable") {
  $raw=&sudo("WIFI_AP_DISABLE");
 } else {
  return '{"status":"error","message":"Unknown AP action"}';
 }
 chomp($raw);
 if($raw=~/^OK/) {
  # Persist the desired AP state so it survives reboot (issue #22).
  &sudo("SET_PGENERATOR_CONF","wifi_ap",($action eq "enable")?"1":"0");
  return '{"status":"ok","message":"WiFi AP '.$action.'d"}';
 }
 $raw=~s/^ERR:?//;
 $raw=&_webui_json_escape($raw||"WiFi AP $action failed");
 return '{"status":"error","message":"'.$raw.'"}';
}

sub webui_wifi_ap_status_json (@) {
 my $raw=&sudo("WIFI_AP_STATUS");
 my %kv;
 foreach my $line (split(/\n/,$raw)) {
  if($line=~/^([A-Z_]+)=(.*)$/) { $kv{$1}=$2; }
 }
 my $available=($kv{AP_AVAILABLE} && $kv{AP_AVAILABLE} eq "1") ? "true" : "false";
 my $active=($kv{AP_ACTIVE} && $kv{AP_ACTIVE} eq "1") ? "true" : "false";
 my $dnsmasq_available=($kv{DNSMASQ_AVAILABLE} && $kv{DNSMASQ_AVAILABLE} eq "1") ? "true" : "false";
 my $dnsmasq_active=($kv{DNSMASQ_ACTIVE} && $kv{DNSMASQ_ACTIVE} eq "1") ? "true" : "false";
 my $gateway_ready=($kv{AP_GATEWAY_READY} && $kv{AP_GATEWAY_READY} eq "1") ? "true" : "false";
 my $iface=&_webui_json_escape($kv{AP_INTERFACE}||"");
 my $ap_net=&_webui_json_escape($kv{AP_NET}||"10.10.10");
 my $address=&_webui_json_escape($kv{AP_ADDRESS}||(($kv{AP_NET}||"10.10.10").".1"));
 return "{\"status\":\"ok\",\"available\":$available,\"active\":$active,\"interface\":\"$iface\",\"ap_net\":\"$ap_net\",\"address\":\"$address\",\"gateway_ready\":$gateway_ready,\"dnsmasq_available\":$dnsmasq_available,\"dnsmasq_active\":$dnsmasq_active}";
}

sub webui_wifi_status_json (@) {
 my $status=&sudo("GET_WIFI_STATUS","wlan0");
 my %info;
 foreach my $line (split(/\n/,$status)) {
  if($line=~/^(\w+)\s*=\s*(.*)/) { $info{$1}=$2; }
 }
 my $ssid=$info{ssid}||"";
 $ssid=&_webui_json_escape($ssid);
 my $state=$info{wpa_state}||"UNKNOWN";
 my $freq=$info{freq}||"";
 my $ip=$info{ip_address}||&webui_mdns_iface_ip("wlan0")||"";
 my $bssid=$info{bssid}||"";
 # Get signal strength via iw
 my $signal="";
 my $iw_out=`timeout 3 iw dev wlan0 station dump 2>/dev/null`;
 if($iw_out=~/signal:\s*(-?\d+)/){ $signal=$1; }
 my $band="";
 if($freq=~/^\d+$/) {
  $band=($freq>=5000)?"5 GHz":"2.4 GHz";
 }
 $state=&_webui_json_escape($state);
 $freq=&_webui_json_escape($freq);
 $band=&_webui_json_escape($band);
 $signal=&_webui_json_escape($signal);
 $ip=&_webui_json_escape($ip);
 $bssid=&_webui_json_escape($bssid);
 return "{\"status\":\"ok\",\"wpa_state\":\"$state\",\"ssid\":\"$ssid\",\"freq\":\"$freq\",\"band\":\"$band\",\"signal\":\"$signal\",\"ip\":\"$ip\",\"bssid\":\"$bssid\"}";
}

sub webui_wifi_radio_status_json (@) {
 my $raw=&sudo("WIFI_RADIO_STATUS");
 my %kv;
 foreach my $line (split(/\n/,$raw)) {
  if($line=~/^([A-Z_]+)=(.*)$/) { $kv{$1}=$2; }
 }
 my $available=($kv{WIFI_RADIO_AVAILABLE} && $kv{WIFI_RADIO_AVAILABLE} eq "1") ? "true" : "false";
 my $blocked=($kv{WIFI_BLOCKED} && $kv{WIFI_BLOCKED} eq "1") ? "true" : "false";
 return "{\"status\":\"ok\",\"available\":$available,\"blocked\":$blocked}";
}

sub webui_wifi_radio_control (@) {
 my ($body)=@_;
 my $enabled=($body=~/"(?:enabled|value|on)"\s*:\s*(true|1|"true"|"1"|"on")/i) ? "on" : "off";
 my $raw=&sudo("WIFI_RADIO",$enabled);
 chomp($raw);
 if($raw=~/^OK/) {
  # Persist the desired radio state so it survives reboot (issue #22).
  &sudo("SET_PGENERATOR_CONF","wifi_radio",($enabled eq "on")?"1":"0");
  # Disabling the WiFi radio also stops the AP (they share one radio).
  # The AP can't beacon on a blocked radio; stop hostapd and persist the
  # AP state too so both stay off across reboot.
  if($enabled eq "off") {
   &sudo("WIFI_AP_DISABLE");
   &sudo("SET_PGENERATOR_CONF","wifi_ap","0");
  }
  return '{"status":"ok","message":"WiFi radio '.($enabled eq "on" ? "enabled" : "disabled").'"}';
 }
 $raw=~s/^ERR:?//;
 $raw=&_webui_json_escape($raw||"WiFi radio change failed");
 return '{"status":"error","message":"'.$raw.'"}';
}

sub webui_bluetooth_status_json (@) {
 my $raw=&sudo("BT_STATUS");
 my %kv;
 foreach my $line (split(/\n/,$raw)) {
  if($line=~/^([A-Z_]+)=(.*)$/) { $kv{$1}=$2; }
 }
 my ($adapter)="";
 if($raw=~/ADAPTER_BEGIN\n(.*?)\nADAPTER_END/s) { $adapter=$1; }
 my ($devices_raw)="";
 if($raw=~/DEVICES_BEGIN\n(.*?)\nDEVICES_END/s) { $devices_raw=$1; }
 my ($pan_raw)="";
 if($raw=~/PAN_BEGIN\n(.*?)\nPAN_END/s) { $pan_raw=$1; }

 # Derive powered from the bluez adapter "Powered" flag (authoritative) or the
 # HCI adapter UP/DOWN flag. Scope the UP check to the HCI block only: a raw-wide
 # /\bUP\b/ match also caught the bnep PAN interface's "UP" and falsely reported
 # the adapter as powered while hci0 was DOWN.
 my $hci_block=""; $hci_block=$1 if($raw=~/HCI_BEGIN\n(.*?)\nHCI_END/s);
 my $powered="false";
 if($adapter=~/Powered\s*[:=]\s*(?:yes|1)\b/i) { $powered="true"; }
 elsif($adapter=~/Powered\s*[:=]\s*(?:no|0)\b/i) { $powered="false"; }
 elsif($hci_block=~/\bUP\b/i) { $powered="true"; }
 $powered="false" if($kv{SOFT_BLOCKED} && $kv{SOFT_BLOCKED} eq "1");
 my $discoverable=($adapter=~/Discoverable:\s*yes/i) ? "true" : "false";
 my $agent=($kv{AGENT} && $kv{AGENT} eq "1") ? "true" : "false";
  # PAN "Running" means the NAP service (or an active bnep client link) is up —
  # not merely that the pan0 bridge still has an address after the radio is
  # powered off. With Power Off, always report PAN stopped. Require BOTH the
  # daemon's NAP_RUNNING flag AND a bnep interface — the bnep name alone can
  # persist in the kernel after the radio goes down, so an OR used to falsely
  # report Running until the next refresh.
  my $pan_running="false";
  if($powered eq "true") {
   if(($kv{NAP_RUNNING} && $kv{NAP_RUNNING} eq "1") && $pan_raw=~/\bbnep\d+\b/s) { $pan_running="true"; }
  }
 my $available=(($kv{BLUETOOTHCTL_AVAILABLE} && $kv{BLUETOOTHCTL_AVAILABLE} eq "1") || $raw=~/HCI_BEGIN\n.+?\nHCI_END/s) ? "true" : "false";
 my $pan_available=(($kv{PAND_AVAILABLE} && $kv{PAND_AVAILABLE} eq "1") || ($kv{BT_NETWORK_AVAILABLE} && $kv{BT_NETWORK_AVAILABLE} eq "1")) ? "true" : "false";
 my $pan_net=&_webui_json_escape($kv{PAND_NET}||"10.10.11");
 my @devices;
 foreach my $line (split(/\n/,$devices_raw)) {
  next if($line=~/^\s*$/);
  my ($mac,$name);
  if($line=~/Device\s+(([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2})\s+(.+)/) {
   $mac=$1; $name=$3;
  } elsif($line=~/(([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2})\s+(.+)/) {
   $mac=$1; $name=$3;
  }
  next if(!$mac);
  $mac=&_webui_json_escape($mac);
  $name=&_webui_json_escape($name||"");
  push @devices, "{\"mac\":\"$mac\",\"name\":\"$name\"}";
 }
 return "{\"status\":\"ok\",\"available\":$available,\"powered\":$powered,\"discoverable\":$discoverable,\"agent\":$agent,\"pan_running\":$pan_running,\"pan_available\":$pan_available,\"pan_net\":\"$pan_net\",\"devices\":[".join(",",@devices)."]}";
}

sub webui_bluetooth_bool_control (@) {
 my ($body,$cmd,$label)=@_;
 my $enabled=($body=~/"(?:enabled|value|on)"\s*:\s*(true|1|"true"|"1"|"on")/i) ? "on" : "off";
 my $raw=&sudo($cmd,$enabled);
 chomp($raw);
 if($raw=~/^OK/) {
  # Persist the BT power state so it survives reboot (issue #22). Only the
  # power toggle is persisted; discoverable/agent are session settings.
  &sudo("SET_PGENERATOR_CONF","bt_powered",($enabled eq "on")?"1":"0") if($cmd eq "BT_SET_POWERED");
  return '{"status":"ok","message":"'.&_webui_json_escape($label)." ".$enabled.'"}';
 }
 $raw=~s/^ERR:?//;
 $raw=&_webui_json_escape($raw||"$label failed");
 return '{"status":"error","message":"'.$raw.'"}';
}

sub webui_bluetooth_set_name (@) {
 my $body=shift;
 my ($name)=$body=~/"name"\s*:\s*"([^"]*)"/;
 $name=~s/[^a-zA-Z0-9_ -]//g if(defined $name);
 return '{"status":"error","message":"Name required"}' if(!defined $name || $name eq "");
 my $raw=&sudo("BT_SET_NAME",$name);
 chomp($raw);
 if($raw=~/^OK/) {
  return '{"status":"ok","message":"Bluetooth name updated"}';
 }
 $raw=~s/^ERR:?//;
 $raw=&_webui_json_escape($raw||"Bluetooth name update failed");
 return '{"status":"error","message":"'.$raw.'"}';
}

sub webui_bluetooth_pan_restart (@) {
 my $raw=&sudo("BT_RESTART_PAN");
 chomp($raw);
 if($raw=~/^OK/) {
  return '{"status":"ok","message":"Bluetooth PAN restarted"}';
 }
 $raw=~s/^ERR:?//;
 $raw=&_webui_json_escape($raw||"Bluetooth PAN restart failed");
 return '{"status":"error","message":"'.$raw.'"}';
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

sub webui_cec_power_label (@) {
 my $power=shift;
 return "unknown" if(!defined($power));
 $power=lc("".$power);
 $power=~s/^\s+//;
 $power=~s/\s+$//;
 return "on" if($power eq "0" || $power eq "on");
 return "standby" if($power eq "1" || $power eq "standby");
 return "powering-on" if($power eq "2" || $power eq "powering-on");
 return "powering-off" if($power eq "3" || $power eq "powering-off");
 return "unknown";
}

sub webui_cec_status_json (@) {
 my ($power,$phys,$log,$osd,$driver)=@_;
 $power=&webui_cec_power_label($power);
 $phys=&_webui_json_escape(defined($phys) ? $phys : "");
 $log=&_webui_json_escape(defined($log) ? $log : "");
 $osd=&_webui_json_escape(defined($osd) ? $osd : "");
 $driver=&_webui_json_escape(defined($driver) ? $driver : "");
 return "{\"status\":\"ok\",\"tv_power\":\"$power\",\"phys_addr\":\"$phys\",\"log_addr\":\"$log\",\"osd_name\":\"$osd\",\"driver\":\"$driver\"}";
}

sub webui_cec_scan_cache_info (@) {
 my $cec_scan_cache=shift;
 my ($cached_phys,$cached_log,$cached_osd,$cached_power)=("","","","unknown");
 my $cache_age=(-f $cec_scan_cache) ? (time() - ((stat($cec_scan_cache))[9]||0)) : 999999;
 if(-f $cec_scan_cache) {
  my $json="";
  if(open(my $fh,"<",$cec_scan_cache)) {
   local $/;
   $json=<$fh>;
   close($fh);
  }
  my ($self_obj)=($json =~ /"self"\s*:\s*(\{[^{}]*\})/);
  my ($self_phys)=($json =~ /"self"\s*:\s*\{[^{}]*"phys"\s*:\s*"([^"]+)"/);
  my $self_log="";
  if(defined($self_obj) && $self_obj ne "") {
   ($self_log)=($self_obj =~ /"(?:log|addr)"\s*:\s*"?([^",}\s]+)"?/);
   $self_log="" if(!defined($self_log));
  }
  my ($tv_obj)=($json =~ /(\{[^{}]*"type"\s*:\s*0[^{}]*\})/);
  if(!defined($tv_obj) || $tv_obj eq "") {
   ($tv_obj)=($json =~ /(\{[^{}]*"addr"\s*:\s*0[^{}]*\})/);
  }
  if(defined($tv_obj) && $tv_obj ne "") {
   ($cached_phys)=($tv_obj =~ /"phys"\s*:\s*"([^"]+)"/);
   ($cached_log)=($tv_obj =~ /"addr"\s*:\s*(\d+)/);
   ($cached_osd)=($tv_obj =~ /"name"\s*:\s*"([^"]*)"/);
   my ($power)=($tv_obj =~ /"power"\s*:\s*"?([^",}\s]+)"?/);
   $cached_power=&webui_cec_power_label($power);
  }
  $cached_phys=$self_phys if((!defined($cached_phys) || $cached_phys eq "" || $cached_phys eq "0.0.0.0") && defined($self_phys));
  $cached_log=$self_log if(defined($self_log) && $self_log ne "");
 }
 $cached_phys="" if(!defined($cached_phys));
 $cached_log="" if(!defined($cached_log));
 $cached_osd="" if(!defined($cached_osd));
 return ($cached_phys,$cached_log,$cached_osd,$cached_power,$cache_age);
}

sub webui_cec_direct_status (@) {
 my ($cec_bin,$timeout,$want_power)=@_;
 $timeout=2 if(!defined($timeout) || $timeout !~ /^\d+$/ || $timeout < 1);
 # Try the configured CEC binary first (pgcec), then fall back to
 # pgenerator-cec (the python2 self-contained CEC helper that talks
 # directly to /dev/cec0 without requiring cec-ctl). On Biasi images
 # cec-ctl is not installed, so pgenerator-cec is the only path that
 # actually returns real TV power state.
 #
 # $want_power controls the blocking GIVE_DEVICE_POWER_STATUS query. With
 # $want_power FALSE we pass --no-power (instant, returns "(skipped)") for
 # callers that only need phys/log/osd. With $want_power TRUE we let the
 # helper query real power; its internal timeout is now 500ms (commit
 # 32978694), so a live query returns in well under a second even when the
 # TV is off. The status path gates real-power queries with a per-process
 # throttle ($_CEC_POWER_QUERY_THROTTLE) so the single-threaded webui never
 # pays more than one such query every few seconds.
 my $power_arg=$want_power ? "" : " --no-power";
 my $output=`timeout $timeout $cec_bin status$power_arg 2>/dev/null`;
 if((!defined($output) || $output eq "" || $output !~ /^tv_power:/m) && -x "/usr/sbin/pgenerator-cec") {
  $output=`timeout $timeout /usr/sbin/pgenerator-cec status$power_arg 2>/dev/null`;
 }
 return undef if(!defined($output) || $output eq "");
 # When --no-power is used pgenerator-cec prints "tv_power:  (skipped)"
 # Treat that as "use the cache" — don't pretend we have new info.
 if($output =~ /^tv_power:\s+\(skipped\)/m) {
  return undef;
 }
 my ($power)=($output =~ /^tv_power:\s*([^\r\n]+)/m);
 $power=&webui_cec_power_label($power);
 return undef if($power eq "unknown");
 # Accept both "physical_addr" (pgcec) and "phys_addr" (pgenerator-cec).
 my ($phys)=($output =~ /^(?:physical_addr|phys_addr):\s*([^\r\n]+)/m);
 # Accept both "logical_addr" (pgcec) and "log_addrs" (pgenerator-cec);
 # for "log_addrs" the value may include a mask like "1 [1] (mask=0x2)" so
 # we extract just the leading address.
 my ($log)="";
 if($output =~ /^logical_addr:\s*(\d+)/m) {
  $log=$1;
 } elsif($output =~ /^log_addrs:\s*(\d+)/m) {
  $log=$1;
 }
 my ($osd)=($output =~ /^osd_name:\s*([^\r\n]+)/m);
 $phys="" if(!defined($phys));
 $log="" if(!defined($log));
 $osd="" if(!defined($osd));
 return { tv_power=>$power, phys_addr=>$phys, log_addr=>$log, osd_name=>$osd };
}

sub webui_cec_power_cache_write (@) {
 my ($path,$power,$phys,$log,$osd)=@_;
 return if(!$path);
 my $json=&webui_cec_status_json($power,$phys,$log,$osd,"cec-status-cache");
 if(open(my $fh,">",$path)) {
  print $fh $json;
  close($fh);
 }
}

sub webui_cec_power_cache_read (@) {
 my ($path,$max_age)=@_;
 return undef if(!$path || !-f $path);
 my $age=time() - ((stat($path))[9]||0);
 return undef if(defined($max_age) && $age > $max_age);
 my $json="";
 if(open(my $fh,"<",$path)) {
  local $/;
  $json=<$fh>;
  close($fh);
 }
 my ($power)=($json =~ /"tv_power"\s*:\s*"([^"]+)"/);
 $power=&webui_cec_power_label($power);
 return undef if($power eq "unknown");
 my ($phys)=($json =~ /"phys_addr"\s*:\s*"([^"]*)"/);
 my ($log)=($json =~ /"log_addr"\s*:\s*"([^"]*)"/);
 my ($osd)=($json =~ /"osd_name"\s*:\s*"([^"]*)"/);
 return { tv_power=>$power, phys_addr=>($phys||""), log_addr=>($log||""), osd_name=>($osd||""), cache_age=>$age };
}

sub webui_cec (@) {
 my $cmd=shift;
 my $cec_bin="/usr/bin/pgcec";
 my $cec_scan_cache="/tmp/pgenerator-cec-scan.json";
 my $cec_scan_lock="/tmp/pgenerator-cec-status.lock";
 my $cec_power_cache="/tmp/pgenerator-cec-power.json";
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
   my $json=`timeout 12 $cec_bin scan-json 2>/dev/null`;
   my $rc=$?>>8;
   chomp($json);
   $json=~s/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]//g;
   if($rc == 0 && $json=~/^\{/) {
    # Always make sure the response includes a "self" entry with our own
    # OSD/phys/log so the frontend's device table shows us, even if the
    # bus poll found no other devices. Also inject a placeholder TV (LA 0)
    # so the table is never empty when a TV is plausibly there.
    my $enriched=$json;
    if($enriched !~ /"self"\s*:/) {
     my $scan_out=`timeout 2 /usr/sbin/pgenerator-cec status --no-power 2>/dev/null`;
     if(defined($scan_out) && $scan_out ne "") {
      my ($phys)=($scan_out =~ /^phys_addr:\s*([^\s]+)/m);
      my ($la)=($scan_out =~ /^log_addrs:\s*\d+\s*\[\s*(\d+)\s*\]\s*\(mask=0x[0-9a-fA-F]+\)/m);
      my ($osd)=($scan_out =~ /^osd_name:\s*([^\r\n]+)/m);
      $phys="" if(!defined($phys));
      $la="" if(!defined($la));
      $osd="" if(!defined($osd));
      $osd =~ s/\s+$//;
      my $self_la=($la ne "") ? $la : 15;
      my $self_phys=($phys ne "") ? $phys : "0.0.0.0";
      $enriched =~ s/^\{/sprintf('{"self":{"phys":"%s","addr":%s,"log":%s,"osd":"%s"},', $self_phys, $self_la, $self_la, ($osd||"PGenerator"))/e;
     }
    } else {
     # pgcec scan-json already includes self — make sure it has a "log"
     # field too because the JS frontend reads both addr and log. We
     # append "log":N right after the "addr":N entry using a non-greedy
     # match so we don't accidentally swallow fields that come after
     # addr in the self object (e.g. phys, osd).
     if($enriched =~ /"self"\s*:\s*\{[^}]*"addr"\s*:\s*(\d+)[^}]*\}/ && $enriched !~ /"self"\s*:\s*\{[^}]*"log"\s*:/) {
      $enriched =~ s/("addr"\s*:\s*(\d+)(?=\s*,|\s*\}))/"addr":$2,"log":$2/g;
     }
    }
    # Inject a TV placeholder if no TV was found in devices[] and no
    # "tv" key already exists
    if($enriched !~ /"tv"\s*:/ && $enriched !~ /"addr"\s*:\s*0/) {
     # Find a self phys to copy
     my ($self_phys)=$enriched =~ /"self"[^}]*"phys"\s*:\s*"([^"]+)"/;
     $self_phys="0.0.0.0" if(!defined($self_phys));
     # Inject a TV entry into devices. Handle both empty and non-empty
     # device arrays, and strip any trailing comma we introduce.
     if($enriched =~ /"devices"\s*:\s*\[\s*\]/) {
      # Empty devices array — replace with [TV_entry] (no power field so
      # the JS renders "?" instead of hardcoding "Standby" — the scan
      # didn't actually query the TV).
      $enriched =~ s/"devices"\s*:\s*\[\s*\]/"devices":\[{"addr":0,"type":0,"name":"TV","phys":"$self_phys","vendor":""}\]/;
     } elsif($enriched =~ /"devices"\s*:\s*\[/) {
      # Non-empty devices array — prepend a TV entry (followed by a comma)
      my $tv_entry='{"addr":0,"type":0,"name":"TV","phys":"' . $self_phys . '","vendor":""},';
      $enriched =~ s/("devices"\s*:\s*\[)/$1$tv_entry/;
     }
    }
    if(open(my $fh,">",$cec_scan_cache)) {
     print $fh $enriched;
     close($fh);
    }
    return "{\"status\":\"ok\",\"data\":$enriched}";
	  } else {
	   # pgcec scan-json is broken on Biasi (no python3 + missing --list-devices
	   # in cec-ctl 1.12). Fall back to a quick pgenerator-cec status scan
	   # which always works and gives us phys_addr/log_addrs/osd_name.
	   my $scan_out=`timeout 3 /usr/sbin/pgenerator-cec status --no-power 2>/dev/null`;
	   my $fallback="";
	   if(defined($scan_out) && $scan_out ne "") {
	    my ($phys)=($scan_out =~ /^phys_addr:\s*([^\s]+)/m);
	    my ($la)=($scan_out =~ /^log_addrs:\s*\d+\s*\[\s*(\d+)\s*\]\s*\(mask=0x[0-9a-fA-F]+\)/m);
	    my ($osd)=($scan_out =~ /^osd_name:\s*([^\r\n]+)/m);
	    $phys="" if(!defined($phys));
	    $la="" if(!defined($la));
	    $osd="" if(!defined($osd));
	    $osd =~ s/\s+$//;
	    # Build a minimal pgcec-style JSON for the cache. The frontend's
	    # cecScan() iterates over data.devices; we include just ourselves
	    # plus a placeholder TV entry (the kernel doesn't enumerate other
	    # devices from a single CEC_TRANSMIT poll, but we know our own
	    # LA and the TV's LA is always 0).
	    my $self_la=($la ne "") ? $la : 15;
	    my $self_phys=($phys ne "") ? $phys : "0.0.0.0";
	    $fallback=sprintf(
	      '{"self":{"phys":"%s","log":%s,"osd":"%s"},' .
	      '"tv":{"addr":0,"phys":"%s","log":0,"name":"%s","type":0},' .
	      '"devices":[{"addr":%s,"type":4,"name":"%s","phys":"%s","vendor":""},{"addr":0,"type":0,"name":"TV","phys":"%s","vendor":""}]}',
	      $self_phys, $self_la, ($osd||"PGenerator"),
	      $self_phys, ($osd||"PGenerator"),
	      $self_la, ($osd||"PGenerator"), $self_phys, $self_phys);
	    if($fallback=~/^\{/) {
	     if(open(my $fh,">",$cec_scan_cache)) {
	      print $fh $fallback;
	      close($fh);
	     }
	     return "{\"status\":\"ok\",\"data\":$fallback}";
	    }
	   }
	   $json=&_webui_json_escape($json);
	   return "{\"status\":\"error\",\"message\":\"Scan failed\",\"output\":\"$json\"}";
	  }
  }
	 # status returns structured JSON
	 if($cmd eq "status") {
	  my ($cached_phys,$cached_log,$cached_osd,$cached_power,$cache_age)=&webui_cec_scan_cache_info($cec_scan_cache);
	  my $cached_status=&webui_cec_power_cache_read($cec_power_cache,60);
	  my $direct=undef;
	  # Live TV power query, throttled so the single-threaded webui pays at
	  # most one ~500ms CEC power query every few seconds; between queries (or
	  # when the query gets no reply) we fall through to the cached reading
	  # below. The prior --no-power-only status path could never read live
	  # power, so the label was stuck "unknown" whenever the scan/power caches
	  # went cold (e.g. after a reboot cleared /tmp), even with the TV on.
	  if(time() - $_cec_last_power_query >= $_CEC_POWER_QUERY_THROTTLE) {
	   $_cec_last_power_query=time();
	   # 1s spawn bound (was 2s): with the TV off both helpers run to
	   # their timeout, and this path executes inside the daemon's only
	   # request thread -- every extra second here is a second the whole
	   # WebUI is frozen.
	   $direct=&webui_cec_direct_status($cec_bin,1,1);
	  }
	  if(ref($direct) eq "HASH") {
	   my $phys=($direct->{"phys_addr"}||$cached_phys||"");
	   my $log=($direct->{"log_addr"}||$cached_log||"");
	   my $osd=($direct->{"osd_name"}||$cached_osd||"");
	   if(ref($cached_status) eq "HASH") {
	    my $pending_power=$cached_status->{"tv_power"}||"";
	    my $pending_age=$cached_status->{"cache_age"}||999999;
	    if($pending_power eq "powering-on" && $direct->{"tv_power"} eq "standby" && $pending_age < 45) {
	     return &webui_cec_status_json("powering-on",$phys,$log,$osd,"cec-wake-pending");
	    }
	    if($pending_power eq "powering-off" && $direct->{"tv_power"} eq "on" && $pending_age < 20) {
	     return &webui_cec_status_json("powering-off",$phys,$log,$osd,"cec-standby-pending");
	    }
	   }
	   &webui_cec_power_cache_write($cec_power_cache,$direct->{"tv_power"},$phys,$log,$osd);
	   return &webui_cec_status_json($direct->{"tv_power"},$phys,$log,$osd,"cec-status-direct");
	  }
	  if($cache_age <= 30 && $cached_power ne "unknown") {
	   &webui_cec_power_cache_write($cec_power_cache,$cached_power,$cached_phys,$cached_log,$cached_osd);
	   return &webui_cec_status_json($cached_power,$cached_phys,$cached_log,$cached_osd,"cec-scan-cache");
	  }
	  if(ref($cached_status) eq "HASH") {
	   return &webui_cec_status_json($cached_status->{"tv_power"},$cached_status->{"phys_addr"},$cached_status->{"log_addr"},$cached_status->{"osd_name"},"cec-status-cache");
	  }
	  if(!&webui_hdmi_connected()) {
	   return &webui_cec_status_json("unknown","","","","");
	  }
	  if($cache_age <= 30 && ($cached_phys ne "" || $cached_log ne "" || $cached_osd ne "")) {
	   return &webui_cec_status_json("unknown",$cached_phys,$cached_log,$cached_osd,"cec-cache");
	  }
	  return &webui_cec_status_json("unknown",$cached_phys,$cached_log,$cached_osd,"cec-status-background");
	 }
 if($cmd =~ /^(?:active|input|volup|voldown|mute)$/ && defined(&webui_lg_cec_fallback)) {
  my $lg_result=&webui_lg_cec_fallback($cmd);
  if(ref($lg_result) eq "HASH" && ($lg_result->{"status"}||"") eq "ok") {
   my $message=$lg_result->{"message"}||"LG WebOS display control sent.";
   return &lg_encode_json({
    status => "ok",
    output => $message,
    lg_webos_fallback => &lg_json_true(),
    lg_result => $lg_result,
   });
  }
 }
# action commands. Try the configured CEC binary first (pgcec -> cec-ctl),
  # then fall back to pgenerator-cec (the python2 self-contained CEC helper
  # that uses the Linux CEC ioctl API directly). On Biasi images cec-ctl
  # is not installed, so pgenerator-cec is the path that actually sends
  # the CEC frames. Only `on`/`off` are routed to pgenerator-cec; the
  # more exotic commands (`volup`/`voldown`/`mute`) require cec-ctl and
  # are unreachable on Biasi images.
  my $output;
  my $rc;
  if($cmd =~ /^(?:on|off|as|wake)$/ && -x "/usr/sbin/pgenerator-cec") {
   my $pgc_cmd=$cmd;
   $pgc_cmd="on" if($cmd eq "wake");
   $pgc_cmd="as" if($cmd eq "active");
   $output=`timeout 8 /usr/sbin/pgenerator-cec $pgc_cmd 2>&1`;
   $rc=$?>>8;
   # pgenerator-cec prints OK on a successful transmit, FAILED/PARTIAL
   # on a failed transmit. It always exits 0 — we have to look at the
   # output to know whether the wire frame was actually acknowledged.
   # Treat anything that doesn't start with "OK" (after trimming) as a
   # failure and bubble it up to the frontend as an error.
   my $pgc_out=$output;
   $pgc_out=~s/^\s+|\s+$//gs;
   if($pgc_out eq "OK") {
    $output="OK\n";
    $rc=0;
   } else {
    # FAILED / PARTIAL / empty / timeout / EBUSY
    $rc=1;
    $output="pgenerator-cec $pgc_cmd: $pgc_out\n" if($pgc_out ne "");
   }
  } else {
   $output=`timeout 8 $cec_bin $cmd 2>&1`;
   $rc=$?>>8;
  }
  $output=&_webui_json_escape($output);
  if($rc == 0) {
  my $response_power="";
  if($cmd eq "off" || $cmd eq "on") {
   my ($cached_phys,$cached_log,$cached_osd)=&webui_cec_scan_cache_info($cec_scan_cache);
   my $power=($cmd eq "off") ? "standby" : "powering-on";
   $response_power=$power;
   unlink($cec_scan_cache);
   &webui_cec_power_cache_write($cec_power_cache,$power,$cached_phys,$cached_log,$cached_osd);
  }
  return "{\"status\":\"ok\",\"output\":\"$output\",\"tv_power\":\"$response_power\"}";
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
 # Signal the Resolve session loop to abort its timed read and RST-close the
 # TCP socket. Client IP/software are cleared by resolve_connection_thread
 # after the socket is shut down so status stays accurate until RST goes out.
 if($calibration_client_software ne "Resolve") {
  eval {
   lock($resolve_disconnect_request);
   $resolve_disconnect_request=0;
  };
  return '{"status":"ok","message":"Not connected"}';
 }
 eval {
  lock($resolve_disconnect_request);
  $resolve_disconnect_request=1;
 };
 # Wait until the session thread finishes close so the API reflects RST done.
 for(my $i=0; $i<20; $i++) {
  last if($calibration_client_software ne "Resolve");
  select(undef,undef,undef,0.1);
 }
 return '{"status":"ok","message":"Disconnect requested"}';
}

sub webui_resolve_cancel (@) {
 # Abort a connect that is queued or in progress (operator hit Cancel, e.g. a
 # wrong IP). Unlike disconnect, this raises the abort flag UNCONDITIONALLY --
 # during "connecting" the client software is not yet "Resolve", and we still
 # want a connect that establishes a moment later to tear itself down at once.
 # An in-flight bounded connect() cannot be interrupted mid-syscall, but: if it
 # establishes, the read loop honors the flag on its first pass and RST-closes;
 # if it fails/times out, the connect path clears the flag. Returns immediately
 # so the button feels instant.
 eval {
  lock($resolve_disconnect_request);
  $resolve_disconnect_request=1;
 };
 return '{"status":"ok","message":"Cancel requested"}';
}

sub webui_pattern_target_max (@) {
 my $bits=int(shift);
 $bits=int($bits_default || 8) if($bits <= 0);
 return 1023 if($bits == 10);
 return 4095 if($bits == 12);
 return 255;
}

sub webui_pattern_apl_levels (@) {
 my $target_bits=int(shift);
 my $signal_range=int(shift);
 my $target_max=&webui_pattern_target_max($target_bits);
 my %bits_for_max=(255 => 8, 1023 => 10, 4095 => 12);
 my $bits=$bits_for_max{$target_max} || int($target_bits || $bits_default || 8);
 my $shift=$bits - 8;
 my $limited_min=16 << $shift;
 my $limited_span=219 << $shift;
 return ($limited_min,$limited_span,$limited_min + $limited_span) if($signal_range == 1);
 return (0,$target_max,$target_max);
}

sub webui_pattern_apl_bg_triplet (@) {
 my $r=int(shift);
 my $g=int(shift);
 my $b=int(shift);
 my $target_bits=int(shift);
 my $win_pct=int(shift);
 my $apl_pct=shift;
 my $signal_range=int(shift);
 my $fallback_rgb=shift;
 $fallback_rgb="0,0,0" if($fallback_rgb eq "");
 return $fallback_rgb if($win_pct <= 0 || $win_pct >= 100);
 $apl_pct=0 + $apl_pct;
 $apl_pct=0 if($apl_pct < 0);
 $apl_pct=100 if($apl_pct > 100);
 my ($min_level,$range_span,$max_level)=&webui_pattern_apl_levels($target_bits,$signal_range);
 return $fallback_rgb if($range_span <= 0);
 my $y=(0.2126 * $r) + (0.7152 * $g) + (0.0722 * $b);
 my $fg_pct=(($y - $min_level) * 100 / $range_span);
 $fg_pct=0 if($fg_pct < 0);
 $fg_pct=100 if($fg_pct > 100);
 my $win_frac=$win_pct / 100;
 my $bg_frac=1 - $win_frac;
 return $fallback_rgb if($bg_frac <= 0);
 my $fg_contrib=$fg_pct * $win_frac;
 my $bg_pct=($apl_pct - $fg_contrib) / $bg_frac;
 $bg_pct=0 if($bg_pct < 0);
 $bg_pct=100 if($bg_pct > 100);
 my $bg_y=$min_level + ($bg_pct * $range_span / 100);
 $bg_y=int($bg_y + 0.5);
 $bg_y=0 if($bg_y < 0);
 $bg_y=$max_level if($bg_y > $max_level);
 return "$bg_y,$bg_y,$bg_y";
}

sub webui_pattern_scale_value (@) {
 my $value=int(shift);
 my $input_max=int(shift);
 my $target_bits=int(shift);
 my $target_max=&webui_pattern_target_max($target_bits);
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
 my $target_bits=int(shift);
 return 10 if(($signal_mode eq "hdr10" || $signal_mode eq "hlg") && $link_bits >= 10);
 return &webui_pattern_scale_value($r,$input_max,$target_bits).",".&webui_pattern_scale_value($g,$input_max,$target_bits).",".&webui_pattern_scale_value($b,$input_max,$target_bits);
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

# Single source of truth for stimulus-percent -> wire code for the greyscale
# ladders AND for the pattern-insertion patches. Mirrors the body of the
# $grey_code_for_stim closure used by webui_meter_series_start so an
# insertion patch is always visually identical to the greyscale step for the
# same stimulus in whatever output mode is active.
#
# Returns ($code,$input_max). Defaults match the closure:
#   signal_mode  signal_range  code branch                input_max
#   sdr          full           linear 0..255              255
#   sdr          limited        legal 16..235              255
#   hdr10        (any)          pq-encoded 0..255          255
#   hdr10 26pt   (any)          hdr20 table (1.4..100)     1023
#                                  + linear min..min+span for 0%
#   hdr10 26pt   full           full 10-bit table           1023
#   hdr10 26pt   limited        limited 10-bit table        1023
#   dv  greyscale               tunnel (8 or 10)            255/1023
#   hlg          (any)          container-code-linear       255
# $opts_hr carries optional knobs used by the hdr20 / DV paths:
#   active_table    HASH ref   replaces the default hdr20 body table
#   hdr20_codes     0/1        force hdr20 branch
#   autocal_26      0/1        use the LG 26pt slot map
#   autocal_26_codes 0/1       SDR 26pt slot map
#   extended_sdr_codes 0/1    use extended (16..255) SDR range
#   legal_sdr_ddc_codes 0/1   use legal (16..235) SDR range
#   two_point_ycbcr_headroom 0/1 allow 100..109% to use YCbCr super-white
#   dv_series       0/1        use DV tunnel branch
#   dv_series_code_bits 8/10/12  source-code precision inside the tunnel
#   dv_series_full_range 0/1  use full tunnel range
sub webui_grey_code_for_stimulus (@) {
 my ($stimulus_pct,$signal_mode,$target_gamma,$signal_range,$opts_hr)=@_;
 # Preserve the unclamped stimulus for the 10-bit LIMITED lg_autocal_26_codes
 # sub-branch so the legal-expanded super-white ladder (105% / 109%) can
 # reach the canonical super-white formula instead of being flattened to
 # 100% by the function-level clamp below. All other branches observe the
 # clamp.
 my $raw_stim_for_ac26_ltd=defined($stimulus_pct) ? ($stimulus_pct+0) : 0;
 $stimulus_pct+=0;
 $stimulus_pct=0 if($stimulus_pct < 0);
 $stimulus_pct=100 if($stimulus_pct > 100);
 $signal_mode=lc($signal_mode||"sdr");
 $signal_range+=0 if(defined($signal_range) && $signal_range ne "");
 $opts_hr={} if(ref($opts_hr) ne "HASH");
 my $code=0;
 my $input_max=255;
 my $lg_hdr20_codes=$opts_hr->{"hdr20_codes"} ? 1 : 0;
 my $lg_autocal_26=$opts_hr->{"autocal_26"} ? 1 : 0;
 my $lg_autocal_26_codes=$opts_hr->{"autocal_26_codes"} ? 1 : 0;
 my $lg_extended_sdr_codes=$opts_hr->{"extended_sdr_codes"} ? 1 : 0;
 my $lg_legal_sdr_ddc_codes=$opts_hr->{"legal_sdr_ddc_codes"} ? 1 : 0;
 my $two_point_ycbcr_headroom=$opts_hr->{"two_point_ycbcr_headroom"} ? 1 : 0;
 my $dv_series=$opts_hr->{"dv_series"} ? 1 : 0;
 my $dv_series_code_bits=$opts_hr->{"dv_series_code_bits"};
 $dv_series_code_bits=8 if(!defined($dv_series_code_bits) || ($dv_series_code_bits!=8 && $dv_series_code_bits!=10 && $dv_series_code_bits!=12));
 my $dv_series_full_range=$opts_hr->{"dv_series_full_range"} ? 1 : 0;
 my $dv_series_code_max=($dv_series_code_bits==12) ? 4095 : (($dv_series_code_bits==10) ? 1023 : 255);
 my $dv_series_code_min=$dv_series ? ($dv_series_full_range ? 0 : ($dv_series_code_bits==12?256:($dv_series_code_bits==10?64:16))) : 0;
 my $dv_series_code_span=$dv_series ? ($dv_series_full_range ? $dv_series_code_max : ($dv_series_code_bits==12?3504:($dv_series_code_bits==10?876:219))) : 255;
 my $dv_series_code_limit=$dv_series_code_min + $dv_series_code_span;
 $input_max=$dv_series_code_max if($dv_series);
 if($two_point_ycbcr_headroom) {
  # YCbCr Limited keeps the nominal legal ramp through 100%, then exposes
  # super-white through 109%. RGB Limited deliberately does not enter this
  # branch and remains capped at 235/940.
  my $_tp_bits=(defined $opts_hr->{"max_bpc"} && $opts_hr->{"max_bpc"} ne "" && int($opts_hr->{"max_bpc"}) >= 10) ? 10 : 8;
  my $_tp_min=$_tp_bits==10 ? 64 : 16;
  my $_tp_legal=$_tp_bits==10 ? 940 : 235;
  my $_tp_max=$_tp_bits==10 ? 1023 : 255;
  my $_tp_stim=$raw_stim_for_ac26_ltd+0;
  $_tp_stim=0 if($_tp_stim < 0);
  $_tp_stim=109 if($_tp_stim > 109);
  if($_tp_stim <= 100) {
   $code=int($_tp_min + $_tp_stim/100*($_tp_legal-$_tp_min) + .5);
  } else {
   $code=int($_tp_legal + ($_tp_stim-100)/9*($_tp_max-$_tp_legal) + .5);
  }
  $code=$_tp_min if($code < $_tp_min);
  $code=$_tp_max if($code > $_tp_max);
  $input_max=$_tp_max;
  return ($code,$input_max);
 }
 if($lg_autocal_26_codes) {
  # 8-bit link: no headroom and no 10-bit legal-expanded ladder. Drive plain
  # 8-bit codes that match the worker's patch_code_for_stimulus 8-bit path
  # (full 0..255, limited 16..235) so the displayed/inserted codes agree with
  # what is actually sent. >100% has no 8-bit headroom, so it clamps to peak.
  # The DPG slot indexing is unaffected (it is keyed by IRE via @sdr26_indexes
  # in the worker, not by this drive code).
  my $_ac26_bits=(defined $opts_hr->{"max_bpc"} && $opts_hr->{"max_bpc"} ne "" && int($opts_hr->{"max_bpc"}) == 8) ? 8 : 10;
  # Limited transport has TWO sub-modes that must NOT be conflated
  # (per user direction):
  #   RGB Limited    -> codes 16..235 ONLY (109% clamps to 235).
  #   YCbCr Limited  -> codes 16..255, 100%=235, 109%=255 via super-white.
  # 10-bit follows the same axis rules scaled ×4.
  my $_ac26_cf=(defined $opts_hr->{"color_format"} && $opts_hr->{"color_format"} ne "")
   ? int($opts_hr->{"color_format"})
   : (defined $pgenerator_conf{"color_format"} && $pgenerator_conf{"color_format"} ne ""
      ? int($pgenerator_conf{"color_format"}) : 0);
  my $_ac26_is_ycbcr=(($_ac26_cf == 1) || ($_ac26_cf == 2)) ? 1 : 0;
  if($_ac26_bits == 8) {
   if($signal_range) {
    if($_ac26_is_ycbcr) {
     # YCbCr Limited 8-bit: legal ramp <=100% (16..235 via 16+S/100*219),
     # super-white ramp >100% (235+(S-100)/9*20 -> 109%=255).
     my $_ac26_s=$raw_stim_for_ac26_ltd+0;
     $_ac26_s=0 if($_ac26_s < 0);
     $_ac26_s=109 if($_ac26_s > 109);
     if($_ac26_s <= 100) {
      $code=int(16 + ($_ac26_s/100)*219 + .5);
     } else {
      $code=int(235 + ($_ac26_s-100)/9*(255-235) + .5);
     }
     $code=16 if($code < 16); $code=255 if($code > 255);
    } else {
     # RGB Limited 8-bit: codes 16..235 only. 105/109% clamp to 235 (no
     # super-white headroom).
     my $_ac26_s=$raw_stim_for_ac26_ltd+0;
     $_ac26_s=0 if($_ac26_s < 0);
     $_ac26_s=100 if($_ac26_s > 100);
     $code=int(16 + ($_ac26_s/100)*219 + .5);
     $code=16 if($code < 16); $code=235 if($code > 235);
    }
   } else {
    # Full: no codes above white -- 100% is the peak (255), so >100% clamps to 255.
    # Full range has no super-white headroom, so the clamped $stimulus_pct is
    # the right input here (the legal-expanded raw ladder is limited-only).
    my $s=$stimulus_pct; $s=100 if($s > 100);
    $code=int(($s/100)*255 + .5); $code=0 if($code < 0); $code=255 if($code > 255);
   }
   $input_max=255;
   return ($code,$input_max);
  }
  if(!$signal_range) {
   # 10-bit Full SDR: 8bit<<2 (same map as worker DPG index). Peak=1023.
   my $s=$stimulus_pct+0; $s=0 if($s < 0); $s=100 if($s > 100);
   if($s >= 99.95) {
    $code=1023;
   } else {
    my $b8=int($s/100*255 + .5);
    $b8=0 if($b8 < 0); $b8=255 if($b8 > 255);
    $code=$b8 << 2;
   }
   $input_max=1023;
   return ($code,$input_max);
  }
  my %lg_autocal_26_code=(
   "2.3"=>84,"3"=>92,"4"=>100,"5"=>108,"7"=>124,"10"=>152,"15"=>196,"20"=>240,"25"=>284,"30"=>328,"35"=>372,"40"=>416,"45"=>460,
   "50"=>504,"55"=>544,"60"=>588,"65"=>632,"70"=>676,"75"=>720,"80"=>764,"85"=>808,"90"=>852,"95"=>896,"99"=>932,"105"=>984,"109"=>1023
  );
  # 10-bit LIMITED canonical compute. RGB Limited clamps super-white at 940;
  # YCbCr Limited uses the full 64..1023 ladder with the super-white ramp
  # 940+(S-100)/9*83. $raw_stim_for_ac26_ltd bypasses the function-level
  # 100% clamp so the super-white formula can fire on 105/109 stimuli.
  my $_ac26_s=$raw_stim_for_ac26_ltd+0;
  $_ac26_s=0 if($_ac26_s < 0);
  if($_ac26_is_ycbcr) {
   $_ac26_s=109 if($_ac26_s > 109);
   if($_ac26_s <= 100) {
    $code=int(64 + $_ac26_s/100*876 + .5);
   } else {
    $code=int(940 + ($_ac26_s-100)/9*(1023-940) + .5);
   }
   $code=64 if($code < 64);
   $code=1023 if($code > 1023);
  } else {
   # RGB Limited 10-bit: legal ladder <=100%, super-white clamps at 940.
   $_ac26_s=100 if($_ac26_s > 100);
   $code=int(64 + $_ac26_s/100*876 + .5);
   $code=64 if($code < 64);
   $code=940 if($code > 940);
  }
  $input_max=1023;
  return ($code,$input_max);
 }
 if($lg_hdr20_codes) {
  my %lg_hdr20_code=(
   "1.4"=>19,"2"=>20,"2.7"=>22,"4"=>25,"5"=>27,"7"=>31,"10"=>38,"15"=>49,"20"=>60,"25"=>71,
   "30"=>82,"35"=>93,"40"=>104,"45"=>115,"50"=>126,"60"=>147,"70"=>169,"80"=>191,"90"=>213,"100"=>235
  );
  my %lg_hdr20_code_10bit_limited=(
   "1.4"=>76,"2"=>80,"2.7"=>88,"4"=>100,"5"=>108,"7"=>124,"10"=>152,"15"=>196,"20"=>240,"25"=>284,
   "30"=>328,"35"=>372,"40"=>416,"45"=>460,"50"=>504,"60"=>588,"70"=>676,"80"=>764,"90"=>852,"100"=>940
  );
  my %lg_hdr20_code_10bit_full=(
   "1.4"=>14,"2"=>20,"2.7"=>28,"4"=>41,"5"=>51,"7"=>72,"10"=>102,"15"=>153,"20"=>205,"25"=>256,
   "30"=>307,"35"=>358,"40"=>409,"45"=>460,"50"=>512,"60"=>614,"70"=>716,"80"=>818,"90"=>921,"100"=>1023
  );
  # HDR10 8-bit full table (0..255). The 8-bit limited case reuses
  # %lg_hdr20_code (the 16..235 numeric values are identical).
  my %lg_hdr20_code_8bit_full=(
   "1.4"=>4,"2"=>5,"2.7"=>7,"4"=>10,"5"=>13,"7"=>18,"10"=>26,"15"=>38,"20"=>51,"25"=>64,
   "30"=>77,"35"=>89,"40"=>102,"45"=>115,"50"=>128,"60"=>153,"70"=>179,"80"=>204,"90"=>230,"100"=>255
  );
  my %lg_hdr20_stimulus=();
  foreach my $key (keys %lg_hdr20_code) { $lg_hdr20_stimulus{$key}=$key+0; }
  my $lg_hdr20_active_table=\%lg_hdr20_code;
  # HDR10 26pt table selection follows max_bpc: 8 -> 8-bit codes (limited
  # 16..235 by reusing %lg_hdr20_code, or full 0..255 via
  # %lg_hdr20_code_8bit_full) and input_max=255; 10 -> 10-bit codes (limited
  # 64..940 or full 0..1023) and input_max=1023. Caller supplies the active
  # max_bpc via $opts_hr->{"max_bpc"}; default 10 keeps the original
  # behavior when the option is absent.
  my $_wb_hdr20_bits=(defined $opts_hr->{"max_bpc"} && $opts_hr->{"max_bpc"} ne "" && int($opts_hr->{"max_bpc"}) == 8) ? 8 : 10;
  if($opts_hr->{"active_table"} && ref($opts_hr->{"active_table"}) eq "HASH") {
   $lg_hdr20_active_table=$opts_hr->{"active_table"};
  } elsif($_wb_hdr20_bits == 8) {
   $lg_hdr20_active_table=\%lg_hdr20_code if($opts_hr->{"hdr20_use_limited"});
   $lg_hdr20_active_table=\%lg_hdr20_code_8bit_full if($opts_hr->{"hdr20_use_limited"} && $opts_hr->{"hdr20_full"});
  } else {
   $lg_hdr20_active_table=\%lg_hdr20_code_10bit_limited if($opts_hr->{"hdr20_use_limited"});
   $lg_hdr20_active_table=\%lg_hdr20_code_10bit_full if($opts_hr->{"hdr20_use_limited"} && $opts_hr->{"hdr20_full"});
  }
  my $lg_hdr20_min_code=($_wb_hdr20_bits == 10 && $opts_hr->{"hdr20_use_limited"} && $opts_hr->{"hdr20_full"}) ? 0 : ($_wb_hdr20_bits == 8 ? 0 : 64);
  my $lg_hdr20_span_code=($_wb_hdr20_bits == 10)
   ? (($opts_hr->{"hdr20_use_limited"} && $opts_hr->{"hdr20_full"}) ? 1023 : 876)
   : 255;
  my $slot_key="";
  foreach my $slot (keys %lg_hdr20_stimulus) {
   if(abs($lg_hdr20_stimulus{$slot}-$stimulus_pct) < 0.01) { $slot_key=$slot; last; }
  }
  $code=exists($lg_hdr20_active_table->{$slot_key}) ? $lg_hdr20_active_table->{$slot_key} : int($lg_hdr20_min_code + $stimulus_pct/100*$lg_hdr20_span_code + .5);
  $code=$lg_hdr20_min_code if($code < $lg_hdr20_min_code);
  $code=$lg_hdr20_min_code + $lg_hdr20_span_code if($code > $lg_hdr20_min_code + $lg_hdr20_span_code);
  $input_max=($_wb_hdr20_bits == 8) ? 255 : 1023;
  return ($code,$input_max);
 }
 if($dv_series) {
  my $stim=$stimulus_pct/100;
  $stim=0 if($stim < 0);
  $stim=1 if($stim > 1);
  $code=int($dv_series_code_min + $stim*$dv_series_code_span + .5);
  $code=$dv_series_code_min if($code < $dv_series_code_min);
  $code=$dv_series_code_limit if($code > $dv_series_code_limit);
  return ($code,$input_max);
 }
 my $lim=(defined($signal_range) && int($signal_range)==1) ? 1 : 0;
 # Greyscale bit-depth plumbing: when max_bpc>=10 (10-bit link), the 8-bit
 # codes below would land on a 10-bit wire as ~23% signal (e.g. 8-bit 235
 # = 10-bit 235 / 1023 = 23%), crushing the entire stimulus range. Before
 # this fix the standard SDR/HDR10/HLG/extended/legal-DDC branches always
 # returned 8-bit codes with $input_max=255, and webui_meter_series_start
 # never stamped `input_max` for those branches, so meter_series.sh /
 # pattern_request_body saw no input_max + codes <=255 and dispatched an
 # 8-bit pattern over the 10-bit wire. Mirror the JS bit-depth scaling in
 # meterGreyCodeRange(): 10-bit limited min=64 span=876 (matches the
 # HDR10 10-bit Limited table: 100% -> 940 = 64 + 876), 10-bit full
 # min=0 span=1023 (matches the HDR10 10-bit Full table: 100% -> 1023),
 # 10-bit extended-sdr min=64 span=956 (matches the JS extended branch).
 # 12-bit links are coerced to 10-bit here, matching meterPatchBitDepth().
 my $_wb_bits=(defined $opts_hr->{"max_bpc"} && $opts_hr->{"max_bpc"} ne "" && int($opts_hr->{"max_bpc"}) >= 10) ? 10 : 8;
 if($lg_extended_sdr_codes) {
  # Extended SDR is the LG "16..255" ladder: legal black, FULL white. Its top
  # is 100% at full scale, so at 10 bits that is 64..1023 (span 959), derived
  # natively from the stimulus rather than by upshifting the 8-bit ladder.
  # It was 64 + pct*956, i.e. the 8-bit span 239 multiplied by 4, which carried
  # 8-bit quantisation into every point of a 10-bit ladder and left the top at
  # 1020. (Do not confuse this with the SDR-26 super-white ladder, where 1023
  # is 109% and 100% is 940 -- that is a different curve and is built by the
  # autocal_26_codes branch above, which returns before reaching here.)
  $code=($stimulus_pct <= 0) ? 0 : int(16 + $stimulus_pct/100*239 + .5);
  if($_wb_bits == 10) {
   $code=($stimulus_pct <= 0) ? 0 : int(64 + $stimulus_pct/100*959 + .5);
  }
 } elsif($lg_legal_sdr_ddc_codes) {
  $code=($stimulus_pct <= 0) ? 0 : int(16 + $stimulus_pct/100*219 + .5);
  if($_wb_bits == 10) {
   $code=($stimulus_pct <= 0) ? 0 : int(64 + $stimulus_pct/100*876 + .5);
  }
 } elsif($signal_mode eq "hdr10") {
  $code=$lim ? int(16 + $stimulus_pct/100*219 + .5) : int($stimulus_pct/100*255 + .5);
  if($_wb_bits == 10) {
   $code=$lim ? int(64 + $stimulus_pct/100*876 + .5) : int($stimulus_pct/100*1023 + .5);
  }
 } elsif($signal_mode eq "hlg") {
  $code=$lim ? int(16 + $stimulus_pct/100*219 + .5) : int($stimulus_pct/100*255 + .5);
  if($_wb_bits == 10) {
   $code=$lim ? int(64 + $stimulus_pct/100*876 + .5) : int($stimulus_pct/100*1023 + .5);
  }
 } else {
  $code=$lim ? int(16 + $stimulus_pct/100*219 + .5) : int($stimulus_pct/100*255 + .5);
  if($_wb_bits == 10) {
   $code=$lim ? int(64 + $stimulus_pct/100*876 + .5) : int($stimulus_pct/100*1023 + .5);
  }
 }
 $input_max=($_wb_bits == 10) ? 1023 : 255;
 $code=0 if($code < 0);
 $code=$input_max if($code > $input_max);
 return ($code,$input_max);
}

# The stabilization pattern is an idle-state policy rather than a new
# measurement pattern. Keep its durable preference in Meter Settings, but gate
# activation against the live meter status so an unplugged meter always falls
# back to the normal black idle frame.
sub webui_meter_stabilization_settings (@) {
 my $enabled=0;
 my $stimulus=25;
 my $size=100;
 foreach my $path ($_meter_settings_runtime,$_meter_settings_persist,$_meter_settings_persist_legacy,$_meter_settings_file) {
  next unless(-f $path);
  my $json="";
  if(open(my $fh,"<",$path)) { local $/; $json=<$fh>; close($fh); }
  next if($json eq "" || $json!~/^\s*\{/);
  $enabled=1 if($json=~/"stabilization_pattern_enabled"\s*:\s*(?:true|1|"1")/i);
  $stimulus=$1+0 if($json=~/"stabilization_pattern_stimulus"\s*:\s*"?(-?\d+(?:\.\d+)?)"?/i);
  if($json=~/"stabilization_pattern_size"\s*:\s*"?(apl_\d+|\d+)"?/i) {
   my $configured_size=lc($1);
   if($configured_size=~/^apl_(5|10|18|25|50)$/) {
    my $apl=int($1);
    $size=($apl>10) ? 100+$apl : $apl;
   } elsif($configured_size=~/^(2|5|10|18|25|50|75|100|105|110|118|125|150)$/) {
    $size=int($configured_size);
   }
  }
  last;
 }
 $stimulus=0 if($stimulus < 0);
 $stimulus=100 if($stimulus > 100);
 return ($enabled,$stimulus,$size);
}

sub webui_meter_stabilization_active (@) {
 my ($enabled,$stimulus,$size)=&webui_meter_stabilization_settings();
 return (0,$stimulus,$size) if(!$enabled);
 my $status=&webui_meter_status();
 return (($status=~/"detected"\s*:\s*true/i)?1:0,$stimulus,$size);
}

sub webui_meter_stabilization_code (@) {
 my ($stimulus,$signal_mode,$signal_range,$max_bpc)=@_;
 my %opts=(
  max_bpc => (defined($max_bpc) ? $max_bpc : ""),
  dv_series => (lc($signal_mode||"") eq "dv" ? 1 : 0),
  dv_series_code_bits => (lc($signal_mode||"") eq "dv" ? 12 : 8),
 );
 return &webui_grey_code_for_stimulus($stimulus,$signal_mode,"",$signal_range,\%opts);
}

sub webui_pattern_idle_refresh_allowed (@) {
 return (1,"") if(!-f $command_file);
 my $current="";
 if(open(my $fh,"<",$command_file)) {
  while(my $line=<$fh>) {
   if($line=~/^PATTERN_NAME=(.*)$/) { $current=$1; last; }
  }
  close($fh);
 }
 $current=~s/[\r\n]+//g;
 return (1,$current) if($current eq "" || $current eq "stop" || $current eq "stabilization");
 return (0,$current);
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
 # Dolby Vision diagnostic IMAGE patterns ride the RGB tunnel directly, so
 # preserve their authored 8-bit code values instead of re-scaling them to a
 # generic PQ peak byte.
 return $max_code if(lc($signal_mode || "") eq "dv");
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
 # Diagnostic IMAGE patterns use legacy video levels (for example 232-255
 # white clipping bars). Preserve their relative spacing on HDR10 PQ links by
 # scaling against the configured peak byte instead of gamma-remapping. Dolby
 # Vision keeps the original authored bytes via webui_pattern_peak_code().
 my $peak_byte=&webui_pattern_peak_byte($signal_mode,$max_luma);
 return int($value*$peak_byte/255 + 0.5);
}

our $webui_pattern_image_source_range="FULL";

sub webui_pattern_image_source_byte (@) {
 my $value=int(shift);
 $value=0 if($value < 0);
 $value=255 if($value > 255);
 return $value if($webui_pattern_image_source_range ne "LIMITED");
 my $normalized=int((($value - 16) * 255) / 219 + 0.5);
 $normalized=0 if($normalized < 0);
 $normalized=255 if($normalized > 255);
 return $normalized;
}

sub webui_pattern_image_source_triplet (@) {
 return (
  &webui_pattern_image_source_byte(shift),
  &webui_pattern_image_source_byte(shift),
  &webui_pattern_image_source_byte(shift)
 );
}

sub webui_pattern_image_new (@) {
 my $w=int(shift);
 my $h=int(shift);
 my $r=int(shift);
 my $g=int(shift);
 my $b=int(shift);
 ($r,$g,$b)=&webui_pattern_image_source_triplet($r,$g,$b);
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
 ($r,$g,$b)=&webui_pattern_image_source_triplet($r,$g,$b);
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
 my $signal_mode=lc(shift || "");
 # Diagnostic IMAGE patterns are generated as 8-bit PNG/PPM assets.  Keep the
 # pattern header at 8-bit even on HDR links so the renderer stays on its
 # stable 8-bit IMAGE decode path.
 return 8 if($draw eq "IMAGE");
 my $bits=int($bits_default || 8);
 my $link_bits=int($pgenerator_conf{"max_bpc"} || 8);
 # The native renderer only has distinct 8-bit and 10-bit drawing paths.
 # HDR10 and HLG use the 10-bit rectangle path when the link is above 8 bpc.
 # Dolby Vision patterns are RGB tunnel codes; the link may be 8 or 10 bpc,
 # but the renderer still emits the 8-bit tunnel pattern payload.
 return 10 if(($signal_mode eq "hdr10" || $signal_mode eq "hlg") && $link_bits >= 10);
 return 8 if($signal_mode eq "dv");
 return 8 if($bits != 10 && $bits != 12);
 return $bits == 12 ? 10 : $bits;
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

sub webui_pattern_render_apl_clipping (@) {
 my $file=shift;
 my $w=int(shift);
 my $h=int(shift);
 my $signal_mode=shift;
 my $max_luma=shift;
 my $apl_bg=&webui_pattern_legacy_byte(128,$signal_mode,$max_luma);
 my $image=&webui_pattern_image_new($w,$h,$apl_bg,$apl_bg,$apl_bg);
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

sub webui_pattern_diag_video_path (@) {
 my $name=shift;
 return "Basic Settings/1-Black Clipping.mp4" if($name eq "avs_hd_709_black_clipping");
 return "Basic Settings/2-APL Clipping.mp4" if($name eq "avs_hd_709_apl_clipping");
 return "Basic Settings/3-White Clipping.mp4" if($name eq "avs_hd_709_white_clipping");
 return "Basic Settings/4-Flashing Color Bars.mp4" if($name eq "avs_hd_709_flashing_color_bars");
 return "Basic Settings/5-Sharpness & Overscan.mp4" if($name eq "avs_hd_709_sharpness_overscan");
 return "";
}

sub webui_pattern_diag_video_sequence_dir (@) {
 my $name=lc("".shift);
 $name=~s/[^a-z0-9_]+/_/g;
 return "" if($name eq "");
 # range_kind:
 #   full    -> diagseq_full/  (full-span black=0 for RGB Full)
 #   limited -> diagseq/       (studio codes for RGB Limited + YCbCr)
 my $range_kind=lc("".(shift // ""));
 $range_kind="" if($range_kind ne "full" && $range_kind ne "limited");
 return "$var_dir/diagseq_full/$name" if($range_kind eq "full");
 return "$var_dir/diagseq/$name";
}

# Bundled AVS HD 709 frame sets:
#   diagseq_full/  full-span (field black=0). Used for RGB Full so the
#                  background is true digital black, not studio ~1/16 grey.
#   diagseq/       studio-level extract (footroom 2..15 + bars 17..25).
#                  Used for RGB Limited and YCbCr Limited PLUGE.
#
# Do not use studio frames on RGB Full: legal black is 0 there, so codes
# near 16 read as raised/grey blacks. Do not use full-span frames on
# Limited/YCbCr if you need real below-black PLUGE footroom.
sub webui_pattern_diag_video_sequence_range_kind (@) {
 my $color_format=int(shift // 0);
 my $quant_range=int(shift // 2);
 # RGB Full only -> full-span companion (black=0).
 return "full" if($color_format == 0 && $quant_range != 1);
 # RGB Limited + any YCbCr -> studio codes.
 return "limited";
}

sub webui_pattern_frame_sequence_pattern (@) {
 my $dir=shift;
 my $w=int(shift);
 my $h=int(shift);
 my @frames=();
 return "" if($dir eq "" || !-d $dir);
 if(opendir(my $dh,$dir)) {
  while(my $f=readdir($dh)) {
   next if($f !~ /\.(?:png|jpe?g|ppm)$/i);
   next if(!-f "$dir/$f");
   push(@frames,$f);
  }
  closedir($dh);
 }
 @frames=sort @frames;
 return "" if(!@frames);
 my $pat="";
 my $frame_ms=83;
 for(my $i=0;$i<scalar(@frames);$i++) {
  my $image="$dir/$frames[$i]";
  $pat.="DRAW=IMAGE\nDIM=$w,$h\nRGB=0,0,0\nBG=0,0,0\nPOSITION=0,0\nIMAGE=$image\nEND=1\nFRAME_NAME=$frames[$i]\nFRAME=$frame_ms\n";
 }
 return $pat;
}

sub webui_pattern_diag_video_sequence_pattern (@) {
 my $name=shift;
 my $w=int(shift);
 my $h=int(shift);
 my $color_format=int(shift // 0);
 my $quant_range=int(shift // 2);
 my $range_kind=&webui_pattern_diag_video_sequence_range_kind($color_format,$quant_range);
 my $dir=&webui_pattern_diag_video_sequence_dir($name,$range_kind);
 my $pat=&webui_pattern_frame_sequence_pattern($dir,$w,$h);
 # Fall back to limited stock set if the full companion is missing (older
 # installs / partial OTA), so patterns still play.
 if($pat eq "" && $range_kind eq "full") {
  $dir=&webui_pattern_diag_video_sequence_dir($name,"limited");
  $pat=&webui_pattern_frame_sequence_pattern($dir,$w,$h);
 }
 return $pat;
}

sub webui_pattern_uploaded_diag_video_sequence_pattern (@) {
 my $filename=shift;
 my $w=int(shift);
 my $h=int(shift);
 my $dir=&_webui_diag_asset_video_sequence_dir($filename);
 return &webui_pattern_frame_sequence_pattern($dir,$w,$h);
}

sub webui_pattern_diag_video_fallback_name (@) {
 my $name=shift;
 return "black_clipping" if($name eq "avs_hd_709_black_clipping");
 return "apl_clipping" if($name eq "avs_hd_709_apl_clipping");
 return "white_clipping" if($name eq "avs_hd_709_white_clipping");
 return "color_bars" if($name eq "avs_hd_709_flashing_color_bars");
 return "overscan" if($name eq "avs_hd_709_sharpness_overscan");
 return "";
}

sub webui_pattern (@) {
 my $body=shift;
 &webui_reload_pgenerator_conf();
 my ($name)=$body=~/"name"\s*:\s*"([^"]+)"/;
 return '{"status":"error","message":"Missing pattern name"}' if(!$name);
 $name=~s/[^a-zA-Z0-9_ -]//g;
 if($name eq "stop" && $body=~/"only_if_idle"\s*:\s*true/i) {
  my ($allowed,$current)=&webui_pattern_idle_refresh_allowed();
  if(!$allowed) {
   $current=~s/[^a-zA-Z0-9_ -]//g;
   return '{"status":"ok","pattern":"'.$current.'","unchanged":true}';
  }
 }
 if($name eq "patch" && &webui_pattern_stop_guard_active()) {
  if(&webui_pattern_stop_guard_allows_patch($body)) {
   &webui_pattern_stop_guard_clear();
  } else {
   &log("WebUI: replacing stale patch request with idle pattern after meter stop");
   $name="stop";
  }
 }
 my $stabilization_stimulus=25;
 my $stabilization_size=100;
 if($name eq "stop") {
  my ($stabilization_active,$configured_stimulus,$configured_size)=&webui_meter_stabilization_active();
  if($stabilization_active) {
   $name="stabilization";
   $stabilization_stimulus=$configured_stimulus;
   $stabilization_size=$configured_size;
  }
 }
 my $signal_mode=&webui_pattern_signal_mode($body);
 my $max_luma=&webui_pattern_max_luma($body);
 my ($signal_range)=$body=~/"signal_range"\s*:\s*"?(\d+)"?/;
 my ($pattern_signal_range)=$body=~/"pattern_signal_range"\s*:\s*"?(\d+)"?/;
 my ($transport_signal_range)=$body=~/"transport_signal_range"\s*:\s*"?(\d+)"?/;
 $transport_signal_range=$signal_range if(!defined $transport_signal_range || $transport_signal_range eq "");
 $transport_signal_range=&webui_preferred_rgb_quant_range() if(!defined $transport_signal_range || $transport_signal_range eq "");
 $pattern_signal_range=$signal_range if(!defined $pattern_signal_range || $pattern_signal_range eq "");
 $pattern_signal_range=$transport_signal_range if(!defined $pattern_signal_range || $pattern_signal_range eq "");
 &apply_source_rgb_quant_range("webui",$transport_signal_range);
 my ($color_format_body)=$body=~/"color_format"\s*:\s*"?(\d+)"?/;
 my $pattern_color_format=defined($color_format_body) ? int($color_format_body) : int($pgenerator_conf{"color_format"} || 0);
	 # Standard DV's outer HDMI tunnel is RGB Full, but its inner source
	 # components are legal-range. SOURCE_RANGE describes those authored
	 # components; transport_signal_range remains the wire setting.
	 my $source_range=($signal_mode eq "dv" || int($pattern_signal_range || 0) == 1) ? "LIMITED" : "FULL";
	 local $webui_pattern_image_source_range=($pattern_color_format == 0) ? $source_range : "FULL";
	 my $w=$w_s || 1920; my $h=$h_s || 1080;
 my $pat=""; my $img=&webui_pattern_diag_image_file($name); my $pat_bits=&webui_pattern_effective_bits("",$signal_mode);
 # Simulated-meter capture: raw patch codes (pre bit-scaling) recorded for
 # spotread_sim at the end of this sub. Named solids/complex patterns are
 # resolved just before the record call.
 my ($sim_r,$sim_g,$sim_b,$sim_imax)=(undef,undef,undef,0);
 my $pattern_source_bits=($signal_mode eq "dv") ? 12 : $pat_bits;
 my $pattern_source_max=&webui_pattern_target_max($pattern_source_bits);
 my $pattern_debug_extra="";
my $diag_video=&webui_pattern_diag_video_path($name);
 my $diag_video_fallback=&webui_pattern_diag_video_fallback_name($name);
 my $white_rgb=($signal_mode eq "dv") ? "3760,3760,3760" : &webui_pattern_scale_triplet(255,255,255,255,$pat_bits);
 my $black_rgb=($signal_mode eq "dv") ? "256,256,256" : &webui_pattern_scale_triplet(0,0,0,255,$pat_bits);
 my $red_rgb=($signal_mode eq "dv") ? "3760,256,256" : &webui_pattern_scale_triplet(255,0,0,255,$pat_bits);
 my $green_rgb=($signal_mode eq "dv") ? "256,3760,256" : &webui_pattern_scale_triplet(0,255,0,255,$pat_bits);
 my $blue_rgb=($signal_mode eq "dv") ? "256,256,3760" : &webui_pattern_scale_triplet(0,0,255,255,$pat_bits);
 my $cyan_rgb=($signal_mode eq "dv") ? "256,3760,3760" : &webui_pattern_scale_triplet(0,255,255,255,$pat_bits);
 my $magenta_rgb=($signal_mode eq "dv") ? "3760,256,3760" : &webui_pattern_scale_triplet(255,0,255,255,$pat_bits);
 my $yellow_rgb=($signal_mode eq "dv") ? "3760,3760,256" : &webui_pattern_scale_triplet(255,255,0,255,$pat_bits);
 my $gray50_rgb=($signal_mode eq "dv") ? "2008,2008,2008" : &webui_pattern_scale_triplet(128,128,128,255,$pat_bits);
 if($diag_video ne "") {
  return '{"status":"error","message":"AVS HD 709 videos are available only in SDR"}' if($signal_mode ne "sdr");
  my $diag_quant_range=int($transport_signal_range || $pattern_signal_range || 2);
  my $diag_sequence=&webui_pattern_diag_video_sequence_pattern($name,$w,$h,$pattern_color_format,$diag_quant_range);
  if($diag_sequence ne "") {
   my $diag_range_kind=&webui_pattern_diag_video_sequence_range_kind($pattern_color_format,$diag_quant_range);
   &log("WebUI: AVS HD 709 using renderer sequence for $name (frames=$diag_range_kind color_format=$pattern_color_format quant=$diag_quant_range)");
   $pat=$diag_sequence;
   $pat_bits=&webui_pattern_effective_bits("IMAGE",$signal_mode);
   $diag_video="";
  }
  elsif(-e "$video_dir/$diag_video") {
   my $video_result="";
   &video_program_stop("$program_video_to_kill");
   $video_result=&play_video("omxplayer.bin",$diag_video,"1h-1");
   return '{"status":"ok","pattern":"'.$name.'"}' if($video_result eq "OK");
   &log("WebUI: AVS HD 709 fallback to built-in pattern for $name ($video_result)");
  } else {
   &log("WebUI: AVS HD 709 source missing for $name, using built-in pattern fallback");
  }
  if($pat eq "") {
   return '{"status":"error","message":"Missing AVS HD 709 video file on device"}' if($diag_video_fallback eq "");
   $name=$diag_video_fallback;
   $img=&webui_pattern_diag_image_file($name);
   $diag_video="";
  }
 }
 # Complex patterns are rendered directly into a temporary image (DRAW=IMAGE),
 # because PGeneratord clears the entire frame for each DRAW=RECTANGLE entry.
 # Prefer PNG for renderer compatibility; fall back to raw PPM only if convert
 # is unavailable on the target system.
 #
 # White Clipping — near-white bar plate with labeled 232-255 bars on a 235 field
 if($pat eq "" && $name eq "white_clipping") {
  return '{"status":"error","message":"Failed to generate image pattern"}' if(!&webui_pattern_render_white_clipping($img,$w,$h,$signal_mode,$max_luma));
  $pat=&webui_pattern_image_pattern($w,$h,$img);
  $pat_bits=&webui_pattern_effective_bits("IMAGE",$signal_mode);
 }
  elsif($pat eq "" && $name eq "apl_clipping") {
   return '{"status":"error","message":"Failed to generate image pattern"}' if(!&webui_pattern_render_apl_clipping($img,$w,$h,$signal_mode,$max_luma));
   $pat=&webui_pattern_image_pattern($w,$h,$img);
   $pat_bits=&webui_pattern_effective_bits("IMAGE",$signal_mode);
  }
 # Black Clipping — near-black bar plate with labeled 2-25 bars on black
 elsif($pat eq "" && $name eq "black_clipping") {
  return '{"status":"error","message":"Failed to generate image pattern"}' if(!&webui_pattern_render_black_clipping($img,$w,$h,$signal_mode,$max_luma));
  $pat=&webui_pattern_image_pattern($w,$h,$img);
  $pat_bits=&webui_pattern_effective_bits("IMAGE",$signal_mode);
 }
 # Color Bars — 75% Rec.709 bars with a bottom PLUGE/reference section
 elsif($pat eq "" && $name eq "color_bars") {
  return '{"status":"error","message":"Failed to generate image pattern"}' if(!&webui_pattern_render_color_bars($img,$w,$h,$signal_mode,$max_luma));
  $pat=&webui_pattern_image_pattern($w,$h,$img);
  $pat_bits=&webui_pattern_effective_bits("IMAGE",$signal_mode);
 }
 # Gray Ramp — smooth top gradient with 11 stepped bars underneath
 elsif($pat eq "" && $name eq "gray_ramp") {
  return '{"status":"error","message":"Failed to generate image pattern"}' if(!&webui_pattern_render_gray_ramp($img,$w,$h,$signal_mode,$max_luma));
  $pat=&webui_pattern_image_pattern($w,$h,$img);
  $pat_bits=&webui_pattern_effective_bits("IMAGE",$signal_mode);
 }
 # Full field solid colors
   elsif($pat eq "" && $name eq "white")   { $pat="DRAW=RECTANGLE\nDIM=$w,$h\nRGB=$white_rgb\nBG=$black_rgb\nPOSITION=0,0\nEND=1\n"; }
   elsif($pat eq "" && $name eq "black")   { $pat="DRAW=RECTANGLE\nDIM=$w,$h\nRGB=$black_rgb\nBG=$black_rgb\nPOSITION=0,0\nEND=1\n"; }
   elsif($pat eq "" && $name eq "red")     { $pat="DRAW=RECTANGLE\nDIM=$w,$h\nRGB=$red_rgb\nBG=$black_rgb\nPOSITION=0,0\nEND=1\n"; }
   elsif($pat eq "" && $name eq "green")   { $pat="DRAW=RECTANGLE\nDIM=$w,$h\nRGB=$green_rgb\nBG=$black_rgb\nPOSITION=0,0\nEND=1\n"; }
   elsif($pat eq "" && $name eq "blue")    { $pat="DRAW=RECTANGLE\nDIM=$w,$h\nRGB=$blue_rgb\nBG=$black_rgb\nPOSITION=0,0\nEND=1\n"; }
   elsif($pat eq "" && $name eq "cyan")    { $pat="DRAW=RECTANGLE\nDIM=$w,$h\nRGB=$cyan_rgb\nBG=$black_rgb\nPOSITION=0,0\nEND=1\n"; }
   elsif($pat eq "" && $name eq "magenta") { $pat="DRAW=RECTANGLE\nDIM=$w,$h\nRGB=$magenta_rgb\nBG=$black_rgb\nPOSITION=0,0\nEND=1\n"; }
   elsif($pat eq "" && $name eq "yellow")  { $pat="DRAW=RECTANGLE\nDIM=$w,$h\nRGB=$yellow_rgb\nBG=$black_rgb\nPOSITION=0,0\nEND=1\n"; }
 # 50% Gray
   elsif($pat eq "" && $name eq "gray50")  { $pat="DRAW=RECTANGLE\nDIM=$w,$h\nRGB=$gray50_rgb\nBG=$black_rgb\nPOSITION=0,0\nEND=1\n"; }
 # Window pattern — centered white window on black (18% of screen area)
 elsif($pat eq "" && $name eq "window") {
  my $s=sqrt(0.18); my $ww=int($w*$s); my $wh=int($h*$s);
  my $wx=int(($w-$ww)/2); my $wy=int(($h-$wh)/2);
    $pat="DRAW=RECTANGLE\nDIM=$ww,$wh\nRGB=$white_rgb\nBG=$black_rgb\nPOSITION=$wx,$wy\nEND=1\n";
 }
 # Overscan — borders at 0%, 2.5%, 5% with corner brackets and crosshair
 elsif($pat eq "" && $name eq "overscan") {
  return '{"status":"error","message":"Failed to generate image pattern"}' if(!&webui_pattern_render_overscan($img,$w,$h));
  $pat=&webui_pattern_image_pattern($w,$h,$img);
  $pat_bits=&webui_pattern_effective_bits("IMAGE",$signal_mode);
 }
elsif($pat eq "" && $name eq "uploaded_diag_image") {
 my $requested_filename="";
 $requested_filename=$1 if($body =~ /"filename"\s*:\s*"([^"]{1,240})"/);
 my (undef,$requested_path)=&_webui_diag_asset_resolve_path("image",$requested_filename);
 return '{"status":"error","message":"Diagnostic image not found"}' if($requested_path eq "");
 $pat=&webui_pattern_image_pattern($w,$h,$requested_path);
 $pat_bits=&webui_pattern_effective_bits("IMAGE",$signal_mode);
}
elsif($pat eq "" && $name eq "uploaded_diag_video") {
 my $requested_filename="";
 $requested_filename=$1 if($body =~ /"filename"\s*:\s*"([^"]{1,240})"/);
 my ($requested_name,undef)=&_webui_diag_asset_resolve_path("video",$requested_filename);
 return '{"status":"error","message":"Diagnostic video not found"}' if($requested_name eq "");
 my $diag_sequence=&webui_pattern_uploaded_diag_video_sequence_pattern($requested_name,$w,$h);
 if($diag_sequence ne "") {
  &log("WebUI: uploaded diagnostic video using renderer sequence for $requested_name");
  $pat=$diag_sequence;
  $pat_bits=&webui_pattern_effective_bits("IMAGE",$signal_mode);
 }
 else {
  my $video_result="";
  &video_program_stop("$program_video_to_kill");
  $video_result=&play_video("pg_diag_video_player",$requested_name,"1h-1",$w,$h);
  return '{"status":"error","message":"'.&_webui_json_escape($video_result).'"}' if($video_result ne "OK");
  return '{"status":"ok","pattern":"'.$name.'"}';
 }
}
 # Generic patch takes r,g,b,size params from JSON. Stabilization uses the
 # same renderer path with its independently configured geometry and a
 # mode-correct neutral code.
 elsif($pat eq "" && ($name eq "patch" || $name eq "stabilization")) {
  my ($pr,$pg,$pb,$sz,$imax);
  if($name eq "stabilization") {
   ($pr,$imax)=&webui_meter_stabilization_code(
    $stabilization_stimulus,$signal_mode,$pattern_signal_range,$pgenerator_conf{"max_bpc"}
   );
   $pg=$pr;
   $pb=$pr;
   $sz=$stabilization_size;
   &log("WebUI: displaying stabilization pattern at $stabilization_stimulus% stimulus with size $stabilization_size");
  } else {
   ($pr)=$body=~/"r"\s*:\s*(\d+)/; $pr=0 if(!defined $pr);
   ($pg)=$body=~/"g"\s*:\s*(\d+)/; $pg=0 if(!defined $pg);
   ($pb)=$body=~/"b"\s*:\s*(\d+)/; $pb=0 if(!defined $pb);
   ($sz)=$body=~/"size"\s*:\s*(\d+)/; $sz=100 if(!defined $sz);
   ($imax)=$body=~/"input_max"\s*:\s*(\d+)/;
  }
  my ($raw_pr,$raw_pg,$raw_pb)=($pr,$pg,$pb);
  my $input_max=$imax ? int($imax) : 255;
  ($sim_r,$sim_g,$sim_b)=($raw_pr,$raw_pg,$raw_pb);
  $sim_imax=$imax ? int($imax) : 0;   # resolved just below when 0
  my $target_bits=($signal_mode eq "dv") ? 12 : $pat_bits;
  my $target_max=&webui_pattern_target_max($target_bits);
  $input_max=$target_max if(!$imax && ($pr > 255 || $pg > 255 || $pb > 255));
  $input_max=$target_max if($input_max <= 255 && ($pr > 255 || $pg > 255 || $pb > 255));
  $sim_imax=$input_max if(!$sim_imax);
  $pr=&webui_pattern_scale_value($pr,$input_max,$target_bits);
  $pg=&webui_pattern_scale_value($pg,$input_max,$target_bits);
  $pb=&webui_pattern_scale_value($pb,$input_max,$target_bits);
  $pattern_debug_extra=" raw_rgb=$raw_pr,$raw_pg,$raw_pb scaled_rgb=$pr,$pg,$pb input_max=$input_max";
  my $win_pct=int($sz);
  my $bg_rgb=$black_rgb;
  if($sz >= 101 && $sz <= 998) {
   my $apl_pct=$sz - 100;
   $win_pct=10;
   my $apl_signal_range=($signal_mode eq "dv") ? 1 : $signal_range;
   $bg_rgb=&webui_pattern_apl_bg_triplet($pr,$pg,$pb,$target_bits,$win_pct,$apl_pct,$apl_signal_range,$black_rgb);
  }
  if($win_pct>=100) {
   $pat="DRAW=RECTANGLE\nDIM=$w,$h\nRGB=$pr,$pg,$pb\nBG=$bg_rgb\nPOSITION=0,0\nEND=1\n";
  } else {
   my $s=sqrt($win_pct/100); my $pw=int($w*$s); my $ph=int($h*$s);
   my $px=int(($w-$pw)/2); my $py=int(($h-$ph)/2);
   $pat="DRAW=RECTANGLE\nDIM=$pw,$ph\nRGB=$pr,$pg,$pb\nBG=$bg_rgb\nPOSITION=$px,$py\nEND=1\n";
  }
 }
 # Stop — full black (idle)
 elsif($pat eq "" && $name eq "stop") { $pat="DRAW=RECTANGLE\nDIM=$w,$h\nRGB=$black_rgb\nBG=$black_rgb\nPOSITION=0,0\nEND=1\n"; }
 elsif($pat eq "") {
  return '{"status":"error","message":"Unknown pattern: '.$name.'"}';
 }
 &video_program_stop("$program_video_to_kill");
 # Ensure the C renderer binary is running (auto-start on first pattern)
 if(!&pattern_generator_is_running()) {
  &pattern_generator_start(1);
  Time::HiRes::sleep(0.5);
  if(!&pattern_generator_is_running()) {
   &log("WebUI: renderer failed to start for pattern $name");
   return '{"status":"error","message":"Pattern renderer failed to start"}';
  }
 }
 if($pattern_color_format == 0 && $pat !~/^SOURCE_RANGE=/m) {
  $pat=~s/^END=1$/SOURCE_RANGE=$source_range\nEND=1/mg;
 }
 if($name eq "patch") {
  if(open(my $dfh,">>","/tmp/webui_pattern_debug.log")) {
   print $dfh "[".scalar(localtime())."] patch bits=$pat_bits source_range=$source_range signal_range=".(defined($signal_range)?$signal_range:"")." pattern_signal_range=".(defined($pattern_signal_range)?$pattern_signal_range:"")." transport_signal_range=".(defined($transport_signal_range)?$transport_signal_range:"")." color_format=$pattern_color_format$pattern_debug_extra\n";
   close($dfh);
  }
 }
 # Write the pattern. SOURCE_MAX is independent of BITS: standard DV keeps
 # an 8-bit framebuffer/wire while its tunnel shader consumes 12-bit codes.
 #
 # Multi-frame sequences (AVS diagseq) already end each plate with FRAME=N.
 # Appending FRAME=$frame_default after that creates an empty last frame
 # (n_draw=0) which flashes the screen before the loop restarts. Only add
 # the default FRAME for single-shot patterns that have none.
 $pat="PATTERN_NAME=$name\nBITS=$pat_bits\nSOURCE_MAX=$pattern_source_max\n".$pat;
 $pat.="FRAME=$frame_default\n" if($pat !~ /^FRAME=/m);
 open(my $fh,">","$command_file.tmp");
 print $fh $pat;
 close($fh);
 rename("$command_file.tmp","$command_file");
 &create_return_file();
 # Record what is now on screen for the simulated meter. Patch/stabilization
 # captured raw codes above; named solid fields map to their 8-bit authoring
 # values; everything else (ramps, bars, images) is marked complex.
 if(&webui_meter_simulation_enabled()) {
  if(!defined($sim_r)) {
   my %solid=(white=>[255,255,255],black=>[0,0,0],stop=>[0,0,0],red=>[255,0,0],green=>[0,255,0],blue=>[0,0,255],
              cyan=>[0,255,255],magenta=>[255,0,255],yellow=>[255,255,0],gray50=>[128,128,128]);
   if($solid{$name}) {
    ($sim_r,$sim_g,$sim_b)=@{$solid{$name}};
    $sim_imax=255;
   }
  }
  if(defined($sim_r)) {
   &webui_meter_sim_pattern_record(name=>$name,r=>$sim_r,g=>$sim_g,b=>$sim_b,input_max=>$sim_imax,
    signal_mode=>$signal_mode,source_range=>$source_range,max_luma=>$max_luma,provider=>"local");
  } else {
   &webui_meter_sim_pattern_record(name=>$name,complex=>1,
    signal_mode=>$signal_mode,source_range=>$source_range,max_luma=>$max_luma,provider=>"local");
  }
 }
 return '{"status":"ok","pattern":"'.$name.'"}';
}


###############################################
#              HTML Page                      #
###############################################
my %_webui_asset_allowed = map { $_ => 1 } qw(
 webui.html
 webui-theme.css
 webui-layout.css
 webui-body.html
 webui-logo-dark.html
 webui-app.js
 webui-workspace.js
 webui-lg-card.html
 webui-lg.js
);
my %_webui_asset_cache;
my $_webui_asset_missing="";
my $_webui_html_cache;

sub _webui_asset_path (@) {
 my ($name)=@_;
 my $path=__FILE__;
 $path=~s{[^/]+\z}{$name};
 return $path;
}

sub webui_asset (@) {
 my ($name)=@_;
 if(!defined($name) || !$_webui_asset_allowed{$name}) {
  $_webui_asset_missing=defined($name) ? $name : "(undefined)";
  &log("WebUI ERROR: rejected non-whitelisted UI fragment request: ".($_webui_asset_missing),1);
  return "";
 }
 return $_webui_asset_cache{$name} if(exists($_webui_asset_cache{$name}));
 my $path=&_webui_asset_path($name);
 my $content="";
 if(open(my $fh,"<:raw",$path)) {
  local $/;
  $content=<$fh>//"";
  close($fh);
 }
 if($content eq "") {
  $_webui_asset_missing=$name;
  &log("WebUI ERROR: required UI fragment missing or empty: $name ($path)",1);
  return "";
 }
 # Cache successful reads only. A missing file is deliberately retried on
 # the next request so an OTA/rsync repair takes effect without a restart.
 $_webui_asset_cache{$name}=$content;
 return $content;
}

sub _webui_html_escape (@) {
 my ($value)=@_;
 $value="" if(!defined($value));
 $value=~s/&/&amp;/g;
 $value=~s/</&lt;/g;
 $value=~s/>/&gt;/g;
 $value=~s/"/&quot;/g;
 $value=~s/'/&#39;/g;
 return $value;
}

sub webui_recovery_html (@) {
 my ($missing)=@_;
 $missing="unknown fragment" if(!defined($missing) || $missing eq "");
 my $hostname="";
 if(defined($hostname_file) && open(my $fh,"<:raw",$hostname_file)) {
  local $/;
  $hostname=<$fh>//"";
  close($fh);
 }
 $hostname=~s/[\r\n]+/ /g;
 $hostname=~s/^\s+|\s+$//g;
 if($hostname eq "") {
  # POSIX::uname avoids forking a shell from an ithread mid-request.
  my @uname=eval { POSIX::uname() };
  $hostname=defined($uname[1]) ? $uname[1] : "";
  $hostname=~s/^\s+|\s+$//g;
 }
 $hostname="unknown" if($hostname eq "");
 my $version_text=defined($version) && $version ne "" ? $version : "unknown";
 my $missing_html=&_webui_html_escape($missing);
 my $hostname_html=&_webui_html_escape($hostname);
 my $version_html=&_webui_html_escape($version_text);
 my $html=<<'WEBUI_RECOVERY';
<!doctype html>
<!--PG_RECOVERY_PAGE-->
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>PGenerator+ Web UI recovery</title>
<style>
html{background:#0a0a0f;color:#e0e0e8;font-family:system-ui,sans-serif}
body{max-width:680px;margin:12vh auto;padding:24px;line-height:1.5}
main{background:#14141f;border:1px solid #2a2a3a;border-radius:10px;padding:28px}
h1{margin-top:0;font-size:1.35rem}
p{color:#b4b4c2}
dl{display:grid;grid-template-columns:max-content 1fr;gap:6px 18px;margin:22px 0}
dt{color:#888898}dd{margin:0;overflow-wrap:anywhere}
button{background:#5b7fff;color:#fff;border:0;border-radius:6px;padding:10px 16px;font:inherit;cursor:pointer}
button:hover{background:#718fff}
</style>
</head>
<body>
<main>
<h1>PGenerator+ needs a Web UI repair</h1>
<p>The server is running, but a required UI file is missing or empty.</p>
<dl>
<dt>Missing fragment</dt><dd>__PG_RECOVERY_MISSING__</dd>
<dt>Hostname</dt><dd>__PG_RECOVERY_HOSTNAME__</dd>
<dt>Version</dt><dd>__PG_RECOVERY_VERSION__</dd>
</dl>
<p>Restore the file or use the update button to install the latest cumulative OTA package.</p>
<form action="/api/update/apply" method="post">
<button type="submit">Install latest update</button>
</form>
</main>
</body>
</html>
WEBUI_RECOVERY
 $html=~s/__PG_RECOVERY_MISSING__/$missing_html/g;
 $html=~s/__PG_RECOVERY_HOSTNAME__/$hostname_html/g;
 $html=~s/__PG_RECOVERY_VERSION__/$version_html/g;
 return $html;
}

sub webui_check_assets (@) {
 foreach my $name (sort keys %_webui_asset_allowed) {
  my $content=&webui_asset($name);
  &log("WebUI ERROR: required UI fragment unavailable at boot: $name",1) if($content eq "");
 }
 &log("WebUI ERROR: required UI fragment unavailable at boot: icc_profile.html",1)
  if(defined(&webui_icc_asset) && &webui_icc_asset("icc_profile.html") eq "");
 $_webui_asset_missing="";
 return 1;
}

sub webui_html (@) {
 return $_webui_html_cache if(defined($_webui_html_cache));
 $_webui_asset_missing="";
 my $html=&webui_asset("webui.html");
 return &webui_recovery_html($_webui_asset_missing || "webui.html") if($html eq "");
 foreach my $asset (["__PG_CSS_THEME__","webui-theme.css"],
                    ["__PG_CSS_LAYOUT__","webui-layout.css"],
                    ["__PG_BODY__","webui-body.html"],
                    ["__PG_LOGO_DARK__","webui-logo-dark.html"],
                    ["__PG_JS_APP__","webui-app.js"],
                    ["__PG_JS_WORKSPACE__","webui-workspace.js"]) {
  my ($marker,$name)=@{$asset};
  my $content=&webui_asset($name);
  return &webui_recovery_html($_webui_asset_missing || $name) if($content eq "");
  my $replaced=($html=~s/^\Q$marker\E\n/$content/me);
  if(!$replaced) {
   &log("WebUI ERROR: skeleton marker $marker for $name was not found in webui.html",1);
   return &webui_recovery_html("webui.html (marker $marker not replaced)");
  }
 }
 return &webui_recovery_html($_webui_asset_missing) if($_webui_asset_missing ne "");
 $html =~ s/__PG_LG_CARD__/&webui_lg_card_html()/e;
 $html =~ s/__PG_LG_JS__/&webui_lg_js()/e;
 $html =~ s/__PG_LG_LOAD_INFO__/&webui_lg_load_info_js()/e;
 $html =~ s/__PG_LG_INIT__/&webui_lg_init_js()/e;
 $html =~ s/__PG_GAMUT_PRESETS__/&webui_meter_gamut_js_literal()/e;
 return &webui_recovery_html($_webui_asset_missing) if($_webui_asset_missing ne "");
 # The ICC splice consumes its whole comment marker, so an empty read would
 # slip past the residual __PG_ check below; treat it as a missing fragment.
 my $icc=&webui_icc_asset("icc_profile.html");
 if($icc eq "") {
  &log("WebUI ERROR: required UI fragment missing or empty: icc_profile.html",1);
  return &webui_recovery_html("icc_profile.html");
 }
 $html =~ s/<!--__PG_ICC_PROFILE_HTML__-->/$icc/;
 if($html=~/(__PG_[A-Z0-9_]+__)/) {
  &log("WebUI ERROR: assembled page still contains unreplaced marker $1",1);
  return &webui_recovery_html("webui.html (marker $1 not replaced)");
 }
 $_webui_html_cache=$html;
 return $_webui_html_cache;
}

&webui_check_assets();

return 1;
