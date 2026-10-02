import { abilityAccessCtrl, bundleManager, common, Permissions } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { KeyCode } from '@kit.InputKit';
import { window } from '@kit.ArkUI';
import { ensureModFolder, modFolderPath } from '../mods/ModImporter';
/* [A] 导出它，是为了让本页在它所指的文件夹真正存在之后，再写一次桥接文件。
 * 理由见 ensureModFolder() 调用处的说明。 */
import { writeUserDirs } from '../entryability/EntryAbility';
/* [A] 崩溃报告在 ability 的 onCreate 中被【捕获】（必须在原生代码 unlink 它之前读取），
 * 再在这里【发布】—— 这是第一个能确定 Download 文件夹已存在的时刻。
 * 见 diagnostics/ExportDiagnostics.ets。 */
import { publish as publishCrash, exportNow as exportDiagnosticsNow,
         readStartupLogTail } from '../diagnostics/ExportDiagnostics';
/* [A] 「加载哪一个游戏」的全部知识都在那里，本页只负责【问一次并照着做】。
 * 为什么判定必须发生在本页、而不是 native：见 decideStartup()。 */
import { consumeLauncherRequest, requestLauncher, resolveGame, reportGameResolution,
         markLaunchAttempt, pendingLaunchAttempt, clearLaunchAttempt,
         GameResolution } from '../games/GameLibrary';
/* [A] 启动后进哪里 —— 设置页那开关写盘，这里读。见 LauncherPrefs 里的 LAUNCH_MODE_DEFAULT。 */
import { readLaunchMode, LAUNCH_MODE_HOME } from '../settings/LauncherPrefs';
/* [A] 版本隔离：在**真正要启动的那一刻**把结论写给 native。⚠️ 不能只靠 EntryAbility.onCreate
 * 那一次 —— 默认模式是「先显示启动器」，玩家会在那之后再改选 jar。见 startGame 里的说明。 */
import { computeKey, readGranularity, writeIsolationBridge } from '../settings/Isolation';
/* [A] 没有游戏可加载时显示的那一屏。它是【替换】XComponent，不是盖在它上面 ——
 * 关于这个区别为什么决定了两边能用什么控件，见那个文件的开头。 */
import { LauncherHome } from './LauncherHome';
/* [A] `focusControl` 无需 import：它是 ArkTS 框架全局变量，和 getContext 一样。
 * 从 @kit.ArkUI 导入它编译不过。 */
import shield from 'libshield.so'; // [B] 坚盾

const DOMAIN = 0x0000;
const TAG = 'MindustryLauncher';

/* [A]
 * 兼容模式 —— 当本次安装没有被授予匿名可执行内存时，追加 -Xint。
 *
 * ⚠️⚠️ 实测于 2026-09-22：这【救不了】这样的设备。
 *
 * 保留它有两个理由，两个都不是「它能用」：替代方案是彻底什么都不做；以及下面
 * 的 FORCE_COMPAT_MODE，那是在不需要它的硬件上【测量】解释器【开销】的手段。
 *
 * 实测到了什么。一个绑定设备的 RELEASE 配置 —— 没有可执行内存 ACL，绑定手机自身
 * 的 UDID —— 在 hilog 里打出这些，然后就没了：
 *
 *     !! executable memory unavailable (probe=-1) -- FORCING -Xint
 *     wrote the verdict for the UI: interp (probe=-1)
 *     calling JNI_CreateJavaVM (strict) ...
 *       opt: ... -Xint
 *
 * 没有返回，没有报错，进程直接消失。
 *
 * ⇒ 解释器仍然需要可执行内存。HotSpot 在它去考虑「字节码怎么执行」之前，就已经
 *   在构建它的启动 stub（SharedRuntime / StubRoutines）了，所以对于【不给】这块
 *   内存的设备，「解释执行」不是退路 —— 它回答的是一个从来就不是卡点的问题。
 *
 * ⚠️ 早先那个「已验证」并不是对这件事的测试。这个退路曾被叫作已验证，理由是
 * NOEXEC 钩子强制做出了决定 —— 但那一整轮运行里内存都是可用的，所以实际通过的
 * 只是「在从不需要它的设备上，这个选项被加上了」。强制加一个选项，和在【该选项
 * 存在的那个状态】里，不是一回事。见 RELEASE-MAINTENANCE.md 2.13b。
 *
 * 决定它的是什么：是那个【能力】，由启动器每次启动时探测 —— 不是系统版本，也不是
 * 设备类别。所以下面的规则只是【首启】猜测，只用于那唯一一次还没有结论的启动；
 * 从第二次启动起，启动器自己的测量就压过它。
 *
 * ⇒ 所以应用商店里【没有手机包】。手机拿不到那个 ACL，这个退路救不了它，而一个
 *   装上却起不来的包，比商店根本不提供的包更糟。手机改用自签名构建来服务，那里
 *   由 debug 配置提供这块内存。
 *
 * 删掉了什么，以及为什么。曾有一个全屏提示把这些都告诉玩家，它一度说游戏只是会
 * 变【慢】（实测：加载 5-6 s，对照解释执行的 ~20 s）。在实际会出现它的那些设备
 * 上，那是一个应用兑现不了的承诺：提示是在 aboutToAppear 里武装的，早于
 * XComponent 挂载，于是玩家读了它、点掉了它，然后眼看着应用死掉。删掉它是用户的
 * 决定。原文措辞、标记文件和那 5 秒倒计时都保存在 RELEASE-MAINTENANCE.md 2.13b。
 */
const JVM_OPTIONS_FILE_NAME = 'jvm.options';

/* [A]
 * 启动器在哪里记录 JVM 是否真的拿到了可执行内存。
 *
 * 用绝对字面量，理由和下面的 IME 桥接相同：这是原生侧写入的【应用级】目录，而
 * context.filesDir 是【模块级】的那个。两者看起来几乎一样，但不能互换。
 *
 * 内容是一个词："interp" 或 "jit"。
 */
const EXEC_MEMORY_FILE = '/data/storage/el2/base/files/execmem';
const JVM_INCOMPLETE_FILE = '/data/storage/el2/base/files/jvm_incomplete';

/* [B] 「上次为什么没起来」那个弹窗里，日志尾巴最多给这么多字节。
 * 这是弹窗里的一小块文字，不是导出诊断 —— 那个仍然是「导出诊断」菜单的事（128 KB）。 */
const FAULT_LOG_BYTES = 1200;
/* [A]
 * 那次失败启动自己的日志。它必须【尽早】读，否则就别读：launcher.c 在 main() 一
 * 启动时就以 O_TRUNC 打开它，而 main() 是在 XComponent 挂载时启动的 —— 所以运行
 * 更早的 aboutToAppear 是「上一次启动的日志仍然存在」的唯一窗口。和 EntryAbility
 * 的 stashIfAny() 是同一个窗口、同一个理由。
 */
const STDERR_LOG_FILE = '/data/storage/el2/base/files/stderr.log';
/** [A]
 * 启动器【上一次】启动测到的结果，或者还没表态时是 ''。
 *
 * '' 的意思是「没有测量」—— 全新安装，或者某次启动文件没写成 —— 调用方会退回用
 * 自己的猜测。它【不】意味着「JIT 能用」：把文件不存在当成好消息，正是一个起不来
 * 的设备连提示都收不到的原因。
 */
function launcherExecMemoryVerdict(): string {
  try {
    if (!fs.accessSync(EXEC_MEMORY_FILE)) {
      return '';
    }
    return fs.readTextSync(EXEC_MEMORY_FILE).trim();
  } catch (e) {
    return '';
  }
}
/** [A]
 * 上一次启动日志里第一行含 `needle` 的内容，没有就返回 ''。
 *
 * 一次死在 JNI_CreateJavaVM 里的启动，没有别的记录：它不返回错误码，不写
 * faultlog，进程在任何东西来得及问它之前就没了。所以这里是把启动器自己的话
 * 逐字引回来，而不是概述。
 *
 * 注意：needle 必须足够具体。光写 'errno=' 也会匹配到那两行无害的
 * "Download NOT READABLE errno=1"，那就会报出错误的失败。
 */
function logLine(needle: string): string {
  try {
    if (!fs.accessSync(STDERR_LOG_FILE)) {
      return '';
    }
    const lines: Array<string> =
      fs.readTextSync(STDERR_LOG_FILE).split(String.fromCharCode(10));
    for (let i = 0; i < lines.length; i++) {
      if (lines[i].indexOf(needle) >= 0) {
        return lines[i].trim();
      }
    }
  } catch (e) {
    /* [C] 空答案会作为 "(not recorded)" 显示给玩家 */
  }
  return '';
}
/* [C] 低于这个 API level，本项目【过去】假设 JIT 不可用。
 *
 * 警告：这是一个猜测，不是阈值。它来自一台 API 24 的手机，而设备类别从来没有和
 * 版本区分开 —— 见本文件顶部的说明。它能留到今天，只是因为启动器的测量会在下一次
 * 启动时纠正错误的猜测，也因为猜「无 JIT」的代价只是首启变慢，而不是启动失败。 */
const MIN_API_FOR_JIT = 26;
/* [A]
 * 在【所有】设备上强制兼容模式。
 *
 * 它的存在是为了【测量】，不是为了发布。-Xint 的代价本来无法测量：手边没有
 * API 24 设备，而 release 签名的包无法侧载，所以想感受这个变慢，唯一的办法是在
 * 并不需要这个退路的硬件上跑它。
 *
 * 任何要发布的构建里它都【必须】是 false。
 */
const FORCE_COMPAT_MODE = false;

/** [A]
 * 现在应用【不再】申请任何运行时权限。下面的列表是空的，而它是空的时候
 * requestPerms() 会整个跳过那次调用。
 *
 * 移除于 2026-09-22：ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY。当初声明它，
 * 是为了让应用能用 Environment.getUserDownloadDir() 够到用户的 Download 目录。
 * 该 API 文档写明需要 SystemCapability.FileManagement.File.Environment.FolderObtain，
 * 并且「目前仅 2in1 设备」，所以在手机上无论权限状态如何它都会抛
 * "The device doesn't support this api"（实测时是手工把授权加上去的，所以授权不是
 * 那个变量）。
 *
 * ⚠️ 移除它【没有】改变的一件事：ModImporter.ets 【仍然】调用
 * getUserDownloadDir()，作为 createModFolder 的 route A —— 平板靠它报出一个路径。
 * 消失的是权限，不是那次调用：route A 本来也从来没用过（平板的 mkdir 返回 EPERM），
 * 真正干活的是 DocumentPickerMode.DOWNLOAD，它根本不需要任何权限。这段注释的早先
 * 版本曾声称「已经没有任何东西调用 getUserDownloadDir() 了」，那是彻底错的。
 *
 * 测量结果说明了什么
 *   实测，同一个 HAP、同一个签名（appId 完全相同）：
 *
 *     tablet : reqPermissionStates [0, 0]  -- 两个都授予
 *     phone  : reqPermissionStates [0, -1] -- 这一个【未】授予
 *
 *   ⚠️ 这段注释的早先版本把这解释成 authResults = 2 即 "INVALID REQUEST"，
 *   于是系统从不弹对话框、再问也没用。那个解读已【撤回】：同一次调用还返回了
 *   dialogShown = true 和 errorReason = 0（"this request is valid"），并且在发起后
 *   约 170 ms 就返回 —— 这个速度快到不可能有人来得及回答对话框。三个字段彼此矛盾，
 *   因此这里不主张任何原因。见 docs/LIMITATIONS.md。
 *
 *   这次请求仍是尽力而为：在能提供授权的硬件上，玩家会被问一次；在不支持的硬件上，
 *   什么都不会发生，也不会坏掉。
 */
const WANTED: Permissions[] = [
];

