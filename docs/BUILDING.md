# 构建 · Ark Launcher

[← 返回 README](../README.md) · [← Back to README](../README.en.md)

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

### 一之二、⭐ 先把 JDK 树铺进 `entry/libs/arm64-v8a/jdk21/`

⛔ **这一步没有脚本，而且它的输入也不在 `payload-src/` 里。**
`prep_jdklib.py` 与 `prep_jdkconf.py` 把 `entry/libs/arm64-v8a/jdk21/` 当作**输入**去读
（前者读 `lib/tzdb.dat`，后者读整个 `conf/` 与 `lib/security/`），
但**没有任何脚本创建它** —— 少了它，下面链条的第一步就报：

```
tzdb.dat  source MISSING at <entry/libs>/arm64-v8a/jdk21/lib/tzdb.dat
```

它必须是一棵 **OpenJDK 21 的 OpenHarmony（musl / aarch64）** 构建，桌面 JDK 不行。
最少要有：

```
entry/libs/arm64-v8a/jdk21/
├── release
├── conf/             prep_jdkconf.py 的输入（security/ 等）
└── lib/
    ├── modules       134 MB 的模块镜像；patch_libjvm.py 会把它改名成 jimg.so 发运
    ├── tzdb.dat      prep_jdklib.py 的输入（游戏读日期时会打开它）
    └── …             其余 JDK 库
```

⚠️ **这不是一处笔误，是这个仓库目前的一个真实缺口**：从一份干净的克隆加上
`payload-src/` 出发，链条跑不起来。记在这里是为了让下一个遇到它的人一眼看到，
而不是先花半小时怀疑自己的 `tzdb.dat` 路径。已记入下列两份文档的待办。

⭐ 手边有一份旧构建时，最省事的办法就是把它拷过来（`entry/libs/` 与 `payload-src/`
一样不进 git，所以它在你机器上通常是有的）：

```bash
# 从另一个已经构建过的检出里拷
cp -r <另一个检出>/entry/libs/arm64-v8a/jdk21 entry/libs/arm64-v8a/jdk21
```
同一台机器上只有一份时，它一般还留在你自己的 `entry/libs/` 里 —— 只要别把整个目录删掉。

### 二、把载荷组装到 `entry/libs/arm64-v8a/`

```bash
python scripts/prep_jdklib.py     # JDK 里按名字读取的那两个文件
python scripts/prep_jdkconf.py    # java.home 相对路径下的其余文件（conf/ 等）
python scripts/prep_lwjgl.py      # LWJGL —— jar 改名，原生库原样
python scripts/prep_arc.py        # Arc 的原生库，取自带着我们原生库的那份 jar
python scripts/prep_freetype.py   # Arc 的 freetype，取自 Arc 的 Android 构建
python scripts/prep_game.py       # ⭐ 游戏 jar = 上游原版，逐字节不改
python scripts/prep_helper.py     # 编译并打包 helper jar
```

**每个脚本都会先校验输入的哈希**、写完再回读一遍，所以输入陈旧或不对时会
**直接报错退出**，而不会悄悄产出与测试过的版本不一致的产物。
每个脚本都支持 `--check`：只报告，不写文件。

### 二之二、把我们的 Arc 修改打成补丁 jar

```bash
python scripts/build_arc_patch.py   # 编译两半补丁（arc-core + backend-sdl3）
python scripts/make_patch_jar.py    # 装成 entry/libs/arm64-v8a/patchjar/arcpatch.so
```

⭐ **这一版架构（2026-09-29 起）里，游戏 jar 是上游原版、一个字节都不改**，
我们的 Arc 类走这个独立的 jar，由启动器排在 classpath **最前面**压过同名类。

⇒ 跟进上游因此变成：**换 `payload-src/Mindustry.jar` → 改两个 SHA-1 钉子 → 重建**，
补丁类通常不用重新编译。实测：同一份补丁 jar 同时驱动 160.4 与 160.5。

⚠️ **顺序是承重的**：`launcher.c` 里 `PATCH_JAR` 必须排在 `GAME_JAR` 前面，
否则补丁完全不起作用，而应用只会「行为不对」、不报任何错。
`verify_hap.py` 的第 6b 段会在产物里确认它在。

⚠️ `make_patch_jar.py` 打包的是 **`arcbuild/sdl3` 整个目录** + 3 个 arc-core 类
（共 26 个），不是「改动过的那些文件」—— 因为 `arc/backend/sdl/` 是**整目录替换**。
收窄过一次，结果是设备上 `NoSuchFieldError: SdlConfig.appName`。

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

