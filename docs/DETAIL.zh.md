# 桌面操控

给智能体装上"眼睛和手"：它能看到这块 Windows 屏幕上有什么，并像人一样点击、输入、切换窗口。

## 新增的九个工具

| 工具 | 作用 |
| --- | --- |
| `desktop_status` | 代理状态、屏幕物理分辨率、OCR 语言、UI Automation 可用性、前台窗口。 |
| `desktop_screenshot` | 把整屏 / 某个窗口 / 指定区域存成 PNG，可顺带 OCR。 |
| `desktop_ocr` | 识别屏幕或 PNG 里的文字，返回每行的位置和中心点。 |
| `desktop_mouse` | 移动、单击、双击、右击、拖拽、滚轮。 |
| `desktop_keyboard` | 输入任意 Unicode 文本（含中文）、按单键或组合键。 |
| `desktop_window` | 列出、查找、激活、最小化、最大化、还原、关闭、移动、启动窗口。 |
| `desktop_uia` | 读取、查找、触发窗口的 UI Automation 控件树。 |
| `desktop_clipboard` | 读取和写入剪贴板文本。 |
| `desktop_wait` | 等待某个窗口标题或屏幕文字出现。 |

## 工作原理

插件只做两件事：注册工具，并维护一个常驻的 Windows PowerShell 代理进程。代理监听本机随机端口，
在同一个 STA 线程里常驻 OCR 引擎和 UI Automation，逐行收发 JSON。第一次调用工具时才启动，空闲超时
自动退出，请求卡死或进程崩溃后下次调用会自动重建。

不需要 Python、不需要编译原生模块、不需要下载任何东西：代理是 Windows 自带的 PowerShell 5.1
加系统自带的 .NET 类型。

## 系统要求与限制

- Windows 10 / 11。截图、OCR、UI Automation 都是 Windows 专有接口。
- OCR 语言取决于系统语言包。中文系统一般同时有 `zh-Hans-CN` 和 `en-US`，用 `desktop_status` 查看。
- 坐标是**物理像素**。125% 缩放下，屏幕在这些工具眼里就是 2560x1440，所以 OCR 返回的框和点击能对上。
- 模拟输入只送进前台窗口。先激活窗口；桌面锁屏或 UAC 安全桌面弹出时输入会失效。
- UI Automation 只对暴露了无障碍信息的程序有用。自绘界面读不到控件，就退回"截图 + OCR + 点击像素"。

## 配置

在 `cordis.patch.yml` 的插件行里设置：

| 键 | 默认值 | 含义 |
| --- | --- | --- |
| `idleMinutes` | `120` | 代理空闲多少分钟后自动退出。 |
| `ocrScale` | `2` | OCR 前放大倍数，放大有助于识别小字。 |
| `screenshotDir` | 系统临时目录 | 截图保存位置。 |
| `requestTimeoutMs` | `45000` | 单次请求超时；超时后杀掉并重建代理。 |
| `powershell` | 系统 PowerShell 路径 | 指定其它 PowerShell 可执行文件。 |
| `logDir` | 系统临时目录 | 代理日志与就绪文件目录。 |

## 安全提醒

这些工具操作的是真实桌面。点击会落在指针所在处，包括会发送消息、提交表单、删除数据的按钮。
请明确告诉智能体它能做什么；这里没有任何"执行前二次确认"。
