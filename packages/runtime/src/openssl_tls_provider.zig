const core = @import("minna-san-core");
const tls = @import("tls_provider.zig");

pub const OpenSslTlsConfig = struct {
    tls: tls.TlsProviderConfig,
    certificate_path: ?[:0]const u8 = null,
    private_key_path: ?[:0]const u8 = null,
    trust_store_path: ?[:0]const u8 = null,

    pub fn validate(self: OpenSslTlsConfig) tls.TlsProviderError!void {
        try self.tls.validate();
        if (self.tls.role == .server and (self.certificate_path == null or self.private_key_path == null)) return error.InvalidConfiguration;
        if (self.tls.role == .client and self.trust_store_path == null) return error.InvalidConfiguration;
    }
};

pub const OpenSslTlsProvider = struct {
    provider: tls.TlsProvider,

    pub fn init(config: OpenSslTlsConfig) tls.TlsProviderError!OpenSslTlsProvider {
        try config.validate();
        const context = minna_openssl_tls_create(
            @intFromEnum(config.tls.role),
            config.tls.alpn.ptr,
            config.tls.alpn.len,
            config.tls.server_name.ptr,
            config.tls.server_name.len,
            if (config.certificate_path) |value| value.ptr else null,
            if (config.private_key_path) |value| value.ptr else null,
            if (config.trust_store_path) |value| value.ptr else null,
        ) orelse return error.ProviderFailed;
        errdefer minna_openssl_tls_destroy(context);
        return .{ .provider = try tls.TlsProvider.init(config.tls, context, .{
            .start = start,
            .poll = poll,
            .encrypt = encrypt,
            .decrypt = decrypt,
            .receive_record = receiveRecord,
            .drain_record = drainRecord,
            .teardown = teardown,
        }) };
    }

    pub fn deinit(self: *OpenSslTlsProvider) void {
        self.provider.close();
        self.* = undefined;
    }

    pub fn selectedAlpn(self: *const OpenSslTlsProvider, output: []u8) tls.TlsProviderError![]u8 {
        var result = tls.TlsRecordOutput{};
        if (minna_openssl_tls_selected_alpn(self.provider.context, output.ptr, output.len, &result) != @intFromEnum(core.CResult.ok) or result.bytes > output.len) return error.ProviderFailed;
        return output[0..result.bytes];
    }

    fn start(context: ?*anyopaque, _: u8, _: [*]const u8, _: usize, _: [*]const u8, _: usize, _: ?*anyopaque, _: ?tls.TlsCertificateCallback) callconv(.c) c_int {
        return minna_openssl_tls_start(context);
    }

    fn poll(context: ?*anyopaque, _: core.TimeNs, output: *tls.TlsPollOutput) callconv(.c) c_int {
        return minna_openssl_tls_poll(context, output);
    }

    fn encrypt(context: ?*anyopaque, input: [*]const u8, input_len: usize, output: [*]u8, output_len: usize, result: *tls.TlsIoOutput) callconv(.c) c_int {
        return minna_openssl_tls_encrypt(context, input, input_len, output, output_len, result);
    }

    fn decrypt(context: ?*anyopaque, input: [*]const u8, input_len: usize, output: [*]u8, output_len: usize, result: *tls.TlsIoOutput) callconv(.c) c_int {
        return minna_openssl_tls_decrypt(context, input, input_len, output, output_len, result);
    }

    fn receiveRecord(context: ?*anyopaque, input: [*]const u8, input_len: usize, result: *tls.TlsRecordOutput) callconv(.c) c_int {
        return minna_openssl_tls_receive_record(context, input, input_len, result);
    }

    fn drainRecord(context: ?*anyopaque, output: [*]u8, output_len: usize, result: *tls.TlsRecordOutput) callconv(.c) c_int {
        return minna_openssl_tls_drain_record(context, output, output_len, result);
    }

    fn teardown(context: ?*anyopaque) callconv(.c) void {
        minna_openssl_tls_destroy(context);
    }
};

extern fn minna_openssl_tls_create(role: u8, alpn: [*]const u8, alpn_len: usize, server_name: [*]const u8, server_name_len: usize, certificate_path: ?[*:0]const u8, private_key_path: ?[*:0]const u8, trust_store_path: ?[*:0]const u8) ?*anyopaque;
extern fn minna_openssl_tls_destroy(context: ?*anyopaque) void;
extern fn minna_openssl_tls_start(context: ?*anyopaque) c_int;
extern fn minna_openssl_tls_poll(context: ?*anyopaque, output: *tls.TlsPollOutput) c_int;
extern fn minna_openssl_tls_encrypt(context: ?*anyopaque, input: [*]const u8, input_len: usize, output: [*]u8, output_len: usize, result: *tls.TlsIoOutput) c_int;
extern fn minna_openssl_tls_decrypt(context: ?*anyopaque, input: [*]const u8, input_len: usize, output: [*]u8, output_len: usize, result: *tls.TlsIoOutput) c_int;
extern fn minna_openssl_tls_receive_record(context: ?*anyopaque, input: [*]const u8, input_len: usize, result: *tls.TlsRecordOutput) c_int;
extern fn minna_openssl_tls_drain_record(context: ?*anyopaque, output: [*]u8, output_len: usize, result: *tls.TlsRecordOutput) c_int;
extern fn minna_openssl_tls_selected_alpn(context: ?*anyopaque, output: [*]u8, output_len: usize, result: *tls.TlsRecordOutput) c_int;
