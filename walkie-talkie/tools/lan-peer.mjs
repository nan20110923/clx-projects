#!/usr/bin/env node
// LAN walkie-talkie test peer.
// Usage:
//   node tools/lan-peer.mjs --target 127.0.0.1:47654
//   node tools/lan-peer.mjs --target 192.168.1.50:47654 --tone --record
//   node tools/lan-peer.mjs --target 127.0.0.1:47654 --wav-in voice.wav
//
// It announces itself as WT-TEST, receives audio from the cartridge and can
// send a 440 Hz test tone (or a 16 kHz mono 16-bit WAV file) back.

import dgram from 'node:dgram'
import fs from 'node:fs'
import path from 'node:path'

const args = process.argv.slice(2)
function arg(name, def) {
  const i = args.indexOf('--' + name)
  return i >= 0 && args[i + 1] && !args[i + 1].startsWith('--') ? args[i + 1] : def
}
function flag(name) { return args.includes('--' + name) }

const targetRaw = arg('target', '127.0.0.1:47654')
const [targetIp, targetPortRaw] = targetRaw.split(':')
const targetPort = Number(targetPortRaw || 47654)
const localPort = Number(arg('port', 47655))
const bindIp = arg('bind', '0.0.0.0')
const passive = flag('passive')
const noLoopback = flag('no-loopback')
const channel = Number(arg('channel', 1))
const nodeId = Number(arg('id', 0x7e57))
const duration = Number(arg('duration', 3000))
const toneDelay = Number(arg('tone-delay', 800))
const record = flag('record')
const tone = flag('tone')
const wavIn = arg('wav-in', '')
const outFile = arg('out', 'tools/out.wav')
// batch N frames every burstMs instead of one frame per 20ms,
// emulating DTIM/power-save batched delivery on real WiFi. 0 = native pacing.
const burstMs = Number(arg('burst', 0))

const TYPE = { announce: 1, audio: 2, voice: 3, call: 4, bye: 5 }

function header(type, seq) {
  const b = Buffer.alloc(9)
  b.write('WT', 0, 'ascii')
  b[2] = 2
  b[3] = type
  b[4] = channel
  b.writeUInt16LE(nodeId & 0xffff, 5)
  b.writeUInt16LE(seq & 0xffff, 7)
  return b
}
function parse(buf) {
  if (buf.length < 9 || buf.toString('ascii', 0, 2) !== 'WT') return null
  return {
    ver: buf[2], type: buf[3], channel: buf[4],
    id: buf.readUInt16LE(5), seq: buf.readUInt16LE(7),
    payload: buf.subarray(9),
  }
}
function log(...a) { console.log(new Date().toISOString().slice(11, 23), ...a) }

const sock = dgram.createSocket('udp4')
let seq = 0
let audioSeq = 0
let peer = null
let rxPackets = 0
let rxBytes = 0
let txPackets = 0
let lastRx = 0
let toneTimer = null
let announceTimer = null
let warnedOpus = false
const recorded = []

function send(buf, port = targetPort, ip = targetIp) {
  sock.send(buf, port, ip, (err) => {
    if (err) log('send error', err.message)
  })
  txPackets++
}

function announce() {
  const pkt = Buffer.concat([header(TYPE.announce, seq++), Buffer.from([0])])
  send(pkt)
}

function startAnnounce() {
  if (announceTimer) return
  announce()
  announceTimer = setInterval(announce, 1000)
}

function sendVoice(state) {
  send(Buffer.concat([header(TYPE.voice, seq++), Buffer.from([state ? 1 : 0])]))
}

function sendCall() {
  send(header(TYPE.call, seq++))
}

function sineFrame(freq, phase) {
  const b = Buffer.alloc(640)
  for (let i = 0; i < 320; i++) {
    const v = Math.round(Math.sin((phase + i) * 2 * Math.PI * freq / 16000) * 9000)
    b.writeInt16LE(v, i * 2)
  }
  return { frame: b, phase: (phase + 320) % 16000 }
}

// [DEBUG-jit] burstMs > 0 batches round(burstMs/20) frames every burstMs,
// reproducing the batched arrival pattern seen on power-saving WiFi.

function sendTone(ms = 1500, freq = 440) {
  if (toneTimer) return
  log(`sending ${ms}ms ${freq}Hz tone${burstMs > 0 ? ` burst=${burstMs}ms` : ''}`)
  sendVoice(true)
  let phase = 0
  const frames = Math.round(ms / 20)
  let n = 0
  const stop = () => {
    clearInterval(toneTimer)
    toneTimer = null
    sendVoice(false)
    log('tone done')
  }
  if (burstMs > 0) {
    const per = Math.max(1, Math.round(burstMs / 20))
    toneTimer = setInterval(() => {
      for (let i = 0; i < per && n < frames; i++, n++) {
        const r = sineFrame(freq, phase)
        phase = r.phase
        send(Buffer.concat([header(TYPE.audio, audioSeq++), Buffer.from([0]), r.frame]))
      }
      if (n >= frames) stop()
    }, burstMs)
  } else {
    toneTimer = setInterval(() => {
      const r = sineFrame(freq, phase)
      phase = r.phase
      send(Buffer.concat([header(TYPE.audio, audioSeq++), Buffer.from([0]), r.frame]))
      if (++n >= frames) stop()
    }, 20)
  }
}

