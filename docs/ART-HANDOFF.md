# Auspex 美术素材交接（给 Codex / imagegen 流水线）

> **优先级**：§4 角色 atlas（先 `blocked`）→ §5 家具 → §8 气泡 → §6 显示器画面 → §1 App 图标 → §2 菜单栏 → §3 应用内图标 → §7 特效 → §9 UI 动画/空状态 → §1.4 衍生物料。
> 目标：一次性产出 Auspex 需要的全部视觉素材——**图标包**（App 图标全尺寸 + 分层源 + 菜单栏 + 应用内图标集）、**俯视像素办公室**（角色 / 家具 / 地板 / 显示器画面 / 环境与特效 atlas / 气泡）、**UI 小动画帧**、**空状态与发布物料**。
> 风格标杆：Pixel Agents 那种 3/4 俯视、温暖干净的 16 位像素办公室；UI 面是深色克制的 macOS 原生风。当前程序占位画面见 `docs/screenshots/scene.png`、`board.png`。
> 交付根目录：`auspex/Resources/`（结构见 §9）。**测试时角色/家具可先丢到 `~/.auspex/sprites/`，app 优先读那里，不用重编。**

---

## 0. 通用硬规则

### 0.1 像素类（角色、家具、显示器画面、气泡、特效、空状态动画）
| 规则 | 值 |
|---|---|
| 视角 | **3/4 俯视**（Stardew / Pixel Agents 同款）：人物看见头顶+脸/后脑+肩膀，家具看见桌面 |
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
- **Harness 标识一律用厂商真 logo**，源文件已放在 `auspex/Resources/ProviderIcons/`（复用 vibe-bar 资产，单色 SVG，app 按上表主色着色）：`ProviderIcon-claude.svg`（Claude Code / Claude Cowork）· `ProviderIcon-codex.svg`（OpenAI 花，Codex / ChatGPT Work）· `ProviderIcon-cursor.svg` · `ProviderIcon-grok.svg`（Grok Build / Grok Bot）· `ProviderIcon-antigravity.svg` · `ProviderIcon-gemini.svg`。同一 logo 的两个 harness 靠**全名文字 + 主色**区分，不靠改 logo。

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

**Harness 标识：不需要新画**——直接用 `Resources/ProviderIcons/*.svg` 的厂商 logo（见 §0.3）。如需，只补一件事：把 6 个 SVG 各出一版 **16 / 20 / 24 pt 光学对齐的 PDF**（描边/填充按原样，单色，template），命名 `ProviderIcon-<name>-{16,20,24}.pdf`。

**状态**：`state-thinking`（虚线圆/呼吸环）`state-tool`（提示符 `›_`）`state-writing`（笔）`state-delegating`（分叉箭头 ↳）`state-needsYou`（感叹号气泡）`state-idle`（暂停/圆点）`state-stale`（zzz）`state-ended`（方块/离席）

**导航与视图**：`nav-live` `nav-projects` `nav-tasks` `nav-harnesses` `nav-settings` `view-board` `view-scene` `view-timeline` `group-by` `filter` `search` `follow`（跟随最新）

**动作**：`action-terminal` `action-editor` `action-finder` `action-pr` `action-copy` `action-open-external` `action-jump-parent` `action-jump-child`

**Trace 行类型**：`trace-prompt`（❯）`trace-text`（¶）`trace-thinking` `trace-tool` `trace-subagent` `trace-permission` `trace-usage`（Σ）`trace-compaction` `trace-liveness`

**其它**：`tree-child`（↳）`tree-parent`（↑）`badge-live` `badge-children` `empty-eye`（空状态大图标 48 pt）

---

## 4. 角色 atlas（场景核心，最先做）

路径：`Resources/Sprites/<harness>/<variant>/<pose>.png`
harness 文件夹名（严格，这是代码里的枚举原值，仅用于路径）：`claudeCode` `claudeCowork` `codex` `chatgptWork` `cursor` `grokBuild` `grokBot` `antigravity`（可选 `geminiCLI`）；variant 先只做 `default`（后续可加 `cli` 卫衣版 / `ide` 耳机版）。**界面上任何地方展示的都是全名**（Claude Code、Claude Cowork、Codex、ChatGPT Work、Cursor、Grok Build、Grok Bot、AntiGravity），不出现缩写。

