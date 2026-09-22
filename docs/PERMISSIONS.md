# 权限 · MindustryArk

[← 返回 README](../README.zh-CN.md) · [← Back to README](../README.md)

---
# 中文

本应用只申请**两条**普通权限，都不需要运行时弹窗（安装即授予）：

| 权限 | 为什么 |
|---|---|
| `ohos.permission.INTERNET` | **多人联机**：加入服务器，以及在本机开服。游戏本身的联网功能（社区服务器列表、联机对战）要用它 |
| `ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY` | 从「下载」目录**导入存档与游戏数据包**，以及把模组放进 `Download/MindustryMods/`。⚠️ **部分机型不提供此权限**（手机 Mate 80 Pro 上申请返回 `2`「无效请求」，不弹窗也不授权），此时该功能不存在；模组仍可用悬浮球的系统文件选择器导入 |

⚠️ 上架应用市场时，**第二条要走 ACL 受限权限流程**（权限级别虽是 `normal`，
但官方要求保持受限申请方式）；本地安装不受影响。见 [BUILDING.md](BUILDING.md)。

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

This app requests **two** normal permissions, neither of which needs a runtime
prompt (both are granted at install):

| Permission | Why |
|---|---|
| `ohos.permission.INTERNET` | **Multiplayer**: joining a server, and hosting one on this device. The game's own online features (the community server list, networked matches) need it |
| `ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY` | Importing saves and game-data exports from Download, and picking up mods from `Download/MindustryMods/`. ⚠️ **Some devices do not offer it** -- on the Mate 80 Pro phone the request returns `2` (invalid request), no dialog appears and it is never granted, so that feature does not exist there. Mods still import through the ball menu's system file picker |

⚠️ For an AppGallery submission, **the second one goes through the ACL route**
(its level is `normal`, but Huawei requires the restricted application path for
compatibility); local installs are unaffected. See [BUILDING.md](BUILDING.md).

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
