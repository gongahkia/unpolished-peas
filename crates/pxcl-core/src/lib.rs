//! Shared compiler, analysis, and cartridge-format implementation for PXCL/1.

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
