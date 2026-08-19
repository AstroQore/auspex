# Auspex 美术素材交接（给 Codex / imagegen 流水线）

> ## ⛔ 硬性要求（违反即整批退回）
> 1. **所有角色一律是非人类的像素宠物/小生物**——参考 Claude Code / Codex 自带的 pets（小怪兽、小动物、幽灵、史莱姆、小机器人、小龙、鸟、猫、章鱼……）。**不允许出现任何人类**：不要人脸、不要人手、不要发型、不要衣服/裤子/鞋、不要办公椅上坐着的人。已生成的"人物"素材全部作废重来。
> 2. 每个 harness 一个**固定物种 + 固定主色**（见 §4 表），同门 harness 用同物种不同配饰区分。
> 3. 全部**全名**、无缩写；harness 标识用厂商真 logo（§0.3）。
> 4. 像素风：逐像素、无抗锯齿、透明底、横向单行帧条、第 0 帧可单独用（§0.1）。

> **优先级**：§4 宠物包（8 只，先 `blocked`）→ §5 家具 → §8 气泡 → §6 显示器画面 → §1 App 图标 → §2 菜单栏 → §3 应用内图标 → §7 特效 → §9 UI 动画/空状态 → §1.4 衍生物料。
> 目标：一次性产出 Auspex 需要的全部视觉素材——**图标包**（App 图标全尺寸 + 分层源 + 菜单栏 + 应用内图标集）、**俯视像素办公室**（角色 / 家具 / 地板 / 显示器画面 / 环境与特效 atlas / 气泡）、**UI 小动画帧**、**空状态与发布物料**。
> 风格标杆：Pixel Agents 那种 3/4 俯视、温暖干净的 16 位像素办公室；UI 面是深色克制的 macOS 原生风。当前程序占位画面见 `docs/screenshots/scene.png`、`board.png`。
> 交付根目录：`auspex/Resources/`（结构见 §9）。**测试时宠物包丢到 `~/.auspex/pets/`、家具/气泡等 atlas 丢到 `~/.auspex/sprites/`，app 优先读那里，不用重编。**

---

## 0. 通用硬规则

### 0.1 像素类（角色、家具、显示器画面、气泡、特效、空状态动画）
| 规则 | 值 |
|---|---|
| 视角 | **3/4 俯视**（Stardew / Pixel Agents 同款）：小生物看见头顶+背/脸，家具看见桌面 |
| 网格 | 16 px 基础网格；角色 cell 32×32；家具按 16 的倍数 |
| 像素 | **在最终分辨率上逐像素画**（最近邻缩放）；无抗锯齿、无软阴影、无渐变、无抖动；外描边 1 px `#1A1A1E`；每 sprite ≤ 14 色 |
| 背景 | 透明 PNG（straight alpha），**不烘焙投影**（显示器光、地面影 app 自己画） |
| 光源 | 统一左上 |
| 帧条 | **横向一行**，无间距无边距；`columns = width / height`；默认 8 fps；**第 0 帧必须是能单独当静态图的完整姿势**（Reduce Motion 只显示第 0 帧） |
| 命名 | 小写驼峰；PNG + 可选同名 `.json`（`{"frameWidth":32,"fps":8}`） |
| QA 附件 | 每个 atlas 一张 contact sheet（所有帧/tile 并排 + 4× 放大） |

### 0.2 矢量/UI 类（App 图标、菜单栏、应用内图标）
| 规则 | 值 |
|---|---|
| 格式 | SVG（源）+ PDF（macOS 用）；单色图标为 **template**（纯黑填充/描边，app 着色） |
| 网格 | 应用内图标 16 / 20 / 24 pt 三档，描边 1.5 pt，圆角端点，2 px 光学内边距 |
| 风格 | 线性、几何、克制，和 SF Symbols 放一起不违和；不用 emoji、不抄各家厂商 logo |

