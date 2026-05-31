#!/usr/bin/env node
'use strict';

const assert = require('assert');
const fs = require('fs');

const source = fs.readFileSync('usr/bin/meter_lg_autocal.pl', 'utf8');

assert(
  source.includes('sub queued_adjustments_rebased_to_current_arrays') &&
    source.includes('trace_109($step,"queued_adjustment_rebased"') &&
    source.includes('$body_luminance_next_adjustments,$arrays,$target,\\%tried_values,$read_step,"body_luminance_next_adjustments"') &&
    source.includes('$headroom_next_adjustments,$arrays,$target,\\%tried_values,$read_step,"headroom_next_adjustments"'),
  'queued next-iteration adjustments should be rebased against live arrays before reuse'
);

assert(
  !source.includes('$adjustments=$body_luminance_next_adjustments if(!$headroom_105_near_y_cleanup_active'),
  'body luminance queues must not be reused with stale absolute current/next values'
);

function clampDdc(value) {
  if (!Number.isFinite(value)) value = 0;
  if (value > 50) value = 50;
  if (value < -50) value = -50;
  return Number(value.toFixed(2));
}

function rebaseQueued(adjustments, arrays, target, tried = {}) {
  return adjustments.map(adj => {
    const setting = adj.setting;
    const idx = adj.index ?? target.index;
    const current = Number(arrays[setting][idx] ?? 0);
    const plannedCurrent = Number(adj.current ?? current);
    const delta = Number(adj.delta ?? (adj.next - plannedCurrent));
    const copy = { ...adj };
    if (Math.abs(current - plannedCurrent) > 0.0001) {
      const next = clampDdc(current + delta);
      const key = next.toFixed(2);
      if (tried[setting]?.[key]) return null;
      copy.queued_original_current = plannedCurrent;
      copy.queued_original_next = adj.next;
      copy.current = current;
      copy.next = next;
      copy.delta = next - current;
      copy.queued_rebased = true;
    }
    return copy;
  });
}

const target = { index: 24, ire: 105 };
const arrays = { adjustingLuminance: Array(26).fill(0) };
arrays.adjustingLuminance[target.index] = -3;

const [rebased] = rebaseQueued(
  [{ channel: 'lum', setting: 'adjustingLuminance', current: 0, next: -0.5, delta: -0.5 }],
  arrays,
  target
);

assert.strictEqual(rebased.current, -3, 'stale queued current should be replaced by restored best array value');
assert.strictEqual(rebased.next, -3.5, 'queued -0.5 luma move should start from restored best, not zero');
assert.strictEqual(rebased.delta, -0.5, 'queued move magnitude should be preserved when rebasing');
assert.strictEqual(rebased.queued_rebased, true, 'rebased queued adjustment should be traceable');

const [unchanged] = rebaseQueued(
  [{ channel: 'lum', setting: 'adjustingLuminance', current: -3, next: -3.5, delta: -0.5 }],
  arrays,
  target
);

assert.strictEqual(unchanged.current, -3, 'matching queued current should remain unchanged');
assert.strictEqual(unchanged.next, -3.5, 'matching queued next should remain unchanged');
assert.strictEqual(unchanged.queued_rebased, undefined, 'matching queued adjustment should not be marked rebased');

console.log('LG AutoCal queued adjustment rebase regression checks passed.');
