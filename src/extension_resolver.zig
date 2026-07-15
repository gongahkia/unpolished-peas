const std = @import("std");

const ResolveError = error{ InvalidVersion, InvalidRange, InvalidPackage, DuplicatePackage, MissingPackage, IncompatibleCore, UnsatisfiedRequirements, OutOfMemory };

pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,

    pub fn parse(value: []const u8) ResolveError!Version {
        var parts = std.mem.splitScalar(u8, value, '.');
        const major = parts.next() orelse return error.InvalidVersion;
        const minor = parts.next() orelse return error.InvalidVersion;
        const patch = parts.next() orelse return error.InvalidVersion;
        if (parts.next() != null) return error.InvalidVersion;
        return .{
            .major = std.fmt.parseUnsigned(u32, major, 10) catch return error.InvalidVersion,
            .minor = std.fmt.parseUnsigned(u32, minor, 10) catch return error.InvalidVersion,
            .patch = std.fmt.parseUnsigned(u32, patch, 10) catch return error.InvalidVersion,
        };
    }

    pub fn eql(lhs: Version, rhs: Version) bool {
        return lhs.major == rhs.major and lhs.minor == rhs.minor and lhs.patch == rhs.patch;
    }

    pub fn lessThan(lhs: Version, rhs: Version) bool {
        if (lhs.major != rhs.major) return lhs.major < rhs.major;
        if (lhs.minor != rhs.minor) return lhs.minor < rhs.minor;
        return lhs.patch < rhs.patch;
    }
};

pub const Requirement = struct {
    name: []const u8,
    range: []const u8,
};

pub const Package = struct {
    name: []const u8,
    version: []const u8,
    core_range: []const u8,
    dependencies: []const Requirement = &.{},
};

pub const Input = struct {
    core_version: []const u8,
    requirements: []const Requirement,
    packages: []const Package,
};

pub const Lock = struct {
    allocator: std.mem.Allocator,
    core: Version,
    packages: []const *const Package,

    pub fn deinit(self: *Lock) void {
        self.allocator.free(self.packages);
        self.* = undefined;
    }
};

const State = struct {
    requirements: std.ArrayListUnmanaged(Requirement) = .{},
    selected: std.ArrayListUnmanaged(*const Package) = .{},

    fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.requirements.deinit(allocator);
        self.selected.deinit(allocator);
        self.* = undefined;
    }

    fn clone(self: State, allocator: std.mem.Allocator) ResolveError!State {
        var result = State{};
        errdefer result.deinit(allocator);
        try result.requirements.appendSlice(allocator, self.requirements.items);
        try result.selected.appendSlice(allocator, self.selected.items);
        return result;
    }
};

pub fn resolve(allocator: std.mem.Allocator, input: Input) ResolveError!Lock {
    const core = try Version.parse(input.core_version);
    try validateCatalog(input.packages);
    var state = State{};
    defer state.deinit(allocator);
    try state.requirements.appendSlice(allocator, input.requirements);
    try solve(allocator, core, input.packages, &state);
    sortPackages(state.selected.items);
    return .{
        .allocator = allocator,
        .core = core,
        .packages = try allocator.dupe(*const Package, state.selected.items),
    };
}

fn validateCatalog(packages: []const Package) ResolveError!void {
    for (packages, 0..) |package, index| {
        if (package.name.len == 0) return error.InvalidPackage;
        _ = try Version.parse(package.version);
        _ = try rangeMatches(package.core_range, .{ .major = 1, .minor = 0, .patch = 0 });
        for (package.dependencies) |dependency| {
            if (dependency.name.len == 0) return error.InvalidPackage;
            _ = try rangeMatches(dependency.range, .{ .major = 1, .minor = 0, .patch = 0 });
        }
        for (packages[index + 1 ..]) |other| {
            if (!std.mem.eql(u8, package.name, other.name)) continue;
            if ((try Version.parse(package.version)).eql(try Version.parse(other.version))) return error.DuplicatePackage;
        }
    }
}

fn solve(allocator: std.mem.Allocator, core: Version, packages: []const Package, state: *State) ResolveError!void {
    try validateSelected(core, state.*);
    const name = nextUnselectedName(state.*) orelse return;
    var candidates = std.ArrayListUnmanaged(*const Package){};
    defer candidates.deinit(allocator);
    var has_name = false;
    var has_core_compatible = false;
    for (packages) |*candidate| {
        if (!std.mem.eql(u8, candidate.name, name)) continue;
        has_name = true;
        if (!(try rangeMatches(candidate.core_range, core))) continue;
        has_core_compatible = true;
        if (!(try candidateMatchesRequirements(candidate.*, state.requirements.items))) continue;
        try candidates.append(allocator, candidate);
    }
    if (candidates.items.len == 0) {
        if (!has_name) return error.MissingPackage;
        if (!has_core_compatible) return error.IncompatibleCore;
        return error.UnsatisfiedRequirements;
    }
    sortCandidates(candidates.items);
    for (candidates.items) |candidate| {
        var attempt = try state.clone(allocator);
        errdefer attempt.deinit(allocator);
        try attempt.selected.append(allocator, candidate);
        try attempt.requirements.appendSlice(allocator, candidate.dependencies);
        solve(allocator, core, packages, &attempt) catch |err| switch (err) {
            error.MissingPackage, error.IncompatibleCore, error.UnsatisfiedRequirements => {
                attempt.deinit(allocator);
                continue;
            },
            else => return err,
        };
        state.deinit(allocator);
        state.* = attempt;
        return;
    }
    return error.UnsatisfiedRequirements;
}

