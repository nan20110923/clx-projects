# walkie-talkie

面向 ColoPLAY（`coloX-16`）的局域网对讲机卡带。两台或多台运行同一 ROM 的设备连接到同一个 WiFi / LAN、切到同一频道后，按住中间旋钮即可通话。

## 功能

- 半双工 PTT：按住 `CENTER` 讲话，松开收听。
- 3 个频道：旋钮左 / 右切换，频道和固定 IP 会持久化。
- 自动发现：UDP 广播 + 单播回复，同频最多显示 4 台设备。
- 音频：优先 Opus（16 kHz、20 ms 帧、24 kbps），固件或对端不支持时自动回退到 16-bit PCM（640 字节/帧）。
- 自适应抖动缓冲：按本次通话观测到的最大包间隔动态扩容（3–20 帧，60–400 ms），链路变好后自动回收延迟；`NETWORK` 页 `JBUF` 行实时显示当前档位。
- 忙音 / 信道占用提示；双方几乎同时按下 PTT 时，节点 ID 较小的一方优先。
- `A` 发送呼叫音；`B` 打开设置；支持固定对端 IP 兜底。
- 自动呼号 `WT-XXXX`，首次生成后保存在 cartdata 中。

## 操作

| 操作 | 功能 |
| --- | --- |
| 按住 `CENTER` | 讲话（松开后停止发送） |
| 旋钮左 / 右 | 切换频道 1 / 2 / 3 |
| `A` | 向同频道设备发送呼叫音 |
| `B` | 打开设置 |

设置页：

| 项目 | 说明 |
| --- | --- |
| `CHANNEL` | 选择频道，`CENTER` 确认 |
| `FIXED` | 固定对端 IP；`AUTO` 表示使用广播自动发现 |
| `MIC TEST` | 麦克风电平测试，`B` 返回 |
| `NETWORK` | 查看本机 IP、端口、连接状态、同频 peer 数、TX/RX、缓冲和错误计数 |
| `BACK` | 返回主界面 |

主界面顶部圆点：红色 = 网络错误，橙色 = 有 IP 但同频道没有 peer，绿色 = 至少发现一个 peer。底部显示本机 IP。

## 两台设备使用

1. 两台 ColoPLAY 连接同一个 WiFi / LAN。避免“访客网络”或开启了 AP 隔离的网络。
2. 两台设备运行同一个 `dist/walkie-talkie.rom`（协议版本 2，旧 ROM 不兼容）。
3. 启动后确认呼号不同（例如 `WT-4689`、`WT-2A1C`），并用旋钮切到同一频道。
4. 按住 `CENTER` 说话；对方应显示绿色 PTT 环、`RECEIVING` 和发送方呼号。
5. 如果 10 秒内没有发现对方：
   - 检查两台设备是否在同一频道；
   - 检查 WiFi 是否允许设备互访；
   - 在设置 → `NETWORK` 查看对方 IP；
   - 在设置 → `FIXED` 输入对方 IP，保存后再试。

固定 IP 是广播被禁止时的兜底方案。若对方 `NETWORK` 页显示的端口不是 `47654`（例如 `47655`），说明默认端口被占用；此时固定 IP 仍会先尝试 `47654`，建议先排查端口占用，或让双方都使用默认端口。

> 同一频道最多显示 4 台设备。没有加密，仅适合可信局域网。

## 构建与模拟器

开发时在项目根目录执行：

```sh
node .agents/skills/clx-dev/scripts/clx.mjs build
node .agents/skills/clx-dev/scripts/clx.mjs run
node .agents/skills/clx-dev/scripts/clx.mjs stop
```

发布 ROM 用：

```sh
node tools/build-release.mjs
```

发布构建会检查 `src/util.lua` 里的 `DEBUG = false`，拒绝 `dlog()` 之外的直接 `printh()` 调用，并在临时源码副本中删除所有 `dlog(...)` 行后再编译，所以发布 ROM 不会带调试字符串。

- ROM 输出：`dist/walkie-talkie.rom`
- 模拟器调试通道：`127.0.0.1:3563`
- 截图：`node .agents/skills/clx-dev/scripts/clx.mjs shot`
- 注入按键：`node .agents/skills/clx-dev/scripts/clx.mjs debug --cmd "btn CENTER"`，释放用 `btn 0`

调试日志统一走 `src/util.lua` 的 `dlog()`：把 `DEBUG` 临时改成 `true` 后，日志通过 `printh()` 输出到模拟器/串口控制台。注意 `print()` 是屏幕文字绘制函数，不要拿它当日志用。

模拟器麦克风需要 macOS 给 `coloXtool` 麦克风权限。未授权时采集到的是静音（Opus 静音包或 PCM 全 0），界面会显示 `MIC SILENT`，这是预期现象，不代表 ROM 故障。发送链路的网络包仍可正常验证。

## Node 测试 peer

`tools/lan-peer.mjs` 可以模拟第二台设备，用于在没有第二台 ColoPLAY 时验证发现、收音频、发音频和呼叫音。

```sh
# 只监听并显示发现的设备
node tools/lan-peer.mjs --target 127.0.0.1:47654

# 发送 3 秒 440 Hz 测试音
node tools/lan-peer.mjs --target 127.0.0.1:47654 --tone --duration 3000

# 接收设备发来的音频并保存为 WAV
node tools/lan-peer.mjs --target 127.0.0.1:47654 --tone --record --out tools/out.wav

# 发送 16 kHz / 单声道 / 16-bit WAV
node tools/lan-peer.mjs --target 127.0.0.1:47654 --wav-in voice.wav

# 被动模式 + 忽略回环 announce：验证设备是否真的发出广播
node tools/lan-peer.mjs --passive --no-loopback --target 127.0.0.1:47654 --listen 10000
```

