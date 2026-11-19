# MFlux Studio

MFlux Studio 是面向 Apple 芯片 Mac 的 [mflux](https://github.com/mflux-community/mflux) 中文图形界面。支持文生图、参考图编辑、遮罩局部编辑、高清放大、LoRA 和本地模型管理。推理以离线模式运行，预设模型通过界面按需下载。

## 构建

需要 Apple 芯片 Mac、macOS 14 或更高版本，以及包含 macOS 15 或更新 SDK 的 Xcode 或 Command Line Tools。

```sh
./build.sh
open 'build/MFlux Studio.app'
```

## 使用

应用使用 `~/.local/bin` 中的 mflux 命令。可以使用 [uv](https://docs.astral.sh/uv/) 安装本版本使用的 mflux。

```sh
UV_TOOL_BIN_DIR="$HOME/.local/bin" uv tool install 'mflux==0.24.0'
```

打开应用后，可从「预设模型」下载所需文件，或通过「导入本地」加入自己的模型。在默认构建目录运行时，模型库、模型和生成图片保存在应用旁边的 `build/` 下。
