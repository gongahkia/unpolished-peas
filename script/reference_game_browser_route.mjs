import {compactReadback,prepareGameSaves,restoreGameSaves} from './reference_game_checks.mjs';
// Test-host-only route verification. Reuses the public wire encoder and shared replay driver.
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {resolve,join,extname,sep} from 'node:path';
import {parseArgs} from 'node:util';
import {createHash} from 'node:crypto';
import {setTimeout as delay} from 'node:timers/promises';
import {replayScript,replayAbi} from './browser-authoring/replay.mjs';
import {adapter} from './browser-authoring/adapters.mjs';
import {frame,compareReference} from './browser-authoring/checks.mjs';
import {probeWebGlCapture,validateWebGlReadback,validateRenderer} from './safari_webdriver.mjs';
const {values}=parseArgs({options:{game:{type:'string'},bundle:{type:'string'},input:{type:'string'},output:{type:'string'},browsers:{type:'string',default:'chromium,firefox'},motion:{type:'boolean',default:false}}});
assert.ok(['neon-siege','lantern-leap'].includes(values.game));
const game=values.game,bundle=resolve(values.bundle??`dogfood/${game}/zig-out/web`),input=resolve(values.input??`dogfood/${game}/zig-out/evidence/browser-route-input`),out=resolve(values.output??`zig-out/diagnostics/${game}-browser-route`);
await mkdir(out,{recursive:true});
const meta=JSON.parse(await readFile(join(input,'route.json'),'utf8'));
assert.equal(meta.abi_version,replayAbi.version);assert.equal(meta.frame_bytes,replayAbi.byteLength);
const sha=async path=>createHash('sha256').update(await readFile(path)).digest('hex');
const report={status:'running',kind:'Normalized ordinary-input replay in real browser/Wasm; virtual controller is recorded input, not physical hardware or trusted automation. No performance claims.',game,mode:meta.mode,wasmSha256:await sha(join(bundle,'unpolished-peas.wasm')),wireSha256:await sha(join(input,'frames.bin')),ticks:meta.ticks,results:[]};
const persist=()=>writeFile(join(out,'result.json'),JSON.stringify(report,null,2));
// Test server owns a fresh loopback origin. Back up even this origin's saves.

