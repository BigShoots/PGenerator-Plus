#
# PGenerator+ — Resolve Calibration XML Protocol (Client Mode)
#
# Connects outbound to calibration software (reference, HCFR, DisplayCAL)
# that is listening on a TCP port (default 20002).
#
# Wire format: 4-byte big-endian length prefix + UTF-8 XML payload
#
# XML format (standard Resolve):
#   <calibration>
#     <color red="512" green="512" blue="512" bits="10"/>
#     <background red="0" green="0" blue="0"/>
#     <geometry x="0" y="0" cx="1" cy="1"/>
#   </calibration>
#
# Connection is triggered via:
#   - Web UI "Connect" button → /api/resolve/connect
#   - Setting resolve_ip in PGenerator.conf + reboot
#

###############################################
#         Resolve Connection Thread           #
###############################################
sub resolve_connection_thread (@) {
 &log("Resolve: connection thread started");
 # Outer eval: an uncaught die in a detached ithread can take down the whole
 # process (WebUI "offline") on some Perl builds. Never let this thread exit.
 while(1) {
  eval {
  # Wait until a connection is requested
  {
   lock($resolve_request_ip);
   until($resolve_request_ip ne "") {
    cond_wait($resolve_request_ip);
   }
  }
  my $ip;
  my $port;
  {
   lock($resolve_request_ip);
   $ip=$resolve_request_ip;
   $port=$resolve_request_port||$port_resolve;
   $resolve_request_ip="";
   $resolve_request_port="";
  }
  &log("Resolve: connecting to $ip:$port");
  $calibration_client_ip=$ip;
  $calibration_client_software="Resolve";
  eval { &resolve_connect($ip,$port); };
  &log("Resolve: session error: $@") if($@);
  &log("Resolve: disconnected from $ip:$port");
  $calibration_client_ip="";
  $calibration_client_software="";
  eval { &release_source_rgb_quant_range("resolve"); };
  eval {
   lock($resolve_last_pattern);
   $resolve_last_pattern="";
  };
  # Show black pattern when disconnected
  eval { &create_pattern_file("RECTANGLE","$w_s,$h_s",100,"$bg_default","","","","",1,"resolve"); };
  };
  if($@) {
   &log("Resolve: connection thread recovered from: $@");
   select(undef,undef,undef,0.5);
  }
 }
}

###############################################
#      Resolve Trigger Connect (API call)     #
###############################################
sub resolve_trigger_connect (@) {
 my ($ip,$port)=@_;
 $port=$port_resolve if(!$port);
 &log("Resolve: trigger connect to $ip:$port");
 # Force-close any existing session first so the thread is free to accept
 # a new connect request (session loop is blocked on interruptible read).
 # Guard lock: if share() was mis-ordered at boot the lock croaks and the
 # whole connect path used to abort before queuing the new peer.
 eval {
  lock($resolve_disconnect_request);
  $resolve_disconnect_request=1 if($calibration_client_software eq "Resolve");
 };
 if($@) {
  &log("Resolve: disconnect flag lock failed (shared var?): $@");
 }
 for(my $i=0; $i<30; $i++) {
  last if($calibration_client_software ne "Resolve");
  select(undef,undef,undef,0.1);
 }
 {
  lock($resolve_request_ip);
  $resolve_request_ip=$ip;
  $resolve_request_port=$port;
  cond_signal($resolve_request_ip);
 }
 &log("Resolve: connect request queued for $ip:$port");
}

