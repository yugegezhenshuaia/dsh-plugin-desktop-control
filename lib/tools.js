/**
 * Model-facing tools for desktop control.
 *
 * Every tool maps onto one command of the PowerShell agent and renders a compact
 * text result. All coordinates are physical screen pixels: the agent is per-monitor
 * DPI aware, so a 125% scaled display really is 2560x1440 to these tools.
 *
 * @module dsh-plugin-desktop-control/tools
 */
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

/** Output schemas are permissive: the agent answers arbitrary JSON objects. */
const OBJECT_OUT = { type: 'object', additionalProperties: true }

const NO_ARGS = { type: 'object', properties: {}, additionalProperties: false }

/** Render one text block. */
function text(value) {
  return [{ type: 'text', text: value }]
}

/** Force a value through JSON so the tool result is lossless and frozen-safe. */
function asJson(value) {
  return JSON.parse(JSON.stringify(value === undefined ? null : value))
}

/** Format a number that may be null/undefined. */
function num(value, fallback = '?') {
  return typeof value === 'number' && Number.isFinite(value) ? String(Math.round(value)) : fallback
}

/** Resolve a window handle from an explicit handle or a title/process selector. */
async function resolveHandle(agent, args) {
  const handle = Number(args.handle)
  if (Number.isFinite(handle) && handle > 0) return handle
  if (args.title || args.process) {
    const found = await agent.request('windows', {
      action: 'find',
      title: args.title,
      process: args.process,
    })
    return found.window.handle
  }
  return 0
}

/** One screenshot file path per call. */
function screenshotPath(dir, requested) {
  if (requested) {
    return path.isAbsolute(requested) ? requested : path.join(dir, requested)
  }
  const now = new Date()
  const pad = (value, width = 2) => String(value).padStart(width, '0')
  const stamp = `${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}-${pad(now.getHours())}${pad(now.getMinutes())}${pad(now.getSeconds())}-${pad(now.getMilliseconds(), 3)}`
  return path.join(dir, `shot-${stamp}-${Math.random().toString(36).slice(2, 6)}.png`)
}

/** Render OCR lines with their clickable geometry. */
function formatOcrLines(result, options = {}) {
  const lines = Array.isArray(result && result.lines) ? result.lines : []
  if (lines.length === 0) return '(no text recognized)'
  const boxes = options.boxes !== false
  const rendered = lines.map((line, index) => {
    if (!boxes) return line.text
    const cx = typeof line.cx === 'number' ? line.cx : (line.x + Math.round(line.width / 2))
    const cy = typeof line.cy === 'number' ? line.cy : (line.y + Math.round(line.height / 2))
    return `L${index + 1} x=${num(line.x)} y=${num(line.y)} w=${num(line.width)} h=${num(line.height)} c=${num(cx)},${num(cy)} | ${line.text}`
  })
  return rendered.join('\n')
}

/** Build the `desktop_status`-like header line shared by several renders. */
function describeScreen(status) {
  const screen = status.screen || {}
  return `screen ${num(screen.width)}x${num(screen.height)} at origin ${num(screen.x, '0')},${num(screen.y, '0')}`
}

/**
 * Create every desktop tool bound to one agent.
 * @param context - plugin context with the agent, resolved config, and log helpers.
 * @returns tool definitions ready for `ctx.tools.register`.
 */
