#include "llama_bridge.h"

#include "llama.h"

#include <android/log.h>

#include <array>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cinttypes>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <functional>
#include <iterator>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

#include <sys/stat.h>
#include <unistd.h>

#define LOG_TAG "AI_RUNTIME"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

namespace {

constexpr size_t kRingCapacity = 256;
constexpr int32_t kMaxGeneratedTokens = 256;
constexpr size_t kMinPromptLength = 2;
constexpr int64_t kDecodeStallLogMillis = 5000;
// Keep native first-token waits aligned with the Dart-side 24ms polling cadence so
// llb_session_poll_token can block briefly on the first-token latch without
// adding extra end-to-end latency or a second timing pattern to debug.
constexpr int64_t kFirstTokenPollWaitMillis = 24;
constexpr int32_t kMaxInitialSampleRetries = 4;
constexpr const char* kFallbackPrompt = "Hello";

constexpr int kStateGenerating = 0;
constexpr int kStateCompleted = 1;
constexpr int kStateCancelled = 2;
constexpr int kStateFailed = -1;

bool is_valid_state(const int state) {
    return state == kStateGenerating || state == kStateCompleted ||
           state == kStateCancelled || state == kStateFailed;
}

uint64_t current_thread_id() {
    return static_cast<uint64_t>(
        std::hash<std::thread::id>{}(std::this_thread::get_id()));
}

std::mutex g_global_error_mutex;
std::string g_global_last_error;

void set_global_error(const std::string& message) {
    std::lock_guard<std::mutex> lock(g_global_error_mutex);
    g_global_last_error = message;
}

std::string get_global_error_copy() {
    std::lock_guard<std::mutex> lock(g_global_error_mutex);
    return g_global_last_error;
}

// Supporto multi-modello esteso per impedire leak di token e cicli infiniti.
// Include i token di controllo di Llama 3, ChatML (DeepSeek/Qwen) e Zephyr/TinyLlama.
constexpr const char* kChatTemplateControlTokens[] = {
    "<|eot_id|>",
    "<|start_header_id|>",
    "<|end_header_id|>",
    "<|im_start|>",
    "<|im_end|>",
    "<|user|>",
    "<|assistant|>",
    "</s>"
};
// Garantisce uno spazio di manovra sicuro sopra l'array dei token di controllo esteso.
constexpr size_t kChatTemplateControlTokenBufferTokens = std::size(kChatTemplateControlTokens) + 1;

struct ChatTemplateControlTokenId {
    llama_token token_id{};
    bool resolved{false};
};

struct ChatTemplateControlTokenIds {
    std::array<ChatTemplateControlTokenId, std::size(kChatTemplateControlTokens)> token_ids{};
};

// Returns the resolved chat-template control token ids for the loaded vocabulary.
ChatTemplateControlTokenIds resolve_chat_template_control_token_ids(const llama_vocab* vocab) {
    ChatTemplateControlTokenIds resolved{};
    if (vocab == nullptr) {
        return resolved;
    }

    // Reused for each control token probe; each result is consumed immediately.
    std::array<llama_token, kChatTemplateControlTokenBufferTokens> control_token_buf{};
    for (size_t i = 0; i < std::size(kChatTemplateControlTokens); ++i) {
        const char* control_token = kChatTemplateControlTokens[i];
        const int token_count = llama_tokenize(
            vocab,
            control_token,
            static_cast<int32_t>(std::strlen(control_token)),
            control_token_buf.data(),
            static_cast<int32_t>(std::size(control_token_buf)),
            false,
            true
        );
        if (token_count == 1) {
            resolved.token_ids[i].token_id = control_token_buf[0];
            resolved.token_ids[i].resolved = true;
            continue;
        }

        LOGE("[CHAT_TEMPLATE_CONTROL_TOKEN_RESOLVE] token=%s token_count=%d expected=1",
             control_token,
             token_count);
    }

    return resolved;
}

// Returns true when the sampled token resolves to a known chat-template control
// token in the loaded vocabulary.
bool is_chat_template_control_token(const ChatTemplateControlTokenIds& control_tokens,
                                   const llama_token token) {
    for (const auto& control_token : control_tokens.token_ids) {
        if (control_token.resolved && control_token.token_id == token) {
            return true;
        }
    }

    return false;
}

// Defensive fallback for decoded pieces that still look like chat-template
// control sequences.
bool looks_like_chat_template_control_piece(const char* piece, const int32_t piece_len) {
    if (piece == nullptr || piece_len <= 0) {
        return false;
    }

    const std::string piece_text(piece, static_cast<size_t>(piece_len));
    for (const char* control_token : kChatTemplateControlTokens) {
        if (piece_text == control_token) {
            return true;
        }
    }

    return false;
}

int32_t decode_token_piece(
    const llama_vocab* vocab,
    const llama_token token,
    char* piece_buf,
    const int32_t piece_buf_len
) {
    return llama_token_to_piece(vocab, token, piece_buf, piece_buf_len, 0, false);
}

struct BatchGuard {
    llama_batch batch{};
    bool initialized{false};

    BatchGuard(const int32_t n_tokens, const int32_t embd, const int32_t n_seq_max) {
        batch = llama_batch_init(n_tokens, embd, n_seq_max);
        initialized = batch.token != nullptr && batch.pos != nullptr &&
                      batch.n_seq_id != nullptr && batch.seq_id != nullptr &&
                      batch.logits != nullptr;
    }

    ~BatchGuard() {
        if (initialized) {
            llama_batch_free(batch);
        }
    }

    BatchGuard(const BatchGuard&) = delete;
    BatchGuard& operator=(const BatchGuard&) = delete;
};

using SamplerPtr = std::unique_ptr<llama_sampler, decltype(&llama_sampler_free)>;

struct TokenEntry {
    std::string piece;
    uint64_t epoch;
    std::chrono::steady_clock::time_point emitted_at;
};

struct RuntimeSession {
    explicit RuntimeSession(int64_t id_in) : id(id_in) {}

