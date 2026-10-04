import { abilityAccessCtrl, AbilityConstant, common, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { window } from '@kit.ArkUI';
import { i18n } from '@kit.LocalizationKit';
import { inputMethod } from '@kit.IMEKit';
import { fileIo as fs, Environment } from '@kit.CoreFileKit';
import { modFolderPath } from '../mods/ModImporter';
/* 只为了拿「玩家挑了哪个游戏 jar」—— 桥接要把它写进 user_dirs.txt 给 native 读。
 * 方向单向：GameLibrary 不反过来 import 本文件，所以没有环。 */
import { GameResolution, readSelection, resolveGame, bundledGamePath } from '../games/GameLibrary';
/* 版本隔离：算出这次该用哪个数据目录，写进 isolation.txt 给 native 读。⚠️ 方向同样单向。 */
import { computeKey, readGranularity, writeIsolationBridge } from '../settings/Isolation';
/* 应用级沙箱路径的**唯一真相源**。⛔ 别在这里再写一遍 `/data/storage/el2/base/files` 字面量 ——
 * 本项目的 `NATIVE_FILES` 就因为「四个文件各写一遍」而分叉过（见 StorageRoot 文件头）。
 * ⚠️ 无环：StorageRoot 只 import ModImporter，而 ModImporter 不 import 本文件。 */
import { SANDBOX_ROOT } from '../settings/StorageRoot';
import { stashIfAny } from '../diagnostics/ExportDiagnostics';
import pointer from "@ohos.multimodalInput.pointer"
import sdl from 'libSDL3.so';

const DOMAIN = 0x0000;

/** 把命令行上传进来的 JVM 选项写进一个 native 侧会读的文件。
 * 为什么需要它：试一个 JVM flag 的代价本是重新构建、重新签名、重装 171 MB、再启动 —— 每猜一次好几分钟；
 * 而主机上没有任何东西能直接写进应用沙箱（hdc 能【读】/data/app/el2/.../files 但不能写）⇒ 唯一入口是
 * 应用自己：`aa start ... --ps jvmopt1 -Xint`，键必须以 "jvmopt" 开头（普通启动参数才会被忽略）。 */
function writeJvmOptions(want: Want): void {
  try {
    const params = want.parameters;
    if (!params) {
      return;
    }
    const lines: string[] = [];
    for (const key of Object.keys(params)) {
      if (key.indexOf('jvmopt') !== 0) {
        continue;
      }
      const value = params[key];
      if (typeof value === 'string' && value.length > 0) {
        // 'aa start' 会拒绝以 '-' 开头的 --ps 值，所以这个短横是在这里加上的，
        // 而不是由命令行提供。调用方传进来的选项不带它：  --ps jvmopt1 Xint   ->   -Xint
        lines.push('-' + value);
      }
    }
    if (lines.length === 0) {
      return;
    }
    /* ⛔⛔ **写【应用级】那一份，不是 `ctx.filesDir`（ability 级）那一份。** 2026-10-05 改的。
     *    这两条路原来抢同一个文件，而两者对「下次启动还在不在」的期望**相反**：
     *      · `Index.setupCompatMode()` 每次启动**双向重写** ability 级那份 —— 写 `-Xint`，
     *        或者**把整个文件删掉**。那是**有意**的（`-Xint` 不能跨设备升级留成永久的）；
     *      · 人工注入的 flag（就是这里写的）应当**持有到有人显式清掉**为止。
     *    ⇒ 合在一个文件里时，启动器**下一次启动就把注入的 flag 删了**。而
     *      `RELEASE-MAINTENANCE.md` §2.10 正是拿这条路测那个悬着的 SIGSEGV
     *      （原文：「put `NOHANDLERS` in `jvm.options`」）—— 那条命令当时**不可能生效**，
     *      而且失败得与「没注入」一模一样。
     * ⭐ 分开之后两个写入者各有各的文件，`launcher.c` 的 `load_extra_options()` 读**全部**候选。
     * ⚠️ 这个路径必须与 `launcher.c` 的 `DEST_ROOT "/jvm.options"` 逐字一致 ⇒ 用 `SANDBOX_ROOT`，
     *    ⛔ 不在这里再写一遍字面量。 */
    const path = SANDBOX_ROOT + '/jvm.options';
    const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE);
    fs.writeSync(file.fd, lines.join('\n') + '\n');
    fs.closeSync(file);
    hilog.info(DOMAIN, 'SDL/STARTUP', 'wrote %{public}d jvm option(s) to %{public}s',
               lines.length, path);
  } catch (e) {
    hilog.error(DOMAIN, 'SDL/STARTUP', 'writing jvm options failed: %{public}s',
                JSON.stringify(e));
  }
}

