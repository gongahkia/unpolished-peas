//! Test-only fault injection around a real in-memory store; writes remain allowed.
const up = @import("unpolished-peas");
const Store = up.core.SaveStore;
pub const ReadFault = struct {
    parent: *Store,
    blocked: bool = true,
    store: Store = undefined,
    const vtable: Store.VTable = .{ .read_size = size, .read = read, .write = write, .delete = delete, .exists = exists };
    pub fn capability(self: *ReadFault) *Store {
        self.store = Store.init(self, &vtable);
        return &self.store;
    }
    fn size(p: *anyopaque, key: []const u8) Store.Error!usize {
        const self: *ReadFault = @ptrCast(@alignCast(p));
        if (self.blocked) return error.Unavailable;
        return self.parent.vtable.read_size(self.parent.context, key);
    }
    fn read(p: *anyopaque, key: []const u8, destination: []u8) Store.Error!usize {
        const self: *ReadFault = @ptrCast(@alignCast(p));
        if (self.blocked) return error.Unavailable;
        return self.parent.vtable.read(self.parent.context, key, destination);
    }
    fn write(p: *anyopaque, key: []const u8, bytes: []const u8) Store.Error!void {
        const self: *ReadFault = @ptrCast(@alignCast(p));
        return self.parent.write(key, bytes);
    }
    fn delete(p: *anyopaque, key: []const u8) Store.Error!void {
        const self: *ReadFault = @ptrCast(@alignCast(p));
        return self.parent.delete(key);
    }
    fn exists(p: *anyopaque, key: []const u8) Store.Error!bool {
        const self: *ReadFault = @ptrCast(@alignCast(p));
        return self.parent.exists(key);
    }
};
