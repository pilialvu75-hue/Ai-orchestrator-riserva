#include "startup_trace.h"

#include <windows.h>

#include <cstdlib>
#include <exception>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>

namespace {

volatile LONG g_fatal_trace_active = 0;

bool AppendWide(wchar_t (&path)[MAX_PATH], const wchar_t* suffix) {
  if (suffix == nullptr) {
    return false;
  }
  const int current = ::lstrlenW(path);
  const int extra = ::lstrlenW(suffix);
  if (current < 0 || extra < 0 || current + extra >= MAX_PATH) {
    return false;
  }
  ::lstrcatW(path, suffix);
  return true;
}

bool EnsureDirectory(const wchar_t* path) {
  if (::CreateDirectoryW(path, nullptr)) {
    return true;
  }
  return ::GetLastError() == ERROR_ALREADY_EXISTS;
}

bool BuildPersistentTracePath(wchar_t (&path)[MAX_PATH]) {
  const DWORD length =
      ::GetEnvironmentVariableW(L"LOCALAPPDATA", path, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) {
    return false;
  }

  if (!AppendWide(path, L"\\AI-Orchestrator") || !EnsureDirectory(path)) {
    return false;
  }
  if (!AppendWide(path, L"\\Diagnostics") || !EnsureDirectory(path)) {
    return false;
  }
  return AppendWide(path, L"\\AI-Orchestrator-win7-startup.log");
}

bool BuildTemporaryTracePath(wchar_t (&path)[MAX_PATH]) {
  const DWORD length = ::GetTempPathW(MAX_PATH, path);
  if (length == 0 || length >= MAX_PATH) {
    return false;
  }
  return AppendWide(path, L"AI-Orchestrator-win7-startup.log");
}

bool BuildTracePath(wchar_t (&path)[MAX_PATH]) {
  path[0] = L'\0';
  if (BuildPersistentTracePath(path)) {
    return true;
  }
  path[0] = L'\0';
  return BuildTemporaryTracePath(path);
}

void AppendAndFlush(const char* stage) {
  if (stage == nullptr) {
    return;
  }

  wchar_t path[MAX_PATH] = {};
  if (!BuildTracePath(path)) {
    return;
  }

  HANDLE file = ::CreateFileW(path, FILE_APPEND_DATA,
                              FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                              OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return;
  }

  DWORD written = 0;
  ::WriteFile(file, stage, static_cast<DWORD>(::lstrlenA(stage)), &written,
              nullptr);
  static const char kNewline[] = "\r\n";
  ::WriteFile(file, kNewline, 2, &written, nullptr);
  ::FlushFileBuffers(file);
  ::CloseHandle(file);
}

void AppendHexLine(const char* label, ULONG_PTR value, int digits) {
  if (label == nullptr || digits <= 0 || digits > 16) {
    return;
  }

  char line[96] = {};
  int pos = 0;
  while (label[pos] != '\0' && pos < 70) {
    line[pos] = label[pos];
    ++pos;
  }

  if (pos + 2 + digits >= static_cast<int>(sizeof(line))) {
    return;
  }

  line[pos++] = '0';
  line[pos++] = 'x';
  static const char kHex[] = "0123456789ABCDEF";
  for (int index = digits - 1; index >= 0; --index) {
    line[pos++] = kHex[(value >> (index * 4)) & 0xF];
  }
  line[pos] = '\0';
  AppendAndFlush(line);
}

void AppendModuleForAddress(const char* label, void* address) {
  if (label == nullptr || address == nullptr) {
    return;
  }

  HMODULE module = nullptr;
  if (!::GetModuleHandleExA(
          GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
              GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
          reinterpret_cast<LPCSTR>(address), &module)) {
    AppendAndFlush("fatal_module=<unresolved>");
    return;
  }

  char module_path[MAX_PATH] = {};
  if (::GetModuleFileNameA(module, module_path, MAX_PATH) == 0) {
    AppendAndFlush("fatal_module=<path-unavailable>");
    return;
  }

  char line[MAX_PATH + 64] = {};
  if (::lstrlenA(label) + ::lstrlenA(module_path) >=
      static_cast<int>(sizeof(line))) {
    return;
  }
  ::lstrcpyA(line, label);
  ::lstrcatA(line, module_path);
  AppendAndFlush(line);
}

void AppendFaultModule(void* address) {
  AppendModuleForAddress("fatal_module=", address);
}

using CaptureStackBackTraceFn =
    USHORT(WINAPI*)(ULONG, ULONG, PVOID*, PULONG);

void AppendStackSnapshot() {
  FARPROC capture_proc = nullptr;
  HMODULE kernel32 = ::GetModuleHandleW(L"kernel32.dll");
  if (kernel32 != nullptr) {
    capture_proc = ::GetProcAddress(kernel32, "RtlCaptureStackBackTrace");
  }
  if (capture_proc == nullptr) {
    HMODULE ntdll = ::GetModuleHandleW(L"ntdll.dll");
    if (ntdll != nullptr) {
      capture_proc = ::GetProcAddress(ntdll, "RtlCaptureStackBackTrace");
    }
  }
  if (capture_proc == nullptr) {
    AppendAndFlush("fatal_stack=<capture-unavailable>");
    return;
  }

  auto capture = reinterpret_cast<CaptureStackBackTraceFn>(capture_proc);
  void* frames[12] = {};
  const USHORT count = capture(0, 12, frames, nullptr);
  for (USHORT index = 0; index < count; ++index) {
    char label[] = "fatal_stack_00=";
    label[12] = static_cast<char>('0' + ((index / 10) % 10));
    label[13] = static_cast<char>('0' + (index % 10));
    AppendHexLine(label, reinterpret_cast<ULONG_PTR>(frames[index]),
                  static_cast<int>(sizeof(void*) * 2));
    AppendModuleForAddress("fatal_stack_module=", frames[index]);
  }
}

bool IsFatalCode(DWORD code) {
  return code == 0x40000015UL ||  // STATUS_FATAL_APP_EXIT
         code == 0xC0000409UL ||  // fail-fast / stack buffer overrun
         code == 0xC0000005UL ||  // access violation
         code == 0xC000001DUL;    // illegal instruction
}

LONG CALLBACK FatalVectoredHandler(EXCEPTION_POINTERS* exception_pointers) {
  if (exception_pointers == nullptr ||
      exception_pointers->ExceptionRecord == nullptr) {
    return EXCEPTION_CONTINUE_SEARCH;
  }

  EXCEPTION_RECORD* record = exception_pointers->ExceptionRecord;
  if (!IsFatalCode(record->ExceptionCode)) {
    return EXCEPTION_CONTINUE_SEARCH;
  }

  if (::InterlockedCompareExchange(&g_fatal_trace_active, 1, 0) != 0) {
    return EXCEPTION_CONTINUE_SEARCH;
  }

  AppendAndFlush("FATAL native exception observed");
  AppendHexLine("fatal_exception_code=", record->ExceptionCode, 8);
  AppendHexLine("fatal_exception_address=",
                reinterpret_cast<ULONG_PTR>(record->ExceptionAddress),
                static_cast<int>(sizeof(void*) * 2));
  AppendFaultModule(record->ExceptionAddress);
  AppendStackSnapshot();
  return EXCEPTION_CONTINUE_SEARCH;
}

void __cdecl InvalidParameterHandler(const wchar_t*, const wchar_t*,
                                     const wchar_t*, unsigned int, uintptr_t) {
  AppendAndFlush("FATAL CRT invalid parameter handler invoked");
}

void AbortSignalHandler(int) {
  AppendAndFlush("FATAL SIGABRT observed");
}

[[noreturn]] void TerminateHandler() noexcept {
  AppendAndFlush("FATAL std::terminate invoked");
  std::abort();
}

void InstallFatalCapture() {
  ::AddVectoredExceptionHandler(1, FatalVectoredHandler);
  _set_invalid_parameter_handler(InvalidParameterHandler);
  signal(SIGABRT, AbortSignalHandler);
  std::set_terminate(TerminateHandler);
}

}  // namespace

namespace startup_trace {

void Reset() {
  wchar_t path[MAX_PATH] = {};
  if (!BuildTracePath(path)) {
    return;
  }

  HANDLE file = ::CreateFileW(path, GENERIC_WRITE,
                              FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                              CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file != INVALID_HANDLE_VALUE) {
    ::FlushFileBuffers(file);
    ::CloseHandle(file);
  }

  InstallFatalCapture();
  AppendAndFlush("00 fatal capture installed (diagnostics v2)");
}

void Mark(const char* stage) {
  AppendAndFlush(stage);
}

}  // namespace startup_trace
