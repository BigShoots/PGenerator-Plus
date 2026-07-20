#!/usr/bin/env node
'use strict';

const fs = require('fs');
const vm = require('vm');
const assert = require('assert');

const source = fs.readFileSync('usr/share/PGenerator/webui.pm', 'utf8');

function extractFunction(name) {
  const token = `function ${name}(`;
  const start = source.indexOf(token);
  assert(start >= 0, `Missing function ${name}`);
  let i = source.indexOf('{', start);
  let depth = 0;
  for (; i < source.length; i++) {
    if (source[i] === '{') depth++;
    else if (source[i] === '}' && --depth === 0) return source.slice(start, i + 1);
  }
  throw new Error(`Failed to extract ${name}`);
}

const bodyClasses = new Set();
const context = {
  document: { body: { classList: { contains: name => bodyClasses.has(name) } } },
  meterActiveSeriesType: 'colors'
};
vm.createContext(context);
['meterSeriesThumbWidth', 'meterSeriesThumbContentWidth', 'meterDesktopColorThumbsFit']
  .forEach(name => vm.runInContext(extractFunction(name), context));

const shortSeries = Array.from({ length: 30 }, (_, i) => ({ name: `Patch ${i}` }));
const longSeries = Array.from({ length: 125 }, (_, i) => ({ name: `Patch ${i}` }));

bodyClasses.add('layout-desktop');
context.shortSeries = shortSeries;
context.longSeries = longSeries;
assert.strictEqual(vm.runInContext('meterDesktopColorThumbsFit(shortSeries,{clientWidth:1800})', context), true,
  'short desktop colour series flex to fill a wide row');
assert.strictEqual(vm.runInContext('meterDesktopColorThumbsFit(longSeries,{clientWidth:1800})', context), false,
  'long desktop colour series retain fixed-width scrolling');

bodyClasses.delete('layout-desktop');
assert.strictEqual(vm.runInContext('meterDesktopColorThumbsFit(shortSeries,{clientWidth:1800})', context), false,
  'tablet colour-series behavior is unchanged');

context.meterActiveSeriesType = 'greyscale';
bodyClasses.add('layout-desktop');
assert.strictEqual(vm.runInContext('meterDesktopColorThumbsFit(shortSeries,{clientWidth:1800})', context), false,
  'greyscale sizing remains controlled by its existing path');

const build = extractFunction('meterBuildPatchThumbs');
assert(build.includes('if(scrollMode&&meterDesktopColorThumbsFit(visibleSteps,row)) scrollMode=false;'),
  'thumbnail builder applies the desktop fit decision before constructing children');

console.log('color thumbnail desktop fit regression OK');
