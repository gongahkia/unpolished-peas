use std::{
    fs,
    path::{Path, PathBuf},
    process::ExitCode,
};

use clap::{Parser, Subcommand};
use pxcl_core::{Diagnostic, FileId, SourceFile, format_source, parse};

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

#[derive(Debug, Subcommand)]
enum Command {
    /// Check PXCL/1 source modules without producing output.
    Check { paths: Vec<PathBuf> },
    /// Format PXCL/1 source modules in place.
    Fmt {
        /// Report files that differ without writing them.
        #[arg(long)]
        check: bool,
        paths: Vec<PathBuf>,
    },
    /// Print compiler and format revision information.
    Info,
}

fn main() -> ExitCode {
    match Arguments::parse().command {
        Command::Check { paths } => check_files(&paths),
        Command::Fmt { check, paths } => format_files(&paths, check),
        Command::Info => {
            println!(
                "{} cartridge-format/{} compiler/{}",
                pxcl_core::LANGUAGE_REVISION,
                pxcl_core::CARTRIDGE_FORMAT_REVISION,
                pxcl_core::compiler_version()
            );
            ExitCode::SUCCESS
        }
    }
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
        let output = parse(&source);
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