export function createTools(context) {
  const { agent, config } = context
  const shotDir = config.screenshotDir
    ? path.resolve(config.screenshotDir)
    : path.join(os.tmpdir(), 'dsh-desktop-control', 'shots')
  const defaultOcrScale = Number.isFinite(config.ocrScale) ? config.ocrScale : 2

  return [
    {
      name: 'desktop_status',
      description:
        'Report the desktop-control agent state and screen geometry: physical pixel size, OCR languages, '
        + 'UI Automation availability, and the foreground window. Call it first when you are unsure whether '
        + 'the agent runs or how large the screen really is.',
      parameters: NO_ARGS,
      output: { schema: OBJECT_OUT, render: (_args, value) => text(renderStatus(value)) },
      async execute() {
        const status = await agent.request('status', {})
        return asJson({ ...status, client: agent.describe() })
      },
    },

    {
      name: 'desktop_screenshot',
      description:
        'Capture the screen, one window, or a region to a PNG file and optionally OCR it in the same call. '
        + 'Returns the saved path and the captured rectangle in physical screen pixels; OCR line coordinates '
        + 'can be passed straight to desktop_mouse. Coordinates are physical pixels, so a scaled display is '
        + 'larger than the logical resolution. Activate the window first when it may be covered.',
      parameters: {
        type: 'object',
        additionalProperties: false,
        properties: {
          mode: {
            type: 'string',
            enum: ['full', 'window', 'region'],
            description: 'What to capture. Default full: the whole virtual desktop.',
          },
          handle: { type: 'integer', description: 'Window handle for mode window; omit to use the foreground window.' },
          title: { type: 'string', description: 'Window title (or unique fragment) used instead of handle.' },
          region: {
            type: 'object',
            additionalProperties: false,
            properties: {
              x: { type: 'integer' },
              y: { type: 'integer' },
              width: { type: 'integer' },
              height: { type: 'integer' },
            },
            description: 'Capture rectangle in physical pixels, used by mode region.',
          },
          scale: { type: 'number', description: 'Upscale factor for the saved image; 2 enlarges small text. Default 1.' },
          ocr: { type: 'boolean', description: 'Run OCR on the capture and include the recognized lines.' },
          path: { type: 'string', description: 'Output PNG path; relative paths resolve under the screenshot directory.' },
        },
      },
      output: { schema: OBJECT_OUT, render: (_args, value) => text(renderScreenshot(value)) },
      async execute(args) {
        const mode = args.mode || 'full'
        let handle = 0
        if (mode === 'window') handle = await resolveHandle(agent, args)
        const file = screenshotPath(shotDir, args.path)
        const shot = await agent.request('screenshot', {
          mode,
          handle,
          region: args.region,
          scale: args.scale === undefined ? 1 : args.scale,
          path: file,
        })
        let ocr = null
        if (args.ocr === true) {
          // Recognize a fresh capture of the same area rather than the PNG: the file
          // may be downscaled or contain window chrome the caller did not ask for.
          ocr = await agent.request('ocr', {
            mode,
            handle,
            region: args.region,
            scale: defaultOcrScale,
          }, { timeoutMs: 120000 })
        }
        return asJson({ ...shot, ocr })
      },
    },

    {
      name: 'desktop_ocr',
      description:
        'Recognize on-screen text with the built-in Windows OCR engine and return lines with bounding boxes '
        + 'and center points in physical screen pixels. Use it to read what an application shows before '
        + 'clicking, to verify a result, or to poll for text. Prefer a window or region capture over the full '
        + 'screen for speed and accuracy.',
      parameters: {
        type: 'object',
        additionalProperties: false,
        properties: {
          image: { type: 'string', description: 'Existing PNG to recognize instead of capturing the screen.' },
          mode: {
            type: 'string',
            enum: ['full', 'window', 'region'],
            description: 'Live capture target when no image is given. Default full.',
          },
          handle: { type: 'integer', description: 'Window handle for mode window.' },
          title: { type: 'string', description: 'Window title (or unique fragment) used instead of handle.' },
          region: {
            type: 'object',
            additionalProperties: false,
            properties: {
              x: { type: 'integer' },
              y: { type: 'integer' },
              width: { type: 'integer' },
              height: { type: 'integer' },
            },
            description: 'Capture rectangle in physical pixels for mode region.',
          },
          scale: { type: 'number', description: 'Upscale factor before recognition; larger helps small text. Default 2.' },
          lang: { type: 'string', description: 'OCR language tag such as zh-Hans-CN or en-US; default follows Windows.' },
          words: { type: 'boolean', description: 'Include per-word boxes for finer clicking.' },
          boxes: { type: 'boolean', description: 'Render coordinates with each line. Default true; false returns plain text.' },
        },
      },
      output: { schema: OBJECT_OUT, render: (_args, value) => text(renderOcr(value)) },
      async execute(args) {
        if (args.image) {
          const image = path.isAbsolute(args.image) ? args.image : path.resolve(shotDir, args.image)
          const result = await agent.request('ocr', {
            path: image,
            scale: args.scale === undefined ? defaultOcrScale : args.scale,
            lang: args.lang,
            words: args.words === true,
          }, { timeoutMs: 120000 })
          return asJson({ ...result, source: image })
        }
        const mode = args.mode || 'full'
        let handle = 0
        if (mode === 'window') handle = await resolveHandle(agent, args)
        const result = await agent.request('ocr', {
          mode,
          handle,
          region: args.region,
          scale: args.scale === undefined ? defaultOcrScale : args.scale,
          lang: args.lang,
          words: args.words === true,
        }, { timeoutMs: 120000 })
        return asJson(result)
      },
    },

    {
      name: 'desktop_mouse',
      description:
        'Move, click, double-click, right-click, drag, or scroll at physical screen pixel coordinates. '
        + 'A click lands on whatever window is on top at that point, so activate the target window first. '
        + 'The result names the window under the point, which tells you whether the click went where you meant.',
      parameters: {
        type: 'object',
        additionalProperties: false,
        properties: {
          action: {
            type: 'string',
            enum: ['click', 'double_click', 'right_click', 'middle_click', 'move', 'scroll', 'drag', 'down', 'up'],
            description: 'Mouse action. Default click.',
          },
          x: { type: 'integer', description: 'Target X in physical pixels.' },
          y: { type: 'integer', description: 'Target Y in physical pixels.' },
          toX: { type: 'integer', description: 'Drag end X in physical pixels.' },
          toY: { type: 'integer', description: 'Drag end Y in physical pixels.' },
          amount: {
            type: 'integer',
            description: 'Scroll wheel clicks, positive scrolls up; negative scrolls down. Default 3.',
          },
          horizontal: { type: 'boolean', description: 'Scroll horizontally instead of vertically.' },
        },
        required: ['x', 'y'],
      },
      output: { schema: OBJECT_OUT, render: (_args, value) => text(renderMouse(value)) },
      async execute(args) {
        const result = await agent.request('mouse', {
          action: args.action || 'click',
          x: args.x,
          y: args.y,
          toX: args.toX,
          toY: args.toY,
          amount: args.amount,
          horizontal: args.horizontal === true,
        })
        return asJson(result)
      },
    },

    {
      name: 'desktop_keyboard',
      description:
        'Type text or press keys into the foreground window. `type` accepts any Unicode text, including '
        + 'Chinese: by default it pastes through the clipboard, which is the only reliable path while a '
        + 'Chinese input method is active, and restores the previous clipboard afterwards. `press` and '
        + '`hotkey` send chords such as enter, tab, esc, ctrl+a, ctrl+c, alt+F4, or win.',
      parameters: {
        type: 'object',
        additionalProperties: false,
        properties: {
          action: {
            type: 'string',
            enum: ['type', 'press', 'hotkey'],
            description: 'Type text, or press a key or key chord. `press` and `hotkey` are equivalent.',
          },
          text: { type: 'string', description: 'Text to type for action type.' },
          keys: { type: 'string', description: 'Key chord for press/hotkey, for example "enter" or "ctrl+s".' },
          method: {
            type: 'string',
            enum: ['auto', 'keys', 'paste', 'unicode'],
            description:
              'How to type. auto (default) pastes through the clipboard, which works for every script and '
              + 'survives an active IME. keys types printable ASCII through virtual-key codes and leaves the '
              + 'clipboard alone. paste forces the clipboard path. unicode uses SendInput, which some sandboxed '
              + 'environments drop.',
          },
          holdMs: { type: 'integer', description: 'How long to hold the key chord; default 40 ms.' },
        },
      },
      output: { schema: OBJECT_OUT, render: (_args, value) => text(renderKeyboard(value)) },
      async execute(args) {
        const result = await agent.request('keyboard', {
          action: args.action || 'type',
          text: args.text,
          keys: args.keys,
          method: args.method || 'auto',
          holdMs: args.holdMs,
        })
        return asJson(result)
      },
    },

    {
      name: 'desktop_window',
      description:
        'List, find, activate, minimize, maximize, restore, close, move, or launch windows. Window titles are '
        + 'matched exactly first, then as a case-insensitive fragment, then as a regular expression. Activate '
        + 'a window before clicking or typing into it when it may be behind another window.',
      parameters: {
        type: 'object',
        additionalProperties: false,
        properties: {
          action: {
            type: 'string',
            enum: ['list', 'find', 'activate', 'minimize', 'maximize', 'restore', 'close', 'move', 'launch'],
            description: 'Window action. Default list.',
          },
          handle: { type: 'integer', description: 'Window handle from desktop_window or desktop_status.' },
          title: { type: 'string', description: 'Window title, unique fragment, or regular expression.' },
          process: { type: 'string', description: 'Process name filter, for example Weixin or chrome.' },
          includeEmpty: { type: 'boolean', description: 'Also list windows without a title.' },
          command: {
            type: 'string',
            description: 'Executable, document path, or URI to start for action launch, for example a https:// link.',
          },
          args: {
            type: 'array',
            items: { type: 'string' },
            description: 'Command line arguments for action launch.',
          },
          cwd: { type: 'string', description: 'Working directory for action launch.' },
          x: { type: 'integer', description: 'New X for action move.' },
          y: { type: 'integer', description: 'New Y for action move.' },
          width: { type: 'integer', description: 'New width for action move.' },
          height: { type: 'integer', description: 'New height for action move.' },
          timeoutMs: { type: 'integer', description: 'How long to wait for a launched window; default 8000 ms.' },
        },
      },
      output: { schema: OBJECT_OUT, render: (_args, value) => text(renderWindow(value)) },
      async execute(args) {
        const action = args.action || 'list'
        if (action === 'launch') {
          const result = await agent.request('windows', {
            action: 'launch',
            command: args.command,
            args: args.args,
            cwd: args.cwd,
            timeoutMs: args.timeoutMs,
          }, { timeoutMs: (args.timeoutMs || 8000) + 20000 })
          return asJson(result)
        }
        const result = await agent.request('windows', {
          action,
          handle: args.handle,
          title: args.title,
          process: args.process,
          includeEmpty: args.includeEmpty === true,
          x: args.x,
          y: args.y,
          width: args.width,
          height: args.height,
        })
        return asJson(result)
      },
    },

    {
      name: 'desktop_uia',
      description:
        'Inspect and drive the UI Automation tree of a window: dump the tree, find elements by name, invoke '
        + 'an element, set a value, focus it, or read its text. Only applications that expose accessibility '
        + 'answer here; many custom-drawn applications expose little, so fall back to screenshot plus OCR.',
      parameters: {
        type: 'object',
        additionalProperties: false,
        properties: {
          action: {
            type: 'string',
            enum: ['tree', 'find', 'invoke', 'set_value', 'focus', 'text'],
            description: 'UIA action. Default tree.',
          },
          handle: { type: 'integer', description: 'Window handle; omit to use the foreground window.' },
          title: { type: 'string', description: 'Window title used instead of handle.' },
          depth: { type: 'integer', description: 'Tree depth for action tree; default 6.' },
          maxNodes: { type: 'integer', description: 'Node budget for tree or find; default 400 for tree.' },
          name: { type: 'string', description: 'Element name (substring, case-insensitive) for action find.' },
          controlType: { type: 'string', description: 'Element type for action find, for example Button or Edit.' },
          exact: { type: 'boolean', description: 'Require an exact name match for action find.' },
          path: { type: 'string', description: 'Element path from a previous tree or find, for example 1/0/3.' },
          value: { type: 'string', description: 'Value for action set_value.' },
        },
      },
      output: { schema: OBJECT_OUT, render: (_args, value) => text(renderUia(value)) },
      async execute(args) {
        const result = await agent.request('uia', {
          action: args.action || 'tree',
          handle: args.handle,
          title: args.title,
          depth: args.depth,
          maxNodes: args.maxNodes,
          name: args.name,
          controlType: args.controlType,
          exact: args.exact === true,
          path: args.path,
          value: args.value,
        })
        return asJson(result)
      },
    },

    {
      name: 'desktop_clipboard',
      description:
        'Read or write the text clipboard. Reading is the cheapest way to get text out of an application that '
        + 'supports copy, and writing lets you paste long text with a single Ctrl+V.',
      parameters: {
        type: 'object',
        additionalProperties: false,
        properties: {
          action: { type: 'string', enum: ['get', 'set'], description: 'Clipboard action. Default get.' },
          text: { type: 'string', description: 'Text to place on the clipboard for action set.' },
        },
      },
      output: { schema: OBJECT_OUT, render: (_args, value) => text(renderClipboard(value)) },
      async execute(args) {
        const action = args.action || 'get'
        const result = await agent.request('clipboard', { action, text: args.text })
        return asJson({ ...result, action })
      },
    },

    {
      name: 'desktop_wait',
      description:
        'Wait until a window title or on-screen text appears, or the timeout expires. Use it after opening a '
        + 'link, switching chats, or submitting a form instead of guessing with fixed delays. Window polling is '
        + 'cheap; text polling re-runs OCR on each interval.',
      parameters: {
        type: 'object',
        additionalProperties: false,
        properties: {
          kind: { type: 'string', enum: ['window', 'text'], description: 'What to wait for. Default window.' },
          pattern: { type: 'string', description: 'Substring or regular expression the title or OCR text must contain.' },
          handle: { type: 'integer', description: 'Limit text polling to this window.' },
          title: { type: 'string', description: 'Window title for text polling, used instead of handle.' },
          region: {
            type: 'object',
            additionalProperties: false,
            properties: {
              x: { type: 'integer' },
              y: { type: 'integer' },
              width: { type: 'integer' },
              height: { type: 'integer' },
            },
            description: 'Limit text polling to this screen rectangle.',
          },
          timeoutMs: { type: 'integer', description: 'Maximum wait; default 10000 ms.' },
          intervalMs: { type: 'integer', description: 'Poll interval; default 400 ms, minimum 150 ms.' },
        },
        required: ['pattern'],
      },
      output: { schema: OBJECT_OUT, render: (_args, value) => text(renderWait(value)) },
      async execute(args) {
        const timeoutMs = Number.isFinite(args.timeoutMs) ? args.timeoutMs : 10000
        const request = {
          kind: args.kind || 'window',
          pattern: args.pattern,
          region: args.region,
          timeoutMs,
          intervalMs: args.intervalMs,
        }
        if (args.handle || args.title) request.handle = await resolveHandle(agent, args)
        const result = await agent.request('wait', request, { timeoutMs: timeoutMs + 20000 })
        return asJson(result)
      },
    },
  ]
}

