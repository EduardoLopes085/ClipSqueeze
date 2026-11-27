<#
    ClipSqueeze
    Compressão de vídeo simplificada via FFmpeg (CPU ou GPU) para PowerShell.

    Comando principal: Compress-Video (segue a convenção Verbo-Substantivo do
    PowerShell, a mesma de Compress-Archive). O alias 'comprimir' funciona
    exatamente igual.

    Uso:
        comprimir <acelerador> <arquivo> [perfil] [limite] [-resolution <preset>] [-Metadata clean|preserve] [-Force]

    Exemplos:
        comprimir cpu "gravacao_reuniao"
        comprimir cpu "gravacao_reuniao" quality -resolution hd
        comprimir nvidia "gravacao_reuniao" efficient 40mb -resolution fhd

    Veja o README para detalhes de instalação, perfis disponíveis e como
    o cálculo de limite de tamanho funciona.

    O config.json pode sobrescrever os padrões por chave.
#>

# ============================================================
# Configuração (config.json)
# ============================================================
# Chaves ausentes ou inválidas usam os padrões internos.

function ConvertTo-HashtableDeep {
    # Converte recursivamente o objeto retornado por ConvertFrom-Json
    # (PSCustomObject) em Hashtable aninhada, pra podermos fazer merge
    # com os padrões abaixo. Evita depender de 'ConvertFrom-Json -AsHashtable',
    # que só existe no PowerShell 6+ (este script roda em 5.1 também).
    param($InputObject)

    if ($null -eq $InputObject) { return $null }

    # PowerShell 7 represents JSON integers as Int64, even when they fit in Int32.
    if ($InputObject -is [long] -and $InputObject -ge [int]::MinValue -and $InputObject -le [int]::MaxValue) {
        return [int]$InputObject
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        $lista = @()
        foreach ($item in $InputObject) {
            $lista += , (ConvertTo-HashtableDeep $item)
        }
        return , $lista
    }

    if ($InputObject -is [PSCustomObject]) {
        $tabela = @{}
        foreach ($propriedade in $InputObject.PSObject.Properties) {
            $tabela[$propriedade.Name] = ConvertTo-HashtableDeep $propriedade.Value
        }
        return $tabela
    }

    return $InputObject
}

function Merge-ConfigHashtable {
    # Merge raso->profundo: para cada chave em $Override, se os dois lados
    # forem Hashtable, mescla recursivamente; senão, $Override vence.
    # Chaves ausentes em $Override simplesmente mantêm o valor de $Base.
    param(
        [hashtable]$Base,
        [hashtable]$Override
    )

    $resultado = $Base.Clone()
    if ($null -eq $Override) { return $resultado }

    foreach ($chave in $Override.Keys) {
        if ($resultado.ContainsKey($chave) -and $resultado[$chave] -is [hashtable] -and $Override[$chave] -is [hashtable]) {
            $resultado[$chave] = Merge-ConfigHashtable -Base $resultado[$chave] -Override $Override[$chave]
        }
        else {
            $resultado[$chave] = $Override[$chave]
        }
    }

    return $resultado
}

function Repair-ParametrosPerfil {
    param(
        [hashtable]$Config,
        [hashtable]$Padrao
    )

    if ($null -eq $Config.profileOverrides -or $Config.profileOverrides -isnot [hashtable]) {
        $Config.profileOverrides = $Padrao.profileOverrides.Clone()
        return $Config
    }

    $resultado = @{
        cpu    = @{}
        amd    = @{}
        nvidia = @{}
    }

    $cpuPresets = @('ultrafast', 'superfast', 'veryfast', 'faster', 'fast', 'medium', 'slow', 'slower', 'veryslow', 'placebo')
    $amdQualities = @('speed', 'balanced', 'quality', 'high_quality')
    $nvidiaPresets = @('default', 'slow', 'medium', 'fast', 'hp', 'hq', 'bd', 'll', 'llhq', 'llhp', 'lossless', 'losslesshp', 'p1', 'p2', 'p3', 'p4', 'p5', 'p6', 'p7')

    foreach ($acelerador in @("cpu", "amd", "nvidia")) {
        $origem = $Config.profileOverrides[$acelerador]
        if ($origem -isnot [hashtable]) { continue }

        if ($acelerador -eq "cpu") {
            foreach ($perfil in @("fast", "balanced", "efficient", "quality")) {
                $perfilConfig = $origem[$perfil]
                if ($perfilConfig -isnot [hashtable]) { continue }

                $filtrado = @{}
                $preset = $perfilConfig['preset']
                $crf = $perfilConfig['crf']
                if ($preset -is [string] -and $preset -in $cpuPresets) {
                    $filtrado.preset = $preset.ToLowerInvariant()
                }
                if (($crf -is [int] -or $crf -is [double] -or $crf -is [decimal]) -and $crf -ge 0 -and $crf -le 51) {
                    $filtrado.crf = $crf
                }
                if ($filtrado.Count -gt 0) {
                    $resultado.cpu[$perfil] = $filtrado
                }
            }
        }
        else {
            foreach ($codec in @("hevc", "h264", "av1")) {
                $codecConfig = $origem[$codec]
                if ($codecConfig -isnot [hashtable]) { continue }

                $perfisCodec = @{}
                foreach ($perfil in @("fast", "balanced", "efficient", "quality")) {
                    $perfilConfig = $codecConfig[$perfil]
                    if ($perfilConfig -isnot [hashtable]) { continue }

                    $filtrado = @{}
                    if ($acelerador -eq "amd") {
                        $quality = $perfilConfig['quality']
                        $qvbr = $perfilConfig['qvbr']
                        if ($quality -is [string] -and $quality -in $amdQualities) {
                            $filtrado.quality = $quality.ToLowerInvariant()
                        }
                        if ($qvbr -is [int] -and $qvbr -ge -1 -and $qvbr -le 51) {
                            $filtrado.qvbr = $qvbr
                        }
                    }
                    else {
                        $preset = $perfilConfig['preset']
                        $cq = $perfilConfig['cq']
                        if ($preset -is [string] -and $preset -in $nvidiaPresets) {
                            $filtrado.preset = $preset.ToLowerInvariant()
                        }
                        if (($cq -is [int] -or $cq -is [double] -or $cq -is [decimal]) -and $cq -ge 0 -and $cq -le 51) {
                            $filtrado.cq = $cq
                        }
                    }
                    if ($filtrado.Count -gt 0) {
                        $perfisCodec[$perfil] = $filtrado
                    }
                }
                if ($perfisCodec.Count -gt 0) { $resultado[$acelerador][$codec] = $perfisCodec }
            }
        }
    }

    $Config.profileOverrides = $resultado
    return $Config
}

