use std::{
    collections::BTreeMap,
    fs,
    hash::{DefaultHasher, Hash, Hasher},
    io::{Read as _, Write as _},
    net::{TcpListener, TcpStream},
    path::{Path, PathBuf},
    process::{Command as ProcessCommand, ExitCode, Stdio},
    thread,
    time::Duration,
};

use clap::{Parser, Subcommand};
use pxcl_core::{
    AssetCatalog, CartridgePngMetadata, CompileMode, Diagnostic, FileId, GeneratedProgram,
    ProjectManifest, SourceFile, analyze_module, compile, compile_project, decode_cartridge,
    decode_cartridge_png, encode_cartridge_png, export_standalone_html, format_source,
    pack_project, parse_project_manifest, unpack_cartridge_project,
};

const HEADLESS_HOST: &str = include_str!("../../../packages/runtime/standalone/headless-host.mjs");
const MAX_TRACE_BYTES: u64 = 8 * 1024 * 1024;

mod lsp;

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
    /// Run ordinary PXCL tests, expected compiler failures, and scripted frame snapshots.
    Test {
        #[arg(default_value = ".")]
        path: PathBuf,
    },
    /// Export a project in a redistributable format.
    Export {
        #[command(subcommand)]
        command: ExportCommand,
    },
    /// Export and open a project in the system browser.
    Run {
        #[arg(default_value = ".")]
        path: PathBuf,
        #[arg(short, long)]
        output: Option<PathBuf>,
        /// Write and validate the player without opening a browser.
        #[arg(long)]
        no_open: bool,
        /// Execute deterministically without a browser and emit a revisioned JSON trace.
        #[arg(long)]
        headless: bool,
        /// Number of display frames for a headless run.
        #[arg(long, default_value_t = 60)]
        frames: u32,
        /// Unsigned 32-bit deterministic seed for a headless run.
        #[arg(long, default_value_t = 604_772_761)]
        seed: u32,
        /// Optional revision-1 scripted controller trace JSON.
        #[arg(long)]
        input: Option<PathBuf>,
        /// Optional raw save image of at most 8 KiB.
        #[arg(long)]
        save: Option<PathBuf>,
    },
    /// Repack a project whenever its files change.
    Watch {
        #[arg(default_value = ".")]
        path: PathBuf,
        #[arg(short, long)]
        output: Option<PathBuf>,
        /// Build once and exit; useful for editor and CI integration checks.
        #[arg(long)]
        once: bool,
        /// Serve the refreshing player without opening the system browser.
        #[arg(long)]
        no_open: bool,
    },
    /// Print toolchain revisions, a project manifest, or packed-cartridge metadata.
    Info { path: Option<PathBuf> },
    /// Run the PXCL/1 language server over standard input/output.
    Lsp,
}

#[derive(Debug, Subcommand)]
enum ExportCommand {
    /// Export one offline, source-inspectable standalone HTML player.
    Html {
        #[arg(default_value = ".")]
        path: PathBuf,
        #[arg(short, long)]
        output: Option<PathBuf>,
    },
    /// Export a PX-240C cartridge-object PNG containing the complete canonical `.pxc`.
    Png {
        #[arg(default_value = ".")]
        path: PathBuf,
        #[arg(short, long)]
        output: Option<PathBuf>,
    },
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
        Command::Test { path } => test_directory(&path),
        Command::Export {
            command: ExportCommand::Html { path, output },
        } => export_html_directory(&path, output.as_deref())
            .map_or(ExitCode::FAILURE, |_| ExitCode::SUCCESS),
        Command::Export {
            command: ExportCommand::Png { path, output },
        } => export_png_directory(&path, output.as_deref())
            .map_or(ExitCode::FAILURE, |_| ExitCode::SUCCESS),
        Command::Run {
            path,
            output,
            no_open,
            headless,
            frames,
            seed,
            input,
            save,
        } => {
            if headless {
                run_headless(
                    &path,
                    output.as_deref(),
                    frames,
                    seed,
                    input.as_deref(),
                    save.as_deref(),
                )
            } else {
                run_directory(&path, output.as_deref(), no_open)
            }
        }
        Command::Watch {
            path,
            output,
            once,
            no_open,
        } => watch_directory(&path, output.as_deref(), once, no_open),
        Command::Info { path } => info(path.as_deref()),
        Command::Lsp => lsp::run(),
    }
}

