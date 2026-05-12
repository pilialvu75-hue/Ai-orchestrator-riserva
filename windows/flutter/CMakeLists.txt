# This file controls Flutter-level build steps. It should not be edited.
cmake_minimum_required(VERSION 3.14)

set(EPHEMERAL_DIR "${CMAKE_CURRENT_SOURCE_DIR}/ephemeral")

include(${EPHEMERAL_DIR}/generated_config.cmake)

find_package(OpenGL REQUIRED)

add_library(flutter INTERFACE)
target_include_directories(flutter INTERFACE
  "${EPHEMERAL_DIR}"
)
target_link_libraries(flutter INTERFACE
  "${EPHEMERAL_DIR}/flutter_windows.dll.lib"
  ${OPENGL_gl_LIBRARY}
)

add_custom_target(flutter_assemble VERBATIM
  COMMAND ${CMAKE_COMMAND} -E env ${FLUTTER_TOOL_ENVIRONMENT}
    "${FLUTTER_TOOL}" assemble
    --output="${CMAKE_CURRENT_BINARY_DIR}/flutter_assets"
    -dTargetFile="${FLUTTER_TARGET_FILE}"
    -dBuildMode="${FLUTTER_BUILD_MODE}"
    -dTargetPlatform="${FLUTTER_TARGET_PLATFORM}"
    -dTrackWidgetCreation="${TRACK_WIDGET_CREATION}"
    "kernel_snapshot"
    "windows_x64_flutter_bundle"
  WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}/.."
)

add_dependencies(flutter flutter_assemble)


