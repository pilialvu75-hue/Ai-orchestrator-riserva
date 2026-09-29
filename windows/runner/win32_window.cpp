#include "win32_window.h"

#include <dwmapi.h>
#include <flutter_windows.h>

#include "resource.h"

/// Window attribute that enables dark mode window decorations.
///
/// Keep this under a project-local name because newer Windows SDKs expose
/// DWMWA_USE_IMMERSIVE_DARK_MODE themselves, which makes a same-name fallback
/// ambiguous at compile time.
constexpr DWORD kDwmwaUseImmersiveDarkMode = 20;

namespace {

constexpr wchar_t kWindowStateRegistryKey[] =
    L"Software\\AI-Orchestrator\\Window";
constexpr wchar_t kWindowPlacementValue[] = L"Placement";
constexpr unsigned int kMinimumWindowWidth = 640;
constexpr unsigned int kMinimumWindowHeight = 480;

bool SavedPlacementIsVisible(const WINDOWPLACEMENT& placement) {
  RECT rect = placement.rcNormalPosition;
  if (rect.right <= rect.left || rect.bottom <= rect.top) {
    return false;
  }
  return ::MonitorFromRect(&rect, MONITOR_DEFAULTTONULL) != nullptr;
}

bool RestoreWindowPlacement(HWND window) {
  WINDOWPLACEMENT placement{};
  placement.length = sizeof(placement);
  DWORD bytes = sizeof(placement);
  const LSTATUS result = ::RegGetValueW(
      HKEY_CURRENT_USER,
      kWindowStateRegistryKey,
      kWindowPlacementValue,
      RRF_RT_REG_BINARY,
      nullptr,
      &placement,
      &bytes);
  if (result != ERROR_SUCCESS || bytes != sizeof(placement) ||
      placement.length != sizeof(placement) ||
      !SavedPlacementIsVisible(placement)) {
    return false;
  }

  // Never restore a minimized window. Preserve maximized state, otherwise
  // restore as a normal desktop window.
  if (placement.showCmd != SW_SHOWMAXIMIZED) {
    placement.showCmd = SW_SHOWNORMAL;
    placement.flags = 0;
  }
  return ::SetWindowPlacement(window, &placement) != FALSE;
}

void SaveWindowPlacement(HWND window) {
  WINDOWPLACEMENT placement{};
  placement.length = sizeof(placement);
  if (!::GetWindowPlacement(window, &placement)) {
    return;
  }

  if (placement.showCmd == SW_SHOWMINIMIZED ||
      placement.showCmd == SW_MINIMIZE ||
      placement.showCmd == SW_SHOWMINNOACTIVE) {
    placement.showCmd = SW_SHOWNORMAL;
    placement.flags = 0;
  }

  HKEY key = nullptr;
  DWORD disposition = 0;
  if (::RegCreateKeyExW(
          HKEY_CURRENT_USER,
          kWindowStateRegistryKey,
          0,
          nullptr,
          REG_OPTION_NON_VOLATILE,
          KEY_SET_VALUE,
          nullptr,
          &key,
          &disposition) != ERROR_SUCCESS) {
    return;
  }

  ::RegSetValueExW(
      key,
      kWindowPlacementValue,
      0,
      REG_BINARY,
      reinterpret_cast<const BYTE*>(&placement),
      static_cast<DWORD>(sizeof(placement)));
  ::RegCloseKey(key);
}

void CenterWindowOnNearestMonitor(HWND window) {
  RECT rect{};
  if (!::GetWindowRect(window, &rect)) {
    return;
  }

  HMONITOR monitor = ::MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST);
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  if (!::GetMonitorInfoW(monitor, &info)) {
    return;
  }

  const LONG width = rect.right - rect.left;
  const LONG height = rect.bottom - rect.top;
  const LONG work_width = info.rcWork.right - info.rcWork.left;
  const LONG work_height = info.rcWork.bottom - info.rcWork.top;
  const LONG x = info.rcWork.left + (work_width - width) / 2;
  const LONG y = info.rcWork.top + (work_height - height) / 2;

  ::SetWindowPos(window, nullptr, x, y, 0, 0,
                 SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
}

}  // namespace

/// A class that wraps a window class registration and ensures that
/// registration is cleaned up when no longer needed.
///
/// This intentionally lives in the global namespace: Win32Window declares it
/// as a friend in win32_window.h so it can register the private WndProc.
class WindowClassRegistrar {
 public:
  ~WindowClassRegistrar() {
    if (registered_) {
      if (::UnregisterClass(kClassName, nullptr)) {
        registered_ = false;
      }
    }
  }

  // Returns the singleton registrar instance.
  static WindowClassRegistrar* GetInstance() {
    static WindowClassRegistrar* registrar = new WindowClassRegistrar();
    return registrar;
  }

