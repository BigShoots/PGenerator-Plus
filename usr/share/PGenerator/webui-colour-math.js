'use strict';

// Pure browser colour maths. This fragment is concatenated before
// webui-app.js in the existing inline script; it must not read the DOM,
// perform I/O, or depend on mutable workflow globals.

function clampNum(v,min,max){
 v=parseFloat(v);
 if(isNaN(v))v=min;
 if(v<min)return min;
 if(v>max)return max;
 return v;
}

const PGEN_PQ_M1=2610/16384;
const PGEN_PQ_M2=2523/32;
const PGEN_PQ_C1=3424/4096;
const PGEN_PQ_C2=2413/128;
const PGEN_PQ_C3=2392/128;

function pqEncodeNormalized(nits){
 const l=clampNum(nits,0,10000)/10000;
 if(l<=0)return 0;
 const p=Math.pow(l,PGEN_PQ_M1);
 return Math.pow((PGEN_PQ_C1+PGEN_PQ_C2*p)/(1+PGEN_PQ_C3*p),PGEN_PQ_M2);
}

function meterChartPqEncodeNormalized(nits){
 return pqEncodeNormalized(nits);
}

function meterChartPqDecodeNormalized(code){
 const clamped=Math.max(0,Math.min(1,code||0));
 if(clamped<=0) return 0;
 const p=Math.pow(clamped,1/PGEN_PQ_M2);
 const num=Math.max(p-PGEN_PQ_C1,0);
 const den=PGEN_PQ_C2-PGEN_PQ_C3*p;
 if(den<=0) return 10000;
 return 10000*Math.pow(num/den,1/PGEN_PQ_M1);
}

function srgbDecodeUnbounded(v){
 const value=Number(v);
 if(!Number.isFinite(value)) return NaN;
 return value<=0.04045?value/12.92:Math.pow((value+0.055)/1.055,2.4);
}

function srgbDecodeBounded(v){
 return srgbDecodeUnbounded(Math.max(0,Math.min(1,Number(v)||0)));
}

function srgbEncodeUnbounded(v){
 const value=Number(v);
 if(!Number.isFinite(value)) return NaN;
 return value<=0.0031308?value*12.92:1.055*Math.pow(value,1/2.4)-0.055;
}

function srgbEncodeBounded(v){
 return srgbEncodeUnbounded(Math.max(0,Math.min(1,Number(v)||0)));
}

// Established chart names retained as semantic aliases for callers outside
// this fragment. Their boundary policies are intentionally explicit above.
function gammaEotf(v,gamma){return Math.pow(Math.max(0,v),gamma);}
function srgbEotf(v){return srgbDecodeUnbounded(v);}

function bt1886Eotf(v,Lw,Lb){
 Lw=Lw||100;Lb=Lb||0;
 const g=2.4;
 const a=Math.pow(Math.pow(Lw,1/g)-Math.pow(Lb,1/g),g);
 const b=Math.pow(Lb,1/g)/(Math.pow(Lw,1/g)-Math.pow(Lb,1/g));
 return a*Math.pow(Math.max(0,v+b),g);
}

function meterPowerTargetLuminance(signal,peak,gamma,Lb){
 const p=(peak>0)?peak:0;
 const y=gammaEotf(Math.max(0,Math.min(1,Number(signal)||0)),gamma)*p;
 const floor=Math.max(0,Number(Lb)||0);
 return floor>0?Math.max(y,floor):y;
}

function meterSrgbTargetLuminance(signal,peak,Lb){
 const p=(peak>0)?peak:0;
 const y=srgbEotf(Math.max(0,Math.min(1,Number(signal)||0)))*p;
 const floor=Math.max(0,Number(Lb)||0);
 return floor>0?Math.max(y,floor):y;
}

function browserTargetLuminanceForContext(context,signal,peak,Lb){
 if(!context||context.caller_policy!=='browser_chart') return null;
 const input=Math.max(0,Math.min(1,Number(signal)||0));
 if(context.transfer_policy==='bt1886_chart_ab') return bt1886Eotf(input,peak,Lb||0);
 if(context.transfer_policy==='srgb') return meterSrgbTargetLuminance(input,peak,Lb||0);
 if(context.transfer_policy==='power_2_2') return meterPowerTargetLuminance(input,peak,2.2,Lb||0);
 if(context.transfer_policy==='power_2_4') return meterPowerTargetLuminance(input,peak,2.4,Lb||0);
 if(context.transfer_policy==='pq_absolute') return meterChartPqDecodeNormalized(input);
 return null;
}

const PGEN_HDR20_8_LIMITED=Object.freeze({'1.4':19,'2':20,'2.7':22,'4':25,'5':27,'7':31,'10':38,'15':49,'20':60,'25':71,'30':82,'35':93,'40':104,'45':115,'50':126,'60':147,'70':169,'80':191,'90':213,'100':235});
const PGEN_HDR20_8_FULL=Object.freeze({'1.4':4,'2':5,'2.7':7,'4':10,'5':13,'7':18,'10':26,'15':38,'20':51,'25':64,'30':77,'35':89,'40':102,'45':115,'50':128,'60':153,'70':179,'80':204,'90':230,'100':255});
const PGEN_HDR20_10_LIMITED=Object.freeze({'1.4':76,'2':80,'2.7':88,'4':100,'5':108,'7':124,'10':152,'15':196,'20':240,'25':284,'30':328,'35':372,'40':416,'45':460,'50':504,'60':588,'70':676,'80':764,'90':852,'100':940});
const PGEN_HDR20_10_FULL=Object.freeze({'1.4':14,'2':20,'2.7':28,'4':41,'5':51,'7':72,'10':102,'15':153,'20':205,'25':256,'30':307,'35':358,'40':409,'45':460,'50':512,'60':614,'70':716,'80':818,'90':921,'100':1023});

