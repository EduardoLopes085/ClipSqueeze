#requires -Version 5.1
<#!
.SYNOPSIS
    Instala e configura o ClipSqueeze para o usuário atual.

.DESCRIPTION
    Instalador seguro e idempotente do ClipSqueeze.

    Responsabilidades:
      - valida o ambiente do Windows PowerShell;
      - verifica a Execution Policy sem alterar políticas administrativas;
      - solicita explicitamente qualquer alteração em CurrentUser;
      - instala o ClipSqueeze em %LOCALAPPDATA%\ClipSqueeze;
      - cria um config.json inicial;
      - integra o ClipSqueeze ao $PROFILE do host atual;
      - instala/verifica FFmpeg via WinGet, quando necessário;
      - registra o estado da instalação para permitir desinstalação segura;
      - faz rollback das alterações realizadas em caso de falha.

.NOTES
    O instalador NÃO eleva privilégios automaticamente.
    Não usa Bypass/Unrestricted para contornar Execution Policy.
    Não altera MachinePolicy ou UserPolicy.
#>

[CmdletBinding()]
param(
    [switch]$NoExecutionPolicyChange,
    [switch]$SkipFfmpegInstallation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:InstallerVersion = '1.0.0'
$script:ApplicationVersion = '0.1.0'
$script:InstallRoot = Join-Path $env:LOCALAPPDATA 'ClipSqueeze'
$script:ConfigPath = Join-Path $script:InstallRoot 'config.json'
$script:StatePath = Join-Path $script:InstallRoot 'install-state.json'
$script:InstalledScriptPath = Join-Path $script:InstallRoot 'ClipSqueeze.ps1'
$script:LogDirectory = Join-Path $script:InstallRoot 'logs'
$script:TempLogPath = Join-Path $env:TEMP ("ClipSqueeze-Install-{0}.log" -f ([guid]::NewGuid().ToString('N')))
$script:SourceScriptPath = Join-Path $PSScriptRoot 'ClipSqueeze.ps1'
$script:ProfilePath = $PROFILE
$script:ProfileWasCreatedByInstaller = $false
$script:ProfileWasModifiedByInstaller = $false
$script:ExecutionPolicyChangedByInstaller = $false
$script:PreviousCurrentUserExecutionPolicy = $null
$script:FfmpegInstalledByInstaller = $false
$script:InstallStarted = $false
$script:InstallCompleted = $false
$script:ExistingManagedInstallation = $false
$script:BackupScriptPath = Join-Path $env:TEMP ("ClipSqueeze-Backup-{0}.ps1" -f ([guid]::NewGuid().ToString('N')))
$script:BackupConfigPath = Join-Path $env:TEMP ("ClipSqueeze-Backup-{0}.json" -f ([guid]::NewGuid().ToString('N')))

function Write-InstallLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = '[{0}] [{1}] {2}' -f $timestamp, $Level, $Message

    try {
        $parent = Split-Path -Path $script:TempLogPath -Parent
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        Add-Content -LiteralPath $script:TempLogPath -Value $line -Encoding UTF8
    }
    catch {
        # Log nunca deve impedir a instalação.
    }

    switch ($Level) {
        'OK'    { Write-Host "[OK] $Message" -ForegroundColor Green }
        'WARN'  { Write-Host "[AVISO] $Message" -ForegroundColor Yellow }
        'ERROR' { Write-Host "[ERRO] $Message" -ForegroundColor Red }
        default { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
    }
}

function Write-Section {
    param([Parameter(Mandatory = $true)][string]$Title)

    Write-Host ''
    Write-Host ('=' * 68) -ForegroundColor DarkGray
    Write-Host " $Title" -ForegroundColor White
    Write-Host ('=' * 68) -ForegroundColor DarkGray
}

function Test-RunningOnWindows {
    if ($env:OS -ne 'Windows_NT') {
        throw 'O ClipSqueeze Installer suporta somente Windows.'
    }
}

function Test-PowerShellVersion {
    $version = $PSVersionTable.PSVersion
    if ($version.Major -lt 5 -or ($version.Major -eq 5 -and $version.Minor -lt 1)) {
        throw "PowerShell 5.1 ou superior é necessário. Versão detectada: $version"
    }

    Write-InstallLog "PowerShell $version detectado." 'OK'
}

function Test-SourceScript {
    if (-not (Test-Path -LiteralPath $script:SourceScriptPath -PathType Leaf)) {
        throw "ClipSqueeze.ps1 não foi encontrado ao lado do instalador: $script:SourceScriptPath"
    }

    $item = Get-Item -LiteralPath $script:SourceScriptPath -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'O arquivo de origem ClipSqueeze.ps1 é um reparse point/symlink. Instalação abortada por segurança.'
    }

    if ($item.Length -le 0) {
        throw 'ClipSqueeze.ps1 está vazio. Instalação abortada.'
    }

    Write-InstallLog "Fonte validada: $script:SourceScriptPath" 'OK'
}

