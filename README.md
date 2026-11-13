# ESP32 诊断工具

> 插上板子点一下，用芯片自己的启动日志判断它为什么刷不进程序。

![界面](docs/screenshot.png)

## 它解决什么问题

Arduino IDE 刷写失败时，你通常只能看到一句：

```
A fatal error occurred: Failed to connect to Espressif device: No serial data received.
```

这句话背后至少有四种**完全不同**的物理原因：

1. 芯片根本没进刷机模式（BOOT 键或 IO0 信号线断了）
2. 芯片进了刷机模式，但电脑发过去的数据它收不到（接收线断了）
3. 芯片在反复掉电重启（USB 供电不足）
4. USB 转串口芯片（CP2102/CH340）本身坏了

这四种原因的维修方式完全不同，但上电、拔插、按按钮都试不出来。这个工具用**芯片自己的启动日志**把它们分开。

## 诊断原理

ESP32 每次复位都会在 115200 波特率输出一行自述：

```
rst:0x1 (POWERON_RESET),boot:0x13 (SPI_FAST_FLASH_BOOT)
```

这一行同时编码了三件事：

| 字段 | 含义 |
|---|---|
| `rst:0x?` | 复位原因（上电 / 软件 / 看门狗 / 电压跌落） |
| `boot:0x?` | 启动方式，即**复位那一瞬间 IO0 的电平** |
| 后续输出 | Flash 是否被正常读取、有没有崩溃回溯 |

工具据此做三件事：

1. 让 esptool 按标准时序尝试握手
2. **对 DTR/RTS 四组组合各断言一次，每组抓 900 毫秒原始字节**——不预设你的板子复位线怎么接的，撞也能撞对一次
3. 解析 `rst:` / `boot:` 并给出一句人话结论

## 判据表

| 芯片说了什么 | 含义 | 结论 |
|---|---|---|
| 正常握手应答 | 一切正常 | 可以直接刷写 |
| `boot:0x03` 或 `waiting for download` | 停在等电脑发程序 | 芯片愿意收，**电脑发不进去**，接收通路坏了 |
| `boot:0x13` | 每次都正常启动 | **IO0 没被拉低**，BOOT 键或信号线断了 |
| `rst:0x13` | 电压跌落复位 | **供电不足**，换 USB 口或换线 |
| `Guru Meditation` | 崩溃回溯 | 固件崩了，不是刷写问题 |
| 一个字节都没有 | 完全静默 | 芯片没运行，或发送脚断了 |

## 使用

### 方式一：exe

下载 `ESP32诊断工具.exe` 双击运行。

### 方式二：直接跑脚本

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\ESP32Diag.ps1
```

### 依赖

需要 `esptool.exe`。工具会自动在以下位置查找：

```
%LOCALAPPDATA%\Arduino15\packages\esp32\tools\esptool_py\*\esptool.exe
%APPDATA%\Arduino15\packages\esp32\tools\esptool_py\*\esptool.exe
<本程序同目录>\esptool.exe
```

装了 Arduino IDE 的 ESP32 开发板支持包就会自动找到；没有的话把 `esptool.exe` 放到程序同目录即可。

## 构建 exe

```powershell
.\build.ps1
```

内部使用 [ps2exe](https://github.com/MScholtes/PS2EXE)：

```powershell
Install-Module ps2exe -Scope CurrentUser
```

## 自测

工具内置两个无界面自测模式，改完代码可以跑：

```powershell
# 启动日志解析器回归（5 组合成样本）
powershell -File .\ESP32Diag.ps1 --parsetest

# 界面渲染成图片，用于检查布局
powershell -File .\ESP32Diag.ps1 --uitest
powershell -File .\ESP32Diag.ps1 --uitest --bigfont   # 模拟高 DPI
```

`--uitest` 会把界面渲染到 `%TEMP%\esp32diag_render.png`。这是排查布局问题的有效手段——RichTextBox 在 `DrawToBitmap` 下不渲染，所以文本内容另用 `TextLength` 校验。

## 已知限制

- **只在 Windows + PowerShell 5.1 下验证过**，未测试 Windows 7
- 四组 DTR/RTS 组合针对经典 ESP32（WROOM/WROVER）的自动下载电路；ESP32-S3/C3 的 strapping 行为不同，判据表不完全适用
- 烧录功能固定写入地址 `0x10000`（Arduino 应用固件的默认地址），不是完整的 bootloader + 分区表烧录方案
- exe 由 ps2exe 打包，无代码签名，可能被杀软误报。介意的话直接跑 `.ps1`

## 许可证

未指定。如需使用请自行判断。
