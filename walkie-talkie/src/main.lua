-- LAN walkie-talkie: state machine, settings and screens.

CFG = {
  id = 0,
  channel = 1,
  ip = { 0, 0, 0, 0 },
  fixed_ip = "",
  callsign = "",
}

APP = {
  screen = "main",
  sel = 1,
  ip_sel = 1,
  ip_edit = { 0, 0, 0, 0 },
  channel_edit = 1,
  toast_text = "",
  toast_until = 0,
  busy_until = 0,
  rx_until = 0,
  rx_peer = nil,
  center_down = false,
  last_now = 0,
  started = false,
  save_ok = false,
}

function APP.toast(s, d)
  APP.toast_text = s
  APP.toast_until = time() + (d or 1.2)
end

function APP.save()
  if not APP.save_ok then return end
  pcall(function()
    dset(0, CFG.id)
    dset(1, CFG.channel)
    dset(2, CFG.ip[1])
    dset(3, CFG.ip[2])
    dset(4, CFG.ip[3])
    dset(5, CFG.ip[4])
    dflush()
  end)
end

function APP.load()
  local ok, res = pcall(function() return cartdata("walkie_talkie") end)
  APP.save_ok = ok and res ~= false
  if not APP.save_ok then return end
  local id = dget(0) or 0
  if id > 0 and id <= 65535 then CFG.id = flr(id) end
  local ch = dget(1) or 1
  CFG.channel = clamp(flr(ch), 1, 3)
  CFG.ip = { dget(2) or 0, dget(3) or 0, dget(4) or 0, dget(5) or 0 }
  for i = 1, 4 do CFG.ip[i] = clamp(flr(CFG.ip[i]), 0, 255) end
  if CFG.ip[1] + CFG.ip[2] + CFG.ip[3] + CFG.ip[4] > 0 then
    CFG.fixed_ip = fmt_ip(CFG.ip[1], CFG.ip[2], CFG.ip[3], CFG.ip[4])
  end
end

function APP.set_channel(ch)
  CFG.channel = ch
  NET.set_channel(ch)
  AUDIO.reset_rx()
  APP.rx_until = 0
  APP.rx_peer = nil
  APP.save()
  APP.toast("CHANNEL " .. ch, 0.8)
  AUDIO.play("tick")
end

function APP.save_ip()
  for i = 1, 4 do CFG.ip[i] = clamp(flr(APP.ip_edit[i]), 0, 255) end
  if CFG.ip[1] + CFG.ip[2] + CFG.ip[3] + CFG.ip[4] == 0 then
    CFG.fixed_ip = ""
    NET.set_fixed_ip("")
    APP.toast("FIXED IP: AUTO", 1.4)
  else
    CFG.fixed_ip = fmt_ip(CFG.ip[1], CFG.ip[2], CFG.ip[3], CFG.ip[4])
    NET.set_fixed_ip(CFG.fixed_ip)
    APP.toast("FIXED IP SAVED", 1.4)
  end
  APP.save()
end

function APP.open_settings()
  if AUDIO.tx_active then return end
  APP.screen = "settings"
  APP.sel = 1
end

function APP.on_center(now)
  if APP.screen == "settings" then
    if APP.sel == 1 then
      APP.channel_edit = CFG.channel
      APP.screen = "channel"
    elseif APP.sel == 2 then
      APP.ip_edit = { CFG.ip[1], CFG.ip[2], CFG.ip[3], CFG.ip[4] }
      APP.ip_sel = 1
      APP.screen = "ip"
    elseif APP.sel == 3 then
      pcall(function() micpoll(1) end)
      AUDIO.mic_peak = 0
      AUDIO.mic_level = 0
      APP.screen = "mic"
    elseif APP.sel == 4 then
      APP.screen = "net"
    else
      APP.screen = "main"
    end
  elseif APP.screen == "channel" then
    APP.set_channel(APP.channel_edit)
    APP.screen = "main"
  elseif APP.screen == "ip" then
    if APP.ip_sel < 4 then
      APP.ip_sel = APP.ip_sel + 1
      AUDIO.play("tick")
    else
      APP.save_ip()
      APP.screen = "settings"
    end
  end
  if APP.screen ~= "main" then AUDIO.play("tick") end
end

