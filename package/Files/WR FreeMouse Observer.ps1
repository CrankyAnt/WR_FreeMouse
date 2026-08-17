param(
    [int]$MaxMinutes = 30
)

$ErrorActionPreference = "Stop"

$installDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$runtimeScript = Join-Path $installDir "WR FreeMouse Runtime.ps1"
$statusPath = Join-Path $installDir "runtime status.json"
$statePath = Join-Path $installDir "WR FreeMouse state.json"

# Single source of truth for the version: the installed state, which Setup
# writes from Package version.json. Falls back to "unknown" if unavailable.
$version = "unknown"
if (Test-Path -LiteralPath $statePath) {
    try {
        $version = [string](Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json).Version
    }
    catch { }
}

$desktop = [Environment]::GetFolderPath("Desktop")
$debugPath = Join-Path $desktop "WR FreeMouse debug.txt"

function Test-RuntimeMutex {
    try {
        $m = [System.Threading.Mutex]::OpenExisting("Local\WRFreeMouse.Runtime.784150")
        $m.Dispose()
        return $true
    }
    catch {
        return $false
    }
}

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

$runtimeWasRunning = Test-RuntimeMutex
$runtimeStartedByDebugger = $false
$runtimeExpectedFromSteam = $false
$gameAtDebugStart = Get-WRGameProcess

@"
WR FreeMouse observation report
Version: $version
Started: $(Get-Date -Format o)
Mode: Observation-only debugger
OS: $([System.Environment]::OSVersion.VersionString)
PowerShell: $($PSVersionTable.PSVersion)
64-bit process: $([System.Environment]::Is64BitProcess)
Install folder: $installDir

PRIVACY NOTICE
This optional debugger observes Windows input/focus activity and writes it to
this report. It can record window/process titles, cursor coordinates, mouse
button and wheel events, and selected NON-TEXT keyboard events used for
focus/input debugging (modifiers, navigation/control keys and F1-F24).

It intentionally does NOT record letter or number keys and does not read the
contents of applications. Window titles can still reveal website, document,
conversation or project names.

The debugger is observation-only: it does not alter Steam Launch Options or
installation settings. Review this file before posting it publicly.

Runtime was running when debugger started: $runtimeWasRunning
Actual W&R game window was running when debugger started: $([bool]$gameAtDebugStart)

"@ | Set-Content -Encoding UTF8 $debugPath

$stateReadPath =
    if (Test-Path -LiteralPath $statePath) {
        $statePath
    }
    else {
        $null
    }

if ($stateReadPath) {
    try {
        $state = Get-Content -Raw -LiteralPath $stateReadPath | ConvertFrom-Json
        Add-Content -Encoding UTF8 -Path $debugPath -Value @"
Installation state:
  Version: $($state.Version)
  BuildId: $($state.BuildId)
  Debug tools installed: $($state.DebugToolsInstalled)
  Steam config: $($state.SteamConfigPath)
  Launch wrap mode: $($state.WrapMode)
  Original Launch Options at install/repair: $($state.BaseLaunchOptions)
  Installed Launch Options: $($state.InstalledLaunchOptions)

"@
    }
    catch {
        Add-Content -Encoding UTF8 -Path $debugPath -Value (
            "Installation state could not be parsed: {0}`r`n" -f $_.Exception.Message
        )
    }
}
else {
    Add-Content -Encoding UTF8 -Path $debugPath -Value "Installation state file: NOT PRESENT`r`n"
}

function Write-StartupFact {
    param(
        [string]$Type,
        [string]$Text
    )

    Add-Content -Encoding UTF8 -Path $debugPath -Value (
        "{0}`t{1}`t{2}" -f
        (Get-Date -Format "HH:mm:ss.fff"),
        $Type,
        $Text
    )
}

function Read-RuntimeStatusText {
    if (-not (Test-Path -LiteralPath $statusPath)) {
        return ""
    }

    try {
        return (Get-Content -Raw -LiteralPath $statusPath).Trim()
    }
    catch {
        return "<status-read-failed>"
    }
}

function Get-WRSetupProcess {
    Get-Process -Name "SETUPAPPLICATION SOVIET" -ErrorAction SilentlyContinue |
        Select-Object -First 1
}

function Start-InstalledRuntimeManually {
    if (-not (Test-Path -LiteralPath $runtimeScript)) {
        Write-StartupFact `
            -Type "RUNTIME_START_FAILED" `
            -Text "Installed WR FreeMouse Runtime.ps1 is not present."

        return $false
    }

    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-WindowStyle", "Hidden",
        "-File", ('"{0}"' -f $runtimeScript),
        "-MaxMinutes", "1440"
    )

    $deadline = (Get-Date).AddSeconds(5)

    while (
        -not (Test-RuntimeMutex) -and
        (Get-Date) -lt $deadline
    ) {
        Start-Sleep -Milliseconds 100
    }

    return (Test-RuntimeMutex)
}

