# payload-src —— 构建输入清单

> 本目录**不进 git**（`.gitignore`：`payload-src/*` 之后跟 `!payload-src/README.md`）。
> 本文件是这里**唯一**被跟踪的东西 —— 所以清单只能写在它里面。

⚠️ **2026-10-07 之前，这个文件只有两行**，内容是「详见 `payload.zip` 中的 `README-PAYLOAD.txt`」。
那是个**环**：`payload.zip` 是 `scripts/make_payload_zip.py` 生成的**下游**产物，
要拿到它得先把载荷构建出来，而构建又需要这份清单。
于是 `docs/BUILDING.md` 说「按 `payload-src/` 凑齐输入」，而它指的那份说明在环里。
本文件补上这个实体。下面的哈希**逐条实测核对过**，不是从别处抄来的。

---

# 中文

## 一、要你自己提供的（8 个文件）

| 相对路径 | 字节 | sha1（仓库里的钉子，实测已核对） | 从哪来 |
| --- | ---: | --- | --- |
| `Mindustry.jar` | 88902250 | `8e0fd5d7dd7828fccff59a693a635948883a704b` | 上游 Mindustry **v8 Build 160.5** 官方桌面发布版，逐字节不改。它的 `version.properties` 写着 `build=160.5, modifier=release, type=official` |
| `lwjgl-ohos/lwjgl.jar` | 1287240 | `cd7dd7a13abce9a2764364f58e138c6f99f50a7f` | LWJGL 的 OHOS 移植。三个 jar 加两个原生库**必须来自同一次 LWJGL 发布**（`prep_lwjgl.py` 的原话：它们「取自一个已构建好的 HarmonyOS 应用」） |
| `lwjgl-ohos/lwjgl-opengl.jar` | 964989 | `27698e706465a088d4c8eda34f98d69e5c8b32f7` | 同上 |
| `lwjgl-ohos/lwjgl-sdl.jar` | 1018499 | `96d577ef9b661fe4bb9bfb32fbb1de3ff34219cd` | 同上 |
| `lwjgl-ohos/liblwjgl.so` | 496200 | `663e5cab870ac3427cbfbe01f93facbc260fa504` | 同上（真 ELF 共享对象） |
| `lwjgl-ohos/liblwjgl_opengl.so` | 343472 | `f3661e892d4d2deb3aa574cab2e64c13b7ac6b4d` | 同上 |
| `jdk21slim/lib/server/libjvm.so` | 25322128 | `871ffd37689f020ed53332db97d64f5dcb110771` | 从一棵 **OpenJDK 21 的 OpenHarmony（musl / aarch64）** 构建里取出的 `lib/server/libjvm.so`。桌面 JDK 不行 |
| `jdk21slim/lib/libcxxabi_shim.so` | 10120 | `b605f5863ca1a75170a814ab4054a9867c346e15` | 在**另一个项目**（`sdl-template`）里构建，按字节原样分发；`verify_hap.py` 会校验它的 SHA-1，所以**不要**为了美观去重编它 |

**钉子的权威出处**（本表只是副本，改哪边都要一起改）：
- `Mindustry.jar` —— `scripts/prep_game.py` 的 `SRC_SHA1`
- `lwjgl-ohos/*` —— `scripts/prep_lwjgl.py` 的 `NATIVES`（两个 `.so`）与 `JARS`（三个 jar）
- JDK 那两个文件**没有哈希钉子**，上面是实测值，仅供核对

## 二、脚本自己生成的（⛔ 不要手工提供）

放在本目录只是历史位置，它们是**流水线的产物**：

| 相对路径 | 谁生成 | 备注 |
| --- | --- | --- |
| `mindustry-1.0.jar` | `patch_mindustry.py` | = `config.PATCHED_JAR`，又是 `build_variants.py` 的基础 jar |
| `mindustry-1.0-audio.jar` | `build_variants.py` | = `config.NATIVES_JAR`。⚠️ **但它实际上得当成输入** —— 见第四节 |
| `mindustry-1.0-audio-debug.jar` | `build_variants.py` | 同上，debug 变体 |

## 三、遗留的，可以删

| 相对路径 | 为什么可以删 |
| --- | --- |
| `Mindustry-160.4.jar` | 已被 160.5 取代。**实测没有任何脚本引用它** |
| `Mindustry-160.5.jar` | 与 `Mindustry.jar` **逐字节相同**（sha256 一致）⇒ 纯冗余 |

## 四、⭐ `libarcarm64.so` —— 配方已收进仓库

这份 `.so` 是**我们自编的 Arc 原生库**：官方那份走 miniaudio，在鸿蒙上没有可用的音频后端，
所以我们用 SDL3 后端重编了一版。

