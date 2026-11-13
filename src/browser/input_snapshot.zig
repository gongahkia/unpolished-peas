// Compatibility location for the runtime and existing Wasm probes. The canonical
// codec belongs to the package so optional consumers use the same definitions.
const codec = @import("unpolished-peas").preview.developer.BrowserInput;
pub const abi_version = codec.abi_version;
pub const legacy_bytes = codec.legacy_bytes;
pub const abi_bytes = codec.abi_bytes;
pub const request_marker = codec.request_marker;
pub const decode = codec.decode;
