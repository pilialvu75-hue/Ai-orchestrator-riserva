/**
 * llama_bridge.cpp
 *
 * Implementation of the llama_bridge.h C API.
 *
 * Compilation
 * ───────────
 * Link against llama.cpp (third_party/llama.cpp) built as a shared or
 * static library.  See native/android/CMakeLists.txt for the full build
 * configuration.
 *
 * Architecture
 * ─────────────
 * llb_start_gen spawns a POSIX background thread that runs the llama.cpp
 * decode loop.  Each generated token piece is pushed into a fixed-size ring
 * buffer protected by a mutex + condition variable.  Dart calls
 * llb_poll_token() from its async event loop (with a Future.delayed(Duration.zero)
 * yield between polls) to drain the buffer without blocking the UI thread.
 *
 * Status codes written to g_gen_state communicate EOS, cancellation, and
 * error conditions to the polling side.
 *
 * Thread-safety notes
 * ────────────────────
 * llb_free_model() MUST NOT block the caller (Dart main isolate / UI thread).
 * On Android, llama_decode() can take many seconds under thermal throttling.
 * If the Dart-side stall watchdog fires and calls freeModel() while the
 * native thread is still inside llama_decode(), a naive join() would freeze
 * the Flutter event loop indefinitely.
 *
 * Fix: llb_free_model() immediately moves the generation thread and the
 * model/context pointers into a detached background "cleanup thread" and
 * returns to the caller instantly.  The cleanup thread performs the join
 * and frees the resources when the generation thread actually exits.
 *
 * llama_backend_init() is intentionally NOT paired with llama_backend_free()
 * inside llb_free_model() because the cleanup thread may race with the next
 * llb_load_model() call that re-initialises the backend.  The backend is
 * process-lifetime state; Android reclaims all memory on process exit.
 */

#include "llama_bridge.h"
#include "llama.h"

#include <android/log.h>
#include <atomic>
#include <chrono>
#include <cinttypes>
#include <cstring>
#include <mutex>
#include <condition_variable>
#include <thread>
#include <string>
#include <vector>
#include <queue>
#include <algorithm>
#include <new>
#include <sys/stat.h>
#include <unistd.h>

#define LOG_TAG "AI_RUNTIME"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

// ── Global state ──────────────────────────────────────────────────────────────

static llama_model*   g_model   = nullptr;
static llama_context* g_ctx     = nullptr;
static std::string    g_last_error;

// ── Token ring buffer ─────────────────────────────────────────────────────────

static constexpr size_t kRingCapacity = 256;

// Each token entry carries the epoch of the generation that produced it.
// llb_poll_token discards entries whose epoch does not match the current
// g_gen_epoch, preventing stale tokens from a previous (cancelled or timed-out)
// generation from contaminating the next inference run.
struct RingEntry {
    std::string piece;
    uint64_t    epoch;
};

struct TokenRing {
    std::queue<RingEntry> items;
    std::mutex mtx;
    std::condition_variable cv;
};

static TokenRing g_ring;

// Generation state values:
//   0  generating
//   1  done (EOS / max_tokens)
//   2  cancelled
//  -1  error
static std::atomic<int>      g_gen_state{0};
static std::atomic<bool>     g_cancel_flag{false};

// Monotonically-increasing generation epoch.  Incremented on every
// llb_start_gen() call.  Generation threads embed their epoch in every ring
// push and in every g_gen_state update so that stale threads cannot corrupt
// a subsequent inference run.
static std::atomic<uint64_t> g_gen_epoch{0};

// Set to true once the generation thread exits (or was never started).
// Used for a non-blocking "is the thread done?" check without calling join().
static std::atomic<bool> g_gen_finished{true};

static std::thread g_gen_thread;

static constexpr int32_t kSafeNBatch              = 32;
static constexpr int32_t kGenerationTimeoutMillis  = 180000;
static constexpr int32_t kNoTokenStallMillis        = 45000;
static constexpr int32_t kMaxGeneratedTokens        = 256;
static constexpr int32_t kRepeatedTokenLimit        = 96;
static constexpr int32_t kEmptyTokenLimit           = 32;

// Maximum time llb_start_gen will spin-wait for a previous thread to finish
// before forcibly detaching it.
static constexpr int32_t kStartGenPrevThreadTimeoutMillis = 2000;

static void set_error(const char* msg) {
    g_last_error = msg ? msg : "";
    LOGE("[AI] runtime error: %s", g_last_error.c_str());
}

