# dsh-plugin-desktop-control

给 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 装上"眼睛和手"：智能体可以看见 Windows 屏幕、读懂屏幕上的文字，并像人一样点击、输入、切换窗口，完成"打开微信看消息、点链接、答题"这类只有人能做的操作。

- 纯 Windows 自带能力：PowerShell 5.1 + .NET + 系统 OCR，**不需要 Python、不需要编译、不需要下载模型**
- 9 个模型工具，覆盖截图、OCR、鼠标、键盘、窗口、UI Automation、剪贴板、等待
- 坐标统一为物理像素，OCR 框和点击点天然对齐
- 常驻代理进程，单次调用几十毫秒；卡死自动重建

## 快速开始

```bash
# 1. 把本仓库放到任意目录，然后在 DSH 里安装为本地插件
#    插件市场 → 添加插件 → 选择本目录
#    或让智能体执行 plugin_manager install_bundle，目标为本目录绝对路径

# 2. 新开一个会话，让智能体自检
> 用 desktop_status 看一下屏幕情况
```

装好后，智能体会多出这些工具：

| 工具 | 作用 |
| --- | --- |
| `desktop_status` | 代理状态、屏幕物理分辨率、OCR 语言、前台窗口、光标位置 |
| `desktop_screenshot` | 整屏 / 窗口 / 区域截图存 PNG，可同时 OCR |
| `desktop_ocr` | 识别屏幕或 PNG 文字，返回每行位置与中心点 |
| `desktop_mouse` | 移动、单击、双击、右击、拖拽、滚轮 |
| `desktop_keyboard` | 输入任意 Unicode 文本、按单键或组合键 |
| `desktop_window` | 列出 / 查找 / 激活 / 最小化 / 最大化 / 还原 / 关闭 / 移动 / 启动窗口 |
| `desktop_uia` | UI Automation 控件树：读取、查找、触发、赋值 |
| `desktop_clipboard` | 读写剪贴板文本 |
| `desktop_wait` | 等待窗口标题或屏幕文字出现 |

## 典型用法

直接对智能体说人话即可：

> 点开我的微信，看一个叫郭梦龙的给我发的链接，点进去要答题，你帮我答了，保证准确率，操作完告诉我即可，不要给郭梦龙发消息。

智能体自己会：激活微信 → 截图/OCR 找到会话 → 点开链接 → 等浏览器打开 → 逐题读题 → 点选项 → 提交 → 读回得分 → 汇报。完整步骤、提示词模板和排错方法见 **[使用手册](docs/使用手册.md)**。

## 系统要求

| 项 | 要求 |
| --- | --- |
| 操作系统 | Windows 10 / 11（截图、OCR、UI Automation 均为 Windows 专有接口） |
| DSH | `>=0.2.2-rc.5 <0.4.0-0`（`package.json` 的 `engines.dsh`） |
| PowerShell | Windows PowerShell 5.1（系统自带） |
| OCR | 依赖系统 OCR 语言包；中文系统一般同时有 `zh-Hans-CN` 和 `en-US` |

## 目录结构

```
index.js                 Host 插件入口：注册工具、持有代理进程
lib/agent.js             代理进程的生命周期、套接字协议、超时与重建
lib/tools.js             9 个工具的定义与文本渲染
agent/desktop-agent.ps1  常驻代理：TCP 监听、JSON 分发
agent/lib/*.ps1          截图 / OCR / 输入 / 窗口 / UIA / 剪贴板
locale/                  插件列表中的标题与描述（en / zh）
docs/DETAIL*.md          插件详情页文档
docs/使用手册.md          生产使用手册
test/                    自测脚本与答题测试页
```

## 配置

在 `cordis.patch.yml` 的插件行里改：

```yaml
- id: dsh-plugin-desktop-control
  name: 'dsh-plugin-desktop-control'
  config:
    idleMinutes: 120      # 代理空闲退出时间（分钟）
    ocrScale: 2           # OCR 放大倍数
    screenshotDir: ''     # 截图目录，空则用系统临时目录
    requestTimeoutMs: 45000
```

## 安全

这些工具操作的是真实桌面：点击会落在指针所在处，可能触发发送消息、提交表单、删除数据。请明确告诉智能体它能做什么、不能做什么；插件本身不做二次确认。

## 许可

MIT
