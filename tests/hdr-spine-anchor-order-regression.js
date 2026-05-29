const assert = require('assert');
const fs = require('fs');

const source = fs.readFileSync('usr/bin/meter_lg_autocal.pl', 'utf8');

function block(start, end) {
  const blockStart = source.indexOf(start);
  const blockEnd = source.indexOf(end, blockStart);
  assert(blockStart >= 0 && blockEnd > blockStart, `${start} block should exist`);
  return source.slice(blockStart, blockEnd);
}

const anchorStart = source.indexOf('sub lg_autocal_26_full_ddc_spine_anchor_ires_for_layout {');
const anchorEnd = source.indexOf('sub lg_autocal_26_full_ddc_spine_anchor_ddc_ires_for_layout {', anchorStart);
assert(anchorStart >= 0 && anchorEnd > anchorStart, 'full-DDC spine anchor helper should exist');
const anchorSource = source.slice(anchorStart, anchorEnd);

assert(
  anchorSource.includes('return (100,5,20,40,60,80) if($layout eq "hdr20");'),
  'HDR20 full-DDC spine anchor order should include 5% before 20%'
);
assert(
  anchorSource.includes('return (109,20,40,60,80);') &&
    !anchorSource.includes('return (109,5,20,40,60,80);'),
  'SDR full-DDC spine anchor order should remain unchanged and exclude 5%'
);

const orderStart = source.indexOf('my @hdr_autocal_26_order=(lg_autocal_26_full_ddc_spine_anchor_ires_for_layout("hdr20"),@top_down);');
assert(orderStart >= 0, 'HDR20 AutoCal order should be built from the HDR full-DDC spine anchor helper');

const propagateStart = source.indexOf('sub propagate_uncalibrated_26pt_slots {');
const propagateEnd = source.indexOf('sub lg_autocal_26_hdr20_propagation_skip_slot_mask', propagateStart);
assert(propagateStart >= 0 && propagateEnd > propagateStart, '26pt propagation helper should exist');
const propagateSource = source.slice(propagateStart, propagateEnd);
assert(
  propagateSource.includes('next if($calibrated_slot_mask->[$idx]);'),
  'full-DDC spine propagation should not overwrite calibrated/best slots'
);

const fullDdcSkipSource = block(
  'sub lg_autocal_26_full_ddc_spine_propagation_skip_slot_mask {',
  'sub calibrated_26pt_slot_for_ire {'
);
assert(
  fullDdcSkipSource.includes('foreach my $ire (lg_autocal_26_full_ddc_spine_anchor_ddc_ires($config))') &&
    fullDdcSkipSource.includes('$mask[$idx]=1;'),
  'full-DDC spine propagation should explicitly skip configured anchor slots'
);

const refreshSource = block(
  'sub refresh_propagated_uncalibrated_26pt_slots {',
  'sub lg_autocal_26_seeded_move_damping_ready {'
);
assert(
  refreshSource.includes('lg_autocal_26_full_ddc_spine_propagation_skip_slot_mask($config,$calibrated_slot_mask)') &&
    refreshSource.includes('propagate_uncalibrated_26pt_slots($arrays,$calibrated_slot_mask,$source_slot_mask,$skip_slot_mask)'),
  'full-DDC spine refresh should pass the anchor skip mask into interpolation'
);

const seedSource = block(
  'sub seed_target_from_prior_slot {',
  'sub repeated_value {'
);
assert(
  seedSource.includes('return 0 if(lg_autocal_26_full_ddc_spine_enabled($config) && lg_autocal_26_full_ddc_spine_anchor($target));'),
  'full-DDC spine anchors and anchor revisits should not receive adjacent/synthesized seed writes'
);

for (const hdrAnchor of [100, 5, 20, 40, 60, 80]) {
  assert(anchorSource.includes(`${hdrAnchor}`), `HDR anchor ${hdrAnchor}% should be represented in the anchor helper`);
}
for (const sdrAnchor of [109, 20, 40, 60, 80]) {
  assert(anchorSource.includes(`${sdrAnchor}`), `SDR anchor ${sdrAnchor}% should be represented in the anchor helper`);
}
for (const intermediate of [7, 10, 15, 25, 30, 35, 45, 50, 70, 90]) {
  assert(!fullDdcSkipSource.includes(`(${intermediate})`), `intermediate ${intermediate}% should not be hard-skipped from spine synthesis`);
}

console.log('HDR/SDR full-DDC spine anchor regression OK');
