# Auspex

<p align="center">
  <strong>把 Mac 上所有 AI 编程 agent 汇总到同一块实时看板。</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/status-pre--alpha-orange" alt="状态：pre-alpha">
  <img src="https://img.shields.io/badge/macOS-26%2B-000000?logo=apple" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white" alt="Swift 6.2">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-AGPL--3.0--only-blue" alt="AGPL-3.0-only"></a>
  · <a href="README.md">English</a>
</p>

Auspex 观察你 Mac 上运行的每一个 AI 编程 agent —— Claude Code、Claude Cowork、
Codex、ChatGPT Work、Cursor、Grok Build、Grok Bot、AntiGravity —— 并汇总到同一块
实时看板：谁在思考、谁在调用工具、谁在派发子 agent、谁在写文件、谁在等待授权。
会话按项目和派生关系分组；一块共享的任务看板通过 MCP 对外暴露，agent 自己也能说
出它需要什么。

> **状态：pre-alpha。** 它能跑，它在 tail 真实的存储，作者每天在用。但没有打过
> tag 的发布，没有公证过的构建，版本之间也没有升级路径 —— 数据库 schema 还在变。

![Auspex 看板：按项目分组的会话卡片，右侧是某个会话的轨迹](docs/screenshots/board.png)

## 为什么

同时跑四五个 agent harness，就意味着四五个终端标签页，而且没有任何一个能告诉你：
哪个 agent 正卡在授权确认上、哪个已经思考了六分钟、哪两个在改同一个文件、哪个二十
分钟前就干完了却一直没人看。每个 harness 本来就会把详细的会话日志写到磁盘上，
Auspex 把它们全部读出来，答案放进同一个窗口。

## 环境要求

- macOS 26 (Tahoe) 或更高版本，Apple silicon
- Xcode 26 / Swift 6.2 或更高版本

## 构建与运行

Auspex 是纯 Swift package，没有 Xcode 工程。

```sh
swift build
swift test
./Scripts/build_app.sh release   # 或：debug
open .build/Auspex.app
```

设置 `AUSPEX_CODESIGN_IDENTITY` 可改用 Developer ID Application 证书签名，并启用
hardened runtime。

加上 `--demo` 会改为回放一块伪造的看板：八个 harness 上的十来个会话，循环走完提问、
调用工具、派发子 agent、等待授权、agent 呼叫真人、结束等状态。它完全在内存中运行：
不打开任何 harness 存储，不创建 `~/.auspex/`，不往磁盘写任何东西，里面出现的所有
路径都在 `/Users/example` 下。

```sh
.build/Auspex.app/Contents/MacOS/Auspex --demo
```

`open -a` 无法传参，所以直接运行二进制；或者设置 `AUSPEX_DEMO=1`，效果相同。本文
里的每一张截图都是 app 自己从这块演示看板离屏渲染出来的（`--render-board`、
`--render-scene`、`--render-crew`、`--render-trajectory`），所以没有一张带着真实
会话、真实路径或真实姓名。

## 跟随系统外观

每一个颜色都有两套取值——同样的四级表面、同样的三级文字、每种状态一个颜色、每个
harness 一个颜色，变的只是明度——所以浅色和深色是同一块看板，不是两套设计。Auspex
默认跟随 Mac 的外观设置，包括日落时的自动切换。

![浅色外观下的看板：同一堵卡片墙，落在温暖的米白底色上](docs/screenshots/board-light.png)

**设置 → Appearance** 可以强制浅色或深色，可以让侧栏在系统材质和看板自己的纯色底
之间切换，并且会把当前生效的强调色、背景色、前景色三块色板显示出来。切换不需要重
启：窗口、菜单栏面板、办公室场景和 Crew 都会就地重绘。`--appearance light|dark`
对单次启动做同样的事而不写入设置，性能预算就是这样对两套外观分别测量的。

下面每一张截图在 `docs/screenshots/` 下都有一张 `-light` 的同名版本，由同一条命令
末尾加上 `appearance=light` 渲染而来。

## 同一块看板的四种读法

顶部的分段控件切换实时会话的画法。它是"模式"而不是"页面"：选中项、分组、过滤器，
以及旁边的轨迹面板，都会跨切换保留。

**Board** 是卡片墙 —— 唯一能一次显示全部会话的视图，也是把*这个会话正在干什么*讲
得最精确的那个：状态、工具名、目标文件、耗时、token、它被要求做什么、它最后说了
什么。

