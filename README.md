# clx-projects

English | [简体中文](README.zh-CN.md)

A collection of cartridges for coloX / ColoPLAY. Each subdirectory is a standalone project containing a `.clx` entry, Lua sources, and assets.

## Projects

| Project | Platform | Description |
| --- | --- | --- |
| [walkie-talkie](walkie-talkie/) | ColoPLAY (`coloX-16`) | LAN walkie-talkie with half-duplex PTT, 3 channels, UDP auto-discovery, and Opus/PCM audio |

## Layout

```text
clx-projects/
└── walkie-talkie/
    ├── walkie-talkie.clx   # cartridge entry
    ├── src/                # Lua sources
    ├── assets/             # images, audio, and other assets
    ├── tools/              # helper scripts (test peer, release build)
    └── README.md           # project documentation
```

## Development

Each project uses the clx-dev toolchain independently. Enter a project directory and follow its `README.md` for build, run, and debug instructions.

Build outputs are written to each project's `dist/`. Simulator screenshots, recordings, and debug files are not committed.
