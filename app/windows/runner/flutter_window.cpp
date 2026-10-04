#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <cstdint>
#include <limits>
#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "window_placement.h"

namespace {

constexpr char kWindowPlacementChannel[] =
    "org.localsend.localsend_app/window-placement";

bool ReadCoordinate(const flutter::EncodableMap& values, const char* key,
                    LONG* coordinate) {
  const auto item = values.find(flutter::EncodableValue(key));
  if (item == values.end()) {
    return false;
  }

  int64_t number;
  if (const auto* value = std::get_if<int32_t>(&item->second)) {
    number = *value;
  } else if (const auto* value = std::get_if<int64_t>(&item->second)) {
    number = *value;
  } else {
    return false;
  }

  if (number < std::numeric_limits<LONG>::min() ||
      number > std::numeric_limits<LONG>::max()) {
    return false;
  }
  *coordinate = static_cast<LONG>(number);
  return true;
}

bool ReadBounds(const flutter::EncodableValue* arguments, RECT* bounds) {
  if (!arguments || !std::holds_alternative<flutter::EncodableMap>(*arguments)) {
    return false;
  }

  const auto& values = std::get<flutter::EncodableMap>(*arguments);
  if (!ReadCoordinate(values, "left", &bounds->left) ||
      !ReadCoordinate(values, "top", &bounds->top) ||
      !ReadCoordinate(values, "right", &bounds->right) ||
      !ReadCoordinate(values, "bottom", &bounds->bottom)) {
    return false;
  }
  const int64_t width = static_cast<int64_t>(bounds->right) - bounds->left;
  const int64_t height = static_cast<int64_t>(bounds->bottom) - bounds->top;
  return width > 0 && width <= std::numeric_limits<LONG>::max() &&
         height > 0 && height <= std::numeric_limits<LONG>::max();
}

}  // namespace

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
  window_placement_channel_ = std::make_unique<flutter::MethodChannel<>>(
      flutter_controller_->engine()->messenger(), kWindowPlacementChannel,
      &flutter::StandardMethodCodec::GetInstance());
  window_placement_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<>& call,
             std::unique_ptr<flutter::MethodResult<>> result) {
        if (call.method_name() == "getWindowPlacement") {
          RECT bounds{};
          if (!GetNormalWindowPlacement(GetHandle(), &bounds)) {
            result->Error("UNAVAILABLE", "Could not read window placement.");
            return;
          }
          flutter::EncodableMap values;
          values[flutter::EncodableValue("left")] = bounds.left;
          values[flutter::EncodableValue("top")] = bounds.top;
          values[flutter::EncodableValue("right")] = bounds.right;
          values[flutter::EncodableValue("bottom")] = bounds.bottom;
          result->Success(flutter::EncodableValue(values));
        } else if (call.method_name() == "restoreWindowPlacement") {
          RECT bounds{};
          if (!ReadBounds(call.arguments(), &bounds)) {
            result->Success(false);
            return;
          }
          result->Success(RestoreNormalWindowPlacement(GetHandle(), bounds));
        } else {
          result->NotImplemented();
        }
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  return true;
}

void FlutterWindow::OnDestroy() {
  window_placement_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
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