function Get-PolicySnapshot {
    $policies = Get-ExecutionPolicy -List

    $snapshot = [ordered]@{}
    foreach ($row in $policies) {
        $snapshot[$row.Scope.ToString()] = $row.ExecutionPolicy.ToString()
    }

    return [pscustomobject]$snapshot
}

function Get-PolicyValue {
    param([Parameter(Mandatory = $true)][string]$ScopeName)

    $policies = Get-ExecutionPolicy -List
    $row = $policies | Where-Object { $_.Scope.ToString() -eq $ScopeName } | Select-Object -First 1
    if ($null -eq $row) {
        return 'Undefined'
    }

    return $row.ExecutionPolicy.ToString()
}

function Ensure-ExecutionPolicy {
    Write-Section '1. Verificando Execution Policy'

    $snapshot = Get-PolicySnapshot
    Write-InstallLog ("Políticas: " + (($snapshot.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '))

    $machinePolicy = Get-PolicyValue -ScopeName 'MachinePolicy'
    $userPolicy = Get-PolicyValue -ScopeName 'UserPolicy'
    $currentUser = Get-PolicyValue -ScopeName 'CurrentUser'
    $effective = Get-ExecutionPolicy

    Write-InstallLog "Política efetiva: $effective"
    Write-InstallLog "CurrentUser: $currentUser"

    if ($effective -in @('RemoteSigned', 'Unrestricted', 'Bypass')) {
        Write-InstallLog "A política efetiva ($effective) permite a execução necessária. Nenhuma alteração será feita." 'OK'
        return
    }

    if ($NoExecutionPolicyChange) {
        throw "A Execution Policy efetiva ($effective) impede a execução normal do ClipSqueeze e a opção -NoExecutionPolicyChange foi usada."
    }

    if ($machinePolicy -ne 'Undefined' -or $userPolicy -ne 'Undefined') {
        throw "A Execution Policy é controlada por política administrativa (MachinePolicy/UserPolicy). O instalador não tentará contornar essa política. Política efetiva: $effective"
    }

    $question = @"
A Execution Policy atual é '$effective'.

Para integrar o ClipSqueeze ao PowerShell, o instalador precisa definir
CurrentUser como RemoteSigned. Isso afeta somente o seu usuário e não
altera MachinePolicy ou UserPolicy.

Deseja continuar e aplicar:
    Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
"@

    $answer = Read-Host "$question`nDigite S para continuar ou N para cancelar"
    if ($answer -notmatch '^(s|sim)$') {
        throw 'Instalação cancelada pelo usuário antes de alterar a Execution Policy.'
    }

    $script:PreviousCurrentUserExecutionPolicy = $currentUser

    Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
    $after = Get-ExecutionPolicy -Scope CurrentUser

    if ($after -ne 'RemoteSigned') {
        throw "Não foi possível definir CurrentUser como RemoteSigned. Valor atual: $after"
    }

    $script:ExecutionPolicyChangedByInstaller = $true
    Write-InstallLog 'CurrentUser definido como RemoteSigned.' 'OK'
}

function Get-DirectoryStatus {
    if (-not (Test-Path -LiteralPath $script:InstallRoot)) {
        return 'Missing'
    }

    $item = Get-Item -LiteralPath $script:InstallRoot -Force
    if (-not $item.PSIsContainer) {
        throw "O caminho de instalação já existe como arquivo: $script:InstallRoot"
    }

    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "O diretório de instalação é um reparse point/symlink. Operação abortada por segurança: $script:InstallRoot"
    }

    if (Test-Path -LiteralPath $script:StatePath -PathType Leaf) {
        return 'Managed'
    }

    $children = @(Get-ChildItem -LiteralPath $script:InstallRoot -Force -ErrorAction Stop)
    if ($children.Count -eq 0) {
        return 'Empty'
    }

    return 'Unknown'
}

function Assert-SafeInstallDirectory {
    Write-Section '2. Preparando diretório de instalação'

    $status = Get-DirectoryStatus

    switch ($status) {
        'Missing' {
            New-Item -ItemType Directory -Path $script:InstallRoot -Force | Out-Null
            Write-InstallLog "Diretório criado: $script:InstallRoot" 'OK'
        }
        'Empty' {
            Write-InstallLog "Diretório de instalação já existe e está vazio: $script:InstallRoot" 'OK'
        }
        'Managed' {
            $script:ExistingManagedInstallation = $true
            $raw = Get-Content -LiteralPath $script:StatePath -Raw -ErrorAction Stop
            $state = $raw | ConvertFrom-Json -ErrorAction Stop

            if ($state.InstallRoot -ne $script:InstallRoot) {
                throw 'O estado da instalação aponta para um diretório diferente. Operação abortada para evitar exclusão ou sobrescrita inesperada.'
            }

            Write-InstallLog 'Instalação existente do ClipSqueeze detectada. Será executado um reparo/atualização idempotente.' 'WARN'
        }
        'Unknown' {
            throw "O diretório $script:InstallRoot já contém arquivos que não pertencem a uma instalação reconhecida do ClipSqueeze. O instalador não irá sobrescrever nem apagar conteúdo desconhecido."
        }
    }
}

function Get-TextEncoding {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [IO.File]::ReadAllBytes($Path)

    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return New-Object System.Text.UTF8Encoding($true)
    }

    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        return New-Object System.Text.UnicodeEncoding($false, $true)
    }

    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        return New-Object System.Text.UnicodeEncoding($true, $true)
    }

    try {
        $utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
        [void]$utf8Strict.GetString($bytes)
        return $utf8Strict
    }
    catch {
        return [System.Text.Encoding]::Default
    }
}

