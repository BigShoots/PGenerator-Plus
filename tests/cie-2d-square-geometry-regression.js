'use strict';

const assert = require('assert');
const fs = require('fs');
const vm = require('vm');

const source = fs.readFileSync('usr/share/PGenerator/webui.pm', 'utf8');
function extractFunction(name) {
  const start = source.indexOf(`function ${name}(`);
  assert(start >= 0, `missing ${name}`);
  let i = source.indexOf('{', start), depth = 0;
  for (; i < source.length; i++) {
    if (source[i] === '{') depth++;
    else if (source[i] === '}' && --depth === 0) return source.slice(start, i + 1);
  }
  throw new Error(`unterminated ${name}`);
}

const ctx = {};
vm.createContext(ctx);
vm.runInContext(`
 const CIE2D_WORLD={xMin:0,xMax:0.9,yMin:0,yMax:0.9};
 const CIE2D_SCALE_MIN=1,CIE2D_SCALE_MAX=25;
 let _cie2d={scale:1,panX:0,panY:0};
 ${extractFunction('meterCie2dViewport')}
 ${extractFunction('meterCie2dGeom')}
`, ctx);

for (const [width, height] of [[600,450],[420,600],[1200,760]]) {
  const geom = vm.runInContext(`meterCie2dGeom(${width},${height})`, ctx);
  assert(Math.abs(geom.w - geom.h) < 1e-9, `plot is not square at ${width}x${height}`);
  assert(Math.abs((geom.toX(0.6)-geom.toX(0.5))-(geom.toY(0.5)-geom.toY(0.6))) < 1e-9,
    `x/y unit scales differ at ${width}x${height}`);
}

console.log('CIE 2D square geometry regression OK');
