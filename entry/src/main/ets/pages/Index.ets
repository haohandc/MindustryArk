import { abilityAccessCtrl, bundleManager, common, Permissions } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { KeyCode } from '@kit.InputKit';
import { window } from '@kit.ArkUI';
import { ensureModFolder, modFolderPath } from '../mods/ModImporter';
/* 应用自己的显示名 —— 与启动器那些页面同一处规则，⛔ 别在这里写死。 */
import { appLabel } from '../utils/AppLabel';
/* 入场动画（退场刻意不做 —— 见那个文件的开头）。 */
import { enterFade } from '../utils/Motion';
/* 导出它，是为了让本页在那个文件夹真正存在之后再写一次桥接文件。见调用处。 */
import { writeUserDirs } from '../entryability/EntryAbility';
/* 崩溃在 ability 的 onCreate 捕获（必须赶在原生代码 unlink 之前），在这里发布 ——
 * 这是第一个能确定 Download 文件夹已存在的时刻。 */
import { publish as publishCrash, exportNow as exportDiagnosticsNow,
         readStartupLogTail } from '../diagnostics/ExportDiagnostics';
/* 「加载哪一个游戏」的全部知识都在那里，本页只问一次并照着做。见 decideStartup()。 */
import { consumeLauncherRequest, requestLauncher, resolveGame, reportGameResolution,
         markLaunchAttempt, pendingLaunchAttempt, clearLaunchAttempt,
         GameResolution, bundledGamePath } from '../games/GameLibrary';
/* 启动后进哪里 —— 设置页那开关写盘，这里读。 */
import { readLaunchMode, LAUNCH_MODE_HOME } from '../settings/LauncherPrefs';
/* 版本隔离：在真正要启动的那一刻把结论写给 native。⛔ 不能只靠 EntryAbility.onCreate
 * 那一次 —— 默认「先显示启动器」，玩家会在那之后再改选 jar。见 startGame。 */
import { computeKey, readGranularity, writeIsolationBridge } from '../settings/Isolation';
/* 没有游戏可加载时显示的那一屏。它是替换 XComponent，不是盖在它上面 ——
 * 这个区别决定了两边能用什么控件，见那个文件开头。 */
import { LauncherHome } from './LauncherHome';
/* `focusControl` 无需 import：它是 ArkTS 全局变量。从 @kit.ArkUI 导入它编译不过。 */
import shield from 'libshield.so'; // 坚盾

const DOMAIN = 0x0000;
const TAG = 'MindustryLauncher';

/* 兼容模式：本次安装没被授予匿名可执行内存时追加 -Xint。
 * ⚠️ 实测 2026-09-22：这【救不了】那样的设备 —— 解释器仍需要可执行内存（HotSpot 在考虑
 *   字节码执行之前就要建启动 stub），进程在 JNI_CreateJavaVM 里直接消失。
 * ⇒ 所以应用商店里没有手机包；手机改用自签名构建。该能力由启动器每次启动时探测。 */
const JVM_OPTIONS_FILE_NAME = 'jvm.options';

/* 启动器在哪里记录 JVM 是否真的拿到了可执行内存（内容是 "interp" 或 "jit"）。
 * 用绝对字面量：这是原生侧写的【应用级】目录，而 context.filesDir 是【模块级】的，
 * 两者不能互换。理由同下面的 IME 桥接。 */
const EXEC_MEMORY_FILE = '/data/storage/el2/base/files/execmem';
const JVM_INCOMPLETE_FILE = '/data/storage/el2/base/files/jvm_incomplete';

/* 失败弹窗里日志尾巴的上限字节。不是导出诊断 —— 那个是「导出诊断」菜单的事（128 KB）。 */
const FAULT_LOG_BYTES = 1200;
/* 那次失败启动自己的日志。必须尽早读：launcher.c 在 main() 启动时以 O_TRUNC 打开它，
 * 而 main() 在 XComponent 挂载时才跑 —— 所以更早的 aboutToAppear 是「上次日志仍在」
 * 的唯一窗口。同 EntryAbility 的 stashIfAny()。 */
const STDERR_LOG_FILE = '/data/storage/el2/base/files/stderr.log';
/** 启动器上一次启动测到的结果；还没表态时是 ''。
 * '' 意为「没有测量」（全新安装或没写成），调用方会退回自己的猜测。
 * ⚠️ 它【不】意味着「JIT 能用」—— 把文件不存在当成好消息正是起不来的设备收不到提示的原因。 */
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
/** 上一次启动日志里第一行含 `needle` 的内容，没有就返回 ''。
 * 死在 JNI_CreateJavaVM 里的启动没有别的记录：不返回错误码、不写 faultlog，
 * 所以这里逐字引回启动器自己的话。⚠️ needle 必须够具体：光写 'errno=' 会匹配到
 * 无害的 "Download NOT READABLE errno=1"，报出错误的失败。 */
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
    /* 读不到就当作「没有这一行」—— 调用方只在它非空时才用 */
  }
  return '';
}
/* 低于这个 API level，本项目过去假设 JIT 不可用。
 * ⚠️ 这是猜测不是阈值：它来自一台 API 24 的手机，而设备类别从没和版本区分开。
 * 能留着，是因为启动器的测量会在下次启动纠正它，且猜错的代价只是首启变慢。 */
const MIN_API_FOR_JIT = 26;
/* 在所有设备上强制兼容模式。它的存在是为了【测量】，不是为了发布 ——
 * 想感受 -Xint 的变慢，唯一的办法是在不需要这个退路的硬件上跑它。
 * ⚠️ 任何要发布的构建里它都必须是 false。 */
const FORCE_COMPAT_MODE = false;

/** 现在应用不再申请任何运行时权限，列表为空（空时 requestPerms 整个跳过那次调用）。
 * 2026-09-22 移除 READ_WRITE_DOWNLOAD_DIRECTORY：该 API 文档写明仅 2in1 设备，手机无论权限
 * 状态都抛 "The device doesn't support this api"（实测时权限是手工加上的，所以授权不是变量）。
 * ⚠️ 移除的是权限不是调用：ModImporter 仍调 getUserDownloadDir() 作 route A（平板靠它报路径），
 * 真正干活的是不需要权限的 DocumentPickerMode.DOWNLOAD。
 * 实测同一 HAP 同一签名：tablet reqPermissionStates [0,0] / phone [0,-1]。 */
const WANTED: Permissions[] = [
];

