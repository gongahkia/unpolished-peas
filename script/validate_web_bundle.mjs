import assert from "node:assert/strict";
import {createHash} from "node:crypto";
import {readFile, access} from "node:fs/promises";
import {constants} from "node:fs";

const root = process.argv[2];
assert.ok(root);
for (const path of ["index.html", "bootstrap.mjs", "host.mjs", "input.mjs", "audio.mjs", "storage.mjs", "artifacts.mjs", "renderer_diagnostics.mjs", "renderer_selection.mjs", "webgpu_backend.mjs", "workload_runner.mjs", "workloads-v1.json", "unpolished-peas.wasm", "web-manifest.json", "SHA256SUMS"]) await access(`${root}/${path}`, constants.R_OK);
assert.deepEqual([...await readFile(`${root}/unpolished-peas.wasm`)].slice(0, 4), [0, 97, 115, 109]);
const manifest = JSON.parse(await readFile(`${root}/web-manifest.json`, "utf8"));
assert.deepEqual(manifest, {version: 1, platform: "web", game: manifest.game, entry: "index.html", runtime: "unpolished-peas.wasm", assets: "assets/", renderer_selection: "query:auto|webgpu|webgl2"});
assert.ok(["bounce", "topdown"].includes(manifest.game));
const workloads = JSON.parse(await readFile(`${root}/workloads-v1.json`, "utf8"));
assert.equal(workloads.schema_version, 1);
assert.equal(workloads.workload_version, "v1");
assert.equal(workloads.workloads.length, 6);
const html = await readFile(`${root}/index.html`, "utf8");
assert.match(html, /bootstrap\.mjs/);
assert.match(html, new RegExp(`data-game="${manifest.game}"`));
const checksums = (await readFile(`${root}/SHA256SUMS`, "utf8")).trim().split("\n");
assert.ok(checksums.length > 0);
const listed = new Set();
for (const line of checksums) {
  const match = /^([a-f0-9]{64})  \.\/([^/].*)$/.exec(line);
  assert.ok(match);
  const [, expected, path] = match;
  assert.ok(!path.includes(".."));
  assert.ok(!listed.has(path));
  listed.add(path);
  assert.equal(createHash("sha256").update(await readFile(`${root}/${path}`)).digest("hex"), expected);
}
assert.ok(listed.has("unpolished-peas.wasm"));
assert.ok(listed.has("web-manifest.json"));
