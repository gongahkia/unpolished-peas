const core = @import("minna-san-core");

pub const SdkBuffer = struct {
    owned: core.OwnedBuffer,

    pub fn init_from_transfer(transfer: *core.TransferredBuffer) core.TransferError!SdkBuffer {
        return .{ .owned = try transfer.into_owned() };
    }

    pub fn borrow(self: *const SdkBuffer) core.BorrowedBuffer {
        return self.owned.borrow();
    }

    pub fn ownership(_: *const SdkBuffer) core.Ownership {
        return .owned;
    }

    pub fn retain(self: *const SdkBuffer, allocator: @import("std").mem.Allocator) @import("std").mem.Allocator.Error!core.RetainedBuffer {
        return core.RetainedBuffer.retain(allocator, self.borrow());
    }

    pub fn into_transfer(self: *SdkBuffer) core.TransferError!core.TransferredBuffer {
        const transfer = try self.owned.into_transfer();
        self.* = undefined;
        return transfer;
    }

    pub fn deinit(self: *SdkBuffer) void {
        self.owned.deinit();
        self.* = undefined;
    }
};

test "SDK buffers own transferred memory and expose borrowed views" {
    var caller_owned = try core.OwnedBuffer.initCopy(@import("std").testing.allocator, "sdk");
    var transfer = try core.TransferredBuffer.init(&caller_owned);
    var sdk_buffer = try SdkBuffer.init_from_transfer(&transfer);
    try @import("std").testing.expectEqualStrings("sdk", sdk_buffer.borrow().bytes);
    var retained = try sdk_buffer.retain(@import("std").testing.allocator);
    defer retained.deinit();
    try @import("std").testing.expectEqualStrings("sdk", retained.borrow().bytes);
    try @import("std").testing.expectError(error.BufferAlreadyTransferred, SdkBuffer.init_from_transfer(&transfer));
    var returned = try sdk_buffer.into_transfer();
    var caller_reclaimed = try returned.into_owned();
    caller_reclaimed.deinit();
}
