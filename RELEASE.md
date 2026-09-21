# What to publish, and what must not be published

Two artifacts go on the Releases page. One artifact is built but deliberately
**does not**.

| Artifact | Publish? | Why |
|---|---|---|
| `MindustryArk-v<version>-unsigned.hap` | **yes** | Anyone can sign it with their own certificate and install it. This is the app. |
| `MindustryArk-v<version>-payload.zip` | yes | The inputs for building from source. Not needed to play. |
| `MindustryArk-v<version>.hap` (the signed one) | **NO** | See below. It is device-locked, and it leaks personal data. |

---

## Why the signed HAP is not a release artifact

`deploy.sh` builds a signed HAP because the local development loop needs one. It
is signed with a **debug** profile generated automatically by DevEco Studio, and
that is the wrong thing to hand to another person for two independent reasons —
either one is disqualifying.

### 1. It only installs on devices whose UDID is in the profile

A debug profile is a list of permitted devices. From Huawei's own documentation
for requesting one:

> **Device** — Click **Select** and select one or more debugging devices. You can
> select up to 100 devices.
>
> — <https://developer.huawei.com/consumer/en/doc/agc-help-debug-profile-0000002248181278>

and for registering them:

> Before using a real device to debug your HarmonyOS app or atomic service, you
> need to register the device with the AppGallery Connect device list using the
> UDID. The debugging device specified in the profile will be selected from the
> device list.
>
> — <https://developer.huawei.com/consumer/en/doc/agc-help-add-device-0000001946142249>

