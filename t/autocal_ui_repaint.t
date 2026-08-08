#
# Contract: live LG greyscale AutoCal status polling must not repaint every
# chart and persist the full series cache when the measurements are unchanged.
#
# A long convergence run polls for status roughly every 1.5 seconds. Canvas
# painting and localStorage serialisation are main-thread work, so bypassing
# the existing frame-budgeted greyscale painter makes the whole WebUI judder.
#
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$FindBin::Bin/lib";
use PGenSource qw(repo_root slurp_source code_only slice_between);

my $root=repo_root($Bin);
my $webui=slurp_source($root,"usr/share/PGenerator/webui.pm");
my $apply=slice_between(
 $webui,
 qr/async function meterAutoCalApplyStatus\(status\)\{/,
 qr/function meterFullAutoCalCloneValue\(value\)\{/
);

ok(defined($apply),"AutoCal status renderer is locatable");

SKIP: {
 skip "AutoCal status renderer not locatable",5 if(!defined($apply));
 my $code=code_only($apply,"js");

 like($code,qr/const chartChanged=.*meterLastChartSignature/,
  "AutoCal compares a stable chart signature before repainting");
 like($code,qr/if\(statusRunning\)\{\s*if\(chartChanged\)\{/s,
  "unchanged running polls bypass chart and cache work");
 like($code,qr/meterQueueRunningGreyscaleChartRefresh\(sorted\)/,
  "running AutoCal uses the frame-budgeted greyscale painter");
 like($code,qr/\}else\{\s*meterCancelRunningGreyscaleChartRefresh\(\).*?drawAllCharts\(sorted\)/s,
  "terminal AutoCal cancels queued work before its final synchronous paint");

 my $running=()=($code=~/meterCacheSeriesState\(status\.status\|\|'running'\)/g);
 is($running,1,"the running cache write exists only in the changed-chart branch");
}

done_testing();
