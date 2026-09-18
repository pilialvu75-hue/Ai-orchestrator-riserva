#pragma once

namespace flutter {
class FlutterEngine;
}

// Loads Windows plugins from application-local DLLs only after the Flutter
// engine is alive. This keeps plugin DLLs out of the executable's static PE
// import table so Windows 7 cannot initialize them before wWinMain.
bool RegisterDynamicPlugins(flutter::FlutterEngine* engine);
