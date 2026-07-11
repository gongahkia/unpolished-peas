const std = @import("std");

const vorbis = @cImport({
    @cDefine("STB_VORBIS_HEADER_ONLY", "1");
    @cDefine("STB_VORBIS_NO_STDIO", "1");
    @cInclude("stb_vorbis.c");
});

const max_audio_bytes = 128 * 1024 * 1024;
const max_ogg_channels = 8;

pub const AudioSample = struct {
    left: f32 = 0,
    right: f32 = 0,
};

pub const BusHandle = struct {
    index: usize,
};

pub const PlaybackHandle = struct {
    index: usize,
    id: u64,
};

pub const SoundOptions = struct {
    bus: ?BusHandle = null,
    volume: f32 = 1,
    loop: bool = false,
};

pub const MusicOptions = struct {
    bus: ?BusHandle = null,
    volume: f32 = 1,
    loop: bool = true,
};

pub const Sound = struct {
    allocator: std.mem.Allocator,
    sample_rate: u32,
    frames: []AudioSample,

    pub fn loadWav(allocator: std.mem.Allocator, path: []const u8) !Sound {
        const bytes = try std.fs.cwd().readFileAlloc(allocator, path, max_audio_bytes);
        defer allocator.free(bytes);
        return decodeWavSound(allocator, bytes);
    }

    pub fn loadOgg(allocator: std.mem.Allocator, path: []const u8) !Sound {
        const bytes = try std.fs.cwd().readFileAlloc(allocator, path, max_audio_bytes);
        defer allocator.free(bytes);
        return decodeOggSound(allocator, bytes);
    }

    pub fn deinit(self: *Sound) void {
        self.allocator.free(self.frames);
        self.* = undefined;
    }
};

pub const Music = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    kind: MusicKind,

    pub fn openWav(allocator: std.mem.Allocator, path: []const u8) !Music {
        const bytes = try std.fs.cwd().readFileAlloc(allocator, path, max_audio_bytes);
        errdefer allocator.free(bytes);
        return .{ .allocator = allocator, .bytes = bytes, .kind = .{ .wav = try parseWav(bytes) } };
    }

    pub fn openOgg(allocator: std.mem.Allocator, path: []const u8) !Music {
        const bytes = try std.fs.cwd().readFileAlloc(allocator, path, max_audio_bytes);
        errdefer allocator.free(bytes);
        return .{ .allocator = allocator, .bytes = bytes, .kind = .{ .ogg = try parseOggInfo(bytes) } };
    }

    pub fn deinit(self: *Music) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }

    fn info(self: Music) AudioInfo {
        return switch (self.kind) {
            .wav => |wav| .{ .sample_rate = wav.sample_rate, .channels = wav.channels, .frames = wav.frames },
            .ogg => |ogg| .{ .sample_rate = ogg.sample_rate, .channels = ogg.channels, .frames = ogg.frames },
        };
    }
};

