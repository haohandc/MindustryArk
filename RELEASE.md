# Mindustry Ark · 发布说明

> 维护者记录（为什么要这样做、版本对照表、事故记录、发布前检查）在
> **[`RELEASE-MAINTENANCE.md`](RELEASE-MAINTENANCE.md)**。本文件只讲用户要的东西。

---

# 中文

在 HarmonyOS / OpenHarmony 上用**自建启动器**运行 Mindustry —— 内嵌 JDK、从 native
代码创建 JVM、把真正的 SDL3 窗口交给游戏，不套任何现成的模拟层。

⚠️ **非官方项目。** 与 Mindustry 及 Anuken 无隶属关系。以 **GPL-3.0** 分发
（构建产物再分发了 GPL-3.0 的 Mindustry）。

内嵌的游戏版本：**Mindustry `v8 Build 160.4`**（游戏内显示 `release build 160.4`）。
⚠️ 这是 **Mindustry 自己的**版本号，与本项目的版本号是**两套体系**，各走各的。

## 下载哪个文件

| 文件 | 说明 |
|---|---|
| `MindustryArk-<版本>-unsigned.hap` | **应用本体。** 未签名，需自签一次（见下）|
| `MindustryArk-<版本>-payload.zip` | 载荷包。**只有要从源码构建才需要**，玩游戏不必下 |

## 怎么安装

⚠️ **未签名的 HAP 装不上** —— HarmonyOS 要求每个 `.hap` 先签名。

用**你自己的**证书签一次：

1. 用 DevEco Studio 打开本项目
2. **File → Project Structure → Signing Configs → Automatically generate signature**
3. `bash deploy.sh`

⭐ **本项目不申请任何受限权限**（没有需要向 AppGallery Connect 申请的 ACL 权限），
所以**自动生成的证书就够了**，不必去申请任何东西。

> 只安装、不自己构建也可以：把下载的 HAP 放进 `entry/build/default/outputs/default/`
> 再跑 `bash deploy.sh`。

## 已验证

HarmonyOS 7 / API 26 真机验证：**HUAWEI MatePad Pro 12.2" 2025** 平板、
**HUAWEI Mate 80 Pro** 手机。

| 项目 | 状态 |
|---|---|
| 主菜单与渲染 | ✅ 移动端布局 |
| 音频 | ✅ OHAudio |
| 触屏 | ✅ 点击、长按、**双指捏合缩放** |
| 软键盘 | ✅ 点输入框自动弹出；打字、退格、ESC 关闭正常 |
| 物理键盘 | ✅ WASD；ESC 打开菜单，**不被系统当作「返回」** |
| 鼠标 | ✅ 全部按键 + 滚轮 |
| 悬浮球 | ✅ 拖动、吸附、半隐藏、点击恢复、位置持久化 |
| 沉浸模式 | ✅ 全屏（平板 / 手机）|
| 键盘不再遮挡输入框 | ✅ 键盘弹出时框架把游戏输入框推到可见位置 |
| 存档与数据导入导出 | ✅ 从「下载」目录往返 |
| 退出 | ✅ 正常关闭，不被系统标记为崩溃 |

## 已知限制

- ⚠️ **软键盘只能输入 ASCII —— 打不了中文。** 游戏侧走的是自建文本通道，没有接系统输入法候选。
- ⚠️ **PC / 触屏模式切换需要重启应用才生效。** 不是缺陷：Mindustry 的输入层和 UI 都派生自
  一个**启动时写入**的值，中途改会让两者不一致。游戏内自带的「鼠标 + 键盘操控」开关可即时切换操控方式。
- ⚠️ **2in1（PC）上沉浸模式不生效**，状态栏和导航条会留着。平板和手机正常。
- **游戏内的文件浏览器用的是 Mindustry 自带**的兜底实现（Arc 的文件对话框库是 glibc 链接，鸿蒙加载不了）。
- **导入游戏数据后游戏会主动退出** —— 这是 Mindustry 的设计（用新数据重启），**看起来像崩溃但不是**。
- ⛔ **没有多人联机、没有成就、没有模组浏览器**（与桌面版相比）。
- **只在上面那两台设备上验证过**，其他鸿蒙设备未测试。这取决于平台对可执行内存的策略，
  策略不同的设备会以本项目无法预测的方式失败。

## 从源码构建

```bash
unzip -o MindustryArk-<版本>-payload.zip
bash deploy.sh          # 构建 + 校验 + 安装 + 启动 + 收日志
```

