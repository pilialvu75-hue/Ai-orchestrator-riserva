cmake_minimum_required(VERSION 3.15)

if(NOT EXISTS "${CMAKE_CURRENT_LIST_DIR}/../../third_party/llama.cpp/CMakeLists.txt")
  message(FATAL_ERROR "Initialize third_party/llama.cpp before building Windows")
endif()

# A portable CPU baseline for older Windows PCs, with no CUDA/OpenMP/Node DLLs.
# The Flutter runner and its existing compatibility shims remain unchanged.
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(GGML_BACKEND_DL OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
foreach(feature SSE42 AVX AVX2 AVX_VNNI AVX512 FMA F16C OPENMP BLAS CUDA VULKAN RPC LLAMAFILE)
  set(GGML_${feature} OFF CACHE BOOL "" FORCE)
endforeach()
set(GGML_CPU ON CACHE BOOL "" FORCE)
set(LLAMA_BUILD_COMMON ON CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS ON CACHE BOOL "" FORCE)
foreach(feature TESTS EXAMPLES SERVER WEBUI)
  set(LLAMA_BUILD_${feature} OFF CACHE BOOL "" FORCE)
endforeach()
set(LLAMA_OPENSSL OFF CACHE BOOL "" FORCE)
set(LLAMA_TOOLS_INSTALL OFF CACHE BOOL "" FORCE)

# Only llama targets inherit these settings, not Flutter or its plugins.
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
add_compile_definitions(_WIN32_WINNT=0x0601 WINVER=0x0601)
add_subdirectory("../../third_party/llama.cpp" "${CMAKE_CURRENT_BINARY_DIR}/llama" EXCLUDE_FROM_ALL)
set_target_properties(llama-completion PROPERTIES WIN32_EXECUTABLE FALSE)
target_link_options(llama-completion PRIVATE /SUBSYSTEM:CONSOLE,6.01)
