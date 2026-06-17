const assert=require('assert');
const fs=require('fs');
const src=fs.readFileSync('usr/share/PGenerator/webui.pm','utf8');
// HDR10 color/saturation verification must solve patches in the selected
// target gamut (like DV/SDR), not force the BT.2020 container. Solving in the
// container desaturates wide-gamut patches (a P3 panel renders them ~BT.709).
// HLG stays on the container (out of scope).
const lines=(src.match(/my \$solve_key=[^\n;]*;/g)||[]);
assert(lines.length>=2,'expected at least two solve_key assignments');
lines.forEach((line,i)=>{
  assert(!/eq "hdr10"/.test(line), 'solve_key #'+(i+1)+' must not special-case hdr10 to the container');
  assert(/\$target_key/.test(line), 'solve_key #'+(i+1)+' falls through to target_key');
  assert(/eq "hlg"/.test(line) && /\$container_key/.test(line), 'solve_key #'+(i+1)+' keeps hlg on the container');
});
console.log('hdr color/sat solve-in-target-gamut regression OK');