### 0.3 色板（全局，所有素材共用）
- 画布 `#101012` · 面板 `#161619` · 描边 `#26262C` · 文字 `#EDEDEF` / `#A0A0A8` / `#6C6C75`
- 状态色（唯一的饱和色）：thinking `#6EA8FE` · tool `#F2B544` · writing `#4FD08A` · delegating `#B48CFF` · **needs-you `#FF5C6C`** · idle `#7A7A85` · ended `#46464E`
- Harness 主色（**8 个正式 harness**，全部用全名，不出现任何缩写/首字母）：Claude Code `#E0785A` · Claude Cowork `#CE8F6E` · Codex `#2DD4BF` · ChatGPT Work `#22A06B` · Cursor `#4C8DFF` · Grok Build `#F45FA0` · Grok Bot `#F98BBE` · AntiGravity `#B4E048`（可选：Gemini CLI `#7DD3FC`）
- **Harness 标识一律用厂商真 logo**，源文件已放在 `auspex/Sources/AuspexApp/Resources/ProviderIcons/`（复用 vibe-bar 资产，单色 SVG，app 按上表主色着色）：`ProviderIcon-claude.svg`（Claude Code / Claude Cowork）· `ProviderIcon-codex.svg`（OpenAI 花，Codex / ChatGPT Work）· `ProviderIcon-cursor.svg` · `ProviderIcon-grok.svg`（Grok Build / Grok Bot）· `ProviderIcon-antigravity.svg` · `ProviderIcon-gemini.svg`。同一 logo 的两个 harness 靠**全名文字 + 主色**区分，不靠改 logo。

---

## 1. App 图标包（尽可能全）

### 1.1 概念（先出 3 个方向各 1 张 1024，我选一个再铺全尺寸）
Auspex = 古罗马**观鸟占卜的祭司**。
1. **眼睛里的鸟**：一只眼睛，虹膜里是极简像素鸟剪影；深色底，珊瑚→琥珀（`#E0785A`→`#F2B544`）作唯一高光。
2. **像素鸟**：深色圆角方块上一只 8-bit 侧影小鸟正在"看"，下方三段状态色细条（蓝/琥珀/绿）。
3. **占卜杖 lituus**：弯钩线条 + 一个观测点，极简单色线稿。
要求：整体是平滑矢量感（只有"鸟"可以是像素元素）；无文字；深色系为主，浅色桌面也认得出。

### 1.2 全尺寸交付（`Resources/AppIcon.iconset/`，10 张，供我 `iconutil` 转 `.icns`）
`icon_16x16.png` `icon_16x16@2x.png`(32) `icon_32x32.png` `icon_32x32@2x.png`(64) `icon_128x128.png` `icon_128x128@2x.png`(256) `icon_256x256.png` `icon_256x256@2x.png`(512) `icon_512x512.png` `icon_512x512@2x.png`(1024)
- **16 / 32 两档必须手工重绘（像素级对齐、去细节），不是缩放**；≥128 可由 1024 派生。
- macOS 26 圆角矩形（squircle）安全区内构图（1024 画布内约 824 边长内容区，四周留 100）。
- 另给 `AppIcon.png` 1024 无遮罩版 + `AppIcon-rounded.png`（带 squircle 遮罩预览）。

### 1.3 分层源（macOS 26 Icon Composer / 液态玻璃外观用，`Resources/AppIcon.layers/`）
每层 1024×1024 透明 PNG：`bg.png`（底色/渐变）、`glyph.png`（主形）、`highlight.png`（高光/次形）；再给 `dark/`、`tinted/`（单色可着色版，纯白形）两套；命名同上。

### 1.4 衍生
- `Resources/DocumentIcon.png` 1024（可选，Auspex 导出文件用：App 图标缩小 + 白纸角）
- `docs/art/social-preview.png` 1280×640（GitHub 仓库社交预览：图标 + 名字 + 一句话）
- `Resources/dmg-background.png` 660×400 @1x + `@2x` 1320×800（DMG 背景：左 App 图标位、右 Applications 箭头）

---

## 2. 菜单栏图标（`Resources/MenuBar/`，全部 template 单色 PDF，18×18 pt 画布，另附 PNG @2x 36×36 便于预览）
| 文件 | 内容 |
|---|---|
| `menubar.pdf` | 静态：与 App 图标同源的眼睛/鸟剪影，16 px 下可辨 |
| `menubar-alert.pdf` | 同图 + 右上小圆点（needs-you） |
| `menubar-off.pdf` | 描边版/半透明版（未检测到任何 harness） |
| `menubar-working.png` | **动画帧条** 6 帧 36×36 @2x（工作中：眼睛缓慢眨/扫视，或鸟头微动），4 fps；template 单色 |
| `menubar-alert.png` | 动画帧条 2 帧（圆点脉冲），2 fps |

