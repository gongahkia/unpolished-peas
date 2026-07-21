#ifndef MINNA_SAN_H
#define MINNA_SAN_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MINNA_SAN_ABI_VERSION 1u
#define MINNA_SAN_PLATFORM_CONFIG_VERSION 1u
#define MINNA_SAN_ADDRESS_BYTES 16u
#define MINNA_SAN_ADDRESS_FAMILY_UNSPECIFIED 0u
#define MINNA_SAN_ADDRESS_FAMILY_IPV4 4u
#define MINNA_SAN_ADDRESS_FAMILY_IPV6 6u
#define MINNA_SAN_ENDPOINT_HOSTNAME_MAX_BYTES 253u
#define MINNA_SAN_ENDPOINT_IPV4 1u
#define MINNA_SAN_ENDPOINT_IPV6 2u
#define MINNA_SAN_ENDPOINT_DNS 3u
#define MINNA_SAN_ENDPOINT_PROVIDER 4u
#define MINNA_SAN_EVENT_CONNECTED 1u
#define MINNA_SAN_EVENT_DISCONNECTED 2u
#define MINNA_SAN_EVENT_MESSAGE 3u
#define MINNA_SAN_EVENT_OVERFLOW 4u
#define MINNA_SAN_CAPABILITY_TRANSPORT 1u
#define MINNA_SAN_CAPABILITY_PACKET_PROTECTION 2u
#define MINNA_SAN_CAPABILITY_TOPOLOGY 4u
#define MINNA_SAN_CAPABILITY_STATE_REPLICATION 8u
#define MINNA_SAN_CAPABILITY_CAPTURE 16u
#define MINNA_SAN_TRANSPORT_UDP 1u
#define MINNA_SAN_TRANSPORT_TCP 2u
#define MINNA_SAN_ROUTE_DIRECT 1u
#define MINNA_SAN_ROUTE_RELAY 2u
#define MINNA_SAN_CHANNEL_RELIABLE 1u
#define MINNA_SAN_CHANNEL_SEQUENCED 2u
#define MINNA_SAN_SECURITY_PSK 1u
#define MINNA_SAN_SECURITY_PUBLIC_KEY 2u
#define MINNA_SAN_SECURITY_AEAD 4u
#define MINNA_SAN_SECURITY_REPLAY_PROTECTION 8u
#define MINNA_SAN_SECURITY_KEY_ROTATION 16u
#define MINNA_SAN_ADMISSION_ACCEPT 1u
#define MINNA_SAN_ADMISSION_REJECT 2u
#define MINNA_SAN_SESSION_IDLE 0u
#define MINNA_SAN_SESSION_ESTABLISHING 1u
#define MINNA_SAN_SESSION_READY 2u
#define MINNA_SAN_SESSION_DRAINING 3u
#define MINNA_SAN_SESSION_CLOSED 4u
#define MINNA_SAN_SESSION_TRANSITION_BEGIN_ESTABLISHING 0u
#define MINNA_SAN_SESSION_TRANSITION_MARK_READY 1u
#define MINNA_SAN_SESSION_TRANSITION_BEGIN_DRAINING 2u
#define MINNA_SAN_SESSION_TRANSITION_CLOSE 3u
#define MINNA_SAN_CANDIDATE_HOST 1u
#define MINNA_SAN_CANDIDATE_SERVER_REFLEXIVE 2u
#define MINNA_SAN_CANDIDATE_RELAY 3u
#define MINNA_SAN_ROUTE_POLICY_DIRECT_FIRST 1u
#define MINNA_SAN_ROUTE_POLICY_RELAY_FIRST 2u
#define MINNA_SAN_ROUTE_POLICY_AUTHORITATIVE_FIRST 3u
#define MINNA_SAN_CONNECTIVITY_CONTROLLING 1u
#define MINNA_SAN_CONNECTIVITY_CONTROLLED 2u
#define MINNA_SAN_REPLICATION_AUTHORITATIVE 1u
#define MINNA_SAN_REPLICATION_CLIENT_PREDICTION 2u
#define MINNA_SAN_REPLICATION_RECONCILIATION 3u
#define MINNA_SAN_LOG_TRACE 1u
#define MINNA_SAN_LOG_DEBUG 2u
#define MINNA_SAN_LOG_INFO 3u
#define MINNA_SAN_LOG_WARNING 4u
#define MINNA_SAN_LOG_ERROR 5u
#define MINNA_SAN_LOG_CATEGORY_RUNTIME 1u
#define MINNA_SAN_LOG_CATEGORY_CONNECTION 2u
#define MINNA_SAN_LOG_CATEGORY_MESSAGE 3u
#define MINNA_SAN_LOG_CATEGORY_QUEUE 4u
#define MINNA_SAN_LOG_CATEGORY_SECURITY 5u
#define MINNA_SAN_LOG_CATEGORY_REPLAY 6u
#define MINNA_SAN_LOG_REDACTION_NONE 0u
#define MINNA_SAN_LOG_REDACTION_PAYLOAD 1u
#define MINNA_SAN_LOG_REDACTION_METADATA 2u
#define MINNA_SAN_LOG_REDACTION_ALL 3u
#define MINNA_SAN_ROUTE_HEALTH_HEALTHY 0u
#define MINNA_SAN_ROUTE_HEALTH_DEGRADED 1u
#define MINNA_SAN_ROUTE_HEALTH_UNAVAILABLE 2u
#define MINNA_SAN_SECURITY_EVENT_COUNT 4u
#define MINNA_SAN_TLS_CERTIFICATE_PENDING 0u
#define MINNA_SAN_TLS_CERTIFICATE_ACCEPT 1u
#define MINNA_SAN_TLS_CERTIFICATE_REJECT 2u

