package render

// RenderTarget identifies a TextureStore-owned portable image that a backend
// can render into. Its Texture can later be used by Sprite commands.
type RenderTarget struct{ Texture Texture }

// TargetBackend is an optional Backend capability for complete off-screen
// command-frame submissions. RenderTo preserves the frame's normal command,
// camera, clip, and texture semantics while changing only its destination.
type TargetBackend interface {
	Backend
	RenderTo(Frame, RenderTarget) error
}
