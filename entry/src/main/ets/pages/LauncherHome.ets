/* [A]
 * 启动器主界面 —— 没有游戏可加载时，或玩家主动要求时显示的那一屏。
 *
 * ⚠️⚠️ 它【替换】XComponent，不是盖在它上面，而这决定了这里能用什么控件。
 *   本项目有一条硬规则：凡是承载在【游戏 Surface 之上】的浮层，一律 focusable(false)
 *   且不含任何可获焦子组件 —— 因为 ArkUI 把按键只投递给聚焦的组件，一个可获焦的
 *   Button 会把键盘从 SDL 那里抢走，游戏于是完全收不到输入（踩过，且是无声的）。
 *
 *   ⇒ 这一屏不适用，因为它存在的时候【没有 Surface】。所以这里的 Button 和可获焦
 *     组件都是安全的。**但这条豁免是有条件的**：如果哪一天有人把它改成盖在游戏上，
 *     那条规则立刻生效，而症状会是「进了启动器之后键盘就废了」。
 *
 * 布局形态是 Navigation + 底部页签，这是被 API 约束推出来的，不是审美选择：
 *   沉浸光感（systemMaterial / uiMaterial）【不是】一个能贴在任何卡片上的背景模糊。
 *   官方文档原文：「其他组件仅在 Navigation/NavDestination 标题栏或横向 Tabs 中
 *   barPosition 为 BarPosition.End 的底部 TabBar 中生效。在其他区域中设置沉浸光感
 *   效果不生效。」
 *
 *   ⭐ 这条约束【顺带否掉了】「平板改成侧边竖向页签」这个方案：那段原文要的是
 *     **横向 Tabs + BarPosition.End**，换成竖向/侧边就没有沉浸光感了。
 *     平板的适配因此落在【内容】上，而不是换页签形态。
 *
 * 颜色分两套，别混：
 *   · 文字  -> $r('sys.color.*')，由系统按深浅色模式切换，而且**沉浸光感的 colorInvert
 *              只对这类特殊资源值生效**（官方原文：硬编码色如 Color.White、'#FFFFFFFF'
 *              不会触发自动反色）。
 *   · 表面色 -> $r('app.color.launcher_*')，在 resources/base 与 resources/dark 两处定义。
 *
 * ⭐⭐⭐ 三条踩过的坑，改这个文件前先读：
 *   1. `.barOverlap(false)` 会让底部栏**不再悬浮** —— 悬浮观感就是靠它。
 *      官方示例 reference 项目 AMCL 也是 `barOverlap(true)`，并且他们的注释明说
 *      「旧 API 仍覆盖在全屏内容上，不退回挤占 TabContent 高度的布局」。
 *      ⇒ 所以防「栏压住按钮」要靠**给内容留底部空间**，不是关掉重叠。
 *   2. `@Builder` 的参数是**按值传递**。把一行列表项做成带 `chosen` 参数的 @Builder
 *      之后，`this.selected` 变化**不会让那个 @Builder 重新执行** —— 结果是点击
 *      其实成功了（文件也写了、native 也读到了），但 ✓ 不动，看起来像「点了没反应」。
 *      ⇒ 列表项**内联**写，不要抽 @Builder。
 *   3. ⛔⛔ **删掉一个 `import` 却漏了调用点，报出来的错会指向【完全无关的地方】。**
 *      实测（2026-10-02）：我把 `computeKey` 从 import 里换成了 `resolveGameDirAndKey`，
 *      却漏了 `applyIsolationCopy()` 里那一处调用，`computeKey` 就成了未定义的名字。
 *      ArkTS 报的是 **177 处**错误，绝大多数是
 *          「UI component 'Column'/'Text'/'Slider' cannot be used in this place」
 *          「`this.SettingsTab()` does not meet UI component syntax」
 *      指向的却是**几百行之外**、一个字都没改过的 `SettingsTab`。
 *      ⭐ **真正的那条**只有一句、排在【整张表的最后】：
 *          `Cannot find name 'computeKey'. Did you mean 'Computed'?`
 *
 *      ⇒ ⭐⭐ **判据：一个未解析的名字会让【整个文件】的语法分析失败**，
 *        于是所有 UI 组件都「用错了地方」。**先看列表最后那几条**，别从第一条读起；
 *        而「UI component 用错地方」这种话本身不构成任何线索，别去追它。
 *
 *      ⚠️ 另一半陷阱在**日志文件**里：`.hvigor/outputs/build-logs/build.log`
 *         **是追加的**，里面混着**历次**构建的错误。按它去数错误会数到早就修好的旧错
 *        （例如那个 `SaveLibrary.ets:265 Unterminated string literal`）。
 *        ⇒ 判断「这一次」只信**命令当场打印的那几行**。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { SymbolGlyphModifier, uiMaterial } from '@kit.ArkUI';
import { GameJar, GameResolution, listGameJars, readSelection, writeSelection,
         resolveGame, gameJarDir, ensureGameJarDir,
         bundledGameVersion, hasBundledGame, bundledGamePath } from '../games/GameLibrary';
/* [A] 界面偏好（启动后进哪里）。单独一个文件，因为它不是「游戏知识」——
 * 理由见那个文件的开头。⛔ 内容宽度**不再**在这里 —— 见 gamesWidthVp 的说明。 */
import { readLaunchMode, writeLaunchMode,
         LAUNCH_MODE_HOME, LAUNCH_MODE_GAME } from '../settings/LauncherPrefs';
/* [A] 版本隔离：四档粒度、键的计算、以及打开时的那次复制。
 * ⛔ 实际的 `-Duser.home=` 在 native 侧 —— 这里只负责【决定】并把结论写进桥。 */
/* [A] 存档：一个存档 = 一个星球的一组 msav（或一个手动存档）。见那个文件的开头。 */
import { SaveEntry, listSaves, formatSaveSize, formatSaveDate,
         SaveMeta, readSaveMeta, newestFileOf } from '../games/SaveLibrary';
/* [A] 存档垃圾站：删除不是抹掉，是搬到游戏看不见的地方。见那个文件的开头。 */
import { VaultEntry, vaultDelete, listVault, vaultRestore, vaultPurge,
         vaultSetArchived, purgeExpired, describeExpiry, formatMs,
         readVaultDays, writeVaultDays, VAULT_DAYS_CHOICES } from '../games/SaveVault';
/* [A] 复制 / 移动。⚠️ 同版本复制只对手动存档开放 —— 理由见那个文件的开头。 */
import { copySaveTo, moveSaveTo, duplicateSave, countSavesIn } from '../games/SaveTransfer';
import { GRANULARITY_OFF, GRANULARITY_NUMBER, GRANULARITY_BUILD, GRANULARITY_PATCH,
         readGranularity, writeGranularity,
         copyLiveDataInto, gameDataExists, liveGameDataDir, isolatedGameDataDir,
         GameDataCounts, countsOf, describeCounts,
         resolveGameDataDir, resolveGameDirAndKey, GameDirForKey,
         listInstanceKeys } from '../settings/Isolation';

const DOMAIN = 0x0000;
const TAG = 'MindustryLauncher';

/* [A] 「查看存档数据」弹窗里的一行：左标签、右值。
 * ⚠️ 做成 `label + value` 两段而不是一整条字符串：值里会长成 `[a, b, c]` 那样带逗号的
 *    东西，拼成一条就分不清哪儿是标签哪儿是值了。 */
interface MetaRow {
  label: string;
  value: string;
}

/* [B] 「在同一个版本里再存一份」在目标列表里的**伪路径**。
 * ⚠️ 它不是一个真的版本，所以不能拿任何一个 `VersionEntry.path` 来当它 ——
 * 拼一个绝不会与真实路径相撞的串（真实路径都是绝对路径，以 `/` 开头）。 */
const DUP_KEY: string = '#dup-same-version';

/* [A] ⚠️ 换行用 `String.fromCharCode()` 取，**不在源码里写字面转义**。
 * ⛔ 因为写文件的工具会把 `
`（反斜杠 + n）当成**真实换行**写进去 ——
 *    报错是「Unterminated string literal」，而看代码时那一行「看起来是对的」
 *    （它确实显示成一个换行，而人眼不会觉得那有什么问题）。
 * ⭐ 同一族的坑在 `SaveLibrary.ets` 里也记着（那次是把 `
` 写进了 TS 字符串）。
 * ⚠️ 另一种更省事的写法是在这里直接打字面量 —— 但任何一次「用脚本改这个文件」
 *    都会把它再弄坏一次，所以用这个拼起来就坏不了的写法。 */
const NL: string = String.fromCharCode(10);

/* [A]
 * 「按存档」列表里的一行 —— ⭐ **必须带上它在哪个目录**。
 *
 * ⛔⛔ 这是用户 2026-10-02 报的那个 bug 的核心：开启隔离之后，
 *    **每个版本都有自己的 `saves/`**，而不同版本里的存档**可以是同名的**
 *    （`0.msav`、`sector-serpulo-142.msav` 到处都是）。
 *    ⇒ 只用 `SaveEntry.id` 当身份会**撞车**：两个版本的 `manual:0` 是同一个 id。
 *    ⭐ 所以身份 = `目录 + id`，而每个动作（删除/复制/移动/看数据）都必须
 *      **按它自己那个目录**去做，⛔ 不能再用「当前版本那个目录」代替。
 */
interface SaveRow {
  /** [B] 这个存档所在的 `saves/` 目录。 */
  dir: string;
  entry: SaveEntry;
}

/* [A]
 * 一组**共用同一份数据**的版本，以及那份数据里的存档。
 *
 * ⭐ 用户 2026-10-02 要的形状：「按存档那里应该列出**所有版本**的存档，
 *    按照顺序"A版本"->"B版本"这样排下去，小字和详情标注这个存档属于哪（几个）版本」。
 *
 * ⚠️ 按**目录**分组，不是按版本 —— 只有按目录才不会重复：
 *    隔离**关着**时所有版本共用一份数据，按版本分会让同一批存档出现 N 遍。
 *    按目录分恰好得到一组，而组头的版本名单正好回答了「属于哪几个版本」。
 */
interface SaveGroup {
  /** [B] 数据目录（`…/<版本>/sets/default/.local/share/Mindustry/saves`）。 */
  dir: string;
  /** [B] 读这个目录的版本，顺序与 `versions` 一致。空数组 = 没有版本读它。 */
  versions: VersionEntry[];
  /** [B] 这个目录里的存档。 */
  saves: SaveEntry[];
  /* [A] ⭐ `versions` 为空时，这个目录**是哪种**「没人读」——
   *    `''` = 未隔离的那一份（它本来就不属于任何版本）；
   *    非空 = 一个**以前某一档隔离留下的**键（`b160.5` 这种）。
   * ⚠️ 两者要分开说：前者的正常状态，后者是「换了粒度/合并之后留下的」，
   *    而后者正是玩家会问「我的数据呢」的那一种。 */
  orphanKey: string;
}

/* [A]
 * 隔离切换时，「复制过去」可以复制进哪些**分类** —— 也就是这一档下的每一个键。
 *
 * ⭐ 用户 2026-10-02：
 *   「复制改成多版本自行选择，告知用户可以复制到哪些粒度下的分类里面。现在这个有点反直觉。」
 *
 * ⛔ 原来是我替他全选（每个版本都补一份）—— 那不是「复制过去」的直觉含义，
 *    而它又**看不见**（列表里没有任何东西告诉你刚才复制了几份）。
 * ⭐ 现在把它摆出来让玩家自己勾：**看得见的选择，比聪明的默认值可靠**。
 */
interface CopyTarget {
  /** [B] 隔离键 —— 也就这一档下的一个「分类」。 */
  key: string;
  /** [B] 落进这个分类的版本。 */
  versions: VersionEntry[];
  /** [B] 这个分类**已经有数据**了吗。⚠️ 有的话勾了也不会覆盖（见 applyIsolationCopy）。 */
  hasData: boolean;
}

/** [B] 存档页的两种视图。 */
const SAVES_VIEW_SAVE: string = 'save';
const SAVES_VIEW_VERSION: string = 'version';

/* [A]
 * 「按版本」视图里的一项 —— 一个**可启动的游戏版本**。
 *
 * ⛔ 这里有个必须想清楚的区别：**「版本」不是「版本号」**。
 *    两个 jar 完全可以是同一个版本号（用户 2026-10-02 就提过「同一个版本放两个 jar」
 *    这种情形，我们当时决定不建议、但也不禁止）。⇒ 标识必须是 **jar 的路径**，
 *    ⛔ 不能是版本号 —— 否则同一个版本号的两个 jar 会互相顶掉，列表里只剩一个。
 *
 * ⚠️ 也不要拿 `GameJar.version` 当身份：它是**给眼睛看的显示串**（`v8 Build 160.5`），
 *    读不出来时还是空串。身份用 path，显示用 version —— 两者不许互换。
 */
interface VersionEntry {
  /** [B] jar 的绝对路径。**同时是这一项的稳定标识**。 */
  path: string;
  /** [B] `'user'` 或 `'bundled'`。 */
  source: string;
  /** [B] 给玩家看的名字（内置那份是「内置游戏」，其余是文件名）。 */
  label: string;
  /** [B] 版本显示串，如 `v8 Build 160.5`；读不出时是空串。 */
  version: string;
  /** [B] 隔离键；`''` 表示不隔离 —— ⭐ 那意味着它和**所有**别的版本共用一份数据。 */
  key: string;
  /** [B] 这个版本启动时游戏会去读的数据目录。 */
  dataDir: string;
  /** [B] 是不是当前选中的那个版本。 */
  isCurrent: boolean;
  /** [B] 该目录下的存档个数（只数文件名，不解压）。 */
  saveCount: number;
  /** [B] 该目录**存在**吗。与「有几个存档」是两件事：不复制地打开隔离就是一个空目录。 */
  hasData: boolean;
}

/** [B] Unix 毫秒 -> `YYYY-MM-DD HH:MM`。存档里的 `saved` 是毫秒，而列表用的 `mtime` 是秒。 */
function formatMsDateTime(ms: number): string {
  const d: Date = new Date(ms);
  const p = (n: number): string => n < 10 ? '0' + String(n) : String(n);
  return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate())
       + ' ' + p(d.getHours()) + ':' + p(d.getMinutes());
}

/* [A]
 * 游戏内时长：毫秒 -> 给人看的一句话。
 *
 * ⛔⛔ **单位是【毫秒】。这一条我原先弄错了，是查出来的，不是推的。**
 *
 * 我原来写的是「60 tick/秒」，于是除以 `60*60` 当 tick 换算 —— **错的**，
 * 分钟数被放大 **16.67 倍**。改的起因是用户 2026-10-02 说
 * 「超过 60 分钟后要开始显示小时 + xx 分钟」，我去核单位时才发现除数本身就错了。
 *
 * 两条**互相独立**的证据（都是 2026-10-02 取的）：
 *
 *   1. 【本项目源码，游戏 jar 的字节码】
 *      `mindustry.game.Saves.update()`：
 *          totalPlaytime += Time.timeSinceMillis(lastTimestamp)
 *      ⇒ 累加的增量来自 `Arc` 的 **timeSinceMillis**，单位毫秒。
 *      同一处 `lastTimestamp = Time.millis()`，也印证这一对是「毫秒时间戳 + 毫秒差」。
 *
 *      而 `arc.util.Strings.formatMillis(long)` 用 `3_600_000` 取小时、`60_000` 取分钟，
 *      再 `SaveSlot.getPlayTime()` = `Strings.formatMillis(meta.timePlayed)`
 *      ⇒ 游戏自己也是把这个值**当毫秒**格式化的（它显示成 `H:MM:SS`）。
 *
 *   2. 【实测，平板上的真存档】四个真实值，按毫秒解释才合理：
 *          `0.msav`                    59_932  ->  1.0 分钟
 *          `sector-erekir-10.msav`  1_991_130  -> 33.2 分钟
 *          `sector-serpulo-133.msav` 3_378_122 -> 56.3 分钟
 *          `sector-serpulo-142.msav` 36_202_317 -> 603.4 分钟 = 10.1 小时
 *      ⚠️ 最后一个是决定性的：同一个战役区块存档，按毫秒是 **10.1 小时**（合理），
 *      按 tick 是 **10056 分钟 = 167 小时**（不可能）。
 *
 * ⚠️ 两条证据是**独立**的（一条读字节码、一条读设备上的文件），而且互相吻合 ——
 *    这正是本项目要的那种对照；单靠其中一条我不会下结论。
 *
 * 分档（用户 2026-10-02 要的形状：「超过 60 分钟后要开始显示小时 + xx 分钟」）：
 *
 *      < 1 分钟   不足 1 分钟          ← ⚠️ 真会碰到：上面 `0.msav` 就是
 *      < 60 分钟  约 N 分钟
 *      >= 60 分钟 约 H 小时 M 分钟      ← ⛔ **M 为 0 也照写**（「约 2 小时 0 分钟」）。
 *                                        用户说的就是「小时 + xx 分钟」，两截都在位，
 *                                        行宽也不会随余数跳动。
 *
 * ⚠️ 一律 **floor**，不是四舍五入 —— 报少一点比报多一点诚实，而且「约」字已经说明它不精确。
 * ⛔ 不显示原始数字：它现在是毫秒，对玩家没有意义；而旧的写法把它标成 `tick`，那个标签**是错的**。
 */
function formatPlaytime(ms: number): string {
  const totalMin: number = Math.floor(ms / 60000);
  if (totalMin < 1) {
    return '不足 1 分钟';
  }
  if (totalMin < 60) {
    return '约 ' + String(totalMin) + ' 分钟';
  }
  return '约 ' + String(Math.floor(totalMin / 60)) + ' 小时 ' + String(totalMin % 60) + ' 分钟';
}

/* [A]
 * 把 native 读出来的元数据排成给玩家看的几行。
 *
 * ⭐ 三条口径，都是有意的：
 *
 *   1. **空值不显示。** 手动存档没有 `sectorPreset`，硬塞一行「区块预置：（空）」只是噪音。
 *   2. **「读取自」排在第一位。** 一个 Serpulo 战役有 14 个 `.msav`（每区块一个），
 *      而这里只读了最新的那一个 ⇒ 「其他区块可能不同」这件事必须**看得见**，
 *      不能藏起来让玩家以为这就是整个存档的属性。
 *   3. ⚠️ **构建号那一行要说清它是什么。** `build` 是「**写**这个存档时的游戏构建号」，
 *      ⛔ 不是「哪些版本能读它」—— 后者要拿模组清单和版本规则去算，是另一件事。
 *      玩家的存档列表里已经显示版本，而这一行如果被读成「兼容范围」，就会误导人。
 */
function rowValue(rows: MetaRow[], label: string): string {
  const hit: MetaRow | undefined = rows.find((r: MetaRow) => r.label === label);
  return hit === undefined ? '' : hit.value;
}

function metaRowsOf(m: SaveMeta, sv: SaveEntry): MetaRow[] {
  const rows: MetaRow[] = [];
  const add = (label: string, value: string): void => {
    if (value !== '') {
      rows.push({ label: label, value: value });
    }
  };

  const others: number = sv.sectors - 1;
  add('读取自', m.fromFile + (others > 0 ? ('（另有 ' + String(others) + ' 个区块文件未读）') : ''));
  add('写入时的构建号', m.build);
  add('地图', m.mapname);
  add('区块预置', m.sectorPreset);
  add('波次', m.wave);
  if (m.width !== '' && m.height !== '') {
    add('地图尺寸', m.width + ' × ' + m.height);
  }
  add('玩家队伍', m.playerteam);
  if (m.saved !== '') {
    add('保存时间', formatMsDateTime(Number(m.saved)));
  }
  if (m.playtime !== '') {
    /* ⛔ 单位是**毫秒**，单位说明与两条证据见 `formatPlaytime`。 */
    add('游戏内时长', formatPlaytime(Number(m.playtime)));
  }
  add('模组', m.mods);
  return rows;
}

/** [A]
 * 内容占窗口宽度的**百分比下限**（按 vp 算）。
 *
 * ⭐ 下限的存在：手机上窗口只有 360–420 vp，30% 会得到一百多 vp 的窄条，没法用。
 * `max(360, 百分比)` 这个组合让**手机退回全宽、平板收成左栏** ——
 * 同一个式子管两种设备，不需要断点。
 */
const CONTENT_MIN_VP = 360;

/** [A]
 * 首页的内容宽度：**固定 30%**。
 *
 * 这条规格从第一天就在（用户 2026-10-01）：「内容本身占 30%，在最左边，像 AMCL 那样。
 * Mindustry 的电脑 UI 也是菜单在左边，而不是居中。」
 * ⚠️ 中间加过一条 20–60 的滑条，用户 2026-10-02 收回了：「那个不要了，首页就固定在 30%」。
 *
 * ⛔ 存档与设置**不用**这个值 —— 它们是 100%，直接写 `'100%'`：那两条没有「占比」的
 * 概念，就是铺满，连窗口宽度都不必量。
 */
const GAMES_WIDTH_PCT = 30;

/** [A]
 * 窄屏（手机）的阈值，vp。低于它就把存档页的详情改成**子页**而不是右栏 ——
 * 理由与实测依据见 `isNarrow()`。
 *
 * ⚠️ 600 与参考项目 AMCL 的断点一致（他们 `viewportWidth >= 600` 才走双栏）。
 */
const NARROW_VP = 600;

/** [A]
 * 底部悬浮栏的**目标宽度**上限。
 *
 * 为什么不是 `barWidth`
 *   `barWidth` 是三档 `FloatingTabBarWidth`，而**档位由 SDK 自己的断点决定** ——
 *   我既不能决定它选哪一档，也不能决定栏摆在哪儿。实测：给了三档宽度，用户仍报
 *   「悬浮了，但不居中」。
 *
 * 为什么是 `barSideMargin`
 *   它是**左右同一个值**。左右留白相等 ⇒ 栏必然居中，**由构造保证**，不需要知道
 *   SDK 内部怎么摆。代价是它不能用百分比，所以宽度得自己从窗口算 —— 见 sideMargin()。
 */
const BAR_MAX_VP = 480;

/** [B] 左右留白的下限，窄屏上不至于把栏挤没。 */
const BAR_MIN_SIDE_VP = 16;

/** [A]
 * 栏离底边多高。**这是「悬浮」的一半**：没有它，栏贴着屏幕下沿，看起来就是一条
 * 普通底栏；抬起来才像一片浮在内容上的玻璃。
 *
 * 参考 AMCL 的做法：他们用 `Math.max(bottomSafeHeight, 16) + 8`，并把这个数交给
 * `barBottomMargin`。这里不读安全区，取一个够用的常量 —— 平板上手势条那一条通常
 * 不到 16 vp。
 */
const BAR_BOTTOM_MARGIN_VP = 24;

/** [A]
 * 为悬浮栏让出的底部空间。
 *
 * ⚠️ 这是**估算**，不是量出来的：栏内容 52（见 TabItem 的 height）+ 离底 24 + 余量 20。
 * 它与本项目「测量不能当门」那条教训无关 —— 那说的是**闸门**；这里只是一段布局留白，
 * 多给一点没有任何副作用（只是底部空一点），少给才会压住按钮。
 * ⇒ 所以取偏大值。真要精确，得在设备上量一次栏的实际占位。
 */
const BAR_CLEARANCE_VP = 96;

/** [B] 圆角。卡片和列表项共用一个值，免得两处漂移。 */
const CARD_RADIUS_VP = 14;

/** [B] 按钮字号。**显式给**，因为不给的话按钮会按各自标签长度自适应，两个按钮的字
 * 会不一样大 —— 用户在设置页看到的正是这个。 */
const BUTTON_FONT_VP = 16;

/* [A] 「按版本」那一屏存档行的三列宽度（vp）。
 *
 * ⭐ 用户 2026-10-02：「文字没有做对齐（文件名对齐，大小和时间单独再对齐）」。
 *    ⇒ 文件名占剩下的全部，大小与时间**各占一列、右对齐**。
 *
 * ⚠️ 宽度必须写死：`Text` 默认按内容自适应，每行宽度不同 ⇒ 列就是歪的。
 * ⭐ 而写死是安全的，因为这两个格式**定长**（见 formatSaveSize / formatSaveDate）：
 *    大小 ≤ 7 个字符（`1.2 MB`），时间恒为 10 个字符（`2026-10-02`）。
 * ⚠️ 手机窄屏上文件名只剩一百多 vp，靠 `TextOverflow.Ellipsis` 收尾 ——
 *    比起让三列错开，截断是更小的代价。 */
const SAVE_SIZE_COL_VP = 74;
const SAVE_DATE_COL_VP = 92;
/** [B] 选中那个 ✓ 也占定宽，否则「选中」会把后面几列推歪。 */
const SAVE_TICK_COL_VP = 16;

/* [A]
 * 失败弹窗里那块文字的高度上限（vp）。
 *
 * ⚠️ 有上限是【必须】的，不是审美：那一块末尾是启动器自己的日志，长度不定，而弹窗下面
 * 那两个按钮（「仍然尝试启动」和「知道了」）才是它存在的理由 —— 日志把按钮顶出屏幕，
 * 就等于逃生门被日志关上了。文字自己滚，按钮永远在。
 */
const FAULT_BOX_VP = 240;

/* [A]
 * 弹窗宽度 = **窗口宽度的这一半**，窄屏上不低于下面的下限。
 *
 * ⚠️ 演进过程，两步都记着，免得下次又跳回去：
 *   ① 最初：只有 24 vp 左右内边距，盒子也没有底色 ⇒ 平板上看着「左右没有空隙」
 *   ② 然后：我写死 420 vp 封顶 ⇒ 用户 2026-10-01 报「有点小了，**矫枉过正**了。
 *      我觉得铺满屏幕的 50% 差不多」
 *   ③ 现在：比例而不是绝对数。⭐ 教训是**「封顶」这个动作本身没错，错的是那个数是拍脑袋
 *      定的** —— 用窗口宽度的比例，平板和手机就各自得到合适的宽度，不需要为每种设备配一个数。
 *
 * ⚠️ 下限仍然必要：手机上 50% 只有约 190 vp，那样连一行地址都放不下。
 *   有了下限，窄屏上它自动接近满宽 —— 这正是弹窗在手机上该有的样子。
 */
const DIALOG_WIDTH_FRACTION = 0.5;
const DIALOG_MIN_VP = 320;

/* [A]
 * 「仍然尝试启动」的底色与文字色。
 *
 * ⚠️ 用户 2026-10-01 要的：「背景应该搞成灰色的（**不希望用户点击**）」。
 * 所以它是个**次要**动作 —— 主推的是「知道了」，而这个绕开判定的入口要看着不起眼。
 *
 * ⚠️⚠️ 但它**必须仍然可点**。灰底只是「不建议」，不是「禁用」：它整个存在的意义就是
 * 在判定失误时留一条出路，把它真的禁用掉，就等于把逃生门拆了装成一个门把手。
 * ⇒ 视觉上压下去，功能上一个字节都不减。
 *
 * ⚠️ 用半透明的白，而不是一个固定的灰：弹窗底是硬编码的深色（`#F01C1C1C`），
 * 半透明灰在那上面读得出来，而且换底色也不用跟着改。
 */
const SECONDARY_BG = '#2EFFFFFF';
const SECONDARY_FG = '#B0FFFFFF';

/** [A]
 * 底部页签的材质。拿不到就返回 undefined，界面退回普通样式。
 *
 * ⚠️ 整件事包在 try 里，而且【判断本身】也在 try 里 —— `uiMaterial` 的起始版本是
 * 26.0.0，而本应用的 compatibleSdkVersion 是 6.1.1(24)。在 API 24 的设备上这个
 * 命名空间可能根本不存在，那时**抛异常的正是 isImmersiveMaterialSupported() 这一句**，
 * 而不是它的返回值。把判断放在 try 外面，等于把最该防的那一句漏在外面。
 */
function immersiveBarMaterial(): uiMaterial.Material | undefined {
  try {
    if (uiMaterial.isImmersiveMaterialSupported()) {
      return new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
      });
    }
    hilog.info(DOMAIN, TAG, 'launcher: the device reports no immersive material support');
  } catch (e) {
    const err = e as BusinessError;
    hilog.info(DOMAIN, TAG, 'launcher: immersive material unavailable (%{public}s)', err.message);
  }
  return undefined;
}

/** [B] 人类可读的大小。装上就是给人看的，所以用 MB/KB 而不是字节。 */
function formatSize(bytes: number): string {
  if (bytes >= 1048576) {
    return (bytes / 1048576).toFixed(1) + ' MB';
  }
  if (bytes >= 1024) {
    return (bytes / 1024).toFixed(0) + ' KB';
  }
  return String(bytes) + ' B';
}

/** [B] 只要日期。玩家分辨两个游戏版本靠的是文件名，日期只是辅助。 */
function formatDate(sec: number): string {
  const d: Date = new Date(sec * 1000);
  const p = (n: number): string => n < 10 ? '0' + String(n) : String(n);
  return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate());
}

@Component
export struct LauncherHome {
  /* [B] 两个都由 Index.ets 传进来 —— 它们是从 context 取的，而 context 只有页面拿得到。
   *
   * ⚠️ 它们【不能】带 private：ArkTS 会拒绝从组件构造器初始化私有属性（实测是一条
   * 警告：「Property 'filesDir' is private and can not be initialized through the
   * component constructor」），而**那条警告的后果是值根本传不进来** —— 组件照常渲染，
   * 只是两个路径都是空串。也就是说它会「构建成功、运行不正常」，比一个编译错误难查
   * 得多。 */
  filesDir: string = '';
  bundleCodeDir: string = '';

  /* [A]
   * Index.ets 在 Download 那个文件夹确认可用之后把它翻成 true。
   *
   * ⚠️ 为什么需要它：那个文件夹是父组件**异步**创建的（mkdir 或 picker，两者都得等），
   * 而本页的 aboutToAppear 紧接着**同步**跑 —— 全新安装的第一次，读到的状态文件还
   * 不存在，于是 jarDirHint 是空的。2026-10-01 在 MatePad Pro 上实测复现：
   * 第一次显示「还没读到文件夹」、同一分钟文件夹才落盘；不点任何东西重启一次即恢复。
   *
   * ⇒ 父组件不阻塞地通知一句，这里重读一遍 —— 与按一次「重新扫描」是同一件事。
   *
   * ⚠️ 反过来也不行：本页【不能】自己去 ensure，因为那要一个 UIAbilityContext，
   * 而本组件只拿到了 filesDir 这个字符串。让持有 ctx 的那一层去做，是唯一干净的分工。
   */
  @Prop @Watch('onFolderSettled') folderSettled: boolean = false;

  /** [B] 玩家点了「启动游戏」。参数是最终决定要加载的那个 jar。 */
  onLaunch: (jarPath: string) => void = (jarPath: string) => {};
  /** [B] 玩家点了「仍然尝试启动」—— 逃生门，见下面空状态里的说明。 */
  onForceLaunch: () => void = () => {};

  @State games: GameJar[] = [];
  @State selected: string = '';
  @State resolution: GameResolution = { path: '', source: 'none' };
  @State currentTab: number = 0;
  /** [B] 模组那个 Downloads 文件夹的路径提示；拿不到时为 ''。 */
  @State jarDirHint: string = '';

  /* [A]
   * 窗口宽度，从 onAreaChange 学来。
   *
   * ⚠️ 它存在只有一个理由：`barSideMargin` **不接受百分比**，所以给栏居中就必须知道
   * 屏幕多宽。0 表示还没量到，那时用下限兜着。
   */
  @State winW: number = 0;

  /* [A] ⭐ 内容宽度**不再是可调的**（用户 2026-10-02）。
   *
   * 「那个不要了，首页就固定在 30%，存档固定在 100%，设置固定在 100%」
   *
   * ⇒ 三条路各有各的**固定**宽度，见 `gamesWidthVp()`：
   *    · 首页 30% —— 那条规格从第一天就是「内容本身占 30%，在最左边，像 AMCL 那样」，
   *      中间加过一条 20–60 的滑条，现在回到固定值。
   *    · 存档 / 设置 100% —— ⭐ 存档要 100% 是为了**把「查看存档数据」挪进右侧的空位**
   *      （不再弹窗），设置要 100% 是为了铺成 AMCL 那种整片卡片。
   *
   * ⛔ 原来那两个 @State（`contentPct` / `sliderPct`）与写盘的 `launcher_width_pct.txt`
   *    已一并删除 —— 留着它们会变成一段没有用户的代码，而下一个读者会以为还有一个滑条。
   */
  /** [B] 启动后进哪里。由设置里那个开关写盘，启动时由 Index.ets 读。 */
  @State launchMode: string = LAUNCH_MODE_HOME;

