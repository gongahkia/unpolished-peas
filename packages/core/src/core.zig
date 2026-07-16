const taxonomy = @import("error_taxonomy.zig");
const ownership = @import("ownership.zig");

pub const ErrorClass = taxonomy.ErrorClass;
pub const CResult = taxonomy.CResult;
pub const ZigError = taxonomy.ZigError;
pub const all_errors = taxonomy.all_errors;
pub const class_for_error = taxonomy.class_for_error;
pub const error_for_class = taxonomy.error_for_class;
pub const c_result_for_class = taxonomy.c_result_for_class;
pub const class_for_c_result = taxonomy.class_for_c_result;
pub const c_result_for_error = taxonomy.c_result_for_error;
pub const error_for_c_result = taxonomy.error_for_c_result;
pub const c_result_from_code = taxonomy.c_result_from_code;
pub const Ownership = ownership.Ownership;
pub const BorrowedBuffer = ownership.BorrowedBuffer;
pub const OwnedBuffer = ownership.OwnedBuffer;
pub const package_name = "core";

test "core package boundary" {
    try @import("std").testing.expectEqualStrings("core", package_name);
}

test {
    _ = @import("error_taxonomy.zig");
    _ = @import("ownership.zig");
}