function signalCodeRangeName(value,fallback){
 if(value==null||value==='') return fallback;
 const name=String(value).toLowerCase();
 if(name==='limited'||name==='legal'||name==='1') return 'limited';
 if(name==='full'||name==='0'||name==='2') return 'full';
 return null;
}

function signalCodePolicy(input){
 if(!input||typeof input!=='object'||Array.isArray(input)) return null;
 let mode=String(input.signal_mode||'sdr').toLowerCase();
 if(mode==='hdr') mode='hdr10';
 if(!['sdr','hdr10','hlg','dv'].includes(mode)) return null;
 let patternRange=signalCodeRangeName(input.pattern_range,
  signalCodeRangeName(input.signal_range,'full'));
 if(!patternRange) return null;
 const transportRange=signalCodeRangeName(input.transport_range,patternRange);
 if(!transportRange) return null;
 const flags=['two_point_ycbcr_headroom','autocal_26_codes','hdr20_codes',
  'dv_series','extended_sdr_codes','legal_sdr_ddc_codes','pq_luminance_percent'];
 const strategies=flags.filter(name=>Boolean(input[name]));
 if(strategies.length>1) return null;
 const strategy=strategies[0]||'standard';
 if(strategy==='dv_series'&&mode!=='dv') return null;
 if(strategy!=='hdr20_codes'&&input.active_table!=null) return null;
 let requestedBits=null;
 if(input.max_bpc!=null&&input.max_bpc!==''){
  requestedBits=Number(input.max_bpc);
  if(!Number.isInteger(requestedBits)||![8,10,12].includes(requestedBits)) return null;
 }
 let bits;
 if(strategy==='dv_series'){
  bits=input.dv_series_code_bits==null?8:Number(input.dv_series_code_bits);
  if(!Number.isInteger(bits)||![8,10,12].includes(bits)) return null;
 }else if(strategy==='hdr20_codes'||strategy==='autocal_26_codes'){
  bits=requestedBits===8?8:10;
 }else bits=requestedBits!=null&&requestedBits>=10?10:8;
 const inputMax=bits===12?4095:(bits===10?1023:255);
 let limited=patternRange==='limited';
 let legalMin=limited?(bits===12?256:(bits===10?64:16)):0;
 let nominalWhite=limited?(bits===12?3760:(bits===10?940:235)):inputMax;
 let allowsHeadroom=false,maximumStimulus=100;
 let percentDomain='container_signal_percent',tunnelMode='none',activeTable=null;
 const colorFormat=input.color_format==null?0:Number.parseInt(input.color_format,10);
 if(!Number.isInteger(colorFormat)||colorFormat<0||colorFormat>2) return null;
 if(strategy==='two_point_ycbcr_headroom'){
  if(!limited) return null;
  allowsHeadroom=true;maximumStimulus=109;percentDomain='nominal_ire_percent';
 }else if(strategy==='autocal_26_codes'){
  const ycbcr=colorFormat===1||colorFormat===2;
  allowsHeadroom=limited&&ycbcr;
  maximumStimulus=allowsHeadroom?109:100;
  percentDomain='nominal_ire_percent';
 }else if(strategy==='hdr20_codes'){
  if(mode!=='hdr10') return null;
  const source=input.active_table||(bits===8
   ?(input.hdr20_use_limited&&input.hdr20_full?PGEN_HDR20_8_FULL:PGEN_HDR20_8_LIMITED)
   :(input.hdr20_use_limited&&input.hdr20_full?PGEN_HDR20_10_FULL:PGEN_HDR20_10_LIMITED));
  if(!source||typeof source!=='object'||Array.isArray(source)) return null;
  activeTable={};
  for(const [key,value] of Object.entries(source)){
   if(!Number.isFinite(Number(key))||!Number.isFinite(Number(value))||Number(value)<0) return null;
   activeTable[key]=Math.trunc(Number(value));
  }
  activeTable=Object.freeze(activeTable);
 }else if(strategy==='dv_series'){
  limited=!input.dv_series_full_range;
  patternRange=limited?'limited':'full';
  legalMin=limited?(bits===12?256:(bits===10?64:16)):0;
  nominalWhite=limited?(bits===12?3760:(bits===10?940:235)):inputMax;
  let dvInterface=String(input.dv_interface||'standard').toLowerCase();
  if(dvInterface==='0') dvInterface='standard';
  if(dvInterface==='1'||dvInterface==='ll') dvInterface='low_latency';
  if(!['standard','low_latency'].includes(dvInterface)) return null;
  tunnelMode='dolby_vision_'+dvInterface;
  percentDomain='dolby_vision_tunnel_signal_percent';
 }else if(strategy==='extended_sdr_codes'){
  if(mode!=='sdr') return null;
  legalMin=bits===10?64:16;nominalWhite=inputMax;
  percentDomain='nominal_ire_percent';
 }else if(strategy==='legal_sdr_ddc_codes'){
  if(mode!=='sdr') return null;
  percentDomain='nominal_ire_percent';
 }else if(strategy==='pq_luminance_percent'){
  const peak=Number(input.signal_peak_nits);
  if(mode!=='hdr10'||!Number.isFinite(peak)||peak<=0||peak>10000) return null;
  percentDomain='absolute_luminance_fraction_of_peak';
 }
 return Object.freeze({
  schema:'pgen-signal-code-policy-v1',policy_version:1,
  signal_mode:mode,pattern_range:patternRange,transport_range:transportRange,
  input_bits:bits,input_max:inputMax,legal_min:legalMin,
  nominal_white_code:nominalWhite,physical_max_code:inputMax,
  allows_above_nominal_white:allowsHeadroom,
  maximum_stimulus_percent:maximumStimulus,
  rounding_mode:'positive_half_up',tunnel_mode:tunnelMode,
  percent_domain:percentDomain,strategy,color_format:colorFormat,
  hdr20_use_limited:input.hdr20_use_limited?1:0,
  hdr20_full:input.hdr20_full?1:0,
  signal_peak_nits:input.signal_peak_nits==null?0:Number(input.signal_peak_nits),
  active_table:activeTable
 });
}

