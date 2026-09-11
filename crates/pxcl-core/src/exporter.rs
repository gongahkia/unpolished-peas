use std::collections::BTreeMap;

use serde::Serialize;

use crate::{CartridgeError, PackedManifest, decode_cartridge, pack_project};

const STANDALONE_PLAYER: &str = include_str!("../../../packages/runtime/standalone/player.js");

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct StandalonePayload {
    manifest: PackedManifest,
    presentation: StandalonePresentation,
    files: BTreeMap<String, String>,
    rom: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct StandalonePresentation {
    year: u16,
    players: u8,
    controls: String,
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
    let presentation = standalone_presentation(&cartridge.entries);
    let year = presentation.year;
    let players = presentation.players;
    let controls = escape_html(&presentation.controls);
    let payload = StandalonePayload {
        manifest: cartridge.manifest,
        presentation,
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
<meta name="px240c-embed" content="true">
<meta name="px240c-players" content="{players}">
<meta name="px240c-controls" content="{controls}">
<title>{title} — PX-240C</title>
<style>
:root{{color-scheme:dark;font-family:ui-monospace,"Cascadia Mono",monospace;background:#17141f;color:#f4e5bd}}
*{{box-sizing:border-box}}body{{margin:0;min-height:100vh;display:grid;place-items:center;background:radial-gradient(circle,#403946 0,#17141f 72%);overflow:hidden}}
.unit{{width:min(96vw,960px);padding:clamp(12px,3vw,30px);border:3px solid #806a63;border-radius:28px;background:#d5b992;color:#292532;box-shadow:0 18px 50px #0009,inset 0 0 0 3px #f4e5bd}}
header,footer,.controls{{display:flex;align-items:center;justify-content:space-between;gap:12px}}header{{padding:0 4px 14px;font-weight:800;letter-spacing:.08em}}header small,footer{{font-size:clamp(9px,1.5vw,13px)}}.bezel{{position:relative;padding:clamp(8px,2vw,18px);border-radius:18px;background:#292532;box-shadow:inset 0 0 0 3px #403946}}
canvas{{display:block;width:100%;aspect-ratio:5/3;image-rendering:pixelated;background:#17141f;touch-action:none}}button,select{{border:2px solid #403946;border-radius:3px;background:#f4e5bd;color:#292532;font:inherit;font-weight:800;padding:7px 10px}}button:focus-visible,select:focus-visible{{outline:3px solid #ed7b69;outline-offset:2px}}button:disabled{{opacity:.65}}
.controls{{padding:14px 4px 0;flex-wrap:wrap}}#status{{font-variant-numeric:tabular-nums;font-size:12px}}.error{{color:#8b3c47}}
#inspector{{position:absolute;inset:8px;display:grid;grid-template-rows:auto 1fr;background:#17141ff2;color:#f4e5bd;border:2px solid #75cbc0;padding:8px;z-index:2}}#inspector[hidden]{{display:none}}#inspector header{{padding:0 0 8px}}pre{{margin:0;padding:8px;overflow:auto;white-space:pre;tab-size:2;background:#292532;color:#f4e5bd;font-size:clamp(9px,1.45vw,14px)}}footer{{padding:14px 4px 0;color:#403946}}
@media(max-width:540px){{.unit{{width:100vw;border-width:0;border-radius:0;padding:8px}}header{{padding-bottom:7px}}.controls,footer{{padding-top:7px}}}}
html[data-embed="true"] body{{background:#17141f}}html[data-embed="true"] .unit{{width:100vw;min-height:100vh;border:0;border-radius:0;box-shadow:none}}html[data-embed="true"] main>header,html[data-embed="true"] footer{{display:none}}
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
<section class="controls"><strong id="title">{title}</strong><span><button id="sound" type="button">SOUND</button> <button id="pause" type="button">PAUSE</button> <button id="reset" type="button">RESET</button> <button id="fullscreen" type="button">FULL</button> <button id="source" type="button">SOURCE</button></span><output id="status">BOOT</output></section>
<footer><span id="author">AUTHOR: {author} / {year} / {players}P / {controls}</span><span>PXCL/1 · CARTRIDGE FORMAT/1</span></footer>
</main>
<script>globalThis.__PX240C_CARTRIDGE__={payload};</script>
<script>{STANDALONE_PLAYER}</script>
</body>
</html>
"##
    ))
}

/// Exports the same standalone player as a deterministic, timestamp-free itch.io ZIP.
///
/// # Errors
///
/// Returns the standalone packing/validation error or a stable ZIP size error.
pub fn export_itch_zip(
    manifest_source: &str,
    project_files: &BTreeMap<String, Vec<u8>>,
) -> Result<Vec<u8>, CartridgeError> {
    let html = export_standalone_html(manifest_source, project_files)?;
    zip_stored_file("index.html", html.as_bytes())
}

fn standalone_presentation(entries: &BTreeMap<String, Vec<u8>>) -> StandalonePresentation {
    let parsed = entries
        .get("presentation/cartridge.json")
        .and_then(|bytes| serde_json::from_slice::<serde_json::Value>(bytes).ok());
    let year = parsed
        .as_ref()
        .and_then(|value| value.get("year"))
        .and_then(serde_json::Value::as_u64)
        .and_then(|value| u16::try_from(value).ok())
        .filter(|value| (1970..=9999).contains(value))
        .unwrap_or(1999);
    let players = parsed
        .as_ref()
        .and_then(|value| value.get("players"))
        .and_then(serde_json::Value::as_u64)
        .and_then(|value| u8::try_from(value).ok())
        .filter(|value| (1..=4).contains(value))
        .unwrap_or(1);
    let controls = parsed
        .as_ref()
        .and_then(|value| value.get("controls"))
        .and_then(serde_json::Value::as_str)
        .filter(|value| value.len() <= 64 && value.is_ascii())
        .unwrap_or("PAD")
        .to_owned();
    StandalonePresentation {
        year,
        players,
        controls,
    }
}

fn zip_stored_file(name: &str, contents: &[u8]) -> Result<Vec<u8>, CartridgeError> {
    let size = u32::try_from(contents.len())
        .map_err(|_| export_error("standalone player exceeds ZIP32".to_owned()))?;
    let name_length = u16::try_from(name.len())
        .map_err(|_| export_error("standalone ZIP name is too long".to_owned()))?;
    let checksum = crc32(contents);
    let mut local = Vec::with_capacity(30 + name.len() + contents.len());
    write_u32(&mut local, 0x0403_4b50);
    write_u16(&mut local, 20);
    write_u16(&mut local, 0x0800);
    write_u16(&mut local, 0);
    write_u16(&mut local, 0);
    write_u16(&mut local, 0);
    write_u32(&mut local, checksum);
    write_u32(&mut local, size);
    write_u32(&mut local, size);
    write_u16(&mut local, name_length);
    write_u16(&mut local, 0);
    local.extend_from_slice(name.as_bytes());
    local.extend_from_slice(contents);
    let local_length = u32::try_from(local.len())
        .map_err(|_| export_error("standalone ZIP exceeds ZIP32".to_owned()))?;

    let mut central = Vec::with_capacity(46 + name.len());
    write_u32(&mut central, 0x0201_4b50);
    write_u16(&mut central, 20);
    write_u16(&mut central, 20);
    write_u16(&mut central, 0x0800);
    write_u16(&mut central, 0);
    write_u16(&mut central, 0);
    write_u16(&mut central, 0);
    write_u32(&mut central, checksum);
    write_u32(&mut central, size);
    write_u32(&mut central, size);
    write_u16(&mut central, name_length);
    write_u16(&mut central, 0);
    write_u16(&mut central, 0);
    write_u16(&mut central, 0);
    write_u16(&mut central, 0);
    write_u32(&mut central, 0);
    write_u32(&mut central, 0);
    central.extend_from_slice(name.as_bytes());
    let central_length = u32::try_from(central.len())
        .map_err(|_| export_error("standalone ZIP exceeds ZIP32".to_owned()))?;

    let mut output = local;
    output.extend_from_slice(&central);
    write_u32(&mut output, 0x0605_4b50);
    write_u16(&mut output, 0);
    write_u16(&mut output, 0);
    write_u16(&mut output, 1);
    write_u16(&mut output, 1);
    write_u32(&mut output, central_length);
    write_u32(&mut output, local_length);
    write_u16(&mut output, 0);
    Ok(output)
}

fn write_u16(output: &mut Vec<u8>, value: u16) {
    output.extend_from_slice(&value.to_le_bytes());
}

fn write_u32(output: &mut Vec<u8>, value: u32) {
    output.extend_from_slice(&value.to_le_bytes());
}

fn crc32(bytes: &[u8]) -> u32 {
    let mut crc = u32::MAX;
    for byte in bytes {
        crc ^= u32::from(*byte);
        for _ in 0..8 {
            crc = (crc >> 1) ^ (0xedb8_8320 & 0_u32.wrapping_sub(crc & 1));
        }
    }
    crc ^ u32::MAX
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

    use super::{base64, export_itch_zip, export_standalone_html};

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
        assert!(first.contains("id=\"fullscreen\""));
        assert!(first.contains("name=\"px240c-embed\""));
        assert!(first.contains("source/src/main.pxl"));
        assert!(first.contains(&base64(&files["src/main.pxl"])));
        assert!(first.contains("\"rom\":\"UFgyNDBD"));
        assert!(first.contains("createConsoleRuntime"));
        assert!(!first.contains("https://"));
        assert!(!first.contains("SCRIPT </script> TEST"));
        assert!(first.contains("SCRIPT &lt;/script&gt; TEST"));

        let zip = export_itch_zip(&manifest, &files).expect("project ZIP exports");
        assert_eq!(&zip[..4], &[0x50, 0x4b, 0x03, 0x04]);
        assert_eq!(
            zip,
            export_itch_zip(&manifest, &files).expect("ZIP exports again")
        );
        assert!(
            zip.windows(first.len())
                .any(|window| window == first.as_bytes())
        );
    }
}
