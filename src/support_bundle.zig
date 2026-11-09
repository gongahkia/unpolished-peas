const std = @import("std");

const max_artifact_bytes = 64 * 1024 * 1024;
const artifact_names = [_][]const u8{
    "metadata.json",
    "environment.json",
    "failure.log",
    "events.jsonl",
    "logging.json",
    "diagnostics.json",
    "renderer-diagnostics.json",
    "commands.json",
    "trace.json",
    "replay.json",
    "screenshot.png",
};

pub const Options = struct {
    source_path: []const u8,
    output_path: []const u8,
    include: []const []const u8 = &.{},
    redact: []const []const u8 = &.{},
    redact_paths: []const []const u8 = &.{},
};

pub const Report = struct {
    files: usize,
    redacted_occurrences: usize,
};

pub fn create(allocator: std.mem.Allocator, options: Options) !Report {
    if (options.source_path.len == 0 or options.output_path.len == 0) return error.InvalidSupportBundlePath;
    try validateRedactions(options.redact);
    try validateRedactions(options.redact_paths);
    const source_path = try std.fs.cwd().realpathAlloc(allocator, options.source_path);
    defer allocator.free(source_path);
    var source = try std.fs.openDirAbsolute(source_path, .{ .iterate = true });
    defer source.close();
    if (std.fs.cwd().access(options.output_path, .{})) |_| return error.SupportBundleExists else |err| if (err != error.FileNotFound) return err;
    try std.fs.cwd().makePath(options.output_path);
    errdefer std.fs.cwd().deleteTree(options.output_path) catch {};
    const output_path = try std.fs.cwd().realpathAlloc(allocator, options.output_path);
    defer allocator.free(output_path);
    if (std.mem.eql(u8, source_path, output_path) or pathContains(source_path, output_path)) return error.SupportBundleInsideSource;
    var output = try std.fs.openDirAbsolute(output_path, .{});
    defer output.close();

    const selected = try selection(options.include);
    var copied_artifacts = [_]bool{false} ** artifact_names.len;
    var copied: usize = 0;
    var redacted_occurrences: usize = 0;
    var bundle_bytes: u64 = 0;
    for (artifact_names, 0..) |name, index| {
        if (!selected[index]) continue;
        const stat = source.statFile(name) catch |err| switch (err) {
            error.FileNotFound => if (options.include.len == 0) continue else return error.SelectedDiagnosticMissing,
            else => return err,
        };
        if (stat.kind != .file or stat.size > max_artifact_bytes) return error.InvalidDiagnosticsArtifact;
        redacted_occurrences += try copyArtifact(allocator, source, output, name, source_path, options);
        bundle_bytes += (try output.statFile(name)).size;
        if (bundle_bytes > max_artifact_bytes) return error.SupportBundleTooLarge;
        copied_artifacts[index] = true;
        copied += 1;
    }
    var incidents: std.ArrayList([]const u8) = .empty;
    defer {
        for (incidents.items) |name| allocator.free(name);
        incidents.deinit(allocator);
    }
    var iterator = source.iterate();
    while (try iterator.next()) |entry| {
        if (!isIncidentArtifact(entry.name)) continue;
        if (options.include.len != 0) {
            var selected_incident = false;
            for (options.include) |name| if (std.mem.eql(u8, name, entry.name)) {
                selected_incident = true;
                break;
            };
            if (!selected_incident) continue;
        }
        if (entry.kind != .file) return error.InvalidDiagnosticsArtifact;
        if (incidents.items.len == 4) return error.SupportBundleTooLarge;
        try incidents.ensureUnusedCapacity(allocator, 1);
        const name = try allocator.dupe(u8, entry.name);
        incidents.appendAssumeCapacity(name);
        redacted_occurrences += try copyArtifact(allocator, source, output, name, source_path, options);
        bundle_bytes += (try output.statFile(name)).size;
        if (bundle_bytes > max_artifact_bytes) return error.SupportBundleTooLarge;
        copied += 1;
    }
    for (options.include) |name| if (isIncidentArtifact(name)) {
        var present = false;
        for (incidents.items) |candidate| if (std.mem.eql(u8, name, candidate)) {
            present = true;
            break;
        };
        if (!present) return error.SelectedDiagnosticMissing;
    };
    if (copied == 0) return error.NoDiagnosticsArtifacts;
    try writeManifest(output, copied_artifacts, copied, redacted_occurrences, incidents.items);
    bundle_bytes += (try output.statFile("support-bundle.json")).size;
    if (bundle_bytes > max_artifact_bytes) return error.SupportBundleTooLarge;
    return .{ .files = copied, .redacted_occurrences = redacted_occurrences };
}

