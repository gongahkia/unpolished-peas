//! Shared compiler, analysis, and cartridge-format implementation for PXCL/1.

pub mod ast;
pub mod cartridge;
pub mod cartridge_png;
pub mod codegen;
pub mod diagnostic;
pub mod exporter;
pub mod formatter;
pub mod ir;
pub mod lexer;
pub mod parser;
pub mod sema;
pub mod span;
pub mod token;
pub mod types;

pub use cartridge::{
    CartridgeError, DecodedCartridge, PackedCartridge, PackedManifest, ProjectAsset,
    ProjectManifest, UnpackedProject, compile_project, decode_cartridge, pack_project,
    parse_project_manifest, unpack_cartridge_project,
};
pub use cartridge_png::{
    CartridgePng, CartridgePngMetadata, decode_cartridge_png, encode_cartridge_png,
};
pub use codegen::{CompilationOutput, CompileMode, GeneratedProgram, compile};
pub use diagnostic::{Diagnostic, Severity};
pub use exporter::export_standalone_html;
pub use formatter::{FormatError, format_source};
pub use lexer::lex;
pub use parser::{ParseOutput, parse};
pub use sema::{AnalysisOutput, analyze_module};
pub use span::{FileId, LineColumn, SourceFile, Span, Spanned};
pub use token::{Token, TokenKind};
pub use types::{AssetCatalog, AssetKind, Type};

/// The source-language revision understood by this compiler.
pub const LANGUAGE_REVISION: &str = "PXCL/1";

/// The deterministic packed-cartridge format revision.
pub const CARTRIDGE_FORMAT_REVISION: u16 = 1;

/// Identifies the compiler in generated artifacts and diagnostics.
#[must_use]
pub const fn compiler_version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

#[cfg(test)]
mod tests {
    use super::{CARTRIDGE_FORMAT_REVISION, LANGUAGE_REVISION, compiler_version};

    #[test]
    fn revisions_are_explicit() {
        assert_eq!(LANGUAGE_REVISION, "PXCL/1");
        assert_eq!(CARTRIDGE_FORMAT_REVISION, 1);
        assert!(!compiler_version().is_empty());
    }
}
