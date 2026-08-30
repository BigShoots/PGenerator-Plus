'use strict';

const fs=require('fs');
const path=require('path');
const root=path.resolve(__dirname,'..');
const runtime=require(path.join(root,'usr/share/PGenerator/webui-colour-math.js'));
const fixture=JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/math_conformance.json'),'utf8'));
const measurementFixture=JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/measurement_conformance.json'),'utf8'));
const targetFixture=JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/calibration_target_conformance.json'),'utf8'));
const ciedeFixture=JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/ciede2000_sharma.json'),'utf8'));
const signalCodeFixture=JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/signal_code_conformance.json'),'utf8'));

let checks=0;
function close(label,actual,expected,tolerance){
 checks++;
 if(typeof actual!=='number'||typeof expected!=='number'||
    !Number.isFinite(actual)||!Number.isFinite(expected))
  throw new Error(label+': non-finite comparison '+actual+' != '+expected);
 const allowed=(tolerance==null?2e-12:tolerance)*Math.max(1,Math.abs(expected));
 if(Math.abs(actual-expected)>allowed) throw new Error(label+': '+actual+' != '+expected);
}
function exact(label,actual,expected){
 checks++;
 if(actual!==expected) throw new Error(label+': '+actual+' != '+expected);
}

for(const row of fixture.pq_encode){
 close('JS PQ encode '+row.nits,runtime.pqEncodeNormalized(row.nits),row.signal);
 close('JS chart PQ encode '+row.nits,runtime.meterChartPqEncodeNormalized(row.nits),row.signal);
}
for(const row of fixture.pq_decode)
 close('JS PQ decode '+row.signal,runtime.meterChartPqDecodeNormalized(row.signal),row.nits);

const hardZero=fixture.policy_rows.pq_encode_zero.find(row=>row.policy==='hard_zero');
exact('JS PQ encode zero',runtime.pqEncodeNormalized(0),hardZero.signal);
exact('JS chart PQ encode zero',runtime.meterChartPqEncodeNormalized(0),0);
exact('JS PQ encode negative',runtime.pqEncodeNormalized(-5),0);

for(const row of measurementFixture.cct_from_xy){
 checks++;
 const estimate=runtime.meterCctFromXy(row.x,row.y);
 const actual=estimate==null?0:Math.round(estimate);
 if(actual!==row.cct) throw new Error('JS CCT '+row.name+': '+actual+' != '+row.cct);
}
exact('JS CCT rejects non-finite chromaticity',runtime.meterCctFromXy(NaN,0.3),null);

const adapted=runtime.meterBradfordAdaptXyz(
 0.31,0.42,0.18,{x:0.3127,y:0.3290},{x:0.3457,y:0.3585});
for(const [index,key] of ['X','Y','Z'].entries())
 close('JS Bradford D65 to D50 '+key,adapted[key],
  [0.32546129634603371,0.42209381787880462,0.13879518502169955][index],2e-7);
const product=runtime.matrix3VectorMultiply(fixture.matrix,fixture.vector);
for(let index=0;index<3;index++)
 close('JS matrix-vector '+index,product[index],fixture.product[index]);

for(const [index,row] of fixture.colour_0_4_7_ictcp_reference.entries()){
 const actual=runtime.xyzToICtCp(...row.xyz);
 for(const [component,key] of ['I','T','P'].entries())
  close('JS ICtCp reference '+index+' '+key,actual[key],row.ictcp[component],2e-7);
}
for(const [index,row] of fixture.colour_0_4_7_delta_e_itp_reference.entries())
 close('JS Delta E ITP reference '+index,runtime.deltaEITP(...row.first,...row.second),row.delta_e,2e-7);

for(const [index,row] of ciedeFixture.pairs.entries()){
 const first={L:row.first[0],a:row.first[1],b:row.first[2]};
 const second={L:row.second[0],a:row.second[1],b:row.second[2]};
 close('JS CIEDE2000 Sharma pair '+index,runtime.deltaE2000(first,second),row.delta_e,5e-5);
}

const jndFirst={L:12.4,a:3.2,b:-4.1};
const jndSecond={L:10.9,a:2.7,b:-3.4};
close('JS JND standard-SL fallback',runtime.deltaE2000JND(jndFirst,jndSecond,0,0),1.2542310400237857);
close('JS JND positive luminance',runtime.deltaE2000JND(jndFirst,jndSecond,1,2),2.0730321454603882);
close('JS JND low-nit Barten scaling',runtime.deltaE2000JND(jndFirst,jndSecond,0.006,0.004),20.240937842592650);

for(const row of targetFixture){
 const context=runtime.calibrationTargetContext(row);
 if(!context) throw new Error('JS target context rejected '+row.name);
 checks++;
 if(!Object.isFrozen(context)) throw new Error('JS target context is mutable for '+row.name);
 const actual=row.caller_policy==='autocal_1d'
  ?runtime.targetLuminanceForContext(context,row.stimulus,row.white_y,row.black_y)
  :runtime.targetRelativeLuminanceForContext(context,row.signal,row.white_y,row.black_y);
 close('JS target context '+row.name,actual,Number(row.expected));
}

const dv=runtime.calibrationTargetContext({
 caller_policy:'autocal_1d',signal_mode:'dv',target_gamma:'st2084',sdr_signal_peak:100
});
exact('JS DV tunnel policy is explicit',dv.transfer_policy,'dv_gamma_2_2_tunnel');
exact('JS context schema is stable',dv.schema,'pgen-calibration-target-context-v1');
exact('JS context version is stable',dv.context_version,1);

for(const signal of [-0.1,0,0.0031308,0.5,1,1.1]){
 const encoded=runtime.srgbEncodeBounded(signal);
 const decoded=runtime.srgbDecodeBounded(encoded);
 close('JS bounded sRGB round trip '+signal,decoded,Math.max(0,Math.min(1,signal)));
}
close('JS unbounded sRGB preserves headroom',runtime.srgbDecodeUnbounded(runtime.srgbEncodeUnbounded(1.1)),1.1);

for(const row of signalCodeFixture.rows){
 const policy=runtime.signalCodePolicy({
  signal_mode:row.signal_mode,signal_range:row.signal_range,...(row.options||{})
 });
 checks++;
 if(!policy||!Object.isFrozen(policy)) throw new Error('JS signal policy rejected '+row.name);
 const actual=runtime.signalPercentToCode(policy,row.stimulus_percent);
 exact('JS signal-code fixture '+row.name,JSON.stringify(actual),JSON.stringify(row.expected));
 const fraction=runtime.codeToSignalFraction(policy,actual.code);
 checks++;
 if(!Number.isFinite(fraction)||fraction<0) throw new Error('JS signal fraction invalid '+row.name);
}

const appSource=fs.readFileSync(path.join(root,'usr/share/PGenerator/webui-app.js'),'utf8');
exact('browser preview constructs the shared signal policy',appSource.includes('const policy=signalCodePolicy(input);'),true);
exact('browser generic preview delegates shared conversion',appSource.includes('return meterPreviewSignalCode(percent,opts||{});'),true);
exact('browser SDR26 preview delegates shared conversion',appSource.includes('return meterPreviewSignalCode(slot,{lgAutocal26:true});'),true);
exact('browser bit depth never comes from white-code magnitude',appSource.includes('wc>0 && wc<=255'),false);

console.log(checks+' JavaScript colour-math conformance checks passed');
