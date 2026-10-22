-- UDP discovery and audio transport.
-- All packets are little-endian: "WT", version, type, channel, node id, seq, payload.

NET = {
  enabled = false,
  sock = nil,
  err = nil,
  port = 0,
  id = 0,
  channel = 1,
  fixed_ip = "",
  peers = {},
  replied = {},
  announce_ports = {},
  own_ip = "0.0.0.0",
  mask = "255.255.255.0",
  broadcast = nil,
  wifi_ready = false,
  wifi_ssid = "",
  wifi_rssi = 0,
  last_announce = -99,
  last_ip_check = -99,
  last_expire = -99,
  ann_seq = 0,
  audio_seq = 0,
  tx_packets = 0,
  rx_packets = 0,
  tx_errors = 0,
  local_talking = false,
  opus_ok = false,
  on_audio = function(peer, seq, data, codec) end,
  on_voice = function(peer, state) end,
  on_call = function(peer) end,
}

function NET.pack(ptype, seq)
  return string.pack(HEADER_FMT, PROTO_MAGIC, PROTO_VER, ptype, NET.channel, NET.id, seq % 65536)
end

function NET.init(id, channel, fixed_ip)
  NET.id = flr(id) % 65536
  NET.channel = flr(channel)
  NET.fixed_ip = fixed_ip or ""
  NET.announce_ports = {}
  for i = 0, PORT_TRIES - 1 do
    NET.announce_ports[#NET.announce_ports + 1] = PORT_BASE + i
  end

  local ok, res = pcall(function() return usemod('net') end)
  NET.enabled = ok and res == true
  if not NET.enabled then
    NET.err = "net module unavailable"
    return false
  end

  for i = 0, PORT_TRIES - 1 do
    local p = PORT_BASE + i
    local s, e = net_bind("mcast", "0.0.0.0", p)
    if not s then
      s, e = net_bind("udp", "0.0.0.0", p)
    end
    if not s then
      s, e = net_bind("udp", nil, p)
    end
    if s then
      NET.sock = s
      NET.port = p
      break
    end
    NET.err = tostring(e)
  end
  if not NET.sock then
    NET.enabled = false
    NET.err = NET.err or "bind failed"
    return false
  end

  NET.refresh_ip()
  dlog("net: id=%04X port=%d ch=%d ip=%s", NET.id, NET.port, NET.channel, NET.own_ip)
  NET.announce()
  return true
end

function NET.refresh_ip()
  local ip, mask = nil, nil
  local ok, inf = pcall(function() return net_getinf() end)
  if ok and inf then
    local fallback = nil
    for _, i in ipairs(inf) do
      if i.family == "inet" and i.addr and i.addr ~= "127.0.0.1" then
        if not fallback then fallback = i end
        local a = tonumber(string.match(i.addr, "^(%d+)%.") or "0")
        if a == 10 or a == 192 then
          fallback = i
          break
        elseif a == 172 then
          local b = tonumber(string.match(i.addr, "^%d+%.(%d+)%.") or "0")
          if b >= 16 and b <= 31 then
            fallback = i
            break
          end
        end
      end
    end
    if fallback then
      ip = fallback.addr
      mask = fallback.mask
    end
  end
  -- ESP32-S3 does not implement net_getinf(), but the ColoPLAY service does
  -- expose the current station address.
  if not ip then
    local okw, wip = pcall(function() return svcget('$wifi.ip') end)
    if okw and type(wip) == "string" then
      local host = string.match(wip, "^([%d%.]+)")
      if host and valid_ip(host) then
        ip = host
        mask = "255.255.255.0"
      end
    end
  end
  if ip then
    NET.own_ip = ip
    if mask then NET.mask = mask end
  end
  local n = ip_to_int(NET.own_ip)
  local m = ip_to_int(NET.mask)
  if n and m and NET.own_ip ~= "0.0.0.0" then
    NET.broadcast = int_to_ip(n + (4294967295 - m))
  end
  local ok2, ready = pcall(function() return svcget('$wifi.ready') end)
  NET.wifi_ready = ok2 and ready == true
  local ok3, ssid = pcall(function() return svcget('$wifi.ssid') end)
  if ok3 and type(ssid) == "string" then NET.wifi_ssid = ssid end
  local ok4, rssi = pcall(function() return svcget('$wifi.rssi') end)
  if ok4 and type(rssi) == "number" then NET.wifi_rssi = rssi end
  NET.last_ip_check = time()
end

function NET.send_to(ip, port, data)
  if not NET.sock or not ip or ip == "" or port <= 0 then return false end
  if port == NET.port and (ip == NET.own_ip or ip == "127.0.0.1") then return false end
  local ok, sent = pcall(function() return NET.sock:sendto(data, ip, port) end)
  if not ok or type(sent) ~= "number" or sent <= 0 then
    NET.tx_errors = NET.tx_errors + 1
    return false
  end
  return true
end

function NET.announce_flags()
  local flags = 0
  if NET.local_talking then flags = flags + 1 end
  if not is_zero_ip(NET.fixed_ip) then flags = flags + 2 end
  if NET.opus_ok then flags = flags + 4 end
  return flags
end

function NET.announce()
  if not NET.enabled then return end
  NET.ann_seq = (NET.ann_seq + 1) % 65536
  local pkt = NET.pack(PKT_ANNOUNCE, NET.ann_seq) .. string.char(NET.announce_flags())

  for _, p in ipairs(NET.announce_ports) do
    NET.send_to("255.255.255.255", p, pkt)
    if NET.broadcast and NET.broadcast ~= "255.255.255.255" then
      NET.send_to(NET.broadcast, p, pkt)
    end
    NET.send_to("127.0.0.1", p, pkt)
  end
  if not is_zero_ip(NET.fixed_ip) then
    NET.send_to(NET.fixed_ip, PORT_BASE, pkt)
  end
  for _, peer in pairs(NET.peers) do
    NET.send_to(peer.ip, peer.port, pkt)
  end
  NET.last_announce = time()
end

function NET.update(now)
  if not NET.enabled then return end

  if now - NET.last_ip_check > 10 then NET.refresh_ip() end
  if now - NET.last_announce > 2 then NET.announce() end

  for _ = 1, 32 do
    local data, addr, port = NET.sock:recvfrom(2048)
    if not data then break end
    NET.rx_packets = NET.rx_packets + 1
    NET.handle(data, addr, port, now)
  end

  if now - NET.last_expire > 1 then
    NET.last_expire = now
    local drop = nil
    for id, p in pairs(NET.peers) do
      if now - p.last_seen > PEER_TIMEOUT then
        drop = drop or {}
        drop[#drop + 1] = id
      elseif p.talking and now - (p.last_audio or 0) > TALK_TIMEOUT then
        p.talking = false
      end
    end
    if drop then
      for _, id in ipairs(drop) do
        NET.peers[id] = nil
        NET.replied[id] = nil
      end
    end
  end
end

function NET.handle(data, addr, port, now)
  if #data < 9 then return end
  local magic, ver, ptype, ch, id, seq, pos = string.unpack(HEADER_FMT, data)
  if magic ~= PROTO_MAGIC or ver ~= PROTO_VER then return end
  if id == NET.id then return end

  local p = NET.peers[id]
  local is_new = false
  if not p then
    is_new = true
    p = {
      id = id,
      callsign = full_id(id),
      short = short_id(id),
      ip = addr,
      port = port,
      channel = ch,
      last_seen = now,
      last_audio = 0,
      talking = false,
    }
    NET.peers[id] = p
  end
  p.ip = addr
  p.port = port
  p.channel = ch
  p.last_seen = now
  p.callsign = full_id(id)
  p.short = short_id(id)

  if ptype == PKT_ANNOUNCE then
    local flags = string.byte(data, pos) or 0
    p.talking = ((flags & 1) ~= 0) or (p.talking and (now - (p.last_audio or 0) < TALK_TIMEOUT))
    p.fixed = ((flags & 2) ~= 0)
    local was_opus = p.opus
    p.opus = ((flags & 4) ~= 0)
    if is_new or was_opus ~= p.opus then
      dlog("peer %s ch=%d opus=%s ip=%s:%d", p.short, ch, tostring(p.opus), addr, port)
    end
    if not NET.replied[id] then
      NET.replied[id] = true
      local pkt = NET.pack(PKT_ANNOUNCE, NET.ann_seq) .. string.char(NET.announce_flags())
      NET.send_to(addr, port, pkt)
    end
  elseif ch ~= NET.channel then
    return
  elseif ptype == PKT_AUDIO then
    local codec = string.byte(data, pos) or CODEC_PCM
    p.talking = true
    p.last_audio = now
    NET.on_audio(p, seq, string.sub(data, pos + 1), codec)
  elseif ptype == PKT_VOICE then
    local state = string.byte(data, pos) or 0
    p.talking = (state == 1)
    p.last_audio = now
    NET.on_voice(p, state)
  elseif ptype == PKT_CALL then
    NET.on_call(p)
  elseif ptype == PKT_BYE then
    NET.peers[id] = nil
    NET.replied[id] = nil
  end
end

function NET.targets()
  local list = {}
  local seen = {}
  local fixed_seen = false
  for _, p in pairs(NET.peers) do
    if p.channel == NET.channel and time() - p.last_seen <= PEER_TIMEOUT then
      if p.ip == NET.fixed_ip then fixed_seen = true end
      local key = p.ip .. ":" .. p.port
      if not seen[key] then
        seen[key] = true
        list[#list + 1] = { ip = p.ip, port = p.port }
      end
    end
  end
  if not is_zero_ip(NET.fixed_ip) and not fixed_seen then
    local key = NET.fixed_ip .. ":" .. PORT_BASE
    if not seen[key] then
      list[#list + 1] = { ip = NET.fixed_ip, port = PORT_BASE }
    end
  end
  return list
end

function NET.has_targets()
  return #NET.targets() > 0
end

-- True only when every peer on this channel announced Opus support. A fixed-IP
-- target without a peer entry keeps the link on PCM, which always decodes.
function NET.peers_support_opus()
  local any = false
  for _, p in pairs(NET.peers) do
    if p.channel == NET.channel and time() - p.last_seen <= PEER_TIMEOUT then
      any = true
      if not p.opus then return false end
    end
  end
  return any
end

function NET.send_audio(data, codec)
  if not NET.enabled or not data or #data == 0 then return end
  local targets = NET.targets()
  if #targets == 0 then return end
  NET.audio_seq = (NET.audio_seq + 1) % 65536
  local pkt = NET.pack(PKT_AUDIO, NET.audio_seq) .. string.char(codec or CODEC_PCM) .. data
  for _, t in ipairs(targets) do
    if NET.send_to(t.ip, t.port, pkt) then
      NET.tx_packets = NET.tx_packets + 1
    end
  end
end

function NET.send_voice(state)
  NET.local_talking = (state == 1)
  if not NET.enabled then return end
  local targets = NET.targets()
  if #targets == 0 then return end
  local pkt = NET.pack(PKT_VOICE, NET.ann_seq) .. string.char(state == 1 and 1 or 0)
  for _, t in ipairs(targets) do NET.send_to(t.ip, t.port, pkt) end
end

function NET.send_call()
  if not NET.enabled then return false end
  local targets = NET.targets()
  if #targets == 0 then return false end
  local pkt = NET.pack(PKT_CALL, NET.ann_seq)
  for _, t in ipairs(targets) do NET.send_to(t.ip, t.port, pkt) end
  return true
end

function NET.send_bye()
  if not NET.enabled then return end
  local pkt = NET.pack(PKT_BYE, NET.ann_seq)
  for _, t in ipairs(NET.targets()) do NET.send_to(t.ip, t.port, pkt) end
end

function NET.set_channel(ch)
  NET.channel = ch
  NET.announce()
end

function NET.set_fixed_ip(ip)
  NET.fixed_ip = ip or ""
  NET.announce()
end

function NET.get_peers(channel)
  local list = {}
  local now = time()
  for _, p in pairs(NET.peers) do
    if p.channel == channel and now - p.last_seen <= PEER_TIMEOUT then
      list[#list + 1] = p
    end
  end
  table.sort(list, function(a, b) return a.id < b.id end)
  return list
end

function NET.peer_count(channel)
  return #NET.get_peers(channel)
end
