//! Browser boundary for the shared PXCL compiler.

use wasm_bindgen::prelude::wasm_bindgen;

use pxcl_core::{FileId, SourceFile, format_source, parse};

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

/// Returns tokens, parsed AST, and designed diagnostics as compiler-explorer JSON.
///
/// # Errors
///
/// Returns a serialization error if the analysis result cannot be encoded.
#[wasm_bindgen]
pub fn analyze(file_name: &str, source: &str) -> Result<String, String> {
    let source = SourceFile::new(FileId(0), file_name, source);
    serde_json::to_string(&parse(&source)).map_err(|error| error.to_string())
}

/// Formats a syntactically valid PXCL/1 module.
///
/// # Errors
///
/// Returns designed diagnostics as JSON when the source is invalid.
#[wasm_bindgen]
pub fn format(file_name: &str, source: &str) -> Result<String, String> {
    let source = SourceFile::new(FileId(0), file_name, source);
    format_source(&source).map_err(|error| {
        serde_json::to_string(&error.diagnostics).unwrap_or_else(|serialization_error| {
            format!("PXCL diagnostic serialization failed: {serialization_error}")
        })
    })
}