function signalPercentToCode(policy,stimulus){
 if(!policy||policy.schema!=='pgen-signal-code-policy-v1') return null;
 stimulus=Number(stimulus);
 if(!Number.isFinite(stimulus)) return null;
 const strategy=policy.strategy,bits=policy.input_bits;
 const limited=policy.pattern_range==='limited',inputMax=policy.input_max;
 const clamp=(value,min,max)=>Math.max(min,Math.min(max,value));
 let code=0;
 if(strategy==='two_point_ycbcr_headroom'){
  const value=clamp(stimulus,0,109);
  code=value<=100
   ?Math.round(policy.legal_min+value/100*(policy.nominal_white_code-policy.legal_min))
   :Math.round(policy.nominal_white_code+(value-100)/9*(inputMax-policy.nominal_white_code));
  code=clamp(code,policy.legal_min,inputMax);
 }else if(strategy==='autocal_26_codes'){
  let value=stimulus;
  const ycbcr=policy.color_format===1||policy.color_format===2;
  if(bits===8){
   if(limited){
    if(ycbcr){
     value=clamp(value,0,109);
     code=value<=100?Math.round(16+value/100*219):Math.round(235+(value-100)/9*20);
     code=clamp(code,16,255);
    }else{
     value=clamp(value,0,100);code=clamp(Math.round(16+value/100*219),16,235);
    }
   }else{
    value=clamp(value,0,100);code=clamp(Math.round(value/100*255),0,255);
   }
  }else if(!limited){
   value=clamp(value,0,100);
   code=value>=99.95?1023:(clamp(Math.round(value/100*255),0,255)<<2);
  }else{
   value=clamp(value,0,ycbcr?109:100);
   code=ycbcr&&value>100?Math.round(940+(value-100)/9*83):Math.round(64+value/100*876);
   code=clamp(code,64,ycbcr?1023:940);
  }
 }else if(strategy==='hdr20_codes'){
  const value=clamp(stimulus,0,100);
  let slot='';
  for(const key of Object.keys(PGEN_HDR20_8_LIMITED)) if(Math.abs(Number(key)-value)<0.01){slot=key;break;}
  const minimum=bits===10&&policy.hdr20_use_limited&&policy.hdr20_full?0:(bits===8?0:64);
  const span=bits===10?(policy.hdr20_use_limited&&policy.hdr20_full?1023:876):255;
  code=Object.prototype.hasOwnProperty.call(policy.active_table,slot)
   ?policy.active_table[slot]:Math.round(minimum+value/100*span);
  code=clamp(code,minimum,minimum+span);
 }else if(strategy==='dv_series'){
  const value=clamp(stimulus,0,100)/100;
  const minimum=limited?(bits===12?256:(bits===10?64:16)):0;
  const span=limited?(bits===12?3504:(bits===10?876:219)):inputMax;
  code=clamp(Math.round(minimum+value*span),minimum,minimum+span);
 }else if(strategy==='pq_luminance_percent'){
  code=clamp(Math.round(pqEncodeNormalized(clamp(stimulus,0,100)/100*policy.signal_peak_nits)*inputMax),0,inputMax);
 }else{
  const value=clamp(stimulus,0,100);
  if(strategy==='extended_sdr_codes') code=value<=0?0:Math.round((bits===10?64:16)+value/100*(bits===10?959:239));
  else if(strategy==='legal_sdr_ddc_codes') code=value<=0?0:Math.round((bits===10?64:16)+value/100*(bits===10?876:219));
  else{
   const minimum=limited?(bits===10?64:16):0;
   const span=limited?(bits===10?876:219):inputMax;
   code=Math.round(minimum+value/100*span);
  }
  code=clamp(code,0,inputMax);
 }
 return {code:Math.trunc(code),input_max:Math.trunc(inputMax)};
}

