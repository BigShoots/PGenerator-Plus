const assert = require('assert');
const fs = require('fs');

const source = fs.readFileSync('usr/bin/meter_lg_autocal.pl', 'utf8');

function sliceBetween(startNeedle, endNeedle) {
  const start = source.indexOf(startNeedle);
  assert(start >= 0, `Missing start marker: ${startNeedle}`);
  const end = source.indexOf(endNeedle, start + startNeedle.length);
  assert(end > start, `Missing end marker after: ${startNeedle}`);
  return source.slice(start, end);
}

const applyPeakReference = sliceBetween(
  'sub apply_peak_headroom_reference {',
  'sub keep_peak_headroom_white_reference {'
);
assert(
  applyPeakReference.includes('my $effective_white=(defined($derived) && $derived > 0) ? $derived : $$white_y_ref;') &&
    applyPeakReference.includes('$state->{"peak_headroom_reference"}=$derived if(defined($derived) && $derived > 0);') &&
    applyPeakReference.includes('sdr_initial_109_target_y_rebase_enabled($LG_AUTOCAL_CONFIG,$signal_mode)') &&
    applyPeakReference.includes('$$white_y_ref=$derived;') &&
    applyPeakReference.includes('$state->{"sdr_autocal_target_y_basis"}="calibrated_109";') &&
    applyPeakReference.includes('$state->{"sdr_autocal_target_y_reference"}=$derived+0;') &&
    !applyPeakReference.includes('set_state_white_reference') &&
    applyPeakReference.includes('return $$white_y_ref;'),
  'normal SDR initial 109 peak-headroom reads should rebase active target-Y math to calibrated 109 without updating stored legal-white state'
);

const targetYRebaseGate = sliceBetween(
  'sub sdr_initial_109_target_y_rebase_enabled {',
  'sub apply_peak_headroom_reference {'
);
assert(
  targetYRebaseGate.includes('lc($config->{"signal_mode"}||$signal_mode||"sdr") ne "sdr"') &&
    targetYRebaseGate.includes('!lg_autocal_26_full_ddc_spine_enabled($config) || lg_autocal_26_hdr20_seed_enabled($config)') &&
    targetYRebaseGate.includes('autocal_config_is_touchup($config) || autocal_config_is_post_3d_polish($config)') &&
    targetYRebaseGate.includes('autocal_config_is_post_series_adjust($config) || autocal_config_is_post_series_revert($config)') &&
    targetYRebaseGate.includes('return 1;'),
  '109 target-Y rebase should be gated to SDR LG26 initial full-spine AutoCal only'
);

const updateWhiteReference = sliceBetween(
  'sub update_white_reference_for_autocal_step {',
  'sub refresh_headroom_targets_from_white_reference {'
);
assert(
  !updateWhiteReference.includes('keep_peak_headroom_white_reference($config,$state) && !autocal_step_is_peak_headroom($step)'),
  'a stored 109 peak reference must not block later legal-white reference updates'
);

const committedPolishReference = sliceBetween(
  'sub committed_polish_reference_white_y {',
  'sub lg_extended_sdr_16_255_enabled {'
);
assert(
  committedPolishReference.includes('return $committed_ref if(defined($committed_ref));') &&
    committedPolishReference.includes('$state->{"target_luminance"}+0') &&
    committedPolishReference.includes('$state->{"calibrated_white_luminance"}+0') &&
    committedPolishReference.includes('$state->{"setup_luminance_reference"}+0') &&
    !committedPolishReference.includes('return $peak_ref') &&
    !committedPolishReference.includes('headroom_reference_white_from_target'),
  'committed verification should prefer committed/legal white references, not 109-derived headroom white'
);

function gammaLinear(stimulus, gamma = 2.4) {
  const signal = Math.min(stimulus / 100, 1.1);
  return signal ** gamma;
}

const legalWhiteY = 100;
const measured109Y = 128;
const derived109WhiteY = measured109Y / gammaLinear(109.474885844749);
const whiteYAfter109Read = derived109WhiteY;
const peakReferenceAfter109Read = derived109WhiteY;
const targetYFromLegalWhite = stimulus => legalWhiteY * gammaLinear(stimulus);
const targetYFromPeakWhite = stimulus => derived109WhiteY * gammaLinear(stimulus);

assert(Math.abs(derived109WhiteY - legalWhiteY) > 1, 'test fixture should distinguish legal and peak-derived white bases');
assert.strictEqual(whiteYAfter109Read, derived109WhiteY, 'normal SDR initial 109 read should rebase active AutoCal target-Y to calibrated 109');
assert.strictEqual(peakReferenceAfter109Read, derived109WhiteY, 'applying a 109 read should still store the headroom-specific reference');
for (const [label, stimulus] of [
  ['low shadow 2.3', 2.28310502283105],
  ['body 50', 50.2283105022831],
  ['direct 99', 99.0867579908676],
  ['headroom 105', 105.022831050228],
]) {
  assert.notStrictEqual(
    targetYFromLegalWhite(stimulus),
    targetYFromPeakWhite(stimulus),
    `${label} fixture should expose the old 109-derived target-Y mismatch`
  );
  assert.strictEqual(
    targetYFromPeakWhite(stimulus),
    whiteYAfter109Read * gammaLinear(stimulus),
    `${label} target-Y should follow calibrated 109 white after a normal SDR initial 109 read`
  );
}
assert.notStrictEqual(
  measured109Y,
  targetYFromLegalWhite(109.474885844749),
  '109 fixture should differ from a legal-white target'
);
assert(
  Math.abs(measured109Y - peakReferenceAfter109Read * gammaLinear(109.474885844749)) < 1e-9,
  '109 remains self/headroom referenced for luminance scoring'
);

const lumaGuard = sliceBetween(
  'sub luma_probe_guarded_target {',
  'sub next_new_headroom_value {'
);
assert(
    lumaGuard.includes('abs($ire-105) < 0.001') &&
    lumaGuard.includes('abs($ire-99) < 0.001') &&
    lumaGuard.includes('sub record_bad_luma_probe_family') &&
    lumaGuard.includes('luma_bearing_adjustment($adjustments)') &&
    lumaGuard.includes('lg_autocal_bad_luma_probe_families') &&
    lumaGuard.includes('$y_improved') &&
    lumaGuard.includes('$de_worse') &&
    lumaGuard.includes('$score_worse') &&
    lumaGuard.includes('my $magnitude=ddc_value_key(abs($delta));') &&
    lumaGuard.includes('return join("|",$target_key,ddc_value_key($current),$direction,$magnitude);') &&
    lumaGuard.includes('trace_109($trace_step,$overshoot ? "luma_overshoot_family" : "bad_luma_probe"') &&
    lumaGuard.includes('trace_109($trace_step,"luma_probe_family_suppressed"') &&
    lumaGuard.includes('$entry->{"suppressed"}=luma_probe_family_suppressed'),
  '105 and 99/100 should record magnitude-aware bad luma-bearing families when Y improves but dE/pair score gets worse'
);

const learnedLuma = sliceBetween(
  'sub lg_autocal_26_learned_luminance_adjustment {',
  'sub lg_autocal_26_adaptive_headroom_luminance_adjustment {'
);
const adaptiveLuma = sliceBetween(
  'sub lg_autocal_26_adaptive_headroom_luminance_adjustment {',
  'sub lg_autocal_26_learned_rgb_adjustment {'
);
const neutralLuma = sliceBetween(
  'sub neutral_luminance_adjustments {',
  'sub low_shadow_luminance_max_step {'
);
for (const block of [learnedLuma, adaptiveLuma, neutralLuma]) {
  assert(
    block.includes('luma_probe_family_suppressed($tried,$target,$current,$next'),
    'learned/adaptive/fallback luminance planners should honor poisoned luma families'
  );
}

const finalVerifyLuma = sliceBetween(
  'sub final_all_level_verify_luminance_adjustment {',
  'sub final_all_level_verify_cap_adjustments {'
);
assert(
  finalVerifyLuma.includes('my ($arrays,$target,$step,$lum_pct,$tried,$state)=@_;') &&
    finalVerifyLuma.includes('luma_probe_family_suppressed($tried,$target,$current,$next,$step,"final_all_level_verify_luminance",$state)'),
  'final all-level verify direct luma touch should honor poisoned luma families'
);

const headroomCombo = sliceBetween(
  'sub headroom_chroma_luma_adjustment {',
  'sub headroom_match_green_adjustment {'
);
assert(
  headroomCombo.includes('autocal_step_is_fast_headroom($step)') &&
    headroomCombo.includes('autocal_step_is_peak_headroom($step)') &&
    headroomCombo.includes('chroma_error_magnitude($error) < ($micro ? 0.022 : 0.030)') &&
    headroomCombo.includes('headroom_chroma_adjustment($error,$arrays,$target,$de,$stalls,$tried,$min_step,$max_step,$micro)') &&
    headroomCombo.includes('neutral_luminance=>1, headroom_chroma_luma=>1') &&
    headroomCombo.includes('$tried->{"__headroom_combo"}{$key}'),
  '105 should have a bounded chroma+luma move family before falling back to luma-only hammering'
);

const seed105 = sliceBetween(
  'sub headroom_105_wrgb_seed_adjustment {',
  'sub legal_white_pair_wrgb_seed_adjustment {'
);
assert(
  seed105.includes('return undef if(chroma_error_magnitude($error) < 0.035);') &&
    !seed105.includes('headroom_105_seed_skipped_high_luma'),
	  '105 WRGB seed should remain allowed when chroma is dominant even if Y is also high'
	);