Write-Host "WR FreeMouse - observation-only debugger"
Write-Host ""
Write-Host "========================== PRIVACY NOTICE =========================="
Write-Host "This debugger records mouse buttons/wheel, cursor coordinates,"
Write-Host "window/process titles and selected NON-TEXT keys used for debugging."
Write-Host "It does NOT record letter or number keys."
Write-Host "Review the report before posting it publicly."
Write-Host "===================================================================="
Write-Host ""

if ($runtimeWasRunning) {
    Write-Host "WR FreeMouse runtime was already running and was left unchanged."
    Write-StartupFact `
        -Type "STARTUP" `
        -Text "Runtime already running; debugger did not start or replace it."
}
elseif ($gameAtDebugStart) {
    Write-Host "The actual W&R game was already running but WR FreeMouse was not."
    Write-Host "The installed runtime is being started now; no settings are changed."

    Write-StartupFact `
        -Type "STARTUP" `
        -Text "Actual game existed but runtime was absent; debugger is starting the installed runtime manually."

    $runtimeStartedByDebugger =
        Start-InstalledRuntimeManually

    Write-StartupFact `
        -Type "RUNTIME_STATE" `
        -Text ("Manual runtime start result: " + $runtimeStartedByDebugger)
}
else {
    # Critical startup-debug path:
    # do not create the runtime ourselves before Steam is launched. Otherwise
    # we would own the single-instance mutex and prevent Steam's normal
    # LauncherPid-aware runtime from starting.
    $runtimeExpectedFromSteam = $true

    Write-Host "Neither the actual game nor WR FreeMouse runtime was running."
    Write-Host "The debugger will NOT start the runtime yet."
    Write-Host "Start W&R normally from Steam; the normal Steam wrapper must start it."
    Write-Host ""

    Write-StartupFact `
        -Type "STARTUP" `
        -Text "Pre-game debug: runtime intentionally NOT started by debugger; waiting for normal Steam launch."
}

Write-Host "No Steam or installation settings were changed."
Write-Host ""
Write-Host "When enough has been captured, focus THIS debug window and press any key."
Write-Host "The observer will stop; the WR FreeMouse runtime will NOT be stopped."
Write-Host ""

$startupDeadline = (Get-Date).AddMinutes($MaxMinutes)
$lastRuntimePresent = Test-RuntimeMutex
$lastStatusText = Read-RuntimeStatusText
$lastSetupPid = 0
$game = Get-WRGameProcess

while (-not $game -and (Get-Date) -lt $startupDeadline) {
    $runtimePresent = Test-RuntimeMutex

    if ($runtimePresent -ne $lastRuntimePresent) {
        Write-StartupFact `
            -Type "RUNTIME_STATE" `
            -Text ("Runtime mutex present=" + $runtimePresent)

        $lastRuntimePresent = $runtimePresent
    }

    $statusText = Read-RuntimeStatusText

    if ($statusText -cne $lastStatusText) {
        Write-StartupFact `
            -Type "RUNTIME_STATUS" `
            -Text $(if ($statusText) { $statusText } else { "<absent>" })

        $lastStatusText = $statusText
    }

    $setupProcess = Get-WRSetupProcess
    $setupPid = if ($setupProcess) { $setupProcess.Id } else { 0 }

    if ($setupPid -ne $lastSetupPid) {
        Write-StartupFact `
            -Type "WR_SETUP_PROCESS" `
            -Text ("PID=" + $setupPid)

        $lastSetupPid = $setupPid
    }

    try {
        if ([Console]::KeyAvailable) {
            [void][Console]::ReadKey($true)

            Write-StartupFact `
                -Type "STOP" `
                -Text "Observer stopped by a key press before the actual game window appeared."

            break
        }
    }
    catch { }

    Start-Sleep -Milliseconds 100
    $game = Get-WRGameProcess
}

if (-not $game) {
    Write-StartupFact `
        -Type "STARTUP_END" `
        -Text "Actual W&R game window did not appear before the observer ended."

    Write-Host ""
    Write-Host "The actual W&R game window did not appear during this debug session."
    Write-Host "No settings were changed."
    Write-Host ""
    Write-Host "Report:"
    Write-Host "  $debugPath"
    Write-Host ""
    Write-Host "Press any key to close this window."

    try {
        [void][Console]::ReadKey($true)
    }
    catch {
        [void](Read-Host)
    }

    exit 0
}

