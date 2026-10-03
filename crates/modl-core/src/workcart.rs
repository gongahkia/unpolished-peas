use std::{
    collections::{BTreeMap, BTreeSet},
    path::Path,
};

use serde::{Deserialize, Serialize};

use crate::{
    AssetKind, CARTRIDGE_FORMAT_REVISION, CartridgeError, ProjectAsset, ProjectManifest,
    parse_project_manifest,
};

/// The authored work-cart revision supported by this compiler.
pub const WORKCART_FORMAT_REVISION: u16 = 2;

type MaterializedFiles = (BTreeMap<String, ProjectAsset>, BTreeMap<String, Vec<u8>>);

/// A parsed source-visible work-cart and its compiler-facing project view.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkcartProject {
    /// Exact UTF-8 authoring source, retained when the cartridge is packed.
    pub source: String,
    /// Validated project metadata consumed by the compiler and runtime.
    pub manifest: ProjectManifest,
    /// MODL, asset, and presentation files materialized from the work-cart.
    pub files: BTreeMap<String, Vec<u8>>,
    /// Author-time-only deterministic generation recipes.
    pub recipes: Vec<WorkcartRecipe>,
    /// Named source and replay tests retained in the work-cart.
    pub tests: Vec<WorkcartTest>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
struct WorkcartDocument {
    format: u16,
    cartridge: WorkcartCartridge,
    #[serde(default)]
    module: Vec<WorkcartModule>,
    #[serde(default)]
    asset: Vec<WorkcartAsset>,
    #[serde(default)]
    file: Vec<WorkcartFile>,
    #[serde(default)]
    recipe: Vec<WorkcartRecipe>,
    #[serde(default)]
    test: Vec<WorkcartTest>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
struct WorkcartCartridge {
    language: String,
    id: String,
    title: String,
    author: String,
    version: String,
    entry: String,
    update_rate: u8,
    #[serde(default)]
    compile_on_load: bool,
    #[serde(default)]
    label: Option<String>,
    #[serde(default)]
    thumbnail: Option<String>,
    #[serde(default)]
    display: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
struct WorkcartModule {
    path: String,
    source: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
struct WorkcartAsset {
    name: String,
    kind: AssetKind,
    path: String,
    payload: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
struct WorkcartFile {
    path: String,
    payload: String,
}

/// A deterministic map recipe retained as work-cart source.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "algorithm", rename_all = "snake_case", deny_unknown_fields)]
pub enum WorkcartRecipe {
    /// A seeded palette of tile IDs distributed across a bounded map.
    Noise {
        id: String,
        output: String,
        seed: u64,
        width: u16,
        height: u16,
        tile_set: String,
        tiles: Vec<u16>,
    },
    /// A seeded Wave Function Collapse map inferred from a declared source map.
    Wfc {
        id: String,
        output: String,
        seed: u64,
        width: u16,
        height: u16,
        tile_set: String,
        source_map: String,
        pattern_size: u8,
    },
}

impl WorkcartRecipe {
    #[must_use]
    pub fn id(&self) -> &str {
        match self {
            Self::Noise { id, .. } | Self::Wfc { id, .. } => id,
        }
    }

    #[must_use]
    pub fn output(&self) -> &str {
        match self {
            Self::Noise { output, .. } | Self::Wfc { output, .. } => output,
        }
    }

