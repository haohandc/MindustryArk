/* 根据系统参数计算异形屏避让值（实验性功能）。
 * 避让公式：uiEdgePadding = ceil(挖孔内缩像素 / scl) + AUTO_EDGE_MARGIN。
 * 不修改 uiscale，GAME_SCALE_BASE = 150 为用户偏好。 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { display } from '@kit.ArkUI';
import { GAME_EDGE_MIN, GAME_EDGE_MAX, GAME_EDGE_FACTORY,
         GAME_SCALE_MIN, GAME_SCALE_MAX, GAME_SCALE_BASE } from '../settings/LauncherPrefs';

const DOMAIN = 0x0000;
const TAG = 'MindustryLauncher';

/* 额外补偿余量，使避让值在公式下限之上。先加余量再夹进量程。 */
const AUTO_EDGE_MARGIN: number = 24;

/* ================================================================
 * 界面缩放
 * ================================================================ */

/** 将系统字体缩放转换为游戏界面缩放基准值 150。
 * 当前因未声明 configuration 标签，fontScale 恒为 1，故返回 150。 */
export function systemGameScale(fontScale: number): number {
  if (!(fontScale > 0) || !Number.isFinite(fontScale)) {
    return GAME_SCALE_BASE;
  }
  const v: number = Math.round(GAME_SCALE_BASE * fontScale);
  if (v < GAME_SCALE_MIN) {
    return GAME_SCALE_MIN;
  }
  return v > GAME_SCALE_MAX ? GAME_SCALE_MAX : v;
}

/** 获取显示密度（vp→px比例），默认返回 1。 */
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

/** 游戏 UI 缩放因子，实现自 arc.scene.ui.layout.Scl.scl(float) 手机分支。 */
export function gameScl(density: number, uiscale: number): number {
  const base: number = Math.max(Math.round((density / 1.5) / 2) * 0.5, 1);
  const product: number = Math.max(uiscale, GAME_SCALE_MIN) / 100;
  return base * product;
}

/** 根据挖孔内缩像素计算避让值，无挖孔返回出厂值 0。
 * @param insetPx 像素值，调用方用 detectedSafeVp × density 得到。
 * @param uiscale 当前游戏 uiscale。
 * @returns 夹入量程的避让值。 */
export function autoEdgePadding(insetPx: number, density: number, uiscale: number): number {
  if (insetPx <= 0) {
    return GAME_EDGE_FACTORY;
  }
  const s: number = gameScl(density, uiscale);
  if (!(s > 0) || !Number.isFinite(s)) {
    return GAME_EDGE_FACTORY;
  }
  const v: number = Math.ceil(insetPx / s) + AUTO_EDGE_MARGIN;
  if (v < GAME_EDGE_MIN) {
    return GAME_EDGE_MIN;
  }
  return v > GAME_EDGE_MAX ? GAME_EDGE_MAX : v;
}
