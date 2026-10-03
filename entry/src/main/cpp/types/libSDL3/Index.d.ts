import { abilityAccessCtrl, UIAbility } from '@kit.AbilityKit';
import { i18n } from '@kit.LocalizationKit';
import { inputMethod } from '@kit.IMEKit';

/* [A] 参数个数必须与 C 侧一致：**5 个**。
 *
 * ⛔⛔ 这一行之前只声明了 **3 个**，而 `EntryAbility.ets` 传 **5 个** ——
 *     两边从仓库建立那一天（`6fe1059`）起就是矛盾的，**从来没对上过**。
 *     后果：`Expected 3 arguments, but got 5` —— ArkTS 编译直接失败。
 *     ⚠ 之前一直没爆，是因为 `CompileArkTS` 命中了增量缓存，**从没真正重编过**；
 *     缓存一失效（清理、新克隆、改动 ArkTS 文件）就会露出来。
 *
 * ⭐ **谁对**：C 侧说了算 —— `SDL_openharmony.c:1161` 写着 `#define expected_argc 5`，
 *     且 `argc != 5` 时直接 `exit(1)`（"Script is out of sync? Aborting!"）。
 *     所以 `EntryAbility.ets` 那一行是对的，**错的是本文件**。
 *
 * ⭐⭐ 【为什么上面有三行 import】本文件原来**一个 import 都没有**，于是
 *     `UIAbility` / `abilityAccessCtrl` / `intl` 全是「找不到的名字」——
 *     它本来就不是一份能通过类型检查的声明（IDE 的 <ArkTSCheck> 报，构建不管）。
 *     补上 import 之后这几个名字才真正有定义。
 *     ⚠ `intl.Locale` 同时改成 `i18n.System`：调用方传的是 `i18n.System`
 *     （`@ohos.i18n.d.ts:125` 的 `export class System`），
 *     而 `intl` 是 ECMA-402 的那个全局，跟这一套没关系。
 *
 * ⚠ 本文件**只影响类型检查**，不进代码生成、不进产物、不改运行行为 ——
 *     运行期一直是对的，只是类型声明漏了两个参数。
 * ⚠ 第四个参数写成**结构化的函数类型**：它接的就是 `pointer.setPointerVisibleSync`
 *     （`@ohos.multimodalInput.pointer.d.ts:696`，`(visible: boolean): void`），
 *     结构化写法不需要再多一个 import。 */
export const provideArkTSObjects: (ability: UIAbility, atManager: abilityAccessCtrl.AtManager, locale: i18n.System, setPointerVisible: (visible: boolean) => void, imeController: inputMethod.InputMethodController) => void;
