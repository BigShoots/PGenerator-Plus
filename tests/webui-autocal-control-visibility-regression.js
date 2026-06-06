#!/usr/bin/env node
'use strict';

const fs = require('fs');
const vm = require('vm');
const assert = require('assert');

const source = fs.readFileSync('usr/share/PGenerator/webui.pm', 'utf8');

const seriesRowStart = source.indexOf('<div class="btn-row" id="meterSeriesBtnRow"');
const readRowStart = source.indexOf('<div class="btn-row" id="meterReadBtnRow"');
const lg3dControlsStart = source.indexOf('id="meterLg3dColorControls"');
assert(seriesRowStart >= 0, 'series row markup exists');
assert(readRowStart >= 0, 'read row markup exists');
assert(lg3dControlsStart > readRowStart, '3D LUT AutoCal controls live in the read/action row');
assert(lg3dControlsStart > source.indexOf('id="meterReadSeriesBtn"', readRowStart), '3D LUT AutoCal button sits beside Read Series actions');
assert(lg3dControlsStart > source.indexOf('id="meterAutoCalBtn"', readRowStart), '3D LUT AutoCal button sits with AutoCal start actions');
assert(lg3dControlsStart < source.indexOf('id="meterStopBtn"', readRowStart), '3D LUT AutoCal button appears before Stop in the read/action row');

function extractFunction(name) {
  const token = `function ${name}(`;
  const start = source.indexOf(token);
  if (start < 0) throw new Error(`Missing function ${name}`);
  let i = source.indexOf('{', start);
  let depth = 0;
  for (; i < source.length; i++) {
    const ch = source[i];
    if (ch === '{') depth++;
    else if (ch === '}') {
      depth--;
      if (depth === 0) return source.slice(start, i + 1);
    }
  }
  throw new Error(`Failed to extract function ${name}`);
}

const updateSeriesTabUiSource = extractFunction('meterUpdateSeriesTabUi');
assert(updateSeriesTabUiSource.includes('meterAutoCalControlsAllowedForSignal()'), 'series tab UI is gated by current signal mode');
assert(updateSeriesTabUiSource.includes('const autoCalSeriesAvailable=meterAutoCalSeriesAvailable();'), 'series tab UI is gated by LG/meter AutoCal availability');
assert(updateSeriesTabUiSource.includes("tabKey!=='autocal'||(autoCalSignalAllowed&&autoCalSeriesAvailable)"), 'Auto Cal tab button is hidden outside SDR or without LG/meter availability');
assert(updateSeriesTabUiSource.includes("(tab==='autocal'&&autoCalSignalAllowed&&autoCalSeriesAvailable)?'flex':'none'"), 'Auto Cal series group is hidden outside SDR or without LG/meter availability');

function makeElement() {
  return {
    style: { display: '' },
    disabled: false,
    hidden: false,
    value: '',
    title: '',
    textContent: '',
    classList: { add() {}, remove() {} }
  };
}

const elements = {};
[
  'meterClearChartBtn',
  'meterReadSeriesBtn',
  'meterReadOnce',
  'meterContinuous',
  'meterAutoCalBtn',
  'meterFullAutoCalBtn',
  'meterAutoCalTarget',
  'meterLg3dColorControls',
  'meterLg3dAutoCalBtn',
  'meterStopBtn',
  'meterDeviceReadyBtn',
  'meterManualPromptBtn',
  'signal_mode'
].forEach(id => {
  elements[id] = makeElement();
});

const code = [
  'var meterActiveSeriesType = "greyscale";',
  'var meterCurrentPatchStep = null;',
  'var meterSelectedThumbIre = 100;',
  'var meterSeriesSteps = [{ ire: 100, name: "100%" }];',
  'var meterDetected = true;',
  'var lgConnected = true;',
  'var meterContinuousActive = false;',
  'var meterContinuousSuspendedForLgWrite = false;',
  'var meterSeriesRunning = false;',
  'var meterAutoCalRunning = false;',
  'var meterAutoCalPolling = null;',
  'var meterAutoCalPendingConfig = null;',
  'var meterAutoCalPhase = "";',
  'var meterLg3dAutoCalRunning = false;',
  'var meterLg3dAutoCalPolling = null;',
  'var meterFullAutoCalRunning = false;',
  'var meterActionPending = false;',
  'var meterReadings = [{ ire: 100, luminance: 120 }];',
  'var meterSeriesTab = "greyscale";',
  'var meterSeriesAwaitingReady = false;',
  'var meterReadySignalPending = false;',
  'var meterManualPromptAwaiting = false;',
  'function meterAutoCalRepairOverlayPointerState() {}',
  'function hasUnsavedSettings() { return false; }',
  'function meterAutoCalAvailable() { return true; }',
  'function meterFullAutoCalAvailable() { return true; }',
  'function meterLg3dAutoCalAvailable() { return true; }',
  'function meterGreyTvControlsActive() { return lgConnected; }',
  'function meterSelectedMeasurementRequiresReady() { return false; }',
  'function meterManualPromptActionLabel() { return "Continue"; }',
  extractFunction('meterHideSeriesControlsForAutoCal'),
  extractFunction('meterAutoCalControlsAllowedForSignal'),
  extractFunction('meterAutoCalSeriesAvailable'),
  extractFunction('meterUpdateReadButtons')
].join('\n');

