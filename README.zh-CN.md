<p align="center">
  <img src="docs/brand/auspex-logo.png" alt="Auspex" width="160">
</p>

<h1 align="center">Auspex</h1>

<p align="center">
  <strong>把 Mac 上所有 AI 编程 agent 汇总到同一块实时看板。</strong>
</p>

<p align="center">
  <a href="https://github.com/AstroQore/auspex/actions/workflows/ci.yml"><img src="https://github.com/AstroQore/auspex/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/AstroQore/auspex/releases/latest"><img src="https://img.shields.io/github/v/release/AstroQore/auspex?display_name=tag&sort=semver" alt="最新发布"></a>
  <img src="https://img.shields.io/badge/status-pre--alpha-orange" alt="状态：pre-alpha">
  <img src="https://img.shields.io/badge/macOS-26%2B-000000?logo=apple" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white" alt="Swift 6.2">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-AGPL--3.0--only-blue" alt="AGPL-3.0-only"></a>
</p>

<p align="center">
  <a href="https://github.com/AstroQore/auspex/releases"><strong>下载</strong></a>
  · <a href="#构建与运行">从源码构建</a>
  · <a href="#致谢">致谢</a>
  · <a href="README.md">English</a>
</p>

Auspex 观察你 Mac 上运行的每一个 AI 编程 agent —— Claude Code、Claude Cowork、
Codex、ChatGPT Work、Cursor、Grok Build、Grok Bot、AntiGravity —— 并汇总到同一块
实时看板：谁在思考、谁在调用工具、谁在派发子 agent、谁在写文件、谁在等待授权。
会话按项目和派生关系分组；一块共享的任务看板通过 MCP 对外暴露，agent 自己也能说
出它需要什么。

> **状态：pre-alpha。** 它能跑，它在 tail 真实的存储，作者每天在用。现在已有一个
> Dev 预览版，但还没有 Stable 或公证过的构建，版本之间也不承诺升级路径 —— 数据库
> schema 还在变。把「下载」当作实验预览；要用当前源码则是两条命令：
>
> ```sh
> git clone https://github.com/AstroQore/auspex.git && cd auspex
> ./Scripts/build_app.sh release && open .build/Auspex.app
> ```

![Auspex Ledger：按项目分组的会话卡片，右侧是某个会话的轨迹](docs/screenshots/board.png)

<details>
<summary>同一块 Ledger 的浅色外观</summary>

![浅色外观下的 Ledger：同一堵卡片墙，落在温暖的米白底色上](docs/screenshots/board-light.png)

</details>

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

## 下载与更新

打过 tag 的构建会作为 GitHub Release 发布，从 Release 装的那份会自己保持更新：
**设置 → Updates**，或者 **Auspex → Check for Updates…**。Auspex 每天检查一次，
并且从不擅自安装 —— 这是一个人们会连着开好几天的窗口，一个把自己换掉的 app 会连
带着把正在跑的会话窗口一起换掉。

有两条通道，由这份拷贝自己选：

| | |
| --- | --- |
| **Stable** | 只有正式发布的版本。默认待在这条。 |
| **Dev** | 两次发布之间切出来的预览版，**外加**每一个正式版本。 |

Dev 是叠加而不是替换：试预览版不会让你错过下一个稳定版修复。feed 里的每个构建都用
项目的 EdDSA 私钥签过名，在解包前先拿你这份拷贝里编译进去的公钥验一遍，所以传输途
中被改过的下载会被拒绝而不是被执行。这道校验独立于 Apple 的那一套 —— 在构建还是
ad-hoc 签名的阶段这一点尤其重要，Gatekeeper 会让你手动放行第一次启动。

这个选择和其它设置一样写在 `~/.auspex/settings.json` 里，你可以直接读它、改它，或者
不开 app 就撤销它。

> **仍是 pre-alpha。** Dev feed 里已有预览版，但没有 Stable，也没有 notarization。
> 需要当前分支时请从源码构建（见上）；`RELEASING.md` 写了一次发布是怎么切出来、签名
> 并发布的。

## 跟随系统外观

