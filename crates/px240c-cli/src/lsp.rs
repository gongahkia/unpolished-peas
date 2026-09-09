use std::{
    collections::BTreeMap,
    io::{self, BufRead, BufReader, Write},
    process::ExitCode,
};

use pxcl_core::{
    AssetCatalog, Diagnostic, FileId, SourceFile, Span, TokenKind, analyze_module, lex,
};
use serde_json::{Value, json};

const MAX_MESSAGE_BYTES: usize = 8 * 1024 * 1024;
const KEYWORDS: &[&str] = &[
    "and", "as", "assert", "break", "case", "const", "continue", "draw", "elif", "else", "enum",
    "false", "fn", "for", "if", "import", "in", "let", "match", "none", "not", "on", "or",
    "raster", "record", "return", "start", "state", "task", "true", "update", "var", "wait",
    "while",
];
const BUILTINS: &[(&str, &str)] = &[
    ("clear", "fn clear(color: Color)"),
    ("pixel", "fn pixel(x: Int, y: Int, color: Color)"),
    (
        "line",
        "fn line(x0: Int, y0: Int, x1: Int, y1: Int, color: Color)",
    ),
    (
        "rect",
        "fn rect(x: Int, y: Int, width: Int, height: Int, color: Color)",
    ),
    (
        "rect_fill",
        "fn rect_fill(x: Int, y: Int, width: Int, height: Int, color: Color)",
    ),
    (
        "circle",
        "fn circle(x: Int, y: Int, radius: Int, color: Color)",
    ),
    (
        "circle_fill",
        "fn circle_fill(x: Int, y: Int, radius: Int, color: Color)",
    ),
    (
        "triangle",
        "fn triangle(x0: Int, y0: Int, x1: Int, y1: Int, x2: Int, y2: Int, color: Color)",
    ),
    (
        "print",
        "fn print(text: Text, x: Int, y: Int, color: Color)",
    ),
    ("camera", "fn camera(x: Int, y: Int)"),
    ("clip", "fn clip(x: Int, y: Int, width: Int, height: Int)"),
    ("clip_reset", "fn clip_reset()"),
    ("pal", "fn pal(from: Color, to: Color)"),
    ("pal_reset", "fn pal_reset()"),
    ("raster_scroll", "fn raster_scroll(x: Int, y: Int)"),
    (
        "dither",
        "fn dither(x: Int, y: Int, first: Color, second: Color, level: Int) -> Color",
    ),
    ("sprite", "fn sprite(asset: Sprite, x: Int, y: Int)"),
    (
        "sprite_xform",
        "fn sprite_xform(asset: Sprite, x: Int, y: Int, scale: Int, turns: Int, flip_x: Bool, flip_y: Bool)",
    ),
    (
        "animation",
        "fn animation(asset: Animation, frame: Int, x: Int, y: Int)",
    ),
    ("map", "fn map(asset: Map, x: Int, y: Int)"),
    (
        "map_cell",
        "fn map_cell(asset: Map, layer: Int, x: Int, y: Int) -> Int",
    ),
    (
        "map_flag",
        "fn map_flag(asset: Map, layer: Int, x: Int, y: Int, flag: Int) -> Bool",
    ),
    ("btn", "fn btn(port: Controller, button: Button) -> Bool"),
    ("btnp", "fn btnp(port: Controller, button: Button) -> Bool"),
    ("rng_int", "fn rng_int(min: Int, max: Int) -> Int"),
    ("rng_num", "fn rng_num() -> Num"),
    (
        "save_get_int",
        "fn save_get_int(key: Text, fallback: Int) -> Int",
    ),
    ("save_set_int", "fn save_set_int(key: Text, value: Int)"),
    ("save_commit", "fn save_commit()"),
    ("sfx", "fn sfx(sound: Sound)"),
    ("music", "fn music(track: Music)"),
    ("music_stop", "fn music_stop()"),
    ("Vec2", "fn Vec2(x: Num, y: Num) -> Vec2"),
    (
        "Rect",
        "fn Rect(x: Num, y: Num, width: Num, height: Num) -> Rect",
    ),
];
const VALUES: &[(&str, &str)] = &[
    ("pad1", "Controller"),
    ("pad2", "Controller"),
    ("pad3", "Controller"),
    ("pad4", "Controller"),
    ("up", "Button"),
    ("down", "Button"),
    ("left", "Button"),
    ("right", "Button"),
    ("a", "Button"),
    ("b", "Button"),
    ("x", "Button"),
    ("y", "Button"),
    ("l", "Button"),
    ("r", "Button"),
    ("start_button", "Button"),
    ("menu", "Button"),
];

