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

Auspex 观察你 Mac 上运行的每一个 AI 编程 agent —— Claude Code、Claude Cowork、
Codex、ChatGPT Work、Cursor、Grok Build、AntiGravity —— 并汇总到同一块实时看板：
谁在思考、谁在调用工具、谁在
派发子 agent、谁在写文件、谁在等待授权。会话可按项目和任务分组，任务看板通过 MCP
对外暴露。

> **状态：pre-alpha，私有开发中。** 看板、会话轨迹和菜单栏已经跑在真实数据管线
> 上，但还没有任何 harness adapter 落地，所以真机上看板仍然是空的。想看它运行，
> 先跑 [演示模式](#看看这块看板)；具体进度见 [路线图](#路线图)。

![Auspex 看板：左侧是会话卡片，右侧是某个会话的轨迹](docs/screenshots/board.png)

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

## 看看这块看板

目前还没有任何 harness adapter 落地，所以真机启动只会看到空看板，以及它将要观察
的存储清单。加上 `--demo` 会改为回放一块伪造的看板：七个 harness 上的十个会话，
循环走完提问、调用工具、派发子 agent、等待授权、结束等状态。

```sh
./Scripts/build_app.sh debug
.build/Auspex.app/Contents/MacOS/Auspex --demo
```

`open -a` 无法传参，所以直接运行二进制；或者设置环境变量 `AUSPEX_DEMO=1`，效果
相同。

演示模式完全在内存中运行：不打开任何 harness 存储，不创建 `~/.auspex/`，不往磁盘
写任何东西，里面出现的所有路径都在 `/Users/example` 下。

| | |
| --- | --- |
| ![会话轨迹：提问、工具调用与轮次组成的瀑布流](docs/screenshots/trace.png) | ![空看板，列出每个 harness 存放会话的位置](docs/screenshots/empty.png) |
| **会话轨迹** —— 单个会话的全部事件，按轮次分组；一次工具调用折叠成一行并带上耗时，点开可看原始 payload。 | **空看板** —— 今天真机启动看到的样子：Auspex 将要读取的存储，以及哪些 adapter 已经就绪。 |

看板以深色为主，同时跟随系统外观（[浅色模式](docs/screenshots/board-light.png)）。

## 项目与委派树

有两个问题横贯整块看板，而没有任何 harness 会把答案写进日志：会话**在哪里**工作，
以及**是谁**把它拉起来的。Auspex 从机器本身取答案 —— 前者读 git 自己的文件，后者读
进程表 —— 再把结果放进侧栏和看板。

![侧栏的项目树，右侧是看板上的一棵委派树](docs/screenshots/projects.png)

- **侧栏**列出看板上的每个项目，用一个色点表示一个正在其中干活的 harness，并给出正在
  运行的数量。同一仓库的三个 worktree 是一个项目下的三个 checkout；agent worktree 用
  任务名而不是路径来标注。点击项目会把看板过滤到该项目。
- **Group by: Tree** 把看板变成委派森林：派生过子会话的会话独占一个分区，子会话在它下
  面缩进；子卡片带一枚指向父会话的 chip，点击即可打开父会话。
- **轨迹头部**会说明这条父子关系是怎么确定的 —— 父会话自己的日志记录了这次派生、子进
  程继承了环境变量、进程树上的祖先关系，还是人手动连的 —— 因为这几种证据的强度完全
  不同。

## Harness 状态

![Harnesses 页：每个 harness 的安装检测、会话计数与 MCP 配置](docs/screenshots/harnesses.png)

七个 harness 都是一等公民：各有一行、一个主色和厂商自己的 logo，并且在任何界面里
都写全名，Auspex 从不缩写。

| Harness | 厂商 | Auspex 读取的存储 |
| --- | --- | --- |
| Claude Code | Anthropic | `~/.claude/projects`、`~/.config/claude/projects` |
| Claude Cowork | Anthropic | `~/Library/Application Support/Claude/local-agent-mode-sessions` |
| Codex | OpenAI | `~/.codex/sessions` —— 除 ChatGPT Work 外的全部 originator |
| ChatGPT Work | OpenAI | 同一棵目录树，`originator` 为 ChatGPT Work |
| Cursor | Anysphere | `~/.cursor/chats` |
| Grok Build | xAI | `~/.grok/sessions` |
| AntiGravity | Google | `~/.gemini/antigravity` |

有两对 harness 共用同一个厂商 logo，因为它们本来就是同一家的：Claude Code 与
Claude Cowork，Codex 与 ChatGPT Work。区分它们靠主色和全名，而不是改动 logo。
Gemini CLI 能被识别但不进这七个：它已被弃用，Auspex 也没有对应的实时 adapter。

Harnesses 页回答两个问题：*为什么这个 harness 没出现在看板上*，以及*它能够到什么*。
页面给出它的存储在本机是否存在、有多少会话正在运行、最后一次活动是什么时候，以及它
配置了哪些 MCP server。这一页背后的每个文件都只读不写 —— 包括配置文件，Auspex 只从中
取出 server 名字，别的什么都不做。

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
| **M1** | Claude Code 与 Codex 的实时看板 —— 运行中 / 思考中 / 调用工具 / 等待授权 / 空闲，实时更新。*看板、轨迹检视器和菜单栏已完成，两个 adapter 正在落地。* |
| **M2** | 全部七个 harness，加上项目与任务分组，以及像素场景视图。 |
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
