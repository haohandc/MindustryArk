import { abilityAccessCtrl, AbilityConstant, common, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { window } from '@kit.ArkUI';
import { i18n } from '@kit.LocalizationKit';
import { inputMethod } from '@kit.IMEKit';
import { fileIo as fs, Environment } from '@kit.CoreFileKit';
import { modFolderPath } from '../mods/ModImporter';
/* [A] 只为了拿「玩家挑了哪个游戏 jar」—— 桥接要把它写进 user_dirs.txt 给 native 读。
 * 方向是单向的：GameLibrary 不反过来 import 本文件，所以没有环。 */
import { readSelection } from '../games/GameLibrary';
import { stashIfAny } from '../diagnostics/ExportDiagnostics';
import pointer from "@ohos.multimodalInput.pointer"
import sdl from 'libSDL3.so';

const DOMAIN = 0x0000;

/** [A]
 * 把命令行上传进来的 JVM 选项写进一个 native 侧会读的文件。
 *
 * 为什么需要它
 *   过去试一个 JVM flag 的代价是：重新构建、重新签名、重装 171 MB、再启动一次 ——
 *   每猜一次就是好几分钟。主机上没有任何东西能直接写进应用的沙箱：hdc 能【读】
 *   /data/app/el2/.../files 但不能写它，应用读不到 /data/local/tmp，
 *   而 Download 目录对两边都是禁区。所以唯一的入口是应用自己，通过启动参数：
 *
 *     hdc shell aa start -a EntryAbility -b com.haohandc.mindustryark \
 *         --ps jvmopt1 -Xint --ps jvmopt2 -XX:TieredStopAtLevel=1
 *
 *   键必须以 "jvmopt" 开头，这样普通的启动参数才会被忽略。
 */
function writeJvmOptions(want: Want, filesDir: string): void {
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
        // [A] 'aa start' 会拒绝以 '-' 开头的 --ps 值，所以这个短横是在这里加上的，
        // 而不是由命令行提供。调用方传进来的选项不带它：  --ps jvmopt1 Xint   ->   -Xint
        lines.push('-' + value);
      }
    }
    if (lines.length === 0) {
      return;
    }
    const path = filesDir + '/jvm.options';
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