  /** [B] 玩家点过「知道了」。只活这一次会话 —— 不再是失败状态就不会再显示。 */
  @State faultAck: boolean = false;

  /** [B] 「关于」那个窗口开着没有。由设置页那一行打开，右上角的 ✕ 关掉。 */
  @State showAbout: boolean = false;

  /** [B] 玩家选的隔离粒度。改它要走 chooseGranularity()，别直接赋值。 */
  @State granularity: string = GRANULARITY_OFF;

  /** [B] 存档列表。只含文件名/大小/时间，不含元数据 —— 元数据点开才读。
   * ⚠️ 这是**当前版本**那一份（给「按版本」面板和兜底用）。**列表用 `saveGroups`。** */
  @State saves: SaveEntry[] = [];

  /* [A] ⭐ 「按存档」列表的数据：**所有版本**的存档，按数据目录分组。
   * ⚠️ 在 `refresh()` 里算一次（它要扫每个版本的目录），⛔ 不在渲染里算。 */
  @State saveGroups: SaveGroup[] = [];

  /* [A] 当前选中的存档 id；'' 表示没选。
   * ⭐ 带 `@Watch` —— 一选中就去读它的元数据（右侧栏要显示「哪个版本写的」）。
   * ⚠️ `@Watch` **只在值真的变化时触发**，所以 `refresh()` 里还要显式调一次
   *    `loadSelectedMeta()`：换目录/换页签后 id 常常没变，但那份存档已经换了。 */
  /* [A] ⭐ 由宿主页（`Index.ets`）注入的回调 —— 它收到**系统返回**时先问这里。
   *
   * ⛔⛔ 为什么必须这样绕：本组件是 `@Component`，而 `onBackPress` 是**页面级**回调
   *    （只有 `@Entry` 有）⇒ 返回事件**到不了这里**，只能由页面转发。
   *
   * ⭐⭐ 而**系统的手势侧滑（全面屏手势）走的就是同一个事件** ——
   *    用户 2026-10-02 报的「没做侧边侧滑返回」，真正的缺口不是手势本身没开，
   *    而是没人**处理**那个返回：`Index.ets` 原来无条件把它转成 ESC 发给游戏，
   *    而启动器界面里根本没有游戏 ⇒ 看起来「滑了没反应」。
   *    ⇒ 补上这一条，返回键与侧滑手势**一起**就通了。
   *    ⚠️ 这与「ESC 被系统当返回」那条老坑是同一族：路径通不通，要看**谁在消费**它。 */
  registerBack: (fn: () => boolean) => void = () => {};

  /* [A]
   * 返回一层。**从最上层往里关**。
   * ⛔ 返回 `false` 表示「我这里没东西可关了」，交给宿主页（在游戏里那会转成 ESC）。
   */
  handleBack(): boolean {
    /* [B] 确认框比多选态**更靠外**一层：它盖在多选列表上，所以要先关它。
     * ⛔ 反过来（先退多选）会把窗留在屏幕上、而它下面那张列表已经没了 ——
     *    那时按「放进垃圾站」删的就是一批已经不属于任何东西的键。 */
    if (this.showMultiAsk) { this.showMultiAsk = false; return true; }
    /* [B] 多选态排在其后：它是一个**模式**，而模式必须能一键退出 ——
     * ⛔ 排在后面的话，返回键会先把别的东西关掉，而玩家看到的还是那张多选列表。 */
    if (this.multiMode) { this.exitMulti(); return true; }
    if (this.showDeleteAsk) { this.showDeleteAsk = false; return true; }
    if (this.transferOp !== '') { this.transferOp = ''; this.transferNote = ''; return true; }
    if (this.isolationConfirm !== '') { this.isolationConfirm = ''; return true; }
    if (this.showIsolationAsk) {
      /* [B] 与那个窗自己的「取消」同义 —— 它本来就只有这一个出口。
       * ⚠️ 所以这里**不是**「返回把窗关了」的越权，而是那个窗唯一的动作。 */
      this.showIsolationAsk = false;
      this.pendingGranularity = '';
      this.isolationConfirm = '';
      return true;
    }
    if (this.launchFault !== '' && !this.faultAck) { this.faultAck = true; return true; }
    if (this.showAbout) { this.showAbout = false; return true; }
    if (this.showVault) { this.closeVault(); return true; }
    if (this.panelOpen) { this.panelOpen = false; return true; }
    return false;
  }

  /* [A] 当前选中的那一行，形如 **`<目录>|<存档 id>`**。
   *
   * ⛔⛔ 原来这里只存 `id`，而开启隔离后**不同版本里的存档会重名**
   *    （每份数据里都有 `manual:0`）⇒ 一个 id 会同时命中好几行。
   *    ⭐ 带上目录之后，「选的是哪一份」与「对它做哪个动作」都有了唯一答案。
   *    ⚠️ 目录里不会出现 `|`，存档 id（`manual:0` / `sector:serpulo`）也不会
   *    ⇒ 用**第一个** `|` 切分是安全的。
   *
   * ⭐ 带 `@Watch` —— 一选中就去读它的元数据（右侧栏要显示「哪个版本写的」）。
   * ⚠️ `@Watch` **只在值真的变化时触发**，所以 `refresh()` 里还要显式调一次。 */
  @State @Watch('onSaveSelected') selectedSave: string = '';


  /** [B] 这一屏读的是哪个 saves 目录 —— 显示出来，因为隔离会换目录。 */
  @State savesDirShown: string = '';

  /* [A] 存档页当前是哪种视图。默认「按存档」——
   * 那是玩家真正要操作的那一屏（删除/复制/移动/看数据都在这儿），
   * 而「按版本」是拿来**理解隔离在干什么**的（哪个版本共用哪份数据）。
   * ⚠️ 别把默认改成按版本：那样每次进存档页都得先切一次才够得着操作。 */
  @State savesView: string = SAVES_VIEW_SAVE;

  /* [B] 「按版本」视图里选中的那个版本的 **jar 路径**（'' 表示没选）。
   * ⚠️ 带 `@Watch` —— 切版本要换右边那份存档名单（`versionSaves`）。 */
  @State @Watch('onVersionSelected') selectedVersion: string = '';

  /** [B] 已安装的版本（内置 ＋ 玩家导入的）。在 refresh() 里算一次，渲染只用它。 */
  @State versions: VersionEntry[] = [];

  /** [B] 选中的那个版本的数据目录里有哪些存档。切版本时读一次。 */
  @State versionSaves: SaveEntry[] = [];

  /* ============ 垃圾站 ============ */

  /** [B] 垃圾站视图开着吗。⛔ 它不是第三种「视图」—— 它是**另一个地方**，进出靠一个返回。 */
  @State showVault: boolean = false;
  /** [B] 垃圾站里现在有什么。`refresh()` 里读一次，渲染只用它。 */
  @State vaultEntries: VaultEntry[] = [];
  /** [B] 保留期（天）。⭐ 全局设置，见 SaveVault 的说明。 */
  @State vaultDays: number = 7;
  /** [B] 垃圾站里上一次操作的结果（''=没有）。⛔ 只是一句话，不是门。 */
  @State vaultNote: string = '';
  /** [B] 「删除」的确认框开着吗 —— 玩家要在这里选**放垃圾站**还是**归档**。 */
  @State showDeleteAsk: boolean = false;
  /** [B] 上一次清掉几个到期条目，用来告诉玩家一句。0 表示没有。 */
  @State vaultPurgedLast: number = 0;

  /** [B] 复制/移动的目标选择开着吗，以及是哪一种。`''` = 关着。 */
  @State transferOp: string = '';
  /** [B] 目标选择框里的提示（''=没有）。⛔ 只是一句话，不是门。 */
  @State transferNote: string = '';

  /* [A] ⭐ 已选中的目标（`v.path` 或 `DUP_KEY`）。⭐ **先选、再按确定** ——
   * 见 TransferDialog 里那段说明。
   * ⚠️ 复制可以多选；移动**只会有一个**（在 `toggleTransferPick` 里强制）。 */
  @State transferPicked: string[] = [];

  /* [A]
   * 选中那个存档的元数据。
   *
   * ⭐ **在【选中】时读一次，存下来**，而不是点开弹窗时才读 —— 因为右侧栏要显示
   *    「这个存档是哪个版本写的」，那是**选中就该看到**的信息。一份数据两处用，
   *    读一次就够（也避免弹窗打开时卡一下）。
   *
   * ⚠️ 存的是**排好的行**，不是 `SaveMeta` 原样：读这一步是**解压**（saveMetaText 走 zlib），
   *    而把原始字段常驻 @State、每次重绘再翻译一遍，等于让每次界面刷新都依赖一堆
   *    「这个字段可能是空串」的判断。⭐ 这样界面里也没有 native 类型，将来 native
   *    多返回一个字段，只需改 `metaRowsOf()`，碰不到界面代码。
   *
   * ⚠️ `selMetaNote` 非空 ⇒ 读失败了，`selMetaRows` 里只有能确定的那一两行。
   *    ⛔ **不允许「读失败但界面上看起来正常」** —— 那会让玩家以为存档是空的。
   */
  @State selMetaRows: MetaRow[] = [];
  @State selMetaNote: string = '';

  /* [A]
   * ⭐ 打开隔离时的**询问窗**是否开着。
   *
   * 为什么必须问：打开隔离会让 `user.home` 换地方，玩家进游戏发现存档「没了」——
   * 而他什么都没做。虽然我们做的是**复制**（原数据留着），但玩家不知道这一点。
   *
   * ⚠️ 只在「不隔离 → 某一档」时问。**关掉不问** —— 关掉只是回到原来那一份数据，
   * 一个字节都不会动，多问一次反而让玩家以为关掉有风险。
   */
  @State showIsolationAsk: boolean = false;

  /** [B] 询问里待确认的那一档；'' 表示没有待确认的切换。 */
  @State pendingGranularity: string = '';

  /* [A] ⭐ 「复制过去」时**玩家勾了哪些分类**。
   * ⚠️ 每次打开这个选择时**重算**（见 `chooseGranularity`）—— 版本的增删与
   *    各个分类有没有数据都会变，缓存下来会显示过期的东西。 */
  /** [A] 上一次「把数据复制进来」失败的原因；'' = 没有失败。
   * ⚠️ 单独一个 @State 而不是复用 `isolationNote`：这一块是要显示在**存档页**上的
   *    （动作在那儿按的），而 `isolationNote` 渲染在**设置页**。⛔ 一个字段两个渲染点
   *    会让「按下去了、屏幕上没反应」再发生一次 —— 那正是这一轮要修的病。 */
  @State staleCopyNote: string = '';
  /* [A] ⭐⭐ **长按进入多选，一次删多个**（用户 2026-10-02）：
   *    「按存档这里还应该加上长按多选存档，可以一键删除」「按版本…右边的选择存档删除页
   *      应该能长按多选」。
   *
   * ⚠️ 选中的键与单选**同一套**（`<目录>|<id>`）⇒ 两个视图、两张列表里指的是同一样东西，
   *    ⛔ 不需要第二套身份。而 `multiMode` 是**一个开关管两处**：
   *    进去之后两张列表都按多选解释点击，行为不会分叉。
   *
   * ⭐ 删除走的是**同一条路**（搬进垃圾站，不是抹掉），保留方式用**全局那个保留期** ——
   *    逐条问就把「一键」毁掉了；而归档仍然可以事后在垃圾站里点。
   */
  @State multiMode: boolean = false;
  @State multiPicked: string[] = [];
  /* [A] ⭐⭐ 多选删除的**确认框**（用户 2026-10-02：「我最后点删除的时候没有提示框」）。
   *
   * ⛔⛔ 我第一版是**故意不问**的，理由写在提交信息里：「逐条问就把一键毁掉了」。
   *    ⭐ 而那句话把两件事混成了一件：他不要的是**逐条**问，
   *      而他要的是**删之前问一次** —— 一批删掉是不可逆的（虽然进的是垃圾站），
   *      按下之前该有一次「你确定是这些吗」。
   *    ⇒ 教训：**「不要 N 次」不等于「不要那一次」。** 我把「减少摩擦」推到了「取消确认」。
   */
  @State showMultiAsk: boolean = false;
  /** [B] 确认框里那张名单展开了吗。⚠️ 默认收起 —— 一次选二十个会把窗撑爆。 */
  @State multiListOpen: boolean = false;
  /** [B] 多选删除之后的一句话（成功/失败都写这儿）。⚠️ 与 `vaultNote` 分开：
   * 那个渲染在**垃圾站**里，而这里是**存档页**。 */
  @State savesNote: string = '';
  @State copyTargets: CopyTarget[] = [];
  @State copyPicked: string[] = [];

  /** [B] 迁移出问题时要告诉玩家的一句话；'' 表示没有。⛔ 不是门，只提示。 */
  @State isolationNote: string = '';

  /* [A]
   * ⭐⭐ 询问窗里「这一档下每个版本会落到哪个目录」的预览行（一行一个版本）。
   *
   * 用户 2026-10-02 报的问题：「切换的大版本，构建号，小版本时，弹窗没说明是怎么分类的，
   * **必须让人选完了才知道是啥情况**」。
   * ⚠️ 原来那句说明（`granularityHint`）只在**设置页、选完之后**才显示 ——
   *    而询问窗是唯一能反悔的地方，恰恰那时什么解释都没有。
   * ⇒ 把说明与**具体目录名**搬进询问窗：⭐ 用玩家**真实的版本**算出来，
   *    而不是举 `160.5` 这种编的例子。
   *
   * ⚠️ 在 `chooseGranularity()` 里算一次（点开询问窗的那一刻），⛔ 不在渲染里算 ——
   *    算它要读每个 jar（见 `versionEntryOf` 的说明）。
   */
  @State pendingPreview: string = '';

  /* [A]
   * ⭐ 当前选中的是**内置游戏** —— 它在任何档位下都用固定的 `bundled` 目录。
   *
   * ⛔ 为什么必须专门说一句：玩家这时去切「大版本/构建号/小版本」，**目录名一个都不会变**
   *    ⇒ 他会得出「这个功能坏了 / 没生效」的结论。而真实原因是一条**刻意的设计**：
   *    内置那份永不移动，这样我们换内置 jar 版本时，玩家数据不会跟着搬走。
   *    ⭐ 不说这句，界面就在把一个设计决定伪装成一个故障。
   */
  @State pendingUsesBundled: boolean = false;

  /* [A] ⭐ 询问窗要点名的那个版本：【「名字 · 版本号」】与它在**这一档下**会用的键。
   *
   * 用户 2026-10-02：「弹窗现在说的是'这个版本'。我们加上具体的版本粒度就行」。
   * ⚠️ 整句话里只有指代（「当前选中的版本」「这个版本」），而那个版本的**身份**
   *    在那一屏上是看不见的（它在「首页」页签里）。⇒ 这里点名。
   *
   * ⚠️ `pendingKey` 必须用**待确认的那一档**算，⛔ 不能用 `versions` 里现成的 `.key`
   *    （那是按**当前**档位算的）—— 两者在玩家正切换时是不一样的。
   */
  @State pendingVersionName: string = '';
  @State pendingKey: string = '';

  /* [A]
   * ⭐ **隔离开着，但那一份数据目录根本不存在** —— 即「开关拨过去了、数据没过去」。
   *
   * ⛔ 为什么必须单独把它显出来：这种状态在界面上**完全看不出来**，而玩家进游戏看到的是
   *   一整套空数据 ⇒ 他只会说「我的存档全没了」。2026-10-02 的一次复制失败就造成了它
   *   （当时是 `writeGranularity` 跑在复制之前，见 applyIsolationCopy 上的说明）。
   *   ⭐ 那条顺序已经改成「复制成功才落盘」，但**已经踩进去的状态不会自己出来** ——
   *   这个提示就是给那种状态留的出口：至少玩家知道发生了什么、以及怎么退回去。
   *
   * ⚠️ 在 `refresh()` 里算一次存下来，⛔ 不是在渲染时去问文件系统 ——
   *    渲染每帧都跑，而这里要 `accessSync`。理由与 `buildVersions()` 那条相同。
   */
  @State isolationStale: boolean = false;

  /* [A]
   * 询问窗要摆出来的【现在有什么】。在打开询问窗那一刻读一次，不常驻。
   *
   * ⚠️ 每次打开都重读，刻意不缓存：玩家完全可能在两次打开之间删了一个存档或装了个模组，
   * 而缓存会让那个数字停在旧值上 —— 界面上看不出来。
   */
  @State isolationCounts: GameDataCounts = { sectorSaves: 0, manualSaves: 0, mods: 0, schematics: 0 };

  /* [A]
   * 二次确认：`''` = 没有待确认的；`'copy'` / `'empty'` = 哪一个动作在等确认。
   *
   * ⚠️ 两个动作都要确认（用户 2026-10-02 要求），理由不一样：
   *   · `empty` —— 真的会让人看不到存档，值得拦一道
   *   · `copy`  —— 本身安全（源不动），但它是"切换数据位置"这个动作的一半，
   *                而玩家在弹窗里点的第一下未必是他想好的那一个
   */
  @State isolationConfirm: string = '';

  /** [B] 下拉刷新是否在进行中。`$$` 双向绑定给 Refresh，由 onRefreshing 放回 false。 */
  @State isRefreshing: boolean = false;

  /** [A] 包内那份自带游戏的版本号；读不出时是 ''，界面显示成「未知版本」。 */
  @State bundledVer: string = '';

  /* [A] 包内那份自带游戏**在不在**。
   * ⛔ 别再从 `resolution.source` 反推 —— 那是「这次加载谁」，不是「在不在」。
   * 详见 GameLibrary.hasBundledGame 上的说明。 */
  @State hasBundled: boolean = false;

  /* [A]
   * 给**人**看的那个文件夹路径，例如 `Download/Mindustry Ark/games`。
   * ⚠️ 是 `Download` 单数 —— 那是磁盘上的真名；写 `Downloads` 会让玩家找不到。
   *
   * ⚠️⚠️ 为什么真实路径不够用（用户 2026-10-02 指出）：那个文件夹在磁盘上叫
   *    `com.haohandc.mindustryark`（由 ModImporter 用 bundle 名创建），
   *    而**文件管理器把它显示成应用名**「Mindustry Ark」。⇒ 玩家照着应用里的
   *    那一串去文件管理器找，**找不到**。
   *    ⚠️ 只有应用被卸载之后，它才退化成显示包名。
   *
   * ⇒ 两行都给：这一行用来**找**，真实路径那一行用来**复制**。
   *   两者都要，任缺其一都会让一部分人卡住。
   */
  @State jarDirHuman: string = '';

  /* [B] 应用自己的显示名，由 resolveAppLabel() 从资源读出；读不到时是 ''。 */
  private appLabel: string = '';

  /** [B] 应用版本，设置页那个「关于」入口用。由 Index.ets 传进来 —— 那边已经从 bundle 问到。 */
  appVersion: string = '';

  /* [A]
   * 上一次启动失败的记录；'' 表示没失败过。
   *
   * ⚠️ 它是【上一次】的判定，不是即时的。理由：失败发生时进程已经死了，那一瞬间没有
   * 任何界面可以弹窗 —— 唯一的物证是 native 在游戏入口之前留下的东西，而它要等
   * **下一次启动**才被读到。⇒ 弹窗出现在**重开之后**，这也是它唯一能出现的地方。
   */
  launchFault: string = '';

  /* [A]
   * 底部页签的悬浮样式（也就是沉浸光感生效的地方）是 @since 26.0.0。
   * 在更低的 API 上那个属性方法根本不存在，调用它会抛 —— 而那发生在 build() 里，
   * catch 不到。所以这里按运行期 API 级别分成两条分支，而不是靠 try。
   */
  private canFloat: boolean = deviceInfo.sdkApiVersion >= 26;
  private barMaterial: uiMaterial.Material | undefined = immersiveBarMaterial();

  aboutToAppear(): void {
    this.launchMode = readLaunchMode(this.filesDir);
    this.granularity = readGranularity(this.filesDir);
    this.appLabel = this.resolveAppLabel();
    /* [B] 把「返回一层」交给宿主页 —— 见 registerBack 的说明。 */
    this.registerBack(() => this.handleBack());
    this.refresh();
  }

  /* ====================================================================
   * 版本隔离
   * ==================================================================== */

  /** [B] 某一档的一句话说明。四档的差别对玩家不是自明的，所以每档都要写清。 */
  /* [A] 档位的**名字**（给弹窗标题用）。
   * ⚠️ 措辞必须与设置页那四个药丸（不隔离 / 大版本 / 构建号 / 小版本）**逐字一致** ——
   *    弹窗标题说「按构建号」而设置页写着「构建号」，玩家会以为是两个东西。
   * ⛔ 别在这里自己造一套更好听的说法。
   */
  private granularityName(g: string): string {
    if (g === GRANULARITY_NUMBER) {
      return '按大版本';
    }
    if (g === GRANULARITY_BUILD) {
      return '按构建号';
    }
    if (g === GRANULARITY_PATCH) {
      return '按小版本';
    }
    return '不隔离';
  }

  private granularityHint(g: string): string {
    if (g === GRANULARITY_NUMBER) {
      return 'v8 的所有版本共用一份；v9 出来之后才会分开';
    }
    if (g === GRANULARITY_BUILD) {
      return '160.5 与 160.1 共用一份；160 与 159 分开。改动最大的界线在这里';
    }
    if (g === GRANULARITY_PATCH) {
      return '每个小版本各一份（160.5 与 160.4 也分开）。切得最细，但要重建的东西也最多';
    }
    return '所有版本共用一份数据（默认）。换版本时看到的是同一批存档';
  }

  /* [A]
   * 玩家点了某一档。
   *
   * ⭐ **关掉不问、打开才问** —— 差别不是省一次点击，而是两者的后果不同：
   *   · 关掉 ⇒ `user.home` 回到原处，**一个字节都不动**，看到的是原来那一份
   *   · 打开 ⇒ 换到一个新目录，里面要么是刚复制过去的、要么是空的
   * ⚠️ 对着一个不会有后果的动作弹窗，会让玩家以为关掉也有风险。
   */
  private chooseGranularity(g: string): void {
    if (g === this.granularity) {
      return;
    }
    if (g === GRANULARITY_OFF) {
      this.granularity = g;
      writeGranularity(this.filesDir, g);
      this.isolationNote = '';
      /* [A] ⭐⭐ 关掉也要刷新 —— 关掉会让 `user.home` 换回公开那一份，
       * 于是存档页要显示**另一批**存档、版本页要重算每个版本的目录。
       * ⛔ 少了这一句，界面上还停在隔离开着时的样子，玩家会以为没关掉。 */
      this.refresh();
      return;
    }
    /* [B] 打开：先把「当前数据怎么办」问清楚。⛔ 这里【不】先落盘 ——
     * 玩家取消的话，界面上那一档不该已经跳过去了。 */
    this.pendingGranularity = g;
    /* ⭐ 读一次「现在有什么」，好在玩家**选之前**把两个结果都写成数字。
     * ⚠️ 在这里读、不常驻：玩家可能在两次打开之间删过存档或装过模组。 */
    this.isolationCounts = countsOf(liveGameDataDir());
    /* [A] ⭐⭐ 选之前就把「这一档怎么分、会落到哪些目录」摆出来。
     * 用户 2026-10-02：「弹窗没说明是怎么分类的，必须让人选完了才知道是啥情况」。 */
    this.pendingPreview = this.buildGranularityPreview(g);
    /* [A] ⭐ 「复制过去」要复制的分类：算出来，并**默认全勾**。
     *
     * ⚠️ 默认全勾是刻意的：玩家点「复制过去」的意图就是「每个版本都别丢数据」，
     *    那是**常见情形**；而他随时能取消掉某几个。
     *    反过来的默认（一个都不勾）会让最常见的意图要点两次。
     * ⭐ 与「我替你全选」的差别在于——**现在是看得见的**，而且能改。
     */
    this.copyTargets = this.buildCopyTargets(g);
    this.copyPicked = this.copyTargets.map((c: CopyTarget) => c.key);
    this.pendingUsesBundled = this.versions.some((v: VersionEntry) => v.source === 'bundled');
    /* [A] ⭐ 点名当前这个版本，以及它**在这一档下**会用哪个目录 —— 见那两个 @State 的说明。
     * ⚠️ 版本名从 `versions` 里按 `resolution.path` 找：那是**版本身份**（jar 路径），
     *    ⛔ 不是版本号（两个 jar 可以是同一个版本号）。 */
    const res: GameResolution = this.resolution;
    const rk: GameDirForKey = resolveGameDirAndKey(g, res.source, res.path, this.bundledJar());
    this.pendingKey = rk.key;
    const hit: VersionEntry | undefined =
      this.versions.find((v: VersionEntry) => v.path === res.path);
    if (hit === undefined) {
      /* [B] 找不到就说实话（jar 在两次读取之间被删了）。⛔ 不要留空 ——
       * 空行会让玩家以为「没有版本」，而实际只是这个引用过期了。 */
      this.pendingVersionName = '（当前没有可用的游戏版本）';
    } else {
      this.pendingVersionName = hit.label + (hit.version === '' ? '' : ('  ·  ' + hit.version));
    }
    this.showIsolationAsk = true;
  }

  /* [A]
   * 「按这一档分，每个已装版本会落到哪个目录」—— 逐行列出。
   *
   * ⭐ 用玩家**真实的版本**算，不举 `160.5` 那种编的例子：玩家要回答的问题是
   *    「我那两个 jar 会不会被分到一起」，而只有他自己的版本号能回答它。
   *
   * ⚠️ 它会读每个 jar（`resolveGameDirAndKey` → `computeKey` → `gameVersionParts`，
   *    那个函数**没有缓存**）。⇒ 只从 `chooseGranularity()` 调，⛔ 绝不在渲染路径上。
   *    一次点开 = 读 4 个 jar，与 `refresh()` 同一量级，可以接受。
   */
  private buildGranularityPreview(g: string): string {
    if (this.versions.length === 0) {
      return '（现在还没有可用的游戏版本）';
    }
    const lines: string[] = [];
    for (const v of this.versions) {
      const key: string = resolveGameDirAndKey(g, v.source, v.path, this.bundledJar()).key;
      lines.push(v.label + '   →   ' + (key === '' ? '（不隔离）' : key));
    }
    return lines.join('\n');
  }

  /* [A]
   * 询问里选了「复制过去」。
   *
   * ⭐ 复制而不是移动 —— 源目录一个字都不动（用户 2026-10-02 定的「留一个当备份」）
   * ⇒ **可逆**：把隔离关掉，看到的还是原来那一份。
   *
   * ⚠️ 复制失败**不阻止**打开隔离：那一份新目录只是空的，而**原数据完好**。
   *   所以这里记一句话给玩家看，流程照走。
   */
  private applyIsolationCopy(): void {
    const g: string = this.pendingGranularity;
    const res: GameResolution = resolveGame(this.filesDir, this.bundleCodeDir);
    /* ⚠️ 用成对的那个函数，只取 `key` —— 目录这次用不上，但 `computeKey` 要读 jar，
     * 分开调两次就会读两遍。见 Isolation.resolveGameDirAndKey 上的说明。 */
    const key: string = resolveGameDirAndKey(g, res.source, res.path, this.bundledJar()).key;
    if (key === '') {
      /* 一个可加载的游戏都没有 ⇒ 键是空的 ⇒ 隔离没有意义。不落盘、也不报错。 */
      this.isolationNote = '现在没有可加载的游戏，先选一个游戏版本再开隔离';
      this.showIsolationAsk = false;
      this.pendingGranularity = '';
      return;
    }
    /* [A] ⭐⭐ **先复制，成功了才落盘。**
     *
     * ⛔⛔ 原来这里顺序是反的（先 `writeGranularity` 再复制），而 2026-10-02 那次
     *    复制失败就把它暴露出来了：
     *        隔离标记已经落盘（开着）⇒ 下次进游戏 `user.home` 指向那棵**空的**新树
     *        ⇒ 玩家看到「存档全没了」，而**报错只写在设置页的一行小字里**。
     *    ⚠️ 原设计的一句注释说「复制失败不是致命错误，原数据完好，玩家丢不了东西」——
     *    那句关于**数据安全**是对的，但它把两件事混成了一件：
     *        · 数据安全：没丢 ✅
     *        · 玩家看到什么：一整套空数据 ❌
     *    ⇒ 玩家选的是「**复制过去**」。复制没成功 ⇒ **他选的那件事没有发生**，
     *    那就**不该**把开关拨过去。⭐ 判据是「玩家的意图有没有被执行」，不是「数据有没有丢」。
     *
     * ⚠️ 这样还顺带保住了**可重试**：开关留在原处，玩家可以再打开一次
     *    （铁律：门关上了也要有开它的路）。
     */
    /* [A] ⭐⭐ **「复制过去」要给每个版本都补一份，不只当前那一个。**
     *
     * ⛔⛔ 用户 2026-10-02 报「粒度的复制似乎是不起作用的」。设备日志说那次复制
     *    **成功了**（`copied 14 dir(s) / 188 file(s)`）—— 但它复制到
     *    `instances/bundled`（他当时选的是内置那份），而那个目录**本来就有数据**
     *    ⇒ 结果与「什么都没做」**在界面上完全一样**。
     *
     *    ⭐ 而「粒度」这个词的含义本该是：**这一档下的每一个版本各有一份**。
     *      只填当前那一个的话，玩家切到另一个版本，那边永远是空的 ——
     *      于是「复制过去」看起来就没起作用。
     *
     * ⚠️ 只补**还没有数据**的那些（`gameDataExists` 判），⛔ 不覆盖已有的：
     *    已有的那份可能装着玩家后来玩的进度，覆盖它等于**又删了一次**。
     *    ⇒ 这个动作的语义是「给每个版本一份起步数据」，不是「同步成一样」。
     *
     * ⚠️ 当前版本那一份**必须成功**（下面仍然要挡），其余尽力而为 ——
     *    它们只是顺带补的，失败了不该毁掉整个开关。
     */
  const note: string = copyLiveDataInto(key);
  if (note !== '') {
    this.isolationNote = note + '。隔离没有打开，你的数据还在原来的位置。';
    this.showIsolationAsk = false;
    this.pendingGranularity = '';
    this.refresh();
    return;
  }
  /* [A] ⭐ 其余**玩家勾了的**分类 —— 不再是我替他全选（见 CopyTarget 的说明）。
   * ⚠️ 仍然只补「还没有数据」的那些：已有的那份可能装着后来玩的进度，
   *    覆盖它等于又删了一次。⇒ 勾了也不会覆盖，界面上就是这么写的。 */
  const extraFails: string[] = [];
  for (const c of this.copyTargets) {
    if (this.copyPicked.indexOf(c.key) < 0 || c.key === key || c.hasData) {
      continue;
    }
    const e: string = copyLiveDataInto(c.key);
    if (e !== '') {
      extraFails.push(c.key + '：' + e);
    }
  }

    this.granularity = g;
    writeGranularity(this.filesDir, g);
    /* [A] ⛔⛔ 顺序：**先清空、再写失败说明**。
     *    原来的写法是反的（先赋值、紧接着 `= ''`）⇒ 那句「有几个版本没能拿到这份数据」
     *    **一次都没显示过**。⚠️ 它不报错、不留痕，只是永远看不见 ——
     *    与 `ForEach` 那条「做完了没刷新」是同一族：**写进去了，但没人读得到**。 */
    this.isolationNote = extraFails.length > 0
      ? ('隔离已经打开，但有几个版本没能拿到这份数据：' + NL + extraFails.join(NL))
      : '';
    this.showIsolationAsk = false;
    this.pendingGranularity = '';
    this.copyTargets = [];
    this.copyPicked = [];
    /* [A] ⭐⭐ **刷新**，而这一句是用户 2026-10-02 报上来的缺口。
     *
     * ⛔⛔ 后果是这样的：复制**其实成功了**（设备日志：`copied 14 dir(s) / 188 file(s)`），
     *    但界面没重算 ⇒ `savesDirShown`、存档列表、版本列表**全停在旧值**
     *    ⇒ 屏幕上一切照旧 ⇒ 玩家得出结论「**复制不成功**」。
     *    ⚠️ 他报的那两条症状（「没自动刷新」和「复制不成功」）**是同一件事**：
     *    一条是机制，一条是他看到的现象。
     *    ⇒ ⭐ 教训：**功能做完了但没刷新，与功能坏了在界面上长得一模一样。**
     *    凡是会改变「界面依据什么来算」的动作，都必须显式重算一次 ——
     *    ⛔ 不能指望 @State 自己发现文件系统变了（它不会）。
     */
    this.refresh();
  }

