# 已知限制 · MindustryArk

[← 返回 README](../README.zh-CN.md) · [← Back to README](../README.md)

> 这些是**已知且有意保留**的行为，不是待修的缺陷清单。
> 频繁问到的问题另见 **[FAQ.md](FAQ.md)**。

---
# 中文

- **文字输入，以及两条路各自能做什么。** 点游戏里的输入框（存档名、蓝图名、导出时的文件名），
  应用会**自己弹出一个输入框**并接上系统输入法 ⇒ **软键盘出现、可用输入法组合，中文也能打**。
  实体键盘同样可用，**能打什么取决于焦点在哪**：
    - **我们的输入框在屏幕上时**，键盘也走系统输入法 ⇒ **实体键盘同样能打中文**；
    - **不在时**，键盘直接交给游戏、走 SDL 的「按键→字符」通路 ⇒ **只支持 ASCII**。
  焦点只有一个，所以只有这两种状态。
  - **两条路并存，是因为 SDL 自己的输入法通路在这里根本走不通。**
    本进程把 `libSDL3.so` **映射了两次**，ArkTS 把输入法 controller 交给了**不跑游戏的那一份**，
    而 `napi_ref` 无法跨这两份搬移 ⇒ SDL 永远弹不出键盘。取而代之的做法：
    应用**监听游戏要文字的请求**（通过文件）、弹出一个 ArkUI `TextInput`，
    再把用户输入**喂回 SDL 的文本事件队列**。
    代码在 `SDL_openharmony.c`、`SDL_openharmonyevents.c` 与 `ets/pages/Index.ets`。
  - **一处粗糙之处，直说**：应用读不到游戏输入框的**光标位置**，所以发的是与
    「它认为输入框已有内容」的**差**。**在末尾打字与退格是精确的**；
    **在中间插入/修改**会被「撤回重发」方式修复 —— 结果正确，但那段字会在屏幕上**重打一遍**。
- **桌面/移动模式无法在运行期切换**：模式在启动时固定。Mindustry 游戏内自带
  「鼠标 + 键盘操控」开关，能覆盖大部分同类需求。切换方式见 [FAQ.md](FAQ.md)。
- `libarc-filedialogsarm64.so` 链接的是 **glibc**，本平台加载不了，
  因此 Arc 回退到 Mindustry **自带的游戏内文件浏览器**。这也是浏览器根目录必须重定向到「下载」的原因。
- **导入游戏数据后游戏会主动退出**（`Core.app.exit()`），以便用新数据重启。
  **这看起来像崩溃，但不是。**
- **目前验证了两台设备**：**MatePad Pro 12.2" 2025** 平板与 **Mate 80 Pro** 手机，均为 HarmonyOS 7 / API 26。
  其他设备**未测试** —— 本项目依赖平台对「可执行内存」的策略，
  若某设备在这点上做法不同，出错方式我们无法预判。
- **`2in1`（PC）上沉浸模式不生效** —— 任务栏与窗口标题栏会留着。
  这是平台限制，不是没做。**实测确认**。功能不受影响：悬浮球在 PC 上**能正常隐藏**。
- ⚠️ **每次正常退出时，`hiview/AppKilledReporter` 都会打一条 `reason: CppCrash`。
  它不是崩溃，也归不到本应用头上 —— 你看到的就是这行，不必惊慌。**
  游戏内点 Quit 正常退出时实测，同一个 5 毫秒窗口内：

  | 组件 | 结论（带归属信息） |
  |---|---|
  | `AppMS` | `Kill Reason: app exit`，`pid=… processName=com.haohandc.mindustryark` |
  | `sceneboard` | `onProcessDied, uid: …, bundleName: com.haohandc.mindustryark, pid: …` |
  | `aidataservice` | `process died, bundleName: com.haohandc.mindustryark` |
  | `hiview` | `uid: 0`、`bundleName:` **空**、`reason: CppCrash` |

  **唯一没有归属的那个在喊崩溃，而它被另外三个反驳。** 而且没有任何产物：
  没有 `faultlog`、没有 `cppcrash` 目录、没有转储、没有非零退出信号，
  启动器**真遇到**致命信号时才写的 `crash.txt` 一直是空的。
  产生那三条有归属记录的退出握手在 `EntryAbility.ets` 里。

以上各条背后的原因写在**对应代码的注释里**，而不在这份文档里 —— 入口是 `entry/src/main/cpp/launcher.c`。

---
## ⚠️ 局域网里同一个服务器可能被列出两次

**现象**：开一台服务器，另一台设备在「加入游戏」的局域网列表里**看到两条**，
指向同一台机器。

**原因在 ArcNet 自己**（游戏用的网络库，不在我们这层）：`Client.discoverHosts()`
会**同时**发两个独立探测 —— 一个 **UDP 广播**、一个**多播**，各自一个 socket，
各自对每个回应回调一次，**全程没有按地址去重**。一个**同时响应这两种探测**的服务器
就会上报两次，界面于是画两条。

🔶 **推断部分**：上面那句「两种探测都成功」我**没有实测**，是从本平台网络探测
（`socket`/`epoll`/广播都通）推出来的。可确定的是**代码里确实没有去重**。

⇒ **不影响使用**：两条指向同一台服务器，点哪条都能进。
⚠️ 这是**上游行为**，不是本移植引入的；手机/平板上都可能有。

## ⚠️ 在部分设备上应用装了却起不来

**现象**：应用安装成功，一点就退，**没有任何崩溃提示**。

**已知条件**（2026-09-22 实测）：在**华为自检**分配的设备（**HarmonyOS 6.1.1 / API 24**）上，
启动器发完 JVM 参数、调用 `JNI_CreateJavaVM` 之后**再无输出**，进程随即消失。
同一份包在 **HarmonyOS 7 / API 26** 的设备上正常进入主菜单。

