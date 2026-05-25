# native/android/CMakeLists.txt
# Optimized for high-performance ARM64 Local Inference

cmake_minimum_required(VERSION 3.22.1)
project(llama_bridge VERSION 1.0.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(SUPPORTED_ANDROID_ABIS arm64-v8a)
option(AI_ANDROID_ENABLE_MLC "Enable MLC-LLM JNI bridge integration" OFF)

if(ANDROID AND DEFINED ANDROID_ABI AND NOT ANDROID_ABI IN_LIST SUPPORTED_ANDROID_ABIS)
    message(FATAL_ERROR
        "Unsupported Android ABI '${ANDROID_ABI}'. "
        "Only 64-bit targets are supported: ${SUPPORTED_ANDROID_ABIS}")
endif()

# ggml requires non-finite math behavior.
add_compile_options(-fno-finite-math-only)

# 🔥 ACCELERAZIONE HARDWARE COMPILAZIONE CRUCIALE PER S24 FE (ARM64)
# Abilitiamo le ottimizzazioni matematiche spinte a livello globale
add_compile_options(-O3 -march=armv8-a+simd+dotprod -flto)
add_link_options(-flto)

if(ANDROID AND DEFINED ANDROID_ABI AND ANDROID_ABI STREQUAL "armeabi-v7a")
    # Per ARMv7 serve esplicitare NEON; su arm64-v8a è già abilitato di default
    set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -mfpu=neon")
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -mfpu=neon")
endif()

# ── llama.cpp submodule ───────────────────────────────────────────────────────

set(LLAMA_CPP_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../third_party/llama.cpp")

if(NOT EXISTS "${LLAMA_CPP_DIR}/CMakeLists.txt")
    message(FATAL_ERROR
        "llama.cpp submodule not found at ${LLAMA_CPP_DIR}.\n"
        "Run: git submodule update --init --recursive")
endif()

# Forza i flag di accelerazione nativi di llama.cpp per Android
set(GGML_NEON             ON  CACHE BOOL "" FORCE)
set(GGML_ARM_FMA          ON  CACHE BOOL "" FORCE)

# ggml-vulkan requires vulkan/vulkan.hpp (Vulkan-Hpp C++ header), which is NOT
# provided by the Android NDK. The NDK ships vulkan/vulkan.h (the C API) and
# libvulkan.so (the runtime loader), but vulkan.hpp is only available through
# the LunarG Vulkan SDK or the Khronos vulkan-hpp project. Forcing this OFF
# prevents ggml-vulkan.cpp from being compiled and avoids the fatal header
# error even if a future CMake argument accidentally sets it to ON.
set(GGML_VULKAN           OFF CACHE BOOL "" FORCE)

set(LLAMA_BUILD_TESTS    OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER   OFF CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS    OFF CACHE BOOL "" FORCE)

add_subdirectory("${LLAMA_CPP_DIR}" llama.cpp EXCLUDE_FROM_ALL)

# ── Bridge shared library ─────────────────────────────────────────────────────

add_library(llama_bridge SHARED llama_bridge.cpp)

target_include_directories(llama_bridge PRIVATE
    "${LLAMA_CPP_DIR}/include"
    "${LLAMA_CPP_DIR}/ggml/include"
)

target_link_libraries(llama_bridge PRIVATE
    llama
    ggml
    log       # Android NDK logging
    android   # Android NDK utils
)

target_compile_options(llama_bridge PRIVATE
    -O3
    -DNDEBUG
    -flto
)

# ── MLC JNI bridge (Android runtime hook) ─────────────────────────────────────
add_library(mlc_native_bridge SHARED mlc_jni_bridge.cpp)
target_link_libraries(mlc_native_bridge PRIVATE
    log
    android
    dl
)

set(MLC_LLM_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../third_party/mlc-llm")
set(AI_MLC_BACKEND_NAME "fallback-llama")
if(AI_ANDROID_ENABLE_MLC AND EXISTS "${MLC_LLM_DIR}")
    find_library(VULKAN_LIB vulkan)
    find_library(OPENCL_LIB OpenCL)

    if(VULKAN_LIB)
        target_link_libraries(mlc_native_bridge PRIVATE ${VULKAN_LIB})
        set(AI_MLC_BACKEND_NAME "vulkan")
    elseif(OPENCL_LIB)
        target_link_libraries(mlc_native_bridge PRIVATE ${OPENCL_LIB})
        set(AI_MLC_BACKEND_NAME "opencl")
    else()
        set(AI_MLC_BACKEND_NAME "cpu")
    endif()

    target_compile_definitions(mlc_native_bridge PRIVATE
        AI_ENABLE_MLC_RUNTIME=1
    )
    if(EXISTS "${MLC_LLM_DIR}/include")
        target_include_directories(mlc_native_bridge PRIVATE
            "${MLC_LLM_DIR}/include"
        )
    endif()
else()
    target_compile_definitions(mlc_native_bridge PRIVATE
        AI_ENABLE_MLC_RUNTIME=0
    )
endif()

target_compile_definitions(mlc_native_bridge PRIVATE
    AI_MLC_BACKEND_NAME="${AI_MLC_BACKEND_NAME}"
)

target_compile_options(mlc_native_bridge PRIVATE
    -O3
    -DNDEBUG
    -flto
)

# 🛠️ STRIP SICURO: Rimuove i simboli in modo robusto senza affidarsi solo a CMAKE_BUILD_TYPE
if(CMAKE_STRIP)
    add_custom_command(TARGET llama_bridge POST_BUILD
        COMMAND ${CMAKE_STRIP} --strip-unneeded $<TARGET_FILE:llama_bridge>
    )
    add_custom_command(TARGET mlc_native_bridge POST_BUILD
        COMMAND ${CMAKE_STRIP} --strip-unneeded $<TARGET_FILE:mlc_native_bridge>
    )
endif()
