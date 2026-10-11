$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$root=(Get-Location).Path
$evidence=Join-Path $root 'evidence/2230'
Start-Transcript -Path (Join-Path $evidence 'prepare.log')
try {
  wsl --list --verbose
  netsh interface ipv4 show excludedportrange protocol=tcp | Out-File (Join-Path $evidence 'windows-excluded-tcp-ports.txt')
  if($LASTEXITCODE -ne 0) { throw 'WSL inventory failed.' }
  $linuxRoot=(& wsl -d Ubuntu-24.04 -u root -- wslpath -a $root.Replace('\','/')).Trim()
  if($LASTEXITCODE -ne 0) { throw 'WSL path mapping failed.' }
  & wsl -d Ubuntu-24.04 -u root -- bash "$linuxRoot/support/diagnose_2230/prepare.sh" "$linuxRoot/evidence/2230"
  if($LASTEXITCODE -ne 0) { throw 'Ubuntu original-release installation/readiness failed; no product case counted.' }
  & "$PSScriptRoot/fixtures.ps1"
  Copy-Item C:/2230/manifest.json (Join-Path $evidence 'manifest.json')
  $zip=Join-Path $evidence 'original-windows.zip'
  Invoke-WebRequest 'https://github.com/localsend/localsend/releases/download/v1.16.1/LocalSend-1.16.1-windows-x86-64.zip' -OutFile $zip -TimeoutSec 180
  Get-FileHash $zip -Algorithm SHA256 | ConvertTo-Json | Out-File (Join-Path $evidence 'windows-release-hash.json')
  $appDir='C:/2230-app'
  Expand-Archive $zip $appDir
  $exe=@(Get-ChildItem $appDir -Recurse -Filter localsend_app.exe)
  if($exe.Count -ne 1) { throw 'Original Windows archive has no unique application.' }
  $settings=@{'flutter.ls_version'=2;'flutter.ls_alias'='Windows2230';'flutter.ls_port'=41631;'flutter.ls_https'=$false;'flutter.ls_quick_save'=$false;'flutter.ls_locale'='en';'flutter.ls_auto_finish'=$false}
  $settings | ConvertTo-Json | Set-Content (Join-Path $exe[0].DirectoryName 'settings.json') -Encoding UTF8
  $exe[0].FullName | Set-Content (Join-Path $evidence 'windows-executable.txt')
  Remove-Item $zip
} finally { Stop-Transcript }
