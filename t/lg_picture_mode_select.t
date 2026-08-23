use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

# This is a pure unit test: every network operation is replaced below. Keep
# the helper loadable on the minimal CI Perl image without installing the
# production-only TLS client dependency.
BEGIN {
 package IO::Socket::SSL;
 sub import { }
 $INC{'IO/Socket/SSL.pm'}=__FILE__;
}

# The helper is a script; &main() is guarded by caller() so `do` yields the
# subs only. The TV is replaced by a scripted fake below.
my $helper="$Bin/../usr/sbin/pgenerator-lg";
{
 no warnings 'once';
 do $helper;
}
die $@ if($@);
die "Failed to load $helper" if(!defined(&lg_picture_mode_select));
$SIG{INT}="DEFAULT";
$SIG{TERM}="DEFAULT";

my $webui="$Bin/../usr/share/PGenerator/lg.pm";
do $webui;
die $@ if($@);
die "Failed to load $webui" if(!defined(&lg_helper_timeout_message));

# ---------------------------------------------------------------------------
# Label -> webOS token map
# ---------------------------------------------------------------------------
my @map_cases=(
 # label, signal, expected
 ['hdrPersonalized','hdr10','hdrPersonalized','HDR Personalised Picture maps in HDR10'],
 ['hdrPersonalized','hlg','hdrPersonalized','HDR Personalised Picture maps in HLG'],
 ['hdrPersonalized','sdr','','HDR Personalised Picture is refused under SDR'],
 ['hdrPersonalized','','hdrPersonalized','with no signal the HDR token is kept, not folded onto the SDR one'],
 ['HDR Personalised Picture','hdr10','hdrPersonalized','the menu label resolves'],
 ['dolbyVisionPersonalized','dv','dolbyHdrPersonalized','DV Personalised Picture uses the dolbyHdr spelling'],
 ['dolbyVisionPersonalized','sdr','','DV Personalised Picture is refused under SDR'],
 ['personalized','sdr','personalized','SDR Personalised Picture'],
 ['standard','sdr','normal','SDR Standard is spelt normal'],
 ['SDR Standard','sdr','normal','the dropdown label for Standard resolves to normal'],
 ['normal','sdr','normal','normal passes through'],
 ['aps','sdr','eco','APS is the eco token'],
 ['Auto Power Save','sdr','eco','the menu label for eco resolves'],
 ['sports','sdr','sports','sports is its own token, not vivid'],
 ['photo','sdr','photo','photo is a catalogue token'],
 ['Technicolor Expert','sdr','technicolor','C8/C9 Technicolor uses the settings enum token'],
 ['HDR Technicolor Expert','hdr10','hdrTechnicolor','C8/C9 HDR Technicolor uses the settings enum token'],
 ['hdrCinemaBright','hdr10','hdrCinemaBright','HDR Cinema Home'],
 ['HDR Auto Power Save','hdr10','hdrEco','C2+ HDR Auto Power Save maps to hdrEco'],
 ['dolbyVisionFilmMaker','dv','dolbyHdrCinema','DV Filmmaker is the dolbyHdrCinema selector'],
 ['hdrStandard','hdr10','hdrStandard','HDR Standard keeps its own token'],
 ['cinema','hdr10','','an SDR token is refused under HDR'],
);
foreach my $case (@map_cases) {
 my ($label,$signal,$expected,$name)=@{$case};
 is(map_picture_mode_label_to_ddc_name($label,$signal),$expected,$name);
}

# ---------------------------------------------------------------------------
# response_is_app_failure
# ---------------------------------------------------------------------------
{
 my ($failed,$msg)=response_is_app_failure({ type => "close", error => "Connection closed" });
 ok($failed,'a websocket close frame is a failure');
 is($msg,'Connection closed','...and carries the close reason');
 ($failed,$msg)=response_is_app_failure(undef);
 ok(!$failed,'undef is not classified here (callers guard ref() themselves)');
 ($failed,$msg)=response_is_app_failure({ type => "error", error => "500 boom", payload => { errorText => "No matched extended item: pictureMode" } });
 ok($failed,'an error envelope is a failure');
 like($msg,qr/No matched extended item/,'...with the TV detail appended');
 ($failed)=response_is_app_failure({ type => "response", payload => { returnValue => JSON::PP::false() } });
 ok($failed,'returnValue false is a failure');
 ($failed)=response_is_app_failure({ type => "response", payload => { returnValue => JSON::PP::true() } });
 ok(!$failed,'returnValue true is not');
}

