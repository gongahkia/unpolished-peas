import {compactReadback} from './reference_game_checks.mjs';
// Trusted automation against ordinary shipping bundles. No normalized replay injection.
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {resolve,extname,join,sep} from 'node:path';
import {parseArgs} from 'node:util';
import {adapter,sleep} from './browser-authoring/adapters.mjs';
import {ready,frame} from './browser-authoring/checks.mjs';
import {instrumentation} from './browser-authoring/instrumentation.mjs';
import {probeWebGlCapture,validateWebGlReadback} from './safari_webdriver.mjs';
const {values}=parseArgs({options:{browsers:{type:'string',default:'chromium,firefox'},output:{type:'string',default:'zig-out/diagnostics/reference-games-trusted'}}});
const out=resolve(values.output);await mkdir(out,{recursive:true});
function rejection(){const set=Storage.prototype.setItem;Storage.prototype.setItem=function(k,v){if(window.peasTest.rejectGameWrites&&/:(settings.v1|progress.v2)$/.test(k))throw new DOMException('verification quota rejection','QuotaExceededError');return set.call(this,k,v);};}
const server=createServer(async(req,res)=>{try{
 const url=new URL(req.url,'http://localhost');
 if(url.pathname==='/probe'){res.writeHead(200,{'content-type':'text/html'});res.end('<!doctype html><body>probe');return;}
 const [,game,...parts]=url.pathname.split('/');assert.ok(['neon-siege','lantern-leap'].includes(game));
 const root=resolve(`dogfood/${game}/zig-out/web`),path=resolve(root,parts.join('/')||'index.html');assert.ok(path.startsWith(root+sep));
 let body=await readFile(path);if(extname(path)==='.html')body=Buffer.from(body.toString().replace(/<script\b/,`<script>(${instrumentation.toString()})();(${rejection.toString()})();</script><script`));
 res.writeHead(200,{'content-type':({'.html':'text/html','.mjs':'application/javascript','.wasm':'application/wasm','.json':'application/json'})[extname(path)]??'application/octet-stream'});res.end(body);
}catch(e){res.writeHead(404);res.end(String(e));}});
await new Promise(r=>server.listen(0,'127.0.0.1',r));const base='http://127.0.0.1:'+server.address().port;
const report={kind:'Trusted WebDriver/Playwright keys/clicks, shipping bundles with passive PCM observation and explicit storage-failure fixture; not physical hardware',status:'running',results:[]};
const persist=()=>writeFile(join(out,'result.json'),JSON.stringify(report,null,2));
try{for(const browser of values.browsers.split(','))for(const game of ['neon-siege','lantern-leap']){
 const d=compactReadback(adapter(browser)),r={browser,game,status:'running'};report.results.push(r);const dir=join(out,browser,game);await mkdir(dir,{recursive:true});
 try{
  await d.open();r.version=d.version;await d.navigate(base+'/probe');d.captureProbe=await d.evaluate(probeWebGlCapture);validateWebGlReadback(d.captureProbe,'independent probe');
  await d.navigate(`${base}/${game}/?renderer=webgl2`);await ready(d,false);
  r.beforeGesture=await d.evaluate(()=>({audio:window.unpolishedPeas.host.audio(),nonzero:window.peasTest.nonzero}));await frame(d,dir,'title',320,200);
  await d.click('canvas[data-unpolished-peas]');await d.wait(()=>window.peasTest.nonzero>0,null,'music after trusted gesture');
  r.afterGesture=await d.evaluate(()=>({audio:window.unpolishedPeas.host.audio(),nonzero:window.peasTest.nonzero}));
  await d.press('Enter');await d.down('ArrowRight');if(game==='neon-siege'){await d.down('Space');await d.down('x');}await sleep(350);if(game==='lantern-leap')await d.press('Space');await sleep(200);await d.up('ArrowRight');if(game==='neon-siege'){await d.up('Space');await d.up('x');}
  await frame(d,dir,'playing',320,200);await d.press('Escape');await frame(d,dir,'paused',320,200);await d.press('Enter');
  await d.press('m');await sleep(250);const mutedPcm=await d.evaluate(()=>window.peasTest.nonzero);await sleep(100);assert.equal(await d.evaluate(()=>window.peasTest.nonzero),mutedPcm);r.mutedPcmStopped=true;
  const save=async()=>d.evaluate(game=>{const suffix=`unpolished-peas.${game}:`+(game==='neon-siege'?'settings.v1':'progress.v2');const k=Object.keys(localStorage).find(k=>k.endsWith(suffix));return {key:k,value:localStorage.getItem(k)};},game);
  const muted=await save();assert.ok(muted.key&&muted.value.startsWith('UPST1:'));const bytes=[...Buffer.from(muted.value.slice(6),'base64')];assert.equal(bytes[game==='neon-siege'?1:3],0);r.mutedSave=bytes;
  await d.evaluate(()=>window.peasTest.rejectGameWrites=true);await d.press('m');assert.deepEqual(await save(),muted);await frame(d,dir,'save-pending',320,200);
  await d.evaluate(()=>window.peasTest.rejectGameWrites=false);await d.press('Escape');await d.press('Enter');
  const retried=await save();const retriedBytes=[...Buffer.from(retried.value.slice(6),'base64')];assert.equal(retriedBytes[game==='neon-siege'?1:3],1);r.retriedSave=retriedBytes;
  await d.press('r');await frame(d,dir,'full-restart',320,200);const restarted=await save();r.trusted=await d.evaluate(()=>({keys:window.peasTest.trustedKeys,invalidPcm:window.peasTest.invalidPcm,errors:window.peasTest.errors}));assert.ok(r.trusted.keys>=8);assert.equal(r.trusted.invalidPcm,0);assert.deepEqual(r.trusted.errors,[]);
  const shutdown=()=>d.evaluate(()=>{const a=window.unpolishedPeas;a.runtime.up_browser_shutdown();return {resources:a.host.resourceCount(),frames:a.host.lifecycle().scheduledFrames,phase:a.host.lifecycle().phase};});
  assert.deepEqual(await shutdown(),{resources:0,frames:0,phase:'destroyed'});await d.reload();await ready(d,false);assert.equal((await save()).value,restarted.value);await frame(d,dir,'reloaded-title',320,200);assert.deepEqual(await shutdown(),{resources:0,frames:0,phase:'destroyed'});r.actualReload=true;r.status='passed';console.log(`${browser} ${game}: trusted controls, autoplay recovery, rejected-write retry, reload and cleanup passed`);
 }catch(e){r.status='failed';r.error=String(e.stack);throw e;}finally{await d.close();await persist();}
}report.status='passed';await persist();}catch(e){report.status='failed';await persist();throw e;}finally{await new Promise(r=>server.close(r));}
