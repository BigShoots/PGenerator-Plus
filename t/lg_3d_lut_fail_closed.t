use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin qw($Bin);

my $worker="$Bin/../usr/bin/meter_lg_3d_autocal.pl";
do $worker;
die $@ if($@);
die "Failed to load $worker" if(!defined(&autocal3d_commit_error));
die "Failed to load shadow terminal classifier" if(!defined(&hdr20_postcal_best_status));
$SIG{INT}="DEFAULT";
$SIG{TERM}="DEFAULT";

is(hdr20_postcal_best_status(1,0.049,0.829,0.05),'converged','a best pass inside tolerance is converged');
is(hdr20_postcal_best_status(1,0.067,0.829,0.05),'best_effort','an improved pass outside tolerance is not mislabeled converged');
is(hdr20_postcal_best_status(1,0.829,0.829,0.05),'reverted','a pass that does not beat baseline is reverted');

sub read_source {
 my ($path)=@_;
 open(my $fh,"<:raw",$path) or die "Unable to read $path: $!";
 local $/;
 my $source=<$fh>;
 close($fh);
 return $source;
}

is(autocal3d_commit_error({upload=>0},{upload_verified=>0}),'','an export-only run does not require a TV commit');
like(
 autocal3d_commit_error({upload=>1},{upload_verified=>0,upload_message=>'websocket closed'}),
 qr/not verified.*websocket closed/i,
 'a requested but unverified upload cannot complete',
);
is(
 autocal3d_commit_error({upload=>1,signal_mode=>'sdr'},{upload_verified=>1}),
 '',
 'a verified standalone SDR upload satisfies the commit contract',
);
like(
 autocal3d_commit_error(
  {upload=>1,full_workflow=>1,signal_mode=>'hdr10'},
  {upload_verified=>1,tone_map_upload_status=>'error',tone_map_upload_message=>'CAL_END failed'},
 ),
 qr/tone-map upload failed.*CAL_END failed/i,
 'a full HDR run fails closed when tone-map finalisation fails',
);
like(
 autocal3d_commit_error(
  {upload=>1,full_workflow=>1,signal_mode=>'hdr10'},
  {upload_verified=>1,tone_map_upload_status=>'error',tone_map_uploaded=>0,tone_map_upload_error_code=>'lg-tone-map-peak-missing'},
 ),
 qr/finalisation failed because no measured peak luminance.*session remains held/i,
 'a missing worker peak is a precise held-session finalisation error',
);
like(
 autocal3d_commit_error(
  {upload=>1,full_workflow=>1,signal_mode=>'hdr10'},
  {upload_verified=>1,tone_map_upload_status=>'skipped',tone_map_uploaded=>0},
 ),
 qr/tone-map upload failed/i,
 'a leftover skipped tone-map status cannot complete a full HDR run',
);
is(
 autocal3d_commit_error(
  {upload=>1,full_workflow=>1,signal_mode=>'hdr10'},
  {upload_verified=>1,tone_map_upload_status=>'ok',tone_map_uploaded=>1},
 ),
 '',
 'verified HDR LUT and tone-map commits can complete when shadow correction is disabled',
);
like(
 autocal3d_commit_error(
  {upload=>1,full_workflow=>1,signal_mode=>'hdr10',lg_autocal_hdr20_postcal_shadow_enable=>1},
  {upload_verified=>1,tone_map_upload_status=>'ok',tone_map_uploaded=>1,hdr20_postcal_shadow=>{status=>'skipped'}},
 ),
 qr/did not reach a valid terminal state/i,
 'an enabled shadow correction cannot silently skip',
);
like(
 autocal3d_commit_error(
  {upload=>1,full_workflow=>1,signal_mode=>'hdr10',lg_autocal_hdr20_postcal_shadow_enable=>1},
  {upload_verified=>1,tone_map_upload_status=>'ok',tone_map_uploaded=>1,hdr20_postcal_shadow=>{status=>'converged',reestablished=>0}},
 ),
 qr/did not re-establish/i,
 'shadow correction must positively re-establish the TV session',
);
like(
 autocal3d_commit_error(
  {upload=>1,full_workflow=>1,signal_mode=>'hdr10',lg_autocal_hdr20_postcal_shadow_enable=>1},
  {
   upload_verified=>1,tone_map_upload_status=>'ok',tone_map_uploaded=>1,
   hdr20_postcal_shadow=>{status=>'converged',reestablished=>1},
   postcal_shadow_recommit_lut_status=>'ok',postcal_shadow_recommit_lut_detail=>{upload_verified=>0},
   postcal_shadow_recommit_tonemap_status=>'ok',
  },
 ),
 qr/readback not verified/i,
 'a nominal shadow LUT response still fails without exact readback verification',
);
is(
 autocal3d_commit_error(
  {upload=>1,full_workflow=>1,signal_mode=>'hdr10',lg_autocal_hdr20_postcal_shadow_enable=>1},
  {
   upload_verified=>1,tone_map_upload_status=>'ok',tone_map_uploaded=>1,
   hdr20_postcal_shadow=>{status=>'converged',reestablished=>1},
   postcal_shadow_recommit_lut_status=>'ok',postcal_shadow_recommit_lut_detail=>{upload_verified=>1},
   postcal_shadow_recommit_tonemap_status=>'ok',
  },
 ),
 '',
 'shadow-enabled HDR completes only after both final commits succeed',
);
is(
 autocal3d_commit_error(
  {upload=>1,full_workflow=>1,signal_mode=>'hdr10',lg_autocal_hdr20_postcal_shadow_enable=>1},
  {
   upload_verified=>1,tone_map_upload_status=>'ok',tone_map_uploaded=>1,
   hdr20_postcal_shadow=>{status=>'best_effort',reestablished=>1,best_worst=>0.067,tolerance=>0.05},
   postcal_shadow_recommit_lut_status=>'ok',postcal_shadow_recommit_lut_detail=>{upload_verified=>1},
   postcal_shadow_recommit_tonemap_status=>'ok',
  },
 ),
 '',
 'an improved shadow result outside tolerance remains a valid truthful terminal state',
);

