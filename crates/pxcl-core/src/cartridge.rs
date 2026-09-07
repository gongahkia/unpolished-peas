use std::{
    collections::{BTreeMap, BTreeSet},
    fmt::{self, Write as _},
    path::Path,
};

use serde::{Deserialize, Serialize};

use crate::{
    AssetCatalog, AssetKind, CARTRIDGE_FORMAT_REVISION, CompilationOutput, CompileMode, FileId,
    LANGUAGE_REVISION, SourceFile, TokenKind,
    ast::{Item, Module},
    compile, compiler_version, parse,
};

const MAGIC: &[u8; 8] = b"PX240C\x1a\x01";
pub const CARTRIDGE_CAPACITY_BYTES: usize = 256 * 1024;
const MAX_UNPACKED_BYTES: usize = 2 * 1024 * 1024;
const MAX_ARCHIVE_ENTRIES: usize = 4096;
const SHA256_INITIAL: [u32; 8] = [
    0x6a09_e667,
    0xbb67_ae85,
    0x3c6e_f372,
    0xa54f_f53a,
    0x510e_527f,
    0x9b05_688c,
    0x1f83_d9ab,
    0x5be0_cd19,
];
const SHA256_ROUND: [u32; 64] = [
    0x428a_2f98,
    0x7137_4491,
    0xb5c0_fbcf,
    0xe9b5_dba5,
    0x3956_c25b,
    0x59f1_11f1,
    0x923f_82a4,
    0xab1c_5ed5,
    0xd807_aa98,
    0x1283_5b01,
    0x2431_85be,
    0x550c_7dc3,
    0x72be_5d74,
    0x80de_b1fe,
    0x9bdc_06a7,
    0xc19b_f174,
    0xe49b_69c1,
    0xefbe_4786,
    0x0fc1_9dc6,
    0x240c_a1cc,
    0x2de9_2c6f,
    0x4a74_84aa,
    0x5cb0_a9dc,
    0x76f9_88da,
    0x983e_5152,
    0xa831_c66d,
    0xb003_27c8,
    0xbf59_7fc7,
    0xc6e0_0bf3,
    0xd5a7_9147,
    0x06ca_6351,
    0x1429_2967,
    0x27b7_0a85,
    0x2e1b_2138,
    0x4d2c_6dfc,
    0x5338_0d13,
    0x650a_7354,
    0x766a_0abb,
    0x81c2_c92e,
    0x9272_2c85,
    0xa2bf_e8a1,
    0xa81a_664b,
    0xc24b_8b70,
    0xc76c_51a3,
    0xd192_e819,
    0xd699_0624,
    0xf40e_3585,
    0x106a_a070,
    0x19a4_c116,
    0x1e37_6c08,
    0x2748_774c,
    0x34b0_bcb5,
    0x391c_0cb3,
    0x4ed8_aa4a,
    0x5b9c_ca4f,
    0x682e_6ff3,
    0x748f_82ee,
    0x78a5_636f,
    0x84c8_7814,
    0x8cc7_0208,
    0x90be_fffa,
    0xa450_6ceb,
    0xbef9_a3f7,
    0xc671_78f2,
];

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ProjectManifest {
    #[serde(rename = "format")]
    pub format_revision: u16,
    #[serde(rename = "language")]
    pub language_revision: String,
    pub id: String,
    pub title: String,
    pub author: String,
    pub version: String,
    pub entry: String,
    pub update_rate: u8,
    #[serde(default)]
    pub label: Option<String>,
    #[serde(default)]
    pub thumbnail: Option<String>,
    #[serde(default)]
    pub assets: BTreeMap<String, ProjectAsset>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ProjectAsset {
    pub kind: AssetKind,
    pub path: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PackedManifest {
    pub format_revision: u16,
    pub language_revision: String,
    pub compiler_version: String,
    pub id: String,
    pub title: String,
    pub author: String,
    pub version: String,
    pub entry: String,
    pub update_rate: u8,
    pub label: Option<String>,
    pub thumbnail: Option<String>,
    pub assets: BTreeMap<String, PackedAsset>,
    pub files: BTreeMap<String, FileIntegrity>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PackedAsset {
    pub kind: AssetKind,
    pub path: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct FileIntegrity {
    pub bytes: u32,
    pub sha256: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PackedCartridge {
    pub bytes: Vec<u8>,
    pub manifest: PackedManifest,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct DecodedCartridge {
    pub manifest: PackedManifest,
    pub entries: BTreeMap<String, Vec<u8>>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CartridgeError {
    pub code: &'static str,
    pub message: String,
}

impl fmt::Display for CartridgeError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "error[{}]: {}", self.code, self.message)
    }
}

impl std::error::Error for CartridgeError {}

/// Parses and validates the Git-friendly `cart.toml` project manifest.
///
/// # Errors
///
/// Returns a stable `PX40xx` error when TOML decoding or manifest validation fails.
pub fn parse_project_manifest(source: &str) -> Result<ProjectManifest, CartridgeError> {
    let manifest: ProjectManifest = toml::from_str(source)
        .map_err(|error| cartridge_error("PX4001", format!("invalid cart.toml: {error}")))?;
    validate_manifest(&manifest)?;
    Ok(manifest)
}

/// Builds one canonical, compressed, source-inspectable `.pxc` byte sequence.
///
/// # Errors
///
/// Returns a stable `PX40xx` error for invalid manifests, missing files, compiler diagnostics,
/// archive collisions, or capacity violations.
pub fn pack_project(
    manifest_source: &str,
    project_files: &BTreeMap<String, Vec<u8>>,
) -> Result<PackedCartridge, CartridgeError> {
    let manifest = parse_project_manifest(manifest_source)?;
    let normalized_entry = normalize_project_path(&manifest.entry)?;
    let mut asset_catalog = AssetCatalog::default();
    for (name, asset) in &manifest.assets {
        asset_catalog.insert(name.clone(), asset.kind);
    }
    let compilation = compile_linked_project(
        &manifest,
        project_files,
        &asset_catalog,
        CompileMode::Release,
    )?;
    if let Some(diagnostic) = compilation.analysis.diagnostics.first() {
        return Err(cartridge_error(
            "PX4003",
            format!(
                "entry source did not compile: error[{}] {}",
                diagnostic.code, diagnostic.message
            ),
        ));
    }
    let generated = compilation.generated.ok_or_else(|| {
        cartridge_error(
            "PX4003",
            "entry source produced no release program".to_owned(),
        )
    })?;

    let (mut entries, packed_assets, label, thumbnail) = collect_project_entries(
        &manifest,
        project_files,
        generated.javascript,
        generated.source_map_json,
    )?;

    let files = entries
        .iter()
        .map(|(path, bytes)| {
            (
                path.clone(),
                FileIntegrity {
                    bytes: u32::try_from(bytes.len()).unwrap_or(u32::MAX),
                    sha256: sha256_hex(bytes),
                },
            )
        })
        .collect();
    let packed_manifest = PackedManifest {
        format_revision: CARTRIDGE_FORMAT_REVISION,
        language_revision: LANGUAGE_REVISION.to_owned(),
        compiler_version: compiler_version().to_owned(),
        id: manifest.id,
        title: manifest.title,
        author: manifest.author,
        version: manifest.version,
        entry: format!("source/{normalized_entry}"),
        update_rate: manifest.update_rate,
        label,
        thumbnail,
        assets: packed_assets,
        files,
    };
    let canonical_manifest = serde_json::to_vec(&packed_manifest).map_err(|error| {
        cartridge_error(
            "PX4004",
            format!("could not encode packed manifest: {error}"),
        )
    })?;
    insert_unique(&mut entries, "manifest.json".to_owned(), canonical_manifest)?;
    let bytes = encode_archive(&entries)?;
    if bytes.len() > CARTRIDGE_CAPACITY_BYTES {
        return Err(cartridge_error(
            "PX4005",
            format!(
                "packed cartridge is {} bytes; capacity is {CARTRIDGE_CAPACITY_BYTES}",
                bytes.len()
            ),
        ));
    }
    Ok(PackedCartridge {
        bytes,
        manifest: packed_manifest,
    })
}

/// Links imported project modules and compiles them through the ordinary typed pipeline.
///
/// Imports use absolute dotted project paths: `import src.math as math` resolves
/// `src/math.pxl`. Reachable modules are flattened in dependency order after checking that their
/// top-level names do not collide. This keeps generated JavaScript free of host module loading.
///
/// # Errors
///
/// Returns a stable `PX40xx` error for an invalid manifest, missing module, import cycle, parse
/// failure, unsupported dependency callback, or cross-module top-level name collision.
pub fn compile_project(
    manifest_source: &str,
    project_files: &BTreeMap<String, Vec<u8>>,
    mode: CompileMode,
) -> Result<CompilationOutput, CartridgeError> {
    let manifest = parse_project_manifest(manifest_source)?;
    let mut asset_catalog = AssetCatalog::default();
    for (name, asset) in &manifest.assets {
        asset_catalog.insert(name.clone(), asset.kind);
    }
    compile_linked_project(&manifest, project_files, &asset_catalog, mode)
}

fn compile_linked_project(
    manifest: &ProjectManifest,
    project_files: &BTreeMap<String, Vec<u8>>,
    assets: &AssetCatalog,
    mode: CompileMode,
) -> Result<CompilationOutput, CartridgeError> {
    let entry = normalize_project_path(&manifest.entry)?;
    let source = link_project_sources(&entry, project_files)?;
    Ok(compile(&source, assets, mode))
}

#[derive(Clone, Debug)]
struct ProjectModule {
    text: String,
    syntax: Module,
}

fn link_project_sources(
    entry: &str,
    project_files: &BTreeMap<String, Vec<u8>>,
) -> Result<SourceFile, CartridgeError> {
    let mut modules = BTreeMap::new();
    for (index, (path, bytes)) in project_files
        .iter()
        .filter(|(path, _)| has_pxl_extension(path))
        .enumerate()
    {
        let path = normalize_project_path(path)?;
        let text = normalized_source(bytes, &path)?;
        let source = SourceFile::new(
            FileId(u32::try_from(index).unwrap_or(u32::MAX)),
            path.clone(),
            text.clone(),
        );
        let parsed = parse(&source);
        if let Some(diagnostic) = parsed.diagnostics.first() {
            return Err(cartridge_error(
                "PX4003",
                format!(
                    "module '{path}' did not parse: error[{}] {}",
                    diagnostic.code, diagnostic.message
                ),
            ));
        }
        modules.insert(
            path,
            ProjectModule {
                text,
                syntax: parsed.module,
            },
        );
    }
    if !modules.contains_key(entry) {
        return Err(cartridge_error(
            "PX4002",
            format!("entry source '{entry}' is missing"),
        ));
    }
    let mut visiting = Vec::new();
    let mut visited = BTreeSet::<String>::new();
    let mut order = Vec::new();
    visit_module(entry, &modules, &mut visiting, &mut visited, &mut order)?;
    validate_link_names(entry, &order, &modules)?;

    let mut linked = String::new();
    for path in order {
        let module = modules.get(&path).expect("visited modules exist");
        linked.push_str(&render_module(&path, module, &modules)?);
        if !linked.ends_with('\n') {
            linked.push('\n');
        }
        linked.push('\n');
    }
    Ok(SourceFile::new(
        FileId(0),
        format!("project/{entry}"),
        linked,
    ))
}

fn visit_module(
    path: &str,
    modules: &BTreeMap<String, ProjectModule>,
    visiting: &mut Vec<String>,
    visited: &mut BTreeSet<String>,
    order: &mut Vec<String>,
) -> Result<(), CartridgeError> {
    if visited.contains(path) {
        return Ok(());
    }
    if visiting.iter().any(|candidate| candidate == path) {
        visiting.push(path.to_owned());
        return Err(cartridge_error(
            "PX4008",
            format!("module import cycle: {}", visiting.join(" -> ")),
        ));
    }
    let module = modules
        .get(path)
        .ok_or_else(|| cartridge_error("PX4008", format!("imported module '{path}' is missing")))?;
    visiting.push(path.to_owned());
    for item in &module.syntax.items {
        if let Item::Import(import) = item {
            let imported = import_path(import.path.iter().map(|part| part.value.as_str()))?;
            visit_module(&imported, modules, visiting, visited, order)?;
        }
    }
    visiting.pop();
    visited.insert(path.to_owned());
    order.push(path.to_owned());
    Ok(())
}

fn validate_link_names(
    entry: &str,
    order: &[String],
    modules: &BTreeMap<String, ProjectModule>,
) -> Result<(), CartridgeError> {
    let mut owners = BTreeMap::<String, String>::new();
    for path in order {
        let module = modules.get(path).expect("visited modules exist");
        if path != entry
            && module
                .syntax
                .items
                .iter()
                .any(|item| matches!(item, Item::Callback(_)))
        {
            return Err(cartridge_error(
                "PX4009",
                format!("imported module '{path}' declares a system callback"),
            ));
        }
        for name in module_exports(&module.syntax) {
            if let Some(previous) = owners.insert(name.clone(), path.clone()) {
                return Err(cartridge_error(
                    "PX4009",
                    format!(
                        "top-level name '{name}' collides between modules '{previous}' and '{path}'"
                    ),
                ));
            }
        }
    }
    Ok(())
}

fn render_module(
    path: &str,
    module: &ProjectModule,
    modules: &BTreeMap<String, ProjectModule>,
) -> Result<String, CartridgeError> {
    let mut replacements = Vec::<(usize, usize, String)>::new();
    let mut aliases = BTreeMap::<String, (String, BTreeSet<String>)>::new();
    for item in &module.syntax.items {
        if let Item::Import(import) = item {
            let imported_path = import_path(import.path.iter().map(|part| part.value.as_str()))?;
            let imported = modules.get(&imported_path).ok_or_else(|| {
                cartridge_error(
                    "PX4008",
                    format!("module '{path}' imports missing module '{imported_path}'"),
                )
            })?;
            let alias = import
                .alias
                .as_ref()
                .or_else(|| import.path.last())
                .map(|name| name.value.clone())
                .ok_or_else(|| cartridge_error("PX4008", "empty import path".to_owned()))?;
            if aliases
                .insert(
                    alias.clone(),
                    (
                        imported_path,
                        module_exports(&imported.syntax).into_iter().collect(),
                    ),
                )
                .is_some()
            {
                return Err(cartridge_error(
                    "PX4009",
                    format!("module '{path}' repeats import alias '{alias}'"),
                ));
            }
            replacements.push((
                usize::try_from(import.span.start).unwrap_or(usize::MAX),
                usize::try_from(import.span.end).unwrap_or(usize::MAX),
                String::new(),
            ));
        }
    }
    let source = SourceFile::new(FileId(0), path, module.text.clone());
    let tokens = crate::lex(&source).tokens;
    for window in tokens.windows(3) {
        let TokenKind::Identifier(alias) = &window[0].kind else {
            continue;
        };
        if !matches!(window[1].kind, TokenKind::Dot) {
            continue;
        }
        let TokenKind::Identifier(member) = &window[2].kind else {
            continue;
        };
        let Some((imported_path, exports)) = aliases.get(alias) else {
            continue;
        };
        if !exports.contains(member) {
            return Err(cartridge_error(
                "PX4009",
                format!("module '{imported_path}' has no exported member '{member}'"),
            ));
        }
        replacements.push((
            usize::try_from(window[0].span.start).unwrap_or(usize::MAX),
            usize::try_from(window[2].span.end).unwrap_or(usize::MAX),
            member.clone(),
        ));
    }
    replacements.sort_by_key(|(start, _, _)| *start);
    let mut output = module.text.clone();
    for (start, end, replacement) in replacements.into_iter().rev() {
        let Some(_) = output.get(start..end) else {
            return Err(cartridge_error(
                "PX4009",
                format!("module '{path}' produced an invalid link span"),
            ));
        };
        output.replace_range(start..end, &replacement);
    }
    Ok(output)
}

fn module_exports(module: &Module) -> Vec<String> {
    module
        .items
        .iter()
        .filter_map(|item| match item {
            Item::Constant(value) => Some(value.name.value.clone()),
            Item::State(value) => Some(value.name.value.clone()),
            Item::Function(value) => Some(value.name.value.clone()),
            Item::Task(value) => Some(value.name.value.clone()),
            Item::Record(value) => Some(value.name.value.clone()),
            Item::Enum(value) => Some(value.name.value.clone()),
            Item::Import(_) | Item::Callback(_) | Item::Assertion(_) => None,
        })
        .collect()
}

fn import_path<'a>(parts: impl Iterator<Item = &'a str>) -> Result<String, CartridgeError> {
    let path = format!("{}.pxl", parts.collect::<Vec<_>>().join("/"));
    normalize_project_path(&path)
}

fn collect_project_entries(
    manifest: &ProjectManifest,
    project_files: &BTreeMap<String, Vec<u8>>,
    javascript: String,
    source_map: String,
) -> Result<CollectedEntries, CartridgeError> {
    let mut entries = BTreeMap::<String, Vec<u8>>::new();
    for (path, bytes) in project_files {
        let path = normalize_project_path(path)?;
        if has_pxl_extension(&path) {
            let text = normalized_source(bytes, &path)?;
            insert_unique(&mut entries, format!("source/{path}"), text.into_bytes())?;
        }
    }
    let mut packed_assets = BTreeMap::new();
    for (name, asset) in &manifest.assets {
        let project_path = normalize_project_path(&asset.path)?;
        let bytes = project_files.get(&project_path).ok_or_else(|| {
            cartridge_error(
                "PX4002",
                format!("asset '{name}' is missing file '{project_path}'"),
            )
        })?;
        let archive_path = format!("assets/{project_path}");
        insert_unique(&mut entries, archive_path.clone(), bytes.clone())?;
        packed_assets.insert(
            name.clone(),
            PackedAsset {
                kind: asset.kind,
                path: archive_path,
            },
        );
    }
    let label = include_presentation_file(
        &mut entries,
        project_files,
        manifest.label.as_deref(),
        "label",
    )?;
    let thumbnail = include_presentation_file(
        &mut entries,
        project_files,
        manifest.thumbnail.as_deref(),
        "thumbnail",
    )?;
    insert_unique(
        &mut entries,
        "build/cartridge.js".to_owned(),
        javascript.into_bytes(),
    )?;
    insert_unique(
        &mut entries,
        "build/cartridge.js.map".to_owned(),
        source_map.into_bytes(),
    )?;
    Ok((entries, packed_assets, label, thumbnail))
}

type CollectedEntries = (
    BTreeMap<String, Vec<u8>>,
    BTreeMap<String, PackedAsset>,
    Option<String>,
    Option<String>,
);

/// Decodes an untrusted `.pxc`, enforcing bounds, hashes, ordering, and manifest integrity.
///
/// # Errors
///
/// Returns a stable `PX40xx` error for malformed, oversized, non-canonical, or corrupted input.
pub fn decode_cartridge(bytes: &[u8]) -> Result<DecodedCartridge, CartridgeError> {
    if bytes.len() > CARTRIDGE_CAPACITY_BYTES {
        return Err(cartridge_error(
            "PX4010",
            "cartridge exceeds the packed capacity".to_owned(),
        ));
    }
    let mut reader = Reader::new(bytes);
    if reader.take(MAGIC.len())? != MAGIC {
        return Err(cartridge_error(
            "PX4010",
            "cartridge magic or revision is invalid".to_owned(),
        ));
    }
    let entry_count = usize::try_from(reader.u32()?).unwrap_or(usize::MAX);
    if entry_count == 0 || entry_count > MAX_ARCHIVE_ENTRIES {
        return Err(cartridge_error(
            "PX4010",
            "cartridge entry count is outside format limits".to_owned(),
        ));
    }
    let mut entries = BTreeMap::new();
    let mut previous_path: Option<String> = None;
    let mut unpacked_bytes = 0_usize;
    for _ in 0..entry_count {
        let path_length = usize::from(reader.u16()?);
        let raw_length = usize::try_from(reader.u32()?).unwrap_or(usize::MAX);
        let encoded_length = usize::try_from(reader.u32()?).unwrap_or(usize::MAX);
        let expected_hash: [u8; 32] = reader
            .take(32)?
            .try_into()
            .map_err(|_| cartridge_error("PX4010", "invalid entry hash length".to_owned()))?;
        let path = std::str::from_utf8(reader.take(path_length)?)
            .map_err(|_| cartridge_error("PX4010", "entry path is not UTF-8".to_owned()))?;
        let path = normalize_archive_path(path)?;
        if previous_path
            .as_ref()
            .is_some_and(|previous| previous >= &path)
        {
            return Err(cartridge_error(
                "PX4010",
                "cartridge entries are not strictly sorted".to_owned(),
            ));
        }
        unpacked_bytes = unpacked_bytes
            .checked_add(raw_length)
            .ok_or_else(|| cartridge_error("PX4010", "unpacked size overflow".to_owned()))?;
        if unpacked_bytes > MAX_UNPACKED_BYTES {
            return Err(cartridge_error(
                "PX4010",
                "cartridge expands beyond the decoder limit".to_owned(),
            ));
        }
        let encoded = reader.take(encoded_length)?;
        let decoded = rle_decode(encoded, raw_length)?;
        if rle_encode(&decoded) != encoded {
            return Err(cartridge_error(
                "PX4010",
                format!("entry '{path}' does not use canonical compression"),
            ));
        }
        if sha256(&decoded) != expected_hash {
            return Err(cartridge_error(
                "PX4011",
                format!("integrity hash failed for '{path}'"),
            ));
        }
        previous_path = Some(path.clone());
        entries.insert(path, decoded);
    }
    if !reader.finished() {
        return Err(cartridge_error(
            "PX4010",
            "cartridge contains trailing bytes".to_owned(),
        ));
    }
    let manifest_bytes = entries.get("manifest.json").ok_or_else(|| {
        cartridge_error("PX4012", "cartridge has no canonical manifest".to_owned())
    })?;
    let manifest: PackedManifest = serde_json::from_slice(manifest_bytes).map_err(|error| {
        cartridge_error("PX4012", format!("packed manifest is invalid: {error}"))
    })?;
    if serde_json::to_vec(&manifest).ok().as_deref() != Some(manifest_bytes) {
        return Err(cartridge_error(
            "PX4012",
            "packed manifest is not canonical JSON".to_owned(),
        ));
    }
    validate_packed_manifest(&manifest, &entries)?;
    Ok(DecodedCartridge { manifest, entries })
}

fn validate_manifest(manifest: &ProjectManifest) -> Result<(), CartridgeError> {
    if manifest.format_revision != CARTRIDGE_FORMAT_REVISION {
        return Err(cartridge_error(
            "PX4006",
            format!(
                "cart.toml requests format revision {}; expected {CARTRIDGE_FORMAT_REVISION}",
                manifest.format_revision
            ),
        ));
    }
    if manifest.language_revision != LANGUAGE_REVISION {
        return Err(cartridge_error(
            "PX4006",
            format!(
                "cart.toml requests language '{}'; expected '{LANGUAGE_REVISION}'",
                manifest.language_revision
            ),
        ));
    }
    if !valid_cartridge_id(&manifest.id) {
        return Err(cartridge_error(
            "PX4006",
            "cartridge id must be 3-64 lowercase ASCII letters, digits, dots, or hyphens"
                .to_owned(),
        ));
    }
    if manifest.title.is_empty()
        || manifest.title.len() > 64
        || manifest.author.is_empty()
        || manifest.author.len() > 64
        || manifest.version.is_empty()
        || manifest.version.len() > 32
    {
        return Err(cartridge_error(
            "PX4006",
            "title, author, or version is empty or too long".to_owned(),
        ));
    }
    if manifest.update_rate != 30 && manifest.update_rate != 60 {
        return Err(cartridge_error(
            "PX4006",
            "update_rate must be 30 or 60".to_owned(),
        ));
    }
    let entry = normalize_project_path(&manifest.entry)?;
    if !has_pxl_extension(&entry) {
        return Err(cartridge_error(
            "PX4006",
            "entry must name a .pxl source file".to_owned(),
        ));
    }
    for (name, asset) in &manifest.assets {
        if !valid_identifier(name) {
            return Err(cartridge_error(
                "PX4006",
                format!("asset name '{name}' is not a PXCL identifier"),
            ));
        }
        normalize_project_path(&asset.path)?;
    }
    if let Some(path) = &manifest.label {
        normalize_project_path(path)?;
    }
    if let Some(path) = &manifest.thumbnail {
        normalize_project_path(path)?;
    }
    Ok(())
}

fn validate_packed_manifest(
    manifest: &PackedManifest,
    entries: &BTreeMap<String, Vec<u8>>,
) -> Result<(), CartridgeError> {
    if manifest.format_revision != CARTRIDGE_FORMAT_REVISION
        || manifest.language_revision != LANGUAGE_REVISION
    {
        return Err(cartridge_error(
            "PX4012",
            "packed manifest requests an unsupported revision".to_owned(),
        ));
    }
    let actual_files: BTreeMap<_, _> = entries
        .iter()
        .filter(|(path, _)| path.as_str() != "manifest.json")
        .map(|(path, bytes)| {
            (
                path.clone(),
                FileIntegrity {
                    bytes: u32::try_from(bytes.len()).unwrap_or(u32::MAX),
                    sha256: sha256_hex(bytes),
                },
            )
        })
        .collect();
    if actual_files != manifest.files {
        return Err(cartridge_error(
            "PX4012",
            "packed manifest file inventory does not match the archive".to_owned(),
        ));
    }
    if !entries.contains_key(&manifest.entry)
        || !entries.contains_key("build/cartridge.js")
        || !entries.contains_key("build/cartridge.js.map")
    {
        return Err(cartridge_error(
            "PX4012",
            "packed manifest is missing source or build entry points".to_owned(),
        ));
    }
    for asset in manifest.assets.values() {
        if !entries.contains_key(&asset.path) {
            return Err(cartridge_error(
                "PX4012",
                format!("packed asset path '{}' is missing", asset.path),
            ));
        }
    }
    for path in [manifest.label.as_ref(), manifest.thumbnail.as_ref()]
        .into_iter()
        .flatten()
    {
        if !entries.contains_key(path) {
            return Err(cartridge_error(
                "PX4012",
                format!("presentation path '{path}' is missing"),
            ));
        }
    }
    Ok(())
}

fn include_presentation_file(
    entries: &mut BTreeMap<String, Vec<u8>>,
    project_files: &BTreeMap<String, Vec<u8>>,
    path: Option<&str>,
    role: &str,
) -> Result<Option<String>, CartridgeError> {
    let Some(path) = path else {
        return Ok(None);
    };
    let project_path = normalize_project_path(path)?;
    let bytes = project_files.get(&project_path).ok_or_else(|| {
        cartridge_error("PX4002", format!("{role} file '{project_path}' is missing"))
    })?;
    let archive_path = format!("label/{role}/{project_path}");
    insert_unique(entries, archive_path.clone(), bytes.clone())?;
    Ok(Some(archive_path))
}

fn insert_unique(
    entries: &mut BTreeMap<String, Vec<u8>>,
    path: String,
    bytes: Vec<u8>,
) -> Result<(), CartridgeError> {
    if entries.contains_key(&path) {
        return Err(cartridge_error(
            "PX4007",
            format!("two project files map to archive path '{path}'"),
        ));
    }
    entries.insert(path, bytes);
    Ok(())
}

fn encode_archive(entries: &BTreeMap<String, Vec<u8>>) -> Result<Vec<u8>, CartridgeError> {
    if entries.is_empty() || entries.len() > MAX_ARCHIVE_ENTRIES {
        return Err(cartridge_error(
            "PX4005",
            "archive entry count is outside format limits".to_owned(),
        ));
    }
    let mut output = Vec::new();
    output.extend_from_slice(MAGIC);
    output.extend_from_slice(
        &u32::try_from(entries.len())
            .map_err(|_| cartridge_error("PX4005", "too many archive entries".to_owned()))?
            .to_le_bytes(),
    );
    for (path, raw) in entries {
        let path = normalize_archive_path(path)?;
        let path_bytes = path.as_bytes();
        let encoded = rle_encode(raw);
        output.extend_from_slice(
            &u16::try_from(path_bytes.len())
                .map_err(|_| cartridge_error("PX4005", "archive path is too long".to_owned()))?
                .to_le_bytes(),
        );
        output.extend_from_slice(
            &u32::try_from(raw.len())
                .map_err(|_| cartridge_error("PX4005", "archive entry is too large".to_owned()))?
                .to_le_bytes(),
        );
        output.extend_from_slice(
            &u32::try_from(encoded.len())
                .map_err(|_| cartridge_error("PX4005", "compressed entry is too large".to_owned()))?
                .to_le_bytes(),
        );
        output.extend_from_slice(&sha256(raw));
        output.extend_from_slice(path_bytes);
        output.extend_from_slice(&encoded);
        if output.len() > CARTRIDGE_CAPACITY_BYTES {
            return Err(cartridge_error(
                "PX4005",
                "packed cartridge exceeds the 256 KiB capacity".to_owned(),
            ));
        }
    }
    Ok(output)
}

fn rle_encode(input: &[u8]) -> Vec<u8> {
    let mut output = Vec::with_capacity(input.len());
    let mut cursor = 0;
    while cursor < input.len() {
        let run = repeated_length(input, cursor);
        if run >= 4 {
            output.push(0x80 | u8::try_from(run - 1).expect("run is capped to 128"));
            output.push(input[cursor]);
            cursor += run;
            continue;
        }
        let literal_start = cursor;
        cursor += run;
        while cursor < input.len() && cursor - literal_start < 128 {
            let next_run = repeated_length(input, cursor);
            if next_run >= 4 || cursor - literal_start + next_run > 128 {
                break;
            }
            cursor += next_run;
        }
        let length = cursor - literal_start;
        output.push(u8::try_from(length - 1).expect("literal is capped to 128"));
        output.extend_from_slice(&input[literal_start..cursor]);
    }
    output
}

fn rle_decode(input: &[u8], expected_length: usize) -> Result<Vec<u8>, CartridgeError> {
    let mut output = Vec::with_capacity(expected_length.min(MAX_UNPACKED_BYTES));
    let mut cursor = 0;
    while cursor < input.len() {
        let tag = input[cursor];
        cursor += 1;
        let length = usize::from(tag & 0x7f) + 1;
        if output.len().saturating_add(length) > expected_length {
            return Err(cartridge_error(
                "PX4010",
                "compressed entry expands past its declared size".to_owned(),
            ));
        }
        if tag & 0x80 == 0 {
            let end = cursor.checked_add(length).ok_or_else(|| {
                cartridge_error("PX4010", "compressed literal overflow".to_owned())
            })?;
            let literal = input.get(cursor..end).ok_or_else(|| {
                cartridge_error("PX4010", "truncated compressed literal".to_owned())
            })?;
            output.extend_from_slice(literal);
            cursor = end;
        } else {
            let byte = *input
                .get(cursor)
                .ok_or_else(|| cartridge_error("PX4010", "truncated compressed run".to_owned()))?;
            cursor += 1;
            output.resize(output.len() + length, byte);
        }
    }
    if output.len() != expected_length {
        return Err(cartridge_error(
            "PX4010",
            "compressed entry size does not match its declaration".to_owned(),
        ));
    }
    Ok(output)
}

fn repeated_length(input: &[u8], start: usize) -> usize {
    let byte = input[start];
    let mut end = start + 1;
    while end < input.len() && end - start < 128 && input[end] == byte {
        end += 1;
    }
    end - start
}

fn normalize_project_path(path: &str) -> Result<String, CartridgeError> {
    normalize_path(path, "PX4006")
}

fn normalize_archive_path(path: &str) -> Result<String, CartridgeError> {
    normalize_path(path, "PX4010")
}

fn normalize_path(path: &str, code: &'static str) -> Result<String, CartridgeError> {
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
        return Err(cartridge_error(
            code,
            format!("path '{path}' is not a canonical relative ASCII path"),
        ));
    }
    Ok(path.to_owned())
}

fn normalized_source(bytes: &[u8], path: &str) -> Result<String, CartridgeError> {
    let text = std::str::from_utf8(bytes)
        .map_err(|_| cartridge_error("PX4002", format!("source '{path}' is not valid UTF-8")))?;
    Ok(text.replace("\r\n", "\n").replace('\r', "\n"))
}

fn valid_cartridge_id(value: &str) -> bool {
    (3..=64).contains(&value.len())
        && value.is_ascii()
        && value.bytes().enumerate().all(|(index, byte)| {
            byte.is_ascii_lowercase()
                || byte.is_ascii_digit()
                || (index > 0 && matches!(byte, b'.' | b'-'))
        })
}

fn valid_identifier(value: &str) -> bool {
    let mut bytes = value.bytes();
    bytes
        .next()
        .is_some_and(|byte| byte.is_ascii_alphabetic() || byte == b'_')
        && bytes.all(|byte| byte.is_ascii_alphanumeric() || byte == b'_')
}

fn has_pxl_extension(path: &str) -> bool {
    Path::new(path)
        .extension()
        .is_some_and(|extension| extension == "pxl")
}

fn cartridge_error(code: &'static str, message: String) -> CartridgeError {
    CartridgeError { code, message }
}

fn sha256_hex(input: &[u8]) -> String {
    let mut output = String::with_capacity(64);
    for byte in sha256(input) {
        write!(&mut output, "{byte:02x}").expect("writing to a String cannot fail");
    }
    output
}

#[allow(clippy::many_single_char_names)]
fn sha256(input: &[u8]) -> [u8; 32] {
    let bit_length = u64::try_from(input.len())
        .unwrap_or(u64::MAX)
        .wrapping_mul(8);
    let mut padded = input.to_vec();
    padded.push(0x80);
    while padded.len() % 64 != 56 {
        padded.push(0);
    }
    padded.extend_from_slice(&bit_length.to_be_bytes());
    let mut hash = SHA256_INITIAL;
    for block in padded.as_chunks::<64>().0 {
        let mut words = [0_u32; 64];
        for (index, chunk) in block.as_chunks::<4>().0.iter().enumerate() {
            words[index] = u32::from_be_bytes(*chunk);
        }
        for index in 16..64 {
            let first = words[index - 15].rotate_right(7)
                ^ words[index - 15].rotate_right(18)
                ^ (words[index - 15] >> 3);
            let second = words[index - 2].rotate_right(17)
                ^ words[index - 2].rotate_right(19)
                ^ (words[index - 2] >> 10);
            words[index] = words[index - 16]
                .wrapping_add(first)
                .wrapping_add(words[index - 7])
                .wrapping_add(second);
        }
        let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut h] = hash;
        for index in 0..64 {
            let sigma1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let choice = (e & f) ^ (!e & g);
            let temporary1 = h
                .wrapping_add(sigma1)
                .wrapping_add(choice)
                .wrapping_add(SHA256_ROUND[index])
                .wrapping_add(words[index]);
            let sigma0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let majority = (a & b) ^ (a & c) ^ (b & c);
            let temporary2 = sigma0.wrapping_add(majority);
            h = g;
            g = f;
            f = e;
            e = d.wrapping_add(temporary1);
            d = c;
            c = b;
            b = a;
            a = temporary1.wrapping_add(temporary2);
        }
        for (slot, value) in hash.iter_mut().zip([a, b, c, d, e, f, g, h]) {
            *slot = slot.wrapping_add(value);
        }
    }
    let mut output = [0_u8; 32];
    for (index, word) in hash.into_iter().enumerate() {
        output[index * 4..index * 4 + 4].copy_from_slice(&word.to_be_bytes());
    }
    output
}

struct Reader<'a> {
    bytes: &'a [u8],
    cursor: usize,
}

