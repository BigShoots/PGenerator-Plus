const assert = require('assert');
const fs = require('fs');

const helper = fs.readFileSync('usr/bin/meter_series.sh', 'utf8');
const webui = fs.readFileSync('usr/share/PGenerator/webui.pm', 'utf8');

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
  helper.includes('PATCH_INSERT_PATCH_DURATION_PROVIDED=0') &&
    helper.includes('(( PATCH_INSERT_PATCH_DURATION_PROVIDED == 0 )) && PATCH_INSERT_DYNAMIC_SETTLE=1'),
  'Old clients that only send patch_insert should keep the dynamic settle fallback'
);
assert(
  helper.includes('maybe_pattern_insert_before_step "$i" "$IRE"') &&
    helper.includes('maybe_pattern_insert_before_step "$READING_COUNT" "$FIRST_IRE"'),
  'Main series reads and final white refresh should both use configurable insertion'
);
assert(
  helper.includes('PATCH_INSERT_TIME_FREQUENCY_MS') &&
    helper.includes('post_insert_patch "$PATCH_INSERT_TIME_LEVEL" "$PATCH_INSERT_TIME_DURATION_MS" "time"') &&
    helper.includes('post_insert_patch "$PATCH_INSERT_PATCH_LEVEL" "$duration_ms" "patch"'),
  'Pattern insertion should support independent time-based and patch-count insertion controls'
);
assert(
  helper.includes('PATTERN_DELAY_SEC=$(milliseconds_to_seconds "$PATTERN_DELAY_MS")') &&
    helper.includes('sleep "$PATTERN_DELAY_SEC"'),
  'Series reads should support a source/pattern delay separate from meter delay'
);
assert(
  webui.includes('function meterPatternInsertionDefaultsForMode()') &&
    webui.includes('timeFrequency:hdrLike?5:45') &&
    webui.includes('patchEnabled:hdrLike') &&
    webui.includes('meterApplyPatternInsertionDefaults(false);'),
  'Web UI should apply SDR vs HDR/DV pattern insertion defaults when controls are still defaulted'
);
assert(
  webui.includes('...meterPatternInsertionPayload()') &&
    webui.includes('patch_insert_time_frequency_ms') &&
    webui.includes('patch_insert_patch_duration_ms'),
  'Series payloads should include the detailed pattern insertion controls'
);

console.log('Meter series pattern-insert delay regression checks passed.');
