#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <pathcch.h>

#include <algorithm>
#include <cwchar>
#include <string>
#include <vector>

namespace {
using PathAllocCanonicalizeFn = HRESULT (WINAPI*)(PCWSTR, ULONG, PWSTR*);
using PathCchCombineExFn = HRESULT (WINAPI*)(PWSTR, size_t, PCWSTR, PCWSTR, ULONG);
using PathCchRemoveFileSpecFn = HRESULT (WINAPI*)(PWSTR, size_t);

HMODULE ResolveNativePathModule() {
  static HMODULE module = LoadLibraryW(L"api-ms-win-core-path-l1-1-0.dll");
  return module;
}

template <typename T>
T ResolveNativePathFunction(const char* name) {
  const HMODULE module = ResolveNativePathModule();
  if (module == nullptr) return nullptr;
  return reinterpret_cast<T>(GetProcAddress(module, name));
}

bool StartsWith(const std::wstring& value, const wchar_t* prefix) {
  const size_t length = std::wcslen(prefix);
  return value.size() >= length &&
      value.compare(0, length, prefix) == 0;
}

bool IsAbsolutePath(const std::wstring& value) {
  if (StartsWith(value, L"\\\\?\\") || StartsWith(value, L"\\\\")) {
    return true;
  }
  return value.size() >= 3 && value[1] == L':' &&
      (value[2] == L'\\' || value[2] == L'/');
}

std::wstring NormalizePath(const std::wstring& raw, bool force_extended) {
  std::wstring value = raw;
  std::replace(value.begin(), value.end(), L'/', L'\\');

  bool was_extended = false;
  if (StartsWith(value, L"\\\\?\\UNC\\")) {
    value = L"\\\\" + value.substr(8);
    was_extended = true;
  } else if (StartsWith(value, L"\\\\?\\")) {
    value = value.substr(4);
    was_extended = true;
  }

  std::wstring root;
  size_t position = 0;
  if (StartsWith(value, L"\\\\")) {
    size_t server_end = value.find(L'\\', 2);
    if (server_end == std::wstring::npos) return value;
    size_t share_end = value.find(L'\\', server_end + 1);
    if (share_end == std::wstring::npos) {
      root = value + L"\\";
      position = value.size();
    } else {
      root = value.substr(0, share_end + 1);
      position = share_end + 1;
    }
  } else if (value.size() >= 3 && value[1] == L':' && value[2] == L'\\') {
    root = value.substr(0, 3);
    position = 3;
  }

  std::vector<std::wstring> components;
  while (position <= value.size()) {
    const size_t separator = value.find(L'\\', position);
    const size_t end = separator == std::wstring::npos ? value.size() : separator;
    const std::wstring component = value.substr(position, end - position);
    if (component.empty() || component == L".") {
      // Skip duplicate separators and current-directory segments.
    } else if (component == L"..") {
      if (!components.empty() && components.back() != L"..") {
        components.pop_back();
      } else if (root.empty()) {
        components.push_back(component);
      }
    } else {
      components.push_back(component);
    }
    if (separator == std::wstring::npos) break;
    position = separator + 1;
  }

  std::wstring normalized = root;
  for (size_t i = 0; i < components.size(); ++i) {
    if (!normalized.empty() && normalized.back() != L'\\') {
      normalized.push_back(L'\\');
    }
    normalized += components[i];
  }
  if (normalized.empty()) normalized = L".";

  if (force_extended || was_extended) {
    if (StartsWith(normalized, L"\\\\")) {
      normalized = L"\\\\?\\UNC\\" + normalized.substr(2);
    } else if (!StartsWith(normalized, L"\\\\?\\")) {
      normalized = L"\\\\?\\" + normalized;
    }
  }
  return normalized;
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

HRESULT CopyResult(const std::wstring& value, PWSTR output, size_t output_count) {
  if (output == nullptr || output_count == 0) return E_INVALIDARG;
  if (value.size() + 1 > output_count) {
    return HRESULT_FROM_WIN32(ERROR_INSUFFICIENT_BUFFER);
  }
  std::wmemcpy(output, value.c_str(), value.size() + 1);
  return S_OK;
}
}  // namespace

extern "C" HRESULT WINAPI CompatPathAllocCanonicalize(
    PCWSTR path_in,
    ULONG flags,
    PWSTR* path_out) {
  static const auto native = ResolveNativePathFunction<PathAllocCanonicalizeFn>(
      "PathAllocCanonicalize");
  if (native != nullptr) return native(path_in, flags, path_out);

  if (path_in == nullptr || path_out == nullptr) return E_INVALIDARG;
  const bool force_extended =
      (flags & PATHCCH_ENSURE_IS_EXTENDED_LENGTH_PATH) != 0;
  std::wstring normalized = NormalizePath(path_in, force_extended);

  if ((flags & PATHCCH_ENSURE_TRAILING_SLASH) != 0 &&
      !normalized.empty() && normalized.back() != L'\\') {
    normalized.push_back(L'\\');
  }

  const size_t bytes = (normalized.size() + 1) * sizeof(wchar_t);
  auto* allocated = static_cast<PWSTR>(LocalAlloc(LMEM_FIXED, bytes));
  if (allocated == nullptr) return E_OUTOFMEMORY;
  std::wmemcpy(allocated, normalized.c_str(), normalized.size() + 1);
  *path_out = allocated;
  return S_OK;
}

extern "C" HRESULT WINAPI CompatPathCchCombineEx(
    PWSTR path_out,
    size_t path_out_count,
    PCWSTR path_in,
    PCWSTR more,
    ULONG flags) {
  static const auto native = ResolveNativePathFunction<PathCchCombineExFn>(
      "PathCchCombineEx");
  if (native != nullptr) {
    return native(path_out, path_out_count, path_in, more, flags);
  }

  if (path_out == nullptr || path_out_count == 0) return E_INVALIDARG;
  const std::wstring base = path_in == nullptr ? L"" : path_in;
  const std::wstring suffix = more == nullptr ? L"" : more;

  std::wstring combined;
  if (IsAbsolutePath(suffix)) {
    combined = suffix;
  } else if (base.empty()) {
    combined = suffix;
  } else if (suffix.empty()) {
    combined = base;
  } else {
    combined = base;
    if (combined.back() != L'\\' && combined.back() != L'/') {
      combined.push_back(L'\\');
    }
    combined += suffix;
  }

  const bool preserve_extended = StartsWith(base, L"\\\\?\\") ||
      StartsWith(suffix, L"\\\\?\\");
  const std::wstring normalized = NormalizePath(combined, preserve_extended);
  return CopyResult(normalized, path_out, path_out_count);
}

extern "C" HRESULT WINAPI CompatPathCchRemoveFileSpec(
    PWSTR path,
    size_t path_count) {
  static const auto native = ResolveNativePathFunction<PathCchRemoveFileSpecFn>(
      "PathCchRemoveFileSpec");
  if (native != nullptr) return native(path, path_count);

  if (path == nullptr || path_count == 0) return E_INVALIDARG;
  const size_t length = wcsnlen_s(path, path_count);
  if (length == path_count) return E_INVALIDARG;

  std::wstring value(path, length);
  const size_t root_length = RootLength(value);
  while (value.size() > root_length && !value.empty() && value.back() == L'\\') {
    value.pop_back();
  }
  if (value.size() <= root_length) return S_FALSE;

  const size_t slash = value.find_last_of(L'\\');
  if (slash == std::wstring::npos || slash < root_length) return S_FALSE;
  value.resize(slash < root_length ? root_length : slash);
  if (value.size() < root_length) value.resize(root_length);
  return CopyResult(value, path, path_count);
}
