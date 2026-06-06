#!/usr/bin/env node
'use strict';

const fs = require('fs');
const assert = require('assert');

const source = fs.readFileSync('usr/share/PGenerator/webui.pm', 'utf8');
const start = source.indexOf('function showColorReadingDetail(rd,opts)');
assert(start >= 0, 'color detail renderer exists');
const end = source.indexOf('function colorHighlightThumb', start);
assert(end > start, 'color detail renderer end marker exists');
const renderer = source.slice(start, end);

assert(renderer.includes('>Target x<'), 'color detail should label target x');
assert(renderer.includes('>Target y<'), 'color detail should label target y');
assert(renderer.includes('>Target Y<'), 'color detail should label target Y');
assert(renderer.includes('>Measured x<'), 'color detail should label measured x');
assert(renderer.includes('>Measured y<'), 'color detail should label measured y');
assert(renderer.includes('>Measured Y<'), 'color detail should label measured Y');
assert(!renderer.includes('>Meas. x<'), 'color detail should not abbreviate measured x');
assert(!renderer.includes('>Meas. y<'), 'color detail should not abbreviate measured y');

console.log('WebUI color detail labels regression passed.');