    const int64_t id;

    mutable std::mutex generation_mutex;
    mutable std::mutex queue_mutex;
    mutable std::mutex error_mutex;
    mutable std::mutex native_mutex;
    mutable std::mutex first_token_mutex;
    std::condition_variable first_token_cv;

    llama_model* model{nullptr};
    llama_context* ctx{nullptr};

    std::thread gen_thread;
    std::atomic<bool> worker_running{false};
    std::atomic<bool> cancel_requested{false};
    std::atomic<bool> first_token_emitted{false};
    std::atomic<int> gen_state{kStateCompleted};
    std::atomic<uint64_t> epoch{0};

    std::deque<TokenEntry> token_queue;
    std::atomic<int64_t> queue_overflow_count{0};
    std::atomic<int64_t> stale_drop_count{0};

    std::string last_error;

    void set_error(const std::string& message) {
        {
            std::lock_guard<std::mutex> lock(error_mutex);
            last_error = message;
        }
        set_global_error(message);
        LOGE("[ERROR] session=%" PRId64 " message=%s", id, message.c_str());
    }

    std::string get_error_copy() const {
        std::lock_guard<std::mutex> lock(error_mutex);
        return last_error;
    }

    void clear_error() {
        std::lock_guard<std::mutex> lock(error_mutex);
        last_error.clear();
    }

    void clear_queue() {
        std::lock_guard<std::mutex> lock(queue_mutex);
        token_queue.clear();
    }

    size_t queue_size_snapshot() const {
        std::lock_guard<std::mutex> lock(queue_mutex);
        return token_queue.size();
    }

    bool has_native_resources() const {
        std::lock_guard<std::mutex> lock(native_mutex);
        return model != nullptr && ctx != nullptr;
    }

    void destroy_native_resources() {
        std::lock_guard<std::mutex> lock(native_mutex);
        if (ctx != nullptr) {
            LOGI("[CLEANUP] session=%" PRId64 " freeing context", id);
            llama_free(ctx);
            ctx = nullptr;
        }
        if (model != nullptr) {
            LOGI("[CLEANUP] session=%" PRId64 " freeing model", id);
            llama_model_free(model);
            model = nullptr;
        }
    }

    std::pair<llama_model*, llama_context*> snapshot_native_handles() const {
        std::lock_guard<std::mutex> lock(native_mutex);
        return {model, ctx};
    }
};

// Trims prompt whitespace and guarantees a minimally usable prompt for the
// first-token liveness path, falling back to kFallbackPrompt when input is
// null, blank, or too short to reliably drive a decode step.
std::string sanitize_prompt_for_generation(const char* prompt) {
    if (prompt == nullptr) {
        return std::string(kFallbackPrompt);
    }
    std::string sanitized(prompt);
    const auto first_non_ws = sanitized.find_first_not_of(" \t\r\n");
    if (first_non_ws == std::string::npos) {
        return std::string(kFallbackPrompt);
    }
    const auto last_non_ws = sanitized.find_last_not_of(" \t\r\n");
    sanitized = sanitized.substr(first_non_ws, last_non_ws - first_non_ws + 1);
    if (sanitized.size() < kMinPromptLength) {
        return std::string(kFallbackPrompt);
    }
    return sanitized;
}

// Wakes any pollers waiting for the first token or an early terminal state.
void notify_first_token_waiters(const std::shared_ptr<RuntimeSession>& session) {
    session->first_token_cv.notify_all();
}

std::once_flag g_backend_init_once;
std::atomic<bool> g_backend_initialized{false};

std::mutex g_registry_mutex;
std::unordered_map<int64_t, std::shared_ptr<RuntimeSession>> g_sessions;
std::atomic<int64_t> g_next_session_id{1};

thread_local std::string g_tls_error;

std::shared_ptr<RuntimeSession> find_session(const int64_t session_id) {
    std::lock_guard<std::mutex> lock(g_registry_mutex);
    const auto it = g_sessions.find(session_id);
    if (it == g_sessions.end()) {
        return nullptr;
    }
    return it->second;
}

std::shared_ptr<RuntimeSession> remove_session(const int64_t session_id) {
    std::lock_guard<std::mutex> lock(g_registry_mutex);
    const auto it = g_sessions.find(session_id);
    if (it == g_sessions.end()) {
        return nullptr;
    }
    auto session = it->second;
    g_sessions.erase(it);
    return session;
}

void set_state_if_epoch(
    const std::shared_ptr<RuntimeSession>& session,
    const int desired_state,
    const uint64_t owner_epoch,
    const char* reason
) {
    if (!is_valid_state(desired_state)) {
        LOGE("[ERROR] session=%" PRId64 " invalid_state=%d", session->id, desired_state);
        return;
    }
    if (session->epoch.load(std::memory_order_acquire) != owner_epoch) {
        LOGI("[STALE_WORKER_EXIT] session=%" PRId64 " epoch_mismatch owner=%" PRIu64 " current=%" PRIu64
             " state_skip=%d reason=%s",
             session->id,
             owner_epoch,
             session->epoch.load(std::memory_order_acquire),
             desired_state,
             reason ? reason : "none");
        return;
    }
    session->gen_state.store(desired_state, std::memory_order_release);
    LOGI("[DECODE] session=%" PRId64 " state=%d epoch=%" PRIu64 " reason=%s",
         session->id,
         desired_state,
         owner_epoch,
         reason ? reason : "none");
}

size_t enqueue_token(
    const std::shared_ptr<RuntimeSession>& session,
    std::string piece,
    const uint64_t epoch
) {
    std::lock_guard<std::mutex> lock(session->queue_mutex);

    if (session->token_queue.size() >= kRingCapacity) {
        session->token_queue.pop_front();
        const auto dropped = ++session->queue_overflow_count;
        LOGE("[QUEUE_OVERFLOW] session=%" PRId64 " drop_oldest=true overflow_count=%" PRId64,
             session->id,
             dropped);
        LOGI("[DECODE] session=%" PRId64 " backpressure queue_size=%zu capacity=%zu",
             session->id,
             session->token_queue.size(),
             kRingCapacity);
    }

    session->token_queue.push_back(TokenEntry{
        std::move(piece),
        epoch,
        std::chrono::steady_clock::now(),
    });

    return session->token_queue.size();
}

void run_generation(
    const std::shared_ptr<RuntimeSession>& session,
    std::string prompt,
    int32_t max_tokens,
    float temperature,
    const uint64_t owner_epoch
) {
    LOGI("[FORENSIC] [RUN_GENERATION] before session=%" PRId64 " epoch=%" PRIu64
         " prompt_chars=%zu max_tokens=%d",
         session->id,
         owner_epoch,
         prompt.size(),
         max_tokens);
    const auto thread_id = current_thread_id();
    const auto generation_started_at = std::chrono::steady_clock::now();
    auto last_decode_progress_at = generation_started_at;
    auto last_token_emitted_at = generation_started_at;
    int32_t initial_sample_retry_count = 0;

    session->worker_running.store(true, std::memory_order_release);
    session->first_token_emitted.store(false, std::memory_order_release);

    struct ThreadGuard {
        std::shared_ptr<RuntimeSession> session;
        uint64_t epoch;
        uint64_t thread_id;
        std::chrono::steady_clock::time_point started_at;

        ~ThreadGuard() {
            session->worker_running.store(false, std::memory_order_release);
            notify_first_token_waiters(session);
            const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now() - started_at
            ).count();
            LOGI("[THREAD_FINISH] session=%" PRId64 " epoch=%" PRIu64 " thread_id=%" PRIu64
                 " elapsed_ms=%lld state=%d",
                 session->id,
                 epoch,
                 thread_id,
                 static_cast<long long>(elapsed),
                 session->gen_state.load(std::memory_order_acquire));
        }
    } guard{session, owner_epoch, thread_id, generation_started_at};

