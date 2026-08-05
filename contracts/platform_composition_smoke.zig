const std = @import("std");
const core = @import("minna-san-core");
const runtime = @import("minna-san-runtime");
const virtual_network = @import("minna-san-virtual-network-provider");

const SmokeService = struct {
    starts: usize = 0,
    stops: usize = 0,
    routes: usize = 0,

    fn initialize(context: ?*anyopaque) runtime.ServiceModuleError!void {
        const self: *SmokeService = @ptrCast(@alignCast(context.?));
        self.starts += 1;
    }

    fn authorize(_: ?*anyopaque, request: runtime.ServiceRequest) runtime.ServiceModuleError!runtime.ServiceCredentialDecision {
        return if (std.mem.eql(u8, request.credentials, "smoke")) .allow else .deny;
    }

    fn route(context: ?*anyopaque, request: runtime.ServiceRequest) runtime.ServiceModuleError!runtime.ServiceRouteResult {
        const self: *SmokeService = @ptrCast(@alignCast(context.?));
        if (!std.mem.eql(u8, request.payload, "smoke")) return error.CallbackFailed;
        self.routes += 1;
        return .handled;
    }

    fn teardown(context: ?*anyopaque) void {
        const self: *SmokeService = @ptrCast(@alignCast(context.?));
        self.stops += 1;
    }

    fn module(self: *SmokeService) runtime.ServiceModule {
        return .{ .config = .{ .name = "smoke", .route_prefix = "/smoke", .maximum_state_bytes = 16 }, .context = self, .hooks = .{ .initialize = initialize, .authorize = authorize, .route = route, .teardown = teardown } };
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    var clock = core.ManualClock.init(0);
    const sdk = try runtime.SdkConfigBuilder.init().with_clock(clock.clock()).with_platform_config(.{ .limits = .{ .provider_capacity = 1, .service_capacity = 1, .poll_work_budget = 1 } }).build();
    var fake_network = try virtual_network.VirtualNetworkProvider.init(allocator, .{ .network = .{ .seed = 213, .latency_ms = 1, .maximum_packet_bytes = 16, .max_flights = 4, .max_inbox_packets = 4 } });
    defer fake_network.deinit();
    var platform = try runtime.Runtime.init(allocator, sdk);
    errdefer platform.deinit();
    var service = SmokeService{};
    try platform.registerProvider(try fake_network.provider());
    _ = try platform.registerService(service.module());
    try platform.start();
    if (service.starts != 1) return error.ServiceDidNotStart;
    var session = runtime.SessionLifecycle{};
    try session.transition(.begin_establishing);
    try session.transition(.mark_ready);
    const channel = runtime.ChannelDescriptor{ .delivery = .datagram, .maximum_payload_bytes = 16, .maximum_in_flight = 1 };
    try channel.validate_payload("smoke".len);
    const binding = try platform.selectChannel(channel);
    if (binding.transport != .datagram) return error.UnexpectedChannelTransport;
    try fake_network.send(.first_to_second, "smoke");
    try clock.advance(std.time.ns_per_ms);
    var poll = try platform.poll(.{ .now_ns = clock.clock().now(), .work_budget = 1 });
    defer poll.deinit();
    if (poll.provider_work_completed != 1) return error.ProviderDidNotPoll;
    var packet = (try fake_network.receive(.second)) orelse return error.MessageNotDelivered;
    defer packet.deinit(allocator);
    if (packet.from.id != 1 or !std.mem.eql(u8, packet.bytes, "smoke")) return error.InvalidMessage;
    const dispatched = try platform.dispatchService(.{ .route = "/smoke/send", .credentials = "smoke", .payload = packet.bytes });
    if (dispatched.result != .handled or service.routes != 1) return error.ServiceDidNotHandleMessage;
    try session.transition(.begin_draining);
    try session.transition(.close);
    platform.deinit();
    if (service.stops != 1 or session.state != .closed) return error.CompositionDidNotStop;
}
