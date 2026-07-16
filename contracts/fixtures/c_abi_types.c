#include <minna_san.h>

_Static_assert(MINNA_SAN_ABI_VERSION == 1u, "ABI version");
_Static_assert(sizeof(((minna_san_address *)0)->bytes) == MINNA_SAN_ADDRESS_BYTES, "address bytes");
_Static_assert(sizeof(((minna_san_buffer *)0)->data) == sizeof(uint8_t *), "buffer pointer");

static minna_san_abi_version_t (*const abi_version_query)(void) = minna_san_abi_version;
static uint8_t (*const abi_support_query)(minna_san_abi_version_t) = minna_san_abi_supports_version;

int minna_san_c_abi_types_fixture(minna_san_handle *handle, minna_san_event event) {
    return (handle == 0 && event.payload.len == 0 && abi_version_query != 0 && abi_support_query != 0) ? 0 : 1;
}
