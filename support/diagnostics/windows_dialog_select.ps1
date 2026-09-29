# Drive LocalSend's real file_selector_windows dialog in its owning process.
# The caller must assert the Flutter picker result after this script exits.
param(
  [Parameter(Mandatory = $true)][int] $TargetProcessId,
  [Parameter(Mandatory = $true)][string] $Path,
  [Parameter(Mandatory = $true)][ValidateSet('File', 'Folder')][string] $Mode,
  [ValidateSet('PathEntry', 'ShellItem', 'MouseShellItem', 'SendInputShellItem')][string] $SelectionMethod = 'PathEntry',
  [switch] $DismissRunnerPrivacyOverlay,
  [string] $DialogScreenshotPath,
  [ValidateRange(1, 120)][int] $TimeoutSeconds = 15
)

$ErrorActionPreference = 'Stop'

$source = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace LocalSendDialogSelect {
  public class ControlInfo {
    public string Hwnd;
    public string ClassName;
    public string Text;
    public int Id;
    public int ParentId;
    public bool Visible;
  }

  public class Result {
    public bool Success;
    public string Error;
    public int TargetProcessId;
    public string Path;
    public string Mode;
    public string SelectionMethod;
    public object Navigation;
    public object ShellItem;
    public string DialogHwnd;
    public string DialogTitle;
    public string EditHwnd;
    public string EditReadback;
    public string ButtonHwnd;
    public List<string> Actions = new List<string>();
    public List<ControlInfo> Controls = new List<ControlInfo>();
  }

  public class MouseClickInfo {
    public bool Posted;
    public string Error;
    public string InputMethod;
    public string ForegroundHwnd;
    public string ForegroundHwndAfterClick;
    public int ForegroundOwnerProcessId;
    public string ForegroundProcessName;
    public string ForegroundClass;
    public string ForegroundTitle;
    public string ScreenHitHwnd;
    public int ScreenHitOwnerProcessId;
    public string ScreenHitProcessName;
    public bool CursorVerified;
    public bool RaisedDialogTopmost;
    public RunnerOverlayInfo RunnerWslPrompt;
    public uint SentInputCount;
    public string TargetHwnd;
    public string TargetClass;
    public int OwnerProcessId;
    public int ScreenX;
    public int ScreenY;
    public int ClientX;
    public int ClientY;
    public List<string> HitTest = new List<string>();
  }

  public class RunnerOverlayInfo {
    public bool Detected;
    public string Hwnd;
    public int ProcessId;
    public string ProcessName;
    public string ClassName;
    public string Title;
    public bool ClosePosted;
    public bool Hidden;
    public bool ProcessStopped;
    public bool Closed;
    public string Error;
  }

  public static class Driver {
    private const uint WM_SETTEXT = 0x000C;
    private const uint WM_GETTEXT = 0x000D;
    private const uint BM_CLICK = 0x00F5;
    private const uint WM_COMMAND = 0x0111;
    private const uint WM_MOUSEMOVE = 0x0200;
    private const uint WM_LBUTTONDOWN = 0x0201;
    private const uint WM_LBUTTONUP = 0x0202;
    private const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    private const uint MOUSEEVENTF_LEFTUP = 0x0004;
    private const uint SWP_NOSIZE = 0x0001;
    private const uint SWP_NOMOVE = 0x0002;
    private const uint SWP_SHOWWINDOW = 0x0040;
    private const int CWP_SKIPINVISIBLE = 0x0001;
    private const uint SMTO_ABORTIFHUNG = 0x0002;
    private const int IDC_FILENAME = 0x047C; // cmb13, the common-dialog filename combo.
    private const int IDC_FILENAME_EDIT = 0x0480; // edt1 on older common dialogs.
    private const int IDOK = 1;
    private delegate bool EnumProc(IntPtr hwnd, IntPtr data);

    [StructLayout(LayoutKind.Sequential)] private struct POINT { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)] private struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [StructLayout(LayoutKind.Sequential)] private struct MOUSEINPUT {
      public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public UIntPtr dwExtraInfo;
    }
    [StructLayout(LayoutKind.Explicit)] private struct INPUTUNION {
      [FieldOffset(0)] public MOUSEINPUT mi;
    }
    [StructLayout(LayoutKind.Sequential)] private struct INPUT {
      public uint type; public INPUTUNION U;
    }

    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc callback, IntPtr data);
    [DllImport("user32.dll")] private static extern bool EnumChildWindows(IntPtr parent, EnumProc callback, IntPtr data);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
    [DllImport("user32.dll")] private static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr hwnd, int command);
    [DllImport("user32.dll")] private static extern bool ScreenToClient(IntPtr hwnd, ref POINT point);
    [DllImport("user32.dll")] private static extern bool GetClientRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] private static extern IntPtr WindowFromPoint(POINT point);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] private static extern bool GetCursorPos(out POINT point);
    [DllImport("user32.dll", SetLastError = true)] private static extern uint SendInput(uint count, INPUT[] inputs, int size);
    [DllImport("user32.dll")] private static extern IntPtr ChildWindowFromPointEx(IntPtr parent, POINT point, uint flags);
    [DllImport("user32.dll")] private static extern int MapWindowPoints(IntPtr from, IntPtr to, ref POINT point, uint count);
    [DllImport("user32.dll")] private static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool PostMessage(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] private static extern IntPtr GetParent(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern int GetDlgCtrlID(IntPtr hwnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr hwnd, StringBuilder text, int length);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int length);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr SendMessageTimeout(IntPtr hwnd, uint message, IntPtr wParam, string lParam, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll", EntryPoint = "SendMessageTimeoutW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr SendMessageTimeoutText(IntPtr hwnd, uint message, IntPtr wParam, StringBuilder lParam, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll", EntryPoint = "SendMessageTimeoutW", SetLastError = true)]
    private static extern IntPtr SendMessageTimeoutPtr(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);

    private static string Hex(IntPtr hwnd) { return "0x" + hwnd.ToInt64().ToString("X"); }
    private static string ProcessName(uint processId) {
      try { return Process.GetProcessById((int)processId).ProcessName; }
      catch { return null; }
    }
    private static string Class(IntPtr hwnd) {
      StringBuilder value = new StringBuilder(128);
      GetClassName(hwnd, value, value.Capacity);
      return value.ToString();
    }
    private static string Text(IntPtr hwnd) {
      StringBuilder value = new StringBuilder(32768);
      IntPtr count;
      if (SendMessageTimeoutText(hwnd, WM_GETTEXT, new IntPtr(value.Capacity), value,
          SMTO_ABORTIFHUNG, 200, out count) == IntPtr.Zero) {
        GetWindowText(hwnd, value, value.Capacity);
      }
      return value.ToString();
    }
    private static bool Closed(IntPtr hwnd) { return !IsWindow(hwnd) || !IsWindowVisible(hwnd); }
    private static bool WaitClosed(IntPtr hwnd, DateTime deadline) {
      while (DateTime.UtcNow < deadline) {
        if (Closed(hwnd)) return true;
        Thread.Sleep(100);
      }
      return Closed(hwnd);
    }
    public static IntPtr FindDialog(int processId) {
      IntPtr found = IntPtr.Zero;
      EnumWindows((hwnd, data) => {
        uint owner;
        GetWindowThreadProcessId(hwnd, out owner);
        if (owner == processId && IsWindowVisible(hwnd) && Class(hwnd) == "#32770") {
          found = hwnd;
          return false;
        }
        return true;
      }, IntPtr.Zero);
      return found;
    }
    private static int FilenameScore(IntPtr hwnd, IntPtr dialog) {
      if (Class(hwnd) != "Edit" || !IsWindowVisible(hwnd)) return -1;
      int score = GetDlgCtrlID(hwnd) == IDC_FILENAME_EDIT ? 80 : 0;
      IntPtr ancestor = GetParent(hwnd);
      while (ancestor != IntPtr.Zero && ancestor != dialog) {
        if (GetDlgCtrlID(ancestor) == IDC_FILENAME) score += 100;
        if (Class(ancestor) == "ComboBoxEx32") score += 20;
        ancestor = GetParent(ancestor);
      }
      return score;
    }
    public static bool DialogOpen(IntPtr hwnd) { return !Closed(hwnd); }
    public static RunnerOverlayInfo DismissRunnerPrivacyOverlay(IntPtr dialog) {
      RunnerOverlayInfo info = new RunnerOverlayInfo();
      IntPtr foreground = GetForegroundWindow();
      uint owner;
      GetWindowThreadProcessId(foreground, out owner);
      string name = ProcessName(owner);
      string className = Class(foreground);
      string title = Text(foreground);
      info.Hwnd = Hex(foreground);
      info.ProcessId = (int)owner;
      info.ProcessName = name;
      info.ClassName = className;
      info.Title = title;
      if (foreground == dialog || name != "WWAHost" || className != "Windows.UI.Core.CoreWindow" || title != "Microsoft account") {
        return info;
      }
      info.Detected = true;
      info.ClosePosted = PostMessage(foreground, 0x0010, IntPtr.Zero, IntPtr.Zero); // WM_CLOSE
      Thread.Sleep(500);
      if (!Closed(foreground)) {
        ShowWindow(foreground, 0); // SW_HIDE, only on this disposable runner.
        info.Hidden = !IsWindowVisible(foreground);
        Thread.Sleep(300);
      }
      if (!Closed(foreground)) {
        try {
          Process.GetProcessById((int)owner).Kill();
          info.ProcessStopped = true;
          Thread.Sleep(500);
        } catch (Exception ex) { info.Error = "Could not stop the identified runner privacy host: " + ex.Message; }
      }
      info.Closed = Closed(foreground);
      if (!info.Closed && info.Error == null) info.Error = "Identified runner privacy window remained visible.";
      if (info.Closed) SetForegroundWindow(dialog);
      return info;
    }
    private static RunnerOverlayInfo DismissRunnerWslPrompt(IntPtr hit, IntPtr dialog) {
      IntPtr window = hit;
      for (int depth = 0; depth < 10 && window != IntPtr.Zero; depth++) {
        uint owner;
        GetWindowThreadProcessId(window, out owner);
        string title = Text(window);
        if (ProcessName(owner) == "wsl" && Class(window) == "ConsoleWindowClass" &&
            title.EndsWith("\\wsl.exe", StringComparison.OrdinalIgnoreCase)) {
          RunnerOverlayInfo info = new RunnerOverlayInfo {
            Detected = true, Hwnd = Hex(window), ProcessId = (int)owner,
            ProcessName = "wsl", ClassName = Class(window), Title = title
          };
          info.ClosePosted = PostMessage(window, 0x0010, IntPtr.Zero, IntPtr.Zero); // WM_CLOSE
          Thread.Sleep(300);
          if (!Closed(window)) {
            ShowWindow(window, 0); // SW_HIDE on the disposable runner only.
            info.Hidden = !IsWindowVisible(window);
          }
          info.Closed = Closed(window);
          if (!info.Closed) info.Error = "Identified runner WSL update prompt remained visible.";
          if (info.Closed) SetForegroundWindow(dialog);
          return info;
        }
        window = GetParent(window);
      }
      return null;
    }
    public static MouseClickInfo ClickVisibleShellItem(IntPtr dialog, int processId, int screenX, int screenY, bool useSendInput, bool recoverRunnerObstruction) {
      MouseClickInfo click = new MouseClickInfo {
        ScreenX = screenX, ScreenY = screenY,
        InputMethod = useSendInput ? "SendInput" : "PostMessage"
      };
      if (Closed(dialog)) { click.Error = "Dialog is closed before Shell-item mouse click."; return click; }
      POINT point = new POINT { X = screenX, Y = screenY };
      if (!ScreenToClient(dialog, ref point)) { click.Error = "Could not map Shell-item screen coordinates into dialog client area."; return click; }
      IntPtr target = dialog;
      for (int depth = 0; depth < 12; depth++) {
        RECT rect;
        if (!GetClientRect(target, out rect) || point.X < rect.Left || point.X >= rect.Right ||
            point.Y < rect.Top || point.Y >= rect.Bottom) {
          click.Error = "Shell-item center lies outside the visible target HWND client area.";
          return click;
        }
        click.HitTest.Add(Hex(target) + " " + Class(target) + " (" + point.X + "," + point.Y + ")");
        IntPtr child = ChildWindowFromPointEx(target, point, CWP_SKIPINVISIBLE);
        if (child == IntPtr.Zero || child == target) break;
        MapWindowPoints(target, child, ref point, 1);
        target = child;
      }
      uint owner;
      GetWindowThreadProcessId(target, out owner);
      click.TargetHwnd = Hex(target);
      click.TargetClass = Class(target);
      click.OwnerProcessId = (int)owner;
      click.ClientX = point.X;
      click.ClientY = point.Y;
      if (owner != processId) { click.Error = "Hit-tested child HWND is not owned by target process."; return click; }
      if (point.X < 0 || point.Y < 0 || point.X > 32767 || point.Y > 32767) {
        click.Error = "Hit-tested child coordinates cannot be encoded in a mouse message.";
        return click;
      }
      if (useSendInput) {
        IntPtr foreground = GetForegroundWindow();
        if (foreground != dialog) {
          SetForegroundWindow(dialog);
          foreground = GetForegroundWindow();
        }
        click.ForegroundHwnd = Hex(foreground);
        uint foregroundOwner;
        GetWindowThreadProcessId(foreground, out foregroundOwner);
        click.ForegroundOwnerProcessId = (int)foregroundOwner;
        click.ForegroundProcessName = ProcessName(foregroundOwner);
        click.ForegroundClass = Class(foreground);
        click.ForegroundTitle = Text(foreground);
        // A user can activate a background dialog by clicking its visible
        // item. Do not require foreground ownership when the screen hit test
        // below proves that the item itself is exposed to pointer input.
        if (!SetCursorPos(screenX, screenY)) {
          click.Error = "Could not move the system cursor to the visible dialog item: " + Marshal.GetLastWin32Error();
          return click;
        }
        POINT cursor;
        if (!GetCursorPos(out cursor) || cursor.X != screenX || cursor.Y != screenY) {
          click.Error = "System cursor did not reach the visible dialog item.";
          return click;
        }
        click.CursorVerified = true;
        IntPtr screenHit = WindowFromPoint(cursor);
        uint screenOwner;
        GetWindowThreadProcessId(screenHit, out screenOwner);
        click.ScreenHitHwnd = Hex(screenHit);
        click.ScreenHitOwnerProcessId = (int)screenOwner;
        click.ScreenHitProcessName = ProcessName(screenOwner);
        if (screenOwner != processId && recoverRunnerObstruction) {
          click.RunnerWslPrompt = DismissRunnerWslPrompt(screenHit, dialog);
          if (click.RunnerWslPrompt != null && click.RunnerWslPrompt.Closed) {
            Thread.Sleep(150);
            screenHit = WindowFromPoint(cursor);
            GetWindowThreadProcessId(screenHit, out screenOwner);
            click.ScreenHitHwnd = Hex(screenHit);
            click.ScreenHitOwnerProcessId = (int)screenOwner;
            click.ScreenHitProcessName = ProcessName(screenOwner);
          }
        }
        if (screenOwner != processId && recoverRunnerObstruction) {
          // The disposable hosted runner can put its own first-run/WSL windows
          // over the picker between navigation and the real input click.
          click.RaisedDialogTopmost = SetWindowPos(dialog, new IntPtr(-1), 0, 0, 0, 0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
          if (click.RaisedDialogTopmost) {
            SetForegroundWindow(dialog);
            Thread.Sleep(150);
            screenHit = WindowFromPoint(cursor);
            GetWindowThreadProcessId(screenHit, out screenOwner);
            click.ScreenHitHwnd = Hex(screenHit);
            click.ScreenHitOwnerProcessId = (int)screenOwner;
            click.ScreenHitProcessName = ProcessName(screenOwner);
          }
        }
        if (screenOwner != processId) {
          click.Error = "System hit test at the cursor is not owned by the target process.";
          return click;
        }
        Thread.Sleep(50);
        INPUT[] inputs = new INPUT[] {
          new INPUT { type = 0, U = new INPUTUNION { mi = new MOUSEINPUT { dwFlags = MOUSEEVENTF_LEFTDOWN } } },
          new INPUT { type = 0, U = new INPUTUNION { mi = new MOUSEINPUT { dwFlags = MOUSEEVENTF_LEFTUP } } }
        };
        click.SentInputCount = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT)));
        click.Posted = click.SentInputCount == (uint)inputs.Length;
        Thread.Sleep(50);
        click.ForegroundHwndAfterClick = Hex(GetForegroundWindow());
        if (!click.Posted) click.Error = "SendInput did not enqueue both click events: " + Marshal.GetLastWin32Error();
      } else {
        IntPtr lParam = new IntPtr((point.Y << 16) | point.X);
        bool move = PostMessage(target, WM_MOUSEMOVE, IntPtr.Zero, lParam);
        bool down = PostMessage(target, WM_LBUTTONDOWN, new IntPtr(1), lParam);
        bool up = PostMessage(target, WM_LBUTTONUP, IntPtr.Zero, lParam);
        click.Posted = move && down && up;
        if (!click.Posted) click.Error = "Could not post the complete mouse click to the dialog-owned child HWND.";
      }
      return click;
    }
    public static MouseClickInfo ClickOkViaSendInput(IntPtr dialog, int processId, bool recoverRunnerObstruction) {
      IntPtr button = IntPtr.Zero;
      EnumChildWindows(dialog, (hwnd, data) => {
        if (GetDlgCtrlID(hwnd) == IDOK && Class(hwnd) == "Button" && IsWindowVisible(hwnd)) { button = hwnd; return false; }
        return true;
      }, IntPtr.Zero);
      if (button == IntPtr.Zero) return new MouseClickInfo { Error = "Could not find the visible Open/Select button." };
      RECT rect;
      if (!GetWindowRect(button, out rect) || rect.Right <= rect.Left || rect.Bottom <= rect.Top) {
        return new MouseClickInfo { Error = "Open/Select button has no visible screen bounds." };
      }
      return ClickVisibleShellItem(dialog, processId, rect.Left + (rect.Right - rect.Left) / 2,
        rect.Top + (rect.Bottom - rect.Top) / 2, true, recoverRunnerObstruction);
    }
    public static bool Capture(IntPtr hwnd, IntPtr hdc) { return PrintWindow(hwnd, hdc, 2) || PrintWindow(hwnd, hdc, 0); }
    public static string ReadText(IntPtr hwnd) { return Text(hwnd); }
    public static IntPtr FindFilenameEdit(IntPtr dialog) {
      IntPtr best = IntPtr.Zero;
      int bestScore = -1;
      EnumChildWindows(dialog, (hwnd, data) => {
        int score = FilenameScore(hwnd, dialog);
        if (score > bestScore) { best = hwnd; bestScore = score; }
        return true;
      }, IntPtr.Zero);
      return bestScore >= 80 ? best : IntPtr.Zero;
    }
    public static bool SetFilenameEdit(IntPtr edit, string value) {
      IntPtr response;
      IntPtr sent = SendMessageTimeout(edit, WM_SETTEXT, IntPtr.Zero, value, SMTO_ABORTIFHUNG, 2000, out response);
      return sent != IntPtr.Zero && response != IntPtr.Zero && String.Equals(Text(edit), value, StringComparison.OrdinalIgnoreCase);
    }
    public static string AddressToolbarText(IntPtr dialog) {
      string text = null;
      EnumChildWindows(dialog, (hwnd, data) => {
        if (GetDlgCtrlID(hwnd) == 1001 && Class(hwnd) == "ToolbarWindow32") { text = Text(hwnd); return false; }
        return true;
      }, IntPtr.Zero);
      return text;
    }
    public static bool FocusAddressBar(IntPtr dialog) {
      // Alt+D is the native common-dialog address-bar accelerator, posted only
      // to the owning dialog HWND. It converts the breadcrumb into an Edit.
      bool alt = PostMessage(dialog, 0x0104, new IntPtr(0x12), new IntPtr(0x20000001)); // WM_SYSKEYDOWN VK_MENU
      bool d = PostMessage(dialog, 0x0104, new IntPtr(0x44), new IntPtr(0x20000001)); // WM_SYSKEYDOWN D
      bool dUp = PostMessage(dialog, 0x0105, new IntPtr(0x44), IntPtr.Zero); // WM_SYSKEYUP D
      bool altUp = PostMessage(dialog, 0x0105, new IntPtr(0x12), IntPtr.Zero); // WM_SYSKEYUP VK_MENU
      return alt && d && dUp && altUp;
    }
    public static IntPtr FindAddressEdit(IntPtr dialog) {
      IntPtr found = IntPtr.Zero;
      EnumChildWindows(dialog, (hwnd, data) => {
        if (Class(hwnd) != "Edit" || !IsWindowVisible(hwnd)) return true;
        IntPtr ancestor = GetParent(hwnd);
        while (ancestor != IntPtr.Zero && ancestor != dialog) {
          string ancestorClass = Class(ancestor);
          if ((GetDlgCtrlID(ancestor) == 1001 && ancestorClass == "ToolbarWindow32") ||
              ancestorClass.IndexOf("Breadcrumb", StringComparison.OrdinalIgnoreCase) >= 0 ||
              ancestorClass.IndexOf("Address", StringComparison.OrdinalIgnoreCase) >= 0) {
            found = hwnd; return false;
          }
          ancestor = GetParent(ancestor);
        }
        return true;
      }, IntPtr.Zero);
      return found;
    }
    public static bool SubmitAddress(IntPtr edit) {
      bool down = PostMessage(edit, 0x0100, new IntPtr(0x0D), IntPtr.Zero); // WM_KEYDOWN VK_RETURN
      bool up = PostMessage(edit, 0x0101, new IntPtr(0x0D), IntPtr.Zero); // WM_KEYUP VK_RETURN
      return down && up;
    }
    public static bool PressOk(IntPtr dialog) {
      IntPtr button = IntPtr.Zero;
      EnumChildWindows(dialog, (hwnd, data) => {
        if (GetDlgCtrlID(hwnd) == IDOK && Class(hwnd) == "Button" && IsWindowVisible(hwnd)) { button = hwnd; return false; }
        return true;
      }, IntPtr.Zero);
      IntPtr response;
      if (button != IntPtr.Zero && SendMessageTimeoutPtr(button, BM_CLICK, IntPtr.Zero, IntPtr.Zero, SMTO_ABORTIFHUNG, 2000, out response) != IntPtr.Zero) return true;
      return SendMessageTimeoutPtr(dialog, WM_COMMAND, new IntPtr(IDOK), IntPtr.Zero, SMTO_ABORTIFHUNG, 2000, out response) != IntPtr.Zero;
    }
    public static Result Run(int processId, string path, string mode, int timeoutSeconds) {
      Result result = new Result { TargetProcessId = processId, Path = path, Mode = mode, SelectionMethod = "PathEntry" };
      DateTime deadline = DateTime.UtcNow.AddSeconds(timeoutSeconds);
      try {
        Process.GetProcessById(processId); // Fail early when the app already exited.
        IntPtr dialog = IntPtr.Zero;
        while (DateTime.UtcNow < deadline && dialog == IntPtr.Zero) {
          dialog = FindDialog(processId);
          if (dialog == IntPtr.Zero) Thread.Sleep(100);
        }
        if (dialog == IntPtr.Zero) {
          result.Error = "No visible process-owned #32770 file dialog appeared before timeout.";
          return result;
        }
        result.DialogHwnd = Hex(dialog);
        result.DialogTitle = Text(dialog);
        result.Actions.Add("Found process-owned native dialog");

        IntPtr filename = IntPtr.Zero;
        IntPtr button = IntPtr.Zero;
        int bestScore = -1;
        EnumChildWindows(dialog, (hwnd, data) => {
          ControlInfo control = new ControlInfo {
            Hwnd = Hex(hwnd), ClassName = Class(hwnd), Text = Text(hwnd),
            Id = GetDlgCtrlID(hwnd), ParentId = GetDlgCtrlID(GetParent(hwnd)),
            Visible = IsWindowVisible(hwnd)
          };
          if (result.Controls.Count < 200) result.Controls.Add(control);
          int score = FilenameScore(hwnd, dialog);
          if (score > bestScore) { bestScore = score; filename = hwnd; }
          if (control.Id == IDOK && control.ClassName == "Button" && control.Visible) button = hwnd;
          return true;
        }, IntPtr.Zero);
        if (filename == IntPtr.Zero || bestScore < 80) {
          result.Error = "Could not identify filename Edit beneath cmb13 or edt1; inspect Controls.";
          return result;
        }
        result.EditHwnd = Hex(filename);
        if (button != IntPtr.Zero) result.ButtonHwnd = Hex(button);
        IntPtr messageResult;
        IntPtr sent = SendMessageTimeout(filename, WM_SETTEXT, IntPtr.Zero, path, SMTO_ABORTIFHUNG, 2000, out messageResult);
        if (sent == IntPtr.Zero || messageResult == IntPtr.Zero) {
          result.Error = "WM_SETTEXT failed or timed out on the filename Edit.";
          return result;
        }
        result.EditReadback = Text(filename);
        if (!String.Equals(result.EditReadback, path, StringComparison.OrdinalIgnoreCase)) {
          result.Error = "Filename Edit did not retain the exact requested path.";
          return result;
        }
        result.Actions.Add("Set and verified filename Edit text");

        // First use the dialog's own button, then the dialog's IDOK command.
        // Folder dialogs may navigate into the named folder on the first click.
        if (button != IntPtr.Zero) {
          sent = SendMessageTimeoutPtr(button, BM_CLICK, IntPtr.Zero, IntPtr.Zero, SMTO_ABORTIFHUNG, 2000, out messageResult);
          result.Actions.Add(sent == IntPtr.Zero ? "BM_CLICK failed" : "Sent BM_CLICK to process-owned IDOK button");
          if (WaitClosed(dialog, DateTime.UtcNow.AddMilliseconds(2500))) {
            result.Success = true;
            return result;
          }
        }
        sent = SendMessageTimeoutPtr(dialog, WM_COMMAND, new IntPtr(IDOK), IntPtr.Zero, SMTO_ABORTIFHUNG, 2000, out messageResult);
        result.Actions.Add(sent == IntPtr.Zero ? "WM_COMMAND IDOK failed" : "Sent WM_COMMAND IDOK to process-owned dialog");
        if (WaitClosed(dialog, deadline)) {
          result.Success = true;
          return result;
        }
        result.Error = "Dialog remained open after IDOK; selection may have navigated or validation rejected the path.";
      } catch (Exception ex) { result.Error = ex.ToString(); }
      return result;
    }
  }
}
'@