/** [C]
 * 把平台认为的「用户可见目录」记录下来，供 native 侧探测。
 *
 * 为什么
 *   游戏内置的文件浏览器（mindustry/ui/FileChooser，「import
 *   save」和「import mod」用的就是它；它以 Arc 的外部存储路径为根，
 *   这也正是为什么要收集这些目录）。注意：那个
 *   浏览器在这里无法工作，原因是 Arc 的 libarc-filedialogsarm64.so 是一个
 *   glibc 桌面库 —— 【不是】本平台的选择器，后者工作正常。
 *   见 mods/ModImporter.ets，它用了它。
 *   save") 以 Arc 的外部存储路径为根，SdlFiles 把它算作
 *   user.home + separator —— 而本 launcher 把 user.home 指向它自己的
 *   沙箱。所以浏览器会在应用内部打开，玩家在那儿
 *   什么都放不进去。要修好这一点，我们需要一个【既】用户可写、
 *   又被应用可读的目录，而关于这个目录在哪里的权威是这套 API，
 *   而不是对路径布局的猜测。
 *
 *   只有 ArkTS 这一侧能去问；只有 native 这一侧能用游戏所用的同一个 libc
 *   去测可读性。所以 ArkTS 把它们写下来，native 再读回去。猜错一次的代价是
 *   一次构建加一次 171 MB 的安装，所以这里刻意做成双侧，而不是靠假设。
 *
 * ⚠️ 每次启动调用【两次】，而这是对一个真实缺陷的修复。
 *   一次在这里的 onCreate，一次在 ensureModFolder 建好
 *   文件夹之后由页面再调。原因是顺序：这段在页面之前跑，所以在安装后的第一次
 *   启动时文件夹还不存在，`mods=` 那一行
 *   写不出来 —— 这会把游戏的文件浏览器送去一个本应用读不了的目录。
 *   在文件夹已知之后再写一次，只要写发生在 launcher 读之前就能修复那次启动
 *   （launcher 在 SDL_main 启动时读它，也就是 XComponent 挂载的时候 —— 比
 *   aboutToAppear 晚），而如果没赶上也无害。
 *   正是为了这第二次调用才导出；见 Index.ets。
 */
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
  /* [A]
   * 应用在 Downloads 里自己的文件夹，前提是玩家已经创建了它。
   *
   * launcher 把游戏的文件浏览器指向它，好让「导入模组」在玩家的 mod 文件
   * 真正所在的地方打开。没有它，浏览器就退回沙箱 —— 那是个能用的浏览器，
   * 但看不见玩家放进 Downloads 的任何东西。
   *
   * 写成解析后的【路径】，不是 URI：native 侧没有办法解析 file:// URI，
   * 而这个桥接只是一个纯文本文件。授权本身由进程持有，
   * 所以对我们自己的代码来说路径就够了。
   */
  try {
    const where: string = modFolderPath(filesDir + '/mod_folder');
    if (where !== '') {
      lines.push('mods=' + where);
    }
  } catch (e) {
    lines.push('mods=<threw>');
  }

  /* [A]
   * 玩家在启动器里挑的那个游戏 jar，作为【绝对路径】。
   *
   * 和上面 mods= 一样的理由：native 侧没办法去问 ArkTS，所以要么 ArkTS 写下来、
   * native 读回去，要么两边各自猜。而 native 读的就是这一行
   * （launcher.c 的 read_user_dir("gamejar", ...)）。
   *
   * ⚠️ 没选过时【整行不写】，不是写一个空值。空值会让 native 必须去分辨「空」和
   * 「没有」两种情形，而它现在的行为已经对了：没有这一行就落回包里自带的那一份。
   * 给它一个可以什么都不写的机会，比要求它理解一个空字符串便宜。
   *
   * ⚠️ 这一行必须在【挂载 XComponent 之前】写进去。native 在 SDL_main 一启动时就读
   * 这个文件，而那是挂载的后果 —— 所以启动器点了「启动游戏」之后，先调本函数、再
   * 换屏。顺序反了的话，这一次启动加载的会是上一次的选择。
   */
  try {
    const chosen: string = readSelection(filesDir);
    if (chosen !== '') {
      lines.push('gamejar=' + chosen);
    }
  } catch (e) {
    /* [B] native 把 <threw> 当作「这一行不存在」（read_user_dir 里显式判断了它），
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
  /** [A]
   * 盯着 native 侧结束，然后体面地把 ability 关掉。
   *
   * 为什么必须由 ability 来结束它
   *   launcher 过去在游戏的 main() 返回后就杀掉自己的进程。从框架的角度看，
   *   那是一个 native 进程在它的 ability 还在运行时就死掉了，系统会把它记成
   *   「Cpp Crash」—— 没有信号、没有崩溃转储，正因如此我们才知道它是对一次
   *   看起来不正常的退出所做的归类，而不是一个真实的故障。
   *
   *   正常结束意味着先销毁【ability】，框架随后再把进程带下去。native 代码没法做到这点：
   *   ability 对象是一个 ArkTS 对象。所以 native 侧丢下一个标记文件，由这边轮询它 ——
   *   轮询而不是回调，因为两侧已经共享了文件系统、且只共享这个，也因为回调会需要在
   *   非 JS 线程上做一次 native->ArkTS 调用。
   *
   * 两条路径，都检查
   *   native 写在 /data/storage/el2/base/files 下；context.filesDir 是模块作用域的
   *   /data/storage/el2/base/haps/entry/files。这是两个不同的目录，与其去猜哪一个
   *   两侧都够得着，不如把标记同时写到两处，这里两处都查。launcher 出于同样的理由，
   *   已经在从两个位置读 jvm.options 了。
   *
   *   上一次运行遗留的标记会在启动四分之一秒后把应用关掉，所以 native 侧在启动时
   *   把两个都 unlink 掉。不要移除那个 unlink。
   */
  private startExitWatch(ctx: common.UIAbilityContext): void {
    const markers: string[] = [
      ctx.filesDir + '/native_exit',
      '/data/storage/el2/base/files/native_exit'
    ];
    let ticks = 0;

    // [A] 在开始监视【之前】，先清掉上一次会话遗留的任何东西。
    //
    // native 侧也会把这些 unlink 掉，但它动手比我们到这里更晚
    // （它的 main() 在 onCreate 之后才跑），而在它动手之前，一个陈旧的标记
    // 和一个新鲜的标记是分不出来的 —— 这意味着一个在退出中途被强停的应用
    // 会在下一次启动时把自己关掉。所以监视者先清掉自己的触发器。
    for (const path of markers) {
      try {
        fs.unlinkSync(path);
      } catch (e) {
        // [B] 没有东西可删时 unlinkSync 会抛异常，而这是常态。
        // 无论哪种情况都无需做什么。
      }
    }

    const timer = setInterval(() => {
      ticks++;
      for (const path of markers) {
        try {
          // [A] 【返回值才是答案】。文件不在时 accessSync 【不】抛异常 —— 它返回 false。
          // 这段代码更早的一个修订版调用了它，并把「没有异常」当成「标记存在」，
          // 结果让应用在第一个 tick 上、也就是启动四分之一秒之内，每次都把自己关掉。
          // hilog 那行说 "native exit marker seen"，而 ls 显示根本没有这个文件，
          // 这才最终把这件事定了下来。
          if (!fs.accessSync(path)) {
            continue;  // [B] 还没到 —— 在游戏关闭之前，这都是常态
          }
          hilog.info(DOMAIN, 'SDL/STARTUP',
                     'native exit marker seen (%{public}s) -- terminating ability', path);
          clearInterval(timer);
          ctx.terminateSelf().catch((err: BusinessError) => {
            hilog.error(DOMAIN, 'SDL/STARTUP',
                        'terminateSelf failed: %{public}s (code=%{public}d)', err.message, err.code);
          });
          return;
        } catch (e) {
          // [B] 一个真实的错误（路径不对、没权限）—— 当成「还没到」处理，
          // 继续轮询；native 侧仍会在它自己的超时后退出。
        }
      }
      // [B] 只是安全阀。2400 个 tick、每个 250 ms，就是十分钟 —— 比任何一次会话都长得多，
      // 所以实际上它从不会触发；它存在的意义是让这里的一个 bug
      // 不至于留下一个永远跑着的定时器。
      if (ticks > 2400) {
        clearInterval(timer);
      }
    }, 250);
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'SDL/STARTUP', '%{public}s', 'Handing control from ArkTS to native SDL.');
    /* [A]
     * 放【第一】，位置本身就是重点。
     *
     * launcher.c 每次进入 main() 都会 unlink crash.txt，所以上一次启动的崩溃报告
     * 只能存活到 native 代码开始运行之前。向 native 的交接是本方法【末尾】的
     * provideArkTSObjects()，而 main() 正是由它启动的 —— 所以那次调用之上的所有东西
     * 都是在报告还在磁盘上时运行的，而它之下没有任何东西有这个保证。
     *
     * 搞错的代价是无声的：报告就这么没了，而它存在所针对的那唯一一种情形，
     * 正是我们没有其他证据的那种。见 diagnostics/ExportDiagnostics.ets。
     */
    stashIfAny(this.context.filesDir);
    writeJvmOptions(want, this.context.filesDir);
    writeUserDirs(this.context.filesDir);
    /* [A]
     * 文件夹的【创建】发生在页面上，不在这里，而这里只是读。
     *
     * 有一个修订版把它放在这里跑，理由是：在 launcher 被告知这个文件夹之前，
     * 它就应该存在。它不属于这里：把创建放进 onCreate，DOWNLOAD 模式在【两台】设备上
     * 都以 13900042 失败 —— 而在手机上，同一个调用从菜单点按时本来是【成功】的。
     * 这两次运行之间的差别在于是否存在一个 UI 窗口，这让 13900042 看起来像是
     * 「还没有可用的窗口」，哪怕 DOWNLOAD 模式并不显示任何对话框。
     *
     * 所以分工是：在这里读（便宜、不碰选择器），在页面上创建（窗口在那儿）。
     * 上面的 writeUserDirs() 就是那个读。
     *
     * ⚠️ 这里【以前】有一个 scanModFolder() 调用，已经移除。它每次启动都会把该文件夹的
     * 内容复制进游戏的 mods 目录，从而复活玩家在游戏里删掉的 mod。现在没有任何东西
     * 再读那个文件夹的内容 —— 它存在的意义就是充当游戏自己的文件浏览器打开的目录。
     * 见 Index.ets 里那个调用原来所在处的说明。
     *
     * 代价没变，而且本来就一直如此：在全新安装上还没有任何东西创建过这个文件夹，
     * 所以 writeUserDirs() 没东西可放进桥接，游戏浏览器在那一次启动时会在沙箱里打开。
     */
    this.startExitWatch(this.context);
    try {
        // [A] 这把 SDL 的 C 代码所需的、用来应付 ArkTS 接口的东西交给它。我们在尽量不写脚本代码，
        //  能的话就用 C 通过 NAPI 调用来别扭地处理，这样「脚本和 native 代码不同步」
        //  这块风险面就 _极小_。这个函数调用会往 `this` 上加方法，比如 onWindowStageCreate()，
        //  于是我们可以从 C 驱动一切，几乎没有 ArkTS 代码。
        // 也就是说：如果这个函数调用失败，你的应用实际上根本起不来。
        //
        // 【只允许往这个函数调用里加参数】。如果 C 代码拿不到它期望的确切数量，它会 abort。
        sdl.provideArkTSObjects(this, abilityAccessCtrl.createAtManager(), i18n.System, pointer.setPointerVisibleSync, inputMethod.getController());
    } catch (e) {
        hilog.info(DOMAIN, 'SDL/STARTUP', '%{public}s', 'Exception thrown! App will not start.');
    }
  }

  /* [A]
   * 这里【曾经】有一个返回 true 的 `onBackPress(): boolean`，
   * 意图是阻止返回键关掉应用。
   *
   * 它是死代码，而且是最糟糕的那种死法：`onBackPress` 并不是 UIAbility 的方法 ——
   * 框架找的名字是 `onBackPressed` —— 所以它从未被调用过。它能编译、能运行、
   * 什么也不做，而这和「那个修复没起作用」是无法区分的，除非你去查。
   * 当时的测量：hilog 里零命中，也就是一次都没被调用过。
   *
   * 它是被移除而不是被改名，因为真正的修复在别处，而且这个钩子本来也不是一个着力点：
   * `onBackPressed` 返回 true 的意思是「转到后台而不是销毁」，不是「取消返回」。
   *
   * ESC 在 pages/Index.ets 里处理，那里的按键派发链是：
   *   onKeyPreIme（拒绝） -> XComponent（native，SDL 拿走这个键）
   *                       -> 祖先节点（消费掉，这样系统就不会）
   * 关于那个顺序背后的测量，见那里的注释。
   */
}

