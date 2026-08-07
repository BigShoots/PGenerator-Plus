package main;

# ICC profile backend extracted from webui.pm. It deliberately remains in
# package main so the existing route API and shared WebUI helpers stay stable.

sub webui_icc_profile_list (@) {
 my @out;
 my @profiles;
 if(opendir(my $dh,$_icc_profile_dir)) {
  foreach my $file (readdir($dh)) {
   next unless($file=~/^[A-Za-z0-9._-]+\.icc$/i);
   my @st=stat("$_icc_profile_dir/$file");
   # An interrupted colprof run can leave an empty destination behind. It is
   # not an installable profile and should not appear in profile history.
   next unless(($st[7]||0)>0);
   # Keep this as a JSON token rather than a Perl truth value. The profile
   # listing is assembled as JSON text and webui.pm has no json_true/json_false
   # helpers to call here.
   my $validation=(-f "$_icc_profile_dir/$file.validation.json")?"true":"false";
   push @profiles,[$file,(($st[7]||0)+0),(($st[9]||0)+0),$validation];
  }
  closedir($dh);
 }
 foreach my $profile (sort { $b->[2] <=> $a->[2] || $a->[0] cmp $b->[0] } @profiles) {
  push @out,"{\"name\":\"".&_webui_json_escape($profile->[0])."\",\"size\":".$profile->[1].",\"mtime\":".$profile->[2].",\"validation\":".$profile->[3]."}";
 }
 return "{\"status\":\"ok\",\"profiles\":[".join(",",@out)."]}";
}

