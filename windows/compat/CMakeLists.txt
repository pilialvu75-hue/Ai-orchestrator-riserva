add_library(ws2fix SHARED ws2fix.cpp ws2fix.def)
apply_standard_settings(ws2fix)
target_link_libraries(ws2fix PRIVATE ws2_32)
set_target_properties(ws2fix PROPERTIES OUTPUT_NAME ws2fix PREFIX "")
