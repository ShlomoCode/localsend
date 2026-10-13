using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Issue3536.UIA;
public sealed class Control3536 {
 public string Name, Value, ClassName; public int Type, Pid, Left,Top,Right,Bottom; public long Handle; public bool Enabled;
}
public static class Controls3536 {
 static IUIAutomation Client() { var c=new CUIAutomation8Class(); var t=(IUIAutomation2)c; t.ConnectionTimeout=2000; t.TransactionTimeout=2000; return (IUIAutomation)c; }
 public static Control3536[] Snapshot(long hwnd, int pid) {
  var u=Client(); var root=u.ElementFromHandle(new IntPtr(hwnd));
  if(root.CurrentProcessId!=pid) throw new Exception("UIA root ownership changed");
  var all=root.FindAll((TreeScope)4,u.CreateTrueCondition());
  if(all.Length>400) throw new Exception("UIA snapshot exceeded 400 controls");
  var list=new List<Control3536>();
  for(int i=0;i<all.Length;i++) { var e=all.GetElement(i); if(Convert.ToBoolean(e.GetCurrentPropertyValue(30022))) continue;
   var r=e.CurrentBoundingRectangle; if(r.right<=r.left || r.bottom<=r.top) continue;
   if(e.CurrentProcessId!=pid) throw new Exception("UIA descendant ownership differs");
   object v=e.GetCurrentPropertyValue(30045);
   list.Add(new Control3536 {Name=e.CurrentName,Value=v is string?(string)v:null,ClassName=e.CurrentClassName,Type=e.CurrentControlType,Pid=e.CurrentProcessId,Left=r.left,Top=r.top,Right=r.right,Bottom=r.bottom,Handle=e.CurrentNativeWindowHandle.ToInt64(),Enabled=Convert.ToBoolean(e.GetCurrentPropertyValue(30010))});
  } return list.ToArray();
 }
 [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback,IntPtr data);
 delegate bool EnumProc(IntPtr hwnd,IntPtr data);
 [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
 [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h,System.Text.StringBuilder s,int n);
 public static long[] Dialogs(int pid) { var list=new List<long>(); EnumWindows((h,d)=>{uint p;GetWindowThreadProcessId(h,out p);var s=new System.Text.StringBuilder(128);GetClassName(h,s,128);if(p==pid && IsWindowVisible(h) && s.ToString()=="#32770") list.Add(h.ToInt64());return true;},IntPtr.Zero); return list.ToArray(); }
}
