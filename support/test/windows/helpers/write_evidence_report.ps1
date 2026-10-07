# Build a local image and video gallery inside a test's downloadable evidence artifact.
param([Parameter(Mandatory = $true)] [string] $EvidenceDirectory)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $EvidenceDirectory)) { return }
$directory = (Resolve-Path $EvidenceDirectory).Path.TrimEnd('\', '/')
$imageExtensions = @('.png', '.jpg', '.jpeg', '.gif', '.webp')
$videoExtensions = @('.mp4', '.webm')
$media = @(Get-ChildItem $directory -File -Recurse |
    Where-Object { $_.Extension.ToLowerInvariant() -in ($imageExtensions + $videoExtensions) } | Sort-Object FullName)
$cards = foreach ($file in $media) {
    $relative = $file.FullName.Substring($directory.Length + 1).Replace('\', '/')
    $label = [System.Net.WebUtility]::HtmlEncode($relative)
    $url = (($relative.Split('/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/')
    $preview = if ($file.Extension.ToLowerInvariant() -in $videoExtensions) {
        "<video controls preload=`"none`" src=`"$url`" aria-label=`"$label`"></video>"
    } else {
        "<a href=`"$url`"><img src=`"$url`" alt=`"$label`" loading=`"lazy`"></a>"
    }
    "<figure>$preview<figcaption><a href=`"$url`">$label</a></figcaption></figure>"
}
@"
<!doctype html>
<html lang="en">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Windows E2E visual evidence</title>
<style>
body { font: 16px system-ui; margin: 24px; background: #f5f5f5; color: #222; }
main { display: grid; grid-template-columns: repeat(auto-fit, minmax(320px, 1fr)); gap: 20px; }
figure { margin: 0; padding: 16px; background: white; border: 1px solid #ddd; border-radius: 8px; }
img, video { max-width: 100%; height: auto; } figcaption { margin-top: 12px; overflow-wrap: anywhere; }
</style>
<h1>Windows E2E visual evidence</h1>
<p>$($media.Count) images and videos. Select a filename to open the original file. Test results and logs are in this artifact.</p>
<main>$($cards -join "`n")</main>
</html>
"@ | Set-Content -Encoding UTF8 (Join-Path $directory 'index.html')
