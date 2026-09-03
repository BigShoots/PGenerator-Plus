package PGMath;

use strict;
use warnings;
use Exporter qw(import);

our @EXPORT_OK=qw(
 akima_interpolate
 bradford_adapt_xyz
 bt1886_luminance_1d_ab
 bt1886_relative_luminance_3d_root_blend
 delta_e_2000_lab
 delta_e_2000_xyz
 delta_e_itp_xyz
 matrix3_inverse
 matrix3_multiply
 matrix3_vector_multiply
 pq_constants
 pq_decode_nits
 pq_decode_normalized
 pq_encode_normalized
 xyz_to_ictcp
 xyz_to_lab
);

# Published Bradford cone-response matrices. The inverse coefficients retain
# the precision historically used by the meter reference path.
my $BRADFORD=[
 [0.8951,0.2664,-0.1614],[-0.7502,1.7135,0.0367],[0.0389,-0.0685,1.0296],
];
my $BRADFORD_INVERSE=[
 [0.9869929,-0.1470543,0.1599627],
 [0.4323053,0.5183603,0.0492912],
 [-0.0085287,0.0400428,0.9684867],
];

# SMPTE ST 2084 constants. Keep these in one Perl module so the web server,
# 1D worker, 3D worker, TV process and simulator cannot acquire different
# copies.
#
# c2 and c3 are over 128, NOT over 32. A display specification in circulation
# lists c2=2413/32 and c3=2392/32; both are typos. With them the EOTF ratio is
# essentially constant at ~1.0087 for every input, the local gamma collapses to
# zero and every derived value ends up on a safety clamp. This warning lived
# beside the inline copy the callers used to carry, so it lives here now.
my $PQ_M1=2610/16384;        # 0.1593017578125
my $PQ_M2=2523/32;           # 78.84375
my $PQ_C1=3424/4096;         # 0.8359375
my $PQ_C2=2413/128;          # 18.8515625  (NOT 2413/32=75.40625)
my $PQ_C3=2392/128;          # 18.6875     (NOT 2392/32=74.75)

sub pq_constants {
 return ($PQ_M1,$PQ_M2,$PQ_C1,$PQ_C2,$PQ_C3);
}

# Non-positive input returns exactly 0 here and in the browser's
# pqEncodeNormalized, while pgen_colour_math.py and src/common/pgen_colour_math.h
# evaluate the transfer function and return its true value at zero,
# 7.3095590257839665e-07. That split is deliberate and long-established --
# these callers emit pattern codes where a hard 0 is wanted, the Python and C
# callers fill 16-bit ICC tables where the floor value round-trips -- and each
# language pins its own zero in its own conformance test.
sub pq_encode_normalized {
 my ($nits)=@_;
 $nits=0 if(!defined($nits));
 $nits+=0;
 return 0 if($nits <= 0);
 $nits=10000 if($nits > 10000);
 my $linear=$nits/10000;
 my $powered=$linear ** $PQ_M1;
 return (($PQ_C1+$PQ_C2*$powered)/(1+$PQ_C3*$powered)) ** $PQ_M2;
}

sub pq_decode_normalized {
 my ($signal)=@_;
 $signal=0 if(!defined($signal));
 $signal+=0;
 $signal=0 if($signal < 0);
 $signal=1 if($signal > 1);
 return 0 if($signal <= 0);
 my $powered=$signal ** (1/$PQ_M2);
 my $denominator=$PQ_C2-$PQ_C3*$powered;
 return 0 if($denominator <= 0);
 my $linear=($powered-$PQ_C1)/$denominator;
 $linear=0 if($linear < 0);
 $linear=$linear ** (1/$PQ_M1);
 return 0 if($linear < 0);
 return 1 if($linear > 1);
 return $linear;
}

sub pq_decode_nits {
 return pq_decode_normalized($_[0])*10000;
}