function Repair-ClipSqueezeConfig {
    param(
        [hashtable]$Config,
        [hashtable]$Padrao
    )

    if ($null -eq $Config -or $Config -isnot [hashtable]) {
        return $Padrao
    }

    foreach ($secao in @(
        "defaults", "output", "audio", "bitrateCalc", "resolutionPresets",
        "profileOverrides", "ffmpeg", "notifications", "ui", "logging", "metadata"
    )) {
        if ($Config.ContainsKey($secao) -and $Config[$secao] -isnot [hashtable]) {
            $Config[$secao] = $Padrao[$secao].Clone()
        }
    }

    if ($Config.defaults.accelerator -notin @("cpu", "amd", "nvidia")) {
        $Config.defaults.accelerator = $Padrao.defaults.accelerator
    }
    if ($Config.defaults.profile -notin @("fast", "balanced", "efficient", "quality")) {
        $Config.defaults.profile = $Padrao.defaults.profile
    }
    if ($Config.defaults.container -notin @("mp4", "mkv", "mov")) {
        $Config.defaults.container = $Padrao.defaults.container
    }
    if ($Config.defaults.codec -notin @("hevc", "h264", "av1")) {
        $Config.defaults.codec = $Padrao.defaults.codec
    }
    if ($Config.metadata.mode -isnot [string] -or $Config.metadata.mode -notin @('clean', 'preserve')) {
        $Config.metadata.mode = $Padrao.metadata.mode
    }

    if ($null -ne $Config.defaults.resolution) {
        $resolucao = [string]$Config.defaults.resolution
        if ([string]::IsNullOrWhiteSpace($resolucao) -or
            -not $Config.resolutionPresets.ContainsKey($resolucao.ToLower())) {
            $Config.defaults.resolution = $Padrao.defaults.resolution
        }
        else {
            $Config.defaults.resolution = $resolucao.ToLower()
        }
    }

    if ($Config.output.suffix -isnot [string] -or [string]::IsNullOrWhiteSpace($Config.output.suffix)) {
        $Config.output.suffix = $Padrao.output.suffix
    }
    elseif ($Config.output.suffix.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) {
        $Config.output.suffix = $Padrao.output.suffix
    }

    if ($Config.output.overwrite -isnot [bool]) {
        $Config.output.overwrite = $Padrao.output.overwrite
    }

    $audioCodecs = @('aac', 'libfdk_aac', 'opus', 'libopus', 'mp3', 'libmp3lame', 'ac3', 'eac3', 'flac', 'alac', 'vorbis', 'libvorbis', 'pcm_s16le', 'pcm_s24le', 'pcm_s32le', 'copy')
    if ($Config.audio.codec -isnot [string] -or $Config.audio.codec -notin $audioCodecs) {
        $Config.audio.codec = $Padrao.audio.codec
    }
    else {
        $Config.audio.codec = $Config.audio.codec.ToLowerInvariant()
    }
    if ($Config.audio.bitrateKbps -isnot [int] -or $Config.audio.bitrateKbps -le 0) {
        $Config.audio.bitrateKbps = $Padrao.audio.bitrateKbps
    }

    if (($Config.bitrateCalc.safetyMargin -isnot [double] -and $Config.bitrateCalc.safetyMargin -isnot [decimal]) -or
        $Config.bitrateCalc.safetyMargin -le 0 -or
        $Config.bitrateCalc.safetyMargin -gt 1) {
        $Config.bitrateCalc.safetyMargin = $Padrao.bitrateCalc.safetyMargin
    }
    if ($Config.bitrateCalc.lowBitrateWarningKbps -isnot [int] -or
        $Config.bitrateCalc.lowBitrateWarningKbps -le 0) {
        $Config.bitrateCalc.lowBitrateWarningKbps = $Padrao.bitrateCalc.lowBitrateWarningKbps
    }

    foreach ($chave in @("hd", "fhd", "qhd", "4k")) {
        if (-not $Config.resolutionPresets.ContainsKey($chave) -or
            $Config.resolutionPresets[$chave] -isnot [int] -or
            $Config.resolutionPresets[$chave] -lt 2) {
            $Config.resolutionPresets[$chave] = $Padrao.resolutionPresets[$chave]
        }
    }

    if ($Config.ffmpeg.packageId -isnot [string] -or [string]::IsNullOrWhiteSpace($Config.ffmpeg.packageId)) {
        $Config.ffmpeg.packageId = $Padrao.ffmpeg.packageId
    }

    if ($Config.notifications.enabled -isnot [bool]) {
        $Config.notifications.enabled = $Padrao.notifications.enabled
    }

    if ($Config.ui.progressBarWidth -isnot [int] -or $Config.ui.progressBarWidth -lt 10 -or $Config.ui.progressBarWidth -gt 200) {
        $Config.ui.progressBarWidth = $Padrao.ui.progressBarWidth
    }
    if ($Config.ui.colors -isnot [bool]) {
        $Config.ui.colors = $Padrao.ui.colors
    }

    if ($Config.logging.keepErrorLogs -isnot [bool]) {
        $Config.logging.keepErrorLogs = $Padrao.logging.keepErrorLogs
    }

    return Repair-ParametrosPerfil -Config $Config -Padrao $Padrao
}

function Get-ClipSqueezeConfig {
    param([string]$caminho)

    if ([string]::IsNullOrWhiteSpace($caminho)) {
        $pastaScript = if ($PSScriptRoot) { $PSScriptRoot } elseif ($MyInvocation.PSCommandPath) { Split-Path -Parent $MyInvocation.PSCommandPath } else { $null }
        if ([string]::IsNullOrWhiteSpace($pastaScript)) { $pastaScript = "." }
        $caminho = Join-Path $pastaScript "config.json"
    }

    # Estes são EXATAMENTE os valores que já estavam hardcoded no script
    # antes do config.json existir. Servem de piso: qualquer chave que
    # faltar no config.json do usuário cai aqui.
    $configPadrao = @{
        schemaVersion      = 1
        applicationVersion = "0.1.0"
        defaults           = @{
            accelerator = "cpu"
            profile     = "balanced"
            container   = "mp4"
            codec       = "hevc"
            resolution  = $null
        }
        output             = @{
            suffix    = "_comprimido"
            overwrite = $false
            directory = $null
        }
        metadata           = @{
            mode = 'clean'
        }
        audio              = @{
            codec       = "aac"
            bitrateKbps = 128
        }
        bitrateCalc        = @{
            safetyMargin          = 0.92
            lowBitrateWarningKbps = 300
        }
        resolutionPresets  = @{
            hd   = 1280
            fhd  = 1920
            qhd  = 2560
            "4k" = 3840
        }
        profileOverrides   = @{
            cpu    = @{}
            amd    = @{}
            nvidia = @{}
        }
        ffmpeg             = @{
            packageId = "Gyan.FFmpeg"
        }
        notifications      = @{
            enabled = $true
        }
        ui                 = @{
            progressBarWidth = 40
            colors           = $true
        }
        logging            = @{
            keepErrorLogs = $true
            directory     = $null
        }
    }

    if (-not (Test-Path -LiteralPath $caminho -PathType Leaf)) {
        return $configPadrao
    }

    try {
        $jsonTexto = Get-Content -LiteralPath $caminho -Raw -Encoding UTF8 -ErrorAction Stop
        $jsonObjeto = $jsonTexto | ConvertFrom-Json -ErrorAction Stop
        $configUsuario = ConvertTo-HashtableDeep -InputObject $jsonObjeto
        $configMesclado = Merge-ConfigHashtable -Base $configPadrao -Override $configUsuario
        return Repair-ClipSqueezeConfig -Config $configMesclado -Padrao $configPadrao
    }
    catch {
        Write-Host "Aviso: não foi possível ler '$caminho' ($($_.Exception.Message)). Usando configurações padrão." -ForegroundColor Yellow
        return $configPadrao
    }
}

# Carregada uma vez, no escopo de topo do script — mesmo padrão que
# $PerfisConfig e $ResolucaoPresets já usavam antes (variável "solta",
# sem prefixo de escopo, visível pelas funções definidas abaixo).
$ClipSqueezeConfig = Get-ClipSqueezeConfig

function Install-FFmpegViaWinget {
    $packageId = $ClipSqueezeConfig.ffmpeg.packageId
    Write-Host "Instalando ffmpeg via winget ($packageId)..." -ForegroundColor Cyan
    winget install --id $packageId -e --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) { return $false }

    # Tenta atualizar o PATH da sessão atual sem precisar reabrir o terminal
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
    return $true
}

