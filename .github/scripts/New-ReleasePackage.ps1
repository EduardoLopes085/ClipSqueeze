#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$OutputDirectory,
    [string]$Tag,
    [ValidatePattern('\A[0-9A-Fa-f]{40}\z')]
    [string]$SigningCertificateThumbprint
)

$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$scripts = @('ClipSqueeze.ps1', 'install.ps1', 'update.ps1', 'uninstall.ps1')
$packageFiles = $scripts + @('config.json', 'README.md', 'README.en.md', 'LICENSE')

$scriptPaths = @($scripts | ForEach-Object { Join-Path $root $_ })
$scriptPaths += @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File | Select-Object -ExpandProperty FullName)
foreach ($path in $scriptPaths) {
    $tokens = $null
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw "PowerShell syntax error in ${path}: $($parseErrors -join '; ')" }
}

$config = Get-Content -LiteralPath (Join-Path $root 'config.json') -Raw | ConvertFrom-Json
$version = $config.applicationVersion
$versionPattern = '(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
if ($version -isnot [string] -or $version -cnotmatch "\A$versionPattern\z") {
    throw 'config.json applicationVersion must use the MAJOR.MINOR.PATCH format.'
}
$installer = Get-Content -LiteralPath (Join-Path $root 'install.ps1') -Raw
$installerVersionPattern = '(?m)^\$script:ApplicationVersion\s*=\s*''(?<version>[^'']+)''[ \t]*\r?$'
if ($installer -cnotmatch $installerVersionPattern -or $Matches.version -cne $version) {
    throw 'The application version in install.ps1 must match config.json.'
}
if (($SigningCertificateThumbprint -or $Tag) -and $Tag -cne "v$version") {
    throw "The release tag must be v$version."
}

$output = New-Item -Path $OutputDirectory -ItemType Directory
$stage = New-Item -Path (Join-Path $output.FullName 'stage') -ItemType Directory
try {
    foreach ($name in $packageFiles) {
        Copy-Item -LiteralPath (Join-Path $root $name) -Destination $stage.FullName
    }

    if ($SigningCertificateThumbprint) {
        $certificate = Get-Item -LiteralPath "Cert:\CurrentUser\My\$SigningCertificateThumbprint"
        if (-not $certificate.HasPrivateKey) {
            throw 'The selected Windows certificate must have access to its signing key.'
        }

        $sha256 = [Security.Cryptography.SHA256]::Create()
        try {
            $signerSha256 = [BitConverter]::ToString($sha256.ComputeHash($certificate.RawData)).Replace('-', '')
        }
        finally {
            $sha256.Dispose()
        }
        $updater = Join-Path $stage.FullName 'update.ps1'
        $updateSource = [IO.File]::ReadAllText($updater)
        $pinPlaceholder = '$script:OfficialSignerSha256 = ' + "''"
        if (-not $updateSource.Contains($pinPlaceholder)) { throw 'The updater signer pin placeholder was not found.' }
        $pinAssignment = '$script:OfficialSignerSha256 = ' + "'$signerSha256'"
        [IO.File]::WriteAllText($updater, $updateSource.Replace($pinPlaceholder, $pinAssignment), [Text.UTF8Encoding]::new($true))

        foreach ($name in $scripts) {
            $path = Join-Path $stage.FullName $name
            $null = Set-AuthenticodeSignature -FilePath $path -Certificate $certificate -HashAlgorithm SHA256 -TimestampServer 'http://timestamp.digicert.com'
            $signature = Get-AuthenticodeSignature -LiteralPath $path
            if ($signature.Status -ne 'Valid' -or -not $signature.TimeStamperCertificate -or $signature.SignerCertificate.Thumbprint -ne $certificate.Thumbprint) {
                throw "Authenticode verification failed for ${name}: $($signature.StatusMessage)"
            }
        }
        Write-Host "Official signing certificate SHA-256 $signerSha256"
    }

    $mainScript = Join-Path $output.FullName 'ClipSqueeze.ps1'
    $archive = Join-Path $output.FullName "ClipSqueeze-v$version.zip"
    $stagedPaths = @($packageFiles | ForEach-Object { Join-Path $stage.FullName $_ })
    Copy-Item -LiteralPath (Join-Path $stage.FullName 'ClipSqueeze.ps1') -Destination $mainScript
    Compress-Archive -LiteralPath $stagedPaths -DestinationPath $archive

    $hashes = Get-FileHash -LiteralPath $mainScript, $archive -Algorithm SHA256
    $hashes | ForEach-Object { '{0} *{1}' -f $_.Hash.ToLowerInvariant(), (Split-Path $_.Path -Leaf) } |
        Set-Content -LiteralPath (Join-Path $output.FullName 'SHA256SUMS.txt') -Encoding Ascii
    Write-Host "Built ClipSqueeze v$version in $($output.FullName)"
}
finally {
    Get-ChildItem -LiteralPath $stage.FullName -File | Remove-Item -Force
    Remove-Item -LiteralPath $stage.FullName
}
