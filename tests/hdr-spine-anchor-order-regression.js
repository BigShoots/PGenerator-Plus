const assert = require('assert');
const fs = require('fs');

const source = fs.readFileSync('usr/bin/meter_lg_autocal.pl', 'utf8');

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

console.log('HDR full-DDC spine anchor order regression OK');