**原因（实测）**：该设备**拒绝一切匿名可执行内存**：

```
!! mmap(RWX) FAILED: errno=22 (Invalid argument)
 [1] clear_cache   (CONTROL) -> -1   unexpected
 [2] mprotect RW->RX          -> -1   unexpected
```

⇒ **JVM 的 JIT 无法启动**，所以卡在 `JNI_CreateJavaVM` 里。

⭐⭐ **两个候选原因，现已分离（2026-09-22）**：当时的两种解释是 ① 平台版本太老；② 该设备运行的是
**应用市场签名（release）**的包，而我们平时在真机上装的都是**调试签名**的包。

⇒ **答案是 ②，与平台版本无关**：实测一台 **API 26 的手机**用不带 ACL 的 release profile，**同样起不来**。
**一个原因就够解释全部观测，不需要「版本」那一半。**

⚠️ **所以「API 24 会拒绝可执行内存」这个说法从来没有被实测支持过** —— 记录里写的始终是「两个假说从未分离」，
是后来**被当成结论引用**了。实测过的只有：**release 签名的包拿不到那块内存，任何版本都一样。**

⚠️ 本应用声明的最低版本是 `compatibleSdkVersion 6.1.1(24)`，**而这个声明没有得到实测支持** ——
所有「能跑」的证据都来自 API 26，而所有「起不来」的证据都来自 release 签名包。
**API 24 到底能不能跑，两个方向都没有测过。**


## ⛔ 解释执行**救不了**拿不到可执行内存的设备

⚠️⚠️ **这一节更正了本文以前的一个说法。** 以前写的是「拿不到内存的设备会**变慢**」（加载约 21 秒而不是 5~6 秒）。
**那是错的，而且从来没有实测过。** 没有任何一次观测到本应用以解释模式跑起来。

**实测（2026-09-22）**：用一份**真正不给该权限的 release profile**（不带可执行内存 ACL），启动器**正确探到了**
拿不到内存、也**照做了**加上 `-Xint` —— 然后**死在 `JNI_CreateJavaVM` 里，此后再无任何输出**。
包本身已经**正确识别了处境并做了唯一能做的事**，日志甚至写着「slow but will start」。**它没有起来。**

**为什么这条路走不通**：`-Xint` 改变的是**字节码怎么执行**，它不移除对可执行内存的需求 ——
HotSpot 要先建**启动用的桩代码**（`SharedRuntime` / `StubRoutines`），这早于它关心字节码要怎么跑。
⇒ 「解释执行」不是这种情况下的降级模式，**它答的是另一道题**。

### 那两种安装方式分别是什么结果

⭐ **限制来自【设备】，不是系统版本。**

| 设备 | 自签名安装（调试 profile） | 应用商店（release profile） |
|---|---|---|
| **平板** | ✅ 可用，有 JIT、全速 | ✅ ACL 批准后可用 |
| **手机** | ⚠️ 部分可用（见下）| ⛔ 不提供 |
| **PC · 2in1** | ❓ 未测试 | ❓ 未测试 |

**为什么自签名就有**：调试 / 自签名用的 profile 会**临时放开全部权限**，与包里声明了什么无关。
✅ **用户 2026-09-22 确认**：第三方签名工具（小白调试助手，自带一套 profile）在手机上一样拿到 JIT。

**为什么手机的应用商店版本不提供**：**release** profile 在手机上**永远**拿不到那块内存，**与系统版本无关** ——
实测：一台 API 26 的手机用不带 ACL 的 release profile，同样起不来。
⭐ 而这项 ACL 权限本身**只面向平板与 PC / 2in1**（华为政策原文），手机申请不到。

**系统版本是次要因素**：
- 本应用声明的最低版本是 **6.1.1（API 24）**，**该下限未实测**。
- 从 **API 26** 起，系统会为**调试** profile **自动申请**受支持的 ACL 权限。
- ⚠️ **鸿蒙 5 / 6 的手机**：没有那个自动机制，**自签名安装未验证**（不是「不行」—— 见下）。

⚠️⚠️ **这一节改过三次，三次的错法值得记：**
1. 最初写「**HarmonyOS 7 以下的手机**」—— 把**被混淆的观测**当成了规则。
2. 改完之后又写成「**手机大概率是解释执行**」—— **把商店包的性质安到了所有安装方式上**。
3. 再之后写「**会自动降级为解释执行，代价是变慢**」—— 引用的 21 秒是在**内存可用的设备上强行打开
   解释模式**量出来的，只证明**解释执行的代价**，**不证明「没内存的设备会怎样」**。实测它根本不起来。

**现在怎么判**：启动器**每次启动实测**「能不能拿到匿名可执行内存」，拿不到就加 `-Xint`。
⚠️ 但这个强制是**如实照做**，不是**救回来** —— 上文已述：拿不到内存的设备，加了也起不来。
探针的价值在于**如实报告**。

⇒ ⚠️ **自签名安装如果变慢或起不来，那是缺陷，不是预期** —— 请报出来。

### 那个 21 秒仍然有效，但要换个标签

它是在**内存可用**的设备上强行开启该模式量出来的：

| | 加载时间 |
| --- | --- |
| 正常（JIT） | 约 5~6 秒 |
| 强行解释执行 | **约 21 秒** |

⇒ 它证明的是**解释执行的代价**（代价随**视野面积**放大：窗口缩小基本能玩、全屏高负载掉帧严重），
**不是**「没内存的设备会怎样」。⭐ 这条是「**平板为什么必须要 JIT**」的依据 ——
平板屏幕最大，是解释执行吃亏最狠的设备。


