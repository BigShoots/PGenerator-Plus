const assert = require('assert');
const fs = require('fs');

const ui = fs.readFileSync('usr/share/PGenerator/webui.pm', 'utf8');
const worker = fs.readFileSync('usr/bin/meter_lg_3d_autocal.pl', 'utf8');

// 1. Container/transport: HDR10 still uploads into the BT.2020 3D-LUT slot.
assert(
  ui.includes("mode==='hdr10' ? {upload_command:'BT2020_3D_LUT_DATA',get_command:'GET_3D_LUT_DATA'} : {}"),
  'HDR10 upload slot remains BT2020_3D_LUT_DATA (container unchanged)'
);

// 2. CIE-chart container default stays BT.2020 for HDR (not re-pointed at the metadata gamut).
assert(
  /function meterDefaultTargetGamutForMode\(\)\{[\s\S]*?sm==='hdr10'\|\|sm==='hlg'\)\s*return 'bt2020';/s.test(ui),
  'meterDefaultTargetGamutForMode keeps BT.2020 for HDR (chart container)'
);

// 3. SDR is untouched: the 3D-LUT AutoCal target line still has the exact SDR branch.
assert(
  ui.includes(":(fullWorkflow?'bt709':meterAutoCalTargetGamutValue());"),
  'SDR / fullWorkflow target_gamut branch is unchanged'
);

// 4. The worker honors a P3/D65 target for HDR10 (only defaults to bt2020 when empty/auto).
const sanitize = worker.slice(worker.indexOf('sub sanitize_target_gamut'), worker.indexOf('sub sanitize_target_gamma'));
assert(/return "p3d65" if\(\$token eq "p3" \|\| \$token eq "p3d65"/.test(sanitize),
  'worker sanitize_target_gamut returns p3d65 for a p3d65 token (HDR LUT can target P3/D65)');
assert(/\$default=\(defined\(\$signal_mode\) && lc\(\$signal_mode\) eq "hdr10"\) \? "bt2020" : "bt709";/.test(sanitize),
  'worker only DEFAULTS hdr10 to bt2020 (does not force it)');
console.log('hdr matrix-lut container invariants regression OK');
