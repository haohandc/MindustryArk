# 发布说明文案

> 这是**给你复制粘贴用的稿子**，不是仓库内容。定稿后可以删掉这个文件，
> 或把内容移进 GitHub Release 页面。
> 下面每一节都标了「贴到哪」。

---

## ① 贴到 GitHub 仓库的 Description（一句话，有字数限制）

仓库列表页那条描述，**只放一句**，约 60–120 字符最合适：

```
在 HarmonyOS / OpenHarmony 上运行 Mindustry 的自建启动器：内嵌 JDK、native 起 JVM、SDL3 出画面，已真机跑通。
```

英文版（如果想让国际用户也能看懂，可以中英并列）：

```
Run Mindustry on HarmonyOS / OpenHarmony via a self-built launcher — embedded JDK, native JVM startup, real SDL3 window.
```

**建议填的 Topics（标签）**：

```
harmonyos  openharmony  mindustry  arkts  deveco-studio  sdl3  jni  jvm  hotspot  java  game-port  hap
```

（标签用小写、连字符，
它们决定别人能不能搜到你。）

---

## ② 贴到 Release 的标题与说明

### 标题

```
v1.0.0 — Mindustry 在鸿蒙上跑通
```

### 说明正文

````markdown
# Mindustry 鸿蒙移植 · v1.0.0

在 HarmonyOS / OpenHarmony 上用**自建启动器**运行 Mindustry。
不依赖任何现成的模拟层：内嵌 JDK、从 native 代码创建 JVM、把真正的 SDL3 窗口交给游戏。

> ⚠️ **非官方项目**，与 Mindustry 及 Anuken 无隶属关系。
> 本项目以 **GPL-3.0** 分发（因为构建产物再分发了 GPL-3.0 的 Mindustry）。

## 已验证可用的功能

在一台 HarmonyOS 7 平板（MatePad Pro，API 26）上真机验证：

| 项目 | 状态 |
|---|---|
| 主菜单 / 渲染 | ✅ 正常，使用移动端布局 |
| 音频 | ✅ OHAudio |
| 触屏 | ✅ 点击、长按、**双指捏合缩放** |
| 键盘 | ✅ 物理键盘 WASD；ESC 打开菜单（**不会被系统当成"返回"**） |
| 鼠标 | ✅ 全部按键 + 滚轮 |
| 存档 / 数据导入导出 | ✅ 从「下载」目录 |
| 退出 | ✅ 正常关闭，不被系统标记为崩溃 |

## 下载哪个文件

| 文件 | 说明 |
|---|---|
| `MindustryArk-v1.0.0-signed.hap` | **已签名，推荐。** 用 DevEco 生成的调试签名，可直接 `hdc install` |
| `MindustryArk-v1.0.0-unsigned.hap` | 未签名。需要你用自己的证书重新签名后安装 |
| `payload-v1.0.0.tar.zst`（约 255 MB） | **载荷包。** 想在本地自己构建就需要它，见 README |

### 安装方式

未签名的 HAP **不能直接安装**，必须先用你自己的证书签名。最简单的方式：
在 DevEco Studio 里打开本项目 → File → Project Structure → Signing Configs →
Automatically generate signature → 然后运行 `bash deploy.sh`。

已签名的那份可以直接装：

```bash
hdc install -r MindustryArk-v1.0.0-signed.hap
```

## 已知限制

- **桌面 / 移动模式无法运行期切换**（启动时固定）。游戏内自带「鼠标 + 键盘操控」开关可覆盖大部分需求。
- 游戏内的文件浏览器走的是 Mindustry **自带**的兜底实现（Arc 的文件对话框库是 glibc 链接，鸿蒙加载不了）。
- **导入游戏数据后游戏会主动退出** —— 这是 Mindustry 的设计（用新数据重启），**看起来像崩溃但不是**。
- **已在两台设备上验证**（MatePad Pro 平板、SGT-AL50 手机，都是 HarmonyOS 7 / API 26）。其他鸿蒙设备未验证，欢迎反馈。

## 从源码构建

```bash
# 1) 把载荷放进 entry/libs/arm64-v8a/  （README 里有清单）
# 2) 配置签名：DevEco → Project Structure → Signing Configs
bash deploy.sh          # 构建 + 校验 + 安装 + 启动 + 收日志
```

`deploy.sh` 带三道闸门：native 产物比源码旧、构建失败、打包校验不通过 —— 任一情况立即中止。
因为这三种情况各自都曾导致「构建显示成功，装上去的却是上一次的产物」。

## 致谢

Mindustry 与 Arc 由 **Anuken** 开发；窗口/输入/音频层是 **SDL3**；
JNI 绑定是 **LWJGL**；运行时是 **OpenJDK 21**。各组件许可证见 `THIRD-PARTY.md`。

本仓库大部分代码由 AI 辅助完成（Claude via Cherry Studio，deepseek-flash v4.1）。
````

---

## ③ 首次 push 前可选的收尾

- [ ] 仓库 Description 填好（① 那句）
- [ ] Topics 填好
- [ ] README 里**没有**留下本地路径或个人信息（已检查，密钥已隔离）
- [ ] 确认 Release 附件里**不要**带 `entry/build/` 整个目录，只挑那三个文件
- [ ] 项目主页可以考虑加一句「**未在真机上广泛测试，欢迎提 issue**」，降低预期