每一个颜色都有两套取值——同样的四级表面、同样的三级文字、每种状态一个颜色、每个
harness 一个颜色，变的只是明度——所以浅色和深色是同一块看板，不是两套设计。Auspex
默认跟随 Mac 的外观设置，包括日落时的自动切换。上面那张看板的浅色版折在本页开头的
折叠块里。

**设置 → Appearance** 可以强制浅色或深色，可以让侧栏在系统材质和看板自己的纯色底
之间切换，并且会把当前生效的强调色、背景色、前景色三块色板显示出来。切换不需要重
启：窗口、菜单栏面板、Aviary 和 Flock 都会就地重绘。`--appearance light|dark`
对单次启动做同样的事而不写入设置，性能预算就是这样对两套外观分别测量的。

下面每一张截图在 `docs/screenshots/` 下都有一张 `-light` 的同名版本，由同一条命令
末尾加上 `appearance=light` 渲染而来。

键盘焦点只遵守一条规则：新打开的 Auspex 窗口、Sheet 或 Popover 默认保持中立，不替用户
选中任何按钮或输入框；用户主动按 Tab 或方向键后，再进入正常的 macOS 键盘导航并显示
焦点反馈。`⌘K` 命令面板是有意的例外——按下快捷键本身就是明确的输入动作，所以搜索框
会直接准备好输入。

## 同一块看板的四种读法

顶部的分段控件切换实时会话的画法。它是「模式」而不是「页面」：选中项、分组、过滤器，
以及旁边的轨迹面板，都会跨切换保留。

**Ledger**（原 Board）是卡片墙 —— 唯一能一次显示全部会话的视图，也是把*这个会话
正在干什么*讲得最精确的那个：状态、工具名、目标文件、耗时、token、它被要求做什么、
它最后说了什么。

**Aviary**（原 Scene）把同一块看板画成一个地方。每个会话是一个人，每个项目是一个
房间，而*人在哪里*是一眼最先读到的东西：干活的会话坐在自己工位上；正在派发的会话走进会议室，它
派生的子 agent 围着长桌坐一圈；空闲的会话在花园长椅上歇着 —— 其中做完了某件事、而
你还没看的那些手里捏着一张纸条 —— 结束的会话从门口走出去。最响的通道是光：显示器
的颜色就是会话的状态，它的节奏就是那个状态的动作。

![Aviary：一个项目一个房间，agent 坐在工位上，显示器被它们正在做的事点亮](docs/screenshots/scene.png)

画布是真正的 `NSScrollView`，所以两指可以像在「预览」里那样同时平移和捏合，带同样的
惯性和同样的弹性边缘；⌘-滚动缩放，两指双击框住指针下的房间，**Fit**（⌘0）框住全部。
点击工位会填充轨迹面板 —— 和点击卡片是同一个选中。开启「减弱动态效果」后，所有节奏都
塌缩成静态姿势。

| 状态 | 工位 | Agent |
| --- | --- | --- |
| 思考中 | 屏幕呼吸，蓝色 | 点头 |
| 调用工具 | 屏幕闪烁，琥珀色 | 双手快速交替 |
| 写文件 | 稳定绿色，桌上有纸 | 双手交替，半速 |
| 派发子 agent | 稳定紫色，连线脉动 | 站起来递出一张纸条 |
| 空闲 · 沉默 · 结束 | 暗 · 暗 · 黑 | 瘫着 · `zzz` · 从门口走出去 |

只有一样东西被允许大喊大叫，而它恰好是没有人就永远不会自己解决的那个 —— 但它不是
一种状态。见下一节。

| | |
| --- | --- |
| ![Flock：一个会话一个几何头像](docs/screenshots/crew.png) | ![Flight：一个会话的轮次瀑布流与步骤列表](docs/screenshots/trajectory.png) |
| **Flock**（原 Crew）—— 一个会话一个几何头像，表情和姿态由这个会话正在做的事驱动。信息量和 Aviary 相同，像素只用十分之一。 | **Flight**（原 Trajectory，⌘T）—— 把单个会话摊开：轮次瀑布流、它走过的每一步，以及选中那一步的检视器。 |

## 两个轴：会话在做什么，以及它要不要你