// Push a token piece into the ring buffer tagged with the calling generation's
// epoch so that llb_poll_token can discard stale entries.
static void push_token(const std::string& piece, uint64_t epoch) {
    {
        std::unique_lock<std::mutex> lock(g_ring.mtx);
        // Drop oldest token if ring is exactly full to avoid unbounded memory use.
        while (g_ring.items.size() == kRingCapacity) {
            g_ring.items.pop();
        }
        g_ring.items.push({piece, epoch});
    }
    g_ring.cv.notify_one();
}

// ── Epoch-safe generation-state helpers ───────────────────────────────────────
//
// A stale generation thread (one that has been superseded by a newer
// llb_start_gen() call but has not yet been joined/detached) must not
// overwrite g_gen_state with its own terminal status.  These helpers gate
// every state write on a current-epoch check so that only the active thread
// can transition the shared state machine.

static void gen_update_state(int new_state, uint64_t my_epoch) {
    if (g_gen_epoch.load(std::memory_order_relaxed) == my_epoch) {
        g_gen_state.store(new_state, std::memory_order_release);
    }
}

static void gen_mark_finished(uint64_t my_epoch) {
    if (g_gen_epoch.load(std::memory_order_relaxed) == my_epoch) {
        g_gen_finished.store(true, std::memory_order_release);
    }
}

// ── Generation thread ─────────────────────────────────────────────────────────

struct GenArgs {
    std::string prompt;
    int32_t     max_tokens;
    float       temperature;
    uint64_t    epoch;   // generation epoch; used to gate state updates
    llama_model* model;
    llama_context* ctx;
};

