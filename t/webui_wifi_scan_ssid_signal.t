#!/usr/bin/perl
# Issue #58: wpa_cli scan_results/status print SSIDs through printf_encode()
# (\\ \" \e \n \r \t, \xNN for bytes outside 0x20-0x7e), and the signal column
# was put into JSON unquoted. The picker showed literal "\xc3\xa9" for
# non-ASCII names, double-escaped backslashes, and could be fed a non-numeric
# signal. This drives the real endpoints with real wpa_cli encoding.
use strict;
use warnings;
no warnings qw(redefine once);
use FindBin qw($Bin);
use Test::More;
use JSON::PP qw(decode_json);
binmode(Test::More->builder->output,':utf8');
binmode(Test::More->builder->failure_output,':utf8');
require "$Bin/../usr/share/PGenerator/webui.pm";

sub row { my ($sig,$flags,$ssid)=@_; return "aa:bb:cc:dd:ee:01\t2412\t$sig\t$flags\t$ssid"; }
my $blob = join("\n",
  'bssid / frequency / signal level / flags / ssid',
  row('-50','[WPA2-PSK-CCMP][ESS]','plain'),
  row('-51','[ESS]','caf\xc3\xa9'),                       # cafe + e-acute, UTF-8
  row('-52','[ESS]','back\\\\slash'),                      # raw: back\slash
  row('-53','[ESS]','say \\"hi\\"'),                       # raw: say "hi"
  row('-54','[ESS]','evil\\\\'),                           # raw: evil\
  row('-55','[ESS]','\x00\x00\x00'),                       # hidden network
  row('-56','[ESS]','bad\x01ctl'),                         # control byte
  row('-57','[ESS]','latin\xe9'),                          # not valid UTF-8
  row('-58','[ESS]','   '),                                # blank
  row('-59','[ESS]','tab\\there'),                         # raw tab
  row('-60','[WEP]','\xf0\x9f\x93\xb6 wifi'),             # emoji, 4-byte UTF-8
  row('-61','[ESS]','x\\xZZ'),                             # bad escape stays literal
  row('-62','[WPA2-PSK-CCMP]','\\\\x41'),                  # raw: \x41 (no decode)
  row('-67"},{"ssid":"pwn','[ESS]','inject'),
  row('abc','[ESS]','nonnumeric'),
  row('','[ESS]','emptysig'),
  row('-70.5','[ESS]','floatsig'),
  row('+55','[ESS]','plussig'),
  row('55','[ESS]','positive'),
)."\nOK\n";
local *main::sudo = sub { $_[0] eq 'WIFI_SCAN' ? $blob : '' };

my $json = main::webui_wifi_scan_json();
my $nets;
ok(eval { $nets = JSON::PP->new->utf8(1)->decode($json); 1 }, 'scan JSON parses')
  or diag("invalid JSON: $@\njson: $json");
SKIP: {
  skip 'unparseable scan JSON', 20 unless $nets;
  my %by = map { $_->{ssid} => $_ } @$nets;
  my @names = map { $_->{ssid} } @$nets;
  ok($by{'plain'}, 'plain ASCII SSID listed');
  ok($by{"caf\x{e9}"}, 'wpa_cli \\xNN UTF-8 bytes decode to the real name');
  ok($by{'back\\slash'}, 'wpa_cli \\\\ decodes to one backslash');
  ok($by{'say "hi"'}, 'wpa_cli \\" decodes to a quote');
  ok($by{'evil\\'}, 'SSID ending in a backslash round-trips');
  ok($by{"\x{1F4F6} wifi"}, '4-byte UTF-8 SSID decodes');
  ok($by{'x\\xZZ'}, 'malformed \\x escape is left literal');
  ok($by{'\\x41'}, 'escaped backslash followed by x41 is not decoded twice');
  ok(!(grep { $_ eq "tab\there" } @names), 'SSID with a control byte is dropped, not mangled');
  ok(!(grep { /^bad|^latin|^\s*$/ } @names), 'hidden, control, non-UTF-8 and blank SSIDs are dropped');
  is($by{'plain'}{signal}, -50, 'signal is a JSON number');
  is($by{'positive'}{signal}, 55, 'positive integer signal accepted');
  ok(!$by{'inject'}, 'signal carrying JSON syntax drops the row');
  ok(!$by{'nonnumeric'} && !$by{'emptysig'} && !$by{'floatsig'} && !$by{'plussig'},
     'non-integer signal drops the row');
  is($by{'plain'}{security}, 'WPA', 'security column still mapped');
  is($by{"\x{1F4F6} wifi"}{security}, 'WEP', 'WEP mapped');
  is(scalar(@$nets), 9, 'exactly the nine valid rows remain');
}
like($json, qr/caf\xc3\xa9/, 'non-ASCII SSID goes out as raw UTF-8 bytes (Content-Length is byte length)');
unlike($json, qr/\\\\xc3|\\\\xa9/, 'no literal \\xNN escape text leaks into the picker');

# status endpoint shows the same decoded name the picker sent
local *main::sudo = sub {
  return "wpa_state=COMPLETED\nssid=caf\\xc3\\xa9 \\\\ \\\"q\\\"\nip_address=10.0.0.5\nfreq=5180\nbssid=aa:bb:cc:dd:ee:01\n"
    if $_[0] eq 'GET_WIFI_STATUS';
  return '';
};
my $st = decode_json(main::webui_wifi_status_json());
is($st->{ssid}, "caf\x{e9} \\ \"q\"", 'status SSID is decoded and JSON-escaped once');
local *main::sudo = sub { $_[0] eq 'GET_WIFI_STATUS' ? "wpa_state=COMPLETED\nssid=latin\\xe9\nip_address=10.0.0.5\n" : '' };
$st = decode_json(main::webui_wifi_status_json());
is($st->{ssid}, 'latin\\xe9', 'status SSID that is not valid UTF-8 falls back to wpa_cli text');

