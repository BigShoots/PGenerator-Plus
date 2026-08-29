package PGCalibrationMath;

use strict;
use warnings;
use Exporter qw(import);
use Scalar::Util qw(looks_like_number);
use PGMath qw(matrix3_inverse matrix3_vector_multiply);

our @EXPORT_OK = qw(
 bounded_number
 calibration_rgb_to_xyz_matrix
 autocal_xy_to_xyz_unit
 dpg_smooth_blend_index
 finite_number
 gamut_xy_definition
 named_gamut_matrix
 smooth_dpg_low_end
 standard_gamut_record
 standard_gamut_records
);

# The string coefficients are intentional. webui.pm assembles them directly
# into JavaScript, so preserving their spelling also preserves the page bytes.
my $STANDARD_GAMUTS={
 bt709=>{
  label=>'BT.709 / D65',
  WHITE=>['0.3127','0.3290'],
  PRIMARIES=>{R=>['0.64','0.33'],G=>['0.30','0.60'],B=>['0.15','0.06']},
  M=>[['3.2404548360','-1.5371388501','-0.4985315469'],['-0.9692663899','1.8760109288','0.0415560823'],['0.0556434196','-0.2040258543','1.0572251625']],
  RGB_TO_XYZ=>[['0.4124564','0.3575761','0.1804375'],['0.2126729','0.7151522','0.0721750'],['0.0193339','0.1191920','0.9503041']],
 },
 bt2020=>{
  label=>'BT.2020 / D65',
  WHITE=>['0.3127','0.3290'],
  PRIMARIES=>{R=>['0.708','0.292'],G=>['0.170','0.797'],B=>['0.131','0.046']},
  M=>[['1.7166511880','-0.3556707838','-0.2533662814'],['-0.6666843518','1.6164812366','0.0157685458'],['0.0176398574','-0.0427706133','0.9421031212']],
  RGB_TO_XYZ=>[['0.6369580483','0.1446169036','0.1688809752'],['0.2627002120','0.6779980715','0.0593017165'],['0.0000000000','0.0280726930','1.0609850577']],
 },
 p3d65=>{
  label=>'P3 / D65',
  WHITE=>['0.3127','0.3290'],
  PRIMARIES=>{R=>['0.680','0.320'],G=>['0.265','0.690'],B=>['0.150','0.060']},
  M=>[['2.4934969119','-0.9313836179','-0.4027107845'],['-0.8294889696','1.7626640603','0.0236246858'],['0.0358458302','-0.0761723893','0.9568845240']],
  RGB_TO_XYZ=>[['0.4865709486','0.2656676932','0.1982172852'],['0.2289745641','0.6917385218','0.0792869141'],['0.0000000000','0.0451133819','1.0439443689']],
 },
 p3dci=>{
  label=>'P3 / DCI',
  WHITE=>['0.3140','0.3510'],
  PRIMARIES=>{R=>['0.680','0.320'],G=>['0.265','0.690'],B=>['0.150','0.060']},
  M=>[['2.7253940305','-1.0180030062','-0.4401631952'],['-0.7951680258','1.6897320548','0.0226471906'],['0.0412418914','-0.0876390192','1.1009293786']],
  RGB_TO_XYZ=>[['0.4451698156','0.2771344092','0.1722826698'],['0.2094916779','0.7215952542','0.0689130679'],['0.0000000000','0.0470605601','0.9073553944']],
 },
};

sub _clone_record {
 my ($value)=@_;
 return [map { _clone_record($_) } @{$value}] if(ref($value) eq "ARRAY");
 return {map { $_=>_clone_record($value->{$_}) } keys %{$value}}
  if(ref($value) eq "HASH");
 return $value;
}

sub standard_gamut_record {
 my ($name)=@_;
 $name=lc($name||"");
 return undef if(!exists($STANDARD_GAMUTS->{$name}));
 return _clone_record($STANDARD_GAMUTS->{$name});
}

sub standard_gamut_records {
 return _clone_record($STANDARD_GAMUTS);
}

