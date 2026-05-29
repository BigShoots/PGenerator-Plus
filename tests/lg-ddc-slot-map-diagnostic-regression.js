const assert = require('assert');
const fs = require('fs');

const source = fs.readFileSync('tools/lg-ddc-slot-map-diagnostic.js', 'utf8');

const channelMapStart = source.indexOf('const channelKey = {');
const channelMapEnd = source.indexOf('}[channel] ||', channelMapStart);
assert(channelMapStart >= 0 && channelMapEnd > channelMapStart, 'channel alias map should exist');
const channelMapSource = source.slice(channelMapStart, channelMapEnd);

assert(
  channelMapSource.includes("red: 'whiteBalanceRed'") &&
    channelMapSource.includes("green: 'whiteBalanceGreen'") &&
    channelMapSource.includes("blue: 'whiteBalanceBlue'"),
  'RGB channel aliases should remain supported'
);
assert(
  channelMapSource.includes("lum: 'adjustingLuminance'") &&
    channelMapSource.includes("luma: 'adjustingLuminance'") &&
    channelMapSource.includes("luminance: 'adjustingLuminance'") &&
    channelMapSource.includes("y: 'adjustingLuminance'"),
  'luminance channel aliases should target adjustingLuminance instead of falling through to red'
);

assert(
  source.includes('const before = Number(arrays[channelKey][idx]) || 0;') &&
    source.includes('arrays[channelKey][idx] = after;') &&
    source.includes('changed_channel: channelKey'),
  'slot probe should apply the selected channel key generically for RGB and luminance'
);
assert(
  source.includes('adjustingLuminance: normalizeArray(restorePicture.adjustingLuminance)') &&
    source.includes('adjustingLuminance: arrays.adjustingLuminance') &&
    source.includes("'adjustingLuminance'"),
  'diagnostic should preserve, write, and restore adjustingLuminance arrays'
);

console.log('LG DDC slot map diagnostic channel regression OK');
