# Lemon串口监控构建说明

本文面向需要从源码构建、测试和生成安装包的开发者。普通使用者请直接下载 Release 安装包。

## 开发机要求

- Windows x64
- Visual Studio 2022
- MSVC x64 C++ 工具
- Visual Studio WDK 组件和 WDK 10.0.26100
- 对应工具集的 Spectre 缓解库
- `global.json` 指定的 .NET SDK 10.0.301（项目目标为 .NET 8）
- PowerShell 5.1 或更高版本
- Pester 4.10.1
- 官方 Inno Setup 6.7.3

安装 Inno Setup：

```powershell
winget install --id JRSoftware.InnoSetup --version 6.7.3 --exact
```

## 只运行托管测试

```powershell
dotnet restore .\CommMonitor.sln
dotnet test .\CommMonitor.sln --configuration Release --no-restore --nologo
```

## 运行安装安全测试

```powershell
Import-Module Pester
Invoke-Pester -Path .\tests\powershell -Output Detailed
```

## 构建完整载荷

不签名的开发构建：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Build-All.ps1 `
  -Configuration Release
```

生成可用于本机测试签名安装包的载荷：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Build-All.ps1 `
  -Configuration Release `
  -TestSignDriver
```

该命令会：

- 恢复依赖并运行全部托管测试
- 运行全部 Pester 安装/卸载安全测试
- 发布 x64 自包含桌面、服务、AI 和卸载助手
- 构建 x64 Release KMDF 驱动并运行代码分析
- 生成 CAT、创建或复用当前用户不可导出的测试签名证书
- 签名驱动、目录、桌面程序、服务、AI 客户端和卸载助手
- 组装 `artifacts\phase1`
- 生成严格的 `SHA256SUMS.txt`

## 生成单文件图形安装包

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Build-Installer.ps1 `
  -Configuration Release
```

默认会先调用完整载荷构建。已有经过验证的载荷时可以使用 `-SkipPayloadBuild`；只有明确要保留未签名安装器用于调试时才使用 `-SkipSigning`。

输出：

```text
artifacts\installer\Lemon串口监控-安装程序-x64.exe
artifacts\release\0.1.0\
```

`artifacts\release\0.1.0` 只包含五个可以公开上传的文件：安装程序、PDF 操作手册、发布说明、构建信息和 SHA-256 清单。构建脚本会核对 Inno Setup 精确版本和官方 Authenticode 发布者，不接受未知编译器替代品；还会签名安装程序并在组装后重新核对五个文件、版本资源、签名证书和全部哈希。

安装向导使用项目内固定版本的简体中文翻译文件。来源、提交号、SHA-256 和 MIT 许可证分别记录在 `installer\third-party\SOURCE.md` 与同目录许可证文件中。

已有发布目录时，可以再次独立验证：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Test-ReleaseBundle.ps1 `
  -Version 0.1.0
```

验证成功时会输出 `Status: Verified`、安装程序 SHA-256、签名证书指纹和文件数量；目录多出、缺少或被修改任何文件都会失败。

## 构建操作手册

仓库的 `manual` 目录已经包含通过逐页检查的 DOCX 和 PDF，普通源码构建会直接使用这两个文件，不需要先安装 Python 或 LibreOffice。

只有修改手册生成脚本或手册内容时，才需要重新生成。先安装 Python 3.12、LibreOffice 26.2.4，再建立独立环境并安装锁定版本：

```powershell
py -3.12 -m venv .\.venv-docs
& .\.venv-docs\Scripts\python.exe -m pip install `
  -r .\scripts\docs\requirements.txt
& .\.venv-docs\Scripts\python.exe `
  .\scripts\docs\build_commmonitor_manual.py
```

把 DOCX 转成 PDF，再渲染全部页面：

```powershell
& "$env:ProgramFiles\LibreOffice\program\soffice.exe" `
  --headless --convert-to pdf `
  --outdir .\artifacts\manual `
  .\artifacts\manual\Lemon串口监控-完整操作手册.docx

& .\.venv-docs\Scripts\python.exe `
  .\scripts\docs\render_pdf_pages.py `
  .\artifacts\manual\Lemon串口监控-完整操作手册.pdf `
  --output-dir .\tmp\manual-render
```

必须逐页检查无缺字、重叠、断表和乱码。确认无误后，再用新生成的 DOCX/PDF 替换仓库 `manual` 目录中的同名文件，并重新运行全部测试和安装包构建。

## 最终检查

```powershell
git diff --check
dotnet test .\CommMonitor.sln --configuration Release --no-restore --nologo
Invoke-Pester -Path .\tests\powershell -Output Detailed
```

还应检查：

- 安装包 SHA-256
- EXE/SYS/CAT 签名器指纹一致
- 载荷清单没有缺文件、多文件或路径逃逸
- Git 公开文件不含证书私钥、令牌、用户路径、日志或会话数据
- Windows 10/11 与 Server 平台矩阵测试
- 安装、重启、真实串口监控、AI 读取、完整卸载和残留核验记录

不要把“编译成功”当成“安装包可发布”。内核驱动版本必须有真实系统门禁和可恢复卸载证据。
