param([Parameter(Mandatory)][string] $WorkDirectory)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$evidence = Join-Path $WorkDirectory 'evidence'
$result = @{ exitCode = 1 }
try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DemoConsole {
    [StructLayout(LayoutKind.Sequential)] public struct Coord { public short X, Y; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct Font {
        public uint Size, Index;
        public Coord Dimensions;
        public uint Family, Weight;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string Face;
    }
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int id);
    [DllImport("kernel32.dll")] public static extern uint GetFileType(IntPtr handle);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr CreateFileW(string name, uint access, uint sharing, IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr handle, out uint mode);
    [DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr handle, uint mode);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    public static extern bool SetCurrentConsoleFontEx(IntPtr output, bool maximum, ref Font font);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    public static extern bool GetCurrentConsoleFontEx(IntPtr output, bool maximum, ref Font font);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
}
'@
    $window = [DemoConsole]::GetConsoleWindow()
    if ($window -eq [IntPtr]::Zero) { throw 'A real Windows console window is required.' }
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    $Host.UI.RawUI.WindowTitle = 'ZML - Native Windows CPU inference'
    $Host.UI.RawUI.BackgroundColor = 'Black'
    $Host.UI.RawUI.ForegroundColor = 'Gray'
    $font = [DemoConsole+Font]::new()
    $font.Size = [Runtime.InteropServices.Marshal]::SizeOf($font)
    $font.Dimensions.Y = 18
    $font.Family = 54
    $font.Weight = 400
    $font.Face = 'Consolas'
    # Actions can pass redirected standard handles into a newly opened console.
    # Open the console itself for font and VT configuration.
    $consoleOutput = [DemoConsole]::CreateFileW('CONOUT$', 0xC0000000u, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
    if ($consoleOutput -eq [IntPtr]::new(-1)) { throw 'Cannot open console output.' }
    try {
        if (-not [DemoConsole]::SetCurrentConsoleFontEx($consoleOutput, $false, [ref]$font)) {
            throw 'Cannot configure console font.'
        }
        if (-not [DemoConsole]::GetCurrentConsoleFontEx($consoleOutput, $false, [ref]$font)) {
            throw 'Cannot inspect console font.'
        }
        [uint32] $mode = 0
        if (-not [DemoConsole]::GetConsoleMode($consoleOutput, [ref]$mode) -or
            -not [DemoConsole]::SetConsoleMode($consoleOutput, $mode -bor 4)) {
            throw 'Cannot enable console VT output.'
        }
    } finally {
        [void][DemoConsole]::CloseHandle($consoleOutput)
    }
    [void][DemoConsole]::ShowWindow($window, 3)
    [void][DemoConsole]::SetForegroundWindow($window)
    Clear-Host
    @{
        processId = $PID
        sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
        consoleWindow = $window.ToInt64()
        title = $Host.UI.RawUI.WindowTitle
        font = @{ face = $font.Face; height = $font.Dimensions.Y }
        standardOutputType = [DemoConsole]::GetFileType([DemoConsole]::GetStdHandle(-11))
    } | ConvertTo-Json | Set-Content (Join-Path $evidence 'terminal.json')
    New-Item -ItemType File (Join-Path $WorkDirectory 'terminal-ready') | Out-Null
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    while (-not (Test-Path (Join-Path $WorkDirectory 'start-inference'))) {
        if ([DateTime]::UtcNow -gt $deadline) { throw 'Timed out waiting for screen capture.' }
        Start-Sleep -Milliseconds 200
    }

    Set-Location (Join-Path $WorkDirectory 'runtime')
    $env:RUNFILES_DIR = Join-Path $PWD 'llm.exe.runfiles'
    $env:RUNFILES_MANIFEST_FILE = $null
    Write-Host 'ZML / Llama 3.2 1B / native Windows / CPU' -ForegroundColor Cyan
    Write-Host "Windows $([Environment]::OSVersion.Version) x64 | PowerShell $($PSVersionTable.PSVersion)"
    Write-Host ''
    $arguments = @(
        '--model=..\model',
        '--prompt=What is the capital of France? Answer in one sentence.',
        '--seqlen=64', '--topk=1', '--cpu-devices=1'
    )
    Write-Host 'PS> .\llm.exe --model=..\model `' -ForegroundColor White
    Write-Host '      --prompt="What is the capital of France? Answer in one sentence." `' -ForegroundColor White
    Write-Host '      --seqlen=64 --topk=1 --cpu-devices=1' -ForegroundColor White
    Start-Sleep -Seconds 3
    & .\llm.exe @arguments 2>&1 |
        ForEach-Object { [regex]::Replace($_.ToString(), '\x1b\[[0-?]*[ -/]*[@-~]', '') } |
        Tee-Object -FilePath (Join-Path $evidence 'terminal-inference.log')
    $result.exitCode = $LASTEXITCODE
    Write-Host "`nPS> # Process exited with code $($result.exitCode)" -ForegroundColor Green
} catch {
    $result.error = $_.ToString()
    Write-Host $_ -ForegroundColor Red
} finally {
    $result | ConvertTo-Json | Set-Content (Join-Path $evidence 'terminal-result.json')
    # Keep the actual console visible while the controller finalizes the video.
    Start-Sleep -Seconds 30
}
