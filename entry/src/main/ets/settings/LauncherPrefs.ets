/* 启动器自己的界面偏好。
 *
 * ⭐ 内容宽度**曾经**在这里；用户 2026-10-02「首页固定在 30%，存档固定在 100%，设置固定在
 *   100%」⇒ 宽度成了每个页签自己的固定值（见 LauncherHome 的 gamesWidthVp），本文件只剩
 *   「启动后进哪里」一项。⛔ 别把宽度那套再搬回来。
 * 为什么单独一个文件：它是**界面偏好**不是游戏知识，混进 GameLibrary 会让那里同时管两件事。
 * 为什么用纯文本而非 preferences：本项目每个跨启动状态都是文件（`control_mode.txt`、
 * `selected_game.txt`、`user_dirs.txt`、`jvm.options`），且都是「ArkTS 写、native 或下次启动读」
 * —— 再引入 Preferences 只多一种要理解的东西，没多出任何能力。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';

const DOMAIN = 0x0000;
const TAG = 'MindustryLauncher';

/* ====================================================================
 * 启动后进哪里
 * ==================================================================== */

const MODE_FILE_NAME = 'launch_mode.txt';

/** 先进启动器界面。 */
export const LAUNCH_MODE_HOME: string = 'home';
/** 直接进游戏（选中的 jar 存在时）。 */
export const LAUNCH_MODE_GAME: string = 'game';

/* 出厂值 = **先进首页**，2026-10-01 用户被卡住之后定的：他选了一个 **mod 当游戏**，于是每次
 * 打开都直接进游戏树、立刻闪退，且**没有任何界面能让他改回来**。检测机制（GameLibrary 的
 * launch_pending）现在能把他送回启动器，但**先进首页**是唯一不依赖检测机制也一定出得来的
 * 选择。代价是每次启动多一次点击（要换回直接进游戏就改成 LAUNCH_MODE_GAME，或拨设置里的开关）。 */
export const LAUNCH_MODE_DEFAULT: string = LAUNCH_MODE_HOME;

/** 读启动模式。文件不存在或内容不认识时给出厂值。
 * ⚠️ 不认识的值【不报错、也不静默当成另一个有效值】—— 记一条日志再回退到默认：
 *    「降级默认值」会把「读错了」掩盖成「看起来正常」，本项目为此付过代价。 */
export function readLaunchMode(filesDir: string): string {
  const path: string = filesDir + '/' + MODE_FILE_NAME;
  try {
    if (!fs.accessSync(path)) {
      return LAUNCH_MODE_DEFAULT;
    }
    const raw: string = fs.readTextSync(path).trim();
    if (raw === LAUNCH_MODE_HOME || raw === LAUNCH_MODE_GAME) {
      return raw;
    }
    hilog.warn(DOMAIN, TAG, 'prefs: launch mode "%{public}s" is not usable -- using the default', raw);
    return LAUNCH_MODE_DEFAULT;
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'prefs: reading the launch mode failed (%{public}s)', err.message);
    return LAUNCH_MODE_DEFAULT;
  }
}

/** 写启动模式。只接受两个已知值，其余当作非法并拒绝。 */
export function writeLaunchMode(filesDir: string, mode: string): void {
  if (mode !== LAUNCH_MODE_HOME && mode !== LAUNCH_MODE_GAME) {
    hilog.error(DOMAIN, TAG, 'prefs: refusing to write an unknown launch mode "%{public}s"', mode);
    return;
  }
  const path: string = filesDir + '/' + MODE_FILE_NAME;
  try {
    const f: fs.File = fs.openSync(path,
      fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE);
    try {
      fs.writeSync(f.fd, mode + '\n');
    } finally {
      fs.closeSync(f);
    }
    hilog.info(DOMAIN, TAG, 'prefs: launch mode -> %{public}s', mode);
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'prefs: saving the launch mode failed (%{public}s)', err.message);
  }
}

/* ====================================================================
 * 深色模式
 * ==================================================================== */

const APPEARANCE_FILE_NAME = 'appearance.txt';

/** 界面外观偏好。`follow` = 跟随系统（玩家没管过），否则用 `dark`。 */
export interface AppearancePref {
  follow: boolean;
  dark: boolean;
}

