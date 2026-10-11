param(
 [ValidateSet("short","ascii105000","multiline105000","ascii105kib","unbroken105000","manylines105000","cjk105000","emoji105000")][string]$Case="short"
)
$ErrorActionPreference="Stop"
Add-Type -AssemblyName System.Windows.Forms
switch($Case) {
 "short" { $text="issue2830 short clipboard control 0123456789" }
 "ascii105000" { $text=("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz " * 1667).Substring(0,105000) }
 "multiline105000" { $text=(("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz " + "`n") * 1641).Substring(0,105000) }
 "ascii105kib" { $text=("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz " * 1707).Substring(0,107520) }
 "unbroken105000" { $text=("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz" * 1694).Substring(0,105000) }
 "manylines105000" { $text="x`n" * 52500 }
 "cjk105000" { $text=([string][char]0x4E2D + [string][char]0x6587) * 52500 }
 "emoji105000" { $text=[char]::ConvertFromUtf32(0x1F600) * 105000 }
}
[System.Windows.Forms.Clipboard]::SetText($text,[System.Windows.Forms.TextDataFormat]::UnicodeText)
$roundtrip=[System.Windows.Forms.Clipboard]::GetText([System.Windows.Forms.TextDataFormat]::UnicodeText)
if($roundtrip -cne $text){throw "Windows clipboard roundtrip differs from exact fixture"}
$utf8=[System.Text.UTF8Encoding]::new($false)
$bytes=$utf8.GetBytes($text)
[System.IO.File]::WriteAllBytes((Join-Path $PWD "evidence/$Case.txt"),$bytes)
$sha=[System.Security.Cryptography.SHA256]::Create()
try {$digest=[Convert]::ToHexString($sha.ComputeHash($bytes)).ToLowerInvariant()}finally{$sha.Dispose()}
@{case=$Case;chars=$text.Length;utf16Units=$text.Length;unicodeScalars=([System.Text.RegularExpressions.Regex]::Matches($text,"[\uD800-\uDBFF][\uDC00-\uDFFF]|[^\uD800-\uDFFF]")).Count;utf8Bytes=$bytes.Length;utf16Bytes=[System.Text.Encoding]::Unicode.GetByteCount($text);lf=($text.ToCharArray()|Where-Object{$_ -eq "`n"}).Count;cr=($text.ToCharArray()|Where-Object{$_ -eq "`r"}).Count;sha256=$digest;clipboardRoundtrip=$true;utc=[DateTime]::UtcNow.ToString("o")}|ConvertTo-Json|Set-Content "evidence/$Case-fixture.json"
