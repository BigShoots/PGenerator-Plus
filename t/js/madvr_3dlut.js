/*
 * madvr_3dlut.test.js — characterization + format suite for the madVR
 * .3dlut (H3D) writer in usr/share/PGenerator/webui-workspace.js.
 *
 * Extracts the converter functions from the live source by anchor (no line
 * numbers), feeds them a tiny analytic .cube, and pins the exact byte layout
 * DisplayCAL's madvr.py writes: 96-byte LE header, text params at 512,
 * 256^3 BGR uint16 LE nodes (blue fastest) at 16384, linear cal1 trailer.
 *
 * Run:  node t/js/madvr_3dlut.js   (raw JSON)
 *       prove t/madvr_3dlut.t      (TAP via perl wrapper)
 * Requires: Node 22+, no npm dependencies.
 */
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('node:assert/strict');

const SRC = path.join(__dirname, '..', '..', 'usr', 'share', 'PGenerator', 'webui-workspace.js');
const source = fs.readFileSync(SRC, 'utf8');

// Anchor-extract top-level functions and consts (brace-match state machine
// skipping strings/comments, same contract as rgb_balance_formula.js).
function extractBlock(name, decl) {
  const re = new RegExp(`^${decl} ${name}\\b`, 'm');
  const m = source.match(re);
  assert.ok(m, `${decl} ${name} found in webui-workspace.js`);
  assert.equal(source.slice(0, m.index).match(re), null, `${name} anchor unique`);
  // Find the BODY brace, not the first brace: async callers open with an
  // object-literal argument ({title:...}) before the body's '{', and
  // brace-matching from that object truncates the extraction at its '}'.
  const sigEnd = source.indexOf(')', source.indexOf('(', m.index));
  let i = source.indexOf('{', sigEnd);
  if (decl === 'const') {
    // const initializers in this file are single-line statements
    const end = source.indexOf('\n', m.index);
    return source.slice(m.index, end + 1);
  }
  let depth = 0, inStr = null, inLine = false, inBlock = false, inRe = false;
  for (; i < source.length; i++) {
    const c = source[i], p = source[i - 1];
    if (inLine) { if (c === '\n') inLine = false; continue; }
    if (inBlock) { if (c === '/' && p === '*') inBlock = false; continue; }
    if (inStr) { if (c === '\\') { i++; continue; } if (c === inStr) inStr = null; continue; }
    if (c === '/' && source[i + 1] === '/') { inLine = true; continue; }
    if (c === '/' && source[i + 1] === '*') { inBlock = true; continue; }
    if (c === '"' || c === "'" || c === '`') { inStr = c; continue; }
    if (c === '{') depth++;
    else if (c === '}') { depth--; if (depth === 0) return source.slice(m.index, i + 1); }
  }
  throw new Error(`${name} block not closed`);
}

const names = [
  ['METER_MADVR_LUT_RES', 'const'], ['METER_MADVR_PARAM_OFFSET', 'const'],
  ['METER_MADVR_LUT_OFFSET', 'const'], ['METER_MADVR_CAL1_SIZE', 'const'],
  ['METER_MADVR_D65_WP', 'const'], ['meterMadvrScratch', 'const'],
  ['METER_MADVR_RANGE_MIN', 'const'], ['METER_MADVR_RANGE_SPAN', 'const'],
  ['meterMadvrPrimaries', 'function'], ['meterMadvrParamsFromName', 'function'],
  ['meterMadvrIccMode', 'function'],
  ['meterMadvrLatticePos', 'function'], ['meterMadvrTrilinear', 'function'],
  ['meterMadvrAlloc', 'function'], ['meterMadvrFillRowplane', 'function'],
  ['meterMadvrFinish', 'function'], ['meterCubeToMadvr', 'function'],
  ['meterMadvrYield', 'function'],
  ['meterCubeToMadvrAsync', 'async function'], ['METER_MADVR_YIELD_PLANES', 'const'],
];
// MessageChannel comes from Node's web-compat globals (real async port
// delivery); fall back to setTimeout if a future runtime lacks it.
const context = { Promise, setTimeout, console,
  MessageChannel: (typeof MessageChannel === 'function') ? MessageChannel : undefined };
