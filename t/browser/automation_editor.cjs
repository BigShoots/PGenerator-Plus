// Local DOM regression check; requires Puppeteer. No generator/TV connection.
// Run: node t/browser/automation_editor.cjs
const fs=require('fs');
const path=require('path');
const assert=require('node:assert/strict');
const puppeteer=require('puppeteer');
const root=path.resolve(__dirname,'../..');
(async()=>{
 const browser=await puppeteer.launch({headless:true});
 try{
  const page=await browser.newPage();
  const errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.setViewport({width:1440,height:1100});
  await page.setContent(fs.readFileSync(path.join(root,'usr/share/PGenerator/webui-automation.html'),'utf8'));
  await page.addStyleTag({content:fs.readFileSync(path.join(root,'usr/share/PGenerator/webui-theme.css'),'utf8')});
  // Injected styles transition from the browser's native button colour.
  // Inspect the settled UI, not the first animation frame.
  await page.waitForFunction(()=>{const b=getComputedStyle(document.getElementById('pgAutomationStartButton')).backgroundColor;return b!=='rgba(0, 0, 0, 0)'&&b!==getComputedStyle(document.getElementById('pgAutomationReadinessButton')).backgroundColor;});
  const lg=fs.readFileSync(path.join(root,'usr/share/PGenerator/webui-lg.js'),'utf8');
  const metadata=lg.match(/const LG_DISPLAY_CONTROL_ITEMS=\[[\s\S]*?const LG_DISPLAY_CONTROL_KEYS=[^;]+;/);
  assert.ok(metadata,'shared LG settings metadata found');
  await page.addScriptTag({content:metadata[0]});
  await page.addScriptTag({content:fs.readFileSync(path.join(root,'usr/share/PGenerator/webui-automation.js'),'utf8').replace(/setTimeout\(pgAutomationInit,0\);\s*$/,'')});
  // Async matrix resolution is covered by automation_settings_plan.cjs.
  await page.evaluate(()=>{window.pgAutomationResolveSettingsPlan=async()=>{};});
  const results=await page.evaluate(async()=>{
   const checks=[];
   const check=(value,label)=>{if(!value)throw new Error(label);checks.push(label);};
   const visible=id=>pgAutomationEl(id).style.display!=='none';
   pgAutomationRenderSavedQueues();
   pgAutomationEl('SavedQueueSelect').value='reference-settings';pgAutomationEl('SavedQueueSelect').dispatchEvent(new Event('change'));
   check(pgAutomationEl('QueueItems').querySelectorAll('.auto-item').length===6&&pgAutomationEl('QueueName').value==='Reference settings','reference settings loads six ordinary queue items');
   const runButton=pgAutomationEl('StartButton'),runRect=runButton.getBoundingClientRect();
   const readiness=pgAutomationEl('ReadinessButton'),runStyle=getComputedStyle(runButton),readyStyle=getComputedStyle(readiness);
   check(runRect.height===readiness.getBoundingClientRect().height&&runStyle.padding===readyStyle.padding&&runStyle.fontSize===readyStyle.fontSize,'Run queue uses the same compact sizing as Check Readiness');
   // 18 Sep 2026: red is for Stop. Run queue is the primary action, and a
   // disabled primary must not sit on the page as a red block for hours.
   check(runButton.classList.contains('btn-primary')&&!runButton.classList.contains('btn-danger')&&runStyle.backgroundColor!==readyStyle.backgroundColor&&runStyle.backgroundColor!=='rgb(255, 68, 68)'&&runStyle.boxShadow==='none','Run queue uses the primary action colour, not red, without a glow');
   check(document.querySelectorAll('#pgAutomationStartButton').length===1&&runButton.classList.contains('btn-sm')&&runRect.bottom<pgAutomationEl('QueueItems').getBoundingClientRect().top,'Run queue remains a single compact action above the jobs');
   check(pgAutomationEl('DeleteQueueButton').disabled&&!/colourstrue|built-in template|template setup/i.test(document.body.innerText),'reference queue has no branded panel or template labels');
   for(const [index,item] of pgAutomation.queue.items.entries()){
    pgAutomationQueueEdit(index);
    const edited=pgAutomationRecipeFromForm();
    check(edited.target_gamma===item.target_gamma&&edited.calibration.target_gamma===item.calibration.target_gamma&&edited.settings.gamma===item.settings.gamma&&edited.tv_gamma_follows_target===item.tv_gamma_follows_target,item.name+' keeps both gamma targets and the TV Gamma pin through the Configure popup');
    check(edited.target_delta_e===.5&&edited.calibration.target_delta_e===.5&&!edited.stages.pre_readings&&!edited.stages.post_readings,item.name+' keeps delta E 0.5 and optional sweeps disabled through the Configure popup');
    check(edited.calibration.dark_detail&&edited.stages.apply_all,item.name+' keeps Dark Detail and Apply to All Inputs enabled through the Configure popup');
    check(edited.panel_protection&&edited.panel_protection.disable===false,item.name+' leaves panel protection (TPC/GSR) on through the Configure popup (switching it off is opt-in)');
    const settingsEqual=Object.keys(edited.settings).length===Object.keys(item.settings).length&&Object.entries(item.settings).every(([key,value])=>edited.settings[key]===value);
    check(settingsEqual&&edited.calibration.method===item.calibration.method&&edited.panel_light.fixed_value===item.panel_light.fixed_value,item.name+' preserves all pinned picture controls, profiling method and panel brightness');
    pgAutomationCancelEditor();
   }
   pgAutomationQueueEdit(4);
   check(pgAutomationEl('Editor').open&&pgAutomationEl('Signal').value==='sdr'&&pgAutomationEl('Delta').value==='0.5'&&pgAutomationEl('PanelValue').value==='95','reference item opens in the normal editor with its saved settings');
   pgAutomationCancelEditor();
   pgAutomationQueueMove(5,-1);pgAutomationQueueDuplicate(4);pgAutomationQueueRemove(6);
   check(pgAutomation.queue.items.length===6&&pgAutomation.queue.items[4].name==='SDR Cinema'&&pgAutomation.queue.items[5].name==='SDR Cinema (copy)','reference items can be reordered, duplicated and removed normally');
   check(pgAutomationReferenceQueue().items[4].name==='SDR Filmmaker','queue edits leave reference settings unchanged');
   // In-app confirmation (P11) is asynchronous; answer it through the test hook.
   const tick=()=>new Promise(resolve=>setTimeout(resolve,0));
   pgAutomation.queues=[{id:'browser-saved',name:'Browser saved queue',items:[pgAutomationReferenceQueue().items[4]]}];pgAutomationRenderSavedQueues();
   window.pgAutomationConfirmOverride=()=>false;
   pgAutomationEl('SavedQueueSelect').value='saved:browser-saved';pgAutomationEl('SavedQueueSelect').dispatchEvent(new Event('change'));await tick();
   check(pgAutomationEl('SavedQueueSelect').value==='reference-settings'&&pgAutomationEl('QueueItems').querySelectorAll('.auto-item').length===6,'cancelling selection restores dropdown and edited queue');
   window.pgAutomationConfirmOverride=()=>true;
   pgAutomationEl('SavedQueueSelect').value='saved:browser-saved';pgAutomationEl('SavedQueueSelect').dispatchEvent(new Event('change'));await tick();
   check(pgAutomationEl('QueueItems').querySelectorAll('.auto-item').length===1&&pgAutomationEl('QueueName').value==='Browser saved queue','dropdown change immediately updates the displayed queue items');
   let prompted=false;window.pgAutomationConfirmOverride=()=>{prompted=true;return false;};
   pgAutomationEl('SavedQueueSelect').value='reference-settings';pgAutomationEl('SavedQueueSelect').dispatchEvent(new Event('change'));await tick();
   check(!prompted,'an unchanged queue switches without prompting');
   check(pgAutomationEl('QueueItems').querySelectorAll('.auto-item').length===6,'switching back restores six reference items without an extra Load click');
   delete window.pgAutomationConfirmOverride;
   pgAutomation.queue={name:'TV calibration queue',items:[]};pgAutomationRenderQueue();
   pgAutomationNewRecipe('queue');
   check(pgAutomationEl('Delta').value==='0.5','new 1D LUT target defaults to 0.5');
   const initial=pgAutomationRecipeFromForm();
   check(!initial.stages.pre_readings&&!initial.stages.post_readings&&initial.stages.calibration,'Add item defaults to AutoCal without before/after sweeps');
   for(const signal of ['hdr10','dv','sdr']){
    pgAutomationEl('Signal').value=signal;pgAutomationModesChanged();pgAutomationSignalDefaults();
    const item=pgAutomationRecipeFromForm();
    check(!item.stages.pre_readings&&!item.stages.post_readings,signal+' mode selection does not enable optional sweeps');
   }
   for(const stages of [{pre_readings:true,post_readings:false},{pre_readings:false,post_readings:true},{pre_readings:true,post_readings:true}]){
    pgAutomationFillRecipe({...initial,stages:{...initial.stages,...stages}});
    const saved=pgAutomationRecipeFromForm();
    check(saved.stages.pre_readings===stages.pre_readings&&saved.stages.post_readings===stages.post_readings,'explicit before/after sweep selections survive editing');
   }
   pgAutomationCancelEditor();pgAutomationNewRecipe('queue');
   check(!pgAutomationChecked('Pre')&&!pgAutomationChecked('Post'),'a new item does not inherit the previous item’s enabled sweeps');
   check(!/Before:|After:/.test(pgAutomationItemSummary({}))&&!/Before readings|After readings/.test(pgAutomationJobSummary({})),'summaries agree with missing-stage defaults');
   check(initial.settings.contrast===85&&initial.settings.gamma==='high2','new SDR jobs start with reference picture controls');
   check(initial.panel_light.fixed_value===95&&!pgAutomationEl('SelectAllSettings').disabled,'reference panel brightness and offline Select All work without contacting a TV');
   check(!pgAutomationEl('Warmup')&&!Object.hasOwn(pgAutomationSnapshot({warmup_minutes:60}),'warmup_minutes'),'warm-up is absent from the editor and legacy snapshots');
   check(pgAutomationEl('BitDepth').value==='10'&&pgAutomationEl('ColorFormat').value==='1','new SDR items use the wizard 10-bit video transport');
   check(visible('PanelFixedField')&&!visible('PanelTargetField'),'fixed policy shows only the control value');
   pgAutomationEl('PanelValue').value=100;
   pgAutomationEl('Gamma').value='srgb';
   pgAutomationEl('Method').value='hybrid9';
   pgAutomationEl('Delta').value=0.3;
   let recipe=pgAutomationRecipeFromForm();
   check(recipe.settings.backlight===100,'fixed backlight value is saved');
   check(recipe.calibration.target_delta_e===0.3&&recipe.calibration.target_gamma==='srgb','1D target and sRGB survive snapshot');
   check(recipe.calibration.method==='hybrid'&&recipe.calibration.lattice_size===9,'Hybrid 9 reaches the worker configuration');
   pgAutomationEl('PanelTargetRadio').click();
   pgAutomationEl('PanelTarget').value=135;
   recipe=pgAutomationRecipeFromForm();
   check(visible('PanelTargetField')&&!visible('PanelFixedField'),'target policy hides the fixed value');
   check(recipe.panel_light.policy==='target'&&recipe.calibration.target_luminance===135&&!('backlight' in recipe.settings),'target luminance is saved without a conflicting fixed pin');
   pgAutomationFillRecipe(recipe);
   check(pgAutomationEl('PanelTargetRadio').checked&&pgAutomationEl('Delta').value==='0.3'&&pgAutomationEl('Method').value==='hybrid9','editing restores policy and 1D/3D targets');
   pgAutomation.supportedKeys=['backlight','brightness','blackLevel','colorTemperature','energySaving'];
   pgAutomation.supportedValues={backlight:80,brightness:50,blackLevel:{ntsc:'auto',pal:'auto'},colorTemperature:-50,energySaving:'off'};
   pgAutomation.pinnedKeys=[];pgAutomationRenderSettingsEditor();
   pgAutomationEl('SelectAllSettings').click();
   const settings=pgAutomationReadSettingsEditor();
   check(Object.keys(settings).length===4,'Select All captures every picture control (panel policy separate)');
   check(settings.blackLevel.ntsc==='auto'&&settings.colorTemperature===-50,'Select All preserves structured and numeric TV values');
   pgAutomationSelectSettings(false);
   check(Object.keys(pgAutomationReadSettingsEditor()).length===0,'Clear Selection removes picture pins');
   pgAutomationEl('Signal').value='hdr10';pgAutomationModesChanged();pgAutomationSignalDefaults();
   pgAutomationEl('ShadowFix').checked=true;
   recipe=pgAutomationRecipeFromForm();
   check(recipe.calibration.method==='matrix'&&recipe.calibration.shadow_fix,'HDR10 pins matrix and retains Shadow Fix');
   check(recipe.max_bpc===10&&recipe.eotf==='2'&&recipe.primaries==='2'&&recipe.colorimetry==='9','HDR10 captures its wizard transport metadata');
   check(!visible('VolumeFields')&&visible('ShadowFixField')&&!visible('PanelTargetChoice'),'HDR10 only exposes its supported wizard controls');
   check(pgAutomationEl('Gamma').disabled&&recipe.target_gamma==='st2084','HDR10 verification target is PQ, not inherited SDR gamma');
   pgAutomationEl('Signal').value='dv';pgAutomationModesChanged();pgAutomationSignalDefaults();
   recipe=pgAutomationRecipeFromForm();
   check(!visible('OutputSection')&&!visible('VolumeFields')&&!visible('ShadowFixField'),'DV hides output presets, 3D LUT and Shadow Fix');
   check(recipe.max_bpc===8&&recipe.color_format==='0'&&recipe.signal_range==='2'&&!recipe.calibration.shadow_fix,'DV saves pinned RGB Full 8-bit with no HDR10-only flag');
   pgAutomationEl('Signal').value='hdr10';pgAutomationModesChanged();pgAutomationSignalDefaults();
   check(pgAutomationRecipeFromForm().max_bpc===10,'switching from DV cannot leak its 8-bit transport into a new HDR item');
   pgAutomationEl('Signal').value='hlg';pgAutomationModesChanged();pgAutomationSignalDefaults();
   check(pgAutomationEl('Cal').disabled&&!pgAutomationChecked('Cal')&&!pgAutomationChecked('Pre')&&!pgAutomationChecked('Post'),'HLG remains measurement-only without silently enabling a sweep');
   pgAutomationEl('Pre').checked=true;
   check(pgAutomationRecipeFromForm().stages.pre_readings&&!pgAutomationRecipeFromForm().stages.calibration,'HLG accepts an explicitly enabled measurement sweep');
   pgAutomationEl('Pre').checked=false;
   pgAutomationEl('Signal').value='sdr';pgAutomationModesChanged();pgAutomationSignalDefaults();pgAutomationEl('Cal').checked=true;pgAutomationUpdateEditor();
   pgAutomationEl('UseCase').value='tv';pgAutomationUseCaseChanged();
   recipe=pgAutomationRecipeFromForm();
   check(recipe.color_format==='1'&&recipe.signal_range==='1'&&recipe.max_bpc===10&&recipe.target_gamma==='bt1886','TV / Movies uses the wizard output and gamma defaults');
   const headings=[...document.querySelectorAll('#pgAutomationEditor .auto-step>h3')].map(x=>x.textContent);
   check(headings.indexOf('Display Use Case')<headings.indexOf('Display Type and Meter Profile')&&headings.indexOf('Gamma Target')<headings.indexOf('TV Settings and 100% White Luminance')&&headings.at(-1)==='1D LUT AutoCal Target','SDR setup order follows the manual wizard');
   return checks;
  });
  await page.setViewport({width:390,height:844});
  assert.ok(await page.evaluate(()=>{const run=pgAutomationEl('StartButton').getBoundingClientRect(),ready=pgAutomationEl('ReadinessButton').getBoundingClientRect();return run.height===ready.height&&Math.abs(run.top-ready.top)<=1;}),'Run queue stays compact beside Check Readiness on phones');
  assert.ok(await page.evaluate(()=>pgAutomationEl('Editor').scrollWidth<=pgAutomationEl('Editor').clientWidth+1),'phone editor has no horizontal overflow');
  const defaultsChecks=await page.evaluate(async()=>{
   const checks=[],check=(ok,label)=>{if(!ok)throw new Error(label);checks.push(label);};
   const setting=key=>document.querySelector('[data-pg-automation-key="'+key+'"]');
   const switchSignal=signal=>{pgAutomationEl('Signal').value=signal;pgAutomationModesChanged();pgAutomationSignalDefaults();};
   pgAutomationCancelEditor();pgAutomationNewRecipe('queue');
   pgAutomationResetPictureDefaults();
   setting('contrast').value=61;
   document.querySelector('[data-pg-automation-pin="energySaving"]').click();
   switchSignal('hdr10');
   let job=pgAutomationRecipeFromForm();
   check(job.settings.contrast===100&&job.settings.peakBrightness==='high'&&job.panel_light.fixed_value===100,'HDR mode starts with its own reference defaults');
   switchSignal('dv');job=pgAutomationRecipeFromForm();
   check(job.settings.contrast===100&&job.settings.peakBrightness==='high'&&!('colorGamut' in job.settings)&&!('hdrDynamicToneMapping' in job.settings),'DV reference defaults exclude decoder-managed controls');
   check(!setting('colorGamut')&&!setting('hdrDynamicToneMapping'),'DV editor does not offer generic gamut or HDR tone-mapping pins');
   switchSignal('sdr');job=pgAutomationRecipeFromForm();
   check(job.settings.contrast===61&&!('energySaving' in job.settings)&&job.panel_light.fixed_value===95,'switching back restores that mode’s edits and unpinned controls');
   pgAutomationEl('PictureMode').value='cinema';pgAutomationModeChanged();
   check(pgAutomationRecipeFromForm().panel_light.fixed_value===100&&setting('contrast').value==='85','SDR Cinema has a separate default profile');
   pgAutomationEl('PictureMode').value='filmMaker';pgAutomationModeChanged();
   check(setting('contrast').value==='61','switching picture modes preserves each draft');
   pgAutomationResetPictureDefaults();
   check(setting('contrast').value==='85'&&pgAutomation.pinnedKeys.includes('energySaving'),'Restore Reference Defaults resets pins and values explicitly');
   const requests=[],originalFetch=window.fetchJSON;
   try{
    window.fetchJSON=async(url,options)=>{
     requests.push({url,body:JSON.parse(options.body)});
     return {status:'ok',supported_picture_keys:['contrast','brightness','blackLevel','backlight'],picture_settings:{pictureMode:'filmMaker',contrast:73,brightness:0,blackLevel:{ntsc:'auto',pal:'auto'},backlight:42,peakBrightness:null,energySaving:''}};
    };
    await pgAutomationLoadSupportedKeys();job=pgAutomationRecipeFromForm();
    check(job.settings.contrast===73&&job.settings.brightness===0&&job.settings.blackLevel.ntsc==='auto'&&job.panel_light.fixed_value===42,'Use TV Settings replaces defaults including zero, structured values and panel brightness');
    check(!('peakBrightness' in job.settings)&&!('energySaving' in job.settings),'missing TV values are unpinned rather than silently retaining defaults');
    check(requests.length===1&&requests[0].url==='/api/lg/picture-settings'&&requests[0].body.picture_mode==='filmMaker'&&requests[0].body.keys.includes('pictureMode'),'TV import is a scoped read only, with no picture-mode or settings writes');
    const before=JSON.stringify(pgAutomationReadSettingsEditor());
    window.fetchJSON=async()=>({status:'error',message:'TV unavailable'});await pgAutomationLoadSupportedKeys();
    check(JSON.stringify(pgAutomationReadSettingsEditor())===before&&pgAutomationEl('EditorError').textContent==='TV unavailable','failed TV reads preserve prepared settings');
    window.fetchJSON=async()=>({status:'ok',picture_settings:{pictureMode:'hdrFilmMaker',contrast:100}});await pgAutomationLoadSupportedKeys();
    check(JSON.stringify(pgAutomationReadSettingsEditor())===before&&/different picture mode/.test(pgAutomationEl('EditorError').textContent),'readback from a different mode cannot overwrite this job');
    let resolve;window.fetchJSON=()=>new Promise(r=>{resolve=r;});
    const pending=pgAutomationLoadSupportedKeys();switchSignal('hdr10');switchSignal('sdr');
    resolve({status:'ok',picture_settings:{pictureMode:'filmMaker',contrast:9}});await pending;
    check(setting('contrast').value==='73','late readback cannot overwrite a changed or revisited profile');
    const editedPending=pgAutomationLoadSupportedKeys();setting('contrast').value=68;
    resolve({status:'ok',picture_settings:{pictureMode:'filmMaker',contrast:9}});await editedPending;
    check(setting('contrast').value==='68'&&/Your edits were kept/.test(pgAutomationEl('EditorError').textContent),'typing during a TV read cannot silently lose the new edit');
   }finally{window.fetchJSON=originalFetch;}
   pgAutomationFillRecipe({name:'Existing custom job',signal_format:'sdr',picture_mode:'cinema',settings:{contrast:12}});
   check(setting('contrast').value==='12'&&!pgAutomation.pinnedKeys.includes('peakBrightness'),'opening saved jobs does not inject defaults or overwrite custom settings');
   pgAutomationFillRecipe({name:'Deliberately empty',signal_format:'sdr',picture_mode:'filmMaker',settings:{}});
   check(pgAutomation.pinnedKeys.length===0,'existing empty settings remain an opt-out');
   pgAutomationCancelEditor();pgAutomationNewRecipe('recipe');
   check(setting('contrast').value==='85'&&pgAutomationEl('PanelValue').value==='95','new recipes reuse defaults without inheriting previous edits');
   return checks;
  });
  const gammaChecks=await page.evaluate(async()=>{
   const checks=[],check=(ok,label)=>{if(!ok)throw new Error(label);checks.push(label);};
   const gamma=()=>document.querySelector('[data-pg-automation-key="gamma"]');
   const target=value=>{pgAutomationEl('Gamma').value=value;pgAutomationEl('Gamma').dispatchEvent(new Event('change'));};
   pgAutomationCancelEditor();pgAutomationNewRecipe('queue');
   check(pgAutomationRecipeFromForm().settings.gamma==='high2','new jobs default to reference TV Gamma');
   pgAutomationResetPictureDefaults();
   check(pgAutomationRecipeFromForm().settings.gamma==='high2'&&gamma().selectedOptions[0].textContent==='BT.1886','SDR starts with a pinned, labelled BT.1886 TV Gamma using the LG wire token');
   target('2.2');check(pgAutomationRecipeFromForm().settings.gamma==='medium','prepared TV Gamma follows the Gamma 2.2 target');
   target('2.4');check(pgAutomationRecipeFromForm().settings.gamma==='high1','Gamma 2.4 uses high1, not BT.1886');
   target('srgb');check(!('gamma' in pgAutomationRecipeFromForm().settings)&&/no sRGB menu preset/.test(pgAutomationEl('GammaHelp').textContent),'sRGB has no fabricated TV gamma setting');
   target('bt1886');check(pgAutomationRecipeFromForm().settings.gamma==='high2','returning to a supported target restores the automatic pin');
   gamma().value='medium';gamma().dispatchEvent(new Event('change'));target('2.4');
   let saved=pgAutomationRecipeFromForm();
   check(saved.settings.gamma==='medium'&&!saved.tv_gamma_follows_target,'manual TV Gamma overrides are independent of the calibration target');
   pgAutomationFillRecipe(saved);target('bt1886');check(pgAutomationRecipeFromForm().settings.gamma==='medium','saved manual gamma override survives reopening');
   pgAutomationEl('PictureMode').value='cinema';pgAutomationModeChanged();
   check(pgAutomationEl('Gamma').value==='2.2'&&pgAutomationRecipeFromForm().settings.gamma==='medium','SDR Cinema has its own reference TV Gamma');
   pgAutomationEl('PictureMode').value='filmMaker';pgAutomationModeChanged();
   check(pgAutomationEl('Gamma').value==='bt1886'&&gamma().value==='medium'&&!pgAutomation.gammaFollowsTarget,'mode drafts restore target and override separately');
   pgAutomationResetPictureDefaults();
   document.querySelector('[data-pg-automation-pin="gamma"]').click();target('2.2');
   check(!('gamma' in pgAutomationRecipeFromForm().settings),'explicit unpin is respected when target changes');
   pgAutomationResetPictureDefaults();
   const fetch=window.fetchJSON;
   try{window.fetchJSON=async()=>({status:'ok',picture_settings:{pictureMode:'filmMaker',gamma:'medium'}});await pgAutomationLoadSupportedKeys();}
   finally{window.fetchJSON=fetch;}
   target('2.4');check(pgAutomationRecipeFromForm().settings.gamma==='medium'&&!pgAutomation.gammaFollowsTarget,'TV import explicitly overrides the prepared gamma link');
   for(const signal of ['hdr10','dv','hlg']){
    pgAutomationEl('Signal').value=signal;pgAutomationModesChanged();pgAutomationSignalDefaults();
    check(!gamma()&&!('gamma' in pgAutomationReadSettingsEditor()),signal+' does not offer generic SDR TV Gamma');
   }
   pgAutomationFillRecipe({signal_format:'sdr',picture_mode:'filmMaker',settings:{gamma:'BT.1886'}});
   check(gamma().value==='high2'&&pgAutomationRecipeFromForm().settings.gamma==='high2','legacy friendly gamma values are converted to LG enum tokens');
   return checks;
  });
  const queueChecks=await page.evaluate(async()=>{
   const checks=[],check=(value,label)=>{if(!value)throw new Error(label);checks.push(label);};
   pgAutomationCancelEditor();
   const request=pgAutomationRequest,refresh=pgAutomationRefresh;
   let fail=false;const writes=[];
   pgAutomationRequest=async(path,body)=>{if(fail)throw new Error('Simulated save failure');if(path!=='queues')throw new Error('Unexpected write');writes.push(pgAutomationClone(body.queue));return {queue:{...body.queue,id:body.queue.id||'copy-'+writes.length}};};
   pgAutomationRefresh=async()=>{};
   try{
    pgAutomation.queue=pgAutomationReferenceQueue();pgAutomation.selectedQueue='reference-settings';pgAutomation.loadedQueueSnapshot=JSON.stringify(pgAutomation.queue);pgAutomationRenderQueue();
    check(pgAutomationEl('SaveQueueButton').textContent==='Copy queue'&&pgAutomationEl('JobsHeading').textContent==='6 jobs in Reference settings','reference queue lists all jobs with a direct Copy queue action');
    check(!document.querySelector('#pgAutomationTabQueue #pgAutomationQueueName'),'queue name is not a separate competing selector');
    pgAutomationSaveSelectedQueue();pgAutomationEl('QueueName').value='My reference copy';await pgAutomationSubmitQueueName();
    check(writes[0].id===undefined&&writes[0].items.length===6&&pgAutomation.queue.name==='My reference copy','copy saves all six jobs under a new queue ID');
    pgAutomationQueueRemove(0);
    check(pgAutomationEl('SavedQueueSelect').selectedOptions[0].textContent.includes('5 jobs · unsaved')&&pgAutomationEl('JobsHeading').textContent==='5 jobs in My reference copy','selected queue label and job list agree after edits');
    check(pgAutomationReferenceQueue().items.length===6&&pgAutomation.queues.find(q=>q.id==='copy-1').items.length===6,'unsaved edits do not mutate reference or saved source jobs');
    pgAutomationNameQueue('copy');pgAutomationEl('QueueName').value='Second copy';await pgAutomationSubmitQueueName();
    check(writes[1].id===undefined&&pgAutomation.queue.id==='copy-2'&&pgAutomation.queue.items.length===5,'copying an existing saved queue creates an independent queue');
    const before=JSON.stringify(pgAutomation.queue);fail=true;
    pgAutomationNameQueue('rename');pgAutomationEl('QueueName').value='Failed rename';await pgAutomationSubmitQueueName();
    check(JSON.stringify(pgAutomation.queue)===before&&pgAutomationEl('QueueDialog').open&&pgAutomationEl('QueueDialogError').textContent==='Simulated save failure','failed save leaves selected queue and jobs unchanged');
    pgAutomationEl('QueueDialog').close();fail=false;
    pgAutomationNewQueue();pgAutomationEl('QueueName').value='Empty queue';await pgAutomationSubmitQueueName();
    check(pgAutomation.queue.items.length===0&&pgAutomationEl('QueueItems').textContent.includes('No jobs in this queue')&&pgAutomation.queue.name==='Empty queue','new named queue is saved and displays its own empty job list');
    pgAutomationNameQueue('rename');pgAutomationEl('QueueName').value='Renamed queue';await pgAutomationSubmitQueueName();
    check(writes.at(-1).id==='copy-3'&&pgAutomation.queue.name==='Renamed queue','rename preserves the saved queue identity');
    check(document.querySelector('#automationCard').scrollWidth<=document.querySelector('#automationCard').clientWidth+1,'queue list fits a phone width');
   }finally{pgAutomationRequest=request;pgAutomationRefresh=refresh;}
   return checks;
  });
  const progressChecks=await page.evaluate(async()=>{
   const checks=[],check=(value,label)=>{if(!value)throw new Error(label);checks.push(label);};
   const reference=pgAutomationReferenceQueue();
   check(reference.items.every(i=>!('truMotionMode' in i.settings)&&i.manual_checks[0].includes('TruMotion')),'reference motion control is a visible manual check, not an unsupported pin');
   check(reference.items.filter(i=>i.signal_format==='hdr10').every(i=>i.settings.hdrDynamicToneMapping==='off'),'HDR reference pins the confirmed tone-mapping control');
   pgAutomation.pendingChecks=null;pgAutomation.lastProblem='';pgAutomation.statusError='';
   pgAutomation.current={run:null,preflight:{id:'test',status:'checking',queue_name:'Reference settings',total_items:6,active_item:1,message:'Checking energySaving',elapsed_seconds:30,items:[{status:'checked'},{status:'checking'}],issues:[]}};
   pgAutomationRenderLiveRun(null,null);
   check(pgAutomationEl('Progress').textContent.includes('Checking job 2 of 6')&&pgAutomationEl('Progress').textContent.includes('energySaving')&&pgAutomationEl('State').textContent==='Checking','startup job and control progress is shown before any runner exists');
   Object.assign(pgAutomation.current.preflight,{status:'blocked',issues:[{item_number:1,level:'error',message:'unsupportedPin: TV rejected control. Configure this job.'}]});pgAutomationRenderLiveRun(null,null);
   check(pgAutomationEl('Progress').getAttribute('role')==='alert'&&pgAutomationEl('Progress').textContent.includes('Job 2: unsupportedPin')&&pgAutomationEl('Progress').querySelector('details').open,'startup blockers are prominent, expanded, job-specific errors');
   const run={id:'run',status:'running',active_item:1,active_stage:'greyscale-done',heartbeat_age:2,items:[{name:'DV',status:'complete'},{name:'HDR',status:'running'},{name:'SDR',status:'queued'}],worker_status:{current_name:'50% white',current_step:12,total_steps:26}};
   pgAutomation.current={run};pgAutomationRenderLiveRun(run,null);
   check(pgAutomationEl('Progress').textContent.includes('Job 2 of 3: HDR')&&pgAutomationEl('Progress').textContent.includes('12 of 26 patches')&&pgAutomationEl('Live').querySelector('[aria-current="step"] strong').textContent==='2. HDR','run progress identifies current job, patch and highlighted queue position');
   Object.assign(run,{status:'failed',failure:{stage:'greyscale-done',message:'Meter disconnected'}});run.items[1].failure={stage:'greyscale-done',message:'Meter disconnected'};run.items[1].status='failed';pgAutomationRenderLiveRun(run,null);
   check(pgAutomationEl('Progress').textContent.includes('Meter disconnected')&&pgAutomationEl('Progress').dataset.error==='true','run failures remain visible with the exact stage and cause');
   const resumed={...run,status:'starting',active_stage:'readiness',failure:null,heartbeat_age:null,worker_status:{message:'Starting the resumed runner'}};
   pgAutomation.current={run:resumed};pgAutomationRenderLiveRun(resumed,null);
   check(pgAutomationEl('Progress').dataset.error==='false'&&pgAutomationEl('Progress').textContent.includes('Previous attempt:')&&!pgAutomationEl('Progress').textContent.includes('Patch 12'),'Resume distinguishes the previous failure from current preparation');
   pgAutomation.current={run};pgAutomationRenderLiveRun(run,null);
   const stopped={...run,status:'stopped',queue_name:'Old reference batch'};pgAutomation.current={run:stopped};pgAutomationRenderLiveRun(stopped,null);
   check(pgAutomationEl('Progress').textContent.includes('Clear last batch')&&!pgAutomationEl('Progress').textContent.includes('Patch 12')&&pgAutomationEl('Progress').dataset.error==='false','stopped batch has a clear action, not a stale active-job error');
   check(!pgAutomationEl('Live').textContent.includes('Heartbeat')&&!pgAutomationEl('Live').querySelector('[aria-current="step"]'),'stopped job list has no live heartbeat or current step');
   pgAutomation.current={run};pgAutomationRenderLiveRun(run,null);
   const originalFetch=window.fetchJSON;window.fetchJSON=async()=>null;
   // One missed poll is a delay; the connection error appears after three in a row.
   try{await pgAutomationPollLive();check(pgAutomation.current.run===run&&pgAutomation.pollDelayed&&!pgAutomationEl('Progress').textContent.includes('progress is unconfirmed'),'one lost status request retains the last known run as a delay');
    await pgAutomationPollLive();await pgAutomationPollLive();check(pgAutomation.current.run===run&&pgAutomationEl('Progress').textContent.includes('progress is unconfirmed'),'repeated lost status requests retain last known run and show a connection error');}
   finally{window.fetchJSON=originalFetch;if(pgAutomation.liveTimer)clearTimeout(pgAutomation.liveTimer);pgAutomation.liveTimer=null;}
   return checks;
  });
  assert.deepEqual(errors,[]);
  console.log(results.map(x=>'PASS '+x).join('\n'));
  console.log(defaultsChecks.map(x=>'PASS '+x).join('\n'));
  console.log(gammaChecks.map(x=>'PASS '+x).join('\n'));
  console.log(queueChecks.map(x=>'PASS '+x).join('\n'));
  console.log(progressChecks.map(x=>'PASS '+x).join('\n'));
  console.log('PASS phone width and no browser errors');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