    LOGI("[FORENSIC] [THREAD_START] before session=%" PRId64 " epoch=%" PRIu64,
         session->id,
         owner_epoch);
    LOGI("[THREAD_START] session=%" PRId64 " epoch=%" PRIu64 " thread_id=%" PRIu64,
         session->id,
         owner_epoch,
         thread_id);
    LOGI("[FORENSIC] [THREAD_START] after session=%" PRId64 " epoch=%" PRIu64 " thread_id=%" PRIu64,
         session->id,
         owner_epoch,
         thread_id);
    LOGI("[SESSION_START_GEN] session=%" PRId64 " epoch=%" PRIu64 " prompt_chars=%zu max_tokens=%d temp=%.3f",
         session->id,
         owner_epoch,
         prompt.size(),
         max_tokens,
         static_cast<double>(temperature));

    auto [model, ctx] = session->snapshot_native_handles();
    if (model == nullptr || ctx == nullptr) {
        session->set_error("Session native resources unavailable");
        set_state_if_epoch(session, kStateFailed, owner_epoch, "missing_native_resources");
        return;
    }

    const llama_vocab* vocab = llama_model_get_vocab(model);
    if (vocab == nullptr) {
        session->set_error("Vocabulary unavailable");
        set_state_if_epoch(session, kStateFailed, owner_epoch, "vocab_unavailable");
        return;
    }
    const ChatTemplateControlTokenIds chat_template_control_tokens =
        resolve_chat_template_control_token_ids(vocab);

    const int n_ctx = llama_n_ctx(ctx);
    if (n_ctx <= 0) {
        session->set_error("Invalid context size");
        set_state_if_epoch(session, kStateFailed, owner_epoch, "ctx_size_invalid");
        return;
    }
    const int prefill_n_batch = n_ctx;

    auto tokenize_prompt = [&](const std::string& text, std::vector<llama_token>* out_tokens) {
        std::vector<llama_token> local_tokens(static_cast<size_t>(n_ctx));
        const int token_count = llama_tokenize(
            vocab,
            text.c_str(),
            static_cast<int32_t>(text.size()),
            local_tokens.data(),
            static_cast<int32_t>(local_tokens.size()),
            true,
            true // CORRETTO: Cambiato da false a true per forzare il parsing dei tag speciali nativi
        );
        if (token_count > 0) {
            local_tokens.resize(static_cast<size_t>(token_count));
            *out_tokens = std::move(local_tokens);
        }
        return token_count;
    };

    std::vector<llama_token> tokens;
    int n_tokens = tokenize_prompt(prompt, &tokens);

    if (n_tokens <= 1) {
        LOGI("[PROMPT_FALLBACK] session=%" PRId64 " epoch=%" PRIu64
             " reason=short_or_empty_prompt original_chars=%zu fallback=%s",
             session->id,
             owner_epoch,
             prompt.size(),
             kFallbackPrompt);
        prompt = kFallbackPrompt;
        n_tokens = tokenize_prompt(prompt, &tokens);
    }

    if (n_tokens <= 0) {
        session->set_error("Tokenisation failed");
        set_state_if_epoch(session, kStateFailed, owner_epoch, "tokenize_failed");
        return;
    }

    LOGI("[FORENSIC] [THREAD_PREFILL_BEGIN] before session=%" PRId64 " epoch=%" PRIu64,
         session->id,
         owner_epoch);
    LOGI("[THREAD_PREFILL_BEGIN] session=%" PRId64 " epoch=%" PRIu64 " prompt_tokens=%d",
         session->id,
         owner_epoch,
         n_tokens);
    LOGI("[FORENSIC_BATCH_PARAMS] session=%" PRId64 " epoch=%" PRIu64
         " stage=prefill prompt_tokens=%d n_batch=%d n_ctx=%d",
         session->id,
         owner_epoch,
         n_tokens,
         prefill_n_batch,
         n_ctx);
    LOGI("[FORENSIC] [THREAD_PREFILL_BEGIN] after session=%" PRId64 " epoch=%" PRIu64
         " prompt_tokens=%d",
         session->id,
         owner_epoch,
         n_tokens);

