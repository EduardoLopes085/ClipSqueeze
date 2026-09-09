#requires -Version 5.1
<#!
.SYNOPSIS
    Remove completamente a instalação do ClipSqueeze pertencente ao usuário atual.

.DESCRIPTION
    Desinstalador seguro e conservador.

    Responsabilidades:
      - valida a instalação por meio do install-state.json;
      - não remove diretórios arbitrários ou instalações não reconhecidas;
      - remove apenas o bloco de integração do ClipSqueeze do $PROFILE registrado;
      - restaura CurrentUser Execution Policy somente se ela ainda estiver no
        valor aplicado pelo instalador;
      - remove o FFmpeg somente quando o instalador registrou que ele foi
        instalado pelo ClipSqueeze;
      - remove o diretório inteiro da aplicação depois das verificações;
      - não executa elevação automática.
#>

[CmdletBinding()]
param(
    [switch]$KeepFfmpeg
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:InstallRoot = Join-Path $env:LOCALAPPDATA 'ClipSqueeze'
$script:StatePath = Join-Path $script:InstallRoot 'install-state.json'
$script:TempLogPath = Join-Path $env:TEMP ("ClipSqueeze-Uninstall-{0}.log" -f ([guid]::NewGuid().ToString('N')))
$script:State = $null

function Write-UninstallLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = '[{0}] [{1}] {2}' -f $timestamp, $Level, $Message

    try {
        Add-Content -LiteralPath $script:TempLogPath -Value $line -Encoding UTF8
    }
    catch {
    }

    switch ($Level) {
        'OK'    { Write-Host "[OK] $Message" -ForegroundColor Green }
        'WARN'  { Write-Host "[AVISO] $Message" -ForegroundColor Yellow }
        'ERROR' { Write-Host "[ERRO] $Message" -ForegroundColor Red }
        default { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
    }
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
    $env:Path = ((@($machinePath, $userPath) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ';')
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
    $targetEncoding = if ($null -ne $Encoding) { $Encoding } else { New-Object System.Text.UTF8Encoding($false) }
    $tempPath = Join-Path $directory ('.clipsqueeze-uninstall-' + [guid]::NewGuid().ToString('N') + '.tmp')

    try {
        [IO.File]::WriteAllText($tempPath, $Content, $targetEncoding)

        try {
            [IO.File]::Replace($tempPath, $Path, $null)
        }
        catch {
            Move-Item -LiteralPath $tempPath -Destination $Path -Force
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Assert-Environment {
    if ($env:OS -ne 'Windows_NT') {
        throw 'O ClipSqueeze Uninstaller suporta somente Windows.'
    }

    $version = $PSVersionTable.PSVersion
    if ($version.Major -lt 5 -or ($version.Major -eq 5 -and $version.Minor -lt 1)) {
        throw "PowerShell 5.1 ou superior é necessário. Versão detectada: $version"
    }
}

function Assert-SafeInstallRoot {
    if (-not (Test-Path -LiteralPath $script:InstallRoot)) {
        throw "Instalação não encontrada em: $script:InstallRoot"
    }

    $item = Get-Item -LiteralPath $script:InstallRoot -Force
    if (-not $item.PSIsContainer) {
        throw "O caminho esperado da instalação não é um diretório. Operação abortada: $script:InstallRoot"
    }

    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'O diretório de instalação é um reparse point/symlink. O desinstalador não irá removê-lo.'
    }

    if (-not (Test-Path -LiteralPath $script:StatePath -PathType Leaf)) {
        throw "install-state.json não foi encontrado. O desinstalador não removerá um diretório não reconhecido automaticamente: $script:InstallRoot"
    }
}

function Read-InstallationState {
    $raw = Get-Content -LiteralPath $script:StatePath -Raw -ErrorAction Stop
    $state = $raw | ConvertFrom-Json -ErrorAction Stop

    foreach ($property in @('installRoot', 'mainScript', 'profile', 'executionPolicy', 'ffmpeg')) {
        if ($null -eq $state.$property) {
            throw "install-state.json não contém a propriedade obrigatória '$property'."
        }
    }

    if ($state.installRoot -ne $script:InstallRoot) {
        throw 'O estado da instalação aponta para outro diretório. Operação abortada por segurança.'
    }

    if ([string]$state.ffmpeg.packageId -ne 'Gyan.FFmpeg') {
        throw 'O estado da instalação contém um pacote FFmpeg não reconhecido. Operação abortada.'
    }

    if ([bool]$state.executionPolicy.changedByInstaller) {
        $validValues = @('Undefined', 'Restricted', 'AllSigned', 'RemoteSigned', 'Unrestricted', 'Bypass')
        if ([string]$state.executionPolicy.installerValue -ne 'RemoteSigned') {
            throw 'O estado da instalação contém um valor de Execution Policy do instalador não reconhecido.'
        }
        if ($validValues -notcontains [string]$state.executionPolicy.previousCurrentUser) {
            throw 'O estado da instalação contém uma Execution Policy anterior inválida.'
        }
    }

    [void](Assert-SafeProfilePath -ProfilePath ([string]$state.profile.path))

    return $state
}

function Get-ClipSqueezeProfileBlockPattern {
    return '(?ms)^# >>> ClipSqueeze >>>\r?\n.*?\r?\n# <<< ClipSqueeze <<<$'
}


function Assert-SafeProfilePath {
    param([Parameter(Mandatory = $true)][string]$ProfilePath)

    if (-not [IO.Path]::IsPathRooted($ProfilePath)) {
        throw 'O caminho do Profile registrado não é absoluto.'
    }

    $fullPath = [IO.Path]::GetFullPath($ProfilePath)
    $documents = [Environment]::GetFolderPath('MyDocuments')
    $allowedRoots = @(
        [IO.Path]::GetFullPath((Join-Path $documents 'WindowsPowerShell')),
        [IO.Path]::GetFullPath((Join-Path $documents 'PowerShell'))
    )

    $rootAllowed = $false
    foreach ($root in $allowedRoots) {
        if ($fullPath.StartsWith($root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or
            $fullPath.Equals($root, [StringComparison]::OrdinalIgnoreCase)) {
            $rootAllowed = $true
            break
        }
    }

    if (-not $rootAllowed) {
        throw "O Profile registrado está fora dos diretórios esperados do usuário: $fullPath"
    }

    $leaf = [IO.Path]::GetFileName($fullPath)
    if ($leaf -notin @('Profile.ps1', 'Microsoft.PowerShell_profile.ps1')) {
        throw "O nome do Profile registrado não é reconhecido como um Profile padrão do PowerShell: $leaf"
    }

    if (Test-Path -LiteralPath $fullPath) {
        $item = Get-Item -LiteralPath $fullPath -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'O Profile registrado é um reparse point/symlink. O desinstalador não irá modificá-lo.'
        }
    }

    return $fullPath
}

function Remove-ProfileIntegration {
    $profilePath = Assert-SafeProfilePath -ProfilePath ([string]$script:State.profile.path)

    if ([string]::IsNullOrWhiteSpace($profilePath)) {
        Write-UninstallLog 'Nenhum Profile foi registrado na instalação. Pulando esta etapa.' 'WARN'
        return
    }

    if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
        Write-UninstallLog "Profile registrado não existe mais: $profilePath" 'WARN'
        return
    }

    $content = Get-Content -LiteralPath $profilePath -Raw
    $encoding = Get-TextEncoding -Path $profilePath
    $pattern = Get-ClipSqueezeProfileBlockPattern

    if ($content -notmatch $pattern) {
        $loadLinePattern = '(?m)^\s*\.\s*"\$env:LOCALAPPDATA\\ClipSqueeze\\ClipSqueeze\.ps1"\s*$'
        if ($content -match $loadLinePattern) {
            Write-UninstallLog 'Marcadores do bloco não foram encontrados, mas a linha de carregamento conhecida foi encontrada. Ela será removida isoladamente.' 'WARN'
            $newContent = [regex]::Replace($content, $loadLinePattern, '')
        }
        else {
            Write-UninstallLog 'Nenhuma integração do ClipSqueeze foi encontrada no Profile. Nada será removido.' 'OK'
            return
        }
    }
    else {
        $newContent = [regex]::Replace($content, $pattern, '')
    }

    $newContent = $newContent -replace '(?m)\r?\n\r?\n\r?\n+$', "`r`n"

    $createdByInstaller = [bool]$script:State.profile.profileWasCreatedByInstaller
    if ($createdByInstaller -and [string]::IsNullOrWhiteSpace($newContent)) {
        Remove-Item -LiteralPath $profilePath -Force
        Write-UninstallLog "Profile criado pelo instalador e agora vazio: arquivo removido ($profilePath)." 'OK'

        $profileDirectory = Split-Path -Path $profilePath -Parent
        if (Test-Path -LiteralPath $profileDirectory) {
            $entries = @(Get-ChildItem -LiteralPath $profileDirectory -Force -ErrorAction SilentlyContinue)
            if ($entries.Count -eq 0) {
                Remove-Item -LiteralPath $profileDirectory -Force -ErrorAction SilentlyContinue
                Write-UninstallLog "Diretório de Profile criado pelo instalador e vazio removido: $profileDirectory" 'OK'
            }
        }
    }
    else {
        Write-TextPreservingEncoding -Path $profilePath -Content $newContent -Encoding $encoding
        Write-UninstallLog "Integração removida do Profile: $profilePath" 'OK'
    }
}

function Restore-ExecutionPolicy {
    $changedByInstaller = [bool]$script:State.executionPolicy.changedByInstaller
    if (-not $changedByInstaller) {
        Write-UninstallLog 'O instalador não alterou CurrentUser Execution Policy. Nenhuma restauração será feita.' 'OK'
        return
    }

    $expectedInstallerValue = [string]$script:State.executionPolicy.installerValue
    $previous = [string]$script:State.executionPolicy.previousCurrentUser
    $current = Get-ExecutionPolicy -Scope CurrentUser

    if ($current -ne $expectedInstallerValue) {
        Write-UninstallLog "CurrentUser Execution Policy foi alterada depois da instalação (atual: $current). Ela NÃO será sobrescrita durante a desinstalação." 'WARN'
        return
    }

    $validValues = @('Undefined', 'Restricted', 'AllSigned', 'RemoteSigned', 'Unrestricted', 'Bypass')
    if ($validValues -notcontains $previous) {
        throw "O estado registrou uma Execution Policy anterior inválida: '$previous'"
    }

    Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy $previous -Force
    $after = Get-ExecutionPolicy -Scope CurrentUser

    if ($after -ne $previous) {
        throw "Não foi possível restaurar CurrentUser Execution Policy para '$previous'. Valor atual: '$after'"
    }

    Write-UninstallLog "CurrentUser Execution Policy restaurada para '$previous'." 'OK'
}

function Get-WingetPath {
    return Get-CommandPathSafe -Name 'winget.exe'
}

function Remove-FfmpegIfOwned {
    $owned = [bool]$script:State.ffmpeg.installedByInstaller
    $packageId = [string]$script:State.ffmpeg.packageId

    if (-not $owned) {
        Write-UninstallLog 'FFmpeg não foi instalado pelo ClipSqueeze. O desinstalador não irá tocá-lo.' 'OK'
        return
    }

    if ($KeepFfmpeg) {
        Write-UninstallLog 'FFmpeg foi instalado pelo ClipSqueeze, mas -KeepFfmpeg foi solicitado. O pacote será mantido.' 'WARN'
        return
    }

    Write-Host ''
    Write-Host 'O registro da instalação indica que o ClipSqueeze instalou o FFmpeg via WinGet.' -ForegroundColor Yellow
    Write-Host "Pacote: $packageId" -ForegroundColor White
    Write-Host 'O pacote será removido também, a menos que você escolha mantê-lo.' -ForegroundColor Yellow

    $answer = Read-Host 'Digite R para remover o FFmpeg também ou M para mantê-lo'
    if ($answer -match '^(m|manter)$') {
        Write-UninstallLog 'Usuário escolheu manter o FFmpeg.' 'WARN'
        return
    }

    if ($answer -notmatch '^(r|remover)$') {
        throw 'Resposta inválida. Desinstalação cancelada para evitar remoção acidental do FFmpeg.'
    }

    $winget = Get-WingetPath
    if (-not $winget) {
        throw 'WinGet não está disponível. O desinstalador não consegue remover com segurança o FFmpeg registrado como dependência.'
    }

    Write-UninstallLog "Removendo $packageId via WinGet..."
    & $winget uninstall --id $packageId -e --accept-source-agreements
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        throw "WinGet falhou ao remover $packageId. Código de saída: $exitCode"
    }

    Refresh-ProcessPath
    Write-UninstallLog 'FFmpeg removido via WinGet.' 'OK'
}

function Test-RootForReparsePoints {
    $entries = @(Get-ChildItem -LiteralPath $script:InstallRoot -Force -Recurse -ErrorAction Stop)
    foreach ($entry in $entries) {
        if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Foi encontrado um reparse point dentro da instalação: $($entry.FullName). O desinstalador não irá seguir ou remover uma árvore potencialmente redirecionada."
        }
    }
}

function Confirm-Uninstall {
    Write-Host ''
    Write-Host ('=' * 68) -ForegroundColor Yellow
    Write-Host ' CONFIRMAÇÃO DE DESINSTALAÇÃO' -ForegroundColor Yellow
    Write-Host ('=' * 68) -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'Será removido:' -ForegroundColor White
    Write-Host "  - $script:InstallRoot"
    Write-Host "  - integração do ClipSqueeze no Profile registrado"

    if ([bool]$script:State.executionPolicy.changedByInstaller) {
        Write-Host "  - restauração da Execution Policy anterior, somente se ela ainda estiver no valor aplicado pelo instalador"
    }

    if ([bool]$script:State.ffmpeg.installedByInstaller -and -not $KeepFfmpeg) {
        Write-Host "  - FFmpeg: somente após sua confirmação específica"
    }
    else {
        Write-Host "  - FFmpeg: preservado"
    }

    Write-Host ''
    Write-Host 'Arquivos pessoais fora desta instalação não serão procurados nem removidos.' -ForegroundColor DarkGray
    Write-Host 'O diretório acima é tratado como diretório exclusivo do ClipSqueeze.' -ForegroundColor DarkGray
    Write-Host ''

    $answer = Read-Host 'Digite DESINSTALAR para continuar ou qualquer outra coisa para cancelar'
    if ($answer -cne 'DESINSTALAR') {
        throw 'Desinstalação cancelada pelo usuário.'
    }
}

function Remove-InstallDirectory {
    if (-not (Test-Path -LiteralPath $script:InstallRoot)) {
        Write-UninstallLog 'Diretório de instalação já não existe.' 'WARN'
        return
    }

    $item = Get-Item -LiteralPath $script:InstallRoot -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'O diretório tornou-se um reparse point durante a desinstalação. Remoção abortada.'
    }

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Remove-Item -LiteralPath $script:InstallRoot -Recurse -Force -ErrorAction Stop
            break
        }
        catch {
            if ($attempt -eq 3) { throw }
            Start-Sleep -Milliseconds 500
        }
    }

    if (Test-Path -LiteralPath $script:InstallRoot) {
        throw 'O diretório do ClipSqueeze ainda existe após a tentativa de remoção.'
    }

    Write-UninstallLog 'Diretório do ClipSqueeze removido completamente.' 'OK'
}