impl<'a> Reader<'a> {
    const fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, cursor: 0 }
    }

    fn take(&mut self, length: usize) -> Result<&'a [u8], CartridgeError> {
        let end = self
            .cursor
            .checked_add(length)
            .ok_or_else(|| cartridge_error("PX4010", "cartridge offset overflow".to_owned()))?;
        let result = self
            .bytes
            .get(self.cursor..end)
            .ok_or_else(|| cartridge_error("PX4010", "cartridge is truncated".to_owned()))?;
        self.cursor = end;
        Ok(result)
    }

    fn u16(&mut self) -> Result<u16, CartridgeError> {
        Ok(u16::from_le_bytes(self.take(2)?.try_into().map_err(
            |_| cartridge_error("PX4010", "invalid 16-bit field".to_owned()),
        )?))
    }

    fn u32(&mut self) -> Result<u32, CartridgeError> {
        Ok(u32::from_le_bytes(self.take(4)?.try_into().map_err(
            |_| cartridge_error("PX4010", "invalid 32-bit field".to_owned()),
        )?))
    }

    const fn finished(&self) -> bool {
        self.cursor == self.bytes.len()
    }
}

#[cfg(test)]
mod tests {
    use super::{
        CARTRIDGE_CAPACITY_BYTES, compile_project, decode_cartridge, pack_project, rle_decode,
        rle_encode, sha256_hex,
    };
    use crate::CompileMode;
    use std::collections::BTreeMap;