---

## 3. 应用内图标集（`Resources/Icons/`，SVG + PDF，template）
每个给 16/20/24 三档（`name-16.svg` …）。命名与列表：

**Harness 标识：不需要新画**——直接用 `Sources/AuspexApp/Resources/ProviderIcons/*.svg` 的厂商 logo（见 §0.3）。如需，只补一件事：把 6 个 SVG 各出一版 **16 / 20 / 24 pt 光学对齐的 PDF**（描边/填充按原样，单色，template），命名 `ProviderIcon-<name>-{16,20,24}.pdf`。

**状态**：`state-thinking`（虚线圆/呼吸环）`state-tool`（提示符 `›_`）`state-writing`（笔）`state-delegating`（分叉箭头 ↳）`state-needsYou`（感叹号气泡）`state-idle`（暂停/圆点）`state-stale`（zzz）`state-ended`（方块/离席）

**导航与视图**：`nav-live` `nav-projects` `nav-tasks` `nav-harnesses` `nav-settings` `view-board` `view-scene` `view-timeline` `group-by` `filter` `search` `follow`（跟随最新）

**动作**：`action-terminal` `action-editor` `action-finder` `action-pr` `action-copy` `action-open-external` `action-jump-parent` `action-jump-child`

**Trace 行类型**：`trace-prompt`（❯）`trace-text`（¶）`trace-thinking` `trace-tool` `trace-subagent` `trace-permission` `trace-usage`（Σ）`trace-compaction` `trace-liveness`

**其它**：`tree-child`（↳）`tree-parent`（↑）`badge-live` `badge-children` `empty-eye`（空状态大图标 48 pt）

---

## 4. 角色 = Auspex 像素宠物包（场景核心，最先做）—— **非人类小生物**

Auspex 自己的宠物包格式（不复用任何第三方格式）。app 内置一 harness 一只默认宠物；用户以后可以自己画/生成一只，丢进 `~/.auspex/pets/` 即可选用：

```
Resources/Pets/<pet-id>/          app 内置（一 harness 一只默认）
~/.auspex/pets/<pet-id>/          用户自定义（同 id 覆盖内置，热加载，不用重编）
├── pet.json
├── idle.png  thinking.png  typing.png  writing.png  delegating.png  blocked.png  stale.png  ended.png
└── walkDown.png  walkRight.png  walkUp.png  spawn.png      （可选）
```

`pet.json`：
```json
{
  "id": "claudeCode-dragon",
  "displayName": "Ember",
  "species": "dragon",
  "harness": "claudeCode",          // 可选：默认绑定的 harness 文件夹名；缺省则只出现在自定义列表里
  "accent": "#E0785A",              // 主色，Crew 视图与 UI 会用
  "cell": 32,                       // 每帧正方形边长（像素）；32 或 48
  "anchor": "bottomCenter",
  "poses": {                        // 每个姿势：帧数 + fps；文件为横向单行帧条，宽 = cell × frames
    "idle": {"frames": 2, "fps": 2},
    "thinking": {"frames": 4, "fps": 4},
    "typing": {"frames": 6, "fps": 12},
    "writing": {"frames": 4, "fps": 6},
    "delegating": {"frames": 4, "fps": 6},
    "blocked": {"frames": 2, "fps": 2},
    "stale": {"frames": 2, "fps": 1},
    "ended": {"frames": 4, "fps": 6},
    "walkDown": {"frames": 4, "fps": 8}, "walkRight": {"frames": 4, "fps": 8}, "walkUp": {"frames": 4, "fps": 8},
    "spawn": {"frames": 4, "fps": 8}
  }
}
```
帧条规则见 §0.1：横向单行、无间距无边距、透明底、逐像素、**第 0 帧可单独当静态图**。缺哪个姿势 app 就退回程序占位，所以可以一只一只、一姿势一姿势地交。