async function requestPerms(ctx: common.UIAbilityContext): Promise<void> {
  /* 没什么可申请的就没什么可做的：截至 2026-09-22 这个列表是空的（见 WANTED）。
   * 这是正常路径不是边角情况 —— requestPermissionsFromUser() 拿空数组会怎样没有文档，
   * 但这次调用被跳过了，所以那个问题不会出现。 */
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
    /* 把四个字段全打出来，不只那两个显而易见的：这个循环过去只打 permissions/authResults，
     * 于是「权限弹窗不再出现」要花一整个会话来解释 —— 回答它的正是 dialogShownResults 和 errorReasons
     * （字段含义见 security/PermissionRequestResult.d.ts）。
     * 实测（HarmonyOS 7 手机）：READ_WRITE_DOWNLOAD_DIRECTORY 的 auth=2 dialogShown=true errorReason=0。 */
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
        /* 报出来是 2 —— 但这里【不要】叙述原因。第一个版本说「判为无效请求所以不弹」，是从 SDK
         * 那句推出来的；实测元组 auth=2 dialogShown=true errorReason=0 反驳了它（0 意为 "this request
         * is valid"），且整次调用约 170ms 就返回，快到不可能有人回答对话框。三个字段凑不成故事，
         * 只记录结果：未授予，玩家看不到弹窗。 */
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

/** 不再申请任何运行时权限（更早申请的 READ_WRITE_DOWNLOAD_DIRECTORY 已删）。
 * 当初要它是为了把 JDK 放在用户 Download 区，该计划已放弃（JDK 随 HAP 打包并复制进沙箱），
 * 实测拒绝它对游戏运行毫无影响。⚠️ 唯一想要用户可见目录的是 Arc 的
 * libarc-filedialogsarm64.so —— 它在这里加载不了（tinyfiledialogs / glibc）；不是本平台自带的那个选择器。 */

/* 原生侧在哪里找这些文件。刻意用字面路径：ArkTS 的 context.filesDir 是 HAP 级目录，
 * 不是原生代码共享的那个应用级目录，写错地方的文件永远不会被看到。 */
const IME_WANT_FILE = '/data/storage/el2/base/files/ime_want';
const IME_CMD_FILE = '/data/storage/el2/base/files/ime_cmd';
/* 游戏的文本框在哪，格式 "x y w h"，单位游戏像素。
 * 用它把隐形文本框盖到它上面，好让框架的键盘避让把页面移动恰好足够的距离 ——
 * 借助框架是关键：它本来就知道怎么让聚焦的文本框保持在键盘上方可见。 */
const IME_RECT_FILE = '/data/storage/el2/base/files/ime_rect';

/* 这里【曾经】有 MODS_DIR，已随它唯一的用户消失 —— 本文件再没有东西写游戏的模组目录。
 * 备忘：user.home→DEST_ROOT，Arc 拼 "<user.home>/.local/share/Mindustry/"，mods 在其下，
 * 设备上是 /data/storage/el2/base/files/.local/share/Mindustry/mods —— 用绝对字面量的理由同上。 */

/* seedProbeMod() 和它的两个常量曾在这里，【已删除】—— 理由同删掉那行菜单、那次文件夹扫描：
 * 那次复制每次都【无条件】执行，开发者手删 probe-mod.jar 后下次启动又被放回去，
 * 和文件夹扫描复活的模组一模一样。⚠️ tools/probe-mod/ 仍在仓库里、仍能构建；
 * 消失的是自动种入，所以设备上遗留的 probe-mod.jar 被删掉后会保持被删。 */

/* 玩家选了哪套操作方案，由启动器在 JVM 启动前读取。刻意写在 user_dirs.txt 旁边：
 * 两者都写进 filesDir（HAP 级目录），【不是】上面 IME 桥接用的应用级目录 ——
 * 两者长得像但不能互换，写错的文件永远不会被看到，而且哪儿都不报错。 */
const CONTROL_MODE_FILE_NAME = 'control_mode.txt';
const CONTROL_MODE_MOBILE = 'mobile';
const CONTROL_MODE_DESKTOP = 'desktop';

/* 悬浮球：承载多个功能，操作方案是第一个，所以点一下是打开菜单而不是执行动作。
 * 所有尺寸都是 vp；触摸坐标也是 vp（TouchObject.windowX/Y），也正是 .position() 的单位，
 * 所以这里无需 px2vp 转换 —— 唯一需要转换的是屏幕尺寸，平台以 px 上报。 */
/* 球的大小从窗口短边推导，不是固定值：固定的 44vp 在这台平板上实测太小，
 * 而保留为【短边比例】可让横屏不产出比竖屏更宽的球。
 * 下限 48 而不是旧的 44（44 就是被发现太小的那个值）；上限阻止大屏产出盖住游戏的球。 */
const BALL_SIZE_FALLBACK_VP = 48;   /* 在 onAreaChange 上报任何数据之前 */
const BALL_SIZE_RATIO = 0.065;      /* 窗口短边的比例 */
const BALL_SIZE_MIN_VP = 48;
const BALL_SIZE_MAX_VP = 76;
/* 球停靠时离边留多远。四条边、每条会安置球的路径（首次摆放/拖动/从磁盘恢复）都适用 ——
 * 它曾经只在首次摆放时被用到，结果拖动过的球贴边相切，没碰过的球却保留着间隙。 */
const BALL_MARGIN_VP = 8;
/* 触摸移动多远才算拖动而非点按。没有它，点按时最轻微的移动都会被读成拖动。 */
const BALL_DRAG_SLOP_VP = 8;
const BALL_MENU_W_VP = 176;
/* 一行的高度。这些行过去是裸 Row + fontSize 14 的 Text，点击目标只有约 19vp，
 * 设备上报「选项太小、也挨得太近」。现在行带显式高度、文本居中，点击目标是整行。
 * 46 矫枉过正，设备上报间隙应减半 ⇒ 32 让文本保持 16vp、上下留白减半。
 * BALL_MENU_H_VP 由它推导，因为 ballMenuY 要拿它做 clamp。 */
const BALL_MENU_ROW_VP = 32;
const BALL_MENU_DIVIDER_VP = 1;
const BALL_MENU_PAD_VP = 16;
/* 菜单行数。要和 build() 里的 Row 数量保持一致 —— BALL_MENU_H_VP 由它推导，
 * 而对不上时会保留一段不绘制任何东西的高度，菜单看起来只是「矮了一截」。 */
const BALL_MENU_ROWS = 4;   /* 2026-10-01 加了「启动器」那一行，3 -> 4 */
const BALL_MENU_H_VP = BALL_MENU_ROWS * BALL_MENU_ROW_VP
                     + (BALL_MENU_ROWS - 1) * BALL_MENU_DIVIDER_VP
                     + BALL_MENU_PAD_VP;
const BALL_MENU_FONT_VP = 16;
const BALL_MENU_HINT_FONT_VP = 14;

/* 自动半隐藏：球贴上边后再滑出这么多，只剩外侧 40% 留在屏幕上并降低透明度。
 * 0.6 在这台平板的密度下，约 66vp 的球仍有约 26vp 可见。
 * 那条窄边就是全部目标区 —— 把球弄回来的点击只需落在那条窄边上，不必瞄准。
 * 调大它就隐藏得更多；它就是那个旋钮。 */
const BALL_HIDE_MS = 3000;
const BALL_HIDE_FRACTION = 0.6;
const BALL_OPACITY_HIDDEN = 0.45;

/* 球上次停在哪。一行 "x,y"，绝对 vp。用绝对值而不是「哪条边+比例」，是因为恢复时会被
 * clamp 进当前窗口，所以「窗口尺寸变了」这个常见情况会自己纠正，无需额外存东西。
 * 它和 control_mode.txt 一起放在模块 filesDir 里，【不是】IME 桥接所用的应用级目录。 */
const BALL_POS_FILE_NAME = 'ball_pos.txt';

/* 用户收起键盘后忽略游戏请求的时长：长到让转发出去的 ESC 抵达游戏并让它关掉对话框
 * （到那时请求会自行停止），短到不会把任何人困住。 */
const IME_DISMISS_MS = 1500;

/* 给隐形文本框额外增加的高度，只在键盘弹起时：框架只会把页面上推到聚焦文本框可见为止，
 * 所以这是避免游戏文本框紧贴键盘上边缘的唯一杠杆。margin 向下长，也盖住游戏画在文本框
 * 下方的东西（导出对话框上是 Cancel）—— 要够到它得先移开焦点。
 * ⚠️ 改成向上是错的：下边缘会落在 fieldY + fieldH（`y = fieldY - 24` + `h = fieldH + 24`），
 * 页面少推 24vp，键盘盖住 Cancel 和 Enter ⇒ 只在用户收起键盘时才去掉这个外伸。 */
const IME_FIELD_MARGIN_VP = 24;

@Entry
@Component
struct Index {
  @State showIme: boolean = false;
  /* 游戏文本框被认为装着的内容。原生侧通过 SDL_SendKeyboardText 喂这个副本，
   * 所以两者一起从空开始，且只会随下面发送的内容变化。 */
  private imeSent: string = '';
  private imeTimer: number = -1;
  private imeFieldFocused: boolean = false;
  /* 用户把键盘收起来了，它必须一直收着直到用户再次要求 —— 尽管游戏全程都还想要文本。
   * `ime_want` 回答不了：它报告的是游戏想要什么，而游戏永远不会知道用户把键盘藏了
   * （它自己的文本框仍聚焦，SDL 从不调 HideScreenKeyboard）。 */
  @State imeUserHid: boolean = false;
  /* 忽略游戏请求的截止时间（用户刚把键盘收起来了）。⚠️ 是【截止时间】不是锁存器：
   * 游戏的对话框只要还开着就一直在要，不会发出能清除锁存器的新请求，所以锁存器会把
   * 一个 ESC 没能关掉对话框的用户困死 —— 截止时间则总会把键盘放回来。 */
  private imeDismissedUntil: number = 0;
  /* 游戏的文本框。值已经是 vp（.position() 接受的单位），在读取时转换一次就能让
   * 渲染路径不含算术。 */
  @State imeFieldX: number = 0;
  @State imeFieldY: number = 0;
  @State imeFieldW: number = 1;
  @State imeFieldH: number = 1;
  /* 持有它，以便页面销毁时能移除 avoid-area 监听。 */
  private imeWindow: window.Window | undefined = undefined;
  /* 这一页已经销毁了吗 —— ⛔ **只由 `aboutToDisappear` 置真**，用来给「先 await、后注册」
   * 的那条异步路径（`watchKeyboardHeight`）一个判据。见那里与 `aboutToDisappear` 的说明。 */
  private pageGone: boolean = false;
  /* 当前记录在磁盘上的操作方案。显示在开关上，因为改动要到下次启动才生效。 */
  @State controlMode: string = CONTROL_MODE_MOBILE;
  /* 球在哪，以及它的菜单是否打开。ballPlaced：窗口尺寸已知之前球无法定位（它从右边缘开始，
   * 而在 onAreaChange 上报宽度之前那会把它放到 x=0）。摆放只发生一次，之后玩家的位置不被覆盖。 */
  @State ballX: number = 0;
  @State ballY: number = 0;
  @State ballPlaced: boolean = false;
  @State ballMenu: boolean = false;

  /* About 覆盖层。版本号从【包】里读而不是写在这里：本项目已被一个手工抄写的版本号
   * 坑过一次（build-profile.json5 的 artifactName），再来一份副本会同样漂移。 */
  @State showAbout: boolean = false;

  /* 这一屏显示【游戏】还是【启动器】。在 aboutToAppear 里由 decideStartup() 设一次，
   * 之后只有两处改它：启动器点「启动游戏」(->false)、悬浮球菜单点「启动器」(走退出握手)。
   * ⚠️ 它是一道【门】，所以必须有出口：启动器空状态里的「仍然尝试启动」（判定失误的逃生门），
   * 以及悬浮球菜单里的「启动器」（进了游戏还能回来）。 */
  @State showLauncher: boolean = false;

  /* 启动器界面注册进来的「返回一层」处理器。⛔ 默认 false —— 没注册时（启动器还没渲染过）
   * 就照旧走下面那条 ESC。 */
  private launcherBack: () => boolean = () => false;

  /* Download 文件夹【确认可用】后翻成 true，传给启动器界面。⚠️ 需要它：文件夹在
   * aboutToAppear 里异步创建（mkdir 或 picker 都要等），而启动器界面的 aboutToAppear
   * 紧接着同步跑 —— 2026-10-01 MatePad Pro 实测：第一次读不到状态文件 ⇒ 不阻塞地通知
   * 「好了」，启动器再读一遍。刻意不在这里等：picker 可能一直不返回，界面就永远不出来。 */
  @State folderSettled: boolean = false;

  /* 传给启动器界面的两个路径。从 context 取一次，因为那是页面才拿得到的东西。 */
  private launcherFilesDir: string = '';
  private launcherBundleDir: string = '';

  /** 设置一次，在 XComponent 存在之前：见 aboutToAppear。 */
  @State shieldBlocked: boolean = false;
  /* Kit 的原始答案：'on' / 'off' / 'no-lib: ...' / 'no-sym: ...' / 'mode=N'。
   * ⛔ **不是 `@State`**（2026-10-05 改的）：它在 `aboutToAppear` 里被写、被读（用来算
   *    `shieldBlocked` 与那行日志），但**从来没有在 `build()` 里被读过** ⇒ 那个 `@State`
   *    只买到「每次赋值都把这一页标脏」，一次重绘都不产出。同 `jvmFaults`。
   * ⚠️ `shieldBlocked` **保留 `@State`** —— 它真的在 `build()` 里决定挂不挂 XComponent。 */
  private shieldDiag: string = '';
  /* 上一次启动的临终遗言，在它的日志还存在时捕获。
   * ⛔⛔ **同样不是 `@State`，而且它当前【没有任何读者】**（2026-10-05 记下来的）。
   *    这里如实写出来，而不是留一个看起来在用的字段：
   *    · 它捕获的那几行（`mmap(RWX) FAILED` / `FORCING -Xint` / `calling JNI_CreateJavaVM`
   *      / `execmem:` / `shield now:`）**全部来自 `stderr.log` 的尾部**；
   *    · 而「导出诊断」已经把 `stderr.log` / `stdout.log` 各 128 KB **原样收进报告**
   *      （`ExportDiagnostics`）⇒ 这几行的信息**已经在玩家能拿到的那个文件里**了。
   *    ⭐ 所以它现在是**重复采集**：删掉它不会少任何信息，留着也不会多给。
   *    ⛔ 但我**没有删**：它是「在标记被清除之前、原生 main() 截断日志之前」抢下来的那一份，
   *      窗口只有那一下，而删掉它要重新论证「那条窗口真的没有价值」—— 那不是这一轮该做的事。
   *    ⇒ 保留、标清楚，等哪天有人要动这里时再决定。 */
  private jvmFaults: string = '';
  /** 启动器留下了「JVM 正在创建」的标记。 */
  @State jvmIncomplete: boolean = false;

  /* 交给启动器界面显示的「上次为什么没起来」，'' 表示没失败。⚠️ 在 decideStartup() 里
   * 【组装一次】而不是 build 里现算：它要读 stderr.log 的尾巴，而 build() 会被调用很多次。 */
  @State launchFault: string = '';

  /** 上一次尝试启动的那个 jar 的路径；判不出来时是 ''。 */
  @State launchFaultJar: string = '';

  @State appVersion: string = '';
  /* 应用自己的显示名，来自资源。打开 About 时读一次 —— 与版本号同一个时机、同一个理由。
   * ⚠️ 名字叫 `appName` 而不是 `appLabel`：后者是 `utils/AppLabel` 导入的【函数】名，
   * 同一个标识符既是成员又是导入函数，读代码的人（和我）都会看错。 */
  @State appName: string = '';

  /* 这里【曾经】有兼容性提示的状态，已随那个提示一起删掉；原文见 RELEASE-MAINTENANCE.md 2.13b。 */
  /* 球的直径，从窗口重新计算。用 @State 而不是 getter：由 winW/winH 推导的普通字段会变，
   * 而组件永远不会被通知重新渲染。 */
  @State ballSizeVp: number = BALL_SIZE_FALLBACK_VP;
  /* 球当前是否滑出到了边缘之外。这【只】是渲染期偏移量 —— ballX/ballY 始终保存露出的位置，
   * 所以拖动、clamp、吸附、持久化都继续基于同一套坐标。改成移动 ballX 会让它们每一个
   * 都得重新弄清球「真正」在哪。 */
  @State ballHidden: boolean = false;
  /* 它上次吸附到哪条边，好让隐藏朝正确的方向滑。 */
  private ballEdge: string = 'right';
  private ballHideTimer: number = -1;
  /* 从磁盘读到的位置，留到窗口尺寸已知。不能在读取时应用：它需要对着窗口做 clamp，
   * 而 onAreaChange 还没上报过。-1 表示什么都没存。 */
  private ballRestoreX: number = -1;
  private ballRestoreY: number = -1;
  /* 按下那一刻球是否是半隐藏的。见 onBallTouch。 */
  private ballWasHiddenOnDown: boolean = false;
  private winW: number = 0;
  private winH: number = 0;
  /* 拖动的锚点：触摸开始时球和手指的位置，这样球不会跳到手指底下居中。 */
  private dragBallX: number = 0;
  private dragBallY: number = 0;
  private dragTouchX: number = 0;
  private dragTouchY: number = 0;
  private dragMoved: boolean = false;

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    /* 应用名在这里读，**不是**打开 About 时才读：`appLabel()` 只是一次同步的资源查表，
     * 而下面 publishCrash() 在启动阶段就要用它（崩溃报告的抬头），那时 About 还没被打开过。
     * ⚠️ 版本号不同 —— 那个要发一次异步包查询，所以仍留在 openAbout() 里按需读。
     * 拿不到就留空串，各处调用点自己兜底。 */
    this.appName = appLabel(ctx);
    /* 权限请求走的是普通窗口，所以沉浸式切换【串】在它后面而不是并行：requestPerms() 是异步的，
     * 首条语句 await getBundleInfoForSelf()，下面的一切都在那次 await 期间运行 —— 而系统权限
     * 对话框属于普通窗口，不属于刚变成全屏、没有栏的窗口。
     * ⚠️ 这是【预防措施】不是【诊断】：它当初的说法已被下次启动否证（顺序变、结果没变），
     * 保留是因为顺序本身是对的。 */
    requestPerms(ctx).then(() => {
      this.enterImmersive();
    }).catch((e: BusinessError) => {
      /* requestPerms 有自己的 try/catch，本不该 reject；万一真 reject，系统栏仍然必须走掉。 */
      hilog.warn(DOMAIN, TAG,
                 'permissions: unexpected rejection (%{public}s); immersive anyway',
                 e.message);
      this.enterImmersive();
    });
    /* 应用在 Downloads 里的文件夹在这里创建，不是在 ability 里：这里才有 UI 窗口 —— 实测同一个
     * DOWNLOAD 模式调用从菜单点击能成功、从 EntryAbility.onCreate 报 13900042。每次启动都检查
     * 并重建。⚠️ 用途已变而函数名没跟上（磁盘上仍叫 ensureModFolder / mod_folder）：它过去是暂存区
     * （内容每次启动被扫进模组目录），现在纯粹是游戏自带文件浏览器打开的目录。 */
    ensureModFolder(ctx, ctx.filesDir + '/mod_folder')
      .then(() => {
        /* 桥接文件在这里【再写一次】—— 这是「文件浏览器打开在错误位置」的修复。
         * writeUserDirs 在 ability 的 onCreate 里跑，早于这里的文件夹创建，所以首次装机启动时
         * 桥接文件没有 `mods=` 那行，启动器退回普通的 Download 目录（实测 "download NOT READABLE
         * errno=1"），浏览器打开在一片虚无上。抢在启动器读取之前写完即修复；抢不到也无害。 */
        writeUserDirs(ctx.filesDir);
        /* 崩溃报告导出的后半段。崩溃本身在 ability 的 onCreate 里捕获（必须赶在原生 unlink 之前），
         * 但那时无法写入 Downloads（手机要靠 DOWNLOAD 模式 picker 的授权，而 picker 需要窗口）。
         * 所以：尽早捕获，等文件夹确认可用后再发布；发布幂等，没有崩溃时什么都不做。 */
        publishCrash(modFolderPath(ctx.filesDir + '/mod_folder'), ctx.filesDir, this.appName);
        /* 文件夹这件事到此为止，通知启动器界面可以读。⚠️ 放在这个 .then() 的最末尾而不是开头：
         * 它读的是上面 writeUserDirs 刚写的桥接文件。⚠️ 这里不判断 showLauncher —— 界面可能还没
         * 创建（用初值 true）、也可能已在屏幕上（触发 @Watch 重读），两种情况都对。 */
        this.folderSettled = true;
      })
      .catch((e: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'mod folder setup failed: %{public}s', e.message);
      });
    this.clearStaleImeState();
    /* 用轮询而不是等通知：请求来自另一份 libSDL3.so 里的原生代码，它无法调进本页；
     * 文件是两者唯一的共用通道（同退出握手的机制）。 */
    this.imeTimer = setInterval(() => { this.pollImeWant(); }, 200);
    this.watchKeyboardHeight();
    this.readControlMode();
    /* 只是持有，不应用：这个值需要窗口尺寸做 clamp，而 onAreaChange 还没上报过。 */
    this.readBallPos();



    /* 【无条件】记录日志，包括答案是 "off" 的时候：上一个版本只在坚盾开启时才记，
     * 这让「闸门没触发」和「库加载失败/符号不存在/方法没运行」无法区分。 */
    try {
      this.shieldDiag = shield.shieldDiagnosis();
    } catch (e) {
      const err = e as BusinessError;
      this.shieldDiag = 'call-failed: ' + err.message;
    }
    this.shieldBlocked = (this.shieldDiag === 'on');
    hilog.info(DOMAIN, TAG, 'shield diagnosis: %{public}s -> blocked=%{public}s',
      this.shieldDiag, String(this.shieldBlocked));

    /* 标记还在这里，意味着上一次启动停在了 JVM 创建内部 —— 唯一一种不留日志、不留 faultlog、
     * 也没有返回码的失败。⚠️ 它不是闸门：玩家被告知，然后自己选择，残留物从不自作主张。 */
    try {
      this.jvmIncomplete = fs.accessSync(JVM_INCOMPLETE_FILE);
      if (this.jvmIncomplete) {
        /* 【先】读证据，在标记被清除之前，也在原生 main() 截断日志之前。 */
        const parts: Array<string> = [];
        const probe: string = logLine('mmap(RWX) FAILED');
        if (probe !== '') { parts.push(probe); }
        const forced: string = logLine('FORCING -Xint');
        if (forced !== '') { parts.push(forced); }
        const called: string = logLine('calling JNI_CreateJavaVM');
        if (called !== '') { parts.push(called); }
        if (logLine('CreateJavaVM (strict) returned') === '') {
          /* 这个标记存在的全部理由：create() 进去了就没回来，所以既没有返回码也没有 faultlog。 */
          parts.push('(no return value -- the process died inside create)');
        }
        const verdict: string = launcherExecMemoryVerdict();
        parts.push('execmem: ' + (verdict === '' ? '(not measured)' : verdict));
        parts.push('shield now: ' + this.shieldDiag);
        this.jvmFaults = parts.join(String.fromCharCode(10));
        try {
          fs.unlinkSync(JVM_INCOMPLETE_FILE);
        } catch (e) {
          /* 删不掉它的代价只是下次启动多一个提示，不是启动失败；绝不能让这个挡住应用。 */
        }
      }
    } catch (e) {
      this.jvmIncomplete = false;
    }

    /* 在 XComponent 存在之前：有游戏就直接进游戏，没有就显示启动器界面（见 decideStartup()）。
     * ⚠️ 它排在 setupCompatMode() 【之前】：那一句会写 jvm.options，而既然它有可能决定根本
     * 不挂 XComponent，就没必要先写一份用不上的文件。 */
    this.decideStartup();

    /* 在 XComponent 存在之前：见 setupCompatMode。启动器在 SDL_main 一启动时就读那个选项文件，
     * 那正是 XComponent 挂载的时候。 */
    this.setupCompatMode();
    /* 这里【曾经】调用 seedProbeMod()，已删除；见它原先定义处的说明。 */
  }

  /* 拿掉状态栏和导航栏。这是修 bug 不是锦上添花：球的半隐藏靠滑出窗口边缘，在上下两侧球
   * 只是滑进了系统栏占据的那条带里、仍然可见 —— 设备上报过；栏没了之后 y=0 才是物理顶端。
   * ⚠️ `setWindowSystemBarEnable([])` 会编译出 "This API is unavailable to 2in1"：本应用声明了 2in1，
   * 这是真实缺口（PC 上栏不动），明知故犯地接受；逐条栏的形式有同样限制且多一条警告。 */
  async enterImmersive(): Promise<void> {
    try {
      const ctx: common.UIAbilityContext | undefined = this.ballCtx();
      if (ctx === undefined) {
        return;
      }
      const win: window.Window = await window.getLastWindow(ctx);
      await win.setWindowSystemBarEnable([]);   /* 空列表表示两条栏都不要 */
      await win.setWindowLayoutFullScreen(true);
      win.setImmersiveModeEnabledState(true);
      hilog.info(DOMAIN, TAG, 'immersive: bars hidden, layout full-screen');
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG,
                 'immersive: not available (%{public}s) -- keeping the bars', err.message);
      return;
    }
    /* 单独读回，放在自己的守卫里：这是一次测量，这里抛异常会被误报成「沉浸式不可用」。 */
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

  /* 把键盘高度和文本框矩形一起打出来 —— 整套方案依赖的测量：框架只会把页面上推到聚焦文本框
   * 可见为止，问题在于它最后是否落在（屏幕高度 - 键盘高度）之上。两种失败模式（框架什么都没移 /
   * 移了但不够远）在屏幕上都是「文本框被盖住」，只有这些数字能分开它们。
   * 包在 try/catch 里：任何一项不可用时，正确结果是「没有测量值」而不是构建失败的页面。 */
  async watchKeyboardHeight(): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const win = await window.getLastWindow(ctx);
      /* ⛔⛔ **`await` 之后再确认这一页还在**（2026-10-05 修的）。
       *    上面那句是**异步**的，而 `aboutToDisappear()` 里有一份对称的清理：
       *      `imeWindow.off('avoidAreaChange'); imeWindow = undefined;`
       *    ⇒ 若销毁正好发生在这次 `await` 期间，清理**已经跑完了**，而这一句紧接着
       *      **又把监听注册上去、并把 `imeWindow` 重新赋成一个已经不存在的窗口上的窗口**
       *      ⇒ 那个监听器**永远不会被摘掉**（`aboutToDisappear` 不会再跑第二次），
       *      而它的回调还会去写一张已经销毁的页面的 @State。
       * ⭐ 判据：**「先 await、后注册」的每一处，都要在注册前重新确认目标还活着** ——
       *    清理点只保证「跑过」，不保证「跑在注册之前」。
       * ⚠️ 这个标志在 `aboutToDisappear` 里置上，⛔ 别在 `aboutToAppear` 里重置：
       *    这一页是被重建（新实例）而不是被复用，新实例的字段本来就是初值。 */
      if (this.pageGone) {
        return;
      }
      this.imeWindow = win;
      /* 避让区域以 px 计量，文本框矩形为 .position() 转成了 vp；两者都以 vp 打日志，好让比较同口径。 */
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

  /* 删除上一次运行遗留的请求，赶在任何东西读到它之前。ime_want 只在游戏有文本框聚焦期间存在，
   * 被在那个对话框开着时杀掉后会活到下一次启动 —— 轮询在第一个 tick 就把它读成活的请求，键盘
   * 会在主菜单上自己弹出来（设备上报过）。启动时清除成立：此刻存在的任何文件按定义都是遗留物。
   * ime_cmd 同理；ime_rect 刻意不动，留着它 readImeRect() 能退回上一个已知可用的矩形。 */
  clearStaleImeState(): void {
    const stale: string[] = [IME_WANT_FILE, IME_CMD_FILE];
    for (const path of stale) {
      try {
        /* accessSync 返回布尔值；文件缺失时不会抛异常 —— 见 pollImeWant。 */
        if (fs.accessSync(path)) {
          fs.unlinkSync(path);
          hilog.info(DOMAIN, TAG, 'ime: cleared a stale %{public}s from the previous run', path);
        }
      } catch (e) {
        /* 删不掉的遗留物值得知道，但不值得为它让页面失败：轮询还是会打开键盘。 */
        const err = e as BusinessError;
        hilog.warn(DOMAIN, TAG, 'ime: could not clear %{public}s: %{public}s', path, err.message);
      }
    }
  }

  aboutToDisappear(): void {
    /* ⭐ **先**置这个标志，再清理 —— 顺序是承重的：那个异步注册（`watchKeyboardHeight`）
     * 会在每个 await 之后检查它，所以它必须在任何清理动作之前就已经是 true。
     * 见 `watchKeyboardHeight` 里那段：这里跑完了、那边才注册上去，是那条竞态的形态。 */
    this.pageGone = true;
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
      /* accessSync 返回布尔值；文件缺失时不会抛异常。 */
      want = fs.accessSync(IME_WANT_FILE);
    } catch (e) {
      want = false;
    }
    /* 请求文件说的是【游戏】想要什么，不是【用户】想要什么 —— 混为一谈正是键盘关不掉的原因：
     * 用户关掉它、游戏还想要文本，于是下一个 tick 又把它放回来。实测过：ESC 关掉键盘后它立刻
     * 又出现，而游戏的文本框从不放弃焦点（ESC 从未抵达游戏）。want 变 false 才是一次重新开始。 */
    if (!want) {
      if (this.showIme) {
        this.dismissIme();
      }
      this.imeDismissedUntil = 0;
      /* 游戏放开了文本框，所以用户之前做过的都作废：下一个文本框必须能自己唤起键盘。 */
      this.imeUserHid = false;
      return;
    }
    if (Date.now() < this.imeDismissedUntil) {
      return;   /* 刚被用户收起来；给游戏一点时间反应 */
    }
    if (this.imeDismissedUntil !== 0) {
      /* 截止时间到期了而游戏【仍然】在要文本 ⇒ 转发出去的 ESC 没能关掉游戏的对话框 ——
       * 键盘「自己又回来了」时，要在 hilog 里找的就是这一行。 */
      hilog.warn(DOMAIN, TAG, 'IME dismissed %{public}dms ago but the game still wants text; the forwarded ESC did not release it', IME_DISMISS_MS);
      this.imeDismissedUntil = 0;
    }
    /* 文本框可能移动了，或者这是第一次可用的读数。 */
    this.readImeRect();
    if (!this.showIme) {
      this.showIme = true;
      this.imeSent = '';
      /* 这个状态变化触发的那一帧构建出来之前文本框并不存在，所以第一次请求必须等它；
       * 一次延迟请求就够了，接下来由下面的分支接手。 */
      setTimeout(() => {
        if (this.showIme) {
          focusControl.requestFocus('ime_ui_field');
        }
      }, 60);
    } else if (!this.imeFieldFocused && !this.imeUserHid) {
      /* 游戏仍然想要文本、文本框也在，但它不持有焦点 —— 有东西抢走了焦点，重新拿回来。
       * 这取代了显示后约 450ms 内散开的五次请求连发：一次抢焦落在连发结束之后会让文本框永久死掉。
       * `imeUserHid` 是这一切安全的原因 —— 没有它，这个分支分不清「需要恢复的抢焦」和「用户刚藏起键盘」。 */
      focusControl.requestFocus('ime_ui_field');
    }
  }

  /* 给游戏的 XComponent 要回焦点 —— **这是实体键盘能不能用的那个开关**。
   *
   * ⛔ 为什么必须有它：默认启动模式是「先显示启动器」，那一刻 `showLauncher` 为真
   *    ⇒ XComponent **不在树里** ⇒ 它上面那句 `.defaultFocus(true)` **赶不上页面的初始构建**，
   *    等于没设。玩家点「启动游戏」只是把 `showLauncher` 置假，组件这时才被建出来，
   *    而全工程没有别处给它请求过焦点（`requestFocus('SDL_XComponent')` 原先只剩 `dismissIme()`
   *    一处）⇒ ArkUI 只把按键投递给聚焦组件 ⇒ **实体键盘彻底失灵，而触摸一切正常**
   *    （触摸按坐标投递，不看焦点）。
   * ⚠️ 症状的指纹：**IME 能正常弹出**（它走文件桥 + 一个隐形 TextInput，与这里无关）、
   *    游戏里按不了键、两种操控方案都一样。日志里会看到按键只落在 `onKeyPreIme[Stack]`，
   *    **没有** `onKeyPreIme[X]` —— 就是焦点不在 XComponent 上的指纹。
   *
   * ⚠️ 为什么是**一串延迟请求**，而不是 `onAppear` 里请求一次：组件刚建出来那一刻还没布局完，
   *    那一次请求会被丢掉（2026-10-05 实测：`onAppear` 里请求一次**没修好**，日志里连那行都没留）。
   *    这是本项目已经付过代价的形状 —— IME 那个隐形文本框的注释写着「第一次请求必须等它」，
   *    用的是 `setTimeout(..., 60)`。游戏这个目标比文本框晚得多（surface 要先挂上），所以给几档延迟兜住。
   * ⭐ 而 `requestFocus('SDL_XComponent')` 这个调用**本身确实有效**：`dismissIme()` 一直靠它
   *    把键盘交还给游戏，那条路是好的（那里的注释写着「否则 ESC 和 WASD 就不再到达」）——
   *    **坏的只是时序**，所以这里补的是「什么时候要」，不是「怎么要」。
   * ⚠️ 只在游戏树里要（`showLauncher` 为假），否则会从启动器界面上把焦点抢走。
   * ⚠️ `focusControl.requestFocus` 返回 **void**，拿不到成败 ⇒ 唯一判据是 hilog：
   *    **修好之后按一个键，日志里会出现 XComponent 自己那条 `onKeyPreIme[X]`。** */
  private focusClaimPending: boolean = false;

  private claimGameFocus(): void {
    if (this.focusClaimPending) {
      return;                     /* 同一轮里别把定时器叠起来 */
    }
    this.focusClaimPending = true;
    const delays: number[] = [0, 120, 400, 900];
    for (const d of delays) {
      setTimeout(() => {
        if (this.showLauncher || this.shieldBlocked) {
          return;                 /* 已经不在游戏树里了，别去抢启动器的焦点 */
        }
        focusControl.requestFocus('SDL_XComponent');
        hilog.info(DOMAIN, TAG, 'focus: asked for SDL_XComponent after %{public}dms', d);
      }, d);
    }
    setTimeout(() => { this.focusClaimPending = false; }, 1000);
  }

  dismissIme(): void {
    this.imeDismissedUntil = Date.now() + IME_DISMISS_MS;
    this.showIme = false;
    /* 在这里清掉它，赶在卸载触发的 onBlur 之前：否则那个 blur 会延长截止时间，把键盘又推后 1.5s。 */
    this.imeFieldFocused = false;
    /* 把键盘交还给游戏，否则 ESC 和 WASD 就不再到达。 */
    focusControl.requestFocus('SDL_XComponent');
  }

  /* 读游戏的文本框矩形，并把隐形文本框摆到它上面。键盘弹起期间每次轮询都调用，不只在出现时调
   * 一次：文本框会移动（对话框被拖动、视口缩小），原生侧只要它变了就重新发布。
   * 坏读数【绝不】覆盖好读数：面积为零或负会被忽略，上一次的摆放保持不变。 */
  readImeRect(): void {
    let text: string = '';
    try {
      text = fs.readTextSync(IME_RECT_FILE);
    } catch (e) {
      return;   /* 还没写入；保留我们已有的 */
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
    /* 游戏像素 -> vp。SDL 的矩形来自 Arc 的 Core.graphics（像素单位），而 .position() 用 vp；
     * 在平板上两者相差一个显示密度，所以这个转换是承重的。 */
    const xvp: number = px2vp(x);
    const yvp: number = px2vp(y);
    const wvp: number = px2vp(w);
    const hvp: number = px2vp(h);
    if (xvp === this.imeFieldX && yvp === this.imeFieldY
        && wvp === this.imeFieldW && hvp === this.imeFieldH) {
      return;   /* 没变：照样赋值会让每次轮询都重绘 */
    }
    this.imeFieldX = xvp;
    this.imeFieldY = yvp;
    this.imeFieldW = wvp;
    /* 游戏的文本框，未经修改。IME_FIELD_MARGIN_VP 在摆放隐形盒子的地方应用，不是在这里，
     * 这样这里始终是对文件的忠实读数（也是下面那行 hilog 打印的东西）。 */
    this.imeFieldH = hvp;
  }

  /* 读取记录的操作方案。文件不可读或为空都表示 mobile，与这个设置存在之前启动器的做法一致 ——
   * 对全新安装，按钮显示的是事实，而不是声称一个没人做过的选择。 */
  readControlMode(): void {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const text: string = fs.readTextSync(ctx.filesDir + '/' + CONTROL_MODE_FILE_NAME);
      this.controlMode = text.trim() === CONTROL_MODE_DESKTOP
        ? CONTROL_MODE_DESKTOP : CONTROL_MODE_MOBILE;
    } catch (e) {
      this.controlMode = CONTROL_MODE_MOBILE;   /* 文件不存在：默认值 */
    }
  }

  /* 记录另一套方案，并告诉玩家需要重启：Mindustry 的整个输入层和 UI 都派生自一个位 ——
   * Vars.mobile，它只在 Vars.init() 里写一次，早于游戏存在；它自带的游戏内开关只改输入处理器、
   * 不动那个位。所以答案必须在 JVM 启动之前落到磁盘上，而不是让玩家以为按钮坏了。 */
  /* 把一份诊断包写到应用的 Downloads 文件夹，并告知结果。文件夹在这里重新计算，而不是记住
   * 启动时 ensureModFolder() 的结果：这个按钮可能在那很久之后才被按下。modFolderPath() 读的是
   * 同一个状态文件；为空时导出会大声失败，而不是写到不存在的地方。 */
  exportDiagnostics(): void {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const where: string = exportDiagnosticsNow(this.appName,
        modFolderPath(ctx.filesDir + '/mod_folder'), ctx.filesDir);
      if (where === '') {
        this.toast('导出失败：下载文件夹不可用');
        return;
      }
      hilog.info(DOMAIN, TAG, 'diagnostics exported to %{public}s', where);
      /* ⭐ 拿不到应用名就只说真实路径 —— 编一个名字会指向【另一个】应用的文件夹。 */
      this.toast(this.appName === ''
                 ? '已导出到「下载 / diagnostics」'
                 : ('已导出到「下载 / ' + this.appName + ' / diagnostics」'));
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
      return;                                   /* 不要声称一个没落地的改动 */
    }
    this.toast(next === CONTROL_MODE_DESKTOP
      ? '已切换为 PC 模式，重启游戏后生效'
      : '已切换为触屏模式，重启游戏后生效');
  }

  /* 显示一条短消息，但不要让「显示失败」变成「它要报告的那件事失败」：showToast 声明为会抛，
   * 而这些调用方报告的事通常已经做成了。走 UIContext 而不是全局的 `promptAction`
   * （全局形式已废弃，这个文件的废弃警告已经够多了）。 */
  toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2600 });
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'toast failed (what it reported still happened): %{public}s',
                 err.message);
    }
  }

  /* 显示 About 卡片。版本号在打开时才读，不是启动时：它要花一次包查询，而那之前没人需要它。 */
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

  /* importMods() 曾在这里，已随调用它的那行菜单一起删除 —— 见 build() 里的说明。 */

  /* 记录窗口尺寸，并在第一次听到它时把球放到右边缘。尺寸来自组件而不是显示器：窗口不总是
   * 整块屏幕，拿错误的矩形去 clamp 会让球停在屏幕之外 —— 所以没有用 display.getDefaultDisplaySync()。 */
  onWindowSize(w: number, h: number): void {
    if (w <= 0 || h <= 0) {
      return;
    }
    this.winW = w;
    this.winH = h;
    /* 每次上报都重新计算；尺寸跟随窗口。 */
    this.ballSizeVp = Math.round(
      Math.min(Math.max(Math.min(w, h) * BALL_SIZE_RATIO, BALL_SIZE_MIN_VP), BALL_SIZE_MAX_VP));
    if (this.ballPlaced) {
      /* 后续上报时刻意【不】重新 clamp 位置：框架为让开键盘而把页面上推时 onAreaChange 也会触发，
       * 在那里 clamp 会把球往上拖并留在那里 —— 一次由无关功能引起的永久移动。相比之下，球稍微
       * 凸出边缘的尺寸变化小得多：存下的位置下次启动会被 clamp，拖一下就能修正。 */
      return;
    }
    const s: number = this.ballSizeVp;
    if (this.ballRestoreX >= 0 && this.ballRestoreY >= 0) {
      /* 被 clamp 到「停靠带」里，而不只是 clamp 进窗口。下界：更早的构建写入的是贴边位置，从那种
       * 位置恢复的球会一直贴边相切。上界：存在更宽屏幕上的位置绝不能把球放到更窄屏幕的边缘之外。
       * 上界上的 Math.max 让带子在极小窗口上不会翻转。 */
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
      /* 【先】露出，而且不带动画：半隐藏的球的位置并不是露出后的位置，拿「隐藏时的坐标」当锚点
       * 去拖动会把球从手指底下甩出去 —— 就是上报的那个「从半个球里跳出来」。按下就露出也意味着
       * 点一下就能把整个球带回来。之前的隐藏状态在这里捕获，松手处理器之后无法找回。 */
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
        return;   /* 仍在点按容差内 —— 先别移动 */
      }
      this.dragMoved = true;
      this.ballMenu = false;   /* 拖动会关闭菜单 */
      const s: number = this.ballSizeVp;
      /* 对窗口做 clamp，这样球不会被推离边缘而丢失。 */
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
        /* 第一次点按只把球带回来，打开菜单需要第二次。没有这个拆分，点半隐藏的球会同时恢复球
         * 【又】打开菜单 —— 一个只想看看球跑哪去了的玩家会得到一个他没要的菜单。倒计时也会重新开始，
         * 否则点一下之后球会一直待在外面，半隐藏就不再是静息状态。 */
        this.scheduleBallHide();
      } else {
        this.ballMenu = !this.ballMenu;
        /* 隐藏的球配打开的菜单会悬浮在虚无旁边，而且玩家反正正在交互 ——
         * 所以只有菜单被关掉之后才重新开始倒计时。 */
        if (!this.ballMenu) {
          this.scheduleBallHide();
        }
      }
      this.dragMoved = false;
    }
  }

  /* 球离哪条边最近。刻意与隐藏方向共用：如果吸附和隐藏各自算各自的，就可能不一致，
   * 球会从屏幕错误的一侧滑出去。 */
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

  /* 把球送到最近的那条边。四条边都算而不只左右：球很小，玩家可能想让它贴上边或下边。
   * 带动画而不是瞬移 —— 这个大小的物体瞬移读起来像故障。animateTo 会闭包捕获那次赋值，
   * 所以位置在回调内部设置。 */
  snapBallToEdge(): void {
    if (this.winW <= 0 || this.winH <= 0) {
      return;
    }
    const s: number = this.ballSizeVp;
    const edge: string = this.nearestEdge();
    /* 停在离边 BALL_MARGIN_VP 的地方，不贴边：贴边是原来的行为，和新摆放的球（离边一个 margin）
     * 不一致，于是玩家从未碰过的球保留间隙、拖动过一次的球永久失去间隙 —— 设备上报过。
     * 现在这个 margin 是每条边上的停靠内缩量，两条路径都一样。 */
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

  /* 隐藏时球滑出它那条边多远，一个渲染期偏移量。露出时为 0：ballX/ballY 是唯一被写入的坐标，
   * 所以隐藏永远不会被误当成一次移动。BALL_MARGIN_VP 是【偏移量的一部分】：球现在离边停靠
   * 一个 margin，只按球自身比例滑会把那个 margin 也留在屏幕上（40% 再加 8vp）。
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

  /* 启动半隐藏的倒计时。每当球停稳或被放开时调用。 */
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

  /* ability 上下文，走没有废弃的那条路：getContext() 仍能用但已废弃，而这个文件每调用一次
   * 本就带一条警告。getHostContext() 可能返回 undefined，所以检查它 —— 「没有上下文」意味着
   * 文件够不到。只有两个调用点用它；另外四处（权限、键盘）刻意不动。 */
  ballCtx(): common.UIAbilityContext | undefined {
    return this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
  }

  /* 球上次停在哪，好让下次启动把它放回去。 */
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

  /* 把存下的位置读进 ballRestoreX/Y，【不】在这里应用：应用它需要一个窗口尺寸做 clamp，
   * 而 onAreaChange 还没上报过。垃圾内容被拒绝而不是被 clamp：一行损坏的数据会把球停进
   * 某个角落且毫无解释。 */
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
      /* 首次运行时没有文件，这是正常情况，不是错误。 */
    }
  }

  /* 菜单摆在哪：球的旁边，朝内开。 */
  ballMenuX(): number {
    const right: number = this.ballX + this.ballSizeVp + 8;
    if (right + BALL_MENU_W_VP > this.winW) {
      return Math.max(0, this.ballX - BALL_MENU_W_VP - 8);
    }
    return right;
  }

  /* 与球垂直对齐，但绝不越过窗口边缘。 */
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

  /* 系统返回手势在游戏内部上一层，从不离开应用。Mindustry 的「返回」就是 ESC，所以手势经屏幕
   * 键盘已在用的同一条文件通道转发出去（那条通道每帧被无守卫读取，有没有文本框都能工作）；
   * 返回 true 表示本页处理了它，应用留在屏幕上。退出是游戏自己主菜单里的事，不是我们的。
   * ⚠️ 双击退出做过又拿掉（分清 UI 深处需要游戏的 UI 状态，我们没有这个通道）；代价是在主菜单上返回什么都不做，逃生口不受影响。 */
  onBackPress(): boolean {
    /* ⛔ 先问启动器界面：原来这里无条件把返回转成 ESC 发给游戏，而启动器界面（首页/存档/设置）
     * 底下根本没有游戏 ⇒ 那条 ESC 发进虚空，玩家看到「滑了没反应」。手势本身是好的（系统的手势
     * 侧滑与返回键是同一个事件）；缺的是「谁在启动器界面里消费它」。
     *
     * ⛔⛔ **但只要还在启动器界面上，就【绝不】往桥里写东西**（2026-10-05 修的，代码审查发现）。
     *    原来这一句是 `if (this.showLauncher && this.launcherBack())`，而 `launcherBack()` 在
     *    **根层**返回 false（`LauncherHome.handleBack()` 最外层就是 `return false`）
     *    ⇒ 条件不成立 ⇒ **落到下面那条 `appendCmd('E\n')`** ⇒ 往「给游戏发命令」的桥文件里
     *    写了一个 ESC。可此刻界面上**根本没有游戏**（没有 XComponent ⇒ 没有 native 消费者）
     *    ⇒ 这条 `E\n` 就**留在文件里**，一直等到玩家点「启动游戏」：XComponent 一挂载，
     *    native 从 offset 0 读起，把这**一次 ESC 当成按键喂给刚起来的游戏**（ESC 会开关游戏菜单）。
     * ⭐ 触发链很普通：在启动器首页按一下返回（界面上没反应，这是设计），过一会儿点启动游戏。
     * ⛔ 判据：**「谁在消费这条命令」比「命令该不该发」更根本** —— 没有消费者时写进去的命令
     *    不会消失，只会**延后生效**，而延后生效在玩家眼里就是「游戏自己动了」。 */
    if (this.showLauncher) {
      const handled: boolean = this.launcherBack();
      hilog.info(DOMAIN, TAG, 'back: the launcher screen had it, handled=%{public}s',
                 String(handled));
      return true;
    }
    /* 'E' 就是整个 ESC 命令；原生侧按整行消费，所以那个换行是命令的一部分。 */
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
      /* 一次无法用 append/truncate 表达的编辑。撤回我们掌控的部分再重新输入：
       * 文本框最后是对的，而游戏在本次会话之前就已存在的文本保持不动。 */
      if (prev.length > 0) {
        cmds += 'B' + prev.length + '\n';
      }
      cmds += 'T' + next + '\n';
    }
    this.imeSent = next;
    this.appendCmd(cmds);
  }

  /* 决定 JVM 是否必须以解释方式运行，并写出或删除启动器要读的选项文件。【必须】在 XComponent
   * 创建之前运行：启动器在 SDL_main 启动时读那个文件，而 SDL_main 在 XComponent 挂载时才跑 ——
   * 再晚就是一场赛跑，输掉是无声的（带 JIT 起来，死在 JNI_CreateJavaVM 里）。文件每次启动都往
   * 两个方向重写：只写不删会让一次 -Xint 永久留下，而设备上没有任何东西能解释为什么。 */
  private setupCompatMode(): void {
    /* 优先级顺序：FORCE_COMPAT_MODE（明确的指令） > 启动器的结论（对本次安装的测量） >
     * 设备类型规则（猜测，只在没有测量结果时用）。⚠️ FORCE 必须在最上面 —— 它就是发布脚本
     * 「只要它不是 false 就拒绝构建 release」那个开关；更早的版本把结论放到它上面，于是开关
     * 无声失效（一次开着 FORCE 的启动读到过期的 "jit" 结论，把强制作罢，结果什么都没写）。 */
    let want: boolean = false;
    let kind: string = '?';
    let api: number = -1;
    let source: string = 'device rule';

    try {
      kind = deviceInfo.deviceType;
      api = deviceInfo.sdkApiVersion;
      /* 只是首启猜测（见 MIN_API_FOR_JIT）；只要启动器报了测量结果，下面的测量就会取代它。 */
      want = kind === 'phone' && api < MIN_API_FOR_JIT;
    } catch (e) {
      const err = e as BusinessError;
      /* 失败即放行：平台不肯说它是什么就假设 JIT 能用；失败即拒绝会仅凭一次查询失败
       * 就让所有人玩得更慢。 */
      hilog.error(DOMAIN, TAG,
        'deviceInfo unavailable (%{public}s) -- assuming the JIT works', err.message);
      kind = 'unavailable';
      want = false;
    }

    /* 启动器的测量压过猜测：规则问「这是不是那类通常拿不到内存的设备」，探测问「本次安装拿到了
     * 没有」—— 只有后者是玩家体验到的东西，两者不一致比规则暗示的更频繁（API 26 手机在商店包里
     * 拿不到权限、API 26 的 DEBUG 安装 JIT 却跑得好、没有该 ACL 的平板）。
     * ⚠️ 猜测仍是首启的答案且在低于 API 26 的设备上必须如此：什么都不写会让 JVM 在产生结论前卡住。 */
    const verdict: string = launcherExecMemoryVerdict();
    if (verdict === 'interp') {
      want = true;
      source = 'launcher measured: no executable memory';
    } else if (verdict === 'jit') {
      want = false;
      source = 'launcher measured: executable memory available';
    }

    /* 最后也最高：见上面关于顺序的说明。 */
    if (FORCE_COMPAT_MODE) {
      want = true;
      source = 'FORCE_COMPAT_MODE';
    }
    /* 【无条件】记录日志，包括输入：第一个版本只在兼容模式开启时才记，让「选项文件没被写」和
     * 「一次从未运行的方法」无法区分。平板上实测 "compat mode: device=tablet api=26 -> interpreted=false"，
     * 与启动器的 "(no options file found; tried 3 locations)" 彼此吻合。 */
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
        /* accessSync 返回布尔值；文件缺失时不抛异常 —— 把它当成会抛的检查，正是一个应用曾经在每次启动后 0.25 s 自杀的原因。 */
        fs.unlinkSync(path);
        hilog.info(DOMAIN, TAG, 'compat mode off: removed %{public}s', path);
      }
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'could not set compat mode: %{public}s', err.message);
      /* 保持原样：过期的 -Xint 代价是速度，缺了它代价是应用起不来。继续走下去比抛出去好。 */
    }

  }

  /** 决定这一屏显示游戏还是启动器。只在 aboutToAppear 里调用一次。
   * ⚠️ 必须在 ArkTS 里、且必须在挂载 XComponent 之前：挂载 XComponent ⇒ 加载 libmain.so ⇒
   * main() 跑 ⇒ 一次完整的 JVM 启动，所以「先挂上、再由 native 说没有游戏」会白起一次 JVM。
   * native 侧仍然【也】判一次（launcher.c 的 resolve_game_jar）：防的是 `aa start` 之类绕过界面
   * 直接拉起 native，以及两次之间文件被删。 */
  /* 把「上次为什么没起来」拼成一段给玩家看的话。⚠️ 两句判据指向的处置不同：jvm_incomplete
   * ⇒ Java 虚拟机都没建起来（多半是设备/权限层面，与 jar 无关）；JVM 好的 ⇒ 那个 jar 里没有
   * 游戏。⚠️ 日志尾巴是搬过来的：启动器把每处失败都写进 stderr.log，例如
   * "!! mindustry.core.Vars is NOT on the classpath" —— 与其写「可能是不兼容的 jar」，不如交出原文。 */
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

    /* ⚠️ 这个调用【顺带把标记删掉】—— 读而不清会把「点过一次启动器」变成一道永久的门。 */
    const requested: boolean = consumeLauncherRequest(ctx.filesDir);

    const r: GameResolution = resolveGame(ctx.filesDir, ctx.bundleCodeDir);
    /* 每次都把这些路径写进日志：`bundleCodeDir` 的取值目前只是推断，而「判定没有游戏」和
     * 「内置游戏路径算错了」在界面上长得一样 —— 这几行是唯一能把两者分开的东西。 */
    reportGameResolution(ctx.filesDir, ctx.bundleCodeDir, r);

    if (requested) {
      hilog.info(DOMAIN, TAG, 'startup: the launcher was requested -- showing it');
      this.showLauncher = true;
      return;
    }

    /* 上一次的启动尝试没有走到游戏入口 ⇒ 回启动器，并把原因交给它显示 —— 这是「一打开就闪退、
     * 回不了主界面」的解药（2026-10-01 实际撞上：把一个 mod 当成游戏选了）。⚠️ 现有两个标记盖不住它，
     * 见 GameLibrary 里 launch_pending：JVM 建起来了（jvm_incomplete 已删），主类找不到时是干净返回
     * （不写 crash.txt）⇒ 必须有「有没有到过游戏入口」的独立判据。读后即删，同 consumeLauncherRequest。 */
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

    /* 玩家选了「启动时先进首页」。⚠️ 排在失败判定【之后】：那是必须回的，而这一条是偏好，
     * 两者都成立时理由更强的那个赢。 */
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

  /** 启动器里点了「启动游戏」。参数是最终决定要加载的 jar，'' 表示「用包里的」。
   * ⚠️ 顺序承重：桥接必须在 XComponent 挂载之前写，写晚了这一次加载的会是上一次选择的结果。 */
  private startGame(jarPath: string): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    /* gamejar= 那一行由 writeUserDirs 从 selected_game.txt 推出，不在这里拼 —— 桥接的格式只由写它的函数拥有。 */
    writeUserDirs(ctx.filesDir);

    /* 记下「正在尝试启动这个 jar」，在切到游戏树【之前】。⚠️ 参数在有的路上是空的（'' 表示
     * 「用包里的」），空的时候自己解析一遍 —— 标记里那句是失败时给玩家看的「是哪一个没起来」，
     * 写空等于丢掉唯一有用的信息。也不为「绕过判定」开特例：最需要它记录的那次恰好是它不记录的那次。 */
    const res: GameResolution = resolveGame(ctx.filesDir, ctx.bundleCodeDir);
    const attempted: string = jarPath !== ''
      ? jarPath
      : res.path;
    markLaunchAttempt(ctx.filesDir, attempted);

    /* ⭐ 版本隔离的桥必须在这里再写一次 —— native 的 main() 就在下面这一句之后开始跑。⚠️ 不能只靠
     * EntryAbility.onCreate 那一次：默认「先显示启动器」，玩家会在它之后才改选 jar，而它写下的键属于
     * 上一个选择 —— 数据会落到另一个版本的目录且看起来一切正常。键跟着真正要启的那个走。 */
    try {
      const g: string = readGranularity(ctx.filesDir);
      const src: string = jarPath !== '' ? 'user' : res.source;
      writeIsolationBridge(ctx.filesDir, g,
                           computeKey(g, src, attempted, bundledGamePath(ctx.bundleCodeDir)));
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'isolation: could not decide at launch (%{public}s)', err.message);
    }

    this.showLauncher = false;
    /* ⭐ 就在这一刻安排要焦点：XComponent 会在紧接着的那一帧被建出来，所以这一次排的
     * 延迟请求正好落在它建好之后。⚠️ 不能等 `onAppear` —— 2026-10-05 实测那次没生效，
     * 所以这里不把成败押在它身上，两处都挂着（`claimGameFocus` 内部有防重入）。 */
    this.claimGameFocus();
  }

  /** 悬浮球菜单里的「启动器」：回启动器界面。
   * ⚠️ 不能直接 `this.showLauncher = true` —— 那段代码运行时游戏已经起来了，本页树里挂着活的
   * XComponent，摘掉它等于在 native 正在跑时拆它的 surface。所以走既有的退出握手：记下意图，
   * 然后 terminateSelf，让框架按自己的顺序拆。 */
  private backToLauncher(): void {
    const ctx = getContext(this) as common.UIAbilityContext;

    /* 【先】记下意图再重启。⚠️ 顺序不能反：它是 restartApp 失败时的唯一退路 —— 先写标记，
     * 无论重启成不成，下一次启动都会进启动器。 */
    requestLauncher(ctx.filesDir);

    /* 顺手清掉「正在尝试启动」的标记。走到这里说明游戏已经在跑了，native 早已在游戏入口删过标记，
     * 所以正常路径上是空操作；它防的是 native 万一没删成（权限、异常路径），下一次启动会把
     * 「刚才明明玩得好好的」报成失败。清掉是幂等的，代价为零。 */
    clearLaunchAttempt(ctx.filesDir);

    /* 用 `ApplicationContext.restartApp()` 重启进程并拉起本 ability。必须是重启而不是切界面：换游戏=换 jar=必须重开 JVM（classpath 在 VM 创建时定死，main() 已跑过一个循环）。
     * ⚠️ 用 ApplicationContext 版而非 UIAbilityContext 版：SDK 写明后者 "can be properly called only on phones"，否则 801 —— 而平板是我们最主要的设备。
     * ⚠️ 它会抛（16000053 不在前台 / 16000063 目标不对 / 16000064 三秒内重启过频），一律落到退路：标记已写好，terminateSelf 后点一下图标就能回来。 */
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

    /* 退路：关掉自己。下次启动读到上面那个标记，照样进启动器。 */
    ctx.terminateSelf().catch((err: BusinessError) => {
      hilog.error(DOMAIN, TAG, 'terminateSelf failed: %{public}s', err.message);
    });
  }

  build() {
    /* 用 Stack，让文本框浮在游戏之上，而不是让游戏表面重排给它腾地方。 */
    Stack({ alignContent: Alignment.Top }) {
    /* 启动器【替换】整棵游戏树，而不是盖在它上面：盖上去 XComponent 仍会挂载 ⇒ native 仍会起一次
     * JVM，而「没有游戏可加载」那一屏存在的理由正是【不要】起那一次；且游戏树里那个隐形 TextInput
     * 可获焦，会压在启动器按钮之上吃掉点击。⚠️ 下面的缩进刻意没跟着 else 右移 —— 那会让唯一的真实改动被埋进巨大的空白 diff。 */
    if (this.showLauncher) {
      LauncherHome({
        filesDir: this.launcherFilesDir,
        bundleCodeDir: this.launcherBundleDir,
        /* 见 folderSettled：它到位之前，本页读到的是空路径。 */
        folderSettled: this.folderSettled,
        /* 设置页的「关于」要显示版本。由本页从 bundle 问到，见 appVersion。 */
        appVersion: this.appVersion,
        /* 上一次启动失败的记录；'' 表示没失败过。由 decideStartup 组装，见 buildLaunchFault。 */
        launchFault: this.launchFault,
        onLaunch: (jarPath: string) => { this.startGame(jarPath); },
        /* 「仍然尝试启动」：绕开判定直接进游戏树。它是逃生门 —— 判定没有游戏有三个来源，其中两个
         * 是我们的问题。没有它，一次判断失误就把应用变成永远打不开游戏的启动器。 */
        onForceLaunch: () => { this.startGame(''); },
        /* ⭐ 启动器把「返回一层」注册上来：回收站、手机子页和那几个弹窗都要靠它。 */
        registerBack: (fn: () => boolean): void => { this.launcherBack = fn; },
      })
    } else {
    Row() {
      Column() {
        if (!this.shieldBlocked) {
          XComponent({ id: 'SDL_XComponent', type: XComponentType.SURFACE, libraryname: 'SDL3' })
            .id('SDL_XComponent')
            /* 键盘输入需要这个组件持有焦点：ArkUI 只把按键事件投递给聚焦组件，SDL 经 OH_NativeXComponent_RegisterKeyEventCallback 收到它们；没有焦点时按键永远到不了原生代码且无声。
             * defaultFocus 让它在构建时成为焦点目标。⚠️ focusOnTouch 刻意去掉：它每次触摸都重夺焦点，与键盘的焦点请求竞争 ⇒ 文本框弹出却无焦点（症状时有时无）。
             * 去掉无损失：触摸按坐标投递、只有按键跟随焦点。 */
            .focusable(true)
            .defaultFocus(true)
            /* ⛔⛔ **这一句是承重的，别删**（2026-10-05 修，用户 bisect 定位到本处）。
             *   `defaultFocus` 只在【页面初始构建】那一次起作用。而默认启动模式是「先显示启动器」，
             *   那一刻 `showLauncher` 为真 ⇒ XComponent **根本不在树里**，初始焦点就落在没有它的页面上。
             *   玩家点「启动游戏」只是把 `showLauncher` 置假 ⇒ XComponent 【这时才被建出来】，
             *   而没有任何地方给它请求过焦点：全工程 `requestFocus('SDL_XComponent')` 只剩
             *   `dismissIme()` 那一处，冷启动直接进游戏时一次都走不到。
             *   ⇒ ArkUI 只把按键投递给聚焦组件 ⇒ **实体键盘彻底失灵，而触摸一切正常**（触摸按坐标投递）。
             * ⚠️ 症状的指纹是「IME 能正常弹出、游戏里就是按不了键、两种操控方案都一样」——
             *   因为 IME 走的是文件桥 + 一个隐形 TextInput，与这里这个焦点无关。
             * ⭐ 判据：**组件晚于页面初始构建才出现时，`defaultFocus` 赶不上，必须自己请求一次。**
             * 【实测·用户 bisect】1.1（无启动器界面）键盘正常 → 1.2（引入启动器界面）键盘坏、
             *   且 1.2 / 1.3.1 / 1.3.2 / 1.3.3 全坏；把启动模式改成「直接进游戏」（XComponent 构建时就在）
             *   键盘立刻恢复 ⇒ 本句即修复。
             * ⚠️ `focusControl.requestFocus` 返回 **void**（不是 boolean），别去接它的返回值。 */
            .onAppear(() => { this.claimGameFocus(); })
            /* 最早的按键钩子，必须【拒绝】（返回 false）：在这里消费 ESC 虽然能修正系统行为，但实测会在
             * 原生代码看到之前就把它吞掉（ESC 时 SDL 一个字节都没记到，而非 ESC 的控制键仍正常到达）。
             * 所以这个断口专属于「消费」，不是键盘普遍损坏 —— 但它仍意味着游戏永远拿不到它的 ESC。 */
            .onKeyPreIme((e: KeyEvent) => {
              hilog.info(DOMAIN, TAG, 'onKeyPreIme[X]: keyCode=%{public}d -> consumed=false (pass through)',
                e.keyCode);
              return false;
            })
        }
      }
      .width('100%')
      /* ESC 必须不再充当系统返回键，又不能被从游戏那里拿走 —— 两条要求方向相反，所以处理器放在这个【祖先】节点上而不是 XComponent 上，这个位置就是全部的修复。实测事件链：13.965 onKeyPreIme[X] consumed=false（我们的，拒绝）-> 13.971 onKeyEvent[Column] consumed=true（我们的，在祖先上）；以前还有 Ace: OnBackPressed。
       * 顺序是 onKeyPreIme -> XComponent（SDL 在这里拿到键）-> 祖先，所以在这里消费不可能从游戏夺走东西。⚠️ 挂在 XComponent 自身的 onKeyEvent 永远不会被调用（原生 XComponent 路径优先），不要把处理器挪回去；原生回调 SDL_OpenHarmonyDispatchKeyEvent 返回 void，所以这个决定只能在 ArkUI 里做。
       * 【只有】ESC 被消费，其他键返回 false。⚠️ 这些 hilog 行不是装饰：一个无声地从不被调用的处理器已让本项目付过代价（早先用了不存在的名字 onBackPress）。 */
      .onKeyEvent((e: KeyEvent) => {
        const esc = e.keyCode === KeyCode.KEYCODE_ESCAPE;
        hilog.info(DOMAIN, TAG, 'onKeyEvent[Column]: keyCode=%{public}d -> consumed=%{public}s',
          e.keyCode, String(esc));
        return esc;
      })
    }
    .height('100%')

      /* 只在游戏内有文本框聚焦时出现。单行：命令协议基于行，Mindustry 的文本框本来也是单行。 */
      if (this.showIme) {
        /* 刻意不可见：用户在游戏自己的文本框里看到输入内容，再显示第二个框既多余又让人困惑。它仍必须存在、可聚焦、并持有 IME —— 不可见但持有焦点才是让键盘保持弹起的东西（若输入法拒绝零透明度文本框，就给它 0.01 的透明度）。
         * 它盖在【游戏】的文本框上而不是屏幕顶部：框架的键盘避让只会把页面上推到聚焦文本框可见为止，
         * 放到玩家正在看的地方才能让它移动恰好那段距离；锚在顶部时它什么都没要求，键盘就把文本框盖住了。 */
        TextInput()
          .id('ime_ui_field')
          /* 锚在文本框的左上角，且只在键盘真正弹起时比它更高。见 IME_FIELD_MARGIN_VP。 */
          .position({ x: this.imeFieldX, y: this.imeFieldY })
          .width(this.imeFieldW)
          .height(this.imeFieldH + (this.imeUserHid ? 0 : IME_FIELD_MARGIN_VP))
          .opacity(0)
          .onChange((v: string) => {
            this.sendDelta(v.replace(/[\r\n]/g, ''));
          })
          .onFocus(() => {
            this.imeFieldFocused = true;
            /* 用户主动要了键盘（点这个文本框，它留在屏幕上正是为了还能再被点到）；他之前做过的都作废。 */
            this.imeUserHid = false;
          })
          .onBlur(() => {
            /* 键盘被收起来了（系统键盘的隐藏按钮、点文本框之外，含义相同：它不该自己回来）。
             * ⚠️ 游戏自己的请求决定不了：`ime_want` 说游戏想要什么，而游戏永远不知道用户藏了键盘（它自己的文本框仍聚焦，SDL 从不调 HideScreenKeyboard）—— 这就是「收起后它立刻又回来」的原因。
             * 我们自己的收起从不到达这里（dismissIme() 提前清了 imeFieldFocused）；被抢走的焦点和用户收起无法区分，按收起处理是可恢复的。清除刻意不基于时间。 */
            if (this.imeFieldFocused) {
              this.imeUserHid = true;
            }
            this.imeFieldFocused = false;
          })
          .onSubmit(() => {
            /* 在键盘上按了完成：把输入的控制权交还给游戏。 */
            this.dismissIme();
          })
      }

      /* 悬浮球及它打开的菜单。用球而不是带标签的按钮：它必须待在游戏之上，而一个小圆是尽可能小的遮盖；角落里一个固定按钮要么挡路、要么小到点不中。点一下是打开菜单而非执行动作，因为它注定承载多个功能。
       * ⚠️ focusable(false) 是承重的：ArkUI 只把按键事件投递给聚焦组件，而 XComponent 需要那份焦点，
       * 否则 SDL 看不到按键、键盘彻底失效（没有焦点时点击和触摸仍然有效）。画成带边框的圆，好让标签直接放在它里面。 */
      Stack() {
        /* 游戏自己的炮塔，而不是字模：齿轮试过且渲染出来了，但它是字体字符，粗细齿形取决于设备
         * 提供的字体，而且读起来像「设置」。这就是应用图标所用的同一张 32x32 炮塔，位图，不依赖字体。
         * ⚠️ Interpolation.None 是让它不发糊的原因（源图是该 sprite 34px 的整数倍）；draggable(false) 因为球的拖动由 Stack 的 onTouch 处理。 */
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
      /* 半隐藏在【这里】，别处没有：ballX/ballY 始终保存露出的位置，所以拖动、clamp、吸附和
       * 存下的文件都基于同一套坐标 —— 改成移动 ballX 会让它们每一个都得考虑球隐藏到什么程度。 */
      .position({ x: this.ballX + this.ballHideDx(), y: this.ballY + this.ballHideDy() })
      .opacity(this.ballHidden ? BALL_OPACITY_HIDDEN : 1)
      .focusable(false)
      .onTouch((e: TouchEvent) => { this.onBallTouch(e); })

      if (this.ballMenu) {
        Column() {
          /* 条目：回启动器。游戏一旦起来，本应用就没有别的路回到那一屏了（启动器界面只在 decideStartup()
           * 判定「不启动游戏」时出现，而那个判定每次启动只做一次）—— 没有这一行，玩家换了 jar 之后想再换
           * 就只能卸载重装。⚠️ 它退出应用而不是切界面，理由见 backToLauncher()。 */
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

          /* 条目：当前生效的是哪套操作方案及切换开关。选择必须在游戏启动之前做出：Mindustry 的整个
           * 输入层【和】UI 都派生自 Vars.mobile，在 Vars.init() 里只写一次；它自带的游戏内开关只改输入
           * 处理器 ⇒ 桌面控制配移动端 UI（平板上实测并在字节码里确认）。所以需要重启，这一点被明白说出。 */
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

          /* 一条细线，不是一个 margin：同一张卡片上的两个标签无论隔多远都会被读成一段文字，
           * 分隔线才是说明「这是两个选择」的东西。 */
          Divider()
            .strokeWidth(BALL_MENU_DIVIDER_VP)
            .color('#22ffffff')

          /* 这里【曾经】有一行 "导入模组"（选文件 → 复制进模组目录），已【删除】。那三种方式全都让应用
           * 自己决定一个模组何时存在，玩家无法在游戏内撤销：把 Downloads 里的东西每次启动复制进模组目录
           * （只跳过已在且大小相同的），于是在游戏里删掉一个模组会下次启动被带回来；而存档是 .zip，
           * 放在那里会被当成模组扫进去。⇒ 现在唯一的入口是游戏自带的导入按钮（手动，构造上就不自动）。 */

          /* 条目：谁做的、它住在哪、以及它不是官方的。这些答案需要在应用内部够得到，
           * 因为问题冒出来的时候玩家已经在应用里了。 */
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

          /* 一键求助。应用本来就自己导出崩溃报告，但只在有崩溃时 —— 而最难处理的情况恰恰没有崩溃
           * （「它起不来」「行为异常」）。release 签名安装下应用之外读不了沙箱，没有这个按钮，
           * 「把日志发给我」的答案就是「拿不到」。写到应用的 Downloads 文件夹。 */
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
        /* ⭐ 淡入出现（用户 2026-10-03 点名）。⚠️ 挂在这里而不是整层：菜单是 position 定位的
         * 一张卡、没有全屏遮罩，所以淡入的就是它自己。⛔ 别把 transition 挪到 `.focusable(false)`
         * **之前** —— 那是同一个节点，位置无所谓；但**不要**给它加任何可获焦的东西（见上面那条规则）。 */
        .transition(enterFade(80))
      }
    /* About 卡片 —— Stack 子节点，盖住一切包括悬浮球。任何地方都没有可聚焦组件：对话框或 Button
     * 会从 XComponent 夺走焦点，游戏然后就看不到键盘，所以变暗的区域本身就是关闭按钮。那些地址是
     * 纯 Text 而不是链接，这就是那条规则的代价：可点需要可聚焦组件或剪贴板权限，两者都不值得。 */
    if (this.showAbout) {
      Column() {
        Column() {
          /* ⭐ 走资源，与启动器那边的 About 同一处规则。原来这里写死 'Mindustry Ark'，
           * 于是改名之后同一块屏幕上两处 About 显示两个名字。
           * ⚠️ 拿不到时给一个空格，不是给某个写死的名字 —— 下一个 `Text`（版本号）就是这么做的，
           * 而写死一个名字恰好会让【另一个】应用显示错名，那正是这次要修的毛病。 */
          Text(this.appName === '' ? ' ' : this.appName)
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
          /* 带上协议头：没有它，光秃秃的 "github.com/..." 读起来像路径或包名，设备上报过。
           * 这两行是卡片上最长的文字，Issues 那行有 47 个字符 —— 用正文字号在手机上放不进卡片、
           * 会在地址中间折行。 */
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
        /* 92% 和 18，而不是 86% 和 22：那两个地址是这里最宽的文字，这是给它一条能放下的行宽
         * （对着手机的窗口宽度实测过）。 */
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
        /* 整层淡入（遮罩 + 卡片一起）。 */
        .transition(enterFade())
        .onClick(() => {
          const ctx = getContext(this) as common.UIAbilityContext;
          ctx.terminateSelf().catch((err: BusinessError) => {
            hilog.error(DOMAIN, TAG, 'terminateSelf failed: %{public}s', err.message);
          });
        })
      }
      /* ⛔ 这里【曾经】是「上次启动未完成」的提示层，2026-10-01 撤掉：它长在游戏树里，而游戏树
       * 正是失败之后不该来的地方 —— 玩家唯一能做的动作是把同一次失败再试一遍。⇒ 同样的信息现在
       * 由启动器界面的弹窗负责（LauncherHome 的 launchFault）。 */
    }
    /* ↑ 这一行关的是「游戏树」那个 else 分支；下面那一行关 Stack。 */
    }
    /* 这个修饰符唯一的任务就是学到窗口尺寸，好让球对着正确的矩形摆放和 clamp。 */

    .onAreaChange((_o: Area, n: Area) => {
      this.onWindowSize(Number(n.width), Number(n.height));
    })
    /* ESC 放在 Stack 上：游戏表面和文本框的共同祖先，因此是两者无论哪一个聚焦都能看到这个键的唯一节点。
     * 焦点是单一的，这正是下面【两个】钩子都存在的原因：文本框聚焦时 Column 不在焦点链上、必须在这里接住；游戏聚焦时 Column 在链上。
     * onKeyPreIme 必须排在前面，因为实测祖先的 onKeyEvent 在 TextInput 持有焦点时不触发；只在我们的文本框弹起时消费，返回 true 阻止 HarmonyOS 把 ESC 当返回。 */
    .onKeyPreIme((e: KeyEvent) => {
      const esc: boolean = e.keyCode === KeyCode.KEYCODE_ESCAPE;
      /* 无条件记录日志：一个祖先的 onKeyPreIme 在后代 TextInput 持有焦点时是否触发，正是这个修复
       * 所依赖的前提 —— 万一 ESC 再次出问题，这些行会说明那个前提是否成立。 */
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
        /* 和上面那个钩子同样的动作，留作一张网，用于键从跳过 onKeyPreIme 的路径到达的情况；
         * 两种情况下都返回 true，因为 HarmonyOS 绝不能把 ESC 当作返回。 */
        this.appendCmd('E' + '\n');
        this.dismissIme();
        return true;
      }
      return esc;
    })
  }
}
