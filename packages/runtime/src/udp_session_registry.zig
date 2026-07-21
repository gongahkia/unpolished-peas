const std = @import("std");
const protocol = @import("minna-san-protocol");
const transport = @import("minna-san-transport");
const resource = @import("resource_handle.zig");
const session = @import("session_registry.zig");
const channel = @import("channel_registry.zig");
const delivery = @import("channel_delivery.zig");

pub const UdpSessionError = std.mem.Allocator.Error || resource.HandleError || session.SessionRegistryError || channel.ChannelRegistryError || protocol.PacketProtectionError || protocol.ReplayWindowError || protocol.KeyRotationError || protocol.KeyRotationFrameError || transport.EndpointSelectionError || transport.SocketError || transport.Ipv4Error || transport.Ipv6Error || transport.PathMtuProbeError || delivery.ChannelDeliveryError || error{ InvalidConfiguration, InvalidState, ConnectFailed, UnknownSession, EmptyBatch, BatchTooLarge, ReceiveFailed, SendFailed, DatagramTooLarge, WouldBlock, PathMtuUnavailable };

pub const UdpPacketProtectionConfig = struct {
    send_key: protocol.PacketProtectionKey,
    receive_key: protocol.PacketProtectionKey,
    replay: protocol.ReplayWindowConfig = .{},
    key_epoch: protocol.KeyEpoch = 0,
    key_rotation: ?protocol.KeyRotationConfig = null,
};

pub const UdpDialConfig = struct {
    endpoint: transport.Endpoint,
    resolved: []const transport.ResolvedAddress = &.{},
    family_policy: transport.AddressFamilyPolicy = .prefer_ipv6,
    platform_support: transport.PlatformSupport,
    channel: delivery.ChannelDescriptor,
    local_address: ?transport.ResolvedAddress = null,
    path_mtu: ?transport.PathMtuProbeConfig = null,
    packet_protection: ?UdpPacketProtectionConfig = null,
};

pub const UdpSessionPoll = struct {
    state: session.SessionState,
    channel: *resource.ResourceHandle,
};

pub const UdpSessionReadiness = struct {
    session: *resource.ResourceHandle,
    readable: bool = false,
    socket_error: bool = false,
    socket_hangup: bool = false,
    invalid_socket: bool = false,
};

pub const UdpReceiveEvent = struct {
    sequence: u64,
    session: *resource.ResourceHandle,
    channel: *resource.ResourceHandle,
    source: transport.ResolvedAddress,
    payload_len: usize,
};

pub const UdpReceiveBatch = struct {
    received: usize = 0,
    discarded: usize = 0,
    would_block: bool = false,
    backpressured: bool = false,
};

pub const UdpSendEvent = struct {
    sequence: u64,
    session: *resource.ResourceHandle,
    channel: *resource.ResourceHandle,
    payload_len: usize,
    status: transport.UdpSendStatus,
};

pub const UdpSendBatch = struct {
    sent: usize = 0,
    dropped: usize = 0,
    remaining: usize = 0,
    would_block: bool = false,
    retryable: bool = false,
};

const Entry = struct {
    session: *resource.ResourceHandle,
    channel: *resource.ResourceHandle,
    socket: transport.Socket,
    route: transport.DialRoute,
    path_mtu: ?transport.PathMtuProber,
    packet_protection: ?ProtectedDatagrams = null,
};

const EpochSender = struct {
    epoch: protocol.KeyEpoch,
    protector: protocol.PacketProtector,

    fn init(epoch: protocol.KeyEpoch, key: protocol.PacketProtectionKey) EpochSender {
        return .{ .epoch = epoch, .protector = protocol.PacketProtector.init(key) };
    }

    fn deinit(self: *EpochSender) void {
        self.protector.deinit();
        self.* = undefined;
    }
};

const EpochReceiver = struct {
    epoch: protocol.KeyEpoch,
    protector: protocol.PacketProtector,
    replay: protocol.ReplayWindow,

    fn init(epoch: protocol.KeyEpoch, key: protocol.PacketProtectionKey, replay_config: protocol.ReplayWindowConfig) protocol.ReplayWindowError!EpochReceiver {
        return .{ .epoch = epoch, .protector = protocol.PacketProtector.init(key), .replay = try protocol.ReplayWindow.init(replay_config) };
    }

    fn deinit(self: *EpochReceiver) void {
        self.protector.deinit();
        self.replay.reset();
        self.* = undefined;
    }
};

const PendingRotationControl = struct {
    control: protocol.KeyRotationControl,
    epoch: protocol.KeyEpoch,
    switch_sender_after: bool,
};

const DatagramKeyRotation = struct {
    send: protocol.KeyRotation,
    receive: protocol.KeyRotation,
    pending_sender: ?EpochSender = null,
    previous_sender: ?EpochSender = null,
    pending_control: ?PendingRotationControl = null,

    fn deinit(self: *DatagramKeyRotation) void {
        self.send.deinit();
        self.receive.deinit();
        if (self.pending_sender) |*value| value.deinit();
        if (self.previous_sender) |*value| value.deinit();
        self.pending_sender = null;
        self.previous_sender = null;
        self.pending_control = null;
        self.* = undefined;
    }
};