vm.createContext(context);
for (const [n, d] of names) vm.runInContext(extractBlock(n, d), context);

const results = [];
const pending = [];
const t = (label, fn) => { pending.push([label, fn]); };
async function runAll() {
  for (const [label, fn] of pending) {
    try { await fn(); results.push([label, true, '']); }
    catch (e) { results.push([label, false, String(e && e.message || e)]); }
  }
}
// Cross-realm (vm) values have foreign prototypes; compare via JSON.
const eq = (a, b, msg) => assert.equal(JSON.stringify(a), JSON.stringify(b), msg);

// Build a test .cube lattice: output = 0.25 + 0.5*signal on each axis
// (a ramp that is neither identity nor flat, linear in the signal).
// Storage follows the .cube convention: red index varies fastest.
function rampParsed(S) {
  const values = [];
  for (let b = 0; b < S; b++) for (let g = 0; g < S; g++) for (let r = 0; r < S; r++) {
    values.push([0.25 + 0.5 * r / (S - 1), 0.25 + 0.5 * g / (S - 1), 0.25 + 0.5 * b / (S - 1)]);
  }
  return { ok: true, size: S, values, domainMin: [0, 0, 0], domainMax: [1, 1, 1], errors: [] };
}

// Constant black-offset fixture: the exact class of non-identity correction
// that silently mis-registers if the fill ignores the header's 16-235 range.
function offsetParsed(S, off) {
  const values = [];
  for (let i = 0; i < S * S * S; i++) values.push([off, off, off]);
  return { ok: true, size: S, values, domainMin: [0, 0, 0], domainMax: [1, 1, 1], errors: [] };
}

const parsed = rampParsed(5);

// Decode a node back to signal under the header's declared video range.
// This mirrors the writer's contract on purpose; the pins that matter for
// the range bug are absolute code values + this readback's exactness, so a
// full-range fill can never satisfy both.
const decode = (code16) => (code16 / 256 - 16) / 219;

t('unknown gamut refused', () => {
  assert.equal(context.meterMadvrPrimaries('rec-9999'), null);
  assert.equal(context.meterCubeToMadvr(parsed, { gamut: 'rec-9999' }), null);
});

t('bt709 primaries match madVR install-API values', () => {
  eq(context.meterMadvrPrimaries('bt709'),
    [0.64000, 0.33000, 0.30000, 0.60000, 0.15000, 0.06000, 0.31273, 0.32902]);
  eq(context.meterMadvrPrimaries('BT2020').slice(0, 2), [0.708, 0.292]);
});

t('name heuristics: solved names carry mode and gamut', () => {
  eq(context.meterMadvrParamsFromName('20261001_TV_sdr_ramp_active_bt709_2.2.cube'), { gamut: 'bt709', hdr: false });
  eq(context.meterMadvrParamsFromName('20261001_TV_hdr10_lattice_active_bt2020_2.4.cube'), { gamut: 'bt2020', hdr: true });
  eq(context.meterMadvrParamsFromName('x_p3d65_y'), { gamut: 'p3d65', hdr: false });
  eq(context.meterMadvrParamsFromName('plain'), { gamut: 'bt709', hdr: false });
  // hdr without gamut defaults to bt2020 (solve-side rule)
  eq(context.meterMadvrParamsFromName('lut_hdr10'), { gamut: 'bt2020', hdr: true });
  // ...and with the extension present, both real call sites pass file names:
  // a trailing hdr token must not be defeated by '.cube'.
  eq(context.meterMadvrParamsFromName('lut_hdr10.cube'), { gamut: 'bt2020', hdr: true });
  eq(context.meterMadvrParamsFromName('foo_pq.CUBE'), { gamut: 'bt2020', hdr: true });
  eq(context.meterMadvrParamsFromName('my_hdr10_bt2020_2.4.cube'), { gamut: 'bt2020', hdr: true });
  eq(context.meterMadvrParamsFromName('sdr_p3d65.cube'), { gamut: 'p3d65', hdr: false });
  // Gamut tokens are anchored like the hdr tokens: embedded inside a longer
  // token they must NOT set the target.
  eq(context.meterMadvrParamsFromName('notbt2020_tv'), { gamut: 'bt709', hdr: false });
  eq(context.meterMadvrParamsFromName('myx_p3d65z_y'), { gamut: 'bt709', hdr: false });
});