**活动（Activity）** 永远是推断出来的，对机器上的每个会话都推断 —— 干活、空闲、
沉默、结束。**注意力（Attention）** 从不推断。只有当某样东西*明确说了*，一张卡片
才会被算作在等人或者已经做完：agent 调用 `auspex.notify`、一次 `PermissionRequest`
hook，或者 harness 自己的授权等待。

两者互相独立。一个 agent 在 `swift build` 还没跑完时报告自己完成了，那它同时是「在
干活」和「已完成」，而且两件事都为真。

| | 什么会把卡片放进来 | Ledger | Aviary | 菜单栏 | 通知 |
| --- | --- | --- | --- | --- | --- |
| **需要你** | `notify(needs_input\|needs_review\|blocked)`、授权 hook、harness 自己的等待 | 红环、呼吸、排在最前 | 花园第一排，红色 `!` | `! N` | 总是 |
| **已完成** | `notify(done)`、`tasks.complete` | 绿环，附上 agent 自己那句话 | 同一排，绿色 `✓` | `✓ N` | 默认开 |
| **干活中** | 思考、工具、写文件、子 agent | 普通卡片 | 工位或会议桌 | `▶ N` | 无 |
| **空闲** | 一轮结束，没有未了事项 | 灰色胶囊 | 花园长椅，太久就打盹 | — | 无 |
| **已结束** | 进程没了 | 折叠起来 | 从门口走出去 | — | 无 |

*空闲*和*结束*这一对值得说准：**空闲意味着你还能在那个终端里继续说话**，而**结束
意味着那条线没了 —— 只有 Resume 能把活儿接回来**。

一轮单纯地结束，不属于以上任何一种。它就是空闲，只在卡片上留一个很淡的点，别的什么
都不做：在一台跑了一整周 agent 的机器上，这个推断同时对几百个会话成立，而一个没人能
处理的计数会把它旁边那些计数一起拖下水。

两个「响」的分桶都会自己清掉。打开卡片、在那个会话自己的终端里敲字、agent 重新开始
干活、点「Dismiss」、点「Mark all as seen」，或者过了一天 —— 以先发生的为准。

## 看板不只显示 agent 在做什么，也显示它要什么

被动观察回答不了*这个会话是不是在等我*。Claude Code 和 Cursor 不会把授权状态写到
磁盘上，「我问了你一个问题，我在等」在任何 harness 的文件里都是不可见的。所以 Auspex
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
  agent 自己的话写在上面。它会在真人下次对那个会话说话、打开卡片，或者过了一天之后
  自动清除。`tasks.complete` 自己就会记一条 `done`，所以 worker 不用说两遍。
- **`auspex.report(focus, progress)`** —— 用会话自己的一句话替换 Auspex 对它在做
  什么的推断。
- **`overview.get(project?)`** —— 一次拿到当前项目的自己、Doing、Blocked、Review、
  可认领任务、孤儿 claim 和所有明确在等人的会话。
- **`tasks.*`** —— 共享任务看板。**每条任务都属于某个项目**，项目由调用方所在的
  会话解析出来：agent 调 `tasks.create` 时不用说自己在哪里工作，任务会落在看板
  给这个 agent 的卡片分组用的同一个项目下。派活的人为每个 worker 建一条任务并把
  id 写进 brief；每个 worker 调用 `tasks.claim(task_id, role, scope)`，卡住时
  `tasks.update`，做完时 `tasks.complete`。每条任务带单调递增的 `version`，新版
  caller 在写入时回传 `expected_version`；过期写入、缺失/自指/成环依赖都会原子拒绝。
  Claim 冲突会成为待真人批准的接管请求，不会偷走当前持有人的任务。
- **`plans.*`** —— 里程碑：项目**内部**可选的一层标题，用来给值得命名的拆解分组。
  沿用旧名字，这样已经发出去的 brief 仍然有效。
- **`sessions.self` / `sessions.list` / `sessions.get` / `sessions.tree` /
  `peers.status`** —— 只读。agent 永远不需要知道自己的 session id。`sessions.list`
  默认只列当前项目，并和 `sessions.get` 一样只给安全 capsule：活动、注意、关系、任务链接
  和主动 report，不给 prompt、cwd、原始转录、完整回复、argv 或工具输出。

