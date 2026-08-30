use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use JSON::PP ();

use lib "$Bin/../usr/share/PGenerator";
use PGSignalCode qw(
 code_to_signal_fraction signal_code_policy signal_percent_to_code
);

my $fixture_path="$Bin/fixtures/signal_code_conformance.json";
open(my $fixture_fh,"<",$fixture_path)
 or die "Unable to read $fixture_path: $!";
local $/;
my $fixture=JSON::PP::decode_json(<$fixture_fh>);
close($fixture_fh);
$/="\n";

is($fixture->{schema},"pgen-signal-code-conformance-v1",
 "signal-code fixture schema is pinned");

foreach my $row (@{$fixture->{rows}}) {
 my $policy=signal_code_policy({
  signal_mode=>$row->{signal_mode},
  signal_range=>$row->{signal_range},
  %{$row->{options}||{}},
 });
 ok(defined($policy),"$row->{name}: policy is valid");
 next if(!defined($policy));
 my $actual=signal_percent_to_code($policy,$row->{stimulus_percent});
 is_deeply($actual,$row->{expected},
  "$row->{name}: shared policy preserves the captured legacy wire result");
 my $fraction=code_to_signal_fraction($policy,$actual->{code});
 ok(defined($fraction) && $fraction == $fraction && $fraction >= 0,
  "$row->{name}: reverse signal fraction is finite and non-negative");
}

my $webui_path="$Bin/../usr/share/PGenerator/webui.pm";
do $webui_path or die "Unable to load $webui_path: ".($@||$!);
foreach my $row (@{$fixture->{rows}}) {
 my $range=$row->{signal_range} eq "limited" ? 1 : 0;
 my ($code,$input_max)=main::webui_grey_code_for_stimulus(
  $row->{stimulus_percent},$row->{signal_mode},"",$range,
  {%{$row->{options}||{}}});
 is_deeply({code=>$code,input_max=>$input_max},$row->{expected},
  "$row->{name}: Web UI adapter agrees with the shared owner");
}

foreach my $worker (qw(
 meter_lg_autocal.pl meter_lg_3d_autocal.pl meter_lg_dv_profile.pl
)) {
 my $path="$Bin/../usr/bin/$worker";
 open(my $source_fh,"<",$path) or die "Unable to read $path: $!";
 local $/;
 my $source=<$source_fh>;
 close($source_fh);
 like($source,qr/use PGSignalCode qw\(/,
  "$worker imports the shared signal-code owner");
 unlike($source,qr/sub _patch_insert_code_for_level\b/,
  "$worker has no private insertion-code implementation");
}

open(my $webui_fh,"<",$webui_path)
 or die "Unable to read $webui_path: $!";
{
 local $/;
 my $source=<$webui_fh>;
 like($source,qr/use PGSignalCode qw\(signal_code_policy signal_percent_to_code\)/,
  "Web UI server imports the shared signal-code owner");
 my $adapter_start=index($source,"sub webui_grey_code_for_stimulus (@) {");
 my $adapter_end=index($source,"# The stabilization pattern",$adapter_start);
 ok($adapter_start>=0 && $adapter_end>$adapter_start
  && ($adapter_end-$adapter_start)<2000,
  "Web UI signal-code entry point remains a thin adapter");
}
close($webui_fh);

my $limited_10=signal_code_policy({
 signal_mode=>'sdr',signal_range=>'limited',max_bpc=>10,
});
is(code_to_signal_fraction($limited_10,64),0,
 "reverse policy maps 10-bit legal black to zero signal");
is(code_to_signal_fraction($limited_10,940),1,
 "reverse policy maps 10-bit nominal white to unit signal");
my $dv_12=signal_code_policy({
 signal_mode=>'dv',signal_range=>'limited',dv_series=>1,
 dv_series_code_bits=>12,dv_series_full_range=>0,
});
is(code_to_signal_fraction($dv_12,2008),0.5,
 "reverse policy removes the Dolby Vision 12-bit legal offset");
my $headroom_10=signal_code_policy({
 signal_mode=>'sdr',signal_range=>'limited',max_bpc=>10,
 autocal_26_codes=>1,color_format=>1,
});
cmp_ok(abs(code_to_signal_fraction($headroom_10,1023)-1.09),'<',1e-12,
 "reverse policy exposes named SDR super-white headroom above unity");

ok(!defined(signal_code_policy(undef)),
 "signal-code policy rejects a missing record");
ok(!defined(signal_code_policy({signal_mode=>'sdr',signal_range=>'bogus'})),
 "signal-code policy rejects an unknown range");
ok(!defined(signal_code_policy({signal_mode=>'bogus',signal_range=>'full'})),
 "signal-code policy rejects an unknown signal mode");
ok(!defined(signal_code_policy({signal_mode=>'sdr',signal_range=>'full',max_bpc=>9})),
 "signal-code policy rejects unsupported source precision");

my $immutable=signal_code_policy({
 signal_mode=>'hdr10',signal_range=>'limited',max_bpc=>10,
 hdr20_codes=>1,active_table=>{50=>777},
});
my $mutation_ok=eval { $immutable->{signal_mode}='sdr'; 1 };
ok(!$mutation_ok,"signal-code policy fields are immutable");
my $table_mutation_ok=eval { $immutable->{active_table}{50}=123; 1 };
ok(!$table_mutation_ok,"custom signal-code table values are immutable");
is_deeply(signal_percent_to_code($immutable,50),{code=>777,input_max=>1023},
 "immutable custom policy remains usable after rejected mutation");

done_testing();
