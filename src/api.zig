pub const core = struct {
    pub const App = @import("app.zig");
    pub const StepClock = @import("app.zig").StepClock;
    pub const Color = @import("color.zig").Color;
    pub const Vec2 = @import("math.zig").Vec2;
    pub const Rect = @import("math.zig").Rect;
};

pub const input = struct {
    pub const Input = @import("input.zig").Input;
    pub const Key = @import("input.zig").Key;
    pub const Pointer = @import("input.zig").Pointer;
    pub const PointerButton = @import("input.zig").PointerButton;
    pub const Gamepad = @import("input.zig").Gamepad;
    pub const GamepadButton = @import("input.zig").GamepadButton;
    pub const GamepadAxis = @import("input.zig").GamepadAxis;
    pub const Action = @import("actions.zig").Action;
    pub const ActionBinding = @import("actions.zig").Binding;
    pub const ActionMap = @import("actions.zig").Map;
};

pub const graphics = struct {
    pub const Canvas = @import("canvas.zig").Canvas;
    pub const Sprite = @import("canvas.zig").Sprite;
    pub const ClipRect = @import("canvas.zig").ClipRect;
    pub const BlendMode = @import("canvas.zig").BlendMode;
    pub const Camera2D = @import("camera.zig").Camera2D;
    pub const CameraCanvas = @import("camera_canvas.zig").CameraCanvas;
    pub const Presentation = @import("presentation.zig").Presentation;
    pub const PresentationMode = @import("presentation.zig").PresentationMode;
    pub const HeadlessRenderer = @import("render.zig").HeadlessRenderer;
};

pub const assets = struct {
    pub const AssetStore = @import("assets.zig").AssetStore;
    pub const AssetFile = @import("assets.zig").AssetFile;
    pub const Image = @import("image.zig").Image;
    pub const Atlas = @import("atlas.zig").Atlas;
    pub const Font = @import("font_asset.zig").Font;
    pub const Sound = @import("audio.zig").Sound;
    pub const Music = @import("audio.zig").Music;
};

pub const world = struct {
    pub const TileMap = @import("tilemap.zig").TileMap;
    pub const TileMapLayer = @import("tilemap.zig").TileMapLayer;
    pub const TileCollider = @import("tile_collision.zig").TileCollider;
    pub const CharacterController = @import("tile_collision.zig").CharacterController;
    pub const collision = @import("collision.zig");
};
