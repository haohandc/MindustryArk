<div align="center">
  <p>
    <img src="./assets/icon-ark-launcher-216.png" width="112" height="112" alt="Ark Launcher 图标">
  </p>
  <h1>Ark Launcher</h1>
  <p>在 HarmonyOS 上运行 Mindustry</p>
  <p>v2 开发中 · v1 已上架应用市场</p>
</div>

## v2

v2 重新设计了应用架构，启动器界面整体重绘。

> [!NOTE]
> 代码主体由 DeepSeek-flash v4.1 1017 编写。

## 功能

| 功能 | 状态 |
|---|---|
| 版本隔离（四档粒度） | 完成 |
| 分组管理 | 完成 |
| 回收站（保留期 3 / 7 / 30 天） | 完成 |
| 游玩时长统计 | 完成 |
| 背景图自定义（纯色 / 图片） | 完成 |
| 卡片外观（标准 / 半透明 / 毛玻璃） | 完成 |
| 弹窗画法 | 完成 |
| 左滑动作样式 | 完成 |
| 服务器收藏与搜索 | 未完成 |
| 资源页下载 | 未完成 |
| 云存档 | 未完成 |
| 成就系统 | 未完成 |
| P2P 联机 | 未完成 |

## 仓库导览

本项目按用途拆分为多个仓库，本仓库作为项目入口保留。

| 仓库 | 内容 | 状态 |
|---|---|---|
| [**MindustryArkCore**](https://github.com/haohandc/MindustryArkCore) | 开源核心与运行时引导层。实例隔离、存储布局、启动计划数据契约，以及在 HarmonyOS 上加载 JVM 的 native 引导链 | 活跃开发 |
| **Ark Launcher Pro** | 应用本体 | 闭源 |
| [**MindustryArk_v1**](https://github.com/haohandc/MindustryArk_v1) | v1 完整源代码与提交历史，含 Mindustry Ark 与 Ark Launcher 两条开发线 | 已归档 |

## v1

v1 有过两个形态：Mindustry Ark 内置游戏本体，Ark Launcher 则去掉了游戏本体，需自备 `Mindustry.jar`。后者安装后将 jar 放入 `Download/<应用名>/games` 目录即可，文件名不限。

v1 已停止功能更新。源代码与全部 11 个版本的提交历史保存在 [MindustryArk_v1](https://github.com/haohandc/MindustryArk_v1)。

## 下载

v1 安装包可在本仓库的 [Releases](https://github.com/haohandc/MindustryArk/releases) 页面获取，共 11 个版本，最新为 v1.3.3.2。

Ark Launcher v1 已上架鸿蒙应用市场，支持平板，并兼容分发至 PC / 2in1。

## 设备要求

HarmonyOS 6.1.1 / API 24 及以上。

平板与 PC / 2in1 可运行游戏。手机版仅提供管理功能：应用市场分发的包不含游戏运行时，原因是 JIT 所需的可执行匿名内存权限仅支持平板与 PC / 2in1。自签名安装不受此限制。

## 开源核心

当前版本的核心实现已独立开源，见 [MindustryArkCore](https://github.com/haohandc/MindustryArkCore)。

该仓库包含两部分：ArkTS 数据层（实例隔离、存储布局、启动计划数据契约、游戏设置读写）与 native 引导层（加载锚库、调用 `JNI_CreateJavaVM`、在沙箱中铺设 `java.home` 目录树）。采用 GPL-2.0-only。

## 声明

非官方项目。与 Mindustry 项目及其作者 Anuken 无隶属关系，未获其认可或支持，与华为终端有限公司亦无关联。Mindustry 及相关名称与商标归各自权利人所有。
