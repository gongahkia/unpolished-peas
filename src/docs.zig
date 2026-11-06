const std = @import("std");
const api_docs = @import("api_docs.zig");
const doc_bundle = @import("doc_bundle.zig");

const max_document_bytes = 1024 * 1024;
const source_documents = [_][]const u8{
    "index.md",
    "guides/quickstart.md",
    "guides/installation.md",
    "guides/platforms.md",
    "guides/portable-conformance.md",
    "guides/game-protocol.md",
    "guides/core-contract.md",
    "guides/rendering.md",
    "guides/render-surfaces.md",
    "guides/surface-composition-performance.md",
    "guides/advanced-2d.md",
    "guides/image-assets.md",
    "guides/authored-text-layout.md",
    "guides/asset-recipes.md",
    "guides/sprite-animation.md",
    "guides/audio-assets.md",
    "guides/save-data.md",
    "guides/input.md",
    "guides/input-v2-compatibility.md",
    "guides/testing.md",
    "guides/developer-diagnostics.md",
    "guides/developer-asset-reload.md",
    "guides/developer-tools.md",
    "guides/browser-development.md",
    "guides/authoring-experience-freeze.md",
    "guides/ci.md",
    "guides/browser-diagnostics.md",
    "guides/capabilities.md",
    "guides/migrations.md",
    "guides/releases.md",
};

const supplemental_documents = [_][]const u8{
    "README.md",
    "templates/starter/README.md",
    "dogfood/neon-siege/README.md",
    "dogfood/lantern-leap/README.md",
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var args = try std.process.argsWithAllocator(gpa.allocator());
    defer args.deinit();
    _ = args.next();
    const docs_root = args.next() orelse return usage();
    const api_source = args.next() orelse return usage();
    const output_root = args.next() orelse return usage();
    const mode = args.next();
    if (args.next() != null) return usage();
    if (mode) |value| {
        if (!std.mem.eql(u8, value, "--update-api")) return usage();
    }
    try emitMode(gpa.allocator(), docs_root, api_source, output_root, mode != null);
}

pub fn emit(allocator: std.mem.Allocator, docs_root: []const u8, api_source: []const u8, output_root: []const u8) !void {
    return emitMode(allocator, docs_root, api_source, output_root, false);
}

fn emitMode(allocator: std.mem.Allocator, docs_root: []const u8, api_source: []const u8, output_root: []const u8, update_api: bool) !void {
    const repository_root = std.fs.path.dirname(docs_root) orelse return error.InvalidDocsRoot;
    var generator = api_docs.Generator.init(allocator, repository_root, api_source);
    defer generator.deinit();
    const pages = try generator.generate();
    try validateApiPages(allocator, repository_root, pages);
    try validateExampleLinksWithPages(allocator, repository_root, docs_root, pages);
    try validateSupplementalLinksWithPages(allocator, repository_root, pages);
    if (update_api) {
        for (pages) |page| try writeApiPage(allocator, docs_root, page);
    }
    try std.fs.cwd().makePath(output_root);
    var bundle = doc_bundle.Bundle.init(allocator, repository_root, output_root, pages);
    defer bundle.deinit();
    for (source_documents) |relative_path| {
        const source = try std.fs.path.join(allocator, &.{ docs_root, relative_path });
        defer allocator.free(source);
        _ = try bundle.add(source);
    }
    for (pages) |page| {
        const source = try std.fs.path.join(allocator, &.{ docs_root, page.path });
        defer allocator.free(source);
        _ = try bundle.add(source);
    }
    // Check actual emitted files, not just links in the source checkout.
    var files = bundle.files.iterator();
    while (files.next()) |entry| {
        const path = entry.value_ptr.*;
        if (!std.mem.endsWith(u8, path, ".md")) continue;
        const document = try std.fs.cwd().readFileAlloc(allocator, path, max_document_bytes);
        defer allocator.free(document);
        try validateDocumentLinks(allocator, output_root, path, document);
    }
}

fn writeApiPage(allocator: std.mem.Allocator, root: []const u8, page: api_docs.Page) !void {
    const path = try std.fs.path.join(allocator, &.{ root, page.path });
    defer allocator.free(path);
    try std.fs.cwd().makePath(std.fs.path.dirname(path).?);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = page.contents });
}

fn validateApiPages(allocator: std.mem.Allocator, root: []const u8, pages: []const api_docs.Page) !void {
    for (pages) |page| {
        const path = try std.fs.path.join(allocator, &.{ root, "docs", page.path });
        defer allocator.free(path);
        try validateDocumentLinksWithPages(allocator, root, path, page.contents, pages);
    }
}

pub fn publicApiMarkdown(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    return api_docs.namespaceMarkdown(allocator, source);
}

