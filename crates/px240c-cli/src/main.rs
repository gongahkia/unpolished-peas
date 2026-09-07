use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
    process::ExitCode,
};

use clap::{Parser, Subcommand};
use pxcl_core::{
    AssetCatalog, CompileMode, Diagnostic, FileId, ProjectManifest, SourceFile, analyze_module,
    compile, decode_cartridge, format_source, pack_project, parse_project_manifest,
};

#[derive(Debug, Parser)]
#[command(
    name = "px240c",
    version,
    about = "PX-240C Color Development Unit toolchain",
    subcommand_required = true,
    arg_required_else_help = true
)]
struct Arguments {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug)]
struct LoadedProject {
    manifest_source: String,
    manifest: ProjectManifest,
    files: BTreeMap<String, Vec<u8>>,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Create a new Git-friendly cartridge project without overwriting an existing path.
    New {
        path: PathBuf,
        #[arg(long)]
        title: Option<String>,
        #[arg(long, default_value = "@gongahkia")]
        author: String,
    },
    /// Compile one PXCL/1 source module to JavaScript and a source map.
    Build {
        path: PathBuf,
        /// Emit debug probes and suspendable source-debug metadata.
        #[arg(long)]
        debug: bool,
        /// Generated JavaScript path. Defaults to the input path with a `.js` extension.
        #[arg(short, long)]
        output: Option<PathBuf>,
    },
    /// Check PXCL/1 source modules without producing output.
    Check { paths: Vec<PathBuf> },
    /// Format PXCL/1 source modules in place.
    Fmt {
        /// Report files that differ without writing them.
        #[arg(long)]
        check: bool,
        paths: Vec<PathBuf>,
    },
    /// Pack a project directory into one deterministic `.pxc` artifact.
    Pack {
        #[arg(default_value = ".")]
        path: PathBuf,
        #[arg(short, long)]
        output: Option<PathBuf>,
    },
    /// Print toolchain revisions, a project manifest, or packed-cartridge metadata.
    Info { path: Option<PathBuf> },
}

fn main() -> ExitCode {
    match Arguments::parse().command {
        Command::New {
            path,
            title,
            author,
        } => new_project(&path, title.as_deref(), &author),
        Command::Build {
            path,
            debug,
            output,
        } => build_file(&path, output.as_deref(), debug),
        Command::Check { paths } => check_files(&paths),
        Command::Fmt { check, paths } => format_files(&paths, check),
        Command::Pack { path, output } => pack_directory(&path, output.as_deref()),
        Command::Info { path } => info(path.as_deref()),
    }
}

fn new_project(path: &Path, title: Option<&str>, author: &str) -> ExitCode {
    if path.exists() {
        eprintln!("{}: refusing to overwrite an existing path", path.display());
        return ExitCode::FAILURE;
    }
    let id = project_id(path);
    let title = title.map_or_else(|| project_title(&id), ToOwned::to_owned);
    let source_directory = path.join("src");
    if let Err(error) = fs::create_dir_all(&source_directory) {
        eprintln!("{}: {error}", source_directory.display());
        return ExitCode::FAILURE;
    }
    let manifest = format!(
        "format = 1\nlanguage = \"PXCL/1\"\nid = \"{id}\"\ntitle = {}\nauthor = {}\nversion = \"0.1.0\"\nentry = \"src/main.pxl\"\nupdate_rate = 60\n\n[assets]\n",
        toml_string(&title),
        toml_string(author)
    );
    let source =
        "// Made by @gongahkia\n\non draw:\n  clear(0)\n  print(\"HELLO, PX-240C\", 72, 68, 7)\n";
    for (target, contents) in [
        (path.join("cart.toml"), manifest.as_bytes()),
        (source_directory.join("main.pxl"), source.as_bytes()),
    ] {
        if let Err(error) = fs::write(&target, contents) {
            eprintln!("{}: {error}", target.display());
            return ExitCode::FAILURE;
        }
    }
    println!("created {}", path.display());
    ExitCode::SUCCESS
}

fn pack_directory(path: &Path, output: Option<&Path>) -> ExitCode {
    let Ok(project) = load_project(path) else {
        return ExitCode::FAILURE;
    };
    let packed = match pack_project(&project.manifest_source, &project.files) {
        Ok(packed) => packed,
        Err(error) => {
            eprintln!("{}: {error}", path.display());
            return ExitCode::FAILURE;
        }
    };
    if let Err(error) = decode_cartridge(&packed.bytes) {
        eprintln!("{}: post-pack validation failed: {error}", path.display());
        return ExitCode::FAILURE;
    }
    let output = output.map_or_else(
        || {
            path.join("dist")
                .join(format!("{}.pxc", project.manifest.id))
        },
        Path::to_path_buf,
    );
    if let Some(parent) = output.parent()
        && let Err(error) = fs::create_dir_all(parent)
    {
        eprintln!("{}: {error}", parent.display());
        return ExitCode::FAILURE;
    }
    if let Err(error) = fs::write(&output, &packed.bytes) {
        eprintln!("{}: {error}", output.display());
        return ExitCode::FAILURE;
    }
    println!(
        "packed {} ({} bytes, {} files)",
        output.display(),
        packed.bytes.len(),
        packed.manifest.files.len()
    );
    ExitCode::SUCCESS
}

