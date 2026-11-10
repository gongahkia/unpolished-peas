// Test-server-only normalized replay injection. The shipped game stays unchanged.
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {resolve,join,extname,sep} from 'node:path';
import {parseArgs} from 'node:util';
import {createHash} from 'node:crypto';
import {setTimeout as delay} from 'node:timers/promises';
import {adapter} from '../../../script/browser-authoring/adapters.mjs';
import {frame,compareReference} from '../../../script/browser-authoring/checks.mjs';
import {probeWebGlCapture,validateWebGlReadback,validateRenderer} from '../../../script/safari_webdriver.mjs';
const {values}=parseArgs({options:{motion:{type:'boolean',default:false},bundle:{type:'string'},input:{type:'string'},output:{type:'string'},browsers:{type:'string',default:'chromium,firefox'}}});
const gameRoot=resolve(new URL('..',import.meta.url).pathname);
const bundle=resolve(values.bundle ?? join(gameRoot,'../../zig-out/diagnostics/ashen-external/web'));
const input=resolve(values.input ?? join(gameRoot,'zig-out/evidence/browser-route-input'));
const out=resolve(values.output ?? join(gameRoot,'../../zig-out/diagnostics/ashen-browser-route'));
await mkdir(out,{recursive:true});
const motionRanges=[[5580,5660],[6250,6330]];
const meta=JSON.parse(await readFile(join(input,'route.json'),'utf8'));
assert.equal(meta.abi_version,2);assert.equal(meta.frame_bytes,1890);
const sha=async path=>createHash('sha256').update(await readFile(path)).digest('hex');
const report={status:'running',kind:'Accelerated normalized fixed-tick replay in the real browser/Wasm/renderer host; not physical input or performance evidence',bundleWasmSha256:await sha(join(bundle,'unpolished-peas.wasm')),wireSha256:await sha(join(input,'frames.bin')),ticks:meta.ticks,results:[]};
const persist=()=>writeFile(join(out,'result.json'),JSON.stringify(report,null,2));
function replayShim(){
  const suffix='unpolished-peas.ashen-causeway:journey-v1';
  window.__ashenOriginalSaves=Object.keys(localStorage).filter(k=>k.endsWith(suffix)).map(k=>[k,localStorage.getItem(k)]);
  if(!new URLSearchParams(location.search).has('continue')) for(const [key] of window.__ashenOriginalSaves)localStorage.removeItem(key);
  const queued=new Map();let token=1;
  window.requestAnimationFrame=callback=>{const id=token++;queued.set(id,callback);return id;};
  window.cancelAnimationFrame=id=>queued.delete(id);
  window.__ashenAdvance=timestamp=>{const batch=[...queued.values()];queued.clear();for(const callback of batch)callback(timestamp);};
  window.__ashenInputIndex=0;let wire;
  window.__ashenReplayReady=fetch('/__verify/frames.bin').then(r=>r.arrayBuffer()).then(buffer=>{wire=new Uint8Array(buffer);return true;});
  const wrapped=new WeakSet();
  const wrap=imports=>{
    if(!imports?.env || wrapped.has(imports.env))return;wrapped.add(imports.env);
    const env=imports.env;
    env.up_host_input_poll=()=>1890;
    env.up_host_input_read=(pointer,capacity)=>{
      if(!wire || capacity<1890)throw new Error('replay input unavailable');
      const index=window.__ashenInputIndex++;
      if(index>=wire.length/1890)throw new Error('replay exhausted');
      new Uint8Array(env.memory.buffer,pointer,1890).set(wire.subarray(index*1890,(index+1)*1890));
      return 1890;
    };
  };
  for(const name of ['instantiate','instantiateStreaming']){
    const original=WebAssembly[name];WebAssembly[name]=(...args)=>{wrap(args[1]);return original.apply(WebAssembly,args);};
  }
}
const mime={'.html':'text/html','.mjs':'application/javascript','.js':'application/javascript','.json':'application/json','.wasm':'application/wasm'};
const server=createServer(async(req,res)=>{
  try{
    const url=new URL(req.url,'http://localhost');
    if(url.pathname==='/probe'){res.writeHead(200,{'content-type':'text/html'});res.end('<!doctype html><body>independent probe');return;}
    if(url.pathname==='/__verify/frames.bin'){res.writeHead(200,{'content-type':'application/octet-stream'});res.end(await readFile(join(input,'frames.bin')));return;}
    const path=resolve(bundle,'.'+decodeURIComponent(url.pathname==='/'?'/index.html':url.pathname));assert.ok(path.startsWith(bundle+sep));
    let data=await readFile(path);
    if(extname(path)==='.html')data=Buffer.from(data.toString().replace(/<script\b/,'<script>('+replayShim.toString()+')();</script><script'));
    res.writeHead(200,{'content-type':mime[extname(path)] ?? 'application/octet-stream','cache-control':'no-store'});res.end(data);
  }catch(error){res.writeHead(500);res.end(String(error));}
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const base='http://127.0.0.1:'+server.address().port;
try{
  for(const browser of values.browsers.split(',')){
    const driver=adapter(browser);const result={browser,status:'running',frames:[],motion:[]};report.results.push(result);await persist();
    const directory=join(out,browser);await mkdir(directory,{recursive:true});let originalSaves=null;
    try{
      await driver.open();result.version=driver.version;
      await driver.navigate(base+'/probe');driver.captureProbe=await driver.evaluate(probeWebGlCapture);validateWebGlReadback(driver.captureProbe,'independent WebGL probe');result.probe=driver.captureProbe;
      await driver.navigate(base+'/?renderer=webgl2');
      await driver.wait(()=>window.unpolishedPeas?.rendererDiagnostic?.context_status==='ready',null,'game ready');
      await driver.evaluate(()=>window.__ashenReplayReady);
      originalSaves=await driver.evaluate(()=>window.__ashenOriginalSaves);
      result.renderer=await driver.evaluate(()=>window.unpolishedPeas.rendererDiagnostic);if(browser==='safari')validateRenderer(result.renderer,'webgl2');
      assert.equal(result.renderer.requested_renderer,'webgl2');assert.equal(result.renderer.selected_renderer,'webgl2');assert.equal(result.renderer.context_status,'ready');assert.equal(result.renderer.capabilities.webgl2,'available');assert.equal(result.renderer.fallback_reason,null);
      let next=0;
      for(const milestone of meta.milestones){
        while(next<=milestone.tick){
          const slowed=values.motion && motionRanges.some(([start,end])=>next>=start && next<end);
          let end=Math.min(milestone.tick+1,next+(slowed?1:90));
          if(values.motion) for(const [start] of motionRanges) if(next<start) end=Math.min(end,start);
          const state=await driver.evaluate(({from,to})=>{for(let i=from;i<to;i++)window.__ashenAdvance(i*1000/60);return {inputs:window.__ashenInputIndex,failure:window.unpolishedPeas.runtime.up_browser_protocol_failure_phase(),render:window.unpolishedPeas.runtime.up_browser_canvas_render_status()};},{from:next,to:end});
          assert.equal(state.inputs,end);assert.equal(state.failure,-1);assert.equal(state.render,0);
          if(slowed){
            if(next%10===0){
              await frame(driver,directory,'motion-'+next,meta.width,meta.height);
              result.motion.push({tick:next,wallStepMs:1000/6,fixedStepMs:1000/60});
            }
            await delay(1000/6);
          }
          next=end;
        }
        const actual=await frame(driver,directory,milestone.label,meta.width,meta.height);
        await compareReference(actual,join(input,milestone.label+'.rgba'));
        result.frames.push({label:milestone.label,tick:milestone.tick,pixelComparison:'all RGBA channels within 1 of native CPU reference'});await persist();
      }
      const ending=await driver.evaluate(()=>{
        const key=Object.keys(localStorage).find(k=>k.endsWith('unpolished-peas.ashen-causeway:journey-v1'));
        const bytes=atob(localStorage.getItem(key).slice(6));return {checkpoint:bytes.charCodeAt(5),upgrade:bytes.charCodeAt(7),bells:bytes.charCodeAt(9),boss:bytes.charCodeAt(13),completed:bytes.charCodeAt(14)};
      });assert.deepEqual(ending,{checkpoint:2,upgrade:1,bells:7,boss:1,completed:1});result.ending=ending;
      await driver.navigate(base+'/?renderer=webgl2&continue=1');
      await driver.wait(()=>window.unpolishedPeas?.rendererDiagnostic?.context_status==='ready',null,'continued game ready');
      await driver.evaluate(()=>window.__ashenReplayReady);
      await driver.evaluate(()=>window.__ashenAdvance(0));
      const continued=await frame(driver,directory,'continued',meta.width,meta.height);
      await compareReference(continued,join(input,meta.continue_reference));result.completedSaveReload=true;
      result.shutdown=await driver.evaluate(()=>{
        const api=window.unpolishedPeas;api.runtime.up_browser_shutdown();
        return {failure:api.runtime.up_browser_protocol_failure_phase(),resources:api.host.resourceCount(),scheduledFrames:api.host.lifecycle().scheduledFrames,phase:api.host.lifecycle().phase};
      });
      assert.deepEqual(result.shutdown,{failure:-1,resources:0,scheduledFrames:0,phase:'destroyed'});
      result.status='passed';console.log(browser+' full route and '+result.frames.length+' native pixel references passed');
    }catch(error){result.status='failed';result.error=String(error.stack);throw error;}
    finally{
      if(originalSaves!==null) {
        const restored=await driver.evaluate(old=>{const suffix='unpolished-peas.ashen-causeway:journey-v1';for(const key of Object.keys(localStorage))if(key.endsWith(suffix))localStorage.removeItem(key);for(const [key,value] of old)localStorage.setItem(key,value);return old.every(([key,value])=>localStorage.getItem(key)===value);},originalSaves);
        assert.equal(restored,true);result.originalSaveRestored=restored;
      }
      await driver.close();await persist();
    }
  }
  assert.equal(await sha(join(bundle,'unpolished-peas.wasm')),report.bundleWasmSha256);
  report.status='passed';await persist();
}catch(error){report.status='failed';report.error=String(error.stack);await persist();throw error;}finally{await new Promise(resolve=>server.close(resolve));}
