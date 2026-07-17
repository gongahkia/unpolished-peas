const std = @import("std");
const acknowledgements = @import("ack_ranges.zig");
const reliable = @import("reliable_ordered.zig");
const retransmission = @import("retransmission.zig");
const congestion = @import("baseline_congestion.zig");
const pacing = @import("packet_pacing.zig");
const bandwidth = @import("bandwidth_caps.zig");
const backpressure = @import("backpressure.zig");
const lz4 = @import("lz4_block.zig");
const reassembly = @import("message_reassembly.zig");
const fragmentation = @import("message_fragmentation.zig");

test "fault matrix recovers reliable ordered delivery after loss duplication and reordering" {
    var storage: [12]u8 = undefined;
    var receiver = try reliable.ReliableOrderedReceiver.init(0, 3, 4, storage[0..]);
    var scheduler = try retransmission.RetransmissionScheduler.init(.{ .timeout_ns = 10, .maximum_retries = 2 });
    for (0..3) |sequence| try scheduler.schedule(@intCast(sequence), 0);
    try std.testing.expectEqual(reliable.ReliableReceiveResult.accepted, receiver.receive(2, "two"));
    try std.testing.expectEqual(reliable.ReliableReceiveResult.duplicate, receiver.receive(2, "two"));
    try std.testing.expectEqual(reliable.ReliableReceiveResult.accepted, receiver.receive(0, "zero"));
    var ranges = acknowledgements.AckRanges{};
    try ranges.insert(0);
    try ranges.insert(2);
    scheduler.acknowledge(ranges);
    var due: [1]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 1), scheduler.collect_due(10, true, due[0..]).due);
    try std.testing.expectEqual(@as(u32, 1), due[0]);
    try scheduler.commit_retransmission(1, 10);
    try std.testing.expectEqual(reliable.ReliableReceiveResult.accepted, receiver.receive(1, "one"));
    var delivered: [3]reliable.ReliableOrderedMessage = undefined;
    try std.testing.expectEqual(@as(usize, 3), receiver.drain(delivered[0..]));
    try std.testing.expectEqualStrings("zero", delivered[0].payload);
    try std.testing.expectEqualStrings("one", delivered[1].payload);
    try std.testing.expectEqualStrings("two", delivered[2].payload);
}

test "fault matrix coordinates loss congestion pacing bandwidth and backpressure" {
    var controller = try congestion.BaselineCongestionController.init(.{
        .initial_window_bytes = 100,
        .minimum_window_bytes = 20,
        .maximum_window_bytes = 200,
        .maximum_segment_size = 10,
    });
    try controller.register_route(1);
    const control = controller.controller();
    control.on_sent(1, 100, 0);
    control.on_feedback(1, .{ .lost_bytes = 50 }, 1);
    try std.testing.expectEqual(@as(usize, 0), control.send_budget(1));
    var pacer = try pacing.PacketPacer.init(.{ .bytes_per_second = 100, .maximum_burst_bytes = 10, .maximum_timer_ns = 10 });
    try pacer.register_route(1, 0);
    try std.testing.expectEqual(@as(usize, 0), (try pacer.reserve(1, control.send_budget(1), 100, 1)).bytes);
    control.on_feedback(1, .{ .acknowledged_bytes = 50 }, 20);
    try std.testing.expect(control.send_budget(1) > 0);
    try std.testing.expectEqual(@as(usize, 10), (try pacer.reserve(1, control.send_budget(1), 100, 20)).bytes);

    const caps = bandwidth.BandwidthCapConfig{
        .ingress = .{ .bytes_per_second = 100, .maximum_burst_bytes = 10, .control_reserve_bytes = 3 },
        .egress = .{ .bytes_per_second = 100, .maximum_burst_bytes = 10, .control_reserve_bytes = 3 },
    };
    var limiter = bandwidth.BandwidthLimiter{};
    try limiter.register_route(1, caps, 20);
    try std.testing.expectEqual(@as(usize, 7), try limiter.admit(1, .egress, .payload, 10, 20));
    try std.testing.expectEqual(@as(usize, 3), try limiter.admit(1, .egress, .control, 10, 20));
    var queues = try backpressure.BackpressureController.init(.{ .maximum_queued_bytes = 10, .high_watermark_bytes = 7 });
    try queues.register_target(.{ .transport = 1 });
    try std.testing.expectEqual(backpressure.BackpressureState.pressured, (try queues.reserve(.{ .transport = 1 }, 7)).state);
    try std.testing.expectEqual(backpressure.BackpressureState.saturated, (try queues.reserve(.{ .transport = 1 }, 3)).state);
    try std.testing.expectError(error.QueueFull, queues.reserve(.{ .transport = 1 }, 1));
    try std.testing.expectEqual(backpressure.BackpressureState.ready, (try queues.release(.{ .transport = 1 }, 5)).state);
}

test "fault matrix rejects corrupted compression and reassembles delayed fragments" {
    const source = "abcabcabcabcabcabcXYZ";
    var codec = try lz4.Lz4BlockCodec.init(.{ .maximum_uncompressed_bytes = source.len, .maximum_compressed_bytes = source.len + 8 });
    var compressed: [source.len + 8]u8 = undefined;
    _ = try codec.compress(source, compressed[0..]);
    var decoded: [source.len]u8 = undefined;
    try std.testing.expectError(error.MalformedBlock, codec.decompress(&.{ 0, 0, 0 }, decoded[0..]));

    var storage: [30]u8 = undefined;
    var receiver = try reassembly.MessageReassembler.init(.{ .maximum_message_bytes = 30, .fragment_payload_bytes = 10, .expiry_ns = 10, .maximum_inflight_messages = 1 }, storage[0..]);
    const first = fragmentation.MessageFragment{ .message_id = 1, .index = 0, .count = 3, .payload = "0123456789" };
    const second = fragmentation.MessageFragment{ .message_id = 1, .index = 1, .count = 3, .payload = "abcdefghij" };
    const last = fragmentation.MessageFragment{ .message_id = 1, .index = 2, .count = 3, .payload = "tail" };
    try std.testing.expectEqual(reassembly.ReassemblyResult.pending, try receiver.accept(last, 0));
    try std.testing.expectEqual(reassembly.ReassemblyResult.pending, try receiver.accept(first, 1));
    try std.testing.expectError(error.FragmentConflict, receiver.accept(.{ .message_id = 1, .index = 0, .count = 3, .payload = "XXXXXXXXXX" }, 2));
    const complete = try receiver.accept(second, 3);
    try std.testing.expectEqualStrings("0123456789abcdefghijtail", complete.complete);
}
