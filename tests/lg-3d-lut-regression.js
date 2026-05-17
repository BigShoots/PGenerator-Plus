#!/usr/bin/env node
const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const root = path.resolve(__dirname, '..');
const worker = path.join(root, 'usr/bin/meter_lg_3d_autocal.pl');
const acceptanceRunner = fs.readFileSync(path.join(root, 'tools/lg-3d-lut-acceptance-runner.js'), 'utf8');
const lgHelper = fs.readFileSync(path.join(root, 'usr/sbin/pgenerator-lg'), 'utf8');
const lgPm = fs.readFileSync(path.join(root, 'usr/share/PGenerator/lg.pm'), 'utf8');
const webui = fs.readFileSync(path.join(root, 'usr/share/PGenerator/webui.pm'), 'utf8');
const fullAutoCalStartStart = webui.indexOf('async function meterStartFullAutoCal');
const fullAutoCalStartEnd = webui.indexOf('async function meterFullAutoCalStart3d', fullAutoCalStartStart);
const fullAutoCalStartSource = fullAutoCalStartStart >= 0 && fullAutoCalStartEnd > fullAutoCalStartStart
  ? webui.slice(fullAutoCalStartStart, fullAutoCalStartEnd)
  : '';

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

const describe = JSON.parse(execFileSync(worker, ['--describe'], { encoding: 'utf8' }));
assert.strictEqual(describe.default_method, 'matrix');
assert.deepStrictEqual(describe.ramp_levels, [0, 2, 5, 8, 12, 16, 20, 30, 40, 50, 60, 70, 80, 88, 94, 98, 100]);
assert.strictEqual(describe.ramp_profile_patch_count, 65);
assert.strictEqual(describe.lut_size, 17);
assert.strictEqual(describe.cube_lut_size, 17);
assert.strictEqual(describe.payload_lut_size, 33);
assert.strictEqual(describe.payload_bits, 12);
assert.strictEqual(describe.payload_endianness, 'little-endian uint16');
assert.strictEqual(describe.payload_axis_order, 'R fastest, G middle, B slowest');
assert.match(describe.ramp_drift, /start\/end WRGB/i);
assert.match(describe.model, /per-luminance-level additive XYZ/i);
assert.match(describe.neutral_axis, /current 1D greyscale path/i);
assert.match(describe.inverse, /per-level native matrix inverse/i);

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-lg-3d-lut-'));
const config = path.join(tmp, 'config.json');
const state = path.join(tmp, 'state.json');
const stop = path.join(tmp, 'stop');
const lutDir = path.join(tmp, 'luts');
fs.writeFileSync(config, JSON.stringify({
  fixture_mode: true,
  method: 'ramp',
  picture_mode: 'cinema',
  lut_dir: lutDir,
  post_check: false,
}));
execFileSync(worker, [config, state, stop], { stdio: 'pipe' });
const status = readJson(state);
assert.strictEqual(status.status, 'complete');
assert.strictEqual(status.profile_patch_count, 65);
assert.strictEqual(status.export.cube_values, 17 * 17 * 17 * 3);
assert.strictEqual(status.export.payload_values, 33 * 33 * 33 * 3);
assert.strictEqual(status.export.payload_bytes, 33 * 33 * 33 * 3 * 2);
assert.match(status.export.cube_path, /_\d{6}_ramp_cinema_bt709\.cube$/);