function Write-TextPreservingEncoding {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content,
        [System.Text.Encoding]$Encoding
    )

    $directory = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $targetEncoding = if ($null -ne $Encoding) { $Encoding } else { New-Object System.Text.UTF8Encoding($false) }
    $tempPath = Join-Path $directory ('.clipsqueeze-profile-' + [guid]::NewGuid().ToString('N') + '.tmp')

    try {
        [IO.File]::WriteAllText($tempPath, $Content, $targetEncoding)

        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            try {
                [IO.File]::Replace($tempPath, $Path, $null)
            }
            catch {
                Move-Item -LiteralPath $tempPath -Destination $Path -Force
            }
        }
        else {
            Move-Item -LiteralPath $tempPath -Destination $Path -Force
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-ClipSqueezeProfileBlock {
    return @(
        '# >>> ClipSqueeze >>>',
        '. "$env:LOCALAPPDATA\ClipSqueeze\ClipSqueeze.ps1"',
        '# <<< ClipSqueeze <<<'
    ) -join "`r`n"
}

function Backup-ExistingInstallationFiles {
    if (-not $script:ExistingManagedInstallation) {
        return
    }

    if (Test-Path -LiteralPath $script:InstalledScriptPath -PathType Leaf) {
        Copy-Item -LiteralPath $script:InstalledScriptPath -Destination $script:BackupScriptPath -Force
        Write-InstallLog 'Backup temporário do ClipSqueeze.ps1 existente criado para permitir rollback.'
    }

    if (Test-Path -LiteralPath $script:ConfigPath -PathType Leaf) {
        Copy-Item -LiteralPath $script:ConfigPath -Destination $script:BackupConfigPath -Force
        Write-InstallLog 'Backup temporário do config.json existente criado para permitir rollback.'
    }
}

function Restore-ExistingInstallationFiles {
    if (-not $script:ExistingManagedInstallation) {
        return
    }

    try {
        if (Test-Path -LiteralPath $script:BackupScriptPath -PathType Leaf) {
            Copy-Item -LiteralPath $script:BackupScriptPath -Destination $script:InstalledScriptPath -Force
            Write-InstallLog 'ClipSqueeze.ps1 existente restaurado após falha.' 'OK'
        }

        if (Test-Path -LiteralPath $script:BackupConfigPath -PathType Leaf) {
            Copy-Item -LiteralPath $script:BackupConfigPath -Destination $script:ConfigPath -Force
            Write-InstallLog 'config.json existente restaurado após falha.' 'OK'
        }
    }
    catch {
        Write-InstallLog "Falha ao restaurar arquivos da instalação anterior: $($_.Exception.Message)" 'ERROR'
    }
}

function Remove-TemporaryBackups {
    Remove-Item -LiteralPath $script:BackupScriptPath, $script:BackupConfigPath -Force -ErrorAction SilentlyContinue
}

function Update-PowerShellProfile {
    Write-Section '3. Configurando PowerShell Profile'

    if ([string]::IsNullOrWhiteSpace($script:ProfilePath)) {
        throw 'Não foi possível determinar o caminho de $PROFILE.'
    }

    $profileDirectory = Split-Path -Path $script:ProfilePath -Parent
    if (-not (Test-Path -LiteralPath $profileDirectory)) {
        New-Item -ItemType Directory -Path $profileDirectory -Force | Out-Null
    }

    $profileExisted = Test-Path -LiteralPath $script:ProfilePath -PathType Leaf
    $content = if ($profileExisted) { Get-Content -LiteralPath $script:ProfilePath -Raw } else { '' }
    $encoding = if ($profileExisted) { Get-TextEncoding -Path $script:ProfilePath } else { New-Object System.Text.UTF8Encoding($false) }

    $block = Get-ClipSqueezeProfileBlock
    $pattern = '(?ms)^# >>> ClipSqueeze >>>\r?\n.*?\r?\n# <<< ClipSqueeze <<<$'

    if ($content -match $pattern) {
        $newContent = [regex]::Replace($content, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $block })
    }
    else {
        $separator = if ([string]::IsNullOrWhiteSpace($content)) { '' } elseif ($content.EndsWith("`r`n")) { '' } elseif ($content.EndsWith("`n")) { "`r" } else { "`r`n" }
        $newContent = $content + $separator + $block + "`r`n"
    }

    if ($newContent -ne $content) {
        Write-TextPreservingEncoding -Path $script:ProfilePath -Content $newContent -Encoding $encoding
        $script:ProfileWasModifiedByInstaller = $true
        $script:ProfileWasCreatedByInstaller = -not $profileExisted
        Write-InstallLog "Profile configurado: $script:ProfilePath" 'OK'
    }
    else {
        Write-InstallLog "Profile já estava configurado corretamente: $script:ProfilePath" 'OK'
    }
}

