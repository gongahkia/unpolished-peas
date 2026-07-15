const std = @import("std");
const up = @import("unpolished-peas");
const sdl = @import("unpolished-peas-sdl3");
const game_mod = @import("topdown_game.zig");

var launch_listen_host = false;

const ListenRuntime = struct {
    allocator: std.mem.Allocator,
    client_endpoint: up.LoopbackTransport,
    host_endpoint: up.LoopbackTransport,
    host: up.NetHost,
    client: up.NetClient,

    fn init(allocator: std.mem.Allocator) !ListenRuntime {
        var client_endpoint = up.LoopbackTransport.init(allocator, .{ .id = 1 });
        errdefer client_endpoint.deinit();
        var host_endpoint = up.LoopbackTransport.init(allocator, .{ .id = 2 });
        errdefer host_endpoint.deinit();
        up.LoopbackTransport.pair(&client_endpoint, &host_endpoint);
        var host = try up.NetHost.init(allocator, host_endpoint.transport(), .{ .role = .listen });
        errdefer host.deinit();
        var client = try up.NetClient.init(allocator, client_endpoint.transport(), .{});
        try client.connect(.{ .id = 2 }, 1);
        try client.poll();
        try host.poll();
        try client.poll();
        return .{ .allocator = allocator, .client_endpoint = client_endpoint, .host_endpoint = host_endpoint, .host = host, .client = client };
    }

    fn deinit(self: *ListenRuntime) void {
        self.host.deinit();
        self.host_endpoint.deinit();
        self.client_endpoint.deinit();
        self.* = undefined;
    }

    fn submit(self: *ListenRuntime, local_input: up.Input) !up.Input {
        var mask: u8 = 0;
        if (local_input.isDown(.left)) mask |= 1;
        if (local_input.isDown(.right)) mask |= 2;
        if (local_input.isDown(.up)) mask |= 4;
        if (local_input.isDown(.down)) mask |= 8;
        if (local_input.isDown(.action)) mask |= 16;
        try self.client.sendInput(&.{mask});
        try self.client.poll();
        try self.host.poll();
        var authoritative = up.Input{};
        while (self.host.nextEvent()) |received| {
            var event = received;
            defer event.deinit(self.allocator);
            switch (event) {
                .input => |value| {
                    const payload = value.message.payload[up.netPeer.session_token_bytes..];
                    if (payload.len != 1) continue;
                    authoritative.set(.left, payload[0] & 1 != 0);
                    authoritative.set(.right, payload[0] & 2 != 0);
                    authoritative.set(.up, payload[0] & 4 != 0);
                    authoritative.set(.down, payload[0] & 8 != 0);
                    authoritative.set(.action, payload[0] & 16 != 0);
                },
                else => {},
            }
        }
        return authoritative;
    }
};

const Game = struct {
    game: game_mod.Game = .{},
    map: up.TileMapHandle,
    player: up.ImageHandle,
    blip: up.Sound,
    camera: up.Camera2D = .{ .position = .{ .x = 80, .y = 48 } },
    listen: ?ListenRuntime = null,

    pub fn init(ctx: *sdl.Context) !Game {
        const path = try ctx.assetPath("blip.wav");
        defer ctx.allocator.free(path);
        var game = Game{ .map = try ctx.loadTileMap("topdown.tmj"), .player = try ctx.loadPng("ball.png"), .blip = try up.Sound.loadWav(ctx.allocator, path) };
        errdefer game.blip.deinit();
        if (launch_listen_host) game.listen = try ListenRuntime.init(ctx.allocator);
        return game;
    }
    pub fn deinit(self: *Game, _: *sdl.Context) void {
        if (self.listen) |*runtime| runtime.deinit();
        self.blip.deinit();
    }
    pub fn update(self: *Game, ctx: *sdl.Context) !void {
        const input = if (self.listen) |*runtime| try runtime.submit(ctx.input.*) else ctx.input.*;
        const event = self.game.step(input, ctx.dt);
        self.camera.position = self.game.player;
        if (event.fired) _ = try ctx.audio.playSound(&self.blip, .{ .volume = 0.3 });
    }
    pub fn draw(self: *Game, ctx: *sdl.Context) void {
        ctx.drawTileMap(self.map, &self.camera, 0);
        ctx.image(self.player, @intFromFloat(self.game.player.x - 8), @intFromFloat(self.game.player.y - 8));
        ctx.text("TOPDOWN", 4, 4, up.Color.white);
        ctx.text("ARROWS SPACE", 84, 4, up.Color.rgb(180, 205, 230));
    }
};

pub fn main() !void {
    var args = try std.process.argsWithAllocator(std.heap.page_allocator);
    defer args.deinit();
    _ = args.next();
    if (args.next()) |argument| {
        if (!std.mem.eql(u8, argument, "--listen-host") or args.next() != null) return error.InvalidArguments;
        launch_listen_host = true;
    }
    try sdl.play(.{ .title = "unpolished-peas Top Down", .width = game_mod.width, .height = game_mod.height, .scale = 5, .fixed_hz = 60, .clear_color = up.Color.rgb(10, 18, 26) }, Game);
}
