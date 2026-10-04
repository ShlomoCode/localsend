#pragma once
#include <cstdint>
#define CALLBACK
using HWND=void*; using HKEY=void*; using HINSTANCE=void*; using UINT=unsigned; using WPARAM=uintptr_t; using LPARAM=intptr_t; using LRESULT=intptr_t; using LONG=int32_t; using DWORD=uint32_t; using BOOL=int; using BYTE=unsigned char; using LSTATUS=int; using HRESULT=int; using LPWSTR=wchar_t*;
struct RECT { LONG left,top,right,bottom; };
using WNDPROC=LRESULT(*)(HWND,UINT,WPARAM,LPARAM);
struct WNDCLASSW { UINT style=0; WNDPROC lpfnWndProc=nullptr; int cbClsExtra=0,cbWndExtra=0; HINSTANCE hInstance=nullptr; void *hIcon=nullptr,*hCursor=nullptr,*hbrBackground=nullptr; const wchar_t *lpszMenuName=nullptr,*lpszClassName=nullptr; };
struct MSG { HWND hwnd; UINT message; WPARAM wParam; LPARAM lParam; DWORD time; };
constexpr UINT WM_DESTROY=2,WM_DPICHANGED=0x2e0,WM_SIZE=5,WM_ACTIVATE=6,WM_DWMCOLORIZATIONCOLORCHANGED=0x320,WM_SETTINGCHANGE=0x1a;
constexpr int SWP_NOZORDER=4,SWP_NOACTIVATE=0x10,TRUE=1,FALSE=0,ERROR_SUCCESS=0,ERROR_FILE_NOT_FOUND=2,RRF_RT_REG_DWORD=1,REG_DWORD=4,KEY_QUERY_VALUE=1,KEY_SET_VALUE=2,CW_USEDEFAULT=0,WS_OVERLAPPEDWINDOW=0;
constexpr HKEY HKEY_CURRENT_USER=nullptr;
#define RegGetValue RegGetValueW
#define DefWindowProc DefWindowProcW
#define FAILED(value) ((value)<0)
LSTATUS RegGetValueW(HKEY,const wchar_t*,const wchar_t*,DWORD,DWORD*,void*,DWORD*);
LSTATUS RegCreateKeyExW(HKEY,const wchar_t*,DWORD,LPWSTR,DWORD,DWORD,void*,HKEY*,DWORD*);
LSTATUS RegQueryValueExW(HKEY,const wchar_t*,DWORD*,DWORD*,BYTE*,DWORD*);
LSTATUS RegSetValueExW(HKEY,const wchar_t*,DWORD,DWORD,const BYTE*,DWORD);
LSTATUS RegDeleteValueW(HKEY,const wchar_t*);
LSTATUS RegCloseKey(HKEY);
void SetWindowPos(HWND,HWND,LONG,LONG,LONG,LONG,int);
void MoveWindow(HWND,LONG,LONG,LONG,LONG,int);
void SetFocus(HWND);
void PostQuitMessage(int);
LRESULT DefWindowProcW(HWND,UINT,WPARAM,LPARAM);
BOOL GetClientRect(HWND,RECT*);
HINSTANCE GetModuleHandleW(const wchar_t*);
unsigned short RegisterClassW(const WNDCLASSW*);
HWND CreateWindowExW(DWORD,const wchar_t*,const wchar_t*,DWORD,int,int,int,int,HWND,void*,HINSTANCE,void*);
BOOL DestroyWindow(HWND);
LRESULT SendMessageW(HWND,UINT,WPARAM,LPARAM);
BOOL GetMessageW(MSG*,HWND,UINT,UINT);
BOOL TranslateMessage(const MSG*);
LRESULT DispatchMessageW(const MSG*);
