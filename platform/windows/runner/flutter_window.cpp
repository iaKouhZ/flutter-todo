#include "flutter_window.h"

#include <optional>
#include <stdexcept>
#include <variant>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  try {
    settings_ = std::make_unique<DeviceSettings>();
    if (settings_->topmost()) {
      SetWindowPos(GetHandle(), HWND_TOPMOST, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    }
  } catch (const std::exception&) {
    MessageBoxW(GetHandle(), L"Unable to read the application settings.",
                L"Todo Endfield", MB_OK | MB_ICONERROR);
    return false;
  }

  device_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "todo_endfield/device",
      &flutter::StandardMethodCodec::GetInstance());
  device_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        using flutter::EncodableMap;
        using flutter::EncodableValue;
        try {
          const auto& method = call.method_name();
          const auto* argument = call.arguments();
          if (method == "read") {
            EncodableMap values;
            if (!settings_->url().empty()) {
              values[EncodableValue("url")] = EncodableValue(settings_->url());
              const auto password = settings_->password();
              if (!password.empty()) values[EncodableValue("password")] = EncodableValue(password);
            }
            result->Success(EncodableValue(values));
          } else if (method == "server") {
            if (!argument || !std::holds_alternative<std::string>(*argument)) {
              throw std::runtime_error("Invalid server address.");
            }
            settings_->SetServer(std::get<std::string>(*argument));
            result->Success();
          } else if (method == "password") {
            const auto* password = argument ? std::get_if<std::string>(argument) : nullptr;
            settings_->SetPassword(password ? *password : "");
            result->Success();
          } else if (method == "refreshWidget") {
            result->Success();
          } else if (method == "desktopRead") {
            result->Success(EncodableValue(EncodableMap{
                {EncodableValue("startup"), EncodableValue(settings_->StartupEnabled())},
                {EncodableValue("topmost"), EncodableValue(settings_->topmost())},
            }));
          } else if (method == "desktopSetStartup" || method == "desktopSetTopmost") {
            if (!argument || !std::holds_alternative<bool>(*argument)) {
              throw std::runtime_error("Invalid switch value.");
            }
            const bool enabled = std::get<bool>(*argument);
            if (method == "desktopSetStartup") settings_->SetStartup(enabled);
            else settings_->SetTopmost(GetHandle(), enabled);
            result->Success();
          } else {
            result->NotImplemented();
          }
        } catch (const std::exception& error) {
          result->Error("windows_settings", error.what());
        }
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    if (!settings_ || !settings_->RestoreWindowPlacement(GetHandle())) this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  device_channel_ = nullptr;
  settings_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Save only on an actual close or confirmed session end, while HWND is valid.
  // A canceled shutdown must not mark the placement as saved.
  switch (message) {
    case WM_SIZE:
      if (wparam != SIZE_MINIMIZED) maximized_before_minimize_ = wparam == SIZE_MAXIMIZED;
      break;
    case WM_CLOSE:
      SaveWindowPlacementOnce();
      break;
    case WM_QUERYENDSESSION:
      return TRUE;
    case WM_ENDSESSION:
      if (wparam) SaveWindowPlacementOnce();
      return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::SaveWindowPlacementOnce() noexcept {
  if (placement_saved_ || !settings_) return;
  try {
    settings_->SaveWindowPlacement(GetHandle(), maximized_before_minimize_);
    placement_saved_ = true;
  } catch (const std::exception& error) {
    // Persistence failure must not block a normal close or Windows shutdown.
    OutputDebugStringA(error.what());
  }
}
