// Pure offline checks. Test luminances/Delta E are synthetic: this verifies
// coverage, coordinates and context selection, not physical calibration.
const fs=require('fs'),path=require('path'),vm=require('vm'),assert=require('node:assert/strict');
const root=path.resolve(__dirname,'../../usr/share/PGenerator');
const app=fs.readFileSync(path.join(root,'webui-app.js'),'utf8');
const workspace=fs.readFileSync(path.join(root,'webui-workspace.js'),'utf8');
const automation=fs.readFileSync(path.join(root,'webui-automation.js'),'utf8');
const cases=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const elements={
 signal_mode:{value:'dv'},rgb_quant_range:{value:'2'},color_format:{value:'0'},max_bpc:{value:'8'},
 meterTargetGamma:{value:'st2084'},dv_map_mode:{value:'1'},dv_interface:{value:'0'},
 meterTargetGamut:{value:'bt709'},max_luma:{value:'1000'}
};
const rendered=[];
let axisLabels=[];
const ctx={w:1100,h:240,save(){},restore(){},beginPath(){},rect(){},clip(){},fillRect(){},
 fillText(value){rendered.push(value)}};
const c={console,window:{},config:{},document:{getElementById:id=>elements[id]||{}},
 meterActiveSeriesType:'greyscale',meterActiveSeriesPoints:26,meterActiveSeriesSignalMode:'dv',
 meterActiveSeriesTargetGamma:'2.2',meterActiveSeriesDvMapMode:'1',meterActiveCalibrationTargetContext:null,
 // An unrelated live HDR calibration must not retarget a saved report.
 meterAutoCalLatestStatus:{status:'running',signal_mode:'hdr10',target_gamma:'2.2',ddc_layout:'hdr20'},
 meterAutoCalRunning:true,meterFullAutoCalRunning:true,
 meterReadings:[],meterWhiteReading:null,meterPreviewSignalCodePolicies:new Map(),
 meterGreyTvControlsActive:()=>false,meterUseLgGreyscale21:()=>false,
 getVal:id=>elements[id]?.value||'',
  meterLivePlotPublish:()=>{},meterLiveCiePublish:()=>{},meterLiveCieInset:()=>{},
 getChartCtx:()=>ctx,meterGreyRefMode:()=> 'absolute',meterSeparateLumEnabled:()=>false,
 meterDeltaEForm:()=> 'deitp',meterDeltaEFormLabel:()=> 'ΔE ITP',meterGrayWorldWeight:()=>1,
 meterGreyRefModeLabel:()=> 'Absolute Y w/o gamma',meterGreyscaleChartWhiteReference:()=>({Y:100,luminance:100}),
 meterChartBlackLevel:()=>0,meterGreyDeltaResult:rd=>({value:rd.testDelta??.2}),
 meterApplyTopYZoom:(_id,max)=>({max}),meterGreyscaleRotateXLabels:()=>true,
 meterGreyscaleChartPad:()=>({t:20,r:15,b:30,l:55}),drawDashedLine(){},meterDrawDeltaSummary(){},
 pgThemeColor:(_key,fallback)=>fallback,meterGreyscaleChartLabel:step=>step.name,
 drawChartGrid(_ctx,o){axisLabels=Array.from({length:o.xSteps+1},(_,i)=>o.xLabel(i));return {
  w:1030,h:190,dw:1000,pad:o.pad,toX:x=>55+x*1000,toY:y=>210-y*190};}
};
vm.createContext(c);
function load(source,name){
 const m=source.match(new RegExp('(async )?function '+name+'\\([^]*?\\n\\}'));
 assert(m,'production function found: '+name);vm.runInContext(m[0],c);
}
vm.runInContext(fs.readFileSync(path.join(root,'webui-colour-math.js'),'utf8'),c);
for(const name of [
 'meterSnapshotReportContext','meterIsLimitedRange','meterOutputFormatValue','meterOutputIsRgb',
 'meterPatchUsesVideoRange','meterPatchBitDepth','meterPatchInputMax','meterSdr26UsesSuperWhiteLadder',
 'meterChartSignalMode','meterActiveChartSignalMode','meterChartIsHdr','meterChartIsPq','meterChartIsHlg','meterChartIsDv',
 'meterDvMapModeValue','meterUseLgAutoCal26','meterGreyAllowsHeadroomTargets',
 'meterHdrAutoCalUsesPowerGammaChartMath','meterGreyChartTargetGammaSelection','meterGreyChartUsesPqTarget',
 'meterReadingPlotIre','meterReadingDisablesAutoCalTargetReference','meterReadingIsAutoCalChartHidden',
 'meterLgAutoCalChartReferenceWhite','meterFilterLgAutoCalChartItems','meterGreyChartPlotIre','meterGreyChartStimulusIre',
 'meterCalibrationTargetContextFromSource','meterGreySignalFractionFromCode',
 'meterPreviewSignalCodePolicy','meterActiveSeriesCodesAre8Bit'
])load(app,name);
c.PG_CHART_FOCUS_DIM=Number(workspace.match(/const PG_CHART_FOCUS_DIM=([\d.]+)/)[1]);
for(const name of ['meterChartFocusEnabled','meterChartFocusIndex','meterChartFocusApply','meterGreyCategoryChartX','drawDeltaEChart','meterGreyEotfLuminancePlotIre','meterEotfLuminanceAxisMax'])load(workspace,name);
load(automation,'pgAutomationGraphSnapshot');