fn info(path: Option<&Path>) -> ExitCode {
    let Some(path) = path else {
        println!(
            "{} cartridge-format/{} compiler/{}",
            pxcl_core::LANGUAGE_REVISION,
            pxcl_core::CARTRIDGE_FORMAT_REVISION,
            pxcl_core::compiler_version()
        );
        return ExitCode::SUCCESS;
    };
    let metadata = if path.extension().is_some_and(|extension| extension == "pxc") {
        fs::read(path)
            .map_err(|error| error.to_string())
            .and_then(|bytes| decode_cartridge(&bytes).map_err(|error| error.to_string()))
            .and_then(|cartridge| {
                serde_json::to_string_pretty(&cartridge.manifest).map_err(|error| error.to_string())
            })
    } else {
        let manifest_path = if path.is_dir() {
            path.join("cart.toml")
        } else {
            path.to_path_buf()
        };
        fs::read_to_string(&manifest_path)
            .map_err(|error| error.to_string())
            .and_then(|source| parse_project_manifest(&source).map_err(|error| error.to_string()))
            .and_then(|manifest| {
                serde_json::to_string_pretty(&manifest).map_err(|error| error.to_string())
            })
    };
    match metadata {
        Ok(metadata) => {
            println!("{metadata}");
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("{}: {error}", path.display());
            ExitCode::FAILURE
        }
    }
}

fn load_project(path: &Path) -> Result<LoadedProject, ()> {
    if !path.is_dir() {
        eprintln!("{}: expected a cartridge project directory", path.display());
        return Err(());
    }
    let manifest_path = path.join("cart.toml");
    let manifest_source = fs::read_to_string(&manifest_path).map_err(|error| {
        eprintln!("{}: {error}", manifest_path.display());
    })?;
    let manifest = parse_project_manifest(&manifest_source).map_err(|error| {
        eprintln!("{}: {error}", manifest_path.display());
    })?;
    let mut files = BTreeMap::new();
    collect_sources(path, path, &mut files)?;
    let required_paths = manifest
        .assets
        .values()
        .map(|asset| asset.path.as_str())
        .chain(manifest.label.as_deref())
        .chain(manifest.thumbnail.as_deref());
    for relative in required_paths {
        if files.contains_key(relative) {
            continue;
        }
        let target = path.join(relative);
        let bytes = fs::read(&target).map_err(|error| {
            eprintln!("{}: {error}", target.display());
        })?;
        files.insert(relative.to_owned(), bytes);
    }
    Ok(LoadedProject {
        manifest_source,
        manifest,
        files,
    })
}

fn collect_sources(
    root: &Path,
    directory: &Path,
    files: &mut BTreeMap<String, Vec<u8>>,
) -> Result<(), ()> {
    let entries = fs::read_dir(directory).map_err(|error| {
        eprintln!("{}: {error}", directory.display());
    })?;
    for entry in entries {
        let entry = entry.map_err(|error| {
            eprintln!("{}: {error}", directory.display());
        })?;
        let file_type = entry.file_type().map_err(|error| {
            eprintln!("{}: {error}", entry.path().display());
        })?;
        if file_type.is_symlink() {
            continue;
        }
        if file_type.is_dir() {
            let name = entry.file_name();
            if !matches!(
                name.to_str(),
                Some(".git" | "dist" | "node_modules" | "target")
            ) {
                collect_sources(root, &entry.path(), files)?;
            }
            continue;
        }
        let target = entry.path();
        if target
            .extension()
            .is_none_or(|extension| extension != "pxl")
        {
            continue;
        }
        let relative = target.strip_prefix(root).map_err(|error| {
            eprintln!("{}: {error}", target.display());
        })?;
        let Some(relative) = relative.to_str() else {
            eprintln!("{}: source path is not valid UTF-8", target.display());
            return Err(());
        };
        let bytes = fs::read(&target).map_err(|error| {
            eprintln!("{}: {error}", target.display());
        })?;
        files.insert(relative.to_owned(), bytes);
    }
    Ok(())
}

fn project_id(path: &Path) -> String {
    let raw = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("game");
    let mut id = String::new();
    let mut separator = false;
    for byte in raw.bytes() {
        if byte.is_ascii_alphanumeric() {
            id.push(char::from(byte.to_ascii_lowercase()));
            separator = false;
        } else if !separator && !id.is_empty() {
            id.push('-');
            separator = true;
        }
    }
    while id.ends_with('-') {
        id.pop();
    }
    if id.len() < 3 {
        format!("game-{id}")
    } else {
        id
    }
}

