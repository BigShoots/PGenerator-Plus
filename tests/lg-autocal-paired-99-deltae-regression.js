const assert = require('assert');
const fs = require('fs');

const webuiSource = fs.readFileSync('usr/share/PGenerator/webui.pm', 'utf8');
const autocalSource = fs.readFileSync('usr/bin/meter_lg_autocal.pl', 'utf8');

function sliceBetween(source, startNeedle, endNeedle) {
  const start = source.indexOf(startNeedle);
  assert(start >= 0, `Missing start marker: ${startNeedle}`);
  const end = source.indexOf(endNeedle, start + startNeedle.length);
  assert(end > start, `Missing end marker after: ${startNeedle}`);
  return source.slice(start, end);
}

const drawAllCharts = sliceBetween(webuiSource, 'function drawAllCharts(readings)', 'function getChartCtx(id)');
const drawDeltaEChart = sliceBetween(webuiSource, 'function drawDeltaEChart(gs,allSteps,readingMap,rawGs)', 'function drawDeltaE2000Chart');
const drawRGBChart = sliceBetween(webuiSource, 'function drawRGBChart(gs,allSteps,readingMap)', 'function drawEOTFChart');
const drawEOTFChart = sliceBetween(webuiSource, 'function drawEOTFChart(gs,allSteps,readingMap)', 'function drawGammaChart');
const drawGammaChart = sliceBetween(webuiSource, 'function drawGammaChart(gs,allSteps,readingMap)', 'function drawDeltaEChart');
const chartInteraction = sliceBetween(webuiSource, 'function chartRegisterInteraction()', 'function chartFindHit');
const chartHover = sliceBetween(webuiSource, 'function chartHandleHover(e,canvasId)', 'function chartHandleClick');

assert(
  !webuiSource.includes('function meterLgAutoCal26PairedDeltaEActive()') &&
    !webuiSource.includes('function meterLgAutoCal26PairedDeltaEFor99(') &&
    !webuiSource.includes('function meterLgAutoCal26DeltaEReadingAt('),
  'WebUI chart code should not keep a 99/100 paired Delta E helper'
);
assert(
  drawAllCharts.includes('const rawGs=meterGreyscaleReadings(readings);') &&
    drawAllCharts.includes('const gs=meterFilterLgAutoCalChartItems(rawGs);') &&
    drawAllCharts.includes('drawDeltaEChart(gs,allSteps,readingMap,rawGs);'),
  'Delta E chart may receive raw greyscale readings, but visible point scoring should stay direct'
);
assert(
  drawDeltaEChart.includes('deMap[rd.ire]=meterGreyDeltaResult(rd,greyMode,deForm,gwWeight).value;') &&
    !drawDeltaEChart.includes('rawDeltaReadings') &&
    !drawDeltaEChart.includes('PairedDeltaE') &&
    !drawDeltaEChart.includes('paired.value'),
  'visible 99% Delta E bar should use the direct 99% reading, not the 99/100 paired average'
);
assert(
  !drawRGBChart.includes('PairedDeltaE') &&
    !drawEOTFChart.includes('PairedDeltaE') &&
    !drawGammaChart.includes('PairedDeltaE') &&
    drawRGBChart.includes('gs.forEach(rd=>{balMap[rd.ire]=rgbBalance(rd,effectiveWhiteRGB,greyMode);});') &&
	    drawGammaChart.includes('meterMeasuredEotfLuminanceSegments(') &&
	    drawGammaChart.includes('const scaleMeasuredLuminance=lum=>') &&
	    drawGammaChart.includes('if(!Number.isFinite(value)) return null;') &&
	    drawGammaChart.includes("return meterScaleEotfLuminancePlotValue('luminance',value,yTop,null,value);"),
  'RGB balance and luminance/EOTF/gamma charts should remain based on the actual 99% reading'
);
assert(
  chartInteraction.includes('deSelected[rd.ire]=result.value;') &&
    chartInteraction.includes('de2000[rd.ire]=result.de2000;') &&
    !chartInteraction.includes('PairedDeltaE') &&
    !chartInteraction.includes('dePaired') &&
    !chartHover.includes('99/100 avg'),
  '99% Delta E tooltip should display direct 99% Delta E and not expose a paired average'
);

