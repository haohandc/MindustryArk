# 常见问题 · Ark Launcher

[← 返回 README](../README.md) · [← Back to README](../README.en.md)

> 这里只放**反复被问到、但「已知限制」里没写**的问题。
> 有意保留的行为清单在 **[LIMITATIONS.md](LIMITATIONS.md)**。

---
# 中文

## 应用为什么这么大（HAP 约 260 MB）？

因为**不套现成的模拟层**，运行时得自己带：内嵌的 **OpenJDK 21**、**SDL3**、**LWJGL**，
以及游戏本体，全都在包里。这是本方案的直接代价，也是它**不需要「让沙箱可执行」那个受限权限**
（`ALLOW_WRITABLE_CODE_MEMORY`）就能装的原因。

## 按返回键没反应，是不是坏了？

分两处说，因为退出游戏之后还有启动器界面：

- **在游戏里**：返回键映射成**游戏内的 ESC**，也就是「退一层」（关掉当前对话框或菜单）。
  ⚠️ **在主菜单上 ESC 无处可去**，所以那里按返回键看起来像没反应 —— 有意为之，不是缺陷。
- **在启动器里**（首页 / 存档 / 设置）：返回键用来**退一层界面** —— 关掉打开的窗、
  退出存档多选、从垃圾站或手机上的详情子页返回。全都退完了才不响应。

**要退出应用**：在游戏里用主菜单的 Quit（那条路已验证是干净退出）；
或者点悬浮球 →「**启动器**」，回到启动器界面再退出。

## 沉浸模式下刘海 / 挖孔挡住东西了，怎么办？

**分两块，两块都能调：**

**① 启动器自己的界面**（首页 / 存档 / 设置，以及那些弹窗）——
应用会**自己探测挖孔 / 刘海**（`window.getWindowAvoidArea(TYPE_CUTOUT)`），
并把结果**自动**用在界面上，不需要你做什么。
⛔ **曲面屏边缘不避让** —— 那是显示特征不是洞，像素是在的，内容本来就该铺到那儿。

要调就去 **设置 → 界面避让（异形屏）**：

| 控件 | 作用 |
|---|---|
| **自动避让**（出厂就是开的） | 每次启动都按本机探测结果来 |
| **滑条**（0 – 64 vp） | 自己定一个值。⚠️ **一动滑条，自动就关掉了** —— 那是「我要自己定」最自然的表达 |

⭐ 想回到自动：把「自动避让」开关重新打开，值立刻回到探测结果。

**这个值作用在哪几边：**

| 探测结果 | 作用在 |
|---|---|
| 命中了一边或几边（例如顶部一个挖孔） | **只让那几边** —— 其余边不需要，让了是浪费 |
| **什么都没探测到** | **只让上边** —— 按最常见的形状（顶部一个孔）假定 |

⚠️ 第二行在 2026-10-03 改成只让上边：原来让四边，用户当场指出「左右避让干啥啊」——
顶部那个孔根本没碰到左右，白白少了两条可用宽度。要上下都让的机器请自己拖滑条。

**② 游戏画面** —— 那是**游戏自带**的：设置里有「**适应刘海显示**」开关，
另有一个安全区边距值可调。请在那里调。⛔ 启动器那条滑条管不到它。

## 启动器界面切页签有点顿，是性能问题吗？

**不是。这一条在设备上量过，结论是「应用无能为力」，写在这里免得别人再走一遍。**

**鸿蒙的 ArkUI 应用无法向系统请求屏幕刷新率 —— 面板是跟着应用走的，不是反过来。**

Mate 80 Pro 上实测：

- 这块屏支持的档位是 `[30, 36, 40, 45, 60, 72, 90, 120]` Hz；
- **应用启动前**，面板停在 **120 Hz**；**应用一进前台，面板就落到 60 Hz，并一直待着**；
- 我们渲染的是**精准的 60 fps** —— 帧间隔恒定 16.6 ms、零抖动。
  也就是说**不是渲染不过来**，而是**面板本来就在 60**；