# ---------------------------------------------------------------------------
# Fake TV for lg_picture_mode_select
# ---------------------------------------------------------------------------
# $tv->{mode} is what getSystemSettings reports; "silent" makes every
# request time out (undef); @{$tv->{script}} are the scripted replies to
# write requests in order; $tv->{on_write} mutates the TV after a write.
my $tv;
my @requests;
sub reset_tv {
 my %opts=@_;
 $tv={ mode => "cinema", silent => 0, script => [], on_write => undef, %opts };
 @requests=();
}
my $OK={ type => "response", payload => { returnValue => JSON::PP::true() } };
{
 no warnings qw(redefine once);
 *main::lg_request=sub (@) {
  my ($session,$id,$uri,$payload,$timeout)=@_;
  push(@requests,{ id => $id, uri => $uri, payload => $payload, timeout => $timeout });
  return undef if($tv->{"silent"});
  if($uri eq "settings/getSystemSettings") {
   # The G5 refuses to read applyToAllInput at all ("Some keys are not allowed").
   if($tv->{"apply_read_rejected"} && grep { $_ eq "applyToAllInput" } @{$payload->{"keys"}||[]}) {
    return { type => "error", error => "500 Application error", payload => { errorText => "Some keys are not allowed for the request. ( applyToAllInput )", returnValue => JSON::PP::false() } };
   }
   my $apply_state=$tv->{"apply_state"}||"done";
   if(grep { $_ eq "applyToAllInput" } @{$payload->{"keys"}||[]}) {
    $apply_state=shift(@{$tv->{"apply_states"}}) if(ref($tv->{"apply_states"}) eq "ARRAY" && @{$tv->{"apply_states"}});
   }
   return { type => "response", payload => { settings => { pictureMode => $tv->{"mode"}, applyToAllInput => $apply_state } } };
  }
  if($uri eq "settings/setSystemSettings") {
   my $reply=@{$tv->{"script"}} ? shift(@{$tv->{"script"}}) : $OK;
   $tv->{"on_write"}->("ssap",$payload) if(ref($tv->{"on_write"}) eq "CODE");
   return $reply;
  }
  return $OK;
 };
 *main::lg_luna_request=sub (@) {
  my ($session,$id,$uri,$payload,$timeout)=@_;
  push(@requests,{ id => $id, uri => "luna:$uri", payload => $payload, timeout => $timeout });
  return undef if($tv->{"silent"});
  my $reply=@{$tv->{"script"}} ? shift(@{$tv->{"script"}}) : $OK;
  $tv->{"on_write"}->("luna",$payload) if(ref($tv->{"on_write"}) eq "CODE");
  return $reply;
 };
 *main::diag_log_append=sub (@) { return 1; };
}
# No real sleeping in tests.
{
 no warnings 'once';
 $main::PICTURE_MODE_SELECT_POLL_INTERVAL=0;
 $main::PICTURE_MODE_SELECT_POLLS=4;
 $main::APPLY_ALL_INPUTS_POLL_INTERVAL=0;
 $main::APPLY_ALL_INPUTS_POLLS=3;
}
my $NO_MATCH={ type => "error", error => "500 error", payload => { errorText => "No matched extended item: pictureMode" } };

# already active -> nothing written
reset_tv(mode => "hdrCinema");
my $r=lg_picture_mode_select({},"10.0.0.1","hdrCinema",7);
ok($r->{"verified"},'already-active is verified');
is($r->{"route"},'already-active','...via the already-active route');
is(scalar(grep { $_->{"uri"} =~ /setSystemSettings/ } @requests),0,'...and no write was sent');

# SSAP accepted, TV flips on the second poll
reset_tv(mode => "hdrFilmMaker");
my $writes=0;
$tv->{"on_write"}=sub { $writes++; };
{
 my $polls=0;
 my $orig=\&main::lg_request;
 no warnings qw(redefine once);
 local *main::lg_request=sub (@) {
  my @args=@_;
  if($args[2] eq "settings/getSystemSettings" && $args[1] =~ /poll/) {
   $polls++;
   $tv->{"mode"}="hdrCinema" if($polls == 2);
  }
  return $orig->(@args);
 };
 $r=lg_picture_mode_select({},"10.0.0.1","hdrCinema",7);
}
ok($r->{"verified"},'SSAP write verified once the TV reads the token back');
is($r->{"route"},'ssap','...over the settings route');
is($r->{"polls"},2,'...after two polls');
is($r->{"readbacks"},2,'...both of which answered');
is($r->{"before"},'hdrFilmMaker','before is the pre-write mode');
is($r->{"after"},'hdrCinema','after is the post-write mode');
is($writes,1,'exactly one write went out');
my @poll_ids=map { $_->{"id"} } grep { $_->{"id"} =~ /^get_picture_mode_poll_/ } @requests;
is(scalar(@poll_ids),2,'each poll has its own request id');
isnt($poll_ids[0],$poll_ids[1],'...and they differ');