t('file size and header layout', () => {
  const bytes = context.meterCubeToMadvr(parsed, { gamut: 'bt709', hdr: false });
  assert.equal(bytes.constructor.name, 'Uint8Array', 'returns Uint8Array');
  const total = 16384 + 256 * 256 * 256 * 6 + 1552;
  assert.equal(bytes.length, total, 'total = header/LUT pad + 256^3*6 + cal1');
  const dv = new DataView(bytes.buffer);
  assert.equal(String.fromCharCode(bytes[0], bytes[1], bytes[2], bytes[3]), '3DLT');
  assert.equal(dv.getInt32(4, true), 1, 'file version 1');
  assert.equal(dv.getInt32(48, true), 8, 'input bit depth 8');
  assert.equal(dv.getInt32(64, true), 16, 'output bit depth 16');
  assert.equal(dv.getInt32(72, true), 512, 'parameters offset');
  assert.equal(dv.getInt32(80, true), 16384, 'LUT offset');
  assert.equal(dv.getInt32(84, true), 0, 'compression method none');
  const lutBytes = 256 * 256 * 256 * 6;
  assert.equal(dv.getInt32(88, true), lutBytes, 'compressed size');
  assert.equal(dv.getInt32(92, true), lutBytes, 'uncompressed size');
});

t('SDR parameter block', () => {
  const bytes = context.meterCubeToMadvr(parsed, { gamut: 'bt709', hdr: false, res: 17 });
  const size = new DataView(bytes.buffer).getInt32(76, true);
  const text = Buffer.from(bytes.subarray(512, 512 + size)).toString('latin1');
  assert.ok(text.endsWith('\0'), 'params NUL-terminated');
  const lines = text.replace(/\0$/, '').split('\r\n');
  assert.deepEqual(lines, [
    'Input_Primaries 0.64000 0.33000 0.30000 0.60000 0.15000 0.06000 0.31273 0.32902',
    'Input_Range 16 235',
    'Output_Range 16 235',
  ]);
});

t('HDR parameter block puts PQ transfer lines first (madvr.py order)', () => {
  const bytes = context.meterCubeToMadvr(parsed, { gamut: 'bt2020', hdr: true, res: 17 });
  const size = new DataView(bytes.buffer).getInt32(76, true);
  const text = Buffer.from(bytes.subarray(512, 512 + size)).toString('latin1');
  // Exact line list AND order: madvr.py's OrderedDict inserts the PQ lines
  // before Input_Primaries, so the serialized block must match byte-for-byte.
  assert.deepEqual(text.replace(/\0$/, '').split('\r\n'), [
    'Input_Transfer_Function PQ',
    'Output_Transfer_Function PQ',
    'Input_Primaries 0.70800 0.29200 0.17000 0.79700 0.13100 0.04600 0.31273 0.32902',
    'Input_Range 16 235',
    'Output_Range 16 235',
  ]);
});

