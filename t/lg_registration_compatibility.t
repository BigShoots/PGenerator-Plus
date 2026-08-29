use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

BEGIN {
 package IO::Socket::SSL;
 sub import { }
 $INC{'IO/Socket/SSL.pm'}=__FILE__;
}

my $helper="$Bin/../usr/sbin/pgenerator-lg";
do $helper;
die $@ if($@);
die "Failed to load $helper" if(!defined(&lg_register_session_with_compatibility));
$SIG{INT}="DEFAULT";
$SIG{TERM}="DEFAULT";

my $signed=lg_message_register('saved-key','PIN',1);
is($signed->{payload}{manifest}{appVersion},'1.1','signed registration is the default');
ok(scalar(grep { $_ eq 'TEST_PROTECTED' } @{$signed->{payload}{manifest}{permissions}}),
 'signed registration requests protected calibration access');
ok(exists($signed->{payload}{manifest}{signatures}),'signed registration includes its signature');
ok(scalar(grep { $_ eq 'TEST_SECURE' } @{$signed->{payload}{manifest}{signed}{permissions}}),
 'signed registration requests secure calibration access');
ok(scalar(grep { $_ eq 'WRITE_SETTINGS' } @{$signed->{payload}{manifest}{permissions}}),
 'signed registration keeps WRITE_SETTINGS on the outer request for TVs that ignore the signed block');
ok(scalar(grep { $_ eq 'WRITE_NOTIFICATION_ALERT' } @{$signed->{payload}{manifest}{permissions}}),
 'signed registration keeps the notification-backed Luna bridge permission on the outer request');

my $unsigned=lg_message_register('saved-key','PIN',1,'unsigned');
is($unsigned->{payload}{manifest}{appVersion},'1.0','unsigned compatibility registration is selectable');
ok(!exists($unsigned->{payload}{manifest}{signatures}),'unsigned compatibility registration has no signature');
ok(!exists($unsigned->{payload}{manifest}{signed}),'unsigned compatibility registration has no signed block');
ok(scalar(grep { $_ eq 'WRITE_SETTINGS' } @{$unsigned->{payload}{manifest}{permissions}}),
 'unsigned compatibility registration retains normal settings access');

{
 my @sent;
 my @received=({ type=>'registered', payload=>{ 'client-key'=>'saved-key' } });
 my $opened=0;
 my $closed=0;
 no warnings qw(redefine once);
 local *main::websocket_send_json=sub (@) { push(@sent,$_[1]); return 1; };
 local *main::websocket_recv_json=sub (@) { return shift(@received); };
 local *main::websocket_open=sub (@) { $opened++; return { retry=>1 }; };
 local *main::websocket_close=sub (@) { $closed++; return 1; };
 my $result=lg_register_session_with_compatibility(
  '10.0.0.2',{ initial=>1 },'saved-key','PROMPT',0,5,
  { deviceOS=>'webOS' },{ modelName=>'OLED55G36LA' }
 );
 is($result->{status},'ok','signed registration success is returned');
 is($result->{registration_manifest},'legacy_signed','working older TVs retain signed registration');
 ok(!$result->{registration_fallback},'working signed registration does not report fallback');
 is($opened,0,'working signed registration does not reconnect');
 is($closed,0,'working signed registration keeps its socket open');
 ok(exists($sent[0]{payload}{manifest}{signed}),'the first registration attempt is signed');
}

