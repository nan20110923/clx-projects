-- Shared constants and helpers for the LAN walkie-talkie.
-- Included before net/audio/main by walkie-talkie.clx.

-- Release switch. Keep this false for release builds; tools/build-release.mjs
-- refuses to build otherwise. Set it to true only while debugging locally.
DEBUG = false

-- Debug console output. printh() writes to the host/simulator console; print()
-- is the on-screen text renderer and must never be used for logging.
-- Keep every dlog() call on its own line: the release build strips those lines.
function dlog(fmt, ...)
  if not DEBUG then return end
  local ok, s = pcall(string.format, fmt, ...)
  printh(ok and s or tostring(fmt))
end

RATE = 16000                 -- PCM sample rate
FRAME_SAMPLES = 320          -- 20 ms
FRAME_BYTES = 640            -- 20 ms of mono 16-bit PCM

OPUS_FRAME_MS = 20           -- must match FRAME_SAMPLES
OPUS_BITRATE = 24000         -- bits/s; raw PCM would be 256 kbps
CODEC_PCM = 0
CODEC_OPUS = 1

-- audiotype argument for wave()/micpoll(); NOT the same as the wire codec id.
AUDIOTYPE_PCM = 0
AUDIOTYPE_ADPCM = 1
AUDIOTYPE_G711A = 2
AUDIOTYPE_OPUS = 3

PROTO_MAGIC = "WT"
PROTO_VER = 2                -- v2: audio packets carry a codec byte
PKT_ANNOUNCE = 1
PKT_AUDIO = 2
PKT_VOICE = 3
PKT_CALL = 4
PKT_BYE = 5

PORT_BASE = 47654
PORT_TRIES = 10

PEER_TIMEOUT = 8.0
TALK_TIMEOUT = 0.8
RX_TAIL = 0.35
RX_HOLD = 0.5

HEADER_FMT = "<c2 B B B I2 I2"

function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

function text_w(s, size)
  local cw = (size == 4) and 4 or 8
  return #s * cw
end

function draw_center(s, y, size, col)
  print(s, flr(120 - text_w(s, size) / 2), y, col, 0, size)
end

function draw_right(s, xr, y, size, col)
  print(s, xr - text_w(s, size), y, col, 0, size)
end

function fmt_ip(a, b, c, d)
  return string.format("%d.%d.%d.%d", a, b, c, d)
end

function ip_to_int(s)
  local a, b, c, d = string.match(s or "", "^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then return nil end
  a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
  if a > 255 or b > 255 or c > 255 or d > 255 then return nil end
  return a * 16777216 + b * 65536 + c * 256 + d
end

function int_to_ip(n)
  n = n % 4294967296
  local a = flr(n / 16777216) % 256
  local b = flr(n / 65536) % 256
  local c = flr(n / 256) % 256
  local d = n % 256
  return fmt_ip(a, b, c, d)
end

function valid_ip(s)
  return ip_to_int(s) ~= nil
end

function is_zero_ip(s)
  return s == nil or s == "" or s == "0.0.0.0"
end

-- Root-mean-square level of 16-bit little-endian PCM, sampled sparsely.
function pcm_rms(pcm)
  local n = #pcm
  if n < 2 then return 0 end
  local pairs_n = flr(n / 2)
  local step = 1
  if pairs_n > 48 then step = flr(pairs_n / 48) end
  local sum, count = 0, 0
  local i = 1
  while i + 1 <= n do
    local lo, hi = string.byte(pcm, i, i + 1)
    local v = lo + hi * 256
    if v >= 32768 then v = v - 65536 end
    sum = sum + abs(v)
    count = count + 1
    i = i + step * 2
  end
  if count == 0 then return 0 end
  return (sum / count) / 32768
end

function silence(bytes)
  return string.rep("\0", bytes)
end

-- Rough signal level for Opus frames: a 20 ms silent VOIP frame is a few
-- bytes, speech is tens of bytes. Only used for the level meter.
function opus_level(bytes)
  return clamp((bytes - 10) / 55, 0, 1)
end

-- Generate a short sine tone with 5 ms fades to avoid clicks.
function synth_tone(freq, ms, vol)
  local n = flr(RATE * ms / 1000)
  local fade = flr(RATE * 0.005)
  if fade < 4 then fade = 4 end
  local out = {}
  for i = 0, n - 1 do
    local env = 1
    if i < fade then
      env = i / fade
    elseif i > n - fade then
      env = (n - i) / fade
    end
    local v = flr(sin(freq * i / RATE) * vol * env)
    if v < 0 then v = v + 65536 end
    out[#out + 1] = string.char(v % 256, flr(v / 256))
  end
  return table.concat(out)
end

TONES = {
  ptt_on = synth_tone(1250, 28, 6000),
  ptt_off = synth_tone(760, 28, 4500),
  tick = synth_tone(1700, 14, 3500),
  busy = synth_tone(380, 170, 8000) .. silence(3200) .. synth_tone(380, 170, 8000),
  error = synth_tone(210, 240, 7000),
  call = synth_tone(880, 90, 9000) .. silence(1600)
    .. synth_tone(1180, 90, 9000) .. silence(1600)
    .. synth_tone(1480, 140, 9000),
}

-- Best-effort unique seed for first-run node ids. utcsec() can be 0 on a
-- device without RTC, so mix in the WiFi MAC/IP when available.
function seed_value()
  local seed = 1
  local okt, t = pcall(function() return utcsec() end)
  if okt and type(t) == "number" then seed = seed + (t % 1000000) end
  local okm, mac = pcall(function() return svcget('$wifi.mac') end)
  if okm and type(mac) == "string" then
    for i = 1, #mac do
      seed = seed + string.byte(mac, i) * (i + 7)
    end
  end
  local oki, ip = pcall(function() return svcget('$wifi.ip') end)
  if oki and type(ip) == "string" then
    seed = seed + (ip_to_int(ip) or 0)
  end
  return seed % 2147483647
end

function short_id(id)
  local n = flr(id) % 65536
  return string.format("%04X", n)
end

function full_id(id)
  return "WT-" .. short_id(id)
end
