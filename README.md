# HostEditor

使用 Swift / AppKit 开发的 Apple Silicon macOS 原生 hosts 编辑器，不依赖 Web 技术栈。产品范围与验收依据见 [需求文档](docs/需求文档.md)，代理协作约定见 [AGENTS.md](AGENTS.md)。

## 功能概览

- 读取、编辑并校验 `/etc/hosts`，也支持切换到本地自定义 hosts 文件。
- 提供行号、语法高亮、原生查找、撤销与重做，保留原始注释、空白和换行格式。
- 保存前检测外部修改并自动备份；受保护文件通过 macOS 管理员认证执行受限写入。
- 支持深色、浅色和跟随系统主题，以及菜单栏常驻图标与 Dock 图标。
- 提供版本、硬件架构、系统信息和作者信息的关于窗口。

## 构建与运行

需要 Apple Silicon Mac 和 Swift 5.9 及以上的 macOS 开发工具。当前已使用 Command Line Tools 中的 Swift 6.3.3 构建，无第三方依赖；不要求先安装完整 Xcode。

```sh
zsh scripts/build.sh
open dist/HostEditor.app
```

构建产物为 `dist/HostEditor.app`，主程序和随包辅助组件均为 arm64。首次打开默认读取 `/etc/hosts`。建议先在设置中选择 [示例文件](examples/hosts) 或临时副本试用。

主题默认深色，可选浅色、跟随系统。编辑区使用 macOS 原生文本编辑操作；选中文本后按 `⌘F` 会以选区内容开始查找，按 `Esc` 收起查找栏。`⌘S` 保存。

## Apple Silicon 安装包

```sh
zsh scripts/package-dmg.sh
```

该命令会构建并生成 `dist/HostEditor-<版本号>-arm64.dmg`。打开磁盘映像后，将 `HostEditor.app` 拖入“Applications”快捷入口即可安装。该安装包仅适用于 Apple Silicon Mac；当前为 ad hoc 开发签名包，尚未使用 Developer ID 签名或 Apple 公证，因此不应作为正式对外分发版本。

## 自动检查

```sh
swift run HostEditorChecks
```

检查仅操作独立临时目录，不写入真实系统 hosts。采用不依赖 XCTest 的检查程序，因此只有 Command Line Tools 的机器也能运行。实现说明和实际验证结果见 [开发与验收记录](docs/开发与验收记录.md)。

## 受保护文件

默认构建使用 ad hoc 开发签名。可写文件直接保存；受保护文件使用 macOS 管理员认证执行单次、限于当前目标的写入，认证不会保存密码，也不会永久更改文件权限。保存仍会先创建备份并检查磁盘版本。点击“授权写入”只验证当前路径可写，不修改文件；后续每次写入均明确确认。

正式签名版本可以改用系统管理的后台辅助服务：

在具备有效 Apple 开发签名证书的机器上，可以用同一证书签名两个组件：

```sh
SIGNING_IDENTITY='你的 Apple 签名证书完整名称' zsh scripts/build.sh
```

正式分发应使用 Developer ID Application 证书，另行完成 Apple 公证与票据附加。构建脚本完成签名检查，不自动提交公证，也不存储签名凭证。

使用可信签名版本时，将应用放在稳定的位置，再在设置中点击“授权写入”。系统可能要求在“登录项与扩展”批准后台组件；实际保存受保护文件时，还会检查当前目标路径的独立系统授权。

辅助服务可从应用设置中卸载；它的启停由系统服务管理，不随主窗口关闭。卸载不删除历史备份。用户备份位于 `~/Library/Application Support/HostEditor/Backups`；受保护写入另保留 root 管理的安全备份。

## 当前交付状态

应用已构建并完成部分本机验证。受保护文件的安装批准、跨版本兼容性、公证、VoiceOver 和全部性能目标尚未完成验收；详细状态以 [验收记录](docs/开发与验收记录.md) 为准。