function codeToSignalFraction(policy,code){
 if(!policy||policy.schema!=='pgen-signal-code-policy-v1') return null;
 code=Number(code);
 if(!Number.isFinite(code)||!(policy.input_max>0)) return null;
 code=Math.max(0,Math.min(policy.physical_max_code,code));
 if(policy.strategy==='pq_luminance_percent') return code/policy.input_max;
 if(code<=policy.legal_min) return 0;
 const nominalSpan=policy.nominal_white_code-policy.legal_min;
 if(!(nominalSpan>0)) return null;
 if(code<=policy.nominal_white_code) return (code-policy.legal_min)/nominalSpan;
 if(!policy.allows_above_nominal_white) return 1;
 const headroomSpan=policy.physical_max_code-policy.nominal_white_code;
 if(!(headroomSpan>0)) return 1;
 return 1+(code-policy.nominal_white_code)/headroomSpan*
  ((policy.maximum_stimulus_percent-100)/100);
}

function signalCodeNominalRange(policy){
 if(!policy||policy.schema!=='pgen-signal-code-policy-v1') return null;
 const minimum=Number(policy.legal_min);
 const maximum=Number(policy.nominal_white_code);
 const inputMax=Number(policy.input_max);
 if(!Number.isFinite(minimum)||!Number.isFinite(maximum)||!Number.isFinite(inputMax)
  ||minimum<0||maximum<minimum||maximum>inputMax) return null;
 return {min:Math.trunc(minimum),span:Math.trunc(maximum-minimum),
  max:Math.trunc(maximum),input_max:Math.trunc(inputMax)};
}

function matrix3VectorMultiply(matrix,vector){
 return [
  matrix[0][0]*vector[0]+matrix[0][1]*vector[1]+matrix[0][2]*vector[2],
  matrix[1][0]*vector[0]+matrix[1][1]*vector[1]+matrix[1][2]*vector[2],
  matrix[2][0]*vector[0]+matrix[2][1]*vector[1]+matrix[2][2]*vector[2]
 ];
}

function matrix3Multiply(left,right){
 return left.map((row,rowIndex)=>right[0].map((unused,column)=>
  left[rowIndex][0]*right[0][column]+
  left[rowIndex][1]*right[1][column]+
  left[rowIndex][2]*right[2][column]));
}

function saturationStimulusForGamuts(input){
 if(!input||typeof input!=='object'||!Array.isArray(input.chromaticity)
  ||input.chromaticity.length!==2) return null;
 const x=Number(input.chromaticity[0]),y=Number(input.chromaticity[1]);
 const level=Number(input.level);
 const validMatrix=matrix=>Array.isArray(matrix)&&matrix.length===3&&matrix.every(
  row=>Array.isArray(row)&&row.length===3&&row.every(value=>Number.isFinite(Number(value))));
 if(!Number.isFinite(x)||!Number.isFinite(y)||!Number.isFinite(level)
  ||x<0||x>1||y<=0||y>1||x+y>1+1e-12||level<0||level>1
  ||!validMatrix(input.target_xyz_to_rgb)||!validMatrix(input.transport_xyz_to_rgb)) return null;
 const unit=[x/y,1,(1-x-y)/y];
 if(!unit.every(Number.isFinite)) return null;
 const axis=matrix3VectorMultiply(input.target_xyz_to_rgb,unit);
 const axisMax=Math.max(axis[0],axis[1],axis[2],1e-9);
 const targetY=level/axisMax;
 const targetXyz=[unit[0]*targetY,targetY,unit[2]*targetY];
 const transport=matrix3VectorMultiply(input.transport_xyz_to_rgb,targetXyz);
 return {rgb:transport.map(value=>Math.max(0,value)),target_y:targetY};
}

const D65=Object.freeze({x:0.3127,y:0.3290,X:0.9505,Y:1.0,Z:1.0890});
const METER_BRADFORD_M=Object.freeze([
 Object.freeze([0.8951,0.2664,-0.1614]),
 Object.freeze([-0.7502,1.7135,0.0367]),
 Object.freeze([0.0389,-0.0685,1.0296])
]);
const METER_BRADFORD_MI=Object.freeze([
 Object.freeze([0.9869929,-0.1470543,0.1599627]),
 Object.freeze([0.4323053,0.5183603,0.0492912]),
 Object.freeze([-0.0085287,0.0400428,0.9684867])
]);

function xyToUnitXyz(x,y){
 if(!(x>0) || !(y>0) || x+y>=1) return {X:D65.X,Y:1,Z:D65.Z};
 return {X:x/y,Y:1,Z:(1-x-y)/y};
}

function meterBradfordAdaptXyz(X,Y,Z,fromWhite,toWhite){
 const fx=Number(fromWhite&&fromWhite.x),fy=Number(fromWhite&&fromWhite.y);
 const tx=Number(toWhite&&toWhite.x),ty=Number(toWhite&&toWhite.y);
 if(!(fx>0&&fy>0&&tx>0&&ty>0)) return {X:X,Y:Y,Z:Z};
 if(Math.abs(fx-tx)<1e-7&&Math.abs(fy-ty)<1e-7) return {X:X,Y:Y,Z:Z};
 const ws=xyToUnitXyz(fx,fy),wd=xyToUnitXyz(tx,ty);
 const cs=matrix3VectorMultiply(METER_BRADFORD_M,[ws.X,ws.Y,ws.Z]);
 const cd=matrix3VectorMultiply(METER_BRADFORD_M,[wd.X,wd.Y,wd.Z]);
 const c=matrix3VectorMultiply(METER_BRADFORD_M,[X,Y,Z]);
 const scaled=[c[0]*(cs[0]!==0?cd[0]/cs[0]:1),c[1]*(cs[1]!==0?cd[1]/cs[1]:1),c[2]*(cs[2]!==0?cd[2]/cs[2]:1)];
 const out=matrix3VectorMultiply(METER_BRADFORD_MI,scaled);
 return {X:out[0],Y:out[1],Z:out[2]};
}

