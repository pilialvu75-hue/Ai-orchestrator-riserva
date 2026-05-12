#include <jni.h>
#include <android/log.h>
#include <cstdint>
#include <string>
#include <unistd.h>

#ifndef AI_ENABLE_MLC_RUNTIME
#define AI_ENABLE_MLC_RUNTIME 0
#endif

#ifndef AI_MLC_BACKEND_NAME
#define AI_MLC_BACKEND_NAME "cpu"
#endif

#define LOG_TAG "MLC_NATIVE"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)

namespace {

constexpr std::uint64_t kMinKvCacheBudgetBytes = 512ull * 1024ull * 1024ull; // 512 MiB
constexpr std::uint64_t kDefaultGuardrailBudgetBytes = 1536ull * 1024ull * 1024ull; // 1.5 GiB

std::uint64_t total_ram_bytes() {
    const long page_size = sysconf(_SC_PAGESIZE);
    const long page_count = sysconf(_SC_PHYS_PAGES);
    if (page_size <= 0 || page_count <= 0) {
        return 0;
    }
    return static_cast<std::uint64_t>(page_size) * static_cast<std::uint64_t>(page_count);
}

std::uint64_t kv_cache_guardrail_bytes() {
    static const std::uint64_t cached_guardrail = []() -> std::uint64_t {
        const std::uint64_t ram = total_ram_bytes();
        if (ram == 0) {
            return kMinKvCacheBudgetBytes;
        }
        const std::uint64_t one_third = ram / 3ull;
        if (one_third < kMinKvCacheBudgetBytes) {
            return kMinKvCacheBudgetBytes;
        }
        return one_third > kDefaultGuardrailBudgetBytes ? kDefaultGuardrailBudgetBytes : one_third;
    }();
    return cached_guardrail;
}

std::string backend_name() {
#if AI_ENABLE_MLC_RUNTIME
    return AI_MLC_BACKEND_NAME;
#else
    return "fallback-llama";
#endif
}

bool mlc_available() {
#if AI_ENABLE_MLC_RUNTIME
    return true;
#else
    return false;
#endif
}

}  // namespace

extern "C" JNIEXPORT jboolean JNICALL
Java_com_aiorchestrator_MlcNativeBridge_nativeIsAvailable(JNIEnv*, jobject) {
    const bool available = mlc_available();
    LOGI("nativeIsAvailable=%d", available ? 1 : 0);
    return available ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_aiorchestrator_MlcNativeBridge_nativeBackendName(JNIEnv* env, jobject) {
    const std::string backend = backend_name();
    return env->NewStringUTF(backend.c_str());
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_aiorchestrator_MlcNativeBridge_nativeMaxKvCacheBytes(JNIEnv*, jobject) {
    const auto bytes = static_cast<jlong>(kv_cache_guardrail_bytes());
    LOGI("nativeMaxKvCacheBytes=%lld", static_cast<long long>(bytes));
    return bytes;
}