Write-StartupFact `
    -Type "GAME_WINDOW" `
    -Text (
        "Actual game appeared: PID=" +
        $game.Id +
        " HWND=0x" +
        ([IntPtr]$game.MainWindowHandle).ToInt64().ToString("X")
    )

# If this was a pre-game debug run, give Steam's normal runtime a small chance
# to become active after the game appears. If it did not, record that fact
# before starting the installed runtime manually so the user can continue.
if (
    $runtimeExpectedFromSteam -and
    -not (Test-RuntimeMutex)
) {
    $steamRuntimeDeadline = (Get-Date).AddSeconds(2)

    while (
        -not (Test-RuntimeMutex) -and
        (Get-Date) -lt $steamRuntimeDeadline
    ) {
        Start-Sleep -Milliseconds 100
    }

    if (-not (Test-RuntimeMutex)) {
        Write-StartupFact `
            -Type "RUNTIME_STATE" `
            -Text "Actual game appeared but normal Steam-started WR FreeMouse runtime was still absent after 2 seconds."

        Write-Host "The game is running, but the normal Steam-started WR FreeMouse"
        Write-Host "runtime was still absent. The installed runtime will now be started"
        Write-Host "manually so the rest of the session can be observed."

        $runtimeStartedByDebugger =
            Start-InstalledRuntimeManually

        Write-StartupFact `
            -Type "RUNTIME_STATE" `
            -Text ("Fallback manual runtime start result: " + $runtimeStartedByDebugger)
    }
}

$gameHwnd = [IntPtr]$game.MainWindowHandle

# Drain any console input Windows Terminal buffered while this observer was
# starting. "Press any key" is armed only after active observation begins.
try {
    while ([Console]::KeyAvailable) {
        [void][Console]::ReadKey($true)
    }
}
catch { }

Add-Type -AssemblyName System.Windows.Forms

foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
    Add-Content -Encoding UTF8 -Path $debugPath -Value (
        "Display: {0} Primary={1} Bounds={2},{3}->{4},{5} WorkingArea={6},{7}->{8},{9}" -f
        $screen.DeviceName,
        $screen.Primary,
        $screen.Bounds.Left,
        $screen.Bounds.Top,
        $screen.Bounds.Right,
        $screen.Bounds.Bottom,
        $screen.WorkingArea.Left,
        $screen.WorkingArea.Top,
        $screen.WorkingArea.Right,
        $screen.WorkingArea.Bottom
    )
}

Add-Content -Encoding UTF8 -Path $debugPath -Value @"

W&R PID: $($game.Id)
W&R HWND: $("0x{0:X}" -f $gameHwnd.ToInt64())
Event timeline:
"@

Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Text;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

public static class WRFreeMouseObserver
{
    private const int WH_MOUSE_LL = 14;
    private const int HC_ACTION = 0;

    private const int WM_LBUTTONDOWN = 0x0201;
    private const int WM_LBUTTONUP = 0x0202;
    private const int WM_RBUTTONDOWN = 0x0204;
    private const int WM_RBUTTONUP = 0x0205;
    private const int WM_MBUTTONDOWN = 0x0207;
    private const int WM_MBUTTONUP = 0x0208;
    private const int WM_MOUSEWHEEL = 0x020A;
    private const int WM_XBUTTONDOWN = 0x020B;
    private const int WM_XBUTTONUP = 0x020C;
    private const int WM_MOUSEHWHEEL = 0x020E;
    private const int WM_QUIT = 0x0012;

    private const uint GA_ROOT = 2;
    private const uint EVENT_SYSTEM_FOREGROUND = 0x0003;
    private const uint EVENT_SYSTEM_MOVESIZESTART = 0x000A;
    private const uint EVENT_SYSTEM_MOVESIZEEND = 0x000B;
    private const uint WINEVENT_OUTOFCONTEXT = 0x0000;

    private static IntPtr _gameHwnd;
    private static int _gamePid;
    private static StreamWriter _log;
    private static readonly object _logLock = new object();

    private static LowLevelMouseProc _mouseProc;
    private static IntPtr _mouseHook = IntPtr.Zero;
    private static WinEventDelegate _winEventProc;
    private static IntPtr _foregroundHook = IntPtr.Zero;
    private static IntPtr _moveSizeHook = IntPtr.Zero;
    private static System.Threading.Timer _timer;
    private static uint _messageThreadId;
    private static DateTime _endTime;

    private static bool _returnClickPending = false;
    private static POINT _returnClickPoint;
    private static DateTime _returnClickTime = DateTime.MinValue;

    private static uint _lastCursorFlags = UInt32.MaxValue;
    private static IntPtr _lastCursorHandle = new IntPtr(-1);
    private static bool _lastCursorForegroundWasWR = false;

