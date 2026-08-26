use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempfile);

# Regression guard for the colour-series White defect ("SG White reads over
# 100% RGB with elevated dE while xyY shows 100%"):
#  (1) the chroma patch range must scale ENDPOINTS like meterGreyCodeRange
#      (10-bit Full top = 1023, never span*4 = 1020);
#  (2) every builtin colour preset's White endpoint must land on the range top
#      and carry build-time signal_*_pct stamps;
#  (3) the neutral-row greyscale analysis must be range-flip-proof: a series
#      measured under Limited codes and viewed under Full settings must still
#      score its White at exactly 100/100/100 with zero dE.
# Runs the REAL webui-app.js + webui-workspace.js in node with a DOM shim.

my $node_version=`node --version 2>/dev/null`;
plan skip_all => 'node is required to execute the colour-range functions'
 if(!defined($node_version) || $node_version!~/v\d+/);

my $app="$Bin/../usr/share/PGenerator/webui-app.js";
my $workspace="$Bin/../usr/share/PGenerator/webui-workspace.js";
ok(-f $app,'webui-app.js exists');
ok(-f $workspace,'webui-workspace.js exists');

my ($jsfh,$jsfile)=tempfile('pgen-color-white-range-XXXX',SUFFIX=>'.js',UNLINK=>1);
print {$jsfh} <<'JS';
'use strict';
const fs=require('fs');
const assert=require('assert');
const appPath=process.argv[2];
const wsPath=process.argv[3];

// ---- DOM shim ----------------------------------------------------------
const elementValues={max_bpc:'10',max_luma:'1000',meterTargetGamma:'2.2',
 meterRgbBalanceFormula:'absolute',rgb_quant_range:'2',color_format:'0',
 meterGreyRefMode:'eotf'};
const elementChecked={meterTargetWhiteUseMeasured:true,meterTargetBlackUseMeasured:true};
function fakeEl(id){
 return {
  id,
  get value(){return elementValues[id]!=null?String(elementValues[id]):'';},
  set value(v){elementValues[id]=v;},
  get checked(){return !!elementChecked[id];},
  set checked(v){elementChecked[id]=!!v;},
  style:{},classList:{add(){},remove(){},toggle(){},contains(){return false;}},
  textContent:'',innerHTML:'',addEventListener(){},setAttribute(){},getAttribute(){return null;},
  appendChild(){},insertAdjacentElement(){},insertAdjacentHTML(){},removeChild(){},remove(){},
  insertBefore(){},replaceChildren(){},closest(){return null;},contains(){return false;},
  focus(){},blur(){},click(){},
  querySelector(){return null;},querySelectorAll(){return [];},
  getContext(){return null;},getBoundingClientRect(){return {width:0,height:0,left:0,top:0};},
  options:[],selectedIndex:0,disabled:false,dataset:{},
 };
}
const elCache={};
global.document={
 getElementById(id){if(!(id in elCache)) elCache[id]=fakeEl(id);return elCache[id];},
 querySelector(){return null;},querySelectorAll(){return [];},
 createElement(tag){return fakeEl('created-'+tag);},
 addEventListener(){},body:fakeEl('body'),documentElement:fakeEl('html'),
};
global.window=global;
global.addEventListener=()=>{};global.removeEventListener=()=>{};global.dispatchEvent=()=>true;
global.matchMedia=()=>({matches:false,addEventListener(){},removeEventListener(){},addListener(){},removeListener(){}});
global.ResizeObserver=function(){this.observe=()=>{};this.unobserve=()=>{};this.disconnect=()=>{};};
global.MutationObserver=function(){this.observe=()=>{};this.disconnect=()=>{};};
global.getComputedStyle=()=>({getPropertyValue(){return '';}});
global.history={replaceState(){},pushState(){}};
global.localStorage={getItem(){return null;},setItem(){},removeItem(){}};
try{Object.defineProperty(global,'navigator',{value:{userAgent:'node'},configurable:true});}catch(e){}
global.location={search:'',hash:'',href:'http://x/',protocol:'http:',host:'x'};
global.fetch=()=>new Promise(()=>{});
global.WebSocket=function(){this.addEventListener=()=>{};this.send=()=>{};this.close=()=>{};};
global.requestAnimationFrame=()=>0;
global.setInterval=()=>0;global.setTimeout=()=>0;global.clearInterval=()=>{};global.clearTimeout=()=>{};
global.alert=()=>{};global.confirm=()=>false;
global.Image=function(){};

