use strict;
use warnings;
use File::Temp qw(tempdir);

my $path = 'usr/share/PGenerator/webui.pm';
open(my $fh, '<', $path) or die "Failed to open $path: $!\n";
local $/;
my $source = <$fh>;
close($fh);

sub extract_between {
 my ($start, $end) = @_;
 my $start_idx = index($source, $start);
 die "Missing block start: $start\n" if $start_idx < 0;
 my $end_idx = index($source, $end, $start_idx);
 die "Missing block end: $end\n" if $end_idx < 0;
 return substr($source, $start_idx, $end_idx - $start_idx);
}

my $block = extract_between(
 'my $_meter_settings_runtime=',
 "###############################################\n#         Custom CCSS API Functions"
);

my $tmpdir = tempdir(CLEANUP => 1);
my $runtime = "$tmpdir/running/meter_settings.json";
my $legacy = "$tmpdir/legacy-runtime/meter_settings.json";
my $persist = "$tmpdir/persist/meter_settings.json";
my $persist_legacy = "$tmpdir/persist-legacy/meter_settings.json";

$block =~ s/my \$_meter_settings_runtime=.*?;/my \$_meter_settings_runtime='$runtime';/;
$block =~ s/my \$_meter_settings_file=.*?;/my \$_meter_settings_file='$legacy';/;
$block =~ s/my \$_meter_settings_persist=.*?;/my \$_meter_settings_persist='$persist';/;
$block =~ s/my \$_meter_settings_persist_legacy=.*?;/my \$_meter_settings_persist_legacy='$persist_legacy';/;

my $loaded = eval "sub log {} our %pgenerator_conf; $block 1;";
die "Failed to load meter settings helpers: $@\n" if !$loaded;

sub assert_contains {
 my ($text, $needle, $message) = @_;
 die "$message\nMissing: $needle\nPayload: $text\n" if index($text, $needle) < 0;
}

my $save = webui_meter_settings_save('{"patch_size":"5","delay":"4500","patch_insert":false,"target_gamma":"2.4"}');
assert_contains($save, '"status":"ok"', 'Meter settings save should succeed');
die "Runtime meter settings file was not created\n" if !-f $runtime;
die "Persistent meter settings file was not created\n" if !-f $persist;

my $first = webui_meter_settings_load();
my $second = webui_meter_settings_load();

assert_contains($first, '"patch_size":"5"', 'Load should return saved patch size');
assert_contains($first, '"delay":"4500"', 'Load should return saved delay');
assert_contains($first, '"patch_insert":false', 'Load should return saved patch insertion flag');
assert_contains($first, '"target_gamma":"2.4"', 'Load should return saved target gamma');

my ($boot_a) = $first =~ /"boot_id":"([^"]+)"/;
my ($boot_b) = $second =~ /"boot_id":"([^"]+)"/;
die "Boot ID should be stable across consecutive loads\n" if !defined($boot_a) || !defined($boot_b) || $boot_a eq '' || $boot_a ne $boot_b;

print "Meter settings persistence regression checks passed.\n";