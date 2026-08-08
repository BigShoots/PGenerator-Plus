#!/usr/bin/env perl
use strict;
use warnings;
no warnings 'once'; # The isolated workflow harness intentionally uses package globals.
use FindBin;
use Test::More;

my $path="$FindBin::Bin/../usr/sbin/pgenerator-lg";
open(my $fh,'<',$path) or die "open $path: $!";
my $source=do { local $/; <$fh> };
close($fh);

# Extraction relies on the file's convention that only a sub's own closing
# brace sits in column 0. BAIL_OUT on a miss so a failed extraction reads as
# "the source changed shape", not as a confusing runtime die further down.
sub extract_sub {
 my $name=shift;
 my ($sub)=$source=~/(sub \Q$name\E \(\@\) \{.*?^\})/ms;
 ok($sub,"$name is present") or BAIL_OUT("could not extract sub $name from $path");
 return $sub;
}

# --- lg_picture_mode_ssap_payload -------------------------------------------

{
 my $payload_sub=extract_sub('lg_picture_mode_ssap_payload');
 package LGPictureModePayloadTest;
 eval "$payload_sub\n1;" or die $@;
}

is_deeply(
 LGPictureModePayloadTest::lg_picture_mode_ssap_payload('filmMaker'),
 {
  category => 'picture',
  settings => { pictureMode => 'filmMaker' },
 },
 'picture-mode selection uses the minimal public WebOS settings payload',
);
is_deeply(
 LGPictureModePayloadTest::lg_picture_mode_ssap_payload(undef),
 {
  category => 'picture',
  settings => { pictureMode => '' },
 },
 'an undefined picture mode degrades to an empty payload value instead of dying',
);

# --- lg_picture_mode_readback_matches ---------------------------------------

{
 my $code=join("\n",
  extract_sub('lg_picture_mode_readback_canonical'),
  extract_sub('lg_picture_mode_readback_matches'));
 package LGPictureModeReadbackTest;
 eval "$code\n1;" or die $@;
}

sub readback_matches { return LGPictureModeReadbackTest::lg_picture_mode_readback_matches(@_); }

ok(readback_matches('filmMaker','filmMaker'),
 'matching picture-mode readback is accepted');
ok(!readback_matches('filmMaker','cinema'),
 'stale picture-mode readback is rejected');
ok(readback_matches('dolbyHdrCinema','dolbyHdrCinemaDark'),
 'the C1/C2 Dolby Vision readback-only label matches its write value');
ok(readback_matches('dolbyHdrCinema','dolby_hdr_cinema_dark'),
 'the C1 separator-form Dolby Vision readback matches its write value');
ok(readback_matches('dolbyHdrCinemaDark','dolbyHdrCinema'),
 'Dolby Vision readback equivalence holds in both directions');
ok(!readback_matches('dolbyHdrCinema','dolbyHdrCinemaBright'),
 'Dolby Vision Cinema and Cinema Bright remain distinct');
ok(readback_matches('game','gameOptimizer'),
 'the Game Optimizer readback label matches the game enum');
ok(!readback_matches('standard','aps'),
 'Energy Saving (aps) readback does not verify a standard request');
ok(!readback_matches('standard','eco'),
 'Eco readback does not verify a standard request');
ok(!readback_matches('vivid','sports'),
 'Sports readback does not verify a vivid request');
ok(!readback_matches('cinema','cinemaHome'),
 'Cinema Home readback does not verify a cinema request');
ok(readback_matches('FILMMAKER','filmMaker'),
 'case differences in enum names are tolerated');
ok(readback_matches('hdrFilmMaker','hdr_filmmaker'),
 'separator differences in enum names are tolerated');
ok(!readback_matches('hdrCinema','hdrStandard'),
 'different HDR modes are rejected');
ok(readback_matches('unknownMode','unknownMode'),
 'identical unmapped mode names still verify');
ok(!readback_matches('unknownModeA','unknownModeB'),
 'different unmapped mode names are rejected');
ok(!readback_matches('filmMaker',''),
 'an empty readback value is never treated as verified');