    llama_memory_clear(llama_get_memory(ctx), true);

    BatchGuard prefill_batch(static_cast<int32_t>(tokens.size()), 0, 1);
    if (!prefill_batch.initialized) {
        session->set_error("Failed to allocate prefill batch");
        set_state_if_epoch(session, kStateFailed, owner_epoch, "prefill_batch_alloc_failed");
        return;
    }

    for (int32_t i = 0; i < static_cast<int32_t>(tokens.size()); ++i) {
        prefill_batch.batch.token[i] = tokens[static_cast<size_t>(i)];
        prefill_batch.batch.pos[i] = i;
        prefill_batch.batch.n_seq_id[i] = 1;
        prefill_batch.batch.seq_id[i][0] = 0;
        prefill_batch.batch.logits[i] =
            (i == static_cast<int32_t>(tokens.size()) - 1) ? 1 : 0;
    }
    prefill_batch.batch.n_tokens = static_cast<int32_t>(tokens.size());

    const auto prefill_started_at = std::chrono::steady_clock::now();
    LOGI("[FORENSIC_BEFORE_LLAMA_DECODE] session=%" PRId64 " epoch=%" PRIu64
         " stage=prefill batch_n_tokens=%d n_batch=%d n_ctx=%d",
         session->id,
         owner_epoch,
         prefill_batch.batch.n_tokens,
         prefill_n_batch,
         n_ctx);
    const int prefill_status = llama_decode(ctx, prefill_batch.batch);
    LOGI("[FORENSIC_AFTER_LLAMA_DECODE] session=%" PRId64 " epoch=%" PRIu64
         " stage=prefill status=%d batch_n_tokens=%d",
         session->id,
         owner_epoch,
         prefill_status,
         prefill_batch.batch.n_tokens);
    if (prefill_status != 0) {
        session->set_error("Prompt prefill decode failed");
        set_state_if_epoch(session, kStateFailed, owner_epoch, "prefill_decode_failed");
        return;
    }

