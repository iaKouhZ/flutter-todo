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
  const HWND window = CreateWindowExW(0, L"STATIC", L"Todo native test", WS_OVERLAPPEDWINDOW,
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
    file.close();
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
    Require(!settings.RestoreWindowPlacement(window), "first launch has no placement");
    SetWindowPos(window, nullptr, 80, 90, 640, 480, SWP_NOZORDER | SWP_NOACTIVATE);
    WINDOWPLACEMENT before{};
    before.length = sizeof(before);
    Require(GetWindowPlacement(window, &before) != FALSE, "read normal placement");
    settings.SaveWindowPlacement(window);
    SetWindowPos(window, nullptr, 150, 160, 800, 600, SWP_NOZORDER | SWP_NOACTIVATE);
    Require(DeviceSettings(profile, startup).RestoreWindowPlacement(window), "restore normal placement");
    WINDOWPLACEMENT after{};
    after.length = sizeof(after);
    GetWindowPlacement(window, &after);
    Require(EqualRect(&before.rcNormalPosition, &after.rcNormalPosition) != FALSE,
            "normal position and size preserved");
    ShowWindow(window, SW_MAXIMIZE);
    settings.SaveWindowPlacement(window);
    ShowWindow(window, SW_RESTORE);
    Require(settings.RestoreWindowPlacement(window) && IsZoomed(window),
            "maximized state restored");
    ShowWindow(window, SW_MINIMIZE);
    settings.SaveWindowPlacement(window, true);
    ShowWindow(window, SW_RESTORE);
    Require(settings.RestoreWindowPlacement(window) && IsZoomed(window) && !IsIconic(window),
            "minimized maximized window restores maximized");
    ShowWindow(window, SW_RESTORE);
    ShowWindow(window, SW_MINIMIZE);
    settings.SaveWindowPlacement(window);
    Require(settings.RestoreWindowPlacement(window) && !IsIconic(window) && !IsZoomed(window),
            "minimized normal window restores normal");
    {
      std::ofstream invalid(profile / L"window.dat", std::ios::binary | std::ios::trunc);
      invalid << "broken";
    }
    Require(!settings.RestoreWindowPlacement(window), "invalid placement falls back safely");
    Require(DeviceSettings(profile, startup).url() == settings.url(),
            "placement does not change existing settings");
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
