use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;
no warnings qw(redefine once);
require "$Bin/../usr/share/PGenerator/webui.pm";
local $ENV{PGEN_AUTOMATION_DIR} = tempdir(CLEANUP => 1);
for my $signal (qw(sdr hdr10 dv)) {
 for my $stages ({}, {pre_readings=>undef,post_readings=>undef}) {
  my $new=main::webui_automation_normalize_item({signal_format=>$signal,stages=>$stages});
  is($new->{stages}{pre_readings},0,"$signal defaults before sweeps off");
  is($new->{stages}{post_readings},0,"$signal defaults after sweeps off");
  is($new->{stages}{calibration},1,"$signal still defaults AutoCal on");
 }
 for my $flags ([1,0],[0,1],[1,1]) {
  my $saved=main::webui_automation_normalize_item({signal_format=>$signal,stages=>{pre_readings=>$flags->[0],post_readings=>$flags->[1]}});
  is_deeply([@{$saved->{stages}}{qw(pre_readings post_readings)}],$flags,"$signal keeps deliberate sweep selections");
 }
}

my $item = main::webui_automation_normalize_item({
 settings_recovery=>{resume_from=>'session-closed'},
 signal_format=>'sdr', target_gamma=>'2.2', target_gamut=>'nonsense', delta_e_formula=>'DE2000',
 calibration=>{target_gamma=>'bt1886', target_luminance=>120, target_delta_e=>0.5, solve_cube_size=>20},
 quality=>{enabled=>1, dE_formula=>'deitp'}, panel_light=>{policy=>'target', key=>'backlight', target_luminance=>90},
 patch_size=>0, delay_ms=>99999, max_bpc=>12, target_white=>{x=>0.7, y=>0.5}, warmup_minutes=>60,
 stages=>{calibration=>undef, post_readings=>0}, pre_series=>[], post_series=>['bogus'],
});
is($item->{calibration}{target_gamma}, 'bt1886', 'calibration gamma wins over the top-level copy');
is($item->{panel_protection}{disable}, 0, 'panel protection is left on unless the job opts in');
is(main::webui_automation_normalize_item({signal_format=>'sdr',panel_protection=>{disable=>1}})->{panel_protection}{disable}, 1, 'a deliberate opt-in is kept');
is(main::webui_automation_normalize_item({signal_format=>'sdr',panel_protection=>{disable=>0}})->{panel_protection}{disable}, 0, 'an explicit opt-out is kept');
is(main::webui_automation_normalize_item({signal_format=>'sdr',panel_protection=>'yes'})->{panel_protection}{disable}, 0, 'malformed panel-protection config falls back to the default (left on)');
is($item->{target_gamma}, 'bt1886', 'top-level gamma is projected from calibration');
is($item->{target_gamut}, 'bt709', 'unknown gamut falls back to the signal default');
is($item->{calibration}{target_gamut}, 'bt709', 'calibration gamut projected too');
is($item->{delta_e_formula}, 'de2000', 'formula is lower-cased and mirrored');
is($item->{calibration}{delta_e_formula}, 'de2000', 'calibration formula agrees');
is($item->{quality}{dE_formula}, 'de2000', 'quality formula agrees with the calibration formula');
is($item->{target_luminance}, 120, 'luminance projected from calibration');
is($item->{panel_light}{target_luminance}, 120, 'panel-light target follows the calibration luminance');
is($item->{calibration}{target_delta_e}, 0.5, 'delta E kept within range');
is($item->{calibration}{solve_cube_size}, 17, 'invalid cube size falls back to 17');
is_deeply($item->{target_white}, {x=>0.3127, y=>0.3290}, 'impossible white point falls back to D65');
is($item->{patch_size}, 1, 'patch size 0 is clamped to 1');
is($item->{delay_ms}, 30000, 'delay is clamped to 30000 ms');
is($item->{max_bpc}, 10, 'bit depth 12 becomes 10');
ok(!exists($item->{warmup_minutes}), 'legacy per-job warm-up is removed, not merely hidden');
ok(!exists($item->{settings_recovery}), 'recipes cannot inject a settings recovery plan to skip calibration');
is($item->{stages}{calibration}, 1, 'an explicit null stage means the default (enabled), as in the editor');
is($item->{stages}{post_readings}, 0, 'an explicit false stage stays disabled');
is_deeply($item->{pre_series}, [], 'an empty sweep list stays empty so readiness can refuse it');
is_deeply($item->{post_series}, [], 'empty sweep list with the stage disabled stays empty');

