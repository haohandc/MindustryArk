/* 把**设备语言**翻译成**游戏认得的 locale 值**。
 *
 * 游戏的 `Vars.loadLocales()` 在 `settings.bin` 的 `locale` 是 `default` 时用 `Locale.getDefault()`；
 * `LanguageDialog.findClosestLocale()` 拿它在 `Vars.locales` 里找 language 相同项，**找不到就硬编码
 * `new Locale("en")`** 并写回 `settings.bin`。
 * ⚠️ 这不是游戏或本项目的缺陷：Mindustry 本来就**没有**「跟随系统」设置，`default` = 「用 JVM 的默认
 *    locale」。本启动器此前不传 locale ⇒ HotSpot 的 C locale 是 `C` ⇒ 那个 `default` 落在英文上。
 * ⭐ 翻译是必需的：系统标签常带文字子标签（`zh-Hans`），而游戏的单位是 `zh_CN` / `zh_TW`。 */
import { i18n } from '@kit.LocalizationKit';

/* ⛔ **从游戏 jar 里逐字节抄出来的，别凭印象改。**
 * 来源：`payload-src/Mindustry-160.5.jar` 内的 `locales` 资产（`Vars.loadLocales()` 读的就是它），
 * 35 行、每行一个 locale ID，按原顺序。⭐ 判据是「在不在这个清单里」，不是「Java 能否构造」。
 * ⚠️ 大小写**有意义**：语言小写、地区大写（`id_ID` / `nl_BE` / `uk_UA`），别自己拼。 */
const GAME_LOCALES: string[] = [
  'en', 'be', 'bg', 'ca', 'cs', 'da', 'de', 'es', 'et', 'eu',
  'fi', 'fil', 'fr', 'hu', 'id_ID', 'it', 'ja', 'ko', 'lt', 'nl',
  'nl_BE', 'pl', 'pt_BR', 'pt_PT', 'ro', 'ru', 'sr', 'sv', 'th', 'tk',
  'tr', 'uk_UA', 'vi', 'zh_CN', 'zh_TW',
];

/** 找出游戏认得的、最贴设备语言的那个值；给不出来就是 `''`（= 什么都不设）。
 * 顺序：**先试「语言_地区」，再退回「语言」。**
 * ⚠️ 顺序不能反：`zh` 在清单里**不存在**，而游戏那侧 `Locale("zh")` 会落到根包 = **英文**（游戏只有 `bundle_zh_CN` / `bundle_zh_TW`）。
 * ⚠️ 地区**一律大写**（与 jar 里的文件名一致），不依赖系统的 `CN` 本来就是大写这个习惯。 */
export function systemGameLocale(): string {
  let lang: string = '';
  let region: string = '';
  try {
    lang = i18n.System.getSystemLanguage();
    region = i18n.System.getSystemRegion();
  } catch (e) {
    /* ⚠️ 拿不到就**什么都不设**，别硬猜一个 —— 猜错会让游戏写死一个错的 locale。
     * ⛔ 不设**不等于**「跟随系统」：游戏那边 `default` 会落到 JVM 默认 locale，
     *    而本启动器不传 locale 时那是 `C`/英文 ⇒「不设 = 可能是英文」。 */
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
