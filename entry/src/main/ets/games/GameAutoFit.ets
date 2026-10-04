/* 由**系统参数**算出游戏该用的「异形屏避让」值。**实验性功能**（用户 2026-10-04 定：不默认开启）。
 *
 * ── 要解的那个方程 ──────────────────────────────────────────────────────────
 * 游戏把避让加在界面的边距上（`mindustry.core.UI.updateMargins()`）：
 * ```
 *   marginTop = insets[2] + Scl.scl(settings.getInt("uiEdgePadding", 0))
 * ```
 * 而 **`insets` 恒为 `{0,0,0,0}`** —— `arc.Graphics.getSafeInsets()` 在这个包里就是一个
 * `new int[4]`，**全包没有任何类覆写它**（2026-10-04 反编译核实）⇒ 游戏自己那套安全区是空转的，
 * 避让只能靠 `uiEdgePadding` 这一个数。
 *
 * ⭐ 而 `Scl.scl(f)` **不是**直接返回 `f`：它乘了一个缩放因子（同一份字节码）：
 * ```
 *   手机分支： scl = max(round((getDensity() / 1.5 + addition) / 2) * 0.5, 1) * (uiscale / 100)
 *   （addition 恒为 0 —— 全包没有任何类写它）
 *   返回：     f * scl
 * ```
 * ⇒ **避让的实际像素 = uiEdgePadding × scl**。要让界面让开挖孔，就要解：
 * ```
 *   uiEdgePadding = ceil(挖孔的内缩像素 / scl)
 * ```
 *
 * ⛔⛔ **缩放（`uiscale`）我们【不自动设】，这是有依据的取舍，不是漏了。**
 *    上面那个公式里 `getDensity()` 是**系统参数**，而 `uiscale/100` 是**玩家偏好乘数**
 *    —— 也就是说「UI 随屏幕自适应」**游戏本来就做了**，而且用的是 GL 层的真实密度，比我们在
 *    应用层读到的更准。我们再去设 `uiscale` 就是**与它叠加**，结果是「以为设了 X、实际是
 *    X×密度因子」，错位且无法向玩家解释。⇒ 自动适配**只给避让**。
 *    ⚠️ 顺带一个实测结论：密度 ≤ 7 时那个 `max(..., 1)` 把基底压成 1，
 *       所以现实中的手机上 **scl = uiscale/100**（uiscale=100 时 scl = 1，避让 1:1 就是像素）。
 *
 * ── 已知的取舍：算出来的值比实测最优【小】────────────────────────────────────
 * 用户 2026-10-04 在 Mate 80 Pro 上实测：避让拉到**满（100，游戏上限）效果最好**。
 * 而那台机器按本公式算出来是 **84**（挖孔内缩 24vp × 密度 3.5 = 84px，scl = 1 ⇒ 84）。
 * ⇒ 本公式给的是**下限**（刚好让开挖孔），实测最优在它之上 16px —— 那 16px 是「视觉余量」，
 *   本公式无法推导。⭐ 用户选的就是「按挖孔实算」。
 * ⭐⭐ **2026-10-04 的进展：那 16px 里已有 5px 变成显式常数** —— 用户定了
 *   `AUTO_EDGE_MARGIN = 5`（「我们避让，再默认多+5px」）⇒ 同一台机器上现在算出来 **89**。
 *   ⚠️ **与他偏好的 100 仍差 11**；要再调就调那一个常数，⛔ 不要动公式。
 * ⚠️ 另记一条：他那台是**顶到游戏上限**的 ⇒ 真最优可能大于 100，而游戏封顶了。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { display } from '@kit.ArkUI';
import { GAME_EDGE_MIN, GAME_EDGE_MAX, GAME_EDGE_FACTORY,
         GAME_SCALE_MIN } from '../settings/LauncherPrefs';

const DOMAIN = 0x0000;
const TAG = 'MindustryLauncher';

/* ⭐ 算出来的避让值**再多的那几像素**。
 *
 * ⛔ 它填的是这个公式自己承认的那个缺口（见文件头那段「已知的取舍」）：
 *    `ceil(内缩 / scl)` 给的是「**刚好**让开挖孔」的下限，而实测最优通常在它之上 ——
 *    多出来的那段是视觉余量，任何系统参数都推不出来，只能是个常数。
 * ⭐ 用户 2026-10-04 定它是 **5**：「我们避让，再默认多+5px。记得不要超限。」
 *
 * ⚠️ **它必须与「超限」一起考虑**：`uiEdgePadding` 游戏封顶 100（`SettingsMenuDialog`
 *    的滑条），所以 `autoEdgePadding` 是**先加这个数、再夹进量程**。
 *    在一台挖孔很大的机器上（比如算出来 98），加 5 会被夹回 100 —— 那是**有意的**：
 *    宁可顶到上限，也不要送一个游戏认不出的值进去。
 *
 * ℹ️ 实测参照（Mate 80 Pro）：内缩 24vp × 密度 3.5 = 84px ⇒ 84 + 5 = **89**。
 *    而用户在那台机上实测「最好」的是 **100**（游戏上限）—— 也就是说
 *    **89 仍然比他偏好的值小 11**。⇒ 若他后面说还是小，**改这一个常数**即可（10~16 都可能）。 */
