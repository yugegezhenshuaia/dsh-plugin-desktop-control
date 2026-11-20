# DeepSeek Harness 桌面操控插件验收报告

## 1. 结论

**通过**（受限项：微信未登录，真实消息流未覆盖）。

一句话总评：9 个 `desktop_*` 工具均可调用，截图、OCR、点击、键盘输入、窗口、剪贴板、等待和 UIA 主路径可用；端到端流程完成了“打开聊天记录 → 点击链接 → 从屏幕读题作答 6 题 → 提交 → 显示 6/6”，只有 1 个低严重度的关闭返回文案问题。

## 2. 环境

| 项目 | 实际值 |
|---|---|
| 测试时间 | 2026-11-20 15:23–15:28（Asia/Shanghai） |
| 操作系统 | Windows 11 |
| 屏幕 | 单显示器，2560×1440 物理像素，原点 0,0；系统缩放 125%（按环境说明） |
| 桌面代理 | Desktop agent 1.0.0（`desktop_status`，pid 14128） |
| 插件 | `dsh-plugin-desktop-control` 1.0.0（`package.json`） |
| OCR | 可用，语言 en-US、zh-Hans-CN |
| UI Automation | 可用 |
| 浏览器 | Microsoft Edge（系统默认浏览器） |

> 说明：下表耗时为按操作时间戳估算的端到端近似值，包含必要的截图与 `read_image` 读图确认，不是插件内部埋点；`desktop_wait` 的毫秒值来自工具自身返回。单次工具 RPC 通常在 1 秒内。

## 3. 逐项结果

### A. 基础能力

| 项目 | 期望 | 实际 | 耗时 | 结论 |
|---|---|---|---|---|
| A1 `desktop_status` | 返回屏幕尺寸、OCR 语言、UIA 可用性 | 2560×1440，原点 0,0；OCR 为 en-US / zh-Hans-CN；UIA available；前台为微信登录窗口 | ≈0.2 s | 通过 |
| A2 `desktop_window list` / `find` / `activate` | 列出窗口，找到已存在窗口并激活 | 启动时 8 个窗口；`find` 标题“设置”返回句柄 1114792，但该句柄为最小化状态、激活未成功；改用同标题句柄 3804148 激活成功 | ≈3 s | 通过（换用可激活句柄） |
| A3 `desktop_screenshot` | full / window / region 三种模式各存一张，画面正确 | full 2560×1440；window 1259×887；region 820×470。三张均用 `read_image` 确认，内容正确、无黑屏/错位： [A3-full.png](acceptance-evidence/A3-full.png)、[A3-window.png](acceptance-evidence/A3-window.png)、[A3-region.png](acceptance-evidence/A3-region.png) | ≈20 s | 通过 |
| A4 `desktop_ocr` | region OCR 正确识别中文；`image:` 可识别已有 PNG | region 返回 7 行，识别出“推荐设置”“最近使用的和常用的设置”“屏幕”“图片”；对 A3-window.png 的 image OCR 返回 33 行，识别出“设置”“主页”“推荐设置”等中文 | ≈4 s | 通过 |
| A5 `desktop_clipboard` | set 中英混排文本，get 与原文一致 | 原文与读回值完全一致，均为 51 字符（见下方对照） | ≈1 s | 通过 |
| A6 `desktop_keyboard` | press 安全键；hotkey `ctrl+a` 在记事本中验证 | `press esc` 返回成功；记事本中 `ctrl+a` 后输入新文本，旧文本被完整覆盖（见 B4） | ≈1 s | 通过 |
| A7 `desktop_wait` | window 等已存在标题应立即匹配；text 等屏幕文字 | `kind:window` 匹配“设置”用时 20 ms；`kind:text` 匹配“推荐设置”用时 82 ms | <0.1 s | 通过 |
| A8 `desktop_uia` | 微信窗口 tree（depth 3）并 find 名称含“微信”的元素 | tree 返回 10 个节点；`find` 返回 4 个匹配，包括窗口“微信”、按钮“进入微信”、文本“进入微信” | ≈1 s | 通过 |
| A9 `desktop_mouse`（补充） | 点击/滚动坐标准确 | 点击链接、6 个单选选项、提交按钮均落在 Edge 网页区域；滚动 3 次后可见第 3–6 题和提交按钮 | ≈15 s | 通过 |

