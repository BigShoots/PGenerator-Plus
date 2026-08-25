use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempfile);

my $webui="$Bin/../usr/share/PGenerator/webui-workspace.js";
open(my $fh,'<',$webui) or die "Unable to read $webui: $!";
local $/;
my $source=<$fh>;
close($fh);

like($source,qr/meterPrepareAutoCalTargetGamma\(\);/,
 'AutoCal setup normalizes the target gamma for the active signal mode');
like($source,qr/meterStopAutoCal[\s\S]+meterRestoreTargetGammaAfterAutoCal/,
 'stopping AutoCal restores the HDR verification target');
like($source,qr/meterFullAutoCalComplete[\s\S]+meterRestoreTargetGammaAfterAutoCal/,
 'completing Full AutoCal restores the HDR verification target');

my ($jsfh,$jsfile)=tempfile('pgen-hdr-target-gamma-XXXX',SUFFIX=>'.js',UNLINK=>1);
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

let signalMode='sdr';
const gamma={value:'bt1886'};
let syncCount=0;
let saveCount=0;
global.document={getElementById:id=>id==='meterTargetGamma'?gamma:null};
global.getVal=id=>id==='signal_mode'?signalMode:'';
global.meterSyncTargetGammaControl=()=>{syncCount++;};
global.saveMeterSettings=()=>{saveCount++;};

const prepare=eval('('+functionSource('meterPrepareAutoCalTargetGamma')+')');
const restore=eval('('+functionSource('meterRestoreTargetGammaAfterAutoCal')+')');

signalMode='hdr10';
gamma.value='st2084';
assert.strictEqual(prepare(),'2.2','HDR10 AutoCal uses the 2.2 calibration target');
assert.strictEqual(gamma.value,'2.2');

gamma.value='bt1886';
assert.strictEqual(prepare(),'2.2','stale SDR gamma cannot survive into HDR10 AutoCal');

signalMode='dv';
gamma.value='st2084';
assert.strictEqual(prepare(),'2.2','Dolby Vision AutoCal uses the 2.2 calibration target');

signalMode='sdr';
gamma.value='2.4';
assert.strictEqual(prepare(),'2.4','valid SDR operator gamma is preserved');
gamma.value='st2084';
assert.strictEqual(prepare(),'bt1886','ST 2084 is sanitized only for SDR');

signalMode='hdr10';
gamma.value='2.2';
assert.strictEqual(restore(),true,'HDR10 restore is applied');
assert.strictEqual(gamma.value,'st2084','HDR10 verification returns to PQ');

signalMode='dv';
gamma.value='2.2';
assert.strictEqual(restore(),true,'Dolby Vision restore is applied');
assert.strictEqual(gamma.value,'st2084','Dolby Vision verification returns to PQ');

signalMode='sdr';
gamma.value='2.4';
assert.strictEqual(restore(),false,'SDR needs no HDR restore');
assert.strictEqual(gamma.value,'2.4','SDR operator gamma remains unchanged');
assert(syncCount>=7,'UI target-gamma state was synchronized');
assert(saveCount>=7,'target-gamma changes were persisted');
JS
close($jsfh) or die "Unable to close $jsfile: $!";

my $status=system('node',$jsfile,$webui);
is($status,0,'HDR AutoCal target-gamma regression passes with production JavaScript');

done_testing();