my $tmp=tempdir(CLEANUP=>1);
my $cube_path="$tmp/original.cube";
open(my $cube,'>',$cube_path) or die "Unable to create fixture cube: $!";
print $cube "LUT_3D_SIZE 2\n";
for my $b (0,1) { for my $g (0,1) { for my $r (0,1) {
 print $cube "$r $g $b\n";
}}}
close($cube);
my @exact=map { $_ % 4096 } 0..(33**3*3-1);
my $payload_path="$tmp/original.bin";
open(my $payload,'>',$payload_path) or die "Unable to create fixture payload: $!";
binmode($payload);
print $payload pack('v*',@exact);
close($payload);
my ($payload_values,$retry_state);
{
 no warnings qw(redefine once);
 local *main::write_state=sub { return 1; };
 $retry_state={};
 my (undef,undef,$values)=build_imported_lut({
  imported_cube_path=>$cube_path,
  imported_payload_path=>$payload_path,
  retry_upload_only=>1,
  signal_mode=>'hdr10',target_gamut=>'p3d65',target_gamma=>'st2084',
 },$retry_state,17);
 $payload_values=$values;
}
is_deeply($payload_values,\@exact,'manual retry reuses every exact 33-point payload value');
ok($retry_state->{retry_payload_reused},'exact payload reuse is recorded in state');

my $short_path="$tmp/short.bin";
open(my $short,'>',$short_path) or die "Unable to create short payload: $!";
binmode($short);
print $short pack('v*',@exact[0..999]);
close($short);
{
 no warnings qw(redefine once);
 local *main::write_state=sub { return 1; };
 eval { build_imported_lut({ imported_cube_path=>$cube_path, imported_payload_path=>$short_path, retry_upload_only=>1 },{},17); };
 like($@,qr/has 2000 bytes, expected 215622/,'a payload that is not byte-exact 33^3 is refused rather than resampled');
}

my $webui="$Bin/../usr/share/PGenerator/webui.pm";
my $source=read_source($webui)
          .read_source("$Bin/../usr/share/PGenerator/webui-body.html")
          .read_source("$Bin/../usr/share/PGenerator/webui-app.js")
          .read_source("$Bin/../usr/share/PGenerator/webui-workspace.js")
          .read_source("$Bin/../usr/share/PGenerator/webui-lg-card.html")
          .read_source("$Bin/../usr/share/PGenerator/webui-lg.js");
like($source,qr{/api/meter/lg-3d-autocal/retry-upload},'the manual retry endpoint is routed');
like($source,qr/id="meterAutoCalUploadRetryBtn"[^>]+onclick="meterRetryLg3dUpload\(\)"/,'the failure overlay exposes a retry button');
like($source,qr/retryWaiting=.*upload_retry_available/,'a saved retry remains visible after a page refresh');
like($source,qr/sub webui_meter_lg_3d_autocal_recover_unverified_complete/,'legacy false-complete upload states have a recovery path');
like($source,qr/recover_unverified_complete\(\$json\)/,'status polling applies legacy recovery before returning success');
like($source,qr/my \$_tm_ok=\(\$_tm_status eq "" \|\| \$_tm_status eq "ok"\)/,
 'the dead-worker monitor accepts only absent or successful tone-map state');
like($source,qr/lg-tone-map-peak-missing[\s\S]{0,400}?measured peak luminance was missing/,
 'the dead-worker monitor surfaces the precise missing-peak finalisation error');

# Legacy recovery must leave genuine states untouched. Load webui.pm so the
# guard clauses run for real (no /tmp state/config files are needed for these).
{
 no warnings qw(redefine once);
 local $SIG{__WARN__}=sub { };
 do $webui;
 die $@ if($@);
}
ok(defined(&webui_meter_lg_3d_autocal_recover_unverified_complete),'legacy recovery is callable');
my $running='{"status":"running","upload_verified":false}';
is(webui_meter_lg_3d_autocal_recover_unverified_complete($running),$running,'a running state is never rewritten');
my $verified='{"status":"complete","upload_verified":true,"export":{}}';
is(webui_meter_lg_3d_autocal_recover_unverified_complete($verified),$verified,'a verified completion is never rewritten');
my $export_only='{"status":"complete","upload_verified":false,"export":{"cube_path":"/nonexistent.cube","payload_path":"/nonexistent.bin"}}';
is(webui_meter_lg_3d_autocal_recover_unverified_complete($export_only),$export_only,'a completion without the exact on-disk files is never rewritten');

my $worker_source=read_source($worker);
my $self_gate_at=index($worker_source,'if($worst <= $tol)');
ok($self_gate_at >= 0,'the HDR shadow self-gate is present');
my $self_gate_block=substr($worker_source,$self_gate_at,650);
like($self_gate_block,qr/common finaliser.*\n.*last;/s,'the self-gate leaves only the pass loop so common finalisation still runs');
unlike($self_gate_block,qr/return\s+1\s*;/,'the self-gate cannot return before calibration mode is re-established');

done_testing();