static void generation_thread(GenArgs args) {
    // Capture the generation epoch for all state-update guards in this thread.
    const uint64_t my_epoch = args.epoch;
    // ── Diagnostics: thread start ────────────────────────────────────────────
    LOGI("[THREAD] generation thread started (epoch=%" PRIu64 ")", my_epoch);
    LOGI("[GENERATION_START] epoch=%" PRIu64 " prompt_chars=%zu max_tokens=%d temp=%.3f",
         my_epoch,
         args.prompt.size(),
         static_cast<int>(args.max_tokens),
         static_cast<double>(args.temperature));

    try {
    // Obtain the vocabulary from the model (modern API).
    const llama_vocab* vocab = llama_model_get_vocab(args.model);
    if (!vocab) {
        LOGE("[THREAD] vocabulary is null — aborting");
        set_error("Vocabulary unavailable");
        gen_update_state(-1, my_epoch);
        gen_mark_finished(my_epoch);
        LOGI("[THREAD] generation thread exited (vocab null)");
        return;
    }
    LOGI("[THREAD] vocabulary obtained ok");

    // Tokenise the prompt.
    const int n_ctx = llama_n_ctx(args.ctx);
    LOGI("[THREAD] tokenization start: prompt_chars=%zu n_ctx=%d",
         args.prompt.size(), n_ctx);
    std::vector<llama_token> tokens(n_ctx);

    int n_tokens = llama_tokenize(
        vocab,
        args.prompt.c_str(),
        static_cast<int32_t>(args.prompt.length()),
        tokens.data(),
        static_cast<int32_t>(tokens.size()),
        /*add_special=*/true,
        /*parse_special=*/false
    );

    if (n_tokens < 0) {
        LOGE("[THREAD] tokenisation failed (error %d)", n_tokens);
        set_error("Tokenisation failed");
        LOGE("[GENERATION_ERROR] stage=tokenize reason=tokenisation_failed code=%d", n_tokens);
        gen_update_state(-1, my_epoch);
        gen_mark_finished(my_epoch);
        LOGI("[THREAD] generation thread exited (tokenise error)");
        return;
    }
    if (n_tokens == 0) {
        LOGE("[THREAD] tokenisation returned zero tokens");
        set_error("Tokenisation returned zero tokens");
        LOGE("[GENERATION_ERROR] stage=tokenize reason=token_count_zero");
        gen_update_state(-1, my_epoch);
        gen_mark_finished(my_epoch);
        LOGI("[THREAD] generation thread exited (zero tokens)");
        return;
    }
    tokens.resize(n_tokens);
    LOGI("[TOKEN_COUNT] count=%d", n_tokens);
    LOGI("[TOKENIZER_OK] prompt_tokenization=true");
    LOGI("[THREAD] prompt token count: %d", n_tokens);

    // Prefill: decode the prompt batch.
    // Clear memory (KV cache) before starting a new generation.
    LOGI("[THREAD] clearing KV cache");
    LOGI("[KV_CACHE] action=clear scope=context");
    llama_memory_clear(llama_get_memory(args.ctx), /*data=*/true);

    llama_batch batch = llama_batch_init(
        static_cast<int32_t>(tokens.size()),
        /*embd=*/0,
        /*n_seq_max=*/1
    );
    if (!batch.token || !batch.pos || !batch.n_seq_id || !batch.seq_id || !batch.logits) {
        LOGE("[THREAD] OOM: prefill batch allocation failed");
        set_error("Out of memory while allocating prefill batch");
        gen_update_state(-1, my_epoch);
        gen_mark_finished(my_epoch);
        LOGI("[THREAD] generation thread exited (OOM prefill batch)");
        return;
    }

    for (int32_t i = 0; i < static_cast<int32_t>(tokens.size()); ++i) {
        batch.token   [i]    = tokens[i];
        batch.pos     [i]    = i;
        batch.n_seq_id[i]    = 1;
        batch.seq_id  [i][0] = 0;
        // Only request logits for the last prompt token.
        batch.logits  [i]    = (i == static_cast<int32_t>(tokens.size()) - 1) ? 1 : 0;
    }
    batch.n_tokens = static_cast<int32_t>(tokens.size());

    LOGI("[THREAD] starting prefill decode for %d prompt tokens", n_tokens);
    LOGI("[PROMPT_EVAL] stage=start prompt_tokens=%d", n_tokens);
    const auto prompt_eval_start = std::chrono::steady_clock::now();
    const int prefill_decode_status = llama_decode(args.ctx, batch);
    const auto prompt_eval_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - prompt_eval_start
    ).count();
    LOGI("[THREAD] prefill decode status: %d", prefill_decode_status);
    LOGI("[PROMPT_EVAL] stage=end status=%d elapsed_ms=%lld",
         prefill_decode_status, static_cast<long long>(prompt_eval_ms));
    if (prefill_decode_status != 0) {
        llama_batch_free(batch);
        LOGE("[THREAD] prefill decode failed with status %d", prefill_decode_status);
        set_error("Decode failed during prompt prefill");
        gen_update_state(-1, my_epoch);
        gen_mark_finished(my_epoch);
        LOGI("[THREAD] generation thread exited (prefill decode error)");
        return;
    }
    llama_batch_free(batch);
    LOGI("[THREAD] prefill decode complete");

    // Check cancel before entering the generation loop.
    if (g_cancel_flag.load()) {
        LOGI("[THREAD] cancelled before generation loop");
        gen_update_state(2, my_epoch);
        gen_mark_finished(my_epoch);
        LOGI("[THREAD] generation thread exited (pre-loop cancel)");
        return;
    }

    // Build sampler chain.
    LOGI("[THREAD] creating sampler chain (temp=%.3f)", static_cast<double>(args.temperature));
    llama_sampler_chain_params sparams = llama_sampler_chain_default_params();
    llama_sampler* sampler = llama_sampler_chain_init(sparams);
    if (!sampler) {
        LOGE("[THREAD] OOM: sampler chain allocation failed");
        set_error("Out of memory while creating sampler");
        gen_update_state(-1, my_epoch);
        gen_mark_finished(my_epoch);
        LOGI("[THREAD] generation thread exited (OOM sampler)");
        return;
    }
    llama_sampler_chain_add(sampler, llama_sampler_init_temp(args.temperature));
    // A final token-selecting sampler is required: llama_sampler_sample()
    // initialises cur_p.selected = -1 before calling the chain; without a
    // selector the field is never set, causing UB in NDEBUG builds (accessing
    // cur_p.data[-1]) and an assertion failure in debug builds.  Using
    // llama_sampler_init_dist instead of greedy lets temperature > 0 produce
    // varied output while still converging to greedy selection at temp = 0.
    llama_sampler_chain_add(sampler, llama_sampler_init_dist(LLAMA_DEFAULT_SEED));
    LOGI("[THREAD] sampler chain created (temp + dist)");

    // Decode loop.
    int32_t n_cur    = static_cast<int32_t>(tokens.size());
    int32_t n_decode = 0;
    int32_t iteration = 0;
    char    piece_buf[256];
    llama_token last_token = static_cast<llama_token>(-1);
    int repeated_token_count = 0;
    int empty_token_count = 0;
    bool eos_detected = false;
    const auto generation_start = std::chrono::steady_clock::now();
    auto last_token_time = generation_start;
    const int32_t capped_max_tokens = std::min(args.max_tokens, kMaxGeneratedTokens);
    LOGI("[THREAD] inference loop start: requested_max=%d capped_max=%d",
         args.max_tokens, capped_max_tokens);

    while (n_decode < capped_max_tokens) {
        iteration++;
        const auto now = std::chrono::steady_clock::now();
        const auto elapsed_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
            now - generation_start
        ).count();
        const auto since_last_token_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
            now - last_token_time
        ).count();

        if (iteration % 8 == 1) {
            // Log every 8 iterations to avoid flooding logcat.
            LOGI("[THREAD] loop iteration=%d tokens=%d elapsed_ms=%lld since_last_ms=%lld",
                 static_cast<int>(iteration),
                 static_cast<int>(n_decode),
                 static_cast<long long>(elapsed_ms),
                 static_cast<long long>(since_last_token_ms));
            LOGI("[GENERATION_STEP] iteration=%d generated_tokens=%d elapsed_ms=%lld since_last_ms=%lld",
                 static_cast<int>(iteration),
                 static_cast<int>(n_decode),
                 static_cast<long long>(elapsed_ms),
                 static_cast<long long>(since_last_token_ms));
        }

        if (elapsed_ms >= kGenerationTimeoutMillis) {
            LOGE("[THREAD] generation timeout at %lld ms (limit: %d ms) — aborting",
                 static_cast<long long>(elapsed_ms), kGenerationTimeoutMillis);
            set_error("Generation timeout");
            llama_sampler_free(sampler);
            gen_update_state(-1, my_epoch);
            gen_mark_finished(my_epoch);
            LOGI("[THREAD] generation thread exited (generation timeout)");
            return;
        }
        if (n_decode == 0 && since_last_token_ms >= kNoTokenStallMillis) {
            LOGE("[THREAD] no-first-token stall after %lld ms (limit: %d ms) — aborting",
                 static_cast<long long>(since_last_token_ms), kNoTokenStallMillis);
            LOGE("[FIRST_TOKEN_TIMEOUT] waited_ms=%lld timeout_ms=%d",
                 static_cast<long long>(since_last_token_ms), kNoTokenStallMillis);
            set_error("Local model stalled during inference.");
            llama_sampler_free(sampler);
            gen_update_state(-1, my_epoch);
            gen_mark_finished(my_epoch);
            LOGI("[THREAD] generation thread exited (stall timeout)");
            return;
        }
        if (g_cancel_flag.load()) {
            LOGI("[THREAD] cancel flag set — stopping generation loop at iteration=%d",
                 static_cast<int>(iteration));
            llama_sampler_free(sampler);
            gen_update_state(2, my_epoch);  // cancelled
            gen_mark_finished(my_epoch);
            LOGI("[THREAD] generation thread exited (cancelled)");
            return;
        }

        // Sample next token.
        llama_token new_tok = llama_sampler_sample(sampler, args.ctx, -1);
        if (new_tok < 0) {
            LOGE("[THREAD] invalid token sampled: %d at iteration=%d",
                 static_cast<int>(new_tok), static_cast<int>(iteration));
            set_error("Invalid generated token");
            llama_sampler_free(sampler);
            gen_update_state(-1, my_epoch);
            gen_mark_finished(my_epoch);
            LOGI("[THREAD] generation thread exited (invalid sample)");
            return;
        }
        LOGI("[THREAD] sampled token_id=%d iteration=%d",
             static_cast<int>(new_tok), static_cast<int>(iteration));
        LOGI("[TOKEN_ID] token_id=%d iteration=%d", static_cast<int>(new_tok), static_cast<int>(iteration));
        llama_sampler_accept(sampler, new_tok);

        if (new_tok == last_token) {
            repeated_token_count++;
            if (repeated_token_count >= kRepeatedTokenLimit) {
                LOGE("[THREAD] repeated-token loop: token=%d count=%d — aborting",
                     static_cast<int>(new_tok), repeated_token_count);
                set_error("Repeated token loop detected");
                llama_sampler_free(sampler);
                gen_update_state(-1, my_epoch);
                gen_mark_finished(my_epoch);
                LOGI("[THREAD] generation thread exited (repeated token loop)");
                return;
            }
        } else {
            last_token = new_tok;
            repeated_token_count = 0;
        }

        if (llama_vocab_is_eog(vocab, new_tok)) {
            LOGI("[THREAD] EOS token detected after %d tokens (iteration=%d) — done",
                 n_decode, static_cast<int>(iteration));
            eos_detected = true;
            break;
        }

        // Convert token to UTF-8 text piece.
        int32_t piece_len = llama_token_to_piece(
            vocab, new_tok,
            piece_buf, static_cast<int32_t>(sizeof(piece_buf)) - 1,
            /*lstrip=*/0,
            /*special=*/false
        );

        if (piece_len > 0) {
            piece_buf[piece_len] = '\0';
            LOGI("[AI] token received: %s", piece_buf);
            LOGI("[THREAD] decoded token_id=%d text=\"%s\" len=%d total_decoded=%d",
                 static_cast<int>(new_tok), piece_buf,
                 static_cast<int>(piece_len), n_decode + 1);
            LOGI("[TOKEN_DECODE] token_id=%d len=%d text=\"%s\"",
                 static_cast<int>(new_tok), static_cast<int>(piece_len), piece_buf);
            LOGI("[TOKEN_EMIT] token_id=%d len=%d", static_cast<int>(new_tok), static_cast<int>(piece_len));
            push_token(std::string(piece_buf, piece_len), my_epoch);
            last_token_time = std::chrono::steady_clock::now();
            empty_token_count = 0;
        } else if (piece_len < 0) {
            LOGE("[THREAD] token-to-piece conversion error for token=%d",
                 static_cast<int>(new_tok));
            set_error("Invalid generated token piece");
            LOGE("[TOKENIZER_DECODE_FAIL] token_id=%d", static_cast<int>(new_tok));
            LOGE("[GENERATION_ERROR] stage=token_decode reason=token_to_piece_failed");
            llama_sampler_free(sampler);
            gen_update_state(-1, my_epoch);
            gen_mark_finished(my_epoch);
            LOGI("[THREAD] generation thread exited (piece conversion error)");
            return;
        } else {
            // piece_len == 0: special token with no visible text (e.g., role
            // boundary tokens in Llama 3, Qwen thinking control tokens).
            // Allow a limited run before treating it as a stall.
            empty_token_count++;
            LOGI("[THREAD] empty piece for token_id=%d consecutive_empty=%d",
                 static_cast<int>(new_tok), empty_token_count);
            if (empty_token_count >= kEmptyTokenLimit) {
                LOGE("[THREAD] empty-token limit reached (%d) — aborting", kEmptyTokenLimit);
                set_error("Empty token loop detected");
                llama_sampler_free(sampler);
                gen_update_state(-1, my_epoch);
                gen_mark_finished(my_epoch);
                LOGI("[THREAD] generation thread exited (empty token loop)");
                return;
            }
        }

        // Decode the newly generated token.
        llama_batch step = llama_batch_init(1, 0, 1);
        if (!step.token || !step.pos || !step.n_seq_id || !step.seq_id || !step.logits) {
            LOGE("[THREAD] OOM: step batch allocation failed at iteration=%d",
                 static_cast<int>(iteration));
            set_error("Out of memory while allocating decode batch");
            llama_sampler_free(sampler);
            gen_update_state(-1, my_epoch);
            gen_mark_finished(my_epoch);
            LOGI("[THREAD] generation thread exited (OOM step batch)");
            return;
        }
        step.token   [0]    = new_tok;
        step.pos     [0]    = n_cur;
        step.n_seq_id[0]    = 1;
        step.seq_id  [0][0] = 0;
        step.logits  [0]    = 1;
        step.n_tokens       = 1;

        const int decode_status = llama_decode(args.ctx, step);
        LOGI("[TOKEN_EVAL] token_index=%d status=%d",
             static_cast<int>(n_decode + 1), decode_status);
        LOGI("[THREAD] step decode status=%d token_id=%d pos=%d",
             decode_status, static_cast<int>(new_tok), static_cast<int>(n_cur));
        if (decode_status != 0) {
            llama_batch_free(step);
            LOGE("[THREAD] step decode failed (status=%d) at token %d",
                 decode_status, n_decode);
            set_error("Decode failed during token generation");
            llama_sampler_free(sampler);
            gen_update_state(-1, my_epoch);
            gen_mark_finished(my_epoch);
            LOGI("[THREAD] generation thread exited (step decode error)");
            return;
        }
        llama_batch_free(step);

        n_cur++;
        n_decode++;
    }

    if (eos_detected) {
        LOGI("[THREAD] generation complete (EOS): %d tokens generated", n_decode);
    } else {
        LOGI("[THREAD] generation complete (max tokens): %d tokens generated", n_decode);
    }
    LOGI("[GENERATION_END] state=success generated_tokens=%d eos=%s",
         static_cast<int>(n_decode),
         eos_detected ? "true" : "false");
    LOGI("[AI] inference completed");
    llama_sampler_free(sampler);
    gen_update_state(1, my_epoch);  // done
    } catch (const std::bad_alloc&) {
        LOGE("[THREAD] std::bad_alloc in generation thread");
        set_error("Out of memory during generation");
        LOGE("[GENERATION_ERROR] stage=generation_thread reason=bad_alloc");
        gen_update_state(-1, my_epoch);
    } catch (const std::exception& e) {
        LOGE("[THREAD] unhandled exception: %s", e.what());
        set_error(e.what());
        LOGE("[GENERATION_ERROR] stage=generation_thread reason=exception message=%s", e.what());
        gen_update_state(-1, my_epoch);
    } catch (...) {
        LOGE("[THREAD] unhandled unknown exception");
        set_error("Unhandled generation exception");
        LOGE("[GENERATION_ERROR] stage=generation_thread reason=unknown_exception");
        gen_update_state(-1, my_epoch);
    }

    gen_mark_finished(my_epoch);
    LOGI("[THREAD] generation thread exited (end of function)");
}

