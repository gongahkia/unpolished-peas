#define _POSIX_C_SOURCE 200809L
#include "msquic_lifecycle_native.h"

#include <msquic.h>
#include <pthread.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdlib.h>

enum {
    MINNA_QUIC_ROLE_CLIENT = 0,
    MINNA_QUIC_ROLE_SERVER = 1,
    MINNA_QUIC_EVENT_CONNECTED = 0,
    MINNA_QUIC_EVENT_TRANSPORT_SHUTDOWN = 1,
    MINNA_QUIC_EVENT_PEER_SHUTDOWN = 2,
    MINNA_QUIC_EVENT_SHUTDOWN_COMPLETE = 3,
    MINNA_QUIC_EVENT_LOCAL_ADDRESS_CHANGED = 4,
    MINNA_QUIC_EVENT_PEER_ADDRESS_CHANGED = 5,
};

typedef struct minna_native_callback {
    uint64_t connection_id;
    void* context;
    minna_quic_connection_callback callback;
} minna_native_callback;

struct minna_msquic_lifecycle_fixture {
    const QUIC_API_TABLE* api;
    HQUIC registration;
    HQUIC listener;
    HQUIC server_configuration;
    HQUIC client_configuration;
    HQUIC server_connection;
    HQUIC client_connection;
    uint16_t listener_port;
    minna_native_callback server;
    minna_native_callback client;
    pthread_mutex_t mutex;
};

_Static_assert(sizeof(minna_quic_connection_provider_event) == 16, "unexpected lifecycle event size");
_Static_assert(offsetof(minna_quic_connection_provider_event, status) == 12, "unexpected lifecycle event layout");

static QUIC_STATUS QUIC_API server_connection_callback(HQUIC connection, void* context, QUIC_CONNECTION_EVENT* event);
static QUIC_STATUS QUIC_API client_connection_callback(HQUIC connection, void* context, QUIC_CONNECTION_EVENT* event);

static QUIC_STATUS emit_event(const minna_native_callback* callback, uint8_t kind, int32_t status) {
    if (callback->callback == NULL) return QUIC_STATUS_INVALID_STATE;
    const minna_quic_connection_provider_event event = {
        .connection_id = callback->connection_id,
        .kind = kind,
        .status = status,
    };
    return callback->callback(callback->context, &event) == 0 ? QUIC_STATUS_SUCCESS : QUIC_STATUS_ABORTED;
}

static QUIC_STATUS emit_connection_event(struct minna_msquic_lifecycle_fixture* fixture, HQUIC connection, QUIC_CONNECTION_EVENT* event, bool server) {
    minna_native_callback callback;
    const QUIC_API_TABLE* api = fixture->api;
    pthread_mutex_lock(&fixture->mutex);
    callback = server ? fixture->server : fixture->client;
    if (event->Type == QUIC_CONNECTION_EVENT_SHUTDOWN_COMPLETE) {
        if (server && fixture->server_connection == connection) fixture->server_connection = NULL;
        if (!server && fixture->client_connection == connection) fixture->client_connection = NULL;
    }
    pthread_mutex_unlock(&fixture->mutex);
    QUIC_STATUS result = QUIC_STATUS_SUCCESS;
    switch (event->Type) {
        case QUIC_CONNECTION_EVENT_CONNECTED:
            result = emit_event(&callback, MINNA_QUIC_EVENT_CONNECTED, 0);
            break;
        case QUIC_CONNECTION_EVENT_SHUTDOWN_INITIATED_BY_TRANSPORT:
            result = emit_event(&callback, MINNA_QUIC_EVENT_TRANSPORT_SHUTDOWN, (int32_t)event->SHUTDOWN_INITIATED_BY_TRANSPORT.Status);
            break;
        case QUIC_CONNECTION_EVENT_SHUTDOWN_INITIATED_BY_PEER:
            result = emit_event(&callback, MINNA_QUIC_EVENT_PEER_SHUTDOWN, 0);
            break;
        case QUIC_CONNECTION_EVENT_LOCAL_ADDRESS_CHANGED:
            result = emit_event(&callback, MINNA_QUIC_EVENT_LOCAL_ADDRESS_CHANGED, 0);
            break;
        case QUIC_CONNECTION_EVENT_PEER_ADDRESS_CHANGED:
            result = emit_event(&callback, MINNA_QUIC_EVENT_PEER_ADDRESS_CHANGED, 0);
            break;
        case QUIC_CONNECTION_EVENT_SHUTDOWN_COMPLETE:
            result = emit_event(&callback, MINNA_QUIC_EVENT_SHUTDOWN_COMPLETE, 0);
            api->ConnectionClose(connection);
            break;
        default:
            break;
    }
    return result;
}

