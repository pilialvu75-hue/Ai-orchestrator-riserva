cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# WINDOWS 7 DYNAMIC-PLUGIN CANDIDATE. Do not compile the generated plugin
# registrar and do not link plugin import libraries into the runner. Plugin DLL
# targets are built by the top-level CMake and loaded explicitly at runtime.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "startup_trace.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "Runner.rc"
  "runner.exe.manifest"
)

apply_standard_settings(${BINARY_NAME})

target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")
target_compile_definitions(${BINARY_NAME} PRIVATE "AI_ORCHESTRATOR_DYNAMIC_PLUGINS=1")

target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

add_dependencies(
  ${BINARY_NAME}
  flutter_assemble
  ws2fix
  nt7fx
  win7krnl
  win7path
  win7sync
  dxg7fix
)

# Flutter 3.29.3 import rewriting is applied to the completed release bundle
# by patch_windows_bundle_win7.ps1. Keeping it out of PRE_LINK makes the
# engine-specific import layout observable and verifiable in CI.
