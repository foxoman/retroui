# The Windows packages made in Nim, checked by Windows itself: the
# program's Authenticode signature, the MSIX installed and removed.
# Run from the repository: pwsh tests/store/windows.ps1 (as an admin: it
# trusts the test certificate on this machine).
$ErrorActionPreference = "Stop"
$env:RETRO_KEYS = "$PWD\build\store-keys"
nim c -d:release --hints:off -o:build\retrokit.exe src\retrokit.nim
nim c -d:release --hints:off -o:build\storehello.exe tests\store\storehello.nim
$tsa = "http://timestamp.digicert.com"
.\build\retrokit.exe sign build\storehello.exe --name:"Store Hello" "--timestamp:$tsa"
if ($LASTEXITCODE -ne 0) { throw "retrokit sign failed" }
.\build\retrokit.exe msix build\storehello.exe --name:Retro.StoreHello --display:"Store Hello" --version:1.0.1 "--timestamp:$tsa"
if ($LASTEXITCODE -ne 0) { throw "retrokit msix failed" }
$cert = "$env:RETRO_KEYS\windows\dev-cert.der"
Import-Certificate -FilePath $cert -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
Import-Certificate -FilePath $cert -CertStoreLocation Cert:\LocalMachine\TrustedPeople | Out-Null
$sig = Get-AuthenticodeSignature build\storehello.exe
Write-Host "The program's signature: $($sig.Status) ($($sig.SignerCertificate.Subject))"
if ($sig.Status -ne "Valid") { throw "the signature is $($sig.Status): $($sig.StatusMessage)" }
if (-not $sig.TimeStamperCertificate) { throw "no time stamp" }
Write-Host "Stamped by: $($sig.TimeStamperCertificate.Subject)"
& .\build\storehello.exe
$signtool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe" -ErrorAction SilentlyContinue | Select-Object -Last 1
if ($signtool) {
  & $signtool.FullName verify /pa /v build\storehello.exe
  if ($LASTEXITCODE -ne 0) { throw "signtool verify failed" }
  & $signtool.FullName verify /pa /v build\storehello.msix
  if ($LASTEXITCODE -ne 0) {
    # (what Windows' own signtool signs the same package with: the digest
    # part by part -- files, central directory, content types, block map --
    # beside ours, to see which part Windows reads otherwise)
    .\build\retrokit.exe msix build\storehello.exe --name:Retro.StoreHello --display:"Store Hello" --version:1.0.1 --unsigned -o:build\storehello-unsigned.msix
    $pem = Get-Content -Raw "$env:RETRO_KEYS\windows\dev-key.pem"
    $x = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($cert)
    $rsa = [System.Security.Cryptography.RSA]::Create(); $rsa.ImportFromPem($pem)
    [System.IO.File]::WriteAllBytes("$PWD\build\dev.pfx", [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::CopyWithPrivateKey($x, $rsa).Export("Pfx", "retro"))
    & $signtool.FullName sign /fd SHA256 /f build\dev.pfx /p retro build\storehello-unsigned.msix
    & $signtool.FullName verify /pa build\storehello-unsigned.msix
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    foreach ($m in "build\storehello.msix", "build\storehello-unsigned.msix") {
      $z = [System.IO.Compression.ZipFile]::OpenRead("$PWD\$m")
      $s = New-Object System.IO.MemoryStream
      $z.GetEntry("AppxSignature.p7x").Open().CopyTo($s); $z.Dispose()
      $b = $s.ToArray(); $hex = [System.BitConverter]::ToString($b).Replace("-", "")
      $at = $hex.IndexOf("41505058") / 2
      for ($k = 0; $k -lt 5; $k++) {
        $o = $at + 4 + 36 * $k
        if ($o + 36 -gt $b.Length) { break }
        Write-Host "$m $([System.Text.Encoding]::ASCII.GetString($b, $o, 4)) $($hex.Substring(2 * ($o + 4), 64))"
      }
    }
    throw "signtool verify of the MSIX failed"
  }
}
$makeappx = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\makeappx.exe" -ErrorAction SilentlyContinue | Select-Object -Last 1
if ($makeappx) {
  & $makeappx.FullName unpack /v /o /p build\storehello.msix /d build\storehello-unpacked
  if ($LASTEXITCODE -ne 0) { throw "makeappx could not read the MSIX" }
}
Add-AppxPackage -Path build\storehello.msix
$p = Get-AppxPackage -Name Retro.StoreHello
if (-not $p) { throw "the MSIX did not install" }
Write-Host "Installed: $($p.PackageFullName) in $($p.InstallLocation)"
& "$($p.InstallLocation)\storehello.exe"
Remove-AppxPackage -Package $p.PackageFullName
Write-Host "store packages: ok"
