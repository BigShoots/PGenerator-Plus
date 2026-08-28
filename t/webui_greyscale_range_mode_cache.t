use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempfile);

my $webui="$Bin/../usr/share/PGenerator/webui-app.js";
open(my $fh,'<',$webui) or die "Unable to read $webui: $!";
local $/;
my $source=<$fh>;
close($fh);

like($source,qr/if\(code!=null\) return meterGreySignalFractionFromCode\(code\);/,
 'ordinary greyscale targets decode the emitted code');
like($source,qr/function meterSeriesSnapshotContentModes\(/,
 'series cache validates mode stamps in snapshot content');

my ($jsfh,$jsfile)=tempfile('pgen-grey-range-mode-XXXX',SUFFIX=>'.js',UNLINK=>1);
print {$jsfh} <<'JS';
'use strict';
const fs=require('fs');
const assert=require('assert');
const source=fs.readFileSync(process.argv[2],'utf8');
function functionSource(name){
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

let limited=true;
let custom=false;
global.meterGreyAllowsHeadroomTargets=()=>false;
global.meterChartIsDv=()=>false;
global.meterChartIsPq=()=>false;
global.meterGreyscaleCustomTargetActive=()=>custom;
global.meterGreyStimulusFraction=ire=>Number(ire)/100;
global.meterGreySignalFractionFromCode=code=>limited?(Number(code)-16)/219:Number(code)/255;
const targetSignal=eval('('+functionSource('meterGreyTargetSignal')+')');
const targetCode=eval('('+functionSource('meterGreyChartTargetCode')+')');

limited=true;
const limitedSignal=targetSignal(90,213);
assert(Math.abs(limitedSignal-197/219)<1e-12,'Limited 90% decodes code 213');
assert(Math.abs(Math.pow(limitedSignal,2.2)*100-79.22251855645268)<1e-10,'Limited target is 79.223 nits');
limited=false;
const fullSignal=targetSignal(90,230);
assert(Math.abs(fullSignal-230/255)<1e-12,'Full 90% decodes code 230');
assert(Math.abs(Math.pow(fullSignal,2.2)*100-79.69165429079781)<1e-10,'Full target is 79.692 nits');
assert.strictEqual(targetCode({r:213}),213,'SDR chart retains its patch code');
custom=true;
assert.strictEqual(targetSignal(90,213),0.9,'Custom Greyscale remains nominal');

const contentModes=eval('('+functionSource('meterSeriesSnapshotContentModes')+')');
global.meterSeriesSnapshotContentModes=contentModes;
const withoutVariants=eval('('+functionSource('meterSeriesSnapshotWithoutModeVariants')+')');
global.meterSeriesSnapshotWithoutModeVariants=withoutVariants;
const forMode=eval('('+functionSource('meterSeriesSnapshotForMode')+')');

const hdr={signal_mode:'hdr10',steps:[{signal_mode:'hdr10'}],readings:[{signal_mode:'hdr10',ire:90}]};
assert(forMode(hdr,'hdr10'),'HDR snapshot restores in HDR');
assert.strictEqual(forMode(hdr,'sdr'),null,'HDR snapshot cannot restore in SDR');
const contaminated={signal_mode:'sdr',steps:[{signal_mode:'sdr'}],readings:[{signal_mode:'hdr10'}]};
assert.strictEqual(forMode(contaminated,'sdr'),null,'mixed-mode snapshot is rejected');
const untagged={steps:[{ire:90}],readings:[{ire:90}]};
assert.strictEqual(forMode(untagged,'sdr'),null,'untagged snapshot cannot adopt the live mode');
const variants={signal_mode:'hdr10',mode_snapshots:{
 hdr10:{signal_mode:'hdr10',readings:[{signal_mode:'hdr10'}]},
 sdr:{signal_mode:'sdr',readings:[{signal_mode:'sdr'}]}
}};
assert.strictEqual(forMode(variants,'sdr').signal_mode,'sdr','SDR variant restores independently');
assert.strictEqual(forMode(variants,'hdr10').signal_mode,'hdr10','HDR variant restores independently');
JS
close($jsfh) or die "Unable to close $jsfile: $!";

SKIP: {
 my $node_version=`node --version 2>/dev/null`;
 skip 'node is required to execute WebUI range/cache functions',1
  if(!defined($node_version) || $node_version!~/v\d+/);
 my $status=system('node',$jsfile,$webui);
 is($status,0,'greyscale target range and mode-cache regression passes');
}

done_testing();
