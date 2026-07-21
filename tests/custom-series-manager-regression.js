// Locks the manager-window rework: per-tab "+ Custom" buttons and per-series
// edit pencils are gone; a right-aligned manager button exists; custom series
// selection buttons carry the btn-custom-series class; delete is id-based and
// shared; export-by-id expands lattice series.
const assert = require('assert');
const fs = require('fs');
const vm = require('vm');
const source = fs.readFileSync('usr/share/PGenerator/webui.pm', 'utf8');
function extractFunction(name) {
  const token = `function ${name}(`;
  const start = source.indexOf(token);
  assert(start >= 0, `Missing function ${name}`);
  let i = source.indexOf('{', start); let depth = 0;
  for (; i < source.length; i++) { const ch = source[i];
    if (ch === '{') depth++;
    else if (ch === '}') { depth--; if (depth === 0) return source.slice(start, i + 1); } }
  throw new Error(`Failed to extract ${name}`);
}
// markup assertions
assert(!/meterOpenCustomSeriesEditor\('greyscale'\)"[^>]*>\+ Custom/.test(source), 'greyscale + Custom button removed');
assert(!/meterOpenCustomSeriesEditor\('color'\)"[^>]*>\+ Custom/.test(source), 'color + Custom button removed');
// The manager opens from the per-group Custom… buttons (last in each series
// group); every manager row has a Load button that closes the popout and
// loads the series into the charts.
assert(!/meterCustomSeriesManagerBtn/.test(source), 'top-right manager button retired');
assert(/meterCustomSeriesBtnGrey/.test(source) && /meterCustomSeriesBtnColor/.test(source), 'per-group Custom buttons open the manager');
assert(/meterCustomSeriesLoad\('+series\.id\+'\)/.test(source) || source.includes("meterCustomSeriesLoad('+series.id+')"), 'manager rows have Load');
assert(source.includes('function meterCustomSeriesLoad('), 'load closes the manager and selects the series');
assert(/meterCustomSeriesManagerModal/.test(source), 'manager modal exists');
assert(/meterCubePreviewPanel/.test(source) && /meterSolvedLutList/.test(source), 'preview + lut list shells');
assert(/\.btn-custom-series\{/.test(source), 'btn-custom-series CSS class defined');
// render buttons: no pencil, custom class present
const render = extractFunction('meterRenderCustomSeriesButtons');
assert(!/9998/.test(render), 'edit pencil removed from series buttons');
assert(/btn-primary/.test(render), 'active custom series highlights its group button');
assert(/meterCustomSeriesLoadedGrey/.test(render) && /meterCustomSeriesLoaded3dLut/.test(render), 'loaded-series tags managed per group');
assert(/modeKey/.test(extractFunction('meterRenderCustomSeriesManager')), 'manager lists only the current display mode series');
// manager render lists series with mode badge + kind and Edit/Delete/export handlers
const mgr = extractFunction('meterRenderCustomSeriesManager');
assert(/meterManagerEditSeries\(/.test(mgr) && /meterManagerDeleteSeries\(/.test(mgr), 'row actions wired');
assert(/meterExportCustomSeriesById\(/.test(mgr), 'row export wired');
// dispatch behaviour of manager edit
const editFn = extractFunction('meterManagerEditSeries');
assert(/kind==='lattice'/.test(editFn) && /meterOpenCustomSeriesEditor/.test(editFn), 'edit dispatches by kind');
// shared delete used by editor delete
const delEditor = extractFunction('meterDeleteCustomSeries');
assert(/meterDeleteCustomSeriesById/.test(delEditor), 'editor delete delegates to id-based helper');
// export-by-id expands via meterCustomSeriesPatches
const exp = extractFunction('meterExportCustomSeriesById');
assert(/meterCustomSeriesPatches/.test(exp), 'export-by-id expands lattice patches');
// editor close returns to manager when flagged
const closeFn = extractFunction('meterCloseCustomSeriesEditorNow');
assert(/meterCustomSeriesReturnToManager/.test(closeFn), 'editor close can return to manager');
// The public close is a discard-guard wrapper around the Now variant.
const closeWrap=source.slice(source.indexOf('async function meterCloseCustomSeriesEditor('),source.indexOf('function meterCloseCustomSeriesEditorNow('));
assert(/meterCustomSeriesEditorUnsaved/.test(closeWrap)&&/meterCloseCustomSeriesEditorNow\(\)/.test(closeWrap), 'close guards unsaved changes then delegates');
assert(source.includes("if(!patch.name) patch.name='Patch '+Number(index||0);"), 'automatic custom-series patch names start at Patch 0');
assert(source.includes("editor.patches.push(meterCustomSeriesSanitizePatch({},editor.patches.length));"), 'newly added rows continue zero-based automatic patch numbering');
console.log('custom-series-manager-regression: PASS');
