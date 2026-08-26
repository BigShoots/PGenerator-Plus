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

# Whole-file regexes are vacuous here (a comment mentioning the function
# plus any later restore call satisfies them), so the wiring is asserted
# inside each terminal path's own function body.
sub function_source {
 my ($name)=@_;
 my $start=index($source,"function $name(");
 die "missing $name in webui-workspace.js" if($start<0);
 my $brace=index($source,'{',$start);
 my $depth=0;
 for(my $i=$brace;$i<length($source);$i++) {
  my $c=substr($source,$i,1);
  if($c eq '{') { $depth++; }
  elsif($c eq '}') { return substr($source,$start,$i-$start+1) if(--$depth==0); }
 }
 die "unterminated $name in webui-workspace.js";
}

# Every terminal exit of an HDR/DV run must restore the ST 2084 verification
# target: normal completion, close-complete, abort, and each stop/dismiss
# path reachable after the greyscale stage pinned the internal 2.2 target.
foreach my $fn (qw(meterAutoCalCloseComplete meterFullAutoCalComplete
                   meterFullAutoCalAbort meterStopAutoCal
                   meterStopDvAutoCalProfile meterStopLg3dAutoCal
                   meterCloseLg3dUploadRetry meterAutoCalConfirmAndStart
                   meterPollAutoCal)) {
 ok(index(function_source($fn),'meterRestoreTargetGammaAfterAutoCal')>=0,
  "$fn restores the HDR verification target");
}

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

SKIP: {
 my $node_version=`node --version 2>/dev/null`;
 skip 'node is required to execute the target-gamma functions',1
  if(!defined($node_version) || $node_version!~/v\d+/);
 my $status=system('node',$jsfile,$webui);
 is($status,0,'HDR AutoCal target-gamma regression passes with production JavaScript');
}

done_testing();