function Get-DefaultConfigObject {
    return [ordered]@{
        schemaVersion = 1
        applicationVersion = $script:ApplicationVersion
        defaults = [ordered]@{
            accelerator = 'cpu'
            profile = 'balanced'
            container = 'mp4'
            codec = 'hevc'
            resolution = $null
        }
        output = [ordered]@{
            suffix = '_comprimido'
            overwrite = $false
        }
        ffmpeg = [ordered]@{
            packageId = 'Gyan.FFmpeg'
        }
        notifications = [ordered]@{
            enabled = $true
        }
    }
}

function Initialize-Config {
    Write-Section '4. Criando configuração'

    if (Test-Path -LiteralPath $script:ConfigPath -PathType Leaf) {
        try {
            $existing = Get-Content -LiteralPath $script:ConfigPath -Raw | ConvertFrom-Json -ErrorAction Stop
            if ($null -eq $existing) { throw 'config.json vazio.' }
            Write-InstallLog 'config.json já existe e será preservado.' 'OK'
            return
        }
        catch {
            throw "config.json existente é inválido. O instalador não irá sobrescrevê-lo automaticamente por segurança. Erro: $($_.Exception.Message)"
        }
    }

    $config = Get-DefaultConfigObject
    $json = $config | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText($script:ConfigPath, $json + "`r`n", (New-Object System.Text.UTF8Encoding($false)))

    Write-InstallLog "config.json criado: $script:ConfigPath" 'OK'
}

