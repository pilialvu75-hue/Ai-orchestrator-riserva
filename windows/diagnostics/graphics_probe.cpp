#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d9.h>
#include <dwmapi.h>
#include <dxgi.h>
#include <gl/GL.h>
#include <shellapi.h>
#include <strsafe.h>

#include <cstdarg>
#include <iterator>

namespace {

HANDLE g_report = INVALID_HANDLE_VALUE;
wchar_t g_report_path[MAX_PATH] = {};
int g_warnings = 0;

bool AppendPath(wchar_t (&path)[MAX_PATH], const wchar_t* suffix) {
  return SUCCEEDED(StringCchCatW(path, MAX_PATH, suffix));
}

bool EnsureDirectory(const wchar_t* path) {
  if (::CreateDirectoryW(path, nullptr)) return true;
  return ::GetLastError() == ERROR_ALREADY_EXISTS;
}

bool BuildReportPath() {
  DWORD length =
      ::GetEnvironmentVariableW(L"LOCALAPPDATA", g_report_path, MAX_PATH);
  if (length > 0 && length < MAX_PATH) {
    if (AppendPath(g_report_path, L"\\AI-Orchestrator") &&
        EnsureDirectory(g_report_path) &&
        AppendPath(g_report_path, L"\\Diagnostics") &&
        EnsureDirectory(g_report_path) &&
        AppendPath(g_report_path, L"\\AI-Orchestrator-graphics-probe.txt")) {
      return true;
    }
  }

  g_report_path[0] = L'\0';
  length = ::GetTempPathW(MAX_PATH, g_report_path);
  if (length == 0 || length >= MAX_PATH) return false;
  return AppendPath(g_report_path, L"AI-Orchestrator-graphics-probe.txt");
}

void WriteRaw(const wchar_t* text) {
  if (g_report == INVALID_HANDLE_VALUE || text == nullptr) return;
  DWORD written = 0;
  ::WriteFile(g_report,
              text,
              static_cast<DWORD>(::lstrlenW(text) * sizeof(wchar_t)),
              &written,
              nullptr);
  ::FlushFileBuffers(g_report);
}

void WriteLine(const wchar_t* text) {
  WriteRaw(text);
  WriteRaw(L"\r\n");
}

void WriteFormat(const wchar_t* format, ...) {
  wchar_t line[1024] = {};
  va_list args;
  va_start(args, format);
  const HRESULT hr = ::StringCchVPrintfW(line, 1024, format, args);
  va_end(args);
  if (SUCCEEDED(hr)) WriteLine(line);
}

void Warn(const wchar_t* format, ...) {
  ++g_warnings;
  wchar_t text[896] = {};
  va_list args;
  va_start(args, format);
  const HRESULT hr = ::StringCchVPrintfW(text, 896, format, args);
  va_end(args);
  if (SUCCEEDED(hr)) WriteFormat(L"WARN  %s", text);
}

void WriteAnsiField(const wchar_t* label, const char* value) {
  if (value == nullptr || *value == '\0') {
    WriteFormat(L"%s=<unavailable>", label);
    return;
  }
  wchar_t wide[512] = {};
  const int converted = ::MultiByteToWideChar(
      CP_ACP, 0, value, -1, wide, static_cast<int>(std::size(wide)));
  WriteFormat(L"%s=%s", label, converted > 0 ? wide : L"<conversion-failed>");
}

void ReportDesktopEnvironment() {
  WriteLine(L"[Desktop / DWM]");
  WriteFormat(L"REMOTE_SESSION=%s",
              ::GetSystemMetrics(SM_REMOTESESSION) ? L"yes" : L"no");
  WriteFormat(L"SCREEN primary=%ldx%ld virtual=%ldx%ld monitors=%ld",
              ::GetSystemMetrics(SM_CXSCREEN),
              ::GetSystemMetrics(SM_CYSCREEN),
              ::GetSystemMetrics(SM_CXVIRTUALSCREEN),
              ::GetSystemMetrics(SM_CYVIRTUALSCREEN),
              ::GetSystemMetrics(SM_CMONITORS));

  BOOL composition = FALSE;
  const HRESULT dwm = ::DwmIsCompositionEnabled(&composition);
  if (SUCCEEDED(dwm)) {
    WriteFormat(L"DWM   composition=%s", composition ? L"enabled" : L"disabled");
  } else {
    Warn(L"DwmIsCompositionEnabled failed hr=0x%08lX",
         static_cast<unsigned long>(dwm));
  }
}

BOOL CALLBACK MonitorCallback(HMONITOR monitor, HDC, LPRECT, LPARAM) {
  MONITORINFOEXW info{};
  info.cbSize = sizeof(info);
  if (!::GetMonitorInfoW(monitor, &info)) {
    Warn(L"GetMonitorInfoW failed error=%lu", ::GetLastError());
    return TRUE;
  }

  WriteFormat(L"MONITOR device=%s primary=%s rect=%ld,%ld-%ld,%ld work=%ld,%ld-%ld,%ld",
              info.szDevice,
              (info.dwFlags & MONITORINFOF_PRIMARY) != 0 ? L"yes" : L"no",
              info.rcMonitor.left,
              info.rcMonitor.top,
              info.rcMonitor.right,
              info.rcMonitor.bottom,
              info.rcWork.left,
              info.rcWork.top,
              info.rcWork.right,
              info.rcWork.bottom);
  return TRUE;
}

void ReportMonitors() {
  WriteLine(L"");
  WriteLine(L"[Monitors]");
  if (!::EnumDisplayMonitors(nullptr, nullptr, MonitorCallback, 0)) {
    Warn(L"EnumDisplayMonitors failed error=%lu", ::GetLastError());
  }
}

void ReportD3D9() {
  WriteLine(L"");
  WriteLine(L"[Direct3D 9]");

  IDirect3D9* d3d = ::Direct3DCreate9(D3D_SDK_VERSION);
  if (d3d == nullptr) {
    Warn(L"Direct3DCreate9 returned null");
    return;
  }

  const UINT count = d3d->GetAdapterCount();
  WriteFormat(L"D3D9 adapters=%u", count);
  for (UINT adapter = 0; adapter < count; ++adapter) {
    D3DADAPTER_IDENTIFIER9 identifier{};
    HRESULT hr = d3d->GetAdapterIdentifier(adapter, 0, &identifier);
    if (FAILED(hr)) {
      Warn(L"D3D9 adapter %u identifier failed hr=0x%08lX",
           adapter,
           static_cast<unsigned long>(hr));
      continue;
    }

    wchar_t description[512] = {};
    wchar_t driver[512] = {};
    ::MultiByteToWideChar(CP_ACP, 0, identifier.Description, -1,
                          description, static_cast<int>(std::size(description)));
    ::MultiByteToWideChar(CP_ACP, 0, identifier.Driver, -1,
                          driver, static_cast<int>(std::size(driver)));
    WriteFormat(L"D3D9 adapter=%u description=%s driver=%s vendor=0x%04X device=0x%04X subsystem=0x%08X revision=0x%08X",
                adapter,
                description,
                driver,
                identifier.VendorId,
                identifier.DeviceId,
                identifier.SubSysId,
                identifier.Revision);

    D3DCAPS9 caps{};
    hr = d3d->GetDeviceCaps(adapter, D3DDEVTYPE_HAL, &caps);
    if (SUCCEEDED(hr)) {
      WriteFormat(L"D3D9 caps adapter=%u vertex_shader=%u.%u pixel_shader=%u.%u max_texture=%lux%lu max_streams=%lu",
                  adapter,
                  D3DSHADER_VERSION_MAJOR(caps.VertexShaderVersion),
                  D3DSHADER_VERSION_MINOR(caps.VertexShaderVersion),
                  D3DSHADER_VERSION_MAJOR(caps.PixelShaderVersion),
                  D3DSHADER_VERSION_MINOR(caps.PixelShaderVersion),
                  caps.MaxTextureWidth,
                  caps.MaxTextureHeight,
                  caps.MaxStreams);
    } else {
      Warn(L"D3D9 GetDeviceCaps adapter=%u failed hr=0x%08lX",
           adapter,
           static_cast<unsigned long>(hr));
    }

    D3DDISPLAYMODE mode{};
    hr = d3d->GetAdapterDisplayMode(adapter, &mode);
    if (SUCCEEDED(hr)) {
      WriteFormat(L"D3D9 display adapter=%u %ux%u refresh=%u format=%u",
                  adapter,
                  mode.Width,
                  mode.Height,
                  mode.RefreshRate,
                  static_cast<unsigned int>(mode.Format));
    }

    hr = d3d->CheckDeviceType(adapter,
                              D3DDEVTYPE_HAL,
                              mode.Format,
                              D3DFMT_X8R8G8B8,
                              TRUE);
    WriteFormat(L"D3D9 windowed_device_check adapter=%u hr=0x%08lX",
                adapter,
                static_cast<unsigned long>(hr));
  }

  d3d->Release();
}

void ReportDxgi() {
  WriteLine(L"");
  WriteLine(L"[DXGI]");

  IDXGIFactory1* factory = nullptr;
  const HRESULT create = ::CreateDXGIFactory1(
      __uuidof(IDXGIFactory1), reinterpret_cast<void**>(&factory));
  if (FAILED(create) || factory == nullptr) {
    Warn(L"CreateDXGIFactory1 failed hr=0x%08lX",
         static_cast<unsigned long>(create));
    return;
  }

  for (UINT index = 0;; ++index) {
    IDXGIAdapter1* adapter = nullptr;
    const HRESULT enumerate = factory->EnumAdapters1(index, &adapter);
    if (enumerate == DXGI_ERROR_NOT_FOUND) break;
    if (FAILED(enumerate) || adapter == nullptr) {
      Warn(L"DXGI EnumAdapters1 index=%u failed hr=0x%08lX",
           index,
           static_cast<unsigned long>(enumerate));
      break;
    }

    DXGI_ADAPTER_DESC1 desc{};
    const HRESULT desc_result = adapter->GetDesc1(&desc);
    if (SUCCEEDED(desc_result)) {
      const unsigned long long mib = 1024ULL * 1024ULL;
      WriteFormat(L"DXGI adapter=%u description=%s vendor=0x%04X device=0x%04X dedicated_video=%lluMiB dedicated_system=%lluMiB shared_system=%lluMiB flags=0x%08X",
                  index,
                  desc.Description,
                  desc.VendorId,
                  desc.DeviceId,
                  static_cast<unsigned long long>(desc.DedicatedVideoMemory) / mib,
                  static_cast<unsigned long long>(desc.DedicatedSystemMemory) / mib,
                  static_cast<unsigned long long>(desc.SharedSystemMemory) / mib,
                  desc.Flags);
    } else {
      Warn(L"DXGI GetDesc1 index=%u failed hr=0x%08lX",
           index,
           static_cast<unsigned long>(desc_result));
    }
    adapter->Release();
  }

  factory->Release();
}

LRESULT CALLBACK HiddenOpenGlWindowProc(HWND window,
                                        UINT message,
                                        WPARAM wparam,
                                        LPARAM lparam) {
  return ::DefWindowProcW(window, message, wparam, lparam);
}

void ReportOpenGl() {
  WriteLine(L"");
  WriteLine(L"[OpenGL]");

  constexpr wchar_t kClassName[] = L"AI_ORCHESTRATOR_GL_DIAGNOSTIC";
  WNDCLASSW window_class{};
  window_class.style = CS_OWNDC;
  window_class.lpfnWndProc = HiddenOpenGlWindowProc;
  window_class.hInstance = ::GetModuleHandleW(nullptr);
  window_class.lpszClassName = kClassName;

  ATOM atom = ::RegisterClassW(&window_class);
  if (atom == 0 && ::GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
    Warn(L"OpenGL RegisterClass failed error=%lu", ::GetLastError());
    return;
  }

  HWND window = ::CreateWindowExW(0,
                                  kClassName,
                                  L"",
                                  WS_OVERLAPPED,
                                  0,
                                  0,
                                  32,
                                  32,
                                  nullptr,
                                  nullptr,
                                  window_class.hInstance,
                                  nullptr);
  if (window == nullptr) {
    Warn(L"OpenGL hidden window creation failed error=%lu", ::GetLastError());
    return;
  }

  HDC dc = ::GetDC(window);
  PIXELFORMATDESCRIPTOR pfd{};
  pfd.nSize = sizeof(pfd);
  pfd.nVersion = 1;
  pfd.dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER;
  pfd.iPixelType = PFD_TYPE_RGBA;
  pfd.cColorBits = 24;
  pfd.cDepthBits = 24;
  pfd.iLayerType = PFD_MAIN_PLANE;

  const int format = ::ChoosePixelFormat(dc, &pfd);
  if (format == 0 || !::SetPixelFormat(dc, format, &pfd)) {
    Warn(L"OpenGL pixel format setup failed error=%lu", ::GetLastError());
    ::ReleaseDC(window, dc);
    ::DestroyWindow(window);
    return;
  }

  HGLRC context = ::wglCreateContext(dc);
  if (context == nullptr || !::wglMakeCurrent(dc, context)) {
    Warn(L"OpenGL context creation failed error=%lu", ::GetLastError());
    if (context != nullptr) ::wglDeleteContext(context);
    ::ReleaseDC(window, dc);
    ::DestroyWindow(window);
    return;
  }

  WriteAnsiField(L"OPENGL vendor", reinterpret_cast<const char*>(::glGetString(GL_VENDOR)));
  WriteAnsiField(L"OPENGL renderer", reinterpret_cast<const char*>(::glGetString(GL_RENDERER)));
  WriteAnsiField(L"OPENGL version", reinterpret_cast<const char*>(::glGetString(GL_VERSION)));

  ::wglMakeCurrent(nullptr, nullptr);
  ::wglDeleteContext(context);
  ::ReleaseDC(window, dc);
  ::DestroyWindow(window);
  ::UnregisterClassW(kClassName, window_class.hInstance);
}

bool OpenReport() {
  if (!BuildReportPath()) return false;
  g_report = ::CreateFileW(g_report_path,
                           GENERIC_WRITE,
                           FILE_SHARE_READ | FILE_SHARE_WRITE,
                           nullptr,
                           CREATE_ALWAYS,
                           FILE_ATTRIBUTE_NORMAL,
                           nullptr);
  if (g_report == INVALID_HANDLE_VALUE) return false;
  const wchar_t bom = 0xFEFF;
  DWORD written = 0;
  ::WriteFile(g_report, &bom, sizeof(bom), &written, nullptr);
  ::FlushFileBuffers(g_report);
  return true;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE,
                      _In_opt_ HINSTANCE,
                      _In_ wchar_t*,
                      _In_ int) {
  if (!OpenReport()) {
    ::MessageBoxW(nullptr,
                  L"Impossibile creare il rapporto grafico Windows.",
                  L"AI Orchestrator - Diagnostica grafica",
                  MB_OK | MB_ICONERROR);
    return 2;
  }

  WriteLine(L"AI Orchestrator - Windows Graphics Diagnostics");
  WriteLine(L"================================================");
  WriteLine(L"No Flutter engine is started by this probe.");
  WriteLine(L"");

  ReportDesktopEnvironment();
  ReportMonitors();
  ReportD3D9();
  ReportDxgi();
  ReportOpenGl();

  WriteLine(L"");
  WriteLine(L"[Summary]");
  WriteFormat(L"diagnostic_warnings=%d", g_warnings);
  WriteFormat(L"REPORT %s", g_report_path);

  ::CloseHandle(g_report);
  g_report = INVALID_HANDLE_VALUE;
  ::ShellExecuteW(nullptr, L"open", g_report_path, nullptr, nullptr,
                  SW_SHOWNORMAL);
  return 0;
}
