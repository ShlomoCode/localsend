function ReadCaptureProgress($file) {
 if(!(Test-Path $file)){return $null}
 $content=Get-Content $file -Raw
 # Windows PowerShell can pass an empty command result as null even after a cast.
 if([string]::IsNullOrEmpty($content)){return $null}
 $blocks=[regex]::Matches($content,'(?m)^frame=(\d+)\r?\n(?:(?!frame=|progress=)[^\r\n]*\r?\n)*?out_time_us=(\d+)\r?\n(?:(?!frame=|progress=)[^\r\n]*\r?\n)*?progress=(continue|end)(?:\r?\n|$)')
 if(!$blocks.Count){return $null}
 return $blocks[$blocks.Count-1]
}
function NewCaptureProgressPath($directory,$name) {
 $file=Join-Path $directory "$name-progress-$([guid]::NewGuid().ToString('N')).txt"
 if(Test-Path $file){throw 'Capture generation unexpectedly exists before recorder start'}
 return $file
}
function ReadLiveCaptureProgress($file,$process) {
 if($process.HasExited){return $null}
 $block=ReadCaptureProgress $file
 if($process.HasExited){return $null}
 return $block
}
function RemainingCaptureGrace($clock) {
 return [int][Math]::Max(0,45000-$clock.ElapsedMilliseconds)
}
function FinishOwnedRecorder($name,$process,$clock,$progressFile,$outputDirectory) {
 if(!$process){return}
 $forced=$false
 if(!$process.HasExited){
  $remaining=RemainingCaptureGrace $clock
  if(!$process.WaitForExit($remaining)){$forced=$true;$process.Kill();$process.WaitForExit()}
 }
 @{forcedRecorderTermination=$forced;utc=[DateTime]::UtcNow.ToString('o');exitCode=$process.ExitCode;elapsedFromStart=$clock.Elapsed.TotalSeconds;progressFile=$progressFile;lastProgress=$(if(Test-Path $progressFile){[System.IO.File]::ReadAllText($progressFile)}else{''})}|ConvertTo-Json|Set-Content "$outputDirectory/$name-cleanup.json"
}