fn export_html_directory(path: &Path, output: Option<&Path>) -> Result<PathBuf, ()> {
    let project = load_project(path)?;
    let html =
        export_standalone_html(&project.manifest_source, &project.files).map_err(|error| {
            eprintln!("{}: {error}", path.display());
        })?;
    let output = output.map_or_else(
        || {
            path.join("dist")
                .join(format!("{}.html", project.manifest.id))
        },
        Path::to_path_buf,
    );
    if let Some(parent) = output.parent() {
        fs::create_dir_all(parent).map_err(|error| {
            eprintln!("{}: {error}", parent.display());
        })?;
    }
    fs::write(&output, html.as_bytes()).map_err(|error| {
        eprintln!("{}: {error}", output.display());
    })?;
    println!("exported {} ({} bytes)", output.display(), html.len());
    Ok(output)
}

fn export_png_directory(path: &Path, output: Option<&Path>) -> Result<PathBuf, ()> {
    let project = load_project(path)?;
    let packed = pack_project(&project.manifest_source, &project.files).map_err(|error| {
        eprintln!("{}: {error}", path.display());
    })?;
    let identity = project
        .files
        .get("presentation/cartridge.json")
        .and_then(|bytes| serde_json::from_slice::<serde_json::Value>(bytes).ok());
    let year = identity
        .as_ref()
        .and_then(|value| value.get("year"))
        .and_then(serde_json::Value::as_u64)
        .and_then(|value| u16::try_from(value).ok())
        .filter(|value| (1970..=9999).contains(value))
        .unwrap_or(1999);
    let players = identity
        .as_ref()
        .and_then(|value| value.get("players"))
        .and_then(serde_json::Value::as_u64)
        .and_then(|value| u8::try_from(value).ok())
        .filter(|value| (1..=4).contains(value))
        .unwrap_or(1);
    let controls = identity
        .as_ref()
        .and_then(|value| value.get("controls"))
        .and_then(serde_json::Value::as_str)
        .filter(|value| value.len() <= 64)
        .unwrap_or("PAD")
        .to_owned();
    let metadata = CartridgePngMetadata {
        title: project.manifest.title.clone(),
        author: project.manifest.author.clone(),
        year,
        players,
        controls,
    };
    let png = encode_cartridge_png(&packed.bytes, &metadata).map_err(|error| {
        eprintln!("{}: {error}", path.display());
    })?;
    let output = output.map_or_else(
        || {
            path.join("dist")
                .join(format!("{}.pxc.png", project.manifest.id))
        },
        Path::to_path_buf,
    );
    if let Some(parent) = output.parent() {
        fs::create_dir_all(parent).map_err(|error| eprintln!("{}: {error}", parent.display()))?;
    }
    fs::write(&output, &png).map_err(|error| eprintln!("{}: {error}", output.display()))?;
    println!("exported {} ({} bytes)", output.display(), png.len());
    Ok(output)
}

fn run_directory(path: &Path, output: Option<&Path>, no_open: bool) -> ExitCode {
    let Ok(output) = export_html_directory(path, output) else {
        return ExitCode::FAILURE;
    };
    if no_open {
        return ExitCode::SUCCESS;
    }
    match browser_command(&output.display().to_string()).spawn() {
        Ok(_) => {
            println!("opened {}", output.display());
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!(
                "{}: could not open system browser: {error}",
                output.display()
            );
            ExitCode::FAILURE
        }
    }
}

