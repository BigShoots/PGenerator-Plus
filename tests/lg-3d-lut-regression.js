#!/usr/bin/env node
const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const vm = require('vm');
const { execFileSync } = require('child_process');

const root = path.resolve(__dirname, '..');
const worker = path.join(root, 'usr/bin/meter_lg_3d_autocal.pl');
const acceptanceRunner = fs.readFileSync(path.join(root, 'tools/lg-3d-lut-acceptance-runner.js'), 'utf8');
const lgHelper = fs.readFileSync(path.join(root, 'usr/sbin/pgenerator-lg'), 'utf8');
const lgPm = fs.readFileSync(path.join(root, 'usr/share/PGenerator/lg.pm'), 'utf8');
const webui = fs.readFileSync(path.join(root, 'usr/share/PGenerator/webui.pm'), 'utf8');

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function readPayloadNode(payload, r, g, b) {
  const node = ((b * 33 + g) * 33 + r) * 3;
  return [
    payload.readUInt16LE(node * 2),
    payload.readUInt16LE((node + 1) * 2),
    payload.readUInt16LE((node + 2) * 2),
  ];
}

function identityPayloadNode(r, g, b, size = 33) {
  return [r, g, b].map(value => Math.round(value * 4095 / (size - 1)));
}

function trilinearGreyPayloadSample(payload, stimulusPct, size = 33) {
  const x = (stimulusPct / 100) * (size - 1);
  const base = Math.max(0, Math.min(size - 2, Math.floor(x)));
  const fraction = x - base;
  const out = [0, 0, 0];
  for (let db = 0; db <= 1; db += 1) {
    for (let dg = 0; dg <= 1; dg += 1) {
      for (let dr = 0; dr <= 1; dr += 1) {
        const weight = (dr ? fraction : 1 - fraction) *
          (dg ? fraction : 1 - fraction) *
          (db ? fraction : 1 - fraction);
        const node = readPayloadNode(payload, base + dr, base + dg, base + db);
        out[0] += weight * node[0];
        out[1] += weight * node[1];
        out[2] += weight * node[2];
      }
    }
  }
  return out;
}

