const std = @import("std");
const builtin = @import("builtin");
const vorbis = @cImport({
    @cDefine("STB_VORBIS_HEADER_ONLY", "1");
    @cDefine("STB_VORBIS_NO_STDIO", "1");
    @cInclude("stb_vorbis.c");
});

pub const stable_asset_diagnostic = "asset_load_failed:audio_v1";
pub const stable_max_input_bytes = 32 * 1024 * 1024;
pub const stable_max_decoded_frames = 4 * 1024 * 1024;
const max_audio_bytes = stable_max_input_bytes;
const max_ogg_channels = 8;
const stream_buffer_frames = 16 * 1024;
const stream_decode_frames = 1024;
const wasm_ogg_decoder_bytes = 1024 * 1024;

pub const AudioSample = struct {
    left: f32 = 0,
    right: f32 = 0,
};

pub const BusHandle = struct { // borrows an AudioMixer bus; invalid bus access returns error.InvalidBus.
    index: usize,
};

pub const PlaybackHandle = struct { // borrows an AudioMixer playback; false from control methods means the playback is stale.
    index: usize,
    id: u64,
};

pub const SoundOptions = struct {
    bus: ?BusHandle = null,
    volume: f32 = 1,
    pan: f32 = 0,
    loop: bool = false,
};

pub const MusicOptions = struct {
    bus: ?BusHandle = null,
    volume: f32 = 1,
    pan: f32 = 0,
    loop: bool = true,
};

pub const Sound = struct { // owns decoded frames allocated by loadWav; call deinit after all adapter playback stops.
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

    pub fn decodeWav(allocator: std.mem.Allocator, bytes: []const u8) !Sound {
        if (bytes.len > stable_max_input_bytes) return error.AudioTooLarge;
        return decodeWavSound(allocator, bytes);
    }

    pub fn decodeOgg(allocator: std.mem.Allocator, bytes: []const u8) !Sound {
        return decodeOggSound(allocator, bytes);
    }

    pub fn deinit(self: *Sound) void {
        self.allocator.free(self.frames);
        self.* = undefined;
    }
};

