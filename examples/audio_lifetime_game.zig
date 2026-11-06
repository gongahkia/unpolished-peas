//! Explicit audio ownership across scene transitions; no scene framework.
const std = @import("std");
const up = @import("unpolished-peas");
const Audio = up.core.Audio;
pub const width = 320;
pub const height = 120;
const wav = @embedFile("assets/blip.wav");
const ogg = @embedFile("assets/tone.ogg");

pub const Game = struct {
    ui_sound: ?Audio.SoundHandle = null,
    scene_sound: ?Audio.SoundHandle = null,
    scene_music: ?Audio.MusicHandle = null,
    scene: u8 = 0,
    transitions: u32 = 0,
    playback_ready: bool = false,

    pub fn init(self: *Game, ctx: *up.core.GameContext) !void {
        const audio = try ctx.requireAudio();
        errdefer self.deinit(ctx) catch {};
        self.ui_sound = try audio.loadWav(wav);
        try self.changeScene(ctx);
    }

    pub fn changeScene(self: *Game, ctx: *up.core.GameContext) !void {
        const audio = try ctx.requireAudio();
        // Prepare the next scene before releasing the old one. Either load
        // can fail without changing the current scene or persistent UI sound.
        const sound = try audio.loadWav(wav);
        const next: u8 = (self.scene + 1) % 2;
        const music = audio.loadMusic(if (next == 0) wav else ogg, .{ .format = if (next == 0) .wav else .ogg }) catch |err| {
            _ = audio.unloadSound(sound);
            return err;
        };
        if (self.scene_sound) |old| _ = audio.unloadSound(old);
        if (self.scene_music) |old| _ = audio.unloadMusic(old);
        self.scene_sound = sound;
        self.scene_music = music;
        self.scene = next;
        self.transitions += 1;
        try self.playScene(audio);
        _ = audio.play(self.ui_sound.?, .{ .volume = 0.15 }) catch |err| switch (err) {
            error.AudioUnavailable => {},
            else => return err,
        };
    }

    fn playScene(self: *Game, audio: *Audio) !void {
        // Browser activation/device failures are output failures, not a reason
        // to reload source data. Space retries using the retained handles.
        _ = audio.playMusic(self.scene_music.?, .{ .loop = true, .volume = 0.15 }) catch |err| switch (err) {
            error.AudioUnavailable => {
                self.playback_ready = false;
                return;
            },
            else => return err,
        };
        _ = try audio.play(self.scene_sound.?, .{ .loop = true, .volume = 0.05 });
        self.playback_ready = true;
    }

    pub fn update(self: *Game, ctx: *up.core.GameContext, _: f32) !void {
        if (ctx.input.wasPressed(.action)) try self.changeScene(ctx);
        if (ctx.input.wasPressed(.cancel)) {
            const audio = try ctx.requireAudio();
            if (audio.musicState() == .paused) _ = audio.resumeMusic() else _ = audio.pauseMusic();
        }
    }

    pub fn draw(self: *Game, ctx: *up.core.GameContext) !void {
        const canvas = try ctx.requireCanvas();
        canvas.clear(if (self.scene == 0) up.core.Color.rgb(23, 45, 62) else up.core.Color.rgb(44, 35, 60));
        canvas.drawText("AUDIO SCENE LIFETIMES", 12, 12, up.core.Color.white);
        canvas.drawText(if (self.scene == 0) "WAV MUSIC" else "OGG MUSIC", 12, 30, up.core.Color.white);
        var text: [48]u8 = undefined;
        canvas.drawText(try std.fmt.bufPrint(&text, "TRANSITIONS: {d}", .{self.transitions}), 12, 48, up.core.Color.white);
        canvas.drawText(if (self.playback_ready) "AUDIO STARTED" else "PRESS SPACE TO ACTIVATE", 12, 66, up.core.Color.white);
        canvas.drawText("SPACE: NEXT   ESC: PAUSE MUSIC", 12, 94, up.core.Color.white);
    }

    pub fn deinit(self: *Game, ctx: *up.core.GameContext) !void {
        if (ctx.audio) |audio| {
            if (self.scene_sound) |sound| _ = audio.unloadSound(sound);
            if (self.scene_music) |music| _ = audio.unloadMusic(music);
            if (self.ui_sound) |sound| _ = audio.unloadSound(sound);
        }
        self.scene_sound = null;
        self.scene_music = null;
        self.ui_sound = null;
    }
};
