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
        .connection_capacity = 1u,
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
    if (minna_san_sdk_poll(sdk, &event) != MINNA_SAN_RESULT_WOULD_BLOCK) return 9;
    if (minna_san_sdk_metrics_snapshot(sdk, &metrics) != MINNA_SAN_RESULT_OK) return 10;
    if (metrics.polls != 1u || metrics.active_connections != 0u) return 11;
    if (minna_san_sdk_runtime_metrics_snapshot(sdk, &runtime_metrics) != MINNA_SAN_RESULT_OK) return 12;
    if (runtime_metrics.polls != 1u || runtime_metrics.events != 0u) return 13;
    if (minna_san_sdk_stop(sdk) != MINNA_SAN_RESULT_OK) return 14;
    minna_san_sdk_destroy(sdk);
    return 0;
}
