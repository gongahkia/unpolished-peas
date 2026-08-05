const std = @import("std");

pub const max_migration_records: usize = 16;
pub const MigrationTerm = u64;
pub const MigrationHostId = u64;
pub const MigrationRoute = enum { direct, relay, authoritative };
pub const MigrationHostHealth = enum { healthy, degraded, unavailable };
pub const MigrationRecordState = enum { prepared, committed, aborted };
pub const MigrationPlan = struct {
    term: MigrationTerm,
    host: MigrationHostId,
    membership_revision: u64,
    membership_count: usize,
    host_is_member: bool,
    health: MigrationHostHealth,
    route: MigrationRoute,
    route_negotiated: bool,
    state_revision: u64,
};
pub const MigrationRecord = struct {
    state: MigrationRecordState,
    plan: MigrationPlan,
};
pub const MigrationCoordinatorError = error{ InvalidConfiguration, InvalidPlan, MigrationPending, StaleTerm, StaleMembership, StateRevisionRegression, UnhealthyHost, RouteUnavailable, NoMigration, TermMismatch, StateRevisionMismatch, RecordOutputTooSmall };
pub const MigrationCoordinatorConfig = struct {
    initial_host: MigrationHostId,
    initial_term: MigrationTerm,
    initial_membership_revision: u64,
    initial_state_revision: u64,
    maximum_records: usize,
};

pub const MigrationCoordinator = struct {
    config: MigrationCoordinatorConfig,
    committed_term: MigrationTerm,
    highest_observed_term: MigrationTerm,
    membership_revision: u64,
    state_revision: u64,
    active_host: MigrationHostId,
    pending: ?MigrationPlan = null,
    active_record: ?MigrationRecord = null,
    records: [max_migration_records]MigrationRecord = undefined,
    record_start: usize = 0,
    record_count: usize = 0,

    pub fn init(config: MigrationCoordinatorConfig) MigrationCoordinatorError!MigrationCoordinator {
        if (config.initial_host == 0 or config.maximum_records == 0 or config.maximum_records > max_migration_records) return error.InvalidConfiguration;
        return .{
            .config = config,
            .committed_term = config.initial_term,
            .highest_observed_term = config.initial_term,
            .membership_revision = config.initial_membership_revision,
            .state_revision = config.initial_state_revision,
            .active_host = config.initial_host,
        };
    }
    pub fn current_host(self: MigrationCoordinator) MigrationHostId {
        return self.active_host;
    }
    pub fn current_term(self: MigrationCoordinator) MigrationTerm {
        return self.committed_term;
    }
    pub fn current_state_revision(self: MigrationCoordinator) u64 {
        return self.state_revision;
    }
    pub fn active(self: MigrationCoordinator) ?MigrationRecord {
        return self.active_record;
    }
    pub fn begin(self: *MigrationCoordinator, proposal: MigrationPlan) MigrationCoordinatorError!void {
        if (self.pending != null) return error.MigrationPending;
        try self.validate_plan(proposal);
        if (proposal.term <= self.highest_observed_term) return error.StaleTerm;
        if (proposal.membership_revision < self.membership_revision) return error.StaleMembership;
        if (proposal.state_revision < self.state_revision) return error.StateRevisionRegression;
        self.highest_observed_term = proposal.term;
        self.pending = proposal;
        self.record(.prepared, proposal);
    }
    pub fn commit(self: *MigrationCoordinator, term: MigrationTerm, state_revision: u64) MigrationCoordinatorError!void {
        const proposal = self.pending orelse return error.NoMigration;
        if (proposal.term != term) return error.TermMismatch;
        if (proposal.state_revision != state_revision) return error.StateRevisionMismatch;
        self.committed_term = proposal.term;
        self.membership_revision = proposal.membership_revision;
        self.state_revision = proposal.state_revision;
        self.active_host = proposal.host;
        self.pending = null;
        const entry = MigrationRecord{ .state = .committed, .plan = proposal };
        self.active_record = entry;
        self.record_record(entry);
    }
    pub fn abort(self: *MigrationCoordinator, term: MigrationTerm) MigrationCoordinatorError!void {
        const proposal = self.pending orelse return error.NoMigration;
        if (proposal.term != term) return error.TermMismatch;
        self.pending = null;
        self.record(.aborted, proposal);
    }
    pub fn list_records(self: MigrationCoordinator, output: []MigrationRecord) MigrationCoordinatorError!usize {
        if (output.len < self.record_count) return error.RecordOutputTooSmall;
        for (0..self.record_count) |index| output[index] = self.records[(self.record_start + index) % self.config.maximum_records];
        return self.record_count;
    }
    fn validate_plan(_: MigrationCoordinator, proposal: MigrationPlan) MigrationCoordinatorError!void {
        if (proposal.term == 0 or proposal.host == 0 or proposal.membership_count == 0 or !proposal.host_is_member) return error.InvalidPlan;
        if (proposal.health != .healthy) return error.UnhealthyHost;
        if (!proposal.route_negotiated) return error.RouteUnavailable;
    }
    fn record(self: *MigrationCoordinator, state: MigrationRecordState, proposal: MigrationPlan) void {
        self.record_record(.{ .state = state, .plan = proposal });
    }
    fn record_record(self: *MigrationCoordinator, entry: MigrationRecord) void {
        if (self.record_count < self.config.maximum_records) {
            self.records[(self.record_start + self.record_count) % self.config.maximum_records] = entry;
            self.record_count += 1;
            return;
        }
        self.records[self.record_start] = entry;
        self.record_start = (self.record_start + 1) % self.config.maximum_records;
    }
};

