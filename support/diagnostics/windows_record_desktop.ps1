param(
  [Parameter(Mandatory)][string] $FramesDirectory,
  [Parameter(Mandatory)][string] $StopFile
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[IO.Directory]::CreateDirectory($FramesDirectory) | Out-Null
$bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
if ($bounds.Width -le 0 -or $bounds.Height -le 0) { throw "Invalid virtual screen bounds: $bounds" }
$started = [DateTime]::UtcNow
$index = 0
while (-not (Test-Path -LiteralPath $StopFile) -and ([DateTime]::UtcNow - $started).TotalSeconds -lt 120) {
  $bitmap = [System.Drawing.Bitmap]::new($bounds.Width, $bounds.Height)
  try {
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
      $graphics.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bounds.Size)
    } finally {
      $graphics.Dispose()
    }
    $frame = Join-Path $FramesDirectory ('frame-{0:D4}.jpg' -f $index)
    $bitmap.Save($frame, [System.Drawing.Imaging.ImageFormat]::Jpeg)
  } finally {
    $bitmap.Dispose()
  }
  $index++
  Start-Sleep -Milliseconds 250
}
Write-Output "Captured $index frames at $($bounds.Width)x$($bounds.Height)."
