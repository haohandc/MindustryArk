/** 一个 Mindustry 存档（`.msav`）的元数据，**每行一条 `key=value`**；读不出时为【空串】。
 *
 * 实测（2026-10-02，真存档）会出现的键：
 *     playtime   游戏内时长，⭐ 单位是**毫秒**（⛔ 不是 tick）
 *     saved      Unix 毫秒时间戳
 *     mapname    地图名（可能是中文）
 *     build      写这个存档时的游戏构建号，**整数**（如 `160`）
 *     mods       当时的模组清单，形如 `[]` 或 `[a, b]`
 *     width/height  地图尺寸
 *     rules      嵌套 HJSON；太大时变成 `rules=(omitted, N bytes)`
 *
 * ⚠️ 返回**原始文本**而非拼好的结构：拼装属于显示、显示格式会变 ⇒ 改显示不必重编 .so。
 * ⚠️ 空串是「不知道」不是「出错」—— 调用方显示成「读不出」，⛔ 不让那一项消失。
 * ⚠️ `build` 是**写入**时的版本，**不是**「哪些版本能读它」（那要游戏的存档迁移规则，
 *    我们拿不到）⇒ 别把它当兼容性保证用。
 */
export const saveMetaText: (savePath: string) => string;
