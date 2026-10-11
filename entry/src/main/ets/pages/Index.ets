import { abilityAccessCtrl, bundleManager, common, Permissions } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { KeyCode } from '@kit.InputKit';
import { window } from '@kit.ArkUI';
import { ensureModFolder, modFolderPath } from '../mods/ModImporter';
import { appLabel } from '../utils/AppLabel';
import { enterFade } from '../utils/Motion';
import { writeUserDirs } from '../entryability/EntryAbility';
import { publish as publishCrash, exportNow as exportDiagnosticsNow,
         readStartupLogTail } from '../diagnostics/ExportDiagnostics';
import { consumeLauncherRequest, requestLauncher, resolveGame, reportGameResolution,
         markLaunchAttempt, pendingLaunchAttempt, clearLaunchAttempt,
         GameResolution, bundledGamePath } from '../games/GameLibrary';
import { readLaunchMode, LAUNCH_MODE_HOME } from '../settings/LauncherPrefs';
import { computeKey, readGranularity, writeIsolationBridge } from '../settings/Isolation';
import { LauncherHome } from './LauncherHome';
import shield from 'libshield.so'; // 坚盾，全局变量 focusControl 无需导入

const DOMAIN = 0x0000;
const TAG = 'MindustryLauncher';

// 兼容模式：无匿名可执行内存时追加 -Xint
const JVM_OPTIONS_FILE_NAME = 'jvm.options';

// 启动器记录 JVM 是否拿到可执行内存，使用绝对路径
const EXEC_MEMORY_FILE = '/data/storage/el2/base/files/execmem';
const JVM_INCOMPLETE_FILE = '/data/storage/el2/base/files/jvm_incomplete';

// 失败弹窗日志尾巴上限
const FAULT_LOG_BYTES = 1200;
// 上次启动的日志，绝对路径
const STDERR_LOG_FILE = '/data/storage/el2/base/files/stderr.log';
/** 上一次启动测到的结果，''表示未测量 */
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
/** 日志中含 needle 的行 */
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
    /* 读不到即无此行 */
  }
  return '';
}
// 兼容模式猜测阈值
const MIN_API_FOR_JIT = 26;
// 强制兼容模式（仅用于测量，发布必须 false）
const FORCE_COMPAT_MODE = false;

// 无需运行时权限
const WANTED: Permissions[] = [
];

async function requestPerms(ctx: common.UIAbilityContext): Promise<void> {
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
      hilog.info(DOMAIN, TAG, 'permission %{public}s state before = %{public}d', p, state);
    }

    const res = await atm.requestPermissionsFromUser(ctx, WANTED);
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
        hilog.warn(DOMAIN, TAG,
          '  %{public}s: NOT GRANTED (authResult 2). dialogShown=%{public}s, '
          + 'errorReason=%{public}d',
          res.permissions[i], shown, reason);
      }
    }
  } catch (e) {
    const err = e as BusinessError;
    hilog.error(DOMAIN, TAG, 'permission request failed: %{public}s (code=%{public}d)', err.message, err.code);
  }
}

// IME 桥接文件路径（绝对路径）
const IME_WANT_FILE = '/data/storage/el2/base/files/ime_want';
const IME_CMD_FILE = '/data/storage/el2/base/files/ime_cmd';
const IME_RECT_FILE = '/data/storage/el2/base/files/ime_rect';

// 操作方案文件
const CONTROL_MODE_FILE_NAME = 'control_mode.txt';
const CONTROL_MODE_MOBILE = 'mobile';
const CONTROL_MODE_DESKTOP = 'desktop';

// 悬浮球尺寸参数（vp）
const BALL_SIZE_FALLBACK_VP = 48;
const BALL_SIZE_RATIO = 0.065;
const BALL_SIZE_MIN_VP = 48;
const BALL_SIZE_MAX_VP = 76;
const BALL_MARGIN_VP = 8;
const BALL_DRAG_SLOP_VP = 8;
const BALL_MENU_W_VP = 176;
const BALL_MENU_ROW_VP = 32;
const BALL_MENU_DIVIDER_VP = 1;
const BALL_MENU_PAD_VP = 16;
const BALL_MENU_ROWS = 4;
const BALL_MENU_H_VP = BALL_MENU_ROWS * BALL_MENU_ROW_VP
                     + (BALL_MENU_ROWS - 1) * BALL_MENU_DIVIDER_VP
                     + BALL_MENU_PAD_VP;
