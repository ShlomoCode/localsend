#ifndef RUNNER_WINDOW_PLACEMENT_H_
#define RUNNER_WINDOW_PLACEMENT_H_

#include <windows.h>

// Coordinates are the workspace coordinates of WINDOWPLACEMENT::rcNormalPosition.
// They must be passed back to SetWindowPlacement, not SetWindowPos.
bool GetNormalWindowPlacement(HWND window, RECT* bounds);
bool RestoreNormalWindowPlacement(HWND window, const RECT& bounds);

#endif  // RUNNER_WINDOW_PLACEMENT_H_
