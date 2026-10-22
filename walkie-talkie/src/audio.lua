-- Microphone capture, Opus/PCM playback, jitter buffer and local tones.

AUDIO = {
  mic_ok = false,
  wave_ok = false,
  opus_ok = false,
  codec = CODEC_PCM,
  tx_active = false,
  tx_start = 0,
  tx_level = 0,
  rx_level = 0,
  level = 0,
  mic_buf = "",
  mic_silent = false,
  last_signal = 0,
  rx_q = {},
  rx_peer = nil,
  rx_active = false,
  rx_last_seq = nil,
  last_rx_time = 0,
  prebuffered = false,
  prebuffer = 3,
  max_q = 8,
  fps = 60,
  last_fps = 0,
  mic_level = 0,
  mic_peak = 0,
  send_cb = function(pcm) end,
}

function AUDIO.init()
  AUDIO.send_cb = NET.send_audio
  AUDIO.opus_ok = AUDIO.setup_opus()
  NET.opus_ok = AUDIO.opus_ok
  local okw = pcall(function() wave('I') end)
  AUDIO.wave_ok = okw
  local okm, res = pcall(function() return usemod('mic') end)
  AUDIO.mic_ok = okm and res == true
  if AUDIO.mic_ok then pcall(function() micpoll(1) end) end
  AUDIO.last_fps = time()
  AUDIO.update_fps(time())
  dlog("audio init: opus=%s wave=%s mic=%s", tostring(AUDIO.opus_ok), tostring(AUDIO.wave_ok), tostring(AUDIO.mic_ok))
  if AUDIO.opus_ok and NET.enabled then pcall(NET.announce) end
end

-- Configure the Opus pair for 16 kHz / 20 ms. Firmware built without Opus
-- rejects the keys (or ignores them), so the link falls back to PCM.
function AUDIO.setup_opus()
  local ok = pcall(function()
    statctl('oers', RATE)
    statctl('oedm', OPUS_FRAME_MS)
    statctl('oebt', OPUS_BITRATE)
    statctl('oeap', 0)
    statctl('odrs', RATE)
    statctl('oddm', OPUS_FRAME_MS)
  end)
  if not ok then
    dlog("opus: statctl rejected, using PCM")
    return false
  end
  local okq, duration = pcall(function() return statctl('oedm') end)
  if not okq or duration ~= OPUS_FRAME_MS then
    dlog("opus: frame=%s (want %d), using PCM", tostring(duration), OPUS_FRAME_MS)
    return false
  end
  pcall(function() statctl('orst') end)
  dlog("opus: ready rate=%d frame=%dms bitrate=%d", RATE, OPUS_FRAME_MS, OPUS_BITRATE)
  return true
end

function AUDIO.update_fps(now)
  if now - AUDIO.last_fps < 2 then return end
  AUDIO.last_fps = now
  local f = stat(7)
  if f and f > 1 then AUDIO.fps = f end
  AUDIO.prebuffer = clamp(math.ceil(1.5 / AUDIO.fps / 0.02), 3, 8)
  AUDIO.max_q = AUDIO.prebuffer + 5
end

function AUDIO.play(name)
  local t = TONES[name]
  if not t or not AUDIO.wave_ok then return end
  if name == "busy" or name == "error" then
    pcall(function() wave('R') end)
  end
  pcall(function() wave(t) end)
end

function AUDIO.buffered()
  if not AUDIO.wave_ok then return 0 end
  local ok, n = pcall(function() return wave('L') end)
  if ok and type(n) == "number" then return n end
  return 0
end

function AUDIO.reset_rx()
  AUDIO.rx_q = {}
  AUDIO.rx_peer = nil
  AUDIO.rx_active = false
  AUDIO.rx_last_seq = nil
  AUDIO.rx_level = 0
  AUDIO.prebuffered = false
end