一共二十个工具。`auspex --mcp-stdio` 是给只会说 stdio 的客户端用的轻量桥接 —— 它连
上 socket，把每条请求绑定到这个 bridge 进程后再转发；Auspex 没在跑时以 1 退出并打印一行，所以这套协议只是增益，
永远不是依赖。同一次注册还会给有 hook 机制的 harness 装上 **hook**：
`auspex --hook <harness>` 把生命周期事件原样转发到同一个 socket，并且无论发生什么都
在 200 ms 内以 0 退出 —— 因为 hook 是正在干活的 agent 的同步子进程，绝不能卡住它，
更不能否决它。

**Roost**（原 Tasks）是把这块任务看板读回来的地方：每个项目一条泳道、
里程碑在项目内部，每条任务按状态排列，卡片上写着是谁认领的。

![Roost：每个项目一条泳道，里程碑在项目内部，以及每条任务被谁认领](docs/screenshots/tasks.png)

## 三十秒重新进入现场

**Catch up** 把你离开后的变化压成三组：需要真人处理的队列（含接管审批）、任务/report/结果等实质变化，
以及琥珀色观察信号（工作区或分支重叠、陈旧会话、长工具调用、上下文压力）。普通 token 和
工具事件不算实质变化；观察信号也不会冒充通知。「Mark caught up」只在你点击时推进游标。

Review 有独立的 **Review Next** 队列。任务详情把三种事实分开：agent 自报、任务记录里的
证据/决策/风险，以及本地 Git 当前观察。Git 只在打开详情或点 Refresh 时读取，不 fetch，
不进入常驻帧循环。**Copy handoff** 会生成有来源标签的有界交接包，包含团队状态、交付、
证据和 resume 提示；只复制，不自动发送。

首次设置和 **Settings → Agents** 可以在 MCP/hook 之外安装版本化的
`auspex-coordination` Skill，教 Supervisor/Worker/Reviewer 读取安全上下文、携带任务版本、
区分待批准接管与真正 ownership，并留下可核验证据。它只占一个带 hash 的 Auspex 专属目录，
可备份、可精确卸载；遇到外来或被修改的文件会 fail closed。

**Settings → General → Launch at login** 使用 macOS ServiceManagement 启动签名主程序，
没有 helper、没有 LaunchAgent。登录启动时只显示菜单栏并开始观察；若用户在系统设置里关闭，
macOS 状态优先，不会被下次启动偷偷打开。从 Finder 或 Dock 再打开则恢复普通主窗口。

## 项目、委派树，以及你不想看到的会话

有两个问题横贯整块看板，而没有任何 harness 会记录：会话**在哪里**工作，以及**是谁**
把它拉起来的。Auspex 从机器本身取答案 —— 前者读 git 自己的文件，后者读进程表。

![侧栏的项目树，右侧是看板上的一棵委派树](docs/screenshots/projects.png)

- **侧栏**列出看板上的每个项目，并给出正在其中运行的数量。同一仓库的三个 worktree
  是一个项目下的三个 checkout；agent worktree 用任务名而不是路径来标注。点击一个项目
  会把所有界面都绑到它上面 —— 卡片墙、树，以及 Aviary 的镜头。
- **Group by: Tree** 把卡片墙变成委派森林。轨迹头部会说明这条父子关系是*怎么*确定
  的 —— 父会话自己的日志记录了这次派生、子进程继承了环境变量、进程树上的祖先关系，
  还是人手动连的 —— 因为这几种证据的强度完全不同。
- **你自己的项目**可以认领文件夹，于是属于同一件事的六个目录会被读成一个项目，不管
  git 怎么说。**忽略规则**可以隐藏一个文件夹、一个项目、一个 prompt 前缀、一整个
  harness，或标题里的一个子串。被忽略不等于被删除：头部会给出「N ignored」，点开就把
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

### 每个 harness 到底能被看到多少

一等公民不等于一样多。Auspex 只能读到 harness 自己写下来的东西，而它们写下来的东西
差别很大。下面这张表是 adapter 今天真正做到的，不是它们本可以做到的。

