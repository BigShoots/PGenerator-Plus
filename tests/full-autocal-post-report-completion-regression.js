#!/usr/bin/env node
'use strict';

const fs = require('fs');
const assert = require('assert');

const webui = fs.readFileSync('usr/share/PGenerator/webui.pm', 'utf8');

function sliceBetween(startNeedle, endNeedle, label) {
  const start = webui.indexOf(startNeedle);
  assert(start >= 0, `${label} start should exist`);
  const end = webui.indexOf(endNeedle, start);
  assert(end > start, `${label} end should exist`);
  return webui.slice(start, end);
}

const completionHelper = sliceBetween(
  'async function meterFullAutoCalMarkCurrentCompletionStatusesHandled',
  'function meterFullAutoCalClearCompletionHandled',
  'Full AutoCal post-report completion-status helper'
);
assert(
  completionHelper.includes("'/api/meter/lg-autocal/status'") &&
    completionHelper.includes("'/api/meter/lg-3d-autocal/status'"),
  'Post-report cleanup should inspect both stale Full AutoCal worker status files'
);
assert(
  completionHelper.includes("status.status==='complete'&&status.full_workflow&&meterFullAutoCalStatusMatchesRun(status)") &&
    completionHelper.includes('meterFullAutoCalMarkCompletionHandled(status);'),
  'Post-report cleanup should mark same-run completed Full AutoCal statuses as handled'
);

const pendingMagicWandHelper = sliceBetween(
  'function meterFullAutoCalMagicWandPendingBeforeCompletion',
  'function meterAutoCalMagicWandCompletionRequiresVerification',
  'Full AutoCal Magic Wand pending completion helper'
);
assert(
  pendingMagicWandHelper.includes("status.status==='complete'&&status.full_workflow") &&
    pendingMagicWandHelper.includes("phase==='magic-wand'") &&
    pendingMagicWandHelper.includes('status.full_autocal_post_series_adjust') &&
    pendingMagicWandHelper.includes('status.full_autocal_magic_wand===true') &&
    pendingMagicWandHelper.includes('meterFullAutoCalRunning&&meterFullAutoCalMagicWandEnabled()'),
  'Full AutoCal should treat selected pre-Magic-Wand worker completions as non-final, while allowing actual Magic Wand completion'
);

const magicWandVerificationHelper = sliceBetween(
  'function meterAutoCalMagicWandCompletionRequiresVerification',
  'function meterFullAutoCalStatusRunId',
  'Magic Wand completion verification helper'
);
assert(
  magicWandVerificationHelper.includes("status.status==='complete'") &&
    magicWandVerificationHelper.includes('status.full_autocal_post_series_adjust') &&
    magicWandVerificationHelper.includes('meterAutoCalMagicWandActive||meterAutoCalMagicWandFullWorkflow') &&
    magicWandVerificationHelper.includes("meterFullAutoCalStatusPhase(status)==='magic-wand'"),
  'Magic Wand completion should require after-series verification/revert even when the backend omits the adjustment marker'
);

const autoCalApplyStatus = sliceBetween(
  'function meterAutoCalApplyStatus(status)',
  'function meterFullAutoCalCloneValue',
  'LG AutoCal status apply function'
);
assert(
  autoCalApplyStatus.includes('if(meterFullAutoCalMagicWandPendingBeforeCompletion(status)){') &&
    autoCalApplyStatus.indexOf('if(meterFullAutoCalMagicWandPendingBeforeCompletion(status)){') < autoCalApplyStatus.indexOf("meterAutoCalSetOverlay(true,{...status,phase:'complete'})"),
  'Generic LG AutoCal completion rendering should not show the Full AutoCal completion popup before selected Magic Wand runs'
);

const autoCalPoll = sliceBetween(
  'async function meterPollAutoCal',
  'async function meterAutoCalBackendRecoveryWatchdog',
  'LG AutoCal polling function'
);
assert(
  autoCalPoll.includes('if(meterFullAutoCalMagicWandPendingBeforeCompletion(r)){') &&
    autoCalPoll.indexOf('if(meterFullAutoCalMagicWandPendingBeforeCompletion(r)){') < autoCalPoll.indexOf("meterAutoCalSetOverlay(true,{...r,phase:'complete'})"),
  'LG AutoCal polling fallback should suppress generic completion before selected Magic Wand runs'
);
assert(
  (autoCalPoll.match(/meterAutoCalMagicWandCompletionRequiresVerification\(r\)/g)||[]).length >= 2 &&
    autoCalPoll.includes('await meterAutoCalFinishMagicWandAdjustment(r,{fullWorkflow:true});') &&
    autoCalPoll.indexOf('meterAutoCalMagicWandCompletionRequiresVerification(r)') < autoCalPoll.indexOf("meterFullAutoCalCompleteAfterHdrToneMap(r,undefined,'magic-wand')"),
  'LG AutoCal polling should run Magic Wand after-series verification/revert before completing, even without the backend marker'
);

const post3dPolish = sliceBetween(
  'async function meterFullAutoCalStartPost3dPolish',
  'async function meterFullAutoCalStartTouchup',
  'Full AutoCal post-3D cleanup function'
);
assert(
  /if\(magicWandEnabled\)\s*\{\s*await meterAutoCalStartMagicWand\(lutStatus,\{fullWorkflow:true\}\);\s*return true;\s*\}/.test(post3dPolish),
  'Post-3D cleanup handoff should await Magic Wand start and report that the next stage was started'
);

const lutPoll = sliceBetween(
  'async function meterPollLg3dAutoCal',
  'async function meterAutoCalStatusWatchdog',
  'LG 3D LUT polling function'
);
assert(
  lutPoll.includes('if(meterFullAutoCalMagicWandPendingBeforeCompletion(r)){') &&
    lutPoll.indexOf('if(meterFullAutoCalMagicWandPendingBeforeCompletion(r)){') < lutPoll.indexOf("meterAutoCalSetOverlay(true,{...r,autocal3d:true,phase:'complete'})"),
  'LG 3D LUT polling fallback should suppress generic completion before selected Magic Wand runs'
);

const postReport = sliceBetween(
  'async function meterFullAutoCalGeneratePostReport()',
  'async function meterFullAutoCalSkipPostReport()',
  'Full AutoCal post-report function'
);
const fenceIndex = postReport.indexOf('await meterFullAutoCalMarkCurrentCompletionStatusesHandled();');
const resetIndex = postReport.indexOf('meterFullAutoCalResetState(true);');
assert(fenceIndex >= 0, 'Post-report completion should fence stale completed worker statuses');
assert(resetIndex > fenceIndex, 'Post-report completion should fence stale worker statuses before clearing Full AutoCal state');
assert(
  postReport.includes('await meterFullAutoCalMarkCurrentCompletionStatusesHandled();\n  meterClearAutoCalStatusPollingForReport();\n  meterFullAutoCalResetState(true);'),
  'Post-report completion should clear report polling only after stale completions are fenced'
);

console.log('Full AutoCal post-report completion regression checks passed.');