/* 文件里一行两个词：`auto dark` / `auto light` / `manual dark` / `manual light`。
 *
 * ⭐ 格式与 `SafePref` 那套**故意一样**（`auto` / `user` + 一个值），因为它们是同一族问题：
 *    「玩家管过这件事没有」。两处写成一个形状，读代码的人只需要理解一次。
 *
 * ⚠️ `auto` 时那个 dark 值**仍然写进去** —— 它不参与判断，只为了让这个文件自己可读
 *    （诊断时要能看出「跟随系统时系统当时是什么」）。同 `writeSafePref` 对 vp 的做法。
 *
 * ⛔ **这份偏好是必须的，不是锦上添花**：`ApplicationContext.setColorMode()` 只对
 *    **当前进程**有效，进程一重启就回到系统默认。⇒ 想把「强制深色」保住，就得自己记住它，
 *    并在每次启动后重新应用一次（见 LauncherHome 的 `applyColorMode`）。 */
function parseAppearance(raw: string): AppearancePref {
  const parts: string[] = raw.trim().split(/\s+/);
  if (parts.length >= 2 && (parts[0] === 'auto' || parts[0] === 'manual')) {
    const dark: boolean = parts[1] === 'dark';
    /* 第二个词只认 dark/light；写别的说明这个文件不是我们写的 ⇒ 整条当读不懂。 */
    if (parts[1] === 'dark' || parts[1] === 'light') {
      return { follow: parts[0] === 'auto', dark: dark };
    }
  }
  return { follow: true, dark: false };
}

/** 读外观偏好。文件不在或读不懂 ⇒ **跟随系统**（= 本项目一直以来的行为）。 */
export function readAppearance(filesDir: string): AppearancePref {
  const path: string = filesDir + '/' + APPEARANCE_FILE_NAME;
  try {
    if (!fs.accessSync(path)) {
      return { follow: true, dark: false };
    }
    return parseAppearance(fs.readTextSync(path));
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'prefs: reading the appearance failed (%{public}s)', err.message);
    return { follow: true, dark: false };
  }
}

/** 写外观偏好。 */
export function writeAppearance(filesDir: string, follow: boolean, dark: boolean): void {
  const path: string = filesDir + '/' + APPEARANCE_FILE_NAME;
  try {
    const f: fs.File = fs.openSync(path,
      fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE);
    try {
      fs.writeSync(f.fd, (follow ? 'auto ' : 'manual ') + (dark ? 'dark' : 'light') + '\n');
    } finally {
      fs.closeSync(f);
    }
    hilog.info(DOMAIN, TAG, 'prefs: appearance -> %{public}s %{public}s',
               follow ? 'auto' : 'manual', dark ? 'dark' : 'light');
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'prefs: saving the appearance failed (%{public}s)', err.message);
  }
}

/* ====================================================================
 * 游戏语言是否跟随系统
 * ==================================================================== */

const GAME_LOCALE_FILE_NAME = 'game_locale.txt';

/* 文件里就一个词：`auto`（跟随系统）/ `manual`（不动）。
 * ⭐ 格式与 `AppearancePref` / `SafePref` **故意一样**（`auto` / `manual` 一族），
 *    它们是同一类问题：「这件事由系统定还是由你定」。
 *
 * ⭐ **出厂 `auto`（跟随系统）** —— 用户 2026-10-04 定的。
 *
 * ⚠️ **这是启动器补的一个能力，不是修缺陷**（用户 2026-10-04 纠正过：「这不是缺陷，正常
 *    mindustry 就没有跟随」）。Mindustry 本来就没有「跟随系统」这个设置项：它的语言就是
 *    `settings.bin` 里那个值，`default` 的含义是「用 JVM 的默认 locale」。
 *    本启动器此前没给 JVM 传 locale ⇒ C locale ⇒ 那个 `default` 落在英文上。
 *    出厂打开，是为了让中文设备上开箱就是中文。 */
export const GAME_LOCALE_FOLLOW: boolean = true;

