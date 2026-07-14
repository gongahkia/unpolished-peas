const std = @import("std");

pub const Metrics = struct {
    frame: u64 = 0,
    gpu_frame_ns: ?u64 = null,
    gpu_pass_ns: ?u64 = null,
    encoder_ns: u64 = 0,
    pass_count: u32 = 0,
    batches: u32 = 0,
    texture_count: u32 = 0,
    texture_bytes: u64 = 0,
    audio_buffer_bytes: ?u64 = null,
    audio_queued_bytes: ?u64 = null,
    resource_churn: u32 = 0,
    allocation_churn_bytes: u64 = 0,
    last_texture_count: u32 = 0,
    last_allocation_bytes: u64 = 0,

    pub fn beginFrame(self: *Metrics, frame: u64) void {
        self.frame = frame;
        self.gpu_frame_ns = null;
        self.gpu_pass_ns = null;
        self.encoder_ns = 0;
        self.pass_count = 0;
        self.batches = 0;
        self.texture_count = 0;
        self.texture_bytes = 0;
        self.audio_buffer_bytes = null;
        self.audio_queued_bytes = null;
        self.resource_churn = 0;
        self.allocation_churn_bytes = 0;
    }

    pub fn recordGpuSubmission(self: *Metrics, encoder_ns: u64, pass_count: u32, batches: u32, texture_count: u32, texture_bytes: u64, allocation_bytes: u64) void {
        self.encoder_ns = encoder_ns;
        self.pass_count = pass_count;
        self.batches = batches;
        self.texture_count = texture_count;
        self.texture_bytes = texture_bytes;
        self.resource_churn +|= deltaU32(self.last_texture_count, texture_count);
        self.allocation_churn_bytes = deltaU64(self.last_allocation_bytes, allocation_bytes);
        self.last_texture_count = texture_count;
        self.last_allocation_bytes = allocation_bytes;
    }

    pub fn recordAssetReloads(self: *Metrics, count: usize) void {
        const bounded: u32 = if (count > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(count);
        self.resource_churn +|= bounded;
    }

    pub fn recordAudio(self: *Metrics, buffer_bytes: ?u64, queued_bytes: ?u64) void {
        self.audio_buffer_bytes = buffer_bytes;
        self.audio_queued_bytes = queued_bytes;
    }
};

fn deltaU32(a: u32, b: u32) u32 {
    return if (a >= b) a - b else b - a;
}

fn deltaU64(a: u64, b: u64) u64 {
    return if (a >= b) a - b else b - a;
}

test "runtime metrics retain unavailable GPU timing and track churn" {
    var metrics = Metrics{};
    metrics.beginFrame(4);
    metrics.recordGpuSubmission(120, 3, 2, 4, 1_024, 4_096);
    metrics.recordAssetReloads(2);
    metrics.recordAudio(512, 256);
    try @import("std").testing.expect(metrics.gpu_frame_ns == null);
    try @import("std").testing.expectEqual(@as(u32, 6), metrics.resource_churn);
    try @import("std").testing.expectEqual(@as(u64, 4_096), metrics.allocation_churn_bytes);
    metrics.beginFrame(5);
    metrics.recordGpuSubmission(80, 2, 1, 3, 768, 2_048);
    try @import("std").testing.expectEqual(@as(u32, 1), metrics.resource_churn);
    try @import("std").testing.expectEqual(@as(u64, 2_048), metrics.allocation_churn_bytes);
}