每个 harness 一个"人"，上衣用 harness 主色，皮肤/发型各异让 8 人一眼可分；同门的两位（Claude Code / Claude Cowork，Codex / ChatGPT Work，Grok Build / Grok Bot）保持家族相似但可区分（例如同发型不同配饰）：
| harness（全名） | 文件夹 | 上衣 | 建议气质 |
|---|---|---|---|
| Claude Code | `claudeCode` | `#E0785A` | 沉稳，卷发 |
| Claude Cowork | `claudeCowork` | `#CE8F6E` | 与 Claude Code 同发型，戴围巾/工牌 |
| Codex | `codex` | `#2DD4BF` | 利落，短发+眼镜 |
| ChatGPT Work | `chatgptWork` | `#22A06B` | 与 Codex 同发型，穿马甲 |
| Cursor | `cursor` | `#4C8DFF` | 年轻，鸭舌帽 |
| Grok Build | `grokBuild` | `#F45FA0` | 张扬，高马尾 |
| Grok Bot | `grokBot` | `#F98BBE` | 与 Grok Build 同发型，戴耳麦（它是聊天机器人，没有代码工位感也没关系） |
| AntiGravity | `antigravity` | `#B4E048` | 松弛，长发 |

cell 32×32，人物约 14 宽 × 22 高，脚底贴 cell 底边（bottom-center 锚点），左右各留 ≥ 8 px；**默认坐姿朝上（背对观众、面向显示器）**，桌子与显示器由 app 画在人物上方，人物上方 8 px 不要画东西。

| 文件 | 帧 | fps | 画什么 |
|---|---|---|---|
| `idle.png` | 1–2 | 2 | 坐着不动，微塌肩；可 2 帧眨眼 |
| `thinking.png` | 3–4 | 4 | 坐着，头轻微左右摆 / 摸下巴 |
| `typing.png` | 4–6 | 12 | 坐着，双手在键盘位快速交替 |
| `writing.png` | 4 | 6 | 坐着，一手写一手扶纸 |
| `delegating.png` | 4 | 6 | **站起来侧身向右**，递出便签（子 agent 坐右侧小桌） |
| `blocked.png` | 2 | 2 | **转身面向观众**，一只手举起——最醒目，先画 |
| `stale.png` | 2 | 1 | 坐着点头打盹 |
| `ended.png` | 4 | 6 | 站起来朝右下走出画面（或 1 帧空椅） |
| `walkDown.png` `walkRight.png` `walkUp.png`（可选） | 4 | 8 | 走路，M3 用于"走到工位/去休息区" |
| `spawn.png`（可选） | 4 | 8 | 子 agent 出现：从无到有的小闪现 |

---

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
├── Sprites/<harness>/default/<pose>.png (+ .json)
├── Tiles/ office.png office.json screens.png screens.json fx.png fx.json bubbles.png bubbles.json
└── UI/ emptyState.png launch.png scanning.png harnessOffline.png onboarding-hero.png
docs/art/ contact-<harness>.png ×8  contact-tiles.png  contact-fx.png  contact-icons.png  social-preview.png
```

## 11. 验收
- Sprites 丢进 `~/.auspex/sprites/` 跑 Scene：`blocked` 在 1:1 下必须是全屏最抓眼元素；八个人 1:1 一眼可分；放大 8× 无一处抗锯齿灰边。
- 图标：16/32 两档在浅/深色 Dock 与 Finder 列表里可辨；菜单栏 template 在浅/深菜单栏都清晰。
- 每个 atlas 的 JSON 与 PNG 尺寸一致，`columns = width/height` 成立。

## 12. 说明
- 现有 `docs/SPRITES.md` 是侧视版旧约定；改俯视后我会同步更新它与 `SpriteLibrary` 锚点逻辑（人物上方留显示器位置），路径命名不变，不影响出图。
- 你机器上的 `hatch-pet` skill（Codex pets 8×9 atlas 流水线）可借用其"逐姿势 prompt + contact sheet QA"方法，但输出格式按本文（横向单行帧条 + JSON）。
