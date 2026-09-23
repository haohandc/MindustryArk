# 常见问题 · MindustryArk

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

不是。返回键被映射成**游戏内的 ESC**，也就是「退一层」（关掉当前对话框或菜单）。
**在主界面上 ESC 无处可去**，所以那里按返回键看起来像没反应 —— 这是有意为之，不是缺陷。
**要退出应用，用游戏主菜单的 Quit**（那条路已验证是干净退出）。

## 沉浸模式下刘海 / 挖孔挡住东西了，怎么办？

**我们没做异形屏适配，也不打算做** —— 因为**游戏自带**：
设置里有「**适应刘海显示**」开关，另有一个安全区边距值可调。请在那里调。

## 怎么切换 PC 模式 / 触屏模式？

点**悬浮球** → 菜单里的「**切换**」→ **重启应用**后生效。
为什么必须重启：Mindustry 的输入层**和** UI 都派生自**启动时写入**的一个值，
中途改会让两者不一致。（游戏内自带的「鼠标 + 键盘操控」开关能**即时**切换操控方式，
但它不改 UI，所以给到的是「移动端 UI + 桌面操控」。）

## 存档和游戏数据在哪？怎么备份？

在应用沙箱内：`/data/storage/el2/base/files/.local/share/Mindustry/`。
**普通使用不需要碰它** —— 用游戏内的导入 / 导出功能，走「下载」目录往返，
这也正是那个权限的用途。

⚠️ **但这条只在部分机型上成立**：手机 Mate 80 Pro 上系统把该权限申请判为「无效请求」
（`authResults = 2`），不弹窗也不授权，「下载」目录用不了。详见
[已知限制](LIMITATIONS.md)。

## DevEco 的稳定性测试报了一堆 `cppcrash`，是我装坏了吗？

**不是安装或签名的问题。** 有**两件性质完全不同**的事都会被报成 `CppCrash`：

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

No. Back is mapped to the game's **ESC**, which means "up one level" — close the current
dialog or menu. **On the main menu ESC has nowhere to go**, so Back looks dead there.
That is deliberate, not a defect. **To quit, use Quit on the game's main menu** (that path
is the verified clean exit).

## On a notched or hole-punch screen the cutout covers things.

**We do not implement display-cutout handling, and we do not intend to** — the game has it.
There is an **"adapt to notch"** toggle in the settings, plus an adjustable safe-area padding
value. Use those.

## How do I switch between PC mode and touch mode?

Tap the **floating ball** → **"switch"** in its menu → **restart the app**.
The restart is required because Mindustry derives both its input layer *and* its UI from one
value written at **startup**; changing it midway leaves the two disagreeing. (The game's own
"mouse + keyboard control" toggle switches the *controls* immediately but not the UI — so it
gives you a mobile UI driven by desktop input.)

## Where do saves and game data live? Can I back them up?

Inside the app sandbox, at `/data/storage/el2/base/files/.local/share/Mindustry/`.
**You should never need to touch it** — use the in-game import / export, which goes through
your Downloads folder. That is what the download permission is for.

⚠️ **On some devices that route does not exist.** On the Mate 80 Pro phone the
system returns "invalid request" (`authResults = 2`) for that permission, shows
no dialog, never grants it, and the Download folder is unusable. See
[limitations](LIMITATIONS.md).

## DevEco's stability test reports a pile of `cppcrash`. Did I install it wrong?

**No — this has nothing to do with signing or installation.** **Two completely different
things** get reported as `CppCrash`:

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
