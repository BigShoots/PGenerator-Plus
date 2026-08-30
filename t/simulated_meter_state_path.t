use strict;
use warnings;
use Test::More;

my $webui_path = 'usr/share/PGenerator/webui.pm';
my $sim_path = 'usr/bin/spotread_sim';

open my $webui_fh, '<', $webui_path or die "open $webui_path: $!";
local $/;
my $webui = <$webui_fh>;
close $webui_fh;

open my $sim_fh, '<', $sim_path or die "open $sim_path: $!";
my $sim = <$sim_fh>;
close $sim_fh;

like(
 $webui,
 qr{my \$_meter_sim_pattern_file="/var/lib/PGenerator/pgen_sim_pattern\.json";},
 'WebUI publishes simulated pattern state outside sticky /tmp'
);
like(
 $sim,
 qr{"/var/lib/PGenerator/pgen_sim_pattern\.json"},
 'simulated meter reads the primary runtime state path'
);
like(
 $sim,
 qr{"/tmp/pgen_sim_pattern\.json"[^\n]*compatibility},
 'simulated meter retains the legacy state-path fallback'
);

done_testing();
