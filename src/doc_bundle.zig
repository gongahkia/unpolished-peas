//! Copies the linked documentation closure and rewrites local links so the
//! emitted Markdown is browsable independently of its checkout location.
const std = @import("std");
const api = @import("api_docs.zig");
const limit = 2 * 1024 * 1024;

pub const Bundle = struct {
    arena: std.heap.ArenaAllocator,
    root: []const u8,
    output: []const u8,
    pages: []const api.Page,
    // Source absolute path -> emitted absolute path; mark before following
    // links to terminate ordinary Markdown cycles.
    files: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn init(backing: std.mem.Allocator, root: []const u8, output: []const u8, pages: []const api.Page) Bundle {
        return .{ .arena = .init(backing), .root = root, .output = output, .pages = pages };
    }

    pub fn deinit(self: *Bundle) void {
        self.arena.deinit();
    }

    fn allocator(self: *Bundle) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn destination(self: *Bundle, source: []const u8) ![]const u8 {
        const a = self.allocator();
        const relative = try std.fs.path.relative(a, self.root, source);
        if (std.fs.path.isAbsolute(relative) or std.mem.startsWith(u8, relative, "..")) return error.ExternalDocumentationResource;
        const docs = try std.fs.path.join(a, &.{ self.root, "docs" });
        const doc_relative = try std.fs.path.relative(a, docs, source);
        if (!std.fs.path.isAbsolute(doc_relative) and !std.mem.startsWith(u8, doc_relative, "..")) return std.fs.path.join(a, &.{ self.output, doc_relative });
        return std.fs.path.join(a, &.{ self.output, "repository", relative });
    }

    pub fn add(self: *Bundle, source_path: []const u8) anyerror![]const u8 {
        const a = self.allocator();
        const source = try std.fs.path.resolve(a, &.{ self.root, source_path });
        if (self.files.get(source)) |existing| return existing;
        const dest = try self.destination(source);
        if (std.mem.eql(u8, source, dest)) return error.DocumentationOutputOverwritesSource;
        try self.files.put(a, source, dest);
        try std.fs.cwd().makePath(std.fs.path.dirname(dest).?);
        if (!std.mem.endsWith(u8, source, ".md")) {
            const info = try std.fs.cwd().statFile(source);
            if (info.kind != .file) return error.UnsupportedDocumentationResource;
            try std.fs.cwd().copyFile(source, std.fs.cwd(), dest, .{});
            return dest;
        }
        var contents: ?[]const u8 = null;
        for (self.pages) |page| {
            const actual = try std.fs.path.resolve(a, &.{ self.root, "docs", page.path });
            if (std.mem.eql(u8, source, actual)) contents = page.contents;
        }
        const markdown = contents orelse try std.fs.cwd().readFileAlloc(a, source, limit);
        var out: std.ArrayList(u8) = .empty;
        var cursor: usize = 0;
        while (std.mem.indexOfPos(u8, markdown, cursor, "](")) |start| {
            const target_start = start + 2;
            const end = std.mem.indexOfScalarPos(u8, markdown, target_start, ')') orelse return error.MalformedMarkdownLink;
            try out.appendSlice(a, markdown[cursor..target_start]);
            const target = markdown[target_start..end];
            if (external(target) or std.mem.startsWith(u8, target, "#")) {
                try out.appendSlice(a, target);
            } else {
                const split = std.mem.indexOfAny(u8, target, "#?") orelse target.len;
                const linked_source = try std.fs.path.resolve(a, &.{ std.fs.path.dirname(source).?, target[0..split] });
                const linked_dest = try self.add(linked_source);
                const relative = try std.fs.path.relative(a, std.fs.path.dirname(dest).?, linked_dest);
                try out.appendSlice(a, try std.mem.replaceOwned(u8, a, relative, "\\", "/"));
                try out.appendSlice(a, target[split..]);
            }
            try out.append(a, ')');
            cursor = end + 1;
        }
        try out.appendSlice(a, markdown[cursor..]);
        try std.fs.cwd().writeFile(.{ .sub_path = dest, .data = out.items });
        return dest;
    }

    fn external(target: []const u8) bool {
        return std.mem.startsWith(u8, target, "https://") or std.mem.startsWith(u8, target, "http://") or
            std.mem.startsWith(u8, target, "mailto:") or std.mem.startsWith(u8, target, "data:");
    }
};

test "emitted docs retain source links, generated member links and Markdown cycles" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.makePath("docs");
    try temp.dir.writeFile(.{ .sub_path = "docs/index.md", .data = "[api](api/core.md#draw) [readme](../README.md)" });
    try temp.dir.writeFile(.{ .sub_path = "README.md", .data = "[back](docs/index.md)" });
    try temp.dir.writeFile(.{ .sub_path = "game.zig", .data = "// exact source snapshot\n" });
    const a = std.testing.allocator;
    const root = try temp.dir.realpathAlloc(a, ".");
    defer a.free(root);
    const output = try std.fs.path.join(a, &.{ root, "emitted" });
    defer a.free(output);
    const pages = [_]api.Page{.{ .path = "api/core.md", .contents = "<a id=\"draw\"></a>\n[source](../../game.zig#L1)" }};
    var bundle = Bundle.init(a, root, output, &pages);
    defer bundle.deinit();
    _ = try bundle.add("docs/index.md");
    const api_page = try temp.dir.readFileAlloc(a, "emitted/api/core.md", limit);
    defer a.free(api_page);
    try std.testing.expect(std.mem.indexOf(u8, api_page, "../repository/game.zig#L1") != null);
    const readme = try temp.dir.readFileAlloc(a, "emitted/repository/README.md", limit);
    defer a.free(readme);
    try std.testing.expectEqualStrings("[back](../index.md)", readme);
    const source = try temp.dir.readFileAlloc(a, "emitted/repository/game.zig", limit);
    defer a.free(source);
    try std.testing.expectEqualStrings("// exact source snapshot\n", source);
    try std.testing.expectEqual(@as(usize, 4), bundle.files.count());
}