function Invoke-Uninstall {
    Write-Host ''
    Write-Host 'ClipSqueeze — Uninstaller' -ForegroundColor White
    Write-Host "Destino reconhecido: $script:InstallRoot" -ForegroundColor DarkGray

    Assert-Environment
    Assert-SafeInstallRoot

    $script:State = Read-InstallationState
    Test-RootForReparsePoints
    Confirm-Uninstall

    Remove-ProfileIntegration
    Restore-ExecutionPolicy
    Remove-FfmpegIfOwned
    Remove-InstallDirectory

    Write-Host ''
    Write-Host ('=' * 68) -ForegroundColor Green
    Write-Host ' DESINSTALAÇÃO CONCLUÍDA' -ForegroundColor Green
    Write-Host ('=' * 68) -ForegroundColor Green
    Write-Host ''
    Write-Host 'O ClipSqueeze e os componentes que o instalador registrou como próprios foram removidos.' -ForegroundColor Green
    Write-Host 'Abra uma nova janela do PowerShell para refletir qualquer alteração restante de sessão.' -ForegroundColor Yellow
}

try {
    Invoke-Uninstall
}
catch {
    Write-Host ''
    Write-UninstallLog $_.Exception.Message 'ERROR'
    Write-Host ''
    Write-Host 'A desinstalação foi interrompida para evitar uma remoção insegura.' -ForegroundColor Red
    if (Test-Path -LiteralPath $script:TempLogPath) {
        Write-Host "Log de diagnóstico: $script:TempLogPath" -ForegroundColor Yellow
    }

    exit 1
}
