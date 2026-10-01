/* [A]
 * 启动器自己的界面偏好 —— 目前只有一个：内容占窗口宽度的百分比。
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

/** [B] 一行纯文本，就是一个整数（百分数）。 */
const WIDTH_FILE_NAME = 'launcher_width_pct.txt';

/** [A]
 * 滑条的取值范围。
 *
 * ⚠️ 下限 20 而不是 0：内容再窄就没法用了（列表项的名字会被截成一个字）。
 * 用户要的是「自由调整」，但一个能把自己调成不可用的滑条不叫自由。
 *
 * 上限 60：用户 2026-10-01 定的是「**20-60，每10%一个挡位**」，
 * 而且滑条的 `step` 也是 10，两者必须对得上（否则圆点会落在没意义的刻度上）。
 */
export const WIDTH_PCT_MIN = 20;
export const WIDTH_PCT_MAX = 60;

/** [A]
 * 默认值。用户 2026-10-01 先要 30%，看过之后改成 **40%**。
 *
 * ⚠️ 它与 WIDTH_PCT_* 是两个不同的东西：那些是**允许的范围**，这是**出厂值**。
 * 把它们合成一个常量，就会在「用户调过之后」和「从没调过」之间失去区分。
 */
export const WIDTH_PCT_DEFAULT = 40;

/** [A]
 * 读回用户调过的宽度；没调过、或读不出来时给默认值。
 *
 * ⚠️ 所有失败路径都**静默回到默认值**，不抛、不中止。理由：这是一个界面偏好，
 * 它读不出来的后果应该是「这次按默认宽度显示」，而不是「启动器打不开」。
 * 越界值同样丢掉 —— 文件是玩家能碰到的，而一个 500% 的宽度会让界面直接消失。
 */
export function readWidthPct(filesDir: string): number {
  const path: string = filesDir + '/' + WIDTH_FILE_NAME;
  try {
    if (!fs.accessSync(path)) {
      return WIDTH_PCT_DEFAULT;
    }
    const raw: string = fs.readTextSync(path).trim();
    const v: number = Number.parseInt(raw, 10);
    if (Number.isNaN(v) || v < WIDTH_PCT_MIN || v > WIDTH_PCT_MAX) {
      hilog.warn(DOMAIN, TAG, 'prefs: width "%{public}s" is not usable -- using the default', raw);
      return WIDTH_PCT_DEFAULT;
    }
    return v;
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'prefs: reading the width failed (%{public}s)', err.message);
    return WIDTH_PCT_DEFAULT;
  }
}

/** [B] 记下宽度。同样静默失败 —— 存不下只是下次回到默认，不值得打断用户。 */
export function writeWidthPct(filesDir: string, pct: number): void {
  const path: string = filesDir + '/' + WIDTH_FILE_NAME;
  try {
    const f: fs.File = fs.openSync(path,
      fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE);
    try {
      fs.writeSync(f.fd, String(Math.round(pct)) + '\n');
    } finally {
      fs.closeSync(f);
    }
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'prefs: saving the width failed (%{public}s)', err.message);
  }
}