function Get-CommandPathSafe {
    param([Parameter(Mandatory = $true)][string]$Name)

    try {
        $cmd = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $cmd) { return $null }
        return $cmd.Source
    }
    catch {
        return $null
    }
}

function Refresh-ProcessPath {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $script:OldPath = $env:Path
    $env:Path = ((@($machinePath, $userPath) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ';')
}

function Get-WingetPath {
    return Get-CommandPathSafe -Name 'winget.exe'
}

function Get-WingetPackagePresence {
    param([Parameter(Mandatory = $true)][string]$PackageId)

    $winget = Get-WingetPath
    if (-not $winget) { return $false }

    try {
        $output = & $winget list --id $PackageId -e --accept-source-agreements 2>&1 | Out-String
        return ($output -match [regex]::Escape($PackageId))
    }
    catch {
        return $false
    }
}

function Get-FfmpegStatus {
    $ffmpeg = Get-CommandPathSafe -Name 'ffmpeg.exe'
    $ffprobe = Get-CommandPathSafe -Name 'ffprobe.exe'

    return [pscustomobject]@{
        Ffmpeg = $ffmpeg
        Ffprobe = $ffprobe
        Ready = ($null -ne $ffmpeg -and $null -ne $ffprobe)
    }
}

function Install-FfmpegIfNeeded {
    Write-Section '5. Verificando FFmpeg'

    if ($SkipFfmpegInstallation) {
        Write-InstallLog 'Instalação do FFmpeg foi explicitamente ignorada por -SkipFfmpegInstallation.' 'WARN'
        return
    }

    $status = Get-FfmpegStatus
    if ($status.Ready) {
        Write-InstallLog "FFmpeg encontrado: $($status.Ffmpeg)" 'OK'
        Write-InstallLog "FFprobe encontrado: $($status.Ffprobe)" 'OK'
        return
    }

    $missing = @()
    if (-not $status.Ffmpeg) { $missing += 'ffmpeg' }
    if (-not $status.Ffprobe) { $missing += 'ffprobe' }
    Write-InstallLog ("Componentes ausentes: " + ($missing -join ', ')) 'WARN'

    $winget = Get-WingetPath
    if (-not $winget) {
        throw 'FFmpeg/FFprobe não estão disponíveis e o WinGet não foi encontrado. Instale o App Installer/WinGet ou disponibilize o FFmpeg antes de executar novamente.'
    }

    $packageId = 'Gyan.FFmpeg'
    $alreadyInstalled = Get-WingetPackagePresence -PackageId $packageId

    if ($alreadyInstalled) {
        Refresh-ProcessPath
        $statusAfterRefresh = Get-FfmpegStatus
        if ($statusAfterRefresh.Ready) {
            Write-InstallLog 'O pacote Gyan.FFmpeg já está instalado e agora está disponível no PATH.' 'OK'
            return
        }

        throw 'O pacote Gyan.FFmpeg parece estar instalado pelo WinGet, mas ffmpeg/ffprobe não estão acessíveis no PATH desta sessão. O instalador não irá reinstalar o pacote automaticamente.'
    }

    Write-Host ''
    Write-Host 'O FFmpeg será instalado pelo WinGet usando o pacote:' -ForegroundColor White
    Write-Host "  $packageId" -ForegroundColor Cyan
    Write-Host 'O WinGet poderá solicitar elevação/UAC ou outras confirmações do próprio instalador.' -ForegroundColor Yellow
    Write-Host 'O ClipSqueeze não fará elevação silenciosa.' -ForegroundColor Yellow

    $answer = Read-Host 'Digite S para instalar o FFmpeg ou N para cancelar'
    if ($answer -notmatch '^(s|sim)$') {
        throw 'Instalação cancelada porque o usuário não autorizou a instalação do FFmpeg.'
    }

    try {
        & $winget show --id $packageId -e --accept-source-agreements | Out-Host
    }
    catch {
        throw "Não foi possível consultar o pacote $packageId no WinGet: $($_.Exception.Message)"
    }

    Write-InstallLog "Instalando $packageId via WinGet..."

    & $winget install --id $packageId -e --accept-source-agreements --accept-package-agreements
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "WinGet falhou ao instalar $packageId. Código de saída: $exitCode"
    }

    $script:FfmpegInstalledByInstaller = $true
    Refresh-ProcessPath

    Start-Sleep -Milliseconds 750
    $statusAfterInstall = Get-FfmpegStatus
    if (-not $statusAfterInstall.Ready) {
        throw 'O WinGet informou sucesso, mas ffmpeg/ffprobe continuam indisponíveis nesta sessão. Abra uma nova sessão do PowerShell e execute o instalador novamente antes de usar o ClipSqueeze.'
    }

    Write-InstallLog "FFmpeg instalado: $($statusAfterInstall.Ffmpeg)" 'OK'
    Write-InstallLog "FFprobe instalado: $($statusAfterInstall.Ffprobe)" 'OK'
}