/** 把平台认为的「用户可见目录」记录下来，供 native 侧探测。为什么：游戏内置的文件浏览器（mindustry/ui/FileChooser）
 * 以 Arc 的外部存储路径为根，而本 launcher 把 user.home 指向自己的沙箱 ⇒ 浏览器在应用内部打开，看不到玩家放进去
 * 的东西；需要一个【既】用户可写、又被应用可读的目录，权威是这套 API 不是对路径布局的猜测。
 * ⚠️ 每次启动调用【两次】（onCreate 一次、ensureModFolder 建好后由页面再一次），否则首次启动时文件夹还不存在、`mods=` 写不出来。 */
export function writeUserDirs(filesDir: string): void {
  const lines: string[] = [];
  try {
    lines.push('download=' + Environment.getUserDownloadDir());
  } catch (e) {
    lines.push('download=<threw>');
  }
  try {
    lines.push('document=' + Environment.getUserDocumentDir());
  } catch (e) {
    lines.push('document=<threw>');
  }
  try {
    lines.push('filesdir=' + filesDir);
  } catch (e) {
    lines.push('filesdir=<threw>');
  }
  /* 应用在 Downloads 里自己的文件夹（前提是玩家已创建）。launcher 把游戏的文件浏览器指向它，好让
   * 「导入模组」在玩家的 mod 文件真正所在的地方打开；写成解析后的【路径】不是 URI —— native 侧没有
   * 办法解析 file:// URI，而授权本身由进程持有，对我们自己的代码来说路径就够了。 */
  try {
    const where: string = modFolderPath(filesDir + '/mod_folder');
    if (where !== '') {
      lines.push('mods=' + where);
    }
  } catch (e) {
    lines.push('mods=<threw>');
  }

  /* 玩家在启动器里挑的那个游戏 jar，作为【绝对路径】（launcher.c 的 read_user_dir("gamejar", ...)）。
   * ⚠️ 没选过时【整行不写】不是写空值：空值会让 native 必须分辨「空」和「没有」，而它现在的行为已经对了。
   * ⚠️ 必须在【挂载 XComponent 之前】写：native 在 SDL_main 一启动时就读它，顺序反了会加载上一次的选择。 */
  try {
    const chosen: string = readSelection(filesDir);
    if (chosen !== '') {
      lines.push('gamejar=' + chosen);
    }
  } catch (e) {
    /* native 把 <threw> 当作「这一行不存在」（read_user_dir 里显式判断了它），
     * 所以这里写下去是安全的，而它同时让「读选择失败了」在日志里可见。 */
    lines.push('gamejar=<threw>');
  }

  for (const line of lines) {
    hilog.info(DOMAIN, 'SDL/STARTUP', 'user dir: %{public}s', line);
  }

  try {
    const path = filesDir + '/user_dirs.txt';
    const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE);
    fs.writeSync(file.fd, lines.join('\n') + '\n');
    fs.closeSync(file);
  } catch (e) {
    hilog.error(DOMAIN, 'SDL/STARTUP', 'writing user_dirs.txt failed: %{public}s', JSON.stringify(e));
  }
}

export default class EntryAbility extends UIAbility {
  /* 退出监视的定时器 id；-1 = 没有在跑。
   * ⚠️ 提到成员上来（原来是一个局部 `const`）是为了能在 `onDestroy` 里停掉它 ——
   *   看下面 `onDestroy` 那段：**没有它就有一个最长十分钟的窗口，定时器在 ability 已经没了之后
   *   还在跑**，而且闭包里还攥着那个 `ctx`。 */
  private exitWatchTimer: number = -1;

