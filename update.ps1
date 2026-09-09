#requires -Version 5.1
<#
.SYNOPSIS
    Atualiza o ClipSqueeze com segurança através de Releases do GitHub.

.DESCRIPTION
    Atualizador seguro e idempotente do ClipSqueeze.

    Princípios de segurança:
      - NÃO usa git, git pull ou executa código vindo de branches.
      - Consulta somente a API oficial do GitHub para Releases.
      - Aceita somente a release estável mais recente (sem pre-release/draft).
      - Valida owner/repository e HTTPS.
      - Exige o asset ClipSqueeze.ps1 explicitamente.
      - Valida o SHA-256 publicado pelo GitHub antes de instalar.
      - Por padrão exige assinatura Authenticode válida no arquivo baixado.
      - Opcionalmente fixa o certificado do mantenedor por thumbprint.
      - Recusa downgrade.
      - Recusa sobrescrever modificações locais não registradas pelo instalador.
      - Valida o PowerShell do arquivo antes da substituição.
      - Usa substituição atômica quando possível e mantém backup durante a operação.
      - Preserva config.json, $PROFILE e demais arquivos do usuário.
      - Registra somente informações operacionais; não armazena credenciais.
      - Não eleva privilégios automaticamente.

    Para desenvolvimento, um update unsigned pode ser autorizado explicitamente
    com -AllowUnsigned. Essa opção NÃO deve ser usada no fluxo normal de usuários.

    Configuração opcional em config.json:

    "update": {
        "repository": "OWNER/REPOSITORY",
        "assetName": "ClipSqueeze.ps1",
        "requireSignature": true,
        "trustedSignerThumbprint": "THUMBPRINT"
    }

.NOTES
    A versão instalada é obtida de install-state.json criado pelo install.ps1.
    O atualizador altera somente o ClipSqueeze.ps1 e os metadados de estado.
#>

[CmdletBinding()]
param(
    [string]$Repository,
    [string]$AssetName,
    [switch]$AllowUnsigned,
    [switch]$NoNotification,
    [switch]$ForceLocalChanges
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:UpdaterVersion = '1.0.0'
$script:InstallRoot = Join-Path $env:LOCALAPPDATA 'ClipSqueeze'
$script:StatePath = Join-Path $script:InstallRoot 'install-state.json'
$script:ConfigPath = Join-Path $script:InstallRoot 'config.json'
$script:InstalledScriptPath = Join-Path $script:InstallRoot 'ClipSqueeze.ps1'
$script:LogDirectory = Join-Path $script:InstallRoot 'logs'
$script:TempDirectory = Join-Path $env:TEMP 'ClipSqueeze-Update'
$script:LogPath = Join-Path $script:LogDirectory 'update.log'
$script:DefaultAssetName = 'ClipSqueeze.ps1'
$script:GitHubApiVersion = '2026-03-10'
$script:MaxScriptBytes = 10MB
$script:BackupPath = Join-Path $script:InstallRoot ('.ClipSqueeze.ps1.update-backup-{0}.bak' -f [guid]::NewGuid().ToString('N'))
$script:DownloadedPath = Join-Path $script:TempDirectory ('ClipSqueeze-{0}.download.ps1' -f [guid]::NewGuid().ToString('N'))
$script:StagedPath = Join-Path $script:InstallRoot ('.ClipSqueeze-{0}.stage.ps1' -f [guid]::NewGuid().ToString('N'))
$script:OriginalHash = $null
$script:NewHash = $null
$script:CurrentVersion = $null
$script:LatestVersion = $null
$script:State = $null
$script:Config = $null
$script:RollbackNeeded = $false
$script:UpdateApplied = $false
$script:RepositoryResolved = $null
$script:TrustedSignerThumbprint = $null
$script:RequireSignature = $true

function Write-UpdateLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = '[{0}] [{1}] {2}' -f $timestamp, $Level, $Message

    try {
        New-Item -ItemType Directory -Path $script:LogDirectory -Force | Out-Null
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
    }
    catch {
        # O log jamais deve impedir o update.
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
    Write-Host ('=' * 72) -ForegroundColor DarkGray
    Write-Host " $Title" -ForegroundColor White
    Write-Host ('=' * 72) -ForegroundColor DarkGray
}

function Test-RunningOnWindows {
    if ($env:OS -ne 'Windows_NT') {
        throw 'O ClipSqueeze Updater suporta somente Windows.'
    }
}

function Test-PowerShellVersion {
    $version = $PSVersionTable.PSVersion
    if ($version.Major -lt 5 -or ($version.Major -eq 5 -and $version.Minor -lt 1)) {
        throw "PowerShell 5.1 ou superior é necessário. Versão detectada: $version"
    }

    Write-UpdateLog "PowerShell $version detectado." 'OK'
}

function Assert-SafeInstallRoot {
    if (-not (Test-Path -LiteralPath $script:InstallRoot -PathType Container)) {
        throw "A instalação do ClipSqueeze não foi encontrada em: $script:InstallRoot"
    }

    $root = Get-Item -LiteralPath $script:InstallRoot -Force
    if (($root.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'O diretório de instalação é um reparse point/symlink. Atualização abortada por segurança.'
    }
}

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Arquivo obrigatório não encontrado: $Path"
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) {
            throw 'arquivo vazio.'
        }
        return $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "JSON inválido em '$Path': $($_.Exception.Message)"
    }
}

