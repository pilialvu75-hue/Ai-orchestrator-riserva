#ifndef LLAMA_BRIDGE_H
#define LLAMA_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

void llb_init_backend(void);

int64_t llb_create_session(
    const char* model_path,
    int32_t n_ctx,
    int32_t n_threads
);

int32_t llb_session_start_gen(
    int64_t session_id,
    const char* prompt,
    int32_t max_tokens,
    float temperature
);

int32_t llb_session_poll_token(
    int64_t session_id,
    char* buf,
    int32_t buf_size
);

void llb_session_cancel(int64_t session_id);

void llb_release_session(int64_t session_id);

int32_t llb_session_is_active(int64_t session_id);

const char* llb_session_last_error(int64_t session_id);

#ifdef __cplusplus
}
#endif

#endif  // LLAMA_BRIDGE_H