# token rejected by the settings service -> Luna is not tried
reset_tv(mode => "hdrCinema", script => [ $NO_MATCH ]);
$r=lg_picture_mode_select({},"10.0.0.1","cinema",7);
ok(!$r->{"verified"},'a rejected token is not verified');
is(scalar(@{$r->{"attempts"}}),1,'...and the alert bridge is not tried with the same token');
is($r->{"polls"},0,'...nor polled');
my $failure=lg_picture_mode_select_failure("cinema",$r);
is($failure->{"error_code"},'picture-mode-not-applied','rejected token reports not-applied');
like($failure->{"message"},qr/rejected picture mode 'cinema'/,'...names the rejection');
like($failure->{"message"},qr/was on 'hdrCinema' before/,'...and the mode it was on (no post-write readback exists to call current)');
like($failure->{"message"},qr/Magic Remote/,'...and offers the remote');
like($failure->{"repair_hint"},qr/Magic Remote/,'...as the repair hint');

# SSAP accepted but the mode does not take; Luna does
reset_tv(mode => "dolbyHdrCinema");
$tv->{"on_write"}=sub { my ($route)=@_; $tv->{"mode"}="dolbyHdrCinemaBright" if($route eq "luna"); };
$r=lg_picture_mode_select({},"10.0.0.1","dolbyHdrCinemaBright",7);
ok($r->{"verified"},'Luna fallback verified by readback');
is($r->{"route"},'luna','...over the alert bridge');
is(scalar(@{$r->{"attempts"}}),2,'...after the settings route was tried first');
ok(!$r->{"attempts"}[0]{"failed"},'the settings route did not error');
is($r->{"attempts"}[0]{"readback"},'dolbyHdrCinema','...but read the old mode back');

# readback matching is case-insensitive
reset_tv(mode => "dolbyHdrCinema");
$tv->{"on_write"}=sub { $tv->{"mode"}="dolbyHdrCinemabright"; };
$r=lg_picture_mode_select({},"10.0.0.1","dolbyHdrCinemaBright",7);
ok($r->{"verified"},'a readback differing only in case verifies');

# TV goes silent after the write
reset_tv(mode => "hdrFilmMaker");
$tv->{"on_write"}=sub { $tv->{"silent"}=1; };
$r=lg_picture_mode_select({},"10.0.0.1","hdrCinema",7);
ok(!$r->{"verified"},'a silent TV is not verified');
ok($r->{"polls"} > 0,'...it was polled');
is($r->{"readbacks"},0,'...and never answered');
is($r->{"after"},'','after is empty, not the stale pre-write value');
$failure=lg_picture_mode_select_failure("hdrCinema",$r);
is($failure->{"error_code"},'picture-mode-readback-lost','silence reports readback-lost');
like($failure->{"message"},qr/stopped answering/,'...and says so');
like($failure->{"message"},qr/was on 'hdrFilmMaker' before/,'...naming the pre-write mode as history, not as current');
unlike($failure->{"message"},qr/still reports/,'...never as "still reports"');
unlike($failure->{"message"},qr/SDR\/HDR\/Dolby Vision signal/,'...and does not blame the signal');

# close frame on the write is a failure, and Luna is still tried
reset_tv(mode => "hdrFilmMaker", script => [ { type => "close", error => "Connection closed" } ]);
$r=lg_picture_mode_select({},"10.0.0.1","hdrCinema",7);
ok(!$r->{"verified"},'a close frame on the write is not verified');
ok($r->{"attempts"}[0]{"failed"},'...the settings attempt is marked failed');
is($r->{"attempts"}[0]{"error"},'Connection closed','...with the close reason');
is(scalar(@{$r->{"attempts"}}),2,'...and the alert bridge was still tried');

