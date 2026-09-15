cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt so `flutter run` keeps resolving the same target.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
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

add_dependencies(${BINARY_NAME} flutter_assemble ws2fix)

# Flutter's current Windows engine imports GetHostNameW directly from
# WS2_32.dll. Windows 7 does not export that symbol, so redirect the engine's
# Winsock import table to the application-local compatibility shim. The shim
# forwards every other Winsock function to the real system WS2_32.dll and uses
# the native GetHostNameW unchanged on Windows 8+.
add_custom_command(TARGET ${BINARY_NAME} PRE_LINK
  COMMAND powershell.exe -NoProfile -ExecutionPolicy Bypass
    -File "${CMAKE_SOURCE_DIR}/../tool/patch_flutter_windows_win7.ps1"
    -FlutterDll "${FLUTTER_LIBRARY}"
  COMMENT "Applying Windows 7 Winsock compatibility patch to Flutter engine"
  VERBATIM
)
