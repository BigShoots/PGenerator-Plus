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
assert(source.includes("const session=document.getElementById('sessionCard')") && source.includes("const update=document.getElementById('updateCard')"), 'tablet default ordering does not identify Session and Software Update');
assert(source.includes('dash.insertBefore(uiSettings,anchor)') && source.includes('dash.insertBefore(session,anchor)'), 'Session and UI Settings are not placed together above Software Update');
assert(/onclick="meterExportHcfrChc\(\)">Export<\/button>/.test(source), 'simple Session export button is missing');
assert(/onclick="meterOpenHcfrImport\(\)">Import<\/button>/.test(source), 'simple Session import button is missing');
assert(source.includes('aria-label="HCFR session export help"') && source.includes('aria-label="HCFR session import help"'), 'Session button help tooltips are missing');
assert(source.includes('function meterExportHcfrChc()'), 'CHC export action is missing');
assert(source.includes('async function meterImportHcfrChcFile(input)'), 'CHC import action is missing');
assert(source.includes("String(snap.signal_mode||mode).toLowerCase()===mode"), 'export must filter snapshots by active signal mode');
assert(source.includes("fixed.primeWhite=meterHcfrScaleXyz(white,chromaWhiteScale)||white"), 'HCFR prime white must match the chroma stimulus luminance');
assert(source.includes("colorCheckerMaster:{declaredCount:5000,items:colorCheckerItems.map"), 'ColorChecker master collection must mirror exported measurements');
assert(source.includes('colorCheckerMode:1'), 'PGenerator ColorChecker must advertise HCFR Classic MCD mode');
assert(source.includes('colors.slice(6,24).map((rd,index)=>({...rd,index}))'), 'ColorChecker chromatic patches are not mapped to MCD slots');
assert(source.includes('[[5,19],[4,20],[3,21],[2,22]]'), 'compatible ColorChecker neutral patches are not mapped to MCD slots');
assert(source.includes('HCFR saturation references are constant luminance'), 'export preview must disclose incompatible saturation reference semantics');
assert(source.includes("source_format:'hcfr-chc'"), 'imported snapshots must retain their source format');
assert(source.includes("output settings will NOT be changed or restarted"), 'import preview must disclose output behavior');

console.log('webui HCFR Session workspace regression OK');
