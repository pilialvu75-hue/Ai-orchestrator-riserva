#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <cwchar>
#include <string>

namespace {
using PathCchRemoveBackslashFn = HRESULT (WINAPI*)(PWSTR, size_t);

PathCchRemoveBackslashFn ResolveNativeRemoveBackslash() {
  static PathCchRemoveBackslashFn resolved = []() -> PathCchRemoveBackslashFn {
    const HMODULE module = LoadLibraryW(L"api-ms-win-core-path-l1-1-0.dll");
    if (module == nullptr) return nullptr;
    return reinterpret_cast<PathCchRemoveBackslashFn>(
        GetProcAddress(module, "PathCchRemoveBackslash"));
  }();
  return resolved;
}

bool StartsWith(const std::wstring& value, const wchar_t* prefix) {
  const size_t length = std::wcslen(prefix);
  return value.size() >= length && value.compare(0, length, prefix) == 0;
}

size_t RootLength(const std::wstring& value) {
  if (StartsWith(value, L"\\\\?\\UNC\\")) {
    const size_t server_end = value.find(L'\\', 8);
    if (server_end == std::wstring::npos) return value.size();
    const size_t share_end = value.find(L'\\', server_end + 1);
    return share_end == std::wstring::npos ? value.size() : share_end + 1;
  }
  if (StartsWith(value, L"\\\\?\\") && value.size() >= 7 && value[5] == L':') {
    return 7;
  }
  if (StartsWith(value, L"\\\\")) {
    const size_t server_end = value.find(L'\\', 2);
    if (server_end == std::wstring::npos) return value.size();
    const size_t share_end = value.find(L'\\', server_end + 1);
    return share_end == std::wstring::npos ? value.size() : share_end + 1;
  }
  if (value.size() >= 3 && value[1] == L':' && value[2] == L'\\') {
    return 3;
  }
  return 0;
}
}  // namespace

extern "C" HRESULT WINAPI CompatPathCchRemoveBackslash(
    PWSTR path,
    size_t path_count) {
  if (auto native = ResolveNativeRemoveBackslash(); native != nullptr) {
    return native(path, path_count);
  }

  if (path == nullptr || path_count == 0) return E_INVALIDARG;
  const size_t length = wcsnlen_s(path, path_count);
  if (length == path_count) return E_INVALIDARG;
  if (length == 0 || path[length - 1] != L'\\') return S_FALSE;

  const std::wstring value(path, length);
  if (length <= RootLength(value)) return S_FALSE;
  path[length - 1] = L'\0';
  return S_OK;
}