function meterCctFromXy(x,y){
 if(!(Number.isFinite(x)&&Number.isFinite(y))) return null;
 if(y<=0) return null;
 const d=0.1858-y;
 if(Math.abs(d)<=1e-15) return null;
 const n=(x-0.3320)/d;
 const cct=449*n*n*n+3525*n*n+6823.3*n+5520.33;
 return (cct>=1000&&cct<=25000)?cct:null;
}

function xyzToICtCp(X,Y,Z){
 X=Number(X)||0; Y=Number(Y)||0; Z=Number(Z)||0;
 const R= 1.7166511880*X -0.3556707838*Y -0.2533662814*Z;
 const G=-0.6666843518*X +1.6164812366*Y +0.0157685458*Z;
 const B= 0.0176398574*X -0.0427706133*Y +0.9421031212*Z;
 const L=(1688*Math.max(0,R)+2146*Math.max(0,G)+262*Math.max(0,B))/4096;
 const M=(683*Math.max(0,R)+2951*Math.max(0,G)+462*Math.max(0,B))/4096;
 const S=(99*Math.max(0,R)+309*Math.max(0,G)+3688*Math.max(0,B))/4096;
 const Lp=meterChartPqEncodeNormalized(L);
 const Mp=meterChartPqEncodeNormalized(M);
 const Sp=meterChartPqEncodeNormalized(S);
 return {
  I:0.5*Lp+0.5*Mp,
  T:(6610*Lp-13613*Mp+7003*Sp)/4096,
  P:(17933*Lp-17390*Mp-543*Sp)/4096
 };
}

function deltaEITP(X1,Y1,Z1,X2,Y2,Z2){
 const a=xyzToICtCp(X1,Y1,Z1);
 const b=xyzToICtCp(X2,Y2,Z2);
 const dI=a.I-b.I;
 const dT=a.T-b.T;
 const dP=a.P-b.P;
 return 720*Math.sqrt(dI*dI+0.25*dT*dT+dP*dP);
}

function deltaEITPChromaOnly(X1,Y1,Z1,X2,Y2,Z2){
 const a=xyzToICtCp(X1,Y1,Z1);
 const b=xyzToICtCp(X2,Y2,Z2);
 const dT=a.T-b.T;
 const dP=a.P-b.P;
 return 720*Math.sqrt(0.25*dT*dT+dP*dP);
}

function xyzToLabWithWhite(X,Y,Z,Xn,Yn,Zn,ratioPolicy){
 if(!(Number.isFinite(Xn)&&Number.isFinite(Yn)&&Number.isFinite(Zn))||Xn===0||Yn===0||Zn===0) return null;
 const policy=ratioPolicy||'signed_linear';
 if(policy!=='signed_linear'&&policy!=='ratio_floor_1e_minus_9') return null;
 const ratios=[X/Xn,Y/Yn,Z/Zn].map(value=>policy==='ratio_floor_1e_minus_9'&&value<1e-9?1e-9:value);
 const e=216/24389,k=24389/27;
 const f=t=>t>e?Math.cbrt(t):(k*t+16)/116;
 const fx=f(ratios[0]),fy=f(ratios[1]),fz=f(ratios[2]);
 return {L:116*fy-16,a:500*(fx-fy),b:200*(fy-fz)};
}

function deltaE2000(lab1,lab2){ const dL=lab2.L-lab1.L;
 const C1=Math.sqrt(lab1.a*lab1.a+lab1.b*lab1.b);
 const C2=Math.sqrt(lab2.a*lab2.a+lab2.b*lab2.b);
 const Cb=(C1+C2)/2;
 const G=0.5*(1-Math.sqrt(Math.pow(Cb,7)/(Math.pow(Cb,7)+Math.pow(25,7))));
 const a1p=lab1.a*(1+G),a2p=lab2.a*(1+G);
 const C1p=Math.sqrt(a1p*a1p+lab1.b*lab1.b);
 const C2p=Math.sqrt(a2p*a2p+lab2.b*lab2.b);
 const dCp=C2p-C1p;
 let h1p=(a1p===0&&lab1.b===0)?0:Math.atan2(lab1.b,a1p)*180/Math.PI; if(h1p<0) h1p+=360;
 let h2p=(a2p===0&&lab2.b===0)?0:Math.atan2(lab2.b,a2p)*180/Math.PI; if(h2p<0) h2p+=360;
 const Cprod=C1p*C2p;
 let dhp;
 if(Cprod===0){ dhp=0; }
 else {
  dhp=h2p-h1p;
  if(dhp>180) dhp-=360;
  else if(dhp<-180) dhp+=360;
 }
 const dHp=2*Math.sqrt(Cprod)*Math.sin(dhp*Math.PI/360);
 const Lbp=(lab1.L+lab2.L)/2;
 const Cbp=(C1p+C2p)/2;
 let Hbp;
 if(Cprod===0){ Hbp=h1p+h2p; }
 else {
  const dh=Math.abs(h1p-h2p);
  if(dh<=180) Hbp=(h1p+h2p)/2;
  else if(h1p+h2p<360) Hbp=(h1p+h2p+360)/2;
  else Hbp=(h1p+h2p-360)/2;
 }
 const T=1-0.17*Math.cos((Hbp-30)*Math.PI/180)+0.24*Math.cos(2*Hbp*Math.PI/180)+0.32*Math.cos((3*Hbp+6)*Math.PI/180)-0.20*Math.cos((4*Hbp-63)*Math.PI/180);
 const SL=1+0.015*Math.pow(Lbp-50,2)/Math.sqrt(20+Math.pow(Lbp-50,2));
 const SC=1+0.045*Cbp;
 const SH=1+0.015*Cbp*T;
 const RT=-2*Math.sqrt(Math.pow(Cbp,7)/(Math.pow(Cbp,7)+Math.pow(25,7)))*Math.sin(60*Math.exp(-Math.pow((Hbp-275)/25,2))*Math.PI/180);
 return Math.sqrt(Math.pow(dL/SL,2)+Math.pow(dCp/SC,2)+Math.pow(dHp/SH,2)+RT*(dCp/SC)*(dHp/SH));
}

