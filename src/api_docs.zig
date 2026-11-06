//! Source-derived API excerpts for the existing Markdown docs generator.
//! This resolves local public re-exports, not arbitrary comptime Zig programs.
const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node.Index;
const limit = 2 * 1024 * 1024;

pub const page_names = [_][]const u8{
    "core", "lifecycle", "drawing", "input", "assets", "audio-save", "testing", "boundaries",
};
pub const Page = struct { path: []const u8, contents: []const u8 };
const File = struct { path: []const u8, tree: Ast };
const Ref = struct { file: *File, node: Node, scope: Node = .root };

pub fn namespaceMarkdown(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const terminated = try allocator.dupeZ(u8, source);
    defer allocator.free(terminated);
    var tree = try Ast.parse(allocator, terminated, .zig);
    defer tree.deinit(allocator);
    if (tree.errors.len != 0) return error.InvalidApiSource;
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, "## Root namespace exports\n\nGenerated from the public facade; use the task links above to explore members.\n\n");
    for (tree.rootDecls()) |node| {
        if (!Generator.isPublic(tree, node)) continue;
        const name = Generator.memberName(tree, node) orelse continue;
        try output.writer(allocator).print("- \x60{s}\x60\n", .{name});
    }
    return output.toOwnedSlice(allocator);
}