sub xyz_to_ictcp {
 my ($X,$Y,$Z)=@_;
 $X=0 if(!defined($X)); $Y=0 if(!defined($Y)); $Z=0 if(!defined($Z));
 my $R= 1.7166511880*$X -0.3556707838*$Y -0.2533662814*$Z;
 my $G=-0.6666843518*$X +1.6164812366*$Y +0.0157685458*$Z;
 my $B= 0.0176398574*$X -0.0427706133*$Y +0.9421031212*$Z;
 $R=0 if($R < 0); $G=0 if($G < 0); $B=0 if($B < 0);
 my $L=(1688*$R+2146*$G+262*$B)/4096;
 my $M=(683*$R+2951*$G+462*$B)/4096;
 my $S=(99*$R+309*$G+3688*$B)/4096;
 my $Lp=pq_encode_normalized($L);
 my $Mp=pq_encode_normalized($M);
 my $Sp=pq_encode_normalized($S);
 return {
  I=>0.5*$Lp+0.5*$Mp,
  T=>(6610*$Lp-13613*$Mp+7003*$Sp)/4096,
  P=>(17933*$Lp-17390*$Mp-543*$Sp)/4096
 };
}

sub delta_e_itp_xyz {
 my ($X1,$Y1,$Z1,$X2,$Y2,$Z2)=@_;
 return undef if(!defined($X1) || !defined($Y1) || !defined($Z1)
  || !defined($X2) || !defined($Y2) || !defined($Z2));
 my $a=xyz_to_ictcp($X1,$Y1,$Z1);
 my $b=xyz_to_ictcp($X2,$Y2,$Z2);
 my $dI=$a->{"I"}-$b->{"I"};
 my $dT=$a->{"T"}-$b->{"T"};
 my $dP=$a->{"P"}-$b->{"P"};
 return 720*sqrt($dI*$dI+0.25*$dT*$dT+$dP*$dP);
}

# The two AutoCal paths historically used mathematically related BT.1886
# forms with different evaluation order and output domains. Keep both names:
# serialized targets can differ at the last bit, and the 3D form normalizes
# the display black back out while the 1D form returns absolute luminance.
sub bt1886_luminance_1d_ab {
 my ($signal,$white_y,$black_y)=@_;
 return undef if(!defined($signal) || !defined($white_y) || $white_y <= 0);
 $black_y=0 if(!defined($black_y) || $black_y < 0);
 return $white_y * (($signal+0) ** 2.4) if($black_y <= 0);
 return $white_y if($black_y >= $white_y);
 my $gamma=2.4;
 my $white_root=$white_y ** (1/$gamma);
 my $black_root=$black_y ** (1/$gamma);
 my $den=$white_root-$black_root;
 return $white_y * (($signal+0) ** $gamma) if($den <= 0);
 my $a=$den ** $gamma;
 my $b=$black_root/$den;
 my $v=$signal+$b;
 $v=0 if($v < 0);
 return $a * ($v ** $gamma);
}

sub _bt1886_clamp_unit {
 my ($value)=@_;
 $value=0 if(!defined($value));
 return 0 if($value < 0);
 return 1 if($value > 1);
 return $value;
}

sub _bt1886_luminance_3d_root_blend {
 my ($signal,$white_y,$black_y)=@_;
 $signal=_bt1886_clamp_unit($signal);
 $white_y=100 if(!defined($white_y) || $white_y <= 0);
 $black_y=0 if(!defined($black_y) || $black_y < 0);
 $black_y=0 if($black_y >= $white_y);
 my $gamma=2.4;
 return (($white_y ** (1/$gamma) - $black_y ** (1/$gamma))*$signal
  + $black_y ** (1/$gamma)) ** $gamma;
}

sub bt1886_relative_luminance_3d_root_blend {
 my ($signal,$white_y,$black_y)=@_;
 $white_y=100 if(!defined($white_y) || $white_y <= 0);
 $black_y=0 if(!defined($black_y) || $black_y < 0);
 my $range=$white_y-$black_y;
 return _bt1886_clamp_unit($signal) ** 2.4 if($range <= 1e-9);
 return _bt1886_clamp_unit(
  (_bt1886_luminance_3d_root_blend($signal,$white_y,$black_y)-$black_y)
  /$range
 );
}

