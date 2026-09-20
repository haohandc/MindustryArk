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

已在 HarmonyOS 7 平板（MatePad Pro，API 26）上跑通：主菜单正常渲染、采用移动端布局、
音频经 OHAudio 播放、触屏与物理键盘均可用、存档可从「下载」目录导入。

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

**载荷不在本仓库里**（原因见 `.gitignore`）。因为 HAP 会把载荷整个打进去，
所以构建前必须先把它准备好。

### 一、把载荷放到 `entry/libs/arm64-v8a/`

| 仓库内路径 | 是什么 | 从哪来 |
|---|---|---|
| `jdk21/` | 面向 OpenHarmony 的 OpenJDK 21（musl / aarch64）。**桌面版 JDK 用不了** | 载荷发布包，或自行获取同类构建 |
| `game/mindustry.so` | Mindustry 的 jar，改了文件名 | 官方 Mindustry 发行版 jar |
| `lwjgl/`、`lwjgl-java/` | 本平台的 LWJGL 3 原生库与 jar | 面向 OpenHarmony 的 LWJGL 构建 |
| `arc/` | Arc 的原生库 | 从 Arc 源码构建 |
| `libjvm.so`、`libcxxabi_shim.so` | 由 JDK 派生 | 由 `prep_vendor.py` 生成 |
| `launcher/` | 只有一个类的 helper jar | 由 `prep_helper.py` 从 `helper-src/` 编译 |

`prep_*.py` 系列脚本负责这些派生工作，**每个脚本都会先校验输入的哈希**再动手写文件。
所以输入陈旧或不对时会**直接报错退出**，而不会悄悄产出与测试过的版本不一致的产物。

### 二、构建

```bash
bash build.sh assembleHap        # 仅编译
bash deploy.sh                   # 构建 + 校验 + 安装 + 启动 + 收日志
```

`deploy.sh` 会在三种情况下**拒绝继续**：native 产物比源码旧、构建失败、打包校验不通过。
因为这三种情况各自都曾导致「构建显示成功，实际装上去的是上一次的产物」。

签名需要配置一次：DevEco Studio → File → Project Structure → Signing Configs →
Automatically generate signature。`deploy.sh` 安装的是 hvigor 产出的**已签名** HAP。
**没有 ACL 重签名这一步**，因为本应用不需要任何受限权限（见下文）。

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
- **只在一台设备上测过**（MatePad Pro，HarmonyOS 7）。其他设备**未测试**。

以上各条背后的原因写在**对应代码的注释里**，而不在这份文档里 —— 入口是 `entry/src/main/cpp/myapp.c`。

## 仓库结构

| 路径 | 内容 |
|---|---|
| `entry/src/main/cpp/myapp.c` | 启动器：沙箱准备、JVM 选项、启动游戏、退出握手 |
| `entry/src/main/cpp/SDL/` | SDL3，含 OpenHarmony 输入/窗口/音频的改造 |
| `entry/src/main/ets/` | ArkTS：XComponent 页面与按键处理、ability |
| `entry/libs/` | 载荷（**不在 git 里**，见 `.gitignore`） |
| `prep_*.py` | 从输入生成载荷 |
| `tools/` | 重建打过补丁的游戏 jar（把 Arc 补丁应用到上游 jar） |
| `deploy.sh`、`build.sh` | 构建与部署，带闸门 |
| `esc_ab.sh`、`quit_timing.sh` | 用于定位输入与退出问题的测量脚本 |
| `verify_hap.py`、`scan_needed.py` | 回读打包后的 HAP，核对里面的字节 |

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
LWJGL 载荷与 `tools/` 引用的 Arc 源码同理。逐组件义务见 [THIRD-PARTY.md](THIRD-PARTY.md)。

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