| | 实时状态 | 工具 | 子 agent | 等待授权 | 上下文窗口 | 配额 | Resume |
| --- | :-: | :-: | :-: | :-: | :-: | :-: | :-: |
| **Claude Code** | ✓ | ✓ | ✓ | hook | 推导 | — | ✓ |
| **Claude Cowork** | ✓ | ✓ | ✓ | MCP | 推导 | — | — |
| **Codex** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| **ChatGPT Work** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| **Cursor** | ✓ | ✓ | hook | MCP | — | — | — |
| **Grok Build** | ✓ | ✓ | 推导 | ✓ | ✓ | — | ✓ |
| **Grok Bot** | 推导 | — | — | ✓ | — | — | — |
| **AntiGravity** | ✓ | ✓ | ✓ | ✓ | — | — | 仅 CLI |

**✓** harness 自己的存储里就写了 · **推导** Auspex 自己算出来 ·
**hook** 只有装上可选的 hook 才知道（Settings → Harnesses）·
**MCP** 只有 agent 自己通过 `auspex.notify` 说了才知道 ·
**—** 磁盘上没有任何东西能回答它。

`auspex.notify` 对八个 harness 都有效；标 **MCP** 的格子表示它是*唯一*的答案。

按列读比按行读有用，每一列都是一种不同的缺口：

- **实时状态 · 工具。** 除 Grok Bot 外，每个 harness 都会写一份带工具调用的转录。
  Grok Bot 的存储只记一个 streaming 标志和文本，没有工具名、没有模型、没有 token
  计数，所以它的卡片只说「思考中」或「空闲」，然后诚实地打住。
- **子 agent。** Claude Code、Claude Cowork、Codex 和 AntiGravity 都会记录一条从子
  会话回指父会话的链接，所以委派树是读出来的而不是猜出来的。Grok Build 把
  `spawn_subagent` 记成一个工具名，却从不写它创建的那个会话是谁，所以 Auspex 知道
  发生了一次派发，但不知道派给了谁。Cursor 的父子关系只从 hook 来。这些都没有的时候
  还有进程表兜底，而且轨迹头部永远会说明这条父子关系是哪一类证据 —— 记录在案的派生、
  继承的环境变量、进程祖先，还是人自己连的。
- **等待授权。** Codex、Grok Build、Grok Bot 和 AntiGravity 会写下来。Claude Code
  和 Cursor 在自己的界面里决定这件事，在答案回来之前转录里什么都没有 —— 这正是 MCP
  server 和 hook 存在的全部理由。
- **上下文窗口 · 配额。** Codex 两样都报，实测值，来自它自己的 rollout。Grok Build
  报上下文，实测值。Claude Code 和 Claude Cowork 报 token 用量，Auspex 拿它对一张
  模型窗口大小表算出百分比，所以这两格写「推导」。**这两列目前在 app 里哪儿都没有
  画出来** —— 流水线算了，卡片显示的是累计 token，仪表还没做。之所以列在这里，是因为
  数据是真的，缺的是那一半界面。
- **Resume。** `claude --resume`、`codex resume`、`grok --resume`，以及从 CLI 而不是
  IDE 启动的 AntiGravity 会话的 `agy --conversation`。其余几个没有可以 resume *回去*
  的地方：Cursor 和 Claude Cowork 自己管着窗口，而 Grok Bot 的会话跑在服务端。

Harnesses 页回答两个问题：*为什么这个 harness 没出现在看板上*，以及*它能够到什么*。
页面给出它的存储在本机是否存在、有多少会话正在运行、最后一次活动是什么时候，以及它
配置了哪些 MCP server 和 hook。这一页背后的每个文件都只读不写。

这里故意没有放这一页的截图。它是一份关于*这台机器*的报告 —— 会列出你自己配置的
MCP server —— 所以它的截图就是某个人的环境快照，而这个仓库是公开的。想看请自己跑。

## 角色包

Aviary 里的人在美术资源到位之前都是代码画的占位图形。真正的角色是一个文件夹 —— 一份
manifest 加上每个姿势一条帧带 —— 放进 `~/.auspex/characters/` 就会被拾取，不需要重新
构建也不需要重启，可以一个姿势一个姿势地补。
[`docs/CHARACTERS.md`](docs/CHARACTERS.md) 是规格；Settings → Characters 是按 harness
选择角色的地方。

## 设置

