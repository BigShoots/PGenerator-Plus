use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use JSON::PP ();

my $module="$Bin/../usr/share/PGenerator/lg.pm";
do $module;
die $@ if($@);
die "Failed to load $module" if(!defined(&lg_public_api_json));

my $public=JSON::PP::decode_json(lg_public_api_json(JSON::PP::encode_json({
 status=>'ok',
 client_key=>'top-secret',
 client_key_present=>JSON::PP::true(),
 nested=>{ 'client-key'=>'nested-secret', safe=>'kept' },
 devices=>[{ clientKey=>'array-secret', name=>'TV' }],
})));

ok(!exists($public->{client_key}),'the top-level LG pairing key is redacted');
ok(!exists($public->{nested}{'client-key'}),'nested hyphenated pairing keys are redacted');
ok(!exists($public->{devices}[0]{clientKey}),'nested browser-style pairing keys are redacted');
ok($public->{client_key_present},'the non-sensitive key-present flag is retained');
is($public->{nested}{safe},'kept','unrelated response data is retained');

my $webui="$Bin/../usr/share/PGenerator/webui.pm";
open(my $fh,'<',$webui) or die "Unable to read $webui: $!";
local $/;
my $source=<$fh>;
close($fh);
like($source,qr/elsif\(\$path=~\/\^\\\/api\\\/lg\\\/\/\).*?lg_public_api_json\(\$result\)/s,
 'all public LG routes pass through the redaction boundary');

done_testing();