function Test-EncoderAvailability {
    param(
        [Parameter(Mandatory = $true)][string]$Encoder
    )

    $ffmpeg = Get-CommandPathSafe -Name 'ffmpeg.exe'
    if (-not $ffmpeg) { return $false }

    try {
        $output = & $ffmpeg -hide_banner -encoders 2>$null | Out-String
        return ($output -match [regex]::Escape($Encoder))
    }
    catch {
        return $false
    }
}

function Invoke-FfmpegDiagnostics {
    Write-Section '6. Diagnóstico do FFmpeg e encoders'

    if ($SkipFfmpegInstallation) {
        Write-InstallLog 'Diagnóstico completo do FFmpeg foi ignorado porque -SkipFfmpegInstallation foi usado.' 'WARN'
        return
    }

    $status = Get-FfmpegStatus
    if (-not $status.Ready) {
        throw 'FFmpeg/FFprobe continuam indisponíveis após a instalação.'
    }

    try {
        $versionOutput = & $status.Ffmpeg -hide_banner -version 2>&1 | Select-Object -First 1
        Write-InstallLog "FFmpeg: $versionOutput" 'OK'
    }
    catch {
        throw "Não foi possível executar ffmpeg -version: $($_.Exception.Message)"
    }

    $encoders = @(
        'hevc_amf', 'h264_amf', 'av1_amf',
        'hevc_nvenc', 'h264_nvenc', 'av1_nvenc'
    )

    foreach ($encoder in $encoders) {
        if (Test-EncoderAvailability -Encoder $encoder) {
            Write-InstallLog "$encoder disponível." 'OK'
        }
        else {
            Write-InstallLog "$encoder não disponível neste sistema/FFmpeg. Isso não é necessariamente um erro." 'WARN'
        }
    }
}

function New-InstallationState {
    $hash = (Get-FileHash -LiteralPath $script:InstalledScriptPath -Algorithm SHA256).Hash

    return [ordered]@{
        schemaVersion = 1
        installerVersion = $script:InstallerVersion
        applicationVersion = $script:ApplicationVersion
        installedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        installRoot = $script:InstallRoot
        mainScript = $script:InstalledScriptPath
        configPath = $script:ConfigPath
        profile = [ordered]@{
            path = $script:ProfilePath
            blockManaged = $true
            profileWasCreatedByInstaller = $script:ProfileWasCreatedByInstaller
        }
        executionPolicy = [ordered]@{
            changedByInstaller = $script:ExecutionPolicyChangedByInstaller
            previousCurrentUser = $script:PreviousCurrentUserExecutionPolicy
            installerValue = if ($script:ExecutionPolicyChangedByInstaller) { 'RemoteSigned' } else { $null }
        }
        ffmpeg = [ordered]@{
            packageId = 'Gyan.FFmpeg'
            installedByInstaller = $script:FfmpegInstalledByInstaller
        }
        files = [ordered]@{
            clipSqueezeSha256 = $hash
        }
    }
}

function Save-InstallationState {
    Write-Section '7. Registrando estado da instalação'

    $state = New-InstallationState
    $json = $state | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText($script:StatePath, $json + "`r`n", (New-Object System.Text.UTF8Encoding($false)))

    if (-not (Test-Path -LiteralPath $script:StatePath -PathType Leaf)) {
        throw 'Não foi possível gravar install-state.json.'
    }

    New-Item -ItemType Directory -Path $script:LogDirectory -Force | Out-Null
    Write-InstallLog 'Estado da instalação registrado.' 'OK'
}