const ProtectedDatagrams = struct {
    sender: EpochSender,
    receiver: EpochReceiver,
    previous_receiver: ?EpochReceiver = null,
    key_rotation: ?DatagramKeyRotation = null,
    replay_config: protocol.ReplayWindowConfig,

    fn init(config: UdpPacketProtectionConfig) UdpSessionError!ProtectedDatagrams {
        if (config.key_rotation != null and config.key_epoch != 0) return error.InvalidConfiguration;
        var value = ProtectedDatagrams{
            .sender = EpochSender.init(config.key_epoch, config.send_key),
            .receiver = try EpochReceiver.init(config.key_epoch, config.receive_key, config.replay),
            .replay_config = config.replay,
        };
        errdefer value.deinit();
        if (config.key_rotation) |rotation_config| {
            var send_rotation = try protocol.KeyRotation.init_packet_key(config.send_key, rotation_config);
            errdefer send_rotation.deinit();
            var receive_rotation = try protocol.KeyRotation.init_packet_key(config.receive_key, rotation_config);
            errdefer receive_rotation.deinit();
            value.key_rotation = .{ .send = send_rotation, .receive = receive_rotation };
        }
        return value;
    }

    fn deinit(self: *ProtectedDatagrams) void {
        self.sender.deinit();
        self.receiver.deinit();
        if (self.previous_receiver) |*value| value.deinit();
        if (self.key_rotation) |*value| value.deinit();
        self.* = undefined;
    }

    fn open(self: *ProtectedDatagrams, input: []const u8, output: []u8) protocol.PacketProtectionError![]const u8 {
        const epoch = try protocol.protected_packet_epoch(input);
        if (epoch == self.receiver.epoch) return openEpoch(&self.receiver, input, output);
        const previous = if (self.previous_receiver) |*value| value else return error.AuthenticationFailed;
        if (epoch != previous.epoch) return error.AuthenticationFailed;
        const payload = try openEpoch(previous, input, output);
        if (self.key_rotation) |*rotation| {
            rotation.receive.confirm_received(epoch) catch return error.AuthenticationFailed;
            var retained = rotation.receive.receive_key(epoch) catch {
                previous.deinit();
                self.previous_receiver = null;
                return payload;
            };
            retained.clear();
        }
        return payload;
    }

    fn forceRotation(self: *ProtectedDatagrams) UdpSessionError!void {
        const rotation = if (self.key_rotation) |*value| value else return error.InvalidConfiguration;
        if (rotation.previous_sender) |*value| value.deinit();
        rotation.previous_sender = null;
        const update = try rotation.send.initiate();
        const receive_update = rotation.receive.initiate() catch |err| {
            _ = rotation.send.recover_failed_rotation() catch {};
            return err;
        };
        if (receive_update.kind != update.kind or receive_update.epoch != update.epoch) return error.InvalidConfiguration;
        var receive_key = rotation.receive.current_key();
        defer receive_key.clear();
        try self.advanceReceiver(receive_key.key, update.epoch);
        var send_key = rotation.send.current_key();
        defer send_key.clear();
        if (rotation.pending_sender) |*value| value.deinit();
        rotation.pending_sender = EpochSender.init(update.epoch, send_key.key);
        rotation.pending_control = .{ .control = update, .epoch = self.sender.epoch, .switch_sender_after = false };
    }

    fn rollbackRotation(self: *ProtectedDatagrams) UdpSessionError!void {
        const rotation = if (self.key_rotation) |*value| value else return error.InvalidConfiguration;
        const rollback = try rotation.send.recover_failed_rotation();
        const receive_rollback = rotation.receive.recover_failed_rotation() catch |err| return err;
        if (receive_rollback.kind != rollback.kind or receive_rollback.epoch != rollback.epoch) return error.InvalidConfiguration;
        try self.restoreReceiver(rollback.epoch);
        if (rotation.pending_sender) |*value| value.deinit();
        rotation.pending_sender = null;
        rotation.pending_control = .{ .control = rollback, .epoch = self.sender.epoch, .switch_sender_after = false };
    }

    fn receiveControl(self: *ProtectedDatagrams, control: protocol.KeyRotationControl) UdpSessionError!void {
        const rotation = if (self.key_rotation) |*value| value else return error.InvalidConfiguration;
        switch (control.kind) {
            .update => {
                const duplicate = control.epoch == rotation.send.current_epoch() and control.epoch == rotation.receive.current_epoch();
                const acknowledgement = try rotation.send.receive_update(control);
                const receive_acknowledgement = try rotation.receive.receive_update(control);
                if (acknowledgement.kind != receive_acknowledgement.kind or acknowledgement.epoch != receive_acknowledgement.epoch) return error.InvalidConfiguration;
                if (duplicate) {
                    rotation.pending_control = .{ .control = acknowledgement, .epoch = self.sender.epoch, .switch_sender_after = false };
                    return;
                }
                var receive_key = rotation.receive.current_key();
                defer receive_key.clear();
                try self.advanceReceiver(receive_key.key, control.epoch);
                var send_key = rotation.send.current_key();
                defer send_key.clear();
                if (rotation.pending_sender) |*value| value.deinit();
                rotation.pending_sender = EpochSender.init(control.epoch, send_key.key);
                rotation.pending_control = .{ .control = acknowledgement, .epoch = self.sender.epoch, .switch_sender_after = true };
            },
            .acknowledge => {
                try rotation.send.receive_acknowledgement(control);
                try rotation.receive.receive_acknowledgement(control);
                try self.activatePendingSender(rotation);
            },
            .rollback => {
                try rotation.send.receive_rollback(control);
                try rotation.receive.receive_rollback(control);
                try self.restoreReceiver(control.epoch);
                if (rotation.previous_sender) |previous| {
                    if (previous.epoch != control.epoch) return error.InvalidState;
                    self.sender.deinit();
                    self.sender = previous;
                    rotation.previous_sender = null;
                } else if (self.sender.epoch != control.epoch) {
                    return error.InvalidState;
                }
                if (rotation.pending_sender) |*value| value.deinit();
                rotation.pending_sender = null;
                rotation.pending_control = null;
            },
        }
    }

    fn hasPendingControl(self: *const ProtectedDatagrams) bool {
        return if (self.key_rotation) |value| value.pending_control != null else false;
    }

    fn sealPendingControl(self: *ProtectedDatagrams, plaintext: []u8, output: []u8) UdpSessionError![]u8 {
        const rotation = if (self.key_rotation) |*value| value else return error.InvalidConfiguration;
        const pending = rotation.pending_control orelse return error.InvalidState;
        if (pending.epoch != self.sender.epoch) return error.InvalidState;
        const payload = try protocol.encode_key_rotation_control(pending.control, plaintext);
        return self.sender.protector.seal_with_epoch(pending.epoch, payload, output);
    }

    fn commitPendingControl(self: *ProtectedDatagrams) UdpSessionError!void {
        const rotation = if (self.key_rotation) |*value| value else return error.InvalidConfiguration;
        const pending = rotation.pending_control orelse return error.InvalidState;
        rotation.pending_control = null;
        if (pending.switch_sender_after) try self.activatePendingSender(rotation);
    }

    fn openEpoch(receiver: *EpochReceiver, input: []const u8, output: []u8) protocol.PacketProtectionError![]const u8 {
        const opened = try receiver.protector.open_with_epoch(input, output);
        if (opened.epoch != receiver.epoch) return error.AuthenticationFailed;
        return switch (receiver.replay.observe(opened.sequence)) {
            .accepted => opened.payload,
            .duplicate => {
                std.crypto.secureZero(u8, output[0..opened.payload.len]);
                return error.DuplicatePacket;
            },
            .too_old => {
                std.crypto.secureZero(u8, output[0..opened.payload.len]);
                return error.TooOldPacket;
            },
        };
    }

    fn advanceReceiver(self: *ProtectedDatagrams, key: protocol.PacketProtectionKey, epoch: protocol.KeyEpoch) UdpSessionError!void {
        const replacement = try EpochReceiver.init(epoch, key, self.replay_config);
        if (self.previous_receiver) |*value| value.deinit();
        self.previous_receiver = self.receiver;
        self.receiver = replacement;
    }

    fn restoreReceiver(self: *ProtectedDatagrams, epoch: protocol.KeyEpoch) UdpSessionError!void {
        const previous = if (self.previous_receiver) |value| value else return error.InvalidState;
        if (previous.epoch != epoch) return error.InvalidState;
        self.receiver.deinit();
        self.receiver = previous;
        self.previous_receiver = null;
    }

    fn activatePendingSender(self: *ProtectedDatagrams, rotation: *DatagramKeyRotation) UdpSessionError!void {
        const pending = rotation.pending_sender orelse return error.InvalidState;
        if (rotation.previous_sender) |*value| value.deinit();
        rotation.previous_sender = self.sender;
        self.sender = pending;
        rotation.pending_sender = null;
    }
};

