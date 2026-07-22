// Locks three CIE/ΔE chart behaviors reported during series reads:
// 1. Pre-read (preset) target squares draw at the SAME size as the live chart
//    (3.5/1.4 dark, 4.2/2 light) — they used to change size when reads started.
// 2. Targets stay visible for the WHOLE read: the live 2D chart draws hollow
//    squares for every unread series step, and the 3D chart injects unread
//    steps as preset-style items. Only measured markers arrive per node.
// 3. The ΔE bar chart lays its axis out over the FULL series (each bar at its
//    own series slot) so mid-read bars sit under their thumbnails — spreading
//    only the read patches across the scroll-synced full-width canvas pushed
//    the newest bar outside the thumb scroll window ("cut off").
const assert = require('assert');
const fs = require('fs');
const source = fs.readFileSync('usr/share/PGenerator/webui.pm', 'utf8');
function extractFunction(name) {
  const token = `function ${name}(`;
  const start = source.indexOf(token);
  assert(start >= 0, `Missing function ${name}`);
  let i = source.indexOf('{', start); let depth = 0;
  for (; i < source.length; i++) { const ch = source[i];
    if (ch === '{') depth++;
    else if (ch === '}') { depth--; if (depth === 0) return source.slice(start, i + 1); } }
  throw new Error(`Failed to extract ${name}`);
}

// (1) preset square = live square
const preset = extractFunction('drawCIEChartPreset');
assert(/const sq=meterCieLightMode\(\)\?4\.2:3\.5;/.test(preset), 'preset target square uses the shared light/dark size');
assert(/lineWidth=meterCieLightMode\(\)\?2:1\.4/.test(preset), 'preset stroke width uses the shared light/dark width');
assert(!/const sq=6;/.test(preset), 'old oversized preset square gone');

// (2a) live 2D chart keeps unread targets on screen
const live2d = extractFunction('drawCIEChart');
assert(/readNames/.test(live2d) && /meterSeriesSteps\.forEach/.test(live2d), 'live 2D draws unread step targets');
assert(/meterCieViewOpts\.targets&&Array\.isArray\(meterSeriesSteps\)/.test(live2d), 'unread targets honor the Targets checkbox');
const liveSquares = live2d.match(/const sq=meterCieLightMode\(\)\?4\.2:3\.5;/g) || [];
assert(liveSquares.length >= 2, 'unread + read targets share the same light/dark square size');

// (2b) live 3D chart injects unread steps as preset-style items
const live3d = extractFunction('drawCIEChart3D');
assert(/_presetStep:true/.test(live3d), '3D injects unread steps');
assert(/isPreset\|\|rd\._presetStep/.test(live3d), '3D per-item preset branch');
assert(/itemPreset=isPreset\|\|!!rd\._presetStep/.test(live3d), '3D colors resolve per item');

// (3) ΔE bars on the full-series axis
const de = extractFunction('drawColorDeltaE2000Chart');
assert(/axisNames/.test(de) && /axisIndex/.test(de), 'ΔE chart has a full-series axis mode');
assert(/steps\.length>=deData\.length&&deData\.every\(d=>idx\.has\(String\(d\.name\)\)\)/.test(de), 'full axis engages only when every reading maps to a step');
assert(/const pos=axisIndex\?axisIndex\.get\(String\(d\.name\)\):i;/.test(de), 'bars land at their series slot');
// (4) ΔE scroll only for long series (>26 nodes): ColorChecker / Sat Sweep /
// post-cal report sets always fit-to-width (wide canvas clipped report charts).
const layout = extractFunction('meterUpdateColorDeltaEScrollLayout');
assert(/const needsScroll=steps\.length>40;/.test(layout), 'scroll threshold is >40 nodes (ColorChecker 30 + Sat Sweep + Cube 3³ fit-to-width)');
assert(/isColor&&needsScroll&&content>viewport\+4/.test(layout), 'wide canvas gated on needsScroll');
console.log('chart-targets-persist-regression: PASS');
