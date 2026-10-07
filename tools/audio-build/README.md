# audio-build —— `libarcarm64.so` 的重建配方

> 这一份回答的是「**载荷里那个 `libarcarm64.so` 是怎么来的**」。
> 它原先只存在于 `MindustryArkDocs/mindustry-ohos/audio-build/`（仓库外），
> 2026-10-07 移入仓库，因为 `scripts/config.py` 与 `CMakeLists.txt` 都写着
> 「它的编译配方不在仓库里」—— 而那句话是当时唯一挡在「从仓库重建」前面的东西。

## 它为什么存在

官方那版 `libarcarm64.so` 的音频后端是 **miniaudio**，在 OpenHarmony 上没有可用的音频后端，
游戏里就是没声音。这里把它换成 **SDL3** 后端重编：

- 后端从 miniaudio 换成 SDL3（新增 `soloud_sdl3.cpp`）
- JNI 绑定不跑 jnigen，改用 `gen_jni.py` 直接从 `.java` 生成（命名规则相同）
- 官方那份是 **4 个类、83 个符号**，所以验收判据是**完整的 `Java_` 符号集**，不是只看 SoLoud 那一类
  （⚠️ 曾经只比 Soloud 的 66 个就宣布「零差异」，设备上 `NativeUtils.setEnv` 直接 `UnsatisfiedLinkError`）

## 怎么用

```bash
# 1. 准备输入（见下节），然后：
bash tools/audio-build/build.sh          # 生成 JNI → 编译 41 个目标 → 链接 → 自检
python tools/audio-build/fix_needed.py \
    <TMP>/soloudbuild/libarcarm64_new.so \
    <TMP>/soloudbuild/libarcarm64_fixed.so
python tools/audio-build/verify_so.py
python tools/audio-build/check_undef.py  # 未定义符号逐个到设备库中解析
python tools/audio-build/repack.py       # 把新库打进 jar
python tools/audio-build/verify_from_jar.py   # 独立来源：从 jar 字节码反推应有符号
bash tools/audio-build/build_test.sh     # 24 项本地真 JVM 功能测试（Windows DLL）
```

## 你要提供的（⛔ 都不在仓库里）

| 需要什么 | 从哪来 | 覆盖用的环境变量 |
| --- | --- | --- |
| **SoLoud 上游源码** | `Anuken/soloud` 的 tag **`2026.09.04`**（与 Arc `build.gradle` 里 `versions.soloud` 一致） | `ARK_SOLOUD_SRC` |
| **Arc 源码检出** | 含 `arc-core/src` 的那棵树（`gen_all_jni.py` 要读 4 个 `.java`） | `ARK_ARC_SRC`（⛔ **无默认值**，缺了直接报错） |
| OHOS NDK | DevEco Studio 自带 | `ARK_DEVECO_STUDIO` / `ARK_DEVECO_SDK_NATIVE` |
| JDK 17 | 仅 `build_test.sh` 用（跑 `javac`/`java`/`javap`） | `ARK_JAVA_HOME` |
| 一个能解析 `SDL_*` 的 `libSDL3.so` | 链接期用；设备上实际解析到 AMCL 那一份 | `ARK_SDL3_LIB` |

其余路径**全部是推导出来的**，不含用户名：
`ARK_TMP`（默认取 `TEMP`/`TMPDIR`）→ `soloudbuild/`、`soloud-src/`；
SDL 头用**仓库自带**的 `entry/src/main/cpp/SDL/include`（实测与原先那棵仓库外的拷贝逐字节相同）。

## ⛔ 没包含什么，为什么

| 缺的 | 为什么 |
| --- | --- |
| `libarcarm64_fixed.so`（490152 字节） | 它是**构建产物**，不是配方；而发运的那一份已经在载荷 `mindustry-1.0-audio.jar` 里。⚠️ 两者**不是同一个构建**（产物 490152 / sha1 `7deb18e1`，载荷里 498800 / `db9d78b1`），所以这个产物**不能当作发运物的对照** |
| SoLoud 源码 | 上游项目，公开可下载（见上表）。源码目录 `soloud-src/` 与工作树 `soloudbuild/` 由 `build.sh` 与 `ARK_SOLOUD_SRC` 决定 |

