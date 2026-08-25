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

like($source,qr/function meterColorPatchRgbBalance\(reading,whiteRef,blackRef,includeLuminance\)/,
 'color RGB balance accepts the luminance mode');
like($source,qr/meterColorDeltaTargetXYZ\(reading,!!includeLuminance\)/,
 'color RGB balance uses the luminance-inclusive target when requested');
like($source,qr/meterColorPatchRgbBalance\(reading,whiteRef,blackRef,includeLuminance\)/,
 'live RGB passes the color luminance toggle through');

my ($jsfh,$jsfile)=tempfile('pgen-color-rgb-XXXX',SUFFIX=>'.js',UNLINK=>1);
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

global.meterReadingXYZ=value=>value||null;
global.meterAnalysisGamut=()=>({xyzToRgb:[[1,0,0],[0,1,0],[0,0,1]]});
global.xyzToLinRgb=(X,Y,Z,matrix)=>[X,Y,Z];
let target={X:0.4,Y:0.2,Z:0.1};
global.meterColorDeltaTargetXYZ=(reading,includeLuminance)=>{
 if(includeLuminance) return {...target};
 const scale=reading.Y/target.Y;
 return {X:target.X*scale,Y:reading.Y,Z:target.Z*scale};
};
const meterColorPatchRgbBalance=eval('('+functionSource('meterColorPatchRgbBalance')+')');

const white={X:1,Y:1,Z:1};
const black={X:0,Y:0,Z:0};
const exact=meterColorPatchRgbBalance({...target},white,black,true);
for(const channel of ['R','G','B']) assert(Math.abs(exact[channel]-100)<1e-10,channel+' exact target');

const dim={X:target.X*0.8,Y:target.Y*0.8,Z:target.Z*0.8};
const chromaOnly=meterColorPatchRgbBalance(dim,white,black,false);
for(const channel of ['R','G','B']) assert(Math.abs(chromaOnly[channel]-100)<1e-10,channel+' chroma only');
const inclusive=meterColorPatchRgbBalance(dim,white,black,true);
assert(inclusive.R<99&&inclusive.G<99&&inclusive.B<99,'inclusive RGB exposes luminance miss');
assert(Math.abs(inclusive.R-80)<1e-10,'dominant channel reports the 20 percent luminance deficit');
JS
close($jsfh) or die "Unable to close $jsfile: $!";

my $status=system('node',$jsfile,$webui);
is($status,0,'numeric RGB regression passes with the production JavaScript function');

done_testing();
