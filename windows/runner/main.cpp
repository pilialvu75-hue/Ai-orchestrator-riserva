#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "startup_trace.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
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
  // plugins.
  startup_trace::Mark("03 before CoInitializeEx");
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  startup_trace::Mark("04 after CoInitializeEx");

  startup_trace::Mark("05 before DartProject");
  flutter::DartProject project(L"data");
  startup_trace::Mark("06 after DartProject");

  startup_trace::Mark("07 before command line parsing");
  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();
  startup_trace::Mark("08 after command line parsing");

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));
  startup_trace::Mark("09 after Dart entrypoint args");

  startup_trace::Mark("10 before FlutterWindow constructor");
  FlutterWindow window(project);
  startup_trace::Mark("11 after FlutterWindow constructor");

  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  startup_trace::Mark("12 before window.Create");
  if (!window.Create(L"ai_orchestrator", origin, size)) {
    startup_trace::Mark("13 window.Create returned false");
    return EXIT_FAILURE;
  }
  startup_trace::Mark("14 window.Create returned true");
  window.SetQuitOnClose(true);

  startup_trace::Mark("15 entering message loop");
  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }
  startup_trace::Mark("16 message loop exited");

  ::CoUninitialize();
  startup_trace::Mark("17 clean shutdown");
  return EXIT_SUCCESS;
}
