#include <stdint.h>
// Return a deterministic signature to verify all FFI arguments cross the isolate.
int64_t llb_create_session_ex(const char* path, int32_t ctx, int32_t threads,
                            int32_t gpu, int32_t batch, int32_t micro) {
    if (!path || path[0] != 'm' || threads != 2 || gpu != 0) return -1;
    return (int64_t)ctx * 1000000 + batch * 1000 + micro;
}