fn project_title(id: &str) -> String {
    id.split('-')
        .filter(|part| !part.is_empty())
        .map(str::to_ascii_uppercase)
        .collect::<Vec<_>>()
        .join(" ")
}

fn toml_string(value: &str) -> String {
    serde_json::to_string(value).expect("Rust strings always serialize")
}

fn build_file(path: &Path, output: Option<&Path>, debug: bool) -> ExitCode {
    let Ok(text) = read_source(path) else {
        return ExitCode::FAILURE;
    };
    let source = SourceFile::new(FileId(0), path.display().to_string(), text);
    let compilation = compile(
        &source,
        &AssetCatalog::default(),
        if debug {
            CompileMode::Debug
        } else {
            CompileMode::Release
        },
    );
    if !compilation.analysis.diagnostics.is_empty() {
        emit_diagnostics(path, &source, &compilation.analysis.diagnostics);
        return ExitCode::FAILURE;
    }
    let Some(generated) = compilation.generated else {
        eprintln!("{}: compiler produced no output", path.display());
        return ExitCode::FAILURE;
    };
    let output = output.map_or_else(|| path.with_extension("js"), Path::to_path_buf);
    let source_map = output.with_extension("js.map");
    if let Some(parent) = output.parent()
        && let Err(error) = fs::create_dir_all(parent)
    {
        eprintln!("{}: {error}", parent.display());
        return ExitCode::FAILURE;
    }
    let Some(source_map_name) = source_map.file_name().and_then(|name| name.to_str()) else {
        eprintln!(
            "{}: output source-map name is not valid UTF-8",
            source_map.display()
        );
        return ExitCode::FAILURE;
    };
    let javascript = format!(
        "{}//# sourceMappingURL={}\n",
        generated.javascript, source_map_name
    );
    if let Err(error) = fs::write(&output, javascript) {
        eprintln!("{}: {error}", output.display());
        return ExitCode::FAILURE;
    }
    if let Err(error) = fs::write(&source_map, generated.source_map_json) {
        eprintln!("{}: {error}", source_map.display());
        return ExitCode::FAILURE;
    }
    println!(
        "built {} ({} bytes, {:?})",
        output.display(),
        generated.generated_bytes,
        generated.mode
    );
    ExitCode::SUCCESS
}

fn check_files(paths: &[PathBuf]) -> ExitCode {
    if paths.is_empty() {
        eprintln!("px240c check: expected at least one .pxl source path");
        return ExitCode::from(2);
    }
    let mut failed = false;
    for (index, path) in paths.iter().enumerate() {
        let Ok(text) = read_source(path) else {
            failed = true;
            continue;
        };
        let source = SourceFile::new(file_id(index), path.display().to_string(), text);
        let output = analyze_module(&source, &AssetCatalog::default());
        if !output.diagnostics.is_empty() {
            emit_diagnostics(path, &source, &output.diagnostics);
            failed = true;
        }
    }
    status(failed)
}

fn format_files(paths: &[PathBuf], check: bool) -> ExitCode {
    if paths.is_empty() {
        eprintln!("px240c fmt: expected at least one .pxl source path");
        return ExitCode::from(2);
    }
    let mut failed = false;
    for (index, path) in paths.iter().enumerate() {
        let Ok(text) = read_source(path) else {
            failed = true;
            continue;
        };
        let source = SourceFile::new(file_id(index), path.display().to_string(), text.clone());
        match format_source(&source) {
            Ok(formatted) if formatted == text => {}
            Ok(_) if check => {
                eprintln!("{}: requires formatting", path.display());
                failed = true;
            }
            Ok(formatted) => {
                if let Err(error) = fs::write(path, formatted) {
                    eprintln!("{}: {error}", path.display());
                    failed = true;
                }
            }
            Err(error) => {
                emit_diagnostics(path, &source, &error.diagnostics);
                failed = true;
            }
        }
    }
    status(failed)
}

fn read_source(path: &Path) -> Result<String, ()> {
    fs::read_to_string(path).map_err(|error| {
        eprintln!("{}: {error}", path.display());
    })
}

fn emit_diagnostics(path: &Path, source: &SourceFile, diagnostics: &[Diagnostic]) {
    for diagnostic in diagnostics {
        let position = source.line_column(diagnostic.primary.span.start);
        eprintln!(
            "{}:{}:{}: error[{}]: {}",
            path.display(),
            position.line + 1,
            position.column + 1,
            diagnostic.code,
            diagnostic.message
        );
        if !diagnostic.primary.message.is_empty() {
            eprintln!("  {}", diagnostic.primary.message);
        }
        for note in &diagnostic.notes {
            eprintln!("  note: {note}");
        }
    }
}

fn file_id(index: usize) -> FileId {
    FileId(u32::try_from(index).unwrap_or(u32::MAX))
}

const fn status(failed: bool) -> ExitCode {
    if failed {
        ExitCode::FAILURE
    } else {
        ExitCode::SUCCESS
    }
}