## ✅「下载」目录：手机上走的是**应用自己创建的那个文件夹**

⚠️ **这一节原来写的是「手机够不到下载目录」，那个结论已被推翻** —— 够得到，只是**换了一条路**。

**两条路，名字很像，机制完全不同**：

| | `Environment.getUserDownloadDir()` | `DocumentPickerMode.DOWNLOAD` |
| --- | --- | --- |
| 官方说法 | 需要 `SystemCapability.FileManagement.File.Environment.FolderObtain`，**仅支持 2in1 设备** | **自动创建在 `Download/包名/` 目录**；跳过选择界面；返回的 URI 已具备持久化权限 |
| 手机上的结果 | ⛔ 抛「The device doesn't support this api」 | ✅ **可用** |
| 要不要权限 | 要 `READ_WRITE_DOWNLOAD_DIRECTORY` | **不要任何权限** |

⇒ **手机上用的是第二条。** 应用在「下载」里创建一个**以包名命名的文件夹**
（`Download/com.haohandc.mindustryark`），玩家用任何文件管理器把模组丢进去即可。

**怎么用**：**不需要你做什么** —— 应用**每次启动都会检查并在缺失时重建**它。
⚠️ **没有对应的菜单项**（早先有过一个，已删除：建文件夹不该让玩家去点）。

**依据（设备实测）**：toast 出现、「文件管理」里能看到那个包名文件夹；
`user_dirs.txt` 里 `mods=/storage/Users/currentUser/Download/com.haohandc.mindustryark`，
启动器日志 `file browser will open at (mod folder): ...`。

⚠️ **仍未验证**：游戏的**文件浏览器**（走 libc，不是走 URI）能否读那个路径 ——
应用的授权是**按 URI** 持有的，而浏览器用**路径**。这是下一步要在设备上看的。

⚠️ **顺带**：`READ_WRITE_DOWNLOAD_DIRECTORY` 在本项目里**从来没有过一次成功**
（见下），已**于 2026-09-22 移除**。⇒ **本应用现在是【零文件权限】。**

### ⭐⭐ 逐设备的精确实测（2026-09-22，两台机器都测了）

| | 平板 MatePad | 手机 M80P |
| --- | --- | --- |
| `Environment.getUserDownloadDir()` | 返回 `/storage/Users/currentUser/Download` | **抛「The device doesn't support this api」** |
| 往那里 `mkdir` 我们的子目录 | **EPERM 被拒**（`13900001`） | 走不到 —— 上一行就抛了 |
| `DocumentPickerMode.DOWNLOAD` | ✅ **成功**（修好窗口问题后，见下） | ✅ **成功** |
| **实际生效的是哪条** | **选择器模式** | **选择器模式** |

⚠️ **并且它不需要任何权限** —— 平板上的权限**是被用户拒绝的**，选择器模式照样建出了文件夹。

⇒ ⭐ **`READ_WRITE_DOWNLOAD_DIRECTORY` 对本应用【完全没有用】**：
路线 A **从来没有成功过一次**（手机上是 API 不支持，平板上是权限被拒 + `mkdir` EPERM）。
✅ **已于 2026-09-22 移除** —— 随之取消的还有它那条 **ACL 受限权限申请流程**，
⇒ **上架审核少一个障碍**。见 [PERMISSIONS.md](PERMISSIONS.md)。

⚠️ **平板上那个 EPERM 的原因，用户确认了：权限是【他手动拒绝】的。**
⇒ 不是平台故障，也不是解不开的矛盾。但**留下一个有用的发现**：

**平板的 `reqPermissionStates` 显示 `[0, 0]`（都「已授予」），而权限实际是被拒的。**
⇒ ⭐ **那个字段不能用来判断权限到底给没给。**
（这和另一处记录呼应：权限请求返回的三个字段互相矛盾 —— 见上文。
**鸿蒙的权限状态字段在本项目上两次都不可靠。**）

### ✅ 所以：文件夹**每次启动都会检查**，缺失就重建

行为是「**每次启动检查在不在，不在就重建**」（这正是其他应用的做法，也是用户要求的）。
✅ **两台设备（平板 + 手机）实测都能建出来**，且**都不需要任何权限**。
⇒ 玩家把文件丢进去、重启应用即可。

### ⭐ `13900042` 是「**现在没有可用的 UI 窗口**」

**实测（同一台手机、同一个包、同一天）**：

| 从哪调用 `DocumentPickerMode.DOWNLOAD` | 结果 |
| --- | --- |
| **悬浮球菜单**（点一下，窗口在手） | ✅ **成功** |
| `EntryAbility.onCreate`（窗口可能还没建） | ❌ **`13900042`** |
| **页面的 `aboutToAppear`**（窗口已存在） | ✅ **成功** |

⇒ **DOWNLOAD 模式虽然不显示任何对话框，但仍然需要一个 UI 窗口。**
⚠️ 这个失败的**表现是「静默」** —— 因为该模式本来就不弹界面，所以「没建出来」
看起来和「建好了」一模一样。**这一点让前面几轮都误判了。**

⇒ **所以创建放在页面里，不放在 ability 的 `onCreate`。** 读取仍留在 `onCreate`
（不涉及选择器，随便哪里都行）。

### ⭐ 存下来的**路径**可用，**URI 不可用**

`DOWNLOAD` 模式返回一个 URI，把它解成路径后，实测在手机上：

```text
/storage/Users/currentUser/Download/<包名>         列表正常   ← 可用
file://docs/storage/Users/currentUser/Download/...  No such file or directory
```

⇒ 那个 URI**不是能直接喂给 `fs.listFileSync` 的形式** —— 官方示例也是先
`new fileUri.FileUri(uri).path` 再用的。**所以路径优先、URI 只做兜底。**

