using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public class ReceiverWindow {
 public int Pid; public long Hwnd; public string Title, ClassName;
 public bool Visible; public int Left, Top, Width, Height;
}
public static class ReceiverNative {
 [StructLayout(LayoutKind.Sequential)] private struct RECT { public int Left, Top, Right, Bottom; }
 [StructLayout(LayoutKind.Sequential)] private struct POINT { public int X,Y; }
 [StructLayout(LayoutKind.Sequential)] private struct GUITHREADINFO { public uint cbSize,flags; public IntPtr active,focus,capture,menuOwner,moveSize,caret; public RECT caretRect; }
 private delegate bool EnumProc(IntPtr hwnd,IntPtr data);
 [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc callback,IntPtr data);
 [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd,out uint pid);
 [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hwnd);
 [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hwnd,out RECT rect);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] private static extern int GetWindowText(IntPtr hwnd,StringBuilder text,int size);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] private static extern int GetClassName(IntPtr hwnd,StringBuilder text,int size);
 [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr hwnd,int command);
 [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr hwnd);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] private static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")] private static extern void mouse_event(uint flags,uint dx,uint dy,uint data,UIntPtr extra);
 [DllImport("user32.dll")] private static extern void keybd_event(byte key,byte scan,uint flags,UIntPtr extra);
 public static void TypeIpv4(string address) {
  foreach(char c in address) if(c!='.' && (c<'0'||c>'9')) throw new ArgumentException("Not an IPv4 literal");
  keybd_event(0x11,0,0,UIntPtr.Zero); keybd_event(0x41,0,0,UIntPtr.Zero);
  keybd_event(0x41,0,2,UIntPtr.Zero); keybd_event(0x11,0,2,UIntPtr.Zero);
  foreach(char c in address) {
   byte key=c=='.' ? (byte)0xBE : (byte)c;
   keybd_event(key,0,0,UIntPtr.Zero); keybd_event(key,0,2,UIntPtr.Zero);
   System.Threading.Thread.Sleep(40);
  }
 }
 [DllImport("user32.dll")] private static extern bool GetGUIThreadInfo(uint thread,ref GUITHREADINFO info);
 public static string FocusState(IntPtr app) {
  uint owner,focusedOwner; uint thread=GetWindowThreadProcessId(app,out owner);
  var info=new GUITHREADINFO { cbSize=(uint)Marshal.SizeOf(typeof(GUITHREADINFO)) };
  if(!GetGUIThreadInfo(thread,ref info)) return "unavailable";
  GetWindowThreadProcessId(info.focus,out focusedOwner);
  return "foreground="+GetForegroundWindow()+" app="+app+" focus="+info.focus+" owner="+owner+" focusedOwner="+focusedOwner;
 }
 public static bool HasKeyboardFocus(IntPtr app) {
  uint owner,focusedOwner; uint thread=GetWindowThreadProcessId(app,out owner);
  var info=new GUITHREADINFO { cbSize=(uint)Marshal.SizeOf(typeof(GUITHREADINFO)) };
  return GetForegroundWindow()==app && GetGUIThreadInfo(thread,ref info) && info.focus!=IntPtr.Zero &&
   GetWindowThreadProcessId(info.focus,out focusedOwner)!=0 && focusedOwner==owner;
 }
 [DllImport("user32.dll")] private static extern bool ScreenToClient(IntPtr hwnd,ref POINT point);
 [DllImport("user32.dll")] private static extern bool GetClientRect(IntPtr hwnd,out RECT rect);
 [DllImport("user32.dll")] private static extern IntPtr ChildWindowFromPointEx(IntPtr hwnd,POINT point,uint flags);
 [DllImport("user32.dll")] private static extern int MapWindowPoints(IntPtr from,IntPtr to,ref POINT point,uint count);
 [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr hwnd,uint message,IntPtr wParam,IntPtr lParam);
 [DllImport("shell32.dll")] private static extern int SHGetKnownFolderPath(ref Guid id,uint flags,IntPtr token,out IntPtr path);
 public static string Downloads() {
  Guid id=new Guid("374DE290-123F-4565-9164-39C4925E467B"); IntPtr path;
  int result=SHGetKnownFolderPath(ref id,0,IntPtr.Zero,out path);
  if(result!=0) Marshal.ThrowExceptionForHR(result);
  try { return Marshal.PtrToStringUni(path); } finally { Marshal.FreeCoTaskMem(path); }
 }
 public static ReceiverWindow[] All() {
  var result=new List<ReceiverWindow>();
  EnumWindows((hwnd,data)=>{
   uint pid; GetWindowThreadProcessId(hwnd,out pid); RECT rect; GetWindowRect(hwnd,out rect);
   var title=new StringBuilder(1024); var cls=new StringBuilder(256);
   GetWindowText(hwnd,title,title.Capacity); GetClassName(hwnd,cls,cls.Capacity);
   result.Add(new ReceiverWindow { Pid=(int)pid,Hwnd=hwnd.ToInt64(),Title=title.ToString(),ClassName=cls.ToString(),
    Visible=IsWindowVisible(hwnd),Left=rect.Left,Top=rect.Top,Width=rect.Right-rect.Left,Height=rect.Bottom-rect.Top });
   return true;
  },IntPtr.Zero); return result.ToArray();
 }
 public static bool Activate(IntPtr hwnd) { ShowWindow(hwnd,9); return SetForegroundWindow(hwnd); }
 public static bool ClickScreen(IntPtr app,int x,int y) {
  POINT point=new POINT { X=x,Y=y }; RECT rect;
  if(!IsWindowVisible(app)||!ScreenToClient(app,ref point)||!GetClientRect(app,out rect)||
   point.X<0||point.Y<0||point.X>=rect.Right||point.Y>=rect.Bottom) return false;
  Activate(app);
  if(!SetCursorPos(x,y)) return false;
  mouse_event(0x0002,0,0,0,UIntPtr.Zero);
  mouse_event(0x0004,0,0,0,UIntPtr.Zero);
  return true;
 }
}
