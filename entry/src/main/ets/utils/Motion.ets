/* 入场动画的**唯一定义**。启动器的浮层与那些「就地出现」的控件都从这里取。
 *
 * ⛔ **退场刻意不做**（用户 2026-10-03：「入场要，退场不要」）。第二条理由是硬的：
 *    浮层**都能点遮罩关闭** ⇒ 退场期间那层遮罩还会**再吃掉一次点击**。
 * ⚠️ 用 `asymmetric(入场, 退场)` 表达，而不是只给一个 effect —— 单个 effect 会**同时**用在
 *    入场和退场，那样退场就有动画了。`TransitionEffect.IDENTITY` 就是「无效果」。
 * ⚠️ 浮层触发点都是 `if (state) { ... }` —— 那正是 `.transition()` 需要的形状。
 * ⚠️ `Curve` 与 `TransitionEffect` 是框架全局声明（与 `$r` 同类），不需要 import。 */

/** 淡入。浮层的遮罩、以及「就地出现/消失」的控件用它。 */
export function enterFade(duration: number = 150): TransitionEffect {
  return TransitionEffect.asymmetric(
    TransitionEffect.OPACITY.animation({ duration: duration, curve: Curve.Friction }),
    TransitionEffect.IDENTITY,
  );
}

/** 淡入 + 轻微放大。给**卡片**用 —— 只淡入时卡片只是跟着遮罩变亮，读不出「这张卡出现了」。
 * ⚠️ 代码**叠了** opacity（`.combine(TransitionEffect.OPACITY)`）；曾被搁置的备选是「只给 scale」，
 *    理由是两边都淡会让卡片滞后于遮罩。若哪天去掉那一层：删掉那行 `.combine(...)` 即可。 */
export function enterPop(duration: number = 180): TransitionEffect {
  return TransitionEffect.asymmetric(
    TransitionEffect.scale({ x: 0.96, y: 0.96 })
      .combine(TransitionEffect.OPACITY)
      .animation({ duration: duration, curve: Curve.FastOutSlowIn }),
    TransitionEffect.IDENTITY,
  );
}
