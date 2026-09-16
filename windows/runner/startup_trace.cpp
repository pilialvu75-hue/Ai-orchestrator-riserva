#include "startup_trace.h"

#include <windows.h>

namespace {

bool BuildTracePath(wchar_t (&path)[MAX_PATH]) {
  const DWORD length = ::GetTempPathW(MAX_PATH, path);
  if (length == 0 || length >= MAX_PATH) {
    return false;
  }

  static const wchar_t kTraceName[] = L"AI-Orchestrator-win7-startup.log";
  const DWORD trace_name_chars =
      static_cast<DWORD>(sizeof(kTraceName) / sizeof(kTraceName[0]));
  if (length + trace_name_chars > MAX_PATH) {
    return false;
  }

  ::lstrcatW(path, kTraceName);
  return true;
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
}

void Mark(const char* stage) {
  AppendAndFlush(stage);
}

}  // namespace startup_trace
