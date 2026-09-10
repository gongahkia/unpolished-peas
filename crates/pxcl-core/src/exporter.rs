use std::collections::BTreeMap;

use serde::Serialize;

use crate::{CartridgeError, PackedManifest, decode_cartridge, pack_project};

const STANDALONE_PLAYER: &str = include_str!("../../../packages/runtime/standalone/player.js");

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct StandalonePayload {
    manifest: PackedManifest,
    files: BTreeMap<String, String>,
    rom: String,
}

/// Exports a project as one offline, source-inspectable standalone HTML player.
///
/// The project is first packed and decoded through the canonical cartridge format. This keeps the
/// standalone payload byte-for-byte aligned with what the `.pxc` inspector accepts.
///
/// # Errors
///
/// Returns the same stable cartridge errors used by project packing and validation.
pub fn export_standalone_html(
    manifest_source: &str,
    project_files: &BTreeMap<String, Vec<u8>>,
) -> Result<String, CartridgeError> {
    let packed = pack_project(manifest_source, project_files)?;
    let cartridge = decode_cartridge(&packed.bytes)?;
    let title = escape_html(&cartridge.manifest.title);
    let author = escape_html(&cartridge.manifest.author);
    let payload = StandalonePayload {
        manifest: cartridge.manifest,
        files: cartridge
            .entries
            .into_iter()
            .map(|(path, contents)| (path, base64(&contents)))
            .collect(),
        rom: base64(&packed.bytes),
    };
    let payload = serde_json::to_string(&payload).map_err(|error| {
        export_error(format!("could not serialize standalone payload: {error}"))
    })?;
    let payload = escape_script_data(&payload);

    Ok(format!(
        r##"<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="theme-color" content="#17141f">
<meta name="px240c-format" content="1">
<title>{title} — PX-240C</title>
<style>
:root{{color-scheme:dark;font-family:ui-monospace,"Cascadia Mono",monospace;background:#17141f;color:#f4e5bd}}
*{{box-sizing:border-box}}body{{margin:0;min-height:100vh;display:grid;place-items:center;background:radial-gradient(circle,#403946 0,#17141f 72%);overflow:hidden}}
.unit{{width:min(96vw,960px);padding:clamp(12px,3vw,30px);border:3px solid #806a63;border-radius:28px;background:#d5b992;color:#292532;box-shadow:0 18px 50px #0009,inset 0 0 0 3px #f4e5bd}}
header,footer,.controls{{display:flex;align-items:center;justify-content:space-between;gap:12px}}header{{padding:0 4px 14px;font-weight:800;letter-spacing:.08em}}header small,footer{{font-size:clamp(9px,1.5vw,13px)}}.bezel{{position:relative;padding:clamp(8px,2vw,18px);border-radius:18px;background:#292532;box-shadow:inset 0 0 0 3px #403946}}
canvas{{display:block;width:100%;aspect-ratio:5/3;image-rendering:pixelated;background:#17141f;touch-action:none}}button,select{{border:2px solid #403946;border-radius:3px;background:#f4e5bd;color:#292532;font:inherit;font-weight:800;padding:7px 10px}}button:focus-visible,select:focus-visible{{outline:3px solid #ed7b69;outline-offset:2px}}button:disabled{{opacity:.65}}
.controls{{padding:14px 4px 0}}#status{{font-variant-numeric:tabular-nums;font-size:12px}}.error{{color:#8b3c47}}
#inspector{{position:absolute;inset:8px;display:grid;grid-template-rows:auto 1fr;background:#17141ff2;color:#f4e5bd;border:2px solid #75cbc0;padding:8px;z-index:2}}#inspector[hidden]{{display:none}}#inspector header{{padding:0 0 8px}}pre{{margin:0;padding:8px;overflow:auto;white-space:pre;tab-size:2;background:#292532;color:#f4e5bd;font-size:clamp(9px,1.45vw,14px)}}footer{{padding:14px 4px 0;color:#403946}}
@media(max-width:540px){{.unit{{width:100vw;border-width:0;border-radius:0;padding:8px}}header{{padding-bottom:7px}}.controls,footer{{padding-top:7px}}}}
</style>
</head>
<body>
<main class="unit" aria-label="PX-240C standalone cartridge player">
<header><span>PX-240C COLOR DEVELOPMENT UNIT</span><small>STANDALONE/1</small></header>
<section class="bezel">
<canvas id="screen" width="240" height="144" aria-label="{title} game display"></canvas>
<section id="inspector" hidden aria-label="Cartridge source inspector">
<header><select id="source-file" aria-label="Source file"></select><button id="close-source" type="button">CLOSE</button></header>
<pre id="source-view" tabindex="0"></pre>
</section>
</section>
<section class="controls"><strong id="title">{title}</strong><span><button id="sound" type="button">ENABLE SOUND</button> <button id="source" type="button">SOURCE</button></span><output id="status">BOOT</output></section>
<footer><span id="author">AUTHOR: {author}</span><span>PXCL/1 · CARTRIDGE FORMAT/1</span></footer>
</main>
<script>globalThis.__PX240C_CARTRIDGE__={payload};</script>
<script>{STANDALONE_PLAYER}</script>
</body>
</html>
"##
    ))
}

fn export_error(message: String) -> CartridgeError {
    CartridgeError {
        code: "PX4014",
        message,
    }
}

fn escape_html(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}

fn escape_script_data(value: &str) -> String {
    value
        .replace('&', "\\u0026")
        .replace('<', "\\u003c")
        .replace('>', "\\u003e")
        .replace('\u{2028}', "\\u2028")
        .replace('\u{2029}', "\\u2029")
}

fn base64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut output = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let first = u32::from(chunk[0]);
        let second = u32::from(*chunk.get(1).unwrap_or(&0));
        let third = u32::from(*chunk.get(2).unwrap_or(&0));
        let value = (first << 16) | (second << 8) | third;
        output.push(char::from(ALPHABET[((value >> 18) & 63) as usize]));
        output.push(char::from(ALPHABET[((value >> 12) & 63) as usize]));
        output.push(if chunk.len() > 1 {
            char::from(ALPHABET[((value >> 6) & 63) as usize])
        } else {
            '='
        });
        output.push(if chunk.len() > 2 {
            char::from(ALPHABET[(value & 63) as usize])
        } else {
            '='
        });
    }
    output
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use super::{base64, export_standalone_html};

    fn project() -> (String, BTreeMap<String, Vec<u8>>) {
        let manifest = r#"format = 1
language = "PXCL/1"
id = "standalone-test"
title = "SCRIPT </script> TEST"
author = "@gongahkia"
version = "0.1.0"
entry = "src/main.pxl"
update_rate = 60

[assets]
"#;
        let files = BTreeMap::from([(
            "src/main.pxl".to_owned(),
            b"on draw:\n  clear(0)\n  print(\"SOURCE VISIBLE\", 2, 2, 7)\n".to_vec(),
        )]);
        (manifest.to_owned(), files)
    }

    #[test]
    fn base64_matches_rfc_4648_vectors() {
        assert_eq!(base64(b""), "");
        assert_eq!(base64(b"f"), "Zg==");
        assert_eq!(base64(b"fo"), "Zm8=");
        assert_eq!(base64(b"foo"), "Zm9v");
        assert_eq!(base64(b"foobar"), "Zm9vYmFy");
    }

    #[test]
    fn standalone_export_is_deterministic_offline_and_source_inspectable() {
        let (manifest, files) = project();
        let first = export_standalone_html(&manifest, &files).expect("project exports");
        let second = export_standalone_html(&manifest, &files).expect("project exports again");
        assert_eq!(first, second);
        assert!(first.starts_with("<!doctype html>"));
        assert!(first.contains("id=\"source-view\""));
        assert!(first.contains("source/src/main.pxl"));
        assert!(first.contains(&base64(&files["src/main.pxl"])));
        assert!(first.contains("\"rom\":\"UFgyNDBD"));
        assert!(first.contains("createConsoleRuntime"));
        assert!(!first.contains("https://"));
        assert!(!first.contains("SCRIPT </script> TEST"));
        assert!(first.contains("SCRIPT &lt;/script&gt; TEST"));
    }
}
