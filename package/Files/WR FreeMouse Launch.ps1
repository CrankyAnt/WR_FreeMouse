$ErrorActionPreference = "Stop"

$installDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$runtimeScript = Join-Path $installDir "WR FreeMouse Runtime.ps1"
$stopFile = Join-Path $installDir "stop requested.flag"
$launchErrorPath = Join-Path $installDir "WR FreeMouse launch error.txt"
$powerShellExe = Join-Path $PSHOME "powershell.exe"

Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath $launchErrorPath
Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath $stopFile

Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class WRGameWindowProbe
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(
        IntPtr hWnd,
        StringBuilder lpClassName,
        int nMaxCount
    );

    public static string ClassName(IntPtr hWnd)
    {
        if (hWnd == IntPtr.Zero)
        {
            return "";
        }

        StringBuilder value = new StringBuilder(256);

        GetClassName(
            hWnd,
            value,
            value.Capacity
        );

        return value.ToString();
    }
}
"@

function Test-RuntimeMutex {
    try {
        $mutex = [System.Threading.Mutex]::OpenExisting(
            "Local\WRFreeMouse.Runtime.784150"
        )

        $mutex.Dispose()
        return $true
    }
    catch {
        return $false
    }
}

function Get-WRGameProcess {
    $gameClass = "Workers & Resources: Soviet Republic"
    $candidates = @()

    foreach ($name in @("SOVIET64","SOVIET")) {
        $candidates += @(
            Get-Process -Name $name -ErrorAction SilentlyContinue |
            Where-Object {
                $_.MainWindowHandle -ne 0 -and
                [WRGameWindowProbe]::ClassName(
                    [IntPtr]$_.MainWindowHandle
                ) -ceq $gameClass
            }
        )
    }

    if ($candidates.Count -eq 0) {
        return $null
    }

    return $candidates |
        Sort-Object StartTime -Descending |
        Select-Object -First 1
}

function Get-SteamArguments {
    $count = 0

    try {
        $count = [int]$env:WRFM_ARG_COUNT
    }
    catch {
        $count = 0
    }

    $values = @()

    for ($i = 0; $i -lt $count; $i++) {
        $name = "WRFM_ARG_$i"
        $values += [Environment]::GetEnvironmentVariable(
            $name,
            "Process"
        )
    }

    return @($values)
}

function ConvertTo-WindowsArgument {
    param([AllowEmptyString()][string]$Value)

    if ($null -eq $Value -or $Value.Length -eq 0) {
        return '""'
    }

    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0

    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq '\') {
            $backslashes++
            continue
        }

        if ($ch -eq '"') {
            [void]$builder.Append(('\' * ($backslashes * 2 + 1)))
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }

        if ($backslashes -gt 0) {
            [void]$builder.Append(('\' * $backslashes))
            $backslashes = 0
        }

        [void]$builder.Append($ch)
    }

    if ($backslashes -gt 0) {
        [void]$builder.Append(('\' * ($backslashes * 2)))
    }

    [void]$builder.Append('"')
    return $builder.ToString()
}

function Wait-RuntimeExit {
    param([int]$Seconds)

    $deadline = (Get-Date).AddSeconds($Seconds)

    while (
        (Test-RuntimeMutex) -and
        (Get-Date) -lt $deadline
    ) {
        Start-Sleep -Milliseconds 100
    }
}

try {
    $steamArgs = @(Get-SteamArguments)

    if ($steamArgs.Count -eq 0) {
        exit 0
    }

    $gameExe = [string]$steamArgs[0]
    $gameArgs = @()

    if ($steamArgs.Count -gt 1) {
        $gameArgs = @($steamArgs[1..($steamArgs.Count - 1)])
    }

    $argumentString = (
        $gameArgs |
        ForEach-Object {
            ConvertTo-WindowsArgument -Value ([string]$_)
        }
    ) -join ' '

    $launcherStart = @{
        FilePath = $gameExe
        PassThru = $true
    }

    if ($argumentString) {
        $launcherStart.ArgumentList = $argumentString
    }

    # Start W&R's native configuration/DirectX launcher and obtain its exact PID.
    $launcher = Start-Process @launcherStart

    # Start the actual FreeMouse runtime independently and hidden.
    Start-Process -FilePath $powerShellExe -WindowStyle Hidden -ArgumentList @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-WindowStyle", "Hidden",
        "-File", ('"{0}"' -f $runtimeScript),
        "-LauncherPid", $launcher.Id,
        "-MaxMinutes", "1440"
    )

    # The key fix: do NOT exit the Steam wrapper when the setup app exits.
    # Steam can place the entire launch tree in a job. Exiting here was killing
    # the child FreeMouse runtime just as the actual game appeared.
    $launcher.WaitForExit()

    $game = Get-WRGameProcess

    if (-not $game) {
        $gameDeadline = (Get-Date).AddSeconds(5)

        while (
            -not $game -and
            (Get-Date) -lt $gameDeadline
        ) {
            Start-Sleep -Milliseconds 50
            $game = Get-WRGameProcess
        }
    }

    if (-not $game) {
        # User cancelled/closed W&R setup without launching the game.
        # Let the runtime notice the dead LauncherPid and cleanly exit before
        # this Steam wrapper/job closes.
        Wait-RuntimeExit -Seconds 7
        exit $launcher.ExitCode
    }

    # Keep the Steam wrapper / process tree alive for the actual game lifetime.
    $game.WaitForExit()
    $gameExitCode = $game.ExitCode

    # Request immediate clean FreeMouse shutdown rather than making it wait
    # through its game-process disappearance grace period.
    if (Test-RuntimeMutex) {
        Set-Content -Encoding ASCII -LiteralPath $stopFile -Value "stop"
        Wait-RuntimeExit -Seconds 5
    }

    Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath $stopFile

    exit $gameExitCode
}
catch {
    @"
WR FreeMouse launch coordinator failed.
Time: $(Get-Date -Format o)

$($_.Exception.ToString())
"@ | Set-Content -Encoding UTF8 -LiteralPath $launchErrorPath

    exit 1
}