  /** [B] 询问里选了「从空开始」。原数据留在原处（关掉隔离还能看到），新目录是空的。 */
  private applyIsolationEmpty(): void {
    this.granularity = this.pendingGranularity;
    writeGranularity(this.filesDir, this.granularity);
    this.isolationNote = '';
    this.showIsolationAsk = false;
    this.pendingGranularity = '';
    /* [B] 与「复制过去」同一条道理：这条路也换了数据目录，界面必须重算。
     * ⚠️ 界面上会**看起来像空的** —— 那是真的（玩家选的就是「不复制」），
     *    但必须让它是**新目录的空**，而不是停在旧目录的内容上。 */
    this.refresh();
  }

  /* [A] ⭐⭐ 「隔离开着，但**当前版本那一档**还是空的」—— 这里给它一个出口。
   *
   * ⛔⛔ 用户 2026-10-02 报「复制过去的新存档全都看不见」，而他踩到的是**这条路没有出口**：
   *    · 复制只发生在**改粒度**那一刻（`chooseGranularity` → 询问 → `applyIsolationCopy`）
   *    · 而他换 jar（159.7）是在**改完粒度之后** ⇒ 键从 `bundled` 变成 `b159`
   *    · 这时粒度**没变**（还是 build）⇒ `chooseGranularity` 第一行就 return ⇒ **再也不弹那个窗**
   *    ⇒ 新键那份目录**没有任何代码路径去建它** ⇒ 进游戏看到空数据，
   *      而界面上只有一句「请把隔离关掉（或重新打开一次）」—— 那是让他去**猜**我该做的事。
   *
   * ⭐ 实测（同一台平板，2026-10-02），两个事实都读自设备、不是推的：
   *      `isolation: bridge written -- enabled=1 key=b159`
   *      `isolation: STALE -- on, but /data/.../instances/b159/sets/default/.local/share/Mindustry does not exist`
   *      而 `instances/` 下只有 `bundled` 与 `n8` —— **没有 b159**。
   *
   * ⭐ 判据（本项目的老账「门关上了也要有开它的路」）：
   *    「目标目录是空的」是一个**状态**，那就必须有一个**只针对这个状态**的出口。
   *
   * ⭐ 为什么是**内嵌的一块**而不是弹窗：状态一出现它就一直在（切页签、切版本回来都还在），
   *    而弹窗只在那一刻响一次 —— 手一滑关掉就再也找不到它了。
   *    ⚠️ 这同时就是用户说的「切版本时再问一次」：换一个 jar ⇒ 目标目录又空了 ⇒ 这块又出现。
   *
   * ⛔ 只补**当前版本**这一个键（他的两个提案里选的是这个）—— 别的键一律不动，
   *    已有的数据一律不覆盖（`copyLiveDataInto` 只在目标目录**不存在**时才被这里调到）。
   */
  private copyStaleCurrent(): void {
    this.staleCopyNote = '';
    const res: GameResolution = resolveGame(this.filesDir, this.bundleCodeDir);
    const key: string = resolveGameDirAndKey(this.granularity, res.source, res.path,
                                             this.bundledJar()).key;
    if (key === '') {
      /* [B] 不隔离时这一块根本不显示；走到这里说明状态刚好变了。
       * ⛔ 不要硬造一个键 —— 那会造出一个游戏根本不会去读的目录。 */
      this.staleCopyNote = '现在没有开启隔离，没有可以复制进去的分类';
      this.refresh();
      return;
    }
    const note: string = copyLiveDataInto(key);
    if (note !== '') {
      this.staleCopyNote = note;
    } else {
      this.isolationNote = '已经把数据复制进这一档（' + key + '）。';
    }
    /* [A] ⭐ 必须显式重算 —— 复制成功后这块会**自己消失**，而存档列表会当场填上。
     * ⛔ 不刷新的话，「复制成功」与「什么都没发生」在界面上长得一模一样。 */
    this.refresh();
  }