// --- renderers ----------------------------------------------------------

function renderStatus(status) {
  const lines = []
  const screen = status.screen || {}
  const ocr = status.ocr || {}
  const uia = status.uia || {}
  lines.push(`Desktop agent ${status.version || '?'} ${status.agent ? `(pid ${status.agent.pid})` : ''}`)
  lines.push(`Screen: ${describeScreen(status)} physical pixels`)
  lines.push(`OCR: ${ocr.available ? 'available' : 'unavailable'}${Array.isArray(ocr.languages) && ocr.languages.length ? ' [' + ocr.languages.join(', ') + ']' : ''}`)
  lines.push(`UI Automation: ${uia.available ? 'available' : 'unavailable'}`)
  const fg = status.foreground
  if (fg) {
    lines.push(`Foreground: "${fg.title}" [${fg.process}] handle=${fg.handle} ${fg.rect ? `${fg.rect.width}x${fg.rect.height} at ${fg.rect.x},${fg.rect.y}` : ''}`)
  }
  if (status.cursor) lines.push(`Cursor: ${num(status.cursor.x)},${num(status.cursor.y)}`)
  if (status.client) {
    lines.push(`Agent process: ${status.client.running ? 'running' : 'stopped'}, idle timeout ${num(status.client.idleMinutes)} min`)
    if (status.client.lastError) lines.push(`Last agent error: ${status.client.lastError}`)
  }
  return lines.join('\n')
}

