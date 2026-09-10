<#
    ClipSqueeze
    Compressão de vídeo simplificada via FFmpeg (CPU ou GPU) para PowerShell.

    Comando principal: Compress-Video (segue a convenção Verbo-Substantivo do
    PowerShell, a mesma de Compress-Archive). O alias 'comprimir' funciona
    exatamente igual.

    Uso:
        Compress-Video <acelerador> <arquivo> [perfil] [limite]
        comprimir <acelerador> <arquivo> [perfil] [limite]

    Exemplos:
        comprimir cpu "gravacao_reuniao"
        comprimir gpu "gravacao_reuniao" quality
        comprimir gpu "gravacao_reuniao" efficient 40mb

    Veja o README para detalhes de instalação, perfis disponíveis e como
    o cálculo de limite de tamanho funciona.

    Configuração: se existir um config.json na mesma pasta deste script,
    seus valores sobrescrevem os padrões abaixo (por chave — não precisa
    conter todas). Sem config.json, o comportamento é idêntico ao anterior.
#>

# ============================================================
# Configuração (config.json)
# ============================================================
# Tudo nesta seção é aditivo: se não houver config.json, ou se ele
# estiver incompleto/inválido, o script usa os mesmos valores que
# sempre foram hardcoded — nenhum comportamento muda por padrão.

