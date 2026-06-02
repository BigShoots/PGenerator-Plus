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

const capability = bodyOf("lg_generation_write_accepted_readback_unavailable_ok");
assert(
  capability.includes('$generation->{"ddc_only_white_balance"}') &&
    capability.includes('$generation->{"picture_mode_read_forbidden"}'),
  "fallback capability should be generation/capability driven"
);
assert(
  capability.includes("$webos_major && $webos_major <= 6"),
  "fallback capability should remain limited to legacy webOS6-class readback behavior"
);
assert(!capability.includes('series eq "C1"'), "fallback should not hardcode C1 by model name");

const fallback = bodyOf("lg_1d_write_accepted_readback_unavailable_ok");
assert(fallback.includes('return 0 if(ref($verify_info->{"lut"}) eq "ARRAY");'), "1D fallback must not accept non-empty mismatched LUT readbacks");
assert(fallback.includes('return 0 if(ref($expected_lut) ne "ARRAY");'), "fallback must require an expected LUT");
assert(
  fallback.includes("lg_1d_lut_readback_unavailable_reason($verify_info)"),
  "1D fallback should be driven by the observed unreadable readback contract"
);

const lut1dUnavailable = bodyOf("lg_1d_lut_readback_unavailable_reason");
assert(
  lut1dUnavailable.includes('"empty-lut-readback"') &&
    lut1dUnavailable.includes('"failed-getter"') &&
    lut1dUnavailable.includes('"unreadable-lut-payload"'),
  "1D readback-unavailable reason should cover empty payload, failed getter, and unreadable payload"
);
assert(
  lut1dUnavailable.includes("no-file-path-from-tvservice") &&
    lut1dUnavailable.includes("no\\s+file\\s+path\\s+from\\s+tvservice"),
  "1D readback-unavailable reason should classify tvservice no-file-path getter failures"
);
assert(
  lut1dUnavailable.indexOf('return "failed-getter";') < lut1dUnavailable.indexOf('return "empty-lut-readback"'),
  "1D failed getters should not be flattened into generic empty payload diagnostics"
);
assert(
  fallback.includes("lg_generation_write_accepted_readback_unavailable_ok"),
  "1D fallback should require the legacy/DDC-only capability gate in addition to an unavailable getter"
);

const ddcSet = bodyOf("lg_ddc_1d_white_balance_set");
assert(
  ddcSet.includes("($reset_ddc_baseline || $verify_ddc_upload) && &lg_1d_write_accepted_readback_unavailable_ok($generation,$verify_info,$lut)"),
  "readback-unavailable fallback must cover reset and verified 1D uploads"
);
assert(
  ddcSet.includes('$reset_readback_contract="write-accepted-readback-unavailable" if($reset_ddc_baseline);') &&
    ddcSet.includes('$upload_readback_contract="write-accepted-readback-unavailable"') &&
    ddcSet.includes("$ddc_readback_unavailable=1;") &&
    ddcSet.includes("$upload_verified=1;"),
  "1D fallback should expose the write-accepted/readback-unavailable contract"
);
assert(
  ddcSet.includes('ddc_reset_readback_unavailable => &json_bool($reset_readback_unavailable)') &&
    ddcSet.includes('ddc_upload_readback_unavailable => &json_bool($upload_readback_unavailable)') &&
    ddcSet.includes('ddc_readback_unavailable => &json_bool($ddc_readback_unavailable)') &&
    ddcSet.includes("ddc_readback_unavailable_reason => $ddc_readback_unavailable_reason") &&
    ddcSet.includes("ddc_verify_mismatch => $ddc_readback_unavailable ? $ddc_verify_mismatch : undef"),
  "1D helper response should include explicit fallback diagnostics"
);
assert(
  ddcSet.includes('if(!$upload_verified && !$reset_ddc_baseline && &lg_lut_matches_tv_readback($verify_lut,$lut))'),
  "normal non-reset upload verification should remain on the existing strict/scaled-readback path"
);

const lut3dUnavailable = bodyOf("lg_3d_lut_readback_unavailable_reason");
assert(
  lut3dUnavailable.includes("no-file-path-from-tvservice") &&
    lut3dUnavailable.includes("no\\s+file\\s+path\\s+from\\s+tvservice"),
  "3D readback-unavailable reason should cover C1 tvservice no-file-path readback errors"
);
assert(
  lut3dUnavailable.includes('"empty-lut-readback"') &&
    lut3dUnavailable.includes('"failed-getter"') &&
    lut3dUnavailable.includes('"unreadable-lut-payload"'),
  "3D readback-unavailable reason should cover empty payload, failed getter, and unreadable payload"
);

