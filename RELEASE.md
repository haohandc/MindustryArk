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
p = "entry/build/default/outputs/default/MindustryArk-v1.0.0.hap"
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

**Topics**: `harmonyos` `openharmony` `mindustry` `arkts` `deveco-studio` `sdl3`
`jni` `jvm` `hotspot` `java` `game-port` `hap`

### Release title

```
v1.0.0 — Mindustry 在鸿蒙上跑通
```

### Release body

````markdown
# Mindustry 鸿蒙移植 · v1.0.0

在 HarmonyOS / OpenHarmony 上用**自建启动器**运行 Mindustry。
不依赖任何现成的模拟层：内嵌 JDK、从 native 代码创建 JVM、把真正的 SDL3 窗口交给游戏。

> ⚠️ **非官方项目**，与 Mindustry 及 Anuken 无隶属关系。
> 本项目以 **GPL-3.0** 分发（因为构建产物再分发了 GPL-3.0 的 Mindustry）。

## 已验证可用的功能

在 HarmonyOS 7 / API 26 设备上真机验证（**HUAWEI MatePad Pro 12.2" 2025** 平板、**HUAWEI Mate 80 Pro** 手机）：

| 项目 | 状态 |
|---|---|
| 主菜单 / 渲染 | ✅ 正常，使用移动端布局 |
| 音频 | ✅ OHAudio |
| 触屏 | ✅ 点击、长按、**双指捏合缩放** |
| 键盘 | ✅ 物理键盘 WASD；ESC 打开菜单（**不会被系统当成"返回"**） |
| 鼠标 | ✅ 全部按键 + 滚轮 |
| 存档 / 数据导入导出 | ✅ 从「下载」目录 |
| 退出 | ✅ 正常关闭，不被系统标记为崩溃 |

## 下载哪个文件

| 文件 | 说明 |
|---|---|
| `MindustryArk-v1.0.0-unsigned.hap` | **这就是应用。** 未签名，需要你用自己的证书签一次才能装（见下） |
| `MindustryArk-v1.0.0-payload.zip` | **载荷包。** 想在本地从源码构建才需要；只想玩的话**不用下** |

⚠️ **签名方式**：HarmonyOS 上未签名的 HAP 装不了，必须先用你自己的证书签名。
在 DevEco Studio 里打开本项目 → File → Project Structure → Signing Configs →
Automatically generate signature，然后运行 `bash deploy.sh`。
**本项目不需要任何受限权限**，所以自动生成的证书就够了，不用去 AGC 申请。

## 已知限制

- **桌面 / 移动模式无法运行期切换**（启动时固定）。游戏内自带「鼠标 + 键盘操控」开关可覆盖大部分需求。
- 游戏内的文件浏览器走的是 Mindustry **自带**的兜底实现（Arc 的文件对话框库是 glibc 链接，鸿蒙加载不了）。
- **导入游戏数据后游戏会主动退出** —— 这是 Mindustry 的设计（用新数据重启），**看起来像崩溃但不是**。
- 只在 **MatePad Pro 12.2" 2025** 与 **Mate 80 Pro** 这两台设备上验证过，均为 HarmonyOS 7 / API 26。
  其他鸿蒙设备未测试 —— 本项目依赖平台对「可执行内存」的策略，若某设备在这点上做法不同，
  出错方式我们无法预判。

## 从源码构建

```bash
# 1) 先准备载荷（见 payload-src/README.md），或解开载荷包
unzip -o MindustryArk-v1.0.0-payload.zip
# 2) 配置签名：DevEco → Project Structure → Signing Configs → 自动生成签名
bash deploy.sh          # 构建 + 校验 + 安装 + 启动 + 收日志
```

## 致谢

Mindustry 与 Arc 由 **Anuken** 开发；窗口/输入/音频层是 **SDL3**；
JNI 绑定是 **LWJGL**；运行时是 **OpenJDK 21**。各组件许可证见 `THIRD-PARTY.md`。

本仓库大部分代码由 AI 辅助完成（Claude via Cherry Studio，deepseek-flash v4.1）。
````

---

## Building the two artifacts

```bash
bash build.sh assembleHap                       # -> the HAPs, in entry/build/.../outputs/default

# the payload zip, from the assembled payload. Rebuild it whenever entry/libs
# changes, or the published zip will disagree with the repository:
python - <<'PY'
import os, zipfile
with zipfile.ZipFile("dist/MindustryArk-v1.0.0-payload.zip", "w",
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
      `python -c "d=open('MindustryArk-v1.0.0-unsigned.hap','rb').read()[-400000:]; print(b'debug-info' in d)"`
      should print `False`
- [ ] Confirm the repository has no local paths left. The leading boundary group
      is what keeps this from matching every `https://` in the docs:
      ```bash
      git grep -nE '(^|[^A-Za-z0-9])[A-Za-z]:[\/\\]' -- . ':!entry/src/main/cpp/SDL' ':!LICENSE'
      ```
      Expected: only the `E:/Program Files/DevEco Studio` default in `build.sh`
      and `deploy.sh`, which is a documented, overridable default rather than
      somebody's home directory. A control for the pattern itself — a quoted
      heredoc, because `printf` eats the backslashes:
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
