#
# PiTPG protocol 2 on port 85: ColourSpace's "PiTPG" hardware entry
# connects to PGenerator+ as it does to a PiTPG. PGPiTPG.pm checks and
# answers the requests; this file is the backend that does what they ask
# with what the classic port 85 commands use (pgenerator_cmd for the
# settings, the signal gate and renderer restart for applying them,
# create_pattern_file for patches), so a PiTPG client gets the same output
# a classic ColourSpace connection gets.
#
use PGPiTPG;
use PGTestEdid ();
use PGEdidCaps ();
use PGEdidDolby ();
use PGMath ();

our %pitpg_conn=();
our %pitpg_checked=();
# The renderer's report of the first flip showing a new pattern (pid, load
# count, DRM sequence, time in us, frame period in us).
our $pitpg_presented_file="$var_dir/running/presented";
# pitpgd's receive buffer: a message and its length.
our $pitpg_buffer_max=0x100004;
# How long a patch reply waits for the flip that shows it.
our $pitpg_present_timeout=2.0;

sub pitpg_open (@) {
 my ($connection,$rest)=@_;
 $pitpg_conn{$connection}={buf=>""};
 # A client that stops reading must not hold the daemon: sends give up
 # after 5 s (pitpgd's SO_SNDTIMEO) and the connection closes.
 eval { $connection->setsockopt(SOL_SOCKET,SO_SNDTIMEO,pack('l!l!',5,0)) };
 &log("PiTPG: protocol 2 client peer=".($client_ip{$connection} || ""));
 &pitpg_receive($connection,$rest) if(defined($rest) && $rest ne "");
}

# Bytes from a PiTPG client: every whole message is answered in order.
sub pitpg_receive (@) {
 my ($connection,$bytes)=@_;
 my $st=$pitpg_conn{$connection};
 return if(!$st);
 if($bytes eq "") {
  &close_connection($connection,"client eof");
  return;
 }
 $st->{buf}.=$bytes;
 if(length($st->{buf}) > $pitpg_buffer_max) {
  &close_connection($connection,"PiTPG message too long");
  return;
 }
 my ($msgs,$err)=PGPiTPG::take_messages(\$st->{buf});
 foreach my $m (@$msgs) {
  $signal_gate_owner="$connection";
  $signal_refused_pending=0;
  &calibration_session_touch($connection);
  my ($reply,$close)=PGPiTPG::handle(&pitpg_backend($connection),$m);
  # A refusal is in the reply; nothing is left for the next one.
  $signal_refused_pending=0;
  return if(!&pitpg_send($connection,PGPiTPG::frame($reply)));
  if($close) {
   &close_connection($connection,"PiTPG bye");
   return;
  }
 }
 &close_connection($connection,"PiTPG: $err") if($err ne "");
}

# The whole reply or the connection closes. 1 when sent.
sub pitpg_send (@) {
 my ($connection,$data)=@_;
 my $off=0;
 while($off < length($data)) {
  my $n=eval { $connection->send(substr($data,$off)) };
  if(!defined($n) || $n <= 0) {
   my $why=$@ || $! || "nothing sent";
   $why=~s/\s+$//;
   &close_connection($connection,"send error: $why");
   return 0;
  }
  $off+=$n;
 }
 return 1;
}

# The client is gone (close_connection): the patch scale it chose ends with it.
sub pitpg_closed (@) {
 my ($connection,$st)=@_;
 &log("PiTPG: client closed peer=".($client_ip{$connection} || ""));
 # As pitpgd: when no PiTPG client is left, the client's patch depth and
 # scale end. pitpgd leaves the output as it is until the next apply; here
 # the output follows the conf again at once, so the cable shows what the
 # WebUI does.
 if(!grep { $_ ne "$connection" } keys %pitpg_conn) {
  # A refusal now belongs to no socket: the client is gone.
  local $signal_gate_owner="";
  &pitpg_apply_output("PiTPG client closed") if(&pitpg_clear_patch_state());
 }
}

###############################################
#              Simple requests                #
###############################################
sub pitpg_hello (@) {
 my $model=&read_from_file("/proc/device-tree/model");
 $model=~s/\x00.*//s;
 $model=~s/^\s+|\s+$//g;
 my $host=&read_from_file($hostname_file);
 $host=~s/^\s+|\s+$//g;
 return {model=>$model,hostname=>$host,server=>"$version_plus $version"};
}

# Why nothing can be shown, in the order pitpgd checks: the link was
# interrupted during a run, no display, refused settings. () when it can.
# pitpgd's link alert: an HDMI link event during a run is returned to the
# patches that follow until 2 s after it was first reported.
our %pitpg_link_alert_seen=();
our $pitpg_link_alert_ms=2000;
sub pitpg_refusal (@) {
 my @ev=&hdmi_link_events();
 if(@ev && ($ev[-1]{during} // "") ne "") {
  my $e=$ev[-1];
  my $now=Time::HiRes::time();
  my $first=$pitpg_link_alert_seen{$e->{id}} //= $now;
  if(($now-$first)*1000 < $pitpg_link_alert_ms) {
   my @t=localtime($e->{time} || 0);
   my $what=$e->{text} ne "" ? $e->{text} : $e->{event};
   return ("link_interrupted",sprintf("The HDMI link to the display was interrupted at %02d:%02d:%02d (%s). The display may have reset; run the measurements again from the start.",$t[2],$t[1],$t[0],$what));
  }
 }
 if(!&hdmi_sink_connected()) {
  return ("no_display","No display is connected to the HDMI port of the Pi (or it is off), so nothing can be shown.");
 }
 my $why=&signal_patches_refused();
 return ("settings_not_applied","The current settings could not be applied, so nothing is shown. $why") if($why ne "");
 return ();
}

# Texts of hdmi_info, edid_info, log, kernel_log and infoframes, in
# pitpgd's formats (v1-layer.md 1.7, 1.8, 4).
sub pitpg_text (@) {
 my $op=shift;
 return ("",&pitpg_hdmi_info()) if($op eq "hdmi_info");
 return ("",&pitpg_edid_info()) if($op eq "edid_info");
 if($op eq "log") {
  # pitpgd keeps the last 300 lines.
  my $tail=&pitpg_file_tail($log_file,262144);
  my @l=split(/\n/,$tail);
  # A tail cut from a longer file starts inside a line.
  shift(@l) if(@l && (-s $log_file || 0) > length($tail));
  @l=@l[-300..-1] if(@l > 300);
  return ("",join("",map { "$_\n" } @l));
 }
 if($op eq "kernel_log") {
  # The kernel ring buffer as klogctl reads it (<N> priority prefixes),
  # its last 49152 bytes as pitpgd returns.
  my $t=`timeout 3 $dmesg -r 2>/dev/null`;
  $t=`timeout 3 $dmesg 2>/dev/null` if(!defined($t) || $t eq "" || $?);
  return ("failed","The kernel log could not be read.") if(!defined($t) || $t eq "" || $?);
  $t=substr($t,-49152) if(length($t) > 49152);
  return ("",$t);
 }
 return ("",&pitpg_infoframes()) if($op eq "infoframes");
 return ("unsupported","No text for $op.");
}

# "MODETEST (<mode index>) <fmt> <range> <aspect>, WxH @ hz Hz,
# progressive|interlaced, up to N-bit" and pitpgd's clauses, from the
# connector state get_hdmi_info reads back.
sub pitpg_hdmi_info (@) {
 return "No display connected" if(!&hdmi_sink_connected());
 my $r=&get_hdmi_info() // "";
 return "No display connected" if($r!~/MODETEST \((\d+)\) (\S+) (\S+) (\S+)\], (\d+x\d+) \@ ([\d.]+)Hz, (\w+)/);
 my ($idx,$fmt,$range,$aspect,$size,$hz,$scan)=($1,$2,$3,$4,$5,$6,$7);
 my $bpc=&pitpg_wire_bpc();
 my $t=sprintf("MODETEST (%d) %s %s %s, %s @ %.2fHz, %s, up to %d-bit",$idx,$fmt,$range,$aspect,$size,$hz,$scan,$bpc);
 $t.=" ($bpc-bit link: 8/10-bit patch values sent exactly)" if($bpc > 10);
 my (undef,$raw)=&pitpg_edid();
 my ($dvmax)=&pitpg_display_luminance($raw);
 if(&pitpg_dv_ll()) {
  $t.=", Dolby Vision Low-Latency";
 } elsif(&pitpg_dv_tv_led()) {
  $t.=", Dolby Vision TV-led (12-bit YCbCr 4:2:2 limited range in RGB tunnel)";
 }
 $t.=sprintf(", display declares a %.0f cd/m2 peak",$dvmax) if(&legacy_external_dv_active() && $dvmax > 0);
 $t.=", TEST EDID in use (not the display's own)" if(PGTestEdid::test_edid_active());
 return $t;
}

