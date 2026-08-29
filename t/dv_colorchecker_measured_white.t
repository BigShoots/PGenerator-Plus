use strict;
use warnings;
use Test::More;
use File::Spec;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use JSON::PP qw(decode_json encode_json);

my $worker = File::Spec->catfile($Bin, '..', 'usr', 'bin', 'meter_series.sh');
open my $worker_fh, '<', $worker or die "cannot read $worker: $!";
local $/;
my $source = <$worker_fh>;
close $worker_fh;

my ($function) = $source =~ /(^apply_series_white_reference_to_steps\(\) \{.*?^\})/ms;
ok(defined $function, 'found measured-white step update function');

my $dir = tempdir(CLEANUP => 1);
my $steps_file = File::Spec->catfile($dir, 'steps.json');
open my $steps_fh, '>', $steps_file or die "cannot write fixture: $!";
print {$steps_fh} encode_json([
 {
  name => 'Gray 35', r => 1999, g => 1999, b => 1999, target_Yn => 0.09,
  colorchecker_rebase_white => JSON::PP::true,
  colorchecker_linear_r => 0.09, colorchecker_linear_g => 0.09,
  colorchecker_linear_b => 0.09, colorchecker_code_min => 256,
  colorchecker_code_span => 3504,
 },
 {name => 'Manual', r => 1700, g => 1700, b => 1700, target_Yn => 0.09,
  series_target_white_y => 500},
]);
close $steps_fh;

my $runner = File::Spec->catfile($dir, 'run.sh');
open my $runner_fh, '>', $runner or die "cannot write runner: $!";
print {$runner_fh} "#!/bin/bash\nset -e\n";
print {$runner_fh} "python(){ command python3 \"\$@\"; }\n";
print {$runner_fh} "STEPS_FILE=\"\$1\"\nSIGNAL_MODE=dv\nDV_MAP_MODE=1\n";
print {$runner_fh} $function, "\napply_series_white_reference_to_steps 711.680157\n";
close $runner_fh;

is(system('bash', $runner, $steps_file), 0, 'worker applies fresh measured white');
open my $result_fh, '<', $steps_file or die "cannot read result: $!";
local $/;
my $steps = decode_json(<$result_fh>);
close $result_fh;

my ($gray, $manual) = @$steps;
is($gray->{series_target_white_y} + 0, 711.680157, 'neutral target uses fresh series white');
is($gray->{r}, $gray->{g}, 'neutral remains equal code');
is($gray->{g}, $gray->{b}, 'neutral remains equal code on all channels');
isnt($gray->{r}, 1999, 'neutral PQ code is rebased from the 1000-nit fallback');
is($gray->{target_Yn} + 0, 0.09, 'authored neutral target remains normalized');
is($manual->{series_target_white_y} + 0, 500, 'manual Target White remains authoritative');
is($manual->{r}, 1700, 'unmarked manual-target code is unchanged');

my $webui = File::Spec->catfile($Bin, '..', 'usr', 'share', 'PGenerator', 'webui.pm');
open my $webui_fh, '<', $webui or die "cannot read $webui: $!";
local $/;
my $webui_source = <$webui_fh>;
close $webui_fh;
like(
 $webui_source,
 qr/\$signal_mode eq "dv" && \$dv_map_mode ne "1" && \$span_code>0/,
 'Absolute DV preserves authored normalized neutral target Yn',
);
like(
 $webui_source,
 qr/\$target_white_use_measured.*?colorchecker_rebase_white/s,
 'server marks neutral rebasing only for Use measured Target White',
);

done_testing();