    private static bool _lastRuntimePresent = false;
    private static bool _runtimeStateInitialized = false;

    private static DateTime _gameMissingSince = DateTime.MinValue;
    private const int GAME_REBIND_GRACE_MS = 8000;
    private static DateTime _consoleStopArmedAt = DateTime.MinValue;

    private static readonly int[] _keyCodes = new int[] {
        0x08,0x09,0x0D,0x10,0x11,0x12,0x13,0x14,0x1B,0x20,
        0x21,0x22,0x23,0x24,0x25,0x26,0x27,0x28,0x2C,0x2D,
        0x2E,0x5B,0x5C,0x5D,
        0x70,0x71,0x72,0x73,0x74,0x75,0x76,0x77,
        0x78,0x79,0x7A,0x7B,0x7C,0x7D,0x7E,0x7F,
        0x80,0x81,0x82,0x83,0x84,0x85,0x86,0x87
    };

    private static readonly string[] _keyNames = new string[] {
        "BACKSPACE","TAB","ENTER","SHIFT","CTRL","ALT","PAUSE","CAPSLOCK",
        "ESC","SPACE","PAGEUP","PAGEDOWN","END","HOME","LEFT","UP","RIGHT","DOWN",
        "PRINTSCREEN","INSERT","DELETE","LWIN","RWIN","APPS",
        "F1","F2","F3","F4","F5","F6","F7","F8",
        "F9","F10","F11","F12","F13","F14","F15","F16",
        "F17","F18","F19","F20","F21","F22","F23","F24"
    };

    private static bool[] _keyStates;

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct CURSORINFO
    {
        public int cbSize;
        public uint flags;
        public IntPtr hCursor;
        public POINT ptScreenPos;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ICONINFO
    {
        [MarshalAs(UnmanagedType.Bool)]
        public bool fIcon;
        public uint xHotspot;
        public uint yHotspot;
        public IntPtr hbmMask;
        public IntPtr hbmColor;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MSLLHOOKSTRUCT
    {
        public POINT pt;
        public uint mouseData;
        public uint flags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MSG
    {
        public IntPtr hwnd;
        public uint message;
        public UIntPtr wParam;
        public IntPtr lParam;
        public uint time;
        public POINT pt;
    }

    private delegate IntPtr LowLevelMouseProc(
        int nCode,
        IntPtr wParam,
        IntPtr lParam
    );

    private delegate void WinEventDelegate(
        IntPtr hWinEventHook,
        uint eventType,
        IntPtr hwnd,
        int idObject,
        int idChild,
        uint idEventThread,
        uint dwmsEventTime
    );

    [DllImport("user32.dll", SetLastError=true)]
    private static extern IntPtr SetWindowsHookEx(
        int idHook,
        LowLevelMouseProc lpfn,
        IntPtr hMod,
        uint dwThreadId
    );

    [DllImport("user32.dll", SetLastError=true)]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(
        IntPtr hhk,
        int nCode,
        IntPtr wParam,
        IntPtr lParam
    );

    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)]
    private static extern IntPtr GetModuleHandle(string lpModuleName);

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();

    [DllImport("user32.dll")]
    private static extern sbyte GetMessage(
        out MSG lpMsg,
        IntPtr hWnd,
        uint wMsgFilterMin,
        uint wMsgFilterMax
    );

    [DllImport("user32.dll")]
    private static extern bool TranslateMessage(ref MSG lpMsg);

    [DllImport("user32.dll")]
    private static extern IntPtr DispatchMessage(ref MSG lpMsg);

    [DllImport("user32.dll", SetLastError=true)]
    private static extern bool PostThreadMessage(
        uint idThread,
        uint Msg,
        IntPtr wParam,
        IntPtr lParam
    );

    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int vKey);

    [DllImport("user32.dll")]
    private static extern bool GetCursorPos(out POINT point);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern IntPtr WindowFromPoint(POINT point);

