#include <minna_san.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void *minna_san_consumer_allocate(void *context, size_t len) {
    (void)context;
    return malloc(len);
}

static void minna_san_consumer_release(void *context, uint8_t *data, size_t len) {
    (void)context;
    (void)len;
    free(data);
}

static uint64_t minna_san_consumer_now(void *context) {
    (void)context;
    return 42u;
}

static minna_san_address minna_san_consumer_loopback(uint16_t port) {
    return (minna_san_address){
        .family = MINNA_SAN_ADDRESS_FAMILY_IPV4,
        .bytes = {127u, 0u, 0u, 1u},
        .port = port,
    };
}

static int minna_san_consumer_native_udp_exchange(const minna_san_sdk_config *config) {
    const uint8_t payload[] = {'u', 'd', 'p'};
    const minna_san_native_udp_config temporary = {
        .local_address = minna_san_consumer_loopback(0u),
        .peer_address = minna_san_consumer_loopback(1u),
        .maximum_payload_bytes = 32u,
        .maximum_in_flight = 4u,
    };
    minna_san_native_runtime *first_runtime = 0;
    minna_san_native_runtime *second_runtime = 0;
    minna_san_native_session *temporary_session = 0;
    minna_san_native_channel *temporary_channel = 0;
    minna_san_native_session *first_session = 0;
    minna_san_native_channel *first_channel = 0;
    minna_san_native_session *second_session = 0;
    minna_san_native_channel *second_channel = 0;
    minna_san_native_channel *received_channel = 0;
    minna_san_address second_local;
    minna_san_address first_local;
    minna_san_buffer received = { .data = 0, .len = 0u };
    size_t sent = 0u;
    size_t attempts = 0u;
    int received_result = MINNA_SAN_RESULT_WOULD_BLOCK;
    if (minna_san_native_udp_config_validate(&temporary) != MINNA_SAN_RESULT_OK) return 30;
    if (minna_san_native_runtime_create(config, &first_runtime) != MINNA_SAN_RESULT_OK) return 31;
    if (minna_san_native_runtime_create(config, &second_runtime) != MINNA_SAN_RESULT_OK) return 32;
    if (minna_san_native_udp_dial(second_runtime, &temporary, &temporary_session, &temporary_channel) != MINNA_SAN_RESULT_OK) return 33;
    if (minna_san_native_udp_session_address(second_runtime, temporary_session, &second_local) != MINNA_SAN_RESULT_OK) return 34;
    if (second_local.family != MINNA_SAN_ADDRESS_FAMILY_IPV4 || second_local.port == 0u) return 35;
    if (minna_san_native_udp_session_close(second_runtime, temporary_session) != MINNA_SAN_RESULT_OK) return 36;
    const minna_san_native_udp_config first_config = {
        .local_address = minna_san_consumer_loopback(0u),
        .peer_address = second_local,
        .maximum_payload_bytes = 32u,
        .maximum_in_flight = 4u,
    };
    if (minna_san_native_udp_dial(first_runtime, &first_config, &first_session, &first_channel) != MINNA_SAN_RESULT_OK) return 37;
    if (minna_san_native_udp_session_address(first_runtime, first_session, &first_local) != MINNA_SAN_RESULT_OK) return 38;
    const minna_san_native_udp_config second_config = {
        .local_address = second_local,
        .peer_address = first_local,
        .maximum_payload_bytes = 32u,
        .maximum_in_flight = 4u,
    };
    if (minna_san_native_udp_dial(second_runtime, &second_config, &second_session, &second_channel) != MINNA_SAN_RESULT_OK) return 39;
    if (minna_san_native_udp_poll(first_runtime, first_session, &first_channel) != MINNA_SAN_RESULT_OK) return 40;
    if (minna_san_native_channel_send(first_runtime, first_channel, (minna_san_const_buffer){ .data = payload, .len = sizeof(payload) }) != MINNA_SAN_RESULT_OK) return 41;
    if (minna_san_native_udp_flush(first_runtime, first_session, &sent) != MINNA_SAN_RESULT_OK || sent != 1u) return 42;
    for (attempts = 0u; attempts < 10000u; ++attempts) {
        received_result = minna_san_native_udp_receive(second_runtime, second_session, &received_channel, &received);
        if (received_result != MINNA_SAN_RESULT_WOULD_BLOCK) break;
    }
    if (received_result != MINNA_SAN_RESULT_OK) return 43;
    if (received_channel != second_channel || received.len != sizeof(payload) || memcmp(received.data, payload, sizeof(payload)) != 0) return 44;
    if (minna_san_native_buffer_release(second_runtime, received) != MINNA_SAN_RESULT_OK) return 45;
    if (minna_san_native_udp_session_close(first_runtime, first_session) != MINNA_SAN_RESULT_OK) return 46;
    if (minna_san_native_udp_session_close(second_runtime, second_session) != MINNA_SAN_RESULT_OK) return 47;
    minna_san_native_runtime_destroy(second_runtime);
    minna_san_native_runtime_destroy(first_runtime);
    return 0;
}