const payload = fs.readFileSync(status.export.payload_path);
assert.strictEqual(payload.length, 215622);
assert.strictEqual(payload.readUInt16LE(0), 0);
assert.strictEqual(payload.readUInt16LE(2), 0);
assert.strictEqual(payload.readUInt16LE(4), 0);
assert.ok(payload.readUInt16LE(6) > 0 && payload.readUInt16LE(6) < 256);
assert.strictEqual(payload.readUInt16LE(8), 0);
assert.strictEqual(payload.readUInt16LE(10), 0);
for (const i of [8, 16, 24]) {
  const expected = Math.round(i * 4095 / 32);
  const node = ((i * 33 + i) * 33 + i) * 3;
  assert.strictEqual(payload.readUInt16LE(node * 2), expected);
  assert.strictEqual(payload.readUInt16LE((node + 1) * 2), expected);
  assert.strictEqual(payload.readUInt16LE((node + 2) * 2), expected);
}
assert.strictEqual(payload.readUInt16LE(payload.length - 6), 4095);
assert.strictEqual(payload.readUInt16LE(payload.length - 4), 4095);
assert.strictEqual(payload.readUInt16LE(payload.length - 2), 4095);

const invalidTmp = fs.mkdtempSync(path.join(os.tmpdir(), 'pg-lg-3d-lut-invalid-'));
const invalidConfig = path.join(invalidTmp, 'config.json');
const invalidState = path.join(invalidTmp, 'state.json');
const invalidStop = path.join(invalidTmp, 'stop');
fs.writeFileSync(invalidConfig, JSON.stringify({
  fixture_mode: true,
  fixture_zero_green_profile: true,
  method: 'matrix',
  picture_mode: 'cinema',
  lut_dir: path.join(invalidTmp, 'luts'),
  post_check: false,
}));
execFileSync(worker, [invalidConfig, invalidState, invalidStop], { stdio: 'pipe' });
const invalidStatus = readJson(invalidState);
assert.strictEqual(invalidStatus.status, 'error');
assert.match(invalidStatus.message, /Invalid profile read.*green/i);
assert.ok(!invalidStatus.export, 'Invalid profile reads must fail before exporting a 3D LUT');

const cube = fs.readFileSync(status.export.cube_path, 'utf8').trim().split(/\n/);
assert.strictEqual(cube[1], 'LUT_3D_SIZE 17');
assert.strictEqual(cube.filter(line => /^\d/.test(line)).length, 4913);
assert.match(status.neutral_axis_source, /exact diagonal identity/i);

assert.match(lgHelper, /externalpq\/setExternalPqData/);
assert.match(lgHelper, /externalpq\/getExternalPqData/);
assert.match(lgHelper, /sub lg_unity_3d_lut/);
assert.match(lgHelper, /BT709_3D_LUT_DATA/);
assert.match(lgHelper, /GET_3D_LUT_DATA/);
assert.match(lgHelper, /lg_3d_lut_probe_candidate/);
assert.match(lgHelper, /restore_upload_response/);

assert.match(lgPm, /\/api\/lg\/3d-lut\/probe/);
assert.match(lgPm, /\/api\/lg\/3d-lut\/upload/);
assert.match(lgPm, /\/api\/lg\/3d-lut\/reset/);
assert.match(lgPm, /\/var\/lib\/PGenerator\/lg\/luts/);
assert.match(lgPm, /sub lg_is_pgenerator_name/);
assert.match(lgPm, /\$osd_name="" if\(&lg_is_pgenerator_name\(\$osd_name\)\)/);
assert.match(lgPm, /function lgDisplayNameFromStatus\(r\)/);
assert.match(lgPm, /!lgIsPGeneratorDisplayName\(name\)/);
assert.match(lgPm, /modelName:lgDisplayNameFromStatus\(r\)/);
assert.doesNotMatch(lgPm, /r\.model_name\|\|r\.modelName\|\|r\.displayName\|\|r\.stored_name\|\|r\.cec_osd_name/);