t('LUT node order and values (BGR uint16 LE, blue fastest)', () => {
  const R = 33;
  const bytes = context.meterCubeToMadvr(parsed, { gamut: 'p3d65', hdr: false, res: R });
  const lut16 = new Uint16Array(bytes.buffer, 16384, R * R * R * 3);
  const nodeAt = (r, g, b) => ((r * R + g) * R + b) * 3;
  // Writer contract: node code i presents signal (i-16)/219, the ramp
  // fixture maps signal -> 0.25 + 0.5*clamp(signal), and results are
  // encoded (16 + 219*v) << 8. Every pin below is EXACT.
  const sig = (code) => (code - 16) / 219;
  const enc = (c) => Math.round((16 + 219 * (0.25 + 0.5 * Math.max(0, Math.min(1, sig(c))))) * 256);
  // Node (0,0,0): all signals clamp to 0 -> ramp black code on every channel.
  assert.deepEqual([lut16[0], lut16[1], lut16[2]], Array(3).fill(enc(16)), 'first node B,G,R = ramp(black)');
  assert.equal(enc(16), Math.round((16 + 219 * 0.25) * 256), 'ramp black = 0.25 as a video code <<8');
  // Walk is blue-fastest: (16,16,16) -> (16,16,17) moves only B (slot +0).
  const a = nodeAt(16, 16, 16), b17 = nodeAt(16, 16, 17);
  assert.deepEqual([lut16[b17], lut16[b17 + 1], lut16[b17 + 2]],
    [enc(17), lut16[a + 1], lut16[a + 2]], 'B is the fast axis');
  // Green is the middle axis: (16,16,16) -> (16,17,16) moves only G (slot +1).
  const g17 = nodeAt(16, 17, 16);
  assert.deepEqual([lut16[g17], lut16[g17 + 1], lut16[g17 + 2]],
    [lut16[a], enc(17), lut16[a + 2]], 'G is the middle axis');
  // Red is the slow axis: (16,16,16) -> (17,16,16) moves only R (slot +2).
  const r17 = nodeAt(17, 16, 16);
  assert.deepEqual([lut16[r17], lut16[r17 + 1], lut16[r17 + 2]],
    [lut16[a], lut16[a + 1], enc(17)], 'red is the slow axis');
  // Uniform signal -> uniform channels at the last node.
  const last = nodeAt(R - 1, R - 1, R - 1);
  assert.deepEqual([lut16[last], lut16[last + 1], lut16[last + 2]],
    Array(3).fill(enc(R - 1)), 'uniform signal -> uniform channels');
});

t('video-range fill: non-identity black offset round-trips under declared range', () => {
  // The reviewer-requested pin: a constant +0.01 offset (the class of
  // correction that silently mis-registers if the fill ignores the header's
  // 16 235 declaration). Real 256 lattice: the fix must hold at production
  // size, and a full-range fill reads back below black here.
  const off = 0.01;
  const bytes = context.meterCubeToMadvr(offsetParsed(5, off), { gamut: 'bt709', hdr: false });
  const lut16 = new Uint16Array(bytes.buffer, 16384, 256 * 256 * 256 * 3);
  const at = (r, g, b) => ((r * 256 + g) * 256 + b) * 3;
  // Absolute code at the declared black (node 16, signal 0): (16+219*0.01)<<8.
  assert.deepEqual([lut16[at(16, 16, 16)], lut16[at(16, 16, 16) + 1], lut16[at(16, 16, 16) + 2]],
    Array(3).fill(Math.round((16 + 219 * off) * 256)), 'black node = video code for 0.01, <<8');
  // Declared white (node 235) — exact up to 16-bit code quantization.
  assert.ok(Math.abs(decode(lut16[at(235, 235, 235)]) - off) <= 1e-5, 'white node decodes to the offset');
  // Readback under the DECLARED range must equal the intended 0.01 at every
  // sampled node — a full-range fill collapses this to near-zero (below black).
  for (const code of [0, 16, 64, 128, 200, 235, 255]) {
    const got = decode(lut16[at(code, code, code)]);
    assert.ok(Math.abs(got - off) <= 1 / 256 / 219 + 1e-9, `code ${code} decodes to ${off}, got ${got}`);
  }
});

