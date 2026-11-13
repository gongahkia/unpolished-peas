// Preserve the shared strict PNG/RGBA/probe checks while transporting pixels
// compactly. Large automation arrays otherwise create millions of protocol objects.
import {readFrame} from './browser-authoring/checks.mjs';
export function compactReadback(driver) {
  const evaluate=driver.evaluate.bind(driver);
  driver.evaluate=async(fn,argument)=>{
    if(fn!==readFrame)return evaluate(fn,argument);
    const {rgba_base64,...value}=await evaluate(fn,{...argument,encoding:'base64'});
    return {...value,rgba:[...Buffer.from(rgba_base64,'base64')]};
  };
  return driver;
}

// Called before bootstrap, and serialized into the isolated test-host page.
// Include legacy keys: a v1 record must neither seed a fresh route nor be lost.
export function prepareGameSaves({game,continuing=false}) {
  const prefix=`unpolished-peas.${game}:`;
  const matches=key=>key.slice(key.lastIndexOf('/')+1).startsWith(prefix);
  window.__referenceOriginalSaves=Object.keys(localStorage).filter(matches).map(key=>[key,localStorage.getItem(key)]);
  if(!continuing)for(const [key]of window.__referenceOriginalSaves)localStorage.removeItem(key);
}
export function restoreGameSaves({game,old}) {
  const prefix=`unpolished-peas.${game}:`;
  const matches=key=>key.slice(key.lastIndexOf('/')+1).startsWith(prefix);
  for(const key of Object.keys(localStorage).filter(matches))localStorage.removeItem(key);
  for(const[key,value]of old)localStorage.setItem(key,value);
  return old.every(([key,value])=>localStorage.getItem(key)===value)&&Object.keys(localStorage).filter(matches).length===old.length;
}