pub const UdpSessionRegistry = struct {
    allocator: std.mem.Allocator,
    sessions: *session.SessionRegistry,
    channels: *channel.ChannelRegistry,
    capacity: usize,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    next_receive_sequence: u64 = 0,
    next_send_sequence: u64 = 0,
    readiness_cursor: usize = 0,

    pub fn init(allocator: std.mem.Allocator, sessions: *session.SessionRegistry, channels: *channel.ChannelRegistry, capacity: usize) UdpSessionError!UdpSessionRegistry {
        if (capacity == 0 or capacity > sessions.capacity) return error.InvalidConfiguration;
        return .{ .allocator = allocator, .sessions = sessions, .channels = channels, .capacity = capacity };
    }

    pub fn deinit(self: *UdpSessionRegistry) void {
        for (self.entries.items) |*entry| self.closeEntry(entry);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn dial(self: *UdpSessionRegistry, config: UdpDialConfig) UdpSessionError!*resource.ResourceHandle {
        if (self.entries.items.len >= self.capacity) return error.SessionCapacityExceeded;
        if (config.channel.transport() != .datagram) return error.InvalidConfiguration;
        if (config.packet_protection != null and config.channel.maximum_payload_bytes > maximum_protected_payload_bytes) return error.InvalidConfiguration;
        if (config.packet_protection != null and config.path_mtu != null and config.path_mtu.?.minimum_payload <= protected_datagram_overhead) return error.InvalidConfiguration;
        const path_mtu = if (config.path_mtu) |value| try transport.PathMtuProber.init(value) else null;
        const route = try transport.select_dial_route(config.endpoint, config.resolved, config.family_policy, config.platform_support);
        const session_handle = try self.sessions.create();
        errdefer self.closeSession(session_handle);
        try self.sessions.transition(session_handle, .begin_establishing);
        const channel_handle = try self.channels.create(session_handle, config.channel);
        errdefer self.channels.teardown(channel_handle) catch {};
        if (path_mtu) |prober| {
            try self.channels.setSessionDatagramBudget(session_handle, try application_payload_budget(prober.payload_ceiling(), config.packet_protection != null));
        } else if (config.packet_protection != null) try self.channels.setSessionDatagramBudget(session_handle, maximum_protected_payload_bytes);
        errdefer self.channels.clearSessionDatagramBudget(session_handle) catch {};
        var socket = try route.open(.udp);
        errdefer socket.close();
        if (config.local_address) |address| try bindLocal(&socket, route.family, address);
        try connect(&socket, route.address);
        var packet_protection = if (config.packet_protection) |value| try ProtectedDatagrams.init(value) else null;
        errdefer if (packet_protection) |*value| value.deinit();
        try self.entries.append(self.allocator, .{ .session = session_handle, .channel = channel_handle, .socket = socket, .route = route, .path_mtu = path_mtu, .packet_protection = packet_protection });
        return session_handle;
    }

    pub fn poll(self: *UdpSessionRegistry, handle: *resource.ResourceHandle) UdpSessionError!UdpSessionPoll {
        const entry = try self.lookup(handle);
        const lifecycle = try self.sessions.lookup(handle);
        switch (lifecycle.state) {
            .establishing => try lifecycle.transition(.mark_ready),
            .ready => {},
            else => return error.InvalidState,
        }
        return .{ .state = lifecycle.state, .channel = entry.channel };
    }

    pub fn validateSession(self: *UdpSessionRegistry, handle: *resource.ResourceHandle) UdpSessionError!void {
        _ = try self.lookup(handle);
    }

    pub fn resetPacketProtection(self: *UdpSessionRegistry, handle: *resource.ResourceHandle, config: UdpPacketProtectionConfig) UdpSessionError!void {
        const entry = try self.lookup(handle);
        const protection = if (entry.packet_protection) |*value| value else return error.InvalidConfiguration;
        if (protection.key_rotation != null or config.key_rotation != null or config.key_epoch <= protection.sender.epoch) return error.InvalidConfiguration;
        const replacement = try ProtectedDatagrams.init(config);
        protection.deinit();
        protection.* = replacement;
    }

    pub fn forcePacketKeyRotation(self: *UdpSessionRegistry, handle: *resource.ResourceHandle) UdpSessionError!void {
        const entry = try self.lookup(handle);
        const protection = if (entry.packet_protection) |*value| value else return error.InvalidConfiguration;
        try protection.forceRotation();
    }

    pub fn rollbackPacketKeyRotation(self: *UdpSessionRegistry, handle: *resource.ResourceHandle) UdpSessionError!void {
        const entry = try self.lookup(handle);
        const protection = if (entry.packet_protection) |*value| value else return error.InvalidConfiguration;
        try protection.rollbackRotation();
    }

    pub fn pollNextReadiness(self: *UdpSessionRegistry) UdpSessionError!?UdpSessionReadiness {
        if (self.entries.items.len == 0) return null;
        var index = if (self.readiness_cursor < self.entries.items.len) self.readiness_cursor else 0;
        var checked: usize = 0;
        while (checked < self.entries.items.len) : (checked += 1) {
            const entry = &self.entries.items[index];
            const lifecycle = try self.sessions.lookup(entry.session);
            index = next_index(index, self.entries.items.len);
            if (lifecycle.state != .ready) continue;
            const result = try poll_socket(&entry.socket);
            if (!result.readable and !result.socket_error and !result.socket_hangup and !result.invalid_socket) continue;
            self.readiness_cursor = index;
            return .{ .session = entry.session, .readable = result.readable, .socket_error = result.socket_error, .socket_hangup = result.socket_hangup, .invalid_socket = result.invalid_socket };
        }
        self.readiness_cursor = index;
        return null;
    }

    pub fn nextPathMtuProbe(self: *UdpSessionRegistry, handle: *resource.ResourceHandle) UdpSessionError!?usize {
        const entry = try self.lookup(handle);
        const prober = if (entry.path_mtu) |*value| value else return error.PathMtuUnavailable;
        const wire_payload = try prober.next_probe() orelse return null;
        return try application_payload_budget(wire_payload, entry.packet_protection != null);
    }

    pub fn recordPathMtuProbe(self: *UdpSessionRegistry, handle: *resource.ResourceHandle, payload: usize, delivered: bool) UdpSessionError!usize {
        const entry = try self.lookup(handle);
        const prober = if (entry.path_mtu) |*value| value else return error.PathMtuUnavailable;
        const wire_payload = if (entry.packet_protection != null) std.math.add(usize, payload, protected_datagram_overhead) catch return error.DatagramTooLarge else payload;
        try prober.record_delivery(wire_payload, delivered);
        const budget = try application_payload_budget(prober.payload_ceiling(), entry.packet_protection != null);
        try self.channels.setSessionDatagramBudget(handle, budget);
        return budget;
    }

    pub fn pollReceives(self: *UdpSessionRegistry, handle: *resource.ResourceHandle, events: []UdpReceiveEvent) UdpSessionError!UdpReceiveBatch {
        if (events.len == 0) return error.EmptyBatch;
        if (events.len > transport.max_udp_receive_batch) return error.BatchTooLarge;
        const entry = try self.lookup(handle);
        if ((try self.sessions.lookup(handle)).state != .ready) return error.InvalidState;
        var storage: [transport.max_ipv4_datagram_bytes]u8 = undefined;
        var plaintext: [transport.max_ipv4_datagram_bytes]u8 = undefined;
        var batch = UdpReceiveBatch{};
        for (events) |*event| {
            const datagram = receive(&entry.socket, entry.route.family, storage[0..]) catch |err| switch (err) {
                error.WouldBlock => {
                    batch.would_block = true;
                    return batch;
                },
                else => return err,
            };
            const payload: []const u8 = if (entry.packet_protection) |*protection| blk: {
                const opened = protection.open(datagram.bytes, plaintext[0..]) catch {
                    batch.discarded += 1;
                    continue;
                };
                const frame = protocol.decode_protected_datagram_payload(opened) catch {
                    batch.discarded += 1;
                    continue;
                };
                switch (frame) {
                    .application => |value| break :blk value,
                    .key_rotation => |control| {
                        protection.receiveControl(control) catch {
                            batch.discarded += 1;
                            continue;
                        };
                        continue;
                    },
                }
            } else datagram.bytes;
            self.channels.enqueue(entry.channel, payload) catch |err| switch (err) {
                error.PayloadTooLarge => return error.DatagramTooLarge,
                else => return err,
            };
            event.* = .{ .sequence = self.next_receive_sequence, .session = handle, .channel = entry.channel, .source = datagram.source, .payload_len = payload.len };
            self.next_receive_sequence +%= 1;
            batch.received += 1;
        }
        var descriptors = [_]std.posix.pollfd{.{ .fd = entry.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&descriptors, 0) catch return error.ReceiveFailed;
        batch.backpressured = ready != 0 and descriptors[0].revents & std.posix.POLL.IN != 0;
        return batch;
    }

    pub fn flushSends(self: *UdpSessionRegistry, handle: *resource.ResourceHandle, events: []UdpSendEvent) UdpSessionError!UdpSendBatch {
        if (events.len == 0) return error.EmptyBatch;
        if (events.len > transport.max_udp_send_batch) return error.BatchTooLarge;
        const entry = try self.lookup(handle);
        if ((try self.sessions.lookup(handle)).state != .ready) return error.InvalidState;
        var protected_plaintext: [transport.max_ipv4_datagram_bytes]u8 = undefined;
        var ciphertext: [transport.max_ipv4_datagram_bytes]u8 = undefined;
        var batch = UdpSendBatch{};
        if (entry.packet_protection) |*protection| if (protection.hasPendingControl()) {
            const wire_payload = protection.sealPendingControl(protected_plaintext[0..], ciphertext[0..]) catch return error.SendFailed;
            const sent = send_datagram(&entry.socket, wire_payload) catch |err| switch (err) {
                error.WouldBlock => {
                    batch.would_block = true;
                    batch.retryable = true;
                    batch.remaining = try self.channels.queuedDatagrams(handle);
                    return batch;
                },
                else => return error.SendFailed,
            };
            if (sent != wire_payload.len) {
                batch.retryable = true;
                batch.remaining = try self.channels.queuedDatagrams(handle);
                return batch;
            }
            try protection.commitPendingControl();
        };
        for (events) |*event| {
            var message = (try self.channels.dequeueDatagram(handle)) orelse break;
            const channel_handle = message.channel;
            const payload_len = message.payload.len;
            self.channels.validateDatagramPayload(handle, payload_len) catch |err| switch (err) {
                error.PayloadTooLarge => {
                    event.* = self.sendEvent(handle, channel_handle, payload_len, .datagram_too_large);
                    message.deinit(self.allocator);
                    batch.dropped += 1;
                    continue;
                },
                else => return err,
            };
            const wire_payload = if (entry.packet_protection) |*protection| blk: {
                const framed = protocol.encode_protected_datagram_application(message.payload, protected_plaintext[0..]) catch |err| switch (err) {
                    error.OutputTooSmall => {
                        event.* = self.sendEvent(handle, channel_handle, payload_len, .datagram_too_large);
                        message.deinit(self.allocator);
                        batch.dropped += 1;
                        continue;
                    },
                    else => return error.SendFailed,
                };
                break :blk protection.sender.protector.seal_with_epoch(protection.sender.epoch, framed, ciphertext[0..]) catch |err| switch (err) {
                    error.PayloadTooLarge, error.OutputTooSmall => {
                        event.* = self.sendEvent(handle, channel_handle, payload_len, .datagram_too_large);
                        message.deinit(self.allocator);
                        batch.dropped += 1;
                        continue;
                    },
                    else => return error.SendFailed,
                };
            } else message.payload;
            const sent = send_datagram(&entry.socket, wire_payload) catch |err| switch (err) {
                error.WouldBlock => {
                    try self.channels.requeueFront(&message);
                    event.* = self.sendEvent(handle, channel_handle, payload_len, .would_block);
                    batch.would_block = true;
                    batch.retryable = true;
                    break;
                },
                error.DatagramTooLarge => {
                    event.* = self.sendEvent(handle, channel_handle, payload_len, .datagram_too_large);
                    message.deinit(self.allocator);
                    batch.dropped += 1;
                    continue;
                },
                else => {
                    try self.channels.requeueFront(&message);
                    event.* = self.sendEvent(handle, channel_handle, payload_len, .failed);
                    batch.retryable = true;
                    break;
                },
            };
            if (sent != wire_payload.len) {
                try self.channels.requeueFront(&message);
                event.* = self.sendEvent(handle, channel_handle, payload_len, .failed);
                batch.retryable = true;
                break;
            }
            event.* = self.sendEvent(handle, channel_handle, payload_len, .sent);
            message.deinit(self.allocator);
            batch.sent += 1;
        }
        batch.remaining = try self.channels.queuedDatagrams(handle);
        return batch;
    }

    pub fn localAddress(self: *UdpSessionRegistry, handle: *resource.ResourceHandle) UdpSessionError!transport.ResolvedAddress {
        const entry = try self.lookup(handle);
        return switch (entry.route.family) {
            .ipv4 => {
                var native = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
                var length = native.getOsSockLen();
                std.posix.getsockname(entry.socket.handle, &native.any, &length) catch return error.ReceiveFailed;
                return .{ .ipv4 = transport.Ipv4Address.from_native(native) catch return error.ReceiveFailed };
            },
            .ipv6 => {
                var native = std.net.Address.initIp6(.{0} ** 16, 0, 0, 0);
                var length = native.getOsSockLen();
                std.posix.getsockname(entry.socket.handle, &native.any, &length) catch return error.ReceiveFailed;
                return .{ .ipv6 = transport.Ipv6Address.from_native(native) catch return error.ReceiveFailed };
            },
        };
    }

    pub fn close(self: *UdpSessionRegistry, handle: *resource.ResourceHandle) UdpSessionError!void {
        _ = try self.lookup(handle);
        for (self.entries.items, 0..) |_, index| {
            if (self.entries.items[index].session != handle) continue;
            var entry = self.entries.orderedRemove(index);
            self.closeEntry(&entry);
            return;
        }
        return error.UnknownSession;
    }

    fn lookup(self: *UdpSessionRegistry, handle: *resource.ResourceHandle) UdpSessionError!*Entry {
        _ = try self.sessions.lookup(handle);
        for (self.entries.items) |*entry| if (entry.session == handle) return entry;
        return error.UnknownSession;
    }

    fn sendEvent(self: *UdpSessionRegistry, handle: *resource.ResourceHandle, channel_handle: *resource.ResourceHandle, payload_len: usize, status: transport.UdpSendStatus) UdpSendEvent {
        const result = UdpSendEvent{ .sequence = self.next_send_sequence, .session = handle, .channel = channel_handle, .payload_len = payload_len, .status = status };
        self.next_send_sequence +%= 1;
        return result;
    }

    fn closeEntry(self: *UdpSessionRegistry, entry: *Entry) void {
        if (entry.packet_protection) |*value| value.deinit();
        entry.socket.close();
        self.channels.clearSessionDatagramBudget(entry.session) catch {};
        self.channels.teardown(entry.channel) catch {};
        self.closeSession(entry.session);
    }

    fn closeSession(self: *UdpSessionRegistry, handle: *resource.ResourceHandle) void {
        const lifecycle = self.sessions.lookup(handle) catch return;
        switch (lifecycle.state) {
            .establishing, .ready => lifecycle.transition(.begin_draining) catch return,
            .draining => {},
            else => return,
        }
        self.sessions.close(handle) catch {};
    }
};

const protected_datagram_overhead = protocol.packet_protection_epoch_header_bytes + protocol.packet_protection_frame_header_bytes + protocol.packet_protection_tag_bytes + protocol.protected_datagram_payload_tag_bytes;
const maximum_protected_payload_bytes = transport.max_ipv4_datagram_bytes - protected_datagram_overhead;

fn application_payload_budget(wire_payload: usize, protected: bool) UdpSessionError!usize {
    if (!protected) return wire_payload;
    if (wire_payload <= protected_datagram_overhead) return error.InvalidConfiguration;
    return wire_payload - protected_datagram_overhead;
}

fn connect(socket: *transport.Socket, address: transport.ResolvedAddress) UdpSessionError!void {
    const native = switch (address) {
        .ipv4 => |value| value.to_native(),
        .ipv6 => |value| value.to_native(),
    };
    std.posix.connect(socket.handle, &native.any, native.getOsSockLen()) catch return error.ConnectFailed;
}

fn bindLocal(socket: *transport.Socket, family: transport.SocketAddressFamily, address: transport.ResolvedAddress) UdpSessionError!void {
    switch (address) {
        .ipv4 => |value| {
            if (family != .ipv4) return error.InvalidConfiguration;
            try transport.bind(socket, value);
        },
        .ipv6 => |value| {
            if (family != .ipv6) return error.InvalidConfiguration;
            try transport.bind_ipv6(socket, value);
        },
    }
}

fn send_datagram(socket: *transport.Socket, payload: []const u8) UdpSessionError!usize {
    if (payload.len > transport.max_ipv4_datagram_bytes) return error.DatagramTooLarge;
    return std.posix.send(socket.handle, payload, 0) catch |err| switch (err) {
        error.WouldBlock => error.WouldBlock,
        error.MessageTooBig => error.DatagramTooLarge,
        else => error.SendFailed,
    };
}

const SocketReadiness = struct {
    readable: bool = false,
    socket_error: bool = false,
    socket_hangup: bool = false,
    invalid_socket: bool = false,
};

fn poll_socket(socket: *transport.Socket) UdpSessionError!SocketReadiness {
    var descriptors = [_]std.posix.pollfd{.{ .fd = socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
    _ = std.posix.poll(&descriptors, 0) catch return error.ReceiveFailed;
    const events = descriptors[0].revents;
    return .{
        .readable = events & std.posix.POLL.IN != 0,
        .socket_error = events & std.posix.POLL.ERR != 0,
        .socket_hangup = events & std.posix.POLL.HUP != 0,
        .invalid_socket = events & std.posix.POLL.NVAL != 0,
    };
}

fn next_index(index: usize, len: usize) usize {
    return if (index + 1 == len) 0 else index + 1;
}

const ReceivedDatagram = struct {
    bytes: []u8,
    source: transport.ResolvedAddress,
};

fn receive(socket: *transport.Socket, family: transport.SocketAddressFamily, storage: []u8) UdpSessionError!ReceivedDatagram {
    return switch (family) {
        .ipv4 => {
            var native = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
            var length = native.getOsSockLen();
            const received = std.posix.recvfrom(socket.handle, storage, 0, &native.any, &length) catch |err| switch (err) {
                error.WouldBlock => return error.WouldBlock,
                error.MessageTooBig => return error.DatagramTooLarge,
                else => return error.ReceiveFailed,
            };
            return .{ .bytes = storage[0..received], .source = .{ .ipv4 = transport.Ipv4Address.from_native(native) catch return error.ReceiveFailed } };
        },
        .ipv6 => {
            var native = std.net.Address.initIp6(.{0} ** 16, 0, 0, 0);
            var length = native.getOsSockLen();
            const received = std.posix.recvfrom(socket.handle, storage, 0, &native.any, &length) catch |err| switch (err) {
                error.WouldBlock => return error.WouldBlock,
                error.MessageTooBig => return error.DatagramTooLarge,
                else => return error.ReceiveFailed,
            };
            return .{ .bytes = storage[0..received], .source = .{ .ipv6 = transport.Ipv6Address.from_native(native) catch return error.ReceiveFailed } };
        },
    };
}

test "UDP session registries establish selected local routes under explicit polling" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    {
        var resources = try resource.ResourceRegistry.init(allocator, 2);
        defer resources.deinit();
        var sessions = try session.SessionRegistry.init(allocator, &resources, 1);
        defer sessions.deinit();
        var payloads = try @import("payload_pool.zig").PayloadPool.init(allocator, 1, 64);
        defer payloads.deinit();
        var channels = try channel.ChannelRegistry.init(allocator, &resources, &sessions, &payloads, 1);
        defer channels.deinit();
        var udp_sessions = try UdpSessionRegistry.init(allocator, &sessions, &channels, 1);
        defer udp_sessions.deinit();
        const endpoint = transport.Endpoint.from_ipv4(transport.Ipv4Address{ .octets = .{ 127, 0, 0, 1 }, .port = 9 });
        const handle = try udp_sessions.dial(.{ .endpoint = endpoint, .family_policy = .ipv4_only, .platform_support = .{ .ipv4 = true, .ipv6 = false, .dual_stack = false }, .channel = .{ .delivery = .datagram, .maximum_payload_bytes = 64, .maximum_in_flight = 1 } });
        const result = try udp_sessions.poll(handle);
        try std.testing.expectEqual(session.SessionState.ready, result.state);
        try udp_sessions.close(handle);
        try std.testing.expectError(error.StaleHandle, sessions.lookup(handle));
    }
    try std.testing.expectEqual(std.heap.Check.ok, gpa.deinit());
}

test "UDP session receive batches preserve source metadata and pool ownership" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    {
        var resources = try resource.ResourceRegistry.init(allocator, 2);
        defer resources.deinit();
        var sessions = try session.SessionRegistry.init(allocator, &resources, 1);
        defer sessions.deinit();
        var payloads = try @import("payload_pool.zig").PayloadPool.init(allocator, 3, 64);
        defer payloads.deinit();
        var channels = try channel.ChannelRegistry.init(allocator, &resources, &sessions, &payloads, 1);
        defer channels.deinit();
        var udp_sessions = try UdpSessionRegistry.init(allocator, &sessions, &channels, 1);
        defer udp_sessions.deinit();
        var sender = try transport.UdpSocket.init(.{});
        defer sender.close();
        try sender.bind(try transport.Ipv4Address.parse("127.0.0.1", 0));
        const sender_address = local_ipv4_address(&sender);
        const handle = try udp_sessions.dial(.{ .endpoint = transport.Endpoint.from_ipv4(sender_address), .family_policy = .ipv4_only, .platform_support = .{ .ipv4 = true, .ipv6 = false, .dual_stack = false }, .channel = .{ .delivery = .datagram, .maximum_payload_bytes = 64, .maximum_in_flight = 3 } });
        _ = try udp_sessions.poll(handle);
        const destination = switch (try udp_sessions.localAddress(handle)) {
            .ipv4 => |address| address,
            .ipv6 => unreachable,
        };
        _ = try sender.send_to("one", destination);
        _ = try sender.send_to("two", destination);
        _ = try sender.send_to("three", destination);
        var events: [3]UdpReceiveEvent = undefined;
        const batch = try receive_with_retry(&udp_sessions, handle, events[0..]);
        try std.testing.expectEqual(@as(usize, 3), batch.received);
        for (events, 0..) |event, index| {
            try std.testing.expectEqual(@as(u64, @intCast(index)), event.sequence);
            try std.testing.expectEqual(handle, event.session);
            switch (event.source) {
                .ipv4 => |address| try std.testing.expectEqual(sender_address, address),
                .ipv6 => unreachable,
            }
        }
        var first = (try channels.dequeue(handle)).?;
        defer first.deinit(allocator);
        var second = (try channels.dequeue(handle)).?;
        defer second.deinit(allocator);
        var third = (try channels.dequeue(handle)).?;
        defer third.deinit(allocator);
        try std.testing.expectEqualStrings("one", first.payload);
        try std.testing.expectEqualStrings("two", second.payload);
        try std.testing.expectEqualStrings("three", third.payload);
        try udp_sessions.close(handle);
    }
    try std.testing.expectEqual(std.heap.Check.ok, gpa.deinit());
}

test "UDP session send batches preserve priority and report remaining datagrams" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    {
        var resources = try resource.ResourceRegistry.init(allocator, 4);
        defer resources.deinit();
        var sessions = try session.SessionRegistry.init(allocator, &resources, 1);
        defer sessions.deinit();
        var payloads = try @import("payload_pool.zig").PayloadPool.init(allocator, 3, 64);
        defer payloads.deinit();
        var channels = try channel.ChannelRegistry.init(allocator, &resources, &sessions, &payloads, 3);
        defer channels.deinit();
        var udp_sessions = try UdpSessionRegistry.init(allocator, &sessions, &channels, 1);
        defer udp_sessions.deinit();
        var receiver = try transport.UdpSocket.init(.{});
        defer receiver.close();
        try receiver.bind(try transport.Ipv4Address.parse("127.0.0.1", 0));
        const receiver_address = local_ipv4_address(&receiver);
        const handle = try udp_sessions.dial(.{ .endpoint = transport.Endpoint.from_ipv4(receiver_address), .family_policy = .ipv4_only, .platform_support = .{ .ipv4 = true, .ipv6 = false, .dual_stack = false }, .channel = .{ .delivery = .datagram, .priority = 0, .maximum_payload_bytes = 64 } });
        const primary = (try udp_sessions.poll(handle)).channel;
        const low = try channels.create(handle, .{ .delivery = .datagram, .priority = 1, .maximum_payload_bytes = 64 });
        const high = try channels.create(handle, .{ .delivery = .datagram, .priority = 2, .maximum_payload_bytes = 64 });
        try channels.enqueue(primary, "primary");
        try channels.enqueue(low, "low");
        try channels.enqueue(high, "high");
        var events: [2]UdpSendEvent = undefined;
        const first_batch = try udp_sessions.flushSends(handle, events[0..]);
        try std.testing.expectEqual(@as(usize, 2), first_batch.sent);
        try std.testing.expectEqual(@as(usize, 1), first_batch.remaining);
        try std.testing.expectEqual(transport.UdpSendStatus.sent, events[0].status);
        try std.testing.expectEqual(high, events[0].channel);
        try std.testing.expectEqual(transport.UdpSendStatus.sent, events[1].status);
        try std.testing.expectEqual(low, events[1].channel);
        var first_storage: [transport.max_ipv4_datagram_bytes]u8 = undefined;
        var second_storage: [transport.max_ipv4_datagram_bytes]u8 = undefined;
        try std.testing.expectEqualStrings("high", (try receive_from_with_retry(&receiver, first_storage[0..])).bytes);
        try std.testing.expectEqualStrings("low", (try receive_from_with_retry(&receiver, second_storage[0..])).bytes);
        var final_events: [1]UdpSendEvent = undefined;
        const final_batch = try udp_sessions.flushSends(handle, final_events[0..]);
        try std.testing.expectEqual(@as(usize, 1), final_batch.sent);
        try std.testing.expectEqual(@as(usize, 0), final_batch.remaining);
        try std.testing.expectEqual(primary, final_events[0].channel);
        var final_storage: [transport.max_ipv4_datagram_bytes]u8 = undefined;
        try std.testing.expectEqualStrings("primary", (try receive_from_with_retry(&receiver, final_storage[0..])).bytes);
        try channels.teardown(high);
        try channels.teardown(low);
        try udp_sessions.close(handle);
    }
    try std.testing.expectEqual(std.heap.Check.ok, gpa.deinit());
}

test "UDP path-MTU loss lowers queued channel acceptance before flush" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    {
        var resources = try resource.ResourceRegistry.init(allocator, 2);
        defer resources.deinit();
        var sessions = try session.SessionRegistry.init(allocator, &resources, 1);
        defer sessions.deinit();
        var payloads = try @import("payload_pool.zig").PayloadPool.init(allocator, 1, 128);
        defer payloads.deinit();
        var channels = try channel.ChannelRegistry.init(allocator, &resources, &sessions, &payloads, 1);
        defer channels.deinit();
        var udp_sessions = try UdpSessionRegistry.init(allocator, &sessions, &channels, 1);
        defer udp_sessions.deinit();
        var receiver = try transport.UdpSocket.init(.{});
        defer receiver.close();
        try receiver.bind(try transport.Ipv4Address.parse("127.0.0.1", 0));
        const receiver_address = local_ipv4_address(&receiver);
        const handle = try udp_sessions.dial(.{ .endpoint = transport.Endpoint.from_ipv4(receiver_address), .family_policy = .ipv4_only, .platform_support = .{ .ipv4 = true, .ipv6 = false, .dual_stack = false }, .channel = .{ .delivery = .datagram, .maximum_payload_bytes = 128 }, .path_mtu = .{ .minimum_payload = 64, .maximum_payload = 128 } });
        const primary = (try udp_sessions.poll(handle)).channel;
        const oversized = [_]u8{0} ** 97;
        try channels.enqueue(primary, &oversized);
        const probe = (try udp_sessions.nextPathMtuProbe(handle)).?;
        try std.testing.expectEqual(@as(usize, 96), probe);
        try std.testing.expectEqual(@as(usize, 95), try udp_sessions.recordPathMtuProbe(handle, probe, false));
        try std.testing.expectError(error.PayloadTooLarge, channels.enqueue(primary, &oversized));
        var events: [1]UdpSendEvent = undefined;
        const batch = try udp_sessions.flushSends(handle, events[0..]);
        try std.testing.expectEqual(@as(usize, 1), batch.dropped);
        try std.testing.expectEqual(transport.UdpSendStatus.datagram_too_large, events[0].status);
        var storage: [transport.max_ipv4_datagram_bytes]u8 = undefined;
        try std.testing.expectError(error.WouldBlock, receiver.receive_from(storage[0..]));
        try udp_sessions.close(handle);
    }
    try std.testing.expectEqual(std.heap.Check.ok, gpa.deinit());
}

