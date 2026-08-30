use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempfile);
use JSON::PP qw(encode_json decode_json);

my $root="$Bin/..";
my $app="$root/usr/share/PGenerator/webui-app.js";
do "$root/usr/share/PGenerator/webui.pm" or die($@||$!);

my ($jsfh,$jsfile)=tempfile('pgen-lattice-parity-XXXX',SUFFIX=>'.js',UNLINK=>1);
print {$jsfh} <<'JS';
'use strict';
const fs=require('fs');
const assert=require('assert');
const source=fs.readFileSync(process.argv[2],'utf8');
const params=JSON.parse(process.argv[3]);
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
global.pqEncodeNormalized=n=>{
 if(!(n>0)) return 0;
 const m1=2610/16384,m2=2523/32,c1=3424/4096,c2=2413/128,c3=2392/128;
 const p=Math.pow(n/10000,m1);
 return Math.pow((c1+c2*p)/(1+c3*p),m2);
};
[
 'meterLatticeGcd','meterLatticeSpreadOrder','meterLatticeSanitizeParams',
 'meterLatticeAxisFracs','meterLatticePct','meterLatticeKeepNode',
 'meterLatticeMakePatch','meterLatticeCornerRank','meterLatticeExpandPatches'
].forEach(name=>{ global[name]=eval('('+functionSource(name)+')'); });
process.stdout.write(JSON.stringify(meterLatticeExpandPatches(params)));
JS
close($jsfh) or die "Unable to close $jsfile: $!";

my @fixtures=(
 {name=>'grid signal 8-bit full',params=>{size=>3,grey_points=>0,threshold_pct=>0,order=>'grid',reverse=>JSON::PP::false,spacing=>'signal',peak_nits=>1000,pq=>JSON::PP::false},min=>0,span=>255,max=>255},
 {name=>'reversed spread with greys',params=>{size=>5,grey_points=>11,threshold_pct=>0,order=>'spread',reverse=>JSON::PP::true,spacing=>'signal',peak_nits=>1000,pq=>JSON::PP::false},min=>16,span=>219,max=>255},
 {name=>'thresholded SDR light lattice',params=>{size=>9,grey_points=>0,threshold_pct=>8.5,order=>'spread',reverse=>JSON::PP::false,spacing=>'light',peak_nits=>100,pq=>JSON::PP::false},min=>64,span=>876,max=>1023},
 {name=>'thresholded PQ light lattice',params=>{size=>9,grey_points=>5,threshold_pct=>17.5,order=>'grid',reverse=>JSON::PP::true,spacing=>'light',peak_nits=>4000,pq=>JSON::PP::true},min=>64,span=>876,max=>1023},
);

my $node_version=`node --version 2>/dev/null`;
SKIP: {
 skip 'node is required for browser/server lattice parity',scalar(@fixtures)
  if(!defined($node_version)||$node_version!~/v\d+/);
 for my $fixture (@fixtures){
  my $params_json=encode_json($fixture->{params});
  open(my $node,'-|','node',$jsfile,$app,$params_json) or die "Unable to start node: $!";
  local $/;
  my $browser_json=<$node>;
  close($node) or die "Browser lattice expansion failed";
  my $patches=decode_json($browser_json);
  my $body=encode_json({custom_series=>JSON::PP::true,lattice_params=>$fixture->{params}});
  my @server_json=webui_lattice_series_steps_from_body(
   $body,$fixture->{min},$fixture->{span},$fixture->{max});
  my @server=map { decode_json($_) } @server_json;
  my @browser;
  for(my $i=0;$i<@{$patches};$i++){
   my $patch=$patches->[$i];
   push @browser,{
    ire=>$i+1,
    r=>int($fixture->{min}+$patch->{frac_r}*$fixture->{span}+0.5),
    g=>int($fixture->{min}+$patch->{frac_g}*$fixture->{span}+0.5),
    b=>int($fixture->{min}+$patch->{frac_b}*$fixture->{span}+0.5),
    name=>$patch->{name},input_max=>$fixture->{max},
   };
  }
  is_deeply(\@server,\@browser,"$fixture->{name}: complete ordered records match");
 }
}

done_testing();