## ⚠️ 模组：文件在沙箱内，只有悬浮球那个入口需要重启

**模组文件放在**（应用沙箱内）：
`/data/storage/el2/base/files/.local/share/Mindustry/mods/`

**格式**：`.jar` 或 `.zip`。
（游戏也接受「内含 `mod.json` 的文件夹」，但那种没法用文件选择器选。）

**只有一个入口：游戏自带的「导入模组」按钮。**

✅ **可用**（设备上实测过）。⚠️ 它会先弹一个**取不到社区模组列表**的提示 ——
那是它在联网，平台层的网络已经通了，取不到是服务端/链路的问题（实测是 `Connection refused`），
关掉提示继续即可。**不用重启**：它自己会触发模组重载。

### ⛔ 应用【不再】自己往模组目录里放文件（2026-09-22 移除，按用户要求）

这里曾经有**三个**入口。另外两个是：

| 已删除的入口 | 它当时怎么工作 |
| --- | --- |
| 悬浮球菜单的「导入模组」 | 系统选择器选文件 → 拷进 `mods/` |
| `Download/com.haohandc.mindustryark/` 文件夹 | **每次启动**把里面的 `.jar`/`.zip` 扫进 `mods/` |
| （以及一个开发用的探针模组） | 每次启动**无条件覆盖** `probe-mod.jar` |

**为什么删**：它们让**应用**决定「某个模组存在」，而玩家**在游戏内无法推翻这个决定**。
最糟的是中间那个：

- 它只在「`mods/` 里已有**同样大小**的同名文件」时才跳过 ⇒ **在游戏内删掉模组**（= 删掉沙箱里那份）
  之后，Download 里那份**还在** ⇒ **下次启动又拷回来，永远如此**。没有任何办法让一个模组**保持被删除**。
- 它还和**存档**冲突：同一个文件夹**同时是游戏文件浏览器的主目录**
  （`-Darc.sdl.chooserPath`），而存档导出的正是 `.zip`，扫描**把 `.zip` 当模组**收 ⇒
  **存档被当成模组扫进了 `mods/`**。

⇒ ⭐ **「丢进文件夹就自动装好」这个便利，代价是玩家失去了「删掉它」这个能力。** 现在没有自动了：
`Download/com.haohandc.mindustryark/` **仍然存在、仍然由应用创建**（因为游戏的文件浏览器要开在那里，
见上一节），把模组放进去**照样能用** —— 只是需要你在游戏里**选一下**，而不是被自动收走。
**删掉的模组从此保持被删除。**

⚠️ 如果你以前版本的探针模组（`probe-mod`）还留在列表里：现在可以直接在游戏内删掉它，**它不会再回来**。

📌 顺带说明一个容易混的点（我自己在这里搞错过一次）：游戏**自己**那套文件浏览器
（`mindustry/ui/FileChooser` / `FileChooserDialog`）是**纯 Java、画在游戏界面里**的，
和**原生**文件对话框是两回事。后者（`libarc-filedialogsarm64.so`，实为 tinyfiledialogs）
是个 glibc 桌面库、本平台加载不了 —— **但本平台没有任何代码路径会走到它**，
所以不影响上面任何一个入口。

### ⚠️ 内置导入会把文件**改名成 `<名字>.zip`**

不是缺陷，是游戏写死的。`Mods.importMod` 算目标名用的是：

```java
file.nameWithoutExtension().replace(' ', '_') + ".zip"
```

⇒ 同一个 `.jar` 分别走「游戏内置导入」和「悬浮球 / Download」，会在 `mods/` 里
**留下两个文件**（一份 `.jar` 一份 `.zip`），**内容逐字节相同**。

实测：把 `MindustryToolMod - 复制 .jar` 放进 Download，落地成
`MindustryToolMod_-_复制_.zip` —— 空格变下划线、后缀变 `.zip`，与上面那个式子逐字相符。

⚠️ **无害**，但容易让人以为装了两遍。只想留一份的话，删掉任意一个即可
（**在游戏内的模组列表里删** —— `mods/` 在应用沙箱内，文件管理器打不开）。

### ⚠️ 模组可能被**游戏自己**禁用，而且**不报错**

游戏有一条**崩溃安全阀**。若上一次启动没能起来（`Vars.failedToLaunch`），下一次启动它会
**对每一个模组**做：

```java
settings.put("mod-" + 名字 + "-enabled", false);      // 关掉
settings.put("mod-" + 名字 + "-failed",  <旧enabled>); // 记一笔，给界面看
```

之后 `Mods.load()` 读 `-enabled`，是 false 就把状态设成 `disabled` ⇒ **模组不生效**。

⚠️⚠️ **最容易骗人的一点**：`Loading mod: <名字>` 这行日志是在**判定之前**打的
（在 `loadMod` 里，而状态改写发生在之后的 `load()`）⇒ **这行日志出现 ≠ 模组生效**。
判断有没有生效要看模组**本身的功能**，不要看这行。

**恢复办法**：游戏 → 模组 → 把模组**重新启用**。那是唯一能改回来的地方。

⚠️ **悬浮球和 Download 这两个入口不会重新启用模组。** 游戏自己的导入会顺手写
`-enabled = true`，**我们的没有** ⇒ 一个被禁用过的模组，用我们的入口重装
**装进去了但不生效**，而且**没有任何提示**。

之所以不去补：那两个标志位在 `settings.bin`（游戏的 Java 序列化设置文件）里，
**游戏运行时改它会被游戏覆盖**；而且键名用的是模组的**内部名字**（`mod.json` 里的
`name`），不是文件名，得先解析 jar 才知道。为一个窄场景去动玩家的设置文件，
风险与收益不成比例 —— 所以**如实记在这里**，而不是悄悄绕过。

