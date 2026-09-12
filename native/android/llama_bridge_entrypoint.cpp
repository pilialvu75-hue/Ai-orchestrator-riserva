// Aggregated native bridge entry point.
//
// The existing llama_bridge.cpp intentionally keeps RuntimeSession and the
// session registry private to its translation unit.  This entry point compiles
// that implementation in the same translation unit so token accounting can use
// the already-loaded model vocabulary without exporting native model pointers
// across the FFI boundary.
//
// The start-generation symbol is renamed while including the implementation,
// then wrapped below.  The public wrapper enforces the hard invariant:
//
//   prompt_tokens + generated_tokens + safety_margin <= n_ctx
//
// using the exact llama.cpp tokenizer for the model attached to the session.
#define llb_session_start_gen llb_session_start_gen_unbudgeted
#include "llama_bridge.cpp"
#undef llb_session_start_gen

namespace {

constexpr int32_t kPromptTokenSafetyMargin = 32;

int32_t count_session_tokens(
    const std::shared_ptr<RuntimeSession>& session,
    const char* text
) {
    if (session == nullptr) {
        set_global_error("Session not found");
        return -1;
    }
    if (text == nullptr) {
        session->set_error("Token count text is null");
        return -2;
    }

    std::lock_guard<std::mutex> lock(session->native_mutex);
    if (session->model == nullptr) {
        session->set_error("Session model is not active for token count");
        return -3;
    }

    const llama_vocab* vocab = llama_model_get_vocab(session->model);
    if (vocab == nullptr) {
        session->set_error("Vocabulary unavailable for token count");
        return -4;
    }

    const size_t text_size = std::strlen(text);
    if (text_size == 0) {
        return 0;
    }

    // A token cannot require fewer than one input byte in the ordinary path,
    // so byte length + a small special-token allowance is normally sufficient.
    // If llama.cpp reports a larger required capacity, resize once and retry.
    std::vector<llama_token> tokens(std::max<size_t>(8, text_size + 8));
    int32_t token_count = llama_tokenize(
        vocab,
        text,
        static_cast<int32_t>(text_size),
        tokens.data(),
        static_cast<int32_t>(tokens.size()),
        true,
        true
    );

    if (token_count < 0) {
        const int32_t required_capacity = -token_count;
        tokens.resize(static_cast<size_t>(required_capacity));
        token_count = llama_tokenize(
            vocab,
            text,
            static_cast<int32_t>(text_size),
            tokens.data(),
            static_cast<int32_t>(tokens.size()),
            true,
            true
        );
    }

    if (token_count < 0) {
        session->set_error("Token count failed after capacity retry");
        return -5;
    }

    return token_count;
}

int32_t session_context_size(const std::shared_ptr<RuntimeSession>& session) {
    if (session == nullptr) {
        return -1;
    }

    std::lock_guard<std::mutex> lock(session->native_mutex);
    if (session->ctx == nullptr) {
        return -1;
    }
    return static_cast<int32_t>(llama_n_ctx(session->ctx));
}

}  // namespace

extern "C" {

int32_t llb_session_token_count(int64_t session_id, const char* text) {
    auto session = find_session(session_id);
    const int32_t token_count = count_session_tokens(session, text);
    if (token_count >= 0) {
        LOGI("[TOKEN_COUNT_EXACT] session=%" PRId64 " chars=%zu tokens=%d",
             session_id,
             text == nullptr ? 0 : std::strlen(text),
             token_count);
    } else {
        LOGE("[TOKEN_COUNT_EXACT_FAIL] session=%" PRId64 " code=%d",
             session_id,
             token_count);
    }
    return token_count;
}

int32_t llb_session_start_gen(
    int64_t session_id,
    const char* prompt,
    int32_t max_tokens,
    float temperature
) {
    auto session = find_session(session_id);
    if (session == nullptr) {
        set_global_error("Session not found");
        LOGE("[TOKEN_BUDGET_FAIL] session=%" PRId64 " reason=session_not_found",
             session_id);
        return -1;
    }

    const std::string sanitized_prompt = sanitize_prompt_for_generation(prompt);
    const int32_t prompt_tokens =
        count_session_tokens(session, sanitized_prompt.c_str());
    if (prompt_tokens < 0) {
        LOGE("[TOKEN_BUDGET_FAIL] session=%" PRId64
             " reason=prompt_token_count code=%d",
             session_id,
             prompt_tokens);
        return -6;
    }

    const int32_t n_ctx = session_context_size(session);
    if (n_ctx <= 0) {
        session->set_error("Invalid context size during token budgeting");
        LOGE("[TOKEN_BUDGET_FAIL] session=%" PRId64 " reason=invalid_n_ctx",
             session_id);
        return -7;
    }

    const int32_t generation_capacity =
        n_ctx - prompt_tokens - kPromptTokenSafetyMargin;
    if (generation_capacity <= 0) {
        session->set_error("Prompt exceeds native context token budget");
        LOGE("[TOKEN_BUDGET_FAIL] session=%" PRId64
             " prompt_tokens=%d n_ctx=%d safety_margin=%d",
             session_id,
             prompt_tokens,
             n_ctx,
             kPromptTokenSafetyMargin);
        return -8;
    }

    const int32_t effective_max_tokens =
        std::min(max_tokens, generation_capacity);
    LOGI("[TOKEN_BUDGET_NATIVE] session=%" PRId64
         " prompt_tokens=%d requested_generation_tokens=%d"
         " effective_generation_tokens=%d n_ctx=%d safety_margin=%d clamped=%s",
         session_id,
         prompt_tokens,
         max_tokens,
         effective_max_tokens,
         n_ctx,
         kPromptTokenSafetyMargin,
         effective_max_tokens != max_tokens ? "true" : "false");

    return llb_session_start_gen_unbudgeted(
        session_id,
        sanitized_prompt.c_str(),
        effective_max_tokens,
        temperature
    );
}

}  // extern "C"
