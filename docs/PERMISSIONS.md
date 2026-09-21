# 权限 · MindustryArk

[← 返回 README](../README.zh-CN.md) · [← Back to README](../README.md)

---
# 中文

只申请 `ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY`，用于从「下载」目录导入存档与游戏数据包。

**刻意不申请**：`ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY`。
那是「让可写沙箱可执行」的 **ACL 受限权限**。实测证明**并不需要**它 ——
JDK 在 HAP 里，沙箱只存数据 —— 而**正是因为没有它，别人才能用普通签名安装本构建**。

---
# English

Only `ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY`, so the player can import
saves and game-data exports from Download.

Deliberately **not** requested: `ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY`.
That is the restricted ACL permission for making the writable sandbox
executable. It was measured unnecessary -- the JDK lives in the HAP, and the
sandbox holds only data -- and leaving it out is what lets anyone install this
build without a special signing profile.