pub const Generator = struct {
    arena: std.heap.ArenaAllocator,
    root: []const u8,
    facade: []const u8,
    files: std.StringHashMapUnmanaged(*File) = .empty,

    pub fn init(backing_allocator: std.mem.Allocator, root: []const u8, facade: []const u8) Generator {
        return .{ .arena = .init(backing_allocator), .root = root, .facade = facade };
    }

    pub fn deinit(self: *Generator) void {
        self.arena.deinit();
    }

    fn allocator(self: *Generator) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn load(self: *Generator, path: []const u8) !*File {
        const a = self.allocator();
        const absolute = try std.fs.path.resolve(a, &.{ self.root, path });
        const relative = try std.fs.path.relative(a, self.root, absolute);
        if (std.mem.startsWith(u8, relative, "..")) return error.ExternalApiSource;
        if (self.files.get(absolute)) |file| return file;
        const raw = try std.fs.cwd().readFileAlloc(a, absolute, limit);
        const source = try a.dupeZ(u8, try std.mem.replaceOwned(u8, a, raw, "\r\n", "\n"));
        const file = try a.create(File);
        file.* = .{ .path = try std.mem.replaceOwned(u8, a, relative, "\\", "/"), .tree = try Ast.parse(a, source, .zig) };
        if (file.tree.errors.len != 0) return error.InvalidApiSource;
        try self.files.put(a, absolute, file);
        return file;
    }

    fn memberName(tree: Ast, node: Node) ?[]const u8 {
        if (tree.fullVarDecl(node)) |v| return tree.tokenSlice(v.ast.mut_token + 1);
        var buffer: [1]Node = undefined;
        if (tree.fullFnProto(&buffer, node)) |f| return tree.tokenSlice(f.name_token orelse return null);
        if (tree.fullContainerField(node)) |f| return tree.tokenSlice(f.ast.main_token);
        return null;
    }

    fn isPublic(tree: Ast, node: Node) bool {
        if (tree.fullVarDecl(node)) |v| return v.visib_token != null;
        var buffer: [1]Node = undefined;
        if (tree.fullFnProto(&buffer, node)) |f| return f.visib_token != null;
        return tree.fullContainerField(node) != null;
    }

    fn lookup(self: *Generator, scope: Ref, name: []const u8, public: bool, depth: u32) anyerror!Ref {
        const container_ref = try self.container(scope, depth + 1);
        var buffer: [2]Node = undefined;
        const tree = container_ref.file.tree;
        const members = tree.fullContainerDecl(&buffer, container_ref.node).?.ast.members;
        for (members) |node| {
            const actual = memberName(tree, node) orelse continue;
            if (!std.mem.eql(u8, actual, name)) continue;
            if (public and !isPublic(tree, node)) return error.PrivateApiSymbol;
            return .{ .file = container_ref.file, .node = node, .scope = container_ref.node };
        }
        return error.MissingApiSymbol;
    }

    fn expression(self: *Generator, ref: Ref, depth: u32) anyerror!Ref {
        if (depth > 64) return error.ApiAliasCycle;
        const tree = ref.file.tree;
        switch (tree.nodeTag(ref.node)) {
            .identifier => {
                const name = tree.tokenSlice(tree.nodeMainToken(ref.node));
                return self.lookup(.{ .file = ref.file, .node = ref.scope }, name, false, depth + 1) catch |err| {
                    if (err != error.MissingApiSymbol or ref.scope == .root) return err;
                    return self.lookup(.{ .file = ref.file, .node = .root }, name, false, depth + 1);
                };
            },
            .field_access => {
                const data = tree.nodeData(ref.node).node_and_token;
                const base = try self.expression(.{ .file = ref.file, .node = data[0], .scope = ref.scope }, depth + 1);
                return self.lookup(base, tree.tokenSlice(data[1]), true, depth + 1);
            },
            else => {
                var buffer: [2]Node = undefined;
                if (tree.builtinCallParams(&buffer, ref.node)) |params| {
                    if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(ref.node)), "@import") or params.len != 1) return error.UnsupportedApiExpression;
                    const literal = tree.getNodeSource(params[0]);
                    if (literal.len < 3 or literal[0] != '"' or !std.mem.endsWith(u8, literal, ".zig\"")) return error.ExternalApiSource;
                    const path = try std.fs.path.join(self.allocator(), &.{ std.fs.path.dirname(ref.file.path) orelse ".", literal[1 .. literal.len - 1] });
                    return .{ .file = try self.load(path), .node = .root };
                }
                return ref;
            },
        }
    }

    fn definition(self: *Generator, ref: Ref, depth: u32) anyerror!Ref {
        if (depth > 64) return error.ApiAliasCycle;
        const tree = ref.file.tree;
        if (tree.fullVarDecl(ref.node)) |v| {
            const value = v.ast.init_node.unwrap() orelse return error.UnsupportedApiExpression;
            var buffer: [2]Node = undefined;
            if (tree.fullContainerDecl(&buffer, value) != null) return ref;
            const next = try self.expression(.{ .file = ref.file, .node = value, .scope = ref.scope }, depth + 1);
            if (next.node == value and next.file == ref.file) return ref;
            return self.definition(next, depth + 1);
        }
        return ref;
    }

    fn container(self: *Generator, original: Ref, depth: u32) anyerror!Ref {
        if (depth > 64) return error.ApiAliasCycle;
        const ref = try self.definition(original, depth + 1);
        const tree = ref.file.tree;
        var buffer: [2]Node = undefined;
        if (tree.fullContainerDecl(&buffer, ref.node) != null) return ref;
        if (tree.fullVarDecl(ref.node)) |v| {
            const value = v.ast.init_node.unwrap() orelse return error.NotApiContainer;
            if (tree.fullContainerDecl(&buffer, value) != null) return .{ .file = ref.file, .node = value };
        }
        // Generic factories such as GameProtocol and HeadlessGameRunner return
        // a literal struct. Document that type without instantiating a game.
        if (tree.nodeTag(ref.node) == .fn_decl) {
            const body = tree.nodeData(ref.node).node_and_node[1];
            if (tree.blockStatements(&buffer, body)) |statements| {
                for (statements) |statement| {
                    if (tree.nodeTag(statement) != .@"return") continue;
                    const value = tree.nodeData(statement).opt_node.unwrap() orelse continue;
                    var inner_buffer: [2]Node = undefined;
                    if (tree.fullContainerDecl(&inner_buffer, value) != null) return .{ .file = ref.file, .node = value };
                }
            }
        }
        return error.NotApiContainer;
    }

    fn resolve(self: *Generator, path: []const u8) !Ref {
        var ref = Ref{ .file = try self.load(self.facade), .node = .root };
        var parts = std.mem.splitScalar(u8, path, '.');
        while (parts.next()) |part| {
            if (part.len == 0) return error.InvalidApiPath;
            ref = try self.lookup(ref, part, true, 0);
        }
        return self.definition(ref, 0);
    }

    pub fn anchor(a: std.mem.Allocator, path: []const u8) ![]const u8 {
        const result = try a.dupe(u8, path);
        // Zig names are case-sensitive: Input.Snapshot and Input.snapshot are
        // distinct public members and must never share a Markdown fragment.
        for (result) |*c| {
            if (c.* == '.') c.* = '-';
        }
        return result;
    }

    fn appendCode(self: *Generator, out: *std.ArrayList(u8), tree: Ast, first: Ast.TokenIndex, last: Ast.TokenIndex) !void {
        const a = self.allocator();
        const start = tree.tokenStart(first);
        const end = tree.tokenStart(last) + tree.tokenSlice(last).len;
        const line_start = if (std.mem.lastIndexOfScalar(u8, tree.source[0..start], '\n')) |i| i + 1 else 0;
        const indentation = start - line_start;
        var lines = std.mem.splitScalar(u8, tree.source[start..end], '\n');
        var initial = true;
        while (lines.next()) |line| {
            if (!initial) try out.append(a, '\n');
            const trim = if (initial) 0 else @min(indentation, line.len - std.mem.trimLeft(u8, line, " ").len);
            try out.appendSlice(a, line[trim..]);
            initial = false;
        }
    }

    fn appendDocs(self: *Generator, out: *std.ArrayList(u8), ref: Ref) !void {
        const tree = ref.file.tree;
        const end = tree.firstToken(ref.node);
        var start = end;
        while (start > 0 and tree.tokenTag(start - 1) == .doc_comment) start -= 1;
        for (start..end) |token| {
            const text = tree.tokenSlice(@intCast(token));
            try out.appendSlice(self.allocator(), std.mem.trimStart(u8, text[3..], " "));
            try out.append(self.allocator(), '\n');
        }
        if (start != end) try out.append(self.allocator(), '\n');
    }

    fn renderSymbol(self: *Generator, out: *std.ArrayList(u8), path: []const u8, original: Ref, level: usize, display_path: ?[]const u8) anyerror!void {
        if (level > 8) return error.ApiNestingTooDeep;
        const a = self.allocator();
        const ref = try self.definition(original, 0);
        const tree = ref.file.tree;
        const id = try anchor(a, path);
        const shown_path = display_path orelse path;
        try out.writer(a).print("<a id=\"{s}\"></a>\n{s} \x60up.{s}\x60\n\n", .{ id, "########"[0..level], shown_path });
        const line = 1 + std.mem.count(u8, tree.source[0..tree.tokenStart(tree.firstToken(ref.node))], "\n");
        try out.writer(a).print("[Source declaration](../../{s}#L{d}).", .{ ref.file.path, line });
        const public_name = path[(if (std.mem.lastIndexOfScalar(u8, path, '.')) |i| i + 1 else 0)..];
        if (memberName(tree, ref.node)) |name| {
            if (!std.mem.eql(u8, name, public_name)) try out.writer(a).print(" Implementation name: \x60{s}\x60.", .{name});
        }
        try out.appendSlice(a, "\n\n");
        try self.appendDocs(out, ref);
        var fn_buffer: [1]Node = undefined;
        const function = tree.fullFnProto(&fn_buffer, ref.node);
        if (function) |f| {
            try out.appendSlice(a, "\x60\x60\x60zig\n");
            try self.appendCode(out, tree, f.firstToken(), tree.lastToken(f.ast.proto_node));
            try out.appendSlice(a, ";\n\x60\x60\x60\n\n");
        }
        const shape = self.container(ref, 0) catch |err| {
            if (err != error.NotApiContainer) return err;
            if (tree.fullVarDecl(ref.node) != null) {
                try out.appendSlice(a, "\x60\x60\x60zig\n");
                try self.appendCode(out, tree, tree.firstToken(ref.node), tree.lastToken(ref.node));
                try out.appendSlice(a, "\n\x60\x60\x60\n\n");
            }
            return;
        };
        var buffer: [2]Node = undefined;
        const info = shape.file.tree.fullContainerDecl(&buffer, shape.node).?;
        const members = info.ast.members;
        var child_prefix = shown_path;
        if (function) |f| {
            var arguments: std.ArrayList(u8) = .empty;
            var params = f.iterate(&tree);
            while (params.next()) |param| {
                if (arguments.items.len != 0) try arguments.appendSlice(a, ", ");
                try arguments.appendSlice(a, if (param.name_token) |token| tree.tokenSlice(token) else "...");
            }
            child_prefix = try std.fmt.allocPrint(a, "{s}({s})", .{ shown_path, arguments.items });
            try out.writer(a).print("Members of the returned type \x60up.{s}\x60:\n\n", .{child_prefix});
        }
        // A compact member index makes large types usable without scrolling.
        var listed_member = false;
        for (members) |member| {
            if (shape.file.tree.fullContainerField(member) != null or !isPublic(shape.file.tree, member)) continue;
            const name = memberName(shape.file.tree, member) orelse continue;
            const child_path = try std.fmt.allocPrint(a, "{s}.{s}", .{ path, name });
            if (listed_member) try out.appendSlice(a, " · ");
            try out.writer(a).print("[\x60{s}\x60](#{s})", .{ name, try anchor(a, child_path) });
            listed_member = true;
        }
        if (listed_member) try out.appendSlice(a, "\n\n");
        try out.appendSlice(a, "Fields, variants and defaults (methods follow):\n\n\x60\x60\x60zig\n");
        const shape_tree = shape.file.tree;
        const first = info.layout_token orelse info.ast.main_token;
        var brace = info.ast.main_token;
        while (shape_tree.tokenTag(brace) != .l_brace) brace += 1;
        try self.appendCode(out, shape_tree, first, brace);
        try out.append(a, '\n');
        for (members) |member| {
            if (shape_tree.fullContainerField(member) == null) continue;
            try out.appendSlice(a, "    ");
            try self.appendCode(out, shape_tree, shape_tree.firstToken(member), shape_tree.lastToken(member));
            try out.appendSlice(a, ",\n");
        }
        try out.appendSlice(a, "}\n\x60\x60\x60\n\n");
        for (members) |member| {
            if (shape_tree.fullContainerField(member) != null or !isPublic(shape_tree, member)) continue;
            const name = memberName(shape_tree, member) orelse continue;
            try self.renderSymbol(out, try std.fmt.allocPrint(a, "{s}.{s}", .{ path, name }), .{ .file = shape.file, .node = member, .scope = shape.node }, level + 1, try std.fmt.allocPrint(a, "{s}.{s}", .{ child_prefix, name }));
        }
    }

    pub fn render(self: *Generator, template: []const u8) ![]const u8 {
        const a = self.allocator();
        var out: std.ArrayList(u8) = .empty;
        var cursor: usize = 0;
        const prefix = "<!-- api: ";
        while (std.mem.indexOfPos(u8, template, cursor, prefix)) |start| {
            try out.appendSlice(a, template[cursor..start]);
            const end = std.mem.indexOfPos(u8, template, start, " -->") orelse return error.InvalidApiDirective;
            const path = template[start + prefix.len .. end];
            const ref = self.resolve(path) catch |err| {
                std.debug.print("API documentation symbol {s}: {s}\n", .{ path, @errorName(err) });
                return err;
            };
            try self.renderSymbol(&out, path, ref, 2, null);
            cursor = end + " -->".len;
        }
        try out.appendSlice(a, template[cursor..]);
        const expanded = try self.renderExamples(try out.toOwnedSlice(a));
        if (std.mem.indexOf(u8, expanded, "<!-- namespaces -->") == null) return expanded;
        return std.mem.replaceOwned(u8, a, expanded, "<!-- namespaces -->", try namespaceMarkdown(a, (try self.load(self.facade)).tree.source));
    }

    fn renderExamples(self: *Generator, template: []const u8) ![]const u8 {
        const a = self.allocator();
        var out: std.ArrayList(u8) = .empty;
        var cursor: usize = 0;
        const prefix = "<!-- example: ";
        while (std.mem.indexOfPos(u8, template, cursor, prefix)) |start| {
            try out.appendSlice(a, template[cursor..start]);
            const end = std.mem.indexOfPos(u8, template, start, " -->") orelse return error.InvalidApiDirective;
            const directive = template[start + prefix.len .. end];
            const split = std.mem.indexOf(u8, directive, " | ") orelse return error.InvalidExampleDirective;
            const path = directive[0..split];
            const symbol = directive[split + 3 ..];
            const file = try self.load(path);
            var selected: ?Node = null;
            if (std.mem.startsWith(u8, symbol, "test: ")) {
                for (file.tree.rootDecls()) |node| {
                    if (file.tree.nodeTag(node) != .test_decl) continue;
                    const literal = file.tree.tokenSlice(file.tree.nodeMainToken(node) + 1);
                    if (literal.len > 2 and std.mem.eql(u8, literal[1 .. literal.len - 1], symbol[6..])) selected = node;
                }
            } else {
                var ref = Ref{ .file = file, .node = .root };
                var parts = std.mem.splitScalar(u8, symbol, '.');
                while (parts.next()) |part| ref = try self.lookup(ref, part, false, 0);
                selected = ref.node;
            }
            const node = selected orelse return error.MissingExampleSymbol;
            const line = 1 + std.mem.count(u8, file.tree.source[0..file.tree.tokenStart(file.tree.firstToken(node))], "\n");
            try out.writer(a).print("[Compiled source](../../{s}#L{d}) (\x60{s}\x60):\n\n\x60\x60\x60zig\n", .{ path, line, symbol });
            try self.appendCode(&out, file.tree, file.tree.firstToken(node), file.tree.lastToken(node));
            try out.appendSlice(a, "\n\x60\x60\x60\n");
            cursor = end + " -->".len;
        }
        try out.appendSlice(a, template[cursor..]);
        return out.toOwnedSlice(a);
    }

    pub fn generate(self: *Generator) ![]const Page {
        const a = self.allocator();
        const pages = try a.alloc(Page, page_names.len);
        for (page_names, pages) |name, *page| {
            const template_path = try std.fs.path.join(a, &.{ self.root, "docs/api/templates", try std.fmt.allocPrint(a, "{s}.md.in", .{name}) });
            const raw = try std.fs.cwd().readFileAlloc(a, template_path, limit);
            const template = try std.mem.replaceOwned(u8, a, raw, "\r\n", "\n");
            var toc: std.ArrayList(u8) = .empty;
            var cursor: usize = 0;
            const prefix = "<!-- api: ";
            while (std.mem.indexOfPos(u8, template, cursor, prefix)) |start| {
                const end = std.mem.indexOfPos(u8, template, start, " -->") orelse return error.InvalidApiDirective;
                const symbol = template[start + prefix.len .. end];
                try toc.writer(a).print("- [\x60up.{s}\x60](#{s})\n", .{ symbol, try anchor(a, symbol) });
                cursor = end + 4;
            }
            const rendered = try self.render(template);
            const title_end = std.mem.indexOfScalar(u8, rendered, '\n') orelse rendered.len;
            const contents = if (toc.items.len == 0) rendered else try std.fmt.allocPrint(a, "{s}\n\nAPI entries:\n\n{s}\n{s}", .{ rendered[0..title_end], toc.items, rendered[title_end + 1 ..] });
            page.* = .{
                .path = try std.fmt.allocPrint(a, "api/{s}.md", .{name}),
                .contents = try std.fmt.allocPrint(a, "<!-- Generated by zig build docs-update-api. Edit docs/api/templates/{s}.md.in. -->\n\n{s}\n", .{ name, std.mem.trimEnd(u8, contents, "\n") }),
            };
        }
        return pages;
    }
};