function APP.try_talk(now)
  if AUDIO.tx_active then return end
  if AUDIO.rx_active or now < APP.rx_until then
    APP.busy_until = now + 1.2
    APP.toast("CHANNEL BUSY", 1.0)
    AUDIO.play("busy")
    return
  end
  if not NET.has_targets() then
    APP.toast("NO PEER", 1.2)
    AUDIO.play("error")
    return
  end
  if not AUDIO.mic_ok then
    APP.toast("NO MIC", 1.4)
    AUDIO.play("error")
    return
  end
  if not AUDIO.start_tx(now) then
    APP.toast("AUDIO ERROR", 1.2)
    return
  end
  NET.send_voice(1)
  APP.rx_until = 0
  APP.rx_peer = nil
end

function APP.stop_talk(now)
  if not AUDIO.tx_active then return end
  AUDIO.stop_tx(now)
  NET.send_voice(0)
end

function APP.handle_main(now, pressed, released)
  if btnp(5) and not AUDIO.tx_active then
    APP.set_channel(CFG.channel == 1 and 3 or CFG.channel - 1)
  end
  if btnp(6) and not AUDIO.tx_active then
    APP.set_channel(CFG.channel == 3 and 1 or CFG.channel + 1)
  end
  if btnp(2) and not AUDIO.tx_active then
    if NET.send_call() then
      AUDIO.play("tick")
      APP.toast("CALL SENT", 1.0)
    else
      APP.toast("NO PEER", 1.2)
      AUDIO.play("error")
    end
  end
  if btnp(3) and not AUDIO.tx_active then
    APP.open_settings()
    return
  end
  if pressed then APP.try_talk(now) end
  if released then APP.stop_talk(now) end
end

function APP.handle_settings(now, pressed)
  if btnp(3) then
    APP.screen = "main"
    AUDIO.play("tick")
    return
  end
  if btnp(5) then
    APP.sel = APP.sel == 1 and 5 or APP.sel - 1
    AUDIO.play("tick")
  end
  if btnp(6) then
    APP.sel = APP.sel == 5 and 1 or APP.sel + 1
    AUDIO.play("tick")
  end
  if pressed then APP.on_center(now) end
end

function APP.handle_channel(now, pressed)
  if btnp(3) then
    APP.screen = "settings"
    AUDIO.play("tick")
    return
  end
  if btnp(5) then
    APP.channel_edit = APP.channel_edit == 1 and 3 or APP.channel_edit - 1
    AUDIO.play("tick")
  end
  if btnp(6) then
    APP.channel_edit = APP.channel_edit == 3 and 1 or APP.channel_edit + 1
    AUDIO.play("tick")
  end
  if pressed then
    APP.set_channel(APP.channel_edit)
    APP.screen = "main"
  end
end

function APP.handle_ip(now, pressed)
  if btnp(3) then
    APP.screen = "settings"
    AUDIO.play("tick")
    return
  end
  if btnp(5) then
    APP.ip_edit[APP.ip_sel] = (APP.ip_edit[APP.ip_sel] + 255) % 256
    AUDIO.play("tick")
  end
  if btnp(6) then
    APP.ip_edit[APP.ip_sel] = (APP.ip_edit[APP.ip_sel] + 1) % 256
    AUDIO.play("tick")
  end
  if pressed then
    if APP.ip_sel < 4 then
      APP.ip_sel = APP.ip_sel + 1
      AUDIO.play("tick")
    else
      APP.save_ip()
      APP.screen = "settings"
    end
  end
end

function APP.handle_input(now)
  local down = btn(4)
  local pressed = down and not APP.center_down
  local released = (not down) and APP.center_down
  APP.center_down = down

  if APP.screen == "main" then
    APP.handle_main(now, pressed, released)
  elseif APP.screen == "settings" then
    APP.handle_settings(now, pressed)
  elseif APP.screen == "channel" then
    APP.handle_channel(now, pressed)
  elseif APP.screen == "ip" then
    APP.handle_ip(now, pressed)
  elseif APP.screen == "mic" then
    if btnp(3) then
      APP.screen = "settings"
      AUDIO.play("tick")
    end
  elseif APP.screen == "net" then
    if btnp(3) then
      APP.screen = "settings"
      AUDIO.play("tick")
    end
  end
end

