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
