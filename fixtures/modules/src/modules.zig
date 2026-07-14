const std = @import("std");
const up = @import("unpolished-peas");
const tools = @import("unpolished-peas-tools");
const services = @import("unpolished-peas-services");

test "downstream module imports remain SDL-free" {
    var canvas = try up.Canvas.init(std.testing.allocator, 1, 1);
    defer canvas.deinit();
    try std.testing.expectEqual(tools.Command.check, tools.parseCommand("check").?);
    const transport = services.networking.Transport;
    _ = transport;
}