{
 my @sent;
 my @received=(
  { type=>'error', error=>'certificate rejected' },
  { type=>'hello', payload=>{ deviceOS=>'webOS', deviceOSReleaseVersion=>'10.0.0' } },
  { type=>'response', payload=>{ modelName=>'OLED77G6' } },
  { type=>'registered', payload=>{ 'client-key'=>'new-key' } },
 );
 my $retry_session={ retry=>1 };
 my $opened=0;
 my $closed=0;
 no warnings qw(redefine once);
 local *main::websocket_send_json=sub (@) { push(@sent,$_[1]); return 1; };
 local *main::websocket_recv_json=sub (@) { return shift(@received); };
 local *main::websocket_open=sub (@) { $opened++; return $retry_session; };
 local *main::websocket_close=sub (@) { $closed++; return 1; };
 my $result=lg_register_session_with_compatibility(
  '10.0.0.3',{ initial=>1 },'saved-key','PIN',1,5,
  { deviceOS=>'webOS' },{ modelName=>'OLED55G36LA' }
 );
 is($result->{status},'ok','an explicit signed-manifest rejection uses the compatibility retry');
 is($result->{session},$retry_session,'the compatibility retry returns its fresh socket');
 is($result->{registration_manifest},'unsigned','the retry reports the unsigned manifest');
 ok($result->{registration_fallback},'the retry is visible to callers');
 is($opened,1,'the compatibility path reconnects exactly once');
 is($closed,1,'the rejected signed socket is closed exactly once');
 my @register=grep { ($_->{type}||'') eq 'register' } @sent;
 is(scalar(@register),2,'the compatibility path sends two registration attempts');
 ok(exists($register[0]{payload}{manifest}{signed}),'the first compatibility attempt is signed');
 ok(!exists($register[1]{payload}{manifest}{signed}),'the second compatibility attempt is unsigned');
 is($result->{hello_info}{deviceOSReleaseVersion},'10.0.0','retry hello metadata replaces the closed session metadata');
 is($result->{system_info}{modelName},'OLED77G6','retry system metadata replaces the closed session metadata');
 # The successful fallback is memoized per ip+model: the next command must
 # register unsigned directly instead of re-probing signed and paying a
 # socket teardown and full re-handshake on every TV operation.
 @sent=();
 @received=({ type=>'registered', payload=>{ 'client-key'=>'new-key' } });
 my ($opened_before,$closed_before)=($opened,$closed);
 my $memoized=lg_register_session_with_compatibility(
  '10.0.0.3',{ second=>1 },'new-key','PIN',1,5,
  { deviceOS=>'webOS' },{ modelName=>'OLED55G36LA' }
 );
 is($memoized->{status},'ok','a memoized TV registers successfully');
 is($memoized->{registration_manifest},'unsigned','the memoized manifest is used directly');
 is(scalar(@sent),1,'the memoized path sends exactly one registration');
 ok(!exists($sent[0]{payload}{manifest}{signed}),'the memoized registration is unsigned');
 is($opened,$opened_before,'the memoized path never reconnects');
 is($closed,$closed_before,'the memoized path keeps its socket open');
}

{
 my @received=({ type=>'error', error=>'certificate rejected' });
 my $opened=0;
 my $closed=0;
 no warnings qw(redefine once);
 local *main::websocket_send_json=sub (@) { return 1; };
 local *main::websocket_recv_json=sub (@) { return shift(@received); };
 local *main::websocket_open=sub (@) { $opened++; return undef; };
 local *main::websocket_close=sub (@) { $closed++; return 1; };
 my $result=lg_register_session_with_compatibility(
  '10.0.0.4',{ initial=>1 },'saved-key','PROMPT',0,5,{},{}
 );
 is($result->{status},'error','a failed compatibility reconnect is terminal');
 is($opened,1,'a failed compatibility reconnect is attempted once');
 is($closed,1,'the rejected signed socket is still closed');
 like($result->{message},qr/unsigned retry could not reconnect/i,'the reconnect failure is explicit');
}

{
 my @received=(undef);
 my $opened=0;
 my $closed=0;
 no warnings qw(redefine once);
 local *main::websocket_send_json=sub (@) { return 1; };
 local *main::websocket_recv_json=sub (@) { return shift(@received); };
 local *main::websocket_open=sub (@) { $opened++; return { retry=>1 }; };
 local *main::websocket_close=sub (@) { $closed++; return 1; };
 my $result=lg_register_session_with_compatibility(
  '10.0.0.5',{ initial=>1 },'saved-key','PROMPT',0,5,{},{}
 );
 is($result->{status},'error','a missing registration reply stays a transport failure');
 is($opened,0,'a missing reply does not downgrade permissions through fallback');
 is($closed,1,'the unacknowledged socket is closed');
}

# An operator-declined pairing must stay terminal: retrying with the unsigned
# manifest would re-display the pairing prompt for a single action.
{
 my @received=({ type=>'error', error=>'pairing denied by user' });
 my $opened=0;
 my $closed=0;
 no warnings qw(redefine once);
 local *main::websocket_send_json=sub (@) { return 1; };
 local *main::websocket_recv_json=sub (@) { return shift(@received); };
 local *main::websocket_open=sub (@) { $opened++; return { retry=>1 }; };
 local *main::websocket_close=sub (@) { $closed++; return 1; };
 my $result=lg_register_session_with_compatibility(
  '10.0.0.8',{ initial=>1 },'saved-key','PROMPT',0,5,{},{}
 );
 is($result->{status},'error','a declined pairing is terminal');
 is($result->{message},'pairing denied by user','the denial is reported verbatim');
 is($opened,0,'a declined pairing never triggers the unsigned retry');
 is($closed,1,'the declined socket is closed');
}

