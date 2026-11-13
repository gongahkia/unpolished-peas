import assert from "node:assert/strict";
import {createServer} from "node:http";
import {readFile,writeFile,mkdir} from "node:fs/promises";
import {resolve,join,sep,extname} from "node:path";
import {execFileSync} from "node:child_process";
import {parseArgs} from "node:util";
import {PlaywrightAdapter} from "./browser-authoring/adapters.mjs";
import {ready,readFrame} from "./browser-authoring/checks.mjs";
const {values,positionals} = parseArgs({allowPositionals:true, options:{bundle:{type:"string"},output:{type:"string",default:"zig-out/diagnostics/chess"}}});
assert.equal(positionals.length,2,"supply native reference and Wasm rules probe");
const root=resolve(values.bundle),output=resolve(values.output);
await mkdir(output,{recursive:true});
execFileSync(resolve(positionals[0]),[output],{timeout:120000});
const {instance}=await WebAssembly.instantiate(await readFile(positionals[1]),{});
assert.equal(instance.exports.chess_rules_check(),500117n,"Wasm chess move-tree and special-rule checks");
const server=createServer(async(request,response)=>{
  try{
    const pathname=new URL(request.url,"http://localhost").pathname;
    const file=resolve(root,pathname==="/"?"index.html":"."+decodeURIComponent(pathname));
    assert.ok(file.startsWith(root+sep));
    const bytes=await readFile(file);response.writeHead(200,{"content-type":{".html":"text/html; charset=utf-8",".mjs":"application/javascript",".wasm":"application/wasm",".json":"application/json"}[extname(file)]??"application/octet-stream"});response.end(bytes);
  }catch{response.writeHead(404);response.end("not found");}
});
await new Promise(resolve=>server.listen(0,"127.0.0.1",resolve));
const driver=new PlaywrightAdapter("chromium");
const report={status:"unverified",rules_nodes:500117,checks:[]};
async function metric(index){return driver.evaluate(index=>window.unpolishedPeas.runtime.chess_metric(index),index);}
async function until(index,value){await driver.wait(({index,value})=>window.unpolishedPeas.runtime.chess_metric(index)===value,{index,value},`chess metric ${index}=${value}`);}
async function click(x,y){const size=await driver.page.locator("canvas").boundingBox();await driver.page.locator("canvas").click({position:{x:x*size.width/640,y:y*size.height/480}});}
async function square(name){
  const flipped=await metric(5),file=name.charCodeAt(0)-97,rank=Number(name[1])-1;
  await click(24+(flipped?7-file:file)*48+24,56+(flipped?rank:7-rank)*48+24);
}
async function play(from,to){const count=await metric(4);await square(from);await until(3,(Number(from[1])-1)*8+from.charCodeAt(0)-97);await square(to);await until(4,count+1);}
async function button(index){await click(500,248+index*48);}
async function restart(){await button(0);await until(7,3);await button(0);await until(7,0);await until(4,0);await until(1,0);await until(0,0);}
async function capture(name,reference){
  const frame=await driver.evaluate(readFrame,{width:640,height:480});
  assert.equal(frame.error,0);assert.equal(frame.protocolFailure,-1);assert.equal(frame.contextLost,false);
  const bytes=Buffer.from(frame.rgba);await writeFile(join(output,name+".rgba"),bytes);
  if(frame.png)await writeFile(join(output,name+".png"),Buffer.from(frame.png.split(",")[1],"base64"));
  if(reference)assert.equal(bytes.equals(await readFile(join(output,reference))),true,`${name} native/Wasm/WebGL pixels differ`);
}
try{
  await driver.open();report.browser=driver.version;
  await driver.navigate(`http://127.0.0.1:${server.address().port}/?renderer=webgl2`);await ready(driver);
  await capture("browser-initial","initial.rgba");report.checks.push("initial pixels match native exactly");
  await square("e2");await until(3,12);await square("e5");assert.equal(await metric(4),0);await driver.press("Escape");await until(3,-1);
  for(const [from,to] of [["f2","f3"],["e7","e5"],["g2","g4"],["d8","h4"]])await play(from,to);
  await until(1,1);await capture("browser-mate","mate.rgba");report.checks.push("complete two-player checkmate with exact native pixels");
  await square("e2");await square("e4");assert.equal(await metric(4),4);
  await driver.press("u");await until(4,3);await until(1,0);
  await driver.press("f");await until(5,1);await square("d8");await until(3,59);await driver.press("Escape");await capture("browser-flipped");
  await restart();await driver.press("f");await until(5,0);
  for(const [from,to] of [["a2","a4"],["h7","h5"],["a4","a5"],["h5","h4"],["a5","a6"],["h4","h3"],["a6","b7"],["h3","g2"]])await play(from,to);
  await square("b7");await until(3,49);await square("a8");await until(6,56);assert.equal(await metric(0),0);
  await button(3);await until(6,-1);assert.equal(await driver.evaluate(()=>window.unpolishedPeas.runtime.chess_piece(56)),2);
  await capture("browser-promotion");report.checks.push("promotion waits for explicit knight choice");
  await driver.press("u");await until(4,8);assert.equal(await driver.evaluate(()=>window.unpolishedPeas.runtime.chess_piece(49)),1);
  await restart();
  for(const [from,to] of [["g1","f3"],["g8","f6"],["g2","g3"],["g7","g6"],["f1","g2"],["f8","g7"],["e1","g1"],["e8","g8"]])await play(from,to);
  assert.deepEqual(await driver.evaluate(()=>[6,5,7,62,61,63].map(s=>window.unpolishedPeas.runtime.chess_piece(s))),[6,4,0,12,10,0]);report.checks.push("both players castle through the real UI");
  await restart();
  for(const [from,to] of [["e2","e4"],["a7","a6"],["e4","e5"],["d7","d5"],["e5","d6"]])await play(from,to);
  assert.deepEqual(await driver.evaluate(()=>[35,43].map(s=>window.unpolishedPeas.runtime.chess_piece(s))),[0,1]);await capture("browser-en-passant");report.checks.push("en passant removes the bypassed pawn");
  await restart();
  for(let i=0;i<2;i++)for(const [from,to] of [["g1","f3"],["g8","f6"],["f3","g1"],["f6","g8"]])await play(from,to);
  await button(3);await until(1,6);report.checks.push("threefold draw claim");
  await restart();await button(4);await until(7,2);await button(0);await until(1,8);await restart();
  await driver.press("Space");await until(3,12);await driver.press("ArrowUp");await driver.press("Space");await until(4,1);report.checks.push("keyboard move and undo/flip; mouse restart and resignation");
  await capture("browser-keyboard");
  const metadata=await driver.evaluate(()=>{const api=window.unpolishedPeas,gl=api.host.context(),debug=gl.getExtension("WEBGL_debug_renderer_info");return{user_agent:navigator.userAgent,renderer:api.renderer,gl_version:gl.getParameter(gl.VERSION),gl_renderer:debug?gl.getParameter(debug.UNMASKED_RENDERER_WEBGL):gl.getParameter(gl.RENDERER)};});
  Object.assign(report,metadata);assert.equal(report.renderer,"webgl2");
  assert.ok(!driver.console.some(item=>item.type==="error"||item.type==="pageerror"),JSON.stringify(driver.console));
  report.status="passed";console.log("chess browser passed: "+report.checks.join("; "));
}catch(error){report.status="failed";report.error=error.stack;await driver.screenshot(join(output,"failure.png")).catch(()=>{});throw error;}
finally{await writeFile(join(output,"result.json"),JSON.stringify(report,null,2)+"\n");await writeFile(join(output,"console.json"),JSON.stringify(driver.console??[],null,2)+"\n");await driver.close();await new Promise(resolve=>server.close(resolve));}
