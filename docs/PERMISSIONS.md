# 权限 · MindustryArk

[← 返回 README](../README.md) · [← Back to README](../README.en.md)

---
# 中文

本应用**只申请一条**权限，不需要运行时弹窗（安装即授予）：

| 权限 | 为什么 |
|---|---|
| `ohos.permission.INTERNET` | **多人联机**：加入服务器，以及在本机开服。游戏本身的联网功能（社区服务器列表、联机对战）要用它 |

✅ **`ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY` 已于 2026-09-22 移除。**
它当初的用途只有一个：让游戏的文件浏览器打开在「下载」目录。⚠️ **实测它在本项目的
两台设备上从来没有成功过一次** —— 手机上是 API 本身不存在
（`Environment.getUserDownloadDir()` 抛错），平板上是权限被拒 + `mkdir` 返回 `EPERM`。
⚠️ **模组从头到尾不需要它**：三个模组入口都不碰这个权限（悬浮球走系统选择器，
Download 文件夹走 `DocumentPickerMode.DOWNLOAD`，两者都是**零权限**）。

⇒ ⭐ **本应用现在【零文件权限】。** 这同时也**取消了那条权限的 ACL 申请流程**
（它以前要走受限权限路径，见 [BUILDING.md](BUILDING.md)），
⇒ **上架审核的阻力变小了**。

⚠️ `INTERNET` 是**普通权限**，不走 ACL，也不影响别人用普通签名安装。

## 关于 `ALLOW_WRITABLE_CODE_MEMORY`

这是「让沙箱里的匿名内存可执行」的 **ACL 受限权限**。它**不在** `module.json5` 里，
只在**商店构建**时由 `scripts/make_store_app.sh` 临时注入。

⚠️ **一份早期版本的本文件写着「实测并不需要它」——那句话是错的，已撤回。**
那是在**一台机器、一个配置**（HarmonyOS 7 平板 + 调试签名）下测出来的，
注释里却把条件丢了。反例见 [RELEASE-MAINTENANCE.md](../RELEASE-MAINTENANCE.md) §2.11：
HarmonyOS 6.1.1（API 24）设备上 `mmap(RWX)` 直接返回 `errno=22`，
JIT 起不来，**应用装了却卡在启动**。所以现在走 ACL 申请流程。

---
# English

This app requests **exactly one** permission, which needs no runtime prompt (it is
granted at install):

| Permission | Why |
|---|---|
| `ohos.permission.INTERNET` | **Multiplayer**: joining a server, and hosting one on this device. The game's own online features (the community server list, networked matches) need it |

✅ **`ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY` was removed on 2026-09-22.**
Its one purpose was to start the game's file browser in Download. ⚠️ **Measured: it
never once succeeded on either device this project owns** -- on the phone the API
does not exist (`Environment.getUserDownloadDir()` throws), and on the tablet the
permission is denied and `mkdir` returns `EPERM`. ⚠️ **Getting files into the mods
directory never needed it**: the folder in Downloads is created through
`DocumentPickerMode.DOWNLOAD`, which is **zero-permission**.

⇒ ⭐ **The app now has ZERO file permissions.** That also **cancels the ACL route
that permission required** (see [BUILDING.md](BUILDING.md)), so **store review has
one less obstacle**.

⚠️ `INTERNET` is a **normal** permission: no ACL, and it does not stop anyone
from installing this build with an ordinary signature.

## About `ALLOW_WRITABLE_CODE_MEMORY`

That is the restricted ACL permission for making anonymous memory in the sandbox
executable. It is **not** in `module.json5`; it is injected only for the store
build, by `scripts/make_store_app.sh`.

⚠️ **An earlier version of this file said it had been "measured unnecessary".
That claim is withdrawn.** It came from one machine in one configuration (a
HarmonyOS 7 tablet with a debug signature) and the condition was lost on the way
into the sentence. The counter-example is in
[RELEASE-MAINTENANCE.md](../RELEASE-MAINTENANCE.md) §2.11: on a HarmonyOS 6.1.1
(API 24) device `mmap(RWX)` returns `errno=22` outright, the JIT cannot start,
and the app installs but hangs on launch. An ACL application is in progress.