pub fn validateExampleLinks(allocator: std.mem.Allocator, repository_root: []const u8, docs_root: []const u8) !void {
    return validateExampleLinksWithPages(allocator, repository_root, docs_root, &.{});
}

fn validateExampleLinksWithPages(allocator: std.mem.Allocator, repository_root: []const u8, docs_root: []const u8, pages: []const api_docs.Page) !void {
    var docs = try std.fs.openDirAbsolute(docs_root, .{ .iterate = true });
    defer docs.close();
    var walker = try docs.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".md")) continue;
        const document_path = try std.fs.path.join(allocator, &.{ docs_root, entry.path });
        defer allocator.free(document_path);
        const document = try std.fs.cwd().readFileAlloc(allocator, document_path, max_document_bytes);
        defer allocator.free(document);
        try validateDocumentLinksWithPages(allocator, repository_root, document_path, document, pages);
    }
}

fn validateSupplementalLinks(allocator: std.mem.Allocator, repository_root: []const u8) !void {
    return validateSupplementalLinksWithPages(allocator, repository_root, &.{});
}

fn validateSupplementalLinksWithPages(allocator: std.mem.Allocator, repository_root: []const u8, pages: []const api_docs.Page) !void {
    for (supplemental_documents) |relative_path| {
        const document_path = try std.fs.path.join(allocator, &.{ repository_root, relative_path });
        defer allocator.free(document_path);
        const document = try std.fs.cwd().readFileAlloc(allocator, document_path, max_document_bytes);
        defer allocator.free(document);
        try validateDocumentLinksWithPages(allocator, repository_root, document_path, document, pages);
    }
}

fn validateDocumentLinks(allocator: std.mem.Allocator, repository_root: []const u8, document_path: []const u8, document: []const u8) !void {
    return validateDocumentLinksWithPages(allocator, repository_root, document_path, document, &.{});
}

fn pageOverride(allocator: std.mem.Allocator, root: []const u8, path: []const u8, pages: []const api_docs.Page) !?[]const u8 {
    for (pages) |page| {
        const actual = try std.fs.path.resolve(allocator, &.{ root, "docs", page.path });
        defer allocator.free(actual);
        if (std.mem.eql(u8, path, actual)) return page.contents;
    }
    return null;
}

fn validateDocumentLinksWithPages(allocator: std.mem.Allocator, repository_root: []const u8, document_path: []const u8, original: []const u8, pages: []const api_docs.Page) !void {
    const document = (try pageOverride(allocator, repository_root, document_path, pages)) orelse original;
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, document, cursor, "](")) |link_start| {
        const target_start = link_start + 2;
        const link_end = std.mem.indexOfScalarPos(u8, document, target_start, ')') orelse return error.MalformedMarkdownLink;
        cursor = link_end + 1;
        const target = document[target_start..link_end];
        if (isExternalLink(target)) continue;
        const path_without_anchor = target[0..(std.mem.indexOfAny(u8, target, "#?") orelse target.len)];
        const document_directory = std.fs.path.dirname(document_path) orelse return error.InvalidDocsRoot;
        const linked_path = if (path_without_anchor.len == 0) try allocator.dupe(u8, document_path) else try std.fs.path.resolve(allocator, &.{ document_directory, path_without_anchor });
        defer allocator.free(linked_path);
        const override = try pageOverride(allocator, repository_root, linked_path, pages);
        if (override != null) {
            if (std.mem.indexOfScalar(u8, target, '#')) |hash| try requireAnchor(allocator, linked_path, override.?, target[hash + 1 ..]);
            continue;
        }
        std.fs.cwd().access(linked_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                std.debug.print("broken documentation link: {s} -> {s}\n", .{ document_path, linked_path });
                return error.BrokenDocumentationLink;
            },
            else => return err,
        };
        if (std.mem.endsWith(u8, linked_path, ".md")) {
            if (std.mem.indexOfScalar(u8, target, '#')) |hash| {
                const linked_document = try std.fs.cwd().readFileAlloc(allocator, linked_path, max_document_bytes);
                defer allocator.free(linked_document);
                try requireAnchor(allocator, linked_path, linked_document, target[hash + 1 ..]);
            }
        }
    }
}

