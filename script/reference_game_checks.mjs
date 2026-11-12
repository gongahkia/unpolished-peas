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
