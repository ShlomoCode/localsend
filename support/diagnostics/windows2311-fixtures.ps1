param([Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
# Execute only on a cloud Windows runner. Publish this directory once, then reuse
# its exact bytes for every baseline/candidate/device comparison.
if(Test-Path (Join-Path $OutputDirectory 'manifest.json')){throw 'Fixture artifact already exists; reuse it without regenerating'}
New-Item -ItemType Directory -Force $OutputDirectory|Out-Null
$ffmpeg=(Get-Command ffmpeg -ErrorAction SilentlyContinue).Source
$ffprobe=(Get-Command ffprobe -ErrorAction SilentlyContinue).Source
if(!$ffmpeg -or !$ffprobe){throw 'Cloud fixture generation needs FFmpeg and ffprobe provisioned by the workflow'}
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.IO;
using System.Text;
public static class ExifFixture2311 {
  public static byte[] Segment() {
    // Little-endian TIFF: IFD0 Exif pointer, then the two capture date tags.
    // String offsets are relative to the TIFF header. No filesystem date appears here.
    using(var buffer=new MemoryStream()) using(var writer=new BinaryWriter(buffer)) {
      writer.Write(Encoding.ASCII.GetBytes("Exif\0\0II"));writer.Write((ushort)42);writer.Write((uint)8);
      writer.Write((ushort)1);writer.Write((ushort)0x8769);writer.Write((ushort)4);writer.Write((uint)1);writer.Write((uint)26);writer.Write((uint)0);
      writer.Write((ushort)2);
      writer.Write((ushort)0x9003);writer.Write((ushort)2);writer.Write((uint)20);writer.Write((uint)56);
      writer.Write((ushort)0x9004);writer.Write((ushort)2);writer.Write((uint)20);writer.Write((uint)76);
      writer.Write((uint)0);
      writer.Write(Encoding.ASCII.GetBytes("2020:06:07 08:09:10\0"));writer.Write(Encoding.ASCII.GetBytes("2020:06:07 08:09:10\0"));
      return buffer.ToArray();
    }
  }
  public static void Insert(string input,string output) {
    byte[] jpeg=File.ReadAllBytes(input),segment=Segment();
    if(jpeg.Length<2||jpeg[0]!=255||jpeg[1]!=216)throw new InvalidDataException("Not a JPEG");
    using(var stream=File.Create(output)) {
      stream.Write(jpeg,0,2);stream.WriteByte(255);stream.WriteByte(225);
      int length=segment.Length+2;stream.WriteByte((byte)(length>>8));stream.WriteByte((byte)length);
      stream.Write(segment,0,segment.Length);stream.Write(jpeg,2,jpeg.Length-2);
    }
  }
}
'@
$jpegBase=Join-Path $OutputDirectory 'jpeg-base.jpg'
$jpeg=Join-Path $OutputDirectory 'capture.jpg'
$image=[Drawing.Bitmap]::new(32,24);$graphics=[Drawing.Graphics]::FromImage($image)
try{$graphics.Clear([Drawing.Color]::FromArgb(19,57,91));$image.Save($jpegBase,[Drawing.Imaging.ImageFormat]::Jpeg)}finally{$graphics.Dispose();$image.Dispose()}
[ExifFixture2311]::Insert($jpegBase,$jpeg)
Remove-Item $jpegBase
$verifiedImage=[Drawing.Image]::FromFile($jpeg)
try{
 $tags=@([Text.Encoding]::ASCII.GetString($verifiedImage.GetPropertyItem(0x9003).Value).TrimEnd([char]0),[Text.Encoding]::ASCII.GetString($verifiedImage.GetPropertyItem(0x9004).Value).TrimEnd([char]0))
}finally{$verifiedImage.Dispose()}
if($tags.Count -ne 2 -or $tags[0] -ne '2020:06:07 08:09:10' -or $tags[1] -ne '2020:06:07 08:09:10'){throw 'JPEG capture tag verification failed'}
$video=Join-Path $OutputDirectory 'capture.mp4'
& $ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i 'color=c=blue:s=32x24:r=10:d=1' -an -c:v libx264 -pix_fmt yuv420p -threads 1 -metadata 'creation_time=2021-08-09T10:11:12Z' -metadata:s:v:0 'creation_time=2021-08-09T10:11:12Z' -movflags +faststart -y $video
if($LASTEXITCODE -ne 0){throw 'FFmpeg video fixture generation failed'}
$probe=& $ffprobe -v error -show_format -show_streams -of json $video
if($LASTEXITCODE -ne 0){throw 'ffprobe video verification failed'}
$probeJson=($probe -join "`n")|ConvertFrom-Json
if($probeJson.format.tags.creation_time -ne '2021-08-09T10:11:12.000000Z' -or $probeJson.streams[0].codec_type -ne 'video' -or [double]$probeJson.format.duration -le 0){throw 'Video capture metadata verification failed'}
$old=[DateTime]::Parse('2025-02-13T14:11:00Z').ToUniversalTime()
$files=@()
foreach($path in @($jpeg,$video)){
 [IO.File]::SetLastWriteTimeUtc($path,$old)
 $files+=@{name=[IO.Path]::GetFileName($path);sha256=(Get-FileHash $path).Hash.ToLowerInvariant();bytes=(Get-Item $path).Length;mtimeUtc=[IO.File]::GetLastWriteTimeUtc($path).ToString('o')}
}
$ffmpegVersion=(& $ffmpeg -version|Select-Object -First 1)
@{artifactPolicy='Generate once in cloud; reuse identical bytes across baseline/candidate and devices';files=$files;jpeg=@{dateTimeOriginal=$tags[0];dateTimeDigitized=$tags[1];timezone='No EXIF timezone tag; compare raw capture tags independently from MediaStore datetaken'};video=$probeJson;ffmpegVersion=$ffmpegVersion}|ConvertTo-Json -Depth 12|Set-Content (Join-Path $OutputDirectory 'manifest.json')
$probe|Set-Content (Join-Path $OutputDirectory 'video-ffprobe.json')
