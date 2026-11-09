param([Parameter(Mandatory)][string] $WorkDirectory)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
& "$PSScriptRoot/windows-cpu-inference.ps1" -WorkDirectory $WorkDirectory -PrepareOnly
$evidence = Join-Path $WorkDirectory 'evidence'

Add-Type -AssemblyName System.Windows.Forms
$desktop = [ordered]@{
    sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
    interactive = [Environment]::UserInteractive
    screens = @([Windows.Forms.Screen]::AllScreens | ForEach-Object { $_.Bounds.ToString() })
    processes = @(Get-Process explorer, conhost -ErrorAction SilentlyContinue | Select-Object ProcessName, Id, SessionId)
}
$desktop | ConvertTo-Json -Depth 5 | Tee-Object -FilePath (Join-Path $evidence 'desktop.json')
& query.exe session 2>&1 | Out-File (Join-Path $evidence 'sessions.txt')

$ffmpegUrl = 'https://github.com/GyanD/codexffmpeg/releases/download/9.0.2/ffmpeg-9.0.2-essentials_build.zip'
$ffmpegSha256 = '60f467265b1e312373dbcd92200c2618a74850f98d3d078e94296bb3fa2047ba'
$archive = Join-Path $WorkDirectory 'ffmpeg.zip'
& curl.exe --fail --location --silent --show-error --retry 3 --retry-all-errors --output $archive $ffmpegUrl
if ($LASTEXITCODE -ne 0) { throw 'FFmpeg download failed.' }
if ((Get-FileHash -Algorithm SHA256 $archive).Hash -ne $ffmpegSha256) { throw 'FFmpeg SHA-256 mismatch.' }
Expand-Archive $archive -DestinationPath (Join-Path $WorkDirectory 'ffmpeg') -Force
$ffmpeg = (Get-ChildItem (Join-Path $WorkDirectory 'ffmpeg') -Recurse -Filter ffmpeg.exe | Select-Object -First 1).FullName
$ffprobe = Join-Path (Split-Path $ffmpeg) 'ffprobe.exe'

