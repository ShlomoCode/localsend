#include "window_placement.h"

#include <windows.h>

#include <climits>
#include <cstdio>

namespace {

bool Check(bool condition, const char* description) {
  if (!condition) {
    std::fprintf(stderr, "FAIL: %s\n", description);
  }
  return condition;
}

bool SameRect(const RECT& a, const RECT& b) {
  return a.left == b.left && a.top == b.top && a.right == b.right &&
         a.bottom == b.bottom;
}

}  // namespace

int main() {
  HWND window = ::CreateWindowExW(0, L"STATIC", L"placement test",
                                  WS_OVERLAPPEDWINDOW, 100, 100, 400, 300,
                                  nullptr, nullptr, ::GetModuleHandleW(nullptr),
                                  nullptr);
  if (!Check(window != nullptr, "create test window")) {
    return 1;
  }

  bool passed = true;
  const RECT initial{100, 100, 500, 400};
  passed &= Check(RestoreNormalWindowPlacement(window, initial),
                  "restore hidden window");
  passed &= Check(!::IsWindowVisible(window), "hidden window stays hidden");
  RECT captured{};
  passed &= Check(GetNormalWindowPlacement(window, &captured) &&
                      SameRect(captured, initial),
                  "capture hidden normal rect");

  passed &= Check(!RestoreNormalWindowPlacement(window, RECT{0, 0, 0, 100}),
                  "reject zero width");
  passed &= Check(!RestoreNormalWindowPlacement(window, RECT{INT_MIN, 0, INT_MAX, 100}),
                  "reject overflowing width");

  ::ShowWindow(window, SW_SHOWNORMAL);
  ::ShowWindow(window, SW_SHOWMAXIMIZED);
  passed &= Check(GetNormalWindowPlacement(window, &captured) &&
                      SameRect(captured, initial),
                  "capture normal rect while maximized");
  ::ShowWindow(window, SW_SHOWMINIMIZED);
  passed &= Check(GetNormalWindowPlacement(window, &captured) &&
                      SameRect(captured, initial),
                  "capture normal rect while minimized");
  ::ShowWindow(window, SW_RESTORE);

  MONITORINFO monitor_info{};
  monitor_info.cbSize = sizeof(monitor_info);
  passed &= Check(::GetMonitorInfoW(::MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST),
                                   &monitor_info) != 0,
                  "read monitor bounds");
  if (passed) {
    const RECT offscreen{monitor_info.rcMonitor.right + 100,
                         monitor_info.rcMonitor.bottom + 100,
                         monitor_info.rcMonitor.right + 500,
                         monitor_info.rcMonitor.bottom + 400};
    passed &= Check(RestoreNormalWindowPlacement(window, offscreen),
                    "restore entirely off screen");
    passed &= Check(GetNormalWindowPlacement(window, &captured) &&
                        !SameRect(captured, offscreen),
                    "Windows moves entirely off-screen placement into view");
    passed &= Check(::MonitorFromWindow(window, MONITOR_DEFAULTTONULL) != nullptr,
                    "restored window intersects a monitor");

    const RECT partial{monitor_info.rcMonitor.right - 200,
                       monitor_info.rcMonitor.top + 100,
                       monitor_info.rcMonitor.right + 200,
                       monitor_info.rcMonitor.top + 400};
    passed &= Check(RestoreNormalWindowPlacement(window, partial),
                    "restore partially off screen");
    passed &= Check(GetNormalWindowPlacement(window, &captured) &&
                        SameRect(captured, partial),
                    "partially off-screen placement is preserved");
  }

  ::DestroyWindow(window);
  return passed ? 0 : 1;
}