**硬性要求（重复）：全部是非人类小生物，而且要抽象、简洁**——参照 Claude Code Buddy 的抽象度（几笔就是一只鸭/龙/幽灵：一个剪影 + 两颗眼 + 至多一个小特征），不要具象写实的解剖细节。可以有自己的小细节（一顶小帽、一撮呆毛、一条围巾），但**每只 ≤ 3 个辨识特征、≤ 6 种颜色、无渐变无毛发无鳞片**；如果一个特征要用超过 ~40 个像素才画得清，就是太具象了。

```
Claude Buddy 抽象度参考（它是 ASCII，我们是像素，但"几笔一只"的克制感一样）：
    __              /^\  /^\            .----.
  <(· )___        <  ·  ·  >          / ·  · \
   (  ._>          (   ~~   )         |      |
    `--´            `-vvvv-´          ~`~``~`~
    duck              dragon             ghost
```

每个 harness 一个固定物种 + 主色（Crew 视图的团子表情会沿用同一物种/主色/眼睛设定）：

| harness（全名） | 文件夹 / 默认 pet id | 主色 | 物种（抽象剪影） | 允许的 ≤3 个特征 |
|---|---|---|---|---|
| Claude Code | `claudeCode` / `claudeCode-dragon` | `#E0785A` | 圆团身体的小龙 | 头顶两个小尖角、身侧两片小翅膀 |
| Claude Cowork | `claudeCowork` / `claudeCowork-dragon` | `#CE8F6E` | 同款小龙（浅棕） | 同上 + 一条小围巾（浅色一横） |
| Codex | `codex` / `codex-robot` | `#2DD4BF` | 圆角方块小机器人 | 头顶一根天线 + 小球（球随状态变色） |
| ChatGPT Work | `chatgptWork` / `chatgptWork-robot` | `#22A06B` | 同款小机器人（绿） | 同上 + 胸口一颗方点 |
| Cursor | `cursor` / `cursor-cat` | `#4C8DFF` | 圆团小猫 | 两只尖耳、一条尾巴 |
| Grok Build | `grokBuild` / `grokBuild-slime` | `#F45FA0` | 史莱姆/团子 | 无四肢，只靠形变；眼睛偏大 |
| Grok Bot | `grokBot` / `grokBot-slime` | `#F98BBE` | 同款团子（浅粉） | 头顶一撮呆毛 |
| AntiGravity | `antigravity` / `antigravity-ghost` | `#B4E048` | 小幽灵 | 波浪下摆、悬浮 |

风格：可爱、圆润、**大眼睛占脸约 1/3**（深瞳 `#0F0F12` + 1 px 白高光；眼睛是主要表情通道）、可选两点腮红、小嘴一笔；平涂色块（主色 + 深一档描边 + 高光/腮红即可）；每只都要有清晰剪影，在 64 pt 大小下一眼分辨。cell 32×32，生物 ≤ 22×22 px，底边贴 cell 底边（bottom-center 锚点），左右各留 ≥ 5 px；**默认背对/侧背观众面向显示器**（看得出它在"看屏幕"），桌子与显示器由 app 画在生物上方，生物上方 8 px 不要画东西。**没有手就不画打字动作**——身体前倾、触角/翅膀/尾巴敲击等物种化动作表达"忙"。

| 文件 | 帧 | fps | 画什么（物种化表达） |
|---|---|---|---|
| `idle.png` | 2 | 2 | 趴着不动，眨一次眼 |
| `thinking.png` | 4 | 4 | 抬头看，眼睛左右转（不要人手托腮） |
| `typing.png` | 6 | 12 | 身体快速前后蹭 / 触角、翅膀、尾巴急速敲击 |
| `writing.png` | 4 | 6 | 节奏慢的敲击 + 面前一张小纸条 |
| `delegating.png` | 4 | 6 | 转向右侧，从身体里"分裂/吐出"一个小号同类 |
| `blocked.png` | 2 | 2 | **正对观众，眼睛瞪大**，身体抖动/跳一下（`!` 气泡 app 另画）——最醒目，先画 |
| `stale.png` | 2 | 1 | 眼睛半闭，脑袋一点一点 |
| `ended.png` | 4 | 6 | 缩小/淡出/变成一小团光飘走 |
| `walkDown/Right/Up.png`（可选） | 4 | 8 | 蹦跳/漂浮移动（走到工位 / 去休息区） |
| `spawn.png`（可选） | 4 | 8 | 从蛋/光点里出现（子 agent 出生） |