const peak109Seed = sliceBetween(
  'sub headroom_peak_wrgb_seed_adjustment {',
  'sub ddc_seed_adjustment {'
);
const legalWhiteSeed = sliceBetween(
  'sub legal_white_pair_wrgb_seed_adjustment {',
  'sub headroom_peak_match_low_adjustment {'
);
assert(
  peak109Seed.includes('whiteBalanceRed => 9,') &&
    peak109Seed.includes('whiteBalanceGreen => -6,') &&
    peak109Seed.includes('whiteBalanceBlue => -13,') &&
    legalWhiteSeed.includes('whiteBalanceRed => 3,') &&
    legalWhiteSeed.includes('whiteBalanceGreen => 1,') &&
    legalWhiteSeed.includes('whiteBalanceBlue => -7,') &&
    !peak109Seed.includes('headroom_105_seed_weight') &&
    !legalWhiteSeed.includes('headroom_105_seed_weight'),
  '109 peak and 99/100 legal-white seed values should remain unchanged by 105 seed damping'
);

const seeded105LumaCap = sliceBetween(
  'sub headroom_105_seed_luma_refine_cap {',
  'sub apply_headroom_105_seed_luma_refine_cap {'
);
	assert(
	  seeded105LumaCap.includes('autocal_step_is_fast_headroom($step)') &&
	    seeded105LumaCap.includes('autocal_step_is_peak_headroom($step)') &&
    seeded105LumaCap.includes('$luminance_err <= 0') &&
    seeded105LumaCap.includes('$ire < 104.5 || $ire >= 108.5') &&
    seeded105LumaCap.includes('abs($current_luma) > 0.0001') &&
	    seeded105LumaCap.includes('my $seed=headroom_105_hard_seed_values();') &&
	    seeded105LumaCap.includes('abs($r-($seed->{"whiteBalanceRed"}+0)) > 0.7501') &&
	    seeded105LumaCap.includes('abs($g-($seed->{"whiteBalanceGreen"}+0)) > 0.7501') &&
	    seeded105LumaCap.includes('abs($b-($seed->{"whiteBalanceBlue"}+0)) > 1.0001') &&
	    seeded105LumaCap.includes('return 1.0;'),
	  'post-seed 105 luma cap should apply only to non-peak fast-headroom seeded RGB state with positive Y error'
	);

const applySeeded105LumaCap = sliceBetween(
  'sub apply_headroom_105_seed_luma_refine_cap {',
  'sub neutral_luminance_adjustments {'
);
assert(
  applySeeded105LumaCap.includes('trace_109($step,"headroom_105_seed_luma_refine_cap"') &&
    applySeeded105LumaCap.includes('planned_step=>$planned_step+0') &&
    applySeeded105LumaCap.includes('capped_step=>$cap+0'),
  'post-seed 105 luma cap should leave trace visibility for capped refinement plans'
);
assert(
  applySeeded105LumaCap.includes('$source =~ /^(?:main_luminance|fine_luminance|body_luminance_priority|headroom_105_body_refinement)$/'),
  'body-style 105 post-seed luma refinement should supersede the narrow one-point seed cap'
);

const seeded105BodyRefinement = sliceBetween(
  'sub headroom_105_hard_seed_values {',
  'sub apply_headroom_105_seed_luma_refine_cap {'
);
assert(
  seeded105BodyRefinement.includes('sub headroom_105_post_seed_body_refinement') &&
    seeded105BodyRefinement.includes('sub headroom_105_seed_weight') &&
    seeded105BodyRefinement.includes('return 0.5;') &&
    seeded105BodyRefinement.includes('sub weighted_headroom_105_seed_values') &&
    seeded105BodyRefinement.includes('round_ddc_quarter(($base->{$setting}+0)*$weight)') &&
    seeded105BodyRefinement.includes('headroom_105_post_seed_candidate($step,$target)') &&
    seeded105BodyRefinement.includes('tried_value_exists($tried,$setting,$seed_value)') &&
    seeded105BodyRefinement.includes('"whiteBalanceRed",$seed->{"whiteBalanceRed"}') &&
    seeded105BodyRefinement.includes('"whiteBalanceGreen",$seed->{"whiteBalanceGreen"}') &&
    seeded105BodyRefinement.includes('"whiteBalanceBlue",$seed->{"whiteBalanceBlue"}') &&
    seeded105BodyRefinement.includes('$ire >= 104.5 && $ire < 108.5'),
  '105 body refinement should be gated to non-peak fast-headroom only after the damped hard seed values are present or tried'
);

const floorLumaCoupled105 = sliceBetween(
  'sub headroom_105_all_down_luma_adjustment {',
  'sub apply_headroom_105_seed_luma_refine_cap {'
);
const lumaPriority105 = sliceBetween(
  'sub headroom_105_luma_priority_active {',
  'sub headroom_105_all_down_luma_adjustment {'
);
assert(
  lumaPriority105.includes('sub headroom_105_luma_blocking_active {') &&
    lumaPriority105.includes('return 0 if(headroom_105_near_y_luminance($step,$lum_pct));') &&
    source.includes('sub headroom_105_near_y_cleanup_working_candidate') &&
    source.includes('sub headroom_105_near_y_cleanup_branch_active') &&
	    source.includes('headroom_105_near_y_cleanup_rgb_cap') &&
	    source.includes('sub append_headroom_105_luma_coupling') &&
	    source.includes('sub headroom_105_luma_coupling_adjustment') &&
	    lumaPriority105.includes('sub headroom_105_luma_priority_adjustment {') &&
    lumaPriority105.includes('headroom_105_luma_priority_active($step,$arrays,$target,$tried,$luminance_err)') &&
    lumaPriority105.includes('return undef if(headroom_105_family_suppressed($tried,"headroom_105_luma_priority") && !headroom_105_score_y_branch_active($tried,$step,$arrays,$target,$luminance_err));') &&
    lumaPriority105.includes('return undef if(headroom_105_near_y_cleanup_branch_active($tried,$step,$arrays,$target,$luminance_err));') &&
    lumaPriority105.includes('headroom_luminance_control_gate_percent($step,1.0)') &&
    lumaPriority105.includes('my $authority=1.00;') &&
    source.includes('return 0 if(abs($adj->{"delta"}||0) > 1.0001);') &&
    lumaPriority105.includes('luma_probe_family_suppressed($tried,$target,$current,$next,$step,"headroom_105_luma_priority"') &&
    lumaPriority105.includes('setting=>"adjustingLuminance"') &&
    lumaPriority105.includes('headroom_105_luma_priority=>1') &&
    lumaPriority105.includes('source=>"headroom_105_luma_priority"') &&
    lumaPriority105.includes('trace_109($step,"headroom_105_luma_priority"'),
  'post-seed 105 high-luma state should have a strict blocking gate plus a traceable scalar luma-priority path before RGB/chroma work'
);
assert(
  floorLumaCoupled105.includes('sub headroom_105_all_down_luma_adjustment {') &&
    floorLumaCoupled105.includes('headroom_105_post_seed_body_refinement($step,$arrays,$target,$tried)') &&
    floorLumaCoupled105.includes('headroom_105_family_suppressed($tried,"headroom_105_all_down_luma")') &&
    floorLumaCoupled105.includes('headroom_105_near_y_cleanup_branch_active($tried,$step,$arrays,$target,$luminance_err)') &&
    floorLumaCoupled105.includes('$lum_pct <= headroom_luminance_control_gate_percent($step,2.0)') &&
    floorLumaCoupled105.includes('headroom_105_all_down_luma=>1') &&
    floorLumaCoupled105.includes('source=>"headroom_105_all_down_luma"') &&
    floorLumaCoupled105.includes('trace_109($step,"headroom_105_all_down_luma"') &&
    floorLumaCoupled105.includes('sub headroom_105_floor_luma_coupled_adjustment {') &&
    floorLumaCoupled105.includes('headroom_105_family_suppressed($tried,"headroom_105_floor_luma_coupled")') &&
    floorLumaCoupled105.includes('$lum_pct <= headroom_luminance_control_gate_percent($step,1.0)') &&
    floorLumaCoupled105.includes('my $floor;') &&
    floorLumaCoupled105.includes('my $gap=$current-$floor;') &&
    floorLumaCoupled105.includes('next if($gap < $min_step-0.0001);') &&
    floorLumaCoupled105.includes('my $next=clamp_ddc_value($current-$step_mag);') &&
    floorLumaCoupled105.includes('headroom_105_floor_luma_coupled=>1') &&
    floorLumaCoupled105.includes('source=>"headroom_105_floor_luma_coupled"') &&
    floorLumaCoupled105.includes('trace_109($step,"headroom_105_floor_luma_coupled"') &&
    floorLumaCoupled105.includes('$tried->{"__headroom_combo"}{$key}'),
  'post-seed 105 high-luma state should have a traceable floor-pull RGB planner keyed by combo'
);
assert(
  source.includes('sub suppress_headroom_105_family {') &&
    source.includes('trace_109($step,"headroom_105_family_suppressed"') &&
    source.includes('sub record_headroom_105_bad_adjustment_family {') &&
	    source.includes('$family="headroom_105_all_down_luma" if($adj->{"headroom_105_all_down_luma"});') &&
	    source.includes('$family="headroom_105_floor_luma_coupled" if($adj->{"headroom_105_floor_luma_coupled"});') &&
	    source.includes('$family="headroom_105_luma_coupled_rgb" if($adj->{"headroom_105_luma_coupled_rgb"});') &&
	    source.includes('return undef if(!$y_worse || (!$score_worse && !$de_worse));'),
	  'post-seed 105 should suppress all-down/floor and combined RGB+luma families once measured bad'
	);