function renderScreenshot(value) {
  const lines = []
  lines.push(`Screenshot: ${value.path}`)
  lines.push(`Captured ${num(value.width)}x${num(value.height)} from ${num(value.origin && value.origin.x, '0')},${num(value.origin && value.origin.y, '0')} (${value.bytes} bytes)`)
  if (value.ocr) {
    lines.push(`OCR ${value.ocr.language || ''} ${num(value.ocr.count)} lines:`)
    lines.push(formatOcrLines(value.ocr))
  }
  return lines.join('\n')
}

function renderOcr(value) {
  const head = `OCR ${value.language || ''}: ${num(value.count)} lines`
  const origin = value.origin ? ` from ${num(value.origin.x, '0')},${num(value.origin.y, '0')}` : ''
  return `${head}${origin}\n${formatOcrLines(value)}`
}

function renderMouse(value) {
  const target = value.target
  const where = target ? ` over "${target.title || target.className}" [${target.process}]` : ''
  const cursor = value.cursor ? ` cursor=${num(value.cursor.x)},${num(value.cursor.y)}` : ''
  if (value.action === 'drag') {
    return `Dragged ${num(value.x)},${num(value.y)} -> ${num(value.dragX)},${num(value.dragY)}${cursor}`
  }
  if (value.action === 'scroll') {
    return `Scrolled at ${num(value.x)},${num(value.y)}${where}${cursor}`
  }
  return `${value.action} at ${num(value.x)},${num(value.y)}${where}${cursor}`
}

