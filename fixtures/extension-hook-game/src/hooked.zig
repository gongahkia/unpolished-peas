const std = @import("std");
const effects = @import("unpolished-peas-effects");

test "explicit extension hook imports the declared module" {
    const program = try effects.ShaderProgram.compile("effect=passthrough\n");
    try std.testing.expectEqual(effects.ShaderKind.passthrough, program.kind);
}
