export const CART_FRAGMENT_LIMIT = 8_192;
export const CART_FRAGMENT_BYTE_LIMIT = 6_000;

/** Encodes a tiny canonical cartridge in the URL fragment, which is never sent in HTTP requests. */
export function encodeCartridgeFragment(cartridge: Uint8Array): string {
  if (cartridge.length < 1 || cartridge.length > CART_FRAGMENT_BYTE_LIMIT)
    throw new RangeError('tiny cartridge exceeds the 6000-byte URL-sharing limit');
  let binary = '';
  for (const byte of cartridge) binary += String.fromCharCode(byte);
  const fragment = `#pxc=${btoa(binary).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '')}`;
  if (fragment.length > CART_FRAGMENT_LIMIT)
    throw new RangeError('encoded cartridge exceeds the 8192-character fragment limit');
  return fragment;
}

export function decodeCartridgeFragment(fragment: string): Uint8Array | undefined {
  if (!fragment.startsWith('#pxc=')) return undefined;
  if (fragment.length > CART_FRAGMENT_LIMIT) throw new RangeError('cartridge fragment is too long');
  const encoded = fragment.slice(5);
  if (encoded.length === 0 || !/^[A-Za-z0-9_-]+$/.test(encoded))
    throw new TypeError('cartridge fragment encoding is invalid');
  const padding = '='.repeat((4 - (encoded.length % 4)) % 4);
  let binary: string;
  try {
    binary = atob(`${encoded.replaceAll('-', '+').replaceAll('_', '/')}${padding}`);
  } catch {
    throw new TypeError('cartridge fragment encoding is invalid');
  }
  const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
  if (bytes.length < 1 || bytes.length > CART_FRAGMENT_BYTE_LIMIT)
    throw new RangeError('tiny cartridge fragment exceeds its byte limit');
  return bytes;
}