// ---- placeholder substitution (webui.pm does this at serve time) -------
const PRESETS_JS=`{
 bt709:{label:'BT.709',white:{x:0.3127,y:0.329},
  primaries:{R:{x:0.64,y:0.33},G:{x:0.30,y:0.60},B:{x:0.15,y:0.06}},
  xyzToRgb:[[3.2404542,-1.5371385,-0.4985314],[-0.9692660,1.8760108,0.0415560],[0.0556434,-0.2040259,1.0572252]],
  rgbToXyz:[[0.4124564,0.3575761,0.1804375],[0.2126729,0.7151522,0.0721750],[0.0193339,0.1191920,0.9503041]]},
 bt2020:{label:'BT.2020',white:{x:0.3127,y:0.329},
  primaries:{R:{x:0.708,y:0.292},G:{x:0.170,y:0.797},B:{x:0.131,y:0.046}},
  xyzToRgb:[[1.7166512,-0.3556708,-0.2533663],[-0.6666844,1.6164812,0.0157685],[0.0176399,-0.0427706,0.9421031]],
  rgbToXyz:[[0.6369580,0.1446169,0.1688810],[0.2627002,0.6779981,0.0593017],[0.0000000,0.0280727,1.0609851]]},
 p3d65:{label:'P3 D65',white:{x:0.3127,y:0.329},
  primaries:{R:{x:0.680,y:0.320},G:{x:0.265,y:0.690},B:{x:0.150,y:0.060}},
  xyzToRgb:[[2.4934969,-0.9313836,-0.4027108],[-0.8294890,1.7626641,0.0236247],[0.0358458,-0.0761724,0.9568845]],
  rgbToXyz:[[0.4865709,0.2656677,0.1982173],[0.2289746,0.6917385,0.0792869],[0.0000000,0.0451134,1.0439444]]},
 p3dci:{label:'P3 DCI',white:{x:0.314,y:0.351},
  primaries:{R:{x:0.680,y:0.320},G:{x:0.265,y:0.690},B:{x:0.150,y:0.060}},
  xyzToRgb:[[2.7253940,-1.0180030,-0.4401632],[-0.7951680,1.6897321,0.0226471],[0.0412419,-0.0876390,1.1009294]],
  rgbToXyz:[[0.4451698,0.2771344,0.1722827],[0.2094917,0.7215953,0.0689131],[0.0000000,0.0470606,0.9073554]]}
}`;
const BRIDGE=`
globalThis.__set=function(state){
 if('meterReadings' in state) meterReadings=state.meterReadings;
 if('meterActiveSeriesType' in state) meterActiveSeriesType=state.meterActiveSeriesType;
 if('meterActiveSeriesPoints' in state) meterActiveSeriesPoints=state.meterActiveSeriesPoints;
 if('meterActiveSeriesSignalMode' in state){try{meterActiveSeriesSignalMode=state.meterActiveSeriesSignalMode;}catch(e){}}
 if('meterWhiteReading' in state){try{meterWhiteReading=state.meterWhiteReading;}catch(e){}}
 if('meterSeriesSteps' in state){try{meterSeriesSteps=state.meterSeriesSteps;}catch(e){}}
};
`;
const appSource=fs.readFileSync(appPath,'utf8')
 .replace('__PG_GAMUT_PRESETS__',PRESETS_JS)
 .replace(/^__PG_LG_JS__\s*$/m,';')
 .replace(/^\s*__PG_LG_LOAD_INFO__\s*$/m,';');
