#include "flutter_window.h"

#include <optional>
#include <cstdint>
#include <variant>
#include <psapi.h>
#pragma comment(lib, "Psapi.lib")
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

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

    // Read-only native RAM sampling; available on Windows 7 and newer.
    // The engine messenger owns the registered handler.
    flutter::MethodChannel<flutter::EncodableValue> resources(
        flutter_controller_->engine()->messenger(),
        "com.aiorchestrator/resources",
        &flutter::StandardMethodCodec::GetInstance());
    resources.SetMethodCallHandler(
        [previous_total = uint64_t{0}, previous_idle = uint64_t{0},
         has_previous = false, previous_app_ticks = uint64_t{0},
         has_app_previous = false, previous_engine_ticks = uint64_t{0},
         previous_engine_total = uint64_t{0}, previous_engine_created = uint64_t{0},
         previous_engine_pid = DWORD{0}](const auto& call, auto result) mutable {
          if (call.method_name() != "sample") {
            result->NotImplemented();
            return;
          }
          MEMORYSTATUSEX memory{};
          memory.dwLength = sizeof(memory);
          if (!GlobalMemoryStatusEx(&memory)) {
            result->Error("memory_unavailable", "GlobalMemoryStatusEx failed");
            return;
          }
          flutter::EncodableMap sample;
          sample[flutter::EncodableValue("availableBytes")] =
              flutter::EncodableValue(static_cast<int64_t>(memory.ullAvailPhys));
          sample[flutter::EncodableValue("totalBytes")] =
              flutter::EncodableValue(static_cast<int64_t>(memory.ullTotalPhys));
          PROCESS_MEMORY_COUNTERS counters{};
          counters.cb = sizeof(counters);
          if (GetProcessMemoryInfo(GetCurrentProcess(), &counters,
                                   sizeof(counters))) {
            sample[flutter::EncodableValue("rssBytes")] =
                flutter::EncodableValue(static_cast<int64_t>(counters.WorkingSetSize));
          }
          // Only the PID supplied by the process owner in Dart is sampled.
          // Compare creation time as well as PID before computing a delta.
          const auto ticks = [](const FILETIME& time) -> uint64_t {
            return (static_cast<uint64_t>(time.dwHighDateTime) << 32) |
                   time.dwLowDateTime;
          };
          DWORD engine_pid = 0;
          if (const auto* args = std::get_if<flutter::EncodableMap>(call.arguments())) {
            const auto entry = args->find(flutter::EncodableValue("enginePid"));
            if (entry != args->end()) {
              int64_t value = 0;
              if (const auto* v = std::get_if<int32_t>(&entry->second)) value = *v;
              if (const auto* v = std::get_if<int64_t>(&entry->second)) value = *v;
              if (value > 0 && value <= 0xffffffffLL &&
                  value != GetCurrentProcessId()) {
                engine_pid = static_cast<DWORD>(value);
              }
            }
          }
          FILETIME idle{}, kernel{}, user{};
          if (GetSystemTimes(&idle, &kernel, &user)) {
            const uint64_t total = ticks(kernel) + ticks(user);
            const uint64_t idle_ticks = ticks(idle);
            if (has_previous && total > previous_total &&
                idle_ticks >= previous_idle) {
              const auto delta = total - previous_total;
              const auto idle_delta = idle_ticks - previous_idle;
              if (idle_delta <= delta) {
                sample[flutter::EncodableValue("systemCpuPercent")] =
                    flutter::EncodableValue(100.0 * (delta - idle_delta) / delta);
              }
            }
            FILETIME created{}, exited{}, app_kernel{}, app_user{};
            if (GetProcessTimes(GetCurrentProcess(), &created, &exited,
                                &app_kernel, &app_user)) {
              const auto app_ticks = ticks(app_kernel) + ticks(app_user);
              if (has_previous && has_app_previous && total > previous_total &&
                  app_ticks >= previous_app_ticks &&
                  app_ticks - previous_app_ticks <= total - previous_total) {
                sample[flutter::EncodableValue("appCpuPercent")] =
                    flutter::EncodableValue(100.0 * (app_ticks - previous_app_ticks) /
                                            (total - previous_total));
              }
              previous_app_ticks = app_ticks;
              has_app_previous = true;
            } else {
              has_app_previous = false;
            }
            // Read-only access; close the handle even if the child has exited.
            HANDLE engine = engine_pid == 0 ? nullptr :
                OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ |
                            SYNCHRONIZE, FALSE, engine_pid);
            bool engine_valid = false;
            if (engine != nullptr) {
              FILETIME engine_created{}, engine_exited{}, engine_kernel{}, engine_user{};
              if (WaitForSingleObject(engine, 0) == WAIT_TIMEOUT &&
                  GetProcessTimes(engine, &engine_created, &engine_exited,
                                  &engine_kernel, &engine_user)) {
                engine_valid = true;
                const auto engine_ticks = ticks(engine_kernel) + ticks(engine_user);
                const auto created_ticks = ticks(engine_created);
                sample[flutter::EncodableValue("enginePid")] =
                    flutter::EncodableValue(static_cast<int64_t>(engine_pid));
                PROCESS_MEMORY_COUNTERS engine_memory{};
                engine_memory.cb = sizeof(engine_memory);
                if (GetProcessMemoryInfo(engine, &engine_memory, sizeof(engine_memory))) {
                  sample[flutter::EncodableValue("engineRssBytes")] =
                      flutter::EncodableValue(static_cast<int64_t>(engine_memory.WorkingSetSize));
                }
                if (previous_engine_pid == engine_pid &&
                    previous_engine_created == created_ticks &&
                    total > previous_engine_total && engine_ticks >= previous_engine_ticks &&
                    engine_ticks - previous_engine_ticks <= total - previous_engine_total) {
                  sample[flutter::EncodableValue("engineCpuPercent")] =
                      flutter::EncodableValue(100.0 * (engine_ticks - previous_engine_ticks) /
                                              (total - previous_engine_total));
                }
                previous_engine_pid = engine_pid;
                previous_engine_created = created_ticks;
                previous_engine_ticks = engine_ticks;
                previous_engine_total = total;
              }
              CloseHandle(engine);
            }
            if (!engine_valid) previous_engine_pid = 0;
            previous_total = total;
            previous_idle = idle_ticks;
            has_previous = true;
          } else {
            has_previous = false;
            has_app_previous = false;
            previous_engine_pid = 0;
          }
          result->Success(flutter::EncodableValue(sample));
        });
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