###############################################
#         Resolve Outbound Connect            #
###############################################
sub resolve_connect (@) {
 my $ip=shift;
 my $port=shift;
 my $socket;
 # Clear any stale disconnect flag from a previous session
 eval {
  lock($resolve_disconnect_request);
  $resolve_disconnect_request=0;
 };
 # Connect BLOCKING, and NEVER with IO::Socket::INET's Timeout param. Timeout
 # makes new() perform a NON-BLOCKING connect + internal select(), which is
 # unreliable in threaded Perl on this platform: the kernel completes the TCP
 # 3-way handshake (the calibration PC, e.g. DisplayCAL, shows "connected")
 # but new() still returns a dead/undef socket, so PGenerator reports
 # "connection failed" on a link that actually came up. A plain blocking
 # connect is handled entirely in the kernel and returns only once the socket
 # is ESTABLISHED (or refused), so it is immune to that race.
 # NEVER use alarm()/SIGALRM to bound it either: process-global SIGALRM can
 # interrupt the wrong thread and take the whole daemon down (WebUI offline)
 # after Connect. An unreachable host just blocks this dedicated thread until
 # the kernel's own connect timeout; the WebUI has its own status-poll timeout.
 eval {
  $socket=IO::Socket::INET->new(
   PeerHost=>$ip,
   PeerPort=>$port,
   Proto=>'tcp',
  );
 };
 if(!$socket) {
  my $err=$@||$!||"refused/unreachable";
  &log("Resolve: connection failed to $ip:$port: $err");
  return;
 }
 &log("Resolve: connected to $ip:$port");
 # Arm SO_LINGER so any close path (requested or peer EOF) issues TCP RST.
 # DisplayCAL never reads the socket and only re-arms its wait() popup after
 # a failed sendall; graceful FIN can leave Windows sockets still "connected".
 eval {
  $socket->setsockopt(SOL_SOCKET, SO_LINGER, pack("ii",1,0))
   or die "setsockopt SO_LINGER: $!";
 };
 &log("Resolve: SO_LINGER=0 arm failed: $@") if($@);
 my $last_pattern_key="";
 my $was_disconnect=0;
 while(1) {
  #
  # Read 4-byte big-endian length prefix (interruptible for disconnect)
  #
  my $hdr;
  my $n=&resolve_read_exact_interruptible($socket,\$hdr,4);
  if($n == -1) {
   $was_disconnect=1;
   last;
  }
  last if($n != 4);
  my $len=unpack("N",$hdr);
  if($len <= 0 || $len > 65536) {
   &log("Resolve: bad message length: $len");
   last;
  }
  #
  # Read XML payload
  #
  my $xml;
  $n=&resolve_read_exact_interruptible($socket,\$xml,$len);
  if($n == -1) {
   $was_disconnect=1;
   last;
  }
  last if($n != $len);
  &log("Resolve RECV: $xml");
  #
  # Parse XML
  #
  my $hash;
  eval {
   $hash=XMLin($xml,ForceArray=>0,KeyAttr=>[]);
  };
  if($@) {
   &log("Resolve: XML parse error: $@");
   next;
  }
  #
  # Extract pattern data (Standard Resolve: <color/> <background/> <geometry/>)
  #
  my ($r_p,$g_p,$b_p,$r_bg,$g_bg,$b_bg,$bits)=(0,0,0,0,0,0,8);
  my ($geom_x,$geom_y,$geom_cx,$geom_cy)=(0,0,1,1);
  if(ref($hash->{color}) eq 'HASH') {
   $r_p=int($hash->{color}{red}||0);
   $g_p=int($hash->{color}{green}||0);
   $b_p=int($hash->{color}{blue}||0);
   $bits=int($hash->{color}{bits}||8);
  }
  if(ref($hash->{background}) eq 'HASH') {
   $r_bg=int($hash->{background}{red}||0);
   $g_bg=int($hash->{background}{green}||0);
   $b_bg=int($hash->{background}{blue}||0);
  }
  if(ref($hash->{geometry}) eq 'HASH') {
   $geom_x=&resolve_float($hash->{geometry}{x});
   $geom_y=&resolve_float($hash->{geometry}{y});
   $geom_cx=&resolve_float($hash->{geometry}{cx}||"1");
   $geom_cy=&resolve_float($hash->{geometry}{cy}||"1");
  }
  #
  # LightSpace format fallback: <shapes><rectangle>...</rectangle></shapes>
  #
  if(!ref($hash->{color}) && ref($hash->{shapes}) eq 'HASH') {
   my $rects=$hash->{shapes}{rectangle};
   my @rect_list=ref($rects) eq 'ARRAY' ? @$rects : ($rects);
   if(@rect_list >= 1) {
    my $fg=(@rect_list >= 2) ? $rect_list[1] : $rect_list[0];
    my $col=$fg->{colex}||$fg->{color};
    if(ref($col) eq 'HASH') {
     $r_p=int($col->{red}||0);
     $g_p=int($col->{green}||0);
     $b_p=int($col->{blue}||0);
     $bits=int($col->{bits}||8);
    }
    if(ref($fg->{geometry}) eq 'HASH') {
     $geom_x=&resolve_float($fg->{geometry}{x});
     $geom_y=&resolve_float($fg->{geometry}{y});
     $geom_cx=&resolve_float($fg->{geometry}{cx}||"1");
     $geom_cy=&resolve_float($fg->{geometry}{cy}||"1");
    }
    if(@rect_list >= 2) {
     my $bgcol=$rect_list[0]->{color}||$rect_list[0]->{colex};
     if(ref($bgcol) eq 'HASH') {
      $r_bg=int($bgcol->{red}||0);
      $g_bg=int($bgcol->{green}||0);
      $b_bg=int($bgcol->{blue}||0);
     }
    }
   }
  }
  #
  # Sync bit depth from XML to PGenerator config if changed
  #
  if($bits > 0 && $bits != $bits_default) {
   &resolve_save_setting("max_bpc","$bits");
   &pattern_generator_stop();
   &pattern_generator_start();
  }
  #
  # Create pattern from color/background/geometry. Dedupe on the RAW sent
  # values PLUS the operator override knobs, so a knob change redraws even
  # when the software re-sends the same pattern. The raw pattern is also
  # stored so the WebUI can redraw it immediately when a knob changes
  # (resolve_redraw_last) without waiting for the next message.
  #
  my $pattern_key="$r_p,$g_p,$b_p;$r_bg,$g_bg,$b_bg;$geom_x;$geom_y;$geom_cx;$geom_cy;$bits;"
   .($pgenerator_conf{"resolve_force_center"}||"")."/".($pgenerator_conf{"resolve_patch_size"}||"");
  next if($pattern_key eq $last_pattern_key);
  $last_pattern_key=$pattern_key;
  {
   lock($resolve_last_pattern);
   $resolve_last_pattern="$r_p,$g_p,$b_p;$r_bg,$g_bg,$b_bg;$geom_x,$geom_y,$geom_cx,$geom_cy;$bits";
  }
  &apply_source_rgb_quant_range("resolve",2);
  &resolve_draw_pattern($r_p,$g_p,$b_p,$r_bg,$g_bg,$b_bg,$geom_x,$geom_y,$geom_cx,$geom_cy);
 }
 if($was_disconnect) {
  &log("Resolve: disconnect requested, closing socket");
 }
 &resolve_force_close_socket($socket);
 {
  lock($resolve_disconnect_request);
  $resolve_disconnect_request=0;
 }
}