function renderKeyboard(value) {
  if (value.action === 'type') {
    return `Typed ${num(value.characters)} characters via ${value.method}${value.asciiOnly === false ? ' (non-ASCII text)' : ''}`
  }
  return `Pressed ${value.keys} (${num(value.count)} keys)`
}

function renderWindow(value) {
  if (Array.isArray(value.windows)) {
    const lines = [`${num(value.count)} windows:`]
    for (const win of value.windows) {
      const rect = win.rect || {}
      const marks = []
      if (win.foreground) marks.push('foreground')
      if (win.minimized) marks.push('minimized')
      if (win.maximized) marks.push('maximized')
      lines.push(
        `handle=${win.handle} "${win.title || ''}" [${win.process || win.className}] `
        + `${num(rect.width)}x${num(rect.height)} at ${num(rect.x)},${num(rect.y)}`
        + (marks.length ? ` ${marks.join(' ')}` : ''),
      )
    }
    return lines.join('\n')
  }
  if (value.windows === undefined && value.pid !== undefined && value.process !== undefined) {
    const win = value.window
    return `Launched ${value.process} (pid ${value.pid})`
      + (win ? `, window "${win.title}" handle=${win.handle}` : ', no window appeared yet')
      + ` in ${num(value.waitedMs)} ms`
  }
  if (value.closed !== undefined) {
    return value.closed
      ? `Closed window handle=${num(value.handle)}`
      : `Window handle=${num(value.handle)} is still open; it may be waiting for confirmation`
  }
  const win = value.window
  if (!win) return 'No window.'
  const rect = win.rect || {}
  const action = value.action ? `${value.action}: ` : ''
  const flags = []
  if (value.activated !== undefined) flags.push(value.activated ? 'activated' : 'not activated')
  if (win.foreground) flags.push('foreground')
  if (win.minimized) flags.push('minimized')
  return `${action}"${win.title || ''}" handle=${win.handle} [${win.process}] ${num(rect.width)}x${num(rect.height)} at ${num(rect.x)},${num(rect.y)}`
    + (flags.length ? ` (${flags.join(', ')})` : '')
}

