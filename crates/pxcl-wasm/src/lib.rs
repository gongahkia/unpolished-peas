//! Browser boundary for the shared PXCL compiler.

use wasm_bindgen::prelude::wasm_bindgen;

/// Returns the compiler version used by the browser studio.
#[must_use]
#[wasm_bindgen]
pub fn compiler_version() -> String {
    pxcl_core::compiler_version().to_owned()
}

/// Returns the implemented language revision.
#[must_use]
#[wasm_bindgen]
pub fn language_revision() -> String {
    pxcl_core::LANGUAGE_REVISION.to_owned()
}
