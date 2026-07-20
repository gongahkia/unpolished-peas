const std = @import("std");

pub const core = struct {
    pub const App = @import("app.zig");
    pub const StepClock = @import("app.zig").StepClock;
    pub const GameContext = @import("app.zig").GameContext;
    pub const GameProtocol = @import("app.zig").GameProtocol;
    pub const GamePhase = @import("app.zig").GamePhase;
    pub const GameFailure = @import("app.zig").GameFailure;
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
    pub const Presentation = @import("presentation.zig").Presentation;
    pub const PresentationMode = @import("presentation.zig").PresentationMode;
    pub const HeadlessRenderer = @import("render.zig").HeadlessRenderer;
    pub const RendererBackend = @import("render.zig").Backend;
    pub const FontGlyphRange = @import("font_asset.zig").GlyphRange;
    pub const FontTextDiagnostics = @import("font_asset.zig").TextDiagnostics;
    pub const DiagnosticCapture = @import("diagnostics.zig").Input;
    pub const DiagnosticCaptureOptions = @import("diagnostics.zig").Options;
    pub const DiagnosticEnvironment = @import("diagnostics.zig").Environment;
    pub const diagnostics = @import("diagnostics.zig");
    pub const runtime_log = @import("runtime_log.zig");
    pub const RuntimeLogEvent = runtime_log.Event;
    pub const RuntimeLogField = runtime_log.Field;
    pub const RuntimeLogLevel = runtime_log.Level;
    pub const RuntimeLogCategory = runtime_log.Category;
    pub const FrameProfiler = @import("profiler.zig").Profiler;
    pub const ProfileMetrics = @import("profiler.zig").Metrics;
    pub const ProfileScope = @import("profiler.zig").Scope;
    pub const ProfileScopeMetrics = @import("profiler.zig").ScopeMetrics;
    pub const ProfileSample = @import("profiler.zig").Sample;
    pub const ProfileTimer = @import("profiler.zig").Timer;
    pub const profiler = @import("profiler.zig");
    pub const RuntimeMetrics = @import("runtime_metrics.zig").Metrics;
    pub const runtimeMetrics = @import("runtime_metrics.zig");
    pub const InspectorLogger = @import("inspector.zig").Logger;
    pub const InspectorMetricsPanel = @import("inspector_panels.zig").MetricsPanel;
    pub const InspectorRendererPanel = @import("inspector_panels.zig").RendererPanel;
    pub const InspectorRendererState = @import("inspector_panels.zig").RendererState;
    pub const InspectorReloadPanel = @import("inspector_panels.zig").ReloadPanel;
    pub const InspectorBindingsPanel = @import("inspector_panels.zig").BindingsPanel;
    pub const InspectorProfilePanel = @import("inspector_panels.zig").ProfilePanel;
    pub const InspectorSubsystemPanel = @import("inspector_panels.zig").SubsystemPanel;
    pub const InspectorSubsystemState = @import("inspector_panels.zig").SubsystemState;
    pub const inspector = @import("inspector.zig");
    pub const inspectorPanels = @import("inspector_panels.zig");
    pub const PresentationRect = @import("presentation.zig").PresentationRect;
    pub const PrimitiveBatch = @import("primitive_batch.zig").PrimitiveBatch;
    pub const PrimitiveBatchDraw = @import("primitive_batch.zig").Draw;
    pub const PrimitiveBatchPoint = @import("primitive_batch.zig").Point;
    pub const PrimitiveBatchVertex = @import("primitive_batch.zig").Vertex;
    pub const RenderCommand = @import("render.zig").Command;
    pub const RenderCommandBuffer = @import("render.zig").CommandBuffer;
    pub const SpriteBatch = @import("sprite_batch.zig").SpriteBatch;
    pub const SpriteBatchGroup = @import("sprite_batch.zig").Batch;
    pub const SpriteBatchDraw = @import("sprite_batch.zig").SpriteDraw;
    pub const SpriteSourceRect = @import("sprite_batch.zig").SourceRect;
    pub const SpriteBatchPoint = @import("sprite_batch.zig").Point;
    pub const SpriteBatchUv = @import("sprite_batch.zig").Uv;
    pub const SpriteBatchVertex = @import("sprite_batch.zig").Vertex;
    pub const TextAlignment = @import("text_layout.zig").Alignment;
    pub const TextLayoutOptions = @import("text_layout.zig").Options;
    pub const TextLayout = @import("text_layout.zig").Layout;
    pub const layoutText = @import("text_layout.zig").layout;
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
    pub const AudioMixer = @import("audio.zig").AudioMixer;
    pub const AudioSample = @import("audio.zig").AudioSample;
    pub const Animation = @import("atlas.zig").Animation;
    pub const AnimationFrame = @import("atlas.zig").AnimationFrame;
    pub const AnimationHandle = @import("atlas.zig").AnimationHandle;
    pub const AnimationPlayer = @import("atlas.zig").AnimationPlayer;
    pub const AnimationStateMachine = @import("animation_state.zig").Machine;
    pub const AnimationState = @import("animation_state.zig").State;
    pub const AnimationTransition = @import("animation_state.zig").Transition;
    pub const AnimationStateDiagnostic = @import("animation_state.zig").Diagnostic;
    pub const animationState = @import("animation_state.zig");
    pub const AtlasFrame = @import("atlas.zig").AtlasFrame;
    pub const AtlasFrameHandle = @import("atlas.zig").AtlasFrameHandle;
    pub const BusHandle = @import("audio.zig").BusHandle;
    pub const DrawSpriteOptions = @import("atlas.zig").DrawSpriteOptions;
    pub const SpriteSampling = @import("atlas.zig").Sampling;
    pub const FontGlyph = @import("font_asset.zig").Glyph;
    pub const FontHandle = @import("assets.zig").FontHandle;
    pub const FontLoadOptions = @import("font_asset.zig").LoadOptions;
    pub const ImageDecodeOptions = @import("image.zig").DecodeOptions;
    pub const ImageHandle = @import("assets.zig").ImageHandle;
    pub const MusicOptions = @import("audio.zig").MusicOptions;
    pub const PlaybackHandle = @import("audio.zig").PlaybackHandle;
    pub const ReloadEvent = @import("assets.zig").ReloadEvent;
    pub const ReloadStatus = @import("assets.zig").ReloadStatus;
    pub const SoundOptions = @import("audio.zig").SoundOptions;
    pub const TextHandle = @import("assets.zig").TextHandle;
};

