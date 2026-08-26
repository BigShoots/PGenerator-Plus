use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempfile);

# Executed coverage for the Full AutoCal controller-ownership primitives:
# controller identity, the saved-state lease, adoption eligibility, the
# can-drive matrix, and the clear/save guards. These functions are what stop
# a second tab from starting duplicate 3D/DV workers — and what let a
# reopened browser adopt an abandoned run instead of leaving it undrivable.

my $node_version=`node --version 2>/dev/null`;
plan skip_all => 'node is required to execute the ownership functions'
 if(!defined($node_version) || $node_version!~/v\d+/);

my $workspace="$Bin/../usr/share/PGenerator/webui-workspace.js";

my ($jsfh,$jsfile)=tempfile('pgen-fullautocal-owner-XXXX',SUFFIX=>'.js',UNLINK=>1);
print {$jsfh} <<'JS';
'use strict';
const fs=require('fs');
const assert=require('assert');
const source=fs.readFileSync(process.argv[2],'utf8');
function functionSource(name){
 const start=source.indexOf('function '+name+'(');
 assert(start>=0,'missing '+name);
 const brace=source.indexOf('{',start);
 let depth=0;
 for(let i=brace;i<source.length;i++){
  if(source[i]==='{') depth++;
  else if(source[i]==='}'&&--depth===0) return source.slice(start,i+1);
 }
 throw new Error('unterminated '+name);
}

// Controllable clock; the real Date is not needed by these functions.
let nowMs=1700000000000;
global.Date={ now:()=>nowMs };

function makeStorage(){
 const m=new Map();
 return {
  getItem:k=>m.has(k)?m.get(k):null,
  setItem:(k,v)=>{ m.set(k,String(v)); },
  removeItem:k=>{ m.delete(k); },
 };
}
global.sessionStorage=makeStorage();
global.localStorage=makeStorage();
global.METER_FULL_AUTOCAL_STATE_KEY='meterFullAutoCalState';
global.meterFullAutoCalControllerIdCache='';
global.meterFullAutoCalRunning=false;
global.meterFullAutoCalRunId=null;
global.meterFullAutoCalPhase='';
global.meterAutoCalRecordRunId=null;
global.meterAutoCalRecordToken='client-run-test';
global.meterFullAutoCalStartedAt=null;
global.meterFullAutoCalConfig=null;
global.meterFullAutoCalReportData=null;
global.meterFullAutoCalDefaultConfig=()=>({});
global.meterFullAutoCalDefaultReportData=()=>({});

const leaseMatch=source.match(/const METER_FULL_AUTOCAL_LEASE_MS=([^;]+);/);
assert(leaseMatch,'missing METER_FULL_AUTOCAL_LEASE_MS');
global.METER_FULL_AUTOCAL_LEASE_MS=eval(leaseMatch[1]);
const LEASE=global.METER_FULL_AUTOCAL_LEASE_MS;
assert(LEASE>=60000,'lease must give a live tab time to heartbeat');

for(const name of ['meterFullAutoCalControllerId','meterFullAutoCalSavedStateOwnedByThisTab',
                   'meterFullAutoCalSavedStateAbandoned','meterFullAutoCalReadSavedState',
                   'meterFullAutoCalCanDriveStatus','meterFullAutoCalClearSavedState',
                   'meterFullAutoCalSaveState','meterFullAutoCalStatusRunId',
                   'meterFullAutoCalStatusMatchesRun']){
 global[name]=eval('('+functionSource(name)+')');
}

// Identity is stable within a tab and survives the cache being dropped.
const myId=meterFullAutoCalControllerId();
assert(myId,'controller id generated');
global.meterFullAutoCalControllerIdCache='';
assert.strictEqual(meterFullAutoCalControllerId(),myId,'identity is stable via sessionStorage');

function writeSaved(saved){ localStorage.setItem(METER_FULL_AUTOCAL_STATE_KEY,JSON.stringify(saved)); }
function readSaved(){ return JSON.parse(localStorage.getItem(METER_FULL_AUTOCAL_STATE_KEY)||'null'); }

// Ownership requires an exact controller-id match on an active record.
assert(meterFullAutoCalSavedStateOwnedByThisTab({active:true,controllerId:myId}),'own record is owned');
assert(!meterFullAutoCalSavedStateOwnedByThisTab({active:true,controllerId:'tab-other'}),'foreign record is not owned');
assert(!meterFullAutoCalSavedStateOwnedByThisTab({active:false,controllerId:myId}),'inactive record is not owned');
assert(!meterFullAutoCalSavedStateOwnedByThisTab(null),'no record is not owned');

// Abandonment: a foreign record becomes adoptable only after its lease lapses.
const fresh={active:true,controllerId:'tab-other',runId:'r1',updated:nowMs};
assert(!meterFullAutoCalSavedStateAbandoned(fresh),'a fresh foreign lease is not abandoned');
const stale={active:true,controllerId:'tab-other',runId:'r1',updated:nowMs-LEASE-1000};
assert(meterFullAutoCalSavedStateAbandoned(stale),'a lapsed foreign lease is abandoned');
assert(!meterFullAutoCalSavedStateAbandoned({active:true,controllerId:myId,updated:nowMs-LEASE-1000}),
 'our own record is never "abandoned"');

