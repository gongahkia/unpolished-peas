use std::{fs, path::PathBuf};

use modl_core::{AssetCatalog, FileId, SourceFile, Type, analyze_module};

fn analyze_fixture(name: &str) -> modl_core::AnalysisOutput {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/types")
        .join(name);
    let text = fs::read_to_string(&path).expect("fixture is readable");
    analyze_module(
        &SourceFile::new(FileId(0), path.display().to_string(), text),
        &AssetCatalog::default(),
    )
}

#[test]
fn positive_type_fixture_lowers_to_fully_typed_ir() {
    let output = analyze_fixture("positive.modl");
    assert!(output.diagnostics.is_empty(), "{:#?}", output.diagnostics);
    let ir = output.ir.expect("valid syntax has typed IR");
    assert_eq!(ir.globals.len(), 7);
    assert_eq!(ir.records.len(), 1);
    assert_eq!(ir.enums.len(), 1);
    assert_eq!(ir.routines.len(), 5);
    assert!(
        ir.globals
            .iter()
            .all(|global| !matches!(global.initializer.r#type, Type::Unknown | Type::Error))
    );
}

#[test]
fn negative_type_fixture_reports_independent_stable_errors() {
    let output = analyze_fixture("negative.modl");
    let codes: Vec<_> = output
        .diagnostics
        .iter()
        .map(|diagnostic| diagnostic.code.as_str())
        .collect();
    for expected in [
        "M013003", "M013101", "M013104", "M013106", "M013110", "M013112",
    ] {
        assert!(
            codes.contains(&expected),
            "missing {expected}; found {codes:?}"
        );
    }
}
