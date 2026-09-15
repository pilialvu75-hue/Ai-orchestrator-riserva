add_library(ws2fix SHARED ws2fix.cpp ws2fix.def)
apply_standard_settings(ws2fix)
target_link_libraries(ws2fix PRIVATE ws2_32)
set_target_properties(ws2fix PROPERTIES OUTPUT_NAME ws2fix PREFIX "")

add_library(nt7fx SHARED nt7fx.cpp nt7fx.def)
apply_standard_settings(nt7fx)
set_target_properties(nt7fx PROPERTIES OUTPUT_NAME nt7fx PREFIX "")

add_library(win7krnl SHARED win7krnl.cpp win7krnl.def)
apply_standard_settings(win7krnl)
set_target_properties(win7krnl PROPERTIES OUTPUT_NAME win7krnl PREFIX "")

add_library(win7path SHARED win7path.cpp win7path_extra.cpp win7path.def)
apply_standard_settings(win7path)
set_target_properties(win7path PROPERTIES
  OUTPUT_NAME "win7path-compatibility-shim"
  PREFIX ""
)

add_library(win7sync SHARED win7sync.cpp win7sync.def)
apply_standard_settings(win7sync)
set_target_properties(win7sync PROPERTIES
  OUTPUT_NAME "ai-orchestrator-sync-win7fix"
  PREFIX ""
)

add_library(dxg7fix SHARED dxg7fix.cpp dxg7fix.def)
apply_standard_settings(dxg7fix)
target_link_libraries(dxg7fix PRIVATE dxgi)
set_target_properties(dxg7fix PROPERTIES OUTPUT_NAME dxg7 PREFIX "")