function Get-DialogElements($Root) {
  $found = New-Object System.Collections.ArrayList
  $descendants = $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
  foreach ($element in $descendants) {
    try {
      $current = $element.Current
      $rect = $current.BoundingRectangle
      [void] $found.Add([pscustomobject]@{
        Element = $element
        Name = [string] $current.Name
        ControlType = [string] $current.ControlType.ProgrammaticName
        AutomationId = [string] $current.AutomationId
        Visible = -not $current.IsOffscreen -and -not $rect.IsEmpty
        Bounds = [ordered]@{ left = $rect.Left; top = $rect.Top; width = $rect.Width; height = $rect.Height }
      })
    } catch { }
  }
  return $found.ToArray()
}

function Test-AddressContext($Element) {
  try {
    $ancestor = $Element
    for ($depth = 0; $depth -lt 8 -and $ancestor; $depth++) {
      $current = $ancestor.Current
      $label = [string] $current.Name
      $kind = [string] $current.ControlType.ProgrammaticName
      $className = [string] $current.ClassName
      if ($label -match '(?i)address|breadcrumb' -or $kind -match 'ToolBar' -or $className -match '(?i)breadcrumb|address') {
        return $true
      }
      $ancestor = [System.Windows.Automation.TreeWalker]::RawViewWalker.GetParent($ancestor)
    }
  } catch { }
  return $false
}