fn selection(include: []const []const u8) ![artifact_names.len]bool {
    var selected = [_]bool{false} ** artifact_names.len;
    if (include.len == 0) return [_]bool{true} ** artifact_names.len;
    for (include, 0..) |value, position| {
        for (include[0..position]) |prior| if (std.mem.eql(u8, value, prior)) return error.DuplicateDiagnosticsArtifact;
        if (artifactIndex(value)) |index| selected[index] = true else if (!isIncidentArtifact(value)) return error.InvalidDiagnosticsArtifact;
    }
    return selected;
}

fn copyArtifact(allocator: std.mem.Allocator, source: std.fs.Dir, output: std.fs.Dir, name: []const u8, source_path: []const u8, options: Options) !usize {
    const info = try source.statFile(name);
    if (info.kind != .file or info.size > max_artifact_bytes) return error.InvalidDiagnosticsArtifact;
    if (isTextArtifact(name)) {
        const contents = try source.readFileAlloc(allocator, name, max_artifact_bytes);
        defer allocator.free(contents);
        const result = try redactText(allocator, contents, source_path, options.redact_paths, options.redact);
        defer allocator.free(result.text);
        try output.writeFile(.{ .sub_path = name, .data = result.text });
        return result.occurrences;
    }
    try source.copyFile(name, output, name, .{});
    return 0;
}

fn isIncidentArtifact(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "incident-") or !std.mem.endsWith(u8, name, ".json") or name.len > 64) return false;
    var parts = std.mem.splitScalar(u8, name[9 .. name.len - 5], '-');
    const session = std.fmt.parseInt(u64, parts.next() orelse return false, 10) catch return false;
    const incident = std.fmt.parseInt(u64, parts.next() orelse return false, 10) catch return false;
    return session > 0 and incident > 0 and parts.next() == null;
}

fn artifactIndex(name: []const u8) ?usize {
    for (artifact_names, 0..) |candidate, index| if (std.mem.eql(u8, candidate, name)) return index;
    return null;
}

fn isTextArtifact(name: []const u8) bool {
    return !std.mem.eql(u8, name, "screenshot.png");
}

fn validateRedactions(values: []const []const u8) !void {
    for (values) |value| if (value.len == 0) return error.InvalidRedaction;
}

fn pathContains(root: []const u8, path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, root)) return false;
    if (root.len == 1 and root[0] == std.fs.path.sep) return path.len > root.len;
    return path.len > root.len and std.fs.path.sep == path[root.len];
}

const Redaction = struct {
    text: []u8,
    occurrences: usize,
};

fn redactText(allocator: std.mem.Allocator, contents: []const u8, source_path: []const u8, paths: []const []const u8, secrets: []const []const u8) !Redaction {
    var text = try allocator.dupe(u8, contents);
    errdefer allocator.free(text);
    var occurrences: usize = 0;
    text, occurrences = try replaceAll(allocator, text, source_path, "[REDACTED_PATH]", occurrences);
    for (paths) |path| text, occurrences = try replaceAll(allocator, text, path, "[REDACTED_PATH]", occurrences);
    for (secrets) |secret| text, occurrences = try replaceAll(allocator, text, secret, "[REDACTED]", occurrences);
    return .{ .text = text, .occurrences = occurrences };
}

