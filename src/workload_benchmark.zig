const std = @import("std");
const builtin = @import("builtin");
const catalog = @import("workload-catalog");

const output_limit = 16 * 1024;

pub fn main() !void {
    run() catch |err| {
        std.debug.print("native-workload-benchmark failed: {s}\n", .{@errorName(err)});
        return err;
    };
}

fn run() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const summary = try catalog.run(gpa.allocator());
    var buffer: [output_limit]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buffer);
    try writeArtifact(&writer.interface, summary);
    try writer.interface.flush();
}

pub fn writeArtifact(writer: anytype, summary: catalog.Summary) !void {
    try writer.print("{{\"schema_version\":1,\"status\":\"ok\",\"target\":{{\"os\":\"{s}\",\"architecture\":\"{s}\",\"renderer\":\"headless\"}},\"workload_version\":\"v1\",\"workloads\":[", .{ @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) });
    for (summary.measurements, 0..) |measurement, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.print("{{\"id\":\"{s}\",\"resolution\":{{\"width\":{d},\"height\":{d}}},\"warmup_frames\":{d},\"sample_count\":{d},\"metrics\":{{\"frame_time_ns\":{d},\"command_count\":{d},\"frame_allocation_events\":{d},\"frame_allocated_bytes\":{d}}}}}", .{ catalog.workloadId(measurement.workload_index), measurement.width, measurement.height, measurement.warmup_frames, measurement.sample_count, measurement.frame_time_ns, measurement.command_count, measurement.frame_allocation_events, measurement.frame_allocated_bytes });
    }
    try writer.print("],\"timer\":{{\"clock\":\"std.time.Timer\",\"unit\":\"nanoseconds\",\"measurement\":\"headless_cpu_render\"}},\"diagnostics\":{{\"combined_canvas_hash\":\"{x}\"}}}}\n", .{summary.combined_hash});
}

test "native workload artifact schema is bounded and complete" {
    const summary = try catalog.run(std.testing.allocator);
    var bytes: [output_limit]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try writeArtifact(&writer, summary);
    const document = writer.buffered();
    try std.testing.expect(document.len <= output_limit);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, document, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 1), root.get("schema_version").?.integer);
    try std.testing.expectEqualStrings("ok", root.get("status").?.string);
    try std.testing.expectEqualStrings("headless", root.get("target").?.object.get("renderer").?.string);
    try std.testing.expectEqualStrings("v1", root.get("workload_version").?.string);
    try std.testing.expectEqualStrings("std.time.Timer", root.get("timer").?.object.get("clock").?.string);
    try std.testing.expectEqualStrings("headless_cpu_render", root.get("timer").?.object.get("measurement").?.string);
    const workloads = root.get("workloads").?.array.items;
    try std.testing.expectEqual(@as(usize, 6), workloads.len);
    for (workloads, 0..) |workload, index| {
        try std.testing.expectEqualStrings(catalog.workloadId(index), workload.object.get("id").?.string);
        try std.testing.expectEqual(@as(i64, 4), workload.object.get("warmup_frames").?.integer);
        try std.testing.expectEqual(@as(i64, 16), workload.object.get("sample_count").?.integer);
        try std.testing.expect(workload.object.get("metrics").?.object.get("command_count").?.integer > 0);
    }
    try std.testing.expect(root.get("diagnostics").?.object.get("combined_canvas_hash").?.string.len > 0);
}
