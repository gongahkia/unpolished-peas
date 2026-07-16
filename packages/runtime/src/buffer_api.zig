const core = @import("minna-san-core");

pub const SdkBuffer = struct {
    owned: core.OwnedBuffer,

    pub fn init_from_transfer(transfer: *core.TransferredBuffer) core.TransferError!SdkBuffer {
        return .{ .owned = try transfer.into_owned() };
    }

    pub fn borrow(self: *const SdkBuffer) core.BorrowedBuffer {
        return self.owned.borrow();
    }

    pub fn into_transfer(self: *SdkBuffer) core.TransferredBuffer {
        const owned = self.owned;
        self.* = undefined;
        return .init(owned);
    }

    pub fn deinit(self: *SdkBuffer) void {
        self.owned.deinit();
        self.* = undefined;
    }
};

test "SDK buffers own transferred memory and expose borrowed views" {
    const caller_owned = try core.OwnedBuffer.initCopy(@import("std").testing.allocator, "sdk");
    var transfer = core.TransferredBuffer.init(caller_owned);
    var sdk_buffer = try SdkBuffer.init_from_transfer(&transfer);
    try @import("std").testing.expectEqualStrings("sdk", sdk_buffer.borrow().bytes);
    try @import("std").testing.expectError(error.BufferAlreadyTransferred, SdkBuffer.init_from_transfer(&transfer));
    var returned = sdk_buffer.into_transfer();
    var caller_reclaimed = try returned.into_owned();
    caller_reclaimed.deinit();
}
