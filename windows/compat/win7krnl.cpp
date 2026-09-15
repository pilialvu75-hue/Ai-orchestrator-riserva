#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winnt.h>

namespace {
using GetCurrentThreadStackLimitsFn = VOID (WINAPI*)(PULONG_PTR, PULONG_PTR);

GetCurrentThreadStackLimitsFn ResolveNativeGetCurrentThreadStackLimits() {
  static GetCurrentThreadStackLimitsFn resolved = []() -> GetCurrentThreadStackLimitsFn {
    HMODULE kernel = GetModuleHandleW(L"kernel32.dll");
    if (kernel == nullptr) {
      kernel = LoadLibraryW(L"kernel32.dll");
    }
    if (kernel == nullptr) {
      return nullptr;
    }
    return reinterpret_cast<GetCurrentThreadStackLimitsFn>(
        GetProcAddress(kernel, "GetCurrentThreadStackLimits"));
  }();
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