/** 读「游戏语言是否跟随系统」。文件不在或读不懂 ⇒ **跟随系统**（出厂值）。 */
export function readGameLocaleFollow(filesDir: string): boolean {
  const path: string = filesDir + '/' + GAME_LOCALE_FILE_NAME;
  try {
    if (!fs.accessSync(path)) {
      return GAME_LOCALE_FOLLOW;
    }
    const raw: string = fs.readTextSync(path).trim();
    if (raw === 'auto') {
      return true;
    }
    if (raw === 'manual') {
      return false;
    }
    /* ⚠️ 认不出的值**不静默当成某一个** —— 记一条再回退（`readLaunchMode` 那条同款）。 */
    hilog.warn(DOMAIN, TAG, 'prefs: game locale file says "%{public}s" -- following the system', raw);
    return GAME_LOCALE_FOLLOW;
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'prefs: reading the game locale failed (%{public}s)', err.message);
    return GAME_LOCALE_FOLLOW;
  }
}

/** 写「游戏语言是否跟随系统」。 */
export function writeGameLocaleFollow(filesDir: string, follow: boolean): void {
  const path: string = filesDir + '/' + GAME_LOCALE_FILE_NAME;
  try {
    const f: fs.File = fs.openSync(path,
      fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE);
    try {
      fs.writeSync(f.fd, (follow ? 'auto' : 'manual') + '\n');
    } finally {
      fs.closeSync(f);
    }
    hilog.info(DOMAIN, TAG, 'prefs: game locale -> %{public}s', follow ? 'auto' : 'manual');
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'prefs: saving the game locale failed (%{public}s)', err.message);
  }
}

/* ====================================================================
 * 游戏内显示（写进游戏自己的 settings.bin）
 * ==================================================================== */

const GAME_DISPLAY_FILE_NAME = 'game_display.txt';

/* ⛔⛔ **两个量程都是从游戏自己的界面抄来的，别自己编** —— 来源 `SettingsMenuDialog`：
 *      `sliderPref("uiEdgePadding", 0, 0, 100, …)` ⇒ 默认 0、0~100
 *      `sliderPref("uiscale", getInt("uiscale", 100), 25, 300, 5, …)` ⇒ 默认 100、25~300、步长 5
 * ⭐ 用它的量程意味着：**启动器设不出游戏自己的 UI 都设不出的值。** */
/* ⛔⛔ **`*_FACTORY` 与「启动器想让它是什么」是【两件不同的事】，别合并成一个常量。**
 *    `*_FACTORY` = **游戏自己的**默认值 ⇒ 只有一个用途：判断「玩家碰过这个设置没有」。
 *    而「启动器出厂想让它是什么」= `GAME_DISPLAY_DEFAULT`（下面）。
 * ⚠️⚠️ 把它们当成一个数的后果是**静默失效**：一旦哪天把启动器的出厂值调成 70/200
 *    （用户已经调好的值），`untouched` 就会拿 70 去比一份全新游戏的 `0` ⇒ 判定「玩家改过」
 *    ⇒ **永远不写**，而现象只是「这个功能忽然不生效」，看不出因果。
 *    ⇒ 判据：**「什么算没被碰过」只由游戏决定，与我们的偏好无关。** */
export const GAME_EDGE_FACTORY: number = 0;
export const GAME_SCALE_FACTORY: number = 100;

/* 量程照抄游戏自己的滑条（见上），⛔ 别自己放宽 —— 那会让启动器设出游戏 UI 都设不出的值。 */
export const GAME_EDGE_MIN: number = 0;
export const GAME_EDGE_MAX: number = 100;
export const GAME_SCALE_MIN: number = 25;
export const GAME_SCALE_MAX: number = 300;
export const GAME_SCALE_STEP: number = 5;

/** 要写进游戏的两个值。 */
export interface GameDisplayPref {
  /** `uiEdgePadding`：异形屏避让。 */
  edge: number;
  /** `uiscale`：UI 缩放（百分数）。 */
  scale: number;
  /** ⭐ **实验性**：避让值由系统参数（挖孔 + 密度）自动算出，而不是用上面的 `edge`。
   * ⛔ **出厂关闭**（用户 2026-10-04：「标注为实验性功能，这个不默认开启」）。
   * ⚠️ 自动模式**只接管避让**，不碰缩放 —— 依据见 `GameAutoFit.ets` 的文件头。 */
  auto: boolean;
}