test "public aliases resolve across modules and preserve multiline signatures/defaults" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root_source =
        \\const api = @import("facade.zig");
        \\pub const graphics = api.drawing;
        \\const hidden = api.drawing;
    ;
    try temp.dir.writeFile(.{ .sub_path = "root.zig", .data = root_source });
    const facade_source =
        \\pub const drawing = struct { pub const Surface = @import("surface.zig").Target; };
    ;
    try temp.dir.writeFile(.{ .sub_path = "facade.zig", .data = facade_source });
    const surface_source =
        \\pub const Target = struct {
        \\    alpha: u8 = 177,
        \\    pub const Options = struct { width: u32 = 19 };
        \\    pub fn draw(
        \\        self: *Target,
        \\        options: Options,
        \\    ) error{InvalidSize}!void { _ = self; _ = options; }
        \\    pub fn options(_: *Target) Options { return .{}; }
        \\    fn secret() void {}
        \\};
    ;
    try temp.dir.writeFile(.{ .sub_path = "surface.zig", .data = surface_source });
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    var generator = Generator.init(std.testing.allocator, root, "root.zig");
    defer generator.deinit();
    const page = try generator.render("<!-- api: graphics.Surface -->");
    for ([_][]const u8{ "alpha: u8 = 177", "width: u32 = 19", "self: *Target", "error{InvalidSize}!void;", "graphics-Surface-Options", "graphics-Surface-options", "graphics-Surface-draw", "../../surface.zig#L" }) |text| try std.testing.expect(std.mem.indexOf(u8, page, text) != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "_ = self") == null);
    try std.testing.expectError(error.PrivateApiSymbol, generator.render("<!-- api: hidden.Surface -->"));
    try std.testing.expectError(error.PrivateApiSymbol, generator.render("<!-- api: graphics.Surface.secret -->"));
    try std.testing.expectError(error.MissingApiSymbol, generator.render("<!-- api: graphics.Surface.missing -->"));
    const original = (try generator.load("surface.zig")).tree.source;
    const changed_type = try std.mem.replaceOwned(u8, std.testing.allocator, original, "options: Options", "options: ?Options");
    defer std.testing.allocator.free(changed_type);
    const changed_default = try std.mem.replaceOwned(u8, std.testing.allocator, changed_type, "alpha: u8 = 177", "alpha: u8 = 99");
    defer std.testing.allocator.free(changed_default);
    try temp.dir.writeFile(.{ .sub_path = "surface.zig", .data = changed_default });
    var fresh = Generator.init(std.testing.allocator, root, "root.zig");
    defer fresh.deinit();
    const changed = try fresh.render("<!-- api: graphics.Surface -->");
    try std.testing.expect(std.mem.indexOf(u8, changed, "options: ?Options") != null);
    try std.testing.expect(std.mem.indexOf(u8, changed, "alpha: u8 = 99") != null);
    try std.testing.expect(!std.mem.eql(u8, page, changed));
}