生成建议流程（用你手头的 imagegen 即可，不依赖任何现成 pet 工具）：① 每只先出一张 **基准立绘**（正面 + 背面各一，透明底，32×32 内）定物种/配色/眼睛；② 以基准图为参考逐姿势出横向帧条（每次只出一个姿势，帧数按表）；③ 用 `Scripts/validate_pet.py`（我会放进仓库：检查 cell 尺寸、帧数、透明底、无灰边、bottom-center 留白）校验；④ 出 contact sheet（所有姿势并排 + 4× 放大）我 QA。

### 4.1 开放自定义（app 侧我来做，格式以本节为准）
- Auspex 扫描 `~/.auspex/pets/` 与内置 `Resources/Pets/`，任何合法宠物包出现在 **Settings → Pets**；可按 harness 设默认宠物、也可给某个 session/项目单独指定；同 id 覆盖内置；无需重编/重启。
- 以后可以做一个 Auspex 自己的"孵蛋"流程（在 app 里点一下就用 imagegen 生成一只），格式还是这个。

## 5. 家具 / 地板 / 墙 tileset（`Resources/Tiles/office.png` + `office.json`，JSON 每项 `{name,x,y,w,h}`）
| name | 尺寸 | 备注 |
|---|---|---|
| `desk` | 48×24 | 桌面 3/4 俯视，木色，桌面中间上方留显示器位 |
| `deskSmall` | 32×20 | 子 agent 小桌 |
| `monitor` | 16×12 | **屏幕区域挖空透明**（内部 10×6，左上偏移 (3,2)），app 在下面填状态色/画面 |
| `keyboard` | 12×4 | |
| `chair` / `chairEmpty` | 16×16 | 有靠背朝上 / 空椅 |
| `sofa` | 48×32 | 休息区 |
| `coffeeTable` | 32×20 | |
| `bookshelf` | 32×48 | 靠墙 |
| `plant` | 16×24 | 盆栽 |
| `coffeeMachine` | 16×24 | |
| `printer` | 24×20 | writing 时可闪 |
| `whiteboard` | 48×24 | 挂墙，任务板（M3）用 |
| `door` | 16×32 | 房间入口 |
| `rug` | 48×32 | |
| `clock` | 16×16 | 挂钟底座（指针见 §7） |
| `floorWood` `floorTile` `floorCarpet` `floorStone` | 各 16×16 | **四方连续无缝** |
| `wallTop` | 16×24 | 房间上墙可见面 |
| `wallSide` | 4×16 | 左右墙边 |
| `wallCornerTL` `wallCornerTR` | 8×24 | |
| `roomLabelPlate` | 32×12 | 门牌底板（项目名 app 写字） |
| `deskNamePlate` | 24×8 | 桌前小名牌底板（app 写 harness 全名） |

---

## 6. 显示器画面 atlas（`Resources/Tiles/screens.png` + `screens.json`）
显示器挖空区 10×6 px 内的**画面动画**，按状态一条帧条（每帧 10×6，横向）：
| name | 帧 | fps | 画什么 |
|---|---|---|---|
| `screenIdle` | 2 | 1 | 深底 + 一格光标闪 |
| `screenThinking` | 4 | 4 | 蓝色点点依次亮（"…"） |
| `screenTyping` | 6 | 12 | 琥珀色代码行逐行滚动 |
| `screenWriting` | 4 | 6 | 绿色进度条推进 |
| `screenDelegating` | 4 | 4 | 紫色两个小对话框来回 |
| `screenBlocked` | 2 | 3 | 红底 + 白 `!` 闪 |
| `screenStale` | 1 | — | 屏保：暗底一颗慢闪像素 |
| `screenEnded` | 1 | — | 黑屏 |

---

