#!/usr/bin/env node
"use strict";

const assert = require("assert");
const fs = require("fs");

const source = fs.readFileSync("usr/share/PGenerator/webui.pm", "utf8");

function sliceFunction(name) {
  const token = `async function ${name}(`;
  const start = source.indexOf(token);
  assert(start >= 0, `Missing ${name}`);
  const nextAsync = source.indexOf("\nasync function ", start + token.length);
  const nextFunction = source.indexOf("\nfunction ", start + token.length);
  const end = [nextAsync, nextFunction].filter(index => index > start).sort((a, b) => a - b)[0] || source.length;
  return source.slice(start, end);
}

const resetDdc = sliceFunction("meterAutoCalResetDdc");
assert(
  resetDdc.includes("reset_ddc_baseline:true"),
  "preflight reset should still clear the LG DDC baseline during the wizard"
);

const confirmStart = sliceFunction("meterAutoCalConfirmAndStart");
const payloadStart = confirmStart.indexOf("meterMeasurementSignalContext({");
assert(payloadStart >= 0, "main AutoCal start should build a worker payload");
const payload = confirmStart.slice(payloadStart, confirmStart.indexOf("steps:autocalSteps", payloadStart));

assert(
  payload.includes("force_ddc_white_balance:true") &&
    payload.includes("restore_factory_levels:false") &&
    payload.includes("reset_ddc_baseline:false"),
  "main AutoCal worker payload should not repeat picture/default/DDC reset after the wizard reset completes"
);

assert(
  payload.indexOf("restore_factory_levels:false") > payload.indexOf("force_ddc_white_balance:true") &&
    payload.indexOf("reset_ddc_baseline:false") > payload.indexOf("restore_factory_levels:false"),
  "handoff reset suppression should live with the LG DDC payload controls"
);

console.log("lg-autocal-preflight-handoff-regression: ok");
