// Disposable Windows VM integration fixture. Compile once before and once after.
// MessageHandler and UpdateTheme below are exact pinned production bodies;
// AFTER_FIX adds only the proposed WM_SETTINGCHANGE case.
#include <windows.h>
#include <dwmapi.h>
#include <iostream>
#include <stdexcept>
#pragma comment(lib, "user32.lib")
#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "dwmapi.lib")
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif
constexpr const wchar_t kGetPreferredBrightnessRegKey[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr const wchar_t kGetPreferredBrightnessRegValue[] = L"AppsUseLightTheme";
class RegistryRestore {
 HKEY key_ = nullptr;
 DWORD old_ = 0;
 bool existed_ = false;
 public:
 RegistryRestore() {
  if (RegCreateKeyExW(HKEY_CURRENT_USER,kGetPreferredBrightnessRegKey,0,nullptr,0,KEY_QUERY_VALUE|KEY_SET_VALUE,nullptr,&key_,nullptr)!=ERROR_SUCCESS)
   throw std::runtime_error("Cannot open personalization registry key");
  DWORD type=0,size=sizeof(old_);
  LSTATUS r=RegQueryValueExW(key_,kGetPreferredBrightnessRegValue,nullptr,&type,reinterpret_cast<BYTE*>(&old_),&size);
  if (r==ERROR_SUCCESS) {
   if(type!=REG_DWORD || size!=sizeof(old_)) { RegCloseKey(key_); key_=nullptr; throw std::runtime_error("Unexpected original registry type; refusing modification"); }
   existed_=true;
  } else if(r!=ERROR_FILE_NOT_FOUND) { RegCloseKey(key_); key_=nullptr; throw std::runtime_error("Cannot read original registry value"); }
 }
 ~RegistryRestore() {
  if(key_) {
   if(existed_) RegSetValueExW(key_,kGetPreferredBrightnessRegValue,0,REG_DWORD,reinterpret_cast<const BYTE*>(&old_),sizeof(old_));
   else RegDeleteValueW(key_,kGetPreferredBrightnessRegValue);
   RegCloseKey(key_);
  }
 }
 void Set(DWORD light) {
  if(RegSetValueExW(key_,kGetPreferredBrightnessRegValue,0,REG_DWORD,reinterpret_cast<const BYTE*>(&light),sizeof(light))!=ERROR_SUCCESS)
   throw std::runtime_error("Cannot set registry value");
 }
};
class Win32Window {
 public:
 HWND window_handle_=nullptr,child_content_=nullptr;
 bool quit_on_close_=false;
 void Destroy() {}
 RECT GetClientArea() { RECT r{}; GetClientRect(window_handle_,&r); return r; }
 LRESULT MessageHandler(HWND,UINT,WPARAM,LPARAM) noexcept;
 void UpdateTheme(HWND);
};
Win32Window* fixtureWindow=nullptr;
LRESULT CALLBACK FixtureProc(HWND h,UINT m,WPARAM w,LPARAM l) {
 if(fixtureWindow) return fixtureWindow->MessageHandler(h,m,w,l);
 return DefWindowProcW(h,m,w,l);
}
BOOL GetDark(HWND h) {
 BOOL dark=FALSE;
 HRESULT r=DwmGetWindowAttribute(h,DWMWA_USE_IMMERSIVE_DARK_MODE,&dark,sizeof(dark));
 if(FAILED(r)) throw std::runtime_error("DwmGetWindowAttribute failed");
 return dark;
}
LRESULT
Win32Window::MessageHandler(HWND hwnd,
                            UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  switch (message) {
    case WM_DESTROY:
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;

    case WM_DPICHANGED: {
      auto newRectSize = reinterpret_cast<RECT*>(lparam);
      LONG newWidth = newRectSize->right - newRectSize->left;
      LONG newHeight = newRectSize->bottom - newRectSize->top;

      SetWindowPos(hwnd, nullptr, newRectSize->left, newRectSize->top, newWidth,
                   newHeight, SWP_NOZORDER | SWP_NOACTIVATE);

      return 0;
    }
    case WM_SIZE: {
      RECT rect = GetClientArea();
      if (child_content_ != nullptr) {
        // Size and position the child window.
        MoveWindow(child_content_, rect.left, rect.top, rect.right - rect.left,
                   rect.bottom - rect.top, TRUE);
      }
      return 0;
    }

    case WM_ACTIVATE:
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;

#ifdef AFTER_FIX
    case WM_SETTINGCHANGE:
#endif
    case WM_DWMCOLORIZATIONCOLORCHANGED:
      UpdateTheme(hwnd);
      return 0;
  }

  return DefWindowProc(window_handle_, message, wparam, lparam);
}

void Win32Window::UpdateTheme(HWND const window) {
  DWORD light_mode;
  DWORD light_mode_size = sizeof(light_mode);
  LSTATUS result = RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
                               kGetPreferredBrightnessRegValue,
                               RRF_RT_REG_DWORD, nullptr, &light_mode,
                               &light_mode_size);

  if (result == ERROR_SUCCESS) {
    BOOL enable_dark_mode = light_mode == 0;
    DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &enable_dark_mode, sizeof(enable_dark_mode));
  }
}

int main() {
 HWND h=nullptr;
 try {
  RegistryRestore restore;
  WNDCLASSW wc{}; wc.lpfnWndProc=FixtureProc; wc.hInstance=GetModuleHandleW(nullptr); wc.lpszClassName=L"LocalSendPinnedThemeFixture";
  if(!RegisterClassW(&wc)) throw std::runtime_error("RegisterClass failed");
  h=CreateWindowExW(0,wc.lpszClassName,L"LocalSend theme fixture",WS_OVERLAPPEDWINDOW,CW_USEDEFAULT,CW_USEDEFAULT,500,300,nullptr,nullptr,wc.hInstance,nullptr);
  if(!h) throw std::runtime_error("CreateWindow failed");
  Win32Window win; win.window_handle_=h; fixtureWindow=&win;
  restore.Set(1); win.UpdateTheme(h);
  BOOL initial=GetDark(h);
  if(initial!=FALSE) throw std::runtime_error("Initial light titlebar failed");
  restore.Set(0);
  SendMessageW(h,WM_SETTINGCHANGE,0,reinterpret_cast<LPARAM>(L"ImmersiveColorSet"));
  BOOL afterDark=GetDark(h);
#ifdef AFTER_FIX
  bool darkPass=afterDark==TRUE;
#else
  bool darkPass=afterDark==FALSE;
#endif
  // Establish dark via the existing supported notification, then reverse.
  SendMessageW(h,WM_DWMCOLORIZATIONCOLORCHANGED,0,0);
  if(GetDark(h)!=TRUE) throw std::runtime_error("Existing colorization handler failed");
  restore.Set(1);
  SendMessageW(h,WM_SETTINGCHANGE,0,reinterpret_cast<LPARAM>(L"ImmersiveColorSet"));
  BOOL afterLight=GetDark(h);
#ifdef AFTER_FIX
  bool lightPass=afterLight==FALSE;
#else
  bool lightPass=afterLight==TRUE;
#endif
  std::cout << "initial="<<initial<<" after_dark="<<afterDark<<" after_light="<<afterLight<<" dark_pass="<<darkPass<<" light_pass="<<lightPass<<"\n";
  fixtureWindow=nullptr; DestroyWindow(h); h=nullptr;
  return darkPass && lightPass ? 0 : 1;
 } catch(const std::exception& e) {
  fixtureWindow=nullptr; if(h) DestroyWindow(h);
  std::cerr<<e.what()<<"\n"; return 2;
 }
}