static int minna_san_consumer_p2p_exchange(minna_san_sdk *sdk) {
    const uint8_t signaling[] = {'s', 'i', 'g'};
    const minna_san_candidate first_candidate = {
        .kind = MINNA_SAN_CANDIDATE_HOST,
        .address = { .family = MINNA_SAN_ADDRESS_FAMILY_IPV4, .bytes = {127u, 0u, 0u, 1u}, .port = 4000u },
        .priority = 10u,
        .expires_at_ns = 100u,
    };
    const minna_san_candidate second_candidate = {
        .kind = MINNA_SAN_CANDIDATE_SERVER_REFLEXIVE,
        .address = { .family = MINNA_SAN_ADDRESS_FAMILY_IPV4, .bytes = {127u, 0u, 0u, 1u}, .port = 5000u },
        .priority = 20u,
        .expires_at_ns = 100u,
    };
    minna_san_p2p_session *first = 0;
    minna_san_p2p_session *second = 0;
    minna_san_candidate copied = {0};
    minna_san_buffer copied_signal = { .data = 0, .len = 0u };
    uint32_t route = 0u;
    if (minna_san_p2p_session_create(sdk, first_candidate, &first) != MINNA_SAN_RESULT_OK) return 60;
    if (minna_san_p2p_session_create(sdk, second_candidate, &second) != MINNA_SAN_RESULT_OK) return 61;
    if (minna_san_p2p_session_set_candidate(sdk, first, second_candidate) != MINNA_SAN_RESULT_OK) return 62;
    if (minna_san_p2p_session_candidate(sdk, first, &copied) != MINNA_SAN_RESULT_OK || copied.address.port != second_candidate.address.port) return 63;
    if (minna_san_p2p_session_copy_signaling(sdk, first, (minna_san_const_buffer){ .data = signaling, .len = sizeof(signaling) }, &copied_signal) != MINNA_SAN_RESULT_OK) return 64;
    if (copied_signal.len != sizeof(signaling) || memcmp(copied_signal.data, signaling, sizeof(signaling)) != 0) return 65;
    if (minna_san_sdk_buffer_release(sdk, copied_signal) != MINNA_SAN_RESULT_OK) return 66;
    if (minna_san_p2p_session_route_state(sdk, first, &route) != MINNA_SAN_RESULT_OK || route != MINNA_SAN_ROUTE_DIRECT) return 67;
    if (minna_san_p2p_session_fallback_relay(sdk, first) != MINNA_SAN_RESULT_OK) return 68;
    if (minna_san_p2p_session_route_state(sdk, first, &route) != MINNA_SAN_RESULT_OK || route != MINNA_SAN_ROUTE_RELAY) return 69;
    if (minna_san_p2p_session_destroy(sdk, second) != MINNA_SAN_RESULT_OK) return 70;
    if (minna_san_p2p_session_destroy(sdk, first) != MINNA_SAN_RESULT_OK) return 71;
    return 0;
}

typedef struct minna_san_consumer_tls_fixture {
    uint8_t saw_request;
} minna_san_consumer_tls_fixture;

static void minna_san_consumer_tls_begin(void *context, const minna_san_tls_certificate_request *request) {
    minna_san_consumer_tls_fixture *fixture = context;
    if (request->kind == 1u && request->peer_certificate_chain_id == 9u && request->has_peer_certificate_chain_id == 1u && request->server_name.len == sizeof("fixture.test") - 1u && memcmp(request->server_name.data, "fixture.test", request->server_name.len) == 0) fixture->saw_request = 1u;
}

static uint32_t minna_san_consumer_tls_poll(void *context, uint64_t request_id) {
    (void)context;
    return request_id == 0u ? MINNA_SAN_TLS_CERTIFICATE_PENDING : MINNA_SAN_TLS_CERTIFICATE_ACCEPT;
}

