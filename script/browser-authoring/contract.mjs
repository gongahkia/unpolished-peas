import assert from "node:assert/strict";
import {mkdtemp, readFile, rm, writeFile} from "node:fs/promises";
import {createServer} from "node:http";
import {tmpdir} from "node:os";
import {join} from "node:path";
import {SafariAdapter, prerequisiteFailure} from "./adapters.mjs";
import {frame, compareReference, readFrame, validateLoggingArtifacts} from "./checks.mjs";
import {WebDriver} from "../safari_webdriver.mjs";
import {execFile} from "node:child_process";
import {fileURLToPath} from "node:url";
import {promisify} from "node:util";

assert.equal(prerequisiteFailure(new Error("You must enable Allow remote automation")), true);
assert.equal(prerequisiteFailure(new Error("Executable doesn't exist")), true);
assert.equal(prerequisiteFailure(new Error("timed out waiting for physical movement")), false);
assert.equal(prerequisiteFailure(new Error("native/browser pixel mismatch")), false);

// A frame larger than the string-conversion chunk must survive JSON transport
// byte-for-byte, while existing callers still receive the original RGBA array.
const previousWindow = globalThis.window;
try {
  const gl = {drawingBufferWidth: 513, drawingBufferHeight: 17, RGBA: 0x1908, UNSIGNED_BYTE: 0x1401,
    readPixels: (_x, _y, _w, _h, _format, _type, pixels) => { for (let i = 0; i < pixels.length; i += 1) pixels[i] = (i * 17 + 3) % 256; },
    getError: () => 0, isContextLost: () => false};
  globalThis.window = {unpolishedPeas: {host: {captureFrame: () => null, context: () => gl}, runtime: {up_browser_protocol_failure_phase: () => -1}}};
  const array = readFrame({width: 513, height: 17});
  const compact = JSON.parse(JSON.stringify(readFrame({width: 513, height: 17, encoding: "base64"})));
  assert.deepEqual(Buffer.from(compact.rgba_base64, "base64"), Buffer.from(array.rgba));
  assert.equal(compact.rgba, undefined);
  assert.equal(array.rgba_base64, undefined);
  assert.throws(() => readFrame({width: 1, height: 1, encoding: "invalid"}), /unsupported/);
} finally {
  if (previousWindow === undefined) delete globalThis.window;
  else globalThis.window = previousWindow;
}

const directory = await mkdtemp(join(tmpdir(), "peas-authoring-contract-"));
try {
  const png = await readFile(new URL("../../examples/assets/ball.png", import.meta.url));
  const pixels = [10, 20, 30, 255];
  const base = {width: 1, height: 1, physicalWidth: png.readUInt32BE(16), physicalHeight: png.readUInt32BE(20), error: 0, contextLost: false, protocolFailure: -1, rgba: pixels, png: "data:image/png;base64," + png.toString("base64")};
  const reference = join(directory, "native.rgba");
  await writeFile(reference, Buffer.from(pixels));
  await compareReference({rgba: [11, 19, 30, 255]}, reference);
  await assert.rejects(compareReference({rgba: [12, 20, 30, 255]}, reference), /pixel mismatch/);
  await assert.rejects(compareReference({rgba: []}, reference), /size differs/);
  const empty = join(directory, "empty.rgba");
  await writeFile(empty, Buffer.alloc(0));
  await assert.rejects(compareReference({rgba: []}, empty), /empty native/);
  const driver = (name, available, value) => ({name, captureProbe: {png_capture_available: available}, evaluate: async () => value});
  await frame(driver("chromium", true, base), directory, "valid", 1, 1);
  await frame(driver("safari", false, {...base, png: null}), directory, "limited-safari", 1, 1);
  await assert.rejects(frame(driver("safari", true, {...base, png: null}), directory, "missing-safari", 1, 1), /PNG capture failed/);
  await assert.rejects(frame(driver("firefox", false, {...base, png: null}), directory, "missing-firefox", 1, 1), /PNG capture failed/);
  await assert.rejects(frame(driver("chromium", true, {...base, png: "data:image/png;base64,"}), directory, "empty-png", 1, 1), /invalid\/empty PNG/);
  await assert.rejects(frame(driver("safari", false, {...base, contextLost: true, png: null}), directory, "lost-context", 1, 1), /healthy/);
  await assert.rejects(frame(driver("safari", false, {...base, rgba: [], png: null}), directory, "empty-readback", 1, 1), /incomplete readback/);
  await assert.rejects(frame(driver("chromium", true, {...base, physicalWidth: 999}), directory, "wrong-size", 1, 1), /dimensions differ/);
} finally { await rm(directory, {recursive: true, force: true}); }