#[derive(Debug)]
struct Document {
    text: String,
    version: i64,
}

#[derive(Debug, Default)]
struct Server {
    documents: BTreeMap<String, Document>,
    shutdown_requested: bool,
}

pub fn run() -> ExitCode {
    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut reader = BufReader::new(stdin.lock());
    let mut writer = stdout.lock();
    let mut server = Server::default();
    loop {
        match read_message(&mut reader) {
            Ok(Some(message)) => {
                let should_exit = server.handle(&message, &mut writer);
                if should_exit {
                    return if server.shutdown_requested {
                        ExitCode::SUCCESS
                    } else {
                        ExitCode::FAILURE
                    };
                }
            }
            Ok(None) => return ExitCode::SUCCESS,
            Err(error) => {
                eprintln!("px240c lsp: {error}");
                return ExitCode::FAILURE;
            }
        }
    }
}

impl Server {
    fn handle(&mut self, message: &Value, writer: &mut impl Write) -> bool {
        let method = message.get("method").and_then(Value::as_str);
        let id = message.get("id");
        match method {
            Some("initialize") => respond(
                writer,
                id,
                &json!({
                    "capabilities": {
                        "textDocumentSync": 1,
                        "completionProvider": { "triggerCharacters": ["#"] },
                        "hoverProvider": true,
                        "definitionProvider": true,
                        "referencesProvider": true,
                        "renameProvider": { "prepareProvider": false }
                    },
                    "serverInfo": { "name": "px240c", "version": env!("CARGO_PKG_VERSION") }
                }),
            ),
            Some("initialized") => {}
            Some("shutdown") => {
                self.shutdown_requested = true;
                respond(writer, id, &Value::Null);
            }
            Some("exit") => return true,
            Some("textDocument/didOpen") => self.did_open(message, writer),
            Some("textDocument/didChange") => self.did_change(message, writer),
            Some("textDocument/didClose") => self.did_close(message, writer),
            Some("textDocument/completion") => {
                respond(writer, id, &completion_items());
            }
            Some("textDocument/hover") => {
                let result = self.symbol_request(message).and_then(|(_, _, symbol)| {
                    hover_text(&symbol).map(|contents| json!({ "contents": contents }))
                });
                respond(writer, id, &result.unwrap_or(Value::Null));
            }
            Some("textDocument/definition") => {
                let result = self
                    .symbol_request(message)
                    .and_then(|(uri, source, symbol)| {
                        definition_span(&source, &symbol).map(|span| location(&uri, &source, span))
                    });
                respond(writer, id, &result.unwrap_or(Value::Null));
            }
            Some("textDocument/references") => {
                let result = self
                    .symbol_request(message)
                    .map(|(uri, source, symbol)| {
                        identifier_spans(&source, &symbol)
                            .into_iter()
                            .map(|span| location(&uri, &source, span))
                            .collect::<Vec<_>>()
                    })
                    .unwrap_or_default();
                respond(writer, id, &json!(result));
            }
            Some("textDocument/rename") => {
                let new_name = message
                    .pointer("/params/newName")
                    .and_then(Value::as_str)
                    .filter(|name| valid_identifier(name));
                let result = self
                    .symbol_request(message)
                    .and_then(|(uri, source, symbol)| {
                        new_name.map(|name| {
                            let edits = identifier_spans(&source, &symbol)
                                .into_iter()
                                .map(|span| {
                                    json!({ "range": range(&source, span), "newText": name })
                                })
                                .collect::<Vec<_>>();
                            let changes = BTreeMap::from([(uri, edits)]);
                            json!({ "changes": changes })
                        })
                    });
                respond(writer, id, &result.unwrap_or(Value::Null));
            }
            Some(method) if id.is_some() => send_error(writer, id, -32601, method),
            _ => {}
        }
        false
    }

    fn did_open(&mut self, message: &Value, writer: &mut impl Write) {
        let Some(uri) = message
            .pointer("/params/textDocument/uri")
            .and_then(Value::as_str)
        else {
            return;
        };
        let Some(text) = message
            .pointer("/params/textDocument/text")
            .and_then(Value::as_str)
        else {
            return;
        };
        let version = message
            .pointer("/params/textDocument/version")
            .and_then(Value::as_i64)
            .unwrap_or(0);
        self.documents.insert(
            uri.to_owned(),
            Document {
                text: text.to_owned(),
                version,
            },
        );
        self.publish_diagnostics(writer, uri);
    }

