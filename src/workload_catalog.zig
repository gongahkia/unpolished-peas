const std = @import("std");
const up = @import("unpolished-peas");

const catalog_bytes = @import("workload-catalog-data").bytes;
const required_workload_ids = [_][]const u8{ "primitive_fill", "sprite_batching", "alpha_blend", "clipping", "text", "mixed_frame" };
const required_metrics = [_][]const u8{ "frame_time_ns", "command_count", "frame_allocation_events", "frame_allocated_bytes" };

const Catalog = struct {
    schema_version: u32,
    workload_version: []const u8,
    assets: []Asset,
    workloads: []Workload,
};

const Asset = struct {
    id: []const u8,
    width: u32,
    height: u32,
    rgba: []u8,
};

const Workload = struct {
    id: []const u8,
    rationale: []const u8,
    width: u32,
    height: u32,
    warmup_frames: u32,
    frame_count: u32,
    assets: [][]const u8,
    metrics: [][]const u8,
    operations: []Operation,
};

const Operation = struct {
    op: []const u8,
    color: ?u32 = null,
    count: ?u32 = null,
    x: ?i32 = null,
    y: ?i32 = null,
    columns: ?u32 = null,
    w: ?i32 = null,
    h: ?i32 = null,
    step_x: ?i32 = null,
    step_y: ?i32 = null,
    asset: ?[]const u8 = null,
    text: ?[]const u8 = null,
};

pub const Summary = struct {
    workload_count: usize,
    frame_count: u64,
    combined_hash: u64,
    measurements: [required_workload_ids.len]Measurement,
};

pub const Measurement = struct {
    workload_index: usize,
    width: u32,
    height: u32,
    warmup_frames: u32,
    sample_count: u32,
    frame_time_ns: u64,
    command_count: usize,
    frame_allocation_events: u64,
    frame_allocated_bytes: u64,
};

const CountingAllocator = struct {
    parent: std.mem.Allocator,
    allocation_events: u64 = 0,
    allocated_bytes: u64 = 0,

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn init(parent: std.mem.Allocator) CountingAllocator {
        return .{ .parent = parent };
    }

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn reset(self: *CountingAllocator) void {
        self.allocation_events = 0;
        self.allocated_bytes = 0;
    }

    fn record(self: *CountingAllocator, bytes: usize) void {
        self.allocation_events +|= 1;
        self.allocated_bytes +|= bytes;
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        const result = self.parent.rawAlloc(len, alignment, ret_addr);
        if (result != null) self.record(len);
        return result;
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        const resized = self.parent.rawResize(memory, alignment, new_len, ret_addr);
        if (resized and new_len > memory.len) self.record(new_len - memory.len);
        return resized;
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        const result = self.parent.rawRemap(memory, alignment, new_len, ret_addr);
        if (result != null and new_len > memory.len) self.record(new_len - memory.len);
        return result;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.parent.rawFree(memory, alignment, ret_addr);
    }
};

pub fn run(allocator: std.mem.Allocator) !Summary {
    var parsed = try std.json.parseFromSlice(Catalog, allocator, catalog_bytes, .{});
    defer parsed.deinit();
    const catalog = parsed.value;
    try validateCatalog(catalog);
    const checker = findAsset(catalog.assets, "checker_2x2") orelse return error.InvalidCatalog;
    var image = try imageFromAsset(allocator, checker);
    defer image.deinit();
    var combined_hash = std.hash.Fnv1a_64.init();
    var frame_count: u64 = 0;
    var measurements: [required_workload_ids.len]Measurement = undefined;
    for (catalog.workloads) |workload| {
        try validateWorkload(workload);
        var counter = CountingAllocator.init(allocator);
        const measured_allocator = counter.allocator();
        var canvas = try up.graphics.Canvas.init(measured_allocator, workload.width, workload.height);
        defer canvas.deinit();
        var commands = up.graphics.RenderCommandBuffer.init(measured_allocator);
        defer commands.deinit();
        try appendOperations(&commands, workload, &image);
        var renderer = up.graphics.HeadlessRenderer.init(measured_allocator, &canvas);
        defer renderer.deinit();
        for (0..workload.warmup_frames) |_| try renderer.submit(commands.commands.items);
        counter.reset();
        var timer = try std.time.Timer.start();
        for (0..workload.frame_count) |_| try renderer.submit(commands.commands.items);
        const elapsed = timer.read();
        const measurement_index = requiredWorkloadIndex(workload.id) orelse return error.InvalidCatalog;
        measurements[measurement_index] = .{
            .workload_index = measurement_index,
            .width = workload.width,
            .height = workload.height,
            .warmup_frames = workload.warmup_frames,
            .sample_count = workload.frame_count,
            .frame_time_ns = elapsed / workload.frame_count,
            .command_count = commands.commands.items.len,
            .frame_allocation_events = counter.allocation_events,
            .frame_allocated_bytes = counter.allocated_bytes,
        };
        const hash = up.testSupport.canvasHash(canvas);
        combined_hash.update(std.mem.asBytes(&hash));
        frame_count += workload.warmup_frames + workload.frame_count;
    }
    return .{ .workload_count = catalog.workloads.len, .frame_count = frame_count, .combined_hash = combined_hash.final(), .measurements = measurements };
}

