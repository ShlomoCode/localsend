#include <windows.h>
#include <fstream>
#include <iostream>
#include <cstdint>
#pragma comment(lib, "user32.lib")
LRESULT CALLBACK HostProc(HWND h,UINT m,WPARAM w,LPARAM l) {
 if(m==WM_DESTROY) { PostQuitMessage(0); return 0; }
 return DefWindowProcW(h,m,w,l);
}
int main(int argc,char** argv) {
 if(argc!=2) return 2;
 WNDCLASSW wc{}; wc.lpfnWndProc=HostProc; wc.hInstance=GetModuleHandleW(nullptr); wc.lpszClassName=L"LocalSendFlutterFFIFixture";
 if(!RegisterClassW(&wc)) return 3;
 HWND h=CreateWindowExW(0,wc.lpszClassName,L"LocalSend Dart FFI fixture",WS_OVERLAPPEDWINDOW,CW_USEDEFAULT,CW_USEDEFAULT,500,300,nullptr,nullptr,wc.hInstance,nullptr);
 if(!h) return 4;
 { std::ofstream file(argv[1]); file<<reinterpret_cast<uintptr_t>(h)<<std::endl; if(!file) return 5; }
 MSG msg{}; while(GetMessageW(&msg,nullptr,0,0)>0) { TranslateMessage(&msg); DispatchMessageW(&msg); }
 return 0;
}