fn run_headless(
    path: &Path,
    output: Option<&Path>,
    frames: u32,
    seed: u32,
    input: Option<&Path>,
    save: Option<&Path>,
) -> ExitCode {
    let Ok((rom, cartridge)) = load_headless_cartridge(path) else {
        return ExitCode::FAILURE;
    };
    let Some(javascript) = cartridge.entries.get("build/cartridge.js") else {
        eprintln!(
            "{}: canonical cartridge has no compiled program",
            path.display()
        );
        return ExitCode::FAILURE;
    };
    let Ok(javascript) = std::str::from_utf8(javascript) else {
        eprintln!("{}: compiled program is not UTF-8", path.display());
        return ExitCode::FAILURE;
    };
    let Ok(trace) = read_json_input(input) else {
        return ExitCode::FAILURE;
    };
    let Ok(save_bytes) = read_save_image(save) else {
        return ExitCode::FAILURE;
    };
    let manifest = &cartridge.manifest;
    let request = serde_json::json!({
        "revision": 1,
        "javascript": javascript,
        "manifest": {
            "id": manifest.id,
            "updateRate": manifest.update_rate,
            "display": manifest.display,
            "assets": manifest.assets,
        },
        "entries": cartridge.entries,
        "rom": rom,
        "seed": seed,
        "frames": frames,
        "trace": trace,
        "save": save_bytes,
    });
    let Ok(request) = serde_json::to_vec(&request) else {
        eprintln!("{}: could not encode headless request", path.display());
        return ExitCode::FAILURE;
    };
    let Ok(serialized) = execute_headless_host(&request, frames) else {
        return ExitCode::FAILURE;
    };
    if let Some(output) = output {
        if let Some(parent) = output.parent()
            && let Err(error) = fs::create_dir_all(parent)
        {
            eprintln!("{}: {error}", parent.display());
            return ExitCode::FAILURE;
        }
        if let Err(error) = fs::write(output, &serialized) {
            eprintln!("{}: {error}", output.display());
            return ExitCode::FAILURE;
        }
        println!(
            "ran {} headlessly for {frames} frames -> {}",
            path.display(),
            output.display()
        );
    } else {
        println!("{}", String::from_utf8_lossy(&serialized));
    }
    ExitCode::SUCCESS
}

fn execute_headless_host(request: &[u8], frames: u32) -> Result<Vec<u8>, ()> {
    let host_path = std::env::temp_dir().join(format!(
        "px240c-headless-{}-{}.mjs",
        std::process::id(),
        frames
    ));
    if let Err(error) = fs::write(&host_path, HEADLESS_HOST) {
        eprintln!("{}: {error}", host_path.display());
        return Err(());
    }
    let node = std::env::var_os("PX240C_NODE").unwrap_or_else(|| "node".into());
    let child = ProcessCommand::new(node)
        .arg(&host_path)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn();
    let mut child = child.map_err(|error| {
        let _ = fs::remove_file(&host_path);
        eprintln!("could not start the PX-240C Node headless host: {error}");
    })?;
    if let Some(mut stdin) = child.stdin.take()
        && let Err(error) = stdin.write_all(request)
    {
        let _ = child.kill();
        let _ = fs::remove_file(&host_path);
        eprintln!("could not send cartridge to headless host: {error}");
        return Err(());
    }
    let result = child.wait_with_output();
    let _ = fs::remove_file(&host_path);
    let result = match result {
        Ok(result) if result.status.success() => result,
        Ok(result) => {
            eprint!("{}", String::from_utf8_lossy(&result.stderr));
            return Err(());
        }
        Err(error) => {
            eprintln!("headless host did not complete: {error}");
            return Err(());
        }
    };
    let parsed: serde_json::Value = match serde_json::from_slice(&result.stdout) {
        Ok(parsed) => parsed,
        Err(error) => {
            eprintln!("headless host returned invalid JSON: {error}");
            return Err(());
        }
    };
    Ok(serde_json::to_vec_pretty(&parsed).expect("JSON value always serializes"))
}

