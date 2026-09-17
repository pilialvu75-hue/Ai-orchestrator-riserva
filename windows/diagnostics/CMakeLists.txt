add_executable(ai_orchestrator_windows_probe WIN32
  "windows_probe.cpp"
)

apply_standard_settings(ai_orchestrator_windows_probe)
target_compile_definitions(ai_orchestrator_windows_probe PRIVATE "NOMINMAX")
target_link_libraries(ai_orchestrator_windows_probe PRIVATE version shell32)
set_target_properties(ai_orchestrator_windows_probe PROPERTIES
  OUTPUT_NAME "AI-Orchestrator-Windows-Diagnostics"
)

add_executable(ai_orchestrator_windows_graphics_probe WIN32
  "graphics_probe.cpp"
)

apply_standard_settings(ai_orchestrator_windows_graphics_probe)
target_compile_definitions(ai_orchestrator_windows_graphics_probe PRIVATE "NOMINMAX")
target_link_libraries(ai_orchestrator_windows_graphics_probe PRIVATE
  d3d9
  dwmapi
  dxgi
  opengl32
  shell32
)
set_target_properties(ai_orchestrator_windows_graphics_probe PROPERTIES
  OUTPUT_NAME "AI-Orchestrator-Windows-Graphics-Diagnostics"
)

add_executable(ai_orchestrator_windows_bootstrap_probe WIN32
  "bootstrap_probe.cpp"
)

apply_standard_settings(ai_orchestrator_windows_bootstrap_probe)
target_compile_definitions(ai_orchestrator_windows_bootstrap_probe PRIVATE "NOMINMAX")
target_link_libraries(ai_orchestrator_windows_bootstrap_probe PRIVATE shell32)
set_target_properties(ai_orchestrator_windows_bootstrap_probe PROPERTIES
  OUTPUT_NAME "AI-Orchestrator-Windows-Bootstrap-Diagnostics"
)
