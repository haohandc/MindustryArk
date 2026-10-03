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
 * 异形屏避让（vp，四边统一一个值）
 * ==================================================================== */

const SAFE_FILE_NAME = 'launcher_safe_vp.txt';

/** 滑条上限（vp）。挖孔通常 20~30vp，曲面屏边缘也在这个量级；64 已经是很宽的余量。 */
export const SAFE_VP_MAX = 64;
/** 滑条步长。4 的倍数足够细，又不会让手指难以停在整数上。 */
export const SAFE_VP_STEP = 4;

/** 有没有存过用户的选择。
 * ⭐ 它决定「首次」那一次：没存过才用探测值**播种**；存过就**完全听用户的**（覆盖语义）。
 * ⛔ 不能用「值等于 0」当没存过的判据 —— 用户可能就是想设成 0。 */
export function hasSafeVp(filesDir: string): boolean {
  try {
    return fs.accessSync(filesDir + '/' + SAFE_FILE_NAME);
  } catch (e) {
    return false;
  }
}

/** 读用户设定的避让量；没存过时返回 −1（调用方据此走「用探测值播种」那条路）。 */
export function readSafeVp(filesDir: string): number {
  const path: string = filesDir + '/' + SAFE_FILE_NAME;
  try {
    if (!fs.accessSync(path)) {
      return -1;
    }
    const raw: string = fs.readTextSync(path).trim();
    const v: number = Number.parseInt(raw, 10);
    if (Number.isNaN(v) || v < 0 || v > SAFE_VP_MAX) {
      hilog.warn(DOMAIN, TAG, 'prefs: safe vp "%{public}s" is not usable -- re-detecting', raw);
      return -1;
    }
    return v;
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'prefs: reading the safe vp failed (%{public}s)', err.message);
    return -1;
  }
}

/** 写避让量。越界一律拒绝（滑条不会越界，但文件是玩家能碰到的）。 */
export function writeSafeVp(filesDir: string, vp: number): void {
  if (!Number.isFinite(vp) || vp < 0 || vp > SAFE_VP_MAX) {
    hilog.error(DOMAIN, TAG, 'prefs: refusing to write an out-of-range safe vp %{public}d', vp);
    return;
  }
  const path: string = filesDir + '/' + SAFE_FILE_NAME;
  try {
    const f: fs.File = fs.openSync(path,
      fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE);
    try {
      fs.writeSync(f.fd, Math.round(vp) + '\n');
    } finally {
      fs.closeSync(f);
    }
    hilog.info(DOMAIN, TAG, 'prefs: safe vp -> %{public}d', Math.round(vp));
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'prefs: saving the safe vp failed (%{public}s)', err.message);
  }
}