- 试过在动画上声明 `expectedFrameRateRange = {60, 120, 120}`，
  **连一条持续 3 秒的动画也抬不动它**，面板全程 60、fps 全程 60。

鸿蒙**没有**公开的「设置刷新率」接口：`@ohos.display` 只有**读**的字段（当前档位、支持的档位），
`settings.openScreenRefreshRateSettingsPage()` 只是把**系统设置页**打开给用户，不是设置 API。

⇒ **如果你觉得切页签不够顺，把屏幕刷新率固定成 60 Hz 会改善**（实测有效）。
原因大概是：智能刷新模式下，面板会在档位之间**移动**（启动时从 120 落到 60、触摸时又可能升上去），
而**每一次档位切换本身就会丢一帧**；固定住之后它就不动了。

⚠️ 这条只影响**启动器的界面动画**，**不影响游戏本身**。

## 怎么切换 PC 模式 / 触屏模式？

点**悬浮球** → 菜单里的「**切换**」→ **重启应用**后生效。
为什么必须重启：Mindustry 的输入层**和** UI 都派生自**启动时写入**的一个值，
中途改会让两者不一致。（游戏内自带的「鼠标 + 键盘操控」开关能**即时**切换操控方式，
但它不改 UI，所以给到的是「移动端 UI + 桌面操控」。）

## 存档和游戏数据在哪？怎么备份？

**没开版本隔离时**（出厂设置就是不开）—— 在应用沙箱内：
`/data/storage/el2/base/files/.local/share/Mindustry/`。

> [!WARNING]
> **开了版本隔离之后，路径会变** —— 每个游戏版本各有一份，多出两层：
> `/data/storage/el2/base/files/instances/<隔离键>/sets/default/.local/share/Mindustry/`
> （隔离键形如 `b160.5`、`bundled`）。
>
> ⚠️ 键取决于**当时选的粒度**，所以换个粒度再看，目录名会变 ——
> **旧的那份不会被搬走**，它会作为「没有版本读它」继续列在存档页里。

**普通使用不需要碰它** —— 用游戏内的导入 / 导出功能，走「下载」目录往返。
那条路走系统的**选择器**，**不需要任何权限**（本应用是零文件权限），两台设备都实测可用。

⭐ **游戏自带的文件浏览器**读同一个路径也**已实测可用**。
⚠️ 这里原先记的是一条**相反**的推断（它走 libc 用路径，而应用的授权是按 URI 持有的，
所以应当读不到）—— **实测否证了那条推断**。详见[已知限制](LIMITATIONS.md)。

## DevEco 的稳定性测试报了一堆 `cppcrash`，是我装坏了吗？

> [!NOTE]
> 有**两件性质完全不同**的事都会被报成 `CppCrash`。**这不是安装或签名的问题。**

| 情形 | 是不是崩溃 |
|---|---|
| **每次正常退出**时 `hiview/AppKilledReporter` 打的那条 | ❌ **不是** —— 证据在 [LIMITATIONS.md](LIMITATIONS.md) |
| **DevEco 稳定性压测**（随机点击 / 旋转 / 切后台）下出现的 | ⚠️ **记录是真的，但性质未定** —— 见下 |

第二种要分成两件事说，不能混：

**① 记录本身是真的**（逐条解码原始机器码得到的，不是报告层的伪影）：

- 故障信号是 `SIGSEGV`；
- **故障指令是 JIT 编译后的代码里读空指针**（`LDR Wn, [X0, #8]` 一类，**基址寄存器为 0**）；
- PC 与 LR 都落在 JVM 的 **JIT 代码缓存**里（匿名可执行内存段）。

⚠️ **但报告里给出的函数名不可信** —— 它标出的那两个位置经反汇编核对**都不是内存访问指令**，
是栈回溯失败之后的猜测（报告自己就写着 `Failed to unwind stack`）。
**别照着报告里的函数名去查代码。**

**② 而它是否等于「用户会遇到的那种崩溃」，还没有定论：**

