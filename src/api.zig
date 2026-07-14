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
    pub const InspectorInputPanel = @import("inspector_panels.zig").InputPanel;
};

pub const graphics = struct {
    pub const Canvas = @import("canvas.zig").Canvas;
    pub const Sprite = @import("canvas.zig").Sprite;
    pub const ClipRect = @import("canvas.zig").ClipRect;
    pub const BlendMode = @import("canvas.zig").BlendMode;
    pub const Camera2D = @import("camera.zig").Camera2D;
    pub const CameraCanvas = @import("camera_canvas.zig").CameraCanvas;
    pub const Inspector = @import("inspector.zig").Inspector;
    pub const InspectorPanel = @import("inspector.zig").Panel;
    pub const InspectorVisibility = @import("inspector.zig").Visibility;
    pub const InspectorScenePanel = @import("inspector_panels.zig").ScenePanel;
    pub const InspectorAssetPanel = @import("inspector_panels.zig").AssetPanel;
    pub const InspectorResource = @import("inspector_panels.zig").Resource;
    pub const InspectorResourceHandle = @import("inspector_panels.zig").ResourceHandle;
    pub const LightingPipeline = @import("lighting.zig").Pipeline;
    pub const LightingConfig = @import("lighting.zig").Config;
    pub const Light = @import("lighting.zig").Light;
    pub const LightOccluder = @import("lighting.zig").Occluder;
    pub const LightingMetrics = @import("lighting.zig").Metrics;
    pub const LightingRenderPath = @import("lighting.zig").RenderPath;
    pub const UiFrame = @import("ui.zig").Frame;
    pub const UiId = @import("ui.zig").Id;
    pub const UiLayout = @import("ui.zig").Layout;
    pub const UiResponse = @import("ui.zig").Response;
    pub const UiState = @import("ui.zig").State;
    pub const UiStyle = @import("ui.zig").Style;
    pub const UiSurface = @import("ui.zig").Surface;
    pub const Presentation = @import("presentation.zig").Presentation;
    pub const PresentationMode = @import("presentation.zig").PresentationMode;
    pub const HeadlessRenderer = @import("render.zig").HeadlessRenderer;
    pub const FontGlyphRange = @import("font_asset.zig").GlyphRange;
    pub const FontTextDiagnostics = @import("font_asset.zig").TextDiagnostics;
    pub const ShaderAssetHandle = @import("assets.zig").ShaderAssetHandle;
    pub const ShaderProgram = @import("shader.zig").Program;
    pub const ShaderReflection = @import("shader.zig").Reflection;
    pub const ShaderKind = @import("shader.zig").Kind;
};

pub const assets = struct {
    pub const AssetStore = @import("assets.zig").AssetStore;
    pub const AssetFile = @import("assets.zig").AssetFile;
    pub const AudioHandle = @import("assets.zig").AudioHandle;
    pub const Image = @import("image.zig").Image;
    pub const Atlas = @import("atlas.zig").Atlas;
    pub const Font = @import("font_asset.zig").Font;
    pub const Sound = @import("audio.zig").Sound;
    pub const Music = @import("audio.zig").Music;
    pub const AssetStats = @import("assets.zig").AssetStats;
};

pub const world = struct {
    pub const TileMap = @import("tilemap.zig").TileMap;
    pub const TileMapLayer = @import("tilemap.zig").TileMapLayer;
    pub const TileCollider = @import("tile_collision.zig").TileCollider;
    pub const CharacterController = @import("tile_collision.zig").CharacterController;
    pub const collision = @import("collision.zig");
};
