package main;

# ICC profile backend extracted from webui.pm. It deliberately remains in
# package main so the existing route API and shared WebUI helpers stay stable.

sub webui_icc_sync_clock_from_build (@) {
 my ($body)=@_;
 my $client_time=0;
 $client_time=int($1) if(defined($body) && $body=~/"client_time"\s*:\s*(\d{10})/);
 # A Pi has no RTC and may be on an isolated calibration network. The browser
 # is still a useful forward-only clock source. Never let a client move time
 # backwards, and reject dates outside a deliberately broad sane range.
 return 0 if($client_time<1767225600 || $client_time>4102444800);
 return 0 if($client_time<=time()+60);
 return 0 if(system("/bin/date","-u","-s","\@$client_time")!=0);
 system("/usr/sbin/fake-hwclock","save") if(-x "/usr/sbin/fake-hwclock");
 return 1;
}

sub webui_icc_profile_list (@) {
 my @out;
 my @profiles;
 if(opendir(my $dh,$_icc_profile_dir)) {
  foreach my $file (readdir($dh)) {
   next unless($file=~/^[A-Za-z0-9._()-]+\.icc$/i);
   my @st=stat("$_icc_profile_dir/$file");
   # An interrupted colprof run can leave an empty destination behind. It is
   # not an installable profile and should not appear in profile history.
   next unless(($st[7]||0)>0);
   # Keep this as a JSON token rather than a Perl truth value. The profile
   # listing is assembled as JSON text and webui.pm has no json_true/json_false
   # helpers to call here.
   my $validation=(-f "$_icc_profile_dir/$file.validation.json")?"true":"false";
   my $finetune=(-f "$_icc_profile_dir/$file.finetune.json")?"true":"false";
   my $has_measurements=(-f "$_icc_profile_dir/$file.measurements.json")?"true":"false";
   # Fine-tuning needs the embedded characterization plus a stage it can
   # edit: the BToA corridor for cLUT profiles or the MHC2 adjustment curves
   # for Windows-class profiles. Decide from the tag table, not the file
   # name. tune_mode tells the browser which signal to measure the ladder
   # in: cicp marks HDR authoritatively; an MHC2 profile without cicp is HDR
   # when its adjustment curves top out well below full drive, which is the
   # PQ request-to-achievable mapping shape.
   my $tunable="false";
   my $tune_mode="sdr";
   my $tune_color="false";
   my $has_clut="false";
   my $has_mhc2="false";
   if(open(my $ph,"<:raw","$_icc_profile_dir/$file")) {
    my $head="";
    read($ph,$head,4096);
    if(length($head)>132) {
     my $tag_count=unpack("N",substr($head,128,4));
     if($tag_count>0 && $tag_count<200 && length($head)>=132+$tag_count*12) {
      my %tags;
      my ($mhc2_off,$mhc2_size)=(0,0);
      for my $i (0..$tag_count-1) {
       my $sig=substr($head,132+$i*12,4);
       $tags{$sig}=1;
       if($sig eq "MHC2") {
        $mhc2_off=unpack("N",substr($head,132+$i*12+4,4));
        $mhc2_size=unpack("N",substr($head,132+$i*12+8,4));
       }
      }
      $has_clut="true" if($tags{"B2A0"});
      $has_mhc2="true" if($tags{"MHC2"});
      $tunable="true" if($tags{"targ"} && ($tags{"B2A0"} || $tags{"MHC2"}));
      # cLUT profiles tune local cells. MHC2 profiles use the same colour
      # evidence for a constrained residual 3x3 matrix correction.
      $tune_color=($tunable eq "true")?"true":"false";
      if($tags{"cicp"}) {
       $tune_mode="hdr10";
      } elsif($tags{"MHC2"} && $mhc2_off>0 && $mhc2_size>44) {
       # No cicp: decide from the correction's own peak luminance. The tag
       # records the calibrated peak in cd/m2, and an SDR calibration target
       # sits far below any HDR peak (measured here: SDR profiles 152-168,
       # HDR profiles 299-999). The adjustment curve's endpoint was tried
       # first and is useless - it reaches full drive on both kinds.
       my $mhc2="";
       if(seek($ph,$mhc2_off,0) && read($ph,$mhc2,20)==20) {
        my $raw=unpack("N",substr($mhc2,16,4));
        $raw-=4294967296 if($raw>=2147483648);
        $tune_mode="hdr10" if($raw/65536.0>=250.0);
       }
      }
     }
    }
    close($ph);
   }
   push @profiles,[$file,(($st[7]||0)+0),(($st[9]||0)+0),$validation,$finetune,$tunable,$tune_mode,$tune_color,$has_clut,$has_mhc2,$has_measurements];
  }
  closedir($dh);
 }
 foreach my $profile (sort { $b->[2] <=> $a->[2] || $a->[0] cmp $b->[0] } @profiles) {
  push @out,"{\"name\":\"".&_webui_json_escape($profile->[0])."\",\"size\":".$profile->[1].",\"mtime\":".$profile->[2].",\"validation\":".$profile->[3].",\"finetune\":".$profile->[4].",\"tunable\":".$profile->[5].",\"tune_mode\":\"".$profile->[6]."\",\"tune_color\":".$profile->[7].",\"has_clut\":".$profile->[8].",\"has_mhc2\":".$profile->[9].",\"has_measurements\":".$profile->[10]."}";
 }
 return "{\"status\":\"ok\",\"profiles\":[".join(",",@out)."]}";
}