    [DllImport("user32.dll")]
    private static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);

    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    private static extern int GetWindowText(
        IntPtr hWnd,
        StringBuilder text,
        int count
    );

    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    private static extern int GetClassName(
        IntPtr hWnd,
        StringBuilder cls,
        int count
    );

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(
        IntPtr hWnd,
        out uint pid
    );

    [DllImport("user32.dll")]
    private static extern bool GetCursorInfo(ref CURSORINFO pci);

    [DllImport("user32.dll")]
    private static extern bool GetIconInfo(
        IntPtr hIcon,
        out ICONINFO piconinfo
    );

    [DllImport("gdi32.dll")]
    private static extern bool DeleteObject(IntPtr hObject);

    [DllImport("user32.dll")]
    private static extern IntPtr SetWinEventHook(
        uint eventMin,
        uint eventMax,
        IntPtr hmodWinEventProc,
        WinEventDelegate lpfnWinEventProc,
        uint idProcess,
        uint idThread,
        uint dwFlags
    );

    [DllImport("user32.dll")]
    private static extern bool UnhookWinEvent(IntPtr hWinEventHook);

    private static bool KeyDown(int vk)
    {
        return (GetAsyncKeyState(vk) & 0x8000) != 0;
    }

    private static void Log(string type, string message)
    {
        lock (_logLock)
        {
            _log.WriteLine(
                DateTime.Now.ToString("HH:mm:ss.fff") +
                "\t" + type +
                "\t" + message
            );
            _log.Flush();
        }
    }

    private static string WindowTitle(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero) return "";
        StringBuilder b = new StringBuilder(1024);
        GetWindowText(hwnd, b, b.Capacity);
        return b.ToString().Replace("\t"," ").Replace("\r"," ").Replace("\n"," ");
    }

    private static string WindowClass(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero) return "";
        StringBuilder b = new StringBuilder(256);
        GetClassName(hwnd, b, b.Capacity);
        return b.ToString();
    }

    private static int WindowPid(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero) return 0;
        uint pid;
        GetWindowThreadProcessId(hwnd, out pid);
        return (int)pid;
    }

    private static string ProcessName(int pid)
    {
        if (pid <= 0) return "";
        try { return Process.GetProcessById(pid).ProcessName; }
        catch { return ""; }
    }

    private static string WindowInfo(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero) return "HWND=0x0";
        int pid = WindowPid(hwnd);
        return
            "HWND=0x" + hwnd.ToInt64().ToString("X") +
            " PID=" + pid +
            " PROC=" + ProcessName(pid) +
            " CLASS=\"" + WindowClass(hwnd) + "\"" +
            " TITLE=\"" + WindowTitle(hwnd) + "\"";
    }

    private static IntPtr RootAt(POINT point)
    {
        IntPtr hwnd = WindowFromPoint(point);
        if (hwnd == IntPtr.Zero) return IntPtr.Zero;
        IntPtr root = GetAncestor(hwnd, GA_ROOT);
        return root != IntPtr.Zero ? root : hwnd;
    }

    private static string CursorSnapshot()
    {
        CURSORINFO ci = new CURSORINFO();
        ci.cbSize = Marshal.SizeOf(typeof(CURSORINFO));
        if (!GetCursorInfo(ref ci))
        {
            return "GetCursorInfo=False";
        }

        string hotspot = "unknown";
        ICONINFO ii;
        if (ci.hCursor != IntPtr.Zero && GetIconInfo(ci.hCursor, out ii))
        {
            hotspot = ii.xHotspot + "," + ii.yHotspot;
            if (ii.hbmMask != IntPtr.Zero) DeleteObject(ii.hbmMask);
            if (ii.hbmColor != IntPtr.Zero) DeleteObject(ii.hbmColor);
        }

        return
            "FLAGS=0x" + ci.flags.ToString("X") +
            " HCURSOR=0x" + ci.hCursor.ToInt64().ToString("X") +
            " POS=" + ci.ptScreenPos.X + "," + ci.ptScreenPos.Y +
            " HOTSPOT=" + hotspot;
    }

    private static void ProbeCursor()
    {
        CURSORINFO ci = new CURSORINFO();
        ci.cbSize = Marshal.SizeOf(typeof(CURSORINFO));
        if (!GetCursorInfo(ref ci)) return;

        bool wrFg = GetForegroundWindow() == _gameHwnd;

        if (
            ci.flags != _lastCursorFlags ||
            ci.hCursor != _lastCursorHandle ||
            wrFg != _lastCursorForegroundWasWR
        )
        {
            _lastCursorFlags = ci.flags;
            _lastCursorHandle = ci.hCursor;
            _lastCursorForegroundWasWR = wrFg;

            Log(
                "CURSOR_PROBE",
                "WR_FOREGROUND=" + wrFg + " " + CursorSnapshot()
            );
        }
    }

    private static void PollKeys()
    {
        for (int i = 0; i < _keyCodes.Length; i++)
        {
            bool down = KeyDown(_keyCodes[i]);
            if (down != _keyStates[i])
            {
                _keyStates[i] = down;
                POINT p;
                GetCursorPos(out p);
                Log(
                    "KEY",
                    _keyNames[i] + " " + (down ? "DOWN" : "UP") +
                    " POS=" + p.X + "," + p.Y +
                    " Foreground={" + WindowInfo(GetForegroundWindow()) + "}"
                );
            }
        }
    }

    private static string MouseEventName(int msg, MSLLHOOKSTRUCT d)
    {
        switch (msg)
        {
            case WM_LBUTTONDOWN: return "LBUTTON DOWN";
            case WM_LBUTTONUP: return "LBUTTON UP";
            case WM_RBUTTONDOWN: return "RBUTTON DOWN";
            case WM_RBUTTONUP: return "RBUTTON UP";
            case WM_MBUTTONDOWN: return "MBUTTON DOWN";
            case WM_MBUTTONUP: return "MBUTTON UP";
            case WM_XBUTTONDOWN: return "XBUTTON DOWN " + ((d.mouseData >> 16) & 0xFFFF);
            case WM_XBUTTONUP: return "XBUTTON UP " + ((d.mouseData >> 16) & 0xFFFF);
            case WM_MOUSEWHEEL: return "WHEEL " + (short)((d.mouseData >> 16) & 0xFFFF);
            case WM_MOUSEHWHEEL: return "HWHEEL " + (short)((d.mouseData >> 16) & 0xFFFF);
            default: return null;
        }
    }

    private static IntPtr MouseCallback(
        int nCode,
        IntPtr wParam,
        IntPtr lParam
    )
    {
        if (nCode >= HC_ACTION)
        {
            int msg = wParam.ToInt32();
            MSLLHOOKSTRUCT d =
                (MSLLHOOKSTRUCT)Marshal.PtrToStructure(
                    lParam,
                    typeof(MSLLHOOKSTRUCT)
                );

            string name = MouseEventName(msg, d);
            if (name != null)
            {
                IntPtr target = RootAt(d.pt);
                IntPtr fg = GetForegroundWindow();

                Log(
                    "MOUSE",
                    name +
                    " POS=" + d.pt.X + "," + d.pt.Y +
                    " LLFLAGS=0x" + d.flags.ToString("X") +
                    " Target={" + WindowInfo(target) + "}" +
                    " Foreground={" + WindowInfo(fg) + "}"
                );

                if (
                    msg == WM_LBUTTONDOWN &&
                    fg == _gameHwnd &&
                    target != IntPtr.Zero &&
                    target != _gameHwnd
                )
                {
                    Log(
                        "RACE_DOWN_OBSERVED",
                        "External physical LBUTTONDOWN while W&R was still foreground."
                    );
                }

                if (
                    msg == WM_LBUTTONDOWN &&
                    fg != _gameHwnd &&
                    target == _gameHwnd
                )
                {
                    _returnClickPending = true;
                    _returnClickPoint = d.pt;
                    _returnClickTime = DateTime.Now;

                    Log(
                        "RETURN_CLICK",
                        "DOWN POS=" + d.pt.X + "," + d.pt.Y +
                        " CURSOR={" + CursorSnapshot() + "}"
                    );
                }
            }
        }

        return CallNextHookEx(
            _mouseHook,
            nCode,
            wParam,
            lParam
        );
    }

    private static void WinEventCallback(
        IntPtr hook,
        uint eventType,
        IntPtr hwnd,
        int idObject,
        int idChild,
        uint thread,
        uint time
    )
    {
        if (hwnd == IntPtr.Zero) return;

        if (eventType == EVENT_SYSTEM_FOREGROUND)
        {
            Log(
                "FOREGROUND",
                "WINDOW={" + WindowInfo(hwnd) + "}"
            );

            if (hwnd == _gameHwnd && _returnClickPending)
            {
                _returnClickPending = false;
                POINT now;
                GetCursorPos(out now);

                Log(
                    "RETURN_FOCUS",
                    "AfterMs=" +
                    (DateTime.Now - _returnClickTime).TotalMilliseconds.ToString("F1") +
                    " ClickPos=" + _returnClickPoint.X + "," + _returnClickPoint.Y +
                    " CursorNow=" + now.X + "," + now.Y +
                    " DeltaPx=" +
                    (now.X - _returnClickPoint.X) + "," +
                    (now.Y - _returnClickPoint.Y) +
                    " CURSOR={" + CursorSnapshot() + "}"
                );
            }
        }
        else if (eventType == EVENT_SYSTEM_MOVESIZESTART)
        {
            Log("MOVESIZE_START", "WINDOW={" + WindowInfo(hwnd) + "}");
        }
        else if (eventType == EVENT_SYSTEM_MOVESIZEEND)
        {
            Log("MOVESIZE_END", "WINDOW={" + WindowInfo(hwnd) + "}");
        }
    }

    private static bool TryBindVisibleGameProcess()
    {
        string[] processNames =
            new string[] { "SOVIET64", "SOVIET" };

        Process best = null;
        DateTime bestStart = DateTime.MinValue;

        foreach (string processName in processNames)
        {
            Process[] processes;

            try
            {
                processes =
                    Process.GetProcessesByName(
                        processName
                    );
            }
            catch
            {
                continue;
            }

            foreach (Process candidate in processes)
            {
                try
                {
                    IntPtr hwnd =
                        candidate.MainWindowHandle;

                    if (
                        candidate.HasExited ||
                        hwnd == IntPtr.Zero ||
                        !String.Equals(
                            WindowClass(hwnd),
                            "Workers & Resources: Soviet Republic",
                            StringComparison.Ordinal
                        )
                    )
                    {
                        candidate.Dispose();
                        continue;
                    }

                    DateTime start = DateTime.MinValue;

                    try
                    {
                        start = candidate.StartTime;
                    }
                    catch { }

                    if (
                        best == null ||
                        start >= bestStart
                    )
                    {
                        if (best != null)
                        {
                            best.Dispose();
                        }

                        best = candidate;
                        bestStart = start;
                    }
                    else
                    {
                        candidate.Dispose();
                    }
                }
                catch
                {
                    try { candidate.Dispose(); } catch { }
                }
            }
        }

        if (best == null)
        {
            return false;
        }

        try
        {
            int oldPid = _gamePid;
            IntPtr oldHwnd = _gameHwnd;

            _gamePid = best.Id;
            _gameHwnd = best.MainWindowHandle;
            _gameMissingSince = DateTime.MinValue;

            if (
                oldPid != _gamePid ||
                oldHwnd != _gameHwnd
            )
            {
                Log(
                    "GAME_REBIND",
                    "OldPid=" + oldPid +
                    " NewPid=" + _gamePid +
                    " OldHwnd=0x" +
                    oldHwnd.ToInt64().ToString("X") +
                    " NewHwnd=0x" +
                    _gameHwnd.ToInt64().ToString("X")
                );
            }

            return _gameHwnd != IntPtr.Zero;
        }
        finally
        {
            best.Dispose();
        }
    }

    private static bool EnsureTrackedGameProcess()
    {
        try
        {
            Process current =
                Process.GetProcessById(
                    _gamePid
                );

            try
            {
                if (!current.HasExited)
                {
                    IntPtr hwnd =
                        current.MainWindowHandle;

                    if (
                        hwnd != IntPtr.Zero &&
                        String.Equals(
                            WindowClass(hwnd),
                            "Workers & Resources: Soviet Republic",
                            StringComparison.Ordinal
                        )
                    )
                    {
                        _gameHwnd = hwnd;
                        _gameMissingSince = DateTime.MinValue;
                        return true;
                    }
                }
            }
            finally
            {
                current.Dispose();
            }
        }
        catch { }

        if (TryBindVisibleGameProcess())
        {
            return true;
        }

        if (_gameMissingSince == DateTime.MinValue)
        {
            _gameMissingSince = DateTime.Now;
            return true;
        }

        return
            (DateTime.Now - _gameMissingSince)
            .TotalMilliseconds <
            GAME_REBIND_GRACE_MS;
    }

    private static bool RuntimePresent()
    {
        try
        {
            Mutex runtime =
                Mutex.OpenExisting(
                    "Local\\WRFreeMouse.Runtime.784150"
                );

            runtime.Dispose();
            return true;
        }
        catch
        {
            return false;
        }
    }

    private static void TimerTick(object state)
    {
        try
        {
            PollKeys();
            ProbeCursor();

            bool runtimePresent =
                RuntimePresent();

            if (
                !_runtimeStateInitialized ||
                runtimePresent !=
                    _lastRuntimePresent
            )
            {
                _runtimeStateInitialized =
                    true;

                _lastRuntimePresent =
                    runtimePresent;

                Log(
                    "RUNTIME_STATE",
                    "Runtime mutex present=" +
                    runtimePresent
                );
            }

            bool consoleStop = false;

            try
            {
                if (
                    DateTime.Now >= _consoleStopArmedAt &&
                    Console.KeyAvailable
                )
                {
                    Console.ReadKey(true);
                    consoleStop = true;

                    Log(
                        "STOP",
                        "A key was pressed in the observer console."
                    );
                }
            }
            catch { }

            bool gamePresent =
                EnsureTrackedGameProcess();

            bool stop =
                DateTime.Now >= _endTime ||
                !gamePresent ||
                consoleStop;

            if (
                !gamePresent &&
                !consoleStop
            )
            {
                Log(
                    "STOP",
                    "Actual W&R game remained absent beyond rebind grace."
                );
            }

            if (stop)
            {
                PostThreadMessage(
                    _messageThreadId,
                    WM_QUIT,
                    IntPtr.Zero,
                    IntPtr.Zero
                );
            }
        }
        catch (Exception ex)
        {
            Log(
                "OBSERVER_ERROR",
                ex.ToString().Replace("\r"," ").Replace("\n"," ")
            );
        }
    }


    public static void Run(
        int gamePid,
        IntPtr gameHwnd,
        string logPath,
        int maxMinutes
    )
    {
        _gamePid = gamePid;
        _gameHwnd = gameHwnd;
        _gameMissingSince = DateTime.MinValue;
        _endTime = DateTime.Now.AddMinutes(Math.Max(1, maxMinutes));
        _consoleStopArmedAt = DateTime.Now.AddSeconds(1);

        _log = new StreamWriter(logPath, true, Encoding.UTF8);
        _log.AutoFlush = true;

        _keyStates = new bool[_keyCodes.Length];
        for (int i = 0; i < _keyCodes.Length; i++)
        {
            _keyStates[i] = KeyDown(_keyCodes[i]);
        }

        try
        {
            _messageThreadId = GetCurrentThreadId();

            _mouseProc = MouseCallback;
            _mouseHook = SetWindowsHookEx(
                WH_MOUSE_LL,
                _mouseProc,
                GetModuleHandle(null),
                0
            );

            if (_mouseHook == IntPtr.Zero)
            {
                throw new System.ComponentModel.Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "SetWindowsHookEx(WH_MOUSE_LL) failed"
                );
            }

            _winEventProc = WinEventCallback;

            _foregroundHook = SetWinEventHook(
                EVENT_SYSTEM_FOREGROUND,
                EVENT_SYSTEM_FOREGROUND,
                IntPtr.Zero,
                _winEventProc,
                0,
                0,
                WINEVENT_OUTOFCONTEXT
            );

            _moveSizeHook = SetWinEventHook(
                EVENT_SYSTEM_MOVESIZESTART,
                EVENT_SYSTEM_MOVESIZEEND,
                IntPtr.Zero,
                _winEventProc,
                0,
                0,
                WINEVENT_OUTOFCONTEXT
            );

            _timer = new System.Threading.Timer(
                TimerTick,
                null,
                0,
                10
            );

            Log(
                "OBSERVER_ACTIVE",
                "Observation-only hooks active."
            );

            MSG msg;
            while (
                GetMessage(
                    out msg,
                    IntPtr.Zero,
                    0,
                    0
                ) > 0
            )
            {
                TranslateMessage(ref msg);
                DispatchMessage(ref msg);
            }
        }
        finally
        {
            if (_timer != null)
            {
                _timer.Dispose();
                _timer = null;
            }

            if (_mouseHook != IntPtr.Zero)
            {
                UnhookWindowsHookEx(_mouseHook);
                _mouseHook = IntPtr.Zero;
            }

            if (_foregroundHook != IntPtr.Zero)
            {
                UnhookWinEvent(_foregroundHook);
                _foregroundHook = IntPtr.Zero;
            }

            if (_moveSizeHook != IntPtr.Zero)
            {
                UnhookWinEvent(_moveSizeHook);
                _moveSizeHook = IntPtr.Zero;
            }

            Log(
                "OBSERVER_END",
                "Observation-only debugger stopped."
            );

            _log.Dispose();
            _log = null;
        }
    }
}
"@