function bartenJND(L){
 const Lc=Math.max(0.005, L);
 const weber=0.0106;
 const dL_over_L = weber * Math.sqrt(100/Lc) ;
 const Yn=100;
 const r=Lc/Yn;
 const fprime = (r>0.008856) ? (1/3)*Math.pow(r,-2/3) : 903.2963/116;
 const dLstar = 116 * fprime * (Lc * dL_over_L) / Yn;
 return Math.max(dLstar, 0.05);
}

function deltaE2000JND(lab1,lab2,Ym,Yref){
 const dL=lab2.L-lab1.L;
 const C1=Math.sqrt(lab1.a*lab1.a+lab1.b*lab1.b);
 const C2=Math.sqrt(lab2.a*lab2.a+lab2.b*lab2.b);
 const Cb=(C1+C2)/2;
 const G=0.5*(1-Math.sqrt(Math.pow(Cb,7)/(Math.pow(Cb,7)+Math.pow(25,7))));
 const a1p=lab1.a*(1+G),a2p=lab2.a*(1+G);
 const C1p=Math.sqrt(a1p*a1p+lab1.b*lab1.b);
 const C2p=Math.sqrt(a2p*a2p+lab2.b*lab2.b);
 const dCp=C2p-C1p;
 let h1p=(a1p===0&&lab1.b===0)?0:Math.atan2(lab1.b,a1p)*180/Math.PI; if(h1p<0) h1p+=360;
 let h2p=(a2p===0&&lab2.b===0)?0:Math.atan2(lab2.b,a2p)*180/Math.PI; if(h2p<0) h2p+=360;
 const Cprod=C1p*C2p;
 let dhp;
 if(Cprod===0){ dhp=0; }
 else {
  dhp=h2p-h1p;
  if(dhp>180) dhp-=360;
  else if(dhp<-180) dhp+=360;
 }
 const dHp=2*Math.sqrt(Cprod)*Math.sin(dhp*Math.PI/360);
 const Cbp=(C1p+C2p)/2;
 let Hbp;
 if(Cprod===0){ Hbp=h1p+h2p; }
 else {
  const dh=Math.abs(h1p-h2p);
  if(dh<=180) Hbp=(h1p+h2p)/2;
  else if(h1p+h2p<360) Hbp=(h1p+h2p+360)/2;
  else Hbp=(h1p+h2p-360)/2;
 }
 const T=1-0.17*Math.cos((Hbp-30)*Math.PI/180)+0.24*Math.cos(2*Hbp*Math.PI/180)+0.32*Math.cos((3*Hbp+6)*Math.PI/180)-0.20*Math.cos((4*Hbp-63)*Math.PI/180);
 let SL;
 if(Ym>0 || Yref>0){
  const Lfield=Math.max(Ym||0, Yref||0, 0.005);
  SL=bartenJND(Lfield);
 } else {
  const Lbp=(lab1.L+lab2.L)/2;
  SL=1+0.015*Math.pow(Lbp-50,2)/Math.sqrt(20+Math.pow(Lbp-50,2));
 }
 const SC=1+0.045*Cbp;
 const SH=1+0.015*Cbp*T;
 const RT=-2*Math.sqrt(Math.pow(Cbp,7)/(Math.pow(Cbp,7)+Math.pow(25,7)))*Math.sin(60*Math.exp(-Math.pow((Hbp-275)/25,2))*Math.PI/180);
 return Math.sqrt(Math.pow(dL/SL,2)+Math.pow(dCp/SC,2)+Math.pow(dHp/SH,2)+RT*(dCp/SC)*(dHp/SH));
}

