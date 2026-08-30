use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempfile);

my $app="$Bin/../usr/share/PGenerator/webui-app.js";
my $workspace="$Bin/../usr/share/PGenerator/webui-workspace.js";

open(my $app_fh,'<',$app) or die "Unable to read $app: $!";
open(my $workspace_fh,'<',$workspace) or die "Unable to read $workspace: $!";
local $/;
my $app_source=<$app_fh>;
my $workspace_source=<$workspace_fh>;
close($app_fh);
close($workspace_fh);

like($app_source,qr/function meterInstallServerSeriesSteps\(/,
 'browser has an explicit server-step authority boundary');
like($app_source,qr/const METER_SERIES_DISPLAY_LIMIT=4096;/,
 'browser declares one bounded display-lattice limit');
like($app_source,qr/function meterReplaceReadings\(/,
 'browser owns reading replacement and index rebuild in one function');
like($app_source,qr/const METER_SERIES_CACHE_SCHEMA=2;/,
 'browser cache has a versioned normalized schema');
unlike($app_source,qr/meterSeriesCachePersistTimer=setTimeout\([^;]+,0\)/s,
 'cache persistence is not scheduled as an immediate full-cache write');
like($workspace_source,qr/function meterBuildPreviewStepsJS\(/,
 'client-side expansion is named as preview-only');
unlike($workspace_source,qr/keep the client copy/,
 'polling never prefers a client lattice over server-returned steps');
my @raw_reading_assignments=($app_source.$workspace_source)=~/\bmeterReadings\s*=/g;
is(scalar(@raw_reading_assignments),2,
 'all runtime reading replacements go through the index-owning setter');

my ($jsfh,$jsfile)=tempfile('pgen-series-runtime-XXXX',SUFFIX=>'.js',UNLINK=>1);
print {$jsfh} <<'JS';
'use strict';
const fs=require('fs');
const assert=require('assert');
const app=fs.readFileSync(process.argv[2],'utf8');

function functionSource(source,name){
 const start=source.indexOf('function '+name+'(');
 assert(start>=0,'missing '+name);
 const brace=source.indexOf('{',start);
 let depth=0,state='code',escape=false;
 for(let i=brace;i<source.length;i++){
  const c=source[i],n=source[i+1];
  if(state==='line'){ if(c==='\n') state='code'; continue; }
  if(state==='block'){ if(c==='*'&&n==='/'){ state='code'; i++; } continue; }
  if(state!=='code'){
   if(escape){ escape=false; continue; }
   if(c==='\\'){ escape=true; continue; }
   if(c===state) state='code';
   continue;
  }
  if(c==='/'&&n==='/'){ state='line'; i++; continue; }
  if(c==='/'&&n==='*'){ state='block'; i++; continue; }
  if(c==='"'||c==="'"||c==='`'){ state=c; continue; }
  if(c==='{') depth++;
  else if(c==='}'&&--depth===0) return source.slice(start,i+1);
 }
 throw new Error('unterminated '+name);
}
function load(name){
 const fn=eval('('+functionSource(app,name)+')');
 global[name]=fn;
 return fn;
}

global.pqEncodeNormalized=n=>n<=0?0:Math.pow(n/10000,1/2.4);
global.METER_SERIES_DISPLAY_LIMIT=4096;
global.meterLatticeDisplayCache=new Map();
global.meterLatticeCountCache=new Map();
[
 'meterLatticeGcd','meterLatticeSpreadOrder','meterLatticeSanitizeParams',
 'meterLatticeAxisFracs','meterLatticePct','meterLatticeKeepNode',
 'meterLatticeParamsKey','meterLatticeMakePatch','meterLatticeCornerRank',
 'meterLatticeExpandPatches','meterLatticeDisplayPatches',
 'meterLatticeNodeMeta','meterLatticeSpreadStride','meterLatticeModInverse',
 'meterLatticeCountForParams'
].forEach(load);

for(const params of [
 {size:3,grey_points:0,threshold_pct:0,order:'grid'},
 {size:5,grey_points:11,threshold_pct:0,order:'spread',reverse:true},
 {size:9,grey_points:0,threshold_pct:7.5,order:'spread'},
 {size:9,grey_points:0,threshold_pct:12.5,order:'grid',spacing:'light',pq:true,peak_nits:1000}
]){
 const full=meterLatticeExpandPatches(params);
 const display=meterLatticeDisplayPatches(params,full.length+1);
 assert.deepStrictEqual(display,full,'uncapped display order is byte-for-byte equivalent');
}

for(const params of [
 {size:17,grey_points:21,threshold_pct:0,order:'spread',reverse:false},
 {size:17,grey_points:0,threshold_pct:0,order:'spread',reverse:true},
 {size:13,grey_points:11,threshold_pct:8.5,order:'grid',reverse:true},
 {size:13,grey_points:0,threshold_pct:17.5,order:'spread',reverse:false,spacing:'light',pq:true,peak_nits:4000}
]){
 const full=meterLatticeExpandPatches(params);
 const cap=127;
 const expected=[];
 for(let i=0;i<cap;i++) expected.push(full[Math.floor(i*full.length/cap)]);
 expected[expected.length-1]=full[full.length-1];
 assert.deepStrictEqual(meterLatticeDisplayPatches(params,cap),expected,
  'bounded display sampling preserves exact full-expansion order and values');
}

let keepCalls=0;
const originalKeep=global.meterLatticeKeepNode;
global.meterLatticeKeepNode=(...args)=>{ keepCalls++; return originalKeep(...args); };
assert.strictEqual(meterLatticeCountForParams({size:50,threshold_pct:0}),125000,
 'zero-threshold count is exact');
assert.strictEqual(keepCalls,0,'zero-threshold count does not scan the lattice');
const large=meterLatticeDisplayPatches({size:50,grey_points:101,threshold_pct:0,order:'spread'},4096);
assert.strictEqual(large.length,4096,'large display lattice is bounded');
assert(Object.isFrozen(large)&&large.every(Object.isFrozen),'cached display samples are immutable');
assert.strictEqual(
 meterLatticeDisplayPatches({size:50,grey_points:101,threshold_pct:0,order:'spread'},4096),large,
 'complete sanitized display key reuses the immutable sample'
);
let patchAllocations=0;
const originalMakePatch=global.meterLatticeMakePatch;
global.meterLatticeMakePatch=(...args)=>{ patchAllocations++; return originalMakePatch(...args); };
meterLatticeDisplayPatches({size:50,grey_points:101,threshold_pct:0,order:'spread',reverse:true},4096);
assert(patchAllocations<=4096,'size-50 redraw allocates no more than the display cap of patch objects');
global.meterLatticeMakePatch=originalMakePatch;

global.meterSeriesSteps=[];
global.meterExecutedSeriesSteps=[];
global.meterExecutedSeriesId=null;
global.meterFreshStepCache=null;
global.meterCanonicalStepCacheSource=null;
global.meterCanonicalStepCache=null;
global.meterRecoveryDisplaySteps=(type,points,steps)=>steps;
global.meterCanonicalRecoveredSteps=(type,points,steps)=>steps.map(step=>({...step}));
global.meterApplyColorSeriesTargetWhiteReference=steps=>steps;
const install=load('meterInstallServerSeriesSteps');
const response={series_id:'run-7',steps:[{name:'A',r:1},{name:'B',r:2}]};
const installed=install(response,'colors',1234,false);
assert.deepStrictEqual(installed.map(s=>s.name),['A','B'],'server order is installed unchanged');
assert.strictEqual(global.meterSeriesSteps,installed,'full run uses installed server steps');
assert(Object.isFrozen(installed)&&installed.every(Object.isFrozen),'executed steps are immutable');

global.meterStepNameKey=reading=>String(reading&&reading.name||'');
global.meterNormalizeMeasuredReading=()=>{};
global.meterCanonicalSeriesStep=step=>step;
global.meterStampReadingStepMeta=()=>{};
global.meterReadings=[];
global.meterReadingsIndex=new Map();
global.meterReadingsIndexSource=global.meterReadings;
global.meterReadingsIndexLength=0;
load('meterReadingIndexKeys');
load('meterRebuildReadingsIndex');
load('meterReplaceReadings');
load('meterEnsureReadingsIndex');
const upsert=load('meterUpsertSeriesReading');
for(let i=0;i<3000;i++) upsert({name:'P'+i,luminance:i},null);
assert.strictEqual(global.meterReadings.length,3000,'indexed upsert appends unique readings');
upsert({name:'P1500',luminance:42},null);
assert.strictEqual(global.meterReadings.length,3000,'indexed upsert replaces without duplicating');
assert.strictEqual(global.meterReadings[1500].luminance,42,'indexed replacement targets the correct entry');
meterReplaceReadings([{name:'fresh'}]);
upsert({name:'fresh',luminance:9},null);
assert.strictEqual(global.meterReadings.length,1,'replacement rebuilds the reading index');
assert.strictEqual(global.meterReadings[0].luminance,9,'rebuilt index addresses the replacement array');

global.meterActiveSeriesType='colors';
global.meterActiveSeriesPoints=30;
global.meterSeriesRunning=false;
global.meterSeriesChartRevision=1;
global.meterActiveSeriesSignalMode='hdr10';
global.meterActiveSeriesTargetGamma='st2084';
global.meterActiveSeriesMaxLuma=1000;
global.meterActiveSeriesDvMapMode=null;
global.meterActiveSeriesDvInterface=null;
global.meterCurrentPatchStep=null;
global.meterFreshStepCache=null;
global.window={meterPatchBitDepth:()=>10,meterPatchUsesVideoRange:()=>true};
global.meterCustomSeriesById=()=>null;
global.meterCanonicalSeriesStep=step=>step;
let builds=0;
global.meterBuildPreviewStepsJS=()=>{ builds++; return [{name:'A'},{name:'B'}]; };
global.meterFreshSeriesContextKey=load('meterFreshSeriesContextKey');
const freshStep=load('meterFreshSeriesStep');
assert.strictEqual(freshStep({name:'A'}).name,'A');
assert.strictEqual(freshStep({name:'B'}).name,'B');
assert.strictEqual(builds,1,'fresh-step list and index are reused in one context');
global.meterSeriesChartRevision++;
freshStep({name:'A'});
assert.strictEqual(builds,2,'a changed series context replaces the prepared list');

global.METER_SERIES_CACHE_SCHEMA=2;
global.meterSeriesSnapshotWithoutModeVariants=load('meterSeriesSnapshotWithoutModeVariants');
global.meterSeriesSnapshotContentModes=load('meterSeriesSnapshotContentModes');
global.meterSeriesSnapshotSignalMode=load('meterSeriesSnapshotSignalMode');
const normalizeEntry=load('meterSeriesCacheNormalizeEntry');
const restoreEntry=load('meterSeriesCacheRestoreEntry');
const sharedSdr=[{name:'S',signal_mode:'sdr',luminance:1}];
const sharedHdr=[{name:'H',signal_mode:'hdr10',luminance:2}];
const cacheEntry={signal_mode:'hdr10',updated_at:2,readings:sharedHdr,mode_snapshots:{
 sdr:{signal_mode:'sdr',updated_at:1,readings:sharedSdr,observer_readings:{two:{readings:[...sharedSdr]}}},
 hdr10:{signal_mode:'hdr10',updated_at:2,readings:sharedHdr,observer_readings:{two:{readings:[...sharedHdr]}}}
}};
const normalized=normalizeEntry(cacheEntry);
assert.strictEqual(Object.keys(normalized.reading_sets).length,2,
 'mode and observer references share two owned reading sets');
const restored=restoreEntry(JSON.parse(JSON.stringify(normalized)));
assert.strictEqual(restored.mode_snapshots.sdr.readings,restored.mode_snapshots.sdr.observer_readings.two.readings,
 'restored observer references the mode-owned SDR readings');
assert.strictEqual(restored.mode_snapshots.hdr10.readings,restored.mode_snapshots.hdr10.observer_readings.two.readings,
 'restored observer references the mode-owned HDR readings');

let clock=1000,persistCalls=0,deadline=null,timerId=0;
global.Date.now=()=>clock;
global.setTimeout=(fn,ms)=>{ deadline={fn,ms,started:clock}; return ++timerId; };
global.clearTimeout=()=>{};
global.requestIdleCallback=(fn,options)=>{ global.idle={fn,options,started:clock}; return 77; };
global.cancelIdleCallback=()=>{};
global.meterSeriesCachePersistTimer=null;
global.meterSeriesCachePersistIdle=null;
global.meterSeriesCacheDirtySince=0;
global.meterSeriesCacheDirtyReadings=0;
global.meterSeriesCacheDirtyKeys=new Set(['colors-30']);
global.METER_SERIES_CACHE_CHECKPOINT_MS=5000;
global.METER_SERIES_CACHE_READING_CHECKPOINT=25;
global.meterPersistSeriesCache=()=>{ persistCalls++; };
global.meterFlushScheduledSeriesCache=load('meterFlushScheduledSeriesCache');
const schedule=load('meterScheduleSeriesCachePersist');
for(let i=0;i<24;i++){ schedule(1); clock+=100; }
assert.strictEqual(persistCalls,0,'twenty-four readings remain inside the checkpoint');
assert.strictEqual(deadline.started,1000,'deadline stays anchored to the first dirty reading');
assert.strictEqual(deadline.ms,5000,'time checkpoint is five seconds');
schedule(1);
assert.strictEqual(persistCalls,1,'twenty-five readings force an immediate checkpoint');
schedule(1);
assert.strictEqual(persistCalls,1,'post-checkpoint dirty state starts a new interval');
deadline.fn();
assert.strictEqual(persistCalls,2,'deadline flush limits crash loss to one interval');
JS
close($jsfh) or die "Unable to close $jsfile: $!";

SKIP: {
 my $node_version=`node --version 2>/dev/null`;
 skip 'node is required to execute WebUI series runtime functions',1
  if(!defined($node_version) || $node_version!~/v\d+/);
 my $status=system('node',$jsfile,$app);
 is($status,0,'bounded and crash-safe series runtime regression passes');
}

done_testing();
