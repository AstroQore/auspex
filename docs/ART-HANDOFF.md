# Auspex 美术素材交接（给 Codex / imagegen 流水线）

> 目标：为 Auspex 的**俯视像素办公室（Scene 视图）**、App 图标、菜单栏图标生成一套可直接放进仓库的素材。
> 风格标杆：Pixel Agents 那种 3/4 俯视、温暖、干净的 16 位像素办公室；参考 `docs/screenshots/scene.png` 里当前的程序占位画面理解布局。
> 交付到：`auspex/Resources/Sprites/`（角色）、`auspex/Resources/Tiles/`（家具/地板/气泡）、`auspex/Resources/AppIcon.icns` + `Resources/AppIcon.png`、`auspex/Resources/MenuBarIcon.pdf`。**测试时可先丢到 `~/.auspex/sprites/`，app 优先读那里，不用重编。**

## 0. 通用硬规则（所有像素素材）

| 规则 | 值 |
|---|---|
| 视角 | **3/4 俯视**（Stardew / Pixel Agents 同款）：人物能看见头顶+脸/后脑+肩膀，家具能看见桌面 |
| 网格 | 16 px 基础网格；角色 cell 32×32；家具按 16 的倍数 |
| 像素 | **在最终分辨率上逐像素画**，最近邻缩放；不要抗锯齿、不要软阴影、不要渐变；1 px 深色描边 `#1A1A1E`（外描边），每个 sprite ≤ 14 色 |
| 背景 | 透明 PNG（straight alpha），**不烘焙投影**（app 自己画显示器光和地面影） |
| 光源 | 统一左上 |
| 帧 | 横向一行帧条，无间距无边距；`columns = width / height`；默认 8 fps；**第 0 帧必须是能单独当静态图的完整姿势**（Reduce Motion 只显示第 0 帧） |
| 命名 | 全小写 + 驼峰按下表；PNG + 同名可选 `.json`（`{"frameWidth":32,"fps":8}`） |
| 交付附件 | 每个 harness 一张 contact sheet（所有姿势并排 + 放大 4×）；家具一张总览；便于我 QA |

## 1. 角色 atlas（最重要，先做）

路径：`Resources/Sprites/<harness>/<variant>/<pose>.png`

**harness 文件夹名（严格）**：`claudeCode` · `codex` · `cursor` · `grokBuild` · `antigravity`
（可选加分：`chatgptWork` `claudeCowork` `geminiCLI`，先不做）

**variant**：先只做 `default`。（后续可加 `cli`（穿卫衣）/ `ide`（戴耳机），文件夹名就是 `cli` / `ide`。）

**每个 harness 一个"人"，用 harness 主色做上衣**（皮肤/发型/发色可各不相同，让 5 个人一眼能区分）：

| harness | 上衣主色 | 建议角色气质（可自由发挥，但保持这个色） |
|---|---|---|
| claudeCode | `#E0785A` 珊瑚 | 沉稳，卷发 |
| codex | `#2DD4BF` 青绿 | 利落，短发+眼镜 |
| cursor | `#4C8DFF` 蓝 | 年轻，鸭舌帽 |
| grokBuild | `#F45FA0` 品红 | 张扬，高马尾 |
| antigravity | `#B4E048` 黄绿 | 松弛，长发 |

**cell 32×32，人物约 14 宽 × 22 高，脚底贴 cell 底边（bottom-center 锚点）**，左右各留 ≥ 8 px 空。**默认坐姿朝上（背对观众、面向显示器）**，桌子和显示器由 app 画在人物上方，所以人物上方 8 px 不要画东西。

| 文件 | 帧数 | 画什么 |
|---|---|---|
| `idle.png` | 1–2 | 坐着不动，微微塌肩；可 2 帧眨眼（朝上看不到眼睛就 1 帧） |
| `thinking.png` | 3–4 | 坐着，头轻微左右摆 / 摸下巴，慢 |
| `typing.png` | 4–6 | 坐着，双手在键盘位置快速交替（fps 12） |
| `writing.png` | 4 | 坐着，一手写、一手扶纸，节奏慢于 typing |
| `delegating.png` | 4 | **站起来侧身向右**，手里递出一张便签（子 agent 会坐在右侧小桌） |
| `blocked.png` | 2 | **转身面向观众**，一只手举起来求助——最醒目的一个，先画 |
| `stale.png` | 2 | 坐着，头点着打盹（zzz 气泡 app 另画） |
| `ended.png` | 4 | 站起来朝右下走出画面（或 1 帧空椅子） |

可选加分：`walk-down.png` / `walk-right.png`（4 帧，M3 用来"走到工位"）。

## 2. 家具 / 地板 / 墙 tileset

路径：`Resources/Tiles/office.png`（一张 atlas）+ `Resources/Tiles/office.json`（每个 tile 的 `{name, x, y, w, h}`）。所有尺寸为像素、透明底、同一视角。

