#include "device_settings.h"

#include <shlobj.h>
#include <shobjidl.h>
#include <wincrypt.h>
#include <wrl/client.h>

#include <cstdint>
#include <fstream>
#include <iterator>
#include <stdexcept>

using Microsoft::WRL::ComPtr;

namespace {
std::filesystem::path KnownFolder(REFKNOWNFOLDERID id) {
  PWSTR value = nullptr;
  if (FAILED(SHGetKnownFolderPath(id, KF_FLAG_CREATE, nullptr, &value))) {
    throw std::runtime_error("Cannot locate the Windows user folder.");
  }
  std::filesystem::path result(value);
  CoTaskMemFree(value);
  return result;
}

void Check(HRESULT result, const char* message) {
  if (FAILED(result)) throw std::runtime_error(message);
}

ComPtr<IShellLinkW> CreateStartupLinkObject() {
  ComPtr<IShellLinkW> link;
  Check(CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER,
                         IID_PPV_ARGS(&link)), "Cannot access Windows shortcuts.");
  return link;
}

std::uint32_t ReadSize(std::istream& stream) {
  std::uint32_t value = 0;
  stream.read(reinterpret_cast<char*>(&value), sizeof(value));
  if (!stream || value > 1024 * 1024) throw std::runtime_error("Invalid settings file.");
  return value;
}

std::string ReadString(std::istream& stream) {
  std::string value(ReadSize(stream), '\0');
  stream.read(value.data(), static_cast<std::streamsize>(value.size()));
  if (!stream) throw std::runtime_error("Cannot read settings.");
  return value;
}

void WriteString(std::ostream& stream, const std::string& value) {
  const auto size = static_cast<std::uint32_t>(value.size());
  stream.write(reinterpret_cast<const char*>(&size), sizeof(size));
  stream.write(value.data(), static_cast<std::streamsize>(size));
}

std::vector<unsigned char> Protect(const std::string& password) {
  if (password.empty()) return {};
  DATA_BLOB input{static_cast<DWORD>(password.size()),
                  reinterpret_cast<BYTE*>(const_cast<char*>(password.data()))};
  DATA_BLOB output{};
  if (!CryptProtectData(&input, L"Todo Endfield", nullptr, nullptr, nullptr,
                        CRYPTPROTECT_UI_FORBIDDEN, &output)) {
    throw std::runtime_error("Windows could not encrypt the password.");
  }
  std::vector<unsigned char> result(output.pbData, output.pbData + output.cbData);
  LocalFree(output.pbData);
  return result;
}
}  // namespace

DeviceSettings::DeviceSettings(std::filesystem::path folder,
                               std::filesystem::path startup_folder)
    : startup_folder_(std::move(startup_folder)) {
  if (folder.empty()) folder = KnownFolder(FOLDERID_LocalAppData) / L"TodoEndfield";
  file_ = folder / L"settings.dat";
  Load();
}

void DeviceSettings::Load() {
  if (!std::filesystem::exists(file_)) return;
  std::ifstream stream(file_, std::ios::binary);
  const auto header = ReadString(stream);
  if (header != "TODO1") throw std::runtime_error("Invalid settings file.");
  url_ = ReadString(stream);
  const auto secret = ReadString(stream);
  encrypted_.assign(secret.begin(), secret.end());
  topmost_ = ReadSize(stream) != 0;
}

