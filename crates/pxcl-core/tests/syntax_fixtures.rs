use std::{fs, path::PathBuf};

use pxcl_core::{FileId, SourceFile, format_source, parse};

fn fixture(path: &str) -> (PathBuf, String) {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(path);
    let source = fs::read_to_string(&path).expect("fixture is readable");
    (path, source)
}

#[test]
fn kitchen_sink_parses_and_is_canonically_formatted() {
    let (path, text) = fixture("positive/kitchen_sink.pxl");
    let source = SourceFile::new(FileId(0), path.display().to_string(), text.clone());
    let output = parse(&source);
    assert!(output.diagnostics.is_empty(), "{:#?}", output.diagnostics);
    assert_eq!(format_source(&source).expect("fixture formats"), text);
}

#[test]
fn negative_fixture_has_stable_code_and_exact_span() {
    let (path, text) = fixture("negative/missing_state_separator.pxl");
    let source = SourceFile::new(FileId(7), path.display().to_string(), text);
    let output = parse(&source);
    assert_eq!(output.diagnostics.len(), 1);
    let diagnostic = &output.diagnostics[0];
    assert_eq!(diagnostic.code, "PX2002");
    assert_eq!(diagnostic.primary.span.file, FileId(7));
    assert_eq!(diagnostic.primary.span.start, 12);
    assert_eq!(diagnostic.primary.span.end, 15);
    assert_eq!(source.text_for(diagnostic.primary.span), Some("Int"));
    assert_eq!(output.module.items.len(), 2, "parser should recover");
}