sub gamut_xy_definition {
 my ($name)=@_;
 my $record=standard_gamut_record($name);
 return undef if(!$record);
 return {
  red=>[map { $_+0 } @{$record->{"PRIMARIES"}{"R"}}],
  green=>[map { $_+0 } @{$record->{"PRIMARIES"}{"G"}}],
  blue=>[map { $_+0 } @{$record->{"PRIMARIES"}{"B"}}],
  white=>[map { $_+0 } @{$record->{"WHITE"}}],
 };
}

sub autocal_xy_to_xyz_unit {
 my ($x,$y)=@_;
 $y=1 if(!defined($y) || $y <= 0);
 return [$x/$y,1,(1-$x-$y)/$y];
}

sub _matrix_policy {
 my ($contract)=@_;
 $contract||="autocal3d";
 return {
  inverse_variant=>"direct_cofactor_division", tolerance=>0,
  singular_fallback=>"none",
 } if($contract eq "dolby_vision_profile");
 return {
  inverse_variant=>"reciprocal_reduction", tolerance=>1e-12,
  singular_fallback=>"undef",
 } if($contract eq "spotread_sim");
 return {
  inverse_variant=>"reciprocal_reduction", tolerance=>1e-12,
  singular_fallback=>"unit_scale",
 } if($contract eq "autocal3d");
 return undef;
}

sub _xy_unit {
 my ($xy)=@_;
 return undef if(ref($xy) ne "ARRAY" || @{$xy} != 2);
 my $x=bounded_number($xy->[0],0,1);
 my $y=bounded_number($xy->[1],0,1);
 return undef if(!defined($x) || !defined($y) || $y <= 0);
 return [$x/$y,1,(1-$x-$y)/$y];
}

sub _matrix_cache_key {
 my ($definition,$policy)=@_;
 my @values;
 for my $name (qw(red green blue white)) {
  push @values,map { sprintf("%.17g",$_+0) } @{$definition->{$name}};
 }
 return join("|","matrix_source=derived","coefficient_precision=binary64-v1",
  "inverse_variant=$policy->{inverse_variant}",
  "tolerance=".sprintf("%.17g",$policy->{tolerance}),
  "singular_fallback=$policy->{singular_fallback}",@values);
}

sub calibration_rgb_to_xyz_matrix {
 my ($definition,%options)=@_;
 return undef if(ref($definition) ne "HASH");
 my $policy=_matrix_policy($options{"caller_contract"});
 return undef if(!$policy);
 my %unit;
 for my $name (qw(red green blue white)) {
  $unit{$name}=_xy_unit($definition->{$name});
  return undef if(!$unit{$name});
 }
 my $canonical={map {
  $_=>[map { $_+0 } @{$definition->{$_}}]
 } qw(red green blue white)};
 my $cache_key=_matrix_cache_key($canonical,$policy);
 my $cache=$options{"context_cache"};
 return $cache->{$cache_key}
  if(ref($cache) eq "HASH" && exists($cache->{$cache_key}));

 my $base=[
  [$unit{"red"}[0],$unit{"green"}[0],$unit{"blue"}[0]],
  [1,1,1],
  [$unit{"red"}[2],$unit{"green"}[2],$unit{"blue"}[2]],
 ];
 my $direct=$policy->{"inverse_variant"} eq "direct_cofactor_division" ? 1 : 0;
 my $inverse=matrix3_inverse($base,$policy->{"tolerance"},$direct);
 my $scale;
 if($inverse) {
  $scale=matrix3_vector_multiply($inverse,$unit{"white"});
 } elsif($policy->{"singular_fallback"} eq "unit_scale") {
  $scale=[1,1,1];
 } else {
  return undef;
 }
 my $matrix=[
  [$base->[0][0]*$scale->[0],$base->[0][1]*$scale->[1],$base->[0][2]*$scale->[2]],
  [$scale->[0],$scale->[1],$scale->[2]],
  [$base->[2][0]*$scale->[0],$base->[2][1]*$scale->[1],$base->[2][2]*$scale->[2]],
 ];
 $cache->{$cache_key}=$matrix if(ref($cache) eq "HASH");
 return $matrix;
}

my %NAMED_DERIVED_MATRIX_CACHE;
my %NAMED_PRECOMPUTED_MATRIX_CACHE;