fn validateSelected(core: Version, state: State) ResolveError!void {
    for (state.selected.items) |package| {
        if (!(try rangeMatches(package.core_range, core))) return error.IncompatibleCore;
        const version = try Version.parse(package.version);
        for (state.requirements.items) |requirement| {
            if (!std.mem.eql(u8, requirement.name, package.name)) continue;
            if (!(try rangeMatches(requirement.range, version))) return error.UnsatisfiedRequirements;
        }
    }
}

fn nextUnselectedName(state: State) ?[]const u8 {
    var next: ?[]const u8 = null;
    for (state.requirements.items) |requirement| {
        if (selectedFor(state, requirement.name) != null) continue;
        if (next == null or std.mem.order(u8, requirement.name, next.?) == .lt) next = requirement.name;
    }
    return next;
}

fn selectedFor(state: State, name: []const u8) ?*const Package {
    for (state.selected.items) |package| if (std.mem.eql(u8, package.name, name)) return package;
    return null;
}

fn candidateMatchesRequirements(candidate: Package, requirements: []const Requirement) ResolveError!bool {
    const version = try Version.parse(candidate.version);
    for (requirements) |requirement| {
        if (!std.mem.eql(u8, requirement.name, candidate.name)) continue;
        if (!(try rangeMatches(requirement.range, version))) return false;
    }
    return true;
}

fn sortCandidates(candidates: []*const Package) void {
    var index: usize = 1;
    while (index < candidates.len) : (index += 1) {
        var cursor = index;
        while (cursor > 0) : (cursor -= 1) {
            const lhs = Version.parse(candidates[cursor - 1].version) catch unreachable;
            const rhs = Version.parse(candidates[cursor].version) catch unreachable;
            if (!lhs.lessThan(rhs)) break;
            const swap = candidates[cursor - 1];
            candidates[cursor - 1] = candidates[cursor];
            candidates[cursor] = swap;
        }
    }
}

fn sortPackages(packages: []*const Package) void {
    var index: usize = 1;
    while (index < packages.len) : (index += 1) {
        var cursor = index;
        while (cursor > 0 and std.mem.order(u8, packages[cursor].name, packages[cursor - 1].name) == .lt) : (cursor -= 1) {
            const swap = packages[cursor - 1];
            packages[cursor - 1] = packages[cursor];
            packages[cursor] = swap;
        }
    }
}

fn rangeMatches(range: []const u8, version: Version) ResolveError!bool {
    if (std.mem.eql(u8, range, "*")) return true;
    if (range.len == 0) return error.InvalidRange;
    if (range[0] == '^') return caretMatches(try Version.parse(range[1..]), version);
    var clauses = std.mem.tokenizeAny(u8, range, " \t");
    var count: usize = 0;
    while (clauses.next()) |clause| {
        count += 1;
        if (!(try clauseMatches(clause, version))) return false;
    }
    return count > 0;
}

fn caretMatches(minimum: Version, version: Version) ResolveError!bool {
    if (version.lessThan(minimum)) return false;
    var maximum = minimum;
    if (minimum.major != 0) {
        if (minimum.major == std.math.maxInt(u32)) return error.InvalidRange;
        maximum.major += 1;
        maximum.minor = 0;
        maximum.patch = 0;
    } else if (minimum.minor != 0) {
        if (minimum.minor == std.math.maxInt(u32)) return error.InvalidRange;
        maximum.minor += 1;
        maximum.patch = 0;
    } else {
        if (minimum.patch == std.math.maxInt(u32)) return error.InvalidRange;
        maximum.patch += 1;
    }
    return version.lessThan(maximum);
}

fn clauseMatches(clause: []const u8, version: Version) ResolveError!bool {
    const Prefix = enum { eq, gt, gte, lt, lte };
    const prefix: Prefix, const source: []const u8 = if (std.mem.startsWith(u8, clause, ">=")) .{ .gte, clause[2..] } else if (std.mem.startsWith(u8, clause, "<=")) .{ .lte, clause[2..] } else if (std.mem.startsWith(u8, clause, ">")) .{ .gt, clause[1..] } else if (std.mem.startsWith(u8, clause, "<")) .{ .lt, clause[1..] } else .{ .eq, clause };
    const target = try Version.parse(source);
    return switch (prefix) {
        .eq => version.eql(target),
        .gt => target.lessThan(version),
        .gte => !version.lessThan(target),
        .lt => version.lessThan(target),
        .lte => !target.lessThan(version),
    };
}