pub const AudioMixer = struct {
    pub const Config = struct {
        sample_rate: u32 = 48_000,
    };

    allocator: std.mem.Allocator,
    sample_rate: u32,
    buses: std.ArrayListUnmanaged(Bus) = .{},
    playbacks: std.ArrayListUnmanaged(Playback) = .{},
    next_id: u64 = 1,

    pub fn init(allocator: std.mem.Allocator, config: Config) !AudioMixer {
        if (config.sample_rate == 0) return error.InvalidSampleRate;
        var mixer = AudioMixer{ .allocator = allocator, .sample_rate = config.sample_rate };
        errdefer mixer.deinit();
        _ = try mixer.appendBus("master", null);
        _ = try mixer.appendBus("sfx", masterBus());
        _ = try mixer.appendBus("music", masterBus());
        return mixer;
    }

    pub fn deinit(self: *AudioMixer) void {
        for (self.playbacks.items) |*playback| playback.deinit(self.allocator);
        for (self.buses.items) |*slot| self.allocator.free(slot.name);
        self.playbacks.deinit(self.allocator);
        self.buses.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn masterBus() BusHandle {
        return .{ .index = 0 };
    }

    pub fn sfxBus() BusHandle {
        return .{ .index = 1 };
    }

    pub fn musicBus() BusHandle {
        return .{ .index = 2 };
    }

    pub fn createBus(self: *AudioMixer, name: []const u8, parent: ?BusHandle) !BusHandle {
        return self.appendBus(name, parent orelse masterBus());
    }

    pub fn setBusVolume(self: *AudioMixer, bus: BusHandle, volume: f32) !void {
        try requireVolume(volume);
        const slot = try self.getBus(bus);
        slot.volume = volume;
    }

    pub fn pauseBus(self: *AudioMixer, bus: BusHandle) !void {
        (try self.getBus(bus)).paused = true;
    }

    pub fn resumeBus(self: *AudioMixer, bus: BusHandle) !void {
        (try self.getBus(bus)).paused = false;
    }

    pub fn stopBus(self: *AudioMixer, bus: BusHandle) !void {
        _ = try self.getBus(bus);
        for (self.playbacks.items) |*playback| {
            if (playback.active and self.playbackUsesBus(playback.bus, bus)) playback.deinit(self.allocator);
        }
    }

    pub fn playSound(self: *AudioMixer, sound: *const Sound, options: SoundOptions) !PlaybackHandle {
        try requireVolume(options.volume);
        if (sound.frames.len == 0) return error.EmptySound;
        const bus_handle = options.bus orelse sfxBus();
        _ = try self.getBus(bus_handle);
        var playback = Playback{
            .id = 0,
            .active = true,
            .paused = false,
            .bus = bus_handle,
            .volume = options.volume,
            .loop = options.loop,
            .kind = .{ .sound = .{ .sound = sound } },
        };
        return self.addPlayback(&playback);
    }

    pub fn playMusic(self: *AudioMixer, music: *const Music, options: MusicOptions) !PlaybackHandle {
        try requireVolume(options.volume);
        const bus_handle = options.bus orelse musicBus();
        _ = try self.getBus(bus_handle);
        var playback = Playback{
            .id = 0,
            .active = true,
            .paused = false,
            .bus = bus_handle,
            .volume = options.volume,
            .loop = options.loop,
            .kind = switch (music.kind) {
                .wav => .{ .wav_music = .{ .music = music } },
                .ogg => .{ .ogg_music = try OggPlayback.init(self.allocator, music) },
            },
        };
        errdefer playback.deinit(self.allocator);
        return self.addPlayback(&playback);
    }

    pub fn stop(self: *AudioMixer, handle: PlaybackHandle) bool {
        if (self.getPlayback(handle)) |playback| {
            playback.deinit(self.allocator);
            return true;
        }
        return false;
    }

    pub fn pause(self: *AudioMixer, handle: PlaybackHandle) bool {
        if (self.getPlayback(handle)) |playback| {
            playback.paused = true;
            return true;
        }
        return false;
    }

    pub fn resumePlayback(self: *AudioMixer, handle: PlaybackHandle) bool {
        if (self.getPlayback(handle)) |playback| {
            playback.paused = false;
            return true;
        }
        return false;
    }

    pub fn setPlaybackVolume(self: *AudioMixer, handle: PlaybackHandle, volume: f32) !bool {
        try requireVolume(volume);
        if (self.getPlayback(handle)) |playback| {
            playback.volume = volume;
            return true;
        }
        return false;
    }

    pub fn mix(self: *AudioMixer, out: []AudioSample) !void {
        @memset(out, AudioSample{});
        for (self.playbacks.items) |*playback| {
            if (!playback.active or playback.paused) continue;
            const gain = self.busGain(playback.bus) * playback.volume;
            if (gain == 0) continue;
            const alive = try playback.mix(self, out, gain);
            if (!alive) playback.deinit(self.allocator);
        }
        for (out) |*sample| {
            sample.left = clampUnit(sample.left);
            sample.right = clampUnit(sample.right);
        }
    }

    fn appendBus(self: *AudioMixer, name: []const u8, parent: ?BusHandle) !BusHandle {
        if (name.len == 0) return error.InvalidBusName;
        if (parent) |bus_handle| _ = try self.getBus(bus_handle);
        const owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned);
        const index = self.buses.items.len;
        try self.buses.append(self.allocator, .{ .name = owned, .parent = parent });
        return .{ .index = index };
    }

    fn addPlayback(self: *AudioMixer, playback: *Playback) !PlaybackHandle {
        const id = self.takeId();
        playback.id = id;
        for (self.playbacks.items, 0..) |*slot, i| {
            if (!slot.active) {
                slot.* = playback.*;
                return .{ .index = i, .id = id };
            }
        }
        const index = self.playbacks.items.len;
        try self.playbacks.append(self.allocator, playback.*);
        return .{ .index = index, .id = id };
    }

    fn takeId(self: *AudioMixer) u64 {
        const id = self.next_id;
        self.next_id +%= 1;
        if (self.next_id == 0) self.next_id = 1;
        return id;
    }

    fn getPlayback(self: *AudioMixer, handle: PlaybackHandle) ?*Playback {
        if (handle.index >= self.playbacks.items.len) return null;
        const playback = &self.playbacks.items[handle.index];
        if (!playback.active or playback.id != handle.id) return null;
        return playback;
    }

    fn getBus(self: *AudioMixer, handle: BusHandle) !*Bus {
        if (handle.index >= self.buses.items.len) return error.InvalidBus;
        return &self.buses.items[handle.index];
    }

    fn busConst(self: AudioMixer, handle: BusHandle) ?Bus {
        if (handle.index >= self.buses.items.len) return null;
        return self.buses.items[handle.index];
    }

    fn busGain(self: AudioMixer, handle: BusHandle) f32 {
        var current: ?BusHandle = handle;
        var gain: f32 = 1;
        while (current) |bus_handle| {
            const slot = self.busConst(bus_handle) orelse return 0;
            if (slot.paused) return 0;
            gain *= slot.volume;
            current = slot.parent;
        }
        return gain;
    }

    fn playbackUsesBus(self: AudioMixer, start: BusHandle, target: BusHandle) bool {
        var current: ?BusHandle = start;
        while (current) |bus_handle| {
            if (bus_handle.index == target.index) return true;
            const slot = self.busConst(bus_handle) orelse return false;
            current = slot.parent;
        }
        return false;
    }
};