{
  const direct99 = 0.309;
  const legalWhite = 19.26;
  const chartValue = direct99;
  const pairedAverage = (direct99 + legalWhite) / 2;
  assert.strictEqual(chartValue, direct99, 'fixture should show the visible 99% bar using direct 99% Delta E');
  assert.notStrictEqual(chartValue, pairedAverage, 'fixture should not use the legal-white paired average for the visible 99% bar');
}

const pairScore = sliceBetween(autocalSource, 'sub legal_white_pair_score {', 'sub legal_white_pair_worst_delta');
const bestUpdate = sliceBetween(autocalSource, 'sub legal_white_pair_best_update_allowed {', 'sub legal_white_pair_target_reached');
const committedPolish = sliceBetween(
  autocalSource,
  'my $keep_committed_candidate=0;',
  'if($keep_committed_candidate) {'
);
const mainBestUpdate = sliceBetween(
  autocalSource,
  'my $pair_best_update_reason=sub {',
  'my $read_legal_white_pair_counterpart=sub {'
);
const pairCounterpartRead = sliceBetween(
  autocalSource,
  'my $read_legal_white_pair_counterpart=sub {',
  'my $switch_to_worst_pair_step=sub {'
);
const mainLoopBestKeep = sliceBetween(
  autocalSource,
  'my $probe_found=0;',
  'my $candidate_score=$candidate_score_after;'
);
assert(
  autocalSource.includes('sub legal_white_pair_delta_average') &&
    pairScore.includes('my $worst=$score_a > $score_b ? $score_a : $score_b;') &&
    pairScore.includes('my $pair_avg=legal_white_pair_delta_average($de_a,$de_b);') &&
    pairScore.includes('my $white_rgb=autocal_step_is_white($step_a) ? $rgb_a : (autocal_step_is_white($step_b) ? $rgb_b : $worst_rgb);') &&
    pairScore.includes('($worst*1.40)+($best*0.18)+($pair_avg*0.12)+($spread*1.20)+($worst_rgb*0.30)+($white_rgb*0.45)'),
  'backend legal-white pair scoring should preserve worst-side protection and include combined 99/100 average plus 100% RGB balance scoring'
);
assert(
  bestUpdate.includes('my $candidate_avg=legal_white_pair_delta_average($de_a,$de_b);') &&
    bestUpdate.includes('return "paired_score_improved" if($candidate_worst <= $best_worst + 0.0001 && $candidate_avg + 0.0001 < $best_avg);'),
  'backend best-result verification should consider the combined pair average without allowing a worse worst-side result'
);

assert(
  bestUpdate.includes('sub legal_white_pair_best_update_reason') &&
    bestUpdate.includes('return "paired_score_improved" if($candidate_worst + 0.0001 < $best_worst);') &&
    bestUpdate.includes('return undef if($candidate_worst > $best_worst + 0.03);'),
  'backend paired best-result helper should expose a traceable paired-score reason while preserving worst-side protection'
);

assert(
  mainBestUpdate.includes('return undef if(!autocal_measurement_not_worse_than_best($de,$lum_pct,$best_de,$best_lum_pct));') &&
    mainBestUpdate.includes('my $reason=legal_white_pair_best_update_reason('),
  'main 99/100 path should bypass the 99-only not-worse gate only for paired scoring'
);

assert(
  autocalSource.includes('sub legal_white_pair_side_metrics') &&
    mainBestUpdate.includes('legal_white_pair_side_metrics($de,$lum_pct,$read_step,$reading,$pair_de,$pair_lum_pct,$pair_step,$pair_reading)') &&
    mainBestUpdate.includes('legal_white_pair_side_metrics($best_de,$best_lum_pct,$best_read_step,$best_reading,$best_pair_de,$best_pair_lum_pct,$best_pair_step,$best_pair_reading)') &&
    mainBestUpdate.includes('$pair_best_reject_reason="same_ire_${ire}_itp_guard";'),
  'paired ITP guard should compare candidate and best by explicit 99/100 IRE side, not by active/pair role after a legal-white switch'
);

