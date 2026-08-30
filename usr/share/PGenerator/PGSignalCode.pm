package PGSignalCode;

use strict;
use warnings;
use Exporter qw(import);
use Scalar::Util qw(looks_like_number);
use PGMath qw(pq_encode_normalized);

our @EXPORT_OK=qw(
 code_to_signal_fraction signal_code_policy signal_percent_to_code
);

my %HDR20_8_LIMITED=(
 "1.4"=>19,"2"=>20,"2.7"=>22,"4"=>25,"5"=>27,"7"=>31,
 "10"=>38,"15"=>49,"20"=>60,"25"=>71,"30"=>82,"35"=>93,
 "40"=>104,"45"=>115,"50"=>126,"60"=>147,"70"=>169,
 "80"=>191,"90"=>213,"100"=>235,
);
my %HDR20_8_FULL=(
 "1.4"=>4,"2"=>5,"2.7"=>7,"4"=>10,"5"=>13,"7"=>18,
 "10"=>26,"15"=>38,"20"=>51,"25"=>64,"30"=>77,"35"=>89,
 "40"=>102,"45"=>115,"50"=>128,"60"=>153,"70"=>179,
 "80"=>204,"90"=>230,"100"=>255,
);
my %HDR20_10_LIMITED=(
 "1.4"=>76,"2"=>80,"2.7"=>88,"4"=>100,"5"=>108,"7"=>124,
 "10"=>152,"15"=>196,"20"=>240,"25"=>284,"30"=>328,
 "35"=>372,"40"=>416,"45"=>460,"50"=>504,"60"=>588,
 "70"=>676,"80"=>764,"90"=>852,"100"=>940,
);
my %HDR20_10_FULL=(
 "1.4"=>14,"2"=>20,"2.7"=>28,"4"=>41,"5"=>51,"7"=>72,
 "10"=>102,"15"=>153,"20"=>205,"25"=>256,"30"=>307,
 "35"=>358,"40"=>409,"45"=>460,"50"=>512,"60"=>614,
 "70"=>716,"80"=>818,"90"=>921,"100"=>1023,
);

sub _finite_number {
 my ($value)=@_;
 return undef if(!defined($value) || ref($value) || !looks_like_number($value));
 my $number=$value+0;
 return undef if($number != $number
  || $number > 1.7976931348623157e308
  || $number < -1.7976931348623157e308);
 return $number;
}

sub _positive_half_up {
 return int($_[0]+0.5);
}

sub _range_name {
 my ($value,$fallback)=@_;
 return $fallback if(!defined($value) || $value eq "");
 my $name=lc("$value");
 return "limited" if($name eq "limited" || $name eq "legal" || $name eq "1");
 return "full" if($name eq "full" || $name eq "0" || $name eq "2");
 return undef;
}

sub _readonly_hash {
 my ($record)=@_;
 Internals::SvREADONLY($record->{$_},1) for keys %{$record};
 Internals::SvREADONLY(%{$record},1);
 return $record;
}

sub _readonly_table_clone {
 my ($source)=@_;
 return undef if(ref($source) ne "HASH");
 my %copy;
 foreach my $key (keys %{$source}) {
  my $stimulus=_finite_number($key);
  my $code=_finite_number($source->{$key});
  return undef if(!defined($stimulus) || !defined($code) || $code < 0);
  $copy{"$key"}=int($code);
 }
 return _readonly_hash(\%copy);
}

