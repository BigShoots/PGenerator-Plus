package PGMath;

use strict;
use warnings;
use Exporter qw(import);

our @EXPORT_OK=qw(
 akima_interpolate
 bradford_adapt_xyz
 delta_e_itp_xyz
 matrix3_inverse
 matrix3_multiply
 matrix3_vector_multiply
 pq_constants
 pq_decode_nits
 pq_decode_normalized
 pq_encode_normalized
 xyz_to_ictcp
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
# 1D worker, 3D worker and simulator cannot acquire different copies.
my $PQ_M1=2610/16384;
my $PQ_M2=2523/32;
my $PQ_C1=3424/4096;
my $PQ_C2=2413/128;
my $PQ_C3=2392/128;

sub pq_constants {
 return ($PQ_M1,$PQ_M2,$PQ_C1,$PQ_C2,$PQ_C3);
}

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