sub named_gamut_matrix {
 my ($name,%options)=@_;
 $name=lc($name||"");
 return undef if(!exists($STANDARD_GAMUTS->{$name}));
 my $source=$options{"matrix_source"}||"precomputed";
 if($source eq "precomputed") {
  my $version=$options{"coefficient_version"}||"webui-v1";
  return undef if($version ne "webui-v1");
  my $key=join("|",$name,"precomputed",$version);
  if(!exists($NAMED_PRECOMPUTED_MATRIX_CACHE{$key})) {
   $NAMED_PRECOMPUTED_MATRIX_CACHE{$key}=[map {
    [map { $_+0 } @{$_}]
   } @{$STANDARD_GAMUTS->{$name}{"RGB_TO_XYZ"}}];
  }
  return $NAMED_PRECOMPUTED_MATRIX_CACHE{$key};
 }
 return undef if($source ne "derived");
 my $contract=$options{"caller_contract"}||"autocal3d";
 my $key=join("|",$name,"derived","binary64-v1",$contract);
 if(!exists($NAMED_DERIVED_MATRIX_CACHE{$key})) {
  $NAMED_DERIVED_MATRIX_CACHE{$key}=calibration_rgb_to_xyz_matrix(
   gamut_xy_definition($name),caller_contract=>$contract);
 }
 return $NAMED_DERIVED_MATRIX_CACHE{$key};
}

# Perl 5.20 on the Pi does not export POSIX::isfinite. Keep the runtime-local
# finite check here and make every domain owner add its own meaningful bounds.
sub finite_number {
 my ($value)=@_;
 return undef if(!defined($value) || ref($value));
 return undef if(!looks_like_number($value));
 my $number;
 {
  no warnings qw(numeric overflow);
  $number=$value+0;
 }
 return undef if($number != $number);
 return undef if(abs($number) > 1e308);
 return $number;
}

sub bounded_number {
 my ($value,$minimum,$maximum)=@_;
 my $number=finite_number($value);
 return undef if(!defined($number));
 return undef if(defined($minimum) && $number < $minimum);
 return undef if(defined($maximum) && $number > $maximum);
 return $number;
}

sub dpg_smooth_blend_index { return 280; }

# Exact low-end DPG smoother shared by standalone greyscale and full 3D
# AutoCal. The arithmetic and evaluation order are pinned by
# t/calibration_math.t; optimize only behind a new byte-parity benchmark.
sub smooth_dpg_low_end {
 my ($dpg)=@_;
 return ($dpg,0) if(ref($dpg) ne "ARRAY" || @{$dpg} != 3072);
 my $full=240;
 my $blend=dpg_smooth_blend_index();
 my $half=2;
 my @out;
 my $changed=0;
 foreach my $c (0,1,2) {
  my @ch=@{$dpg}[($c*1024)..($c*1024+1023)];
  my @sm=@ch;
  foreach my $pass (1,2) {
   my @prev=@sm;
   for(my $i=1;$i<=$blend+$half;$i++) {
    last if($i > 1023);
    my $lo=$i-$half; $lo=0 if($lo < 0);
    my $hi=$i+$half; $hi=1023 if($hi > 1023);
    my $sum=0;
    for(my $j=$lo;$j<=$hi;$j++) { $sum+=$prev[$j]; }
    $sm[$i]=$sum/($hi-$lo+1);
   }
  }
  my @res=@ch;
  for(my $i=1;$i<=1023;$i++) {
   my $w=0;
   if($i <= $full) { $w=1; }
   elsif($i <= $blend) { $w=($blend-$i)/($blend-$full); }
   next if($w <= 0);
   $res[$i]=sprintf("%.0f",$ch[$i]+($sm[$i]-$ch[$i])*$w)+0;
  }
  $res[0]=$ch[0];
  for(my $i=1;$i<=1023;$i++) {
   $res[$i]=$res[$i-1] if($res[$i] < $res[$i-1]);
   $res[$i]=0 if($res[$i] < 0);
   $res[$i]=65535 if($res[$i] > 65535);
   $changed++ if($res[$i] != $ch[$i]);
  }
  push @out,@res;
 }
 return (\@out,$changed);
}

1;