## ⚠️ 移入仓库时改动了什么（**未实测**）

为了不把带用户名的绝对路径带进仓库（`RELEASE-MAINTENANCE.md` 的发布检查会数它们，
并点名「带用户名的那一行值得中性化」），**8 个文件里的 ~35 处路径被改成环境变量 + 推导**。

- ✅ **已验证**：`bash -n`（2 个 shell）、`python -m py_compile`（9 个 py）全过；目录内**已无带用户名的路径**。
- ⛔ **未验证**：**没有真的跑过一次构建** —— 本机没有 SoLoud 源码，且重编需要上设备验证音频。
  ⇒ 参数化本身**没有经过端到端检验**，第一次真跑时请留意路径解析。

## 完整说明

原始文档（22 KB，含事故复盘与验证记录）：
`MindustryArkDocs/mindustry-ohos/README-音频修复说明.md`

---

# English

Rebuild recipe for the `libarcarm64.so` that ships inside the payload. Upstream's build uses
**miniaudio**, which has no usable audio backend on OpenHarmony, so this one is compiled against
**SDL3**; the JNI bindings are generated from the `.java` sources by `gen_jni.py` instead of jnigen.
The official library exports **83 `Java_` symbols across four classes**, so the acceptance
criterion is the **complete symbol set** -- comparing only Soloud's 66 is how a build once passed
review and then died with `UnsatisfiedLinkError` on `NativeUtils.setEnv`.

This directory used to live outside the repository, at
`MindustryArkDocs/mindustry-ohos/audio-build/`. It was moved in on 2026-10-07 because both
`scripts/config.py` and `CMakeLists.txt` stated that the compile recipe was not in the repository,
and that statement was the only thing standing between this project and a rebuild from source.

## What you must supply (none of it is committed)

| Needed | Where from | Override |
| --- | --- | --- |
| SoLoud sources | tag **`2026.09.04`** of `Anuken/soloud` (matches `versions.soloud` in Arc's `build.gradle`) | `ARK_SOLOUD_SRC` |
| Arc checkout | the tree containing `arc-core/src` | `ARK_ARC_SRC` (no default -- it errors out) |
| OHOS NDK | ships with DevEco Studio | `ARK_DEVECO_STUDIO` / `ARK_DEVECO_SDK_NATIVE` |
| JDK 17 | `build_test.sh` only | `ARK_JAVA_HOME` |
| A `libSDL3.so` to link against | link time only; the device resolves AMCL's copy | `ARK_SDL3_LIB` |

Every other path is derived and contains no username. SDL headers come from the repository's own
`entry/src/main/cpp/SDL/include`, which was measured byte-for-byte identical to the out-of-repo copy
the script used before.

## Not included, on purpose

`libarcarm64_fixed.so` is a build output, not part of the recipe, and the shipped one is already
inside the payload jar. Note the two are **different builds** (490152 / sha1 `7deb18e1` versus
498800 / `db9d78b1`), so the output here is **not** a reference for what ships.

## What changed on the way in -- and what was not verified

Roughly 35 hard-coded paths across 8 files were replaced with environment variables and derived
defaults, so that no username-bearing absolute path enters the repository.

- Verified: `bash -n` on both shell scripts, `python -m py_compile` on all nine Python files, and
  no username paths remain under this directory.
- **Not verified: the build was never run.** SoLoud sources are not on this machine and a rebuild
  needs a device to confirm audio. The parameterisation has had no end-to-end test.

Full write-up (22 KB, including the incident reviews and the verification log):
`MindustryArkDocs/mindustry-ohos/README-音频修复说明.md`.