常用参数：

| 参数 | 说明 |
| --- | --- |
| `--target IP:PORT` | 设备地址，默认 `127.0.0.1:47654` |
| `--bind IP` | Node 监听地址，默认 `0.0.0.0` |
| `--port PORT` | Node 监听端口，默认 `47655` |
| `--id N` | 节点 ID，默认 `0x7e57`；可用于测试同时 PTT 的 ID 仲裁 |
| `--channel N` | 频道，默认 `1` |
| `--tone --duration MS` | 发送测试音 |
| `--burst MS` | 把每 20ms 一帧改为每 MS 毫秒成批发送（模拟省电 WiFi 的批量投递，测试抖动缓冲） |
| `--tone-delay MS` | 发现设备后延迟多久开始发送测试音，默认 `800` |
| `--record --out FILE` | 记录收到的音频为 WAV |
| `--wav-in FILE` | 发送 WAV 文件 |
| `--passive` | 不主动 announce，收到设备 announce 后才开始 |
| `--no-loopback` | 忽略来自 `127.0.0.1` 的 announce（仅用于广播测试） |

`--passive --no-loopback` 能成功发现设备，说明设备确实通过局域网广播发出了 announce，而不是只靠本机回环。

> 测试 peer 只发送 PCM，并且 announce 不声明 Opus。设备发现它之后会自动改用 PCM，因此可以直接抓包或录 WAV；`NETWORK` 页此时显示 `CODEC PCM` 属正常现象。

## 协议

- 传输：UDP。
- 端口：基端口 `47654`，绑定失败时依次尝试 `47654..47663`。
- 发现：每 2 秒向 `255.255.255.255`、子网广播地址和 `127.0.0.1` 的 `47654..47663` 发送 announce；新 peer 会收到单播回复；音频单播到 peer 的源 IP / 端口。
- 包头 9 字节，小端：

```text
"WT" | version(1) | type(1) | channel(1) | id(u16) | seq(u16)
```

| type | 含义 | 负载 |
| --- | --- | --- |
| 1 | announce | 1 字节 flags（bit0 = talking，bit1 = 已设置固定 IP，bit2 = 支持 Opus） |
| 2 | audio | 1 字节 codec（0 = PCM，1 = Opus）+ 音频数据；PCM 固定 640 字节（20 ms），Opus 为 `[u16 大端长度][Opus 包]` |
| 3 | voice | 1 字节（1 = 开始，0 = 停止） |
| 4 | call | 无 |
| 5 | bye | 无 |

协议版本为 2（包头 `version` 字节）。音频默认使用 Opus；当固件不支持 Opus、或同频道有对端未在 announce 中声明 Opus 时，整条链路自动回退到 PCM，保证兼容。

半双工逻辑：收到音频或 voice-start 时本地 PTT 进入 busy；双方几乎同时开始时，节点 ID 较小者继续发送，较大者停止并转为接收。

## 文件

```text
walkie-talkie.clx   卡带头 + #include
src/util.lua        常量、IP 工具、种子、音调合成
src/net.lua         UDP 发现 / 传输、peer 表、协议
src/audio.lua       麦克风采集、Opus/PCM 编解码、抖动缓冲、提示音
src/main.lua        状态机、输入、设置页、UI 绘制、PTT 仲裁
tools/lan-peer.mjs  Node 测试 peer
dist/               构建产物（gitignored）
walkie_talkie.rec   cartdata：ID / 频道 / 固定 IP（gitignored）
```

## 故障排查

- **主界面顶部红点 / `NET ERROR`**：UDP 端口绑定失败。检查 `NETWORK` 页的错误计数和端口；关闭占用 `47654..47663` 的程序。
- **橙色点、一直 `SEARCHING`**：本机有 IP，但同频道没有 peer。确认频道相同、WiFi 允许互访、没有 AP 隔离；必要时使用 `FIXED` 固定 IP。
- **有 peer 但按 PTT 显示 `NO PEER`**：peer 刚刚掉线或切了频道；等待下一次 announce（约 2 秒）。
- **`MIC SILENT`**：模拟器未授权麦克风，或真机麦克风增益过低。先在设置 → `MIC TEST` 查看电平；真机可在系统设置中调整麦克风增益。
- **`NETWORK` 页显示 `CODEC PCM`**：本机固件不支持 Opus，或同频道还有不支持 Opus 的对端（例如 `tools/lan-peer.mjs`）。链路会自动回退到 PCM，功能正常。
- **升级后互相发现不到 / 没有声音**：确认两台设备都刷入同一版 ROM。协议版本已升到 2，旧 ROM 的包会被直接丢弃。
- **声音卡顿 / 断断续续**：抖动缓冲会按观测到的网络抖动自动扩容（最多 400 ms）。如果 `NETWORK` 页 `JBUF` 长期顶在 `20F/400MS` 且仍然卡顿，说明包间隔超过 400 ms——通常是 WiFi 省电（DTIM）或信道严重拥塞；靠近路由器、换信道，或关闭路由器的省电/组播转单播相关设置。`CODEC PCM` 表示链路回退到了 PCM（约 10 倍带宽），也会加剧卡顿。
- **双方同时按 PTT**：ID 小的一方继续说，ID 大的一方会看到 `CHANNEL BUSY` 并转为接收。这是确定性的仲裁结果，不是故障。
- **两台设备呼号相同**：删除本机的 `walkie_talkie.rec` 后重新启动，让两台设备分别用各自的 MAC / IP 重新生成 ID。不要在两台设备之间复制这个文件。
- **ESP32-S3 上 `net_getinf()` 不可用**：ROM 会自动回退到 `$wifi.ip` 获取本机地址；`NETWORK` 页显示的是实际使用的地址。
