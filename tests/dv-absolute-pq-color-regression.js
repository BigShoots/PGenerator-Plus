// DV Absolute keeps the standard-DV patch tunnel unchanged, but its error
// target luminance is decoded as ST 2084.
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
 meterColorTargetCodeRange:()=>({min:256,span:3504}),
 meterActiveSeriesMaxLuma:1000,
 meterChartHdrPeak:()=>1000,
 meterHdrDiffuseScale:()=>1,
 meterColorSeriesReferenceNits:()=>700,
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
 extractFunction('meterEncodeSaturationLinear'),
 extractFunction('meterDvStimulusLinearChannel')
].join('\n'),context);

const close=(actual,expected,tolerance,message)=>
 assert(Math.abs(actual-expected)<=tolerance,`${message}: got ${actual}, expected ${expected}`);
const min=256,span=3504;

// Absolute patch construction remains byte-for-byte compatible with the
// previously working standard-DV tunnel.
const linear=0.18;
close(context.meterTargetLinearToSignal(linear),
 context.meterChartPqEncodeNormalized(linear*10000),1e-12,
 'DV Absolute target-curve helper remains PQ');
const ccAbs=context.meterEncodeColorCheckerLinear(linear);
assert.strictEqual(ccAbs,
 Math.round(min+Math.pow(linear*0.68,1/2.2)*span),
 'DV Absolute ColorChecker patch remains gamma 2.2');
const satAbs=context.meterEncodeSaturationLinear(linear,'Red');
assert.strictEqual(satAbs,
 Math.round(min+Math.pow(linear,1/2.2)*span),
 'DV Absolute saturation patch remains gamma 2.2');
const absoluteCode=1900;
const absoluteNorm=(absoluteCode-min)/span;
close(context.meterDvStimulusLinearChannel(absoluteCode),
 Math.min(context.meterChartPqDecodeNormalized(absoluteNorm),1000),1e-9,
 'DV Absolute error target luminance uses HDR/PQ decode');

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

// Lock the server-side patch builders: only HDR10 may enter these PQ encoders.
assert(!/if\(\$signal_mode eq "hdr10" \|\| \(\$signal_mode eq "dv" && \$dv_map_mode eq "1"\)\)/.test(source),
 'server DV Absolute must not enter HDR10 patch encoders');

console.log('dv absolute pq color regression OK');