⚠️ 开发时注意：用 `deploy.sh` 重新部署会**清空沙箱**，模组和存档一起没。


# English

- **Text entry, and what each route can do.** Touch a text field inside the game
  (a save name, a schematic name, the export filename) and the app puts up its
  own text field, wired to the system input method — so the on-screen keyboard
  appears and composed input works, Chinese included. A physical keyboard works
  too, and what it can type depends on where the focus is:
    - while the app's field is up, the keyboard goes through the system input
      method as well, so Chinese works from a physical keyboard too;
    - when it is not up, the keyboard goes straight to the game through SDL's
      key-to-character path, which has no input method behind it — ASCII only.
  Focus is singular, so those are the only two states there can be.
  - **Both routes exist because SDL's own IME path cannot work here.** This
    process maps `libSDL3.so` twice, ArkTS hands the IME controller to the copy
    that is *not* running the game, and a `napi_ref` cannot be moved between
    them — so SDL can never show a keyboard. What replaced it: the app watches
    for the game asking for text (a file), shows an ArkUI `TextInput`, and feeds
    what the user types back into SDL's text event queue. The code is in
    `SDL_openharmony.c`, `SDL_openharmonyevents.c` and `ets/pages/Index.ets`.
  - **One rough edge, stated plainly:** the app cannot read the game field's
    cursor, so it sends the *difference* from what it believes the field holds.
    Typing and backspacing at the end of a name are exact. Inserting or editing
    in the *middle* is repaired by retracting and resending — the result is
    correct, but that text is retyped on screen.
- **Desktop/mobile mode cannot be switched at runtime.** The mode is fixed at
  launch. Mindustry has an in-game "mouse + keyboard control" toggle that covers
  most of the same ground. For how to switch, see [FAQ.md](FAQ.md).
- `libarc-filedialogsarm64.so` is linked against glibc and cannot load here, so
  Arc falls back to Mindustry's own in-game file browser. This is why the
  browser path had to be redirected to Download.
- Importing game data makes the game exit on purpose (`Core.app.exit()`), so
  that it restarts with the new data. This looks like a crash and is not one.
- Verified on two devices so far: a HUAWEI MatePad Pro 12.2" 2025 tablet and a
  HUAWEI Mate 80 Pro phone, both HarmonyOS 7 / API 26. Anything else is
  untested — the platform's policy on executable memory is what this depends on,
  and a device that enforces it differently would fail in ways this project has
  no way to predict.
- **Immersive mode does not apply on `2in1` (PC)** — the taskbar and window title
  bar stay. That is a platform limit, not something left undone. **Measured, not
  assumed.** Nothing is broken by it: the floating ball **does** hide normally on PC.
- **`hiview/AppKilledReporter` logs `reason: CppCrash` every time the app exits
  normally. It is not a crash, and it is not attributable to this app.** Measured
  on a normal in-game Quit, in one 5 ms window:

  | Component | Verdict, with attribution |
  |---|---|
  | `AppMS` | `Kill Reason: app exit`, `pid=… processName=com.haohandc.mindustryark` |
  | `sceneboard` | `onProcessDied, uid: …, bundleName: com.haohandc.mindustryark, pid: …` |
  | `aidataservice` | `process died, bundleName: com.haohandc.mindustryark` |
  | `hiview` | `uid: 0, bundleName: ` **empty**, `reason: CppCrash` |

  The one component with no attribution is the one calling it a crash, and it is
  contradicted by the other three. Nothing is produced for it either: no
  `faultlog`, no `cppcrash` directory, no core dump, no non-zero exit signal, and
  `crash.txt` (which the launcher writes when it *does* see a fatal signal) stays
  empty. If you are reading `hiview` lines and wondering, that is what you are
  looking at. See `EntryAbility.ets` for the exit handshake that produces the
  three attributed lines.

The reasoning behind each of those is in the source comments where the code is, rather than here -- `entry/src/main/cpp/launcher.c` is the place to start.

## ⚠️ One LAN server can be listed twice

**What happens**: with a server running, another device's LAN list in "Join game"
shows **two entries** for the same machine.

**The cause is in ArcNet itself** (the game's networking library, not our layer):
`Client.discoverHosts()` fires **two independent probes** -- one **UDP
broadcast**, one **multicast** -- each on its own socket, each calling the
callback once per reply, with **no de-duplication by address anywhere**. A server
that answers *both* probes is therefore reported twice and drawn twice.

🔶 **The inferred part**: that both probes do succeed here is **not measured** --
it is inferred from this platform's network probe (socket/epoll/broadcast all
pass). What is certain is that **the code contains no de-duplication**.

⇒ **Harmless**: both entries point at the same server and either one connects.
⚠️ This is **upstream behaviour**, not something this port introduced; it can
happen on phones and tablets alike.

## ⛔ On some devices it installs and will not start

**Symptom**: it installs, you tap it, it exits -- with **no crash report at all**.

**The condition** (measured 2026-09-22): the device **refuses anonymous executable
memory**:

```
!! mmap(RWX) FAILED: errno=22 (Invalid argument)
 [1] clear_cache   (CONTROL) -> -1   unexpected
 [2] mprotect RW->RX          -> -1   unexpected
```

⇒ the Java runtime cannot start, so the process dies inside `JNI_CreateJavaVM`.

⛔ **AND THERE IS NO FALLBACK THAT SAVES IT.** The next section is the correction --
this file used to say such a device would run the game *slower*. It does not run
the game at all.

⚠️ **What is still not separated**: whether the **platform version** matters. The
device that first showed this was an **API 24 phone running the store package**, so
two explanations were confounded from the start and this project said so in as many
words (`RELEASE-MAINTENANCE.md` 2.11, "两个假说从未分离"). What is clear now is that
the **capability** is what decides, and it is measured on every launch rather than
inferred from a version.