# SSIDs "0" and with a leading space must survive the status round-trip
for my $case (['0','0'], [' lead',' lead']) {
  my ($txt,$want)=@$case;
  local *main::sudo = sub { $_[0] eq 'GET_WIFI_STATUS' ? "wpa_state=COMPLETED\nssid=$txt\nip_address=10.0.0.5\n" : '' };
  my $s = decode_json(main::webui_wifi_status_json());
  is($s->{ssid}, $want, "status keeps SSID '$txt' as is");
}

# /api/info reads the cached wpa_cli status text and must emit valid JSON
use File::Temp qw(tempdir);
use MIME::Base64 qw(encode_base64);
my $tmp = tempdir(CLEANUP=>1);
{
  no warnings 'once';
  local $main::info_dir = $tmp;
  local *main::read_from_file = sub { return '' if !defined $_[0]; open(my $r,'<',$_[0]) or return ''; local $/; my $c=<$r>; defined $c ? $c : '' };
  local *main::get_temperature = sub { '40' };
  local *main::decode_base64 = \&MIME::Base64::decode_base64;
  for my $case (['caf\xc3\xa9', "caf\x{e9}"], ['a\\"b', 'a"b'], ['a\\\\b', 'a\\b'], ['bad\x01ctl', 'bad\x01ctl'], ['0', '0']) {
    my ($txt,$want)=@$case;
    open(my $w, '>', "$tmp/GET_WIFI_STATUS.info") or die $!;
    print $w encode_base64("wpa_state=COMPLETED\nssid=$txt\nfreq=5180\n", '');
    close($w);
    my $info;
    ok(eval { $info = JSON::PP->new->utf8(1)->decode(main::webui_info_json()); 1 }, "info JSON parses for SSID '$txt'")
      or diag($@);
    is($info && $info->{wifi}{ssid}, $want, "info SSID decoded once for '$txt'");
  }
}

# connect: what the picker shows must reach wpa_supplicant byte-for-byte
my @sudo;
local *main::sudo = sub { @sudo = @_; "OK\nip_address=10.0.0.9" };
sub connect_body { return JSON::PP->new->utf8(1)->encode({ssid=>$_[0], psk=>$_[1]}); }
for my $ssid ('back\\slash', 'say "hi"', 'evil\\', "caf\x{e9}", "\x{1F4F6} wifi") {
  @sudo = ();
  my $res = decode_json(main::webui_wifi_connect(connect_body($ssid, 'pa"ss\\word1')));
  is($res->{status}, 'ok', "connect accepts $ssid") or diag(JSON::PP->new->encode($res));
  my $want = $ssid; utf8::encode($want);
  is($sudo[2], $want, "SSID reaches WIFI_APPLYCONF unchanged: $ssid");
  is($sudo[3], 'pa"ss\\word1', 'passphrase with quote and backslash is not truncated');
}
@sudo = ();
my $res = decode_json(main::webui_wifi_connect('{"ssid":"","psk":"x"}'));
is($res->{status}, 'error', 'empty SSID rejected');
$res = decode_json(main::webui_wifi_connect('not json'));
is($res->{status}, 'error', 'garbage body rejected');
$res = decode_json(main::webui_wifi_connect(connect_body('x' x 33, '')));
is($res->{status}, 'error', 'SSID over 32 bytes rejected');
$res = decode_json(main::webui_wifi_connect(connect_body("a\x01b", '')));
is($res->{status}, 'error', 'SSID with a control byte rejected');
is(scalar(@sudo), 0, 'rejected requests never reach sudo');
for my $bad ('{"ssid":123,"psk":"x"}', '{"ssid":"net","psk":123}', '{"ssid":"net","psk":["a"]}',
             '{"ssid":"net","psk":{"a":1}}', '{"ssid":"net","psk":true}', '{"ssid":["net"],"psk":"x"}') {
  $res = decode_json(main::webui_wifi_connect($bad));
  is($res->{status}, 'error', "non-string field rejected: $bad");
}
$res = decode_json(main::webui_wifi_connect(connect_body('-p', 'x')));
is($res->{status}, 'error', 'SSID starting with - rejected');
is(scalar(@sudo), 0, 'wrong-type and leading-dash requests never reach sudo');
$res = decode_json(main::webui_wifi_connect('{"ssid":"123"}'));
is($res->{status}, 'ok', 'string SSID with no psk still connects (open network)');
$res = decode_json(main::webui_wifi_connect('{"ssid":"net","psk":null}'));
is($res->{status}, 'ok', 'null psk treated as absent');

# wifi_wait_completed compares wpa_cli status text: the encoder must be the
# inverse of the decoder the web UI uses.
open(my $fh, '<', "$Bin/../usr/bin/PGenerator_cmd.pl") or die $!;
my $src = do { local $/; <$fh> }; close($fh);
my ($sub) = $src =~ /(sub wifi_ssid_wpa_txt\(\@\) \{.*?\n\}\n)/s or die 'sub not found';
eval "package CmdUnderTest; $sub; 1" or die $@;
for my $ssid ('plain', 'back\\slash', 'say "hi"', "caf\xc3\xa9") {
  my $txt = CmdUnderTest::wifi_ssid_wpa_txt($ssid);
  my $back = main::_webui_wpa_ssid_decode($txt);
  is($back, $ssid, "wpa_txt encode round-trips: $ssid");
}
is(CmdUnderTest::wifi_ssid_wpa_txt("caf\xc3\xa9"), 'caf\\xc3\\xa9', 'UTF-8 bytes encoded as \\xNN like wpa_cli status');

done_testing();
