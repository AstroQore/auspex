# Auspex

<p align="center">
  <strong>把 Mac 上所有 AI 编程 agent 汇总到同一块实时看板。</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/status-pre--alpha%2C%20private%20development-orange" alt="状态：pre-alpha，私有开发中">
  <img src="https://img.shields.io/badge/macOS-26%2B-000000?logo=apple" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white" alt="Swift 6.2">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-AGPL--3.0--only-blue" alt="AGPL-3.0-only"></a>
  · <a href="README.md">English</a>
</p>

Auspex 观察你 Mac 上运行的每一个 AI 编程 agent —— Claude Code、Codex、Cursor、
Grok Build、Antigravity —— 并汇总到同一块实时看板：谁在思考、谁在调用工具、谁在
派发子 agent、谁在写文件、谁在等待授权。会话可按项目和任务分组，任务看板通过 MCP
对外暴露。

> **状态：pre-alpha，私有开发中。** 当前仓库只是骨架，尚未真正观察任何东西，
> 具体进度见 [路线图](#路线图)。

## 为什么

同时跑四五个 agent harness，就意味着四五个终端标签页，而且没有任何一个能告诉你：
哪个 agent 正卡在授权确认上、哪个已经思考了六分钟、哪两个在改同一个文件。每个
harness 本来就会把详细的会话日志写到磁盘上，Auspex 把它们全部读出来，答案放进
同一个窗口。

## 环境要求

- macOS 26 (Tahoe) 或更高版本，Apple silicon
- Xcode 26 / Swift 6.2 或更高版本

## 构建

Auspex 是纯 Swift package，没有 Xcode 工程。

```sh
swift build
swift test
```

打包成可运行的 ad-hoc 签名 app：

```sh
./Scripts/build_app.sh release   # 或：debug
open .build/Auspex.app
```

设置 `AUSPEX_CODESIGN_IDENTITY` 可改用 Developer ID Application 证书签名，并启用
hardened runtime。

## 数据从哪来

Auspex 是**只读的本地文件观察者**。

- 每个受支持的 harness 本来就会把会话记录写在用户目录下 —— JSONL 转录、SQLite
  存储、会话数据库。Auspex 只是 tail 这些文件，并据此重建会话状态机。
- **所有 harness 的存储一律视为只读。** Auspex 从不写入其他工具的目录，不删除
  会话，也不修改转录内容。
- **Auspex 自己写的一切都在 `~/.auspex/` 下**（权限 0700），且统一经由
  `AuspexPaths` 一个类型，因此写入范围读一个文件就能审计清楚。
- **无网络。** 没有后端、没有遥测、没有分析、没有更新服务，任何数据都不会离开
  你的机器。
- 可选的 harness hook（M3）是本地且需显式开启的：它们通过 `~/.auspex/mcp.sock`
  这个 Unix socket 通知正在运行的 app，从而把状态更新从"下次轮询"提前到"立刻"。

Auspex **不启用 macOS app sandbox**，因为沙箱内的 app 无法跨目录读取它要观察的
harness 存储。这是有意的取舍，而不是疏漏；它也不构成随意读写文件系统的许可，
详见 [`AGENTS.md`](AGENTS.md)。

## 隐私

Agent 转录是开发机上最敏感的文本之一：里面有源码、基础设施细节，以及凌晨两点被
粘进 prompt 的任何内容。Auspex 按这个标准对待它们。

- 会话内容始终留在本地，存于 `~/.auspex/` 下的 SQLite 数据库。
- 进程命令行在记录或落库前会先脱敏 —— 某些 harness 会把凭据放在 argv 里
  （`cursor-agent --api-key …`）。
- 不上传任何东西；也没有"关闭遥测"的开关，因为根本没有遥测。
- 仓库是公开的：真实 token、组织 ID、账号 ID、邮箱地址，以及 `/Users/<name>`
  路径，都不允许出现在源码、fixture 或日志中。

## 路线图

| 里程碑 | 范围 |
| ------ | ---- |
| **M0** | 仓库骨架，以及共享包 `agent-session-kit`：会话模型、事件流、source adapter 协议。 |
| **M1** | Claude Code 与 Codex 的实时看板 —— 运行中 / 思考中 / 调用工具 / 等待授权 / 空闲，实时更新。 |
| **M2** | 全部五个 harness，加上项目与任务分组，以及像素场景视图。 |
| **M3** | 基于 `~/.auspex/mcp.sock` 的 MCP 任务看板（含 `--mcp-stdio` 桥接），以及可选的 harness hook 实现即时更新。 |
| **M4** | 控制能力 —— 不只是观察，还能直接对会话执行操作。 |

## 架构

[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) 描述目标设计：source adapter、
事件流与状态 reducer、会话注册表、GRDB 存储，以及 MCP 接口。其中大部分尚未实现。

## 参与贡献

分支与 PR 流程、隐私规则见 [`CONTRIBUTING.md`](CONTRIBUTING.md)；完整的操作手册
（包括 AI agent 在本仓库工作时必须遵守的约定）见 [`AGENTS.md`](AGENTS.md)。

安全问题报告见 [`SECURITY.md`](SECURITY.md)。

## 许可证

AGPL-3.0-only。Copyright © 2026 AstroQore。见 [`LICENSE`](LICENSE)。