⚠️ **全新克隆要先补一份签名配置的骨架。** 根目录的 `build-profile.json5` **不在仓库里**
—— DevEco Studio 会把签名物料（certpath、keyPassword、storeFile、storePassword…）
直接写进那份文件，那些不属于公开仓库。仓库里带的是它的骨架：

```bash
cp build-profile.json5.template build-profile.json5
```

签名需要配置一次：DevEco Studio → File → Project Structure → Signing Configs →
Automatically generate signature —— 它会写进上面那份文件。`deploy.sh` 安装的是 hvigor
产出的**已签名** HAP。

#### ⚠️ 改了 native 编译标志之后（`-ffile-prefix-map` 等）

`entry/src/main/cpp/CMakeLists.txt` 里有三个编译器路径映射，用来把**构建机的绝对路径**
从产物里去掉（`__FILE__` 会把它写进 `.rodata`，**strip 去不掉**，见
[RELEASE-MAINTENANCE.md](../RELEASE-MAINTENANCE.md) 发布检查表）。动这类标志有**两个坑**：

1. ⚠️ **`entry/.cxx` 一个 product/buildMode 一份 CMake 缓存** ⇒ **不清缓存，新标志不生效**：
   ```bash
   rm -rf entry/.cxx entry/build/default/intermediates/cmake
   ```
2. ⚠️⚠️ **`BUILD SUCCESSFUL` 不代表 native 重编了**。实测过一次 10 秒的「成功」构建，
   日志一切正常而编译根本没跑。**唯一可靠的检查是数产物里的字符串**：
   ```bash
   python - <<'EOF'
   import re, zipfile, glob
   # 边界组和「至少两层目录」都是承重的：没有边界时 "https://x" 会被它的 "s:/" 命中，
   # 而 conf/security 那些文件在注释里提到真实 Windows 路径 —— 实测 160 行噪声、4 个真命中。
   # 一个永远报 FAIL 的检查等于没有检查。
   pat = re.compile(rb"(?:^|[^A-Za-z0-9])[A-Za-z]:[\/][ -~]{0,120}?[\/][ -~]{0,120}?[\/]")
   tot = 0
   for z in sorted(glob.glob("entry/build/**/*.hap", recursive=True)):
       with zipfile.ZipFile(z) as f:
           for n in f.namelist():
               h = pat.findall(f.read(n))
               if h:
                   print("  %s :: %s (%d)" % (z, n, len(h))); tot += len(h)
   print("total =", tot)
   EOF
   ```
   ✅ 当前期望值：**14**（`libSDL3.so` 0、`libmain.so` 1、`libarcarm64.so` 7、
   `libcxxabi_shim.so` 6）。**后两个是刻意不修的**，理由写在发布检查表那一条里 ——
   **看到它们不是回归**，但**看到 `libSDL3.so` 有命中就是**。
3. ⚠️ 改完要**验它还能跑**（native 标志改动真的会影响运行）：装机 → 启动 →
   看 `[Mindustry] Version:` 那行和音频回调，别只看构建成功。
   ⭐ 用这个串而不是版本号 —— 它是**游戏自己**的格式串（在 `mindustry/Vars.class` 里），**跨版本不变**。

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

⚠️ **2026-09-22 更新**：`READ_WRITE_DOWNLOAD_DIRECTORY` **已从包里移除**，
⇒ **它那条 ACL 申请随之取消**。⚠️ **但本节仍然有效，而且仍然是 RC 的头号阻塞** ——
因为它现在只针对**另一条**权限：

**`ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY`**（沙箱里匿名内存可执行，
JIT 需要它）。它只在**商店构建**时由 `scripts/make_store_app.sh` 注入，
要配套的 ACL Profile 才装得上。见 [RELEASE-MAINTENANCE.md](../RELEASE-MAINTENANCE.md) §2.11。

**AppGallery 的准入检测会逐条比对**包里的声明与 Profile 里的 ACL 列表，
**少一条就不通过**，而且**改不了包、只能改 Profile**：

1. AGC → 申请该 ACL
2. **重新生成 Release Profile**（带 ACL 的那份）
3. 重新签名、重新上传

⚠️ 日常本地部署（产品 `default` + 调试证书）**不需要**这一步 —— 调试 profile 不查这个。