    fn manifest() -> &'static str {
        r#"format = 1
language = "PXCL/1"
id = "test.game"
title = "Test Game"
author = "@gongahkia"
version = "1.0.0"
entry = "src/main.pxl"
update_rate = 60

[assets.hero]
kind = "sprite"
path = "assets/hero.pxg"
"#
    }

    fn files(line_ending: &str) -> BTreeMap<String, Vec<u8>> {
        BTreeMap::from([
            (
                "src/main.pxl".to_owned(),
                format!("on draw:{line_ending}  clear(0){line_ending}").into_bytes(),
            ),
            ("assets/hero.pxg".to_owned(), vec![0, 1, 1, 1, 0]),
        ])
    }

    #[test]
    fn hashes_the_standard_sha256_vector() {
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn rle_round_trips_runs_and_literal_boundaries() {
        let input: Vec<_> = (0_u16..600)
            .map(|value| u8::try_from((value / 5) % 251).expect("bounded"))
            .collect();
        let encoded = rle_encode(&input);
        assert_eq!(rle_decode(&encoded, input.len()).expect("decode"), input);
        assert!(rle_decode(&encoded, input.len() - 1).is_err());
    }

    #[test]
    fn packing_is_byte_identical_and_normalizes_source_line_endings() {
        let first = pack_project(manifest(), &files("\n")).expect("pack LF");
        let second = pack_project(manifest(), &files("\r\n")).expect("pack CRLF");
        assert_eq!(first.bytes, second.bytes);
        assert!(first.bytes.len() < CARTRIDGE_CAPACITY_BYTES);
        let decoded = decode_cartridge(&first.bytes).expect("decode");
        assert_eq!(decoded.manifest.title, "Test Game");
        assert_eq!(
            decoded.entries.get("source/src/main.pxl"),
            Some(&b"on draw:\n  clear(0)\n".to_vec())
        );
        assert!(decoded.entries.contains_key("build/cartridge.js"));
        assert!(decoded.entries.contains_key("assets/assets/hero.pxg"));
    }

    #[test]
    fn project_imports_link_through_the_typed_pipeline() {
        let mut project_files = files("\n");
        project_files.insert(
            "src/main.pxl".to_owned(),
            b"import src.math as math\nstate score: Int = 1\non update:\n  score = math.twice(score)\n"
                .to_vec(),
        );
        project_files.insert(
            "src/math.pxl".to_owned(),
            b"fn twice(value: Int) -> Int:\n  return value * 2\n".to_vec(),
        );
        let output = compile_project(manifest(), &project_files, CompileMode::Release)
            .expect("project links");
        assert!(output.analysis.diagnostics.is_empty());
        assert!(
            !output
                .generated
                .expect("project generates")
                .javascript
                .is_empty()
        );
        assert!(pack_project(manifest(), &project_files).is_ok());
    }

    #[test]
    fn decoding_rejects_mutation_truncation_and_trailing_bytes() {
        let packed = pack_project(manifest(), &files("\n")).expect("pack");
        let mut mutated = packed.bytes.clone();
        let last = mutated.len() - 1;
        mutated[last] ^= 1;
        assert!(decode_cartridge(&mutated).is_err());
        assert!(decode_cartridge(&packed.bytes[..packed.bytes.len() - 1]).is_err());
        let mut trailing = packed.bytes;
        trailing.push(0);
        assert!(decode_cartridge(&trailing).is_err());
    }

    #[test]
    fn bounded_arbitrary_inputs_never_panic() {
        let mut state = 0x240c_1999_u64;
        for length in 0..512 {
            let mut input = vec![0_u8; length];
            for byte in &mut input {
                state ^= state << 13;
                state ^= state >> 7;
                state ^= state << 17;
                *byte = state.to_le_bytes()[0];
            }
            let _ = decode_cartridge(&input);
        }
    }
}