static int minna_san_consumer_http_websocket_exchange(minna_san_sdk *sdk) {
    static const uint8_t method[] = {'G', 'E', 'T'};
    static const uint8_t target[] = {'/', 'f', 'i', 'x', 't', 'u', 'r', 'e'};
    static const uint8_t authority[] = {'f', 'i', 'x', 't', 'u', 'r', 'e', '.', 't', 'e', 's', 't'};
    static const uint8_t response_bytes[] = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok";
    static const uint8_t stream_input[] = {'o', 'k'};
    static const uint8_t websocket_uri[] = "wss://fixture.test/socket";
    static const uint8_t websocket_subprotocol[] = "chat";
    const minna_san_http_request request = {
        .method = { .data = method, .len = sizeof(method) },
        .target = { .data = target, .len = sizeof(target) },
        .authority = { .data = authority, .len = sizeof(authority) },
        .headers = 0,
        .header_count = 0u,
        .body = { .data = 0, .len = 0u },
        .close_after_response = 0u,
        .reserved = {0},
    };
    minna_san_http_client *http = 0;
    minna_san_http_stream *stream = 0;
    minna_san_tls_certificate_registry *tls = 0;
    minna_san_websocket_client *websocket = 0;
    uint8_t wire[512];
    uint8_t stream_wire[32];
    uint8_t accept[64];
    uint8_t message[8];
    char handshake[256];
    size_t wire_len = 0u;
    size_t consumed = 0u;
    size_t accepted = 0u;
    size_t pending = 0u;
    size_t stream_len = 0u;
    size_t accept_len = 0u;
    size_t message_len = 0u;
    uint8_t complete = 0u;
    uint8_t closed = 0u;
    uint64_t certificate_id = 0u;
    uint64_t resolved_id = 0u;
    uint32_t decision = MINNA_SAN_TLS_CERTIFICATE_PENDING;
    minna_san_http_response response = {0};
    minna_san_consumer_tls_fixture tls_fixture = {0};
    const minna_san_tls_certificate_callbacks callbacks = {
        .context = &tls_fixture,
        .begin = minna_san_consumer_tls_begin,
        .poll = minna_san_consumer_tls_poll,
        .maximum_pending = 1u,
    };
    const minna_san_websocket_client_config websocket_config = {
        .uri = { .data = websocket_uri, .len = sizeof(websocket_uri) - 1u },
        .subprotocol = { .data = websocket_subprotocol, .len = sizeof(websocket_subprotocol) - 1u },
        .maximum_message_bytes = sizeof(message),
        .maximum_in_flight_messages = 1u,
    };
    if (minna_san_http_client_create(sdk, &http) != MINNA_SAN_RESULT_OK) return 80;
    if (minna_san_http_client_begin(http, &request, (minna_san_buffer){ .data = wire, .len = sizeof(wire) }, &wire_len) != MINNA_SAN_RESULT_OK || wire_len == 0u) return 81;
    if (minna_san_http_client_feed(http, (minna_san_const_buffer){ .data = response_bytes, .len = sizeof(response_bytes) - 1u }, &consumed, &complete) != MINNA_SAN_RESULT_OK || consumed != sizeof(response_bytes) - 1u || complete != 1u) return 82;
    if (minna_san_http_client_response(http, &response) != MINNA_SAN_RESULT_OK || response.status != 200u || response.body.len != 2u || memcmp(response.body.data, "ok", 2u) != 0) return 83;
    if (minna_san_http_client_destroy(sdk, http) != MINNA_SAN_RESULT_OK) return 84;
    if (minna_san_http_stream_create(sdk, sizeof(stream_wire), sizeof(stream_input), &stream) != MINNA_SAN_RESULT_OK) return 85;
    if (minna_san_http_stream_write(stream, (minna_san_const_buffer){ .data = stream_input, .len = sizeof(stream_input) }, &accepted, &pending) != MINNA_SAN_RESULT_OK || accepted != sizeof(stream_input) || pending == 0u) return 86;
    if (minna_san_http_stream_pending(stream, (minna_san_buffer){ .data = stream_wire, .len = sizeof(stream_wire) }, &stream_len) != MINNA_SAN_RESULT_OK || stream_len != pending || memcmp(stream_wire, "2\r\nok\r\n", stream_len) != 0) return 87;
    if (minna_san_http_stream_consume(stream, stream_len, &closed) != MINNA_SAN_RESULT_OK || closed != 0u) return 88;
    if (minna_san_http_stream_finish(stream, &pending) != MINNA_SAN_RESULT_OK || pending != 5u) return 89;
    if (minna_san_http_stream_consume(stream, pending, &closed) != MINNA_SAN_RESULT_OK || closed != 1u) return 90;
    if (minna_san_http_stream_destroy(sdk, stream) != MINNA_SAN_RESULT_OK) return 91;
    if (minna_san_tls_certificate_registry_create(sdk, &callbacks, &tls) != MINNA_SAN_RESULT_OK) return 92;
    if (minna_san_tls_certificate_client_trust_begin(tls, (minna_san_const_buffer){ .data = authority, .len = sizeof(authority) }, 9u, 0, 10, &certificate_id) != MINNA_SAN_RESULT_OK || certificate_id == 0u || tls_fixture.saw_request != 1u) return 93;
    if (minna_san_tls_certificate_registry_poll(tls, 1, &resolved_id, &decision) != MINNA_SAN_RESULT_OK || resolved_id != certificate_id || decision != MINNA_SAN_TLS_CERTIFICATE_ACCEPT) return 94;
    if (minna_san_tls_certificate_registry_destroy(sdk, tls) != MINNA_SAN_RESULT_OK) return 95;
    if (minna_san_websocket_client_create(sdk, &websocket_config, &websocket) != MINNA_SAN_RESULT_OK) return 96;
    if (minna_san_websocket_client_begin(websocket, (minna_san_buffer){ .data = wire, .len = sizeof(wire) }, &wire_len) != MINNA_SAN_RESULT_OK || wire_len == 0u) return 97;
    if (minna_san_websocket_client_expected_accept(websocket, (minna_san_buffer){ .data = accept, .len = sizeof(accept) }, &accept_len) != MINNA_SAN_RESULT_OK || accept_len == 0u) return 98;
    const int handshake_len = snprintf(handshake, sizeof(handshake), "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %.*s\r\nSec-WebSocket-Protocol: chat\r\n\r\n", (int)accept_len, (const char *)accept);
    if (handshake_len <= 0 || (size_t)handshake_len >= sizeof(handshake)) return 99;
    if (minna_san_websocket_client_feed(websocket, (minna_san_const_buffer){ .data = (const uint8_t *)handshake, .len = (size_t)handshake_len }, &consumed, &complete) != MINNA_SAN_RESULT_OK || consumed != (size_t)handshake_len || complete != 1u) return 100;
    const uint8_t frame[] = {0x82u, 0x02u, 0x01u, 0x02u};
    if (minna_san_websocket_client_feed(websocket, (minna_san_const_buffer){ .data = frame, .len = sizeof(frame) }, &consumed, &complete) != MINNA_SAN_RESULT_OK || consumed != sizeof(frame)) return 101;
    if (minna_san_websocket_client_receive(websocket, (minna_san_buffer){ .data = message, .len = sizeof(message) }, &message_len) != MINNA_SAN_RESULT_OK || message_len != 2u || message[0] != 1u || message[1] != 2u) return 102;
    if (minna_san_websocket_client_destroy(sdk, websocket) != MINNA_SAN_RESULT_OK) return 103;
    return 0;
}