    fn did_change(&mut self, message: &Value, writer: &mut impl Write) {
        let Some(uri) = message
            .pointer("/params/textDocument/uri")
            .and_then(Value::as_str)
        else {
            return;
        };
        let Some(text) = message
            .pointer("/params/contentChanges/0/text")
            .and_then(Value::as_str)
        else {
            return;
        };
        let version = message
            .pointer("/params/textDocument/version")
            .and_then(Value::as_i64)
            .unwrap_or(0);
        self.documents.insert(
            uri.to_owned(),
            Document {
                text: text.to_owned(),
                version,
            },
        );
        self.publish_diagnostics(writer, uri);
    }

    fn did_close(&mut self, message: &Value, writer: &mut impl Write) {
        let Some(uri) = message
            .pointer("/params/textDocument/uri")
            .and_then(Value::as_str)
        else {
            return;
        };
        self.documents.remove(uri);
        notify(
            writer,
            "textDocument/publishDiagnostics",
            &json!({ "uri": uri, "diagnostics": [] }),
        );
    }

    fn publish_diagnostics(&self, writer: &mut impl Write, uri: &str) {
        let Some(document) = self.documents.get(uri) else {
            return;
        };
        let source = SourceFile::new(FileId(0), uri, document.text.clone());
        let diagnostics = analyze_module(&source, &AssetCatalog::default())
            .diagnostics
            .iter()
            .map(|diagnostic| lsp_diagnostic(&source, diagnostic))
            .collect::<Vec<_>>();
        notify(
            writer,
            "textDocument/publishDiagnostics",
            &json!({ "uri": uri, "version": document.version, "diagnostics": diagnostics }),
        );
    }

    fn symbol_request(&self, message: &Value) -> Option<(String, SourceFile, String)> {
        let uri = message
            .pointer("/params/textDocument/uri")?
            .as_str()?
            .to_owned();
        let document = self.documents.get(&uri)?;
        let source = SourceFile::new(FileId(0), uri.clone(), document.text.clone());
        let line = u32::try_from(message.pointer("/params/position/line")?.as_u64()?).ok()?;
        let character =
            u32::try_from(message.pointer("/params/position/character")?.as_u64()?).ok()?;
        let offset = offset_at(&source, line, character)?;
        let symbol = lex(&source).tokens.into_iter().find_map(|token| {
            if (token.span.contains(offset)
                || (token.span.end == offset && token.span.start < offset))
                && let TokenKind::Identifier(name) = token.kind
            {
                return Some(name);
            }
            None
        })?;
        Some((uri, source, symbol))
    }
}

fn respond(writer: &mut impl Write, id: Option<&Value>, result: &Value) {
    let Some(id) = id else {
        return;
    };
    write_message(
        writer,
        &json!({ "jsonrpc": "2.0", "id": id, "result": result }),
    );
}

fn send_error(writer: &mut impl Write, id: Option<&Value>, code: i32, method: &str) {
    let Some(id) = id else {
        return;
    };
    write_message(
        writer,
        &json!({
            "jsonrpc": "2.0",
            "id": id,
            "error": { "code": code, "message": format!("unsupported LSP method '{method}'") }
        }),
    );
}

fn read_message(reader: &mut impl BufRead) -> Result<Option<Value>, String> {
    let mut content_length = None;
    loop {
        let mut line = String::new();
        let bytes = reader
            .read_line(&mut line)
            .map_err(|error| error.to_string())?;
        if bytes == 0 {
            return if content_length.is_none() {
                Ok(None)
            } else {
                Err("unexpected EOF in LSP headers".to_owned())
            };
        }
        if line == "\r\n" || line == "\n" {
            break;
        }
        if let Some((name, value)) = line.split_once(':')
            && name.eq_ignore_ascii_case("content-length")
        {
            content_length = Some(
                value
                    .trim()
                    .parse::<usize>()
                    .map_err(|_| "invalid LSP Content-Length".to_owned())?,
            );
        }
    }
    let length = content_length.ok_or_else(|| "missing LSP Content-Length".to_owned())?;
    if length > MAX_MESSAGE_BYTES {
        return Err("LSP message exceeds 8 MiB".to_owned());
    }
    let mut bytes = vec![0_u8; length];
    reader
        .read_exact(&mut bytes)
        .map_err(|error| error.to_string())?;
    serde_json::from_slice(&bytes)
        .map(Some)
        .map_err(|error| error.to_string())
}

fn write_message(writer: &mut impl Write, value: &Value) {
    let Ok(bytes) = serde_json::to_vec(value) else {
        return;
    };
    if write!(writer, "Content-Length: {}\r\n\r\n", bytes.len()).is_ok()
        && writer.write_all(&bytes).is_ok()
    {
        let _ = writer.flush();
    }
}

