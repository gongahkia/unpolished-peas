import assert from 'node:assert/strict';
import test from 'node:test';
import vm from 'node:vm';
import {prepareGameSaves,restoreGameSaves} from './reference_game_checks.mjs';
test('fresh routes preserve current and legacy saves, and restore exactly their own game keys',()=>{
 const storage={'origin/unpolished-peas.lantern-leap:progress.v1':'legacy','origin/unpolished-peas.lantern-leap:progress.v2':'current','origin/unpolished-peas.neon-siege:settings.v1':'other-game','user-setting':'untouched'};
 Object.defineProperties(storage,{getItem:{value:key=>storage[key]??null},setItem:{value:(key,value)=>{storage[key]=value;}},removeItem:{value:key=>{delete storage[key];}}});
 const ctx=vm.createContext({window:{},localStorage:storage});
 const prepare=vm.runInContext('('+prepareGameSaves.toString()+')',ctx),restore=vm.runInContext('('+restoreGameSaves.toString()+')',ctx);
 prepare({game:'lantern-leap'});const old=ctx.window.__referenceOriginalSaves;
 assert.equal(old.length,2);assert.equal(storage['origin/unpolished-peas.lantern-leap:progress.v1'],undefined);
 storage['origin/unpolished-peas.lantern-leap:progress.v2']='test-result';
 prepare({game:'lantern-leap',continuing:true});assert.equal(storage['origin/unpolished-peas.lantern-leap:progress.v2'],'test-result');
 storage['origin/unpolished-peas.lantern-leap:new-test-record']='temporary';
 assert.equal(restore({game:'lantern-leap',old}),true);
 assert.deepEqual({...storage},{'origin/unpolished-peas.lantern-leap:progress.v1':'legacy','origin/unpolished-peas.lantern-leap:progress.v2':'current','origin/unpolished-peas.neon-siege:settings.v1':'other-game','user-setting':'untouched'});
});