    const auto prefill_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - prefill_started_at
    ).count();
    LOGI("[FORENSIC] [THREAD_PREFILL_OK] before session=%" PRId64 " epoch=%" PRIu64,
         session->id,
         owner_epoch);
    LOGI("[THREAD_PREFILL_OK] session=%" PRId64 " epoch=%" PRIu64 " status=%d prefill_ms=%lld",
         session->id,
         owner_epoch,
         prefill_status,
         static_cast<long long>(prefill_ms));
    LOGI("[FORENSIC] [THREAD_PREFILL_OK] after session=%" PRId64 " epoch=%" PRIu64
         " status=%d prefill_ms=%lld",
         session->id,
         owner_epoch,
         prefill_status,
         static_cast<long long>(prefill_ms));

    if (session->epoch.load(std::memory_order_acquire) != owner_epoch) {
        LOGI("[STALE_WORKER_EXIT] session=%" PRId64 " epoch=%" PRIu64 " reason=pre_loop_epoch_mismatch",
             session->id,
             owner_epoch);
        set_state_if_epoch(session, kStateCancelled, owner_epoch, "stale_worker_pre_loop");
        return;
    }
    if (session->cancel_requested.load(std::memory_order_acquire)) {
        set_state_if_epoch(session, kStateCancelled, owner_epoch, "cancel_before_decode_loop");
        return;
    }

    llama_sampler_chain_params sampler_params = llama_sampler_chain_default_params();
    SamplerPtr sampler(llama_sampler_chain_init(sampler_params), &llama_sampler_free);
    if (!sampler) {
        session->set_error("Failed to allocate sampler");
        set_state_if_epoch(session, kStateFailed, owner_epoch, "sampler_alloc_failed");
        return;
    }

    llama_sampler_chain_add(sampler.get(), llama_sampler_init_top_k(40));
    llama_sampler_chain_add(sampler.get(), llama_sampler_init_top_p(0.9f, 1));
    llama_sampler_chain_add(sampler.get(), llama_sampler_init_temp(temperature));
    llama_sampler_chain_add(sampler.get(), llama_sampler_init_dist(LLAMA_DEFAULT_SEED));

    int32_t n_cur = n_tokens;
    int32_t n_decode = 0;
    bool eos_reached = false;

    while (n_decode < std::min(max_tokens, kMaxGeneratedTokens)) {
        if (session->epoch.load(std::memory_order_acquire) != owner_epoch) {
            LOGI("[STALE_WORKER_EXIT] session=%" PRId64 " epoch=%" PRIu64 " reason=decode_loop_epoch_mismatch",
                 session->id,
                 owner_epoch);
            set_state_if_epoch(session, kStateCancelled, owner_epoch, "stale_worker_decode_loop");
            return;
        }
        if (session->cancel_requested.load(std::memory_order_acquire)) {
            set_state_if_epoch(session, kStateCancelled, owner_epoch, "cancelled_decode_loop");
            LOGI("[CANCEL] session=%" PRId64 " epoch=%" PRIu64 " token_count=%d",
                 session->id,
                 owner_epoch,
                 n_decode);
            return;
        }

        const auto now = std::chrono::steady_clock::now();
        const auto stall_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
            now - last_decode_progress_at
        ).count();
        if (stall_ms > kDecodeStallLogMillis) {
            LOGE("[STALL_WARNING] session=%" PRId64 " epoch=%" PRIu64 " stall_detected=true stall_ms=%lld"
                 " queue_size=%zu tokens=%d",
                 session->id,
                 owner_epoch,
                 static_cast<long long>(stall_ms),
                 session->queue_size_snapshot(),
                 n_decode);
            last_decode_progress_at = now;
        }

        llama_token next_token = llama_sampler_sample(sampler.get(), ctx, -1);
        if (next_token < 0) {
            if (!session->first_token_emitted.load(std::memory_order_acquire) &&
                initial_sample_retry_count < kMaxInitialSampleRetries) {
                ++initial_sample_retry_count;
                LOGI("[FIRST_TOKEN_RETRY] session=%" PRId64 " epoch=%" PRIu64
                     " reason=invalid_sample retry=%d",
                     session->id,
                     owner_epoch,
                     initial_sample_retry_count);
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
                continue;
            }
            session->set_error("Invalid sample after max retries before first token");
            set_state_if_epoch(session, kStateFailed, owner_epoch, "invalid_sample_before_first_token");
            notify_first_token_waiters(session);
            return;
        }

        llama_sampler_accept(sampler.get(), next_token);

        if (llama_vocab_is_eog(vocab, next_token)) {
            if (!session->first_token_emitted.load(std::memory_order_acquire) &&
                initial_sample_retry_count < kMaxInitialSampleRetries) {
                ++initial_sample_retry_count;
                LOGI("[FIRST_TOKEN_RETRY] session=%" PRId64 " epoch=%" PRIu64
                     " reason=immediate_eos retry=%d",
                     session->id,
                     owner_epoch,
                     initial_sample_retry_count);
                continue;
            }
            if (!session->first_token_emitted.load(std::memory_order_acquire)) {
                session->set_error("EOS reached after max retries before first token");
                set_state_if_epoch(session, kStateFailed, owner_epoch, "eos_before_first_token");
                notify_first_token_waiters(session);
                return;
            }
            eos_reached = true;
            LOGI("[DECODE] session=%" PRId64 " epoch=%" PRIu64 " eos_reached=true generated=%d",
                 session->id,
                 owner_epoch,
                 n_decode);
            break;
        }

        if (is_chat_template_control_token(chat_template_control_tokens, next_token)) {
            eos_reached = true;
            LOGI("[DECODE] session=%" PRId64 " epoch=%" PRIu64
                 " eos_reached=true generated=%d reason=chat_template_control_token token_id=%d",
                 session->id,
                 owner_epoch,
                 n_decode,
                 static_cast<int>(next_token));
            break;
        }

        char piece_buf[256];
        const int32_t piece_len = decode_token_piece(
            vocab,
            next_token,
            piece_buf,
            static_cast<int32_t>(sizeof(piece_buf)) - 1
        );

        if (piece_len < 0) {
            session->set_error("Failed to decode token piece");
            set_state_if_epoch(session, kStateFailed, owner_epoch, "token_to_piece_failed");
            return;
        }

        if (piece_len > 0) {
            piece_buf[piece_len] = '\0';
            if (looks_like_chat_template_control_piece(piece_buf, piece_len)) {
                eos_reached = true;
                LOGI("[DECODE] session=%" PRId64 " epoch=%" PRIu64
                     " eos_reached=true generated=%d reason=chat_template_control_piece token_id=%d piece=%s",
                     session->id,
                     owner_epoch,
                     n_decode,
                     static_cast<int>(next_token),
                     piece_buf);
                break;
            }
            const auto emit_now = std::chrono::steady_clock::now();
            const auto emit_interval_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                emit_now - last_token_emitted_at
            ).count();
            const size_t queue_size = enqueue_token(
                session,
                std::string(piece_buf, static_cast<size_t>(piece_len)),
                owner_epoch
            );
            last_token_emitted_at = emit_now;
            if (!session->first_token_emitted.exchange(true, std::memory_order_acq_rel)) {
                const auto first_token_latency_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                    emit_now - generation_started_at
                ).count();
                LOGI("[THREAD_FIRST_TOKEN] session=%" PRId64 " epoch=%" PRIu64 " latency_ms=%lld",
                     session->id,
                     owner_epoch,
                     static_cast<long long>(first_token_latency_ms));
                notify_first_token_waiters(session);
            }
            LOGI("[TOKEN_LATENCY] session=%" PRId64 " epoch=%" PRIu64 " token_interval_ms=%lld",
                 session->id,
                 owner_epoch,
                 static_cast<long long>(emit_interval_ms));
            const auto total_elapsed_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                emit_now - generation_started_at
            ).count();
            const int emitted_tokens = n_decode + 1;
            const double throughput = total_elapsed_ms > 0
                ? (static_cast<double>(emitted_tokens) * 1000.0 / static_cast<double>(total_elapsed_ms))
                : 0.0;
            LOGI("[TOKEN_THROUGHPUT] session=%" PRId64 " epoch=%" PRIu64 " tokens=%d elapsed_ms=%lld tokens_per_sec=%.3f",
                 session->id,
                 owner_epoch,
                 emitted_tokens,
                 static_cast<long long>(total_elapsed_ms),
                 throughput);
            LOGI("[TOKEN] session=%" PRId64 " epoch=%" PRIu64 " token_id=%d chars=%d"
                 " queue_size=%zu emit_interval_ms=%lld overflow_count=%" PRId64,
                 session->id,
                 owner_epoch,
                 static_cast<int>(next_token),
                 static_cast<int>(piece_len),
                 queue_size,
                 static_cast<long long>(emit_interval_ms),
                 session->queue_overflow_count.load(std::memory_order_acquire));
        }

        BatchGuard step_batch(1, 0, 1);
        if (!step_batch.initialized) {
            session->set_error("Failed to allocate decode batch");
            set_state_if_epoch(session, kStateFailed, owner_epoch, "decode_batch_alloc_failed");
            return;
        }

        step_batch.batch.token[0] = next_token;
        step_batch.batch.pos[0] = n_cur;
        step_batch.batch.n_seq_id[0] = 1;
        step_batch.batch.seq_id[0][0] = 0;
        step_batch.batch.logits[0] = 1;
        step_batch.batch.n_tokens = 1;

        const int decode_status = llama_decode(ctx, step_batch.batch);
        if (decode_status != 0) {
            session->set_error("Token decode step failed");
            set_state_if_epoch(session, kStateFailed, owner_epoch, "decode_step_failed");
            return;
        }

        ++n_cur;
        ++n_decode;
        last_decode_progress_at = std::chrono::steady_clock::now();
        LOGI("[DECODE] session=%" PRId64 " epoch=%" PRIu64 " decode_step_ok token_index=%d",
             session->id,
             owner_epoch,
             n_decode);
    }

    set_state_if_epoch(session, kStateCompleted, owner_epoch, "generation_completed");
    LOGI("[DECODE] session=%" PRId64 " epoch=%" PRIu64 " decode_loop_end eos=%s generated=%d",
         session->id,
         owner_epoch,
         eos_reached ? "true" : "false",
         n_decode);
}

}  // namespace

