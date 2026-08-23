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
#>

function Install-FFmpegViaWinget {
    Write-Host "Instalando ffmpeg via winget (Gyan.FFmpeg)..." -ForegroundColor Cyan
    winget install --id Gyan.FFmpeg -e --accept-source-agreements --accept-package-agreements
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
    } elseif (-not $ffprobeOk) {
        Write-Host "ffmpeg foi encontrado, mas ffprobe não. Isso normalmente indica uma instalação incompleta (só o executável ffmpeg.exe foi copiado, sem o pacote completo)." -ForegroundColor Red
    } else {
        Write-Host "ffprobe foi encontrado, mas ffmpeg não." -ForegroundColor Red
    }

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host "winget não está disponível neste sistema. Baixe manualmente em: https://www.gyan.dev/ffmpeg/builds/ (pacote 'release full' ou 'essentials')." -ForegroundColor Yellow
        return $false
    }

    $resposta = Read-Host "Deseja instalar o ffmpeg agora via winget (pacote Gyan.FFmpeg)? (s/n)"
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

function Resolve-ParametrosComprimir {
    param(
        [string]$acelerador,
        [string]$perfil = "balanced",
        [string]$limiteStr
    )

    $aceleradoresValidos = @("cpu", "gpu")
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

    $limiteBytes = $null
    if (-not [string]::IsNullOrWhiteSpace($limiteStr)) {
        if ($limiteStr -match '^(\d+(?:[.,]\d+)?)\s*mb$') {
            $valorTexto = $matches[1] -replace ',', '.'
            $valorMb = [double]::Parse($valorTexto, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture)
            if ($valorMb -le 0) {
                Write-Host "Limite deve ser maior que zero: '$limiteStr'" -ForegroundColor Red
                return $null
            }
            $limiteBytes = $valorMb * 1000000
        }
        else {
            Write-Host "Formato de limite inválido: '$limiteStr'. Use algo como '40mb'." -ForegroundColor Red
            return $null
        }
    }

    if ($aceleradorNormalizado -eq "gpu") {
        if (-not (Test-EncoderDisponivel -nome "hevc_amf")) {
            Write-Host "Encoder de GPU (hevc_amf) não disponível neste ffmpeg/sistema. Use 'cpu' ou verifique sua instalação/driver." -ForegroundColor Red
            return $null
        }
    }

    return [PSCustomObject]@{
        Acelerador  = $aceleradorNormalizado
        Perfil      = $perfilNormalizado
        LimiteBytes = $limiteBytes
        LimiteTexto = $limiteStr
    }
}

function Get-DuracaoVideo {
    param([string]$caminho)
    $culturaInvariante = [System.Globalization.CultureInfo]::InvariantCulture
    $estiloNumerico = [System.Globalization.NumberStyles]::Float
    $duracaoStr = ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $caminho
    $duracao = 0
    if (-not [double]::TryParse($duracaoStr, $estiloNumerico, $culturaInvariante, [ref]$duracao) -or $duracao -le 0) {
        return $null
    }
    return $duracao
}

function Get-BitrateAlvo {
    param(
        [double]$duracaoSegundos,
        [long]$limiteBytes,
        [int]$bitrateAudioKbps = 128,
        [double]$margemSeguranca = 0.92   # 8% de folga pro overhead do container
    )

    if ($duracaoSegundos -le 0 -or $limiteBytes -le 0) {
        Write-Host "Duração ou limite inválidos para cálculo de bitrate." -ForegroundColor Red
        return $null
    }

    $bitsTotais = $limiteBytes * 8
    $bitrateTotalKbps = ($bitsTotais / $duracaoSegundos) / 1000
    $orcamentoKbps = $bitrateTotalKbps * $margemSeguranca
    $bitrateVideoKbps = $orcamentoKbps - $bitrateAudioKbps

    if ($bitrateVideoKbps -le 0) {
        Write-Host "O limite de tamanho é pequeno demais pra essa duração (nem o áudio caberia com folga)." -ForegroundColor Red
        return $null
    }

    if ($bitrateVideoKbps -lt 300) {
        Write-Host "Aviso: bitrate de vídeo calculado ($([math]::Round($bitrateVideoKbps)) kbps) é bem baixo — a qualidade final pode ficar ruim." -ForegroundColor Yellow
    }

    return [PSCustomObject]@{
        BitrateVideoKbps = [math]::Round($bitrateVideoKbps)
        BitrateAudioKbps = $bitrateAudioKbps
        BitrateTotalKbps = [math]::Round($orcamentoKbps)
    }
}