test "UDP sessions enforce bounded replay windows and epoch resets" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    {
        var resources = try resource.ResourceRegistry.init(allocator, 2);
        defer resources.deinit();
        var sessions = try session.SessionRegistry.init(allocator, &resources, 1);
        defer sessions.deinit();
        var payloads = try @import("payload_pool.zig").PayloadPool.init(allocator, 1, 64);
        defer payloads.deinit();
        var channels = try channel.ChannelRegistry.init(allocator, &resources, &sessions, &payloads, 1);
        defer channels.deinit();
        var udp_sessions = try UdpSessionRegistry.init(allocator, &sessions, &channels, 1);
        defer udp_sessions.deinit();
        const send_key = protocol.PacketProtectionKey.init([_]u8{1} ** protocol.packet_protection_key_bytes, [_]u8{2} ** protocol.packet_protection_nonce_prefix_bytes);
        const receive_key = protocol.PacketProtectionKey.init([_]u8{3} ** protocol.packet_protection_key_bytes, [_]u8{4} ** protocol.packet_protection_nonce_prefix_bytes);
        var peer = try transport.UdpSocket.init(.{});
        defer peer.close();
        try peer.bind(try transport.Ipv4Address.parse("127.0.0.1", 0));
        const peer_address = local_ipv4_address(&peer);
        const handle = try udp_sessions.dial(.{ .endpoint = transport.Endpoint.from_ipv4(peer_address), .family_policy = .ipv4_only, .platform_support = .{ .ipv4 = true, .ipv6 = false, .dual_stack = false }, .channel = .{ .delivery = .datagram, .maximum_payload_bytes = 64 }, .packet_protection = .{ .send_key = send_key, .receive_key = receive_key, .replay = .{ .window_size = 2 } } });
        const primary = (try udp_sessions.poll(handle)).channel;
        const local_address = switch (try udp_sessions.localAddress(handle)) {
            .ipv4 => |address| address,
            .ipv6 => unreachable,
        };
        var inbound = protocol.PacketProtector.init(receive_key);
        defer inbound.deinit();
        var zero_plaintext: [protocol.protected_datagram_payload_tag_bytes + 4]u8 = undefined;
        var zero_storage: [protected_datagram_overhead + 4]u8 = undefined;
        const zero = try seal_protected_application(&inbound, 0, "zero", zero_plaintext[0..], zero_storage[0..]);
        _ = try peer.send_to(zero, local_address);
        var events: [1]UdpReceiveEvent = undefined;
        const accepted = try protected_receive_with_retry(&udp_sessions, handle, events[0..]);
        try std.testing.expectEqual(@as(usize, 1), accepted.received);
        try std.testing.expectEqual(@as(usize, 0), accepted.discarded);
        var received = (try channels.dequeue(handle)).?;
        try std.testing.expectEqualStrings("zero", received.payload);
        received.deinit(allocator);
        var one_plaintext: [protocol.protected_datagram_payload_tag_bytes + 3]u8 = undefined;
        var one_storage: [protected_datagram_overhead + 3]u8 = undefined;
        const one = try seal_protected_application(&inbound, 0, "one", one_plaintext[0..], one_storage[0..]);
        var tampered_storage = one_storage;
        const tampered = tampered_storage[0..one.len];
        tampered_storage[protocol.packet_protection_epoch_header_bytes + protocol.packet_protection_frame_header_bytes] +%= 1;
        _ = try peer.send_to(tampered, local_address);
        const rejected = try protected_receive_with_retry(&udp_sessions, handle, events[0..]);
        try std.testing.expectEqual(@as(usize, 0), rejected.received);
        try std.testing.expectEqual(@as(usize, 1), rejected.discarded);
        try std.testing.expect((try channels.dequeue(handle)) == null);
        var two_plaintext: [protocol.protected_datagram_payload_tag_bytes + 3]u8 = undefined;
        var two_storage: [protected_datagram_overhead + 3]u8 = undefined;
        const two = try seal_protected_application(&inbound, 0, "two", two_plaintext[0..], two_storage[0..]);
        _ = try peer.send_to(two, local_address);
        try std.testing.expectEqual(@as(usize, 1), (try protected_receive_with_retry(&udp_sessions, handle, events[0..])).received);
        received = (try channels.dequeue(handle)).?;
        try std.testing.expectEqualStrings("two", received.payload);
        received.deinit(allocator);
        _ = try peer.send_to(one, local_address);
        try std.testing.expectEqual(@as(usize, 1), (try protected_receive_with_retry(&udp_sessions, handle, events[0..])).received);
        received = (try channels.dequeue(handle)).?;
        try std.testing.expectEqualStrings("one", received.payload);
        received.deinit(allocator);
        _ = try peer.send_to(one, local_address);
        try std.testing.expectEqual(@as(usize, 1), (try protected_receive_with_retry(&udp_sessions, handle, events[0..])).discarded);
        try std.testing.expect((try channels.dequeue(handle)) == null);
        var three_plaintext: [protocol.protected_datagram_payload_tag_bytes + 5]u8 = undefined;
        var three_storage: [protected_datagram_overhead + 5]u8 = undefined;
        _ = try peer.send_to(try seal_protected_application(&inbound, 0, "three", three_plaintext[0..], three_storage[0..]), local_address);
        try std.testing.expectEqual(@as(usize, 1), (try protected_receive_with_retry(&udp_sessions, handle, events[0..])).received);
        received = (try channels.dequeue(handle)).?;
        try std.testing.expectEqualStrings("three", received.payload);
        received.deinit(allocator);
        var four_plaintext: [protocol.protected_datagram_payload_tag_bytes + 4]u8 = undefined;
        var four_storage: [protected_datagram_overhead + 4]u8 = undefined;
        _ = try peer.send_to(try seal_protected_application(&inbound, 0, "four", four_plaintext[0..], four_storage[0..]), local_address);
        try std.testing.expectEqual(@as(usize, 1), (try protected_receive_with_retry(&udp_sessions, handle, events[0..])).received);
        received = (try channels.dequeue(handle)).?;
        try std.testing.expectEqualStrings("four", received.payload);
        received.deinit(allocator);
        _ = try peer.send_to(zero, local_address);
        try std.testing.expectEqual(@as(usize, 1), (try protected_receive_with_retry(&udp_sessions, handle, events[0..])).discarded);
        try std.testing.expect((try channels.dequeue(handle)) == null);
        const next_send_key = protocol.PacketProtectionKey.init([_]u8{5} ** protocol.packet_protection_key_bytes, [_]u8{6} ** protocol.packet_protection_nonce_prefix_bytes);
        const next_receive_key = protocol.PacketProtectionKey.init([_]u8{7} ** protocol.packet_protection_key_bytes, [_]u8{8} ** protocol.packet_protection_nonce_prefix_bytes);
        try std.testing.expectError(error.InvalidConfiguration, udp_sessions.resetPacketProtection(handle, .{ .send_key = next_send_key, .receive_key = next_receive_key, .key_epoch = 0 }));
        try udp_sessions.resetPacketProtection(handle, .{ .send_key = next_send_key, .receive_key = next_receive_key, .replay = .{ .window_size = 2 }, .key_epoch = 1 });
        _ = try peer.send_to(two, local_address);
        try std.testing.expectEqual(@as(usize, 1), (try protected_receive_with_retry(&udp_sessions, handle, events[0..])).discarded);
        try std.testing.expect((try channels.dequeue(handle)) == null);
        var next_inbound = protocol.PacketProtector.init(next_receive_key);
        defer next_inbound.deinit();
        var reset_plaintext: [protocol.protected_datagram_payload_tag_bytes + 5]u8 = undefined;
        var reset_storage: [protected_datagram_overhead + 5]u8 = undefined;
        _ = try peer.send_to(try seal_protected_application(&next_inbound, 1, "reset", reset_plaintext[0..], reset_storage[0..]), local_address);
        try std.testing.expectEqual(@as(usize, 1), (try protected_receive_with_retry(&udp_sessions, handle, events[0..])).received);
        received = (try channels.dequeue(handle)).?;
        try std.testing.expectEqualStrings("reset", received.payload);
        received.deinit(allocator);
        try channels.enqueue(primary, "out");
        var sent_events: [1]UdpSendEvent = undefined;
        const sent = try udp_sessions.flushSends(handle, sent_events[0..]);
        try std.testing.expectEqual(@as(usize, 1), sent.sent);
        var wire_storage: [transport.max_ipv4_datagram_bytes]u8 = undefined;
        const wire = try receive_from_with_retry(&peer, wire_storage[0..]);
        try std.testing.expect(!std.mem.eql(u8, wire.bytes, "out"));
        var outbound = protocol.PacketProtector.init(next_send_key);
        defer outbound.deinit();
        var plaintext: [protocol.protected_datagram_payload_tag_bytes + 3]u8 = undefined;
        const opened = try outbound.open_with_epoch(wire.bytes, plaintext[0..]);
        try std.testing.expectEqual(@as(protocol.KeyEpoch, 1), opened.epoch);
        try std.testing.expectEqualStrings("out", (try protocol.decode_protected_datagram_payload(opened.payload)).application);
        try udp_sessions.close(handle);
    }
    try std.testing.expectEqual(std.heap.Check.ok, gpa.deinit());
}