###############################################
#   Force TCP RST close (DisplayCAL re-arm)   #
###############################################
# DisplayCAL's Resolve path never reads the socket and only re-shows its
# connection wait popup after the next sendall fails (no peer-disconnect
# watch). A graceful FIN can leave the peer socket half-open on Windows;
# SO_LINGER onoff=1 linger=0 + close produces RST so the next send fails.
sub resolve_force_close_socket (@) {
 my $socket=shift;
 return if(!$socket);
 # Do NOT shutdown() first: that can send a graceful FIN and leave the peer
 # in CLOSE_WAIT. DisplayCAL never reads the socket, so FIN-only often leaves
 # its next sendall succeeding. SO_LINGER+close alone produces RST.
 &log("Resolve: forcing TCP RST close (SO_LINGER=0)");
 eval {
  $socket->setsockopt(SOL_SOCKET, SO_LINGER, pack("ii",1,0))
   or die "setsockopt SO_LINGER: $!";
 };
 &log("Resolve: SO_LINGER set failed: $@") if($@);
 eval { $socket->close(); };
 &log("Resolve: close failed: $@") if($@);
}

###############################################
#          Resolve Read Exact Bytes           #
###############################################
sub resolve_read_exact (@) {
 my ($sock,$buf_ref,$wanted)=@_;
 $$buf_ref="";
 my $got=0;
 while($got < $wanted) {
  my $chunk;
  my $n=$sock->sysread($chunk,$wanted-$got);
  return $got if(!defined($n) || $n == 0);
  $$buf_ref.=$chunk;
  $got+=$n;
 }
 return $got;
}

###############################################
#   Resolve Read Exact (interruptible)        #
###############################################
# Like resolve_read_exact, but wakes every 0.5s to honor
# $resolve_disconnect_request so WebUI disconnect can RST the TCP session.
# Returns: $wanted on success, 0..$wanted-1 on EOF/error, -1 if disconnect
# was requested.
sub resolve_read_exact_interruptible (@) {
 my ($sock,$buf_ref,$wanted)=@_;
 $$buf_ref="";
 my $got=0;
 while($got < $wanted) {
  {
   lock($resolve_disconnect_request);
   if($resolve_disconnect_request) {
    return -1;
   }
  }
  my $rvec='';
  my $fn=fileno($sock);
  return $got if(!defined($fn) || $fn < 0);
  vec($rvec, $fn, 1)=1;
  my $nready=select(my $rout=$rvec, undef, undef, 0.5);
  if(!defined($nready) || $nready < 0) {
   return $got;
  }
  if($nready == 0) {
   next; # timeout — re-check disconnect flag
  }
  my $chunk;
  my $n=$sock->sysread($chunk,$wanted-$got);
  return $got if(!defined($n) || $n == 0);
  $$buf_ref.=$chunk;
  $got+=$n;
 }
 return $got;
}

###############################################
#          Resolve Save Setting               #
###############################################
sub resolve_save_setting (@) {
 my ($conf_key,$conf_val)=@_;
 &sudo("SET_PGENERATOR_CONF",$conf_key,$conf_val);
 $pgenerator_conf{$conf_key}="$conf_val";
 # Note: bits_default is NOT synced to max_bpc — EGL surface is always 8bpc
 &log("Resolve: saved $conf_key=$conf_val");
}