八个面板。Auspex 自己的偏好都在 `~/.auspex/settings.json`；只有明确点击的 Agent 集成
和 macOS Login Item 会离开这个文件，单纯打开设置页不会写它们。

- **Agents** —— 各 harness 的 MCP、hook、协议说明和版本化 Skill，可备份并精确撤销。
- **General** —— 通过 macOS ServiceManagement 开机登录启动。
- **Appearance** —— 浅色、深色，或跟随系统；侧栏用哪种材质；以及这个选择最终解析出的
  三个颜色。切换不重启。
- **Characters** —— Aviary 和 Flock 里每个 harness 穿哪个角色包。
- **Scene / Crew** —— 空间布局与动画预算。
- **Ignore** —— 项目认领与隐藏无关会话的规则。
- **Updates** —— Stable 还是 Dev，以及这份拷贝上次检查是什么时候。

## 它是怎么工作的

八行，然后是长版本。

1. 每个 harness 本来就会把会话写在用户目录下的某个地方 —— JSONL 转录、SQLite 存储、
   protobuf 记录行。
2. 每个 harness 一个 **source adapter**，就地 tail 这些文件、从当前末尾开始读，并且
   从不往回写一个字节。
3. 每个 adapter 把读到的东西翻译成同一套很小的**事件**词汇 —— 一次提问、一次工具
   调用、一次写文件、一个子 agent、一次结束。
4. 一个 **reducer** 把这些事件折叠成单个会话的状态；一个**注册表**持有每个活着的
   会话、它的项目和它的父亲。
5. 一个 **frame assembler** 在主 actor 之外推导出整扇窗口要画的那一帧，所以 UI 永远
   只比较扁平的值。
6. 所有要落盘的东西都经由 `AuspexPaths` 进入 **`~/.auspex/` 下唯一一个存储**
   （权限 0700）—— SQLite 数据库、设置、备份。
7. `~/.auspex/mcp.sock` 上的一个 **MCP server** 让会话说出推断看不见的事：它卡住了、
   它做完了、它正在做什么。
8. **Hook 是可选的，而且带围栏。** 只有你点了 Auspex 才写，只写在它自己拥有的区域
   里，写之前先备份，并且可以精确撤销。

[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) 是长版本：adapter、事件流与 reducer、
注册表、frame assembler、GRDB 存储，以及 MCP 接口。[`RELEASING.md`](RELEASING.md) 讲
一次构建是怎么切出来、签名并发布的。[`CONTRIBUTING.md`](CONTRIBUTING.md) 讲怎么参与
开发。

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
- **无网络，只有一个看得见的例外。** 没有后端、没有遥测、没有分析、没有账号、没有
  崩溃上报，你的会话内容不会离开这台机器。Auspex 唯一一次对外请求，是 Sparkle 去本
  仓库取一个静态 appcast 文件，问一句「有没有更新版本」—— 和你自己打开 Releases 页
  是同一种请求，除了一个版本号什么都不带。

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
- 不上传任何东西；也没有「关闭遥测」的开关，因为根本没有遥测。
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
| **M2** | 全部八个 harness，项目与任务分组，用户自己的项目与忽略规则，Aviary 与 Flock 视图。 | 已完成 |
| **M3** | 基于 `~/.auspex/mcp.sock` 的 MCP 任务看板、`--mcp-stdio` 桥接、可选的 harness hook（`--hook`），以及一键写入各 harness 配置。 | 已完成 |
| **M4** | 保留策略的定时执行，以及控制能力 —— 不只是观察，还能直接对会话执行操作。 | 下一步 |

## 参与贡献

分支与 PR 流程、隐私规则见 [`CONTRIBUTING.md`](CONTRIBUTING.md)；完整的操作手册
（包括 AI agent 在本仓库工作时必须遵守的约定）见 [`AGENTS.md`](AGENTS.md)。
行为准则见 [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md)；安全问题报告见
[`SECURITY.md`](SECURITY.md)。

## 致谢

这里几乎没有什么是第一次被想出来的。下面按它们出现在屏幕上的顺序，写清楚拿了什么、
从谁那里拿的。许可证和版权行在
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)，两份文件保持同步。

**思路与前作**

