// Optional test-server instrumentation. Never installed in production bundles.
import {InputAbiV2} from '../../src/browser/input.mjs';
export const replayAbi = InputAbiV2;

// Self-contained so an HTTP test server can install it before ordinary bootstrap.
export function installReplay({url, frameBytes, ticks}) {
  if (!Number.isSafeInteger(frameBytes) || frameBytes <= 0 || !Number.isSafeInteger(ticks) || ticks < 0 || !Number.isSafeInteger(frameBytes * ticks)) throw new Error('invalid replay dimensions');
  window.__peasReplay?.dispose();
  const originals = {request: window.requestAnimationFrame, cancel: window.cancelAnimationFrame, instantiate: WebAssembly.instantiate, streaming: WebAssembly.instantiateStreaming};
  const queued = new Map(), bindings = new Map();
  let token = 1, wire = null, index = 0, cancelled = false, disposed = false, previous = -Infinity;
  const request = callback => {if(disposed || cancelled) return 0; const id=token++;queued.set(id,callback);return id;};
  const cancel = id => queued.delete(id);
  window.requestAnimationFrame = request;
  window.cancelAnimationFrame = cancel;
  const wrap = imports => {
    const env=imports?.env;if(!env || bindings.has(env))return;
    const old={poll:env.up_host_input_poll,read:env.up_host_input_read};
    const poll=()=>frameBytes;
    const read=(pointer,capacity)=>{
      if(disposed || cancelled || !wire)throw new Error('replay input unavailable');
      if(capacity<frameBytes)throw new Error('replay input capacity too small');
      if(index>=ticks)throw new Error('replay exhausted');
      new Uint8Array(env.memory.buffer,pointer,frameBytes).set(wire.subarray(index*frameBytes,(index+1)*frameBytes));
      index++;return frameBytes;
    };
    bindings.set(env,{...old,pollWrapper:poll,readWrapper:read});env.up_host_input_poll=poll;env.up_host_input_read=read;
  };
  const instantiate=(...args)=>{wrap(args[1]);return originals.instantiate.apply(WebAssembly,args);};
  const streaming=(...args)=>{wrap(args[1]);return originals.streaming.apply(WebAssembly,args);};
  WebAssembly.instantiate=instantiate;
  if(originals.streaming)WebAssembly.instantiateStreaming=streaming;
  const api={
    get consumed(){return index;},
    ready: fetch(url).then(r=>{if(!r.ok)throw new Error('replay fetch failed: '+r.status);return r.arrayBuffer();}).then(buffer=>{
      if(buffer.byteLength!==frameBytes*ticks)throw new Error('replay byte length mismatch');
      if(!disposed)wire=new Uint8Array(buffer);return true;
    }),
    advance(timestamp){
      if(disposed || cancelled)throw new Error('replay stopped');
      if(!wire)throw new Error('replay not ready');
      if(!Number.isFinite(timestamp) || timestamp<previous)throw new Error('invalid replay timestamp');
      previous=timestamp;
      for(const id of [...queued.keys()]){
        if(disposed || cancelled)break;
        const callback=queued.get(id);queued.delete(id);
        if(callback)callback(timestamp);
      }
    },
    cancel(){cancelled=true;queued.clear();},
    dispose(){
      if(disposed)return;disposed=true;queued.clear();wire=null;
      if(window.requestAnimationFrame===request)window.requestAnimationFrame=originals.request;
      if(window.cancelAnimationFrame===cancel)window.cancelAnimationFrame=originals.cancel;
      if(WebAssembly.instantiate===instantiate)WebAssembly.instantiate=originals.instantiate;
      if(WebAssembly.instantiateStreaming===streaming)WebAssembly.instantiateStreaming=originals.streaming;
      for(const [env,old] of bindings){
        if(env.up_host_input_poll===old.pollWrapper)env.up_host_input_poll=old.poll;
        if(env.up_host_input_read===old.readWrapper)env.up_host_input_read=old.read;
      }
      bindings.clear();
    },
  };
  window.__peasReplay=api;return api;
}
export function replayScript(options) {
  if(options.frameBytes!==replayAbi.byteLength)throw new Error('unsupported replay ABI size');
  return '('+installReplay.toString()+')('+JSON.stringify(options).replaceAll('<','\\u003c')+');';
}
