#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "startup_trace.h"

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

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  startup_trace::Mark("23 before FlutterViewController constructor");
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  startup_trace::Mark("24 after FlutterViewController constructor");

  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    startup_trace::Mark("25 controller missing engine or view");
    return false;
  }
  startup_trace::Mark("26 controller engine and view ready");

  if (skip_plugins_) {
    startup_trace::Mark("27 diagnostic mode: RegisterPlugins skipped");
  } else {
    startup_trace::Mark("27 before RegisterPlugins");
    RegisterPlugins(flutter_controller_->engine());
    startup_trace::Mark("28 after RegisterPlugins");
  }

  startup_trace::Mark("29 before SetChildContent");
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  startup_trace::Mark("30 after SetChildContent");

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    startup_trace::Mark("31 first frame callback");
    this->Show();
  });
  startup_trace::Mark("32 after SetNextFrameCallback");

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
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
  // Give Flutter, including plugins, an opportunity to handle window messages.
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
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
