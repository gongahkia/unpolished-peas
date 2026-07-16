const std = @import("std");

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
    pub const InspectorAssetPanel = @import("inspector_panels.zig").AssetPanel;
    pub const InspectorResource = @import("inspector_panels.zig").Resource;
    pub const InspectorResourceHandle = @import("inspector_panels.zig").ResourceHandle;
    pub const InspectorCollisionPanel = @import("inspector_panels.zig").CollisionPanel;
    pub const InspectorPhysicsPanel = @import("inspector_panels.zig").PhysicsPanel;
    pub const InspectorPhysicsState = @import("inspector_panels.zig").PhysicsState;
    pub const Presentation = @import("presentation.zig").Presentation;
    pub const PresentationMode = @import("presentation.zig").PresentationMode;
    pub const HeadlessRenderer = @import("render.zig").HeadlessRenderer;
    pub const RendererBackend = @import("render.zig").Backend;
    pub const FontGlyphRange = @import("font_asset.zig").GlyphRange;
    pub const FontTextDiagnostics = @import("font_asset.zig").TextDiagnostics;
    pub const ShaderAssetHandle = @import("assets.zig").ShaderAssetHandle;
};

pub const assets = struct {
    pub const AssetStore = @import("assets.zig").AssetStore;
    pub const AssetFile = @import("assets.zig").AssetFile;
    pub const AudioHandle = @import("assets.zig").AudioHandle;
    pub const Image = @import("image.zig").Image;
    pub const Atlas = @import("atlas.zig").Atlas;
    pub const AtlasFrameSpec = @import("atlas.zig").FrameSpec;
    pub const AtlasAnimationFrameSpec = @import("atlas.zig").AnimationFrameSpec;
    pub const AtlasAnimationSpec = @import("atlas.zig").AnimationSpec;
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

pub const preview = @import("preview.zig");
pub const testSupport = @import("test_support.zig");

pub const effects = @import("subsystems/effects/effects.zig");
pub const ecs = @import("subsystems/ecs.zig");
pub const Ui = @import("subsystems/ui.zig").ui(@This());
pub const ui = Ui;
pub const Physics = @import("subsystems/physics.zig").physics(@This());
pub const physics = Physics;
pub const GpuResourceKind = effects.ResourceKind;
pub const GpuResources = effects.Resources;
pub const TextureHandle = effects.TextureHandle;
pub const RenderTargetHandle = effects.RenderTargetHandle;
pub const ShaderHandle = effects.ShaderHandle;
pub const PipelineHandle = effects.PipelineHandle;
pub const ShaderProgram = effects.ShaderProgram;
pub const ShaderReflection = effects.ShaderReflection;
pub const ShaderKind = effects.ShaderKind;
pub const PixelEffect = effects.PixelEffect;
pub const PixelEffectParameters = effects.PixelEffectParameters;
pub const PostProcessChain = effects.PostProcessChain;
pub const lighting = effects.lighting;
pub const EcsEntity = ecs.Entity;
pub const EcsWorld = ecs.World;
pub const EcsCommands = ecs.Commands;
pub const ComponentStore = ecs.ComponentStore;
pub const UiFrame = Ui.Frame;
pub const UiId = Ui.Id;
pub const UiLayout = Ui.Layout;
pub const UiResponse = Ui.Response;
pub const UiState = Ui.State;
pub const UiStyle = Ui.Style;
pub const UiSurface = Ui.Surface;
pub const PhysicsWorld = Physics.World;
pub const PhysicsConfig = Physics.Config;
pub const PhysicsBody = Physics.BodyHandle;
pub const EcsRuntime = struct {
    world: EcsWorld,
    commands: EcsCommands,

    pub fn init(allocator: std.mem.Allocator) EcsRuntime {
        return .{ .world = EcsWorld.init(allocator), .commands = EcsCommands.init(allocator) };
    }

    pub fn deinit(self: *EcsRuntime) void {
        self.commands.deinit();
        self.world.deinit();
        self.* = undefined;
    }

    pub fn beginFrame(self: *EcsRuntime) *EcsCommands {
        return &self.commands;
    }

    pub fn endFrame(self: *EcsRuntime) !void {
        try self.commands.apply(&self.world);
    }
};

test "public API includes first-class engine subsystems" {
    try std.testing.expect(@hasDecl(@This(), "effects"));
    try std.testing.expect(@hasDecl(@This(), "ecs"));
    try std.testing.expect(@hasDecl(@This(), "ui"));
    try std.testing.expect(@hasDecl(@This(), "physics"));
    try std.testing.expect(@hasDecl(@This(), "PixelEffect"));
    try std.testing.expect(@hasDecl(@This(), "EcsWorld"));
    try std.testing.expect(@hasDecl(@This(), "EcsRuntime"));
    try std.testing.expect(@hasDecl(@This(), "UiFrame"));
    try std.testing.expect(@hasDecl(@This(), "PhysicsWorld"));
    try std.testing.expect(!@hasDecl(@This(), "NetMessage"));
    try std.testing.expect(!@hasDecl(@This(), "NetContract"));
    try std.testing.expect(!@hasDecl(@This(), "NetTransport"));
    try std.testing.expect(!@hasDecl(@This(), "P2pPeer"));
    try std.testing.expect(!@hasDecl(@This(), "PredictionClient"));
    try std.testing.expect(!@hasDecl(@This(), "FaultNetwork"));
    try std.testing.expect(!@hasDecl(@This(), "netCodec"));
    try std.testing.expect(!@hasDecl(@This(), "InspectorNetworkPanel"));
    try std.testing.expect(!@hasDecl(graphics, "InspectorNetworkPanel"));
}

test "ECS runtime owns frame commands without becoming mandatory" {
    var runtime = EcsRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const entity = try runtime.world.create();
    try runtime.beginFrame().destroy(entity);
    try runtime.endFrame();
    try std.testing.expectError(error.StaleEntity, runtime.world.validate(entity));
}
pub const App = @import("app.zig");
pub const AudioMixer = @import("audio.zig").AudioMixer;
pub const AudioSample = @import("audio.zig").AudioSample;
pub const Animation = @import("atlas.zig").Animation;
pub const ActionBinding = @import("actions.zig").Binding;
pub const Action = @import("actions.zig").Action;
pub const ActionMap = @import("actions.zig").Map;
pub const AnimationFrame = @import("atlas.zig").AnimationFrame;
pub const AnimationHandle = @import("atlas.zig").AnimationHandle;
pub const AnimationPlayer = @import("atlas.zig").AnimationPlayer;
pub const AnimationStateMachine = @import("animation_state.zig").Machine;
pub const AnimationState = @import("animation_state.zig").State;
pub const AnimationTransition = @import("animation_state.zig").Transition;
pub const AnimationStateDiagnostic = @import("animation_state.zig").Diagnostic;
pub const animationState = @import("animation_state.zig");
pub const Atlas = @import("atlas.zig").Atlas;
pub const AtlasFrame = @import("atlas.zig").AtlasFrame;
pub const AtlasFrameHandle = @import("atlas.zig").AtlasFrameHandle;
pub const AtlasFrameSpec = @import("atlas.zig").FrameSpec;
pub const AtlasAnimationFrameSpec = @import("atlas.zig").AnimationFrameSpec;
pub const AtlasAnimationSpec = @import("atlas.zig").AnimationSpec;
pub const AudioHandle = @import("assets.zig").AudioHandle;
pub const AssetFile = @import("assets.zig").AssetFile;
pub const AssetStore = @import("assets.zig").AssetStore;
pub const Font = @import("font_asset.zig").Font;
pub const FontGlyph = @import("font_asset.zig").Glyph;
pub const FontHandle = @import("assets.zig").FontHandle;
pub const FontLoadOptions = @import("font_asset.zig").LoadOptions;
pub const FontGlyphRange = @import("font_asset.zig").GlyphRange;
pub const FontTextDiagnostics = @import("font_asset.zig").TextDiagnostics;
pub const BusHandle = @import("audio.zig").BusHandle;
pub const Broadphase = @import("broadphase.zig").Broadphase;
pub const BroadphaseProxy = @import("broadphase.zig").Proxy;
pub const Camera2D = @import("camera.zig").Camera2D;
pub const CameraBounds = @import("camera.zig").CameraBounds;
pub const CameraCanvas = @import("camera_canvas.zig").CameraCanvas;
pub const CameraDirector = @import("camera.zig").CameraDirector;
pub const CameraFollow = @import("camera.zig").CameraFollow;
pub const CameraHandle = @import("camera.zig").CameraHandle;
pub const CameraRig = @import("camera.zig").CameraRig;
pub const CameraShake = @import("camera.zig").CameraShake;
pub const CameraShot = @import("camera.zig").CameraShot;
pub const CameraViewport = @import("camera.zig").CameraViewport;
pub const Canvas = @import("canvas.zig").Canvas;
pub const ClipRect = @import("canvas.zig").ClipRect;
pub const BlendMode = @import("canvas.zig").BlendMode;
pub const Color = @import("color.zig").Color;
pub const DiagnosticCapture = @import("diagnostics.zig").Input;
pub const DiagnosticCaptureOptions = @import("diagnostics.zig").Options;
pub const DiagnosticEnvironment = @import("diagnostics.zig").Environment;
pub const diagnostics = @import("diagnostics.zig");
pub const runtime_log = @import("runtime_log.zig");
pub const RuntimeLogEvent = runtime_log.Event;
pub const RuntimeLogField = runtime_log.Field;
pub const RuntimeLogLevel = runtime_log.Level;
pub const RuntimeLogCategory = runtime_log.Category;
pub const Circle = @import("collision.zig").Circle;
pub const Segment = @import("collision.zig").Segment;
pub const Polygon = @import("collision.zig").Polygon;
pub const ParticleEmitter = @import("particles.zig").Emitter;
pub const ParticleConfig = @import("particles.zig").Config;
pub const ParticleMetrics = @import("particles.zig").Metrics;
pub const particles = @import("particles.zig");
pub const FrameProfiler = @import("profiler.zig").Profiler;
pub const ProfileMetrics = @import("profiler.zig").Metrics;
pub const ProfileScope = @import("profiler.zig").Scope;
pub const ProfileScopeMetrics = @import("profiler.zig").ScopeMetrics;
pub const ProfileSample = @import("profiler.zig").Sample;
pub const ProfileTimer = @import("profiler.zig").Timer;
pub const profiler = @import("profiler.zig");
pub const RuntimeMetrics = @import("runtime_metrics.zig").Metrics;
pub const runtimeMetrics = @import("runtime_metrics.zig");
pub const CollisionContact = @import("collision.zig").Contact;
pub const CollisionRayHit = @import("collision.zig").RayHit;
pub const collision = @import("collision.zig");
pub const CharacterConfig = @import("tile_collision.zig").CharacterConfig;
pub const CharacterController = @import("tile_collision.zig").CharacterController;
pub const CharacterState = @import("tile_collision.zig").CharacterState;
pub const TileCollider = @import("tile_collision.zig").TileCollider;
pub const TileCollisionHit = @import("tile_collision.zig").Hit;
pub const TileCollisionShape = @import("tile_collision.zig").Shape;
pub const DrawSpriteOptions = @import("atlas.zig").DrawSpriteOptions;
pub const SpriteSampling = @import("atlas.zig").Sampling;
pub const Image = @import("image.zig").Image;
pub const ImageDecodeOptions = @import("image.zig").DecodeOptions;
pub const ImageHandle = @import("assets.zig").ImageHandle;
pub const Input = @import("input.zig").Input;
pub const Inspector = @import("inspector.zig").Inspector;
pub const InspectorLogger = @import("inspector.zig").Logger;
pub const InspectorPanel = @import("inspector.zig").Panel;
pub const InspectorVisibility = @import("inspector.zig").Visibility;
pub const inspector = @import("inspector.zig");
pub const InspectorAssetPanel = @import("inspector_panels.zig").AssetPanel;
pub const InspectorInputPanel = @import("inspector_panels.zig").InputPanel;
pub const InspectorResource = @import("inspector_panels.zig").Resource;
pub const InspectorResourceHandle = @import("inspector_panels.zig").ResourceHandle;
pub const InspectorMetricsPanel = @import("inspector_panels.zig").MetricsPanel;
pub const InspectorCollisionPanel = @import("inspector_panels.zig").CollisionPanel;
pub const InspectorPhysicsPanel = @import("inspector_panels.zig").PhysicsPanel;
pub const InspectorPhysicsState = @import("inspector_panels.zig").PhysicsState;
pub const inspectorPanels = @import("inspector_panels.zig");
pub const Gamepad = @import("input.zig").Gamepad;
pub const GamepadButton = @import("input.zig").GamepadButton;
pub const GamepadAxis = @import("input.zig").GamepadAxis;
pub const Key = @import("input.zig").Key;
pub const Music = @import("audio.zig").Music;
pub const InputReplay = @import("input_replay.zig").Replay;
pub const InputReplayButton = @import("input_replay.zig").Button;
pub const InputReplayRecorder = @import("input_replay.zig").Recorder;
pub const parseInputReplay = @import("input_replay.zig").parse;
pub const MusicOptions = @import("audio.zig").MusicOptions;
pub const PlaybackHandle = @import("audio.zig").PlaybackHandle;
pub const Pointer = @import("input.zig").Pointer;
pub const PointerButton = @import("input.zig").PointerButton;
pub const Presentation = @import("presentation.zig").Presentation;
pub const PresentationMode = @import("presentation.zig").PresentationMode;
pub const PresentationRect = @import("presentation.zig").PresentationRect;
pub const PrimitiveBatch = @import("primitive_batch.zig").PrimitiveBatch;
pub const PrimitiveBatchDraw = @import("primitive_batch.zig").Draw;
pub const PrimitiveBatchPoint = @import("primitive_batch.zig").Point;
pub const PrimitiveBatchVertex = @import("primitive_batch.zig").Vertex;
pub const Rect = @import("math.zig").Rect;
pub const ReloadEvent = @import("assets.zig").ReloadEvent;
pub const ReloadStatus = @import("assets.zig").ReloadStatus;
pub const RenderCommand = @import("render.zig").Command;
pub const RenderCommandBuffer = @import("render.zig").CommandBuffer;
pub const HeadlessRenderer = @import("render.zig").HeadlessRenderer;
pub const RendererBackend = @import("render.zig").Backend;
pub const ShaderAssetHandle = @import("assets.zig").ShaderAssetHandle;
pub const Sound = @import("audio.zig").Sound;
pub const SoundOptions = @import("audio.zig").SoundOptions;
pub const Sprite = @import("canvas.zig").Sprite;
pub const SpriteBatch = @import("sprite_batch.zig").SpriteBatch;
pub const SpriteBatchGroup = @import("sprite_batch.zig").Batch;
pub const SpriteBatchDraw = @import("sprite_batch.zig").SpriteDraw;
pub const SpriteSourceRect = @import("sprite_batch.zig").SourceRect;
pub const SpriteBatchPoint = @import("sprite_batch.zig").Point;
pub const SpriteBatchUv = @import("sprite_batch.zig").Uv;
pub const SpriteBatchVertex = @import("sprite_batch.zig").Vertex;
pub const StepClock = @import("app.zig").StepClock;
pub const TextHandle = @import("assets.zig").TextHandle;
pub const TextAlignment = @import("text_layout.zig").Alignment;
pub const TextLayoutOptions = @import("text_layout.zig").Options;
pub const TextLayout = @import("text_layout.zig").Layout;
pub const layoutText = @import("text_layout.zig").layout;
pub const Tile = @import("tilemap.zig").Tile;
pub const TileFlags = @import("tilemap.zig").TileFlags;
pub const TileMap = @import("tilemap.zig").TileMap;
pub const TileMapLayer = @import("tilemap.zig").TileMapLayer;
pub const TileMapLayerKind = @import("tilemap.zig").LayerKind;
pub const TileMapObject = @import("tilemap.zig").MapObject;
pub const TileMapObjectShape = @import("tilemap.zig").ObjectShape;
pub const TileMapProperty = @import("tilemap.zig").Property;
pub const TileMapPropertyValue = @import("tilemap.zig").PropertyValue;
pub const TileSet = @import("tilemap.zig").TileSet;
pub const Vec2 = @import("math.zig").Vec2;
