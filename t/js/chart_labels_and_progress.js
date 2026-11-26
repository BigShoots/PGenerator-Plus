// Regression for PR 14 test report P26, P27 and P30: HDR panel-clip readings
// leave the gamma line and average, the absolute EOTF chart is named for what
// it plots, and held-run progress labels name the actual state.
const fs=require('fs'),path=require('path'),vm=require('vm'),assert=require('node:assert/strict');
const read=f=>fs.readFileSync(path.join(__dirname,'../../usr/share/PGenerator/'+f),'utf8');
const grab=(source,name)=>{const code=source.match(new RegExp('function '+name+'\\([^]*?\\n\\}'))?.[0];assert.ok(code,name+' found');return code;};
const ws=read('webui-workspace.js'),app=read('webui-app.js'),auto=read('webui-automation.js');

// P26: G3 HDR10 greyscale from run 20260917-085726-914ca1, which clips at
// 1,334.9 cd/m2 from the 80% step.
{
 const ctx={};vm.createContext(ctx);
 vm.runInContext(ws.match(/const METER_HDR_GAMMA_CLIP_FRACTION=[^;]+;/)[0]+'\n'+grab(ws,'meterGammaReadingAtPanelClip')+';this.clip=meterGammaReadingAtPanelClip;',ctx);
 const readings=[[5,0.06],[10,0.42],[15,1.09],[20,2.56],[25,5.32],[30,10.12],[35,18.18],[40,32.12],[45,53.73],[50,88.93],[55,147.93],[60,239.61],[65,367.68],[70,587.05],[75,931.76],[80,1319.6],[85,1324.81],[90,1328.73],[95,1332.97]];
 const white=1334.92;
 const clipped=readings.filter(([ire,y])=>ctx.clip(y,white,ire,true)).map(([ire])=>ire);
 assert.deepEqual(clipped,[80,85,90,95],'the steps held at the panel clip are identified; the 75% roll-off is not');
 const gamma=([ire,y])=>Math.log(y/white)/Math.log(ire/100);
 const kept=readings.filter(([ire,y])=>!ctx.clip(y,white,ire,true)).map(gamma);
 assert.ok(kept.every(g=>g>1),'no near-zero values remain in the plotted line');
 const avg=kept.reduce((a,b)=>a+b,0)/kept.length;
 assert.ok(Math.abs(avg-3.48)<0.01,'the average over unclipped steps is 3.48, not 2.76 (got '+avg.toFixed(3)+')');
 assert.equal(ctx.clip(99,100,95,false),false,'SDR readings are never treated as clipped');
 assert.equal(ctx.clip(white,white,100,true),false,'the 100% white reference is not a clip reading');
}
// P26 round 3: the clip is excluded from its onset upward on every surface.
{
 const white=1334.92;
 const readings=[[5,0.06],[10,0.42],[15,1.09],[20,2.56],[25,5.32],[30,10.12],[35,18.18],[40,32.12],[45,53.73],[50,88.93],[55,147.93],[60,239.61],[65,367.68],[70,587.05],[75,931.76],[80,1319.6],[85,1290.2],[90,1328.73],[95,1332.97]]
  .map(([ire,y])=>({ire,luminance:y,Y:y,r_code:ire,g_code:ire,b_code:ire}));
 const whiteRd={ire:100,luminance:white,Y:white,r_code:100,g_code:100,b_code:100};
 let hdr=true;
 const calls={};
 const record=name=>(...args)=>{(calls[name]=calls[name]||[]).push(args);return name==='drawChartGrid'?{}:undefined;};
 const elements={chartGammaValueLabel:{textContent:''},meterPerChannelGamma:{checked:true}};
 const ctx={Math,Number,Object,Array,isFinite,
  document:{getElementById:id=>elements[id]||null},
  meterLivePlotPublish:()=>{},meterLiveCiePublish:()=>{},meterLiveCieInset:()=>{},
  getChartCtx:()=>({}),meterChartIsHlg:()=>false,meterGreyTargetUsesPq:()=>hdr,meterChartIsHdr:()=>hdr,meterChartIsDv:()=>false,
  meterTargetGammaLabel:()=>'ST 2084',meterUseLgAutoCal26GammaAxis:()=>false,meterGreyscaleChartWhiteReference:()=>whiteRd,
  meterFilterGammaChartItems:x=>x,meterReadingLuminanceNits:rd=>rd.luminance,meterChartBlackLevel:()=>0,meterFilterEotfLuminanceChartItems:x=>x,
  meterGammaValueReferenceY:()=>white,meterGreyTargetPeak:y=>y,meterReadingGammaAnalysisIre:rd=>rd.ire,meterGammaPreviousSeriesReading:()=>null,
  effectiveGammaTopSlope:()=>null,meterReadingAnalysisIre:rd=>rd.ire,
  // A PQ target clipped at the panel peak has the same near-zero tail.
  meterGreyTargetGamma:ire=>ire>=80&&ire<100?0.01:3.5,
  meterGreyscaleTargetIreForStep:step=>step.ire,meterGreyscaleTargetCodeForStep:step=>step.ire,
  meterGammaAxisCenteredOnTarget:(m,t)=>{calls.axis=[m,t];return {min:0,max:5};},meterApplyLinearYZoom:(id,min,max)=>({min,max}),
  meterGreyscaleRotateXLabels:()=>false,meterGreyscaleChartPad:p=>p,meterGreyscaleChartLabel:()=>'',meterGammaChartX:(step,steps,idx)=>idx,
  drawChartGrid:record('drawChartGrid'),drawDashedLine:record('drawDashedLine'),drawLine:record('drawLine'),drawDots:record('drawDots'),drawGammaLegend:record('drawGammaLegend'),drawGammaValuePreset:record('preset')};
 vm.createContext(ctx);
 ctx.meterReadings=[];ctx.meterChartSignalMode=()=>hdr?'hdr10':'sdr';
 vm.runInContext(['meterGammaSignalFraction','effectiveGamma','meterGreyscaleGammaValue'].map(n=>grab(app,n)).join('\n')+'\n'
  +ws.match(/const METER_HDR_GAMMA_CLIP_FRACTION=[^;]+;/)[0]+'\n'
  +ws.match(/const PG_CHART_FOCUS_DIM=[^;]+;/)[0]+'\n'
  +['meterChartFocusEnabled','meterChartFocusIndex','meterChartFocusApply','meterGammaReadingAtPanelClip','meterGammaClipAwareView','meterGammaClipOnsetIre','meterGammaExcludedAtClip','drawGammaValueChart','meterBuildGreyscaleReportTable'].map(n=>grab(ws,n)).join('\n')
  +';this.onset=meterGammaClipOnsetIre;this.excluded=meterGammaExcludedAtClip;this.aware=meterGammaClipAwareView;this.draw=drawGammaValueChart;this.table=meterBuildGreyscaleReportTable;',ctx);
 assert.equal(ctx.onset(readings,white,true),80,'the clip onset is the lowest step at the clip');
 assert.equal(ctx.onset(readings,white,false),null,'there is no onset outside a clip-aware view');
 assert.ok(ctx.excluded(85,80),'a step above the onset that noise put just outside the band is still excluded');
 assert.ok(!ctx.excluded(75,80)&&!ctx.excluded(100,80)&&!ctx.excluded(85,null),'the roll-off, the white reference and unclipped series are kept');
 hdr=false;assert.equal(ctx.aware(),false,'SDR is not clip-aware');hdr=true;assert.equal(ctx.aware(),true,'HDR10, DV and HLG views are');
 ctx.meterGreyTargetUsesPq=()=>false;ctx.meterChartIsDv=()=>true;
 assert.equal(ctx.aware(),true,'including a Dolby Vision view whose target is not PQ');
 ctx.meterGreyTargetUsesPq=()=>hdr;ctx.meterChartIsDv=()=>false;
 const steps=[...readings,whiteRd].map(rd=>({ire:rd.ire}));
 const map=Object.fromEntries([...readings,whiteRd].map(rd=>[rd.ire,{...rd,_gamma_rgb:{r:rd.ire>=80?0.02:3.4,g:3.5,b:3.6}}]));
 ctx.draw([...readings,whiteRd],steps,map);
 const [measured,targets]=calls.axis;
 assert.equal(measured.length,15,'the measured line keeps 5% to 75% only');
 assert.ok(measured.every(g=>g>1),'with no zero tail, including the noisy 85% step');
 assert.equal(targets.length,15,'the target line leaves the clipped steps out too');
 assert.ok(targets.every(g=>g>1),'so the axis is not stretched to zero by the clipped target');
 const lines=calls.drawLine.map(args=>args[2]);
 const clippedX=x=>x>=15&&x<=18;
 assert.equal(lines.length,4,'the measured line and three per-channel lines are drawn');
 assert.ok(lines.every(pts=>pts.length>1&&!pts.some(([x])=>clippedX(x))),'no plotted line (measured or per-channel) includes a clipped step');
 assert.ok(calls.drawDashedLine.length>0&&calls.drawDashedLine.every(args=>!args[2].some(([x])=>clippedX(x))),'nor does the dashed target line');
 assert.match(calls.drawGammaLegend[0][3],/panel clip from 80% excluded/,'the legend names the onset');
 // Report table.
 Object.assign(ctx,{meterGreyscaleReportReadings:()=>({visible:[...readings,whiteRd],white:whiteRd,raw:[...readings,whiteRd]}),meterGreyRefMode:()=>'relative',meterDeltaEForm:()=>'de2000',
  meterDeltaEFormLabel:()=>'dE2000',rgbBalance:()=>({R:100,G:100,B:100}),meterColorDeltaE2000:()=>1,meterGrayWorldWeight:()=>0});
 const html=ctx.table();
 const cell=ire=>html.match(new RegExp('<tr[^>]*><td>'+ire+'%</td>(?:<td>[^<]*</td>){4}<td>([^<]*)</td>'))[1];
 assert.equal(cell(85),'clip','the report table marks a clipped step instead of printing a zero gamma');
 assert.equal(cell(80),'clip','from the onset');
 assert.match(cell(75),/^\d\.\d\d$/,'and keeps the roll-off value');
 hdr=false;
 assert.match(ctx.table().match(/<tr[^>]*><td>85%<\/td>(?:<td>[^<]*<\/td>){4}<td>([^<]*)<\/td>/)[1],/^0\.\d\d$/,'SDR tables are unchanged');
 hdr=true;
}
// CSV and tooltip use the same onset rule.
{
 const exportCode=grab(ws,'meterExportCSV');
 assert.match(exportCode,/meterGammaClipOnsetIre\(sorted\.filter\(isGrey\),Lw,meterGammaClipAwareView\(\),csvIre\)/,'the CSV finds the onset over its grey rows');
 assert.match(exportCode,/meterGammaExcludedAtClip\(ire,csvClipOnset\)\)\?null:effectiveGamma/,'and blanks the Gamma column from it');
 const hover=grab(ws,'chartHandleHover');
 assert.match(hover,/gammaAtClip\?null:meterGreyscaleGammaValue/,'the tooltip never computes a clipped gamma');
 assert.match(hover,/Gamma: at panel clip \(excluded\)/,'and says the step is at the clip');
}
// P27: the absolute EOTF view is titled as tracking, not error.
{
 const label={textContent:'',title:''};let normalized=false;
 let hdrView=true;
 const ctx={document:{getElementById:()=>label},meterHdrDiffuseWhiteOverride:()=>null,meterChartIsPq:()=>true,meterChartIsHdr:()=>hdrView,meterEotfNormalizedEnabled:()=>normalized};
 vm.createContext(ctx);vm.runInContext(grab(app,'meterUpdateEotfChartLabel')+';this.update=meterUpdateEotfChartLabel;',ctx);
 ctx.update();
 assert.equal(label.textContent,'EOTF Tracking, absolute','the absolute view is named for what it plots');
 assert.doesNotMatch(label.textContent,/Error/,'it no longer claims to be an error chart');
 assert.match(label.title,/dashed target line/,'and explains how to read it against the target line');
 assert.doesNotMatch(label.title,/diagonal/,'never against the chart diagonal, which only matches the target at one white level');
 assert.match(label.title,/panel clipping/,'an HDR view explains the flat top as the panel clip');
 hdrView=false;ctx.update();
 assert.match(label.title,/dashed target line/,'an SDR view also reads against the dashed target line');
 assert.doesNotMatch(label.title,/diagonal/,'not the diagonal');
 assert.doesNotMatch(label.title,/clip/,'but never attributes a flat top to HDR panel clipping');
 hdrView=true;
 const body=read('webui-body.html').match(/<label[^>]*title="([^"]*)"[^>]*>\s*<input type="checkbox" id="meterEotfAbsolute"/);
 assert.ok(body,'the Absolute checkbox tooltip is found');
 assert.doesNotMatch(body[1],/error view/i,'the checkbox tooltip no longer calls the view an error chart');
 assert.match(body[1],/dashed target line/,'and describes reading it against the target line');
 assert.doesNotMatch(body[1],/diagonal/,'not the chart diagonal');
 normalized=true;ctx.update();
 assert.equal(label.textContent,'EOTF','the normalised view keeps its title');
}
// P30: held progress labels.
{
 const ctx={pgAutomation:{statusError:''},pgAutomationStageLabel:s=>'Stage '+s};
 vm.createContext(ctx);
 vm.runInContext(grab(auto,'pgAutomationEscape')+'\n'+grab(auto,'pgAutomationProgressMeters')+';this.meters=pgAutomationProgressMeters;',ctx);
 const label=(run,pre)=>ctx.meters(run,pre).match(/<span>[^<]*<\/span><span>([^<]*)<\/span>/)[1];
 assert.equal(label({status:'interrupted',active_stage:'post-readings-done'}),'Interrupted','an interrupted run is not called paused');
 assert.equal(label({status:'paused',active_stage:'post-readings-done'}),'Paused','a paused run is paused');
 ctx.pgAutomation.statusError='lost';
 assert.equal(label({status:'running',active_stage:'greyscale-done'}),'Status unavailable','a lost status poll is not called paused');
 ctx.pgAutomation.statusError='';
 assert.equal(label(null,{status:'blocked'}),'Blocked','a blocked preflight is not called paused');
}
// The colour stage names only what the job is doing: a 3D LUT profile on SDR,
// HDR10 and HLG, a Dolby Vision profile on DV. Naming both read as if an SDR
// run had wandered into Dolby Vision (seen live on the appliance).
{
 const ctx={pgAutomation:{current:{run:{active_item:0,items:[{signal_format:'sdr'}]}}}};
 vm.createContext(ctx);
 vm.runInContext(grab(auto,'pgAutomationStageSignal')+'\n'+grab(auto,'pgAutomationStageLabel')+';this.label=pgAutomationStageLabel;',ctx);
 assert.equal(ctx.label('volume-done'),'3D LUT profiling','an SDR job calls the colour stage a 3D LUT profile');
 assert.doesNotMatch(ctx.label('volume-done'),/Dolby/,'and never mentions Dolby Vision');
 assert.equal(ctx.label('volume-settings-verified'),'Checking TV settings after the 3D LUT upload','the follow-up check names the 3D LUT too');
 ctx.pgAutomation.current.run.items[0].signal_format='dv';
 assert.equal(ctx.label('volume-done'),'Dolby Vision profiling','a Dolby Vision job names its own profile');
 assert.match(ctx.label('volume-settings-verified'),/Dolby Vision profile upload/,'and its follow-up check');
 assert.equal(ctx.label('volume-done','hdr10'),'3D LUT profiling','an explicit signal overrides the active job');
 assert.equal(ctx.label('greyscale-done'),'Calibrating the 1D LUT','other stages are unchanged');
 ctx.pgAutomation.current=null;
 assert.equal(ctx.label('volume-done'),'3D LUT profiling','with no active job the neutral name is used');
}
console.log('PASS chart labels and progress: HDR clip excluded from gamma, EOTF tracking title, held-state labels');
