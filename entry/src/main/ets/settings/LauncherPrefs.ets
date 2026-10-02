/* [A]
 * 启动器自己的界面偏好。
 *
 * ⭐ 内容宽度**曾经**在这里（一个百分比 + 一条滑条）。用户 2026-10-02
 *   「那个不要了，首页就固定在30%，存档固定在100%，设置固定在100%」
 *   ⇒ 宽度成了每个页签自己的**固定值**（见 LauncherHome 的 gamesWidthVp），
 *   于是这个文件只剩「启动后进哪里」一项。⛔ 别把宽度那套再搬回来。
 *
 * 为什么单独一个文件
 *   它是**界面偏好**，不是游戏知识。放进 GameLibrary 会让那个文件同时管两件不相干的
 *   事（「加载哪个游戏」和「界面多宽」），而本项目已经在「一份知识存在两处、其中一处
 *   先跑偏」上栽过好几次。
 *
 * 为什么是一个纯文本文件，而不是 preferences
 *   这个项目读写的每一个跨启动状态都是文件（`control_mode.txt`、`selected_game.txt`、
 *   `user_dirs.txt`、`jvm.options`），而且每一个都是「ArkTS 写、native 或下一次启动读」。
 *   再引入一套 Preferences 存储，就多了一种要理解的东西而没有多出任何能力。
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

/** [B] 先进启动器界面。 */
export const LAUNCH_MODE_HOME: string = 'home';
/** [B] 直接进游戏（选中的 jar 存在时）。 */
export const LAUNCH_MODE_GAME: string = 'game';

/* [A]
 * 出厂值 = **先进首页**，而这是 2026-10-01 用户被卡住之后定的。
 *
 * ⚠️ 他被卡住的那一次：选了一个 **mod 当游戏**，于是每次打开都直接进游戏树、立刻闪退，
 * 而且**没有任何界面能让他改回来**。检测机制（见 GameLibrary 的 launch_pending）现在
 * 能把他送回启动器，所以「直接进游戏」不再是死路 —— 但**先进首页**是唯一
 * 不依赖检测机制也一定出得来的选择。
 *
 * ⚠️ 代价是每次启动多一次点击。要换回「直接进游戏」，把这里改成 LAUNCH_MODE_GAME，
 * 或者在设置里拨那个开关（拨完就写盘，覆盖这个默认值）。
 */
export const LAUNCH_MODE_DEFAULT: string = LAUNCH_MODE_HOME;

/** [A]
 * 读启动模式。文件不存在或内容不认识时给出厂值。
 *
 * ⚠️ 不认识的值【不报错、也不静默当成另一个有效值】—— 记一条日志再回退到默认。
 * 「降级默认值」会把「读错了」掩盖成「看起来正常」，本项目为此付过代价。
 */
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

/** [B] 写启动模式。只接受两个已知值，其余当作非法并拒绝。 */
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
