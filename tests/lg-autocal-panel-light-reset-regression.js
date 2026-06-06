#!/usr/bin/env node
"use strict";

const assert = require("assert");
const fs = require("fs");

const source = fs.readFileSync("usr/share/PGenerator/webui.pm", "utf8");

function sliceFunction(name) {
  const asyncToken = `async function ${name}(`;
  const functionToken = `function ${name}(`;
  let start = source.indexOf(asyncToken);
  if (start < 0) start = source.indexOf(functionToken);
  assert(start >= 0, `Missing ${name}`);
  const nextAsync = source.indexOf("\nasync function ", start + 1);
  const nextFunction = source.indexOf("\nfunction ", start + 1);
  const end = [nextAsync, nextFunction].filter(index => index > start).sort((a, b) => a - b)[0] || source.length;
  return source.slice(start, end);
}

const resetDdc = sliceFunction("meterAutoCalResetDdc");
assert(
  resetDdc.includes("if(typeof lgDisplayControlInvalidate==='function') lgDisplayControlInvalidate();") &&
    resetDdc.includes("const resetPicture={...((pictureModeReset&&pictureModeReset.picture_settings)||{}),...((response&&response.picture_settings)||{})};") &&
    resetDdc.indexOf("lgDisplayControlInvalidate") < resetDdc.indexOf("const resetPicture="),
  "AutoCal reset should invalidate stale Display Control cache and preserve reset picture panel-light values"
);

const luminanceSetup = sliceFunction("meterAutoCalLuminanceSetupLoop");
assert(
  luminanceSetup.includes("meterAutoCalResetPanelLightState();") &&
    luminanceSetup.includes("await meterAutoCalLoadPanelLightValue(true);") &&
    luminanceSetup.indexOf("meterAutoCalResetPanelLightState();") < luminanceSetup.indexOf("await meterAutoCalLoadPanelLightValue(true);") &&
    !luminanceSetup.includes("meterAutoCalSeedPanelLightFromDisplayControl();"),
  "Luminance setup should force a fresh TV panel-light read instead of trusting the cached Display Control value"
);

const startAutoCal = sliceFunction("meterStartAutoCal");
assert(
  startAutoCal.includes("meterAutoCalResetPanelLightState();"),
  "Starting AutoCal should clear queued/stale panel-light state through the shared helper"
);

console.log("lg-autocal-panel-light-reset-regression: ok");
