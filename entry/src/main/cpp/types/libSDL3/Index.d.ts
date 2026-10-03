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
 * ⚠ 本文件**只影响类型检查**，不进代码生成、不进产物、不改运行行为 ——
 *     运行期一直是对的，只是类型声明漏了两个参数。
 * ⚠ 第四个参数写成**结构化的函数类型**而不引 `@ohos.multimodalInput.pointer`：
 *     它接的就是 `pointer.setPointerVisibleSync`（`(visible: boolean): void`），
 *     而不引包就不会因为 `.d.ts` 里的 import 而改变模块解析方式。 */
export const provideArkTSObjects: (ability: UIAbility, atManager: abilityAccessCtrl.AtManager, locale: intl.Locale, setPointerVisible: (visible: boolean) => void, imeController: inputMethod.InputMethodController) => void;
