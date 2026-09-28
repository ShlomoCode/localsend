# Reproduce the Windows common-item-dialog path used by file_selector_windows 0.9.3+5.
# Run on a Windows desktop with LS_TIMESTAMP_FIXTURES and LS_DIAGNOSTIC_OUTPUT set.
param(
  [switch] $Child,
  [switch] $Folder,
  [int] $CaseIndex = -1,
  [string] $ChildOutput
)

$ErrorActionPreference = 'Stop'

function Write-JsonFile([string] $Path, $Value) {
  $json = ConvertTo-Json -InputObject $Value -Depth 12
  [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
}

function Get-FixtureCases {
  $root = $env:LS_TIMESTAMP_FIXTURES
  if ([string]::IsNullOrWhiteSpace($root)) { throw 'LS_TIMESTAMP_FIXTURES is not set.' }
  $manifest = Join-Path $root 'manifest.json'
  if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { throw "Missing fixture manifest: $manifest" }
  $cases = @(ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($manifest)))
  if ($cases.Count -eq 0) { throw 'The fixture manifest is empty.' }
  return $cases
}

function Get-FixturePath($Fixture, [bool] $IsFolder) {
  $candidate = if ($IsFolder) { [string] $Fixture.directory } else { [string] $Fixture.path }
  if ([string]::IsNullOrWhiteSpace($candidate)) { throw "Fixture '$($Fixture.name)' has no $(if ($IsFolder) { 'directory' } else { 'path' })." }
  if (-not [System.IO.Path]::IsPathRooted($candidate)) {
    $candidate = Join-Path $env:LS_TIMESTAMP_FIXTURES $candidate
  }
  return [System.IO.Path]::GetFullPath($candidate)
}

