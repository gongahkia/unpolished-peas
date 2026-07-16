#ifndef MINNA_SAN_H
#define MINNA_SAN_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MINNA_SAN_ABI_VERSION 1u
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
typedef struct minna_san_sdk_config {
    minna_san_abi_version_t abi_version;
    uint32_t capability_bits;
    void *clock_context;
    minna_san_now_fn now;
    minna_san_allocator allocator;
} minna_san_sdk_config;

minna_san_abi_version_t minna_san_abi_version(void);
uint8_t minna_san_abi_supports_version(minna_san_abi_version_t requested_version);
uint8_t minna_san_result_is_known(int result_code);
minna_san_error_category minna_san_result_category(int result_code);
const char *minna_san_result_message(int result_code);
minna_san_result minna_san_sdk_validate_config(const minna_san_sdk_config *config);
minna_san_result minna_san_sdk_create(const minna_san_sdk_config *config, minna_san_sdk **out_sdk);
minna_san_result minna_san_sdk_start(minna_san_sdk *sdk);
minna_san_result minna_san_sdk_poll(minna_san_sdk *sdk, minna_san_event *out_event);
minna_san_result minna_san_sdk_stop(minna_san_sdk *sdk);
void minna_san_sdk_destroy(minna_san_sdk *sdk);

#ifdef __cplusplus
}
#endif

#endif