function Test-FFmpegInstalado {
    param([switch]$NaoInterativo)

    $ffmpegOk = [bool](Get-Command ffmpeg -CommandType Application -ErrorAction SilentlyContinue)
    $ffprobeOk = [bool](Get-Command ffprobe -CommandType Application -ErrorAction SilentlyContinue)

    if ($ffmpegOk -and $ffprobeOk) { return $true }

    if (-not $ffmpegOk -and -not $ffprobeOk) {
        Write-Host "ffmpeg não foi encontrado no PATH." -ForegroundColor Red
    }
    elseif (-not $ffprobeOk) {
        Write-Host "ffmpeg foi encontrado, mas ffprobe não. Isso normalmente indica uma instalação incompleta (só o executável ffmpeg.exe foi copiado, sem o pacote completo)." -ForegroundColor Red
    }
    else {
        Write-Host "ffprobe foi encontrado, mas ffmpeg não." -ForegroundColor Red
    }

    if ($NaoInterativo) {
        Write-Host 'Para usar -Force, instale ffmpeg e ffprobe e confirme que ambos estão no PATH.' -ForegroundColor Yellow
        return $false
    }

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host "winget não está disponível neste sistema. Baixe manualmente em: https://www.gyan.dev/ffmpeg/builds/ (pacote 'release full' ou 'essentials')." -ForegroundColor Yellow
        return $false
    }

    $resposta = Read-Host "Deseja instalar o ffmpeg agora via winget (pacote $($ClipSqueezeConfig.ffmpeg.packageId))? (s/n)"
    if ($resposta -ne "s") {
        Write-Host "Instalação cancelada." -ForegroundColor Yellow
        return $false
    }

    if (-not (Install-FFmpegViaWinget)) {
        Write-Host "A instalação via winget falhou. Tente manualmente: https://www.gyan.dev/ffmpeg/builds/" -ForegroundColor Red
        return $false
    }

    Start-Sleep -Seconds 1
    if ((Get-Command ffmpeg -CommandType Application -ErrorAction SilentlyContinue) -and (Get-Command ffprobe -CommandType Application -ErrorAction SilentlyContinue)) {
        Write-Host "ffmpeg instalado e pronto para uso." -ForegroundColor Green
        return $true
    }

    Write-Host "Instalado, mas este terminal não reconheceu o PATH automaticamente. Feche e reabra o terminal, depois rode o comando novamente." -ForegroundColor Yellow
    return $false
}

function Resolve-ArquivoVideo {
    param([string]$arquivo)

    # Se o caminho já existe exatamente como foi passado (com extensão), usa direto
    if (Test-Path -LiteralPath $arquivo -PathType Leaf) {
        return Get-Item -LiteralPath $arquivo
    }

    # Extensões de vídeo que vamos tentar
    $extensoes = @("mp4", "mkv", "mov", "avi", "webm", "wmv", "flv", "m4v")

    $pasta = Split-Path $arquivo -Parent
    if ([string]::IsNullOrEmpty($pasta)) { $pasta = "." }
    $nomeBase = Split-Path $arquivo -Leaf

    $candidatos = @()
    foreach ($ext in $extensoes) {
        $tentativa = Join-Path $pasta "$nomeBase.$ext"
        if (Test-Path -LiteralPath $tentativa -PathType Leaf) {
            $candidatos += Get-Item -LiteralPath $tentativa
        }
    }

    if ($candidatos.Count -eq 0) {
        Write-Host "Nenhum arquivo de vídeo encontrado para: $arquivo" -ForegroundColor Red
        return $null
    }
    if ($candidatos.Count -gt 1) {
        Write-Host "Mais de um arquivo encontrado com esse nome:" -ForegroundColor Yellow
        $candidatos | ForEach-Object { Write-Host "  - $($_.Name)" -ForegroundColor Yellow }
        Write-Host "Especifique a extensão explicitamente." -ForegroundColor Yellow
        return $null
    }

    return $candidatos[0]
}


function Test-EncoderDisponivel {
    param([string]$nome)
    try {
        $linhas = ffmpeg -hide_banner -encoders 2>$null
        return ($linhas | Select-String -SimpleMatch $nome) -ne $null
    }
    catch {
        return $false
    }
}

function Get-DicaErroConhecido {
    param([string]$log)

    $padroesConhecidos = @(
        @{ Regex = "does not support the required nvenc API version|minimum required Nvidia driver"
            Dica = "O driver da NVIDIA nesta máquina está desatualizado para a versão do NVENC exigida por este FFmpeg. Atualize o driver em nvidia.com/drivers e tente novamente." 
        }
        @{ Regex = "Cannot load nvcuda\.dll|no CUDA-capable device"
            Dica = "Não foi possível inicializar CUDA/NVENC nesta GPU. Verifique se o driver NVIDIA está instalado e se a GPU está realmente ativa (não em modo híbrido/desligada)." 
        }
        @{ Regex = "Failed to initialise AMF|Failed to open AMF"
            Dica = "Não foi possível inicializar o driver AMD (AMF). Verifique se o driver da GPU AMD está atualizado." 
        }
        @{ Regex = '\[(?:hevc|h264|av1)_amf[^\]]*\]\s+encoder->Init\(\) failed with error 5'
            Dica = "O encoder AMD AMF recusou os parâmetros. Verifique se o codec e as dimensões de saída são compatíveis com o driver da GPU."
        }
    )

    foreach ($padrao in $padroesConhecidos) {
        if ($log -match $padrao.Regex) { return $padrao.Dica }
    }
    return $null
}

function Resolve-ParametrosComprimir {
    param(
        [string]$acelerador,
        [string]$perfil,
        [string]$limiteStr,
        [string]$container,
        [string]$codec,
        [string]$resolution,
        [string]$metadata
    )

    # Cada default abaixo vem do config.json quando disponível; se
    # $ClipSqueezeConfig não existir por algum motivo, cai nos mesmos
    # literais que o script sempre usou.
    if ([string]::IsNullOrWhiteSpace($perfil)) {
        $perfil = if ($ClipSqueezeConfig) { $ClipSqueezeConfig.defaults.profile } else { "balanced" }
    }
    if ([string]::IsNullOrWhiteSpace($container)) {
        $container = if ($ClipSqueezeConfig) { $ClipSqueezeConfig.defaults.container } else { "mp4" }
    }
    if ([string]::IsNullOrWhiteSpace($codec)) {
        $codec = if ($ClipSqueezeConfig) { $ClipSqueezeConfig.defaults.codec } else { "hevc" }
    }
    if ([string]::IsNullOrWhiteSpace($resolution) -and $ClipSqueezeConfig -and $ClipSqueezeConfig.defaults.resolution) {
        $resolution = $ClipSqueezeConfig.defaults.resolution
    }
    if (-not $metadata) { $metadata = $ClipSqueezeConfig.metadata.mode }

    $aceleradoresValidos = @("cpu", "amd", "nvidia")
    $perfisValidos = @("fast", "balanced", "efficient", "quality")

    if ([string]::IsNullOrWhiteSpace($acelerador)) {
        Write-Host "Acelerador não informado. Use: $($aceleradoresValidos -join ', ')" -ForegroundColor Red
        return $null
    }
    $aceleradorNormalizado = $acelerador.ToLower()
    if ($aceleradoresValidos -notcontains $aceleradorNormalizado) {
        Write-Host "Acelerador inválido: '$acelerador'. Use: $($aceleradoresValidos -join ', ')" -ForegroundColor Red
        return $null
    }

    $perfilNormalizado = $perfil.ToLower()
    if ($perfisValidos -notcontains $perfilNormalizado) {
        Write-Host "Perfil inválido: '$perfil'. Use: $($perfisValidos -join ', ')" -ForegroundColor Red
        return $null
    }

    $containersValidos = @("mp4", "mkv", "mov")
    $containerNormalizado = $container.ToLower()
    $codecsValidos = @("hevc", "h264", "av1")
    $codecNormalizado = $codec.ToLower()
    if ($codecsValidos -notcontains $codecNormalizado) {
        Write-Host "Codec inválido: '$codec'. Use: $($codecsValidos -join ', ')" -ForegroundColor Red
        return $null
    }

    if ($containersValidos -notcontains $containerNormalizado) {
        Write-Host "Container inválido: '$container'. Use: $($containersValidos -join ', ')" -ForegroundColor Red
        return $null
    }

    $resolucaoNormalizada = $null
    if (-not [string]::IsNullOrWhiteSpace($resolution)) {
        $resolucaoNormalizada = $resolution.ToLower()
        if (-not $ResolucaoPresets.ContainsKey($resolucaoNormalizada)) {
            Write-Host "Resolução inválida: '$resolution'. Use: $($ResolucaoPresets.Keys -join ', ')" -ForegroundColor Red
            return $null
        }
    }

    $limiteBytes = $null
    if (-not [string]::IsNullOrWhiteSpace($limiteStr)) {
        if ($limiteStr -notmatch '^([0-9]+(?:[.,][0-9]+)?)\s*mb$') {
            Write-Host "Formato de limite inválido: '$limiteStr'. Use algo como '40mb'." -ForegroundColor Red
            return $null
        }
        $valorTexto = $matches[1].Replace(',', '.')
        $valorMb = 0D
        $maximoMb = [decimal]([long]::MaxValue) / 1000000
        if (-not [decimal]::TryParse($valorTexto, [Globalization.NumberStyles]::AllowDecimalPoint,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$valorMb) -or
            $valorMb -lt 0.000001D -or $valorMb -gt $maximoMb) {
            Write-Host "Limite fora do intervalo aceito: '$limiteStr'." -ForegroundColor Red
            return $null
        }
        $limiteBytes = [long][Math]::Floor($valorMb * 1000000)
    }

    if ($aceleradoresGpu -contains $aceleradorNormalizado) {
        $encoderGpu = $CodecEncoder[$aceleradorNormalizado][$codecNormalizado]
        if (-not (Test-EncoderDisponivel -nome $encoderGpu)) {
            Write-Host "Encoder $encoderGpu não disponível neste ffmpeg/sistema. Tente outro -codec, outro acelerador, ou verifique sua instalação/driver." -ForegroundColor Red
            return $null
        }
    }

    return [PSCustomObject]@{
        Acelerador  = $aceleradorNormalizado
        Perfil      = $perfilNormalizado
        LimiteBytes = $limiteBytes
        LimiteTexto = $limiteStr
        Container   = $containerNormalizado
        Codec       = $codecNormalizado
        Resolucao   = $resolucaoNormalizada
        Metadata    = $metadata
    }
}

