#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winsock2.h>

namespace {
using GetHostNameWFn = int (WSAAPI*)(PWSTR, int);

GetHostNameWFn ResolveNativeGetHostNameW() {
  static GetHostNameWFn resolved = []() -> GetHostNameWFn {
    HMODULE ws2 = GetModuleHandleW(L"ws2_32.dll");
    if (ws2 == nullptr) {
      ws2 = LoadLibraryW(L"ws2_32.dll");
    }
    if (ws2 == nullptr) {
      return nullptr;
    }
    return reinterpret_cast<GetHostNameWFn>(
        GetProcAddress(ws2, "GetHostNameW"));
  }();
  return resolved;
}
}  // namespace

extern "C" __declspec(dllexport) int WSAAPI GetHostNameW(
    PWSTR name,
    int namelen) {
  if (auto native = ResolveNativeGetHostNameW(); native != nullptr) {
    return native(name, namelen);
  }

  if (name == nullptr || namelen <= 0) {
    WSASetLastError(WSAEFAULT);
    return SOCKET_ERROR;
  }

  char ansi_name[256] = {};
  if (gethostname(ansi_name, static_cast<int>(sizeof(ansi_name))) == SOCKET_ERROR) {
    return SOCKET_ERROR;
  }

  const int required = MultiByteToWideChar(
      CP_ACP, 0, ansi_name, -1, nullptr, 0);
  if (required <= 0 || required > namelen) {
    WSASetLastError(WSAEFAULT);
    return SOCKET_ERROR;
  }

  const int written = MultiByteToWideChar(
      CP_ACP, 0, ansi_name, -1, name, namelen);
  if (written <= 0) {
    WSASetLastError(WSAEFAULT);
    return SOCKET_ERROR;
  }
  return 0;
}