pub const preview = struct {
    pub const developer = struct {
        pub const InputReplay = @import("input_replay.zig").Replay;
        pub const InputReplayButton = @import("input_replay.zig").Button;
        pub const InputReplayRecorder = @import("input_replay.zig").Recorder;
        pub const parseInputReplay = @import("input_replay.zig").parse;
    };
};
pub const testSupport = @import("test_support.zig");

test "public API excludes removed and unsupported systems" {
    inline for (.{ "effects", "PixelEffect", "PostProcessChain", "ShaderProgram", "ShaderAssetHandle", "lighting", "GpuResourceKind", "GpuResources", "TextureHandle", "RenderTargetHandle", "ShaderHandle", "PipelineHandle" }) |name| {
        try std.testing.expect(!@hasDecl(@This(), name));
    }
    inline for (.{ "world", "TileMap", "TileMapLayer", "TileCollider", "CharacterController", "collision", "Broadphase", "InspectorCollisionPanel" }) |name| {
        try std.testing.expect(!@hasDecl(@This(), name));
    }
    try std.testing.expect(!@hasDecl(@This(), "physics"));
    try std.testing.expect(!@hasDecl(@This(), "PhysicsWorld"));
    try std.testing.expect(!@hasDecl(@This(), "NetMessage"));
    try std.testing.expect(!@hasDecl(@This(), "NetContract"));
    try std.testing.expect(!@hasDecl(@This(), "NetTransport"));
    try std.testing.expect(!@hasDecl(@This(), "P2pPeer"));
    try std.testing.expect(!@hasDecl(@This(), "PredictionClient"));
    try std.testing.expect(!@hasDecl(@This(), "FaultNetwork"));
    try std.testing.expect(!@hasDecl(@This(), "netCodec"));
    try std.testing.expect(!@hasDecl(@This(), "InspectorNetworkPanel"));
    try std.testing.expect(!@hasDecl(graphics, "InspectorNetworkPanel"));
    inline for (.{ "CameraBounds", "CameraDirector", "CameraFollow", "CameraHandle", "CameraRig", "CameraShake", "CameraShot", "CameraViewport" }) |name| {
        try std.testing.expect(!@hasDecl(graphics, name));
    }
}