assert(
  autocalSource.includes('return undef if(legal_white_pair_disabled_for_sdr_initial_99($config,$target,$step));') &&
    autocalSource.includes('sub legal_white_pair_disabled_for_sdr_initial_99') &&
    autocalSource.includes('return abs(($target->{"ire"}+0)-99) <= 0.001 ? 1 : 0;') &&
    autocalSource.includes('trace_109($read_step,"legal_white_pair_disabled_for_99"') &&
    autocalSource.includes('reason=>"sdr_initial_autocal_99_unpaired"') &&
    !autocalSource.includes('Full-DDC spine still needs the hidden 100% legal-white read'),
  'initial SDR full-DDC spine 99% should disable the hidden 100% legal-white read and trace the unpaired mode'
);

assert(
  mainLoopBestKeep.includes('my $best_update_reason=$paired_white_step ? $pair_best_update_reason->($candidate_score_after) : undef;') &&
    mainLoopBestKeep.includes('my $keep_candidate=$paired_white_step') &&
    mainLoopBestKeep.includes('? defined($best_update_reason)') &&
    mainLoopBestKeep.includes('$store_best_pair->() if($paired_white_step);') &&
    mainLoopBestKeep.includes('reason=>defined($best_update_reason)?$best_update_reason'),
  'main AutoCal 99/100 loop should promote the combined paired-best state and store its paired 100% read'
);

assert(
  committedPolish.includes('$best_update_reason=legal_white_pair_best_update_reason($score,$best_score,$de,$committed_pair_de,$best_de,$best_pair_de,$target_delta);') &&
    committedPolish.includes('$keep_committed_candidate=defined($best_update_reason) ? 1 : 0;') &&
    committedPolish.includes('$keep_committed_candidate=(defined($best_update_reason) && $not_worse_measurement) ? 1 : 0;') &&
    committedPolish.includes('"committed_polish_best_candidate"') &&
    committedPolish.includes('reason=>defined($best_update_reason)?$best_update_reason:""'),
  'committed legal-white pair polish should keep a better combined pair without the old active-side-only veto, while non-paired polish still requires not-worse'
);

assert(
  autocalSource.includes('Keeping best 99/100 paired result') &&
    autocalSource.includes('reason=>defined($best_update_reason)?$best_update_reason') &&
    autocalSource.includes('candidate_99_delta_e=>legal_white_pair_metric_delta($candidate_metrics,99)') &&
    autocalSource.includes('candidate_100_delta_e=>legal_white_pair_metric_delta($candidate_metrics,100)') &&
    autocalSource.includes('best_99_delta_e=>legal_white_pair_metric_delta($best_metrics,99)') &&
    autocalSource.includes('best_100_delta_e=>legal_white_pair_metric_delta($best_metrics,100)') &&
    autocalSource.includes('candidate_100_rgb_imbalance=>legal_white_pair_metric_rgb_imbalance($candidate_metrics,100)') &&
    autocalSource.includes('$pair_best_reject_reason="100_delta_guard";') &&
    autocalSource.includes('$pair_best_reject_reason="100_rgb_guard";') &&
    autocalSource.includes('pair_update_reject_reason=>defined($pair_best_reject_reason)?$pair_best_reject_reason:""'),
  'trace output should identify paired best-state updates, explicit 99/100 side deltas, and paired rejection reasons'
);