for(const test of cases){
 const {name,item,grey}=test;
 if(item.signal_format==='hdr10'){
  const policy=c.signalCodePolicy({signal_mode:'hdr10',pattern_range:item.signal_range,max_bpc:item.max_bpc,
   hdr20_codes:1,hdr20_use_limited:1,hdr20_full:item.signal_range==='2'?1:0});
  let previous=-1;
  for(const step of [...grey.steps].sort((a,b)=>a.ire-b.ire)){
   const encoded=c.signalPercentToCode(policy,step.ire);
   assert.equal(encoded.code,step.r,name+' JS/Perl parity at '+step.ire+'%');
   assert(encoded.code>previous,name+' monotonic HDR codes at '+step.ire+'%');
   previous=encoded.code;
  }
 }
 const snap=c.pgAutomationGraphSnapshot({key:'grey',phase:'calibration',snapshot:{...grey,readings:[]}},item);
 c.window._meterSnapshotReportContext=snap;
 // Deliberately leave stale DV mode and unrelated live worker globals.
 c.meterActiveSeriesSignalMode='dv';
 const ycc=item.signal_format==='sdr'&&item.color_format!=='0'&&item.signal_range==='1';
 assert.equal(c.meterActiveChartSignalMode(),item.signal_format,name+' saved signal');
 assert.equal(c.meterOutputFormatValue(),item.color_format,name+' saved format');
 assert.equal(c.meterIsLimitedRange(),item.signal_range==='1',name+' saved transport range');
 assert.equal(c.meterPatchBitDepth(),item.signal_format==='dv'?12:item.max_bpc,name+' source depth');
 assert.equal(c.meterGreyAllowsHeadroomTargets(),ycc,name+' headroom');
 assert.equal(c.meterUseLgAutoCal26(26),true,name+' saved chart works without a live TV');
 assert.equal(c.meterGreyChartTargetGammaSelection(),item.signal_format==='sdr'?'2.4':'2.2',name+' saved gamma');
 const target=c.meterCalibrationTargetContextFromSource(snap,{},{});
 assert(target,name+' accepted target context');
 assert.equal(target.caller_policy,'browser_chart',name+' worker solver context is adapted to browser decoding');
 assert.equal(target.pattern_bits,item.signal_format==='dv'?12:item.max_bpc,name+' target source depth');
 assert.equal(target.transport_bits,item.max_bpc,name+' target transport depth');
 assert.equal(target.pattern_range,item.signal_format==='dv'?'limited':item.signal_range==='1'?'limited':'full',name+' target source range');
 assert.equal(target.headroom_strategy==='lg_sdr26_ladder',ycc,name+' target headroom');
 c.meterActiveCalibrationTargetContext=target;
 const whiteCode=grey.steps.find(s=>Number(s.ire)===100).r;
 const whiteFraction=c.meterGreySignalFractionFromCode(whiteCode);
 assert(Math.abs(whiteFraction-(ycc?100/109:1))<1e-10,name+' actual white code decodes on the correct basis');
 if(ycc){
  const headroom=c.meterGreySignalFractionFromCode(grey.steps.find(s=>Number(s.ire)===105).r);
  const peak=c.meterGreySignalFractionFromCode(grey.steps.find(s=>Number(s.ire)===109).r);
  assert(whiteFraction<headroom&&headroom<peak,name+' real context preserves distinct 100/105/109 luminance targets');
 }
 if(item.signal_format==='dv')assert.equal(c.meterDvMapModeValue(),'2',name+' calibration relative map');
 c.meterActiveSeriesSignalMode=item.signal_format;
 // Mirror the worker's measured ladder, omitting the separate YCbCr legal
 // white reference, not inventing a measurement at every possible label.
 const readings=grey.steps.filter(s=>!(ycc&&s.ire===100)).map(s=>({
  ...s,Y:1,luminance:1,name:'worker_'+s.ire,autocal_white_reference:s.ire===(ycc?109:100),
  ...(ycc&&s.ire===109?{autocal_reference_only:true,autocal_legal_white_anchor:true}: {})
 }));
 const steps=c.meterFilterLgAutoCalChartItems(grey.steps).sort((a,b)=>a.ire-b.ire);
 const visible=c.meterFilterLgAutoCalChartItems(readings).sort((a,b)=>a.ire-b.ire);
 rendered.length=0;c.drawDeltaEChart(visible,steps,{},readings);
 assert.equal(rendered.filter(v=>v==='0.20').length,steps.length,name+' every expected label has a bar');
 assert(axisLabels.includes(ycc?'109%':'100%'),name+' correct endpoint label');
 assert.equal(visible.at(-1).ire,ycc?109:100,name+' measured endpoint retained');
 assert.equal(c.meterEotfLuminanceAxisMax(steps),ycc?110:100,name+' luminance axis extent');
 // Verification must use PQ for HDR/DV, even while another 2.2 calibration runs.
 const verify=c.pgAutomationGraphSnapshot({key:'greyscale-21',phase:'post',snapshot:{...test.series,readings:[]}},item);
 c.window._meterSnapshotReportContext=verify;
 assert.equal(c.meterHdrAutoCalUsesPowerGammaChartMath(),false,name+' no live calibration leakage into verification');
 assert.equal(c.meterGreyChartUsesPqTarget(),item.signal_format!=='sdr',name+' verification transfer');
 if(item.signal_format==='dv')assert.equal(c.meterDvMapModeValue(),'1',name+' verification absolute map');
}

