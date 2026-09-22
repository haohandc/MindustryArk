# 隐私政策 · Mindustry Ark

[← 返回 README](README.zh-CN.md) · [← Back to README](README.md)

---
# 中文

**生效日期：2026-09-22**

本政策适用于 **Mindustry Ark**（包名 `com.haohandc.mindustryark`，以下简称「本应用」）。

## 一、我们收集哪些个人信息

**不收集任何个人信息。**

本应用没有账号系统、没有登录，不接入任何统计分析或广告服务，**不会**收集、上传或与任何第三方共享你的设备标识、位置、联系人、使用行为或其他任何个人信息。

## 二、数据存在哪里

本应用会在**你自己的设备上**保存以下内容，它们**只存在于本应用的私有存储空间**（应用沙箱）内：

- 游戏存档、蓝图、设置
- 音频等缓存文件

**卸载本应用即全部删除。** 这些数据不会离开你的设备。

## 三、权限用途

本应用申请以下权限：

| 权限 | 用途 |
|---|---|
| `ohos.permission.INTERNET` | 用于**多人联机**：加入服务器，以及在本机开服 |
| `ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY` | 用于**导入和导出游戏存档**，以及把游戏数据文件保存到你指定的「下载」目录。⚠️ **仅部分设备支持**（见下） |

**只在你主动使用导入 / 导出功能时**才会读写该目录；本应用不会在后台扫描或传输该目录中的内容。

## 四、⚠️ 关于游戏内置的联网功能

本应用内置的 Mindustry 包含多人联机、模组浏览与服务器列表等功能的**代码**，这些代码**会尝试**访问上游维护的公开服务器，包括但不限于：

- `api.github.com`（版本信息与封禁列表查询）
- `cdn.jsdelivr.net`（服务器列表、模组索引）

⚠️ **本应用【已申请】网络权限（`ohos.permission.INTERNET`），因此上述请求会真的发出。**
这一点与早期版本不同 —— 早期版本没有网络权限，那些请求全部失败在本地。

**会发送什么**：只包含上述请求本身所需的常规内容（要访问的地址、Mindustry 协议握手、
你输入的服务器地址）。**本应用没有任何账号系统、不内嵌任何统计或广告 SDK，也不会上传
你的设备标识、位置、通讯录或使用记录。**

**要提醒的一点**：多人联机与服务器列表由**上游 Mindustry / 第三方服务器**提供，
它们各自的隐私做法**不受本应用控制**。连接到哪台服务器、由谁运营，由你选择；
连上去之后的数据如何处理，适用的是**对方的**政策。

⚠️ 如果你不希望有任何网络流量，可以在系统设置里关闭本应用的网络权限，或直接不加入联机 ——
**单机游戏完全不需要网络**，关掉权限不影响存档、模组和游戏本体。

## 五、第三方组件

本应用是**非官方**的第三方移植版，与 Mindustry 项目及其作者 Anuken **无隶属关系，未获其认可或支持**。

内置的第三方组件及其许可：Mindustry 与 Arc（Anuken，GPL-3.0 / Apache-2.0）、SDL3（Zlib）、LWJGL（BSD-3-Clause）、OpenJDK 21（GPL-2.0 with Classpath Exception）。详见 [`THIRD-PARTY.md`](THIRD-PARTY.md)。

## 六、儿童

本应用不对儿童做任何特殊设计，也**不面向儿童收集任何信息** —— 因为它对任何用户都不收集信息。

## 七、平台层的数据

系统平台（HarmonyOS）会自行收集崩溃诊断等信息以改进系统。**这属于平台行为，不在本应用的控制范围内**，由华为自身的隐私政策约束。

## 八、本政策的变更

若本政策有变更，我们会更新本文件并修改顶部的生效日期。

## 九、联系方式

如有疑问，请通过项目仓库的 Issues 反馈：
<https://github.com/haohandc/MindustryArk/issues>

---
# English

**Effective date: 2026-09-22**

This policy applies to **Mindustry Ark** (bundle name `com.haohandc.mindustryark`, "the app").

## 1. What we collect

**Nothing.**

The app has no accounts and no sign-in, and it embeds no analytics or advertising services. It does **not** collect, upload or share your device identifiers, location, contacts, usage or any other personal information with anyone.

## 2. What is stored, and where

The app saves a few things **on your own device, inside its private storage** (the app sandbox):

- game saves, schematics and settings
- caches such as audio files

**Uninstalling the app deletes all of it.** None of it leaves your device.

## 3. Permissions

| Permission | Why |
|---|---|
| `ohos.permission.INTERNET` | for **multiplayer**: joining a server, and hosting one on this device |
| `ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY` | to **import and export game saves**, and to write game data files to the Download folder you choose. ⚠️ **Only some devices support this** (see below) |

That folder is touched **only while you use the import / export feature**; the app never scans or transmits its contents in the background.

## 4. ⚠️ The game's built-in network features

The Mindustry build inside the app contains the **code** for multiplayer, a mod browser and a server list, and that code **attempts to reach** public servers run upstream, including:

- `api.github.com` (version and ban-list lookups)
- `cdn.jsdelivr.net` (server list, mod index)

⚠️ **This app DOES request the network permission (`ohos.permission.INTERNET`), so those
requests do go out.** That is a change from earlier versions, which had no network permission
and therefore failed every one of them locally.

**What is sent**: only what those requests carry -- the address being fetched, the Mindustry
protocol handshake, and the server address you typed. **The app has no accounts, no analytics
and no advertising SDK, and it does not upload your device identifiers, location, contacts or
usage.**

**One thing worth saying plainly**: multiplayer and the server list are provided by **upstream
Mindustry and by third-party servers**, whose own privacy practices **this app does not
control**. Which server you connect to, and who runs it, is your choice; once connected, what
happens to that data is governed by **their** policy, not this one.

⚠️ If you would rather have no network traffic at all, revoke this app's network permission in
the system settings, or simply do not join a multiplayer game -- **single-player needs no
network**, and turning the permission off does not affect saves, mods or the game itself.

## 5. Third-party components

This is an **unofficial** third-party port. It is not affiliated with, endorsed by or supported by the Mindustry project or Anuken.

Bundled components and their licences: Mindustry and Arc (Anuken, GPL-3.0 / Apache-2.0), SDL3 (Zlib), LWJGL (BSD-3-Clause), OpenJDK 21 (GPL-2.0 with Classpath Exception). See [`THIRD-PARTY.md`](THIRD-PARTY.md).

## 6. Children

The app is not designed for children, and it collects **nothing** from anyone — children included.

## 7. Platform-level data

HarmonyOS itself collects crash diagnostics and similar information to improve the system. **That is the platform's behaviour and outside this app's control**; it is governed by Huawei's own privacy policy.

## 8. Changes to this policy

If this policy changes, we will update this file and the effective date above.

## 9. Contact

Questions: open an issue at
<https://github.com/haohandc/MindustryArk/issues>
