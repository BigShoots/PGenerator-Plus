package PGCalibrationMath;

use strict;
use warnings;
use Exporter qw(import);
use Scalar::Util qw(looks_like_number);
# Resolve sibling modules relative to this file so the module compiles from
# any checkout (perl -c, deploy tooling), not only when /usr/share/PGenerator
# is already on @INC.
use File::Basename ();
use lib File::Basename::dirname(__FILE__);
use PGMath qw(
 bt1886_luminance_1d_ab bt1886_relative_luminance_3d_root_blend
 matrix3_inverse matrix3_vector_multiply pq_decode_nits pq_decode_normalized
);

our @EXPORT_OK = qw(
 bounded_number
 calibration_target_context
 calibration_rgb_to_xyz_matrix
 autocal_xy_to_xyz_unit
 dpg_smooth_blend_index
 effective_de_limits_for_ire
 finite_number
 gamut_xy_definition
 named_gamut_matrix
 saturation_stimulus_for_gamuts
 smooth_dpg_low_end
 standard_gamut_record
 standard_gamut_records
 target_linear_for_context
 target_luminance_for_context
 target_relative_luminance_for_context
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

sub _lock_flat_hashref {
 my ($record)=@_;
 return undef if(ref($record) ne "HASH");
 Internals::SvREADONLY($record->{$_},1) for keys %{$record};
 Internals::SvREADONLY(%{$record},1);
 return $record;
}

sub effective_de_limits_for_ire {
 my ($input)=@_;
 return undef if(ref($input) ne "HASH");
 my $ire=finite_number($input->{"ire"});
 my $target=bounded_number($input->{"target_delta_e"},0,1_000_000);
 my $skip_fraction=bounded_number($input->{"skip_fraction"},0,1);
 my $low_threshold=bounded_number(
  $input->{"low_ire_threshold"},0,1_000_000);
 my $very_low_threshold=bounded_number(
  $input->{"very_low_ire_threshold"},0,1_000_000);
 my $low_multiplier=bounded_number($input->{"low_multiplier"},0,1_000_000);
 my $very_low_multiplier=bounded_number(
  $input->{"very_low_multiplier"},0,1_000_000);
 return undef if(!defined($ire) || !defined($target) || $target <= 0
  || !defined($skip_fraction) || !defined($low_threshold)
  || !defined($very_low_threshold) || $very_low_threshold > $low_threshold
  || !defined($low_multiplier) || $low_multiplier <= 0
  || !defined($very_low_multiplier) || $very_low_multiplier <= 0);
 my $policy=$input->{"threshold_policy"}||"";
 return undef if($policy ne "inclusive" && $policy ne "exclusive");
 my $very_low=($policy eq "inclusive")
  ? ($ire <= $very_low_threshold) : ($ire < $very_low_threshold);
 my $low=($policy eq "inclusive")
  ? ($ire <= $low_threshold) : ($ire < $low_threshold);
 my $tier=$very_low ? "very_low" : ($low ? "low" : "body");
 my $multiplier=$very_low ? $very_low_multiplier : ($low ? $low_multiplier : 1);
 my $effective_target=$target*$multiplier;
 return _lock_flat_hashref({
  target_delta_e=>$effective_target+0,
  skip_delta_e=>($effective_target*$skip_fraction)+0,
  tier=>$tier,
  ire=>$ire+0,
  skip_fraction=>$skip_fraction+0,
  threshold_policy=>$policy,
 });
}

sub calibration_target_context {
 my ($input)=@_;
 return undef if(ref($input) ne "HASH");
 my $caller=lc($input->{"caller_policy"}||"");
 return undef if($caller ne "autocal_1d" && $caller ne "autocal_3d"
  && $caller ne "browser_chart");

 my $mode=lc($input->{"signal_mode"}||"sdr");
 $mode="hdr10" if($mode eq "hdr");
 return undef if($mode ne "sdr" && $mode ne "hdr10"
  && $mode ne "hlg" && $mode ne "dv");

 my $gamma=lc($input->{"target_gamma"}||"bt1886");
 $gamma="bt1886" if($gamma eq "1886");
 $gamma="st2084" if($gamma eq "pq" || $gamma eq "smpte2084");
 return undef if($gamma ne "bt1886" && $gamma ne "2.2"
  && $gamma ne "2.4" && $gamma ne "srgb" && $gamma ne "st2084"
  && $gamma ne "hlg");

 my $peak=defined($input->{"sdr_signal_peak"})
  ? bounded_number($input->{"sdr_signal_peak"},1,1_000_000) : 100;
 return undef if(!defined($peak));

 my $transfer;
 if($caller eq "browser_chart") {
  $transfer="hlg_display" if($mode eq "hlg" || $gamma eq "hlg");
  $transfer="pq_absolute" if(!defined($transfer) && $gamma eq "st2084");
  $transfer="srgb" if(!defined($transfer) && $gamma eq "srgb");
  $transfer="power_2_2" if(!defined($transfer) && $gamma eq "2.2");
  $transfer="bt1886_chart_ab" if(!defined($transfer) && $gamma eq "bt1886");
  $transfer="power_2_4" if(!defined($transfer));
 }
 elsif($caller eq "autocal_1d") {
  $transfer="srgb" if($gamma eq "srgb");
  $transfer="dv_gamma_2_2_tunnel" if($mode eq "dv" && $gamma eq "st2084");
  $transfer="pq_normalized" if(!defined($transfer) && $gamma eq "st2084");
  $transfer="power_2_2" if(!defined($transfer) && $gamma eq "2.2");
  $transfer="bt1886_1d_ab" if(!defined($transfer) && $gamma eq "bt1886");
  $transfer="power_2_4" if(!defined($transfer));
 } else {
  $transfer="bt1886_3d_root_blend_relative" if($gamma eq "bt1886");
  $transfer="srgb" if(!defined($transfer) && $gamma eq "srgb");
  $transfer="pq_normalized" if(!defined($transfer) && $gamma eq "st2084");
  $transfer="power_2_2" if(!defined($transfer) && $gamma eq "2.2");
  $transfer="power_2_4" if(!defined($transfer));
 }

 my $normalization=($caller eq "autocal_3d")
  ? "relative_black_removed"
  : (($caller eq "browser_chart")
     ? (($transfer eq "pq_absolute" || $transfer eq "hlg_display")
        ? "absolute_nits" : "white_scaled")
     : (($mode eq "hdr10" && $gamma eq "st2084")
        ? "absolute_nits_capped_at_white" : "white_scaled"));
 my $context={
  schema=>"pgen-calibration-target-context-v1",
  context_version=>1,
  caller_policy=>$caller,
  signal_mode=>$mode,
  target_gamma=>$gamma,
  sdr_signal_peak=>$peak+0,
  transfer_policy=>$transfer,
  normalization_policy=>$normalization,
  dv_tunnel_policy=>(($mode eq "dv" && $gamma eq "st2084")
   ? "gamma_2_2_when_target_label_st2084" : "none"),
 };
 if($caller eq "browser_chart") {
  my $signal_peak=defined($input->{"signal_peak_nits"})
   ? bounded_number($input->{"signal_peak_nits"},0,10_000)
   : (($mode eq "sdr") ? 100 : 1_000);
  my $white=defined($input->{"white_nits"})
   ? bounded_number($input->{"white_nits"},0,1_000_000) : 0;
  my $black=defined($input->{"black_nits"})
   ? bounded_number($input->{"black_nits"},0,1_000_000) : 0;
  return undef if(!defined($signal_peak) || !defined($white)
   || !defined($black));
  my $pattern_range=lc($input->{"pattern_range"}||"full");
  my $transport_range=lc($input->{"transport_range"}||$pattern_range);
  return undef if(($pattern_range ne "full" && $pattern_range ne "limited")
   || ($transport_range ne "full" && $transport_range ne "limited"));
  my $pattern_bits=defined($input->{"pattern_bits"})
   ? finite_number($input->{"pattern_bits"}) : (($mode eq "dv") ? 12 : 8);
  my $transport_bits=defined($input->{"transport_bits"})
   ? finite_number($input->{"transport_bits"}) : $pattern_bits;
  return undef if(!defined($pattern_bits) || !defined($transport_bits));
  return undef if(($pattern_bits != 8 && $pattern_bits != 10 && $pattern_bits != 12)
   || ($transport_bits != 8 && $transport_bits != 10 && $transport_bits != 12));
  my $headroom=lc($input->{"headroom_strategy"}||"none");
  return undef if($headroom ne "none" && $headroom ne "legal_superwhite"
   && $headroom ne "extended_sdr" && $headroom ne "lg_sdr26_ladder");
  my $headroom_max=defined($input->{"headroom_max_percent"})
   ? bounded_number($input->{"headroom_max_percent"},100,1_000) : 100;
  return undef if(!defined($headroom_max)
   || ($headroom eq "none" && $headroom_max != 100));
  my $dv_map=lc($input->{"dv_map_mode"}||"");
  $dv_map="absolute" if($dv_map eq "1");
  $dv_map="relative" if($dv_map eq "2");
  $dv_map=($mode eq "dv") ? "relative" : "none" if($dv_map eq "");
  return undef if($dv_map ne "none" && $dv_map ne "absolute"
   && $dv_map ne "relative");
  return undef if($mode ne "dv" && $dv_map ne "none");
  my $dv_interface=lc($input->{"dv_interface"}||"");
  $dv_interface="standard" if($dv_interface eq "0");
  $dv_interface="low_latency" if($dv_interface eq "1" || $dv_interface eq "ll");
  $dv_interface=($mode eq "dv") ? "standard" : "none" if($dv_interface eq "");
  return undef if($dv_interface ne "none" && $dv_interface ne "standard"
   && $dv_interface ne "low_latency");
  return undef if($mode ne "dv" && $dv_interface ne "none");
  my $gamma_exponent=($gamma eq "2.2") ? 2.2
   : (($gamma eq "2.4" || $gamma eq "bt1886") ? 2.4 : 0);
  $context->{"gamma_exponent"}=$gamma_exponent+0;
  $context->{"white_nits"}=$white+0;
  $context->{"black_nits"}=$black+0;
  $context->{"signal_peak_nits"}=$signal_peak+0;
  $context->{"pattern_range"}=$pattern_range;
  $context->{"transport_range"}=$transport_range;
  $context->{"pattern_bits"}=$pattern_bits;
  $context->{"transport_bits"}=$transport_bits;
  $context->{"headroom_strategy"}=$headroom;
  $context->{"headroom_max_percent"}=$headroom_max+0;
  $context->{"dv_map_mode"}=$dv_map;
  $context->{"dv_interface"}=$dv_interface;
  $context->{"dv_tunnel_policy"}=($mode eq "dv")
   ? (($dv_map eq "absolute")
      ? "st2084_absolute_map" : "gamma_2_2_relative_map")
   : "none";
  $context->{"target_gamut"}=lc($input->{"target_gamut"}||"auto");
 }
 return _lock_flat_hashref($context);
}

sub _is_target_context {
 my ($context,$caller)=@_;
 return 0 if(ref($context) ne "HASH"
  || ($context->{"schema"}||"") ne "pgen-calibration-target-context-v1"
  || ($context->{"context_version"}||0) != 1);
 return 0 if(defined($caller) && ($context->{"caller_policy"}||"") ne $caller);
 return 1;
}

sub _clamp_target_unit {
 my ($value)=@_;
 return 0 if(!defined($value) || $value < 0);
 return 1 if($value > 1);
 return $value;
}

sub target_linear_for_context {
 my ($context,$signal)=@_;
 return undef if(!_is_target_context($context));
 $signal=0 if(!defined($signal));
 $signal+=0;
 if($context->{"caller_policy"} eq "autocal_3d") {
  $signal=_clamp_target_unit($signal);
 } else {
  $signal=0 if($signal < 0);
  $signal=1 if($signal > 1 && $context->{"signal_mode"} ne "sdr");
  return 0 if($signal <= 0);
 }
 my $policy=$context->{"transfer_policy"};
 return ($signal <= 0.04045) ? ($signal/12.92)
  : ((($signal+0.055)/1.055) ** 2.4) if($policy eq "srgb");
 return $signal ** 2.2 if($policy eq "power_2_2"
  || $policy eq "dv_gamma_2_2_tunnel");
 return pq_decode_normalized($signal) if($policy eq "pq_normalized");
 return $signal ** 2.4;
}

sub target_luminance_for_context {
 my ($context,$stimulus,$white_y,$black_y)=@_;
 return undef if(!_is_target_context($context,"autocal_1d")
  || !defined($stimulus) || !defined($white_y) || $white_y <= 0);
 my $mode=$context->{"signal_mode"};
 my $signal_peak=($mode eq "sdr") ? $context->{"sdr_signal_peak"} : 100;
 my $signal=($stimulus+0)/$signal_peak;
 $signal=1 if($signal > 1 && ($mode ne "sdr" || $signal_peak == 100));
 if($mode eq "sdr" && $context->{"transfer_policy"} eq "bt1886_1d_ab"
  && defined($black_y) && ($black_y+0) > 0) {
  $signal=0 if($signal < 0);
  return bt1886_luminance_1d_ab($signal,$white_y,$black_y+0);
 }
 return 0 if($stimulus <= 0);
 $signal=1 if($signal > 1 && $mode ne "sdr");
 if($mode eq "hdr10" && $context->{"target_gamma"} eq "st2084") {
  my $pq_y=pq_decode_nits($signal);
  return ($pq_y > $white_y) ? $white_y : $pq_y;
 }
 return $white_y*target_linear_for_context($context,$signal);
}

sub target_relative_luminance_for_context {
 my ($context,$signal,$white_y,$black_y)=@_;
 return undef if(!_is_target_context($context,"autocal_3d"));
 return bt1886_relative_luminance_3d_root_blend(
  $signal,$white_y,$black_y)
  if($context->{"transfer_policy"} eq "bt1886_3d_root_blend_relative");
 return target_linear_for_context($context,$signal);
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

sub _finite_matrix3 {
 my ($matrix)=@_;
 return undef if(ref($matrix) ne "ARRAY" || @{$matrix} != 3);
 my @copy;
 for my $row (@{$matrix}) {
  return undef if(ref($row) ne "ARRAY" || @{$row} != 3);
  my @values;
  for my $value (@{$row}) {
   my $number=finite_number($value);
   return undef if(!defined($number));
   push @values,$number;
  }
  push @copy,\@values;
 }
 return \@copy;
}

# Fix a saturation stimulus's luminance ceiling in the selected target gamut,
# then carry that XYZ magnitude into the transport gamut. The caller owns hue
# interpolation, transfer encoding, and signal-mode reference scaling.
sub saturation_stimulus_for_gamuts {
 my ($input)=@_;
 return undef if(ref($input) ne "HASH"
  || ref($input->{chromaticity}) ne "ARRAY"
  || @{$input->{chromaticity}} != 2);
 my $x=bounded_number($input->{chromaticity}[0],0,1);
 my $y=bounded_number($input->{chromaticity}[1],0,1);
 my $level=bounded_number($input->{level},0,1);
 return undef if(!defined($x) || !defined($y) || $y<=0
  || $x+$y>1+1e-12 || !defined($level));
 my $target_matrix=_finite_matrix3($input->{target_xyz_to_rgb});
 my $transport_matrix=_finite_matrix3($input->{transport_xyz_to_rgb});
 return undef if(!$target_matrix || !$transport_matrix);
 my @unit=($x/$y,1,(1-$x-$y)/$y);
 return undef if(grep { !defined(finite_number($_)) } @unit);
 my $axis=matrix3_vector_multiply($target_matrix,\@unit);
 my $axis_max=$axis->[0];
 $axis_max=$axis->[1] if($axis->[1]>$axis_max);
 $axis_max=$axis->[2] if($axis->[2]>$axis_max);
 $axis_max=1e-9 if($axis_max<1e-9);
 my $target_y=$level/$axis_max;
 my $transport=matrix3_vector_multiply($transport_matrix,\@unit);
 my @rgb=map {
  my $value=$_*$target_y;
  $value<0 ? 0 : $value;
 } @{$transport};
 return {rgb=>\@rgb,target_y=>$target_y};
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
