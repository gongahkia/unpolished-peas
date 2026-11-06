// Served only by the test server, before bootstrap. Never written into bundles.
export function instrumentation() {
  window.peasTest = {submissions: 0, nonzero: 0, invalidPcm: 0, rejectProgressWrites: false, errors: [], keyEvents: 0, trustedKeys: 0, trustedInput: 0, injectedComposition: 0, keySamples: []};
  window.addEventListener("error", (event) => window.peasTest.errors.push(event.message));
  window.addEventListener("unhandledrejection", (event) => window.peasTest.errors.push(String(event.reason)));
  window.addEventListener("keydown", (event) => {
    window.peasTest.keyEvents += 1;
    if (event.isTrusted) window.peasTest.trustedKeys += 1;
    if (window.peasTest.keySamples.length < 32) window.peasTest.keySamples.push({code: event.code, key: event.key, target: event.target?.tagName, active: document.activeElement?.tagName, hostFocused: window.unpolishedPeas?.host?.input().focused});
  });
  window.addEventListener("input", (event) => { if (event.isTrusted) window.peasTest.trustedInput += 1; });
  window.addEventListener("compositionupdate", (event) => { if (!event.isTrusted) window.peasTest.injectedComposition += 1; });
  const setItem = Storage.prototype.setItem;
  Storage.prototype.setItem = function(key, value) {
    if (window.peasTest.rejectProgressWrites && key.endsWith(":progress")) throw new DOMException("fixture quota rejection", "QuotaExceededError");
    return setItem.call(this, key, value);
  };
  const wrapped = new WeakSet();
  const wrap = (imports) => {
    if (!imports?.env || wrapped.has(imports.env)) return;
    wrapped.add(imports.env);
    const original = imports.env.up_host_audio_submit;
    if (!original) return;
    imports.env.up_host_audio_submit = (pointer, length) => {
      const samples = new Float32Array(imports.env.memory.buffer, pointer, length / 4);
      if (!samples.every(Number.isFinite)) window.peasTest.invalidPcm += 1;
      const nonzero = samples.some((value) => value !== 0);
      const status = original(pointer, length);
      if (status === 0) {
        window.peasTest.submissions += 1;
        if (nonzero) window.peasTest.nonzero += 1;
      }
      return status;
    };
  };
  for (const name of ["instantiate", "instantiateStreaming"]) {
    const original = WebAssembly[name];
    WebAssembly[name] = (...args) => { wrap(args[1]); return original.apply(WebAssembly, args); };
  }
}
