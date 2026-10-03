/* 异形屏（挖孔 / 刘海）探测量 —— 单位一律 **vp**。
 *
 * 为什么需要它
 *   沉浸模式（Index.ets 的 enterImmersive）把两条系统栏拿掉之后，窗口四边就是**物理边界**。
 *   于是挖孔 / 刘海会直接压在启动器自己的内容上 —— 顶部标签、设置页第一行、弹窗标题都可能
 *   落在孔里。⚠️ 游戏画面不归这里管：那由游戏自带的「适应刘海显示」开关负责（见 docs/FAQ.md）。
 *
 * ⭐ 数据来源是 `display.getCutoutInfo().boundingRects` —— 挖孔 / 刘海（没有则**空数组**）。
 *    ⚠️ 它给的矩形是 **px**，而布局用 **vp** ⇒ 这里统一换算后再交出去。
 *
 * ⛔ **只看挖孔，不看曲面。** `CutoutInfo` 还有一个 `waterfallDisplayAreaRects`（曲面屏边缘），
 *    2026-10-03 用户指出这是**不能避让**的：「没有哪个游戏会避让曲面屏区域」。
 *    两者的区别是本质的：
 *        · 挖孔 / 刘海 —— 屏幕上的一块**物理洞**，那儿的像素**根本不存在** ⇒ 必须让开；
 *        · 曲面边缘   —— 像素**存在**，只是弯的 ⇒ 内容本来就该铺到那儿，让开反而留下一圈死边。
 *    ⛔ 所以本文件**不读** `waterfallDisplayAreaRects`。别因为它「看起来也是避让区」就加回来。
 *
 * ⛔ 这里【不】按机型兜底。多数平板的 `boundingRects` 是空的 ⇒ 探测结果就是 0 ⇒ 与从前一样。
 *    需要避让的平板由用户在设置里用滑条自己调（用户 2026-10-03 定的：不编一张会过期的机型表，
 *    因为错判的代价是**每一台**平板都多出一圈空白）。
 *
 * ⚠️ 探测只是**建议值**：滑条才是最终值（用户 2026-10-03 选的是「覆盖」语义）。
 *    所以本模块不关心用户最终选了多少，只回答「这台机器看起来需要让开多少」。
 */
import { display, window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';

const DOMAIN = 0x0000;
const TAG = 'MindustryLauncher';

/* 探测结果落盘的地方 —— **native 侧的应用级目录**，hdc 读得到：
 *   hdc file recv /data/app/el2/100/base/com.haohandc.mindustryark/files/safearea.txt
 * ⛔ 为什么不用 hilog：实测（2026-10-03）本应用的 hilog 行**读不到** ——
 *    `hilog -x | grep -c MindustryLauncher` = 0，而同一条命令能抓到别的进程。
 *    而「探测不到」和「探测到了但没生效」在屏幕上长得一样，必须有**能读到的**记录才能分开。
 * ⚠️ 这个文件每次探测被覆盖，只留最近一次。 */
const NATIVE_DIR = '/data/storage/el2/base/files';
const DUMP_PATH = NATIVE_DIR + '/safearea.txt';

export function dumpSafeArea(text: string, append: boolean = false): void {
  try {
    const f: fs.File = fs.openSync(DUMP_PATH, append
      ? (fs.OpenMode.CREATE | fs.OpenMode.APPEND | fs.OpenMode.READ_WRITE)
      : (fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE));
    try {
      fs.writeSync(f.fd, text);
    } finally {
      fs.closeSync(f);
    }
  } catch (e) {
    /* 写不进去就算了 —— 它不是功能的一部分，只是诊断。 */
  }
}

/** 四边各让开多少，vp。0 表示不让。 */
export interface SafeInsets {
  top: number;
  right: number;
  bottom: number;
  left: number;
}

/* ⛔ 不要拿一个**固定像素数**当「贴边」的容差 —— 这个错误真的发生并出过货。
 *    2026-10-03 手机实测：挖孔 `352x84 @ 464,38`（**距顶 38px**），而我原先写的容差是 8px
 *    ⇒ `38 <= 8` 不成立 ⇒ 顶部那一支被跳过 ⇒ 这一个来源算出**全 0**。
 * ⭐ 改成**相对它自己的尺寸**判：一个宽 352、高 84 的洞，离顶只有 38px（不到它自己的一半高）
 *    就是贴着顶的；而一个在屏幕中间的元素离边的距离必然远大于它自己的尺寸。 */

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

  if (topPx < r.height) {
    raise(ins, 'top', px2vp(r.top + r.height));
  }
  if (bottomPx < r.height) {
    raise(ins, 'bottom', px2vp(r.height));
  }
  if (leftPx < r.width) {
    raise(ins, 'left', px2vp(r.left + r.width));
  }
  if (rightPx < r.width) {
    raise(ins, 'right', px2vp(r.width));
  }
}

/** 一条 AvoidArea 的四个矩形是否为空（全 0 尺寸即「没有」）。 */
function avoidAreaEmpty(a: window.AvoidArea): boolean {
  return a.topRect.height === 0 && a.bottomRect.height === 0
      && a.leftRect.width === 0 && a.rightRect.width === 0;
}

/** 探测这台机器建议让开多少。任何一步失败 ⇒ 全 0（**不是**抛异常）。
 * ⚠️ 需要 ctx：`window.getLastWindow()` 要一个 Context。
 *
 * 两个来源都问，结果都落盘：
 *   A. `display.getCutoutInfo().boundingRects`    —— 屏幕级，可能为空（实测手机上就是）
 *   B. `window.getWindowAvoidArea(TYPE_CUTOUT)`   —— **窗口级，分边给出**，多半才是准的那个
 * ⛔ 不合并两者的「最大值」就算完 —— 先把各自的原始值记下来，才能知道是哪一边在起作用。
 *    这个文件就是为「探测不到 vs 探测到了没生效」准备的那份证据。 */
