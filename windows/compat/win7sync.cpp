#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <cstdint>

namespace {
using WaitOnAddressFn = BOOL (WINAPI*)(volatile VOID*, PVOID, SIZE_T, DWORD);
using WakeByAddressFn = VOID (WINAPI*)(PVOID);

INIT_ONCE g_init_once = INIT_ONCE_STATIC_INIT;
CRITICAL_SECTION g_wait_lock;
CONDITION_VARIABLE g_wait_condition;

BOOL CALLBACK InitializeFallback(PINIT_ONCE, PVOID, PVOID*) {
  InitializeCriticalSection(&g_wait_lock);
  InitializeConditionVariable(&g_wait_condition);
  return TRUE;
}

void EnsureFallbackInitialized() {
  InitOnceExecuteOnce(&g_init_once, InitializeFallback, nullptr, nullptr);
}

HMODULE ResolveNativeSyncModule() {
  static HMODULE module = LoadLibraryW(L"api-ms-win-core-synch-l1-2-0.dll");
  return module;
}

template <typename T>
T ResolveNativeSyncFunction(const char* name) {
  const HMODULE module = ResolveNativeSyncModule();
  if (module == nullptr) return nullptr;
  return reinterpret_cast<T>(GetProcAddress(module, name));
}

bool MemoryEquals(const volatile VOID* address, const VOID* compare, SIZE_T size) {
  if (address == nullptr || compare == nullptr) return false;
  switch (size) {
    case 1:
      return *reinterpret_cast<const volatile uint8_t*>(address) ==
          *reinterpret_cast<const uint8_t*>(compare);
    case 2:
      return *reinterpret_cast<const volatile uint16_t*>(address) ==
          *reinterpret_cast<const uint16_t*>(compare);
    case 4:
      return *reinterpret_cast<const volatile uint32_t*>(address) ==
          *reinterpret_cast<const uint32_t*>(compare);
    case 8:
      return *reinterpret_cast<const volatile uint64_t*>(address) ==
          *reinterpret_cast<const uint64_t*>(compare);
    default:
      return false;
  }
}

void WakeFallbackWaiters() {
  EnsureFallbackInitialized();

  // Synchronize the wake with the exact same lock used by the waiter around
  // its value check and SleepConditionVariableCS call. Without this lock, a
  // wake can occur after MemoryEquals() reports equality but immediately
  // before the waiter is actually queued by SleepConditionVariableCS, losing
  // the notification forever. Taking the lock forces the waker either to run
  // before the value check (so the waiter observes the new value) or after the
  // sleep operation has atomically released the lock and queued the waiter.
  EnterCriticalSection(&g_wait_lock);
  WakeAllConditionVariable(&g_wait_condition);
  LeaveCriticalSection(&g_wait_lock);
}
}  // namespace

extern "C" BOOL WINAPI CompatWaitOnAddress(
    volatile VOID* address,
    PVOID compare_address,
    SIZE_T address_size,
    DWORD milliseconds) {
  static const auto native = ResolveNativeSyncFunction<WaitOnAddressFn>(
      "WaitOnAddress");
  if (native != nullptr) {
    return native(address, compare_address, address_size, milliseconds);
  }

  if (address == nullptr || compare_address == nullptr ||
      !(address_size == 1 || address_size == 2 || address_size == 4 ||
        address_size == 8)) {
    SetLastError(ERROR_INVALID_PARAMETER);
    return FALSE;
  }

  EnsureFallbackInitialized();
  const ULONGLONG started = GetTickCount64();
  EnterCriticalSection(&g_wait_lock);

  while (MemoryEquals(address, compare_address, address_size)) {
    DWORD remaining = milliseconds;
    if (milliseconds != INFINITE) {
      const ULONGLONG elapsed = GetTickCount64() - started;
      if (elapsed >= milliseconds) {
        LeaveCriticalSection(&g_wait_lock);
        SetLastError(ERROR_TIMEOUT);
        return FALSE;
      }
      remaining = static_cast<DWORD>(milliseconds - elapsed);
    }

    if (!SleepConditionVariableCS(&g_wait_condition, &g_wait_lock, remaining)) {
      const DWORD error = GetLastError();
      if (error == ERROR_TIMEOUT &&
          MemoryEquals(address, compare_address, address_size)) {
        LeaveCriticalSection(&g_wait_lock);
        SetLastError(ERROR_TIMEOUT);
        return FALSE;
      }
    }
  }

  LeaveCriticalSection(&g_wait_lock);
  SetLastError(ERROR_SUCCESS);
  return TRUE;
}

extern "C" VOID WINAPI CompatWakeByAddressSingle(PVOID address) {
  static const auto native = ResolveNativeSyncFunction<WakeByAddressFn>(
      "WakeByAddressSingle");
  if (native != nullptr) {
    native(address);
    return;
  }

  // The fallback intentionally wakes all waiters. WaitOnAddress permits
  // spurious wakeups and callers must re-check their observed value. Using the
  // shared lock here is essential to prevent a lost-wakeup race on Windows 7.
  WakeFallbackWaiters();
}

extern "C" VOID WINAPI CompatWakeByAddressAll(PVOID address) {
  static const auto native = ResolveNativeSyncFunction<WakeByAddressFn>(
      "WakeByAddressAll");
  if (native != nullptr) {
    native(address);
    return;
  }

  WakeFallbackWaiters();
}