**Scene** 把同一块看板画成一间办公室。每个会话是一个坐在工位上的人，每个项目是他们
共用的一个房间，子 agent 坐在派生它的 agent 旁边的小工位上。最响的通道是光：显示器
的颜色就是会话的状态，它的节奏就是那个状态的动作。六个房间的灯光会在任何形状被辨认
出来之前先形成图案。

![场景视图：一个项目一个房间，agent 坐在工位上，显示器被它们正在做的事点亮](docs/screenshots/scene.png)

画布是真正的 `NSScrollView`，所以两指可以像在"预览"里那样同时平移和捏合，带同样的
惯性和同样的弹性边缘；⌘-滚动缩放，两指双击框住指针下的房间，**Fit**（⌘0）框住全部。
点击工位会填充轨迹面板 —— 和点击卡片是同一个选中。开启"减弱动态效果"后，所有节奏都
塌缩成静态姿势。

| 状态 | 工位 | Agent |
| --- | --- | --- |
| 思考中 | 屏幕呼吸，蓝色 | 点头 |
| 调用工具 | 屏幕闪烁，琥珀色 | 双手快速交替 |
| 写文件 | 稳定绿色，桌上有纸 | 双手交替，半速 |
| 派发子 agent | 稳定紫色，连线脉动 | 站起来递出一张纸条 |
| 等待授权 | 红色频闪 | 举手，红色 `!` 气泡 |
| 空闲 · 沉默 · 结束 | 暗 · 暗 · 黑 | 瘫着 · `zzz` · 人走了 |

其中只有一个被允许大喊大叫，而它恰好是没有人就永远不会自己解决的那个。

| | |
| --- | --- |
| ![Crew 视图：一个会话一个几何头像](docs/screenshots/crew.png) | ![Trajectory 视图：一个会话的轮次瀑布流与步骤列表](docs/screenshots/trajectory.png) |
| **Crew** —— 一个会话一个几何头像，表情和姿态由这个会话正在做的事驱动。信息量和场景相同，像素只用十分之一。 | **Trajectory**（⌘T）—— 把单个会话摊开：轮次瀑布流、它走过的每一步，以及选中那一步的检视器。 |

## 看板不只显示 agent 在做什么，也显示它要什么

被动观察回答不了*这个会话是不是在等我*。Claude Code 和 Cursor 不会把授权状态写到
磁盘上，"我问了你一个问题，我在等"在任何 harness 的文件里都是不可见的。所以 Auspex
在 `~/.auspex/mcp.sock` 上跑一个 MCP server，让会话自己说。

```jsonc
// ~/.claude.json —— Settings → Harnesses 会带围栏地帮你写好，也能原样撤销
{ "mcpServers": { "auspex": {
    "command": "/Applications/Auspex.app/Contents/MacOS/Auspex",
    "args": ["--mcp-stdio"]
} } }
```

```toml
# ~/.codex/config.toml
[mcp_servers.auspex]
command = "/Applications/Auspex.app/Contents/MacOS/Auspex"
args = ["--mcp-stdio"]
```

- **`auspex.notify(kind, message)`** —— `needs_input`、`needs_review`、
  `blocked` 或 `done`，附一句话。它会发一条 macOS 通知，把卡片移进对应的分桶，并把
  agent 自己的话写在上面。`needs_input` 会在真人下次对那个会话说话时自动清除。
- **`auspex.report(focus, progress)`** —— 用会话自己的一句话替换 Auspex 对它在做
  什么的推断。
- **`plans.*` / `tasks.*`** —— 共享任务看板。派活的人用 `plans.create` 登记拆解，
  为每个 worker `tasks.create` 一条并把 id 写进 brief；每个 worker 调用
  `tasks.claim(task_id, role, scope)`，卡住时 `tasks.update`，做完时
  `tasks.complete`。
- **`sessions.self` / `sessions.list` / `sessions.tree` / `peers.status`** ——
  只读。agent 永远不需要知道自己的 session id：Auspex 从 socket 另一端的进程推出来。