###############################################
#          Resolve Float Helper               #
###############################################
sub resolve_float (@) {
 my $val=shift||"0";
 $val=~s/,/\./g;
 return $val+0;
}


###############################################
#      Resolve Draw Pattern (with overrides)  #
###############################################
# Applies the operator override knobs to a RAW received pattern and draws it.
sub resolve_draw_pattern (@) {
 my ($r_p,$g_p,$b_p,$r_bg,$g_bg,$b_bg,$geom_x,$geom_y,$geom_cx,$geom_cy)=@_;
 #
 # Patch-size override (WebUI Resolve card "Patch Size Override"): N% of
 # screen AREA, same convention as the meter Patch Size dropdown (linear
 # scale = sqrt(pct/100)). Keeps the sent window's centre and resizes
 # around it (clamped to the screen), so it composes with the software's
 # positioning and with "Force centered patch". Empty/invalid conf =
 # follow the software.
 #
 my $size_ovr=defined($pgenerator_conf{"resolve_patch_size"}) ? $pgenerator_conf{"resolve_patch_size"} : "";
 $size_ovr="" if($size_ovr!~/^\d+$/ || $size_ovr+0 < 1 || $size_ovr+0 > 100);
 if($size_ovr ne "") {
  if($size_ovr+0 >= 100) {
   ($geom_x,$geom_y,$geom_cx,$geom_cy)=(0,0,1,1);
  } else {
   my $s=sqrt(($size_ovr+0)/100.0);
   my $ctr_x=$geom_x+$geom_cx/2.0;
   my $ctr_y=$geom_y+$geom_cy/2.0;
   ($geom_cx,$geom_cy)=($s,$s);
   $geom_x=$ctr_x-$s/2.0;
   $geom_y=$ctr_y-$s/2.0;
   $geom_x=0 if($geom_x < 0); $geom_y=0 if($geom_y < 0);
   $geom_x=1.0-$s if($geom_x > 1.0-$s);
   $geom_y=1.0-$s if($geom_y > 1.0-$s);
  }
 }
 my $rgb_str="$r_p,$g_p,$b_p";
 my $bg_str="$r_bg,$g_bg,$b_bg";
 &clean_pattern_files();
 # Full field pattern (geometry covers entire screen)
 if($geom_cx >= 0.99 && $geom_cy >= 0.99) {
  &create_pattern_file("RECTANGLE","$w_s,$h_s",100,"$rgb_str","$bg_str","","","",1,"resolve");
 } else {
  # Windowed pattern -- compute pixel dimensions from geometry fractions
  my $win_w=int($geom_cx*$w_s+0.5);
  my $win_h=int($geom_cy*$h_s+0.5);
  my $pos_x=int($geom_x*$w_s+0.5);
  my $pos_y=int($geom_y*$h_s+0.5);
  my $pos_str="$pos_x,$pos_y";
  # Center the window if caller specified origin 0,0 for a non-fullscreen window
  $pos_str=$position_default if($pos_x == 0 && $pos_y == 0);
  # Operator override (WebUI Resolve card "Force centered patch"): ignore
  # the sent window position -- DisplayCAL mirrors its measurement frame
  # position here, which is easy to leave off-center without noticing.
  # The protocol carries no client identity, so this applies to every
  # Resolve-protocol sender. Size still follows the sent geometry.
  $pos_str=$position_default if(($pgenerator_conf{"resolve_force_center"}||"") eq "1");
  &create_pattern_file("RECTANGLE","$win_w,$win_h",100,"$rgb_str","$bg_str","$pos_str","","",1,"resolve");
 }
}

###############################################
#      Resolve Redraw Last Pattern            #
###############################################
# Redraw the last received Resolve pattern with the CURRENT override knobs.
# Called from the WebUI config-apply path so toggling the Resolve card
# settings updates the on-screen patch immediately instead of waiting for
# the calibration software's next pattern message.
sub resolve_redraw_last (@) {
 my $last;
 {
  lock($resolve_last_pattern);
  $last=$resolve_last_pattern;
 }
 return 0 if(!defined($last) || $last eq "");
 my ($rgb,$bg,$geom,$bits)=split(";",$last);
 my ($r_p,$g_p,$b_p)=split(",",$rgb||"");
 my ($r_bg,$g_bg,$b_bg)=split(",",$bg||"");
 my ($gx,$gy,$gcx,$gcy)=split(",",$geom||"");
 return 0 if(!defined($b_p) || !defined($gcy));
 &log("Resolve: redrawing last pattern with updated override settings");
 &resolve_draw_pattern($r_p,$g_p,$b_p,$r_bg,$g_bg,$b_bg,$gx,$gy,$gcx,$gcy);
 return 1;
}

return 1;
