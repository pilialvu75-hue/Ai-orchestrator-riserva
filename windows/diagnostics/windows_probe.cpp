#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shellapi.h>
#include <strsafe.h>
#include <winver.h>

#include <cstdarg>
#include <cstdint>

namespace {

HANDLE g_report = INVALID_HANDLE_VALUE;
wchar_t g_report_path[MAX_PATH] = {};
wchar_t g_app_dir[MAX_PATH] = {};
int g_failures = 0;

struct RtlOsVersionInfoWCompat {
  ULONG dwOSVersionInfoSize;
  ULONG dwMajorVersion;
  ULONG dwMinorVersion;
  ULONG dwBuildNumber;
  ULONG dwPlatformId;
  WCHAR szCSDVersion[128];
};

using RtlGetVersionFn = LONG(WINAPI*)(RtlOsVersionInfoWCompat*);
using WaitOnAddressFn = BOOL(WINAPI*)(volatile VOID*, PVOID, SIZE_T, DWORD);
using WakeByAddressFn = VOID(WINAPI*)(PVOID);

struct SyncProbeContext {
  volatile LONG value = 0;
  WaitOnAddressFn wait = nullptr;
  BOOL wait_result = FALSE;
  DWORD wait_error = ERROR_SUCCESS;
};

bool AppendPath(wchar_t (&buffer)[MAX_PATH], const wchar_t* suffix) {
  return SUCCEEDED(StringCchCatW(buffer, MAX_PATH, suffix));
}

void WriteRaw(const wchar_t* text) {
  if (g_report == INVALID_HANDLE_VALUE || text == nullptr) return;
  DWORD written = 0;
  const DWORD bytes = static_cast<DWORD>(lstrlenW(text) * sizeof(wchar_t));
  WriteFile(g_report, text, bytes, &written, nullptr);
  FlushFileBuffers(g_report);
}

void WriteLine(const wchar_t* text) {
  WriteRaw(text);
  WriteRaw(L"\r\n");
}

void WriteFormat(const wchar_t* format, ...) {
  wchar_t buffer[1024] = {};
  va_list args;
  va_start(args, format);
  const HRESULT result = StringCchVPrintfW(buffer, 1024, format, args);
  va_end(args);
  if (SUCCEEDED(result)) {
    WriteLine(buffer);
  }
}

void RecordFailure(const wchar_t* format, ...) {
  ++g_failures;
  wchar_t buffer[1024] = {};
  va_list args;
  va_start(args, format);
  const HRESULT result = StringCchVPrintfW(buffer, 1024, format, args);
  va_end(args);
  if (SUCCEEDED(result)) {
    WriteFormat(L"FAIL  %s", buffer);
  }
}

bool EnsureDirectory(const wchar_t* path) {
  if (CreateDirectoryW(path, nullptr)) return true;
  return GetLastError() == ERROR_ALREADY_EXISTS;
}

bool BuildReportPath() {
  DWORD length = GetEnvironmentVariableW(L"LOCALAPPDATA", g_report_path, MAX_PATH);
  if (length > 0 && length < MAX_PATH) {
    if (!AppendPath(g_report_path, L"\\AI-Orchestrator") ||
        !EnsureDirectory(g_report_path) ||
        !AppendPath(g_report_path, L"\\Diagnostics") ||
        !EnsureDirectory(g_report_path) ||
        !AppendPath(g_report_path, L"\\AI-Orchestrator-windows-probe.txt")) {
      g_report_path[0] = L'\0';
    }
  } else {
    g_report_path[0] = L'\0';
  }

  if (g_report_path[0] != L'\0') return true;

  length = GetTempPathW(MAX_PATH, g_report_path);
  if (length == 0 || length >= MAX_PATH) return false;
  return AppendPath(g_report_path, L"AI-Orchestrator-windows-probe.txt");
}

bool ResolveAppDirectory() {
  const DWORD length = GetModuleFileNameW(nullptr, g_app_dir, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) return false;
  for (DWORD index = length; index > 0; --index) {
    if (g_app_dir[index - 1] == L'\\' || g_app_dir[index - 1] == L'/') {
      g_app_dir[index - 1] = L'\0';
      return true;
    }
  }
  return false;
}

bool BuildAppPath(const wchar_t* name, wchar_t (&path)[MAX_PATH]) {
  if (FAILED(StringCchCopyW(path, MAX_PATH, g_app_dir))) return false;
  if (!AppendPath(path, L"\\")) return false;
  return AppendPath(path, name);
}

void ReportFileVersion(const wchar_t* path) {
  DWORD ignored = 0;
  const DWORD bytes = GetFileVersionInfoSizeW(path, &ignored);
  if (bytes == 0) {
    WriteFormat(L"      version=<unavailable> error=%lu", GetLastError());
    return;
  }

  void* buffer = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, bytes);
  if (buffer == nullptr) {
    WriteLine(L"      version=<allocation-failed>");
    return;
  }

