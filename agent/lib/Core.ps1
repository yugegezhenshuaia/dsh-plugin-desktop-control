# Core.ps1 -- native interop, JSON helpers, and shared utilities for the desktop agent.
# ASCII-only source: all user text arrives as UTF-8 JSON over the wire.

$script:AgentVersion = '1.0.0'

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

if (-not ('DWin' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class DWin
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }

    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }

    [StructLayout(LayoutKind.Sequential)]
    public struct HARDWAREINPUT { public uint uMsg; public ushort wParamL; public ushort wParamH; }

    [StructLayout(LayoutKind.Explicit)]
    public struct INPUT
    {
        [FieldOffset(0)] public uint type;
        [FieldOffset(4)] public MOUSEINPUT mi;
        [FieldOffset(4)] public KEYBDINPUT ki;
        [FieldOffset(4)] public HARDWAREINPUT hi;
    }

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern void SwitchToThisWindow(IntPtr hWnd, bool altTab);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr hWnd, StringBuilder text, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr hWnd, StringBuilder text, int max);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr unused);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool attach);
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hWnd, uint flags);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern uint SendInput(uint count, INPUT[] inputs, int size);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, IntPtr extra);
    [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint mapType);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern short VkKeyScanW(char ch);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hWnd, int attribute, out RECT value, int size);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessageW(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool PostMessageW(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool AllowSetForegroundWindow(uint processId);

    public const uint INPUT_MOUSE = 0;
    public const uint INPUT_KEYBOARD = 1;
    public const uint KEYEVENTF_EXTENDEDKEY = 0x0001;
    public const uint KEYEVENTF_KEYUP = 0x0002;
    public const uint KEYEVENTF_UNICODE = 0x0004;
    public const uint KEYEVENTF_SCANCODE = 0x0008;
    public const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    public const uint MOUSEEVENTF_LEFTUP = 0x0004;
    public const uint MOUSEEVENTF_RIGHTDOWN = 0x0008;
    public const uint MOUSEEVENTF_RIGHTUP = 0x0010;
    public const uint MOUSEEVENTF_MIDDLEDOWN = 0x0020;
    public const uint MOUSEEVENTF_MIDDLEUP = 0x0040;
    public const uint MOUSEEVENTF_WHEEL = 0x0800;
    public const uint MOUSEEVENTF_HWHEEL = 0x1000;

    public static void MakeDpiAware()
    {
        try { SetProcessDpiAwarenessContext(new IntPtr(-4)); return; } catch { }
        try { SetProcessDPIAware(); } catch { }
    }

    public static string Title(IntPtr h)
    {
        var sb = new StringBuilder(1024);
        GetWindowTextW(h, sb, sb.Capacity);
        return sb.ToString();
    }

    public static string ClassName(IntPtr h)
    {
        var sb = new StringBuilder(256);
        GetClassNameW(h, sb, sb.Capacity);
        return sb.ToString();
    }

    public static uint Pid(IntPtr h)
    {
        uint pid;
        GetWindowThreadProcessId(h, out pid);
        return pid;
    }

    public static int[] Rect(IntPtr h)
    {
        RECT r = new RECT();
        int hr = DwmGetWindowAttribute(h, 9, out r, Marshal.SizeOf(typeof(RECT)));
        if (hr != 0 || r.Right - r.Left <= 0 || r.Bottom - r.Top <= 0)
        {
            if (!GetWindowRect(h, out r)) return new int[] { 0, 0, 0, 0 };
        }
        return new int[] { r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top };
    }

    public static IntPtr[] TopWindows()
    {
        var list = new List<IntPtr>();
        EnumWindows(delegate (IntPtr h, IntPtr l) { list.Add(h); return true; }, IntPtr.Zero);
        return list.ToArray();
    }

    public static bool IsMinimized(IntPtr h) { return IsIconic(h); }
    public static bool IsMaximized(IntPtr h) { return IsZoomed(h); }
    public static bool IsShown(IntPtr h) { return IsWindowVisible(h); }
    public static bool IsAlive(IntPtr h) { return IsWindow(h); }

    public static bool Activate(IntPtr h)
    {
        if (h == IntPtr.Zero || !IsWindow(h)) return false;
        if (IsIconic(h)) ShowWindow(h, 9); // SW_RESTORE
        if (GetForegroundWindow() == h) { ShowWindow(h, 5); return true; }

        // Escalating, never-blocking activation. AttachThreadInput is deliberately
        // avoided: it deadlocks when the foreground thread is not pumping input.
        SetForegroundWindow(h);
        System.Threading.Thread.Sleep(80);
        if (GetForegroundWindow() == h) return true;

        SwitchToThisWindow(h, true);
        System.Threading.Thread.Sleep(80);
        if (GetForegroundWindow() == h) return true;

        // Minimize/restore hands activation to the window through the shell.
        ShowWindow(h, 6);
        System.Threading.Thread.Sleep(120);
        ShowWindow(h, 9);
        System.Threading.Thread.Sleep(120);
        if (GetForegroundWindow() == h) return true;

        // A synthetic Alt press releases the foreground lock for this process.
        Key(0x12, true);
        Key(0x12, false);
        System.Threading.Thread.Sleep(60);
        SetForegroundWindow(h);
        BringWindowToTop(h);
        System.Threading.Thread.Sleep(80);
        return GetForegroundWindow() == h;
    }

    public static int[] Cursor()
    {
        POINT p;
        GetCursorPos(out p);
        return new int[] { p.X, p.Y };
    }

    public static bool MoveTo(int x, int y) { return SetCursorPos(x, y); }

    public static void Button(bool down, string button)
    {
        uint flag;
        if (button == "right") flag = down ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP;
        else if (button == "middle") flag = down ? MOUSEEVENTF_MIDDLEDOWN : MOUSEEVENTF_MIDDLEUP;
        else flag = down ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP;
        // Legacy mouse_event rather than SendInput: SendInput is silently discarded
        // for processes inside a Windows job object with UI restrictions (the
        // Harness shell sandbox), while this path keeps working.
        mouse_event(flag, 0, 0, 0, IntPtr.Zero);
    }

    public static void Wheel(int delta, bool horizontal)
    {
        uint flag = horizontal ? MOUSEEVENTF_HWHEEL : MOUSEEVENTF_WHEEL;
        mouse_event(flag, 0, 0, (uint)delta, IntPtr.Zero);
    }

    public static uint SendUnicode(string text)
    {
        var inputs = new List<INPUT>();
        foreach (char ch in text)
        {
            INPUT down = new INPUT();
            down.type = INPUT_KEYBOARD;
            down.ki.wScan = (ushort)ch;
            down.ki.dwFlags = KEYEVENTF_UNICODE;
            inputs.Add(down);
            INPUT up = new INPUT();
            up.type = INPUT_KEYBOARD;
            up.ki.wScan = (ushort)ch;
            up.ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
            inputs.Add(up);
        }
        if (inputs.Count == 0) return 0;
        return SendInput((uint)inputs.Count, inputs.ToArray(), Marshal.SizeOf(typeof(INPUT)));
    }

    private static bool IsExtendedKey(ushort vk)
    {
        switch (vk)
        {
            case 0x21: case 0x22: case 0x23: case 0x24: case 0x25: case 0x26: case 0x27: case 0x28:
            case 0x2D: case 0x2E: case 0x90: case 0x2C: case 0x5B: case 0x5C: case 0x5D:
                return true;
            default:
                return false;
        }
    }

    public static void Key(ushort vk, bool down)
    {
        byte scan = (byte)MapVirtualKey(vk, 0);
        uint flags = down ? 0u : KEYEVENTF_KEYUP;
        if (IsExtendedKey(vk)) flags |= KEYEVENTF_EXTENDEDKEY;
        keybd_event((byte)vk, scan, flags, IntPtr.Zero);
    }

    // Type printable ASCII through virtual-key codes; works where SendInput is
    // blocked. Non-ASCII characters cannot be produced this way.
    public static void SendAscii(string text)
    {
        foreach (char c in text)
        {
            short vkScan = VkKeyScanW(c);
            if (vkScan == -1) continue;
            int vk = vkScan & 0xFF;
            int state = (vkScan >> 8) & 0xFF;
            bool shift = (state & 1) != 0, ctrl = (state & 2) != 0, alt = (state & 4) != 0;
            if (shift) Key(0x10, true);
            if (ctrl) Key(0x11, true);
            if (alt) Key(0x12, true);
            Key((ushort)vk, true);
            Key((ushort)vk, false);
            if (alt) Key(0x12, false);
            if (ctrl) Key(0x11, false);
            if (shift) Key(0x10, false);
            System.Threading.Thread.Sleep(4);
        }
    }

    public static IntPtr WindowAt(int x, int y)
    {
        POINT p = new POINT();
        p.X = x; p.Y = y;
        return WindowFromPoint(p);
    }

    public static int[] VirtualScreen()
    {
        int x = GetSystemMetrics(76), y = GetSystemMetrics(77);
        int w = GetSystemMetrics(78), h = GetSystemMetrics(79);
        if (w <= 0 || h <= 0) { w = GetSystemMetrics(0); h = GetSystemMetrics(1); x = 0; y = 0; }
        return new int[] { x, y, w, h };
    }
}
'@
}

# --- JSON helpers -------------------------------------------------------

function ConvertFrom-Utf8Json {
    param([byte[]]$Bytes)
    $text = [System.Text.Encoding]::UTF8.GetString($Bytes)
    return $text | ConvertFrom-Json
}

function ConvertTo-JsonText {
    param($Value, [int]$Depth = 12)
    if ($null -eq $Value) { return 'null' }
    return (ConvertTo-Json -InputObject $Value -Depth $Depth -Compress)
}

# --- process / window utilities ----------------------------------------

function Get-ProcessNameSafe {
    param([uint32]$ProcessId)
    try { return (Get-Process -Id $ProcessId -ErrorAction Stop).ProcessName } catch { return '' }
}

function New-AgentError {
    param([string]$Message, [string]$Code = 'AGENT_ERROR')
    return [pscustomobject]@{ message = $Message; code = $Code }
}

# Load-bearing helper: every action returns a hashtable so the server can
# serialize it as the response body.
function Out-Ok {
    param($Result)
    return @{ ok = $true; result = $Result }
}
