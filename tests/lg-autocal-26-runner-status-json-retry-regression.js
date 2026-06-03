const assert = require('assert');
const fs = require('fs');

const source = fs.readFileSync('tools/lg-autocal-26-runner.js', 'utf8');

function sliceBetween(startNeedle, endNeedle, from = 0) {
  const start = source.indexOf(startNeedle, from);
  assert(start >= 0, `Missing start marker: ${startNeedle}`);
  const end = source.indexOf(endNeedle, start + startNeedle.length);
  assert(end > start, `Missing end marker after: ${startNeedle}`);
  return source.slice(start, end);
}

const apiSource = sliceBetween(
  'async function api(endpoint, options = {})',
  'function xyToUvPrime'
);
assert(
  apiSource.includes('error.nonJson = true;') &&
    apiSource.includes('error.endpoint = endpoint;') &&
    apiSource.includes('error.responseText = text;') &&
    apiSource.includes('throw error;'),
  'runner API helper should tag malformed JSON responses so status polling can retry only parse failures'
);

const pollSource = sliceBetween(
  'async function pollStatus(endpoint, outName, label)',
  'async function main()'
);
assert(
  source.includes("const malformedStatusJsonRetries = Number(process.env.PGEN_STATUS_JSON_RETRIES || '3');") &&
    pollSource.includes('const maxMalformedRetries = Number.isFinite(malformedStatusJsonRetries) && malformedStatusJsonRetries >= 0') &&
    pollSource.includes('let malformedRetries = 0;') &&
    pollSource.includes('status = await api(endpoint, { timeoutMs: 30000 });') &&
    pollSource.includes('malformedRetries = 0;') &&
    pollSource.includes('!error.nonJson || malformedRetries >= maxMalformedRetries') &&
    pollSource.includes('malformed status JSON from ${endpoint}; retry ${malformedRetries}/${maxMalformedRetries}') &&
    pollSource.includes('await sleep(1000);') &&
    pollSource.includes('continue;'),
  'status poller should retry malformed JSON a bounded number of times, log each retry, reset after success, and keep repeated failures fatal'
);

console.log('LG AutoCal 26 runner malformed status JSON retry regression checks passed.');
