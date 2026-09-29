#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shellapi.h>

#include <stdint.h>

namespace {

HANDLE g_report = INVALID_HANDLE_VALUE;
HANDLE g_child_process = nullptr;
DWORD g_child_pid = 0;
bool g_dump_written = false;

struct ModuleInfo {
  ULONG_PTR base;
  wchar_t path[MAX_PATH];
};

ModuleInfo g_modules[192] = {};
size_t g_module_count = 0;

bool AppendPath(wchar_t (&buffer)[MAX_PATH], const wchar_t* suffix) {
  if (suffix == nullptr) return false;
  const int current = lstrlenW(buffer);
  const int extra = lstrlenW(suffix);
  if (current < 0 || extra < 0 || current + extra >= MAX_PATH) return false;
  lstrcatW(buffer, suffix);
  return true;
}

bool EnsureDirectory(const wchar_t* path) {
  if (CreateDirectoryW(path, nullptr)) return true;
  return GetLastError() == ERROR_ALREADY_EXISTS;
}

bool BuildReportPath(wchar_t (&path)[MAX_PATH], const wchar_t* file_name) {
  DWORD length = GetEnvironmentVariableW(L"LOCALAPPDATA", path, MAX_PATH);
  if (length > 0 && length < MAX_PATH) {
    if (AppendPath(path, L"\\AI-Orchestrator") && EnsureDirectory(path) &&
        AppendPath(path, L"\\Diagnostics") && EnsureDirectory(path) &&
        AppendPath(path, L"\\") && AppendPath(path, file_name)) {
      return true;
    }
  }

  path[0] = L'\0';
  length = GetTempPathW(MAX_PATH, path);
  if (length == 0 || length >= MAX_PATH) return false;
  return AppendPath(path, file_name);
}

void WriteRaw(const wchar_t* text) {
  if (g_report == INVALID_HANDLE_VALUE || text == nullptr) return;
  DWORD written = 0;
  WriteFile(g_report, text,
            static_cast<DWORD>(lstrlenW(text) * sizeof(wchar_t)),
            &written, nullptr);
  FlushFileBuffers(g_report);
}

void WriteLine(const wchar_t* text) {
  WriteRaw(text);
  WriteRaw(L"\r\n");
}

void WriteHexLine(const wchar_t* label, ULONG_PTR value) {
  wchar_t line[160] = {};
#ifdef _WIN64
  wsprintfW(line, L"%s0x%016I64X", label, static_cast<unsigned __int64>(value));
#else
  wsprintfW(line, L"%s0x%08lX", label, static_cast<unsigned long>(value));
#endif
  WriteLine(line);
}

void WriteDecLine(const wchar_t* label, DWORD value) {
  wchar_t line[160] = {};
  wsprintfW(line, L"%s%lu", label, value);
  WriteLine(line);
}

bool ResolveAppDirectory(wchar_t (&directory)[MAX_PATH]) {
  const DWORD length = GetModuleFileNameW(nullptr, directory, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) return false;
  for (DWORD index = length; index > 0; --index) {
    if (directory[index - 1] == L'\\' || directory[index - 1] == L'/') {
      directory[index - 1] = L'\0';
      return true;
    }
  }
  return false;
}

void NormalizeHandlePath(wchar_t (&path)[MAX_PATH]) {
  const wchar_t prefix[] = L"\\\\?\\";
  if (wcsncmp(path, prefix, 4) == 0) {
    MoveMemory(path, path + 4, (lstrlenW(path + 4) + 1) * sizeof(wchar_t));
  }
}

void ResolvePathFromHandle(HANDLE file, wchar_t (&path)[MAX_PATH]) {
  path[0] = L'\0';
  if (file == nullptr || file == INVALID_HANDLE_VALUE) return;
  const DWORD length = GetFinalPathNameByHandleW(file, path, MAX_PATH,
                                                 FILE_NAME_NORMALIZED);
  if (length == 0 || length >= MAX_PATH) {
    path[0] = L'\0';
    return;
  }
  NormalizeHandlePath(path);
}

void RecordModule(ULONG_PTR base, const wchar_t* path) {
  if (g_module_count >= (sizeof(g_modules) / sizeof(g_modules[0]))) return;
  g_modules[g_module_count].base = base;
  g_modules[g_module_count].path[0] = L'\0';
  if (path != nullptr && path[0] != L'\0') {
    lstrcpynW(g_modules[g_module_count].path, path, MAX_PATH);
  }
  ++g_module_count;
}

const wchar_t* FindModuleForAddress(ULONG_PTR address, ULONG_PTR* base_out) {
  const ModuleInfo* best = nullptr;
  for (size_t i = 0; i < g_module_count; ++i) {
    if (g_modules[i].base <= address &&
        (best == nullptr || g_modules[i].base > best->base)) {
      best = &g_modules[i];
    }
  }
  if (best == nullptr) return nullptr;
  if (base_out != nullptr) *base_out = best->base;
  return best->path;
}

using MiniDumpWriteDumpFn = BOOL(WINAPI*)(HANDLE, DWORD, HANDLE, DWORD,
                                          void*, void*, void*);

void WriteChildMiniDump() {
  if (g_dump_written || g_child_process == nullptr) return;
  g_dump_written = true;

  wchar_t system_dir[MAX_PATH] = {};
  const UINT length = GetSystemDirectoryW(system_dir, MAX_PATH);
  if (length == 0 || length >= MAX_PATH ||
      !AppendPath(system_dir, L"\\dbghelp.dll")) {
    WriteLine(L"DUMP  dbghelp path unavailable");
    return;
  }

  HMODULE dbghelp = LoadLibraryW(system_dir);
  if (dbghelp == nullptr) {
    WriteDecLine(L"DUMP  LoadLibrary(dbghelp) error=", GetLastError());
    return;
  }

  auto write_dump = reinterpret_cast<MiniDumpWriteDumpFn>(
      GetProcAddress(dbghelp, "MiniDumpWriteDump"));
  if (write_dump == nullptr) {
    WriteLine(L"DUMP  MiniDumpWriteDump unavailable");
    FreeLibrary(dbghelp);
    return;
  }

  wchar_t dump_path[MAX_PATH] = {};
  if (!BuildReportPath(dump_path, L"AI-Orchestrator-bootstrap-crash.dmp")) {
    WriteLine(L"DUMP  output path unavailable");
    FreeLibrary(dbghelp);
    return;
  }

  HANDLE dump = CreateFileW(dump_path, GENERIC_WRITE, FILE_SHARE_READ, nullptr,
                            CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (dump == INVALID_HANDLE_VALUE) {
    WriteDecLine(L"DUMP  create error=", GetLastError());
    FreeLibrary(dbghelp);
    return;
  }

  // MiniDumpNormal = 0.  We deliberately omit target exception pointers here:
  // this harness runs outside the crashing process and captures the process
  // state at the debug event boundary instead.
  const BOOL ok = write_dump(g_child_process, g_child_pid, dump, 0,
                             nullptr, nullptr, nullptr);
  const DWORD error = ok ? ERROR_SUCCESS : GetLastError();
  FlushFileBuffers(dump);
  CloseHandle(dump);
  FreeLibrary(dbghelp);

  if (ok) {
    WriteLine(L"DUMP  AI-Orchestrator-bootstrap-crash.dmp written");
  } else {
    WriteDecLine(L"DUMP  MiniDumpWriteDump error=", error);
  }
}

bool IsInterestingFatal(DWORD code) {
  return code == 0x40000015UL ||  // STATUS_FATAL_APP_EXIT
         code == 0xC0000409UL ||  // fail-fast / stack buffer overrun
         code == 0xC0000005UL ||  // access violation
         code == 0xC000001DUL;    // illegal instruction
}

DWORD ContinueStatusFor(const DEBUG_EVENT& event) {
  if (event.dwDebugEventCode != EXCEPTION_DEBUG_EVENT) return DBG_CONTINUE;
  const DWORD code = event.u.Exception.ExceptionRecord.ExceptionCode;
  if (code == EXCEPTION_BREAKPOINT || code == 0x40010006UL) {
    return DBG_CONTINUE;
  }
  return DBG_EXCEPTION_NOT_HANDLED;
}

void LogException(const DEBUG_EVENT& event) {
  const EXCEPTION_DEBUG_INFO& info = event.u.Exception;
  const DWORD code = info.ExceptionRecord.ExceptionCode;
  const ULONG_PTR address = reinterpret_cast<ULONG_PTR>(
      info.ExceptionRecord.ExceptionAddress);

  WriteLine(L"");
  WriteLine(L"[EXCEPTION]");
  WriteHexLine(L"code=", code);
  WriteHexLine(L"address=", address);
  WriteDecLine(L"first_chance=", info.dwFirstChance);
  WriteDecLine(L"thread_id=", event.dwThreadId);

  ULONG_PTR module_base = 0;
  const wchar_t* module = FindModuleForAddress(address, &module_base);
  if (module != nullptr && module[0] != L'\0') {
    WriteRaw(L"module=");
    WriteLine(module);
    WriteHexLine(L"module_base=", module_base);
    WriteHexLine(L"module_offset=", address - module_base);
  } else {
    WriteLine(L"module=<unresolved>");
  }

  if (IsInterestingFatal(code)) {
    WriteLine(L"classification=interesting-fatal");
    WriteChildMiniDump();
  }
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE,
                      _In_opt_ HINSTANCE,
                      _In_ wchar_t* command_line,
                      _In_ int) {
  wchar_t report_path[MAX_PATH] = {};
  if (!BuildReportPath(report_path, L"AI-Orchestrator-bootstrap-probe.txt")) {
    MessageBoxW(nullptr, L"Impossibile creare il rapporto bootstrap.",
                L"AI Orchestrator - Bootstrap diagnostics",
                MB_OK | MB_ICONERROR);
    return 2;
  }

  g_report = CreateFileW(report_path, GENERIC_WRITE,
                         FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                         CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (g_report == INVALID_HANDLE_VALUE) return 2;

  const wchar_t bom = 0xFEFF;
  DWORD written = 0;
  WriteFile(g_report, &bom, sizeof(bom), &written, nullptr);
  WriteLine(L"AI Orchestrator - pre-main bootstrap debug harness");
  WriteLine(L"================================================");

  wchar_t app_dir[MAX_PATH] = {};
  if (!ResolveAppDirectory(app_dir)) {
    WriteLine(L"FAIL  application directory unavailable");
    CloseHandle(g_report);
    return 3;
  }

  wchar_t target[MAX_PATH] = {};
  lstrcpynW(target, app_dir, MAX_PATH);
  if (!AppendPath(target, L"\\ai_orchestrator.exe")) {
    WriteLine(L"FAIL  target path too long");
    CloseHandle(g_report);
    return 3;
  }

  wchar_t child_command[4096] = {};
  wsprintfW(child_command, L"\"%s\"", target);
  if (command_line != nullptr && command_line[0] != L'\0') {
    if (lstrlenW(child_command) + 1 + lstrlenW(command_line) <
        static_cast<int>(sizeof(child_command) / sizeof(child_command[0]))) {
      lstrcatW(child_command, L" ");
      lstrcatW(child_command, command_line);
    }
  }

  WriteRaw(L"TARGET ");
  WriteLine(target);
  WriteRaw(L"ARGS   ");
  WriteLine(command_line == nullptr ? L"" : command_line);

  STARTUPINFOW startup = {};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process = {};
  const BOOL created = CreateProcessW(
      target, child_command, nullptr, nullptr, FALSE,
      DEBUG_ONLY_THIS_PROCESS | CREATE_NEW_PROCESS_GROUP,
      nullptr, app_dir, &startup, &process);
  if (!created) {
    WriteDecLine(L"FAIL  CreateProcessW error=", GetLastError());
    CloseHandle(g_report);
    ShellExecuteW(nullptr, L"open", report_path, nullptr, nullptr, SW_SHOWNORMAL);
    return 4;
  }

  g_child_process = process.hProcess;
  g_child_pid = process.dwProcessId;
  CloseHandle(process.hThread);
  WriteDecLine(L"CHILD pid=", g_child_pid);

  bool running = true;
  while (running) {
    DEBUG_EVENT event = {};
    if (!WaitForDebugEvent(&event, INFINITE)) {
      WriteDecLine(L"FAIL  WaitForDebugEvent error=", GetLastError());
      break;
    }

    switch (event.dwDebugEventCode) {
      case CREATE_PROCESS_DEBUG_EVENT: {
        wchar_t path[MAX_PATH] = {};
        ResolvePathFromHandle(event.u.CreateProcessInfo.hFile, path);
        if (path[0] == L'\0') lstrcpynW(path, target, MAX_PATH);
        RecordModule(reinterpret_cast<ULONG_PTR>(event.u.CreateProcessInfo.lpBaseOfImage), path);
        WriteLine(L"");
        WriteLine(L"[CREATE_PROCESS]");
        WriteHexLine(L"base=", reinterpret_cast<ULONG_PTR>(event.u.CreateProcessInfo.lpBaseOfImage));
        WriteRaw(L"image=");
        WriteLine(path);
        if (event.u.CreateProcessInfo.hFile != nullptr) {
          CloseHandle(event.u.CreateProcessInfo.hFile);
        }
        if (event.u.CreateProcessInfo.hThread != nullptr) {
          CloseHandle(event.u.CreateProcessInfo.hThread);
        }
        if (event.u.CreateProcessInfo.hProcess != nullptr &&
            event.u.CreateProcessInfo.hProcess != g_child_process) {
          CloseHandle(event.u.CreateProcessInfo.hProcess);
        }
        break;
      }
      case LOAD_DLL_DEBUG_EVENT: {
        wchar_t path[MAX_PATH] = {};
        ResolvePathFromHandle(event.u.LoadDll.hFile, path);
        const ULONG_PTR base = reinterpret_cast<ULONG_PTR>(event.u.LoadDll.lpBaseOfDll);
        RecordModule(base, path);
        WriteRaw(L"LOAD  ");
        WriteHexLine(L"base=", base);
        if (path[0] != L'\0') {
          WriteRaw(L"      path=");
          WriteLine(path);
        }
        if (event.u.LoadDll.hFile != nullptr) CloseHandle(event.u.LoadDll.hFile);
        break;
      }
      case EXCEPTION_DEBUG_EVENT:
        LogException(event);
        break;
      case EXIT_PROCESS_DEBUG_EVENT:
        WriteLine(L"");
        WriteLine(L"[EXIT_PROCESS]");
        WriteDecLine(L"exit_code=", event.u.ExitProcess.dwExitCode);
        running = false;
        break;
      default:
        break;
    }

    const DWORD continue_status = ContinueStatusFor(event);
    ContinueDebugEvent(event.dwProcessId, event.dwThreadId, continue_status);
  }

  if (g_child_process != nullptr) {
    CloseHandle(g_child_process);
    g_child_process = nullptr;
  }
  WriteLine(L"");
  WriteLine(L"END bootstrap debug session");
  CloseHandle(g_report);
  g_report = INVALID_HANDLE_VALUE;

  ShellExecuteW(nullptr, L"open", report_path, nullptr, nullptr, SW_SHOWNORMAL);
  return 0;
}
