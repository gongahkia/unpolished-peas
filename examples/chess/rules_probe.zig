pub export fn chess_rules_check() u64 {
    return @import("rules_checks.zig").verify() catch 0;
}