sub webui_icc_reusable_measurements (@) {
 my ($query)=@_;
 my $signature="";
 $signature=lc($1) if(defined($query) && $query=~/(?:^|&)signature=([0-9a-fA-F]{16})(?:&|$)/);
 return '{"status":"error","message":"Invalid ICC measurement signature"}' if($signature eq "");
 my @candidates;
 if(opendir(my $dh,$_icc_profile_dir)) {
  foreach my $file (readdir($dh)) {
   next unless($file=~/^[A-Za-z0-9._-]+\.icc\.measurements\.json$/i);
   my $profile=$file;
   $profile=~s/\.measurements\.json$//i;
   next unless(-f "$_icc_profile_dir/$profile");
   my @st=stat("$_icc_profile_dir/$file");
   next unless(($st[7]||0)>0 && ($st[7]||0)<=16*1024*1024);
   push @candidates,[$file,($st[9]||0)];
  }
  closedir($dh);
 }
 my ($best_data,$best_count)=("",-1);
 foreach my $candidate (sort { $b->[1] <=> $a->[1] } @candidates) {
  my $data="";
  my $measurements_path=$_icc_profile_dir."/".$candidate->[0];
  if(open(my $fh,"<",$measurements_path)) { local $/; $data=<$fh>||""; close($fh); }
  next unless($data=~/^\s*\{/ && $data=~/"status"\s*:\s*"ok"/ && $data=~/"reuse_signature"\s*:\s*"\Q$signature\E"/i && $data=~/"readings"\s*:\s*\[/);
  my $count=()=$data=~/"r_code"\s*:/g;
  if($count>$best_count) { ($best_data,$best_count)=($data,$count); }
 }
 return $best_data if($best_data ne "");
 return '{"status":"none","readings":[]}';
}

sub webui_icc_profile_build (@) {
 my ($body)=@_;
 return '{"status":"error","message":"Profile request is empty"}' if(!defined($body) || $body eq "");
 return '{"status":"error","message":"Profile request is too large"}' if(length($body)>16*1024*1024);
 return '{"status":"error","message":"ICC profile builder is unavailable"}' unless(-f $_icc_profile_builder);
 if(!-d $_icc_profile_dir) {
  eval { require File::Path; File::Path::make_path($_icc_profile_dir,{mode=>0755}); };
 }
 return '{"status":"error","message":"Could not create the ICC profile directory"}' unless(-d $_icc_profile_dir);
 my $token=time()."_".$$."_".int(rand(1000000));
 my $input="/tmp/icc_profile_build_${token}.json";
 my $fh;
 if(!open($fh,">",$input)) {
  return '{"status":"error","message":"Could not prepare the profile measurements"}';
 }
 my $wrote=print {$fh} $body;
 my $closed=close($fh);
 if(!$wrote || !$closed) {
  unlink($input);
  return '{"status":"error","message":"Could not save the profile measurements"}';
 }
 chmod(0600,$input);
 # Every command component is fixed or generated above. The profile name and
 # all measurement data remain inside the JSON file and never enter the shell.
 # Large/high-quality cLUT fits can legitimately take many minutes on a Pi4.
 # Keep this outer guard longer than colprof plus profcheck so the API does not
 # terminate a healthy build before its validation result is returned.
 my $result=`timeout 2700 /usr/bin/python3 $_icc_profile_builder $input $_icc_profile_dir 2>/dev/null`;
 my $exit=$?;
 unlink($input);
 $result=~s/^\s+|\s+$//g;
 if($result!~/^\{/) {
  return '{"status":"error","message":"ICC profile creation failed"}';
 }
 return $result if($exit==0);
 return $result if($result=~/"status"\s*:\s*"error"/);
 return '{"status":"error","message":"ICC profile creation failed"}';
}

sub webui_icc_patch_generate (@) {
 my ($body)=@_;
 return '{"status":"error","message":"Patch request is empty"}' if(!defined($body) || $body eq "");
 return '{"status":"error","message":"Patch request is too large"}' if(length($body)>1024*1024);
 return '{"status":"error","message":"ICC profile builder is unavailable"}' unless(-f $_icc_profile_builder);
 if(!-d $_icc_profile_dir) {
  eval { require File::Path; File::Path::make_path($_icc_profile_dir,{mode=>0755}); };
 }
 my $token=time()."_".$$ ."_".int(rand(1000000));
 my $input="/tmp/icc_patch_build_${token}.json";
 return '{"status":"error","message":"Could not prepare the patch request"}' unless(open(my $fh,">",$input));
 my $wrote=print {$fh} $body;
 my $closed=close($fh);
 if(!$wrote || !$closed) { unlink($input); return '{"status":"error","message":"Could not save the patch request"}'; }
 chmod(0600,$input);
 my $result=`timeout 920 /usr/bin/python3 $_icc_profile_builder --patches $input $_icc_profile_dir 2>/dev/null`;
 my $exit=$?;
 unlink($input);
 $result=~s/^\s+|\s+$//g;
 return $result if($result=~/^\{/ && ($exit==0 || $result=~/"status"\s*:\s*"error"/));
 return '{"status":"error","message":"ICC patch generation failed"}';
}

sub webui_icc_precondition_patch_generate (@) {
 my ($body)=@_;
 return '{"status":"error","message":"Preconditioning request is empty"}' if(!defined($body) || $body eq "");
 return '{"status":"error","message":"Preconditioning request is too large"}' if(length($body)>16*1024*1024);
 return '{"status":"error","message":"ICC profile builder is unavailable"}' unless(-f $_icc_profile_builder);
 if(!-d $_icc_profile_dir) {
  eval { require File::Path; File::Path::make_path($_icc_profile_dir,{mode=>0755}); };
 }
 my $token=time()."_".$$ ."_".int(rand(1000000));
 my $input="/tmp/icc_precondition_${token}.json";
 return '{"status":"error","message":"Could not prepare the preconditioning request"}' unless(open(my $fh,">",$input));
 my $wrote=print {$fh} $body;
 my $closed=close($fh);
 if(!$wrote || !$closed) { unlink($input); return '{"status":"error","message":"Could not save the preconditioning measurements"}'; }
 chmod(0600,$input);
 my $result=`timeout 920 /usr/bin/python3 $_icc_profile_builder --precondition-patches $input $_icc_profile_dir 2>/dev/null`;
 my $exit=$?;
 unlink($input);
 $result=~s/^\s+|\s+$//g;
 return $result if($result=~/^\{/ && ($exit==0 || $result=~/"status"\s*:\s*"error"/));
 return '{"status":"error","message":"ICC preconditioned patch generation failed"}';
}

sub webui_icc_profile_validation (@) {
 my ($query)=@_;
 my $file="";
 $file=$1 if(defined($query) && $query=~/(?:^|&)file=([A-Za-z0-9._-]+\.icc)(?:&|$)/i);
 return '{"status":"error","message":"Invalid ICC profile name"}' if($file eq "" || $file=~m{/} || $file=~/\.\./);
 my $path="$_icc_profile_dir/$file.validation.json";
 my $bytes=-s $path;
 return '{"status":"error","message":"Validation results are unavailable"}' unless(-f $path && defined($bytes) && $bytes>0 && $bytes<1024*1024);
 my $data="";
 if(open(my $fh,"<",$path)) { local $/; $data=<$fh>; close($fh); }
 return '{"status":"error","message":"Validation results are invalid"}' unless($data=~/^\s*\{/);
 # Older builds could retain a stale UI preset label even though the saved
 # validation was generated from a different number of measured patches.
 # Normalize those records on read so profile history reflects the data that
 # actually built the profile.
 eval {
  require JSON::PP;
  my $decoded=JSON::PP::decode_json($data);
  if(ref($decoded) eq "HASH" && ($decoded->{patch_set}||"") ne "custom") {
   my $model=$decoded->{profile_model}||"";
   my $family=($model=~/matrix/ && $model!~/clut/) ? "matrix" : "clut";
   my %counts=(matrix=>{small=>55,medium=>95,large=>225},clut=>{small=>175,medium=>425,large=>1000});
   my $patches=int($decoded->{patches}||0);
   foreach my $label (qw(small medium large)) {
    if(abs($patches-$counts{$family}{$label})<=1) { $decoded->{patch_set}=$label; last; }
   }
   $data=JSON::PP->new->canonical(1)->encode($decoded);
  }
 };
 return $data;
}

sub webui_icc_profile_download (@) {
 my ($query)=@_;
 my $file="";
 $file=$1 if(defined($query) && $query=~/(?:^|&)file=([A-Za-z0-9._-]+\.icc)(?:&|$)/i);
 return ("","") if($file eq "" || $file=~m{/} || $file=~/\.\./);
 my $path="$_icc_profile_dir/$file";
 return ("","") unless(-f $path);
 my $data="";
 if(open(my $fh,"<",$path)) { binmode($fh); local $/; $data=<$fh>; close($fh); }
 return ($file,$data);
}

sub webui_icc_profile_delete (@) {
 my ($body)=@_;
 my $file="";
 $file=$1 if(defined($body) && $body=~/"file"\s*:\s*"([A-Za-z0-9._-]+\.icc)"/i);
 return '{"status":"error","message":"Invalid ICC profile name"}' if($file eq "" || $file=~m{/} || $file=~/\.\./);
 my $path="$_icc_profile_dir/$file";
 return '{"status":"error","message":"ICC profile not found"}' unless(-f $path);
 if(unlink($path)) {
  unlink($path.".validation.json");
  unlink($path.".measurements.json");
  (my $ti3=$path)=~s/\.icc$/.ti3/i;
  unlink($ti3);
  return '{"status":"ok"}';
 }
 return '{"status":"error","message":"Could not delete the ICC profile"}';
}

sub webui_icc_companion_write_atomic (@) {
 my ($path,$content,$mode)=@_;
 my $tmp=$path.".".$$ .".".int(Time::HiRes::time()*1000000).".".int(rand(1000000)).".tmp";
 return 0 unless(open(my $fh,">",$tmp));
 print $fh $content;
 close($fh);
 chmod($mode||0600,$tmp);
 return 1 if(rename($tmp,$path));
 unlink($tmp);
 return 0;
}

sub webui_icc_companion_token (@) {
 if(open(my $fh,"<",$_icc_companion_token_file)) {
  my $token=<$fh>||"";
  close($fh);
  chomp($token);
  return $token if($token=~/^[0-9a-f]{64}$/);
 }
 eval { require File::Path; File::Path::make_path($_icc_companion_dir,{mode=>0700}); } unless(-d $_icc_companion_dir);
 my $random="";
 if(open(my $rf,"<:raw","/dev/urandom")) { read($rf,$random,32); close($rf); }
 return "" unless(length($random)==32);
 my $token=unpack("H*",$random);
 return "" unless(&webui_icc_companion_write_atomic($_icc_companion_token_file,"$token\n",0600));
 return $token;
}

sub webui_icc_companion_query_value (@) {
 my ($query,$name)=@_;
 return "" unless(defined($query) && $query=~/(?:^|&)\Q$name\E=([A-Za-z0-9._-]{1,128})(?:&|$)/);
 return $1;
}

sub webui_icc_companion_settings_values () {
 my ($window_mode,$patch_size,$revision,$correction_mode,$signal_mode)=("window",100,0,"system","sdr");
 if(open(my $fh,"<",$_icc_companion_settings_file)) {
  local $/; my $content=<$fh>||""; close($fh);
  $window_mode=$1 if($content=~/"window_mode"\s*:\s*"(window|fullscreen)"/);
  $patch_size=int($1) if($content=~/"patch_size"\s*:\s*(\d+)/);
  $revision=int($1) if($content=~/"revision"\s*:\s*(\d+)/);
  $correction_mode=$1 if($content=~/"correction_mode"\s*:\s*"(system|none|clut|matrix)"/);
  $signal_mode=$1 if($content=~/"correction_signal_mode"\s*:\s*"(sdr|hdr10)"/);
 }
 my %allowed=map { $_=>1 } (2,5,10,18,25,50,75,100,105,110,118,125,150);
 $patch_size=100 unless($allowed{$patch_size});
 return ($window_mode,$patch_size,$revision,$correction_mode,"",$signal_mode);
}

sub webui_icc_companion_settings_fragment () {
 my ($window_mode,$patch_size,$revision,$correction_mode,undef,$signal_mode)=&webui_icc_companion_settings_values();
 return '"window_mode":"'.$window_mode.'","display_size":'.$patch_size.',"settings_revision":'.$revision.',"correction_mode":"'.$correction_mode.'","correction_signal_mode":"'.$signal_mode.'"';
}

sub webui_icc_companion_settings (@) {
 my ($body)=@_;
 return '{"status":"error","message":"Invalid PGenerator+ Patch Companion display settings"}' unless(defined($body) && length($body)<2048);
 my $window_mode="";
 my $patch_size=0;
 my $correction_mode="system";
 my $signal_mode="sdr";
 $window_mode=$1 if($body=~/"window_mode"\s*:\s*"(window|fullscreen)"/);
 $patch_size=int($1) if($body=~/"patch_size"\s*:\s*(\d+)/);
 $correction_mode=$1 if($body=~/"correction_mode"\s*:\s*"(system|none|clut|matrix)"/);
 $signal_mode=$1 if($body=~/"correction_signal_mode"\s*:\s*"(sdr|hdr10)"/);
 my %allowed=map { $_=>1 } (2,5,10,18,25,50,75,100,105,110,118,125,150);
 return '{"status":"error","message":"Invalid PGenerator+ Patch Companion window mode"}' if($window_mode eq "");
 return '{"status":"error","message":"Invalid PGenerator+ Patch Companion patch size"}' unless($allowed{$patch_size});
 if($correction_mode ne "system") {
  my @status_stat=stat($_icc_companion_status_file);
  my $status="";
  if(@status_stat && time()-($status_stat[9]||0)<=12 && open(my $status_fh,"<",$_icc_companion_status_file)) {
   local $/; $status=<$status_fh>||""; close($status_fh);
  }
  if($status=~/"version"\s*:\s*"(\d+)\.(\d+)\.(\d+)"/) {
   my $version=$1*1000000+$2*1000+$3;
   return '{"status":"error","message":"Install PGenerator+ Patch Companion 1.3.1 or newer before using active-profile correction"}'
    if($version<1003001);
  }
 }
 eval { require File::Path; File::Path::make_path($_icc_companion_dir,{mode=>0700}); } unless(-d $_icc_companion_dir);
 my (undef,undef,$previous_revision)=&webui_icc_companion_settings_values();
 my $revision=int(Time::HiRes::time()*1000);
 $revision=$previous_revision+1 if($revision<=$previous_revision);
 my $content='{"window_mode":"'.$window_mode.'","patch_size":'.$patch_size.',"revision":'.$revision.',"correction_mode":"'.$correction_mode.'","correction_signal_mode":"'.$signal_mode.'"}';
 return '{"status":"error","message":"Could not save PGenerator+ Patch Companion display settings"}'
  unless(&webui_icc_companion_write_atomic($_icc_companion_settings_file,$content,0600));
 return '{"status":"ok",'.&webui_icc_companion_settings_fragment().'}';
}

sub webui_icc_companion_profile_from_query (@) {
 my ($query)=@_;
 return "" unless(defined($query) && $query=~/(?:^|&)profile_hex=([0-9A-Fa-f]{2,640})(?:&|$)/ && length($1)%2==0);
 my $profile=pack("H*",$1);
 return "" unless($profile=~/\A[A-Za-z0-9][A-Za-z0-9 ._()-]{0,159}\.(?:icc|icm)\z/i);
 return "" if($profile=~/\.\./ || $profile=~/[\\\/]/);
 return $profile;
}

sub webui_icc_companion_text_from_hex_query (@) {
 my ($query,$name)=@_;
 return "" unless(defined($query) && $name=~/\A[A-Za-z0-9_]+\z/ &&
  $query=~/(?:^|&)\Q$name\E=([0-9A-Fa-f]{2,640})(?:&|$)/ && length($1)%2==0);
 my $text=pack("H*",$1);
 return "" unless($text=~/\A[\x20-\x7e]{1,160}\z/);
 return $text;
}

sub webui_icc_companion_poll (@) {
 my ($query)=@_;
 my $token=&webui_icc_companion_query_value($query,"token");
 my $expected=&webui_icc_companion_token();
 return '{"status":"unauthorized"}' if($expected eq "" || $token ne $expected);
 my $client=&webui_icc_companion_query_value($query,"client")||"companion";
 my $version=&webui_icc_companion_query_value($query,"version")||"unknown";
 my $renderer=&webui_icc_companion_query_value($query,"renderer")||"unknown";
 my $swapchain_cs=&webui_icc_companion_query_value($query,"swapchain_cs")||"unknown";
 my $presentation=&webui_icc_companion_query_value($query,"presentation")||"unknown";
 my $active_profile=&webui_icc_companion_profile_from_query($query);
 my $selected_display=&webui_icc_companion_text_from_hex_query($query,"display_hex");
 my $transform=&webui_icc_companion_query_value($query,"transform")||"system";
 $transform="system" unless($transform=~/\A(?:system|clut|matrix)\z/);
 my $transform_ready=($query=~/(?:^|&)transform_ready=1(?:&|$)/)?1:0;
 my $hdr=($query=~/(?:^|&)hdr=1(?:&|$)/)?1:0;
 my $output_max=0;
 my $output_full=0;
 my $output_bits=0;
 my @patch_values=(0,0,0,0,0,0);
 $output_max=$1+0 if($query=~/(?:^|&)output_max=(\d+(?:\.\d+)?)(?:&|$)/);
 $output_full=$1+0 if($query=~/(?:^|&)output_full=(\d+(?:\.\d+)?)(?:&|$)/);
 $output_bits=int($1) if($query=~/(?:^|&)output_bits=(\d+)(?:&|$)/);
 my @patch_keys=("source_r","source_g","source_b","submitted_r","submitted_g","submitted_b");
 for(my $index=0;$index<@patch_keys;$index++) {
  my $key=$patch_keys[$index];
  $patch_values[$index]=$1+0 if($query=~/(?:^|&)\Q$key\E=(\d+(?:\.\d+)?)(?:&|$)/);
 }
 my $seen=time();
 my $status="{\"client\":\"".&_webui_json_escape($client)."\",\"version\":\"".&_webui_json_escape($version)."\",\"renderer\":\"".&_webui_json_escape($renderer)."\",\"selected_display\":\"".&_webui_json_escape($selected_display)."\",\"swapchain_color_space\":\"".&_webui_json_escape($swapchain_cs)."\",\"presentation_mode\":\"".&_webui_json_escape($presentation)."\",\"output_max_luminance\":".($output_max+0).",\"output_full_frame_luminance\":".($output_full+0).",\"output_bits_per_color\":".($output_bits+0).",\"active_profile\":\"".&_webui_json_escape($active_profile)."\",\"transform_mode\":\"$transform\",\"transform_ready\":".($transform_ready?"true":"false").",\"source_rgb\":[".join(",",@patch_values[0..2])."],\"submitted_rgb\":[".join(",",@patch_values[3..5])."],\"hdr_active\":".($hdr?"true":"false").",\"last_seen\":$seen}";
 &webui_icc_companion_write_atomic($_icc_companion_status_file,$status,0600);
 my $command="";
 if(open(my $fh,"<",$_icc_companion_command_file)) { local $/; $command=<$fh>||""; close($fh); }
 if($command=~/^\s*\{/ && length($command)<8192) {
  my $sequence=0;
  $sequence=$1 if($command=~/"sequence"\s*:\s*(\d+)/);
  my $acked=0;
  if(open(my $af,"<",$_icc_companion_ack_file)) { local $/; my $ack=<$af>||""; close($af); $acked=$1 if($ack=~/"sequence"\s*:\s*(\d+)/); }
  if($sequence>0 && $sequence!=$acked) {
   my $settings=&webui_icc_companion_settings_fragment();
   $command=~s/\}\s*$/,$settings}/;
   return $command;
  }
 }
 my $poll_ms=500;
 foreach my $state_file ($_meter_series_file,$_meter_read_file) {
  next unless(-f $state_file);
  my @state_stat=stat($state_file);
  next unless(@state_stat && time()-($state_stat[9]||0)<=30);
  my $state="";
  if(open(my $sf,"<",$state_file)) { local $/; $state=<$sf>||""; close($sf); }
  if($state=~/"status"\s*:\s*"(?:running|measuring|setup)"/i) { $poll_ms=50; last; }
 }
 return '{"status":"idle","poll_ms":'.$poll_ms.','.&webui_icc_companion_settings_fragment().'}';
}

sub webui_icc_companion_ack (@) {
 my ($body)=@_;
 return '{"status":"unauthorized"}' unless(defined($body) && length($body)<4096);
 my $token="";
 $token=$1 if($body=~/"token"\s*:\s*"([0-9a-f]{64})"/);
 my $expected=&webui_icc_companion_token();
 return '{"status":"unauthorized"}' if($expected eq "" || $token ne $expected);
 my $sequence=0;
 $sequence=$1 if($body=~/"sequence"\s*:\s*(\d+)/);
 return '{"status":"error","message":"Invalid patch sequence"}' if($sequence<1);
 my $result=($body=~/"status"\s*:\s*"ok"/)?"ok":"error";
 my $client="companion";
 my $renderer="unknown";
 my $message="";
 $client=$1 if($body=~/"client"\s*:\s*"([A-Za-z0-9._-]{1,96})"/);
 $renderer=$1 if($body=~/"renderer"\s*:\s*"([A-Za-z0-9._-]{1,96})"/);
 $message=$1 if($body=~/"message"\s*:\s*"([^"\\]{0,240})"/);
 my $ack="{\"sequence\":$sequence,\"status\":\"$result\",\"client\":\"".&_webui_json_escape($client)."\",\"renderer\":\"".&_webui_json_escape($renderer)."\",\"message\":\"".&_webui_json_escape($message)."\",\"time\":".time()."}";
 return &webui_icc_companion_write_atomic($_icc_companion_ack_file,$ack,0600) ? '{"status":"ok"}' : '{"status":"error","message":"Could not acknowledge patch"}';
}

# Version of the Patch Companion this PGenerator ships. Read from the resource
# script rather than hard-coded so it cannot drift from the binary: both are
# produced from the same source tree, and a stale constant here would tell
# users their Companion is current when it is not.
my $_icc_companion_shipped_version;
sub webui_icc_companion_shipped_version () {
 return $_icc_companion_shipped_version if(defined($_icc_companion_shipped_version));
 $_icc_companion_shipped_version="";
 my $dir=__FILE__;
 $dir=~s{/[^/]+\z}{};
 if(open(my $fh,"<","$dir/icc-companion-src/pgen-icc-companion.rc")) {
  local $/;
  my $rc=<$fh>||"";
  close($fh);
  $_icc_companion_shipped_version=$1 if($rc=~/VALUE\s+"FileVersion"\s*,\s*"([0-9]+(?:\.[0-9]+){1,3})"/);
 }
 return $_icc_companion_shipped_version;
}

sub webui_icc_companion_status (@) {
 my $content="";
 my @st=stat($_icc_companion_status_file);
 # The companion's synchronous HTTP poll can take about three seconds on a
 # busy or remote link. Allow several missed polls before declaring it gone.
 if(@st && time()-($st[9]||0)<=12 && open(my $fh,"<",$_icc_companion_status_file)) { local $/; $content=<$fh>||""; close($fh); }
 my $shipped=&webui_icc_companion_shipped_version();
 my $shipped_json=($shipped ne "") ? ',"shipped_version":"'.&_webui_json_escape($shipped).'"' : "";
 return '{"status":"ok","connected":false,'.&webui_icc_companion_settings_fragment().$shipped_json.'}' unless($content=~/^\s*\{/);
 $content=~s/^\s*\{//;
 return '{"status":"ok","connected":true,'.&webui_icc_companion_settings_fragment().$shipped_json.','.$content;
}

# Publish a calibration-card patch to the paired target-computer companion.
# Patch size is ignored in resizable-window mode and controls centered window
# or APL geometry when the Companion is in borderless fullscreen mode.
sub webui_icc_companion_pattern (@) {
 my ($body)=@_;
 return '{"status":"error","message":"Invalid companion pattern request"}' unless(defined($body) && length($body)<8192);
 my $connected=&webui_icc_companion_status();
 return '{"status":"error","message":"PGenerator+ Patch Companion is not connected"}' unless($connected=~/"connected"\s*:\s*true/);
 my $sequence=int(Time::HiRes::time()*1000);
 if(open(my $fh,"<",$_icc_companion_command_file)) {
  local $/; my $previous=<$fh>||""; close($fh);
  my $last=0; $last=$1 if($previous=~/"sequence"\s*:\s*(\d+)/);
  $sequence=$last+1 if($sequence<=$last);
 }
 my $payload="";
 if($body=~/"(?:name|status)"\s*:\s*"(?:stop|align|alignment)"/i) {
  $payload='{"status":"align","sequence":'.$sequence.'}';
 } else {
  my ($r,$g,$b)=(0,0,0);
  $r=$1 if($body=~/"(?:r|patch_r)"\s*:\s*(\d+)/);
  $g=$1 if($body=~/"(?:g|patch_g)"\s*:\s*(\d+)/);
  $b=$1 if($body=~/"(?:b|patch_b)"\s*:\s*(\d+)/);
  my $input_max=255; $input_max=$1 if($body=~/"(?:input_max|patch_input_max)"\s*:\s*(\d+)/);
  $input_max=255 if($input_max<1 || $input_max>65535);
  $r=$input_max if($r>$input_max); $g=$input_max if($g>$input_max); $b=$input_max if($b>$input_max);
  my $size=100; $size=$1 if($body=~/"size"\s*:\s*(\d+)/); $size=100 if($size<1 || $size>100);
  my $signal_mode="sdr"; $signal_mode=$1 if($body=~/"signal_mode"\s*:\s*"(sdr|hdr10|hlg|dv)"/);
  # Fall back to the configured HDR metadata, not to fixed literals. A display
  # tone maps against the mastering metadata it is sent, so an ICC
  # characterization measured with different max_luma/max_cll/max_fall than the
  # verification series is measuring a differently behaving display, and the
  # resulting profile can never agree with the charts.
  my $max_luma=defined($pgenerator_conf{"max_luma"}) ? ($pgenerator_conf{"max_luma"}+0) : 1000;
  $max_luma=$1 if($body=~/"max_luma"\s*:\s*(\d+(?:\.\d+)?)/);
  $max_luma=1000 if($max_luma<=0); $max_luma=10000 if($max_luma>10000);
  my $min_luma=defined($pgenerator_conf{"min_luma"}) ? ($pgenerator_conf{"min_luma"}+0) : 0.005;
  $min_luma=$1 if($body=~/"min_luma"\s*:\s*(\d+(?:\.\d+)?)/);
  my $max_cll=defined($pgenerator_conf{"max_cll"}) ? ($pgenerator_conf{"max_cll"}+0) : $max_luma;
  $max_cll=$1 if($body=~/"max_cll"\s*:\s*(\d+(?:\.\d+)?)/);
  my $max_fall=defined($pgenerator_conf{"max_fall"}) ? ($pgenerator_conf{"max_fall"}+0) : 400;
  $max_fall=$1 if($body=~/"max_fall"\s*:\s*(\d+(?:\.\d+)?)/);
  my $signal_range=""; $signal_range=$1 if($body=~/"signal_range"\s*:\s*"?(\d+)"?/);
  my $scale=1; $scale=4 if($input_max==1023); $scale=16 if($input_max==4095);
  my $code_min=($signal_range eq "1") ? 16*$scale : 0;
  my $code_max=($signal_range eq "1") ? 235*$scale : $input_max;
  $payload='{"status":"patch","sequence":'.$sequence.',"r":'.$r.',"g":'.$g.',"b":'.$b.',"size":'.$size.',"input_max":'.$input_max.',"code_min":'.$code_min.',"code_max":'.$code_max.',"signal_mode":"'.$signal_mode.'","max_luma":'.($max_luma+0).',"min_luma":'.($min_luma+0).',"max_cll":'.($max_cll+0).',"max_fall":'.($max_fall+0).'}';
 }
 return &webui_icc_companion_write_atomic($_icc_companion_command_file,$payload,0644)
  ? '{"status":"ok","sequence":'.$sequence.'}'
  : '{"status":"error","message":"Could not send a pattern to PGenerator+ Patch Companion"}';
}

sub webui_icc_companion_download (@) {
 my ($query,$host)=@_;
 my $platform=&webui_icc_companion_query_value($query,"platform");
 return ("","","Unsupported PGenerator+ Patch Companion platform") unless($platform eq "windows-x64" || $platform eq "windows-portable-x64" || $platform eq "linux-x64");
 return ("","","Could not determine this PGenerator address") unless(defined($host) && $host=~/^[A-Za-z0-9._\-\[\]:]+$/);
 return ("","","PGenerator+ Patch Companion packager is not installed") unless(-f $_icc_companion_packager);
 my $token=&webui_icc_companion_token();
 return ("","","Could not create the PGenerator+ Patch Companion pairing token") if($token eq "");
 my $tmp="/tmp/pgen_icc_companion_".$$ ."_".int(rand(1000000)).($platform eq "windows-x64" ? ".exe" : ".zip");
 my $server="http://$host";
 my $output=`/usr/bin/python3 $_icc_companion_packager '$platform' '$server' '$token' '$tmp' 2>&1`;
 chomp($output);
 my $filename=$output;
 my $content="";
 if($?==0 && $filename=~/^[A-Za-z0-9._-]+\.(?:zip|exe)$/ && open(my $fh,"<:raw",$tmp)) { local $/; $content=<$fh>||""; close($fh); }
 unlink($tmp);
 return ($filename,$content,"") if($content ne "");
 $output=~s/[\r\n]+/ /g;
 $output=~s/[^A-Za-z0-9 ._:\/()\[\]-]+/?/g;
 $output=substr($output,0,240);
 &log("PGenerator+ Patch Companion package failed: ".($output||"unknown packager error"));
 return ("","",$output||"PGenerator+ Patch Companion package generation failed");
}


my %_webui_icc_asset_cache;

sub webui_icc_asset (@) {
 my ($name)=@_;
 return "" unless(defined($name) && $name=~/\Aicc_profile\.(?:html|css|js)\z/);
 return $_webui_icc_asset_cache{$name} if(exists($_webui_icc_asset_cache{$name}));
 my $dir=__FILE__;
 $dir=~s{/[^/]+\z}{};
 my $content="";
 if(open(my $fh,"<:raw","$dir/$name")) {
  local $/;
  $content=<$fh>||"";
  close($fh);
 }
 $_webui_icc_asset_cache{$name}=$content;
 return $content;
}

1;