sub xyz_to_lab {
 my ($xyz,$white,$ratio_policy)=@_;
 return undef if(ref($xyz) ne "ARRAY" || ref($white) ne "ARRAY"
  || @{$xyz} < 3 || @{$white} < 3);
 $ratio_policy||="signed_linear";
 return undef if($ratio_policy ne "signed_linear"
  && $ratio_policy ne "ratio_floor_1e_minus_9");
 my @ratio;
 for my $index (0..2) {
  return undef if(!defined($white->[$index]) || $white->[$index] == 0);
  my $value=($xyz->[$index]||0)/$white->[$index];
  $value=1e-9 if($ratio_policy eq "ratio_floor_1e_minus_9" && $value < 1e-9);
  push @ratio,$value;
 }
 my $f=sub {
  my ($value)=@_;
  my $epsilon=216/24389;
  my $kappa=24389/27;
  return ($value > $epsilon) ? ($value ** (1/3))
   : (($kappa*$value+16)/116);
 };
 my ($fx,$fy,$fz)=map { $f->($_) } @ratio;
 return [116*$fy-16,500*($fx-$fy),200*($fy-$fz)];
}

sub _degrees_to_radians { return $_[0]*4*atan2(1,1)/180; }
sub _radians_to_degrees { return $_[0]*180/(4*atan2(1,1)); }

sub delta_e_2000_lab {
 my ($lab1,$lab2)=@_;
 return undef if(ref($lab1) ne "ARRAY" || ref($lab2) ne "ARRAY"
  || @{$lab1} < 3 || @{$lab2} < 3);
 my ($l1,$a1,$b1)=@{$lab1};
 my ($l2,$a2,$b2)=@{$lab2};
 my $c1=sqrt($a1*$a1+$b1*$b1);
 my $c2=sqrt($a2*$a2+$b2*$b2);
 my $avg_c=($c1+$c2)/2;
 my $avg_c7=$avg_c**7;
 my $g=0.5*(1-sqrt($avg_c7/($avg_c7+25**7)));
 my $a1p=(1+$g)*$a1;
 my $a2p=(1+$g)*$a2;
 my $c1p=sqrt($a1p*$a1p+$b1*$b1);
 my $c2p=sqrt($a2p*$a2p+$b2*$b2);
 my $h1p=($c1p==0) ? 0 : _radians_to_degrees(atan2($b1,$a1p));
 my $h2p=($c2p==0) ? 0 : _radians_to_degrees(atan2($b2,$a2p));
 $h1p+=360 if($h1p < 0);
 $h2p+=360 if($h2p < 0);
 my $dlp=$l2-$l1;
 my $dcp=$c2p-$c1p;
 my $dhp=0;
 if($c1p*$c2p != 0) {
  my $dh=$h2p-$h1p;
  if(abs($dh) <= 180) { $dhp=$dh; }
  elsif($h2p <= $h1p) { $dhp=$dh+360; }
  else { $dhp=$dh-360; }
 }
 my $dhp_term=2*sqrt($c1p*$c2p)*sin(_degrees_to_radians($dhp/2));
 my $avg_lp=($l1+$l2)/2;
 my $avg_cp=($c1p+$c2p)/2;
 my $avg_hp=0;
 if($c1p*$c2p == 0) {
  $avg_hp=$h1p+$h2p;
 } elsif(abs($h1p-$h2p) <= 180) {
  $avg_hp=($h1p+$h2p)/2;
 } elsif($h1p+$h2p < 360) {
  $avg_hp=($h1p+$h2p+360)/2;
 } else {
  $avg_hp=($h1p+$h2p-360)/2;
 }
 my $t=1 - 0.17*cos(_degrees_to_radians($avg_hp-30))
  + 0.24*cos(_degrees_to_radians(2*$avg_hp))
  + 0.32*cos(_degrees_to_radians(3*$avg_hp+6))
  - 0.20*cos(_degrees_to_radians(4*$avg_hp-63));
 my $delta_theta=30*exp(-((($avg_hp-275)/25)**2));
 my $avg_cp7=$avg_cp**7;
 my $rc=2*sqrt($avg_cp7/($avg_cp7+25**7));
 my $sl=1+(0.015*(($avg_lp-50)**2))/sqrt(20+(($avg_lp-50)**2));
 my $sc=1+0.045*$avg_cp;
 my $sh=1+0.015*$avg_cp*$t;
 my $rt=-sin(_degrees_to_radians(2*$delta_theta))*$rc;
 my $v1=$dlp/$sl;
 my $v2=$dcp/$sc;
 my $v3=$dhp_term/$sh;
 return sqrt($v1*$v1+$v2*$v2+$v3*$v3+$rt*$v2*$v3);
}