function Invoke-Child {
  $cases = Get-FixtureCases
  if ($CaseIndex -lt 0 -or $CaseIndex -ge $cases.Count) { throw "Invalid case index $CaseIndex." }
  $fixture = $cases[$CaseIndex]
  $isDirectory = [bool] $Folder
  $path = Get-FixturePath $fixture $isDirectory
  $result = [ordered]@{
    name = [string] $fixture.name
    selection = if ($isDirectory) { 'folder' } else { 'file' }
    expectedPath = $path
    expectedTimestamp = [string] $fixture.timestamp
    expectedSize = $fixture.size
    directory = [string] $fixture.directory
    status = 'inconclusive'
    reason = $null
    dialog = $null
  }
  try {
    if (-not (Test-Path -LiteralPath $path -PathType $(if ($isDirectory) { 'Container' } else { 'Leaf' }))) {
      throw "Fixture does not exist as expected: $path"
    }
    $source = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace LocalSendPickerProbe {
  [ComImport, Guid("dc1c5a9c-e88a-4dde-a5a1-60f82a20aef7")]
  internal class FileOpenDialogClass { }

  // Flat vtable: IModalWindow, IFileDialog, then IFileOpenDialog.
  [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("d57c7288-d4ad-4768-be02-9d969532d960")]
  internal interface IFileOpenDialog {
    [PreserveSig] int Show(IntPtr owner);
    [PreserveSig] int SetFileTypes(uint count, IntPtr filters);
    [PreserveSig] int SetFileTypeIndex(uint index);
    [PreserveSig] int GetFileTypeIndex(out uint index);
    [PreserveSig] int Advise(IntPtr events, out uint cookie);
    [PreserveSig] int Unadvise(uint cookie);
    [PreserveSig] int SetOptions(uint options);
    [PreserveSig] int GetOptions(out uint options);
    [PreserveSig] int SetDefaultFolder(IntPtr item);
    [PreserveSig] int SetFolder(IntPtr item);
    [PreserveSig] int GetFolder(out IntPtr item);
    [PreserveSig] int GetCurrentSelection(out IntPtr item);
    [PreserveSig] int SetFileName([MarshalAs(UnmanagedType.LPWStr)] string name);
    [PreserveSig] int GetFileName(out IntPtr name);
    [PreserveSig] int SetTitle([MarshalAs(UnmanagedType.LPWStr)] string title);
    [PreserveSig] int SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string label);
    [PreserveSig] int SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string label);
    [PreserveSig] int GetResult(out IntPtr item);
    [PreserveSig] int AddPlace(IntPtr item, int position);
    [PreserveSig] int SetDefaultExtension([MarshalAs(UnmanagedType.LPWStr)] string extension);
    [PreserveSig] int Close(int result);
    [PreserveSig] int SetClientGuid(ref Guid guid);
    [PreserveSig] int ClearClientData();
    [PreserveSig] int SetFilter(IntPtr filter);
    [PreserveSig] int GetResults(out IShellItemArray items);
    [PreserveSig] int GetSelectedItems(out IntPtr items);
  }

  [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("b63ea76d-1f85-456f-a19c-48159efa858b")]
  internal interface IShellItemArray {
    [PreserveSig] int BindToHandler(IntPtr bindCtx, ref Guid bhid, ref Guid riid, out IntPtr output);
    [PreserveSig] int GetPropertyStore(int flags, ref Guid riid, out IntPtr output);
    [PreserveSig] int GetPropertyDescriptionList(IntPtr keyType, ref Guid riid, out IntPtr output);
    [PreserveSig] int GetAttributes(int flags, uint mask, out uint attributes);
    [PreserveSig] int GetCount(out uint count);
    [PreserveSig] int GetItemAt(uint index, out IShellItem item);
    [PreserveSig] int EnumItems(out IntPtr enumerator);
  }

  [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe")]
  internal interface IShellItem {
    [PreserveSig] int BindToHandler(IntPtr bindCtx, ref Guid bhid, ref Guid riid, out IntPtr output);
    [PreserveSig] int GetParent(out IntPtr parent);
    [PreserveSig] int GetDisplayName(uint sigdnName, out IntPtr name);
    [PreserveSig] int GetAttributes(uint mask, out uint attributes);
    [PreserveSig] int Compare(IShellItem item, uint hint, out int order);
  }

  public class PickerResult {
    public string CreateHresult;
    public string GetOptionsHresult;
    public string SetOptionsHresult;
    public string SetFileNameHresult;
    public string ShowHresult;
    public string GetResultsHresult;
    public string GetCountHresult;
    public string[] ItemHresults;
    public string[] DisplayNameHresults;
    public string[] Paths;
    public string DialogHwnd;
    public string DialogClass;
    public string DialogTitle;
    public string DriverAction;
    public string DriverError;
    public bool DesktopVisible;
    public string Exception;
  }

  public static class Picker {
    private const uint FOS_PICKFOLDERS = 0x20;
    private const uint FOS_ALLOWMULTISELECT = 0x200;
    private const uint SIGDN_FILESYSPATH = 0x80058000;
    private const uint BM_CLICK = 0x00F5;
    private const uint WM_COMMAND = 0x0111;
    private const uint IDOK = 1;
    private delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr data);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr data);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr hwnd, StringBuilder name, int length);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr hwnd, StringBuilder name, int length);
    [DllImport("user32.dll")] private static extern IntPtr GetDlgItem(IntPtr hwnd, int id);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool PostMessage(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] private static extern IntPtr GetDesktopWindow();

    private static string Hr(int value) { return "0x" + unchecked((uint)value).ToString("X8"); }
    private static string Hwnd(IntPtr value) { return "0x" + value.ToInt64().ToString("X"); }

    public static PickerResult Run(string path, bool folder) {
      PickerResult result = new PickerResult();
      result.Paths = new string[0];
      result.DesktopVisible = GetDesktopWindow() != IntPtr.Zero;
      IFileOpenDialog dialog = null;
      Thread driver = null;
      try {
        dialog = (IFileOpenDialog)new FileOpenDialogClass();
        result.CreateHresult = Hr(0);
        uint options;
        int hr = dialog.GetOptions(out options);
        result.GetOptionsHresult = Hr(hr);
        if (hr < 0) return result;
        // openFiles() sets multiselect; getDirectoryPath() sets PICKFOLDERS.
        hr = dialog.SetOptions(options | (folder ? FOS_PICKFOLDERS : FOS_ALLOWMULTISELECT));
        result.SetOptionsHresult = Hr(hr);
        if (hr < 0) return result;
        hr = dialog.SetFileName(path);
        result.SetFileNameHresult = Hr(hr);
        if (hr < 0) return result;

        int processId = Process.GetCurrentProcess().Id;
        driver = new Thread(() => {
          try {
            DateTime deadline = DateTime.UtcNow.AddSeconds(12);
            while (DateTime.UtcNow < deadline) {
              IntPtr target = IntPtr.Zero;
              EnumWindows((hwnd, data) => {
                uint owner;
                GetWindowThreadProcessId(hwnd, out owner);
                if (owner != processId || !IsWindowVisible(hwnd)) return true;
                StringBuilder cls = new StringBuilder(128);
                GetClassName(hwnd, cls, cls.Capacity);
                if (cls.ToString() != "#32770") return true;
                target = hwnd;
                result.DialogClass = cls.ToString();
                StringBuilder title = new StringBuilder(256);
                GetWindowText(hwnd, title, title.Capacity);
                result.DialogTitle = title.ToString();
                return false;
              }, IntPtr.Zero);
              if (target != IntPtr.Zero) {
                result.DialogHwnd = Hwnd(target);
                Thread.Sleep(600);
                IntPtr button = GetDlgItem(target, (int)IDOK);
                if (button != IntPtr.Zero && PostMessage(button, BM_CLICK, IntPtr.Zero, IntPtr.Zero)) {
                  result.DriverAction = "process-owned IDOK button BM_CLICK";
                } else if (PostMessage(target, WM_COMMAND, new IntPtr(IDOK), IntPtr.Zero)) {
                  result.DriverAction = "process-owned dialog WM_COMMAND IDOK";
                } else {
                  result.DriverError = "PostMessage failed for the process-owned dialog";
                }
                return;
              }
              Thread.Sleep(100);
            }
            result.DriverError = "No visible process-owned #32770 dialog appeared within 12 seconds";
          } catch (Exception ex) { result.DriverError = ex.ToString(); }
        });
        driver.IsBackground = true;
        driver.Start();
        hr = dialog.Show(IntPtr.Zero);
        result.ShowHresult = Hr(hr);
        if (driver != null) driver.Join(1000);
        if (hr < 0) return result;

        IShellItemArray items;
        hr = dialog.GetResults(out items);
        result.GetResultsHresult = Hr(hr);
        if (hr < 0 || items == null) return result;
        try {
          uint count;
          hr = items.GetCount(out count);
          result.GetCountHresult = Hr(hr);
          if (hr < 0) return result;
          List<string> paths = new List<string>();
          List<string> itemHrs = new List<string>();
          List<string> nameHrs = new List<string>();
          for (uint i = 0; i < count; i++) {
            IShellItem item;
            hr = items.GetItemAt(i, out item);
            itemHrs.Add(Hr(hr));
            if (hr < 0 || item == null) continue;
            try {
              IntPtr name;
              hr = item.GetDisplayName(SIGDN_FILESYSPATH, out name);
              nameHrs.Add(Hr(hr));
              if (hr >= 0 && name != IntPtr.Zero) {
                try { paths.Add(Marshal.PtrToStringUni(name)); }
                finally { Marshal.FreeCoTaskMem(name); }
              }
            } finally { Marshal.ReleaseComObject(item); }
          }
          result.Paths = paths.ToArray();
          result.ItemHresults = itemHrs.ToArray();
          result.DisplayNameHresults = nameHrs.ToArray();
        } finally { Marshal.ReleaseComObject(items); }
      } catch (Exception ex) {
        result.Exception = ex.ToString();
        if (result.CreateHresult == null) result.CreateHresult = Hr(Marshal.GetHRForException(ex));
      } finally {
        if (dialog != null) Marshal.ReleaseComObject(dialog);
      }
      return result;
    }
  }
}
'@
    Add-Type -TypeDefinition $source -Language CSharp -ErrorAction Stop
    $dialog = [LocalSendPickerProbe.Picker]::Run($path, $isDirectory)
    $result.dialog = $dialog
    $returned = @($dialog.Paths)
    if ($dialog.ShowHresult -eq '0x00000000' -and $dialog.GetResultsHresult -eq '0x00000000' -and
        $returned.Count -eq 1 -and [string]::Equals($returned[0], $path, [System.StringComparison]::OrdinalIgnoreCase)) {
      $result.status = 'pass'
      $result.reason = 'Native picker returned the expected filesystem path.'
    } elseif ($dialog.ShowHresult -eq '0x00000000' -and $dialog.GetResultsHresult -eq '0x00000000') {
      $result.status = 'fail'
      $result.reason = 'Native picker completed but returned an unexpected filesystem path or item count.'
    } else {
      $result.reason = 'Native picker did not complete; inspect HWND, driver action, HRESULT, and exception.'
    }
  } catch {
    $result.reason = $_.Exception.ToString()
  }
  Write-JsonFile $ChildOutput $result
}