# both routes accepted, mode never takes -> per-route message
reset_tv(mode => "hdrFilmMaker");
$r=lg_picture_mode_select({},"10.0.0.1","hdrCinema",7);
ok(!$r->{"verified"},'a mode that never takes is not verified');
$failure=lg_picture_mode_select_failure("hdrCinema",$r);
is($failure->{"error_code"},'picture-mode-not-applied','...reports not-applied');
like($failure->{"message"},qr/TV still reports 'hdrFilmMaker'/,'...with a real post-write readback');
like($failure->{"message"},qr/settings route accepted the change but the mode did not take/,'...and says the settings route accepted it');
like($failure->{"message"},qr/alert-bridge fallback accepted/,'...and what the bridge did');

# A legacy alert-bridge acknowledgement is not the same as an active-mode
# readback. Keep it as the requested DDC target, but require confirmation on
# the TV and never invent active_picture_mode.
{
 no warnings qw(redefine once);
 local *main::lg_authenticated_session=sub (@) {
  return { status => "ok", session => {}, client_key => "k", system_info => {}, software_info => {}, hello_info => {} };
 };
 local *main::lg_generation_info=sub (@) { return { ddc_only_white_balance => 1 }; };
 local *main::lg_luna_request=sub (@) { return $OK; };
 local *main::lg_palm_picture_setting=sub (@) { return ""; };
 local *main::lg_current_picture_mode=sub (@) { return ""; };
 local *main::lg_ddc_virtual_picture_settings=sub (@) { return {}; };
 local *main::websocket_close=sub (@) { return 1; };
 my $legacy=lg_picture_set_workflow(
  "10.0.0.1","k",5,{ pictureMode => "hdrFilmMaker" },["pictureMode"],"",
  0,"",0,0,0,0,"hdr10"
 );
 is($legacy->{status},'ok','an accepted legacy bridge command remains usable as a DDC target');
 ok(!$legacy->{picture_mode_verified},'the silent legacy readback is explicitly unverified');
 ok($legacy->{manual_confirmation_required},'the operator is asked to confirm the TV mode');
 is($legacy->{requested_picture_mode},'hdrFilmMaker','the requested mode is retained separately');
 ok(!exists($legacy->{active_picture_mode}),'the response does not invent an active TV mode');
}

{
 my $read_count=0;
 no warnings qw(redefine once);
 local *main::lg_authenticated_session=sub (@) {
  return { status => "ok", session => {}, client_key => "k", system_info => {}, software_info => {}, hello_info => {} };
 };
 local *main::lg_generation_info=sub (@) { return { ddc_only_white_balance => 1 }; };
 local *main::lg_luna_request=sub (@) { return $OK; };
 local *main::lg_palm_picture_setting=sub (@) { return (++$read_count == 1) ? "hdrCinema" : "hdrFilmMaker"; };
 local *main::lg_ddc_virtual_picture_settings=sub (@) { return {}; };
 local *main::websocket_close=sub (@) { return 1; };
 my $legacy=lg_picture_set_workflow(
  "10.0.0.1","k",5,{ pictureMode => "hdrFilmMaker" },["pictureMode"],"",
  0,"",0,0,0,0,"hdr10"
 );
 ok($legacy->{picture_mode_verified},'a matching legacy readback verifies the switch');
 is($legacy->{active_picture_mode},'hdrFilmMaker','only verified readback is reported active');
 ok(!$legacy->{manual_confirmation_required},'verified legacy selection needs no manual confirmation');
}

