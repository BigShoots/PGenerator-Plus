#!/usr/bin/env node
'use strict';

const assert = require('assert');
const childProcess = require('child_process');
const fs = require('fs');
const path = require('path');
const { ChcParseError, parseHcfrChc } = require('../usr/share/PGenerator/hcfr_chc.js');

const root = path.resolve(__dirname, '..');
const fixture = name => fs.readFileSync(path.join(root, 'HCFR CHC', name));
const fixtureExists = name => fs.existsSync(path.join(root, 'HCFR CHC', name));

function u32(value) {
  const out = Buffer.alloc(4);
  out.writeUInt32LE(value);
  return out;
}

function f64(value) {
  const out = Buffer.alloc(8);
  out.writeDoubleLE(value);
  return out;
}

function matrix(values) {
  const rows = values.length;
  const columns = values[0].length;
  const data = [];
  for (let column = 0; column < columns; column++) {
    for (let row = 0; row < rows; row++) data.push(f64(values[row][column]));
  }
  return Buffer.concat([Buffer.from('taMCCxir'), u32(1), u32(columns), u32(rows), ...data]);
}

function color(X, Y, Z) {
  const identity = matrix([[1, 0, 0], [0, 1, 0], [0, 0, 1]]);
  return Buffer.concat([u32(1), matrix([[X], [Y], [Z]]), identity, identity]);
}

function minimalChc() {
  const invalid = color(-99999.99, -99999.99, -99999.99);
  return Buffer.concat([
    Buffer.from('COLORHCF'), u32(3), u32(1),
    u32(1), color(1, 2, 3),
    u32(0),
    invalid, invalid, invalid, invalid, invalid, invalid,
    invalid, invalid, invalid, invalid,
    Buffer.from([0])
  ]);
}

const synthetic = parseHcfrChc(minimalChc());
assert.strictEqual(synthetic.measurementVersion, 1);
assert.strictEqual(synthetic.groups.grayscale.validItems.length, 1);
assert.deepStrictEqual(
  [synthetic.groups.grayscale.items[0].X, synthetic.groups.grayscale.items[0].Y, synthetic.groups.grayscale.items[0].Z],
  [1, 2, 3]
);
assert.strictEqual(synthetic.validMeasurementCount, 1);
assert.strictEqual(synthetic.trailingObjectBytes, 0);

if (fixtureExists('Angryht blu/5-27-08 3.chc')) {
const legacy = parseHcfrChc(fixture('Angryht blu/5-27-08 3.chc'));
assert.strictEqual(legacy.fileVersion, 3);
assert.strictEqual(legacy.measurementVersion, 6);
assert.strictEqual(legacy.groups.grayscale.declaredCount, 11);
assert.strictEqual(legacy.groups.grayscale.validItems.length, 11);
assert.strictEqual(legacy.groups.redSaturation.declaredCount, 5);
assert.strictEqual(legacy.fixed.redPrimary.valid, true);
assert.strictEqual(legacy.fixed.onOffWhite.valid, true);
assert.ok(Math.abs(legacy.groups.grayscale.items[10].Y - 28.726144790649414) < 1e-10);
assert.ok(legacy.notes.includes('Panasonic DMP BD30'));
assert.ok(legacy.trailingObjectBytes > 0);
}

if (fixtureExists('Angryht blu/5-27-08 3 REFERENCE.chc')) {
const reference = parseHcfrChc(fixture('Angryht blu/5-27-08 3 REFERENCE.chc'));
assert.strictEqual(reference.groups.grayscale.validItems.length, 0);
assert.strictEqual(reference.fixed.redPrimary.valid, false);
assert.strictEqual(reference.fixed.yellowSecondary.valid, true);
}

if (fixtureExists('Bright Cinema HDR.chc')) {
const modern = parseHcfrChc(fixture('Bright Cinema HDR.chc'));
assert.strictEqual(modern.fileVersion, 3);
assert.strictEqual(modern.measurementVersion, 17);
assert.ok(modern.validMeasurementCount > 0);
assert.ok(modern.groups.grayscale.declaredCount > 0);
assert.strictEqual(modern.preferences.masterMaxLuminance, 4000);
assert.strictEqual(modern.preferences.targetMaxLuminance, 164.09);
assert.strictEqual(modern.groups.colorChecker.validItems.length, 24);
assert.strictEqual(modern.groups.freeMeasurements.validItems.length, 1811);
assert.ok(modern.trailingObjectBytes > 0);
}

assert.throws(() => parseHcfrChc(Buffer.from('not a chc file')), ChcParseError);
const corrupt = Buffer.from(minimalChc());
corrupt.writeUInt32LE(0xffffffff, 16);
assert.throws(() => parseHcfrChc(corrupt), /safety limit/);

if (fixtureExists('Bright Cinema HDR.chc')) {
  const cli = path.join(root, 'tools/parse_hcfr_chc.js');
  const modernPath = path.join(root, 'HCFR CHC/Bright Cinema HDR.chc');
  const fullOutput = JSON.parse(childProcess.execFileSync(process.execPath, [cli, '--full', modernPath], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 }));
  assert.strictEqual(fullOutput.groups.grayscale.items.length, 21);
  assert.strictEqual(typeof fullOutput.groups.grayscale.items[0].X, 'number');
  const summaryOutput = JSON.parse(childProcess.execFileSync(process.execPath, [cli, '--summary', modernPath], { encoding: 'utf8' }));
  assert.strictEqual(summaryOutput.groups.grayscale.valid, 21);
  assert.strictEqual(summaryOutput.groups.grayscale.items, undefined);
}

process.stdout.write('HCFR CHC parser regression tests passed\n');