pub fn workloadId(index: usize) []const u8 {
    return required_workload_ids[index];
}

fn requiredWorkloadIndex(id: []const u8) ?usize {
    for (required_workload_ids, 0..) |expected, index| if (std.mem.eql(u8, id, expected)) return index;
    return null;
}

fn validateCatalog(catalog: Catalog) !void {
    if (catalog.schema_version != 1 or !std.mem.eql(u8, catalog.workload_version, "v1") or catalog.workloads.len != required_workload_ids.len) return error.InvalidCatalog;
    const checker = findAsset(catalog.assets, "checker_2x2") orelse return error.InvalidCatalog;
    if (catalog.assets.len != 1 or checker.width != 2 or checker.height != 2 or checker.rgba.len != 16) return error.InvalidCatalog;
    for (required_workload_ids) |id| {
        var matches: usize = 0;
        for (catalog.workloads) |workload| {
            if (std.mem.eql(u8, workload.id, id)) matches += 1;
        }
        if (matches != 1) return error.InvalidCatalog;
    }
}

fn validateWorkload(workload: Workload) !void {
    if (workload.id.len == 0 or workload.rationale.len == 0 or workload.width == 0 or workload.height == 0 or workload.warmup_frames == 0 or workload.frame_count == 0 or workload.metrics.len != required_metrics.len) return error.InvalidCatalog;
    for (required_metrics, 0..) |metric, index| if (!std.mem.eql(u8, workload.metrics[index], metric)) return error.InvalidCatalog;
    for (workload.assets) |asset| if (!std.mem.eql(u8, asset, "checker_2x2")) return error.InvalidCatalog;
}

fn findAsset(assets: []const Asset, id: []const u8) ?Asset {
    for (assets) |asset| if (std.mem.eql(u8, asset.id, id)) return asset;
    return null;
}

fn imageFromAsset(allocator: std.mem.Allocator, asset: Asset) !up.assets.Image {
    const pixel_count = std.math.mul(usize, asset.width, asset.height) catch return error.InvalidCatalog;
    if (asset.rgba.len != pixel_count * 4) return error.InvalidCatalog;
    const pixels = try allocator.alloc(up.core.Color, pixel_count);
    errdefer allocator.free(pixels);
    for (pixels, 0..) |*pixel, index| {
        const offset = index * 4;
        pixel.* = .{ .r = asset.rgba[offset], .g = asset.rgba[offset + 1], .b = asset.rgba[offset + 2], .a = asset.rgba[offset + 3] };
    }
    return .{ .allocator = allocator, .width = asset.width, .height = asset.height, .pixels = pixels };
}

fn appendOperations(commands: *up.graphics.RenderCommandBuffer, workload: Workload, image: *const up.assets.Image) !void {
    for (workload.operations) |operation| {
        if (std.mem.eql(u8, operation.op, "clear")) {
            try commands.append(.{ .clear = try color(operation.color) });
        } else if (std.mem.eql(u8, operation.op, "rect_batch")) {
            try appendRectBatch(commands, operation);
        } else if (std.mem.eql(u8, operation.op, "sprite_batch")) {
            try appendSpriteBatch(commands, operation, workload.assets, image);
        } else if (std.mem.eql(u8, operation.op, "text_batch")) {
            try appendTextBatch(commands, operation);
        } else if (std.mem.eql(u8, operation.op, "push_clip")) {
            try commands.append(.{ .push_clip = .{ .x = try integer(operation.x), .y = try integer(operation.y), .w = try integer(operation.w), .h = try integer(operation.h) } });
        } else if (std.mem.eql(u8, operation.op, "pop_clip")) {
            try commands.append(.pop_clip);
        } else return error.InvalidCatalog;
    }
}

