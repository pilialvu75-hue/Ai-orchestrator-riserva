cmake_minimum_required(VERSION 3.20)
project(ai_orchestrator_static_runtime LANGUAGES C CXX)

set(AI_ORCHESTRATOR_RUNTIME_VARIANT "" CACHE STRING "cpu-avx2 or vulkan-server")
set_property(CACHE AI_ORCHESTRATOR_RUNTIME_VARIANT PROPERTY STRINGS cpu-avx2 vulkan-server)
if(NOT AI_ORCHESTRATOR_RUNTIME_VARIANT MATCHES "^(cpu-avx2|vulkan-server)$")
  message(FATAL_ERROR "AI_ORCHESTRATOR_RUNTIME_VARIANT must be cpu-avx2 or vulkan-server")
endif()
if(NOT EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/../../../third_party/llama.cpp/CMakeLists.txt")
  message(FATAL_ERROR "Initialize third_party/llama.cpp before building Windows")
endif()

# Keep app-owned ggml/backend components inside each executable. The only
# Vulkan runtime import is the OS/driver-provided vulkan-1.dll loader.
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(GGML_BACKEND_DL OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_CPU ON CACHE BOOL "" FORCE)
foreach(feature SSE42 AVX AVX2 AVX_VNNI AVX512 FMA F16C OPENMP BLAS CUDA VULKAN RPC LLAMAFILE)
  set(GGML_${feature} OFF CACHE BOOL "" FORCE)
endforeach()
set(GGML_AVX2 ON CACHE BOOL "" FORCE)
set(GGML_FMA OFF CACHE BOOL "" FORCE)
set(GGML_F16C OFF CACHE BOOL "" FORCE)
if(AI_ORCHESTRATOR_RUNTIME_VARIANT STREQUAL "vulkan-server")
  set(GGML_VULKAN ON CACHE BOOL "" FORCE)
  set(LLAMA_BUILD_SERVER ON CACHE BOOL "" FORCE)
  add_compile_definitions(_WIN32_WINNT=0x0A00 WINVER=0x0A00)
  set(AI_ORCHESTRATOR_RUNTIME_TARGET llama-server)
else()
  set(GGML_VULKAN OFF CACHE BOOL "" FORCE)
  set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
  add_compile_definitions(_WIN32_WINNT=0x0601 WINVER=0x0601)
  set(AI_ORCHESTRATOR_RUNTIME_TARGET llama-completion)
endif()
set(LLAMA_BUILD_COMMON ON CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS ON CACHE BOOL "" FORCE)
foreach(feature TESTS EXAMPLES WEBUI)
  set(LLAMA_BUILD_${feature} OFF CACHE BOOL "" FORCE)
endforeach()
set(LLAMA_OPENSSL OFF CACHE BOOL "" FORCE)
set(LLAMA_TOOLS_INSTALL OFF CACHE BOOL "" FORCE)

set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
add_subdirectory("../../../third_party/llama.cpp" "${CMAKE_CURRENT_BINARY_DIR}/llama" EXCLUDE_FROM_ALL)

if(AI_ORCHESTRATOR_RUNTIME_VARIANT STREQUAL "cpu-avx2")
  # The CPU helper is local-file-only; use the same offline boundary as the
  # portable Win7 baseline, avoiding an unrelated Win10 HTTP dependency.
  get_target_property(common_sources llama-common SOURCES)
  list(FILTER common_sources EXCLUDE REGEX "(^|/)(download|hf-cache)\\.cpp$")
  set_property(TARGET llama-common PROPERTY SOURCES "${common_sources}")
  target_sources(llama-common PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../offline_download.cpp")
  get_target_property(common_links llama-common LINK_LIBRARIES)
  list(REMOVE_ITEM common_links cpp-httplib)
  set_property(TARGET llama-common PROPERTY LINK_LIBRARIES "${common_links}")
  get_target_property(common_interface_links llama-common INTERFACE_LINK_LIBRARIES)
  if(common_interface_links)
    list(FILTER common_interface_links EXCLUDE REGEX "cpp-httplib")
    set_property(TARGET llama-common PROPERTY INTERFACE_LINK_LIBRARIES "${common_interface_links}")
  endif()
  set_target_properties(cpp-httplib PROPERTIES EXCLUDE_FROM_ALL TRUE)
  target_link_options(llama-completion PRIVATE /SUBSYSTEM:CONSOLE,6.01)
endif()

install(TARGETS ${AI_ORCHESTRATOR_RUNTIME_TARGET}
  RUNTIME DESTINATION "."
  COMPONENT Runtime)
install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/../../../third_party/llama.cpp/LICENSE"
  DESTINATION "licenses"
  RENAME "llama.cpp-LICENSE.txt"
  COMPONENT Runtime)