fn load_headless_cartridge(path: &Path) -> Result<(Vec<u8>, pxcl_core::DecodedCartridge), ()> {
    let packed = if path.is_dir() {
        let project = load_project(path)?;
        pack_project(&project.manifest_source, &project.files).map_err(|error| {
            eprintln!("{}: {error}", path.display());
        })?
    } else if path
        .extension()
        .is_some_and(|extension| extension == "pxc" || extension == "png")
    {
        let file_bytes = fs::read(path).map_err(|error| {
            eprintln!("{}: {error}", path.display());
        })?;
        let bytes = if path.extension().is_some_and(|extension| extension == "png") {
            decode_cartridge_png(&file_bytes)
                .map_err(|error| eprintln!("{}: {error}", path.display()))?
                .cartridge
        } else {
            file_bytes
        };
        let project = unpack_cartridge_project(&bytes).map_err(|error| {
            eprintln!("{}: {error}", path.display());
        })?;
        pack_project(&project.manifest, &project.files).map_err(|error| {
            eprintln!("{}: {error}", path.display());
        })?
    } else {
        eprintln!(
            "{}: expected a project directory, .pxc, or .pxc.png cartridge",
            path.display()
        );
        return Err(());
    };
    let cartridge = decode_cartridge(&packed.bytes).map_err(|error| {
        eprintln!("{}: {error}", path.display());
    })?;
    Ok((packed.bytes, cartridge))
}

fn read_json_input(path: Option<&Path>) -> Result<serde_json::Value, ()> {
    let Some(path) = path else {
        return Ok(serde_json::json!({ "revision": 1, "frames": [] }));
    };
    let metadata = fs::metadata(path).map_err(|error| {
        eprintln!("{}: {error}", path.display());
    })?;
    if metadata.len() > MAX_TRACE_BYTES {
        eprintln!("{}: controller trace exceeds 8 MiB", path.display());
        return Err(());
    }
    let source = fs::read(path).map_err(|error| {
        eprintln!("{}: {error}", path.display());
    })?;
    serde_json::from_slice(&source).map_err(|error| {
        eprintln!("{}: invalid controller trace JSON: {error}", path.display());
    })
}

fn read_save_image(path: Option<&Path>) -> Result<Vec<u8>, ()> {
    let Some(path) = path else {
        return Ok(Vec::new());
    };
    let bytes = fs::read(path).map_err(|error| {
        eprintln!("{}: {error}", path.display());
    })?;
    if bytes.len() > 8 * 1024 {
        eprintln!("{}: save image exceeds 8 KiB", path.display());
        return Err(());
    }
    Ok(bytes)
}

fn test_directory(path: &Path) -> ExitCode {
    let Ok(project) = load_project(path) else {
        return ExitCode::FAILURE;
    };
    let tests_root = path.join("tests");
    let mut test_paths = Vec::new();
    if tests_root.is_dir()
        && let Err(error) = collect_test_paths(&tests_root, &mut test_paths)
    {
        eprintln!("{}: {error}", tests_root.display());
        return ExitCode::FAILURE;
    }
    test_paths.sort();
    let mut passed = 0_usize;
    let mut failed = 0_usize;
    let main_cartridge = test_paths
        .iter()
        .any(|test| {
            test.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.ends_with(".pxrun.json"))
        })
        .then(|| pack_project(&project.manifest_source, &project.files));
    for test_path in &test_paths {
        let result = if test_path
            .extension()
            .is_some_and(|extension| extension == "pxl")
        {
            run_pxcl_test(path, &project, test_path)
        } else if test_path
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name.ends_with(".pxrun.json"))
        {
            match &main_cartridge {
                Some(Ok(cartridge)) => run_scripted_test(path, cartridge, test_path),
                Some(Err(error)) => Err(error.to_string()),
                None => Err("internal test runner error".to_owned()),
            }
        } else {
            continue;
        };
        match result {
            Ok(()) => {
                passed += 1;
                println!("PASS {}", test_path.display());
            }
            Err(error) => {
                failed += 1;
                eprintln!("FAIL {}: {error}", test_path.display());
            }
        }
    }
    println!("test result: {passed} passed; {failed} failed");
    status(failed > 0)
}