The device restriction lives in the **profile**, not the certificate — a Release
profile has no device list at all ("*a list of devices permitted for debugging
(empty for Release type apps)*", <https://dev.to/harmonyos/how-to-solve-the-manual-signature-issue-41lj>).
A third-party distribution service states the same thing from the other side: a
debug certificate is rejected outright, and the profile must be of type
Specified Device Release *with the tester's UDID included*
(<https://www.pgyer.com/doc/en/view/harmonyos>). Its error code 10021 is
literally "the device UDID isn't in the profile's scope".

So a HAP signed this way installs on the machines in that profile and returns an
error everywhere else.

### 2. It contains the UDIDs and the developer's real name, in the clear

This one is worse, because it is not an install failure — it is a disclosure.
**Measured, not assumed**: read `pack.info`'s sibling in the signing block of a
built HAP and the profile is right there as JSON.

```
python - <<'PY'
p = "entry/build/default/outputs/default/MindustryArk-v0.1.0-beta1.hap"
d = open(p, "rb").read()[-400000:]
i = d.find(b'"debug-info"')
print(d[max(0, i - 900):i + 400].decode("utf-8", "replace"))
PY
```

which prints, among other fields:

```
"type":"debug",
"bundle-info":{"developer-id":"…","development-certificate":"…CN=…,Development…"},
"debug-info":{"device-ids":["…","…","…","…","…","…"],"device-id-type":"udid"}
```

Six UDIDs, the developer account id, and the name on the certificate. Those
UDIDs are hardware identifiers tied to the account, and publishing them is not
recoverable by deleting the release afterwards — assume anything uploaded is
cached.

**Conclusion: build the signed HAP locally, install it locally, never upload it.**

---

## What a user does instead

The unsigned HAP cannot be installed as-is — on HarmonyOS every `.hap` must be
signed before it will install
(<https://www.pgyer.com/doc/en/view/harmonyos>). The user signs it themselves,
once, and the reason that works here is the same property that made this project
distributable at all:

> this app requests **no restricted ACL permission**, so an ordinary
> automatically-generated debug profile is sufficient. There is nothing to apply
> for from AppGallery Connect.

So the instructions in the release notes are:

1. Open the project in DevEco Studio.
2. **File → Project Structure → Signing Configs → Automatically generate
   signature.** This creates a debug certificate and profile for *their* account
   and registers *their* device.
3. Put the downloaded HAP where the build output goes, or simply build it
   (`bash deploy.sh`), and install with `hdc install -r <the signed hap>`.

A user who only wants to play should build rather than patch the artifact —
`bash deploy.sh` does everything, and the payload zip is not needed for it
because the prebuilt HAP already contains the payload.

### If a pre-signed build is ever genuinely wanted

It needs a **release certificate** and a Release profile, both from AppGallery
Connect, which requires a real-name-verified developer account. Two caveats
before promising it to anyone:

- A **Release** profile has no device list, which is what would make the result
  installable on arbitrary devices. That is read from the profile format
  (source above) — it has not been tested here.
- Full public distribution through AppGallery also means app review, which an
  unofficial Mindustry launcher would not pass on licensing grounds. See
  `THIRD-PARTY.md`: a build redistributes GPL-3.0 Mindustry, so it can only be
  distributed with its source, which is what this repository is for.

---

## Release page copy

### Description (one line, for the repository page)

```
在 HarmonyOS / OpenHarmony 上运行 Mindustry 的自建启动器：内嵌 JDK、native 起 JVM、SDL3 出画面，已真机跑通。
```

```
Run Mindustry on HarmonyOS / OpenHarmony via a self-built launcher — embedded JDK, native JVM startup, real SDL3 window.
```

### Topics

Paste this into the repo's **Topics** box (space-separated; GitHub allows 20):

```
harmonyos harmonyos-next openharmony ohos arkts deveco-studio mindustry game-port sdl3 lwjgl jni jvm
```

Grouped by what they're for: **platform** `harmonyos` `harmonyos-next` `openharmony` `ohos` ·
**how it's written** `arkts` `deveco-studio` `jni` `jvm` · **what it is** `mindustry` `game-port` ·
**what it stands on** `sdl3` `lwjgl`.

#### Three candidates were dropped after checking what they actually contain

Not from intuition — each one would have found the wrong audience, and one of them was
in an earlier draft of this list:

| Dropped | What the topic actually is | Measured |
|---|---|---|
| `hap` | HomeKit Accessory Protocol (`homebridge`, `homebridge/HAP-NodeJS`), `html-agility-pack`, `HAP-python` | 121 repos, **none** HarmonyOS |
| `java` | tutorials, LeetCode, Spring — `JavaGuide`, `spring-boot`, `elasticsearch` | **324,781** repos |
| `hotspot` | WiFi tethering (`VPNHotspot`, `tetherfusenet`), mixed with `doocs/jvm` and `jitwatch` | 476 repos, mostly unrelated |

The decisive one is `hap`: on this platform it means *HarmonyOS Ability Package*, so it looks
like the obvious tag, and on GitHub it means something else entirely. The same conclusion
arrives from the other direction — the HarmonyOS HAP-tooling repo `Zitann/HarmonyOS-Haps`
tags itself `harmonyos-next`, not `hap`.

`jvm` is kept where `java` was dropped on the same reasoning: `jvm` (3,382 repos) is about
the runtime — `arthas`, `btrace`, `openjdk/jdk` — which is what this project embeds and
starts from native code, while `java` is about the language and is 96× larger and
tutorial-dominated.

**Source for every count and repo name above**: the `https://github.com/topics/<name>`
pages, fetched 2026-09-20. Local measurement plays no part in this table — it is all
web-sourced, and worth re-checking if it ever matters.

### Release title

```
v0.2.0-beta.1 — Mindustry v8 Build 160.4 on HarmonyOS
```

### Release body

Pasted verbatim from `dist/RELEASE-BODY-v0.2.0-beta.1.md`, which is generated
alongside the artifacts. Keep the two in step: this block is the copy of record,
and the file in `dist/` is what gets pasted into the release form.

````markdown
# Mindustry 鸿蒙移植 · v0.2.0-beta.1

在 HarmonyOS / OpenHarmony 上用**自建启动器**运行 Mindustry ——
内嵌 JDK、从 native 代码创建 JVM、把真正的 SDL3 窗口交给游戏，不套任何现成的模拟层。

**Run Mindustry on HarmonyOS / OpenHarmony with a self-built launcher** — an embedded
JDK, a JVM created from native code, and a real SDL3 window handed to the game.
No existing emulation layer involved.

内嵌的游戏版本 / Embedded game: **Mindustry `v8 Build 160.4`**（游戏内显示 `release build 160.4`）
⚠️ 这是 **Mindustry 自己的**版本号，和本项目的 `v0.2.0-beta.1` 是两套体系 /
that is the *game's* version, not this project's — the two move independently.

> ⚠️ **非官方项目 / Unofficial.** 与 Mindustry 及 Anuken 无隶属关系 · Not affiliated with,
> endorsed by, or supported by the Mindustry project or Anuken.
> 以 **GPL-3.0** 分发（构建产物再分发了 GPL-3.0 的 Mindustry）/ licensed GPL-3.0.

> ⚠️ **上个版本带 `v0.1.0-beta1` 的设备可以直接升级安装**（`versionCode` 10001 → **20001**）。
> *Installs of `v0.1.0-beta1` can upgrade in place.*（但若你之前装的是从源码自行构建的包，`versionCode`
> 可能不单调，那就得先卸载 / if you built from source with a different code, uninstall first.）

---

## ⭐ 这一版新增 / What is new in this release

**上个 beta 之后有 14 个提交，以下是全部用户可见的变化。**
*Fourteen commits since the last beta; these are all the user-visible changes.*

| 新增 / Added | 说明 / Notes |
|---|---|
| ⌨️ **屏幕软键盘** | ⭐ 点进游戏里的输入框会**自动弹出**；打字、退格、ESC 关闭都可正常工作。此前**完全打不了字**。<br>An on-screen keyboard appears when you tap a text field in the game. Before this, text entry did not work at all. |
| 🎈 **悬浮球** | 可以**拖动**、松手**吸附到最近的四条边**、**3 秒后自动半隐藏**（只露 40%），点击把它叫回来。它承载的第一项功能是**切换触屏 / PC 模式**。<br>A draggable ball that snaps to the nearest edge, half-hides after three seconds, and comes back on tap. Its first function is switching between touch and desktop control. |
| 🖥️ **PC / 触屏模式切换** | 游戏内自带的那个开关**只换输入层、不换 UI**；这个开关会真正切到移动端或桌面端 UI。⚠️ **重启应用后生效。**<br>Mindustry's own toggle swaps the input handler but leaves the mobile UI; this one switches both. Takes effect on restart. |
| 🖼️ **沉浸模式** | 隐藏状态栏和导航条，游戏铺满全屏。**系统手势未被抑制**，随时可以回桌面。<br>Hides the status and navigation bars. System gestures are left alone, so you can always leave the app. |
| 🎨 **新的应用图标** | 蓝底 + Arc 炮塔，取代了模板占位图。<br>A blue plate with the Arc turret, replacing the template placeholder. |
| 📛 **改名 `Mindustry Ark`** | 桌面显示的名字中间多了一个空格。⚠️ **下载的文件名仍是无空格的 `MindustryArk-v…`**（构建规则不允许空格）。<br>The launcher name now reads "Mindustry Ark". The downloaded filename keeps the unspaced form, which is a build-rule limit. |
| 🐛 **触摸修复** | 触屏点进存档列表后，条目不再「高亮卡住、要点两次」。<br>Save-list entries no longer stay highlighted and need a second tap. |

---

## 下载哪个文件 / Which file to download

| 文件 / File | 说明 / What it is |
|---|---|
| `MindustryArk-v0.2.0-beta.1-unsigned.hap` | **应用本体。** 未签名，需自签一次（见下）<br>**This is the app.** Unsigned — sign it once yourself (below) |
| `MindustryArk-v0.2.0-beta.1-payload.zip` | 载荷包。**只有要从源码构建才需要**<br>Build inputs — **only needed to build from source** |

⚠️ **未签名的 HAP 装不上**（HarmonyOS 要求先签名）/ **An unsigned HAP will not install**
(HarmonyOS requires a signature). 用你自己的证书签一次 / sign it once with your own certificate:

1. 用 DevEco Studio 打开本项目 / open this project in DevEco Studio
2. **File → Project Structure → Signing Configs → Automatically generate signature**
3. `bash deploy.sh`

**本项目不申请任何受限权限 / no restricted ACL permission is requested**，
所以自动生成的证书就够了，不必去 AppGallery Connect 申请 ·
so the automatically generated profile is sufficient and there is nothing to apply for.

---

## 已验证 / Verified

HarmonyOS 7 / API 26 真机验证：**HUAWEI MatePad Pro 12.2" 2025** 平板、**HUAWEI Mate 80 Pro** 手机。
Verified on a HUAWEI MatePad Pro 12.2" 2025 tablet and a HUAWEI Mate 80 Pro phone, both HarmonyOS 7 / API 26.

| 项目 / Area | 状态 / State |
|---|---|
| 主菜单与渲染 / menu and rendering | ✅ 正常，移动端布局 / works, mobile layout |
| 音频 / audio | ✅ OHAudio |
| 触屏 / touch | ✅ 点击、长按、**双指捏合缩放** / tap, long-press, **two-finger pinch zoom** |
| **软键盘 / on-screen keyboard** | ✅ **新** —— 点输入框自动弹出，打字/退格/ESC 关闭正常<br>**new** — appears on tap, typing, backspace and ESC all work |
| 物理键盘 / physical keyboard | ✅ WASD；ESC 打开菜单，**不被系统当成「返回」**<br>WASD; ESC opens the menu and is **not** treated as Back |
| 鼠标 / mouse | ✅ 全部按键 + 滚轮 / all buttons and the wheel |
| **悬浮球 / floating ball** | ✅ **新** —— 拖动、吸附、半隐藏、点击恢复、位置持久化<br>**new** — drag, snap, half-hide, tap to restore, position remembered |
| **沉浸模式 / immersive** | ✅ **新**（平板、手机）—— 全屏；⚠️ **2in1 上不生效**，见下<br>**new** on tablet and phone; ⚠️ not on 2in1, below |
| **键盘不再遮挡输入框 / keyboard no longer covers the field** | ✅ **新** —— 键盘弹出时框架会把游戏输入框推到可见位置<br>**new** — the framework pushes the game's field clear of the keyboard |
| 存档与数据导入导出 / save and data import | ✅ 从「下载」目录往返 / via the Download folder |
| 退出 / quitting | ✅ 正常关闭，不被系统标记为崩溃 / clean exit, not flagged as a crash |

## 已知限制 / Known limitations

- ⚠️ **软键盘只能输入 ASCII —— 打不了中文。** 游戏侧用的是自建的文本通道，没有接系统的输入法候选。
  *The on-screen keyboard is **ASCII-only**; Chinese input does not work.* It goes through
  a hand-rolled text path rather than the platform IME.
- ⚠️ **PC / 触屏模式切换需要重启应用才生效**（不是缺陷，是刻意为之：游戏把输入层和 UI 都绑在一个
  启动时写入的开关上，中途改会让两者不一致）。游戏内自带的「鼠标 + 键盘操控」开关可以即时切换操控方式。
  *The desktop/touch switch needs a restart.* Mindustry derives both the input layer and the UI
  from one value written at startup, so changing it midway would leave the two disagreeing.
  Mindustry's own "mouse + keyboard control" toggle changes the controls immediately.
- ⚠️ **2in1（PC）上沉浸模式不生效**，状态栏和导航条会留着。平板上正常。
  *Immersive mode does not apply on 2in1*, where the bars stay. Tablet and phone are unaffected.
- **游戏内的文件浏览器用的是 Mindustry 自带**的兜底实现（Arc 的文件对话框库是 glibc 链接，鸿蒙加载不了）。
  *The in-game file browser is Mindustry's own fallback* — Arc's file-dialog native
  is glibc-linked and cannot load here.
- **导入游戏数据后游戏会主动退出** —— 这是 Mindustry 的设计（用新数据重启），**看起来像崩溃但不是**。
  *Importing game data makes the game exit on purpose*, so it restarts with the new
  data. It looks like a crash and is not one.
- ⛔ **没有多人联机、没有成就、没有模组浏览器**（与桌面版相比）。网络需要额外的平台工作，尚未做。
  *No multiplayer, achievements or mod browser* compared with the desktop release.
  Networking needs platform work that has not been done.
- 只在上面那两台设备上验证过，其他鸿蒙设备**未测试**。
  *Verified on those two devices only.* This depends on the platform's policy on
  executable memory, and a device that enforces it differently would fail in ways
  this project has no way to predict.

## 从源码构建 / Building from source

```bash
# 先准备载荷（见 payload-src/README.md），或解开载荷包
unzip -o MindustryArk-v0.2.0-beta.1-payload.zip
# 配置签名（同上），然后 / then configure signing as above and run:
bash deploy.sh          # 构建 + 校验 + 安装 + 启动 + 收日志
```

## 致谢与许可 / Credits and licences

Mindustry 与 Arc 由 **Anuken** 开发 / by **Anuken**；窗口·输入·音频层 / windowing,
input and audio: **SDL3**；JNI 绑定 / bindings: **LWJGL**；运行时 / runtime: **OpenJDK 21**。
逐组件条款见 / per-component terms: [`THIRD-PARTY.md`](THIRD-PARTY.md)。
中文说明见 / Chinese docs: [`README.zh-CN.md`](README.zh-CN.md)。

本仓库大部分代码由 AI 辅助完成 / most of the code here was written with AI
assistance（Claude via Cherry Studio，deepseek-flash v4.1）。
````

## Building the two artifacts

```bash
bash build.sh assembleHap                       # -> the HAPs, in entry/build/.../outputs/default

# the payload zip, from the assembled payload. Rebuild it whenever entry/libs
# changes, or the published zip will disagree with the repository:
python - <<'PY'
import os, zipfile
with zipfile.ZipFile("dist/MindustryArk-v0.2.0-beta.1-payload.zip", "w",
                     zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    z.write("dist/README-PAYLOAD.txt", "README-PAYLOAD.txt")
    for dp, _d, fs in os.walk("entry/libs"):
        for f in sorted(fs):
            p = os.path.join(dp, f)
            z.write(p, p.replace(os.sep, "/"))
PY
```

The zip carries `entry/` at the top level and `README-PAYLOAD.txt` beside it, so
unzipping into the repository root does the right thing.

## Published state

Released **2026-09-20** as a **pre-release**:

| | |
|---|---|
| Repository | `https://github.com/haohandc/MindustryArk` (private at the time of writing) |
| Tag | `v0.1.0-beta1` = `332192e` — lightweight, matching what GitHub creates on publish |
| Release | `v0.1.0-beta1 — Mindustry v8 Build 160.4 on HarmonyOS`, **Set as a pre-release** |
| Assets | the two below, plus GitHub's automatic `Source code (zip)` / `(tar.gz)` |

| Asset | Size | sha256 |
|---|---|---|
| `MindustryArk-v0.1.0-beta1-unsigned.hap` | 272,616,859 B | `0e2a6c9086814a383a21b35ce7944f21fc588eb3df333efb1fed864822abc4f0` |
| `MindustryArk-v0.1.0-beta1-payload.zip` | 146,836,356 B | `93db79ffd7974fb93859fc91b3e1de44d939a107c563e1399d430a8e36004adb` |

**Both hashes were recomputed locally and match the ones GitHub displays**, which is
what closes the last gap: the local unsigned HAP was checked for a signature block here,
and equal hashes mean the uploaded bytes are those same bytes. A local check alone
would only ever be evidence about the local file.

The signed HAP is **not** among the assets. That was confirmed by reading the release
page: four assets, two of them ours and two auto-generated.

> ⚠️ **The tag was moved after this release was published.** The AMCL artifact paths
> were rewritten out of history (see the repository's git log for why), which changed
> every commit SHA, so `v0.1.0-beta1` was re-pointed from `fd6e021` to `332192e` and
> force-pushed. **The tag's tree is byte-identical** (`59a49bf02784418e226d4cf4b11f6cfa6b93a166`),
> so the source archives GitHub generates are unchanged — only the commit SHA in the
> page header moved.

### v0.2.0-beta.1 — prepared 2026-09-21, awaiting publication

Assembled and checked locally. **Not published yet** — the release page is created by
hand, so this records the bytes that were verified so they can be compared against
whatever ends up uploaded.

| Asset | Size | sha256 |
|---|---|---|
| `MindustryArk-v0.2.0-beta.1-unsigned.hap` | 272557304 B | `7a246386d66b18af6b63fa8661f38a23a32ef1f204aac4273e59f51bf52e74c4` |
| `MindustryArk-v0.2.0-beta.1-payload.zip` | 146836398 B | `f7b08a7e577913c1540e502efb6f26846d48efea08e80d165b7cebb456e3e26a` |

**The unsigned HAP was checked for a signature block before this table was written.**
The four markers (`debug-info`, `device-ids`, `developer-id`, `development-certificate`)
are all absent and there are zero 64-hex strings that could be a device UDID —
**and the same check run against the signed build finds all four and exactly six
UDIDs**, which is what shows the check works rather than merely finding nothing.

The payload was rebuilt for this version rather than reused: `entry/libs` changed
since the last one (the game jar), and publishing a stale zip would make the download
disagree with the repository.

## Pre-publication checklist

All of these were run and passed before publishing. Kept as a record rather than a
to-do list, because a checklist that has never been executed is a guess.

- [x] Repository description and topics filled in (see the Topics section above).
      The topic list was checked against what each topic actually contains; `hap`
      turned out to mean HomeKit, and was dropped.
- [x] Uploaded **only** the unsigned HAP and the payload zip — never the signed one.
- [x] Confirmed the uploaded HAP has no signature block:
      `python -c "d=open('MindustryArk-v0.1.0-beta1-unsigned.hap','rb').read()[-900000:]; print(b'debug-info' in d)"`
      prints `False` — along with `device-ids`, `developer-id` and
      `development-certificate`, and zero 64-hex strings that could be a UDID.
- [x] Confirmed the repository has no local paths left. The leading boundary group
      is what keeps this from matching every `https://` in the docs:
      ```bash
      git grep -nE '(^|[^A-Za-z0-9])[A-Za-z]:[\/\\]' -- . ':!entry/src/main/cpp/SDL' ':!LICENSE' ':!RELEASE.md'
      ```
      Result: only documented, overridable defaults — `scripts/config.py` (every path
      the toolchain uses, each an `ARK_*`-overridable default), the same values
      repeated in `build.sh` and `deploy.sh` for the tools they invoke directly, and
      this file's own example below.
      **This check found a real defect**: `scripts/test_version_gate.py` had a
      hard-coded absolute path to one particular checkout, which would have failed
      with a confusing `ImportError` anywhere else. Fixed to derive from `__file__`.

      A control for the pattern itself — a quoted heredoc, because `printf`
      eats the backslashes:
      ```bash
      cat <<'EOF' | grep -nE '(^|[^A-Za-z0-9])[A-Za-z]:[\/\\]'
      ok https://x.dev/a
      bad E:/u/x
      bad C:\Users\y
      EOF
      # -> lines 2 and 3 only
      ```
      (That heredoc warning was already in this file, and the lesson was still
      learned the hard way while auditing history: a `printf`-built control did not
      contain the string it was supposed to, so a working check looked broken.)
- [x] Scanned every blob reachable from `master` — not just the working tree —
      for device UDIDs, the developer id, the app identifier, the profile UUID, the
      name on the certificate, the account's real email address, and any
      key/certificate file. None present. A file deleted in a later commit still
      lives in the earlier commit's objects, and going public exposes all of it.
- [x] Considered a line in the description lowering expectations:
      "未在真机上广泛测试，欢迎提 issue"
