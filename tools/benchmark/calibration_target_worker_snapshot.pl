#!/usr/bin/perl

use strict;
use warnings;
no warnings qw(once redefine);

my $root=shift || ".";
my $count=shift || 10_000;
$count=int($count);
die "count must be positive\n" if($count < 1);

unshift @INC,"$root/usr/share/PGenerator";
my $worker_1d="$root/usr/bin/meter_lg_autocal.pl";
my $worker_3d="$root/usr/bin/meter_lg_3d_autocal.pl";

sub load_worker {
 my ($path)=@_;
 local @ARGV=();
 my $loaded=do $path;
 die "Unable to load $path: ".($@||$!||"unknown error")."\n"
  if(!defined($loaded));
}

sub formatted {
 my ($value)=@_;
 return "undef" if(!defined($value));
 return sprintf("%.17g",$value);
}

my @one_d_policies=(
 ["sdr","2.2"], ["sdr","2.4"], ["sdr","srgb"],
 ["sdr","bt1886"], ["hdr10","st2084"], ["hdr10","2.2"],
 ["hlg","2.4"], ["dv","st2084"],
);
my @three_d_policies=(
 ["sdr","2.2"], ["sdr","2.4"], ["sdr","srgb"],
 ["sdr","bt1886"], ["hdr10","st2084"], ["hdr10","2.2"],
 ["hlg","2.4"], ["dv","2.2"],
);

load_worker($worker_1d);
for(my $i=0;$i<$count;$i++) {
 my ($mode,$gamma)=@{$one_d_policies[$i%@one_d_policies]};
 my $stimulus=(($i*7919)%109001)/1000;
 my $white=80+(($i*37)%1921)/10;
 my $black=($i%7==0) ? (($i*13)%1000)/100_000 : 0;
 $main::LG_AUTOCAL_CONFIG={
  pattern_signal_range=>(($i%3)==0 ? 1 : 2),
  color_format=>(($i%3)==0 ? 1 : 0),
 };
 my $actual=main::target_luminance_for_step(
  $white,{stimulus=>$stimulus,ire=>$stimulus},$gamma,$mode,$black);
 print join("\t","1d",$i,$mode,$gamma,formatted($actual))."\n";
}

load_worker($worker_3d);
for(my $i=0;$i<$count;$i++) {
 my ($mode,$gamma)=@{$three_d_policies[$i%@three_d_policies]};
 my $signal=(($i*3571)%10001)/10000;
 my $white=80+(($i*43)%1921)/10;
 my $black=($i%5==0) ? (($i*17)%1000)/100_000 : 0;
 my $actual=main::target_relative_luminance(
  $signal,$gamma,$white,$black);
 print join("\t","3d",$i,$mode,$gamma,formatted($actual))."\n";
}