extern "C" {

void llb_init_backend(void) {
    std::call_once(g_backend_init_once, []() {
        llama_backend_init();
        g_backend_initialized.store(true, std::memory_order_release);
        LOGI("[SESSION_CREATE_BEGIN] backend_initialized=true");
    });
}

int64_t llb_create_session(
    const char* model_path,
    int32_t n_ctx,
    int32_t n_threads,
    int32_t n_gpu_layers
) {
    llb_init_backend();
    set_global_error("");

    if (model_path == nullptr || std::strlen(model_path) == 0) {
        set_global_error("Model path is empty");
        LOGE("[ERROR] [SESSION_CREATE_BEGIN] model_path_empty");
        return -1;
    }

    struct stat model_stat;
    const bool model_exists = stat(model_path, &model_stat) == 0;
    const bool model_readable = access(model_path, R_OK) == 0;
    const int64_t model_size = model_exists ? static_cast<int64_t>(model_stat.st_size) : -1;

    const int32_t effective_gpu_layers = n_gpu_layers < 0 ? 0 : n_gpu_layers;

    LOGI("[SESSION_CREATE_BEGIN] model_path=%s n_ctx=%d n_threads=%d n_gpu_layers=%d",
         model_path,
         n_ctx,
         n_threads,
         effective_gpu_layers);
    LOGI("[SESSION_LOAD] model_exists=%s model_readable=%s model_size=%" PRId64,
         model_exists ? "true" : "false",
         model_readable ? "true" : "false",
         model_size);

#if defined(GGML_USE_VULKAN)
    LOGI("[GPU_DETECT] vulkan=enabled requested_gpu_layers=%d", effective_gpu_layers);
#else
    if (effective_gpu_layers > 0) {
        LOGI("[GPU_DETECT] vulkan=disabled requested_gpu_layers=%d effective_gpu_layers=0"
             " reason=GGML_USE_VULKAN_not_compiled fallback=cpu",
             effective_gpu_layers);
    } else {
        LOGI("[GPU_DETECT] vulkan=disabled gpu_layers=0 backend=cpu");
    }
#endif

    if (!model_exists || !model_readable || model_size <= 0) {
        set_global_error("Invalid model file path or unreadable file");
        LOGE("[ERROR] [SESSION_LOAD] invalid_model_file path=%s", model_path);
        return -2;
    }

    const int64_t session_id = g_next_session_id.fetch_add(1, std::memory_order_acq_rel);
    auto session = std::make_shared<RuntimeSession>(session_id);

    llama_model_params mparams = llama_model_default_params();
#if defined(GGML_USE_VULKAN)
    mparams.n_gpu_layers = effective_gpu_layers;
    LOGI("[GPU_ASSIGN] session=%" PRId64 " n_gpu_layers=%d backend=vulkan",
         session_id, mparams.n_gpu_layers);
#else
    mparams.n_gpu_layers = 0;
    if (effective_gpu_layers > 0) {
        LOGI("[GPU_ASSIGN] session=%" PRId64 " n_gpu_layers=0 requested=%d"
             " reason=vulkan_not_available fallback=cpu",
             session_id, effective_gpu_layers);
    }
#endif
    mparams.use_mmap = true;
    mparams.use_mlock = false;

    {
        std::lock_guard<std::mutex> lock(session->native_mutex);
        session->model = llama_model_load_from_file(model_path, mparams);
    }

    if (session->model == nullptr) {
        session->set_error("Failed to load model");
        LOGE("[ERROR] [SESSION_LOAD] llama_model_load_from_file_failed path=%s", model_path);
        return -3;
    }

    llama_context_params cparams = llama_context_default_params();
    const uint32_t effective_n_ctx = static_cast<uint32_t>(n_ctx > 0 ? n_ctx : 2048);
    const int32_t effective_n_threads = n_threads > 0 ? n_threads : 2;
    cparams.n_ctx = effective_n_ctx;
    cparams.n_threads = effective_n_threads;
    cparams.n_threads_batch = effective_n_threads;
    cparams.n_batch = effective_n_ctx;
    cparams.n_ubatch = effective_n_ctx;
    cparams.embeddings = false;
    cparams.offload_kqv = true;
    LOGI("[FORENSIC_CTX_PARAMS] session=%" PRId64
         " requested_n_ctx=%d effective_n_ctx=%u requested_n_threads=%d effective_n_threads=%d"
         " n_batch=%u n_ubatch=%u",
         session_id,
         n_ctx,
         effective_n_ctx,
         n_threads,
         effective_n_threads,
         cparams.n_batch,
         cparams.n_ubatch);

    {
        std::lock_guard<std::mutex> lock(session->native_mutex);
        session->ctx = llama_init_from_model(session->model, cparams);
    }

    if (session->ctx == nullptr) {
        session->set_error("Failed to create context");
        session->destroy_native_resources();
        LOGE("[ERROR] [SESSION_LOAD] llama_init_from_model_failed");
        return -4;
    }

    const llama_vocab* vocab = llama_model_get_vocab(session->model);
    const int ctx_size = llama_n_ctx(session->ctx);
    char model_desc[512] = {0};
    const int model_desc_len = llama_model_desc(session->model, model_desc, static_cast<int32_t>(sizeof(model_desc)));

    LOGI("[SESSION_LOAD] bootstrap_vocab=%s ctx_size=%d model_desc_len=%d",
         vocab != nullptr ? "ok" : "null",
         ctx_size,
         model_desc_len);

    if (vocab == nullptr || ctx_size <= 0 || model_desc_len <= 0) {
        session->set_error("Bootstrap verification failed");
        session->destroy_native_resources();
        LOGE("[ERROR] [SESSION_LOAD] bootstrap_verification_failed");
        return -5;
    }

    LOGI("[SESSION_LOAD] model_desc=%s", model_desc);
    LOGI("[SESSION_LOAD] bos_id=%d eos_id=%d",
         static_cast<int>(llama_vocab_bos(vocab)),
         static_cast<int>(llama_vocab_eos(vocab)));

    session->clear_error();
    session->gen_state.store(kStateCompleted, std::memory_order_release);

    {
        std::lock_guard<std::mutex> lock(g_registry_mutex);
        g_sessions[session_id] = session;
    }

    LOGI("[SESSION_CREATE_OK] session=%" PRId64 " created=true", session_id);
    return session_id;
}

int32_t llb_session_start_gen(
    int64_t session_id,
    const char* prompt,
    int32_t max_tokens,
    float temperature
) {
    LOGI("[FORENSIC] [LLB_SESSION_START_GEN] before session=%" PRId64 " max_tokens=%d temp=%.3f",
         session_id,
         max_tokens,
         static_cast<double>(temperature));
    set_global_error("");
    auto session = find_session(session_id);
    if (session == nullptr) {
        set_global_error("Session not found");
        LOGE("[ERROR] [GEN_START] session_not_found session=%" PRId64, session_id);
        return -1;
    }

    if (!session->has_native_resources()) {
        session->set_error("Session native resources not active");
        return -2;
    }

    if (max_tokens <= 0) {
        session->set_error("max_tokens must be > 0");
        LOGE("[ERROR] [GEN_START] invalid_max_tokens session=%" PRId64 " value=%d",
             session_id,
             max_tokens);
        return -4;
    }

    std::lock_guard<std::mutex> lock(session->generation_mutex);

    LOGI("[CANCEL_REQUEST] session=%" PRId64 " reason=restart_generation", session_id);
    session->cancel_requested.store(true, std::memory_order_release);
    if (session->gen_thread.joinable()) {
        LOGI("[CLEANUP_JOIN] session=%" PRId64 " join_previous_generation=true", session_id);
        session->gen_thread.join();
    }

    session->clear_queue();
    session->cancel_requested.store(false, std::memory_order_release);
    session->first_token_emitted.store(false, std::memory_order_release);
    session->clear_error();

    const uint64_t owner_epoch = session->epoch.fetch_add(1, std::memory_order_acq_rel) + 1;
    session->gen_state.store(kStateGenerating, std::memory_order_release);
    notify_first_token_waiters(session);

    const std::string sanitized_prompt = sanitize_prompt_for_generation(prompt);
    if (prompt == nullptr || sanitized_prompt != std::string(prompt)) {
        LOGI("[PROMPT_FALLBACK] session=%" PRId64 " reason=start_gen_sanitized fallback=%s",
             session_id,
             sanitized_prompt.c_str());
    }

    LOGI("[SESSION_START_GEN] session=%" PRId64 " epoch=%" PRIu64 " max_tokens=%d temp=%.3f",
         session_id,
         owner_epoch,
         max_tokens,
         static_cast<double>(temperature));

    try {
        LOGI("[FORENSIC] [RUN_GENERATION_SPAWN] before session=%" PRId64 " epoch=%" PRIu64,
             session_id,
             owner_epoch);
        session->gen_thread = std::thread(
            run_generation,
            session,
            sanitized_prompt,
            max_tokens,
            temperature,
            owner_epoch
        );
        LOGI("[FORENSIC] [RUN_GENERATION_SPAWN] after session=%" PRId64 " epoch=%" PRIu64,
             session_id,
             owner_epoch);
    } catch (const std::exception& error) {
        session->set_error(error.what());
        session->gen_state.store(kStateFailed, std::memory_order_release);
        LOGE("[ERROR] [THREAD_START] session=%" PRId64 " spawn_failed=%s",
             session_id,
             error.what());
        return -5;
    }

    LOGI("[FORENSIC] [LLB_SESSION_START_GEN] after session=%" PRId64 " epoch=%" PRIu64 " result=0",
         session_id,
         owner_epoch);
    return 0;
}

int32_t llb_session_poll_token(
    int64_t session_id,
    char* buf,
    int32_t buf_size
) {
    auto session = find_session(session_id);
    if (session == nullptr) {
        set_global_error("Session not found");
        LOGE("[ERROR] [TOKEN] session_not_found session=%" PRId64, session_id);
        return -1;
    }

    if (buf == nullptr || buf_size <= 0) {
        session->set_error("Invalid token buffer");
        return -1;
    }

    const uint64_t current_epoch = session->epoch.load(std::memory_order_acquire);

    auto try_pop_token = [&]() -> int32_t {
        std::lock_guard<std::mutex> lock(session->queue_mutex);

        while (!session->token_queue.empty()) {
            const uint64_t entry_epoch = session->token_queue.front().epoch;
            if (entry_epoch == current_epoch) {
                break;
            }
            if (entry_epoch > current_epoch) {
                return 0;
            }
            session->token_queue.pop_front();
            const auto dropped = ++session->stale_drop_count;
            LOGI("[QUEUE_DROP_OLD_EPOCH] session=%" PRId64 " stale_drop_count=%" PRId64,
                 session_id,
                 dropped);
        }

        if (!session->token_queue.empty()) {
            TokenEntry entry = std::move(session->token_queue.front());
            session->token_queue.pop_front();

            const auto copy_len = static_cast<int32_t>(std::min(
                static_cast<size_t>(buf_size - 1),
                entry.piece.size()
            ));
            std::memcpy(buf, entry.piece.data(), static_cast<size_t>(copy_len));
            buf[copy_len] = '\0';

            const auto queued_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now() - entry.emitted_at
            ).count();
            LOGI("[TOKEN] session=%" PRId64 " polled=true chars=%d queue_size=%zu queued_ms=%lld"
                 " overflow_count=%" PRId64,
                 session_id,
                 copy_len,
                 session->token_queue.size(),
                 static_cast<long long>(queued_ms),
                 session->queue_overflow_count.load(std::memory_order_acquire));
            return 1;
        }
        return 0;
    };

    if (try_pop_token() == 1) {
        return 1;
    }

    if (!session->first_token_emitted.load(std::memory_order_acquire) &&
        session->gen_state.load(std::memory_order_acquire) == kStateGenerating &&
        session->epoch.load(std::memory_order_acquire) == current_epoch) {
        std::unique_lock<std::mutex> wait_lock(session->first_token_mutex);
        session->first_token_cv.wait_for(
            wait_lock,
            std::chrono::milliseconds(kFirstTokenPollWaitMillis),
            [&]() {
                return session->first_token_emitted.load(std::memory_order_acquire) ||
                       session->gen_state.load(std::memory_order_acquire) != kStateGenerating ||
                       session->epoch.load(std::memory_order_acquire) != current_epoch;
            }
        );
        if (try_pop_token() == 1) {
            return 1;
        }
    }

    const int state = session->gen_state.load(std::memory_order_acquire);
    if (state == kStateCompleted) {
        LOGI("[DECODE] session=%" PRId64 " poll_state=completed", session_id);
        return 2;
    }
    if (state == kStateCancelled) {
        LOGI("[CANCEL] session=%" PRId64 " poll_state=cancelled", session_id);
        return -99;
    }
    if (state == kStateFailed) {
        LOGE("[ERROR] [DECODE] session=%" PRId64 " poll_state=failed error=%s",
             session_id,
             session->get_error_copy().c_str());
        return -1;
    }

    return 0;
}

