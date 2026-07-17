const core = @import("minna-san-core");
const protocol = @import("minna-san-protocol");
const migration_coordinator = @import("migration_coordinator.zig");
const host_election = @import("host_election.zig");
const migration_state_transfer = @import("migration_state_transfer.zig");
const serialization_contract = @import("serialization_contract.zig");

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
pub const HostElectionOrder = host_election.HostElectionOrder;
pub const HostElectionMember = host_election.HostElectionMember;
pub const HostElection = host_election.HostElection;
pub const HostElectionError = host_election.HostElectionError;
pub const HostElectionConfig = host_election.HostElectionConfig;
pub const HostElector = host_election.HostElector;
pub const migration_transfer_integrity_tag_bytes = migration_state_transfer.migration_transfer_integrity_tag_bytes;
pub const MigrationStateMetadata = migration_state_transfer.MigrationStateMetadata;
pub const AcknowledgedMigrationSnapshot = migration_state_transfer.AcknowledgedMigrationSnapshot;
pub const MigrationStateTransferFrame = migration_state_transfer.MigrationStateTransferFrame;
pub const MigrationStateTransferError = migration_state_transfer.MigrationStateTransferError;
pub const MigrationStateTransferConfig = migration_state_transfer.MigrationStateTransferConfig;
pub const MigrationStateTransfer = migration_state_transfer.MigrationStateTransfer;
pub const StateSchemaVersion = serialization_contract.StateSchemaVersion;
pub const StateSerializationFailure = serialization_contract.StateSerializationFailure;
pub const StateSerializationError = serialization_contract.StateSerializationError;
pub const StateSerializationAllocateFn = serialization_contract.StateSerializationAllocateFn;
pub const StateSerializationReleaseFn = serialization_contract.StateSerializationReleaseFn;
pub const StateSerializationAllocation = serialization_contract.StateSerializationAllocation;
pub const StateSerializationFrame = serialization_contract.StateSerializationFrame;
pub const StateSchemaVersionFn = serialization_contract.StateSchemaVersionFn;
pub const StateSerializeFn = serialization_contract.StateSerializeFn;
pub const StateDeserializeFn = serialization_contract.StateDeserializeFn;
pub const StateSerializationDeterminismFn = serialization_contract.StateSerializationDeterminismFn;
pub const StateSerializationFailureFn = serialization_contract.StateSerializationFailureFn;
pub const StateSerializationCallbacks = serialization_contract.StateSerializationCallbacks;
pub const StateSerializationConfig = serialization_contract.StateSerializationConfig;
pub const StateSerializationContract = serialization_contract.StateSerializationContract;

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
    _ = @import("host_election.zig");
    _ = @import("migration_state_transfer.zig");
    _ = @import("serialization_contract.zig");
}
