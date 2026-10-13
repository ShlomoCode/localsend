using System;
using System.Collections.Generic;
using Issue89.UIA;
public sealed class Control89 {
 public string Name, Value, ClassName; public int Type, Pid, Left,Top,Right,Bottom; public long Handle; public bool Enabled, Focused; public int Toggle;
}
public static class Controls89 {
 static IUIAutomation Client() { var c=new CUIAutomation8Class(); var t=(IUIAutomation2)c; t.ConnectionTimeout=2000; t.TransactionTimeout=2000; return (IUIAutomation)c; }
 static Control89 Read(IUIAutomationElement e) {
  if(Convert.ToBoolean(e.GetCurrentPropertyValue(30022))) return null;
  var r=e.CurrentBoundingRectangle; if(r.right<=r.left||r.bottom<=r.top) return null;
  object v=e.GetCurrentPropertyValue(30045), toggle=e.GetCurrentPropertyValue(30086);
  return new Control89 {Name=e.CurrentName,Value=v is string?(string)v:null,ClassName=e.CurrentClassName,Type=e.CurrentControlType,Pid=e.CurrentProcessId,Left=r.left,Top=r.top,Right=r.right,Bottom=r.bottom,Handle=e.CurrentNativeWindowHandle.ToInt64(),Enabled=Convert.ToBoolean(e.GetCurrentPropertyValue(30010)),Focused=Convert.ToBoolean(e.GetCurrentPropertyValue(30008)),Toggle=toggle is int?(int)toggle:-1};
 }
 public static Control89[] Snapshot(long hwnd,int pid) {
  var u=Client();var root=u.ElementFromHandle(new IntPtr(hwnd));if(root.CurrentProcessId!=pid)throw new Exception("UIA root ownership changed");
  var all=root.FindAll((TreeScope)4,u.CreateTrueCondition());if(all.Length>1500)throw new Exception("UIA bounded snapshot exceeded1500 controls");
  var list=new List<Control89>();for(int i=0;i<all.Length;i++){var e=all.GetElement(i);var n=Read(e);if(n==null)continue;if(n.Pid!=pid)throw new Exception("UIA descendant ownership differs");list.Add(n);}return list.ToArray();
 }
 public static Dictionary<string,object> ScrollProcessPage(long hwnd,int pid,Control89 expected,DateTime localDeadline,DateTime absoluteDeadline) {
  var receipt=new Dictionary<string,object>();receipt["Target"]=expected;receipt["Called"]=false;receipt["Completed"]=false;
  try {
   var u=Client();var root=u.ElementFromHandle(new IntPtr(hwnd));if(root.CurrentProcessId!=pid)throw new Exception("UIA root ownership changed");
   var all=root.FindAll((TreeScope)4,u.CreateTrueCondition());if(all.Length>1500)throw new Exception("UIA bounded snapshot exceeded1500 controls");
   IUIAutomationElement target=null;int matches=0;
   for(int i=0;i<all.Length;i++){var e=all.GetElement(i);var n=Read(e);if(n==null)continue;
    if(n.Pid!=pid)throw new Exception("UIA descendant ownership differs");
    if(n.Name==expected.Name&&n.ClassName==expected.ClassName&&n.Type==expected.Type&&n.Left==expected.Left&&n.Top==expected.Top&&n.Right==expected.Right&&n.Bottom==expected.Bottom&&n.Enabled){target=e;matches++;}
   }
   if(matches!=1||expected.Name!="List of items"||expected.ClassName!="TmScrollViewer"||expected.Type!=50028||expected.Pid!=pid)throw new Exception("Exact native Processes list changed");
   bool available=Convert.ToBoolean(target.GetCurrentPropertyValue(30034));receipt["ScrollPatternAvailable"]=available;
   if(!available)throw new Exception("Native Processes ScrollPattern unavailable");
   var scroll=(IUIAutomationScrollPattern)target.GetCurrentPattern(10004);receipt["VerticallyScrollable"]=Convert.ToBoolean(scroll.CurrentVerticallyScrollable);
   if(!Convert.ToBoolean(scroll.CurrentVerticallyScrollable))throw new Exception("Native Processes list not vertically scrollable");
   receipt["BeforePercent"]=scroll.CurrentVerticalScrollPercent;receipt["BeforeUtc"]=DateTime.UtcNow.ToString("o");
   if(DateTime.UtcNow>=localDeadline||DateTime.UtcNow>=absoluteDeadline)throw new Exception("Explicit native scroll input deadline");
   receipt["Called"]=true;scroll.Scroll((ScrollAmount)2,(ScrollAmount)3);receipt["Completed"]=true;receipt["AfterUtc"]=DateTime.UtcNow.ToString("o");
   receipt["AfterPercent"]=scroll.CurrentVerticalScrollPercent;
  }catch(Exception e){receipt["Error"]=e.ToString();}
  return receipt;
 }
 public static Control89[] Roots() {
  var u=Client();var all=u.GetRootElement().FindAll((TreeScope)2,u.CreateTrueCondition());if(all.Length>100)throw new Exception("Desktop root limit");var list=new List<Control89>();for(int i=0;i<all.Length;i++){var n=Read(all.GetElement(i));if(n!=null)list.Add(n);}return list.ToArray();
 }
}