assert.match(webui, /\/api\/meter\/lg-3d-autocal\/start/);
assert.match(webui, /\/api\/meter\/lg-3d-autocal\/status/);
assert.match(webui, /\/api\/meter\/lg-3d-autocal\/stop/);
assert.match(webui, /id="meterLg3dColorControls"/);
assert.match(webui, /3D LUT AutoCal/);
assert.doesNotMatch(webui, /id="meterLg3dMethod"/);
assert.doesNotMatch(webui, /id="meterLg3dUpload"/);
assert.match(webui, /const showLg3d=meterSeriesTab==='color'&&meterDetected&&meterLg3dAutoCalAvailable\(\)&&!continuousUiActive/);
assert.match(webui, /const showFullAutoCal=meterDetected&&meterFullAutoCalAvailable\(\)&&!continuousUiActive/);
assert.match(webui, /function meterSetSeriesButtonVisible/);
assert.match(webui, /meterSetSeriesButtonVisible\('greyscale-26',lgTvAvailable\)/);
assert.match(webui, /return Array\.from\(group\.querySelectorAll\('button\[data-series\]'\)\)\.find\(btn=>!btn\.hidden&&btn\.style\.display!=='none'&&!btn\.disabled\)\|\|null/);
assert.match(webui, /return !!\(\(state\.paired\|\|state\.clientKeyPresent\)&&!state\.pinPending\)/);
assert.match(lgPm, /if\(typeof meterUpdateSeriesTabUi==='function'\) meterUpdateSeriesTabUi\(\);/);
assert.match(lgPm, /if\(typeof meterUpdateReadButtons==='function'\) meterUpdateReadButtons\(\);/);
assert.match(webui, /function meterFullAutoCalMethodValue\(\)\{\s*return 'matrix';\s*\}/);
assert.match(webui, /function meterFullAutoCalUploadValue\(\)\{\s*return true;\s*\}/);
assert.match(webui, /function meterLg3dApplyPostCheckStatus/);
assert.match(webui, /meterActiveSeriesType='colors'/);
assert.match(webui, /meterSeriesSteps=readings\.map\(meterLg3dPostCheckStep\)/);
assert.match(webui, /function meterWorkflowPhaseFraction/);
assert.match(webui, /status\.autocal3d&&phase==='post_check'/);
assert.match(webui, /Number\(status\.post_check_total\)\|\|total/);
assert.doesNotMatch(webui, /Export:\s*'\+.*cube_path/);
assert.match(webui, /function meterEnsureLgAutoCalTransport/);
assert.match(webui, /SDR YCbCr 4:4:4 10-bit limited BT\.709 output/);
assert.match(webui, /id="meterFullAutoCalBtn"/);
assert.match(webui, /function meterStartFullAutoCal/);
assert.match(webui, /id="meterWorkflowProgressFill"/);
assert.match(webui, /function meterSetWorkflowProgress/);
assert.match(webui, /function meterAutoCalStatusWatchdog/);
assert.match(webui, /if\(watchdog&&r\.status!=='running'\) return/);
assert.match(webui, /const greyActive=!!\(meterAutoCalPolling\|\|meterAutoCalPhase==='running'\)/);
assert.match(webui, /const lutActive=!!\(meterLg3dAutoCalRunning/);
assert.match(webui, /setInterval\(meterAutoCalStatusWatchdog,5000\)/);
assert.match(webui, /meterPollLg3dAutoCal\(\{initial:true\}\)/);
assert.match(webui, /webui_meter_lg_3d_autocal_compact_status_json/);
assert.match(webui, /omitted from status/);
assert.match(webui, /METER_FULL_AUTOCAL_STATE_KEY/);
assert.match(webui, /function meterFullAutoCalRestoreSavedState/);
assert.match(webui, /meterFullAutoCalRestoreSavedState\(\)/);
assert.match(webui, /meterAutoCalPollErrors\+\+/);
assert.match(webui, /meterLg3dAutoCalPollErrors\+\+/);
assert.match(fullAutoCalStartSource, /await meterEnsureLgAutoCalTransport\('Full Auto Cal'\)/);
assert.match(webui, /This will first switch PGenerator to the AutoCal video transport and measure the current state for the before report/);
assert.match(webui, /await meterEnsureLgAutoCalTransport\(fullWorkflow\?'Full Auto Cal':'LG Greyscale Auto Cal'\)/);
assert.match(webui, /await meterEnsureLgAutoCalTransport\('LG 3D LUT AutoCal'\)/);
assert.match(webui, /run the current LG 26-point greyscale AutoCal top\/body first and shadows low-to-high with committed greyscale polish, then run color-only 3D LUT AutoCal/);
assert.match(webui, /upload:true/);
assert.match(webui, /post_check:false/);
assert.match(webui, /meterStartLg3dAutoCal\(\{\s*fullWorkflow:true,\s*skipConfirm:true/s);
assert.match(webui, /full_autocal_touchup:true/);
assert.match(webui, /restore_factory_levels:false/);
assert.match(webui, /reset_ddc_baseline:false/);
assert.match(webui, /max_iterations:8/);
assert.match(webui, /headroom_max_iterations:8/);
assert.match(webui, /meter_lg_3d_autocal/);
const workerSource = fs.readFileSync(worker, 'utf8');
assert.match(workerSource, /\$state->\{"post_check_current"\}=\$i\+1/);
assert.match(workerSource, /\$post_entry->\{"target_x"\}/);
assert.match(workerSource, /\$post_entry->\{"target_Yn"\}/);
assert.match(workerSource, /\$post_entry->\{"series_color"\}/);
assert.match(workerSource, /sub patch_code_for_8bit_value/);
assert.match(workerSource, /patch_code_for_8bit_value\(\$r,\$signal_range\)/);
assert.match(workerSource, /target_linear_r=>target_gamma_linear\(\$r\/255,\$target_gamma\)/);
assert.match(workerSource, /my \$linear=target_gamma_linear\(\$sat\/100,\$target_gamma\)/);
assert.match(workerSource, /my \$k=patch_code_for_percent\(0,\$signal_range\)/);
assert.match(workerSource, /Matrix profile /);
assert.match(workerSource, /\$state->\{"profile_current"\}=\$i\+1/);
assert.match(workerSource, /sub reset_3d_lut_to_unity_before_profile/);
assert.match(workerSource, /\/api\/lg\/3d-lut\/reset/);
assert.match(workerSource, /\$state->\{"phase"\}="unity_reset"/);
assert.match(workerSource, /\$state->\{"unity_reset_verified"\}/);
assert.match(workerSource, /Writing verified unity 3D LUT before profile reads/);
assert.ok(workerSource.indexOf('reset_3d_lut_to_unity_before_profile($config,$state)') < workerSource.indexOf('for(my $i=0;$i<@steps;$i++)'));
assert.match(webui, /const absX=Number\(reading\.target_X\)/);
assert.match(webui, /if\(Number\.isFinite\(absX\)&&Number\.isFinite\(absY\)&&Number\.isFinite\(absZ\)&&absY>=0\)/);
assert.match(webui, /LG Auto Cal is already running/);
assert.match(webui, /LG 3D LUT AutoCal is already running/);

assert.match(acceptanceRunner, /\/api\/meter\/series/);
assert.match(acceptanceRunner, /\/api\/meter\/lg-3d-autocal\/start/);
assert.match(acceptanceRunner, /colors/);
assert.match(acceptanceRunner, /saturations/);
assert.match(acceptanceRunner, /deltaE2000/);
assert.match(acceptanceRunner, /mean_delta_e_2000/);
assert.match(acceptanceRunner, /PGEN_ALLOW_TV_WRITE/);
assert.match(acceptanceRunner, /PGEN_MEAN_IMPROVEMENT_THRESHOLD_PCT/);
assert.match(acceptanceRunner, /PGEN_AUTOCAL_POST_CHECK/);
assert.match(acceptanceRunner, /process\.env\.PGEN_METHOD \|\| 'matrix'/);
assert.match(acceptanceRunner, /upload_verified: uploadVerified/);
assert.match(acceptanceRunner, /lg-3d-lut-acceptance-\$\{stamp\}-acceptance\.json/);

console.log('LG 3D LUT regression checks passed');
