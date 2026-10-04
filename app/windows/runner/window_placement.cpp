#include "window_placement.h"

#include <cstdint>
#include <limits>

namespace {

bool HasPositiveSize(const RECT& bounds) {
  const int64_t width = static_cast<int64_t>(bounds.right) - bounds.left;
  const int64_t height = static_cast<int64_t>(bounds.bottom) - bounds.top;
  return width > 0 && width <= std::numeric_limits<LONG>::max() &&
         height > 0 && height <= std::numeric_limits<LONG>::max();
}

}  // namespace

bool GetNormalWindowPlacement(HWND window, RECT* bounds) {
  if (!window || !bounds) {
    return false;
  }

  WINDOWPLACEMENT placement{};
  placement.length = sizeof(placement);
  if (!::GetWindowPlacement(window, &placement) ||
      !HasPositiveSize(placement.rcNormalPosition)) {
    return false;
  }

  *bounds = placement.rcNormalPosition;
  return true;
}

bool RestoreNormalWindowPlacement(HWND window, const RECT& bounds) {
  if (!window || !HasPositiveSize(bounds)) {
    return false;
  }

  WINDOWPLACEMENT placement{};
  placement.length = sizeof(placement);
  if (!::GetWindowPlacement(window, &placement)) {
    return false;
  }

  placement.rcNormalPosition = bounds;
  // The runner starts hidden. Applying a normal show command here would flash
  // the window before window_manager decides whether to show it.
  if (!::IsWindowVisible(window)) {
    placement.showCmd = SW_HIDE;
  }
  return ::SetWindowPlacement(window, &placement) != 0;
}
