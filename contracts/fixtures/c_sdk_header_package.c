#include "minna_san.h"
#include "minna_san_sdk_metadata.h"

_Static_assert(MINNA_SAN_SDK_ABI_VERSION == MINNA_SAN_ABI_VERSION, "ABI version marker mismatch");
_Static_assert(sizeof(MINNA_SAN_SDK_VERSION) > 1, "SDK version marker missing");

int main(void) {
    return minna_san_abi_supports_version(MINNA_SAN_SDK_ABI_VERSION) == 1u ? 0 : 1;
}