# The retry's fresh socket must complete its own hello before registering; a
# TV that stays silent there is a transport failure, not a permission
# downgrade.
{
 my @received=(
  { type=>'error', error=>'certificate rejected' },
  { type=>'response', payload=>{} },
 );
 my $opened=0;
 my $closed=0;
 no warnings qw(redefine once);
 local *main::websocket_send_json=sub (@) { return 1; };
 local *main::websocket_recv_json=sub (@) { return shift(@received); };
 local *main::websocket_open=sub (@) { $opened++; return { retry=>1 }; };
 local *main::websocket_close=sub (@) { $closed++; return 1; };
 my $result=lg_register_session_with_compatibility(
  '10.0.0.6',{ initial=>1 },'saved-key','PROMPT',0,5,{},{}
 );
 is($result->{status},'error','an unacknowledged retry hello is terminal');
 like($result->{message},qr/did not acknowledge the unsigned registration retry hello/i,
  'the failed retry hello is explicit');
 is($result->{legacy_registration_error},'certificate rejected',
  'the original signed rejection is preserved through the retry-hello failure');
 is($closed,2,'both sockets are closed after a failed retry hello');
}

# When BOTH manifests are rejected the error must carry both rejections so a
# field report distinguishes "old TV, new failure" from "new TV, old failure".
{
 my @received=(
  { type=>'error', error=>'certificate rejected' },
  { type=>'hello', payload=>{ deviceOS=>'webOS' } },
  { type=>'response', payload=>{} },
  { type=>'error', error=>'pairing denied by user' },
 );
 my $opened=0;
 my $closed=0;
 no warnings qw(redefine once);
 local *main::websocket_send_json=sub (@) { return 1; };
 local *main::websocket_recv_json=sub (@) { return shift(@received); };
 local *main::websocket_open=sub (@) { $opened++; return { retry=>1 }; };
 local *main::websocket_close=sub (@) { $closed++; return 1; };
 my $result=lg_register_session_with_compatibility(
  '10.0.0.7',{ initial=>1 },'saved-key','PROMPT',0,5,{},{}
 );
 is($result->{status},'error','a double rejection is terminal');
 is($result->{message},'pairing denied by user','the unsigned rejection is the primary message');
 is($result->{legacy_registration_error},'certificate rejected',
  'the signed rejection is carried alongside');
 is($result->{unsigned_registration_error},'pairing denied by user',
  'the unsigned rejection is carried explicitly');
 is($closed,2,'both rejected sockets are closed');
}

{
 my $g3=lg_generation_info({ modelName=>'OLED55G36LA' },{}, { deviceOSReleaseVersion=>'9.2.2' });
 is($g3->{series},'G3','the G3 regional suffix is not consumed as part of its series');
 is($g3->{generation_id},'lg2022plus_oled','the G3 uses the current OLED generation profile');
 ok(!$g3->{ddc_only_white_balance},'the G3 retains native white-balance support');

 my $g5=lg_generation_info({ modelName=>'OLED83G54LW.BEKYLJP' },{},{});
 is($g5->{series},'G5','the G5 regional suffix is not consumed as part of its series');
 is($g5->{generation_id},'lg2022plus_oled','the G5 uses the current OLED generation profile');

 my $c8=lg_generation_info({ modelName=>'OLED65C8PLA' },{},{});
 is($c8->{series},'C8','older single-digit series parsing remains intact');
 is($c8->{generation_id},'lg2018_oled','the C8 retains its legacy generation profile');
 ok($c8->{ddc_only_white_balance},'the C8 retains DDC-only white balance');
}

{
 open(my $fh,'<',$helper) or die "Unable to read $helper: $!";
 local $/;
 my $source=<$fh>;
 close($fh);
 like($source,qr/sub lg_authenticated_session[\s\S]+?lg_register_session_with_compatibility/,
  'normal authentication uses the compatibility handshake');
 like($source,qr/sub lg_connect_pin_wait_workflow[\s\S]+?lg_register_session_with_compatibility/,
  'PIN pairing uses the compatibility handshake');
}

done_testing;
