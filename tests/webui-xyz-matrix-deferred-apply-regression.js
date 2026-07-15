#!/usr/bin/env node
// Pin deferred Apply for XYZ matrix number cells only.
// The enable checkbox applies immediately (refresh + persist); typing matrix
// cells must not recompute charts/live readings until Apply.
// Source-only test (no live renderer/meter).
'use strict';
const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const webuiPath = path.join(root, 'usr', 'share', 'PGenerator', 'webui.pm');
const src = fs.readFileSync(webuiPath, 'utf8');

function assert(cond, msg) {
  if (!cond) {
    console.error('FAIL:', msg);
    process.exit(1);
  }
  console.log('  ok -', msg);
}

// 1. Apply button + apply handler exist.
assert(/id="meterXyzMatrixApply"/.test(src), 'Apply button id meterXyzMatrixApply is present');
assert(/function meterApplyXyzMatrixEdits\(/.test(src), 'meterApplyXyzMatrixEdits is defined');
assert(/function meterSnapshotXyzMatrixAppliedFromDom\(/.test(src), 'meterSnapshotXyzMatrixAppliedFromDom is defined');
assert(/function meterXyzMatrixDraftDirty\(/.test(src), 'meterXyzMatrixDraftDirty is defined');
assert(/function meterUpdateXyzMatrixApplyButton\(/.test(src), 'meterUpdateXyzMatrixApplyButton is defined');
assert(/function meterApplyXyzMatrixEnableFromDraft\(/.test(src), 'meterApplyXyzMatrixEnableFromDraft is defined');
assert(/window\._meterXyzMatrixApplied/.test(src), 'applied snapshot state window._meterXyzMatrixApplied exists');

// 2. Analysis path uses applied snapshot, not live draft DOM.
const enabledFn = src.match(/function meterXyzCorrectionEnabled\(\)\{[\s\S]*?\n\}/);
assert(enabledFn, 'meterXyzCorrectionEnabled is defined');
assert(
  /_meterXyzMatrixApplied/.test(enabledFn[0]),
  'meterXyzCorrectionEnabled reads the applied snapshot when present'
);

const matrixFn = src.match(/function meterXyzCorrectionMatrix\(\)\{[\s\S]*?\n\}/);
assert(matrixFn, 'meterXyzCorrectionMatrix is defined');
assert(
  /_meterXyzMatrixApplied/.test(matrixFn[0]),
  'meterXyzCorrectionMatrix returns the applied matrix snapshot'
);

// 3. Matrix cell input no longer live-refreshes charts; it only marks dirty.
assert(
  /el\.addEventListener\('input',meterUpdateXyzMatrixApplyButton\)/.test(src),
  'matrix input listener calls meterUpdateXyzMatrixApplyButton (dirty UI)'
);
assert(
  !/addEventListener\('input',meterRefreshAfterXyzMatrixChange\)/.test(src),
  'matrix input listener does NOT call meterRefreshAfterXyzMatrixChange'
);
const inputWire = src.match(
  /Draft edits only mark the Apply button dirty[\s\S]{0,400}?addEventListener\('input',meterUpdateXyzMatrixApplyButton\)/
);
assert(inputWire, 'matrix field input listeners are wired near the deferred-edit comment');

// 4. Matrix cells are not on the auto-save change list.
const autoSaveList = src.match(
  /\['meterDisplayType','meterMeasurementPort'[\s\S]*?'meterSimulateSpectro'\]\.forEach\(id=>\{[\s\S]*?addEventListener\('change',saveMeterSettings\)/
);
assert(autoSaveList, 'auto-save change list for meter fields exists');
assert(
  !/meterXyzM1[123]/.test(autoSaveList[0]),
  'matrix cell IDs are not in the auto-save change list'
);

// 5. Enable checkbox applies immediately (not deferred with matrix cells).
const enableApplyFn = src.match(/function meterApplyXyzMatrixEnableFromDraft\(\)\{[\s\S]*?\n\}/);
assert(enableApplyFn, 'meterApplyXyzMatrixEnableFromDraft body found');
assert(
  /_meterXyzMatrixApplied\.enabled\s*=/.test(enableApplyFn[0]) ||
    /enabled:meterDraftXyzMatrixEnabled\(\)/.test(enableApplyFn[0]),
  'enable-from-draft updates applied.enabled (not full matrix-only stale)'
);
assert(
  /meterRefreshAfterXyzMatrixChange\(\)/.test(enableApplyFn[0]),
  'enable-from-draft refreshes charts/live'
);
assert(/saveMeterSettings\(\)/.test(enableApplyFn[0]), 'enable-from-draft persists settings');
// Must not overwrite draft matrix numbers when only toggling enable (keep applied.matrix).
assert(
  !/meterSnapshotXyzMatrixAppliedFromDom\(\)/.test(
    enableApplyFn[0].replace(/if\(!window\._meterXyzMatrixApplied\)\{[\s\S]*?\}/, '')
  ),
  'enable-from-draft does not full-snapshot from DOM when applied already exists'
);

const enableWire = src.match(
  /const xyEl=document\.getElementById\('meterXyzMatrixEnabled'\);[\s\S]*?xyEl\.addEventListener\('change',[\s\S]*?\}\);/
);
assert(enableWire, 'meterXyzMatrixEnabled change listener is wired');
assert(
  /meterApplyXyzMatrixEnableFromDraft/.test(enableWire[0]),
  'enable checkbox change calls meterApplyXyzMatrixEnableFromDraft'
);
assert(
  /meterUpdateGearVisibility/.test(enableWire[0]),
  'enable checkbox change updates gear visibility'
);

const chkSaveList = src.match(
  /\['meterPatchInsert'[\s\S]*?'meterHdrApplyBT2390'\]\.forEach\(id=>\{[\s\S]*?addEventListener\('change',saveMeterSettings\)/
);
assert(chkSaveList, 'checkbox auto-save list exists');
assert(
  !/meterXyzMatrixEnabled/.test(chkSaveList[0]),
  'meterXyzMatrixEnabled is not in the generic checkbox auto-save list (uses enable-from-draft instead)'
);

// 6. Apply path snapshots matrix numbers, refreshes, and saves.
const applyFn = src.match(/function meterApplyXyzMatrixEdits\(\)\{[\s\S]*?\n\}/);
assert(applyFn, 'meterApplyXyzMatrixEdits body found');
assert(/meterSnapshotXyzMatrixAppliedFromDom\(\)/.test(applyFn[0]), 'Apply snapshots from DOM');
assert(/meterRefreshAfterXyzMatrixChange\(\)/.test(applyFn[0]), 'Apply refreshes charts/live');
assert(/saveMeterSettings\(\)/.test(applyFn[0]), 'Apply persists settings');

// 7. loadMeterSettings seeds the applied snapshot.
assert(
  /setChk\('meterXyzMatrixEnabled'[\s\S]{0,200}?meterSnapshotXyzMatrixAppliedFromDom\(\)/.test(src),
  'loadMeterSettings snapshots applied matrix after restoring DOM values'
);

// 8. saveMeterSettings persists applied snapshot (so enable-from-draft's applied.enabled is what is saved).
assert(
  /xyz_matrix_enabled:\(window\._meterXyzMatrixApplied!=null\)\?!!window\._meterXyzMatrixApplied\.enabled:chk\('meterXyzMatrixEnabled'\)/.test(
    src
  ),
  'saveMeterSettings writes xyz_matrix_enabled from applied snapshot when set'
);

console.log('OK: XYZ matrix enable applies immediately; matrix cells stay deferred until Apply');
