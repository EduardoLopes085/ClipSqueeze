#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackageDirectory,
    [Parameter(Mandatory)][ValidatePattern('\Av(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\z')][string]$Tag,
    [Parameter(Mandatory)][ValidatePattern('\A[0-9A-Fa-f]{64}\z')][string]$SignerSha256
)

$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$SignerSha256 = $SignerSha256.ToUpperInvariant()
$scripts = @('ClipSqueeze.ps1', 'install.ps1', 'update.ps1', 'uninstall.ps1')
$packageFiles = $scripts + @('config.json', 'README.md', 'README.en.md', 'LICENSE')
$config = Get-Content -LiteralPath (Join-Path $root 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($Tag -cne "v$($config.applicationVersion)") { throw 'The tag does not match the package source version.' }

$archive = Join-Path $PackageDirectory "ClipSqueeze-$Tag.zip"
$mainScript = Join-Path $PackageDirectory 'ClipSqueeze.ps1'
$manifest = @(Get-Content -LiteralPath (Join-Path $PackageDirectory 'SHA256SUMS.txt'))
$hashes = Get-FileHash -LiteralPath $mainScript, $archive -Algorithm SHA256
$expectedHashes = @($hashes | ForEach-Object { '{0} *{1}' -f $_.Hash.ToLowerInvariant(), (Split-Path $_.Path -Leaf) })
if ($manifest.Count -ne $expectedHashes.Count -or (Compare-Object $expectedHashes $manifest -CaseSensitive)) {
    throw 'SHA256SUMS.txt does not match the release assets.'
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($archive)
try {
    $entries = @($zip.Entries | Select-Object -ExpandProperty FullName)
    if ($entries.Count -ne $packageFiles.Count -or (Compare-Object $packageFiles $entries -CaseSensitive)) {
        throw 'The package has missing or unexpected ZIP entries.'
    }
    if ($zip.Entries | Where-Object { $_.Length -gt 10MB }) { throw 'The package contains an oversized file.' }
}
finally {
    $zip.Dispose()
}

$stage = New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) ("ClipSqueeze-verify-" + [guid]::NewGuid()))
$sha256 = [Security.Cryptography.SHA256]::Create()
try {
    Expand-Archive -LiteralPath $archive -DestinationPath $stage.FullName
    foreach ($name in $packageFiles) {
        $path = Join-Path $stage.FullName $name
        $published = [IO.File]::ReadAllText($path)
        $source = [IO.File]::ReadAllText((Join-Path $root $name))
        if ($name -in $scripts) {
            $signature = Get-AuthenticodeSignature -LiteralPath $path
            if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or -not $signature.TimeStamperCertificate) {
                throw "Missing valid Authenticode signature and timestamp for $name."
            }
            $certificateHash = [BitConverter]::ToString($sha256.ComputeHash($signature.SignerCertificate.RawData)).Replace('-', '')
            if ($certificateHash -cne $SignerSha256) { throw "Unexpected signer certificate for $name." }

            $published = $published -creplace '(?ms)\r?\n# SIG # Begin signature block\r?\n.*?\r?\n# SIG # End signature block(?:\r?\n)?\z', ''
            $published = $published.TrimEnd("`r", "`n")
            $source = $source.TrimEnd("`r", "`n")
        }
        if ($name -eq 'update.ps1') {
            $source = $source.Replace(('$script:OfficialSignerSha256 = ' + "''"), ('$script:OfficialSignerSha256 = ' + "'$SignerSha256'"))
        }
        if (($published -replace "`r`n", "`n") -cne ($source -replace "`r`n", "`n")) {
            throw "$name does not match the tagged source."
        }
    }
    if ((Get-FileHash -LiteralPath (Join-Path $stage.FullName 'ClipSqueeze.ps1')).Hash -ne $hashes[0].Hash) {
        throw 'The standalone script differs from the signed ZIP copy.'
    }
    Write-Host "Verified signed ClipSqueeze $Tag package."
}
finally {
    $sha256.Dispose()
    Get-ChildItem -LiteralPath $stage.FullName -File | Remove-Item -Force
    Remove-Item -LiteralPath $stage.FullName
}
