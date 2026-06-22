const assert=require('assert');
const fs=require('fs');
const src=fs.readFileSync('usr/share/PGenerator/webui.pm','utf8');
// HDR10 color/sat verification solves patches in the BT.2020 container for
// saturation sweeps (matches the wire gamut the panel actually receives).
// HLG stays on the container too. The ColorChecker chart target conversion
// (see tests/color-checker-p3-chart-target-conversion-regression.js) is what
// brings the chromatic patches into the panel-reproducer gamut; the solve
// side stays in the container to keep saturation sweeps stable.
const lines=(src.match(/my \$solve_key=[^\n;]*;/g)||[]);
assert(lines.length>=2,'expected at least two solve_key assignments');
lines.forEach((line,i)=>{
  // solve_key must either:
  //   (a) equal target_key (DV/SDR fall-through), OR
  //   (b) equal container_key (HDR10/HLG saturation sweep stability).
  assert(/(\$target_key|\$container_key)/.test(line),
    'solve_key #'+(i+1)+' must reference either target_key or container_key');
  if(/eq "hlg"/.test(line)){
    assert(/\$container_key/.test(line), 'solve_key #'+(i+1)+' keeps hlg on the container');
  }
});
console.log('hdr color/sat solve-in-target-gamut regression OK');