function Test-Installation {
    Write-Section '8. Validação final'

    if (-not (Test-Path -LiteralPath $script:InstalledScriptPath -PathType Leaf)) {
        throw 'ClipSqueeze.ps1 não foi encontrado no diretório instalado.'
    }

    if (-not (Test-Path -LiteralPath $script:ConfigPath -PathType Leaf)) {
        throw 'config.json não foi encontrado.'
    }

    if (-not (Test-Path -LiteralPath $script:StatePath -PathType Leaf)) {
        throw 'install-state.json não foi encontrado.'
    }

    if (-not (Test-Path -LiteralPath $script:ProfilePath -PathType Leaf)) {
        throw 'Profile não existe após a instalação.'
    }

    $profileContent = Get-Content -LiteralPath $script:ProfilePath -Raw
    if ($profileContent -notmatch '(?ms)^# >>> ClipSqueeze >>>\r?\n.*?\r?\n# <<< ClipSqueeze <<<$') {
        throw 'Bloco do ClipSqueeze não foi encontrado no Profile.'
    }

    if (-not $SkipFfmpegInstallation) {
        $status = Get-FfmpegStatus
        if (-not $status.Ready) {
            throw 'Validação final falhou: ffmpeg/ffprobe não estão disponíveis.'
        }
    }

    Write-InstallLog 'Arquivos do ClipSqueeze presentes.' 'OK'
    Write-InstallLog 'config.json válido/presente.' 'OK'
    Write-InstallLog 'Profile contém a integração do ClipSqueeze.' 'OK'
    Write-InstallLog 'Validação final concluída.' 'OK'
}

function Invoke-Rollback {
    Write-Section 'Rollback de segurança'
    Write-InstallLog 'Uma etapa falhou. Tentando desfazer somente as alterações feitas pelo instalador.' 'WARN'

    try {
        if ($script:ProfileWasModifiedByInstaller -and (Test-Path -LiteralPath $script:ProfilePath -PathType Leaf)) {
            $content = Get-Content -LiteralPath $script:ProfilePath -Raw
            $pattern = '(?ms)^# >>> ClipSqueeze >>>\r?\n.*?\r?\n# <<< ClipSqueeze <<<$'
            $newContent = [regex]::Replace($content, $pattern, '')
            $newContent = $newContent -replace '(?m)\r?\n\r?\n\r?\n+$', "`r`n"

            if ($script:ProfileWasCreatedByInstaller -and [string]::IsNullOrWhiteSpace($newContent)) {
                Remove-Item -LiteralPath $script:ProfilePath -Force -ErrorAction SilentlyContinue
                $profileDirectory = Split-Path -Path $script:ProfilePath -Parent
                if (Test-Path -LiteralPath $profileDirectory) {
                    $entries = @(Get-ChildItem -LiteralPath $profileDirectory -Force -ErrorAction SilentlyContinue)
                    if ($entries.Count -eq 0) {
                        Remove-Item -LiteralPath $profileDirectory -Force -ErrorAction SilentlyContinue
                    }
                }
            }
            else {
                Write-TextPreservingEncoding -Path $script:ProfilePath -Content $newContent -Encoding (Get-TextEncoding -Path $script:ProfilePath)
            }

            Write-InstallLog 'Integração do Profile revertida.' 'OK'
        }
    }
    catch {
        Write-InstallLog "Falha ao reverter o Profile: $($_.Exception.Message)" 'ERROR'
    }

    try {
        if ($script:ExecutionPolicyChangedByInstaller -and $null -ne $script:PreviousCurrentUserExecutionPolicy) {
            $current = Get-ExecutionPolicy -Scope CurrentUser
            if ($current -eq 'RemoteSigned') {
                Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy $script:PreviousCurrentUserExecutionPolicy -Force
                Write-InstallLog "Execution Policy restaurada para CurrentUser=$script:PreviousCurrentUserExecutionPolicy." 'OK'
            }
            else {
                Write-InstallLog "Execution Policy não foi restaurada automaticamente porque o valor atual de CurrentUser mudou para '$current' depois da alteração do instalador." 'WARN'
            }
        }
    }
    catch {
        Write-InstallLog "Falha ao restaurar Execution Policy: $($_.Exception.Message)" 'ERROR'
    }

    if ($script:FfmpegInstalledByInstaller) {
        Write-InstallLog 'FFmpeg foi instalado pelo instalador antes da falha. O rollback tentará removê-lo para não deixar uma dependência parcialmente instalada.' 'WARN'
        try {
            $winget = Get-WingetPath
            if ($winget) {
                & $winget uninstall --id Gyan.FFmpeg -e --accept-source-agreements
                if ($LASTEXITCODE -eq 0) {
                    Write-InstallLog 'FFmpeg removido durante rollback.' 'OK'
                }
                else {
                    Write-InstallLog "Não foi possível remover FFmpeg durante rollback. Código: $LASTEXITCODE" 'ERROR'
                }
            }
        }
        catch {
            Write-InstallLog "Falha ao remover FFmpeg durante rollback: $($_.Exception.Message)" 'ERROR'
        }
    }

    if ($script:ExistingManagedInstallation) {
        Restore-ExistingInstallationFiles
        Remove-TemporaryBackups
        return
    }

    try {
        if (Test-Path -LiteralPath $script:InstallRoot) {
            $item = Get-Item -LiteralPath $script:InstallRoot -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
                Remove-Item -LiteralPath $script:InstallRoot -Recurse -Force -ErrorAction Stop
                Write-InstallLog 'Diretório do ClipSqueeze removido durante rollback.' 'OK'
            }
        }
    }
    catch {
        Write-InstallLog "Falha ao remover diretório durante rollback: $($_.Exception.Message)" 'ERROR'
    }
}

