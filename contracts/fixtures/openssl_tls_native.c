#include <openssl/err.h>
#include <openssl/ssl.h>

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

enum { MINNA_TLS_CLIENT = 1, MINNA_TLS_SERVER = 2, MINNA_TLS_HANDSHAKING = 1, MINNA_TLS_CONNECTED = 2, MINNA_TLS_FAILED = 3 };

typedef struct {
    size_t bytes;
    uint16_t alert;
} minna_openssl_record_output;

typedef struct {
    uint8_t state;
    uint16_t alert;
    size_t work_completed;
} minna_openssl_poll_output;

typedef struct {
    SSL_CTX* ssl_context;
    SSL* ssl;
    BIO* inbound;
    BIO* outbound;
    uint8_t alpn[256];
    size_t alpn_len;
} minna_openssl_tls;

static int result_failure(void) {
    ERR_clear_error();
    return 14;
}

static int set_result(minna_openssl_record_output* output, size_t bytes) {
    if (output == NULL) return 1;
    output->bytes = bytes;
    output->alert = 0;
    return 0;
}

static int alpn_select(SSL* ssl, const unsigned char** output, unsigned char* output_len, const unsigned char* input, unsigned int input_len, void* argument) {
    (void)ssl;
    minna_openssl_tls* context = argument;
    const unsigned char* selected = NULL;
    unsigned char selected_len = 0;
    if (SSL_select_next_proto((unsigned char**)&selected, &selected_len, context->alpn, (unsigned int)context->alpn_len, input, input_len) != OPENSSL_NPN_NEGOTIATED) return SSL_TLSEXT_ERR_NOACK;
    *output = selected;
    *output_len = selected_len;
    return SSL_TLSEXT_ERR_OK;
}

static int encode_alpn(minna_openssl_tls* context, const uint8_t* alpn, size_t alpn_len) {
    if (context == NULL || alpn == NULL || alpn_len == 0 || alpn_len > 255) return 0;
    context->alpn[0] = (uint8_t)alpn_len;
    memcpy(context->alpn + 1, alpn, alpn_len);
    context->alpn_len = alpn_len + 1;
    return 1;
}

void* minna_openssl_tls_create(uint8_t role, const uint8_t* alpn, size_t alpn_len, const uint8_t* server_name, size_t server_name_len, const char* certificate_path, const char* private_key_path, const char* trust_store_path) {
    if ((role != MINNA_TLS_CLIENT && role != MINNA_TLS_SERVER) || server_name_len > 255) return NULL;
    if (OPENSSL_init_ssl(0, NULL) != 1) return NULL;
    minna_openssl_tls* context = calloc(1, sizeof(*context));
    if (context == NULL || !encode_alpn(context, alpn, alpn_len)) goto failure;
    context->ssl_context = SSL_CTX_new(TLS_method());
    if (context->ssl_context == NULL || SSL_CTX_set_min_proto_version(context->ssl_context, TLS1_2_VERSION) != 1) goto failure;
    if (role == MINNA_TLS_SERVER) {
        if (certificate_path == NULL || private_key_path == NULL || SSL_CTX_use_certificate_chain_file(context->ssl_context, certificate_path) != 1 || SSL_CTX_use_PrivateKey_file(context->ssl_context, private_key_path, SSL_FILETYPE_PEM) != 1 || SSL_CTX_check_private_key(context->ssl_context) != 1) goto failure;
        SSL_CTX_set_alpn_select_cb(context->ssl_context, alpn_select, context);
    } else {
        if (trust_store_path == NULL || SSL_CTX_load_verify_locations(context->ssl_context, trust_store_path, NULL) != 1) goto failure;
        SSL_CTX_set_verify(context->ssl_context, SSL_VERIFY_PEER, NULL);
    }
    context->ssl = SSL_new(context->ssl_context);
    if (context->ssl == NULL) goto failure;
    context->inbound = BIO_new(BIO_s_mem());
    context->outbound = BIO_new(BIO_s_mem());
    if (context->inbound == NULL || context->outbound == NULL) goto failure;
    BIO_set_mem_eof_return(context->inbound, -1);
    BIO_set_mem_eof_return(context->outbound, -1);
    SSL_set_bio(context->ssl, context->inbound, context->outbound);
    context->inbound = NULL;
    context->outbound = NULL;
    if (role == MINNA_TLS_CLIENT) {
        if (SSL_set_alpn_protos(context->ssl, context->alpn, (unsigned int)context->alpn_len) != 0) goto failure;
        if (server_name_len != 0) {
            char hostname[256];
            memcpy(hostname, server_name, server_name_len);
            hostname[server_name_len] = '\0';
            if (SSL_set_tlsext_host_name(context->ssl, hostname) != 1 || SSL_set1_host(context->ssl, hostname) != 1) goto failure;
        }
        SSL_set_connect_state(context->ssl);
    } else {
        SSL_set_accept_state(context->ssl);
    }
    return context;

failure:
    if (context != NULL) {
        BIO_free(context->inbound);
        BIO_free(context->outbound);
        SSL_free(context->ssl);
        SSL_CTX_free(context->ssl_context);
    }
    free(context);
    ERR_clear_error();
    return NULL;
}