/** 出厂值 = **游戏自己的默认值**（= 什么都不改变）。
 *
 * ⚠️⚠️ 这是刻意的、也是一个待办：用户要的是「启动器默认帮用户调好」，而**合适的数值我定不出来**
 *    —— 那取决于真机上游戏 HUD 与挖孔的位置关系，而我看不到屏幕。
 *    ⛔ 编一个数写进去，症状会是「游戏界面看起来坏了」，而玩家不知道是谁弄的。
 *    ⭐ 所以：量程与出厂值都照游戏默认，界面给他两个滑条去拖；他试出合适的数之后，
 *      **把那两个数改成这里的出厂值**，后面的用户就自动调好了。 */
export const GAME_DISPLAY_DEFAULT: GameDisplayPref = {
  edge: GAME_EDGE_FACTORY,
  scale: GAME_SCALE_FACTORY,
  auto: false,
};

/** 把数值夹进量程。⛔ 读文件与滑条两处都要走它 —— 文件是可以被改坏的。
 * ⚠️ 两个量程**必须分开传**：边距是 0~100，缩放是 25~300。第一版我写了「下限用边距的、
 *    上限用缩放的」那一个函数，两边都错 —— 那种一眼看不出的错正是要避免的。 */
function clampTo(v: number, min: number, max: number): number {
  if (!Number.isFinite(v)) {
    return min;
  }
  return v < min ? min : (v > max ? max : v);
}

/** 边距的量程夹取。 */
export function clampEdge(v: number): number {
  return clampTo(v, GAME_EDGE_MIN, GAME_EDGE_MAX);
}

/** UI 缩放的量程夹取。 */
export function clampScale(v: number): number {
  return clampTo(v, GAME_SCALE_MIN, GAME_SCALE_MAX);
}

/** 读「游戏内显示」偏好。文件不在或读不懂 ⇒ 出厂值。格式一行两个词：`edge=<n> scale=<n>`。 */
export function readGameDisplay(filesDir: string): GameDisplayPref {
  const path: string = filesDir + '/' + GAME_DISPLAY_FILE_NAME;
  try {
    if (!fs.accessSync(path)) {
      return GAME_DISPLAY_DEFAULT;
    }
    let edge: number = GAME_DISPLAY_DEFAULT.edge;
    let scale: number = GAME_DISPLAY_DEFAULT.scale;
    let auto: boolean = GAME_DISPLAY_DEFAULT.auto;
    let sawOne: boolean = false;
    for (const part of fs.readTextSync(path).trim().split(/\s+/)) {
      const eq: number = part.indexOf('=');
      if (eq <= 0) {
        continue;
      }
      const k: string = part.substring(0, eq);
      const raw: string = part.substring(eq + 1);
      if (k === 'auto') {
        auto = (raw === '1');
        sawOne = true;
        continue;
      }
      const n: number = Number.parseInt(raw, 10);
      if (!Number.isFinite(n)) {
        continue;
      }
      if (k === 'edge') {
        edge = n;
        sawOne = true;
      } else if (k === 'scale') {
        scale = n;
        sawOne = true;
      }
    }
    if (!sawOne) {
      /* ⚠️ 一个词都没认出来 ⇒ 当读不懂，记一条再回出厂值（`readLaunchMode` 那条同款）。 */
      hilog.warn(DOMAIN, TAG, 'prefs: game display file has nothing usable -- using defaults');
      return GAME_DISPLAY_DEFAULT;
    }
    return { edge: clampEdge(edge), scale: clampScale(scale), auto: auto };
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'prefs: reading the game display failed (%{public}s)', err.message);
    return GAME_DISPLAY_DEFAULT;
  }
}

