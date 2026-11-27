#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Get-Command ffmpeg, ffprobe -CommandType Application -ErrorAction Stop | Out-Null
$fixture = New-Item -Path (Join-Path ([IO.Path]::GetTempPath()) "ClipSqueeze test $([guid]::NewGuid())") -ItemType Directory

try {
    $configDirectory = Join-Path $fixture.FullName '[config]'
    [void][IO.Directory]::CreateDirectory($configDirectory)
    $configFile = Join-Path $configDirectory 'config.json'
    [IO.File]::WriteAllText($configFile, '{"metadata":{"mode":"preserve"},"output":{"suffix":"_custom"}}')
    $inputPath = Join-Path $fixture.FullName 'test [video].mp4'
    & ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i 'testsrc2=size=320x180:rate=24' -f lavfi -i 'sine=frequency=440:sample_rate=48000' -t 2 -c:v mpeg4 -c:a aac $inputPath
    if ($LASTEXITCODE -ne 0) { throw "Failed to generate test video (exit $LASTEXITCODE)." }

    $scriptPath = Join-Path $fixture.FullName 'ClipSqueeze.ps1'
    Copy-Item -LiteralPath (Join-Path $root 'ClipSqueeze.ps1') -Destination $scriptPath
    @{
        notifications = @{ enabled = $false }
        output = @{ suffix = '_test' }
        resolutionPresets = @{ hd = 160; fhd = 241 }
        bitrateCalc = @{ safetyMargin = 0.90 }
        audio = @{ codec = 'aac extra marker' }
        profileOverrides = @{
            cpu = @{ fast = @{ preset = 'fast extra marker'; crf = 52 } }
            amd = @{ hevc = @{ fast = @{ quality = 'balanced'; qvbr = 30 } } }
            nvidia = @{ hevc = @{ fast = @{ preset = 'p3'; cq = 30.5 } } }
        }
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $fixture.FullName 'config.json') -Encoding Ascii
    . $scriptPath
    $loadedConfig = Get-ClipSqueezeConfig $configFile
    if ($loadedConfig.metadata.mode -ne 'preserve' -or $loadedConfig.output.suffix -ne '_custom') {
        throw 'Configuration in a path with brackets was ignored.'
    }
    if ($ClipSqueezeConfig.audio.codec -ne 'aac' -or $PerfisConfig.cpu.fast.preset -ne 'veryfast' -or $PerfisConfig.cpu.fast.crf -ne 27) {
        throw 'Invalid codec, preset or CRF survived configuration validation.'
    }
    if ($PerfisConfig.amd.hevc.fast.quality -ne 'balanced' -or $PerfisConfig.amd.hevc.fast.qvbr -ne 30 -or
        $PerfisConfig.nvidia.hevc.fast.preset -ne 'p3' -or $PerfisConfig.nvidia.hevc.fast.cq -ne 30.5) {
        throw 'Valid GPU profile overrides were not preserved.'
    }
    if ([double]$ClipSqueezeConfig.bitrateCalc.safetyMargin -ne 0.9) {
        throw 'Configured safety margin was not preserved.'
    }

    $nvidiaParameters = @{ Acelerador = 'nvidia'; Perfil = 'fast'; Codec = 'hevc'; Resolucao = 'hd' }
    $nvidiaArgs = @(Build-FfmpegArgs -parametros $nvidiaParameters -entrada $inputPath -saida $inputPath)
    $filtroNvidia = $nvidiaArgs[([array]::IndexOf($nvidiaArgs, '-vf') + 1)]
    $filtroCpu = Get-FiltroEscalaVideo 'hd'
    if ($nvidiaArgs -notcontains 'hevc_nvenc' -or $filtroNvidia -ne $filtroCpu -or $nvidiaArgs -contains '-progress') {
        throw 'NVIDIA did not use the shared resolution filter or headless options.'
    }
    $amdParameters = @{ Acelerador = 'amd'; Perfil = 'fast'; Codec = 'hevc'; Resolucao = 'hd' }
    $amdArgs = @(Build-FfmpegArgs -parametros $amdParameters -entrada $inputPath -saida $inputPath)
    if ($amdArgs -notcontains 'hevc_amf' -or $amdArgs[([array]::IndexOf($amdArgs, '-vf') + 1)] -ne $filtroCpu) {
        throw 'AMD did not use the shared resolution filter or the AMF encoder.'
    }
    $metadata = Get-MetadadosVideo $inputPath
    if ($metadata.Fps -ne 24 -or [Math]::Abs($metadata.Duracao - 2) -gt 0.15) {
        throw 'The input metadata probe did not return the expected duration and frame rate.'
    }
    $invalidInput = Join-Path $fixture.FullName 'invalid-input.mp4'
    [IO.File]::WriteAllText($invalidInput, 'not a video')
    if (Get-MetadadosVideo $invalidInput) { throw 'The input probe accepted a non-video file.' }
    if ((Resolve-ParametrosComprimir -acelerador cpu -limiteStr '0,15mb').LimiteBytes -ne 150000 -or
        (Resolve-ParametrosComprimir -acelerador cpu -limiteStr '100000000000000000000000000000000mb') -or
        (Get-BitrateAlvo -duracaoSegundos 100 -limiteBytes 1602500 -margemSeguranca 1 -bitrateAudioKbps 128)) {
        throw 'Bitrate limits were not validated.'
    }

    $progressPath = Join-Path $fixture.FullName 'progress.txt'
    [IO.File]::WriteAllText($progressPath, ("frame=1`n" * 1000) + "frame=120`nout_time_us=5000000`nspeed=1.5x`nframe=999")
    $progress = Read-FfmpegProgress $progressPath
    if ($progress['frame'] -ne '120' -or $progress['out_time_us'] -ne '5000000' -or $progress['speed'] -ne '1.5x') {
        throw 'The progress reader lost complete records or used an incomplete line.'
    }

    $cases = @(
        @{ Arguments = @{ container = 'mkv'; resolution = 'hd' }; Extension = 'mkv'; MaxBytes = $null }
        @{ Arguments = @{ container = 'mp4'; resolution = 'hd'; limite = '0.15mb' }; Extension = 'mp4'; MaxBytes = 150000 }
    )
    foreach ($case in $cases) {
        $arguments = $case.Arguments
        comprimir cpu (Join-Path $fixture.FullName 'test [video]') fast @arguments

        $output = Get-Item -LiteralPath (Join-Path $fixture.FullName "test [video]_test.$($case.Extension)")
        $metadataJson = & ffprobe -v error -show_entries 'stream=codec_name,codec_type,width,height:format=duration' -of json $output.FullName
        if ($LASTEXITCODE -ne 0) { throw "ffprobe failed to open $($output.Name)." }
        $metadata = $metadataJson | Out-String | ConvertFrom-Json
        $video = @($metadata.streams | Where-Object codec_type -eq 'video')
        $audio = @($metadata.streams | Where-Object codec_type -eq 'audio')
        if ($video.Count -ne 1 -or $video[0].codec_name -ne 'hevc' -or $video[0].width -ne 160 -or $video[0].height -ne 90) {
            throw "Expected one HEVC stream at 160x90 in $($output.Name). ffprobe: $($metadataJson -join ' ')"
        }
        if ($audio.Count -ne 1 -or $audio[0].codec_name -ne 'aac') {
            throw "Expected one AAC stream in $($output.Name)."
        }
        if ([Math]::Abs([double]$metadata.format.duration - 2) -gt 0.15) {
            throw "Unexpected duration in $($output.Name): $($metadata.format.duration)s."
        }
        if ($case.MaxBytes -and $output.Length -gt $case.MaxBytes) {
            throw "$($output.Name) exceeded the $($case.MaxBytes)-byte limit."
        }
    }

    $dimensionCases = @(
        @{ Name = 'default'; InputSize = '320x180'; Options = @{}; Expected = '320x180' }
        @{ Name = 'portrait'; InputSize = '180x320'; Options = @{ resolution = 'hd' }; Expected = '90x160' }
        @{ Name = 'square'; InputSize = '180x180'; Options = @{ resolution = 'fhd' }; Expected = '240x240' }
    )
    foreach ($case in $dimensionCases) {
        $source = Join-Path $fixture.FullName "$($case.Name).mp4"
        & ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "testsrc2=size=$($case.InputSize):rate=24" -t 1 -c:v mpeg4 $source
        if ($LASTEXITCODE) { throw "Failed to generate $($case.Name) video." }
        $options = $case.Options
        comprimir cpu $source fast @options
        $outputPath = Join-Path $fixture.FullName "$($case.Name)_test.mp4"
        if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) { throw "Missing $($case.Name) output." }
        $size = & ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of 'csv=p=0:s=x' $outputPath
        if ($LASTEXITCODE -or $size -ne $case.Expected) {
            throw "Expected $($case.Expected) for $($case.Name), received $size."
        }
    }

    $lateTarget = Join-Path $fixture.FullName 'test [video]_late.mp4'
    $ClipSqueezeConfig.output.suffix = '_late'
    $originalLookup = ${function:Get-ClipSqueezeOutputFile}
    function Get-ClipSqueezeOutputFile {
        param($Path)
        if ($Path -eq $lateTarget -and (Get-ChildItem -LiteralPath $fixture.FullName -Filter '.clipsqueeze-*.mp4')) {
            [IO.File]::WriteAllText($Path, 'keep this file')
        }
        & $originalLookup $Path
    }
    try {
        comprimir cpu $inputPath fast -resolution hd -ErrorAction Stop
        throw 'A late destination collision was accepted.'
    }
    catch {
        if ($_.Exception.Message -notlike '*Move*') { throw }
    }
    if ([IO.File]::ReadAllText($lateTarget) -ne 'keep this file') {
        throw 'Compression overwrote a file created after the first destination check.'
    }
    Set-Item -Path function:Get-ClipSqueezeOutputFile -Value $originalLookup

    $estadoPrompt = [pscustomobject]@{ Chamadas = 0; Proibir = $false }
    function Read-Host {
        param([string]$Prompt)
        $estadoPrompt.Chamadas++
        if ($estadoPrompt.Proibir) { throw "Unexpected prompt: $Prompt" }
        return 'n'
    }
    comprimir cpu $inputPath fast -resolution hd
    if ($estadoPrompt.Chamadas -ne 1 -or [IO.File]::ReadAllText($lateTarget) -ne 'keep this file') {
        throw 'Normal compression did not ask before replacing the existing output.'
    }

    $estadoPrompt.Proibir = $true
    comprimir cpu $inputPath fast -resolution hd -Force
    if (-not (Test-ArquivoSaidaValido $lateTarget).Valido) { throw 'Force did not replace the existing output.' }

    $hashCompressed = (Get-FileHash -LiteralPath $lateTarget).Hash
    comprimir cpu $lateTarget fast -resolution hd -Force
    $recompressed = Join-Path $fixture.FullName 'test [video]_late_late.mp4'
    if (-not (Test-ArquivoSaidaValido $recompressed).Valido -or (Get-FileHash -LiteralPath $lateTarget).Hash -ne $hashCompressed) {
        throw 'Force did not recompress the video while preserving its input.'
    }

    try {
        comprimir -Force
        throw 'Force accepted missing required arguments.'
    }
    catch {
        if ($_.Exception.Message -notlike 'Informe o acelerador*') { throw }
    }
    try {
        comprimir cpu (Join-Path $fixture.FullName 'missing.mp4') -Force
        throw 'Force accepted a missing file.'
    }
    catch {
        if ($_.Exception.Message -notlike '*encontrado*') { throw }
    }
    & {
        function Get-Command {
            param([string]$Name, $CommandType, $ErrorAction)
            if ($Name -notin @('ffmpeg', 'ffprobe')) {
                throw "Non-interactive dependency check should not look for $Name."
            }
        }
        if (Test-FFmpegInstalado -NaoInterativo) {
            throw 'The non-interactive dependency check accepted missing tools.'
        }
    }

    $ClipSqueezeConfig.output.overwrite = $true
    comprimir cpu $inputPath fast -resolution hd
    if (-not (Test-ArquivoSaidaValido $lateTarget).Valido) { throw 'Explicit overwrite did not publish the new video.' }
    if (Get-ChildItem -LiteralPath $fixture.FullName -Filter '.clipsqueeze-*') {
        throw 'Temporary compression output remained in the destination.'
    }

    $junction = Join-Path $fixture.FullName 'redirected output'
    $null = New-Item -ItemType Junction -Path $junction -Target $fixture.FullName
    try {
        $ClipSqueezeConfig.output.directory = $junction
        $ClipSqueezeConfig.output.suffix = '_redirected'
        try {
            comprimir cpu $inputPath fast -resolution hd -Force
            throw 'Force accepted a redirected destination.'
        }
        catch {
            if ($_.Exception.Message -notlike '*redirecionada*') { throw }
        }
        if (Test-Path -LiteralPath (Join-Path $fixture.FullName 'test [video]_redirected.mp4')) {
            throw 'Compression published output through a junction.'
        }
    }
    finally {
        [IO.Directory]::Delete($junction)
    }
    if ($estadoPrompt.Chamadas -ne 1) { throw 'An automatic operation prompted for input.' }
}
finally {
    if (Test-Path -LiteralPath $configFile) { [IO.File]::Delete($configFile) }
    if (Test-Path -LiteralPath $configDirectory) { [IO.Directory]::Delete($configDirectory) }
    Get-ChildItem -LiteralPath $fixture.FullName -File | Remove-Item -Force
    Remove-Item -LiteralPath $fixture.FullName
}
