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
die "Failed to load $helper" if(!defined(&lg_3d_lut_upload_workflow));
$SIG{INT}="DEFAULT";
$SIG{TERM}="DEFAULT";

ok(lg_calibration_end_confirmed({type=>'response',payload=>{returnValue=>JSON::PP::true()}},0,0),'a successful CAL_END response confirms the commit');
ok(!lg_calibration_end_confirmed({type=>'response'},0,0),'a response envelope without returnValue cannot confirm CAL_END');
ok(!lg_calibration_end_confirmed({type=>'response',payload=>{returnValue=>JSON::PP::false()}},0,0),'returnValue=false cannot confirm CAL_END');
ok(!lg_calibration_end_confirmed({type=>'skipped',payload=>{returnValue=>JSON::PP::true()}},0,0),'a skipped diagnostic envelope cannot confirm CAL_END');
ok(!lg_calibration_end_confirmed({type=>'close'},1,0),'a failed CAL_END cannot confirm the commit');
ok(!lg_calibration_end_confirmed(undef,0,0),'a missing CAL_END response cannot confirm the commit');
ok(lg_calibration_end_confirmed({type=>'error'},1,1),'an explicitly tolerated generation-specific response remains valid');

{
 no warnings 'once';
 $main::LG_3D_LUT_UPLOAD_RETRY_DELAY=0;
}

sub run_scripted_upload {
 my (@responses)=@_;
 my $calls=0;
 my $result;
 {
  no warnings qw(redefine once);
  local *main::lg_3d_lut_upload_workflow_inner=sub (@) {
   $calls++;
   return shift(@responses);
  };
  local *main::diag_log_append=sub (@) { return 1; };
  $result=lg_3d_lut_upload_workflow('10.0.0.1','key',5,'hdrFilmMaker','/tmp/lut.bin','BT2020_3D_LUT_DATA','GET_3D_LUT_DATA',1,0,'hdr10');
 }
 return ($result,$calls);
}

my ($result,$calls)=run_scripted_upload(
 { status=>'error', message=>'WebOS websocket connection closed' },
 { status=>'error', message=>'LG TV did not answer the upload command' },
 { status=>'ok', upload_verified=>JSON::PP::true(), message=>'verified' },
);
is($calls,3,'transient failures open three complete upload attempts before success');
is($result->{status},'ok','the eventual verified response is returned');
ok($result->{upload_verified},'the successful retry remains verified');
is($result->{transport_attempt_count},3,'all transport attempts are counted');
is($result->{transport_retry_count},2,'two retries are reported');
is(scalar(@{$result->{transport_attempts}}),3,'each attempt is retained for diagnosis');

($result,$calls)=run_scripted_upload(
 { status=>'error', message=>'3D LUT payload must be a 33x33x33 little-endian uint16 file with 12-bit RGB values.' },
 { status=>'ok', upload_verified=>JSON::PP::true(), message=>'must not run' },
);
is($calls,1,'a permanent payload error is not retried');
ok(!$result->{retry_exhausted},'a permanent error is not labelled retry exhaustion');

($result,$calls)=run_scripted_upload(
 { status=>'error', message=>'Connect / Pair the LG TV before uploading a 3D LUT', needs_repair=>JSON::PP::true() },
 { status=>'ok', upload_verified=>JSON::PP::true(), message=>'must not run' },
);
is($calls,1,'a pairing repair requirement is returned immediately');

($result,$calls)=run_scripted_upload(
 map { { status=>'error', message=>'connection timed out '.$_ } } 1..4
);
is($calls,4,'a transient failure receives the bounded maximum of four attempts');
is($result->{status},'error','exhaustion remains an error');
ok($result->{retry_exhausted},'retry exhaustion is explicit');
is($result->{transport_retry_count},3,'the exhausted response reports three retries');

($result,$calls)=run_scripted_upload(
 { status=>'ok', upload_verified=>JSON::PP::false(), message=>'write answered but readback did not verify' },
 { status=>'ok', upload_verified=>JSON::PP::true(), message=>'verified' },
);
is($calls,2,'an unverified nominal response is retried');
ok($result->{upload_verified},'only a verified response terminates successfully');

($result,$calls)=run_scripted_upload(
 map { { status=>'ok', upload_verified=>JSON::PP::false(), message=>'write answered but readback did not verify '.$_ } } 1..4
);
is($calls,4,'nominal but unverified responses use every bounded attempt');
is($result->{status},'error','unverified retry exhaustion is converted to an error');
is($result->{error_code},'3d-lut-upload-not-verified','unverified exhaustion has a stable error code');
ok($result->{retry_exhausted},'unverified exhaustion is explicit');

($result,$calls)=run_scripted_upload(
 undef,
 { status=>'ok', upload_verified=>JSON::PP::true(), message=>'verified' },
);
is($calls,2,'an invalid helper response is treated as a transient transport failure');
ok($result->{upload_verified},'an invalid response cannot prevent a later verified retry');

{
 no warnings 'once';
 # Deadline already in the past: the first attempt runs, but no retry may
 # start because the helper's `timeout` wrapper would kill it mid-write.
 local $main::LG_3D_LUT_UPLOAD_DEADLINE=time()-1;
 ($result,$calls)=run_scripted_upload(
  { status=>'error', message=>'connection timed out' },
  { status=>'ok', upload_verified=>JSON::PP::true(), message=>'must not run' },
 );
 is($calls,1,'no retry starts once the helper timeout budget is exhausted');
 is($result->{status},'error','the last real failure is returned instead of a SIGTERM');
 ok(!$result->{retry_exhausted},'a deadline stop is not reported as retry exhaustion');
}

done_testing();
