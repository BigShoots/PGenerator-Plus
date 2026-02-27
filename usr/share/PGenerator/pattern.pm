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
#       Create Pattern File Function          #
###############################################
sub create_pattern_file (@) {
 my $draw=shift;
 my $dim=shift;
 my $resolution=shift;
 my $rgb=shift;
 my $bg=shift;
 my $position=shift;
 my $text=shift;
 my $return_str=shift;
 my $simple=shift;
 my $requested_by=(($requested_by=shift) eq "") ? $requested_by_default : $requested_by;
 my $scaling_disabled=($requested_by eq "RGB") ? 1 : 0;
 my ($min_rgb,$max_rgb)=(0,255);
 my @el_rgb=split(",",$rgb);
 my $bits="";
 my $draw_type="";
 my $new_rgb="";
 my $pattern_string="";
 return if($#el_rgb != 2);
 # HCFR, DeviceControl Simple Template,Calman
 if($simple) {
  ($draw_type,$bits)=$draw=~/([A-Z]+)(\d+)bit/;
  $draw=$draw_type             if($draw_type ne "");
  ($min_rgb,$max_rgb)=(0,1023) if($bits == 10);
 }
 $bits=$bits_default if($bits eq "");
 for(@el_rgb) {
  return if($_ < $min_rgb || $_ > $max_rgb);
  $new_rgb.=int($_).",";
 }
 $bg=$bg_default if($bg eq "");
 $position=$position_default if($position eq "");
 $new_rgb=~s/,$//;
 $options="TEXT";
 $options="IMAGE" if($draw eq "IMAGE");
 if(!$scaling_disabled) {
  my $scaled_w=&round_val((split(",",$dim))[0]*($w_s/$max_x));
  my $scaled_h=&round_val((split(",",$dim))[1]*($h_s/$max_y));
  # Cap to display dimensions — prevents oversized patterns and negative positions
  $scaled_w=$w_s if($scaled_w > $w_s);
  $scaled_h=$h_s if($scaled_h > $h_s);
  $dim="$scaled_w,$scaled_h";
 }
 # calculate and check the position
 $position=&get_position($dim,$draw,$position,$scaling_disabled);
 @num_sep=split(",",$position);
 for(@num_sep) { return &error() if(/[^0-9-]/); }
 $scaling_done=1 if(!$scaling_disabled);
 # create the pattern file
 $pattern_string.="PATTERN_NAME=$pname_file\n" if($pname_file ne "");
 $pattern_string.="MOVIE_NAME=TestPattern\nBITS=$bits\n" if($simple);
 $pattern_string.="DRAW=$draw\nDIM=$dim\nRESOLUTION=$resolution\nRGB=$new_rgb\nBG=$bg\nPOSITION=$position\n$options=$text\nEND=1\n";
 $pattern_string.="FRAME_NAME=TestPattern\nFRAME=$frame_default\n" if($simple);
 return $pattern_string if($return_str);
 open(FILE,">$command_file.tmp");
 print FILE $pattern_string;
 close(FILE);
 rename("$command_file.tmp","$command_file");
 &load_new_pattern_file("$requested_by");
 &stats("patterns",1);
}

###############################################
#          Functions Pattern Function         #
###############################################
sub execute_functions (@) {
 my $draw=shift;
 my $dim=shift;
 my $res=shift;
 my $functions=shift;
 open(FUNCTIONS,"$functions");
 while(<FUNCTIONS>) {
  eval $_;
 }
 close(FUNCTIONS);
}

###############################################
#            Pattern Video Function           #
###############################################
sub play_video(@) {
 my $program = shift;
 my $video = shift;
 my ($duration,$repeat) = split("-",shift);
 $repeat=0 if($repeat != 1);
 &pattern_generator_stop();
 #system("$timeout --foreground -k $duration $duration $program '$video_dir/$video' &>/dev/null");
 &create_pattern_file("$draw_default","$w_s,$h_s",$res_default,"$rgb_default","$bg_default","$position_default","","","","play_video");
 $program_video_to_kill=$program;
 #system("$timeout --foreground -k $duration $duration $program '$video_dir/$video' &>/dev/null &");
 # timeout exit with 124 and kill process exit withn 143
 system("while [ true ]; do $timeout --foreground -k $duration $duration $program '$video_dir/$video' &>/dev/null;if [ \$? == 143 ] || [ $repeat == 0 ];then exit 0;fi; done &");
 #&pattern_generator_start();
}

###############################################
#            Pattern Conversion               # 
###############################################
sub pc_to_video (@) {
 my $val = shift;
 $val=((219/255)*$val)+16;
 return &round_val($val);
}

###############################################
#              File Get List                 # 
###############################################
sub get_file_list (@) {
 my $dir = shift;
 my $str = "";
 opendir(DIR,"$dir");
 @dir=sort(readdir(DIR));
 closedir(DIR);
 for(@dir) {
  next if(! -f "$dir/$_");
  $str.="$_\n";
 }
 chomp($str);
 return $str;
}

###############################################
#             Pattern Get Image               #  
###############################################
sub get_pattern_image (@) {
 my $dir = shift;
 my $pattern = shift;
 my $img_content="";
 my $response="";
 my %frame = ();
 my $n_frames = 0;
 my $count = 0;
 open(FILE,"$pattern_frames/pattern.info");
 $pname_file=<FILE>;
 close(FILE);
 chomp($pname_file);
 return $none if($pname_file ne $pattern);
 opendir(DIR,"$dir");
 @dir=readdir(DIR);
 closedir(DIR);
 for(@dir) {
  @el=split("-",$_);
  $frame{$el[0]}=$_;
  $n_frames++ if (/\.png/);
 }
 # remove old preview frames
 foreach my $key (sort {$a <=> $b} keys %frame) {
  $_=$frame{$key};
  next if (!/\.png/);
  last if($count == ($n_frames-1));
  ($preview="preview-".$_)=~s/\.png$/.jpg/;
  $preview=~s/\%//g;
  unlink("$var_dir/running/$preview");
  $count++;
 }
 # convert last frame preview
 foreach my $key (sort {$b <=> $a} keys %frame) {
  $_=$frame{$key};
  next if (!/\.png/);
  ($preview="preview-".$_)=~s/\.png$/.jpg/;
  $preview=~s/\%//g;
  $size_str=$img_width."x".$img_height;
  system("$convert -resize $size_str $pattern_frames/$_ $var_dir/running/$preview") if(!-f "$var_dir/running/$preview");
  return "<img src=http://\$ip_device:\$port_device/running/$preview-".time().">";
 }
 return $ok_response;
}

###############################################
#         Pattern Images Get List             # 
###############################################
sub get_patternimages_list (@) {
 my $pname = shift;
 my $str = "";
 my @arr=();
 my %img=();
 my $last="";
 my $index="";
 my $cnt=0;
 open(FILE,"$pattern_frames/pattern.info");
 $pname_file=<FILE>;
 close(FILE);
 chomp($pname_file);
 return "" if($pname ne $pname_file);
 opendir(DIR,"$pattern_frames/");
 @dir=readdir(DIR);
 closedir(DIR);
 for(@dir){
  next if($_ eq "." ||  $_ eq ".." || -d "$pattern_frames/$_");
  @el=split("-",$_);
  $index=$el[0];
  $pname=$duration=$el[1];
  $pname=~s/$split_images_string.*//;
  $duration=~s/.*$split_images_string//;
  $duration=~s/\.png//;
  $key=$index;
  next if($key eq "pattern.info");
  $key=$last="-1" if($_ =~/done$/);
  $index="Done" if($index eq "done");
  $pattern_info="$index";
  $pattern_info.=")" if($index ne "Done");
  $duration=($duration/1000000)."s" if($key ne "-1");
  $pattern_info.=" $pname $duration";
  $img{$key}=$pattern_info;
  $cnt++;
 }
 $str="Ready" if($cnt == 0 && $pname_file ne "");
 if($last ne "-1") {
  foreach $key (sort {$b<=>$a} keys %img) {
   $str.=$img{$key}."\n";
  }
 } else {
  foreach $key (sort {$a<=>$b} keys %img) {
   $str.=$img{$key}."\n";
  }
 }
 chomp($str);
 return $str;
}

###############################################
#           Pattern SaveImages                #
###############################################
sub save_images_pattern (@) {
 my $file = shift;
 my $images = shift;
 open(FILE,">$pattern_frames/pattern.info");
 print FILE $file;
 close(FILE);
 open(FILE,">$var_dir/running/$file.save");
 close(FILE);
 &create_return_file();
}

###############################################
#             Reload Pattern File             #
###############################################
sub load_new_pattern_file (@) {
 my $requested_by = shift;
 &video_program_stop("$program_video_to_kill");
 &create_return_file() if($requested_by ne $last_pattern_requested_by || $requested_by eq "");
 $last_pattern_requested_by=$requested_by;
}


###############################################
#             Create Return File              #
###############################################
sub create_return_file (@) {
 open(FILE,">$var_dir/running/return");
 close(FILE);
}

###############################################
#               Pattern Get                   #
###############################################
sub get_pattern (@) {
 my $type = shift;
 my $pattern = shift;
 my $rgb = shift;
 my $requested_by = shift;
 my ($str,$bg,$dim,$draw_type,$pos,$res,$frame,$str_other,$image,$bits,$rules) = "";
 my %var=();
 my $pattern_dir = $pattern_templates;
 my $scaling_disabled=0;
 #
 # For HCFR or LS
 #
 if($rgb=~/;/) {
  my @el=split(";",$rgb);
  $rgb=$el[0];
  $bg=$el[1];
  $draw_type=$el[2];
  $dim=$el[3];
  $pos=$el[4];
  $res=$el[5];
  $frame=$el[6];
  $str_other=$el[7];
  $bits=$el[8] if($el[8] ne "");
  $scaling_disabled=1;
 }
 #
 # Read Pattern
 #
 $pattern_dir = "$var_dir/running/tmp" if($type eq "$test_template_ramdisk_command");
 my $file_pattern="$pattern_dir/$pattern";
 return &error() if(!-f $file_pattern);
 open($pattern,"$pattern_dir/$pattern");
 $first_row=<$pattern>;
 $first_row=<$pattern> if($first_row =~/^PERMANENT=/);
 chomp($first_row);
 #
 # EVAL Pattern
 #
 if($first_row eq "EVALPATTERN=") {
  while(<$pattern>) {
   $rules.=$_;
  }
  eval $rules;
  return &error() if($@ ne "");
  $file_pattern="$var_dir/running/$pattern.tmp";
  open(TMP,">$file_pattern");
  print TMP $str;
  close(TMP);
  $str="";
 }
 #
 # Classic Pattern
 #
 open($pattern,"$file_pattern");
 while(<$pattern>) {
  $scaling_disabled=1 if(/^# SCALING=DISABLED/ || $scaling_done);
  next if($_=~/^(#|\n|\r)/);
  if($_=~/^VAR=(.*)=(.*)/) {
   $var{"$1"}=&replace_string($2,$rgb);
   next;
  }
  foreach $key (keys %var) {
   $_=~s/$key/$var{$key}/g;
  }
  #
  # FRAME
  #
  if($_=~/^FRAME=DYNAMIC/) {
   $frame=$1             if($frame eq "" && /^FRAME=DYNAMIC\|\|(.*)/);
   $frame=$frame_default if($frame eq "");
   $str.="FRAME=$frame\n";
   next;
  }
  #
  # IMAGE
  #
  if($_=~/^IMAGE=DYNAMIC/) {
   $str_other=$1                if($str_other eq "" && /^IMAGE=DYNAMIC\|\|(.*)/);
   $_="IMAGE=$str_other\n";
  }
  if($_=~/^IMAGE=(.*)/) {
   $image=$1;
   $str.="IMAGE=$1\n";
   next;
  }
  #
  # TEXT
  #
  if($_=~/^TEXT=DYNAMIC/) {
   $str_other=$1            if($str_other eq "" && /^TEXT=DYNAMIC\|\|(.*)/);
   $str_other=$text_default if($str_other eq "");
   $_="TEXT=$str_other\n";
  } 
  if($_=~/^TEXT=(.*)/) {
   $str_other=&replace_string($1,$rgb);
   $str.="TEXT=$str_other\n";
   next;
  }
  #
  # DRAW
  #
  if($_=~/^DRAW=DYNAMIC/) {
   $draw_type=$1            if($draw_type eq "" && /^DRAW=DYNAMIC\|\|(.*)/);
   $draw_type=$draw_default if($draw_type eq "");
   $_="DRAW=$draw_type\n";
  } 
  if($_=~/^DRAW=(.*)/) {
   $draw_type=$1;
   return &error() if($draw_type !~/^RECTANGLE$|^CIRCLE$|^TRIANGLE$|^TEXT$|^IMAGE$/);
   $str.=$_;
   next;
  }
  #
  # DIM
  #
  if($_=~/^DIM=DYNAMIC/) {
   $dim=$1           if($dim eq "" && /^DIM=DYNAMIC\|\|(.*)/);
   $dim=$dim_default if($dim eq "");
   $_="DIM=$dim\n";
  } 
  if($_=~/^DIM=NATIVE/) {
   if($draw_type eq "IMAGE") {
    open(IDENTIFY,"$identify '$image'|");
    $dim=(<IDENTIFY>)=~s/ /,/r;
    close(DENTIFY);
    $_="DIM=$dim\n" if($dim ne "");
   }
  }
  if($_=~/^DIM=(.*)\%/) {
   $sqrt=sqrt($1/100);
   $dim=&round_val($sqrt*$w_s).",".&round_val($sqrt*$h_s);
   $_="DIM=$dim\n";
  } 
  if($_=~/^DIM=(.*)/) {
   $dim=$1;
   if(!$scaling_disabled) {
    my $scaled_w=&round_val((split(",",$dim))[0]*($w_s/$max_x));
    my $scaled_h=&round_val((split(",",$dim))[1]*($h_s/$max_y));
    $scaled_w=$w_s if($scaled_w > $w_s);
    $scaled_h=$h_s if($scaled_h > $h_s);
    $dim="$scaled_w,$scaled_h";
   }
   $_="DIM=$dim\n";
   @num_dim=split(",",$dim);
   for(@num_dim) { return &error() if(/[^0-9]/); }
   return &error() if($num_dim[0] > $w_s || $num_dim[1] > $h_s);
   $str.=$_;
   next;
  }
  #
  # MACRO
  #
  if($_=~/^MACRO=(.*)/) {
   &get_pattern($type,$1,$rgb,"MACRO");
   next;
  }
  #
  # EVAL DISABLED for security reason
  #
  return &error("eval denied") if($_=~/^EVAL=(.*)/);
  # 
  # POSITION
  #
  if($_=~/^POSITION=DYNAMIC/) {
   $pos=$1                if($pos eq "" && /^POSITION=DYNAMIC\|\|(.*)/);
   $pos=$position_default if($pos eq "");
   $_="POSITION=$pos\n";
  }
  if($_=~/^POSITION=(.*)/) {
   $pos=&get_position($dim,$draw_type,$1,$scaling_disabled);
   @num_sep=split(",",$1);
   for(@num_sep) { return &error() if(/[^0-9-]/); }
   @num_sep=split(",",$pos);
   for(@num_sep) { return &error() if(/[^0-9-]/); }
   $str.="POSITION=$pos\n";
   next;
  }
  #
  # BG
  #
  if($_=~/^BG=DYNAMIC/) {
   $bg=$1          if($bg eq "" && /^BG=DYNAMIC\|\|(.*)/);
   $bg=$bg_default if($bg eq "");
   $str.="BG=$bg\n";
   next;
  }
  #
  # RESOLUTION
  #
  if($_=~/^RESOLUTION=DYNAMIC/) {
   $res=$1           if($res eq "" && /^RESOLUTION=DYNAMIC\|\|(.*)/);
   $res=$res_default if($res eq "");
   $str.="RESOLUTION=$res\n";
   next;
  }
  #
  # BITS
  #
  if($_=~/^BITS=DYNAMIC/) {
   $bits=$1             if($bits eq "" && /^BITS=DYNAMIC\|\|(.*)/);
   $bits=$bits_default  if($bits eq "");
   $_="BITS=$bits\n";
  }
  #
  # RGB
  #
  if($_=~/^RGB=DYNAMIC/) {
   $rgb=$1             if($rgb eq "" && /^RGB=DYNAMIC\|\|(.*)/);
   $rgb=$rgb_default   if($rgb eq "");
   $_="RGB=$rgb\n";
  } 
  if($_=~/^RGB=(.*)/) {
   $rgb=$rgb_default if($rgb eq "");
   @num_lut=split(",",$1);
   for(@num_lut) { return &error() if(/[^0-9]/); }
   $lut=&lut($1);
   @num_lut=split(",",$lut);
   for(@num_lut) { return &error() if(/[^0-9]/); }
   $str.="RGB=$lut\n";
   next;
  }
  #
  # DEFAULT
  #
  $str.=$_;
 }
 #
 # Write definitive pattern
 #
 $bits=$bits_default if($bits eq "");
 $str.="FRAME=$frame_default\n"  if($str !~/\n^FRAME=/m);
 open(PATTERN,">$command_file.tmp");
 print PATTERN "PATTERN_NAME=$pattern\n" if($str !~/^PATTERN_NAME=/m);
 print PATTERN "BITS=$bits\n"   if($str !~/\n^BITS=/m);
 print PATTERN $str;
 close(PATTERN);
 rename("$command_file.tmp","$command_file");
 &load_new_pattern_file("$requested_by");
 unlink("$var_dir/running/$pattern.tmp") if(-f "$var_dir/running/$pattern.tmp");
 #
 # Stats and Return
 #
 &stats("patterns",1);
 return $ok_response;
}

###############################################
#               Pattern Pos                   #
###############################################
sub get_position (@) {
 my $dim = shift;
 my $type = shift;
 my $pos = shift;
 my $scaling_disabled=shift;
 my ($w,$h)=split(",",$dim);
 my ($x,$y,$d_x,$d_y)=split(",",$pos);
 $d_x=0 if($w == $w_s);
 $d_y=0 if($h == $h_s);
 if($type eq "RECTANGLE") {
  $x=($w_s-$w)/2 if($x == -1);
  $y=($h_s-$h)/2 if($y == -1);
 }
 if($type eq "CIRCLE") {
  $x=$w_s/2 if($x == -1 && $w != $w_s);
  $y=$h_s/2 if($y == -1 && $h != $h_s);
 }
 if($type eq "TRIANGLE") {
  $x=$w_s/2 if($x == -1 && $w != $w_s);;
  $y=$h_s/2 if($y == -1 && $h != $h_s);;
 }
 $x=int($x+$d_x);
 $y=int($y+$d_y);
 $x=&round_val($x*($w_s/$max_x)) if(!$scaling_disabled && (split(",",$pos))[0] != "-1");
 $y=&round_val($y*($h_s/$max_y)) if(!$scaling_disabled && (split(",",$pos))[1] != "-1");
 return "$x,$y";
}

###############################################
#              Replace String                 #
###############################################
sub replace_string (@) {
 my $string = shift;
 my $rgb = shift;
 my $date = localtime(time);
 my $eth_interface=&get_ip("$eth_interface");
 $string=~s/\$RGB/$rgb/g;
 $string=~s/\$DATE/$date/g;
 $string=~s/\$ETH_INTERFACE/$eth_interface/g;
 return $string;
}

###############################################
#                    Lut                      #
###############################################
sub lut (@) {
 my $rgb = shift;
 ($r,$g,$b)=split(",",$rgb);
 $file=$lut_file;
 return if($file eq "" || !-f $file);
 open(LUT,$file);
 while(<LUT>) {
  next if($_=~/^#/);
  if($_=~/^($r|ALL),($g|ALL),($b|ALL)=(.*)/ || $_=~/.*ALL.*=(.*)/) {
   ($r_d,$g_d,$b_d)=split(",",$4);
   $r=$r+$r_d;
   $g=$g+$g_d;
   $b=$b+$b_d;
   last;
  }
 }
 close(LUT);
 return "$r,$g,$b";
}

return 1;

###############################################
#             Create File Pattern             #
###############################################
sub create_tmp_file(@) {
 my $pattern_string = shift;
 open(FILE,">$command_file.tmp");
 print FILE $pattern_string;
 close(FILE);
 rename("$command_file.tmp","$command_file");
}

###############################################
#           Clean Pattern Files               #
###############################################
sub clean_pattern_files (@) {
 &remove_files("$var_dir/tmp","\.jpg\$");
 &remove_files("$var_dir/tmp","\.png\$");
 &remove_files("$var_dir/running","\.jpg\$");
 &remove_files("$var_dir/running","\.png\$");
 &remove_files("$var_dir/running","\.save\$");
 &remove_files("$var_dir/frames",".*");
}

###############################################
#               Round Function                #
###############################################
sub round_val (@) {
 my $value = shift;
 return int($value+0.5);
}

return 1;
