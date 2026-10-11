# Component regression only: execute the receiver's actual verification block.
# The hash boundary publishes the Android receipt before returning its Windows digest.
$ErrorActionPreference='Stop'
$sourcePath=Join-Path $PSScriptRoot 'windows_receiver.ps1'
$candidate=Get-Content -LiteralPath $sourcePath -Raw
$baseline=(& git show '1b14424098058239b003e5b8e1dabf843b687f51:support/diagnose_3556/windows_receiver.ps1') -join "`n"
if($LASTEXITCODE -ne 0){throw 'Negative-control receiver source unavailable'}
function Parse-Receiver([string]$Text){
 $tokens=$null;$errors=$null
 $ast=[System.Management.Automation.Language.Parser]::ParseInput($Text,[ref]$tokens,[ref]$errors)
 if($errors.Count){throw ($errors | Out-String)}
 return $ast
}
function Exercise-Verification([string]$Text,[bool]$ShouldPass){
 $ast=Parse-Receiver $Text
 $functions=@($ast.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-ValidatedExpectedHash'},$true))
 foreach($function in $functions){Invoke-Expression $function.Extent.Text}
 $blocks=@($ast.FindAll({param($node) $node -is [System.Management.Automation.Language.ForEachStatementAst] -and $node.Extent.Text.Contains('$beforeHash=Get-Item')},$true))
 if($blocks.Count -ne 1){throw 'Expected exactly one real saved-file verification block'}
 $destination=Join-Path $env:RUNNER_TEMP ('receipt-race-'+[Guid]::NewGuid().ToString('N'))
 [void][IO.Directory]::CreateDirectory($destination)
 $ExpectedName='owned.mp4';$filePath=Join-Path $destination $ExpectedName
 [IO.File]::WriteAllBytes($filePath,[byte[]](1..17))
 $ExpectedBytes=17L;$ExpectedSha256='';$ExpectedHashFile=Join-Path $destination 'expected-sha256.json'
 $beforePaths=@();$large=$true;$verifiedHashes=@{};$exitCode=1;$OutputDirectory=$destination
 $report=@{senderCompletion=@{uri='content://owned/fixture'};destination=@{};savedFiles=@();stage='waiting';status='waiting'}
 function Save-Snapshot([string]$Name){}
 function Get-DestinationCapacity([string]$Path){return @{scope='Component fixture only'}}
 function Get-BoundedFileHash([string]$Path,[string]$Label){
  if(Test-Path $ExpectedHashFile){throw 'Receipt must be absent at the hash boundary'}
  $digest=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
  # Model Android publication during the Windows hash call. The caller cannot
  # use a previously captured ExpectedSha256 after this boundary returns.
  [IO.File]::WriteAllText($ExpectedHashFile,(ConvertTo-Json @{bytes=$ExpectedBytes;name=$ExpectedName;uri=$report.senderCompletion.uri;sha256=$digest}),[Text.UTF8Encoding]::new($false))
  return $digest
 }
 $failure=$null
 try{Invoke-Expression $blocks[0].Extent.Text}catch{$failure=$_.Exception.Message}
 try{
  if($ShouldPass){
   if($failure -or $exitCode -ne 0 -or $report.savedFiles.Count -ne 1){throw "Candidate verification failed: $failure"}
   if($report.savedFiles[0].sha256 -ne (Get-FileHash $filePath).Hash.ToLowerInvariant()){throw 'Candidate saved digest differs'}
  }else{
   if($failure -ne 'Saved Windows bytes disagree with the Android fixture hash.'){throw "Negative control did not catch the receipt race: $failure"}
  }
 }finally{Remove-Item -LiteralPath $destination -Recurse -Force}
}
Exercise-Verification $baseline $false
Exercise-Verification $candidate $true
Write-Host 'Negative control caught stale receipt; candidate verified the same saved content with the fresh receipt. Component check only; no app reproduction.'