function APP.setup_net_callbacks()
  NET.on_audio = function(peer, seq, data, codec)
    if AUDIO.tx_active then return end
    local now = time()
    AUDIO.push_rx(peer, seq, data, codec, now)
    APP.rx_until = now + RX_HOLD
    APP.rx_peer = peer
  end
  NET.on_voice = function(peer, state)
    local now = time()
    if state == 1 then
      if AUDIO.tx_active then
        -- Simultaneous PTT: the lower node id wins.
        if now - AUDIO.tx_start < 0.8 and peer.id < NET.id then
          AUDIO.stop_tx(now)
          NET.send_voice(0)
          APP.toast("CHANNEL BUSY", 1.0)
          AUDIO.begin_rx(peer, now)
          APP.rx_until = now + RX_HOLD
          APP.rx_peer = peer
        end
        return
      end
      if AUDIO.begin_rx(peer, now) then
        APP.rx_until = now + RX_HOLD
        APP.rx_peer = peer
      end
    else
      AUDIO.end_rx(peer, now)
      if APP.rx_peer and APP.rx_peer.id == peer.id then
        APP.rx_until = math.min(APP.rx_until, now + 0.3)
      end
    end
  end
  NET.on_call = function(peer)
    APP.toast("CALL " .. peer.short, 1.6)
    if not AUDIO.tx_active then AUDIO.play("call") end
  end
end

function _init()
  APP.load()
  srand(seed_value())
  if CFG.id == 0 then
    CFG.id = flr(rnd(65535)) + 1
    APP.save()
  end
  CFG.callsign = full_id(CFG.id)

  NET.init(CFG.id, CFG.channel, CFG.fixed_ip)
  APP.setup_net_callbacks()
  AUDIO.init()
  APP.last_now = time()
  APP.started = true

  if not NET.enabled then
    APP.toast("NET ERROR", 3)
  elseif not AUDIO.mic_ok then
    APP.toast("NO MIC", 3)
  elseif not AUDIO.wave_ok then
    APP.toast("NO AUDIO", 3)
  end
end

function _update()
  local now = time()
  if now < APP.last_now then APP.last_now = now end
  APP.last_now = now
  NET.update(now)
  AUDIO.update(now)
  APP.handle_input(now)
  if APP.screen == "mic" then AUDIO.mic_test(now) end
end

function APP.draw_body()
  cls(black)
  circfill(120, 120, 119, dark_gray)
  circfill(120, 120, 113, black)
  circ(120, 120, 118, dark_gray)
  for i = -2, 2 do
    circfill(120 + i * 12, 28, 2, dark_green)
  end
end

function APP.draw_top()
  print(CFG.callsign, 38, 34, light_gray, 0, 8)
  draw_right("CH " .. CFG.channel, 202, 34, 8, orange)
  local dot = dark_gray
  if not NET.enabled then
    dot = red
  elseif NET.peer_count(CFG.channel) > 0 then
    dot = green
  elseif NET.own_ip ~= "0.0.0.0" then
    dot = orange
  end
  circfill(120, 38, 3, dot)
end

function APP.draw_ptt(now)
  local state = "idle"
  local ring = dark_gray
  local inner = dark_green
  if AUDIO.tx_active then
    state = "tx"
    ring = red
    inner = black
  elseif now < APP.busy_until then
    state = "busy"
    ring = yellow
    inner = black
  elseif AUDIO.rx_active or now < APP.rx_until then
    state = "rx"
    ring = green
    inner = black
  end

  local ticks = 24
  for i = 0, ticks - 1 do
    local a = i / ticks + 0.25
    local len = 2
    if state == "tx" or state == "rx" then
      len = 2 + AUDIO.level * 10
    elseif state == "idle" then
      len = 2 + 1.5 * (0.5 + 0.5 * sin(now * 0.4 + i * 0.05))
    end
    local r0 = 62
    line(
      120 + cos(a) * r0, 116 + sin(a) * r0,
      120 + cos(a) * (r0 + len), 116 + sin(a) * (r0 + len),
      ring
    )
  end
  circ(120, 116, 58, ring)
  circ(120, 116, 57, ring)
  circfill(120, 116, 53, inner)

  if state == "tx" then
    draw_center("TALK", 94, 16, ring)
    if AUDIO.mic_silent then
      draw_center("MIC SILENT", 116, 8, yellow)
    else
      draw_center("MIC OK", 116, 8, light_gray)
    end
    draw_center("ON AIR", 140, 8, ring)
  elseif state == "rx" then
    local who = AUDIO.rx_peer and AUDIO.rx_peer.short or APP.rx_peer and APP.rx_peer.short or "----"
    draw_center(who, 94, 16, ring)
    draw_center("RECEIVING", 116, 8, light_gray)
    draw_center("FROM " .. who, 142, 8, ring)
  elseif state == "busy" then
    draw_center("BUSY", 94, 16, ring)
    draw_center("IN USE", 116, 8, light_gray)
    draw_center("WAIT", 140, 8, ring)
  else
    draw_center("HOLD", 94, 16, light_gray)
    draw_center("TO TALK", 116, 8, light_gray)
    local hint, hcol = "PTT CENTER", light_gray
    if NET.peer_count(CFG.channel) == 0 then
      if CFG.fixed_ip ~= "" then
        hint, hcol = "FIXED IP", light_gray
      else
        hint, hcol = "SEARCHING", yellow
      end
    end
    draw_center(hint, 142, 8, hcol)
  end