fn notify(writer: &mut impl Write, method: &str, params: &Value) {
    write_message(
        writer,
        &json!({ "jsonrpc": "2.0", "method": method, "params": params }),
    );
}

fn completion_items() -> Value {
    let keywords = KEYWORDS
        .iter()
        .map(|label| json!({ "label": label, "kind": 14 }));
    let builtins = BUILTINS
        .iter()
        .map(|(label, detail)| json!({ "label": label, "kind": 3, "detail": detail }));
    let values = VALUES
        .iter()
        .map(|(label, detail)| json!({ "label": label, "kind": 21, "detail": detail }));
    Value::Array(keywords.chain(builtins).chain(values).collect())
}

fn hover_text(symbol: &str) -> Option<Value> {
    if let Some((_, signature)) = BUILTINS.iter().find(|(name, _)| *name == symbol) {
        return Some(json!({ "kind": "markdown", "value": format!("```pxcl\n{signature}\n```") }));
    }
    if let Some((_, r#type)) = VALUES.iter().find(|(name, _)| *name == symbol) {
        return Some(json!({ "kind": "plaintext", "value": format!("{symbol}: {type}") }));
    }
    KEYWORDS
        .contains(&symbol)
        .then(|| json!({ "kind": "plaintext", "value": format!("PXCL/1 keyword `{symbol}`") }))
        .or_else(|| {
            Some(json!({ "kind": "plaintext", "value": format!("PXCL symbol `{symbol}`") }))
        })
}

fn definition_span(source: &SourceFile, symbol: &str) -> Option<Span> {
    let tokens = lex(source).tokens;
    for pair in tokens.windows(2) {
        if is_definition_prefix(&pair[0].kind)
            && matches!(&pair[1].kind, TokenKind::Identifier(name) if name == symbol)
        {
            return Some(pair[1].span);
        }
    }
    for window in tokens.windows(3) {
        if matches!(&window[0].kind, TokenKind::LeftParen | TokenKind::Comma)
            && matches!(&window[1].kind, TokenKind::Identifier(name) if name == symbol)
            && matches!(window[2].kind, TokenKind::Colon)
        {
            return Some(window[1].span);
        }
    }
    None
}

fn is_definition_prefix(kind: &TokenKind) -> bool {
    matches!(
        kind,
        TokenKind::Const
            | TokenKind::State
            | TokenKind::Let
            | TokenKind::Var
            | TokenKind::Fn
            | TokenKind::Task
            | TokenKind::Record
            | TokenKind::Enum
    )
}

fn identifier_spans(source: &SourceFile, symbol: &str) -> Vec<Span> {
    lex(source)
        .tokens
        .into_iter()
        .filter_map(|token| match token.kind {
            TokenKind::Identifier(name) if name == symbol => Some(token.span),
            _ => None,
        })
        .collect()
}

fn lsp_diagnostic(source: &SourceFile, diagnostic: &Diagnostic) -> Value {
    json!({
        "range": range(source, diagnostic.primary.span),
        "severity": 1,
        "code": diagnostic.code,
        "source": "pxcl",
        "message": diagnostic.message
    })
}

fn location(uri: &str, source: &SourceFile, span: Span) -> Value {
    json!({ "uri": uri, "range": range(source, span) })
}

fn range(source: &SourceFile, span: Span) -> Value {
    let start = source.line_column(span.start);
    let end = source.line_column(span.end);
    json!({
        "start": { "line": start.line, "character": start.column },
        "end": { "line": end.line, "character": end.column }
    })
}

fn offset_at(source: &SourceFile, line: u32, character: u32) -> Option<u32> {
    let mut offset = 0_u32;
    for (index, text_line) in source.text().split_inclusive('\n').enumerate() {
        if u32::try_from(index).ok()? == line {
            let content_length = u32::try_from(text_line.trim_end_matches('\n').len()).ok()?;
            return (character <= content_length).then_some(offset + character);
        }
        offset = offset.checked_add(u32::try_from(text_line.len()).ok()?)?;
    }
    (line == 0 && source.text().is_empty() && character == 0).then_some(0)
}

fn valid_identifier(value: &str) -> bool {
    let mut bytes = value.bytes();
    bytes
        .next()
        .is_some_and(|byte| byte.is_ascii_alphabetic() || byte == b'_')
        && bytes.all(|byte| byte.is_ascii_alphanumeric() || byte == b'_')
        && !KEYWORDS.contains(&value)
}