// Legacy worker snapshots lack transport fields and sometimes even targets.
for(const signal of ['sdr','hdr10','dv']){
 const item={signal_format:signal,color_format:signal==='dv'?'0':'1',signal_range:signal==='dv'?'2':'1',max_bpc:signal==='dv'?8:10,target_gamma:signal==='sdr'?'2.4':'st2084'};
 const saved={steps:[{ire:100}],readings:[{Y:100}]},before=JSON.stringify(saved);
 const snap=c.pgAutomationGraphSnapshot({key:'grey',phase:'calibration',snapshot:saved},item);
 assert.equal(snap.color_format,item.color_format,signal+' legacy job format fallback');
 assert.equal(snap.target_gamma,signal==='sdr'?'2.4':'2.2',signal+' legacy phase target fallback');
 assert.equal(JSON.stringify(saved),before,'snapshot preparation never mutates saved evidence');
}
const dvProfile=c.pgAutomationGraphSnapshot({key:'dv-profile',phase:'calibration',snapshot:{readings:[{Y:100}]}},
 {signal_format:'dv',target_gamma:'st2084',color_format:'0',signal_range:'2',max_bpc:8});
assert.equal(dvProfile.target_gamma,'2.2','DV native profile stays in the Relative calibration phase');
assert.equal(dvProfile.dv_map_mode,'2','DV native profile does not inherit Absolute verification mode');
for(const method of ['matrix','hybrid']){
 const volume=c.pgAutomationGraphSnapshot({key:'3d',phase:'calibration',snapshot:{readings:[{Y:100}]}},
  {signal_format:method==='matrix'?'hdr10':'sdr',calibration:{method}});
 assert.equal(volume.cache_key,method==='matrix'?'lg-3d-matrix-profile':'lg-3d-lattice-profile-automation',
  method+' uses native profile context rather than an accuracy-sweep context');
}
for(const signal of ['sdr','hdr10']){
 const sparse=c.pgAutomationGraphSnapshot({key:'grey',phase:'calibration',snapshot:{readings:[{Y:100}]}},{signal_format:signal});
 assert.equal(sparse.color_format,'0','sparse legacy recipe uses runner colour-format default');
 assert.equal(sparse.max_bpc,10,'sparse legacy recipe uses runner bit-depth default');
 assert.equal(sparse.signal_range,'2','sparse legacy recipe uses runner range default');
 assert.equal(sparse.transport_context_inferred,true,'unrecorded context assumptions are explicitly flagged');
}
const profileState=JSON.parse(fs.readFileSync(process.argv[3],'utf8'));
const profileCopy=JSON.stringify(profileState);
const profileSnapshot=c.pgAutomationGraphSnapshot({key:'dv-profile',phase:'calibration',snapshot:profileState},
 {signal_format:'dv',target_gamma:'st2084',color_format:'0',signal_range:'2',max_bpc:8});