function Invoke-FfprobeJson {
    param([string[]]$argumentos)

    $processo = $null
    try {
        $ffprobe = Get-Command ffprobe -CommandType Application -ErrorAction Stop | Select-Object -First 1
        $inicio = [Diagnostics.ProcessStartInfo]::new()
        $inicio.FileName = $ffprobe.Path
        $inicio.Arguments = ConvertTo-WindowsArgumentLine $argumentos
        $inicio.UseShellExecute = $false
        $inicio.CreateNoWindow = $true
        $inicio.RedirectStandardOutput = $true
        $inicio.RedirectStandardError = $true
        # FFprobe returns UTF-8 even when Windows PowerShell uses a legacy code page.
        $inicio.StandardOutputEncoding = [Text.Encoding]::UTF8
        $processo = [Diagnostics.Process]::Start($inicio)
        $erros = $processo.StandardError.BaseStream.CopyToAsync([IO.Stream]::Null)
        $saida = [Text.StringBuilder]::new()
        $buffer = [char[]]::new(4096)
        while (($lidos = $processo.StandardOutput.Read($buffer, 0, $buffer.Length)) -gt 0) {
            if ($saida.Length + $lidos -gt 1MB) { return $null }
            $null = $saida.Append($buffer, 0, $lidos)
        }
        $processo.WaitForExit()
        $null = $erros.GetAwaiter().GetResult()
        if ($processo.ExitCode -ne 0) { return $null }
        ConvertFrom-Json -InputObject ($saida.ToString()) -ErrorAction Stop
    }
    catch {
        return $null
    }
    finally {
        if ($processo) {
            try {
                if (-not $processo.HasExited) { $processo.Kill(); $processo.WaitForExit() }
            }
            catch {
                Write-Verbose "Não foi possível encerrar o ffprobe: $($_.Exception.Message)"
            }
            $processo.Dispose()
        }
    }
}

function Get-MetadadosVideo {
    param(
        [string]$caminho,
        [ValidateSet('nenhuma', 'faixas', 'todas')][string]$tags = 'nenhuma'
    )

    $argumentos = @('-v', 'error')
    $campos = 'format=duration:stream=codec_type,duration,avg_frame_rate,r_frame_rate'
    if ($tags -eq 'nenhuma') {
        $argumentos += @('-select_streams', 'V:0')
    }
    else {
        $campos += ':stream_disposition=attached_pic:stream_tags'
        if ($tags -eq 'todas') { $campos += ':format_tags:chapter_tags:program_tags' }
    }
    $dados = Invoke-FfprobeJson ($argumentos + @('-show_entries', $campos, '-of', 'json', $caminho))
    if (-not $dados) { return $null }

    $streams = $dados.PSObject.Properties['streams']
    if (-not $streams -or -not $streams.Value) { return $null }
    $video = $null
    foreach ($fluxo in $streams.Value) {
        $tipo = $fluxo.PSObject.Properties['codec_type']
        if (-not $tipo -or $tipo.Value -ne 'video') { continue }
        $disposicao = $fluxo.PSObject.Properties['disposition']
        if ($disposicao -and $disposicao.Value.attached_pic -eq 1) { continue }
        $video = $fluxo
        break
    }
    if (-not $video) { return $null }
    $formato = $dados.PSObject.Properties['format']
    $duracao = 0.0
    $fps = 0.0
    $cultura = [Globalization.CultureInfo]::InvariantCulture
    $estilo = [Globalization.NumberStyles]::Float

    $duracaoContainer = if ($formato) { $formato.Value.PSObject.Properties['duration'] }
    $duracaoStream = $video.PSObject.Properties['duration']
    foreach ($entrada in @($duracaoContainer, $duracaoStream)) {
        if ($entrada -and [double]::TryParse($entrada.Value, $estilo, $cultura, [ref]$duracao) -and
            $duracao -gt 0 -and $duracao -lt [TimeSpan]::MaxValue.TotalSeconds) { break }
        $duracao = 0.0
    }
    foreach ($chave in @('avg_frame_rate', 'r_frame_rate')) {
        $taxa = $video.PSObject.Properties[$chave]
        if ($taxa -and $taxa.Value -match '^([0-9]+)/([1-9][0-9]*)$') {
            $fps = [double]$matches[1] / [double]$matches[2]
            if ($fps -gt 0) { break }
        }
    }

    [PSCustomObject]@{ Duracao = $duracao; Fps = $fps; Sondagem = $dados }
}

function Get-PropriedadesTags {
    param($elemento)

    if ($null -ne $elemento) {
        $tags = $elemento.PSObject.Properties['tags']
        if ($tags -and $tags.Value) { return $tags.Value.PSObject.Properties }
    }
}

$padraoIdiomaFaixa = '\A[a-z]{2,3}(?:-[a-z0-9]{2,8})*\z'

function Get-ArgumentosLimpezaMetadados {
    param($sondagem, [string]$container)

    # Explicit global scope is required. Unscoped -map_metadata -1 also disables
    # stream metadata copying in FFmpeg. Keep the selected tracks' language tags.
    $argumentos = [Collections.Generic.List[string]]::new()
    $argumentos.AddRange([string[]]@('-hide_banner', '-loglevel', 'error', '-map_metadata:g', '-1', '-map_metadata:c:0', '-1'))
    if ($container -in @('mp4', 'mov')) {
        $argumentos.AddRange([string[]]@('-write_tmcd', '0'))
    }

    $chaves = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($faixa in $sondagem.streams) {
        foreach ($tag in (Get-PropriedadesTags $faixa)) {
            if ($tag.Name -eq 'language' -and $tag.Value -match $padraoIdiomaFaixa) { continue }
            if ($tag.Name -eq 'language') {
                if ($tag.Value -match '[:\\\p{Cc}]') {
                    throw 'Uma faixa contém um idioma inválido que não pode ser removido com segurança.'
                }
                $argumentos.Add("-metadata:s:m:language:$($tag.Value)")
                $argumentos.Add('language=')
                continue
            }
            if ($tag.Name -match '[=\p{Cc}]' -or [string]::IsNullOrWhiteSpace($tag.Name)) {
                throw 'Uma faixa contém uma chave de metadados que não pode ser removida com segurança.'
            }
            if ($chaves.Add($tag.Name)) {
                $argumentos.Add('-metadata:s')
                $argumentos.Add("$($tag.Name)=")
            }
        }
    }
    $argumentos.ToArray()
}