test "UDP sessions rotate packet keys across overlap and rollback" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    {
        var resources = try resource.ResourceRegistry.init(allocator, 2);
        defer resources.deinit();
        var sessions = try session.SessionRegistry.init(allocator, &resources, 1);
        defer sessions.deinit();
        var payloads = try @import("payload_pool.zig").PayloadPool.init(allocator, 1, 64);
        defer payloads.deinit();
        var channels = try channel.ChannelRegistry.init(allocator, &resources, &sessions, &payloads, 1);
        defer channels.deinit();
        var udp_sessions = try UdpSessionRegistry.init(allocator, &sessions, &channels, 1);
        defer udp_sessions.deinit();
        const send_key = protocol.PacketProtectionKey.init([_]u8{1} ** protocol.packet_protection_key_bytes, [_]u8{2} ** protocol.packet_protection_nonce_prefix_bytes);
        const receive_key = protocol.PacketProtectionKey.init([_]u8{3} ** protocol.packet_protection_key_bytes, [_]u8{4} ** protocol.packet_protection_nonce_prefix_bytes);
        var peer = try transport.UdpSocket.init(.{});
        defer peer.close();
        try peer.bind(try transport.Ipv4Address.parse("127.0.0.1", 0));
        const peer_address = local_ipv4_address(&peer);
        const handle = try udp_sessions.dial(.{ .endpoint = transport.Endpoint.from_ipv4(peer_address), .family_policy = .ipv4_only, .platform_support = .{ .ipv4 = true, .ipv6 = false, .dual_stack = false }, .channel = .{ .delivery = .datagram, .maximum_payload_bytes = 64 }, .packet_protection = .{ .send_key = send_key, .receive_key = receive_key, .key_rotation = .{ .overlap_packets = 2 } } });
        const primary = (try udp_sessions.poll(handle)).channel;
        const local_address = switch (try udp_sessions.localAddress(handle)) {
            .ipv4 => |address| address,
            .ipv6 => unreachable,
        };
        var peer_receiver = protocol.PacketProtector.init(send_key);
        defer peer_receiver.deinit();
        var peer_sender = protocol.PacketProtector.init(receive_key);
        defer peer_sender.deinit();
        var peer_send_rotation = try protocol.KeyRotation.init_packet_key(receive_key, .{ .overlap_packets = 2 });
        defer peer_send_rotation.deinit();
        var peer_receive_rotation = try protocol.KeyRotation.init_packet_key(send_key, .{ .overlap_packets = 2 });
        defer peer_receive_rotation.deinit();
        try udp_sessions.forcePacketKeyRotation(handle);
        try channels.enqueue(primary, "during");
        var send_events: [1]UdpSendEvent = undefined;
        try std.testing.expectEqual(@as(usize, 1), (try udp_sessions.flushSends(handle, send_events[0..])).sent);
        var wire_storage: [transport.max_ipv4_datagram_bytes]u8 = undefined;
        var plaintext: [transport.max_ipv4_datagram_bytes]u8 = undefined;
        const update_wire = try receive_from_with_retry(&peer, wire_storage[0..]);
        const update_opened = try peer_receiver.open_with_epoch(update_wire.bytes, plaintext[0..]);
        try std.testing.expectEqual(@as(protocol.KeyEpoch, 0), update_opened.epoch);
        const update = (try protocol.decode_protected_datagram_payload(update_opened.payload)).key_rotation;
        try std.testing.expectEqual(protocol.KeyRotationControlKind.update, update.kind);
        try std.testing.expectEqual(@as(protocol.KeyEpoch, 1), update.epoch);
        const acknowledgement = try peer_send_rotation.receive_update(update);
        _ = try peer_receive_rotation.receive_update(update);
        var next_peer_send_key = peer_send_rotation.current_key();
        defer next_peer_send_key.clear();
        var next_peer_sender = protocol.PacketProtector.init(next_peer_send_key.key);
        defer next_peer_sender.deinit();
        var next_peer_receive_key = peer_receive_rotation.current_key();
        defer next_peer_receive_key.clear();
        var next_peer_receiver = protocol.PacketProtector.init(next_peer_receive_key.key);
        defer next_peer_receiver.deinit();
        const during_wire = try receive_from_with_retry(&peer, wire_storage[0..]);
        const during_opened = try peer_receiver.open_with_epoch(during_wire.bytes, plaintext[0..]);
        try std.testing.expectEqual(@as(protocol.KeyEpoch, 0), during_opened.epoch);
        try std.testing.expectEqualStrings("during", (try protocol.decode_protected_datagram_payload(during_opened.payload)).application);
        var acknowledgement_plaintext: [protocol.key_rotation_control_frame_bytes]u8 = undefined;
        var acknowledgement_wire: [protocol.packet_protection_epoch_header_bytes + protocol.packet_protection_frame_header_bytes + protocol.key_rotation_control_frame_bytes + protocol.packet_protection_tag_bytes]u8 = undefined;
        _ = try peer.send_to(try peer_sender.seal_with_epoch(0, try protocol.encode_key_rotation_control(acknowledgement, acknowledgement_plaintext[0..]), acknowledgement_wire[0..]), local_address);
        try process_protected_control_with_retry(&udp_sessions, handle);
        var overlap_plaintext: [protocol.protected_datagram_payload_tag_bytes + 7]u8 = undefined;
        var overlap_wire: [protected_datagram_overhead + 7]u8 = undefined;
        _ = try peer.send_to(try seal_protected_application(&peer_sender, 0, "overlap", overlap_plaintext[0..], overlap_wire[0..]), local_address);
        var receive_events: [1]UdpReceiveEvent = undefined;
        try std.testing.expectEqual(@as(usize, 1), (try protected_receive_with_retry(&udp_sessions, handle, receive_events[0..])).received);
        var received = (try channels.dequeue(handle)).?;
        try std.testing.expectEqualStrings("overlap", received.payload);
        received.deinit(allocator);
        var current_plaintext: [protocol.protected_datagram_payload_tag_bytes + 7]u8 = undefined;
        var current_wire: [protected_datagram_overhead + 7]u8 = undefined;
        _ = try peer.send_to(try seal_protected_application(&next_peer_sender, 1, "current", current_plaintext[0..], current_wire[0..]), local_address);
        try std.testing.expectEqual(@as(usize, 1), (try protected_receive_with_retry(&udp_sessions, handle, receive_events[0..])).received);
        received = (try channels.dequeue(handle)).?;
        try std.testing.expectEqualStrings("current", received.payload);
        received.deinit(allocator);
        try channels.enqueue(primary, "after");
        try std.testing.expectEqual(@as(usize, 1), (try udp_sessions.flushSends(handle, send_events[0..])).sent);
        const after_wire = try receive_from_with_retry(&peer, wire_storage[0..]);
        const after_opened = try next_peer_receiver.open_with_epoch(after_wire.bytes, plaintext[0..]);
        try std.testing.expectEqual(@as(protocol.KeyEpoch, 1), after_opened.epoch);
        try std.testing.expectEqualStrings("after", (try protocol.decode_protected_datagram_payload(after_opened.payload)).application);
        try udp_sessions.forcePacketKeyRotation(handle);
        try udp_sessions.rollbackPacketKeyRotation(handle);
        try channels.enqueue(primary, "rollback");
        try std.testing.expectEqual(@as(usize, 1), (try udp_sessions.flushSends(handle, send_events[0..])).sent);
        const rollback_control_wire = try receive_from_with_retry(&peer, wire_storage[0..]);
        const rollback_control_opened = try next_peer_receiver.open_with_epoch(rollback_control_wire.bytes, plaintext[0..]);
        try std.testing.expectEqual(@as(protocol.KeyEpoch, 1), rollback_control_opened.epoch);
        const rollback = (try protocol.decode_protected_datagram_payload(rollback_control_opened.payload)).key_rotation;
        try std.testing.expectEqual(protocol.KeyRotationControlKind.rollback, rollback.kind);
        try std.testing.expectEqual(@as(protocol.KeyEpoch, 1), rollback.epoch);
        const rollback_wire = try receive_from_with_retry(&peer, wire_storage[0..]);
        const rollback_opened = try next_peer_receiver.open_with_epoch(rollback_wire.bytes, plaintext[0..]);
        try std.testing.expectEqual(@as(protocol.KeyEpoch, 1), rollback_opened.epoch);
        try std.testing.expectEqualStrings("rollback", (try protocol.decode_protected_datagram_payload(rollback_opened.payload)).application);
        try udp_sessions.close(handle);
    }
    try std.testing.expectEqual(std.heap.Check.ok, gpa.deinit());
}

