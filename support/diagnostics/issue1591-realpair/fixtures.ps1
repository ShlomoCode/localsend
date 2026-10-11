param([string]$ReuseDirectory)
$ErrorActionPreference='Stop'
New-Item -ItemType Directory -Force evidence | Out-Null
if($ReuseDirectory){
 $index=Get-Content "$ReuseDirectory/fixture-index.json" -Raw|ConvertFrom-Json
 foreach($kind in @('mkv','mp4')){
  $name=$index.$kind
  if([IO.Path]::GetFileName($name) -ne $name){throw 'Fixture index must contain a filename'}
  $source=Join-Path $ReuseDirectory $name
  $identity=Get-Content "$source.identity.json" -Raw|ConvertFrom-Json
  if((Get-FileHash $source -Algorithm SHA256).Hash.ToLower() -ne $identity.sha256 -or (Get-Item $source).Length -ne $identity.bytes){throw 'Reused fixture identity mismatch'}
  Copy-Item $source,"$source.identity.json","$source.ffprobe.json" evidence/
 }
 Copy-Item "$ReuseDirectory/fixture-index.json" evidence/
 Copy-Item "$ReuseDirectory/ffmpeg-version.txt","$ReuseDirectory/ffprobe-version.txt" evidence/
 return
}
ffmpeg -version | Set-Content evidence/ffmpeg-version.txt
ffprobe -version | Set-Content evidence/ffprobe-version.txt
$mp4="evidence/issue1591-$env:GITHUB_RUN_ID.mp4"
$mkv="evidence/issue1591-$env:GITHUB_RUN_ID.mkv"
ffmpeg -hide_banner -y -f lavfi -i 'testsrc2=size=160x120:rate=10' -f lavfi -i 'sine=frequency=880:sample_rate=44100' -t 1 -c:v libx264 -pix_fmt yuv420p -c:a aac -movflags +faststart $mp4 2> evidence/fixture-encode.txt
if($LASTEXITCODE -ne 0){throw 'Valid MP4 fixture generation failed'}
ffmpeg -hide_banner -y -i $mp4 -map 0 -c copy $mkv 2> evidence/fixture-remux.txt
if($LASTEXITCODE -ne 0){throw 'Same-codec MKV remux failed'}
foreach($path in @($mp4,$mkv)){
 $name=[IO.Path]::GetFileName($path)
 ffprobe -v error -show_format -show_streams -of json $path | Set-Content "evidence/$name.ffprobe.json"
 if($LASTEXITCODE -ne 0){throw "Fixture validation failed: $name"}
 $probe=Get-Content "evidence/$name.ffprobe.json" -Raw|ConvertFrom-Json
 if(@($probe.streams|Where-Object codec_name -eq h264).Count -ne 1 -or @($probe.streams|Where-Object codec_name -eq aac).Count -ne 1){throw 'Fixture codecs differ from H264/AAC'}
 @{filename=$name;path=[IO.Path]::GetFullPath($path);sha256=(Get-FileHash $path -Algorithm SHA256).Hash.ToLower();bytes=(Get-Item $path).Length;container=$probe.format.format_name;streams=$probe.streams;generation='MP4 encoded once; MKV remuxed without transcoding'}|ConvertTo-Json -Depth 15|Set-Content "evidence/$name.identity.json"
}
@{mkv=[IO.Path]::GetFileName($mkv);mp4=[IO.Path]::GetFileName($mp4)}|ConvertTo-Json|Set-Content evidence/fixture-index.json
