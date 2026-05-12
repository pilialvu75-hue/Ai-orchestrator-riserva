/**
 * llama_bridge.h
 *
 * Thin C API that wraps llama.cpp for easy Dart FFI consumption on Android.
 *
 * Design principles
 * ─────────────────
 * • No struct-by-value arguments or return values — all llama.cpp structs
 *   are hidden behind opaque global state so Dart bindings stay simple.
 * • Non-blocking generation via a POSIX background thread + mutex-guarded
 *   ring buffer.  Dart polls llb_poll_token() from its async event loop.
 * • Single-model, single-session design: load one model at a time.
 *
 * Thread safety
 * ─────────────
 * All API functions are safe to call from a single Dart isolate.
 * llb_poll_token() and llb_cancel() may be called concurrently with the
 * background generation thread — the implementation uses a mutex.
 */

#ifndef LLAMA_BRIDGE_H
#define LLAMA_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * llb_load_model
 *
 * Loads the GGUF model at [model_path] into a new llama context.
 * Any previously loaded model is freed first.
 *
 * @param model_path   Absolute path to the .gguf file.
 * @param n_ctx        Context window size in tokens (e.g. 2048).
 * @param n_threads    Number of CPU threads for inference.
 *
 * @return  0 on success.
 *         -1 if model loading fails.
 *         -2 if context creation fails.
 */
int32_t llb_load_model(const char* model_path, int32_t n_ctx, int32_t n_threads);

/**
 * llb_start_gen
 *
 * Tokenises [prompt] and starts asynchronous token generation in a
 * background POSIX thread.  Tokens are queued for retrieval via
 * llb_poll_token().
 *
 * Must be called after a successful llb_load_model().
 *
 * @param prompt      Null-terminated UTF-8 prompt string.
 * @param max_tokens  Maximum number of tokens to generate.
 * @param temperature Sampling temperature (0.0 – 2.0).
 *
 * @return  0 on success.
 *         -1 if no model is loaded.
 *         -2 if tokenisation fails.
 *         -3 if the generation thread cannot be started.
 */
int32_t llb_start_gen(const char* prompt, int32_t max_tokens, float temperature);

/**
 * llb_poll_token
 *
 * Non-blocking poll for the next generated token piece.
 *
 * @param buf       Output buffer for the null-terminated UTF-8 token piece.
 * @param buf_size  Size of [buf] in bytes (must be >= 1).
 *
 * @return
 *   1   Token available; piece written to [buf].
 *   2   Generation finished (EOS or max_tokens reached); [buf] not written.
 *   0   No token ready yet; caller should yield and retry.
 *  -1   Generation error; call llb_last_error() for details.
 * -99   Generation was cancelled via llb_cancel().
 */
int32_t llb_poll_token(char* buf, int32_t buf_size);

/**
 * llb_cancel
 *
 * Signals the background generation thread to stop at the next opportunity.
 * Safe to call from any thread.
 */
void llb_cancel(void);

/**
 * llb_free_model
 *
 * Frees the loaded model and context, releasing all native memory.
 * Blocks until any running generation thread has finished.
 */
void llb_free_model(void);

/**
 * llb_last_error
 *
 * Returns the last error string emitted by the bridge, or an empty string
 * if no error has occurred.  The returned pointer is valid until the next
 * bridge API call.
 */
const char* llb_last_error(void);

/**
 * llb_is_loaded
 *
 * @return 1 if a model is currently loaded, 0 otherwise.
 */
int32_t llb_is_loaded(void);

#ifdef __cplusplus
}
#endif

#endif /* LLAMA_BRIDGE_H */