const requests = [];
let deleted = false, released = false, busy = false;
const server = createServer(async (request, response) => {
  let text = ""; for await (const chunk of request) text += chunk;
  const body = text ? JSON.parse(text) : null;
  requests.push({path: request.url, method: request.method, body});
  if (request.url === "/slow") { await new Promise((resolve) => setTimeout(resolve, 100)); }
  let value = null;
  if (request.url === "/status") value = {ready: !busy};
  else if (request.url === "/session") value = {sessionId: "contract", capabilities: {browserVersion: "fixture"}};
  else if (request.url === "/session/contract" && request.method === "DELETE") deleted = true;
  else if (request.url.endsWith("/execute/async")) value = {ok: false, message: "fixture script rejection"};
  else if (request.url.endsWith("/element")) value = {"element-6066-11e4-a52e-4f735466cecf": "text"};
  else if (request.url.endsWith("/actions") && request.method === "DELETE") released = true;
  response.writeHead(200, {"content-type": "application/json"});
  response.end(JSON.stringify({value}));
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const url = "http://127.0.0.1:" + server.address().port;
const adapter = new SafariAdapter(url);
try {
  await adapter.open();
  await assert.rejects(adapter.evaluate(() => { throw new Error("rejected"); }), /fixture script rejection/);
  await adapter.press("Space");
  await adapter.text("你好");
  await adapter.reload();
  assert.deepEqual(requests.filter((value) => value.path.endsWith("/actions") && value.method === "POST").map((value) => value.body.actions[0].actions[0]), [{type: "keyDown", value: "\ue00d"}]);
  assert.ok(released, "keyup must release the WebDriver input source");
  assert.deepEqual(requests.find((value) => value.path.endsWith("/value")).body, {text: "你好", value: ["你", "好"]});
  assert.ok(requests.some((value) => value.path.endsWith("/refresh")), "reload uses real navigation");
  await adapter.close();
  assert.ok(deleted && released, "sessions release input actions and close after failures");
  await assert.rejects(adapter.evaluate(() => true), /closed/);
  const timeout = new WebDriver(url, {requestTimeoutMs: 20});
  await assert.rejects(timeout.request("/slow"), /timeout|timed|aborted/i);
  busy = true;
  const artifacts = await mkdtemp(join(tmpdir(), "peas-authoring-unverified-"));
  const sessionsBefore = requests.filter((value) => value.path === "/session").length;
  try {
    const result = await promisify(execFile)(process.execPath, [fileURLToPath(new URL("./run.mjs", import.meta.url)), "--consumer", artifacts, "--browsers", "safari", "--diagnostics", join(artifacts, "evidence")], {env: {...process.env, UP_SAFARI_WEBDRIVER_URL: url}, timeout: 10000}).catch((error) => error);
    assert.equal(result.code, 69, "a missing prerequisite must never exit successfully");
    const report = JSON.parse(await readFile(join(artifacts, "evidence/result.json"), "utf8"));
    assert.equal(report.passed, false);
    assert.equal(report.results[0].status, "unverified");
    assert.match(report.results[0].cases[0].error, /already has an active session/);
    assert.equal(requests.filter((value) => value.path === "/session").length, sessionsBefore, "a busy driver must not create/replace another session");
  } finally { await rm(artifacts, {recursive: true, force: true}); }
} finally {
  await adapter.close();
  await new Promise((resolve) => server.close(resolve));
}
console.log("authoring browser contracts passed: PNG/readback/reference failures, Safari keys/text/error cleanup and request deadlines");

// A structurally valid file list is insufficient if events or terminal output
// were lost; retain these checks independently of browser availability.
const logArtifacts = [
  {name: "logging.json", data: JSON.stringify({events: {enabled: true, session_id: 7, sink_errors: 0}})},
  {name: "events.jsonl", data: ["engine", "render"].map((category) => JSON.stringify({version: 1, session_id: 7, frame_id: 0, timestamp_ns: 1, level: "info", category, message: "ok", fields: {}})).join("\n")},
];
assert.equal(validateLoggingArtifacts(logArtifacts).events, 2);
assert.throws(() => validateLoggingArtifacts([]), /must be enabled/);
assert.throws(() => validateLoggingArtifacts([{name: "logging.json", data: JSON.stringify({events: {enabled: true, session_id: 7, sink_errors: 1}})}, logArtifacts[1]]), /console output/);
assert.throws(() => validateLoggingArtifacts([logArtifacts[0], {name: "events.jsonl", data: "{"}]), SyntaxError);
