param([string]$Exe, [string]$Evidence)
$ErrorActionPreference = "Stop"
Start-Transcript (Join-Path $Evidence direct-child-original.txt)
$PSVersionTable | Out-String | Write-Output
try { & $Exe }
catch {
    $_ | Format-List * -Force | Out-File (Join-Path $Evidence direct-child-original-error.txt)
    $_.Exception | Format-List * -Force | Out-File (Join-Path $Evidence direct-child-exception.txt)
    exit 2
} finally { Stop-Transcript }
