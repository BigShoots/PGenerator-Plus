#!/usr/bin/env node
"use strict";

const assert = require("assert");
const fs = require("fs");

const source = fs.readFileSync("usr/bin/meter_lg_autocal.pl", "utf8");

function bodyOf(name) {
  const start = source.indexOf(`sub ${name} {`);
  assert(start >= 0, `${name} helper should exist`);
  const next = source.indexOf("\nsub ", start + 5);
  return source.slice(start, next >= 0 ? next : source.length);
}

const enabled = bodyOf("sdr_initial_99_rgb_balance_enabled");
assert(enabled.includes("sdr_initial_autocal_context_enabled($config,$step)"), "99 RGB balance must be initial AutoCal scoped");
assert(enabled.includes("lg_autocal_26_sdr_headroom_enabled($config)"), "99 RGB balance must be SDR LG26 scoped");
assert(enabled.includes('abs(($step->{"ire"}+0)-99) <= 0.001'), "99 RGB balance must be 99-only");

const disabledPair = bodyOf("legal_white_pair_disabled_for_sdr_initial_99");
assert(!disabledPair.includes("sdr_initial_99_rgb_balance_enabled"), "standalone 99 tuning must not re-enable hidden 99/100 pairing");

assert(source.includes("return 0 if(sdr_initial_99_rgb_balance_needs_work($config,$read_step,$reading,$target_delta));"), "99 should not declare target reached while RGB balance still needs work");
assert(source.includes("sdr_initial_99_rgb_balance_adjustments($config,$err,$arrays,$target,$read_step,$de,$target_delta,$stalls,\\%tried_values,0)"), "main loop should try 99 RGB-balance moves");
assert(source.includes("sdr_initial_99_rgb_balance_adjustments($LG_AUTOCAL_CONFIG,$error,$arrays,$target,$step,$de,$target_delta,$stalls,$tried,1)"), "fine tune should try 99 RGB-balance moves");
assert(source.includes("sdr_99_rgb_balance_keep"), "candidate/best preservation should mark 99 RGB-balance keeps");

function balanceLimit(targetDelta = 0.5) {
  let limit = targetDelta / 100;
  if (limit < 0.0045) limit = 0.0045;
  if (limit > 0.0080) limit = 0.0080;
  return limit;
}

function score(de, rgb, targetDelta = 0.5) {
  const excess = rgb - balanceLimit(targetDelta);
  return de + (excess > 0 ? Math.min(excess * 120, 3) : 0);
}

function keepCandidate(candidate, best, targetDelta = 0.5) {
  const limit = balanceLimit(targetDelta);
  if (candidate.rgb + 0.0005 >= best.rgb) return false;
  const deAllowance = candidate.rgb <= limit ? 0.18 : 0.08;
  if (candidate.de > best.de + deAllowance) return false;
  if (best.rgb > limit && candidate.rgb + 0.0008 < best.rgb) return true;
  return candidate.rgb + 0.0015 < best.rgb && candidate.de <= best.de + 0.03;
}

const best = { de: 0.50, rgb: 0.014 };
const tighterComparable = { de: 0.56, rgb: 0.0055 };
const lowerDeLooseRgb = { de: 0.46, rgb: 0.0135 };
const tooMuchDeDamage = { de: 0.70, rgb: 0.0050 };

assert(score(tighterComparable.de, tighterComparable.rgb) < score(best.de, best.rgb), "RGB penalty should prefer tighter 99 RGB when dE is comparable");
assert(keepCandidate(tighterComparable, best), "candidate keep should preserve tighter 99 RGB when dE is comparable");
assert(!keepCandidate(lowerDeLooseRgb, best), "candidate keep should not call a loose-RGB candidate an RGB-balance improvement");
assert(!keepCandidate(tooMuchDeDamage, best), "candidate keep should not trade too much dE for RGB balance");

console.log("lg-autocal-99-standalone-rgb-balance-regression: ok");
