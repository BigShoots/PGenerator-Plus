// DV Absolute color patches and targets use ST 2084; gamma 2.2 is Relative only.
const assert=require('assert');
const fs=require('fs');
const vm=require('vm');

const source=fs.readFileSync('usr/share/PGenerator/webui.pm','utf8');
function extractFunction(name){
 const token=`function ${name}(`;
 const start=source.indexOf(token);
 assert(start>=0,`missing ${name}`);
 let i=source.indexOf('{',start),depth=0;
 for(;i<source.length;i++){
  if(source[i]==='{') depth++;
  else if(source[i]==='}'&&--depth===0) return source.slice(start,i+1);
 }
 throw new Error(`unterminated ${name}`);
}

let mapMode='1';
const context={
 meterChartIsDv:()=>true,
 meterDvMapModeValue:()=>mapMode,
 meterDvUsesPqTargetCurve:()=>mapMode==='1',
 meterChartIsPq:()=>true,
 meterChromaPatchRangeMin:()=>256,
 meterChromaPatchRangeSpan:()=>3504,
 meterActiveSeriesMaxLuma:1000,
 meterChartHdrPeak:()=>1000,
 meterDvClassicColorCheckerScale:()=>0.68
};
vm.createContext(context);
vm.runInContext([
 extractFunction('meterChartPqEncodeNormalized'),
 extractFunction('meterChartPqDecodeNormalized'),
 extractFunction('meterTargetLinearToSignal'),
 extractFunction('meterTargetSignalToLinear'),
 extractFunction('meterEncodeColorCheckerLinear'),
 extractFunction('meterDecodeColorCheckerSignal'),
 extractFunction('meterEncodeSaturationLinear')
].join('\n'),context);

const close=(actual,expected,tolerance,message)=>
 assert(Math.abs(actual-expected)<=tolerance,`${message}: got ${actual}, expected ${expected}`);
const min=256,span=3504;

// Absolute follows the exact HDR/PQ formulas.
const linear=0.18;
close(context.meterTargetLinearToSignal(linear),
 context.meterChartPqEncodeNormalized(linear*10000),1e-12,
 'DV Absolute target OETF is PQ');
const ccAbs=context.meterEncodeColorCheckerLinear(linear);
assert.strictEqual(ccAbs,
 Math.round(min+context.meterChartPqEncodeNormalized(linear*1000)*span),
 'DV Absolute ColorChecker encoder matches HDR/PQ');
const satAbs=context.meterEncodeSaturationLinear(linear,'Red');
assert.strictEqual(satAbs,
 Math.round(min+context.meterChartPqEncodeNormalized(linear*10000)*span),
 'DV Absolute saturation encoder matches HDR/PQ');

// Relative retains its classic 0.68 scale and gamma-2.2 tunnel.
mapMode='2';
close(context.meterTargetLinearToSignal(linear),linear,1e-12,
 'DV Relative target path remains linear before its tunnel encoder');
const ccRelative=context.meterEncodeColorCheckerLinear(linear);
assert.strictEqual(ccRelative,
 Math.round(min+Math.pow(linear*0.68,1/2.2)*span),
 'DV Relative ColorChecker remains gamma 2.2');
const satRelative=context.meterEncodeSaturationLinear(linear,'Red');
assert.strictEqual(satRelative,
 Math.round(min+Math.pow(linear,1/2.2)*span),
 'DV Relative saturation remains gamma 2.2');

// Lock the server-side builders as well; these generate the actual run steps.
assert(/return &webui_pattern_pq_encode_normalized\(\$v\*10000\) if\(\$dv_map_mode eq "1"\)/.test(source),
 'server DV Absolute target encoder must use PQ');
assert(/if\(\$signal_mode eq "hdr10" \|\| \(\$signal_mode eq "dv" && \$dv_map_mode eq "1"\)\)\s*\{\s*return int\(\$min_code \+ &webui_pattern_pq_encode_normalized\(\$linear\*10000\)/s.test(source),
 'server DV Absolute saturation encoder must share HDR PQ path');

console.log('dv absolute pq color regression OK');
