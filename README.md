# Lemon串口监控（Lemon Serial Monitor）

[简体中文](README.md) | [English](README.en.md)

[![最新版本](https://img.shields.io/github/v/release/qingningmneg/LemonSerialMonitor?display_name=tag&sort=semver&label=release)](https://github.com/qingningmneg/LemonSerialMonitor/releases/latest) [![总下载量](https://img.shields.io/github/downloads/qingningmneg/LemonSerialMonitor/total?label=downloads)](https://github.com/qingningmneg/LemonSerialMonitor/releases) [![MIT 许可证](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE) [![Windows x64](https://img.shields.io/badge/Windows-x64-0078D4?logo=windows&logoColor=white)](#兼容目标系统)

我做这款免费开源的 Windows x64 串口监控工具，是想查看已经发生的通信，同时尽量不改变原软件的串口使用方式。它可用于 COM 端口抓包和串口嗅探：内核过滤驱动复制现有的读写事件，桌面程序本身不打开 COM 端口，因此原业务程序仍然是端口的实际使用者；WPF 界面、CLI 和 MCP 则分别用于人工查看、脚本接入和 AI 辅助调试。

当前版本为 `0.1.0`，采用 [MIT](LICENSE) 许可证。个人使用和商业使用，以及修改、再分发、再许可和销售均获允许；分发本软件的副本或实质性部分时，必须保留版权声明和许可证中的许可声明。

**[直接下载 `LemonSerialMonitor-Setup-x64.exe`](https://github.com/qingningmneg/LemonSerialMonitor/releases/latest/download/LemonSerialMonitor-Setup-x64.exe)**

下载后请先根据对应 Release 中的 `SHA256SUMS.txt` 核对安装包。

## 下载与安装

正式安装包发布在 GitHub 的 **Releases** 页面，文件名为：

```text
LemonSerialMonitor-Setup-x64.exe
```

安装时不需要打开 PowerShell：

1. 双击安装包。
2. 阅读并接受“本地测试证书使用说明”。
3. 选择桌面程序安装位置。
4. 点击“安装”，在 Windows 提示时允许管理员权限。
5. 如果安装程序提示重启，请先保存工作，再按提示重启；重启后再打开软件。

当前驱动使用本地测试证书，不是微软正式发布签名。安装程序会自动核对安装包、导入随包公钥证书，并在需要时启用 Windows `TESTSIGNING`。它不会关闭安全启动，也不会修改 BitLocker。安全启动处于开启状态时，安装会停止。

测试证书要等安装程序取得管理员权限后才能导入，因此第一次双击时，Windows 仍可能显示 SmartScreen 或“未知发布者”。0.1.0 的发布文件有本地测试签名，但没有微软信任链，也没有 RFC 3161 公共时间戳；请只从本项目 Release 下载并先核对 `SHA256SUMS.txt`。

0.1.0 不支持覆盖已有的新式安装。更新前先停止监控并备份数据，使用旧版本完整卸载，按提示重启后再安装新版。

完整说明见 [安装与卸载](docs/INSTALL.md)。

完整操作手册可直接查看或保存：[PDF 版](manual/Lemon串口监控-完整操作手册.pdf)、[Word 版](manual/Lemon串口监控-完整操作手册.docx)。

## 兼容目标系统

- Windows 10 x64
- Windows 11 x64
- Windows Server 2019 x64（桌面体验 / Server Core）
- Windows Server 2022 x64（桌面体验 / Server Core）
- Windows Server 2025 x64（桌面体验 / Server Core）

Server Core 不安装 WPF 桌面程序，只安装驱动、后台服务、AI/命令行接口和文档。x86、ARM64、未知 Windows Server 构建以及安全启动开启的环境会被安装程序拒绝。

0.1.0 当前代码候选已在 Windows 11 x64 实机完成图形安装、重启、服务冷启动、桌面连接、JSON CLI 和 MCP；候选验证链还完成了前一候选的完整卸载以及当前代码候选的干净安装。没有接入串口设备时，后台服务仍会保持运行；点击“刷新端口”后，端口列表为空、驱动显示暂不可用属于正常状态，接入真实设备后再刷新即可。

Windows Server 2022/2025 已在 GitHub 托管桌面 runner 完成平台识别、托管测试和安装契约检查，但没有装载内核驱动；Server Core 只有组件布局契约测试，Server 2019 自托管任务未执行。本次没有任何 Server 实机或虚拟机的驱动安装、重启、捕获、AI、卸载端到端验收，所以这些版本是兼容目标，不是已完成硬件认证。具体范围见 [0.1.0 发布说明](docs/RELEASE_NOTES_0.1.0.md)。

## 与常规串口终端/助手的区别

| 方面 | Lemon串口监控 | 常规串口终端/助手的典型方式 |
| --- | --- | --- |
| COM 端口关系 | 桌面界面不打开或取得被监控 COM 端口的所有权；内核过滤驱动复制已经发生的读写活动。 | 通常由工具直接打开 COM 端口并参与通信。 |
| 数据方向 | 只读监控，不主动发送、注入或重放数据。 | 通常可以主动发送数据。 |
| AI 辅助调试 | 通过受保护的本机 CLI/MCP 分页读取捕获事件，用于 AI 辅助软硬件调试。 | 是否提供本机自动化或分页接口取决于具体工具。 |

## 主要功能

- 不由桌面程序占用 COM 端口，监控一个或多个串口的 Read、Write 和配置控制事件。
- 列表、Dump、终端三种查看方式。
- 显示时间、进程、端口、方向、操作码、状态、长度、标志、HEX 和文本。
- HEX 与文本循环查找；HEX 支持 `??` 单字节通配符。
- 多行选择后可复制为空格 HEX、紧凑 HEX、文本、C 数组、Python `bytes`、TSV、CSV 或 JSON。
- `Ctrl+C` 使用当前复制格式；`Ctrl+Shift+C` 只复制连续的空格 HEX 数据。
- 会话自动写入受保护的本机数据库；停止后可导出 CSV、TXT 或 RAW。
- 本机 AI 接口支持状态、端口、开始/暂停/继续/停止、会话列表、分页读取、等待新事件、导出和协议描述。
- AI 接口提供标准 MCP stdio 服务，不开放 HTTP 端口，也不接受发送、注入、重放或任意文件访问。
- 图形化完整卸载；按受保护安装记录精确移除本软件文件、服务、驱动、过滤器、证书和数据。

## 三分钟开始监控

1. 打开原来使用串口的业务软件，让它正常连接设备。
2. 打开 Lemon串口监控，点击“刷新端口”。
3. 勾选要看的 COM 端口，填写一个会话文件名，例如 `board-test.db`。
4. 点击“开始”。
5. 让原业务软件真正发送或读取数据。
6. 在“列表”“Dump”“终端”之间切换查看。
7. 结束时先点击“停止”，再按需要复制或导出。

如果列表没有数据，先确认已经点了“开始”，并确认原业务软件在“开始”之后确实对同一个 COM 端口发生了读写。监控工具不会主动向设备发送数据。

没有连接串口设备时，刷新后看到“服务已连接”、端口列表为空、驱动暂不可用是正常现象，不表示后台服务启动失败。

完整界面说明见 [操作指南](docs/USER_GUIDE.md)，问题处理见 [故障排查](docs/TROUBLESHOOTING.md)。

## AI 接入

安装后的 AI 客户端默认位于：

```text
C:\Program Files\Lemon串口监控\ai\Lemon.SerialMonitor.AI.exe
```

如果安装时选择了其他位置，请使用实际路径。

命令行快速检查：

```powershell
& 'C:\Program Files\Lemon串口监控\ai\Lemon.SerialMonitor.AI.exe' status --json
& 'C:\Program Files\Lemon串口监控\ai\Lemon.SerialMonitor.AI.exe' ports --json
```

MCP 配置示例：

```json
{
  "mcpServers": {
    "lemon-serial-monitor": {
      "command": "C:\\Program Files\\Lemon串口监控\\ai\\Lemon.SerialMonitor.AI.exe",
      "args": ["mcp"]
    }
  }
}
```

详细接入步骤见 [AI 接入指南](docs/AI_INTEGRATION.md)，命令、工具、字段和完整性规则见 [AI 接口参考](docs/AI_API_REFERENCE.md)。

## 数据与卸载

会话和导出文件默认保存在受保护的 `%ProgramData%` 数据目录中。卸载程序会明确提示：**完整卸载会永久删除本软件产生的全部会话、导出、设置、日志和 AI 状态**。需要保留的数据必须先导出或备份。

可以从“设置 → 应用 → 已安装的应用 → Lemon串口监控 → 卸载”进入完整卸载。卸载程序会先关闭本软件桌面程序、AI 客户端和后台服务；只有 Windows 内核仍在使用驱动、启动策略需要恢复或文件仍被系统锁定时，才会安排重启后继续清理并再次核验残留。

## 从源码构建

仓库已经包含生成安装包所需的已验收 DOCX/PDF 手册。源码构建还需要 Visual Studio 2022、WDK、Spectre 库、.NET SDK、Pester 和 Inno Setup 6.7.3。构建、签名、测试与安装包命令见 [构建说明](docs/BUILD.md)。

安全边界和威胁模型见 [安全说明](docs/SECURITY.md)，版本变化见 [0.1.0 发布说明](docs/RELEASE_NOTES_0.1.0.md)。

## 开源许可证

Lemon串口监控由 `qingningmneg` 以 [MIT 许可证](LICENSE) 开源。MIT 允许个人使用和商业使用，也允许修改、再分发、再许可和销售；分发本软件的副本或实质性部分时，必须保留 `Copyright (c) 2026 qingningmneg` 和 MIT 许可声明。本软件按“原样”提供，不附带任何明示或默示担保；完整条款以 [LICENSE](LICENSE) 为准。

## 独立实现

本项目的代码、协议、会话格式、安装流程和界面均为独立实现，不包含其他串口软件的二进制、图标、商标、私有代码或素材。
