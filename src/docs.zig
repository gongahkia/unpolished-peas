const std = @import("std");

const max_document_bytes = 1024 * 1024;
const source_documents = [_][]const u8{
    "index.md",
    "guides/quickstart.md",
    "guides/game-protocol.md",
    "guides/testing.md",
    "guides/capabilities.md",
    "guides/releases.md",
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
        if (std.mem.indexOf(u8, target, "examples/") == null) continue;
        const path_without_anchor = target[0..(std.mem.indexOfScalar(u8, target, '#') orelse target.len)];
        const document_directory = std.fs.path.dirname(document_path) orelse return error.InvalidDocsRoot;
        const linked_path = try std.fs.path.resolve(allocator, &.{ document_directory, path_without_anchor });
        defer allocator.free(linked_path);
        std.fs.cwd().access(linked_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                _ = repository_root;
                return error.BrokenExampleLink;
            },
            else => return err,
        };
    }
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
    try std.testing.expectError(error.BrokenExampleLink, validateExampleLinks(std.testing.allocator, root, docs_root));
}
