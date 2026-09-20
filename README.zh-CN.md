# MindustryArk

[English](README.md) | **简体中文**

在 **HarmonyOS / OpenHarmony** 上运行 **Mindustry**，使用自建启动器，而不是套一层现成的模拟层。

启动器内嵌一套 JDK，从 native 代码创建 JVM，再把一个真正的 SDL3 窗口交给游戏。
本仓库就是这套启动器。**Mindustry 自身的代码未经修改**；被改动的是它下层的框架 ——
Arc 的四个后端类被重新编译后写回 jar，因为平台相关的改造都在那里。

> **非官方项目。** 与 Mindustry 项目及 Anuken 无隶属关系，未获其认可或支持。
> 详见 [THIRD-PARTY.md](THIRD-PARTY.md)。

---

## 当前状态

已在 HarmonyOS 7 / API 26 的设备上跑通（MatePad Pro 平板、SGT-AL50 手机）：
主菜单正常渲染、采用移动端布局、音频经 OHAudio 播放、
触屏与物理键盘均可用、存档可从「下载」目录导入。

| 项目 | 状态 |
|---|---|
| JVM 启动 | 可用 —— 但启动器**必须**传 `-XX:UseSVE=0`，否则 JIT 会生成本设备无法执行的 SVE 指令，进程直接 SIGILL |
| 图形 | OpenGL ES，经 SDL3 |
| 音频 | OHAudio，经自编的 `libarcarm64.so`（含 SDL3 后端） |
| 触屏 | 可用，**含双指捏合缩放** |
| 键盘 | 可用（物理键盘；WASD 与 ESC） |
| 鼠标 / 手柄 | 鼠标可用；手柄**未测试** |
| 存档导入导出 | 可用，从「下载」目录往返 |
| 桌面 / 移动模式切换 | **未实现** |

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
**没有 ACL 重签名这一步**，因为本应用不需要任何受限权限（见下文）。

⚠️ **这个签名只属于你自己的机器。** DevEco 自动生成的是**调试 profile**，
它指定了允许安装的**设备 UDID 列表**，而产出的 HAP 里**内嵌了这份列表** ——
还有你的开发者 ID 与证书上的姓名。用它构建、用它安装都可以，**但不要把它发布出去**。
该发布什么见 **[RELEASE.md](RELEASE.md)**。

---

## 权限

只申请 `ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY`，用于从「下载」目录导入存档与游戏数据包。

**刻意不申请**：`ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY`。
那是「让可写沙箱可执行」的 **ACL 受限权限**。实测证明**并不需要**它 ——
JDK 在 HAP 里，沙箱只存数据 —— 而**正是因为没有它，别人才能用普通签名安装本构建**。

## 已知限制

- **桌面/移动模式无法在运行期切换**：模式在启动时固定。Mindustry 游戏内自带
  「鼠标 + 键盘操控」开关，能覆盖大部分同类需求。
- `libarc-filedialogsarm64.so` 链接的是 **glibc**，本平台加载不了，
  因此 Arc 回退到 Mindustry **自带的游戏内文件浏览器**。这也是浏览器根目录必须重定向到「下载」的原因。
- **导入游戏数据后游戏会主动退出**（`Core.app.exit()`），以便用新数据重启。
  **这看起来像崩溃，但不是。**
- **目前验证了两台设备**：MatePad Pro 平板与 SGT-AL50 手机，均为 HarmonyOS 7 / API 26。
  其他设备**未测试** —— 本项目依赖平台对「可执行内存」的策略，
  若某设备在这点上做法不同，出错方式我们无法预判。

以上各条背后的原因写在**对应代码的注释里**，而不在这份文档里 —— 入口是 `entry/src/main/cpp/myapp.c`。

## 仓库结构

| 路径 | 内容 |
|---|---|
| `entry/src/main/cpp/myapp.c` | 启动器：沙箱准备、JVM 选项、启动游戏、退出握手 |
| `entry/src/main/cpp/SDL/` | SDL3，含 OpenHarmony 输入/窗口/音频的改造 |
| `entry/src/main/ets/` | ArkTS：XComponent 页面与按键处理、ability |
| `payload-src/` | 构建的**输入**（不在 git 里）—— 见其 `README.md` |
| `entry/libs/` | **组装好的载荷**（**不在 git 里**，见 `.gitignore`） |
| `scripts/config.py` | 工具链用到的所有路径，集中一处 |
| `scripts/` | 从输入组装载荷、重建打过补丁的 jar、打包校验 |
| `deploy.sh`、`build.sh` | 构建与部署，带闸门 |
| `RELEASE.md` | 该发布什么、什么**绝不能**发布 |

## 许可证

**GPL-3.0** —— 见 [LICENSE](LICENSE)。

Copyright (C) 2026 Haohandc and contributors.

本项目**没有选择宽松许可证的自由**，因为构建产物再分发了 Mindustry，而它是 GPL-3.0。
HAP 是**单一可安装单元**，其唯一目的就是运行该游戏 ⇒ 属于**结合作品**，
而非彼此独立程序的「聚合」⇒ GPL-3.0 覆盖整体。

**贡献前值得知道的实际后果**：衍生作品也必须以 GPL-3.0 分发，
所以**不能**基于本项目做闭源产品。

技术栈中其余组件都与 GPL-3.0 兼容，这正是这个组合能够合法分发的前提 ——
**包括 JDK**：它的 **Classpath Exception** 正是「允许把该库与独立模块链接、
并按你自己的条款分发可执行文件」的那一条。

⚠️ **第三方文件保留各自许可证。** `entry/src/main/cpp/SDL/` 是 **Zlib 许可的 SDL3 加上本地修改**；
它**不会**因本项目的 GPL 而改许可，且 Zlib 要求**修改版不得冒充原版**。
LWJGL 载荷与 `scripts/` 引用的 Arc 源码同理。逐组件义务见 [THIRD-PARTY.md](THIRD-PARTY.md)。

## 致谢

- **Mindustry** —— Anuken 开发，游戏本体，**加载时未做修改**
- **Arc** —— Anuken 开发的游戏框架；`arc/backend/sdl/**` 与 `arc/graphics/gl/**` 带有本平台补丁
- **SDL3** —— 窗口 / 输入 / 音频层
- **LWJGL** —— OpenGL 与 SDL 的 JNI 绑定
- **OpenJDK 21** —— 运行时

各组件许可证与再分发条款见 [THIRD-PARTY.md](THIRD-PARTY.md)。

本仓库大部分代码由 AI 辅助完成（Claude via Cherry Studio，模型 deepseek-flash v4.1）。
所有测量、真机测试，以及「当测量结果与假设冲突时如何取舍」的判断，都全程对照**一手来源**复核过；
源码注释里记着那些有意思的失败 —— **包括我自己造成的那几个**。