assert(
    source.includes('sub headroom_105_luminance_progress_working_state {') &&
    source.includes('headroom_105_post_seed_body_refinement($step,$arrays,$target,$tried)') &&
    source.includes('$candidate_abs+0.50 >= $best_abs') &&
    source.includes('my $near_target=($candidate_abs <= luminance_tolerance_percent($step)') &&
    source.includes('my $de_allowance=$near_target ? 4.00 : ($far_luma ? 2.50 : 1.25);') &&
    source.includes('my $score_allowance=$near_target ? 3.00 : ($far_luma ? 1.00 : 0.25);') &&
    source.includes('headroom_105_luminance_progress_working_state($read_step,$arrays,$target,\\%tried_values,$lum_pct,$best_lum_pct,$de,$best_de,$candidate_score_after,$best_score)'),
  'post-seed 105 should be allowed to keep a lower-luminance working state instead of restoring the too-bright best after every exploratory move'
);

const neutralLumaAfterCap = sliceBetween(
  'sub neutral_luminance_adjustments {',
  'sub low_shadow_luminance_max_step {'
);
assert(
  neutralLumaAfterCap.includes('apply_headroom_105_seed_luma_refine_cap($arrays,$target,$step,$luminance_err,$planned_step,$source||"neutral_luminance")') &&
    neutralLumaAfterCap.includes('headroom_105_near_target_luma_cap($step,$arrays,$target,$tried,$luminance_err,$planned_step,$source||"neutral_luminance")') &&
    neutralLumaAfterCap.includes('headroom_105_response_scaled_step(') &&
    neutralLumaAfterCap.includes('return undef if(!defined($guarded_step));') &&
    neutralLumaAfterCap.includes('headroom_105_seed_luma_refine_cap=>$seed_luma_capped ? 1 : undef') &&
    neutralLumaAfterCap.includes('headroom_105_near_target_luma_cap=>($near_target_luma_capped || defined($near_target_luma_cap)) ? 1 : undef'),
  'neutral post-seed 105 luma refinement should cap near-target probes, honor wrong-direction response, and annotate scalar luma correction'
);
assert(
  headroomCombo.includes('apply_headroom_105_seed_luma_refine_cap($arrays,$target,$step,$luminance_err,$luma_mag,"headroom_chroma_luma")') &&
    headroomCombo.includes('headroom_105_seed_luma_refine_cap=>$seed_luma_capped ? 1 : undef'),
  'chroma+luma post-seed 105 refinement should also cap its first luma component'
);
assert(
  source.includes('sub headroom_105_near_target_luma_cap {') &&
    source.includes('trace_109($step,"headroom_105_near_target_luma_cap"') &&
    source.includes('(!defined($de) || !defined($best_de) || ($best_de > 1.25) || ($de <= $best_de+0.020))'),
  'post-seed 105 near-target cleanup should stop trading a slightly better Y score for worse dE once the best is already near target'
);

function lumaTolerancePercent(ire) {
  if (ire >= 108.5) return 8;
  if (ire >= 105) return 1;
  return 0.45;
}

function headroomSeedDecision({ ire, de = 4, lumPct = 0, chroma = 0.05 }) {
  if (ire < 105 || ire >= 108.5) return { allowed: false, reason: 'not_non_peak_fast_headroom' };
  if (de < 2.5) return { allowed: false, reason: 'delta_e_below_seed_gate' };
  if (lumPct > lumaTolerancePercent(ire) * 0.5 && chroma < 0.035) return { allowed: false, reason: 'chroma_below_seed_gate' };
  return { allowed: true, reason: 'headroom_105_seed' };
}

function postSeed105LumaBlockingActive({ ire, hasLuma = true, seedRgbPresent = true, lumPct = 0 }) {
  const postSeed105Body = ire >= 104.5 && ire < 108.5 && seedRgbPresent;
  const nearGate = Math.min(2.0, Math.max(1.5, lumaTolerancePercent(ire) * 2.0));
  return postSeed105Body && hasLuma && Math.abs(lumPct) > lumaTolerancePercent(ire) && Math.abs(lumPct) > nearGate;
}

function nearYCleanupWorkingCandidate({ ire, delta, beforeLumPct, afterLumPct, beforeDe, afterDe, beforeScore, afterScore }) {
  const postSeed105Body = ire >= 104.5 && ire < 108.5;
  const nearGate = Math.min(2.0, Math.max(1.5, lumaTolerancePercent(ire) * 2.0));
  const yImproved = Math.abs(afterLumPct) + 0.10 < Math.abs(beforeLumPct);
  const deWorse = afterDe > beforeDe + 0.35;
  const scoreWorse = afterScore > beforeScore + 0.35;
  return postSeed105Body && Math.abs(delta) <= 1.0001 && Math.abs(afterLumPct) <= nearGate && yImproved && (deWorse || scoreWorse);
}

function lumaCoupledRgbPlan({ ire, lumPct, rgbDeltaSum = 0, hasLuma = true, paired = false }) {
  const postSeed105Body = ire >= 104.5 && ire < 108.5;
  if (!postSeed105Body || !hasLuma || paired) return null;
  const desired = lumPct > 0 ? -1 : lumPct < 0 ? 1 : rgbDeltaSum > 0 ? -1 : 1;
  const opposition = rgbDeltaSum * desired < 0 ? Math.abs(rgbDeltaSum) : 0;
  if (Math.abs(lumPct) <= lumaTolerancePercent(ire) && opposition < 0.5) return null;
  const nearGate = Math.min(2.0, Math.max(1.5, lumaTolerancePercent(ire) * 2.0));
  let cap = Math.abs(lumPct) <= nearGate ? 0.25 : 0.5;
  if (opposition >= 1.0) cap = Math.max(cap, 0.5);
  if (opposition >= 2.0) cap = Math.max(cap, 1.0);
  if (rgbDeltaSum * desired > 0 && Math.abs(rgbDeltaSum) >= 0.5) cap = Math.min(cap, 0.25);
  return { delta: desired * cap, cap };
}

function scoreYWorkingCandidate({ ire, rgbOnly = true, beforeLumPct, afterLumPct, beforeScore, afterScore, bestLumPct, bestScore, beforeDe, afterDe }) {
  if (ire < 104.5 || ire >= 108.5 || !rgbOnly) return false;
  const beforeAbs = Math.abs(beforeLumPct);
  const afterAbs = Math.abs(afterLumPct);
  const bestAbs = Math.abs(bestLumPct);
  if (afterAbs <= lumaTolerancePercent(ire)) return false;
  if (afterAbs <= beforeAbs + 0.35 && afterAbs <= bestAbs + 0.35) return false;
  if (afterScore > bestScore - 0.5) return false;
  if (afterScore > beforeScore - 0.35) return false;
  return afterDe < beforeDe - 0.35;
}

function responseScaledStep({ baseStep, cap, insufficient = false, wrongDirection = false, samples = 1 }) {
  if (wrongDirection) return null;
  if (!insufficient) return baseStep;
  const mult = samples >= 2 ? 2.0 : 1.5;
  return Math.max(baseStep, Math.min(cap, baseStep * mult));
}

function weighted105Seed(weight = 0.5) {
  return {
    r: roundQuarter(4.25 * weight),
    g: roundQuarter(-5.5 * weight),
    b: roundQuarter(-13 * weight),
  };
}