fn replaceAll(allocator: std.mem.Allocator, source: []u8, pattern: []const u8, replacement: []const u8, occurrences: usize) !struct { []u8, usize } {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    var cursor: usize = 0;
    var count = occurrences;
    while (std.mem.indexOfPos(u8, source, cursor, pattern)) |start| {
        try appendLimited(allocator, &output, source[cursor..start]);
        try appendLimited(allocator, &output, replacement);
        cursor = start + pattern.len;
        count += 1;
    }
    if (count == occurrences) return .{ source, occurrences };
    try appendLimited(allocator, &output, source[cursor..]);
    const result = try output.toOwnedSlice(allocator);
    allocator.free(source);
    return .{ result, count };
}

fn appendLimited(allocator: std.mem.Allocator, output: *std.ArrayList(u8), value: []const u8) !void {
    if (value.len > max_artifact_bytes or output.items.len > max_artifact_bytes - value.len) return error.SupportBundleTooLarge;
    try output.appendSlice(allocator, value);
}

fn writeManifest(output: std.fs.Dir, artifacts: [artifact_names.len]bool, files: usize, redacted_occurrences: usize, incidents: []const []const u8) !void {
    var file = try output.createFile("support-bundle.json", .{});
    defer file.close();
    var buffer: [1024]u8 = undefined;
    var writer = file.writer(&buffer);
    const out = &writer.interface;
    try out.print("{{\"version\":1,\"files\":{d},\"redacted_occurrences\":{d},\"artifacts\":[", .{ files, redacted_occurrences });
    var first = true;
    for (artifact_names, 0..) |name, index| {
        if (!artifacts[index]) continue;
        if (!first) try out.writeByte(',');
        first = false;
        try std.json.Stringify.value(name, .{}, out);
    }
    for (incidents) |name| {
        if (!first) try out.writeByte(',');
        first = false;
        try std.json.Stringify.value(name, .{}, out);
    }
    try out.writeAll("]}");
    try out.flush();
}

test "support bundle redacts configured values and copies selected diagnostics" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const source = try std.fs.path.join(std.testing.allocator, &.{ root, "diagnostics" });
    defer std.testing.allocator.free(source);
    const output = try std.fs.path.join(std.testing.allocator, &.{ root, "support" });
    defer std.testing.allocator.free(output);
    try std.fs.cwd().makePath(source);
    const environment = try std.fmt.allocPrint(std.testing.allocator, "{{\"asset_root\":\"{s}\",\"cache\":\"/private/value\",\"token\":\"token-123\"}}", .{source});
    defer std.testing.allocator.free(environment);
    const environment_path = try std.fs.path.join(std.testing.allocator, &.{ source, "environment.json" });
    defer std.testing.allocator.free(environment_path);
    try std.fs.cwd().writeFile(.{ .sub_path = environment_path, .data = environment });
    const log_path = try std.fs.path.join(std.testing.allocator, &.{ source, "failure.log" });
    defer std.testing.allocator.free(log_path);
    try std.fs.cwd().writeFile(.{ .sub_path = log_path, .data = "token-123" });
    const screenshot_path = try std.fs.path.join(std.testing.allocator, &.{ source, "screenshot.png" });
    defer std.testing.allocator.free(screenshot_path);
    const screenshot = "\x89PNG\r\n";
    try std.fs.cwd().writeFile(.{ .sub_path = screenshot_path, .data = screenshot });
    const report = try create(std.testing.allocator, .{ .source_path = source, .output_path = output, .include = &.{ "environment.json", "failure.log", "screenshot.png" }, .redact = &.{"token-123"}, .redact_paths = &.{"/private/value"} });
    try std.testing.expectEqual(@as(usize, 3), report.files);
    try std.testing.expectEqual(@as(usize, 4), report.redacted_occurrences);
    const copied_environment_path = try std.fs.path.join(std.testing.allocator, &.{ output, "environment.json" });
    defer std.testing.allocator.free(copied_environment_path);
    const copied_environment = try std.fs.cwd().readFileAlloc(std.testing.allocator, copied_environment_path, 4096);
    defer std.testing.allocator.free(copied_environment);
    try std.testing.expect(std.mem.indexOf(u8, copied_environment, source) == null);
    try std.testing.expect(std.mem.indexOf(u8, copied_environment, "/private/value") == null);
    try std.testing.expect(std.mem.indexOf(u8, copied_environment, "token-123") == null);
    const copied_screenshot_path = try std.fs.path.join(std.testing.allocator, &.{ output, "screenshot.png" });
    defer std.testing.allocator.free(copied_screenshot_path);
    const copied_screenshot = try std.fs.cwd().readFileAlloc(std.testing.allocator, copied_screenshot_path, 4096);
    defer std.testing.allocator.free(copied_screenshot);
    try std.testing.expectEqualStrings(screenshot, copied_screenshot);
    const manifest_path = try std.fs.path.join(std.testing.allocator, &.{ output, "support-bundle.json" });
    defer std.testing.allocator.free(manifest_path);
    const manifest = try std.fs.cwd().readFileAlloc(std.testing.allocator, manifest_path, 4096);
    defer std.testing.allocator.free(manifest);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "token-123") == null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, source) == null);
}

