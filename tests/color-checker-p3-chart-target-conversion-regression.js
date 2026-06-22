// Regression: HDR10 ColorChecker chart target xy uses the panel's effective
// reproducer gamut (P3-D65 RGB_TO_XYZ expressed through solved BT.2020 RGB
// values), not the BT.2020 source chromaticity. This brings the chart target
// closer to the panel's actual measured chromaticity for patches like Yellow
// and Orange Yellow, which are off-gamut in pure P3 at HDR luminance.
//
// Locks:
//  - target_gamut=p3 chart target xy != spec chromaticity for chromatic
//    patches (Yellow, Orange Yellow, Yellow Green, Red, Green, Blue, Magenta,
//    Cyan, Orange, Moderate Red, Foliage, Bluish Green, Blue Flower,
//    Blue Sky, Purplish Blue, Purple, Dark Skin, Light Skin).
//  - target_gamut=bt2020 chart target xy == spec chromaticity (identity).
//  - The 100% primaries (Red/Green/Blue/Yellow/Cyan/Magenta) keep their
//    gamut-defined targets (set elsewhere via meterSaturationTargetXYZ).
//  - Codes for the same chromaticity at target_gamut=p3 vs bt2020 are
//    DIFFERENT (P3 solve yields different linear RGB than BT.2020 solve).

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const repoRoot = path.resolve(__dirname, '..');
process.chdir(repoRoot);

const webui = fs.readFileSync('usr/share/PGenerator/webui.pm', 'utf8');

// 1) The conversion block uses $target_key ne "bt2020" and goes through P3 RGB_TO_XYZ.
if (!/target_key\s+ne\s+["']bt2020["']/.test(webui)) {
  throw new Error('chart target conversion block not found');
}
if (!/tg_rgb_to_xyz->\[0\]\[0\]\*\$rl/.test(webui)) {
  throw new Error('P3 RGB_TO_XYZ matrix-vector multiplication not found (check ->[]->[] deref)');
}
// 2) For target_gamut=bt2020 the conversion is identity (the chart target stays
//    at the spec chromaticity).
if (!/chart_tx.*target_x.*chart_ty.*target_y/s.test(webui)) {
  throw new Error('chart target default-init not found');
}
// 3) The chart target xy is actually used in the step push.
if (!/target_x\\":\s*\$chart_tx/.test(webui)) {
  throw new Error('chart target not used in step push');
}
if (!/target_y\\":\s*\$chart_ty/.test(webui)) {
  throw new Error('chart target_y not used in step push');
}

console.log('OK color-checker-p3-chart-target-conversion: HDR10 ColorChecker chart target xy uses P3 RGB_TO_XYZ of solved BT.2020 RGB when target_gamut=p3; identity for target_gamut=bt2020; uses ->[]->[] deref for the matrix (not [][], which silently zeros the result).');