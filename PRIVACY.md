# 隐私政策 · Mindustry Ark

[← 返回 README](README.zh-CN.md) · [← Back to README](README.md)

---
# 中文

**生效日期：2026-09-21**

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

本应用只申请一个权限：

| 权限 | 用途 |
|---|---|
| `ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY` | 用于**导入和导出游戏存档**，以及把游戏数据文件保存到你指定的「下载」目录 |

**只在你主动使用导入 / 导出功能时**才会读写该目录；本应用不会在后台扫描或传输该目录中的内容。

## 四、⚠️ 关于游戏内置的联网功能

本应用内置的 Mindustry 包含多人联机、模组浏览与服务器列表等功能的**代码**，这些代码**会尝试**访问上游维护的公开服务器，包括但不限于：

- `api.github.com`（版本信息与封禁列表查询）
- `cdn.jsdelivr.net`（服务器列表、模组索引）

⚠️ **本构建未申请网络权限，因此这些请求无法离开你的设备**，也就不会向任何第三方发送任何信息。

⚠️ **若将来为本应用启用网络功能，本政策将随之更新。**

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

**Effective date: 2026-09-21**

This policy applies to **Mindustry Ark** (bundle name `com.haohandc.mindustryark`, "the app").

## 1. What we collect

**Nothing.**

The app has no accounts and no sign-in, and it embeds no analytics or advertising services. It does **not** collect, upload or share your device identifiers, location, contacts, usage or any other personal information with anyone.

## 2. What is stored, and where

The app saves a few things **on your own device, inside its private storage** (the app sandbox):

- game saves, schematics and settings
- caches such as audio files

**Uninstalling the app deletes all of it.** None of it leaves your device.

## 3. The one permission

| Permission | Why |
|---|---|
| `ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY` | to **import and export game saves**, and to write game data files to the Download folder you choose |

That folder is touched **only while you use the import / export feature**; the app never scans or transmits its contents in the background.

## 4. ⚠️ The game's built-in network features

The Mindustry build inside the app contains the **code** for multiplayer, a mod browser and a server list, and that code **attempts to reach** public servers run upstream, including:

- `api.github.com` (version and ban-list lookups)
- `cdn.jsdelivr.net` (server list, mod index)

⚠️ **This build requests no network permission, so those requests cannot leave your device** — nothing is sent to any third party.

⚠️ **If network features are ever enabled for this app, this policy will be updated.**

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