test "support bundle rejects missing and duplicate selected diagnostics" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const source = try std.fs.path.join(std.testing.allocator, &.{ root, "diagnostics" });
    defer std.testing.allocator.free(source);
    try std.fs.cwd().makePath(source);
    const duplicate_output = try std.fs.path.join(std.testing.allocator, &.{ root, "duplicate" });
    defer std.testing.allocator.free(duplicate_output);
    try std.testing.expectError(error.DuplicateDiagnosticsArtifact, create(std.testing.allocator, .{ .source_path = source, .output_path = duplicate_output, .include = &.{ "failure.log", "failure.log" } }));
    const missing_output = try std.fs.path.join(std.testing.allocator, &.{ root, "missing" });
    defer std.testing.allocator.free(missing_output);
    try std.testing.expectError(error.SelectedDiagnosticMissing, create(std.testing.allocator, .{ .source_path = source, .output_path = missing_output, .include = &.{"failure.log"} }));
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(missing_output, .{}));
}

fn bundleAllocationFailures(allocator: std.mem.Allocator, source: []const u8, output: []const u8) !void {
    defer std.fs.cwd().deleteTree(output) catch {};
    _ = create(allocator, .{ .source_path = source, .output_path = output, .include = &.{ "events.jsonl", "logging.json", "incident-7-1.json" }, .redact = &.{"private-value"} }) catch |err| {
        try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(output, .{}));
        return err;
    };
}

test "support exports structured event context with allocation rollback and redaction" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const source = try std.fs.path.join(std.testing.allocator, &.{ root, "source" });
    defer std.testing.allocator.free(source);
    const output = try std.fs.path.join(std.testing.allocator, &.{ root, "output" });
    defer std.testing.allocator.free(output);
    try temp.dir.makeDir("source");
    try temp.dir.writeFile(.{ .sub_path = "source/events.jsonl", .data = "{\"version\":1,\"message\":\"private-value\"}\n" });
    try temp.dir.writeFile(.{ .sub_path = "source/logging.json", .data = "{\"version\":1,\"dropped_events\":3}" });
    try temp.dir.writeFile(.{ .sub_path = "source/incident-7-1.json", .data = "{\"version\":1,\"error\":\"private-value\"}" });
    try std.testing.checkAllAllocationFailures(std.testing.allocator, bundleAllocationFailures, .{ source, output });
    _ = try create(std.testing.allocator, .{ .source_path = source, .output_path = output, .redact = &.{"private-value"} });
    const event_bytes = try temp.dir.readFileAlloc(std.testing.allocator, "output/events.jsonl", 1024);
    defer std.testing.allocator.free(event_bytes);
    const event = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, event_bytes, .{});
    defer event.deinit();
    try std.testing.expectEqualStrings("[REDACTED]", event.value.object.get("message").?.string);
    try temp.dir.access("output/logging.json", .{});
    try temp.dir.access("output/incident-7-1.json", .{});
}