fn appendRectBatch(commands: *up.graphics.RenderCommandBuffer, operation: Operation) !void {
    const batch = try batchFields(operation);
    if (batch.w <= 0 or batch.h <= 0) return error.InvalidCatalog;
    for (0..batch.count) |index| try commands.append(.{ .rect = .{ .x = batch.x + @as(i32, @intCast(index % batch.columns)) * batch.step_x, .y = batch.y + @as(i32, @intCast(index / batch.columns)) * batch.step_y, .w = batch.w, .h = batch.h, .color = batch.color } });
}

fn appendSpriteBatch(commands: *up.graphics.RenderCommandBuffer, operation: Operation, assets: []const []const u8, image: *const up.assets.Image) !void {
    const batch = try batchFields(operation);
    if (operation.asset == null or !std.mem.eql(u8, operation.asset.?, "checker_2x2") or !contains(assets, "checker_2x2")) return error.InvalidCatalog;
    for (0..batch.count) |index| try commands.append(.{ .image = .{ .image = image, .x = batch.x + @as(i32, @intCast(index % batch.columns)) * batch.step_x, .y = batch.y + @as(i32, @intCast(index / batch.columns)) * batch.step_y } });
}

fn contains(values: []const []const u8, expected: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, expected)) return true;
    return false;
}

fn appendTextBatch(commands: *up.graphics.RenderCommandBuffer, operation: Operation) !void {
    const batch = try batchFields(operation);
    const text = operation.text orelse return error.InvalidCatalog;
    for (0..batch.count) |index| try commands.append(.{ .text = .{ .value = text, .x = batch.x + @as(i32, @intCast(index % batch.columns)) * batch.step_x, .y = batch.y + @as(i32, @intCast(index / batch.columns)) * batch.step_y, .color = batch.color } });
}

const Batch = struct { count: u32, x: i32, y: i32, columns: u32, w: i32, h: i32, step_x: i32, step_y: i32, color: up.core.Color };

fn batchFields(operation: Operation) !Batch {
    const columns = operation.columns orelse return error.InvalidCatalog;
    if (columns == 0) return error.InvalidCatalog;
    return .{ .count = operation.count orelse return error.InvalidCatalog, .x = try integer(operation.x), .y = try integer(operation.y), .columns = columns, .w = operation.w orelse 0, .h = operation.h orelse 0, .step_x = try integer(operation.step_x), .step_y = try integer(operation.step_y), .color = colorOrWhite(operation.color) };
}

fn integer(value: ?i32) !i32 {
    return value orelse error.InvalidCatalog;
}

fn color(value: ?u32) !up.core.Color {
    const packed_color = value orelse return error.InvalidCatalog;
    return .{ .r = @truncate(packed_color), .g = @truncate(packed_color >> 8), .b = @truncate(packed_color >> 16), .a = @truncate(packed_color >> 24) };
}

fn colorOrWhite(value: ?u32) up.core.Color {
    return color(value) catch up.core.Color.white;
}

test "versioned catalog runs every stable-core workload headlessly" {
    const summary = try run(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 6), summary.workload_count);
    try std.testing.expectEqual(@as(u64, 120), summary.frame_count);
    try std.testing.expect(summary.combined_hash != 0);
    for (summary.measurements, 0..) |measurement, index| {
        try std.testing.expectEqual(index, measurement.workload_index);
        try std.testing.expectEqualStrings(workloadId(index), required_workload_ids[index]);
        try std.testing.expectEqual(@as(u32, 160), measurement.width);
        try std.testing.expectEqual(@as(u32, 90), measurement.height);
        try std.testing.expectEqual(@as(u32, 4), measurement.warmup_frames);
        try std.testing.expectEqual(@as(u32, 16), measurement.sample_count);
        try std.testing.expect(measurement.command_count > 0);
    }
}