function renderUia(value) {
  if (Array.isArray(value.nodes)) {
    const lines = [`UIA tree: ${num(value.count)} nodes${value.truncated ? ' (truncated)' : ''}`]
    for (const node of value.nodes) {
      const indent = '  '.repeat(node.depth || 0)
      const rect = node.rect || {}
      const valueText = node.value ? ` value="${node.value}"` : ''
      lines.push(`${indent}${node.type} "${node.name}" path=${node.path} ${num(rect.width)}x${num(rect.height)} at ${num(rect.x)},${num(rect.y)}${valueText}`)
    }
    return lines.join('\n')
  }
  if (Array.isArray(value.matches)) {
    if (value.matches.length === 0) return `No element matched (visited ${num(value.visited)} nodes).`
    const lines = [`${num(value.count)} matches (visited ${num(value.visited)} nodes):`]
    if (value.typeFilterIgnored) lines.push('(no element had that control type; the type filter was ignored)')
    for (const item of value.matches) {
      const rect = item.rect || {}
      lines.push(`${item.type} "${item.name}" path=${item.path} center=${num(item.cx)},${num(item.cy)} ${num(rect.width)}x${num(rect.height)}`)
    }
    return lines.join('\n')
  }
  if (value.invoked) {
    const el = value.element || {}
    return `Invoked ${el.type || 'element'} "${el.name || ''}" via ${value.invoked}`
  }
  if (value.set !== undefined) {
    return `Set value on "${(value.element || {}).name || ''}"`
  }
  if (value.focused !== undefined) {
    return `Focused "${(value.element || {}).name || ''}"`
  }
  if (value.text !== undefined) {
    return `Element text (${num(value.length)} chars):\n${value.text}`
  }
  return JSON.stringify(value)
}

function renderClipboard(value) {
  if (value.action === 'set') {
    return value.set ? `Clipboard set (${num(value.length)} chars)` : `Clipboard write could not be verified (${num(value.length)} chars requested)`
  }
  const clipboard = typeof value.text === 'string' ? value.text : ''
  if (!clipboard) return 'Clipboard is empty or holds no text.'
  return `Clipboard text (${clipboard.length} chars):\n${clipboard}`
}

function renderWait(value) {
  const elapsed = num(value.elapsedMs)
  if (value.matched) {
    if (value.kind === 'window') {
      const win = value.window || {}
      return `Matched window "${win.title}" handle=${win.handle} after ${elapsed} ms`
    }
    return `Matched text after ${elapsed} ms: ${(value.line || {}).text || ''}`
  }
  return `Timed out after ${elapsed} ms waiting for ${value.kind}.`
}
