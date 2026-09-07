//! Browser boundary for the shared PXCL compiler.

use wasm_bindgen::prelude::wasm_bindgen;

use pxcl_core::{
    AssetCatalog, CompileMode, FileId, SourceFile, analyze_module, compile as compile_source,
    compile_project, decode_cartridge, format_source, pack_project, parse_project_manifest,
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

/// Parses and validates `cart.toml` for browser project tooling.
///
/// # Errors
///
/// Returns the same stable manifest error used by the CLI and packer.
#[wasm_bindgen(js_name = parseProjectManifest)]
pub fn parse_project_manifest_for_browser(source: &str) -> Result<String, String> {
    let manifest = parse_project_manifest(source).map_err(|error| error.to_string())?;
    serde_json::to_string(&manifest).map_err(|error| error.to_string())
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

/// Links and compiles a browser-owned project through the same pipeline as the native CLI.
///
/// # Errors
///
/// Returns an error when project files cannot be decoded, linked, compiled, or serialized.
#[wasm_bindgen(js_name = compileProject)]
pub fn compile_project_for_browser(
    manifest: &str,
    files_json: &str,
    debug: bool,
) -> Result<String, String> {
    let files = serde_json::from_str(files_json).map_err(|error| error.to_string())?;
    let output = compile_project(
        manifest,
        &files,
        if debug {
            CompileMode::Debug
        } else {
            CompileMode::Release
        },
    )
    .map_err(|error| error.to_string())?;
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

/// Packs browser-owned project files with the same canonical implementation as the native CLI.
///
/// # Errors
///
/// Returns a project, compilation, capacity, or serialization error.
#[wasm_bindgen(js_name = packProject)]
pub fn pack_project_for_browser(manifest: &str, files_json: &str) -> Result<Vec<u8>, String> {
    let files = serde_json::from_str(files_json).map_err(|error| error.to_string())?;
    pack_project(manifest, &files)
        .map(|packed| packed.bytes)
        .map_err(|error| error.to_string())
}

/// Validates and decodes an untrusted cartridge for browser import and inspection.
///
/// # Errors
///
/// Returns a bounded decoder, integrity, revision, or serialization error.
#[wasm_bindgen(js_name = decodeCartridge)]
pub fn decode_cartridge_for_browser(bytes: &[u8]) -> Result<String, String> {
    let cartridge = decode_cartridge(bytes).map_err(|error| error.to_string())?;
    serde_json::to_string(&cartridge).map_err(|error| error.to_string())
}