my $hdr = main::webui_automation_normalize_item({signal_format=>'hdr', calibration=>{method=>'hybrid'}});
is($hdr->{signal_format}, 'hdr10', 'hdr alias maps to hdr10');
is($hdr->{calibration}{method}, 'matrix', 'HDR10 always profiles with the matrix method');
is($hdr->{target_gamma}, 'st2084', 'HDR10 default gamma');
is($hdr->{target_gamut}, 'p3d65', 'HDR10 default gamut agrees with the AutoCal card and the runner');
is($hdr->{calibration}{solve_cube_size}, 17, 'missing cube size defaults to 17');
is($hdr->{patch_size}, 10, 'missing patch size defaults to 10');
is($hdr->{max_bpc}, 10, 'missing bit depth defaults to 10');
for my $signal (qw(sdr hdr10)) {
 my $y422=main::webui_automation_normalize_item({signal_format=>$signal,color_format=>'2',max_bpc=>8});
 is($y422->{max_bpc},10,"$signal 4:2:2 recipe records the renderer's required 10-bit link");
 my $y444=main::webui_automation_normalize_item({signal_format=>$signal,color_format=>'1',max_bpc=>8});
 is($y444->{max_bpc},8,"$signal 4:4:4 retains supported 8-bit transport");
}
my $srgb=main::webui_automation_normalize_item({signal_format=>'sdr',calibration=>{target_gamma=>'srgb',profile_source=>'hybrid9'}});
is($srgb->{target_gamma},'srgb','SDR accepts the wizard sRGB target');
is($srgb->{calibration}{lattice_size},9,'Hybrid 9 selects a nine-point cube axis');
is($srgb->{target_delta_e},0.5,'new items default to the wizard 1D LUT delta target');
my $dv=main::webui_automation_normalize_item({signal_format=>'dv',color_format=>'1',max_bpc=>10,signal_range=>'1',calibration=>{target_gamma=>'srgb',shadow_fix=>1}});
is($dv->{target_gamma},'st2084','DV verification cannot inherit SDR gamma');
is($dv->{color_format},'0','DV pins RGB transport');
is($dv->{max_bpc},8,'DV pins 8-bit transport');
is($dv->{signal_range},'2','DV pins full transport range');
ok(!$dv->{calibration}{shadow_fix},'HDR10 shadow fix does not leak into DV');
my $secret=main::webui_automation_normalize_item({
 token=>'owner-token',automation_token=>'owner-token',
 calibration=>{target_delta_e=>0.5,client_run_token=>'owner-token'},
 settings=>{brightness=>50,password=>'panel-secret'},
});
unlike(PGAutomation::encode_json($secret),qr/owner-token|panel-secret/,'untrusted recipe credentials are not saved');
my $legacy={id=>'legacy-secrets',token=>'owner-token',status=>'complete',
 items=>[{name=>'Old item',automation_token=>'owner-token',settings=>{password=>'panel-secret'}}]};
my $public=main::webui_automation_public_detail_run($legacy);
unlike(PGAutomation::encode_json($public),qr/owner-token|panel-secret/,'legacy run details never expose saved credentials');
ok(PGAutomation::write_json_atomic(PGAutomation::run_dir($legacy->{id}).'/run.json',$legacy),'legacy run saved for public-read checks');
my $edit=PGAutomation::decode_json(main::webui_automation_api('/api/automation/runs/legacy-secrets/edit','GET',''));
unlike(PGAutomation::encode_json($edit),qr/owner-token|panel-secret/,'pending-editor read does not disclose saved credentials');
my $item_path=PGAutomation::item_dir($legacy->{id},0).'/item.json';
ok(PGAutomation::write_json_atomic($item_path,$legacy->{items}[0]),'legacy item artifact saved');
my $artifact=main::webui_automation_artifact($legacy->{id},'items/0/item.json');
unlike($artifact->{data},qr/owner-token|panel-secret/,'public item artifact does not disclose saved credentials');

