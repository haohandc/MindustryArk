/* 应用自己的显示名 —— 界面上每一处要打印「本应用叫什么」的地方都从这里取。
 *
 * ⛔ **不要硬编码应用名**：同一份代码装在两个应用里（Mindustry Ark / Ark Launcher），硬编码意味着
 *    其中一边必然写错，而写错的地方正是【用户看得见的那几行】。2026-10-03 实测：设置页 About 走
 *    资源、游戏里的 About 写死 ⇒ 改名后同屏两处 About 显示两个名字。
 * ⭐ 走资源才能与**文件管理器给那个 Download 子文件夹看的名**同源（磁盘上是包名、界面显示应用名，
 *    对不上正是玩家找不到文件夹的成因）—— 见 LauncherHome 的 `jarDirHuman` 与 RELEASE-MAINTENANCE.md 对照表。
 * ⚠️ `ctx` 从参数传进来而不在这里调 `getContext()`：本项目每处都写 `getContext(this)`，而 `this` 只有组件里才有（`$r` 是全局 `declare function`，没这问题）。 */
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

const DOMAIN = 0x0000;
const TAG = 'MindustryLauncher';

/** 本应用在界面上显示的名字；拿不到时是空串。 */
export function appLabel(ctx: common.Context): string {
  try {
    return ctx.resourceManager.getStringSync($r('app.string.EntryAbility_label').id);
  } catch (e) {
    const err = e as BusinessError;
    hilog.info(DOMAIN, TAG, 'label: cannot read the app label (%{public}s)', err.message);
    return '';
  }
}
