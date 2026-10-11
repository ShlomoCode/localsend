param([string]$Image,[string]$Result)
$ErrorActionPreference='Stop'
$report=@{status='unsupported';image=$Image;words=@()}
try {
 Add-Type -AssemblyName System.Runtime.WindowsRuntime
 [void][Windows.Storage.StorageFile,Windows.Storage,ContentType=WindowsRuntime]
 [void][Windows.Graphics.Imaging.BitmapDecoder,Windows.Foundation,ContentType=WindowsRuntime]
 [void][Windows.Media.Ocr.OcrEngine,Windows.Foundation,ContentType=WindowsRuntime]
 [void][Windows.Globalization.Language,Windows.Globalization,ContentType=WindowsRuntime]
 function Await($Operation,[Type]$Type) {
  $method=[System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.IsGenericMethod -and $_.GetGenericArguments().Count -eq 1 -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
  $task=$method.MakeGenericMethod($Type).Invoke($null,@($Operation)); $task.Wait(); return $task.Result
 }
 $file=Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($Image)) ([Windows.Storage.StorageFile])
 $stream=Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
 try {
  $decoder=Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
  $bitmap=Await ($decoder.GetSoftwareBitmapAsync([Windows.Graphics.Imaging.BitmapPixelFormat]::Bgra8,[Windows.Graphics.Imaging.BitmapAlphaMode]::Premultiplied)) ([Windows.Graphics.Imaging.SoftwareBitmap])
  try {
   $engine=[Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage([Windows.Globalization.Language]::new('en-US'))
   if($null -eq $engine) { throw 'Native Windows OCR en-US language is unavailable.' }
   $recognized=Await ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
   $report.status='recognized'; $report.text=$recognized.Text; $report.textAngle=$recognized.TextAngle
   foreach($line in $recognized.Lines) { foreach($word in $line.Words) {
    $r=$word.BoundingRect; $report.words+=@{text=$word.Text;x=$r.X;y=$r.Y;width=$r.Width;height=$r.Height}
   } }
  } finally { $bitmap.Dispose() }
 } finally { $stream.Dispose() }
} catch { $report.error=$_.Exception.ToString() }
[IO.File]::WriteAllText($Result,(ConvertTo-Json $report -Depth 8),[Text.UTF8Encoding]::new($false))