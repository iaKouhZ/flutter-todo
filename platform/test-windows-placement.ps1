param([Parameter(Mandatory = $true)][string]$Executable)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class LedgerWindowPlacement {
    [StructLayout(LayoutKind.Sequential)] public struct Point { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct State {
        public int Length, Flags, Show;
        public Point Min, Max;
        public Rect Normal;
    }
    [DllImport("user32.dll", SetLastError=true)]
    static extern bool GetWindowPlacement(IntPtr window, ref State state);
    [DllImport("user32.dll", SetLastError=true)]
    static extern bool SetWindowPlacement(IntPtr window, ref State state);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int show);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr window);
    [DllImport("user32.dll", SetLastError=true)]
    static extern IntPtr SendMessageTimeout(IntPtr window, uint message, UIntPtr wparam,
        IntPtr lparam, uint flags, uint timeout, out UIntPtr result);
    public static State Read(IntPtr window) {
        var state = new State { Length = Marshal.SizeOf<State>() };
        if (!GetWindowPlacement(window, ref state)) throw new Win32Exception();
        return state;
    }
    public static State Move(IntPtr window, int x, int y, int width, int height) {
        var state = Read(window);
        state.Flags = 0;
        state.Show = 1;
        state.Normal = new Rect { Left=x, Top=y, Right=x+width, Bottom=y+height };
        if (!SetWindowPlacement(window, ref state)) throw new Win32Exception();
        return Read(window);
    }
    public static bool Same(State a, State b) {
        return a.Normal.Left == b.Normal.Left && a.Normal.Top == b.Normal.Top &&
            a.Normal.Right == b.Normal.Right && a.Normal.Bottom == b.Normal.Bottom;
    }
    public static void Session(IntPtr window, bool ending) {
        UIntPtr result;
        if (SendMessageTimeout(window, 0x11, UIntPtr.Zero, IntPtr.Zero, 2, 5000, out result) == IntPtr.Zero)
            throw new Win32Exception();
        if (result.ToUInt64() != 1) throw new Exception("Session-end query was denied");
        if (SendMessageTimeout(window, 0x16, ending ? new UIntPtr(1) : UIntPtr.Zero,
                               IntPtr.Zero, 2, 5000, out result) == IntPtr.Zero)
            throw new Win32Exception();
    }
}
'@
$layout = Join-Path $env:LOCALAPPDATA 'TodoEndfield/window.dat'
$backup = if (Test-Path $layout) { [IO.File]::ReadAllBytes($layout) } else { $null }
$script:desktop = $null
function Start-Desktop {
    $script:desktop = Start-Process -FilePath $Executable -WorkingDirectory $env:RUNNER_TEMP -PassThru
    for ($attempt = 0; $attempt -lt 100; $attempt++) {
        Start-Sleep -Milliseconds 100
        $script:desktop.Refresh()
        if ($script:desktop.HasExited) { throw 'Desktop app exited before showing its window.' }
        if ($script:desktop.MainWindowHandle -ne [IntPtr]::Zero) { return $script:desktop.MainWindowHandle }
    }
    throw 'Desktop window did not become visible.'
}
function Close-Desktop {
    if (-not $script:desktop.CloseMainWindow() -or -not $script:desktop.WaitForExit(10000)) {
        throw 'Desktop app did not close normally.'
    }
    $script:desktop.Dispose()
    $script:desktop = $null
}
try {
    Remove-Item -LiteralPath $layout -Force -ErrorAction SilentlyContinue
    $window = Start-Desktop
    $normal = [LedgerWindowPlacement]::Move($window, 60, 70, 720, 480)
    [LedgerWindowPlacement]::Session($window, $false)
    if (Test-Path $layout) { throw 'Moving or canceling shutdown wrote window state.' }
    Close-Desktop
    if (-not (Test-Path $layout)) { throw 'Normal close did not save window state.' }

    $window = Start-Desktop
    if (-not [LedgerWindowPlacement]::Same($normal, [LedgerWindowPlacement]::Read($window))) {
        throw 'Normal window position and size were not restored.'
    }
    [LedgerWindowPlacement]::ShowWindow($window, 3) | Out-Null
    Close-Desktop

    $window = Start-Desktop
    if (-not [LedgerWindowPlacement]::IsZoomed($window)) { throw 'Maximized state was not restored.' }
    [LedgerWindowPlacement]::ShowWindow($window, 6) | Out-Null
    Close-Desktop

    $window = Start-Desktop
    if ([LedgerWindowPlacement]::IsIconic($window) -or -not [LedgerWindowPlacement]::IsZoomed($window)) {
        throw 'Minimized maximized window did not reopen visibly maximized.'
    }
    $previous = [Convert]::ToBase64String([IO.File]::ReadAllBytes($layout))
    $shutdown = [LedgerWindowPlacement]::Move($window, 100, 110, 760, 500)
    [LedgerWindowPlacement]::Session($window, $false)
    if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($layout)) -ne $previous) {
        throw 'Canceled shutdown changed the saved state.'
    }
    # Simulate only this app's confirmed session-end notification, without
    # shutting down the Actions runner. Windows may terminate without WM_CLOSE.
    [LedgerWindowPlacement]::Session($window, $true)
    Stop-Process -Id $script:desktop.Id -Force
    $script:desktop.WaitForExit()
    $script:desktop.Dispose()
    $script:desktop = $null

    $window = Start-Desktop
    if (-not [LedgerWindowPlacement]::Same($shutdown, [LedgerWindowPlacement]::Read($window))) {
        throw 'Confirmed session end did not save the latest normal placement.'
    }
    Close-Desktop
    Write-Output 'Installed app normal close, restart, maximize, minimize and session-end placement checks passed.'
} finally {
    if ($script:desktop) {
        if (-not $script:desktop.HasExited) { Stop-Process -Id $script:desktop.Id -Force }
        $script:desktop.Dispose()
    }
    if ($null -ne $backup) { [IO.File]::WriteAllBytes($layout, [byte[]]$backup) }
    else { Remove-Item -LiteralPath $layout -Force -ErrorAction SilentlyContinue }
}