fn assertLockFixture(lock: Lock, fixture: []const u8) !void {
    var lines = std.mem.splitScalar(u8, fixture, '\n');
    try std.testing.expectEqualStrings("format=unpolished-peas-extension-lock", lines.next() orelse return error.InvalidFixture);
    try std.testing.expectEqualStrings("version=1", lines.next() orelse return error.InvalidFixture);
    var core_buffer: [64]u8 = undefined;
    const core_line = try std.fmt.bufPrint(&core_buffer, "core={d}.{d}.{d}", .{ lock.core.major, lock.core.minor, lock.core.patch });
    try std.testing.expectEqualStrings(core_line, lines.next() orelse return error.InvalidFixture);
    for (lock.packages) |package| {
        var package_buffer: [256]u8 = undefined;
        const package_line = try std.fmt.bufPrint(&package_buffer, "package={s}@{s}", .{ package.name, package.version });
        try std.testing.expectEqualStrings(package_line, lines.next() orelse return error.InvalidFixture);
    }
    while (lines.next()) |line| try std.testing.expectEqualStrings("", line);
}

test "extension resolver emits a reproducible versioned lock fixture" {
    const renderer_dependencies = [_]Requirement{.{ .name = "effects", .range = "^1.0.0" }};
    const effects_dependencies = [_]Requirement{.{ .name = "physics", .range = ">=1.0.0 <1.1.0" }};
    const packages = [_]Package{
        .{ .name = "physics", .version = "1.0.0", .core_range = ">=1.0.0 <2.0.0" },
        .{ .name = "effects", .version = "1.0.0", .core_range = "^1.0.0", .dependencies = &effects_dependencies },
        .{ .name = "renderer", .version = "1.0.0", .core_range = "^1.0.0", .dependencies = &renderer_dependencies },
        .{ .name = "physics", .version = "1.0.1", .core_range = ">=1.0.0 <2.0.0" },
        .{ .name = "effects", .version = "1.1.0", .core_range = "^1.0.0", .dependencies = &effects_dependencies },
        .{ .name = "renderer", .version = "1.1.0", .core_range = "^1.0.0", .dependencies = &renderer_dependencies },
        .{ .name = "renderer", .version = "2.0.0", .core_range = "^2.0.0" },
    };
    const reversed = [_]Package{ packages[6], packages[5], packages[4], packages[3], packages[2], packages[1], packages[0] };
    const requirements = [_]Requirement{.{ .name = "renderer", .range = "^1.0.0" }};
    var forward = try resolve(std.testing.allocator, .{ .core_version = "1.0.0", .requirements = &requirements, .packages = &packages });
    defer forward.deinit();
    var reverse = try resolve(std.testing.allocator, .{ .core_version = "1.0.0", .requirements = &requirements, .packages = &reversed });
    defer reverse.deinit();
    const fixture = try std.fs.cwd().readFileAlloc(std.testing.allocator, "fixtures/extensions/core-1.lock", 4096);
    defer std.testing.allocator.free(fixture);
    try assertLockFixture(forward, fixture);
    try assertLockFixture(reverse, fixture);
}

test "extension resolver rejects incompatible core and package ranges" {
    const no_dependencies = [_]Requirement{};
    const core_incompatible = [_]Package{.{ .name = "renderer", .version = "1.0.0", .core_range = "^2.0.0", .dependencies = &no_dependencies }};
    const renderer_dependencies = [_]Requirement{.{ .name = "effects", .range = "^2.0.0" }};
    const conflict = [_]Package{
        .{ .name = "renderer", .version = "1.0.0", .core_range = "^1.0.0", .dependencies = &renderer_dependencies },
        .{ .name = "effects", .version = "1.0.0", .core_range = "^1.0.0", .dependencies = &no_dependencies },
        .{ .name = "effects", .version = "2.0.0", .core_range = "^1.0.0", .dependencies = &no_dependencies },
    };
    const renderer_requirement = [_]Requirement{.{ .name = "renderer", .range = "^1.0.0" }};
    const conflict_requirements = [_]Requirement{
        .{ .name = "renderer", .range = "^1.0.0" },
        .{ .name = "effects", .range = "^1.0.0" },
    };
    try std.testing.expectError(error.IncompatibleCore, resolve(std.testing.allocator, .{ .core_version = "1.0.0", .requirements = &renderer_requirement, .packages = &core_incompatible }));
    try std.testing.expectError(error.UnsatisfiedRequirements, resolve(std.testing.allocator, .{ .core_version = "1.0.0", .requirements = &conflict_requirements, .packages = &conflict }));
}
