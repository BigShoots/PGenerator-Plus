#!/usr/bin/env node
'use strict';

const {chromium}=require('playwright');

const base=process.env.PGEN_URL||'http://192.168.1.166';
const timeoutMs=Number(process.env.PGEN_SWEEP_TIMEOUT_MS||240000);
const seriesKind=String(process.env.PGEN_SERIES||'saturations').toLowerCase();
const colorChecker=seriesKind==='colors'||seriesKind==='colorchecker';

(async()=>{
 const launch={headless:true};
 if(process.env.PLAYWRIGHT_CHROMIUM_PATH) launch.executablePath=process.env.PLAYWRIGHT_CHROMIUM_PATH;
 const browser=await chromium.launch(launch);
 const page=await browser.newPage({viewport:{width:1600,height:1100}});
 page.on('console',msg=>{
  if(msg.type()==='error') process.stderr.write(`[browser console] ${msg.text()}\n`);
 });
 try{
  await page.goto(base,{waitUntil:'domcontentloaded',timeout:30000});
  await page.waitForSelector('#meterSaturationSeriesBtn',{state:'attached',timeout:30000});
  await page.waitForFunction(()=>typeof meterSelectBuiltinSaturationSweep==='function'&&typeof meterRunSeries==='function');

  const initial=await page.evaluate(async()=>{
   const config=await (await fetch('/api/config')).json();
   const status=await (await fetch('/api/meter/series/status')).json();
   return {config,status:String(status.status||''),series:status};
  });
  if(initial.status==='running'||initial.status==='setup') throw new Error(`meter series already ${initial.status}`);
  if(String(initial.config.dv_map_mode)!=='1') throw new Error(`DV map mode is ${initial.config.dv_map_mode}, expected Absolute (1)`);
  if(String(initial.config.dv_status)!=='1') throw new Error('Dolby Vision is not active');

  await page.selectOption('#meterDisplayType','oled_generic');
  await page.selectOption('#meterColorDeltaEForm','de2000');
  await page.check('#meterColorIncludeLumError');
  await page.click('[data-series-tab="color"]');
  await page.click(colorChecker?'#meterColorCheckerSeriesBtn':'#meterSaturationSeriesBtn');
  await page.waitForFunction(()=>{
   const b=document.getElementById('meterReadSeriesBtn');
   return b&&b.style.display!=='none'&&!b.disabled&&
    (meterActiveSeriesType==='saturations'||meterActiveSeriesType==='colors');
  },null);

  const preview=await page.evaluate(()=>({
   type:meterActiveSeriesType,
   points:meterActiveSeriesPoints,
   displayType:document.getElementById('meterDisplayType').value,
   includeLuminance:document.getElementById('meterColorIncludeLumError').checked,
   steps:(meterSeriesSteps||[]).map(s=>({name:s.name,r:s.r,g:s.g,b:s.b,target_Yn:s.target_Yn}))
  }));
  process.stdout.write(`${JSON.stringify({phase:'preview',...preview})}\n`);
  const expectedType=colorChecker?'colors':'saturations';
  const apiColorSteps=String((initial.series&&initial.series.type)||'')===expectedType
   ?((initial.series&&initial.series.steps)||[])
   :[];
  if(apiColorSteps.length===preview.steps.length){
   const apiByName=new Map(apiColorSteps.map(s=>[s.name,s]));
   const mismatches=preview.steps.filter(step=>{
    const api=apiByName.get(step.name);
    return !api||Number(step.r)!==Number(api.r)||Number(step.g)!==Number(api.g)||Number(step.b)!==Number(api.b);
   });
   process.stdout.write(`${JSON.stringify({phase:'preview-api-parity',mismatches})}\n`);
   if(mismatches.length) throw new Error(`${mismatches.length} browser preview patches differ from API series steps`);
  }
  if(process.env.PGEN_PREVIEW_ONLY==='1') return;

  await page.click('#meterReadSeriesBtn');
  await page.waitForFunction(async()=>{
   try{
    const status=await (await fetch('/api/meter/series/status')).json();
    return status.status==='running'||status.status==='setup';
   }catch(_e){return false;}
  },null,{timeout:30000});

  const deadline=Date.now()+timeoutMs;
  let lastStep=-1;
  for(;;){
   const status=await page.evaluate(async()=>await (await fetch('/api/meter/series/status')).json());
   if(Number(status.current_step)!==lastStep){
    lastStep=Number(status.current_step);
    process.stdout.write(`${JSON.stringify({phase:'progress',status:status.status,current:status.current_step,total:status.total_steps,name:status.current_name})}\n`);
   }
   if(status.status==='complete') break;
   if(status.status==='error'||status.status==='stopped'||status.status==='cleared'){
    throw new Error(`series ended with ${status.status}: ${status.message||''}`);
   }
   if(Date.now()>deadline) throw new Error(`series timed out after ${timeoutMs}ms`);
   await page.waitForTimeout(1000);
  }

  await page.waitForFunction(()=>Array.isArray(meterReadings)&&meterReadings.length>=24,null,{timeout:30000});
  const result=await page.evaluate(()=>{
   const mode='eotf';
   const rows=(meterReadings||[]).filter(rd=>{
    if(!rd) return false;
    if(meterActiveSeriesType==='saturations') return rd.series_color&&rd.sat_pct!=null;
    const name=String(rd.name||'').toLowerCase();
    return name!=='white'&&name!=='black';
   }).map(rd=>{
    const target=meterTargetXYZForReading(rd);
    return {
     name:rd.name,
     r:rd.r_code,g:rd.g_code,b:rd.b_code,
     measuredY:Number(rd.Y!=null?rd.Y:rd.luminance),
     targetY:target?Number(target.Y):null,
     deltaE:Number(meterColorDeltaE2000(rd,mode,'de2000'))
    };
   });
   const values=rows.map(r=>r.deltaE).filter(Number.isFinite);
   return {
    rows,
    maxDeltaE:values.length?Math.max(...values):null,
    avgDeltaE:values.length?values.reduce((a,b)=>a+b,0)/values.length:null
   };
  });
  process.stdout.write(`${JSON.stringify({phase:'result',...result})}\n`);
  const expectedRows=colorChecker?28:24;
  if(!(result.rows.length===expectedRows)) throw new Error(`expected ${expectedRows} readings, got ${result.rows.length}`);
  if(!(result.maxDeltaE<=3)) throw new Error(`maximum Delta E is ${result.maxDeltaE}, expected <= 3`);
 }finally{
  try{
   await page.evaluate(async()=>{await fetch('/api/pattern',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name:'stop'})});});
  }catch(_e){}
  await browser.close();
 }
})().catch(error=>{
 process.stderr.write(`${error.stack||error}\n`);
 process.exit(1);
});