end

function APP.draw_dial()
  print("CH", 84, 184, light_gray, 0, 8)
  for ch = 1, 3 do
    local x = 106 + (ch - 1) * 18
    local col = (ch == CFG.channel) and orange or dark_gray
    print(tostring(ch), x, 184, col, 0, 8)
    if ch == CFG.channel then
      line(x, 194, x + 8, 194, orange)
    end
  end
end

function APP.draw_peers()
  local peers = NET.get_peers(CFG.channel)
  local centers = { 54, 90, 126, 162 }
  for i = 1, 4 do
    local cx = centers[i]
    local p = peers[i]
    if p then
      local col = p.talking and green or light_gray
      circfill(cx, 205, 3, col)
      print(p.short, cx - 8, 212, col, 0, 4)
    else
      circfill(cx, 205, 3, dark_green)
      print("--", cx - 4, 212, dark_gray, 0, 4)
    end
  end
end

function APP.draw_main(now)
  APP.draw_body()
  APP.draw_top()
  APP.draw_ptt(now)
  APP.draw_dial()
  APP.draw_peers()
  draw_center(NET.own_ip, 226, 4, light_gray)
end

function APP.draw_settings()
  APP.draw_body()
  draw_center("SETTINGS", 26, 8, orange)
  local labels = { "CHANNEL", "FIXED", "MIC TEST", "NETWORK", "BACK" }
  local values = {
    tostring(CFG.channel),
    CFG.fixed_ip == "" and "AUTO" or CFG.fixed_ip,
    AUDIO.mic_ok and "OK" or "N/A",
    NET.enabled and (NET.peer_count(CFG.channel) .. " ONLINE") or "OFF",
    "",
  }
  for i = 1, 5 do
    local y = 52 + (i - 1) * 26
    if i == APP.sel then
      rectfill(30, y - 4, 210, y + 12, dark_green)
    end
    local col = (i == APP.sel) and white or light_gray
    print(labels[i], 40, y, col, 0, 8)
    if values[i] ~= "" then
      draw_right(values[i], 204, y, 8, (i == APP.sel) and orange or light_gray)
    end
  end
  draw_center("TURN = MOVE", 186, 8, dark_gray)
  draw_center("PRESS OK   B BACK", 200, 8, dark_gray)
end

