# native/android/CMakeLists.txt
#
# Builds libllama_bridge.so for Android.
#
# Prerequisites
# ─────────────
# 1. Initialise the llama.cpp git submodule:
#
#      git submodule update --init --recursive
#
# 2. Either configure externalNativeBuild in android/app/build.gradle to
#    compile this during `flutter build apk`, or build manually with the
#    Android NDK cmake toolchain:
#
#      cmake \
#        -DCMAKE_TOOLCHAIN_FILE=$ANDROID_NDK/build/cmake/android.toolchain.cmake \
#        -DANDROID_ABI=arm64-v8a \
#        -DANDROID_PLATFORM=android-24 \
#        -DCMAKE_BUILD_TYPE=Release \
#        -S native/android \
#        -B build/android/arm64-v8a
#
#      cmake --build build/android/arm64-v8a --target llama_bridge
#
# 3. Copy the resulting libllama_bridge.so to:
#
#      android/app/src/main/jniLibs/<abi>/libllama_bridge.so
#
# Enabling automatic build in Flutter
# ─────────────────────────────────────
# Add the following block to android/app/build.gradle (inside `android {}`):
#
#   externalNativeBuild {
#       cmake {
#           path "../../native/android/CMakeLists.txt"
#           version "3.22.1"
#       }
#   }
#   defaultConfig {
#       ...
#       externalNativeBuild {
#           cmake {
#               cppFlags "-std=c++17 -O3"
#               abiFilters "arm64-v8a"
#           }
#       }
#   }

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

# ── llama.cpp submodule ───────────────────────────────────────────────────────

set(LLAMA_CPP_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../third_party/llama.cpp")

if(NOT EXISTS "${LLAMA_CPP_DIR}/CMakeLists.txt")
    message(FATAL_ERROR
        "llama.cpp submodule not found at ${LLAMA_CPP_DIR}.\n"
        "Run: git submodule update --init --recursive")
endif()

# Build llama.cpp as a static library (avoids .so packaging issues).
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
        # Prefer Vulkan when both backends are available because it is the
        # primary mobile GPU path targeted by the Android MLC integration.
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
)

# Strip debug symbols from the release build to reduce APK size.
if(CMAKE_BUILD_TYPE STREQUAL "Release")
    add_custom_command(TARGET llama_bridge POST_BUILD
        COMMAND ${CMAKE_STRIP} --strip-unneeded
                $<TARGET_FILE:llama_bridge>
    )
    add_custom_command(TARGET mlc_native_bridge POST_BUILD
        COMMAND ${CMAKE_STRIP} --strip-unneeded
                $<TARGET_FILE:mlc_native_bridge>
    )
endif()