const Bus = struct {
    name: []u8,
    parent: ?BusHandle,
    volume: f32 = 1,
    paused: bool = false,
};

const AudioInfo = struct {
    sample_rate: u32,
    channels: u16,
    frames: usize,
};

const WavInfo = struct {
    sample_rate: u32,
    channels: u16,
    format: u16,
    bits_per_sample: u16,
    block_align: u16,
    data_start: usize,
    data_len: usize,
    frames: usize,
};

const OggInfo = struct {
    sample_rate: u32,
    channels: u16,
    frames: usize,
};

const MusicKind = union(enum) {
    wav: WavInfo,
    ogg: OggInfo,
};

const Playback = struct {
    id: u64,
    active: bool,
    paused: bool,
    bus: BusHandle,
    volume: f32,
    loop: bool,
    kind: PlaybackKind,

    fn deinit(self: *Playback, allocator: std.mem.Allocator) void {
        if (!self.active) return;
        switch (self.kind) {
            .ogg_music => |*ogg| ogg.deinit(allocator),
            else => {},
        }
        self.active = false;
    }

    fn mix(self: *Playback, mixer: *AudioMixer, out: []AudioSample, gain: f32) !bool {
        return switch (self.kind) {
            .sound => |*sound| mixSound(sound, mixer.sample_rate, self.loop, out, gain),
            .wav_music => |*wav| mixWavMusic(wav, mixer.sample_rate, self.loop, out, gain),
            .ogg_music => |*ogg| try mixOggMusic(ogg, mixer.allocator, mixer.sample_rate, self.loop, out, gain),
        };
    }
};