fn collect_test_paths(directory: &Path, paths: &mut Vec<PathBuf>) -> Result<(), std::io::Error> {
    for entry in fs::read_dir(directory)? {
        let entry = entry?;
        let file_type = entry.file_type()?;
        if file_type.is_symlink() {
            continue;
        }
        if file_type.is_dir() {
            collect_test_paths(&entry.path(), paths)?;
        } else {
            paths.push(entry.path());
        }
    }
    Ok(())
}

fn run_pxcl_test(root: &Path, project: &LoadedProject, test_path: &Path) -> Result<(), String> {
    let relative = test_path
        .strip_prefix(root)
        .map_err(|error| error.to_string())?
        .to_str()
        .ok_or_else(|| "test path is not valid UTF-8".to_owned())?;
    let source = fs::read_to_string(test_path).map_err(|error| error.to_string())?;
    let compile_fail = test_path
        .file_name()
        .and_then(|name| name.to_str())
        .is_some_and(|name| name.ends_with(".fail.pxl"));
    let expected_code = source.lines().find_map(|line| {
        line.trim()
            .strip_prefix("// expect ")
            .map(str::trim)
            .filter(|code| code.starts_with("PX"))
    });
    let mut manifest = project.manifest.clone();
    relative.clone_into(&mut manifest.entry);
    manifest.assets.clear();
    manifest.label = None;
    manifest.thumbnail = None;
    manifest.display = None;
    let manifest_source = toml::to_string(&manifest).map_err(|error| error.to_string())?;
    let compilation = compile_project(&manifest_source, &project.files, CompileMode::Debug);
    if compile_fail {
        let code = match compilation {
            Err(error) => Some(error.code.to_owned()),
            Ok(output) => output
                .analysis
                .diagnostics
                .first()
                .map(|diagnostic| diagnostic.code.clone()),
        };
        return match (expected_code, code) {
            (Some(expected), Some(actual)) if expected == actual => Ok(()),
            (Some(expected), Some(actual)) => {
                Err(format!("expected {expected}, compiler returned {actual}"))
            }
            (Some(expected), None) => {
                Err(format!("expected {expected}, but compilation succeeded"))
            }
            (None, _) => Err("compile-fail test needs `// expect PX....`".to_owned()),
        };
    }
    let compilation = compilation.map_err(|error| error.to_string())?;
    if let Some(diagnostic) = compilation.analysis.diagnostics.first() {
        return Err(format!("error[{}] {}", diagnostic.code, diagnostic.message));
    }
    let generated = compilation
        .generated
        .ok_or_else(|| "test produced no executable program".to_owned())?;
    let request = serde_json::json!({
        "revision": 1,
        "javascript": generated.javascript,
        "manifest": { "id": project.manifest.id, "updateRate": project.manifest.update_rate,
            "display": null, "assets": {} },
        "entries": {}, "rom": [0], "seed": 0x240c_1999_u32, "frames": 1,
        "trace": { "revision": 1, "frames": [] }, "save": [],
    });
    let result = execute_headless_host(
        &serde_json::to_vec(&request).map_err(|error| error.to_string())?,
        1,
    )
    .map_err(|()| "headless test host failed".to_owned())?;
    let result: serde_json::Value =
        serde_json::from_slice(&result).map_err(|error| error.to_string())?;
    if let Some(fault) = result.get("fault") {
        return Err(format!(
            "error[{}] {} at {}..{}",
            fault["code"].as_str().unwrap_or("PX????"),
            fault["message"].as_str().unwrap_or("runtime fault"),
            fault["sourceSpan"]["start"].as_u64().unwrap_or_default(),
            fault["sourceSpan"]["end"].as_u64().unwrap_or_default()
        ));
    }
    Ok(())
}

