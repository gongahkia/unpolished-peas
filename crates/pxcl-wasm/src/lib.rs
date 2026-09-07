//! Browser boundary for the shared PXCL compiler.

use wasm_bindgen::prelude::wasm_bindgen;

use pxcl_core::{
    AssetCatalog, CompileMode, FileId, SourceFile, analyze_module, compile as compile_source,
    format_source,
};

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
    serde_json::to_string(&analyze_module(&source, &AssetCatalog::default()))
        .map_err(|error| error.to_string())
}

/// Analyzes PXCL using a JSON-encoded typed asset catalog.
///
/// # Errors
///
/// Returns an error when the catalog or analysis result cannot be decoded or encoded.
#[wasm_bindgen]
pub fn analyze_with_assets(
    file_name: &str,
    source: &str,
    asset_catalog_json: &str,
) -> Result<String, String> {
    let assets: AssetCatalog =
        serde_json::from_str(asset_catalog_json).map_err(|error| error.to_string())?;
    let source = SourceFile::new(FileId(0), file_name, source);
    serde_json::to_string(&analyze_module(&source, &assets)).map_err(|error| error.to_string())
}

/// Compiles a module and typed asset catalog to release or debug JavaScript and source-map JSON.
///
/// # Errors
///
/// Returns an error when inputs or compiler output cannot be decoded or encoded.
#[wasm_bindgen(js_name = compile)]
pub fn compile_for_browser(
    file_name: &str,
    source: &str,
    asset_catalog_json: &str,
    debug: bool,
) -> Result<String, String> {
    let assets: AssetCatalog =
        serde_json::from_str(asset_catalog_json).map_err(|error| error.to_string())?;
    let source = SourceFile::new(FileId(0), file_name, source);
    let output = compile_source(
        &source,
        &assets,
        if debug {
            CompileMode::Debug
        } else {
            CompileMode::Release
        },
    );
    serde_json::to_string(&output).map_err(|error| error.to_string())
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