const PlaybackKind = union(enum) {
    sound: SoundPlayback,
    wav_music: WavPlayback,
    ogg_music: OggPlayback,
};

const SoundPlayback = struct {
    sound: *const Sound,
    pos: f64 = 0,
};

const WavPlayback = struct {
    music: *const Music,
    pos: f64 = 0,
};

const OggPlayback = struct {
    music: *const Music,
    decoder: *vorbis.stb_vorbis,
    buffer: std.ArrayListUnmanaged(AudioSample) = .{},
    start: usize = 0,
    pos: f64 = 0,
    eof: bool = false,

    fn init(allocator: std.mem.Allocator, music: *const Music) !OggPlayback {
        const decoder = try openOggDecoder(music.bytes);
        errdefer vorbis.stb_vorbis_close(decoder);
        _ = allocator;
        return .{ .music = music, .decoder = decoder };
    }

    fn deinit(self: *OggPlayback, allocator: std.mem.Allocator) void {
        vorbis.stb_vorbis_close(self.decoder);
        self.buffer.deinit(allocator);
    }

    fn reset(self: *OggPlayback) void {
        _ = vorbis.stb_vorbis_seek_start(self.decoder);
        self.buffer.clearRetainingCapacity();
        self.start = 0;
        self.pos = 0;
        self.eof = false;
    }

    fn ensure(self: *OggPlayback, allocator: std.mem.Allocator, frame_index: usize) !bool {
        while (frame_index >= self.start + self.buffer.items.len) {
            if (self.eof) return false;
            if (!try self.decodeMore(allocator)) return false;
        }
        return true;
    }

    fn decodeMore(self: *OggPlayback, allocator: std.mem.Allocator) !bool {
        const info = self.music.info();
        var output: [*c][*c]f32 = undefined;
        const got = vorbis.stb_vorbis_get_frame_float(self.decoder, null, &output);
        if (got <= 0) {
            self.eof = true;
            return false;
        }
        var frame: usize = 0;
        while (frame < @as(usize, @intCast(got))) : (frame += 1) {
            try self.buffer.append(allocator, sampleFromVorbis(output, info.channels, frame));
        }
        return true;
    }

    fn trim(self: *OggPlayback, frame_index: usize) void {
        if (frame_index <= self.start + 1024 or self.buffer.items.len <= 8192) return;
        const drop = @min(frame_index - self.start - 1024, self.buffer.items.len);
        std.mem.copyForwards(AudioSample, self.buffer.items[0 .. self.buffer.items.len - drop], self.buffer.items[drop..]);
        self.buffer.items.len -= drop;
        self.start += drop;
    }
};

fn mixSound(playback: *SoundPlayback, mixer_rate: u32, loop: bool, out: []AudioSample, gain: f32) bool {
    const sound = playback.sound;
    const step = rateStep(sound.sample_rate, mixer_rate);
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        const frame_index = normalizePos(&playback.pos, sound.frames.len, loop) orelse return false;
        mixAdd(&out[i], sound.frames[frame_index], gain);
        playback.pos += step;
    }
    return true;
}

fn mixWavMusic(playback: *WavPlayback, mixer_rate: u32, loop: bool, out: []AudioSample, gain: f32) bool {
    const wav = switch (playback.music.kind) {
        .wav => |info| info,
        else => return false,
    };
    const step = rateStep(wav.sample_rate, mixer_rate);
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        const frame_index = normalizePos(&playback.pos, wav.frames, loop) orelse return false;
        mixAdd(&out[i], wavFrame(playback.music.bytes, wav, frame_index), gain);
        playback.pos += step;
    }
    return true;
}

