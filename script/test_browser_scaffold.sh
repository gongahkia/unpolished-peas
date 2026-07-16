#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
stage=$(mktemp -d)
trap 'rm -f "$stage/web/unpolished-peas.wasm"; rmdir "$stage/web" 2>/dev/null || true; rmdir "$stage" 2>/dev/null || true' EXIT HUP INT TERM

cd "$repo"
zig build browser -p "$stage"
[ -f "$stage/web/unpolished-peas.wasm" ]
[ "$(od -An -tx1 -N4 "$stage/web/unpolished-peas.wasm" | tr -d ' \n')" = 0061736d ]
node script/test_browser_wasm_host.mjs "$stage/web/unpolished-peas.wasm"
for symbol in \
    up_host_schedule_frame up_host_cancel_frame \
    up_host_gl_context_create up_host_gl_context_destroy up_host_gl_resource_create up_host_gl_resource_destroy up_host_gl_context_lost \
    up_host_gl_clear up_host_gl_draw_rect up_host_gl_draw_line up_host_gl_draw_circle up_host_gl_draw_triangle up_host_gl_present \
    up_host_gl_texture_upload up_host_gl_draw_sprite up_host_gl_flush_sprites up_host_gl_draw_text \
    up_host_input_poll up_host_input_read up_host_audio_state up_host_audio_submit \
    up_host_storage_read up_host_storage_write up_host_storage_remove up_host_diagnostic_emit up_host_teardown \
    up_browser_abi_version up_browser_init up_browser_frame up_browser_resize up_browser_cancel_frame \
    up_browser_gl_context_create up_browser_gl_context_destroy up_browser_gl_resource_create up_browser_gl_resource_destroy up_browser_gl_context_lost \
    up_browser_clear up_browser_draw_rect up_browser_draw_line up_browser_draw_circle up_browser_draw_triangle up_browser_present \
    up_browser_texture_upload up_browser_draw_sprite up_browser_flush_sprites up_browser_draw_text \
    up_browser_input_poll up_browser_input_read up_browser_audio_state up_browser_audio_submit \
    up_browser_storage_read up_browser_storage_write up_browser_storage_remove up_browser_diagnostic_emit up_browser_shutdown
do
    strings "$stage/web/unpolished-peas.wasm" | grep -qx "$symbol"
done