一共十六个工具。`auspex --mcp-stdio` 是给只会说 stdio 的客户端用的轻量桥接 —— 它连
上 socket 并转发字节，Auspex 没在跑时以 1 退出并打印一行，所以这套协议只是增益，
永远不是依赖。同一次注册还会给有 hook 机制的 harness 装上 **hook**：
`auspex --hook <harness>` 把生命周期事件原样转发到同一个 socket，并且无论发生什么都
在 200 ms 内以 0 退出 —— 因为 hook 是正在干活的 agent 的同步子进程，绝不能卡住它，
更不能否决它。

![Tasks 页：计划、它们的任务，以及每条任务被谁认领](docs/screenshots/tasks.png)

## 项目、委派树，以及你不想看到的会话

有两个问题横贯整块看板，而没有任何 harness 会记录：会话**在哪里**工作，以及**是谁**
把它拉起来的。Auspex 从机器本身取答案 —— 前者读 git 自己的文件，后者读进程表。

![侧栏的项目树，右侧是看板上的一棵委派树](docs/screenshots/projects.png)

- **侧栏**列出看板上的每个项目，并给出正在其中运行的数量。同一仓库的三个 worktree
  是一个项目下的三个 checkout；agent worktree 用任务名而不是路径来标注。点击一个项目
  会把所有界面都绑到它上面 —— 卡片墙、树，以及场景的镜头。
- **Group by: Tree** 把卡片墙变成委派森林。轨迹头部会说明这条父子关系是*怎么*确定
  的 —— 父会话自己的日志记录了这次派生、子进程继承了环境变量、进程树上的祖先关系，
  还是人手动连的 —— 因为这几种证据的强度完全不同。
- **你自己的项目**可以认领文件夹，于是属于同一件事的六个目录会被读成一个项目，不管
  git 怎么说。**忽略规则**可以隐藏一个文件夹、一个项目、一个 prompt 前缀、一整个
  harness，或标题里的一个子串。被忽略不等于被删除：头部会给出"N ignored"，点开就把
  它们以变暗的样子放回来。

## Harness

八个 harness 都是一等公民：各有一行、一个主色和厂商自己的 logo，并且在任何界面里都
写全名，Auspex 从不缩写。

| Harness | 厂商 | Auspex 读取的存储 |
| --- | --- | --- |
| Claude Code | Anthropic | `~/.claude/projects`、`~/.config/claude/projects` |
| Claude Cowork | Anthropic | `~/Library/Application Support/Claude/local-agent-mode-sessions` |
| Codex | OpenAI | `~/.codex/sessions` —— 除 ChatGPT Work 外的全部 originator |
| ChatGPT Work | OpenAI | 同一棵目录树，`originator` 为 ChatGPT Work |
| Cursor | Anysphere | `~/.cursor/chats` |
| Grok Build | xAI | `~/.grok/sessions` |
| Grok Bot | xAI | `~/Library/Application Support/Grok Bot/sand-client-persistence` |
| AntiGravity | Google | `~/.gemini/antigravity` |

有两对 harness 共用同一个厂商 logo，因为它们本来就是同一家的：Claude Code 与
Claude Cowork，Codex 与 ChatGPT Work。区分它们靠主色和全名，而不是改动 logo。
Gemini CLI 能被识别但不进这八个：它已被弃用，Auspex 也没有对应的实时 adapter。

Harnesses 页回答两个问题：*为什么这个 harness 没出现在看板上*，以及*它能够到什么*。
页面给出它的存储在本机是否存在、有多少会话正在运行、最后一次活动是什么时候，以及它
配置了哪些 MCP server 和 hook。这一页背后的每个文件都只读不写。

这里故意没有放这一页的截图。它是一份关于*这台机器*的报告 —— 会列出你自己配置的
MCP server —— 所以它的截图就是某个人的环境快照，而这个仓库是公开的。想看请自己跑。

## 角色包

场景里的人在美术资源到位之前都是代码画的占位图形。真正的角色是一个文件夹 —— 一份
manifest 加上每个姿势一条帧带 —— 放进 `~/.auspex/characters/` 就会被拾取，不需要重新
构建也不需要重启，可以一个姿势一个姿势地补。
[`docs/CHARACTERS.md`](docs/CHARACTERS.md) 是规格；Settings → Characters 是按 harness
选择角色的地方。

## 数据从哪来

Auspex 是**只读的本地文件观察者**。

- 每个受支持的 harness 本来就会把会话记录写在用户目录下 —— JSONL 转录、SQLite
  存储、会话数据库。Auspex 只是 tail 这些文件，并据此重建会话状态机。