- ✅ **要发运的二进制**：包在 `mindustry-1.0-audio.jar` 里（498800 字节，
  sha1 `db9d78b196beaa237a153b622b781e06be973462` —— 钉子写在 `scripts/prep_arc.py` 的 `NATIVES`）。
  `prep_arc.py` 从这份 jar 里把它解出来。⇒ **你不需要自己编译它**，但二进制得你在。
- ⭐ **配方在 `tools/audio-build/`**（19 个配方文件 + 它自己的 `README.md`）——
  `build.sh`（一键重建：生成 JNI → 编译 41 个目标 → 链接 → 自检）、
  `soloud_sdl3.cpp`（自写的 SDL3 后端）、`patch_soloud.py`（给 SoLoud 打 4 处补丁，幂等）、
  `gen_jni.py` / `gen_all_jni.py` / `jni/*.cpp`（4 个类的 83 个绑定）、
  `fix_needed.py`（把 `DT_NEEDED` 从 `libSDL3.so.0` 改写成 `libSDL3.so`，等长替换）、
  `repack.py` / `verify_so.py` / `check_undef.py` / `verify_from_jar.py`、
  `ArcJniTest.java` + `build_test.sh`（24 项本地真 JVM 功能测试）。
  ⚠️ 2026-10-07 从仓库外的 `MindustryArkDocs/mindustry-ohos/audio-build/` 移入，
  移入时把 ~35 处带用户名的绝对路径换成了环境变量 + 推导（理由见那个目录的 README）。
- ⛔ **重建还缺一样，而它是公开的**：SoLoud 上游源码。`build.sh` 默认从 `%TEMP%/soloud-src` 读它，
  而该目录 2026-10-07 实测**已空（0 个文件）**。取法：`Anuken/soloud` 的 tag
  **`2026.09.04`**（与 Arc 的 `build.gradle` 里 `versions.soloud` 一致），
  可用 `ARK_SOLOUD_SRC` 指过去。`%TEMP%/soloudbuild` 工作树同样已空，但它由 `build.sh` 自己重建。
- ✅ **其余依赖都还在**：SDL 官方的 include 目录（本机上有 98 个文件，`build.sh` 里指向它）、
  `MindustryArkDocs/sdl3-ohos/libSDL3.so`（链接期解析 `SDL_*` 用，1.8 MB）、OHOS NDK。
  另外 `ARK_ARC_SRC`（Arc 检出）是 `gen_all_jni.py` 的必需输入，**故意没有默认值**。
- ⚠️ **那个 490152 字节的产物没有进仓库**：它是构建产物，不是配方；而它与 jar 里发运的那份
  （498800 / `db9d78b1…`）**不是同一个构建**，所以它也不能当作发运物的对照。
- ⇒ **结论**：`mindustry-1.0-audio.jar` 仍是**你必须提供的输入**（你不需要编译它，但得有）；
  **配方已可从仓库取得**。真正还挡在「完全从仓库重建」前面的，只剩**公开可下载的 SoLoud 源码**。

## 五、缺件会怎样

```bash
python scripts/config.py     # 打印每一个路径，以及它是否存在（MISSING / not yet built）
```

`config.py` 的 `require()` 在缺件时**直接退出**，并且提示来看本文件。
其他已记录的缺口见 `docs/BUILDING.md`：`entry/libs/arm64-v8a/jdk21/` 那棵完整 JDK 树（§一之二），
以及载荷本身的做法（`scripts/make_payload_zip.py`）。

---

# English

> This directory is **not in git** (`.gitignore`: `payload-src/*` then `!payload-src/README.md`).
> This file is the only tracked thing in it, so the manifest has to live here.
>
> Until 2026-10-07 it held two lines pointing at `README-PAYLOAD.txt` inside `payload.zip` --
> which is a **cycle**, because that zip is produced *downstream* by `make_payload_zip.py`,
> and building it is what needs the inputs this file is supposed to list.
> Every hash below was measured against the files on disk, not copied.

## 1. You provide these (8 files)