$terminal = $null
$recorder = $null
$recorderLog = $null
try {
    $terminalArguments = @('-NoLogo', '-NoProfile', '-File', ('"{0}"' -f "$PSScriptRoot/windows-cpu-terminal.ps1"), '-WorkDirectory', ('"{0}"' -f $WorkDirectory))
    $terminal = Start-Process (Get-Command pwsh).Source -ArgumentList $terminalArguments -WindowStyle Normal -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while (-not (Test-Path (Join-Path $WorkDirectory 'terminal-ready'))) {
        if ($terminal.HasExited -or [DateTime]::UtcNow -gt $deadline) { throw 'Console did not become ready.' }
        Start-Sleep -Milliseconds 200
    }

    $video = Join-Path $evidence 'zml-windows-cpu-paris-20-words.mp4'
    $start = [Diagnostics.ProcessStartInfo]::new($ffmpeg)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-y', '-hide_banner', '-loglevel', 'warning', '-f', 'gdigrab', '-framerate', '15', '-draw_mouse', '0', '-i', 'desktop', '-t', '360', '-vf', 'pad=ceil(iw/2)*2:ceil(ih/2)*2', '-c:v', 'libx264', '-preset', 'ultrafast', '-crf', '18', '-pix_fmt', 'yuv420p', '-threads', '2', '-movflags', '+faststart', $video)) {
        $start.ArgumentList.Add($argument)
    }
    $videoStarted = [DateTimeOffset]::UtcNow
    $recorder = [Diagnostics.Process]::Start($start)
    $recorderLog = $recorder.StandardError.ReadToEndAsync()
    Start-Sleep -Seconds 2
    if ($recorder.HasExited) { throw 'Desktop capture failed to start.' }
    New-Item -ItemType File (Join-Path $WorkDirectory 'start-inference') | Out-Null

    $deadline = [DateTime]::UtcNow.AddSeconds(300)
    while (-not (Test-Path (Join-Path $evidence 'terminal-result.json'))) {
        if ($terminal.HasExited -or [DateTime]::UtcNow -gt $deadline) { throw 'Console inference did not finish.' }
        Start-Sleep -Milliseconds 200
    }
    Start-Sleep -Seconds 5
} finally {
    if ($recorder) {
        if (-not $recorder.HasExited) {
            $recorder.StandardInput.WriteLine('q')
            $recorder.StandardInput.Flush()
            if (-not $recorder.WaitForExit(15000)) { $recorder.Kill(); throw 'Recorder did not finalize.' }
        }
        $recorderLog.GetAwaiter().GetResult() | Set-Content (Join-Path $evidence 'ffmpeg.log')
    }
    if ($terminal -and -not $terminal.HasExited) { Stop-Process -Id $terminal.Id -Force }
}
if ($recorder.ExitCode -ne 0) { throw "Recorder failed: $($recorder.ExitCode)" }
$result = Get-Content -Raw (Join-Path $evidence 'terminal-result.json') | ConvertFrom-Json
if ($result.exitCode -ne 0) { throw "Console inference failed: $($result | ConvertTo-Json -Compress)" }
$output = [regex]::Replace((Get-Content -Raw (Join-Path $evidence 'terminal-inference.log')), '\x1b\[[0-?]*[ -/]*[@-~]', '')
foreach ($pattern in @('platform: cpu', 'Compiled prefill forward', 'Compiled decode forward', 'Loaded weights', 'Paris', 'decode\s+.+\d+\.\d+tok/s')) {
    if ($output -notmatch $pattern) { throw "Missing recorded inference evidence: $pattern" }
}
$output | Write-Output
$story = [regex]::Match($output, '(?s)prefill\.\.\.(?<story>.*?)\r?\ndecode\s+').Groups['story'].Value.Trim()
$wordCount = ($story -split '\s+').Count
if ($wordCount -lt 3 -or $wordCount -gt 20) { throw "Expected a short story of at most 20 words; got $wordCount." }
$story | Set-Content (Join-Path $evidence 'generated-story.txt')
$events = @(Get-Content (Join-Path $evidence 'stdout-events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
$prefix = ''
$prefill = $null
foreach ($event in $events) {
    $prefix += $event.text
    if ($prefix.Contains('prefill...')) { $prefill = $event; break }
}
if ($null -eq $prefill) { throw 'Missing prefill marker in stdout events.' }
$generation = @($events | Where-Object {
    $_.elapsedMs -gt $prefill.elapsedMs -and $_.elapsedMs -lt ($events[-1].elapsedMs - 100) -and $_.text -match '\p{L}'
})
if ($generation.Count -lt 3 -or ($generation[-1].elapsedMs - $generation[0].elapsedMs) -lt 1000) {
    throw 'Did not observe text arriving progressively during generation.'
}
@{
    chunks = $generation.Count
    firstChunkMs = $generation[0].elapsedMs
    lastChunkMs = $generation[-1].elapsedMs
    words = $wordCount
} | ConvertTo-Json | Set-Content (Join-Path $evidence 'streaming.json')
$metadata = & $ffprobe -v error -show_format -show_streams -of json $video
if ($LASTEXITCODE -ne 0) { throw 'Recorded MP4 is invalid.' }
$metadata | Set-Content (Join-Path $evidence 'video.json')
$duration = [double](($metadata | ConvertFrom-Json).format.duration)
if ($duration -lt 6) { throw "Recording too short: $duration seconds" }
foreach ($sample in @(@('intro', 3), @('inference', [math]::Max(3, $duration / 2)), @('result', [math]::Max(3, $duration - 2)))) {
    & $ffmpeg -y -hide_banner -loglevel error -ss $sample[1] -i $video -frames:v 1 (Join-Path $evidence "$($sample[0]).png")
    if ($LASTEXITCODE -ne 0) { throw 'Cannot extract recording preview.' }
}
for ($i = 1; $i -le 3; $i++) {
    $event = $generation[[int][math]::Floor(($generation.Count - 1) * $i / 4)]
    $seconds = ([DateTimeOffset]$event.utc - $videoStarted).TotalSeconds
    & $ffmpeg -y -hide_banner -loglevel error -ss $seconds -i $video -frames:v 1 (Join-Path $evidence "streaming-$i.png")
    if ($LASTEXITCODE -ne 0) { throw 'Cannot extract streaming preview.' }
}
Write-Host "PASS: captured a real Windows console; MP4 duration $duration seconds."
