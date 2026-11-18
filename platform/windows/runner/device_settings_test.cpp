#include "device_settings.h"

#include <objbase.h>
#include <windows.h>

#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>

namespace {
void Require(bool condition, const char* description) {
  if (!condition) throw std::runtime_error(description);
}
}

int main() {
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  wchar_t temp[MAX_PATH]{};
  GetTempPathW(MAX_PATH, temp);
  const auto root = std::filesystem::path(temp) /
      (L"todo-native-test-" + std::to_wstring(GetCurrentProcessId()));
  const auto profile = root / L"profile";
  const auto startup = root / L"startup";
  const HWND window = CreateWindowExW(0, L"STATIC", L"Todo native test", WS_OVERLAPPED,
                                      0, 0, 200, 100, nullptr, nullptr,
                                      GetModuleHandleW(nullptr), nullptr);
  try {
    Require(window != nullptr, "create window");
    DeviceSettings settings(profile, startup);
    Require(settings.url().empty() && settings.password().empty() &&
            !settings.topmost() && !settings.StartupEnabled(), "defaults");
    settings.SetServer("https://example.com/todo/");
    settings.SetPassword("test-password-123");
    DeviceSettings restored(profile, startup);
    Require(restored.url() == settings.url() &&
            restored.password() == "test-password-123", "restore encrypted password");
    std::ifstream file(profile / L"settings.dat", std::ios::binary);
    const std::string bytes((std::istreambuf_iterator<char>(file)),
                             std::istreambuf_iterator<char>());
    Require(bytes.find("test-password-123") == std::string::npos, "password encrypted");
    settings.SetStartup(true);
    Require(settings.StartupEnabled(), "startup shortcut created");
    settings.SetStartup(true);
    Require(settings.StartupEnabled(), "startup enabled twice");
    settings.SetStartup(false);
    Require(!settings.StartupEnabled(), "startup shortcut removed");
    settings.SetTopmost(window, true);
    Require((GetWindowLongPtrW(window, GWL_EXSTYLE) & WS_EX_TOPMOST) != 0, "topmost enabled");
    Require(DeviceSettings(profile, startup).topmost(), "topmost persisted");
    settings.SetTopmost(window, false);
    Require((GetWindowLongPtrW(window, GWL_EXSTYLE) & WS_EX_TOPMOST) == 0, "topmost disabled");
    settings.SetServer("https://other.example/");
    Require(DeviceSettings(profile, startup).password().empty(), "server switch clears password");
    settings.SetPassword("another");
    settings.SetPassword("");
    Require(DeviceSettings(profile, startup).password().empty(), "logout clears password");
    DestroyWindow(window);
    std::filesystem::remove_all(root);
    CoUninitialize();
    std::cout << "Windows native checks passed\n";
    return 0;
  } catch (const std::exception& error) {
    if (window) DestroyWindow(window);
    std::cerr << error.what() << "\n";
    CoUninitialize();
    return 1;
  }
}
