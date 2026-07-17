.PHONY: run-examples
.NOTPARALLEL: run-examples

run-examples:
	zig build run-bounce-sdl -- --renderer sdl-gpu
	zig build run-bounce-sdl -- --renderer opengl
	zig build dev-bounce -- --renderer sdl-gpu
	zig build dev-bounce -- --renderer opengl
	zig build run-minimal -- --renderer sdl-gpu
	zig build run-minimal -- --renderer opengl
	zig build run-explicit-loop -- --renderer sdl-gpu
	zig build run-explicit-loop -- --renderer opengl
	zig build run-audio -- --renderer sdl-gpu
	zig build run-audio -- --renderer opengl
	zig build run-atlas -- --renderer sdl-gpu
	zig build run-atlas -- --renderer opengl
	zig build run-camera -- --renderer sdl-gpu
	zig build run-camera -- --renderer opengl
	zig build run-primitives -- --renderer sdl-gpu
	zig build run-primitives -- --renderer opengl
	zig build run-breakout-sdl -- --renderer sdl-gpu
	zig build run-breakout-sdl -- --renderer opengl
	zig build run-topdown-sdl -- --renderer sdl-gpu
	zig build run-topdown-sdl -- --renderer opengl
	zig build stress-audio-sdl -- --renderer sdl-gpu
	zig build stress-audio-sdl -- --renderer opengl