剪贴板原文与读回值：

```text
原文：DSH 桌面操控插件验收 2026 — clipboard test / 中文 English 123
读回：DSH 桌面操控插件验收 2026 — clipboard test / 中文 English 123
```

### B. 输入闭环（记事本）

| 项目 | 期望 | 实际 | 耗时 | 结论 |
|---|---|---|---|---|
| B1 启动记事本并激活 | `launch notepad.exe` 后窗口出现、可激活 | 第一次启动返回“.txt - Notepad”（句柄 4590768），激活后首次点击时窗口已消失；重试 `launch` 返回“记事本 / 无标题”（句柄 4063784，281 ms），激活成功 | ≈2 s | 通过（重试 1 次） |
| B2 点击编辑区并输入 | 输入 `DSH 桌面操控插件验收 2026` | 点击落在 `RichEditD2DPT` 编辑区；`type` 报告 17 个字符，画面显示完整文本 | ≈2 s | 通过 |
| B3 截图确认 | 文字真的进入编辑区 | [B3-notepad-typed.png](acceptance-evidence/B3-notepad-typed.png) 显示完整原文 | ≈7 s | 通过 |
| B4 `ctrl+a` 后覆盖输入 | 旧文本被全部替换 | 全选后输入 `覆盖测试：DSH acceptance OK 2026`，旧文本不再存在，字符数为 27：[B4-notepad-overwrite.png](acceptance-evidence/B4-notepad-overwrite.png) | ≈6 s | 通过 |
| B5 不保存直接关闭 | 窗口消失，如弹保存提示则选“不保存” | 未出现保存提示；`desktop_window close` 返回 `No window.`，随后 `desktop_window list` 为 7 个窗口且记事本已消失 | ≈1 s | 通过（返回文案见问题 1） |

### C. 端到端场景

| 项目 | 期望 | 实际 | 耗时 | 结论 |
|---|---|---|---|---|
| C1 打开 entry.html | 默认浏览器打开聊天记录页 | Edge 窗口标题为“聊天记录 - 郭梦龙的测试 - 个人 - Microsoft Edge”，窗口 2560×1380 | ≈2 s | 通过 |
| C2 点击蓝色链接 | 点击“点击开始答题：2026 年安全知识测验” | OCR 得到链接中心 `c=914,570`，点击后窗口标题变为“2026 年安全知识测验 - 个人 - Microsoft Edge” | ≈3 s | 通过 |
| C3 等待页面跳转 | 标题出现 | `desktop_wait` 23 ms 匹配“2026 年安全知识测验” | <1 s | 通过 |
| C4 逐题作答 | 从屏幕读题，点选 6 题并确认实心圆点 | 6 题均已选中，逐题截图见下表 | ≈70 s | 通过 |
| C5 提交答案 | 页面出现“得分 X/6” | 点击“提交答案”后 URL 变为 `quiz.html#scored`；`desktop_wait` 等“得分 \d+/6”8.3 s 超时，改为截图/OCR 确认 | ≈20 s | 通过（等待正则受 OCR 空格影响） |
| C6 读取结果 | 记录真实得分与每题对错文案 | 屏幕显示“得分 6/6”，6 题均为“正确”（原文见下） | ≈10 s | 通过 |
| C7 关闭浏览器 | 只关闭本次打开的 Edge 窗口 | `desktop_window close` 返回 `No window.`；`desktop_window list` 为 7 个窗口，Edge 已消失 | ≈1 s | 通过 |

#### C4 逐题作答记录（答案来自屏幕，不读页面源码）

| 题号 | 屏幕上读到的题干（摘要） | 选择 | 选择后截图 |
|---|---|---|---|
| 1 | 中华人民共和国的首都是哪座城市？ | B. 北京 | [C4-q1-selected.png](acceptance-evidence/C4-q1-selected.png) |
| 2 | 水的化学式是什么？ | B. H2O | [C4-q2-selected.png](acceptance-evidence/C4-q2-selected.png) |
| 3 | 一年有多少个月？ | C. 12 个月 | [C4-q3-selected.png](acceptance-evidence/C4-q3-selected.png) |
| 4 | 《红楼梦》的作者是谁？ | A. 曹雪芹 | [C4-q4-selected.png](acceptance-evidence/C4-q4-selected.png) |
| 5 | 9 乘以 7 等于多少？ | B. 63 | [C4-q5-selected.png](acceptance-evidence/C4-q5-selected.png) |
| 6 | 太阳从哪个方向升起？ | A. 东 | [C4-q6-selected.png](acceptance-evidence/C4-q6-selected.png) |

