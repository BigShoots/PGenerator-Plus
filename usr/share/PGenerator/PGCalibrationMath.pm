package PGCalibrationMath;

use strict;
use warnings;
use Exporter qw(import);
use Scalar::Util qw(looks_like_number);

our @EXPORT_OK = qw(
 bounded_number
 dpg_smooth_blend_index
 finite_number
 smooth_dpg_low_end
);

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
