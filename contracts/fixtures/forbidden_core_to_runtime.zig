const core = @import("minna-san-core");
const runtime = @import("minna-san-runtime");

test "core cannot import runtime" {
    _ = core.marker;
    _ = runtime;
}
