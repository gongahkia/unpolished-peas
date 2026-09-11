# V1 release-candidate evidence

This is the reproducible closing record for the PX-240C V1 product pass. The implementation began
at `e39be5a` and the final release-candidate commit is recorded in `docs/PROGRESS.md`. Nothing in
this pass was pushed, published or deployed.

## Hardware and formats

Hardware Revision 1 freezes a 22-bit, little-endian, non-mirrored address space. The complete table,
field encodings, timing, reset state, permissions, work charges and fault codes are in
[HARDWARE.md](HARDWARE.md). Its major regions are work RAM `00000`, front/back/resolved indexed
frames `10000`/`19000`/`22000`, the 128 KiB visual image `30000`, draw/palette/input/system/
allocation/raster/save/cartridge/audio registers from `50000`, scanline records `55000`, 8 KiB
working/committed saves `58000`/`5a000`, canonical ROM `60000`, visual descriptors `a0000` and
`c0000`, and audio descriptors `3c0000`. Unmapped reads return zero; writes fault.

The canonical cartridge remains format revision 1. Optional `compile_on_load` carts retain editable
source and a generated-code identity while omitting redundant generated payloads. `.pxc.png` stores
the byte-exact canonical cart in a CRC-checked `pxCa` chunk, HTML and ZIP embed the same verified
cart and production-core Worker, and `.pxrec` plus `.pxsave` are bounded revision-1 envelopes.

## Before and after measurements

Alpha values are immutable measurements from `tests/fixtures/alpha`; V1 values come from the final
`px240c info` section accountant. V1 profile values below use an empty 60-frame input. The archived
intentional gameplay paths still match all 720 alpha framebuffer/state/work/command observations
and their PCM goldens.

| Cart           | Alpha cart | V1 cart | Alpha generated | V1 generated | Alpha visual | V1 visual | V1 empty work/draw/voice | V1 mapped bus |
| -------------- | ---------: | ------: | --------------: | -----------: | -----------: | --------: | -----------------------: | ------------: |
| Cinder Circuit |     42,121 |  42,904 |          13,896 |       14,689 |        9,766 |    10,695 |          10,477 / 90 / 0 |       366,905 |
| Ashvault       |     40,532 |  41,315 |          18,832 |       19,623 |          288 |       908 |          13,485 / 84 / 0 |       365,204 |
| Raster Rush 99 |     37,311 |  38,091 |          16,546 |       17,337 |          160 |       440 |          11,326 / 21 / 0 |       361,868 |

The intentional alpha/V1 gameplay path peaks are work 10,477/19,140/31,722, draw commands
90/120/470, audio commands 1/3/1 and active voices 4/5/5 for Cinder/Ashvault/Raster. Their final
indexed framebuffer hashes remain
`37e05608feb0c99751e17cd08dd74d62eb5bd100230a56c67eaed68c71daf9fe`,
`db03fc95a5688bd95055ae2ae8700f71145ea1198a0e5a5b255059ee01c61b9c`, and
`05e33801457c0d6e38f6a7ff29a8a1703041917bc7ef55d186f958aba5b2ef53`; PCM hashes remain
`e730e962afdbfababa536a4033191333bcc322f3fee3cbe8b4d1547982b11ff4`,
`93930135d6ff547b724f2ed02dcae2c10b647e1f481d47199ed5e30d6c2dc2f7`, and
`e948a02c45835d7d5ed6272d5d12533f99624e0da908582460a1807fe06af25d`.

The alpha production bundle was 121,103-byte main JS, 18,722-byte Worker JS, 12,372-byte CSS and
1,165,346-byte Wasm. V1 is 304,594-byte main JS with the locked-down Worker inlined, 16,825-byte
CSS, 1,427,662-byte Wasm and 1,272-byte generated service worker. SHA-256 values are
`edb9bd12619fb231573ff39df630f8bf4e9036edefd69902d23dcce9f1b741b7`,
`417c154c1830f85845140f174a52240f1ca4f683dc2e9339ed8f92fc63aa88e7`,
`cd4a7ef2a3e78af2cd1d2fae522556347464264ec4f02ace6e72ed14909c7ad3`, and
`0b1e2a3f91f1553d4d5564aadc3f411ea6f28ddd823f417123fd057b2352ef41`. Generated headless and
standalone hosts are 163,418 and 197,096 bytes.

