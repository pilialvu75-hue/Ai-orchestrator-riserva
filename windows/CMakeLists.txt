# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(ai_orchestrator LANGUAGES CXX)

# The on-disk executable name.
set(BINARY_NAME "ai_orchestrator")

cmake_policy(VERSION 3.14...3.25)

get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()

set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

add_definitions(-DUNICODE -D_UNICODE)

function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})
add_subdirectory("compat")

# WINDOWS 7 DYNAMIC-PLUGIN CANDIDATE:
# Let Flutter's generated plugin metadata build all plugin/FFI targets and
# populate PLUGIN_BUNDLED_LIBRARIES. The runner itself does not compile the
# generated registrant and references no plugin symbols, so MSVC does not add
# plugin import libraries to the executable's PE dependency table. CI enforces
# that property with dumpbin.
add_subdirectory("runner")
add_subdirectory("diagnostics")
include(flutter/generated_plugins.cmake)

# === Installation ===
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS
  ${BINARY_NAME}
  ai_orchestrator_windows_probe
  ai_orchestrator_windows_graphics_probe
  ai_orchestrator_windows_bootstrap_probe
  file_selector_windows_plugin
  flutter_secure_storage_windows_plugin
  permission_handler_windows_plugin
  record_windows_plugin
  RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(TARGETS ws2fix nt7fx win7krnl win7path win7sync dxg7fix
  RUNTIME DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

install(FILES
  "${CMAKE_CURRENT_SOURCE_DIR}/diagnostics/AI-Orchestrator-Collect-Diagnostics.cmd"
  DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}"
  DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

# Keep generated plugin/FFI DLLs and their runtime companions beside the
# executable. Nothing here is linked into ai_orchestrator.exe; the native
# method-channel plugins are loaded explicitly after FlutterEngine startup.
# dartjni.dll is an Android/JVM bridge pulled transitively by tooling. The
# Windows AOT image and bundled DLLs contain no reference to it, and keeping it
# causes a misleading jvm.dll loader popup on Windows 7 diagnostics.
foreach(bundled_library ${PLUGIN_BUNDLED_LIBRARIES})
  if("${bundled_library}" MATCHES "[\\/]dartjni\\.dll$")
    message(STATUS "Skipping unused Windows dartjni.dll bundle asset")
    continue()
  endif()
  install(FILES "${bundled_library}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endforeach()

# Native assets emitted by Dart/Flutter packages remain present because the Dart
# application may reference them after startup. They are not linked into the
# runner and therefore cannot participate in pre-main plugin initialization.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
  DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${AOT_LIBRARY}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
