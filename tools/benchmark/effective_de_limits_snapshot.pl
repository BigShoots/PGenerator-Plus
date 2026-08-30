#!/usr/bin/perl

use strict;
use warnings;

my $root=shift || ".";
my $implementation=shift || "shared";
my $count=int(shift || 10_000);
die "implementation must be legacy or shared\n"
 if($implementation ne "legacy" && $implementation ne "shared");
die "count must be positive\n" if($count < 1);

unshift @INC,"$root/usr/share/PGenerator";
require PGCalibrationMath if($implementation eq "shared");

sub formatted { return sprintf("%.17g",$_[0]); }

sub legacy_limits {
 my ($policy,$ire,$target,$skip_fraction,$low_threshold,$very_low_threshold,
  $low_multiplier,$very_low_multiplier)=@_;
 my $effective_target=$target;
 my $very_low=($policy eq "inclusive")
  ? ($ire <= $very_low_threshold) : ($ire < $very_low_threshold);
 my $low=($policy eq "inclusive")
  ? ($ire <= $low_threshold) : ($ire < $low_threshold);
 my $tier="body";
 if($very_low) {
  $effective_target=$target*$very_low_multiplier;
  $tier="very_low";
 } elsif($low) {
  $effective_target=$target*$low_multiplier;
  $tier="low";
 }
 return ($effective_target,$effective_target*$skip_fraction,$tier);
}

for my $policy (qw(inclusive exclusive)) {
 for(my $i=0;$i<$count;$i++) {
  my $ire=(($i*7919)%109001)/1000;
  my $target=0.1+(($i*37)%991)/100;
  my $skip_fraction=($policy eq "inclusive") ? 0.6 : 0.3;
  my $low_threshold=5+(($i%5)/10);
  my $very_low_threshold=($policy eq "inclusive") ? 2 : 2.5;
  my $low_multiplier=1+(($i%9)/8);
  my $very_low_multiplier=$low_multiplier+(($i%7)/6);
  my ($target_limit,$skip_limit,$tier);
  if($implementation eq "legacy") {
   ($target_limit,$skip_limit,$tier)=legacy_limits(
    $policy,$ire,$target,$skip_fraction,$low_threshold,$very_low_threshold,
    $low_multiplier,$very_low_multiplier);
  } else {
   my $limits=PGCalibrationMath::effective_de_limits_for_ire({
    ire=>$ire,target_delta_e=>$target,skip_fraction=>$skip_fraction,
    low_ire_threshold=>$low_threshold,
    very_low_ire_threshold=>$very_low_threshold,
    low_multiplier=>$low_multiplier,
    very_low_multiplier=>$very_low_multiplier,
    threshold_policy=>$policy,
   });
   ($target_limit,$skip_limit,$tier)=@{$limits}{
    qw(target_delta_e skip_delta_e tier)};
  }
  print join("\t",$policy,$i,formatted($target_limit),
   formatted($skip_limit),$tier)."\n";
 }
}