assert.equal(profileSnapshot.cache_key,'lg-dv-profile','real worker enters native CIE-only profile context');
assert.equal(profileSnapshot.readings.length,5,'all five measured xyY steps reach the renderer');
assert.deepEqual(Array.from(profileSnapshot.readings,r=>[r.name,r.x,r.y,r.luminance]),
 profileState.steps.map(r=>[r.name,r.x,r.y,r.luminance]),'profile adaptation preserves measured values exactly');
assert.equal(profileSnapshot.readings[0].luminance,0,'black is a real profile measurement');
assert.equal(JSON.stringify(profileState),profileCopy,'real saved profile is not mutated');
load(app,'meterIs3dLutProfileChartContext');
load(workspace,'meterBuildReportSummaryCards');
c.meterActiveSeriesKey='lg-dv-profile';c.meterActiveSeriesType='colors';
c.meterReadings=profileSnapshot.readings;c.meterReadingHasLuminance=r=>r.luminance!=null;
assert.doesNotMatch(c.meterBuildReportSummaryCards(),/Average|ΔE/,'native profile is not falsely graded against a reference gamut');
assert.match(c.meterBuildReportSummaryCards(),/500.0 cd\/m²/,'native profile reports measured peak');
c.meterActiveSeriesType='greyscale';
// The historical recovery path must not replace recorded steps with a live
// preset (including its dark-detail or super-white settings).
const recovery={meterSeriesStatusIsIccWorkflow:()=>false,meterSeriesChartRevision:0,
 meterActiveSeriesKey:'greyscale-26',meterGreyscaleScrollRatio:0,meterSharedSeriesId:null,
 meterCurrentPatchStep:null,meterServerSeriesIsSelection:()=>false,
 meterCanonicalRecoveredSteps:()=>{throw new Error('must not rebuild recorded steps')},
 meterRecoveryDisplaySteps:()=>{throw new Error('must not expand recorded steps')},
 meterSetActiveSeriesChartContext:s=>{recovery.captured=s;throw new Error('captured before UI side effects')}};