# ---------------------------------------------------------------------------
# Apply to All Inputs
# ---------------------------------------------------------------------------
is(lg_apply_all_inputs_generation_support({ platform_year => 2025 }),1,'C1+ platform years support apply-all');
is(lg_apply_all_inputs_generation_support({ platform_year => 2020 }),0,'pre-C1 platform years do not support apply-all');
is(lg_apply_all_inputs_generation_support({ series => 'C1' }),1,'C1 series supports apply-all');
is(lg_apply_all_inputs_generation_support({ series => 'CX' }),0,'CX series does not support apply-all');
is(lg_apply_all_inputs_generation_support({}),-1,'unclassified generations remain unknown');
is(lg_picture_mode_for_calibration('technicolor'),'technicolorExpert','raw Technicolor mode keeps its calibration namespace');
is(lg_picture_mode_for_calibration('hdrTechnicolor'),'hdr_technicolorExpert','raw HDR Technicolor mode keeps its calibration namespace');
{
 my ($confirmed,$acknowledged,$msg)=lg_apply_all_inputs_outcome("cinema","luna","done","",1);
 ok($confirmed,'applyToAllInput=done confirms');
 ok(!$acknowledged,'...a Luna dispatch is still not an acknowledgement');
 like($msg,qr/reports the all-inputs action as done/,'...and the message says done');
 ($confirmed,$acknowledged,$msg)=lg_apply_all_inputs_outcome("cinema","luna","done","",0);
 ok(!$confirmed,'a resting done value without a fresh picture state does not confirm');
 ($confirmed,$acknowledged,$msg)=lg_apply_all_inputs_outcome("cinema","luna","","",0);
 ok(!$confirmed,'no readback does not confirm');
 like($msg,qr/dispatched over the alert bridge/,'...and is reported as a dispatch');
 like($msg,qr/no readback/,'...with no readback');
 ($confirmed,$acknowledged,$msg)=lg_apply_all_inputs_outcome("cinema","ssap","picture");
 ok($acknowledged && !$confirmed,'SSAP accepted but not done is acknowledged only');
 like($msg,qr/read back 'picture'/,'...quoting the readback');
}

{
 no warnings qw(redefine once);
 local *main::lg_authenticated_session=sub (@) {
  return {
   status => "ok",
   session => {},
   client_key => "k",
   system_info => { modelName => "OLED83G54LW" },
   software_info => { model_name => "HE_DTV_W25O", product_name => "webOSTV 25" },
   hello_info => {},
  };
 };
 local *main::websocket_close=sub (@) { 1 };
 # G5 path: SSAP rejects the key, Luna dispatches, the read settles to done
 reset_tv(mode => "cinema", apply_state => "done", apply_states => ["picture","done"],
  script => [ { type => "error", error => "500 error", payload => { errorText => "Some keys are not allowed for the request. ( applyToAllInput )" } } ]);
 my $res=lg_picture_apply_all_inputs_workflow("10.0.0.1","k",5);
 is($res->{"status"},'ok','apply-all via Luna succeeds');
 is($res->{"transport"},'luna','...over the alert bridge');
 ok($res->{"confirmed"},'...and is confirmed by applyToAllInput=done');
 ok($res->{"transition_seen"},'...after observing the fresh picture state');
 is($res->{"readback"},'done','...with the readback reported');
 is($res->{"active_picture_mode"},'cinema','...naming the copied mode');
 is(scalar(grep { $_->{"id"} =~ /^apply_all_inputs_poll_/ && $_->{"timeout"} > 2 } @requests),0,'apply-all readback calls use the bounded timeout');

 # The command has no mode argument, so a supported TV may apply even when
 # its active picture-mode read is unavailable.
 reset_tv(mode => "", apply_state => "done");
 $res=lg_picture_apply_all_inputs_workflow("10.0.0.1","k",5);
 is($res->{"status"},'ok','a supported TV can apply-all without an active-mode readback');
 is($res->{"active_picture_mode"},'','...and does not invent a mode name');
 like($res->{"message"},qr/for the active picture mode/,'...using a truthful generic result');
 # both routes fail: both errors surface
 reset_tv(mode => "cinema", script => [
  { type => "error", error => "500 error", payload => { errorText => "Some keys are not allowed for the request. ( applyToAllInput )" } },
  { type => "error", error => "LG TV did not return an alertId for Luna request", payload => {} },
 ]);
 $res=lg_picture_apply_all_inputs_workflow("10.0.0.1","k",5);
 is($res->{"status"},'error','apply-all fails when both routes fail');
 like($res->{"message"},qr/settings route: .*Some keys are not allowed/,'...naming the settings-route error');
 like($res->{"message"},qr/alert bridge: .*alertId/,'...and the alert-bridge error');
 is($res->{"luna_error"},'LG TV did not return an alertId for Luna request','...with luna_error in the envelope');
 # G5 path with the readback refused: Luna dispatched, one rejected read, no confirmation
 reset_tv(mode => "hdrFilmMaker", apply_read_rejected => 1,
  script => [ { type => "error", error => "500 error", payload => { errorText => "Some keys are not allowed for the request. ( applyToAllInput )" } } ]);
 $res=lg_picture_apply_all_inputs_workflow("10.0.0.1","k",5);
 is($res->{"status"},'ok','a refused readback is still a dispatch, not a failure');
 ok(!$res->{"confirmed"} && !$res->{"acknowledged"},'...but neither confirmed nor acknowledged');
 like($res->{"readback_error"},qr/Some keys are not allowed/,"...with the TV's refusal in the envelope");
 like($res->{"message"},qr/does not allow the applyToAllInput readback/,'...and in the message');
 is(scalar(grep { $_->{"id"} =~ /^apply_all_inputs_poll_/ } @requests),1,'...after exactly one rejected poll');
 # close frame on the SSAP write is not "applied"
 reset_tv(mode => "cinema", apply_state => "done", script => [ { type => "close", error => "Connection closed" }, undef ]);
 $tv->{"on_write"}=sub { $tv->{"silent"}=1; };
 $res=lg_picture_apply_all_inputs_workflow("10.0.0.1","k",5);
 is($res->{"status"},'error','a dropped session is not reported as applied');
 like($res->{"message"},qr/Connection closed/,'...and names the close');

 # C8/C9/CX do not expose applyToAllInput. Reject before any write instead
 # of treating an alert lifecycle as a successful TV command.
 {
  local *main::lg_authenticated_session=sub (@) {
   return {
    status => "ok",
    session => {},
    client_key => "k",
    system_info => { modelName => "OLED65C8PLA" },
    software_info => { model_name => "HE_DTV_W18H", product_name => "webOSTV 4" },
    hello_info => {},
   };
  };
  reset_tv(mode => "cinema");
  $res=lg_picture_apply_all_inputs_workflow("10.0.0.1","k",5);
  is($res->{"status"},'error','C8 apply-all is rejected');
  is($res->{"error_code"},'apply-all-inputs-unsupported','...with a generation-specific error');
  is(scalar(@requests),0,'...before sending any TV request');
 }

 # Unknown models may use a positively acknowledged public route, but must
 # not fall back to the Luna bridge after rejection.
 {
  local *main::lg_authenticated_session=sub (@) {
   return { status => "ok", session => {}, client_key => "k", system_info => {}, software_info => {}, hello_info => {} };
  };
  reset_tv(mode => "cinema", script => [ $NO_MATCH ]);
  $res=lg_picture_apply_all_inputs_workflow("10.0.0.1","k",5);
  is($res->{"status"},'error','an unclassified TV does not use Luna after public-route rejection');
  is($res->{"error_code"},'apply-all-inputs-support-unknown','...with an explicit support error');
  is(scalar(grep { $_->{"uri"} =~ /^luna:/ } @requests),0,'...and no alert-bridge request');
 }
}

