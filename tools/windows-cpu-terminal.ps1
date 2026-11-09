param([Parameter(Mandatory)][string] $WorkDirectory)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$evidence = Join-Path $WorkDirectory 'evidence'
$result = @{ exitCode = 1 }
try {
    Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
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
    [DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr handle, out uint mode);
    [DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr handle, uint mode);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    public static extern bool SetCurrentConsoleFontEx(IntPtr output, bool maximum, ref Font font);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    public static extern bool GetCurrentConsoleFontEx(IntPtr output, bool maximum, ref Font font);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);

    public static int RunStreaming(string executable, string[] arguments, string logPath, string eventsPath) {
        var start = new ProcessStartInfo(executable) {
            UseShellExecute = false, CreateNoWindow = true,
            WorkingDirectory = Path.GetDirectoryName(executable),
            RedirectStandardOutput = true, RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8
        };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        using (var process = new Process { StartInfo = start })
        using (var log = new StreamWriter(logPath, false, new UTF8Encoding(false)))
        using (var events = new StreamWriter(eventsPath, false, new UTF8Encoding(false))) {
            var gate = new object();
            var clock = Stopwatch.StartNew();
            process.Start();
            Action<StreamReader, bool> forward = (reader, stdout) => {
                var buffer = new char[256];
                int count;
                while ((count = reader.Read(buffer, 0, buffer.Length)) != 0) {
                    var text = new string(buffer, 0, count);
                    lock (gate) {
                        Console.Out.Write(text);
                        Console.Out.Flush();
                        log.Write(text);
                        log.Flush();
                        if (stdout) {
                            events.WriteLine(JsonSerializer.Serialize(new { elapsedMs = clock.ElapsedMilliseconds, utc = DateTimeOffset.UtcNow.ToString("O"), text }));
                            events.Flush();
                        }
                    }
                }
            };
            var output = Task.Run(() => forward(process.StandardOutput, true));
            var error = Task.Run(() => forward(process.StandardError, false));
            process.WaitForExit();
            Task.WaitAll(output, error);
            return process.ExitCode;
        }
    }
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
    # Coord is a value type: mutating $font.Dimensions.Y changes a copy.
    $dimensions = [DemoConsole+Coord]::new()
    $dimensions.Y = 18
    $font.Dimensions = $dimensions
    $font.Family = 54
    $font.Weight = 400
    $font.Face = 'Consolas'
    $consoleOutput = [DemoConsole]::GetStdHandle(-11)
    if ([DemoConsole]::GetFileType($consoleOutput) -ne 2) { throw 'Console output is redirected.' }
    if (-not [DemoConsole]::SetCurrentConsoleFontEx($consoleOutput, $false, [ref]$font)) {
        throw 'Cannot configure console font.'
    }
    if (-not [DemoConsole]::GetCurrentConsoleFontEx($consoleOutput, $false, [ref]$font) -or $font.Dimensions.Y -ne 18) {
        throw 'Windows did not apply the requested console font.'
    }
    [uint32] $mode = 0
    if (-not [DemoConsole]::GetConsoleMode($consoleOutput, [ref]$mode) -or
        -not [DemoConsole]::SetConsoleMode($consoleOutput, $mode -bor 4)) {
        throw 'Cannot enable console VT output.'
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
        '--prompt=Write a story about Paris in at most 20 words. Output only the story.',
        '--seqlen=128', '--topk=1', '--cpu-devices=1'
    )
    Write-Host 'PS> .\llm.exe --model=..\model `' -ForegroundColor White
    Write-Host '      --prompt="Write a story about Paris in at most 20 words. Output only the story." `' -ForegroundColor White
    Write-Host '      --seqlen=128 --topk=1 --cpu-devices=1' -ForegroundColor White
    Start-Sleep -Seconds 3
    # Forward available chunks directly: PowerShell's native pipeline waits for lines.
    $result.exitCode = [DemoConsole]::RunStreaming(
        (Join-Path $PWD 'llm.exe'), $arguments,
        (Join-Path $evidence 'terminal-inference.log'),
        (Join-Path $evidence 'stdout-events.jsonl')
    )
    Write-Host "`nPS> # Process exited with code $($result.exitCode)" -ForegroundColor Green
} catch {
    $result.error = $_.ToString()
    Write-Host $_ -ForegroundColor Red
} finally {
    $result | ConvertTo-Json | Set-Content (Join-Path $evidence 'terminal-result.json')
    # Keep the actual console visible while the controller finalizes the video.
    Start-Sleep -Seconds 30
}
