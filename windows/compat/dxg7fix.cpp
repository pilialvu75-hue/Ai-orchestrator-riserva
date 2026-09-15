#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <dxgi.h>

namespace {
using CreateDXGIFactory2Fn = HRESULT (WINAPI*)(UINT, REFIID, void**);
using CreateDXGIFactory1Fn = HRESULT (WINAPI*)(REFIID, void**);

HMODULE ResolveDxgi() {
  static HMODULE module = []() -> HMODULE {
    wchar_t system_directory[MAX_PATH] = {};
    const UINT length = GetSystemDirectoryW(system_directory, MAX_PATH);
    if (length == 0 || length >= MAX_PATH) {
      return LoadLibraryW(L"dxgi.dll");
    }
    std::wstring path(system_directory);
    path += L"\\dxgi.dll";
    return LoadLibraryW(path.c_str());
  }();
  return module;
}
}  // namespace

extern "C" HRESULT WINAPI CompatCreateDXGIFactory2(
    UINT flags,
    REFIID riid,
    void** factory) {
  const HMODULE dxgi = ResolveDxgi();
  if (dxgi == nullptr) {
    return HRESULT_FROM_WIN32(GetLastError());
  }

  auto native = reinterpret_cast<CreateDXGIFactory2Fn>(
      GetProcAddress(dxgi, "CreateDXGIFactory2"));
  if (native != nullptr) {
    return native(flags, riid, factory);
  }

  // DXGI 1.3 / CreateDXGIFactory2 arrived after Windows 7. The older
  // factory creation API is sufficient for CPU-only ONNX Runtime discovery
  // and also lets callers probing newer interfaces fail normally with
  // E_NOINTERFACE rather than preventing the process from loading.
  auto legacy = reinterpret_cast<CreateDXGIFactory1Fn>(
      GetProcAddress(dxgi, "CreateDXGIFactory1"));
  if (legacy == nullptr) {
    return E_NOTIMPL;
  }
  return legacy(riid, factory);
}
