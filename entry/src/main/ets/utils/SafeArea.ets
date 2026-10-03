/* 异形屏（挖孔 / 刘海 / 曲面边缘）探测量 —— 单位一律 **vp**。
 *
 * 为什么需要它
 *   沉浸模式（Index.ets 的 enterImmersive）把两条系统栏拿掉之后，窗口四边就是**物理边界**。
 *   于是挖孔与曲面边缘会直接压在启动器自己的内容上 —— 顶部标签、设置页第一行、弹窗标题都可能
 *   落在孔里。⚠️ 游戏画面不归这里管：那由游戏自带的「适应刘海显示」开关负责（见 docs/FAQ.md）。
 *
 * ⭐ 数据来源是 `display.getCutoutInfo()`：
 *     · `boundingRects`            —— 挖孔 / 刘海（没有则**空数组**）
 *     · `waterfallDisplayAreaRects` —— 曲面屏边缘（left / right / top / bottom 各一个矩形）
 *   ⚠️ 两个 API 给的矩形都是 **px**，而布局用 **vp** ⇒ 这里统一换算后再交出去。
 *
 * ⛔ 这里【不】按机型兜底。多数平板的 `boundingRects` 是空的 ⇒ 探测结果就是 0 ⇒ 与从前一样。
 *    需要避让的平板由用户在设置里用滑条自己调（用户 2026-10-03 定的：不编一张会过期的机型表，
 *    因为错判的代价是**每一台**平板都多出一圈空白）。
 *
 * ⚠️ 探测只是**建议值**：滑条才是最终值（用户 2026-10-03 选的是「覆盖」语义）。
 *    所以本模块不关心用户最终选了多少，只回答「这台机器看起来需要让开多少」。
 */
import { display } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

const DOMAIN = 0x0000;
const TAG = 'MindustryLauncher';

/** 四边各让开多少，vp。0 表示不让。 */
export interface SafeInsets {
  top: number;
  right: number;
  bottom: number;
  left: number;
}

/* 判定「这个矩形贴着某条边」的容差（px）。
 * ⚠️ 不能要求恰好等于 0：实测里刘海矩形的 top 不一定是 0（状态栏区域先占了几个像素），
 *    而曲面屏那条的 left/right 也可能有个小偏移。8px 远超任何合理的边缘贴合误差，
 *    又远小于「一个明显在屏幕中间的元素」到边的距离。 */
const EDGE_TOLERANCE_PX = 8;

function emptyInsets(): SafeInsets {
  return { top: 0, right: 0, bottom: 0, left: 0 };
}

/** 逐边取最大 —— 多个矩形可能压在同一条边上（例如两个挖孔并排）。 */
function raise(ins: SafeInsets, edge: string, vp: number): void {
  const v: number = Math.max(0, Math.round(vp));
  if (edge === 'top' && v > ins.top) { ins.top = v; }
  if (edge === 'right' && v > ins.right) { ins.right = v; }
  if (edge === 'bottom' && v > ins.bottom) { ins.bottom = v; }
  if (edge === 'left' && v > ins.left) { ins.left = v; }
}

/** 一个矩形对它**贴着的那条（些）边**贡献多少 vp；没贴边就不贡献。
 * 贴顶的矩形贡献 `top + height`（它从边缘往里占了这么多），不是只贡献 height。 */
function feedRect(ins: SafeInsets, r: display.Rect, screenW: number, screenH: number): void {
  const leftPx: number = r.left;
  const topPx: number = r.top;
  const rightPx: number = screenW - (r.left + r.width);
  const bottomPx: number = screenH - (r.top + r.height);

  if (topPx <= EDGE_TOLERANCE_PX) {
    raise(ins, 'top', px2vp(r.top + r.height));
  }
  if (bottomPx <= EDGE_TOLERANCE_PX) {
    raise(ins, 'bottom', px2vp(r.height));
  }
  if (leftPx <= EDGE_TOLERANCE_PX) {
    raise(ins, 'left', px2vp(r.left + r.width));
  }
  if (rightPx <= EDGE_TOLERANCE_PX) {
    raise(ins, 'right', px2vp(r.width));
  }
}

/** 曲面屏那条边：矩形本身**就是**那条边上的不可用带 ⇒ 它的厚度（或宽度）就是让开的量。 */
function feedEdge(ins: SafeInsets, edge: string, r: display.Rect | undefined): void {
  if (r === undefined) {
    return;
  }
  if (edge === 'left' || edge === 'right') {
    raise(ins, edge, px2vp(r.width));
  } else {
    raise(ins, edge, px2vp(r.height));
  }
}

/** 探测这台机器建议让开多少。任何一步失败 ⇒ 全 0（**不是**抛异常）。 */
export async function detectInsets(): Promise<SafeInsets> {
  const ins: SafeInsets = emptyInsets();
  try {
    const d: display.Display = display.getDefaultDisplaySync();
    const screenW: number = d.width;
    const screenH: number = d.height;
    const info: display.CutoutInfo = await d.getCutoutInfo();

    /* ⚠️ 逐条记日志，因为「探测不到」和「探测到了但看起来没生效」在屏幕上长得一样，
     * 而这两件事的修法完全不同（前者调滑条，后者是布局没吃到 padding）。 */
    for (const r of info.boundingRects) {
      feedRect(ins, r, screenW, screenH);
    }
    feedEdge(ins, 'left', info.waterfallDisplayAreaRects?.left);
    feedEdge(ins, 'right', info.waterfallDisplayAreaRects?.right);
    feedEdge(ins, 'top', info.waterfallDisplayAreaRects?.top);
    feedEdge(ins, 'bottom', info.waterfallDisplayAreaRects?.bottom);

    hilog.info(DOMAIN, TAG,
      'safearea: screen %{public}dx%{public}dp, %{public}d cutout rect(s) -> '
      + 'top=%{public}d right=%{public}d bottom=%{public}d left=%{public}d (vp)',
      screenW, screenH, info.boundingRects.length,
      ins.top, ins.right, ins.bottom, ins.left);
    for (let i = 0; i < info.boundingRects.length; i++) {
      const r: display.Rect = info.boundingRects[i];
      hilog.info(DOMAIN, TAG, 'safearea:   rect[%{public}d] %{public}dx%{public}d @ %{public}d,%{public}d (px)',
        i, r.width, r.height, r.left, r.top);
    }
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'safearea: detection unavailable (%{public}s) -- assuming none', err.message);
  }
  return ins;
}

/** 四边取最大值 —— 滑条只有一个，所以最终要用一个数。
 * ⚠️ 取最大而不是取平均：四条边里**任意**一条被挡住都是缺陷，而取平均会把那条冲淡。 */
export function uniformOf(ins: SafeInsets): number {
  return Math.max(ins.top, ins.right, ins.bottom, ins.left);
}

/** 给人看的一行，用在日志与设置页的提示里。 */
export function describeInsets(ins: SafeInsets): string {
  return '上 ' + ins.top + ' / 右 ' + ins.right + ' / 下 ' + ins.bottom + ' / 左 ' + ins.left;
}
