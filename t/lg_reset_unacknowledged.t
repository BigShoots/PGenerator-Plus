use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use JSON::PP ();

BEGIN {
 package IO::Socket::SSL;
 sub import { }
 $INC{'IO/Socket/SSL.pm'}=__FILE__;
}

# The reset workflows must treat a step whose reply never arrived (recv
# timeout / dead socket => undef) as UNACKNOWLEDGED, not as success.
# response_is_app_failure() alone reports undef as "not failed", so a socket
# that died right after CAL_START used to turn the whole reset into a false
# success -- which then cleared the persisted calibration-session flag every
# stuck-session recovery path depends on. lg_calibration_mode_workflow already
# carried the correct `|| ref($response) ne "HASH"` idiom; these tests pin the
# same contract onto the reset step gates.

my $helper="$Bin/../usr/sbin/pgenerator-lg";
do $helper;
die $@ if($@);
die "Failed to load $helper" if(!defined(&response_is_app_failure_or_unacknowledged));
$SIG{INT}="DEFAULT";
$SIG{TERM}="DEFAULT";

# --- unit: the acknowledgement gate ---
my ($f,$m)=response_is_app_failure_or_unacknowledged(undef);
ok($f,'undef (recv timeout / dead socket) is unacknowledged');
like($m,qr/did not acknowledge/i,'timeout message says so');
($f,$m)=response_is_app_failure_or_unacknowledged({type=>'close',error=>'peer closed'});
ok($f,'a close frame is a failure');
($f,$m)=response_is_app_failure_or_unacknowledged({type=>'response',payload=>{returnValue=>JSON::PP::true}});
ok(!$f,'a real acknowledgement passes');
($f,$m)=response_is_app_failure_or_unacknowledged({type=>'response'});
ok($f,'a response envelope without returnValue is not an acknowledgement');
($f,$m)=response_is_app_failure_or_unacknowledged({type=>'skipped',payload=>{returnValue=>JSON::PP::true}});
ok($f,'a synthetic/skipped envelope is not an acknowledgement');
($f,$m)=response_is_app_failure_or_unacknowledged({type=>'response',payload=>{returnValue=>JSON::PP::false,errorMessage=>'rejected'}});
ok($f,'returnValue=false stays a failure');

# The weaker sibling used for the reset DATA/UI steps: it closes the
# dead-socket false-success hole without imposing the strict returnValue
# criterion (hardware-proven only for CAL_END) on writes that were never
# gated on it -- a deliberate difference, pinned here.
($f,$m)=response_is_app_failure_or_missing(undef);
ok($f,'missing-variant: undef is a failure');
($f,$m)=response_is_app_failure_or_missing({type=>'close',error=>'peer closed'});
ok($f,'missing-variant: a close frame is a failure');
($f,$m)=response_is_app_failure_or_missing({type=>'response'});
ok(!$f,'missing-variant: a response without returnValue passes (no new hardware assumption)');
($f,$m)=response_is_app_failure_or_missing({type=>'response',payload=>{returnValue=>JSON::PP::false}});
ok($f,'missing-variant: returnValue=false stays a failure');

# --- scripted workflow: dead socket after CAL_START must fail the HDR reset ---
my $ack={ type=>'response', payload=>{ returnValue=>JSON::PP::true } };
sub run_hdr_reset_with_responses {
 my ($responder)=@_;
 my $result;
 {
  no warnings qw(redefine once);
  local *main::lg_authenticated_session=sub (@) {
   return { status=>'ok', session=>{}, client_key=>'k', hello_info=>{}, system_info=>{}, software_info=>{} };
  };
  local *main::lg_generation_info=sub (@) { return {}; };
  local *main::lg_3d_lut_resolve_mode=sub (@) { return ('hdr_cinema','hdr_cinema'); };
  local *main::lg_hdr_picture_reset_apply_dynamic_contrast_off=sub (@) { return (1,[]); };
  local *main::lg_calibration_request=sub (@) {
   my ($session,$request_id,$command)=@_;
   return $responder->($command);
  };
  local *main::websocket_close=sub (@) { return 1; };
  local *main::diag_log_append=sub (@) { return 1; };
  $result=lg_hdr_calman_reset_workflow('10.0.0.1','k',5,'','');
 }
 return $result;
}

# All steps acknowledged: reset succeeds.
my $result=run_hdr_reset_with_responses(sub { return $ack; });
is($result->{status},'ok','a fully acknowledged HDR reset succeeds');

# Socket dies after CAL_START: every later reply is undef. The old gate saw
# "not failed" everywhere and returned ok (clearing the held-session flag).
$result=run_hdr_reset_with_responses(sub {
 my ($command)=@_;
 return $ack if($command eq 'CAL_START');
 return undef;
});
is($result->{status},'error','a dead socket after CAL_START fails the reset')
 or diag(JSON::PP->new->canonical(1)->encode($result));
like($result->{message},qr/rejected commands/i,'the failure is reported, not silently absorbed');

# Only CAL_END lost: still a failure -- the session end was never confirmed.
$result=run_hdr_reset_with_responses(sub {
 my ($command)=@_;
 return undef if($command eq 'CAL_END');
 return $ack;
});
is($result->{status},'error','an unacknowledged CAL_END alone fails the reset');

# --- unmapped picture-mode tokens can never reach the TV as a write value ---
# (The C2 dolbyHdr* alt-case runtime retry was deleted because the label map
# resolves every known variant and returns "" for anything unmapped -- pin
# that invariant so a future mapping change cannot silently pass raw tokens.)
is(map_picture_mode_label_to_ddc_name('utterly unknown mode','dv'),'', 'an unmapped DV label resolves to nothing, never a raw write value');
is(map_picture_mode_label_to_ddc_name('','sdr'),'','an empty label resolves to nothing');
is(map_picture_mode_label_to_ddc_name('DV FilmMaker','dv'),'dolbyHdrCinema','the FilmMaker family resolves to the accepted enum');

# --- retryable-failure classifier fed REAL result shapes ---
ok(!lg_3d_lut_upload_retryable_failure({ status=>'error', message=>'401 insufficient permissions' }),
 'insufficient permissions is never retried (re-pairing, not re-uploading, fixes it)');
ok(!lg_3d_lut_upload_retryable_failure({ status=>'error', message=>'LG 3D LUT payload must be 33x33x33 uint16 (215622 bytes)' }),
 'a payload-shape rejection is permanent');
ok(lg_3d_lut_upload_retryable_failure({ status=>'error', message=>'LG TV did not confirm calibration mode end after the 3D LUT write.', upload_write_verified=>JSON::PP::true }),
 'an unconfirmed CAL_END stays retryable: a fresh socket re-runs the full CAL_START/write/CAL_END');
ok(lg_3d_lut_upload_retryable_failure({ status=>'error', message=>'WebOS websocket connection closed' }),
 'a transport drop is retryable');

done_testing();