# pitpgd GET_EDID_INFO: connector, hex dump (16 bytes a line, a blank line
# after each block), a rule, the decoded EDID, at most 11000 characters,
# returned base64-encoded (as pitpgd's protocol 2 reply carries it).
sub pitpg_edid_info (@) {
 my ($port,$raw)=&pitpg_edid();
 my $t=($port ne "" ? $port : "HDMI-A-1")."\n";
 if($raw eq "") {
  $t.="No info available";
 } else {
  for(my $i=0;$i<length($raw);$i+=16) {
   $t.=join(" ",map { sprintf("%02x",$_) } unpack("C*",substr($raw,$i,16)))."\n";
   $t.="\n" if(($i+16) % 128 == 0);
  }
  my $tmp="$info_dir/PITPG_EDID.bin";
  &write_file("$tmp.TMP",$tmp,$raw);
  $t.="\n----------------\n\n".&parse_edid($tmp);
  unlink($tmp);
 }
 $t=substr($t,0,11000)."\n(truncated)" if(length($t) > 11000);
 return encode_base64($t,"");
}

# pitpgd's infoframes text: a line per frame, "%-8s" and its bytes in
# hex, the AVI one decoded. From DRM debugfs when it is readable (as
# pitpgd), else from the vc4 driver's "AVI IF / DRM IF / SPD IF" kernel
# lines (the same bytes: header, checksum, payload).
sub pitpg_infoframes (@) {
 my ($port)=&signal_connected_port();
 return "No display connected\n" if($port eq "");
 my %frame;
 foreach my $dir (sort glob("/sys/kernel/debug/dri/*/$port/infoframes")) {
  foreach my $n (qw(avi hdr_drm hdmi spd audio)) {
   my $f="$dir/$n";
   $f.="/payload" if(-d $f);
   next if(!-r $f || !open(my $fh,"<",$f));
   binmode($fh);
   my $b="";
   read($fh,$b,64);
   close($fh);
   $frame{$n}=$b;
  }
  last if(%frame);
 }
 my $source="DRM debugfs";
 if(!%frame) {
  $source="kernel log";
  my (undef,$avi,$drm,$spd)=&webui_last_infoframes();
  my %hex=(avi=>$avi,hdr_drm=>$drm,spd=>$spd);
  foreach my $n (keys %hex) {
   next if(!defined($hex{$n}) || $hex{$n} eq "");
   $frame{$n}=pack("C*",map { hex($_) } grep { $_ ne "" } split(/:/,$hex{$n}));
  }
 }
 my $t="";
 foreach my $n (qw(avi hdr_drm hdmi spd audio)) {
  if(!exists($frame{$n})) {
   $t.=sprintf("%-8s (not read)\n",$n) if($source eq "kernel log");
   $t.=sprintf("%-8s (not sent)\n",$n) if($source ne "kernel log");
   next;
  }
  my @b=unpack("C*",$frame{$n});
  if(!@b) { $t.=sprintf("%-8s (not sent)\n",$n); next; }
  $t.=sprintf("%-8s",$n).join("",map { sprintf(" %02x",$_) } @b);
  if($n eq "avi" && @b >= 6) {
   my @fmt=("RGB","YCbCr 4:2:2","YCbCr 4:4:4","YCbCr 4:2:0");
   my @q=("Default","Limited","Full","Reserved");
   my @yq=("Limited","Full","Reserved","Reserved");
   $t.=sprintf("  [%s, Q %s, YQ %s, VIC %d]",$fmt[($b[4] >> 5) & 3],@b > 6 ? $q[($b[6] >> 2) & 3] : $q[0],
               @b > 8 ? $yq[($b[8] >> 6) & 3] : "Limited",@b > 7 ? $b[7] & 0x7f : 0);
  }
  $t.="\n";
 }
 $t.="(from the $source)\n";
 return $t;
}

sub pitpg_file_tail (@) {
 my ($file,$max)=@_;
 open(my $fh,"<",$file) or return "";
 my $size=-s $fh || 0;
 seek($fh,$size-$max,0) if($size > $max);
 local $/;
 my $t=<$fh>;
 close($fh);
 return defined($t) ? $t : "";
}

###############################################
#              Renderer frames                #
###############################################
# (pid, load count, seq, time_us, period_us) of the last report, () if none.
sub pitpg_presented (@) {
 open(my $fh,"<",$pitpg_presented_file) or return ();
 my $line=<$fh>;
 close($fh);
 return () if(!defined($line) || $line!~/^(\d+) (\d+) (\d+) (\d+) (\d+)\s*$/);
 return ($1,$2,$3,$4,$5);
}

# Waits until the renderer reports the flip of the pattern written at
# $written_us (CLOCK_MONOTONIC, the clock of DRM's flip events): from the
# renderer of @before a later load, from a new renderer process a flip
# after the write (its first report can be a pattern parsed before it).
# At most $pitpg_present_timeout seconds. Returns {seq,time_us,period_us}
# of the newest report and whether it is the pattern's.
sub pitpg_wait_presented (@) {
 my ($written_us,@before)=@_;
 my $until=Time::HiRes::time()+$pitpg_present_timeout;
 my $shown=sub {
  my @n=@_;
  return 0 if(!@n);
  return $n[1] > $before[1] ? 1 : 0 if(@before && $n[0] == $before[0]);
  return $n[3] >= $written_us ? 1 : 0;
 };
 my @now;
 while(1) {
  @now=&pitpg_presented();
  last if($shown->(@now));
  if(Time::HiRes::time() >= $until) {
   &log("PiTPG: no flip reported for the new pattern within ${pitpg_present_timeout}s");
   last;
  }
  select(undef,undef,undef,0.005);
 }
 return ({seq=>@now ? $now[2] : 0,time_us=>@now ? $now[3] : 0,period_us=>@now ? $now[4] : 0},$shown->(@now));
}

sub pitpg_monotonic_us (@) {
 return PGPiTPG::monotonic_us();
}

###############################################
#                 Backend                     #
###############################################
# pitpgd's settings table (v1-layer.md 1.1): min and max of each integer
# setting. The names are PGenerator's conf keys, so each value goes to the
# conf through pgenerator_cmd as a classic CMD:SET_PGENERATOR_CONF_<KEY>
# does (min_luma in 0.0001 cd/m2 there and here); mode is a string and
# becomes mode_idx.
our %pitpg_setting_range=(eotf=>[0,3],colorimetry=>[0,15],max_luma=>[0,65535],min_luma=>[0,65535],
 max_cll=>[0,65535],max_fall=>[0,65535],color_format=>[0,3],rgb_quant_range=>[0,3],primaries=>[0,5],
 max_bpc=>[8,12],dv_status=>[0,1],dv_interface=>[0,1],dv_metadata=>[0,255],is_ll_dovi=>[0,1],
 is_std_dovi=>[0,1],is_sdr=>[0,1],is_hdr=>[0,1],dv_color_space=>[0,255],dv_profile=>[0,255],
 dv_map_mode=>[0,255],dv_minpq=>[0,4095],dv_maxpq=>[0,4095],dv_diagonal=>[0,65535]);
