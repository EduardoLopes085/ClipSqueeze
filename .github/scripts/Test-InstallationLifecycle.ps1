#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$fixture = New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) "ClipSqueeze lifecycle $([guid]::NewGuid())")
$originalLocalAppData = $env:LOCALAPPDATA
$originalTemp = $env:TEMP
$originalLastExitCode = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue -ValueOnly

function New-LifecycleModule {
    param([string]$FileName)

    $path = Join-Path $root $FileName
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
    $definitions = foreach ($statement in $ast.EndBlock.Statements) {
        if ($statement -is [System.Management.Automation.Language.TryStatementAst]) { break }
        if ($statement -is [System.Management.Automation.Language.AssignmentStatementAst] -and $statement.Left.Extent.Text -eq '$script:SourceScriptPath') { continue }
        $statement.Extent.Text
    }
    New-Module -ScriptBlock ([scriptblock]::Create($definitions -join "`n"))
}

try {
    $env:LOCALAPPDATA = $fixture.FullName
    $env:TEMP = $fixture.FullName
    $installRoot = Join-Path $fixture.FullName 'ClipSqueeze'
    $profilePath = Join-Path $fixture.FullName 'Microsoft.VSCode_profile.ps1'
    $statePath = Join-Path $installRoot 'install-state.json'
    $installedScript = Join-Path $installRoot 'ClipSqueeze.ps1'
    $configPath = Join-Path $installRoot 'config.json'
    $sourceScript = Join-Path $root 'ClipSqueeze.ps1'
    $installedVersion = [version](Get-Content -LiteralPath (Join-Path $root 'config.json') -Raw | ConvertFrom-Json).applicationVersion
    $nextVersion = [version]::new($installedVersion.Major, $installedVersion.Minor, ($installedVersion.Build + 1))

    $updater = New-LifecycleModule 'update.ps1'
    & $updater {
        Test-PowerShellVersion
        $failure = $null
        try { Assert-SafeInstallRoot } catch { $failure = $_ }
        if (-not $failure -or (Test-Path -LiteralPath $script:InstallRoot)) {
            throw 'Update before installation created an installation directory.'
        }
    }

    $installer = New-LifecycleModule 'install.ps1'
    & $installer {
        param($Source, $Profile)
        $script:SourceScriptPath = $Source
        $script:ProfilePath = $Profile
        $script:SkipFfmpegInstallation = $true
        function script:Ensure-ExecutionPolicy {
            throw 'Execution policy must not be reached for an unmanaged directory.'
        }
        $null = New-Item -ItemType Directory -Path $script:InstallRoot
        $personal = Join-Path $script:InstallRoot 'personal.txt'
        Set-Content -LiteralPath $personal -Value 'preserve'
        $failure = $null
        try { Invoke-Install } catch { $failure = $_; Invoke-Rollback }
        if (-not $failure -or $failure.Exception.Message -notlike '*reconhecida*' -or (Get-Content -LiteralPath $personal) -ne 'preserve') {
            throw 'Installer rollback did not preserve the unmanaged directory.'
        }
        Remove-Item -LiteralPath $personal
        [IO.Directory]::Delete($script:InstallRoot)
    } $sourceScript $profilePath

    $installer = New-LifecycleModule 'install.ps1'
    & $installer {
        param($Source, $Profile)
        $script:SourceScriptPath = $Source
        $script:ProfilePath = $Profile
        $script:SkipFfmpegInstallation = $true
        function script:Ensure-ExecutionPolicy {
            $script:PreviousCurrentUserExecutionPolicy = 'Restricted'
            $script:ExecutionPolicyChangedByInstaller = $true
        }
        function script:Install-FfmpegIfNeeded { $script:FfmpegInstalledByInstaller = $true }
        Invoke-Install
    } $sourceScript $profilePath

    $installer = New-LifecycleModule 'install.ps1'
    & $installer {
        param($Source, $Profile)
        $script:SourceScriptPath = $Source
        $script:ProfilePath = $Profile
        $script:SkipFfmpegInstallation = $true
        function script:Ensure-ExecutionPolicy {}
        Invoke-Install
        $state = Get-Content -LiteralPath $script:StatePath -Raw | ConvertFrom-Json
        if (-not $state.executionPolicy.changedByInstaller -or $state.executionPolicy.previousCurrentUser -ne 'Restricted' -or
            -not $state.ffmpeg.installedByInstaller -or -not $state.profile.profileWasCreatedByInstaller) {
            throw 'Repair discarded ownership metadata.'
        }
        $profileText = [IO.File]::ReadAllText($script:ProfilePath)
        if ([regex]::Matches($profileText, '# >>> ClipSqueeze >>>').Count -ne 1) {
            throw 'Repair duplicated the CRLF profile block.'
        }
    } $sourceScript $profilePath

    # Force the repair to replace the managed block, then fail after writing its new state.
    $profileText = [IO.File]::ReadAllText($profilePath).Replace('ClipSqueeze.ps1"', 'Previous.ps1"')
    [IO.File]::WriteAllText($profilePath, $profileText)
    $beforeRepair = Get-FileHash -LiteralPath $profilePath, $statePath, $installedScript, $configPath
    $installer = New-LifecycleModule 'install.ps1'
    & $installer {
        param($Source, $Profile)
        $script:SourceScriptPath = $Source
        $script:ProfilePath = $Profile
        $script:SkipFfmpegInstallation = $true
        function script:Ensure-ExecutionPolicy {}
        function script:Test-Installation { throw 'Simulated failed final installation check.' }
        try {
            Invoke-Install
            throw 'Repair unexpectedly succeeded.'
        }
        catch {
            if ($_.Exception.Message -ne 'Simulated failed final installation check.') { throw }
            Invoke-Rollback
        }
    } $sourceScript $profilePath
    foreach ($entry in $beforeRepair) {
        if ((Get-FileHash -LiteralPath $entry.Path).Hash -ne $entry.Hash) {
            throw "Repair rollback did not restore $($entry.Path)."
        }
    }

    [IO.File]::WriteAllText($configPath, '{"update":{"repository":"example/ClipSqueeze","assetName":"different.ps1","requireSignature":false,"trustedSignerThumbprint":"invalid"}}')
    $beforeUpdate = Get-FileHash -LiteralPath $installedScript, $statePath
    foreach ($failAfterSwap in @($true, $false)) {
        $updater = New-LifecycleModule 'update.ps1'
        & $updater {
            param($FailAfterSwap, $NextVersion)
            $script:Repository = ''
            $script:AssetName = ''
            $script:TrustedSignerSha256 = 'A' * 64
            $script:AllowUnsigned = $false
            $script:ForceLocalChanges = $false
            $script:FailAfterSwap = $FailAfterSwap
            $script:FixtureVersion = $NextVersion

            function script:Set-TlsSecurity {}
            function script:Show-UpdateNotification {}
            function script:Test-DownloadedScriptSignature {}
            function script:Get-LatestRelease {
                if ($script:RepositoryResolved -ne $script:OfficialRepository -or -not $script:RequireSignature -or
                    $script:ExpectedSignerSha256 -ne $script:TrustedSignerSha256) {
                    throw 'Editable configuration changed the official update policy.'
                }
                $script:LatestVersion = $script:FixtureVersion
                return @{ tag_name = "v$script:FixtureVersion" }
            }
            function script:Find-ReleaseAsset { return @{ name = 'ClipSqueeze.ps1' } }
            function script:Download-ReleaseAsset {
                Ensure-TempDirectory
                [IO.File]::WriteAllText($script:DownloadedPath, 'function Compress-Video { "updated" }')
                $script:NewHash = (Get-FileHash -LiteralPath $script:DownloadedPath).Hash.ToLowerInvariant()
            }
            function script:Read-Host { return 'ATUALIZAR' }
            function script:Write-UpdateLog {
                param([string]$Message)
                if ($script:FailAfterSwap -and $Message -like '*usando File.Replace*') {
                    throw 'Simulated failure immediately after replacing the script.'
                }
            }

            try {
                Invoke-Update
                if ($FailAfterSwap) { throw 'The post-swap failure was not triggered.' }
            }
            catch {
                if (-not $FailAfterSwap -or $_.Exception.Message -notlike '*Simulated failure immediately*' -or -not $script:RollbackNeeded) { throw }
                Restore-PreviousScript
                if ($script:RollbackNeeded) { throw 'The update rollback did not complete.' }
            }
            finally {
                Cleanup-TemporaryFiles
            }

            if (Test-Path -LiteralPath $script:BackupPath) { throw 'Update left a backup after a successful commit or rollback.' }
        } $failAfterSwap $nextVersion

        if ($failAfterSwap) {
            foreach ($entry in $beforeUpdate) {
                if ((Get-FileHash -LiteralPath $entry.Path).Hash -ne $entry.Hash) { throw "Update rollback changed $($entry.Path)." }
            }
        }
    }

    $updatedState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $updatedConfig = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    if ($updatedState.applicationVersion -ne $nextVersion.ToString() -or -not $updatedState.updatedAtUtc -or
        $updatedState.files.clipSqueezeSha256 -ne (Get-FileHash -LiteralPath $installedScript).Hash -or
        $updatedConfig.applicationVersion -ne $nextVersion.ToString()) {
        throw 'The first update did not record the new version and hash.'
    }

    $uninstaller = New-LifecycleModule 'uninstall.ps1'
    & $uninstaller {
        param($Profile, $ExpectedRoot)
        $standardVSCodeProfile = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Microsoft.VSCode_profile.ps1'
        $null = Assert-SafeProfilePath -ProfilePath $standardVSCodeProfile

        $script:FixtureProfile = $Profile
        $script:KeepFfmpeg = $false
        function script:Assert-SafeProfilePath {
            param([string]$ProfilePath)
            if ($ProfilePath -ne $script:FixtureProfile) { throw 'Unexpected profile in test fixture.' }
            return $ProfilePath
        }
        function script:Restore-ExecutionPolicy { $script:PolicyRestored = $true }
        function script:Read-Host {
            param([string]$Prompt)
            if ($Prompt -like '*DESINSTALAR*') { return 'DESINSTALAR' }
            return $script:Reply
        }
        $script:PolicyRestored = $false
        $beforeCancel = (Get-FileHash -LiteralPath $Profile).Hash
        function script:Get-WingetPath { return 'Invoke-TestWinget' }
        function script:Invoke-TestWinget { $global:LASTEXITCODE = $script:WingetExitCode }
        $script:WingetExitCode = 1
        foreach ($scenario in @(@{ Reply = 'cancel'; Error = '*inv*lida*' }, @{ Reply = 'r'; Error = '*WinGet falhou*' })) {
            $script:Reply = $scenario.Reply
            try {
                Invoke-Uninstall
                throw 'Uninstall accepted an invalid response or ignored a WinGet error.'
            }
            catch {
                if ($_.Exception.Message -notlike $scenario.Error) { throw }
            }
            if ($script:PolicyRestored -or (Get-FileHash -LiteralPath $Profile).Hash -ne $beforeCancel) {
                throw 'Uninstall changed the profile or policy before the FFmpeg decision succeeded.'
            }
        }

        $script:WingetExitCode = -1978335212
        $script:Reply = 'r'
        if ((Get-Item -LiteralPath $script:InstallRoot).FullName -ne $ExpectedRoot) { throw 'Unexpected uninstall directory.' }
        Invoke-Uninstall
        if (-not $script:PolicyRestored -or (Test-Path -LiteralPath $Profile) -or (Test-Path -LiteralPath $script:InstallRoot)) {
            throw 'Uninstall did not remove the installation and the managed CRLF block.'
        }
    } $profilePath $installRoot
    Write-Host 'Installation lifecycle checks passed.'
}
finally {
    $env:LOCALAPPDATA = $originalLocalAppData
    $env:TEMP = $originalTemp
    if ($null -eq $originalLastExitCode) {
        Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
    }
    else {
        $global:LASTEXITCODE = $originalLastExitCode
    }
    $resolved = (Get-Item -LiteralPath $fixture.FullName).FullName
    if ($resolved -eq $fixture.FullName -and [IO.Path]::GetDirectoryName($resolved) -eq [IO.Path]::GetTempPath().TrimEnd('\')) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