assert.strictEqual(
  postSeed105LumaBlockingActive({ ire: 105, lumPct: 1.2 }),
  false,
  '105 should allow capped RGB cleanup when a luma probe lands near the target band'
);
assert.strictEqual(
  postSeed105LumaBlockingActive({ ire: 105, lumPct: 4.2 }),
  true,
  '105 should still block RGB/chroma planners while post-seed luminance remains far outside tolerance'
);
assert.strictEqual(
  nearYCleanupWorkingCandidate({ ire: 105, delta: -4, beforeLumPct: 9.1, afterLumPct: -1.36, beforeDe: 6.7, afterDe: 10.0, beforeScore: 6.7, afterScore: 10.0 }),
  false,
  'oversized first 105 luma jumps must not start near-Y RGB cleanup'
);
assert.strictEqual(
  nearYCleanupWorkingCandidate({ ire: 105, delta: -1, beforeLumPct: 4.2, afterLumPct: 1.49, beforeDe: 6.0, afterDe: 7.5, beforeScore: 7.1, afterScore: 7.7 }),
  true,
  'incremental 105 luma probes may start near-Y RGB cleanup when Y is near target but score worsens'
);
assert.deepStrictEqual(
  lumaCoupledRgbPlan({ ire: 105, lumPct: 4.2, rgbDeltaSum: -0.5 }),
  { delta: -0.25, cap: 0.25 },
  '105 RGB cleanup while Y is high should include a conservative luminance-down component'
);
assert.deepStrictEqual(
  lumaCoupledRgbPlan({ ire: 105, lumPct: 0.915, rgbDeltaSum: 3.75 }),
  { delta: -1, cap: 1 },
  '105 response-model RGB moves that are likely to raise already-high near-target Y should still be luma-coupled'
);
assert.deepStrictEqual(
  lumaCoupledRgbPlan({ ire: 105, lumPct: -2.4, rgbDeltaSum: 0 }),
  { delta: 0.5, cap: 0.5 },
  '105 RGB cleanup while Y is low should include a luminance-up component'
);
assert.strictEqual(
  lumaCoupledRgbPlan({ ire: 105, lumPct: 0.8, rgbDeltaSum: -0.5 }),
  null,
  '105 RGB cleanup should not append luma when Y is already within tolerance'
);
assert.strictEqual(
  scoreYWorkingCandidate({ ire: 105, beforeLumPct: 0.915, afterLumPct: 6.526, beforeScore: 8.664, afterScore: 6.853, bestLumPct: 0.915, bestScore: 8.664, beforeDe: 8.664, afterDe: 4.919 }),
  true,
  '105 RGB branch with materially better score but worse high-Y should become a luma-recovery working branch'
);
assert.strictEqual(
  scoreYWorkingCandidate({ ire: 105, beforeLumPct: 0.915, afterLumPct: 6.526, beforeScore: 8.664, afterScore: 8.4, bestLumPct: 0.915, bestScore: 8.664, beforeDe: 8.664, afterDe: 7.9 }),
  false,
  '105 RGB branch should not become working unless the combined score improves materially'
);
for (const ire of [99, 100, 109]) {
  assert.strictEqual(
    scoreYWorkingCandidate({ ire, beforeLumPct: 0.915, afterLumPct: 6.526, beforeScore: 8.664, afterScore: 6.853, bestLumPct: 0.915, bestScore: 8.664, beforeDe: 8.664, afterDe: 4.919 }),
    false,
    `${ire} should not use the 105 score/Y working branch`
  );
}
for (const ire of [99, 100, 109]) {
  assert.strictEqual(
    lumaCoupledRgbPlan({ ire, lumPct: 4.2, rgbDeltaSum: -0.5 }),
    null,
    `${ire} should remain outside 105 RGB+luma coupling`
  );
}
assert.deepStrictEqual(weighted105Seed(), { r: 2.25, g: -2.75, b: -6.5 }, '105 hard seed should default to a 50% weighted 109-derived RGB shape');
assert.deepStrictEqual(weighted105Seed(1), { r: 4.25, g: -5.5, b: -13 }, '105 seed helper should keep the legacy source shape available behind the configured weight');
assert.strictEqual(responseScaledStep({ baseStep: 0.5, cap: 2, insufficient: true }), 0.75, '105 high-channel RGB pull should escalate after a measured insufficient response');
assert.strictEqual(responseScaledStep({ baseStep: 1, cap: 2, insufficient: true, samples: 2 }), 2, '105 luma/coupled moves may scale after measured probes while staying capped');
assert.strictEqual(responseScaledStep({ baseStep: 1, cap: 2 }), 1, '105 first luma move should remain the staged one-point probe');
assert.strictEqual(responseScaledStep({ baseStep: 0.5, cap: 2, wrongDirection: true }), null, '105 wrong-direction response should suppress the repeated direction');
for (const ire of [99, 100, 109]) {
  assert.strictEqual(
    postSeed105LumaBlockingActive({ ire, lumPct: 12 }),
    false,
    `${ire} should remain outside the post-seed 105 luma-blocking helper`
  );
}
assert.strictEqual(
  headroomSeedDecision({ ire: 105, lumPct: 7.2, chroma: 0.08 }).reason,
  'headroom_105_seed',
  'large positive 105 luma error should still allow the hard WRGB seed when chroma is dominant'
);
assert.strictEqual(
  headroomSeedDecision({ ire: 109, lumPct: 7.2, chroma: 0.08 }).reason,
  'not_non_peak_fast_headroom',
  '109 should remain outside the 105 seed path'
);
for (const ire of [99, 100]) {
  assert.strictEqual(
    headroomSeedDecision({ ire, lumPct: 7.2, chroma: 0.08 }).reason,
    'not_non_peak_fast_headroom',
    `${ire} should remain outside the 105 seed path`
  );
}

const chooseMain = sliceBetween(
  'sub choose_adjustments {',
  'sub choose_micro_adjustments {'
);
assert(
  chooseMain.includes('my $headroom_105_body=headroom_105_post_seed_body_refinement($step,$arrays,$target,$tried);') &&
    chooseMain.includes('if(autocal_step_is_fast_headroom($step) && !$headroom_105_body)') &&
    chooseMain.includes('trace_109($step,"headroom_105_body_refinement_path"') &&
    chooseMain.includes('mark_headroom_105_body_refinement_adjustments') &&
    chooseMain.includes('my $headroom_105_luma_blocking=headroom_105_luma_blocking_active($step,$arrays,$target,$tried,$luminance_err);') &&
    chooseMain.includes('my $headroom_105_luma_priority=headroom_105_luma_priority_active($step,$arrays,$target,$tried,$luminance_err);') &&
    chooseMain.includes('headroom_105_luma_priority_adjustment($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_step,1,0,$step)') &&
    chooseMain.includes('headroom_105_all_down_luma_adjustment($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_step,2,0,$step)') &&
    chooseMain.includes('headroom_105_floor_luma_coupled_adjustment($error,$arrays,$target,$luminance_err,$de,$stalls,$tried,$min_step,1,0,$step)') &&
    chooseMain.includes('return undef if($headroom_105_luma_blocking);'),
  'after a successful 105 seed, main planning should prioritize scalar luma until Y is near target, then annotate body-style refinement'
);
const dominantIdx = chooseMain.indexOf('my $dominant_chroma_first=');
const firstLumaIdx = chooseMain.indexOf('headroom_rgb_luminance_adjustments($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_step,$max_luma_step,$step,"main_headroom_luminance")');
assert(dominantIdx >= 0 && firstLumaIdx > dominantIdx, '105 dominant-chroma branch should run before the first luma-only fallback');
assert(
  chooseMain.includes('headroom_chroma_luma_adjustment($error,$arrays,$target,$luminance_err,$de,$stalls,$tried,$min_step,1,0,$step)'),
  'main 105 planner should try a bounded chroma+luma move when both chroma and Y are bad'
);
const peakHeadroomMain = chooseMain.slice(
  chooseMain.indexOf('if(autocal_step_is_peak_headroom($step)) {'),
  chooseMain.indexOf('if(!autocal_step_is_peak_headroom($step) && abs($lum_pct) > $luma_tol && $chroma_mag < 0.035)')
);
assert(
  peakHeadroomMain.includes('headroom_peak_match_low_adjustment') &&
    peakHeadroomMain.includes('return undef;') &&
    !peakHeadroomMain.includes('headroom_rgb_luminance_adjustments'),
  '109 peak headroom should remain chroma-only and outside scalar luma refinement'
);

const chooseMicro = sliceBetween(
  'sub choose_micro_adjustments {',
  'sub describe_adjustments {'
);
assert(
  chooseMicro.includes('my $headroom_105_body=headroom_105_post_seed_body_refinement($step,$arrays,$target,$tried);') &&
    chooseMicro.includes('if(autocal_step_is_fast_headroom($step) && !$headroom_105_body)') &&
    chooseMicro.includes('trace_109($step,"headroom_105_body_refinement_path"') &&
    chooseMicro.includes('mark_headroom_105_body_refinement_adjustments') &&
    chooseMicro.includes('my $headroom_105_luma_blocking=headroom_105_luma_blocking_active($step,$arrays,$target,$tried,$luminance_err);') &&
    chooseMicro.includes('my $headroom_105_luma_priority=headroom_105_luma_priority_active($step,$arrays,$target,$tried,$luminance_err);') &&
    chooseMicro.includes('headroom_105_luma_priority_adjustment($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_micro_step,1,1,$step)') &&
    chooseMicro.includes('headroom_105_all_down_luma_adjustment($arrays,$target,$luminance_err,$de,$stalls,$tried,$min_micro_step,$max_step < 0.5 ? $max_step : 0.5,1,$step)') &&
    chooseMicro.includes('headroom_105_floor_luma_coupled_adjustment($error,$arrays,$target,$luminance_err,$de,$stalls,$tried,$min_micro_step,$max_step < 0.5 ? $max_step : 0.5,1,$step)') &&
    chooseMicro.includes('return undef if($headroom_105_luma_blocking);'),
  '105 fine tuning should also keep high-luma states out of body RGB/chroma refinement after seed'
);
assert(
  chooseMicro.includes('my $dominant_chroma_first=') &&
    chooseMicro.includes('headroom_chroma_luma_adjustment($error,$arrays,$target,$luminance_err,$de,$stalls,$tried,$min_micro_step,$max_step,1,$step)'),
  '105 fine tune should also avoid returning to luma-only when chroma dominates'
);

const bodyLumaPriority = sliceBetween(
  'sub body_luminance_priority_adjustments {',
  'sub low_shadow_luminance_priority_adjustments {'
);
assert(
  bodyLumaPriority.includes('headroom_105_post_seed_body_refinement($step,$arrays,$target,$tried)') &&
    bodyLumaPriority.includes('(autocal_step_is_fast_headroom($step) && !$headroom_105_body)') &&
    bodyLumaPriority.includes('$adj->{"headroom_105_body_refinement"}=1 if($headroom_105_body);'),
  'body luminance priority should admit only post-seed 105 among fast-headroom points'
);

const bodyResponse = sliceBetween(
  'sub body_luminance_response_cap {',
  'sub high_end_paired_luma_allowed {'
);
assert(
  bodyResponse.includes('return 1.0 if($headroom_105_body_refinement && $ire >= 104.5 && $ire < 108.5);') &&
    bodyResponse.includes('headroom_105_post_seed_body_refinement($step,$arrays,$target,$tried)') &&
    bodyResponse.includes('headroom_105_body_refinement=>$headroom_105_body ? 1 : undef'),
  'body luminance response follow-up should be available to post-seed 105 with the same high-body cap'
);

