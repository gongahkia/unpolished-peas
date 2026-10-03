//! Browser boundary for the shared MODL compiler.

use wasm_bindgen::prelude::wasm_bindgen;

use modl_core::{
    AssetCatalog, CompileMode, FileId, SourceFile, analyze_module, compile as compile_source,
    compile_project, decode_cartridge, encode_workcart, export_standalone_html,
    export_standalone_workcart, format_source, materialize_workcart_recipe, pack_project,
    pack_workcart, parse_project_manifest, parse_workcart, rewrite_workcart,
    unpack_cartridge_project, unpack_workcart, workcart_project_view,
};

/// Returns the compiler version used by the browser studio.
#[must_use]
#[wasm_bindgen]
pub fn compiler_version() -> String {
    modl_core::compiler_version().to_owned()
}

/// Returns the implemented language revision.
#[must_use]
#[wasm_bindgen]
pub fn language_revision() -> String {
    modl_core::LANGUAGE_REVISION.to_owned()
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

/// Analyzes MODL using a JSON-encoded typed asset catalog.
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

/// Parses an authored `M01W/2` work-cart through the same validation boundary as the CLI.
///
/// # Errors
///
/// Returns stable work-cart validation errors.
#[wasm_bindgen(js_name = parseWorkcart)]
pub fn parse_workcart_for_browser(source: &str) -> Result<String, String> {
    let project = parse_workcart(source).map_err(|error| error.to_string())?;
    serde_json::to_string(&project).map_err(|error| error.to_string())
}

/// Materializes a work-cart into the manifest-and-file view used by existing browser editors.
///
/// # Errors
///
/// Returns work-cart validation or serialization errors.
#[wasm_bindgen(js_name = workcartProjectView)]
pub fn workcart_project_view_for_browser(source: &str) -> Result<String, String> {
    let project = workcart_project_view(source).map_err(|error| error.to_string())?;
    serde_json::to_string(&project).map_err(|error| error.to_string())
}

/// Applies a manifest-and-file editor view back to an existing work-cart without losing recipes.
///
/// # Errors
///
/// Returns source, manifest, file, or work-cart validation errors.
#[wasm_bindgen(js_name = rewriteWorkcart)]
pub fn rewrite_workcart_for_browser(
    source: &str,
    manifest: &str,
    files_json: &str,
) -> Result<String, String> {
    let files = serde_json::from_str(files_json).map_err(|error| error.to_string())?;
    rewrite_workcart(source, manifest, &files).map_err(|error| error.to_string())
}

/// Creates an M01W/2 source work-cart from a compiler-facing manifest and files.
///
/// # Errors
///
/// Returns manifest, file, or work-cart validation errors.
#[wasm_bindgen(js_name = encodeWorkcart)]
pub fn encode_workcart_for_browser(manifest: &str, files_json: &str) -> Result<String, String> {
    let manifest = parse_project_manifest(manifest).map_err(|error| error.to_string())?;
    let files = serde_json::from_str(files_json).map_err(|error| error.to_string())?;
    encode_workcart(&manifest, &files, &[], &[]).map_err(|error| error.to_string())
}

/// Links and compiles a work-cart using the shared Rust compiler.
///
/// # Errors
///
/// Returns work-cart, linking, compilation, or serialization errors.
#[wasm_bindgen(js_name = compileWorkcart)]
pub fn compile_workcart_for_browser(source: &str, debug: bool) -> Result<String, String> {
    let project = parse_workcart(source).map_err(|error| error.to_string())?;
    let output = compile_project(
        &toml::to_string(&project.manifest).map_err(|error| error.to_string())?,
        &project.files,
        if debug {
            CompileMode::Debug
        } else {
            CompileMode::Release
        },
    )
    .map_err(|error| error.to_string())?;
    serde_json::to_string(&output).map_err(|error| error.to_string())
}

/// Materializes one stored Noise or WFC recipe using the same deterministic core as `mod01`.
///
/// # Errors
///
/// Returns work-cart, generator corpus, or generated map validation errors.
#[wasm_bindgen(js_name = materializeWorkcartRecipe)]
pub fn materialize_workcart_recipe_for_browser(
    source: &str,
    recipe_id: &str,
) -> Result<String, String> {
    materialize_workcart_recipe(source, recipe_id).map_err(|error| error.to_string())
}

/// Formats a syntactically valid MODL/1 module.
///
/// # Errors
///
/// Returns designed diagnostics as JSON when the source is invalid.
#[wasm_bindgen]
pub fn format(file_name: &str, source: &str) -> Result<String, String> {
    let source = SourceFile::new(FileId(0), file_name, source);
    format_source(&source).map_err(|error| {
        serde_json::to_string(&error.diagnostics).unwrap_or_else(|serialization_error| {
            format!("MODL diagnostic serialization failed: {serialization_error}")
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

/// Packs a work-cart into a deterministic source-visible revision-2 cartridge.
///
/// # Errors
///
/// Returns the same validation, compilation, and capacity errors as the native packer.
#[wasm_bindgen(js_name = packWorkcart)]
pub fn pack_workcart_for_browser(source: &str) -> Result<Vec<u8>, String> {
    pack_workcart(source)
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

/// Validates and reconstructs a source-visible project for browser import.
///
/// # Errors
///
/// Returns a bounded cartridge or serialization error.
#[wasm_bindgen(js_name = unpackCartridge)]
pub fn unpack_cartridge_for_browser(bytes: &[u8]) -> Result<String, String> {
    let project = unpack_cartridge_project(bytes).map_err(|error| error.to_string())?;
    serde_json::to_string(&project).map_err(|error| error.to_string())
}

/// Restores the exact source work-cart from a revision-2 cartridge.
///
/// # Errors
///
/// Returns a revision, archive, or work-cart validation error.
#[wasm_bindgen(js_name = unpackWorkcart)]
pub fn unpack_workcart_for_browser(bytes: &[u8]) -> Result<String, String> {
    unpack_workcart(bytes).map_err(|error| error.to_string())
}

/// Exports browser-owned project files as a validated, offline standalone player.
///
/// # Errors
///
/// Returns the same project, compilation, capacity, or serialization errors as the packer.
#[wasm_bindgen(js_name = exportHtml)]
pub fn export_html_for_browser(manifest: &str, files_json: &str) -> Result<String, String> {
    let files = serde_json::from_str(files_json).map_err(|error| error.to_string())?;
    export_standalone_html(manifest, &files).map_err(|error| error.to_string())
}

/// Exports a work-cart as one validated, offline standalone player.
///
/// # Errors
///
/// Returns the same work-cart, compilation, and capacity errors as the native exporter.
#[wasm_bindgen(js_name = exportHtmlWorkcart)]
pub fn export_html_workcart_for_browser(source: &str) -> Result<String, String> {
    export_standalone_workcart(source).map_err(|error| error.to_string())
}