const AUTO_EDGE_MARGIN: number = 5;

/** 显示密度（vp → px 的比例因子）。拿不到 ⇒ `1`。
 * ⚠️ 平台把它限制在 `[0.5, 4.0]`（`@ohos.display.d.ts` 的说明），所以它**不等于** dpi/160。
 * ⛔ 拿不到时返回 `1` 而不是 0：0 会让下面除出 Infinity。 */
export function displayDensity(): number {
  try {
    const d: display.Display = display.getDefaultDisplaySync();
    const v: number = d.densityPixels;
    return (v > 0.5 && v <= 8) ? v : 1;
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'autofit: cannot read the display density -- assuming 1');
    return 1;
  }
}

/** 游戏的 UI 缩放因子 —— ⛔ **抄自 `arc.scene.ui.layout.Scl.scl(float)` 的手机分支**，
 *  改这里必须同时改那边。`addition` 恒为 0（全包无人写它）。 */
export function gameScl(density: number, uiscale: number): number {
  const base: number = Math.max(Math.round((density / 1.5) / 2) * 0.5, 1);
  const product: number = Math.max(uiscale, GAME_SCALE_MIN) / 100;
  return base * product;
}

/** 由「挖孔内缩的像素」推出游戏的避让值。
 *
 * @param insetPx 界面要让开的像素（**px**，不是 vp）—— 调用方用 `detectedSafeVp × density` 得到。
 * @param density  `displayDensity()`。
 * @param uiscale  游戏**当前**的 `uiscale`（⛔ 不是我们想设的值 —— 我们不设它，所以取它现值）。
 * @returns 夹进游戏量程的避让值；推不出来（没有挖孔）⇒ 出厂值 0。 */
export function autoEdgePadding(insetPx: number, density: number, uiscale: number): number {
  if (insetPx <= 0) {
    return GAME_EDGE_FACTORY;      /* 这台机器没有挖孔要让 —— 不改变玩家的设置 */
  }
  const s: number = gameScl(density, uiscale);
  if (!(s > 0) || !Number.isFinite(s)) {
    return GAME_EDGE_FACTORY;
  }
  /* ⭐ 再**多让 5px**（用户 2026-10-04：「我们避让，再默认多+5px。记得不要超限。」）。
   * ⛔⛔ **这个余量不是我拍脑袋的，它填的正是这个公式自己承认的那个缺口** ——
   *    见下面的说明：算出来的是「**刚好**让开挖孔」的下限，而实测最优在它之上。
   * ⚠️ **「记得不要超限」= 加完之后再夹一次**：`uiEdgePadding` 游戏封顶 100，
   *    超了会被判成非法值（或静默截断），而那台机器的表现就是「比它能做到的最优还差」。
   *    ⇒ 顺序是**先加、后夹**，⛔ 不能反过来（先夹再加会让 100 变成 105）。 */
  const v: number = Math.ceil(insetPx / s) + AUTO_EDGE_MARGIN;
  if (v < GAME_EDGE_MIN) {
    return GAME_EDGE_MIN;
  }
  return v > GAME_EDGE_MAX ? GAME_EDGE_MAX : v;
}
