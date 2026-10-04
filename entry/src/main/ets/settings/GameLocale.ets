/* 把**设备语言**翻译成**游戏认得的 locale 值**。
 *
 * ── 为什么需要这一层翻译 ────────────────────────────────────────────────────
 * 游戏的 `Vars.loadLocales()` 在 `settings.bin` 的 `locale` 值是 `default` 时用
 * `Locale.getDefault()`；而 `LanguageDialog.findClosestLocale()` 拿这个 Locale 去
 * `Vars.locales` 里找「language 相同」的那一项，**找不到就硬编码 `new Locale("en")`**
 * 并把它写回 `settings.bin`。
 *
 * ⚠️ **这不是游戏或本项目的缺陷**（用户 2026-10-04 纠正过）—— Mindustry 本来就**没有**
 *    「跟随系统」这个设置项，`default` 的含义只是「用 JVM 的默认 locale」。桌面版看起来
 *    「跟着系统」，是因为桌面 JVM 的默认 locale 跟着操作系统走，同一套机制。
 *    本启动器此前没给 JVM 传过 locale ⇒ HotSpot 的 C locale 是 `C` ⇒ 那个 `default`
 *    落在英文上。这里做的是**把设备语言喂给 JVM**，不是修谁。
 *
 * 本文件负责给出那个**能被游戏匹配上**的字符串。翻译是必需的，不是周全：
 *   · 系统的语言标签常带文字子标签（`zh-Hans`），而游戏的单位是 `zh_CN` / `zh_TW`；
 *   · 游戏**没有** `bundle_zh.properties`，只有 `bundle_zh_CN` 与 `bundle_zh_TW`
 *     ⇒ 只给 `zh` 会**落到根包（英文）**，比不给还糟（不给至少还能落回系统默认）。
 */
import { i18n } from '@kit.LocalizationKit';

/* ⛔⛔ **这份清单是从游戏 jar 里逐字节抄出来的，别凭印象改。**
 * 来源：`payload-src/Mindustry-160.5.jar` 内的 `locales` 资产（`Vars.loadLocales()` 读的就是它），
 * 内容是 35 行、每行一个 locale ID，用 `\n` 分隔；下面按原顺序抄下。
 * ⭐ 它是**权威的**：`LanguageDialog` 的语言列表就是从这里建的，所以「游戏认不认某个值」
 *    的判据是它在不在这个清单里 —— 而不是「Java 能不能构造出这个 Locale」。
 * ⚠️ 大小写是**有意义**的：语言小写、地区大写（`id_ID` / `nl_BE` / `uk_UA`）。
 *    而 `new Locale("zh","Tw").toString()` 是 `zh_Tw` —— 对不上文件名，所以别自己拼大小写。 */
const GAME_LOCALES: string[] = [
  'en', 'be', 'bg', 'ca', 'cs', 'da', 'de', 'es', 'et', 'eu',
  'fi', 'fil', 'fr', 'hu', 'id_ID', 'it', 'ja', 'ko', 'lt', 'nl',
  'nl_BE', 'pl', 'pt_BR', 'pt_PT', 'ro', 'ru', 'sr', 'sv', 'th', 'tk',
  'tr', 'uk_UA', 'vi', 'zh_CN', 'zh_TW',
];

/** 找出游戏认得的、最贴设备语言的那个值；给不出来就是 `''`（= 什么都不设）。
 *
 * 顺序：**先试「语言_地区」，再退回「语言」。**
 * ⚠️ 顺序不能反：`zh_CN` 在清单里而 `zh` **不在** ⇒ 对中文设备，「先语言」得到的 `zh`
 *    不是被清单拒绝、而是**清单里根本没有它**；而游戏那侧，`Locale("zh")` 会去找
 *    `bundle_zh.properties`（不存在）并落到根包 = **英文**。所以必须优先带地区。
 * ⚠️ 地区**一律大写**（与 jar 里的文件名一致）；系统的 region 本来就是大写（`CN`），
 *    这里再 `toUpperCase()` 一次是为了不依赖那个习惯。 */
export function systemGameLocale(): string {
  let lang: string = '';
  let region: string = '';
  try {
    lang = i18n.System.getSystemLanguage();
    region = i18n.System.getSystemRegion();
  } catch (e) {
    /* ⚠️ 拿不到就**什么都不设**，别硬猜一个 —— 猜错会让游戏写死一个错的 locale。
     * ⛔ 不设**不等于**「跟随系统」：游戏那边 `default` 会落到 JVM 的默认 locale，
     *    而本启动器不传 locale 时那是 `C`/英文。也就是「不设 = 可能是英文」。
     *    ⚠️ 这条以前写成「落回游戏本来就有的跟随系统那条路」——**是错的**，游戏没有那条路。 */
    return '';
  }
  /* ⚠️ 系统的语言标签可能带文字子标签（`zh-Hans` / `sr-Latn`），取第一段。
   * ⛔ 别把子标签当成地区用（`zh_Hans` 不在清单里，会白退回）。 */
  const dash: number = lang.indexOf('-');
  const base: string = (dash === -1 ? lang : lang.substring(0, dash)).toLowerCase();
  if (base === '') {
    return '';
  }
  if (region !== '') {
    const withRegion: string = base + '_' + region.toUpperCase();
    if (GAME_LOCALES.indexOf(withRegion) !== -1) {
      return withRegion;
    }
  }
  /* 退到语言本身 —— ⚠️ 只在清单里**确实有**它时才给（`en`/`ja`/`de`… 都是裸语言），
   * 否则宁可空着：给一个游戏没有的值，结果是它静默落在英文根包上。 */
  return GAME_LOCALES.indexOf(base) !== -1 ? base : '';
}
