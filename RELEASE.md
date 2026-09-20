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
v0.1.0-beta1 — Mindustry v8 Build 160.4 on HarmonyOS
```

### Release body

````markdown
# Mindustry 鸿蒙移植 · v0.1.0-beta1

在 HarmonyOS / OpenHarmony 上用**自建启动器**运行 Mindustry ——
内嵌 JDK、从 native 代码创建 JVM、把真正的 SDL3 窗口交给游戏，不套任何现成的模拟层。

**Run Mindustry on HarmonyOS / OpenHarmony with a self-built launcher** — an embedded
JDK, a JVM created from native code, and a real SDL3 window handed to the game.
No existing emulation layer involved.

内嵌的游戏版本 / Embedded game: **Mindustry `v8 Build 160.4`**（游戏内显示 `release build 160.4`）
⚠️ 这是 **Mindustry 自己的**版本号，和本项目的 `v0.1.0-beta1` 是两套体系 /
that is the *game's* version, not this project's — the two move independently.

> ⚠️ **非官方项目 / Unofficial.** 与 Mindustry 及 Anuken 无隶属关系 · Not affiliated with,
> endorsed by, or supported by the Mindustry project or Anuken.
> 以 **GPL-3.0** 分发（构建产物再分发了 GPL-3.0 的 Mindustry）/ licensed GPL-3.0.

---

## 下载哪个文件 / Which file to download

| 文件 / File | 说明 / What it is |
|---|---|
| `MindustryArk-v0.1.0-beta1-unsigned.hap` | **应用本体。** 未签名，需自签一次（见下）<br>**This is the app.** Unsigned — sign it once yourself (below) |
| `MindustryArk-v0.1.0-beta1-payload.zip` | 载荷包。**只有要从源码构建才需要**<br>Build inputs — **only needed to build from source** |

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
| 键盘 / keyboard | ✅ 物理键盘 WASD；ESC 打开菜单，**不被系统当成「返回」**<br>WASD; ESC opens the menu and is **not** treated as Back |
| 鼠标 / mouse | ✅ 全部按键 + 滚轮 / all buttons and the wheel |
| 存档与数据导入导出 / save and data import | ✅ 从「下载」目录往返 / via the Download folder |
| 退出 / quitting | ✅ 正常关闭，不被系统标记为崩溃 / clean exit, not flagged as a crash |

## 已知限制 / Known limitations

- **桌面/移动模式无法运行期切换**（启动时固定）。游戏内自带「鼠标 + 键盘操控」开关可覆盖大部分需求。
  *Desktop/mobile mode cannot be switched at runtime.* Mindustry's own in-game
  "mouse + keyboard control" toggle covers most of what you would want it for.
- 游戏内的文件浏览器用的是 Mindustry **自带**的兜底实现（Arc 的文件对话框库是 glibc 链接，鸿蒙加载不了）。
  *The in-game file browser is Mindustry's own fallback* — Arc's file-dialog native
  is glibc-linked and cannot load here.
- **导入游戏数据后游戏会主动退出** —— 这是 Mindustry 的设计（用新数据重启），**看起来像崩溃但不是**。
  *Importing game data makes the game exit on purpose*, so it restarts with the new
  data. It looks like a crash and is not one.
- 只在上面那两台设备上验证过，其他鸿蒙设备**未测试**。
  *Verified on those two devices only.* This depends on the platform's policy on
  executable memory, and a device that enforces it differently would fail in ways
  this project has no way to predict.

## 从源码构建 / Building from source

```bash
# 先准备载荷（见 payload-src/README.md），或解开载荷包
unzip -o MindustryArk-v0.1.0-beta1-payload.zip
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

---

## Building the two artifacts

```bash
bash build.sh assembleHap                       # -> the HAPs, in entry/build/.../outputs/default

# the payload zip, from the assembled payload. Rebuild it whenever entry/libs
# changes, or the published zip will disagree with the repository:
python - <<'PY'
import os, zipfile
with zipfile.ZipFile("dist/MindustryArk-v0.1.0-beta1-payload.zip", "w",
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

## Before pushing

- [ ] Repository description and topics filled in (above)
- [ ] Upload **only** the unsigned HAP and the payload zip — never the signed one
- [ ] Confirm the uploaded HAP has no signature block:
      `python -c "d=open('MindustryArk-v0.1.0-beta1-unsigned.hap','rb').read()[-400000:]; print(b'debug-info' in d)"`
      should print `False`
- [ ] Confirm the repository has no local paths left. The leading boundary group
      is what keeps this from matching every `https://` in the docs:
      ```bash
      git grep -nE '(^|[^A-Za-z0-9])[A-Za-z]:[\/\\]' -- . ':!entry/src/main/cpp/SDL' ':!LICENSE'
      ```
      Expected: **only documented, overridable defaults** — `scripts/config.py`
      (which holds every path the toolchain uses, each an `ARK_*`-overridable
      default), the same values repeated in `build.sh` and `deploy.sh` for the
      tools they invoke directly, and this file's own example above. Nothing
      that would break for someone whose checkout is not at one particular
      path, and no home directory outside those defaults.

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
- [ ] Consider a line in the description lowering expectations:
      "未在真机上广泛测试，欢迎提 issue"
