#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Get-Command ffmpeg, ffprobe -CommandType Application -ErrorAction Stop | Out-Null
$fixture = New-Item -Path (Join-Path ([IO.Path]::GetTempPath()) "ClipSqueeze test $([guid]::NewGuid())") -ItemType Directory

try {
    $inputPath = Join-Path $fixture.FullName 'test [video].mp4'
    & ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i 'testsrc2=size=320x180:rate=24' -f lavfi -i 'sine=frequency=440:sample_rate=48000' -t 2 -c:v mpeg4 -c:a aac $inputPath
    if ($LASTEXITCODE -ne 0) { throw "Failed to generate test video (exit $LASTEXITCODE)." }

    $scriptPath = Join-Path $fixture.FullName 'ClipSqueeze.ps1'
    Copy-Item -LiteralPath (Join-Path $root 'ClipSqueeze.ps1') -Destination $scriptPath
    @{
        notifications = @{ enabled = $false }
        output = @{ suffix = '_test' }
        resolutionPresets = @{ hd = 160 }
        audio = @{ codec = 'aac extra marker' }
        profileOverrides = @{
            cpu = @{ fast = @{ preset = 'fast extra marker'; crf = 52 } }
            amd = @{ hevc = @{ fast = @{ quality = 'balanced'; qvbr = 30 } } }
            nvidia = @{ hevc = @{ fast = @{ preset = 'p3'; cq = 30.5 } } }
        }
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $fixture.FullName 'config.json') -Encoding Ascii
    . $scriptPath
    if ($ClipSqueezeConfig.audio.codec -ne 'aac' -or $PerfisConfig.cpu.fast.preset -ne 'veryfast' -or $PerfisConfig.cpu.fast.crf -ne 27) {
        throw 'Invalid codec, preset or CRF survived configuration validation.'
    }
    if ($PerfisConfig.amd.hevc.fast.quality -ne 'balanced' -or $PerfisConfig.amd.hevc.fast.qvbr -ne 30 -or
        $PerfisConfig.nvidia.hevc.fast.preset -ne 'p3' -or $PerfisConfig.nvidia.hevc.fast.cq -ne 30.5) {
        throw 'Valid GPU profile overrides were not preserved.'
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
    comprimir cpu $inputPath fast -resolution hd
    if ([IO.File]::ReadAllText($lateTarget) -ne 'keep this file') {
        throw 'Compression overwrote a file created after the first destination check.'
    }
    Set-Item -Path function:Get-ClipSqueezeOutputFile -Value $originalLookup

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
        comprimir cpu $inputPath fast -resolution hd
        if (Test-Path -LiteralPath (Join-Path $fixture.FullName 'test [video]_redirected.mp4')) {
            throw 'Compression published output through a junction.'
        }
    }
    finally {
        [IO.Directory]::Delete($junction)
    }
}
finally {
    Get-ChildItem -LiteralPath $fixture.FullName -File | Remove-Item -Force
    Remove-Item -LiteralPath $fixture.FullName
}
