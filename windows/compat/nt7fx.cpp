#define WIN32_LEAN_AND_MEAN
#include <windows.h>

namespace {
using AddGrowableFn = DWORD (WINAPI*)(PVOID*, PRUNTIME_FUNCTION, DWORD, DWORD, ULONG_PTR, ULONG_PTR);
using DeleteGrowableFn = VOID (WINAPI*)(PVOID);

HMODULE ResolveNtdll() {
  static HMODULE module = []() -> HMODULE {
    HMODULE loaded = GetModuleHandleW(L"ntdll.dll");
    if (loaded == nullptr) {
      loaded = LoadLibraryW(L"ntdll.dll");
    }
    return loaded;
  }();
  return module;
}

AddGrowableFn ResolveNativeAddGrowable() {
  static AddGrowableFn function = []() -> AddGrowableFn {
    const HMODULE module = ResolveNtdll();
    if (module == nullptr) return nullptr;
    return reinterpret_cast<AddGrowableFn>(
        GetProcAddress(module, "RtlAddGrowableFunctionTable"));
  }();
  return function;
}

DeleteGrowableFn ResolveNativeDeleteGrowable() {
  static DeleteGrowableFn function = []() -> DeleteGrowableFn {
    const HMODULE module = ResolveNtdll();
    if (module == nullptr) return nullptr;
    return reinterpret_cast<DeleteGrowableFn>(
        GetProcAddress(module, "RtlDeleteGrowableFunctionTable"));
  }();
  return function;
}
}  // namespace

extern "C" DWORD WINAPI CompatRtlAddGrowableFunctionTable(
    PVOID* dynamic_table,
    PRUNTIME_FUNCTION function_table,
    DWORD entry_count,
    DWORD maximum_entry_count,
    ULONG_PTR range_base,
    ULONG_PTR range_end) {
  if (auto native = ResolveNativeAddGrowable(); native != nullptr) {
    return native(dynamic_table, function_table, entry_count,
                  maximum_entry_count, range_base, range_end);
  }

  // Dart's Windows AOT/runtime records currently pass EntryCount equal to
  // MaximumEntryCount, so a fixed dynamic function table is sufficient on
  // Windows 7 where growable function tables do not exist.
  if (dynamic_table == nullptr || function_table == nullptr ||
      entry_count != maximum_entry_count || range_end <= range_base) {
    return 0xC000000DL;  // STATUS_INVALID_PARAMETER
  }

  if (!RtlAddFunctionTable(function_table, entry_count, range_base)) {
    return 0xC0000001L;  // STATUS_UNSUCCESSFUL
  }

  *dynamic_table = function_table;
  return 0;
}

extern "C" VOID WINAPI CompatRtlDeleteGrowableFunctionTable(PVOID dynamic_table) {
  if (auto native = ResolveNativeDeleteGrowable(); native != nullptr) {
    native(dynamic_table);
    return;
  }

  if (dynamic_table != nullptr) {
    RtlDeleteFunctionTable(
        reinterpret_cast<PRUNTIME_FUNCTION>(dynamic_table));
  }
}