static QUIC_STATUS QUIC_API server_connection_callback(HQUIC connection, void* context, QUIC_CONNECTION_EVENT* event) {
    return emit_connection_event(context, connection, event, true);
}

static QUIC_STATUS QUIC_API client_connection_callback(HQUIC connection, void* context, QUIC_CONNECTION_EVENT* event) {
    return emit_connection_event(context, connection, event, false);
}

static QUIC_STATUS QUIC_API listener_callback(HQUIC listener, void* context, QUIC_LISTENER_EVENT* event) {
    struct minna_msquic_lifecycle_fixture* fixture = context;
    (void)listener;
    if (event->Type != QUIC_LISTENER_EVENT_NEW_CONNECTION) return QUIC_STATUS_SUCCESS;
    pthread_mutex_lock(&fixture->mutex);
    const minna_native_callback callback = fixture->server;
    fixture->server_connection = event->NEW_CONNECTION.Connection;
    pthread_mutex_unlock(&fixture->mutex);
    if (callback.callback == NULL) return QUIC_STATUS_INVALID_STATE;
    fixture->api->SetCallbackHandler(event->NEW_CONNECTION.Connection, (void*)server_connection_callback, fixture);
    return fixture->api->ConnectionSetConfiguration(event->NEW_CONNECTION.Connection, fixture->server_configuration);
}

static void close_resources(struct minna_msquic_lifecycle_fixture* fixture) {
    if (fixture == NULL) return;
    if (fixture->listener != NULL) fixture->api->ListenerClose(fixture->listener);
    if (fixture->client_configuration != NULL) fixture->api->ConfigurationClose(fixture->client_configuration);
    if (fixture->server_configuration != NULL) fixture->api->ConfigurationClose(fixture->server_configuration);
    if (fixture->registration != NULL) fixture->api->RegistrationClose(fixture->registration);
    if (fixture->api != NULL) MsQuicClose(fixture->api);
    pthread_mutex_destroy(&fixture->mutex);
    free(fixture);
}

int32_t minna_msquic_lifecycle_fixture_init(minna_msquic_lifecycle_fixture** output, const char* certificate_path, const char* private_key_path) {
    if (output == NULL || certificate_path == NULL || private_key_path == NULL) return -1;
    *output = NULL;
    struct minna_msquic_lifecycle_fixture* fixture = calloc(1, sizeof(*fixture));
    if (fixture == NULL) return -1;
    if (pthread_mutex_init(&fixture->mutex, NULL) != 0) {
        free(fixture);
        return -1;
    }
    QUIC_BUFFER alpn = { .Length = sizeof("minna-lifecycle/1") - 1, .Buffer = (uint8_t*)"minna-lifecycle/1" };
    QUIC_CERTIFICATE_FILE certificate = { .PrivateKeyFile = private_key_path, .CertificateFile = certificate_path };
    QUIC_CREDENTIAL_CONFIG server_credentials = { .Type = QUIC_CREDENTIAL_TYPE_CERTIFICATE_FILE, .CertificateFile = &certificate };
    QUIC_CREDENTIAL_CONFIG client_credentials = { .Type = QUIC_CREDENTIAL_TYPE_NONE, .Flags = QUIC_CREDENTIAL_FLAG_CLIENT | QUIC_CREDENTIAL_FLAG_NO_CERTIFICATE_VALIDATION };
    QUIC_REGISTRATION_CONFIG registration = { .AppName = "minna-lifecycle", .ExecutionProfile = QUIC_EXECUTION_PROFILE_LOW_LATENCY };
    if (QUIC_FAILED(MsQuicOpen2(&fixture->api))) goto failure;
    if (QUIC_FAILED(fixture->api->RegistrationOpen(&registration, &fixture->registration))) goto failure;
    if (QUIC_FAILED(fixture->api->ConfigurationOpen(fixture->registration, &alpn, 1, NULL, 0, NULL, &fixture->server_configuration))) goto failure;
    if (QUIC_FAILED(fixture->api->ConfigurationLoadCredential(fixture->server_configuration, &server_credentials))) goto failure;
    if (QUIC_FAILED(fixture->api->ConfigurationOpen(fixture->registration, &alpn, 1, NULL, 0, NULL, &fixture->client_configuration))) goto failure;
    if (QUIC_FAILED(fixture->api->ConfigurationLoadCredential(fixture->client_configuration, &client_credentials))) goto failure;
    if (QUIC_FAILED(fixture->api->ListenerOpen(fixture->registration, listener_callback, fixture, &fixture->listener))) goto failure;
    *output = fixture;
    return 0;

failure:
    close_resources(fixture);
    return -1;
}

