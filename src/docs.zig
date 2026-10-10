const std = @import("std");

const max_document_bytes = 1024 * 1024;
const source_documents = [_][]const u8{
    "index.md",
    "guides/quickstart.md",
    "guides/installation.md",
    "guides/platforms.md",
    "guides/game-protocol.md",
    "guides/core-contract.md",
    "guides/rendering.md",
    "guides/render-surfaces.md",
    "guides/advanced-2d.md",
    "guides/image-assets.md",
    "guides/audio-assets.md",
    "guides/save-data.md",
    "guides/input.md",
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
    if (args.next() != null) return usage();
    try emit(gpa.allocator(), docs_root, api_source, output_root);
}

pub fn emit(allocator: std.mem.Allocator, docs_root: []const u8, api_source: []const u8, output_root: []const u8) !void {
    const repository_root = std.fs.path.dirname(docs_root) orelse return error.InvalidDocsRoot;
    try validateExampleLinks(allocator, repository_root, docs_root);
    try validateSupplementalLinks(allocator, repository_root);
    try std.fs.cwd().makePath(output_root);
    for (source_documents) |relative_path| try copyDocument(allocator, docs_root, output_root, relative_path);
    const source = try std.fs.cwd().readFileAlloc(allocator, api_source, max_document_bytes);
    defer allocator.free(source);
    const api_path = try std.fs.path.join(allocator, &.{ output_root, "api", "core.md" });
    defer allocator.free(api_path);
    const api_directory = std.fs.path.dirname(api_path) orelse return error.InvalidOutputPath;
    try std.fs.cwd().makePath(api_directory);
    const api_page = try publicApiMarkdown(allocator, source);
    defer allocator.free(api_page);
    try std.fs.cwd().writeFile(.{ .sub_path = api_path, .data = api_page });
}

pub fn publicApiMarkdown(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, "# Core API\n\nGenerated from `src/unpolished_peas.zig`.\n\n");
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const declaration = std.mem.trimLeft(u8, line, " \t");
        if (!std.mem.startsWith(u8, declaration, "pub const ")) continue;
        const rest = declaration["pub const ".len..];
        const end = std.mem.indexOfAny(u8, rest, " =\t;") orelse continue;
        try output.writer(allocator).print("- `{s}`\n", .{rest[0..end]});
    }
    return output.toOwnedSlice(allocator);
}

pub fn validateExampleLinks(allocator: std.mem.Allocator, repository_root: []const u8, docs_root: []const u8) !void {
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
        try validateDocumentLinks(allocator, repository_root, document_path, document);
    }
}

fn validateSupplementalLinks(allocator: std.mem.Allocator, repository_root: []const u8) !void {
    for (supplemental_documents) |relative_path| {
        const document_path = try std.fs.path.join(allocator, &.{ repository_root, relative_path });
        defer allocator.free(document_path);
        const document = try std.fs.cwd().readFileAlloc(allocator, document_path, max_document_bytes);
        defer allocator.free(document);
        try validateDocumentLinks(allocator, repository_root, document_path, document);
    }
}

fn copyDocument(allocator: std.mem.Allocator, docs_root: []const u8, output_root: []const u8, relative_path: []const u8) !void {
    const source_path = try std.fs.path.join(allocator, &.{ docs_root, relative_path });
    defer allocator.free(source_path);
    const output_path = try std.fs.path.join(allocator, &.{ output_root, relative_path });
    defer allocator.free(output_path);
    const output_directory = std.fs.path.dirname(output_path) orelse return error.InvalidOutputPath;
    try std.fs.cwd().makePath(output_directory);
    const document = try std.fs.cwd().readFileAlloc(allocator, source_path, max_document_bytes);
    defer allocator.free(document);
    try std.fs.cwd().writeFile(.{ .sub_path = output_path, .data = document });
}