The alpha split-module edit/save/run/first-render warm median was 282.11 ms. The final two-module
`examples/api-tour` median is **211.48 ms** (ten warm Firefox samples, cold 593.71 ms), including
revision-safe save, deterministic restart, compile, inline Worker boot and first rendered frame.
`node scripts/measure-v1-latency.mjs` reproduces it against a local production preview.

## Deterministic release artifacts

`scripts/verify-release-artifacts.sh` packs and exports every first-party cart twice, byte-compares
raw/PNG/HTML/ZIP pairs, validates each PNG, and boots each raw cart for five headless frames.

| Cartridge             |  Bytes | `.pxc` SHA-256                                                     | `.pxc.png` SHA-256                                                 | HTML SHA-256                                                       | ZIP SHA-256                                                        |
| --------------------- | -----: | ------------------------------------------------------------------ | ------------------------------------------------------------------ | ------------------------------------------------------------------ | ------------------------------------------------------------------ |
| Cinder Circuit        | 42,904 | `225f164cc7cb9a891b353fb41df025d7a4d9be09ef713888c4f7a8b766408ea8` | `92be98e7ff7f0f1b541b73614feaab2e67528bcbbd63f05b8c5a03f2da761055` | `4232fa1a74542939c829f0394b31ebc16fc56597e9d7eaadff3f63a540751566` | `4036e384df1bed4c86224c227ea188c108640f55a8763ebe40337f8c5a00e039` |
| Ashvault              | 41,315 | `44abf7399348c4790de27ad316d63fcfea1c064e3c99980c644026e75d604986` | `09ea6a29503b8d7938ab8f9b7398f495e8f57294819f7eaa35ead0e13a4cbe31` | `9b77b45b0232b5bbb3524b86f5594d0041ae4c8c23e5322bbf92369a5c06ce67` | `e0c7d0331c7d41f7dc46e9c4a793c0823ae39ac166b93065e81a3d4ae0db973a` |
| Raster Rush 99        | 38,091 | `3f4172ea7f5538d860143f555a9243dac38449e4a51cabffab8b2279ab41d5b1` | `6faee5f768b6917c8a07f98ec972f61a1bc444eb39ec803a62c4cb6a94f98f6e` | `112ef5036414fcc6200fb9df86f07b3b31f23baaecdabf50c0f2a06767dfdc5d` | `51986b39733072217cc455e6649d3a83cf03d62381b8ea44b68f3cab76acf208` |
| Service cartridge     | 27,869 | `0175b0e7d06bd401ee48ef695b095cdbdf78a0832b1acd9dc88648322a0f12b8` | `2b5498d698c6eeaa91fa05fca81651341c798ebd3384da84c2e1c38587f6baf6` | `70b9eab55f9b8c3fb4dfb800d161f963991ab7b2af56e139aca44b58c96a5efa` | `49185b680c7573b0d26acd3a82de1bd2b0aa551e2d3e72eb0b3d742d966c45e3` |
| Signal 4K             |  2,364 | `8025fd248b327a41b1d2a983fba2f1339c99ef507ef78a77ba7c01dd71c23b05` | `bce59f4e993328d685b3c029acc6be1dbfd55b2e18cd247b97f3005a632f29f2` | `8b4bacaf64386c5a95372b7fb07ecfa6ecb7cebf4f1263f8a286d5e600cec34b` | `60b1a45a7a93a95101b0d2a80af95eb01a188a867f6620c061c4eebb021ce5a6` |
| Pocket Relay          |  4,609 | `6d36d38187f30ea08e7b25f7492104543231e061900d86b03af4a596cea75ea2` | `5f8ee18a560a35086667571390da94475c57dee105c96b6388c148849e552ea9` | `a71d2b1a10d55af38d03b8b6bf90f5af555c66711118f2598bf47ba6280e1f6b` | `2a6c4af8eab514a7a64204357ea082be5403d125d1c8a3b1ae0973222400828d` |
| Hardware Gauntlet     |  4,619 | `903aa05766b0c5ef88a7f85340e05a721da923a569cbbf6da2625a94d832afdf` | `998fd2fbb1cdfca8b03c6fed63d1f941db4368eb221e216735b6ee2c711037c2` | `2dc0aa4f0c367413315d6e447ecbe8e189eea8cb1c98db85ccbc7c9f6d9917a9` | `0e7f645430c57cd3ebf6a118119a4c2c943945187e2b46933abc67c10e98b19b` |
| First Signal tutorial | 11,706 | `6bb0ed93462da3f4e82afb68b57afcac4a5538a53802fded8075c4ed1c2cb954` | `1ea0c13be798b69af05cbf679a6b26858f46533fc40cca79c3fba09727bda9fd` | `8a254e6843c60f68c085f83d83fd02b7b1a42ca9a658f77bca02935a35984fc2` | `82606c3015a9600dde37d1d41b8074daec52f92c8a3cfcb9cdaaf904dfe0780f` |