const BALL_MENU_FONT_VP = 16;
const BALL_MENU_HINT_FONT_VP = 14;

// 自动半隐藏参数
const BALL_HIDE_MS = 3000;
const BALL_HIDE_FRACTION = 0.6;
const BALL_OPACITY_HIDDEN = 0.45;

// 球位置文件
const BALL_POS_FILE_NAME = 'ball_pos.txt';

// 键盘收起后忽略游戏请求的截止时长
const IME_DISMISS_MS = 1500;

// 隐形文本框额外高度
const IME_FIELD_MARGIN_VP = 24;

@Entry
@Component
struct Index {
  @State showIme: boolean = false;
  private imeSent: string = '';
  private imeTimer: number = -1;
  private imeFieldFocused: boolean = false;
  @State imeUserHid: boolean = false;
  private imeDismissedUntil: number = 0;
  @State imeFieldX: number = 0;
  @State imeFieldY: number = 0;
  @State imeFieldW: number = 1;
  @State imeFieldH: number = 1;
  private imeWindow: window.Window | undefined = undefined;
  private pageGone: boolean = false;
  @State controlMode: string = CONTROL_MODE_MOBILE;
  @State ballX: number = 0;
  @State ballY: number = 0;
  @State ballPlaced: boolean = false;
  @State ballMenu: boolean = false;
  @State showAbout: boolean = false;
  @State showLauncher: boolean = false;
  private launcherBack: () => boolean = () => false;
  @State folderSettled: boolean = false;
  private launcherFilesDir: string = '';
  private launcherBundleDir: string = '';
  @State shieldBlocked: boolean = false;
  private shieldDiag: string = '';
  private jvmFaults: string = '';
  @State jvmIncomplete: boolean = false;
  @State launchFault: string = '';
  @State launchFaultJar: string = '';
  @State appVersion: string = '';
  @State appName: string = '';
  @State ballSizeVp: number = BALL_SIZE_FALLBACK_VP;
  @State ballHidden: boolean = false;
  private ballEdge: string = 'right';
  private ballHideTimer: number = -1;
  private ballRestoreX: number = -1;
  private ballRestoreY: number = -1;
  private ballWasHiddenOnDown: boolean = false;
  private winW: number = 0;
  private winH: number = 0;
  private dragBallX: number = 0;
  private dragBallY: number = 0;
  private dragTouchX: number = 0;
  private dragTouchY: number = 0;
  private dragMoved: boolean = false;

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    this.appName = appLabel(ctx);
    requestPerms(ctx).then(() => {
      this.enterImmersive();
    }).catch((e: BusinessError) => {
      hilog.warn(DOMAIN, TAG,
                 'permissions: unexpected rejection (%{public}s); immersive anyway',
                 e.message);
      this.enterImmersive();
    });
    ensureModFolder(ctx, ctx.filesDir + '/mod_folder')
      .then(() => {
        writeUserDirs(ctx.filesDir);
        publishCrash(modFolderPath(ctx.filesDir + '/mod_folder'), ctx.filesDir, this.appName);
        this.folderSettled = true;
      })
      .catch((e: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'mod folder setup failed: %{public}s', e.message);
      });
    this.clearStaleImeState();
    this.imeTimer = setInterval(() => { this.pollImeWant(); }, 200);
    this.watchKeyboardHeight();
    this.readControlMode();
    this.readBallPos();

    /* 记录坚盾诊断 */
    try {
      this.shieldDiag = shield.shieldDiagnosis();
    } catch (e) {
      const err = e as BusinessError;
      this.shieldDiag = 'call-failed: ' + err.message;
    }
    this.shieldBlocked = (this.shieldDiag === 'on');
    hilog.info(DOMAIN, TAG, 'shield diagnosis: %{public}s -> blocked=%{public}s',
      this.shieldDiag, String(this.shieldBlocked));

    /* 检查 JVM 残留标记 */
    try {
      this.jvmIncomplete = fs.accessSync(JVM_INCOMPLETE_FILE);
      if (this.jvmIncomplete) {
        const parts: Array<string> = [];
        const probe: string = logLine('mmap(RWX) FAILED');
        if (probe !== '') { parts.push(probe); }
        const forced: string = logLine('FORCING -Xint');
        if (forced !== '') { parts.push(forced); }
        const called: string = logLine('calling JNI_CreateJavaVM');
        if (called !== '') { parts.push(called); }
        if (logLine('CreateJavaVM (strict) returned') === '') {
          parts.push('(no return value -- the process died inside create)');
        }
        const verdict: string = launcherExecMemoryVerdict();
        parts.push('execmem: ' + (verdict === '' ? '(not measured)' : verdict));
        parts.push('shield now: ' + this.shieldDiag);
        this.jvmFaults = parts.join(String.fromCharCode(10));
        try {
          fs.unlinkSync(JVM_INCOMPLETE_FILE);
        } catch (e) {
          /* 忽略 */
        }
      }
    } catch (e) {
      this.jvmIncomplete = false;
    }

    this.decideStartup();
    this.setupCompatMode();
  }

  async enterImmersive(): Promise<void> {
    try {
      const ctx: common.UIAbilityContext | undefined = this.ballCtx();
      if (ctx === undefined) {
        return;
      }
      const win: window.Window = await window.getLastWindow(ctx);
      await win.setWindowSystemBarEnable([]);
      await win.setWindowLayoutFullScreen(true);
      win.setImmersiveModeEnabledState(true);
      hilog.info(DOMAIN, TAG, 'immersive: bars hidden, layout full-screen');
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG,
                 'immersive: not available (%{public}s) -- keeping the bars', err.message);
      return;
    }
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

  /* 测量键盘高度和文本框矩形，用于判断避让是否到位。try/catch 防止单一项错误导致页面崩溃。 */
  async watchKeyboardHeight(): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const win = await window.getLastWindow(ctx);
      /* await 后检查页面是否已销毁，防止注册到不存在的窗口（2026-10-05 修复） */
      if (this.pageGone) {
        return;
      }
      this.imeWindow = win;
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

  /* 清除上次运行的残留文件，防止轮询误判。ime_want 和 ime_cmd 必须删，ime_rect 保留。 */
  clearStaleImeState(): void {
    const stale: string[] = [IME_WANT_FILE, IME_CMD_FILE];
    for (const path of stale) {
      try {
        if (fs.accessSync(path)) {
          fs.unlinkSync(path);
          hilog.info(DOMAIN, TAG, 'ime: cleared a stale %{public}s from the previous run', path);
        }
      } catch (e) {
        const err = e as BusinessError;
        hilog.warn(DOMAIN, TAG, 'ime: could not clear %{public}s: %{public}s', path, err.message);
      }
    }
  }

  aboutToDisappear(): void {
    /* 先置标志再清理，顺序重要：watchKeyboardHeight 的异步回调依赖此标志检测页面销毁 */
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
      want = fs.accessSync(IME_WANT_FILE);
    } catch (e) {
      want = false;
    }
    /* 根据游戏请求状态决定键盘显示。用户主动关闭后需延迟重新响应 */
    if (!want) {
      if (this.showIme) {
        this.dismissIme();
      }
      this.imeDismissedUntil = 0;
      this.imeUserHid = false;
      return;
    }
    if (Date.now() < this.imeDismissedUntil) {
      return;
    }
    if (this.imeDismissedUntil !== 0) {
      hilog.warn(DOMAIN, TAG, 'IME dismissed %{public}dms ago but the game still wants text; the forwarded ESC did not release it', IME_DISMISS_MS);
      this.imeDismissedUntil = 0;
    }
    this.readImeRect();
    if (!this.showIme) {
      this.showIme = true;
      this.imeSent = '';
      setTimeout(() => {
        if (this.showIme) {
          focusControl.requestFocus('ime_ui_field');
        }
      }, 60);
    } else if (!this.imeFieldFocused && !this.imeUserHid) {
      focusControl.requestFocus('ime_ui_field');
    }
  }

  /* 给游戏 XComponent 请求焦点，保证实体键盘可用。需多次延迟请求。 */
  private focusClaimPending: boolean = false;

  private claimGameFocus(): void {
    if (this.focusClaimPending) {
      return;
    }
    this.focusClaimPending = true;
    const delays: number[] = [0, 120, 400, 900];
    for (const d of delays) {
      setTimeout(() => {
        if (this.showLauncher || this.shieldBlocked) {
          return;
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
    this.imeFieldFocused = false;
    focusControl.requestFocus('SDL_XComponent');
  }

  /* 读取游戏文本框矩形，并更新位置。无效数据不覆盖。像素转 VP。 */
  readImeRect(): void {
    let text: string = '';
    try {
      text = fs.readTextSync(IME_RECT_FILE);
    } catch (e) {
      return;
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
    const xvp: number = px2vp(x);
    const yvp: number = px2vp(y);
    const wvp: number = px2vp(w);
    const hvp: number = px2vp(h);
    if (xvp === this.imeFieldX && yvp === this.imeFieldY
        && wvp === this.imeFieldW && hvp === this.imeFieldH) {
      return;
    }
    this.imeFieldX = xvp;
    this.imeFieldY = yvp;
    this.imeFieldW = wvp;
    this.imeFieldH = hvp;
  }

  /* 读取控制模式文件，默认 mobile */
  readControlMode(): void {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const text: string = fs.readTextSync(ctx.filesDir + '/' + CONTROL_MODE_FILE_NAME);
      this.controlMode = text.trim() === CONTROL_MODE_DESKTOP
        ? CONTROL_MODE_DESKTOP : CONTROL_MODE_MOBILE;
    } catch (e) {
      this.controlMode = CONTROL_MODE_MOBILE;
    }
  }

  /* 导出诊断包至 Downloads 文件夹。 */
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
      return;
    }
    this.toast(next === CONTROL_MODE_DESKTOP
      ? '已切换为 PC 模式，重启游戏后生效'
      : '已切换为触屏模式，重启游戏后生效');
  }

  /* 显示短消息，避免失败连锁 */
  toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2600 });
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'toast failed (what it reported still happened): %{public}s',
                 err.message);
    }
  }

  /* 打开 About 卡片，读取版本号 */
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

  /* 记录窗口尺寸，初始化球位置 */
  onWindowSize(w: number, h: number): void {
    if (w <= 0 || h <= 0) {
      return;
    }
    this.winW = w;
    this.winH = h;
    this.ballSizeVp = Math.round(
      Math.min(Math.max(Math.min(w, h) * BALL_SIZE_RATIO, BALL_SIZE_MIN_VP), BALL_SIZE_MAX_VP));
    if (this.ballPlaced) {
      return;
    }
    const s: number = this.ballSizeVp;
    if (this.ballRestoreX >= 0 && this.ballRestoreY >= 0) {
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
      /* 先露出，不带动画。记录隐藏状态供后续判断 */
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
        return;
      }
      this.dragMoved = true;
      this.ballMenu = false;
      const s: number = this.ballSizeVp;
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
        this.scheduleBallHide();
      } else {
        this.ballMenu = !this.ballMenu;
        if (!this.ballMenu) {
          this.scheduleBallHide();
        }
      }
      this.dragMoved = false;
    }
  }

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

  snapBallToEdge(): void {
    if (this.winW <= 0 || this.winH <= 0) {
      return;
    }
    const s: number = this.ballSizeVp;
    const edge: string = this.nearestEdge();
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

  ballCtx(): common.UIAbilityContext | undefined {
    return this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
  }

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

  ballMenuX(): number {
    const right: number = this.ballX + this.ballSizeVp + 8;
    if (right + BALL_MENU_W_VP > this.winW) {
      return Math.max(0, this.ballX - BALL_MENU_W_VP - 8);
    }
    return right;
  }

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

  onBackPress(): boolean {
    if (this.showLauncher) {
      const handled: boolean = this.launcherBack();
      hilog.info(DOMAIN, TAG, 'back: the launcher screen had it, handled=%{public}s',
                 String(handled));
      return true;
    }
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
      if (prev.length > 0) {
        cmds += 'B' + prev.length + '\n';
      }
      cmds += 'T' + next + '\n';
    }
    this.imeSent = next;
    this.appendCmd(cmds);
  }

  private setupCompatMode(): void {
    let want: boolean = false;
    let kind: string = '?';
    let api: number = -1;
    let source: string = 'device rule';

    try {
      kind = deviceInfo.deviceType;
      api = deviceInfo.sdkApiVersion;
      want = kind === 'phone' && api < MIN_API_FOR_JIT;
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG,
        'deviceInfo unavailable (%{public}s) -- assuming the JIT works', err.message);
      kind = 'unavailable';
      want = false;
    }

    const verdict: string = launcherExecMemoryVerdict();
    if (verdict === 'interp') {
      want = true;
      source = 'launcher measured: no executable memory';
    } else if (verdict === 'jit') {
      want = false;
      source = 'launcher measured: executable memory available';
    }

    if (FORCE_COMPAT_MODE) {
      want = true;
      source = 'FORCE_COMPAT_MODE';
    }
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
        fs.unlinkSync(path);
        hilog.info(DOMAIN, TAG, 'compat mode off: removed %{public}s', path);
      }
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'could not set compat mode: %{public}s', err.message);
    }

  }

  /** 只在 aboutToAppear 调用。必须在 XComponent 挂载前执行，避免白启 JVM。native 也判一次。 */
  /* 构建失败原因：jvm_incomplete（JVM未创建）或 jar 内无游戏。附最后日志。 */
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

    /* 读并清除标记，避免永久门。 */
    const requested: boolean = consumeLauncherRequest(ctx.filesDir);

    const r: GameResolution = resolveGame(ctx.filesDir, ctx.bundleCodeDir);
    /* 记录决议，用于区分无游戏与内置路径错误。 */
    reportGameResolution(ctx.filesDir, ctx.bundleCodeDir, r);

    if (requested) {
      hilog.info(DOMAIN, TAG, 'startup: the launcher was requested -- showing it');
      this.showLauncher = true;
      return;
    }

    /* 上次启动未到游戏入口则回启动器显示原因。读后即删。 */
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

    /* 启动模式为首页时也显示启动器，排在失败判定之后。 */
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

  /** 启动游戏。参数为 jar 路径，'' 表示内置包。
   * 桥接必须在 XComponent 挂载前写完。 */
  private startGame(jarPath: string): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    writeUserDirs(ctx.filesDir);

    /* 记下尝试启动的 jar，空时自动解析——用于失败时显示哪个 jar 没起来。 */
    const res: GameResolution = resolveGame(ctx.filesDir, ctx.bundleCodeDir);
    const attempted: string = jarPath !== ''
      ? jarPath
      : res.path;
    markLaunchAttempt(ctx.filesDir, attempted);

    /* 隔离桥接：必须在 native main() 之前写入，确保键对应真正启动的 jar。 */
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
    /* 在此安排焦点：XComponent 将在下一帧构建，延迟请求正好落在建好之后。 */
    this.claimGameFocus();
  }

  /** 回启动器界面。不能直接 showLauncher，因为游戏已运行，摘掉 XComponent 会拆 surface。
   * 走退出握手：记意图 → terminateSelf。 */
  private backToLauncher(): void {
    const ctx = getContext(this) as common.UIAbilityContext;

    /* 先记意图再重启（restartApp 失败时的退路）。 */
    requestLauncher(ctx.filesDir);

    /* 清理启动标记，防止 native 未删时下一次误报。 */
    clearLaunchAttempt(ctx.filesDir);

    /* 使用 ApplicationContext.restartApp 重启进程（换游戏需重开 JVM）。
     * 失败则 fallback 到 terminateSelf。 */
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

    /* 退路：关掉自己，下次启动读标记进入启动器。 */
    ctx.terminateSelf().catch((err: BusinessError) => {
      hilog.error(DOMAIN, TAG, 'terminateSelf failed: %{public}s', err.message);
    });
  }
  build() {
    Stack({ alignContent: Alignment.Top }) {
    if (this.showLauncher) {
      LauncherHome({
        filesDir: this.launcherFilesDir,
        bundleCodeDir: this.launcherBundleDir,
        folderSettled: this.folderSettled,
        appVersion: this.appVersion,
        launchFault: this.launchFault,
        onLaunch: (jarPath: string) => { this.startGame(jarPath); },
        onForceLaunch: () => { this.startGame(''); },
        registerBack: (fn: () => boolean): void => { this.launcherBack = fn; },
      })
    } else {
    Row() {
      Column() {
        if (!this.shieldBlocked) {
          XComponent({ id: 'SDL_XComponent', type: XComponentType.SURFACE, libraryname: 'SDL3' })
            .id('SDL_XComponent')
            .focusable(true)
            .defaultFocus(true)
            .onAppear(() => { this.claimGameFocus(); })
            .onKeyPreIme((e: KeyEvent) => {
              hilog.info(DOMAIN, TAG, 'onKeyPreIme[X]: keyCode=%{public}d -> consumed=false (pass through)',
                e.keyCode);
              return false;
            })
        }
      }
      .width('100%')
      .onKeyEvent((e: KeyEvent) => {
        const esc = e.keyCode === KeyCode.KEYCODE_ESCAPE;
        hilog.info(DOMAIN, TAG, 'onKeyEvent[Column]: keyCode=%{public}d -> consumed=%{public}s',
          e.keyCode, String(esc));
        return esc;
      })
    }
    .height('100%')

      if (this.showIme) {
        TextInput()
          .id('ime_ui_field')
          .position({ x: this.imeFieldX, y: this.imeFieldY })
          .width(this.imeFieldW)
          .height(this.imeFieldH + (this.imeUserHid ? 0 : IME_FIELD_MARGIN_VP))
          .opacity(0)
          .onChange((v: string) => {
            this.sendDelta(v.replace(/[\r\n]/g, ''));
          })
          .onFocus(() => {
            this.imeFieldFocused = true;
            this.imeUserHid = false;
          })
          .onBlur(() => {
            if (this.imeFieldFocused) {
              this.imeUserHid = true;
            }
            this.imeFieldFocused = false;
          })
          .onSubmit(() => {
            this.dismissIme();
          })
      }

      Stack() {
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
      .position({ x: this.ballX + this.ballHideDx(), y: this.ballY + this.ballHideDy() })
      .opacity(this.ballHidden ? BALL_OPACITY_HIDDEN : 1)
      .focusable(false)
      .onTouch((e: TouchEvent) => { this.onBallTouch(e); })

      if (this.ballMenu) {
        Column() {
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

          Divider()
            .strokeWidth(BALL_MENU_DIVIDER_VP)
            .color('#22ffffff')

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
        .transition(enterFade(80))
      }
    if (this.showAbout) {
      Column() {
        Column() {
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
        .transition(enterFade())
        .onClick(() => {
          const ctx = getContext(this) as common.UIAbilityContext;
          ctx.terminateSelf().catch((err: BusinessError) => {
            hilog.error(DOMAIN, TAG, 'terminateSelf failed: %{public}s', err.message);
          });
        })
      }
    }
    }
    .onAreaChange((_o: Area, n: Area) => {
      this.onWindowSize(Number(n.width), Number(n.height));
    })
    .onKeyPreIme((e: KeyEvent) => {
      const esc: boolean = e.keyCode === KeyCode.KEYCODE_ESCAPE;
      /* 日志，调试 ESC 行为 */
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
        this.appendCmd('E' + '\n');
        this.dismissIme();
        return true;
      }
      return esc;
    })
  }
}