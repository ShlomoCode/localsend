function Save-PackageInventory($Name) {
    $packages = @(Get-AppxPackage LocalSend.App -ErrorAction Stop)
    $packages | Format-List * | Out-File (Join-Path $Evidence "$Name-package-raw.txt")
    foreach ($package in $packages) {
        Get-AppxPackageManifest $package | ForEach-Object { $_.OuterXml } |
            Set-Content (Join-Path $Evidence "$Name-registered-AppxManifest.xml")
    }
    Write-Event package @{ Name = $Name; Count = $packages.Count; FullNames = @($packages.PackageFullName) }
    return $packages
}
function Save-InstalledInventory($Directory) {
    $target = Join-Path $Evidence installed
    New-Item -ItemType Directory -Force $target | Out-Null
    Get-ChildItem $Directory -Recurse -File | Get-FileHash -Algorithm SHA256 |
        Select-Object Path, Algorithm, Hash | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $target hashes.json)
    $exe = Join-Path $Directory localsend_app.exe
    (Get-Item $exe).VersionInfo | Format-List * | Out-File (Join-Path $target exe-version.txt)
    foreach ($file in Get-ChildItem $Directory -File | Where-Object { $_.Extension -in @(".exe", ".dll", ".msix", ".manifest") }) {
        Copy-Item $file.FullName $target
        Get-AuthenticodeSignature $file.FullName | Format-List * | Out-File (Join-Path $target "$($file.Name)-signature.txt")
    }
    [IO.File]::WriteAllBytes((Join-Path $target embedded-RT_MANIFEST.bin), [Issue3456Native]::EmbeddedManifest($exe))
    $msix = Join-Path $Directory localsend_msix_helper.msix
    if (Test-Path $msix) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($msix)
        try {
            $zip.Entries | Select-Object FullName, Length | ConvertTo-Json | Set-Content (Join-Path $target msix-entries.json)
            $entry = $zip.GetEntry("AppxManifest.xml")
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $target helper-AppxManifest.xml), $true)
        } finally { $zip.Dispose() }
    }
    Save-PackageInventory installed | Out-Null
    foreach ($branch in @("HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall", "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall")) {
        if (Test-Path $branch) {
            Get-ItemProperty "$branch\*" | Where-Object DisplayName -eq "LocalSend" |
                Format-List * | Out-File (Join-Path $target uninstall-registry.txt) -Append
        } else { "Absent optional branch: $branch" | Add-Content (Join-Path $target uninstall-registry.txt) }
    }
    $shell = New-Object -ComObject WScript.Shell
    foreach ($path in @("$env:PUBLIC\Desktop\LocalSend.lnk", "$env:USERPROFILE\Desktop\LocalSend.lnk", "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\LocalSend.lnk", "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\LocalSend.lnk")) {
        if (Test-Path $path) {
            Copy-Item $path (Join-Path $target (([IO.Path]::GetFileName([IO.Path]::GetDirectoryName($path))) + "-LocalSend.lnk"))
            $link = $shell.CreateShortcut($path)
            Write-Event shortcut @{ Path = $path; Target = $link.TargetPath; Arguments = $link.Arguments; WorkingDirectory = $link.WorkingDirectory }
        }
    }
}
