use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use JSON::PP;
use lib "$Bin/../usr/share/PGenerator";
use PGCalibrationMath qw(
 calibration_target_context
 target_luminance_for_context
 target_relative_luminance_for_context
);

sub fixture {
 my $path="$Bin/fixtures/calibration_target_conformance.json";
 open(my $fh,"<",$path) or die "Unable to read $path: $!";
 local $/;
 return decode_json(<$fh>);
}

sub formatted { return sprintf("%.17g",$_[0]); }

my $rows=fixture();
for my $row (@{$rows}) {
 my $context=calibration_target_context({
  caller_policy=>$row->{"caller_policy"},
  signal_mode=>$row->{"signal_mode"},
  target_gamma=>$row->{"target_gamma"},
  sdr_signal_peak=>$row->{"sdr_signal_peak"},
 });
 ok(ref($context) eq "HASH","$row->{name} builds a context");
 my $actual=$row->{"caller_policy"} eq "autocal_1d"
  ? target_luminance_for_context(
     $context,$row->{"stimulus"},$row->{"white_y"},$row->{"black_y"})
  : target_relative_luminance_for_context(
     $context,$row->{"signal"},$row->{"white_y"},$row->{"black_y"});
 is(formatted($actual),$row->{"expected"},"$row->{name} preserves its pre-context value");
}

my $dv=calibration_target_context({
 caller_policy=>"autocal_1d",signal_mode=>"dv",target_gamma=>"st2084",
 sdr_signal_peak=>100,
});
is($dv->{"schema"},"pgen-calibration-target-context-v1",
 "context carries a stable schema");
is($dv->{"context_version"},1,"context carries a numeric version");
is($dv->{"transfer_policy"},"dv_gamma_2_2_tunnel",
 "the st2084-labelled Dolby Vision tunnel is explicit");
is($dv->{"normalization_policy"},"white_scaled",
 "the Dolby Vision tunnel records its relative normalization");
my $mutated=eval { $dv->{"target_gamma"}="2.4"; 1 };
ok(!$mutated,"a validated context cannot be mutated after construction");
my $encoded=JSON::PP->new->canonical(1)->encode({%{$dv}});
like($encoded,qr/"context_version":1/,
 "a context can be stamped into persisted run metadata");

ok(!defined(calibration_target_context({
 caller_policy=>"unknown",signal_mode=>"sdr",target_gamma=>"2.2",
})),"unknown caller policies are rejected");
ok(!defined(calibration_target_context({
 caller_policy=>"autocal_1d",signal_mode=>"unknown",target_gamma=>"2.2",
})),"unknown signal modes are rejected");
ok(!defined(calibration_target_context({
 caller_policy=>"autocal_1d",signal_mode=>"sdr",target_gamma=>"unknown",
})),"unknown target transfers are rejected");

for my $worker (qw(meter_lg_autocal.pl meter_lg_3d_autocal.pl)) {
 my $path="$Bin/../usr/bin/$worker";
 open(my $fh,"<",$path) or die "Unable to read $path: $!";
 local $/;
 my $source=<$fh>;
 close($fh);
 like($source,qr/calibration_target_context\s*=>\s*\{\s*%\{\$run_target_context\}\s*\}/,
  "$worker stamps the resolved context into run state");
}

{
 my $path="$Bin/../usr/bin/meter_lg_3d_autocal.pl";
 open(my $fh,"<",$path) or die "Unable to read $path: $!";
 local $/;
 my $source=<$fh>;
 close($fh);
 like($source,qr/target_context\s*=>\s*\$target_context/,
  "the 3D model owns one prepared target context");
 like($source,qr/target_relative_luminance_for_context\(\s*\$model->\{"target_context"\}/,
  "the 3D level-matrix hot path consumes the prepared context");
 like($source,qr/target_rgb_to_xyz\([^;]+\$model->\{"target_context"\}\)/s,
  "the 3D node hot path consumes the prepared context");
}

done_testing();