function Invoke-ShellItem {
  $targetPath = [System.IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\', '/'))
  $parentPath = [System.IO.Path]::GetDirectoryName($targetPath)
  $targetName = [System.IO.Path]::GetFileName($targetPath)
  $parentName = [System.IO.Path]::GetFileName($parentPath.TrimEnd([char[]]@('\', '/')))
  $navigationInput = $parentPath.TrimEnd([char[]]@('\', '/')) + '\'
  $acceptedItemNames = @($targetName)
  $stemEvidence = $null
  if ($Mode -eq 'File') {
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($targetName)
    if ($stem -ne $targetName) {
      $sameStemFiles = @(Get-ChildItem -LiteralPath $parentPath -File | Where-Object { $_.BaseName -eq $stem })
      $uniqueExactFile = $sameStemFiles.Count -eq 1 -and
        [string]::Equals($sameStemFiles[0].FullName, $targetPath, [System.StringComparison]::OrdinalIgnoreCase)
      $stemEvidence = [ordered]@{
        stem = $stem
        filesWithStem = @($sameStemFiles | ForEach-Object FullName)
        uniqueExactTarget = $uniqueExactFile
      }
      if ($uniqueExactFile) { $acceptedItemNames += $stem }
    }
  }
  $result = [ordered]@{
    Success = $false
    Error = $null
    TargetProcessId = $TargetProcessId
    Path = $targetPath
    Mode = $Mode
    SelectionMethod = $SelectionMethod
    DialogHwnd = $null
    Navigation = [ordered]@{
      ParentDirectory = $parentPath
      Method = if ($Mode -eq 'Folder') { 'native address-bar Alt+D and Enter' } else { 'filename Edit with parent directory only' }
      Input = $navigationInput
      AddressToolbarBefore = $null
      AddressToolbarAfter = $null
      AddressEditHwnd = $null
      EditReadbackBeforeOpen = $null
      EditReadbackAfterOpen = $null
      AddressEvidence = @()
      DialogStayedOpen = $false
      UiaEnumerationRetries = 0
      Screenshot = $null
      ScreenshotError = $null
    }
    ShellItem = [ordered]@{
      Name = $targetName
      AcceptedVisibleNames = $acceptedItemNames
      HiddenExtensionEvidence = $stemEvidence
      MatchedBy = $null
      Candidates = @()
      SelectedElement = $null
      SelectionPattern = $null
      NativeFolderField = $null
      WasSelectedBefore = $null
      MouseClick = $null
      MouseClickRetry = $null
      ConfirmationClick = $null
      IsSelected = $false
    }
    RunnerPrivacyOverlay = $null
    Actions = @()
    UiaNames = @()
  }
  try {
    Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
    Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $dialog = [IntPtr]::Zero
    while ($dialog -eq [IntPtr]::Zero -and [DateTime]::UtcNow -lt $deadline) {
      $dialog = [LocalSendDialogSelect.Driver]::FindDialog($TargetProcessId)
      if ($dialog -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 100 }
    }
    if ($dialog -eq [IntPtr]::Zero) { throw 'No visible process-owned native file dialog appeared before timeout.' }
    $result.DialogHwnd = '0x' + $dialog.ToInt64().ToString('X')
    $result.Actions += 'Found process-owned native common dialog'
    $edit = [LocalSendDialogSelect.Driver]::FindFilenameEdit($dialog)
    if ($edit -eq [IntPtr]::Zero) { throw 'Could not identify the dialog filename Edit.' }

    # Enter only the parent directory. A folder picker treats filename Edit + OK
    # as a completed selection, so its address bar must perform navigation.
    if ($Mode -eq 'Folder') {
      $result.Navigation.AddressToolbarBefore = [LocalSendDialogSelect.Driver]::AddressToolbarText($dialog)
      if (-not [LocalSendDialogSelect.Driver]::FocusAddressBar($dialog)) { throw 'Could not post Alt+D to the native dialog address bar.' }
      $addressEdit = [IntPtr]::Zero
      $addressDeadline = [DateTime]::UtcNow.AddSeconds(3)
      while ($addressEdit -eq [IntPtr]::Zero -and [DateTime]::UtcNow -lt $addressDeadline) {
        $addressEdit = [LocalSendDialogSelect.Driver]::FindAddressEdit($dialog)
        if ($addressEdit -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 100 }
      }
      if ($addressEdit -eq [IntPtr]::Zero) { throw 'Alt+D did not expose a native address-bar Edit; refusing filename Edit navigation in Folder mode.' }
      $result.Navigation.AddressEditHwnd = '0x' + $addressEdit.ToInt64().ToString('X')
      if (-not [LocalSendDialogSelect.Driver]::SetFilenameEdit($addressEdit, $parentPath)) {
        throw 'Could not set and read back the parent directory in the address-bar Edit.'
      }
      $result.Navigation.EditReadbackBeforeOpen = [LocalSendDialogSelect.Driver]::ReadText($addressEdit)
      $result.Actions += 'Entered and verified parent directory in native address-bar Edit'
      if (-not [LocalSendDialogSelect.Driver]::SubmitAddress($addressEdit)) { throw 'Could not submit parent directory from address bar.' }
      $result.Actions += 'Submitted parent directory from address bar using targeted Enter'
    } else {
      if (-not [LocalSendDialogSelect.Driver]::SetFilenameEdit($edit, $navigationInput)) {
        throw 'Could not set and read back the parent directory in the filename Edit.'
      }
      $result.Navigation.EditReadbackBeforeOpen = [LocalSendDialogSelect.Driver]::ReadText($edit)
      $result.Actions += 'Entered and verified parent directory path in filename Edit'
      if (-not [LocalSendDialogSelect.Driver]::PressOk($dialog)) { throw 'Could not activate Open to navigate to the parent directory.' }
      $result.Actions += 'Activated Open to navigate to parent directory'
    }
    if (-not [LocalSendDialogSelect.Driver]::DialogOpen($dialog)) { throw 'Dialog closed while navigating to parent; no Shell item was selected.' }
    $result.Navigation.DialogStayedOpen = $true

    $root = $null
    $records = @()
    $items = @()
    $address = @()
    do {
      Start-Sleep -Milliseconds 150
      if (-not [LocalSendDialogSelect.Driver]::DialogOpen($dialog)) { throw 'Dialog closed before Shell item selection.' }
      try {
        # Explorer replaces the Shell view while changing directories. An old
        # UIA element can disappear between FromHandle and FindAll, so reacquire
        # the dialog and retry until the existing selection deadline.
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($dialog)
        $records = @(Get-DialogElements $root)
      } catch {
        $result.Navigation.UiaEnumerationRetries++
        if ([DateTime]::UtcNow -ge $deadline) {
          throw "Could not enumerate the navigated dialog before timeout: $($_.Exception.Message)"
        }
        continue
      }
      $address = @($records | Where-Object {
        $_.Visible -and $_.Name -and
        ($_.Name -eq $parentName -or $_.Name -eq $parentPath -or $_.Name -like "*$parentName*") -and
        $_.ControlType -notmatch 'ListItem|DataItem|TreeItem' -and
        ($_.Name -eq $parentPath -or $_.ControlType -match 'Button|ToolBar|SplitButton|Hyperlink' -or (Test-AddressContext $_.Element))
      })
      $result.Navigation.AddressToolbarAfter = [LocalSendDialogSelect.Driver]::AddressToolbarText($dialog)
      $nativeAddressVerified = $result.Navigation.AddressToolbarAfter -and
        $result.Navigation.AddressToolbarAfter.IndexOf($parentName, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
      $items = @($records | Where-Object { $_.Visible -and $_.Name -in $acceptedItemNames })
    } while ((($address.Count -eq 0 -and -not $nativeAddressVerified) -or $items.Count -eq 0) -and [DateTime]::UtcNow -lt $deadline)
    if ($Mode -eq 'File') { $result.Navigation.EditReadbackAfterOpen = [LocalSendDialogSelect.Driver]::ReadText($edit) }
    $result.UiaNames = @($records | Where-Object { $_.Visible -and $_.Name } | Select-Object -First 100 -ExpandProperty Name)
    $result.Navigation.AddressEvidence = @($address | ForEach-Object {
      [ordered]@{ name = $_.Name; controlType = $_.ControlType; automationId = $_.AutomationId; bounds = $_.Bounds }
    })
    if ($address.Count -eq 0 -and -not $nativeAddressVerified) { throw "Could not verify that the common dialog navigated to parent directory '$parentPath'." }
    $result.Actions += 'Verified parent directory in visible dialog address controls'

    if ($DialogScreenshotPath) {
      try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($DialogScreenshotPath))) | Out-Null
        $windowRect = $root.Current.BoundingRectangle
        if ($windowRect.IsEmpty -or $windowRect.Width -le 0 -or $windowRect.Height -le 0) { throw 'Dialog has no printable bounds.' }
        $bitmap = [System.Drawing.Bitmap]::new([int]$windowRect.Width, [int]$windowRect.Height)
        try {
          $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
          try {
            $hdc = $graphics.GetHdc()
            try { $printed = [LocalSendDialogSelect.Driver]::Capture($dialog, $hdc) }
            finally { $graphics.ReleaseHdc($hdc) }
          } finally { $graphics.Dispose() }
          if (-not $printed) { throw 'PrintWindow returned false for the navigated dialog.' }
          $bitmap.Save($DialogScreenshotPath, [System.Drawing.Imaging.ImageFormat]::Png)
          $result.Navigation.Screenshot = $DialogScreenshotPath
        } finally { $bitmap.Dispose() }
      } catch { $result.Navigation.ScreenshotError = $_.Exception.Message }
    }

    if ($items.Count -eq 0) { throw "The target '$targetName' is not a visible Shell item in the verified parent directory." }
    $selected = $null
    $selectedPattern = $null
    $matchingRows = 0
    foreach ($candidate in $items) {
      $result.ShellItem.Candidates += [ordered]@{
        name = $candidate.Name; controlType = $candidate.ControlType
        automationId = $candidate.AutomationId; bounds = $candidate.Bounds
      }
      if ($SelectionMethod -in @('MouseShellItem', 'SendInputShellItem') -and $candidate.ControlType -notmatch 'ListItem|DataItem') { continue }
      try {
        $pattern = $candidate.Element.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
        if ($pattern) {
          $matchingRows++
          if (-not $selectedPattern) { $selected = $candidate; $selectedPattern = $pattern }
          if ($SelectionMethod -notin @('MouseShellItem', 'SendInputShellItem')) { break }
        }
      } catch { }
    }
    if (-not $selectedPattern) { throw "The visible target '$targetName' has no SelectionItemPattern; refusing to use the filename Edit." }
    if ($SelectionMethod -in @('MouseShellItem', 'SendInputShellItem') -and $matchingRows -ne 1) {
      throw "Expected one visible Shell list row for '$targetName'; found $matchingRows selectable rows."
    }
    $result.ShellItem.MatchedBy = if ($selected.Name -eq $targetName) { 'exact filename' } else { 'extension-hidden stem with unique filesystem match' }
    $result.ShellItem.SelectedElement = [ordered]@{
      name = $selected.Name; controlType = $selected.ControlType
      automationId = $selected.AutomationId; bounds = $selected.Bounds
    }
    if ($SelectionMethod -in @('MouseShellItem', 'SendInputShellItem')) {
      $result.ShellItem.WasSelectedBefore = [bool] $selectedPattern.Current.IsSelected
      $bounds = $selected.Bounds
      $screenX = [int] [Math]::Floor($bounds.left + ($bounds.width / 2))
      $screenY = [int] [Math]::Floor($bounds.top + ($bounds.height / 2))
      $useSendInput = $SelectionMethod -eq 'SendInputShellItem'
      if ($useSendInput -and $DismissRunnerPrivacyOverlay) {
        $overlay = [LocalSendDialogSelect.Driver]::DismissRunnerPrivacyOverlay($dialog)
        $result.RunnerPrivacyOverlay = $overlay
        if ($overlay.Error) { throw "Could not dismiss the identified runner privacy overlay: $($overlay.Error)" }
        if ($overlay.Detected) { $result.Actions += 'Dismissed the identified WWAHost Microsoft account privacy overlay on the disposable runner' }
      }
      $click = [LocalSendDialogSelect.Driver]::ClickVisibleShellItem($dialog, $TargetProcessId, $screenX, $screenY, $useSendInput, [bool] $DismissRunnerPrivacyOverlay)
      $result.ShellItem.MouseClick = $click
      if (-not $click.Posted) { throw "Could not click the visible Shell item using $($click.InputMethod): $($click.Error)" }
      $result.Actions += "Clicked visible Shell item using $($click.InputMethod) via $($click.TargetClass) $($click.TargetHwnd)"
      $selectionDeadline = [DateTime]::UtcNow.AddSeconds(3)
      do {
        Start-Sleep -Milliseconds 100
        $result.ShellItem.IsSelected = [bool] $selectedPattern.Current.IsSelected
      } while (-not $result.ShellItem.IsSelected -and [DateTime]::UtcNow -lt $selectionDeadline)
      if (-not $result.ShellItem.IsSelected -and $useSendInput) {
        # The first click on a background dialog may only activate it.
        $retryClick = [LocalSendDialogSelect.Driver]::ClickVisibleShellItem($dialog, $TargetProcessId, $screenX, $screenY, $true, [bool] $DismissRunnerPrivacyOverlay)
        $result.ShellItem.MouseClickRetry = $retryClick
        if (-not $retryClick.Posted) { throw "Could not retry the visible Shell item using SendInput: $($retryClick.Error)" }
        $selectionDeadline = [DateTime]::UtcNow.AddSeconds(3)
        do {
          Start-Sleep -Milliseconds 100
          $result.ShellItem.IsSelected = [bool] $selectedPattern.Current.IsSelected
        } while (-not $result.ShellItem.IsSelected -and [DateTime]::UtcNow -lt $selectionDeadline)
      }
      $result.ShellItem.SelectionPattern = "SelectionItemPattern.Current.IsSelected after $($click.InputMethod) click"
      if (-not $result.ShellItem.IsSelected -and $useSendInput -and $Mode -eq 'Folder') {
        # On this native folder dialog, UIA can report IsSelected=false even
        # while the clicked row is highlighted and the Folder field names it.
        $folderEdit = [LocalSendDialogSelect.Driver]::FindFilenameEdit($dialog)
        if ($folderEdit -ne [IntPtr]::Zero) {
          $result.ShellItem.NativeFolderField = [LocalSendDialogSelect.Driver]::ReadText($folderEdit)
          if ([string]::Equals($result.ShellItem.NativeFolderField, $targetName, [System.StringComparison]::OrdinalIgnoreCase)) {
            $result.ShellItem.IsSelected = $true
            $result.ShellItem.SelectionPattern = 'clicked visible Shell row and verified exact native Folder field'
          }
        }
      }
    } else {
      $selectedPattern.Select()
      $result.ShellItem.SelectionPattern = 'SelectionItemPattern.Select'
      $result.ShellItem.IsSelected = [bool] $selectedPattern.Current.IsSelected
      $result.Actions += 'Selected exact visible Shell item through SelectionItemPattern'
    }
    if (-not $result.ShellItem.IsSelected) { throw 'UI Automation did not report the exact Shell item selected.' }
    if ($SelectionMethod -in @('MouseShellItem', 'SendInputShellItem')) { $result.Actions += 'Verified exact Shell item selected through UI Automation after mouse click' }
    if ($SelectionMethod -eq 'SendInputShellItem') {
      $confirmationClick = [LocalSendDialogSelect.Driver]::ClickOkViaSendInput($dialog, $TargetProcessId, [bool] $DismissRunnerPrivacyOverlay)
      $result.ShellItem.ConfirmationClick = $confirmationClick
      if (-not $confirmationClick.Posted) { throw "Could not click Open/Select using SendInput: $($confirmationClick.Error)" }
      $result.Actions += 'Clicked Open/Select using SendInput'
    } else {
      if (-not [LocalSendDialogSelect.Driver]::PressOk($dialog)) { throw 'Could not activate Open/Select after Shell item selection.' }
      $result.Actions += 'Activated Open/Select after selecting Shell item'
    }
    while ([LocalSendDialogSelect.Driver]::DialogOpen($dialog) -and [DateTime]::UtcNow -lt $deadline) {
      Start-Sleep -Milliseconds 100
    }
    if ([LocalSendDialogSelect.Driver]::DialogOpen($dialog)) { throw 'Dialog remained open after Shell item selection.' }
    $result.Success = $true
  } catch {
    $result.Error = $_.Exception.ToString()
  }
  return [pscustomobject] $result
}

try {
  if (-not [System.IO.Path]::IsPathRooted($Path)) { throw "Path must be absolute: $Path" }
  if (-not (Test-Path -LiteralPath $Path -PathType $(if ($Mode -eq 'Folder') { 'Container' } else { 'Leaf' }))) {
    throw "Target $Mode does not exist: $Path"
  }
  Add-Type -TypeDefinition $source -Language CSharp -ErrorAction Stop
  $result = if ($SelectionMethod -in @('ShellItem', 'MouseShellItem', 'SendInputShellItem')) {
    Invoke-ShellItem
  } else {
    [LocalSendDialogSelect.Driver]::Run($TargetProcessId, $Path, $Mode, $TimeoutSeconds)
  }
  ConvertTo-Json -InputObject $result -Depth 8 -Compress
  if (-not $result.Success) { exit 1 }
} catch {
  ConvertTo-Json -InputObject @{ Success = $false; Error = $_.Exception.ToString(); TargetProcessId = $TargetProcessId; Path = $Path; Mode = $Mode; SelectionMethod = $SelectionMethod } -Depth 4 -Compress
  exit 1
}
