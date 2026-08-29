use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use JSON::PP;
use lib "$Bin/../usr/share/PGenerator";
use PGCalibrationMath qw(effective_de_limits_for_ire);

my $path="$Bin/fixtures/effective_de_limits_conformance.json";
open(my $fh,"<",$path) or die "Unable to read $path: $!";
local $/;
my $rows=decode_json(<$fh>);
close($fh);

sub formatted { return sprintf("%.17g",$_[0]); }

for my $row (@{$rows}) {
 my $limits=effective_de_limits_for_ire($row);
 ok(ref($limits) eq "HASH","$row->{name} resolves limits");
 is(formatted($limits->{"target_delta_e"}),$row->{"expected_target"},
  "$row->{name} preserves the effective target limit");
 is(formatted($limits->{"skip_delta_e"}),$row->{"expected_skip"},
  "$row->{name} preserves the effective skip limit");
 is($limits->{"tier"},$row->{"expected_tier"},
  "$row->{name} preserves tier selection");
}

ok(!defined(effective_de_limits_for_ire({
 ire=>5,target_delta_e=>"NaN",skip_fraction=>0.6,
 low_ire_threshold=>5,very_low_ire_threshold=>2,
 low_multiplier=>1.5,very_low_multiplier=>2,
 threshold_policy=>"inclusive",
})),"non-finite target limits are rejected");
ok(!defined(effective_de_limits_for_ire({
 ire=>5,target_delta_e=>0.5,skip_fraction=>2,
 low_ire_threshold=>5,very_low_ire_threshold=>2,
 low_multiplier=>1.5,very_low_multiplier=>2,
 threshold_policy=>"inclusive",
})),"out-of-domain skip fractions are rejected");
ok(!defined(effective_de_limits_for_ire({
 ire=>5,target_delta_e=>0.5,skip_fraction=>0.6,
 low_ire_threshold=>5,very_low_ire_threshold=>2,
 low_multiplier=>1.5,very_low_multiplier=>2,
 threshold_policy=>"unknown",
})),"unknown tier-boundary policies are rejected");

{
 my $worker="$Bin/../usr/bin/meter_lg_autocal.pl";
 open(my $worker_fh,"<",$worker) or die "Unable to read $worker: $!";
 local $/;
 my $source=<$worker_fh>;
 close($worker_fh);
 my $calls=()=$source=~/effective_de_limits_for_ire\s*\(\s*\{/g;
 is($calls,2,"HDR20 and SDR26 use the shared effective-limit owner");
 unlike($source,qr/my\s+\$_effective_target_de\s*=\s*\$target_de\s*;/,
  "the worker has no remaining inline effective-target calculation");
 like($source,qr/current_effective_de_limits/,
  "progress state publishes the resolved effective limits");
 like($source,qr/effective_target_delta_e/,
  "anchor history publishes the resolved target limit");
 like($source,qr/effective_skip_delta_e/,
  "anchor history publishes the resolved skip limit");
 like($source,qr/of effective target/,
  "skip logging names the same effective target used by comparison");
}

done_testing();
