#include "flutter_window.h"

#include <windows.h>

#include <optional>

#include "startup_trace.h"

namespace {

struct DynamicPluginSpec {
  const wchar_t* dll_name;
  const char* symbol_name;
  const char* registry_name;
  const char* before_marker;
  const char* loaded_marker;
  const char* registered_marker;
  const char* load_failed_marker;
  const char* symbol_failed_marker;
  const char* registrar_failed_marker;
};

bool BuildSiblingPath(const wchar_t* file_name, wchar_t (&path)[MAX_PATH]) {
  const DWORD length = ::GetModuleFileNameW(nullptr, path, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) {
    return false;
  }

  wchar_t* last_separator = nullptr;
  for (DWORD i = 0; i < length; ++i) {
    if (path[i] == L'\\' || path[i] == L'/') {
      last_separator = &path[i];
    }
  }
  if (last_separator == nullptr) {
    return false;
  }

  *(last_separator + 1) = L'\0';
  const int base_length = ::lstrlenW(path);
  const int file_length = ::lstrlenW(file_name);
  if (base_length < 0 || file_length < 0 ||
      base_length + file_length >= MAX_PATH) {
    return false;
  }
  ::lstrcatW(path, file_name);
  return true;
}

bool LoadAndRegisterPlugin(flutter::FlutterEngine* engine,
                           const DynamicPluginSpec& spec) {
  startup_trace::Mark(spec.before_marker);

  wchar_t plugin_path[MAX_PATH] = {};
  if (!BuildSiblingPath(spec.dll_name, plugin_path)) {
    startup_trace::Mark(spec.load_failed_marker);
    return false;
  }

  HMODULE module = ::LoadLibraryW(plugin_path);
  if (module == nullptr) {
    startup_trace::Mark(spec.load_failed_marker);
    return false;
  }
  startup_trace::Mark(spec.loaded_marker);

  FARPROC raw_register = ::GetProcAddress(module, spec.symbol_name);
  if (raw_register == nullptr) {
    startup_trace::Mark(spec.symbol_failed_marker);
    ::FreeLibrary(module);
    return false;
  }

  auto registrar = engine->GetRegistrarForPlugin(spec.registry_name);
  if (registrar == nullptr) {
    startup_trace::Mark(spec.registrar_failed_marker);
    ::FreeLibrary(module);
    return false;
  }

  using RegisterPluginFn = void (*)(decltype(registrar));
  auto register_plugin = reinterpret_cast<RegisterPluginFn>(raw_register);
  register_plugin(registrar);

  // Intentionally keep the module loaded for the lifetime of the process.
  // Flutter plugin instances can retain code/data pointers into their DLL.
  startup_trace::Mark(spec.registered_marker);
  return true;
}

void RegisterDynamicPlugins(flutter::FlutterEngine* engine) {
  static const DynamicPluginSpec kPlugins[] = {
      {L"file_selector_windows_plugin.dll",
       "FileSelectorWindowsRegisterWithRegistrar",
       "FileSelectorWindows",
       "27a dynamic plugin: file_selector load begin",
       "27b dynamic plugin: file_selector DLL loaded",
       "27c dynamic plugin: file_selector registered",
       "27x dynamic plugin: file_selector load failed; continuing",
       "27x dynamic plugin: file_selector symbol missing; continuing",
       "27x dynamic plugin: file_selector registrar missing; continuing"},
      {L"flutter_secure_storage_windows_plugin.dll",
       "FlutterSecureStorageWindowsPluginRegisterWithRegistrar",
       "FlutterSecureStorageWindowsPlugin",
       "27d dynamic plugin: secure_storage load begin",
       "27e dynamic plugin: secure_storage DLL loaded",
       "27f dynamic plugin: secure_storage registered",
       "27x dynamic plugin: secure_storage load failed; continuing",
       "27x dynamic plugin: secure_storage symbol missing; continuing",
       "27x dynamic plugin: secure_storage registrar missing; continuing"},
      {L"permission_handler_windows_plugin.dll",
       "PermissionHandlerWindowsPluginRegisterWithRegistrar",
       "PermissionHandlerWindowsPlugin",
       "27g dynamic plugin: permission_handler load begin",
       "27h dynamic plugin: permission_handler DLL loaded",
       "27i dynamic plugin: permission_handler registered",
       "27x dynamic plugin: permission_handler load failed; continuing",
       "27x dynamic plugin: permission_handler symbol missing; continuing",
       "27x dynamic plugin: permission_handler registrar missing; continuing"},
      {L"record_windows_plugin.dll",
       "RecordWindowsPluginCApiRegisterWithRegistrar",
       "RecordWindowsPluginCApi",
       "27j dynamic plugin: record load begin",
       "27k dynamic plugin: record DLL loaded",
       "27l dynamic plugin: record registered",
       "27x dynamic plugin: record load failed; continuing",
       "27x dynamic plugin: record symbol missing; continuing",
       "27x dynamic plugin: record registrar missing; continuing"},
  };

  startup_trace::Mark("27 dynamic plugin registration begin");
  for (const auto& plugin : kPlugins) {
    LoadAndRegisterPlugin(engine, plugin);
  }
  startup_trace::Mark("28 dynamic plugin registration complete");
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project,
                             bool skip_plugins)
    : project_(project), skip_plugins_(skip_plugins) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  startup_trace::Mark("20 FlutterWindow::OnCreate entered");
  if (!Win32Window::OnCreate()) {
    startup_trace::Mark("21 Win32Window::OnCreate returned false");
    return false;
  }
  startup_trace::Mark("22 Win32Window::OnCreate returned true");

  RECT frame = GetClientArea();

  startup_trace::Mark("23 before FlutterViewController constructor");
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  startup_trace::Mark("24 after FlutterViewController constructor");

  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    startup_trace::Mark("25 controller missing engine or view");
    return false;
  }
  startup_trace::Mark("26 controller engine and view ready");

  if (skip_plugins_) {
    startup_trace::Mark("27 diagnostic mode: dynamic plugins skipped");
  } else {
    RegisterDynamicPlugins(flutter_controller_->engine());
  }

  startup_trace::Mark("29 before SetChildContent");
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  startup_trace::Mark("30 after SetChildContent");

  flutter_controller_->engine()->SetNextFrameCallback([this]() {
    startup_trace::Mark("31 first frame callback entered");
    this->Show();
    startup_trace::Mark("31a first frame window shown");
  });
  startup_trace::Mark("32 after SetNextFrameCallback");

  startup_trace::Mark("33 before ForceRedraw");
  flutter_controller_->ForceRedraw();
  startup_trace::Mark("34 after ForceRedraw");

  startup_trace::Mark("35 FlutterWindow::OnCreate success");
  return true;
}

void FlutterWindow::OnDestroy() {
  startup_trace::Mark("40 FlutterWindow::OnDestroy entered");
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
  startup_trace::Mark("41 FlutterWindow::OnDestroy complete");
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      if (flutter_controller_ && flutter_controller_->engine()) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
