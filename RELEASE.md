# Ark Launcher · 发布说明

> 维护者记录（为什么要这样做、版本对照表、事故记录、发布前检查）在
> **[`RELEASE-MAINTENANCE.md`](RELEASE-MAINTENANCE.md)**。本文件只讲用户要的东西。

---

# 中文

在 HarmonyOS / OpenHarmony 上用**自建启动器**运行 Mindustry —— 内嵌 JDK、从 native
代码创建 JVM、把真正的 SDL3 窗口交给游戏，不套任何现成的模拟层。

⚠️ **非官方项目。** 与 Mindustry 及 Anuken 无隶属关系。以 **GPL-3.0** 分发
（构建产物再分发了 GPL-3.0 的 Mindustry）。

⛔ **本分支的包里没有游戏本体** —— 游戏由你自己提供（见 [README](README.md) 最上面那段）。
本项目的版本号与 **Mindustry 自己的**版本号是**两套体系**，各走各的。
⭐ 需要游戏本体时，请用**上游原版**：Anuken 在
[Anuken/Mindustry 的 Releases](https://github.com/Anuken/Mindustry/releases) 发布的那份 `.jar`
（桌面版，`v8 Build 160.5` 或更新）。启动器只读它的版本号，不改它。

## 下载哪个文件

| 文件 | 说明 |
|---|---|
| `ArkLauncher-<版本>-unsigned.hap` | **应用本体。** 未签名，需自签一次（见下）|
| `ArkLauncher-<版本>-payload.zip` | 载荷包。**只有要从源码构建才需要**，玩游戏不必下 |

## 怎么安装

⚠️ **未签名的 HAP 装不上** —— HarmonyOS 要求每个 `.hap` 先签名。

### 方法一：用安装工具（**不需要开发环境**，推荐）

| 工具 | 说明 |
|---|---|
| [**小白调试助手**](https://github.com/likuai2010/auto-installer/releases/latest) | 免费的跨平台鸿蒙调试工具，**签名 + 安装一步到位** |
| [**HoKit**](https://github.com/yabi-zzh/HoKit/releases/latest) | 一站式工具：**一键重签名**、设备投屏、性能监控、文件管理。支持 Windows / macOS / Linux |

本项目也收录在 **[Zitann/HarmonyOS-Haps](https://github.com/Zitann/HarmonyOS-Haps)**
（鸿蒙 Next HAP 安装包合集）的列表中。

### 方法二：用 DevEco Studio 自己签名

1. 用 DevEco Studio 打开本项目
2. **File → Project Structure → Signing Configs → Automatically generate signature**
3. `bash deploy.sh`

**本构建不声明那条「让沙箱可执行」的受限权限**
（`ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY`），
所以**平板和手机都只要一张自动生成的证书就能装**。

**而且在手机上它也能全速跑 —— 条件是鸿蒙 7 / API 26 及以上。** 调试签名 / 自签名用的 profile
会**临时解禁所有权限**（不管你声明了什么），Java 运行时因此拿得到 JIT 需要的内存 —— 实测确认：
第三方签名工具（小白调试助手，用它自己的 profile）在手机上一样拿到 JIT。
⚠️ **鸿蒙 5 / 6 没有这个机制**，应用商店渠道不可用；自签名安装**未验证**。
**这是手机唯一的安装途径**：应用市场里**没有手机包**，原因见下面「已知限制」。

⚠️ **上架应用市场用的是另一份产物**，由 `bash scripts/make_store_app.sh tablet` 生成：
它**会**声明那条权限，所以需要一份带 ACL 授权的 Release Profile ——
因为商店签名**不带**调试签名那个临时解禁。见
[BUILDING.md](docs/BUILDING.md) 的「ACL（受限权限）」。

### 只想装、不想构建

把下载的 HAP 放进 `entry/build/default/outputs/default/`，再跑 `bash deploy.sh`。

## 已验证

HarmonyOS 7 / API 26 真机验证：**HUAWEI MatePad Pro 12.2" 2025** 平板、
**HUAWEI Mate 80 Pro** 手机。

| 项目 | 状态 |
|---|---|
| 主菜单与渲染 | 移动端布局 |
| 音频 | OHAudio |
| 触屏 | 点击、长按、**双指捏合缩放** |
| 软键盘 | 点游戏里的输入框自动弹出，**接系统输入法 ⇒ 中文可打**；打字、退格、ESC 关闭正常 |
| 实体键盘 | WASD；ESC 打开菜单，**不被系统当作「返回」**；应用自己的输入框在屏幕上时**也能打中文** |
| 鼠标 | 全部按键 + 滚轮 |
| 悬浮球 | 拖动、吸附、半隐藏、点击恢复、位置持久化 |
| 沉浸模式 | 全屏（平板 / 手机）|
| 键盘不再遮挡输入框 | 键盘弹出时框架把游戏输入框推到可见位置 |
| 存档与数据导入导出 | 从「下载」目录往返 |
| 退出 | 正常关闭，不被系统标记为崩溃 |

### 本分支（`lite`）专有的两条

⭐ **2026-10-03 实测**，在同一台平板上，用**本分支自己构建并安装**的
`ArkLauncher-v1.3.0.1`（包名 `com.haohandc.arklauncher`，**与上游是另一个沙箱**）：

| 项目 | 证据 |
|---|---|
| **包里没有游戏** | `stderr.log` 里 `MISSING /data/storage/el1/bundle/libs/arm64/game/mindustry.so`；整包 178.3 MB 对上游的 263.1 MB |
| **玩家提供的那份被用上了** | `game jar: …/Download/com.haohandc.arklauncher/games/Mindustry160.5.jar  (chosen in the launcher)`，紧跟 `*** JVM CREATED ***`，随后 `[Mindustry] Version: 160.5` |

⚠️ **「第一次打开会停在启动器界面」**（见 [README](README.md) 顶部）是**由上面第一条推出的**，
不是单独测的 —— 那台设备上已经放着一个 jar，所以第一次打开直接进了游戏。
推导本身很直接（没有 jar ⇒ `resolveGame()` 返回 `none` ⇒ 界面拦住），但它是**推导**，记在这里。

## 已知限制

**完整的限制清单（附实测证据）在 [docs/LIMITATIONS.md](docs/LIMITATIONS.md)。**
这里只留**下载前就该知道的**：

**按设备**

| 设备 | 自签名安装 | 应用商店 |
|---|---|---|
| **平板** | 可用 | ACL 已获批，待 AppTest |
| **手机** | 部分可用（见下） | **不提供** |
| **PC · 2in1** | 未测试 | 未测试 |

- **手机为什么没有应用商店版本**：可执行内存权限（ACL，`ALLOW_WRITABLE_CODE_MEMORY`）**只向平板与 PC / 2in1 开放**。而 Java 的 JIT 需要该项能力。
- **手机为什么是「部分可用」**：取决于系统版本，见下。符合版本的手机上，自签名安装和平板一样。

**按系统版本**

- 本应用声明的最低版本是 **6.1.1（API 24）**，该下限**未实测**。
- **API 26（鸿蒙 7）起**：调试安装会**自动申请**受支持的 ACL 权限 ⇒ 手机自签名可用。
- **鸿蒙 5 / 6**：没有这个机制，能否自签名安装**请以实机结果为准**。

更多限制：

- ⚠️ **手机上自签名后「点开即退」？先换签名工具，别急着当 bug 报。**
  自签名能不能拿到 JIT，取决于**你签名用的 profile 是不是【调试】类型** ——
  **调试 profile 会临时解禁全部权限**，所以 JIT 可用（实测：小白调试助手在手机上正常，
  启动器报告 `probe=42`）。⚠️ 但**如果工具用的是非调试类型的 profile，应用就会「装得上、点开闪退」，
  而且不给任何线索**：没有 faultlog，沙箱日志也读不到，屏幕上也不会有提示。
  ⇒ **症状是这样，就换一个按调试 profile 签名的工具再试。**（这一条**只能这样描述**：
  失败时应用来不及说任何话，所以判据只有「换工具」这一个动作。）
- **没有成就，也没有创意工坊** —— 两者都是 **Steam 平台**的功能，Mindustry 本身不含。模组用游戏自带的浏览器导入，它**带有联网搜索**，只是不如创意工坊方便。
- ⚠️ **实体键盘在「应用自己的输入框不在屏幕上」时只能打 ASCII** ——
  **点一下游戏里的输入框**，让应用自己的输入框弹出（它接系统输入法），实体键盘**也能打中文**。
- **导入游戏数据后游戏会主动退出** —— 这是 Mindustry 的设计（用新数据重启），**看起来像崩溃但不是**。
- **只在上面那两台设备上验证过**，其他鸿蒙设备未测试。能否可用取决于平台对**可执行内存**的策略，
  策略不同的设备会以本项目无法预测的方式失败。

## 常见问题

完整 FAQ 是独立的一篇：**[docs/FAQ.md](docs/FAQ.md)**（双语 —— 中文段在前、英文段在后）。
放在这里会让三个文档说同一件事，所以只留最常被问的两条：

- **返回键好像没反应？** 返回键 = 游戏内的 **ESC**（退一层）；
  **主界面上 ESC 无处可去**，所以那里看起来没反应。有意为之。
  **退出请用游戏主菜单的 Quit。**
- **DevEco 报 `cppcrash`？** 那里混了**两件性质完全不同**的事，其中一件**不是崩溃**。
  ⚠️ 并且**别照报告里的函数名去查代码** —— 那两个位置经反汇编核对**都不是内存访问指令**。

## 从源码构建

```bash
unzip -o ArkLauncher-<版本>-payload.zip
bash deploy.sh          # 构建 + 校验 + 安装 + 启动 + 收日志
```

（签名按上面「怎么安装」配置）

## 版本历史

> [!NOTE]
> **下面这些条目是 `master` 的历史记录，原文照抄，未改。**
> 其中提到「包内自带的那一份」「随包的那一份」的地方，**在本分支（`lite`）上不成立** ——
> 本分支的包里没有游戏本体，游戏始终由你提供。除此之外的每一条都适用于本分支。

### 1.3.1.1 — 2026-10-03 · 整包导入导出与启动器界面

新增**整包导入 / 导出**：把一整套游戏数据打成一个 zip 带走或带回来。启动器的界面也在这一版重做 —— 加了进场动效、适配异形屏，底部导航栏换成系统的悬浮材质样式。

**新增**

| 项目 | 说明 |
|---|---|
| **整包导出** | 把某个版本的一整套游戏数据（存档、模组、蓝图、设置）打成一个 zip |
| **整包导入** | 选一个 zip 导入。⚠️ 导入前会**自动把现有数据备份一份** |
| **导出与备份的位置** | 都在 `Mindustry Ark/` 文件夹下，文件管理器里能找到；文件名带版本与时间 |
| **启动器进场动效** | 启动器的界面切换有了过渡 |
| **异形屏适配** | 启动器界面会避开挖孔与曲面边缘，可在「设置」里调整 |
| **底部导航栏** | 换成系统的悬浮材质底栏（沉浸光感） |

**变动**

| 项目 | 说明 |
|---|---|
| **存档的动作按钮** | 原来的一排按钮改为「删除 / 复制 / 移动」三个 |
| **应用名不再硬编码** | 「关于」卡片、诊断报告标题等处改为读取应用资源 |
| **诊断报告** | 标题下方不再多出一条分隔线 |
| **不带游戏运行时的包** | 若包里没有运行时，启动器会说明原因并让「启动游戏」不可用 —— 不再出现「点了没反应」的按钮 |

**修复**

| 问题 | 说明 |
|---|---|
| **「内置游戏」那一行缺守卫** | 在包里没有内置游戏时，那一行仍然显示 |
| **两个 C 函数从未被声明** | `setenv` 与 `pthread_getname_np` 一直靠 C99 已废弃的隐式声明编译通过 —— AArch64 上恰好能跑对，属于巧合而非保证。已补上声明，生成的机器码不变 |
| **SDL3 的类型声明与实际调用不符** | 声明 3 个参数、调用传 5 个。此前一直被增量编译缓存掩盖：**换一份干净克隆、或清一次缓存，构建就会失败** |

### 1.3.0.1 — 2026-10-03 · 版本隔离与存档管理

从本版本起，**每个游戏版本可以各用一套游戏数据**，并新增了**存档管理界面**。在此之前所有版本共用同一批存档：换一个 jar 看到的是同一份进度。隔离**默认关闭**，关闭时行为与之前一致。

**新增**

| 项目 | 说明 |
|---|---|
| **版本隔离** | 每个游戏版本各用一套游戏数据（存档、模组、蓝图、研究进度）。四档粒度：不隔离 / 大版本 / 构建号 / 小版本 |
| **存档管理** | 新增「存档」页：列出所有版本的存档并按「共用同一份数据」分组，可查看元数据（写入时的版本 / 地图 / 时长 / 模组清单） |
| **复制 / 移动存档** | 把存档在版本之间搬，或复制到多个目标。可多选。⚠️ 同版本再复制一份只对**手动存档**开放 |
| **垃圾站** | 删除不是抹掉 —— 搬进垃圾站，保留 3 / 7 / 30 天，或归档（永不自动清理）。随时可放回 |
| **多选删除** | 长按进入多选，一次删多个。删除前有确认框，列出选中的存档与它们各自的来源 |
| **启动模式** | 设置里可选「先显示启动器」或「直接进游戏」 |

**变动**

| 项目 | 说明 |
|---|---|
| **存档的可见性** | 开启隔离后，一个存档只对读取同一份数据的版本可见。默认（不隔离）不变 |
| **同版本的 jar 与内置游戏合并** | 版本号与内置那一致的 jar 共用内置那一份数据，不再各占一份。⚠️ 现有数据不会被覆盖 |
| **存档页的列表** | 「按存档」现在列出所有版本的存档；不含存档的目录也照样列出 |
| **版本名显示** | 版本号在前、文件名在后，例如 `v8 Build 160.5（内置游戏, Mindustry160.5.jar）` |

**修复**

| 问题 | 说明 |
|---|---|
| **换版本后存档「全都看不见」** | 隔离开着而当前版本那一档还是空的时候，只说「请把隔离关掉或重新打开一次」，没有可点的出口。现在就地给出复制按钮 |
| **存档列表滚不动** | 只能看到头两三组。列表一直没有任何可滚动的余量 |
| **「按版本」左侧列表竖直居中** | 版本少时停在屏幕中间，应当贴顶 |
| **手机比例下首页没铺满** | 内容宽度被一个固定值卡住，右边空出一条 |
| **「关于」窗缺一行** | 「上游」那一行的标签缺失，而它的样式接到了上一行，导致上一行的字号/颜色不对 |
| **点击已选中的存档无法取消** | 选中之后详情栏再也关不掉 |
| **多选时出现两个「删除」** | 一个是删勾选的一批、一个是删详情里那一个。多选态下后者不再显示 |
| **取消最后一项会退出多选** | 退出应当只由「取消」按钮负责 |

### 1.2.0.1 — 2026-10-02 · 自选游戏版本

从本版本起，**由你自己选择要加载哪个游戏版本**。启动器会显示一个游戏列表 —— 包内自带的那一份，加上你放进文件夹里的任意多个 jar —— 每一项都标出该文件自带的版本号。游戏本体仍然是**未经修改的上游原版**。

**新增**

| 项目 | 说明 |
|---|---|
| **自选游戏版本** | 可以同时放多个游戏 jar，在启动器里挑一个使用。在此之前只能用随包的那一份 |
| **显示每个 jar 的版本** | 版本号是从文件本身读出来的，不必靠文件名分辨 |
| **启动器界面** | 新增一屏用来管理游戏版本。默认每次启动先显示它 |
| **下拉刷新** | 在列表上往下拉即可重新扫描文件夹 |
| **启动模式** | 设置里可选「先显示启动器」或「直接进游戏」 |
| **启动失败时的说明** | 上一次没启动成功时，启动器会说明原因，并给出绕过这次判断的入口 |

**变动**

| 项目 | 说明 |
|---|---|
| **应用图标** | 换回原先那张 |
| **默认启动行为** | 从「直接进游戏」改为「先显示启动器界面」。可在设置里改回 |
| **「仍然尝试启动」** | 从常驻按钮改为只在启动失败时以弹窗出现 |

**修复**

| 问题 | 说明 |
|---|---|
| **选了不能玩的文件之后打不开** | 若选中的文件不能玩（例如误把模组当成游戏），以前每次打开都会立刻退出，而且**没有任何界面可以把它改回来**。现在会回到启动器界面并说明原因 |
| **全新安装的第一次启动说找不到文件夹** | 第一次打开会说读不到游戏文件夹，需要重启一次才好。现在第一次就正常 |

### 1.1.0.1 — 2026-09-29 · 架构更新

内嵌的游戏本体升级到上游 `v8 Build 160.5`，并改为**未经修改的上游原版**；启动器需要的适配代码独立成一份补丁，在游戏之前加载。

**变动**

| 项目 | 说明 |
|---|---|
| **内嵌游戏** | `160.4` → `160.5` |
| **游戏本体** | 改为上游原版，**未做任何修改** |
| **适配代码** | 从游戏本体中移出，独立成一份补丁 |

本版本**没有本项目自身的功能性改动**。

**修复**

以下是**上游 `160.5` 修的问题**（不是本项目修的），挑的是玩家能感觉到的部分；完整列表见上游发布页。

| 问题 | 说明 |
|---|---|
| **命中框极大的实体导致线程卡死** | 表现为卡顿或无响应 |
| **地图描述不换行** | 长描述挤成一行 |
| **逻辑处理器** | 超过 `Long.MAX_VALUE` 的十六进制 / 二进制数值无法解析；重启后图形与文本缓冲不清空；界面的形状文字标记无法选中 |
| **产出被增益时生产方块跟不上** | 输出速度不够 |
| **靶机** | 附近有大型命中框的靶机时无法降落 |
| **数据补丁** | 液体容量为 0 的方块不再显示液体条；图像现在会做边缘透明扩散与抗锯齿，和原版精灵图一致 |
| **服务器 / 模组** | 隐藏 UI 时某些弹窗仍然显示；模组浏览器现在会优先显示标题与当前游戏版本匹配的模组版本 |

### 1.0.0.2 — 2026-09-28 · 1.0.0 的 RC 2

已完整支持所有 Mindustry 原生功能。

**新增**

| 项目 | 说明 |
|---|---|
| **悬浮球 · 导出诊断** | 悬浮球菜单新增「导出诊断」，一键把运行日志导出到 `Download/Ark Launcher/diagnostics/`，方便反馈问题 |
| **崩溃报告自动导出** | 应用崩溃后，下次启动会自动把崩溃报告写到同一个 `diagnostics/` 文件夹 |

**变动**

| 项目 | 说明 |
|---|---|
| **应用图标** | 换为手绘图标 |
| **仓库首页** | 仓库首页改为中文，英文版在 `README.en.md` |

**修复**

| 问题 | 说明 |
|---|---|
| **开着「坚盾守护模式」时点开即退，且不给任何提示** | 该模式会禁止应用申请可执行内存，Java 虚拟机因此无法创建。此前表现为**无声退出** —— 没有提示、没有日志、屏幕上什么都不说。现在会说明原因，并给出关闭路径：设置 → 隐私和安全 → 坚盾守护模式 |

### 1.0.0.1 — 2026-09-22 · 1.0.0 的 RC 1

功能已冻结，之后只修阻断性问题。

**新增**

| 项目 | 说明 |
|---|---|
| **多人联机** | 局域网联机、搜索公网服务器、在本机开服 |
| **模组加载** | 支持 `.jar` / `.zip` 格式的模组。放进 `Download/Ark Launcher/`（真实路径 `Download/com.haohandc.arklauncher/`）|
| **悬浮球 · 关于** | 悬浮球菜单新增「关于」，可查看版本号与仓库地址 |

**变动**

| 项目 | 说明 |
|---|---|
| **文件夹权限** | 不再申请「下载」文件夹权限，改用应用自己创建的指定文件夹。详见「新增 · 模组加载」|

**修复**

| 问题 | 说明 |
|---|---|
| **模组导入入口过多** | 现在只有游戏自带的「导入模组」按钮。悬浮球菜单里的「导入模组」已移除（该入口未在已发布版本中出现过），应用也不再自动扫描文件夹 |
| **悬浮球菜单点击区域过小** | 每个选项原来只有约 19vp 高，且挨得很近；已放大并加上分隔 |

手机相关说明见上面「[已知限制](#已知限制)」。

### 0.2.0.2 — 2026-09-22 · 未单独发布

**变动**

| 项目 | 说明 |
|---|---|
| **版本名** | 改成纯数字和点（应用市场准入要求）|
| **隐私政策** | 新增 |

**修复**

| 问题 | 说明 |
|---|---|
| **屏幕键盘** | 三个问题：收起后弹回、输入框下方按钮被挡住、强杀重开时自弹 |

### 0.2.0-beta.1 — 2026-09-21 · 已发布

**新增**

| 项目 | 说明 |
|---|---|
| **悬浮球** | 可拖动、可半隐藏、菜单里能切换 PC / 触屏模式 |
| **沉浸模式** | 隐藏状态栏与导航栏，全屏游戏 |
| **屏幕键盘** | 中文可输入 |
| **返回键** | 退一层 UI（第一次当 ESC，不直接退出应用）|

### 0.1.0-beta.1 — 2026-09-20 · 首个可运行版本

自建启动器跑通：内嵌 JDK、从 native 创建 JVM、把真正的 SDL3 窗口交给游戏。

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

⛔ **This branch's package carries no game** — you supply it (see the top of the
[README](README.en.md)). This project's version number and the *game's* version number are
two independent things.
⭐ When you need the game itself, use the **upstream release**: the `.jar` Anuken publishes on
[Anuken/Mindustry's Releases](https://github.com/Anuken/Mindustry/releases) (desktop build,
`v8 Build 160.5` or newer). The launcher only reads its version number; it does not modify it.

## Which file to download

| File | What it is |
|---|---|
| `ArkLauncher-<version>-unsigned.hap` | **The app.** Unsigned — sign it once yourself (below) |
| `ArkLauncher-<version>-payload.zip` | Build inputs. **Only needed to build from source** |

## Installing

⚠️ **An unsigned HAP will not install** — HarmonyOS requires every `.hap` to be signed.

### Option 1: an installer tool (**no dev environment needed**, recommended)

| Tool | What it does |
|---|---|
| [**小白调试助手** (Auto-Installer)](https://github.com/likuai2010/auto-installer/releases/latest) | Free cross-platform HarmonyOS debugging tool — **signing and installing in one step** |
| [**HoKit**](https://github.com/yabi-zzh/HoKit/releases/latest) | All-in-one: **one-click re-signing**, device mirroring, perf monitoring, file management. Windows / macOS / Linux |

This project is also listed in **[Zitann/HarmonyOS-Haps](https://github.com/Zitann/HarmonyOS-Haps)**
(a HarmonyOS Next HAP collection).

### Option 2: sign it yourself with DevEco Studio

1. Open this project in DevEco Studio
2. **File → Project Structure → Signing Configs → Automatically generate signature**
3. `bash deploy.sh`

**This build does not declare the restricted permission that makes the sandbox
executable** (`ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY`), so **an
automatically generated certificate is sufficient to install it** — on a tablet
**or on a phone**.

**And on a phone it runs at full speed — provided the phone is on HarmonyOS 7 / API 26 or
later.** A debug / self-signed profile *temporarily unlocks every permission*, regardless of
what the package declares, so the Java runtime gets the memory its JIT needs — measured and
confirmed: a third-party signing tool (小白调试助手, with its own profile) gets the JIT on a phone.
⚠️ **HarmonyOS 5 / 6 has no such mechanism**, so the app store route is unavailable; a self-signed install is **untested**.
**This is the only route phones have**: there is **no phone package in the store**,
for the reason under "Known limitations" below.

⚠️ **The AppGallery submission is a different artifact**, built by
`bash scripts/make_store_app.sh tablet`. It **does** declare that permission, so it
needs a Release Profile carrying the matching ACL grant — a store signature does not
come with the debug unlock. See "ACL (restricted permissions)" in
[BUILDING.md](docs/BUILDING.md).

### Install only, without building

Drop the downloaded HAP into `entry/build/default/outputs/default/` and run `bash deploy.sh`.

## Verified

On a **HUAWEI MatePad Pro 12.2" 2025** tablet and a **HUAWEI Mate 80 Pro** phone, both
HarmonyOS 7 / API 26.

| Area | State |
|---|---|
| Menu and rendering | mobile layout |
| Audio | OHAudio |
| Touch | tap, long-press, **two-finger pinch zoom** |
| On-screen keyboard | appears on tapping a field in the game, **wired to the system input method ⇒ Chinese works**; backspace and ESC work |
| Physical keyboard | WASD; ESC opens the menu and is **not** treated as Back; **Chinese too** while the app's own field is up |
| Mouse | all buttons and the wheel |
| Floating ball | drag, snap, half-hide, tap to restore, position remembered |
| Immersive mode | full-screen (tablet and phone) |
| Keyboard no longer covers the field | the framework pushes the game's field clear |
| Save and data import/export | via the Download folder |
| Quitting | clean exit, not flagged as a crash |

### Two things only this branch (`lite`) has

⭐ **Measured 2026-10-03**, on the same tablet, from `ArkLauncher-v1.3.0.1` built and installed
by this branch (bundle `com.haohandc.arklauncher` — **a different sandbox from upstream**):

| Item | Evidence |
|---|---|
| **The package carries no game** | `MISSING /data/storage/el1/bundle/libs/arm64/game/mindustry.so` in `stderr.log`; 178.3 MB against upstream's 263.1 MB |
| **The copy the player supplies is what runs** | `game jar: …/Download/com.haohandc.arklauncher/games/Mindustry160.5.jar  (chosen in the launcher)`, followed by `*** JVM CREATED ***` and `[Mindustry] Version: 160.5` |

⚠️ **"The first launch stops at the launcher screen"** (top of the [README](README.en.md)) is
**derived** from the first row above, not measured on its own — the device had a jar in place, so
the first launch went straight into the game. The derivation is direct (no jar => `resolveGame()`
returns `none` => the screen stops it), but it is a derivation, and it is recorded as one.

## Known limitations

**The full list, with the measurements behind it, is in [docs/LIMITATIONS.md](docs/LIMITATIONS.md).**
Only what you should know *before downloading* is kept here:

**By device**

| Device | Self-signed install | App store |
|---|---|---|
| **Tablet** | Works | ACL approved; pending AppTest |
| **Phone** | Partial (see below) | **Not offered** |
| **PC · 2in1** | Untested | Untested |

- **Why there is no app store version for phones**: the executable-memory permission (ACL, `ALLOW_WRITABLE_CODE_MEMORY`) is granted to **tablets and PC / 2in1 only**. Java's JIT needs it.
- **Why a phone is "partial"**: it depends on the system version — see below. On a supported version, a self-signed install works the same as on a tablet.

**By system version**

- The app declares a minimum of **6.1.1 (API 24)**; that floor is **untested**.
- **From API 26 (HarmonyOS 7)**: a debug install is granted the supported ACL permissions **automatically** ⇒ a phone can install self-signed.
- **HarmonyOS 5 / 6**: no such mechanism; whether a self-signed install works **is untested — go by what the device does**.

More limitations:

- ⚠️ **Phone, self-signed, closes the instant you tap it? Change your signing tool before
  reporting a bug.** Whether a self-signed install gets the JIT depends on **whether the profile
  you sign with is a DEBUG one** — a debug profile *temporarily unlocks every permission*, so the
  JIT works (measured: 小白调试助手 is fine on a phone; the launcher reports `probe=42`).
  ⚠️ But if the tool signs with a non-debug profile, the app **installs and closes on launch with
  no clues at all**: no faultlog, the sandbox logs are unreadable, and nothing appears on screen.
  ⇒ **If that is your symptom, re-sign with a tool that uses a debug profile.**
  (This is the only way the problem *can* be described: the app never gets far enough to say
  anything, so the only available action is "try another tool".)
- **No achievements and no Steam Workshop** — both are **Steam-platform** features rather than part of the game. Mods are imported with the game's own browser, which **includes online search**; it is just less convenient than the Workshop.
- ⚠️ **A physical keyboard is ASCII-only while the app's own text field is NOT on screen** —
  **tap a text field in the game** so the app's own field comes up (it is wired to the system
  input method) and the physical keyboard **types Chinese too**.
- **Importing game data makes the game exit on purpose**, so it restarts with the new data.
  It looks like a crash and is not one.
- **Verified on those two devices only.** Whether it works elsewhere depends on the platform's
  policy on executable memory, and a device that enforces it differently would fail in ways
  this project has no way to predict.

## FAQ

The full FAQ is its own document: **[docs/FAQ.md](docs/FAQ.md)** (bilingual — Chinese
section first, then English). Keeping it here too would have three documents saying the
same thing, so only the two most-asked ones stay:

- **Back does nothing?** Back is the game's **ESC** ("up one level");
  **on the main menu ESC has nowhere to go**, so it looks dead there. Deliberate.
  **To quit, use Quit on the game's main menu.**
- **DevEco reports `cppcrash`?** That conflates **two completely different things**, one of
  which is **not** a crash. ⚠️ And **do not go looking for code based on the function names
  in that report** — disassembly shows those two frames are **not memory accesses at all**.

## Building from source

```bash
unzip -o ArkLauncher-<version>-payload.zip
bash deploy.sh          # build + verify + install + launch + collect log
```

(configure signing as under "Installing")

## Changelog

> [!NOTE]
> **These entries are `master`'s history, copied verbatim.** Where they mention a
> copy of the game being inside the package, **that does not hold on this branch
> (`lite`)** — this branch ships no game, and you always supply it. Every other
> entry applies here too.


### 1.1.0.1 — 2026-09-29 · architecture

The embedded game is updated to upstream `v8 Build 160.5` and is now the **unmodified upstream
release**; the adaptation code the launcher needs was moved out into a patch of its own, which
loads ahead of the game.

**Changed**

| Item | Notes |
|---|---|
| **Embedded game** | `160.4` → `160.5` |
| **The game binary** | Now the upstream release, **modified in no way** |
| **The adaptation code** | Moved out of the game binary into a patch of its own |

This version has **no functional changes of this project's own**.

**Fixed**

These are **fixes in upstream `160.5`** (not made by this project); the ones a player is likely
to notice. The full list is on the upstream release page.

| Problem | Notes |
|---|---|
| **Entities with extremely large hitboxes freezing a thread** | Shows up as a stall or an unresponsive game |
| **Map descriptions not wrapping** | Long descriptions crammed onto one line |
| **Logic processors** | Hex / binary values above `Long.MAX_VALUE` would not parse; the graphics and text buffers did not clear on restart; the shape text marker could not be selected in the logic UI |
| **Crafters lagging when their output is boosted** | They could not output fast enough |
| **Target dummies** | Would not land when other dummies with large hitboxes were nearby |
| **Data patches** | Blocks with 0 liquid capacity no longer draw liquid bars; images now get alpha bleeding and antialiasing, matching how vanilla sprites are processed |
| **Servers / mods** | Certain popups still showed on servers while the UI was hidden; the mod browser now prioritises mod releases whose title matches the current game version |

### 1.0.0.2 — 2026-09-28 · RC 2 of 1.0.0

Full support for all of Mindustry's native features.

**Added**

| Item | Notes |
|---|---|
| **Floating ball · Export diagnostics** | A new row in the floating ball's menu writes the run logs to `Download/Ark Launcher/diagnostics/`, to make reporting a problem easier |
| **Crash reports export themselves** | After a crash, the next launch writes the crash report to the same `diagnostics/` folder automatically |

**Changed**

| Item | Notes |
|---|---|
| **App icon** | Replaced with a hand-drawn icon |
| **Repository front page** | The repository README is now Chinese; the English one is `README.en.md` |

**Fixed**

| Problem | Notes |
|---|---|
| **Closes on launch with no message while Secure Shield Mode is on** | That mode forbids the app anonymous executable memory, so the Java VM cannot be created. It used to die silently — no message, no log, nothing on screen. It now states the reason and names the setting to turn off: Settings → Privacy and security → Secure Shield Mode |

### 1.0.0.1 — 2026-09-22 · RC 1 of 1.0.0

Features are frozen; only blocking fixes from here.

**Added**

| Item | Notes |
|---|---|
| **Multiplayer** | LAN games, the public server list, and hosting on the device |
| **Mod loading** | `.jar` and `.zip` mods. Put them in `Download/Ark Launcher/` (real path `Download/com.haohandc.arklauncher/`) |
| **Floating ball · About** | A new "About" entry in the floating ball's menu, showing the version and the repository address |

**Changed**

| Item | Notes |
|---|---|
| **Folder permission** | No longer requests permission for the system Download folder; uses an app-created folder instead. See "Added · Mod loading" |

**Fixed**

| Problem | Notes |
|---|---|
| **Too many ways to import a mod** | There is now only the game's own "import mod" button. The floating ball's "导入模组" has been removed (that entry never appeared in a released version), and the app no longer scans the folder by itself |
| **The floating ball's menu options were too small to tap** | Each row was about 19 vp tall and the rows were close together; they are now larger and separated |

Phones are covered under "[Known limitations](#known-limitations)" above.

### 0.2.0.2 — 2026-09-22 · not released on its own

**Changed**

| Item | Notes |
|---|---|
| **Version name** | Now digits and dots only (required for store admission) |
| **Privacy policy** | Added |

**Fixed**

| Problem | Notes |
|---|---|
| **On-screen keyboard** | Three problems: it bounced back after being dismissed, it covered the buttons under the text field, and it opened by itself after a force-stop |

### 0.2.0-beta.1 — 2026-09-21 · released

**Added**

| Item | Notes |
|---|---|
| **Floating ball** | Draggable, half-hides itself, and its menu switches PC / touch mode |
| **Immersive mode** | Hides the status and navigation bars for full-screen play |
| **On-screen keyboard** | Chinese input works |
| **Back key** | Goes up one level (ESC first; it does not quit the app) |

### 0.1.0-beta.1 — 2026-09-20 · first runnable version

The self-built launcher works end to end: embedded JDK, a JVM created from native code, and a
real SDL3 window handed to the game.

## Credits and licences

Mindustry and Arc by **Anuken**; windowing, input and audio **SDL3**; JNI bindings **LWJGL**;
runtime **OpenJDK 21**. Per-component terms: [`THIRD-PARTY.md`](THIRD-PARTY.md).

Most of the code here was written with AI assistance (Claude via Cherry Studio,
deepseek-flash v4.1).