fn requireAnchor(allocator: std.mem.Allocator, path: []const u8, document: []const u8, anchor: []const u8) !void {
    if (anchor.len == 0) return;
    const explicit = try std.fmt.allocPrint(allocator, "id=\"{s}\"", .{anchor});
    defer allocator.free(explicit);
    var lines = std.mem.splitScalar(u8, document, '\n');
    var fenced = false;
    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " ");
        if (std.mem.startsWith(u8, trimmed, "\x60\x60\x60") or std.mem.startsWith(u8, trimmed, "~~~")) {
            fenced = !fenced;
            continue;
        }
        if (fenced) continue;
        if (std.mem.startsWith(u8, trimmed, "<a ") and std.mem.indexOf(u8, trimmed, explicit) != null) return;
        if (!std.mem.startsWith(u8, trimmed, "#")) continue;
        const heading = std.mem.trimStart(u8, trimmed, "# ");
        var slug: std.ArrayList(u8) = .empty;
        defer slug.deinit(allocator);
        for (heading) |byte| {
            if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte >= 128) try slug.append(allocator, std.ascii.toLower(byte)) else if (byte == ' ') try slug.append(allocator, '-');
        }
        if (std.mem.eql(u8, slug.items, anchor)) return;
    }
    std.debug.print("broken documentation anchor: {s}#{s}\n", .{ path, anchor });
    return error.BrokenDocumentationAnchor;
}

fn isExternalLink(target: []const u8) bool {
    return std.mem.startsWith(u8, target, "https://") or
        std.mem.startsWith(u8, target, "http://") or
        std.mem.startsWith(u8, target, "mailto:") or
        std.mem.startsWith(u8, target, "data:");
}

fn markdownZigSnippet(document: []const u8, name: []const u8) ![]const u8 {
    var begin_marker_buffer: [128]u8 = undefined;
    const begin_marker = try std.fmt.bufPrint(&begin_marker_buffer, "<!-- BEGIN {s} -->\n```zig\n", .{name});
    var end_marker_buffer: [128]u8 = undefined;
    const end_marker = try std.fmt.bufPrint(&end_marker_buffer, "\n```\n<!-- END {s} -->", .{name});
    const begin = (std.mem.indexOf(u8, document, begin_marker) orelse return error.MissingDocumentationSnippet) + begin_marker.len;
    const end = std.mem.indexOfPos(u8, document, begin, end_marker) orelse return error.MissingDocumentationSnippet;
    return document[begin..end];
}

fn readLfFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const contents = try std.fs.cwd().readFileAlloc(allocator, path, max_document_bytes);
    defer allocator.free(contents);
    return std.mem.replaceOwned(u8, allocator, contents, "\r\n", "\n");
}

fn usage() error{InvalidArguments} {
    std.debug.print("usage: unpolished-peas-docs <docs-root> <public-api-source> <output-root> [--update-api]\n", .{});
    return error.InvalidArguments;
}

test "public API Markdown derives exported declarations" {
    const page = try publicApiMarkdown(std.testing.allocator, "pub const Vec2 = struct {};\nconst Private = struct {};\npub const Canvas = struct {};\n");
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "- `Vec2`") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "- `Canvas`") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "Private") == null);
}

test {
    _ = api_docs;
    _ = doc_bundle;
}

test "checked API pages match current declarations defaults and executed examples" {
    const allocator = std.testing.allocator;
    const root = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(root);
    var generator = api_docs.Generator.init(allocator, root, "src/unpolished_peas.zig");
    defer generator.deinit();
    const pages = try generator.generate();
    try validateApiPages(allocator, root, pages);
    for (pages) |page| {
        const path = try std.fs.path.join(allocator, &.{ root, "docs", page.path });
        defer allocator.free(path);
        const current = try readLfFileAlloc(allocator, path);
        defer allocator.free(current);
        try expectCurrentApiPage(path, page.contents, current);
    }
}

fn expectCurrentApiPage(path: []const u8, expected: []const u8, current: []const u8) !void {
    if (std.mem.eql(u8, expected, current)) return;
    std.debug.print("stale API reference: {s}; run zig build docs-update-api -Dwith_sdl=false\n", .{path});
    return error.StaleApiReference;
}

test "stale signatures and defaults fail the checked reference gate" {
    try std.testing.expectError(error.StaleApiReference, expectCurrentApiPage("fixture.md", "pub fn draw(width: u32) !void;", "pub fn draw(width: u16) !void;"));
    try std.testing.expectError(error.StaleApiReference, expectCurrentApiPage("fixture.md", "volume: f32 = 1", "volume: f32 = 0"));
}

test "member fragments must exist including generated pages" {
    const allocator = std.testing.allocator;
    const pages = [_]api_docs.Page{.{ .path = "api/drawing.md", .contents = "<a id=\"graphics-canvas-drawsurface\"></a>\n## Canvas\n" }};
    try validateDocumentLinksWithPages(allocator, "/repo", "/repo/docs/index.md", "[draw](api/drawing.md#graphics-canvas-drawsurface)", &pages);
    try std.testing.expectError(error.BrokenDocumentationAnchor, validateDocumentLinksWithPages(allocator, "/repo", "/repo/docs/index.md", "[typo](api/drawing.md#graphics-canvas-drawsurfce)", &pages));
    try std.testing.expectError(error.BrokenDocumentationAnchor, requireAnchor(allocator, "fixture.md", "\x60\x60\x60zig\n<a id=\"fake\"></a>\n\x60\x60\x60\n", "fake"));
}

