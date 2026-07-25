// WRGB ColorChecker/saturation target-Y regression.
//
// Every color target must be determined before measurement. A selected WRGB
// OLED must not learn target luminance from the current series' R/G/B results.
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

const P3=[
 [0.48663243,0.26566758,0.19817182],
 [0.22897456,0.69173852,0.07928691],
 [0.00000000,0.04511331,1.04394437]
];
const whiteY=726.776262;
let technology='oled_generic';
let dvMapMode='2';
const context={
 document:{getElementById:()=>({value:technology})},
 getDisplayTechnology:()=>technology,
 meterChartIsPq:()=>true,
 meterChartIsDv:()=>true,
 meterDvMapModeValue:()=>dvMapMode,
 meterChartHdrPeak:()=>1000,
 meterHdrDiffuseScale:()=>1,
 meterAnalysisGamut:()=>({rgbToXyz:P3}),
 meterActiveChartSignalMode:()=> 'dv',
 meterColorTargetCodeRange:()=>({min:256,span:3504}),
 meterColorSeriesReferenceNits:()=>whiteY,
 meterCanonicalSeriesStep:()=>null,
 meterReadingLuminanceNits:rd=>Number(rd&&(rd.luminance!=null?rd.luminance:rd.Y))||0,
 meterReadingIsGreyscale:rd=>{
  const r=rd&&(rd.r_code!=null?rd.r_code:rd.r);
  const g=rd&&(rd.g_code!=null?rd.g_code:rd.g);
  const b=rd&&(rd.b_code!=null?rd.b_code:rd.b);
  return r!=null&&g!=null&&b!=null&&Number(r)===Number(g)&&Number(g)===Number(b);
 },
 linRgbToXyz:(r,g,b,M)=>({
  X:M[0][0]*r+M[0][1]*g+M[0][2]*b,
  Y:M[1][0]*r+M[1][1]*g+M[1][2]*b,
  Z:M[2][0]*r+M[2][1]*g+M[2][2]*b
 }),
 meterDecodeColorTargetChannel:()=>{ throw new Error('DV must use its 2.2 decoder'); }
};
context.meterReadings=[
 {name:'White',r_code:3760,g_code:3760,b_code:3760,Y:whiteY,signal_mode:'dv'},
 {series_color:'Red',sat_pct:100,r_code:2813,g_code:256,b_code:256,Y:51.329963,signal_mode:'dv'},
 {series_color:'Green',sat_pct:100,r_code:256,g_code:2813,b_code:256,Y:165.594962,signal_mode:'dv'},
 {series_color:'Blue',sat_pct:100,r_code:256,g_code:256,b_code:2813,Y:17.592354,signal_mode:'dv'}
];
vm.createContext(context);
vm.runInContext([
 extractFunction('meterWrgbTargetCompensationSelected'),
 extractFunction('meterChartPqDecodeNormalized'),
 extractFunction('meterDvStimulusLinearChannel'),
 extractFunction('meterWrgbStimulusTargetY')
].join('\n'),context);

const rawY=reading=>{
 const channels=[reading.r_code,reading.g_code,reading.b_code].map(context.meterDvStimulusLinearChannel);
 return context.linRgbToXyz(channels[0],channels[1],channels[2],P3).Y;
};
const wrgbY=reading=>{
 const channels=[reading.r_code,reading.g_code,reading.b_code].map(context.meterDvStimulusLinearChannel);
 const common=Math.min(...channels);
  const chromatic=P3[1].reduce((sum,weight,index)=>sum+weight*Math.max(0,channels[index]-common),0);
 const raw=context.linRgbToXyz(channels[0],channels[1],channels[2],P3).Y;
 const endpoint=common*P3[1].reduce((sum,weight)=>sum+weight,0)+0.65*chromatic;
 const signal=[reading.r_code,reading.g_code,reading.b_code].map(code=>(code-256)/3504);
 const hi=Math.max(...signal),lo=Math.min(...signal);
 const endpointSignal=(2813-256)/3504;
 const weight=hi>0?Math.max(0,Math.min(1,((hi-lo)/hi)*Math.pow(hi/endpointSignal,2))):0;
 return raw+(endpoint-raw)*weight;
};
const close=(actual,expected,tolerance,message)=>
 assert(Math.abs(actual-expected)<=tolerance,`${message}: got ${actual}, expected ${expected} ±${tolerance}`);