fn validateDocumentLinks(allocator: std.mem.Allocator, repository_root: []const u8, document_path: []const u8, document: []const u8) !void {
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, document, cursor, "](")) |link_start| {
        const target_start = link_start + 2;
        const link_end = std.mem.indexOfScalarPos(u8, document, target_start, ')') orelse return error.MalformedMarkdownLink;
        cursor = link_end + 1;
        const target = document[target_start..link_end];
        if (isExternalLink(target) or std.mem.startsWith(u8, target, "#")) continue;
        const path_without_anchor = target[0..(std.mem.indexOfAny(u8, target, "#?") orelse target.len)];
        if (path_without_anchor.len == 0) continue;
        const document_directory = std.fs.path.dirname(document_path) orelse return error.InvalidDocsRoot;
        const linked_path = try std.fs.path.resolve(allocator, &.{ document_directory, path_without_anchor });
        defer allocator.free(linked_path);
        if (std.mem.endsWith(u8, linked_path, "/docs/api/core.md")) continue; // generated by `zig build docs`
        std.fs.cwd().access(linked_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                _ = repository_root;
                return error.BrokenDocumentationLink;
            },
            else => return err,
        };
    }
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

fn usage() error{InvalidArguments} {
    std.debug.print("usage: unpolished-peas-docs <docs-root> <public-api-source> <output-root>\n", .{});
    return error.InvalidArguments;
}

test "public API Markdown derives exported declarations" {
    const page = try publicApiMarkdown(std.testing.allocator, "pub const Vec2 = struct {};\nconst Private = struct {};\npub const Canvas = struct {};\n");
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "- `Vec2`") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "- `Canvas`") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "Private") == null);
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

test "quickstart states that the first release remains unpublished" {
    const quickstart = try std.fs.cwd().readFileAlloc(std.testing.allocator, "docs/guides/quickstart.md", max_document_bytes);
    defer std.testing.allocator.free(quickstart);
    const claims = [_][]const u8{
        "The first public release is prepared as `v0.1.0`, but has",
        "zig build test-starter -Dwith_sdl=false",
        "zig build run-starter",
        "zig build browser-starter -Dwith_sdl=false",
        "zig build package-starter",
        "zig build run-tutorial-game-protocol",
        "**not** been published",
    };
    for (claims) |claim| try std.testing.expect(std.mem.indexOf(u8, quickstart, claim) != null);
    try std.testing.expect(std.mem.indexOf(u8, quickstart, "archive/refs/tags/v0.1.0") == null);
}

test "authoring freeze distinguishes game API from developer tooling" {
    const document = try std.fs.cwd().readFileAlloc(std.testing.allocator, "docs/guides/authoring-experience-freeze.md", max_document_bytes);
    defer std.testing.allocator.free(document);
    inline for ([_][]const u8{
        "SpriteAnimationPlayer",
        "MusicHandle",
        "EXPERIMENTAL DEVELOPER TOOLING",
        "Seed Sprint",
        "Neon Siege",
        "Lantern Leap",
        "not a published `v0.2.0` release",
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
    const quickstart = try std.fs.cwd().readFileAlloc(std.testing.allocator, "docs/guides/quickstart.md", max_document_bytes);
    defer std.testing.allocator.free(quickstart);
    const source = try std.fs.cwd().readFileAlloc(std.testing.allocator, "examples/tutorial_game_protocol.zig", max_document_bytes);
    defer std.testing.allocator.free(source);
    const begin_marker = "<!-- BEGIN tutorial-game-protocol -->\n```zig\n";
    const end_marker = "\n```\n<!-- END tutorial-game-protocol -->";
    const begin = (std.mem.indexOf(u8, quickstart, begin_marker) orelse return error.MissingTutorialSource) + begin_marker.len;
    const end = std.mem.indexOfPos(u8, quickstart, begin, end_marker) orelse return error.MissingTutorialSource;
    try std.testing.expectEqualStrings(std.mem.trimRight(u8, source, "\n"), quickstart[begin..end]);
}

test "starter excerpts in beginner guides match compiled source" {
    const input_guide = try std.fs.cwd().readFileAlloc(std.testing.allocator, "docs/guides/input.md", max_document_bytes);
    defer std.testing.allocator.free(input_guide);
    const save_guide = try std.fs.cwd().readFileAlloc(std.testing.allocator, "docs/guides/save-data.md", max_document_bytes);
    defer std.testing.allocator.free(save_guide);
    const starter = try std.fs.cwd().readFileAlloc(std.testing.allocator, "templates/starter/src/game.zig", max_document_bytes);
    defer std.testing.allocator.free(starter);
    inline for ([_][]const u8{ "seed-sprint-actions", "seed-sprint-action-update" }) |name| {
        try std.testing.expect(std.mem.indexOf(u8, starter, try markdownZigSnippet(input_guide, name)) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, starter, try markdownZigSnippet(save_guide, "seed-sprint-save")) != null);
}
