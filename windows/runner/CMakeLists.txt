cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt so `flutter run` keeps resolving the same target.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "startup_trace.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
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

# The generated registrar is intentionally not committed by Flutter. Instrument
# it after flutter_assemble has finalized generated Windows sources and before
# the runner is compiled. The script is idempotent and discovers registrar calls
# by pattern, so adding/removing plugins does not require maintaining a manual
# list here.
add_custom_command(TARGET ${BINARY_NAME} PRE_BUILD
  COMMAND powershell.exe -NoProfile -ExecutionPolicy Bypass
    -File "${CMAKE_SOURCE_DIR}/../tool/instrument_windows_plugin_registrant.ps1"
    -RegistrantPath "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  COMMENT "Instrumenting Windows plugin registration startup trace"
  VERBATIM
)

# Current Flutter/Dart desktop binaries contain loader-level dependencies that
# first appeared after Windows 7: GetHostNameW, growable unwind tables,
# GetCurrentThreadStackLimits, PathCch and WaitOnAddress. Redirect exactly the
# corresponding import modules to application-local shims. Every shim delegates
# to the native implementation on Windows 8+ and only uses a fallback on Win7.
add_custom_command(TARGET ${BINARY_NAME} PRE_LINK
  COMMAND powershell.exe -NoProfile -ExecutionPolicy Bypass
    -File "${CMAKE_SOURCE_DIR}/../tool/patch_flutter_windows_win7.ps1"
    -FlutterDll "${FLUTTER_LIBRARY}"
  COMMENT "Applying Windows 7 compatibility redirects to Flutter engine"
  VERBATIM
)