  // Returns the name of the window class, registering the class if necessary.
  const wchar_t* GetWindowClass();

  // Unregisters the window class. Should only be called if there are no
  // instances of the window.
  void UnregisterWindowClass();

 private:
  WindowClassRegistrar() = default;

  bool registered_ = false;

  static constexpr const wchar_t kClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
};

const wchar_t* WindowClassRegistrar::GetWindowClass() {
  if (!registered_) {
    WNDCLASS window_class{};
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kClassName;
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIconW(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    window_class.hbrBackground = 0;
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    registered_ = true;
  }
  return kClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  if (::UnregisterClass(kClassName, nullptr)) {
    registered_ = false;
  }
}

// The number of Win32Window objects that currently exist.
static int g_active_window_count = 0;

Win32Window::Win32Window() {
  ++g_active_window_count;
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
}

bool Win32Window::Create(const std::wstring& title,
                         const Point& origin,
                         const Size& size) {
  Destroy();

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();

  const POINT target_point = {static_cast<LONG>(origin.x),
                               static_cast<LONG>(origin.y)};
  HMONITOR monitor = MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale_factor = dpi / 96.0;

  HWND window = CreateWindow(
      window_class, title.c_str(), WS_OVERLAPPEDWINDOW,
      static_cast<int>(origin.x * scale_factor),
      static_cast<int>(origin.y * scale_factor),
      static_cast<int>(size.width * scale_factor),
      static_cast<int>(size.height * scale_factor),
      nullptr, nullptr, GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }

  if (!RestoreWindowPlacement(window)) {
    CenterWindowOnNearestMonitor(window);
  }

  UpdateTheme(window);

  return OnCreate();
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_handle_);
  RECT frame = GetClientArea();

  MoveWindow(content, frame.left, frame.top, frame.right - frame.left,
             frame.bottom - frame.top, true);

  SetFocus(child_content_);
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  return frame;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

void Win32Window::Destroy() {
  OnDestroy();

  if (window_handle_) {
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }

  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

LRESULT
Win32Window::MessageHandler(HWND hwnd, UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  switch (message) {
    case WM_CLOSE:
      SaveWindowPlacement(hwnd);
      break;

    case WM_DESTROY:
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;

    case WM_GETMINMAXINFO: {
      auto* min_max = reinterpret_cast<MINMAXINFO*>(lparam);
      HMONITOR monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
      const UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
      const double scale_factor = dpi / 96.0;
      min_max->ptMinTrackSize.x =
          static_cast<LONG>(kMinimumWindowWidth * scale_factor);
      min_max->ptMinTrackSize.y =
          static_cast<LONG>(kMinimumWindowHeight * scale_factor);
      return 0;
    }

    case WM_DPICHANGED: {
      auto newRectSize = reinterpret_cast<RECT*>(lparam);
      LONG newWidth = newRectSize->right - newRectSize->left;
      LONG newHeight = newRectSize->bottom - newRectSize->top;

      SetWindowPos(hwnd, nullptr, newRectSize->left, newRectSize->top, newWidth,
                   newHeight, SWP_NOZORDER | SWP_NOACTIVATE);
      return 0;
    }

    case WM_SIZE: {
      RECT frame = GetClientArea();
      if (child_content_ != nullptr) {
        // Size and position the child window.
        MoveWindow(child_content_, frame.left, frame.top,
                   frame.right - frame.left, frame.bottom - frame.top, TRUE);
      }
      return 0;
    }

    case WM_ACTIVATE:
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;

    case WM_DWMCOLORIZATIONCOLORCHANGED:
      UpdateTheme(hwnd);
      return 0;
  }

  return DefWindowProc(hwnd, message, wparam, lparam);
}

void Win32Window::OnDestroy() {
  // No-op; provided for subclasses.
}

bool Win32Window::OnCreate() {
  // No-op; provided for subclasses.
  return true;
}

void Win32Window::Show() {
  ShowWindow(window_handle_, SW_SHOWNORMAL);
  UpdateWindow(window_handle_);
}

// static
LRESULT CALLBACK Win32Window::WndProc(HWND const window, UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));
    auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
    that->window_handle_ = window;
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

// static
Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

// static
void Win32Window::UpdateTheme(HWND const window) {
  DWORD light_mode;
  DWORD light_mode_size = sizeof(light_mode);
  LSTATUS result = RegGetValue(
      HKEY_CURRENT_USER,
      L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
      L"AppsUseLightTheme", RRF_RT_REG_DWORD, nullptr, &light_mode,
      &light_mode_size);

  if (result == ERROR_SUCCESS) {
    BOOL enable_dark_mode = light_mode == 0;
    DwmSetWindowAttribute(window, kDwmwaUseImmersiveDarkMode,
                          &enable_dark_mode, sizeof(enable_dark_mode));
  }
}
