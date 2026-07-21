'use strict';

const assert = require('assert');
const {
  parseHcfrChc,
  serializeHcfrChc
} = require('../usr/share/PGenerator/hcfr_chc.js');

const color = (n) => ({ X: n + 0.1, Y: n + 0.2, Z: n + 0.3 });
const bytes = serializeHcfrChc({
  preferences: {
    colorStandard: 8,
    gammaOffsetType: 5,
    masterMinLuminance: 0.001,
    masterMaxLuminance: 4000,
    targetMaxLuminance: 800,
    contentMaxLuminance: 1000,
    frameAverageMaxLuminance: 400,
    useToneMap: true,
    diffuseLuminance: 100,
    manualWhiteX: 0.3127,
    manualWhiteY: 0.329
  },
  groups: {
    grayscale: [color(1), color(2), color(3)],
    redSaturation: [null, color(4), color(5), color(6), color(7)],
    colorChecker: { declaredCount: 1000, items: [{ ...color(8), index: 0 }, { ...color(9), index: 23 }] },
    colorCheckerMaster: { declaredCount: 5000, items: [] },
    freeMeasurements: [color(10)]
  },
  fixed: {
    redPrimary: color(11), onOffBlack: color(0), onOffWhite: color(12), primeWhite: color(12)
  },
  notes: 'Calibration by: \r\nDisplay: Test\r\nNote: PGenerator € — unsupported snowman becomes ? ☃\r\n'
});

const parsed = parseHcfrChc(bytes);
assert.strictEqual(parsed.fileVersion, 3);
assert.strictEqual(parsed.measurementVersion, 17);
assert.strictEqual(parsed.groups.grayscale.validItems.length, 3);
assert.strictEqual(parsed.groups.redSaturation.validItems.length, 4);
assert.deepStrictEqual(parsed.groups.colorChecker.items.map(x => x.index), [0, 23]);
assert.strictEqual(parsed.groups.colorCheckerMaster.items.length, 0);
assert.strictEqual(parsed.groups.freeMeasurements.validItems.length, 1);
assert.strictEqual(parsed.fixed.redPrimary.X, 11.1);
assert.strictEqual(parsed.fixed.ansiWhite.valid, false);
assert.strictEqual(parsed.preferences.gammaOffsetType, 5);
assert.strictEqual(parsed.preferences.useToneMap, true);
assert(parsed.notes.includes('€'));
assert(parsed.notes.includes('?'));
assert.strictEqual(parsed.trailingObjectBytes, 487);
assert.strictEqual(parsed.measurementEndOffset + parsed.trailingObjectBytes, bytes.length);

assert.throws(() => serializeHcfrChc({
  groups: { colorChecker: { declaredCount: 10, items: [{ ...color(1), index: 10 }] } }
}), /outside declared array/);

console.log('HCFR CHC writer regression tests passed');
