#ifndef LLAMA_BRIDGE_H
#define LLAMA_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

void llb_init_backend(void);

const char* llb_gpu_backend_name(void);

const char* llb_gpu_backend_reason(void);

int64_t llb_create_session(
    const char* model_path,
    int32_t n_ctx,
    int32_t n_threads,
    int32_t n_gpu_layers
);

// Extended ABI keeps the original entrypoint available for older callers.
int64_t llb_create_session_ex(const char* model_path, int32_t n_ctx,
    int32_t n_threads, int32_t n_gpu_layers, int32_t n_batch, int32_t n_ubatch);
// 0=context, 1=batch, 2=microbatch, 3=observed offloaded layers,
// 4=successful decode calls (CPU or GPU), 5=reused prompt/KV tokens,
// 6=prefilled prompt tokens. Unknown/session absent returns -1.
int64_t llb_session_metric(int64_t session_id, int32_t metric);

// Exact llama.cpp token count using the vocabulary of an already-loaded
// RuntimeSession. Returns a non-negative token count or a negative error code.
int32_t llb_session_token_count(
    int64_t session_id,
    const char* text
);

int32_t llb_session_start_gen(
    int64_t session_id,
    const char* prompt,
    int32_t max_tokens,
    float temperature
);

// Scoped generation enables conservative KV-prefix reuse. cache_scope must be
// a stable logical conversation/session id. Empty/null scope always cold-prefills.
int32_t llb_session_start_gen_scoped(
    int64_t session_id,
    const char* prompt,
    const char* cache_scope,
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

// Unlike is_active (loaded resources), this reports a scheduled/running worker.
int32_t llb_session_is_generating(int64_t session_id);

const char* llb_session_last_error(int64_t session_id);

#ifdef __cplusplus
}
#endif

#endif  // LLAMA_BRIDGE_H