## 7. 环境与特效 atlas（`Resources/Tiles/fx.png` + `fx.json`，全部横向帧条）
| name | cell | 帧 | fps | 用途 |
|---|---|---|---|---|
| `coffeeSteam` | 8×16 | 6 | 6 | 咖啡机/杯子冒气 |
| `plantSway` | 16×24 | 2 | 1 | 盆栽微动 |
| `clockHands` | 16×16 | 12 | 按分钟 | 挂钟指针 12 档 |
| `doorOpen` | 16×32 | 4 | 8 | 有人进出 |
| `printerWork` | 24×20 | 4 | 6 | writing 时纸张吐出 |
| `poof` | 24×24 | 6 | 12 | 会话结束角色消失 |
| `sparkle` | 24×24 | 6 | 12 | 子 agent 生成 |
| `keyDust` | 12×6 | 3 | 12 | 打字时键盘上小尘点 |
| `radarPing` | 16×16 | 8 | 8 | 侧栏 Live 指示 / 有新会话出现 |
| `windowLight` | 16×24 | 4 | 慢 | 墙上窗户昼夜光（可选） |

---

## 8. 气泡（`Resources/Tiles/bubbles.png` + `bubbles.json`）
| name | cell | 帧 | fps | 画什么 |
|---|---|---|---|---|
| `needsYou` | 24×24 | 2 | 3 | 白底圆角气泡 + 红 `!`，一大一小脉冲 |
| `note` | 24×20 | 2 | 2 | 紫色便签（delegating） |
| `zzz` | 24×20 | 3 | 2 | 灰 `z z z` 逐字浮现（stale） |
| `check` | 24×24 | 1 | — | 绿对勾（turn 完成一瞬） |
| `question` | 24×24 | 2 | 3 | `?`（权限询问） |
| `dots` | 24×20 | 3 | 4 | 思考中 `…` |

---

## 9. UI 小动画帧与空状态（`Resources/UI/`）
| 文件 | 规格 | 用途 |
|---|---|---|
| `emptyState.png` | 6 帧 96×64 @1x（另给 @2x 192×128）8 fps | 没有会话时：一个像素小人在空办公室喝咖啡等人 |
| `launch.png` | 8 帧 64×64 @2x 128×128，10 fps | 启动/首次扫描：眼睛睁开或小鸟落下 |
| `scanning.png` | 8 帧 24×24 @2x，8 fps | 正在扫描 harness 存储的小转圈（像素风） |
| `harnessOffline.png` | 静态 32×32 @2x | Harnesses 页"未检测到"插图 |
| `onboarding-hero.png` | 静态 480×320 @2x | 首次运行说明页插图（俯视办公室一角） |
（状态 pill 的呼吸/扫光/脉冲由代码做，不需要帧。）

---

## 10. 交付目录（最终形态）
```
Resources/
├── AppIcon.iconset/ (10 PNG)   AppIcon.png  AppIcon-rounded.png  AppIcon-{a,b,c}.png(概念)
├── AppIcon.layers/{light,dark,tinted}/{bg,glyph,highlight}.png
├── DocumentIcon.png  dmg-background.png  dmg-background@2x.png
├── MenuBar/ menubar.pdf menubar-alert.pdf menubar-off.pdf menubar-working.png menubar-alert.png
├── Icons/ <name>-{16,20,24}.svg + .pdf
├── Pets/<pet-id>/{pet.json, <pose>.png…}   （Auspex 宠物包格式，§4）
├── Tiles/ office.png office.json screens.png screens.json fx.png fx.json bubbles.png bubbles.json
└── UI/ emptyState.png launch.png scanning.png harnessOffline.png onboarding-hero.png
docs/art/ contact-<harness>.png ×8  contact-tiles.png  contact-fx.png  contact-icons.png  social-preview.png
```

## 11. 验收
- 宠物包丢进 `~/.auspex/pets/` 跑 Scene：`blocked`（needs you）在 1:1 下必须是全屏最抓眼元素；八只 1:1 一眼可分；`validate_pet.py` 通过；contact sheet 无裁切/无白底/无人形/无抗锯齿灰边。
- 图标：16/32 两档在浅/深色 Dock 与 Finder 列表里可辨；菜单栏 template 在浅/深菜单栏都清晰。
- 每个 atlas 的 JSON 与 PNG 尺寸一致，`columns = width/height` 成立。

## 12. 说明
- 现有 `docs/SPRITES.md` 是侧视版旧约定；改为宠物包后我会重写它与 `SpriteLibrary`（读取 `pet.json` + 姿势帧条），路径与姿势名不变，不影响出图。