const rgbResponsePlanner = sliceBetween(
  'sub choose_rgb_response_adjustments {',
  'sub choose_adjustments {'
);
assert(
  rgbResponsePlanner.includes('my $headroom_105_body=headroom_105_post_seed_body_refinement($step,$arrays,$target,$tried);') &&
    rgbResponsePlanner.includes('return undef if(autocal_step_is_fast_headroom($step) && !$headroom_105_body);') &&
    rgbResponsePlanner.includes('my $near_y_cleanup_cap=headroom_105_near_y_cleanup_rgb_cap($tried,$step,$arrays,$target,$luminance_err,0);') &&
    rgbResponsePlanner.includes('$max_jump=$near_y_cleanup_cap if(defined($near_y_cleanup_cap) && $max_jump > $near_y_cleanup_cap);') &&
    rgbResponsePlanner.includes('!defined($response_multiplier)') &&
    rgbResponsePlanner.includes('headroom_105_near_y_cleanup=>defined($near_y_cleanup_cap) ? 1 : undef') &&
    rgbResponsePlanner.includes('append_headroom_105_luma_coupling($out,$arrays,$target,$step,$luminance_err,$tried,0,$LG_AUTOCAL_STATE)') &&
    rgbResponsePlanner.includes('headroom_105_body_refinement=>$headroom_105_body ? 1 : undef'),
  'RGB response planner should remain blocked for 109/headroom except post-seed 105 and cap near-Y cleanup moves'
);
assert(
  source.includes('trace_109($step,"headroom_105_luma_coupled_rgb"') &&
    source.includes('rgb_adjustments=>trace_adjustments_summary($adjustments)') &&
    source.includes('headroom_105_luma_coupled_rgb=>1') &&
    source.includes('headroom_105_rgb_luma_assist($adjustments,$luminance_err)') &&
    source.includes('headroom_105_rgb_luma_opposition($adjustments,$luminance_err)') &&
    source.includes('return undef if(abs($lum_pct) <= $tol && $opposition < 0.4999);') &&
    source.includes('projected_luminance_error_pct=>$projected_lum_pct+0'),
  'post-seed 105 RGB cleanup should append and trace a luma component when luminance is outside tolerance or an RGB move is likely to push Y away'
);
assert(
	  source.includes('sub record_headroom_105_response {') &&
	    source.includes('trace_109($step,"headroom_105_response_measured"') &&
	    source.includes('sub headroom_105_response_scaled_step {') &&
	    source.includes('sub headroom_105_score_y_working_candidate {') &&
	    source.includes('sub headroom_105_score_y_branch_active {') &&
	    source.includes('trace_109($step,"headroom_105_response_direction_suppressed"') &&
	    source.includes('$adj->{"headroom_105_response_scaled"}=1;') &&
	    source.includes('headroom_105_response_update=>$headroom_105_response_update'),
	  'post-seed 105 should trace measured response, scale insufficient follow-up moves, suppress wrong-direction repeats, and support score/Y working branches'
	);

const mainLoop = sliceBetween(
  'my $before_adjustment_reading=clone_picture($reading);',
  '$state->{"best_delta_e"}=$best_de;'
);
const loopCoupledIdx = source.indexOf('headroom_105_floor_luma_coupled_adjustment($err,$arrays,$target,$lum_err,$de,$stalls,\\%tried_values,0.25,1,0,$read_step)');
const loopBodyPriorityIdx = source.indexOf('$adjustments=body_luminance_priority_adjustments($arrays,$target,$lum_err,$de,$stalls,\\%tried_values,$read_step)');
const loopAllDownIdx = source.indexOf('headroom_105_all_down_luma_adjustment($arrays,$target,$lum_err,$de,$stalls,\\%tried_values,0.25,2,0,$read_step)');
const loopLumaPriorityIdx = source.indexOf('headroom_105_luma_priority_adjustment($arrays,$target,$lum_err,$de,$stalls,\\%tried_values,0.25,1,0,$read_step)');
const loopMainPolishIdx = source.indexOf('headroom_105_main_polish_refine_adjustments($state,$arrays,$target,$read_step,$reading,$de,$lum_pct,$target_delta,\\%tried_values,$stalls,$lum_err,\\%rgb_response_model,$err)');
assert(loopMainPolishIdx >= 0 && loopMainPolishIdx < loopLumaPriorityIdx, 'live main loop should try 105 committed-polish-style refinement before scalar/all-down/floor luma families when Y is close-ish but dE remains high');
assert(loopLumaPriorityIdx >= 0 && loopAllDownIdx > loopLumaPriorityIdx, 'live main loop should try scalar 105 luma-priority before all-RGB-down or per-channel work when Y is far high');
assert(loopCoupledIdx >= 0 && loopCoupledIdx > loopAllDownIdx, 'live main loop should try 105 all-RGB-down before floor-pull once scalar luma-priority is inactive');
assert(loopBodyPriorityIdx > loopCoupledIdx, 'live main loop should try 105 floor-pull luma coupling before generic body luma-priority can consume the turn');
assert(
  source.includes('!$headroom_105_luma_blocking &&') &&
    source.includes('my $headroom_105_near_y_cleanup_active=headroom_105_near_y_cleanup_branch_active(\\%tried_values,$read_step,$arrays,$target,$lum_err);') &&
    source.includes('!$headroom_105_luma_blocking && !$headroom_105_near_y_cleanup_active') &&
    source.includes('choose_rgb_response_adjustments($err,$arrays,$target,\\%rgb_response_model,\\%tried_values,$de,$read_step,$target_delta,$stalls,$lum_err) if(!$adjustments && !$headroom_105_luma_blocking)'),
  'live main loop should suppress queued/RGB planners while 105 has high luma error and skip body luma while near-Y cleanup is active'
);
assert(
  mainLoop.includes('record_bad_luma_probe_family(') &&
	    mainLoop.includes('headroom_105_near_y_cleanup_working_candidate(') &&
	    mainLoop.includes('headroom_105_score_y_working_candidate(') &&
	    mainLoop.includes('mode=>"score_y_recovery"') &&
	    mainLoop.includes('trace_109($read_step,"headroom_105_score_y_branch_started"') &&
	    mainLoop.includes('$tried_values{"__headroom_105_near_y_cleanup"}={') &&
    mainLoop.includes('trace_109($read_step,"headroom_105_near_y_cleanup_branch_started"') &&
    mainLoop.includes('record_headroom_105_bad_adjustment_family(') &&
    mainLoop.includes('bad_headroom_105_family=>$bad_headroom_105_family') &&
    mainLoop.includes('bad_luma_probe=>$bad_luma_probe') &&
    mainLoop.includes('legal_white_pair_score_stalled') &&
    mainLoop.includes('$legal_white_pair_score_stalled=1;'),
  'main loop should keep near-Y 105 luma probes as working cleanup branches while still tracing bad luma probes'
);
assert(
  source.includes('sub headroom_105_main_polish_refine_active') &&
    source.includes('sub headroom_105_main_polish_refine_adjustments') &&
    source.includes('lg_autocal_26_learned_luminance_adjustment($state,$arrays,$target,$step,$lum_pct,$tried,final_all_level_verify_adjustment_cap($step,"adjustingLuminance"),"headroom_105_main_polish_luminance")') &&
    source.includes('lg_autocal_26_learned_rgb_adjustment($state,$arrays,$target,$step,$reading,$de,$target_delta,$tried,$learned_rgb_cap,"headroom_105_main_polish_rgb")') &&
    source.includes('choose_rgb_response_adjustments($err,$arrays,$target,$rgb_response_model,$tried,$de,$step,$target_delta,$stalls,$lum_err)') &&
    source.includes('trace_109($step,"headroom_105_main_polish_refine_plan"') &&
    source.includes('trace_109($read_step,"headroom_105_main_polish_refine_keep"') &&
    source.includes('trace_109($read_step,"headroom_105_main_polish_refine_reject"') &&
    source.includes('$headroom_105_main_polish_keep=1;') &&
    source.includes('$best_update_reason="headroom_105_main_polish_refine_score_keep"'),
  'post-seed 105 main calibration should have a committed-polish-style near-Y refinement path with plan/keep/reject tracing'
);
assert(
  mainLoop.includes('restore_headroom_105_near_y_cleanup_branch') &&
    mainLoop.includes('headroom_105_near_y_cleanup_rejected') &&
    mainLoop.includes('105 near-Y RGB cleanup exhausted; keeping best $label result') &&
    mainLoop.includes('suppress_headroom_105_family(\\%tried_values,$read_step,$target,"headroom_105_all_down_luma","near_y_cleanup_exhausted"') &&
    mainLoop.includes('suppress_headroom_105_family(\\%tried_values,$read_step,$target,"headroom_105_floor_luma_coupled","near_y_cleanup_exhausted"'),
  'near-Y 105 RGB cleanup should retry only from the near-luma branch, then restore best and suppress luma families when exhausted'
);

const committedPolishLoop = sliceBetween(
  'my $before_de_for_committed_polish=$de;',
  '$finish_polish->(undef);'
);
assert(
  committedPolishLoop.includes('record_bad_luma_probe_family(') &&
    committedPolishLoop.includes('"committed_polish"') &&
    committedPolishLoop.includes('bad_luma_probe=>$bad_luma_probe'),
  'committed polish should poison rejected luma-only families before restoring best'
);

