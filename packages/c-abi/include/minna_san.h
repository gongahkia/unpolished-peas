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

typedef uint32_t minna_san_abi_version_t;
typedef int64_t minna_san_duration_ns;
typedef struct minna_san_handle minna_san_handle;
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
typedef struct minna_san_event {
    uint32_t kind;
    uint32_t mode;
    uint64_t sequence;
    minna_san_buffer payload;
} minna_san_event;

minna_san_abi_version_t minna_san_abi_version(void);
uint8_t minna_san_abi_supports_version(minna_san_abi_version_t requested_version);

#ifdef __cplusplus
}
#endif

#endif
