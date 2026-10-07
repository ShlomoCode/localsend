# Build a local image and video gallery inside a test's downloadable evidence artifact.
param([Parameter(Mandatory = $true)] [string] $EvidenceDirectory)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $EvidenceDirectory)) { return }
$directory = (Resolve-Path $EvidenceDirectory).Path.TrimEnd('\', '/')
$report = $null
$captions = @{}
$metadataPath = Join-Path $directory 'evidence.json'
if (Test-Path $metadataPath) {
    $report = Get-Content $metadataPath -Raw | ConvertFrom-Json
    foreach ($item in $report.Media) { $captions[$item.Path.Replace('\', '/')] = $item }
}
$title = if ($report.Title) { $report.Title } else { 'Windows E2E visual evidence' }
$description = if ($report.Description) { $report.Description } else { 'Images and videos captured by this test.' }
$title = [System.Net.WebUtility]::HtmlEncode($title)
$description = [System.Net.WebUtility]::HtmlEncode($description)
$imageExtensions = @('.png', '.jpg', '.jpeg', '.gif', '.webp')
$videoExtensions = @('.mp4', '.webm')
$media = @(Get-ChildItem $directory -File -Recurse |
    Where-Object { $_.Extension.ToLowerInvariant() -in ($imageExtensions + $videoExtensions) } | Sort-Object FullName)
$cards = foreach ($file in $media) {
    $relative = $file.FullName.Substring($directory.Length + 1).Replace('\', '/')
    $caption = $captions[$relative]
    $label = [System.Net.WebUtility]::HtmlEncode($(if ($caption.Title) { $caption.Title } else { $relative }))
    $details = [System.Net.WebUtility]::HtmlEncode($caption.Description)
    $filename = [System.Net.WebUtility]::HtmlEncode($relative)
    $url = (($relative.Split('/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/')
    $preview = if ($file.Extension.ToLowerInvariant() -in $videoExtensions) {
        "<video controls preload=`"none`" src=`"$url`" aria-label=`"$label`"></video>"
    } else {
        "<a href=`"$url`"><img src=`"$url`" alt=`"$label`" loading=`"lazy`"></a>"
    }
    "<figure><h2>$label</h2>$preview<figcaption><p>$details</p><a href=`"$url`">Open original: $filename</a></figcaption></figure>"
}
@"
<!doctype html>
<html lang="en">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$title</title>
<style>
body { font: 16px system-ui; margin: 24px; background: #f5f5f5; color: #222; }
main { display: grid; grid-template-columns: repeat(auto-fit, minmax(320px, 1fr)); gap: 20px; }
figure { margin: 0; padding: 16px; background: white; border: 1px solid #ddd; border-radius: 8px; }
img, video { max-width: 100%; height: auto; } figcaption { margin-top: 12px; overflow-wrap: anywhere; }
h2 { font-size: 18px; margin: 0 0 16px; } figcaption p { line-height: 1.5; }
</style>
<h1>$title</h1>
<p>$description</p>
<p>$($media.Count) images and videos. Select a filename to open the original file. Test results and logs are in this artifact.</p>
<main>$($cards -join "`n")</main>
</html>
"@ | Set-Content -Encoding UTF8 (Join-Path $directory 'index.html')
