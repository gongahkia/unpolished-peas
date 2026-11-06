async (page) => {
  const report = await page.evaluate(async () => {
    const [wasmResponse, nativeResponse] = await Promise.all([fetch("suite.wasm"), fetch("native.json")]);
    if (!wasmResponse.ok || !nativeResponse.ok) throw new Error("surface fixture fetch failed");
    const native = await nativeResponse.json();
    const {instance} = await WebAssembly.instantiate(await wasmResponse.arrayBuffer(), {
      env: {memory: new WebAssembly.Memory({initial: 128})},
    });
    const status = instance.exports.surface_conformance_run();
    if (status !== 0) throw new Error(`surface status=${status} case=${instance.exports.surface_failure_case()} pixel=${instance.exports.surface_failure_pixel()}`);
    const cases = instance.exports.surface_conformance_cases();
    const hash = BigInt.asUintN(64, instance.exports.surface_conformance_hash()).toString();
    if (native.cases !== 554 || native.hash !== "716431564172485137" || cases !== native.cases || hash !== native.hash) {
      throw new Error(`surface native/browser mismatch: ${JSON.stringify({native, cases, hash})}`);
    }
    return {cases, hash, userAgent: navigator.userAgent, platform: navigator.platform};
  });
  return {status: "peas-surface-composition-passed", ...report};
}