Canonical codec fixtures: PNG `c52601bf655b456ad11ef15bf558b902ec9003b205225d58d1d77d74951678be`,
GIF `be91301d85c0c8ba5c9f20ac0d37042224946f0e265bfd13eab744dd7871ef28`, 48 kHz PCM16 WAV
`094f8a60e627c49f6c6209704bd24bb3e6c64e0517cc938b05fee1360e85c503`, and deterministic ZIP
`cd29362199db5175e8d1a169d5a969809745eef09f4a735f218f2696cc896871`. Browser downloads parse and
round-trip raw carts, cart PNGs, native/scaled PNG captures, 30 fps GIF, `.pxrec`, WAV, standalone
HTML and ZIP. Directly inspected 240x144 and scaled Signal 4K captures are retained locally under
`output/playwright/v1-{firefox,chromium}-{native,scaled}.png`; the native output is free of host UI.

## Compatibility and security

The gate exercises the three raw alpha carts and 720 recorded frames, the gzip-preserved first-install
IndexedDB project, raw alpha save JSON, revision-0 replay JSON, snapshot revisions 1-5, old flat and
single-file PXCL, one-tileset maps, existing built-in font behavior and legacy standalone integer
saves. Migration writes a separate recovery key before a V1 record and never replaces the fixture.

Untrusted cartridge, PNG, map/font/audio JSON, URL fragment, replay, save, manifest, folder and
Worker-message boundaries have strict byte/count/dimension/depth/path/work checks. Imported archived
JavaScript is never executed. `pnpm audit --prod` reports no known vulnerabilities; `cargo audit`
0.22.2 scanned all 48 locked Rust dependencies against 1,243 advisories with no findings.

Firefox 155.0 (Playwright build 1543) and Chrome for Testing 153.0.8010.12 (Chromium build 1243)
pass the same clean-storage production workflow, including installable manifest/service-worker
control, cold offline reload, every built-in cart, editors, source debugger, persistence, capture,
distribution and zero post-boot run/capture/export HTTP requests. Safari was not available on this
macOS host and is not claimed.

## Intentional limits

- File System Access is opt-in and session-only. Timestamp/path/conflict logic is automated; browser
  picker approval remains a manual gesture, and unsupported browsers retain file/IndexedDB flows.
- Worker containment is a browser boundary, not operating-system process isolation.
- Optional synchronized replay-audio muxing is not emitted; deterministic standalone WAV and exact
  replay exports remain separate. Arbitrary samples are intentionally outside the synth contract.
- The fixed machine/non-goals remain: no accounts, backend, telemetry, cloud gallery, netplay,
  compatibility importers, package/plugin system, generic engine, alternate hardware, RGB/shaders,
  native desktop wrapper, or PX-240C license grant.
