import assert from 'node:assert/strict';
import test from 'node:test';
import {SafariAdapter} from './adapters.mjs';
test('Safari submits WebDriver special-key code points for game start and horizontal movement',async()=>{
  const driver=new SafariAdapter();const events=[];let releases=0;
  driver.client={actions:async actions=>events.push(...actions[0].actions),releaseActions:async()=>{releases++;}};
  for(const key of ['Enter','ArrowLeft','ArrowRight','x']){await driver.down(key);await driver.up(key);}
  assert.deepEqual(events,[{type:'keyDown',value:'\ue007'},{type:'keyDown',value:'\ue012'},{type:'keyDown',value:'\ue014'},{type:'keyDown',value:'x'}]);
  assert.equal(releases,4);
});
