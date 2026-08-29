use strict;
use warnings;

use Cwd qw(abs_path);
use File::Basename qw(dirname);
use File::Spec;
use Test::More;

# Load the same module environment as PGeneratord so the API-ingress contract
# is exercised as production Perl, not copied into a test-only parser.
use Cwd;
use Config;
use Time::HiRes qw(usleep);
use IO::Socket::INET;
use IO::Select;
use Getopt::Long;
use File::Copy;
use threads;
use threads::shared;
use URI::Escape;
use MIME::Base64;
use XML::Simple;
use List::Util qw(sum);

my $repo = dirname(dirname(abs_path(__FILE__)));
my $shared = File::Spec->catdir($repo, "usr", "share", "PGenerator");
chdir $shared or die "cannot chdir to $shared: $!";
for my $module (qw(version command variables conf info file log pattern daemon
                   client resolve discovery lg webui bash serial)) {
    my $path = "./$module.pm";
    my $ok = do $path;
    die "$path failed: ".($@ || $! || "module returned false")."\n" unless $ok;
}

ok(defined(&main::webui_low_light_request_contract),
   "WebUI exposes the low-light ingress contract");

if (defined(&main::webui_low_light_request_contract)) {
    my %expected = (off => 1, a => 2, aa => 3, aaa => 5);
    for my $mode (qw(off a aa aaa)) {
        my $enabled = $mode eq "off" ? "false" : "true";
        my $body = qq({"low_light":{"enabled":$enabled,"mode":"$mode"}});
        my $legacy = main::webui_low_light_request_contract($body, 0);
        is($legacy->{mode}, $mode, "$mode remains presentation metadata");
        is($legacy->{requested_sample_count}, $expected{$mode},
           "$mode compatibility ingress resolves to $expected{$mode} samples");
        ok($legacy->{legacy_mode_only}, "$mode-only payload uses the compatibility adapter");

        $body =~ s/\}\z/,"requested_sample_count":$expected{$mode}}/;
        my $numeric = main::webui_low_light_request_contract($body, 0);
        is($numeric->{error}, "", "$mode and its numeric count agree");
        ok(!$numeric->{legacy_mode_only}, "$mode numeric payload is not legacy");
    }

    my $mismatch = main::webui_low_light_request_contract(
        '{"low_light":{"enabled":true,"mode":"aa","requested_sample_count":5}}', 0);
    like($mismatch->{error}, qr/does not match/i,
         "ingress rejects a presentation-mode/count mismatch");

    my $invalid = main::webui_low_light_request_contract(
        '{"low_light":{"enabled":true,"mode":"a","requested_sample_count":"two"}}', 0);
    like($invalid->{error}, qr/requested_sample_count/i,
         "ingress rejects a malformed numeric count");
    my $fractional = main::webui_low_light_request_contract(
        '{"low_light":{"enabled":true,"mode":"a","requested_sample_count":2.0}}', 0);
    like($fractional->{error}, qr/requested_sample_count/i,
         "ingress rejects a numeric count that is not an integer token");

    my $spectro = main::webui_low_light_request_contract(
        '{"low_light":{"enabled":true,"mode":"aaa","requested_sample_count":5}}', 1);
    is_deeply([@{$spectro}{qw(mode requested_sample_count)}], ["off", 1],
              "the spectrophotometer compatibility workflow is explicitly one sample");

    my ($stamped, $stamp_error) = main::webui_low_light_stamp_request(
        '{"low_light":{"enabled":true,"mode":"aa"}}', 0);
    is($stamp_error, "", "mode-only saved config is accepted at the common ingress");
    like($stamped, qr/"low_light_requested_sample_count":3/,
         "persisted run config carries the resolved numeric count");
}

sub source_text {
    my ($path) = @_;
    open my $fh, "<", $path or die "cannot read $path: $!";
    local $/;
    return <$fh> // "";
}

my $webui = source_text(File::Spec->catfile($shared, "webui.pm"));
my @downstream = map { File::Spec->catfile($repo, "usr", "bin", $_) }
                 qw(meter_session.sh meter_series.sh meter_lg_autocal.pl
                    meter_lg_3d_autocal.pl pgen_meter_result.py);
for my $path (@downstream) {
    unlike(source_text($path), qr/(?:sub\s+)?low_light_sample_count\s*\(/,
           "$path has no presentation-mode sample-count table");
}
my $map_owners = () = $webui =~ /sub\s+webui_low_light_sample_count\s*\{/g;
is($map_owners, 1, "one production mode-to-count owner remains");
like(source_text($downstream[0]), qr/CMD_REQUESTED_SAMPLE_COUNT/,
     "persistent meter session executes the numeric count");
like(source_text($downstream[1]), qr/PREPARED_STEP_REQUESTED_SAMPLE_COUNT/,
     "series executes the prepared per-step numeric count");
for my $path (@downstream[2,3]) {
    like(source_text($path), qr/requested_sample_count\s*=>\s*\$read_sample_count/,
         "$path sends the numeric count with each meter request");
}
unlike(source_text($downstream[4]), qr/expected_by_mode/,
       "the averaging helper validates numeric execution without a mode table");

done_testing();