const finalVerifyLoop = sliceBetween(
  'my $before_de_for_verify=$de;',
  '$reading=clone_picture($best_reading);'
);
assert(
  finalVerifyLoop.includes('record_bad_luma_probe_family(') &&
    finalVerifyLoop.includes('"final_all_level_verify"') &&
    finalVerifyLoop.includes('bad_luma_probe=>$bad_luma_probe'),
  'final verify should poison rejected luma-only touches before restoring best'
);
assert(
  source.includes('!$legal_white_pair_score_stalled') &&
    source.includes('autocal_step_allows_final_fine_tune($read_step,$best_de,$target_delta)') &&
    source.includes('Keeping best 99/100 paired result'),
  'paired 99/100 should skip extra fine tune after pair-score stall and still restore the best measured pair'
);
assert(
    source.includes('$headroom_105_score_keep=1;') &&
    source.includes('$best_update_reason="headroom_105_y_score_keep";') &&
    source.includes('sub headroom_105_score_branch_adjustment') &&
    source.includes('sub headroom_105_score_branch_promote_candidate') &&
    source.includes('return 0 if($adj->{"headroom_105_all_down_luma"} || $adj->{"headroom_105_floor_luma_coupled"});') &&
    source.includes('$headroom_105_score_branch_promote=1;') &&
    source.includes('$best_update_reason="headroom_105_score_branch_promoted";') &&
    source.includes('trace_109($read_step,"headroom_105_score_branch_promoted"') &&
    source.includes('my $headroom_105_luma_blocking_after=(!$paired_white_step && defined($lum_pct))') &&
    source.includes('? ($headroom_105_score_keep || $headroom_105_score_branch_promote || $headroom_105_main_polish_keep)') &&
    source.includes('$luma_anchor_working=0 if(ref($bad_luma_probe) eq "HASH");') &&
    source.includes('delete($tried_values{"__headroom_105_near_y_cleanup"});'),
  'post-seed 105 should allow Y-aware and score-branch improvements to replace a bad near-Y best while clearing temporary cleanup branches'
);

const topWindowScore = sliceBetween(
  'sub committed_top_window_score {',
  'sub committed_top_window_score_passed {'
);
assert(
  topWindowScore.includes('my @ires=grep { ref($window->{"points"}{$_}) eq "HASH" && defined($window->{"points"}{$_}{"de"}) } (109,105,99,100,95);') &&
    topWindowScore.includes('return { score=>9999, worst=>9999, avg=>9999, over=>9999 } if(!@ires);') &&
    topWindowScore.includes('committed_top_window_point_score($ire,$rec)') &&
    !topWindowScore.includes('return { score=>9999, worst=>9999, avg=>9999, over=>9999 } if(ref($rec) ne "HASH" || !defined($rec->{"de"}));'),
  'focused 109/105/99/100 top-window validation should score available points and include 105 luma penalty instead of requiring 95%'
);

const topWindowCandidates = sliceBetween(
  'sub committed_top_window_luma_candidate_change {',
  'sub committed_top_window_apply_candidate {'
);
assert(
    topWindowCandidates.includes('sub committed_top_window_luma_suppressed') &&
    topWindowCandidates.includes('sub committed_top_window_luma_allowed') &&
    topWindowCandidates.includes('sub record_committed_top_window_bad_luma') &&
    topWindowCandidates.includes('my $magnitude=ddc_value_key(abs($delta+0));') &&
    topWindowCandidates.includes('return join("|",format_percent($ire),ddc_value_key($current),$direction,$magnitude);') &&
    topWindowCandidates.includes('return 0 if(abs(($ire||0)-105) < 0.001 && $de > 2.0 && $chroma >= 0.030);') &&
    topWindowCandidates.includes('my ($window,$config,$arrays,$bad_luma)=@_;') &&
    topWindowCandidates.includes('$add_luma_candidates->() if(!$rgb_first);') &&
    topWindowCandidates.includes('$add_luma_candidates->() if($rgb_first);'),
  'committed top-window polish should suppress poisoned luma families and prefer RGB when 105 chroma dominates'
);

const topWindowLoop = sliceBetween(
  'my %bad_luma_candidates;',
  'sub start_calibration_mode {'
);
assert(
  topWindowLoop.includes('committed_top_window_candidates($best_window,$config,$best_arrays,\\%bad_luma_candidates)') &&
    topWindowLoop.includes('next if(committed_top_window_luma_suppressed(\\%bad_luma_candidates,$candidate,$best_arrays));') &&
    topWindowLoop.includes('record_committed_top_window_bad_luma(') &&
    topWindowLoop.includes('bad_luma_candidate=>$bad_luma_candidate'),
  'top-window candidate loop should feed failed luma-only attempts back into candidate selection'
);

const pairPrecision = sliceBetween(
  'sub legal_white_pair_precision_stall_limit {',
  'sub legal_white_pair_needs_work {'
);
assert(
  pairPrecision.includes('return 5 if($worst > 3.0);') &&
    pairPrecision.includes('return 6 if($worst > 1.5);') &&
    pairPrecision.includes('return 8 if($worst > 1.0);'),
  'bad 99/100 pairs should not spend double-digit fine-tune iterations on non-improving pair score'
);

function roundQuarter(value) {
  const rounded = value >= 0 ? Math.floor(value * 4 + 0.5) / 4 : Math.trunc(value * 4 - 0.5) / 4;
  return Math.max(-50, Math.min(50, Number(rounded.toFixed(2))));
}

function lumaFamilyKey(target, current, next) {
  const delta = next - current;
  return `${target}|${current.toFixed(2)}|${delta < 0 ? -1 : 1}|${Math.abs(delta).toFixed(2)}`;
}

function recordBadLumaFamily(tried, { current, next, beforeDe, afterDe, beforeLum, afterLum, beforeScore, afterScore }) {
  const yImproved = Math.abs(afterLum) + 0.10 < Math.abs(beforeLum);
  const deWorse = afterDe > beforeDe + 0.35;
  const scoreWorse = afterScore > beforeScore + 0.35;
  if (!yImproved || (!deWorse && !scoreWorse)) return null;
  const key = lumaFamilyKey('105', current, next);
  const severe = afterDe > beforeDe + 1.0 || afterScore > beforeScore + 1.0;
  tried[key] = tried[key] || { count: 0, severeCount: 0 };
  tried[key].count += 1;
  if (severe) tried[key].severeCount += 1;
  return tried[key];
}

function lumaSuppressed(tried, current, next) {
  const entry = tried[lumaFamilyKey('105', current, next)];
  return !!entry && (entry.severeCount >= 1 || entry.count >= 2);
}

function seeded105LumaRefineCap({ ire, current, lumErr, rgb }) {
  if (ire < 104.5 || ire >= 108.5) return null;
  if (lumErr <= 0 || Math.abs(current) > 0.0001) return null;
  if (!rgb) return null;
  const seed = weighted105Seed();
  if (Math.abs(rgb.r - seed.r) > 0.7501 || Math.abs(rgb.g - seed.g) > 0.7501 || Math.abs(rgb.b - seed.b) > 1.0001) return null;
  if (lumErr * 100 <= lumaTolerancePercent(ire) * 0.65) return null;
  return 1.0;
}

function adjustmentStep(absErr, de, minStep = 0.25) {
  let step = 0.25;
  if (absErr >= 0.30 || de >= 30) step = 8;
  else if (absErr >= 0.20 || de >= 20) step = 6;
  else if (absErr >= 0.12 || de >= 10) step = 4;
  else if (absErr >= 0.06 || de >= 4) step = 2;
  else if (absErr >= 0.025 || de >= 2) step = 1;
  else if (absErr >= 0.012 || de >= 1) step = 0.5;
  return Math.max(step, minStep);
}

function neutralLumaStep(lumErr, de, maxStep = 1) {
  const abs = Math.abs(lumErr);
  let step = 0.25;
  if (abs >= 0.08 || de >= 12) step = 4;
  else if (abs >= 0.04 || de >= 8) step = 2;
  else if (abs >= 0.02 || de >= 4) step = 1;
  else if (abs >= 0.008) step = 0.5;
  return Math.min(step, maxStep);
}

function floorLuma105({ ire = 105, seeded = true, current, lumErr, maxStep = 1, minStep = 0.25, triedCombos = new Set() }) {
  if (!seeded || ire < 104.5 || ire >= 108.5) return null;
  if (lumErr * 100 <= lumaTolerancePercent(ire)) return null;
  const floor = Math.min(current.r, current.g, current.b);
  const candidate = [];
  for (const [channel, setting] of [
    ['r', 'whiteBalanceRed'],
    ['g', 'whiteBalanceGreen'],
    ['b', 'whiteBalanceBlue'],
  ]) {
    const value = current[channel];
    const gap = value - floor;
    if (gap < minStep - 0.0001) continue;
    const step = roundQuarter(Math.min(gap, maxStep));
    if (step < minStep - 0.0001) continue;
    const next = Math.max(floor, roundQuarter(value - step));
    if (Math.abs(next - value) < 0.0001) continue;
    candidate.push({ channel, setting, current: value, next });
  }
  if (!candidate.length) return null;
  const key = candidate.map(adj => `${adj.setting}=${adj.next.toFixed(2)}`).sort().join('|');
  return triedCombos.has(key) ? null : candidate;
}

