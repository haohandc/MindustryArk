/* 入场动画的**唯一定义**。启动器的浮层与那些「就地出现」的控件都从这里取。
 *
 * ⛔ **退场刻意不做**（用户 2026-10-03：「入场要，退场不要」）。两条理由，第二条是硬的：
 *    ① 关掉的东西还在慢慢淡出，会挡住下面的操作一百多毫秒；
 *    ② 我们的浮层**都能点遮罩关闭** ⇒ 退场期间那层遮罩还会**再吃掉一次点击**。
 *
 * ⚠️ 用 `asymmetric(入场, 退场)` 表达，而不是只给一个 effect ——
 *    单个 effect 会**同时**用在入场和退场，那样退场就有动画了，正是要避免的那个。
 *    SDK 的 `TransitionEffect.IDENTITY` 就是「无效果」，比写 `duration: 0` 明确。
 *
 * ⚠️ 所有浮层的触发点都是 `if (state) { ... }` —— 那正是 `.transition()` 需要的形状，
 *    所以这里只是一个**取值**，挂上去不改任何结构、也不改任何状态机。
 *
 * ⚠️ `Curve` 与 `TransitionEffect` 都是框架的全局声明（与 `$r` 同类），不需要 import。
 */

/** 淡入。浮层的遮罩、以及「就地出现/消失」的控件用它。 */
export function enterFade(duration: number = 150): TransitionEffect {
  return TransitionEffect.asymmetric(
    TransitionEffect.OPACITY.animation({ duration: duration, curve: Curve.Friction }),
    TransitionEffect.IDENTITY,
  );
}

/** 淡入 + 轻微放大。给**卡片**用 —— 遮罩单独淡入时，卡片只是跟着变亮，读起来是「整块亮起来」；
 *  叠一点点缩放才读得出「这张卡出现了」。⚠️ 只给 scale、**不叠 opacity**：
 *  卡片在遮罩里面，两边都淡会让卡片明显滞后于底下的遮罩。 */
export function enterPop(duration: number = 180): TransitionEffect {
  return TransitionEffect.asymmetric(
    TransitionEffect.scale({ x: 0.96, y: 0.96 })
      .combine(TransitionEffect.OPACITY)
      .animation({ duration: duration, curve: Curve.FastOutSlowIn }),
    TransitionEffect.IDENTITY,
  );
}