void llb_session_cancel(int64_t session_id) {
    auto session = find_session(session_id);
    if (session == nullptr) {
        LOGE("[ERROR] [CANCEL] session_not_found session=%" PRId64, session_id);
        return;
    }

    LOGI("[CANCEL_REQUEST] session=%" PRId64 " requested=true", session_id);
    session->cancel_requested.store(true, std::memory_order_release);
    const uint64_t owner_epoch = session->epoch.load(std::memory_order_acquire);
    set_state_if_epoch(session, kStateCancelled, owner_epoch, "cancel_requested_api");
    notify_first_token_waiters(session);
    LOGI("[CANCEL] session=%" PRId64 " requested=true epoch=%" PRIu64,
         session_id,
         owner_epoch);
}

void llb_release_session(int64_t session_id) {
    auto session = remove_session(session_id);
    if (session == nullptr) {
        LOGI("[SESSION_DESTROY] session=%" PRId64 " already_released=true", session_id);
        return;
    }

    LOGI("[SESSION_DESTROY] session=%" PRId64 " releasing=true", session_id);

    // Signal cancellation so the gen thread exits its decode loop promptly.
    session->cancel_requested.store(true, std::memory_order_release);
    session->gen_state.store(kStateCancelled, std::memory_order_release);
    // Wake any llb_session_poll_token caller waiting on the first-token CV.
    // This is a no-op when cancelSession was already called (the common path),
    // but is needed for correctness when releaseSession is called without a prior
    // cancelSession (e.g. LRU eviction).  It is idempotent and harmless.
    notify_first_token_waiters(session);

    // Synchronous cleanup: block the caller (Dart FFI isolate thread) until the
    // gen_thread has fully exited and all native resources are freed.  This is the
    // minimal change that eliminates the race between the old gen_thread still
    // running llama_decode and a new llb_session_start_gen starting on a freshly
    // created context — both would otherwise race through GGML's shared CPU thread
    // pool, causing SIGSEGV at the start of the new generation.
    LOGI("[SESSION_RELEASE_WAIT_BEGIN] session=%" PRId64, session_id);

    {
        std::lock_guard<std::mutex> lock(session->generation_mutex);
        if (session->gen_thread.joinable()) {
            LOGI("[SESSION_NATIVE_THREAD_JOIN] session=%" PRId64 " joining=true", session_id);
            session->gen_thread.join();
        }
    }

    session->clear_queue();
    session->destroy_native_resources();

    LOGI("[SESSION_RELEASE_WAIT_END] session=%" PRId64 " destroyed=true", session_id);
}

int32_t llb_session_is_active(int64_t session_id) {
    auto session = find_session(session_id);
    if (session == nullptr) {
        return 0;
    }
    return session->has_native_resources() ? 1 : 0;
}

const char* llb_session_last_error(int64_t session_id) {
    auto session = find_session(session_id);
    if (session == nullptr) {
        g_tls_error = get_global_error_copy();
        if (g_tls_error.empty()) {
            g_tls_error = "Session not found";
        }
        return g_tls_error.c_str();
    }

    g_tls_error = session->get_error_copy();
    return g_tls_error.c_str();
}

}  // extern "C"