fn seal_protected_application(protector: *protocol.PacketProtector, epoch: protocol.KeyEpoch, payload: []const u8, plaintext: []u8, output: []u8) ![]u8 {
    return protector.seal_with_epoch(epoch, try protocol.encode_protected_datagram_application(payload, plaintext), output);
}

fn process_protected_control_with_retry(registry: *UdpSessionRegistry, handle: *resource.ResourceHandle) UdpSessionError!void {
    var events: [1]UdpReceiveEvent = undefined;
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        const batch = try registry.pollReceives(handle, events[0..]);
        if (!batch.would_block) {
            if (batch.received != 0 or batch.discarded != 0) return error.ReceiveFailed;
            return;
        }
        std.Thread.sleep(std.time.ns_per_ms);
    }
    return error.ReceiveFailed;
}

fn local_ipv4_address(socket: *transport.UdpSocket) transport.Ipv4Address {
    var native = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
    var length = native.getOsSockLen();
    std.posix.getsockname(socket.socket.handle, &native.any, &length) catch unreachable;
    return transport.Ipv4Address.from_native(native) catch unreachable;
}

fn receive_with_retry(registry: *UdpSessionRegistry, handle: *resource.ResourceHandle, events: []UdpReceiveEvent) UdpSessionError!UdpReceiveBatch {
    var total = UdpReceiveBatch{};
    var attempts: usize = 0;
    while (total.received < events.len and attempts < 100) : (attempts += 1) {
        const batch = try registry.pollReceives(handle, events[total.received..]);
        total.received += batch.received;
        total.backpressured = batch.backpressured;
        total.would_block = batch.would_block;
        if (batch.would_block) std.Thread.sleep(std.time.ns_per_ms);
    }
    if (total.received != events.len) return error.ReceiveFailed;
    return total;
}

fn protected_receive_with_retry(registry: *UdpSessionRegistry, handle: *resource.ResourceHandle, events: []UdpReceiveEvent) UdpSessionError!UdpReceiveBatch {
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        const batch = try registry.pollReceives(handle, events);
        if (batch.received != 0 or batch.discarded != 0) return batch;
        if (batch.would_block) std.Thread.sleep(std.time.ns_per_ms);
    }
    return error.ReceiveFailed;
}

fn receive_from_with_retry(socket: *transport.UdpSocket, storage: []u8) !transport.ReceivedDatagram {
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        return socket.receive_from(storage) catch |err| switch (err) {
            error.WouldBlock => {
                std.Thread.sleep(std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
    }
    return error.WouldBlock;
}
