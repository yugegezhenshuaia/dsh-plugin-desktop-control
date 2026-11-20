# Desktop control

Gives the agent eyes and hands on this Windows machine. Nine `desktop_*` tools drive
a long-lived PowerShell agent that captures the screen, reads text with the OCR
engine built into Windows, moves the mouse, types text, manages windows, and reads
UI Automation trees.

## What it adds

| Tool | What it does |
| --- | --- |
| `desktop_status` | Agent state, physical screen size, OCR languages, UI Automation availability, foreground window. |
| `desktop_screenshot` | Save the screen, one window, or a region to PNG, optionally with OCR text in the same call. |
| `desktop_ocr` | Recognize text on screen or in a PNG, with bounding boxes and center points. |
| `desktop_mouse` | Move, click, double-click, right-click, drag, scroll. |
| `desktop_keyboard` | Type Unicode text (Chinese included), press keys and key chords. |
| `desktop_window` | List, find, activate, minimize, maximize, restore, close, move, launch. |
| `desktop_uia` | Dump, find, invoke, and set values in a window's UI Automation tree. |
| `desktop_clipboard` | Read and write text on the clipboard. |
| `desktop_wait` | Wait for a window title or on-screen text to appear. |

## How it works

`index.js` registers the tools and owns one agent process. The agent listens on a
random loopback TCP port, keeps a single STA thread with the OCR engine and UI
Automation assemblies loaded, and answers one JSON request per line. It starts on
the first tool call, exits after an idle timeout, and is replaced automatically if a
request hangs or the process dies.

No Python, no Node native modules, no downloads: the agent is Windows PowerShell 5.1
plus .NET Framework types that ship with Windows.

## Requirements and limits

- Windows 10 or 11. The screen-capture, OCR, and UI Automation APIs are Windows-only.
- Windows PowerShell 5.1 is present on every supported Windows version.
- OCR coverage depends on installed Windows language packs. A Chinese Windows reads
  `zh-Hans-CN` and `en-US`; call `desktop_status` to see what is available.
- Coordinates are physical pixels. On a 125% scaled display the screen really is
  2560x1440 to these tools, which is why OCR boxes line up with clicks.
- Synthetic input goes to the foreground window. Activate a window first, and expect
  input to be ignored while the desktop is locked or a secure prompt is open.
- UI Automation only helps for applications that expose accessibility. For
  custom-drawn applications, read the screen with OCR and click the pixels.

## Configuration

Set on the plugin row in `cordis.patch.yml`:

| Key | Default | Meaning |
| --- | --- | --- |
| `idleMinutes` | `120` | Idle timeout of the agent process. |
| `ocrScale` | `2` | Upscale factor before OCR; larger helps small text. |
| `screenshotDir` | system temp | Where screenshots are written. |
| `requestTimeoutMs` | `45000` | Per-request timeout; a timed-out agent is killed and restarted. |
| `powershell` | Windows PowerShell path | Alternate PowerShell executable. |
| `logDir` | system temp | Agent log and ready-file directory. |

## Safety

The tools act on the real desktop. A click lands wherever the pointer is, including
buttons that send messages, submit forms, or delete data. Tell the agent what it may
do; nothing here asks for confirmation before acting.
