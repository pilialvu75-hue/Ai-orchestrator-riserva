# native/android/CMakeLists.txt
# Optimized for high-performance ARM64 Local Inference

cmake_minimum_required(VERSION 3.22.1)
project(llama_bridge VERSION 1.0.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(SUPPORTED_ANDROID_ABIS arm64-v8a)
option(AI_ANDROID_ENABLE_MLC "Enable MLC-LLM JNI bridge integration" OFF)
option(AI_ANDROID_ENABLE_VULKAN "Enable ggml Vulkan backend when Vulkan-Hpp is available" OFF)

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

# L'NDK Android fornisce solo vulkan.h (C). I binding C++ vulkan.hpp
# usati da ggml NON sono inclusi nell'NDK: li scarichiamo con FetchContent
# in fase di configure. libvulkan.so, invece, è già presente nel sysroot
# NDK da API 24 in su (minSdk di questo progetto è 24).
if(AI_ANDROID_ENABLE_VULKAN)
    include(FetchContent)
    FetchContent_Declare(
        VulkanHeaders
        GIT_REPOSITORY https://github.com/KhronosGroup/Vulkan-Headers.git
        GIT_TAG        v1.3.296
    )
    FetchContent_MakeAvailable(VulkanHeaders)

    # ggml-vulkan.cpp include anche <spirv/unified1/spirv.hpp>, che NON fa
    # parte di Vulkan-Headers ma di un repository Khronos separato.
    FetchContent_Declare(
        SPIRVHeaders
        GIT_REPOSITORY https://github.com/KhronosGroup/SPIRV-Headers.git
        GIT_TAG        vulkan-sdk-1.4.335.0
    )
    FetchContent_MakeAvailable(SPIRVHeaders)
endif()

find_library(VULKAN_LIB vulkan)
if(AI_ANDROID_ENABLE_VULKAN AND VULKAN_LIB)
    set(GGML_VULKAN ON CACHE BOOL "" FORCE)
    include_directories(
        "${vulkanheaders_SOURCE_DIR}/include"
        "${spirvheaders_SOURCE_DIR}/include"
    )
    message(STATUS "ggml Vulkan backend enabled with fetched Vulkan-Headers at ${vulkanheaders_SOURCE_DIR}/include and SPIRV-Headers at ${spirvheaders_SOURCE_DIR}/include")
else()
    set(GGML_VULKAN OFF CACHE BOOL "" FORCE)
    if(AI_ANDROID_ENABLE_VULKAN)
        message(WARNING
            "AI_ANDROID_ENABLE_VULKAN is ON but libvulkan was not found in the NDK sysroot. "
            "Vulkan GPU backend unavailable, using CPU fallback.")
    endif()
endif()

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

if(AI_ANDROID_ENABLE_VULKAN AND VULKAN_LIB)
    target_link_libraries(llama_bridge PRIVATE ${VULKAN_LIB})
endif()

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