sub delta_e_2000_xyz {
 my ($xyz1,$xyz2,$white,$ratio_policy)=@_;
 my $lab1=xyz_to_lab($xyz1,$white,$ratio_policy);
 my $lab2=xyz_to_lab($xyz2,$white,$ratio_policy);
 return undef if(!$lab1 || !$lab2);
 return delta_e_2000_lab($lab1,$lab2);
}

sub matrix3_vector_multiply {
 my ($matrix,$vector)=@_;
 return [
  $matrix->[0][0]*$vector->[0]+$matrix->[0][1]*$vector->[1]+$matrix->[0][2]*$vector->[2],
  $matrix->[1][0]*$vector->[0]+$matrix->[1][1]*$vector->[1]+$matrix->[1][2]*$vector->[2],
  $matrix->[2][0]*$vector->[0]+$matrix->[2][1]*$vector->[1]+$matrix->[2][2]*$vector->[2],
 ];
}

sub matrix3_multiply {
 my ($left,$right)=@_;
 my @result;
 for(my $row=0;$row<3;$row++) {
  for(my $column=0;$column<3;$column++) {
   $result[$row][$column]=$left->[$row][0]*$right->[0][$column]
    +$left->[$row][1]*$right->[1][$column]
    +$left->[$row][2]*$right->[2][$column];
  }
 }
 return \@result;
}

sub matrix3_inverse {
 my ($matrix,$tolerance,$direct_division)=@_;
 $tolerance=1e-12 if(!defined($tolerance));
 my $a=$matrix->[0][0]; my $b=$matrix->[0][1]; my $c=$matrix->[0][2];
 my $d=$matrix->[1][0]; my $e=$matrix->[1][1]; my $f=$matrix->[1][2];
 my $g=$matrix->[2][0]; my $h=$matrix->[2][1]; my $i=$matrix->[2][2];
 my $determinant=$a*($e*$i-$f*$h)-$b*($d*$i-$f*$g)+$c*($d*$h-$e*$g);
 return undef if(abs($determinant) < $tolerance);
 if($direct_division) {
  return [
   [($e*$i-$f*$h)/$determinant,($c*$h-$b*$i)/$determinant,($b*$f-$c*$e)/$determinant],
   [($f*$g-$d*$i)/$determinant,($a*$i-$c*$g)/$determinant,($c*$d-$a*$f)/$determinant],
   [($d*$h-$e*$g)/$determinant,($b*$g-$a*$h)/$determinant,($a*$e-$b*$d)/$determinant],
  ];
 }
 my $inverse=1/$determinant;
 return [
  [($e*$i-$f*$h)*$inverse,($c*$h-$b*$i)*$inverse,($b*$f-$c*$e)*$inverse],
  [($f*$g-$d*$i)*$inverse,($a*$i-$c*$g)*$inverse,($c*$d-$a*$f)*$inverse],
  [($d*$h-$e*$g)*$inverse,($b*$g-$a*$h)*$inverse,($a*$e-$b*$d)*$inverse],
 ];
}

