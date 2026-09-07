export const DENIED_WORKER_CAPABILITIES = [
  'Date',
  'fetch',
  'WebSocket',
  'EventSource',
  'XMLHttpRequest',
  'importScripts',
  'indexedDB',
  'caches',
  'crypto',
  'navigator',
  'eval',
  'Function',
] as const;

/** Removes ambient capabilities before generated cartridge code is evaluated. */
export function lockDownWorkerGlobals(target: Record<string, unknown>): void {
  for (const capability of DENIED_WORKER_CAPABILITIES) {
    try {
      Object.defineProperty(target, capability, {
        configurable: false,
        enumerable: false,
        value: undefined,
        writable: false,
      });
    } catch {
      // Some browser globals are non-configurable; PXCL code still has no syntax that can name them.
    }
  }
  const deterministicMath = Object.freeze({
    abs: Math.abs,
    ceil: Math.ceil,
    floor: Math.floor,
    max: Math.max,
    min: Math.min,
    round: Math.round,
    sign: Math.sign,
    trunc: Math.trunc,
  });
  try {
    Object.defineProperty(target, 'Math', {
      configurable: false,
      enumerable: false,
      value: deterministicMath,
      writable: false,
    });
  } catch {
    // The compiler never emits Math.random; this is defense in depth where replacement is allowed.
  }
}