void DeviceSettings::Save() const {
  std::filesystem::create_directories(file_.parent_path());
  auto temporary = file_;
  temporary += L".tmp";
  {
    std::ofstream stream(temporary, std::ios::binary | std::ios::trunc);
    if (!stream) throw std::runtime_error("Cannot save settings.");
    WriteString(stream, "TODO1");
    WriteString(stream, url_);
    WriteString(stream, std::string(encrypted_.begin(), encrypted_.end()));
    const std::uint32_t top = topmost_ ? 1 : 0;
    stream.write(reinterpret_cast<const char*>(&top), sizeof(top));
    stream.flush();
    if (!stream) throw std::runtime_error("Cannot save settings.");
  }
  if (!MoveFileExW(temporary.c_str(), file_.c_str(),
                   MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
    std::filesystem::remove(temporary);
    throw std::runtime_error("Cannot replace the settings file.");
  }
}

std::string DeviceSettings::password() const {
  if (encrypted_.empty()) return {};
  DATA_BLOB input{static_cast<DWORD>(encrypted_.size()),
                  const_cast<BYTE*>(encrypted_.data())};
  DATA_BLOB output{};
  if (!CryptUnprotectData(&input, nullptr, nullptr, nullptr, nullptr,
                          CRYPTPROTECT_UI_FORBIDDEN, &output)) {
    throw std::runtime_error("Windows could not decrypt the saved password.");
  }
  std::string result(reinterpret_cast<char*>(output.pbData), output.cbData);
  SecureZeroMemory(output.pbData, output.cbData);
  LocalFree(output.pbData);
  return result;
}

void DeviceSettings::SetServer(const std::string& url) {
  if (url == url_) return;
  const auto previous = url_;
  const auto secret = encrypted_;
  url_ = url;
  encrypted_.clear();
  try {
    Save();
  } catch (...) {
    url_ = previous;
    encrypted_ = secret;
    throw;
  }
}

void DeviceSettings::SetPassword(const std::string& password) {
  auto encrypted = Protect(password);
  encrypted_.swap(encrypted);
  try {
    Save();
  } catch (...) {
    encrypted_.swap(encrypted);
    throw;
  }
}

void DeviceSettings::SetTopmost(HWND window, bool enabled) {
  if (!SetWindowPos(window, enabled ? HWND_TOPMOST : HWND_NOTOPMOST, 0, 0, 0, 0,
                    SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE)) {
    throw std::runtime_error("Windows could not change the window position.");
  }
  const bool previous = topmost_;
  topmost_ = enabled;
  try {
    Save();
  } catch (...) {
    topmost_ = previous;
    SetWindowPos(window, previous ? HWND_TOPMOST : HWND_NOTOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    throw;
  }
}

std::filesystem::path DeviceSettings::Executable() {
  std::wstring path(32768, L'\0');
  const auto length = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
  if (length == 0 || length >= path.size()) throw std::runtime_error("Cannot locate the application.");
  path.resize(length);
  return std::filesystem::path(path);
}

std::filesystem::path DeviceSettings::Shortcut() const {
  auto folder = startup_folder_.empty() ? KnownFolder(FOLDERID_Startup) : startup_folder_;
  return folder / L"TodoEndfield.lnk";
}

bool DeviceSettings::StartupEnabled() const {
  const auto file = Shortcut();
  if (!std::filesystem::exists(file)) return false;
  auto link = CreateStartupLinkObject();
  ComPtr<IPersistFile> persist;
  Check(link.As(&persist), "Cannot read the startup shortcut.");
  Check(persist->Load(file.c_str(), STGM_READ), "Cannot load the startup shortcut.");
  wchar_t target[32768]{};
  Check(link->GetPath(target, 32768, nullptr, SLGP_RAWPATH), "Cannot read the startup target.");
  return _wcsicmp(target, Executable().c_str()) == 0;
}

void DeviceSettings::SetStartup(bool enabled) {
  const auto shortcut = Shortcut();
  if (!enabled) {
    if (StartupEnabled()) std::filesystem::remove(shortcut);
    return;
  }
  if (std::filesystem::exists(shortcut) && !StartupEnabled()) {
    throw std::runtime_error("A different shortcut already uses the startup file name.");
  }
  auto link = CreateStartupLinkObject();
  const auto exe = Executable();
  Check(link->SetPath(exe.c_str()), "Cannot set the startup target.");
  Check(link->SetWorkingDirectory(exe.parent_path().c_str()), "Cannot set the startup directory.");
  Check(link->SetDescription(L"Todo Endfield"), "Cannot set the startup description.");
  Check(link->SetIconLocation(exe.c_str(), 0), "Cannot set the startup icon.");
  Check(link->SetShowCmd(SW_SHOWNORMAL), "Cannot set the startup window mode.");
  ComPtr<IPersistFile> persist;
  Check(link.As(&persist), "Cannot save the startup shortcut.");
  std::filesystem::create_directories(shortcut.parent_path());
  auto temp = shortcut;
  temp += L".tmp";
  Check(persist->Save(temp.c_str(), TRUE), "Cannot save the startup shortcut.");
  if (!MoveFileExW(temp.c_str(), shortcut.c_str(), MOVEFILE_REPLACE_EXISTING)) {
    std::filesystem::remove(temp);
    throw std::runtime_error("Cannot install the startup shortcut.");
  }
}
