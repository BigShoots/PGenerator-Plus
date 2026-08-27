'use strict';

const fs=require('fs');
const path=require('path');
const root=path.resolve(__dirname,'..');
const source=fs.readFileSync(path.join(root,'usr/share/PGenerator/webui-app.js'),'utf8');
const fixture=JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/math_conformance.json'),'utf8'));

function functionSource(name){
 const start=source.indexOf('function '+name+'(');
 if(start<0) throw new Error('missing '+name);
 const brace=source.indexOf('{',start);
 let depth=0;
 for(let index=brace;index<source.length;index++){
  if(source[index]==='{') depth++;
  else if(source[index]==='}'&&--depth===0) return source.slice(start,index+1);
 }
 throw new Error('unterminated '+name);
}

const constantNames=['M1','M2','C1','C2','C3'];
const constants=constantNames.map(name=>{
 const match=source.match(new RegExp('^const PGEN_PQ_'+name+'=[^;]+;','m'));
 if(!match) throw new Error('missing PGEN_PQ_'+name);
 return match[0];
}).join('\n');
const bodies=['clampNum','pqEncodeNormalized','meterChartPqEncodeNormalized',
 'meterChartPqDecodeNormalized'].map(functionSource).join('\n');
const runtime=eval('(()=>{'+constants+'\n'+bodies+
 '\nreturn {encode:pqEncodeNormalized,chartEncode:meterChartPqEncodeNormalized,decode:meterChartPqDecodeNormalized};})()');

let checks=0;
function close(label,actual,expected){
 checks++;
 const tolerance=2e-12*Math.max(1,Math.abs(expected));
 if(Math.abs(actual-expected)>tolerance) throw new Error(label+': '+actual+' != '+expected);
}
for(const row of fixture.pq_encode){
 close('JS PQ encode '+row.nits,runtime.encode(row.nits),row.signal);
 close('JS chart PQ encode '+row.nits,runtime.chartEncode(row.nits),row.signal);
}
for(const row of fixture.pq_decode){
 close('JS PQ decode '+row.signal,runtime.decode(row.signal),row.nits);
}

if((source.match(/const PGEN_PQ_M1=/g)||[]).length!==1)
 throw new Error('JavaScript has more than one PQ constant owner');
if((source.match(/function meterChartPqEncodeNormalized\(nits\)\{\s*return pqEncodeNormalized\(nits\);\s*\}/g)||[]).length!==1)
 throw new Error('chart PQ encode does not delegate to the shared function');

console.log(checks+' JavaScript colour-math conformance checks passed');
