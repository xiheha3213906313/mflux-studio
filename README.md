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

## 连接安卓版映序

在 MFlux Studio 主窗口打开「连接映序」，选择 Mac 的局域网 IPv4 地址并开启连接。允许 macOS 提示的本地网络访问，确认手机和 Mac 处在同一个可互访的子网。点击「生成配对信息」并复制到支持该接口的映序版本。每份配对信息五分钟内可使用一次，已配对设备可以在 Mac 上移除。

远程任务复用当前模型库、LoRA 库和离线推理进程。文生图、参考图编辑、局部编辑和高清放大的可用模型取决于 Mac 上已就绪的权重。关闭连接会暂停受理和启动新的远程任务，正在运行的任务可以完成。重新打开 MFlux Studio 后，在同一地址开启连接即可恢复队列。手机端适配方式见 [局域网 API v1](docs/FRAMESTUDIO-API.md)。
