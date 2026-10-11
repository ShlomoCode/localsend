# Preparation only. Execute on the authorized Windows cloud sender, never locally.
# The Chinese names are boundary controls, not the reporter's unknown exact name.
param([string]$FixtureRoot = 'C:\2230')
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $FixtureRoot | Out-Null
$cjk = [char]0x5B57
$topics = '中华传统文化大百科套装五十册中国历史哲学文学艺术民俗典籍书画建筑医学礼仪宗教考古地理人物故事'
$title = $topics
while ($title.Length -lt 98) { $title += $topics }
$bookName = '0288. ' + $title.Substring(0,98) + '.txt'
if ([Text.Encoding]::UTF8.GetByteCount($bookName) -ne 304) { throw 'Synthetic book filename must be exactly 304 UTF-8 bytes.' }
$cases = @(
  @{ id = 'ascii-control'; name = 'ordinary-control.txt' },
  @{ id = 'utf8-254'; name = (($cjk.ToString() * 83) + 'a.txt') },
  @{ id = 'utf8-255'; name = (($cjk.ToString() * 83) + 'aa.txt') },
  @{ id = 'utf8-256'; name = (($cjk.ToString() * 83) + 'aaa.txt') },
  @{ id = 'utf8-304'; name = (($cjk.ToString() * 100) + '.txt') },
  @{ id = 'booklike-304'; name = $bookName }
)
$payloadBytes = 10276045
$chunk = New-Object byte[] 65536
for ($i = 0; $i -lt $chunk.Length; $i++) { $chunk[$i] = $i % 251 }
$manifest = foreach ($case in $cases) {
  $path = Join-Path $FixtureRoot $case.name
  if ([System.IO.File]::Exists($path)) { throw "Fixture already exists: $($case.id)" }
  $stream = [System.IO.File]::Open($path, 'CreateNew', 'Write', 'None')
  try {
    $remaining = $payloadBytes
    while ($remaining -gt 0) {
      $count = [Math]::Min($remaining, $chunk.Length)
      $stream.Write($chunk, 0, $count)
      $remaining -= $count
    }
  } finally { $stream.Dispose() }
  [ordered]@{
    id = $case.id
    filename = $case.name
    path = $path
    utf8Bytes = [System.Text.Encoding]::UTF8.GetByteCount($case.name)
    utf16Units = $case.name.Length
    bytes = (Get-Item -LiteralPath $path).Length
    sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    exactReporterFilename = $false
  }
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $FixtureRoot 'manifest.json') -Encoding UTF8