try {
    [WRFreeMouseObserver]::Run(
        $game.Id,
        $gameHwnd,
        $debugPath,
        $MaxMinutes
    )
}
catch {
    Add-Content -Encoding UTF8 -Path $debugPath -Value (
        "{0}`tFATAL`t{1}" -f
        (Get-Date -Format "HH:mm:ss.fff"),
        ($_.Exception.ToString() -replace "`r|`n"," ")
    )
}

$runtimeStillRunning = Test-RuntimeMutex

Add-Content -Encoding UTF8 -Path $debugPath -Value @"

Session summary:
  Runtime was running at debug start: $runtimeWasRunning
  Pre-game run expected runtime from normal Steam launch: $runtimeExpectedFromSteam
  Runtime was started by debugger: $runtimeStartedByDebugger
  Runtime is running when debugger ends: $runtimeStillRunning
  Steam/settings changed by debugger: False
"@

Write-Host ""
Write-Host "Debug session ended."
if ($runtimeStillRunning) {
    Write-Host "WR FreeMouse runtime is still running."
}
else {
    Write-Host "WR FreeMouse runtime is not running now."
}
Write-Host "No Steam or installation settings were changed by this debugger."
Write-Host ""
Write-Host "Report:"
Write-Host "  $debugPath"
Write-Host ""
Write-Host "Review the report before attaching it to a public GitHub issue."
Write-Host ""
Write-Host "Press any key to close this window."
try {
    [void][Console]::ReadKey($true)
}
catch {
    [void](Read-Host)
}