pub const Music = struct { // owns source bytes allocated by openWav/openOgg; moving the value is safe, but call deinit only after all mixer playback stops.
    allocator: std.mem.Allocator,
    bytes: []u8,
    kind: MusicKind,

    pub fn openWav(allocator: std.mem.Allocator, path: []const u8) !Music {
        const bytes = try std.fs.cwd().readFileAlloc(allocator, path, max_audio_bytes);
        errdefer allocator.free(bytes);
        return .{ .allocator = allocator, .bytes = bytes, .kind = .{ .wav = try parseMusicWav(bytes) } };
    }

    pub fn openOgg(allocator: std.mem.Allocator, path: []const u8) !Music {
        const bytes = try std.fs.cwd().readFileAlloc(allocator, path, max_audio_bytes);
        errdefer allocator.free(bytes);
        return .{ .allocator = allocator, .bytes = bytes, .kind = .{ .ogg = try parseOggInfo(allocator, bytes) } };
    }

    pub fn decodeWav(allocator: std.mem.Allocator, source: []const u8) !Music {
        if (source.len > stable_max_input_bytes) return error.AudioTooLarge;
        const bytes = try allocator.dupe(u8, source);
        errdefer allocator.free(bytes);
        return .{ .allocator = allocator, .bytes = bytes, .kind = .{ .wav = try parseMusicWav(bytes) } };
    }

    pub fn decodeOgg(allocator: std.mem.Allocator, source: []const u8) !Music {
        if (source.len > stable_max_input_bytes) return error.AudioTooLarge;
        const bytes = try allocator.dupe(u8, source);
        errdefer allocator.free(bytes);
        return .{ .allocator = allocator, .bytes = bytes, .kind = .{ .ogg = try parseOggInfo(allocator, bytes) } };
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

pub const AudioMixer = struct { // owns buses, playbacks, and stream state allocated by init; call deinit before borrowed Sound/Music values.
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
        try requirePan(options.pan);
        if (sound.frames.len == 0) return error.EmptySound;
        const bus_handle = options.bus orelse sfxBus();
        _ = try self.getBus(bus_handle);
        var playback = Playback{
            .id = 0,
            .active = true,
            .paused = false,
            .bus = bus_handle,
            .volume = options.volume,
            .pan = options.pan,
            .loop = options.loop,
            .kind = .{ .sound = .{ .sound = sound } },
        };
        return self.addPlayback(&playback);
    }

    pub fn playMusic(self: *AudioMixer, music: *const Music, options: MusicOptions) !PlaybackHandle {
        try requireVolume(options.volume);
        try requirePan(options.pan);
        const bus_handle = options.bus orelse musicBus();
        _ = try self.getBus(bus_handle);
        var playback = Playback{
            .id = 0,
            .active = true,
            .paused = false,
            .bus = bus_handle,
            .volume = options.volume,
            .pan = options.pan,
            .loop = options.loop,
            .kind = switch (music.kind) {
                .wav => |info| .{ .wav_music = .{ .bytes = music.bytes, .info = info } },
                .ogg => |info| .{ .ogg_music = try OggPlayback.init(self.allocator, music.bytes, info) },
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

    pub fn setPlaybackPan(self: *AudioMixer, handle: PlaybackHandle, pan: f32) !bool {
        try requirePan(pan);
        if (self.getPlayback(handle)) |playback| {
            playback.pan = pan;
            return true;
        }
        return false;
    }

    pub fn fadePlayback(self: *AudioMixer, handle: PlaybackHandle, target_volume: f32, frames: u32) !bool {
        try requireVolume(target_volume);
        if (self.getPlayback(handle)) |playback| {
            if (frames == 0) {
                playback.volume = target_volume;
                playback.fade = null;
            } else {
                playback.fade = .{ .target = target_volume, .remaining = frames, .step = (target_volume - playback.volume) / @as(f32, @floatFromInt(frames)) };
            }
            return true;
        }
        return false;
    }

    pub fn mix(self: *AudioMixer, out: []AudioSample) !void {
        @memset(out, AudioSample{});
        for (self.playbacks.items) |*playback| {
            if (!playback.active or playback.paused) continue;
            const gain = self.busGain(playback.bus);
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

/// A small, host-owned sound-effect service for `GameProtocol` games.
///
/// `loadWav` decodes bytes once and returns a reusable handle. The service owns
/// every decoded sound and releases it in `deinit`, after stopping its mixer.
/// A game therefore stores handles but never frees individual sound resources.
/// This intentionally covers short WAV effects; the lower-level `AudioMixer`
/// and `AssetStore` APIs remain available for advanced/native use cases.
pub const Audio = struct {
    pub const Availability = enum {
        /// Playback requests are accepted and can be mixed by the host.
        ready,
        /// The host exists but cannot play yet (for example browser autoplay
        /// policy before the first user gesture).
        blocked,
        /// The host has no usable output device or audio implementation.
        unavailable,
    };

    pub const Config = struct {
        sample_rate: u32 = 48_000,
        availability: Availability = .ready,
    };

    /// Stable only for the lifetime of its owning `Audio` service.
    pub const SoundHandle = struct {
        index: usize,
        generation: u32,
    };

    /// Stable only for the lifetime of its owning `Audio` service. Music is
    /// deliberately distinct from `SoundHandle`: its encoded source remains
    /// owned by the host while an active playback incrementally decodes it.
    pub const MusicHandle = struct {
        index: usize,
        generation: u32,
    };

    /// OGG/Vorbis is the default because it is the compact, incrementally
    /// decoded long-form path on every supported host. WAV is accepted for
    /// small authored tracks, but is normally less space-efficient.
    pub const MusicFormat = enum {
        ogg,
        wav,
    };

    pub const MusicLoadOptions = struct {
        format: MusicFormat = .ogg,
    };

    /// Per-request music controls. The high-level service keeps one active
    /// music stream; starting another replaces the prior music playback while
    /// preserving independently playing sound effects.
    pub const MusicPlayOptions = struct {
        volume: f32 = 1,
        loop: bool = true,
    };

    pub const MusicState = enum {
        stopped,
        playing,
        paused,
    };

    /// A small observation surface shared by native developer diagnostics.
    /// `underruns` is currently always zero: music decode/refill happens
    /// synchronously before host PCM submission rather than in an audio
    /// callback. It is retained as an explicit statement of that behavior,
    /// not a device-underrun measurement.
    pub const MusicDiagnostics = struct {
        state: MusicState = .stopped,
        encoded_bytes: usize = 0,
        source_frames: usize = 0,
        decoder_position_frames: usize = 0,
        buffered_frames: usize = 0,
        buffer_capacity_frames: usize = 0,
        underruns: u32 = 0,
    };

    /// Per-request controls. Volume is finite and in the inclusive range
    /// `0.0...1.0`; looping repeats the decoded effect until stopped.
    pub const PlayOptions = struct {
        volume: f32 = 1,
        loop: bool = false,
    };

    const OwnedSound = struct {
        sound: Sound,
        generation: u32,
    };

    const OwnedMusic = struct {
        music: Music,
        generation: u32,
    };

    allocator: std.mem.Allocator,
    mixer: AudioMixer,
    sounds: std.ArrayListUnmanaged(*OwnedSound) = .{},
    music_sources: std.ArrayListUnmanaged(*OwnedMusic) = .{},
    active_music: ?PlaybackHandle = null,
    availability_state: Availability,
    next_generation: u32 = 1,
    next_music_generation: u32 = 1,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Audio {
        return .{
            .allocator = allocator,
            .mixer = try AudioMixer.init(allocator, .{ .sample_rate = config.sample_rate }),
            .availability_state = config.availability,
        };
    }

    pub fn deinit(self: *Audio) void {
        self.mixer.deinit();
        for (self.sounds.items) |owned| {
            owned.sound.deinit();
            self.allocator.destroy(owned);
        }
        for (self.music_sources.items) |owned| {
            owned.music.deinit();
            self.allocator.destroy(owned);
        }
        self.sounds.deinit(self.allocator);
        self.music_sources.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn availability(self: *const Audio) Availability {
        return self.availability_state;
    }

    /// Host adapters update availability as devices or browser gesture state
    /// changes. Normal game code should only inspect `availability`.
    pub fn setAvailability(self: *Audio, state: Availability) void {
        self.availability_state = state;
    }

    /// Decodes a small WAV effect from game-owned bytes. This performs no I/O;
    /// `@embedFile` is the portable way to load a starter-sized effect during
    /// `Game.init` on both desktop and browser builds.
    pub fn loadWav(self: *Audio, bytes: []const u8) !SoundHandle {
        const owned = try self.allocator.create(OwnedSound);
        errdefer self.allocator.destroy(owned);
        owned.* = .{
            .sound = try Sound.decodeWav(self.allocator, bytes),
            .generation = self.takeGeneration(),
        };
        errdefer owned.sound.deinit();
        try self.sounds.append(self.allocator, owned);
        return .{ .index = self.sounds.items.len - 1, .generation = owned.generation };
    }

    /// Retains encoded game-owned bytes and creates a source suitable for
    /// bounded, incremental playback. No full-track PCM allocation occurs.
    /// OGG/Vorbis is the default; select `.wav` explicitly for WAV source.
    pub fn loadMusic(self: *Audio, bytes: []const u8, options: MusicLoadOptions) !MusicHandle {
        const owned = try self.allocator.create(OwnedMusic);
        errdefer self.allocator.destroy(owned);
        owned.* = .{
            .music = switch (options.format) {
                .ogg => try Music.decodeOgg(self.allocator, bytes),
                .wav => try Music.decodeWav(self.allocator, bytes),
            },
            .generation = self.takeMusicGeneration(),
        };
        errdefer owned.music.deinit();
        try self.music_sources.append(self.allocator, owned);
        return .{ .index = self.music_sources.items.len - 1, .generation = owned.generation };
    }

    /// Starts an independent playback instance. It is safe to play the same
    /// loaded effect concurrently. A blocked or unavailable host returns a
    /// recoverable error and does not create a hidden queued playback.
    pub fn play(self: *Audio, sound: SoundHandle, options: PlayOptions) !PlaybackHandle {
        if (self.availability_state != .ready) return error.AudioUnavailable;
        if (std.math.isNan(options.volume) or options.volume < 0 or options.volume > 1) return error.InvalidVolume;
        const owned = try self.resolve(sound);
        return self.mixer.playSound(&owned.sound, .{ .volume = options.volume, .loop = options.loop });
    }

    /// Starts the selected music source. At most one high-level music stream
    /// is active; a successful new request stops the previous music stream.
    /// Sound effects continue to mix independently on the SFX bus.
    pub fn playMusic(self: *Audio, music: MusicHandle, options: MusicPlayOptions) !PlaybackHandle {
        if (self.availability_state != .ready) return error.AudioUnavailable;
        if (!validVolume(options.volume)) return error.InvalidVolume;
        const owned = try self.resolveMusic(music);
        // Build the next decoder/playback before stopping the old stream. A
        // failed allocation or invalid source must not silence valid music.
        const playback = try self.mixer.playMusic(&owned.music, .{ .volume = options.volume, .loop = options.loop });
        if (self.active_music) |previous| _ = self.mixer.stop(previous);
        self.active_music = playback;
        return playback;
    }

    pub fn pauseMusic(self: *Audio) bool {
        const playback = self.active_music orelse return false;
        const paused = self.mixer.pause(playback);
        if (!paused) self.active_music = null;
        return paused;
    }

    pub fn resumeMusic(self: *Audio) bool {
        const playback = self.active_music orelse return false;
        const resumed = self.mixer.resumePlayback(playback);
        if (!resumed) self.active_music = null;
        return resumed;
    }

    /// Stops the active high-level music stream. The next `playMusic` starts
    /// a fresh decoder at the beginning of its source.
    pub fn stopMusic(self: *Audio) bool {
        const playback = self.active_music orelse return false;
        self.active_music = null;
        return self.mixer.stop(playback);
    }

    pub fn setMusicVolume(self: *Audio, volume: f32) !bool {
        if (!validVolume(volume)) return error.InvalidVolume;
        const playback = self.active_music orelse return false;
        const changed = try self.mixer.setPlaybackVolume(playback, volume);
        if (!changed) self.active_music = null;
        return changed;
    }

    /// Returns the logical state of the single high-level music stream.
    /// A non-looping stream that ended during mixing is reported as stopped.
    pub fn musicState(self: *Audio) MusicState {
        const playback = self.active_music orelse return .stopped;
        const current = self.mixer.getPlayback(playback) orelse {
            self.active_music = null;
            return .stopped;
        };
        return if (current.paused) .paused else .playing;
    }

    pub fn musicDiagnostics(self: *Audio) MusicDiagnostics {
        var diagnostics = MusicDiagnostics{ .state = self.musicState() };
        const playback = self.active_music orelse return diagnostics;
        const current = self.mixer.getPlayback(playback) orelse return diagnostics;
        switch (current.kind) {
            .wav_music => |wav| {
                diagnostics.encoded_bytes = wav.bytes.len;
                diagnostics.source_frames = wav.info.frames;
                diagnostics.decoder_position_frames = @intFromFloat(wav.pos);
            },
            .ogg_music => |ogg| {
                diagnostics.encoded_bytes = ogg.bytes.len;
                diagnostics.source_frames = ogg.info.frames;
                diagnostics.decoder_position_frames = @intFromFloat(ogg.pos);
                diagnostics.buffered_frames = ogg.buffer.items.len;
                diagnostics.buffer_capacity_frames = ogg.buffer.capacity;
            },
            .sound => {},
        }
        return diagnostics;
    }

    pub fn stop(self: *Audio, playback: PlaybackHandle) bool {
        const stopped = self.mixer.stop(playback);
        if (self.active_music) |music| {
            if (music.index == playback.index and music.id == playback.id) self.active_music = null;
        }
        return stopped;
    }

    /// Compatibility for the existing SDL callback context. Unlike the
    /// high-level `play`, this permits silent legacy playbacks while no device
    /// is attached so older examples retain their non-fatal muted behavior.
    pub fn playSound(self: *Audio, sound: *const Sound, options: SoundOptions) !PlaybackHandle {
        return self.mixer.playSound(sound, options);
    }

    pub fn mix(self: *Audio, out: []AudioSample) !void {
        try self.mixer.mix(out);
    }

    /// True when a host should continue requesting PCM. This is a host helper,
    /// not a game scheduling signal.
    pub fn hasActivePlayback(self: *const Audio) bool {
        for (self.mixer.playbacks.items) |playback| if (playback.active) return true;
        return false;
    }

    fn resolve(self: *Audio, handle: SoundHandle) !*OwnedSound {
        if (handle.index >= self.sounds.items.len) return error.InvalidSound;
        const owned = self.sounds.items[handle.index];
        if (owned.generation != handle.generation) return error.InvalidSound;
        return owned;
    }

    fn resolveMusic(self: *Audio, handle: MusicHandle) !*OwnedMusic {
        if (handle.index >= self.music_sources.items.len) return error.InvalidMusic;
        const owned = self.music_sources.items[handle.index];
        if (owned.generation != handle.generation) return error.InvalidMusic;
        return owned;
    }

    fn takeGeneration(self: *Audio) u32 {
        const generation = self.next_generation;
        self.next_generation +%= 1;
        if (self.next_generation == 0) self.next_generation = 1;
        return generation;
    }

    fn takeMusicGeneration(self: *Audio) u32 {
        const generation = self.next_music_generation;
        self.next_music_generation +%= 1;
        if (self.next_music_generation == 0) self.next_music_generation = 1;
        return generation;
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
    pan: f32,
    fade: ?Fade = null,
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

    const Fade = struct { target: f32, remaining: u32, step: f32 };

    fn mix(self: *Playback, mixer: *AudioMixer, out: []AudioSample, gain: f32) !bool {
        return switch (self.kind) {
            .sound => |*sound| mixSound(sound, self, mixer.sample_rate, self.loop, out, gain),
            .wav_music => |*wav| mixWavMusic(wav, self, mixer.sample_rate, self.loop, out, gain),
            .ogg_music => |*ogg| try mixOggMusic(ogg, self, mixer.allocator, mixer.sample_rate, self.loop, out, gain),
        };
    }

    fn nextGain(self: *Playback, bus_gain: f32) f32 {
        const gain = self.volume * bus_gain;
        if (self.fade) |*fade| {
            self.volume += fade.step;
            fade.remaining -= 1;
            if (fade.remaining == 0) {
                self.volume = fade.target;
                self.fade = null;
            }
        }
        return gain;
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
    bytes: []const u8,
    info: WavInfo,
    pos: f64 = 0,
};

const OggPlayback = struct {
    bytes: []const u8,
    info: OggInfo,
    decoder: OggDecoder,
    buffer: std.ArrayListUnmanaged(AudioSample) = .{},
    start: usize = 0,
    pos: f64 = 0,
    eof: bool = false,

    fn init(allocator: std.mem.Allocator, bytes: []const u8, info: OggInfo) !OggPlayback {
        var decoder = try OggDecoder.init(allocator, bytes);
        errdefer decoder.deinit();
        var buffer: std.ArrayListUnmanaged(AudioSample) = .{};
        errdefer buffer.deinit(allocator);
        try buffer.ensureTotalCapacity(allocator, stream_buffer_frames);
        return .{ .bytes = bytes, .info = info, .decoder = decoder, .buffer = buffer };
    }

    fn deinit(self: *OggPlayback, allocator: std.mem.Allocator) void {
        self.decoder.deinit();
        self.buffer.deinit(allocator);
    }

    fn reset(self: *OggPlayback) void {
        _ = vorbis.stb_vorbis_seek_start(self.decoder.value);
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
        _ = allocator;
        const info = self.info;
        const available = self.buffer.capacity - self.buffer.items.len;
        if (available == 0) return error.StreamBufferFull;
        const requested_frames = @min(stream_decode_frames, available);
        var interleaved: [stream_decode_frames * max_ogg_channels]f32 = undefined;
        const sample_count = requested_frames * @as(usize, info.channels);
        const got = vorbis.stb_vorbis_get_samples_float_interleaved(self.decoder.value, @intCast(info.channels), &interleaved, @intCast(sample_count));
        if (got <= 0) {
            self.eof = true;
            return false;
        }
        const frame_count: usize = @intCast(got);
        var frame: usize = 0;
        while (frame < frame_count) : (frame += 1) {
            self.buffer.appendAssumeCapacity(sampleFromInterleavedVorbis(&interleaved, info.channels, frame));
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

fn mixSound(playback: *SoundPlayback, controls: *Playback, mixer_rate: u32, loop: bool, out: []AudioSample, gain: f32) bool {
    const sound = playback.sound;
    const step = rateStep(sound.sample_rate, mixer_rate);
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        const frame_index = normalizePos(&playback.pos, sound.frames.len, loop) orelse return false;
        mixAdd(&out[i], sound.frames[frame_index], controls.nextGain(gain), controls.pan);
        playback.pos += step;
    }
    return true;
}

fn mixWavMusic(playback: *WavPlayback, controls: *Playback, mixer_rate: u32, loop: bool, out: []AudioSample, gain: f32) bool {
    const step = rateStep(playback.info.sample_rate, mixer_rate);
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        const frame_index = normalizePos(&playback.pos, playback.info.frames, loop) orelse return false;
        mixAdd(&out[i], wavFrame(playback.bytes, playback.info, frame_index), controls.nextGain(gain), controls.pan);
        playback.pos += step;
    }
    return true;
}

fn mixOggMusic(playback: *OggPlayback, controls: *Playback, allocator: std.mem.Allocator, mixer_rate: u32, loop: bool, out: []AudioSample, gain: f32) !bool {
    const info = playback.info;
    const step = rateStep(info.sample_rate, mixer_rate);
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        var frame_index = normalizePos(&playback.pos, info.frames, loop) orelse return false;
        if (loop and (frame_index < playback.start or (frame_index == 0 and playback.eof))) playback.reset();
        if (!try playback.ensure(allocator, frame_index)) {
            if (!loop) return false;
            playback.reset();
            frame_index = 0;
            if (!try playback.ensure(allocator, frame_index)) return false;
        }
        const local = frame_index - playback.start;
        mixAdd(&out[i], playback.buffer.items[local], controls.nextGain(gain), controls.pan);
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

fn mixAdd(out: *AudioSample, sample: AudioSample, gain: f32, pan: f32) void {
    out.left += sample.left * gain * (1 - @max(pan, 0));
    out.right += sample.right * gain * (1 + @min(pan, 0));
}

fn sampleFromVorbis(output: [*c][*c]f32, channels: u16, frame: usize) AudioSample {
    const left = output[0][frame];
    const right = if (channels == 1) left else output[1][frame];
    return .{ .left = left, .right = right };
}

fn sampleFromInterleavedVorbis(samples: []const f32, channels: u16, frame: usize) AudioSample {
    const offset = frame * @as(usize, channels);
    const left = samples[offset];
    const right = if (channels == 1) left else samples[offset + 1];
    return .{ .left = left, .right = right };
}

fn requireVolume(volume: f32) !void {
    if (std.math.isNan(volume) or volume < 0) return error.InvalidVolume;
}

fn validVolume(volume: f32) bool {
    return std.math.isFinite(volume) and volume >= 0 and volume <= 1;
}

fn requirePan(pan: f32) !void {
    if (std.math.isNan(pan) or pan < -1 or pan > 1) return error.InvalidPan;
}

fn clampUnit(value: f32) f32 {
    if (value < -1) return -1;
    if (value > 1) return 1;
    return value;
}

fn parseOggInfo(allocator: std.mem.Allocator, bytes: []const u8) !OggInfo {
    var decoder = try OggDecoder.init(allocator, bytes);
    defer decoder.deinit();
    const info = vorbis.stb_vorbis_get_info(decoder.value);
    if (info.channels <= 0 or info.channels > max_ogg_channels or info.sample_rate == 0) return error.UnsupportedOgg;
    const frames = vorbis.stb_vorbis_stream_length_in_samples(decoder.value);
    if (frames == 0) return error.EmptyOgg;
    return .{ .sample_rate = info.sample_rate, .channels = @intCast(info.channels), .frames = frames };
}

fn decodeOggSound(allocator: std.mem.Allocator, bytes: []const u8) !Sound {
    const info = try parseOggInfo(allocator, bytes);
    var decoder = try OggDecoder.init(allocator, bytes);
    defer decoder.deinit();
    var frames: std.ArrayListUnmanaged(AudioSample) = .{};
    errdefer frames.deinit(allocator);
    try frames.ensureTotalCapacity(allocator, info.frames);
    while (true) {
        var output: [*c][*c]f32 = undefined;
        const got = vorbis.stb_vorbis_get_frame_float(decoder.value, null, &output);
        if (got <= 0) break;
        var frame: usize = 0;
        while (frame < @as(usize, @intCast(got))) : (frame += 1) {
            try frames.append(allocator, sampleFromVorbis(output, info.channels, frame));
        }
    }
    if (frames.items.len == 0) return error.EmptyOgg;
    return .{ .allocator = allocator, .sample_rate = info.sample_rate, .frames = try frames.toOwnedSlice(allocator) };
}

const OggDecoder = struct {
    allocator: std.mem.Allocator,
    value: *vorbis.stb_vorbis,
    storage: []u8 = &.{},

    fn init(allocator: std.mem.Allocator, bytes: []const u8) !OggDecoder {
        var storage: []u8 = &.{};
        if (comptime builtin.target.cpu.arch == .wasm32) storage = try allocator.alloc(u8, wasm_ogg_decoder_bytes);
        errdefer if (storage.len != 0) allocator.free(storage);
        const value = try openOggDecoder(bytes, storage);
        return .{ .allocator = allocator, .value = value, .storage = storage };
    }

    fn deinit(self: *OggDecoder) void {
        vorbis.stb_vorbis_close(self.value);
        if (self.storage.len != 0) self.allocator.free(self.storage);
        self.* = undefined;
    }
};

fn openOggDecoder(bytes: []const u8, storage: []u8) !*vorbis.stb_vorbis {
    if (bytes.len > std.math.maxInt(c_int)) return error.AudioTooLarge;
    var err: c_int = 0;
    var allocation = vorbis.stb_vorbis_alloc{
        .alloc_buffer = if (storage.len == 0) null else storage.ptr,
        .alloc_buffer_length_in_bytes = std.math.cast(c_int, storage.len) orelse return error.OggDecoderStorageTooLarge,
    };
    const maybe_allocation: ?*const vorbis.stb_vorbis_alloc = if (storage.len == 0) null else &allocation;
    return vorbis.stb_vorbis_open_memory(bytes.ptr, @intCast(bytes.len), &err, maybe_allocation) orelse if (storage.len != 0 and err != 0) error.OggDecoderStorageExhausted else error.InvalidOgg;
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
    return parseWavWithFrameLimit(bytes, stable_max_decoded_frames);
}

// A Music source retains encoded bytes and converts only bounded chunks to
// PCM while it is playing, so it must not inherit Sound's full-decode frame
// limit. The encoded-byte limit is still enforced by Music.decodeWav/openWav.
fn parseMusicWav(bytes: []const u8) !WavInfo {
    return parseWavWithFrameLimit(bytes, null);
}

fn parseWavWithFrameLimit(bytes: []const u8, frame_limit: ?usize) !WavInfo {
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
    if (channels > 2) return error.UnsupportedWav;
    if (!supportedWav(format, bits_per_sample)) return error.UnsupportedWav;
    if (block_align != channels * (bits_per_sample / 8) or data_len % block_align != 0) return error.InvalidWav;
    const frames = data_len / block_align;
    if (frames == 0) return error.EmptyWav;
    if (frame_limit) |limit| {
        if (frames > limit) return error.AudioTooLarge;
    }
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

test "stable audio fixture has equivalent load play stop outcomes" {
    const Fixture = struct {
        version: u32,
        format: []const u8,
        valid_wav_base64: []const u8,
        invalid_wav_base64: []const u8,
        outcomes: struct {
            load: []const u8,
            play: []const u8,
            stop: []const u8,
            stop_stale: []const u8,
            invalid_load: []const u8,
        },
    };
    var fixture = try std.json.parseFromSlice(Fixture, std.testing.allocator, @embedFile("fixtures/audio/stable-audio-v1.json"), .{});
    defer fixture.deinit();
    try std.testing.expectEqual(@as(u32, 1), fixture.value.version);
    try std.testing.expectEqualStrings("wav", fixture.value.format);
    try std.testing.expectEqualStrings("ok", fixture.value.outcomes.load);
    try std.testing.expectEqualStrings("ok", fixture.value.outcomes.play);
    try std.testing.expectEqualStrings("ok", fixture.value.outcomes.stop);
    try std.testing.expectEqualStrings("rejected", fixture.value.outcomes.stop_stale);
    try std.testing.expectEqualStrings("rejected", fixture.value.outcomes.invalid_load);
    const valid_len = try std.base64.standard.Decoder.calcSizeForSlice(fixture.value.valid_wav_base64);
    const valid = try std.testing.allocator.alloc(u8, valid_len);
    defer std.testing.allocator.free(valid);
    try std.base64.standard.Decoder.decode(valid, fixture.value.valid_wav_base64);
    var sound = try Sound.decodeWav(std.testing.allocator, valid);
    defer sound.deinit();
    var mixer = try AudioMixer.init(std.testing.allocator, .{});
    defer mixer.deinit();
    const handle = try mixer.playSound(&sound, .{});
    try std.testing.expect(mixer.stop(handle));
    try std.testing.expect(!mixer.stop(handle));
    const invalid_len = try std.base64.standard.Decoder.calcSizeForSlice(fixture.value.invalid_wav_base64);
    const invalid = try std.testing.allocator.alloc(u8, invalid_len);
    defer std.testing.allocator.free(invalid);
    try std.base64.standard.Decoder.decode(invalid, fixture.value.invalid_wav_base64);
    try std.testing.expectError(error.InvalidWav, Sound.decodeWav(std.testing.allocator, invalid));
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

test "mixer playback survives output recovery boundaries" {
    const frames = try std.testing.allocator.dupe(AudioSample, &.{ .{ .left = 1, .right = 1 }, .{ .left = 0.5, .right = 0.5 } });
    var sound = Sound{ .allocator = std.testing.allocator, .sample_rate = 48_000, .frames = frames };
    defer sound.deinit();
    var mixer = try AudioMixer.init(std.testing.allocator, .{});
    defer mixer.deinit();
    try mixer.setBusVolume(AudioMixer.masterBus(), 0.5);
    const handle = try mixer.playSound(&sound, .{ .loop = true });

    var before: [1]AudioSample = undefined;
    try mixer.mix(&before);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), before[0].left, 0.0001);

    var after: [1]AudioSample = undefined;
    try mixer.mix(&after);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), after[0].left, 0.0001);
    try std.testing.expect(try mixer.setPlaybackVolume(handle, 1));

    var resumed: [1]AudioSample = undefined;
    try mixer.mix(&resumed);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), resumed[0].left, 0.0001);
}

test "internal playback pan and fades are sample-accurate" {
    const frames = try std.testing.allocator.dupe(AudioSample, &.{.{ .left = 1, .right = 1 }});
    var sound = Sound{ .allocator = std.testing.allocator, .sample_rate = 48_000, .frames = frames };
    defer sound.deinit();
    var mixer = try AudioMixer.init(std.testing.allocator, .{});
    defer mixer.deinit();
    const handle = try mixer.playSound(&sound, .{ .loop = true });
    try std.testing.expect(try mixer.setPlaybackPan(handle, 1));
    var out: [2]AudioSample = undefined;
    try mixer.mix(&out);
    try std.testing.expectEqual(@as(f32, 0), out[0].left);
    try std.testing.expectEqual(@as(f32, 1), out[0].right);
    try std.testing.expect(try mixer.setPlaybackPan(handle, -1));
    try std.testing.expect(try mixer.fadePlayback(handle, 0, 2));
    try mixer.mix(&out);
    try std.testing.expectApproxEqAbs(@as(f32, 1), out[0].left, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), out[1].left, 0.0001);
    try std.testing.expect(!try mixer.setPlaybackPan(.{ .index = handle.index, .id = handle.id +% 1 }, 0));
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

test "deterministic mixer hash covers bus pan and fades" {
    const frames = try std.testing.allocator.dupe(AudioSample, &.{ .{ .left = 0.75, .right = 0.25 }, .{ .left = 0.25, .right = 0.75 } });
    var sound = Sound{ .allocator = std.testing.allocator, .sample_rate = 48_000, .frames = frames };
    defer sound.deinit();
    var mixer = try AudioMixer.init(std.testing.allocator, .{});
    defer mixer.deinit();
    try mixer.setBusVolume(AudioMixer.sfxBus(), 0.5);
    const handle = try mixer.playSound(&sound, .{ .loop = true, .volume = 0.8 });
    try std.testing.expect(try mixer.setPlaybackPan(handle, -0.5));
    try std.testing.expect(try mixer.fadePlayback(handle, 0.2, 3));
    var out: [6]AudioSample = undefined;
    try mixer.mix(&out);
    try std.testing.expectEqual(@as(u64, 8393355929743166360), hashSamples(&out));
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
    const handle = try mixer.playMusic(&music, .{ .loop = true });
    const capacity = switch (mixer.playbacks.items[handle.index].kind) {
        .ogg_music => |ogg| ogg.buffer.capacity,
        else => unreachable,
    };
    var out: [8192]AudioSample = undefined;
    try mixer.mix(&out);
    var nonzero = false;
    for (out) |sample| {
        if (sample.left != 0 or sample.right != 0) nonzero = true;
    }
    try std.testing.expect(nonzero);
    var i: usize = 0;
    while (i < 128) : (i += 1) try mixer.mix(&out);
    const final_capacity = switch (mixer.playbacks.items[handle.index].kind) {
        .ogg_music => |ogg| ogg.buffer.capacity,
        else => unreachable,
    };
    try std.testing.expectEqual(capacity, final_capacity);
}

test "music decodes owned Ogg bytes for freestanding hosts" {
    const bytes = try std.fs.cwd().readFileAlloc(std.testing.allocator, "examples/assets/tone.ogg", stable_max_input_bytes);
    defer std.testing.allocator.free(bytes);
    var music = try Music.decodeOgg(std.testing.allocator, bytes);
    defer music.deinit();
    var mixer = try AudioMixer.init(std.testing.allocator, .{ .sample_rate = music.info().sample_rate });
    defer mixer.deinit();
    _ = try mixer.playMusic(&music, .{});
    var out: [256]AudioSample = undefined;
    try mixer.mix(&out);
    var nonzero = false;
    for (out) |sample| {
        if (sample.left != 0 or sample.right != 0) nonzero = true;
    }
    try std.testing.expect(nonzero);
}

test "high-level music keeps encoded Ogg data bounded and supports lifecycle controls" {
    const bytes = try std.fs.cwd().readFileAlloc(std.testing.allocator, "examples/assets/tone.ogg", stable_max_input_bytes);
    defer std.testing.allocator.free(bytes);

    var audio = try Audio.init(std.testing.allocator, .{});
    defer audio.deinit();
    const music = try audio.loadMusic(bytes, .{});
    const effect = try audio.loadWav(&wav_mono_16);
    const first_music = try audio.playMusic(music, .{ .volume = 0.25, .loop = true });
    const replacement_music = try audio.playMusic(music, .{ .volume = 0.25, .loop = true });
    try std.testing.expect(first_music.id != replacement_music.id);
    try std.testing.expect(!audio.stop(first_music));
    _ = try audio.play(effect, .{ .volume = 0.1 });
    try std.testing.expectEqual(Audio.MusicState.playing, audio.musicState());

    const initial = audio.musicDiagnostics();
    try std.testing.expectEqual(bytes.len, initial.encoded_bytes);
    // ArrayList is allowed to round a requested capacity upward. The stream
    // must reserve at least this bounded working set, then retain that
    // capacity during playback rather than growing with track duration.
    try std.testing.expect(initial.buffer_capacity_frames >= stream_buffer_frames);
    try std.testing.expect(initial.source_frames > initial.buffer_capacity_frames);

    var output: [1024]AudioSample = undefined;
    try audio.mix(&output);
    var nonzero = false;
    for (output) |sample| {
        if (sample.left != 0 or sample.right != 0) nonzero = true;
    }
    try std.testing.expect(nonzero);

    try std.testing.expect(audio.pauseMusic());
    try std.testing.expectEqual(Audio.MusicState.paused, audio.musicState());
    try audio.mix(&output);
    for (output) |sample| {
        try std.testing.expectEqual(@as(f32, 0), sample.left);
        try std.testing.expectEqual(@as(f32, 0), sample.right);
    }
    try std.testing.expect(audio.resumeMusic());
    try std.testing.expectEqual(Audio.MusicState.playing, audio.musicState());
    try std.testing.expect(try audio.setMusicVolume(0.5));
    try std.testing.expectError(error.InvalidVolume, audio.setMusicVolume(std.math.inf(f32)));
    try std.testing.expect(audio.stopMusic());
    try std.testing.expectEqual(Audio.MusicState.stopped, audio.musicState());
    try std.testing.expect(!audio.stopMusic());

    _ = try audio.playMusic(music, .{ .loop = false });
    try std.testing.expectEqual(Audio.MusicState.playing, audio.musicState());
}

test "high-level music retains bounded Ogg buffer across simulated long playback" {
    const bytes = try std.fs.cwd().readFileAlloc(std.testing.allocator, "examples/assets/tone.ogg", stable_max_input_bytes);
    defer std.testing.allocator.free(bytes);
    var audio = try Audio.init(std.testing.allocator, .{});
    defer audio.deinit();
    const music = try audio.loadMusic(bytes, .{});
    _ = try audio.playMusic(music, .{ .loop = true });
    const expected_capacity = audio.musicDiagnostics().buffer_capacity_frames;
    var output: [1024]AudioSample = undefined;
    var block: usize = 0;
    // 8,500 × 1,024 frames is a little over three minutes at 48 kHz. This
    // advances faster than realtime in the headless mixer while exercising
    // hundreds of loop boundaries from the half-second fixture.
    while (block < 8_500) : (block += 1) try audio.mix(&output);
    const diagnostics = audio.musicDiagnostics();
    try std.testing.expectEqual(Audio.MusicState.playing, diagnostics.state);
    try std.testing.expectEqual(expected_capacity, diagnostics.buffer_capacity_frames);
    try std.testing.expect(diagnostics.decoder_position_frames < diagnostics.source_frames);
    try std.testing.expectEqual(@as(u32, 0), diagnostics.underruns);
}

test "high-level music rejects unavailable output and invalid encoded source" {
    var audio = try Audio.init(std.testing.allocator, .{ .availability = .blocked });
    defer audio.deinit();
    try std.testing.expectError(error.InvalidOgg, audio.loadMusic("not an ogg", .{}));
    const music = try audio.loadMusic(&wav_mono_16, .{ .format = .wav });
    try std.testing.expectError(error.AudioUnavailable, audio.playMusic(music, .{}));
    audio.setAvailability(.ready);
    try std.testing.expectError(error.InvalidVolume, audio.playMusic(music, .{ .volume = -0.01 }));
    try std.testing.expectError(error.InvalidMusic, audio.playMusic(.{ .index = 99, .generation = 1 }, .{}));
}

test "ogg playback retains source data when its Music container moves" {
    var original = try Music.openOgg(std.testing.allocator, "examples/assets/tone.ogg");
    var mixer = try AudioMixer.init(std.testing.allocator, .{ .sample_rate = original.info().sample_rate });
    defer mixer.deinit();
    _ = try mixer.playMusic(&original, .{ .loop = true });
    var moved = original;
    original = undefined;
    defer moved.deinit();

    var out: [8192]AudioSample = undefined;
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
        if (i == 72) try std.testing.expect(mixer.stop(music_handle));
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