const wsSource=fs.readFileSync(wsPath,'utf8')
 .replace(/^\s*__PG_LG_INIT__\s*$/m,';');
(0,eval)(appSource+'\n'+wsSource+'\n'+BRIDGE);

// ---- helpers -----------------------------------------------------------
const wp={x:0.3127,y:0.3290};
function xyzAt(x,y,Y){return {X:x/y*Y,Y:Y,Z:(1-x-y)/y*Y};}
function readingFromStep(step,Y,ts){
 // Mirrors meter_series.sh build_step_reading_json field copies.
 const m=xyzAt(wp.x,wp.y,Y);
 const rd={X:m.X,Y:m.Y,Z:m.Z,x:wp.x,y:wp.y,luminance:Y,cct:6500,timestamp:ts};
 for(const f of ['ire','name','input_max','stimulus','signal_r_pct','signal_g_pct','signal_b_pct',
  'target_x','target_y','target_Yn','series_mode','series_color','sat_pct']){
  if(f in step) rd[f]=step[f];
 }
 rd.r_code=step.r;rd.g_code=step.g;rd.b_code=step.b;
 return rd;
}
function near(actual,expected,tol,label){
 assert(Math.abs(actual-expected)<=tol,label+': '+actual+' !~ '+expected);
}

// ---- (1) range endpoints ----------------------------------------------
elementValues.max_bpc='10';elementValues.rgb_quant_range='2';elementValues.color_format='0';
assert.strictEqual(meterChromaPatchRangeMin(),0,'10-bit Full chroma min');
assert.strictEqual(meterChromaPatchRangeMin()+meterChromaPatchRangeSpan(),1023,'10-bit Full chroma top == 1023');
assert.strictEqual(meterChromaPatchRangeMin()+meterChromaPatchRangeSpan(),meterPatchInputMax(),'10-bit Full chroma top == input max');
elementValues.rgb_quant_range='1';
assert.strictEqual(meterChromaPatchRangeMin(),64,'10-bit Limited chroma min');
assert.strictEqual(meterChromaPatchRangeMin()+meterChromaPatchRangeSpan(),940,'10-bit Limited chroma top');
elementValues.max_bpc='8';elementValues.rgb_quant_range='2';
assert.strictEqual(meterChromaPatchRangeMin()+meterChromaPatchRangeSpan(),255,'8-bit Full chroma top');
elementValues.rgb_quant_range='1';
assert.strictEqual(meterChromaPatchRangeMin()+meterChromaPatchRangeSpan(),235,'8-bit Limited chroma top');

// ---- (2) builtin White endpoints + stamps ------------------------------
elementValues.max_bpc='10';elementValues.rgb_quant_range='2';
for(const preset of ['classic-24','hcfr-gcd-24','sg-96','sg-skin-19']){
 const steps=meterBuildBuiltinColorCheckerSteps({preset});
 const white=steps.find(s=>String(s.name).toLowerCase()==='white');
 assert(white,'White step exists for '+preset);
 assert.strictEqual(white.r,1023,preset+' White r at 10-bit Full');
 assert.strictEqual(white.g,1023,preset+' White g');
 assert.strictEqual(white.b,1023,preset+' White b');
 near(Number(white.signal_r_pct),100,1e-9,preset+' White signal_r_pct');
 near(Number(white.signal_g_pct),100,1e-9,preset+' White signal_g_pct');
 near(Number(white.signal_b_pct),100,1e-9,preset+' White signal_b_pct');
}
elementValues.rgb_quant_range='1';
{
 const steps=meterBuildBuiltinColorCheckerSteps({preset:'sg-skin-19'});
 const white=steps.find(s=>String(s.name).toLowerCase()==='white');
 assert.strictEqual(white.r,940,'sg-skin White r at 10-bit Limited');
 near(Number(white.signal_r_pct),100,1e-9,'sg-skin Limited White signal_r_pct');
}