（签名按上面「怎么安装」配置）

## 致谢与许可

Mindustry 与 Arc 由 **Anuken** 开发；窗口 / 输入 / 音频层 **SDL3**；JNI 绑定 **LWJGL**；
运行时 **OpenJDK 21**。逐组件条款见 [`THIRD-PARTY.md`](THIRD-PARTY.md)。

本仓库大部分代码由 AI 辅助完成（Claude via Cherry Studio，deepseek-flash v4.1）。

---

# English

Run Mindustry on HarmonyOS / OpenHarmony with a **self-built launcher** — an embedded JDK,
a JVM created from native code, and a real SDL3 window handed to the game. No existing
emulation layer involved.

⚠️ **Unofficial.** Not affiliated with, endorsed by, or supported by the Mindustry project
or Anuken. Distributed under **GPL-3.0** (the build redistributes GPL-3.0 Mindustry).

Embedded game version: **Mindustry `v8 Build 160.4`** (in-game: `release build 160.4`).
⚠️ That is the *game's* version, not this project's — the two move independently.

## Which file to download

| File | What it is |
|---|---|
| `MindustryArk-<version>-unsigned.hap` | **The app.** Unsigned — sign it once yourself (below) |
| `MindustryArk-<version>-payload.zip` | Build inputs. **Only needed to build from source** |

## Installing

⚠️ **An unsigned HAP will not install** — HarmonyOS requires every `.hap` to be signed.

Sign it once with **your own** certificate:

1. Open this project in DevEco Studio
2. **File → Project Structure → Signing Configs → Automatically generate signature**
3. `bash deploy.sh`

⭐ **This project requests no restricted permission** (no ACL permission requiring an
AppGallery Connect application), so **an automatically generated certificate is
sufficient**.

> To install without building: drop the downloaded HAP into
> `entry/build/default/outputs/default/` and run `bash deploy.sh`.

## Verified

On a **HUAWEI MatePad Pro 12.2" 2025** tablet and a **HUAWEI Mate 80 Pro** phone, both
HarmonyOS 7 / API 26.

| Area | State |
|---|---|
| Menu and rendering | ✅ mobile layout |
| Audio | ✅ OHAudio |
| Touch | ✅ tap, long-press, **two-finger pinch zoom** |
| On-screen keyboard | ✅ appears on tap; typing, backspace and ESC all work |
| Physical keyboard | ✅ WASD; ESC opens the menu and is **not** treated as Back |
| Mouse | ✅ all buttons and the wheel |
| Floating ball | ✅ drag, snap, half-hide, tap to restore, position remembered |
| Immersive mode | ✅ full-screen (tablet and phone) |
| Keyboard no longer covers the field | ✅ the framework pushes the game's field clear |
| Save and data import/export | ✅ via the Download folder |
| Quitting | ✅ clean exit, not flagged as a crash |

## Known limitations

- ⚠️ **The on-screen keyboard is ASCII-only** — Chinese input does not work. It goes through
  a hand-rolled text path rather than the platform IME.
- ⚠️ **The PC / touch mode switch needs an app restart.** Not a defect: Mindustry derives
  both its input layer and its UI from one value written at **startup**, and changing it
  midway would leave the two disagreeing. Mindustry's own "mouse + keyboard control" toggle
  changes the controls immediately.
- ⚠️ **Immersive mode does not apply on 2in1** (PC); the bars stay. Tablet and phone are unaffected.
- **The in-game file browser is Mindustry's own fallback** — Arc's file-dialog native is
  glibc-linked and cannot load here.
- **Importing game data makes the game exit on purpose**, so it restarts with the new data.
  It looks like a crash and is not one.
- ⛔ **No multiplayer, achievements or mod browser**, compared with the desktop release.
- **Verified on those two devices only.** This depends on the platform's policy on
  executable memory, and a device that enforces it differently would fail in ways this
  project has no way to predict.

## Building from source

```bash
unzip -o MindustryArk-<version>-payload.zip
bash deploy.sh          # build + verify + install + launch + collect log
```

(configure signing as under "Installing")

## Credits and licences

Mindustry and Arc by **Anuken**; windowing, input and audio **SDL3**; JNI bindings **LWJGL**;
runtime **OpenJDK 21**. Per-component terms: [`THIRD-PARTY.md`](THIRD-PARTY.md).

Most of the code here was written with AI assistance (Claude via Cherry Studio,
deepseek-flash v4.1).
