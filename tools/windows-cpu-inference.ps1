param(
    [string] $Manifest = (Join-Path $PSScriptRoot 'windows-cpu-inference.json'),
    [string] $WorkDirectory = (Join-Path ([IO.Path]::GetTempPath()) 'zml-windows-inference')
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$PSStyle.OutputRendering = 'PlainText'
if (-not $IsWindows -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64') {
    throw 'This smoke test requires native x64 Windows.'
}

$config = Get-Content -Raw $Manifest | ConvertFrom-Json
$evidence = Join-Path $WorkDirectory 'evidence'
New-Item -ItemType Directory -Force $evidence | Out-Null
$identity = [ordered]@{
    os = [Runtime.InteropServices.RuntimeInformation]::OSDescription
    architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    processArchitecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
    cpu = (Get-CimInstance Win32_Processor | Select-Object -ExpandProperty Name) -join ', '
    logicalProcessors = [Environment]::ProcessorCount
    memoryGiB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
    runner = $env:RUNNER_NAME
    workflowCommit = $env:GITHUB_SHA
}
$identity | ConvertTo-Json | Tee-Object -FilePath (Join-Path $evidence 'windows.json')

function Get-VerifiedFile([string] $Url, [string] $Destination, [string] $Sha256) {
    if ($Sha256 -notmatch '^[0-9a-fA-F]{64}$') { throw "Invalid SHA-256 for $Destination" }
    Write-Host "Downloading $Url"
    & curl.exe --fail --location --silent --show-error --retry 3 --retry-all-errors --output $Destination $Url
    if ($LASTEXITCODE -ne 0) { throw "Download failed: $Url" }
    if ((Get-FileHash -Algorithm SHA256 $Destination).Hash -ne $Sha256) {
        throw "SHA-256 mismatch: $Destination"
    }
}

$archive = Join-Path $WorkDirectory 'runtime.zip'
Get-VerifiedFile $config.bundle.url $archive $config.bundle.sha256
$runtime = Join-Path $WorkDirectory 'runtime'
Expand-Archive -Path $archive -DestinationPath $runtime -Force
Copy-Item (Join-Path $runtime 'build-info.json') $evidence
Get-Content (Join-Path $evidence 'build-info.json')

$model = Join-Path $WorkDirectory 'model'
New-Item -ItemType Directory -Force $model | Out-Null
foreach ($file in $config.model.files) {
    $url = "https://huggingface.co/$($config.model.repository)/resolve/$($config.model.revision)/$($file.name)"
    Get-VerifiedFile $url (Join-Path $model $file.name) $file.sha256
}
$config | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $evidence 'inputs.json')

# Use the packaged runfiles tree; never inherit paths from the build machine.
$env:RUNFILES_DIR = Join-Path $runtime 'llm.exe.runfiles'
$env:RUNFILES_MANIFEST_FILE = $null
$executable = Join-Path $runtime 'llm.exe'
$arguments = @(
    "--model=$model",
    '--prompt=What is the capital of France? Answer in one sentence.',
    '--seqlen=64',
    '--topk=1',
    '--cpu-devices=1'
)
Write-Host "Running: $executable $($arguments -join ' ')"
$log = Join-Path $evidence 'inference.log'
& $executable @arguments 2>&1 | Tee-Object -FilePath $log
$exitCode = $LASTEXITCODE
Write-Host "llm.exe exit code: $exitCode"
if ($exitCode -ne 0) { throw "Inference failed with exit code $exitCode" }

$output = [regex]::Replace((Get-Content -Raw $log), '\x1b\[[0-?]*[ -/]*[@-~]', '')
foreach ($pattern in @('platform: cpu', 'Compiled prefill forward', 'Compiled decode forward', 'Loaded weights', 'Paris', 'decode\s+.+\d+\.\d+tok/s')) {
    if ($output -notmatch $pattern) { throw "Missing inference evidence: $pattern" }
}
Write-Host 'PASS: native Windows CPU model compilation, weight loading, and text generation.'
if ($env:GITHUB_STEP_SUMMARY) {
    @"
### Native Windows CPU inference passed

- OS: $($identity.os), $($identity.architecture)
- Model: $($config.model.repository) at $($config.model.revision)
- Runtime: prebuilt Windows executable and CPU PJRT DLL; no compilation on the runner.
- Generated text and decode timing: see this step's log and the evidence artifact.
"@ | Add-Content $env:GITHUB_STEP_SUMMARY
}
