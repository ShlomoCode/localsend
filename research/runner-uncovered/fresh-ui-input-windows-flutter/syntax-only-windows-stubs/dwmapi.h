#pragma once
#include "windows.h"
HRESULT DwmSetWindowAttribute(HWND,DWORD,const void*,DWORD);
HRESULT DwmGetWindowAttribute(HWND,DWORD,void*,DWORD);