⚠️ **这个签名只属于你自己的机器。** DevEco 自动生成的是**调试 profile**，
它指定了允许安装的**设备 UDID 列表**，而产出的 HAP 里**内嵌了这份列表** ——
还有你的开发者 ID 与证书上的姓名。用它构建、用它安装都可以，**但不要把它发布出去**。
该发布什么见 **[RELEASE.md](../RELEASE.md)**。

---
### 四、另外两种包形态

日常的 `bash build.sh assembleHap` 出的是 **HAP**。要出**应用商店的 `.app`** 用另一个脚本，
它按模式改变包形状（是否注入权限、面向哪些设备）：

| 模式 | 设备 | 可执行内存权限 | 内容 |
|---|---|---|---|
| `bash scripts/make_store_app.sh tablet` | 平板 + 2in1 | **注入** | 完整：JDK + 游戏 |
| `bash scripts/make_store_app.sh tools` | 手机 + 平板 + 2in1 | **不注入** | **无 JDK、无游戏**（管理工具，约 1.5 MB） |

⭐ **想在自己机器上试这个包形状**，加 `--hap`：产出**可以侧载的 debug 签名 HAP**，
而不是只能上传的 release `.app`。

| 命令 | 产物 | 能不能装到自己的设备上 |
|---|---|---|
| `bash scripts/make_store_app.sh tools` | `dist/store/…-tools.app` | ⛔ **不能**（release 证书，只给上传） |
| `bash scripts/make_store_app.sh tools --hap` | `dist/…-tools-hap.hap` | ✅ 可以 |

⚠️ **`--hap` 不改包形状** —— 权限注不注入、`deviceTypes` 是哪一组，仍由模式决定，
`entry/libs/` 也**照样挪走再挪回**（所以出来的确实是「无运行时」那个）。
它只改**容器与签名**。⚠️⚠️ 少了「挪走」那一步，出来的就是**带 JDK 的完整包**，
而它在手机上**装得上** ⇒ 这次测试会安静地测错东西。

它用 **`product=default` + `buildMode=release`**，两半各管一件事：前者给**调试证书**（所以能侧载），
后者让原生库**按商店包那样 strip 与优化**。⛔ 别改成 `buildMode=debug`：实测产物从
**3.9 MB 涨到 9.2 MB**，而体积闸门的上限是 10 MB ⇒ 一条该不该报的闸门会变成边界值检查；
而且**商店包就是 release 档**，拿 debug 档的原生库测的不是要上架的那个东西。

⛔ **别用 `bash deploy.sh` 装它** —— 那个脚本会自己构建**带运行时**的 HAP，并且带
`hdc uninstall`（会清空应用沙盒）。直接装这个文件：

```bash
hdc install -r dist/ArkLauncher-<版本>-tools-hap.hap
```

⛔⛔ **`tools` 只属于 Ark Launcher（`lite` 分支）。** 范围是「拆分包体仅限于 Ark Launcher，
Mindustry Ark 不做实际的拆分包体」。脚本里有一道门：在 `config.SHIPS_GAME` 为 `True` 的树上
**直接拒绝运行**（在任何文件被碰之前）。只有 `lite` 那棵树是 `False`。

⭐ **`tools` 不需要 `entry/libs/` 那棵 JDK 树** —— 它把整个 `arm64-v8a/` 挪走、构建完再挪回。
而那棵树**没有脚本能重建**（见上面「一之二」）⇒ **`tools` 是一份干净克隆唯一能构建出来的
产物**，也就能当「这条工具链是否完好」的验收。

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

### 1b. Put the JDK tree in `entry/libs/arm64-v8a/jdk21/`

⛔ **There is no script for this, and its input is not in `payload-src/` either.**
`prep_jdklib.py` and `prep_jdkconf.py` read `entry/libs/arm64-v8a/jdk21/` as **input**
(the first reads `lib/tzdb.dat`, the second reads all of `conf/` and `lib/security/`),
but **nothing creates it** — without it the first step of the chain below reports:

```
tzdb.dat  source MISSING at <entry/libs>/arm64-v8a/jdk21/lib/tzdb.dat
```

It has to be an **OpenJDK 21 build for OpenHarmony (musl / aarch64)**; a desktop JDK will not do.
At minimum it contains:

```
entry/libs/arm64-v8a/jdk21/
├── release
├── conf/            input to prep_jdkconf.py (security/ and friends)
└── lib/
    ├── modules      the 134 MB module image; patch_libjvm.py ships it renamed to jimg.so
    ├── tzdb.dat     input to prep_jdklib.py (the game opens it when it asks for a date)
    └── ...          the rest of the JDK's libraries
```