| name | 尺寸 | 备注 |
|---|---|---|
| `desk` | 48×24 | 桌面 3/4 俯视，木色；桌面中间上方留显示器位置 |
| `deskSmall` | 32×20 | 子 agent 用的小桌 |
| `monitor` | 16×12 | **屏幕区域挖空透明**（内部 10×6，左上偏移 (3,2)），app 在下面填状态色 |
| `keyboard` | 12×4 | |
| `chair` | 16×16 | 有靠背，朝上 |
| `chairEmpty` | 16×16 | 空椅（ended 用） |
| `sofa` | 48×32 | 休息区 |
| `coffeeTable` | 32×20 | |
| `bookshelf` | 32×48 | 靠墙 |
| `plant` | 16×24 | 盆栽 |
| `coffeeMachine` | 16×24 | |
| `door` | 16×32 | 房间入口 |
| `rug` | 48×32 | |
| `floorWood` / `floorTile` / `floorCarpet` / `floorStone` | 各 16×16 | **四方连续无缝** |
| `wallTop` | 16×24 | 房间上墙（可见墙面） |
| `wallSide` | 4×16 | 左右墙边 |
| `wallCornerTL` / `wallCornerTR` | 8×24 | |

## 3. 气泡（app 画在角色头顶）

路径：`Resources/Tiles/bubbles.png` + `bubbles.json`，每个是横向帧条：

| name | cell | 帧 | 画什么 |
|---|---|---|---|
| `needsYou` | 24×24 | 2 | 白底圆角气泡 + 红色 `!`（`#FF5C6C`），两帧一大一小做脉冲 |
| `note` | 24×20 | 2 | 紫色 `#B48CFF` 便签气泡（delegating） |
| `zzz` | 24×20 | 3 | 灰色 `z z z` 逐字浮现（stale） |
| `check` | 24×24 | 1 | 绿色对勾（turn 完成的一瞬间，可选） |
| `question` | 24×24 | 2 | `?`（M3 权限询问的另一种） |

## 4. App 图标

- `Resources/AppIcon.png` 1024×1024（我来转 `.icns`），macOS 26 圆角矩形（squircle）安全区内构图。
- 概念：**Auspex = 观鸟占卜的祭司**。给 3 个方向各 1 张，我选：
  1. 一只**眼睛**，虹膜里是一只极简像素鸟的剪影；深色底 `#101012`，珊瑚→琥珀（`#E0785A`→`#F2B544`）作为唯一高光。
  2. 深色圆角方块上一只**像素鸟**（8-bit，侧影，正在"看"），下方一条细的活动条（三段状态色 蓝/琥珀/绿）。
  3. **占卜杖（lituus）**弯钩线条 + 一个观测点，极简单色线稿版。
- 要求：不像素化整张图（图标是矢量感/平滑的，只有鸟可以是像素元素）；无文字；深色系为主，浅色桌面也能认。

## 5. 菜单栏图标

- `Resources/MenuBarIcon.pdf`（矢量，单色 template，18×18 pt 画布，线宽 1.5 pt）：与 App 图标同源的**眼睛**或**鸟**剪影，极简，能在 16 px 下认。
- 再给一份 `MenuBarIcon-alert.pdf`：同图 + 右上角小圆点（needs-you 状态叠加用；也可我用代码画，给了更好）。

## 6. 交付清单 & 验收

- [ ] `Resources/Sprites/{claudeCode,codex,cursor,grokBuild,antigravity}/default/{idle,thinking,typing,writing,delegating,blocked,stale,ended}.png`（40 个 PNG）+ 需要时的 `.json`
- [ ] `Resources/Tiles/office.png` + `office.json`
- [ ] `Resources/Tiles/bubbles.png` + `bubbles.json`
- [ ] `Resources/AppIcon.png`（3 个方向：`AppIcon-a.png` `AppIcon-b.png` `AppIcon-c.png`）
- [ ] `Resources/MenuBarIcon.pdf`（+ `-alert`）
- [ ] `docs/art/contact-<harness>.png` ×5、`docs/art/contact-tiles.png`
- 验收：我把 Sprites 丢进 `~/.auspex/sprites/` 跑 app 的 Scene 视图；`blocked` 在 1:1 缩放下必须是全屏最抓眼的元素；五个人在 1:1 下一眼分得清；无一处抗锯齿灰边（放大 8× 检查）。

## 7. 说明
- 现有 `docs/SPRITES.md` 是**侧视版**的旧约定（显示器在 cell 右侧）；本次改为俯视版后我会同步更新 `SPRITES.md` 与 `SpriteLibrary` 的锚点逻辑（人物上方留显示器位置），文件路径与命名不变。
- 你机器上的 `hatch-pet` skill（Codex pets 8×9 atlas 流水线）可以借它的"逐行姿势 prompt + contact sheet QA"方法，但输出格式按本文（横向单行帧条）。