// ── Public API ────────────────────────────────────────────────────────────────

extern "C" {

int32_t llb_load_model(const char* model_path, int32_t n_ctx, int32_t n_threads) {
    LOGI("[AI] loading model...");
    LOGI("[LOAD] model path=%s n_ctx=%d n_threads=%d",
         model_path ? model_path : "(null)", n_ctx, n_threads);
    LOGI("[NATIVE_MODEL_LOAD_BEGIN] path=%s n_ctx=%d n_threads=%d",
         model_path ? model_path : "(null)", n_ctx, n_threads);
    if (!model_path || std::strlen(model_path) == 0) {
        set_error("Model path is empty");
        LOGE("[LOAD] failed: empty path");
        LOGE("[NATIVE_MODEL_LOAD_RESULT] code=-3");
        LOGE("[NATIVE_MODEL_LOAD_FAILURE] code=-3 reason=empty_model_path");
        return -3;
    }

    struct stat model_stat;
    const bool model_exists = stat(model_path, &model_stat) == 0;
    const bool model_readable = access(model_path, R_OK) == 0;
    const int64_t model_size = model_exists ? static_cast<int64_t>(model_stat.st_size) : -1;
    LOGI("[MODEL_PATH] path=%s", model_path);
    LOGI("[MODEL_EXISTS] path=%s exists=%s", model_path, model_exists ? "true" : "false");
    LOGI("[MODEL_SIZE] path=%s size_bytes=%" PRId64, model_path, model_size);
    LOGI("[MODEL_READABLE] path=%s readable=%s", model_path, model_readable ? "true" : "false");

    // Free any previously loaded model (non-blocking via cleanup thread).
    llb_free_model();

    llama_backend_init();

    llama_model_params mparams = llama_model_default_params();
    mparams.n_gpu_layers = 0;  // CPU-only; GPU (Vulkan/OpenCL) can be enabled
                               // by setting n_gpu_layers > 0 when the ggml
                               // backend is compiled with GPU support.

    LOGI("[LOAD] calling llama_model_load_from_file");
    g_model = llama_model_load_from_file(model_path, mparams);
    if (!g_model) {
        LOGE("[LOAD] llama_model_load_from_file failed: %s", model_path);
        set_error("Failed to load model from file (invalid/corrupted model or out of memory)");
        LOGE("[NATIVE_MODEL_LOAD_RESULT] code=-1");
        LOGE("[NATIVE_MODEL_LOAD_FAILURE] code=-1 reason=llama_model_load_from_file_failed");
        return -1;
    }
    LOGI("[AI] model loaded");
    LOGI("[LOAD] model loaded successfully: %s", model_path);

    LOGI("[AI] creating context...");
    llama_context_params cparams = llama_context_default_params();
    cparams.n_ctx            = static_cast<uint32_t>(n_ctx);
    cparams.n_threads        = n_threads;
    cparams.n_threads_batch  = n_threads;
    cparams.n_batch          = kSafeNBatch;
    cparams.n_ubatch         = kSafeNBatch;
    cparams.embeddings       = false;

    LOGI("[NATIVE_CONTEXT_CREATE] path=%s n_ctx=%d n_threads=%d n_batch=%d",
         model_path, n_ctx, n_threads, kSafeNBatch);
    LOGI("[LOAD] calling llama_init_from_model: n_ctx=%d n_batch=%d n_threads=%d",
         n_ctx, kSafeNBatch, n_threads);
    g_ctx = llama_init_from_model(g_model, cparams);
    if (!g_ctx) {
        LOGE("[LOAD] llama_init_from_model failed");
        set_error("Failed to create llama context (out of memory or incompatible model)");
        LOGE("[NATIVE_CONTEXT_FAILURE] path=%s reason=llama_init_from_model_failed", model_path);
        LOGE("[NATIVE_MODEL_LOAD_RESULT] code=-2");
        LOGE("[NATIVE_MODEL_LOAD_FAILURE] code=-2 reason=context_creation_failed");
        llama_model_free(g_model);
        g_model = nullptr;
        return -2;
    }
    LOGI("[AI] context ready");
    LOGI("[LOAD] context created: n_ctx=%d n_batch=%d gpu_layers=%d",
         n_ctx, kSafeNBatch, mparams.n_gpu_layers);

    g_last_error.clear();
    LOGI("[NATIVE_MODEL_LOAD_RESULT] code=0");
    LOGI("[NATIVE_MODEL_LOAD_SUCCESS] path=%s", model_path);
    return 0;
}

int32_t llb_start_gen(const char* prompt, int32_t max_tokens, float temperature) {
    if (!g_model || !g_ctx) {
        set_error("No model loaded");
        return -1;
    }

    // If a previous generation thread is still joinable (edge case: llb_start_gen
    // called without an intervening llb_free_model), spin-wait briefly with a
    // timeout and detach if the thread does not finish in time.  This prevents
    // blocking the caller when the thread is stuck inside llama_decode.
    // NOTE: In the normal flow, llb_load_model calls llb_free_model which moves
    // g_gen_thread into a cleanup thread, so g_gen_thread will not be joinable here.
    if (g_gen_thread.joinable()) {
        g_cancel_flag.store(true);
        LOGI("[START_GEN] previous thread still joinable — spin-waiting up to %d ms",
             kStartGenPrevThreadTimeoutMillis);
        bool prev_detached = false;
        const auto deadline = std::chrono::steady_clock::now() +
                              std::chrono::milliseconds(kStartGenPrevThreadTimeoutMillis);
        while (!g_gen_finished.load()) {
            if (std::chrono::steady_clock::now() >= deadline) {
                LOGE("[START_GEN] previous thread did not finish in %d ms — detaching",
                     kStartGenPrevThreadTimeoutMillis);
                g_gen_thread.detach();
                prev_detached = true;
                break;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(25));
        }
        if (!prev_detached && g_gen_thread.joinable()) {
            LOGI("[START_GEN] previous thread finished — joining");
            g_gen_thread.join();
        }
    }

    // Clear ring buffer and reset state.
    // Increment g_gen_epoch BEFORE resetting g_gen_state so that any stale
    // generation thread racing here sees the new epoch and stops updating
    // the shared state machine (see gen_update_state / gen_mark_finished).
    const uint64_t new_epoch = ++g_gen_epoch;
    {
        std::unique_lock<std::mutex> lock(g_ring.mtx);
        while (!g_ring.items.empty()) g_ring.items.pop();
    }
    g_gen_state.store(0);
    g_gen_finished.store(false);
    g_cancel_flag.store(false);
    g_last_error.clear();

    const int32_t capped_max_tokens = std::min(max_tokens, kMaxGeneratedTokens);
    LOGI("[AI] starting inference...");
    LOGI("[AI] streaming callback active");
    LOGI("[START_GEN] epoch=%" PRIu64 " prompt_chars=%zu requested_max=%d capped_max=%d temp=%.3f",
         new_epoch,
         prompt ? std::strlen(prompt) : static_cast<size_t>(0),
         max_tokens, capped_max_tokens,
         static_cast<double>(temperature));
    GenArgs args{
        prompt ? prompt : "",
        capped_max_tokens,
        temperature,
        new_epoch,
        g_model,
        g_ctx
    };

    try {
        g_gen_thread = std::thread(generation_thread, std::move(args));
    } catch (const std::exception& e) {
        g_gen_finished.store(true);
        set_error(e.what());
        LOGE("[START_GEN] failed to spawn generation thread: %s", e.what());
        return -3;
    }

    LOGI("[START_GEN] generation thread spawned (epoch=%" PRIu64 ")", new_epoch);
    return 0;
}

int32_t llb_poll_token(char* buf, int32_t buf_size) {
    if (!buf || buf_size <= 0) {
        set_error("Invalid token buffer");
        return -1;
    }

    // Acquire the ring mutex and hold it through the generation-state check.
    //
    // This closes the EOS-token race: without the combined lock, the sequence
    //   [Dart] ring empty? yes → [Gen] push_token(last) → [Gen] state=1 → [Dart] state==1 → return 2
    // would cause the last token to be lost.  By holding the lock through the
    // state read we guarantee:
    //   • If the gen thread is mid-push_token it is blocked; we see state < 1
    //     and return 0 so the next poll retrieves the token.
    //   • If state == 1 while we hold the lock, all tokens that could ever be
    //     pushed have already been pushed (push_token needs the same lock), so
    //     an empty ring + state==1 correctly means "done, no more tokens".
    std::unique_lock<std::mutex> lock(g_ring.mtx);

    // Discard any stale entries from previous generation epochs.
    const uint64_t cur_epoch = g_gen_epoch.load(std::memory_order_relaxed);
    while (!g_ring.items.empty() && g_ring.items.front().epoch != cur_epoch) {
        g_ring.items.pop();
    }

    if (!g_ring.items.empty()) {
        const RingEntry& entry = g_ring.items.front();
        int32_t copy_len = static_cast<int32_t>(
            std::min(entry.piece.size(), static_cast<size_t>(buf_size - 1)));
        std::memcpy(buf, entry.piece.data(), copy_len);
        buf[copy_len] = '\0';
        g_ring.items.pop();
        return 1;  // token available
    }

    // Ring is empty — check generation state while still holding the ring lock.
    int state = g_gen_state.load(std::memory_order_acquire);
    if (state == 1) return 2;   // done
    if (state == 2) return -99; // cancelled
    if (state == -1) return -1; // error

    return 0;  // still generating; caller should yield and retry
}

void llb_cancel(void) {
    LOGI("[AI] llb_cancel called");
    g_cancel_flag.store(true);
}

void llb_free_model(void) {
    LOGI("[AI] llb_free_model called");
    g_cancel_flag.store(true);

    if (g_gen_thread.joinable()) {
        // ── Non-blocking cleanup ─────────────────────────────────────────────
        //
        // Move the generation thread and the model/context pointers into a
        // detached background "cleanup thread" so that the caller (the Dart
        // main isolate / Flutter event loop) is NEVER blocked by a slow or
        // stalled llama_decode() call inside the generation thread.
        //
        // The cleanup thread performs the join() and then frees the resources
        // once the generation thread actually exits.  The global pointers are
        // nulled immediately so that any subsequent llb_load_model() call sees
        // a clean state and does not double-free.
        //
        // llama_backend_free() is intentionally omitted here — see file header.
        llama_context* ctx_to_free   = g_ctx;
        llama_model*   model_to_free = g_model;
        g_ctx   = nullptr;
        g_model = nullptr;

        std::thread cleanup(
            [gen_thread  = std::move(g_gen_thread),
             ctx_to_free,
             model_to_free]() mutable {
                LOGI("[CLEANUP_THREAD] waiting for generation thread to exit...");
                if (gen_thread.joinable()) {
                    gen_thread.join();
                }
                LOGI("[CLEANUP_THREAD] generation thread joined — freeing model/ctx");
                if (ctx_to_free)   { llama_free(ctx_to_free);        }
                if (model_to_free) { llama_model_free(model_to_free); }
                LOGI("[CLEANUP_THREAD] model/ctx freed — cleanup complete");
            }
        );
        cleanup.detach();

        // NOTE: g_cancel_flag is intentionally NOT cleared here.
        // The old gen thread must see cancel=true and exit cleanly.
        // The next llb_start_gen() call will clear g_cancel_flag
        // (via g_cancel_flag.store(false) in llb_start_gen) AFTER it increments
        // g_gen_epoch, ensuring the new gen thread starts with a clean state.
        // Any state updates the old thread tries to make after that point will
        // be suppressed by the epoch check in gen_update_state / gen_mark_finished.
        LOGI("[AI] llb_free_model: cleanup delegated to background thread");
        return;
    }

    // No generation thread running — free resources immediately.
    if (g_ctx) {
        LOGI("[AI] freeing context");
        llama_free(g_ctx);
        g_ctx = nullptr;
    }
    if (g_model) {
        LOGI("[AI] freeing model");
        llama_model_free(g_model);
        g_model = nullptr;
    }
    g_cancel_flag.store(false);
    LOGI("[AI] llb_free_model complete");
}

const char* llb_last_error(void) {
    return g_last_error.c_str();
}

int32_t llb_is_loaded(void) {
    return (g_model != nullptr && g_ctx != nullptr) ? 1 : 0;
}

}  // extern "C"
