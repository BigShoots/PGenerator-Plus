use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

my $worker="$Bin/../usr/bin/meter_lg_autocal.pl";
do $worker;
die $@ if($@);
die "Failed to load $worker (do returned nothing and the resolver is missing)" if(!defined(&autocal_solver_target_delta_e));
# The worker installs INT/TERM handlers that only set a cancellation flag;
# restore the defaults so Ctrl-C still kills a test run.
$SIG{INT}="DEFAULT";
$SIG{TERM}="DEFAULT";

is(autocal_solver_target_delta_e({target_delta_e=>0.2},'lg_autocal_sdr26_dpg_target_de',0.5),0.2,'SDR inherits the operator target');
is(autocal_solver_target_delta_e({target_delta_e=>0.2},'lg_autocal_hdr20_dpg_target_de',0.5),0.2,'HDR inherits the operator target');
is(autocal_solver_target_delta_e({target_delta_e=>0.2},undef,0.5),0.2,'the main body (undef key) inherits the operator target');
is(autocal_solver_target_delta_e({target_delta_e=>0.2},'',0.5),0.2,'an empty override key is ignored');
is(autocal_solver_target_delta_e({},undef,0.5),0.5,'an empty config uses the fallback');
is(autocal_solver_target_delta_e(undef,'lg_autocal_sdr26_dpg_target_de',0.5),0.5,'a missing config uses the fallback');
is(autocal_solver_target_delta_e({},'lg_autocal_sdr26_dpg_target_de','garbage'),0.5,'an invalid fallback sanitises to 0.5');
is(autocal_solver_target_delta_e({target_delta_e=>0.2,lg_autocal_sdr26_dpg_target_de=>0.35},'lg_autocal_sdr26_dpg_target_de',0.5),0.35,'explicit solver override wins');
is(autocal_solver_target_delta_e({target_delta_e=>0.3,lg_autocal_sdr26_dpg_target_de=>'bogus'},'lg_autocal_sdr26_dpg_target_de',0.5),0.3,'an invalid override falls through to the operator target');
is(autocal_solver_target_delta_e({target_delta_e=>0.3,lg_autocal_sdr26_dpg_target_de=>0},'lg_autocal_sdr26_dpg_target_de',0.5),0.3,'a zero override falls through to the operator target');
is(autocal_solver_target_delta_e({target_delta_e=>0.3,lg_autocal_sdr26_dpg_target_de=>-2},'lg_autocal_sdr26_dpg_target_de',0.5),0.3,'a negative override falls through to the operator target');
is(autocal_solver_target_delta_e({target_delta_e=>0.3,lg_autocal_sdr26_dpg_target_de=>0.05},'lg_autocal_sdr26_dpg_target_de',0.5),0.1,'a tiny valid override clamps rather than falling through');
is(autocal_solver_target_delta_e({target_delta_e=>' 0.3'},'lg_autocal_hdr20_dpg_target_de',0.5),0.3,'whitespace-padded targets are honoured');
is(autocal_solver_target_delta_e({target_delta_e=>'+0.3'},'lg_autocal_hdr20_dpg_target_de',0.5),0.3,'plus-signed targets are honoured');
is(autocal_solver_target_delta_e({target_delta_e=>'2e-1'},'lg_autocal_hdr20_dpg_target_de',0.5),0.2,'scientific-notation targets are honoured');
is(autocal_solver_target_delta_e({target_delta_e=>0.1},'lg_autocal_hdr20_dpg_target_de',0.5),0.1,'the full UI minimum reaches the worker');
is(autocal_solver_target_delta_e({target_delta_e=>10},'lg_autocal_hdr20_dpg_target_de',0.5),10,'the full UI maximum reaches the worker');
is(autocal_solver_target_delta_e({target_delta_e=>20},'lg_autocal_hdr20_dpg_target_de',0.5),10,'targets above the UI range are capped consistently');
is(autocal_solver_target_delta_e({target_delta_e=>0.01},'lg_autocal_hdr20_dpg_target_de',0.5),0.1,'targets below the UI range are capped consistently');
is(autocal_solver_target_delta_e({target_delta_e=>'invalid'},'lg_autocal_hdr20_dpg_target_de',0.5),0.5,'invalid targets use the fallback');

my $source;
{
 local $/;
 open(my $fh,'<',$worker) or die "Unable to read $worker: $!";
 $source=<$fh>;
 close($fh);
}

# Positive counted pins: these FAIL (count drops) on any refactor of the
# declarations, instead of passing vacuously the way a negative match would.
my $mult_defaults=()=$source=~/lg_autocal_(?:hdr20|sdr26)_dpg_target_de_(?:low|very_low)_multiplier"\}\)\s*\?\s*\([^\n]+\)\s*:\s*1\.0/g;
is($mult_defaults,4,'all four low-IRE target multipliers default to exactly 1.0');
my $close_defaults=()=$source=~/lg_autocal_(?:hdr20|sdr26)_dpg_low_ire_close_factor"\}\)\s*\?\s*\([^\n]+\)\s*:\s*1\.0/g;
is($close_defaults,2,'both near-target shortcut bands default to exactly 1.0');
my $sdr_uses=()=$source=~/autocal_solver_target_delta_e\(\$config,"lg_autocal_sdr26_dpg_target_de",0\.5\)/g;
is($sdr_uses,2,'both SDR solver layers use the shared resolver');
my $hdr_uses=()=$source=~/autocal_solver_target_delta_e\(\$config,"lg_autocal_hdr20_dpg_target_de",0\.5\)/g;
is($hdr_uses,1,'the HDR solver uses the shared resolver');
my $main_uses=()=$source=~/autocal_solver_target_delta_e\(\$config,undef,0\.5\)/g;
is($main_uses,1,'the main-body target uses the shared resolver');

done_testing();
