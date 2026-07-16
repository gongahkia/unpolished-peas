#include <minna_san.h>

_Static_assert(MINNA_SAN_ABI_VERSION == 1u, "ABI version");
_Static_assert(MINNA_SAN_RESULT_VERSION_MISMATCH == 11, "result code");
_Static_assert(MINNA_SAN_ERROR_CATEGORY_INTERNAL == 14, "error category");
_Static_assert(sizeof(((minna_san_address *)0)->bytes) == MINNA_SAN_ADDRESS_BYTES, "address bytes");
_Static_assert(sizeof(((minna_san_buffer *)0)->data) == sizeof(uint8_t *), "buffer pointer");

static minna_san_abi_version_t (*const abi_version_query)(void) = minna_san_abi_version;
static uint8_t (*const abi_support_query)(minna_san_abi_version_t) = minna_san_abi_supports_version;
static uint8_t (*const result_is_known_query)(int) = minna_san_result_is_known;
static minna_san_error_category (*const result_category_query)(int) = minna_san_result_category;
static const char *(*const result_message_query)(int) = minna_san_result_message;
static minna_san_result (*const sdk_validate_query)(const minna_san_sdk_config *) = minna_san_sdk_validate_config;
static minna_san_result (*const sdk_create_query)(const minna_san_sdk_config *, minna_san_sdk **) = minna_san_sdk_create;
static minna_san_result (*const sdk_start_query)(minna_san_sdk *) = minna_san_sdk_start;
static minna_san_result (*const sdk_poll_query)(minna_san_sdk *, minna_san_event *) = minna_san_sdk_poll;
static minna_san_result (*const sdk_stop_query)(minna_san_sdk *) = minna_san_sdk_stop;
static void (*const sdk_destroy_query)(minna_san_sdk *) = minna_san_sdk_destroy;
static minna_san_result (*const connection_open_query)(minna_san_sdk *, uint32_t, minna_san_connection **, minna_san_peer **) = minna_san_connection_open;
static minna_san_result (*const connection_close_query)(minna_san_sdk *, minna_san_connection *) = minna_san_connection_close;
static minna_san_result (*const connection_peer_query)(minna_san_sdk *, minna_san_connection *, minna_san_peer **) = minna_san_connection_peer;
static minna_san_result (*const connection_route_query)(minna_san_sdk *, minna_san_connection *, uint32_t *) = minna_san_connection_route_state;
static minna_san_result (*const connection_set_route_query)(minna_san_sdk *, minna_san_connection *, uint32_t) = minna_san_connection_set_route_state;
static uint32_t (*const event_kind_query)(const minna_san_event *) = minna_san_event_kind;
static uint32_t (*const event_mode_query)(const minna_san_event *) = minna_san_event_mode;
static uint64_t (*const event_sequence_query)(const minna_san_event *) = minna_san_event_sequence;
static minna_san_buffer (*const event_payload_query)(const minna_san_event *) = minna_san_event_payload;
static minna_san_result (*const channel_open_query)(minna_san_sdk *, minna_san_connection *, uint32_t, minna_san_channel **) = minna_san_channel_open;
static minna_san_result (*const channel_close_query)(minna_san_sdk *, minna_san_channel *) = minna_san_channel_close;
static minna_san_result (*const channel_mode_query)(minna_san_sdk *, minna_san_channel *, uint32_t *) = minna_san_channel_mode;
static minna_san_result (*const channel_send_query)(minna_san_sdk *, minna_san_channel *, minna_san_buffer, uint64_t *) = minna_san_channel_send;
static minna_san_result (*const channel_receive_query)(minna_san_sdk *, minna_san_channel *, minna_san_buffer *, uint64_t *) = minna_san_channel_receive;
static minna_san_result (*const channel_ack_query)(minna_san_sdk *, minna_san_channel *, uint64_t) = minna_san_channel_acknowledge;
static minna_san_result (*const channel_last_ack_query)(minna_san_sdk *, minna_san_channel *, uint64_t *) = minna_san_channel_last_acknowledged;
static minna_san_result (*const sdk_buffer_release_query)(minna_san_sdk *, minna_san_buffer) = minna_san_sdk_buffer_release;
static minna_san_result (*const security_init_query)(minna_san_security_config *) = minna_san_security_config_init;
static minna_san_result (*const security_set_psk_query)(minna_san_security_config *, minna_san_buffer) = minna_san_security_config_set_psk;
static minna_san_result (*const security_set_public_key_query)(minna_san_security_config *, minna_san_buffer) = minna_san_security_config_set_public_key;
static minna_san_result (*const security_set_aead_key_query)(minna_san_security_config *, minna_san_buffer) = minna_san_security_config_set_aead_key;
static minna_san_result (*const security_set_replay_query)(minna_san_security_config *, uint32_t) = minna_san_security_config_set_replay_window;
static minna_san_result (*const security_set_rotation_query)(minna_san_security_config *, minna_san_duration_ns, minna_san_duration_ns) = minna_san_security_config_set_key_rotation;
static minna_san_result (*const security_validate_query)(const minna_san_security_config *) = minna_san_security_config_validate;
static minna_san_result (*const session_config_init_query)(minna_san_authoritative_session_config *) = minna_san_authoritative_session_config_init;
static minna_san_result (*const session_config_validate_query)(const minna_san_authoritative_session_config *) = minna_san_authoritative_session_config_validate;
static minna_san_result (*const session_create_query)(minna_san_sdk *, const minna_san_authoritative_session_config *, minna_san_authoritative_session **) = minna_san_authoritative_session_create;
static minna_san_result (*const session_destroy_query)(minna_san_sdk *, minna_san_authoritative_session *) = minna_san_authoritative_session_destroy;
static minna_san_result (*const session_join_query)(minna_san_sdk *, minna_san_authoritative_session *, minna_san_connection *) = minna_san_authoritative_session_client_join;
static minna_san_result (*const session_leave_query)(minna_san_sdk *, minna_san_authoritative_session *, minna_san_connection *) = minna_san_authoritative_session_client_leave;
static minna_san_result (*const session_count_query)(minna_san_sdk *, minna_san_authoritative_session *, size_t *) = minna_san_authoritative_session_client_count;
static minna_san_result (*const transport_init_query)(minna_san_transport_config *) = minna_san_transport_config_init;
static minna_san_result (*const transport_set_kind_query)(minna_san_transport_config *, uint32_t) = minna_san_transport_config_set_kind;
static minna_san_result (*const transport_set_local_query)(minna_san_transport_config *, minna_san_address) = minna_san_transport_config_set_local_address;
static minna_san_result (*const transport_set_remote_query)(minna_san_transport_config *, minna_san_address) = minna_san_transport_config_set_remote_address;
static minna_san_result (*const transport_set_options_query)(minna_san_transport_config *, minna_san_socket_options) = minna_san_transport_config_set_socket_options;
static minna_san_result (*const transport_set_control_query)(minna_san_transport_config *, minna_san_transport_control) = minna_san_transport_config_set_control;
static minna_san_result (*const transport_validate_query)(const minna_san_transport_config *) = minna_san_transport_config_validate;

