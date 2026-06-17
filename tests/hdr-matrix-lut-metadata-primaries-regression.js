const assert = require('assert');
const fs = require('fs');
const vm = require('vm');

const source = fs.readFileSync('usr/share/PGenerator/webui.pm', 'utf8');

function extractFunction(name) {
  const token = `function ${name}(`;
  const start = source.indexOf(token);
  if (start < 0) throw new Error(`Missing function ${name}`);
  let i = source.indexOf('{', start);
  let depth = 0;
  for (; i < source.length; i++) {
    const ch = source[i];
    if (ch === '{') depth++;
    else if (ch === '}') { depth--; if (depth === 0) return source.slice(start, i + 1); }
  }
  throw new Error(`Failed to extract function ${name}`);
}

const elements = { signal_mode: { value: 'sdr' }, meterTargetGamut: { value: '' }, primaries: { value: '2' } };
const context = { document: { getElementById(id){ return elements[id] || null; } } };
context.window = context;
vm.createContext(context);
vm.runInContext([
  extractFunction('meterDefaultTargetGamutForMode'),
  extractFunction('meterHdrMetadataGamut'),
].join('\n'), context);

// The HDR metadata gamut follows the Primaries config; defaults to P3/D65.
elements.primaries.value = '2'; assert.strictEqual(context.meterHdrMetadataGamut(), 'p3d65', 'primaries=2 -> P3/D65');
elements.primaries.value = '3'; assert.strictEqual(context.meterHdrMetadataGamut(), 'p3dci', 'primaries=3 -> P3/DCI');
elements.primaries.value = '1'; assert.strictEqual(context.meterHdrMetadataGamut(), 'bt2020', 'primaries=1 -> BT.2020');
elements.primaries.value = '0'; assert.strictEqual(context.meterHdrMetadataGamut(), 'bt709', 'primaries=0 -> custom/BT.709');
elements.primaries.value = ''; assert.strictEqual(context.meterHdrMetadataGamut(), 'p3d65', 'unset -> P3/D65 default');

// The CIE-chart container is decoupled: still BT.2020 for HDR regardless of primaries.
const elDoc = { signal_mode: { value: 'hdr10' } };
const cctx = { document: { getElementById(id){ return elDoc[id] || null; } } }; cctx.window = cctx;
vm.createContext(cctx);
vm.runInContext(extractFunction('meterDefaultTargetGamutForMode'), cctx);
assert.strictEqual(cctx.meterDefaultTargetGamutForMode(), 'bt2020', 'chart container stays BT.2020 for HDR');

// The 3D-LUT AutoCal payload line uses the metadata gamut for HDR10, not a hardcoded bt2020.
assert(
  source.includes("const targetGamut=signalMode==='hdr10'?meterHdrMetadataGamut():(fullWorkflow?'bt709':meterAutoCalTargetGamutValue());"),
  '3D-LUT AutoCal target_gamut uses meterHdrMetadataGamut() for HDR10 (SDR branch unchanged)'
);
console.log('hdr matrix-lut metadata primaries regression OK');
