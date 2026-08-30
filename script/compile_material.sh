#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage:
  peas shader compile <linux|windows|macos> <source.upshader> <output-directory>
  peas shader assemble <source.upshader> <artifact-directory> <output.upmat>

source manifests use key=value lines. Required keys are name, vertex.glsl,
fragment.glsl, vertex.webgl2, vertex.webgpu, fragment.webgl2, fragment.webgpu,
and one or more binding=texture:name or binding=uniform:name lines. Compile
emits one platform-native AOT artifact set. Assemble is run after the three
native CI jobs have placed their outputs in artifact-directory/{linux,windows,
macos}; it writes the runtime .upmat manifest with no source compilation step.
EOF
}

command_name="${1:-}"
if [[ "$command_name" != "compile" && "$command_name" != "assemble" ]]; then usage >&2; exit 64; fi
shift

value() {
  local key="$1" file="$2"
  awk -F= -v key="$key" '$1 == key { if (seen++) exit 2; print substr($0, length(key) + 2) } END { if (!seen) exit 1 }' "$file"
}

copy_web_sources() {
  local source="$1" output="$2"
  for stage in vertex fragment; do
    for target in webgl2 webgpu; do
      local path
      path="$(value "$stage.$target" "$source")" || { echo "peas shader: missing $stage.$target" >&2; exit 65; }
      cp "$(dirname "$source")/$path" "$output/$stage.$target"
    done
  done
}

if [[ "$command_name" == "compile" ]]; then
  target="${1:-}"; source="${2:-}"; output="${3:-}"
  [[ -n "$target" && -n "$source" && -n "$output" && $# -eq 3 ]] || { usage >&2; exit 64; }
  [[ "$target" == linux || "$target" == windows || "$target" == macos ]] || { usage >&2; exit 64; }
  command -v glslangValidator >/dev/null || { echo "peas shader: glslangValidator is required" >&2; exit 69; }
  mkdir -p "$output"
  copy_web_sources "$source" "$output"
  for stage in vertex fragment; do
    glsl="$(value "$stage.glsl" "$source")" || { echo "peas shader: missing $stage.glsl" >&2; exit 65; }
    glslangValidator -V -S "$([[ "$stage" == vertex ]] && echo vert || echo frag)" "$(dirname "$source")/$glsl" -o "$output/$stage.spv"
  done
  case "$target" in
    linux)
      ;;
    windows)
      command -v fxc >/dev/null || { echo "peas shader: fxc is required to emit DXBC AOT artifacts" >&2; exit 69; }
      command -v spirv-cross >/dev/null || { echo "peas shader: spirv-cross is required to generate HLSL" >&2; exit 69; }
      for stage in vertex fragment; do
        spirv-cross "$output/$stage.spv" --hlsl --shader-model 51 --output "$output/$stage.hlsl"
        fxc /nologo /T "$([[ "$stage" == vertex ]] && echo vs_5_1 || echo ps_5_1)" /E main /Fo "$output/$stage.dxbc" "$output/$stage.hlsl"
      done
      ;;
    macos)
      command -v spirv-cross >/dev/null || { echo "peas shader: spirv-cross is required to generate Metal" >&2; exit 69; }
      command -v xcrun >/dev/null || { echo "peas shader: xcrun is required to emit metallib AOT artifacts" >&2; exit 69; }
      for stage in vertex fragment; do
        spirv-cross "$output/$stage.spv" --msl --output "$output/$stage.metal"
        xcrun metal -c "$output/$stage.metal" -o "$output/$stage.air"
        xcrun metallib "$output/$stage.air" -o "$output/$stage.metallib"
      done
      ;;
  esac
  echo "peas shader: compiled $target artifacts in $output"
  exit 0
fi

source="${1:-}"; artifacts="${2:-}"; output="${3:-}"
[[ -n "$source" && -n "$artifacts" && -n "$output" && $# -eq 3 ]] || { usage >&2; exit 64; }
name="$(value name "$source")" || { echo "peas shader: missing name" >&2; exit 65; }
for required in linux/vertex.spv linux/fragment.spv linux/vertex.webgl2 linux/vertex.webgpu linux/fragment.webgl2 linux/fragment.webgpu windows/vertex.dxbc windows/fragment.dxbc macos/vertex.metallib macos/fragment.metallib; do
  [[ -s "$artifacts/$required" ]] || { echo "peas shader: missing required artifact $artifacts/$required" >&2; exit 65; }
done
mkdir -p "$(dirname "$output")"
relative_to_manifest() {
  python3 -c 'import os, sys; print(os.path.relpath(sys.argv[2], sys.argv[1]))' "$(dirname "$output")" "$1"
}
vertex_spirv="$(relative_to_manifest "$artifacts/linux/vertex.spv")"
vertex_dxbc="$(relative_to_manifest "$artifacts/windows/vertex.dxbc")"
vertex_metallib="$(relative_to_manifest "$artifacts/macos/vertex.metallib")"
vertex_webgl2="$(relative_to_manifest "$artifacts/linux/vertex.webgl2")"
vertex_webgpu="$(relative_to_manifest "$artifacts/linux/vertex.webgpu")"
fragment_spirv="$(relative_to_manifest "$artifacts/linux/fragment.spv")"
fragment_dxbc="$(relative_to_manifest "$artifacts/windows/fragment.dxbc")"
fragment_metallib="$(relative_to_manifest "$artifacts/macos/fragment.metallib")"
fragment_webgl2="$(relative_to_manifest "$artifacts/linux/fragment.webgl2")"
fragment_webgpu="$(relative_to_manifest "$artifacts/linux/fragment.webgpu")"
{
  printf 'name=%s\n' "$name"
  printf 'vertex.spirv=%s\nvertex.dxbc=%s\nvertex.metallib=%s\nvertex.webgl2=%s\nvertex.webgpu=%s\n' \
    "$vertex_spirv" "$vertex_dxbc" "$vertex_metallib" "$vertex_webgl2" "$vertex_webgpu"
  printf 'fragment.spirv=%s\nfragment.dxbc=%s\nfragment.metallib=%s\nfragment.webgl2=%s\nfragment.webgpu=%s\n' \
    "$fragment_spirv" "$fragment_dxbc" "$fragment_metallib" "$fragment_webgl2" "$fragment_webgpu"
  awk -F= '$1 == "binding" { print }' "$source"
} > "$output"
echo "peas shader: assembled $output"