/** 写「游戏内显示」偏好。 */
export function writeGameDisplay(filesDir: string, p: GameDisplayPref): void {
  const path: string = filesDir + '/' + GAME_DISPLAY_FILE_NAME;
  try {
    const f: fs.File = fs.openSync(path,
      fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE);
    try {
      /* ⛔⛔ **`auto` 必须写出来 —— 漏了它会让「自动适配」整个失效，而症状是静默的。**
       *    2026-10-04 真的漏了（那次改动经由脚本替换，替换没匹配上而 `str.replace` 不报错），
       *    后果连锁：`readGameDisplay` 读不到 `auto` ⇒ 回退 `false` ⇒ 下一次 `refresh()`
       *    把 `gameAuto` 复位成 false ⇒ **开关自己弹回去**，而 `applyGameDisplayNow`
       *    于是用**手动值**（0）去比 ⇒ 永远不写。玩家看到的是「拨上去、它自己回去了、游戏没变」。
       * ⭐ 判据：**读的那一侧加了字段，写的那一侧必须同时加** —— 两者不同步时，
       *    失败方向是「读到默认值」，而那与「玩家没设过」长得一模一样。 */
      fs.writeSync(f.fd, 'auto=' + (p.auto ? '1' : '0')
                       + ' edge=' + String(p.edge) + ' scale=' + String(p.scale) + '\n');
    } finally {
      fs.closeSync(f);
    }
    hilog.info(DOMAIN, TAG, 'prefs: game display -> auto=%{public}s edge=%{public}d scale=%{public}d',
               p.auto ? 'on' : 'off', p.edge, p.scale);
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'prefs: saving the game display failed (%{public}s)', err.message);
  }
}

/* 「**上次我们把它写成了什么**」—— ⛔ 这一个文件是「不覆盖玩家设置」那条规则的**全部依据**。
 *
 * ⭐ 判据（三个值一比就知道该不该动手）：
 *     游戏里那个值 == 出厂默认        ⇒ 玩家没碰过      ⇒ **写**
 *     游戏里那个值 == 我们上次写的     ⇒ 那是**我们的**值 ⇒ **写**（玩家改了启动器那边就该跟着变）
 *     其它                            ⇒ 玩家在游戏里改过了 ⇒ **不碰**
 * ⛔ 少了这个文件，就只能靠「是不是出厂默认」判断 —— 那样**启动器一旦写过一次，就再也改不动了**
 *    （值不再是默认、也不是我们认识的，于是永远被当成「玩家改的」）。
 * ⚠️ 它记的是**边距与缩放两个数**，不是「写过没有」这个布尔 —— 布尔分不出「我们写的是 40」与
 *    「我们写的是 60」。 */
const GAME_DISPLAY_APPLIED_FILE_NAME = 'game_display_applied.txt';

/** 上次写进游戏的值；从没写过 ⇒ `null`。 */
export function readAppliedGameDisplay(filesDir: string): GameDisplayPref | null {
  const path: string = filesDir + '/' + GAME_DISPLAY_APPLIED_FILE_NAME;
  try {
    if (!fs.accessSync(path)) {
      return null;
    }
    const raw: string = fs.readTextSync(path).trim();
    let edge: number = -1;
    let scale: number = -1;
    for (const part of raw.split(/\s+/)) {
      const eq: number = part.indexOf('=');
      if (eq <= 0) {
        continue;
      }
      const n: number = Number.parseInt(part.substring(eq + 1), 10);
      if (!Number.isFinite(n)) {
        continue;
      }
      if (part.substring(0, eq) === 'edge') {
        edge = n;
      } else if (part.substring(0, eq) === 'scale') {
        scale = n;
      }
    }
    if (edge < 0 || scale < 0) {
      return null;
    }
    /* ⚠️ `applied` 里**不**记 auto：它记的是「我们往游戏里写了什么数」，而 auto 只是
     * 「这个数是谁算出来的」。判据（不覆盖玩家设置）只用得上那两个数。 */
    return { edge: edge, scale: scale, auto: false };
  } catch (e) {
    return null;
  }
}