t('domain mapping honors DOMAIN_MIN/MAX', () => {
  const R = 33;
  const p = rampParsed(3);
  // Domain sized to span the signal range the seam's node codes cover
  // ((0-16)/219 .. (32-16)/219), so every probe lands mid-domain instead of
  // clamping — the mapping, not the clamp, is what this pins.
  p.domainMin = [-0.08, -0.08, -0.08]; p.domainMax = [0.08, 0.08, 0.08];
  const bytes = context.meterCubeToMadvr(p, { gamut: 'bt709', hdr: false, res: R });
  const lut16 = new Uint16Array(bytes.buffer, 16384, R * R * R * 3);
  // Sample the B fast axis at fixed codes with r=g=16 (signal 0 on R/G).
  for (const code of [0, 8, 16, 24, 32]) {
    const s = (code - 16) / 219;
    const pos = Math.max(0, Math.min(1, (s + 0.08) / 0.16));
    const expect = 0.25 + 0.5 * pos; // ramp value at lattice pos*(S-1)
    const got = decode(lut16[((16 * R + 16) * R + code) * 3]);
    assert.ok(Math.abs(got - expect) <= 1e-4, `code ${code}: decode ${got} ~ ${expect}`);
  }
});

t('cal1 trailer is a linear full-range ramp', () => {
  const bytes = context.meterCubeToMadvr(parsed, { gamut: 'bt709', hdr: false, res: 17 });
  const c = bytes.length - 1552;
  assert.equal(String.fromCharCode(bytes[c], bytes[c + 1], bytes[c + 2], bytes[c + 3]), 'cal1');
  const dv = new DataView(bytes.buffer);
  assert.equal(dv.getInt32(c + 4, true), 1, 'cal1 version');
  assert.equal(dv.getInt32(c + 8, true), 256, 'entries');
  assert.equal(dv.getInt32(c + 12, true), 2, 'bytes per entry');
  const ramps = new Uint16Array(bytes.buffer, c + 16, 768);
  for (const ch of [0, 1, 2]) {
    assert.equal(ramps[ch * 256], 0, `ch${ch} black`);
    assert.equal(ramps[ch * 256 + 255], 65535, `ch${ch} white`);
    assert.equal(ramps[ch * 256 + 100], 25700, `ch${ch} linear mid`);
  }
});

t('bad input refused', () => {
  assert.equal(context.meterCubeToMadvr(null, {}), null);
  assert.equal(context.meterCubeToMadvr({ ok: false }, {}), null);
  assert.equal(context.meterCubeToMadvr({ ok: true, size: 2, values: 'nope' }, {}), null);
});


t('async fill: identical bytes to sync path, progress reaches 1', async () => {
  const p = rampParsed(3);
  const sync = context.meterCubeToMadvr(p, { gamut: 'bt709', hdr: false, res: 17 });
  const seen = [];
  const asyncBytes = await context.meterCubeToMadvrAsync(p, { gamut: 'bt709', hdr: false, res: 17 },
    (f) => { seen.push(f); });
  assert.deepEqual(Array.from(asyncBytes), Array.from(sync), 'async output byte-identical to sync');
  assert.ok(seen.length > 0, 'progress callback fired');
  assert.equal(seen[seen.length - 1], 1, 'final progress is 1');
  for (let i = 1; i < seen.length; i++) assert.ok(seen[i] > seen[i - 1], 'progress is strictly increasing');
});

t('async fill yields control back to the event loop', async () => {
  // The freeze fix only exists if the fill awaits a macrotask: a timer armed
  // before the conversion must fire DURING it, not after. A sync loop that
  // merely looks async (no await) would block the loop and fail here.
  const p = rampParsed(3);
  let fired = 0;
  const id = setTimeout(() => { fired++; }, 0);
  await context.meterCubeToMadvrAsync(p, { gamut: 'bt709', hdr: false, res: 33 });
  clearTimeout(id);
  assert.ok(fired > 0, 'event loop ran timers during the async fill');
});