function Invoke-Install {
    Write-Host ''
    Write-Host 'ClipSqueeze — Installer' -ForegroundColor White
    Write-Host "Versão do instalador: $script:InstallerVersion" -ForegroundColor DarkGray
    Write-Host "Destino: $script:InstallRoot" -ForegroundColor DarkGray

    Test-RunningOnWindows
    Test-PowerShellVersion
    Test-SourceScript

    $script:InstallStarted = $true

    Ensure-ExecutionPolicy
    Assert-SafeInstallDirectory
    Backup-ExistingInstallationFiles

    Copy-Item -LiteralPath $script:SourceScriptPath -Destination $script:InstalledScriptPath -Force
    Write-InstallLog "ClipSqueeze.ps1 instalado em $script:InstalledScriptPath" 'OK'

    Update-PowerShellProfile
    Initialize-Config
    Install-FfmpegIfNeeded
    Invoke-FfmpegDiagnostics

    New-Item -ItemType Directory -Path $script:LogDirectory -Force | Out-Null
    Save-InstallationState
    Test-Installation

    if (Test-Path -LiteralPath $script:TempLogPath) {
        Copy-Item -LiteralPath $script:TempLogPath -Destination (Join-Path $script:LogDirectory 'install.log') -Force
        Remove-Item -LiteralPath $script:TempLogPath -Force -ErrorAction SilentlyContinue
    }

    Remove-TemporaryBackups
    $script:InstallCompleted = $true

    Write-Host ''
    Write-Host ('=' * 68) -ForegroundColor Green
    Write-Host ' INSTALAÇÃO CONCLUÍDA' -ForegroundColor Green
    Write-Host ('=' * 68) -ForegroundColor Green
    Write-Host ''
    Write-Host "Instalação: $script:InstallRoot"
    Write-Host "Profile:     $script:ProfilePath"
    Write-Host ''
    Write-Host 'Abra uma nova janela do PowerShell para carregar o ClipSqueeze.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'Exemplo:' -ForegroundColor White
    Write-Host '  comprimir cpu "video.mp4"' -ForegroundColor Cyan
    Write-Host ''
}

try {
    Invoke-Install
}
catch {
    Write-Host ''
    Write-InstallLog $_.Exception.Message 'ERROR'
    if ($script:InstallStarted -and -not $script:InstallCompleted) {
        Invoke-Rollback
    }

    Write-Host ''
    Write-Host 'A instalação foi abortada.' -ForegroundColor Red
    if (Test-Path -LiteralPath $script:TempLogPath) {
        Write-Host "Log de diagnóstico: $script:TempLogPath" -ForegroundColor Yellow
    }

    exit 1
}
finally {
    if (Test-Path -LiteralPath $script:TempLogPath -and $script:InstallCompleted) {
        Remove-Item -LiteralPath $script:TempLogPath -Force -ErrorAction SilentlyContinue
    }
}
