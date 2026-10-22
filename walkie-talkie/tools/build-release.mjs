#!/usr/bin/env node
// Build a release ROM with debug logging removed.
//
// - fails if DEBUG is not false in src/util.lua
// - rejects direct printh() calls outside the dlog() wrapper
// - strips every single-line dlog(...) call from a temporary source copy
// - builds with the same coloXtool version as "clx.mjs build"
//
// Usage:
//   node tools/build-release.mjs
//   node tools/build-release.mjs --out dist/walkie-talkie.rom

import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { spawnSync } from 'node:child_process'
import { tmpdir } from 'node:os'
import path from 'node:path'
import process from 'node:process'

const root = path.resolve(import.meta.dirname, '..')
const args = process.argv.slice(2)
const outFlag = args.indexOf('--out')
if (outFlag >= 0 && !args[outFlag + 1]) {
  console.error('release build: --out needs a file path')
  process.exit(1)
}
const config = JSON.parse(readFileSync(path.join(root, 'clx.config.json'), 'utf8'))
const entry = config.entry || `${config.rom}.clx`
const outFile = outFlag >= 0 ? path.resolve(process.cwd(), args[outFlag + 1]) : path.join(root, 'dist', `${config.rom}.rom`)

const utilFile = path.join(root, 'src', 'util.lua')
const util = readFileSync(utilFile, 'utf8')
if (!/^\s*DEBUG\s*=\s*false\b/m.test(util)) {
  console.error('release build: src/util.lua must contain "DEBUG = false"')
  process.exit(1)
}

const srcDir = path.join(root, 'src')
const sources = readdirSync(srcDir).filter((name) => name.endsWith('.lua'))
let debugCalls = 0
for (const name of sources) {
  const text = readFileSync(path.join(srcDir, name), 'utf8')
  const lines = text.split(/\r?\n/)
  for (let i = 0; i < lines.length; i++) {
    if (/^\s*dlog\s*\(/.test(lines[i])) debugCalls++
    if (/\bprinth\s*\(/.test(lines[i]) && name !== 'util.lua') {
      console.error(`release build: direct printh() in src/${name}:${i + 1}; use dlog() instead`)
      process.exit(1)
    }
  }
}

const clx = path.join(root, '.agents', 'skills', 'clx-dev', 'scripts', 'clx.mjs')
if (!existsSync(clx)) {
  console.error(`release build: ${clx} not found; install the clx-dev skill first`)
  process.exit(1)
}

const temp = mkdtempSync(path.join(tmpdir(), 'walkie-release-'))
try {
  cpSync(path.join(root, 'clx.config.json'), path.join(temp, 'clx.config.json'))
  cpSync(srcDir, path.join(temp, 'src'), { recursive: true })
  const assets = path.join(root, 'assets')
  if (existsSync(assets)) cpSync(assets, path.join(temp, 'assets'), { recursive: true })
  mkdirSync(path.dirname(path.join(temp, entry)), { recursive: true })
  cpSync(path.join(root, entry), path.join(temp, entry))

  for (const name of sources) {
    const file = path.join(temp, 'src', name)
    const kept = readFileSync(file, 'utf8')
      .split(/\r?\n/)
      .filter((line) => !/^\s*dlog\s*\(/.test(line))
    writeFileSync(file, kept.join('\n'))
  }

  console.log(`release build: stripped ${debugCalls} dlog calls`)
  const result = spawnSync(process.execPath, [clx, 'build', '--root', temp, '--out', outFile], {
    cwd: root,
    stdio: 'inherit',
  })
  if (result.error) throw result.error
  if (result.status !== 0) process.exit(result.status ?? 1)
  console.log(`release build: ${outFile} (${statSync(outFile).size} bytes)`)
} finally {
  rmSync(temp, { recursive: true, force: true })
}
