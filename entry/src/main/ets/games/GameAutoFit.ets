/* 由**系统参数**算出游戏该用的「异形屏避让」值。**实验性功能**（用户 2026-10-04 定：不默认开启）。
 * 游戏把避让加在 `mindustry.core.UI.updateMargins()` 的边距上：`避让像素 = uiEdgePadding × scl`；
 * 而 `arc.Graphics.getSafeInsets()` 在这个包里**恒为 `{0,0,0,0}`**（全包无覆写，2026-10-04 反编译核实）
 * ⇒ 游戏自己的安全区空转，避让只能靠 `uiEdgePadding` ⇒ 解 `uiEdgePadding = ceil(挖孔内缩像素 / scl)`。
 * ⛔ 「自动适配」**不碰** `uiscale`；`GAME_SCALE_BASE = 150` 是**用户实测的偏好**，与「算」无关 ——
 *    拿密度去推 `uiscale` 会与游戏自己的密度适配叠加（实测本机 density 3.5 ⇒ scl 基底 = 1.0）。
 * ⚠️ 公式给的是**下限**（刚好让开挖孔），实测最优在其上；那段视觉余量推不出来，见 `AUTO_EDGE_MARGIN`。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { display } from '@kit.ArkUI';
import { GAME_EDGE_MIN, GAME_EDGE_MAX, GAME_EDGE_FACTORY,
         GAME_SCALE_MIN, GAME_SCALE_MAX, GAME_SCALE_BASE } from '../settings/LauncherPrefs';

const DOMAIN = 0x0000;
const TAG = 'MindustryLauncher';

/* 算出来的避让值**再多给的那几像素**：补 `ceil(内缩/scl)` 只给「刚好让开挖孔」下限的缺口。
 * ⭐ 用户 2026-10-05 实测定 **24**（16→24；2026-10-04 定过的 5 已作废）。它不是从公式推的，
 *    是「他上机要的 80」减去公式给的下限 56。⚠️ 它加出来的是**游戏里那个 0..100 的整数，不是 px**。
 * ⛔ 先加余量、再夹进量程（游戏滑条封顶 100）：顺序反了会让上限失效。 */
const AUTO_EDGE_MARGIN: number = 24;

/* ====================================================================
 * 界面缩放：为什么基准是 150，以及「跟随系统」到底能跟随什么
 * ==================================================================== */

/** 把系统的**字体缩放**折进游戏的界面缩放：`GAME_SCALE_BASE`(150) 是基准，系统那项是相对倍率。
 * ⛔⛔ **今天它惰性恒等于 1（= 恒返回 150）**：`app.json5` 没声明 `configuration` 标签，
 *    缺省即「不跟随系统」⇒ `Configuration.fontSizeScale` 永远是 1（2026-10-05 实测量到 150）。
 * ⛔ 不在 app.json5 声明那个标签（2026-10-05 定）：它会让启动器自身整个 UI 也跟着放大。 */
export function systemGameScale(fontScale: number): number {
  if (!(fontScale > 0) || !Number.isFinite(fontScale)) {
    return GAME_SCALE_BASE;        /* 读不到系统值 ⇒ 就是基准，⛔ 不是 0 */
  }
  const v: number = Math.round(GAME_SCALE_BASE * fontScale);
  if (v < GAME_SCALE_MIN) {
    return GAME_SCALE_MIN;
  }
  return v > GAME_SCALE_MAX ? GAME_SCALE_MAX : v;
}

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

/** 由「挖孔内缩的像素」推出游戏的避让值；没有挖孔 ⇒ 出厂值 0。
 * @param insetPx 界面要让开的像素（**px**，不是 vp）—— 调用方用 `detectedSafeVp × density` 得到。
 * @param uiscale 游戏**当前**的 `uiscale`（⛔ 不是我们想设的值 —— 我们不设它，取现值）。
 * @returns 夹进游戏量程的避让值。 */
export function autoEdgePadding(insetPx: number, density: number, uiscale: number): number {
  if (insetPx <= 0) {
    return GAME_EDGE_FACTORY;      /* 这台机器没有挖孔要让 —— 不改变玩家的设置 */
  }
  const s: number = gameScl(density, uiscale);
  if (!(s > 0) || !Number.isFinite(s)) {
    return GAME_EDGE_FACTORY;
  }
  /* ⭐ 再**多让 `AUTO_EDGE_MARGIN`**（当前 24 —— 用户 2026-10-05 按实测定的）。
   * ⚠️ **先加、后夹**：`uiEdgePadding` 游戏封顶 100，顺序反了会让上限失效（100 会变 105）。 */
  const v: number = Math.ceil(insetPx / s) + AUTO_EDGE_MARGIN;
  if (v < GAME_EDGE_MIN) {
    return GAME_EDGE_MIN;
  }
  return v > GAME_EDGE_MAX ? GAME_EDGE_MAX : v;
}
