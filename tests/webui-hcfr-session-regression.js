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
assert(source.includes('colorCheckerMode:0'), 'PGenerator ColorChecker must advertise HCFR Classic GCD mode');
assert(source.includes('{...colors[1],index:0},{...colors[0],index:5}'), 'ColorChecker black and white are not mapped to GCD slots');
assert(source.includes("colors.slice(6,24).forEach((rd,offset)=>colorCheckerItems.push({...rd,index:offset+6}))"), 'ColorChecker chromatic patches are not mapped to GCD slots');
assert(source.includes('free.push(...colors.slice(2,6))'), 'incompatible PGenerator neutral patches must be preserved as free measurements');
assert(source.includes('HCFR Sat Sweep'), 'HCFR-compatible constant-luminance saturation series is missing');
assert(source.includes('HCFR ColorChecker'), 'HCFR-compatible GCD ColorChecker series is missing');
assert(source.includes("['Dark Skin',45.20,31.96,26.03]"), 'client HCFR GCD Dark Skin stimulus is not exact');
assert(source.includes('["Dark Skin","hcfr_rgb",45.20,31.96,26.03]'), 'server HCFR GCD Dark Skin stimulus is not exact');
assert(source.includes('id="meterHcfrFixedCodes"'), 'normal built-in series controls need the HCFR fixed-code checkbox');
assert(source.includes("meterSelectSeries('colors',meterHcfrFixedCodesEnabled()?29:30)"), 'ColorChecker button must select the checkbox-backed variant');
assert(source.includes("meterSelectSeries('saturations',meterHcfrFixedCodesEnabled()?25:24)"), 'Sat Sweep button must select the checkbox-backed variant');
assert(source.includes("localStorage.setItem(METER_HCFR_FIXED_CODES_KEY,checked?'1':'0')"), 'HCFR fixed-code preference must persist');
assert(source.includes("Number(e.snap.points)===(preferHcfr?29:30)"), 'CHC export must follow the ColorChecker checkbox variant');
assert(source.includes("Number(e.snap.points)===(preferHcfr?25:24)"), 'CHC export must follow the saturation checkbox variant');
assert(source.includes("generator:{type:'gdi',rgbRange:rgbRange}"), 'CHC export must serialize the active RGB range');
assert(source.includes("source_rgb_range:sourceRange||null"), 'CHC import must preserve the source generator range');
assert(source.includes('Output range will NOT be changed'), 'CHC import must disclose that generator range is not applied');
assert(source.includes("source_format:'hcfr-chc'"), 'imported snapshots must retain their source format');
assert(source.includes('if(meterSeriesSnapshotIsImported(snap)) return'), 'imported CHC snapshots must not feed native grayscale cache recovery');
assert(source.includes('exact.readings.some(meterSeriesReadingIsImported)'), 'native snapshots must remove previously merged imported readings');
assert(source.includes('function meterScheduleSeriesCachePersist()'), 'series cache persistence must support deferred writes');
assert(source.includes("meterCacheSeriesState(meterSeriesRunning?'running':'complete',{deferPersist:true})"), 'series switching must not synchronously persist the entire cache');
assert(source.includes('_defer_cache_persist:true'), 'cached restore must coalesce its persistence write');
assert(source.includes("output settings will NOT be changed or restarted"), 'import preview must disclose output behavior');

console.log('webui HCFR Session workspace regression OK');