t('solved-path HDR export is refused at the call site', () => {
  // Gate is structural: meterDownloadSolvedLutAs3dlut must bail on an
  // hdr-params name BEFORE the confirm modal / fetch, with a toast naming
  // the gamma-2.2 domain reason. Regex over the shipped source because the
  // caller needs fetch/toast/DOM (no vm sandbox for those).
  const fnSrc = extractBlock('meterDownloadSolvedLutAs3dlut', 'async function');
  const gate = fnSrc.search(/params\.hdr[\s\S]{0,400}?toast\([^)]*gamma-2\.2[\s\S]*?return;/);
  assert.ok(gate >= 0, 'hdr guard toasts the gamma-domain reason and returns');
  const modalAt = fnSrc.indexOf('meterShowChoiceModal');
  assert.ok(gate < modalAt, 'guard sits before the confirm modal (no HDR file can be produced)');
  // Exemption: icc_* cubes are PQ-domain by construction (icc_companion_lut
  // pq_linear), so the gamma-2.2 refusal must not gate on them.
  assert.ok(/params\.hdr\s*&&\s*!\s*meterMadvrIccMode\(\s*name\s*\)/.test(fnSrc), 'gate exempts ICC-converted HDR cubes');
});

t('ICC trailing mode token outranks the filename heuristic', () => {
  // An SDR ICC profile whose (user-controlled) stem carries dv/pq tokens
  // must NOT be treated as HDR; the trailing _<mode>_<unixtime> is the
  // authoritative token webui_icc_profile_to_cube writes.
  assert.equal(context.meterMadvrIccMode('icc_my_dv_profile_sdr_1760000000.cube'), 'sdr');
  assert.equal(context.meterMadvrIccMode('icc_p_hdr10_1760000000.CUBE'), 'hdr10', 'extension strip is case-insensitive');
  assert.equal(context.meterMadvrIccMode('solved_hdr10_method_gamut.cube'), null, 'non-ICC names get no ICC mode');
  assert.equal(context.meterMadvrIccMode('icc_no_mode_token.cube'), null, 'ICC name without the mode token falls back to the heuristic');
  assert.equal(context.meterMadvrParamsFromName('icc_my_dv_profile_sdr_1760000000.cube').hdr, false, 'dv in an SDR ICC stem no longer means HDR');
  assert.equal(context.meterMadvrParamsFromName('icc_p_HDR10_1760000000.CUBE').hdr, true, 'ICC hdr10 stays HDR');
  assert.equal(context.meterMadvrParamsFromName('lut_hdr10.cube').hdr, true, 'non-ICC heuristic unchanged');
});

t('ICC cubes get header gamut from the mode token, not the stem', () => {
  // icc_companion_lut.py source_xyz fixes the input space: hdr10 samples
  // BT.2020/PQ, sdr samples sRGB/Rec.709. A user-controlled profile stem
  // naming another gamut must not leak into the .3dlut header.
  // Every case runs (collect, not fail-fast): an earlier assertion throwing
  // must not mask the SDR-rung case — mutation-verified ordering trap.
  const bad = [];
  const check = (name, want) => {
    try {
      assert.equal(context.meterMadvrParamsFromName(name).gamut, want, `${name} -> ${want}`);
    } catch (e) { bad.push(e.message); }
  };
  check('icc_foo_p3d65_hdr10_1760000000.cube', 'bt2020');   // p3d65 stem cannot override BT.2020
  check('icc_foo_bt2020_sdr_1760000000.cube', 'bt709');     // bt2020 stem cannot override Rec.709
  check('icc_foo_p3dci_sdr_1760000000.cube', 'bt709');      // p3dci leak on the SDR rung
  check('icc_no_token_p3d65.cube', 'p3d65');                // no mode token: heuristic intact
  check('lut_p3d65_sdr.cube', 'p3d65');                     // non-ICC heuristic unchanged
  assert.deepEqual(bad, [], 'ICC gamut derivation matrix: ' + bad.join(' | '));
});

t('yield uses MessageChannel, not a timer (background-tab clamp free)', async () => {
  // Browsers clamp nested setTimeout (~4 ms, ~1/s in a background tab):
  // 2731 timer yields would stretch the export past 45 minutes once the
  // operator switches tabs. Behavior pin: with setTimeout sabotaged in the
  // sandbox the yield must still resolve — MessageChannel carries it.
  const realSetTimeout = context.setTimeout;
  context.setTimeout = function () { throw new Error('yield used a timer despite MessageChannel being available'); };
  try { await context.meterMadvrYield(); } finally { context.setTimeout = realSetTimeout; }
});

