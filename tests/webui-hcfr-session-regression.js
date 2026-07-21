'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');

const source = fs.readFileSync(path.join(__dirname, '../usr/share/PGenerator/webui.pm'), 'utf8');

assert(source.includes('elsif($path eq "/assets/hcfr_chc.js")'), 'CHC browser module route is missing');
assert(source.includes('<script src="/assets/hcfr_chc.js"></script>'), 'CHC browser module is not loaded');
assert(source.includes('data-workspace-target="session"'), 'desktop Session workspace navigation is missing');
assert(source.includes('id="sessionCard"') && source.includes('data-desktop-workspace="session"'), 'Session workspace card is missing');
assert(/id="sessionCard"[^>]*class="card"/.test(source) || /class="card"[^>]*id="sessionCard"/.test(source), 'tablet Session card must be half-width, not span2');
assert(source.includes('function meterExportHcfrChc()'), 'CHC export action is missing');
assert(source.includes('async function meterImportHcfrChcFile(input)'), 'CHC import action is missing');
assert(source.includes("String(snap.signal_mode||mode).toLowerCase()===mode"), 'export must filter snapshots by active signal mode');
assert(source.includes("source_format:'hcfr-chc'"), 'imported snapshots must retain their source format');
assert(source.includes("output settings will NOT be changed or restarted"), 'import preview must disclose output behavior');

console.log('webui HCFR Session workspace regression OK');