⚠️ The app declares a minimum of `compatibleSdkVersion 6.1.1(24)` and **that claim has
no measurement behind it** -- every "it works" observation is from API 26. Until this
is settled, an API 24 device may install the app and be unable to run it.

## ⛔ Interpreted mode does NOT rescue a device without executable memory

⚠️⚠️ **This corrects a claim this file used to make.** It said a device refused
executable memory would run the game **slower** (about 21 s to load instead of
5-6 s). **That is false, and it was never measured.** Nothing has ever been observed
running this app interpreted.

**What was measured (2026-09-22).** A package signed with a **device-bound RELEASE
profile**, carrying **no** executable-memory ACL, produced exactly this in `hilog`
and then nothing at all:

```
!! executable memory unavailable (probe=-1) -- FORCING -Xint; the game will be slow but will start
wrote the verdict for the UI: interp (probe=-1)
calling JNI_CreateJavaVM (strict) ...
  opt: ... -Xint
```

No return, no error, the process gone. The package had **detected the situation
correctly** and had already done the one thing this project knew to do -- and the
launcher's own log line says out loud what it expected ("slow but will start"). It
did not start.

**Why the fallback cannot work.** `-Xint` changes how *bytecode* is run. It does not
remove the need for executable memory, because HotSpot builds its **startup stubs**
(`SharedRuntime`, `StubRoutines`) **before** it ever looks at how bytecode will be
executed. So "interpreted" is not a degraded mode for this situation; it answers a
question that was never the blocker.

⚠️ **The earlier "verified" was not a test of this.** The fallback was once called
verified because a test hook (`NOEXEC`) forced the decision -- but the memory was
available throughout that run. What actually passed was *"the option gets added on a
device that never needed it"*. **Forcing an option is not the same as being in the
state the option exists for** — that is the general lesson, and it is written down in
`RELEASE-MAINTENANCE.md` 2.13b.

### What this means, and what was done about it

