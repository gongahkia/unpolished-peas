const std = @import("std");
const core = @import("unpolished-peas").api;
const ui = @import("unpolished-peas-ui").ui(core);

test "UI package pointer focus and toggle paths" {
    var canvas = try core.Canvas.init(std.testing.allocator, 32, 16);
    defer canvas.deinit();
    var input = core.Input{};
    input.setPointerPosition(.{ .x = 3, .y = 3 }, .{ .x = 3, .y = 3 }, .{ .x = 3, .y = 3 });
    input.setPointerButton(.left, true);
    var state = ui.State{};
    var frame = ui.Frame.begin(&state, &input, .{ .hud = &canvas }, .{ .cursor = .{ .x = 1, .y = 1 }, .width = 20 });
    var enabled = false;
    const response = frame.toggle(1, "ENABLE", &enabled);
    frame.end();
    try std.testing.expect(response.hovered and response.focused and response.pressed);
    try std.testing.expect(enabled);
    try std.testing.expectEqual(@as(?ui.Id, 1), state.focus);
    try std.testing.expect(!std.meta.eql(canvas.get(1, 1).?, core.Color.transparent));
}

test "UI package keyboard and gamepad navigation wrap deterministically" {
    var canvas = try core.Canvas.init(std.testing.allocator, 32, 32);
    defer canvas.deinit();
    var state = ui.State{ .focus = 1 };
    var keyboard = core.Input{};
    keyboard.set(.down, true);
    var frame = ui.Frame.begin(&state, &keyboard, .{ .hud = &canvas }, .{ .cursor = .{}, .width = 20 });
    _ = frame.button(1, "ONE");
    _ = frame.button(2, "TWO");
    frame.end();
    try std.testing.expectEqual(@as(?ui.Id, 2), state.focus);

    var gamepad = core.Input{};
    try std.testing.expect(gamepad.addGamepad(7));
    gamepad.setGamepadButton(7, .dpad_down, true);
    frame = ui.Frame.begin(&state, &gamepad, .{ .hud = &canvas }, .{ .cursor = .{}, .width = 20 });
    _ = frame.button(1, "ONE");
    _ = frame.button(2, "TWO");
    frame.end();
    try std.testing.expectEqual(@as(?ui.Id, 1), state.focus);

    gamepad.beginFrame();
    gamepad.setGamepadButton(7, .south, true);
    state.focus = 2;
    frame = ui.Frame.begin(&state, &gamepad, .{ .hud = &canvas }, .{ .cursor = .{}, .width = 20 });
    _ = frame.button(1, "ONE");
    const activated = frame.button(2, "TWO");
    frame.end();
    try std.testing.expect(activated.pressed);
}

test "UI package draws in HUD and camera boundaries without retained nodes" {
    var hud = try core.Canvas.init(std.testing.allocator, 16, 16);
    defer hud.deinit();
    var hud_state = ui.State{};
    var input = core.Input{};
    var hud_frame = ui.Frame.begin(&hud_state, &input, .{ .hud = &hud }, .{ .cursor = .{ .x = 2, .y = 2 }, .width = 8, .row_height = 4 });
    hud_frame.label("HUD");
    _ = hud_frame.button(1, "OK");
    hud_frame.end();
    try std.testing.expect(!std.meta.eql(hud.get(2, 8).?, core.Color.transparent));

    var world = try core.Canvas.init(std.testing.allocator, 16, 16);
    defer world.deinit();
    var camera = core.Camera2D{ .position = .{ .x = 10, .y = 10 } };
    var world_state = ui.State{};
    var world_frame = ui.Frame.begin(&world_state, &input, .{ .world = .init(&world, &camera) }, .{ .cursor = .{ .x = 10, .y = 10 }, .width = 4 });
    _ = world_frame.button(2, "W");
    world_frame.end();
    try std.testing.expect(!std.meta.eql(world.get(8, 8).?, core.Color.transparent));
}