function ConvertTo-HashtableDeep {
    # Converte recursivamente o objeto retornado por ConvertFrom-Json
    # (PSCustomObject) em Hashtable aninhada, pra podermos fazer merge
    # com os padrões abaixo. Evita depender de 'ConvertFrom-Json -AsHashtable',
    # que só existe no PowerShell 6+ (este script roda em 5.1 também).
    param($InputObject)

    if ($null -eq $InputObject) { return $null }

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

    foreach ($acelerador in @("cpu", "amd", "nvidia")) {
        $origem = $Config.profileOverrides[$acelerador]
        if ($origem -isnot [hashtable]) { continue }

        if ($acelerador -eq "cpu") {
            foreach ($perfil in @("fast", "balanced", "efficient", "quality")) {
                $perfilConfig = $origem[$perfil]
                if ($perfilConfig -isnot [hashtable]) { continue }

                $filtrado = @{}
                foreach ($chave in @("preset", "crf")) {
                    if ($perfilConfig.ContainsKey($chave)) {
                        $filtrado[$chave] = $perfilConfig[$chave]
                    }
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

                foreach ($perfil in @("fast", "balanced", "efficient", "quality")) {
                    $perfilConfig = $codecConfig[$perfil]
                    if ($perfilConfig -isnot [hashtable]) { continue }

                    $permitidos = if ($acelerador -eq "amd") {
                        @("quality", "qvbr")
                    }
                    else {
                        @("preset", "cq")
                    }

                    $filtrado = @{}
                    foreach ($chave in $permitidos) {
                        if ($perfilConfig.ContainsKey($chave)) {
                            $filtrado[$chave] = $perfilConfig[$chave]
                        }
                    }
                    if ($filtrado.Count -gt 0) {
                        $resultado[$acelerador][$codec][$perfil] = $filtrado
                    }
                }
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
            "profileOverrides", "ffmpeg", "notifications", "ui", "logging"
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

    if ($Config.audio.codec -isnot [string] -or [string]::IsNullOrWhiteSpace($Config.audio.codec)) {
        $Config.audio.codec = $Padrao.audio.codec
    }
    if ($Config.audio.bitrateKbps -isnot [int] -or $Config.audio.bitrateKbps -le 0) {
        $Config.audio.bitrateKbps = $Padrao.audio.bitrateKbps
    }

    if ($Config.bitrateCalc.safetyMargin -isnot [double] -or
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
            $Config.resolutionPresets[$chave] -le 0) {
            $Config.resolutionPresets[$chave] = $Padrao.resolutionPresets[$chave]
        }
    }

    if ($Config.ffmpeg.packageId -isnot [string] -or [string]::IsNullOrWhiteSpace($Config.ffmpeg.packageId)) {
        $Config.ffmpeg.packageId = $Padrao.ffmpeg.packageId
    }

    if ($Config.notifications.enabled -isnot [bool]) {
        $Config.notifications.enabled = $Padrao.notifications.enabled
    }

    if ($Config.ui.progressBarWidth -isnot [int] -or $Config.ui.progressBarWidth -lt 10) {
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

    if (-not (Test-Path $caminho -PathType Leaf)) {
        return $configPadrao
    }

    try {
        $jsonTexto = Get-Content -Path $caminho -Raw -ErrorAction Stop
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
    $ffmpegOk = [bool](Get-Command ffmpeg -ErrorAction SilentlyContinue)
    $ffprobeOk = [bool](Get-Command ffprobe -ErrorAction SilentlyContinue)

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
    if ((Get-Command ffmpeg -ErrorAction SilentlyContinue) -and (Get-Command ffprobe -ErrorAction SilentlyContinue)) {
        Write-Host "ffmpeg instalado e pronto para uso." -ForegroundColor Green
        return $true
    }

    Write-Host "Instalado, mas este terminal não reconheceu o PATH automaticamente. Feche e reabra o terminal, depois rode o comando novamente." -ForegroundColor Yellow
    return $false
}

function Resolve-ArquivoVideo {
    param([string]$arquivo)

    # Se o caminho já existe exatamente como foi passado (com extensão), usa direto
    if (Test-Path $arquivo -PathType Leaf) {
        return Get-Item $arquivo
    }

    # Extensões de vídeo que vamos tentar
    $extensoes = @("mp4", "mkv", "mov", "avi", "webm", "wmv", "flv", "m4v")

    $pasta = Split-Path $arquivo -Parent
    if ([string]::IsNullOrEmpty($pasta)) { $pasta = "." }
    $nomeBase = Split-Path $arquivo -Leaf

    $candidatos = @()
    foreach ($ext in $extensoes) {
        $tentativa = Join-Path $pasta "$nomeBase.$ext"
        if (Test-Path $tentativa -PathType Leaf) {
            $candidatos += Get-Item $tentativa
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
        [string]$resolution
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
        if ($limiteStr -match '^(\d+(?:[.,]\d+)?)\s*mb$') {
            $valorTexto = $matches[1] -replace ',', '.'
            $valorMb = [double]::Parse($valorTexto, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture)
            if ($valorMb -le 0) {
                Write-Host "Limite deve ser maior que zero: '$limiteStr'" -ForegroundColor Red
                return $null
            }
            # MB decimal (1 MB = 1.000.000 bytes) — mesma convenção usada pela maioria
            # dos serviços de upload/redes sociais. Não é MiB (1.048.576 bytes).
            $limiteBytes = $valorMb * 1000000
        }
        else {
            Write-Host "Formato de limite inválido: '$limiteStr'. Use algo como '40mb'." -ForegroundColor Red
            return $null
        }
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
    }
}

function Get-DuracaoVideo {
    param([string]$caminho)
    $culturaInvariante = [System.Globalization.CultureInfo]::InvariantCulture
    $estiloNumerico = [System.Globalization.NumberStyles]::Float
    $duracaoStr = ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $caminho 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ffprobe falhou ao ler a duração de '$caminho' (código $LASTEXITCODE): $duracaoStr" -ForegroundColor Red
        return $null
    }
    $duracao = 0
    if (-not [double]::TryParse($duracaoStr, $estiloNumerico, $culturaInvariante, [ref]$duracao) -or $duracao -le 0) {
        Write-Host "ffprobe não retornou uma duração válida para '$caminho'." -ForegroundColor Red
        return $null
    }
    return $duracao
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

    $bitsTotais = $limiteBytes * 8
    $bitrateTotalKbps = ($bitsTotais / $duracaoSegundos) / 1000
    $orcamentoKbps = $bitrateTotalKbps * $margemSeguranca
    $bitrateVideoKbps = $orcamentoKbps - $bitrateAudioKbps
    $orcamentoMB = [math]::Round(($orcamentoKbps * $duracaoSegundos) / 8 / 1000, 1)

    if ($bitrateVideoKbps -le 0) {
        Write-Host "O limite de tamanho é pequeno demais pra essa duração (nem o áudio caberia com folga)." -ForegroundColor Red
        return $null
    }

    if ($bitrateVideoKbps -lt $avisoBitrateBaixoKbps) {
        Write-Host "Aviso: bitrate de vídeo calculado ($([math]::Round($bitrateVideoKbps)) kbps) é bem baixo — a qualidade final pode ficar ruim." -ForegroundColor Yellow
    }

    return [PSCustomObject]@{
        BitrateVideoKbps = [math]::Round($bitrateVideoKbps)
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

function Build-FfmpegArgs {
    param(
        [Parameter(Mandatory = $true)] $parametros,
        [Parameter(Mandatory = $true)] [string]$entrada,
        [Parameter(Mandatory = $true)] [string]$saida,
        [Parameter(Mandatory = $true)] [string]$progressFile,
        $bitrateAlvo = $null
    )

    $audioKbps = if ($bitrateAlvo) { $bitrateAlvo.BitrateAudioKbps } else { $ClipSqueezeConfig.audio.bitrateKbps }
    $audioCodec = $ClipSqueezeConfig.audio.codec

    if ($parametros.Resolucao) {
        $lado = $ResolucaoPresets[$parametros.Resolucao]
        $filtroEscalaCpu = "scale=w='if(gte(iw,ih),${lado},-2)':h='if(lt(iw,ih),${lado},-2)'"
    }
    else {
        $filtroEscalaCpu = "scale=w=1920:h=1080:force_original_aspect_ratio=decrease:force_divisible_by=2"
    }

    # AMD:
    # Decodifica em D3D11, baixa os frames para a memória do sistema,
    # escala usando o filtro CPU e envia novamente para D3D11 antes do
    # encode via AMF.
    if ($parametros.Acelerador -eq "amd") {
        $encoder = $CodecEncoder.amd[$parametros.Codec]
        $config = $PerfisConfig.amd[$parametros.Codec][$parametros.Perfil]

        if ($parametros.Resolucao) {
            $lado = $ResolucaoPresets[$parametros.Resolucao]
            $filtroEscalaGpu = "hwdownload,format=nv12,scale=w='if(gte(iw,ih),${lado},-2)':h='if(lt(iw,ih),${lado},-2)',format=nv12,hwupload"
        }
        else {
            $filtroEscalaGpu = "hwdownload,format=nv12,scale=w=1920:h=1080:force_original_aspect_ratio=decrease:force_divisible_by=2,format=nv12,hwupload"
        }

        $argsBase = @(
            "-init_hw_device", "d3d11va=amd",
            "-filter_hw_device", "amd",
            "-hwaccel", "d3d11va",
            "-hwaccel_output_format", "d3d11",
            "-extra_hw_frames", "32",
            "-i", "`"$entrada`"",
            "-vf", $filtroEscalaGpu
        )

        $argsCodec = if ($null -eq $bitrateAlvo) {
            @(
                "-c:v", $encoder,
                "-quality", $config.quality,
                "-rc", "qvbr",
                "-qvbr_quality_level", $config.qvbr
            )
        }
        else {
            $v = $bitrateAlvo.BitrateVideoKbps

            @(
                "-c:v", $encoder,
                "-quality", $config.quality,
                "-rc", "vbr_peak",
                "-b:v", "${v}k",
                "-maxrate", "${v}k",
                "-bufsize", "$($v * 2)k"
            )
        }

        return $argsBase + $argsCodec + @(
            "-c:a", $audioCodec,
            "-b:a", "${audioKbps}k",
            "-y",
            "-progress", "`"$progressFile`"",
            "-nostats",
            "`"$saida`""
        )
    }

    # CPU continua usando o pipeline original.
    if ($parametros.Acelerador -eq "cpu") {
        $argsBase = @(
            "-i", "`"$entrada`"",
            "-vf", $filtroEscalaCpu
        )

        $config = $PerfisConfig.cpu[$parametros.Perfil]

        $argsCodec = if ($null -eq $bitrateAlvo) {
            @(
                "-c:v", "libx265",
                "-preset", $config.preset,
                "-crf", $config.crf
            )
        }
        else {
            $v = $bitrateAlvo.BitrateVideoKbps

            @(
                "-c:v", "libx265",
                "-preset", $config.preset,
                "-b:v", "${v}k",
                "-maxrate", "${v}k",
                "-bufsize", "$($v * 2)k"
            )
        }

        return $argsBase + $argsCodec + @(
            "-c:a", $audioCodec,
            "-b:a", "${audioKbps}k",
            "-y",
            "-progress", "`"$progressFile`"",
            "-nostats",
            "`"$saida`""
        )
    }

    # NVIDIA continua usando o pipeline original.
    $encoder = $CodecEncoder.nvidia[$parametros.Codec]
    $config = $PerfisConfig.nvidia[$parametros.Codec][$parametros.Perfil]

    $argsBase = @(
        "-i", "`"$entrada`"",
        "-vf", $filtroEscalaCpu
    )

    $argsCodec = if ($null -eq $bitrateAlvo) {
        @(
            "-c:v", $encoder,
            "-preset", $config.preset,
            "-rc", "vbr",
            "-cq", $config.cq,
            "-b:v", "0"
        )
    }
    else {
        $v = $bitrateAlvo.BitrateVideoKbps

        @(
            "-c:v", $encoder,
            "-preset", $config.preset,
            "-rc", "vbr",
            "-b:v", "${v}k",
            "-maxrate", "${v}k",
            "-bufsize", "$($v * 2)k"
        )
    }

    return $argsBase + $argsCodec + @(
        "-c:a", $audioCodec,
        "-b:a", "${audioKbps}k",
        "-y",
        "-progress", "`"$progressFile`"",
        "-nostats",
        "`"$saida`""
    )
}

function Get-FpsVideo {
    param([string]$caminho)
    $culturaInvariante = [System.Globalization.CultureInfo]::InvariantCulture
    $estiloNumerico = [System.Globalization.NumberStyles]::Float
    $fpsStr = ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 $caminho 2>&1
    $fps = 0
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ffprobe falhou ao ler o fps de '$caminho' (código $LASTEXITCODE): $fpsStr" -ForegroundColor Red
        return 0
    }
    if ($fpsStr -match '^(\d+)/(\d+)$') {
        $num = [double]::Parse($matches[1], $estiloNumerico, $culturaInvariante)
        $den = [double]::Parse($matches[2], $estiloNumerico, $culturaInvariante)
        if ($den -gt 0) { $fps = $num / $den }
    }
    else {
        [double]::TryParse($fpsStr, $estiloNumerico, $culturaInvariante, [ref]$fps) | Out-Null
    }
    return $fps
}

function Read-ProgressTail {
    param([string]$path)
    try {
        $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $sr = New-Object System.IO.StreamReader($fs)
        $conteudo = $sr.ReadToEnd()
        $sr.Close(); $fs.Close()
        return $conteudo -split "`r?`n"
    }
    catch {
        return @()
    }
}

function Show-NotificacaoConclusao {
    param(
        [string]$titulo,
        [string]$mensagem,
        [ValidateSet("Info", "Warning", "Error")]
        [string]$tipo = "Info"
    )
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $notify = New-Object System.Windows.Forms.NotifyIcon
        $notify.Icon = [System.Drawing.SystemIcons]::Information
        $notify.Visible = $true
        $notify.ShowBalloonTip(5000, $titulo, $mensagem, [System.Windows.Forms.ToolTipIcon]::$tipo)
        Start-Sleep -Seconds 4
        $notify.Dispose()
    }
    catch {
        # Notificação é só um extra — se falhar (ex: ambiente sem GUI), o script segue normalmente
    }
}

function Test-ArquivoSaidaValido {
    # Validação mínima pós-compressão: o ffmpeg pode retornar ExitCode 0 e ainda
    # assim deixar um arquivo truncado/inválido em casos raros. Esta função não
    # confere codec/resolução esperados (isso é responsabilidade de quem chamou
    # o ffmpeg, já sabemos o que foi pedido) — só confirma que existe um vídeo
    # de verdade e abrível no caminho de saída.
    param([string]$caminho)

    if (-not (Test-Path $caminho -PathType Leaf) -or (Get-Item $caminho).Length -le 0) {
        return [PSCustomObject]@{ Valido = $false; Motivo = "arquivo não existe ou está vazio" }
    }

    $saidaFfprobe = ffprobe -v error -select_streams v:0 -show_entries "stream=codec_type:format=duration" -of default=noprint_wrappers=1 $caminho 2>&1
    if ($LASTEXITCODE -ne 0) {
        return [PSCustomObject]@{ Valido = $false; Motivo = "ffprobe não conseguiu abrir o arquivo ($saidaFfprobe)" }
    }

    if (-not ($saidaFfprobe -match "codec_type=video")) {
        return [PSCustomObject]@{ Valido = $false; Motivo = "nenhum stream de vídeo encontrado no arquivo de saída" }
    }

    $linhaDuracao = $saidaFfprobe | Where-Object { $_ -match "^duration=([\d\.]+)" } | Select-Object -Last 1
    $duracaoValida = $linhaDuracao -match "^duration=([\d\.]+)" -and [double]$matches[1] -gt 0
    if (-not $duracaoValida) {
        return [PSCustomObject]@{ Valido = $false; Motivo = "duração inválida ou ausente no arquivo de saída" }
    }

    return [PSCustomObject]@{ Valido = $true; Motivo = $null }
}

function Compress-Video {
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$acelerador,
        [Parameter(Mandatory = $true, Position = 1)]
        [string]$arquivo,
        [Parameter(Position = 2)]
        [string]$perfil,
        [Parameter(Position = 3)]
        [string]$limite,
        [string]$container,
        [string]$codec,
        [string]$resolution
    )

    if (-not (Test-FFmpegInstalado)) { return }

    $p = Resolve-ParametrosComprimir -acelerador $acelerador -perfil $perfil -limiteStr $limite -container $container -codec $codec -resolution $resolution
    if ($null -eq $p) { return }

    $item = Resolve-ArquivoVideo $arquivo
    if ($null -eq $item) { return }

    $sufixoSaida = $ClipSqueezeConfig.output.suffix
    if ($sufixoSaida -and $item.BaseName -match [regex]::Escape($sufixoSaida) + '$') {
        Write-Host "Esse arquivo já parece ser resultado de uma compressão anterior ($($item.Name))." -ForegroundColor Yellow
        $respostaRecomprimir = Read-Host "Deseja comprimir mesmo assim? (s/n)"
        if ($respostaRecomprimir -ne "s") {
            Write-Host "Cancelado."
            return
        }
    }

    $pasta = $item.DirectoryName
    $nome = $item.BaseName

    $dirConfigurado = $ClipSqueezeConfig.output.directory
    $pastaSaida = if ([string]::IsNullOrWhiteSpace($dirConfigurado) -or $dirConfigurado.Trim().ToLower() -eq "source") {
        $pasta
    }
    else {
        $dirConfigurado
    }
    if (-not (Test-Path $pastaSaida -PathType Container)) {
        try {
            New-Item -ItemType Directory -Path $pastaSaida -Force -ErrorAction Stop | Out-Null
        }
        catch {
            Write-Host "Não foi possível criar a pasta de saída configurada ('$pastaSaida'): $($_.Exception.Message)" -ForegroundColor Red
            return
        }
    }

    $saida = Join-Path $pastaSaida "$($nome)$($sufixoSaida).$($p.Container)"
    if ((Test-Path $saida) -and -not $ClipSqueezeConfig.output.overwrite) {
        Write-Host "Já existe um arquivo comprimido: $saida" -ForegroundColor Yellow
        $resposta = Read-Host "Sobrescrever? (s/n)"
        if ($resposta -ne "s") {
            Write-Host "Cancelado."
            return
        }
    }

    $duracao = Get-DuracaoVideo -caminho $item.FullName
    $fps = Get-FpsVideo -caminho $item.FullName
    $totalFrames = 0
    if ($duracao -and $fps -gt 0) { $totalFrames = [math]::Round($duracao * $fps) }

    $bitrateAlvo = $null
    if ($p.LimiteBytes) {
        if (-not $duracao) {
            Write-Host "Não foi possível determinar a duração do vídeo — necessário para calcular o limite de tamanho." -ForegroundColor Red
            return
        }
        $bitrateAlvo = Get-BitrateAlvo -duracaoSegundos $duracao -limiteBytes $p.LimiteBytes
        if ($null -eq $bitrateAlvo) { return }
    }

    $progressFile = [System.IO.Path]::GetTempFileName()
    $stdoutLog = [System.IO.Path]::GetTempFileName()
    $stderrLog = [System.IO.Path]::GetTempFileName()

    $ffmpegArgs = Build-FfmpegArgs -parametros $p -entrada $item.FullName -saida $saida -progressFile $progressFile -bitrateAlvo $bitrateAlvo

    $proc = $null
    try {
        $proc = Start-Process -FilePath "ffmpeg" -ArgumentList $ffmpegArgs -NoNewWindow -PassThru `
            -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog -ErrorAction Stop
        $proc.Handle | Out-Null
    }
    catch {
        Write-Host "Falha ao iniciar o ffmpeg: $($_.Exception.Message)" -ForegroundColor Red
        Remove-Item $progressFile, $stdoutLog, $stderrLog -ErrorAction SilentlyContinue
        return
    }
    if ($null -eq $proc -or $proc.Id -eq 0) {
        Write-Host "O processo do ffmpeg não iniciou corretamente." -ForegroundColor Red
        Remove-Item $progressFile, $stdoutLog, $stderrLog -ErrorAction SilentlyContinue
        return
    }

    $tamanhoOriginal = $item.Length
    $inicio = Get-Date

    try {
        function Build-LinhasPainel {
            param($percent, $decorrido, $restante, $velocidade)
            $largura = $ClipSqueezeConfig.ui.progressBarWidth
            $preenchido = [math]::Floor($largura * ($percent / 100))
            $barra = ("#" * $preenchido).PadRight($largura, "-")
            $limiteTexto = if ($p.LimiteTexto) { $p.LimiteTexto } else { "livre" }
            $saidaTexto = if ($p.Resolucao) { "$($p.Resolucao.ToUpper()) (upscale/downscale conforme necessário)" } else { "até 1920x1080 (sem upscale)" }
            return @(
                "=============================================",
                " Previsão de compressão",
                "=============================================",
                (" Tempo decorrido : {0}" -f $decorrido),
                (" Tempo restante  : {0}" -f $restante),
                (" Velocidade      : {0}" -f $velocidade),
                "",
                (" Progresso: [{0}] {1}%" -f $barra, $percent),
                "",
                (" Acelerador: $($p.Acelerador) | Perfil: $($p.Perfil) | Limite: $limiteTexto"),
                (" Codec: $($p.Codec) | Container: $($p.Container)"),
                (" Saída: $saidaTexto"),
                "=============================================================",
                ""
            )
        }

        $linhasPainel = (Build-LinhasPainel -percent 0 -decorrido "" -restante "" -velocidade "").Count
        for ($i = 0; $i -lt $linhasPainel; $i++) { Write-Host "" }
        $topoPainel = [Console]::CursorTop - $linhasPainel

        function Desenhar-PainelComprimir {
            param($percent, $decorrido, $restante, $velocidade)
            $linhas = Build-LinhasPainel -percent $percent -decorrido $decorrido -restante $restante -velocidade $velocidade
            [Console]::SetCursorPosition(0, $topoPainel)
            foreach ($linha in $linhas) {
                Write-Host $linha.PadRight([Console]::WindowWidth - 1)
            }
        }
    

        $restante = "calculando..."
        $ultimoCalculo = $inicio
        $percent = 0

        while (-not $proc.HasExited) {
            Start-Sleep -Milliseconds 500
            $velocidade = "--"
            $decorrido = ((Get-Date) - $inicio).ToString("hh\:mm\:ss")

            if ($totalFrames -gt 0 -and (Test-Path $progressFile)) {
                $linhasProg = Read-ProgressTail -path $progressFile

                $velocidadeNum = 0
                $linhaVel = $linhasProg | Where-Object { $_ -match '^speed=\s*([\d\.]+)x' } | Select-Object -Last 1
                if ($linhaVel -match '^speed=\s*([\d\.]+)x') {
                    $velocidadeNum = [double]$matches[1]
                    $velocidade = "$($matches[1])x"
                }

                $linhaFrame = $linhasProg | Where-Object { $_ -match '^frame=\s*(\d+)' } | Select-Object -Last 1
                if ($linhaFrame -match '^frame=\s*(\d+)') {
                    $frameAtual = [double]$matches[1]
                    $percent = [math]::Min(100, [math]::Round(($frameAtual / $totalFrames) * 100, 1))

                    $segundosDesdeUltimoCalculo = ((Get-Date) - $ultimoCalculo).TotalSeconds
                    if ($percent -gt 0 -and ($restante -eq "calculando..." -or $segundosDesdeUltimoCalculo -ge 5)) {
                        if ($velocidadeNum -gt 0 -and $duracao) {
                            $segundosRestantesDeVideo = $duracao * (1 - ($percent / 100))
                            $restanteSeg = [math]::Max(0, $segundosRestantesDeVideo / $velocidadeNum)
                        }
                        else {
                            $decorridoSeg = ((Get-Date) - $inicio).TotalSeconds
                            $totalEstimadoSeg = $decorridoSeg / ($percent / 100)
                            $restanteSeg = [math]::Max(0, $totalEstimadoSeg - $decorridoSeg)
                        }
                        $ts = [TimeSpan]::FromSeconds($restanteSeg)
                        $restante = "$($ts.Hours)h $($ts.Minutes)m $($ts.Seconds)s" -replace "^0h ", ""
                        $ultimoCalculo = Get-Date
                    }
                }
            }

            Desenhar-PainelComprimir -percent $percent -decorrido $decorrido -restante $restante -velocidade $velocidade
        }

        $proc.WaitForExit()
        $duracaoTotal = ((Get-Date) - $inicio).ToString("hh\:mm\:ss")
        Desenhar-PainelComprimir -percent 100 -decorrido $duracaoTotal -restante "concluído" -velocidade "--"

        $arquivoGerado = (Test-Path $saida) -and ((Get-Item $saida).Length -gt 0)
        $saidaNome = Split-Path $saida -Leaf

        if (-not ($proc.ExitCode -eq 0 -or $arquivoGerado)) {
            Write-Host "`nErro na compressão (código $($proc.ExitCode))." -ForegroundColor Red

            $conteudoErro = Get-Content $stderrLog -Raw -ErrorAction SilentlyContinue
            $dica = Get-DicaErroConhecido -log $conteudoErro
            if ($dica) {
                Write-Host $dica -ForegroundColor Yellow
            }

            $mensagemNotificacao = "${saidaNome}: falha na compressão."
            if ($ClipSqueezeConfig.logging.keepErrorLogs) {
                $pastaLog = if ($ClipSqueezeConfig.logging.directory) { $ClipSqueezeConfig.logging.directory } else { $pasta }
                if (-not (Test-Path $pastaLog -PathType Container)) {
                    New-Item -ItemType Directory -Path $pastaLog -Force -ErrorAction SilentlyContinue | Out-Null
                }
                $logErro = Join-Path $pastaLog "$($nome)_erro_compressao.log"
                Copy-Item $stderrLog $logErro -ErrorAction SilentlyContinue
                Write-Host "Log completo salvo em: $logErro" -ForegroundColor Yellow
                $mensagemNotificacao = "${saidaNome}: falha na compressão. Veja o log em $logErro"
            }

            if ($ClipSqueezeConfig.notifications.enabled) {
                Show-NotificacaoConclusao -titulo "ClipSqueeze — Erro" -mensagem $mensagemNotificacao -tipo "Error"
            }
            return
        }

        $tamanhoFinal = (Get-Item $saida).Length
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
        if ($aceleradoresGpu -contains $p.Acelerador) { Write-Host "Codec: $($p.Codec)" }
        if ($p.Resolucao) { Write-Host "Resolução: $($p.Resolucao.ToUpper())" }

        if ($ClipSqueezeConfig.notifications.enabled) {
            Show-NotificacaoConclusao -titulo "ClipSqueeze — Concluído" -mensagem "${saidaNome}: $([math]::Round($tamanhoFinal / 1MB, 1)) MB (redução de $reducaoPct%)" -tipo "Info"
        }
    }
    finally {
        Remove-Item $stdoutLog, $stderrLog, $progressFile -ErrorAction SilentlyContinue
    }
}

Set-Alias -Name comprimir -Value Compress-Video