- **所有 harness 的存储一律只读。** Auspex 从不写入其他工具的目录，不删除会话，也不
  修改转录内容。SQLite 存储以只读方式打开，并预期存在活跃的 WAL。
- **Auspex 自己写的一切都在 `~/.auspex/` 下**（权限 0700），且统一经由 `AuspexPaths`
  一个类型，因此写入范围读一个文件就能审计清楚。
- **只有一个例外。** 把 Auspex 的 MCP server 和它的 hook 注册进某个 harness，意味着
  要写那个 harness 的配置文件。它只在真人于 Settings → Harnesses 里点击时发生，只写在
  Auspex 自己拥有的区域里 —— `>>> auspex >>>` 围栏、一个名为 `auspex` 的 JSON 成员，
  或者命令指向 Auspex 二进制的那几条 hook 条目 —— 写之前先备份到
  `~/.auspex/backups/`，写完重新解析校验，并且可以精确撤销。
- **无网络。** 没有后端、没有遥测、没有分析、没有更新服务，任何数据都不会离开你的
  机器。

Auspex **不启用 macOS app sandbox**，因为沙箱内的 app 无法跨目录读取它要观察的
harness 存储，也无法绑定 `~/.auspex/mcp.sock`。这是有意的取舍，而不是疏漏；它也不构成
随意读写文件系统的许可，详见 [`AGENTS.md`](AGENTS.md)。

## 隐私

Agent 转录是开发机上最敏感的文本之一：里面有源码、基础设施细节，以及凌晨两点被粘进
prompt 的任何内容。Auspex 按这个标准对待它们。

- 会话内容始终留在本地，存于 `~/.auspex/` 下的 SQLite 数据库。
- 进程命令行在记录或落库前会先脱敏 —— 某些 harness 会把凭据放在 argv 里
  （`cursor-agent --api-key …`）。
- agent 通过 MCP 写进来的文本，会在进入存储或屏幕之前被剥掉控制字符、双向覆写字符和
  零宽格式字符。
- 不上传任何东西；也没有"关闭遥测"的开关，因为根本没有遥测。
- 仓库是公开的：真实 token、组织 ID、账号 ID、邮箱地址，以及 `/Users/<name>` 路径，
  都不允许出现在源码、fixture 或日志中。

## 性能

Auspex 整天跟它观察的那些 harness 一起跑，所以它的开销是一项功能而不是事后补丁。它被
要求满足的预算和背后的实测数据在 [`AGENTS.md` § 4.1](AGENTS.md)。简单说：窗口要画的
那一帧是在主 actor 之外推导出来的，视图比较的是扁平的行值而不是会话快照，所有秒表由
同一个时钟驱动，不在屏幕上的视图里什么都不动。

## 路线图

| 里程碑 | 范围 | 状态 |
| ------ | ---- | ---- |
| **M0** | 仓库骨架，以及共享包 `agent-session-kit`：会话模型、事件流、source adapter 协议。 | 已完成 |
| **M1** | Claude Code 与 Codex 的实时看板、会话轨迹与菜单栏，实时更新。 | 已完成 |
| **M2** | 全部八个 harness，项目与任务分组，用户自己的项目与忽略规则，场景视图与 Crew 视图。 | 已完成 |
| **M3** | 基于 `~/.auspex/mcp.sock` 的 MCP 任务看板、`--mcp-stdio` 桥接、可选的 harness hook（`--hook`），以及一键写入各 harness 配置。 | 已完成 |
| **M4** | 保留策略的定时执行，以及控制能力 —— 不只是观察，还能直接对会话执行操作。 | 下一步 |

## 架构

[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) 描述它是怎么拼起来的：source adapter、
事件流与状态 reducer、会话注册表、board frame assembler、GRDB 存储，以及 MCP 接口。

## 参与贡献

分支与 PR 流程、隐私规则见 [`CONTRIBUTING.md`](CONTRIBUTING.md)；完整的操作手册
（包括 AI agent 在本仓库工作时必须遵守的约定）见 [`AGENTS.md`](AGENTS.md)。

安全问题报告见 [`SECURITY.md`](SECURITY.md)。

## 许可证

AGPL-3.0-only。Copyright © 2026 AstroQore。见 [`LICENSE`](LICENSE)。
