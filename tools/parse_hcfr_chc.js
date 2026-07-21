#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const parser = require(path.resolve(__dirname, '../usr/share/PGenerator/hcfr_chc.js'));

if (process.argv.length !== 3) {
  process.stderr.write('Usage: parse_hcfr_chc.js FILE.chc\n');
  process.exit(2);
}

try {
  const input = fs.readFileSync(process.argv[2]);
  const parsed = parser.parseHcfrChc(input);
  process.stdout.write(JSON.stringify(parser.summarizeHcfrChc(parsed), null, 2) + '\n');
} catch (error) {
  process.stderr.write((error && error.message ? error.message : String(error)) + '\n');
  process.exit(1);
}