const mime={'.html':'text/html','.mjs':'application/javascript','.json':'application/json','.wasm':'application/wasm'};
const server=createServer(async(req,res)=>{try{
 const url=new URL(req.url,'http://localhost');
 if(url.pathname==='/probe'){res.writeHead(200,{'content-type':'text/html'});res.end('<!doctype html><body>independent probe');return;}
 if(['/__verify/frames.bin','/__verify/reload.bin'].includes(url.pathname)){res.end(await readFile(join(input,url.pathname.split('/').at(-1))));return;}
 const path=resolve(bundle,'.'+decodeURIComponent(url.pathname==='/'?'/index.html':url.pathname));assert.ok(path.startsWith(bundle+sep));
 let data=await readFile(path);
 if(extname(path)==='.html'){
   const continuing=url.searchParams.has('continue');
   data=Buffer.from(data.toString().replace(/<script\b/,`<script>(${prepareGameSaves.toString()})(${JSON.stringify({game,key:meta.save_key,continuing})});${replayScript({url:continuing?'/__verify/reload.bin':'/__verify/frames.bin',frameBytes:meta.frame_bytes,ticks:continuing?1:meta.ticks})}</script><script`));
 }
 res.writeHead(200,{'content-type':mime[extname(path)]??'application/octet-stream','cache-control':'no-store'});res.end(data);
}catch(error){res.writeHead(500);res.end(String(error));}});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const base='http://127.0.0.1:'+server.address().port;
const shutdown=async driver=>{
 const state=await driver.evaluate(()=>{const api=window.unpolishedPeas;api.runtime.up_browser_shutdown();return {failure:api.runtime.up_browser_protocol_failure_phase(),resources:api.host.resourceCount(),scheduledFrames:api.host.lifecycle().scheduledFrames,phase:api.host.lifecycle().phase};});
 assert.deepEqual(state,{failure:-1,resources:0,scheduledFrames:0,phase:'destroyed'});
 await driver.evaluate(()=>window.__peasReplay.dispose());return state;
};
try{for(const browser of values.browsers.split(',')){
 const driver=compactReadback(adapter(browser)),result={browser,status:'running',frames:[],motion:[]};report.results.push(result);await persist();
 const dir=join(out,browser);await mkdir(dir,{recursive:true});let original=null;
 try{
  await driver.open();result.version=driver.version;
  await driver.navigate(base+'/probe');driver.captureProbe=await driver.evaluate(probeWebGlCapture);validateWebGlReadback(driver.captureProbe,'independent WebGL probe');result.probe=driver.captureProbe;
  const ready=async()=>{await driver.wait(()=>window.unpolishedPeas?.rendererDiagnostic?.context_status==='ready',null,'game ready');await driver.evaluate(()=>window.__peasReplay.ready);};
  await driver.navigate(base+'/?renderer=webgl2');original=await driver.evaluate(()=>window.__referenceOriginalSaves);await ready();
  result.renderer=await driver.evaluate(()=>window.unpolishedPeas.rendererDiagnostic);if(browser==='safari')validateRenderer(result.renderer,'webgl2');
  assert.equal(result.renderer.selected_renderer,'webgl2');assert.equal(result.renderer.fallback_reason,null);
  let next=0;
  for(const mark of meta.milestones){
   while(next<=mark.tick){
    // Selected ordinary motion ranges, observed at approximately 10% wall speed.
    const ranges=game==='lantern-leap'?[[80,120],[310,340],[630,650]]:[[180,220],[650,690]];
    const slow=values.motion&&ranges.some(([start,end])=>next>=start&&next<end);
    let end=Math.min(mark.tick+1,next+(slow?1:60));
    if(values.motion)for(const [start]of ranges)if(next<start)end=Math.min(end,start);
    const state=await driver.evaluate(({from,to})=>{for(let i=from;i<to;i++)window.__peasReplay.advance(i*1000/60);return {inputs:window.__peasReplay.consumed,failure:window.unpolishedPeas.runtime.up_browser_protocol_failure_phase(),render:window.unpolishedPeas.runtime.up_browser_canvas_render_status()};},{from:next,to:end});
    assert.equal(state.inputs,end);assert.equal(state.failure,-1);assert.equal(state.render,0);
    if(slow){if(next%5===0){await frame(driver,dir,'motion-'+next,meta.width,meta.height);result.motion.push({tick:next,wallStepMs:1000/6,fixedStepMs:1000/60});}await delay(1000/6);}
    next=end;
   }
   const actual=await frame(driver,dir,mark.label,meta.width,meta.height);await compareReference(actual,join(input,mark.label+'.rgba'));result.frames.push({...mark,comparison:'every RGBA channel within 1 of CPU reference'});await persist();
  }
  assert.equal(next,meta.ticks);
  const saved=await driver.evaluate(({game,key})=>{const k=Object.keys(localStorage).find(k=>k.endsWith(`unpolished-peas.${game}:${key}`));if(!k)throw Error('save absent');const value=localStorage.getItem(k);return {key:k,value,bytes:Array.from(atob(value.slice(6)),c=>c.charCodeAt(0))};},{game,key:meta.save_key});
  assert.deepEqual(saved.bytes,[...await readFile(join(input,'final-save.bin'))]);result.savedBytes=saved.bytes;result.routeShutdown=await shutdown(driver);
  await driver.navigate(base+'/?renderer=webgl2&continue=1');await ready();await driver.evaluate(()=>window.__peasReplay.advance(0));
  await compareReference(await frame(driver,dir,'reloaded',meta.width,meta.height),join(input,'reloaded.rgba'));result.actualFinalReload=true;result.reloadShutdown=await shutdown(driver);
  if(meta.checkpoint_reference){
   const bytes=[...await readFile(join(input,'checkpoint-save.bin'))];
   await driver.evaluate(({key,bytes})=>localStorage.setItem(key,'UPST1:'+btoa(String.fromCharCode(...bytes))),{key:saved.key,bytes});
   await driver.navigate(base+'/?renderer=webgl2&continue=1');await ready();await driver.evaluate(()=>window.__peasReplay.advance(0));
   await compareReference(await frame(driver,dir,'checkpoint-reloaded',meta.width,meta.height),join(input,'checkpoint-reloaded.rgba'));result.actualCheckpointReload=true;result.checkpointShutdown=await shutdown(driver);
  }
  result.status='passed';console.log(`${game} ${browser} ${meta.mode}: full route, ${result.frames.length} CPU comparisons, save reload and shutdown passed`);
 }catch(error){result.status='failed';result.error=String(error.stack);throw error;}
 finally{
  try{if(original===null)try{original=await driver.evaluate(()=>window.__referenceOriginalSaves??null);}catch{}if(original!==null){result.originalSavesRestored=await driver.evaluate(restoreGameSaves,{old:original,game});assert.equal(result.originalSavesRestored,true);}}
  finally{try{await driver.evaluate(()=>window.__peasReplay?.dispose());}catch{}await driver.close();await persist();}
 }
}report.status='passed';await persist();}catch(error){report.status='failed';report.error=String(error.stack);await persist();throw error;}finally{await new Promise(r=>server.close(r));}
