#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$fixture = New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) "ClipSqueeze metadata $([guid]::NewGuid())")

try {
    $scriptPath = Join-Path $fixture.FullName 'ClipSqueeze.ps1'
    Copy-Item -LiteralPath (Join-Path $root 'ClipSqueeze.ps1') -Destination $scriptPath
    '{"notifications":{"enabled":false},"output":{"suffix":"_clean"}}' |
        Set-Content -LiteralPath (Join-Path $fixture.FullName 'config.json') -Encoding Ascii
    . $scriptPath
    if ($ClipSqueezeConfig.metadata.mode -ne 'clean') {
        throw 'An existing config without a metadata setting must default to clean.'
    }

    $tagsPath = Join-Path $fixture.FullName 'tags.ffmeta'
    @'
;FFMETADATA1
title=Private project
artist=Private author
location=+01.0000+002.0000/
creation_time=2020-01-02T03:04:05Z
[CHAPTER]
TIMEBASE=1/1000
START=0
END=800
title=Private chapter A
[CHAPTER]
TIMEBASE=1/1000
START=800
END=1600
title=Private chapter B
'@ | Set-Content -LiteralPath $tagsPath -Encoding Ascii
    $inputPath = Join-Path $fixture.FullName 'input [video].mkv'
    $chaveUnicode = "c$([char]0x00E2)mera_privada"
    $fixtureArgs = @(
        '-nostdin', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=160x90:rate=24',
        '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000', '-f', 'ffmetadata', '-i', $tagsPath,
        '-map', '0:v', '-map', '1:a', '-map_metadata', '2', '-map_chapters', '2', '-t', '2',
        '-c:v', 'libx264', '-preset', 'ultrafast', '-c:a', 'aac',
        '-colorspace', 'bt709', '-color_range', 'tv',
        '-metadata:s:v:0', "$chaveUnicode=Private camera", '-metadata:s:v:0', 'language=invalid language',
        '-metadata:s:a:0', 'language=por',
        '-metadata:s:a:0', 'title=Private track', $inputPath
    )
    & ffmpeg @fixtureArgs
    if ($LASTEXITCODE) { throw 'Failed to create the tagged test video.' }
    $originalHash = (Get-FileHash -LiteralPath $inputPath).Hash
    $inputProbe = Get-MetadadosVideo $inputPath -tags todas
    $languageProbe = [pscustomobject]@{
        streams = @(
            [pscustomobject]@{ tags = [pscustomobject]@{ language = 'zh-Hant-TW' } },
            [pscustomobject]@{ tags = [pscustomobject]@{ language = 'por' } }
        )
    }
    $languageArgs = @(Get-ArgumentosLimpezaMetadados $languageProbe 'mkv')
    if ($languageArgs -contains 'language=' -or -not (Test-MetadadosLimpos $languageProbe 'mkv')) {
        throw 'Valid language subtags were removed or rejected.'
    }
    if (-not ($inputProbe.Sondagem.streams[0].tags.PSObject.Properties[$chaveUnicode])) {
        $observedTags = $inputProbe.Sondagem.streams[0].tags.PSObject.Properties.Name -join ', '
        throw "The metadata test fixture or UTF-8 probe lost the Unicode stream tag. Observed: $observedTags"
    }

    $probeOriginal = ${function:Invoke-FfprobeJson}
    $contador = [pscustomobject]@{ Total = 0 }
    function Invoke-FfprobeJson {
        param([string[]]$argumentos)
        $contador.Total++
        & $probeOriginal -argumentos $argumentos
    }

    $campos = 'stream=codec_type,color_range,color_space:stream_tags:format_tags:chapter=start_time:chapter_tags'
    foreach ($container in @('mp4', 'mov', 'mkv')) {
        $totalInicial = $contador.Total
        comprimir cpu $inputPath fast -container $container
        if (($contador.Total - $totalInicial) -ne 2) { throw 'Cleaning must reuse the input and output probes.' }
        $outputPath = Join-Path $fixture.FullName "input [video]_clean.$container"
        if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) { throw "Missing clean $container output." }
        $dados = Invoke-FfprobeJson @('-v', 'error', '-show_entries', $campos, '-of', 'json', $outputPath)
        if (-not $dados -or ($dados | ConvertTo-Json -Depth 10) -match 'Private|creation_time|location') {
            throw "Descriptive tags survived in $container."
        }
        $video = $dados.streams | Where-Object codec_type -eq 'video' | Select-Object -First 1
        $audio = $dados.streams | Where-Object codec_type -eq 'audio' | Select-Object -First 1
        if ($audio.tags.language -ne 'por' -or $video.color_range -ne 'tv' -or $video.color_space -ne 'bt709') {
            throw "Language or color information was lost in ${container}: $($dados | ConvertTo-Json -Depth 8 -Compress)"
        }
        if ($dados.chapters.Count -ne 2 -or [Math]::Abs([double]$dados.chapters[1].start_time - 0.8) -gt 0.05) {
            throw "Chapter timing was not preserved in $container."
        }
    }

    $rotated = Join-Path $fixture.FullName 'rotated.mp4'
    & ffmpeg -nostdin -hide_banner -loglevel error -display_rotation:v:0 90 -i $inputPath -map 0:v:0 -c:v copy $rotated
    if ($LASTEXITCODE) { throw 'Failed to create a video with display rotation.' }
    comprimir cpu $rotated fast
    $rotatedOutput = Join-Path $fixture.FullName 'rotated_clean.mp4'
    $geometry = Invoke-FfprobeJson @('-v', 'error', '-select_streams', 'V:0', '-show_entries', 'stream=width,height', '-of', 'json', $rotatedOutput)
    if (-not $geometry -or $geometry.streams[0].width -ne 90 -or $geometry.streams[0].height -ne 160) {
        throw 'The output lost the display orientation of the input video.'
    }

    $ClipSqueezeConfig.output.suffix = '_preserve'
    comprimir cpu $inputPath fast -container mkv -Metadata preserve
    $preserved = Get-MetadadosVideo (Join-Path $fixture.FullName 'input [video]_preserve.mkv') -tags todas
    if ($preserved.Sondagem.format.tags.title -ne 'Private project' -or
        $preserved.Sondagem.chapters[0].tags.title -ne 'Private chapter A') {
        throw 'The preserve mode did not keep descriptive tags.'
    }

    $ClipSqueezeConfig.metadata.mode = 'preserve'
    $ClipSqueezeConfig.output.suffix = '_override'
    comprimir cpu $inputPath fast -container mkv -Metadata clean
    $override = Join-Path $fixture.FullName 'input [video]_override.mkv'
    if (-not (Test-ArquivoSaidaValido $override -container mkv -validarLimpeza).Valido) {
        throw 'The explicit clean option did not override the config.'
    }

    $ClipSqueezeConfig.output.suffix = '_blocked'
    $blocked = Join-Path $fixture.FullName 'input [video]_blocked.mkv'
    [IO.File]::WriteAllText($blocked, 'existing output')
    function Get-ArgumentosLimpezaMetadados {
        @('-metadata', 'title=Unexpected descriptive tag')
    }
    try {
        comprimir cpu $inputPath fast -container mkv -Metadata clean -Force
        throw 'Force accepted an output with descriptive tags.'
    }
    catch {
        if ($_.Exception.Message -notlike '*limpeza*') { throw }
    }
    if ([IO.File]::ReadAllText($blocked) -ne 'existing output' -or
        (Get-FileHash -LiteralPath $inputPath).Hash -ne $originalHash -or
        (Get-ChildItem -LiteralPath $fixture.FullName -Filter '.clipsqueeze-*')) {
        throw 'Failed verification replaced an existing file, modified the source, or left a staged file.'
    }
    Write-Host 'Metadata cleaning, preservation, and safe publication checks passed.'
}
finally {
    Get-ChildItem -LiteralPath $fixture.FullName -File | Remove-Item -Force
    [IO.Directory]::Delete($fixture.FullName)
}
