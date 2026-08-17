param(
    [int]$LauncherPid = 0,
    [int]$SettleAfterFocusMs = 35,
    [int]$MaxGuardMs = 120,
    [int]$GuardRadiusPixels = 3,
    [int]$MaxMinutes = 1440,

    # cursor.png is 128x128. Screenshot matching on the user's 2560x1440
    # game view gives a 37px rendered canvas. The visible arrow occupies
    # roughly 34-35px within that canvas.
    [int]$CursorRenderSize = 37,

    # Approximate tip/hotspot in the original 128x128 W&R asset.
    # At 37px this becomes ~2,2 physical pixels.
    [int]$CursorSourceHotspotX = 8,
    [int]$CursorSourceHotspotY = 6
)

$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$stopFile = Join-Path $scriptRoot "stop requested.flag"
$errorPath = Join-Path $scriptRoot "WR FreeMouse error.txt"
$statusPath = Join-Path $scriptRoot "runtime status.json"
$statePath = Join-Path $scriptRoot "WR FreeMouse state.json"

# Single source of truth for the version: the installed state, which Setup
# writes from Package version.json. Falls back to "unknown" if unavailable.
$version = "unknown"
if (Test-Path -LiteralPath $statePath) {
    try {
        $version = [string](Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json).Version
    }
    catch { }
}

Remove-Item $stopFile -Force -ErrorAction SilentlyContinue
Remove-Item $errorPath -Force -ErrorAction SilentlyContinue

# Single-instance lock. The mutex is the authoritative running-state signal used
# by the optional observation-only debugger. Windows releases it automatically
# if this PowerShell process exits unexpectedly.
$runtimeMutexCreated = $false
$runtimeMutex = New-Object System.Threading.Mutex(
    $true,
    "Local\WRFreeMouse.Runtime.784150",
    [ref]$runtimeMutexCreated
)

if (-not $runtimeMutexCreated) {
    exit 0
}

function Write-RuntimeStatus {
    param(
        [string]$Phase,
        [int]$GamePid = 0,
        [IntPtr]$GameHwnd = [IntPtr]::Zero,
        [string]$Note = ""
    )

    $status = [ordered]@{
        Version = $version
        RuntimePid = $PID
        LauncherPid = $LauncherPid
        Phase = $Phase
        Started = $script:RuntimeStartedAt
        Updated = (Get-Date -Format o)
        GamePid = $GamePid
        GameHwnd = if ($GameHwnd -ne [IntPtr]::Zero) {
            "0x{0:X}" -f $GameHwnd.ToInt64()
        }
        else {
            ""
        }
        Note = $Note
    }

    $tempStatusPath = "$statusPath.tmp"

    $status |
        ConvertTo-Json -Compress |
        Set-Content -Encoding UTF8 -LiteralPath $tempStatusPath

    Move-Item -Force -LiteralPath $tempStatusPath -Destination $statusPath
}

function Remove-RuntimeStatus {
    Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath $statusPath
}

$script:RuntimeStartedAt = Get-Date -Format o
Write-RuntimeStatus `
    -Phase "Starting" `
    -Note $(if ($LauncherPid -gt 0) {
        "Started by the Steam launch wrapper with an exact W&R setup-process PID."
    }
    else {
        "Started manually/debug without a Steam setup-process PID."
    })

# Steam starts W&R's native configuration / DirectX launcher first.
# The Steam wrapper passes that exact process PID through -LauncherPid.
# The runtime therefore waits on the launcher PROCESS LIFETIME, not on a clock.
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

function Test-ProcessAlive {
    param([int]$ProcessId)

    if ($ProcessId -le 0) {
        return $false
    }

    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        return (-not $process.HasExited)
    }
    catch {
        return $false
    }
}

$game = Get-WRGameProcess

if (-not $game -and $LauncherPid -gt 0) {
    Write-RuntimeStatus `
        -Phase "WaitingForGame" `
        -Note "Waiting on the exact W&R setup/DirectX launcher process lifetime."

    # Normal Steam path. The W&R setup/DirectX launcher may stay open for as
    # long as the user wants; WR FreeMouse does not time out while it is alive.
    while (
        -not $game -and
        (Test-ProcessAlive -ProcessId $LauncherPid)
    ) {
        Start-Sleep -Milliseconds 100
        $game = Get-WRGameProcess
    }

    if (-not $game) {
        # Startup tracing showed SOVIET64 is created just before the setup
        # process exits and its real window follows about 100 ms later.
        # This grace is only for that process/window creation race.
        $handoffDeadline = (Get-Date).AddSeconds(5)

        while (
            -not $game -and
            (Get-Date) -lt $handoffDeadline
        ) {
            Start-Sleep -Milliseconds 50
            $game = Get-WRGameProcess
        }
    }

    if (-not $game) {
        # The user closed/cancelled the W&R setup window or game startup failed.
        # This is a normal clean exit for WR FreeMouse.
        Remove-RuntimeStatus

        if ($runtimeMutex) {
            try { $runtimeMutex.ReleaseMutex() } catch { }
            try { $runtimeMutex.Dispose() } catch { }
        }

        exit 0
    }
}
elseif (-not $game) {
    # Manual/debug runtime start has no Steam launcher PID to anchor the wait.
    # Keep this bounded so a manual helper does not remain resident forever.
    $manualDeadline = (Get-Date).AddMinutes(3)

    while (
        -not $game -and
        (Get-Date) -lt $manualDeadline
    ) {
        Start-Sleep -Milliseconds 200
        $game = Get-WRGameProcess
    }

    if (-not $game) {
        @"
WR FreeMouse could not find the actual Workers & Resources game window
within 3 minutes of a manual/debug runtime start.
Time: $(Get-Date -Format o)
"@ | Set-Content -Encoding UTF8 $errorPath

        Remove-RuntimeStatus

        if ($runtimeMutex) {
            try { $runtimeMutex.ReleaseMutex() } catch { }
            try { $runtimeMutex.Dispose() } catch { }
        }

        exit 1
    }
}

$gameHwnd = [IntPtr]$game.MainWindowHandle

$gameExePath = $null
try {
    $gameExePath = $game.Path
}
catch { }

if (-not $gameExePath) {
    try {
        $gameExePath = $game.MainModule.FileName
    }
    catch { }
}

$cursorAssetPath = ""
if ($gameExePath) {
    $gameRoot = Split-Path -Parent $gameExePath
    $cursorAssetPath = Join-Path $gameRoot "media_soviet\editor\cursor.png"
}