# ---------------------------------------------------------------------------
# Web UI safety contracts
# ---------------------------------------------------------------------------
my $lg_js=webui_lg_js();
like($lg_js,qr/let lgApplyAllInputsPending=false;/,'the UI tracks an apply-all operation independently');
like($lg_js,qr/modeActionsDisabled=.*lgApplyAllInputsPending/,'status renders cannot re-enable mode actions mid-apply');
unlike($lg_js,qr/lgRememberPictureMode\(value,signal\);\s*lgPictureModePending=true/s,'a requested mode is not cached before TV verification');
like($lg_js,qr/if\(r\.picture_mode_verified===true\) lgRememberPictureMode\(mode,signal\);/,
 'an unverified legacy mode is not persisted as the active TV mode');
like($lg_js,qr/r\.manual_confirmation_required\|\|r\.virtual_picture_settings/,
 'the UI warns when legacy mode selection needs confirmation on the TV');
like($lg_js,qr/\['hdrEco','HDR Auto Power Save'\]/,'the C2+ HDR Auto Power Save mode is offered');
like($lg_js,qr/\['technicolor','SDR Technicolor Expert'\]/,'the C8/C9 Technicolor mode is offered');

# ---------------------------------------------------------------------------
# Helper timeout message
# ---------------------------------------------------------------------------
like(lg_helper_timeout_message({ action => "picture_set", settings => { pictureMode => "cinema" } },45),qr/picture-mode change/,'a mode-only picture_set times out as a mode change');
like(lg_helper_timeout_message({ action => "picture_set", settings => { whiteBalanceRed => [] } },150),qr/white-balance/,'a white-balance picture_set keeps its message');
like(lg_helper_timeout_message({ action => "picture_apply_all_inputs" },60),qr/Apply to All Inputs/,'apply-all has its own message');

done_testing();
