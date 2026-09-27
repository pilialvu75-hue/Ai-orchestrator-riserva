#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winnt.h>

namespace {

struct CompatCreateFile2ExtendedParameters {
  DWORD dwSize;
  DWORD dwFileAttributes;
  DWORD dwFileFlags;
  DWORD dwSecurityQosFlags;
  LPSECURITY_ATTRIBUTES lpSecurityAttributes;
  HANDLE hTemplateFile;
};

using GetCurrentThreadStackLimitsFn = VOID (WINAPI*)(PULONG_PTR, PULONG_PTR);
using CreateFile2Fn = HANDLE (WINAPI*)(
    LPCWSTR,
    DWORD,
    DWORD,
    DWORD,
    const CompatCreateFile2ExtendedParameters*);
using GetProcessMitigationPolicyFn = BOOL (WINAPI*)(
    HANDLE,
    int,
    PVOID,
    SIZE_T);
using GetSystemTimePreciseAsFileTimeFn = VOID (WINAPI*)(LPFILETIME);

HMODULE ResolveKernel32() {
  static HMODULE kernel = []() -> HMODULE {
    HMODULE module = GetModuleHandleW(L"kernel32.dll");
    if (module == nullptr) {
      module = LoadLibraryW(L"kernel32.dll");
    }
    return module;
  }();
  return kernel;
}

template <typename T>
T ResolveKernelProc(const char* name) {
  const HMODULE kernel = ResolveKernel32();
  if (kernel == nullptr) {
    return nullptr;
  }
  return reinterpret_cast<T>(GetProcAddress(kernel, name));
}

GetCurrentThreadStackLimitsFn ResolveNativeGetCurrentThreadStackLimits() {
  static GetCurrentThreadStackLimitsFn resolved =
      ResolveKernelProc<GetCurrentThreadStackLimitsFn>(
          "GetCurrentThreadStackLimits");
  return resolved;
}

CreateFile2Fn ResolveNativeCreateFile2() {
  static CreateFile2Fn resolved =
      ResolveKernelProc<CreateFile2Fn>("CreateFile2");
  return resolved;
}

GetProcessMitigationPolicyFn ResolveNativeGetProcessMitigationPolicy() {
  static GetProcessMitigationPolicyFn resolved =
      ResolveKernelProc<GetProcessMitigationPolicyFn>(
          "GetProcessMitigationPolicy");
  return resolved;
}

GetSystemTimePreciseAsFileTimeFn ResolveNativePreciseFileTime() {
  static GetSystemTimePreciseAsFileTimeFn resolved =
      ResolveKernelProc<GetSystemTimePreciseAsFileTimeFn>(
          "GetSystemTimePreciseAsFileTime");
  return resolved;
}

}  // namespace

extern "C" VOID WINAPI CompatGetCurrentThreadStackLimits(
    PULONG_PTR low_limit,
    PULONG_PTR high_limit) {
  if (auto native = ResolveNativeGetCurrentThreadStackLimits(); native != nullptr) {
    native(low_limit, high_limit);
    return;
  }

  if (low_limit == nullptr || high_limit == nullptr) {
    return;
  }

  auto* tib = reinterpret_cast<NT_TIB*>(NtCurrentTeb());
  *high_limit = reinterpret_cast<ULONG_PTR>(tib->StackBase);

  MEMORY_BASIC_INFORMATION memory_info = {};
  if (VirtualQuery(tib->StackLimit, &memory_info, sizeof(memory_info)) ==
      sizeof(memory_info)) {
    *low_limit = reinterpret_cast<ULONG_PTR>(memory_info.AllocationBase);
  } else {
    *low_limit = reinterpret_cast<ULONG_PTR>(tib->StackLimit);
  }
}

extern "C" HANDLE WINAPI CompatCreateFile2(
    LPCWSTR file_name,
    DWORD desired_access,
    DWORD share_mode,
    DWORD creation_disposition,
    const CompatCreateFile2ExtendedParameters* parameters) {
  if (auto native = ResolveNativeCreateFile2(); native != nullptr) {
    return native(
        file_name,
        desired_access,
        share_mode,
        creation_disposition,
        parameters);
  }

  DWORD flags_and_attributes = FILE_ATTRIBUTE_NORMAL;
  LPSECURITY_ATTRIBUTES security_attributes = nullptr;
  HANDLE template_file = nullptr;

  if (parameters != nullptr) {
    if (parameters->dwSize < sizeof(CompatCreateFile2ExtendedParameters)) {
      SetLastError(ERROR_INVALID_PARAMETER);
      return INVALID_HANDLE_VALUE;
    }
    flags_and_attributes = parameters->dwFileAttributes |
        parameters->dwFileFlags |
        parameters->dwSecurityQosFlags;
    if (flags_and_attributes == 0) {
      flags_and_attributes = FILE_ATTRIBUTE_NORMAL;
    }
    security_attributes = parameters->lpSecurityAttributes;
    template_file = parameters->hTemplateFile;
  }

  return CreateFileW(
      file_name,
      desired_access,
      share_mode,
      security_attributes,
      creation_disposition,
      flags_and_attributes,
      template_file);
}

extern "C" BOOL WINAPI CompatGetProcessMitigationPolicy(
    HANDLE process,
    int mitigation_policy,
    PVOID buffer,
    SIZE_T length) {
  if (auto native = ResolveNativeGetProcessMitigationPolicy(); native != nullptr) {
    return native(process, mitigation_policy, buffer, length);
  }

  if (buffer != nullptr && length > 0) {
    ZeroMemory(buffer, length);
  }
  SetLastError(ERROR_CALL_NOT_IMPLEMENTED);
  return FALSE;
}

extern "C" VOID WINAPI CompatGetSystemTimePreciseAsFileTime(
    LPFILETIME system_time_as_file_time) {
  if (auto native = ResolveNativePreciseFileTime(); native != nullptr) {
    native(system_time_as_file_time);
    return;
  }
  GetSystemTimeAsFileTime(system_time_as_file_time);
}