// Neutral patches stay on measured-white tracking because their chromatic
// residual is zero.
const grey={r_code:1664,g_code:1664,b_code:1664};
close(context.meterWrgbStimulusTargetY(grey),rawY(grey),1e-9,'WRGB grey target unchanged');

const samples=[
 {name:'Orange',r_code:2595,g_code:1703,b_code:959},
 {name:'Orange Yellow',r_code:2785,g_code:2155,b_code:1084},
 {name:'Red 25%',r_code:2813,g_code:1968,b_code:1968},
 {name:'Cyan 50%',r_code:2004,g_code:2813,b_code:2813}
];
context.meterReadings=[];
const before=samples.map(rd=>context.meterWrgbStimulusTargetY(rd));
context.meterReadings=[
 {name:'White',r_code:3760,g_code:3760,b_code:3760,Y:whiteY,signal_mode:'dv'},
 {series_color:'Red',sat_pct:100,r_code:2813,g_code:256,b_code:256,Y:1,signal_mode:'dv'},
 {series_color:'Green',sat_pct:100,r_code:256,g_code:2813,b_code:256,Y:999,signal_mode:'dv'},
 {series_color:'Blue',sat_pct:100,r_code:256,g_code:256,b_code:2813,Y:7,signal_mode:'dv'}
];
const after=samples.map(rd=>context.meterWrgbStimulusTargetY(rd));
assert.deepStrictEqual(Array.from(after),Array.from(before),
 'ColorChecker and saturation targets are invariant after arbitrary R/G/B reads');
samples.forEach((rd,index)=>close(before[index],wrgbY(rd),1e-9,`${rd.name} uses immediate DV WRGB model`));

// Independent completed LG C2 DV ColorChecker run. These patches occur before
// the full-saturation R/G/B series endpoints, so they prove the Display Type
// model produces the right target immediately rather than learning it later.
for(const [name,codes,measured] of [
 ['Light Skin',[2409,2002,1782],155.269687],
 ['Orange',[2595,1703,959],100.824969],
 ['Orange Yellow',[2785,2155,1084],151.013947],
 ['Yellow',[2925,2567,1114],205.864757],
 ['Magenta',[2244,1282,1913],78.955700]
]){
 const target=context.meterWrgbStimulusTargetY({name,r_code:codes[0],g_code:codes[1],b_code:codes[2]});
 assert(Math.abs(target/measured-1)<0.20,`${name} immediate WRGB target ${target} vs measured ${measured}`);
}

// QD-OLED and every other additive display type keep the signal target even
// if old WRGB endpoint readings remain in browser memory.
technology='qdoled';
const yellow={r_code:2925,g_code:2567,b_code:1114};
close(context.meterWrgbStimulusTargetY(yellow),rawY(yellow),1e-9,'QD-OLED bypasses WRGB compensation');
technology='lcd_wled';
close(context.meterWrgbStimulusTargetY(yellow),rawY(yellow),1e-9,'LCD bypasses WRGB compensation');

// Absolute DV greyscale is PQ, but color-series stimulus target Y remains
// referenced to measured white because the standard-DV color patches retain
// their classic gamma-2.2 encoding.
dvMapMode='1';
technology='oled_generic';
const absolute={r_code:1900,g_code:1500,b_code:1000};
const absoluteExpected=wrgbY(absolute);
close(context.meterWrgbStimulusTargetY(absolute),absoluteExpected,1e-9,
 'DV Absolute color target uses measured-white WRGB response');

console.log('wrgb color target response regression OK');