function bt1886Luminance1dAb(signal,whiteY,blackY){
 if(!Number.isFinite(Number(signal))||!Number.isFinite(Number(whiteY))||!(Number(whiteY)>0)) return null;
 signal=Number(signal); whiteY=Number(whiteY); blackY=Number(blackY);
 if(!Number.isFinite(blackY)||blackY<0) blackY=0;
 if(blackY<=0) return whiteY*Math.pow(signal,2.4);
 if(blackY>=whiteY) return whiteY;
 const gamma=2.4;
 const whiteRoot=Math.pow(whiteY,1/gamma);
 const blackRoot=Math.pow(blackY,1/gamma);
 const denominator=whiteRoot-blackRoot;
 if(denominator<=0) return whiteY*Math.pow(signal,gamma);
 const a=Math.pow(denominator,gamma);
 const b=blackRoot/denominator;
 return a*Math.pow(Math.max(0,signal+b),gamma);
}

function bt1886RelativeLuminance3dRootBlend(signal,whiteY,blackY){
 signal=Math.max(0,Math.min(1,Number(signal)||0));
 whiteY=Number(whiteY); blackY=Number(blackY);
 if(!(whiteY>0)) whiteY=100;
 if(!Number.isFinite(blackY)||blackY<0) blackY=0;
 const range=whiteY-blackY;
 if(range<=1e-9) return Math.pow(signal,2.4);
 let curveBlack=blackY;
 if(curveBlack>=whiteY) curveBlack=0;
 const gamma=2.4;
 const luminance=Math.pow(
  (Math.pow(whiteY,1/gamma)-Math.pow(curveBlack,1/gamma))*signal+
  Math.pow(curveBlack,1/gamma),gamma);
 return Math.max(0,Math.min(1,(luminance-blackY)/range));
}

function calibrationTargetContext(input){
 if(!input||typeof input!=='object') return null;
 const caller=String(input.caller_policy||'').toLowerCase();
 if(caller!=='autocal_1d'&&caller!=='autocal_3d'&&caller!=='browser_chart') return null;
 let mode=String(input.signal_mode||'sdr').toLowerCase();
 if(mode==='hdr') mode='hdr10';
 if(!['sdr','hdr10','hlg','dv'].includes(mode)) return null;
 let gamma=String(input.target_gamma||'bt1886').toLowerCase();
 if(gamma==='1886') gamma='bt1886';
 if(gamma==='pq'||gamma==='smpte2084') gamma='st2084';
 if(!['bt1886','2.2','2.4','srgb','st2084','hlg'].includes(gamma)) return null;
 const peak=input.sdr_signal_peak==null?100:Number(input.sdr_signal_peak);
 if(!Number.isFinite(peak)||peak<1||peak>1000000) return null;
 let transfer;
 if(caller==='browser_chart'){
  if(mode==='hlg'||gamma==='hlg') transfer='hlg_display';
  else if(gamma==='st2084') transfer='pq_absolute';
  else if(gamma==='srgb') transfer='srgb';
  else if(gamma==='2.2') transfer='power_2_2';
  else if(gamma==='bt1886') transfer='bt1886_chart_ab';
  else transfer='power_2_4';
 }else if(caller==='autocal_1d'){
  if(gamma==='srgb') transfer='srgb';
  else if(mode==='dv'&&gamma==='st2084') transfer='dv_gamma_2_2_tunnel';
  else if(gamma==='st2084') transfer='pq_normalized';
  else if(gamma==='2.2') transfer='power_2_2';
  else if(gamma==='bt1886') transfer='bt1886_1d_ab';
  else transfer='power_2_4';
 }else{
  if(gamma==='bt1886') transfer='bt1886_3d_root_blend_relative';
  else if(gamma==='srgb') transfer='srgb';
  else if(gamma==='st2084') transfer='pq_normalized';
  else if(gamma==='2.2') transfer='power_2_2';
  else transfer='power_2_4';
 }
 const context={
  schema:'pgen-calibration-target-context-v1',context_version:1,
  caller_policy:caller,signal_mode:mode,target_gamma:gamma,
  sdr_signal_peak:peak,transfer_policy:transfer,
  normalization_policy:caller==='autocal_3d'?'relative_black_removed':
   (caller==='browser_chart'?(transfer==='pq_absolute'||transfer==='hlg_display'?'absolute_nits':'white_scaled'):
    (mode==='hdr10'&&gamma==='st2084'?'absolute_nits_capped_at_white':'white_scaled')),
  dv_tunnel_policy:mode==='dv'&&gamma==='st2084'?
   'gamma_2_2_when_target_label_st2084':'none'
 };
 if(caller==='browser_chart'){
  const finiteOr=(value,fallback)=>Number.isFinite(Number(value))?Number(value):fallback;
  const signalPeak=finiteOr(input.signal_peak_nits,mode==='sdr'?100:1000);
  const white=finiteOr(input.white_nits,0);
  const black=finiteOr(input.black_nits,0);
  if(signalPeak<0||signalPeak>10000||white<0||black<0) return null;
  const patternRange=String(input.pattern_range||'full').toLowerCase();
  const transportRange=String(input.transport_range||patternRange).toLowerCase();
  if(!['full','limited'].includes(patternRange)||!['full','limited'].includes(transportRange)) return null;
  const patternBits=input.pattern_bits==null?(mode==='dv'?12:8):Number(input.pattern_bits);
  const transportBits=input.transport_bits==null?patternBits:Number(input.transport_bits);
  if(![8,10,12].includes(patternBits)||![8,10,12].includes(transportBits)) return null;
  const headroom=String(input.headroom_strategy||'none').toLowerCase();
  if(!['none','legal_superwhite','extended_sdr','lg_sdr26_ladder'].includes(headroom)) return null;
  const headroomMax=finiteOr(input.headroom_max_percent,100);
  if(headroomMax<100||(headroom==='none'&&headroomMax!==100)) return null;
  let dvMap=String(input.dv_map_mode==null?'':input.dv_map_mode).toLowerCase();
  if(dvMap==='1') dvMap='absolute';
  if(dvMap==='2') dvMap='relative';
  if(!dvMap) dvMap=mode==='dv'?'relative':'none';
  if(!['none','absolute','relative'].includes(dvMap)||(mode!=='dv'&&dvMap!=='none')) return null;
  let dvInterface=String(input.dv_interface==null?'':input.dv_interface).toLowerCase();
  if(dvInterface==='0') dvInterface='standard';
  if(dvInterface==='1'||dvInterface==='ll') dvInterface='low_latency';
  if(!dvInterface) dvInterface=mode==='dv'?'standard':'none';
  if(!['none','standard','low_latency'].includes(dvInterface)||(mode!=='dv'&&dvInterface!=='none')) return null;
  context.gamma_exponent=gamma==='2.2'?2.2:((gamma==='2.4'||gamma==='bt1886')?2.4:0);
  context.white_nits=white;
  context.black_nits=black;
  context.signal_peak_nits=signalPeak;
  context.pattern_range=patternRange;
  context.transport_range=transportRange;
  context.pattern_bits=patternBits;
  context.transport_bits=transportBits;
  context.headroom_strategy=headroom;
  context.headroom_max_percent=headroomMax;
  context.dv_map_mode=dvMap;
  context.dv_interface=dvInterface;
  context.target_gamut=String(input.target_gamut||'auto').toLowerCase();
  if(mode==='dv') context.dv_tunnel_policy=dvMap==='absolute'?
   'st2084_absolute_map':'gamma_2_2_relative_map';
 }
 return Object.freeze(context);
}