sub signal_code_policy {
 my ($input)=@_;
 return undef if(ref($input) ne "HASH");
 my $mode=lc($input->{signal_mode}||"sdr");
 $mode="hdr10" if($mode eq "hdr");
 return undef if($mode ne "sdr" && $mode ne "hdr10"
  && $mode ne "hlg" && $mode ne "dv");
 my $pattern_range=_range_name($input->{pattern_range},
  _range_name($input->{signal_range},"full"));
 return undef if(!defined($pattern_range));
 my $transport_range=_range_name($input->{transport_range},$pattern_range);
 return undef if(!defined($transport_range));

 my @strategies=grep { $input->{$_} } qw(
  two_point_ycbcr_headroom autocal_26_codes hdr20_codes dv_series
  extended_sdr_codes legal_sdr_ddc_codes pq_luminance_percent
 );
 return undef if(@strategies > 1);
 my $strategy=@strategies ? $strategies[0] : "standard";
 return undef if($strategy eq "dv_series" && $mode ne "dv");
 return undef if($strategy ne "hdr20_codes" && defined($input->{active_table}));

 my $requested_bits;
 if(defined($input->{max_bpc}) && $input->{max_bpc} ne "") {
  my $numeric=_finite_number($input->{max_bpc});
  return undef if(!defined($numeric) || int($numeric)!=$numeric
   || ($numeric != 8 && $numeric != 10 && $numeric != 12));
  $requested_bits=int($numeric);
 }
 my $bits;
 if($strategy eq "dv_series") {
  my $dv_bits=defined($input->{dv_series_code_bits})
   ? _finite_number($input->{dv_series_code_bits}) : 8;
  return undef if(!defined($dv_bits) || int($dv_bits)!=$dv_bits
   || ($dv_bits != 8 && $dv_bits != 10 && $dv_bits != 12));
  $bits=int($dv_bits);
 } elsif($strategy eq "hdr20_codes" || $strategy eq "autocal_26_codes") {
  $bits=(defined($requested_bits) && $requested_bits==8) ? 8 : 10;
 } else {
  # Preserve the established non-DV policy: 12-bit links use native 10-bit
  # calibration codes, while input_max makes that domain explicit.
  $bits=(defined($requested_bits) && $requested_bits>=10) ? 10 : 8;
 }
 my $input_max=$bits==12 ? 4095 : ($bits==10 ? 1023 : 255);
 my $limited=$pattern_range eq "limited" ? 1 : 0;
 my $legal_min=$limited ? ($bits==12 ? 256 : ($bits==10 ? 64 : 16)) : 0;
 my $nominal_white=$limited
  ? ($bits==12 ? 3760 : ($bits==10 ? 940 : 235)) : $input_max;
 my $physical_max=$input_max;
 my $allows_headroom=0;
 my $maximum_stimulus=100;
 my $percent_domain="container_signal_percent";
 my $tunnel_mode="none";
 my $active_table;

 if($strategy eq "two_point_ycbcr_headroom") {
  return undef if(!$limited);
  $allows_headroom=1;
  $maximum_stimulus=109;
  $percent_domain="nominal_ire_percent";
 } elsif($strategy eq "autocal_26_codes") {
  my $format=defined($input->{color_format}) ? int($input->{color_format}) : 0;
  return undef if($format<0 || $format>2);
  my $ycbcr=($format==1 || $format==2) ? 1 : 0;
  $allows_headroom=($limited && $ycbcr) ? 1 : 0;
  $maximum_stimulus=$allows_headroom ? 109 : 100;
  $percent_domain="nominal_ire_percent";
 } elsif($strategy eq "hdr20_codes") {
  return undef if($mode ne "hdr10");
  $percent_domain="container_signal_percent";
  if(defined($input->{active_table})) {
   $active_table=_readonly_table_clone($input->{active_table});
   return undef if(!defined($active_table));
  } elsif($bits==8) {
   $active_table=_readonly_table_clone(
    ($input->{hdr20_use_limited} && $input->{hdr20_full})
     ? \%HDR20_8_FULL : \%HDR20_8_LIMITED);
  } else {
   $active_table=_readonly_table_clone(
    ($input->{hdr20_use_limited} && $input->{hdr20_full})
     ? \%HDR20_10_FULL : \%HDR20_10_LIMITED);
  }
 } elsif($strategy eq "dv_series") {
  my $full=$input->{dv_series_full_range} ? 1 : 0;
  $pattern_range=$full ? "full" : "limited";
  $limited=$full ? 0 : 1;
  $legal_min=$limited ? ($bits==12 ? 256 : ($bits==10 ? 64 : 16)) : 0;
  $nominal_white=$limited
   ? ($bits==12 ? 3760 : ($bits==10 ? 940 : 235)) : $input_max;
  my $interface=lc($input->{dv_interface}||"standard");
  $interface="standard" if($interface eq "0");
  $interface="low_latency" if($interface eq "1" || $interface eq "ll");
  return undef if($interface ne "standard" && $interface ne "low_latency");
  $tunnel_mode="dolby_vision_".$interface;
  $percent_domain="dolby_vision_tunnel_signal_percent";
 } elsif($strategy eq "extended_sdr_codes") {
  return undef if($mode ne "sdr");
  $legal_min=$bits==10 ? 64 : 16;
  $nominal_white=$input_max;
  $percent_domain="nominal_ire_percent";
 } elsif($strategy eq "legal_sdr_ddc_codes") {
  return undef if($mode ne "sdr");
  $percent_domain="nominal_ire_percent";
 } elsif($strategy eq "pq_luminance_percent") {
  return undef if($mode ne "hdr10");
  my $peak=_finite_number($input->{signal_peak_nits});
  return undef if(!defined($peak) || $peak<=0 || $peak>10_000);
  $percent_domain="absolute_luminance_fraction_of_peak";
 }

 my $record={
  schema=>"pgen-signal-code-policy-v1",
  policy_version=>1,
  signal_mode=>$mode,
  pattern_range=>$pattern_range,
  transport_range=>$transport_range,
  input_bits=>$bits,
  input_max=>$input_max,
  legal_min=>$legal_min,
  nominal_white_code=>$nominal_white,
  physical_max_code=>$physical_max,
  allows_above_nominal_white=>$allows_headroom,
  maximum_stimulus_percent=>$maximum_stimulus,
  rounding_mode=>"positive_half_up",
  tunnel_mode=>$tunnel_mode,
  percent_domain=>$percent_domain,
  strategy=>$strategy,
  color_format=>(defined($input->{color_format}) ? int($input->{color_format}) : 0),
  hdr20_use_limited=>($input->{hdr20_use_limited} ? 1 : 0),
  hdr20_full=>($input->{hdr20_full} ? 1 : 0),
  signal_peak_nits=>(defined($input->{signal_peak_nits})
   ? ($input->{signal_peak_nits}+0) : 0),
  active_table=>$active_table,
 };
 return _readonly_hash($record);
}

