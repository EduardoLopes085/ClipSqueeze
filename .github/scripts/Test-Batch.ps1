#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$fixture = New-Item -ItemType Directory -Path (Join-Path $env:TEMP ("ClipSqueeze batch " + [guid]::NewGuid()))
try {
    . (Join-Path $root 'ClipSqueeze.ps1')
    $ClipSqueezeConfig.notifications.enabled = $false
    $ClipSqueezeConfig.output.directory = $fixture.FullName
    $ClipSqueezeConfig.output.suffix = '_compressed'
    $ClipSqueezeConfig.output.overwrite = $false
    $inputA = Join-Path $fixture.FullName 'a.mp4'
    $inputB = Join-Path $fixture.FullName 'b.mp4'
    & ffmpeg -nostdin -v error -f lavfi -i 'testsrc2=size=160x90:rate=24' -t 1 -c:v mpeg4 $inputA
    if ($LASTEXITCODE) { throw 'Could not create the batch fixture.' }
    Copy-Item -LiteralPath $inputA -Destination $inputB
    $invalid = Join-Path $fixture.FullName 'c.mp4'
    [IO.File]::WriteAllText($invalid, 'invalid video')
    $outputA = Join-Path $fixture.FullName 'a_compressed.mp4'
    [IO.File]::WriteAllText($outputA, 'replace me')
    $queue = @(Resolve-FilaVideos @((Join-Path $fixture.FullName '*.mp4'), $inputA))
    if ($queue.Count -ne 3 -or $queue[0].FullName -ne $inputA) { throw 'Wildcard ordering, output exclusion or deduplication failed.' }
    $results = [Collections.Generic.List[object]]::new()
    try {
        comprimir cpu @($invalid, $inputB, $inputA, $inputA) fast -Force -PassThru | ForEach-Object { $results.Add($_) }
        throw 'The invalid batch input did not report failure.'
    }
    catch {
        if ($_.Exception.Message -notlike '*ffprobe*') { throw }
    }
    if ($results.Count -ne 3 -or $results[0].Status -ne 'Concluido' -or $results[1].Status -ne 'Concluido' -or
        $results[2].Status -ne 'Falhou' -or -not (Test-ArquivoSaidaValido $outputA).Valido) {
        throw 'The batch did not report per-file results or overwrite with Force.'
    }
    # A failed first item must allow a later valid file to complete.
    $firstBad = Join-Path $fixture.FullName '0-invalid.mp4'
    [IO.File]::WriteAllText($firstBad, 'invalid video')
    $results.Clear()
    try {
        comprimir cpu @($firstBad, $inputA) fast -Force -PassThru | ForEach-Object { $results.Add($_) }
        throw 'Failed input did not fail the batch.'
    }
    catch { if ($_.Exception.Message -notlike '*ffprobe*') { throw } }
    if ($results.Count -ne 2 -or $results[0].Status -ne 'Falhou' -or $results[1].Status -ne 'Concluido') {
        throw 'The queue did not continue after a failed file.'
    }
    $results.Clear()
    try {
        comprimir cpu @($firstBad, $inputA) fast -Force -PassThru -StopOnError | ForEach-Object { $results.Add($_) }
        throw 'StopOnError ignored failure.'
    }
    catch { if ($_.Exception.Message -notlike '*ffprobe*') { throw } }
    if ($results.Count -ne 1 -or $results[0].Status -ne 'Falhou') { throw 'StopOnError processed more than one item.' }
    $before = (Get-FileHash -LiteralPath $outputA).Hash
    try {
        comprimir cpu @($inputA, $outputA) fast -Force
        throw 'Input/output overlap was accepted.'
    }
    catch { if ($_.Exception.Message -notlike '*Conflito*') { throw } }
    if ((Get-FileHash -LiteralPath $outputA).Hash -ne $before) { throw 'Preflight modified an existing input.' }
    $mkv = Join-Path $fixture.FullName 'a.mkv'
    Copy-Item -LiteralPath $inputA -Destination $mkv
    try {
        comprimir cpu @($inputA, $mkv) fast -Force
        throw 'Two files targeting the same output were accepted.'
    }
    catch { if ($_.Exception.Message -notlike '*Conflito*') { throw } }
    if (Get-ChildItem -LiteralPath $fixture.FullName -Filter '.clipsqueeze-*') { throw 'The queue left temporary output files.' }
    Write-Host 'Batch queue, failure handling, and destination collision tests passed.'
}
finally {
    Get-ChildItem -LiteralPath $fixture.FullName -File | Remove-Item -Force
    [IO.Directory]::Delete($fixture.FullName)
}
