# clx-projects

面向 coloX / ColoPLAY 的卡带项目集合。每个子目录是一个独立项目，包含 `.clx` 入口、Lua 源码和资源文件。

## 项目

| 项目 | 平台 | 说明 |
| --- | --- | --- |
| [walkie-talkie](walkie-talkie/) | ColoPLAY（`coloX-16`） | 局域网对讲机：半双工 PTT、3 频道、UDP 自动发现、Opus/PCM 音频 |

## 目录结构

```text
clx-projects/
└── walkie-talkie/
    ├── walkie-talkie.clx   # 卡带入口
    ├── src/                # Lua 源码
    ├── assets/             # 图片、音频等资源
    ├── tools/              # 辅助脚本（测试 peer、发布构建）
    └── README.md           # 项目说明
```

## 开发

每个项目独立使用 clx-dev 工具链构建、运行和调试。进入项目目录后，按该项目的 `README.md` 操作。

构建产物写入各自项目的 `dist/`；模拟器截图、录音和调试文件不会提交到仓库。