- ❓ **不施加压测时没有观察到复现**，正常使用中也没有收到过闪退报告；
- ⚠️ 压测会**反复把应用切到后台**，而 HarmonyOS 会回收后台进程 ——
  应用本来就要被杀，这个过程中的信号也可能被记成崩溃。**这两种情况我们还没有区分开。**

⇒ **结论**：如果你在**正常使用**中遇到闪退，请把 faultlog 报告（以及沙箱里的 `crash.txt`，
若有）提上来，那是有价值的。**如果你只是在压测报告里看到它，不必据此认为应用不可用。**

---
# English

## Why is the app so big (a ~260 MB HAP)?

Because nothing is emulated — the runtime travels inside the package: an embedded
**OpenJDK 21**, **SDL3**, **LWJGL** and the game itself. That is the direct cost of this
approach, and the reason it installs with an ordinary signature and needs **no restricted
permission**.

## The Back button does nothing. Is it broken?

Two places, because there is a launcher UI behind the game:

- **In the game**: Back is mapped to the game's **ESC**, meaning "up one level" — close the
  current dialog or menu. ⚠️ **On the main menu ESC has nowhere to go**, so Back looks dead
  there. That is deliberate, not a defect.
- **In the launcher** (Home / Saves / Settings): Back goes **up one level of UI** — it closes
  an open dialog, leaves save multi-select, and returns from the vault or a phone detail
  sub-page. It stops responding only once there is nothing left to close.

**To quit**: use Quit on the game's main menu (that path is the verified clean exit), or tap
the floating ball → **"launcher"** to go back to the launcher UI and exit from there.

## On a notched or hole-punch screen the cutout covers things.

**Two separate things, and both are adjustable:**

**① The launcher's own UI** (Home / Saves / Settings, and the dialogs) —
the app **detects cutouts and notches itself** (`window.getWindowAvoidArea(TYPE_CUTOUT)`) and
applies the result **automatically**; there is nothing to do.
⛔ **Curved edges are not avoided** -- that is a display feature, not a hole: the pixels are there,
and content is meant to extend under it.

To change it: **Settings → 界面避让（异形屏）**:

| Control | What it does |
|---|---|
| **自动避让** (on by default) | re-applies this machine's detection on every launch |
| **the slider** (0 – 64 vp) | your own value. ⚠️ **Touching the slider turns auto off** -- the most natural way to say "I will decide" |

⭐ To go back to automatic, turn the toggle on again; the value returns to the detection at once.

**Which edges the value applies to:**

| Detection | Applies to |
|---|---|
| one or more edges (a top-centred cutout, say) | **only those edges** -- the rest do not need it, and the space would be wasted |
| **nothing at all** | **the top edge only** -- the most common shape (one hole at the top) |

⚠️ The second row became top-only on 2026-10-03. It used to be all four, and the user pointed out
on the spot that a top-centred hole has nothing to do with the left and right edges -- two strips
of usable width were being thrown away. A device that needs the bottom too can drag the slider.

**② The game's picture**
**② The game's picture** — that one belongs to the **game**: there is an **"adapt to notch"** toggle
in its settings, plus an adjustable safe-area padding value. ⛔ The launcher's slider does not
affect it.

## The launcher's UI stutters a little when I switch tabs. Is it a performance problem?

**No. This was measured on the device, and the conclusion is "the app cannot fix it". It is
written down here so the next person does not have to walk the same path.**

**A HarmonyOS ArkUI app cannot ask the system for a refresh rate -- the panel follows the app,
not the other way around.**

Measured on a Mate 80 Pro:

- The display supports `[30, 36, 40, 45, 60, 72, 90, 120]` Hz;
- **Before the app starts** the panel sits at **120 Hz**; **as soon as the app comes to the
  foreground the panel drops to 60 Hz and stays there**;
- We render a **precise 60 fps** -- 16.6 ms between frames, no jitter at all.
  So this is **not** "we cannot keep up"; the panel is simply at 60;
- Declaring `expectedFrameRateRange = {60, 120, 120}` on an animation **did not raise it**,
  not even with an animation that ran for 3 seconds -- the panel stayed at 60 and so did the
  frame rate.