test "broken runnable example links fail validation" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.makePath("docs/guides");
    try temp.dir.writeFile(.{ .sub_path = "docs/guides/broken.md", .data = "[broken](../../examples/missing.zig)\n" });
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const docs_root = try std.fs.path.join(std.testing.allocator, &.{ root, "docs" });
    defer std.testing.allocator.free(docs_root);
    try std.testing.expectError(error.BrokenDocumentationLink, validateExampleLinks(std.testing.allocator, root, docs_root));
}

test "repository documentation local links resolve" {
    const repository_root = try std.fs.cwd().realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(repository_root);
    const docs_root = try std.fs.path.join(std.testing.allocator, &.{ repository_root, "docs" });
    defer std.testing.allocator.free(docs_root);
    try validateExampleLinks(std.testing.allocator, repository_root, docs_root);
    try validateSupplementalLinks(std.testing.allocator, repository_root);
}

test "quickstart distinguishes the published version from missing package assets" {
    const quickstart = try std.fs.cwd().readFileAlloc(std.testing.allocator, "docs/guides/quickstart.md", max_document_bytes);
    defer std.testing.allocator.free(quickstart);
    const claims = [_][]const u8{
        "The current release is `1.0.0`",
        "zig build peas -- new ../my-game",
        "cd ../my-game",
        "zig build web",
        "local dependency",
        "zig build test-starter -Dwith_sdl=false",
        "zig build run-starter",
        "zig build run-tutorial-game-protocol",
        "no prepared source-package archive",
    };
    for (claims) |claim| try std.testing.expect(std.mem.indexOf(u8, quickstart, claim) != null);
    try std.testing.expect(std.mem.indexOf(u8, quickstart, "archive/refs/tags/v0.1.0") == null);
}

test "authoring freeze distinguishes game API from developer tooling" {
    const document = try readLfFileAlloc(std.testing.allocator, "docs/guides/authoring-experience-freeze.md");
    defer std.testing.allocator.free(document);
    inline for ([_][]const u8{
        "SpriteAnimationPlayer",
        "MusicHandle",
        "EXPERIMENTAL DEVELOPER TOOLING",
        "Seed Sprint",
        "Neon Siege",
        "Lantern Leap",
        "does\nnot announce another release",
    }) |claim| try std.testing.expect(std.mem.indexOf(u8, document, claim) != null);
}

test "developer tools reference keeps source and runtime asset roots distinct" {
    const document = try std.fs.cwd().readFileAlloc(std.testing.allocator, "docs/guides/developer-tools.md", max_document_bytes);
    defer std.testing.allocator.free(document);
    inline for ([_][]const u8{
        "UP_DEVELOPER_TOOLS",
        "UP_DEVELOPER_ASSET_ROOT",
        "UP_ASSET_ROOT",
        "UP_DEVELOPER_DIAGNOSTICS_DUMP",
        "python3",
    }) |claim| try std.testing.expect(std.mem.indexOf(u8, document, claim) != null);
}

test "quickstart tutorial program is the checked example source" {
    const quickstart = try readLfFileAlloc(std.testing.allocator, "docs/guides/quickstart.md");
    defer std.testing.allocator.free(quickstart);
    const source = try readLfFileAlloc(std.testing.allocator, "examples/tutorial_game_protocol.zig");
    defer std.testing.allocator.free(source);
    const begin_marker = "<!-- BEGIN tutorial-game-protocol -->\n```zig\n";
    const end_marker = "\n```\n<!-- END tutorial-game-protocol -->";
    const begin = (std.mem.indexOf(u8, quickstart, begin_marker) orelse return error.MissingTutorialSource) + begin_marker.len;
    const end = std.mem.indexOfPos(u8, quickstart, begin, end_marker) orelse return error.MissingTutorialSource;
    try std.testing.expectEqualStrings(std.mem.trimRight(u8, source, "\n"), quickstart[begin..end]);
}

test "starter excerpts in beginner guides match compiled source" {
    const input_guide = try readLfFileAlloc(std.testing.allocator, "docs/guides/input.md");
    defer std.testing.allocator.free(input_guide);
    const save_guide = try readLfFileAlloc(std.testing.allocator, "docs/guides/save-data.md");
    defer std.testing.allocator.free(save_guide);
    const starter = try readLfFileAlloc(std.testing.allocator, "templates/starter/src/game.zig");
    defer std.testing.allocator.free(starter);
    inline for ([_][]const u8{ "seed-sprint-actions", "seed-sprint-action-update" }) |name| {
        try std.testing.expect(std.mem.indexOf(u8, starter, try markdownZigSnippet(input_guide, name)) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, starter, try markdownZigSnippet(save_guide, "seed-sprint-save")) != null);
}
