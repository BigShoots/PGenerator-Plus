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

const ddcOk = bodyOf("lg_picture_reset_ddc_baseline_ok");
assert(
  ddcOk.includes('($ddc_result->{"status"}||"") ne "ok"') &&
    ddcOk.includes('$ddc_result->{"ddc_baseline_reset"}') &&
    ddcOk.includes('$ddc_result->{"ddc_reset_verified"}'),
  "C2 white-balance reset fallback must require a successful, verified DDC baseline reset"
);

const reset = bodyOf("lg_picture_reset_workflow");
assert(
  reset.includes("my $white_balance_reset_satisfied_by_ddc=&lg_picture_reset_ddc_baseline_ok($ddc_attempted,$ddc_result);"),
  "picture reset should evaluate whether DDC baseline reset satisfied the white-balance requirement"
);
assert(
  reset.includes('if(!$generation->{"ddc_only_white_balance"} && !$white_balance_reset_satisfied_by_ddc)') &&
    reset.includes("LG picture mode reset did not clear white-balance settings"),
  "newer LGs should still fail when both user-menu white-balance reset and verified DDC reset fail"
);
assert(
  reset.includes("LG user-menu white-balance reset keys were rejected; verified LG DDC baseline reset was used instead."),
  "C2-style reset should report that verified DDC reset satisfied the unsupported user-menu white-balance reset"
);
assert(
  reset.includes("LG user-menu white-balance reset keys were rejected by this DDC-only TV; DDC calibration state was reset instead."),
  "C1/DDC-only warning path should remain available"
);
assert(
  reset.includes("white_balance_reset_satisfied_by_ddc => &json_bool($white_balance_reset_satisfied_by_ddc)"),
  "reset response should expose when DDC satisfied the white-balance reset requirement"
);

console.log("lg-c2-picture-reset-ddc-satisfies-wb-regression: ok");