function targetLinearForContext(context,signal){
 if(!context||context.schema!=='pgen-calibration-target-context-v1'||context.context_version!==1) return null;
 signal=Number(signal)||0;
 if(context.caller_policy==='autocal_3d') signal=Math.max(0,Math.min(1,signal));
 else{
  if(signal<0) signal=0;
  if(signal>1&&context.signal_mode!=='sdr') signal=1;
  if(signal<=0) return 0;
 }
 switch(context.transfer_policy){
  case 'srgb': return srgbDecodeUnbounded(signal);
  case 'power_2_2':
  case 'dv_gamma_2_2_tunnel': return Math.pow(signal,2.2);
  case 'pq_normalized': return meterChartPqDecodeNormalized(signal)/10000;
  default: return Math.pow(signal,2.4);
 }
}

function targetLuminanceForContext(context,stimulus,whiteY,blackY){
 if(!context||context.caller_policy!=='autocal_1d'||!Number.isFinite(Number(stimulus))||!(Number(whiteY)>0)) return null;
 stimulus=Number(stimulus); whiteY=Number(whiteY);
 const signalPeak=context.signal_mode==='sdr'?context.sdr_signal_peak:100;
 let signal=stimulus/signalPeak;
 if(signal>1&&(context.signal_mode!=='sdr'||signalPeak===100)) signal=1;
 if(context.signal_mode==='sdr'&&context.transfer_policy==='bt1886_1d_ab'&&Number(blackY)>0)
  return bt1886Luminance1dAb(Math.max(0,signal),whiteY,Number(blackY));
 if(stimulus<=0) return 0;
 if(signal>1&&context.signal_mode!=='sdr') signal=1;
 if(context.signal_mode==='hdr10'&&context.target_gamma==='st2084')
  return Math.min(whiteY,meterChartPqDecodeNormalized(signal));
 return whiteY*targetLinearForContext(context,signal);
}

function targetRelativeLuminanceForContext(context,signal,whiteY,blackY){
 if(!context||context.caller_policy!=='autocal_3d') return null;
 if(context.transfer_policy==='bt1886_3d_root_blend_relative')
  return bt1886RelativeLuminance3dRootBlend(signal,whiteY,blackY);
 return targetLinearForContext(context,signal);
}

if(typeof module!=='undefined'&&module.exports){
 module.exports=Object.freeze({
  D65,clampNum,pqEncodeNormalized,meterChartPqEncodeNormalized,
  meterChartPqDecodeNormalized,srgbDecodeUnbounded,srgbDecodeBounded,
  srgbEncodeUnbounded,srgbEncodeBounded,gammaEotf,srgbEotf,bt1886Eotf,
  meterPowerTargetLuminance,meterSrgbTargetLuminance,browserTargetLuminanceForContext,
  signalCodePolicy,signalPercentToCode,codeToSignalFraction,signalCodeNominalRange,
  matrix3VectorMultiply,matrix3Multiply,
  saturationStimulusForGamuts,
  xyToUnitXyz,meterBradfordAdaptXyz,meterCctFromXy,xyzToICtCp,deltaEITP,
  deltaEITPChromaOnly,xyzToLabWithWhite,deltaE2000,bartenJND,
  deltaE2000JND,bt1886Luminance1dAb,
  bt1886RelativeLuminance3dRootBlend,calibrationTargetContext,
  targetLinearForContext,targetLuminanceForContext,
  targetRelativeLuminanceForContext
 });
}
