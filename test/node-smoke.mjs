// Standalone smoke test for the Host half: no DSH required.
// Usage: node test/node-smoke.mjs
import path from 'node:path'
import os from 'node:os'
import { fileURLToPath } from 'node:url'
import { DesktopAgent } from '../lib/agent.js'
import { createTools } from '../lib/tools.js'

const here = path.dirname(fileURLToPath(import.meta.url))
const root = path.dirname(here)

const agent = new DesktopAgent({
  scriptPath: path.join(root, 'agent', 'desktop-agent.ps1'),
  idleMinutes: 5,
  logDir: path.join(os.tmpdir(), 'dsh-desktop-control-test'),
})

function line(label, value) {
  console.log(`\n=== ${label} ===`)
  console.log(value)
}

try {
  const status = await agent.request('status', {})
  line('status', JSON.stringify({
    screen: status.screen,
    ocr: status.ocr,
    uia: status.uia,
    foreground: status.foreground && status.foreground.title,
  }, null, 2))

  const tools = createTools({ agent, config: { ocrScale: 2 } })
  const byName = new Map(tools.map(tool => [tool.name, tool]))

  for (const tool of tools) {
    console.log(`tool ${tool.name}: ${Object.keys(tool.parameters.properties || {}).length} params, output schema ok=${typeof tool.output.schema === 'object'}`)
  }

  const shotDir = path.join(os.tmpdir(), 'dsh-desktop-control-test')
  const shotTool = byName.get('desktop_screenshot')
  const shot = await shotTool.execute({ mode: 'full', ocr: true, path: path.join(shotDir, 'node-smoke.png') }, {})
  const rendered = shotTool.output.render({}, shot)[0].text
  line('desktop_screenshot render', rendered.slice(0, 900))

  const ocrTool = byName.get('desktop_ocr')
  const ocr = await ocrTool.execute({ mode: 'region', region: { x: 0, y: 0, width: 900, height: 400 } }, {})
  line('desktop_ocr render', ocrTool.output.render({}, ocr)[0].text.slice(0, 600))

  const winTool = byName.get('desktop_window')
  const wins = await winTool.execute({ action: 'list', includeEmpty: false }, {})
  line('desktop_window render', winTool.output.render({}, wins)[0].text.slice(0, 700))

  const clipTool = byName.get('desktop_clipboard')
  const clip = await clipTool.execute({ action: 'get' }, {})
  line('desktop_clipboard render', clipTool.output.render({}, clip)[0].text.slice(0, 200))

  console.log('\nnode smoke ok')
}
catch (error) {
  console.error('\nnode smoke FAILED:', error && error.stack ? error.stack : error)
  if (error && error.detail) console.error(error.detail)
  process.exitCode = 1
}
finally {
  await agent.stop()
}