function Test-TagsPermitidas {
    param($elemento, [hashtable]$regras)

    foreach ($tag in (Get-PropriedadesTags $elemento)) {
        $padrao = $regras[$tag.Name]
        if (-not $padrao -or $tag.Value -isnot [string] -or $tag.Value -notmatch $padrao) { return $false }
    }
    return $true
}

function Test-MetadadosLimpos {
    param($sondagem, [string]$container)

    # These tags can be generated by the muxer even when all descriptive tags are removed.
    $formato = @{ encoder = '\ALavf[0-9]+\.[0-9]+\.[0-9]+\z' }
    $faixa = @{
        language = $padraoIdiomaFaixa
        encoder = '\ALavc[0-9]+\.[0-9]+\.[0-9]+(?: [a-z0-9_]+)?\z'
    }
    $capitulo = @{}
    if ($container -in @('mp4', 'mov')) {
        $formato.major_brand = '\A[a-z0-9 ]{4}\z'
        $formato.minor_version = '\A[0-9]{1,10}\z'
        $formato.compatible_brands = '\A(?:[a-z0-9 ]{4}){1,32}\z'
        $faixa.handler_name = '\A(?:VideoHandler|SoundHandler|SubtitleHandler|DataHandler)\z'
        $faixa.vendor_id = '\A(?:FFMP|appl|\[0\]\[0\]\[0\]\[0\])\z'
        $capitulo.title = '\A\z'
    }
    else {
        $faixa.duration = '\A[0-9]+:[0-9]{2}:[0-9]{2}\.[0-9]{1,9}\z'
    }

    $dadosFormato = $sondagem.PSObject.Properties['format']
    if ($dadosFormato -and -not (Test-TagsPermitidas $dadosFormato.Value $formato)) { return $false }
    foreach ($dadosFaixa in $sondagem.streams) {
        if (-not (Test-TagsPermitidas $dadosFaixa $faixa)) { return $false }
    }
    $capitulos = $sondagem.PSObject.Properties['chapters']
    if ($capitulos) {
        foreach ($dadosCapitulo in $capitulos.Value) {
            if (-not (Test-TagsPermitidas $dadosCapitulo $capitulo)) { return $false }
        }
    }
    $programas = $sondagem.PSObject.Properties['programs']
    if ($programas) {
        foreach ($programa in $programas.Value) {
            if (-not (Test-TagsPermitidas $programa @{})) { return $false }
        }
    }
    return $true
}

function Get-BitrateAlvo {
    param(
        [double]$duracaoSegundos,
        [long]$limiteBytes,
        [int]$bitrateAudioKbps = $(if ($ClipSqueezeConfig) { $ClipSqueezeConfig.audio.bitrateKbps } else { 128 }),
        [double]$margemSeguranca = $(if ($ClipSqueezeConfig) { $ClipSqueezeConfig.bitrateCalc.safetyMargin } else { 0.92 }),  # folga pro overhead do container — configurável via bitrateCalc.safetyMargin
        [int]$avisoBitrateBaixoKbps = $(if ($ClipSqueezeConfig) { $ClipSqueezeConfig.bitrateCalc.lowBitrateWarningKbps } else { 300 })
    )

    if ($duracaoSegundos -le 0 -or $limiteBytes -le 0) {
        Write-Host "Duração ou limite inválidos para cálculo de bitrate." -ForegroundColor Red
        return $null
    }

    $bitsTotais = [double]$limiteBytes * 8
    $bitrateTotalKbps = ($bitsTotais / $duracaoSegundos) / 1000
    $orcamentoKbps = $bitrateTotalKbps * $margemSeguranca
    $bitrateVideoKbps = $orcamentoKbps - $bitrateAudioKbps
    $bitrateVideoArredondado = [math]::Round($bitrateVideoKbps)
    $orcamentoMB = [math]::Round(($orcamentoKbps * $duracaoSegundos) / 8 / 1000, 1)

    if ($bitrateVideoArredondado -lt 1) {
        Write-Host "O limite de tamanho é pequeno demais para codificar áudio e vídeo com essa duração." -ForegroundColor Red
        return $null
    }
    # FFmpeg stores the VBV buffer size in a signed 32-bit field, in bits.
    if ($bitrateVideoArredondado -gt [Math]::Floor([int]::MaxValue / 2000.0)) {
        Write-Host "O limite de tamanho gera um bitrate fora do intervalo aceito pelo FFmpeg." -ForegroundColor Red
        return $null
    }

    if ($bitrateVideoKbps -lt $avisoBitrateBaixoKbps) {
        Write-Host "Aviso: bitrate de vídeo calculado ($bitrateVideoArredondado kbps) é bem baixo — a qualidade final pode ficar ruim." -ForegroundColor Yellow
    }

    return [PSCustomObject]@{
        BitrateVideoKbps = $bitrateVideoArredondado
        BitrateAudioKbps = $bitrateAudioKbps
        BitrateTotalKbps = [math]::Round($orcamentoKbps)
        OrcamentoMB      = $orcamentoMB
    }
}

$CodecEncoder = @{
    amd    = @{
        hevc = "hevc_amf"
        h264 = "h264_amf"
        av1  = "av1_amf"
    }
    nvidia = @{
        hevc = "hevc_nvenc"
        h264 = "h264_nvenc"
        av1  = "av1_nvenc"
    }
}

$aceleradoresGpu = @("amd", "nvidia")

$PerfisConfig = @{
    cpu    = @{
        fast      = @{ preset = "veryfast"; crf = 27 }
        balanced  = @{ preset = "medium"; crf = 23 }
        efficient = @{ preset = "veryslow"; crf = 23 }
        quality   = @{ preset = "slow"; crf = 18 }
    }
    amd    = @{
        hevc = @{
            fast      = @{ quality = "speed"; qvbr = 32 }
            balanced  = @{ quality = "balanced"; qvbr = 26 }
            efficient = @{ quality = "quality"; qvbr = 23 }
            quality   = @{ quality = "quality"; qvbr = 18 }
        }
        h264 = @{
            fast      = @{ quality = "speed"; qvbr = 32 }
            balanced  = @{ quality = "balanced"; qvbr = 26 }
            efficient = @{ quality = "quality"; qvbr = 23 }
            quality   = @{ quality = "quality"; qvbr = 18 }
        }
        av1  = @{
            fast      = @{ quality = "speed"; qvbr = 32 }
            balanced  = @{ quality = "balanced"; qvbr = 26 }
            efficient = @{ quality = "quality"; qvbr = 23 }
            quality   = @{ quality = "high_quality"; qvbr = 18 }
        }
    }
    nvidia = @{
        hevc = @{
            fast      = @{ preset = "p2"; cq = 32 }
            balanced  = @{ preset = "p4"; cq = 26 }
            efficient = @{ preset = "p6"; cq = 26 }
            quality   = @{ preset = "p7"; cq = 20 }
        }
        h264 = @{
            fast      = @{ preset = "p2"; cq = 32 }
            balanced  = @{ preset = "p4"; cq = 26 }
            efficient = @{ preset = "p6"; cq = 26 }
            quality   = @{ preset = "p7"; cq = 20 }
        }
        av1  = @{
            fast      = @{ preset = "p2"; cq = 40 }
            balanced  = @{ preset = "p4"; cq = 32 }
            efficient = @{ preset = "p6"; cq = 32 }
            quality   = @{ preset = "p7"; cq = 25 }
        }
    }
}