async function requestPerms(ctx: common.UIAbilityContext): Promise<void> {
  /* [B]
   * 没什么可申请的，就没什么可做的。
   *
   * 截至 2026-09-22，这个列表是【空的】—— READ_WRITE_DOWNLOAD_DIRECTORY 是最后
   * 一项，也已经没了（见 WANTED 上的说明）。这个应用做的任何事都不需要运行时权限：
   * 唯一需要过的那件事就是伸手去够用户的 Download 目录，而那条路在本项目拥有的任何
   * 设备上都没成功过。剩下的权限 INTERNET 是安装即授予，永远不会出现在这里。
   *
   * 所以这现在是正常路径，不是边角情况。requestPermissionsFromUser() 拿到空数组
   * 会怎样，本项目查过的地方都没有文档，而这也不重要：这次调用被跳过了，所以这个
   * 问题根本不会出现。
   */
  if (WANTED.length === 0) {
    hilog.info(DOMAIN, TAG, 'permissions: nothing to request');
    return;
  }
  try {
    const atm = abilityAccessCtrl.createAtManager();
    const bundleInfo = await bundleManager.getBundleInfoForSelf(
      bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
    const tokenId = bundleInfo.appInfo.accessTokenId;

    for (const p of WANTED) {
      const state = atm.checkAccessTokenSync(tokenId, p);
      hilog.info(DOMAIN, TAG, 'permission %{public}s state before = %{public}d (0=granted,-1=not granted)', p, state);
    }

    const res = await atm.requestPermissionsFromUser(ctx, WANTED);
    /* [A]
     * 把四个字段全打出来，不只打那两个显而易见的。
     *
     * 这个循环过去只打印 permissions/authResults，这就是一句「权限弹窗不再出现」
     * 的报告要花一整个会话来解释的原因。结果里还带着 dialogShownResults 和
     * errorReasons，而回答「为什么没弹对话框」的正是这两个 —— 见
     * security/PermissionRequestResult.d.ts：
     *
     *   authResults  0 = 已授予, -1 = 未授权, 2 = INVALID REQUEST
     *                （未声明 / 名字错 / 请求条件不满足）
     *   dialogShown  true = 弹了对话框；false = 系统没弹，
     *                因为权限状态、类型或策略不允许走对话框这条路径
     *   errorReasons 0 有效, 1 名字错, 2 未声明, 3 条件不满足,
     *                4 隐私声明未接受, 5 该权限不支持通过对话框申请,
     *                6 manual_settings —— 只能在设置页授予, 12 服务错误
     *
     * 在 HarmonyOS 7 手机上实测：READ_WRITE_DOWNLOAD_DIRECTORY 的 authResults
     * 返回 2，所以没有弹窗，状态停在 -1。那台手机从
     * Environment.getUserDownloadDir() 也报 "The device doesn't support this
     * api"，这是同一个事实的另一面。见 docs/LIMITATIONS.md。
     */
    for (let i = 0; i < res.permissions.length; i++) {
      const shown: string = (res.dialogShownResults !== undefined
        && i < res.dialogShownResults.length)
        ? String(res.dialogShownResults[i]) : 'n/a';
      const reason: number = (res.errorReasons !== undefined
        && i < res.errorReasons.length) ? res.errorReasons[i] : -999;
      hilog.info(DOMAIN, TAG,
        'permission request: %{public}s -> auth=%{public}d dialogShown=%{public}s errorReason=%{public}d',
        res.permissions[i], res.authResults[i], shown, reason);
      if (res.authResults[i] === 2) {
        /* [A]
         * 报出来是 2（未授予）—— 但这里【不要】叙述原因。
         *
         * 这条警告的第一个版本说「系统把这个请求判为无效，所以不会弹对话框」，
         * 是从 SDK 那句「2 通常表示无效请求」推出来的。手机上的实测元组反驳了这个
         * 解读：
         *
         *     auth=2   dialogShown=true   errorReason=0
         *
         * 而 errorReason 0 的意思是 "this request is valid"。也不可能是有人回答了
         * 对话框：整次调用在发起后约 170 ms 就返回了，这对一个人来说太快了。所以这
         * 三个字段凑不成一个故事，而猜测哪一个才算准，正是让一个错误解释留进日志、
         * 后来被人信任的路子。
         *
         * 上面那行把四个值原样记录下来。能确定的只有结果：未授予，玩家看不到弹窗。
         */
        hilog.warn(DOMAIN, TAG,
          '  %{public}s: NOT GRANTED (authResult 2). dialogShown=%{public}s, '
          + 'errorReason=%{public}d -- the three fields do not agree, so no cause '
          + 'is claimed here; see docs/LIMITATIONS.md',
          res.permissions[i], shown, reason);
      }
    }
  } catch (e) {
    const err = e as BusinessError;
    hilog.error(DOMAIN, TAG, 'permission request failed: %{public}s (code=%{public}d)', err.message, err.code);
  }
}

/** [A]
 * 不再申请任何运行时权限。
 *
 * 更早的一个版本申请了 READ_WRITE_DOWNLOAD_DIRECTORY，因为当时的计划是把 JDK 放在
 * 用户的 Download 区 —— 注释写的是「JDK 放在用户 Download 区时要读它」。那个计划
 * 被放弃了：现在 JDK 随 HAP 一起打包，并被复制进应用自己的沙箱，所以那个权限守的
 * 是一条已经没人走的路。
 *
 * 移除之前实测过：拒绝该权限对游戏怎么运行毫无影响。它的数据进沙箱 —— user.home
 * 被重定向到那里，files/.local/share/Mindustry/ 存放存档、settings.bin、模组和
 * 缓存 —— 它的素材来自游戏 jar，唯一想要一个用户可见目录的功能是 Arc 的文件选择器
 * 后端 libarc-filedialogsarm64.so，而它在这里根本加载不了：那是 tinyfiledialogs
 * —— zenity/kdialog/popen —— 而且是 glibc 链接的。这句话说的是【Arc 的】那个库，
 * 不是本平台自带的文件选择器；后者能用，也正是模组菜单用的那个（见
 * mods/ModImporter.ets）。这里早先的措辞只写了「文件选择器……加载不了」，读起来
 * 指的是后者，白白浪费了一轮排查。
 *
 * 移除它会去掉启动时的一次授权弹窗。那个原因字符串 perm_reason_DOWNLOAD 仍在
 * resources/ 里 —— 现在已无人引用，无害。
 */

/* [A]
 * 原生侧在哪里找这些文件。刻意用字面路径：ArkTS 的 context.filesDir 是 HAP 级
 * 目录，它【不是】原生代码共享的那个应用级目录，所以写在那里的文件永远不会被看到。
 */
const IME_WANT_FILE = '/data/storage/el2/base/files/ime_want';
const IME_CMD_FILE = '/data/storage/el2/base/files/ime_cmd';
/* [A]
 * 游戏的文本框到底在哪，格式为 "x y w h"，单位是游戏像素。
 *
 * 用来把我们的隐形文本框盖到它【上面】，好让框架的键盘避让把页面移动恰好足够
 * 露出它的距离。借助框架正是关键：它本来就知道怎么让一个聚焦的文本框保持在键盘
 * 上方可见，而且移动是它自己做的。
 */
const IME_RECT_FILE = '/data/storage/el2/base/files/ime_rect';

/* [A]
 * 这里【曾经】有一个 MODS_DIR 常量，已随它唯一的用户一起消失。本文件里再没有
 * 任何东西写入游戏的模组目录，所以把它写在这里就是一条没人读的路径。
 *
 * 留作备注，是因为这套算术万一以后还用得上，值得记住：启动器把 user.home 指向
 * DEST_ROOT，Arc 的 OS.getAppDataDirectoryString() 拼出
 * "<user.home>/.local/share/Mindustry/"，而 Vars.modDirectory 是
 * dataDirectory.child("mods/") —— 所以在设备上它是
 * /data/storage/el2/base/files/.local/share/Mindustry/mods。用绝对字面量而不是
 * 推导出来的值，理由和上面的 IME 文件相同：那是原生代码共享的【应用级】目录，而
 * context.filesDir 是模块级的那个。
 */

/* [A]
 * seedProbeMod() 和它的两个常量曾在这里。【已删除】，理由和删掉那行菜单、那次
 * 文件夹扫描是同一个：
 *
 *   那次复制在【每次】启动时都是【无条件】的。它是个开发探针，所以开发者手删
 *   probe-mod.jar 很正常 —— 而下一次启动又把它放回去，和文件夹扫描复活的模组
 *   一模一样。一个自己认定某个模组存在、并且在游戏内无法被纠正的应用，才是问题
 *   所在；它是探针并不让它变成另一种问题。
 *
 * ⇒ 这个没了之后，应用就再也不往模组目录里写任何东西了。唯一往那里放模组的是游戏
 *   自己，当玩家用它自带的导入按钮时。
 *
 * ⚠️ tools/probe-mod/ 仍在仓库里，仍然能构建。消失的是【自动种入】—— 所以设备上
 *   遗留的 probe-mod.jar 现在在游戏里被删掉之后会【保持】被删，这正是重点。
 */

/* [A]
 * 玩家选了哪套操作方案，由启动器在 JVM 启动前读取。
 *
 * 刻意写在 user_dirs.txt 旁边：两者都是本侧写进 filesDir、原生侧在启动时读的文件，
 * 而 filesDir 是 HAP 级目录，【不是】上面 IME 桥接所用的应用级目录。这两个目录长得
 * 像，但不能互换 —— 写错目录的文件就是永远不会被看到，而且哪儿都不会报错。
 */
const CONTROL_MODE_FILE_NAME = 'control_mode.txt';
const CONTROL_MODE_MOBILE = 'mobile';
const CONTROL_MODE_DESKTOP = 'desktop';

/* [A]
 * 悬浮球。它的存在是为了承载多个功能，其中操作方案是第一个，所以它点一下是打开
 * 菜单，而不是直接执行动作。
 *
 * 所有尺寸都是 vp。触摸坐标也是 vp 到达的（TouchObject.windowX/Y 文档写明是 vp），
 * 这也正是 .position() 接受的单位 —— 所以这里没有任何地方需要 px2vp 转换。唯一
 * 需要转换的是屏幕尺寸，平台以 px 上报它。
 */
/* [A]
 * 球的大小是从窗口【推导】出来的，不是固定的。
 *
 * 固定的 44vp 在这台平板上实测太小。合适的尺寸取决于屏幕，而屏幕自身的短边才是
 * 诚实的输入：球是个拇指目标，拇指目标随设备缩放。
 *
 * 之所以保留为【短边的比例】而不是两个维度的某个分数，是为了让横屏窗口不会产出
 * 一个比竖屏更宽的球。
 *
 * 下限设为 48 而不是旧的 44：44 就是被发现太小的那个值，所以自适应公式绝不能又
 * 回到它。上限则阻止一块很大的屏幕产出一个盖住游戏的球。
 */
const BALL_SIZE_FALLBACK_VP = 48;   /* [B] 在 onAreaChange 上报任何数据之前 */
const BALL_SIZE_RATIO = 0.065;      /* [B] 窗口短边的比例 */
const BALL_SIZE_MIN_VP = 48;
const BALL_SIZE_MAX_VP = 76;
/* [A]
 * 球停靠在它贴上的那条边时，离边留多远。
 *
 * 四条边都适用，每一条会安置球的路径也适用 —— 首次摆放、拖动、从磁盘恢复的位置
 * —— 所以这个间隙不取决于球是怎么到那儿的。它曾经只在首次摆放时被用到，结果被拖动
 * 过的球贴边相切，而没碰过的球却保留着间隙。
 */
const BALL_MARGIN_VP = 8;
/* [A] 触摸要移动多远才算拖动而不是点按。没有它，点按时手指最轻微的移动都会被读成
 * 拖动，菜单就永远打不开。 */
const BALL_DRAG_SLOP_VP = 8;
const BALL_MENU_W_VP = 176;
/* [A]
 * 一行的高度 —— 以及它为什么是个高度。
 *
 * 这些行过去是裸 Row 包一个 fontSize 14 的 Text，所以点击目标就是文本恰好量出来的
 * 大小：约 19 vp。从设备上报回来：选项太小、也挨得太近。手指没法可靠地打中 19 vp，
 * 而且两个目标大约只隔一行文字。
 *
 * 所以行现在带一个显式高度，文本由 Row 的默认对齐在其中居中。点击目标现在是整行，
 * 那才是玩家实际瞄准的东西；间距也由高度自然得出，而不是一个需要猜的 margin。
 *
 * 46 是第一次尝试，它矫枉过正：设备上又报回来，说行现在离得太远、间隙应该大约减半。
 * 32 让文本保持 16 vp，并把上下留白大致减半，而正是那部分留白被读成「间隙」——
 * 行是相邻的，所以两个标签之间的空间【就是】每行内部的 padding。它仍然远高于开头
 * 那个 19 vp，所以点击目标依然好用。
 *
 * BALL_MENU_H_VP 由这些推导而来，因为 ballMenuY 要拿它做 clamp。它曾是一个光秃秃的
 * 64 —— 对一行来说没错，但它会让两行的菜单挂出下边缘，只不过仅在球恰好靠近下边缘
 * 时才发生，而这类缺陷能躲过每一次「没把球放到那儿」的审查。
 */
const BALL_MENU_ROW_VP = 32;
const BALL_MENU_DIVIDER_VP = 1;
const BALL_MENU_PAD_VP = 16;
/* [C]
 * 菜单有多少行。要和 build() 里的 Row 数量保持一致。
 *
 * 之所以是个具名常量，是因为 BALL_MENU_H_VP 必须与之匹配，而这里上一次错误的形态
 * 就是一个「对它写定时那个行数而言正确」的高度。现在加一行是一处改动而不是两处 ——
 * 而容易忘的那一处，正是被写下来的那一处。
 *
 * ⚠️ 这个常量存在的全部意义，就是逼出「加/删一行要改两处」里的第二处：把它留在
 * 旧值，会保留一段并不绘制任何东西的高度，菜单看起来只是「矮了一截」。
 *
 * ⚠️ 这里上面【曾】有一句「它曾是 3，现在是 2」，而紧挨着的值一直是 3 —— 也就是说
 * 那句话在写下时就已经说错了，2026-10-01 订正。它被删掉而不是改写，因为**我不掌握
 * 它的历史**：只留下能核实的部分（现在的值、以及改动它的规则）。
 */
const BALL_MENU_ROWS = 4;   /* [B] 2026-10-01 加了「启动器」那一行，3 -> 4 */
const BALL_MENU_H_VP = BALL_MENU_ROWS * BALL_MENU_ROW_VP
                     + (BALL_MENU_ROWS - 1) * BALL_MENU_DIVIDER_VP
                     + BALL_MENU_PAD_VP;
/* [C] 标签和它的提示共用同一个尺寸，这样两行不会彼此漂移。 */
const BALL_MENU_FONT_VP = 16;
const BALL_MENU_HINT_FONT_VP = 14;

/* [A]
 * 自动半隐藏。
 *
 * 球在贴上某条边之后，会再向外滑出这么多，让只有剩余部分还留在屏幕上，同时降到
 * 更低的透明度 —— 它应当不再和游戏争抢注意力，但仍能被找到。
 *
 * 0.6 按要求隐藏了大约五分之三的球，留下外侧 40%。在这台平板的密度下，约 66vp 的
 * 球仍有约 26vp 在屏幕上。
 *
 * 那条窄边就是全部的目标区，所以这就是那个在「可见性」和「可找到」之间做取舍的值。
 * 它可行，是因为把球弄回来的那次点击【只需要落在】那条窄边上，而不必瞄准它 —— 也
 * 因为那第一次点击现在只是「露出」（菜单需要点第二次），打偏的代价不过就是再来一下。
 * 调大它就隐藏得更多；它就是那个旋钮。
 */
const BALL_HIDE_MS = 3000;
const BALL_HIDE_FRACTION = 0.6;
const BALL_OPACITY_HIDDEN = 0.45;

/* [A]
 * 球上次停在哪。一行，"x,y"，绝对 vp。
 *
 * 用绝对值而不是「哪条边加一个比例」，是因为位置在恢复时会被 clamp 进当前窗口，
 * 而一个停在更宽窗口右边缘的球会被 clamp 回更窄窗口的右边缘 —— 所以「窗口尺寸变了」
 * 这个常见情况会自己纠正，无需额外存任何东西。
 *
 * 它和 control_mode.txt 一起放在模块的 filesDir 里。【不是】IME 桥接所用的那个
 * 应用级目录：两者长得像，写错目录的文件永远不会被看到，而且哪儿都不报错。
 */
const BALL_POS_FILE_NAME = 'ball_pos.txt';

/* [B]
 * 用户收起键盘之后，忽略游戏请求的时长。
 *
 * 长到足够让转发出去的 ESC 抵达游戏、并让游戏关掉它的对话框 —— 到那时请求会自行
 * 停止，这个值也就无所谓了。短到不会把任何人困住。
 */
const IME_DISMISS_MS = 1500;

/* [A]
 * 给隐形文本框额外增加的高度，加在游戏自身文本框之上，且【只在】键盘弹起时。
 *
 * 它为什么存在：框架只会把页面上推到聚焦文本框可见为止，所以这是避免游戏文本框
 * 紧贴键盘上边缘的唯一杠杆。
 *
 * 它为什么是有条件的 —— 这正是花了两次才做对的部分。
 *
 * 这个 margin 是【向下】长的 —— 盒子锚在左上角，只是被加高 —— 所以它也会盖住
 * Mindustry 在文本框下方画的东西，而在导出对话框上那是 Cancel。所以要够到 Cancel
 * 就得先把焦点移开：那会让游戏丢掉文本框，从而卸载我们的盒子，只有这时点击才落到
 * Cancel 上。
 *
 * 把这块外伸改向上试过，是【错的】，值得记下为什么，因为这个错误是算术层面的，不是
 * 判断层面的。用 `y = fieldY - 24` 和 `h = fieldH + 24`，盒子的【下】边缘落在
 * `fieldY + fieldH`，而不是 `fieldY + fieldH + 24` —— 它整体上移了一个 margin。
 * 下边缘恰恰是框架避让必须让开的东西，所以页面少被推了 24vp，键盘盖住了 Cancel
 * 和 Enter。
 *
 * 所以 margin 留在底部，只在用户收起键盘时才去掉 —— 那时页面没有什么需要让开，
 * 这个更高的盒子就纯属碍事。去掉它之后，盒子就正好是游戏的文本框：点文本框仍会
 * 再次唤起键盘，点 Cancel 也能到游戏。
 */
const IME_FIELD_MARGIN_VP = 24;

@Entry
@Component
struct Index {
  @State showIme: boolean = false;
  /* [B]
   * 游戏文本框被认为装着的内容。原生侧通过 SDL_SendKeyboardText 喂这个副本，所以
   * 两者一起从空开始，且只会随下面发送的内容变化。
   */
  private imeSent: string = '';
  private imeTimer: number = -1;
  private imeFieldFocused: boolean = false;
  /* [A]
   * 用户把键盘收起来了，它必须一直收着，直到用户再次要求 —— 尽管游戏【全程】都还在
   * 要文本。
   *
   * `ime_want` 回答不了这个：它报告的是游戏想要什么，而游戏永远不会知道用户把键盘
   * 藏了，因为它自己的文本框仍然聚焦，所以 SDL 从不调用 HideScreenKeyboard。于是
   * 这个区分只能由轮询自己带着。它如何被置位见 onBlur 处理器，如何被清除见
   * pollImeWant 的 `want` 分支。
   */
  @State imeUserHid: boolean = false;
  /* [A]
   * 忽略游戏请求的截止时间，因为用户刚刚把它收起来了。没有它，游戏持续不断的请求
   * 会重新打开用户刚刚关掉的东西。
   *
   * 这是一个【截止时间】，不是锁存器，而这个区别就是全部要点。游戏的对话框只要还
   * 开着，就保持着文本框聚焦，因此一直在要 —— 它不会发出任何能清除锁存器的新请求。
   * 所以锁存器会把一个 ESC 没能关掉对话框的用户困死：没键盘，也没办法要一个。截止
   * 时间则总会把键盘放回来。
   */
  private imeDismissedUntil: number = 0;
  /* [B]
   * 游戏的文本框，以游戏像素计，好让我们的隐形文本框盖到它上面。值已经是 vp，因为
   * 那是 .position() 接受的单位，而在读取时转换一次就能让渲染路径不含算术。
   */
  @State imeFieldX: number = 0;
  @State imeFieldY: number = 0;
  @State imeFieldW: number = 1;
  @State imeFieldH: number = 1;
  /* [B] 持有它，以便页面销毁时能移除 avoid-area 监听。 */
  private imeWindow: window.Window | undefined = undefined;
  /* [B] 当前记录在磁盘上的操作方案。显示在开关上，好让玩家看出正生效的是哪一套，
   * 因为改动要到下次启动才生效。 */
  @State controlMode: string = CONTROL_MODE_MOBILE;
  /* [A]
   * 球在哪，以及它的菜单是否打开。
   *
   * ballPlaced 之所以存在，是因为在窗口尺寸已知之前球无法定位：它从右边缘开始，
   * 而在 onAreaChange 上报一个宽度之前，那会把它放到 x=0。摆放只发生一次，在第一次
   * 尺寸上报时，之后玩家选定的位置永远不会被覆盖。
   */
  @State ballX: number = 0;
  @State ballY: number = 0;
  @State ballPlaced: boolean = false;
  @State ballMenu: boolean = false;

  /* [A] About 覆盖层，以及它显示的版本号。版本号是从【包】里读的，而不是写在这里：
   * 本项目已经被一个手工抄写的版本号坑过一次（build-profile.json5 里的
   * artifactName），再来一份副本会以完全相同的方式漂移。 */
  @State showAbout: boolean = false;

  /* [A]
   * 这一屏显示【游戏】还是【启动器】。
   *
   * 设置一次，在 aboutToAppear 里，由 decideStartup() 决定；之后只有两个地方改它：
   * 启动器里点「启动游戏」（-> false），以及悬浮球菜单里点「启动器」（那一行走的是
   * 退出握手，不是直接改这里 —— 见 backToLauncher()）。
   *
   * ⚠️ 它是一道【门】，所以它必须有出口。两个出口都在，而且是刻意放的：
   *   · 启动器空状态里的「仍然尝试启动」—— 判定失误时的逃生门
   *   · 悬浮球菜单里的「启动器」—— 进了游戏之后还能回来
   */
  @State showLauncher: boolean = false;

  /* [A]
   * Download 那个文件夹【确认可用】之后翻成 true，传给启动器界面。
   *
   * ⚠️ 为什么需要它：那个文件夹是在本页 aboutToAppear 里**异步**创建的
   * （ensureModFolder 要么 mkdir、要么弹 picker，两者都得等），而启动器界面的
   * aboutToAppear 紧接着**同步**跑 —— 于是全新安装的第一次，它读到的状态文件还
   * 不存在。2026-10-01 在 MatePad Pro 上实测复现：第一次显示「还没读到文件夹」，
   * 而同一分钟 mod_folder 就落盘了；不点任何东西重启一次即恢复。
   *
   * ⇒ 父组件不阻塞地通知一句「好了」，启动器再读一遍（等于按一次「重新扫描」）。
   *
   * ⚠️ 刻意**不**把关卡设在这里（例如等文件夹好了才挂载启动器界面）：那条路上
   * picker 可能一直不返回，界面就永远不出来。本项目为「门关上了却没有开的路径」
   * 付过代价（jvm_incomplete），不再犯 —— **不阻塞比早显示重要**。
   *
   * ⚠️ 两个到达顺序都要成立：若它先翻成 true、界面后创建，界面拿到的初值就是
   * true，aboutToAppear 里那次 refresh() 读到的已经是写好的文件 —— 正确。
   */
  @State folderSettled: boolean = false;

  /* [B] 传给启动器界面的两个路径。从 context 取一次，因为那是页面才拿得到的东西。 */
  private launcherFilesDir: string = '';
  private launcherBundleDir: string = '';

  /** [A] 设置一次，在 XComponent 存在之前：见 aboutToAppear。 */
  @State shieldBlocked: boolean = false;
  /* [B] Kit 的原始答案：'on' / 'off' / 'no-lib: ...' / 'no-sym: ...' / 'mode=N'。 */
  @State shieldDiag: string = '';
  /* [B] 上一次启动的临终遗言，在它的日志还存在时捕获。 */
  @State jvmFaults: string = '';
  /** [B] 启动器留下了它那个「JVM 正在创建」的标记。 */
  @State jvmIncomplete: boolean = false;

  /* [A]
   * 交给启动器界面显示的「上次为什么没起来」，'' 表示没有失败。
   *
   * ⚠️ 在 decideStartup() 里【组装一次】，不是在 build 里现算：它要读 stderr.log 的尾巴，
   * 而 build() 会被调用很多次。一句提示不值得每次都去碰磁盘。
   */
  @State launchFault: string = '';

  /** [B] 上一次尝试启动的那个 jar 的路径；判不出来时是 ''。 */
  @State launchFaultJar: string = '';

  @State appVersion: string = '';

  /* [B] 不再有兼容性提示的状态：那个提示已经没了。为什么见文件头注释，它过去显示的
   * 文字见 RELEASE-MAINTENANCE.md 2.13b。`compatMode` 也随它一起去掉了 —— 一个
   * 没人读的字段不记录任何东西。 */
  /* [A]
   * 球的直径，从窗口重新计算。用 @State 字段而不是 getter，因为渲染要读它：一个由
   * winW/winH 推导出的普通字段会变化，而组件永远不会被通知重新渲染。
   */
  @State ballSizeVp: number = BALL_SIZE_FALLBACK_VP;
  /* [A]
   * 球当前是否滑出到了边缘之外。
   *
   * 这【只】是一个渲染期的偏移量 —— ballX/ballY 始终保存着「露出」的位置。这是那个
   * 承重的选择：拖动、clamp、吸附和持久化都继续在同一套坐标上工作，隐藏无法让它们
   * 漂移。另一种做法（移动 ballX 本身）会让上面每一个功能都得重新去弄清球「真正」
   * 在哪。
   */
  @State ballHidden: boolean = false;
  /* [B] 它上次吸附到哪条边，好让隐藏朝正确的方向滑。 */
  private ballEdge: string = 'right';
  private ballHideTimer: number = -1;
  /* [B]
   * 从磁盘读到的位置，一直留到窗口尺寸已知。
   *
   * 它不能在读取时就应用：这个值需要对着窗口做 clamp，而 onAreaChange 还没上报过
   * 一个。-1 表示「什么都没存」。
   */
  private ballRestoreX: number = -1;
  private ballRestoreY: number = -1;
  /* [B] 按下那一刻球是否是半隐藏的。见 onBallTouch。 */
  private ballWasHiddenOnDown: boolean = false;
  private winW: number = 0;
  private winH: number = 0;
  /* [B] 拖动的锚点：触摸开始时球的位置和手指的位置，这样球不会跳到手指底下居中。 */
  private dragBallX: number = 0;
  private dragBallY: number = 0;
  private dragTouchX: number = 0;
  private dragTouchY: number = 0;
  private dragMoved: boolean = false;

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    /* [A]
     * 权限请求走的是一个普通窗口，所以沉浸式切换是【串】在它后面，而不是和它并行
     * 启动。
     *
     * requestPerms() 是异步的，它的第一条语句 await
     * bundleManager.getBundleInfoForSelf()，所以下面的一切都在那次 await 期间运行。
     * enterImmersive() 会把系统栏拿走、把布局设为全屏 —— 而系统权限对话框属于一个
     * 普通窗口，不属于一个刚刚变成全屏、没有栏的窗口。
     *
     * ⚠️ 这是一种【预防措施】，不是【诊断】。它最初是当作诊断写的，理论是「沉浸式
     * 切换就是手机上 requestPermissionsFromUser() 返回未完成的原因」—— 而下一次
     * 启动就否证了它。相同的输入，相同的输出：
     *
     *     permission request: ... -> auth=2 dialogShown=true errorReason=0
     *     immersive: bars hidden, layout full-screen
     *
     * 只是两行的顺序变成了这样。所以顺序固定了、结果却没变，这意味着原因在别处。
     * 这段注释【不能】做的，就是继续主张一个已被测量杀死的说法 —— 那正是让一个错误
     * 解释被下一个读者继承的路子。
     *
     * 顺序得以保留，是因为它本身是对的：在一个正常窗口上申请权限才是 API 期望的
     * 做法，代价只是首启时系统栏会多留一个往返的时间。
     */
    requestPerms(ctx).then(() => {
      this.enterImmersive();
    }).catch((e: BusinessError) => {
      /* [B] requestPerms 有自己的 try/catch，本不该 reject；万一真 reject 了，
       * 系统栏仍然必须走掉。 */
      hilog.warn(DOMAIN, TAG,
                 'permissions: unexpected rejection (%{public}s); immersive anyway',
                 e.message);
      this.enterImmersive();
    });
    /* [A]
     * 应用在 Downloads 里的文件夹，在这里创建，而不是在 ability 里。
     *
     * 【在这里】是因为这里才有 UI 窗口。实测：同一个 DOWNLOAD 模式的调用，从菜单
     * 点击发起能成功，从 EntryAbility.onCreate 发起则报 13900042 失败，两台设备都
     * 如此 —— 所以哪怕它不弹对话框，也需要一个窗口。
     *
     * 每次启动都检查并重建，所以玩家删掉的文件夹会回来。它跑在上面 requestPerms()
     * 已被【启动】但未被 await 之后：picker 模式不需要权限，所以没什么可等的。
     *
     * ⚠️ 这个文件夹的【用途】已经变了，而函数名没跟上 —— 磁盘上仍然是
     * ensureModFolder / mod_folder。它过去是一个暂存区，其中内容会在每次启动时被
     * 扫进游戏的模组目录；现在它纯粹是游戏自带文件浏览器打开时所在的目录：
     * EntryAbility 把它的路径写进 user_dirs.txt，启动器把它作为 -Darc.sdl.chooserPath
     * 传进去，这才让「导入模组」和存档的导入/导出打开在玩家够得到的地方。
     *
     * ⇒ 已经没有任何东西读它的内容了。丢进其中的文件可以通过游戏的浏览器够到，
     *   但必须在【那里选中】；它不再会被自动取走。这就是「模组在游戏里被删掉后又被
     *   复活」的修复，也是「存档（.zip）像一个模组那样被扫进模组目录」的修复。
     */
    ensureModFolder(ctx, ctx.filesDir + '/mod_folder')
      .then(() => {
        /* [A]
         * 桥接文件在这里【再写一次】，这就是「文件浏览器打开在错误位置」的修复。
         *
         * writeUserDirs 在 ability 的 onCreate 里运行，早于这里 —— 而文件夹是在这
         * 里创建的，因为 DOWNLOAD 模式的 picker 需要一个窗口。所以在一次安装或卸载
         * 之后的首次启动上，桥接文件没有 `mods=` 这一行，而启动器过去会退回用普通的
         * Download 目录 —— 它【测出】那个目录不可读（"download NOT READABLE
         * errno=1"），于是浏览器打开在一片虚无上。
         *
         * 在文件夹已知之后再写一次，只要这次写抢在启动器读取之前，就修好了那次启动；
         * 抢不到也无害。启动器在 SDL_main 启动时读这个文件，也就是 XComponent 挂载
         * 时，那在 aboutToAppear 之后 —— 所以这次写通常来得及。并不试图保证它：抢输
         * 一次的代价是那一次启动里浏览器待在沙箱中，而下次启动无论如何都是对的。
         */
        writeUserDirs(ctx.filesDir);
        /* [A]
         * 崩溃报告导出的后半段，它恰好就该在这里。
         *
         * 崩溃本身是在 ability 的 onCreate 里捕获的，因为必须在原生代码 unlink 它
         * 之前读取。那时它无法被【写入】Downloads：在手机上那个文件夹只能通过
         * DOWNLOAD 模式 picker 的授权够到，而 picker 需要一个窗口 —— 和把文件夹的
         * 创建放到本页是同一个约束。
         *
         * 所以：尽早捕获，等文件夹确认可用后再发布。发布是幂等的（以崩溃命名，已存在
         * 就跳过），而且在没有崩溃时什么都不做 —— 那是正常情况。
         */
        publishCrash(modFolderPath(ctx.filesDir + '/mod_folder'), ctx.filesDir);
        /* [A]
         * 文件夹这件事到此为止了，通知启动器界面可以读。
         *
         * ⚠️ 放在这个 .then() 的**最末尾**，不是开头：它读的是上面 writeUserDirs
         * 刚写的桥接文件，所以必须排在它之后。
         *
         * ⚠️ 这里【不】判断 showLauncher。启动器界面可能还没被创建（那就用初值
         * true）、也可能已经在屏幕上（那就触发 @Watch 重读），两种情况都对 ——
         * 这正是修一个**竞态**时该有的形状：不依赖谁先谁后。
         */
        this.folderSettled = true;
      })
      .catch((e: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'mod folder setup failed: %{public}s', e.message);
      });
    this.clearStaleImeState();
    /* [A]
     * 用轮询而不是等通知：这个请求是另一份 libSDL3.so 里的原生代码发出的，它无法
     * 调进本页。文件是两者唯一的共用通道，而这里复用的正是退出握手已经在用的机制。
     */
    this.imeTimer = setInterval(() => { this.pollImeWant(); }, 200);
    this.watchKeyboardHeight();
    this.readControlMode();
    /* [B] 只是持有，不应用：这个值需要窗口尺寸来做 clamp，而 onAreaChange 还没上报
     * 过。 */
    this.readBallPos();



    /* [A]
     * 【无条件】记录日志，包括答案是 "off" 的时候。
     *
     * 上一个版本只在坚盾开启时才记日志，这让它自己的正确性无法验证：「闸门没有触发」
     * 也正好是「库加载失败」「符号不存在」「方法从未运行」三者都会产生的现象。一个
     * 决定必须报告它据以做出的输入，否则它没有产生效果这件事什么都证明不了。
     */
    try {
      this.shieldDiag = shield.shieldDiagnosis();
    } catch (e) {
      const err = e as BusinessError;
      this.shieldDiag = 'call-failed: ' + err.message;
    }
    this.shieldBlocked = (this.shieldDiag === 'on');
    hilog.info(DOMAIN, TAG, 'shield diagnosis: %{public}s -> blocked=%{public}s',
      this.shieldDiag, String(this.shieldBlocked));

    /* [A]
     * 标记还在这里，意味着【上一次】启动停在了 JVM 创建内部 —— 这是唯一一种不留
     * 日志、不留 faultlog、也没有返回码的失败。
     *
     * 它【不是】一道闸门，这个区分就是整个设计。玩家被告知，然后自己选择；一个残留
     * 物从不自作主张。
     */
    try {
      this.jvmIncomplete = fs.accessSync(JVM_INCOMPLETE_FILE);
      if (this.jvmIncomplete) {
        /* [A] 【先】读证据，在标记被清除之前，也在原生 main() 把证据来源的日志
         * 截断之前。 */
        const parts: Array<string> = [];
        const probe: string = logLine('mmap(RWX) FAILED');
        if (probe !== '') { parts.push(probe); }
        const forced: string = logLine('FORCING -Xint');
        if (forced !== '') { parts.push(forced); }
        const called: string = logLine('calling JNI_CreateJavaVM');
        if (called !== '') { parts.push(called); }
        if (logLine('CreateJavaVM (strict) returned') === '') {
          /* [A] 这个标记存在的全部理由：create() 进去了就没回来，所以既没有返回码，
           * 也没有 faultlog。 */
          parts.push('(no return value -- the process died inside create)');
        }
        const verdict: string = launcherExecMemoryVerdict();
        parts.push('execmem: ' + (verdict === '' ? '(not measured)' : verdict));
        parts.push('shield now: ' + this.shieldDiag);
        this.jvmFaults = parts.join(String.fromCharCode(10));
        try {
          fs.unlinkSync(JVM_INCOMPLETE_FILE);
        } catch (e) {
          /* [B] 删不掉它 —— 代价只是下次启动多一个提示，不是启动失败。绝不能让这个
           * 挡住应用。 */
        }
      }
    } catch (e) {
      this.jvmIncomplete = false;
    }

    /* [A]
     * 在 XComponent 存在之前：有游戏就直接进游戏，没有就显示启动器界面。
     * 为什么这个判定必须在这里、而不能等 native 起来再说，见 decideStartup()。
     *
     * ⚠️ 它排在 setupCompatMode() 【之前】不是随意的：那一句会写 jvm.options，
     * 而既然它有可能决定根本不挂 XComponent，就没必要先写一份用不上的文件。
     */
    this.decideStartup();

    /* [A]
     * 在 XComponent 存在之前：见 setupCompatMode 上的说明。它会写出启动器要读的
     * 选项文件，而启动器在 SDL_main 一启动时就读它，那正是 XComponent 挂载的时候。
     */
    this.setupCompatMode();
    /* [A] 这里【曾经】调用 seedProbeMod()，在游戏扫描模组目录之前种下 probe-mod.jar。
     * 已删除 —— 现在这个应用跑的任何东西都不再写入那个目录。见它原先定义处的说明。 */
  }

  /* [A]
   * 把状态栏和导航栏从屏幕上拿掉。
   *
   * 为什么这是修 bug，而不是锦上添花
   *   球的半隐藏方式是滑出窗口边缘。在左右两侧那是真实的屏幕边缘，所以有效。在上下
   *   两侧，球只是滑进了系统栏占据的那条带里 —— 那条带仍然可见，于是球还留在屏幕上，
   *   隐藏看起来毫无作用。设备上报了这个现象。
   *
   *   系统栏没了之后，y=0 就是显示器的物理顶端，向上滑就真的把球移出屏幕了。
   *
   * 为什么这些栏可以直接拿掉
   *   它们是平台的装饰，不是游戏的。Mindustry 自己画全屏 UI，本应用在那条带里没有
   *   自己的控件，而这些栏在所有时刻都占掉游戏的一条。
   *
   * 刻意【没有】做的事
   *   系统的手势返回和回到桌面【没有】被屏蔽。隐藏这些栏绝不能把玩家困在应用里：
   *   出不去远比一条可见的栏糟糕。只移除了栏本身。
   *
   * 本文件接受的唯一一条警告
   *   setWindowSystemBarEnable([]) 会编译出 "This API is unavailable to 2in1"，而
   *   本应用确实在设备类型里声明了 2in1，所以这条警告说的是一个真实的缺口，不是噪音
   *   —— 在 PC 上这些栏会原地不动。
   *
   *   逐条栏的形式 setSpecificSystemBarEnabled 先试过，理论是它能避开这条警告。它
   *   不能；它带有同样的 2in1 限制，而且同样的覆盖面下代价是【两】条警告而不是一条。
   *   所以保留了单次调用的形式，并且明知故犯地接受这条警告。
   *
   *   2in1 这种情形是可以承受的：调用有守卫，所以在 PC 上它会安静地失败，下面的布局
   *   仍然会变全屏。平板和手机 —— 本项目构建和测试所用的 —— 不受影响。
   *
   * 为什么还要让页面进入全屏
   *   只隐藏这些栏，布局仍会保留它们那条带，那么球就还有一块可见的地方可藏，缺陷依旧。
   *   这两件事是分开的，两件都需要。
   *
   * 失败是可以承受的
   *   一切都有守卫，失败是记日志而不是抛出。不沉浸正是本应用直到现在发布时所处的
   *   状态，所以这里没有任何值得为它启动失败的东西。
   */
  async enterImmersive(): Promise<void> {
    try {
      const ctx: common.UIAbilityContext | undefined = this.ballCtx();
      if (ctx === undefined) {
        return;
      }
      const win: window.Window = await window.getLastWindow(ctx);
      await win.setWindowSystemBarEnable([]);   /* [B] 空列表表示两条栏都不要 */
      await win.setWindowLayoutFullScreen(true);
      win.setImmersiveModeEnabledState(true);
      hilog.info(DOMAIN, TAG, 'immersive: bars hidden, layout full-screen');
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG,
                 'immersive: not available (%{public}s) -- keeping the bars', err.message);
      return;
    }
    /* [A]
     * 单独读回，放在它自己的守卫里：这是一次测量，而这里抛异常会被报成「沉浸式不可
     * 用」，可上面的调用明明成功了。
     */
    try {
      const ctx: common.UIAbilityContext | undefined = this.ballCtx();
      if (ctx === undefined) {
        return;
      }
      const win: window.Window = await window.getLastWindow(ctx);
      hilog.info(DOMAIN, TAG, 'immersive: read back = %{public}s',
                 win.getImmersiveModeEnabledState() ? 'on' : 'off');
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'immersive: read-back failed: %{public}s', err.message);
    }
  }

  /* [A]
   * 在游戏的文本框位置旁边，报告键盘有多高。
   *
   * 这就是整套方案所依赖的测量。框架只会把页面上推直到聚焦文本框可见，所以问题在于
   * 那个文本框最后是否落在（屏幕高度 - 键盘高度）之上。把键盘自身的高度和文本框矩形
   * 一起打出来，就把这件事从主观判断变成了算术。
   *
   * 两种失败模式在屏幕上看起来一样 —— 文本框还是被盖住 —— 但含义相反：框架什么都没
   * 移（摆放根本没被采纳，再怎么调它也没用），或者移了但不够远（margin 常量就是那个
   * 杠杆）。只有这些数字能把它们分开。
   *
   * 包在 try/catch 里：如果在这台设备上有任何一项不可用，正确的结果是「没有测量值」，
   * 而不是一个构建失败的页面。
   */
  async watchKeyboardHeight(): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const win = await window.getLastWindow(ctx);
      this.imeWindow = win;
      /* [A]
       * 避让区域文档写明以 px 计量，而文本框矩形是为 .position() 转成 vp 的；两者
       * 都以 vp 打日志，好让这个比较是同口径的。
       */
      win.on('avoidAreaChange', (data: window.AvoidAreaOptions) => {
        if (data.type !== window.AvoidAreaType.TYPE_KEYBOARD) {
          return;
        }
        const kbVp: number = px2vp(data.area.bottomRect.height);
        hilog.info(DOMAIN, TAG,
          'ime rect/keys: keyboard=%{public}dvp | field x=%{public}dvp y=%{public}dvp w=%{public}dvp h=%{public}dvp',
          kbVp, this.imeFieldX, this.imeFieldY, this.imeFieldW, this.imeFieldH);
      });
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'ime: keyboard measurement unavailable: %{public}s', err.message);
    }
  }

  /* [A]
   * 删除【上一次】运行遗留的请求，赶在任何东西读到它之前。
   *
   * ime_want 只在游戏有文本框聚焦期间存在：原生侧在 SDL_StartTextInput 里创建它，
   * 在 SDL_StopTextInput 里移除它。如果应用在那个对话框开着时被杀掉，这个文件会活到
   * 下一次启动 —— 而下面的轮询在第一个 tick 就把它读成一条活的请求，于是键盘会在
   * 主菜单上、没有任何东西聚焦的情况下自己弹出来。设备上报的现象：留着一个文本框，
   * 杀掉应用，再打开它。
   *
   * 启动时清除是成立的，因为此时请求不可能合法：这段代码在游戏画出任何东西之前运行，
   * 更别说聚焦某个文本框了，所以此刻存在的任何文件按定义都是遗留物。游戏要是还想要
   * 文本，它会再问一次。
   *
   * ime_cmd 也一样。它带着上一次会话打字的尾巴，等另一份 libSDL3.so 去排空，而那份
   * 还没运行 —— 所以同样的推理适用，一条过期的命令会被重放进一个根本不存在的文本框。
   * 它是被截断而不是被删除的，因为原生侧打开它时假设它存在……而在这个时点那个假设并不
   * 成立，所以删除才是诚实的选项；原生侧会按需创建它。
   *
   * ime_rect 刻意【不】动。它是原生侧发布的读数，留着它，readImeRect() 就能退回用
   * 最后一个已知可用的矩形，而不是退回 1x1 的默认值。
   */
  clearStaleImeState(): void {
    const stale: string[] = [IME_WANT_FILE, IME_CMD_FILE];
    for (const path of stale) {
      try {
        /* [A] accessSync 返回一个布尔值；文件缺失时它不会抛异常 —— 见 pollImeWant
         * 里的说明。 */
        if (fs.accessSync(path)) {
          fs.unlinkSync(path);
          hilog.info(DOMAIN, TAG, 'ime: cleared a stale %{public}s from the previous run', path);
        }
      } catch (e) {
        /* [B] 一个删不掉的遗留物值得知道，但不值得为它让页面失败：轮询还是会打开
         * 键盘，那正是根本没有这次调用时的行为。 */
        const err = e as BusinessError;
        hilog.warn(DOMAIN, TAG, 'ime: could not clear %{public}s: %{public}s', path, err.message);
      }
    }
  }

  aboutToDisappear(): void {
    if (this.imeTimer >= 0) {
      clearInterval(this.imeTimer);
      this.imeTimer = -1;
    }
    this.cancelBallHide();
    if (this.imeWindow !== undefined) {
      this.imeWindow.off('avoidAreaChange');
      this.imeWindow = undefined;
    }
  }

  pollImeWant(): void {
    let want: boolean = false;
    try {
      /* [A] accessSync 返回一个布尔值；文件缺失时它不会抛异常。 */
      want = fs.accessSync(IME_WANT_FILE);
    } catch (e) {
      want = false;
    }
    /* [A]
     * 这个请求文件说的是【游戏】想要什么，不是【用户】想要什么，而把两者混为一谈正是
     * 让键盘关不掉的原因：用户关掉了它，游戏还想要文本，于是下一个 tick 又把它放回来。
     *
     * 在把它拆开之前实测过：ESC 关掉了键盘，它立刻又出现；而游戏的文本框从不放弃焦点，
     * 因为 ESC 从未抵达游戏（我们的文本框把它吃掉了）。
     *
     * 所以 `want` 变 false 就是一次重新开始，而一次关闭会锁存到那时为止。
     */
    if (!want) {
      if (this.showIme) {
        this.dismissIme();
      }
      this.imeDismissedUntil = 0;
      /* [B] 游戏放开了文本框，所以用户之前做过的都作废了：下一个文本框必须能自己
       * 唤起键盘。 */
      this.imeUserHid = false;
      return;
    }
    if (Date.now() < this.imeDismissedUntil) {
      return;   /* [B] 刚被用户收起来；给游戏一点时间反应 */
    }
    if (this.imeDismissedUntil !== 0) {
      /* [A]
       * 截止时间到期了，而游戏【仍然】在要文本。这意味着我们转发出去的 ESC 没能关掉
       * 游戏的对话框 —— 所以当键盘「自己又回来了」时，要在 hilog 里找的就是这一行。
       */
      hilog.warn(DOMAIN, TAG, 'IME dismissed %{public}dms ago but the game still wants text; the forwarded ESC did not release it', IME_DISMISS_MS);
      this.imeDismissedUntil = 0;
    }
    /* [B] 文本框可能移动了，或者这是第一次可用的读数。 */
    this.readImeRect();
    if (!this.showIme) {
      this.showIme = true;
      this.imeSent = '';
      /* [A]
       * 在这个状态变化触发的那一帧被构建出来之前，文本框并不存在，所以第一次请求必须
       * 等它。一次延迟请求就够了，因为接下来由下面的分支接手。
       */
      setTimeout(() => {
        if (this.showIme) {
          focusControl.requestFocus('ime_ui_field');
        }
      }, 60);
    } else if (!this.imeFieldFocused && !this.imeUserHid) {
      /* [A]
       * 游戏仍然想要文本、文本框也在，但它不持有焦点 —— 有东西把它抢走了。重新拿回来。
       *
       * 这取代了显示之后约 450ms 内散开的五次请求连发，那个形状是错的：一次抢焦落在
       * 连发结束之后，会让文本框留着却永久死掉，而且再也不会有人重试。改成每次轮询都
       * 请求反而更简单、也能自我纠正，而且它不会失控，因为轮询是每 200ms 一次，不是
       * 循环。
       *
       * `imeUserHid` 正是这一切安全的原因。没有它，这个分支就分不清「一次需要恢复的
       * 抢焦」和「用户刚刚藏起了键盘」，因为两者都恰恰是「文本框在、无焦点、游戏还在
       * 要」—— 于是它不管哪种都会把焦点拿回来，也就把键盘在用户刚关掉之后直接放了回来。
       * 这个标志是「用户藏起键盘」时置位的，上面关于它的注释说明了为什么游戏自己的请求
       * 不能代替它。
       */
      focusControl.requestFocus('ime_ui_field');
    }
  }

  dismissIme(): void {
    this.imeDismissedUntil = Date.now() + IME_DISMISS_MS;
    this.showIme = false;
    /* [A] 在这里清掉它，赶在卸载触发的 onBlur 到达之前：否则那个 blur 会看到一个
     * 「曾经」聚焦的文本框，从而延长截止时间，那会在下一次请求时把键盘又推后 1.5s。 */
    this.imeFieldFocused = false;
    /* [A] 把键盘交还给游戏，否则 ESC 和 WASD 就不再到达。 */
    focusControl.requestFocus('SDL_XComponent');
  }

  /* [A]
   * 读取游戏的文本框矩形，并把我们的隐形文本框摆到它上面。
   *
   * 键盘弹起期间每次轮询都调用，而不只在它出现时调一次：文本框会移动（对话框被拖动、
   * 视口缩小），原生侧只要它变了就会重新发布。
   *
   * 一个坏读数【绝不】覆盖一个好读数。原生侧只在文本输入活跃时写入，所以键盘弹起的
   * 那一刻文件里可能是一个过时但仍可用的矩形 —— 而如果文件写着 "0 0 0 0"，照它写
   * 一帧就会把布局拽到左上角再拽回来。所以面积为零或负会被忽略，上一次的摆放保持不变。
   */
  readImeRect(): void {
    let text: string = '';
    try {
      text = fs.readTextSync(IME_RECT_FILE);
    } catch (e) {
      return;   /* [B] 还没写入；保留我们已有的 */
    }
    const parts: string[] = text.trim().split(' ');
    if (parts.length !== 4) {
      return;
    }
    const x: number = Number.parseInt(parts[0], 10);
    const y: number = Number.parseInt(parts[1], 10);
    const w: number = Number.parseInt(parts[2], 10);
    const h: number = Number.parseInt(parts[3], 10);
    if (!Number.isFinite(x) || !Number.isFinite(y) || !Number.isFinite(w) || !Number.isFinite(h)) {
      return;
    }
    if (w <= 0 || h <= 0 || x < 0 || y < 0) {
      return;
    }
    /* [A]
     * 游戏像素 -> vp。SDL 的矩形来自 Arc 的 Core.graphics，那是像素单位，而
     * .position() 用 vp；在平板上两者相差一个显示密度，所以这个转换是承重的，不是
     * 装饰性的。
     */
    const xvp: number = px2vp(x);
    const yvp: number = px2vp(y);
    const wvp: number = px2vp(w);
    const hvp: number = px2vp(h);
    if (xvp === this.imeFieldX && yvp === this.imeFieldY
        && wvp === this.imeFieldW && hvp === this.imeFieldH) {
      return;   /* [B] 没变：照样赋值会让每次轮询都重绘 */
    }
    this.imeFieldX = xvp;
    this.imeFieldY = yvp;
    this.imeFieldW = wvp;
    /* [A] 游戏的文本框，未经修改。IME_FIELD_MARGIN_VP 是在摆放隐形盒子的地方应用的，
     * 不是在这里，这样这里始终是对文件的一次忠实读数 —— 它正是下面那行 hilog 打印的
     * 东西，而一个偷偷包含了布局决定的值，是没人能拿去和测量对照的值。 */
    this.imeFieldH = hvp;
  }

  /* [B]
   * 读取记录的操作方案。
   *
   * 文件不可读或为空都表示 mobile，与这个设置存在之前启动器的做法一致 —— 所以对于
   * 全新安装，按钮显示的是事实，而不是声称一个没人做过的选择。
   */
  readControlMode(): void {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const text: string = fs.readTextSync(ctx.filesDir + '/' + CONTROL_MODE_FILE_NAME);
      this.controlMode = text.trim() === CONTROL_MODE_DESKTOP
        ? CONTROL_MODE_DESKTOP : CONTROL_MODE_MOBILE;
    } catch (e) {
      this.controlMode = CONTROL_MODE_MOBILE;   /* [B] 文件不存在：默认值 */
    }
  }

  /* [A]
   * 记录另一套方案，并告诉玩家需要重启。
   *
   * 重启不是偷懒。Mindustry 的整个输入层和 UI 都派生自一个位 —— Vars.mobile ——
   * 而这个位只被写一次，在 Vars.init() 里，早于游戏存在。它自带的游戏内开关只改输入
   * 处理器、不动那个位，这就是为什么那个开关会在移动端 UI 上给出桌面控制。所以答案
   * 必须在 JVM 启动之前就落到磁盘上，而诚实的做法是把这一点说出来，而不是什么都没
   * 变可见、让玩家以为按钮坏了。
   */
  /* [A]
   * 把一份诊断包写到应用的 Downloads 文件夹，并告知结果。
   *
   * 这个文件夹是在这里重新计算的，而不是记住启动时 ensureModFolder() 那次调用的
   * 结果，因为这个按钮可能在那次解析很久之后才被按下，而玩家可能已经移动或新建了
   * 那个文件夹。modFolderPath() 读的是文件夹设置写下的同一个状态文件，所以它反映的
   * 是当前答案；当它为空时，导出会大声失败，而不是写到某个不存在的地方。
   */
  exportDiagnostics(): void {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const where: string = exportDiagnosticsNow(
        modFolderPath(ctx.filesDir + '/mod_folder'), ctx.filesDir);
      if (where === '') {
        this.toast('导出失败：下载文件夹不可用');
        return;
      }
      hilog.info(DOMAIN, TAG, 'diagnostics exported to %{public}s', where);
      this.toast('已导出到「下载 / Mindustry Ark / diagnostics」');
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'exportDiagnostics threw: %{public}s', err.message);
      this.toast('导出失败');
    }
  }

  toggleControlMode(): void {
    const next: string = this.controlMode === CONTROL_MODE_MOBILE
      ? CONTROL_MODE_DESKTOP : CONTROL_MODE_MOBILE;
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const f: fs.File = fs.openSync(ctx.filesDir + '/' + CONTROL_MODE_FILE_NAME,
        fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE);
      fs.writeSync(f.fd, next);
      fs.closeSync(f);
      this.controlMode = next;
      hilog.info(DOMAIN, TAG, 'control mode set to %{public}s (restart to apply)', next);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'writing control mode failed: %{public}s', err.message);
      return;                                   /* [B] 不要声称一个没落地的改动 */
    }
    this.toast(next === CONTROL_MODE_DESKTOP
      ? '已切换为 PC 模式，重启游戏后生效'
      : '已切换为触屏模式，重启游戏后生效');
  }

  /* [A]
   * 显示一条短消息，但不要让「显示失败」变成「它要报告的那件事失败」。
   *
   * showToast 声明为会抛异常，所以裸调用会是一条编译器警告 —— 而这些调用方来报告
   * 某件事时，通常它们已经做成了那件事。一个抛异常的 toast 不能把一个已完成的操作
   * 变成一个看起来的失败。
   *
   * 走 UIContext 而不是全局的 `promptAction`：全局形式已废弃，而这个文件的废弃警告
   * 已经够多了。
   */
  toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2600 });
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'toast failed (what it reported still happened): %{public}s',
                 err.message);
    }
  }

  /* [C]
   * 导入玩家挑选的模组文件，然后说需要重启。
   *
   * 重启不是偷懒，而且理由和上面的操作方案开关不同：游戏只扫描一次它的模组目录，在
   * Vars.load() 里。没有任何东西在监视它，所以之后到达的文件就躺在磁盘上、不可见。
   * 把这一点说出来，就是「这能用」和「这个按钮什么也不做」的区别。
   *
   * 这个条目为什么非存在不可，见 ModImporter —— 游戏自带的导入按钮在这个平台上
   * 用不了。
   */
  /* [B]
   * 显示 About 卡片，版本号从包里读。
   *
   * 在打开时才读，而不是启动时读：它要花一次包查询，而在那之前没有任何东西需要这个
   * 答案。
   */
  openAbout(): void {
    this.ballMenu = false;
    this.showAbout = true;
    try {
      bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT)
        .then((info: bundleManager.BundleInfo) => {
          this.appVersion = info.versionName;
        })
        .catch((e: BusinessError) => {
          hilog.warn(DOMAIN, TAG, 'about: version lookup failed: %{public}s', e.message);
        });
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'about: version lookup threw: %{public}s', err.message);
    }
  }

  /* [A]
   * importMods() 曾在这里。它已随调用它的那行菜单一起删除 —— 见 build() 里那行
   * 菜单原先所在处的说明。
   */

  /* [A]
   * 记录窗口尺寸，并在第一次听到它时把球放到右边缘。
   *
   * 尺寸来自组件而不是显示器：窗口不总是整块屏幕，而拿错误的矩形去做 clamp 会让球
   * 停在屏幕之外。出于这个理由，完全没有用 display.getDefaultDisplaySync()。
   */
  onWindowSize(w: number, h: number): void {
    if (w <= 0 || h <= 0) {
      return;
    }
    this.winW = w;
    this.winH = h;
    /* [B] 每次上报都重新计算；尺寸跟随窗口。 */
    this.ballSizeVp = Math.round(
      Math.min(Math.max(Math.min(w, h) * BALL_SIZE_RATIO, BALL_SIZE_MIN_VP), BALL_SIZE_MAX_VP));
    if (this.ballPlaced) {
      /* [A]
       * 后续上报时刻意【不】重新 clamp 位置。
       *
       * 框架为让开键盘而把页面上推时，onAreaChange 也会触发。在那里做 clamp 会把球
       * 往上拖，并在键盘关闭后把它留在那里 —— 一次由无关功能引起的、永久而令人困惑的
       * 移动。相比之下，一次让球稍微凸出边缘的尺寸变化是个小得多的问题：存下的位置会
       * 在下次启动时被 clamp，而拖一下就能立刻修正。
       */
      return;
    }
    const s: number = this.ballSizeVp;
    if (this.ballRestoreX >= 0 && this.ballRestoreY >= 0) {
      /* [A]
       * 被 clamp 到「停靠带」里，而不只是 clamp 进窗口。
       *
       * 下界：更早的构建写入的是贴边位置，没有这一条，从那种位置恢复的球会一直贴边
       * 相切，直到玩家碰巧拖动它 —— 正是这次改动要消除的那种不一致。
       * 上界：一个存在更宽屏幕上的位置，绝不能把球放到更窄屏幕的边缘之外。
       * 上界上的 Math.max 让这个带子在极小窗口上不会翻转。
       */
      this.ballX = Math.min(Math.max(this.ballRestoreX, BALL_MARGIN_VP),
                            Math.max(BALL_MARGIN_VP, w - s - BALL_MARGIN_VP));
      this.ballY = Math.min(Math.max(this.ballRestoreY, BALL_MARGIN_VP),
                            Math.max(BALL_MARGIN_VP, h - s - BALL_MARGIN_VP));
    } else {
      this.ballX = w - s - BALL_MARGIN_VP;
      this.ballY = Math.round(h / 3);
    }
    this.ballEdge = this.nearestEdge();
    this.ballPlaced = true;
    hilog.info(DOMAIN, TAG, 'ball: %{public}dvp on a %{public}dvp x %{public}dvp window',
               s, w, h);
    this.scheduleBallHide();
  }

  onBallTouch(e: TouchEvent): void {
    const t: TouchObject = e.touches[0];
    if (e.type === TouchType.Down) {
      /* [A]
       * 【先】露出，而且不带动画。
       *
       * 半隐藏的球所处的位置并不是露出后的球所在的位置，所以拿「隐藏时的坐标」当锚点
       * 去拖动，会把球从手指底下甩出去 —— 就是上报的那个「从半个球里跳出来」。按下时
       * 就露出，也意味着点一下就能把整个球立刻带回来（这正是要求的行为），而不是只在
       * 松手时才露出。
       *
       * 之前的隐藏状态在这里被捕获，因为松手处理器需要它、而之后无法找回：正是这一行
       * 把它销毁掉。
       */
      this.ballWasHiddenOnDown = this.ballHidden;
      this.cancelBallHide();
      this.ballHidden = false;
      this.dragBallX = this.ballX;
      this.dragBallY = this.ballY;
      this.dragTouchX = t.windowX;
      this.dragTouchY = t.windowY;
      this.dragMoved = false;
      return;
    }

    if (e.type === TouchType.Move) {
      const dx: number = t.windowX - this.dragTouchX;
      const dy: number = t.windowY - this.dragTouchY;
      if (!this.dragMoved && Math.abs(dx) < BALL_DRAG_SLOP_VP && Math.abs(dy) < BALL_DRAG_SLOP_VP) {
        return;   /* [B] 仍在点按容差内 —— 先别移动 */
      }
      this.dragMoved = true;
      this.ballMenu = false;   /* [B] 拖动会关闭菜单 */
      const s: number = this.ballSizeVp;
      /* [B] 对窗口做 clamp，这样球不会被推离边缘而丢失。 */
      this.ballX = Math.min(Math.max(this.dragBallX + dx, 0), Math.max(0, this.winW - s));
      this.ballY = Math.min(Math.max(this.dragBallY + dy, 0), Math.max(0, this.winH - s));
      return;
    }

    if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
      if (this.dragMoved) {
        this.snapBallToEdge();
        this.saveBallPos();
        this.scheduleBallHide();
      } else if (this.ballWasHiddenOnDown) {
        /* [A]
         * 第一次点按只把球带回来；打开菜单需要第二次。
         *
         * 没有这个拆分，点半隐藏的球会同时做两件事：既恢复球、【又】打开菜单，于是一个
         * 只想看看球跑哪去了的玩家，会得到一个他并没有要的菜单 —— 而且在做任何别的事
         * 之前还得先把它关掉。把两者分开，就让「露出」成为一个独立的、可反悔的动作。
         *
         * 倒计时会重新开始：否则点一下之后球就会一直待在外面，半隐藏也就不再是静息
         * 状态了。
         */
        this.scheduleBallHide();
      } else {
        this.ballMenu = !this.ballMenu;
        /* [B]
         * 一个隐藏的球配一个打开的菜单，会是一个悬浮在虚无旁边的菜单，而且玩家反正
         * 正在交互中 —— 所以只有在菜单被关掉之后才重新开始倒计时。
         */
        if (!this.ballMenu) {
          this.scheduleBallHide();
        }
      }
      this.dragMoved = false;
    }
  }

  /* [A]
   * 球离哪条边最近。
   *
   * 刻意与隐藏方向共用：如果吸附和隐藏各自算各自的，它们就可能不一致，球会从屏幕
   * 错误的一侧滑出去 —— 看得见，但远在没人会去看的地方。
   */
  nearestEdge(): string {
    const s: number = this.ballSizeVp;
    const cx: number = this.ballX + s / 2;
    const cy: number = this.ballY + s / 2;
    const dLeft: number = cx;
    const dRight: number = this.winW - cx;
    const dTop: number = cy;
    const dBottom: number = this.winH - cy;
    const m: number = Math.min(dLeft, dRight, dTop, dBottom);
    if (m === dLeft) {
      return 'left';
    }
    if (m === dRight) {
      return 'right';
    }
    if (m === dTop) {
      return 'top';
    }
    return 'bottom';
  }

  /* [A]
   * 把球送到最近的那条边。
   *
   * 四条边都算，不只左右：球很小，玩家可能想让它贴在上边或下边，而只支持左右的吸附
   * 会跟他对着干。
   *
   * 带动画而不是瞬移 —— 这个大小的物体在屏幕上瞬移读起来像故障。animateTo 会闭包
   * 捕获那次赋值，所以位置是在回调内部设置一次，而不是在它之前。
   */
  snapBallToEdge(): void {
    if (this.winW <= 0 || this.winH <= 0) {
      return;
    }
    const s: number = this.ballSizeVp;
    const edge: string = this.nearestEdge();
    /* [A]
     * 停在离边 BALL_MARGIN_VP 的地方，不贴边。
     *
     * 贴边是原来的行为，它和一个新摆放的球所在的位置（离边一个 margin）不一致。于是
     * 玩家从未碰过的球保留着它的间隙，而拖动过一次的球就永久失去了间隙。设备上报了
     * 这个现象。
     *
     * 现在这个 margin 是每条边上的停靠内缩量，两条路径都一样。
     */
    let x: number = this.ballX;
    let y: number = this.ballY;
    if (edge === 'left') {
      x = BALL_MARGIN_VP;
    } else if (edge === 'right') {
      x = this.winW - s - BALL_MARGIN_VP;
    } else if (edge === 'top') {
      y = BALL_MARGIN_VP;
    } else {
      y = this.winH - s - BALL_MARGIN_VP;
    }
    this.ballEdge = edge;
    this.getUIContext().animateTo({ duration: 180, curve: Curve.Friction }, () => {
      this.ballX = x;
      this.ballY = y;
    });
  }

  /* [A]
   * 隐藏时球滑出它那条边多远，作为一个渲染期偏移量。
   *
   * 露出时为 0，这是重要的一点：ballX/ballY 是任何东西唯一写入的坐标，所以隐藏永远
   * 不会被误当成一次移动。
   *
   * BALL_MARGIN_VP 是【偏移量的一部分】，不是意外。球现在离边停靠一个 margin，所以
   * 只按球自身的比例来滑，会把那个 margin 也留在屏幕上 —— 球的 40% 再加 8vp，也就是
   * 明显少于要求的三分之五。把 margin 加回去，就把隐藏后的位置钉到【屏幕】边缘，那才
   * 是「留 40% 可见」的意思。
   */
  ballHideDx(): number {
    if (!this.ballHidden) {
      return 0;
    }
    const off: number = this.ballSizeVp * BALL_HIDE_FRACTION + BALL_MARGIN_VP;
    if (this.ballEdge === 'left') {
      return -off;
    }
    return this.ballEdge === 'right' ? off : 0;
  }

  ballHideDy(): number {
    if (!this.ballHidden) {
      return 0;
    }
    const off: number = this.ballSizeVp * BALL_HIDE_FRACTION + BALL_MARGIN_VP;
    if (this.ballEdge === 'top') {
      return -off;
    }
    return this.ballEdge === 'bottom' ? off : 0;
  }

  cancelBallHide(): void {
    if (this.ballHideTimer >= 0) {
      clearTimeout(this.ballHideTimer);
      this.ballHideTimer = -1;
    }
  }

  /* [B] 启动半隐藏的倒计时。每当球停稳或被放开时调用。 */
  scheduleBallHide(): void {
    this.cancelBallHide();
    if (this.ballMenu || !this.ballPlaced) {
      return;
    }
    this.ballHideTimer = setTimeout(() => {
      this.ballHideTimer = -1;
      if (this.ballMenu) {
        return;
      }
      this.getUIContext().animateTo({ duration: 260, curve: Curve.Friction }, () => {
        this.ballHidden = true;
      });
    }, BALL_HIDE_MS);
  }

  /* [C]
   * ability 上下文，走的是没有废弃的那条路。
   *
   * getContext() 仍然能用，这里更早的代码用的就是它，但它已废弃，而这个文件每调用
   * 一次本就带着一条警告。新代码不该再增加。getHostContext() 可能返回 undefined，
   * 所以是检查它而不是假定有 —— 而「没有上下文」意味着文件够不到，两个调用方本来
   * 对此也都不做处理。
   *
   * 只有这两个调用点用它。另外四处调用刻意不动：它们取上下文是为了够到权限和键盘，
   * 在那里，一个行为哪怕稍有差别的改动，代价都远高于一行警告。
   */
  ballCtx(): common.UIAbilityContext | undefined {
    return this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
  }

  /* [B] 球上次停在哪，好让下次启动把它放回去。 */
  saveBallPos(): void {
    try {
      const ctx: common.UIAbilityContext | undefined = this.ballCtx();
      if (ctx === undefined) {
        return;
      }
      const f: fs.File = fs.openSync(ctx.filesDir + '/' + BALL_POS_FILE_NAME,
        fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE);
      fs.writeSync(f.fd, Math.round(this.ballX) + ',' + Math.round(this.ballY));
      fs.closeSync(f);
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'ball: saving the position failed: %{public}s', err.message);
    }
  }

  /* [B]
   * 把存下的位置读进 ballRestoreX/Y。它【不】在这里应用：应用它需要一个窗口尺寸来做
   * clamp，而 onAreaChange 还没上报过。
   *
   * 垃圾内容会被拒绝而不是被 clamp。否则一行损坏的数据会把球停进某个角落、毫无解释；
   * 而对于一个读不了的文件，默认位置是个完全够用的答案。
   */
  readBallPos(): void {
    try {
      const ctx: common.UIAbilityContext | undefined = this.ballCtx();
      if (ctx === undefined) {
        return;
      }
      const text: string = fs.readTextSync(ctx.filesDir + '/' + BALL_POS_FILE_NAME);
      const parts: string[] = text.trim().split(',');
      if (parts.length !== 2) {
        return;
      }
      const x: number = Number(parts[0]);
      const y: number = Number(parts[1]);
      if (!Number.isFinite(x) || !Number.isFinite(y) || x < 0 || y < 0) {
        return;
      }
      this.ballRestoreX = x;
      this.ballRestoreY = y;
    } catch (e) {
      /* [B] 首次运行时没有文件，这是正常情况，不是错误。 */
    }
  }

  /* [B] 菜单摆在哪：球的旁边，朝内开。 */
  ballMenuX(): number {
    const right: number = this.ballX + this.ballSizeVp + 8;
    if (right + BALL_MENU_W_VP > this.winW) {
      return Math.max(0, this.ballX - BALL_MENU_W_VP - 8);
    }
    return right;
  }

  /* [B] 与球垂直对齐，但绝不越过窗口边缘。 */
  ballMenuY(): number {
    const below: number = this.ballY + this.ballSizeVp - 40;
    return Math.min(Math.max(below, 0), Math.max(0, this.winH - BALL_MENU_H_VP));
  }

  appendCmd(text: string): void {
    try {
      const f: fs.File = fs.openSync(IME_CMD_FILE, fs.OpenMode.CREATE | fs.OpenMode.APPEND | fs.OpenMode.READ_WRITE);
      fs.writeSync(f.fd, text);
      fs.closeSync(f);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'ime cmd write failed: %{public}s', err.message);
    }
  }

  /* [A]
   * 系统返回手势在游戏内部上一层。它从不离开应用。
   *
   * Mindustry 的「返回」就是 ESC —— 它关掉当前对话框或菜单并回到上一屏 —— 所以这个
   * 手势被作为 ESC，通过屏幕键盘已经在用的同一条文件通道转发出去。那条通道每一帧都被
   * 无守卫地读取，所以无论有没有文本框，它都能工作。
   *
   * 返回 true 意味着「本页处理了它」：默认返回逻辑不会运行，应用留在屏幕上。所以一次
   * 过去会关掉应用的返回，现在关掉的是一个菜单。
   *
   * 离开应用是游戏自己的退出，不是我们的
   *   退出是在游戏主菜单里做的。那条路径本来就干净收尾：原生侧落下退出标记，本页的
   *   轮询关掉 ability —— 这就是早先验证过的那个安排，是一次干净的退出而不是崩溃。
   *
   *   双击退出先做了，又被拿掉了。要分清「玩家在主菜单」和「玩家在三个对话框深处」，
   *   需要游戏的 UI 状态，而我们没有这个通道 —— 于是那条规则会是一个计时窗口，顶替
   *   我们并不掌握的信息，从 UI 深处任意位置提前退出。对意图做基于时间的猜测，是那种
   *   不该发布的东西。游戏有真正的退出；用它。
   *
   * ⚠️ 接受的代价：在主菜单上返回什么都不做，因为 ESC 在那里无处可去。逃生口不受影响
   *   —— 系统的回桌面手势和最近任务菜单都没动，本项目里任何地方都没有屏蔽它们。
   */
  onBackPress(): boolean {
    /* [A] 'E' 就是整个 ESC 命令；原生侧按整行消费，所以那个换行是命令的一部分，不是
     * 装饰。 */
    this.appendCmd('E\n');
    hilog.info(DOMAIN, TAG, 'back: forwarded as ESC (one level up)');
    return true;
  }

  sendDelta(next: string): void {
    const prev: string = this.imeSent;
    if (next === prev) {
      return;
    }
    let cmds: string = '';
    if (next.startsWith(prev)) {
      cmds = 'T' + next.substring(prev.length) + '\n';
    } else if (prev.startsWith(next)) {
      cmds = 'B' + (prev.length - next.length) + '\n';
    } else {
      /* [B] 一次无法用 append/truncate 表达的编辑。撤回我们掌控的部分再重新输入：
       * 文本框最后是对的，而游戏在本次会话之前就已存在的文本保持不动。 */
      if (prev.length > 0) {
        cmds += 'B' + prev.length + '\n';
      }
      cmds += 'T' + next + '\n';
    }
    this.imeSent = next;
    this.appendCmd(cmds);
  }

  /* [A]
   * 决定 JVM 是否必须以解释方式运行，并写出或删除启动器要读的那个选项文件。
   *
   * 【必须】在 XComponent 创建【之前】运行。启动器在 SDL_main 启动时读那个文件，
   * 而那发生在 XComponent 挂载时 —— 所以这是从运行更早的 aboutToAppear 里调用的。
   * 再晚就是一场赛跑，选项文件有时会输，而输掉是无声的：应用会带着 JIT 起来，然后
   * 死在 JNI_CreateJavaVM 里。
   *
   * 这个文件【每次】启动都往两个方向重写。「需要时写 -Xint、不需要时删掉它」看起来
   * 等价于一次条件写入，其实不是：一台手机第一次被更新到 API 26 以上时，那个 -Xint
   * 会留下来，游戏会永久以解释方式运行，而设备上没有任何东西能解释为什么。
   */
  private setupCompatMode(): void {
    /* [A]
     * 这三者的顺序决定谁压过谁，它是：
     *
     *   FORCE_COMPAT_MODE   一条明确的指令，所以它直接胜出
     *   启动器的结论   对【本次】安装的一次测量
     *   设备类型规则   一个猜测，只在没有测量结果时使用
     *
     * ⚠️ FORCE 必须待在最上面。它就是本项目发布脚本「只要它不是 false 就拒绝构建
     * release」的那个开关，所以它的全部目的就是覆盖自动决定。这次改动的一个更早版本
     * 把结论放到了它上面，于是那个开关无声地失效了：一次开着 FORCE 的启动读到一个
     * 过期的 "jit" 结论，把强制作罢，结果什么都没写 —— 实测如此，这就是为什么在这里
     * 把顺序写明，而不是交给代码的先后顺序。
     */
    let want: boolean = false;
    let kind: string = '?';
    let api: number = -1;
    let source: string = 'device rule';

    try {
      kind = deviceInfo.deviceType;
      api = deviceInfo.sdkApiVersion;
      /* [B] 只是一个首启猜测：见 MIN_API_FOR_JIT。只要启动器报了测量结果，下面的
       * 测量就会取代它。 */
      want = kind === 'phone' && api < MIN_API_FOR_JIT;
    } catch (e) {
      const err = e as BusinessError;
      /* [A]
       * 失败即放行。如果平台不肯说它是什么，就假设 JIT 能用。失败即拒绝，会仅凭一次
       * 查询失败就让所有人玩得更慢。
       */
      hilog.error(DOMAIN, TAG,
        'deviceInfo unavailable (%{public}s) -- assuming the JIT works', err.message);
      kind = 'unavailable';
      want = false;
    }

    /* [A]
     * 启动器的测量压过猜测。
     *
     * 设备类型规则和启动器的探测回答的是不同的问题。规则问「这是不是那类通常拿不到
     * 内存的设备」；探测问「【本次】安装拿到了没有」。只有后者才是玩家体验到的东西，
     * 而两者不一致的频率比规则所暗示的更高：
     *
     *   - 一台 API 26 的手机，规则说是 JIT，而商店包里根本拿不到那个权限；
     *   - 一台 API 26 的手机、DEBUG 安装，规则什么也没说，但 DevEco 的 debug 配置
     *     解开了所有权限，JIT 跑得好好的；
     *   - 一台没有该 ACL 的平板。
     *
     * 有结论时就采纳它，也是在【修复】中间那种情况，而不只是描述它：规则本会写下
     * -Xint，拖慢一台完全能用 JIT 的设备，而一次启动之后测量就会把它改回来。
     *
     * ⚠️ 这个猜测仍然是首启的答案，而且必须如此：在低于 API 26 的设备上还没有结论，
     * 什么都不写会让 JVM 在产生结论之前就卡住。所以顺序是「有测量就用测量，没有就猜」
     * —— 绝不是「假定没问题」。
     */
    const verdict: string = launcherExecMemoryVerdict();
    if (verdict === 'interp') {
      want = true;
      source = 'launcher measured: no executable memory';
    } else if (verdict === 'jit') {
      want = false;
      source = 'launcher measured: executable memory available';
    }

    /* [B] 最后也最高：见顶部关于顺序的说明。 */
    if (FORCE_COMPAT_MODE) {
      want = true;
      source = 'FORCE_COMPAT_MODE';
    }
    /* [A]
     * 【无条件】记录日志，包括输入。
     *
     * 第一个版本只在兼容模式开启时才记日志，这让它自己的正确性无法验证：「选项文件
     * 没被写」也正是一个从未运行的方法会产生的现象。一个决定需要报告它据以做出的输入，
     * 否则它没有产生效果这件事什么都证明不了。
     *
     * 在平板上实测："compat mode: device=tablet api=26 -> interpreted=false"，与
     * 启动器的 "(no options file found; tried 3 locations)" 并列。两个独立的观察，
     * 彼此吻合。
     */
    hilog.info(DOMAIN, TAG,
      'compat mode: device=%{public}s api=%{public}d -> interpreted=%{public}s (from %{public}s)',
      kind, api, String(want), source);

    const ctx = getContext(this) as common.UIAbilityContext;
    const path: string = ctx.filesDir + '/' + JVM_OPTIONS_FILE_NAME;
    try {
      if (want) {
        const f: fs.File = fs.openSync(path,
          fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE);
        fs.writeSync(f.fd, '-Xint' + String.fromCharCode(10));
        fs.closeSync(f);
        hilog.info(DOMAIN, TAG, 'compat mode ON: -Xint written to %{public}s', path);
      } else if (fs.accessSync(path)) {
        /* [A] accessSync 【返回】一个布尔值；文件缺失时它不会抛异常。把它当成会抛
         * 异常的检查，正是一个应用曾经在每次启动后 0.25 s 自杀的原因。 */
        fs.unlinkSync(path);
        hilog.info(DOMAIN, TAG, 'compat mode off: removed %{public}s', path);
      }
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'could not set compat mode: %{public}s', err.message);
      /* [A] 保持原样。一个过期的 -Xint 代价是速度；缺了它代价是应用根本起不来。继续
       * 走下去，比从 aboutToAppear 里抛出去要好。 */
    }

  }

  /** [A]
   * 决定这一屏显示游戏还是启动器。**只在 aboutToAppear 里调用一次。**
   *
   * ⚠️⚠️ 为什么这个判定必须在 ArkTS 里、而且必须在【挂载 XComponent 之前】：
   *
   *     挂载 XComponent ⇒ 加载 libmain.so ⇒ main() 跑 ⇒ 一次完整的 JVM 启动
   *
   * 所以「先挂上、再由 native 说没有游戏」是错的 —— 那会白起一次 JVM（几百 MB 的
   * 匿名可执行内存、一个 SDL 窗口、一整条初始化链），然后才发现无事可做。这正是
   * `shieldBlocked` 用过的同一个形状，也是它同样在 aboutToAppear 里判定的理由。
   *
   * native 那一侧仍然【也】判一次（launcher.c 的 resolve_game_jar），那不是重复：
   * 那一次防的是 `aa start` 之类的路径绕过界面直接拉起 native，而两次之间文件也可能
   * 被删掉。
   */
  /* [A]
   * 把「上次为什么没起来」拼成一段给玩家看的话。
   *
   * ⚠️ 判据要分清，因为两句话指向的处置完全不同：
   *   · jvm_incomplete ⇒ Java 虚拟机都没建起来。多半是设备/权限层面的事，与 jar 无关
   *   · 走到这里但 JVM 好的 ⇒ **那个 jar 里没有游戏**。最典型的就是把一个 mod 当游戏
   *     选了（用户 2026-10-01 实际遇到的那一种）
   *
   * ⚠️ 日志尾巴是【搬过来】的，不是我编的：启动器把每一处失败都写进 stderr.log，
   * 例如 "!! mindustry.core.Vars is NOT on the classpath" —— 那一句就是原因本身。
   * 与其写一句「可能是不兼容的 jar」，不如把启动器自己写下的那行交出去。
   *
   * ⚠️ 上限刻意小（1.2 KB）：这是弹窗里的一小块文字，不是导出诊断。
   */
  private buildLaunchFault(jarPath: string): string {
    const lines: string[] = [];
    if (jarPath !== '') {
      lines.push('尝试启动的游戏：' + jarPath);
    } else {
      lines.push('尝试启动的游戏：（这次没能记下是哪一个）');
    }
    if (this.jvmIncomplete) {
      lines.push('');
      lines.push('上次运行时，游戏所需的 Java 虚拟机没有创建成功。');
    } else {
      lines.push('');
      lines.push('启动器没有在那个文件里找到游戏。它可能不是一个可玩的 Mindustry，'
                 + '比如把一个模组（.jar）当成游戏选中了。');
    }
    lines.push('');
    lines.push('启动器留下的最后记录：');
    lines.push(readStartupLogTail(FAULT_LOG_BYTES));
    return lines.join(String.fromCharCode(10));
  }

  private decideStartup(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    this.launcherFilesDir = ctx.filesDir;
    this.launcherBundleDir = ctx.bundleCodeDir;

    /* ⚠️ 这个调用【顺带把标记删掉】—— 读而不清会把「点过一次启动器」变成一道永久的
     * 门。理由写在 consumeLauncherRequest 的注释里，那里执行了删除。 */
    const requested: boolean = consumeLauncherRequest(ctx.filesDir);

    const r: GameResolution = resolveGame(ctx.filesDir, ctx.bundleCodeDir);
    /* [A] 每一次都把这些路径写进日志。🔶 `bundleCodeDir` 的取值目前只是推断，
     * 而「判定没有游戏」和「我把内置游戏的路径算错了」在界面上长得一模一样 ——
     * 第一次上设备时，这几行是唯一能把两者分开的东西。 */
    reportGameResolution(ctx.filesDir, ctx.bundleCodeDir, r);

    if (requested) {
      hilog.info(DOMAIN, TAG, 'startup: the launcher was requested -- showing it');
      this.showLauncher = true;
      return;
    }

    /* [A]
     * 上一次的启动尝试没有走到游戏入口 ⇒ 回启动器，并把原因交给它显示。
     *
     * ⭐ 这是「一打开就闪退、回不了主界面」的解药。用户 2026-10-01 实际撞上：
     * 他把一个 **mod 当成游戏**选了。
     *
     * ⚠️ 为什么现有的两个标记都盖不住它，见 GameLibrary 里 launch_pending 上的说明 ——
     * 简单说：JVM 建起来了（jvm_incomplete 已被删），主类找不到时是**干净返回**
     * （不写 crash.txt）。⇒ 必须有一个「有没有到过游戏入口」的独立判据。
     *
     * ⚠️ **读后即删**，和 consumeLauncherRequest 同一个形状：留着它会让每一次启动都
     * 再弹一次同样的窗。删掉之后玩家再试一次，标记会被 startGame 重新写上。
     */
    const pending: string = pendingLaunchAttempt(ctx.filesDir);
    if (pending !== '' || this.jvmIncomplete) {
      this.launchFaultJar = pending;
      this.launchFault = this.buildLaunchFault(pending);
      hilog.info(DOMAIN, TAG,
                 'startup: the last launch never reached the game entry point (jar=%{public}s)',
                 pending === '' ? '(unknown)' : pending);
      clearLaunchAttempt(ctx.filesDir);
      this.showLauncher = true;
      return;
    }

    /* [A]
     * 玩家选了「启动时先进首页」。
     *
     * ⚠️ 排在失败判定【之后】：那是必须回的，而这一条是玩家自己的偏好，
     * 两者都成立时理由更强的那个赢。
     */
    if (readLaunchMode(ctx.filesDir) === LAUNCH_MODE_HOME) {
      hilog.info(DOMAIN, TAG, 'startup: the launch mode is "home" -- showing the launcher');
      this.showLauncher = true;
      return;
    }

    if (r.path === '') {
      hilog.info(DOMAIN, TAG, 'startup: no game to load -- showing the launcher');
      this.showLauncher = true;
      return;
    }
    this.showLauncher = false;
  }

  /** [A]
   * 启动器里点了「启动游戏」。参数是最终决定要加载的那个 jar，'' 表示「用包里的」。
   *
   * ⚠️ 顺序承重：桥接必须在 XComponent 挂载【之前】写。native 在 SDL_main 一启动时
   * 就读 user_dirs.txt，而挂载是这一句之后的下一帧 —— 写晚了，这一次加载的会是上一次
   * 选择的结果，而那种错误看起来只是「换了 jar 但没生效」。
   */
  private startGame(jarPath: string): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    /* [A] gamejar= 那一行是 writeUserDirs 从 selected_game.txt 推出来的 —— 不在这里
     * 单独拼一遍。一份知识一个来源，而桥接的格式只由写它的那个函数拥有。 */
    writeUserDirs(ctx.filesDir);

    /* [A]
     * 记下「正在尝试启动这个 jar」，在切到游戏树【之前】—— 那是重点。
     *
     * ⚠️ 走到这里的路不只一条，而参数在有的路上是空的：本页里 '' 表示「用包里的那一份」
     *   （见上面 onLaunch/onForceLaunch 的说明）。空的时候自己解析一遍，而不是把空路径
     *   记进标记 —— 标记里那句话是失败时给玩家看的「是哪一个没起来」，写空就等于把唯一
     *   有用的信息丢掉了。
     *
     * ⚠️ 这里【不】为「绕过判定」这个意图开特例：即使玩家强行启动，这一次尝试照样记账。
     *   否则最需要它记录的那一次，恰好是它不记录的那一次。
     */
    const res: GameResolution = resolveGame(ctx.filesDir, ctx.bundleCodeDir);
    const attempted: string = jarPath !== ''
      ? jarPath
      : res.path;
    markLaunchAttempt(ctx.filesDir, attempted);

    /* [A] ⭐ 版本隔离的桥必须在【这里】再写一次 —— native 的 main() 就在下面这一句之后开始跑。
     *
     * ⚠️⚠️ 不能只靠 EntryAbility.onCreate 写的那一次：默认模式是「先显示启动器」，
     * 也就是说玩家会在 onCreate 之后才改选 jar，而 onCreate 写下的键属于**上一个**选择。
     * 那是一个无声的错：数据会落到另一个版本的目录里，而且**看起来一切正常**。
     * （同族：本项目「在 A 事件里读 B 事件才写入的字段」那条教训。）
     *
     * ⚠️ 键跟着【真正要启的那个】走，而不是 resolveGame 自己的结论：
     * 两者在这条路上本该一致，但「启动哪一个」必须只有一个来源。
     * 所以 jarPath 给了就用它（那是玩家的选择），空了才回落到解出来的那个。 */
    try {
      const g: string = readGranularity(ctx.filesDir);
      const src: string = jarPath !== '' ? 'user' : res.source;
      writeIsolationBridge(ctx.filesDir, g, computeKey(g, src, attempted));
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'isolation: could not decide at launch (%{public}s)', err.message);
    }

    this.showLauncher = false;
  }

  /** [A]
   * 悬浮球菜单里的「启动器」：回启动器界面。
   *
   * ⚠️ 它不能直接 `this.showLauncher = true` —— 那段代码运行时，游戏已经起来了，
   * 本页的树里挂着一个活的 XComponent，把它从树上摘掉等于在 native 正在跑的时候拆它的
   * surface。所以走的是【既有的退出握手】的同一个形状（悬浮球的其它退出路径也是）：
   * 记下意图，然后 terminateSelf，让框架按它自己的顺序拆。下次启动时
   * decideStartup() 读到那个意图。
   */
  private backToLauncher(): void {
    const ctx = getContext(this) as common.UIAbilityContext;

    /* [A]
     * 【先】记下意图，再重启。
     *
     * ⚠️ 顺序不能反，而且这一句不只是「顺手」：它是 restartApp 失败时的唯一退路。
     * 先写标记 ⇒ 无论重启成不成，下一次启动都会进启动器，只是多要点一下图标。
     */
    requestLauncher(ctx.filesDir);

    /* [A]
     * 顺手把「正在尝试启动」的标记清掉。
     *
     * ⚠️ 走到这里说明游戏**已经在跑了**（否则到不了悬浮球），也就是说那次启动是成功的，
     * 而 native 早已在游戏入口处删过标记 —— 所以这一句在正常路径上是空操作。
     * 它防的是另一件事：万一哪次 native 没能删成（权限、异常路径），下一次启动会把
     * 「刚才明明玩得好好的」报成失败。清掉是幂等的，代价为零。
     */
    clearLaunchAttempt(ctx.filesDir);

    /* [A]
     * 用 `ApplicationContext.restartApp()` 一次性重启进程并拉起本 ability —— 用户要的
     * 「点悬浮球的启动器，自动重启回到主界面」。
     *
     * 为什么必须是「重启」而不是「直接切界面」
     *   换一个游戏 = 换一个 jar = **必须重开 JVM**：classpath 在 VM 创建时就定死了，
     *   `main()` 也已经跑过一个循环。所以「切到启动器」如果只是换一屏，
     *   它换的也是一个**仍然加载着旧 jar 的进程** —— 看着对了，实际什么都没换。
     *   ⇒ 重启不是实现上的将就，而是这件事本身的要求。
     *
     * ⚠️ 为什么是 ApplicationContext 那一版，不是 `UIAbilityContext.restartApp`
     *   SDK 原文（UIAbilityContext 版）：
     *     "This API can be properly called only on phones. If it is called on other
     *      device types, error code 801 is returned."
     *   ⛔ 那我们最主要的设备（平板）就不能用。`ApplicationContext.restartApp` 的文档里
     *   **没有**这条限制，而且从 API 12 就有。
     *
     * ⚠️ 它会抛，而且理由各不相同（16000053 不在前台 / 16000063 目标不对 /
     *   16000064 三秒内重启过频）。**一律落到退路**：上面的标记已经写好了，
     *   terminateSelf 之后玩家点一下图标就能回到启动器。
     */
    try {
      ctx.getApplicationContext().restartApp({
        bundleName: ctx.applicationInfo.name,
        abilityName: ctx.abilityInfo.name,
      });
      hilog.info(DOMAIN, TAG, 'restartApp requested -- the app will come back on the launcher');
      return;
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG,
                  'restartApp failed (code=%{public}d %{public}s) -- falling back to terminateSelf',
                  err.code, err.message);
    }

    /* [B] 退路：关掉自己。下一次启动读到上面那个标记，照样进启动器。 */
    ctx.terminateSelf().catch((err: BusinessError) => {
      hilog.error(DOMAIN, TAG, 'terminateSelf failed: %{public}s', err.message);
    });
  }

  build() {
    /* [B] 用 Stack，让文本框浮在游戏之上，而不是让游戏表面重排给它腾地方。 */
    Stack({ alignContent: Alignment.Top }) {
    /* [A]
     * 启动器【替换】整棵游戏树，而不是盖在它上面。这不是审美选择：
     *
     *   · 盖上去的话，XComponent 仍然会被挂载 ⇒ native 仍然会起一次 JVM ——
     *     而「没有游戏可加载」的那一屏之所以存在，正是为了【不要】起那一次。
     *   · 而且游戏树里那个隐形的 TextInput 是可获焦的，它会压在启动器的按钮之上，
     *     于是点击落到它身上。这个项目在焦点上栽过不止一次。
     *
     * ⚠️ 下面那一段的缩进【刻意没有】跟着 else 往右移四百多行：那样做会让这个唯一的
     * 真实改动被埋进一个巨大的空白 diff 里，而审查一遍看不出改了什么。这里的代价
     * 只是 else 块的内层缩进比它该有的少两级。
     */
    if (this.showLauncher) {
      LauncherHome({
        filesDir: this.launcherFilesDir,
        bundleCodeDir: this.launcherBundleDir,
        /* [B] 见 folderSettled 上的说明：它到位之前，本页读到的是空路径。 */
        folderSettled: this.folderSettled,
        /* [B] 设置页的「关于」要显示版本。它由本页从 bundle 问到，见 appVersion。 */
        appVersion: this.appVersion,
        /* [B] 上一次启动失败的记录；'' 表示没失败过。由 decideStartup 组装，
         * 见 buildLaunchFault —— 里面既有「是哪个 jar」，也有启动器自己写下的那几行。 */
        launchFault: this.launchFault,
        onLaunch: (jarPath: string) => { this.startGame(jarPath); },
        /* [A] 「仍然尝试启动」：绕开判定，直接进游戏树。它是逃生门 —— 判定没有游戏有
         * 三个来源（真的没有 / 我把路径算错了 / 那台设备上建不出文件夹），而其中两个
         * 是我的问题。没有它，一次判断失误就把应用变成永远打不开游戏的启动器。 */
        onForceLaunch: () => { this.startGame(''); },
      })
    } else {
    Row() {
      Column() {
        if (!this.shieldBlocked) {
          XComponent({ id: 'SDL_XComponent', type: XComponentType.SURFACE, libraryname: 'SDL3' })
            .id('SDL_XComponent')
            /* [A]
             * 键盘输入需要这个组件持有焦点。
             *
             * ArkUI 只把按键事件投递给聚焦的组件，而 SDL 是通过
             * OH_NativeXComponent_RegisterKeyEventCallback 注册的回调收到它们的。
             * 没有设置焦点时，没有任何东西聚焦，于是按键事件永远到不了原生代码 ——
             * 而这是无声的：SDL 从来看不到一个可以上报的按键，游戏的行为就像键盘没
             * 连上一样。
             *
             * defaultFocus 让它在页面构建时成为焦点目标。
             *
             * focusOnTouch 曾在这里，现已【刻意去掉】。它让组件在每次触摸时重新夺回
             * 焦点，从而和键盘所需的焦点请求形成竞争：点游戏的文本框会在本表面上产生
             * 一次触摸，焦点请求在一次轮询延迟后发出，而如果手指剩余的触摸事件落在它
             * 之后，focusOnTouch 就干脆把焦点抢了回去。文本框于是弹出来了却没聚焦，
             * 也就没有键盘。这正是上报的症状 —— 「有时候点一下就够，有时候不够」——
             * 而一场取决于手指事件如何交错进行的竞争，只能表现为时有时无。
             *
             * 去掉它没有任何损失：触摸仍然到得了游戏（ArkUI 按坐标投递指针事件，不
             * 按焦点 —— 只有【按键】事件跟随焦点），初始焦点仍来自 defaultFocus，而
             * 每一条收起键盘的路径都会显式请求把焦点要回来。
             */
            .focusable(true)
            .defaultFocus(true)
            /* [A]
             * 最早的按键钩子，它必须【拒绝】（返回 false）。
             *
             * 在这里消费 ESC 确实能修正系统行为，但实测它会在原生代码看到之前就把
             * 这个键吞掉：ESC 时 SDL 一个字节都没记到，而非 ESC 的控制键仍然正常到达。
             * 所以这个断口专属于「消费」，不是普遍性的键盘损坏 —— 但它仍然意味着游戏
             * 永远拿不到它的 ESC，这不是一笔可以接受的交易。
             */
            .onKeyPreIme((e: KeyEvent) => {
              hilog.info(DOMAIN, TAG, 'onKeyPreIme[X]: keyCode=%{public}d -> consumed=false (pass through)',
                e.keyCode);
              return false;
            })
        }
      }
      .width('100%')
      /* [A]
       * ESC 必须不再充当系统返回键，同时【又】不能被从游戏那里拿走。这两条要求方向
       * 相反，所以处理器被放在这个【祖先】节点上，而不是 XComponent 上，而这个位置
       * 就是全部的修复。
       *
       * 事件链，来自一次实测的 ESC 按下（hilog 时间戳）：
       *
       *   13.965  onKeyPreIme[X]        consumed=false   <- 我们的，拒绝
       *   13.971  onKeyEvent[Column]    consumed=true    <- 我们的，在祖先上
       *   （以前：Ace: OnBackPressed called —— 在它返回 true 之后就不再出现）
       *
       * 要紧的顺序：onKeyPreIme -> XComponent（它的原生回调在这里运行，SDL 就是在这里
       * 拿到键的）-> 祖先。因为祖先只有在 XComponent 已经派发给原生代码【之后】才会被
       * 触达，在这里消费不可能从游戏那里夺走任何东西。
       *
       * 相比之下，挂在 XComponent 自身上面的 `onKeyEvent` 根本永远不会被调用 —— 原生
       * XComponent 路径优先于它。无论它返回什么，那都是条死路，而且实测如此（它那行日志
       * 出现了零次）。不要把处理器挪回去。
       *
       * 原生侧的回调语义也值得记下：SDL_OpenHarmonyDispatchKeyEvent 返回 void，所以
       * 原生代码没办法报告「我消费了这个」。这个决定只能在 ArkUI 里做，这就是为什么
       * 它没有在 C 里解决。
       *
       * 【只有】ESC 会被消费；其他每个键都返回 false，好让游戏输入和文本录入（需要
       * IME）不受影响。
       *
       * 这些 hilog 行不是装饰。一个无声地从不被调用的处理器已经让本项目付出过一轮
       * 代价：早先的尝试用了不存在的名字 `onBackPress`，它能编译、能运行、被调用的
       * 次数恰好是零，看起来活像一个「就是没生效」的修复。如果这些行没出现在 hilog
       * 里，说明处理器没在跑，结果也就毫无意义。
       */
      .onKeyEvent((e: KeyEvent) => {
        const esc = e.keyCode === KeyCode.KEYCODE_ESCAPE;
        hilog.info(DOMAIN, TAG, 'onKeyEvent[Column]: keyCode=%{public}d -> consumed=%{public}s',
          e.keyCode, String(esc));
        return esc;
      })
    }
    .height('100%')

      /* [B]
       * 只在游戏内有文本框聚焦时出现。单行：命令协议是基于行的，而 Mindustry 的
       * 文本框（存档名、文件名）本来也是单行。
       */
      if (this.showIme) {
        /* [A]
         * 刻意不可见：用户在【游戏】自己的文本框里看到自己打的内容，那个框随打字更新，
         * 所以再显示第二个框既多余又让人困惑。有了这个隐藏，可见的结果就是系统键盘在
         * 直接驱动 Mindustry。
         *
         * 它仍然必须存在、可聚焦、并持有 IME —— 一个不可见但持有焦点的组件，才是让
         * 键盘保持弹起的东西。如果输入法哪天拒绝为一个零透明度文本框出现，要改的就是
         * 这一行：给它 0.01 的透明度。
         *
         * 它盖在【游戏】的文本框上，而不是像过去那样在屏幕顶部。那个位置就是整个机制：
         * 框架的键盘避让只会把页面上推到这个聚焦文本框可见为止，所以把它放到玩家实际
         * 正在看的地方，就能让框架把游戏移动恰好露出那一处的距离。锚在顶部时它什么都
         * 没要求，于是什么都没动，键盘就把文本框盖住了。
         */
        TextInput()
          .id('ime_ui_field')
          /* [B] 锚在文本框的左上角，且只在键盘真正弹起时比它更高。margin 为什么存在、
           * 以及为什么键盘隐藏时不能有它，见 IME_FIELD_MARGIN_VP。 */
          .position({ x: this.imeFieldX, y: this.imeFieldY })
          .width(this.imeFieldW)
          .height(this.imeFieldH + (this.imeUserHid ? 0 : IME_FIELD_MARGIN_VP))
          .opacity(0)
          .onChange((v: string) => {
            this.sendDelta(v.replace(/[\r\n]/g, ''));
          })
          .onFocus(() => {
            this.imeFieldFocused = true;
            /* [B] 用户主动要了键盘 —— 靠点这个文本框，它之所以还留在屏幕上、盖在游戏
             * 的文本框上，正是为了还能再被点到。他之前做过的都作废了。 */
            this.imeUserHid = false;
          })
          .onBlur(() => {
            /* [A]
             * 键盘被收起来了。按系统键盘自带的隐藏按钮、以及点文本框之外的地方，都会
             * 落到这里，两者含义相同：它不该自己回来。
             *
             * 为什么游戏自己的请求决定不了这件事
             *   `ime_want` 说的是【游戏】想要什么，而游戏永远不会知道用户把键盘藏了：
             *   它自己的文本框仍然聚焦，所以 SDL 从不调用 HideScreenKeyboard，请求
             *   文件就一直留在磁盘上。这个标志存在之前实测到的症状：收起键盘，它立刻
             *   又回来了 —— 轮询看到「文本框在、无焦点、游戏还在要」，于是又把焦点拿
             *   了回来。
             *
             * 我们自己的收起从不到达这里：dismissIme() 在文本框被卸载之前就清掉了
             * imeFieldFocused，所以这个判断为假。正是它把两条路径分了开来。
             *
             * 一次被抢走的焦点和一次用户收起无法区分，现在也按收起处理。这是可恢复的
             * 而不是致命的，也就是它可以接受的原因：这个文本框仍然盖在游戏的文本框上，
             * 所以点一下就能再次唤起键盘，而它所取代的那套「五次连发」可能让它永久
             * 死掉。
             *
             * 清除刻意【不】基于时间。不要求用户在任何时间窗内行动 —— 他们愿意把键盘
             * 放多久都行，点一下仍能把它带回来。
             */
            if (this.imeFieldFocused) {
              this.imeUserHid = true;
            }
            this.imeFieldFocused = false;
          })
          .onSubmit(() => {
            /* [B] 在键盘上按了完成：把输入的控制权交还给游戏。 */
            this.dismissIme();
          })
      }

      /* [A]
       * 悬浮球，以及它打开的菜单。
       *
       * 用球而不是带标签的按钮，有个实际的理由：它必须待在游戏之上，而一个小圆是它
       * 尽可能小的遮盖。角落里一个固定的按钮，要么挡路，要么小到点不中。
       *
       * 点一下是打开菜单而不是直接执行，因为它注定要承载多个功能；操作方案是第一个，
       * 所以这次点击必须表示「给我看看你能做什么」，而不是「做那一件事」。
       *
       * 为什么 focusable(false) —— 这是承重的，不是装饰。ArkUI 只把按键事件投递给
       * 聚焦的组件，而 XComponent 需要那份焦点，否则 SDL 永远看不到按键，键盘就彻底
       * 失效。这个 Stack 里一个可聚焦的球会把它抢走。没有焦点时点击和触摸仍然有效；
       * 被扣下的只是键盘焦点。
       *
       * 画成一个带边框的圆，而不是用 Circle 形状组件，这样标签可以直接放在它里面，
       * 不必再走一次布局。
       */
      Stack() {
        /* [A]
         * 游戏自己的炮塔，而不是一个字模。
         *
         * 试过齿轮并且渲染出来了 —— 但它是一个字体字符，所以它的粗细和齿形取决于设备
         * 恰好提供的哪套字体，而且它读起来像「设置」，可这里其实是一个多功能的菜单。
         *
         * 这就是应用图标所用的同一张 32x32 炮塔，所以球和玩家点进来时点的那个图标是
         * 一致的。它是位图，所以也彻底不再依赖设备的字体。
         *
         * Interpolation.None 是让它不发糊的原因：源图恰好是该 sprite 自身 34px 的整数
         * 倍，而最近邻缩放才是让像素画看起来像画出来的、而不是模糊的原因。
         *
         * draggable(false)：球的拖动由 Stack 的 onTouch 处理。它里面一张可拖动的图片
         * 会启动自己的拖动，跟那个打架。
         */
        Image($r('app.media.ball_icon'))
          .width(Math.round(this.ballSizeVp * 0.62))
          .height(Math.round(this.ballSizeVp * 0.62))
          .interpolation(ImageInterpolation.None)
          .draggable(false)
      }
      .width(this.ballSizeVp)
      .height(this.ballSizeVp)
      .borderRadius(this.ballSizeVp / 2)
      .backgroundColor(this.ballMenu ? '#cc1d2733' : '#99101820')
      .borderWidth(1)
      .borderColor('#66ffffff')
      /* [A]
       * 半隐藏在【这里】，别处没有。ballX/ballY 始终保存着露出的位置，所以拖动、clamp、
       * 吸附和存下的文件全都一致地基于同一套坐标 —— 改成移动 ballX 会让它们每一个都
       * 得去考虑球当前隐藏到什么程度。
       */
      .position({ x: this.ballX + this.ballHideDx(), y: this.ballY + this.ballHideDy() })
      .opacity(this.ballHidden ? BALL_OPACITY_HIDDEN : 1)
      .focusable(false)
      .onTouch((e: TouchEvent) => { this.onBallTouch(e); })

      if (this.ballMenu) {
        Column() {
          /* [A]
           * 条目：回启动器。
           *
           * 为什么它必须有：游戏一旦起来，本应用就没有别的路回到那一屏了 —— 启动器
           * 界面只在 decideStartup() 判定「不启动游戏」时出现，而那个判定每次启动只做
           * 一次。没有这一行，玩家换了 jar 之后想再换一个就只能卸载重装。
           *
           * ⚠️ 它退出应用，不是切界面。理由见 backToLauncher()：这段代码运行时
           * XComponent 已经挂上了，把那棵树从页面上摘掉等于在 native 正在跑的时候拆它
           * 的 surface。所以它走的是和其它退出路径同一个握手：记下意图，交给框架拆。
           */
          Row() {
            Text('启动器')
              .fontSize(BALL_MENU_FONT_VP)
              .fontColor('#eef2f9')
            Blank()
            Text('选择游戏').fontSize(BALL_MENU_HINT_FONT_VP).fontColor('#8fb4ff')
          }
          .width('100%')
          .height(BALL_MENU_ROW_VP)
          .onClick(() => { this.backToLauncher(); })

          Divider()
            .strokeWidth(BALL_MENU_DIVIDER_VP)
            .color('#22ffffff')

          /* [A]
           * 条目：当前生效的是哪套操作方案，以及那个切换开关。
           *
           * 一个真正的选择必须在游戏启动【之前】做出：Mindustry 的整个输入层【和】UI
           * 都派生自一个位 —— Vars.mobile —— 在 Vars.init() 里写一次。它自带的游戏内
           * 开关只改输入处理器，所以会在移动端 UI 上给出桌面控制 —— 在平板上实测过，
           * 并在字节码里确认过。因此需要重启，这一点被明白说出，而不是藏起来。
           */
          Row() {
            Text(this.controlMode === CONTROL_MODE_DESKTOP ? 'PC 模式' : '触屏模式')
              .fontSize(BALL_MENU_FONT_VP)
              .fontColor('#eef2f9')
            Blank()
            Text('切换').fontSize(BALL_MENU_HINT_FONT_VP).fontColor('#8fb4ff')
          }
          .width('100%')
          .height(BALL_MENU_ROW_VP)
          .onClick(() => { this.toggleControlMode(); })

          /* [B]
           * 一条细线，不是一个 margin。
           *
           * 同一张卡片上的两个标签，无论隔多远都会被读成一段文字；分隔线才是说明「这是
           * 两个选择」的东西。它也让纵向跨度变得明显，而那是单靠一个更大的间隙修不好的
           * 那一半问题。
           */
          Divider()
            .strokeWidth(BALL_MENU_DIVIDER_VP)
            .color('#22ffffff')

          /* [A]
           * 这里【曾经】有一行 "导入模组"（选一个文件 → 把它复制进模组目录），它已被
           * 【删除】，是刻意的，和这个应用过去自行往那里放文件的另外两种方式一起。
           *
           * 为什么。这三种方式全都让应用自己决定一个模组何时存在，而玩家无法在游戏内
           * 撤销那个决定。造成伤害的那一种，每次启动都把应用 Downloads 文件夹里的任何
           * 东西复制进模组目录，只跳过已在、且大小相同的文件 —— 于是在游戏里删掉一个
           * 模组（也就是把它从沙箱里删掉）会在下次启动时直接把它带回来，永远如此。那个
           * 文件夹【也】是游戏自带文件浏览器打开的根目录，而存档是 .zip，所以放在那里的
           * 一个存档会被当成模组一样扫进模组目录。
           *
           * ⇒ 现在唯一的入口是【游戏自带的】导入按钮，它按构造就是手动的：玩家挑一个
           *   文件，游戏复制它。它在这里能用（已在设备上确认），不需要我们写任何代码。
           *   Downloads 文件夹仍然会被创建、仍然充当浏览器的根目录 —— 所以丢在那里的一
           *   个模组仍然够得到，只是必须被选中，而不是被自动取走。
           *
           * ⚠️ 行数是推导出来的（BALL_MENU_ROWS），所以删掉一行不是一行的改动：那个常量
           * 喂给 BALL_MENU_H_VP，而 ballMenuY 要拿它做 clamp。
           */

          /* [B]
           * 条目：谁做的、它住在哪、以及它【不是】什么。
           *
           * 一个还没上任何商店的移植版会被人问「在哪下载 / 在哪报 bug / 这是官方的吗」
           * —— 而这些答案需要在应用内部够得到，因为问题冒出来的时候，玩家已经在应用
           * 里了。
           */
          Row() {
            Text('关于')
              .fontSize(BALL_MENU_FONT_VP)
              .fontColor('#eef2f9')
            Blank()
            Text('仓库 / 更新日志').fontSize(BALL_MENU_HINT_FONT_VP).fontColor('#8fb4ff')
          }
          .width('100%')
          .height(BALL_MENU_ROW_VP)
          .onClick(() => { this.openAbout(); })

          Divider()
            .strokeWidth(BALL_MENU_DIVIDER_VP)
            .color('#22ffffff')

          /* [A]
           * 一键求助。
           *
           * 应用本来就自己导出崩溃报告，但只在【有】崩溃时 —— 而最难处理的情况恰恰
           * 根本没有崩溃（「它起不来」「它行为异常」）。在 release 签名的安装上，应用
           * 之外的任何东西都读不了沙箱，所以没有这个按钮，「把日志发给我」的回答就是
           * 「拿不到」。
           *
           * 它写到应用的 Downloads 文件夹 —— 玩家本来就知道去那里找，因为模组去的是
           * 同一个地方。
           */
          Row() {
            Text('导出诊断')
              .fontSize(BALL_MENU_FONT_VP)
              .fontColor('#eef2f9')
            Blank()
            Text('日志').fontSize(BALL_MENU_HINT_FONT_VP).fontColor('#8fb4ff')
          }
          .width('100%')
          .height(BALL_MENU_ROW_VP)
          .onClick(() => { this.exportDiagnostics(); })
        }
        .width(BALL_MENU_W_VP)
        .padding({ left: 14, right: 14, top: 8, bottom: 8 })
        .backgroundColor('#e6161c26')
        .borderRadius(10)
        .borderWidth(1)
        .borderColor('#44ffffff')
        .position({ x: this.ballMenuX(), y: this.ballMenuY() })
        .focusable(false)
      }
    /* [A]
     * About 卡片 —— 一个 Stack 子节点，盖住一切，包括悬浮球，否则球会浮在它上面。
     *
     * 任何地方都【没有可聚焦组件】。对话框或 Button 会从 XComponent 那里夺走焦点，
     * 游戏然后就看不到键盘了。所以这张卡片不可聚焦，里面也不放任何可聚焦的东西；变暗
     * 的区域本身就是关闭按钮。
     *
     * （曾经有一个兼容性提示也坐在这里，用同样的方式构建。它已经没了 —— 见文件头注释
     * —— 所以现在这是唯一一个这类覆盖层。）
     *
     * 那些地址是纯 Text 而不是链接，这就是那条规则的代价：要让它们可点，要么需要一个
     * 可聚焦组件，要么需要剪贴板权限，而两者都不值得为它搞坏键盘。想要仓库地址的人可以
     * 从卡片上把它抄下来。
     */
    if (this.showAbout) {
      Column() {
        Column() {
          Text('Mindustry Ark')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(Color.White)
          Text(this.appVersion === '' ? ' ' : ('版本 ' + this.appVersion))
            .fontSize(13)
            .fontColor('#A0FFFFFF')
            .margin({ top: 4 })
          Text('在 HarmonyOS / OpenHarmony 上运行 Mindustry')
            .fontSize(13)
            .fontColor('#E0FFFFFF')
            .margin({ top: 12 })

          Text('仓库')
            .fontSize(12)
            .fontColor('#8fb4ff')
            .margin({ top: 16 })
          /* [A]
           * 带上协议头，因为没有它，光秃秃的 "github.com/..." 读起来像一条路径或一个包
           * 名，而不是一个网址。设备上报过 —— 它看起来怪 —— 确实怪。
           *
           * 这两行是卡片上最长的文字，而 Issues 那行有 47 个字符。这就是它们被排得比正文
           * 小的原因：用正文字号，最长的那一行在手机上放不进卡片，会在地址中间折行，那比
           * 字号小更糟。
           */
          Text('https://github.com/haohandc/MindustryArk')
            .fontSize(12)
            .fontColor('#E0FFFFFF')

          Text('问题反馈 / 联系方式')
            .fontSize(12)
            .fontColor('#8fb4ff')
            .margin({ top: 12 })
          Text('https://github.com/haohandc/MindustryArk/issues')
            .fontSize(12)
            .fontColor('#E0FFFFFF')

          Text('更新日志')
            .fontSize(12)
            .fontColor('#8fb4ff')
            .margin({ top: 12 })
          Text('见仓库 RELEASE.md 的「版本历史」')
            .fontSize(13)
            .fontColor('#E0FFFFFF')

          Text('非官方项目。与 Mindustry 及其作者 Anuken 无隶属关系，未获其认可或支持。以 GPL-3.0 分发。')
            .fontSize(12)
            .fontColor('#A0FFFFFF')
            .margin({ top: 16 })

          Text('轻触任意处关闭')
            .fontSize(12)
            .fontColor('#80FFFFFF')
            .margin({ top: 16 })
        }
        /* [A] 92% 和 18，而不是 86% 和 22：那两个地址是这里最宽的文字，而这就是给它们
         * 一条能放下的行宽。对着手机的窗口宽度实测过 —— 见上面关于地址行的说明。 */
        .padding(18)
        .backgroundColor('#F01C1C1C')
        .borderRadius(14)
        .width('92%')
      }
        .width('100%')
        .height('100%')
        .backgroundColor('#B0000000')
        .justifyContent(FlexAlign.Center)
        .focusable(false)
        .onClick(() => { this.showAbout = false; })
      }
      if (this.shieldBlocked) {
        Column() {
          Column() {
            Text('无法启动').fontSize(22).fontColor('#FFFFFF')
            Text('本机当前开启了「坚盾守护模式」，系统不允许应用申请可执行内存，游戏所需的 Java 虚拟机无法创建。')
              .fontSize(15).fontColor('#E0FFFFFF').margin({ top: 14 })
            Text('请关闭该模式后重新打开应用。关闭路径：设置 → 隐私和安全 → 坚盾守护模式。')
              .fontSize(13).fontColor('#A0FFFFFF').margin({ top: 10 })
            Text('点击任意位置退出')
              .fontSize(13).fontColor('#A0FFFFFF').margin({ top: 10 })
          }
          .padding(20).backgroundColor('#F01C1C1C').borderRadius(14).width('90%')
        }
        .width('100%').height('100%').backgroundColor('#B0000000')
        .justifyContent(FlexAlign.Center).focusable(false)
        .onClick(() => {
          const ctx = getContext(this) as common.UIAbilityContext;
          ctx.terminateSelf().catch((err: BusinessError) => {
            hilog.error(DOMAIN, TAG, 'terminateSelf failed: %{public}s', err.message);
          });
        })
      }
      /* ⛔ 这里【曾经】是「上次启动未完成」的提示层。
       *
       * 2026-10-01 撤掉：它长在**游戏树**里，而游戏树正是失败之后不该来的地方 ——
       * 玩家在这里唯一能做的动作是「点击任意位置继续启动」，也就是把同一次失败再试一遍。
       *
       * ⇒ 同样的信息现在由启动器界面上的弹窗负责（LauncherHome 的 launchFault），
       *   而 decideStartup() 里新增的那条规则会把失败后的启动送回启动器。
       *   ⚠️ 两处都改才算完成：只删这里，玩家会进游戏树且看不到失败提示。 */
    }
    /* [A] ↑ 这一行关的是「游戏树」那个 else 分支。下面这一行关 Stack ——
     * 两行本来是同一个括号，这里只是把它拆成了两个。 */
    }
    /* [B] 这个修饰符唯一的任务就是学到窗口尺寸，一次，好让球能对着正确的矩形摆放和
     * clamp。 */

    .onAreaChange((_o: Area, n: Area) => {
      this.onWindowSize(Number(n.width), Number(n.height));
    })
    /* [A]
     * ESC，放在 Stack 上：游戏表面和我们文本框的共同祖先，因此是这两者无论哪一个聚焦
     * 都能看到这个键的唯一节点。
     *
     * 焦点是单一的，这正是下面【两个】钩子都存在的原因：
     *
     *   文本框聚焦    -> Column 不在焦点链上，所以它的处理器永远不会运行，键必须在
     *                    这里接住
     *   游戏聚焦      -> Column 【在】链上，它的处理器就够用了
     *
     * onKeyPreIme 必须排在前面，因为实测祖先上的 onKeyEvent 在 TextInput 持有焦点时
     * 【不】触发 —— 文本框在祖先看到它之前就把键消费了。所以下面的 onKeyEvent 是后备，
     * 不是主选。
     *
     * 【只在】我们的文本框弹起时消费。在游戏聚焦时消费它，就是曾让 SDL 对 ESC 什么
     * 都看不到的原因 —— XComponent 的原生回调在这个钩子【之后】运行 —— 而这花了一轮
     * 才找到。那种情况下返回 false 就能让它原样通过。
     *
     * 消费做了什么：把 ESC 转发进游戏（于是游戏关掉它自己的对话框，那才是真正释放
     * 文本框、停止请求的动作），并在本地锁存这次收起，好让下一次轮询无法把它撤销。
     *
     * 返回 true 与转发是两回事：它是阻止 HarmonyOS 把 ESC 当作返回、把应用丢回桌面的
     * 东西。
     */
    .onKeyPreIme((e: KeyEvent) => {
      const esc: boolean = e.keyCode === KeyCode.KEYCODE_ESCAPE;
      /* [A] 无条件记录日志。一个祖先的 onKeyPreIme 在后代 TextInput 持有焦点时是否
       * 触发，正是这个修复所依赖的前提，而它并不显然 —— 所以万一 ESC 再次出问题，
       * 这些行会说明那个前提是否成立，而不是让这次失败含糊不清。 */
      hilog.info(DOMAIN, TAG, 'onKeyPreIme[Stack]: keyCode=%{public}d showIme=%{public}s -> consumed=%{public}s',
        e.keyCode, String(this.showIme), String(esc && this.showIme));
      if (esc && this.showIme) {
        this.appendCmd('E' + '\n');
        this.dismissIme();
        return true;
      }
      return false;
    })
    .onKeyEvent((e: KeyEvent) => {
      const esc: boolean = e.keyCode === KeyCode.KEYCODE_ESCAPE;
      if (esc && this.showIme) {
        /* [B] 和上面那个钩子同样的动作，留作一张网，用于键从一条跳过 onKeyPreIme 的
         * 路径到达的情况。两种情况下都返回 true，因为 HarmonyOS 绝不能把 ESC 当作
         * 返回。 */
        this.appendCmd('E' + '\n');
        this.dismissIme();
        return true;
      }
      return esc;
    })
  }
}