fn mixOggMusic(playback: *OggPlayback, allocator: std.mem.Allocator, mixer_rate: u32, loop: bool, out: []AudioSample, gain: f32) !bool {
    const info = playback.music.info();
    const step = rateStep(info.sample_rate, mixer_rate);
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        var frame_index = normalizePos(&playback.pos, info.frames, loop) orelse return false;
        if (loop and frame_index == 0 and playback.pos == 0 and (playback.start != 0 or playback.eof)) playback.reset();
        if (!try playback.ensure(allocator, frame_index)) {
            if (!loop) return false;
            playback.reset();
            frame_index = 0;
            if (!try playback.ensure(allocator, frame_index)) return false;
        }
        const local = frame_index - playback.start;
        mixAdd(&out[i], playback.buffer.items[local], gain);
        playback.pos += step;
        playback.trim(frame_index);
    }
    return true;
}

fn normalizePos(pos: *f64, frame_count: usize, loop: bool) ?usize {
    if (frame_count == 0) return null;
    const len: f64 = @floatFromInt(frame_count);
    if (loop) {
        while (pos.* >= len) pos.* -= len;
    } else if (pos.* >= len) {
        return null;
    }
    return @intFromFloat(pos.*);
}

fn rateStep(src_rate: u32, dst_rate: u32) f64 {
    return @as(f64, @floatFromInt(src_rate)) / @as(f64, @floatFromInt(dst_rate));
}

fn mixAdd(out: *AudioSample, sample: AudioSample, gain: f32) void {
    out.left += sample.left * gain;
    out.right += sample.right * gain;
}

fn sampleFromVorbis(output: [*c][*c]f32, channels: u16, frame: usize) AudioSample {
    const left = output[0][frame];
    const right = if (channels == 1) left else output[1][frame];
    return .{ .left = left, .right = right };
}

fn requireVolume(volume: f32) !void {
    if (std.math.isNan(volume) or volume < 0) return error.InvalidVolume;
}

fn clampUnit(value: f32) f32 {
    if (value < -1) return -1;
    if (value > 1) return 1;
    return value;
}

fn parseOggInfo(bytes: []const u8) !OggInfo {
    const decoder = try openOggDecoder(bytes);
    defer vorbis.stb_vorbis_close(decoder);
    const info = vorbis.stb_vorbis_get_info(decoder);
    if (info.channels <= 0 or info.channels > max_ogg_channels or info.sample_rate == 0) return error.UnsupportedOgg;
    const frames = vorbis.stb_vorbis_stream_length_in_samples(decoder);
    if (frames == 0) return error.EmptyOgg;
    return .{ .sample_rate = info.sample_rate, .channels = @intCast(info.channels), .frames = frames };
}

fn decodeOggSound(allocator: std.mem.Allocator, bytes: []const u8) !Sound {
    const info = try parseOggInfo(bytes);
    const decoder = try openOggDecoder(bytes);
    defer vorbis.stb_vorbis_close(decoder);
    var frames: std.ArrayListUnmanaged(AudioSample) = .{};
    errdefer frames.deinit(allocator);
    try frames.ensureTotalCapacity(allocator, info.frames);
    while (true) {
        var output: [*c][*c]f32 = undefined;
        const got = vorbis.stb_vorbis_get_frame_float(decoder, null, &output);
        if (got <= 0) break;
        var frame: usize = 0;
        while (frame < @as(usize, @intCast(got))) : (frame += 1) {
            try frames.append(allocator, sampleFromVorbis(output, info.channels, frame));
        }
    }
    if (frames.items.len == 0) return error.EmptyOgg;
    return .{ .allocator = allocator, .sample_rate = info.sample_rate, .frames = try frames.toOwnedSlice(allocator) };
}

fn openOggDecoder(bytes: []const u8) !*vorbis.stb_vorbis {
    if (bytes.len > std.math.maxInt(c_int)) return error.AudioTooLarge;
    var err: c_int = 0;
    return vorbis.stb_vorbis_open_memory(bytes.ptr, @intCast(bytes.len), &err, null) orelse error.InvalidOgg;
}