function APP.draw_channel()
  APP.draw_body()
  draw_center("CHANNEL", 26, 8, orange)
  draw_center("CH " .. APP.channel_edit, 80, 16, white)
  for ch = 1, 3 do
    local cx = 88 + (ch - 1) * 32
    local active = ch == APP.channel_edit
    if active then
      rectfill(cx - 14, 126, cx + 14, 154, dark_green)
      rect(cx - 14, 126, cx + 14, 154, orange)
    else
      rect(cx - 14, 126, cx + 14, 154, dark_gray)
    end
    local s = tostring(ch)
    print(s, cx - #s * 4, 134, active and orange or dark_gray, 0, 8)
    if active then
      line(cx - 4, 160, cx + 4, 160, orange)
    end
  end
  draw_center("TURN TO CHANGE", 178, 8, dark_gray)
  draw_center("PRESS SAVE   B CANCEL", 194, 8, dark_gray)
end

function APP.draw_ip()
  APP.draw_body()
  draw_center("FIXED PEER IP", 26, 8, orange)
  local slots = { 44, 84, 124, 164 }
  for i = 1, 4 do
    local x = slots[i]
    local s = tostring(APP.ip_edit[i])
    if i == APP.ip_sel then
      rectfill(x, 68, x + 34, 102, dark_green)
      rect(x, 68, x + 34, 102, orange)
    end
    local col = (i == APP.ip_sel) and orange or light_gray
    print(s, x + 17 - #s * 4, 76, col, 0, 16)
  end
  print(".", 80, 78, dark_gray, 0, 16)
  print(".", 120, 78, dark_gray, 0, 16)
  print(".", 160, 78, dark_gray, 0, 16)
  draw_center("OCTET " .. APP.ip_sel .. "/4", 114, 8, white)
  draw_center("0.0.0.0 = AUTO", 136, 8, dark_gray)
  draw_center("TURN = SET", 168, 8, dark_gray)
  draw_center("PRESS NEXT   B CANCEL", 184, 8, dark_gray)
end

function APP.draw_mic()
  APP.draw_body()
  draw_center("MIC TEST", 26, 8, orange)
  local segs = 10
  local w = 16
  local gap = 3
  local x0 = 25
  local level = AUDIO.mic_level
  for i = 1, segs do
    local x = x0 + (i - 1) * (w + gap)
    local col = dark_green
    if i <= 6 then col = green elseif i <= 8 then col = yellow else col = red end
    if level * segs >= i then
      rectfill(x, 92, x + w, 114, col)
    else
      rect(x, 92, x + w, 114, dark_green)
    end
  end
  local peak = flr(clamp(AUDIO.mic_peak, 0, 1) * segs + 0.99)
  if peak >= 1 then
    local px = x0 + (peak - 1) * (w + gap)
    line(px, 88, px, 118, white)
  end
  draw_center(flr(level * 100) .. "%", 128, 16, white)
  local status, col = "SILENT", dark_gray
  if not AUDIO.mic_ok then
    status, col = "NO MIC MODULE", red
  elseif level > 0.02 then
    status, col = "SIGNAL OK", green
  elseif level > 0.005 then
    status, col = "TOO QUIET", yellow
  end
  draw_center(status, 156, 8, col)
  draw_center("SPEAK NOW", 178, 8, light_gray)
  draw_center("B BACK", 194, 8, dark_gray)
end

function APP.draw_net()
  APP.draw_body()
  draw_center("NETWORK", 26, 8, orange)
  local link = "DOWN"
  if NET.wifi_ready then link = "WIFI" elseif NET.own_ip ~= "0.0.0.0" then link = "LAN" end
  local lines = {
    "IP   " .. NET.own_ip,
    "PORT " .. tostring(NET.port),
    "LINK " .. link,
    "PEER " .. NET.peer_count(CFG.channel) .. "/4",
    "FIX  " .. (CFG.fixed_ip == "" and "AUTO" or CFG.fixed_ip),
    "CODEC " .. (AUDIO.opus_ok and "OPUS" or "PCM"),
    "JBUF " .. AUDIO.jbuf .. "F/" .. AUDIO.prebuffer * FRAME_MS .. "MS",
    "TX " .. NET.tx_packets .. "  RX " .. NET.rx_packets,
    "BUF " .. AUDIO.buffered() .. "B",
    "ERR " .. NET.tx_errors,
  }
  for i, s in ipairs(lines) do
    print(s, 40, 50 + (i - 1) * 16, light_gray, 0, 8)
  end
  draw_center("B BACK", 200, 8, dark_gray)
end

function APP.draw_toast(now)
  if now < APP.toast_until then
    local y = 44
    if APP.screen == "settings" then
      y = 168
    elseif APP.screen == "ip" then
      y = 150
    elseif APP.screen == "channel" then
      y = 162
    elseif APP.screen == "mic" then
      y = 164
    elseif APP.screen == "net" then
      y = 176
    end
    local w = text_w(APP.toast_text, 8) + 10
    rectfill(120 - w / 2, y, 120 + w / 2, y + 14, black)
    draw_center(APP.toast_text, y + 2, 8, yellow)
  end
end

function APP.draw(now)
  if APP.screen == "main" then
    APP.draw_main(now)
  elseif APP.screen == "settings" then
    APP.draw_settings()
  elseif APP.screen == "channel" then
    APP.draw_channel()
  elseif APP.screen == "ip" then
    APP.draw_ip()
  elseif APP.screen == "mic" then
    APP.draw_mic()
  elseif APP.screen == "net" then
    APP.draw_net()
  end
  APP.draw_toast(now)
end

function _draw()
  APP.draw(time())
end
