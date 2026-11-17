#!/usr/bin/perl
# Follow-up to PR #55 (issue #50 review): webui_wifi_scan_json() escaped '"'
# but not '\' when serialising attacker-controlled SSIDs. An SSID ending in
# '\' (or containing '\"') emitted invalid JSON, so ONE nearby AP could blank
# the whole scan list on every client: fetchJSON() rejects the array and the
# UI shows nothing. Denial of service, not injection -- but a neighbouring
# beacon silencing the Wi-Fi picker is not acceptable.
#
# Real-call test (model: t/webui_config_noop_sudo.t): load webui.pm, stub
# &sudo with a crafted wpa_cli scan_results blob, and require the endpoint's
# output to be valid JSON whose SSIDs round-trip exactly.
use strict;
use warnings;
no warnings qw(redefine once);
use FindBin qw($Bin);
use Test::More;
use JSON::PP qw(decode_json);
require "$Bin/../usr/share/PGenerator/webui.pm";

# wpa_cli scan_results shape: bssid \t freq \t signal \t flags \t ssid
# (wpa_cli escapes '\\' and '"' in the ssid column, so SSID has \" quote is
# emitted as has \\\" quote)
my $blob = join("\n",
  'bssid / frequency / signal level / flags / ssid',
  "aa:bb:cc:dd:ee:01\t2412\t-50\t[WPA2-PSK-CCMP][ESS]\tevil\\",
  "aa:bb:cc:dd:ee:02\t2412\t-55\t[ESS]\thas \\\\\\\" quote",
  "aa:bb:cc:dd:ee:03\t2437\t-60\t[ESS]\tplain",
  "aa:bb:cc:dd:ee:04\t5180\t-65\t[WPA3-EAP-SHA256][ESS]\tsay \"hi\"",
  "aa:bb:cc:dd:ee:05\t5180\t-70\t[ESS]\t\x01\x02",
)."\nOK\n";
local *main::sudo = sub { $blob };

my $json = main::webui_wifi_scan_json();
my $nets;
my $ok = eval { $nets = decode_json($json); 1 };
ok($ok, 'scan JSON parses even with backslashes and quotes in SSIDs')
  or diag("invalid JSON: $@\njson: $json");
SKIP: {
  skip 'unparseable scan JSON', 4 unless $ok;
  is(scalar(@$nets), 4, 'printable-only SSID still dropped, four rows remain');
  is($nets->[0]{ssid}, 'evil\\', 'SSID ending in a backslash round-trips');
  is($nets->[1]{ssid}, 'has \\" quote', 'SSID with backslash-quote round-trips');
  is($nets->[3]{ssid}, 'say "hi"', 'SSID with plain quotes still round-trips');
}
done_testing();