// ---- (2b) Calculated RGB target-code row -------------------------------
// The signal_*_pct stamp routes colour patches through the honest per-channel
// pct branch of meterLiveTargetRgbCodes. Pre-stamp, Full-range colour patches
// fell to the ladder-inference fallback, which misread their luminance-percent
// ire as a signal percent and put them on the Limited ladder.
elementValues.rgb_quant_range='2';
{
 const steps=meterBuildBuiltinColorCheckerSteps({preset:'sg-skin-19'});
 const skin=steps.find(s=>String(s.name)==='2E');
 const expected=[skin.r,skin.g,skin.b].map(c=>Math.round(c*255/1023));
 assert.deepStrictEqual(meterLiveTargetRgbCodes(skin),expected,
  '10-bit Full colour patch Calculated RGB row uses the full ladder');
}
elementValues.rgb_quant_range='1';
{
 const steps=meterBuildBuiltinColorCheckerSteps({preset:'sg-skin-19'});
 const skin=steps.find(s=>String(s.name)==='2E');
 const expected=[skin.r,skin.g,skin.b].map(c=>Math.round(16+219*Math.max(0,Math.min(1,(c-64)/876))));
 assert.deepStrictEqual(meterLiveTargetRgbCodes(skin),expected,
  '10-bit Limited colour patch Calculated RGB row uses the limited ladder');
}

// ---- (3) neutral-row analysis: clean + range-flip ----------------------
function analyseWhite(buildRange,viewRange,bpc){
 elementValues.max_bpc=bpc;elementValues.rgb_quant_range=buildRange;
 const steps=meterBuildBuiltinColorCheckerSteps({preset:'sg-skin-19'});
 const white=steps.find(s=>String(s.name).toLowerCase()==='white');
 const black=steps.find(s=>String(s.name).toLowerCase()==='black');
 const skin=steps.find(s=>String(s.name)==='2E');
 const readings=[readingFromStep(white,105,1000),readingFromStep(black,0.0005,1001),
  readingFromStep(skin,6.5,1002)];
 // The skin patch is chromatic; give it plausible chromatic XYZ so the
 // colour-path sanity check exercises real numbers.
 readings[2].x=0.44;readings[2].y=0.37;
 const m={X:0.44/0.37*6.5,Y:6.5,Z:(1-0.44-0.37)/0.37*6.5};
 readings[2].X=m.X;readings[2].Z=m.Z;
 elementValues.rgb_quant_range=viewRange;
 __set({meterActiveSeriesType:'colors',meterActiveSeriesPoints:800019,
  meterActiveSeriesSignalMode:'sdr',meterReadings:readings,meterWhiteReading:null,
  meterSeriesSteps:steps});
 const rgb=meterLiveRgbData(readings[0]);
 const de=meterSeriesDeltaEForDisplay(readings[0],meterGreyRefMode());
 const skinRgb=meterLiveRgbData(readings[2]);
 return {rgb,de,skinRgb};
}
// Clean: build and view under the same range (Full 10-bit).
for(const [build,view,bpc,label] of [
 ['2','2','10','clean 10-bit Full'],
 ['1','1','10','clean 10-bit Limited'],
 ['1','2','10','flip Limited->Full 10-bit'],
 ['2','1','10','flip Full->Limited 10-bit'],
 ['1','2','8','flip Limited->Full 8-bit'],
]){
 const {rgb,de,skinRgb}=analyseWhite(build,view,bpc);
 near(rgb.R,100,1e-6,label+' White R');
 near(rgb.G,100,1e-6,label+' White G');
 near(rgb.B,100,1e-6,label+' White B');
 near(de,0,1e-6,label+' White dE');
 for(const ch of ['R','G','B']){
  assert(skinRgb[ch]==null||Number.isFinite(skinRgb[ch]),label+' skin '+ch+' finite');
 }
}
console.log('all colour-white range assertions passed');
JS
close($jsfh) or die "Unable to close $jsfile: $!";

my $status=system('node',$jsfile,$app,$workspace);
is($status,0,'colour-series White range/analysis regression passes against production JS');

done_testing();