int c_abi_consumer_main(void) {
    minna_san_platform_config platform_config;
    const minna_san_allocator allocator = {
        .context = 0,
        .allocate = minna_san_consumer_allocate,
        .release = minna_san_consumer_release,
    };
    if (minna_san_platform_config_init(&platform_config) != MINNA_SAN_RESULT_OK) return 1;
    const minna_san_sdk_config config = {
        .abi_version = MINNA_SAN_ABI_VERSION,
        .capability_bits = MINNA_SAN_CAPABILITY_TRANSPORT,
        .connection_capacity = 2u,
        .channel_capacity = 1u,
        .platform_config = platform_config,
        .clock_context = 0,
        .now = minna_san_consumer_now,
        .allocator = allocator,
    };
    minna_san_sdk *sdk = 0;
    minna_san_event event;
    minna_san_metrics_snapshot metrics;
    minna_san_runtime_metrics_snapshot runtime_metrics;
    const char ipv6_expanded[] = "2001:0DB8:0:0:0:0:0:1";
    const char ipv6_short[] = "[2001:db8::1]";
    const char dns_mixed[] = "Api.Example.COM.";
    const char dns_canonical[] = "api.example.com";
    uint8_t endpoint_text[MINNA_SAN_ENDPOINT_HOSTNAME_MAX_BYTES];
    size_t endpoint_text_len = 0u;
    minna_san_endpoint first_endpoint;
    minna_san_endpoint second_endpoint;

    if (minna_san_abi_version() != MINNA_SAN_ABI_VERSION) return 2;
    if (minna_san_abi_supports_version(MINNA_SAN_ABI_VERSION) != 1u) return 3;
    if (minna_san_result_category(MINNA_SAN_RESULT_VERSION_MISMATCH) != MINNA_SAN_ERROR_CATEGORY_VERSION_MISMATCH) return 4;
    if (minna_san_result_retryability(MINNA_SAN_RESULT_TRANSPORT_FAILURE) != MINNA_SAN_RETRY_BACKOFF) return 15;
    if (minna_san_result_operator_category(MINNA_SAN_RESULT_TRANSPORT_FAILURE) != MINNA_SAN_OPERATOR_TRANSPORT) return 16;
    if (minna_san_endpoint_parse((minna_san_const_buffer){ .data = (const uint8_t *)ipv6_expanded, .len = sizeof(ipv6_expanded) - 1u }, 443u, &first_endpoint) != MINNA_SAN_RESULT_OK) return 17;
    if (minna_san_endpoint_parse((minna_san_const_buffer){ .data = (const uint8_t *)ipv6_short, .len = sizeof(ipv6_short) - 1u }, 443u, &second_endpoint) != MINNA_SAN_RESULT_OK) return 18;
    if (minna_san_endpoint_equal(&first_endpoint, &second_endpoint) != 1u) return 19;
    if (minna_san_endpoint_format(&first_endpoint, (minna_san_buffer){ .data = endpoint_text, .len = sizeof(endpoint_text) }, &endpoint_text_len) != MINNA_SAN_RESULT_OK) return 20;
    if (endpoint_text_len != sizeof("2001:db8::1") - 1u) return 21;
    if (minna_san_endpoint_parse((minna_san_const_buffer){ .data = (const uint8_t *)dns_mixed, .len = sizeof(dns_mixed) - 1u }, 443u, &first_endpoint) != MINNA_SAN_RESULT_OK) return 22;
    if (minna_san_endpoint_parse((minna_san_const_buffer){ .data = (const uint8_t *)dns_canonical, .len = sizeof(dns_canonical) - 1u }, 443u, &second_endpoint) != MINNA_SAN_RESULT_OK) return 23;
    if (minna_san_endpoint_equal(&first_endpoint, &second_endpoint) != 1u) return 24;
    if (minna_san_endpoint_format(&first_endpoint, (minna_san_buffer){ .data = endpoint_text, .len = sizeof(endpoint_text) }, &endpoint_text_len) != MINNA_SAN_RESULT_OK) return 25;
    if (endpoint_text_len != sizeof("api.example.com") - 1u) return 26;
    if (minna_san_platform_config_validate(&platform_config) != MINNA_SAN_RESULT_OK) return 5;
    if (minna_san_sdk_validate_config(&config) != MINNA_SAN_RESULT_OK) return 6;
    if (minna_san_sdk_create(&config, &sdk) != MINNA_SAN_RESULT_OK) return 7;
    if (minna_san_sdk_start(sdk) != MINNA_SAN_RESULT_OK) return 8;
    const int http_websocket_result = minna_san_consumer_http_websocket_exchange(sdk);
    if (http_websocket_result != 0) return http_websocket_result;
    if (minna_san_consumer_p2p_exchange(sdk) != 0) return 59;
    if (minna_san_sdk_poll(sdk, &event) != MINNA_SAN_RESULT_WOULD_BLOCK) return 9;
    if (minna_san_sdk_metrics_snapshot(sdk, &metrics) != MINNA_SAN_RESULT_OK) return 10;
    if (metrics.polls != 1u || metrics.active_connections != 0u) return 11;
    if (minna_san_sdk_runtime_metrics_snapshot(sdk, &runtime_metrics) != MINNA_SAN_RESULT_OK) return 12;
    if (runtime_metrics.polls != 1u || runtime_metrics.events != 0u) return 13;
    if (minna_san_sdk_stop(sdk) != MINNA_SAN_RESULT_OK) return 14;
    minna_san_sdk_destroy(sdk);
    if (minna_san_consumer_native_udp_exchange(&config) != 0) return 48;
    return 0;
}