fn decodeWavSound(allocator: std.mem.Allocator, bytes: []const u8) !Sound {
    const info = try parseWav(bytes);
    const frames = try allocator.alloc(AudioSample, info.frames);
    errdefer allocator.free(frames);
    var i: usize = 0;
    while (i < frames.len) : (i += 1) frames[i] = wavFrame(bytes, info, i);
    return .{ .allocator = allocator, .sample_rate = info.sample_rate, .frames = frames };
}

fn parseWav(bytes: []const u8) !WavInfo {
    if (bytes.len < 44) return error.InvalidWav;
    if (!std.mem.eql(u8, bytes[0..4], "RIFF") or !std.mem.eql(u8, bytes[8..12], "WAVE")) return error.InvalidWav;
    var offset: usize = 12;
    var fmt_seen = false;
    var data_seen = false;
    var format: u16 = 0;
    var channels: u16 = 0;
    var sample_rate: u32 = 0;
    var bits_per_sample: u16 = 0;
    var block_align: u16 = 0;
    var data_start: usize = 0;
    var data_len: usize = 0;
    while (offset + 8 <= bytes.len) {
        const id = bytes[offset .. offset + 4];
        const chunk_len = readU32(bytes[offset + 4 .. offset + 8]);
        offset += 8;
        if (offset + chunk_len > bytes.len) return error.InvalidWav;
        if (std.mem.eql(u8, id, "fmt ")) {
            if (chunk_len < 16) return error.InvalidWav;
            format = readU16(bytes[offset .. offset + 2]);
            channels = readU16(bytes[offset + 2 .. offset + 4]);
            sample_rate = readU32(bytes[offset + 4 .. offset + 8]);
            block_align = readU16(bytes[offset + 12 .. offset + 14]);
            bits_per_sample = readU16(bytes[offset + 14 .. offset + 16]);
            fmt_seen = true;
        } else if (std.mem.eql(u8, id, "data")) {
            data_start = offset;
            data_len = chunk_len;
            data_seen = true;
        }
        offset += chunk_len + (chunk_len & 1);
    }
    if (!fmt_seen or !data_seen) return error.InvalidWav;
    if (sample_rate == 0 or channels == 0 or block_align == 0) return error.InvalidWav;
    if (channels > max_ogg_channels) return error.UnsupportedWav;
    if (!supportedWav(format, bits_per_sample)) return error.UnsupportedWav;
    const frames = data_len / block_align;
    if (frames == 0) return error.EmptyWav;
    return .{
        .sample_rate = sample_rate,
        .channels = channels,
        .format = format,
        .bits_per_sample = bits_per_sample,
        .block_align = block_align,
        .data_start = data_start,
        .data_len = data_len,
        .frames = frames,
    };
}

fn supportedWav(format: u16, bits_per_sample: u16) bool {
    return switch (format) {
        1 => bits_per_sample == 8 or bits_per_sample == 16 or bits_per_sample == 24 or bits_per_sample == 32,
        3 => bits_per_sample == 32,
        else => false,
    };
}

fn wavFrame(bytes: []const u8, info: WavInfo, frame_index: usize) AudioSample {
    const frame_start = info.data_start + frame_index * info.block_align;
    const stride = info.bits_per_sample / 8;
    const left = wavSample(bytes[frame_start .. frame_start + stride], info.format, info.bits_per_sample);
    const right = if (info.channels == 1)
        left
    else
        wavSample(bytes[frame_start + stride .. frame_start + stride * 2], info.format, info.bits_per_sample);
    return .{ .left = left, .right = right };
}