sub _clamp {
 my ($value,$minimum,$maximum)=@_;
 return $minimum if($value<$minimum);
 return $maximum if($value>$maximum);
 return $value;
}

sub signal_percent_to_code {
 my ($policy,$stimulus)=@_;
 return undef if(ref($policy) ne "HASH"
  || ($policy->{schema}||"") ne "pgen-signal-code-policy-v1");
 $stimulus=_finite_number($stimulus);
 return undef if(!defined($stimulus));
 my $strategy=$policy->{strategy};
 my $bits=$policy->{input_bits};
 my $limited=$policy->{pattern_range} eq "limited" ? 1 : 0;
 my $input_max=$policy->{input_max};
 my $code=0;

 if($strategy eq "two_point_ycbcr_headroom") {
  my $value=_clamp($stimulus,0,109);
  if($value<=100) {
   $code=_positive_half_up($policy->{legal_min}
    + $value/100*($policy->{nominal_white_code}-$policy->{legal_min}));
  } else {
   $code=_positive_half_up($policy->{nominal_white_code}
    + ($value-100)/9*($input_max-$policy->{nominal_white_code}));
  }
  $code=_clamp($code,$policy->{legal_min},$input_max);
 } elsif($strategy eq "autocal_26_codes") {
  my $value=$stimulus;
  my $ycbcr=($policy->{color_format}==1 || $policy->{color_format}==2) ? 1 : 0;
  if($bits==8) {
   if($limited) {
    if($ycbcr) {
     $value=_clamp($value,0,109);
     $code=$value<=100
      ? _positive_half_up(16+$value/100*219)
      : _positive_half_up(235+($value-100)/9*20);
     $code=_clamp($code,16,255);
    } else {
     $value=_clamp($value,0,100);
     $code=_clamp(_positive_half_up(16+$value/100*219),16,235);
    }
   } else {
    $value=_clamp($value,0,100);
    $code=_clamp(_positive_half_up($value/100*255),0,255);
   }
  } elsif(!$limited) {
   $value=_clamp($value,0,100);
   $code=$value>=99.95 ? 1023
    : (_clamp(_positive_half_up($value/100*255),0,255) << 2);
  } else {
   $value=_clamp($value,0,$ycbcr ? 109 : 100);
   $code=($ycbcr && $value>100)
    ? _positive_half_up(940+($value-100)/9*83)
    : _positive_half_up(64+$value/100*876);
   $code=_clamp($code,64,$ycbcr ? 1023 : 940);
  }
 } elsif($strategy eq "hdr20_codes") {
  my $value=_clamp($stimulus,0,100);
  my $table=$policy->{active_table};
  my $slot_key="";
  foreach my $slot (keys %HDR20_8_LIMITED) {
   if(abs(($slot+0)-$value)<0.01) { $slot_key=$slot; last; }
  }
  my $minimum=($bits==10 && $policy->{hdr20_use_limited}
   && $policy->{hdr20_full}) ? 0 : ($bits==8 ? 0 : 64);
  my $span=$bits==10
   ? (($policy->{hdr20_use_limited} && $policy->{hdr20_full}) ? 1023 : 876)
   : 255;
  $code=exists($table->{$slot_key}) ? $table->{$slot_key}
   : _positive_half_up($minimum+$value/100*$span);
  $code=_clamp($code,$minimum,$minimum+$span);
 } elsif($strategy eq "dv_series") {
  my $value=_clamp($stimulus,0,100)/100;
  my $minimum=$limited ? ($bits==12 ? 256 : ($bits==10 ? 64 : 16)) : 0;
  my $span=$limited ? ($bits==12 ? 3504 : ($bits==10 ? 876 : 219)) : $input_max;
  $code=_clamp(_positive_half_up($minimum+$value*$span),$minimum,$minimum+$span);
 } elsif($strategy eq "pq_luminance_percent") {
  my $value=_clamp($stimulus,0,100);
  $code=_positive_half_up(pq_encode_normalized(
   $value/100*$policy->{signal_peak_nits})*$input_max);
  $code=_clamp($code,0,$input_max);
 } else {
  my $value=_clamp($stimulus,0,100);
  if($strategy eq "extended_sdr_codes") {
   $code=$value<=0 ? 0 : _positive_half_up(
    ($bits==10 ? 64 : 16)+$value/100*($bits==10 ? 959 : 239));
  } elsif($strategy eq "legal_sdr_ddc_codes") {
   $code=$value<=0 ? 0 : _positive_half_up(
    ($bits==10 ? 64 : 16)+$value/100*($bits==10 ? 876 : 219));
  } else {
   my $minimum=$limited ? ($bits==10 ? 64 : 16) : 0;
   my $span=$limited ? ($bits==10 ? 876 : 219) : $input_max;
   $code=_positive_half_up($minimum+$value/100*$span);
  }
  $code=_clamp($code,0,$input_max);
 }
 return {code=>int($code),input_max=>int($input_max)};
}

sub code_to_signal_fraction {
 my ($policy,$code)=@_;
 return undef if(ref($policy) ne "HASH"
  || ($policy->{schema}||"") ne "pgen-signal-code-policy-v1");
 $code=_finite_number($code);
 return undef if(!defined($code) || !$policy->{input_max});
 $code=_clamp($code,0,$policy->{physical_max_code});
 return $code/$policy->{input_max}
  if($policy->{strategy} eq "pq_luminance_percent");
 return 0 if($code <= $policy->{legal_min});
 my $nominal_span=$policy->{nominal_white_code}-$policy->{legal_min};
 return undef if($nominal_span <= 0);
 if($code <= $policy->{nominal_white_code}) {
  return ($code-$policy->{legal_min})/$nominal_span;
 }
 return 1 if(!$policy->{allows_above_nominal_white});
 my $headroom_span=$policy->{physical_max_code}
  -$policy->{nominal_white_code};
 return 1 if($headroom_span <= 0);
 return 1+(($code-$policy->{nominal_white_code})/$headroom_span)
  *(($policy->{maximum_stimulus_percent}-100)/100);
}

1;