const context = {
  console,
  String,
  Array,
  window: { _configApplyPending: false },
  document: {
    getElementById(id) {
      return elements[id] || null;
    }
  }
};
vm.createContext(context);
vm.runInContext(code, context);

function resetState(overrides = {}) {
  Object.values(elements).forEach(el => {
    el.style.display = '';
    el.disabled = false;
    el.hidden = false;
    el.title = '';
    el.textContent = '';
  });
  elements.signal_mode.value = overrides.signalMode || 'sdr';
  delete overrides.signalMode;
  Object.assign(context, {
    meterSeriesSteps: [{ ire: 100, name: '100%' }],
    meterSelectedThumbIre: 100,
    meterDetected: true,
    lgConnected: true,
    meterReadings: [{ ire: 100, luminance: 120 }],
    meterContinuousActive: false,
    meterContinuousSuspendedForLgWrite: false,
    meterSeriesRunning: false,
    meterAutoCalRunning: false,
    meterAutoCalPolling: null,
    meterAutoCalPendingConfig: null,
    meterAutoCalPhase: '',
    meterLg3dAutoCalRunning: false,
    meterLg3dAutoCalPolling: null,
    meterFullAutoCalRunning: false,
    meterActionPending: false,
    meterSeriesAwaitingReady: false,
    meterManualPromptAwaiting: false,
    meterActiveSeriesType: 'greyscale',
    meterSeriesTab: 'greyscale',
    meterAutoCalSeriesChoice: 'greyscale'
  }, overrides);
}

function assertControlState(label, expected) {
  context.meterUpdateReadButtons();
  assert.strictEqual(elements.meterClearChartBtn.style.display, expected.clearDisplay, `${label}: clear display`);
  assert.strictEqual(elements.meterReadSeriesBtn.style.display, expected.readSeriesDisplay, `${label}: read-series display`);
  assert.strictEqual(elements.meterStopBtn.style.display, expected.stopDisplay, `${label}: stop display`);
}

resetState({ meterSeriesRunning: true });
assertControlState('regular series run', {
  clearDisplay: '',
  readSeriesDisplay: '',
  stopDisplay: ''
});

resetState({ meterAutoCalRunning: true, meterAutoCalPhase: 'running' });
assertControlState('standalone greyscale AutoCal run', {
  clearDisplay: 'none',
  readSeriesDisplay: 'none',
  stopDisplay: ''
});

resetState({ meterFullAutoCalRunning: true, meterAutoCalPhase: 'running' });
assertControlState('full AutoCal greyscale/touchup run', {
  clearDisplay: 'none',
  readSeriesDisplay: 'none',
  stopDisplay: ''
});

resetState({ meterLg3dAutoCalRunning: true });
assertControlState('3D LUT AutoCal run', {
  clearDisplay: 'none',
  readSeriesDisplay: 'none',
  stopDisplay: ''
});

resetState({ meterAutoCalRunning: true, meterAutoCalPhase: 'complete' });
assertControlState('completed AutoCal result view', {
  clearDisplay: '',
  readSeriesDisplay: '',
  stopDisplay: ''
});

resetState({ meterAutoCalRunning: true, meterAutoCalPhase: 'error' });
assertControlState('errored AutoCal result view', {
  clearDisplay: '',
  readSeriesDisplay: '',
  stopDisplay: ''
});

resetState({ meterSeriesTab: 'greyscale', meterActiveSeriesType: 'greyscale' });
context.meterUpdateReadButtons();
assert.strictEqual(elements.meterAutoCalBtn.style.display, 'none', 'greyscale AutoCal start is hidden in Greyscale series tab');

