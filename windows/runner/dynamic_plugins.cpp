#include "dynamic_plugins.h"

#include <flutter/flutter_engine.h>
#include <windows.h>

#include <cwchar>
#include <string>
#include <vector>

#include "startup_trace.h"

namespace {

struct DynamicPluginSpec {
  const wchar_t* dll_name;
  const char* export_name;
  const char* registrar_name;
  const char* before_marker;
  const char* loaded_marker;
  const char* registered_marker;
  const char* failed_marker;
};

std::vector<HMODULE>& LoadedPluginModules() {
  static std::vector<HMODULE> modules;
  return modules;
}

std::wstring ApplicationLocalPath(const wchar_t* file_name) {
  wchar_t executable_path[MAX_PATH] = {};
  const DWORD length =
      ::GetModuleFileNameW(nullptr, executable_path, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) {
    return std::wstring(file_name);
  }

  wchar_t* last_slash = ::wcsrchr(executable_path, L'\\');
  if (last_slash == nullptr) {
    return std::wstring(file_name);
  }
  *(last_slash + 1) = L'\0';
  return std::wstring(executable_path) + file_name;
}

bool LoadAndRegister(flutter::FlutterEngine* engine,
                     const DynamicPluginSpec& spec) {
  startup_trace::Mark(spec.before_marker);

  const std::wstring dll_path = ApplicationLocalPath(spec.dll_name);
  const UINT previous_error_mode =
      ::SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOOPENFILEERRORBOX);
  HMODULE module = ::LoadLibraryW(dll_path.c_str());
  ::SetErrorMode(previous_error_mode);

  if (module == nullptr) {
    startup_trace::Mark(spec.failed_marker);
    return false;
  }
  startup_trace::Mark(spec.loaded_marker);

  FARPROC raw_register = ::GetProcAddress(module, spec.export_name);
  if (raw_register == nullptr) {
    startup_trace::Mark(spec.failed_marker);
    ::FreeLibrary(module);
    return false;
  }

  FlutterDesktopPluginRegistrarRef registrar =
      engine->GetRegistrarForPlugin(spec.registrar_name);
  if (registrar == nullptr) {
    startup_trace::Mark(spec.failed_marker);
    ::FreeLibrary(module);
    return false;
  }

  using RegisterPluginFn = void (*)(FlutterDesktopPluginRegistrarRef);
  auto register_plugin = reinterpret_cast<RegisterPluginFn>(raw_register);
  register_plugin(registrar);

  // Plugin callbacks can outlive registration. Keep each DLL loaded for the
  // full process lifetime instead of unloading it after registration.
  LoadedPluginModules().push_back(module);
  startup_trace::Mark(spec.registered_marker);
  return true;
}

}  // namespace

bool RegisterDynamicPlugins(flutter::FlutterEngine* engine) {
  if (engine == nullptr) {
    startup_trace::Mark("27z dynamic plugins: Flutter engine missing");
    return false;
  }

  const DynamicPluginSpec plugins[] = {
      {
          L"file_selector_windows_plugin.dll",
          "FileSelectorWindowsRegisterWithRegistrar",
          "FileSelectorWindows",
          "27a file_selector: before LoadLibrary",
          "27b file_selector: DLL loaded",
          "27c file_selector: registered",
          "27x file_selector: skipped after load/register failure",
      },
      {
          L"flutter_secure_storage_windows_plugin.dll",
          "FlutterSecureStorageWindowsPluginRegisterWithRegistrar",
          "FlutterSecureStorageWindowsPlugin",
          "27d secure_storage: before LoadLibrary",
          "27e secure_storage: DLL loaded",
          "27f secure_storage: registered",
          "27y secure_storage: skipped after load/register failure",
      },
      {
          L"permission_handler_windows_plugin.dll",
          "PermissionHandlerWindowsPluginRegisterWithRegistrar",
          "PermissionHandlerWindowsPlugin",
          "27g permission_handler: before LoadLibrary",
          "27h permission_handler: DLL loaded",
          "27i permission_handler: registered",
          "27w permission_handler: skipped after load/register failure",
      },
      {
          L"record_windows_plugin.dll",
          "RecordWindowsPluginCApiRegisterWithRegistrar",
          "RecordWindowsPluginCApi",
          "27j record_windows: before LoadLibrary",
          "27k record_windows: DLL loaded",
          "27l record_windows: registered",
          "27v record_windows: skipped after load/register failure",
      },
  };

  bool all_registered = true;
  for (const auto& plugin : plugins) {
    if (!LoadAndRegister(engine, plugin)) {
      all_registered = false;
    }
  }
  return all_registered;
}