| how it was installed | phone | tablet |
|---|---|---|
| **self-signed** (this project's GitHub release asks you to sign it yourself) | ✅ **JIT, full speed** | ✅ JIT, full speed |
| **AppGallery** | ⛔ **cannot start** | JIT, if the ACL took effect |

**Why self-signing gets it**: the profile a debug / self-signed install uses
**temporarily unlocks every permission**, regardless of what the package declares.
✅ **Confirmed by the user on 2026-09-22**: a third-party signing tool (小白调试助手,
with its own profile) gets the JIT on a phone as well.

**Why the store package cannot, on a phone**: a **release** profile **never** gets that
memory on a phone, at any platform version, and per the section above there is no
interpreted fallback to fall back to.

⚠️ **Two different questions, and this file used to blur them:**

| | HarmonyOS 7 / API 26+ | HarmonyOS 5 / 6 |
|---|---|---|
| **self-signed (debug profile)** | ✅ **works — JIT included** | ⛔ does not |
| **store (release profile)** | ⛔ never | ⛔ never |

⇒ ⭐ **A HarmonyOS 7 phone is a supported way to run this app** — install it self-signed,
exactly as the release notes describe, and it has the JIT like a tablet. From API 26 the
system applies the *supported* ACL permissions for a **debug** profile by itself; an older
platform has no such mechanism, and a release profile is excluded regardless.

⇒ ⭐ **THERE IS NO PHONE PACKAGE IN THE STORE, ON PURPOSE.** It could only install and
never start. **To play on a phone, install the self-signed build** -- see the
installation section of the release notes.

### ⚠️ On a phone, "installs and closes instantly" is a SIGNING problem, not this app

⚠️ **And this is the one place where deleting the notice (above) costs something, so it is
spelled out here instead.**

A self-signed install gets the JIT **only if the profile you sign with is a DEBUG one** --
a debug profile *temporarily unlocks every permission*, which is what supplies the memory.
Measured at both ends:

| profile used for signing | phone |
|---|---|
| **debug** (`小白调试助手`, or DevEco's automatically generated one) | ✅ JIT, `probe=42` |
| **non-debug** (`app-distribution-type: internaltesting` -- measured 2026-09-22) | ⛔ installs, closes on launch, **nothing logged** |

⚠️ **The failure is indistinguishable from a bug in this app, from the outside.** There is no
faultlog, the sandbox logs cannot be read, and -- since the notice was deleted -- **nothing
appears on screen either**. The app dies inside `JNI_CreateJavaVM` before it can explain itself.

⇒ **If a phone install closes the instant it is tapped, re-sign with a different tool before
reporting anything.** That is the only diagnostic available, and that is why this paragraph
exists rather than being folded into the table above: the symptom is silent, so the *symptom
itself* has to be documented as the thing to match against.

🔶 **Not measured**: whether any particular third-party tool uses a debug or a non-debug
profile. Only `小白调试助手` was tested (it works). The rule above is about the *profile type*,
which is what was measured at both ends.

⚠️ The app still contains the compatibility switch (`-Xint`), and two things about it
are worth knowing:
- it is **not a rescue**, and is not documented as one;
- `FORCE_COMPAT_MODE` (a constant in `Index.ets`, default `false`) forces it on every
  device, which is how the interpreter's **cost** is measured. The store build script
  refuses to run if that constant is not `false`.

⚠️⚠️ **This section has been wrong three times now, and each way is worth keeping:**
1. It said "**phones below HarmonyOS 7**" -- reading a **confounded observation** (the
   failing device was both a phone and on an old version) as a rule.
2. The first correction said "**phones will most likely run interpreted**" -- attaching
   a property of the store package to every way of installing.
3. The second correction said such devices run **slower**, and promised a 21-second
   load. That number is real, but it was measured by **forcing `-Xint` on a device that
   did have the memory** -- so it measures what interpretation costs, not what a device
   without that memory does. It does nothing: the app dies.

**What the 21-second figure is still good for** (HarmonyOS 7 tablet, mode forced on by
hand): it is the **cost of interpretation** on hardware that can run it, and in game it
**scales with the VISIBLE AREA** rather than slowing everything uniformly:

- **window shrunk** (roughly phone-sized): high load is **playable**
- **full screen**: high load **drops frames badly, effectively unplayable**

⇒ because rendering is native while the unit and tile simulation is Java: a larger
viewport means more work per frame at the same frame budget. This is why a small screen
tolerates interpretation better -- and it is the reason the phone gamble looked
plausible. **It was still wrong**, because the app does not reach the point where any
of this matters.

⚠️ **A removed notice.** A full-screen notice used to tell the player about
interpreted mode. It was armed **before the XComponent mounted**, so on a device in
this state the player read a promise of "slower" and then watched the app die. It has
been **deleted** -- the text is preserved in `RELEASE-MAINTENANCE.md` 2.13b, and the
decision was the user's.


## ✅ The Download folder: on phones the route is the folder the app creates itself

⚠️ **This section used to say the phone cannot reach Downloads. That is refuted**
-- it can, by a different route.

**Two routes, similar names, entirely different mechanisms**:

| | `Environment.getUserDownloadDir()` | `DocumentPickerMode.DOWNLOAD` |
| --- | --- | --- |
| The documentation | needs `SystemCapability.FileManagement.File.Environment.FolderObtain`, **"currently 2in1 devices only"** | **creates `Download/<bundle name>/` automatically**; skips the picker UI; the URI it returns already carries persistent permission |
| On a phone | ⛔ throws "The device doesn't support this api" | ✅ **works** |
| Permission needed | `READ_WRITE_DOWNLOAD_DIRECTORY` | **none at all** |

⇒ **Phones use the second one.** The app creates a folder named after the bundle
inside Downloads (`Download/com.haohandc.mindustryark`) and the player drops mod
files into it with any file manager.

**How to use it**: floating ball menu -> **"模组文件夹"**. ⚠️ **No picker appears** --
DOWNLOAD mode skips its UI entirely.

**Evidence (measured on the device)**: the toast appeared and the bundle-name
folder is visible in the file manager; `user_dirs.txt` carries
`mods=/storage/Users/currentUser/Download/com.haohandc.mindustryark`, and the
launcher logs `file browser will open at (mod folder): ...`.

⚠️ **Still unverified**: whether the game's own **file browser** (which goes
through libc, not through the URI) can read that path -- the app's grant is held
**per URI** while the browser uses a **path**. That is the next thing to check on
the device.

⚠️ **Also**: `READ_WRITE_DOWNLOAD_DIRECTORY` has **never once succeeded** in this
project (see below), and was **removed on 2026-09-22**. ⇒ **this app now has ZERO
file permissions.**

### ⭐⭐ Precise, per device (2026-09-22, both machines measured)

| | Tablet (MatePad) | Phone (M80P) |
| --- | --- | --- |
| `Environment.getUserDownloadDir()` | returns `/storage/Users/currentUser/Download` | **throws "The device doesn't support this api"** |
| `mkdir` our subdirectory there | **refused, EPERM** (`13900001`) | never reached -- the line above throws |
| `DocumentPickerMode.DOWNLOAD` | ✅ **works** (once the window problem was fixed) | ✅ **works** |
| **which one actually does the work** | **the picker mode** | **the picker mode** |

⚠️ **And it needs no permission at all** -- the tablet's permission is **denied by
the user**, and the picker mode still created the folder.

⇒ ⭐ **`READ_WRITE_DOWNLOAD_DIRECTORY` has NO use in this app**: route A has never
succeeded once (on the phone the API does not exist, on the tablet the permission is
denied and `mkdir` returns EPERM). ✅ **Removed on 2026-09-22** -- which also cancels
the **ACL restricted-permission route** it required, so **store review has one less
obstacle**. See [PERMISSIONS.md](PERMISSIONS.md).

⚠️ **That EPERM on the tablet is now explained -- the user DENIED the permission
by hand.** So it is not a platform fault and not a contradiction. But it leaves a
useful finding:

**The tablet's `reqPermissionStates` reads `[0, 0]` ("both granted") while the
permission is in fact denied.** ⇒ ⭐ **That field cannot be used to tell whether a
permission was granted.** This is the second time on this project that a Huawei
permission-status field has disagreed with reality -- see the three contradictory
fields on the request result above. **Do not trust them; test the operation.**

### ✅ So: the folder is CHECKED every launch, and recreated if missing

The behaviour is "check on every launch whether it is there, and recreate it if not"
-- what other apps do, and what the user asked for. ✅ **Both devices (tablet and
phone) create it**, and **neither needs any permission**. The player drops files in
and restarts the app.

### ⭐ `13900042` is "there is no usable UI window right now"

**Measured on one phone, one package, one day**:

| called from | result |
| --- | --- |
| **the floating ball's menu** (a tap, window present) | ✅ **works** |
| `EntryAbility.onCreate` (the window may not exist yet) | ❌ **`13900042`** |
| **the page's `aboutToAppear`** (window exists) | ✅ **works** |

⇒ **DOWNLOAD mode needs a UI window even though it shows no dialog.**
⚠️ And the failure is **silent in effect** -- the mode shows no UI at all, so "it did
not create the folder" looks exactly like "it created the folder". That is what
made the earlier rounds misread it.

⇒ **So creation lives on the page, not in the ability's `onCreate`.** Reading stays
in `onCreate`, where no picker is involved.

### ⭐ The stored **path** works; the **URI** does not

DOWNLOAD mode returns a URI. Resolved to a path, measured on the phone:

```text
/storage/Users/currentUser/Download/<bundle>          lists fine   <- usable
file://docs/storage/Users/currentUser/Download/...    No such file or directory
```

⇒ the URI **is not something `fs.listFileSync` accepts as-is** -- the guide's own
example resolves it with `new fileUri.FileUri(uri).path` first. **So the path is
tried first and the URI is only a fallback.**

## ⚠️ Mods: the files live in the sandbox, and only the picker needs a restart

**Where the mod files are** (inside the app sandbox):
`/data/storage/el2/base/files/.local/share/Mindustry/mods/`

**Format**: `.jar` or `.zip`. (The game also accepts a *folder* containing
`mod.json`, but a picker cannot hand a folder over.)

**There is exactly one way in: the game's own "import mod" button.**

✅ **Works** (confirmed on the device). ⚠️ It shows a
**cannot-reach-the-community-mod-list** notice first -- it is going online, and the
platform-level network path works; failing to fetch is a server/route condition (measured:
`Connection refused`). Dismiss it and carry on. **No restart needed**: it triggers the
reload itself.

### ⛔ The app no longer puts files into the mods directory (removed 2026-09-22)

There used to be **three** ways in. The other two were:

| Removed | What it did |
| --- | --- |
| the floating ball's "导入模组" | system picker → copy into `mods/` |
| `Download/com.haohandc.mindustryark/` | **every launch**, sweep its `.jar` / `.zip` into `mods/` |
| (plus a development probe mod) | **every launch**, overwrite `probe-mod.jar` unconditionally |

**Why they were removed**: they let the *app* decide that a mod exists, and the player
**could not overrule that from inside the game**. The middle one was the damaging one:

- it skipped a file only when `mods/` already held one of the **same size**, so **deleting a
  mod in the game** (which deletes the sandbox copy) left the Downloads copy in place and the
  file **came back on the next launch, forever**. There was no way to make a mod stay gone.
- it also collided with **saves**: that folder is also the root the game's file browser opens
  in (`-Darc.sdl.chooserPath`), saves are exported as `.zip`, and the scan accepted `.zip` as a
  mod -- so **a save was swept into `mods/` as though it were a mod**.

⇒ ⭐ **"Drop a file in and it installs itself" cost the player the ability to delete it.**
Nothing is automatic now. `Download/com.haohandc.mindustryark/` **still exists and is still
created by the app** (the game's file browser has to open there -- see the section above), and
a mod dropped in it **still works** -- it just has to be **picked** rather than taken.
**A deleted mod now stays deleted.**

⚠️ If a previous version left a `probe-mod` in your mod list, you can delete it in the game now
and **it will not come back**.

📌 One thing that is easy to confuse -- and that this project got wrong once:
the game's **own** file browser (`mindustry/ui/FileChooser` /
`FileChooserDialog`) is **pure Java, drawn inside the game**, and is a different
thing from the **native** file dialog. The latter
(`libarc-filedialogsarm64.so`, really tinyfiledialogs) is a glibc desktop
library that does not load here -- but **no code path on this platform ever
reaches it**, so none of the entries above is affected by it.

### ⚠️ The game's own import **renames the file to `<name>.zip`**

Not a defect -- it is hard-coded. `Mods.importMod` derives its destination as:

```java
file.nameWithoutExtension().replace(' ', '_') + ".zip"
```

⇒ the same `.jar` taken in through **the game's import** and through the ball's picker
or Downloads leaves **two files** in `mods/` (one `.jar`, one `.zip`) with **byte-identical
contents**.

Measured: dropping in `MindustryToolMod - 复制 .jar` landed as
`MindustryToolMod_-_复制_.zip` -- spaces became underscores and the suffix became `.zip`,
matching that expression exactly.

⚠️ **Harmless**, but it reads as though the mod were installed twice. To keep one copy,
delete either one -- **from the game's own mods list**, since `mods/` lives in the app
sandbox and a file manager cannot open it.

### ⚠️ The game may disable a mod **by itself**, and it **says nothing**

Mindustry has a **crash safety valve**. If the previous launch failed to start
(`Vars.failedToLaunch`), the next launch does this **to every mod**:

```java
settings.put("mod-" + name + "-enabled", false);        // switch it off
settings.put("mod-" + name + "-failed",  <old enabled>); // and note it for the UI
```

`Mods.load()` then reads `-enabled`, and when it is false it sets the mod's state to
`disabled` ⇒ **the mod does not take effect**.

⚠️⚠️ **The part that misleads:** the `Loading mod: <name>` line is printed *before* that
decision (inside `loadMod`; the state is rewritten later, in `load()`) ⇒ **that line
appearing does NOT mean the mod took effect.** Judge that by the mod's own behaviour, not
by that line.

**To recover**: game → mods → **enable the mod again**. That is the only place that can
change it back.

⚠️ **Neither the ball's picker nor the Downloads folder re-enables a mod.** The game's own
import also writes `-enabled = true`; **ours does not** ⇒ a mod that has been disabled is
re-installed by our entries **and still does not take effect**, with **no message at all**.

Why it was left alone: those flags live in `settings.bin`, the game's Java-serialised
settings file. Writing it while the game is running gets overwritten by the game, and the
key is the mod's **internal name** (the `name` in `mod.json`) rather than the file name, so
the jar would have to be parsed first. Rewriting a player's settings file for a narrow case
is a bad trade -- so it is recorded here rather than quietly worked around.

⚠️ For developers: re-deploying with `deploy.sh` **wipes the sandbox**, mods and
saves together.
