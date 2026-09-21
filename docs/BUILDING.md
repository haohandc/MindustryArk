# 构建 · MindustryArk

[← 返回 README](../README.zh-CN.md) · [← Back to README](../README.md)

---
# 中文

## 环境要求

- DevEco Studio 及 HarmonyOS SDK（`compatibleSdkVersion 6.1.1(24)`、`targetSdkVersion 26.0.0`）
- 一台 HarmonyOS 设备或模拟器
- Python 3.12、JDK 17（**仅**用于生成 Arc 补丁与 helper jar）

## 构建

**载荷不在本仓库里，它的输入也不在**（原因见 `.gitignore`）。
因为 HAP 会把载荷整个打进去，所以构建前必须先准备输入。

### 一、把输入放进 `payload-src/`

`payload-src/README.md` 列了清单 —— 三个 jar、两个 LWJGL 原生库、JDK 里的两个文件 ——
并写明每一个从哪来。那里面的东西**都不进 git**。

工具链用到的**每一个路径都在 `scripts/config.py` 里**，可以用 `ARK_*` 环境变量覆盖，
所以换一台机器不需要改任何脚本。查看它解析成什么：

```bash
python scripts/config.py          # 打印每个路径，以及它是否存在
```

### 二、把载荷组装到 `entry/libs/arm64-v8a/`

```bash
python scripts/prep_jdklib.py     # JDK 里按名字读取的那两个文件
python scripts/prep_lwjgl.py      # LWJGL —— jar 改名，原生库原样
python scripts/prep_arc.py        # Arc 的原生库，取自那个定版 jar
python scripts/prep_freetype.py   # Arc 的 freetype，取自 Arc 的 Android 构建
python scripts/prep_game.py       # 游戏 jar 本体
python scripts/prep_helper.py     # 编译并打包 helper jar
```

**每个脚本都会先校验输入的哈希**、写完再回读一遍，所以输入陈旧或不对时会
**直接报错退出**，而不会悄悄产出与测试过的版本不一致的产物。
每个脚本都支持 `--check`：只报告，不写文件。

JDK 派生的两个库（`jdk21/lib/server/libjvm_real.so` 与锚库 `libjvm.so`）出自
`prep_vendor.py` —— 见该文件顶部的说明。
`libcxxabi_shim.so` **不是派生物**：直接把 JDK 自己那份原样拷进去，
并由 `verify_hap.py` 钉住它的 SHA-1 来保证这一点。

### 三、构建

```bash
bash build.sh assembleHap        # 仅编译
bash deploy.sh                   # 构建 + 校验 + 安装 + 启动 + 收日志
```

`deploy.sh` 会在三种情况下**拒绝继续**：native 产物比源码旧、构建失败、打包校验不通过。
因为这三种情况各自都曾导致「构建显示成功，实际装上去的是上一次的产物」。

签名需要配置一次：DevEco Studio → File → Project Structure → Signing Configs →
Automatically generate signature。`deploy.sh` 安装的是 hvigor 产出的**已签名** HAP。

#### 上架用的包（`.app`）是另一条命令

```bash
bash build.sh assembleApp --mode project -p product=release -p buildMode=release
```

⭐ **`assembleApp` 只在 `--mode project` 下存在**；写 `--mode module` 会报
`Task [ 'assembleApp' ] was not found`。产物在 `build/outputs/release/`，
**product 名是路径的一部分**（`build/outputs/<product>/`）—— 早先曾在
`entry/build/default/` 里找一个其实在 `entry/build/release/` 的包。

写 `.app` 而非 `.hap`：应用市场只收 `.app`，`.hap` 是单模块包、用于本地安装。

#### ⚠️ 产物会累积，旧版本不会被自动删掉

`artifactName` 是**文件名的一部分** ⇒ **改版本号或换构建模式时，hvigor 写一个新名字的包，
但不会删掉旧的**（它已经不产那个名字了，就不认旧文件是自己的）。两个 product 目录
（`entry/build/<product>/outputs/default/`）都会这样一代代堆。

⚠️ **别靠文件名判断产物是什么版本** —— 读包自己的 `pack.info`：

```bash
python - <<'EOF'
import json, zipfile, glob
for p in sorted(glob.glob("entry/build/**/outputs/default/*.hap", recursive=True)):
    v = json.loads(zipfile.ZipFile(p).read("pack.info").decode())["summary"]["app"]["version"]
    print("%-50s name=%-14s code=%s" % (p.split("/")[-1], v["name"], v["code"]))
EOF
```

⚠️ 这个坑**同一天误导过两次检查**：排序取"第一个"会拿到旧包（`-v0.2.0-beta.2-`
按字节序排在 `-v0.2.0.2-` **前面**，因为 `-` 0x2D < `.` 0x2E）。

#### 装到哪台设备：`ARK_HDC_TARGET`

`deploy.sh` **带 `uninstall`**，所以它**拒绝在多设备时猜测**：

```bash
hdc list targets                                  # 先看有哪几台
ARK_HDC_TARGET=<上面列的 id> bash deploy.sh        # 显式指定
```

只有一台连着时它会自动用那一台；**零台或多台都会停下并说明**。
⚠️ 单设备时没有必要设这个变量。

#### ACL（受限权限）—— 只有上架会碰到

`ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY` 的权限级别在 API 12 变更为
`normal`，但官方要求**「为保证兼容性，在当前版本请继续采用受限权限申请方式」**
⇒ 走 ACL 路线。**AppGallery 的准入检测会逐条比对**包里的声明与 Profile 里的
ACL 列表，**少一条就不通过**，而且**改不了包、只能改 Profile**：