- **[Carbon](https://github.com/chunkburst/Carbon)**（MIT）—— Auspex 里任务管理的
  那一半。Carbon 是给 agent 项目做的集成式任务管理器，任务行的结构、「关闭前必须先
  评审」这条坚持、任务之间的依赖、以及记录谁做了什么的 provenance 备注，都是从它那里
  读来的。Auspex 的任务看板就是它的想法加上一块实时会话看板。
- **[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)**（MIT）——
  Flight 视图。把一次运行按来源摊成轮次瀑布流、旁边跟一个选中步骤的检视器，是
  dsh 展示一次 run 的方式，而它恰好也是展示一个会话的正确方式。
- **[Pixel Agents](https://github.com/pixel-agents-hq/pixel-agents)**（MIT）——
  像素办公室。「agent 是房间里的人」「人站在哪里本身就是信息」「气泡是程序求助的
  方式」这三件事是他们的。Auspex 的 Aviary 是它的原生 macOS 版本，覆盖八个 harness
  而不是一个 VS Code 扩展。
- **Anthropic 的 Agent View** —— 那套词汇。*needs input · working · done · idle*
  是一组经得起「一眼扫过」的小词，Auspex 直接用它，而不是给同样四个状态再发明第五套
  说法。

**移植的代码与数据**

- **[bloub](https://github.com/jeremy-prt/bloub)**（MIT，© 2026 Jérémy Perret）——
  Flock 头像引擎是它的 Swift 移植：剪影、剪影之间的缓动形变、坐在球面上带真实头部朝向
  的双胶囊眼睛模型，以及静息时的生命感（视线漂移、呼吸、眼睑曲线、形变中点处的眨眼）。
  它的数字是量出来的而不是调出来的，移植保留了它们；偏离的地方，有一个文件专门说明
  偏离在哪里、为什么。
- **[bible-strong-avatar-lab](https://github.com/smontlouis/bible-strong-avatar-lab)**
  （AGPL-3.0，© Stéphane Montlouis-Calixte）—— Flock 的表情和编排是移植过来的数据：
  25 组标定过的表情预设、按状态分的表情池与眨眼配置，以及从它们派生出来的 23 段内置
  动画序列。Auspex 同样是 AGPL-3.0，所以这些数据和推导以同一份许可证流转。有一个脚本
  能从上游 checkout 重跑这次移植，所以上游重新标定之后是重跑一次，而不是重抄一遍。
- **[agent-session-kit](https://github.com/AstroQore/agent-session-kit)** 与
  **[Vibe Bar](https://github.com/AstroQore/vibe-bar)**（AstroQore）—— harness
  adapter、实时 tail 流水线、MCP 传输和发布机制，都是先为 Vibe Bar 写的，之后抽成
  kit，也正因如此 Auspex 一上来就能支持八个 harness 而不是一个。`ProviderIcons/`
  里的厂商 logo 也是先在那边收齐的。

**外观**

- **Grok Bot**（xAI）—— Flock 的长相源自这一族头像，中间经过 bloub：它是逐帧从 xAI
  自己的视频里量出来的。
- **像素美术和整套图标**由 **OpenAI Codex** 根据
  [`docs/ART-HANDOFF.md`](docs/ART-HANDOFF.md) 生成，那份 brief 就在仓库里，所以
  prompt 和产出一样可以被review。

**依赖**

- **[GRDB.swift](https://github.com/groue/GRDB.swift)**（MIT）—— 本地存储。
- **[Sparkle](https://github.com/sparkle-project/Sparkle)**（MIT）—— 应用内更新，
  EdDSA 签名，在解包前先验。

**以及怎么做的**

Auspex 是用 **Claude Code** 和 **Codex**，配合 **AntiGravity**、**Cursor** 和 **Grok Build**
开发的 —— 模型以 Fable、Opus、Sol、Terra 为主，Gemini 和 Grok 为辅 —— 都在 git worktree
里照着书面 brief 干活。这也正是它存在的原因：当五个这样的东西同时在跑、而只有一个卡住时，
你想要的就是这么一块看板。

列出某个项目或展示它的标识，不构成任何从属、赞助或背书关系。所有名称与商标归各自
所有者。

## 许可证

AGPL-3.0-only。Copyright © 2026 AstroQore。见 [`LICENSE`](LICENSE)。