# Convert a stored ICC profile's BToA correction into a standard .cube 3D LUT
# written straight into the solved-LUT directory, so the 3D LUT workspace
# lists it like any solved LUT. The signal mode reuses the listing's tag
# heuristics (cicp marks HDR authoritatively; an MHC2 profile without cicp is
# HDR when its calibrated peak reaches 250 cd/m2). ICC names legally contain
# parentheses but the solved-LUT routes whitelist [A-Za-z0-9._-], so the
# output stem is sanitized before writing. The optional directory argument
# exists for tests only.
sub webui_icc_profile_to_cube (@) {
 my ($body,$lut_dir)=@_;
 $lut_dir="/var/lib/PGenerator/lg/luts" if(!defined($lut_dir) || $lut_dir eq "");
 return '{"status":"error","message":"Conversion request is empty"}' if(!defined($body) || $body eq "");
 return '{"status":"error","message":"The LUT conversion tool is unavailable"}' unless(-f $_icc_companion_lut_builder);
 my $file="";
 $file=$1 if($body=~/"file"\s*:\s*"([A-Za-z0-9._()-]+\.icc)"/i);
 return '{"status":"error","message":"Invalid ICC profile name"}' if($file eq "" || $file=~m{/} || $file=~/\.\./);
 my $path="$_icc_profile_dir/$file";
 return '{"status":"error","message":"ICC profile not found"}' unless(-f $path);
 my $size=65;
 $size=$1+0 if($body=~/"size"\s*:\s*(\d{1,4})/);
 return '{"status":"error","message":"Unsupported 3D LUT size"}' unless($size==17 || $size==33 || $size==65);
 my ($method,$mode)=("","sdr");
 if(open(my $ph,"<:raw",$path)) {
  my $head="";
  read($ph,$head,4096);
  if(length($head)>132) {
   my $tag_count=unpack("N",substr($head,128,4));
   if($tag_count>0 && $tag_count<200 && length($head)>=132+$tag_count*12) {
    my %tags;
    my ($mhc2_off,$mhc2_size)=(0,0);
    for my $i (0..$tag_count-1) {
     my $sig=substr($head,132+$i*12,4);
     $tags{$sig}=1;
     if($sig eq "MHC2") {
      $mhc2_off=unpack("N",substr($head,132+$i*12+4,4));
      $mhc2_size=unpack("N",substr($head,132+$i*12+8,4));
     }
    }
    # Prefer the measured cLUT; a matrix/TRC-only profile still converts
    # through the converter's matrix fallback.
    $method=$tags{"B2A0"} ? "clut" : (($tags{"rXYZ"} && $tags{"gXYZ"} && $tags{"bXYZ"}) ? "matrix" : "");
    if($tags{"cicp"}) {
     $mode="hdr10";
    } elsif($tags{"MHC2"} && $mhc2_off>0 && $mhc2_size>44) {
     my $mhc2="";
     if(seek($ph,$mhc2_off,0) && read($ph,$mhc2,20)==20) {
      my $raw=unpack("N",substr($mhc2,16,4));
      $raw-=4294967296 if($raw>=2147483648);
      $mode="hdr10" if($raw/65536.0>=250.0);
     }
    }
   }
  }
  close($ph);
 }
 return '{"status":"error","message":"The profile has no convertible cLUT or matrix stage"}' if($method eq "");
 my $stem=$file;
 $stem=~s/\.icc$//i;
 $stem=~s/[^A-Za-z0-9._-]+/_/g;
 $stem=~s/^[._]+//;
 $stem=~s/_+$//;
 $stem="profile" if($stem eq "");
 system("mkdir -p $lut_dir 2>/dev/null") unless(-d $lut_dir);
 my $out="icc_".$stem."_".$mode."_".time().".cube";
 my $out_path="$lut_dir/$out";
 # Names are whitelist-constrained above and cannot carry quotes; the profile
 # data itself never enters the shell.
 my $output=`timeout 900 /usr/bin/python3 $_icc_companion_lut_builder '$path' $method $mode '$out_path' $size 2>&1`;
 my $exit=$?;
 if($exit!=0 || !-f $out_path) {
  unlink($out_path);
  $output="" if(!defined($output));
  $output=~s/\s+/ /g;
  $output=~s/^ | $//g;
  $output="LUT conversion failed" if($output eq "");
  return '{"status":"error","message":"'.&_webui_json_escape($output).'"}';
 }
 my $bytes=(-s $out_path)||0;
 my $nodes=$size*$size*$size;
 # The delete route removes the .cube/.bin/.json triple by basename; write the
 # sidecar so converted LUTs clean up like solved ones and keep provenance.
 (my $sidecar=$out_path)=~s/\.cube$/.json/;
 if(open(my $mf,'>',$sidecar)) {
  print $mf "{\"status\":\"ok\",\"method\":\"".($method eq "clut"?"icc_clut":"icc_matrix")."\",\"signal_mode\":\"$mode\",\"source_profile\":\"".&_webui_json_escape($file)."\",\"lut_size\":$size,\"cube_lut_size\":$size,\"cube_axis_order\":\"r-fastest\",\"title\":\"ICC ".&_webui_json_escape($stem)."\"}";
  close($mf);
 }
 return "{\"status\":\"ok\",\"file\":\"".&_webui_json_escape($out)."\",\"path\":\"".&_webui_json_escape($out_path)."\",\"size\":$bytes,\"nodes\":$nodes,\"lut_size\":$size,\"signal_mode\":\"$mode\",\"method\":\"$method\"}";
}