#### 屏幕上显示的真实结果

```text
得分 6/6

第 1 题：选择 B 正确
第 2 题：选择 B 正确
第 3 题：选择 C 正确
第 4 题：选择 A 正确
第 5 题：选择 B 正确
第 6 题：选择 A 正确
```

结果截图：[C6-score.png](acceptance-evidence/C6-score.png)；放大细节：[C6-score-detail.png](acceptance-evidence/C6-score-detail.png)。

#### 端到端执行步骤

1. 用 `desktop_window launch` 打开 `test\quiz\entry.html`，确认窗口标题含“聊天记录 - 郭梦龙的测试”。
2. 截图后用 `read_image` 读出页面内容，再用 OCR 定位蓝色链接中心 `(914,570)`，点击。
3. 通过 `desktop_wait` 和窗口标题确认已跳转到“2026 年安全知识测验”。
4. 逐屏滚动，依次阅读并点选第 1–6 题；每题点击后截图确认单选圆点为实心。
5. 滚动到底部点击“提交答案”，页面跳转到 `#scored`，显示“得分 6/6”和 6 条“正确”文案。
6. 用区域截图读取结果并记录，最后关闭本次打开的 Edge 窗口；没有向微信发送任何内容。

### D. 微信只读检查

| 项目 | 期望 | 实际 | 耗时 | 结论 |
|---|---|---|---|---|
| D1 登录状态识别 | 不点击“进入微信”，只记录状态 | 微信窗口 352×476，位于 `(1104,453)`；UIA 暴露“进入微信”按钮，确认处于未登录状态。未点击该按钮，未输入、未打开会话 | ≈0.2 s | 通过（只读） |
| D2 UIA tree | 记录微信窗口暴露的控件 | tree（depth 3）返回 10 个节点：Window“微信”、Pane“MMUIRenderSubWindowHW”、Group、ToolBar、Button“关闭”、Text“微信”、Button“网络代理设置”等 | ≈1 s | 通过 |
| D3 真实消息流 | 如已登录则只读聊天列表，不发送 | 未登录，未覆盖；没有打开任何会话或输入框 | — | 未覆盖 |

## 4. 发现的问题

### 问题 1（低）：`desktop_window close` 成功关闭后返回 `No window.`，成功与失败语义不清

- **现象**：关闭记事本和本次打开的 Edge 窗口后，工具都返回 `No window.`；随后 `desktop_window list` 确认目标窗口已经消失。
- **复现步骤**：
  1. `desktop_window launch` 启动 `notepad.exe`，等待并激活；
  2. 输入任意文本后执行 `desktop_window close`（句柄 4063784）；
  3. 观察到返回 `No window.`；执行 `desktop_window list`，记事本已不在 7 个窗口列表中。
  4. 对 Edge 句柄 2756534 重复 `close`，结果相同，列表确认 Edge 已消失。
- **影响**：调用方可能把成功关闭误判为失败并重复操作；窗口本身确实关闭，未造成数据损坏。建议成功时返回明确的“closed”或同时返回关闭后的窗口状态。
- **证据**：关闭前画面 [B4-notepad-overwrite.png](acceptance-evidence/B4-notepad-overwrite.png)；关闭后以 `desktop_window list` 的 7 窗口结果确认。无窗口画面可截，故未额外截图。

未发现阻断性缺陷；以上为唯一判定为“问题”的项。

### 其他观察（未判定为插件缺陷）