# profileOverrides do config.json por cima dos perfis hardcoded acima.
# Formato para cpu:        profileOverrides.cpu.<perfil>.<preset|crf>
# Formato para amd/nvidia: profileOverrides.<amd|nvidia>.<codec>.<perfil>.<parametro>
# (um nível a mais, pois amd/nvidia têm o codec no meio). Chaves ausentes
# mantêm o valor hardcoded original.
$PerfisConfig = Merge-ConfigHashtable -Base $PerfisConfig -Override $ClipSqueezeConfig.profileOverrides

$ResolucaoPresets = $ClipSqueezeConfig.resolutionPresets

function Get-FiltroEscalaVideo {
    param([string]$resolucao)

    if ($resolucao) {
        $lado = $ResolucaoPresets[$resolucao]
        $lado -= $lado % 2
        $largura = "if(gte(iw,ih),$lado,-2)"
        $altura = "if(lt(iw,ih),$lado,-2)"
        return "scale=w='$largura':h='$altura'"
    }

    return "scale=w='min(iw,1920)':h='min(ih,1080)':force_original_aspect_ratio=decrease:force_divisible_by=2"
}

function Build-FfmpegArgs {
    param(
        [Parameter(Mandatory = $true)] $parametros,
        [Parameter(Mandatory = $true)] [string]$entrada,
        [Parameter(Mandatory = $true)] [string]$saida,
        [string]$progressFile,
        $bitrateAlvo = $null,
        [string[]]$argsMetadados = @()
    )

    $acelerador = $parametros.Acelerador
    $perfil = $parametros.Perfil
    $codec = $parametros.Codec
    $cultura = [Globalization.CultureInfo]::InvariantCulture
    switch ($acelerador) {
        'cpu' {
            $encoder = 'libx265'
            $config = $PerfisConfig.cpu[$perfil]
            $argsEncoder = @('-preset', $config.preset)
            $argsQualidade = @('-crf', $config.crf.ToString($cultura))
        }
        'amd' {
            $encoder = $CodecEncoder.amd[$codec]
            $config = $PerfisConfig.amd[$codec][$perfil]
            $argsEncoder = @('-quality', $config.quality)
            $argsQualidade = @('-rc', 'qvbr', '-qvbr_quality_level', $config.qvbr)
        }
        'nvidia' {
            $encoder = $CodecEncoder.nvidia[$codec]
            $config = $PerfisConfig.nvidia[$codec][$perfil]
            $argsEncoder = @('-preset', $config.preset, '-rc', 'vbr')
            $argsQualidade = @('-cq', $config.cq.ToString($cultura), '-b:v', '0')
        }
        default { throw "Acelerador inválido: $acelerador" }
    }

    $audioKbps = $ClipSqueezeConfig.audio.bitrateKbps
    if ($null -ne $bitrateAlvo) {
        $audioKbps = $bitrateAlvo.BitrateAudioKbps
        $v = $bitrateAlvo.BitrateVideoKbps
        $argsQualidade = @('-b:v', "${v}k", '-maxrate', "${v}k", '-bufsize', "$($v * 2)k")
        if ($acelerador -eq 'amd') { $argsQualidade = @('-rc', 'vbr_peak') + $argsQualidade }
    }

    $argsSaida = @('-c:a', $ClipSqueezeConfig.audio.codec, '-b:a', "${audioKbps}k", '-y', '-nostats')
    if ($progressFile) { $argsSaida += @('-progress', $progressFile) }

    @('-nostdin', '-i', $entrada, '-vf', (Get-FiltroEscalaVideo $parametros.Resolucao), '-c:v', $encoder) +
        $argsEncoder + $argsQualidade + $argsSaida + $argsMetadados + @($saida)
}

function ConvertTo-WindowsArgumentLine {
    param([string[]]$Arguments)

    # Windows command-line quoting must also escape backslashes next to quotes.
    ($Arguments | ForEach-Object {
        '"' + ($_ -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
    }) -join ' '
}

function Assert-ClipSqueezeOutputDirectory {
    param([string]$Path)

    for ($directory = [IO.DirectoryInfo]::new($Path); $null -ne $directory; $directory = $directory.Parent) {
        $item = Get-Item -LiteralPath $directory.FullName -Force -ErrorAction SilentlyContinue
        if ($item -and (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint))) {
            throw "Pasta de saída inválida ou redirecionada: $($directory.FullName)"
        }
    }
}

function Get-ClipSqueezeOutputFile {
    param([string]$Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($item -and ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint))) {
        throw "A saída não pode substituir um diretório ou link: $Path"
    }
    return $item
}

function Read-FfmpegProgress {
    param([string]$caminho)

    $arquivo = $null
    $leitor = $null
    $valores = @{}
    try {
        $arquivo = [IO.File]::Open($caminho, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        # Read only the latest progress records. The file grows during encoding.
        $inicioCauda = [Math]::Max(0, $arquivo.Length - 4096)
        $null = $arquivo.Seek($inicioCauda, [IO.SeekOrigin]::Begin)
        $leitor = [IO.StreamReader]::new($arquivo)
        if ($inicioCauda -gt 0) { $null = $leitor.ReadLine() }
        $conteudo = $leitor.ReadToEnd()
        foreach ($linha in [regex]::Matches($conteudo, '(?m)^(frame|out_time_us|speed)=([^\r\n]*)\r?\n')) {
            $valores[$linha.Groups[1].Value] = $linha.Groups[2].Value.Trim()
        }
    }
    catch [IO.IOException] {
        # FFmpeg may still be opening the progress file.
    }
    finally {
        if ($leitor) { $leitor.Dispose() }
        if ($arquivo) { $arquivo.Dispose() }
    }
    return $valores
}

function Wait-Compressao {
    param(
        [Diagnostics.Process]$processo,
        [string]$arquivoProgresso,
        [string]$nome,
        $metadados
    )

    if (-not $arquivoProgresso) {
        $processo.WaitForExit()
        return
    }

    $atividade = "Comprimindo $nome"
    $cronometro = [Diagnostics.Stopwatch]::StartNew()
    $duracao = $metadados.Duracao
    $totalFrames = $duracao * $metadados.Fps
    $cultura = [Globalization.CultureInfo]::InvariantCulture
    $largura = $ClipSqueezeConfig.ui.progressBarWidth
    $ultimoPercentual = 0.0
    try {
        while (-not $processo.WaitForExit(500)) {
            $progresso = Read-FfmpegProgress $arquivoProgresso
            $microssegundos = 0L
            $frames = 0L
            if ($duracao -gt 0 -and [long]::TryParse($progresso['out_time_us'], [ref]$microssegundos) -and $microssegundos -gt 0) {
                $fracao = ($microssegundos / 1000000.0) / $duracao
            }
            elseif ($totalFrames -gt 0 -and [long]::TryParse($progresso['frame'], [ref]$frames)) {
                $fracao = $frames / $totalFrames
            }
            else {
                $fracao = $ultimoPercentual / 100
            }

            $ultimoPercentual = [Math]::Max($ultimoPercentual, [Math]::Min(99, $fracao * 100))
            $decorrido = $cronometro.Elapsed.ToString('hh\:mm\:ss')
            $status = "$decorrido decorridos"
            $velocidade = $progresso['speed']
            $velocidadeNumerica = 0.0
            if ($velocidade -match '^([0-9.]+)x$' -and
                [double]::TryParse($matches[1], [Globalization.NumberStyles]::Float, $cultura, [ref]$velocidadeNumerica)) {
                $status += " | $velocidade"
            }
            $restante = 0.0
            if ($duracao -gt 0 -and $velocidadeNumerica -gt 0) {
                $restante = $duracao * (1 - ($ultimoPercentual / 100)) / $velocidadeNumerica
            }
            elseif ($ultimoPercentual -gt 0) {
                $restante = $cronometro.Elapsed.TotalSeconds * (100 / $ultimoPercentual - 1)
            }
            if ($restante -gt 0 -and $restante -lt [TimeSpan]::MaxValue.TotalSeconds) {
                $status += " | restante $([TimeSpan]::FromSeconds($restante).ToString('hh\:mm\:ss'))"
            }

            if ($duracao -gt 0) {
                $preenchido = [int][Math]::Floor($largura * ($ultimoPercentual / 100))
                $barra = ('#' * $preenchido).PadRight($largura, '-')
                $status = "[$barra] $([Math]::Round($ultimoPercentual, 1))% | $status"
            }
            Write-Progress -Activity $atividade -Status $status
        }
    }
    catch {
        Write-Verbose "Painel de progresso indisponível: $($_.Exception.Message)"
        $processo.WaitForExit()
    }
    finally {
        Write-Progress -Activity $atividade -Completed -ErrorAction SilentlyContinue
    }
}

function Show-NotificacaoConclusao {
    param(
        [string]$titulo,
        [string]$mensagem,
        [ValidateSet("Info", "Warning", "Error")]
        [string]$tipo = "Info"
    )
    $notify = $null
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $notify = New-Object System.Windows.Forms.NotifyIcon
        $notify.Icon = [System.Drawing.SystemIcons]::Information
        $notify.Visible = $true
        $notify.ShowBalloonTip(5000, $titulo, $mensagem, [System.Windows.Forms.ToolTipIcon]::$tipo)
        Start-Sleep -Seconds 4
    }
    catch {
        # Notificação é só um extra — se falhar (ex: ambiente sem GUI), o script segue normalmente
    }
    finally {
        if ($notify) { $notify.Dispose() }
    }
}

