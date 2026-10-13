using System;
using System.Collections.Generic;
using Issue3536.UIA;
public sealed class Control3536 {
 public string Name, Value, ClassName; public int Type, Pid, Left,Top,Right,Bottom; public long Handle; public bool Enabled; public int Toggle;
}
public sealed class Section3536 {
 public Control3536 Group; public Control3536[] Descendants;
}
public static class Controls3536 {
 static IUIAutomation Client() { var c=new CUIAutomation8Class(); var t=(IUIAutomation2)c; t.ConnectionTimeout=2000; t.TransactionTimeout=2000; return (IUIAutomation)c; }
 static Control3536 Read(IUIAutomationElement e) {
  if(Convert.ToBoolean(e.GetCurrentPropertyValue(30022))) return null;
  var r=e.CurrentBoundingRectangle; if(r.right<=r.left||r.bottom<=r.top) return null;
  object v=e.GetCurrentPropertyValue(30045), toggle=e.GetCurrentPropertyValue(30086);
  return new Control3536 {Name=e.CurrentName,Value=v is string?(string)v:null,ClassName=e.CurrentClassName,Type=e.CurrentControlType,Pid=e.CurrentProcessId,Left=r.left,Top=r.top,Right=r.right,Bottom=r.bottom,Handle=e.CurrentNativeWindowHandle.ToInt64(),Enabled=Convert.ToBoolean(e.GetCurrentPropertyValue(30010)),Toggle=toggle is int?(int)toggle:-1};
 }
 public static Control3536[] Snapshot(long hwnd,int pid) {
  var u=Client();var root=u.ElementFromHandle(new IntPtr(hwnd));if(root.CurrentProcessId!=pid)throw new Exception("UIA root ownership changed");
  var all=root.FindAll((TreeScope)4,u.CreateTrueCondition());if(all.Length>1500)throw new Exception("UIA bounded snapshot exceeded1500 controls");
  var list=new List<Control3536>();for(int i=0;i<all.Length;i++){var e=all.GetElement(i);var n=Read(e);if(n==null)continue;if(n.Pid!=pid)throw new Exception("UIA descendant ownership differs");list.Add(n);}return list.ToArray();
 }
 public static Section3536 SnapshotSection(long hwnd,int pid,string name,int type) {
  var u=Client();var root=u.ElementFromHandle(new IntPtr(hwnd));if(root.CurrentProcessId!=pid)throw new Exception("UIA section root ownership changed");
  var all=root.FindAll((TreeScope)4,u.CreateTrueCondition());if(all.Length>1500)throw new Exception("UIA section search exceeded1500 controls");
  IUIAutomationElement group=null;int matches=0;
  for(int i=0;i<all.Length;i++){var e=all.GetElement(i);if(e.CurrentControlType==type&&String.Equals(e.CurrentName,name,StringComparison.Ordinal)){group=e;matches++;}}
  if(matches!=1||group==null)throw new Exception("UIA exact section ancestry unavailable or ambiguous");
  var identity=Read(group);if(identity==null||identity.Pid!=pid)throw new Exception("UIA section identity/visibility invalid");
  var descendants=group.FindAll((TreeScope)4,u.CreateTrueCondition());if(descendants.Length>1500)throw new Exception("UIA section descendants exceeded1500 controls");
  var list=new List<Control3536>();for(int i=0;i<descendants.Length;i++){var n=Read(descendants.GetElement(i));if(n==null)continue;if(n.Pid!=pid)throw new Exception("UIA section descendant ownership differs");list.Add(n);}
  return new Section3536 {Group=identity,Descendants=list.ToArray()};
 }
 public static Control3536[] Roots() {
  var u=Client();var all=u.GetRootElement().FindAll((TreeScope)2,u.CreateTrueCondition());if(all.Length>100)throw new Exception("Desktop root limit");var list=new List<Control3536>();for(int i=0;i<all.Length;i++){var n=Read(all.GetElement(i));if(n!=null)list.Add(n);}return list.ToArray();
 }
}