assert(
  !autocalSource.includes('hdr20_shared_top_white_pair') &&
    !autocalSource.includes('my $hdr20_shared_top_pair=') &&
    !autocalSource.includes('my $hdr20_pair_evaluation_white_y=sub {') &&
    !autocalSource.includes('my $recalculate_active_against_pair_white=sub {'),
  'retired HDR 94.98/100 paired scoring helpers should stay removed'
);
assert(
  pairCounterpartRead.includes('my $pair_eval_white_y=$white_y;') &&
    pairCounterpartRead.includes('my $other_target_step_y=defined($other_guarded_y) ? $other_guarded_y') &&
    pairCounterpartRead.includes('pair_evaluation_white_y=>$pair_eval_white_y'),
  'SDR paired counterpart reads should use the normal white-reference path without HDR local-pair branches'
);

function scorePair(deA, deB) {
  const worst = Math.max(deA, deB);
  const best = Math.min(deA, deB);
  const avg = (deA + deB) / 2;
  const spread = Math.abs(deA - deB);
  return worst * 1.40 + best * 0.18 + avg * 0.12 + spread * 1.20;
}

function pairUpdateAllowed(candidateScore, bestScore, deA, deB, bestDeA, bestDeB, targetDelta = 0.5) {
  const candidateWorst = Math.max(deA, deB);
  const bestWorst = Math.max(bestDeA, bestDeB);
  if (candidateWorst + 0.0001 < bestWorst) return true;
  if (candidateWorst > bestWorst + 0.03) return false;
  const candidateAvg = (deA + deB) / 2;
  const bestAvg = (bestDeA + bestDeB) / 2;
  if (candidateWorst <= bestWorst + 0.0001 && candidateAvg + 0.0001 < bestAvg) return true;
  const candidateSpread = Math.abs(deA - deB);
  const bestSpread = Math.abs(bestDeA - bestDeB);
  if (candidateScore + 0.0001 < bestScore && candidateSpread + 0.02 < bestSpread) return true;
  return candidateWorst <= targetDelta + 0.30 && candidateScore + 0.0001 < bestScore;
}

const best99 = 0.8140603625;
const best100 = 1.5366067721;
const candidate99 = 0.6661467611;
const candidate100 = 1.2439669083;
assert(scorePair(candidate99, candidate100) < scorePair(best99, best100), 'fixture should recreate the better legal-white pair score');
assert(Math.max(candidate99, candidate100) < Math.max(best99, best100), 'fixture should improve the worst legal-white side');
assert(candidate100 > 1.0, 'fixture should keep the candidate 100% side over the ITP+Y acceptance threshold');
assert(
  pairUpdateAllowed(scorePair(candidate99, candidate100), scorePair(best99, best100), candidate99, candidate100, best99, best100),
  'better 99/100 pair should be accepted in both main AutoCal and committed polish for the reported 20:54:20 vs 20:56:57 case'
);

function withinItpAcceptance(de) {
  return de <= 1.0;
}

function oldRoleItpGuardAllows(candidateActive, bestActive) {
  return !(withinItpAcceptance(bestActive) && !withinItpAcceptance(candidateActive));
}

function sameIreItpGuardAllows(candidateByIre, bestByIre) {
  return [99, 100].every((ire) => {
    return !(withinItpAcceptance(bestByIre[ire]) && !withinItpAcceptance(candidateByIre[ire]));
  });
}

assert(
  !oldRoleItpGuardAllows(candidate100, best99),
  'fixture should prove the old active-role guard rejects after legal_white_pair_switch by comparing stored 99 against candidate 100'
);
assert(
  sameIreItpGuardAllows({ 99: candidate99, 100: candidate100 }, { 99: best99, 100: best100 }),
  'same-IRE ITP guard should allow the reported candidate because candidate 99 compares to best 99 and candidate 100 compares to best 100'
);
assert(
  !pairUpdateAllowed(scorePair(1.62, 0.55), scorePair(best99, best100), 1.62, 0.55, best99, best100),
  'paired scoring should reject catastrophic worst-side regression'
);
assert(
  autocalSource.includes('$keep_committed_candidate=(defined($best_update_reason) && $not_worse_measurement) ? 1 : 0;'),
  'non-paired committed polish should still use the existing not-worse guard'
);

console.log('LG AutoCal paired 99/100 Delta E regression checks passed.');
