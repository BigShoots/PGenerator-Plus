const assert = require('assert');
const fs = require('fs');

const helper = fs.readFileSync('usr/bin/meter_series.sh', 'utf8');

assert(
  helper.includes('patch_insert_settle_seconds()'),
  'meter_series.sh should centralize pattern-insert settle timing'
);
assert(
  helper.includes('if float_le "$ire" 25; then') &&
    helper.includes('echo 3.0') &&
    helper.includes('echo 1.5'),
  'Pattern insertion should wait longer before low-level patches while preserving the normal delay for brighter patches'
);
assert(
  helper.includes('sleep "$(patch_insert_settle_seconds "$IRE")"') &&
    helper.includes('sleep "$(patch_insert_settle_seconds "$FIRST_IRE")"'),
  'Main series reads and final white refresh should both use the pattern-insert settle helper'
);

console.log('Meter series pattern-insert delay regression checks passed.');