# Run evidence merged into history items (calibration reset transcripts,
# worker state, measurement series) is not recipe input. Copied into a queue
# it once reached run.json three times over and stalled the runner launch.
my $bloated=main::webui_automation_normalize_item({
 signal_format=>'sdr',name=>'Copied job',
 calibration=>{target_gamma=>'bt1886',reset=>{responses=>[({picture_reset=>{status=>'ok'}}) x 50]},'grey-state'=>{data=>[1..10]},
  '3d-state'=>{x=>1},'dv-profile-state'=>{x=>1},'dv-profile-measurements'=>{x=>1},'dv-profile-upload'=>{x=>1}},
 series=>{pre=>{'greyscale-21'=>{points=>[1..21]}}},'apply-all'=>{verified=>1},'panel-light'=>{value=>80},
});
is($bloated->{calibration}{target_gamma},'bt1886','recipe calibration targets survive evidence stripping');
ok(!exists($bloated->{calibration}{$_}),"merged calibration/$_ artifact is stripped") for qw(reset grey-state 3d-state dv-profile-state dv-profile-measurements dv-profile-upload);
ok(!exists($bloated->{$_}),"merged $_ evidence is stripped") for qw(series apply-all panel-light);
my $history={id=>'history-evidence',token=>'history-token',status=>'stopped',queue_name=>'Old batch',
 items=>[{id=>'job-a',name=>'Job A',signal_format=>'sdr',calibration=>{target_gamma=>'bt1886'},status=>'complete'}]};
ok(PGAutomation::write_json_atomic(PGAutomation::run_dir($history->{id}).'/run.json',$history),'history run saved');
ok(PGAutomation::write_json_atomic(PGAutomation::item_dir($history->{id},0).'/calibration/reset.json',
 {completed_at=>1,responses=>[({picture_reset=>{status=>'ok'}}) x 50]}),'reset transcript artifact saved');
my $recovered=PGAutomation::decode_json(main::webui_automation_api('/api/automation/runs/history-evidence/queue','GET',''));
is($recovered->{status},'ok','history run can be copied to an editable queue');
is($recovered->{queue}{items}[0]{calibration}{target_gamma},'bt1886','copied job keeps its calibration recipe');
ok(!exists($recovered->{queue}{items}[0]{calibration}{reset}),'copied job does not carry the reset transcript');
ok(!exists($recovered->{queue}{items}[0]{status}),'copied job does not carry execution status');
{
 local *main::webui_automation_checked_readiness=sub {
  my ($payload)=@_;
  return {ready=>1,status=>'ok',message=>'ready',items=>[map { main::webui_automation_normalize_item($_) } @{$payload->{items}}],checks=>[],events=>[],hazard_restore=>{}};
 };
 local *main::webui_automation_launch_runner=sub {1};
 my $reply=PGAutomation::decode_json(main::webui_automation_start({queue=>{name=>'Copied batch',
  items=>[{name=>'Job A',signal_format=>'sdr',calibration=>{target_gamma=>'bt1886',reset=>{responses=>[({x=>1}) x 50]}}}]}}));
 is($reply->{status},'started','a payload carrying old evidence still starts');
 my $manifest=PGAutomation::read_json_file(PGAutomation::run_dir($reply->{run_id}).'/run.json');
 ok(!exists($manifest->{items}[0]{calibration}{reset}),'manifest items carry no reset transcript');
 ok(!exists($manifest->{queue_snapshot}{items}[0]{calibration}{reset}),'queue snapshot carries no reset transcript');
 ok(!$manifest->{readiness}{items},'manifest does not store a second copy of every item under readiness');
 is($manifest->{items}[0]{calibration}{target_gamma},'bt1886','manifest items keep the recipe');
}
done_testing();
