/** 一个 Mindustry jar 里 `version.properties` 的**原文**；读不出时为【空串】。
 *
 * ⚠️ 刻意**不**返回拼好的版本号：拼装属于显示，而显示格式会变 ⇒ 改显示不必重编 .so。
 * ⚠️ 空串是「不知道」不是「出错」—— 调用方显示成「未知版本」，⛔ 不让列表项消失
 * （不是游戏的 jar，例如模组，正常就走到这里）。
 */
export const jarVersionText: (jarPath: string) => string;