function Test-ArquivoSaidaValido {
    param(
        [string]$caminho,
        [string]$container,
        [switch]$validarLimpeza
    )

    $arquivo = Get-Item -LiteralPath $caminho -ErrorAction SilentlyContinue
    if (-not $arquivo -or $arquivo.Length -le 0) {
        return [PSCustomObject]@{ Valido = $false; Motivo = 'arquivo não existe ou está vazio' }
    }
    $tags = if ($validarLimpeza) { 'todas' } else { 'nenhuma' }
    $metadados = Get-MetadadosVideo $caminho -tags $tags
    if (-not $metadados) {
        return [PSCustomObject]@{ Valido = $false; Motivo = 'ffprobe não encontrou um vídeo válido no arquivo' }
    }
    if ($metadados.Duracao -le 0) {
        return [PSCustomObject]@{ Valido = $false; Motivo = 'duração inválida ou ausente no arquivo de saída' }
    }
    if ($validarLimpeza -and -not (Test-MetadadosLimpos $metadados.Sondagem $container)) {
        return [PSCustomObject]@{ Valido = $false; Motivo = 'a saída contém tags fora da política de limpeza' }
    }
    return [PSCustomObject]@{ Valido = $true; Motivo = $null }
}

function Resolve-DestinoCompressao {
    param(
        [IO.FileInfo]$item,
        [string]$container,
        [switch]$AutorizarSobrescrita
    )

    $pasta = $item.DirectoryName
    $config = $ClipSqueezeConfig.output
    $pastaSaida = $config.directory
    if ([string]::IsNullOrWhiteSpace($pastaSaida) -or $pastaSaida.Trim() -eq 'source') {
        $pastaSaida = $pasta
    }

    $provedor = $null
    $unidade = $null
    $pastaSaida = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($pastaSaida, [ref]$provedor, [ref]$unidade)
    if ($provedor.Name -ne 'FileSystem') { throw 'A saída precisa estar no sistema de arquivos.' }
    Assert-ClipSqueezeOutputDirectory $pastaSaida
    if (-not [IO.Directory]::Exists($pastaSaida)) {
        [void][IO.Directory]::CreateDirectory($pastaSaida)
        Assert-ClipSqueezeOutputDirectory $pastaSaida
    }

    $saida = [IO.Path]::Combine($pastaSaida, "$($item.BaseName)$($config.suffix).$container")
    if ([string]::Equals($item.FullName, $saida, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'A saída precisa ser diferente do vídeo original.'
    }
    $arquivoExistente = Get-ClipSqueezeOutputFile $saida
    $sobrescrever = $AutorizarSobrescrita -or $config.overwrite
    if ($arquivoExistente -and -not $sobrescrever) {
        Write-Host "Já existe um arquivo comprimido: $saida" -ForegroundColor Yellow
        if ((Read-Host 'Sobrescrever? (s/n)') -ne 's') {
            Write-Host 'Cancelado.'
            return $null
        }
        $sobrescrever = $true
    }

    [PSCustomObject]@{ Caminho = $saida; Pasta = $pastaSaida; Sobrescrever = $sobrescrever }
}

function Compress-Video {
    [CmdletBinding(DefaultParameterSetName = 'Interativo')]
    param(
        [Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'Interativo')]
        [Parameter(Position = 0, ParameterSetName = 'Automatico')]
        [string]$acelerador,
        [Parameter(Mandatory = $true, Position = 1, ParameterSetName = 'Interativo')]
        [Parameter(Position = 1, ParameterSetName = 'Automatico')]
        [string]$arquivo,
        [Parameter(Position = 2)]
        [string]$perfil,
        [Parameter(Position = 3)]
        [string]$limite,
        [string]$container,
        [string]$codec,
        [string]$resolution,
        [ValidateSet('clean', 'preserve')][string]$Metadata,
        [Parameter(Mandatory = $true, ParameterSetName = 'Automatico')]
        [switch]$Force
    )

    # Validate required arguments in automatic mode without triggering Binder prompts.
    if ([string]::IsNullOrWhiteSpace($acelerador) -or [string]::IsNullOrWhiteSpace($arquivo)) {
        throw 'Informe o acelerador e o arquivo de vídeo.'
    }
    if (-not (Test-FFmpegInstalado -NaoInterativo:$Force)) {
        if ($Force) { throw 'FFmpeg e FFprobe precisam estar disponíveis no PATH.' }
        return
    }

    $p = Resolve-ParametrosComprimir -acelerador $acelerador -perfil $perfil -limiteStr $limite -container $container -codec $codec -resolution $resolution -metadata $Metadata
    if ($null -eq $p) {
        if ($Force) { throw 'Parâmetros de compressão inválidos.' }
        return
    }

    $item = Resolve-ArquivoVideo $arquivo
    if ($null -eq $item) {
        if ($Force) { throw 'O arquivo de vídeo não foi encontrado ou é ambíguo.' }
        return
    }

    $sufixoSaida = $ClipSqueezeConfig.output.suffix
    if (-not $Force -and $sufixoSaida -and $item.BaseName -match [regex]::Escape($sufixoSaida) + '$') {
        Write-Host "Esse arquivo já parece ser resultado de uma compressão anterior ($($item.Name))." -ForegroundColor Yellow
        $respostaRecomprimir = Read-Host "Deseja comprimir mesmo assim? (s/n)"
        if ($respostaRecomprimir -ne "s") {
            Write-Host "Cancelado."
            return
        }
    }

    try {
        $destino = Resolve-DestinoCompressao -item $item -container $p.Container -AutorizarSobrescrita:$Force
    }
    catch {
        if ($Force) { throw }
        Write-Host "Não foi possível preparar a saída: $($_.Exception.Message)" -ForegroundColor Red
        return
    }
    if (-not $destino) { return }

    $limparMetadados = $p.Metadata -eq 'clean'
    $tags = if ($limparMetadados) { 'faixas' } else { 'nenhuma' }
    $metadados = Get-MetadadosVideo $item.FullName -tags $tags
    if (-not $metadados) {
        if ($Force) { throw 'Não foi possível ler o vídeo com ffprobe.' }
        Write-Host "Não foi possível ler o vídeo '$($item.FullName)' com ffprobe." -ForegroundColor Red
        return
    }
    $duracao = $metadados.Duracao

    $bitrateAlvo = $null
    if ($p.LimiteBytes) {
        if (-not $duracao) {
            if ($Force) { throw 'Duração inválida para calcular o bitrate.' }
            Write-Host "Não foi possível determinar a duração do vídeo — necessário para calcular o limite de tamanho." -ForegroundColor Red
            return
        }
        $bitrateAlvo = Get-BitrateAlvo -duracaoSegundos $duracao -limiteBytes $p.LimiteBytes
        if ($null -eq $bitrateAlvo) {
            if ($Force) { throw 'Não foi possível calcular um bitrate válido.' }
            return
        }
    }

    $saida = $destino.Caminho
    $pastaSaida = $destino.Pasta
    $temporario = [IO.Path]::Combine($pastaSaida, ".clipsqueeze-$([guid]::NewGuid().ToString('N')).$($p.Container)")
    $exibirProgresso = -not [Console]::IsOutputRedirected -and $ProgressPreference -ne 'SilentlyContinue'
    $progressFile = $null
    $stdoutLog = $null
    $stderrLog = $null
    $reserva = $null
    $proc = $null
    try {
        $argsMetadados = @()
        if ($limparMetadados) {
            $argsMetadados = @(Get-ArgumentosLimpezaMetadados -sondagem $metadados.Sondagem -container $p.Container)
        }
        if ($exibirProgresso) { $progressFile = [IO.Path]::GetTempFileName() }
        $stdoutLog = [IO.Path]::GetTempFileName()
        $stderrLog = [IO.Path]::GetTempFileName()
        # Reserve a new file and deny deletion while FFmpeg writes to it.
        Assert-ClipSqueezeOutputDirectory $pastaSaida
        $reserva = [IO.File]::Open($temporario, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
        $ffmpegArgs = Build-FfmpegArgs -parametros $p -entrada $item.FullName -saida $temporario -progressFile $progressFile -bitrateAlvo $bitrateAlvo -argsMetadados $argsMetadados
        $linhaArgumentos = ConvertTo-WindowsArgumentLine $ffmpegArgs
        if ($linhaArgumentos.Length -gt 30000) { throw 'Os argumentos do FFmpeg ultrapassam o limite compatível com o Windows.' }
        $proc = Start-Process -FilePath "ffmpeg" -ArgumentList $linhaArgumentos -NoNewWindow -PassThru `
            -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog -ErrorAction Stop
        $proc.Handle | Out-Null
        $tamanhoOriginal = $item.Length
        if (-not $exibirProgresso) { Write-Host "Comprimindo $($item.Name)..." }
        Wait-Compressao -processo $proc -arquivoProgresso $progressFile -nome $item.Name -metadados $metadados

        $saidaNome = Split-Path $saida -Leaf

        if ($proc.ExitCode -ne 0) {
            Write-Host "`nErro na compressão (código $($proc.ExitCode))." -ForegroundColor Red

            $conteudoErro = Get-Content $stderrLog -Raw -ErrorAction SilentlyContinue
            $dica = Get-DicaErroConhecido -log $conteudoErro
            if ($dica) {
                Write-Host $dica -ForegroundColor Yellow
            }

            $mensagemNotificacao = "${saidaNome}: falha na compressão."
            if ($ClipSqueezeConfig.logging.keepErrorLogs) {
                $pastaLog = if ($ClipSqueezeConfig.logging.directory) { $ClipSqueezeConfig.logging.directory } else { $item.DirectoryName }
                if (-not (Test-Path $pastaLog -PathType Container)) {
                    New-Item -ItemType Directory -Path $pastaLog -Force -ErrorAction SilentlyContinue | Out-Null
                }
                $logErro = Join-Path $pastaLog "$($item.BaseName)_erro_compressao.log"
                try {
                    [IO.File]::Copy($stderrLog, $logErro, $false)
                    Write-Host "Log completo salvo em: $logErro" -ForegroundColor Yellow
                    $mensagemNotificacao = "${saidaNome}: falha na compressão. Veja o log em $logErro"
                }
                catch {
                    Write-Host "Não foi possível salvar o log em '$logErro': $($_.Exception.Message)" -ForegroundColor Yellow
                }
            }

            if ($ClipSqueezeConfig.notifications.enabled) {
                Show-NotificacaoConclusao -titulo "ClipSqueeze — Erro" -mensagem $mensagemNotificacao -tipo "Error"
            }
            if ($Force) { throw "FFmpeg falhou com código $($proc.ExitCode)." }
            return
        }

        $validacao = Test-ArquivoSaidaValido $temporario -container $p.Container -validarLimpeza:$limparMetadados
        if (-not $validacao.Valido) { throw "O FFmpeg gerou um vídeo inválido: $($validacao.Motivo)" }
        $tamanhoFinal = (Get-Item -LiteralPath $temporario).Length
        $reserva.Dispose()
        Assert-ClipSqueezeOutputDirectory $pastaSaida
        $destinoAtual = Get-ClipSqueezeOutputFile $saida
        if ($destino.Sobrescrever -and $destinoAtual) {
            [IO.File]::Replace($temporario, $saida, [NullString]::Value)
        }
        else {
            [IO.File]::Move($temporario, $saida)
        }
        $reducaoPct = [math]::Round((1 - ($tamanhoFinal / $tamanhoOriginal)) * 100, 1)

        Write-Host ""
        Write-Host "Arquivo: $($item.Name)"
        Write-Host "Acelerador: $($p.Acelerador)"
        Write-Host "Perfil: $($p.Perfil)"
        Write-Host "Limite: $(if ($p.LimiteTexto) { $p.LimiteTexto } else { 'livre' })"
        Write-Host ""
        if ($duracao) { Write-Host "Duração: $([TimeSpan]::FromSeconds($duracao).ToString('mm\:ss'))" }
        if ($bitrateAlvo) {
            Write-Host "Orçamento (após margem de segurança): $($bitrateAlvo.OrcamentoMB) MB"
            Write-Host "Bitrate de vídeo (alvo): $($bitrateAlvo.BitrateVideoKbps) kbps"
            Write-Host "Bitrate de áudio: $($bitrateAlvo.BitrateAudioKbps) kbps"
        }
        Write-Host ""
        Write-Host "Compressão concluída." -ForegroundColor Green
        Write-Host ""
        Write-Host "Tamanho original: $([math]::Round($tamanhoOriginal / 1MB, 1)) MB"
        Write-Host "Tamanho final: $([math]::Round($tamanhoFinal / 1MB, 1)) MB"
        Write-Host "Redução: $reducaoPct%"
        Write-Host "Container: $($p.Container)"
        $codecEfetivo = if ($p.Acelerador -eq 'cpu') { 'hevc' } else { $p.Codec }
        Write-Host "Codec: $codecEfetivo"
        if ($p.Resolucao) { Write-Host "Resolução: $($p.Resolucao.ToUpper())" }
        if ($limparMetadados) { Write-Host 'Metadados: limpeza de tags verificada' }

        if ($ClipSqueezeConfig.notifications.enabled) {
            Show-NotificacaoConclusao -titulo "ClipSqueeze — Concluído" -mensagem "${saidaNome}: $([math]::Round($tamanhoFinal / 1MB, 1)) MB (redução de $reducaoPct%)" -tipo "Info"
        }
    }
    catch {
        if ($Force) { throw }
        Write-Host "Falha ao comprimir ou publicar o vídeo: $($_.Exception.Message)" -ForegroundColor Red
    }
    finally {
        if ($proc) {
            try {
                if (-not $proc.HasExited) {
                    $proc.Kill()
                    $proc.WaitForExit()
                }
            }
            catch {
                Write-Verbose "Não foi possível encerrar o FFmpeg durante a limpeza: $($_.Exception.Message)"
            }
            $proc.Dispose()
        }
        if ($reserva) {
            $reserva.Dispose()
            Remove-Item -LiteralPath $temporario -ErrorAction SilentlyContinue
        }
        foreach ($arquivoTemporario in @($stdoutLog, $stderrLog, $progressFile)) {
            if ($arquivoTemporario) { Remove-Item -LiteralPath $arquivoTemporario -ErrorAction SilentlyContinue }
        }
    }
}

Set-Alias -Name comprimir -Value Compress-Video