fn wavSample(bytes: []const u8, format: u16, bits_per_sample: u16) f32 {
    if (format == 3) {
        return @bitCast(readU32(bytes[0..4]));
    }
    return switch (bits_per_sample) {
        8 => (@as(f32, @floatFromInt(bytes[0])) - 128.0) / 128.0,
        16 => @as(f32, @floatFromInt(readI16(bytes[0..2]))) / 32768.0,
        24 => @as(f32, @floatFromInt(readI24(bytes[0..3]))) / 8388608.0,
        32 => @as(f32, @floatFromInt(readI32(bytes[0..4]))) / 2147483648.0,
        else => 0,
    };
}

fn readU16(bytes: []const u8) u16 {
    return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
}

fn readU32(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) | (@as(u32, bytes[1]) << 8) | (@as(u32, bytes[2]) << 16) | (@as(u32, bytes[3]) << 24);
}

fn readI16(bytes: []const u8) i16 {
    return @bitCast(readU16(bytes));
}

fn readI24(bytes: []const u8) i32 {
    var value = @as(u32, bytes[0]) | (@as(u32, bytes[1]) << 8) | (@as(u32, bytes[2]) << 16);
    if ((value & 0x00800000) != 0) value |= 0xff000000;
    return @bitCast(value);
}

fn readI32(bytes: []const u8) i32 {
    return @bitCast(readU32(bytes));
}

const wav_mono_16 = [_]u8{
    'R',  'I',  'F', 'F', 40,   0,    0, 0, 'W', 'A', 'V',  'E',
    'f',  'm',  't', ' ', 16,   0,    0, 0, 1,   0,   1,    0,
    0x40, 0x1f, 0,   0,   0x80, 0x3e, 0, 0, 2,   0,   16,   0,
    'd',  'a',  't', 'a', 4,    0,    0, 0, 0,   0,   0xff, 0x7f,
};

test "wav decode valid and invalid files" {
    var sound = try decodeWavSound(std.testing.allocator, &wav_mono_16);
    defer sound.deinit();
    try std.testing.expectEqual(@as(u32, 8000), sound.sample_rate);
    try std.testing.expectEqual(@as(usize, 2), sound.frames.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0), sound.frames[0].left, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.9999), sound.frames[1].right, 0.0001);
    try std.testing.expectError(error.InvalidWav, decodeWavSound(std.testing.allocator, "nope"));
}

test "sound playback handle lifecycle and bus volume" {
    const frames = try std.testing.allocator.dupe(AudioSample, &.{.{ .left = 1, .right = 1 }});
    var sound = Sound{ .allocator = std.testing.allocator, .sample_rate = 48_000, .frames = frames };
    defer sound.deinit();
    var mixer = try AudioMixer.init(std.testing.allocator, .{});
    defer mixer.deinit();
    try mixer.setBusVolume(AudioMixer.masterBus(), 0.5);
    try mixer.setBusVolume(AudioMixer.sfxBus(), 0.5);
    const handle = try mixer.playSound(&sound, .{});
    var out: [1]AudioSample = undefined;
    try mixer.mix(&out);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), out[0].left, 0.0001);
    try std.testing.expect(mixer.pause(handle));
    try mixer.mix(&out);
    try std.testing.expectEqual(@as(f32, 0), out[0].left);
    try std.testing.expect(mixer.resumePlayback(handle));
    try std.testing.expect(mixer.stop(handle));
    try std.testing.expect(!mixer.stop(handle));
}

test "looped wav music streams across buffer boundaries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "tone.wav", .data = &wav_mono_16 });
    const cwd = std.fs.cwd();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp.dir.realpath("tone.wav", &path_buf);
    _ = cwd;
    var music = try Music.openWav(std.testing.allocator, path);
    defer music.deinit();
    var mixer = try AudioMixer.init(std.testing.allocator, .{ .sample_rate = 8000 });
    defer mixer.deinit();
    _ = try mixer.playMusic(&music, .{ .loop = true });
    var out: [5]AudioSample = undefined;
    try mixer.mix(&out);
    try std.testing.expectApproxEqAbs(@as(f32, 0), out[0].left, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.9999), out[1].left, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), out[2].left, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.9999), out[3].left, 0.0001);
}