resetState({ meterSeriesTab: 'autocal', meterActiveSeriesType: 'greyscale' });
context.meterUpdateReadButtons();
assert.strictEqual(elements.meterAutoCalBtn.style.display, '', 'greyscale AutoCal start is visible in Auto Cal tab');
assert.strictEqual(elements.meterFullAutoCalBtn.style.display, '', 'Full AutoCal start is visible for SDR');
assert.strictEqual(elements.meterLg3dAutoCalBtn.style.display, 'none', '3D LUT AutoCal start is hidden for AutoCal Greyscale choice');

resetState({ meterSeriesTab: 'autocal', meterActiveSeriesType: 'greyscale', lgConnected: false });
context.meterUpdateReadButtons();
assert.strictEqual(elements.meterAutoCalBtn.style.display, 'none', 'greyscale AutoCal start is hidden when LG is disconnected');
assert.strictEqual(elements.meterFullAutoCalBtn.style.display, 'none', 'Full AutoCal start is hidden when LG is disconnected');

resetState({ meterSeriesTab: 'autocal', meterActiveSeriesType: 'greyscale', meterDetected: false });
context.meterUpdateReadButtons();
assert.strictEqual(elements.meterAutoCalBtn.style.display, 'none', 'greyscale AutoCal start is hidden when meter is disconnected');
assert.strictEqual(elements.meterFullAutoCalBtn.style.display, 'none', 'Full AutoCal start is hidden when meter is disconnected');

resetState({ meterSeriesTab: 'autocal', meterActiveSeriesType: 'greyscale', signalMode: 'hdr10' });
context.meterUpdateReadButtons();
assert.strictEqual(elements.meterAutoCalBtn.style.display, 'none', 'greyscale AutoCal start is hidden in HDR mode');
assert.strictEqual(elements.meterFullAutoCalBtn.style.display, 'none', 'Full AutoCal start is hidden in HDR mode');
assert.strictEqual(elements.meterReadSeriesBtn.style.display, '', 'regular series read button remains visible in HDR mode');

resetState({ meterSeriesTab: 'autocal', meterActiveSeriesType: 'greyscale', signalMode: 'dv' });
context.meterUpdateReadButtons();
assert.strictEqual(elements.meterAutoCalBtn.style.display, 'none', 'greyscale AutoCal start is hidden in Dolby Vision mode');
assert.strictEqual(elements.meterFullAutoCalBtn.style.display, 'none', 'Full AutoCal start is hidden in Dolby Vision mode');

resetState({ meterSeriesTab: 'color', meterActiveSeriesType: 'colors', meterAutoCalSeriesChoice: '3d-lut' });
context.meterUpdateReadButtons();
assert.strictEqual(elements.meterLg3dColorControls.style.display, 'none', '3D LUT AutoCal start is hidden in Color series tab');
assert.strictEqual(elements.meterLg3dAutoCalBtn.style.display, 'none', '3D LUT AutoCal button is hidden in Color series tab');

resetState({ meterSeriesTab: 'autocal', meterActiveSeriesType: 'colors', meterAutoCalSeriesChoice: '3d-lut' });
context.meterUpdateReadButtons();
assert.strictEqual(elements.meterLg3dColorControls.style.display, 'flex', '3D LUT AutoCal start is visible in Auto Cal tab');
assert.strictEqual(elements.meterLg3dAutoCalBtn.style.display, '', '3D LUT AutoCal button is visible in Auto Cal tab');
assert.strictEqual(elements.meterAutoCalBtn.style.display, 'none', 'greyscale AutoCal start is hidden for AutoCal 3D LUT choice');

resetState({ meterSeriesTab: 'autocal', meterActiveSeriesType: 'colors', meterAutoCalSeriesChoice: '3d-lut', lgConnected: false });
context.meterUpdateReadButtons();
assert.strictEqual(elements.meterLg3dColorControls.style.display, 'none', '3D LUT AutoCal controls are hidden when LG is disconnected');
assert.strictEqual(elements.meterLg3dAutoCalBtn.style.display, 'none', '3D LUT AutoCal button is hidden when LG is disconnected');

resetState({ meterSeriesTab: 'autocal', meterActiveSeriesType: 'colors', meterAutoCalSeriesChoice: '3d-lut', signalMode: 'hdr10' });
context.meterUpdateReadButtons();
assert.strictEqual(elements.meterLg3dColorControls.style.display, 'none', '3D LUT AutoCal controls are hidden in HDR mode');
assert.strictEqual(elements.meterLg3dAutoCalBtn.style.display, 'none', '3D LUT AutoCal button is hidden in HDR mode');

console.log('WebUI AutoCal control visibility regression checks passed.');