    #[must_use]
    pub const fn dimensions(&self) -> (u16, u16) {
        match self {
            Self::Noise { width, height, .. } | Self::Wfc { width, height, .. } => {
                (*width, *height)
            }
        }
    }
}

/// A source or replay test stored with its authored cartridge.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct WorkcartTest {
    pub name: String,
    pub path: String,
    pub kind: WorkcartTestKind,
    pub payload: String,
}

/// Test payload semantics supported by a work-cart.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkcartTestKind {
    Modl,
    Replay,
}

/// Parses and validates a source-visible `M01W/2` work-cart.
///
/// # Errors
///
/// Returns stable `M01402x` errors for malformed work-cart structure, duplicate authored
/// names, invalid paths, invalid assets, or inconsistent references.
pub fn parse_workcart(source: &str) -> Result<WorkcartProject, CartridgeError> {
    let document: WorkcartDocument = toml::from_str(source)
        .map_err(|error| workcart_error("M014020", format!("invalid .m01w: {error}")))?;
    if document.format != WORKCART_FORMAT_REVISION {
        return Err(workcart_error(
            "M014021",
            format!(
                "work-cart requests format revision {}; expected {WORKCART_FORMAT_REVISION}",
                document.format
            ),
        ));
    }
    let (assets, files) = materialize_files(&document)?;
    let manifest = manifest_from_cartridge(document.cartridge, assets)?;
    if !files.contains_key(&manifest.entry) {
        return Err(workcart_error(
            "M014024",
            format!("entry module '{}' is missing", manifest.entry),
        ));
    }
    validate_presentation_files(&manifest, &files)?;
    validate_recipes(&document.recipe, &manifest.assets)?;
    validate_tests(&document.test)?;
    Ok(WorkcartProject {
        source: source.to_owned(),
        manifest,
        files,
        recipes: document.recipe,
        tests: document.test,
    })
}

fn materialize_files(document: &WorkcartDocument) -> Result<MaterializedFiles, CartridgeError> {
    let mut assets = BTreeMap::new();
    let mut files = BTreeMap::new();
    let mut paths = BTreeSet::new();
    for module in &document.module {
        require_path(&module.path, "module")?;
        if !has_extension(&module.path, "modl") {
            return Err(workcart_error(
                "M014022",
                format!("module path '{}' must end in .modl", module.path),
            ));
        }
        insert_file(
            &mut files,
            &mut paths,
            &module.path,
            module.source.as_bytes(),
            "module",
        )?;
    }
    for asset in &document.asset {
        require_path(&asset.path, "asset")?;
        if assets
            .insert(
                asset.name.clone(),
                ProjectAsset {
                    kind: asset.kind,
                    path: asset.path.clone(),
                },
            )
            .is_some()
        {
            return Err(workcart_error(
                "M014022",
                format!("asset name '{}' is duplicated", asset.name),
            ));
        }
        let _: serde_json::Value = serde_json::from_str(&asset.payload).map_err(|error| {
            workcart_error(
                "M014023",
                format!("asset '{}' payload is not valid JSON: {error}", asset.name),
            )
        })?;
        insert_file(
            &mut files,
            &mut paths,
            &asset.path,
            asset.payload.as_bytes(),
            "asset",
        )?;
    }
    for file in &document.file {
        require_path(&file.path, "file")?;
        insert_file(
            &mut files,
            &mut paths,
            &file.path,
            file.payload.as_bytes(),
            "file",
        )?;
    }
    Ok((assets, files))
}

fn manifest_from_cartridge(
    cartridge: WorkcartCartridge,
    assets: BTreeMap<String, ProjectAsset>,
) -> Result<ProjectManifest, CartridgeError> {
    let manifest = ProjectManifest {
        format_revision: CARTRIDGE_FORMAT_REVISION,
        language_revision: cartridge.language,
        id: cartridge.id,
        title: cartridge.title,
        author: cartridge.author,
        version: cartridge.version,
        entry: cartridge.entry,
        update_rate: cartridge.update_rate,
        compile_on_load: cartridge.compile_on_load,
        label: cartridge.label,
        thumbnail: cartridge.thumbnail,
        display: cartridge.display,
        assets,
    };
    let manifest_source =
        toml::to_string(&manifest).map_err(|error| workcart_error("M014020", error.to_string()))?;
    parse_project_manifest(&manifest_source)
}

fn validate_presentation_files(
    manifest: &ProjectManifest,
    files: &BTreeMap<String, Vec<u8>>,
) -> Result<(), CartridgeError> {
    for path in [&manifest.label, &manifest.thumbnail, &manifest.display]
        .into_iter()
        .flatten()
    {
        if !files.contains_key(path) {
            return Err(workcart_error(
                "M014024",
                format!("presentation file '{path}' is missing"),
            ));
        }
    }
    Ok(())
}

fn validate_recipes(
    recipes: &[WorkcartRecipe],
    assets: &BTreeMap<String, ProjectAsset>,
) -> Result<(), CartridgeError> {
    let mut ids = BTreeSet::new();
    for recipe in recipes {
        if !ids.insert(recipe.id()) {
            return Err(workcart_error(
                "M014022",
                format!("recipe id '{}' is duplicated", recipe.id()),
            ));
        }
        let (width, height) = recipe.dimensions();
        if width == 0 || height == 0 || width > 256 || height > 256 {
            return Err(workcart_error(
                "M014025",
                format!("recipe '{}' dimensions must be within 1..=256", recipe.id()),
            ));
        }
        let output = assets.get(recipe.output());
        if !matches!(
            output,
            Some(ProjectAsset {
                kind: AssetKind::Map,
                ..
            })
        ) {
            return Err(workcart_error(
                "M014025",
                format!(
                    "recipe '{}' output '{}' is not a map asset",
                    recipe.id(),
                    recipe.output()
                ),
            ));
        }
        match recipe {
            WorkcartRecipe::Noise {
                tile_set, tiles, ..
            } => {
                if tiles.is_empty() {
                    return Err(workcart_error(
                        "M014025",
                        format!("noise recipe '{}' has no tile IDs", recipe.id()),
                    ));
                }
                require_tile_set(tile_set, recipe.id(), assets)?;
            }
            WorkcartRecipe::Wfc {
                tile_set,
                source_map,
                pattern_size,
                ..
            } => {
                if !(2..=8).contains(pattern_size) {
                    return Err(workcart_error(
                        "M014025",
                        format!(
                            "wfc recipe '{}' pattern_size must be within 2..=8",
                            recipe.id()
                        ),
                    ));
                }
                require_tile_set(tile_set, recipe.id(), assets)?;
                if !matches!(
                    assets.get(source_map),
                    Some(ProjectAsset {
                        kind: AssetKind::Map,
                        ..
                    })
                ) {
                    return Err(workcart_error(
                        "M014025",
                        format!(
                            "wfc recipe '{}' source_map '{source_map}' is not a map asset",
                            recipe.id()
                        ),
                    ));
                }
            }
        }
    }
    Ok(())
}

fn require_tile_set(
    name: &str,
    recipe_id: &str,
    assets: &BTreeMap<String, ProjectAsset>,
) -> Result<(), CartridgeError> {
    if matches!(
        assets.get(name),
        Some(ProjectAsset {
            kind: AssetKind::TileSet,
            ..
        })
    ) {
        Ok(())
    } else {
        Err(workcart_error(
            "M014025",
            format!("recipe '{recipe_id}' tile_set '{name}' is not a tile_set asset"),
        ))
    }
}

fn validate_tests(tests: &[WorkcartTest]) -> Result<(), CartridgeError> {
    let mut names = BTreeSet::new();
    let mut paths = BTreeSet::new();
    for test in tests {
        if !names.insert(&test.name) {
            return Err(workcart_error(
                "M014022",
                format!("test name '{}' is duplicated", test.name),
            ));
        }
        require_path(&test.path, "test")?;
        if !paths.insert(&test.path) {
            return Err(workcart_error(
                "M014022",
                format!("test path '{}' is duplicated", test.path),
            ));
        }
        let valid_path = match test.kind {
            WorkcartTestKind::Modl => has_extension(&test.path, "modl"),
            WorkcartTestKind::Replay => Path::new(&test.path)
                .file_name()
                .is_some_and(|name| name.to_string_lossy().ends_with(".m01run.json")),
        };
        if !valid_path {
            return Err(workcart_error(
                "M014026",
                format!("test '{}' path does not match its kind", test.name),
            ));
        }
    }
    Ok(())
}

fn insert_file(
    files: &mut BTreeMap<String, Vec<u8>>,
    paths: &mut BTreeSet<String>,
    path: &str,
    bytes: &[u8],
    role: &str,
) -> Result<(), CartridgeError> {
    if !paths.insert(path.to_owned()) {
        return Err(workcart_error(
            "M014022",
            format!("{role} path '{path}' is duplicated"),
        ));
    }
    files.insert(path.to_owned(), bytes.to_vec());
    Ok(())
}

fn require_path(path: &str, role: &str) -> Result<(), CartridgeError> {
    if path.is_empty()
        || path.starts_with('/')
        || path.contains('\\')
        || !path.is_ascii()
        || path.len() > 1024
        || path.split('/').any(|part| {
            part.is_empty()
                || part == "."
                || part == ".."
                || !part
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(&byte))
        })
    {
        return Err(workcart_error(
            "M014022",
            format!("{role} path '{path}' is not a canonical relative ASCII path"),
        ));
    }
    Ok(())
}

fn workcart_error(code: &'static str, message: String) -> CartridgeError {
    CartridgeError { code, message }
}

fn has_extension(path: &str, extension: &str) -> bool {
    Path::new(path)
        .extension()
        .is_some_and(|value| value == extension)
}

#[cfg(test)]
mod tests {
    use super::{WORKCART_FORMAT_REVISION, WorkcartRecipe, parse_workcart};