// Can-drive matrix. Not running + no saved ownership => observer only.
global.meterFullAutoCalRunning=false;
localStorage.removeItem(METER_FULL_AUTOCAL_STATE_KEY);
assert(meterFullAutoCalCanDriveStatus({}),'a non-workflow status is always drivable');
assert(!meterFullAutoCalCanDriveStatus({full_workflow:true,full_autocal_run_id:'r1'}),
 'without ownership a workflow status is not drivable');
writeSaved({active:true,controllerId:'tab-other',runId:'r1',updated:nowMs});
assert(!meterFullAutoCalCanDriveStatus({full_workflow:true,full_autocal_run_id:'r1'}),
 'another tab\'s live record does not grant drive rights');
writeSaved({active:true,controllerId:myId,runId:'r1',updated:nowMs});
assert(meterFullAutoCalCanDriveStatus({full_workflow:true,full_autocal_run_id:'r1'}),
 'the owning tab may drive its own run');
assert(!meterFullAutoCalCanDriveStatus({full_workflow:true,full_autocal_run_id:'r2'}),
 'the owning tab may not drive a different run');

// Running owner: a transient foreign status tick does not revoke ownership;
// the poller skips that tick with its separate run-id check. But when another
// tab adopts the SAME run, its fresh lease immediately demotes the old owner.
global.meterFullAutoCalRunning=true;
global.meterFullAutoCalRunId='r1';
writeSaved({active:true,controllerId:myId,runId:'r1',updated:nowMs});
assert(meterFullAutoCalCanDriveStatus({full_workflow:true,full_autocal_run_id:'r1'}),
 'a running owner drives its own run');
assert(meterFullAutoCalCanDriveStatus({full_workflow:true,full_autocal_run_id:'r2'}),
 'a foreign status tick does not revoke a valid owner lease');
writeSaved({active:true,controllerId:'tab-adopter',runId:'r1',updated:nowMs});
assert(!meterFullAutoCalCanDriveStatus({full_workflow:true,full_autocal_run_id:'r1'}),
 'a fresh adopter lease demotes the former in-memory owner');
writeSaved({active:true,controllerId:'tab-adopter',runId:'r1',updated:nowMs-LEASE-1000});
assert(!meterFullAutoCalCanDriveStatus({full_workflow:true,full_autocal_run_id:'r1'}),
 'an old owner cannot reclaim the run merely because the adopter lease expired');
writeSaved({active:true,controllerId:'tab-other-run',runId:'r0',updated:nowMs});
assert(meterFullAutoCalCanDriveStatus({full_workflow:true,full_autocal_run_id:'r1'}),
 'a leftover record for another run does not demote the current run');
global.meterFullAutoCalRunning=false;
global.meterFullAutoCalRunId=null;

// Clear guard: a LIVE foreign record survives, an abandoned one is removable.
writeSaved({active:true,controllerId:'tab-other',runId:'r1',updated:nowMs});
meterFullAutoCalClearSavedState();
assert(readSaved(),'clearing cannot delete another tab\'s live record');
writeSaved({active:true,controllerId:'tab-other',runId:'r1',updated:nowMs-LEASE-1000});
meterFullAutoCalClearSavedState();
assert.strictEqual(readSaved(),null,'an abandoned record is removable');
writeSaved({active:true,controllerId:myId,runId:'r1',updated:nowMs});
meterFullAutoCalClearSavedState();
assert.strictEqual(readSaved(),null,'our own record is removable');

// Save guard: a running tab must not steal back a run another tab adopted.
global.meterFullAutoCalRunning=true;
global.meterFullAutoCalRunId='r1';
writeSaved({active:true,controllerId:'tab-adopter',runId:'r1',updated:nowMs});
meterFullAutoCalSaveState();
assert.strictEqual(readSaved().controllerId,'tab-adopter',
 'a live adopted lease for the same run is not overwritten');
writeSaved({active:true,controllerId:'tab-dead',runId:'r0',updated:nowMs});
meterFullAutoCalSaveState();
assert.strictEqual(readSaved().controllerId,myId,
 'a leftover record for a different run is overwritten normally');
assert.strictEqual(readSaved().runId,'r1','the new record carries our run id');
assert.strictEqual(readSaved().recordToken,'client-run-test','the begin token survives lease persistence');
global.meterFullAutoCalRunning=false;

assert(source.includes("if(r.full_workflow&&!meterFullAutoCalCanDriveStatus(r))"),
 'the poller checks ownership even for an in-memory running tab');
assert(/if\(r\.full_workflow&&!meterFullAutoCalCanDriveStatus\(r\)\)[\s\S]*?meterFullAutoCalResetState\(false\)/.test(source),
 'the poller demotes a former owner that lost its lease');

console.log('fullautocal-owner-ok');
JS
close($jsfh);

my $out=`node $jsfile $workspace 2>&1`;
my $rc=$?;
is($rc,0,'ownership harness runs cleanly') or diag($out);
like($out,qr/fullautocal-owner-ok/,'all ownership assertions hold');

done_testing();
