#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "startup_trace.h"
#include "utils.h"

namespace {

bool AppendPathPart(wchar_t (&path)[MAX_PATH], const wchar_t* suffix) {
  const int current = ::lstrlenW(path);
  const int extra = suffix == nullptr ? 0 : ::lstrlenW(suffix);
  if (suffix == nullptr || current < 0 || extra < 0 ||
      current + extra >= MAX_PATH) {
    return false;
  }
  ::lstrcatW(path, suffix);
  return true;
}

void RotateDiagnosticPair(const wchar_t* current_name,
                          const wchar_t* previous_name) {
  wchar_t root[MAX_PATH] = {};
  DWORD length = ::GetEnvironmentVariableW(L"LOCALAPPDATA", root, MAX_PATH);
  if (length > 0 && length < MAX_PATH &&
      AppendPathPart(root, L"\\AI-Orchestrator\\Diagnostics\\")) {
    wchar_t current[MAX_PATH] = {};
    wchar_t previous[MAX_PATH] = {};
    ::lstrcpyW(current, root);
    ::lstrcpyW(previous, root);
    if (AppendPathPart(current, current_name) &&
        AppendPathPart(previous, previous_name) &&
        ::GetFileAttributesW(current) != INVALID_FILE_ATTRIBUTES) {
      ::DeleteFileW(previous);
      ::MoveFileExW(current, previous,
                    MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
    }
  }

  wchar_t temp_root[MAX_PATH] = {};
  length = ::GetTempPathW(MAX_PATH, temp_root);
  if (length > 0 && length < MAX_PATH) {
    wchar_t current[MAX_PATH] = {};
    wchar_t previous[MAX_PATH] = {};
    ::lstrcpyW(current, temp_root);
    ::lstrcpyW(previous, temp_root);
    if (AppendPathPart(current, current_name) &&
        AppendPathPart(previous, previous_name) &&
        ::GetFileAttributesW(current) != INVALID_FILE_ATTRIBUTES) {
      ::DeleteFileW(previous);
      ::MoveFileExW(current, previous,
                    MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
    }
  }
}

void PreservePreviousStartupDiagnostics() {
  RotateDiagnosticPair(L"AI-Orchestrator-win7-startup.log",
                       L"AI-Orchestrator-win7-startup.previous.log");
  RotateDiagnosticPair(L"AI-Orchestrator-win7-crash.dmp",
                       L"AI-Orchestrator-win7-crash.previous.dmp");
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  PreservePreviousStartupDiagnostics();
  startup_trace::Reset();
  startup_trace::Mark("01 wWinMain entered");

  // Attach to console when present (e.g., 'flutter run') or create a
  // temporary one when not present (e.g., within a debugger).
  if (!::AttachConsole(ATTACH_PARENT_PROCESS)) {
    ::AllocConsole();
    ::ShowWindow(::GetConsoleWindow(), SW_HIDE);
  }
  startup_trace::Mark("02 console initialized");

  // Initialize COM, so that it is available for use in the library and/or
  // plugins. Only balance CoInitializeEx with CoUninitialize when this call
  // actually acquired a COM initialization reference.
  startup_trace::Mark("03 before CoInitializeEx");
  const HRESULT com_result =
      ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  const bool com_initialized = SUCCEEDED(com_result);
  if (com_result == S_OK) {
    startup_trace::Mark("04 CoInitializeEx initialized apartment");
  } else if (com_result == S_FALSE) {
    startup_trace::Mark("04 CoInitializeEx apartment already initialized");
  } else if (com_result == RPC_E_CHANGED_MODE) {
    startup_trace::Mark("04 CoInitializeEx changed-mode result; continuing");
  } else {
    startup_trace::Mark("04 CoInitializeEx failed; continuing for diagnostics");
  }

  startup_trace::Mark("05 before DartProject");
  flutter::DartProject project(L"data");
  startup_trace::Mark("06 after DartProject");

  startup_trace::Mark("07 before command line parsing");
  std::vector<std::string> command_line_arguments = GetCommandLineArguments();
  startup_trace::Mark("08 after command line parsing");

  bool skip_plugins = false;
  bool disable_impeller = false;
  std::vector<std::string> dart_arguments;
  dart_arguments.reserve(command_line_arguments.size());
  for (const auto& argument : command_line_arguments) {
    if (argument == "--win7-no-plugins") {
      skip_plugins = true;
      startup_trace::Mark("08a Win7 plugin-free diagnostic mode requested");
      continue;
    }
    if (argument == "--win7-no-impeller") {
      disable_impeller = true;
      startup_trace::Mark("08b Win7 no-Impeller diagnostic mode requested");
      continue;
    }
    dart_arguments.push_back(argument);
  }

  if (disable_impeller) {
    // Flutter 3.29.x predates the Windows Impeller switch exposed by newer
    // DartProject wrappers. The legacy Windows renderer is already the engine
    // default here, so the diagnostic flag is intentionally a no-op.
    startup_trace::Mark(
        "08c Flutter 3.29 legacy renderer already active; no Impeller switch");
  } else {
    startup_trace::Mark("08c Flutter 3.29 renderer default retained");
  }

  project.set_dart_entrypoint_arguments(std::move(dart_arguments));
  startup_trace::Mark("09 after Dart entrypoint args");

  startup_trace::Mark("10 before FlutterWindow constructor");
  FlutterWindow window(project, skip_plugins);
  startup_trace::Mark("11 after FlutterWindow constructor");

  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  startup_trace::Mark("12 before window.Create");
  if (!window.Create(L"ai_orchestrator", origin, size)) {
    startup_trace::Mark("13 window.Create returned false");
    if (com_initialized) {
      ::CoUninitialize();
    }
    return EXIT_FAILURE;
  }
  startup_trace::Mark("14 window.Create returned true");
  window.SetQuitOnClose(true);

  startup_trace::Mark("15 entering message loop");
  ::MSG msg;
  int exit_code = EXIT_SUCCESS;
  for (;;) {
    const BOOL get_message_result = ::GetMessage(&msg, nullptr, 0, 0);
    if (get_message_result > 0) {
      ::TranslateMessage(&msg);
      ::DispatchMessage(&msg);
      continue;
    }
    if (get_message_result == 0) {
      startup_trace::Mark("16 message loop received WM_QUIT");
      break;
    }
    startup_trace::Mark("16 message loop GetMessage failed");
    exit_code = EXIT_FAILURE;
    break;
  }

  if (com_initialized) {
    ::CoUninitialize();
    startup_trace::Mark("17 COM uninitialized");
  } else {
    startup_trace::Mark("17 COM cleanup not required");
  }
  startup_trace::Mark("18 clean shutdown");
  return exit_code;
}