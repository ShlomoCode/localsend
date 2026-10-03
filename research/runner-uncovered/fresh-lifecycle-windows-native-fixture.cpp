#include <windows.h>
#include <cstdio>
#include <cstdlib>

// Run on an isolated Windows runner; no sleep, suspend, or power setting changes.
// The after flags expression is identical to the native MethodChannel prototype.
bool snapshot() {
  std::fflush(stdout);
  return std::system("powercfg /requests") == 0;
}

int main() {
  const DWORD thread = GetCurrentThreadId();
  const auto initial = SetThreadExecutionState(ES_CONTINUOUS);
  if (initial == 0) return 1;
  std::puts("=== BASELINE IDLE ===");
  if (!snapshot()) return 10;

  const auto before = ES_CONTINUOUS | ES_DISPLAY_REQUIRED;
  if (SetThreadExecutionState(before) == 0) return 2;
  std::puts("=== BEFORE ACTIVE: DISPLAY ONLY ===");
  if (!snapshot()) return 11;
  const auto beforeCleared = SetThreadExecutionState(ES_CONTINUOUS);
  if (beforeCleared == 0) return 3;

  const bool enable = true;
  const auto flags = ES_CONTINUOUS | (enable ? ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED : 0);
  if (SetThreadExecutionState(flags) == 0) return 4;
  std::puts("=== AFTER ACTIVE: SYSTEM + DISPLAY ===");
  if (!snapshot()) return 12;
  const auto afterCleared = SetThreadExecutionState(ES_CONTINUOUS);
  if (afterCleared == 0) return 5;
  std::puts("=== AFTER CLEANUP ===");
  if (!snapshot()) return 13;

  const bool beforeSystem = (beforeCleared & ES_SYSTEM_REQUIRED) != 0;
  const bool afterSystem = (afterCleared & ES_SYSTEM_REQUIRED) != 0;
  const bool afterDisplay = (afterCleared & ES_DISPLAY_REQUIRED) != 0;
  const bool sameThread = thread == GetCurrentThreadId();
  std::printf("{\"before_system\":%s,\"after_system\":%s,\"after_display\":%s,\"same_thread\":%s,\"thread_id\":%lu}\n",
              beforeSystem ? "true" : "false", afterSystem ? "true" : "false",
              afterDisplay ? "true" : "false", sameThread ? "true" : "false", thread);
  return !beforeSystem && afterSystem && afterDisplay && sameThread ? 0 : 6;
}
