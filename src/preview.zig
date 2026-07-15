pub const ecs = struct {
    pub const Entity = @import("ecs.zig").Entity;
    pub const World = @import("ecs.zig").World;
    pub const Commands = @import("ecs.zig").Commands;
    pub const ComponentStore = @import("ecs.zig").ComponentStore;
};

pub const developer = struct {
    pub const InputReplay = @import("input_replay.zig").Replay;
    pub const InputReplayRecorder = @import("input_replay.zig").Recorder;
    pub const parseInputReplay = @import("input_replay.zig").parse;
};