# WinForms/System.Drawing provide the click-through cursor overlay. The helper
# loads W&R's own media_soviet\editor\cursor.png and renders it as a
# per-pixel-alpha layered window. If the asset cannot be loaded, the helper
# falls back to the standard Windows arrow.
try {
    Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$wrReferences = @(
    [System.Windows.Forms.Form].Assembly.Location,
    [System.Drawing.Bitmap].Assembly.Location
)


# WRFM_CORE_CSHARP_BEGIN
Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Text;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Windows.Forms;

public static class WRFreeMouse
{
    private const int WH_MOUSE_LL = 14;
    private const int HC_ACTION = 0;

    private const int WM_MOUSEMOVE = 0x0200;
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
    private const uint GW_HWNDNEXT = 2;

    private const int GWL_EXSTYLE = -20;

    private const long WS_EX_TOPMOST = 0x00000008L;
    private const long WS_EX_TRANSPARENT = 0x00000020L;
    private const long WS_EX_TOOLWINDOW = 0x00000080L;
    private const long WS_EX_LAYERED = 0x00080000L;
    private const long WS_EX_NOACTIVATE = 0x08000000L;

    private const uint ULW_ALPHA = 0x00000002;
    private const byte AC_SRC_OVER = 0x00;
    private const byte AC_SRC_ALPHA = 0x01;

    private const uint CURSOR_SHOWING = 0x00000001;
    private const uint CURSOR_SUPPRESSED = 0x00000002;

    private const uint INPUT_KEYBOARD = 1;
    private const uint KEYEVENTF_KEYUP = 0x0002;
    private const uint VK_F24 = 0x87;

    private const int WM_HOTKEY = 0x0312;
    private const uint MOD_NOREPEAT = 0x4000;
    private const int HOTKEY_ID = 0x6A31;

    private const uint EVENT_SYSTEM_FOREGROUND = 0x0003;
    private const uint EVENT_SYSTEM_MOVESIZESTART = 0x000A;
    private const uint EVENT_SYSTEM_MOVESIZEEND = 0x000B;
    private const uint WINEVENT_OUTOFCONTEXT = 0x0000;
    private const uint WINEVENT_SKIPOWNPROCESS = 0x0002;

    private static IntPtr _gameHwnd;
    private static int _gamePid;

    private static string _stopFile;
    private static DateTime _endTime;

    // W&R can replace/restart its visible process during startup. The runtime
    // therefore rebinds to a new visible SOVIET64/SOVIET process instead of
    // treating the first tracked PID disappearing as an immediate game exit.
    private static DateTime _gameMissingSince = DateTime.MinValue;
    private const int GAME_REBIND_GRACE_MS = 8000;

    private static int _settleAfterFocusMs;
    private static int _maxGuardMs;
    private static int _guardRadiusPixels;

    private static readonly object _guardLock = new object();

    private static LowLevelMouseProc _mouseProc;
    private static IntPtr _mouseHook = IntPtr.Zero;

    private static WinEventDelegate _winEventProc;
    private static IntPtr _foregroundHook = IntPtr.Zero;
    private static IntPtr _moveSizeHook = IntPtr.Zero;

    private static System.Threading.Timer _timer;
    private static uint _messageThreadId;

    // Outgoing click guard
    private static bool _guardActive = false;
    private static int _guardId = 0;
    private static POINT _guardPoint;
    private static RECT _guardRect;
    private static DateTime _guardStarted = DateTime.MinValue;

    private static int _suppressedMoves = 0;
    private static double _largestSuppressedJump = 0.0;

    // Helper cursor overlay
    private static CursorOverlayController _overlay;
    private static bool _overlayVisible = false;

    // Neutral focus sink. A registered global F24 hotkey gives the helper an
    // input event; the WM_HOTKEY handler then requests foreground for the
    // invisible sink before the user's next physical desktop click.
    private static HotkeySinkController _hotkeySink;
    private static DateTime _lastSinkRequest = DateTime.MinValue;

    // Return-to-W&R click diagnostic
    private static bool _returnClickPending = false;
    private static POINT _returnClickPoint;
    private static DateTime _returnClickTime = DateTime.MinValue;

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SIZE
    {
        public int cx;
        public int cy;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    private struct BLENDFUNCTION
    {
        public byte BlendOp;
        public byte BlendFlags;
        public byte SourceConstantAlpha;
        public byte AlphaFormat;
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
    private struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct HARDWAREINPUT
    {
        public uint uMsg;
        public ushort wParamL;
        public ushort wParamH;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct INPUTUNION
    {
        [FieldOffset(0)]
        public MOUSEINPUT mi;

        [FieldOffset(0)]
        public KEYBDINPUT ki;

        [FieldOffset(0)]
        public HARDWAREINPUT hi;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT
    {
        public uint type;
        public INPUTUNION U;
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

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetProcessDpiAwarenessContext(IntPtr value);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(
        int idHook,
        LowLevelMouseProc lpfn,
        IntPtr hMod,
        uint dwThreadId
    );

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(
        IntPtr hhk,
        int nCode,
        IntPtr wParam,
        IntPtr lParam
    );

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
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

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool PostThreadMessage(
        uint idThread,
        uint Msg,
        IntPtr wParam,
        IntPtr lParam
    );

    [DllImport("user32.dll", EntryPoint = "ClipCursor", SetLastError = true)]
    private static extern bool SetClip(ref RECT lpRect);

    [DllImport("user32.dll", EntryPoint = "ClipCursor", SetLastError = true)]
    private static extern bool ReleaseClip(IntPtr lpRect);

    [DllImport("user32.dll")]
    private static extern bool GetCursorPos(out POINT lpPoint);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetCursorPos(int X, int Y);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(
        uint cInputs,
        INPUT[] pInputs,
        int cbSize
    );

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RegisterHotKey(
        IntPtr hWnd,
        int id,
        uint fsModifiers,
        uint vk
    );

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnregisterHotKey(
        IntPtr hWnd,
        int id
    );

    [DllImport("user32.dll")]
    private static extern IntPtr WindowFromPoint(POINT Point);

    [DllImport("user32.dll")]
    private static extern IntPtr GetAncestor(IntPtr hwnd, uint gaFlags);

    [DllImport("user32.dll")]
    private static extern IntPtr GetTopWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern bool IsIconic(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);

    [DllImport("user32.dll")]
    private static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int nIndex);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(
        IntPtr hWnd,
        StringBuilder lpClassName,
        int nMaxCount
    );




    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetCursorInfo(ref CURSORINFO pci);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetIconInfo(IntPtr hIcon, out ICONINFO piconinfo);

    [DllImport("gdi32.dll")]
    private static extern bool DeleteObject(IntPtr hObject);

    [DllImport("user32.dll")]
    private static extern IntPtr GetDC(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern int ReleaseDC(
        IntPtr hWnd,
        IntPtr hDC
    );

    [DllImport("gdi32.dll")]
    private static extern IntPtr CreateCompatibleDC(
        IntPtr hdc
    );

    [DllImport("gdi32.dll")]
    private static extern bool DeleteDC(
        IntPtr hdc
    );

    [DllImport("gdi32.dll")]
    private static extern IntPtr SelectObject(
        IntPtr hdc,
        IntPtr hgdiobj
    );

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UpdateLayeredWindow(
        IntPtr hwnd,
        IntPtr hdcDst,
        ref POINT pptDst,
        ref SIZE psize,
        IntPtr hdcSrc,
        ref POINT pprSrc,
        uint crKey,
        ref BLENDFUNCTION pblend,
        uint dwFlags
    );

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


    private static double Distance(POINT a, POINT b)
    {
        long dx = (long)a.X - b.X;
        long dy = (long)a.Y - b.Y;

        return Math.Sqrt(
            (double)(dx * dx + dy * dy)
        );
    }

    private static string WindowClass(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero) return "";

        StringBuilder sb = new StringBuilder(256);
        GetClassName(hwnd, sb, sb.Capacity);
        return sb.ToString();
    }





    private static bool PointInRect(RECT r, POINT p)
    {
        return
            p.X >= r.Left &&
            p.X < r.Right &&
            p.Y >= r.Top &&
            p.Y < r.Bottom;
    }

    // Returns the first visible top-level window at the point while ignoring
    // our own cursor overlay. This lets us distinguish exposed W&R from a
    // browser/Discord/Terminal window that happens to cover the same pixels.
    private static IntPtr TopLevelAtIgnoringHelper(
        POINT point,
        IntPtr helperHwnd
    )
    {
        IntPtr hwnd = GetTopWindow(IntPtr.Zero);
        int safety = 0;

        while (hwnd != IntPtr.Zero && safety < 5000)
        {
            if (
                hwnd != helperHwnd &&
                IsWindowVisible(hwnd) &&
                !IsIconic(hwnd)
            )
            {
                RECT r;

                if (
                    GetWindowRect(hwnd, out r) &&
                    PointInRect(r, point)
                )
                {
                    return hwnd;
                }
            }

            hwnd = GetWindow(hwnd, GW_HWNDNEXT);
            safety++;
        }

        return IntPtr.Zero;
    }

    private static bool IsTaskbarClass(string cls)
    {
        return
            cls == "Shell_TrayWnd" ||
            cls == "Shell_SecondaryTrayWnd";
    }

    private static bool IsExcludedShellClass(string cls)
    {
        return
            cls == "Progman" ||
            cls == "WorkerW" ||
            cls == "ForegroundStaging" ||
            cls == "XamlExplorerHostIslandWindow" ||
            cls == "Xaml_WindowedPopupClass";
    }

    private static bool IsGuardableTarget(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero || hwnd == _gameHwnd) {
            return false;
        }

        if (!IsWindowVisible(hwnd)) {
            return false;
        }

        string cls = WindowClass(hwnd);

        // Windows taskbars are explicitly guardable so direct taskbar clicks
        // from active W&R receive the same outgoing-click protection.
        if (IsTaskbarClass(cls)) {
            return true;
        }

        if (IsExcludedShellClass(cls)) {
            return false;
        }

        long exStyle =
            GetWindowLongPtr(
                hwnd,
                GWL_EXSTYLE
            ).ToInt64();

        if ((exStyle & WS_EX_NOACTIVATE) != 0) {
            return false;
        }

        return true;
    }

    private static IntPtr RootAt(POINT point)
    {
        IntPtr hwnd = WindowFromPoint(point);

        if (hwnd == IntPtr.Zero) {
            return IntPtr.Zero;
        }

        IntPtr root = GetAncestor(hwnd, GA_ROOT);

        return root != IntPtr.Zero
            ? root
            : hwnd;
    }

    // Runtime build intentionally contains no diagnostic input logger.
    // Core code keeps Log() call sites as zero-cost documentation hooks.
    private static CURSORINFO ReadCursorInfo()
    {
        CURSORINFO ci =
            new CURSORINFO();

        ci.cbSize =
            Marshal.SizeOf(
                typeof(CURSORINFO)
            );

        if (!GetCursorInfo(ref ci))
        {
            ci.flags =
                0xFFFFFFFF;

            ci.hCursor =
                IntPtr.Zero;
        }

        return ci;
    }


    private static void RequestHotkeySink(
        POINT point,
        IntPtr underPointer
    )
    {
        if (_hotkeySink == null)
        {
            return;
        }

        if (
            (DateTime.Now - _lastSinkRequest)
                .TotalMilliseconds < 35
        )
        {
            return;
        }

        _lastSinkRequest =
            DateTime.Now;

        bool requested =
            _hotkeySink.RequestActivation();

    }

    private static void ApplyPin()
    {
        RECT rect;

        lock (_guardLock)
        {
            if (!_guardActive) {
                return;
            }

            rect = _guardRect;
        }

        SetClip(ref rect);
    }

    private static void StartGuard(
        POINT point,
        IntPtr target
    )
    {
        int id;

        lock (_guardLock)
        {
            if (_guardActive) {
                return;
            }

            _guardId++;
            id = _guardId;

            _guardPoint = point;
            _guardStarted = DateTime.Now;

            _suppressedMoves = 0;
            _largestSuppressedJump = 0.0;

            int r = _guardRadiusPixels;

            _guardRect = new RECT {
                Left = point.X - r,
                Top = point.Y - r,
                Right = point.X + r + 1,
                Bottom = point.Y + r + 1
            };

            _guardActive = true;
        }

        ApplyPin();


        Thread worker = new Thread(delegate()
        {
            Stopwatch sw = Stopwatch.StartNew();

            bool foregroundChanged = false;
            long foregroundChangedAt = -1;

            try
            {
                while (
                    sw.ElapsedMilliseconds <
                    _maxGuardMs
                )
                {
                    bool stillActive;

                    lock (_guardLock)
                    {
                        stillActive =
                            _guardActive &&
                            _guardId == id;
                    }

                    if (!stillActive) {
                        break;
                    }

                    ApplyPin();

                    POINT now;

                    if (GetCursorPos(out now))
                    {
                        double distance =
                            Distance(now, point);

                        if (
                            distance >
                            _guardRadiusPixels + 2
                        )
                        {
                            SetCursorPos(
                                point.X,
                                point.Y
                            );

                            lock (_guardLock)
                            {
                                if (
                                    distance >
                                    _largestSuppressedJump
                                )
                                {
                                    _largestSuppressedJump =
                                        distance;
                                }
                            }
                        }
                    }

                    IntPtr fg =
                        GetForegroundWindow();

                    if (
                        !foregroundChanged &&
                        fg != _gameHwnd
                    )
                    {
                        foregroundChanged = true;
                        foregroundChangedAt =
                            sw.ElapsedMilliseconds;

                    }

                    if (
                        foregroundChanged &&
                        sw.ElapsedMilliseconds -
                        foregroundChangedAt >=
                        _settleAfterFocusMs
                    )
                    {
                        break;
                    }

                    Thread.SpinWait(2500);
                }
            }
            finally
            {
                int moves;
                double largest;

                lock (_guardLock)
                {
                    moves = _suppressedMoves;
                    largest =
                        _largestSuppressedJump;

                    if (_guardId == id) {
                        _guardActive = false;
                    }
                }

                ReleaseClip(IntPtr.Zero);

            }
        });

        worker.IsBackground = true;
        worker.Priority =
            ThreadPriority.AboveNormal;

        worker.Start();
    }

    private static IntPtr MouseCallback(
        int nCode,
        IntPtr wParam,
        IntPtr lParam
    )
    {
        if (nCode < HC_ACTION)
        {
            return CallNextHookEx(
                _mouseHook,
                nCode,
                wParam,
                lParam
            );
        }

        MSLLHOOKSTRUCT data =
            Marshal.PtrToStructure<MSLLHOOKSTRUCT>(
                lParam
            );

        int msg = wParam.ToInt32();
        POINT point = data.pt;


        if (msg == WM_LBUTTONDOWN)
        {
            IntPtr foreground =
                GetForegroundWindow();

            IntPtr target =
                RootAt(point);

            if (
                foreground == _gameHwnd &&
                IsGuardableTarget(target)
            )
            {

                StartGuard(
                    point,
                    target
                );
            }
            else if (
                foreground != _gameHwnd &&
                target == _gameHwnd
            )
            {
                _returnClickPending = true;
                _returnClickPoint = point;
                _returnClickTime =
                    DateTime.Now;

            }
        }
        else if (msg == WM_MOUSEMOVE)
        {
            IntPtr foregroundNow =
                GetForegroundWindow();

            if (foregroundNow == _gameHwnd)
            {
                IntPtr underPointer =
                    RootAt(point);

                if (
                    underPointer != IntPtr.Zero &&
                    underPointer != _gameHwnd
                )
                {
                    RequestHotkeySink(
                        point,
                        underPointer
                    );
                }
            }

            bool guardActive;
            POINT origin;
            int guardId;

            lock (_guardLock)
            {
                guardActive =
                    _guardActive;

                origin =
                    _guardPoint;

                guardId =
                    _guardId;
            }

            if (guardActive)
            {
                double distance =
                    Distance(
                        point,
                        origin
                    );

                if (
                    distance >
                    _guardRadiusPixels + 2
                )
                {
                    lock (_guardLock)
                    {
                        _suppressedMoves++;

                        if (
                            distance >
                            _largestSuppressedJump
                        )
                        {
                            _largestSuppressedJump =
                                distance;
                        }
                    }

                    SetCursorPos(
                        origin.X,
                        origin.Y
                    );


                    return new IntPtr(1);
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
        IntPtr hWinEventHook,
        uint eventType,
        IntPtr hwnd,
        int idObject,
        int idChild,
        uint idEventThread,
        uint dwmsEventTime
    )
    {
        string name;

        if (eventType ==
            EVENT_SYSTEM_FOREGROUND)
        {
            name = "FOREGROUND";
        }
        else if (
            eventType ==
            EVENT_SYSTEM_MOVESIZESTART
        )
        {
            name = "MOVESIZE_START";
        }
        else if (
            eventType ==
            EVENT_SYSTEM_MOVESIZEEND
        )
        {
            name = "MOVESIZE_END";
        }
        else
        {
            name =
                "EVENT_0x" +
                eventType.ToString("X");
        }


        if (
            eventType ==
            EVENT_SYSTEM_FOREGROUND &&
            hwnd == _gameHwnd &&
            _returnClickPending
        )
        {
            _returnClickPending = false;

            POINT now;
            GetCursorPos(out now);

            double distance =
                Distance(
                    now,
                    _returnClickPoint
                );

            double elapsed =
                (DateTime.Now -
                 _returnClickTime)
                .TotalMilliseconds;

        }
    }

    private static void UpdateHelperCursor(
        IntPtr foreground
    )
    {
        if (_overlay == null) {
            return;
        }

        if (foreground == _gameHwnd)
        {
            if (_overlayVisible)
            {
                _overlay.HideOverlay();
                _overlayVisible = false;

            }

            return;
        }

        POINT point;

        if (!GetCursorPos(out point))
        {
            return;
        }

        IntPtr helperHwnd =
            _overlay.WindowHandle;

        IntPtr actualTop =
            TopLevelAtIgnoringHelper(
                point,
                helperHwnd
            );

        bool exposedWR =
            actualTop == _gameHwnd;

        CURSORINFO ci =
            ReadCursorInfo();

        bool systemCursorShowing =
            ci.flags != 0xFFFFFFFF &&
            (ci.flags &
             CURSOR_SHOWING) != 0;

        if (
            exposedWR &&
            !systemCursorShowing
        )
        {
            _overlay.ShowAt(
                point.X,
                point.Y
            );

            if (!_overlayVisible)
            {
                _overlayVisible = true;

            }
        }
        else
        {
            if (_overlayVisible)
            {
                _overlay.HideOverlay();
                _overlayVisible = false;

            }
        }
    }

    private static bool TryBindVisibleGameProcess()
    {
        string[] processNames =
            new string[] {
                "SOVIET64",
                "SOVIET"
            };

        Process best =
            null;

        DateTime bestStart =
            DateTime.MinValue;

        foreach (
            string processName in
            processNames
        )
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

            foreach (
                Process candidate in
                processes
            )
            {
                try
                {
                    IntPtr candidateHwnd =
                        candidate.MainWindowHandle;

                    if (
                        candidate.HasExited ||
                        candidateHwnd ==
                            IntPtr.Zero ||
                        !String.Equals(
                            WindowClass(
                                candidateHwnd
                            ),
                            "Workers & Resources: Soviet Republic",
                            StringComparison.Ordinal
                        )
                    )
                    {
                        candidate.Dispose();
                        continue;
                    }

                    DateTime startTime =
                        DateTime.MinValue;

                    try
                    {
                        startTime =
                            candidate.StartTime;
                    }
                    catch { }

                    if (
                        best == null ||
                        startTime >= bestStart
                    )
                    {
                        if (best != null)
                        {
                            best.Dispose();
                        }

                        best =
                            candidate;

                        bestStart =
                            startTime;
                    }
                    else
                    {
                        candidate.Dispose();
                    }
                }
                catch
                {
                    try
                    {
                        candidate.Dispose();
                    }
                    catch { }
                }
            }
        }

        if (best == null)
        {
            return false;
        }

        try
        {
            _gamePid =
                best.Id;

            _gameHwnd =
                best.MainWindowHandle;

            _gameMissingSince =
                DateTime.MinValue;

            return
                _gameHwnd !=
                IntPtr.Zero;
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
                    IntPtr currentHwnd =
                        current.MainWindowHandle;

                    if (
                        currentHwnd !=
                            IntPtr.Zero &&
                        String.Equals(
                            WindowClass(
                                currentHwnd
                            ),
                            "Workers & Resources: Soviet Republic",
                            StringComparison.Ordinal
                        )
                    )
                    {
                        _gameHwnd =
                            currentHwnd;

                        _gameMissingSince =
                            DateTime.MinValue;

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

        // The originally tracked PID/window disappeared. Search for the
        // replacement W&R process before deciding the game was closed.
        if (TryBindVisibleGameProcess())
        {
            return true;
        }

        if (
            _gameMissingSince ==
            DateTime.MinValue
        )
        {
            _gameMissingSince =
                DateTime.Now;

            return true;
        }

        return
            (DateTime.Now -
                _gameMissingSince)
            .TotalMilliseconds <
            GAME_REBIND_GRACE_MS;
    }

    private static void TimerTick(
        object state
    )
    {
        try
        {
            bool guardActive;

            lock (_guardLock)
            {
                guardActive =
                    _guardActive;
            }

            IntPtr foreground =
                GetForegroundWindow();

            if (
                !guardActive &&
                foreground == _gameHwnd
            )
            {
                ReleaseClip(
                    IntPtr.Zero
                );
            }

            UpdateHelperCursor(
                foreground
            );

            bool stop = false;

            if (DateTime.Now >= _endTime)
            {

                stop = true;
            }

            if (
                !stop &&
                File.Exists(_stopFile)
            )
            {

                stop = true;
            }

            if (
                !stop &&
                !EnsureTrackedGameProcess()
            )
            {

                stop = true;
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
        catch
        {
        }
    }

    public static void Run(
        int gamePid,
        IntPtr gameHwnd,
        string stopFile,
        string cursorAssetPath,
        int cursorRenderSize,
        int cursorSourceHotspotX,
        int cursorSourceHotspotY,
        int settleAfterFocusMs,
        int maxGuardMs,
        int guardRadiusPixels,
        int maxMinutes
    )
    {
        try
        {
            // Per-monitor-v2 awareness keeps the helper arrow aligned with
            // physical GetCursorPos coordinates on mixed-DPI monitor setups.
            SetProcessDpiAwarenessContext(
                new IntPtr(-4)
            );
        }
        catch { }

        _gamePid = gamePid;
        _gameHwnd = gameHwnd;
        _stopFile = stopFile;


        _settleAfterFocusMs =
            Math.Max(
                15,
                settleAfterFocusMs
            );

        _maxGuardMs =
            Math.Max(
                _settleAfterFocusMs + 20,
                maxGuardMs
            );

        _guardRadiusPixels =
            Math.Max(
                1,
                guardRadiusPixels
            );

        _endTime =
            DateTime.Now.AddMinutes(
                Math.Max(
                    1,
                    maxMinutes
                )
            );


        try
        {



            _overlay =
                new CursorOverlayController(
                    cursorAssetPath,
                    cursorRenderSize,
                    cursorSourceHotspotX,
                    cursorSourceHotspotY
                );

            _overlay.Start();


            _hotkeySink =
                new HotkeySinkController();

            _hotkeySink.Start();


            if (!_hotkeySink.HotkeyRegistered)
            {
                throw new InvalidOperationException(
                    "WR FreeMouse could not register its internal F24 hotkey. " +
                    "Another application may already be using F24."
                );
            }


            _messageThreadId =
                GetCurrentThreadId();

            _mouseProc =
                MouseCallback;

            _mouseHook =
                SetWindowsHookEx(
                    WH_MOUSE_LL,
                    _mouseProc,
                    GetModuleHandle(null),
                    0
                );


            if (_mouseHook == IntPtr.Zero)
            {
                throw new System.ComponentModel
                    .Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "SetWindowsHookEx(WH_MOUSE_LL) failed"
                    );
            }

            _winEventProc =
                WinEventCallback;

            _foregroundHook =
                SetWinEventHook(
                    EVENT_SYSTEM_FOREGROUND,
                    EVENT_SYSTEM_FOREGROUND,
                    IntPtr.Zero,
                    _winEventProc,
                    0,
                    0,
                    WINEVENT_OUTOFCONTEXT |
                    WINEVENT_SKIPOWNPROCESS
                );

            _moveSizeHook =
                SetWinEventHook(
                    EVENT_SYSTEM_MOVESIZESTART,
                    EVENT_SYSTEM_MOVESIZEEND,
                    IntPtr.Zero,
                    _winEventProc,
                    0,
                    0,
                    WINEVENT_OUTOFCONTEXT |
                    WINEVENT_SKIPOWNPROCESS
                );

            _timer =
                new System.Threading.Timer(
                    TimerTick,
                    null,
                    0,
                    10
                );




            MSG msg;
            sbyte getMessageResult;

            while (
                (getMessageResult =
                    GetMessage(
                        out msg,
                        IntPtr.Zero,
                        0,
                        0
                    )
                ) > 0
            )
            {
                TranslateMessage(ref msg);
                DispatchMessage(ref msg);
            }

        }
        finally
        {
            lock (_guardLock)
            {
                _guardActive = false;
            }

            ReleaseClip(
                IntPtr.Zero
            );

            if (_timer != null)
            {
                _timer.Dispose();
                _timer = null;
            }

            if (_mouseHook != IntPtr.Zero)
            {
                UnhookWindowsHookEx(
                    _mouseHook
                );

                _mouseHook =
                    IntPtr.Zero;
            }

            if (
                _foregroundHook !=
                IntPtr.Zero
            )
            {
                UnhookWinEvent(
                    _foregroundHook
                );

                _foregroundHook =
                    IntPtr.Zero;
            }

            if (
                _moveSizeHook !=
                IntPtr.Zero
            )
            {
                UnhookWinEvent(
                    _moveSizeHook
                );

                _moveSizeHook =
                    IntPtr.Zero;
            }

            if (_overlay != null)
            {
                _overlay.Stop();
                _overlay = null;
            }

            if (_hotkeySink != null)
            {
                _hotkeySink.Stop();
                _hotkeySink = null;
            }



            try
            {
                if (
                    File.Exists(
                        _stopFile
                    )
                )
                {
                    File.Delete(
                        _stopFile
                    );
                }
            }
            catch { }
        }
    }

    // ---------------------------------------------------------------------
    // Click-through helper cursor
    // ---------------------------------------------------------------------

    private sealed class CursorOverlayForm : Form
    {
        private Bitmap _renderBitmap;
        private IntPtr _hBitmap = IntPtr.Zero;

        private int _hotspotX = 0;
        private int _hotspotY = 0;

        public bool UsingGameCursor
        {
            get;
            private set;
        }

        public string CursorStatus
        {
            get;
            private set;
        }

        public string CursorLabel
        {
            get
            {
                return UsingGameCursor
                    ? "W&R game cursor"
                    : "Windows arrow fallback";
            }
        }

        public CursorOverlayForm(
            string cursorAssetPath,
            int renderSize,
            int sourceHotspotX,
            int sourceHotspotY
        )
        {
            FormBorderStyle =
                FormBorderStyle.None;

            ShowInTaskbar = false;
            TopMost = true;

            StartPosition =
                FormStartPosition.Manual;

            AutoScaleMode =
                AutoScaleMode.None;

            Text = "";

            UsingGameCursor = false;

            int safeRenderSize =
                Math.Max(
                    16,
                    Math.Min(
                        256,
                        renderSize
                    )
                );

            try
            {
                if (
                    !String.IsNullOrEmpty(
                        cursorAssetPath
                    ) &&
                    File.Exists(
                        cursorAssetPath
                    )
                )
                {
                    using (
                        Image source =
                            Image.FromFile(
                                cursorAssetPath
                            )
                    )
                    {
                        _renderBitmap =
                            new Bitmap(
                                safeRenderSize,
                                safeRenderSize,
                                PixelFormat
                                    .Format32bppPArgb
                            );

                        using (
                            Graphics g =
                                Graphics.FromImage(
                                    _renderBitmap
                                )
                        )
                        {
                            g.Clear(
                                Color.Transparent
                            );

                            g.CompositingMode =
                                CompositingMode
                                    .SourceCopy;

                            g.CompositingQuality =
                                CompositingQuality
                                    .HighQuality;

                            g.InterpolationMode =
                                InterpolationMode
                                    .HighQualityBicubic;

                            g.PixelOffsetMode =
                                PixelOffsetMode
                                    .HighQuality;

                            g.SmoothingMode =
                                SmoothingMode
                                    .HighQuality;

                            g.DrawImage(
                                source,
                                new Rectangle(
                                    0,
                                    0,
                                    safeRenderSize,
                                    safeRenderSize
                                ),
                                0,
                                0,
                                source.Width,
                                source.Height,
                                GraphicsUnit.Pixel
                            );
                        }

                        _hotspotX =
                            (int)Math.Round(
                                sourceHotspotX *
                                safeRenderSize /
                                (double)source.Width
                            );

                        _hotspotY =
                            (int)Math.Round(
                                sourceHotspotY *
                                safeRenderSize /
                                (double)source.Height
                            );

                        _hotspotX =
                            Math.Max(
                                0,
                                Math.Min(
                                    safeRenderSize - 1,
                                    _hotspotX
                                )
                            );

                        _hotspotY =
                            Math.Max(
                                0,
                                Math.Min(
                                    safeRenderSize - 1,
                                    _hotspotY
                                )
                            );

                        UsingGameCursor = true;

                        CursorStatus =
                            "GameAsset=True" +
                            " Path=\"" +
                            cursorAssetPath +
                            "\"" +
                            " Source=" +
                            source.Width + "x" +
                            source.Height +
                            " Render=" +
                            safeRenderSize + "x" +
                            safeRenderSize +
                            " SourceHotspot=" +
                            sourceHotspotX + "," +
                            sourceHotspotY +
                            " RenderHotspot=" +
                            _hotspotX + "," +
                            _hotspotY;
                    }
                }
            }
            catch (
                Exception ex
            )
            {
                CursorStatus =
                    "GameAssetLoadError=\"" +
                    ex.Message
                      .Replace(
                          "\r",
                          " "
                      )
                      .Replace(
                          "\n",
                          " "
                      ) +
                    "\"";
            }

            if (_renderBitmap == null)
            {
                int fallbackSize =
                    Math.Max(
                        48,
                        Math.Max(
                            Cursors.Arrow.Size.Width,
                            Cursors.Arrow.Size.Height
                        )
                    );

                _renderBitmap =
                    new Bitmap(
                        fallbackSize,
                        fallbackSize,
                        PixelFormat
                            .Format32bppPArgb
                    );

                using (
                    Graphics g =
                        Graphics.FromImage(
                            _renderBitmap
                        )
                )
                {
                    g.Clear(
                        Color.Transparent
                    );

                    Cursors.Arrow.Draw(
                        g,
                        new Rectangle(
                            0,
                            0,
                            Cursors.Arrow.Size.Width,
                            Cursors.Arrow.Size.Height
                        )
                    );
                }

                _hotspotX = 0;
                _hotspotY = 0;

                if (
                    String.IsNullOrEmpty(
                        CursorStatus
                    )
                )
                {
                    CursorStatus =
                        "GameAsset=False" +
                        " Path=\"" +
                        cursorAssetPath +
                        "\"" +
                        " Fallback=WindowsArrow";
                }
                else
                {
                    CursorStatus +=
                        " Fallback=WindowsArrow";
                }
            }

            Width =
                _renderBitmap.Width;

            Height =
                _renderBitmap.Height;

            _hBitmap =
                _renderBitmap.GetHbitmap(
                    Color.FromArgb(
                        0
                    )
                );
        }

        protected override bool ShowWithoutActivation
        {
            get { return true; }
        }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp =
                    base.CreateParams;

                cp.ExStyle |=
                    (int)(
                        WS_EX_LAYERED |
                        WS_EX_NOACTIVATE |
                        WS_EX_TOOLWINDOW |
                        WS_EX_TRANSPARENT
                    );

                return cp;
            }
        }

        private bool ApplyLayeredCursor(
            int cursorX,
            int cursorY
        )
        {
            if (
                _hBitmap ==
                IntPtr.Zero
            )
            {
                return false;
            }

            IntPtr screenDc =
                IntPtr.Zero;

            IntPtr memoryDc =
                IntPtr.Zero;

            IntPtr oldBitmap =
                IntPtr.Zero;

            try
            {
                screenDc =
                    GetDC(
                        IntPtr.Zero
                    );

                if (
                    screenDc ==
                    IntPtr.Zero
                )
                {
                    return false;
                }

                memoryDc =
                    CreateCompatibleDC(
                        screenDc
                    );

                if (
                    memoryDc ==
                    IntPtr.Zero
                )
                {
                    return false;
                }

                oldBitmap =
                    SelectObject(
                        memoryDc,
                        _hBitmap
                    );

                POINT destination =
                    new POINT();

                destination.X =
                    cursorX -
                    _hotspotX;

                destination.Y =
                    cursorY -
                    _hotspotY;

                SIZE size =
                    new SIZE();

                size.cx =
                    _renderBitmap.Width;

                size.cy =
                    _renderBitmap.Height;

                POINT source =
                    new POINT();

                source.X = 0;
                source.Y = 0;

                BLENDFUNCTION blend =
                    new BLENDFUNCTION();

                blend.BlendOp =
                    AC_SRC_OVER;

                blend.BlendFlags = 0;

                blend.SourceConstantAlpha =
                    255;

                blend.AlphaFormat =
                    AC_SRC_ALPHA;

                return
                    UpdateLayeredWindow(
                        Handle,
                        screenDc,
                        ref destination,
                        ref size,
                        memoryDc,
                        ref source,
                        0,
                        ref blend,
                        ULW_ALPHA
                    );
            }
            finally
            {
                if (
                    oldBitmap !=
                    IntPtr.Zero
                )
                {
                    SelectObject(
                        memoryDc,
                        oldBitmap
                    );
                }

                if (
                    memoryDc !=
                    IntPtr.Zero
                )
                {
                    DeleteDC(
                        memoryDc
                    );
                }

                if (
                    screenDc !=
                    IntPtr.Zero
                )
                {
                    ReleaseDC(
                        IntPtr.Zero,
                        screenDc
                    );
                }
            }
        }

        public void ShowCursorAt(
            int cursorX,
            int cursorY
        )
        {
            Location =
                new Point(
                    cursorX -
                    _hotspotX,
                    cursorY -
                    _hotspotY
                );

            if (!Visible)
            {
                Show();
            }

            ApplyLayeredCursor(
                cursorX,
                cursorY
            );
        }

        protected override void WndProc(
            ref Message m
        )
        {
            // WM_NCHITTEST -> HTTRANSPARENT.
            // Keep the visual cursor entirely click-through.
            if (m.Msg == 0x0084)
            {
                m.Result =
                    new IntPtr(-1);

                return;
            }

            base.WndProc(ref m);
        }

        protected override void Dispose(
            bool disposing
        )
        {
            if (
                _hBitmap !=
                IntPtr.Zero
            )
            {
                DeleteObject(
                    _hBitmap
                );

                _hBitmap =
                    IntPtr.Zero;
            }

            if (
                disposing &&
                _renderBitmap !=
                null
            )
            {
                _renderBitmap.Dispose();
                _renderBitmap = null;
            }

            base.Dispose(
                disposing
            );
        }
    }

    private sealed class CursorOverlayController
    {
        private Thread _thread;
        private CursorOverlayForm _form;

        private readonly string _cursorAssetPath;
        private readonly int _renderSize;
        private readonly int _sourceHotspotX;
        private readonly int _sourceHotspotY;

        private readonly ManualResetEvent _ready =
            new ManualResetEvent(false);

        public CursorOverlayController(
            string cursorAssetPath,
            int renderSize,
            int sourceHotspotX,
            int sourceHotspotY
        )
        {
            _cursorAssetPath =
                cursorAssetPath;

            _renderSize =
                renderSize;

            _sourceHotspotX =
                sourceHotspotX;

            _sourceHotspotY =
                sourceHotspotY;
        }

        public IntPtr WindowHandle
        {
            get
            {
                CursorOverlayForm form =
                    _form;

                if (
                    form == null ||
                    form.IsDisposed ||
                    !form.IsHandleCreated
                )
                {
                    return IntPtr.Zero;
                }

                return form.Handle;
            }
        }

        public string CursorStatus
        {
            get
            {
                CursorOverlayForm form =
                    _form;

                return
                    form != null
                    ? form.CursorStatus
                    : "OverlayFormUnavailable";
            }
        }

        public string CursorLabel
        {
            get
            {
                CursorOverlayForm form =
                    _form;

                return
                    form != null
                    ? form.CursorLabel
                    : "cursor overlay";
            }
        }

        public void Start()
        {
            _thread =
                new Thread(delegate()
                {
                    // Windows PowerShell 5.1 uses .NET Framework WinForms,
                    // which has no Application.SetHighDpiMode API.
                    // Process DPI awareness is configured through
                    // SetProcessDpiAwarenessContext(-4).
                    _form =
                        new CursorOverlayForm(
                            _cursorAssetPath,
                            _renderSize,
                            _sourceHotspotX,
                            _sourceHotspotY
                        );

                    IntPtr handle =
                        _form.Handle;

                    _form.Hide();

                    _ready.Set();

                    Application.Run(
                        _form
                    );
                });

            _thread.IsBackground =
                true;

            _thread.SetApartmentState(
                ApartmentState.STA
            );

            _thread.Start();

            _ready.WaitOne(3000);
        }

        public void ShowAt(
            int x,
            int y
        )
        {
            CursorOverlayForm form =
                _form;

            if (
                form == null ||
                form.IsDisposed ||
                !form.IsHandleCreated
            )
            {
                return;
            }

            try
            {
                form.BeginInvoke(
                    new Action(delegate()
                    {
                        form.ShowCursorAt(
                            x,
                            y
                        );
                    })
                );
            }
            catch { }
        }

        public void HideOverlay()
        {
            CursorOverlayForm form =
                _form;

            if (
                form == null ||
                form.IsDisposed ||
                !form.IsHandleCreated
            )
            {
                return;
            }

            try
            {
                form.BeginInvoke(
                    new Action(delegate()
                    {
                        form.Hide();
                    })
                );
            }
            catch { }
        }

        public void Stop()
        {
            CursorOverlayForm form =
                _form;

            if (
                form != null &&
                !form.IsDisposed &&
                form.IsHandleCreated
            )
            {
                try
                {
                    form.BeginInvoke(
                        new Action(delegate()
                        {
                            form.Close();
                        })
                    );
                }
                catch { }
            }

            if (
                _thread != null &&
                _thread.IsAlive
            )
            {
                _thread.Join(1000);
            }

            _ready.Dispose();
        }
    }

    // ---------------------------------------------------------------------
    // Neutral sink activated through a registered global hotkey
    // ---------------------------------------------------------------------

    private sealed class HotkeySinkForm : Form
    {
        public bool Registered { get; private set; }

        public HotkeySinkForm()
        {
            FormBorderStyle =
                FormBorderStyle.None;

            ShowInTaskbar = false;

            StartPosition =
                FormStartPosition.Manual;

            AutoScaleMode =
                AutoScaleMode.None;

            Width = 1;
            Height = 1;

            // Keep the sink on the virtual desktop but effectively invisible.
            Location =
                new Point(0, 0);

            Opacity = 0.01;

            Text = "";

            Registered = false;
        }

        protected override bool ShowWithoutActivation
        {
            get { return true; }
        }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp =
                    base.CreateParams;

                cp.ExStyle |=
                    (int)WS_EX_TOOLWINDOW;

                return cp;
            }
        }

        protected override void OnHandleCreated(
            EventArgs e
        )
        {
            base.OnHandleCreated(e);

            Registered =
                RegisterHotKey(
                    Handle,
                    HOTKEY_ID,
                    MOD_NOREPEAT,
                    VK_F24
                );
        }

        protected override void OnHandleDestroyed(
            EventArgs e
        )
        {
            if (Registered)
            {
                UnregisterHotKey(
                    Handle,
                    HOTKEY_ID
                );

                Registered = false;
            }

            base.OnHandleDestroyed(e);
        }

        protected override void WndProc(
            ref Message m
        )
        {
            if (
                m.Msg == WM_HOTKEY &&
                m.WParam.ToInt32() ==
                    HOTKEY_ID
            )
            {
                IntPtr before =
                    GetForegroundWindow();

                bool result =
                    SetForegroundWindow(
                        Handle
                    );

                IntPtr after =
                    GetForegroundWindow();


                return;
            }

            base.WndProc(ref m);
        }
    }

    private sealed class HotkeySinkController
    {
        private Thread _thread;
        private HotkeySinkForm _form;

        private readonly ManualResetEvent _ready =
            new ManualResetEvent(false);

        public IntPtr WindowHandle
        {
            get
            {
                HotkeySinkForm form =
                    _form;

                if (
                    form == null ||
                    form.IsDisposed ||
                    !form.IsHandleCreated
                )
                {
                    return IntPtr.Zero;
                }

                return form.Handle;
            }
        }

        public bool HotkeyRegistered
        {
            get
            {
                HotkeySinkForm form =
                    _form;

                return
                    form != null &&
                    !form.IsDisposed &&
                    form.Registered;
            }
        }

        public void Start()
        {
            _thread =
                new Thread(delegate()
                {
                    _form =
                        new HotkeySinkForm();

                    IntPtr handle =
                        _form.Handle;

                    _form.Show();

                    _ready.Set();

                    Application.Run(
                        _form
                    );
                });

            _thread.IsBackground =
                true;

            _thread.SetApartmentState(
                ApartmentState.STA
            );

            _thread.Start();

            _ready.WaitOne(3000);
        }

        public bool RequestActivation()
        {
            HotkeySinkForm form =
                _form;

            if (
                form == null ||
                form.IsDisposed ||
                !form.Registered
            )
            {
                return false;
            }

            INPUT[] inputs =
                new INPUT[2];

            inputs[0].type =
                INPUT_KEYBOARD;

            inputs[0].U.ki.wVk =
                (ushort)VK_F24;

            inputs[0].U.ki.dwFlags =
                0;

            inputs[1].type =
                INPUT_KEYBOARD;

            inputs[1].U.ki.wVk =
                (ushort)VK_F24;

            inputs[1].U.ki.dwFlags =
                KEYEVENTF_KEYUP;

            int inputSize =
                Marshal.SizeOf(
                    typeof(INPUT)
                );

            uint sent =
                SendInput(
                    (uint)inputs.Length,
                    inputs,
                    inputSize
                );

            int lastError =
                Marshal.GetLastWin32Error();


            return sent ==
                inputs.Length;
        }

        public void Stop()
        {
            HotkeySinkForm form =
                _form;

            if (
                form != null &&
                !form.IsDisposed &&
                form.IsHandleCreated
            )
            {
                try
                {
                    form.BeginInvoke(
                        new Action(delegate()
                        {
                            form.Close();
                        })
                    );
                }
                catch { }
            }

            if (
                _thread != null &&
                _thread.IsAlive
            )
            {
                _thread.Join(1000);
            }

            _ready.Dispose();
        }
    }
}
"@ -ReferencedAssemblies $wrReferences
# WRFM_CORE_CSHARP_END

}
catch {
    $initializationFatal =
        $_.Exception.ToString() -replace "`r|`n"," "

    @"
WR FreeMouse failed during core initialization.
Time: $(Get-Date -Format o)

$initializationFatal
"@ | Set-Content -Encoding UTF8 $errorPath

    Remove-RuntimeStatus

    if ($runtimeMutex) {
        try { $runtimeMutex.ReleaseMutex() } catch { }
        try { $runtimeMutex.Dispose() } catch { }
    }

    exit 1
}

Write-RuntimeStatus `
    -Phase "Active" `
    -GamePid $game.Id `
    -GameHwnd $gameHwnd `
    -Note "Bound to the actual Workers & Resources game window."

try {
    [WRFreeMouse]::Run(
        $game.Id,
        $gameHwnd,
        $stopFile,
        $cursorAssetPath,
        $CursorRenderSize,
        $CursorSourceHotspotX,
        $CursorSourceHotspotY,
        $SettleAfterFocusMs,
        $MaxGuardMs,
        $GuardRadiusPixels,
        $MaxMinutes
    )
}
catch {
    $fatal = $_.Exception.ToString() -replace "`r|`n"," "
    @"
WR FreeMouse failed.
Time: $(Get-Date -Format o)

$fatal
"@ | Set-Content -Encoding UTF8 $errorPath
}
finally {
    Remove-RuntimeStatus

    if ($runtimeMutex) {
        try { $runtimeMutex.ReleaseMutex() } catch { }
        try { $runtimeMutex.Dispose() } catch { }
    }

}