export async function detectInsets(ctx: common.Context): Promise<SafeInsets> {
  const ins: SafeInsets = emptyInsets();
  const report: string[] = [];

  let screenW: number = 0;
  let screenH: number = 0;

  /* ── A. 屏幕级 getCutoutInfo ─────────────────────────────── */
  try {
    const d: display.Display = display.getDefaultDisplaySync();
    screenW = d.width;
    screenH = d.height;
    const info: display.CutoutInfo = await d.getCutoutInfo();
    report.push('screen        : ' + screenW + 'x' + screenH + ' px');
    report.push('A boundingRects: ' + info.boundingRects.length + ' 个');
    for (let i = 0; i < info.boundingRects.length; i++) {
      const r: display.Rect = info.boundingRects[i];
      report.push('    [' + i + '] ' + r.width + 'x' + r.height + ' @ ' + r.left + ',' + r.top + ' px');
      feedRect(ins, r, screenW, screenH);
    }
    report.push('A -> insets    : top=' + ins.top + ' right=' + ins.right
                + ' bottom=' + ins.bottom + ' left=' + ins.left + ' vp'
                + '   (fallback only -- B overrides it)');
  } catch (e) {
    const err = e as BusinessError;
    report.push('A getCutoutInfo FAILED: ' + err.message);
    hilog.warn(DOMAIN, TAG, 'safearea: getCutoutInfo failed (%{public}s)', err.message);
  }

  /* ── B. 窗口级 getWindowAvoidArea ──────────────────────────
   * ⭐ **B 优先，A 只是回退。** B 是操作系统对「这个窗口该让开多少」的直接回答；
   *    A 是我拿挖孔的绝对坐标去猜它贴着哪条边 —— 猜错过一次（见上面那段）。 */
  const before: SafeInsets = { top: ins.top, right: ins.right, bottom: ins.bottom, left: ins.left };
  try {
    const win: window.Window = await window.getLastWindow(ctx);
    const a: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT);
    report.push('B TYPE_CUTOUT  : topRect=' + a.topRect.width + 'x' + a.topRect.height
                + ' bottomRect=' + a.bottomRect.width + 'x' + a.bottomRect.height
                + ' leftRect=' + a.leftRect.width + 'x' + a.leftRect.height
                + ' rightRect=' + a.rightRect.width + 'x' + a.rightRect.height + ' px');
    if (!avoidAreaEmpty(a)) {
      /* B 给了答案 ⇒ **先清空 A 的结果再用它**，不是取两者最大。
       * ⛔ 取最大等于用我的猜测去盖 OS 的回答；实测两者就差着 10vp（A 的判据把
       *    「洞从 38px 开始」也算成要让的了）。 */
      ins.top = 0; ins.right = 0; ins.bottom = 0; ins.left = 0;
      if (a.topRect.height > 0) { raise(ins, 'top', px2vp(a.topRect.height)); }
      if (a.bottomRect.height > 0) { raise(ins, 'bottom', px2vp(a.bottomRect.height)); }
      if (a.leftRect.width > 0) { raise(ins, 'left', px2vp(a.leftRect.width)); }
      if (a.rightRect.width > 0) { raise(ins, 'right', px2vp(a.rightRect.width)); }
      report.push('                (B answered -- A discarded)');
    }
    report.push('B -> insets    : top=' + ins.top + ' right=' + ins.right
                + ' bottom=' + ins.bottom + ' left=' + ins.left + ' vp');
  } catch (e) {
    const err = e as BusinessError;
    report.push('B getWindowAvoidArea FAILED: ' + err.message);
    hilog.warn(DOMAIN, TAG, 'safearea: getWindowAvoidArea failed (%{public}s)', err.message);
  }

  report.push('FINAL         : top=' + ins.top + ' right=' + ins.right
              + ' bottom=' + ins.bottom + ' left=' + ins.left + ' vp');
  report.push('               (A alone said top=' + before.top + ' left=' + before.left + ')');
  report.push('edges         : ' + JSON.stringify(edgesOf(ins)));
  dumpSafeArea(report.join('\n') + '\n');

  hilog.info(DOMAIN, TAG, 'safearea: top=%{public}d right=%{public}d bottom=%{public}d left=%{public}d (vp)',
             ins.top, ins.right, ins.bottom, ins.left);
  return ins;
}

/** 四边里最大的那个 —— 滑条只有一个，所以要用一个数。 */
export function uniformOf(ins: SafeInsets): number {
  return Math.max(ins.top, ins.right, ins.bottom, ins.left);
}

/** 探测**命中**了哪几边（值 > 0 的）。返回固定的四字串数组顺序，便于比较与显示。
 * ⭐ 它决定滑条的值作用在哪些边上（用户 2026-10-03 定：「只用在探测到的那几边」）——
 * 顶部一个挖孔不该逼着左右下也白让。
 * ⚠️ 空数组是**有意义的**：那表示这台机器什么都探测不到。调用方必须为此单独定行为 ——
 * 见 LauncherHome.edgeVp()：那种情况四边都让，否则滑条在**最需要它的机器上**恰好失效。 */
export function edgesOf(ins: SafeInsets): string[] {
  const out: string[] = [];
  if (ins.top > 0) { out.push('top'); }
  if (ins.right > 0) { out.push('right'); }
  if (ins.bottom > 0) { out.push('bottom'); }
  if (ins.left > 0) { out.push('left'); }
  return out;
}