fn run_scripted_test(
    root: &Path,
    packed: &pxcl_core::PackedCartridge,
    test_path: &Path,
) -> Result<(), String> {
    let source = fs::read(test_path).map_err(|error| error.to_string())?;
    if source.len() > usize::try_from(MAX_TRACE_BYTES).unwrap_or(usize::MAX) {
        return Err("scripted test exceeds 8 MiB".to_owned());
    }
    let spec: serde_json::Value =
        serde_json::from_slice(&source).map_err(|error| error.to_string())?;
    if spec.get("revision").and_then(serde_json::Value::as_u64) != Some(1) {
        return Err("scripted test revision must be 1".to_owned());
    }
    let frames = spec
        .get("frames")
        .and_then(serde_json::Value::as_u64)
        .and_then(|value| u32::try_from(value).ok())
        .ok_or_else(|| "scripted test needs a u32 `frames`".to_owned())?;
    let seed = spec
        .get("seed")
        .and_then(serde_json::Value::as_u64)
        .and_then(|value| u32::try_from(value).ok())
        .unwrap_or(0x240c_1999);
    let trace = spec
        .get("input")
        .cloned()
        .unwrap_or_else(|| serde_json::json!({ "revision": 1, "frames": [] }));
    let save = match spec.get("save").and_then(serde_json::Value::as_str) {
        Some(relative) => read_save_image(Some(&root.join(relative)))
            .map_err(|()| "could not load scripted save fixture".to_owned())?,
        None => Vec::new(),
    };
    let cartridge = decode_cartridge(&packed.bytes).map_err(|error| error.to_string())?;
    let javascript = cartridge
        .entries
        .get("build/cartridge.js")
        .and_then(|bytes| std::str::from_utf8(bytes).ok())
        .ok_or_else(|| "packed project has no UTF-8 program".to_owned())?;
    let manifest = &cartridge.manifest;
    let request = serde_json::json!({
        "revision": 1, "javascript": javascript,
        "manifest": { "id": manifest.id, "updateRate": manifest.update_rate,
            "display": manifest.display, "assets": manifest.assets },
        "entries": cartridge.entries, "rom": packed.bytes, "seed": seed, "frames": frames,
        "trace": trace, "save": save,
    });
    let result = execute_headless_host(
        &serde_json::to_vec(&request).map_err(|error| error.to_string())?,
        frames,
    )
    .map_err(|()| "headless scripted test host failed".to_owned())?;
    let result: serde_json::Value =
        serde_json::from_slice(&result).map_err(|error| error.to_string())?;
    if let Some(fault) = result.get("fault") {
        return Err(format!(
            "runtime error[{}] {}",
            fault["code"].as_str().unwrap_or("PX????"),
            fault["message"].as_str().unwrap_or("runtime fault")
        ));
    }
    let expected = spec
        .get("expect")
        .and_then(serde_json::Value::as_object)
        .ok_or_else(|| "scripted test needs an `expect` object".to_owned())?;
    let summary = result
        .get("summary")
        .and_then(serde_json::Value::as_object)
        .ok_or_else(|| "headless host returned no summary".to_owned())?;
    for (key, expected_value) in expected {
        if summary.get(key) != Some(expected_value) {
            return Err(format!(
                "snapshot `{key}` expected {expected_value}, got {}",
                summary.get(key).unwrap_or(&serde_json::Value::Null)
            ));
        }
    }
    Ok(())
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

fn watch_directory(path: &Path, output: Option<&Path>, once: bool, no_open: bool) -> ExitCode {
    if once {
        return pack_directory(path, output);
    }
    let output = output.map_or_else(|| path.join("dist/watch.html"), Path::to_path_buf);
    if export_watch_html(path, &output).is_err() {
        return ExitCode::FAILURE;
    }
    let listener = match TcpListener::bind("127.0.0.1:0") {
        Ok(listener) => listener,
        Err(error) => {
            eprintln!("px240c watch: could not bind local player: {error}");
            return ExitCode::FAILURE;
        }
    };
    if let Err(error) = listener.set_nonblocking(true) {
        eprintln!("px240c watch: could not configure local player: {error}");
        return ExitCode::FAILURE;
    }
    let address = listener
        .local_addr()
        .expect("bound listener has an address");
    let url = format!("http://{address}/");
    println!("watching {} at {url}", path.display());
    if !no_open && let Err(error) = browser_command(&url).spawn() {
        eprintln!("px240c watch: could not open system browser: {error}");
    }
    let mut fingerprint = directory_fingerprint(path).ok();
    let mut revision = 1_u64;
    loop {
        match listener.accept() {
            Ok((stream, _)) => serve_watch_request(stream, &output, revision),
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {}
            Err(error) => eprintln!("px240c watch: local player request failed: {error}"),
        }
        let current = directory_fingerprint(path).ok();
        if current != fingerprint {
            fingerprint = current;
            if export_watch_html(path, &output).is_ok() {
                revision = revision.wrapping_add(1);
                println!("rebuilt revision {revision}");
            }
        }
        thread::sleep(Duration::from_millis(50));
    }
}

fn browser_command(target: &str) -> ProcessCommand {
    let mut command = if cfg!(target_os = "macos") {
        ProcessCommand::new("open")
    } else {
        ProcessCommand::new("xdg-open")
    };
    command.arg(target);
    command
}

fn export_watch_html(path: &Path, output: &Path) -> Result<(), ()> {
    let project = load_project(path)?;
    let html =
        export_standalone_html(&project.manifest_source, &project.files).map_err(|error| {
            eprintln!("{}: {error}", path.display());
        })?;
    let reload = r"<script>(()=>{let revision;setInterval(async()=>{try{const next=await fetch('/revision',{cache:'no-store'}).then(response=>response.text());if(revision!==undefined&&next!==revision)location.reload();revision=next}catch{}},250)})()</script>";
    let html = html.replace("</body>", &format!("{reload}</body>"));
    if let Some(parent) = output.parent() {
        fs::create_dir_all(parent).map_err(|error| {
            eprintln!("{}: {error}", parent.display());
        })?;
    }
    fs::write(output, html).map_err(|error| {
        eprintln!("{}: {error}", output.display());
    })
}

fn serve_watch_request(mut stream: TcpStream, output: &Path, revision: u64) {
    let _ = stream.set_read_timeout(Some(Duration::from_millis(100)));
    let mut request = [0_u8; 4096];
    let length = stream.read(&mut request).unwrap_or_default();
    let revision_request = request[..length].starts_with(b"GET /revision ");
    let (content_type, body) = if revision_request {
        (
            "text/plain; charset=utf-8",
            revision.to_string().into_bytes(),
        )
    } else {
        (
            "text/html; charset=utf-8",
            fs::read(output).unwrap_or_else(|_| b"PX-240C WATCH BUILD UNAVAILABLE".to_vec()),
        )
    };
    let header = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
        body.len()
    );
    let _ = stream.write_all(header.as_bytes());
    let _ = stream.write_all(&body);
}