HarmonyOS exposes **no** public "set the refresh rate" API: `@ohos.display` only has readable
fields (the current step and the supported steps), and
`settings.openScreenRefreshRateSettingsPage()` merely opens the **system settings page** for the
user rather than setting anything.

=> **If the tab switch feels rough to you, pinning the display to 60 Hz improves it** (measured).
The likely reason: in adaptive-refresh mode the panel **moves** between steps (it drops from 120
to 60 when the app starts, and may rise again on touch), and **every step change costs a frame**.
Pinned, it stops moving.

Note this only affects the **launcher's own animations**, **not the game itself**.

## How do I switch between PC mode and touch mode?

Tap the **floating ball** → **"switch"** in its menu → **restart the app**.
The restart is required because Mindustry derives both its input layer *and* its UI from one
value written at **startup**; changing it midway leaves the two disagreeing. (The game's own
"mouse + keyboard control" toggle switches the *controls* immediately but not the UI — so it
gives you a mobile UI driven by desktop input.)

## Where do saves and game data live? Can I back them up?

**With version isolation off** (the factory setting) — inside the app sandbox, at
`/data/storage/el2/base/files/.local/share/Mindustry/`.

> [!WARNING]
> **With version isolation on, the path changes** — each game version gets its own, two levels
> deeper:
> `/data/storage/el2/base/files/instances/<isolation key>/sets/default/.local/share/Mindustry/`
> (a key looks like `b160.5` or `bundled`).
>
> ⚠️ The key follows **the granularity selected at the time**, so changing granularity changes
> the directory name — the old copy is **not** moved, and stays listed on the Saves tab as
> "no version reads it".

**You should never need to touch it** — use the in-game import / export, which goes through
your Downloads folder. That route uses the system **picker** and needs **no permission at
all** (this app holds zero file permissions); it is measured working on both devices.

⭐ The **game's own file browser** reads that same path too — **measured**.
⚠️ What stood here was the **opposite** inference (it goes through libc with a path while the
app's grant is held per URI, so it should not be able to) — **the measurement disproved it**.
See [limitations](LIMITATIONS.md).

## DevEco's stability test reports a pile of `cppcrash`. Did I install it wrong?

> [!NOTE]
> **Two completely different things** get reported as `CppCrash`. **This has nothing to do
> with signing or installation.**

| Case | Is it a crash? |
|---|---|
| The line `hiview/AppKilledReporter` prints on **every normal exit** | ❌ **No** — the evidence is in [LIMITATIONS.md](LIMITATIONS.md) |
| What appears under **DevEco stability stress testing** (random taps, rotation, app switching) | ⚠️ **The record is real; what it means is not settled** — see below |

The second one has to be split in two, and they must not be conflated:

**① The record itself is real** (decoded from the raw instruction bytes, so not a reporting
artifact):

- the signal is `SIGSEGV`;
- **the faulting instruction is a null-pointer read inside JIT-compiled code**
  (`LDR Wn, [X0, #8]` and the like, with a **zero base register**);
- both PC and LR land in the JVM's **JIT code cache** (an anonymous executable mapping).

⚠️ **The function names in that report cannot be trusted** — disassembly shows the two frames
it labels are **not memory accesses at all**; they are guesses made after stack unwinding
failed (the report says so itself: `Failed to unwind stack`).
**Do not go looking for code based on the names in that report.**

**② Whether it corresponds to a crash a *user* would meet is still open:**

- ❓ **It has not been observed to reproduce without the stress harness**, and no crash has
  been reported from normal use;
- ⚠️ the harness **repeatedly sends the app to the background**, and HarmonyOS reclaims
  background processes — the app was going to be killed anyway, and signals raised during
  that teardown would also be recorded as a crash. **We have not yet told those two apart.**

⇒ **In short:** if you hit a crash in **normal use**, please attach the faultlog report (and
`crash.txt` from the sandbox, if present) — that one is worth having. **If you only saw it in
a stress-test report, it is not by itself grounds for thinking the app is unusable.**
