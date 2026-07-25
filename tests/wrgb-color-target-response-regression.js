// WRGB ColorChecker/saturation target-Y regression.
//
// A selected WRGB OLED must use the current series' measured R/G/B endpoints
// to scale chromatic luminance while leaving neutral luminance on measured
// white. Additive display selections must retain the signal-defined target.
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
 extractFunction('meterWrgbSeriesEndpointResponse'),
 extractFunction('meterWrgbCompensatedTargetY'),
 extractFunction('meterOrderWrgbTargetAnchors'),
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

const ordered=context.meterOrderWrgbTargetAnchors([
 {name:'Gray 35'},{name:'Dark Skin'},{name:'100% Green'},
 {name:'White'},{name:'100% Blue'},{name:'Black'},{name:'100% Red'},
 {name:'Orange'}
]);
assert.deepStrictEqual(
 Array.from(ordered,name=>name.name),
 ['White','Black','100% Red','100% Green','100% Blue','Gray 35','Dark Skin','Orange'],
 'WRGB response anchors are measured before the test body'
);
assert(
 source.includes('my $wrgb_target_series=') &&
 source.includes('100%\\s+Red|Red\\s+100%') &&
 source.includes('100%\\s+Green|Green\\s+100%') &&
 source.includes('100%\\s+Blue|Blue\\s+100%'),
 'backend series worker order is gated by WRGB Display Type and promotes all three anchors'
);
technology='qdoled';
const additiveOrder=context.meterOrderWrgbTargetAnchors([{name:'Orange'},{name:'White'},{name:'100% Red'}]);
assert.deepStrictEqual(Array.from(additiveOrder,name=>name.name),['Orange','White','100% Red'],
 'additive display series order is unchanged');
technology='oled_generic';

// Each primary endpoint targets the measured chromatic capability at this
// series level, rather than the impossible white-referenced primary value.
for(const [name,code,measured] of [
 ['red',[2813,256,256],51.329963],
 ['green',[256,2813,256],165.594962],
 ['blue',[256,256,2813],17.592354]
]){
 const rd={series_color:name,sat_pct:100,r_code:code[0],g_code:code[1],b_code:code[2]};
 close(context.meterWrgbStimulusTargetY(rd),measured,0.02,`${name} endpoint uses measured response`);
}

// Real C2 DV ColorChecker samples: the response model removes the large
// impossible-target error without making target Y equal to the measured patch.
let sweepRawError=0;
let sweepCompensatedError=0;
for(const [name,code,measured,maxError] of [
 ['Orange',[2595,1703,959],99.929959,0.12],
 ['Orange Yellow',[2785,2155,1084],149.715289,0.10],
 ['Yellow',[2925,2567,1114],203.931187,0.08],
 ['Cyan',[725,1770,2110],80.302263,0.06]
]){
 const rd={name,r_code:code[0],g_code:code[1],b_code:code[2]};
 const target=context.meterWrgbStimulusTargetY(rd);
 assert(Math.abs(target/measured-1)<=maxError,`${name} compensated target ${target} vs measured ${measured}`);
 assert(target<rawY(rd),`${name} compensation must reduce the impossible raw target`);
}

// Independent 25-point DV saturation sweep from the same panel. These are
// intermediate points, not the R/G/B measurements used to build the response.
// The endpoint-derived model must improve each old raw-stimulus target.
for(const [name,code,measured,maxError] of [
 ['Red 25%',[2813,1968,1968],163.328729,0.07],
 ['Green 50%',[1613,2813,1613],228.112587,0.04],
 ['Blue 50%',[1742,1742,2813],120.79113,0.12],
 ['Cyan 50%',[2004,2813,2813],298.311275,0.08],
 ['Magenta 50%',[2813,1944,2813],185.582339,0.03],
 ['Yellow 50%',[2813,2813,1865],284.731581,0.06]
]){
 const rd={name,r_code:code[0],g_code:code[1],b_code:code[2]};
 const raw=rawY(rd);
 const target=context.meterWrgbStimulusTargetY(rd);
 assert(Math.abs(target/measured-1)<=maxError,`${name} compensated target ${target} vs measured ${measured}`);
 sweepRawError+=Math.abs(raw/measured-1);
 sweepCompensatedError+=Math.abs(target/measured-1);
}
assert(sweepCompensatedError<sweepRawError*0.55,
 `saturation compensation must cut aggregate target error by at least 45% (${sweepRawError} -> ${sweepCompensatedError})`);

// QD-OLED and every other additive display type keep the signal target even
// if old WRGB endpoint readings remain in browser memory.
technology='qdoled';
const yellow={r_code:2925,g_code:2567,b_code:1114};
close(context.meterWrgbStimulusTargetY(yellow),rawY(yellow),1e-9,'QD-OLED bypasses WRGB compensation');
technology='lcd_wled';
close(context.meterWrgbStimulusTargetY(yellow),rawY(yellow),1e-9,'LCD bypasses WRGB compensation');

console.log('wrgb color target response regression OK');
