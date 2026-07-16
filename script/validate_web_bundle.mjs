import assert from "node:assert/strict";
import {readFile, access} from "node:fs/promises";
import {constants} from "node:fs";

const root = process.argv[2];
assert.ok(root);
for (const path of ["index.html", "bootstrap.mjs", "host.mjs", "input.mjs", "audio.mjs", "storage.mjs", "artifacts.mjs", "unpolished-peas.wasm", "web-manifest.json", "SHA256SUMS"]) await access(`${root}/${path}`, constants.R_OK);
assert.deepEqual([...await readFile(`${root}/unpolished-peas.wasm`)].slice(0, 4), [0, 97, 115, 109]);
const manifest = JSON.parse(await readFile(`${root}/web-manifest.json`, "utf8"));
assert.deepEqual(manifest, {version: 1, platform: "web", game: manifest.game, entry: "index.html", runtime: "unpolished-peas.wasm", assets: "assets/"});
assert.ok(["bounce", "topdown", "platformer"].includes(manifest.game));
const html = await readFile(`${root}/index.html`, "utf8");
assert.match(html, /bootstrap\.mjs/);
assert.match(html, new RegExp(`data-game="${manifest.game}"`));