sub bradford_adapt_xyz {
 my ($X,$Y,$Z,$from_x,$from_y,$to_x,$to_y)=@_;
 return ($X,$Y,$Z) unless($from_x>0 && $from_y>0 && $to_x>0 && $to_y>0);
 return ($X,$Y,$Z)
  if(abs($from_x-$to_x)<1e-7 && abs($from_y-$to_y)<1e-7);
 my $source_white=[$from_x/$from_y,1,(1-$from_x-$from_y)/$from_y];
 my $destination_white=[$to_x/$to_y,1,(1-$to_x-$to_y)/$to_y];
 my $source_cone=matrix3_vector_multiply($BRADFORD,$source_white);
 my $destination_cone=matrix3_vector_multiply($BRADFORD,$destination_white);
 my $cone=matrix3_vector_multiply($BRADFORD,[$X,$Y,$Z]);
 my $scaled=[
  map {
   $cone->[$_]*($source_cone->[$_]!=0
    ? $destination_cone->[$_]/$source_cone->[$_] : 1)
  } (0..2)
 ];
 return @{matrix3_vector_multiply($BRADFORD_INVERSE,$scaled)};
}

sub akima_interpolate {
 my ($xs_ref,$ys_ref,$min_idx,$max_idx)=@_;
 return [] if(!defined($xs_ref) || ref($xs_ref) ne "ARRAY");
 return [] if(!defined($ys_ref) || ref($ys_ref) ne "ARRAY");
 return [] if(scalar(@$xs_ref) != scalar(@$ys_ref));
 return [] if(scalar(@$xs_ref) < 4);
 $min_idx=$xs_ref->[0] if(!defined($min_idx));
 $max_idx=$xs_ref->[-1] if(!defined($max_idx));
 my @xs=map { 0+$_ } @$xs_ref;
 my @ys=map { 0+$_ } @$ys_ref;
 my $count=scalar(@xs);

 my @slopes;
 for my $index (0..$count-2) {
  my $span=$xs[$index+1]-$xs[$index];
  push @slopes,($span != 0)
   ? ($ys[$index+1]-$ys[$index])/$span : 0;
 }

 my @padded;
 $padded[1]=2*$slopes[0]-$slopes[1];
 $padded[0]=2*$padded[1]-$slopes[0];
 for my $index (0..$count-2) { push @padded,$slopes[$index]; }
 $padded[$count+1]=2*$slopes[$count-2]-$slopes[$count-3];
 $padded[$count+2]=2*$padded[$count+1]-$slopes[$count-2];

 my @derivatives;
 for my $index (0..$count-1) {
  $derivatives[$index]=0.5*($padded[$index+3]+$padded[$index]);
 }
 my $break_multiplier=1e-9;
 my @difference=map { abs($padded[$_+1]-$padded[$_]) } (0..$#padded-1);
 my $maximum_weight=0;
 for my $index (0..$count-1) {
  my $weight=$difference[$index+2]+$difference[$index];
  $maximum_weight=$weight if($weight > $maximum_weight);
 }
 $maximum_weight=-1 if($maximum_weight == 0);
 for my $index (0..$count-1) {
  my $right_weight=$difference[$index+2];
  my $left_weight=$difference[$index];
  my $weight=$right_weight+$left_weight;
  next if($weight <= 0);
  next if($maximum_weight > 0
   && $weight <= $break_multiplier*$maximum_weight);
  $derivatives[$index]=$padded[$index+1]
   +($left_weight/$weight)*($padded[$index+2]-$padded[$index+1]);
 }

 my @result;
 for my $query ($min_idx..$max_idx) {
  if($query <= $xs[0]) { push @result,$ys[0]; next; }
  if($query >= $xs[-1]) { push @result,$ys[-1]; next; }
  my $segment=0;
  for my $index (0..$count-2) {
   if($xs[$index+1] >= $query) { $segment=$index; last; }
  }
  my $span=$xs[$segment+1]-$xs[$segment];
  if($span == 0) { push @result,$ys[$segment]; next; }
  my $position=($query-$xs[$segment])/$span;
  my $squared=$position*$position;
  my $cubed=$squared*$position;
  my $h00=2*$cubed-3*$squared+1;
  my $h10=$cubed-2*$squared+$position;
  my $h01=-2*$cubed+3*$squared;
  my $h11=$cubed-$squared;
  push @result,$h00*$ys[$segment]
   +$h10*$span*$derivatives[$segment]
   +$h01*$ys[$segment+1]
   +$h11*$span*$derivatives[$segment+1];
 }
 return \@result;
}

1;