void minna_openssl_tls_destroy(void* value) {
    minna_openssl_tls* context = value;
    if (context == NULL) return;
    SSL_free(context->ssl);
    SSL_CTX_free(context->ssl_context);
    free(context);
}

int32_t minna_openssl_tls_start(void* value) {
    minna_openssl_tls* context = value;
    if (context == NULL || context->ssl == NULL) return 1;
    const int result = SSL_do_handshake(context->ssl);
    if (result == 1) return 0;
    const int error = SSL_get_error(context->ssl, result);
    return error == SSL_ERROR_WANT_READ || error == SSL_ERROR_WANT_WRITE ? 0 : result_failure();
}

int32_t minna_openssl_tls_poll(void* value, minna_openssl_poll_output* output) {
    minna_openssl_tls* context = value;
    if (context == NULL || context->ssl == NULL || output == NULL) return 1;
    const int result = SSL_do_handshake(context->ssl);
    if (result == 1) {
        output->state = MINNA_TLS_CONNECTED;
        output->alert = 0;
        output->work_completed = 1;
        return 0;
    }
    const int error = SSL_get_error(context->ssl, result);
    if (error == SSL_ERROR_WANT_READ || error == SSL_ERROR_WANT_WRITE) {
        output->state = MINNA_TLS_HANDSHAKING;
        output->alert = 0;
        output->work_completed = 0;
        return 0;
    }
    output->state = MINNA_TLS_FAILED;
    output->alert = 80;
    output->work_completed = 0;
    return result_failure();
}

int32_t minna_openssl_tls_receive_record(void* value, const uint8_t* input, size_t input_len, minna_openssl_record_output* output) {
    minna_openssl_tls* context = value;
    if (context == NULL || context->ssl == NULL || (input_len != 0 && input == NULL) || input_len > INT_MAX) return 1;
    const int written = BIO_write(SSL_get_rbio(context->ssl), input, (int)input_len);
    if (written < 0 || (size_t)written != input_len) return result_failure();
    return set_result(output, (size_t)written);
}

int32_t minna_openssl_tls_drain_record(void* value, uint8_t* output, size_t output_len, minna_openssl_record_output* result) {
    minna_openssl_tls* context = value;
    if (context == NULL || context->ssl == NULL || result == NULL || (output_len != 0 && output == NULL) || output_len > INT_MAX) return 1;
    const int read = BIO_read(SSL_get_wbio(context->ssl), output, (int)output_len);
    if (read == -1) return set_result(result, 0);
    if (read < 0) return result_failure();
    return set_result(result, (size_t)read);
}

int32_t minna_openssl_tls_encrypt(void* value, const uint8_t* input, size_t input_len, uint8_t* output, size_t output_len, minna_openssl_record_output* result) {
    minna_openssl_tls* context = value;
    if (context == NULL || context->ssl == NULL || result == NULL || (input_len != 0 && input == NULL) || input_len > INT_MAX) return 1;
    size_t written = 0;
    if (SSL_write_ex(context->ssl, input, input_len, &written) != 1 || written != input_len) return result_failure();
    return minna_openssl_tls_drain_record(context, output, output_len, result);
}

int32_t minna_openssl_tls_decrypt(void* value, const uint8_t* input, size_t input_len, uint8_t* output, size_t output_len, minna_openssl_record_output* result) {
    minna_openssl_tls* context = value;
    if (context == NULL || context->ssl == NULL || result == NULL || (input_len != 0 && input == NULL)) return 1;
    if (input_len != 0 && minna_openssl_tls_receive_record(context, input, input_len, result) != 0) return 14;
    size_t read = 0;
    const int read_result = SSL_read_ex(context->ssl, output, output_len, &read);
    if (read_result == 1) return set_result(result, read);
    const int error = SSL_get_error(context->ssl, read_result);
    if (error == SSL_ERROR_WANT_READ || error == SSL_ERROR_WANT_WRITE) return set_result(result, 0);
    return result_failure();
}

int32_t minna_openssl_tls_selected_alpn(void* value, uint8_t* output, size_t output_len, minna_openssl_record_output* result) {
    minna_openssl_tls* context = value;
    if (context == NULL || context->ssl == NULL || result == NULL) return 1;
    const unsigned char* selected = NULL;
    unsigned int selected_len = 0;
    SSL_get0_alpn_selected(context->ssl, &selected, &selected_len);
    if (selected_len > output_len || (selected_len != 0 && output == NULL)) return 4;
    if (selected_len != 0) memcpy(output, selected, selected_len);
    return set_result(result, selected_len);
}