# What a PiTPG client set ("" = unset); state.settings shows it, the conf
# for keys no client set.
our %pitpg_settings=();
# A mode the display does not offer: the next apply is refused with it.
our $pitpg_mode_error="";
# The client's patch depth (0 none, 8, 10) and patch scale (-1 none, 0 full,
# 1 legal, 2 extended, 3 user). As in pitpgd the link follows them: an 8-bit
# patch goes out on an 8-bit link, a 10-bit one needs a 10-bit link, and
# the RGB range label follows the scale. They end with the next settings
# apply and when the last PiTPG client closes. While they are in effect the
# client's own max_bpc / rgb_quant_range are kept here and put back then.
our $pitpg_bit_depth=0;
our $pitpg_patch_range=-1;
our %pitpg_client_value=();
# The same values on disk while they are in effect: the conf holds the
# patch's depth or label, so a daemon that stops in between (crash, power)
# puts the client's own values back at its next start
# (pitpg_client_values_recover). A subdirectory: clean_files keeps it.
our $pitpg_client_values_file="$var_dir/pitpg/client-values";
# The last patch (window, colours, depth): test patterns are drawn in it.
our %pitpg_last_patch=();

sub pitpg_backend (@) {
 my $connection=shift;
 return {
  hello=>sub { &pitpg_granger_prepare(); return &pitpg_hello(); },
  log=>sub {
   my $text=shift;
   &log($text);
   if($text=~/client: (.+)$/ && $1 ne "(unnamed)") {
    # The name reaches the status bar and /api/info: the same characters
    # as a classic client's name (legacy_external_set_client_name).
    (my $name=$1)=~s/[^A-Za-z0-9 ._+()\/-]//g;
    $name=~s/^\s+|\s+$//g;
    $pitpg_conn{$connection}{client}=substr($name,0,64) if($name ne "");
   }
   &pitpg_session($connection);
  },
  state=>sub { return &pitpg_state(); },
  snapshot=>sub { return &pitpg_snapshot(); },
  restore=>sub { &pitpg_restore(shift); },
  set_setting=>sub { &pitpg_session($connection); return &pitpg_set_setting(@_); },
  set_setting_direct=>sub {
   my ($k,$v)=@_;
   $pitpg_settings{$k}=$v;
   # As a value the client sends: it replaces one kept while the link
   # followed the patch scale.
   &pitpg_client_value_drop($k);
   &pitpg_conf_set($k,$v);
  },
  apply=>sub { return &pitpg_apply(); },
  apply_live=>sub { &pitpg_apply_live(shift); },
  refusal=>sub { return &pitpg_refusal(); },
  patch=>sub { &pitpg_session($connection); return &pitpg_patch(shift); },
  test_pattern=>sub { &pitpg_session($connection); return &pitpg_test_pattern(shift); },
  text=>sub { return &pitpg_text(shift); },
 };
}

# A session (status bar, WebUI signal lock) opens with the client's hello
# or first command, not with the bare connect (as the classic port 85).
sub pitpg_session (@) {
 my $connection=shift;
 my $name=$pitpg_conn{$connection}{client} // "";
 &calibration_session_open($connection,$name=~/ColourSpace/i ? "ColourSpace" : ($name ne "" ? "ColourSpace ($name)" : "ColourSpace"));
}

sub pitpg_conf_set (@) {
 my ($k,$v)=@_;
 &pgenerator_cmd("SET_PGENERATOR_CONF_".uc($k).":$v");
}

# The value a setting has for a client: what it set, else the conf.
sub pitpg_setting_value (@) {
 my $k=shift;
 return $pitpg_settings{$k} if(exists $pitpg_settings{$k});
 return $pitpg_client_value{$k} if(exists $pitpg_client_value{$k});
 my $v=$pgenerator_conf{$k};
 $v=&pg_min_luma_cmd_nits_to_wire($v) if($k eq "min_luma" && defined($v) && $v ne "");
 return defined($v) ? "$v" : "";
}

sub pitpg_client_value_drop (@) {
 my $k=shift;
 return if(!exists $pitpg_client_value{$k});
 delete $pitpg_client_value{$k};
 &pitpg_client_values_store();
}

sub pitpg_client_value_keep (@) {
 my ($k,$v)=@_;
 return if(exists $pitpg_client_value{$k});
 $pitpg_client_value{$k}=$v;
 &pitpg_client_values_store();
}

sub pitpg_client_values_store (@) {
 my $f=$pitpg_client_values_file;
 if(!%pitpg_client_value) {
  unlink($f) if(-e $f);
  return 1;
 }
 (my $d=$f)=~s{/[^/]+$}{};
 mkdir($d) if(!-d $d);
 my $data=join("",map { "$_=$pitpg_client_value{$_}\n" } sort keys %pitpg_client_value);
 my $ok=open(my $fh,">","$f.tmp") ? 1 : 0;
 $ok=0 if($ok && !print $fh $data);
 $ok=0 if($ok && !close($fh));
 $ok=0 if($ok && !rename("$f.tmp",$f));
 &log("PiTPG: could not keep the client's settings in $f: $!") if(!$ok);
 return $ok;
}

# Daemon start: values a PiTPG client's patch depth or scale replaced
# when the daemon stopped go back to the conf.
sub pitpg_client_values_recover (@) {
 my $f=$pitpg_client_values_file;
 open(my $fh,"<",$f) or return 0;
 my @pairs;
 while(my $l=<$fh>) {
  push(@pairs,$1,$2) if($l=~/^(max_bpc|rgb_quant_range)=(\d*)\s*$/);
 }
 close($fh);
 if(@pairs) {
  my $ok=&set_pgenerator_conf_runtime_multi(@pairs) // "";
  if($ok!~/^\Q$ok_response\E/) {
   &log("PiTPG: client settings from the last session could not be put back: $ok");
   return 0;
  }
  &log("PiTPG: client settings from the last session put back: ".join(" ",@pairs));
 }
 unlink($f);
 return 1;
}

sub pitpg_set_setting (@) {
 my ($k,$v)=@_;
 if($k eq "mode") {
  $pitpg_mode_error="";
  $pitpg_settings{mode}=$v;
  if($v eq "") {
   &pitpg_conf_set("mode_idx","");
   &invalidate_hdmi_info_cache();
   return "";
  }
  my $m=&pitpg_mode_parse($v);
  return "Mode ".substr($v,0,40)." is not in the form 3840x2160\@60.00." if(!$m);
  my $idx=&pitpg_mode_match($m);
  if($idx < 0) {
   # As pitpgd: taken now, refused when the output is applied.
   $pitpg_mode_error="The display does not offer $v (the chosen resolution and refresh rate); choose one of its modes.";
   return "";
  }
  &pitpg_conf_set("mode_idx",$idx);
  &invalidate_hdmi_info_cache();
  return "";
 }
 my $r=$pitpg_setting_range{$k};
 return "Setting $k is not known." if(!$r);
 if($v ne "") {
  return "Setting $k=".substr($v,0,40)." is not accepted ($k is $r->[0] to $r->[1])." if($v!~/^-?\d+$/ || $v < $r->[0] || $v > $r->[1]);
 }
 $pitpg_settings{$k}=$v;
 # The client's own value replaces one kept while the link followed it.
 &pitpg_client_value_drop($k);
 # pitpgd labels rgb_quant_range 3 as full (output_decide: 1 limited,
 # 0 default, else full); PGenerator+ has 0, 1 and 2.
 &pitpg_conf_set($k,($k eq "rgb_quant_range" && $v eq "3") ? "2" : $v);
 return "";
}

our @pitpg_snapshot_keys=(@signal_conf_keys,@signal_metadata_keys,qw(dv_minpq dv_maxpq dv_diagonal));
sub pitpg_snapshot (@) {
 my %conf=map { ($_ => defined($pgenerator_conf{$_}) ? "$pgenerator_conf{$_}" : "") } @pitpg_snapshot_keys;
 return {conf=>\%conf,settings=>{%pitpg_settings},client=>{%pitpg_client_value},mode_error=>$pitpg_mode_error,
         bit_depth=>$pitpg_bit_depth,patch_range=>$pitpg_patch_range};
}