function spread(values) {
  return Math.max(...values) - Math.min(...values);
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
assert.match(status.export.cube_path, /_\d{6}_sdr_ramp_cinema_bt709_bt1886\.cube$/);

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

const cube = fs.readFileSync(status.export.cube_path, 'utf8').trim().split(/\n/);
assert.strictEqual(cube[1], 'LUT_3D_SIZE 17');
assert.strictEqual(cube.filter(line => /^\d/.test(line)).length, 4913);
assert.match(status.neutral_axis_source, /exact diagonal identity/i);

const matrixConfig = path.join(tmp, 'matrix-config.json');
const matrixState = path.join(tmp, 'matrix-state.json');
fs.writeFileSync(matrixConfig, JSON.stringify({
  fixture_mode: true,
  method: 'matrix',
  picture_mode: 'cinema',
  lut_dir: lutDir,
  post_check: false,
}));
execFileSync(worker, [matrixConfig, matrixState, stop], { stdio: 'pipe' });
const matrixStatus = readJson(matrixState);
assert.strictEqual(matrixStatus.status, 'complete');
assert.strictEqual(matrixStatus.profile_patch_count, 5);
assert.deepStrictEqual(matrixStatus.steps.map(step => step.kind), ['white', 'red', 'green', 'blue', 'black']);
assert.deepStrictEqual(matrixStatus.readings.map(reading => reading.kind), ['white', 'red', 'green', 'blue', 'black']);
assert.deepStrictEqual(
  matrixStatus.steps.map(step => [step.kind, step.r, step.g, step.b]),
  [
    ['white', 235, 235, 235],
    ['red', 235, 16, 16],
    ['green', 16, 235, 16],
    ['blue', 16, 16, 235],
    ['black', 16, 16, 16],
  ],
);

function runMatrixFixture(name, extraConfig) {
  const cfg = path.join(tmp, `${name}-config.json`);
  const st = path.join(tmp, `${name}-state.json`);
  fs.writeFileSync(cfg, JSON.stringify({
    fixture_mode: true,
    method: 'matrix',
    picture_mode: 'cinema',
    lut_dir: path.join(lutDir, name),
    post_check: false,
    ...extraConfig,
  }));
  execFileSync(worker, [cfg, st, stop], { stdio: 'pipe' });
  return readJson(st);
}

const bt1886Black2 = runMatrixFixture('matrix-bt1886-black2', {
  target_gamma: 'bt1886',
  fixture_black_y: 2,
  fixture_white_y: 100,
});
const gamma24Black2 = runMatrixFixture('matrix-gamma24-black2', {
  target_gamma: '2.4',
  fixture_black_y: 2,
  fixture_white_y: 100,
});
const bt1886Black5 = runMatrixFixture('matrix-bt1886-black5', {
  target_gamma: 'bt1886',
  fixture_black_y: 5,
  fixture_white_y: 100,
});
assert.strictEqual(bt1886Black2.status, 'complete');
assert.strictEqual(bt1886Black2.readings.find(reading => reading.kind === 'black').Y, 2);
assert.strictEqual(bt1886Black2.readings.find(reading => reading.kind === 'white').Y, 100);
const bt1886Node = readPayloadNode(fs.readFileSync(bt1886Black2.export.payload_path), 8, 4, 1);
const gamma24Node = readPayloadNode(fs.readFileSync(gamma24Black2.export.payload_path), 8, 4, 1);
const bt1886Black5Node = readPayloadNode(fs.readFileSync(bt1886Black5.export.payload_path), 8, 4, 1);
assert.notDeepStrictEqual(bt1886Node, gamma24Node);
assert.notDeepStrictEqual(bt1886Node, bt1886Black5Node);
assert.ok(bt1886Node[0] > gamma24Node[0]);
assert.ok(bt1886Node[1] > gamma24Node[1]);

const neutralGuardPayload = fs.readFileSync(bt1886Black2.export.payload_path);
for (const stimulus of [1, 2.3, 3, 5, 10, 20, 40, 60, 80, 95, 99]) {
  const sample = trilinearGreyPayloadSample(neutralGuardPayload, stimulus);
  const expected = stimulus * 4095 / 100;
  assert.ok(spread(sample) <= 0.01, `neutral trilinear RGB spread should stay zero at ${stimulus}%: ${sample.join('/')}`);
  for (const channel of sample) {
    assert.ok(Math.abs(channel - expected) <= 1, `neutral trilinear sample should track ${stimulus}% input: ${channel} vs ${expected}`);
  }
}
assert.notDeepStrictEqual(
  readPayloadNode(neutralGuardPayload, 8, 4, 1),
  identityPayloadNode(8, 4, 1),
  'saturated off-axis 3D LUT nodes should remain corrected, not globally identity'
);

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

assert.match(webui, /\/api\/meter\/lg-3d-autocal\/start/);
assert.match(webui, /\/api\/meter\/lg-3d-autocal\/status/);
assert.match(webui, /\/api\/meter\/lg-3d-autocal\/stop/);
assert.match(webui, /id="meterLg3dColorControls"/);
assert.match(webui, /3D LUT AutoCal/);
assert.doesNotMatch(webui, /id="meterLg3dMethod"/);
assert.doesNotMatch(webui, /id="meterLg3dUpload"/);
assert.match(webui, /const showLg3d=autoCalSignalAllowed&&autoCalTabActive&&meterAutoCalSeriesChoice==='3d-lut'&&meterDetected&&meterLg3dAutoCalAvailable\(\)&&!continuousUiActive/);
assert.match(webui, /const showFullAutoCal=autoCalSignalAllowed&&meterDetected&&meterFullAutoCalAvailable\(\)&&!continuousUiActive/);
assert.match(webui, /function meterSetSeriesButtonVisible/);
assert.match(webui, /meterSetSeriesButtonVisible\('greyscale-26',false\)/);
assert.match(webui, /if\(opts\.preserveTab&&meterSeriesTab==='autocal'\)\{\s*meterUpdateSeriesTabUi\(\);\s*meterSetAutoCalSeriesChoice\(type==='greyscale'\?'greyscale':'3d-lut'\);/);
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
assert.match(webui, /SDR YCbCr 4:4:4 10-bit limited BT\.709/);
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
assert.match(webui, /await meterEnsureLgAutoCalTransport\('Full Auto Cal'\)/);
assert.match(webui, /await meterEnsureLgAutoCalTransport\(fullWorkflow\?'Full Auto Cal':'LG Greyscale Auto Cal'\)/);
assert.match(webui, /await meterEnsureLgAutoCalTransport\('LG 3D LUT AutoCal'\)/);
assert.match(webui, /run the current LG 26-point greyscale AutoCal top\/body first and shadows low-to-high.*color-only 3D LUT AutoCal/s);
assert.match(webui, /upload:true/);
assert.match(webui, /meterStartLg3dAutoCal\(\{\s*fullWorkflow:true,\s*skipConfirm:true/s);
assert.match(webui, /full_autocal_touchup:true/);
assert.match(webui, /max_iterations:8/);
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
assert.match(acceptanceRunner, /rgb_codes_bt1886_measured_black/);
assert.match(acceptanceRunner, /BT\.1886 greyscale summary cannot score RGB-code fallback without a measured black sample/);

function acceptanceContext(targetGamma = 'bt1886') {
  const source = acceptanceRunner.replace(/main\(\)\.catch\([\s\S]*?\n\}\);\s*$/, '');
  const context = {
    require,
    process: {
      env: {
        PGEN_TARGET_GAMMA: targetGamma,
      },
      stdout: { write() {} },
      stderr: { write() {} },
      exit() {},
    },
    console,
  };
  vm.createContext(context);
  vm.runInContext(source, context);
  return context;
}

const acceptanceBt1886 = acceptanceContext('bt1886');
const blackY = 2;
const whiteY = 100;
const d65X = 0.3127;
const d65Y = 0.329;
const signal50 = (126 - 16) / 219;
const blackX = (d65X / d65Y) * blackY;
const blackZ = ((1 - d65X - d65Y) / d65Y) * blackY;
const whiteX = (d65X / d65Y) * whiteY;
const whiteZ = ((1 - d65X - d65Y) / d65Y) * whiteY;
const bt1886ExpectedY = Math.pow(
  (Math.pow(whiteY, 1 / 2.4) - Math.pow(blackY, 1 / 2.4)) * signal50 + Math.pow(blackY, 1 / 2.4),
  2.4
);
const gamma24Y = Math.pow(signal50, 2.4) * whiteY;
const bt1886Summary = acceptanceBt1886.summarizeSeries({}, {
  steps: [
    { name: 'Black', ire: 0, r: 16, g: 16, b: 16, input_max: 255 },
    { name: '50%', ire: 50, r: 126, g: 126, b: 126, input_max: 255 },
    { name: 'White', ire: 100, r: 235, g: 235, b: 235, input_max: 255 },
  ],
  readings: [
    { name: 'Black', ire: 0, X: blackX, Y: blackY, Z: blackZ, luminance: blackY, x: d65X, y: d65Y },
    { name: '50%', ire: 50, X: whiteX * 0.2, Y: 20, Z: whiteZ * 0.2, luminance: 20, x: d65X, y: d65Y },
    { name: 'White', ire: 100, X: whiteX, Y: whiteY, Z: whiteZ, luminance: whiteY, x: d65X, y: d65Y },
  ],
}, 'greyscale');
assert.strictEqual(bt1886Summary.blackY, blackY);
assert.strictEqual(bt1886Summary.rows[0].target_source, 'rgb_codes_bt1886_measured_black');
assert(Math.abs(bt1886Summary.rows[0].target_Y - bt1886ExpectedY) < 1e-6, 'acceptance runner BT.1886 fallback should use measured black/white luminance');
assert(bt1886Summary.rows[0].target_Y > gamma24Y + 1, 'acceptance runner BT.1886 fallback must not collapse to plain gamma 2.4');
assert.throws(
  () => acceptanceBt1886.summarizeSeries({}, {
    steps: [
      { name: '50%', ire: 50, r: 126, g: 126, b: 126, input_max: 255 },
      { name: 'White', ire: 100, r: 235, g: 235, b: 235, input_max: 255 },
    ],
    readings: [
      { name: '50%', ire: 50, X: whiteX * 0.2, Y: 20, Z: whiteZ * 0.2, luminance: 20, x: d65X, y: d65Y },
      { name: 'White', ire: 100, X: whiteX, Y: whiteY, Z: whiteZ, luminance: whiteY, x: d65X, y: d65Y },
    ],
  }, 'greyscale'),
  /measured black sample/
);

console.log('LG 3D LUT regression checks passed');