| Path | Bytes | sha1 (pinned in the repo, verified) | Where it comes from |
| --- | ---: | --- | --- |
| `Mindustry.jar` | 88902250 | `8e0fd5d7dd7828fccff59a693a635948883a704b` | Upstream Mindustry **v8 Build 160.5**, official desktop release, byte-for-byte unmodified |
| `lwjgl-ohos/lwjgl.jar` | 1287240 | `cd7dd7a13abce9a2764364f58e138c6f99f50a7f` | The OHOS port of LWJGL. The three jars and two natives **must come from one LWJGL release** |
| `lwjgl-ohos/lwjgl-opengl.jar` | 964989 | `27698e706465a088d4c8eda34f98d69e5c8b32f7` | same |
| `lwjgl-ohos/lwjgl-sdl.jar` | 1018499 | `96d577ef9b661fe4bb9bfb32fbb1de3ff34219cd` | same |
| `lwjgl-ohos/liblwjgl.so` | 496200 | `663e5cab870ac3427cbfbe01f93facbc260fa504` | same (a real ELF shared object) |
| `lwjgl-ohos/liblwjgl_opengl.so` | 343472 | `f3661e892d4d2deb3aa574cab2e64c13b7ac6b4d` | same |
| `jdk21slim/lib/server/libjvm.so` | 25322128 | `871ffd37689f020ed53332db97d64f5dcb110771` | From an **OpenJDK 21 OpenHarmony (musl / aarch64)** build. A desktop JDK will not do |
| `jdk21slim/lib/libcxxabi_shim.so` | 10120 | `b605f5863ca1a75170a814ab4054a9867c346e15` | Built in a **different project** (`sdl-template`) and shipped byte-for-byte; `verify_hap.py` checks its SHA-1, so do not rebuild it for tidiness |

Authoritative pins: `Mindustry.jar` in `scripts/prep_game.py` (`SRC_SHA1`);
`lwjgl-ohos/*` in `scripts/prep_lwjgl.py` (`NATIVES`, `JARS`).
The two JDK files have no pin -- those values are measurements, for checking only.

## 2. Produced by the scripts (do **not** supply by hand)

`mindustry-1.0.jar` (`patch_mindustry.py`), `mindustry-1.0-audio.jar` and
`mindustry-1.0-audio-debug.jar` (`build_variants.py`).
They live here for historical reasons; they are pipeline outputs.

## 3. Leftovers, safe to delete

`Mindustry-160.4.jar` (superseded, referenced by nothing) and `Mindustry-160.5.jar`
(byte-identical to `Mindustry.jar`).

## 4. `libarcarm64.so` -- the recipe is in the repository now

Our own Arc native library: upstream's uses miniaudio, which has no usable audio backend on
HarmonyOS, so this one was rebuilt against SDL3.

- **The shipped binary** is inside `mindustry-1.0-audio.jar` (498800 bytes, sha1
  `db9d78b196beaa237a153b622b781e06be973462`, pinned in `scripts/prep_arc.py`), which
  `prep_arc.py` unpacks. You do not have to compile it -- but you do have to have it.
- **The recipe lives at `tools/audio-build/`** (19 files plus its own `README.md`): `build.sh`
  (one-click rebuild), `soloud_sdl3.cpp` (the SDL3 backend), `patch_soloud.py` (four idempotent
  patches to SoLoud), `gen_jni.py` / `gen_all_jni.py` / `jni/*.cpp` (83 bindings across four
  classes), `fix_needed.py` (rewrites `DT_NEEDED` from `libSDL3.so.0` to `libSDL3.so`),
  `repack.py` / `verify_so.py` / `check_undef.py` / `verify_from_jar.py`, and
  `ArcJniTest.java` + `build_test.sh` (24 on-host tests against a real JVM).
  It was moved in on 2026-10-07 from `MindustryArkDocs/mindustry-ohos/audio-build/`, and about
  35 username-bearing absolute paths were replaced with environment variables and derived
  defaults on the way (see that directory's README).
- **One input is still missing, and it is public**: the upstream SoLoud sources. `build.sh`
  reads them from `%TEMP%/soloud-src`, which measured **empty (0 files)** on 2026-10-07. Get tag
  **`2026.09.04`** of `Anuken/soloud` (matching `versions.soloud` in Arc's `build.gradle`) and
  point `ARK_SOLOUD_SRC` at it. The `%TEMP%/soloudbuild` work tree is empty too, but `build.sh`
  recreates it.
- **Everything else is still present**: SDL's own include directory (98 files on this machine;
  `build.sh` points at it), `MindustryArkDocs/sdl3-ohos/libSDL3.so` (1.8 MB, used at link time to
  resolve `SDL_*`), and the OHOS NDK. `ARK_ARC_SRC` (an Arc checkout) is a required input for
  `gen_all_jni.py` and deliberately has **no default**.
- **The 490152-byte build output did not come along**: it is an artifact, not part of the recipe,
  and it is a **different build** from the jar's copy (498800 / `db9d78b1...`) -- so it is not a
  reference for what ships either.
- Conclusion: `mindustry-1.0-audio.jar` is still **an input you must provide** (you need not
  compile it, but you must have it). The recipe is now obtainable from the repository; the only
  remaining obstacle to a full from-repo rebuild is the publicly downloadable SoLoud sources.

## 5. When something is missing

`python scripts/config.py` prints every path and whether it exists; `config.py`'s `require()`
exits immediately and points back here. Two other known gaps are documented in
`docs/BUILDING.md`: the full JDK tree at `entry/libs/arm64-v8a/jdk21/`, and how the payload
itself is packaged (`scripts/make_payload_zip.py`).