1. **首次启动记事本的窗口消失（1 次，未复现）**：第一次 `launch notepad.exe` 返回“.txt - Notepad”（句柄 4590768），`activate` 后首次点击落到了“设置”窗口，记事本已不在窗口列表；第二次启动正常。可能与系统已有 Notepad 会话/恢复标签有关，未归因于插件。
2. **同名“设置”窗口的句柄差异**：列表中有两个“设置”窗口，句柄 1114792 的 `activate`/`restore` 都返回仍为最小化；改用句柄 3804148 激活成功。A2 因此使用后者完成验证。
3. **等待结果文本时 OCR 空格导致正则不匹配**：屏幕上结果为“得分 6 / 6”，实际 OCR 也在数字与斜杠间输出空格；`desktop_wait` 的 `得分 \d+/6` 因此等待 8.3 s 超时，改用截图/OCR 确认。建议用容忍空白的正则，或等待更宽泛的“得分”。
4. **OCR 对个别文字/图标不完整**：区域 OCR 未单独识别出“声音”，把单选框/图标识别为“0”“囗”等；主要中文标题和题干识别正确，不影响本次点击与答题。

## 5. 未覆盖 / 受阻部分

- **微信真实消息流未覆盖**：微信停留在未登录窗口，UIA 可读，但未点击“进入微信”、未登录、未打开任何会话，也未向“郭梦龙”或任何聊天框输入/发送内容。因此“真实微信消息 → 链接 → 回复得分”的链路只验证了本地网页替身，没有验证真实微信消息流。
- 未额外测试拖拽、右键菜单、双击、多显示器、不同 DPI 缩放，以及登录后微信聊天列表的截图/OCR；这些不在本次任务清单内。
- 记事本关闭时没有出现保存提示，因此“选择不保存”的弹窗分支未被触发；只验证了无提示直接关闭。

## 6. 总结

1. 9 个桌面工具的主路径全部跑通；截图/读图、OCR、点击、键盘输入、窗口管理和 UIA 都能支撑完整操作。
2. 核心端到端验收通过：从本地聊天记录页点击链接，按屏幕读题答完 6 题，提交后真实显示 **6/6**，6 题全部正确。
3. 微信仅完成未登录状态下的只读窗口/UIA 检查；未登录，未发送任何消息，真实微信消息流不在本次已验证范围内。
4. 唯一记录的问题是 `desktop_window close` 成功关闭后返回 `No window.`，属低严重度返回语义问题；未发现阻断性缺陷。

---

## 7. 修复复核（主导会话补充，2026-11-20 15:32–15:34）

验收报告基于安装时的那一版插件。下面两项已由主导会话修复并复核，均在**重新加载插件**（禁用→启用，代理进程随之重建）之后验证。

| 问题 | 修复内容 | 复核方式 | 结果 |
|---|---|---|---|
| 问题 1：`desktop_window close` 成功后返回 `No window.` | `lib/tools.js` 的窗口渲染新增 `closed` 分支，成功时返回 `Closed window handle=<handle>`，未关闭时返回明确的“仍在打开”提示 | 通过插件执行 `desktop_window launch notepad.exe` → `desktop_window close handle=5965780` | 返回 `Closed window handle=5965780`，与 `desktop_window list` 一致 ✔ |
| 观察 3：`desktop_wait kind=text` 对 OCR 空格敏感、不支持正则 | `agent/lib/Windows.ps1` 改为“去空白后的不区分大小写子串匹配 + 正则匹配”双通道，OCR 的 `得分 6 / 6` 与调用方写的 `得分6/6` 都能命中 | 新增 `test/wait-test.ps1`：窗口显示 `得分 0 / 6`，分别用 `得分0/6`、`得分\s*\d+\s*/\s*6` 和一段不存在的文本测试 | 压缩匹配 51 ms 命中、正则 61 ms 命中、不存在文本按 1385 ms 超时返回 false ✔ |

复核同时跑通了回归自测（均在重载后的代码上）：

```text
node test/node-smoke.mjs    -> node smoke ok
test/smoke.ps1              -> 截图 158 ms、全屏 OCR 1023 ms、窗口 31 ms、剪贴板 6 ms
test/input-test.ps1         -> input test passed（含 UIA 类型回退：uia find Submit: 1 matches）
test/wait-test.ps1          -> wait text test passed
```

未修复项：无。报告第 4 节其余“其他观察”均为环境或 OCR 固有行为，不属于插件缺陷。