# Drive LocalSend's real file_selector_windows dialog in its owning process.
# The caller must assert the Flutter picker result after this script exits.
param(
  [Parameter(Mandatory = $true)][int] $TargetProcessId,
  [Parameter(Mandatory = $true)][string] $Path,
  [Parameter(Mandatory = $true)][ValidateSet('File', 'Folder')][string] $Mode,
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
    public string DialogHwnd;
    public string DialogTitle;
    public string EditHwnd;
    public string EditReadback;
    public string ButtonHwnd;
    public List<string> Actions = new List<string>();
    public List<ControlInfo> Controls = new List<ControlInfo>();
  }

  public static class Driver {
    private const uint WM_SETTEXT = 0x000C;
    private const uint WM_GETTEXT = 0x000D;
    private const uint BM_CLICK = 0x00F5;
    private const uint WM_COMMAND = 0x0111;
    private const uint SMTO_ABORTIFHUNG = 0x0002;
    private const int IDC_FILENAME = 0x047C; // cmb13, the common-dialog filename combo.
    private const int IDC_FILENAME_EDIT = 0x0480; // edt1 on older common dialogs.
    private const int IDOK = 1;
    private delegate bool EnumProc(IntPtr hwnd, IntPtr data);

    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc callback, IntPtr data);
    [DllImport("user32.dll")] private static extern bool EnumChildWindows(IntPtr parent, EnumProc callback, IntPtr data);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
    [DllImport("user32.dll")] private static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hwnd);
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
    private static IntPtr FindDialog(int processId) {
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
    public static Result Run(int processId, string path, string mode, int timeoutSeconds) {
      Result result = new Result { TargetProcessId = processId, Path = path, Mode = mode };
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

try {
  if (-not [System.IO.Path]::IsPathRooted($Path)) { throw "Path must be absolute: $Path" }
  if (-not (Test-Path -LiteralPath $Path -PathType $(if ($Mode -eq 'Folder') { 'Container' } else { 'Leaf' }))) {
    throw "Target $Mode does not exist: $Path"
  }
  Add-Type -TypeDefinition $source -Language CSharp -ErrorAction Stop
  $result = [LocalSendDialogSelect.Driver]::Run($TargetProcessId, $Path, $Mode, $TimeoutSeconds)
  ConvertTo-Json -InputObject $result -Depth 8 -Compress
  if (-not $result.Success) { exit 1 }
} catch {
  ConvertTo-Json -InputObject @{ Success = $false; Error = $_.Exception.ToString(); TargetProcessId = $TargetProcessId; Path = $Path; Mode = $Mode } -Depth 4 -Compress
  exit 1
}