$PerfisConfig = @{
    cpu = @{
        fast      = @{ preset = "veryfast"; crf = 27 }
        balanced  = @{ preset = "medium"; crf = 23 }
        efficient = @{ preset = "veryslow"; crf = 23 }
        quality   = @{ preset = "slow"; crf = 18 }
    }
    gpu = @{
        fast      = @{ quality = "speed"; qvbr = 32 }
        balanced  = @{ quality = "balanced"; qvbr = 26 }
        efficient = @{ quality = "quality"; qvbr = 26 }
        quality   = @{ quality = "quality"; qvbr = 20 }
    }
}

function Build-FfmpegArgs {
    param(
        [Parameter(Mandatory = $true)] $parametros,
        [Parameter(Mandatory = $true)] [string]$entrada,
        [Parameter(Mandatory = $true)] [string]$saida,
        [Parameter(Mandatory = $true)] [string]$progressFile,
        $bitrateAlvo = $null
    )

    $config = $PerfisConfig[$parametros.Acelerador][$parametros.Perfil]
    $audioKbps = if ($bitrateAlvo) { $bitrateAlvo.BitrateAudioKbps } else { 128 }

    if ($parametros.Acelerador -eq "cpu") {
        if ($null -eq $bitrateAlvo) {
            $controle = "-crf $($config.crf)"
        }
        else {
            $v = $bitrateAlvo.BitrateVideoKbps
            $controle = "-b:v ${v}k -maxrate ${v}k -bufsize $($v * 2)k"
        }
        return ('-i "{0}" -vf scale=1920:-2 -c:v libx265 -preset {1} {2} -c:a aac -b:a {3}k -y -progress "{4}" -nostats "{5}"' -f `
                $entrada, $config.preset, $controle, $audioKbps, $progressFile, $saida)
    }
    else {
        if ($null -eq $bitrateAlvo) {
            $controle = "-rc qvbr -qvbr_quality_level $($config.qvbr)"
        }
        else {
            $v = $bitrateAlvo.BitrateVideoKbps
            $controle = "-rc vbr_peak -b:v ${v}k -maxrate ${v}k -bufsize $($v * 2)k"
        }
        return ('-i "{0}" -vf scale=1920:-2 -c:v hevc_amf -quality {1} {2} -c:a aac -b:a {3}k -y -progress "{4}" -nostats "{5}"' -f `
                $entrada, $config.quality, $controle, $audioKbps, $progressFile, $saida)
    }
}

function Get-FpsVideo {
    param([string]$caminho)
    $culturaInvariante = [System.Globalization.CultureInfo]::InvariantCulture
    $estiloNumerico = [System.Globalization.NumberStyles]::Float
    $fpsStr = ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 $caminho
    $fps = 0
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
    } catch {
        # Notificação é só um extra — se falhar (ex: ambiente sem GUI), o script segue normalmente
    }
}

