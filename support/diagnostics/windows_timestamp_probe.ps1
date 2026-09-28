# Reproduce Windows file metadata failures at and before the DOS timestamp boundary.
# Run on a 64-bit Windows runner before the Dart and Flutter probes.
param(
    [string]$FixtureRoot = (Join-Path ([IO.Path]::GetTempPath()) ("localsend-timestamps-" + [guid]::NewGuid().ToString('N')))
)

$ErrorActionPreference = 'Stop'
if (-not [Environment]::Is64BitProcess) {
    throw 'The _wstat64 structure below is for a 64-bit process.'
}

Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class NativeTimestampProbe {
    [StructLayout(LayoutKind.Sequential)]
    public struct Stat64 {
        public int Device;
        public ushort Inode;
        public ushort Mode;
        public short LinkCount;
        public short UserId;
        public short GroupId;
        public int RawDevice;
        public long Size;
        public long AccessTime;
        public long ModificationTime;
        public long ChangeTime;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct FileTime {
        public uint Low;
        public uint High;
        public long Ticks { get { return ((long)High << 32) | Low; } }
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct AttributeData {
        public uint Attributes;
        public FileTime CreationTime;
        public FileTime AccessTime;
        public FileTime WriteTime;
        public uint SizeHigh;
        public uint SizeLow;
        public long Size { get { return ((long)SizeHigh << 32) | SizeLow; } }
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct ByHandleInformation {
        public uint Attributes;
        public FileTime CreationTime;
        public FileTime AccessTime;
        public FileTime WriteTime;
        public uint VolumeSerialNumber;
        public uint SizeHigh;
        public uint SizeLow;
        public uint LinkCount;
        public uint FileIndexHigh;
        public uint FileIndexLow;
        public long Size { get { return ((long)SizeHigh << 32) | SizeLow; } }
    }

    [DllImport("ucrtbase.dll", EntryPoint = "_wstat64", CharSet = CharSet.Unicode, CallingConvention = CallingConvention.Cdecl)]
    public static extern int WStat64(string path, out Stat64 data);

    [DllImport("ucrtbase.dll", EntryPoint = "_get_errno", CallingConvention = CallingConvention.Cdecl)]
    private static extern int GetErrnoNative(out int error);

    public static int GetErrno() {
        int error;
        return GetErrnoNative(out error) == 0 ? error : -1;
    }

    [DllImport("kernel32.dll", EntryPoint = "GetFileAttributesExW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetFileAttributesEx(string path, int infoLevel, out AttributeData data);

    [DllImport("kernel32.dll", EntryPoint = "GetFileInformationByHandle", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetFileInformationByHandle(SafeFileHandle handle, out ByHandleInformation data);

    [DllImport("kernel32.dll", EntryPoint = "FileTimeToDosDateTime", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool FileTimeToDosDateTime(ref FileTime fileTime, out ushort date, out ushort time);

    public static ByHandleInformation ProbeHandle(string path) {
        using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) {
            ByHandleInformation data;
            if (!GetFileInformationByHandle(stream.SafeFileHandle, out data)) {
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            }
            return data;
        }
    }
}
'@

function Write-JsonFile([string]$Path, $Value) {
    $json = ConvertTo-Json -InputObject $Value -Depth 8
    [IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
}

function Check-Size([long]$Actual, [long]$Expected) {
    return @{ status = $(if ($Actual -eq $Expected) { 'pass' } else { 'fail' }); size = $Actual; expectedSize = $Expected }
}

$FixtureRoot = [IO.Path]::GetFullPath($FixtureRoot)
if ([Runtime.InteropServices.Marshal]::SizeOf([NativeTimestampProbe+Stat64]::new()) -ne 56) {
    throw 'Unexpected x64 _stat64 structure size.'
}
[IO.Directory]::CreateDirectory($FixtureRoot) | Out-Null
$outputDirectory = $env:LS_DIAGNOSTIC_OUTPUT
if ([string]::IsNullOrWhiteSpace($outputDirectory)) {
    $outputDirectory = Join-Path $FixtureRoot 'diagnostics'
}
$outputDirectory = [IO.Path]::GetFullPath($outputDirectory)
[IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
$env:LS_DIAGNOSTIC_OUTPUT = $outputDirectory

$payload = [Text.Encoding]::ASCII.GetBytes("LocalSend timestamp fixture`n")
$now = [DateTime]::UtcNow
$now = [DateTime]::new($now.Year, $now.Month, $now.Day, $now.Hour, $now.Minute, $now.Second, [DateTimeKind]::Utc)
$cases = @(
    @{ name = 'current'; time = $now },
    @{ name = '1980-boundary'; time = [DateTime]::Parse('1980-01-01T00:00:00Z').ToUniversalTime() },
    @{ name = '1979-59'; time = [DateTime]::Parse('1979-12-31T23:59:59Z').ToUniversalTime() },
    @{ name = '1979-58'; time = [DateTime]::Parse('1979-12-31T23:59:58Z').ToUniversalTime() },
    @{ name = '1970'; time = [DateTime]::Parse('1970-01-01T00:00:00Z').ToUniversalTime() },
    @{ name = '1969'; time = [DateTime]::Parse('1969-12-31T23:59:59Z').ToUniversalTime() },
    # FILETIME zero means "leave unchanged" to SetFileTime, so use one second later.
    @{ name = '1601-plus-one-second'; time = [DateTime]::Parse('1601-01-01T00:00:01Z').ToUniversalTime() }
)

$manifest = @()
foreach ($case in $cases) {
    $directory = Join-Path $FixtureRoot $case.name
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $path = Join-Path $directory 'file.txt'
    [IO.File]::WriteAllBytes($path, $payload)
    [IO.File]::SetLastWriteTimeUtc($path, $case.time)
    $actual = [IO.File]::GetLastWriteTimeUtc($path)
    if ($actual -ne $case.time) {
        throw "Timestamp did not round-trip for $($case.name): requested $($case.time.ToString('o')), actual $($actual.ToString('o'))"
    }
    $manifest += @{ name = $case.name; timestamp = $actual.ToString('o'); requestedTimestamp = $case.time.ToString('o'); path = $path; directory = $directory; size = $payload.Length }
}
Write-JsonFile (Join-Path $FixtureRoot 'manifest.json') @($manifest)
[IO.File]::Copy((Join-Path $FixtureRoot 'manifest.json'), (Join-Path $outputDirectory 'manifest.json'), $true)

$env:LS_TIMESTAMP_FIXTURES = $FixtureRoot
if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_ENV)) {
    $encoding = New-Object Text.UTF8Encoding($false)
    [IO.File]::AppendAllText($env:GITHUB_ENV, "LS_TIMESTAMP_FIXTURES=$FixtureRoot`nLS_DIAGNOSTIC_OUTPUT=$outputDirectory`n", $encoding)
}

$results = @()
$unexpectedFailures = 0
foreach ($item in $manifest) {
    $operations = @{}
    $stat = New-Object NativeTimestampProbe+Stat64
    $statCode = [NativeTimestampProbe]::WStat64($item.path, [ref]$stat)
    if ($statCode -eq 0) {
        $operations.wstat64 = Check-Size $stat.Size $item.size
        $operations.wstat64.modificationTimeSeconds = $stat.ModificationTime
        if ($operations.wstat64.status -eq 'fail') { $unexpectedFailures++ }
    } else {
        $operations.wstat64 = @{ status = 'error'; returnCode = $statCode; errno = [NativeTimestampProbe]::GetErrno() }
        $unexpectedFailures++
    }

    $attributes = New-Object NativeTimestampProbe+AttributeData
    if ([NativeTimestampProbe]::GetFileAttributesEx($item.path, 0, [ref]$attributes)) {
        $operations.getFileAttributesEx = Check-Size $attributes.Size $item.size
        $operations.getFileAttributesEx.writeTimeTicks = $attributes.WriteTime.Ticks
        if ($operations.getFileAttributesEx.status -eq 'fail') { $unexpectedFailures++ }

        $dosDate = [ushort]0
        $dosTime = [ushort]0
        $writeTime = $attributes.WriteTime
        if ([NativeTimestampProbe]::FileTimeToDosDateTime([ref]$writeTime, [ref]$dosDate, [ref]$dosTime)) {
            $operations.fileTimeToDosDateTime = @{ status = 'pass'; dosDate = $dosDate; dosTime = $dosTime }
        } else {
            # Pre-1980 dates cannot be represented as DOS dates. This is a finding, not a probe failure.
            $operations.fileTimeToDosDateTime = @{ status = 'error'; win32Error = [Runtime.InteropServices.Marshal]::GetLastWin32Error(); expectedForPre1980 = ($item.name -ne 'current' -and $item.name -ne '1980-boundary') }
        }
    } else {
        $operations.getFileAttributesEx = @{ status = 'error'; win32Error = [Runtime.InteropServices.Marshal]::GetLastWin32Error() }
        $operations.fileTimeToDosDateTime = @{ status = 'skipped'; reason = 'GetFileAttributesEx failed' }
        $unexpectedFailures++
    }

    try {
        $handleInfo = [NativeTimestampProbe]::ProbeHandle($item.path)
        $operations.getFileInformationByHandle = Check-Size $handleInfo.Size $item.size
        $operations.getFileInformationByHandle.writeTimeTicks = $handleInfo.WriteTime.Ticks
        if ($operations.getFileInformationByHandle.status -eq 'fail') { $unexpectedFailures++ }
    } catch {
        $operations.getFileInformationByHandle = @{ status = 'error'; message = $_.Exception.Message }
        $unexpectedFailures++
    }
    $results += @{ name = $item.name; timestamp = $item.timestamp; path = $item.path; operations = $operations }
    Write-Host "$($item.name): _wstat64=$($operations.wstat64.status), GetFileAttributesEx=$($operations.getFileAttributesEx.status), GetFileInformationByHandle=$($operations.getFileInformationByHandle.status), FileTimeToDosDateTime=$($operations.fileTimeToDosDateTime.status)"
}

$reportPath = Join-Path $outputDirectory 'native-report.json'
Write-JsonFile $reportPath @{ fixtureRoot = $FixtureRoot; manifest = (Join-Path $FixtureRoot 'manifest.json'); unexpectedFailures = $unexpectedFailures; cases = @($results) }
Write-Host "Timestamp fixtures: $FixtureRoot"
Write-Host "Native probe report: $reportPath"
if ($unexpectedFailures -gt 0) { exit 1 }
