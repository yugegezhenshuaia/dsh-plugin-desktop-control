/**
 * Client for the long-lived PowerShell desktop agent.
 *
 * One agent process serves the whole session: it owns the UI thread (STA), keeps
 * the OCR engine and UI Automation assemblies loaded, and answers JSON lines over
 * a loopback TCP socket. A crashed or unresponsive agent is killed and replaced on
 * the next call.
 *
 * @module dsh-plugin-desktop-control/agent
 */
import { spawn } from 'node:child_process'
import { randomBytes } from 'node:crypto'
import fs from 'node:fs'
import net from 'node:net'
import os from 'node:os'
import path from 'node:path'

const START_TIMEOUT_MS = 20000
const DEFAULT_REQUEST_TIMEOUT_MS = 45000

/** Absolute path of the Windows PowerShell host used to run the agent. */
export function defaultPowerShellPath() {
  if (process.env.DSH_DESKTOP_CONTROL_POWERSHELL) return process.env.DSH_DESKTOP_CONTROL_POWERSHELL
  const root = process.env.SystemRoot || process.env.windir || 'C:\\Windows'
  return path.join(root, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
}

function tailFile(file, bytes = 4000) {
  try {
    const stat = fs.statSync(file)
    const start = Math.max(0, stat.size - bytes)
    const fd = fs.openSync(file, 'r')
    try {
      const buffer = Buffer.alloc(stat.size - start)
      fs.readSync(fd, buffer, 0, buffer.length, start)
      return buffer.toString('utf8').trim()
    } finally {
      fs.closeSync(fd)
    }
  } catch {
    return ''
  }
}

/** Sleep helper. */
function delay(ms) {
  return new Promise(resolve => setTimeout(resolve, ms))
}

/**
 * Owns the agent child process, its socket, and request serialization.
 */
export class DesktopAgent {
  /**
   * @param options - plugin configuration plus the agent script path.
   * @param options.scriptPath - absolute path of `agent/desktop-agent.ps1`.
   * @param [options.powershell] - PowerShell executable override.
   * @param [options.idleMinutes] - how long the agent may idle before exiting.
   * @param [options.requestTimeoutMs] - default per-request timeout.
   * @param [options.logDir] - directory for agent logs.
   */
  constructor(options) {
    this.scriptPath = options.scriptPath
    this.powershell = options.powershell || defaultPowerShellPath()
    this.idleMinutes = Number.isFinite(options.idleMinutes) ? options.idleMinutes : 120
    this.requestTimeoutMs = Number.isFinite(options.requestTimeoutMs) ? options.requestTimeoutMs : DEFAULT_REQUEST_TIMEOUT_MS
    this.logDir = options.logDir || path.join(os.tmpdir(), 'dsh-desktop-control')
    this.proc = null
    this.socket = null
    this.buffer = ''
    this.pending = new Map()
    this.counter = 0
    this.starting = null
    this.queue = Promise.resolve()
    this.token = ''
    this.port = 0
    this.startedAt = 0
    this.lastError = ''
    this.readyFile = ''
    this.logFile = ''
    this.disposed = false
  }

  /** Whether an agent process is currently serving. */
  get running() {
    return this.socket !== null && this.proc !== null && this.proc.exitCode === null
  }

  /** Diagnostics for `desktop_status`. */
  describe() {
    return {
      running: this.running,
      pid: this.proc ? this.proc.pid : null,
      port: this.port,
      uptimeMs: this.startedAt ? Date.now() - this.startedAt : 0,
      idleMinutes: this.idleMinutes,
      logFile: this.logFile || null,
      lastError: this.lastError || null,
      powershell: this.powershell,
    }
  }

  /** Read the tail of the agent log (used for error reporting). */
  logTail(bytes = 4000) {
    return this.logFile ? tailFile(this.logFile, bytes) : ''
  }

  /** Start the agent if it is not running. Concurrent callers share one start. */
  async ensure() {
    if (this.disposed) throw new Error('the desktop agent has been disposed')
    if (this.running) return
    if (this.starting) return this.starting
    this.starting = this.start().finally(() => { this.starting = null })
    return this.starting
  }

  /** Spawn the agent, wait for its ready file, and connect the socket. */
  async start() {
    if (process.platform !== 'win32') {
      throw new Error('desktop control requires Windows; the current platform is ' + process.platform)
    }
    if (!fs.existsSync(this.scriptPath)) {
      throw new Error('desktop agent script not found: ' + this.scriptPath)
    }
    if (!fs.existsSync(this.powershell)) {
      throw new Error('Windows PowerShell not found at ' + this.powershell)
    }
    await fs.promises.mkdir(this.logDir, { recursive: true })

    this.token = randomBytes(16).toString('hex')
    const stamp = `${process.pid}-${Date.now()}-${randomBytes(3).toString('hex')}`
    this.readyFile = path.join(this.logDir, `agent-${stamp}.ready.json`)
    this.logFile = path.join(this.logDir, 'agent.log')

    const args = [
      '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-STA',
      '-File', this.scriptPath,
      '-Port', '0',
      '-Token', this.token,
      '-ReadyFile', this.readyFile,
      '-IdleMinutes', String(this.idleMinutes),
      '-LogFile', this.logFile,
    ]

    const child = spawn(this.powershell, args, {
      windowsHide: true,
      stdio: 'ignore',
      detached: false,
    })
    this.proc = child
    child.on('exit', () => {
      if (this.proc === child) {
        this.proc = null
        this.startedAt = 0
        this.rejectAll(new Error('the desktop agent process exited'))
      }
    })
    child.on('error', error => {
      this.lastError = String(error && error.message ? error.message : error)
      this.rejectAll(new Error('cannot start the desktop agent: ' + this.lastError))
    })

    const deadline = Date.now() + START_TIMEOUT_MS
    let info = null
    while (Date.now() < deadline) {
      if (child.exitCode !== null) break
      try {
        const raw = await fs.promises.readFile(this.readyFile, 'utf8')
        const parsed = JSON.parse(raw)
        if (parsed && parsed.port) { info = parsed; break }
      } catch {
        // The file may not exist yet, or be partially written.
      }
      await delay(60)
    }
    if (!info) {
      this.lastError = 'the desktop agent did not report a port in time'
      const detail = this.logTail(1500)
      this.kill()
      throw new Error(this.lastError + (detail ? '\n' + detail : ''))
    }
    this.port = info.port
    try { await fs.promises.rm(this.readyFile, { force: true }) } catch { }
    await this.connect()
    this.startedAt = Date.now()
    this.lastError = ''
  }

  /** Open the request socket and wire the line protocol. */
  connect() {
    return new Promise((resolve, reject) => {
      const socket = net.createConnection({ host: '127.0.0.1', port: this.port })
      socket.setNoDelay(true)
      socket.setEncoding('utf8')
      const timer = setTimeout(() => {
        socket.destroy()
        reject(new Error('cannot connect to the desktop agent socket'))
      }, 5000)
      const onError = (error) => {
        clearTimeout(timer)
        socket.destroy()
        reject(new Error('desktop agent socket error: ' + (error && error.message ? error.message : error)))
      }
      socket.once('error', onError)
      socket.once('connect', () => {
        clearTimeout(timer)
        socket.removeListener('error', onError)
        this.socket = socket
        socket.on('data', chunk => this.onData(chunk))
        socket.on('error', error => {
          this.lastError = String(error && error.message ? error.message : error)
          this.rejectAll(new Error('desktop agent connection failed: ' + this.lastError))
        })
        socket.on('close', () => {
          if (this.socket === socket) this.socket = null
          this.rejectAll(new Error('the desktop agent connection closed'))
        })
        resolve()
      })
    })
  }

  /** Accumulate line-delimited JSON responses. */
  onData(chunk) {
    this.buffer += chunk
    let index
    while ((index = this.buffer.indexOf('\n')) >= 0) {
      const line = this.buffer.slice(0, index).trim()
      this.buffer = this.buffer.slice(index + 1)
      if (!line) continue
      let message
      try { message = JSON.parse(line) } catch { continue }
      const entry = message && message.id ? this.pending.get(message.id) : undefined
      if (!entry) continue
      this.pending.delete(message.id)
      clearTimeout(entry.timer)
      if (message.ok) entry.resolve(message.result)
      else {
        const err = message.error || {}
        const error = new Error(err.message || 'the desktop agent reported an unknown error')
        error.code = err.type || 'AGENT_ERROR'
        error.detail = err.detail
        entry.reject(error)
      }
    }
  }

  /** Reject every in-flight request (connection loss or shutdown). */
  rejectAll(error) {
    for (const [id, entry] of this.pending) {
      clearTimeout(entry.timer)
      entry.reject(error)
      this.pending.delete(id)
    }
  }

  /**
   * Send one request and await its result.
   * @param cmd - agent command name.
   * @param args - command arguments (plain JSON).
   * @param [options] - `timeoutMs` overrides the default budget.
   * @returns the agent's result object.
   */
  async request(cmd, args = {}, options = {}) {
    const run = async () => {
      await this.ensure()
      const socket = this.socket
      if (!socket) throw new Error('the desktop agent is not connected')
      const id = String(++this.counter)
      const timeoutMs = Number.isFinite(options.timeoutMs) ? options.timeoutMs : this.requestTimeoutMs
      const payload = JSON.stringify({ id, token: this.token, cmd, req: args }) + '\n'
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          this.pending.delete(id)
          reject(new Error(`the desktop agent did not answer "${cmd}" within ${timeoutMs} ms`))
          // A stuck request usually means the UI thread is blocked; drop the agent
          // so the next call starts a clean one.
          this.kill()
        }, timeoutMs)
        this.pending.set(id, { resolve, reject, timer })
        socket.write(payload, error => {
          if (!error) return
          clearTimeout(timer)
          this.pending.delete(id)
          reject(new Error('cannot write to the desktop agent: ' + error.message))
        })
      })
    }
    const result = this.queue.then(run, run)
    this.queue = result.then(() => undefined, () => undefined)
    return result
  }

  /** Kill the agent process and clear socket state. */
  kill() {
    if (this.socket) {
      try { this.socket.destroy() } catch { }
      this.socket = null
    }
    if (this.proc) {
      try { this.proc.kill() } catch { }
      this.proc = null
    }
    this.startedAt = 0
    this.buffer = ''
  }

  /** Ask the agent to exit, then force it. */
  async stop() {
    const socket = this.socket
    if (socket) {
      try {
        socket.write(JSON.stringify({ id: 'shutdown', token: this.token, cmd: 'shutdown', req: {} }) + '\n')
      } catch { }
    }
    await delay(150)
    this.kill()
  }

  /** Release everything; the plugin's disposer calls this. */
  dispose() {
    this.disposed = true
    void this.stop()
  }
}