  /* [A] 上面那个状态的界面。⭐ 零参 `@Builder`，所以**设置页与存档页可以共用同一份**
   * （本文件开头那条「带参数的 @Builder 不会因状态变化重跑」只针对**带参数**的那种）。
   */
  @Builder
  StaleCopyOffer() {
    Column() {
      Text('⚠ 隔离开着，但当前版本这一档还是空的 —— 进游戏会看到空的数据。'
           + '你的存档一直都在（在「未隔离的那一份」里）。')
        .fontSize(12).fontColor($r('sys.color.warning'))
        .width('100%')
      /* [B] 失败时**留在这块里**说清楚，因为失败意味着状态没变、这块还会在。
       * ⛔ 不写成弹窗：失败一次就弹一次的话，玩家得先关掉窗才看得见下面还有什么。 */
      if (this.staleCopyNote !== '') {
        Text(this.staleCopyNote)
          .fontSize(12).fontColor($r('sys.color.warning'))
          .width('100%').margin({ top: 6 })
      }
      Row() {
        Button('把未隔离的那份复制过来')
          .fontSize(BUTTON_FONT_VP)
          .onClick(() => { this.copyStaleCurrent(); })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
      .margin({ top: 8 })
    }
    .width('100%')
    .padding(14)
    .borderRadius(CARD_RADIUS_VP)
    .backgroundColor($r('app.color.launcher_bg'))
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: 16 })
  }

  /* [A]
   * 那个文件夹就绪了，重读一遍。
   *
   * ⚠️ 只在 true 时重读。父组件只会把它从 false 翻到 true（没有回头路），所以这里的
   * 判断其实是冗余的 —— 留着是因为「值变了一下就重干活」这个形状如果哪天被改成双向，
   * 冗余的那一半就成了唯一挡住无谓重读的东西。
   *
   * ⚠️ 重读是【幂等】的：refresh() 只是按当前磁盘重新算 games/selected/resolution，
   * 不写任何东西（writeSelection 只在玩家点选时走）。所以玩家在等待期间已经点过选择，
   * 也不会被这次重读抹掉 —— 它读的正是玩家那次写下的。
   */
  onFolderSettled(): void {
    if (this.folderSettled) {
      this.refresh();
    }
  }

  /* [A]
   * 应用自己的显示名 —— 也就是文件管理器给那个文件夹看的名。
   *
   * ⚠️ **从资源读，不硬编码。** 两个仓库的应用名不同（Mindustry Ark / Ark Launcher），
   *    硬编码意味着其中一边必然写错，而且改名时不会有人想起来改这里。
   *    走资源还顺带拿到**当前语言**下的名字。
   *
   * ⚠️ 读不到就返回 ''，调用方那时只显示真实路径 —— 退化成改之前的行为，
   *    比显示一个错的路径好。
   */
  private resolveAppLabel(): string {
    try {
      const rm = getContext(this).resourceManager;
      return rm.getStringSync($r('app.string.EntryAbility_label').id);
    } catch (e) {
      const err = e as BusinessError;
      hilog.info(DOMAIN, TAG, 'launcher: cannot read the app label (%{public}s)', err.message);
      return '';
    }
  }

  /* [A]
   * 弹窗宽度（vp）。两个弹窗都用它 —— ⚠️ 一个地方拥有这个规则，不然两处会各自漂移。
   *
   * ⚠️ `winW` 在 onAreaChange 之前是 0，那时返回下限。它是 @State，所以量到宽度之后
   * build 会重跑，宽度自己就到位了。
   */
  private dialogWidthVp(): number {
    return Math.max(DIALOG_MIN_VP, this.winW * DIALOG_WIDTH_FRACTION);
  }

  /* [A]
   * 一个页签项 —— 用【原生】`BottomTabBarStyle`，不是自定义的 `@Builder`。
   *
   * ⛔⛔ 这里有一段失败的历史，别重走：
   *
   *   1. 最初用的是自定义 @Builder（`Column { SymbolGlyph; Text }`）。图标能显示，
   *      但**没有按下去的反馈** —— `tabBar()` 收到自定义 builder 时，系统就不再绘制
   *      它自己的页签项，而那套按压高光与沉浸光感的交互**只存在于系统画的那一个里**。
   *   2. 我于是自己补了 `stateStyles({ pressed: ... })`。**编译器内部崩过一次**
   *      （`Node must have a real position` —— 状态对象要用点前缀语法），修好之后编译过了，
   *      但效果是假的：那只是「一个半透明方块」，不是鸿蒙的沉浸光感。
   *      用户原话：「按压效果不对，不是鸿蒙的沉浸光感。这个应该是要用鸿蒙的原生底栏
   *      组件自带的效果。你自己应该搞不出来的。」
   *
   * ⇒ 正解：把**图标**交给 `TabBarSymbol`、把**页签项**交给 `BottomTabBarStyle`，
   *   让系统去画它自己的页签 —— 按压、选中高亮、与 `barFloatingStyle` 里那层
   *   沉浸光感的配合，就全都是原生的了。
   *
   * ⭐ 颜色并没有因此丢掉：`TabBarSymbol` 的 `normal` / `selected` 两个
   *   `SymbolGlyphModifier` 正好接住原来那套「未选中用次要色 / 选中用品牌色」。
   *
   * ⚠️ 图标仍然是 `$r('sys.symbol.*')`（矢量、跟字体无关），这一点没变，见下面原注释。 */
  private tabItem(symbol: Resource, label: string): BottomTabBarStyle {
    /* [A] **系统符号，不是 emoji。**
     *
     * 之前用的是 🎮 / ⚙️ —— 那是**字符**，不是图标：它们由字体决定长相，
     * 在有的设备上是彩色 emoji、有的是单色轮廓，而且**跟着系统字体漂移**。
     * 用户的原话是「现在的是不是字符当成图标？有没有扁平化的UI」—— 是的，就是字符。
     *
     * `$r('sys.symbol.*')` 是鸿蒙自己的矢量图标，扁平、随主题变色、**跟字体无关**。
     * 而且参考项目 AMCL 用的就是这一套，所以这正是「通用样式」。
     *
     * ⚠️ 名字不是记来的，是在 SDK 的资源索引里核过的：`house_fill` 与
     * `gearshape_fill` 都在。而且**编译器会校验** —— 写错名字会报
     * `Unknown resource name`，这一条对 `sys.color.*` 已经实测过一次。 */
    const marks: TabBarSymbol = {
      normal: new SymbolGlyphModifier(symbol).fontColor([$r('sys.color.font_secondary')]),
      selected: new SymbolGlyphModifier(symbol).fontColor([$r('sys.color.brand')]),
    };
    return new BottomTabBarStyle(marks, label);
  }

  /* [B] 内置那份游戏 jar 的路径 —— 它现在参与**算隔离键**（同版本要合并）。
   * ⚠️ 做成方法是为了让「合并规则用的是哪一份内置」只有一处。 */
  private bundledJar(): string {
    return bundledGamePath(this.bundleCodeDir);
  }

  /** [B] 重新读一遍磁盘。文件夹在这里【再确认一次】存在，因为玩家可能刚把它删掉。 */
  private refresh(): void {
    ensureGameJarDir(this.filesDir);
    this.games = listGameJars(this.filesDir);
    this.selected = readSelection(this.filesDir);
    this.resolution = resolveGame(this.filesDir, this.bundleCodeDir);
    this.bundledVer = bundledGameVersion(this.bundleCodeDir);
    this.hasBundled = hasBundledGame(this.bundleCodeDir);

    /* [A] 存档。⚠️ 目录**取决于隔离状态** —— 用与 native 算 `user.home` 同一套输入，
     * 否则这里会列出另一份存档，而那是最坏的一类不一致：界面上看起来完全正常。
     * ⚠️ 但两者仍可能分叉：玩家改了粒度但还没重启时，游戏那边还是旧目录。 */
    const dataDir: string = resolveGameDataDir(this.granularity, this.resolution.source,
                                              this.resolution.path, this.bundledJar());
    const dir: string = dataDir + '/saves';
    this.savesDirShown = dir;
    this.saves = listSaves(dir);
    /* [A] ⭐ 「开关拨过去了、数据没过去」。判据是两条**都**成立：
     *    ① 隔离开着；② 目标数据目录不存在，而**未隔离**那一份存在（真的丢不了东西）。
     * ⚠️ 第二个条件不能省：全新安装、第一次就打开隔离时目标也是空的，那是**正常**的
     *    （玩家选了「不复制」），不该报警。只有当「原来有数据、现在指向空目录」才是异常。
     * ⚠️ 这也正是我在 `buildVersions` 里已经有 `gameDataExists` 的那个调用能顺手做掉的事。 */
    this.isolationStale = (this.granularity !== GRANULARITY_OFF)
                       && !gameDataExists(dataDir)
                       && gameDataExists(liveGameDataDir());
    /* [A] ⚠️ 只在**异常**时才记一行 —— 那就正是需要日志的时候，而它一旦修好就自动安静了。
     * ⭐ 它把「界面上有没有那条警告」变成一条**能读出来的**事实，不必靠眼睛看屏幕。 */
    if (this.isolationStale) {
      hilog.error(DOMAIN, TAG, 'isolation: STALE -- on, but %{public}s does not exist '
                + '(the un-isolated copy does)', dataDir);
    } else {
      /* [B] 状态解除了 ⇒ 上一次那句「没复制成功」不再关于任何东西 —— 清掉。
       * ⚠️ 不清的话它会一直挂在 `StaleCopyOffer` 里，等**下一次**出现空的档位时
       *    重新露出来，而那时它说的是另一个键的事。⛔ 一条关于旧状态的错误消息
       *    比没有消息更坏：它指向一个已经不存在的问题。 */
      this.staleCopyNote = '';
    }
    /* [A] ⚠️ 版本列表要在 `resolution` / `hasBundled` / `games` **都算好之后**才能建 ——
     * 它三样都用（判定谁是「当前版本」、内置那份在不在、有哪些玩家 jar）。
     * 而建它的那一步会**读每个 jar**（见 versionEntryOf 上的说明），所以整轮 refresh
     * 只建一次，渲染只用结果。
     *
     * ⚠️ 顺序：必须在上面那个「清掉失效的 selectedSave」之后 —— 它可能把 selectedSave
     * 清成 ''，而接着 loadSelectedMeta 要按最新的值去读。 */
    this.versions = this.buildVersions();
    /* [B] 选中的版本没了（jar 被删了）⇒ 退回当前版本，别让右边空着。
     * ⚠️ 「当前版本」一定在这一批里（它要么是内置的、要么来自 games），所以这个兜底是可靠的。 */
    if (this.selectedVersion === ''
        || !this.versions.some((v: VersionEntry) => v.path === this.selectedVersion)) {
      const cur: VersionEntry | undefined = this.versions.find((v: VersionEntry) => v.isCurrent);
      this.selectedVersion = cur === undefined ? '' : cur.path;
    }
    this.loadVersionSaves();
    /* [A] 垃圾站：**清掉到期的**，再读一遍名单。
     * ⚠️ 放在 `refresh()` 里（而不是渲染里）—— 它要扫目录、还要真删文件，
     *    ⛔ 每帧跑一次是不可接受的。`refresh()` 只在切页签/切版本/改设置/操作完之后跑。 */
    this.reloadVault();
    this.vaultDays = readVaultDays(this.filesDir);
    /* [A] ⭐⭐ 「按存档」那一屏的数据 —— **所有版本**的存档，按数据目录分组。
     * ⚠️ 必须在 `this.versions` 算好之后（它逐个版本解目录），见 buildSaveGroups。 */
    this.saveGroups = this.buildSaveGroups();
    /* [B] **清失效的选中**放在这之后 —— 它要拿 saveGroups 去查那一行还在不在。
     * ⚠️ 换隔离粒度、删掉一个存档、切换版本，都会让原来那一行消失。 */
    if (this.selectedSave !== '' && this.selectedSaveRow() === undefined) {
      this.selectedSave = '';
    }
    /* [A] ⚠️ 必须显式再读一次。`@Watch` 只在 id **真的变了**时才触发，而这里的
     * 常见情形恰恰是「id 没变、那份存档换了」—— 例如改了隔离粒度再回来：列表整份换掉，
     * 但选中的那个如果两边同名，id 就一模一样。那时右侧栏会**显示上一个目录的元数据**，
     * 而界面上完全看不出不对。 */
    this.loadSelectedMeta();
    this.jarDirHint = gameJarDir(this.filesDir);
    /* ⚠️ 父文件夹叫 `Download`（单数）—— 这是**磁盘上的名字**，不是英文惯用的
     * "Downloads"。判据：`user_dirs.txt` 里记的是
     * `/storage/Users/currentUser/Download/com.haohandc.mindustryark`，
     * 而 `Environment.getUserDownloadDir()` 也返回 `.../currentUser/Download`。
     * 文件管理器显示的就是磁盘上的名字，所以写复数会让玩家去找一个不存在的文件夹。 */
    this.jarDirHuman = this.jarDirHint === '' ? '' : ('Download/' + this.appLabel + '/games');
    hilog.info(DOMAIN, TAG, 'launcher: %{public}d jar(s), resolved=%{public}s (%{public}s)',
               this.games.length, this.resolution.path === '' ? '(none)' : this.resolution.path,
               this.resolution.source);
  }

  /** [B] 当前选中的那个存档项；没选（或它已经不在了）时 `undefined`。 */
  private selectedSaveRow(): SaveRow | undefined {
    if (this.selectedSave === '') {
      return undefined;
    }
    const cut: number = this.selectedSave.indexOf('|');
    if (cut < 0) {
      return undefined;
    }
    const dir: string = this.selectedSave.substring(0, cut);
    const id: string = this.selectedSave.substring(cut + 1);
    const g: SaveGroup | undefined = this.saveGroups.find((x: SaveGroup) => x.dir === dir);
    if (g === undefined) {
      return undefined;
    }
    const e: SaveEntry | undefined = g.saves.find((s: SaveEntry) => s.id === id);
    return e === undefined ? undefined : { dir: dir, entry: e };
  }

  private selectedSaveEntry(): SaveEntry | undefined {
    const r: SaveRow | undefined = this.selectedSaveRow();
    return r === undefined ? undefined : r.entry;
  }

  /* [A] ⭐ 选中那一行**所在的目录** —— 每个动作都该用它。
   * ⛔ 别退回 `savesDirShown`：那是**当前版本**的目录，而现在列表里可能有
   *    好几个版本的存档，「当前」与「选中的那个」不是一回事。 */
  private selectedSaveDir(): string {
    const r: SaveRow | undefined = this.selectedSaveRow();
    return r === undefined ? '' : r.dir;
  }

  /** [B] 存档列表里一行的选中键。⭐ 唯一性靠**目录**，见 `selectedSave` 的说明。 */
  private saveKey(dir: string, id: string): string {
    return dir + '|' + id;
  }

  /** [B] 选中那一行属于哪些版本。⭐ 详情面板用它写「属于：A、B」。 */
  private selectedSaveVersions(): VersionEntry[] {
    const r: SaveRow | undefined = this.selectedSaveRow();
    if (r === undefined) {
      return [];
    }
    const g: SaveGroup | undefined = this.saveGroups.find((x: SaveGroup) => x.dir === r.dir);
    return g === undefined ? [] : g.versions;
  }

  /* [A] 下面三个是给右侧栏用的取值函数。
   * ⚠️ 为什么做成方法而**不是**在 `build()` 里声明局部变量：ArkUI 的 `build()` / `@Builder`
   *    里**不允许声明本地变量** —— 那些语句会被当成 UI 描述解析，编译报的是语法错。
   *    ⇒ 需要在界面上用的每一个值，都得是一个能直接写进表达式的方法。 */

  /** [B] 选中存档的显示名；没选时空串。 */
  private selectedSaveLabel(): string {
    const sv: SaveEntry | undefined = this.selectedSaveEntry();
    return sv === undefined ? '' : sv.label;
  }

  /** [B] 一行摘要：几个区块、几个文件、多大。 */
  private selectedSaveSummary(): string {
    const sv: SaveEntry | undefined = this.selectedSaveEntry();
    if (sv === undefined) {
      return '';
    }
    const parts: string[] = [];
    if (sv.kind === 'sector') {
      parts.push(String(sv.sectors) + ' 个区块');
    }
    parts.push(String(sv.files.length) + ' 个文件');
    parts.push(formatSaveSize(sv.bytes));
    return parts.join(' · ');
  }

  /** [B] 「最后更新 YYYY-MM-DD」。 */
  private selectedSaveUpdated(): string {
    const sv: SaveEntry | undefined = this.selectedSaveEntry();
    return sv === undefined ? '' : ('最后更新 ' + formatSaveDate(sv.mtime));
  }

  /* [A] `loadSelectedMeta()` 上次读的是哪一个（`id@目录`）。
   * ⚠️ 刻意**不是** `@State` —— 它不参与渲染，只是去重用的账本。做成 @State 会让
   *    每次读完之后再多一次无意义的界面刷新。 */
  private metaLoadedKey: string = '';

  /** [A] `@Watch` 的落点。选中变了 ⇒ 去读那个存档的元数据。 */
  private onSaveSelected(): void {
    this.loadSelectedMeta();
  }

  /* ==================================================================
   * 「按版本」视图
   * ================================================================== */

  /* [A]
   * 造一个版本项。
   *
   * ⚠️ 它**读 jar**（`resolveGameDirAndKey` 里的 `computeKey` 最终会读
   *    `version.properties`），所以只能从 `buildVersions()` 里调 ——
   *    ⛔ 绝不能在渲染路径上调。渲染每帧都会跑，而这里每帧都会去开一次 jar。
   */
  private versionEntryOf(path: string, source: string,
                         label: string, version: string): VersionEntry {
    const rk: GameDirForKey = resolveGameDirAndKey(this.granularity, source, path, this.bundledJar());
    return {
      path: path,
      source: source,
      label: label,
      version: version,
      key: rk.key,
      dataDir: rk.dir,
      isCurrent: false,
      saveCount: 0,
      hasData: false,
    };
  }

  /* [A]
   * 列出已装的版本：**内置的排最前**，然后是玩家导入的。
   *
   * ⭐ 为什么内置第一：它永远在（我们跟着包一起发的），而且是「玩家什么都没选」时的落点。
   *    放在最前，玩家扫一眼就知道「不折腾的话就是这一份」。
   *
   * ⚠️ 数存档那一步**按目录去重** —— 隔离关着时每个版本算出来的都是同一个目录，
   *    不去重就会把同一个目录列 N 遍（N = 版本个数）。
   */
  private buildVersions(): VersionEntry[] {
    const out: VersionEntry[] = [];
    if (this.hasBundled) {
      out.push(this.versionEntryOf(bundledGamePath(this.bundleCodeDir), 'bundled',
                                   '内置游戏', this.bundledVer));
    }
    for (const g of this.games) {
      out.push(this.versionEntryOf(g.path, 'user', g.name, g.version));
    }
    for (const v of out) {
      v.isCurrent = (v.source === this.resolution.source && v.path === this.resolution.path);
    }

    /* [B] 一个目录只列一次。`Map` 而不是对象字面量 —— ArkTS 拒绝无类型对象字面量。 */
    const counted: Map<string, number> = new Map<string, number>();
    for (const v of out) {
      let n: number | undefined = counted.get(v.dataDir);
      if (n === undefined) {
        n = listSaves(v.dataDir + '/saves').length;
        counted.set(v.dataDir, n);
      }
      v.saveCount = n;
      v.hasData = gameDataExists(v.dataDir);
      /* [A] ⭐ 每个版本记一行：标签 / 版本号 / 隔离键 / 数据目录。
       * ⭐ 这一行是「我换了版本怎么看不到存档了」的**第一手答案** ——
       *    看一眼 key 就知道两个 jar 有没有落进同一个目录，
       *    而这是**光看界面推不出来**的（界面上只写版本号，不写键）。
       * ⚠️ 只在 refresh() 里跑，⛔ 不在渲染路径上。 */
      hilog.info(DOMAIN, TAG, 'version: %{public}s | %{public}s | key=%{public}s | %{public}s',
                 v.label, v.version === '' ? '(unknown)' : v.version, v.key, v.dataDir);
    }
    /* [A] ⭐ 记一行「有几个版本、几个**不同的**数据目录」。
     *
     * ⭐ `distinct` 这个数是这一屏的**核心诊断**：它 > 1 才说明隔离真的把它们分开了，
     *    = 1 就是「所有版本共用一份」（隔离关着，或者粒度太粗）。
     * ⚠️ 玩家问「我换了版本怎么看不到存档了」时，第一个要看的就是这个数 ——
     *    而它**不是** UI 上那个「N 个版本」（那个只数版本，说不出有没有分开）。
     * ⚠️ 它只在 refresh() 里跑，不在渲染路径上 ⇒ 不会刷屏。 */
    hilog.info(DOMAIN, TAG, 'saves: %{public}d version(s), %{public}d distinct data dir(s)',
               out.length, counted.size);
    return out;
  }

  /* [A]
   * ⭐⭐ 把**所有版本**的存档按数据目录聚起来 —— 「按存档」那一屏的数据源。
   *
   * ⚠️ 按**目录**分组而不是按版本：隔离关着时所有版本共用一份数据，
   *    按版本分会让同一批存档出现 N 遍；按目录分恰好一组，
   *    而组头的版本名单正好就是「属于哪几个版本」。
   *
   * ⭐ 顺序：`this.versions` 的顺序（内置在前、玩家 jar 在后）⇒ 组也是这个序，
   *    也就是用户要的「A版本 → B版本 这样排下去」。
   *
   * ⚠️ 另外补一组**未隔离的那一份**（只在它不属于任何版本时）：
   *    「复制过去」刻意不动源目录（为了可逆），所以那份原始数据会一直留着。
   *    ⛔ 不列出来的话，玩家会以为它不见了 —— 而它其实是最后一道保险。
   *    ⚠️ 隔离关着时它**就是**各版本那一组，所以那时不会重复列。
   */
  private buildSaveGroups(): SaveGroup[] {
    const out: SaveGroup[] = [];
    const byDir: Map<string, SaveGroup> = new Map<string, SaveGroup>();
    for (const v of this.versions) {
      const dir: string = v.dataDir + '/saves';
      let g: SaveGroup | undefined = byDir.get(dir);
      if (g === undefined) {
        g = { dir: dir, versions: [], saves: listSaves(dir), orphanKey: '' };
        byDir.set(dir, g);
        out.push(g);
      }
      g.versions.push(v);
    }
    const liveDir: string = liveGameDataDir();
    const live: string = liveDir + '/saves';
    if (byDir.get(live) === undefined && gameDataExists(liveDir)) {
      const only: SaveGroup = { dir: live, versions: [], saves: listSaves(live), orphanKey: '' };
      if (only.saves.length > 0) {
        out.push(only);
      }
    }
    /* [A] ⭐⭐ **`instances/` 下没有版本读的那些目录也要列出来。**
     *
     * ⛔⛔ 光靠 `this.versions` 推不出它们，而它们的来源全是**规则的改变**：
     *    · 换粒度（小版本 → 构建号）⇒ 昨天的 `b160.5` 今天没有版本指向它
     *    · 换 jar ⇒ 同理
     *    · 内置/同版本合并 ⇒ 玩家 jar 原来那个槽位立刻变成没人读
     *    ⭐ 第三种就是**这次改动自己会造出来的** —— 不做这一步，合并完的下一眼
     *      就会是「我的 160.5 存档不见了」，而那是我**亲手**造成的。
     *
     * ⚠️ 只列**真有存档**的（空目录列出来只是噪音，而它没有任何东西可丢）。
     * ⛔ 也不要列已经被 `byDir` 认领的 —— 那样同一份数据会出现两遍。 */
    for (const k of listInstanceKeys()) {
      const d: string = isolatedGameDataDir(k);
      if (byDir.get(d + '/saves') !== undefined) {
        continue;
      }
      const saves: SaveEntry[] = listSaves(d + '/saves');
      if (saves.length === 0) {
        continue;
      }
      out.push({ dir: d + '/saves', versions: [], saves: saves, orphanKey: k });
      hilog.warn(DOMAIN, TAG, 'save group: %{public}s has %{public}d save(s) but no version reads it',
                 k, saves.length);
    }
    /* [A] ⛔⛔ **订正（2026-10-02，用户报上来的）：空组不再丢掉。**
     *
     * ⭐ 我原来在这里丢掉空组，理由是「一屏 5 组、3 组空，噪音大过信息」——
     *    那是我自己的判断，**不是他的要求**，而它的代价他立刻就说出来了：
     *    「我按最小粒度，只显示了内置游戏和159.7，**其他的消失了**」。
     *
     * ⭐⭐ 真正让那个判断站不住的是**后来加的东西**：每一组现在都是
     *    「把未隔离的那份复制过来」的**去处**（见 `StaleCopyOffer`）。
     *    ⇒ 一个空组**不是噪音，是一个还没填的槽位**；把它藏起来，
     *      玩家就没法把数据放进那个版本 —— 而那正是他要做的事。
     *
     * ⚠️ 于是判据从「有没有存档」换成「**有没有版本**」：
     *    有版本读的目录一律列出来，哪怕它现在是空的。
     * ⛔ 而未隔离的那一份仍然只在真有存档时才补进来（见上）——
     *    它不属于任何版本，空的时候确实没有意义。 */
    for (const g of out) {
      hilog.info(DOMAIN, TAG, 'save group: %{public}d save(s), %{public}d version(s), %{public}s',
                 g.saves.length, g.versions.length, g.dir);
    }
    return out;
  }

  /* [A] ⭐⭐ 一组的标题。**顺序是用户定的**（2026-10-02）：
   *    「先展示**版本**，再展示**文件名**。比如 v8 Build 159.7 (xxx.jar)」。
   *
   * ⇒ 形状是 `v8 Build 160.5（内置游戏, Mindustry160.5.jar）`。
   *
   * ⛔ 我上一版是反的（`内置游戏（v8 Build 160.5）`），理由是「名字是身份」——
   *    而那个理由只在**单个**版本时成立。一组里可能有好几个版本，那时名字串在最后
   *    反而更容易看：先读到「这是哪个版本」，再看「都是谁在用」。
   *
   * ⚠️ **一组里可能有两个不同的版本号**：构建号档下 `160.4` 与 `160.5` 折进同一个槽位。
   *    ⇒ 版本号要去重后**全部列出来**（`/` 分隔），⛔ 不能只写第一个 ——
   *      那会让 160.4 的那份数据看起来属于 160.5。
   *
   * ⚠️ 版本读不出来时写「未知版本」，⛔ 不留空 —— 空着会被读成「没有版本」。
   */
  private groupTitle(g: SaveGroup): string {
    if (g.versions.length === 0) {
      /* [B] 两种「没人读」：以前某一档留下的键 vs 未隔离的那一份本身。 */
      return g.orphanKey === '' ? '未隔离的那一份' : ('没有版本读它（' + g.orphanKey + '）');
    }
    const vers: string[] = [];
    const names: string[] = [];
    for (const v of g.versions) {
      const s: string = v.version === '' ? '未知版本' : v.version;
      if (vers.indexOf(s) < 0) {
        vers.push(s);
      }
      names.push(v.label);
    }
    return vers.join(' / ') + '（' + names.join(', ') + '）';
  }

  /** [B] 一组的副标题：谁在读它。 */
  private groupSub(g: SaveGroup): string {
    if (g.versions.length === 0) {
      if (g.orphanKey !== '') {
        /* [A] ⭐ 说清**它从哪来**，并给出路 —— ⛔ 只说「没人读」会让玩家以为这是垃圾。
         * ⭐ 最常见的成因就是我们自己改的合并规则，所以那句要写在这里。 */
        return '这是以前某一档隔离留下的数据，现在没有版本指向它了 —— '
             + '要接着玩，就从某一组里复制/移动一份过去（或者在「按版本」那边看看谁和它同版本）';
      }
      return '现在没有版本读它 —— 这是你数据最初的那一份，「复制过去」不会动它';
    }
    /* [A] ⭐ 标出**游戏真正会读的那一份**（当前版本指向的目录）。
     * ⛔ 不标的话，玩家看到两堆存档会不知道哪个是「正在玩的」——
     *    而那正是他换粒度之后第一个要问的问题。 */
    const cur: boolean = g.versions.some((v: VersionEntry) => v.isCurrent);
    const head: string = cur ? '当前版本在用 · ' : '';
    if (g.versions.length === 1) {
      return head + '只有这个版本读它';
    }
    return head + String(g.versions.length) + ' 个版本共用同一份数据';
  }

  /** [B] 当前选中的那个版本项；没选或它已经不在（jar 被删了）时 `undefined`。 */
  private selectedVersionEntry(): VersionEntry | undefined {
    if (this.selectedVersion === '') {
      return undefined;
    }
    return this.versions.find((v: VersionEntry) => v.path === this.selectedVersion);
  }

  /* [A]
   * 读选中版本的数据目录里有哪些存档。
   *
   * ⚠️ 这里**只列文件名**（`listSaves` 不读内容、不解压），所以它很便宜 ——
   *    与选中存档时那次解压完全不是一回事。
   *
   * ⚠️⚠️ 它读的是**那个版本自己的**目录，而 `savesDirShown` 是**当前版本**的目录。
   *    两者在「看的是别的版本」时**不一样**，所以这里绝不能借 `savesDirShown`。
   *    同理，这个列表里**不做**任何元数据读取 —— `loadSelectedMeta()` 只认
   *    `savesDirShown`，混着用就会读到另一个目录的元数据，而界面上看不出不对。
   */
  private loadVersionSaves(): void {
    const v: VersionEntry | undefined = this.selectedVersionEntry();
    if (v === undefined) {
      this.versionSaves = [];
      return;
    }
    this.versionSaves = listSaves(v.dataDir + '/saves');
  }

  /** [A] `@Watch` 的落点。切版本 ⇒ 换那一份存档名单。 */
  private onVersionSelected(): void {
    this.loadVersionSaves();
  }

  /** [B] 还有哪些版本**和它共用同一个数据目录**（不含它自己）。 */
  private versionsSharingDir(dir: string, exceptPath: string): VersionEntry[] {
    return this.versions.filter((v: VersionEntry) =>
      v.dataDir === dir && v.path !== exceptPath);
  }

  /* [A]
   * 「哪些版本能看到【当前这个存档】」。
   *
   * ⭐ 判据是**目录相等**，⛔ 不是比较版本号或存档里的 `build`。
   *    理由：游戏按 `user.home` 选数据目录，而 `user.home` 由隔离键算出来
   *    ⇒ **「谁看得到」是一个目录问题，不是兼容性问题。** 这是能确切回答的那个问题。
   *    ⚠️ 而「这个存档能不能被某个版本**读**」是另一件事（要看模组与版本规则），
   *    我们答不了，所以不在这儿答。
   *
   * ⚠️ 隔离关着时所有版本都指向同一个目录 ⇒ 这里自然是「全部」。那是**对的**，
   *    不是 bug —— 它正是「不隔离」的含义。
   */
  private savesSeenByText(): string {
    const seen: VersionEntry[] = this.selectedSaveVersions();
    if (seen.length === 0) {
      /* [B] 没有版本读这个目录 ⇒ 它是那份「未隔离的原始数据」。
       * ⛔ 不要显示成「没有」—— 要说清它是什么，否则玩家会以为这是个坏掉的条目。 */
      return '没有版本在读它 —— 这是你数据最初的那一份';
    }
    if (seen.length === this.versions.length) {
      return '全部 ' + String(seen.length) + ' 个版本';
    }
    const names: string[] = [];
    for (const v of seen) {
      names.push(v.label);
    }
    return names.join('、');
  }

  /** [B] 头部那一行：视图不同，它要说的事情不同。 */
  private savesHeaderLine(): string {
    if (this.savesView === SAVES_VIEW_VERSION) {
      return this.versions.length === 0 ? '（没有可用的版本）'
                                        : (String(this.versions.length) + ' 个版本');
    }
    return this.savesDirShown === '' ? '（还没读到目录）' : this.savesDirShown;
  }

  /* [A] 下面这些是给「按版本」那一屏的取值函数。
   * ⚠️ 做成方法而**不是**在 `build()` 里声明局部变量 —— ArkUI 的 `build()` / `@Builder`
   *    里不许声明本地变量，那些语句会被当成 UI 描述解析，编译报的是语法错。 */

  /** [B] 版本列表项第二行里那截「N 个存档」。 */
  private versionSavesLine(v: VersionEntry): string {
    if (!v.hasData) {
      return '还没有数据';
    }
    return v.saveCount === 0 ? '目录在，没有存档' : (String(v.saveCount) + ' 个存档');
  }

  /* [A] ⭐ 这两个的**内容对调了**（2026-10-02）—— 用户要「版本在前、文件名在后」。
   *    `selectedVersionLabel` 现在给的是**版本号**（手机子页拿它当标题），
   *    `selectedVersionLine` 给的是文件名与「当前版本」。
   * ⚠️ 名字没跟着改，因为「label / line」说的是**位置**（大字那行 / 小字那行），
   *    而不是内容 —— 两处渲染点的结构不需要跟着动。 */
  private selectedVersionLabel(): string {
    const v: VersionEntry | undefined = this.selectedVersionEntry();
    if (v === undefined) {
      return '';
    }
    return v.version === '' ? '未知版本' : v.version;
  }

  /** [B] 选中版本的**文件名**那一行，附带「当前版本」。 */
  private selectedVersionLine(): string {
    const v: VersionEntry | undefined = this.selectedVersionEntry();
    if (v === undefined) {
      return '';
    }
    return this.selectedVersionIsCurrent() ? (v.label + '  ·  当前版本') : v.label;
  }

  /** [B] 选中版本是不是当前正在使用的那个。 */
  private selectedVersionIsCurrent(): boolean {
    const v: VersionEntry | undefined = this.selectedVersionEntry();
    return v === undefined ? false : v.isCurrent;
  }

  /** [B] 「这个目录里有 N 个存档」。 */
  private selectedVersionDataLine(): string {
    const v: VersionEntry | undefined = this.selectedVersionEntry();
    if (v === undefined) {
      return '';
    }
    if (!v.hasData) {
      return '这个版本还没有数据目录 —— 启动过一次之后才会建出来。';
    }
    return v.saveCount === 0 ? '数据目录在，但里面还没有存档。'
                             : ('这个目录里有 ' + String(v.saveCount) + ' 个存档。');
  }

  /** [B] 空名单时那句话：目录不在与目录空是两件事。 */
  private selectedVersionHasDataText(): string {
    const v: VersionEntry | undefined = this.selectedVersionEntry();
    if (v === undefined || !v.hasData) {
      return '还没有数据目录。';
    }
    return '还没有存档。';
  }

  /** [B] 选中版本的数据目录。 */
  private selectedVersionDir(): string {
    const v: VersionEntry | undefined = this.selectedVersionEntry();
    return v === undefined ? '' : (v.dataDir + '/saves');
  }

  /* [A]
   * 「还有谁共用这一份数据」。
   *
   * ⭐ 隔离**关着**时全部版本都会落进这一条（它们指向同一个目录）——
   *    那不是缺陷，那正是「不隔离」的定义。所以措辞要**陈述**，不是警告。
   * ⚠️ 隔离开着时也可能共用：粒度选「大版本」而两个 jar 是同一个大版本、
   *    或者粒度选「构建号」而两个 jar 只是小版本不同 —— 这两句都要能自然读通。
   */
  private selectedVersionSharedText(): string {
    const v: VersionEntry | undefined = this.selectedVersionEntry();
    if (v === undefined) {
      return '';
    }
    const shared: VersionEntry[] = this.versionsSharingDir(v.dataDir, v.path);
    if (shared.length === 0) {
      return '';
    }
    if (shared.length === this.versions.length - 1) {
      return '它和其余 ' + String(shared.length) + ' 个版本共用同一份数据 —— 数据没有隔离。';
    }
    const names: string[] = [];
    for (const s of shared) {
      names.push(s.label);
    }
    return '它和这些版本共用同一份数据：' + names.join('、');
  }

  /* [A]
   * 读当前选中存档的元数据，存进 `selMetaRows`。
   *
   * ⚠️ 这里会**解压一个 .msav**（走 native 的 `saveMetaText`），有真实成本 ——
   *    但一次只读**一个**文件，而且只在选中变化时做。列表那一步刻意不读内容就是这个原因
   *    （见 SaveLibrary 开头）。
   *
   * ⭐ **读的是组里最新的那个文件，并把它的名字放进第一行**（见 `metaRowsOf`）。
   *    一个 Serpulo 战役有 14 个区块文件，全部解压是几 MB 的 CPU，而玩家问「这是哪个版本
   *    写的」通常指**最近在玩的那一个**。⇒ 读一个，同时让「其他区块可能不同」看得见。
   *
   * ⚠️ 三种情形都要各自有话说，⛔ **不允许「读失败但界面上看着正常」**：
   *    a. 组里没有可用文件（只剩 `-backup`）；
   *    b. native 读不出来（不是合法 msav、或被截断）；
   *    c. 正常。
   */
  private loadSelectedMeta(): void {
    const sv: SaveEntry | undefined = this.selectedSaveEntry();
    /* [A] ⭐ 去重。读一次就是**解压一个 .msav**，而这件事会被两条路径同时触发：
     *    `@Watch`（选中变了）和 `refresh()` 里那次显式调用（换目录后 id 可能没变）。
     *    ⚠️ 实测：不加这一句，选中一个存档会**解压两遍**（日志里同一行出现两次）。
     *
     * ⭐ 键是 `id @ 目录`：id 相同但目录换了（改完隔离粒度再回来）**要**重读，
     *    而两者都没变时重读没有任何意义。 */
    const key: string = (sv === undefined ? '' : (sv.id + '@' + this.selectedSaveDir()));
    if (key === this.metaLoadedKey) {
      return;
    }
    this.metaLoadedKey = key;

    this.selMetaRows = [];
    this.selMetaNote = '';
    if (sv === undefined) {
      return;
    }
    const file: string = newestFileOf(sv, this.selectedSaveDir());
    if (file === '') {
      this.selMetaNote = '这个存档里没有可读的文件（只剩备份）。';
      hilog.info(DOMAIN, TAG, 'saves: %{public}s has no readable file', sv.id);
      return;
    }

    const m: SaveMeta = readSaveMeta(this.selectedSaveDir() + '/' + file);
    if (!m.ok) {
      this.selMetaRows = [{ label: '读取自', value: file }];
      this.selMetaNote = '这个文件读不出来，可能不是有效的存档，或者已损坏。';
    } else {
      this.selMetaRows = metaRowsOf(m, sv);
    }
    hilog.info(DOMAIN, TAG, 'saves: meta of %{public}s ok=%{public}s build=%{public}s',
               file, String(m.ok), m.build);
  }

  /* [A] 点一行的落点。⭐ 窄屏时**同时**打开子页 —— 手机上列表与详情放不下两栏，
   * 所以「选中」与「进去看」是同一个动作（用户 2026-10-02：「如果手机上点，
   * 就是进去那个子页面，可以返回退出」）。
   * ⚠️ 宽屏时不设 `panelOpen` —— 那时详情一直就在右边。 */
  /* [A] ⭐⭐ 点**已经选中的那一行** = 取消选中（用户 2026-10-02）：
   *    「点击我选中过的，取消选中，右边界面变空（单选时）」。
   *
   * ⭐ 为什么需要它：`selectedSave` 之前**只增不减** —— 一旦点过任何一行，
   *    右边就永远挂着一份详情，而“我不想看任何东西”这个状态**无法到达**。
   *    ⚠️ 那不只是少一个功能：右边那块占据屏幕的三分之一（3:7 的两栏），
   *      而它显示什么完全由一次很久以前的点击决定。
   *
   * ⚠️ **只在单选态生效**：多选态的点击是「勾/取消勾」，走 `toggleMultiPick`
   *    （调用点已经分开，见两张列表的 onClick）—— 两件事都叫“取消选中”，
   *    但取消的东西不同：这里取消的是**详情**，那里取消的是**勾选**。
   *
   * ⚠️ 窄屏（手机）**不在这里退子页**：手机上一个存档本来就是“进去看”，
   *    再点一下应当还是“看”，⛔ 不是把自己弹出去 —— 那会让人以为点坏了。
   *    出口是左上角那个返回箭头（它本来就在）。
   */
  private openSaveRow(dir: string, id: string): void {
    const key: string = this.saveKey(dir, id);
    if (this.selectedSave === key) {
      this.selectedSave = '';
      return;
    }
    this.selectedSave = key;
    if (this.isNarrow()) {
      this.panelOpen = true;
    }
  }

  /** [B] 「按版本」面板里那个版本的 `saves/` 目录。 */
  private versionSavesDir(): string {
    const v: VersionEntry | undefined = this.selectedVersionEntry();
    return v === undefined ? '' : (v.dataDir + '/saves');
  }

  /** [B] 版本列表同理。 */
  private openVersionRow(path: string): void {
    this.selectedVersion = path;
    if (this.isNarrow()) {
      this.panelOpen = true;
    }
  }

  /* ==================================================================
   * 垃圾站
   * ================================================================== */

  /* [A] ⭐ 垃圾站**只碰自己那点数据**的重新读盘，单独一条路。
   *
   * ⚠️ 为什么不靠 `refresh()`：那是**整页**重算（读每个 jar、扫三个目录），
   *    其中任何一步抛了，后面那些 `@State` 就一个都不会被赋值 ——
   *    而玩家看到的正是「点了没反应」。
   *    ⇒ 垃圾站的动作先走这条**短**路，界面立刻是对的；`refresh()` 再去做剩下的。
   *    （用户 2026-10-02 报的「取消归档和放回点了 UI 不刷新」，除开 ForEach 的 key，
   *      有一半是这个形状：磁盘上确实发生了，而界面没跟上。） */
  private reloadVault(): void {
    this.vaultPurgedLast = purgeExpired(Date.now());
    this.vaultEntries = listVault();
  }

  private openVault(): void {
    this.showVault = true;
    this.vaultNote = '';
    this.refresh();
  }

  private closeVault(): void {
    this.showVault = false;
    this.vaultNote = '';
    this.refresh();
  }

  /* [A]
   * 玩家点了「删除」。⛔ **不直接删** —— 先弹一个确认框，让他在
   * 「放进垃圾站（到期清理）」与「归档（不自动清理）」之间选一个。
   *
   * ⭐ 那两个就是垃圾站里条目的两种状态，所以这个确认框同时承担了
   *    「确认」与「选保留方式」两件事，不需要第二个窗。
   * ⚠️ 确认框里要写出**具体保留到哪一天** —— 「7 天」是抽象的，
   *    「保留到 2026-10-09 18:40」是玩家能判断的。
   */
  /* [A]
   * 列出「这一档下的每一个分类」，以及谁落进它、它有没有数据。
   *
   * ⚠️ 会读每个 jar（`resolveGameDirAndKey` → `computeKey` → `gameVersionParts`，
   *    那个函数没有缓存）⇒ 只在**点开这个选择**时算一次，⛔ 不在渲染里算。
   */
  private buildCopyTargets(g: string): CopyTarget[] {
    const out: CopyTarget[] = [];
    const byKey: Map<string, CopyTarget> = new Map<string, CopyTarget>();
    for (const v of this.versions) {
      const k: string = resolveGameDirAndKey(g, v.source, v.path, this.bundledJar()).key;
      if (k === '') {
        continue;   /* [B] 不隔离 ⇒ 没有分类可复制进 */
      }
      let one: CopyTarget | undefined = byKey.get(k);
      if (one === undefined) {
        one = { key: k, versions: [], hasData: gameDataExists(isolatedGameDataDir(k)) };
        byKey.set(k, one);
        out.push(one);
      }
      one.versions.push(v);
    }
    return out;
  }

  /** [B] 分类的显示名：键 ＋ 落进它的版本。 */
  private copyTargetTitle(c: CopyTarget): string {
    const names: string[] = [];
    for (const v of c.versions) {
      names.push(v.label);
    }
    return names.join('  ·  ') + '   →   ' + c.key;
  }

  /** [B] 分类的副标题：它现在有没有数据。⭐ 这一句是「勾了会发生什么」的答案。 */
  private copyTargetSub(c: CopyTarget): string {
    if (c.hasData) {
      return '已经有数据 —— 勾了也不会覆盖它';
    }
    return '还没有数据 —— 会复制一份当前数据进来';
  }

  /** [B] 勾/取消勾一个分类。⚠️ 必须**赋新数组**，理由见 toggleTransferPick。 */
  private toggleCopyPick(key: string): void {
    const i: number = this.copyPicked.indexOf(key);
    if (i >= 0) {
      const out: string[] = this.copyPicked.slice();
      out.splice(i, 1);
      this.copyPicked = out;
    } else {
      this.copyPicked = this.copyPicked.concat([key]);
    }
  }

  private isCopyPicked(key: string): boolean {
    return this.copyPicked.indexOf(key) >= 0;
  }

  /* ==================================================================
   * 长按多选
   * ================================================================== */

  /** [B] 这一行现在算不算「选中」—— 多选态看 `multiPicked`，平时看 `selectedSave`。
   *  ⭐ 做成一个函数而不是两处各写一遍 if：两张列表必须**长得一样**。 */
  private rowHot(key: string): boolean {
    return this.multiMode ? (this.multiPicked.indexOf(key) >= 0) : (this.selectedSave === key);
  }

  /* [A] ⛔⛔ **长按与点击都要把 `selectedSave` 挪到刚碰的那一行** —— 用户 2026-10-02：
   *    「我先选中了一个，再长按其他的选其他的，**长按选中时页面信息要刷新成我刚刚长按选中的**。
   *      进入多选后再单点选中也是一样。」
   *
   * ⛔ 不改的后果就是他报的那个 bug：右边详情**还停在最开头选的那个**，
   *    于是屏幕上同时有**两个「删除」**（多选那条是一个，详情下面那个单条的又是一个），
   *    而玩家分不出哪个是哪个。
   *
   * ⭐ 两处都改（进入时 + 已经在多选态时）不是重复：它们是**两条入口**，
   *    而「详情显示哪一条」这件事必须与「我刚碰了哪一条」一致 —— 这条不变量
   *    只要有一个入口漏了，症状就是同一个。
   */
  private enterMulti(key: string): void {
    this.selectedSave = key;
    if (!this.multiMode) {
      this.multiMode = true;
      this.multiPicked = [key];
      return;
    }
    this.toggleMultiPick(key);
  }

  /** [B] 勾/取消。⚠️ 必须**赋新数组**（ArkUI 只认赋值），理由同 toggleTransferPick。 */
  private toggleMultiPick(key: string): void {
    /* [B] 先挪详情 —— 取消勾选时**也要**挪：详情答的是「我刚碰的是哪一个」，
     * 而不是「它还选着吗」。⚠️ 否则取消一个之后右边会跳回很久以前选的那条。 */
    this.selectedSave = key;
    const i: number = this.multiPicked.indexOf(key);
    if (i >= 0) {
      const out: string[] = this.multiPicked.slice();
      out.splice(i, 1);
      this.multiPicked = out;
    } else {
      this.multiPicked = this.multiPicked.concat([key]);
    }
    /* [B] 一个都不剩 ⇒ 自动退出多选。⛔ 留着一个「已选 0 项」的条只会让人以为卡住了。 */
    if (this.multiPicked.length === 0) {
      this.exitMulti();
    }
  }

  /* [B] 退出多选。⚠️ 顺带把那两个只属于多选的开关也清掉 ——
   * 不清的话下次进来会**直接弹着上一次的确认框**，而玩家根本没按删除。 */
  private exitMulti(): void {
    this.multiMode = false;
    this.multiPicked = [];
    this.showMultiAsk = false;
    this.multiListOpen = false;
  }

  /** [B] 勾上的那些存档的名字，顿号相连 —— 确认框的标题行与展开窗都用它。 */
  private pickedNamesText(): string {
    const names: string[] = [];
    for (const r of this.pickedRows()) {
      names.push(r.entry.label);
    }
    return names.join('、');
  }

  /** [B] 勾上的那些行（按 `saveGroups` 的顺序）。找不到的键**跳过** ——
   *  它可能已经被别处删掉了，而那不是错误。 */
  private pickedRows(): SaveRow[] {
    const out: SaveRow[] = [];
    for (const g of this.saveGroups) {
      for (const s of g.saves) {
        if (this.multiPicked.indexOf(this.saveKey(g.dir, s.id)) >= 0) {
          out.push({ dir: g.dir, entry: s });
        }
      }
    }
    return out;
  }

  /* [A] 一次删掉所有勾上的。⚠️ 一个个走**同一条**搬进垃圾站的路，不是批量直接删 ——
   *    批量删要额外的回滚逻辑，而这条路已经带回了回滚（见 SaveVault.vaultDelete）。
   * ⚠️ 部分失败要**说出来**：只报成功会让玩家以为全删了。 */
  private deleteMultiToVault(): void {
    const rows: SaveRow[] = this.pickedRows();
    if (rows.length === 0) {
      this.exitMulti();
      return;
    }
    const now: number = Date.now();
    const fails: string[] = [];
    let done: number = 0;
    for (const r of rows) {
      const e: string = vaultDelete(r.entry, r.dir, this.vaultDays, now,
                                    this.ownerOfDir(r.dir), this.keyOfDir(r.dir));
      if (e === '') {
        done += 1;
      } else {
        fails.push(r.entry.label + '：' + e);
      }
    }
    this.savesNote = fails.length === 0
      ? ('把 ' + String(done) + ' 个存档放进了垃圾站，可以在那儿找回。')
      : ('放进了垃圾站 ' + String(done) + ' 个；有 ' + String(fails.length) + ' 个没成功：'
         + NL + fails.join(NL));
    /* [B] 先关窗再退出 —— `exitMulti()` 自己也会清 `showMultiAsk`，
     * 这里显式写一次是为了让「删完窗一定没了」读得出来（顺序不依赖另一个函数）。 */
    this.showMultiAsk = false;
    this.exitMulti();
    this.selectedSave = '';
    this.refresh();
  }

  private askDelete(): void {
    if (this.selectedSave === '') {
      return;
    }
    this.showDeleteAsk = true;
  }

  /* [A]
   * 真删。`archived = true` ⇒ 归档（不自动清理）。
   *
   * ⚠️ 走的是**搬进垃圾站**，不是抹掉 —— 见 SaveVault 开头。
   */
  private doVaultDelete(archived: boolean): void {
    const sv: SaveEntry | undefined = this.selectedSaveEntry();
    this.showDeleteAsk = false;
    if (sv === undefined) {
      return;
    }
    const dir: string = this.selectedSaveDir();
    const now: number = Date.now();
    /* [A] ⭐ 把**来源**一起记下来（用户 2026-10-02：垃圾站里区分不出原来是哪个版本的）。
     * ⚠️ 在这里取值而不是在垃圾站里现算：删除之后那个 jar 可能就没了。 */
    const err: string = vaultDelete(sv, dir, this.vaultDays, now,
                                    this.ownerOfDir(dir), this.keyOfDir(dir));
    if (err !== '') {
      this.vaultNote = err;
      this.refresh();
      return;
    }
    if (archived) {
      /* [B] 刚搬进去的那个 = 最新那一个（`listVault` 新的在前）。
       * ⚠️ 用「最新」而不是自己拼 id：id 的拼法只有 SaveVault 知道，
       *    在这里再拼一遍就是同一件事两份实现。 */
      const fresh: VaultEntry[] = listVault();
      if (fresh.length > 0) {
        const e2: string = vaultSetArchived(fresh[0].id, true, this.vaultDays, now);
        if (e2 !== '') {
          /* ⚠️ 搬成功了、归档没设上 ⇒ 说出来。它现在是**普通垃圾站条目**，
           * 到期会被清掉 —— 而那正是玩家选了归档想避免的事。 */
          this.vaultNote = '已经搬进垃圾站了，但归档没设上（它到期仍会被清理）：' + e2;
        }
      }
    }
    this.selectedSave = '';
    this.refresh();
  }

  /* [A] ⭐ 一个**存档目录**属于哪些版本 —— 直接复用「按存档」那一屏的分组结论。
   *
   * ⭐ 用 `groupTitle` 而不是自己拼：那里已经处理了「内置游戏要带版本号」
   *    （`groupTitle` 那套「版本在前」），而这两个地方必须**说同一件事** ——
   *    垃圾站里写「内置游戏」、存档页写「内置游戏（v8 Build 160.5）」，
   *    玩家会以为是两个东西。 */
  private ownerOfDir(dir: string): string {
    const g: SaveGroup | undefined = this.saveGroups.find((x: SaveGroup) => x.dir === dir);
    return g === undefined || g.versions.length === 0 ? '' : this.groupTitle(g);
  }

  /** [B] 上面那个目录的隔离键；`''` = 未隔离（或推不出来）。 */
  private keyOfDir(dir: string): string {
    const g: SaveGroup | undefined = this.saveGroups.find((x: SaveGroup) => x.dir === dir);
    return g === undefined || g.versions.length === 0 ? '' : g.versions[0].key;
  }

  /* [A] 垃圾站一行里「原来属于谁」。
   * ⚠️ 老条目（或那一刻的 jar 已被删、目录已不在）没有 `owner` ⇒ **现算一次**，
   *    拿 `from` 去当前的分组里找。⛔ 都失败就说实话，别留空 ——
   *    空着会被读成「没有版本」，而那是错的。 */
  /* [A] ⛔ 三级回退，**顺序是用户定的**（2026-10-02）：「优先显示版本 → 文件夹路径
   *    → 不知道是谁的」。
   *
   * ⭐ 每一级都比下一级更接近玩家脑子里的那个东西：
   *    ① 版本（`内置游戏（v8 Build 160.5）`）—— 就是他选的那一项；
   *    ② 目录 —— ⚠️ 老条目、以及「留了很久没人读的孤立档」（`b160.5` 这种）只有这个，
   *       而它恰好**指得准**：那个键就是他当时那一档的名字；
   *    ③ 都没有 ⇒ 实话实说。
   * ⛔ 别把 ③ 写成一句空话（「未知」）—— 要让人看出**我们真的不知道**，
   *    而不是「有值但没显示」。 */
  private vaultOwnerText(e: VaultEntry): string {
    if (e.owner !== '') {
      return e.owner + (e.key === '' ? '' : ('（' + e.key + '）'));
    }
    const now: string = this.ownerOfDir(e.from);
    if (now !== '') {
      return now;
    }
    return e.from === '' ? '不知道原来属于哪个版本' : ('目录 ' + e.from);
  }

  /** [B] 放回。刷新后存档列表当场出现它。 */
  private doVaultRestore(e: VaultEntry): void {
    /* [B] 第二个参数只是**兜底**（原来那个目录没了时用它）—— 用当前版本的目录合适。 */
    this.vaultNote = vaultRestore(e, this.savesDirShown);
    /* ⚠️ 先短后长：垃圾站自己的名单立刻更新，`refresh()` 再去更新存档列表。 */
    this.reloadVault();
    this.refresh();
  }

  /** [B] 彻底删掉（不可撤销）。 */
  private doVaultPurge(e: VaultEntry): void {
    this.vaultNote = vaultPurge(e.id);
    this.reloadVault();
    this.refresh();
  }

  /** [B] 归档 / 取消归档。取消时**重新起算**保留期，见 SaveVault.vaultSetArchived。 */
  private doVaultToggleArchive(e: VaultEntry): void {
    this.vaultNote = vaultSetArchived(e.id, !e.archived, this.vaultDays, Date.now());
    this.reloadVault();
    this.refresh();
  }

  /** [B] 改全局保留期。写盘后刷新，让每一行显示的剩余天数跟着变。 */
  private setVaultDays(d: number): void {
    this.vaultDays = d;
    writeVaultDays(this.filesDir, d);
    this.refresh();
  }

  /** [B] 「保留到 YYYY-MM-DD HH:MM」。⚠️ 现在只在按钮上用到「日期」那一半。 */
  private deleteExpiryText(): string {
    return formatMs(Date.now() + this.vaultDays * 24 * 60 * 60 * 1000);
  }

  /* [B] 只要日期那一段（`YYYY-MM-DD`）。
   * ⚠️ 按钮标签上写时分是噪音 —— 保留期是 3/7/30 天那个尺度，几点几分不影响决定。 */
  private deleteExpiryDate(): string {
    return this.deleteExpiryText().substring(0, 10);
  }

  /** [B] 保留期那一档的按钮文案。 */
  private vaultDaysLabel(d: number): string {
    return d >= 30 ? '1 个月' : (String(d) + ' 天');
  }

  /* ---- 复制 / 移动 ---- */

  private askTransfer(op: string): void {
    if (this.selectedSave === '') {
      return;
    }
    this.transferOp = op;
    this.transferNote = '';
    /* [B] 每次打开都从**空选择**开始 —— 上一次的选择留在那儿会让玩家以为已经选好了。 */
    this.transferPicked = [];
  }

  private closeTransferDialog(): void {
    this.transferOp = '';
    this.transferNote = '';
    this.transferPicked = [];
  }

  /** [B] 这一项选中了吗。 */
  private isTransferPicked(key: string): boolean {
    return this.transferPicked.indexOf(key) >= 0;
  }

  /* [A] 点一项 —— **只改选择，不执行任何动作**（用户要的「先多选再确定」）。
   *
   * ⚠️⚠️ **必须赋一个【新数组】**。`push`/`splice` 改的是同一个对象，
   *    而 ArkUI 观测的是「这个 @State 被重新赋值了吗」——⛔ 原地改内容**不保证**触发重绘，
   *    症状就是「点了没反应」。（与刚刚那个 `ForEach` key 的问题同一族：
   *    变的是内容、而 UI 认的是引用。）
   */
  private toggleTransferPick(key: string): void {
    const i: number = this.transferPicked.indexOf(key);
    if (this.transferOp === 'move') {
      /* [B] 移动**单选**：再点已选的就取消，点别 的就换成它。
       * ⚠️ 理由见 TransferDialog 里那段 —— 搬走之后源就没了，第二个目标无从谈起。 */
      this.transferPicked = (i >= 0) ? [] : [key];
      return;
    }
    if (i >= 0) {
      const out: string[] = this.transferPicked.slice();
      out.splice(i, 1);
      this.transferPicked = out;
    } else {
      this.transferPicked = this.transferPicked.concat([key]);
    }
  }

  /* [A]
   * 能当目标的版本 —— **排除当前版本自己**。
   * ⚠️ 判据是**数据目录**相同，不是 path 不同：隔离关着时所有版本的目录是同一个，
   *    那时「复制到别的版本」等于复制到同一个目录 ⇒ 必须也排除掉，
   *    否则会出现一个看起来能选、点下去报「源和目标在同一个目录」的选项。
   */
  private transferTargets(): VersionEntry[] {
    /* [A] ⭐ 「源」= **选中那一行自己的目录**，不再是当前版本的目录 ——
     * 现在列表里可能有别的版本的存档，从那里也能复制/移动。
     * ⛔ 用 `savesDirShown` 的话，从别的版本选一个存档再复制，
     *    会把**当前版本那一份**当成源（而它可能根本没有这个存档）。 */
    const here: string = this.selectedSaveDir();
    return this.versions.filter((v: VersionEntry) => (v.dataDir + '/saves') !== here);
  }

  /** [B] 目标那一行的后果说明。⭐ 用户要的就是「移动前讲清后果」。 */
  private transferTargetNote(v: VersionEntry): string {
    const n: number = countSavesIn(v.dataDir + '/saves');
    const head: string = n === 0
      ? '它还没有存档'
      : ('它现在有 ' + String(n) + ' 个存档');
    if (this.transferOp === 'move') {
      return head + '；移过去之后，这个存档只在「' + v.label + '」下有。';
    }
    return head + '；复制一份过去，两边都有。';
  }

  /* [A]
   * 按下「确定」——**这才是真正动手的地方**。
   *
   * ⚠️ 多个目标时**逐个执行**，并把失败的那几个**列出来**（不是遇到第一个失败就停）：
   *    停下来的话，玩家会以为后面那些也没做，而其实前面已经成功了 ——
   *    那种「状态不明」比失败本身更难受。
   * ⇒ 所以：成功的照做，失败的汇总成一句话，并且**照旧刷新**（部分成功也要反映出来）。
   */
  private confirmTransfer(): void {
    const sv: SaveEntry | undefined = this.selectedSaveEntry();
    if (sv === undefined || this.transferPicked.length === 0) {
      return;
    }
    const fails: string[] = [];
    let okCount: number = 0;

    if (this.transferOp === 'move') {
      const v: VersionEntry | undefined =
        this.transferTargets().find((x: VersionEntry) => x.path === this.transferPicked[0]);
      if (v === undefined) {
        fails.push('选中的目标已经不在了');
      } else {
        const e: string = moveSaveTo(sv, this.selectedSaveDir(), v.dataDir + '/saves');
        if (e === '') {
          okCount += 1;
        } else {
          fails.push(v.label + '：' + e);
        }
      }
    } else {
      for (const key of this.transferPicked) {
        if (key === DUP_KEY) {
          const e: string = duplicateSave(sv, this.selectedSaveDir());
          if (e === '') {
            okCount += 1;
          } else {
            fails.push('再存一份：' + e);
          }
        } else {
          const v: VersionEntry | undefined =
            this.transferTargets().find((x: VersionEntry) => x.path === key);
          if (v === undefined) {
            fails.push('有个选中的目标已经不在了');
            continue;
          }
          const e: string = copySaveTo(sv, this.selectedSaveDir(), v.dataDir + '/saves');
          if (e === '') {
            okCount += 1;
          } else {
            fails.push(v.label + '：' + e);
          }
        }
      }
    }

    if (fails.length === 0) {
      this.closeTransferDialog();
    } else {
      /* [A] ⭐⭐ 失败提示就两行：**「复制失败：」/「移动失败：」＋具体原因**。
       *
       * 用户 2026-10-02：
       *   「复制失败的提示不太美观。应该这样：复制失败：「具体原因」
       *     别的解释不需要，复制又不是移动。」
       *
       * ⛔ 我原来拼的是「成功了 N 个；没成功：A；B；C」—— 一句话里塞了三件事，
       *    而且用分号连起来，读起来像日志。⇒ 改成**一个标题 + 逐行的原因**。
       *
       * ⚠️ 多目标时**每个目标单独一行**，原因里带目标名（`v.label + '：' + e` 已经在
       *    `fails` 里了）—— 那才是能定位的那部分，⛔ 不是「别的解释」。
       *
       * ⚠️ 部分成功时只留一行「成功了 N 个。」在最前面：那不是解释，是**事实**——
       *    少了它，屏幕上写着「复制失败」而玩家会以为一个都没成（其实成了几个）。
       *    ⛔ 但也仅此一行，不再展开。
       */
      const head: string = this.transferOp === 'move' ? '移动失败' : '复制失败';
      const okLine: string = okCount > 0 ? ('成功了 ' + String(okCount) + ' 个。\n') : '';
      this.transferNote = okLine + head + '：\n' + fails.join('\n');
      /* [B] 清掉选择 —— 成功的那些再点一次会撞同名而报错，失败的那些让玩家重新挑。 */
      this.transferPicked = [];
    }
    this.refresh();
  }

  /* [A] ⭐⭐ 窄屏（手机）的判定，以及「详情子页」是否开着。
   *
   * ⚠️ 阈值 600 vp 与参考项目 AMCL 一致（他们 `viewportWidth >= 600` 才走双栏）。
   *    本项目已有的实测依据也吻合：`CONTENT_MIN_VP` 那条注释记着
   *    「手机上窗口只有 360–420 vp」。
   *
   * ⚠️ `winW <= 0` 时（还没量到）**当作宽屏**：宁可先按宽屏画一帧，
   *    也不要让平板上闪一下子页 —— 平板上量到宽度之前就点进子页的概率极低，
   *    而误判成窄屏会让**平板**上一进页面就少一半界面。
   */
  private isNarrow(): boolean {
    return this.winW > 0 && this.winW < NARROW_VP;
  }

  /** [B] 手机上打开了详情子页。宽屏恒为 false（宽屏没有子页）。 */
  @State panelOpen: boolean = false;

  /** [A]
   * 元数据里**除了头条那三项**之外的行。
   *
   * ⛔ 为什么要有它：右侧面板把「构建号 / 地图 / 保存时间」放在头条（构建号还放大到 22），
   *    而 `metaRowsOf` 的完整列表里也有这三项 ⇒ 不去掉的话**同一个字段在一屏上出现两遍**，
   *    读者会以为是两个不同的东西。
   * ⚠️ 排的是**标签**，而那些标签在 `metaRowsOf` 里定义、只此一处 ⇒ 改名时两边一起改。
   */
  private metaRowsExcept(): MetaRow[] {
    const skip: string[] = ['写入时的构建号', '地图', '保存时间'];
    return this.selMetaRows.filter((r: MetaRow) => skip.indexOf(r.label) < 0);
  }

  /** [A] 玩家点了某个 jar。只是【记下来】，不在这里启动 —— 启动要重建整棵树。 */
  private pick(jarPath: string): void {
    this.selected = jarPath;
    writeSelection(this.filesDir, jarPath);
    this.resolution = resolveGame(this.filesDir, this.bundleCodeDir);
    hilog.info(DOMAIN, TAG, 'launcher: picked %{public}s', jarPath === '' ? '(bundled)' : jarPath);
  }

  /** [A] 退回内置的那一份。写一个【空的】选择，那是明确的「用包里的」，不是清除。 */
  private pickBundled(): void {
    this.selected = '';
    writeSelection(this.filesDir, '');
    this.resolution = resolveGame(this.filesDir, this.bundleCodeDir);
    hilog.info(DOMAIN, TAG, 'launcher: picked (bundled)');
  }

  /** [A]
   * 内容一栏的宽度（vp）。**靠左**摆，见 CONTENT_MIN_VP。
   *
   * ⚠️⚠️ 它返回的是一个**数值 width**，而不是配 `width('100%')` 用的 `constraintSize` ——
   * 这个选择是为动画服务的，别改回去。
   *
   * 用户报「松手后切换的速度太快了」，我第一版用 `animateTo` 包住 `constraintSize` 的变化，
   * 他说「**还是**太快了」—— 那个「还是」说明动画根本没跑。
   *
   * 原因：`animateTo` 动的是**渲染属性**（width / height / opacity / translate / …），
   * 而 `constraintSize` 是**布局约束**。约束变了，布局直接重排，没有中间帧。
   *
   * ⇒ 改成真正的数值 `width`。宽度是渲染属性，`animateTo` 能对它插值。
   *
   * ⚠️ 窗口宽度还没量到时给下限；`winW <= 0` 只出现在第一帧。
   */
  private gamesWidthVp(): number {
    if (this.winW <= 0) {
      return CONTENT_MIN_VP;
    }
    const want: number = this.winW * (GAMES_WIDTH_PCT / 100);
    return want > CONTENT_MIN_VP ? want : CONTENT_MIN_VP;
  }

  /* ⛔ 这里曾有一个 `hasRightGap()`，用于「右侧非界面区」那套底色/分界线。
   * 整套已回退（用户 2026-10-02：「还是去掉吧，背景就黑色就行了」），所以它没有用户了。
   * 理由与两次失败的记录见 build() 里 Navigation 上方的那段注释。 */

  /** [A]
   * 栏左右各留多少。**同一个值给两边 ⇒ 栏必然居中**（见 BAR_MAX_VP 的注释）。
   *
   * 窗口宽度还没量到时返回下限 —— 那时栏会宽一点，下一帧就正了。宁可先宽后正，
   * 也不要先给一个可能算出负数的值。
   */
  private sideMargin(): number {
    if (this.winW <= 0) {
      return BAR_MIN_SIDE_VP;
    }
    const want: number = Math.min(BAR_MAX_VP, this.winW - 2 * BAR_MIN_SIDE_VP);
    const side: number = (this.winW - want) / 2;
    return side > BAR_MIN_SIDE_VP ? side : BAR_MIN_SIDE_VP;
  }

  @Builder
  GamesTab() {
    Column() {
      /* [A]
       * 下拉刷新。用户 2026-10-01 要的：
       *   「重新扫描我们能搞成下拉刷新吗，游戏列表直接下拉刷新不方便多了。
       *     原来的按钮可以留着当备份。」
       *
       * ⇒ 列表上直接下拉就重扫；设置页那个「重新扫描」按钮**保留**当备份
       *   （下拉是一条手势，手势失败时按钮还在 —— 出口多一点比少一点安全）。
       *
       * ⚠️ 刷新的动作就是 `refresh()`，与按钮**完全同一个函数**。不要在两边各写一份
       *    读盘逻辑：那是「同一件事存在两处、其中一处先跑偏」的经典形态，本项目为此
       *    付过好几次代价。
       *
       * ⚠️ `refresh()` 是**同步**的（只是列目录 + 读两个小文件），所以这里可以立刻
       *    把 isRefreshing 放回 false。转圈会一闪而过 —— 那是诚实的：它确实就那么快。
       *    刻意**不**加延时去「让动画好看一点」，那等于让界面撒谎说它等了很久。
       */
      Refresh({ refreshing: $$this.isRefreshing }) {
        /* [A]
         * ⚠️ 必须有一个**可滚动**的子节点，否则下拉手势不一定触发 —— Refresh 是靠
         *   内容能滚动来判断「用户拉的是列表」的。原来那层直接是 Column（不可滚），
         *   所以这里包一层 Scroll。
         *
         * ⚠️ 再加一层 Row 是为了**恢复左对齐**。装上下拉刷新时我漏了这件事：Refresh 的
         *   内容区默认居中，于是卡片从屏幕左边跑到了中间，而用户给的规格是
         *   「内容本身占 30%，在**最左边**，像 AMCL 那样」。Row + justifyStart 把这条
         *   规格恢复回来，而且靠的是结构而不是调数值。
         */
        Scroll() {
          Row() {
            Column() {
              if (this.games.length === 0) {
          /* [A]
           * 空状态，而它同时是【逃生门】。
           *
           * 「判定没有游戏」有三个完全不同的来源：真的没有、内置那份的路径我算错了、
           * 以及那个 Downloads 文件夹在这台设备上还没被创建出来。三者在界面上长得
           * 一模一样，而其中两个是【我的】问题。
           *
           * ⇒ 所以这里必须能出去：一个「仍然尝试启动」的入口。没有它，一次路径判断
           *   失误就把应用变成永远打不开游戏的启动器，而玩家没有任何办法绕过去。
           *   本项目为「门关上了却没有开的路径」付过代价（jvm_incomplete），不再犯。
           */
          Column() {
            /* [A]
             * ⚠️ 标题**据实**说，别一律说「没有找到游戏」。
             *
             * 这段的进入条件是 `games.length === 0`，而 `games` 是
             * **`listGameJars()` 列出来的东西 —— 也就是【Download 文件夹里玩家自己放的 jar】**，
             * 内置那份不在里面。
             * ⇒ 内置在的时候，这一屏原来会写成「没有找到游戏」而下面又写「内置游戏：有」，
             *    **自相矛盾**；更糟的是底下那个「启动游戏」按钮是**可用**的（它会去加载内置那份）。
             * ⭐ 「没有找到游戏」只有在**内置也不在**时才是真的。
             *
             * ⚠️ 判据用 `hasBundled`（直接问文件在不在），不是 `resolution.source` ——
             *    后者回答的是「这次加载谁」，玩家一选自己的 jar 它就变成 'user'，
             *    与「内置在不在」无关。见 GameLibrary.hasBundledGame 上的说明。
             */
            Text(this.hasBundled ? '还没有导入其他游戏版本' : '没有找到游戏')
              .fontSize(18).fontColor($r('sys.color.font_primary'))
            /* [B] 内置在的时候补一句「其实可以直接玩」，因为标题已经不再说「找不到」了，
             * 得让玩家知道这一屏不是死路。 */
            if (this.hasBundled) {
              Text('内置的那一份可以直接玩，点下面的「启动游戏」就行')
                .fontSize(13).fontColor($r('sys.color.font_secondary'))
                .margin({ top: 8 })
                .textAlign(TextAlign.Center)
            }
            /* [B] 提示里给**两条**路。下拉是本页就能做的，而设置页那个按钮是备用的 ——
             * 两者都写，免得玩家以为只有一个办法。 */
            Text('把 Mindustry 的 .jar 放进下面这个文件夹，然后下拉刷新（或到「设置」里点「重新扫描」）：')
              .fontSize(13).fontColor($r('sys.color.font_secondary'))
              .margin({ top: 12 })
              .textAlign(TextAlign.Center)
            /* [A]
             * ⚠️ 两行，缺一不可（用户 2026-10-02 定的）：
             *   第一行给人【找】—— 文件夹在磁盘上叫包名，而文件管理器显示的是应用名，
             *            ⇒ 照着真实路径去文件管理器找是找不到的
             *   第二行给人【复制】—— 真实路径可以直接粘进文件管理器的地址栏
             */
            Text(this.jarDirHuman === '' ? '　' : this.jarDirHuman)
              .fontSize(13).fontColor($r('sys.color.font_secondary'))
              .margin({ top: 8 })
              .textAlign(TextAlign.Center)
            Text(this.jarDirHint === '' ? '（这个设备上还拿不到 Download 文件夹）' : this.jarDirHint)
              .fontSize(12).fontColor($r('sys.color.font_tertiary'))
              .margin({ top: 2 })
              .textAlign(TextAlign.Center)
              .copyOption(CopyOptions.LocalDevice)
            Text('内置游戏：' + (this.hasBundled ? '有' : '无'))
              .fontSize(12).fontColor($r('sys.color.font_secondary'))
              .margin({ top: 12 })
          }
          .width('100%')
          .padding({ left: 24, right: 24, top: 40, bottom: 24 })
          .alignItems(HorizontalAlign.Center)
        } else {
          /* [A]
           * ⚠️ 列表项是【内联】写的，不是 @Builder。这里踩过一次，见文件头第 2 条：
           *    @Builder 的参数按值传递 ⇒ `this.selected` 变化不会让它重新执行
           *    ⇒ 点击其实成功了（日志里 source=user 是对的），但 ✓ 不动，
           *      看起来就是「点了没反应」。
           */
          List({ space: 8 }) {
            ListItem() {
              Row() {
                Column() {
                  Text('内置游戏')
                    .fontSize(16).fontColor($r('sys.color.font_primary'))
                  /* [A]
                   * 第二行 = **版本号**，用户 2026-10-01 要的。
                   *
                   * ⚠️ 它【曾经】在这里随选中状态切换（「正在使用」/「包里的那一份」）。
                   *   用户判定那个切换没必要 —— 而它是多余的：选没选中已经由右边的 ✓
                   *   表达了，再写一遍只是把**唯一能放版本号的位置**占掉了。
                   */
                  Text(this.bundledVer === '' ? '未知版本' : this.bundledVer)
                    .fontSize(12).fontColor($r('sys.color.font_secondary')).margin({ top: 2 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                if (this.selected === '') {
                  Text('✓').fontSize(18).fontColor($r('sys.color.brand'))
                }
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 14, bottom: 14 })
            }
            .backgroundColor($r('app.color.launcher_card'))
            .borderRadius(CARD_RADIUS_VP)
            .onClick(() => { this.pickBundled(); })

            ForEach(this.games, (g: GameJar) => {
              ListItem() {
                Row() {
                  Column() {
                    /* [A]
                     * 第一行 = **版本号**，第二行 = 文件名 · 大小 · 日期（用户 2026-10-01 要的）。
                     *
                     * ⚠️ 与内置那一行的次序相反，这是刻意的：内置那份没有文件名可看，
                     *   所以「内置游戏」本身就是它的标题；玩家导入的这些文件名五花八门
                     *   （Mindustry160.5.jar / mindustry.jar / 随便什么），
                     *   而**版本号才是选的时候真正要比的东西**。
                     *
                     * ⚠️ 读不出就写「未知版本」，**不是**把这一行留空或让条目消失 ——
                     *   一个不是游戏的 jar（例如模组）本来就会走到这里，而它照样要能被选中。
                     */
                    Text(g.version === '' ? '未知版本' : g.version)
                      .fontSize(16).fontColor($r('sys.color.font_primary'))
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(g.name + '  ·  ' + formatSize(g.size) + '  ·  ' + formatDate(g.mtime))
                      .fontSize(12).fontColor($r('sys.color.font_secondary')).margin({ top: 2 })
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                  if (this.selected === g.path) {
                    Text('✓').fontSize(18).fontColor($r('sys.color.brand'))
                  }
                }
                .width('100%')
                .padding({ left: 16, right: 16, top: 14, bottom: 14 })
              }
              .backgroundColor($r('app.color.launcher_card'))
              .borderRadius(CARD_RADIUS_VP)
              .onClick(() => { this.pick(g.path); })
            }, (g: GameJar): string => g.path)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 16 })
            }
            }
            .width(this.gamesWidthVp())
            .animation({ duration: 300, curve: Curve.FastOutSlowIn })
          }
          /* [B] 靠左**且**靠上 —— 见上面那层 Row 的说明。
           *
           * ⚠️ `height('100%')` 不是多余的：Row 自适应高度时，Scroll 会把它**垂直居中**，
           * 于是列表上下各空出一大块（实测截图里第一张卡片落在屏幕 33% 处）。
           * 撑满之后 `VerticalAlign.Top` 才真正把它钉在顶部。 */
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Start)
          .alignItems(VerticalAlign.Top)
        }
        .width('100%')
        .height('100%')
        /* [B] 关掉滚动条：内容通常只有几行，一条忽隐忽现的滚动条只是噪音。 */
        .scrollBar(BarState.Off)
      }
      /* [A] Refresh 自己拿 layoutWeight(1)，让「列表 + 空状态」这块占满按钮以上的空间。
       *
       * ⚠️ 里面那几层**不**要再要 layoutWeight：高度由 Refresh 决定，两处都要会让高度
       * 被算两次，症状是列表比可用空间矮一截。
       */
      .layoutWeight(1)
      .width('100%')
      .onRefreshing(() => {
        this.refresh();
        this.isRefreshing = false;
      })

      /* [A]
       * 主按钮。它被禁用的唯一理由是「确实没有任何可加载的东西」——
       * 由 resolveGame 判定，而它已经确认过文件真的能打开。
       */
      Column() {
        Button('启动游戏')
          .width('100%')
          .height(44)
          .fontSize(BUTTON_FONT_VP)
          .enabled(this.resolution.path !== '')
          .onClick(() => { this.onLaunch(this.resolution.path); })

        /* ⛔ 这里【曾经】有一行「仍然尝试启动」，只在没有选中 jar 时出现，就贴在
         * 「启动游戏」正下方。
         *
         * 用户 2026-10-01 去掉它，理由是它**常驻**：
         *   「这个仍然尝试启动不要放在启动的下面吧，应该是启动失败了才有的东西
         *     （弹窗告知的）」
         *
         * ⇒ 它现在只在**上一次启动失败**时出现，而且是弹窗，见 build() 末尾那个浮层。
         *   设置页里那个同名的按钮也一并撤了 —— 同一个东西不该有两处常驻入口。 */
      }
      .width(this.gamesWidthVp())
      .animation({ duration: 300, curve: Curve.FastOutSlowIn })
      .padding({ left: 16, right: 16, top: 12 })
    }
    .width('100%')
    .height('100%')
    /* [A] ⭐ **Start，不是 Center** —— 内容靠左，这是用户给的规格：
     * 「内容本身占 30%，在最左边，像 AMCL 那样。」见 CONTENT_FRACTION。 */
    .alignItems(HorizontalAlign.Start)
    /* [A] 给悬浮栏让位，见 BAR_CLEARANCE_VP。 */
    .padding({ bottom: BAR_CLEARANCE_VP })
  }
  /* ==================================================================
   * 存档页的两个详情面板
   *
   * ⭐⭐ 抽成**零参** `@Builder` 是为了让**宽屏内嵌**与**窄屏子页**共用同一份。
   *    ⛔ 注意是零参：本文件开头记着「@Builder 的参数按值传递，`selected` 变了不会重跑」
   *    —— 那条**只针对带参数的 @Builder**。零参的那种只读 `this`，`this` 上任何 @State
   *    变化都会让它重新执行，所以这里安全。
   *    ⇒ 若哪天要给它们加参数，先回去读文件头第 2 条。
   * ================================================================== */

  @Builder
  SaveDataPanel() {
    Column() {
      if (this.selectedSave === '') {
        Text(this.saves.length === 0 ? '还没有存档' : '从左边选一个存档')
          .fontSize(13).fontColor($r('sys.color.font_tertiary'))
      } else {
        /* [A]
         * 「这个存档对哪些版本可见」与**标题同一行、靠最右**。
         *
         * 用户 2026-10-02：「存档那里，'按存档'分类时，下面的'这个存档对哪些版本可见'
         *   在最下面，我觉得这个和存档标题放在同一行的最右边比较合适。」
         *
         * ⭐ 那个判断是对的，而且不只是「好看」：它是这个存档的**属性**，
         *    和标题、摘要、更新时间一样属于「这是什么」那一组；摆在整张元数据表**下面**
         *    会让人以为它是表格的最后一行。
         *
         * ⚠️ 这一行内部按 **2 : 1** 分（左标题 2、右可见性 1），⛔ 不是按内容自适应：
         *    自适应的话，存档名一长就会把右边挤掉或挤到换行，而那是**随名字浮动**的 ——
         *    同一屏上换个存档，那行字就跳一次位。给比例 ⇒ 位置**由结构保证**。
         *    ⚠️ 别把它与外层那两栏的 3 : 7 搞混：那是「列表 : 详情」，这是标题行内部。
         *
         * ⚠️ 顶部对齐：左边三行、右边两行，居中会让右边浮在中间。
         * ⚠️ 右边整块 `alignItems(HorizontalAlign.End)` ⇒ 文字贴右边缘。
         */
        Row() {
          Column() {
            Text(this.selectedSaveLabel())
              .fontSize(16).fontColor($r('sys.color.font_primary'))
              .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.selectedSaveSummary())
              .fontSize(12).fontColor($r('sys.color.font_tertiary'))
              .margin({ top: 6 })
            Text(this.selectedSaveUpdated())
              .fontSize(12).fontColor($r('sys.color.font_tertiary'))
              .margin({ top: 4 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(2)

          /* [A] ⭐ 这一句是用户 2026-10-02 要的信息：「右侧可以看到存档生效于哪个版本
           * （哪个版本可以用这个存档）」。
           *
           * ⭐ 答的是**目录**层面的问题（谁的 user.home 指向这里），那是能确切回答的那个；
           * ⛔ 不是「这个存档能被哪些版本读」—— 那个还要看模组与版本迁移规则，
           * 我们答不了，所以不在这儿答。存档自己的 `build` 就在下面，两件事分开摆着。 */
          if (this.savesSeenByText() !== '') {
            Column() {
              Text('这个存档对哪些版本可见')
                .fontSize(12).fontColor($r('sys.color.font_tertiary'))
                .textAlign(TextAlign.End)
              Text(this.savesSeenByText())
                .fontSize(12).fontColor($r('sys.color.font_secondary'))
                .margin({ top: 2 })
                .textAlign(TextAlign.End)
            }
            .alignItems(HorizontalAlign.End)
            .layoutWeight(1)
            .margin({ left: 12 })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)

        Divider()
          .strokeWidth(1).color($r('app.color.launcher_border'))
          .margin({ top: 14, bottom: 14 })

        /* [A] ⚠️ 读失败时（`selMetaNote` 非空）**只显示那句话**，不显示半截数据 ——
         * ⛔ 一个「读不出来」的存档如果看起来和正常存档一样（只是字段空着），
         * 玩家会以为存档本身是空的。 */
        if (this.selMetaNote !== '') {
          Text(this.selMetaNote)
            .fontSize(12).fontColor($r('sys.color.font_secondary'))
        } else {
          /* [A] ⭐ 头条三行：构建号放大，地图与保存时间跟在下面。
           * ⛔ 这三项**不再出现在下面的完整列表里**（用 `metaRowsExcept` 排掉）——
           * 同一个字段在一屏上出现两遍，读者会以为是两个不同的东西。 */
          Text('写入时的游戏构建号')
            .fontSize(12).fontColor($r('sys.color.font_tertiary'))
          Text(rowValue(this.selMetaRows, '写入时的构建号') === ''
               ? '—' : rowValue(this.selMetaRows, '写入时的构建号'))
            .fontSize(22).fontColor($r('sys.color.font_primary'))
            .margin({ top: 2 })

          if (rowValue(this.selMetaRows, '地图') !== '') {
            Text('地图  ' + rowValue(this.selMetaRows, '地图'))
              .fontSize(12).fontColor($r('sys.color.font_secondary'))
              .margin({ top: 10 })
          }
          if (rowValue(this.selMetaRows, '保存时间') !== '') {
            Text('保存于  ' + rowValue(this.selMetaRows, '保存时间'))
              .fontSize(12).fontColor($r('sys.color.font_secondary'))
              .margin({ top: 4 })
          }

          /* [A] ⭐⭐ **这里是「查看存档数据」原来那个弹窗的内容**，现在直接铺在右侧。
           * 用户 2026-10-02：「我想把'查看存档数据'改成不弹窗，直接显示在右侧空白区域」。
           * ⇒ 那个按钮与那个弹窗**都已删除**，不是藏起来了。
           * ⚠️ 行内容在可滚动的一块里：`模组` 那条会长成 `[a, b, c]`，行数也跟着变。 */
          Divider()
            .strokeWidth(1).color($r('app.color.launcher_border'))
            .margin({ top: 14, bottom: 14 })

          Scroll() {
            Column() {
              ForEach(this.metaRowsExcept(), (r: MetaRow) => {
                Row() {
                  Text(r.label)
                    .fontSize(12).fontColor($r('sys.color.font_tertiary'))
                    .width(88)
                  Text(r.value)
                    .fontSize(12).fontColor($r('sys.color.font_primary'))
                    .layoutWeight(1)
                    .copyOption(CopyOptions.LocalDevice)
                }
                .width('100%')
                .margin({ bottom: 8 })
                .alignItems(VerticalAlign.Top)
              }, (r: MetaRow) => r.label)
            }
            .width('100%')
          }
          .width('100%')
          .layoutWeight(1)
          .align(Alignment.TopStart)
          .scrollBar(BarState.Off)
        }

        /* ⛔ 「这个存档对哪些版本可见」原先在这里（元数据表**下面**）。
         * 用户 2026-10-02 指出它该和标题同一行：摆在表格下面会让人以为它是表格的最后一行，
         * 而它其实是这个存档的**属性**。已移到上面那行。 */

        /* [A]
         * 对这个存档可做的事。
         *
         * ⭐ 用户 2026-10-02 点的四个动作是「删除，复制，移动，查看存档数据」：
         *    · **查看存档数据**已经不需要在这里了 —— 它的内容就铺在上面（不再弹窗）
         *    · **删除**在这里，⛔ 但它不真删，而是搬进垃圾站（见 SaveVault 开头）
         *    · **复制 / 移动**是 ③f，还没做，所以这里**没有它们** ——
         *      ⛔ 不放一个点了没用的按钮：那比没有更糟。
         *
         * ⚠️ 只有**当前版本**的存档能操作（上面的 `saves` 列表本来就只列当前版本的）。
         *    别的版本的存档要动，得先在「首页」把版本切过去 —— 那条提示在「按版本」那边。
         */
        /* [A] ⭐⭐ **多选态下把这一条整根藏掉**（用户 2026-10-02 同意）。
         *
         * ⛔ 不藏的话屏幕上会同时出现**两个「删除」**：多选那条是「删勾上的这一批」，
         *    这条是「删详情里那一个」。而它们长得一样、位置又近 ⇒
         *    玩家按下哪一个都是赌。⭐ 两个意思不同的同名按钮并存，比少一个按钮糟得多。
         *
         * ⚠️ 复制/移动也一起藏 —— 它们**只作用于一个存档**，而多选态里
         *    「一个」这个概念本身已经不确定了（详情跟着手走，一直在变）。 */
        if (!this.multiMode) {
          Divider()
            .strokeWidth(1).color($r('app.color.launcher_border'))
            .margin({ top: 14, bottom: 12 })

          this.SaveActionRow()
        }
      }
    }
    .width('100%').height('100%')
    .padding({ left: 8, right: 16, top: 12 })
    .alignItems(HorizontalAlign.Start)
  }

  /* [A]
   * 对一个存档可做的事。⭐ 抽成零参 `@Builder`，因为**两个面板都要用**：
   * 「按存档」那边（选中任意版本的一行）与「按版本」那边（选中该版本里的一行）。
   *
   * ⚠️ 两份动作是安全的**现在**才成立：选中项自带目录（见 `selectedSave`），
   *    所以「操作的是哪一份数据」有唯一答案。⛔ 在它只存 `id` 的那些日子里，
   *    两边各放一份动作会让它们对「操作谁」的理解分叉。
   */
  /* [A] 多选态的那一条。⭐ 抽成**零参** `@Builder`：两张列表共用同一份
   * （带参数的 @Builder 不会因状态变化重跑，见文件开头那条）。
   * ⚠️ 两句话必须都在：「已选几项」是状态，「删除 = 放进垃圾站」是**后果** ——
   *    少了后者，玩家会以为「删除」是抹掉，于是不敢按。 */
  @Builder
  MultiBar() {
    Row() {
      Text('已选 ' + String(this.multiPicked.length) + ' 项 · 删除只是放进垃圾站，可以找回')
        .fontSize(12).fontColor($r('sys.color.font_secondary'))
        .layoutWeight(1)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      Button('删除')
        .fontSize(BUTTON_FONT_VP)
        .fontColor($r('sys.color.warning'))
        .backgroundColor($r('app.color.launcher_bg'))
        .enabled(this.multiPicked.length > 0)
        /* [B] ⭐ 只**开窗**，不直接删 —— 见 `showMultiAsk` 的说明。
         * ⚠️ 名单每次重新**收起**：上一次展开过的话，这一次一进来就是展开的，
         * 而那是上一个批次的状态。 */
        .onClick(() => { this.showMultiAsk = true; this.multiListOpen = false; })
      Button('取消')
        .fontSize(BUTTON_FONT_VP)
        .backgroundColor($r('app.color.launcher_bg'))
        .margin({ left: 8 })
        .onClick(() => { this.exitMulti(); })
    }
    .width('100%')
    .margin({ top: 10 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  SaveActionRow() {
    Row() {
      Button('复制')
        .fontSize(BUTTON_FONT_VP)
        .onClick(() => { this.askTransfer('copy'); })
      Button('移动')
        .fontSize(BUTTON_FONT_VP)
        .margin({ left: 8 })
        .onClick(() => { this.askTransfer('move'); })
      Button('删除')
        .fontSize(BUTTON_FONT_VP)
        .fontColor($r('sys.color.warning'))
        .backgroundColor($r('app.color.launcher_bg'))
        .margin({ left: 8 })
        .onClick(() => { this.askDelete(); })
    }
    /* [A] ⭐ **靠右**（用户 2026-10-02：「复制、移动、删除按钮应该在界面最右边，
     * 这样更符合人点击习惯」）。
     * ⚠️ 用 `justifyContent(FlexAlign.End)` 而不是塞一个 `Blank()` 占位 ——
     *    靠右由**布局**保证，不需要多一个节点。
     * ⚠️ 拇指在右侧：动作放右、内容放左，是平板/手机上的通行摆法。 */
    .width('100%')
    .justifyContent(FlexAlign.End)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  VersionDataPanel() {
    Column() {
      if (this.selectedVersionEntry() === undefined) {
        Text('从左边选一个版本')
          .fontSize(13).fontColor($r('sys.color.font_tertiary'))
      } else {
        Text(this.selectedVersionLabel())
          .fontSize(16).fontColor($r('sys.color.font_primary'))
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.selectedVersionLine())
          .fontSize(12).fontColor($r('sys.color.font_tertiary'))
          .margin({ top: 6 })

        Divider()
          .strokeWidth(1).color($r('app.color.launcher_border'))
          .margin({ top: 14, bottom: 14 })

        Text(this.selectedVersionDataLine())
          .fontSize(12).fontColor($r('sys.color.font_secondary'))
        /* [B] 数据目录写出来 —— 这一屏的意义就是让「谁读哪一份数据」变得看得见。 */
        Text(this.selectedVersionDir())
          .fontSize(11).fontColor($r('sys.color.font_tertiary'))
          .margin({ top: 4 })
          .copyOption(CopyOptions.LocalDevice)

        /* [A] ⭐⭐ **这一句是「按版本」这一屏真正的价值。**
         * 用户 2026-10-02 问的「哪个版本可以用这个存档」，在机制上的真答案是
         * 「谁的 `user.home` 指向同一个目录，谁就看得见」。
         * ⚠️ 隔离**关着**时全部版本指向同一份 ⇒ 这句话会写成「全部 N 个版本」，
         * 而那不是 bug，那正是「不隔离」的含义。 */
        if (this.selectedVersionSharedText() !== '') {
          Text(this.selectedVersionSharedText())
            .fontSize(11).fontColor($r('sys.color.font_tertiary'))
            .margin({ top: 10 })
        }

        if (!this.selectedVersionIsCurrent()) {
          /* [B] 说的是**怎么去操作**，不是「不行」—— 门要能开。
           * 存档页的四个动作只作用于**当前版本**的数据（那是游戏实际会读的那份）。 */
          Text('这还不是当前版本。要操作这份数据，先在「首页」把它切过去。')
            .fontSize(11).fontColor($r('sys.color.font_tertiary'))
            .margin({ top: 10 })
        }

        Divider()
          .strokeWidth(1).color($r('app.color.launcher_border'))
          .margin({ top: 14, bottom: 14 })

        Text('这个目录里的存档')
          .fontSize(12).fontColor($r('sys.color.font_tertiary'))

        /* [B] 用户 2026-10-02：「右边的选择存档删除页应该能长按多选」。
         * ⚠️ 与「按存档」那边是**同一个** `MultiBar` 与同一份选中集 —— 两处是同一件事。 */
        if (this.multiMode) {
          this.MultiBar()
        }

        /* [A] ⭐⭐ 用户 2026-10-02：「**按版本那里也要能管理存档**」。
         * ⛔ 原来这里只是一串只读文字 —— 看得到、动不了。
         * ⇒ 现在每一行**可以点**（选中它，与「按存档」那边用同一个选中状态），
         *    选中之后底下就是那三个动作。
         *
         * ⚠️ 两处共用同一个 `selectedSave` ⇒ 在一边选了、切到另一边，选中的还是同一份。
         *    这是对的：它在两个视图里都是**同一个存档**。
         */
        Scroll() {
          Column() {
            if (this.versionSaves.length === 0) {
              Text(this.selectedVersionHasDataText())
                .fontSize(12).fontColor($r('sys.color.font_secondary'))
                .margin({ top: 8 })
            }
            /* [A] ⭐⭐ 用户 2026-10-02 对这一段提了三件事，一起改掉：
             *    ① 「字体过小了」—— 原来整行统一 12fp，名字和元数据**一样大**，
             *       于是没有主次、也看不清。⇒ 名字 14、元数据 12。
             *    ② 「文字没有做对齐（文件名对齐，大小和时间单独再对齐）」
             *       —— 原来是一整句 `名字 · 大小 · 日期` 拼出来的，每行宽度随手，
             *       三列全歪。⇒ 改成**三列**：名字吃剩余宽度，大小与时间各占定宽右对齐。
             *    ③ 「选择版本存档很不方便」—— 原来一行只有 `margin(top:8)`，
             *       热区**只有文字那么高**，在平板上很难点中。
             *       ⇒ 补上内边距、圆角与底色，热区变成一整块（与左边版本列表同一形状）。
             *
             * ⚠️ ✓ 用 `visibility` 而不是 `if` 来显示/隐藏：`if` 会让未选中的行**少一个节点**
             *    ⇒ 选中与未选中两种行的列宽不一样 ⇒ 点一下整列就跳。
             *    `Visibility.Hidden` 照样占位，列不会动。 */
            ForEach(this.versionSaves, (sv: SaveEntry) => {
              Row() {
                Text(sv.label)
                  .fontSize(14)
                  .fontColor(this.rowHot(this.saveKey(this.versionSavesDir(), sv.id))
                             ? $r('sys.color.brand') : $r('sys.color.font_primary'))
                  .layoutWeight(1)
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })

                Text(formatSaveSize(sv.bytes))
                  .fontSize(12).fontColor($r('sys.color.font_tertiary'))
                  .width(SAVE_SIZE_COL_VP).textAlign(TextAlign.End)

                Text(formatSaveDate(sv.mtime))
                  .fontSize(12).fontColor($r('sys.color.font_tertiary'))
                  .width(SAVE_DATE_COL_VP).textAlign(TextAlign.End)
                  .margin({ left: 10 })

                Text('✓')
                  .fontSize(14).fontColor($r('sys.color.brand'))
                  .width(SAVE_TICK_COL_VP).textAlign(TextAlign.End)
                  .margin({ left: 6 })
                  .visibility(this.rowHot(this.saveKey(this.versionSavesDir(), sv.id))
                              ? Visibility.Visible : Visibility.Hidden)
              }
              .width('100%')
              .padding({ left: 12, right: 12, top: 11, bottom: 11 })
              .borderRadius(CARD_RADIUS_VP)
              .backgroundColor($r('app.color.launcher_card'))
              .margin({ top: 6 })
              .gesture(LongPressGesture({ repeat: false, duration: 400 })
                .onAction(() => { this.enterMulti(this.saveKey(this.versionSavesDir(), sv.id)); }))
              .onClick(() => {
                if (this.multiMode) {
                  this.toggleMultiPick(this.saveKey(this.versionSavesDir(), sv.id));
                  return;
                }
                /* [B] 与「按存档」那边同一套：点已选中的那一条 = 取消选中。
                 * ⚠️ 别在这里直接赋值 —— 两处行为不一致时，同一个动作在不同视图下
                 * 结果不同，而那不是“两个视图”，是“两个东西”。 */
                this.openSaveRow(this.versionSavesDir(), sv.id);
              })
            }, (sv: SaveEntry) => sv.id)
          }
          .width('100%')
        }
        .width('100%')
        .layoutWeight(1)
        .align(Alignment.TopStart)
        .scrollBar(BarState.Off)

        /* [B] 选中了某一项才给动作 —— 没选时按下去无事可做，给出来只会让人点空。
         * ⛔ 多选态下一律不给：那会与上面那条多选条上的「删除」撞成一模一样的两个按钮
         *    （理由详见 SaveDataPanel 里那一段）。 */
        if (!this.multiMode && this.selectedSave !== ''
            && this.selectedSaveDir() === this.versionSavesDir()) {
          Divider()
            .strokeWidth(1).color($r('app.color.launcher_border'))
            .margin({ top: 14, bottom: 12 })
          this.SaveActionRow()
        }
      }
    }
    .width('100%').height('100%')
    .padding({ left: 8, right: 16, top: 12 })
    .alignItems(HorizontalAlign.Start)
  }

  /* [A]
   * 存档页。用户 2026-10-02 的布局：「左侧列表选择存档/版本」＋ 右侧详情，
   * 并要求左右**对称** —— 不管左边选的是什么，右边永远是同一套「详情 + 对它可做的事」。
   *
   * ⭐⭐ 这一版的三处变化（同一条消息里要的）：
   *
   *   1. **宽度 100%**（原来 30–60% 可调）——
   *      用户：「存档固定在 100%」。⭐ 理由是他自己给的：
   *      「我说搞到 100%，是因为我想把'查看存档数据'改成不弹窗，直接显示在右侧空白区域」。
   *   2. **「查看存档数据」不再弹窗**，内容直接铺在右侧（见 `SaveDataPanel`）。
   *      那个按钮与 `metaShown` 弹窗**都已删除**。
   *   3. **窄屏（手机）走子页**：「如果手机上点，就是进去那个子页面，可以返回退出」。
   *      ⛔ 没有用 `Navigation` / `NavDestination` —— 那是另一套机制，而这一页的
   *      `Navigation` 现在是 `NavigationMode.Stack` 且**一个 NavDestination 都没有**，
   *      附近还栽过两次。这里用一个 `panelOpen` 开关在**同一个页签内**换内容，
   *      出口是屏幕左上角那个返回箭头（就是用户说的「可以返回退出」）。
   *
   * ⚠️ 两栏按 **3 : 7** 分（`layoutWeight`），不是各一半：左边只是存档名与一行摘要（很短），
   *    右边要放下整张元数据表。⭐ 用 `layoutWeight` 而不是写死 vp，是为了让它在
   *    任何窗口宽度下都自成比例（手机走子页，这条根本不参与）。
   */
  /* [A]
   * 垃圾站。
   *
   * ⭐ 它**不是第三种「视图」**（那种要挤进「按存档 / 按版本」那一排），
   *    而是**另一个地方** —— 进出靠一个返回，与手机的详情子页同一套做法。
   *    理由：分段控件那两档回答的是「我怎么看这批存档」，而垃圾站回答的是
   *    「我删掉的东西去哪了」，不是同一个问题。
   *
   * ⚠️ 每一行自带三个动作（放回 / 归档 / 彻底删），**没有右侧详情栏**：
   *    一个条目的字段就那么几个，再切一栏只会让「点哪一行」多一层含义。
   */
  /* [A]
   * 复制 / 移动的目标选择。
   *
   * ⭐ 用户 2026-10-02 的硬要求：「如果要提供移动的选项，**需要在移动前告诉用户
   *    移动后的效果是什么**」。⇒ 所以这里每一行都是**「动作 + 后果」**的形状，
   *    而不是一排光秃秃的版本名。
   *
   * ⚠️ 目标列表**只列别的版本**（当前版本不在里面）：
   *    · 「移动到当前版本」什么都不会发生 —— 放一行没意义的选项比不放更糟
   *    · 「复制到当前版本」= 同版本再存一份，那是**另一个动作**（改名复制），
   *      它有自己的一行，而且只对**手动存档**开放（理由见 SaveTransfer 开头）。
   */
  @Builder
  TransferDialog() {
    Column() {
      Column() {
        Text((this.transferOp === 'move' ? '移动「' : '复制「') + this.selectedSaveLabel() + '」')
          .fontSize(17).fontColor($r('sys.color.font_primary'))
          .width('100%').textAlign(TextAlign.Center)

        Text(this.transferOp === 'move'
             ? '原版本会看不到它。选一个目标。'
             : '原来那一份不动。可以选多个目标。')
          .fontSize(13).fontColor($r('sys.color.font_secondary'))
          .width('100%').textAlign(TextAlign.Center)
          .margin({ top: 10 })

        Divider().strokeWidth(1).color($r('app.color.launcher_border')).margin({ top: 14 })

        /* [A]
         * ⭐⭐ **先多选、再确定**（用户 2026-10-02）：
         *   「复制那里，我认为是先多选再确定，而不是现在点了就尝试复制。」
         *
         * ⛔ 原来的写法是「点一行 = 立刻复制」，于是复制到三个版本要来回三趟，
         *    而且**没有后悔的机会** —— 点下去就已经发生了。
         * ⭐ 现在点只是**选中**，动作统一由底下的「确定」执行。
         *
         * ⚠️ **移动是单选** —— 它没有「多选」的语义：第一次搬走之后源就没了，
         *    第二个目标会搬一个不存在的东西。⛔ 所以这里按操作分：复制可多选、移动单选。
         *    把这条差别做进**交互**（而不是做进报错）才是对的 ——
         *    让玩家选不出一个做不到的组合，比事后告诉他「不行」好。
         *
         * ⚠️ 选中的样子**复用本项目已有的那套**（文字变 `brand` 色 + 右侧 ✓），
         *    ⛔ 不引入 `Checkbox`：它有自己的一套主题与获焦行为，本项目在焦点上栽过；
         *    而这一页别处的选中态（存档列表、版本列表）就是长这样的，一致比新奇重要。
         */
        Scroll() {
          Column() {
            /* ---- 同版本再存一份（只有复制 + 只有手动存档）---- */
            if (this.transferOp === 'copy' && this.selectedSaveEntry() !== undefined
                && this.selectedSaveEntry()!.kind === 'manual') {
              Row() {
                Column() {
                  Text('在这个版本里再复制一份')
                    .fontSize(15)
                    .fontColor(this.isTransferPicked(DUP_KEY)
                               ? $r('sys.color.brand') : $r('sys.color.font_primary'))
                    .width('100%')
                  Text('会多出一个 `-copy`。⚠️ 游戏里它显示成「untitled」——'
                       + '存档名存在游戏设置里，改名要进游戏做。')
                    .fontSize(12).fontColor($r('sys.color.font_tertiary'))
                    .width('100%').margin({ top: 4 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                if (this.isTransferPicked(DUP_KEY)) {
                  Text('✓').fontSize(16).fontColor($r('sys.color.brand'))
                }
              }
              .width('100%').padding(14)
              .borderRadius(CARD_RADIUS_VP)
              .backgroundColor($r('app.color.launcher_bg'))
              .margin({ bottom: 8 })
              .onClick(() => { this.toggleTransferPick(DUP_KEY); })
            }

            /* ---- 战役存档说明为什么没有上面那一项 ---- */
            if (this.transferOp === 'copy' && this.selectedSaveEntry() !== undefined
                && this.selectedSaveEntry()!.kind === 'sector') {
              Text('⚠️ 战役存档不能在同一个版本里复制 —— 一个区块出现两份存档，游戏会认不出来。'
                   + '要备份它，请复制到别的版本。')
                .fontSize(12).fontColor($r('sys.color.warning'))
                .width('100%').margin({ bottom: 10 })
            }

            /* ---- 别的版本 ---- */
            ForEach(this.transferTargets(), (v: VersionEntry) => {
              Row() {
                Column() {
                  Text(v.label)
                    .fontSize(15)
                    .fontColor(this.isTransferPicked(v.path)
                               ? $r('sys.color.brand') : $r('sys.color.font_primary'))
                    .width('100%')
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(this.transferTargetNote(v))
                    .fontSize(12).fontColor($r('sys.color.font_tertiary'))
                    .width('100%').margin({ top: 4 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                if (this.isTransferPicked(v.path)) {
                  Text('✓').fontSize(16).fontColor($r('sys.color.brand'))
                }
              }
              .width('100%').padding(14)
              .borderRadius(CARD_RADIUS_VP)
              .backgroundColor($r('app.color.launcher_bg'))
              .margin({ bottom: 8 })
              .onClick(() => { this.toggleTransferPick(v.path); })
            }, (v: VersionEntry) => v.path)

            if (this.transferTargets().length === 0
                && !(this.transferOp === 'copy' && this.selectedSaveEntry() !== undefined
                     && this.selectedSaveEntry()!.kind === 'manual')) {
              Text('没有可以选的目标 —— 先在「首页」导入另一个游戏版本。')
                .fontSize(12).fontColor($r('sys.color.font_tertiary'))
                .width('100%').margin({ top: 8 })
            }
          }
          .width('100%')
        }
        .width('100%')
        .constraintSize({ maxHeight: 320 })
        .align(Alignment.TopStart)
        .margin({ top: 12 })

        /* [B] 上一次「确定」的结果。⛔ 只是一句话，不是门 —— 没成功的会列在这儿。 */
        if (this.transferNote !== '') {
          Text(this.transferNote)
            .fontSize(12).fontColor($r('sys.color.warning'))
            .width('100%').margin({ top: 10 })
        }

        Divider().strokeWidth(1).color($r('app.color.launcher_border')).margin({ top: 8 })
        Row() {
          /* [B] 选不出目标时**禁用**是对的：它不是逃生门，是这次动作本身。
           * ⚠️ 本项目对「别禁用逃生门」有明确结论 —— 那条针对的是**出路**，
           * 而这里按下去必须得有个已选的目标，否则无事可做。 */
          Button(this.transferOp === 'move' ? '确定移动' : '确定复制')
            .fontSize(15)
            .layoutWeight(1)
            .enabled(this.transferPicked.length > 0)
            .onClick(() => { this.confirmTransfer(); })
          Button('取消')
            .fontSize(14)
            .layoutWeight(1)
            .margin({ left: 12 })
            .onClick(() => { this.closeTransferDialog(); })
        }
        .width('100%')
        .margin({ top: 14 })
      }
      .width('100%')
      .constraintSize({ maxWidth: this.dialogWidthVp() })
      .padding(20)
      .backgroundColor($r('app.color.launcher_card'))
      .borderRadius(CARD_RADIUS_VP)
      .alignItems(HorizontalAlign.Start)
      /* [B] 吞掉落在卡片上的点击 —— 与隔离窗同一处理由。 */
      .onClick(() => {})
    }
    .width('100%').height('100%')
    .backgroundColor('#80000000')
    .justifyContent(FlexAlign.Center)
    .padding({ left: 32, right: 32 })
  }

  @Builder
  VaultView() {
    Column() {
      Row() {
        /* [A] ⚠️ 用户 2026-10-02：「返回按钮太小了」。
         * ⭐ 字形 18 → **26**，并给足内边距 —— 可点区域从约 18×18 变成约 46×46，
         *    那接近触摸目标的下限（约 44）。⛔ 别只放大字形而不给内边距：
         *    字形大了但热区还贴着笔画，照样点不中。 */
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(26).fontColor([$r('sys.color.brand')])
          .padding({ left: 10, right: 14, top: 10, bottom: 10 })
          .onClick(() => { this.closeVault(); })
        Text('垃圾站')
          .fontSize(18).fontColor($r('sys.color.font_primary'))
          .layoutWeight(1)
        Text(this.vaultEntries.length === 0 ? '空' : (String(this.vaultEntries.length) + ' 项'))
          .fontSize(12).fontColor($r('sys.color.font_tertiary'))
      }
      .width('100%')
      .padding({ left: 12, right: 16, top: 16, bottom: 8 })
      .alignItems(VerticalAlign.Center)

      /* [A]
       * 保留期。⭐ 用户 2026-10-02 定的是**全局**（「一次性设成全局」）——
       * 每次删都问一遍会把同一个问题的答案反复要一遍。
       * ⚠️ 放在这一屏而不是设置页：玩家是在**看垃圾站**的时候才会想「留多久」，
       *    而他一旦离开这一屏，那个念头就没了。
       */
      Row() {
        Text('保留')
          .fontSize(12).fontColor($r('sys.color.font_tertiary'))
        ForEach(VAULT_DAYS_CHOICES, (d: number) => {
          Text(this.vaultDaysLabel(d))
            .fontSize(13)
            .fontColor(this.vaultDays === d
                       ? $r('sys.color.font_primary') : $r('sys.color.font_secondary'))
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(9)
            .backgroundColor(this.vaultDays === d
                             ? $r('app.color.launcher_border') : $r('app.color.launcher_bg'))
            .margin({ left: 8 })
            .onClick(() => { this.setVaultDays(d); })
        }, (d: number) => String(d))
      }
      .width('100%')
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)

      /* [B] 上一次操作的结果。⛔ 只是一句话，不是门 —— 失败也照旧能继续用。 */
      if (this.vaultNote !== '') {
        Text(this.vaultNote)
          .fontSize(12).fontColor($r('sys.color.warning'))
          .width('100%').margin({ top: 10 }).padding({ left: 16, right: 16 })
      }
      /* [B] 清掉到期条目时**说一声** —— 默默地少掉几项会让玩家以为是自己记错了。 */
      if (this.vaultPurgedLast > 0) {
        Text('上次清理删掉了 ' + String(this.vaultPurgedLast) + ' 个到期的存档。')
          .fontSize(12).fontColor($r('sys.color.font_tertiary'))
          .width('100%').margin({ top: 10 }).padding({ left: 16, right: 16 })
      }

      Scroll() {
        Row() {
          Column() {
            if (this.vaultEntries.length === 0) {
              Text('垃圾站是空的')
                .fontSize(15).fontColor($r('sys.color.font_secondary'))
                .margin({ top: 20 })
              Text('删掉的存档会先放到这里，到期才真正清理')
                .fontSize(12).fontColor($r('sys.color.font_tertiary'))
                .margin({ top: 8 })
            }
            ForEach(this.vaultEntries, (e: VaultEntry) => {
              Column() {
                Row() {
                  Column() {
                    Text(e.label === '' ? e.id : e.label)
                      .fontSize(15).fontColor($r('sys.color.font_primary'))
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text('删除于 ' + formatMs(e.deletedMs) + '  ·  '
                         + String(e.count) + ' 个文件  ·  ' + formatSaveSize(e.bytes))
                      .fontSize(12).fontColor($r('sys.color.font_tertiary'))
                      .margin({ top: 4 })
                    Text('原来属于 ' + this.vaultOwnerText(e))
                      .fontSize(12).fontColor($r('sys.color.font_secondary'))
                      .margin({ top: 2 })
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(describeExpiry(e, Date.now()))
                      .fontSize(12)
                      .fontColor(e.archived
                                 ? $r('sys.color.font_secondary') : $r('sys.color.warning'))
                      .margin({ top: 2 })
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                }
                .width('100%')

                Row() {
                  Button('放回')
                    .fontSize(13)
                    .onClick(() => { this.doVaultRestore(e); })
                  Button(e.archived ? '取消归档' : '归档')
                    .fontSize(13)
                    .margin({ left: 8 })
                    .onClick(() => { this.doVaultToggleArchive(e); })
                  Button('彻底删除')
                    .fontSize(13)
                    .fontColor($r('sys.color.warning'))
                    .backgroundColor($r('app.color.launcher_bg'))
                    .margin({ left: 8 })
                    .onClick(() => { this.doVaultPurge(e); })
                }
                .width('100%')
                .margin({ top: 10 })
              }
              .width('100%')
              .padding(14)
              .borderRadius(CARD_RADIUS_VP)
              .backgroundColor($r('app.color.launcher_card'))
              .margin({ bottom: 8 })
              .alignItems(HorizontalAlign.Start)
            /* [A] ⛔⛔ **key 必须带上【会变的字段】** —— 这就是用户 2026-10-02 报的
             * 「取消归档 / 放回，点了 UI 不刷新」的成因之一。
             *
             * ⭐ ArkUI 的 `ForEach` 按 key 做差分：**key 没变的那一项会被【复用】、
             *    不会重建** ⇒ 行里的文字（「已归档，不会自动清理」→「还有 7 天清理」）
             *    永远停在旧值上。⚠️ 而 `e.id` 只在**增删**时变，
             *    归档/取消归档是**原地改内容** ⇒ key 一模一样 ⇒ 界面一动不动。
             *
             * ⚠️ 所以 key 里要放**渲染真正依赖的**那几个字段：归档位与到期时刻。
             * ⛔ 别只写 `e.id`：那在「原地改」这一类操作上必然失灵，而且**看起来完全正常**。 */
            }, (e: VaultEntry) => e.id + '|' + (e.archived ? 'a' : 'n') + '|' + String(e.expiresMs))
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 12 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Start)
        .alignItems(VerticalAlign.Top)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)

      /* [B] 与悬浮底栏之间的留白。见 BAR_CLEARANCE_VP。 */
      Blank().height(BAR_CLEARANCE_VP)
    }
    .width('100%').height('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /* [A]
   * 删除的确认框。
   *
   * ⭐ **它同时承担两件事**：「确认删除」与「选保留方式」。那两个选项就是垃圾站里条目的
   *    两种状态（到期清理 / 归档不清理），所以不需要第二个窗。
   *
   * ⚠️ 结构照抄「打开数据隔离」那个窗（同屏遮罩 + 卡片 + 点卡片不冒泡 + **点空白不关**）：
   *    那个窗的理由在这里同样成立 —— 一个手滑点空白就消失的确认框比没有更糟。
   *    ⛔ 别照「关于 / 查看数据」那两个窗去加「点外面也关」，它们是**只读**的。
   */
  /* [A] ⭐⭐ 多选删除的确认框（用户 2026-10-02）。
   *
   * ⭐ 形状是他指定的：
   *    「标题应该是显示多个，字符超过一定数量改成 ...，**用户可以点击**，
   *      出现一个小的提示窗展示**所有选中的存档（包括来源于哪里）**。」
   *
   * ⇒ 三件事，各有各的理由：
   *    ① 标题写出**有几个**（单删那个窗写的是一个名字，这里写一批）
   *    ② 名字那条**超长就截成 `...`** —— 一次选二十个，标题不可能全塞下
   *    ③ 它**可点**，点开一张小名单，每条带**来源**（`ownerOfDir` 那套）
   *
   * ⚠️ 名单**默认收起**、并且**放在这个窗里面**而不是再弹一层：
   *    两层弹窗叠在一起时，返回键该关哪一层会变成一个问题（本项目为此栽过）。
   *
   * ⛔ 没有「逐条选择保留方式」那一套 —— 一批就是一次决定，保留期用全局那个
   *    （理由与单删那个窗一致：区别写进按钮标签，一处说清）。
   *    归档仍然可以在垃圾站里逐条补。
   *
   * ⚠️ 结构照抄 `DeleteAskDialog`（同屏遮罩 + 卡片 + 点卡片不冒泡 + **点空白不关**）：
   *    一个手滑点空白就消失的确认框比没有更糟。
   */
  @Builder
  MultiDeleteAskDialog() {
    Column() {
      Column() {
        Text('删除这 ' + String(this.multiPicked.length) + ' 个存档')
          .fontSize(17).fontColor($r('sys.color.font_primary'))
          .width('100%').textAlign(TextAlign.Center)

        /* [A] 名字那条。⭐ `▾` / `▴` 是**它的可点性**唯一的视觉线索 ——
         * ⛔ 别只靠「看起来像一行字」暗示它能点：本项目在别处栽过「给了控件但没给出口」，
         * 而这里是反过来的（有出口，但没人知道它在）。
         * ⚠️ 箭头**不放进那个 Text 里**：它会被 `Ellipsis` 一起截掉，
         * 于是名字越长越看不见入口 —— 恰好把最需要展开的那种情形挡掉。 */
        Row() {
          Text(this.pickedNamesText())
            .fontSize(13).fontColor($r('sys.color.font_secondary'))
            .layoutWeight(1)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.multiListOpen ? '▴' : '▾')
            .fontSize(13).fontColor($r('sys.color.brand'))
            .margin({ left: 8 })
        }
        .width('100%')
        .margin({ top: 12 })
        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
        .borderRadius(9)
        .backgroundColor($r('app.color.launcher_bg'))
        .alignItems(VerticalAlign.Center)
        .onClick(() => { this.multiListOpen = !this.multiListOpen; })

        if (this.multiListOpen) {
          Scroll() {
            Column() {
              ForEach(this.pickedRows(), (r: SaveRow) => {
                Column() {
                  Text(r.entry.label)
                    .fontSize(13).fontColor($r('sys.color.font_primary'))
                    .width('100%')
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  /* [B] 来源 —— 与垃圾站那行用**同一个** `ownerOfDir`，
                   * 所以两处对同一条存档的说法不会分叉。 */
                  Text('原来属于 ' + this.ownerOfDir(r.dir))
                    .fontSize(11).fontColor($r('sys.color.font_tertiary'))
                    .width('100%').margin({ top: 2 })
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)
                .margin({ bottom: 10 })
              }, (r: SaveRow) => this.saveKey(r.dir, r.entry.id))
            }
            .width('100%')
          }
          .width('100%')
          /* [B] 给个上限，让名单自己滚 —— ⛔ 不给的话一次选二十个会把按钮顶出屏幕，
           * 而按钮正是这个窗存在的理由。与启动失败那个窗同一条道理。 */
          .constraintSize({ maxHeight: 220 })
          .align(Alignment.TopStart)
          .margin({ top: 10 })
        }

        Divider().strokeWidth(1).color($r('app.color.launcher_border')).margin({ top: 14 })

        /* [B] 与单删那个窗**同一套措辞**（`放 进垃圾站（保留到 X）`）：
         * 玩家在两个地方看到的应当是同一句话，否则他会以为是两种不同的去向。 */
        Button('放进垃圾站（保留到 ' + this.deleteExpiryDate() + '）')
          .fontSize(15)
          .width('72%').alignSelf(ItemAlign.Center)
          .margin({ top: 16 })
          .onClick(() => { this.deleteMultiToVault(); })

        Divider().strokeWidth(1).color($r('app.color.launcher_border')).margin({ top: 14 })
        Button('取消')
          .fontSize(14)
          .width('25%').alignSelf(ItemAlign.Center)
          .margin({ top: 12 })
          .onClick(() => { this.showMultiAsk = false; })
      }
      .width('100%')
      .constraintSize({ maxWidth: this.dialogWidthVp() })
      .padding(20)
      .backgroundColor($r('app.color.launcher_card'))
      .borderRadius(CARD_RADIUS_VP)
      .alignItems(HorizontalAlign.Start)
      /* [B] 吞掉落在卡片上的点击 —— 与隔离窗同一处理由。 */
      .onClick(() => {})
    }
    .width('100%').height('100%')
    .backgroundColor('#80000000')
    .justifyContent(FlexAlign.Center)
    .padding({ left: 32, right: 32 })
  }

  @Builder
  DeleteAskDialog() {
    Column() {
      Column() {
        Text('删除「' + this.selectedSaveLabel() + '」')
          .fontSize(17).fontColor($r('sys.color.font_primary'))
          .width('100%').textAlign(TextAlign.Center)

        /* [A] ⛔⛔ **这个框里【没有任何说明文字】** —— 用户 2026-10-02：
         *    「删除还需要说明吗？？？下面按钮都说了放到垃圾站，那上面的文字说明根本没用」。
         *
         *    ⭐ 他是对的，而且理由不只是「嫌啰嗦」：原来的写法把**区别**放在**按钮上面
         *      的文字**里（「保留到 X，然后自动清理」/「不会自动清理…」），
         *      而按钮本身只说「放进垃圾站」「归档」—— 两者分开之后，
         *      玩家要**先读上面、再看下面**才能知道自己在选什么。
         *    ⇒ 把区别**直接写进按钮标签**：一处说清，不需要对照。
         *
         * ⚠️ 日期仍然保留（它是有信息量的那一部分，而且只有这里有），只是压到
         *    「保留到 2026-10-09」这种程度 —— 时分对 3/7/30 天的时间尺度是噪音。
         */
        Divider().strokeWidth(1).color($r('app.color.launcher_border')).margin({ top: 14 })

        Button('放进垃圾站（保留到 ' + this.deleteExpiryDate() + '）')
          .fontSize(15)
          .width('72%').alignSelf(ItemAlign.Center)
          .margin({ top: 16 })
          .onClick(() => { this.doVaultDelete(false); })

        Button('归档（不自动清理）')
          .fontSize(15)
          .width('72%').alignSelf(ItemAlign.Center)
          .margin({ top: 10 })
          .onClick(() => { this.doVaultDelete(true); })

        Divider().strokeWidth(1).color($r('app.color.launcher_border')).margin({ top: 14 })
        Button('取消')
          .fontSize(14)
          .width('25%').alignSelf(ItemAlign.Center)
          .margin({ top: 12 })
          .onClick(() => { this.showDeleteAsk = false; })
      }
      .width('100%')
      .constraintSize({ maxWidth: this.dialogWidthVp() })
      .padding(20)
      .backgroundColor($r('app.color.launcher_card'))
      .borderRadius(CARD_RADIUS_VP)
      .alignItems(HorizontalAlign.Start)
      /* [B] 吞掉落在卡片上的点击 —— 与隔离窗同一处理由。 */
      .onClick(() => {})
    }
    .width('100%').height('100%')
    .backgroundColor('#80000000')
    .justifyContent(FlexAlign.Center)
    .padding({ left: 32, right: 32 })
  }

  @Builder
  SavesTab() {
    Column() {
      /* [A] ⭐ 垃圾站是**另一个地方**，所以它在最外层就分开了 ——
       * 进去之后看不到分段控件、也看不到存档列表，只有一个返回。
       * ⚠️ 与「手机详情子页」同一个形状（那个也在最外层分），理由也一样：
       *    它们是「去了别处」，不是「换了个视图」。 */
      if (this.showVault) {
        this.VaultView()
      } else if (this.isNarrow() && this.panelOpen) {
        /* ===================== 窄屏：子页 ===================== */
        Row() {
          /* [B] 与垃圾站那个返回同尺寸、同热区 —— 两处是同一个动作，别长得不一样。 */
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(26).fontColor([$r('sys.color.brand')])
            .padding({ left: 10, right: 14, top: 10, bottom: 10 })
            .onClick(() => { this.panelOpen = false; })
          Text(this.savesView === SAVES_VIEW_VERSION
               ? this.selectedVersionLabel() : this.selectedSaveLabel())
            .fontSize(18).fontColor($r('sys.color.font_primary'))
            .layoutWeight(1)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .padding({ left: 12, right: 16, top: 16, bottom: 8 })
        .alignItems(VerticalAlign.Center)

        /* [A] ⚠️ 面板必须包一层 `layoutWeight(1)`：面板自身写的是 `height('100%')`，
         * 而这里它上面还有一个返回行、下面还有一个 `Blank` ⇒ 不包的话它会要求
         * **整列**那么高，把返回行挤出屏幕。包一层之后 `height('100%')` 参照的是
         * 这一层，剩下的高度正好是它。 */
        Column() {
          if (this.savesView === SAVES_VIEW_VERSION) {
            this.VersionDataPanel()
          } else {
            this.SaveDataPanel()
          }
        }
        .width('100%')
        .layoutWeight(1)
      } else {
        /* ===================== 列表（含宽屏的右侧面板）===================== */
        Column() {
          /* [A]
           * 视图切换：按存档 / 按版本。⭐ **它就是这一屏的标题**（用户 2026-10-02 定的）。
           *
           * ⚠️ 原来这里写着一行 `Text('存档')`，分段控件摆在**右边**。用户指出两个问题：
           *    ① 分段控件应当在**左边**；② `存档` 与 `按存档` **语义重复**。
           *    ⇒ 于是标题整个撤掉，由分段控件顶上 —— 屏幕上少一个词，信息一个不少。
           *
           * ⚠️ 形状**照抄设置页那组粒度选择**（一排 `Text` ＋ 切底色），⛔ 不新造组件。
           *    「分段控件」这种自带主题的组件，本项目为它付过代价 ——
           *    `stateStyles` 那次编译期崩，HdsTabs 那次发现 UI Design Kit 只在中国境内可用。
           * ⚠️ 未选中的底色是 `launcher_bg`（不是 `launcher_card`）：后者与页面底色同色，
           *    会让未选中的那一个**完全看不见**。
           */
          Row() {
            Text('按存档')
              .fontSize(13)
              .fontColor(this.savesView === SAVES_VIEW_SAVE
                         ? $r('sys.color.font_primary') : $r('sys.color.font_secondary'))
              .padding({ left: 12, right: 12, top: 7, bottom: 7 })
              .borderRadius(9)
              .backgroundColor(this.savesView === SAVES_VIEW_SAVE
                               ? $r('app.color.launcher_border') : $r('app.color.launcher_bg'))
              .onClick(() => {
                this.savesView = SAVES_VIEW_SAVE;
                this.panelOpen = false;
              })
            Text('按版本')
              .fontSize(13)
              .fontColor(this.savesView === SAVES_VIEW_VERSION
                         ? $r('sys.color.font_primary') : $r('sys.color.font_secondary'))
              .padding({ left: 12, right: 12, top: 7, bottom: 7 })
              .borderRadius(9)
              .backgroundColor(this.savesView === SAVES_VIEW_VERSION
                               ? $r('app.color.launcher_border') : $r('app.color.launcher_bg'))
              .margin({ left: 8 })
              .onClick(() => {
                this.savesView = SAVES_VIEW_VERSION;
                this.panelOpen = false;
              })
            /* [A] ⭐ 垃圾站入口。⚠️ 用一个 `Blank()` 把它推到**最右**，而不是给它
             * `layoutWeight` —— 那会让它按剩余宽度撑开，点到的区域比看起来大得多。
             * ⚠️ 空的时候也显示（写「垃圾站」而不写「(0)」）—— 一个数字 0 挂在那里
             * 只会让人以为坏了；而**空垃圾站本身有说明作用**（删掉的东西会去哪）。 */
            Blank()
            Text(this.vaultEntries.length === 0
                 ? '垃圾站'
                 : ('垃圾站 ' + String(this.vaultEntries.length)))
              .fontSize(13).fontColor($r('sys.color.brand'))
              .padding({ left: 12, right: 4, top: 7, bottom: 7 })
              .onClick(() => { this.openVault(); })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          /* [B] 明确写出**在数哪个目录**。隔离一开一关，这个路径就换了 ——
           * 而不写出来的话，玩家会以为存档丢了。
           * ⚠️ 「按版本」视图下这一行改成版本个数：那时左边根本不是某一份存档目录。 */
          Text(this.savesHeaderLine())
            .fontSize(11).fontColor($r('sys.color.font_tertiary'))
            .margin({ top: 8 })
            .copyOption(CopyOptions.LocalDevice)

          /* [B] 多选那条，以及上一次多选删除的结果。⛔ 结果只说一句就走 —— 它是提示，不是门。 */
          if (this.multiMode) {
            this.MultiBar()
          }
          if (this.savesNote !== '') {
            Text(this.savesNote)
              .fontSize(12).fontColor($r('sys.color.font_secondary'))
              .width('100%').margin({ top: 8 })
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 20 })
        .alignItems(HorizontalAlign.Start)

        Row() {
          Scroll() {
            Row() {
              Column() {
                if (this.savesView === SAVES_VIEW_VERSION) {
                  /* [B] 版本列表。⚠️ 列表项同样**内联**写 —— 见文件开头 @Builder 按值传递那条。 */
                  if (this.versions.length === 0) {
                    Text('没有可用的游戏版本')
                      .fontSize(14).fontColor($r('sys.color.font_secondary'))
                      .margin({ top: 20 })
                  }
                  ForEach(this.versions, (v: VersionEntry) => {
                    Row() {
                      Column() {
                        /* [B] **版本在前、文件名在后** —— 与组头同一套顺序（用户 2026-10-02）。 */
                        Text(v.version === '' ? '未知版本' : v.version)
                          .fontSize(15)
                          .fontColor(this.selectedVersion === v.path
                                     ? $r('sys.color.brand') : $r('sys.color.font_primary'))
                          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                        Text(v.label + '  ·  ' + this.versionSavesLine(v))
                          .fontSize(12).fontColor($r('sys.color.font_tertiary'))
                          .margin({ top: 4 })
                          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                      }
                      .alignItems(HorizontalAlign.Start)
                      .layoutWeight(1)

                      if (this.selectedVersion === v.path) {
                        Text('✓')
                          .fontSize(16).fontColor($r('sys.color.brand'))
                      }
                    }
                    .width('100%')
                    .padding(14)
                    .borderRadius(CARD_RADIUS_VP)
                    .backgroundColor($r('app.color.launcher_card'))
                    .margin({ bottom: 8 })
                    .onClick(() => { this.openVersionRow(v.path); })
                  }, (v: VersionEntry) => v.path)
                } else if (this.saveGroups.length === 0) {
                  Text('没有存档')
                    .fontSize(15).fontColor($r('sys.color.font_secondary'))
                    .margin({ top: 20 })
                  Text('进游戏玩一局，存档会出现在这里')
                    .fontSize(12).fontColor($r('sys.color.font_tertiary'))
                    .margin({ top: 8 })
                } else {
                  /* [A]
                   * ⭐⭐ 一屏列出**所有版本**的存档，按「共用同一份数据的版本」分组。
                   *
                   * 用户 2026-10-02：「按存档那里应该列出**所有版本**的存档，
                   *   按照顺序"A版本"->"B版本"这样排下去，小字和详情标注这个存档属于哪（几个）版本」。
                   *
                   * ⛔⛔ 原来只列**当前版本**那一个目录 ⇒ 开了隔离之后，
                   *    别的版本的存档**完全看不见**；而当前那个目录还没建出来时
                   *    屏幕会写「没有存档」—— 玩家看到的是「我的存档全都不见了」，
                   *    尽管几十上百个存档都还在盘上。**这就是他报的那个 bug。**
                   *
                   * ⚠️ 分组键是**目录**而不是版本（理由见 buildSaveGroups）：
                   *    隔离关着时只有一组，组头会写「N 个版本共用同一份数据」。
                   */
                  /* [A] ⭐⭐ 「当前版本那一档是空的」在**存档页**也要有出口 ——
                   * 玩家来找存档时就是在这儿看见「空」的，那就该在这儿把它补上。
                   * ⚠️ 放在列表**顶上**而不是塞进那一组里：这个状态意味着当前版本那一组
                   *    本身是空的，把按钮放进一个空组里，玩家会以为它只对那一组有效。 */
                  if (this.isolationStale) {
                    this.StaleCopyOffer()
                  }
                  ForEach(this.saveGroups, (g: SaveGroup) => {
                    Column() {
                      /* [B] 组头 = 用户要的「小字」那一半：谁在读这份数据。 */
                      Text(this.groupTitle(g))
                        .fontSize(13).fontColor($r('sys.color.font_secondary'))
                        .width('100%')
                        .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                      Text(this.groupSub(g))
                        .fontSize(11).fontColor($r('sys.color.font_tertiary'))
                        .width('100%').margin({ top: 2 })

                      if (g.saves.length === 0) {
                        Text('这个目录还没有存档')
                          .fontSize(12).fontColor($r('sys.color.font_tertiary'))
                          .width('100%').margin({ top: 8 })
                      }
                      ForEach(g.saves, (sv: SaveEntry) => {
                        Row() {
                          Column() {
                            Text(sv.label)
                              .fontSize(15)
                              .fontColor(this.rowHot(this.saveKey(g.dir, sv.id))
                                         ? $r('sys.color.brand') : $r('sys.color.font_primary'))
                              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                            Text((sv.kind === 'sector' ? (sv.sectors + ' 个区块 · ') : '')
                                 + formatSaveSize(sv.bytes) + ' · ' + formatSaveDate(sv.mtime))
                              .fontSize(12).fontColor($r('sys.color.font_tertiary'))
                              .margin({ top: 4 })
                          }
                          .alignItems(HorizontalAlign.Start)
                          .layoutWeight(1)

                          if (this.rowHot(this.saveKey(g.dir, sv.id))) {
                            Text('✓')
                              .fontSize(16).fontColor($r('sys.color.brand'))
                          }
                        }
                        .width('100%')
                        .padding(14)
                        .borderRadius(CARD_RADIUS_VP)
                        .backgroundColor($r('app.color.launcher_card'))
                        .margin({ top: 8 })
                        /* [A] ⭐ 长按进多选；已经在多选态时，**点击**就是勾选（见下）。
                         * ⚠️ 多选态里长按与点击做同一件事，是为了让「已经进去了」的人
                         *    不会因为记错手势而以为点不动。 */
                        .gesture(LongPressGesture({ repeat: false, duration: 400 })
                          .onAction(() => { this.enterMulti(this.saveKey(g.dir, sv.id)); }))
                        .onClick(() => {
                          if (this.multiMode) {
                            this.toggleMultiPick(this.saveKey(g.dir, sv.id));
                            return;
                          }
                          this.openSaveRow(g.dir, sv.id);
                        })
                      }, (sv: SaveEntry) => this.saveKey(g.dir, sv.id))
                    }
                    .width('100%')
                    .margin({ bottom: 16 })
                    .alignItems(HorizontalAlign.Start)
                  }, (g: SaveGroup) => g.dir)
                }
              }
              .width('100%')
              .padding({ left: 16, right: 8, top: 12 })
            }
            /* [A] ⛔⛔ **这一行 `height('100%')` 必须没有，而它是用户 2026-10-02 报的
             *    「我只能看到头两个，后面的看不到（列表是固定死的）」的唯一原因。**
             *
             * ⭐ `Scroll` 的直接子节点写 `height('100%')` ⇒ 它的高度**等于视口**
             *    ⇒ 内容再高也是「和视口一样高」⇒ `Scroll` **可滚动的余量是 0**，
             *    多出来的部分被裁掉。⚠️ 界面上看起来就像「列表只有这么长」，
             *    而不是「滚不动」—— 所以它一直没被发现。
             *
             * ⚠️ 它当初是被加进来治「列表在竖直方向居中」的（Row 的交叉轴默认
             *    `VerticalAlign.Center`，有了 100% 高度就真去居中了）。
             * ⭐ 而正确的解法是**不要那个高度**：Row 变成内容高 ⇒ 没有多余空间
             *    ⇒ 居中无从发生，滚动也照常。⇒ **同一行同时治了两件事，只是方向相反。**
             * ⛔ 别再把 height 加回来「以防万一」。 */
            .width('100%')
            .justifyContent(FlexAlign.Start)
            .alignItems(VerticalAlign.Top)
          }
          .layoutWeight(3)
          .height('100%')
          /* [A] ⛔⛔ **必须有这一行，否则内容短的时候会被竖直居中。**
           *
           * ⭐ `Scroll` 的 `align` **默认是 `Alignment.Center`** —— 内容比视口矮时它
           *    就把内容摆在中间。用户 2026-10-02 报的「按版本，左边列表居中了，
           *    应该置顶」就是它。
           *
           * ⚠️ 为什么以前看不出来：那时内层 Row 带着 `height('100%')`，
           *    **永远和视口一样高** ⇒ 没有「多余空间」可以居中，也就没有症状。
           *    而那一行正是让存档列表**滚不动**的原因（见那边的说明）。
           * ⇒ ⭐ 同一个布局缺了两个属性，各自遮住了对方的毛病：
           *    去掉 height 暴露了居中，补上 align 才两件都平。
           * ⛔ 别只改一个。 */
          .align(Alignment.TopStart)
          .scrollBar(BarState.Off)

          /* [A] ⚠️ 窄屏时**不渲染右侧面板** —— 那时它是子页（见上面那个分支）。
           * ⛔ 别因为「窄屏也能挤一挤」就把它留下：手机上 100% 宽度里再切两栏，
           * 每栏只剩一百多 vp，两栏都没法读。
           *
           * ⛔⛔ **这一层 `Column().layoutWeight(7)` 是必需的，而我第一版漏了它。**
           *    面板自己的根节点写的是 `width('100%')` 而**没有权重** ⇒ 直接放进 Row 里，
           *    它会要求**整行**的宽度，于是左边那个 `layoutWeight(3)` 的 `Scroll`
           *    被挤成 0 宽 —— ⭐ **症状就是用户报的「从左边选的列表直接没了」**。
           *    ⇒ 权重必须加在**调用点**，不能加在面板里：面板在手机子页是包在
           *    `layoutWeight(1)` 里的，若它自己再带一个，两层权重叠在一起会算错比例。
           *    ⚠️ 3 : 7 与注释里写的一致（左边只是存档名，右边要放下整张元数据表）。 */
          if (!this.isNarrow()) {
            Column() {
              if (this.savesView === SAVES_VIEW_VERSION) {
                this.VersionDataPanel()
              } else {
                this.SaveDataPanel()
              }
            }
            .width('100%')
            .height('100%')
            .layoutWeight(7)
          }
        }
        /* [A] ⚠️ 这里**只有** `layoutWeight(1)`，没有 `height('100%')` ——
         * 外面那个 Column 里除了它还有一行标题和一个 `Blank`，写 height('100%')
         * 就是在要求超出父容器的高度。（我改这一版时顺手加过，已去掉。） */
        .width('100%')
        .layoutWeight(1)
        .alignItems(VerticalAlign.Top)
      }

      /* [B] 与悬浮底栏之间的留白。见 BAR_CLEARANCE_VP。 */
      Blank().height(BAR_CLEARANCE_VP)
    }
    .width('100%').height('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /* [A]
   * 设置页。用户 2026-10-02 改成**全宽 + 卡片**，参考 AMCL 的设置页：
   *
   *   「设置你可以参考AMCL的那种布局」
   *
   * ⭐ 从那边的形态里取了三样**结构**上的东西，⛔ 不是照抄它的配色/图标体系：
   *   1. **整片铺满**（左右各留 20）—— 它原本是一条 30% 的窄栏，现在有整屏可用。
   *   2. **圆角卡片分组**（`launcher_card` + `CARD_RADIUS_VP` + 内边距 16）——
   *      每一组是一块，组与组之间用留白分开，而不是靠一堆 `top: 28` 硬撑。
   *   3. **组标题在卡片外面**（AMCL 的「常用配置」「按场景调整」）——
   *      ⭐ 标题在卡片外，读者才知道它是**这一组的名字**，而不是卡片里的第一项。
   *
   * ⚠️ 我们**没有**取它的「每节点进去是子页」那套：这一页只有四组、六项设置，
   *    再套一层子页只会让人多点一次。用户也是这么选的（「只改外观」）。
   *
   * ⚠️ 外面套 `Scroll` 是新加的。原来是裸 `Column` + `Blank()`，在平板上刚好放得下；
   *    但卡片式（每块有内边距、组间有留白）**总高变大了**，而手机上可用高度只有 800 上下
   *    ⇒ 不滚就会被裁掉，且裁掉的正好是最后一组「关于」。
   *    ⛔ `Blank()` 一并去掉 —— 它在可滚动容器里没有任何作用。
   */
  @Builder
  SettingsTab() {
    Scroll() {
      Column() {
        /* ================= 游戏 ================= */
        Text('游戏')
          .fontSize(13).fontColor($r('sys.color.font_secondary'))
          .width('100%')
        Column() {
          Text('游戏 jar 目录')
            .fontSize(14).fontColor($r('sys.color.font_primary'))
          /* [B] 与空状态同款两行：给人找的一行 + 可复制的一行。理由见空状态里的说明。 */
          Text(this.jarDirHuman === '' ? '　' : this.jarDirHuman)
            .fontSize(13).fontColor($r('sys.color.font_secondary'))
            .margin({ top: 4 })
          Text(this.jarDirHint === '' ? '（本设备上拿不到）' : this.jarDirHint)
            .fontSize(12).fontColor($r('sys.color.font_tertiary'))
            .margin({ top: 2 })
            .copyOption(CopyOptions.LocalDevice)

          Divider().strokeWidth(1).color($r('app.color.launcher_border'))
            .margin({ top: 14, bottom: 14 })

          /* [A]
           * 「本次启动将加载」与「重新扫描」**同一行** —— 用户 2026-10-02：
           *   「设置那里的重新扫描太宽了，这个按钮最好和解释说明的字在同一行。」
           *
           * ⚠️ 原来是「三行说明 + 一个 `width('100%')` 的按钮」上下排：
           *    按钮拉满整张卡片那么宽，而它只有四个字 —— 视觉重量远大于它做的事。
           *    ⇒ 说明一栏 `layoutWeight(1)` 吃掉剩余宽度，按钮按**内容**自适应。
           *
           * ⚠️ 字号【要给】。不给的话按钮按标签长度自适应时会**缩放字号** ——
           *    那正是当初「两个按钮字体大小不一样」的成因，换到别处同样成立。
           *
           * ⚠️ 对齐用 `VerticalAlign.Top`，不是 Center：说明有三行、按钮只有一行，
           *    居中的话按钮会浮在三行文字的**中间**，读起来像是挂在第二行上的。
           *    顶部对齐让它和标题那一行齐平 —— 那也是它作用的对象。
           */
          Row() {
            Column() {
              Text('本次启动将加载')
                .fontSize(14).fontColor($r('sys.color.font_primary'))
              Text(this.resolution.path === ''
                     ? '（没有可加载的游戏）'
                     : (this.resolution.source === 'user' ? '（玩家选择的）' : '（包内自带的）'))
                .fontSize(12).fontColor($r('sys.color.font_tertiary'))
                .margin({ top: 4 })
              Text(this.resolution.path === '' ? '—' : this.resolution.path)
                .fontSize(12).fontColor($r('sys.color.font_tertiary'))
                .margin({ top: 4 })
                .copyOption(CopyOptions.LocalDevice)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Button('重新扫描')
              .fontSize(BUTTON_FONT_VP)
              .margin({ left: 12 })
              .onClick(() => { this.refresh(); })
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        }
        .width('100%').padding(16)
        .backgroundColor($r('app.color.launcher_card'))
        .borderRadius(CARD_RADIUS_VP)
        .alignItems(HorizontalAlign.Start)
        .margin({ top: 8 })

        /* ================= 数据 ================= */
        Text('数据')
          .fontSize(13).fontColor($r('sys.color.font_secondary'))
          .width('100%')
          .margin({ top: 20 })
        Column() {
          Text('数据隔离')
            .fontSize(14).fontColor($r('sys.color.font_primary'))
          Text('把不同游戏版本的存档、蓝图、模组、研究进度分开保存')
            .fontSize(12).fontColor($r('sys.color.font_tertiary'))
            .margin({ top: 4 })

          /* [A] 四个写成**并列的一行**而不是下拉菜单：这是互斥的四选一，一眼看全比点开一层省事，
           * 而且「当前是哪一档」不需要点开才看得见。
           *
           * ⚠️ 下面那行说明是**必需**的，不是装饰：四档的差别（尤其中间两档）对玩家不是自明的，
           * 而选错的代价是「换个版本就看不到存档了」。
           *
           * ⚠️ 未选中的底色从 `launcher_card` 改成 `launcher_bg`：卡片本身就是 `launcher_card`，
           * 两者同色会让未选中的那三个**完全看不见**（这不是「颜色不好看」，是「没画出来」）。
           * 本项目在隔离弹窗那三个按钮上正是栽过这一跤。 */
          Row() {
            Text('不隔离')
              .fontSize(13)
              .fontColor(this.granularity === GRANULARITY_OFF
                         ? $r('sys.color.font_primary') : $r('sys.color.font_secondary'))
              .padding({ left: 12, right: 12, top: 7, bottom: 7 })
              .borderRadius(9)
              .backgroundColor(this.granularity === GRANULARITY_OFF
                               ? $r('app.color.launcher_border') : $r('app.color.launcher_bg'))
              .onClick(() => { this.chooseGranularity(GRANULARITY_OFF); })
            Text('大版本')
              .fontSize(13)
              .fontColor(this.granularity === GRANULARITY_NUMBER
                         ? $r('sys.color.font_primary') : $r('sys.color.font_secondary'))
              .padding({ left: 12, right: 12, top: 7, bottom: 7 })
              .borderRadius(9)
              .backgroundColor(this.granularity === GRANULARITY_NUMBER
                               ? $r('app.color.launcher_border') : $r('app.color.launcher_bg'))
              .margin({ left: 8 })
              .onClick(() => { this.chooseGranularity(GRANULARITY_NUMBER); })
            Text('构建号')
              .fontSize(13)
              .fontColor(this.granularity === GRANULARITY_BUILD
                         ? $r('sys.color.font_primary') : $r('sys.color.font_secondary'))
              .padding({ left: 12, right: 12, top: 7, bottom: 7 })
              .borderRadius(9)
              .backgroundColor(this.granularity === GRANULARITY_BUILD
                               ? $r('app.color.launcher_border') : $r('app.color.launcher_bg'))
              .margin({ left: 8 })
              .onClick(() => { this.chooseGranularity(GRANULARITY_BUILD); })
            Text('小版本')
              .fontSize(13)
              .fontColor(this.granularity === GRANULARITY_PATCH
                         ? $r('sys.color.font_primary') : $r('sys.color.font_secondary'))
              .padding({ left: 12, right: 12, top: 7, bottom: 7 })
              .borderRadius(9)
              .backgroundColor(this.granularity === GRANULARITY_PATCH
                               ? $r('app.color.launcher_border') : $r('app.color.launcher_bg'))
              .margin({ left: 8 })
              .onClick(() => { this.chooseGranularity(GRANULARITY_PATCH); })
          }
          .width('100%').margin({ top: 12 })

          Text(this.granularityHint(this.granularity))
            .fontSize(12).fontColor($r('sys.color.font_secondary'))
            .margin({ top: 10 })

          /* [A] ⭐⭐ 这一条是给**已经踩进去的状态**留的出口。
           * 它不是错误提示，而是一句**诊断**：说清现在什么状态、以及怎么退回去。
           * ⛔ 没有它，玩家只能看到「存档全没了」，而界面上没有任何线索指向隔离。 */
          if (this.isolationStale) {
            /* [A] ⛔ 原来这里只是一句提示（「请把隔离关掉（或重新打开一次）」）——
             * 那是让玩家去猜一个**我们该做**的动作。现在它是同一块可点的东西。 */
            this.StaleCopyOffer()
          }

          /* [B] 迁移出问题时的提示。⛔ 它不是门 —— 隔离照旧打开，只是新目录可能是空的，
           * 而原数据完好（我们是复制）。 */
          if (this.isolationNote !== '') {
            Text(this.isolationNote)
              .fontSize(12).fontColor($r('sys.color.font_tertiary'))
              .margin({ top: 8 })
          }
        }
        .width('100%').padding(16)
        .backgroundColor($r('app.color.launcher_card'))
        .borderRadius(CARD_RADIUS_VP)
        .alignItems(HorizontalAlign.Start)
        .margin({ top: 8 })

        /* ================= 启动 ================= */
        Text('启动')
          .fontSize(13).fontColor($r('sys.color.font_secondary'))
          .width('100%')
          .margin({ top: 20 })
        Column() {
          /* [A]
           * 启动后进哪里。用户 2026-10-01 要的：「加一个开关，用于选择是否启动进入首页/直接进入游戏」。
           *
           * ⭐ 这个开关是从一次真实的卡死里长出来的：他把一个 **mod 当成游戏**选了，于是
           * 每次打开都直接进游戏树、立刻闪退，而**没有任何界面能让他改回来**。
           * 检测机制（launch_pending）现在也能把他送回启动器，但这是**不依赖检测**的那条路 ——
           * 一个存在感为零、却让最坏情况有出口的开关。
           *
           * ⚠️ 默认是「先进首页」，见 LauncherPrefs 的 LAUNCH_MODE_DEFAULT。想省掉这一次点击
           * 就拨到「直接进游戏」；拨完立刻写盘，下一次启动生效。
           */
          Row() {
            Column() {
              Text('启动时直接进游戏')
                .fontSize(14).fontColor($r('sys.color.font_primary'))
              Text(this.launchMode === LAUNCH_MODE_GAME
                   ? '跳过这个界面，直接开始游戏'
                   : '先停在这个界面，由你点「启动游戏」')
                .fontSize(12).fontColor($r('sys.color.font_tertiary'))
                .margin({ top: 4 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            /* [B] 开关的「开」= 直接进游戏。写成左侧标签 + 右侧开关，而不是两个单选，
             * 是因为它确实是一个二元选择，没有第三种。 */
            Toggle({ type: ToggleType.Switch,
                     isOn: this.launchMode === LAUNCH_MODE_GAME })
              .onChange((on: boolean) => {
                this.launchMode = on ? LAUNCH_MODE_GAME : LAUNCH_MODE_HOME;
                writeLaunchMode(this.filesDir, this.launchMode);
              })
          }
          .width('100%')
        }
        .width('100%').padding(16)
        .backgroundColor($r('app.color.launcher_card'))
        .borderRadius(CARD_RADIUS_VP)
        .margin({ top: 8 })

        /* ================= 关于 ================= */
        Text('关于')
          .fontSize(13).fontColor($r('sys.color.font_secondary'))
          .width('100%')
          .margin({ top: 20 })
        /* [A]
         * 关于 —— 现在是一个【入口】，点开才是内容。
         *
         * 用户 2026-10-01 的原话：「关于独立出来，点击出现一个有关闭按钮（右上角）的窗口
         * 展示信息。」
         *
         * ⚠️ 它【曾经】是把整块信息平铺在这一页上的。那样做的问题不是好不好看，而是：
         * 设置页的主语是**设置**，而一块只能读、不能改的长文字会把真正的设置项挤下去。
         * ⇒ 收成一行，点开再看。
         *
         * ⚠️ 游戏那边（本页之外的悬浮球 →「关于」）还有一份同内容的浮层。它们够不到彼此
         * （那个在游戏树里），所以两份都得留；改文案时两边一起改。
         */
        Column() {
          Row() {
            Column() {
              Text('版本与许可')
                .fontSize(14).fontColor($r('sys.color.font_primary'))
              Text(this.appVersion === '' ? 'Mindustry Ark' : ('Mindustry Ark  ' + this.appVersion))
                .fontSize(12).fontColor($r('sys.color.font_tertiary'))
                .margin({ top: 4 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            /* [B] 一个朝右的箭头，表示「点进去还有一页」。用符号字形而不是字符，
             * 免得不同字体下宽度跳变。 */
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(16).fontColor([$r('sys.color.font_tertiary')])
          }
          .width('100%')
        }
        .width('100%').padding(16)
        .backgroundColor($r('app.color.launcher_card'))
        .borderRadius(CARD_RADIUS_VP)
        .margin({ top: 8 })
        .onClick(() => { this.showAbout = true; })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 20, bottom: BAR_CLEARANCE_VP })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%').height('100%')
    .align(Alignment.TopStart)
    .scrollBar(BarState.Off)
  }

  build() {
    /* [A]
     * 外面这层 Stack 只为了在界面之上放两个弹窗（build 末尾那两个 if）。
     *
     * ⚠️ 内层的 Navigation 及其整条链**刻意没有重新缩进**。理由与 Index.ets 里那处
     * 完全一样：给几百行整体加两格缩进，会让「多了一个 Stack」这个唯一真实的改动被埋进
     * 一片空白 diff 里，审查时看不出来。代价只是这一块的缩进比它该有的少两级。
     */
    Stack() {
    /* [A]
     * ⛔⛔ 右侧「非界面区底色」那次尝试已**整体回退**（2026-10-02）。两次都失败了，
     * 记在这里免得下次重走：
     *
     *   尝试 1：在 Navigation 【后面】加一层全屏底色 ⇒ 盖在界面上 ⇒ **UI 全部不见了**
     *   尝试 2：移到 Navigation 【前面】（正确的层序）+ 把 Navigation 底色改透明
     *           ⇒ UI 回来了，但**设置页的内容被推到屏幕右侧外并截断**
     *
     * ⚠️ 第二次的成因**没有查清**就回退了。可查的方向：
     *   · Navigation 底色改透明是否影响了 Tabs 的尺寸计算
     *   · Stack 里多一个 `position()` 的兄弟节点是否影响了 Navigation 的布局
     *   · 那层空的 `Column().width('100%').height('100%')` 是否是元凶
     *
     * ⭐ 结论：**这条是纯观感改动，不值得在用户的实机上盲试。** 要再做，先用一个
     *   最小页面（一个 Navigation + 一层底色）把层序和尺寸行为验证清楚，再动这里。
     *   ⚠️ 而且「分成两块」这个方向本身可能就与 `barOverlap(true)` 的悬浮底栏冲突 ——
     *   底栏居中在**整个窗口**宽度上，它必然横跨这两块的边界。
     */

    Navigation() {
      /* [A]
       * 两条分支只差悬浮样式那一块，理由见 canFloat 的注释。
       * ⚠️ 页签内容走 @Builder，所以这里没有重复第二份内容。
       */
      if (this.canFloat) {
        Tabs({ barPosition: BarPosition.End }) {
          TabContent() { this.GamesTab() }.tabBar(this.tabItem($r('sys.symbol.house_fill'), '首页'))
          TabContent() { this.SavesTab() }.tabBar(this.tabItem($r('sys.symbol.doc_text'), '存档'))
          TabContent() { this.SettingsTab() }.tabBar(this.tabItem($r('sys.symbol.gearshape_fill'), '设置'))
        }
        .barFloatingStyle({
          /* [A] 左右同一个留白 ⇒ 居中由构造保证。见 BAR_MAX_VP 的注释。 */
          barSideMargin: this.sideMargin(),
          /* [A] 把栏从屏幕下沿抬起来 —— 悬浮观感的另一半。 */
          barBottomMargin: BAR_BOTTOM_MARGIN_VP,
          systemMaterial: this.barMaterial,
          maskColor: Color.Transparent,
        })
        /* [A]
         * ⚠️⚠️ 这一行 = 「悬浮」本身，**不要改成 false**。
         *
         * 我改过一次，理由是「栏压住『启动游戏』」，结果用户报回来的第一句就是
         * 「底栏现在不悬浮，和左边融为一体了」—— 因为悬浮样式就是靠它生效的。
         *
         * 官方示例（SDK 文档）与参考项目 AMCL 都是 true，而且 AMCL 的注释明说
         * 「旧 API 仍覆盖在全屏内容上，不退回挤占 TabContent 高度的布局」。
         *
         * ⇒ 「栏压住按钮」的正解是**给内容留出底部空间**（BAR_CLEARANCE_VP），
         *   不是关掉重叠。关掉重叠 = 同时失去悬浮观感，代价比问题本身大。
         */
        .barOverlap(true)
        /* [A]
         * ⚠️ 这一行是「首页 / 设置 两页之间切换跳变」的修复，参考项目 AMCL 同款。
         *
         * SDK 文档说自定义 tabBar 不设时默认就是 300 —— 但实测是跳的。显式写上，
         * 与 AMCL 完全对齐（他们 `.animationDuration(300)` 就写在 `.barOverlap(true)`
         * 的下一行）。
         *
         * ⛔ 而**更关键的是上面那处改动**：Tabs 的 `index` 绑定已经去掉。
         * 原来写的是 `Tabs({ index: this.currentTab })`，而 `onAnimationStart` 里会回写
         * `this.currentTab` ⇒ **把值灌回 `index`** ⇒ 等于在动画中途重新请求一次切换，
         * 那一下就是「跳」。AMCL 用控制器，`currentTab` 只喂底栏高亮，两边互不干涉。
         *
         * ⚠️ 注意 `animationCurve` 不设时，滑动切换的时长由默认曲线
         * `interpolatingSpring(-1, 1, 228, 30)` 自己决定 —— 也就是说这一行对
         * 「点击页签」和「滑动」的作用方式不完全一样，别以为它是一个万能旋钮。
         */
        .animationDuration(300)
        .barBackgroundColor(Color.Transparent)
        /* [A]
         * ⚠️ 这里要的是 onAnimationStart，**不是 onChange** ——
         * 这一行就是「滑动换页时底栏高亮有延迟」的修复。
         *
         * onChange【在切换完成之后】才触发，所以手指滑动的那一整段时间里，高亮还停在
         * 旧页签上，看起来就是「慢半拍」（用户原话）。
         * onAnimationStart【在动画一开始】就给出 targetIndex，高亮跟着手势走。
         *
         * ⭐ 这不是我猜的：参考项目 AMCL 用的就是它 ——
         *     .onAnimationStart((_index, targetIndex) => { this.currentTab = targetIndex })
         *   而用户报的正是「AMCL 就没有」这个延迟。
         *
         * onChange 保留作兜底：如果动画被跳过（系统关了动效等），它仍会把值纠正回来。
         * 两者都写同一个字段、都是幂等的，不冲突。
         */
        .onAnimationStart((_index: number, targetIndex: number) => {
          this.currentTab = targetIndex;
        })
        .onChange((index: number) => { this.currentTab = index; })
        .width('100%')
        .height('100%')
      } else {
        /* [A]
         * 低于 API 26 的退路。没有悬浮材质，但**仍然重叠**（同上），
         * 用 `barBackgroundBlurStyle` 换个毛玻璃 —— 它从 API 7 就有。
         * 同一个做法见 AMCL 的 LauncherTabsStyle.ets。
         */
        Tabs({ barPosition: BarPosition.End }) {
          TabContent() { this.GamesTab() }.tabBar(this.tabItem($r('sys.symbol.house_fill'), '首页'))
          TabContent() { this.SavesTab() }.tabBar(this.tabItem($r('sys.symbol.doc_text'), '存档'))
          TabContent() { this.SettingsTab() }.tabBar(this.tabItem($r('sys.symbol.gearshape_fill'), '设置'))
        }
        .barOverlap(true)
        /* [A] 同上：显式给切换时长，与 AMCL 的写法对齐。 */
        .animationDuration(300)
        .barBackgroundBlurStyle(BlurStyle.COMPONENT_THICK)
        /* [A]
         * ⚠️ 这里要的是 onAnimationStart，**不是 onChange** ——
         * 这一行就是「滑动换页时底栏高亮有延迟」的修复。
         *
         * onChange【在切换完成之后】才触发，所以手指滑动的那一整段时间里，高亮还停在
         * 旧页签上，看起来就是「慢半拍」（用户原话）。
         * onAnimationStart【在动画一开始】就给出 targetIndex，高亮跟着手势走。
         *
         * ⭐ 这不是我猜的：参考项目 AMCL 用的就是它 ——
         *     .onAnimationStart((_index, targetIndex) => { this.currentTab = targetIndex })
         *   而用户报的正是「AMCL 就没有」这个延迟。
         *
         * onChange 保留作兜底：如果动画被跳过（系统关了动效等），它仍会把值纠正回来。
         * 两者都写同一个字段、都是幂等的，不冲突。
         */
        .onAnimationStart((_index: number, targetIndex: number) => {
          this.currentTab = targetIndex;
        })
        .onChange((index: number) => { this.currentTab = index; })
        .width('100%')
        .height('100%')
      }
    }
    .title('Mindustry Ark')
    .titleMode(NavigationTitleMode.Mini)
    /* [A]
     * ⚠️⚠️ 必须显式写 Stack，**不能靠默认的 Auto** —— 这一行同时是两个缺陷的根因。
     *
     * SDK 原文（`NavigationMode.Auto`）：
     *
     *     In API version 10 and later versions: If the window width is greater than or equal
     *     to 600 vp, the **Split** mode is used; otherwise, the Stack mode is used.
     *     600 vp = minNavBarWidth (240 vp) + minContentWidth (360 vp).
     *
     * 平板远超 600 vp ⇒ Auto 把 Navigation 切成 **Split** ⇒ **左边多出一个 240 vp 的
     * 导航栏**，而 Tabs（连同它的悬浮底栏）住在**右侧的内容区**里。
     *
     * 后果正是用户报的那两条：
     *   · 「底栏不居中」—— 它在内容区里居中，相对整屏就偏了。
     *     用户的描述非常准：「你应该是把底栏当成左边窗口的一个控件之类的了」。
     *   · 「界面太窄」—— 那 240 vp 白给了，内容区根本没占满。
     *
     * Stack 模式下导航页与内容区**互相独立、等价于两页**，本页因此拿到整个窗口宽度，
     * 底栏也就在【总窗口】的正中间。
     *
     * ⚠️ 本页没有任何 NavDestination，Split 的那个导航栏里本来就什么都没有 ——
     * 所以关掉它不损失任何东西。
     */
    .mode(NavigationMode.Stack)
    /* [A]
     * ⚠️ 必须关掉：Navigation 默认在左上角画一个返回箭头，而**这一页不在任何
     * NavPathStack 里**，所以它没有任何可返回的东西 —— 点它什么都不会发生。
     * 用户看到的就是「一个空按钮」。这不是缺陷，是默认值用错了地方。
     */
    .hideBackButton(true)
    .width('100%')
    .height('100%')
    /* [A] 唯一的任务是把窗口宽度学回来，好让底部栏能算出对称的左右留白。
     * 见 sideMargin()。 */
    .onAreaChange((_o: Area, n: Area) => {
      this.winW = Number(n.width);
    })
    .backgroundColor($r('app.color.launcher_bg'))

    /* [A]
     * 关于那个窗口。
     *
     * ⚠️ 它排在失败弹窗【前面】，所以失败弹窗会盖在它上面（Stack 里后面的在上层）。
     * 这是对的：失败弹窗是必须处理的，关于是可选的。
     *
     * ⚠️ 关闭按钮放在**右上角**，这是用户点名的位置。它必须真的存在 ——
     * 这个项目在别处踩过「门关上了却没有开的路径」，而一个只有内容没有出口的窗口
     * 就是同一类东西的界面版本。点遮罩也关（顺手），但出口以那个按钮为准。
     */
    /* [A]
     * 打开隔离时的询问 —— 用户 2026-10-02 定：「询问玩家，给出不同选择」。
     *
     * ⭐ 结构照抄「关于」那个窗口（同屏遮罩 + 卡片 + 点卡片不冒泡），理由也相同：
     * 里面的按钮是**要点的**，冒泡上去就会把窗口关掉。
     *
     * ⚠️ 三个选项的顺序是刻意的：**先讲后果，再说动作**，而「复制过去」排第一 ——
     * 它最安全（源数据不动 ⇒ 可逆），所以默认落在它身上。
     * ⛔ 「从空开始」绝不能高亮成默认 —— 那等于把「看不到存档了」做成默认选项。
     */
    if (this.showIsolationAsk) {
      Column() {
        Column() {
          /* [A] ⭐ 标题里直接点出**这一档叫什么**（用户 2026-10-02：
           * 「我们加上具体的版本粒度就行」）。
           * ⚠️ 原来只有「打开数据隔离」四个字，玩家看不出自己点的是哪一档 ——
           *    而那正是他下一步要确认的东西。 */
          Text('打开数据隔离  ·  ' + this.granularityName(this.pendingGranularity))
            .fontSize(18).fontColor($r('sys.color.font_primary'))
          /* ⛔⛔ 这一行**是用户留给他自己改的**（2026-10-02 他点名要自己动措辞）。
           * ⇒ 我**不动它**。之前有一轮我顺手改过一次，已还原 —— 那是他的句子。
           * ⚠️ 谁要改这句，先问他。 */
          Text('之后，当前选中的版本的数据与其他版本隔离。你想怎么处理存档？')
            .fontSize(13).fontColor($r('sys.color.font_secondary'))
            .width('100%').textAlign(TextAlign.Center)
            .margin({ top: 12 })

          /* [A] ⭐⭐ 把「当前选中的版本」**点名**。
           *
           * 用户 2026-10-02 原话：「点开后的弹窗，现在说的是'这个版本'。
           *                    我们加上具体的版本粒度就行」。
           *
           * ⚠️ 原来整句话里只有「当前选中的版本」「这个版本」这种**指代**，
           *    而玩家在那一屏上根本看不到自己选的是哪一个（它在「首页」页签里）。
           *    ⇒ 这里给出【版本名 + 版本号】，并把它**这一档下实际会用的目录**也写出来 ——
           *    那就是「具体到什么粒度」的答案。
           *
           * ⚠️ 目录名那一行**刻意**与上面那份总表用同一套键，两处不会分叉。
           */
          Text(this.pendingVersionName)
            .fontSize(14).fontColor($r('sys.color.font_primary'))
            .width('100%').textAlign(TextAlign.Center)
            .margin({ top: 10 })
          Text('这一档下，它用目录：' + (this.pendingKey === '' ? '（不隔离）' : this.pendingKey))
            .fontSize(12).fontColor($r('sys.color.font_secondary'))
            .width('100%').textAlign(TextAlign.Center)
            .margin({ top: 4 })

          /* ============================================================
           * [A] ⭐⭐ 「这一档到底怎么分」—— 用户 2026-10-02 点名要的。
           *
           * 原话：「切换的大版本，构建号，小版本时，弹窗**没说明是怎么分类的**，
           *       必须让人**选完了才知道是啥情况**」。
           *
           * ⛔ 为什么必须在这个窗里说：**这个窗是唯一能反悔的地方**。
           *    那句说明原来只在设置页、**选完之后**才显示 —— 顺序正好是反的。
           *    而且这里给的是**玩家自己的版本号算出来的目录名**，不是 `160.5` 这种编的例子：
           *    他要回答的是「我那两个 jar 会不会被分到一起」，只有他的版本号能回答。
           * ============================================================ */
          Divider().strokeWidth(1).color($r('app.color.launcher_border')).margin({ top: 14 })

          Text('这一档怎么分')
            .fontSize(12).fontColor($r('sys.color.font_tertiary'))
            .width('100%').textAlign(TextAlign.Center).margin({ top: 12 })
          Text(this.granularityHint(this.pendingGranularity))
            .fontSize(13).fontColor($r('sys.color.font_primary'))
            .width('100%').textAlign(TextAlign.Center).margin({ top: 4 })

          Text('你的版本会落到这些目录（在 instances/ 下面）')
            .fontSize(12).fontColor($r('sys.color.font_tertiary'))
            .width('100%').textAlign(TextAlign.Center).margin({ top: 12 })
          /* ⚠️ 只有这一块**左对齐** —— 它是一份「版本 -> 目录名」的对照表，
           * 居中的话 `→` 会参差不齐，反而读不出对应关系。
           * 其余说明文字一律居中，与用户 2026-10-02 说的「文字居中显示」一致。 */
          Text(this.pendingPreview)
            .fontSize(12).fontColor($r('sys.color.font_secondary'))
            .width('100%').textAlign(TextAlign.Start).margin({ top: 6 })
            .copyOption(CopyOptions.LocalDevice)

          /* [A] ⭐⭐ 这一句是**必须**的，而且它解释的正是最容易让人误判成故障的那个现象。
           *
           * ⛔ 当前玩的是内置游戏时，**任何档位算出来的键都是 `bundled`** ——
           *    玩家切来切去，目录名一个都不变 ⇒ 他会得出「这功能没生效/坏了」。
           *    而真实原因是**一条刻意的设计**：内置那份永不移动，
           *    这样我们换内置 jar 版本时，玩家数据不会跟着搬走。
           * ⭐ 不说这句，界面就在把一个设计决定**伪装成一个故障**。
           */
          if (this.pendingUsesBundled) {
            Text('⚠️ 内置游戏永远用固定的目录 bundled，与这一档无关 —— '
                 + '这样我们以后换内置的游戏版本时，你的数据不会跟着搬走。'
                 + '要让档位真正起作用，得先在「首页」导入并选中一个自己的 jar。')
              .fontSize(11).fontColor($r('sys.color.warning'))
              .width('100%').textAlign(TextAlign.Center).margin({ top: 10 })
          }

          /* [A] ⭐ 先摆出【现在有什么】，用真实数量 —— 让玩家在**选之前**就看到结果。 */
          Text('当前数据：' + describeCounts(this.isolationCounts))
            .fontSize(12).fontColor($r('sys.color.font_secondary'))
            .width('100%').textAlign(TextAlign.Center)
            .margin({ top: 12 })

          /* [A] 每一块的顺序是【说明在上、按钮在下】（用户 2026-10-02 要的对调）。
           *
           * ⚠️ 「复制过去」**不配任何说明** —— 用户原话：「很直观了，根本不需要任何说明」。
           *    ⛔ 不要在别处补一句解释回去，那正是被删掉的冗余。
           *
           * ⚠️ 「不复制」的说明**只有一句**：用户删掉了「这个版本会看到：…」（「正常人不需要」），
           *    并把剩下那句改成「相当于新建一个存档，原存档保留」。
           *
           * ⭐⭐ 用真 `Button` 而不是给 `Text` 上色：设置页那个「重新扫描」是裸 `Button()`，
           *    它的蓝色是**组件自带的默认主题色**。用它就自动与那一处一致，
           *    ⛔ 不需要（也不该）自己去写一个蓝值 —— 那样两处迟早会分叉。
           *    ⚠️ 宽度 `'50%'` 之后要 `alignSelf(ItemAlign.Center)`：父 Column 是
           *    `alignItems(HorizontalAlign.Start)`，光给宽度会让按钮贴左边。
           */

          /* ============ 选项一：主操作（系统蓝） ============ */
          Divider().strokeWidth(1).color($r('app.color.launcher_border')).margin({ top: 14 })
          Button('复制过去')
            .fontSize(15)
            .width('40%').alignSelf(ItemAlign.Center)
            .margin({ top: 14 })
            /* [A] ⭐ 两步：先记下意图，由下面那个二次确认来真正执行。
             * ⛔ 这里【不】直接调 applyIsolationCopy() —— 那会让二次确认变成摆设。 */
            .onClick(() => { this.isolationConfirm = 'copy'; })

          /* ============ 选项二 ============ */
          /* [A] ⛔ **这个选项【没有】说明文字** —— 用户 2026-10-02：
           *    「'不复制'的说明去掉吧，这个不用解释了。」
           * ⚠️ 而且它与上面那个「复制过去」是**对称**的：一个的动作就是「复制」，
           *    另一个就是「不复制」，两个词本身已经把结果说完了。
           * ⛔ 别再补「相当于新建一个存档」之类 —— 那是解释，不是信息。 */
          Divider().strokeWidth(1).color($r('app.color.launcher_border')).margin({ top: 14 })
          Button('不复制')
            .fontSize(15)
            .width('40%').alignSelf(ItemAlign.Center)
            .margin({ top: 10 })
            /* ⛔ 这里【曾经】写 `.backgroundColor(launcher_bg)` + `.fontColor(font_primary)`，
             * 想做成「灰底次级按钮」。**实测是黑的** ——
             * `launcher_bg` 在深色模式下是 #FF101010，而深色主题正是默认。
             * ⇒ 用户 2026-10-02：「现在颜色是黑色的。也改成蓝色吧」
             * ⭐ 于是三个按钮都不设底色，全部用 `Button` 的系统默认主题色 —— 一处颜色，
             *   不给自己造的色值留分叉的机会。 */
            .onClick(() => { this.isolationConfirm = 'empty'; })

          /* ============ 取消：也是蓝底，但更窄 ============ */
          Divider().strokeWidth(1).color($r('app.color.launcher_border')).margin({ top: 14 })
          Button('取消')
            .fontSize(14)
            .width('20%').alignSelf(ItemAlign.Center)
            .margin({ top: 12 })
            .onClick(() => {
              this.showIsolationAsk = false;
              this.pendingGranularity = '';
              this.isolationConfirm = '';
            })
        }
        .width('100%')
        .constraintSize({ maxWidth: this.dialogWidthVp() })
        .padding(20)
        .backgroundColor($r('app.color.launcher_card'))
        .borderRadius(CARD_RADIUS_VP)
        .alignItems(HorizontalAlign.Start)
        /* [B] 吞掉落在卡片上的点击，别让它冒泡到遮罩把窗口关掉 —— 与「关于」同一处理由。 */
        .onClick(() => {})
      }
      .width('100%').height('100%')
      .backgroundColor('#80000000')
      .justifyContent(FlexAlign.Center)
      .padding({ left: 32, right: 32 })
      /* ⚠️ 这里【不】让点遮罩等于取消：这个窗比「关于」重（它会改数据位置），
       * 而一个手滑点空白就消失的确认框，比没有确认框更糟。出口只有「取消」。 */
    }

    /* [A]
     * 二次确认。
     *
     * ⚠️ 它必须放在上面那个 `if` **之后** —— 在 Stack 里，后声明的孩子画在上面。
     *   反过来写的话，确认框会被主弹窗盖住，而症状是「点了按钮什么都没发生」。
     *
     * ⚠️ 两条出口都要把 `isolationConfirm` 清回 `''`，否则下一次打开隔离会直接
     *   弹在确认框上。
     */
    if (this.isolationConfirm !== '') {
      Column() {
        Column() {
          Text(this.isolationConfirm === 'copy'
               ? '复制到哪些分类' : '再确认一次')
            .fontSize(17).fontColor($r('sys.color.font_primary'))

          /* ============================================================
           * [A] ⭐⭐ 「复制过去」＝**自己挑复制进哪些分类**。
           *
           * 用户 2026-10-02：
           *   「复制改成多版本自行选择，**告知用户可以复制到哪些粒度下的分类里面**。
           *     现在这个有点反直觉。」
           *
           * ⛔ 原来是我替他全选（每个版本都补一份）—— 而它在界面上**看不见**：
           *    没有任何东西告诉玩家「刚才复制了几份」。⇒ 一个聪明但沉默的默认值，
           *    比一个看得见的选择差。
           *
           * ⭐ 每一行就是**这一档下的一个分类**（一个键），后面列出落进它的版本、
           *    以及它现在有没有数据 —— 那正是「勾了会发生什么」的答案。
           * ⚠️ 默认**全勾**（见 chooseGranularity）：最常见的意图就是「每个都别丢」，
           *    ⛔ 而默认一个不勾会让最常见的意图要点两次。
           * ============================================================ */
          if (this.isolationConfirm === 'copy') {
            Scroll() {
              Column() {
                ForEach(this.copyTargets, (c: CopyTarget) => {
                  Row() {
                    Column() {
                      Text(this.copyTargetTitle(c))
                        .fontSize(14)
                        .fontColor(this.isCopyPicked(c.key)
                                   ? $r('sys.color.font_primary') : $r('sys.color.font_secondary'))
                        .width('100%')
                        .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                      Text(this.copyTargetSub(c))
                        .fontSize(12).fontColor($r('sys.color.font_tertiary'))
                        .width('100%').margin({ top: 4 })
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)

                    if (this.isCopyPicked(c.key)) {
                      Text('✓').fontSize(16).fontColor($r('sys.color.brand'))
                    }
                  }
                  .width('100%')
                  .padding(12)
                  .borderRadius(CARD_RADIUS_VP)
                  .backgroundColor($r('app.color.launcher_bg'))
                  .margin({ top: 8 })
                  .onClick(() => { this.toggleCopyPick(c.key); })
                }, (c: CopyTarget) => c.key)

                if (this.copyTargets.length === 0) {
                  Text('这一档下没有可复制的分类。')
                    .fontSize(12).fontColor($r('sys.color.font_tertiary'))
                    .width('100%').margin({ top: 8 })
                }
              }
              .width('100%')
            }
            .width('100%')
            .constraintSize({ maxHeight: 300 })
            .align(Alignment.TopStart)
            .margin({ top: 12 })
          } else {
            Text('这个版本会是空的，相当于新建一个存档。')
              .fontSize(13).fontColor($r('sys.color.font_secondary'))
              .margin({ top: 10 })
          }

          Row() {
            Button(this.isolationConfirm === 'copy' ? '复制' : '确定')
              .fontSize(15)
              .layoutWeight(1)
              .enabled(this.isolationConfirm !== 'copy' || this.copyPicked.length > 0)
              .onClick(() => {
                const what: string = this.isolationConfirm;
                this.isolationConfirm = '';
                if (what === 'copy') {
                  this.applyIsolationCopy();
                } else {
                  this.applyIsolationEmpty();
                }
              })
            Button('取消')
              .fontSize(14)
              .layoutWeight(1)
              .margin({ left: 12 })
              .onClick(() => { this.isolationConfirm = ''; })
          }
          .width('100%')
          .margin({ top: 16 })
        }
        .width('100%')
        .constraintSize({ maxWidth: this.dialogWidthVp() })
        .padding(20)
        .backgroundColor($r('app.color.launcher_card'))
        .borderRadius(CARD_RADIUS_VP)
        .alignItems(HorizontalAlign.Start)
        .onClick(() => {})
      }
      .width('100%').height('100%')
      .backgroundColor('#80000000')
      .justifyContent(FlexAlign.Center)
      .padding({ left: 32, right: 32 })
    }

    if (this.showAbout) {
      Column() {
        Column() {
          /* [B] 标题行：左边标题，右边 ✕。用 Row 是为了让 ✕ 真的在右上角，
           * 而不是靠 margin 把它推到看起来像角落的地方。 */
          Row() {
            Text('关于')
              .fontSize(18).fontColor($r('sys.color.font_primary'))
              .layoutWeight(1)
            Text('✕')
              .fontSize(18).fontColor($r('sys.color.font_secondary'))
              .padding({ left: 14, right: 4, top: 2, bottom: 2 })
              .onClick(() => { this.showAbout = false; })
          }
          .width('100%')

          Text('Mindustry Ark' + (this.appVersion === '' ? '' : ('  ' + this.appVersion)))
            .fontSize(14).fontColor($r('sys.color.font_secondary'))
            .margin({ top: 14 })
          Text('在 HarmonyOS / OpenHarmony 上运行 Mindustry')
            .fontSize(13).fontColor($r('sys.color.font_secondary'))
            .margin({ top: 8 })
          Text('以 GPL-3.0 分发。')
            .fontSize(13).fontColor($r('sys.color.font_secondary'))
            .margin({ top: 4 })

          /* ⚠️ 上游与本仓库是两个地址，别合并：本应用是上游的 fork，而「报问题」应当去
           * 它自己那个仓库。两个都列是因为它们回答的是不同的问题。 */
            .fontSize(12).fontColor($r('sys.color.font_tertiary'))
            .margin({ top: 16 })
          Text('https://github.com/haohandc/MindustryArk')
            .fontSize(12).fontColor($r('sys.color.brand'))
            .margin({ top: 2 }).copyOption(CopyOptions.LocalDevice)
          Text('本仓库')
            .fontSize(12).fontColor($r('sys.color.font_tertiary'))
            .margin({ top: 10 })
          Text('https://github.com/haohandc/MindustryArk')
            .fontSize(12).fontColor($r('sys.color.brand'))
            .margin({ top: 2 }).copyOption(CopyOptions.LocalDevice)
          Text('问题反馈')
            .fontSize(12).fontColor($r('sys.color.font_tertiary'))
            .margin({ top: 10 })
          Text('https://github.com/haohandc/MindustryArk/issues')
            .fontSize(12).fontColor($r('sys.color.brand'))
            .margin({ top: 2 }).copyOption(CopyOptions.LocalDevice)

          Text('非官方项目。与 Mindustry 及其作者 Anuken 无隶属关系，未获其认可或支持。以 GPL-3.0 分发。')
            .fontSize(12).fontColor($r('sys.color.font_tertiary'))
            .margin({ top: 16 })
        }
        .width('100%')
        .constraintSize({ maxWidth: this.dialogWidthVp() })
        .padding(20)
        .backgroundColor($r('app.color.launcher_card'))
        .borderRadius(CARD_RADIUS_VP)
        .alignItems(HorizontalAlign.Start)
        /* [A] 吞掉落在卡片上的点击，不让它冒泡到下面那层遮罩。
         *
         * ⚠️ 没有这一句，点卡片里的任意一行文字都会把窗口关掉 —— 而那里面有几条**要抄走
         * 的网址**（它们带 copyOption），正好是最需要点一下的地方。
         *
         * ⚠️ 空处理器是有意的：这里不需要做任何事，只需要**接管**这一次手势。
         * ArkUI 的手势竞争是子优先，所以这一句就足以让点卡片不再等于点遮罩。 */
        .onClick(() => {})
      }
      .width('100%').height('100%')
      .backgroundColor('#80000000')
      .justifyContent(FlexAlign.Center)
      .padding({ left: 32, right: 32 })
      /* [B] 点卡片【外面】的空白处也关。与右上角那个 ✕ 并存 —— 两个都是出口，
       * 而出口多一点，比少一点安全。 */
      .onClick(() => { this.showAbout = false; })
    }

    /* [A] 复制/移动的目标选择。同上：只读的窗可以盖在别的东西上，启动失败不能。 */
    if (this.transferOp !== '') {
      this.TransferDialog()
    }

    /* [A] 删除确认。⚠️ 排在「上次没能启动成功」**前面** —— Stack 里后声明的在上层，
     * 而启动失败是必须处理的，不能被一个可选的确认框盖住。 */
    if (this.showDeleteAsk) {
      this.DeleteAskDialog()
    }

    /* [A] 多选删除的确认框。⭐ 排在单删那个**后面**（同层的话后声明的在上）——
     * 两者不可能同时出现（多选态下单条动作行整个藏了），所以顺序只是防御性的。 */
    if (this.showMultiAsk) {
      this.MultiDeleteAskDialog()
    }

    if (this.launchFault !== '' && !this.faultAck) {
      /* [A] 外面这层是【同屏遮罩】，里面那层是【盒子】—— 与「关于」那个窗口结构一致。
       * 两层各拿各的修饰符，**不要合成一层**：合成之后背景色、对齐、内边距会互相覆盖，
       * 而那种错误只在视觉上体现，编译期看不出来。 */
      Column() {
        Column() {
          Text('上次没能启动成功')
            .fontSize(20).fontColor($r('sys.color.font_primary'))
          /* [A]
           * 内容在【可滚动】的一块里，而不是一个裸 Text。
           *
           * ⚠️ 这一块的末尾是启动器自己的日志（最多 1.2 KB），行数不定。裸 Text 会让
           * 弹窗随着日志变长而撑高，最后把下面那两个按钮顶出屏幕 —— 而按钮正是这个弹窗
           * 存在的理由（它是逃生门）。给一个上限，让文字自己滚。
           *
           * ⚠️ 它【不】截断日志：截断了就等于把原因藏起来，而原因正是玩家要看的东西。
           */
          Scroll() {
            Text(this.launchFault)
              .fontSize(12).fontColor($r('sys.color.font_secondary'))
              .width('100%')
              .textAlign(TextAlign.Start)
          }
          .width('100%')
          .constraintSize({ maxHeight: FAULT_BOX_VP })
          .align(Alignment.TopStart)
          .margin({ top: 12 })

          /* [A] 逃生门必须写明它绕开的是什么，否则玩家不知道按了会发生什么。 */
          Text('若你确认设备本可以运行游戏，可以用「仍然尝试启动」绕开这次判定。')
            .fontSize(12).fontColor($r('sys.color.font_tertiary'))
            .margin({ top: 10 })

          /* [A]
           * 按钮**并排**，各占一半。
           *
           * ⚠️ 两个都用 `layoutWeight(1)` —— 在 Row 里它让子项**平分**可用宽度，所以两者
           *   **宽度严格相等**，而且一起铺满弹窗。用户报过「知道了这个按钮有点窄」，
           *   那正是因为按内容收缩时短标签必然更窄；`layoutWeight(1)` 让「一样宽」由
           *   **结构**保证，不需要给 `minWidth` 填一个拍脑袋的数。
           *
           * ⚠️ 顺序：次要的（灰）在左，主推的（主题色）在右 —— 各类对话框的通行次序。
           *
           * ⚠️ ⛔ **不要**因为「看着不建议」就把「仍然尝试启动」禁用掉：灰底只是视觉上的
           *   次要，而它整个存在的意义就是在判定失误时留一条出路。禁用它等于把逃生门
           *   拆了装成一个门把手。
           */
          Row({ space: 12 }) {
            Button('仍然尝试启动')
              .fontSize(BUTTON_FONT_VP).height(44)
              .layoutWeight(1)
              .fontColor(SECONDARY_FG)
              .backgroundColor(SECONDARY_BG)
              .onClick(() => {
                this.faultAck = true;
                this.onForceLaunch();
              })
            Button('知道了')
              .fontSize(BUTTON_FONT_VP).height(44)
              .layoutWeight(1)
              .onClick(() => { this.faultAck = true; })
          }
          .width('100%')
          .margin({ top: 18 })
        }
        /* [A] 盒子的修饰符。⚠️ `constraintSize` 是【上限】，而宽度给 100% 是为了窄屏
         * （手机）上占满可用宽度 —— 两者分工不同，缺了上限就是用户报的「太宽了」。 */
        .width('100%')
        .constraintSize({ maxWidth: this.dialogWidthVp() })
        .padding(20)
        .backgroundColor('#F01C1C1C')
        .borderRadius(CARD_RADIUS_VP)
        .alignItems(HorizontalAlign.Start)
      }
      /* [B] 遮罩的修饰符。盒子之外再留一层，窄屏上也不至于贴边。 */
      .width('100%').height('100%')
      .backgroundColor('#B0000000')
      .justifyContent(FlexAlign.Center)
      .padding({ left: 32, right: 32 })
    }
    }
  }
}
