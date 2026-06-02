#!/usr/bin/env node
"use strict";

const assert = require("assert");
const fs = require("fs");

const source = fs.readFileSync("usr/sbin/pgenerator-lg", "utf8");

function bodyOf(name) {
  const start = source.indexOf(`sub ${name} (@) {`);
  assert(start >= 0, `${name} helper should exist`);
  const next = source.indexOf("\nsub ", start + 5);
  return source.slice(start, next >= 0 ? next : source.length);
}

const fallback = bodyOf("lg_ddc_reset_readback_unavailable_ok");
assert(fallback.includes('return 0 if(ref($verify_lut) eq "ARRAY");'), "fallback must not accept non-empty mismatched LUT readbacks");
assert(fallback.includes('return 0 if(ref($expected_lut) ne "ARRAY");'), "fallback must require an expected LUT");
assert(fallback.includes('return 1 if($series eq "C1");'), "fallback must explicitly cover C1");
assert(
  fallback.includes("return 1 if($ddc_only && $webos_major && $webos_major <= 6);"),
  "fallback must stay limited to old/DDC-only webOS6-class sets"
);

const ddcSet = bodyOf("lg_ddc_1d_white_balance_set");
assert(
  ddcSet.includes("$reset_ddc_baseline && &lg_ddc_reset_readback_unavailable_ok($generation,$verify_lut,$lut)"),
  "readback-unavailable fallback must be reset-baseline scoped"
);
assert(
  ddcSet.includes('$reset_readback_contract="write-accepted-readback-unavailable";') &&
    ddcSet.includes("$reset_readback_unavailable=1;") &&
    ddcSet.includes("$upload_verified=1;"),
  "fallback should expose the write-accepted/readback-unavailable contract"
);
assert(
  ddcSet.includes('ddc_reset_readback_unavailable => &json_bool($reset_readback_unavailable)') &&
    ddcSet.includes("ddc_verify_mismatch => $reset_readback_unavailable ? $reset_verify_mismatch : undef"),
  "helper response should include explicit fallback diagnostics"
);
assert(
  ddcSet.includes('if(!$upload_verified && !$reset_ddc_baseline && &lg_lut_matches_tv_readback($verify_lut,$lut))'),
  "normal non-reset upload verification should remain on the existing strict/scaled-readback path"
);

const workflow = bodyOf("lg_picture_set_workflow");
assert(
  workflow.includes("lg_ddc_1d_white_balance_set($session,$ip,$active_picture_mode,$settings_to_apply,$connect_timeout + 4,$keep_calibration_mode,$calibration_mode_active,$reset_ddc_baseline,$verify_ddc_upload,$generation)"),
  "picture-set DDC path should pass generation info into reset verification"
);
assert(
  workflow.includes('ddc_reset_readback_unavailable => &json_bool($ddc_result->{"ddc_reset_readback_unavailable"})'),
  "outer picture-set result should preserve the fallback marker"
);
assert(
  workflow.includes('ddc_verify_mismatch => $ddc_result->{"ddc_verify_mismatch"}||undef') &&
    workflow.includes('ddc_linear_unity_diagnostics => $ddc_result->{"ddc_linear_unity_diagnostics"}||undef'),
  "outer picture-set result should preserve fallback diagnostics"
);

console.log("lg-c1-ddc-reset-readback-unavailable-regression: ok");