t('yield closes both MessageChannel ports after the tick', async () => {
  // Nit: an export creates ~2731 channels; ports left open pin the channel
  // (Node refuses to exit with open ports). Behavior pin via a tracking
  // wrapper: after the yield resolves, port1.close AND port2.close must
  // each have run.
  const real = context.MessageChannel;
  const closed = [];
  function TrackedChannel() {
    const ch = new real();
    for (const p of ['port1', 'port2']) {
      const orig = ch[p].close.bind(ch[p]);
      ch[p].close = () => { closed.push(p); orig(); };
    }
    return ch;
  }
  context.MessageChannel = TrackedChannel;
  try { await context.meterMadvrYield(); } finally { context.MessageChannel = real; }
  closed.sort();
  assert.deepEqual(closed, ['port1', 'port2'], 'both ports closed in the onmessage handler');
});

t('preview-path HDR confirm dialog carries the PQ-domain warning', () => {
  const fnSrc = extractBlock('meterDownloadPreviewedCubeAs3dlut', 'async function');
  assert.ok(/hdr[\s\S]{0,200}?PQ[\s\S]{0,300}?gamma-2\.2/.test(fnSrc), 'warn text keyed on hdr mentions PQ and gamma-2.2');
  assert.ok(fnSrc.indexOf('warn') < fnSrc.indexOf('meterShowChoiceModal'), 'warning is composed into the modal body');
});

t('solved download name strips .CUBE extension case-insensitively', () => {
  const fnSrc = extractBlock('meterDownloadSolvedLutAs3dlut', 'async function');
  assert.ok(fnSrc.indexOf('replace(/' + String.fromCharCode(92) + '.cube$/i') >= 0, 'extension strip uses /i like the sibling paths');
});

t('solved list disables .3dlut on refused rows', () => {
  // Nit: the refuse gate must be mirrored at render time — a blocked row
  // shows a disabled button naming the reason, not a live button that
  // toasts only after the click.
  const fnSrc = extractBlock('meterLoadSolvedLutList', 'async function');
  assert.ok(/madvrBlocked\s*=\s*meterMadvrParamsFromName\(name\)\.hdr\s*&&\s*!\s*meterMadvrIccMode\(name\)/.test(fnSrc), 'render mirrors the gate predicate exactly');
  assert.ok(/disabled[^]*?Not available: HDR auto-cal LUTs[^]*?\.3dlut<\/button>/.test(fnSrc), 'blocked row renders a disabled button with the reason in title');
});

t('madVR export retitles the progress modal and separates download errors', () => {
  // Nit: "Building 3D LUT" is wrong while writing a .3dlut, and a
  // meterDownloadBlob failure must not read as "conversion failed".
  const showSrc = extractBlock('meterLutSolveProgressShow', 'function');
  assert.ok(/String\(title\|\|'Building 3D LUT'\)/.test(showSrc), 'title param defaults to the solve wording');
  for (const fn of ['meterDownloadSolvedLutAs3dlut', 'meterDownloadPreviewedCubeAs3dlut']) {
    const fnSrc = extractBlock(fn, 'async function');
    assert.ok(fnSrc.indexOf("'Writing madVR .3dlut')") > 0, fn + ' passes the export title');
    assert.ok(/meterDownloadBlob[\s\S]{0,200}?catch[\s\S]{0,80}?download failed/.test(fnSrc), fn + ' reports download failure separately');
  }
});

runAll().then(() => {
  let failed = 0;
  for (const [label, ok, err] of results) {
    if (!ok) failed++;
    console.log(`${ok ? 'ok' : 'FAIL'} ${label}${ok ? '' : ' — ' + err}`);
  }
  console.log(JSON.stringify({ pass: results.length - failed, fail: failed }));
  process.exit(failed ? 1 : 0);
});
