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
const whiteY=717.870725;
let technology='oled_generic';
const context={
 document:{getElementById:()=>({value:technology})},
 getDisplayTechnology:()=>technology,
 meterChartIsPq:()=>true,
 meterChartIsDv:()=>true,
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
 extractFunction('meterDvStimulusLinearChannel'),
 extractFunction('meterWrgbStimulusTargetY')
].join('\n'),context);

const rawY=reading=>{
 const channels=[reading.r_code,reading.g_code,reading.b_code].map(context.meterDvStimulusLinearChannel);
 return context.linRgbToXyz(channels[0],channels[1],channels[2],P3).Y;
};
const close=(actual,expected,tolerance,message)=>
 assert(Math.abs(actual-expected)<=tolerance,`${message}: got ${actual}, expected ${expected} ±${tolerance}`);

// Neutral patches stay on measured-white tracking.
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
samples.forEach((rd,index)=>close(before[index],rawY(rd),1e-9,`${rd.name} uses authored signal target`));

// QD-OLED and every other additive display type keep the signal target even
// if old WRGB endpoint readings remain in browser memory.
technology='qdoled';
const yellow={r_code:2925,g_code:2567,b_code:1114};
close(context.meterWrgbStimulusTargetY(yellow),rawY(yellow),1e-9,'QD-OLED bypasses WRGB compensation');
technology='lcd_wled';
close(context.meterWrgbStimulusTargetY(yellow),rawY(yellow),1e-9,'LCD bypasses WRGB compensation');

console.log('wrgb color target response regression OK');
