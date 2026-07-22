#ifndef MINNA_MSQUIC_LIFECYCLE_NATIVE_H
#define MINNA_MSQUIC_LIFECYCLE_NATIVE_H

#include <stdint.h>

typedef struct minna_quic_connection_provider_event {
    uint64_t connection_id;
    uint8_t kind;
    int32_t status;
} minna_quic_connection_provider_event;

typedef int32_t (*minna_quic_connection_callback)(void* context, const minna_quic_connection_provider_event* event);

typedef struct minna_msquic_lifecycle_fixture minna_msquic_lifecycle_fixture;

int32_t minna_msquic_lifecycle_fixture_init(minna_msquic_lifecycle_fixture** output, const char* certificate_path, const char* private_key_path);
int32_t minna_msquic_lifecycle_fixture_open(minna_msquic_lifecycle_fixture* fixture, uint64_t connection_id, uint8_t role, void* callback_context, minna_quic_connection_callback callback);
void minna_msquic_lifecycle_fixture_shutdown(minna_msquic_lifecycle_fixture* fixture, uint64_t connection_id);
void minna_msquic_lifecycle_fixture_deinit(minna_msquic_lifecycle_fixture* fixture);

#endif
