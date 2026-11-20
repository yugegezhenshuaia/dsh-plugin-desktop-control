/**
 * Desktop control - drive Windows applications from the agent.
 *
 * The plugin is a thin Host half: it owns one long-lived PowerShell agent that
 * performs screen capture, OCR, synthetic input, window management, UI Automation
 * and clipboard access, and it exposes that agent as nine model-facing tools.
 *
 * @module dsh-plugin-desktop-control
 */
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { DesktopAgent } from './lib/agent.js'
import { createTools } from './lib/tools.js'

const here = path.dirname(fileURLToPath(import.meta.url))

/** Loader entry name. */
export const name = 'desktop-control'

/** Services this plugin needs before it can register tools. */
export const inject = ['tools']

/** Host-only bundle: no client half, no build step, no runtime dependencies. */
export function apply(ctx, config) {
  const options = config && typeof config === 'object' ? config : {}
  const agent = new DesktopAgent({
    scriptPath: path.join(here, 'agent', 'desktop-agent.ps1'),
    powershell: typeof options.powershell === 'string' && options.powershell ? options.powershell : undefined,
    idleMinutes: Number.isFinite(options.idleMinutes) ? options.idleMinutes : 120,
    requestTimeoutMs: Number.isFinite(options.requestTimeoutMs) ? options.requestTimeoutMs : undefined,
    logDir: typeof options.logDir === 'string' && options.logDir ? options.logDir : undefined,
  })

  ctx.effect(() => () => { agent.dispose() })

  const tools = createTools({
    agent,
    config: {
      screenshotDir: typeof options.screenshotDir === 'string' ? options.screenshotDir : '',
      ocrScale: Number.isFinite(options.ocrScale) ? options.ocrScale : 2,
    },
  })
  for (const tool of tools) ctx.tools.register(tool)
}