fn migration_plan(term: MigrationTerm, host: MigrationHostId) MigrationPlan {
    return .{ .term = term, .host = host, .membership_revision = 4, .membership_count = 2, .host_is_member = true, .health = .healthy, .route = .relay, .route_negotiated = true, .state_revision = 9 };
}

test "migration coordinator commits term membership health route and state records" {
    var coordinator = try MigrationCoordinator.init(.{ .initial_host = 1, .initial_term = 1, .initial_membership_revision = 4, .initial_state_revision = 9, .maximum_records = 4 });
    const next = migration_plan(2, 2);
    try coordinator.begin(next);
    try coordinator.commit(2, 9);
    try std.testing.expectEqual(@as(MigrationHostId, 2), coordinator.current_host());
    try std.testing.expectEqual(@as(MigrationTerm, 2), coordinator.current_term());
    try std.testing.expectEqual(MigrationRecordState.committed, coordinator.active().?.state);
    var records: [2]MigrationRecord = undefined;
    try std.testing.expectEqual(@as(usize, 2), try coordinator.list_records(records[0..]));
    try std.testing.expectEqual(MigrationRecordState.prepared, records[0].state);
    try std.testing.expectEqual(MigrationRecordState.committed, records[1].state);
}

test "migration coordinator rejects stale unsafe and mismatched transitions" {
    var coordinator = try MigrationCoordinator.init(.{ .initial_host = 1, .initial_term = 1, .initial_membership_revision = 4, .initial_state_revision = 9, .maximum_records = 2 });
    try std.testing.expectError(error.StaleTerm, coordinator.begin(migration_plan(1, 2)));
    var stale_membership = migration_plan(2, 2);
    stale_membership.membership_revision = 3;
    try std.testing.expectError(error.StaleMembership, coordinator.begin(stale_membership));
    var unhealthy = migration_plan(2, 2);
    unhealthy.health = .degraded;
    try std.testing.expectError(error.UnhealthyHost, coordinator.begin(unhealthy));
    var unavailable = migration_plan(2, 2);
    unavailable.route_negotiated = false;
    try std.testing.expectError(error.RouteUnavailable, coordinator.begin(unavailable));
    try coordinator.begin(migration_plan(2, 2));
    try std.testing.expectError(error.MigrationPending, coordinator.begin(migration_plan(3, 3)));
    try std.testing.expectError(error.TermMismatch, coordinator.commit(3, 9));
    try std.testing.expectError(error.StateRevisionMismatch, coordinator.commit(2, 10));
    try coordinator.abort(2);
    try std.testing.expectError(error.NoMigration, coordinator.abort(2));
    var records: [1]MigrationRecord = undefined;
    try std.testing.expectError(error.RecordOutputTooSmall, coordinator.list_records(records[0..]));
    try std.testing.expectError(error.InvalidConfiguration, MigrationCoordinator.init(.{ .initial_host = 0, .initial_term = 0, .initial_membership_revision = 0, .initial_state_revision = 0, .maximum_records = 0 }));
}
