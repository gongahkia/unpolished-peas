#include <minna_san.h>
#include <stdlib.h>

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

int c_abi_consumer_main(void) {
    const minna_san_allocator allocator = {
        .context = 0,
        .allocate = minna_san_consumer_allocate,
        .release = minna_san_consumer_release,
    };
    const minna_san_sdk_config config = {
        .abi_version = MINNA_SAN_ABI_VERSION,
        .capability_bits = MINNA_SAN_CAPABILITY_TRANSPORT,
        .connection_capacity = 1u,
        .channel_capacity = 1u,
        .clock_context = 0,
        .now = minna_san_consumer_now,
        .allocator = allocator,
    };
    minna_san_sdk *sdk = 0;
    minna_san_event event;
    minna_san_metrics_snapshot metrics;
    minna_san_runtime_metrics_snapshot runtime_metrics;

    if (minna_san_abi_version() != MINNA_SAN_ABI_VERSION) return 1;
    if (minna_san_abi_supports_version(MINNA_SAN_ABI_VERSION) != 1u) return 2;
    if (minna_san_result_category(MINNA_SAN_RESULT_VERSION_MISMATCH) != MINNA_SAN_ERROR_CATEGORY_VERSION_MISMATCH) return 3;
    if (minna_san_sdk_validate_config(&config) != MINNA_SAN_RESULT_OK) return 4;
    if (minna_san_sdk_create(&config, &sdk) != MINNA_SAN_RESULT_OK) return 5;
    if (minna_san_sdk_start(sdk) != MINNA_SAN_RESULT_OK) return 6;
    if (minna_san_sdk_poll(sdk, &event) != MINNA_SAN_RESULT_WOULD_BLOCK) return 7;
    if (minna_san_sdk_metrics_snapshot(sdk, &metrics) != MINNA_SAN_RESULT_OK) return 8;
    if (metrics.polls != 1u || metrics.active_connections != 0u) return 9;
    if (minna_san_sdk_runtime_metrics_snapshot(sdk, &runtime_metrics) != MINNA_SAN_RESULT_OK) return 10;
    if (runtime_metrics.polls != 1u || runtime_metrics.events != 0u) return 11;
    if (minna_san_sdk_stop(sdk) != MINNA_SAN_RESULT_OK) return 12;
    minna_san_sdk_destroy(sdk);
    return 0;
}
