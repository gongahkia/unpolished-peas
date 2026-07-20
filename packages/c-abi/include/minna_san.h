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

minna_san_abi_version_t minna_san_abi_version(void);
uint8_t minna_san_abi_supports_version(minna_san_abi_version_t requested_version);
uint8_t minna_san_result_is_known(int result_code);
minna_san_error_category minna_san_result_category(int result_code);
const char *minna_san_result_message(int result_code);
minna_san_result minna_san_platform_config_init(minna_san_platform_config *out_config);
minna_san_result minna_san_platform_config_validate(const minna_san_platform_config *config);
minna_san_result minna_san_sdk_validate_config(const minna_san_sdk_config *config);
minna_san_result minna_san_sdk_create(const minna_san_sdk_config *config, minna_san_sdk **out_sdk);
minna_san_result minna_san_sdk_start(minna_san_sdk *sdk);
minna_san_result minna_san_sdk_poll(minna_san_sdk *sdk, minna_san_event *out_event);
minna_san_result minna_san_sdk_stop(minna_san_sdk *sdk);
void minna_san_sdk_destroy(minna_san_sdk *sdk);
minna_san_result minna_san_channel_open(minna_san_sdk *sdk, minna_san_connection *connection, uint32_t mode, minna_san_channel **out_channel);
minna_san_result minna_san_channel_close(minna_san_sdk *sdk, minna_san_channel *channel);
minna_san_result minna_san_channel_mode(minna_san_sdk *sdk, minna_san_channel *channel, uint32_t *out_mode);
minna_san_result minna_san_channel_send(minna_san_sdk *sdk, minna_san_channel *channel, minna_san_buffer buffer, uint64_t *out_sequence);
minna_san_result minna_san_channel_receive(minna_san_sdk *sdk, minna_san_channel *channel, minna_san_buffer *out_buffer, uint64_t *out_sequence);
minna_san_result minna_san_channel_acknowledge(minna_san_sdk *sdk, minna_san_channel *channel, uint64_t sequence);
minna_san_result minna_san_channel_last_acknowledged(minna_san_sdk *sdk, minna_san_channel *channel, uint64_t *out_sequence);
minna_san_result minna_san_sdk_buffer_release(minna_san_sdk *sdk, minna_san_buffer buffer);
minna_san_result minna_san_security_config_init(minna_san_security_config *out_config);
minna_san_result minna_san_security_config_set_psk(minna_san_security_config *config, minna_san_buffer psk);
minna_san_result minna_san_security_config_set_public_key(minna_san_security_config *config, minna_san_buffer public_key);
minna_san_result minna_san_security_config_set_aead_key(minna_san_security_config *config, minna_san_buffer aead_key);
minna_san_result minna_san_security_config_set_replay_window(minna_san_security_config *config, uint32_t replay_window);
minna_san_result minna_san_security_config_set_key_rotation(minna_san_security_config *config, minna_san_duration_ns interval_ns, minna_san_duration_ns overlap_ns);
minna_san_result minna_san_security_config_validate(const minna_san_security_config *config);
minna_san_result minna_san_authoritative_session_config_init(minna_san_authoritative_session_config *out_config);
minna_san_result minna_san_authoritative_session_config_validate(const minna_san_authoritative_session_config *config);
minna_san_result minna_san_authoritative_session_create(minna_san_sdk *sdk, const minna_san_authoritative_session_config *config, minna_san_authoritative_session **out_session);
minna_san_result minna_san_authoritative_session_destroy(minna_san_sdk *sdk, minna_san_authoritative_session *session);
minna_san_result minna_san_authoritative_session_client_join(minna_san_sdk *sdk, minna_san_authoritative_session *session, minna_san_connection *connection);
minna_san_result minna_san_authoritative_session_client_leave(minna_san_sdk *sdk, minna_san_authoritative_session *session, minna_san_connection *connection);
minna_san_result minna_san_authoritative_session_client_count(minna_san_sdk *sdk, minna_san_authoritative_session *session, size_t *out_count);
minna_san_result minna_san_topology_config_init(minna_san_topology_config *out_config);
minna_san_result minna_san_topology_config_set_p2p(minna_san_topology_config *config, minna_san_p2p_config p2p);
minna_san_result minna_san_topology_config_set_stun_turn(minna_san_topology_config *config, minna_san_stun_turn_config stun_turn);
minna_san_result minna_san_topology_config_set_migration(minna_san_topology_config *config, minna_san_migration_config migration);
minna_san_result minna_san_topology_config_validate(const minna_san_topology_config *config);
minna_san_result minna_san_topology_capabilities_config_init(minna_san_topology_capabilities_config *out_config);
minna_san_result minna_san_topology_capabilities_config_set_authoritative_recovery(minna_san_topology_capabilities_config *config, minna_san_authoritative_recovery_config authoritative_recovery);
minna_san_result minna_san_topology_capabilities_config_set_sharded_p2p(minna_san_topology_capabilities_config *config, minna_san_sharded_p2p_config sharded_p2p);
minna_san_result minna_san_topology_capabilities_config_set_stun(minna_san_topology_capabilities_config *config, minna_san_stun_config stun);
minna_san_result minna_san_topology_capabilities_config_set_turn(minna_san_topology_capabilities_config *config, minna_san_turn_config turn);
minna_san_result minna_san_topology_capabilities_config_set_route(minna_san_topology_capabilities_config *config, minna_san_route_config route);
minna_san_result minna_san_topology_capabilities_config_set_migration_transfer(minna_san_topology_capabilities_config *config, minna_san_migration_transfer_config migration_transfer);
minna_san_result minna_san_topology_capabilities_config_validate(const minna_san_topology_capabilities_config *config);
minna_san_result minna_san_state_transfer_config_init(minna_san_state_transfer_config *out_config);
minna_san_result minna_san_state_transfer_config_set_callbacks(minna_san_state_transfer_config *config, void *context, minna_san_state_transform_fn serialize, minna_san_state_transform_fn deserialize);
minna_san_result minna_san_state_transfer_config_set_snapshot_limits(minna_san_state_transfer_config *config, size_t max_snapshot_bytes, size_t max_delta_bytes);
minna_san_result minna_san_state_transfer_config_set_recovery(minna_san_state_transfer_config *config, minna_san_duration_ns recovery_timeout_ns, uint32_t template_kind);
minna_san_result minna_san_state_transfer_config_validate(const minna_san_state_transfer_config *config);
minna_san_result minna_san_state_transfer_serialize(const minna_san_state_transfer_config *config, minna_san_buffer input, minna_san_buffer *out_snapshot);
minna_san_result minna_san_state_transfer_deserialize(const minna_san_state_transfer_config *config, minna_san_buffer input, minna_san_buffer *out_state);
minna_san_result minna_san_sdk_metrics_snapshot(minna_san_sdk *sdk, minna_san_metrics_snapshot *out_snapshot);
minna_san_result minna_san_sdk_runtime_metrics_snapshot(minna_san_sdk *sdk, minna_san_runtime_metrics_snapshot *out_snapshot);
minna_san_result minna_san_sdk_log_callback_register(minna_san_sdk *sdk, void *context, minna_san_log_record_fn callback, minna_san_log_subscription *out_subscription);
minna_san_result minna_san_sdk_log_callback_unregister(minna_san_sdk *sdk, minna_san_log_subscription subscription);
minna_san_result minna_san_sdk_log(minna_san_sdk *sdk, uint32_t level, uint32_t category, uint32_t redaction, minna_san_buffer message);
minna_san_result minna_san_diagnostics_config_init(minna_san_diagnostics_config *out_config);
minna_san_result minna_san_diagnostics_config_set_logging(minna_san_diagnostics_config *config, void *context, minna_san_log_fn log, uint32_t level);
minna_san_result minna_san_diagnostics_config_set_capture_replay(minna_san_diagnostics_config *config, uint8_t capture_enabled, uint8_t replay_enabled, uint8_t redact_payloads, size_t max_capture_bytes);
minna_san_result minna_san_diagnostics_config_validate(const minna_san_diagnostics_config *config);
minna_san_result minna_san_diagnostics_log(const minna_san_diagnostics_config *config, const char *message);
minna_san_result minna_san_connection_open(minna_san_sdk *sdk, uint32_t route_state, minna_san_connection **out_connection, minna_san_peer **out_peer);
minna_san_result minna_san_connection_close(minna_san_sdk *sdk, minna_san_connection *connection);
minna_san_result minna_san_connection_peer(minna_san_sdk *sdk, minna_san_connection *connection, minna_san_peer **out_peer);
minna_san_result minna_san_connection_route_state(minna_san_sdk *sdk, minna_san_connection *connection, uint32_t *out_route_state);
minna_san_result minna_san_connection_set_route_state(minna_san_sdk *sdk, minna_san_connection *connection, uint32_t route_state);
uint32_t minna_san_event_kind(const minna_san_event *event);
uint32_t minna_san_event_mode(const minna_san_event *event);
uint64_t minna_san_event_sequence(const minna_san_event *event);
minna_san_buffer minna_san_event_payload(const minna_san_event *event);
minna_san_result minna_san_transport_config_init(minna_san_transport_config *out_config);
minna_san_result minna_san_transport_config_set_kind(minna_san_transport_config *config, uint32_t kind);
minna_san_result minna_san_transport_config_set_local_address(minna_san_transport_config *config, minna_san_address address);
minna_san_result minna_san_transport_config_set_remote_address(minna_san_transport_config *config, minna_san_address address);
minna_san_result minna_san_transport_config_set_socket_options(minna_san_transport_config *config, minna_san_socket_options options);
minna_san_result minna_san_transport_config_set_control(minna_san_transport_config *config, minna_san_transport_control control);
minna_san_result minna_san_transport_config_validate(const minna_san_transport_config *config);

#ifdef __cplusplus
}
#endif

#endif