function sendWav(file) {
  const buf = fs.readFileSync(file)
  let off = 12
  let data = null
  while (off + 8 <= buf.length) {
    const id = buf.toString('ascii', off, off + 4)
    const size = buf.readUInt32LE(off + 4)
    if (id === 'data') { data = buf.subarray(off + 8, off + 8 + size); break }
    off += 8 + size + (size % 2)
  }
  if (!data) { log('no data chunk in', file); return }
  log(`sending WAV ${file}, ${(data.length / 2 / 16000).toFixed(2)}s${burstMs > 0 ? ` burst=${burstMs}ms` : ''}`)
  sendVoice(true)
  let pos = 0
  let wavTimer = null
  const stop = () => {
    clearInterval(wavTimer)
    sendVoice(false)
    log('wav done')
  }
  if (burstMs > 0) {
    const per = Math.max(1, Math.round(burstMs / 20))
    wavTimer = setInterval(() => {
      for (let i = 0; i < per && pos < data.length; i++) {
        const frame = Buffer.alloc(640)
        const n = Math.min(640, data.length - pos)
        data.copy(frame, 0, pos, pos + n)
        pos += n
        send(Buffer.concat([header(TYPE.audio, audioSeq++), Buffer.from([0]), frame]))
      }
      if (pos >= data.length) stop()
    }, burstMs)
  } else {
    wavTimer = setInterval(() => {
      const frame = Buffer.alloc(640)
      const n = Math.min(640, data.length - pos)
      if (n > 0) data.copy(frame, 0, pos, pos + n)
      pos += n
      send(Buffer.concat([header(TYPE.audio, audioSeq++), Buffer.from([0]), frame]))
      if (pos >= data.length) stop()
    }, 20)
  }
}

function wavBytes() {
  const data = Buffer.concat(recorded)
  const b = Buffer.alloc(44)
  b.write('RIFF', 0); b.writeUInt32LE(36 + data.length, 4); b.write('WAVE', 8)
  b.write('fmt ', 12); b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22)
  b.writeUInt32LE(16000, 24); b.writeUInt32LE(32000, 28); b.writeUInt16LE(2, 32); b.writeUInt16LE(16, 34)
  b.write('data', 36); b.writeUInt32LE(data.length, 40)
  return Buffer.concat([b, data])
}

sock.on('message', (msg, rinfo) => {
  const p = parse(msg)
  if (!p || p.id === nodeId) return
  if (p.channel !== channel) return
  if (noLoopback && rinfo.address === '127.0.0.1' && p.type === TYPE.announce) return
  if (p.type === TYPE.announce) {
    const first = !peer
    const flags = p.payload[0] || 0
    peer = { id: p.id, ip: rinfo.address, port: rinfo.port, opus: (flags & 4) !== 0 }
    if (passive && !announceTimer) startAnnounce()
    if (first) {
      log(`peer WT-${p.id.toString(16).toUpperCase().padStart(4, '0')} at ${rinfo.address}:${rinfo.port}${peer.opus ? ' (opus)' : ''}`)
      if (tone) setTimeout(() => sendTone(duration), toneDelay)
      if (wavIn) setTimeout(() => sendWav(wavIn), 800)
    }
  } else if (p.type === TYPE.audio) {
    const codec = p.payload[0] || 0
    const data = p.payload.subarray(1)
    rxPackets++
    rxBytes += data.length
    if (codec !== 0) {
      if (!warnedOpus) log(`RX Opus packet (${data.length}B); this peer only records PCM`)
      warnedOpus = true
    } else if (record) {
      recorded.push(Buffer.from(data))
    }
    const now = Date.now()
    if (!lastRx || now - lastRx > 1000) {
      log(`RX audio #${rxPackets} ${data.length}B${codec === 0 ? '' : ' opus'} from WT-${p.id.toString(16).toUpperCase()}`)
      lastRx = now
    }
  } else if (p.type === TYPE.voice) {
    log(`peer voice ${p.payload[0] ? 'START' : 'STOP'}`)
  } else if (p.type === TYPE.call) {
    log('peer CALL tone')
  } else if (p.type === TYPE.bye) {
    log('peer BYE')
  }
})

sock.bind(localPort, bindIp, () => {
  log(`listening on ${bindIp}:${localPort}, target ${targetIp}:${targetPort}, id=${nodeId.toString(16)}${passive ? ', passive' : ''}`)
  if (!passive) startAnnounce()
  if (flag('call')) setTimeout(sendCall, 2500)
  setTimeout(() => {
    if (announceTimer) clearInterval(announceTimer)
    if (toneTimer) clearInterval(toneTimer)
    log(`done: tx=${txPackets} rx=${rxPackets} audio=${rxBytes}B`)
    if (record && recorded.length) {
      fs.mkdirSync(path.dirname(outFile), { recursive: true })
      fs.writeFileSync(outFile, wavBytes())
      log(`wrote ${outFile} (${(rxBytes / 32000).toFixed(2)}s)`)
    }
    sock.close()
    process.exit(0)
  }, Number(arg('listen', 12000)))
})