vm.createContext(recovery);
const recoverCode=app.match(/function meterRecoverSeries\([^]*?\n\}/)[0];
vm.runInContext(recoverCode,recovery);
for(const test of cases){
 assert.throws(()=>recovery.meterRecoverSeries({
  ...test.grey,snapshot_report:true,status:'complete',total_steps:test.grey.steps.length,series_id:null
 }),/captured before UI side effects/);
 assert.equal(recovery.captured.steps,test.grey.steps,test.name+' authoritative step array retained');
}

// Exercise the real asynchronous report wrapper, including a UI update between
// paints and restoration on failure. No DOM change handler or API is called.
Object.assign(c,{
 meterActiveSeriesKey:null,_selectedColorReadingName:null,_colorDetailPinned:false,meterCurrentPatchStep:null,
 meterSelectedThumbIre:null,meterSeriesCache:{},meterFullAutoCalCloneValue:x=>JSON.parse(JSON.stringify(x)),
 meterSeriesSnapshotHasReadings:s=>s.readings.length>0,meterPersistSeriesCache:()=>{},
 meterRecoverSeries:s=>{assert.equal(s.snapshot_report,true);c.recovered=s;},
 meterBuildCurrentSeriesReportSection:()=>c.meterGreyChartTargetGammaSelection()
});
load(workspace,'meterFullAutoCalBuildSnapshotReportSections');
(async()=>{
 const original={sentinel:true};
 c.window._meterSnapshotReportContext=original;
 c.window._meterSnapshotReportTargetGamma='prior-target';
 for(const signal of ['sdr','hdr10','dv']){
  const test=cases.find(t=>t.item.signal_format===signal);
  for(const phase of ['calibration','post']){
   const saved=phase==='calibration'?test.grey:test.series;
   const snapshot=c.pgAutomationGraphSnapshot({phase,key:phase==='calibration'?'grey':'greyscale-21',
    snapshot:{...saved,readings:[{Y:100}]}},test.item);
   c.meterPrepareCurrentSeriesForReport=async()=>{
    await Promise.resolve();
    // Mimic an unrelated selector refresh after snapshot recovery.
    elements.max_bpc.value='8';elements.color_format.value='2';
    elements.rgb_quant_range.value='2';elements.dv_map_mode.value='1';elements.meterTargetGamma.value='srgb';
    assert.equal(c.meterOutputFormatValue(),String(snapshot.color_format),signal+' report format survives async refresh');
    assert.equal(c.meterPatchBitDepth(),signal==='dv'?12:snapshot.max_bpc,signal+' report source depth survives async refresh');
    assert.equal(c.meterGreyChartTargetGammaSelection(),snapshot.target_gamma,signal+' report target survives async refresh');
   };
   assert.equal(await c.meterFullAutoCalBuildSnapshotReportSections([{snapshot}]),snapshot.target_gamma);
   assert.equal(c.window._meterSnapshotReportContext,original,'outer scope restored');
   assert.equal(c.window._meterSnapshotReportTargetGamma,'prior-target','outer target restored');
  }
 }
 c.meterPrepareCurrentSeriesForReport=async()=>{throw new Error('test paint failure')};
 await assert.rejects(c.meterFullAutoCalBuildSnapshotReportSections([{snapshot:{...cases[0].grey,readings:[{Y:100}]}}]),/test paint failure/);
 assert.equal(c.window._meterSnapshotReportContext,original,'scope restored after failure');
 assert.equal(c.window._meterSnapshotReportTargetGamma,'prior-target','target restored after failure');
 console.log('PASS automation transport: '+cases.length+' runner-to-chart cases, SDR/HDR/DV endpoints, immutable recovery and asynchronous report isolation');
})().catch(e=>{console.error(e);process.exitCode=1});