static void *minna_san_fixture_allocate(void *context, size_t len) {
    return len == 0 ? context : 0;
}

static void minna_san_fixture_release(void *context, uint8_t *data, size_t len) {
    (void)context;
    (void)data;
    (void)len;
}

static uint64_t minna_san_fixture_now(void *context) {
    return context == 0 ? 42u : 0u;
}

int minna_san_c_abi_types_fixture(minna_san_handle *handle, minna_san_event event) {
    const minna_san_allocator allocator = {
        .context = 0,
        .allocate = minna_san_fixture_allocate,
        .release = minna_san_fixture_release,
    };
    const minna_san_sdk_config config = {
        .abi_version = MINNA_SAN_ABI_VERSION,
        .capability_bits = MINNA_SAN_CAPABILITY_TRANSPORT,
        .connection_capacity = 2u,
        .channel_capacity = 2u,
        .clock_context = 0,
        .now = minna_san_fixture_now,
        .allocator = allocator,
    };
    const minna_san_transport_config transport = {
        .kind = MINNA_SAN_TRANSPORT_UDP,
        .local_address = { .family = MINNA_SAN_ADDRESS_FAMILY_UNSPECIFIED, .bytes = { 0 }, .port = 0 },
        .remote_address = { .family = MINNA_SAN_ADDRESS_FAMILY_UNSPECIFIED, .bytes = { 0 }, .port = 0 },
        .socket_options = { .send_buffer_bytes = 0, .receive_buffer_bytes = 0, .reuse_address = 0, .no_delay = 0, .reserved = { 0, 0 } },
        .control = { .connect_timeout_ns = 0, .idle_timeout_ns = 0, .max_datagram_bytes = 0, .max_in_flight = 0 },
    };
    const minna_san_security_config security = {
        .flags = 0,
        .psk = { .data = 0, .len = 0 },
        .public_key = { .data = 0, .len = 0 },
        .aead_key = { .data = 0, .len = 0 },
        .replay_window = 0,
        .rotation_interval_ns = 0,
        .rotation_overlap_ns = 0,
    };
    return (handle == 0 && event.payload.len == 0 && config.now != 0 && transport.kind == MINNA_SAN_TRANSPORT_UDP && security.flags == 0 && allocator.allocate != 0 && allocator.release != 0 && abi_version_query != 0 && abi_support_query != 0 && result_is_known_query != 0 && result_category_query != 0 && result_message_query != 0 && sdk_validate_query != 0 && sdk_create_query != 0 && sdk_start_query != 0 && sdk_poll_query != 0 && sdk_stop_query != 0 && sdk_destroy_query != 0 && connection_open_query != 0 && connection_close_query != 0 && connection_peer_query != 0 && connection_route_query != 0 && connection_set_route_query != 0 && event_kind_query != 0 && event_mode_query != 0 && event_sequence_query != 0 && event_payload_query != 0 && channel_open_query != 0 && channel_close_query != 0 && channel_mode_query != 0 && channel_send_query != 0 && channel_receive_query != 0 && channel_ack_query != 0 && channel_last_ack_query != 0 && sdk_buffer_release_query != 0 && security_init_query != 0 && security_set_psk_query != 0 && security_set_public_key_query != 0 && security_set_aead_key_query != 0 && security_set_replay_query != 0 && security_set_rotation_query != 0 && security_validate_query != 0 && session_config_init_query != 0 && session_config_validate_query != 0 && session_create_query != 0 && session_destroy_query != 0 && session_join_query != 0 && session_leave_query != 0 && session_count_query != 0 && transport_init_query != 0 && transport_set_kind_query != 0 && transport_set_local_query != 0 && transport_set_remote_query != 0 && transport_set_options_query != 0 && transport_set_control_query != 0 && transport_validate_query != 0) ? 0 : 1;
}
