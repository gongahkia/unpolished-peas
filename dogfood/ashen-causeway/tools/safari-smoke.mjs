// Requires a free Safari WebDriver service; uses the repository's real-Safari adapter.
import assert from 'node:assert/strict';
import {mkdir,writeFile} from 'node:fs/promises';
import {SafariAdapter,sleep} from '../../../script/browser-authoring/adapters.mjs';
import {probeWebGlCapture,webGlRenderContract,validateWebGlReadback,validateRenderer} from '../../../script/safari_webdriver.mjs';
const out=new URL('../zig-out/evidence/safari/',import.meta.url);await mkdir(out,{recursive:true});
const driver=new SafariAdapter(process.env.UP_SAFARI_WEBDRIVER_URL ?? 'http://127.0.0.1:41245');
let previousSave=null;let saveSnapshotTaken=false;
const press=async key=>{await driver.press(key);await sleep(80);};
const report={browser:'safari',scope:'Authored text, menu input, save reload and strict renderer readback smoke; not a complete winning route'};
try {
  await driver.open();report.version=driver.version;report.capabilities=driver.client.capabilities;
  await driver.navigate('about:blank');report.captureProbe=await driver.evaluate(probeWebGlCapture);validateWebGlReadback(report.captureProbe,'independent WebGL probe');
  await driver.navigate(process.env.PEAS_GAME_URL ?? 'http://127.0.0.1:8114/?renderer=webgl2');
  await driver.wait(()=>window.unpolishedPeas?.rendererDiagnostic?.context_status==='ready',null,'game ready');
  report.renderer=await driver.evaluate(()=>window.unpolishedPeas.rendererDiagnostic);validateRenderer(report.renderer,'webgl2');
  report.readback=await driver.evaluate(webGlRenderContract);validateWebGlReadback(report.readback,'game renderer');await sleep(100);
  previousSave=await driver.evaluate(()=>{const key=Object.keys(localStorage).find(k=>k.endsWith('unpolished-peas.ashen-causeway:journey-v1'));return key?{key,raw:localStorage.getItem(key)}:null;});
  saveSnapshotTaken=true;
  await driver.click('canvas[data-unpolished-peas]');
  await driver.screenshot(new URL('title.png',out).pathname);
  await press('ArrowDown');await press('Space');await sleep(150);await press('q');await sleep(150);
  const saved=await driver.evaluate(()=>{
    const key=Object.keys(localStorage).find(k=>k.endsWith('unpolished-peas.ashen-causeway:journey-v1'));
    const raw=localStorage.getItem(key);return {key,raw,weapon:atob(raw.slice(6)).charCodeAt(6)};
  });assert.equal(saved.weapon,1);
  await press('Escape');for(let i=0;i<5;i++)await press('ArrowDown');await press('Space');await sleep(100);
  await driver.screenshot(new URL('settings.png',out).pathname);
  await press('\ue014');await press('Escape');await press('Space');
  await driver.reload();await driver.wait(()=>window.unpolishedPeas?.rendererDiagnostic?.context_status==='ready',null,'reloaded game');
  await driver.click('canvas[data-unpolished-peas]');await press('Space');await sleep(150);
  const after=await driver.evaluate(()=>{
    const key=Object.keys(localStorage).find(k=>k.endsWith('unpolished-peas.ashen-causeway:journey-v1'));const raw=localStorage.getItem(key);const bytes=atob(raw.slice(6));
    return {weapon:bytes.charCodeAt(6),music:bytes.charCodeAt(15),audio:window.unpolishedPeas.host.audio(),lifecycle:window.unpolishedPeas.host.lifecycle()};
  });assert.equal(after.weapon,1);assert.equal(after.music,60);assert.equal(after.audio.phase,'active');
  await driver.screenshot(new URL('continued.png',out).pathname);report.afterReload=after;report.status='passed';
} catch(error) {report.status='failed';report.error=String(error.stack);throw error;}
finally {
  if(driver.client.sessionId && saveSnapshotTaken) {
    try {
      report.previousSaveRestored=await driver.evaluate((old)=>{const key=Object.keys(localStorage).find(k=>k.endsWith('unpolished-peas.ashen-causeway:journey-v1'));if(old){localStorage.setItem(old.key,old.raw);return localStorage.getItem(old.key)===old.raw;}if(key)localStorage.removeItem(key);return !key || localStorage.getItem(key)===null;},previousSave);
      assert.equal(report.previousSaveRestored,true);
    } catch(error) {report.status='failed';report.restoreError=String(error);}
  }
  await writeFile(new URL('result.json',out),JSON.stringify(report,null,2));await driver.close();}
assert.equal(report.status,'passed');
console.log(JSON.stringify(report,null,2));
