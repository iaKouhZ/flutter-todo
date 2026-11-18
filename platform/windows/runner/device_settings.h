#ifndef RUNNER_DEVICE_SETTINGS_H_
#define RUNNER_DEVICE_SETTINGS_H_

#include <windows.h>

#include <filesystem>
#include <string>
#include <vector>

class DeviceSettings {
 public:
  explicit DeviceSettings(std::filesystem::path folder = {},
                          std::filesystem::path startup_folder = {});
  std::string url() const { return url_; }
  std::string password() const;
  bool topmost() const { return topmost_; }
  void SetServer(const std::string& url);
  void SetPassword(const std::string& password);
  void SetTopmost(HWND window, bool enabled);
  bool StartupEnabled() const;
  void SetStartup(bool enabled);
  bool RestoreWindowPlacement(HWND window) const;
  void SaveWindowPlacement(HWND window, bool minimized_from_maximized = false) const;
  static std::filesystem::path Executable();

 private:
  void Load();
  void Save() const;
  std::filesystem::path Shortcut() const;
  std::filesystem::path file_;
  std::filesystem::path startup_folder_;
  std::string url_;
  std::vector<unsigned char> encrypted_;
  bool topmost_ = false;
};

#endif