typedef uint32_t minna_san_abi_version_t;
typedef int64_t minna_san_duration_ns;
typedef struct minna_san_handle minna_san_handle;
typedef enum minna_san_result {
    MINNA_SAN_RESULT_OK = 0,
    MINNA_SAN_RESULT_INVALID_ARGUMENT = 1,
    MINNA_SAN_RESULT_INVALID_STATE = 2,
    MINNA_SAN_RESULT_UNSUPPORTED = 3,
    MINNA_SAN_RESULT_RESOURCE_EXHAUSTED = 4,
    MINNA_SAN_RESULT_TIMEOUT = 5,
    MINNA_SAN_RESULT_CANCELLED = 6,
    MINNA_SAN_RESULT_WOULD_BLOCK = 7,
    MINNA_SAN_RESULT_AUTHENTICATION_FAILED = 8,
    MINNA_SAN_RESULT_PERMISSION_DENIED = 9,
    MINNA_SAN_RESULT_PROTOCOL_VIOLATION = 10,
    MINNA_SAN_RESULT_VERSION_MISMATCH = 11,
    MINNA_SAN_RESULT_INTEGRITY_FAILED = 12,
    MINNA_SAN_RESULT_TRANSPORT_FAILURE = 13,
    MINNA_SAN_RESULT_INTERNAL = 14,
} minna_san_result;
typedef enum minna_san_error_category {
    MINNA_SAN_ERROR_CATEGORY_OK = 0,
    MINNA_SAN_ERROR_CATEGORY_INVALID_ARGUMENT = 1,
    MINNA_SAN_ERROR_CATEGORY_INVALID_STATE = 2,
    MINNA_SAN_ERROR_CATEGORY_UNSUPPORTED = 3,
    MINNA_SAN_ERROR_CATEGORY_RESOURCE_EXHAUSTED = 4,
    MINNA_SAN_ERROR_CATEGORY_TIMEOUT = 5,
    MINNA_SAN_ERROR_CATEGORY_CANCELLED = 6,
    MINNA_SAN_ERROR_CATEGORY_WOULD_BLOCK = 7,
    MINNA_SAN_ERROR_CATEGORY_AUTHENTICATION_FAILED = 8,
    MINNA_SAN_ERROR_CATEGORY_PERMISSION_DENIED = 9,
    MINNA_SAN_ERROR_CATEGORY_PROTOCOL_VIOLATION = 10,
    MINNA_SAN_ERROR_CATEGORY_VERSION_MISMATCH = 11,
    MINNA_SAN_ERROR_CATEGORY_INTEGRITY_FAILED = 12,
    MINNA_SAN_ERROR_CATEGORY_TRANSPORT_FAILURE = 13,
    MINNA_SAN_ERROR_CATEGORY_INTERNAL = 14,
} minna_san_error_category;
typedef enum minna_san_retryability {
    MINNA_SAN_RETRY_NEVER = 0,
    MINNA_SAN_RETRY_IMMEDIATE = 1,
    MINNA_SAN_RETRY_BACKOFF = 2,
} minna_san_retryability;
typedef enum minna_san_operator_category {
    MINNA_SAN_OPERATOR_NONE = 0,
    MINNA_SAN_OPERATOR_CALLER = 1,
    MINNA_SAN_OPERATOR_LIFECYCLE = 2,
    MINNA_SAN_OPERATOR_CAPABILITY = 3,
    MINNA_SAN_OPERATOR_CAPACITY = 4,
    MINNA_SAN_OPERATOR_SCHEDULING = 5,
    MINNA_SAN_OPERATOR_AUTHENTICATION = 6,
    MINNA_SAN_OPERATOR_AUTHORIZATION = 7,
    MINNA_SAN_OPERATOR_PROTOCOL = 8,
    MINNA_SAN_OPERATOR_INTEGRITY = 9,
    MINNA_SAN_OPERATOR_TRANSPORT = 10,
    MINNA_SAN_OPERATOR_INTERNAL = 11,
} minna_san_operator_category;
typedef struct minna_san_version {
    uint16_t major;
    uint16_t minor;
    uint16_t patch;
} minna_san_version;
typedef struct minna_san_address {
    uint8_t family;
    uint8_t bytes[MINNA_SAN_ADDRESS_BYTES];
    uint16_t port;
} minna_san_address;
typedef struct minna_san_endpoint {
    uint32_t kind;
    uint16_t port;
    uint16_t name_len;
    uint32_t scope_id;
    uint8_t address[MINNA_SAN_ADDRESS_BYTES];
    uint8_t name[MINNA_SAN_ENDPOINT_HOSTNAME_MAX_BYTES];
} minna_san_endpoint;
typedef struct minna_san_buffer {
    uint8_t *data;
    size_t len;
} minna_san_buffer;
typedef struct minna_san_const_buffer {
    const uint8_t *data;
    size_t len;
} minna_san_const_buffer;
typedef void *(*minna_san_allocate_fn)(void *context, size_t len);
typedef void (*minna_san_release_fn)(void *context, uint8_t *data, size_t len);
typedef struct minna_san_allocator {
    void *context;
    minna_san_allocate_fn allocate;
    minna_san_release_fn release;
} minna_san_allocator;
typedef struct minna_san_event {
    uint32_t kind;
    uint32_t mode;
    uint64_t sequence;
    minna_san_buffer payload;
} minna_san_event;
typedef uint64_t (*minna_san_now_fn)(void *context);
typedef struct minna_san_sdk minna_san_sdk;
typedef struct minna_san_connection minna_san_connection;
typedef struct minna_san_peer minna_san_peer;
typedef struct minna_san_channel minna_san_channel;
typedef struct minna_san_authoritative_session minna_san_authoritative_session;
typedef struct minna_san_p2p_session minna_san_p2p_session;
typedef struct minna_san_native_runtime minna_san_native_runtime;
typedef struct minna_san_native_session minna_san_native_session;
typedef struct minna_san_native_channel minna_san_native_channel;
typedef struct minna_san_http_client minna_san_http_client;
typedef struct minna_san_http_stream minna_san_http_stream;
typedef struct minna_san_tls_certificate_registry minna_san_tls_certificate_registry;
typedef struct minna_san_websocket_client minna_san_websocket_client;
typedef struct minna_san_http_header {
    minna_san_const_buffer name;
    minna_san_const_buffer value;
} minna_san_http_header;
typedef struct minna_san_http_request {
    minna_san_const_buffer method;
    minna_san_const_buffer target;
    minna_san_const_buffer authority;
    const minna_san_http_header *headers;
    size_t header_count;
    minna_san_const_buffer body;
    uint8_t close_after_response;
    uint8_t reserved[7];
} minna_san_http_request;
typedef struct minna_san_http_response {
    uint64_t sequence;
    uint16_t status;
    uint8_t keep_alive;
    uint8_t redirect_not_followed;
    minna_san_const_buffer body;
} minna_san_http_response;
typedef struct minna_san_tls_certificate_request {
    uint64_t id;
    uint32_t kind;
    minna_san_const_buffer server_name;
    uint64_t peer_certificate_chain_id;
    uint8_t has_peer_certificate_chain_id;
    uint8_t reserved[7];
    minna_san_duration_ns issued_at_ns;
    minna_san_duration_ns expires_at_ns;
} minna_san_tls_certificate_request;
typedef void (*minna_san_tls_certificate_begin_fn)(void *context, const minna_san_tls_certificate_request *request);
typedef uint32_t (*minna_san_tls_certificate_poll_fn)(void *context, uint64_t request_id);
typedef struct minna_san_tls_certificate_callbacks {
    void *context;
    minna_san_tls_certificate_begin_fn begin;
    minna_san_tls_certificate_poll_fn poll;
    size_t maximum_pending;
} minna_san_tls_certificate_callbacks;
typedef struct minna_san_websocket_client_config {
    minna_san_const_buffer uri;
    minna_san_const_buffer subprotocol;
    size_t maximum_message_bytes;
    size_t maximum_in_flight_messages;
} minna_san_websocket_client_config;
typedef struct minna_san_platform_config {
    uint32_t version;
    size_t provider_capacity;
    size_t service_capacity;
    size_t session_capacity;
    size_t channel_capacity;
    size_t event_capacity;
    size_t poll_work_budget;
} minna_san_platform_config;
typedef struct minna_san_sdk_config {
    minna_san_abi_version_t abi_version;
    uint32_t capability_bits;
    size_t connection_capacity;
    size_t channel_capacity;
    minna_san_platform_config platform_config;
    void *clock_context;
    minna_san_now_fn now;
    minna_san_allocator allocator;
} minna_san_sdk_config;
typedef struct minna_san_native_udp_config {
    minna_san_address local_address;
    minna_san_address peer_address;
    size_t maximum_payload_bytes;
    size_t maximum_in_flight;
} minna_san_native_udp_config;
typedef uint32_t (*minna_san_admission_fn)(void *context, const minna_san_peer *peer);
typedef struct minna_san_authoritative_session_config {
    size_t max_clients;
    void *admission_context;
    minna_san_admission_fn admission;
} minna_san_authoritative_session_config;
typedef struct minna_san_candidate {
    uint32_t kind;
    minna_san_address address;
    uint32_t priority;
    minna_san_duration_ns expires_at_ns;
} minna_san_candidate;
typedef struct minna_san_p2p_config {
    size_t max_peers;
    uint32_t shard_id;
    minna_san_candidate candidate;
} minna_san_p2p_config;
typedef struct minna_san_stun_turn_config {
    minna_san_address stun_server;
    minna_san_address turn_server;
    minna_san_buffer turn_username;
    minna_san_buffer turn_password;
} minna_san_stun_turn_config;
typedef struct minna_san_migration_config {
    uint8_t enabled;
    uint8_t reserved[3];
    minna_san_duration_ns handoff_timeout_ns;
    uint32_t max_attempts;
} minna_san_migration_config;
typedef struct minna_san_topology_config {
    minna_san_p2p_config p2p;
    minna_san_stun_turn_config stun_turn;
    minna_san_migration_config migration;
} minna_san_topology_config;
typedef struct minna_san_authoritative_recovery_config {
    uint8_t maximum_reconnect_attempts;
    uint8_t reserved[7];
} minna_san_authoritative_recovery_config;
typedef struct minna_san_sharded_p2p_config {
    size_t maximum_groups;
    size_t maximum_participants;
    size_t maximum_dispatches_per_pump;
    size_t maximum_signal_bytes;
    size_t maximum_liveness_peers;
    minna_san_duration_ns heartbeat_interval_ns;
    minna_san_duration_ns idle_timeout_ns;
    minna_san_duration_ns reconnect_window_ns;
    size_t maximum_liveness_events_per_poll;
} minna_san_sharded_p2p_config;
typedef struct minna_san_stun_config {
    minna_san_address udp_server;
    minna_san_duration_ns udp_initial_rto_ns;
    size_t udp_maximum_retransmissions;
    size_t udp_maximum_alternate_servers;
    minna_san_address tcp_server;
    minna_san_duration_ns tcp_timeout_ns;
    minna_san_buffer tcp_username;
    minna_san_buffer tcp_password;
} minna_san_stun_config;
typedef struct minna_san_turn_config {
    minna_san_address server;
    minna_san_buffer username;
    minna_san_buffer password;
    minna_san_buffer realm;
    minna_san_buffer nonce;
    uint32_t requested_lifetime_seconds;
    size_t maximum_permissions;
    minna_san_duration_ns permission_lifetime_ns;
    size_t maximum_channels;
    minna_san_duration_ns credential_expires_at_ns;
    minna_san_duration_ns refresh_margin_ns;
    size_t maximum_failures;
} minna_san_turn_config;
typedef struct minna_san_route_config {
    uint32_t policy;
    uint8_t allow_direct;
    uint8_t allow_relay;
    uint8_t allow_authoritative;
    uint8_t allow_degraded;
    uint32_t initial_route;
    uint32_t role;
    uint8_t reserved[4];
    uint64_t initial_security_epoch;
    size_t maximum_diagnostics;
    size_t maximum_pairs;
    size_t maximum_in_flight;
    uint8_t maximum_attempts;
    uint8_t maximum_keepalive_failures;
    uint8_t maximum_keepalive_sends_per_poll;
    uint8_t reserved2[5];
    uint64_t tie_breaker;
    minna_san_duration_ns pace_interval_ns;
    minna_san_duration_ns retry_interval_ns;
    minna_san_duration_ns check_timeout_ns;
    minna_san_duration_ns keepalive_interval_ns;
    minna_san_duration_ns keepalive_retry_interval_ns;
} minna_san_route_config;
typedef struct minna_san_migration_transfer_config {
    uint64_t initial_host;
    uint64_t initial_term;
    uint64_t initial_membership_revision;
    uint64_t initial_state_revision;
    size_t maximum_records;
    size_t maximum_state_bytes;
    minna_san_buffer integrity_key;
} minna_san_migration_transfer_config;
typedef struct minna_san_topology_capabilities_config {
    minna_san_authoritative_recovery_config authoritative_recovery;
    minna_san_sharded_p2p_config sharded_p2p;
    minna_san_stun_config stun;
    minna_san_turn_config turn;
    minna_san_route_config route;
    minna_san_migration_transfer_config migration_transfer;
} minna_san_topology_capabilities_config;
typedef int (*minna_san_state_transform_fn)(void *context, minna_san_buffer input, minna_san_buffer *output);
typedef struct minna_san_state_transfer_config {
    void *context;
    minna_san_state_transform_fn serialize;
    minna_san_state_transform_fn deserialize;
    size_t max_snapshot_bytes;
    size_t max_delta_bytes;
    minna_san_duration_ns recovery_timeout_ns;
    uint32_t template_kind;
} minna_san_state_transfer_config;
typedef struct minna_san_metrics_snapshot {
    uint64_t polls;
    size_t active_connections;
    size_t active_channels;
    size_t active_sessions;
} minna_san_metrics_snapshot;
typedef struct minna_san_runtime_metrics_snapshot {
    uint64_t polls;
    uint64_t events;
    uint64_t connected;
    uint64_t disconnected;
    uint64_t messages;
    uint64_t overflows;
    uint64_t dropped_events;
    uint64_t active_connections;
    uint64_t message_bytes_samples;
    uint64_t message_bytes_total;
    uint64_t message_bytes_maximum;
    uint32_t direct_route_health;
    uint32_t relay_route_health;
    uint32_t authoritative_route_health;
    uint64_t queue_depth;
    uint64_t queue_capacity;
    uint64_t security_events[MINNA_SAN_SECURITY_EVENT_COUNT];
} minna_san_runtime_metrics_snapshot;
typedef void (*minna_san_log_fn)(void *context, uint32_t level, const char *message);
typedef struct minna_san_log_record {
    uint64_t sequence;
    uint32_t level;
    uint32_t category;
    uint32_t redaction;
    minna_san_const_buffer message;
    uint64_t source_event_sequence;
    uint8_t has_source_event_sequence;
    uint8_t reserved[7];
} minna_san_log_record;
typedef void (*minna_san_log_record_fn)(void *context, const minna_san_log_record *record);
typedef struct minna_san_log_subscription {
    uint64_t id;
} minna_san_log_subscription;
typedef struct minna_san_diagnostics_config {
    void *log_context;
    minna_san_log_fn log;
    uint32_t log_level;
    uint8_t capture_enabled;
    uint8_t replay_enabled;
    uint8_t redact_payloads;
    uint8_t reserved;
    size_t max_capture_bytes;
} minna_san_diagnostics_config;
typedef struct minna_san_socket_options {
    uint32_t send_buffer_bytes;
    uint32_t receive_buffer_bytes;
    uint8_t reuse_address;
    uint8_t no_delay;
    uint8_t reserved[2];
} minna_san_socket_options;
typedef struct minna_san_transport_control {
    minna_san_duration_ns connect_timeout_ns;
    minna_san_duration_ns idle_timeout_ns;
    uint32_t max_datagram_bytes;
    uint32_t max_in_flight;
} minna_san_transport_control;
typedef struct minna_san_transport_config {
    uint32_t kind;
    minna_san_address local_address;
    minna_san_address remote_address;
    minna_san_socket_options socket_options;
    minna_san_transport_control control;
} minna_san_transport_config;
typedef struct minna_san_security_config {
    uint32_t flags;
    minna_san_buffer psk;
    minna_san_buffer public_key;
    minna_san_buffer aead_key;
    uint32_t replay_window;
    minna_san_duration_ns rotation_interval_ns;
    minna_san_duration_ns rotation_overlap_ns;
} minna_san_security_config;

#include "minna_san_api.h"
#ifdef __cplusplus
}
#endif

#endif