1. AGC → 申请该 ACL
2. **重新生成 Release Profile**（带 ACL 的那份）
3. 重新签名、重新上传

⚠️ 日常本地部署（产品 `default` + 调试证书）**不需要**这一步 —— 调试 profile 不查这个。

⚠️ **这个签名只属于你自己的机器。** DevEco 自动生成的是**调试 profile**，
它指定了允许安装的**设备 UDID 列表**，而产出的 HAP 里**内嵌了这份列表** ——
还有你的开发者 ID 与证书上的姓名。用它构建、用它安装都可以，**但不要把它发布出去**。
该发布什么见 **[RELEASE.md](../RELEASE.md)**。

---
# English

## Requirements

- DevEco Studio with the HarmonyOS SDK (`compatibleSdkVersion 6.1.1(24)`,
  `targetSdkVersion 26.0.0`)
- A HarmonyOS device or emulator
- Python 3.12, JDK 17 (only for the Arc patches and the helper jar)

## Building

The payload is **not** in this repository (see `.gitignore` for why), and neither
are the inputs it is assembled from. You must supply the inputs before the
project will build, because the HAP embeds all of the payload.

### 1. Put the inputs in `payload-src/`

`payload-src/README.md` lists them — three jars, two LWJGL natives and two files
out of the JDK — with where each comes from. Nothing there is committed.

Every path the toolchain uses is in **`scripts/config.py`**, overridable from the
environment with `ARK_*` variables, so a different machine does not have to edit
any script. To see what it resolves to:

```bash
python scripts/config.py          # each path, and whether it exists
```

### 2. Assemble the payload into `entry/libs/arm64-v8a/`

```bash
python scripts/prep_jdklib.py     # the JDK pieces that are read by name
python scripts/prep_lwjgl.py      # LWJGL -- jars renamed, natives in place
python scripts/prep_arc.py        # Arc's natives, taken from the pinned jar
python scripts/prep_freetype.py   # Arc's freetype, from Arc's Android build
python scripts/prep_game.py       # the game jar itself
python scripts/prep_helper.py     # compiles and packs the helper jar
```

Each script checks its input's hash before writing anything and re-reads what it
wrote, so a stale or wrong input fails loudly instead of producing a jar that
silently differs from the one that was tested. Any of them takes `--check` to
report without writing.

The JDK-derived libraries (`jdk21/lib/server/libjvm_real.so` and the anchor
`libjvm.so`) come from `prep_vendor.py` — see the note at the top of it.
`libcxxabi_shim.so` is not derived at all: the JDK's own file is copied and
shipped unmodified, and `verify_hap.py` pins its SHA-1 so that stays true.

### 3. Build

```bash
bash build.sh assembleHap        # just compile
bash deploy.sh                   # build + verify + install + launch + log
```

`deploy.sh` refuses to continue on a stale native object, a failed build, or a
packaging check that fails, because each of those once produced a green build
that installed the *previous* binary.

#### The store package (`.app`) is a different command

```bash
bash build.sh assembleApp --mode project -p product=release -p buildMode=release
```

⭐ **`assembleApp` exists only under `--mode project`**; with `--mode module` it
answers `Task [ 'assembleApp' ] was not found`. Output lands in
`build/outputs/release/` — **the product name is a path component**
(`build/outputs/<product>/`); a package was once looked for under
`entry/build/default/` when it was really in `entry/build/release/`.

An `.app`, not a `.hap`: AppGallery takes only `.app`; a `.hap` is one module, for
local installs.

#### ⚠️ Outputs accumulate, and the old ones are never deleted

`artifactName` is part of the file NAME, so a version bump or a mode switch makes
hvigor write a package under the new name and leave the old one in place — it no
longer produces that name, so it does not treat the old file as its output. Both
product directories (`entry/build/<product>/outputs/default/`) collect a pair per
bump.

⚠️ **Do not use the file name to find out what version a package is.** Read the
package's own `pack.info` (the snippet is in the Chinese section above).

This misled two separate checks on the same day: taking "the first" after sorting
gets the stale package, because `-v0.2.0-beta.2-` sorts before `-v0.2.0.2-`
(`-` is 0x2D, `.` is 0x2E).

#### Which device: `ARK_HDC_TARGET`

`deploy.sh` runs `uninstall`, so it **refuses to guess when more than one device
is attached**:

```bash
hdc list targets                                   # see what is connected
ARK_HDC_TARGET=<id from that list> bash deploy.sh  # state it explicitly
```

With exactly one device it uses it; with zero or several it stops and says why.
Nothing needs setting in the single-device case.

#### ACL (restricted permissions) — only the store route meets it

`ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY` became level `normal` in API 12,
but Huawei requires it to keep going through the restricted/ACL route for
compatibility. **AppGallery's admission check compares the package's declarations
against the Profile's ACL list**, and a missing entry fails the upload — and the
package is not what gets changed:

1. request that ACL in AGC
2. **regenerate the Release Profile** from the result
3. re-sign and re-upload

⚠️ Local installs (product `default`, debug certificate) need none of this — a
debug profile is not checked this way.

Signing must be configured once: DevEco Studio → File → Project Structure →
Signing Configs → Automatically generate signature. `deploy.sh` installs the
signed HAP that hvigor produces.

⚠️ **That signature is for your own machine.** DevEco's automatically generated
profile is a *debug* profile, which names the device UDIDs it is valid for, and
the HAP it produces embeds that list — plus your developer id and the name on
your certificate. Build with it, install with it, do not publish the result.
What to publish instead is in **[RELEASE.md](../RELEASE.md)**.