int32_t minna_msquic_lifecycle_fixture_open(minna_msquic_lifecycle_fixture* fixture, uint64_t connection_id, uint8_t role, void* callback_context, minna_quic_connection_callback callback) {
    if (fixture == NULL || callback == NULL) return -1;
    QUIC_BUFFER alpn = { .Length = sizeof("minna-lifecycle/1") - 1, .Buffer = (uint8_t*)"minna-lifecycle/1" };
    if (role == MINNA_QUIC_ROLE_SERVER) {
        QUIC_ADDR address = {0};
        QuicAddrSetFamily(&address, QUIC_ADDRESS_FAMILY_INET);
        QuicAddrSetToLoopback(&address);
        QuicAddrSetPort(&address, 0);
        pthread_mutex_lock(&fixture->mutex);
        if (fixture->server.callback != NULL) {
            pthread_mutex_unlock(&fixture->mutex);
            return -1;
        }
        fixture->server = (minna_native_callback){ .connection_id = connection_id, .context = callback_context, .callback = callback };
        pthread_mutex_unlock(&fixture->mutex);
        if (QUIC_FAILED(fixture->api->ListenerStart(fixture->listener, &alpn, 1, &address))) return -1;
        uint32_t address_length = sizeof(address);
        if (QUIC_FAILED(fixture->api->GetParam(fixture->listener, QUIC_PARAM_LISTENER_LOCAL_ADDRESS, &address_length, &address))) return -1;
        pthread_mutex_lock(&fixture->mutex);
        fixture->listener_port = QuicAddrGetPort(&address);
        pthread_mutex_unlock(&fixture->mutex);
        return fixture->listener_port == 0 ? -1 : 0;
    }
    if (role != MINNA_QUIC_ROLE_CLIENT) return -1;
    pthread_mutex_lock(&fixture->mutex);
    if (fixture->client.callback != NULL || fixture->listener_port == 0) {
        pthread_mutex_unlock(&fixture->mutex);
        return -1;
    }
    fixture->client = (minna_native_callback){ .connection_id = connection_id, .context = callback_context, .callback = callback };
    const uint16_t port = fixture->listener_port;
    pthread_mutex_unlock(&fixture->mutex);
    if (QUIC_FAILED(fixture->api->ConnectionOpen(fixture->registration, client_connection_callback, fixture, &fixture->client_connection))) return -1;
    if (QUIC_FAILED(fixture->api->ConnectionStart(fixture->client_connection, fixture->client_configuration, QUIC_ADDRESS_FAMILY_INET, "localhost", port))) return -1;
    return 0;
}

void minna_msquic_lifecycle_fixture_shutdown(minna_msquic_lifecycle_fixture* fixture, uint64_t connection_id) {
    if (fixture == NULL) return;
    pthread_mutex_lock(&fixture->mutex);
    HQUIC connection = NULL;
    if (fixture->client.connection_id == connection_id) connection = fixture->client_connection;
    if (fixture->server.connection_id == connection_id) connection = fixture->server_connection;
    const bool stop_listener = fixture->server.connection_id == connection_id && connection == NULL;
    pthread_mutex_unlock(&fixture->mutex);
    if (connection != NULL) fixture->api->ConnectionShutdown(connection, QUIC_CONNECTION_SHUTDOWN_FLAG_NONE, 0);
    else if (stop_listener) fixture->api->ListenerStop(fixture->listener);
}

void minna_msquic_lifecycle_fixture_deinit(minna_msquic_lifecycle_fixture* fixture) {
    close_resources(fixture);
}
