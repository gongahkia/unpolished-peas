const core = @import("minna-san-core");
const protocol = @import("minna-san-protocol");
const migration_coordinator = @import("migration_coordinator.zig");

pub const max_migration_records = migration_coordinator.max_migration_records;
pub const MigrationTerm = migration_coordinator.MigrationTerm;
pub const MigrationHostId = migration_coordinator.MigrationHostId;
pub const MigrationRoute = migration_coordinator.MigrationRoute;
pub const MigrationHostHealth = migration_coordinator.MigrationHostHealth;
pub const MigrationRecordState = migration_coordinator.MigrationRecordState;
pub const MigrationPlan = migration_coordinator.MigrationPlan;
pub const MigrationRecord = migration_coordinator.MigrationRecord;
pub const MigrationCoordinatorError = migration_coordinator.MigrationCoordinatorError;
pub const MigrationCoordinatorConfig = migration_coordinator.MigrationCoordinatorConfig;
pub const MigrationCoordinator = migration_coordinator.MigrationCoordinator;

pub const package_name = "state";

comptime {
    _ = core.package_name;
    _ = protocol.package_name;
}

test "state package boundary" {
    try @import("std").testing.expectEqualStrings("state", package_name);
}

test {
    _ = @import("migration_coordinator.zig");
}