  /** 盯着 native 侧结束，然后体面地把 ability 关掉：launcher 过去在 main() 返回后杀掉自己的进程，从框架看就是
   * 「native 进程在 ability 运行时死了」⇒ 系统记成「Cpp Crash」（无信号、无转储）。正常结束要先销毁【ability】
   * 再让框架带下进程，而 ability 是 ArkTS 对象、native 做不到 ⇒ native 丢标记文件，这边轮询（而非回调）。
   * ⚠️ 标记要同时写到 native 与 ctx.filesDir 两处都查；上次遗留的会在启动 1/4 秒后关掉应用，native 启动时 unlink。 */
  private startExitWatch(ctx: common.UIAbilityContext): void {
    const markers: string[] = [
      ctx.filesDir + '/native_exit',
      '/data/storage/el2/base/files/native_exit'
    ];
    let ticks = 0;

    // 在开始监视【之前】，先清掉上一次会话遗留的任何东西。native 侧也会 unlink，但它动手比我们到这里
    // 更晚（main() 在 onCreate 之后才跑），而在它动手之前，陈旧标记和新鲜标记分不出来 —— 这意味着一个
    // 在退出中途被强停的应用会在下次启动时把自己关掉。所以监视者先清掉自己的触发器。
    for (const path of markers) {
      try {
        fs.unlinkSync(path);
      } catch (e) {
        // 没有东西可删时 unlinkSync 会抛异常，而这是常态。无论哪种情况都无需做什么。
      }
    }

    const timer = setInterval(() => {
      ticks++;
      for (const path of markers) {
        try {
          // 【返回值才是答案】。文件不在时 accessSync 【不】抛异常 —— 它返回 false。更早一版把「没有
          // 异常」当成「标记存在」，结果让应用在第一个 tick（启动 1/4 秒内）每次都把自己关掉；hilog
          // 那行说 "native exit marker seen" 而 ls 显示根本没有这个文件，这才最终定了案。
          if (!fs.accessSync(path)) {
            continue;  // 还没到 —— 在游戏关闭之前，这都是常态
          }
          hilog.info(DOMAIN, 'SDL/STARTUP',
                     'native exit marker seen (%{public}s) -- terminating ability', path);
          clearInterval(timer);
          this.exitWatchTimer = -1;
          ctx.terminateSelf().catch((err: BusinessError) => {
            hilog.error(DOMAIN, 'SDL/STARTUP',
                        'terminateSelf failed: %{public}s (code=%{public}d)', err.message, err.code);
          });
          return;
        } catch (e) {
          // 一个真实的错误（路径不对、没权限）—— 当成「还没到」处理，继续轮询；
          // native 侧仍会在它自己的超时后退出。
        }
      }
      // 只是安全阀。2400 个 tick、每个 250 ms 就是十分钟 —— 比任何一次会话都长得多，所以实际上
      // 从不会触发；它存在的意义是让这里的一个 bug 不至于留下一个永远跑着的定时器。
      if (ticks > 2400) {
        clearInterval(timer);
        this.exitWatchTimer = -1;
      }
    }, 250);
    this.exitWatchTimer = timer;
  }

