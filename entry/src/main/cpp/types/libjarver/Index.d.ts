/** [A]
 * 一个 Mindustry jar 里 `version.properties` 的**原文**；读不出时为【空串】。
 *
 * ⚠️ 这里刻意**不**返回拼好的版本号：拼装属于显示，而显示格式会变。
 * 交给 ArkTS 之后，改显示不必重新编译这个 .so。
 *
 * ⚠️ 空串表示「不知道」，不表示出错 —— 调用方把它显示成「未知版本」，
 * 而不是让列表项消失。一份不是游戏的 jar（例如模组）正常就会走到这里。
 */
export const jarVersionText: (jarPath: string) => string;