    const CART: &str = r#"format = 2

[cartridge]
language = "MODL/1"
id = "workcart-test"
title = "WORKCART TEST"
author = "@gongahkia"
version = "0.1.0"
entry = "src/main.modl"
update_rate = 60
label = "presentation/label.svg"

[[module]]
path = "src/main.modl"
source = "on draw:\n  clear(25)\n"

[[asset]]
name = "tiles"
kind = "tile_set"
path = "assets/tiles.m01g"
payload = '''{"revision":1,"kind":"tile_set","tiles":[[0,0,0,0,0,0,0,0]],"flags":[0]}'''

[[asset]]
name = "world"
kind = "map"
path = "assets/world.m01m"
payload = '''{"revision":1,"kind":"map","layers":[]}'''

[[file]]
path = "presentation/label.svg"
payload = "<svg/>"

[[recipe]]
algorithm = "noise"
id = "noise-world"
output = "world"
seed = 1
width = 30
height = 18
tile_set = "tiles"
tiles = [0]

[[test]]
name = "smoke"
kind = "modl"
path = "tests/smoke.modl"
payload = "on start:\n  assert true\n"
"#;

    #[test]
    fn parses_a_source_visible_workcart() {
        let project = parse_workcart(CART).expect("work-cart parses");
        assert_eq!(WORKCART_FORMAT_REVISION, 2);
        assert_eq!(project.manifest.id, "workcart-test");
        assert_eq!(project.files.len(), 4);
        assert_eq!(project.files["src/main.modl"], b"on draw:\n  clear(25)\n");
        assert_eq!(project.source, CART);
        assert!(matches!(
            project.recipes.as_slice(),
            [WorkcartRecipe::Noise { .. }]
        ));
        assert_eq!(project.tests.len(), 1);
    }

    #[test]
    fn rejects_duplicate_paths_and_invalid_recipe_references() {
        let duplicate = CART.replace(
            "path = \"presentation/label.svg\"\npayload = \"<svg/>\"",
            "path = \"assets/world.m01m\"\npayload = \"<svg/>\"",
        );
        assert_eq!(parse_workcart(&duplicate).unwrap_err().code, "M014022");
        let invalid = CART.replace("output = \"world\"", "output = \"tiles\"");
        assert_eq!(parse_workcart(&invalid).unwrap_err().code, "M014025");
    }

    #[test]
    fn rejects_unknown_workcart_revisions() {
        assert_eq!(
            parse_workcart(&CART.replacen("format = 2", "format = 1", 1))
                .unwrap_err()
                .code,
            "M014021"
        );
    }
}
