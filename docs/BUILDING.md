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
**没有 ACL 重签名这一步**，因为本应用不需要任何受限权限（见 [PERMISSIONS.md](PERMISSIONS.md)）。

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

Signing must be configured once: DevEco Studio → File → Project Structure →
Signing Configs → Automatically generate signature. `deploy.sh` installs the
signed HAP that hvigor produces; there is no ACL re-signing step, because this
app needs no restricted permissions (see [PERMISSIONS.md](PERMISSIONS.md)).

⚠️ **That signature is for your own machine.** DevEco's automatically generated
profile is a *debug* profile, which names the device UDIDs it is valid for, and
the HAP it produces embeds that list — plus your developer id and the name on
your certificate. Build with it, install with it, do not publish the result.
What to publish instead is in **[RELEASE.md](../RELEASE.md)**.
