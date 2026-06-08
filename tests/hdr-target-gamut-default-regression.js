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
    else if (ch === '}') {
      depth--;
      if (depth === 0) return source.slice(start, i + 1);
    }
  }
  throw new Error(`Failed to extract function ${name}`);
}

const elements = {
  signal_mode: { value: 'sdr' },
  meterTargetGamut: { value: '' }
};

const context = {
  document: {
    getElementById(id) {
      return elements[id] || null;
    }
  }
};
context.window = context;

vm.createContext(context);
vm.runInContext([
  extractFunction('meterDefaultTargetGamutForMode'),
  extractFunction('applyMeterTargetGamutDefault')
].join('\n'), context);

elements.signal_mode.value = 'sdr';
assert.strictEqual(context.meterDefaultTargetGamutForMode(), 'bt709', 'SDR should default Target Colorspace to BT.709');

elements.signal_mode.value = 'hdr10';
assert.strictEqual(context.meterDefaultTargetGamutForMode(), 'bt2020', 'HDR10 should default Target Colorspace to BT.2020');

elements.signal_mode.value = 'hlg';
assert.strictEqual(context.meterDefaultTargetGamutForMode(), 'bt2020', 'HLG should default Target Colorspace to BT.2020');

elements.signal_mode.value = 'dv';
assert.strictEqual(context.meterDefaultTargetGamutForMode(), 'p3d65', 'DV should default Target Colorspace to DCI-P3 / D65');

elements.signal_mode.value = 'hdr10';
elements.meterTargetGamut.value = 'p3d65';
context.applyMeterTargetGamutDefault(true);
assert.strictEqual(elements.meterTargetGamut.value, 'bt2020', 'forced HDR10 signal-mode change should select BT.2020');

elements.signal_mode.value = 'sdr';
elements.meterTargetGamut.value = '';
context.applyMeterTargetGamutDefault(false);
assert.strictEqual(elements.meterTargetGamut.value, 'bt709', 'empty SDR Target Colorspace should default to BT.709');

console.log('HDR target gamut default regression checks passed.');