function AUDIO.start_tx(now)
  if not AUDIO.mic_ok then return false end
  if AUDIO.tx_active then return true end
  pcall(function() wave('R') end)
  pcall(function() micpoll(1) end)
  AUDIO.reset_rx()
  AUDIO.codec = CODEC_PCM
  local peer_opus = AUDIO.opus_ok and NET.peers_support_opus()
  if peer_opus then AUDIO.codec = CODEC_OPUS end
  dlog("tx start: codec=%s opus_capable=%s peers=%d", AUDIO.codec == CODEC_OPUS and "opus" or "pcm", tostring(AUDIO.opus_ok), NET.peer_count(NET.channel))
  AUDIO.tx_active = true
  AUDIO.tx_start = now
  AUDIO.tx_level = 0
  AUDIO.level = 0
  AUDIO.mic_buf = ""
  AUDIO.mic_silent = false
  AUDIO.last_signal = 0
  AUDIO.play("ptt_on")
  return true
end

function AUDIO.push_frame(data, codec)
  codec = codec or CODEC_PCM
  if codec == CODEC_PCM then
    if #data < FRAME_BYTES then
      data = data .. silence(FRAME_BYTES - #data)
    elseif #data > FRAME_BYTES then
      data = string.sub(data, 1, FRAME_BYTES)
    end
  elseif #data == 0 then
    return
  end
  AUDIO.rx_q[#AUDIO.rx_q + 1] = { codec = codec, data = data }
  while #AUDIO.rx_q > AUDIO.max_q do
    table.remove(AUDIO.rx_q, 1)
    AUDIO.prebuffered = false
  end
end

function AUDIO.capture(now)
  if not AUDIO.mic_ok then return 0 end
  if AUDIO.codec == CODEC_OPUS then return AUDIO.capture_opus(now) end
  return AUDIO.capture_pcm(now)
end

function AUDIO.capture_pcm(now)
  local units = micpoll(2)
  if not units or units <= 0 then return 0 end
  local got = 0
  for _ = 1, 8 do
    if units <= 0 then break end
    local n = units
    if n > FRAME_SAMPLES then n = FRAME_SAMPLES end
    local d = micpoll(3, n, AUDIOTYPE_PCM)
    if not d or #d == 0 then break end
    if #d > n * 2 then d = string.sub(d, 1, n * 2) end
    if #d % 2 == 1 then d = string.sub(d, 1, #d - 1) end
    AUDIO.mic_buf = AUDIO.mic_buf .. d
    got = got + #d
    units = units - flr(#d / 2)
    local lv = pcm_rms(d)
    if lv > AUDIO.tx_level then AUDIO.tx_level = lv end
    if lv > 0.008 then
      AUDIO.last_signal = now
      AUDIO.mic_silent = false
    end
  end
  while #AUDIO.mic_buf >= FRAME_BYTES do
    local frame = string.sub(AUDIO.mic_buf, 1, FRAME_BYTES)
    AUDIO.mic_buf = string.sub(AUDIO.mic_buf, FRAME_BYTES + 1)
    AUDIO.send_cb(frame, CODEC_PCM)
  end
  if #AUDIO.mic_buf > FRAME_BYTES * 6 then
    AUDIO.mic_buf = string.sub(AUDIO.mic_buf, #AUDIO.mic_buf - FRAME_BYTES * 6 + 1)
  end
  if AUDIO.tx_active and now - AUDIO.tx_start > 2.0 and now - AUDIO.last_signal > 1.5 then
    AUDIO.mic_silent = true
  end
  return got
end

-- micpoll uses the same [2-byte big-endian length][packet] framing that wave()
-- decodes. Split multi-packet chunks so each 20 ms frame gets its own seq.
local function split_opus_frames(data)
  local frames = {}
  local pos = 1
  while pos + 1 <= #data do
    local n = string.byte(data, pos) * 256 + string.byte(data, pos + 1)
    if n == 0 or pos + 1 + n > #data then return nil end
    frames[#frames + 1] = string.sub(data, pos, pos + 1 + n)
    pos = pos + 2 + n
  end
  if pos ~= #data + 1 then return nil end
  return frames
end

-- One encoded packet per 20 ms frame. The encoder buffers internally, so an
-- empty result just means the frame is not complete yet.
function AUDIO.capture_opus(now)
  local got = 0
  local units = micpoll(2) or 0
  for _ = 1, 8 do
    if units < FRAME_SAMPLES then break end
    local d = micpoll(3, FRAME_SAMPLES, AUDIOTYPE_OPUS)
    units = units - FRAME_SAMPLES
    if not d or #d == 0 then break end
    local frames = split_opus_frames(d)
    if not frames then frames = { d } end
    for _, frame in ipairs(frames) do
      AUDIO.send_cb(frame, CODEC_OPUS)
      got = got + #frame
      local lv = opus_level(#frame)
      if lv > AUDIO.tx_level then AUDIO.tx_level = lv end
      if lv > 0.05 then
        AUDIO.last_signal = now
        AUDIO.mic_silent = false
      end
    end
  end
  if AUDIO.tx_active and now - AUDIO.tx_start > 2.0 and now - AUDIO.last_signal > 1.5 then
    AUDIO.mic_silent = true
  end
  return got
end

function AUDIO.stop_tx(now)
  if not AUDIO.tx_active then return end
  AUDIO.capture(now)
  if AUDIO.codec == CODEC_PCM and #AUDIO.mic_buf > 1 then
    if #AUDIO.mic_buf % 2 == 1 then AUDIO.mic_buf = string.sub(AUDIO.mic_buf, 1, -2) end
    local last = AUDIO.mic_buf
    if #last < FRAME_BYTES then last = last .. silence(FRAME_BYTES - #last) end
    while #last >= FRAME_BYTES do
      AUDIO.send_cb(string.sub(last, 1, FRAME_BYTES), CODEC_PCM)
      last = string.sub(last, FRAME_BYTES + 1)
    end
  end
  AUDIO.mic_buf = ""
  AUDIO.tx_active = false
  AUDIO.tx_level = 0
  AUDIO.level = 0
  AUDIO.play("ptt_off")
end

function AUDIO.begin_rx(peer, now)
  if AUDIO.tx_active then return false end
  if AUDIO.rx_peer and AUDIO.rx_peer.id ~= peer.id then return false end
  if not AUDIO.rx_peer then
    AUDIO.rx_q = {}
    AUDIO.rx_last_seq = nil
    AUDIO.prebuffered = false
    AUDIO.rx_peer = peer
  end
  AUDIO.rx_active = true
  AUDIO.last_rx_time = now
  return true
end

function AUDIO.end_rx(peer, now)
  if AUDIO.rx_peer and AUDIO.rx_peer.id == peer.id then
    AUDIO.last_rx_time = now
  end
end

function AUDIO.push_rx(peer, seq, data, codec, now)
  if AUDIO.tx_active then return end
  if codec ~= CODEC_PCM and codec ~= CODEC_OPUS then
    dlog("rx: bad codec=%s from %s", tostring(codec), tostring(peer and peer.short))
    return
  end
  if AUDIO.rx_peer and AUDIO.rx_peer.id ~= peer.id then return end
  if not AUDIO.rx_peer then
    AUDIO.rx_q = {}
    AUDIO.rx_last_seq = nil
    AUDIO.prebuffered = false
    AUDIO.rx_peer = peer
  end
  if AUDIO.rx_last_seq then
    local d = (seq - AUDIO.rx_last_seq) % 65536
    if d == 0 or d > 32768 then return end
    if d > 1 then
      if d <= 11 then
        for _ = 2, d do AUDIO.push_frame(silence(FRAME_BYTES), CODEC_PCM) end
      else
        AUDIO.rx_q = {}
        AUDIO.prebuffered = false
      end
    end
  end
  AUDIO.rx_last_seq = seq
  AUDIO.rx_active = true
  AUDIO.last_rx_time = now
  if codec == CODEC_OPUS then
    local lv = opus_level(#data)
    if lv > AUDIO.rx_level then AUDIO.rx_level = lv end
    AUDIO.push_frame(data, CODEC_OPUS)
    return
  end
  local remaining = data
  while #remaining > 0 do
    local chunk = string.sub(remaining, 1, FRAME_BYTES)
    remaining = string.sub(remaining, FRAME_BYTES + 1)
    AUDIO.push_frame(chunk, CODEC_PCM)
    local lv = pcm_rms(chunk)
    if lv > AUDIO.rx_level then AUDIO.rx_level = lv end
  end
end

-- Returns "done" when the frame left the queue, "retry" when a partial Opus
-- packet stays at the head, "drop" when the data cannot be played at all.
function AUDIO.play_frame(frame)
  if frame.codec == CODEC_OPUS then
    local ok, _produced, consumed = pcall(function() return wave(frame.data, nil, nil, AUDIOTYPE_OPUS) end)
    if not ok then
      dlog("rx: opus decode failed (%dB)", #frame.data)
      return "drop"
    end
    if type(consumed) ~= "number" or consumed <= 0 then
      dlog("rx: opus consumed=%s (%dB)", tostring(consumed), #frame.data)
      return "drop"
    end
    if consumed < #frame.data then
      frame.data = string.sub(frame.data, consumed + 1)
      return "retry"
    end
    return "done"
  end
  if not pcall(function() wave(frame.data) end) then return "drop" end
  return "done"
end

function AUDIO.feed_rx(now)
  if not AUDIO.wave_ok then return end
  if #AUDIO.rx_q == 0 then
    if AUDIO.rx_active and now - AUDIO.last_rx_time > RX_TAIL then
      AUDIO.rx_active = false
      AUDIO.rx_peer = nil
      AUDIO.prebuffered = false
    end
    return
  end
  if not AUDIO.prebuffered then
    if #AUDIO.rx_q < AUDIO.prebuffer then return end
    AUDIO.prebuffered = true
  end
  for _ = 1, 10 do
    if #AUDIO.rx_q == 0 then break end
    local free = wave()
    -- one 20 ms decoded frame is FRAME_BYTES; keep room for a few
    if not free or free < FRAME_BYTES * 3 then break end
    local state = AUDIO.play_frame(AUDIO.rx_q[1])
    if state == "retry" then break end
    table.remove(AUDIO.rx_q, 1)
  end
end

function AUDIO.update(now)
  AUDIO.update_fps(now)

  if AUDIO.tx_active then
    AUDIO.capture(now)
  else
    AUDIO.feed_rx(now)
    AUDIO.rx_level = AUDIO.rx_level * 0.86
    if AUDIO.rx_level < 0.005 then AUDIO.rx_level = 0 end
  end

  local target = 0
  if AUDIO.tx_active then
    target = AUDIO.tx_level
    AUDIO.tx_level = AUDIO.tx_level * 0.82
  elseif AUDIO.rx_active then
    target = AUDIO.rx_level
  end
  if target > AUDIO.level then
    AUDIO.level = target
  else
    AUDIO.level = AUDIO.level * 0.82
    if AUDIO.level < 0.004 then AUDIO.level = 0 end
  end
end

function AUDIO.mic_test(now)
  if not AUDIO.mic_ok then return end
  local units = micpoll(2)
  if not units or units <= 0 then
    AUDIO.mic_level = AUDIO.mic_level * 0.9
    return
  end
  local lv = 0
  for _ = 1, 4 do
    if units <= 0 then break end
    local n = units
    if n > FRAME_SAMPLES then n = FRAME_SAMPLES end
    local d = micpoll(3, n, AUDIOTYPE_PCM)
    if not d or #d == 0 then break end
    lv = math.max(lv, pcm_rms(d))
    units = units - flr(#d / 2)
  end
  if lv > AUDIO.mic_level then
    AUDIO.mic_level = lv
  else
    AUDIO.mic_level = AUDIO.mic_level * 0.9
  end
  if AUDIO.mic_level > AUDIO.mic_peak then AUDIO.mic_peak = AUDIO.mic_level end
  AUDIO.mic_peak = AUDIO.mic_peak * 0.995
end
