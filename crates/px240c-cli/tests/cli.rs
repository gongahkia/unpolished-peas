use std::{fs, process::Command};

fn binary() -> Command {
    Command::new(env!("CARGO_BIN_EXE_px240c"))
}

#[test]
fn check_accepts_the_positive_language_fixture() {
    let fixture = format!(
        "{}/../pxcl-core/tests/fixtures/types/positive.pxl",
        env!("CARGO_MANIFEST_DIR")
    );
    let output = binary()
        .args(["check", &fixture])
        .output()
        .expect("CLI starts");
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
}

#[test]
fn formatter_check_distinguishes_valid_unformatted_source() {
    let path =
        std::env::temp_dir().join(format!("px240c-cli-{}-{}.pxl", std::process::id(), line!()));
    fs::write(&path, "state  score:Int=0\n").expect("temporary source writes");
    let check = binary()
        .args(["fmt", "--check", path.to_str().expect("UTF-8 path")])
        .output()
        .expect("CLI starts");
    assert_eq!(check.status.code(), Some(1));

    let format = binary()
        .args(["fmt", path.to_str().expect("UTF-8 path")])
        .output()
        .expect("CLI starts");
    assert!(format.status.success());
    assert_eq!(
        fs::read_to_string(&path).expect("temporary source reads"),
        "state score: Int = 0\n"
    );
    fs::remove_file(path).expect("temporary source removes");
}

#[test]
fn build_emits_javascript_and_source_map() {
    let stem =
        std::env::temp_dir().join(format!("px240c-build-{}-{}", std::process::id(), line!()));
    let source = stem.with_extension("pxl");
    let javascript = stem.with_extension("js");
    let source_map = stem.with_extension("js.map");
    fs::write(&source, "state score: Int = 0\non update:\n  score += 1\n")
        .expect("temporary source writes");
    let output = binary()
        .args([
            "build",
            source.to_str().expect("UTF-8 source path"),
            "--output",
            javascript.to_str().expect("UTF-8 output path"),
        ])
        .output()
        .expect("CLI starts");
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        fs::read_to_string(&javascript)
            .expect("JavaScript reads")
            .contains("export default function createCartridge")
    );
    let map: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&source_map).expect("source map reads"))
            .expect("source map is JSON");
    assert_eq!(map["version"], 3);
    for path in [source, javascript, source_map] {
        fs::remove_file(path).expect("temporary build artifact removes");
    }
}

#[test]
fn new_pack_and_info_form_a_deterministic_project_workflow() {
    let project =
        std::env::temp_dir().join(format!("px240c-project-{}-{}", std::process::id(), line!()));
    assert!(
        !project.exists(),
        "temporary project path unexpectedly exists"
    );
    let create = binary()
        .args([
            "new",
            project.to_str().expect("UTF-8 project path"),
            "--title",
            "CLI TEST",
        ])
        .output()
        .expect("CLI starts");
    assert!(
        create.status.success(),
        "{}",
        String::from_utf8_lossy(&create.stderr)
    );
    let first = project.with_extension("first.pxc");
    let second = project.with_extension("second.pxc");
    for output in [&first, &second] {
        let pack = binary()
            .args([
                "pack",
                project.to_str().expect("UTF-8 project path"),
                "--output",
                output.to_str().expect("UTF-8 cartridge path"),
            ])
            .output()
            .expect("CLI starts");
        assert!(
            pack.status.success(),
            "{}",
            String::from_utf8_lossy(&pack.stderr)
        );
    }
    assert_eq!(
        fs::read(&first).expect("first cartridge reads"),
        fs::read(&second).expect("second cartridge reads")
    );
    let info = binary()
        .args(["info", first.to_str().expect("UTF-8 cartridge path")])
        .output()
        .expect("CLI starts");
    assert!(info.status.success());
    assert!(String::from_utf8_lossy(&info.stdout).contains("\"title\": \"CLI TEST\""));

    fs::remove_file(first).expect("first cartridge removes");
    fs::remove_file(second).expect("second cartridge removes");
    fs::remove_dir_all(project).expect("temporary project removes");
}