test "generic returned structs expose their public methods" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root_source =
        \\pub fn Runner(comptime Game: type) type {
        \\    return struct {
        \\        game: Game,
        \\        pub fn step(self: *@This(), dt: f32) !void { _ = self; _ = dt; }
        \\    };
        \\}
    ;
    try temp.dir.writeFile(.{ .sub_path = "root.zig", .data = root_source });
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    var generator = Generator.init(std.testing.allocator, root, "root.zig");
    defer generator.deinit();
    const page = try generator.render("<!-- api: Runner -->");
    try std.testing.expect(std.mem.indexOf(u8, page, "game: Game") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "Runner-step") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "up.Runner(Game).step") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "dt: f32) !void;") != null);
}

test "example extraction includes executable bodies and rejects stale selectors" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(.{ .sub_path = "root.zig", .data = "" });
    try temp.dir.writeFile(.{ .sub_path = "recipe.zig", .data = "pub fn draw() !void {\r\n    return error.Sentinel;\r\n}\r\ntest \"pixels\" { try draw(); }\r\n" });
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    var generator = Generator.init(std.testing.allocator, root, "root.zig");
    defer generator.deinit();
    const function = try generator.render("<!-- example: recipe.zig | draw -->");
    try std.testing.expect(std.mem.indexOf(u8, function, "return error.Sentinel;") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, function, '\r') == null);
    const example_test = try generator.render("<!-- example: recipe.zig | test: pixels -->");
    try std.testing.expect(std.mem.indexOf(u8, example_test, "try draw();") != null);
    try std.testing.expectError(error.MissingExampleSymbol, generator.render("<!-- example: recipe.zig | test: removed -->"));
    try std.testing.expectError(error.MissingApiSymbol, generator.render("<!-- example: recipe.zig | removed -->"));
}