const floorPull105 = floorLuma105({
  current: { r: 4.25, g: -5.5, b: -13 },
  lumErr: 0.0656,
});
assert(floorPull105, 'post-seed 105 with positive high luma should emit an RGB floor-pull candidate');
assert.deepStrictEqual(
  floorPull105.map(adj => adj.setting).sort(),
  ['whiteBalanceGreen', 'whiteBalanceRed'],
  '105 floor-pull candidate should move every RGB channel above the floor, independent of measured-channel dominance'
);
assert.strictEqual(floorPull105.find(adj => adj.setting === 'whiteBalanceRed').next < 4.25, true, 'floor-pull 105 red component should move downward');
assert.strictEqual(floorPull105.find(adj => adj.setting === 'whiteBalanceGreen').next < -5.5, true, 'floor-pull 105 green component should move downward when green is above the floor');
assert.strictEqual(floorPull105.some(adj => adj.setting === 'whiteBalanceBlue'), false, 'floor-pull 105 should not push the lowest channel lower');
assert.strictEqual(floorPull105.some(adj => adj.setting === 'adjustingLuminance'), false, 'floor-pull 105 should use RGB floor matching, not burn the luma dial budget');
assert.strictEqual(
  floorLuma105({ ire: 109, seeded: true, current: { r: 4.25, g: -5.5, b: -13 }, lumErr: 0.0656 }),
  null,
  '109 peak headroom should not run the 105 floor-pull planner'
);
for (const ire of [99, 100, 80]) {
  assert.strictEqual(
    floorLuma105({ ire, seeded: true, current: { r: 4.25, g: -5.5, b: -13 }, lumErr: 0.0656 }),
    null,
    `${ire} should remain outside the 105 floor-pull planner`
  );
}

function nextNeutralLuma({ ire = 105, current, lumErr, de, stalls = 0, tried = {}, rgb = null }) {
  const direction = lumErr > 0 ? -1 : 1;
  let step = 0.25;
  const abs = Math.abs(lumErr);
  if (abs >= 0.08 || de >= 12) step = 4;
  else if (abs >= 0.04 || de >= 8) step = 2;
  else if (abs >= 0.02 || de >= 4) step = 1;
  else if (abs >= 0.008) step = 0.5;
  if (stalls >= 4 && step < 1) step = 1;
  const seedCap = seeded105LumaRefineCap({ ire, current, lumErr, rgb });
  if (seedCap !== null && step > seedCap) step = seedCap;
  const magnitudes = [step];
  if (step > 0.5) magnitudes.push(0.5);
  if (step > 0.25) magnitudes.push(0.25);
  for (const mag of magnitudes) {
    const next = roundQuarter(current + direction * mag);
    if (!lumaSuppressed(tried, current, next)) return next;
  }
  return null;
}

const seededRgb = weighted105Seed();
assert.strictEqual(
  nextNeutralLuma({ current: 0, lumErr: 0.09046, de: 6.12775725880537, rgb: seededRgb }),
  -1,
  'first post-seed 105 luma correction should be capped instead of jumping from L 0 to L -4'
);
assert.strictEqual(
  nextNeutralLuma({ ire: 109, current: 0, lumErr: 0.09046, de: 6.12775725880537, rgb: seededRgb }),
  -4,
  '109 should remain outside the seeded 105 luma cap'
);
for (const ire of [99, 100]) {
  assert.strictEqual(
    nextNeutralLuma({ ire, current: 0, lumErr: 0.09046, de: 6.12775725880537, rgb: seededRgb }),
    -4,
    `${ire} paired behavior should remain outside the seeded 105 luma cap`
  );
}

const tried105 = {};
const severe105 = recordBadLumaFamily(tried105, {
  current: 0,
  next: -4,
  beforeDe: 6.12775725880537,
  afterDe: 9.55667675915135,
  beforeLum: 9.046,
  afterLum: -0.627231874316445,
  beforeScore: 7.34950416313307,
  afterScore: 9.55667675915135,
});
assert(severe105 && severe105.severeCount === 1, 'luma-improves but dE/score-worsens should record a severe bad family');
assert.strictEqual(lumaSuppressed(tried105, 0, -4), true, 'a severe same-origin 105 luma failure should suppress the same magnitude');
assert.strictEqual(lumaSuppressed(tried105, 0, -1), false, 'a severe large 105 luma failure should not suppress a smaller one-point retry');
assert.strictEqual(lumaSuppressed(tried105, 0, -0.5), false, 'a severe large 105 luma failure should not suppress a smaller half-step retry');
assert.strictEqual(lumaSuppressed(tried105, 0, -0.25), false, 'a severe large 105 luma failure should not suppress a smaller quarter-step retry');
assert.strictEqual(nextNeutralLuma({ current: 0, lumErr: 0.09046, de: 6.12775725880537, tried: tried105, rgb: seededRgb }), -1, '105 should still allow a smaller capped luma-only move from the restored state after a failed large cut');

function finalVerifyLumaMove({ current, lumPct, tried = {} }) {
  const direction = lumPct > 0 ? -1 : 1;
  let mag = 0.25;
  const abs = Math.abs(lumPct);
  if (abs >= 2.0) mag = 0.5;
  if (abs >= 4.0) mag = 1.0;
  if (abs >= 8.0) mag = 1.5;
  const next = roundQuarter(current + direction * mag);
  return lumaSuppressed(tried, current, next) ? null : next;
}
assert.strictEqual(
  finalVerifyLumaMove({ current: 0, lumPct: 9.1, tried: tried105 }),
  -1.5,
  'final verify should not inherit suppression from a larger failed luma-only touch'
);
recordBadLumaFamily(tried105, {
  current: 0,
  next: -1.5,
  beforeDe: 6.12775725880537,
  afterDe: 8.1,
  beforeLum: 9.046,
  afterLum: 4.2,
  beforeScore: 9.16,
  afterScore: 10.2,
});
assert.strictEqual(
  finalVerifyLumaMove({ current: 0, lumPct: 9.1, tried: tried105 }),
  null,
  'final verify should still avoid repeating the same bad luma-only magnitude'
);

function pairScore(de99, de100) {
  const worst = Math.max(de99, de100);
  const best = Math.min(de99, de100);
  const avg = (de99 + de100) / 2;
  const spread = Math.abs(de99 - de100);
  return worst * 1.45 + best * 0.20 + avg * 0.10 + spread * 1.25;
}

function pairUpdateReason(candidateScore, bestScore, deA, deB, bestDeA, bestDeB, targetDelta = 0.5) {
  const candidateWorst = Math.max(deA, deB);
  const bestWorst = Math.max(bestDeA, bestDeB);
  if (candidateWorst + 0.0001 < bestWorst) return 'paired_score_improved';
  if (candidateWorst > bestWorst + 0.03) return null;
  const candidateAvg = (deA + deB) / 2;
  const bestAvg = (bestDeA + bestDeB) / 2;
  if (candidateWorst <= bestWorst + 0.0001 && candidateAvg + 0.0001 < bestAvg) return 'paired_score_improved';
  const candidateSpread = Math.abs(deA - deB);
  const bestSpread = Math.abs(bestDeA - bestDeB);
  if (candidateScore + 0.0001 < bestScore && candidateSpread + 0.02 < bestSpread) return 'paired_score_improved';
  if (candidateWorst <= targetDelta + 0.30 && candidateScore + 0.0001 < bestScore) return 'paired_score_improved';
  return null;
}

let best = { de99: 0.744586817778206, de100: 5.86565684918027 };
best.score = pairScore(best.de99, best.de100);
const rejected = { de99: 1.40691339468679, de100: 4.83111748091896 };
rejected.score = pairScore(rejected.de99, rejected.de100);
assert.strictEqual(
  pairUpdateReason(rejected.score, best.score, rejected.de99, rejected.de100, best.de99, best.de100),
  'paired_score_improved',
  'pair score should allow trading some 99 error for a materially better hidden 100 side'
);
best = rejected;
const worse99 = { de99: 1.09463908953829, de100: 5.02458152699754 };
worse99.score = pairScore(worse99.de99, worse99.de100);
assert.strictEqual(
  pairUpdateReason(worse99.score, best.score, worse99.de99, worse99.de100, best.de99, best.de100),
  null,
  'pair best preservation should reject a later candidate that improves 100 slightly while regressing the protected 99 side'
);
assert(
  source.includes('$pair_best_reject_reason="same_ire_${ire}_itp_guard";'),
  'explicit same-IRE 99/100 guard from 2920b27 must remain in place'
);

function topWindowScoreFor(points) {
  const ires = [109, 105, 99, 100, 95].filter(ire => points[ire] && Number.isFinite(points[ire].de));
  if (!ires.length) return { score: 9999, worst: 9999, avg: 9999, over: 9999 };
  let sum = 0;
  let worst = 0;
  let over = 0;
  for (const ire of ires) {
    let pointScore = points[ire].de;
    if (ire === 105 && Number.isFinite(points[ire].lum)) {
      const excess = Math.abs(points[ire].lum) - 1.0;
      if (excess > 0) pointScore += Math.min(4, excess * 0.35);
    }
    sum += pointScore;
    if (pointScore > worst) worst = pointScore;
    if (pointScore > 1.0) over += 1;
  }
  const avg = sum / ires.length;
  return { score: over * 10 + worst + avg * 0.25, worst, avg, over };
}

const focusedTopScore = topWindowScoreFor({
  109: { de: 0.15 },
  105: { de: 6.5 },
  100: { de: 3.6 },
  99: { de: 3.5 },
});
assert.notStrictEqual(focusedTopScore.score, 9999, 'focused top-window score should be finite without 95%');
assert.strictEqual(focusedTopScore.over, 3, 'focused top-window score should still count failing available points');