function Read-InstallationState {
    $state = Read-JsonFile -Path $script:StatePath

    if ([string]::IsNullOrWhiteSpace([string]$state.installRoot)) {
        throw 'install-state.json não contém installRoot.'
    }

    $normalizedStateRoot = [IO.Path]::GetFullPath([string]$state.installRoot).TrimEnd('\')
    $normalizedExpectedRoot = [IO.Path]::GetFullPath($script:InstallRoot).TrimEnd('\')

    if (-not [string]::Equals($normalizedStateRoot, $normalizedExpectedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'install-state.json aponta para um diretório de instalação diferente. Atualização abortada.'
    }

    if ([string]::IsNullOrWhiteSpace([string]$state.mainScript)) {
        throw 'install-state.json não contém mainScript.'
    }

    $normalizedMainScript = [IO.Path]::GetFullPath([string]$state.mainScript)
    $normalizedExpectedScript = [IO.Path]::GetFullPath($script:InstalledScriptPath)

    if (-not [string]::Equals($normalizedMainScript, $normalizedExpectedScript, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'install-state.json aponta para um script principal diferente. Atualização abortada.'
    }

    if ([string]::IsNullOrWhiteSpace([string]$state.applicationVersion)) {
        throw 'install-state.json não contém applicationVersion.'
    }

    return $state
}

function Read-ConfigIfPresent {
    if (-not (Test-Path -LiteralPath $script:ConfigPath -PathType Leaf)) {
        return $null
    }

    try {
        return Read-JsonFile -Path $script:ConfigPath
    }
    catch {
        Write-UpdateLog "config.json não pôde ser lido. A atualização continuará sem usar configurações opcionais do update. Detalhes: $($_.Exception.Message)" 'WARN'
        return $null
    }
}

function Get-OptionalProperty {
    param(
        [Parameter(Mandatory = $false)]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Object) { return $null }

    $property = $Object.PSObject.Properties | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Resolve-UpdateConfiguration {
    $configUpdate = Get-OptionalProperty -Object $script:Config -Name 'update'

    $configuredRepository = Get-OptionalProperty -Object $configUpdate -Name 'repository'
    $stateUpdates = Get-OptionalProperty -Object $script:State -Name 'updates'
    $stateRepository = Get-OptionalProperty -Object $stateUpdates -Name 'repository'
    $configuredAssetName = Get-OptionalProperty -Object $configUpdate -Name 'assetName'
    $configuredRequireSignature = Get-OptionalProperty -Object $configUpdate -Name 'requireSignature'
    $configuredThumbprint = Get-OptionalProperty -Object $configUpdate -Name 'trustedSignerThumbprint'

    if ([string]::IsNullOrWhiteSpace($Repository) -and -not [string]::IsNullOrWhiteSpace([string]$configuredRepository)) {
        $Repository = [string]$configuredRepository
    }

    if ([string]::IsNullOrWhiteSpace($Repository) -and -not [string]::IsNullOrWhiteSpace([string]$stateRepository)) {
        $Repository = [string]$stateRepository
    }

    if ([string]::IsNullOrWhiteSpace($AssetName) -and -not [string]::IsNullOrWhiteSpace([string]$configuredAssetName)) {
        $AssetName = [string]$configuredAssetName
    }

    if ([string]::IsNullOrWhiteSpace($AssetName)) {
        $AssetName = $script:DefaultAssetName
    }

    if ($configuredRequireSignature -ne $null) {
        $script:RequireSignature = [bool]$configuredRequireSignature
    }

    if ($AllowUnsigned) {
        $script:RequireSignature = $false
        Write-UpdateLog 'A verificação de assinatura foi desativada explicitamente com -AllowUnsigned. Uso recomendado somente para desenvolvimento/testes.' 'WARN'
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$configuredThumbprint)) {
        $script:TrustedSignerThumbprint = ([string]$configuredThumbprint) -replace '\s+', ''
    }

    if ([string]::IsNullOrWhiteSpace($Repository)) {
        throw 'Repositório do GitHub não configurado. Use -Repository "OWNER/REPOSITORY" ou adicione update.repository ao config.json.'
    }

    if ($Repository -match '^https?://') {
        throw 'Use somente OWNER/REPOSITORY em -Repository. URLs externas não são aceitas.'
    }

    if ($Repository -notmatch '^[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}$') {
        throw "Repositório inválido: '$Repository'. Formato esperado: OWNER/REPOSITORY"
    }

    if ([IO.Path]::GetFileName($AssetName) -ne $AssetName -or $AssetName -ne 'ClipSqueeze.ps1') {
        throw "AssetName inválido. Por segurança, o atualizador aceita somente 'ClipSqueeze.ps1'."
    }

    if ($script:RequireSignature -and -not [string]::IsNullOrWhiteSpace($script:TrustedSignerThumbprint)) {
        if ($script:TrustedSignerThumbprint -notmatch '^[A-Fa-f0-9]{40}$') {
            throw 'trustedSignerThumbprint inválido. Informe o thumbprint SHA-1 de 40 caracteres hexadecimais do certificado de assinatura.'
        }
        $script:TrustedSignerThumbprint = $script:TrustedSignerThumbprint.ToUpperInvariant()
    }

    $script:RepositoryResolved = $Repository
    $script:AssetName = $AssetName

    Write-UpdateLog "Repositório: $script:RepositoryResolved" 'OK'
    Write-UpdateLog "Asset: $script:AssetName" 'OK'
    Write-UpdateLog "Assinatura Authenticode obrigatória: $script:RequireSignature" 'INFO'

    if (-not [string]::IsNullOrWhiteSpace($script:TrustedSignerThumbprint)) {
        Write-UpdateLog 'Thumbprint de assinante confiável configurado e será validado.' 'OK'
    }
}

function Parse-VersionStrict {
    param([Parameter(Mandatory = $true)][string]$VersionText)

    $text = $VersionText.Trim()
    if ($text.StartsWith('v', [StringComparison]::OrdinalIgnoreCase)) {
        $text = $text.Substring(1)
    }

    if ($text -notmatch '^(\d+)\.(\d+)\.(\d+)(?:[-+].*)?$') {
        throw "Versão '$VersionText' não segue o formato semver esperado MAJOR.MINOR.PATCH."
    }

    return [Version]::new([int]$matches[1], [int]$matches[2], [int]$matches[3])
}

function Set-TlsSecurity {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Write-UpdateLog 'Comunicação HTTPS limitada a TLS 1.2 nesta sessão.' 'OK'
    }
    catch {
        throw "Não foi possível configurar TLS 1.2: $($_.Exception.Message)"
    }
}

function Invoke-GitHubApi {
    param([Parameter(Mandatory = $true)][string]$Uri)

    $uriObject = [Uri]$Uri
    if ($uriObject.Scheme -ne 'https' -or $uriObject.Host -ne 'api.github.com') {
        throw "Endpoint recusado por segurança: $Uri"
    }

    $headers = @{
        Accept = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = $script:GitHubApiVersion
        'User-Agent' = "ClipSqueeze-Updater/$($script:UpdaterVersion)"
    }

    try {
        return Invoke-RestMethod -Method Get -Uri $Uri -Headers $headers -TimeoutSec 30 -ErrorAction Stop
    }
    catch {
        $status = $null
        if ($_.Exception.Response) {
            try { $status = [int]$_.Exception.Response.StatusCode } catch {}
        }

        if ($status) {
            throw "GitHub API retornou HTTP $status ao consultar '$Uri'."
        }

        throw "Falha ao consultar GitHub: $($_.Exception.Message)"
    }
}

function Get-LatestRelease {
    Write-Section '1. Consultando a release estável'

    $uri = "https://api.github.com/repos/$($script:RepositoryResolved)/releases/latest"
    $release = Invoke-GitHubApi -Uri $uri

    if ($null -eq $release) {
        throw 'A API do GitHub não retornou uma release.'
    }

    if ([bool]$release.draft -or [bool]$release.prerelease) {
        throw 'A release retornada está marcada como draft/prerelease. Atualização recusada.'
    }

    if ([string]::IsNullOrWhiteSpace([string]$release.tag_name)) {
        throw 'A release do GitHub não possui tag_name.'
    }

    $script:LatestVersion = Parse-VersionStrict -VersionText ([string]$release.tag_name)

    Write-UpdateLog "Release disponível: $($release.tag_name) -> versão $script:LatestVersion" 'OK'

    return $release
}

function Find-ReleaseAsset {
    param([Parameter(Mandatory = $true)]$Release)

    if ($null -eq $Release.assets) {
        throw 'A release não possui assets publicados.'
    }

    $asset = @($Release.assets | Where-Object { [string]$_.name -ceq $script:AssetName }) | Select-Object -First 1
    if ($null -eq $asset) {
        throw "O asset obrigatório '$script:AssetName' não foi encontrado na release $($Release.tag_name)."
    }

    if ([string]$asset.state -ne 'uploaded') {
        throw "O asset '$script:AssetName' não está no estado 'uploaded'."
    }

    if ([string]$asset.content_type -notmatch '^(text/plain|application/octet-stream|application/x-powershell|)$') {
        Write-UpdateLog "Content-Type declarado pelo GitHub para o asset: '$($asset.content_type)'. A integridade será confirmada pelo SHA-256 e pela validação do arquivo." 'WARN'
    }

    if ([int64]$asset.size -le 0) {
        throw 'O asset possui tamanho inválido.'
    }

    if ([int64]$asset.size -gt $script:MaxScriptBytes) {
        throw "O asset ultrapassa o limite de segurança de $($script:MaxScriptBytes / 1MB) MB."
    }

    if ([string]$asset.digest -notmatch '^sha256:[A-Fa-f0-9]{64}$') {
        throw 'A release não forneceu um digest SHA-256 válido para o asset. Atualização recusada.'
    }

    $repoRegex = [regex]::Escape($script:RepositoryResolved)
    if ([string]$asset.url -notmatch "^https://api\.github\.com/repos/$repoRegex/releases/assets/\d+$") {
        throw 'O endpoint do asset não pertence ao repositório configurado. Atualização recusada.'
    }

    if ([string]$asset.browser_download_url -notmatch '^https://github\.com/[^/]+/[^/]+/releases/download/[^/]+/ClipSqueeze\.ps1$') {
        throw 'A URL de download do asset não possui o formato esperado do GitHub Releases. Atualização recusada.'
    }

    Write-UpdateLog "Asset encontrado: $($asset.name), tamanho declarado: $($asset.size) bytes" 'OK'
    Write-UpdateLog "Digest publicado pelo GitHub: $($asset.digest)" 'OK'

    return $asset
}

function Ensure-TempDirectory {
    New-Item -ItemType Directory -Path $script:TempDirectory -Force | Out-Null
}

function Download-ReleaseAsset {
    param([Parameter(Mandatory = $true)]$Asset)

    Write-Section '2. Baixando e validando o arquivo'
    Ensure-TempDirectory

    if (Test-Path -LiteralPath $script:DownloadedPath) {
        Remove-Item -LiteralPath $script:DownloadedPath -Force -ErrorAction SilentlyContinue
    }

    $uri = [Uri][string]$Asset.url
    if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'api.github.com') {
        throw "Host de download recusado: $($uri.Host)"
    }

    $headers = @{
        Accept = 'application/octet-stream'
        'X-GitHub-Api-Version' = $script:GitHubApiVersion
        'User-Agent' = "ClipSqueeze-Updater/$($script:UpdaterVersion)"
    }

    try {
        Invoke-WebRequest -Method Get -Uri $uri.AbsoluteUri -Headers $headers -UseBasicParsing -OutFile $script:DownloadedPath -TimeoutSec 120 -ErrorAction Stop
    }
    catch {
        throw "Falha ao baixar o asset do GitHub: $($_.Exception.Message)"
    }

    if (-not (Test-Path -LiteralPath $script:DownloadedPath -PathType Leaf)) {
        throw 'O download terminou sem criar o arquivo esperado.'
    }

    $downloaded = Get-Item -LiteralPath $script:DownloadedPath -Force
    if (($downloaded.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'O arquivo baixado é um reparse point/symlink. Atualização recusada.'
    }

    if ($downloaded.Length -le 0) {
        throw 'O arquivo baixado está vazio.'
    }

    if ($downloaded.Length -gt $script:MaxScriptBytes) {
        throw 'O arquivo baixado ultrapassa o limite de tamanho de segurança.'
    }

    if ($downloaded.Length -ne [int64]$Asset.size) {
        throw "Tamanho do arquivo baixado ($($downloaded.Length) bytes) difere do tamanho publicado pelo GitHub ($($Asset.size) bytes)."
    }

    $hash = (Get-FileHash -LiteralPath $script:DownloadedPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $publishedHash = ([string]$Asset.digest).Substring(7).ToLowerInvariant()
    $script:NewHash = $hash

    if ($hash -ne $publishedHash) {
        throw 'O SHA-256 do arquivo baixado não corresponde ao digest publicado pelo GitHub. O arquivo NÃO será instalado.'
    }

    Write-UpdateLog "SHA-256 verificado: $hash" 'OK'
}

function Test-DownloadedScriptSignature {
    Write-Section '3. Verificando assinatura do arquivo'

    if (-not $script:RequireSignature) {
        Write-UpdateLog 'Verificação de assinatura Authenticode desativada explicitamente. Isso reduz a garantia de autenticidade.' 'WARN'
        return
    }

    $signature = Get-AuthenticodeSignature -LiteralPath $script:DownloadedPath

    if ($null -eq $signature) {
        throw 'Não foi possível obter a assinatura Authenticode do arquivo baixado.'
    }

    if ([string]$signature.Status -ne 'Valid') {
        throw "A assinatura Authenticode do arquivo não é válida. Status: $($signature.Status)." 
    }

    if ($null -eq $signature.SignerCertificate) {
        throw 'O arquivo informou assinatura válida, mas nenhum certificado de assinante foi disponibilizado pelo sistema.'
    }

    $subject = [string]$signature.SignerCertificate.Subject
    $thumbprint = ([string]$signature.SignerCertificate.Thumbprint) -replace '\s+', ''
    $thumbprint = $thumbprint.ToUpperInvariant()

    Write-UpdateLog "Assinatura Authenticode válida. Subject: $subject" 'OK'
    Write-UpdateLog "Thumbprint do assinante: $thumbprint" 'OK'

    if (-not [string]::IsNullOrWhiteSpace($script:TrustedSignerThumbprint)) {
        if ($thumbprint -ne $script:TrustedSignerThumbprint) {
            throw 'O certificado que assinou a atualização não corresponde ao thumbprint confiável configurado. O arquivo NÃO será instalado.'
        }

        Write-UpdateLog 'Thumbprint do assinante corresponde ao certificado confiável configurado.' 'OK'
    }
}

function Test-PowerShellScriptSyntax {
    Write-Section '4. Validando sintaxe PowerShell'

    $tokens = $null
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($script:DownloadedPath, [ref]$tokens, [ref]$errors)

    if ($null -ne $errors -and $errors.Count -gt 0) {
        $messages = @($errors | ForEach-Object { $_.Message }) -join '; '
        throw "O arquivo de atualização contém erros de sintaxe PowerShell: $messages"
    }

    $content = Get-Content -LiteralPath $script:DownloadedPath -Raw
    if ($content -notmatch '(?m)^\s*function\s+Compress-Video\s*\{') {
        throw 'O arquivo baixado não contém a função esperada Compress-Video. Atualização recusada.'
    }

    Write-UpdateLog 'Sintaxe PowerShell válida e função principal Compress-Video encontrada.' 'OK'
}

function Get-InstalledScriptHash {
    if (-not (Test-Path -LiteralPath $script:InstalledScriptPath -PathType Leaf)) {
        throw "Script instalado não encontrado: $script:InstalledScriptPath"
    }

    $item = Get-Item -LiteralPath $script:InstalledScriptPath -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'O script instalado é um reparse point/symlink. Atualização recusada.'
    }

    return (Get-FileHash -LiteralPath $script:InstalledScriptPath -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Confirm-LocalIntegrity {
    Write-Section '5. Verificando integridade da instalação atual'

    $actualHash = Get-InstalledScriptHash
    $recordedHash = [string](Get-OptionalProperty -Object (Get-OptionalProperty -Object $script:State -Name 'files') -Name 'clipSqueezeSha256')

    if ([string]::IsNullOrWhiteSpace($recordedHash)) {
        throw 'install-state.json não contém o SHA-256 do ClipSqueeze.ps1 instalado.'
    }

    $script:OriginalHash = $actualHash

    if ($actualHash -ne $recordedHash.ToLowerInvariant()) {
        if (-not $ForceLocalChanges) {
            throw 'O ClipSqueeze.ps1 instalado foi modificado desde a última instalação/atualização. Por segurança, o atualizador não irá sobrescrevê-lo. Use -ForceLocalChanges somente se você reconhece e deseja descartar essa modificação local.'
        }

        Write-UpdateLog 'O script instalado possui modificações locais, mas -ForceLocalChanges foi usado. A modificação será substituída.' 'WARN'
    }
    else {
        Write-UpdateLog 'SHA-256 do script instalado corresponde ao estado registrado.' 'OK'
    }

    if ($script:OriginalHash -eq $script:NewHash) {
        throw 'O arquivo disponível para atualização é byte a byte idêntico ao arquivo instalado, apesar da diferença de versão.'
    }
}

function Confirm-VersionTransition {
    Write-Section '6. Verificando a transição de versão'

    $script:CurrentVersion = Parse-VersionStrict -VersionText ([string]$script:State.applicationVersion)

    Write-UpdateLog "Versão instalada: $script:CurrentVersion" 'INFO'
    Write-UpdateLog "Versão disponível: $script:LatestVersion" 'INFO'

    if ($script:LatestVersion -eq $script:CurrentVersion) {
        return 'Current'
    }

    if ($script:LatestVersion -lt $script:CurrentVersion) {
        throw "A release disponível ($script:LatestVersion) é mais antiga que a versão instalada ($script:CurrentVersion). Downgrade automático é recusado por segurança."
    }

    return 'Update'
}

function Replace-InstalledScript {
    Write-Section '7. Aplicando atualização'

    try {
        # Stage no mesmo volume da instalação para permitir File.Replace.
        # File.Replace cria o backup original durante a própria substituição.
        Copy-Item -LiteralPath $script:DownloadedPath -Destination $script:StagedPath -Force -ErrorAction Stop

        $stagedHash = (Get-FileHash -LiteralPath $script:StagedPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($stagedHash -ne $script:NewHash) {
            throw 'O SHA-256 do arquivo em staging não corresponde ao arquivo validado.'
        }

        if ((Get-Item -LiteralPath $script:StagedPath -Force).Length -gt $script:MaxScriptBytes) {
            throw 'O arquivo em staging ultrapassa o limite de tamanho de segurança.'
        }

        [IO.File]::Replace($script:StagedPath, $script:InstalledScriptPath, $script:BackupPath, $true)
        Write-UpdateLog 'ClipSqueeze.ps1 substituído usando File.Replace.' 'OK'
    }
    catch {
        throw "A substituição atômica do ClipSqueeze.ps1 falhou. Nenhuma substituição alternativa será feita para evitar uma atualização não atômica. Detalhes: $($_.Exception.Message)"
    }

    if (-not (Test-Path -LiteralPath $script:InstalledScriptPath -PathType Leaf)) {
        throw 'O script principal não está presente após a substituição.'
    }

    $afterHash = (Get-FileHash -LiteralPath $script:InstalledScriptPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($afterHash -ne $script:NewHash) {
        throw 'O SHA-256 do script instalado após a substituição não corresponde ao arquivo validado.'
    }

    if (-not (Test-Path -LiteralPath $script:BackupPath -PathType Leaf)) {
        throw 'File.Replace não criou o backup necessário para rollback. Atualização recusada.'
    }

    $backupHash = (Get-FileHash -LiteralPath $script:BackupPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($backupHash -ne $script:OriginalHash) {
        throw 'O backup criado por File.Replace não corresponde ao script original.'
    }

    $script:RollbackNeeded = $true
    Write-UpdateLog 'Integridade do arquivo atualizado e do backup de rollback confirmadas.' 'OK'
}

function Restore-PreviousScript {
    if (-not (Test-Path -LiteralPath $script:BackupPath -PathType Leaf)) {
        Write-UpdateLog 'Backup de rollback não está disponível.' 'ERROR'
        return
    }

    try {
        Copy-Item -LiteralPath $script:BackupPath -Destination $script:InstalledScriptPath -Force -ErrorAction Stop
        $restoredHash = (Get-FileHash -LiteralPath $script:InstalledScriptPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($restoredHash -ne $script:OriginalHash) {
            Write-UpdateLog 'O rollback foi executado, mas o SHA-256 restaurado não corresponde ao original.' 'ERROR'
        }
        else {
            Write-UpdateLog 'Versão anterior do ClipSqueeze.ps1 restaurada com sucesso.' 'OK'
        }
    }
    catch {
        Write-UpdateLog "Falha crítica ao restaurar a versão anterior: $($_.Exception.Message)" 'ERROR'
    }
}

function Write-JsonAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Object
    )

    $directory = Split-Path -Path $Path -Parent
    New-Item -ItemType Directory -Path $directory -Force | Out-Null

    $temp = Join-Path $directory ('.clipsqueeze-json-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    try {
        $json = $Object | ConvertTo-Json -Depth 20
        [IO.File]::WriteAllText($temp, $json + "`r`n", $utf8NoBom)

        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $backup = Join-Path $directory ('.clipsqueeze-json-backup-' + [guid]::NewGuid().ToString('N') + '.bak')
            try {
                Copy-Item -LiteralPath $Path -Destination $backup -Force
                [IO.File]::Replace($temp, $Path, $backup, $true)
                Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
            }
            catch {
                Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
                throw
            }
        }
        else {
            Move-Item -LiteralPath $temp -Destination $Path -Force
        }
    }
    finally {
        if (Test-Path -LiteralPath $temp) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
    }
}


function Set-OrAddObjectProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Value
    )

    $property = $Object.PSObject.Properties | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if ($null -ne $property) {
        $property.Value = $Value
        return $Object
    }

    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    return $Object
}

function Update-InstallationState {
    Write-Section '8. Registrando nova versão'

    $files = Get-OptionalProperty -Object $script:State -Name 'files'
    if ($null -eq $files) {
        throw 'install-state.json não contém a seção files.'
    }

    $files.clipSqueezeSha256 = $script:NewHash
    $script:State.applicationVersion = $script:LatestVersion.ToString()
    $script:State.updatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')

    $updates = Get-OptionalProperty -Object $script:State -Name 'updates'
    if ($null -eq $updates) {
        $updates = [pscustomobject]@{}
        $script:State | Add-Member -NotePropertyName updates -NotePropertyValue $updates
    }

    $updates = Set-OrAddObjectProperty -Object $updates -Name 'lastReleaseTag' -Value "v$($script:LatestVersion)"
    $updates = Set-OrAddObjectProperty -Object $updates -Name 'lastUpdateAtUtc' -Value ((Get-Date).ToUniversalTime().ToString('o'))
    $updates = Set-OrAddObjectProperty -Object $updates -Name 'lastAssetSha256' -Value $script:NewHash
    $updates = Set-OrAddObjectProperty -Object $updates -Name 'repository' -Value $script:RepositoryResolved

    Write-JsonAtomic -Path $script:StatePath -Object $script:State

    # config.json é opcional. Se existir e for válido, apenas applicationVersion é atualizado.
    if ($null -ne $script:Config) {
        try {
            $script:Config.applicationVersion = $script:LatestVersion.ToString()
            Write-JsonAtomic -Path $script:ConfigPath -Object $script:Config
            Write-UpdateLog 'applicationVersion do config.json atualizado.' 'OK'
        }
        catch {
            Write-UpdateLog "Não foi possível atualizar applicationVersion no config.json. O estado principal já foi atualizado: $($_.Exception.Message)" 'WARN'
        }
    }

    Write-UpdateLog 'install-state.json atualizado com a nova versão e SHA-256.' 'OK'
}

function Test-InstalledScriptAfterUpdate {
    Write-Section '9. Validação pós-atualização'

    $hash = (Get-FileHash -LiteralPath $script:InstalledScriptPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -ne $script:NewHash) {
        throw 'Validação pós-atualização falhou: SHA-256 inesperado.'
    }

    $tokens = $null
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($script:InstalledScriptPath, [ref]$tokens, [ref]$errors)
    if ($null -ne $errors -and $errors.Count -gt 0) {
        throw 'Validação pós-atualização falhou: o arquivo instalado contém erros de sintaxe.'
    }

    $installedContent = Get-Content -LiteralPath $script:InstalledScriptPath -Raw
    if ($installedContent -notmatch '(?m)^\s*function\s+Compress-Video\s*\{') {
        throw 'Validação pós-atualização falhou: Compress-Video não foi encontrada no script instalado.'
    }

    Write-UpdateLog 'Validação pós-atualização concluída.' 'OK'
}

function Cleanup-TemporaryFiles {
    try {
        if (Test-Path -LiteralPath $script:DownloadedPath) {
            Remove-Item -LiteralPath $script:DownloadedPath -Force -ErrorAction SilentlyContinue
        }

        if (Test-Path -LiteralPath $script:StagedPath) {
            Remove-Item -LiteralPath $script:StagedPath -Force -ErrorAction SilentlyContinue
        }

        if (Test-Path -LiteralPath $script:TempDirectory -PathType Container) {
            $entries = @(Get-ChildItem -LiteralPath $script:TempDirectory -Force -ErrorAction SilentlyContinue)
            if ($entries.Count -eq 0) {
                Remove-Item -LiteralPath $script:TempDirectory -Force -ErrorAction SilentlyContinue
            }
        }
    }
    catch {
        Write-UpdateLog "Não foi possível limpar completamente os temporários: $($_.Exception.Message)" 'WARN'
    }
}

function Cleanup-Backup {
    if (-not $script:RollbackNeeded) { return }

    try {
        if (Test-Path -LiteralPath $script:BackupPath) {
            Remove-Item -LiteralPath $script:BackupPath -Force -ErrorAction Stop
            Write-UpdateLog 'Backup temporário removido após validação bem-sucedida.' 'OK'
        }
    }
    catch {
        Write-UpdateLog "Não foi possível remover o backup temporário: $($_.Exception.Message)" 'WARN'
    }
}

function Show-UpdateNotification {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('Info', 'Warning', 'Error')][string]$Type = 'Info'
    )

    if ($NoNotification) { return }

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop

        $notify = New-Object System.Windows.Forms.NotifyIcon
        $notify.Icon = [System.Drawing.SystemIcons]::Information
        $notify.Visible = $true
        $notify.ShowBalloonTip(5000, $Title, $Message, [System.Windows.Forms.ToolTipIcon]::$Type)
        Start-Sleep -Seconds 4
        $notify.Dispose()
    }
    catch {
        Write-UpdateLog "Não foi possível exibir a notificação do Windows: $($_.Exception.Message)" 'WARN'
    }
}

function Invoke-Update {
    Write-Host ''
    Write-Host 'ClipSqueeze — Updater' -ForegroundColor White
    Write-Host "Versão do atualizador: $script:UpdaterVersion" -ForegroundColor DarkGray
    Write-Host "Instalação: $script:InstallRoot" -ForegroundColor DarkGray

    Test-RunningOnWindows
    Test-PowerShellVersion
    Set-TlsSecurity
    Assert-SafeInstallRoot

    $script:State = Read-InstallationState
    $script:Config = Read-ConfigIfPresent
    Resolve-UpdateConfiguration

    $release = Get-LatestRelease
    $status = Confirm-VersionTransition

    if ($status -eq 'Current') {
        Write-UpdateLog "O ClipSqueeze já está na versão mais recente ($($script:CurrentVersion))." 'OK'
        Show-UpdateNotification -Title 'ClipSqueeze' -Message "Você já está usando a versão mais recente: v$($script:CurrentVersion)." -Type Info
        return
    }

    $asset = Find-ReleaseAsset -Release $release
    Download-ReleaseAsset -Asset $asset
    Test-DownloadedScriptSignature
    Test-PowerShellScriptSyntax
    Confirm-LocalIntegrity

    $confirmation = Read-Host "Atualizar ClipSqueeze de v$($script:CurrentVersion) para v$($script:LatestVersion)? Digite ATUALIZAR para continuar ou qualquer outra coisa para cancelar"
    if ($confirmation -cne 'ATUALIZAR') {
        throw 'Atualização cancelada pelo usuário.'
    }

    Replace-InstalledScript

    try {
        # Primeiro valida o novo script. O estado só é alterado depois de o arquivo estar validado.
        Test-InstalledScriptAfterUpdate
        Update-InstallationState
        $script:UpdateApplied = $true
        $script:RollbackNeeded = $false
    }
    catch {
        Write-UpdateLog 'Falha após substituição. Iniciando rollback para a versão anterior.' 'ERROR'
        Restore-PreviousScript
        throw
    }

    Cleanup-Backup

    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor Green
    Write-Host ' ATUALIZAÇÃO CONCLUÍDA' -ForegroundColor Green
    Write-Host ('=' * 72) -ForegroundColor Green
    Write-Host ''
    Write-Host "Versão anterior: v$($script:CurrentVersion)"
    Write-Host "Versão atual:    v$($script:LatestVersion)" -ForegroundColor Green
    Write-Host ''
    Write-Host 'Abra uma nova janela do PowerShell para garantir que o script atualizado seja carregado.' -ForegroundColor Yellow

    Show-UpdateNotification -Title 'ClipSqueeze — Atualizado' -Message "Atualização concluída: v$($script:CurrentVersion) → v$($script:LatestVersion)." -Type Info
}

try {
    Invoke-Update
}
catch {
    Write-Host ''
    Write-UpdateLog $_.Exception.Message 'ERROR'

    if ($script:RollbackNeeded -and -not $script:UpdateApplied) {
        Write-UpdateLog 'Tentando rollback de segurança.' 'WARN'
        Restore-PreviousScript
    }

    Show-UpdateNotification -Title 'ClipSqueeze — Atualização' -Message 'Não foi possível concluir a atualização. Consulte update.log para obter detalhes.' -Type Error
    Cleanup-TemporaryFiles
    exit 1
}
finally {
    Cleanup-TemporaryFiles
    if ($script:UpdateApplied) {
        Write-UpdateLog 'Processo de atualização finalizado com sucesso.' 'OK'
    }
}
