#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const parser = require(path.resolve(__dirname, '../usr/share/PGenerator/hcfr_chc.js'));

const args = process.argv.slice(2);
const full = args.includes('--full');
const positional = args.filter(arg => arg !== '--full' && arg !== '--summary');

if (positional.length !== 1 || (full && args.includes('--summary'))) {
  process.stderr.write('Usage: parse_hcfr_chc.js [--summary|--full] FILE.chc\n');
  process.stderr.write('  --summary  Print group counts and session metadata (default)\n');
  process.stderr.write('  --full     Print every parsed measurement, including XYZ, xyY, spectrum and lux data\n');
  process.exit(2);
}

try {
  const input = fs.readFileSync(positional[0]);
  const parsed = parser.parseHcfrChc(input);
  process.stdout.write(JSON.stringify(full ? parsed : parser.summarizeHcfrChc(parsed), null, 2) + '\n');
} catch (error) {
  process.stderr.write((error && error.message ? error.message : String(error)) + '\n');
  process.exit(1);
}