  if (!GetFileVersionInfoW(path, 0, bytes, buffer)) {
    WriteFormat(L"      version=<read-failed> error=%lu", GetLastError());
    HeapFree(GetProcessHeap(), 0, buffer);
    return;
  }

  VS_FIXEDFILEINFO* info = nullptr;
  UINT info_size = 0;
  if (!VerQueryValueW(buffer, L"\\", reinterpret_cast<void**>(&info), &info_size) ||
      info == nullptr || info_size < sizeof(VS_FIXEDFILEINFO)) {
    WriteLine(L"      version=<missing-fixed-info>");
    HeapFree(GetProcessHeap(), 0, buffer);
    return;
  }

  WriteFormat(L"      version=%u.%u.%u.%u",
              HIWORD(info->dwFileVersionMS),
              LOWORD(info->dwFileVersionMS),
              HIWORD(info->dwFileVersionLS),
              LOWORD(info->dwFileVersionLS));
  HeapFree(GetProcessHeap(), 0, buffer);
}

HMODULE LoadLocalDll(const wchar_t* name, bool required) {
  wchar_t path[MAX_PATH] = {};
  if (!BuildAppPath(name, path)) {
    if (required) RecordFailure(L"%s path construction failed", name);
    return nullptr;
  }

  const DWORD attributes = GetFileAttributesW(path);
  if (attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
    if (required) {
      RecordFailure(L"%s missing", name);
    } else {
      WriteFormat(L"SKIP  %s missing", name);
    }
    return nullptr;
  }

  WriteFormat(L"FILE  %s", name);
  ReportFileVersion(path);

  SetLastError(ERROR_SUCCESS);
  HMODULE module = LoadLibraryExW(path, nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
  if (module == nullptr) {
    const DWORD error = GetLastError();
    if (required) {
      RecordFailure(L"%s LoadLibrary failed error=%lu", name, error);
    } else {
      WriteFormat(L"WARN  %s LoadLibrary failed error=%lu", name, error);
    }
    return nullptr;
  }

  WriteFormat(L"PASS  %s loaded at 0x%p", name, module);
  return module;
}

void CheckExport(HMODULE module, const wchar_t* module_name, const char* export_name) {
  if (module == nullptr) return;
  FARPROC address = GetProcAddress(module, export_name);
  if (address == nullptr) {
    wchar_t export_wide[128] = {};
    MultiByteToWideChar(CP_ACP, 0, export_name, -1, export_wide, 128);
    RecordFailure(L"%s missing export %s", module_name, export_wide);
    return;
  }
  wchar_t export_wide[128] = {};
  MultiByteToWideChar(CP_ACP, 0, export_name, -1, export_wide, 128);
  WriteFormat(L"PASS  %s!%s = 0x%p", module_name, export_wide, address);
}

void ReportOsVersion() {
  HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
  auto rtl_get_version = ntdll == nullptr
      ? nullptr
      : reinterpret_cast<RtlGetVersionFn>(GetProcAddress(ntdll, "RtlGetVersion"));

  if (rtl_get_version == nullptr) {
    WriteLine(L"WARN  RtlGetVersion unavailable");
    return;
  }

  RtlOsVersionInfoWCompat version = {};
  version.dwOSVersionInfoSize = sizeof(version);
  if (rtl_get_version(&version) != 0) {
    WriteLine(L"WARN  RtlGetVersion failed");
    return;
  }

  WriteFormat(L"OS    %lu.%lu build %lu %s",
              version.dwMajorVersion,
              version.dwMinorVersion,
              version.dwBuildNumber,
              version.szCSDVersion);
  if (version.dwMajorVersion == 6 && version.dwMinorVersion == 1) {
    WriteLine(L"INFO  Windows 7 family detected");
  }
}

void ReportHardware() {
  SYSTEM_INFO system_info = {};
  GetNativeSystemInfo(&system_info);
  WriteFormat(L"CPU   architecture=%u processors=%lu page_size=%lu",
              system_info.wProcessorArchitecture,
              system_info.dwNumberOfProcessors,
              system_info.dwPageSize);
  WriteFormat(L"CPU   SSE2=%s",
              IsProcessorFeaturePresent(PF_XMMI64_INSTRUCTIONS_AVAILABLE) ? L"yes" : L"no");

  MEMORYSTATUSEX memory = {};
  memory.dwLength = sizeof(memory);
  if (GlobalMemoryStatusEx(&memory)) {
    const ULONGLONG mib = 1024ULL * 1024ULL;
    WriteFormat(L"RAM   total=%llu MiB available=%llu MiB load=%lu%%",
                memory.ullTotalPhys / mib,
                memory.ullAvailPhys / mib,
                memory.dwMemoryLoad);
  } else {
    WriteFormat(L"WARN  GlobalMemoryStatusEx failed error=%lu", GetLastError());
  }
}

void ReportNativeApiAvailability() {
  WriteLine(L"");
  WriteLine(L"[Native API availability]");

  HMODULE kernel32 = GetModuleHandleW(L"kernel32.dll");
  HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");

  const char* kernel_names[] = {
      "WaitOnAddress",
      "WakeByAddressSingle",
      "WakeByAddressAll",
      "GetCurrentThreadStackLimits",
      "CreateFile2",
      "GetProcessMitigationPolicy",
      "GetSystemTimePreciseAsFileTime",
  };
  for (const char* name : kernel_names) {
    const bool present = kernel32 != nullptr && GetProcAddress(kernel32, name) != nullptr;
    wchar_t wide_name[96] = {};
    MultiByteToWideChar(CP_ACP, 0, name, -1, wide_name, 96);
    WriteFormat(L"API   kernel32!%s native=%s", wide_name, present ? L"yes" : L"no");
  }

  const char* ntdll_names[] = {
      "RtlAddGrowableFunctionTable",
      "RtlDeleteGrowableFunctionTable",
      "RtlCaptureStackBackTrace",
  };
  for (const char* name : ntdll_names) {
    const bool present = ntdll != nullptr && GetProcAddress(ntdll, name) != nullptr;
    wchar_t wide_name[96] = {};
    MultiByteToWideChar(CP_ACP, 0, name, -1, wide_name, 96);
    WriteFormat(L"API   ntdll!%s native=%s", wide_name, present ? L"yes" : L"no");
  }
}

DWORD WINAPI SyncProbeThread(LPVOID parameter) {
  auto* context = static_cast<SyncProbeContext*>(parameter);
  LONG compare = 0;
  SetLastError(ERROR_SUCCESS);
  context->wait_result = context->wait(
      &context->value, &compare, sizeof(compare), 2000);
  context->wait_error = GetLastError();
  return 0;
}

void RunSynchronizationProbe(HMODULE sync_module) {
  WriteLine(L"");
  WriteLine(L"[Synchronization probe]");
  if (sync_module == nullptr) {
    RecordFailure(L"sync shim unavailable; probe skipped");
    return;
  }

  auto wait = reinterpret_cast<WaitOnAddressFn>(
      GetProcAddress(sync_module, "WaitOnAddress"));
  auto wake = reinterpret_cast<WakeByAddressFn>(
      GetProcAddress(sync_module, "WakeByAddressSingle"));
  if (wait == nullptr || wake == nullptr) {
    RecordFailure(L"sync shim exports unavailable; probe skipped");
    return;
  }

  SyncProbeContext context = {};
  context.wait = wait;
  HANDLE thread = CreateThread(nullptr, 0, SyncProbeThread, &context, 0, nullptr);
  if (thread == nullptr) {
    RecordFailure(L"CreateThread for sync probe failed error=%lu", GetLastError());
    return;
  }

  Sleep(100);
  InterlockedExchange(&context.value, 1);
  wake(const_cast<LONG*>(&context.value));

  const DWORD joined = WaitForSingleObject(thread, 3000);
  if (joined != WAIT_OBJECT_0) {
    RecordFailure(L"WaitOnAddress/WakeByAddressSingle probe did not complete status=%lu", joined);
    TerminateThread(thread, 3);
    CloseHandle(thread);
    return;
  }

  CloseHandle(thread);
  if (!context.wait_result || context.value != 1) {
    RecordFailure(L"WaitOnAddress probe returned result=%s error=%lu value=%ld",
                  context.wait_result ? L"true" : L"false",
                  context.wait_error,
                  context.value);
    return;
  }

  WriteFormat(L"PASS  WaitOnAddress/WakeByAddressSingle result=true value=%ld", context.value);
}

void ReportLoadedUcrt() {
  WriteLine(L"");
  WriteLine(L"[CRT]");
  HMODULE ucrt = GetModuleHandleW(L"ucrtbase.dll");
  if (ucrt == nullptr) {
    WriteLine(L"WARN  ucrtbase.dll is not loaded in probe process");
    return;
  }

  wchar_t path[MAX_PATH] = {};
  const DWORD length = GetModuleFileNameW(ucrt, path, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) {
    WriteFormat(L"WARN  GetModuleFileNameW(ucrtbase) failed error=%lu", GetLastError());
    return;
  }
  WriteFormat(L"CRT   path=%s", path);
  ReportFileVersion(path);
}

void ReportDllInventory() {
  WriteLine(L"");
  WriteLine(L"[Bundle DLL inventory / loader probe]");
  wchar_t pattern[MAX_PATH] = {};
  if (FAILED(StringCchCopyW(pattern, MAX_PATH, g_app_dir)) ||
      !AppendPath(pattern, L"\\*.dll")) {
    RecordFailure(L"DLL inventory path construction failed");
    return;
  }

  WIN32_FIND_DATAW data = {};
  HANDLE find = FindFirstFileW(pattern, &data);
  if (find == INVALID_HANDLE_VALUE) {
    RecordFailure(L"no DLLs found in application directory error=%lu", GetLastError());
    return;
  }

  do {
    if ((data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) continue;
    HMODULE module = LoadLocalDll(data.cFileName, false);
    if (module != nullptr) FreeLibrary(module);
  } while (FindNextFileW(find, &data));
  FindClose(find);
}

void CheckCompatibilityExports() {
  WriteLine(L"");
  WriteLine(L"[Compatibility shim exports]");

  HMODULE ws2 = LoadLocalDll(L"ws2fix.dll", true);
  CheckExport(ws2, L"ws2fix.dll", "GetHostNameW");

  HMODULE nt7fx = LoadLocalDll(L"nt7fx.dll", true);
  CheckExport(nt7fx, L"nt7fx.dll", "RtlAddGrowableFunctionTable");
  CheckExport(nt7fx, L"nt7fx.dll", "RtlDeleteGrowableFunctionTable");
  CheckExport(nt7fx, L"nt7fx.dll", "RtlCaptureStackBackTrace");

  HMODULE krnl = LoadLocalDll(L"win7krnl.dll", true);
  CheckExport(krnl, L"win7krnl.dll", "GetCurrentThreadStackLimits");
  CheckExport(krnl, L"win7krnl.dll", "CreateFile2");
  CheckExport(krnl, L"win7krnl.dll", "GetProcessMitigationPolicy");
  CheckExport(krnl, L"win7krnl.dll", "GetSystemTimePreciseAsFileTime");

  HMODULE path = LoadLocalDll(L"win7path-compatibility-shim.dll", true);
  CheckExport(path, L"win7path-compatibility-shim.dll", "PathAllocCanonicalize");
  CheckExport(path, L"win7path-compatibility-shim.dll", "PathCchCombineEx");
  CheckExport(path, L"win7path-compatibility-shim.dll", "PathCchRemoveFileSpec");
  CheckExport(path, L"win7path-compatibility-shim.dll", "PathCchRemoveBackslash");

  HMODULE dxg = LoadLocalDll(L"dxg7.dll", true);
  CheckExport(dxg, L"dxg7.dll", "CreateDXGIFactory2");

  HMODULE sync = LoadLocalDll(L"ai-orchestrator-sync-win7fix.dll", true);
  CheckExport(sync, L"ai-orchestrator-sync-win7fix.dll", "WaitOnAddress");
  CheckExport(sync, L"ai-orchestrator-sync-win7fix.dll", "WakeByAddressSingle");
  CheckExport(sync, L"ai-orchestrator-sync-win7fix.dll", "WakeByAddressAll");
  RunSynchronizationProbe(sync);

  if (ws2 != nullptr) FreeLibrary(ws2);
  if (nt7fx != nullptr) FreeLibrary(nt7fx);
  if (krnl != nullptr) FreeLibrary(krnl);
  if (path != nullptr) FreeLibrary(path);
  if (dxg != nullptr) FreeLibrary(dxg);
  if (sync != nullptr) FreeLibrary(sync);
}

void CheckPrimaryRuntimeDlls() {
  WriteLine(L"");
  WriteLine(L"[Primary runtime DLLs]");
  HMODULE flutter = LoadLocalDll(L"flutter_windows.dll", true);
  HMODULE onnx = LoadLocalDll(L"onnxruntime.dll", true);
  if (flutter != nullptr) FreeLibrary(flutter);
  if (onnx != nullptr) FreeLibrary(onnx);
}

bool OpenReport() {
  if (!BuildReportPath()) return false;
  g_report = CreateFileW(g_report_path,
                         GENERIC_WRITE,
                         FILE_SHARE_READ | FILE_SHARE_WRITE,
                         nullptr,
                         CREATE_ALWAYS,
                         FILE_ATTRIBUTE_NORMAL,
                         nullptr);
  if (g_report == INVALID_HANDLE_VALUE) return false;
  const wchar_t bom = 0xFEFF;
  DWORD written = 0;
  WriteFile(g_report, &bom, sizeof(bom), &written, nullptr);
  FlushFileBuffers(g_report);
  return true;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE,
                      _In_opt_ HINSTANCE,
                      _In_ wchar_t*,
                      _In_ int) {
  if (!OpenReport()) {
    MessageBoxW(nullptr,
                L"Impossibile creare il rapporto diagnostico Windows.",
                L"AI Orchestrator - Diagnostica",
                MB_OK | MB_ICONERROR);
    return 2;
  }

  WriteLine(L"AI Orchestrator - Windows Native Diagnostics Probe");
  WriteLine(L"=================================================");
  WriteLine(L"Purpose: loader/runtime compatibility diagnostics without starting Flutter.");

  if (!ResolveAppDirectory()) {
    RecordFailure(L"unable to resolve application directory error=%lu", GetLastError());
  } else {
    WriteFormat(L"APP   directory=%s", g_app_dir);
  }

  ReportOsVersion();
  ReportHardware();
  ReportLoadedUcrt();
  ReportNativeApiAvailability();

  if (g_app_dir[0] != L'\0') {
    CheckPrimaryRuntimeDlls();
    CheckCompatibilityExports();
    ReportDllInventory();
  }

  WriteLine(L"");
  WriteLine(L"[Summary]");
  if (g_failures == 0) {
    WriteLine(L"PASS  native diagnostics completed with 0 hard failures");
  } else {
    WriteFormat(L"FAIL  native diagnostics completed with %d hard failure(s)", g_failures);
  }
  WriteFormat(L"REPORT %s", g_report_path);

  CloseHandle(g_report);
  g_report = INVALID_HANDLE_VALUE;

  ShellExecuteW(nullptr, L"open", g_report_path, nullptr, nullptr, SW_SHOWNORMAL);
  return g_failures == 0 ? 0 : 3;
}
