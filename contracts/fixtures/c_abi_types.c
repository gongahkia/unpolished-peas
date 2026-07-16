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

static void *minna_san_fixture_allocate(void *context, size_t len) {
    return len == 0 ? context : 0;
}

static void minna_san_fixture_release(void *context, uint8_t *data, size_t len) {
    (void)context;
    (void)data;
    (void)len;
}

int minna_san_c_abi_types_fixture(minna_san_handle *handle, minna_san_event event) {
    const minna_san_allocator allocator = {
        .context = 0,
        .allocate = minna_san_fixture_allocate,
        .release = minna_san_fixture_release,
    };
    return (handle == 0 && event.payload.len == 0 && allocator.allocate != 0 && allocator.release != 0 && abi_version_query != 0 && abi_support_query != 0 && result_is_known_query != 0 && result_category_query != 0 && result_message_query != 0) ? 0 : 1;
}
