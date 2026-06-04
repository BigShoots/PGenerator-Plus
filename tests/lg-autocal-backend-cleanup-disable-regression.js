#!/usr/bin/env node
'use strict';

const fs = require('fs');
const assert = require('assert');

const worker = fs.readFileSync('usr/bin/meter_lg_autocal.pl', 'utf8');

function sliceBetween(startNeedle, endNeedle, label) {
  const start = worker.indexOf(startNeedle);
  assert(start >= 0, `${label} start should exist`);
  const end = worker.indexOf(endNeedle, start);
  assert(end > start, `${label} end should exist`);
  return worker.slice(start, end);
}

const postCommitPolishEnabled = sliceBetween(
  'sub post_commit_polish_enabled {',
  'sub post_3d_committed_polish_requested {',
  'post commit polish gate'
);
assert(
  postCommitPolishEnabled.includes('return 0;') &&
    !postCommitPolishEnabled.includes('return 1 if(!exists($config->{"post_commit_polish"}));') &&
    !postCommitPolishEnabled.includes('return $config->{"post_commit_polish"} ? 1 : 0;'),
  'backend post-commit polish must be hard-disabled, including stale configs that omit post_commit_polish'
);

const post3dPolishRequested = sliceBetween(
  'sub post_3d_committed_polish_requested {',
  'sub post_commit_verify_enabled {',
  'post-3D committed polish gate'
);
assert(
  post3dPolishRequested.includes('return 0;') &&
    !post3dPolishRequested.includes('$config->{"post_commit_polish"}'),
  'direct full_autocal_post_3d_polish payloads must not be able to request committed polish'
);

const dispatch = sliceBetween(
  'if(autocal_config_is_post_series_revert($config)) {',
  'my $finalize_calibrated_26pt_slot=sub {',
  'worker mode dispatch'
);
assert(
  dispatch.indexOf('autocal_config_is_post_series_adjust($config)') >= 0 &&
    dispatch.indexOf('autocal_config_is_touchup($config)') >
      dispatch.indexOf('autocal_config_is_post_series_adjust($config)') &&
    dispatch.indexOf('autocal_config_is_touchup($config)') <
      dispatch.indexOf('autocal_config_is_post_3d_polish($config)') &&
    dispatch.includes('$state->{"full_autocal_touchup_skipped"}=JSON::PP::true;'),
  'stale touch-up configs should be skipped after Magic Wand modes, before normal greyscale calibration can start'
);

assert(
  dispatch.includes('$state->{"full_autocal_post_series_adjust"}=JSON::PP::true;') &&
    dispatch.includes('$state->{"full_autocal_post_series_revert"}=JSON::PP::true;'),
  'Magic Wand adjust/revert modes should remain available before the cleanup disable gates'
);

const committedPolish = sliceBetween(
  'sub committed_state_polish {',
  'sub end_calibration_mode',
  'committed state polish'
);
assert(
  committedPolish.includes('my @shadow=sort { ($b->{"ire"}||0) <=> ($a->{"ire"}||0) }') &&
    committedPolish.includes('$include_shadow=0;') &&
    !committedPolish.includes('push @polish,@shadow if($include_shadow);') &&
    !committedPolish.includes('post_commit_low_shadow_settle_ms') &&
    !committedPolish.includes('Settling panel before committed low-shadow polish'),
  'committed polish should not pause for a low-shadow committed-state settle after bottom patches'
);

console.log('LG AutoCal backend cleanup disable regression checks passed.');