if ($Child) {
  Invoke-Child
  exit 0
}

$outputDir = $env:LS_DIAGNOSTIC_OUTPUT
if ([string]::IsNullOrWhiteSpace($outputDir)) { throw 'LS_DIAGNOSTIC_OUTPUT is not set.' }
[System.IO.Directory]::CreateDirectory($outputDir) | Out-Null
$reportPath = Join-Path $outputDir 'picker-report.json'
$report = [ordered]@{
  probe = 'file_selector_windows 0.9.3+5 native IFileOpenDialog Show/GetResults/SIGDN_FILESYSPATH'
  generatedUtc = [DateTime]::UtcNow.ToString('o')
  computer = $env:COMPUTERNAME
  sessionName = $env:SESSIONNAME
  cases = @()
}
try {
  $cases = Get-FixtureCases
  $exe = (Get-Process -Id $PID).Path
  for ($i = 0; $i -lt $cases.Count; $i++) {
    foreach ($isFolder in @($false, $true)) {
      $selection = if ($isFolder) { 'folder' } else { 'file' }
      $caseOutput = Join-Path $outputDir ("picker-case-$i-$selection.json")
      $stdoutPath = Join-Path $outputDir ("picker-case-$i-$selection.stdout.txt")
      $stderrPath = Join-Path $outputDir ("picker-case-$i-$selection.stderr.txt")
      $folderArgument = if ($isFolder) { '-Folder' } else { '' }
      $arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "{0}" -Child -CaseIndex {1} {2} -ChildOutput "{3}"' -f $PSCommandPath, $i, $folderArgument, $caseOutput
      $process = Start-Process -FilePath $exe -ArgumentList $arguments -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
      if (-not $process.WaitForExit(20000)) {
        $process.Kill()
        $process.WaitForExit()
        $caseResult = [ordered]@{
          name = [string] $cases[$i].name
          selection = $selection
          expectedPath = Get-FixturePath $cases[$i] $isFolder
          status = 'inconclusive'
          reason = 'Native dialog did not complete within 20 seconds; desktop interaction may be unavailable.'
          processTimedOut = $true
        }
      } elseif (Test-Path -LiteralPath $caseOutput -PathType Leaf) {
        $caseResult = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($caseOutput))
      } else {
        $caseResult = [ordered]@{
          name = [string] $cases[$i].name
          selection = $selection
          expectedPath = Get-FixturePath $cases[$i] $isFolder
          status = 'inconclusive'
          reason = "Probe child exited $($process.ExitCode) without a case report."
        }
      }
      $caseResult = [pscustomobject] $caseResult
      $caseResult | Add-Member -NotePropertyName processExitCode -NotePropertyValue $process.ExitCode -Force
      $caseResult | Add-Member -NotePropertyName stdout -NotePropertyValue ([System.IO.File]::ReadAllText($stdoutPath)) -Force
      $caseResult | Add-Member -NotePropertyName stderr -NotePropertyValue ([System.IO.File]::ReadAllText($stderrPath)) -Force
      $report.cases += $caseResult
    }
  }
} catch {
  $report.error = $_.Exception.ToString()
} finally {
  Write-JsonFile $reportPath $report
}
Write-Host "Picker report: $reportPath"
if ($report.error -or @($report.cases | Where-Object { $_.status -ne 'pass' }).Count -gt 0) { exit 1 }
