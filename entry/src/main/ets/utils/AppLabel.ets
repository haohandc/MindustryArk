/* 应用自己的显示名 —— 界面上每一处要打印「本应用叫什么」的地方都从这里取。
 *
 * ⛔ **不要硬编码应用名。** 同一份代码要装在两个应用里（Mindustry Ark / Ark Launcher），
 *    硬编码意味着其中一边必然写错，而写错的地方正是【用户看得见的那几行】。
 *    2026-10-03 实测到过一次：设置页的 About 走资源、游戏里的 About 写死，
 *    于是改名之后，同一块屏幕上两处 About 显示两个不同的名字。
 *
 * ⭐ 走资源还顺带保证它与**文件管理器给那个 Download 子文件夹看的名**同源 ——
 *    磁盘上那个文件夹叫包名（`ModImporter` 用 bundle 名创建），文件管理器却显示应用名。
 *    两者对不上正是「玩家照着界面去找、找不到文件夹」的成因，
 *    见 LauncherHome 的 `jarDirHuman` 与 RELEASE-MAINTENANCE.md 里那张对照表。
 *
 * ⚠️ 为什么把 context 作为参数传进来，而不是在这里调 `getContext()`：
 *    本项目每一处 `getContext` 都写成 `getContext(this)`，而 `this` 只有组件里才有。
 *    传进来就不必在这个文件里赌一个没有先例的调用形状。
 *    （`$r` 没这个问题：它是 `declare function`，全局的 —— SDK 的 component/common.d.ts。）
 *
 * ⚠️ 读不到时返回 `''`。调用方按「拿不到就退化」处理：比显示一个编出来的名字好，
 *    也比让 About 卡片把整页带崩好。
 */
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