⚠️ **This is not a typo, it is a real gap in this repository**: starting from a clean clone plus
`payload-src/`, the chain does not run. It is written down so that the next person hits the
explanation instead of spending half an hour doubting their `tzdb.dat` path.

⭐ With an earlier build at hand, the cheapest fix is to copy the tree across (`entry/libs/`, like
`payload-src/`, is not in git, so it usually exists on a machine that has built once):

```bash
cp -r <another-checkout>/entry/libs/arm64-v8a/jdk21 entry/libs/arm64-v8a/jdk21
```
If there is only one checkout on the machine, it is probably still in your own `entry/libs/` --
just do not delete that whole directory.

### 2. Assemble the payload into `entry/libs/arm64-v8a/`

```bash
python scripts/prep_jdklib.py     # the JDK pieces that are read by name
python scripts/prep_jdkconf.py    # the rest of what java.home reads (conf/)
python scripts/prep_lwjgl.py      # LWJGL -- jars renamed, natives in place
python scripts/prep_arc.py        # Arc's natives, from the jar that carries OURS
python scripts/prep_freetype.py   # Arc's freetype, from Arc's Android build
python scripts/prep_game.py       # ⭐ the game jar = upstream, byte for byte
python scripts/prep_helper.py     # compiles and packs the helper jar
```

Each script checks its input's hash before writing anything and re-reads what it
wrote, so a stale or wrong input fails loudly instead of producing a jar that
silently differs from the one that was tested. Any of them takes `--check` to
report without writing.

### 2b. Pack our Arc changes into a patch jar

```bash
python scripts/build_arc_patch.py   # compiles both halves (arc-core + backend-sdl3)
python scripts/make_patch_jar.py    # packs entry/libs/arm64-v8a/patchjar/arcpatch.so
```

⭐ **Since 2026-09-29 the game jar is upstream's, byte for byte.** Our Arc classes
travel in this separate jar, which the launcher puts FIRST on the class path so
they shadow the same-named classes in the game jar.

⇒ Following an upstream release is now: replace `payload-src/Mindustry.jar`,
update two SHA-1 pins, rebuild -- and usually do not recompile the patch at all.
Measured: the same patch jar bytes drive both 160.4 and 160.5.

⚠️ **The order is load-bearing.** `PATCH_JAR` must precede `GAME_JAR` in
`launcher.c`, or the patch does nothing and the app merely behaves wrong without
reporting anything. Section 6b of `verify_hap.py` checks the jar is in the package.

⚠️ `make_patch_jar.py` packs **the whole `arcbuild/sdl3` directory** plus three
arc-core classes (26 in total), not "the files we edited" -- because
`arc/backend/sdl/` is replaced as a DIRECTORY. It was narrowed to the edited files
once, and the device died with `NoSuchFieldError: SdlConfig.appName`.

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

⚠️ **Updated 2026-09-22**: `READ_WRITE_DOWNLOAD_DIRECTORY` **has been removed from
the package**, so **its ACL application is cancelled**. ⚠️ **This section still
applies, and it is still the number-one RC blocker** -- it now covers **one other**
permission:

**`ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY`** (anonymous memory in the
sandbox made executable, which the JIT needs). It is injected only for the **store
build**, by `scripts/make_store_app.sh`, and needs a matching ACL Profile to install.
See [RELEASE-MAINTENANCE.md](../RELEASE-MAINTENANCE.md) §2.11.

**AppGallery's admission check compares the package's declarations against the
Profile's ACL list**, and a missing entry fails the upload — and the package is not
what gets changed:

1. request that ACL in AGC
2. **regenerate the Release Profile** from the result
3. re-sign and re-upload

⚠️ Local installs (product `default`, debug certificate) need none of this — a
debug profile is not checked this way.

⚠️ **A fresh clone needs the signing config's skeleton put in place first.** The root
`build-profile.json5` is **not in the repository** — DevEco Studio writes the signing
material straight into it (certpath, keyPassword, storeFile, storePassword, …), and
none of that belongs in a public repository. What the repository carries is its
skeleton:

```bash
cp build-profile.json5.template build-profile.json5
```

Signing must then be configured once: DevEco Studio → File → Project Structure →
Signing Configs → Automatically generate signature — which writes into the file
above. `deploy.sh` installs the signed HAP that hvigor produces.

#### ⚠️ After touching a native compile flag (`-ffile-prefix-map`, etc.)

