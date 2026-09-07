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