ok(!readback_matches('filmMaker',undef),
 'an undefined readback value is never treated as verified');
ok(!readback_matches('','cinema'),
 'an empty requested mode is never treated as verified');

# --- lg_picture_set_workflow: source-shape checks ---------------------------

my $workflow=extract_sub('lg_picture_set_workflow');
like(
 $workflow,
 qr/"settings\/setSystemSettings",\s*\$set_payload/s,
 'picture-mode write uses public SSAP setSystemSettings',
);
unlike(
 $workflow,
 qr/set_picture_mode_active_app/,
 'the current_app-scoped Luna alert write path is not reintroduced',
);
like(
 $workflow,
 qr/if\(\$picture_mode_readback_supported\).*?push\(\@\{\$readback_keys\},"pictureMode"\)/s,
 'readable picture-mode requests gain a pictureMode readback key',
);
like(
 $workflow,
 qr/\$generation->\{"picture_mode_read_forbidden"\}.*?\$picture_mode_readback_required/s,
 'generation metadata prevents mandatory readback on read-forbidden sets',
);
like(
 $workflow,
 qr/get_picture_mode_after_.*?settings\/getSystemSettings/s,
 'picture-mode selection performs a separate readback poll',
);
like(
 $workflow,
 qr/if\(&lg_picture_mode_readback_matches\(\$active_picture_mode,\$observed_picture_mode\)\)/,
 'the poll verifies the observed mode through the readback matcher',
);
like(
 $workflow,
 qr/if\(\$picture_mode_readback_required && !\$picture_mode_readback_verified\) \{.*?picture-mode-readback-mismatch/s,
 'an unverified picture-mode readback is reported as failure',
);

# PR #30 predates the C1 Dolby Vision 3D LUT routing fix on the test branch.
# Keep that later behaviour pinned while integrating its picture-mode path.
my $lut_resolver=extract_sub('lg_3d_lut_resolve_mode');
like(
 $lut_resolver,
 qr/lg_resolve_ddc_picture_mode\(\$ip,\$picture_mode,\$signal_mode\)/,
 '3D LUT DDC resolution still receives the active signal mode',
);
like(
 $lut_resolver,
 qr/generation_id.*?lg2021_oled.*?\$signal_mode.*?dv.*?dolbyVisionFilmMaker/s,
 'C1 Dolby Vision 3D LUT routing still targets the hardware-proven dark mode',
);

# --- lg_picture_set_workflow: behavioural harness ---------------------------
# Run the real workflow sub with the real mapper/matcher and stubbed TV I/O.
# The stubs mirror the response shapes of the real helpers (json_ok,
# json_error, response_is_app_failure) closely enough to drive every branch
# under test without a TV.

{
 my $helpers=join("\n",map { extract_sub($_) } qw(
  map_picture_mode_label_to_ddc_name
  lg_picture_mode_signal_for_canonical_name
  lg_picture_mode_signal_compatible
  lg_picture_mode_signal_examples
  lg_picture_mode_ssap_payload
  lg_picture_mode_readback_canonical
  lg_picture_mode_readback_matches
 ));
my $stubs=<<'STUBS';
our (@READBACK_MODES,@PALM_MODES,@REQUEST_LABELS,@LUNA_LABELS,$SET_RESPONSE,$LUNA_RESPONSE,$GENERATION);
$WRITABLE_PICTURE_MODES_RE=qr/^(?:expert|cinema|filmmaker|game|standard)/;
sub lg_authenticated_session { return { status => "ok", session => {}, client_key => "test-key", hello_info => {}, system_info => {}, software_info => {} }; }
sub lg_generation_info { return $GENERATION||{}; }
sub lg_ddc_has_22pt_rgb { return 0; }
sub lg_picture_mode_for_calibration { return ""; }
sub lg_ddc_1d_target_info { return {}; }
sub lg_ddc_1d_nonzero_map { return {}; }
sub lg_palm_picture_setting { return @PALM_MODES ? shift(@PALM_MODES) : ""; }
sub lg_current_picture_mode { return ""; }
sub lg_ddc_virtual_picture_settings { return {}; }
sub diag_log_append { return; }
sub websocket_close { return; }
sub json_true { return 1; }
sub json_false { return 0; }
sub json_bool { return $_[0] ? 1 : 0; }
sub json_error {
 my ($message,$extra)=@_;
 $extra={} if(ref($extra) ne "HASH");
 $extra->{"status"}="error";
 $extra->{"message"}=$message;
 return $extra;
}
sub json_ok {
 my $extra=shift;
 $extra={} if(ref($extra) ne "HASH");
 $extra->{"status"}="ok";
 return $extra;
}
sub json_permission_error {
 my ($message,$extra)=@_;
 $extra=&json_error($message,$extra);
 $extra->{"error_code"}="insufficient-permissions";
 return $extra;
}
sub response_is_app_failure {
 my $response=shift;
 return (0,"") if(ref($response) ne "HASH");
 return (1,$response->{"error"}||"error envelope") if(($response->{"type"}||"") eq "error");
 my $payload=(ref($response->{"payload"}) eq "HASH") ? $response->{"payload"} : {};
 return (1,"returnValue false") if(defined($payload->{"returnValue"}) && !$payload->{"returnValue"});
 return (0,"");
}
sub lg_request {
 my ($session,$label,$path,$payload,$timeout)=@_;
 push(@REQUEST_LABELS,$label);
 return $SET_RESPONSE if($label eq "set_picture_mode");
 if($label =~ /^get_picture_mode_after_/) {
  return undef if(!@READBACK_MODES);
  my $mode=shift(@READBACK_MODES);
  return { type => "response", payload => { returnValue => 1, settings => { pictureMode => $mode } } };
 }
 return { type => "response", payload => { returnValue => 1, settings => {} } };
}
sub lg_luna_request {
 my ($session,$label,$path,$payload,$timeout)=@_;
 push(@LUNA_LABELS,$label);
 return $LUNA_RESPONSE;
}
STUBS
 package LGWorkflowRunTest;
 eval "no strict;\nno warnings;\n$stubs\n$helpers\n$workflow\n1;" or die $@;
}

sub run_picture_mode_workflow {
 my (%opt)=@_;
 @LGWorkflowRunTest::READBACK_MODES=@{$opt{readback_modes}||[]};
 @LGWorkflowRunTest::PALM_MODES=@{$opt{palm_modes}||[]};
 @LGWorkflowRunTest::REQUEST_LABELS=();
 @LGWorkflowRunTest::LUNA_LABELS=();
 $LGWorkflowRunTest::GENERATION=$opt{generation}||{
  generation_id => "lg2022plus_oled",
  ddc_only_white_balance => 0,
  picture_mode_read_forbidden => 0,
 };
 $LGWorkflowRunTest::SET_RESPONSE=$opt{set_response}
  || { type => "response", payload => { returnValue => 1 } };
 $LGWorkflowRunTest::LUNA_RESPONSE=$opt{luna_response}
  || { type => "response", payload => { returnValue => 1 } };
 return LGWorkflowRunTest::lg_picture_set_workflow(
  "192.0.2.10","test-key",1,
  { pictureMode => $opt{request_mode} },
  [],"hdmi2",0,"",0,0,0,0,$opt{signal_mode}||"sdr");
}

# Scenario 1: readback matches on the first poll attempt.
{
 my $result=run_picture_mode_workflow(request_mode => "filmMaker", readback_modes => ["filmMaker"]);
 is($result->{status},'ok','verified first readback reports success');
 ok($result->{picture_mode_readback_verified},'success payload marks the readback verified');
 is($result->{picture_mode_readback_attempts},1,'success payload counts one readback attempt');
 is($result->{picture_mode_write_path},'ssap://settings/setSystemSettings',
  'verified public write reports its actual SSAP transport');
 is($result->{picture_settings}{pictureMode},'filmMaker','success payload carries the observed mode');
 is(scalar(grep { $_ eq 'set_picture_mode' } @LGWorkflowRunTest::REQUEST_LABELS),1,
  'exactly one SSAP picture-mode write was sent');
}

# Scenario 2: TV needs several polls before the mode lands.
{
 my $result=run_picture_mode_workflow(request_mode => "filmMaker",
  readback_modes => ["cinema","cinema","cinema","filmMaker"]);
 is($result->{status},'ok','late-arriving readback still reports success');
 is($result->{picture_mode_readback_attempts},4,'poll kept reading until the mode was observed');
}

# Scenario 3: TV acknowledges the write but stays on the previous mode.
{
 my $result=run_picture_mode_workflow(request_mode => "filmMaker",
  readback_modes => [("cinema") x 10]);
 is($result->{status},'error','stale readback reports failure, not success');
 is($result->{error_code},'picture-mode-readback-mismatch','stale readback carries the mismatch error code');
 is($result->{observed_picture_mode},'cinema','the mode the TV actually reported is surfaced');
 like($result->{message},qr/remained on 'cinema'/,'failure message names the stale mode');
}

# Scenario 4: TV never returns a usable readback at all.
{
 my $result=run_picture_mode_workflow(request_mode => "filmMaker", readback_modes => []);
 is($result->{status},'error','missing readback reports failure, not success');
 is($result->{error_code},'picture-mode-readback-mismatch','missing readback carries the mismatch error code');
 is($result->{observed_picture_mode},'','no observed mode is reported when the TV never answered');
}

# Scenario 5: SSAP write is refused for permissions; the Luna fallback applies
# the mode and the readback poll still decides success.
{
 my $result=run_picture_mode_workflow(request_mode => "filmMaker",
  set_response => { type => "error", error => "401 insufficient permissions" },
  readback_modes => ["filmMaker"]);
 is($result->{status},'ok','permission-refused SSAP write recovers through the Luna fallback');
 ok($result->{picture_mode_readback_verified},'the Luna fallback result is still readback-verified');
 is($result->{picture_mode_write_path},'luna://com.webos.settingsservice/setSystemSettings',
  'permission fallback reports its actual Luna transport');
 is(scalar(grep { $_ eq 'set_picture_settings_luna' } @LGWorkflowRunTest::LUNA_LABELS),1,
  'the Luna fallback write path was used exactly once');
}

# Scenario 6: C1/B1/G1/Z1 do not expose public pictureMode readback. An
# accepted bridge write must therefore retain the established unverifiable
# success behaviour rather than being turned into a false failure.
{
 my $result=run_picture_mode_workflow(
  request_mode => "filmMaker",
  generation => {
   generation_id => "lg2021_oled",
   ddc_only_white_balance => 1,
   picture_mode_read_forbidden => 1,
  },
 );
 is($result->{status},'ok','read-forbidden C1 bridge write remains successful');
 ok(!$result->{picture_mode_verified},'empty C1 readback is explicitly unverifiable');
 is(scalar(grep { $_ eq 'set_picture_mode' } @LGWorkflowRunTest::REQUEST_LABELS),0,
  'read-forbidden C1 does not use the public SSAP picture-mode write');
 is(scalar(grep { $_ eq 'set_picture_mode_palm-bridge' } @LGWorkflowRunTest::LUNA_LABELS),1,
  'read-forbidden C1 uses its established bridge transport once');
}

# Scenario 7: a C1 may report the dark Dolby Vision mode using its
# separator-form readback enum. It is a verified match, not a separate mode.
{
 my $result=run_picture_mode_workflow(
  request_mode => "dolbyVisionFilmMaker",
  signal_mode => "dv",
  palm_modes => ["","dolby_hdr_cinema_dark"],
  generation => {
   generation_id => "lg2021_oled",
   ddc_only_white_balance => 1,
   picture_mode_read_forbidden => 1,
  },
 );
 is($result->{status},'ok','C1 separator-form Dolby Vision readback reports success');
 is($result->{active_picture_mode},'dolbyHdrCinema','C1 dark Dolby Vision request uses the accepted WebOS write enum');
 ok($result->{picture_mode_verified},'C1 separator-form Dolby Vision readback is verified');
}

done_testing();
