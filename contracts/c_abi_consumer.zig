extern fn c_abi_consumer_main() c_int;

pub fn main() void {
    if (c_abi_consumer_main() != 0) @panic("C ABI conformance consumer failed");
}