test "deterministic mixer output hash" {
    const frames = try std.testing.allocator.dupe(AudioSample, &.{ .{ .left = 0.25, .right = -0.25 }, .{ .left = 0.5, .right = -0.5 } });
    var sound = Sound{ .allocator = std.testing.allocator, .sample_rate = 48_000, .frames = frames };
    defer sound.deinit();
    var mixer = try AudioMixer.init(std.testing.allocator, .{});
    defer mixer.deinit();
    _ = try mixer.playSound(&sound, .{ .loop = true, .volume = 0.5 });
    var out: [4]AudioSample = undefined;
    try mixer.mix(&out);
    try std.testing.expectEqual(@as(u64, 0xd29318ef7d25eea5), hashSamples(&out));
}

test "ogg decode fixture" {
    var sound = try Sound.loadOgg(std.testing.allocator, "examples/assets/tone.ogg");
    defer sound.deinit();
    try std.testing.expect(sound.frames.len > 0);
    try std.testing.expect(sound.sample_rate > 0);
}

test "ogg music streams through mixer" {
    var music = try Music.openOgg(std.testing.allocator, "examples/assets/tone.ogg");
    defer music.deinit();
    var mixer = try AudioMixer.init(std.testing.allocator, .{ .sample_rate = music.info().sample_rate });
    defer mixer.deinit();
    _ = try mixer.playMusic(&music, .{ .loop = false });
    var out: [32]AudioSample = undefined;
    try mixer.mix(&out);
    var nonzero = false;
    for (out) |sample| {
        if (sample.left != 0 or sample.right != 0) nonzero = true;
    }
    try std.testing.expect(nonzero);
}

test "headless mixer stress keeps handles and buses stable" {
    var sound = try Sound.loadWav(std.testing.allocator, "examples/assets/blip.wav");
    defer sound.deinit();
    var music = try Music.openOgg(std.testing.allocator, "examples/assets/tone.ogg");
    defer music.deinit();
    var mixer = try AudioMixer.init(std.testing.allocator, .{});
    defer mixer.deinit();

    var handles: [128]PlaybackHandle = undefined;
    for (&handles, 0..) |*handle, index| {
        handle.* = try mixer.playSound(&sound, .{ .volume = if ((index % 2) == 0) 0.02 else 0.01, .loop = true });
    }
    const music_handle = try mixer.playMusic(&music, .{ .volume = 0.08, .loop = true });
    try mixer.pauseBus(AudioMixer.sfxBus());
    var silent: [128]AudioSample = undefined;
    try mixer.mix(&silent);
    try mixer.resumeBus(AudioMixer.sfxBus());
    try mixer.setBusVolume(AudioMixer.masterBus(), 0.5);
    try mixer.setBusVolume(AudioMixer.sfxBus(), 0.75);

    var hash: u64 = 0;
    var block: [512]AudioSample = undefined;
    var i: usize = 0;
    while (i < 96) : (i += 1) {
        try mixer.mix(&block);
        hash ^= hashSamples(&block);
        if (i == 16) try mixer.stopBus(AudioMixer.sfxBus());
        if (i == 32) try std.testing.expect(mixer.stop(music_handle));
    }
    try std.testing.expect(hash != 0);
    try std.testing.expect(!mixer.stop(handles[0]));
}

fn hashSamples(samples: []const AudioSample) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    for (samples) |sample| {
        hash = hashFloat(hash, sample.left);
        hash = hashFloat(hash, sample.right);
    }
    return hash;
}

fn hashFloat(hash_in: u64, value: f32) u64 {
    var hash = hash_in;
    const bits: u32 = @bitCast(value);
    var i: u32 = 0;
    while (i < 32) : (i += 8) {
        hash ^= @as(u8, @truncate(bits >> @as(u5, @intCast(i))));
        hash *%= 0x100000001b3;
    }
    return hash;
}