`entry/src/main/cpp/CMakeLists.txt` carries three compiler path mappings that keep
the build machine's absolute paths out of the artifacts (`__FILE__` writes them
into `.rodata`, and **stripping does not remove them** — see the release checklist
in [RELEASE-MAINTENANCE.md](../RELEASE-MAINTENANCE.md)). Changing flags there has
**two traps**:

1. ⚠️ **`entry/.cxx` holds one CMake cache per product/buildMode** ⇒ **the new flag
   does not reach a cache that already exists**:
   ```bash
   rm -rf entry/.cxx entry/build/default/intermediates/cmake
   ```
2. ⚠️⚠️ **`BUILD SUCCESSFUL` does not mean the native code recompiled.** A
   ten-second "successful" build was measured where nothing was compiled at all.
   **The only acceptable check is counting the strings in the product** — the
   script is in the Chinese half of this file, and the expected result is
   **14** (`libSDL3.so` 0, `libmain.so` 1, `libarcarm64.so` 7,
   `libcxxabi_shim.so` 6). **The last two are deliberately left; seeing them is not
   a regression — seeing any hit in `libSDL3.so` is.**
3. ⚠️ Then **verify it still runs** (a native flag change really can affect
   execution): install, launch, and look for the `[Mindustry] Version:` line and the
   audio callbacks. A green build is not that check.
   ⭐ Search for that string rather than a version number — it is the **game's own** format
   string (in `mindustry/Vars.class`) and **does not change between versions**.

⚠️ **That signature is for your own machine.** DevEco's automatically generated
profile is a *debug* profile, which names the device UDIDs it is valid for, and
the HAP it produces embeds that list — plus your developer id and the name on
your certificate. Build with it, install with it, do not publish the result.
What to publish instead is in **[RELEASE.md](../RELEASE.md)**.

### 4. The other two package shapes

`bash build.sh assembleHap` produces the **HAP**. The **store `.app`** comes from a different
script, which changes the shape of the package by mode (whether a permission is injected, and
which devices it claims):

| Mode | Devices | Executable-memory permission | Contents |
|---|---|---|---|
| `bash scripts/make_store_app.sh tablet` | tablet + 2in1 | **injected** | full: JDK + game |
| `bash scripts/make_store_app.sh tools` | phone + tablet + 2in1 | **not injected** | **no JDK, no game** (a management tool, ~1.5 MB) |

⭐ **To try that shape on your own device**, add `--hap`: it produces a **sideload-able,
debug-signed HAP** instead of the upload-only release `.app`.

| Command | Artifact | Installable on your own device |
|---|---|---|
| `bash scripts/make_store_app.sh tools` | `dist/store/…-tools.app` | ⛔ no (release certificate, upload only) |
| `bash scripts/make_store_app.sh tools --hap` | `dist/…-tools-hap.hap` | ✅ yes |

⚠️ **`--hap` does not change the package shape** -- whether the permission is injected and which
`deviceTypes` are claimed still come from the mode, and `entry/libs/` is **still moved aside and
back** (which is why the result really is the no-runtime one). Only the container and the signing
config differ. ⚠️⚠️ Without that move you get the full package **with** the JDK, and it *does*
install on a phone -- so the test would quietly test the wrong thing.

It uses **`product=default` + `buildMode=release`**, and the two halves do different jobs: the
first gives the **debug certificate** (hence sideload-able), the second strips and optimises the
native libraries **the way the store package does**. ⛔ Do not switch it to `buildMode=debug`:
measured, the artifact goes from **3.9 MB to 9.2 MB** against a 10 MB size gate, so a check that
ought to catch regressions becomes a boundary value; and the store package is a release build, so
debug natives test something other than what ships.

⛔ **Do not use `bash deploy.sh` to install it** -- that script builds its own HAP *with* the
runtime and runs `hdc uninstall` (wiping the app sandbox). Install the file directly:

```bash
hdc install -r dist/ArkLauncher-<version>-tools-hap.hap
```

⛔⛔ **`tools` belongs to Ark Launcher (the `lite` branch) only.** The scope is 拆分包体仅限于
Ark Launcher, Mindustry Ark 不做实际的拆分包体. The script refuses the mode unless
`config.SHIPS_GAME` is `False` -- which is this repository's branch identity -- and it refuses
before touching anything. Only the `lite` tree has it `False`.

⭐ **`tools` does not need the JDK tree under `entry/libs/`** -- it moves the whole `arm64-v8a/`
aside and back. That tree **has no script that can rebuild it** (see 1b above), so `tools` is the
one artifact a clean clone can produce, and therefore also a way to check that the toolchain
itself is intact.
