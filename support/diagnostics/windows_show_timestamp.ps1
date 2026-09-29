param([Parameter(Mandatory)][string] $Path)

$ErrorActionPreference = 'Stop'
$Host.UI.RawUI.WindowTitle = 'Issue #3366: set the file timestamp'
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('en-GB')
Write-Host 'PowerShell - exact timestamp command from issue #3366' -ForegroundColor Cyan
Write-Host '[Thread]::CurrentThread.CurrentCulture = GetCultureInfo(''en-GB'')'
Write-Host '$date = Get-Date ''31-12-1979 23:59:58Z'''
Write-Host '(Get-Item -LiteralPath $file).LastWriteTime = $date'
Write-Host "`$file = '$Path'"
$date = Get-Date '31-12-1979 23:59:58Z'
(Get-Item -LiteralPath $Path).LastWriteTime = $date
Get-Item -LiteralPath $Path | Select-Object Name, LastWriteTime, LastWriteTimeUtc | Format-List
Start-Sleep -Seconds 8
