use std::{fs, process::Command};

use pxcl_core::{AssetCatalog, CompileMode, FileId, SourceFile, compile};

fn execute(mode: CompileMode) -> serde_json::Value {
    let source = SourceFile::new(
        FileId(0),
        "semantic-equivalence.pxl",
        r"state score: Int = 0
task tick():
  var index = 0
  while index < 3:
    wait 1f
    score += 1
    index += 1
on start:
  start tick()
on update:
  score += 10
",
    );
    let output = compile(&source, &AssetCatalog::default(), mode);
    assert!(
        output.analysis.diagnostics.is_empty(),
        "{:#?}",
        output.analysis.diagnostics
    );
    let program = output.generated.expect("valid source generates JavaScript");
    let script = format!(
        r#"{}
let workUnits=0;
const api={{
  work(units){{workUnits+=units;if(workUnits>100000)throw new Error("budget");}},
  call(){{throw new Error("unexpected console API call");}},
  fault(code,message){{throw new Error(`${{code}}: ${{message}}`);}},
  probe(){{}},enter(){{}},leave(){{}}
}};
const cartridge=createCartridge(api);
cartridge.start();
for(let frame=0;frame<6;frame+=1)cartridge.update();
process.stdout.write(JSON.stringify({{snapshot:cartridge.snapshot(),workUnits}}));
"#,
        program.javascript
    );
    let suffix = match mode {
        CompileMode::Release => "release",
        CompileMode::Debug => "debug",
    };
    let path =
        std::env::temp_dir().join(format!("pxcl-codegen-{}-{suffix}.mjs", std::process::id()));
    fs::write(&path, script).expect("temporary generated module writes");
    let result = Command::new("node")
        .arg(&path)
        .output()
        .expect("Node.js executes generated module");
    fs::remove_file(path).expect("temporary generated module removes");
    assert!(
        result.status.success(),
        "generated module failed:\n{}",
        String::from_utf8_lossy(&result.stderr)
    );
    serde_json::from_slice(&result.stdout).expect("generated module prints JSON")
}

#[test]
fn release_and_debug_outputs_are_semantically_equivalent() {
    let release = execute(CompileMode::Release);
    let debug = execute(CompileMode::Debug);
    assert_eq!(release, debug);
    assert_eq!(
        release["snapshot"]["state"]
            .as_object()
            .and_then(|state| state.values().next())
            .and_then(serde_json::Value::as_i64),
        Some(63)
    );
    assert_eq!(
        release["snapshot"]["tasks"].as_array().map(Vec::len),
        Some(0)
    );
}