sub pitpg_restore (@) {
 my $s=shift;
 return if(ref($s) ne "HASH");
 my @pairs;
 foreach my $k (@pitpg_snapshot_keys) {
  my $want=$s->{conf}{$k} // "";
  my $cur=defined($pgenerator_conf{$k}) ? "$pgenerator_conf{$k}" : "";
  push(@pairs,$k,$want) if($want ne $cur);
 }
 if(@pairs) {
  my $ok=&set_pgenerator_conf_runtime_multi(@pairs) // "";
  &log("PiTPG: settings could not be put back: $ok") if($ok!~/^\Q$ok_response\E/);
  unlink("$info_dir/GET_PGENERATOR_CONF_ALL.info");
 }
 %pitpg_settings=%{$s->{settings}};
 %pitpg_client_value=%{$s->{client}};
 &pitpg_client_values_store();
 $pitpg_mode_error=$s->{mode_error};
 $pitpg_bit_depth=$s->{bit_depth};
 $pitpg_patch_range=$s->{patch_range};
}

# The client's depth and scale end; its own max_bpc / rgb_quant_range go
# back to the conf. No apply here: the caller applies. Returns how many
# conf keys changed.
sub pitpg_clear_patch_state (@) {
 my @pairs;
 foreach my $k (sort keys %pitpg_client_value) {
  push(@pairs,$k,$pitpg_client_value{$k}) if(($pgenerator_conf{$k} // "") ne $pitpg_client_value{$k});
 }
 &set_pgenerator_conf_runtime_multi(@pairs) if(@pairs);
 %pitpg_client_value=();
 &pitpg_client_values_store();
 &log("PiTPG: client bit depth and range cleared") if($pitpg_bit_depth || $pitpg_patch_range >= 0);
 $pitpg_bit_depth=0;
 $pitpg_patch_range=-1;
 return scalar(@pairs)/2;
}

# Settings sent and applied through the gate (as RESTARTPGENERATOR).
sub pitpg_apply (@) {
 &pitpg_clear_patch_state();
 if($pitpg_mode_error ne "") {
  # As a refusal of the signal gate: patches are refused until settings
  # that work come (the protocol puts the conf back).
  $signal_refused_pending=1;
  &signal_refused_set(source=>"ColourSpace",reason=>$pitpg_mode_error,code=>"mode",requested=>$pitpg_settings{mode} // "",
                      kept=>"",alternatives=>"",restored=>1,owner=>defined($signal_gate_owner) ? $signal_gate_owner : "");
  &log("Signal: ColourSpace asked for mode ".($pitpg_settings{mode} // "").": refused: $pitpg_mode_error");
  &webui_notice("Settings refused","ColourSpace asked for ".($pitpg_settings{mode} // "").". $pitpg_mode_error") if(defined &webui_notice);
  return $pitpg_mode_error;
 }
 return &pitpg_apply_output("PiTPG settings");
}

sub pitpg_apply_output (@) {
 my $who=shift;
 if(!$is_kms || &signal_gate_conf(&signal_source_label("ColourSpace"))) {
  &pattern_generator_restart_unless_current($who);
  return "";
 }
 return "Refused: ".&signal_patches_refused();
}

# HDR metadata: in place while HDR10/HLG is on (not Low-Latency DV), as
# pitpgd; otherwise it waits for the next apply.
sub pitpg_apply_live (@) {
 my $keys=shift;
 return if(int($pgenerator_conf{"is_hdr"} || 0) != 1 || int($pgenerator_conf{"is_ll_dovi"} || 0) == 1);
 if(!$is_kms || &signal_gate_conf(&signal_source_label("ColourSpace"))) {
  my %changed=map { ($_ => 1) } grep { $PGPiTPG::LIVE_KEY{$_} } @$keys;
  &pattern_generator_restart_unless_current("PiTPG HDR metadata") if(!&renderer_reconfigure_in_place(\%changed));
  &log("PiTPG: HDR metadata updated");
 }
}

###############################################
#                  Modes                      #
###############################################
# pitpgd's mode_parse: "WxH@Hz" or "WxHi@Hz", W and H 64..16384, Hz 1..1000.
sub pitpg_mode_parse (@) {
 my $s=shift;
 return undef if(!defined($s) || $s!~/^(\d+)x(\d+)(i?)\@(\d+(?:\.\d+)?)$/);
 my ($w,$h,$i,$hz)=($1+0,$2+0,$3 eq "i" ? 1 : 0,$4+0);
 return undef if($w < 64 || $w > 16384 || $h < 64 || $h > 16384 || $hz < 1 || $hz > 1000);
 return {w=>$w,h=>$h,interlaced=>$i,hz=>$hz};
}

# Modes of the first connected connector in modetest -c output: index,
# size, interlace, hz = clock kHz * 1000 / (htotal * vtotal) as pitpgd
# computes it, and the modetest type (preferred, userdef, driver).
sub pitpg_modes_parse (@) {
 my $out=shift;
 my @modes=();
 my $in=0;
 foreach my $l (split(/\n/,defined($out) ? $out : "")) {
  if($l=~/^\d+\s+\d+\s+(connected|disconnected|unknown)\s/) {
   last if($in);
   $in=($1 eq "connected") ? 1 : 0;
   next;
  }
  next if(!$in);
  next if($l!~/^\s*#(\d+)\s+(\d+)x(\d+)(i?)\s+([\d.]+)\s+\d+\s+\d+\s+\d+\s+(\d+)\s+\d+\s+\d+\s+\d+\s+(\d+)\s+(\d+)\s+flags:[^;]*;\s*type:\s*(.*)$/);
  my ($idx,$w,$h,$i,$refresh,$htot,$vtot,$clock,$type)=($1,$2,$3,$4,$5,$6,$7,$8,$9);
  my $hz=($htot && $vtot) ? $clock*1000/($htot*$vtot) : $refresh+0;
  push(@modes,{idx=>$idx+0,w=>$w+0,h=>$h+0,interlaced=>$i eq "i" ? 1 : 0,hz=>$hz,clock_khz=>$clock+0,
               preferred=>($type=~/preferred/) ? 1 : 0,userdef=>($type=~/userdef/) ? 1 : 0});
 }
 return @modes;
}

sub pitpg_modes (@) {
 my $out=`timeout 3 $modetest -c 2>/dev/null`;
 return &pitpg_modes_parse($out);
}

sub pitpg_mode_describe (@) {
 my $m=shift;
 return sprintf("%dx%d%s\@%.2f",$m->{w},$m->{h},$m->{interlaced} ? "i" : "",$m->{hz});
}

# Exact size and interlace, |hz difference| < 0.005 (pitpgd apply_now).
# pitpgd takes the first match or a later preferred one; here the EDID's
# copy of a timing also wins over the userdef boot mode (which goes out
# with VIC 0 and a full-range AVI infoframe, see calman_find_mode_idx).
# -1 when none.
sub pitpg_mode_match (@) {
 my ($want,@modes)=@_;
 @modes=&pitpg_modes() if(!@modes);
 my ($found,$score)=(-1,-1);
 foreach my $m (@modes) {
  next if($m->{w} != $want->{w} || $m->{h} != $want->{h} || $m->{interlaced} != $want->{interlaced});
  next if(abs($m->{hz}-$want->{hz}) >= 0.005);
  my $sc=($m->{userdef} ? 0 : 2)+($m->{preferred} ? 1 : 0);
  ($found,$score)=($m->{idx},$sc) if($sc > $score);
 }
 return $found;
}

# The mode the renderer drives: mode_idx when set, else the preferred one.
sub pitpg_current_mode (@) {
 my @modes=@_;
 my $idx=$pgenerator_conf{"mode_idx"} // "";
 foreach my $m (@modes) { return $m if($idx ne "" && $m->{idx} == $idx); }
 foreach my $m (@modes) { return $m if($m->{preferred}); }
 return @modes ? $modes[0] : undef;
}

###############################################
#              Output and state               #
###############################################
sub pitpg_dv_tv_led (@) {
 return (int($pgenerator_conf{"dv_status"} || 0) == 1 && int($pgenerator_conf{"is_std_dovi"} || 0) == 1) ? 1 : 0;
}
sub pitpg_dv_ll (@) {
 return (int($pgenerator_conf{"dv_status"} || 0) == 1 && int($pgenerator_conf{"is_ll_dovi"} || 0) == 1) ? 1 : 0;
}
# Bits per component on the link as drm_override.so and the renderer
# (main.cpp applySignalConf) set it: max_bpc, at least 10 for 4:2:2, and
# 12 only in Dolby Vision. 8 or 10 for the framebuffer.
sub pitpg_link_bits (@) {
 my $bpc=int($pgenerator_conf{"max_bpc"} || 8);
 $bpc=10 if(int($pgenerator_conf{"color_format"} || 0) == 2 && $bpc < 10);
 return ($bpc >= 10) ? 10 : 8;
}

# Bits per component on the cable: the renderer's wire_bpc (12 only with
# dv_status 1), 8 for Dolby Vision TV-led's RGB tunnel.
sub pitpg_wire_bpc (@) {
 return 8 if(&pitpg_dv_tv_led());
 my $bpc=int($pgenerator_conf{"max_bpc"} || 8);
 $bpc=10 if(int($pgenerator_conf{"color_format"} || 0) == 2 && $bpc < 10);
 $bpc=10 if($bpc == 12 && int($pgenerator_conf{"dv_status"} || 0) != 1);
 return $bpc;
}

sub pitpg_signal (@) {
 return "dv_tv_led" if(&pitpg_dv_tv_led());
 return "dv_low_latency" if(&pitpg_dv_ll());
 return (int($pgenerator_conf{"eotf"} // 0) == 3 ? "hlg" : "hdr10") if(int($pgenerator_conf{"is_hdr"} || 0) == 1);
 return "sdr";
}

sub pitpg_edid (@) {
 my ($port,$file)=&signal_connected_port();
 return ("","") if($port eq "");
 my $raw=&read_from_file($file);
 return ($port,defined($raw) ? $raw : "");
}

# Display monitor name descriptor (tag 0xFC) of the base block.
sub pitpg_edid_name (@) {
 my $raw=shift;
 return "" if(length($raw) < 128);
 for(my $o=54;$o<=108;$o+=18) {
  my $d=substr($raw,$o,18);
  next if(substr($d,0,3) ne "\x00\x00\x00" || ord(substr($d,3,1)) != 0xfc);
  my $n=substr($d,5,13);
  $n=~s/\x0a.*//s;
  $n=~s/[^\x20-\x7e]//g;
  $n=~s/\s+$//;
  return substr($n,0,15);
 }
 return "";
}

# Peaks the display declares: (dv max, dv min, hdr max, hdr min) in cd/m2.
sub pitpg_display_luminance (@) {
 my $raw=shift;
 my ($dvmax,$dvmin,$hmax,$hmin)=(0,0,0,0);
 if(length($raw) >= 256) {
  my $dv=PGEdidDolby::dolby_vsvdb_from_edid($raw);
  ($dvmax,$dvmin)=($dv->{max_nits} || 0,$dv->{min_nits} || 0) if($dv);
 }
 my $caps=PGEdidCaps::edid_caps_from_raw($raw);
 ($hmax,$hmin)=($caps->{hdr_max_nits} || 0,$caps->{hdr_min_nits} || 0) if($caps);
 return ($dvmax,$dvmin,$hmax,$hmin);
}

sub pitpg_state (@) {
 my %settings;
 foreach my $k (@PGPiTPG::SETTING_KEYS) {
  my $v;
  if($k eq "mode") {
   $v=$pitpg_settings{mode};
  } else {
   $v=&pitpg_setting_value($k);
  }
  next if(!defined($v) || $v eq "");
  $settings{$k}=($k ne "mode" && $v=~/^-?\d+$/) ? PGPiTPG::num($v) : $v;
 }
 my @modes=&hdmi_sink_connected() ? &pitpg_modes() : ();
 my $cur=@modes ? &pitpg_current_mode(@modes) : undef;
 $settings{mode}=&pitpg_mode_describe($cur) if(!exists $settings{mode} && $cur);
 my $output;
 if($cur) {
  my $cf=int($pgenerator_conf{"color_format"} || 0);
  my $blocked=&signal_patches_refused();
  $output={mode=>&pitpg_mode_describe($cur),w=>PGPiTPG::num($cur->{w}),h=>PGPiTPG::num($cur->{h}),
           hz=>PGPiTPG::raw(sprintf("%.3f",$cur->{hz})),interlaced=>$cur->{interlaced} ? \1 : \0,
           format=>$cf == 1 ? "ycc444" : ($cf == 2 ? "ycc422" : ($cf == 3 ? "ycc420" : "rgb")),
           bits=>PGPiTPG::num(&pitpg_wire_bpc()),
           range=>($cf == 0 && &effective_rgb_quant_range() == 2) ? "full" : "limited",
           signal=>&pitpg_signal(),depth_note=>"",blocked=>$blocked ne "" ? $blocked : undef};
 }
 my ($port,$raw)=&pitpg_edid();
 my ($dvmax,$dvmin,$hmax,$hmin)=&pitpg_display_luminance($raw);
 my %lum;
 $lum{dv}={max=>PGPiTPG::raw(sprintf("%.1f",$dvmax)),min=>PGPiTPG::raw(sprintf("%.4f",$dvmin))} if($dvmax > 0);
 $lum{hdr}={max=>PGPiTPG::raw(sprintf("%.1f",$hmax)),min=>PGPiTPG::raw(sprintf("%.4f",$hmin))} if($hmax > 0);
 my @test_edid=PGTestEdid::test_edid_active();
 my $display={connected=>($port ne "") ? \1 : \0,name=>&pitpg_edid_name($raw),test_edid=>@test_edid ? \1 : \0,
              edid=>$raw ne "" ? encode_base64($raw,"") : "",luminance=>\%lum};
 my @sorted=map { $_->[1] } sort { $b->[1]{w} <=> $a->[1]{w} || $a->[0] <=> $b->[0] } map { [$_,$modes[$_]] } 0..$#modes;
 my @mlist=map { {mode=>&pitpg_mode_describe($_),w=>PGPiTPG::num($_->{w}),h=>PGPiTPG::num($_->{h}),
                  hz=>PGPiTPG::raw(sprintf("%.3f",$_->{hz})),interlaced=>$_->{interlaced} ? \1 : \0,
                  clock_khz=>PGPiTPG::num($_->{clock_khz}),preferred=>$_->{preferred} ? \1 : \0} } @sorted;
 my @ev=&hdmi_link_events();
 my $last="";
 if(@ev) {
  my @t=localtime($ev[-1]{time} || 0);
  $last=sprintf("%02d:%02d:%02d %s (%s)",$t[2],$t[1],$t[0],$ev[-1]{text} ne "" ? $ev[-1]{text} : $ev[-1]{event},
                $ev[-1]{during} ne "" ? "during a run" : "not during a run");
 }
 return {settings=>\%settings,output=>$output,display=>$display,modes=>\@mlist,link=>{last_event=>$last}};
}

###############################################
#                  Patches                    #
###############################################
# The client's patch scale. Codes are never rescaled (pitpgd patch_pack):
# the scale picks the RGB range label; YCbCr is always limited, so a full
# scale is refused there. Returns ("") or (code,message).
sub pitpg_set_patch_range (@) {
 my $r=shift;
 my $ycc=(($pgenerator_conf{"color_format"} || "0") ne "0") ? 1 : 0;
 if(&pitpg_dv_tv_led()) {
  # PGenerator+ sends Dolby Vision TV-led as a limited-range signal only.
  return ("range","Dolby Vision TV-led goes out as a limited-range Dolby signal here. Set Patch Scale in ColourSpace Settings to Legal.") if($r == 0 || $r == 2);
 } elsif($ycc) {
  return ("range","ColourSpace is set to Full range, but YCbCr is always sent as limited range. Set Patch Scale in ColourSpace Settings to Legal.") if($r == 0);
 } else {
  my $client=exists($pitpg_client_value{rgb_quant_range}) ? $pitpg_client_value{rgb_quant_range} : ($pgenerator_conf{"rgb_quant_range"} // "");
  my $label=($r == 0) ? "2" : (($r == 1 || $r == 2) ? "1" : $client);
  if(($pgenerator_conf{"rgb_quant_range"} // "") ne $label) {
   &pitpg_client_value_keep("rgb_quant_range",$client);
   &set_pgenerator_conf_runtime("rgb_quant_range",$label);
   my $why=&pitpg_apply_output("PiTPG patch scale");
   return ("settings_not_applied","The patch scale could not be applied. $why") if($why ne "");
   &log("PiTPG: RGB range label now follows ColourSpace: ".($label eq "2" ? "Full" : ($label eq "1" ? "Limited" : "Default")));
  }
 }
 $pitpg_patch_range=$r;
 return ("");
}

# The client's patch depth: the link follows it outside Dolby Vision.
sub pitpg_set_bit_depth (@) {
 my $bits=shift;
 $pitpg_bit_depth=$bits;
 return ("") if(&legacy_external_dv_active());
 return ("") if(&pitpg_link_bits() == $bits);
 # 4:2:2 has at least 10 bits: an 8-bit patch goes out as v << 2.
 return ("") if($bits == 8 && int($pgenerator_conf{"color_format"} || 0) == 2);
 my $client=exists($pitpg_client_value{max_bpc}) ? $pitpg_client_value{max_bpc} : ($pgenerator_conf{"max_bpc"} // "");
 &pitpg_client_value_keep("max_bpc",$client);
 &set_pgenerator_conf_runtime("max_bpc",$bits);
 my $why=&pitpg_apply_output("PiTPG bit depth");
 if($why ne "") {
  $pitpg_bit_depth=0;
  return ("bit_depth","10-bit patch, but the output cannot be 10-bit here. $why Set ColourSpace to 8-bit.") if($bits == 10);
  return ("settings_not_applied","The 8-bit output could not be applied. $why");
 }
 &log("PiTPG: client bit depth: $bits");
 return ("");
}

sub pitpg_screen (@) {
 &get_hdmi_info();
 my ($w,$h)=(int($w_s || 0),int($h_s || 0));
 return ($w > 0 && $h > 0) ? ($w,$h) : (1920,1080);
}

# The framebuffer depth codes are drawn at outside standard Dolby Vision.
sub pitpg_fb_bits (@) {
 return &pitpg_link_bits() >= 10 ? 10 : 8;
}

# pitpgd patch_pack: a code of $bits on a framebuffer of $fb bits. No
# range scaling: 8 -> 10 is v << 2, 10 -> 8 is (v + 2) >> 2 (255 from 1022).
sub pitpg_pack (@) {
 my ($v,$bits,$fb)=@_;
 return $v if($bits == $fb);
 return $v << 2 if($bits == 8 && $fb == 10);
 return $v >= 1022 ? 255 : ($v+2) >> 2;
}

# A frame: {bg=>[r,g,b], draws=>[[x,y,w,h,r,g,b] or {image,x,y,w,h}], ms}.
# Codes are wire codes at $fb bits (pitpgd never rescales them by range),
# so every draw is SOURCE_RANGE=LIMITED: the renderer then passes them on
# as they are (RGB Limited passthrough, RGB Full, YCbCr studio-range
# input). In standard Dolby Vision the codes are scaled to the 12-bit
# tunnel source as classic patches are (SOURCE_MAX=4095, BITS=8).
sub pitpg_pattern_string (@) {
 my ($fb,$frames)=@_;
 my $dv=(&legacy_external_dv_source_max() == 4095) ? 1 : 0;
 my $scale=sub { return $dv ? map { &legacy_external_scale_dv_value($_,$fb) } @_ : @_; };
 my $ps="MOVIE_NAME=TestPattern\n".($dv ? "BITS=8\nSOURCE_MAX=4095\n" : "BITS=$fb\n");
 my $n=0;
 foreach my $f (@$frames) {
  my $bg=join(",",$scale->(@{$f->{bg}}));
  my $first=1;
  foreach my $d (@{$f->{draws}}) {
   my $b=$first ? $bg : "-1,-1,-1";
   if(ref($d) eq "HASH") {
    $ps.="DRAW=IMAGE\nDIM=$d->{w},$d->{h}\nRGB=0,0,0\nBG=$b\nPOSITION=$d->{x},$d->{y}\nIMAGE=$d->{image}\nEND=1\n";
   } else {
    my ($x,$y,$w,$h,@c)=@$d;
    $ps.="DRAW=RECTANGLE\nDIM=$w,$h\nRESOLUTION=0\nRGB=".join(",",$scale->(@c))."\nBG=$b\nPOSITION=$x,$y\nTEXT=\nEND=1\n";
   }
   $first=0;
  }
  $ps.="FRAME_NAME=PiTPG_".($n++)."\nFRAME=".($f->{ms} || $frame_default)."\n";
 }
 return $ps;
}

# Draws the frames and waits for the flip that shows them: that flip's
# {seq,time_us,period_us}, undef when none came (pitpgd: "could not be
# shown").
sub pitpg_show (@) {
 my ($fb,$frames)=@_;
 my $ps=&pitpg_pattern_string($fb,$frames);
 my @before=&pitpg_presented();
 my $written=&pitpg_monotonic_us();
 &clean_pattern_files();
 &create_tmp_file($ps,&legacy_external_dv_active() ? "" : "LIMITED");
 &load_new_pattern_file("PiTPG");
 my ($frame,$shown)=&pitpg_wait_presented($written,@before);
 return $shown ? $frame : undef;
}

sub pitpg_patch (@) {
 my $p=shift;
 if($p->{range} >= 0 && $p->{range} != $pitpg_patch_range) {
  my @e=&pitpg_set_patch_range($p->{range});
  return @e if($e[0] ne "");
 }
 if($p->{bits} != $pitpg_bit_depth) {
  my @e=&pitpg_set_bit_depth($p->{bits});
  return @e if($e[0] ne "");
 }
 if($p->{bits} == 10 && !&pitpg_dv_tv_led() && &pitpg_link_bits() < 10) {
  return ("bit_depth","10-bit patch, but the output is 8-bit (max_bpc ".($pgenerator_conf{"max_bpc"} || 8)."). Set ColourSpace to 8-bit.");
 }
 my ($W,$H)=&pitpg_screen();
 my ($x,$y,$w,$h)=$p->{rect} ? @{$p->{rect}} : (0,0,$W,$H);
 # -1 centres (as pitpgd).
 $x=int(($W-$w)/2) if($x == -1);
 $y=int(($H-$h)/2) if($y == -1);
 %pitpg_last_patch=(x=>$x,y=>$y,w=>$w,h=>$h,rgb=>[@{$p->{rgb}}],bg=>[@{$p->{bg}}],bits=>$p->{bits});
 # Standard DV: the patch's own codes, scaled to the 12-bit tunnel source.
 my $fb=&pitpg_dv_tv_led() ? $p->{bits} : &pitpg_fb_bits();
 my $frame=&pitpg_show($fb,[&pitpg_patch_frame($W,$H,$fb)]);
 return ("failed","The patch could not be shown: the renderer reported no new frame.") if(!$frame);
 &log("PiTPG: patch ".join(",",@{$p->{rgb}})." bg ".join(",",@{$p->{bg}})." $p->{bits}-bit at $x,$y ${w}x$h");
 return ("",$frame,&pitpg_peak_note($p));
}

# The last patch (black, 8-bit, full screen when none) as a frame at $fb
# bits: background, then the rect clipped to the screen.
sub pitpg_patch_frame (@) {
 my ($W,$H,$fb)=@_;
 my %lp=%pitpg_last_patch ? %pitpg_last_patch : (x=>0,y=>0,w=>$W,h=>$H,rgb=>[0,0,0],bg=>[0,0,0],bits=>8);
 my @bg=map { &pitpg_pack($_,$lp{bits},$fb) } @{$lp{bg}};
 my @fg=map { &pitpg_pack($_,$lp{bits},$fb) } @{$lp{rgb}};
 my @r=&pitpg_clip($lp{x},$lp{y},$lp{w},$lp{h},$W,$H);
 my @draws=@r ? ([@r,@fg]) : ([0,0,$W,$H,@bg]);
 return {bg=>\@bg,draws=>\@draws,ms=>$frame_default};
}

sub pitpg_clip (@) {
 my ($x,$y,$w,$h,$W,$H)=@_;
 my ($x0,$y0)=($x < 0 ? 0 : $x,$y < 0 ? 0 : $y);
 my ($x1,$y1)=($x+$w > $W ? $W : $x+$w,$y+$h > $H ? $H : $y+$h);
 return () if($x1 <= $x0 || $y1 <= $y0);
 return ($x0,$y0,$x1-$x0,$y1-$y0);
}

# pitpgd's peak note: only with HDR10 (PQ) or Dolby Vision. The brightest
# channel PQ-decoded (legal or full code range, as the scale and the
# link), against the display's declared peak (Dolby Vision block for DV,
# else the HDR block; the other one when that is missing).
sub pitpg_peak_note (@) {
 my $p=shift;
 my $dv=&legacy_external_dv_active();
 return "" if(!$dv && !(int($pgenerator_conf{"is_hdr"} || 0) == 1 && int($pgenerator_conf{"eotf"} // 0) == 2));
 my (undef,$raw)=&pitpg_edid();
 return "" if($raw eq "");
 my ($dvmax,undef,$hmax)=&pitpg_display_luminance($raw);
 my ($peak,$block)=$dv ? ($dvmax,"Dolby Vision block") : ($hmax,"HDR block");
 ($peak,$block)=$dv ? ($hmax,"HDR block") : ($dvmax,"Dolby Vision block") if($peak <= 0);
 return "" if($peak <= 0);
 my $legal;
 if(&pitpg_dv_tv_led()) {
  # PGenerator+ sends Dolby Vision TV-led as limited range only.
  $legal=1;
 } elsif($pitpg_patch_range < 0 || $pitpg_patch_range == 3) {
  $legal=(($pgenerator_conf{"color_format"} || "0") ne "0" || &effective_rgb_quant_range() == 1) ? 1 : 0;
 } else {
  $legal=($pitpg_patch_range == 1 || $pitpg_patch_range == 2) ? 1 : 0;
 }
 my $b=$p->{bits};
 my ($lo,$span)=$legal ? (16*2**($b-8),219*2**($b-8)) : (0,2**$b-1);
 my $max=0;
 foreach my $v (@{$p->{rgb}}) {
  my $e=($v-$lo)/$span;
  next if($e <= 0);
  $e=1 if($e > 1);
  my $nits=PGMath::pq_decode_nits($e);
  $max=$nits if($nits > $max);
 }
 return "" if($max <= $peak*1.005);
 return sprintf("Above the display's declared peak: patch %.0f cd/m2, display %.0f cd/m2 (its EDID's %s); the display will clip or tone-map this patch.",$max,$peak,$block);
}

###############################################
#               Test patterns                 #
###############################################
# The 12 PiTPG test patterns (v1-layer.md 3.3, decomp/testpat_level.c),
# drawn inside the last patch's window. Each level L (0..255, fractional
# for the ramps and GRANGER) becomes pitpgd's code.isra.0:
# lround(2^fb/2^bits * ((max-min) * (L/255) + min)), clamped to the
# framebuffer depth.
our @pitpg_contrast_levels=([191,199,207,215,223,231,239,247],[223,227,231,235,239,243,247,251],
                            [239,241,243,245,247,249,251,253],[247,248,249,250,251,252,253,254]);
our @pitpg_brightness_levels=([1,2,3,4,5,6,7,8],[2,4,6,8,10,12,14,15],
                              [4,8,12,16,20,24,28,32],[8,16,24,32,40,48,56,64]);
our %pitpg_test_pattern_known=map { ($_ => 1) } qw(CONTRAST BRIGHTNESS ANSI_1 ANSI_2 CORNER_BOX_1 CORNER_BOX_2
 PROBE_ALIGNMENT GRANGER RAMP_BW_HORIZ RAMP_BW_VERT FALD);

sub pitpg_level_code (@) {
 my ($l,$min,$max,$bits,$fb)=@_;
 my $c=((2**$fb)/(2**$bits))*(($max-$min)*($l/255)+$min);
 $c=int($c+0.5);
 my $top=2**$fb-1;
 return $c < 0 ? 0 : ($c > $top ? $top : $c);
}

sub pitpg_test_pattern (@) {
 my $p=shift;
 my ($W,$H)=&pitpg_screen();
 my $fb=&pitpg_fb_bits();
 my $name=uc($p->{name});
 if($p->{off} || $name eq "PATCH") {
  &log("PiTPG: test pattern off - patches again");
  my $pfb=&pitpg_dv_tv_led() ? ($pitpg_last_patch{bits} || 8) : $fb;
  my $frame=&pitpg_show($pfb,[&pitpg_patch_frame($W,$H,$pfb)]);
  return $frame ? ("",$frame) : ("failed","The patch could not be shown: the renderer reported no new frame.");
 }
 return ("failed","Unknown test pattern '$p->{name}'.") if(!$pitpg_test_pattern_known{$name});
 my $bits=$p->{bits} // 8;
 my $min=$p->{min} // 0;
 my $max=$p->{max} // 255;
 return ("failed","Test pattern levels must be min < max < ".(2**$bits).".") if($min >= $max || $max >= 2**$bits);
 return ("failed","GRANGER is not available while Dolby Vision is on here.") if($name eq "GRANGER" && &legacy_external_dv_active());
 # The window: the last patch clipped to the screen; none or empty is the
 # full screen.
 my @win=%pitpg_last_patch ? &pitpg_clip(@pitpg_last_patch{qw(x y w h)},$W,$H) : ();
 @win=(0,0,$W,$H) if(!@win);
 my ($wx,$wy,$ww,$wh)=@win;
 # pitpgd testpat_window: the DV tunnel window starts at an even x.
 if(&pitpg_dv_tv_led() && $wx % 2) { $wx--; $ww++ if($wx+$ww < $W); }
 my $code=sub { return &pitpg_level_code(shift,$min,$max,$bits,$fb); };
 my ($bgl,@rects)=&pitpg_test_rects($name,$ww,$wh,$code);
 if($name eq "GRANGER") {
  my $file=&pitpg_granger_file($ww,$wh,$min,$max,$bits,$fb);
  return ("failed","The test pattern could not be shown.") if($file eq "");
  @rects=({image=>$file,x=>0,y=>0,w=>$ww,h=>$wh});
 }
 my @bgc=($code->($bgl)) x 3;
 my $base=&pitpg_patch_frame($W,$H,$fb);
 my $full=($ww == $W && $wh == $H) ? 1 : 0;
 my @frame_bg=$full ? @bgc : @{$base->{bg}};
 my $window=[$wx,$wy,$ww,$wh,@bgc];
 # In the window only (testpat_level sets the window's pixels): a shape
 # larger than a small window is cut at its edges.
 my @pattern;
 foreach my $r (@rects) {
  if(ref($r) eq "HASH") { push(@pattern,{%$r,x=>$r->{x}+$wx,y=>$r->{y}+$wy}); next; }
  my @c=&pitpg_clip($wx+$r->[0],$wy+$r->[1],$r->[2],$r->[3],$wx+$ww,$wy+$wh);
  next if(!@c);
  my ($x0,$y0)=($c[0] < $wx ? $wx : $c[0],$c[1] < $wy ? $wy : $c[1]);
  my ($x1,$y1)=($c[0]+$c[2],$c[1]+$c[3]);
  next if($x1 <= $x0 || $y1 <= $y0);
  push(@pattern,[$x0,$y0,$x1-$x0,$y1-$y0,@$r[4..6]]);
 }
 my @frames=({bg=>\@frame_bg,draws=>[$window,@pattern],ms=>$frame_default});
 if($name eq "CONTRAST" || $name eq "BRIGHTNESS") {
  # Blink: 500 ms the cells, 500 ms the plain background.
  $frames[0]{ms}=500;
  push(@frames,{bg=>\@frame_bg,draws=>[$window],ms=>500});
 }
 &log("PiTPG: test pattern $name (levels $min-$max at $bits-bit)");
 my $frame=&pitpg_show($fb,\@frames);
 return $frame ? ("",$frame) : ("failed","The test pattern could not be shown: the renderer reported no new frame.");
}

# (background L, [x,y,w,h,r,g,b]...) in window coordinates, codes from
# $code; testpat_level.c's bounds (inclusive ends become widths).
sub pitpg_test_rects (@) {
 my ($name,$W,$H,$code)=@_;
 my @r;
 my $grey=sub { my ($x,$y,$w,$h,$l)=@_; return [$x,$y,$w,$h,($code->($l)) x 3]; };
 if($name eq "CONTRAST" || $name eq "BRIGHTNESS") {
  my $tab=$name eq "CONTRAST" ? \@pitpg_contrast_levels : \@pitpg_brightness_levels;
  my ($cw,$rh)=($W/8.0,$H*0.25);
  my ($g,$gh)=($cw*0.25,$rh*0.25);
  for my $j (0..3) {
   my $ry0=int($gh/2+$j*$rh);
   my $ry1=int($ry0+$rh-$gh);
   for my $i (0..7) {
    my $cx0=int($g/2+$i*$cw);
    my $cx1=int($cx0+$cw-$g);
    push(@r,$grey->($cx0,$ry0,$cx1-$cx0+1,$ry1-$ry0+1,$tab->[$j][$i]));
   }
  }
  return ($name eq "CONTRAST" ? 255 : 0,@r);
 }
 if($name eq "ANSI_1" || $name eq "ANSI_2") {
  my ($cw,$ch)=(int($W/4),int($H/4));
  for my $j (0..3) {
   for my $i (0..3) {
    push(@r,$grey->($i*$cw,$j*$ch,$cw,$ch,255)) if(($i+$j+($name eq "ANSI_2" ? 1 : 0)) % 2);
   }
  }
  return (0,@r);
 }
 if($name eq "CORNER_BOX_1") {
  my ($bw,$bh)=($W/5.0,$H/5.0);
  my ($x0,$y0)=(int($W*0.5-$bw*0.5),int($H*0.5-$bh*0.5));
  my ($x1,$y1)=(int($x0+$bw-1),int($y0+$bh-1));
  return (0,$grey->($x0,$y0,$x1-$x0+1,$y1-$y0+1,255));
 }
 if($name eq "CORNER_BOX_2") {
  my ($bw,$bh)=(int($W/10),int($H/10));
  return (0,map { $grey->(@$_,$bw,$bh,255) } ([0,0],[$W-$bw,0],[0,$H-$bh],[$W-$bw,$H-$bh]));
 }
 if($name eq "PROBE_ALIGNMENT") {
  my ($s,$t)=(int($W/3),int($W/30));
  my ($x0,$y0)=(int(($W-$s)/2),int(($H-$s)/2));
  return (0,$grey->($x0,$y0,$s,$s,48),$grey->($x0+$t,int($H/2),$s-2*$t,1,219),$grey->(int($W/2),$y0+$t,1,$s-2*$t,219));
 }
 if($name eq "RAMP_BW_HORIZ" || $name eq "RAMP_BW_VERT") {
  # L = x*255/W (y*255/H), not rounded before the code: neighbouring
  # columns (rows) with the same code become one strip.
  my $horiz=($name eq "RAMP_BW_HORIZ") ? 1 : 0;
  my $len=$horiz ? $W : $H;
  my ($start,$prev)=(0,undef);
  for my $i (0..$len) {
   my $c=$i < $len ? $code->($i*255.0/$len) : -1;
   if(defined($prev) && $c != $prev) {
    push(@r,$horiz ? [$start,0,$i-$start,$H,($prev) x 3] : [0,$start,$W,$i-$start,($prev) x 3]);
    $start=$i;
   }
   $prev=$c;
  }
  return (0,@r);
 }
 if($name eq "FALD") {
  my ($cw,$ch)=(int($W/16),int($H/9));
  push(@r,$grey->($_*$cw,0,1,$H,198)) for(1..15);
  push(@r,$grey->(0,$_*$ch,$W,1,198)) for(1..8);
  return (235,@r);
 }
 return (0);
}

# GRANGER (testpat_level.c id 8), per pixel: an HSL rainbow with S = 1,
# hue u = 1-(x+0.5)/W (R at u+1/3, G at u, B at u-1/3; the B offset is
# assumed in v1-layer.md), lightness v = 1-(y+0.5)/H. Written once per
# size, levels and depth as a PNG (16-bit samples round(code*65535/1023)
# for 10-bit, as the G1 10-bit plates) in the G1 cache.
sub pitpg_granger_path (@) {
 my ($W,$H,$min,$max,$bits,$fb)=@_;
 return &calman_g1_cache_dir()."/pitpg_granger_${W}x${H}_${min}_${max}_${bits}_${fb}.png";
}

# Builds the file unless it is there; a build already running in a worker
# (pitpg_granger_prepare) is waited for instead of done twice.
sub pitpg_granger_file (@) {
 my ($W,$H,$min,$max,$bits,$fb)=@_;
 my $file=&pitpg_granger_path(@_);
 my $until=Time::HiRes::time()+60;
 while(!-s $file && Time::HiRes::time() < $until) {
  my $pid=&read_from_file("$file.building") // "";
  last if($pid!~/^(\d+)/ || !kill(0,$1));
  select(undef,undef,undef,0.05);
 }
 return $file if(-s $file);
 # Keep the cache small: one GRANGER at a time.
 unlink(grep { $_ ne $file && $_!~/\.building$/ } glob(&calman_g1_cache_dir()."/pitpg_granger_*.png"));
 my $t0=Time::HiRes::time();
 my $img=&pitpg_granger_image($W,$H,$min,$max,$bits,$fb);
 if(!&calman_g1_save_image($img,$file,$W,$H)) {
  &log("PiTPG: GRANGER could not be written to $file");
  return "";
 }
 &log(sprintf("PiTPG: GRANGER %dx%d written in %.1f s",$W,$H,Time::HiRes::time()-$t0));
 return $file;
}

# With a client's hello: GRANGER at the default levels (0-255, 8-bit) for
# the screen is built in a worker, so the request for it does not wait
# for the per-pixel image (seconds in Perl at 2160p).
sub pitpg_granger_prepare (@) {
 return if(!defined &webui_spawn_detached || &legacy_external_dv_active());
 my ($W,$H)=&pitpg_screen();
 my @key=($W,$H,0,255,8,&pitpg_fb_bits());
 my $file=&pitpg_granger_path(@key);
 return if(-s $file || -e "$file.building");
 &webui_spawn_detached(sub {
  if(open(my $fh,">","$file.building")) { print $fh $$; close($fh); }
  &pitpg_granger_file(@key);
  unlink("$file.building");
 });
}

sub pitpg_granger_image (@) {
 my ($W,$H,$min,$max,$bits,$fb)=@_;
 my @f=([],[],[]);
 for my $x (0..$W-1) {
  my $u=1-($x+0.5)/$W;
  push(@{$f[0]},&pitpg_hue_part(0,1,$u+1/3));
  push(@{$f[1]},&pitpg_hue_part(0,1,$u));
  push(@{$f[2]},&pitpg_hue_part(0,1,$u-1/3));
 }
 my $deep=($fb == 10) ? 1 : 0;
 my @s16=map { int($_*65535/1023+0.5) } 0..1023;
 my @cols=0..$W-1;
 my $buf="";
 for my $y (0..$H-1) {
  my $v=1-($y+0.5)/$H;
  my $q=$v < 0.5 ? 2*$v : 1;
  my $p=2*$v-$q;
  # L = 255 * hue_part(p,q,t) = 255 * (p + (q-p) * hue_part(0,1,t)).
  my @c=map { my $i=$_; map { &pitpg_level_code(255*($p+($q-$p)*$f[$_][$i]),$min,$max,$bits,$fb) } 0..2 } @cols;
  $buf.=$deep ? pack("n*",map { $s16[$_] } @c) : pack("C*",@c);
 }
 return {w=>$W,h=>$H,buf=>$buf,($deep ? (depth=>16) : ())};
}

sub pitpg_hue_part (@) {
 my ($p,$q,$t)=@_;
 $t+=1 if($t < 0);
 $t-=1 if($t > 1);
 return $p+($q-$p)*6*$t if($t < 1/6);
 return $q if($t < 1/2);
 return $p+($q-$p)*(2/3-$t)*6 if($t < 2/3);
 return $p;
}

1;
