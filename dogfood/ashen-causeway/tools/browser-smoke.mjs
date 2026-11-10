// Run from the engine root after building and serving the game on port 8114.
// Uses the existing authoring installation; no test hooks enter the game bundle.
import {chromium, firefox} from '../../../script/browser-authoring/node_modules/playwright/index.mjs';
import {mkdir, writeFile} from 'node:fs/promises';
import assert from 'node:assert/strict';
const out = new URL('../zig-out/evidence/', import.meta.url);
await mkdir(out, {recursive:true});
const results=[];
for (const name of (process.env.PEAS_SMOKE_BROWSERS ?? 'chromium').split(',')) {
  const browser=await (name==='firefox'?firefox:chromium).launch(name==='chromium'?{channel:'chrome',headless:true,args:['--enable-webgl','--use-angle=swiftshader','--enable-unsafe-swiftshader']}:{headless:true});
  try {
    const page=await browser.newPage({viewport:{width:1100,height:760}});
    const errors=[];page.on('pageerror',e=>errors.push(String(e)));
    await page.goto(process.env.PEAS_GAME_URL ?? 'http://127.0.0.1:8114/?renderer=webgl2');
    await page.waitForFunction(()=>window.unpolishedPeas?.rendererDiagnostic?.context_status==='ready');
    const canvas=page.locator('canvas[data-unpolished-peas]');await canvas.focus();
    const capture=async(label)=>{
      const value=await page.evaluate(()=>{
        const app=window.unpolishedPeas;
        const png=app.host.captureFrame();
        const c=document.querySelector('canvas[data-unpolished-peas]');
        const gl=c.getContext('webgl2');const pixels=new Uint8Array(c.width*c.height*4);
        gl.readPixels(0,0,c.width,c.height,gl.RGBA,gl.UNSIGNED_BYTE,pixels);
        let sum=0;for(let i=0;i<pixels.length;i++) sum=(sum+pixels[i]*(i%251+1))>>>0;
        return {png,sum,error:gl.getError(),width:c.width,height:c.height};
      });
      assert.equal(value.error,0);assert.equal(value.width,480);assert.equal(value.height,270);assert.ok(value.sum>0);assert.ok(value.png);
      await writeFile(new URL(`${name}-${label}.png`,out),Buffer.from(value.png.split(',')[1],'base64'));
      delete value.png;return value;
    };
    const title=await capture('title');
    await page.keyboard.press('Enter');await page.waitForTimeout(100);
    const play=await capture('play');assert.notEqual(title.sum,play.sum);
    await page.keyboard.down('ArrowRight');await page.waitForTimeout(650);await page.keyboard.up('ArrowRight');
    await page.keyboard.press('q');await page.keyboard.press('j');await page.waitForTimeout(150);
    const action=await capture('action');assert.notEqual(play.sum,action.sum);
    await page.keyboard.press('Escape');await page.waitForTimeout(100);const pause=await capture('pause');assert.notEqual(action.sum,pause.sum);
    assert.deepEqual(errors,[]);
    results.push({browser:name,version:browser.version(),title,play,action,pause,errors,coverage:'Trusted keyboard smoke and nonzero WebGL readback, not full route or parity validation'});
  } finally {await browser.close();}
}
await writeFile(new URL('browser-smoke.json',out),JSON.stringify(results,null,2));
console.log(JSON.stringify(results,null,2));