const lut3dFallback = bodyOf("lg_3d_write_accepted_readback_unavailable_ok");
assert(
  lut3dFallback.includes("return 0 if($read_ok && ref($read_lut) eq \"ARRAY\");"),
  "3D fallback must not accept non-empty mismatched LUT readbacks"
);
assert(
  lut3dFallback.includes('return 0 if(ref($expected_lut) ne "ARRAY");') &&
    lut3dFallback.includes("lg_3d_lut_readback_unavailable_reason($read_response)") &&
    lut3dFallback.includes("return 1;"),
  "3D fallback should accept write-accepted/readback-unavailable without requiring model-name metadata"
);
assert(
  !lut3dFallback.includes("lg_generation_write_accepted_readback_unavailable_ok"),
  "3D fallback should not depend on generation metadata when the getter is observably unavailable"
);

const upload3d = bodyOf("lg_3d_lut_upload_workflow");
assert(
  upload3d.includes("lg_3d_write_accepted_readback_unavailable_ok($generation,$read_ok,$read_lut,$read_response,$lut)"),
  "3D upload should allow write-accepted/readback-unavailable contract"
);
assert(
    upload3d.includes('$attempt{"upload_verify_contract"}="write-accepted-readback-unavailable";') &&
    upload3d.includes('$attempt{"readback_unavailable"}=&json_true();') &&
    upload3d.includes('$attempt{"readback_unavailable_reason"}=$readback_unavailable_reason||"readback-unavailable";') &&
    upload3d.includes('readback_unavailable_reason => $selected->{"readback_unavailable_reason"}||""') &&
    upload3d.includes("readback_unavailable => &json_bool($selected->{\"readback_unavailable\"})"),
  "3D upload response should expose fallback diagnostics"
);
assert(
  upload3d.includes('diag_log_append("3d_lut_upload:start"') &&
    upload3d.includes('diag_log_append("3d_lut_upload:attempt"') &&
    upload3d.includes('diag_log_append("3d_lut_upload:ok"') &&
    upload3d.includes('diag_log_append("3d_lut_upload:failure"'),
  "3D upload should leave compact helper breadcrumbs for start, attempts, success, and failure"
);

const reset3d = bodyOf("lg_3d_lut_reset_workflow");
assert(
  reset3d.includes('"LG 3D LUT reset write accepted; readback unavailable on this generation."'),
  "3D reset should preserve the fallback contract in its message"
);

const worker3d = fs.readFileSync("usr/bin/meter_lg_3d_autocal.pl", "utf8");
assert(
  worker3d.includes('$state->{"upload_started_at"}') &&
    worker3d.includes('$state->{"upload_request"}') &&
    worker3d.includes('$state->{"upload_completed_at"}') &&
    worker3d.includes('$state->{"upload_status"}') &&
    worker3d.includes('$state->{"upload_api_timeout"}') &&
    worker3d.includes('$state->{"upload_helper_timeout"}') &&
    worker3d.includes('$state->{"upload_json_error"}'),
  "3D worker should persist upload request/result markers that distinguish worker death from returned helper failures"
);
assert(
  worker3d.indexOf('$state->{"upload_started_at"}') < worker3d.indexOf('api_json("POST","/api/lg/3d-lut/upload"') &&
    worker3d.indexOf('$state->{"upload"}=$upload;') > worker3d.indexOf('api_json("POST","/api/lg/3d-lut/upload"') &&
    worker3d.indexOf('write_state($state);', worker3d.indexOf('$state->{"upload_json_error"}')) > worker3d.indexOf('$state->{"upload"}=$upload;'),
  "3D worker should write upload-start state before the call and upload-result state immediately after the call"
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
  workflow.includes('ddc_upload_readback_unavailable => &json_bool($ddc_result->{"ddc_upload_readback_unavailable"})') &&
    workflow.includes('ddc_readback_unavailable => &json_bool($ddc_result->{"ddc_readback_unavailable"})') &&
    workflow.includes('ddc_readback_unavailable_reason => $ddc_result->{"ddc_readback_unavailable_reason"}||""') &&
  workflow.includes('ddc_verify_mismatch => $ddc_result->{"ddc_verify_mismatch"}||undef') &&
    workflow.includes('ddc_linear_unity_diagnostics => $ddc_result->{"ddc_linear_unity_diagnostics"}||undef'),
  "outer picture-set result should preserve fallback diagnostics"
);

console.log("lg-c1-ddc-reset-readback-unavailable-regression: ok");
