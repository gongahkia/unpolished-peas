pub const developer = struct {
    pub const InputReplay = @import("input_replay.zig").Replay;
    pub const InputReplayRecorder = @import("input_replay.zig").Recorder;
    pub const parseInputReplay = @import("input_replay.zig").parse;
};