  /* ⛔ **必须停掉那个定时器**（2026-10-05 补的）。
   *
   * 背景：`startExitWatch` 的定时器在那个文件里**没有对应的清理点** —— ability 被销毁时
   * （玩家把应用从最近任务里划掉、系统回收、或者一次不经过标记的退出）它会**继续跑**，
   * 而它闭包里攥着 `ctx`（那个已经无效的 ability 上下文），还每 250 ms 做两次 `accessSync`。
   * 上界是那个 2400 tick 的安全阀 —— 也就是**最多十分钟的无效轮询**。
   * ⭐ 这不是崩溃，是「一次性的事被拖着做」：与「诊断工具不该拖慢被测对象」同一条。
   * ⚠️ 正常退出那条路（`terminateSelf`）里已经 `clearInterval` 过了，这里再清一次是幂等的
   *   （`clearInterval` 对已清的 id 无害），所以两条路都不必特判。
   * ⛔ 这个类原本**没有 `onDestroy`** —— 补上它不是为了做别的事，只为停这一个定时器。 */
  onDestroy(): void {
    if (this.exitWatchTimer !== -1) {
      clearInterval(this.exitWatchTimer);
      this.exitWatchTimer = -1;
      hilog.info(DOMAIN, 'SDL/STARTUP', 'exit watch stopped with the ability');
    }
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'SDL/STARTUP', '%{public}s', 'Handing control from ArkTS to native SDL.');
    /* 放【第一】，位置本身就是重点：launcher.c 每次进 main() 都 unlink crash.txt，所以上次启动的崩溃报告
     * 只能存活到 native 开始运行之前。向 native 的交接是本方法【末尾】的 provideArkTSObjects()，main() 正是
     * 由它启动 ⇒ 那次调用之上的东西都在报告还在磁盘上时运行；搞错的代价是无声的（见 ExportDiagnostics.ets）。 */
    stashIfAny(this.context.filesDir);
    writeJvmOptions(want);
    writeUserDirs(this.context.filesDir);
    /* ⭐ 版本隔离的拨杆 —— 必须在 provideArkTSObjects()（本方法末尾）【之前】写完，因为那一下会启动
     * native 的 main()，而 -Duser.home= 就是在那儿算的。⚠️ 每次启动都写（包括「不隔离」那一次）：
     * 留着一个上次的 enabled=1 会让「关掉」看起来没生效。它自己吞掉所有异常，⛔ 绝不拦住启动。 */
    try {
      const g: string = readGranularity(this.context.filesDir);
      const res: GameResolution = resolveGame(this.context.filesDir, this.context.bundleCodeDir);
      const key: string = computeKey(g, res.source, res.path,
                                    bundledGamePath(this.context.bundleCodeDir));
      writeIsolationBridge(this.context.filesDir, g, key);
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, 'SDL/STARTUP', 'isolation: could not decide (%{public}s)', err.message);
    }
    /* 文件夹的【创建】发生在页面上，不在这里，这里只是读：把创建放进 onCreate，DOWNLOAD 模式在【两台】设备上
     * 都以 13900042 失败（手机上从菜单点按本来是成功的，差别在于是否存在 UI 窗口）。⚠️ 这里【以前】有
     * scanModFolder() 调用（已移除）—— 它每次启动都复制该文件夹内容进 mods 目录、复活玩家删掉的 mod。 */
    this.startExitWatch(this.context);
    try {
        // 把 SDL 的 C 代码所需的、用来应付 ArkTS 接口的东西交给它：尽量用 C 通过 NAPI 来处理，这样
        // 「脚本和 native 代码不同步」的风险面就极小。它会往 `this` 上加方法（如 onWindowStageCreate），
        // 于是可以从 C 驱动一切 —— 这个函数调用失败，应用实际上根本起不来。
        // 【只允许往这个调用里加参数】：如果 C 代码拿不到它期望的确切数量，它会 abort。
        sdl.provideArkTSObjects(this, abilityAccessCtrl.createAtManager(), i18n.System, pointer.setPointerVisibleSync, inputMethod.getController());
    } catch (e) {
        hilog.info(DOMAIN, 'SDL/STARTUP', '%{public}s', 'Exception thrown! App will not start.');
    }
  }

  /* 这里【曾经】有一个返回 true 的 `onBackPress(): boolean`（意图阻止返回键关掉应用），它是死代码：`onBackPress`
   * 不是 UIAbility 的方法（框架找的是 `onBackPressed`），所以从未被调用过 —— 能编译能运行什么也不做（hilog 里零
   * 命中）。⛔ 它被移除而非改名：`onBackPressed` 返回 true 的意思是「转到后台而不是销毁」；ESC 在 pages/Index.ets 处理。 */
}

