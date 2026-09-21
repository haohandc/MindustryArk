# 仓库结构 · MindustryArk

[← 返回 README](../README.zh-CN.md) · [← Back to README](../README.md)

---
# 中文

| 路径 | 内容 |
|---|---|
| `entry/src/main/cpp/launcher.c` | 启动器：沙箱准备、JVM 选项、启动游戏、退出握手 |
| `entry/src/main/cpp/SDL/` | SDL3，含 OpenHarmony 输入/窗口/音频的改造 |
| `entry/src/main/ets/` | ArkTS：XComponent 页面与按键处理、ability |
| `payload-src/` | 构建的**输入**（不在 git 里）—— 见其 `README.md` |
| `entry/libs/` | **组装好的载荷**（**不在 git 里**，见 `.gitignore`） |
| `scripts/config.py` | 工具链用到的所有路径，集中一处 |
| `scripts/` | 从输入组装载荷、重建打过补丁的 jar、打包校验 |
| `deploy.sh`、`build.sh` | 构建与部署，带闸门 |
| `docs/` | 这一组说明文档 |
| `RELEASE.md` | 该发布什么、什么**绝不能**发布 |
| `RELEASE-MAINTENANCE.md` | 版本对照表、事故记录、发布前检查清单 |
| `THIRD-PARTY.md` | 逐组件的许可证与再分发义务 |

---
# English

| Path | What |
|---|---|
| `entry/src/main/cpp/launcher.c` | The launcher: sandbox setup, JVM options, game launch, exit handshake |
| `entry/src/main/cpp/SDL/` | SDL3, with patches for OpenHarmony input, windowing and audio |
| `entry/src/main/ets/` | ArkTS: the XComponent page and key handling, and the ability |
| `payload-src/` | The build's **inputs** (not in git) — see its `README.md` |
| `entry/libs/` | The **assembled payload** (not in git -- see `.gitignore`) |
| `scripts/config.py` | Every path the toolchain uses, in one place |
| `scripts/` | Payload assembly from those inputs, rebuilding the patched jar, and the packaging checks |
| `deploy.sh`, `build.sh` | Build and deploy, with gates |
| `docs/` | This set of documents |
| `RELEASE.md` | What to publish and what must not be published |
| `RELEASE-MAINTENANCE.md` | Version ledger, incident records, the pre-release checklist |
| `THIRD-PARTY.md` | Per-component licences and redistribution obligations |
