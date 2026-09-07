use std::{
    fs,
    io::Write,
    process::{Command, Stdio},
};

use serde_json::{Value, json};

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
fn export_html_and_headless_run_write_the_same_offline_player() {
    let project =
        std::env::temp_dir().join(format!("px240c-export-{}-{}", std::process::id(), line!()));
    let create = binary()
        .args([
            "new",
            project.to_str().expect("UTF-8 project path"),
            "--title",
            "EXPORT TEST",
        ])
        .output()
        .expect("CLI starts");
    assert!(create.status.success());
    let first = project.with_extension("first.html");
    let second = project.with_extension("second.html");
    let export = binary()
        .args([
            "export",
            "html",
            project.to_str().expect("UTF-8 project path"),
            "--output",
            first.to_str().expect("UTF-8 HTML path"),
        ])
        .output()
        .expect("CLI starts");
    assert!(
        export.status.success(),
        "{}",
        String::from_utf8_lossy(&export.stderr)
    );
    let run = binary()
        .args([
            "run",
            project.to_str().expect("UTF-8 project path"),
            "--no-open",
            "--output",
            second.to_str().expect("UTF-8 HTML path"),
        ])
        .output()
        .expect("CLI starts");
    assert!(
        run.status.success(),
        "{}",
        String::from_utf8_lossy(&run.stderr)
    );
    let first_html = fs::read_to_string(&first).expect("first HTML reads");
    assert_eq!(
        first_html,
        fs::read_to_string(&second).expect("second HTML reads")
    );
    assert!(first_html.contains("PX-240C standalone cartridge player"));
    assert!(first_html.contains("id=\"source-view\""));
    assert!(!first_html.contains("https://"));
    for path in [first, second] {
        fs::remove_file(path).expect("temporary HTML removes");
    }
    fs::remove_dir_all(project).expect("temporary project removes");
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
    fs::write(
        project.join("src/math.pxl"),
        "fn twice(value: Int) -> Int:\n  return value * 2\n",
    )
    .expect("module writes");
    fs::write(
        project.join("src/main.pxl"),
        "import src.math as math\nstate score: Int = 1\non update:\n  score = math.twice(score)\n",
    )
    .expect("entry writes");
    let linked = project.with_extension("linked.js");
    let build = binary()
        .args([
            "build",
            project.to_str().expect("UTF-8 project path"),
            "--output",
            linked.to_str().expect("UTF-8 JavaScript path"),
        ])
        .output()
        .expect("CLI starts");
    assert!(
        build.status.success(),
        "{}",
        String::from_utf8_lossy(&build.stderr)
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
    let watched = project.with_extension("watched.pxc");
    let watch = binary()
        .args([
            "watch",
            project.to_str().expect("UTF-8 project path"),
            "--once",
            "--output",
            watched.to_str().expect("UTF-8 cartridge path"),
        ])
        .output()
        .expect("CLI starts");
    assert!(
        watch.status.success(),
        "{}",
        String::from_utf8_lossy(&watch.stderr)
    );
    assert_eq!(
        fs::read(&first).expect("first cartridge reads"),
        fs::read(&watched).expect("watched cartridge reads")
    );
    let info = binary()
        .args(["info", first.to_str().expect("UTF-8 cartridge path")])
        .output()
        .expect("CLI starts");
    assert!(info.status.success());
    assert!(String::from_utf8_lossy(&info.stdout).contains("\"title\": \"CLI TEST\""));

    fs::remove_file(first).expect("first cartridge removes");
    fs::remove_file(second).expect("second cartridge removes");
    fs::remove_file(watched).expect("watched cartridge removes");
    fs::remove_file(linked.with_extension("js.map")).expect("linked source map removes");
    fs::remove_file(linked).expect("linked JavaScript removes");
    fs::remove_dir_all(project).expect("temporary project removes");
}

#[test]
fn lsp_serves_diagnostics_completion_and_symbol_navigation() {
    let uri = "file:///tmp/lsp-test.pxl";
    let source = "state score: Int = 0\n\non update:\n  score += 1\n\non draw:\n  clear(0)\n";
    let messages = [
        json!({ "jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {} }),
        json!({
            "jsonrpc": "2.0",
            "method": "textDocument/didOpen",
            "params": { "textDocument": { "uri": uri, "languageId": "pxcl", "version": 1, "text": source } }
        }),
        json!({
            "jsonrpc": "2.0", "id": 2, "method": "textDocument/completion",
            "params": { "textDocument": { "uri": uri }, "position": { "line": 3, "character": 4 } }
        }),
        json!({
            "jsonrpc": "2.0", "id": 3, "method": "textDocument/hover",
            "params": { "textDocument": { "uri": uri }, "position": { "line": 6, "character": 4 } }
        }),
        json!({
            "jsonrpc": "2.0", "id": 4, "method": "textDocument/definition",
            "params": { "textDocument": { "uri": uri }, "position": { "line": 3, "character": 4 } }
        }),
        json!({
            "jsonrpc": "2.0", "id": 5, "method": "textDocument/references",
            "params": { "textDocument": { "uri": uri }, "position": { "line": 3, "character": 4 }, "context": { "includeDeclaration": true } }
        }),
        json!({
            "jsonrpc": "2.0", "id": 6, "method": "textDocument/rename",
            "params": { "textDocument": { "uri": uri }, "position": { "line": 3, "character": 4 }, "newName": "points" }
        }),
        json!({ "jsonrpc": "2.0", "id": 7, "method": "shutdown", "params": null }),
        json!({ "jsonrpc": "2.0", "method": "exit", "params": null }),
    ];
    let mut child = binary()
        .arg("lsp")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .expect("LSP starts");
    {
        let input = child.stdin.as_mut().expect("LSP stdin");
        for message in messages {
            let bytes = serde_json::to_vec(&message).expect("request serializes");
            write!(input, "Content-Length: {}\r\n\r\n", bytes.len()).expect("header writes");
            input.write_all(&bytes).expect("body writes");
        }
    }
    let output = child.wait_with_output().expect("LSP exits");
    assert!(output.status.success());
    let responses = decode_lsp_messages(&output.stdout);
    let response = |id: i64| {
        responses
            .iter()
            .find(|value| value.get("id").and_then(Value::as_i64) == Some(id))
            .expect("response id exists")
    };
    assert_eq!(response(1)["result"]["serverInfo"]["name"], "px240c");
    assert!(
        response(2)["result"]
            .as_array()
            .expect("completion list")
            .iter()
            .any(|item| item["label"] == "clear")
    );
    assert!(
        response(3)["result"]["contents"]["value"]
            .as_str()
            .is_some_and(|value| value.contains("fn clear"))
    );
    assert_eq!(response(4)["result"]["range"]["start"]["line"], 0);
    assert_eq!(
        response(5)["result"].as_array().expect("references").len(),
        2
    );
    assert_eq!(
        response(6)["result"]["changes"][uri]
            .as_array()
            .expect("rename edits")
            .len(),
        2
    );
    assert!(responses.iter().any(|value| {
        value.get("method") == Some(&Value::String("textDocument/publishDiagnostics".to_owned()))
            && value["params"]["diagnostics"] == json!([])
    }));
}

fn decode_lsp_messages(bytes: &[u8]) -> Vec<Value> {
    let mut messages = Vec::new();
    let mut cursor = 0;
    while cursor < bytes.len() {
        let separator = bytes[cursor..]
            .windows(4)
            .position(|window| window == b"\r\n\r\n")
            .expect("LSP header terminator");
        let header_end = cursor + separator;
        let header = std::str::from_utf8(&bytes[cursor..header_end]).expect("ASCII headers");
        let length = header
            .strip_prefix("Content-Length: ")
            .expect("content length")
            .parse::<usize>()
            .expect("numeric content length");
        let body_start = header_end + 4;
        let body_end = body_start + length;
        messages.push(serde_json::from_slice(&bytes[body_start..body_end]).expect("JSON response"));
        cursor = body_end;
    }
    messages
}