sub webui_icc_profile_finetune (@) {
 my ($body)=@_;
 return '{"status":"error","message":"Fine-tune request is empty"}' if(!defined($body) || $body eq "");
 return '{"status":"error","message":"Fine-tune request is too large"}' if(length($body)>16*1024*1024);
 my $tool="/usr/bin/icc_finetune.py";
 return '{"status":"error","message":"The fine-tune tool is unavailable"}' unless(-f $tool);
 my $file="";
 $file=$1 if($body=~/"file"\s*:\s*"([A-Za-z0-9._()-]+\.icc)"/i);
 return '{"status":"error","message":"Invalid ICC profile name"}' if($file eq "" || $file=~/\.\./);
 my $parent="$_icc_profile_dir/$file";
 return '{"status":"error","message":"ICC profile not found"}' unless(-f $parent);
 # Derive a space-free versioned name so the result stays installable and
 # clearly separate from characterization-time pre-conditioning profiles. An
 # iterative AutoCal-style session passes an explicit output stem instead and
 # overwrites it on every pass, so converging does not litter the history
 # with one file per iteration.
 my $out_name="";
 $out_name=$1 if($body=~/"output"\s*:\s*"([A-Za-z0-9._()-]{1,80})"/);
 $out_name="" if($out_name=~/\.\./ || $out_name=~/\.icc$/i);
 if($out_name eq "") {
  my $stem=$file; $stem=~s/\.icc$//i; $stem=~s/-FineTuned(?:-\d+)?$//;
  $out_name=$stem."-FineTuned";
  my $suffix=2;
  while(-f "$_icc_profile_dir/$out_name.icc") { $out_name=$stem."-FineTuned-".$suffix; $suffix++; last if($suffix>99); }
 }
 my $token=time()."_".$$."_".int(rand(1000000));
 my $input="/tmp/icc_finetune_${token}.json";
 my $fh;
 return '{"status":"error","message":"Could not prepare the fine-tune request"}' unless(open($fh,">",$input));
 # Reuse the client readings verbatim; inject the resolved parent path and name.
 my $payload=$body;
 $payload=~s/^\s*\{/{"parent_path":"$parent","name":"$out_name",/;
 print {$fh} $payload;
 close($fh);
 chmod(0600,$input);
 my $result=`timeout 1800 /usr/bin/python3 $tool $input $_icc_profile_dir 2>/dev/null`;
 my $exit=$?;
 unlink($input);
 $result=~s/^\s+|\s+$//g;
 return '{"status":"error","message":"Profile fine-tuning failed"}' if($result!~/^\{/);
 return $result if($exit==0);
 return $result if($result=~/"status"\s*:\s*"error"/);
 return '{"status":"error","message":"Profile fine-tuning failed"}';
}

sub webui_icc_reusable_measurements (@) {
 my ($query)=@_;
 my $signature="";
 $signature=lc($1) if(defined($query) && $query=~/(?:^|&)signature=([0-9a-fA-F]{16})(?:&|$)/);
 return '{"status":"error","message":"Invalid ICC measurement signature"}' if($signature eq "");
 my @candidates;
 if(opendir(my $dh,$_icc_profile_dir)) {
  foreach my $file (readdir($dh)) {
   next unless($file=~/^[A-Za-z0-9._()-]+\.icc\.measurements\.json$/i);
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
 &webui_icc_sync_clock_from_build($body);
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
 # Large Ultra cLUT fits can legitimately take more than two hours on a Pi4.
 # Keep this outer guard beyond the builder's four-hour runaway limit so the
 # API cannot terminate colprof or the following profile validation first.
 my $result=`timeout 15000 /usr/bin/python3 $_icc_profile_builder $input $_icc_profile_dir 2>/dev/null`;
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

sub webui_icc_profile_measurements (@) {
 my ($query)=@_;
 my $file="";
 $file=$1 if(defined($query) && $query=~/(?:^|&)file=([A-Za-z0-9._()-]+\.icc)(?:&|$)/i);
 return '{"status":"error","message":"Invalid ICC profile name"}' if($file eq "" || $file=~m{/} || $file=~/\.\./);
 my $path="$_icc_profile_dir/$file.measurements.json";
 my $bytes=-s $path;
 return '{"status":"none","readings":[],"mhc2_readings":[]}' unless(-f $path && defined($bytes) && $bytes>0 && $bytes<=16*1024*1024);
 my $data="";
 if(open(my $fh,"<",$path)) { local $/; $data=<$fh>||""; close($fh); }
 return '{"status":"error","message":"Saved measurements are invalid"}' unless($data=~/^\s*\{/ && $data=~/"readings"\s*:\s*\[/);
 return $data;
}

sub webui_icc_profile_validation (@) {
 my ($query)=@_;
 my $file="";
 $file=$1 if(defined($query) && $query=~/(?:^|&)file=([A-Za-z0-9._()-]+\.icc)(?:&|$)/i);
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
 $file=$1 if(defined($query) && $query=~/(?:^|&)file=([A-Za-z0-9._()-]+\.icc)(?:&|$)/i);
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
 $file=$1 if(defined($body) && $body=~/"file"\s*:\s*"([A-Za-z0-9._()-]+\.icc)"/i);
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

sub webui_icc_pairing_read () {
 my @requests;
 if(open(my $fh,"<",$_icc_companion_pairing_file)) {
  local $/; my $data=<$fh>||""; close($fh);
  if($data=~/^\s*\[/) {
   eval {
    require JSON::PP;
    my $decoded=JSON::PP::decode_json($data);
    @requests=grep { ref($_) eq "HASH" } @$decoded if(ref($decoded) eq "ARRAY");
   };
  }
 }
 return @requests;
}

sub webui_icc_pairing_write (@) {
 my (@requests)=@_;
 my $json="[]";
 eval { require JSON::PP; $json=JSON::PP->new->canonical(1)->encode(\@requests); };
 eval { require File::Path; File::Path::make_path($_icc_companion_dir,{mode=>0700}); } unless(-d $_icc_companion_dir);
 return &webui_icc_companion_write_atomic($_icc_companion_pairing_file,$json,0600);
}

# Runs $code with the current (already pruned) request list and persists
# whatever it returns, all inside one lock. Two fast-lane workers can call the
# pairing endpoints at the same moment; unlike the other Companion state files
# this one is a list, so a load here racing a save there would silently drop
# whichever request lost the race, rather than just going stale for a poll.
sub webui_icc_pairing_mutate (@) {
 my ($code)=@_;
 my @after;
 {
  lock($_icc_pairing_lock);
  my @before=&webui_icc_pairing_read();
  my $now=time();
  my @kept=grep { defined($_->{created}) && ($now-$_->{created})<180 } @before;
  # Skip the write when nothing actually changed -- this runs on every
  # status poll (every companion-status container, every open tab), and most
  # of those calls are a pure read with zero pending requests to prune.
  # Snapshotted BEFORE calling $code: $code can mutate an entry's hashref in
  # place (pair-decide does), and those hashrefs are the same objects @before
  # holds, so encoding @before afterwards would already show the mutation and
  # this check would never see a difference.
  my ($before_json,$after_json)=("a","b");
  eval { require JSON::PP; $before_json=JSON::PP->new->canonical(1)->encode(\@kept); };
  @after=$code->(@kept);
  eval { require JSON::PP; $after_json=JSON::PP->new->canonical(1)->encode(\@after); };
  &webui_icc_pairing_write(@after) if($before_json ne $after_json);
 }
 return @after;
}

sub webui_icc_pairing_random_hex (@) {
 my ($bytes)=@_;
 my $random="";
 if(open(my $rf,"<:raw","/dev/urandom")) { read($rf,$random,$bytes); close($rf); }
 return "" unless(length($random)==$bytes);
 return unpack("H*",$random);
}

# 6-digit pairing code, generated here rather than trusted from the client --
# a hostile requester choosing its own code could otherwise steer a human
# into approving the wrong machine.
sub webui_icc_pairing_random_code () {
 my $random="";
 if(open(my $rf,"<:raw","/dev/urandom")) { read($rf,$random,4); close($rf); }
 return "" unless(length($random)==4);
 return sprintf("%06d",unpack("N",$random)%1000000);
}

# Called by an unpaired Companion, with no token, to ask a human to approve
# it. A retry from the same client name while its first request is still
# pending gets back the identical id/code rather than queuing a second prompt.
sub webui_icc_pair_request (@) {
 my ($body,$ip)=@_;
 return '{"status":"error","message":"Pairing request is empty"}' unless(defined($body) && length($body)>0 && length($body)<4096);
 my ($client,$platform,$version)=("","","");
 $client=$1 if($body=~/"client"\s*:\s*"([A-Za-z0-9._-]{1,64})"/);
 $platform=$1 if($body=~/"platform"\s*:\s*"(windows|linux|macos)"/);
 $version=$1 if($body=~/"version"\s*:\s*"([0-9.]{1,16})"/);
 return '{"status":"error","message":"Invalid pairing request"}' if($client eq "" || $platform eq "" || $version eq "");
 $ip="" unless(defined($ip) && $ip=~/^[0-9A-Fa-f:.]{1,45}$/);
 my $outcome="";
 &webui_icc_pairing_mutate(sub {
  my (@requests)=@_;
  foreach my $request (@requests) {
   next unless(($request->{status}||"") eq "pending" && ($request->{client}||"") eq $client);
   $outcome=$request;
   return @requests;
  }
  if(scalar(grep { ($_->{status}||"") eq "pending" } @requests)>=4) {
   $outcome="full";
   return @requests;
  }
  my $id=&webui_icc_pairing_random_hex(16);
  my $code=&webui_icc_pairing_random_code();
  if($id eq "" || $code eq "") { $outcome="random"; return @requests; }
  my $entry={id=>$id,code=>$code,client=>$client,platform=>$platform,version=>$version,ip=>$ip,created=>time(),status=>"pending"};
  $outcome=$entry;
  push @requests,$entry;
  return @requests;
 });
 return '{"status":"error","message":"Too many pending pairing requests"}' if(!ref($outcome) && $outcome eq "full");
 return '{"status":"error","message":"Could not create the pairing request"}' if(!ref($outcome));
 my $expires=180-(time()-($outcome->{created}||time()));
 $expires=0 if($expires<0);
 return "{\"status\":\"pending\",\"request\":\"$outcome->{id}\",\"code\":\"$outcome->{code}\",\"expires_in\":$expires}";
}

# Called by the Companion, with no token, to find out whether a human has
# decided yet. Approved and denied are both one-shot: the entry is deleted the
# moment either is read, so the token is handed out exactly once and a second
# poll for the same id can only ever see "expired".
sub webui_icc_pair_status (@) {
 my ($query)=@_;
 my $id="";
 $id=$1 if(defined($query) && $query=~/(?:^|&)request=([0-9a-f]{32})(?:&|$)/);
 return '{"status":"expired"}' if($id eq "");
 my $outcome="expired";
 &webui_icc_pairing_mutate(sub {
  my (@requests)=@_;
  my @kept;
  foreach my $request (@requests) {
   if(($request->{id}||"") ne $id) { push @kept,$request; next; }
   my $status=$request->{status}||"pending";
   if($status eq "approved" || $status eq "denied") { $outcome=$status; next; }
   $outcome="pending";
   push @kept,$request;
  }
  return @kept;
 });
 return '{"status":"pending"}' if($outcome eq "pending");
 return '{"status":"denied"}' if($outcome eq "denied");
 if($outcome eq "approved") {
  my $token=&webui_icc_companion_token();
  return '{"status":"expired"}' if($token eq "");
  return "{\"status\":\"approved\",\"token\":\"$token\"}";
 }
 return '{"status":"expired"}';
}

# Called by the WebUI itself when a human clicks Approve or Deny. Only marks a
# still-pending entry -- one already decided, or gone, is not this call's to
# resolve twice.
sub webui_icc_pair_decide (@) {
 my ($body)=@_;
 return '{"status":"error","message":"Pairing decision is empty"}' unless(defined($body) && length($body)<2048);
 my ($id,$action)=("","");
 $id=$1 if($body=~/"request"\s*:\s*"([0-9a-f]{32})"/);
 $action=$1 if($body=~/"action"\s*:\s*"(approve|deny)"/);
 return '{"status":"error","message":"Invalid pairing decision"}' if($id eq "" || $action eq "");
 my $found=0;
 &webui_icc_pairing_mutate(sub {
  my (@requests)=@_;
  foreach my $request (@requests) {
   next unless(($request->{id}||"") eq $id && ($request->{status}||"") eq "pending");
   $request->{status}=($action eq "approve")?"approved":"denied";
   $found=1;
  }
  return @requests;
 });
 return '{"status":"error","message":"Pairing request not found"}' unless($found);
 return '{"status":"ok"}';
}

# Fed into webui_icc_companion_status() so the browser learns about pending
# approvals through the poll it already runs, with no second polling loop.
# Returned even when no Companion is connected -- an unpaired Companion is by
# definition not connected yet, so the prompt has to appear anyway.
sub webui_icc_pair_requests_fragment () {
 my @requests=&webui_icc_pairing_mutate(sub { my (@requests)=@_; return @requests; });
 my $now=time();
 my @out;
 foreach my $request (@requests) {
  next unless(($request->{status}||"") eq "pending");
  push @out,"{\"id\":\"".($request->{id}||"")."\",\"client\":\"".&_webui_json_escape($request->{client}||"")."\",\"platform\":\"".($request->{platform}||"")."\",\"code\":\"".($request->{code}||"")."\",\"age\":".($now-($request->{created}||$now)).",\"ip\":\"".&_webui_json_escape($request->{ip}||"")."\"}";
 }
 return "[".join(",",@out)."]";
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
 # Correction handling changed from a status-mirrored value into an explicit
 # operator preference in protocol 2. An already-open tab running the old
 # script otherwise keeps posting its stale `none` value every time the live
 # Companion status changes, undoing cLUT immediately before a series. Refuse
 # that cached script instead of silently measuring the wrong transform.
 my $settings_protocol=0;
 $settings_protocol=int($1) if($body=~/"settings_protocol"\s*:\s*(\d+)/);
 return '{"status":"error","message":"Refresh the PGenerator+ WebUI before changing Patch Companion profile correction"}'
  if($settings_protocol<2);
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

sub webui_icc_meter_busy () {
 foreach my $state_file ($_meter_series_file,$_meter_read_file) {
  next unless(-f $state_file);
  my @state_stat=stat($state_file);
  next unless(@state_stat && time()-($state_stat[9]||0)<=30);
  my $state="";
  if(open(my $sf,"<",$state_file)) { local $/; $state=<$sf>||""; close($sf); }
  return 1 if($state=~/"status"\s*:\s*"(?:running|measuring|setup)"/i);
 }
 return 0;
}

sub webui_icc_companion_poll (@) {
 my ($query)=@_;
 my $token=&webui_icc_companion_query_value($query,"token");
 my $expected=&webui_icc_companion_token();
 return '{"status":"unauthorized"}' if($expected eq "" || $token ne $expected);
 my $client=&webui_icc_companion_query_value($query,"client")||"companion";
 my $version=&webui_icc_companion_query_value($query,"version")||"unknown";
 my $build=&webui_icc_companion_query_value($query,"build")||"";
 $build="" unless($build=~/\A[A-Za-z0-9._-]{1,32}\z/);
 my $renderer=&webui_icc_companion_query_value($query,"renderer")||"unknown";
 # Which Companion build this is. Reading a display's active ICC profile, and
 # the active-profile transforms built on it, exist only in the Windows build,
 # so the UI needs this to say what is unavailable rather than showing the
 # missing values as a fault.
 my $platform=&webui_icc_companion_query_value($query,"platform")||"";
 $platform="" unless($platform=~/\A(?:windows|linux|macos)\z/);
 my $swapchain_cs=&webui_icc_companion_query_value($query,"swapchain_cs")||"unknown";
 my $presentation=&webui_icc_companion_query_value($query,"presentation")||"unknown";
 # The Companion's own reason a requested transform is not running.
 my $transform_note=&webui_icc_companion_text_from_hex_query($query,"transform_note_hex");
 my $active_profile=&webui_icc_companion_profile_from_query($query);
 my $selected_display=&webui_icc_companion_text_from_hex_query($query,"display_hex");
 my $transform=&webui_icc_companion_query_value($query,"transform")||"system";
 $transform="system" unless($transform=~/\A(?:system|none|clut|matrix)\z/);
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
 # Record whether this Companion can run colprof locally, and which ArgyllCMS
 # it has. The builder reads this to decide whether to offload; a version that
 # does not match the Pi's is treated as no capability at all, because the same
 # measurements fitted by a different ArgyllCMS produce a different profile.
 my $build_argyll="";
 $build_argyll=$1 if($query=~/(?:^|&)build_argyll=([0-9]+(?:\.[0-9]+){1,3})(?:&|$)/);
 my $build_targen=($build_argyll ne "" && $query=~/(?:^|&)build_targen=1(?:&|$)/)?1:0;
 &webui_icc_companion_build_state($build_argyll,$build_targen);
 my $status="{\"client\":\"".&_webui_json_escape($client)."\",\"version\":\"".&_webui_json_escape($version)."\",\"build\":\"".&_webui_json_escape($build)."\",\"renderer\":\"".&_webui_json_escape($renderer)."\",\"platform\":\"".&_webui_json_escape($platform)."\",\"selected_display\":\"".&_webui_json_escape($selected_display)."\",\"swapchain_color_space\":\"".&_webui_json_escape($swapchain_cs)."\",\"presentation_mode\":\"".&_webui_json_escape($presentation)."\",\"output_max_luminance\":".($output_max+0).",\"output_full_frame_luminance\":".($output_full+0).",\"output_bits_per_color\":".($output_bits+0).",\"active_profile\":\"".&_webui_json_escape($active_profile)."\",\"transform_mode\":\"$transform\",\"transform_ready\":".($transform_ready?"true":"false").",\"transform_note\":\"".&_webui_json_escape($transform_note)."\",\"source_rgb\":[".join(",",@patch_values[0..2])."],\"submitted_rgb\":[".join(",",@patch_values[3..5])."],\"hdr_active\":".($hdr?"true":"false").",\"last_seen\":$seen}";
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
 # A pending colprof job outranks the idle response: the builder is blocked
 # waiting on it, and the patch path is idle while a fit runs.
 if($build_argyll ne "" && -f $_icc_companion_build_job) {
  my $job="";
  if(open(my $jf,"<",$_icc_companion_build_job)) { local $/; $job=<$jf>||""; close($jf); }
  if($job=~/^\s*\{/ && length($job)<64*1024*1024) {
   $job=~s/\}\s*\z//;
   return $job.',"status":"build",'.&webui_icc_companion_settings_fragment().'}';
  }
 }
 # Profile installation is intentionally separate from patch delivery. A
 # queued install waits until the Companion is otherwise idle, so it cannot
 # change the active display profile in the middle of a measurement series.
 if(!&webui_icc_meter_busy() && -f $_icc_companion_install_job) {
  my $job="";
  if(open(my $jf,"<",$_icc_companion_install_job)) { local $/; $job=<$jf>||""; close($jf); }
  if($job=~/^\s*\{/ && length($job)<4096) {
   $job=~s/\}\s*\z//;
   return $job.',"status":"install",'.&webui_icc_companion_settings_fragment().'}';
  }
 }
 my $poll_ms=500;
 $poll_ms=50 if(&webui_icc_meter_busy());
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

# Version of the Patch Companion this PGenerator ships, read from the resource
# script rather than hard-coded so it cannot drift from the binary. The
# browser now prefers the newest tagged release on GitHub for its
# outdated-Companion check, since the Pi has no internet route on this
# network to look that up itself; this stays as the offline fallback for
# whenever that browser-side lookup never resolves.
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

# Publish the Companion's colprof capability for the builder to read. Written on
# every poll so a Companion that goes away stops being offered work within one
# poll interval, rather than stalling a build until its timeout.
sub webui_icc_companion_build_state (@) {
 my ($argyll,$targen)=@_;
 eval { require File::Path; File::Path::make_path($_icc_companion_build_dir,{mode=>0700}); } unless(-d $_icc_companion_build_dir);
 my $connected=($argyll ne "") ? "true" : "false";
 my $json='{"connected":'.$connected.',"argyll_version":"'.&_webui_json_escape($argyll).'","targen":'.($targen?'true':'false').',"seen":'.time().'}';
 return &webui_icc_companion_write_atomic($_icc_companion_build_state,$json,0600);
}

# Serve the characterization for the pending build. Kept out of the poll
# response because that buffer is 32 KB on the Companion and a 1000-patch .ti3
# is around 76 KB.
sub webui_icc_companion_build_ti3 (@) {
 my ($query)=@_;
 my $token=&webui_icc_companion_query_value($query,"token");
 my $expected=&webui_icc_companion_token();
 return (0,'{"status":"unauthorized"}') if($expected eq "" || $token ne $expected);
 return (0,'{"status":"error","message":"No build is pending"}') unless(-f $_icc_companion_build_job && -f $_icc_companion_build_ti3);
 my $data="";
 if(open(my $fh,"<",$_icc_companion_build_ti3)) { local $/; $data=<$fh>||""; close($fh); }
 return (0,'{"status":"error","message":"Characterization is unavailable"}') if($data eq "");
 my $job="";
 if(open(my $jh,"<",$_icc_companion_build_job)) { local $/; $job=<$jh>||""; close($jh); }
 my $job_id="";
 $job_id=$1 if($job=~/"job"\s*:\s*"([0-9]+-[0-9]+)"/);
 return (0,'{"status":"error","message":"Build job is invalid"}') if($job_id eq "");
 # Fetching the TI3 acknowledges that the Companion started this build. Its
 # poll loop is blocked while synchronous colprof runs, which can exceed the
 # ordinary liveness window without indicating a disconnect.
 my $claim='{"job":"'.$job_id.'","seen":'.time().'}';
 return (0,'{"status":"error","message":"Could not claim the build"}')
  unless(&webui_icc_companion_write_atomic($_icc_companion_build_claim,$claim,0600));
 return (1,$data);
}

# Serve an optional binary input for a Companion targen job. The file is empty
# for an ordinary chart and contains the temporary preconditioning ICC when
# targen -c is requested. Fetching it also claims the synchronous job.
sub webui_icc_companion_build_input (@) {
 my ($query)=@_;
 my $token=&webui_icc_companion_query_value($query,"token");
 my $expected=&webui_icc_companion_token();
 return (0,'{"status":"unauthorized"}') if($expected eq "" || $token ne $expected);
 return (0,'{"status":"error","message":"No chart build is pending"}')
  unless(-f $_icc_companion_build_job && -f $_icc_companion_build_input);
 my $job="";
 if(open(my $jh,"<",$_icc_companion_build_job)) { local $/; $job=<$jh>||""; close($jh); }
 my $job_id="";
 $job_id=$1 if($job=~/"job"\s*:\s*"([0-9]+-[0-9]+)"/);
 return (0,'{"status":"error","message":"Chart build job is invalid"}')
  if($job_id eq "" || $job!~/"operation"\s*:\s*"targen"/);
 my $data="";
 if(open(my $fh,"<:raw",$_icc_companion_build_input)) { local $/; $data=<$fh>; close($fh); }
 return (0,'{"status":"error","message":"Chart input is unavailable"}') unless(defined($data));
 my $claim='{"job":"'.$job_id.'","seen":'.time().'}';
 return (0,'{"status":"error","message":"Could not claim the chart build"}')
  unless(&webui_icc_companion_write_atomic($_icc_companion_build_claim,$claim,0600));
 return (1,$data);
}

# Receive a profile built by the Companion, or the reason it could not be.
sub webui_icc_companion_build_result (@) {
 my ($query,$body)=@_;
 my $token=&webui_icc_companion_query_value($query,"token");
 my $expected=&webui_icc_companion_token();
 return '{"status":"unauthorized"}' if($expected eq "" || $token ne $expected);
 return '{"status":"error","message":"No build is pending"}' unless(-f $_icc_companion_build_job);
 my $job="";
 if(open(my $jh,"<",$_icc_companion_build_job)) { local $/; $job=<$jh>||""; close($jh); }
 my $operation=($job=~/"operation"\s*:\s*"targen"/)?"targen":"colprof";
 # Parsed here rather than through webui_icc_companion_query_value: that parser
 # is deliberately strict because it also reads tokens and client names, and a
 # build failure message needs spaces and punctuation to be worth reporting.
 # Sanitised immediately below to the same character class it enforces.
 my $error="";
 $error=$1 if($query=~/(?:^|&)error=([^&]{1,240})(?:&|$)/);
 $error=~s/\+/ /g;
 $error=~s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;
 if($error ne "") {
  $error=~s/[^A-Za-z0-9 ._:\/()\[\]-]+/?/g;
  return '{"status":"error","message":"Could not store the build error"}'
   unless(&webui_icc_companion_write_atomic($_icc_companion_build_error,substr($error,0,240),0600));
  # The durable result/error file is the builder's completion signal. Remove
  # the advertised job before replying so the Companion's next poll cannot
  # claim and run the same synchronous colprof job a second time while the
  # builder is still waking up and consuming that signal.
  unlink($_icc_companion_build_job);
  unlink($_icc_companion_build_ti3);
  unlink($_icc_companion_build_input);
  unlink($_icc_companion_build_claim);
  return '{"status":"ok"}';
 }
 return '{"status":"error","message":"Empty build payload"}' unless(defined($body) && length($body)>32);
 return '{"status":"error","message":"Build payload is too large"}' if(length($body)>64*1024*1024);
 if($operation eq "targen") {
  return '{"status":"error","message":"Payload is not an Argyll TI1 chart"}'
   unless($body=~/\ACTI1[ \t]*\r?\n/ && $body=~/\bBEGIN_DATA_FORMAT\b/ && $body=~/\bBEGIN_DATA\b/);
 } else {
  # An ICC declares its own byte count in the first four bytes and carries the
  # acsp signature; reject anything else rather than handing the builder a file
  # that will only fail later.
  my $declared=unpack("N",substr($body,0,4));
  return '{"status":"error","message":"Payload is not an ICC profile"}'
   if($declared!=length($body) || substr($body,36,4) ne "acsp");
 }
 return '{"status":"error","message":"Could not store the build result"}'
  unless(&webui_icc_companion_write_atomic($_icc_companion_build_result,$body,0600));
 unlink($_icc_companion_build_job);
 unlink($_icc_companion_build_ti3);
 unlink($_icc_companion_build_input);
 unlink($_icc_companion_build_claim);
 return '{"status":"ok"}';
}

sub webui_icc_companion_profile_install (@) {
 my ($body)=@_;
 my $file="";
 $file=$1 if(defined($body) && length($body)<2048 && $body=~/"file"\s*:\s*"([A-Za-z0-9._()-]+\.icc)"/i);
 return '{"status":"error","message":"Invalid ICC profile name"}' if($file eq "" || $file=~/\.\./);
 my $path="$_icc_profile_dir/$file";
 return '{"status":"error","message":"ICC profile not found"}' unless(-f $path);
 my $bytes=-s $path;
 return '{"status":"error","message":"ICC profile is empty or too large"}' unless(defined($bytes) && $bytes>128 && $bytes<=64*1024*1024);
 my $connected=&webui_icc_companion_status();
 return '{"status":"error","message":"PGenerator+ Patch Companion is not connected"}' unless($connected=~/"connected"\s*:\s*true/);
 return '{"status":"error","message":"Wait for the active meter reading to finish before installing a display profile"}' if(&webui_icc_meter_busy());
 return '{"status":"error","message":"Update PGenerator+ ICC Tools before using Install & Apply"}'
  unless($connected=~/"version"\s*:\s*"(\d+)\.(\d+)\.(\d+)"/ && ($1*1000000+$2*1000+$3)>=1004011);
 eval { require File::Path; File::Path::make_path($_icc_companion_install_dir,{mode=>0700}); } unless(-d $_icc_companion_install_dir);
 return '{"status":"error","message":"Could not prepare the profile installation"}' unless(-d $_icc_companion_install_dir);
 # Once the OS owns the newly installed profile, the Companion must stop
 # applying an application-side cLUT or matrix. Otherwise its patches would be
 # corrected once by the Companion and again by the OS profile just selected.
 my ($window_mode,$patch_size,undef,undef,undef,$signal_mode)=&webui_icc_companion_settings_values();
 my $settings=&webui_icc_companion_settings('{"settings_protocol":2,"window_mode":"'.$window_mode.'","patch_size":'.$patch_size.',"correction_mode":"system","correction_signal_mode":"'.$signal_mode.'"}');
 return $settings unless($settings=~/"status"\s*:\s*"ok"/);
 my $job=int(Time::HiRes::time()*1000)."-".$$;
 my $payload='{"install_job":"'.$job.'","file":"'.&_webui_json_escape($file).'"}';
 my $state='{"status":"pending","job":"'.$job.'","file":"'.&_webui_json_escape($file).'","message":"Waiting for Patch Companion"}';
 return '{"status":"error","message":"Could not queue the profile installation"}'
  unless(&webui_icc_companion_write_atomic($_icc_companion_install_status,$state,0600) &&
         &webui_icc_companion_write_atomic($_icc_companion_install_job,$payload,0600));
 return '{"status":"ok","job":"'.$job.'"}';
}

sub webui_icc_companion_profile_install_status (@) {
 my ($query)=@_;
 my $job=&webui_icc_companion_query_value($query,"job");
 return '{"status":"error","message":"Invalid installation job"}' unless($job=~/\A\d+-\d+\z/);
 my $state="";
 if(open(my $fh,"<",$_icc_companion_install_status)) { local $/; $state=<$fh>||""; close($fh); }
 return '{"status":"error","message":"Installation status is unavailable"}' unless($state=~/^\s*\{/ && $state=~/"job"\s*:\s*"\Q$job\E"/);
 return $state;
}

sub webui_icc_companion_profile_install_data (@) {
 my ($query)=@_;
 my $token=&webui_icc_companion_query_value($query,"token");
 my $expected=&webui_icc_companion_token();
 return (0,'{"status":"unauthorized"}') if($expected eq "" || $token ne $expected);
 my $job_id=&webui_icc_companion_query_value($query,"job");
 my $job="";
 if(open(my $fh,"<",$_icc_companion_install_job)) { local $/; $job=<$fh>||""; close($fh); }
 return (0,'{"status":"error","message":"No matching installation is pending"}')
  unless($job_id=~/\A\d+-\d+\z/ && $job=~/"install_job"\s*:\s*"\Q$job_id\E"/);
 my $file=""; $file=$1 if($job=~/"file"\s*:\s*"([A-Za-z0-9._()-]+\.icc)"/i);
 return (0,'{"status":"error","message":"Installation job is invalid"}') if($file eq "" || $file=~/\.\./);
 my $data="";
 if(open(my $pf,"<:raw","$_icc_profile_dir/$file")) { local $/; $data=<$pf>||""; close($pf); }
 return (0,'{"status":"error","message":"ICC profile is unavailable"}') unless(length($data)>128 && length($data)<=64*1024*1024 && substr($data,36,4) eq "acsp");
 return (1,$data);
}

sub webui_icc_companion_profile_install_result (@) {
 my ($query)=@_;
 my $token=&webui_icc_companion_query_value($query,"token");
 my $expected=&webui_icc_companion_token();
 return '{"status":"unauthorized"}' if($expected eq "" || $token ne $expected);
 my $job_id=&webui_icc_companion_query_value($query,"job");
 my $job="";
 if(open(my $fh,"<",$_icc_companion_install_job)) { local $/; $job=<$fh>||""; close($fh); }
 return '{"status":"error","message":"No matching installation is pending"}'
  unless($job_id=~/\A\d+-\d+\z/ && $job=~/"install_job"\s*:\s*"\Q$job_id\E"/);
 my $file=""; $file=$1 if($job=~/"file"\s*:\s*"([A-Za-z0-9._()-]+\.icc)"/i);
 my $ok=($query=~/(?:^|&)ok=1(?:&|$)/)?1:0;
 my $message=&webui_icc_companion_text_from_hex_query($query,"message_hex");
 $message=$ok ? "Installed and applied by Patch Companion" : "Profile Loader could not install and apply the profile" if($message eq "");
 my $state='{"status":"'.($ok?'ok':'error').'","job":"'.$job_id.'","file":"'.&_webui_json_escape($file).'","message":"'.&_webui_json_escape($message).'"}';
 return '{"status":"error","message":"Could not save the installation result"}'
  unless(&webui_icc_companion_write_atomic($_icc_companion_install_status,$state,0600));
 unlink($_icc_companion_install_job);
 return '{"status":"ok"}';
}

sub webui_icc_companion_status (@) {
 my $content="";
 my @st=stat($_icc_companion_status_file);
 # The companion's synchronous HTTP poll can take about three seconds on a
 # busy or remote link. Allow several missed polls before declaring it gone.
 if(@st && time()-($st[9]||0)<=12 && open(my $fh,"<",$_icc_companion_status_file)) { local $/; $content=<$fh>||""; close($fh); }
 my $shipped=&webui_icc_companion_shipped_version();
 my $shipped_json=($shipped ne "") ? ',"shipped_version":"'.&_webui_json_escape($shipped).'"' : "";
 my $pair_requests_json=',"pair_requests":'.&webui_icc_pair_requests_fragment();
 # A Companion running colprof/targen cannot send its normal heartbeat until
 # the child exits. A matching claim proves that it received the current job;
 # expose that busy state separately so the UI does not call it disconnected.
 my ($build_job,$build_claim)=("","");
 if(open(my $jf,"<",$_icc_companion_build_job)) { local $/; $build_job=<$jf>||""; close($jf); }
 if(open(my $cf,"<",$_icc_companion_build_claim)) { local $/; $build_claim=<$cf>||""; close($cf); }
 my ($job_id,$claim_id,$operation)=("","","");
 $job_id=$1 if($build_job=~/"job"\s*:\s*"(\d+-\d+)"/);
 $claim_id=$1 if($build_claim=~/"job"\s*:\s*"(\d+-\d+)"/);
 $operation=$1 if($build_job=~/"operation"\s*:\s*"(colprof|targen)"/);
 my $build_active=($job_id ne "" && $job_id eq $claim_id && $operation ne ""
                   && !-f $_icc_companion_build_result && !-f $_icc_companion_build_error) ? 1 : 0;
 my $build_json=',"build_offload":'.($build_active?'true':'false');
 $build_json.=',"build_operation":"'.$operation.'"' if($build_active);
 return '{"status":"ok","connected":false,'.&webui_icc_companion_settings_fragment().$shipped_json.$pair_requests_json.$build_json.'}' unless($content=~/^\s*\{/);
 $content=~s/^\s*\{//;
 return '{"status":"ok","connected":true,'.&webui_icc_companion_settings_fragment().$shipped_json.$pair_requests_json.$build_json.','.$content;
}

# Publish a calibration-card patch to the paired target-computer companion.
# Patch size is ignored in resizable-window mode and controls centered window
# or APL geometry when the Companion is in borderless fullscreen mode.
sub webui_icc_companion_pattern (@) {
 my ($body)=@_;
 return '{"status":"error","message":"Invalid companion pattern request"}' unless(defined($body) && length($body)<8192);
 my $connected=&webui_icc_companion_status();
 return '{"status":"error","message":"PGenerator+ Patch Companion is not connected"}' unless($connected=~/"connected"\s*:\s*true/);
 my $idle_request=($body=~/"(?:name|status)"\s*:\s*"(?:stop|align|alignment)"/i) ? 1 : 0;
 if($idle_request && $body=~/"only_if_idle"\s*:\s*true/i && -f $_icc_companion_command_file) {
  my $current="";
  if(open(my $fh,"<",$_icc_companion_command_file)) { local $/; $current=<$fh>||""; close($fh); }
  my $currently_idle=($current eq "" || $current=~/"status"\s*:\s*"align"/i || $current=~/"stabilization"\s*:\s*true/i) ? 1 : 0;
  return '{"status":"ok","unchanged":true}' if(!$currently_idle);
 }
 # A stop/alignment command marks the selected patch generator as idle. When
 # stabilization is enabled, replace that idle target with the configured
 # neutral stimulus and geometry. The shared helper also verifies that a meter
 # is still connected before allowing the replacement.
 if($idle_request) {
  my ($stabilization_active,$stimulus,$size)=&webui_meter_stabilization_active();
  if($stabilization_active) {
   &webui_reload_pgenerator_conf();
   my $signal_mode=&webui_pattern_signal_mode($body);
   my ($signal_range)=$body=~/"signal_range"\s*:\s*"?(\d+)"?/;
   $signal_range=&webui_preferred_rgb_quant_range() if(!defined($signal_range) || $signal_range eq "");
   my $max_bpc=($signal_mode eq "hdr10") ? 10 : ($pgenerator_conf{"max_bpc"}||8);
   my ($code,$input_max)=&webui_meter_stabilization_code($stimulus,$signal_mode,$signal_range,$max_bpc);
   my $max_luma=&webui_pattern_max_luma($body);
   $body='{"name":"stabilization","r":'.$code.',"g":'.$code.',"b":'.$code
    .',"size":'.$size.',"input_max":'.$input_max.',"signal_mode":"'.$signal_mode
    .'","signal_range":"'.$signal_range.'","max_luma":'.$max_luma.'}';
  }
 }
 my $sequence=int(Time::HiRes::time()*1000);
 if(open(my $fh,"<",$_icc_companion_command_file)) {
  local $/; my $previous=<$fh>||""; close($fh);
  my $last=0; $last=$1 if($previous=~/"sequence"\s*:\s*(\d+)/);
  $sequence=$last+1 if($sequence<=$last);
 }
 my $payload="";
 if($body=~/"(?:name|status)"\s*:\s*"(?:stop|align|alignment)"/i) {
  $payload='{"status":"align","sequence":'.$sequence.'}';
  # Simulated meter: the Companion window is now idle on its alignment target.
  &webui_meter_sim_pattern_record(name=>"stop",r=>0,g=>0,b=>0,input_max=>255,
   signal_mode=>"sdr",source_range=>"FULL",provider=>"companion");
 } else {
  my ($r,$g,$b)=(0,0,0);
  $r=$1 if($body=~/"(?:r|patch_r)"\s*:\s*(\d+)/);
  $g=$1 if($body=~/"(?:g|patch_g)"\s*:\s*(\d+)/);
  $b=$1 if($body=~/"(?:b|patch_b)"\s*:\s*(\d+)/);
  my $input_max=255; $input_max=$1 if($body=~/"(?:input_max|patch_input_max)"\s*:\s*(\d+)/);
  $input_max=255 if($input_max<1 || $input_max>65535);
  $r=$input_max if($r>$input_max); $g=$input_max if($g>$input_max); $b=$input_max if($b>$input_max);
  my $size=100; $size=$1 if($body=~/"size"\s*:\s*(\d+)/);
  my %allowed_apl_size=map { $_=>1 } (105,110,118,125,150);
  $size=100 if(($size<1 || $size>100) && !$allowed_apl_size{$size});
  my $signal_mode="sdr"; $signal_mode=$1 if($body=~/"signal_mode"\s*:\s*"(sdr|hdr10|hlg|dv)"/);
  my $stabilization=($body=~/"name"\s*:\s*"stabilization"/i) ? ',"stabilization":true' : '';
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
  $payload='{"status":"patch","sequence":'.$sequence.',"r":'.$r.',"g":'.$g.',"b":'.$b.',"size":'.$size.',"input_max":'.$input_max.',"code_min":'.$code_min.',"code_max":'.$code_max.',"signal_mode":"'.$signal_mode.'","max_luma":'.($max_luma+0).',"min_luma":'.($min_luma+0).',"max_cll":'.($max_cll+0).',"max_fall":'.($max_fall+0).$stabilization.'}';
  # Simulated meter: record the Companion patch so spotread_sim measures it.
  &webui_meter_sim_pattern_record(name=>"patch",r=>$r,g=>$g,b=>$b,input_max=>$input_max,
   signal_mode=>$signal_mode,source_range=>(($signal_range eq "1")?"LIMITED":"FULL"),
   max_luma=>$max_luma,provider=>"companion");
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
  $content=<$fh>//"";
  close($fh);
 }
 # Cache successful reads only, so restoring a missing file takes effect on
 # the next request without a restart; the caller decides how to fail.
 if($content eq "") {
  &log("WebUI ERROR: ICC UI asset missing or empty: $name ($dir/$name)",1) if(defined(&log));
  return "";
 }
 $_webui_icc_asset_cache{$name}=$content;
 return $content;
}

1;
