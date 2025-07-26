<p align="center">
    <a href="https://zune.com"><img height="296px" src="https://raw.githubusercontent.com/Scythe-Technology/zune-docs/master/public/logo-dark.svg" alt="Zoooooom"/></a>
</p>
<div align="center">
    <a href="https://github.com/Scythe-Technology/Zune/releases" target="_blank"><img src="https://img.shields.io/badge/x64,_arm64-Linux?style=flat-square&logo=linux&logoColor=white&label=Linux&color=orange"/>
    <img src="https://img.shields.io/badge/x64,_arm64-macOs?style=flat-square&logo=apple&label=macOs&color=white"/>
    <img src="https://img.shields.io/badge/x64,_arm64-windows?style=flat-square&label=Windows&color=blue"/></a>
</div>

<br/>

<p align="center">
A <a href="https://luau.org/">Luau</a> runtime, similar to <a href="https://lune-org.github.io/docs">Lune</a>, <a href="https://nodejs.org">Node</a>, or <a href="https://bun.sh">Bun</a>.
</p>

## Features
- **Comprehensive API**: Includes fully featured APIs for filesystem operations, networking, and standard I/O.
- **Rich Standard Library**: A rich standard library with utilities for basic needs, reducing the need for external dependencies.
- **Cross-Platform Compatibility**: Fully compatible with **Linux**, **macOS**, and **Windows**, ensuring broad usability across different operating systems.
- **High Performance**: Built with Zig, designed for high performance and low memory usage.

## Building

Requirements:
- [zig](https://ziglang.org/).

Steps:
1. Clone the repository:
```sh
git clone https://github.com/Scythe-Technology/zune.git
cd zune
```
2. Compile
```sh
zig build -Doptimize=ReleaseFast
```
3. Execute
```sh
./zig-out/bin/zune --version
```

# Roadmap
For more information on the future of zune, check out the milestones


# Contributing
Read [CONTRIBUTING.md](https://github.com/Scythe-Technology/zune/blob/master/CONTRIBUTING.md).