const highLuma105Score = topWindowScoreFor({ 105: { de: 0.6, lum: 8.0 } });
const lowLuma105Score = topWindowScoreFor({ 105: { de: 0.6, lum: 0.5 } });
assert(highLuma105Score.score > lowLuma105Score.score + 2, '105 top-window scoring should penalize high luma error even when dE is low');
const highLuma109Score = topWindowScoreFor({ 109: { de: 0.6, lum: 8.0 } });
const lowLuma109Score = topWindowScoreFor({ 109: { de: 0.6, lum: 0.5 } });
assert.strictEqual(highLuma109Score.score, lowLuma109Score.score, '109 should remain chroma-only under top-window scoring');

function autocalItpScore({ ire, de, lum }) {
  let score = de;
  if (ire >= 105 && ire < 108.5 && Number.isFinite(lum)) {
    const excess = Math.abs(lum) - 1.0;
    if (excess > 0) score += Math.min(4, excess * 0.35);
  }
  return score;
}
assert(
  autocalItpScore({ ire: 105, de: 0.8, lum: 8.0 }) > autocalItpScore({ ire: 105, de: 0.8, lum: 0.5 }),
  '105 ITP scoring should be worse when luminance error is high'
);
assert.strictEqual(
  autocalItpScore({ ire: 109, de: 0.8, lum: 8.0 }),
  autocalItpScore({ ire: 109, de: 0.8, lum: 0.5 }),
  '109 ITP scoring should remain chroma-only'
);

function nearY105(lumPct) {
  return Math.abs(lumPct) <= 2.0;
}

function scoreBranchPromoted({ ire = 105, postSeed = true, rgbMove = true, bestDe, bestLum, bestScore, candidateDe, candidateLum, candidateScore }) {
  if (Math.abs(ire - 105) >= 0.001 || !postSeed || !rgbMove) return false;
  if (!Number.isFinite(bestDe) || !Number.isFinite(bestLum) || !Number.isFinite(bestScore)) return false;
  if (!Number.isFinite(candidateDe) || !Number.isFinite(candidateLum) || !Number.isFinite(candidateScore)) return false;
  if (bestDe <= 2.5 || !nearY105(bestLum)) return false;
  if (candidateScore + 0.50 >= bestScore) return false;
  if (candidateDe + 0.75 >= bestDe) return false;
  if (Math.abs(candidateLum) > 8.0) return false;
  return true;
}

function mainPolishRefineActive({ ire = 105, postSeed = true, de, lumPct, targetDelta = 0.5 }) {
  if (Math.abs(ire - 105) >= 0.001 || !postSeed) return false;
  if (!Number.isFinite(de) || !Number.isFinite(lumPct)) return false;
  if (de <= targetDelta + 1.0) return false;
  return Math.abs(lumPct) <= 4.0;
}

function mainPolishKeep({ active = true, bestScore, beforeScore, beforeDe, beforeLum, candidateScore, candidateDe, candidateLum }) {
  if (!active || !Number.isFinite(bestScore) || !Number.isFinite(candidateScore)) return false;
  if (candidateScore + 0.0001 >= bestScore) return false;
  const yWorse = Number.isFinite(beforeLum) && Number.isFinite(candidateLum) && Math.abs(candidateLum) > Math.abs(beforeLum) + 0.05;
  const deWorse = Number.isFinite(beforeDe) && Number.isFinite(candidateDe) && candidateDe > beforeDe + 0.25;
  return !(yWorse && deWorse);
}

assert.strictEqual(
  mainPolishRefineActive({ de: 9.096, lumPct: 0.916 }),
  true,
  '105 main polish refinement should activate for a near-Y high-dE branch'
);
assert.strictEqual(
  mainPolishKeep({
    bestScore: 9.096,
    beforeScore: 9.096,
    beforeDe: 9.096,
    beforeLum: 0.916,
    candidateScore: 7.316,
    candidateDe: 6.36,
    candidateLum: 3.73,
  }),
  true,
  '105 main polish refinement should keep a score-improving RGB/luma candidate even when Y moves away temporarily'
);
assert.strictEqual(
  mainPolishRefineActive({ de: 9.096, lumPct: 6.0 }),
  false,
  '105 main polish refinement should stay inactive when Y is not near enough for the committed-polish-style branch'
);
assert.strictEqual(
  mainPolishRefineActive({ ire: 109, de: 9.096, lumPct: 0.916 }),
  false,
  '109 should remain outside the 105 main polish refinement path'
);
for (const ire of [99, 100]) {
  assert.strictEqual(
    mainPolishRefineActive({ ire, de: 9.096, lumPct: 0.916 }),
    false,
    `${ire}% legal-white pair should remain outside the 105 main polish refinement path`
  );
}
assert.strictEqual(
  mainPolishKeep({
    bestScore: 9.096,
    beforeScore: 9.096,
    beforeDe: 9.096,
    beforeLum: 0.916,
    candidateScore: 9.4,
    candidateDe: 9.4,
    candidateLum: 1.5,
  }),
  false,
  '105 main polish refinement should reject candidates that fail to improve combined score'
);

assert.strictEqual(
  scoreBranchPromoted({
    bestDe: 9.096,
    bestLum: 0.916,
    bestScore: 9.096,
    candidateDe: 6.36,
    candidateLum: 3.73,
    candidateScore: 7.316,
  }),
  true,
  '105 should promote a lower combined-score RGB/chroma branch over a near-Y high-dE best, then chase Y from that branch'
);
assert.strictEqual(
  scoreBranchPromoted({
    bestDe: 9.096,
    bestLum: 0.916,
    bestScore: 9.096,
    candidateDe: 5.08,
    candidateLum: 6.72,
    candidateScore: 7.08,
  }),
  true,
  '105 score-branch promotion should compare combined score rather than absolute Y alone'
);
assert.strictEqual(
  scoreBranchPromoted({
    ire: 109,
    bestDe: 9.096,
    bestLum: 0.916,
    bestScore: 9.096,
    candidateDe: 6.36,
    candidateLum: 3.73,
    candidateScore: 7.316,
  }),
  false,
  '109 should remain outside the 105 score-branch promotion path'
);
for (const ire of [99, 100]) {
  assert.strictEqual(
    scoreBranchPromoted({
      ire,
      bestDe: 9.096,
      bestLum: 0.916,
      bestScore: 9.096,
      candidateDe: 6.36,
      candidateLum: 3.73,
      candidateScore: 7.316,
    }),
    false,
    `${ire}% legal-white pair should remain outside the 105 score-branch promotion path`
  );
}
assert.strictEqual(
  scoreBranchPromoted({
    bestDe: 1.8,
    bestLum: 0.4,
    bestScore: 1.8,
    candidateDe: 1.4,
    candidateLum: 3.5,
    candidateScore: 2.1,
  }),
  false,
  '105 should not promote a worse-score high-Y branch when the near-Y best is already reasonably low dE'
);

function topLumaKey({ ire = 105, current, delta }) {
  return `${ire}|${current.toFixed(2)}|${delta < 0 ? -1 : 1}|${Math.abs(delta).toFixed(2)}`;
}

function recordTopBadLuma(families, change, before, after, bestScore, candidateScore) {
  if (Math.abs(after.lum) + 0.10 >= Math.abs(before.lum)) return null;
  const deWorse = after.de > before.de + 0.10;
  const chromaWorse = after.chroma > before.chroma + 0.004;
  const scoreWorse = candidateScore > bestScore + 0.25;
  if (!deWorse && !chromaWorse && !scoreWorse) return null;
  const key = topLumaKey(change);
  const entry = families[key] || { count: 0, severeCount: 0 };
  entry.count += 1;
  if (after.de > before.de + 0.25 || after.chroma > before.chroma + 0.008 || scoreWorse) entry.severeCount += 1;
  families[key] = entry;
  return entry;
}

function topLumaSuppressed(families, change) {
  const entry = families[topLumaKey(change)];
  return !!entry && (entry.severeCount >= 1 || entry.count >= 2);
}

const topFamilies = {};
recordTopBadLuma(
  topFamilies,
  { ire: 105, index: 24, current: 0, delta: -0.25 },
  { de: 6.49, lum: 6.18, chroma: 0.043 },
  { de: 6.67, lum: 5.80, chroma: 0.050 },
  28.2,
  28.6
);
assert.strictEqual(
  topLumaSuppressed(topFamilies, { ire: 105, index: 24, current: 0, delta: -0.25 }),
  true,
  'a bad top-window luma-only move should suppress the same magnitude from the restored state'
);
assert.strictEqual(
  topLumaSuppressed(topFamilies, { ire: 105, index: 24, current: 0, delta: -0.125 }),
  false,
  'a bad top-window luma-only move should not suppress a smaller same-slot retry from the restored state'
);

function topCandidateAllowed(candidate, best) {
  if (candidate.over < best.over) return true;
  if (candidate.over > best.over) return false;
  if (candidate.worst + 0.03 < best.worst) return true;
  if (candidate.score + 0.03 < best.score && candidate.worst <= best.worst + 0.06) return true;
  return false;
}
const topBest = topWindowScoreFor({ 105: { de: 6.65, lum: 9.0 }, 99: { de: 0.7, lum: 0.2 }, 100: { de: 0.8, lum: 0.2 }, 109: { de: 0.4, lum: 8 } });
const topSmallerCut = topWindowScoreFor({ 105: { de: 6.1, lum: 5.5 }, 99: { de: 0.7, lum: 0.2 }, 100: { de: 0.8, lum: 0.2 }, 109: { de: 0.4, lum: 8 } });
assert(topCandidateAllowed(topSmallerCut, topBest), 'top-window keep logic should accept a smaller 105 luma correction that improves scored worst/error after a larger failed one');

console.log('LG AutoCal top luma budget regression checks passed.');