function Compress-Video {
    param(
        [Parameter(Mandatory=$true, Position=0)]
        [string]$acelerador,
        [Parameter(Mandatory=$true, Position=1)]
        [string]$arquivo,
        [Parameter(Position=2)]
        [string]$perfil = "balanced",
        [Parameter(Position=3)]
        [string]$limite
    )

    $p = Resolve-ParametrosComprimir -acelerador $acelerador -perfil $perfil -limiteStr $limite
    if ($null -eq $p) { return }

    $item = Resolve-ArquivoVideo $arquivo
    if ($null -eq $item) { return }

    if (-not (Test-FFmpegInstalado)) { return }

    $pasta = $item.DirectoryName
    $nome = $item.BaseName
    $saida = Join-Path $pasta "$($nome)_comprimido.mp4"
    if (Test-Path $saida) {
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

    $argString = Build-FfmpegArgs -parametros $p -entrada $item.FullName -saida $saida -progressFile $progressFile -bitrateAlvo $bitrateAlvo

    $proc = $null
    try {
        $proc = Start-Process -FilePath "ffmpeg" -ArgumentList $argString -NoNewWindow -PassThru `
            -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog -ErrorAction Stop
        $proc.Handle | Out-Null
    } catch {
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

    $linhasPainel = 13
    for ($i = 0; $i -lt $linhasPainel; $i++) { Write-Host "" }
    $topoPainel = [Console]::CursorTop - $linhasPainel

    function Desenhar-PainelComprimir {
        param($percent, $decorrido, $restante, $velocidade)
        $largura = 40
        $preenchido = [math]::Floor($largura * ($percent / 100))
        $barra = ("#" * $preenchido).PadRight($largura, "-")
        $limiteTexto = if ($p.LimiteTexto) { $p.LimiteTexto } else { "livre" }
        $linhas = @(
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
            (" Saída: 1920x-2"),
            "=============================================================",
            ""
        )
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
            $linhaVel = $linhasProg | Where-Object { $_ -match '^speed=\s*([\d\.]+)x' } | Select-Object -Last 1
            if ($linhaVel -match '^speed=\s*([\d\.]+)x') { $velocidade = "$($matches[1])x" }

            $linhaFrame = $linhasProg | Where-Object { $_ -match '^frame=\s*(\d+)' } | Select-Object -Last 1
            if ($linhaFrame -match '^frame=\s*(\d+)') {
                $frameAtual = [double]$matches[1]
                $percent = [math]::Min(100, [math]::Round(($frameAtual / $totalFrames) * 100, 1))

                $segundosDesdeUltimoCalculo = ((Get-Date) - $ultimoCalculo).TotalSeconds
                if ($percent -gt 0 -and ($restante -eq "calculando..." -or $segundosDesdeUltimoCalculo -ge 30)) {
                    $decorridoSeg = ((Get-Date) - $inicio).TotalSeconds
                    $totalEstimadoSeg = $decorridoSeg / ($percent / 100)
                    $restanteSeg = [math]::Max(0, $totalEstimadoSeg - $decorridoSeg)
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

    if (-not ($proc.ExitCode -eq 0 -or $arquivoGerado)) {
        $logErro = Join-Path $pasta "$($nome)_erro_compressao.log"
        Copy-Item $stderrLog $logErro -ErrorAction SilentlyContinue
        Write-Host "`nErro na compressão (código $($proc.ExitCode))." -ForegroundColor Red
        Write-Host "Log completo salvo em: $logErro" -ForegroundColor Yellow
        Show-NotificacaoConclusao -titulo "ClipSqueeze — Erro" -mensagem "$($item.Name): falha na compressão. Veja o log em $logErro" -tipo "Error"
        Remove-Item $stdoutLog, $stderrLog, $progressFile -ErrorAction SilentlyContinue
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
        Write-Host "Bitrate de vídeo (alvo): $($bitrateAlvo.BitrateVideoKbps) kbps"
        Write-Host "Bitrate de áudio: $($bitrateAlvo.BitrateAudioKbps) kbps"
    }
    Write-Host ""
    Write-Host "Compressão concluída." -ForegroundColor Green
    Write-Host ""
    Write-Host "Tamanho original: $([math]::Round($tamanhoOriginal / 1MB, 1)) MB"
    Write-Host "Tamanho final: $([math]::Round($tamanhoFinal / 1MB, 1)) MB"
    Write-Host "Redução: $reducaoPct%"

    Show-NotificacaoConclusao -titulo "ClipSqueeze — Concluído" -mensagem "$($item.Name): $([math]::Round($tamanhoFinal / 1MB, 1)) MB (redução de $reducaoPct%)" -tipo "Info"

    Remove-Item $stdoutLog, $stderrLog, $progressFile -ErrorAction SilentlyContinue
}

Set-Alias -Name comprimir -Value Compress-Video