fn directory_fingerprint(path: &Path) -> Result<u64, std::io::Error> {
    let mut files = Vec::new();
    collect_fingerprint_files(path, path, &mut files)?;
    files.sort();
    let mut hasher = DefaultHasher::new();
    for file in files {
        file.strip_prefix(path).unwrap_or(&file).hash(&mut hasher);
        fs::read(file)?.hash(&mut hasher);
    }
    Ok(hasher.finish())
}

fn collect_fingerprint_files(
    root: &Path,
    directory: &Path,
    files: &mut Vec<PathBuf>,
) -> Result<(), std::io::Error> {
    for entry in fs::read_dir(directory)? {
        let entry = entry?;
        let file_type = entry.file_type()?;
        if file_type.is_symlink() {
            continue;
        }
        if file_type.is_dir() {
            let name = entry.file_name();
            if !matches!(
                name.to_str(),
                Some(".git" | "dist" | "node_modules" | "target")
            ) {
                collect_fingerprint_files(root, &entry.path(), files)?;
            }
        } else if entry.path() != root.join("cart.pxc") {
            files.push(entry.path());
        }
    }
    Ok(())
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
    let metadata = if path
        .extension()
        .is_some_and(|extension| extension == "pxc" || extension == "png")
    {
        fs::read(path)
            .map_err(|error| error.to_string())
            .and_then(|bytes| {
                if path.extension().is_some_and(|extension| extension == "png") {
                    decode_cartridge_png(&bytes).map(|decoded| decoded.cartridge)
                } else {
                    Ok(bytes)
                }
            })
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
        .chain(manifest.thumbnail.as_deref())
        .chain(manifest.display.as_deref());
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
    if path.is_dir() {
        return build_directory(path, output, debug);
    }
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
    write_program(&generated, &output)
}

fn build_directory(path: &Path, output: Option<&Path>, debug: bool) -> ExitCode {
    let Ok(project) = load_project(path) else {
        return ExitCode::FAILURE;
    };
    let compilation = match compile_project(
        &project.manifest_source,
        &project.files,
        if debug {
            CompileMode::Debug
        } else {
            CompileMode::Release
        },
    ) {
        Ok(compilation) => compilation,
        Err(error) => {
            eprintln!("{}: {error}", path.display());
            return ExitCode::FAILURE;
        }
    };
    if !compilation.analysis.diagnostics.is_empty() {
        emit_project_diagnostics(path, &compilation.analysis.diagnostics);
        return ExitCode::FAILURE;
    }
    let Some(generated) = compilation.generated else {
        eprintln!("{}: compiler produced no output", path.display());
        return ExitCode::FAILURE;
    };
    let output = output.map_or_else(|| path.join("dist/cartridge.js"), Path::to_path_buf);
    write_program(&generated, &output)
}

fn write_program(generated: &GeneratedProgram, output: &Path) -> ExitCode {
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
    if let Err(error) = fs::write(output, javascript) {
        eprintln!("{}: {error}", output.display());
        return ExitCode::FAILURE;
    }
    if let Err(error) = fs::write(&source_map, &generated.source_map_json) {
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
    let defaults = [PathBuf::from(".")];
    let paths = if paths.is_empty() {
        &defaults[..]
    } else {
        paths
    };
    let mut failed = false;
    for (index, path) in paths.iter().enumerate() {
        if path.is_dir() {
            let Ok(project) = load_project(path) else {
                failed = true;
                continue;
            };
            match compile_project(
                &project.manifest_source,
                &project.files,
                CompileMode::Release,
            ) {
                Ok(output) if output.analysis.diagnostics.is_empty() => {}
                Ok(output) => {
                    emit_project_diagnostics(path, &output.analysis.diagnostics);
                    failed = true;
                }
                Err(error) => {
                    eprintln!("{}: {error}", path.display());
                    failed = true;
                }
            }
            continue;
        }
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

fn emit_project_diagnostics(path: &Path, diagnostics: &[Diagnostic]) {
    for diagnostic in diagnostics {
        eprintln!(
            "{}: error[{}]: {}",
            path.display(),
            diagnostic.code,
            diagnostic.message
        );
    }
}

fn format_files(paths: &[PathBuf], check: bool) -> ExitCode {
    let defaults = [PathBuf::from(".")];
    let requested = if paths.is_empty() {
        &defaults[..]
    } else {
        paths
    };
    let mut paths = Vec::new();
    for requested_path in requested {
        if requested_path.is_dir() {
            if let Err(error) = collect_pxl_paths(requested_path, &mut paths) {
                eprintln!("{}: {error}", requested_path.display());
                return ExitCode::FAILURE;
            }
        } else {
            paths.push(requested_path.clone());
        }
    }
    paths.sort();
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

fn collect_pxl_paths(directory: &Path, paths: &mut Vec<PathBuf>) -> Result<(), std::io::Error> {
    for entry in fs::read_dir(directory)? {
        let entry = entry?;
        let file_type = entry.file_type()?;
        if file_type.is_symlink() {
            continue;
        }
        if file_type.is_dir() {
            if !matches!(
                entry.file_name().to_str(),
                Some(".git" | "dist" | "node_modules" | "target")
            ) {
                collect_pxl_paths(&entry.path(), paths)?;
            }
        } else if entry
            .path()
            .extension()
            .is_some_and(|extension| extension == "pxl")
        {
            paths.push(entry.path());
        }
    }
    Ok(())
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