/** 记下我们刚写进游戏的值。 */
export function writeAppliedGameDisplay(filesDir: string, p: GameDisplayPref): void {
  const path: string = filesDir + '/' + GAME_DISPLAY_APPLIED_FILE_NAME;
  try {
    const f: fs.File = fs.openSync(path,
      fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE);
    try {
      fs.writeSync(f.fd, 'edge=' + String(p.edge) + ' scale=' + String(p.scale) + '\n');
    } finally {
      fs.closeSync(f);
    }
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'prefs: saving the applied game display failed (%{public}s)', err.message);
  }
}

/* ====================================================================
 * 异形屏避让（vp，四边统一一个值）
 * ==================================================================== */

const SAFE_FILE_NAME = 'launcher_safe_vp.txt';

/** 滑条上限（vp）。挖孔通常 20~30vp；64 已经是很宽的余量。 */
export const SAFE_VP_MAX = 64;
/** 滑条步长。4 的倍数足够细，又不会让手指难以停在整数上。 */
export const SAFE_VP_STEP = 4;

/** 避让设置。`auto` = 跟着探测走（玩家没管过），`vp` = 玩家自己定的值。 */
export interface SafePref {
  auto: boolean;
  vp: number;
}

/* 文件里一行两个词：`auto 24` / `user 32`。
 *
 * ⛔ **为什么需要这个标记，而不是「有文件就用文件里的值」**（那是第一版，坏了）：
 *    第一版是「只播种一次」—— 文件不存在时把探测结果写进去，之后就永远用文件里的值。
 *    而**前一版探测本身是坏的**（顶部的判据算错，永远得 0），于是那唯一一次播种
 *    把 0 写了进去 ⇒ 从此 `hasSafeVp()` 恒为真、**探测值再也不被采用**，
 *    界面上「建议 24」与滑条停在 0 同时成立。用户 2026-10-03 报的就是这个：
 *    「自动设置好异形屏避让没做」。
 * ⭐ 教训：一个「只发生一次」的动作，如果它的输入可能是错的，那它就会把错误永久固化。
 *    ⇒ 改成**状态**而不是**事件**：只要玩家没动过滑条，每次启动都重新采用探测结果。
 *
 * ⚠️ 旧格式（单独一个数字，没有标记）会被当成 `auto`。这是**刻意的迁移**：
 *    这个功能只存在过几小时，而唯一存在的旧文件正是那份被错误播种的 0。 */

function parseSafe(raw: string): SafePref {
  const parts: string[] = raw.trim().split(/\s+/);
  if (parts.length >= 2) {
    const v: number = Number.parseInt(parts[1], 10);
    if (parts[0] === 'user' && !Number.isNaN(v) && v >= 0 && v <= SAFE_VP_MAX) {
      return { auto: false, vp: v };
    }
    if (parts[0] === 'auto' && !Number.isNaN(v) && v >= 0 && v <= SAFE_VP_MAX) {
      return { auto: true, vp: v };
    }
  }
  /* 旧格式 / 读不懂 ⇒ 自动。见上面那段迁移说明。 */
  return { auto: true, vp: 0 };
}

/** 读避让设置。文件不在或读不懂 ⇒ 自动。 */
export function readSafePref(filesDir: string): SafePref {
  const path: string = filesDir + '/' + SAFE_FILE_NAME;
  try {
    if (!fs.accessSync(path)) {
      return { auto: true, vp: 0 };
    }
    return parseSafe(fs.readTextSync(path));
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'prefs: reading the safe pref failed (%{public}s)', err.message);
    return { auto: true, vp: 0 };
  }
}

/** 写避让设置。`auto` 时 vp 也写进去，只为了让这个文件自己可读（诊断用）。 */
export function writeSafePref(filesDir: string, auto: boolean, vp: number): void {
  const v: number = Math.max(0, Math.min(SAFE_VP_MAX, Math.round(vp)));
  const path: string = filesDir + '/' + SAFE_FILE_NAME;
  try {
    const f: fs.File = fs.openSync(path,
      fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE);
    try {
      fs.writeSync(f.fd, (auto ? 'auto ' : 'user ') + v + '\n');
    } finally {
      fs.closeSync(f);
    }
    hilog.info(DOMAIN, TAG, 'prefs: safe -> %{public}s %{public}d', auto ? 'auto' : 'user', v);
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'prefs: saving the safe pref failed (%{public}s)', err.message);
  }
}
