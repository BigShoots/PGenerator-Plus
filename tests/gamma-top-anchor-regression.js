const fs = require('fs');
const vm = require('vm');
const assert = require('assert');

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

const code = [
  extractFunction('meterReadingPlotIre'),
  extractFunction('meterStepNameKey'),
  extractFunction('effectiveGamma'),
  extractFunction('effectiveGammaTopSlope'),
  extractFunction('meterGammaPreviousSeriesReading')
].join('\n\n');

const context = { Math, Number, isFinite };
vm.createContext(context);
vm.runInContext(code, context);

const steps = [0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75, 80, 85, 90, 95, 100]
  .map(ire => ({ ire, name: `${ire}%`, r: ire, g: ire, b: ire }));

const white = { ire: 100, name: '100%', luminance: 100 };
let readingMap = {
  45: { ire: 45, name: '45%', luminance: 14.8 },
  100: white
};

assert.strictEqual(
  context.meterGammaPreviousSeriesReading(white, steps, readingMap),
  null,
  '100% gamma must not anchor to a non-adjacent measured point during a partial scan'
);

readingMap = {
  ...readingMap,
  95: { ire: 95, name: '95%', luminance: 88.4 }
};

assert.strictEqual(
  context.meterGammaPreviousSeriesReading(white, steps, readingMap),
  readingMap[95],
  '100% gamma should anchor to the adjacent 95% point once it is measured'
);

assert.strictEqual(
  context.effectiveGamma(100, 100, 100, null, null),
  null,
  '100% gamma without an adjacent lower anchor should be omitted'
);

assert(
  context.effectiveGammaTopSlope(100, 100, 100, 88.4, 95) > 0,
  '100% top segment gamma should still be computable after the adjacent lower point is measured'
);

console.log('Gamma top-anchor regression checks passed.');
