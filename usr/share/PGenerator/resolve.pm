#
# PGenerator+ — Resolve Calibration XML Protocol (Client Mode)
#
# Connects outbound to calibration software (CalMAN, HCFR, DisplayCAL)
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
 while(1) {
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
  # Show black pattern when disconnected
  &create_pattern_file("RECTANGLE","$w_s,$h_s",100,"$bg_default","","","","",1,"resolve");
 }
}

###############################################
#      Resolve Trigger Connect (API call)     #
###############################################
sub resolve_trigger_connect (@) {
 my ($ip,$port)=@_;
 $port=$port_resolve if(!$port);
 &log("Resolve: trigger connect to $ip:$port");
 {
  lock($resolve_request_ip);
  $resolve_request_ip=$ip;
  $resolve_request_port=$port;
  cond_signal($resolve_request_ip);
 }
}

###############################################
#         Resolve Outbound Connect            #
###############################################
sub resolve_connect (@) {
 my $ip=shift;
 my $port=shift;
 my $socket;
 # Use alarm-based timeout since IO::Socket::INET Timeout uses non-blocking
 # mode which breaks in threaded Perl on this platform
 eval {
  local $SIG{ALRM}=sub { die "connect timeout\n"; };
  alarm(10);
  $socket=IO::Socket::INET->new(
   PeerHost=>$ip,
   PeerPort=>$port,
   Proto=>'tcp',
  );
  alarm(0);
 };
 alarm(0);
 if(!$socket) {
  my $err=$@||$!;
  &log("Resolve: connection failed to $ip:$port: $err");
  return;
 }
 &log("Resolve: connected to $ip:$port");
 my $last_pattern_key="";
 while(1) {
  #
  # Read 4-byte big-endian length prefix
  #
  my $hdr;
  last if(&resolve_read_exact($socket,\$hdr,4) != 4);
  my $len=unpack("N",$hdr);
  if($len <= 0 || $len > 65536) {
   &log("Resolve: bad message length: $len");
   last;
  }
  #
  # Read XML payload
  #
  my $xml;
  last if(&resolve_read_exact($socket,\$xml,$len) != $len);
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
  # Create pattern from color/background/geometry
  #
  my $bg_str="$r_bg,$g_bg,$b_bg";
  my $rgb_str="$r_p,$g_p,$b_p";
  my $pattern_key="$rgb_str;$bg_str;$geom_x;$geom_y;$geom_cx;$geom_cy;$bits";
  next if($pattern_key eq $last_pattern_key);
  $last_pattern_key=$pattern_key;
  &clean_pattern_files();
  # Full field pattern (geometry covers entire screen)
  if($geom_cx >= 0.99 && $geom_cy >= 0.99) {
   &create_pattern_file("RECTANGLE","$w_s,$h_s",100,"$rgb_str","$bg_str","","","",1,"resolve");
  } else {
   # Windowed pattern — compute pixel dimensions from geometry fractions
   my $win_w=int($geom_cx*$w_s+0.5);
   my $win_h=int($geom_cy*$h_s+0.5);
   my $pos_x=int($geom_x*$w_s+0.5);
   my $pos_y=int($geom_y*$h_s+0.5);
   my $pos_str="$pos_x,$pos_y";
   # Center the window if caller specified origin 0,0 for a non-fullscreen window
   $pos_str=$position_default if($pos_x == 0 && $pos_y == 0);
   &create_pattern_file("RECTANGLE","$win_w,$win_h",100,"$rgb_str","$bg_str","$pos_str","","",1,"resolve");
  }
 }
 $socket->close();
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

return 1;
