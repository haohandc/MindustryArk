/* 启动器主界面 —— 没有游戏可加载时、或玩家主动要求时显示的那一屏。
 * ⚠️ 它替换 XComponent（不是盖在上面）⇒ 无 Surface，可获焦组件安全；若改成盖在游戏上，`focusable(false)` 规则立刻生效（症状：键盘废掉，无声）。
 * 布局 Navigation + 底部页签是被 API 推出来的：沉浸光感只在 Navigation/NavDestination 标题栏或横向 Tabs(BarPosition.End) 生效 ⇒ 顺带否掉平板侧边竖向页签。
 * 颜色两套：文字 $r('sys.color.*')（colorInvert 只对特殊资源值生效，硬编码色不反色）；表面色 $r('app.color.launcher_*')（base/dark 两处定义）。
 * 三条坑：① 浮底栏靠 `barOverlap(true)`，防「栏压按钮」要给内容留底部空间而非关重叠；
 * ② `@Builder` 参数按值传递 ⇒ 带 `chosen` 的列表项点击后 ✓ 不刷新，列表项必须内联；
 * ③ 漏改 import 调用点会让整个文件语法分析失败（真错在错误列表最后一条），而 `build.log`
 * 是追加的、混着历次错误 ⇒ 只信命令当场打印的那几行。 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { SymbolGlyphModifier } from '@kit.ArkUI';
/* 底部页签换成设计系统组件 HdsTabs（2026-10-03，用户指定）。与裸 Tabs 的关键差别见 build() 里那段。 */
import { HdsTabs, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit';
import { bundleManager, common, ConfigurationConstant } from '@kit.AbilityKit';
/* 应用自己的显示名 —— 与游戏里那个 About 卡片同一处规则。 */
import { appLabel } from '../utils/AppLabel';
import { newTreeStat, copyTreeInto, removeTree, TreeStat, isDir, pathExists } from '../utils/FsTree';
import { externalRootPath, STORAGE_MODE_SANDBOX, STORAGE_MODE_EXTERNAL,
         readStorageMode, writeStorageMode, gameDataRoot, gameDataRootFor, ensureGameDataRoot,
         probeExternalRoot, usedUserHome, usedUserHomeReason,
         dumpStorageState } from '../settings/StorageRoot';
import { fileIo as fs } from '@kit.CoreFileKit';
import { picker } from '@kit.CoreFileKit';
import { fileUri } from '@kit.CoreFileKit';
import {
  packDataDir, ensureDir, readUriToFile, copyLocalFile, stampNow,
  unpackZip, locateDataRoot, validatePack, packableItems, countPackable,
} from '../games/DataPack';
import { GameJar, GameResolution, listGameJars, readSelection, writeSelection,
         resolveGame, gameJarDir, ensureGameJarDir,
         bundledGameVersion, hasBundledGame, bundledGamePath,
         gameVersionParts } from '../games/GameLibrary';
/* 界面偏好（启动后进哪里）。⛔ 内容宽度**不再**在这里 —— 见 gamesWidthVp。 */
import { readLaunchMode, writeLaunchMode,
         LAUNCH_MODE_HOME, LAUNCH_MODE_GAME,
         AppearancePref, readAppearance, writeAppearance,
         SafePref, readSafePref, writeSafePref, SAFE_VP_MAX, SAFE_VP_STEP,
         readGameLocaleFollow, writeGameLocaleFollow,
         GameDisplayPref, readGameDisplay, writeGameDisplay, readAppliedGameDisplay,
         GAME_EDGE_MIN, GAME_EDGE_MAX, GAME_SCALE_MIN, GAME_SCALE_MAX, GAME_SCALE_STEP,
         GAME_EDGE_FACTORY, GAME_SCALE_FACTORY } from '../settings/LauncherPrefs';
/* ⭐ 实验性：由系统参数（挖孔 + 密度）算游戏该用的避让值。 */
import { displayDensity, autoEdgePadding } from '../games/GameAutoFit';
/* ⭐ 写游戏自己的 settings.bin（异形屏避让 / UI 缩放）。格式与判据见那个文件。 */
import { applyGameDisplay } from '../games/GameSettings';
/* ⭐ 「设备语言 → 游戏认得的那个值」的翻译（值必须是游戏认的，见那个文件）。 */
/* 异形屏探测（挖孔 / 刘海）。⛔ 游戏画面不归它管，只用于启动器自己的界面。 */
import { SafeInsets, detectInsets, uniformOf, edgesOf, dumpSafeArea } from '../utils/SafeArea';
/* 入场动画（退场刻意不做 —— 见那个文件的开头）。 */
import { enterFade, enterPop } from '../utils/Motion';
/* ⚠️ 临时：帧率探针。排查完连同这一行一起删。 */
/* 版本隔离：四档粒度、键的计算、以及打开时的那次复制。
 * ⛔ 实际的 `-Duser.home=` 在 native 侧 —— 这里只负责【决定】并把结论写进桥。 */
/* 存档：一个存档 = 一个星球的一组 msav（或一个手动存档）。 */
import { SaveEntry, listSaves, formatSaveSize, formatSaveDate,
         SaveMeta, readSaveMeta, newestFileOf } from '../games/SaveLibrary';
/* 存档垃圾站：删除不是抹掉，是搬到游戏看不见的地方。 */
import { VaultEntry, vaultDelete, listVault, vaultRestore, vaultPurge,
         vaultSetArchived, purgeExpired, describeExpiry, formatMs,
         readVaultDays, writeVaultDays, VAULT_DAYS_CHOICES } from '../games/SaveVault';
/* 复制 / 移动。⚠️ 同版本复制只对手动存档开放。 */
import { copySaveTo, moveSaveTo, duplicateSave, countSavesIn } from '../games/SaveTransfer';
import { GRANULARITY_OFF, GRANULARITY_NUMBER, GRANULARITY_BUILD, GRANULARITY_PATCH,
         readGranularity, writeGranularity,
         copyLiveDataInto, gameDataExists, liveGameDataDir, isolatedGameDataDir,
         GameDataCounts, countsOf, describeCounts,
         resolveGameDataDir, resolveGameDirAndKey, GameDirForKey,
         listInstanceKeys, granularityKey, KEY_UNKNOWN,
         setGameDataRoot, migrateGameData, dumpDataDirs,
         hasUserMadeFiles, settingsLocaleIn,
         writeIsolationBridge } from '../settings/Isolation';

const DOMAIN = 0x0000;
const TAG = 'MindustryLauncher';

/* 「查看存档数据」弹窗里的一行：左标签、右值。
 * ⚠️ 分两段而非一整条字符串：值里会长成 `[a, b, c]` 那样带逗号的东西。 */
interface MetaRow {
  label: string;
  value: string;
}

/* 「在同一个版本里再存一份」在目标列表里的**伪路径**：不能拿 `VersionEntry.path` 当它，
 * 拼一个不与真实路径（都是 `/` 开头的绝对路径）相撞的串。 */
const DUP_KEY: string = '#dup-same-version';

/* ⚠️ 换行用 `String.fromCharCode(10)` 拼：写文件的工具会把源码里的转义序列写成真实换行 ⇒
 * 「Unterminated string literal」，而那一行看起来是对的。同一族坑见 `SaveLibrary.ets`。
 * ⛔ 别改成直接打字面量 —— 任何一次脚本改这个文件都会再弄坏它。 */
const NL: string = String.fromCharCode(10);

/* 「按存档」列表里的一行 —— 必须带上它在哪个目录。
 * 隔离开启后每个版本各有 `saves/`，存档可同名（`0.msav`、`sector-serpulo-142.msav`），
 * 只用 `SaveEntry.id` 当身份会撞车（两个版本的 `manual:0` 同 id）⇒ 身份 = 目录 + id，
 * 每个动作（删除/复制/移动/看数据）必须按它自己那个目录做，⛔ 不能用「当前版本目录」代替。 */
interface SaveRow {
  /** 这个存档所在的 `saves/` 目录。 */
  dir: string;
  entry: SaveEntry;
}

/* 一组**共用同一份数据**的版本，以及那份数据里的存档。
 * ⚠️ 按**目录**分组而非按版本：隔离关着时所有版本共用一份数据，按版本分会让同一批存档
 * 出现 N 遍；按目录分恰好得到一组，组头的版本名单正好回答「属于哪几个版本」。 */
/* 一个「共用同一份数据」的组：`key` 是那个目录的键，`versions` 是读它的版本名。
 * ⭐ 「哪几个版本共用存档」这个问题，答案就是它。见 `isolationGroups()`。 */
interface IsoGroup {
  key: string;
  versions: string[];
}

interface SaveGroup {
  /** 数据目录（`…/<版本>/sets/default/.local/share/Mindustry/saves`）。 */
  dir: string;
  /** 读这个目录的版本，顺序与 `versions` 一致。空数组 = 没有版本读它。 */
  versions: VersionEntry[];
  /** 这个目录里的存档。 */
  saves: SaveEntry[];
  /* `versions` 为空时这个目录是哪种「没人读」：`''` = 未隔离那份（本就不属于任何版本）；
   * 非空 = 以前某一档隔离留下的键（`b160.5` 这种）。后者正是玩家会问「我的数据呢」的那一种。 */
  orphanKey: string;
}

/* 隔离切换时「复制过去」可复制进的**分类** —— 这一档下的每一个键。
 * ⛔ 原来替他全选（每个版本都补一份），那不是「复制过去」的直觉含义，而且看不见
 * （列表里没东西告诉你刚才复制了几份）⇒ 摆出来让玩家勾：看得见的选择比聪明的默认值可靠。 */
interface CopyTarget {
  /** 隔离键 —— 这一档下的一个「分类」。 */
  key: string;
  /** 落进这个分类的版本。 */
  versions: VersionEntry[];
  /** 这个分类已经有数据吗。⚠️ 有的话勾了也不会覆盖（见 applyIsolationCopy）。 */
  hasData: boolean;
}

/** 存档页的两种视图。 */
const SAVES_VIEW_SAVE: string = 'save';
const SAVES_VIEW_VERSION: string = 'version';

/* 「按版本」视图里的一项 —— 一个**可启动的游戏版本**。
 * ⛔ 「版本」不是「版本号」：两个 jar 可以是同一个版本号 ⇒ 标识必须是 jar 路径，
 * 不能是版本号（否则同号的两个 jar 会互相顶掉，列表里只剩一个）。
 * ⚠️ 也别拿 `GameJar.version` 当身份 —— 它是显示串（`v8 Build 160.5`），读不出时是空串。 */
/* 一次「导入到多处」的汇总。⚠️ 单独一个类型而不是一串局部变量：它要在
 * `importIntoOne`（每个目标一次）与 `confirmImport`（收尾）之间传来传去。 */
interface ImportOutcome {
  /** 成功落盘的目标数。 */
  done: number;
  /** 备份了几份（只数成功的）。 */
  backups: number;
  /** 有没有备份被迫落在应用沙箱里（外面拿不到）—— 那样的话「备份」这句话要加警告。 */
  anyBackupInSandbox: boolean;
  dirs: number;
  files: number;
  /** 每个失败目标一句人话（带它自己的名字）。 */
  fails: string[];
}

function newImportOutcome(): ImportOutcome {
  return { done: 0, backups: 0, anyBackupInSandbox: false, dirs: 0, files: 0, fails: [] };
}

interface VersionEntry {
  /** jar 的绝对路径。**同时是这一项的稳定标识**。 */
  path: string;
  /** `'user'` 或 `'bundled'`。 */
  source: string;
  /** 给玩家看的名字（内置那份是「内置游戏」，其余是文件名）。 */
  label: string;
  /** 版本显示串，如 `v8 Build 160.5`；读不出时是空串。 */
  version: string;
  /** 隔离键；`''` 表示不隔离 —— 那意味着它和**所有**别的版本共用一份数据。 */
  key: string;
  /** 这个版本启动时游戏会去读的数据目录。 */
  dataDir: string;
  /** 是不是当前选中的那个版本。 */
  isCurrent: boolean;
  /** 该目录下的存档个数（只数文件名，不解压）。 */
  saveCount: number;
  /** 该目录**存在**吗。与「有几个存档」是两件事：不复制地打开隔离就是一个空目录。 */
  hasData: boolean;
}

/** Unix 毫秒 -> `YYYY-MM-DD HH:MM`。存档里的 `saved` 是毫秒，而列表用的 `mtime` 是秒。 */
function formatMsDateTime(ms: number): string {
  const d: Date = new Date(ms);
  const p = (n: number): string => n < 10 ? '0' + String(n) : String(n);
  return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate())
       + ' ' + p(d.getHours()) + ':' + p(d.getMinutes());
}

/* 游戏内时长：毫秒 → 给人看的一句话。
 * ⛔⛔ 单位是**毫秒**（原按 60 tick/秒 换算，分钟数被放大 16.67 倍）。证据：游戏
 * `Saves.update()` 用 `Time.timeSinceMillis` 累加、`Strings.formatMillis` 用 3_600_000；
 * 实测 `sector-serpulo-142.msav` 36_202_317 按毫秒是 10.1 小时，按 tick 是 167 小时（不可能）。
 * 分档：<1 分钟「不足 1 分钟」，<60「约 N 分钟」，≥60「约 H 小时 M 分钟」（M 为 0 也照写）。一律 floor。 */
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

/* 把 native 读出来的元数据排成给玩家看的几行。三条口径：
 * ① 空值不显示（手动存档无 `sectorPreset`，硬塞一行只是噪音）；
 * ② 「读取自」排第一 —— 一个 Serpulo 战役有 14 个 `.msav` 而只读最新那个，「其他区块可能不同」必须看得见；
 * ③ `build` 是「写这个存档时的游戏构建号」，⛔ 不是「哪些版本能读它」（那要拿模组清单和版本规则算）。 */
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
    /* ⛔ 单位是**毫秒**，证据见 `formatPlaytime`。 */
    add('游戏内时长', formatPlaytime(Number(m.playtime)));
  }
  add('模组', m.mods);
  return rows;
}

/** 内容占窗口宽度的**百分比下限**（vp）。手机窗口只有 360–420 vp，30% 会得到一百多 vp 的窄条。
 * ⛔ 原来写「`max(360, 百分比)` 让手机退回全宽」，做不到：360 是常量，窗口 420 时内容停在
 * 360、右边空 60vp 且外层靠左 ⇒ 一条窄栏贴在左边（实测症状：首页在手机比例下列表不居中）。
 * ⇒ **全宽只能用窗口宽度表达**；窄屏那条提前返回 `winW`（见 `gamesWidthVp()`），这里只剩首帧与宽屏下限。 */
const CONTENT_MIN_VP = 360;

/** 首页的内容宽度：**固定 30%**，在最左边（像 AMCL / Mindustry 桌面 UI，不是居中）。
 * ⚠️ 中间加过一条 20–60 的滑条，2026-10-02 收回。
 * ⛔ 存档与设置**不用**这个值 —— 它们直接写 `'100%'`，铺满，连窗口宽度都不必量。 */
const GAMES_WIDTH_PCT = 30;

/** 窄屏（手机）阈值，vp：低于它就把存档页详情改成**子页**而非右栏。理由见 `isNarrow()`。
 * ⚠️ 600 与 AMCL 断点一致（他们 `viewportWidth >= 600` 才走双栏）。 */
const NARROW_VP = 600;

/** 底部悬浮栏的**目标宽度**上限。
 * ⛔ 不用 `barWidth`：它是三档 `FloatingTabBarWidth`，档位由 SDK 自己的断点决定 ⇒
 * 实测给了三档宽度仍报「悬浮了，但不居中」。
 * ⭐ 用 `barSideMargin`：左右同一个值 ⇒ 栏必然居中（由构造保证）。代价是不能用百分比。 */
const BAR_MAX_VP = 480;

/** 左右留白的下限，窄屏上不至于把栏挤没。 */
const BAR_MIN_SIDE_VP = 16;

/** 栏离底边多高 —— **「悬浮」的一半**：没有它栏贴屏幕下沿，就是一条普通底栏。
 * AMCL 用 `Math.max(bottomSafeHeight, 16) + 8`；这里不读安全区，取够用的常量
 * （平板上手势条那一条通常不到 16 vp）。 */
const BAR_BOTTOM_MARGIN_VP = 24;

/** 为悬浮栏让出的底部空间。⚠️ 是估算：栏内容 52（TabItem 的 height）+ 离底 24 + 余量 20。
 * 多给只是底部空一点，少给才会压住按钮 ⇒ 取偏大值。 */
const BAR_CLEARANCE_VP = 96;

/* 滑条展开后的高度（vp）= 滑条自身 40 + 它与上面那行的 6 间距。
 * ⚠️ 必须有这个数：高度动画要在 0 和它之间插值，而「内容多高」要到布局期才算得出来。 */
const SAFE_REVEAL_VP = 46;

/** 圆角。卡片和列表项共用，免得两处漂移。 */
/** 导入对话框里「未隔离的那一份」的伪路径（它不是真版本，但复用同一套渲染）。 */
const LIVE_TARGET_PATH: string = '__live__';

/** 提示条自动收掉的时间（ms）。用户 2026-10-03 要求 3~5 秒。 */
const NOTICE_MS: number = 4000;

const CARD_RADIUS_VP = 14;

/* ⭐⭐ **弹窗里那些「独占一行的按钮」不写宽度** —— 让它按**标签自身**的宽度排，
 *    只加一条 `constraintSize({ maxWidth: '100%' })` 兜住「标签比弹窗还宽」的极端情况。
 *    ⛔ 别给它们写 `.width('72%')` 之类的百分比。
 *
 * ⛔⛔ 这里原来是一个 `const CANCEL_BTN_WIDTH = '34%'`，五个确认窗共用。
 *    它治好过一次病（2026-10-04：原本 25%，「取消」两字装不下、显示成 **「...」**），
 *    **但药方是错的** —— 这些按钮**每一个都独占一行**（不是并排挤在 `Row` 里），
 *    对独占一行的东西写百分比，等于同时制造两个毛病：
 *      · **长的被压**：`放进垃圾站（保留到 2026-10-09）` 约 232vp，塞进 72% × 280 = 202vp
 *        ⇒ 折成两行、按钮变高（用户 2026-10-04 说的「按钮比文字提示还大」就是它）
 *      · **短的被拉**：「取消」两个字占 95vp 宽，看着比它旁边的正文还重
 *    ⇒ 改成**按内容**。⭐ 关键是它把问题**从结构上消掉**了：不再是「宽度写得够不够」，
 *    而是**根本没有宽度可以写错** —— 当初那句「一个『今天刚好放得下』的宽度，就是明天
 *    会坏掉的宽度」在这里终于有了正确答案。
 *
 * ⚠️ **并排的按钮不适用**：`TransferDialog` 底下那两个（确定 / 取消）是真的挤在一个 `Row` 里，
 *    那里继续用 `layoutWeight(1)` —— 那是对的，⛔ 别一起改。 */

/** 按钮字号。**显式给**，因为不给会按各自标签长度自适应，两个按钮的字不一样大。 */
const BUTTON_FONT_VP = 16;

/* 「按版本」那一屏存档行的三列宽度（vp）：文件名占剩下的全部，大小与时间**各占一列、右对齐**。
 * ⚠️ 宽度必须写死（`Text` 默认按内容自适应 ⇒ 列会歪），写死是安全的，因为两个格式**定长**：
 * 大小 ≤ 7 个字符（`1.2 MB`），时间恒为 10 个字符（`2026-10-02`）。
 *
 * ⭐⭐ **但「宽度写死」只在字号也写死时才成立。** 这一条是 2026-10-04 才补上的：
 * 原来那句理由默认了「字不会变大」，而 ArkUI 里 `fontSize(12)` 的单位是 **fp**（SDK 原文：
 * 「If fontSize is of the number type, the unit fp is used」）⇒ **它跟着系统字体缩放**。
 * 系统字体一调大，10 个字符的日期就会撑出 92vp，列宽写死反而变成裁切。
 *
 * ⇒ ⭐ **判据（全文件通用）**：
 *    · **标签 / 说明文字**（跟着读的字）—— 用数字（fp），**让用户按自己的需要放大**；
 *    · **装在定宽盒子里的数据**（大小、日期、勾）—— 用 `'12vp'` 这样的字符串，
 *      **不跟系统字体缩放**，否则那个盒子装不下它。
 * ⛔ 别反过来：给标签写 vp 会让看不清的用户没有出路；给数据列写 fp 会让列宽失效。
 * 手机窄屏上文件名只剩一百多 vp，靠 `TextOverflow.Ellipsis` 收尾 —— 比三列错开代价小。 */
const SAVE_SIZE_COL_VP = 74;
const SAVE_DATE_COL_VP = 92;
/** 选中那个 ✓ 也占定宽，否则「选中」会把后面几列推歪。 */
const SAVE_TICK_COL_VP = 16;

/* 失败弹窗里那块文字的高度上限（vp）。
 * ⚠️ 有上限是【必须】的：末尾是启动器自己的日志、长度不定，而下面那两个按钮
 * （「仍然尝试启动」/「知道了」）才是弹窗存在的理由 —— 日志把按钮顶出屏幕等于关掉逃生门。 */
const FAULT_BOX_VP = 240;

/* 弹窗宽度 = **窗口宽度的这一半**，窄屏上不低于下面的下限。
 * ⚠️ 原来写死 420 vp 封顶 ⇒ 2026-10-01 报「有点小了，矫枉过正，铺满屏幕的 50% 差不多」。
 * 用比例而非绝对数：平板和手机各自得到合适的宽度，不必为每种设备配一个数。
 * ⚠️ 下限必要：手机 50% 只有约 190 vp，连一行地址都放不下；有了下限窄屏自动接近满宽。 */
const DIALOG_WIDTH_FRACTION = 0.5;
const DIALOG_MIN_VP = 320;

/* 「仍然尝试启动」的底色与文字色：它是个**次要**动作，要看着不起眼（2026-10-01 要灰底）。
 * ⚠️ 但它**必须仍然可点** —— 灰底只是「不建议」不是「禁用」，它是判定失误时唯一的出路。
 * 用半透明的白而非固定灰：弹窗底是硬编码的深色（`#F01C1C1C`），半透明灰在那上面读得出。 */
const SECONDARY_BG = '#2EFFFFFF';
const SECONDARY_FG = '#B0FFFFFF';

/** 人类可读的大小。就是给人看的，所以用 MB/KB 而不是字节。 */
function formatSize(bytes: number): string {
  if (bytes >= 1048576) {
    return (bytes / 1048576).toFixed(1) + ' MB';
  }
  if (bytes >= 1024) {
    return (bytes / 1024).toFixed(0) + ' KB';
  }
  return String(bytes) + ' B';
}

/** 只要日期。玩家分辨两个游戏版本靠文件名，日期只是辅助。 */
function formatDate(sec: number): string {
  const d: Date = new Date(sec * 1000);
  const p = (n: number): string => n < 10 ? '0' + String(n) : String(n);
  return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate());
}

@Component
export struct LauncherHome {
  /* 两个都由 Index.ets 传进来（它们从 context 取，而 context 只有页面拿得到）。
   * ⚠️ 它们**不能**带 private：ArkTS 拒绝对私有属性做构造器初始化（只有一条警告），
   * 后果是值传不进来、两个路径都是空串 —— 构建成功但运行不正常，比编译错误难查得多。 */
  filesDir: string = '';
  bundleCodeDir: string = '';

  /* Index.ets 在 Download 那个文件夹确认可用之后把它翻成 true。
   * ⚠️ 那个文件夹是父组件**异步**创建的（mkdir 或 picker），本页 aboutToAppear 紧接着
   * **同步**跑 ⇒ 全新安装的第一次读到状态文件还不存在、jarDirHint 为空（2026-10-01 在
   * MatePad Pro 上实测，重启一次即恢复）。父组件不阻塞地通知一句，这里重读一遍。
   * ⚠️ 反过来也不行：本页不能自己去 ensure（那要 UIAbilityContext，这里只有 filesDir 字符串）。 */
  @Prop @Watch('onFolderSettled') folderSettled: boolean = false;

  /** 玩家点了「启动游戏」。参数是最终决定要加载的那个 jar。 */
  onLaunch: (jarPath: string) => void = (jarPath: string) => {};
  /** 玩家点了「仍然尝试启动」—— 逃生门。 */
  onForceLaunch: () => void = () => {};

  @State games: GameJar[] = [];
  @State selected: string = '';
  @State resolution: GameResolution = { path: '', source: 'none' };
  /* ⚠️⚠️ **2026-10-03：从 @State 降成普通字段，这是一次一行实验 —— 别急着改回去。**
   *
   * 它是一个**只写不读**的遗留字段：全工程没有任何地方读它（当年的 `Tabs({index: this.currentTab})`
   * 绑定已经撤掉）。但它是 `@State` ⇒ **每次赋值都让这个 4100 行的组件变脏** ⇒ `build()` 整棵重跑
   * ⇒ 而三个页签是 `@Builder`（内容内联在 build() 里）⇒ **两千多行的构造代码每次切页签重跑一遍**。
   * ⭐ 这正好解释用户报的「所有页签都一样、稳定地卡」：代价与切到哪个页签无关。
   * ⭐ 对照 AMCL：它也在 onAnimationStart 里写同名字段（`Index.ets:2854`），但它的页签是**独立
   *    `@Component`** ⇒ 父组件重跑时子组件不重新执行 ⇒ 所以它不卡。
   * ⇒ 如果降级后不卡了，说明链条成立，下一步是把三个 @Builder 拆成独立 @Component（AMCL 的结构）。 */
  private currentTab: number = 0;

  /** 模组那个 Downloads 文件夹的路径提示；拿不到时为 ''。 */
  @State jarDirHint: string = '';

  /* 窗口宽度，从 onAreaChange 学来。⚠️ 只为 `barSideMargin`（不接受百分比）而存在 ——
   * 给栏居中就必须知道屏幕多宽。0 表示还没量到，那时用下限兜着。 */
  @State winW: number = 0;

  /* 内容宽度**不再是可调的**：三条路各有固定宽度（见 `gamesWidthVp()`）—— 首页 30%，
   * 存档 / 设置 100%（存档要 100% 是为了把「查看存档数据」挪进右侧空位，不再弹窗）。
   * ⛔ 原来的 `contentPct` / `sliderPct` 与 `launcher_width_pct.txt` 已删，别再加回来。 */
  /** 启动后进哪里。设置里那个开关写盘，启动时由 Index.ets 读。 */
  @State launchMode: string = LAUNCH_MODE_HOME;

  /* 异形屏避让量（vp）。作用在**启动器自己的界面**上：三个页签的内容与所有弹窗。
   * ⭐ 谁在定由 `safeAuto` 说了算：开着 ⇒ 每次启动重新采用探测值；关着 ⇒ 用这个数。
   * ⚠️ 0 是合法值（「不让」），所以「玩家定过没有」不能靠 0 判断 —— 判据是**文件里的模式**，
   *    见 LauncherPrefs 的 readSafePref()。 */
  @State safeVp: number = 0;
  /** 这台机器探测出来的建议值（vp，四边取最大）。只用于设置页的提示与日志。 */
  @State detectedSafeVp: number = 0;
  /** 探测**命中**了哪几边。⭐ 滑条的值只作用在这里面列的边上（用户 2026-10-03 定）。 */
  @State detectedEdges: string[] = [];
  /** 自动避让开着没有。⭐ 开着时每次启动**都重新采用探测结果**；关着时用玩家拖出来的值。
   *  ⚠️ 玩家一动滑条就自动关掉 —— 那是最自然的「我要自己定」的表达方式。 */
  @State safeAuto: boolean = true;

  /* 深色模式的两个开关（2026-10-04 用户要求）。
   * ⭐ `darkFollow` = **跟随系统**（默认，就是本项目一直以来的行为）；
   *    关掉它之后 `darkOn` 才说话。两个开关而不是一个三档选择器 —— 用户要的就是这个形状。 */
  @State darkFollow: boolean = true;
  @State darkOn: boolean = false;

  /* 存储位置（2026-10-04）。⭐ 这三个是**只读展示**用的，第 1 步先不提供切换。
   * ⚠️ `storageUsed` 是 native 记下的**实际**值（`userhome_used.txt`），`storageIntent` 是本页
   *    读设置得出的**意图** —— 两者不一致 = 改了设置还没重启，那不是 bug（见 StorageRoot 文件头）。 */
  @State storageIntent: string = STORAGE_MODE_SANDBOX;
  @State storageUsed: string = '';
  @State storageUsedReason: string = '';
  /** 上一次写给 hdc 的那个内容。⛔ 拿它避免**每次 refresh 都写一个文件**（见 `dumpStorageState`）。 */
  private storageDumped: string = '';
  /* ⭐ **开关控件自己的状态**，与 `storageIntent` 分开。
   * ⛔ 为什么不能直接把 `isOn` 绑到意图上：`Toggle` 只在**绑定值变化时**才重新应用，
   *    而「意图没提交」=「值没变」⇒ 控件不会自己弹回去（用户 2026-10-04 报的
   *    「点取消，开关还是开着的」就是这个）。详见 Toggle 那一段的说明。 */
  @State storageToggleOn: boolean = false;
  /* ⭐ **搬移进行中**（用户 2026-10-04：「复制完成前，切换按钮变成灰色不给点」）。
   * ⛔ 它不是装饰：搬移是**同步**的（`migrateGameData` 在主线程上跑完 250 来个文件），
   *    所以「进行中」这个状态**必须由我们自己在开始前设上、结束后清掉** ——
   *    没有别的东西能给出这个信号（没有进度回调，也没有异步句柄）。 */
  @State storageBusy: boolean = false;
  /* ⭐ 游戏语言是否跟随系统。⛔ 出厂 `true` —— 这不是偏好，是**修缺陷**（见 LauncherPrefs 那段）。 */
  @State gameLocaleFollow: boolean = true;
  /** 游戏内的两个显示值（写进游戏自己的 settings.bin）。出厂 = 游戏的默认值，见 LauncherPrefs。 */
  @State gameEdge: number = GAME_EDGE_FACTORY;
  @State gameScale: number = GAME_SCALE_FACTORY;
  /** ⭐ 实验性：避让由系统参数自动算（出厂关，见 LauncherPrefs）。 */
  @State gameAuto: boolean = false;
  /* ⛔⛔ **探测完成之前不许用自动值** —— 这个标志是承重的，别删。
   *    `initSafeArea()` 是 **async**，而 `refresh()` 是同步的：刷新先跑，那时
   *    `detectedSafeVp` 还是 0 ⇒ 自动值算出来是 0 ⇒ 而 0 会被当成「我们要写 0」
   *    ⇒ **把游戏里原来的避让抹掉**（而那正是自动模式最该保护的东西）。
   *    ⚠️ 这个 bug 的症状是「刚拨上自动适配，避让就归零了」，而且只在启动的头一瞬间发生 ——
   *    正是那种「手动复现要碰运气」的形态，所以用标志挡死而不是指望时序。 */
  private safeDetected: boolean = false;
  /** 写失败时给玩家看的一句话（成功时为空）。 */
  @State gameDisplayNote: string = '';
  /** 上一次尝试过的那组「数据目录 + 两个值」。
   * ⛔ 承重，别删：`refresh()` 被调用得很勤（切页签、切版本…），而 `applyGameDisplay` 要
   *    **读并解析整个 settings.bin**。没有这个缓存，每次刷新都白读一次文件 ——
   *    这正是本项目为「诊断/维护动作拖慢界面」付过代价的那一类。 */
  private gameDisplayTried: string = '';
  /** 探针的原始结论 / 切换结果。⛔ 原样显示，别改写探针的话。 */
  @State storageNote: string = '';

  /** 玩家点过「知道了」。只活这一次会话 —— 不再是失败状态就不会再显示。 */
  @State faultAck: boolean = false;

  /** 「关于」那个窗口开着没有。由设置页那一行打开，右上角的 ✕ 关掉。 */
  @State showAbout: boolean = false;

  /** 玩家选的隔离粒度。改它要走 chooseGranularity()，别直接赋值。 */
  @State granularity: string = GRANULARITY_OFF;

  /** 存档列表。只含文件名/大小/时间（元数据点开才读）。⚠️ 这是**当前版本**那一份；
   * 「按存档」列表用 `saveGroups`。 */
  @State saves: SaveEntry[] = [];

  /* 「按存档」列表的数据：**所有版本**的存档，按数据目录分组。
   * ⚠️ 在 `refresh()` 里算一次（要扫每个版本的目录），⛔ 不在渲染里算。 */
  @State saveGroups: SaveGroup[] = [];

  /* 由宿主页（`Index.ets`）注入的回调 —— 它收到**系统返回**时先问这里。
   * ⛔ 本组件是 `@Component`，而 `onBackPress` 是页面级回调（只有 `@Entry` 有）⇒ 返回事件
   * 到不了这里，只能由页面转发。系统的手势侧滑**走的就是同一个事件**：原来 `Index.ets`
   * 无条件把它转成 ESC 发给游戏，而启动器里没有游戏 ⇒ 「滑了没反应」。补上这条两者一起通。 */
  registerBack: (fn: () => boolean) => void = () => {};

  /* 返回一层。**从最上层往里关**。
   * ⛔ 返回 `false` 表示「我这里没东西可关了」，交给宿主页（在游戏里那会转成 ESC）。 */
  handleBack(): boolean {
    /* 确认框比多选态**更靠外**一层（它盖在多选列表上）⇒ 先关它。⛔ 反过来会把窗留在屏幕上、
     * 而它下面那张列表已经没了 —— 那时按「放进垃圾站」删的是一批已不属于任何东西的键。 */
    if (this.showMultiAsk) { this.showMultiAsk = false; return true; }
    /* 多选态排其后：它是一个**模式**，而模式必须能一键退出。⛔ 排后面的话返回键会先关别的东西，
     * 而玩家看到的还是那张多选列表。 */
    if (this.multiMode) { this.exitMulti(); return true; }
    if (this.showDeleteAsk) { this.showDeleteAsk = false; return true; }
    /* 清空垃圾站的确认框。⚠️ 与上面那些同理 —— 一个能永久删东西的窗必须能被返回键关掉。 */
    if (this.showVaultClearAsk) { this.showVaultClearAsk = false; return true; }
    /* 删除版本的确认窗。⚠️ 与上面同理：一个会真删东西的窗必须能被返回键关掉。 */
    if (this.showGameDeleteAsk) { this.showGameDeleteAsk = false; return true; }
    if (this.transferOp !== '') { this.transferOp = ''; this.transferNote = ''; return true; }
    if (this.isolationConfirm !== '') { this.isolationConfirm = ''; return true; }
    if (this.showIsolationAsk) {
      /* 与那个窗自己的「取消」同义 —— 它本来就只有这一个出口。 */
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

  /* 当前选中的那一行，形如 **`<目录>|<存档 id>`**。
   * ⛔ 原来只存 `id`：隔离后不同版本里的存档会重名（每份数据里都有 `manual:0`）⇒ 一个 id 会
   * 同时命中好几行。带上目录后「选的是哪一份」与「对它做哪个动作」才有唯一答案 ——
   * 目录里不会出现 `|`，存档 id（`manual:0` / `sector:serpulo`）也不会 ⇒ 用第一个 `|` 切分是安全的。
   * ⭐ 带 `@Watch` 读元数据；⚠️ 它只在值真的变化时触发 ⇒ `refresh()` 里还要显式调一次。 */
  @State @Watch('onSaveSelected') selectedSave: string = '';


  /** 这一屏读的是哪个 saves 目录 —— 显示出来，因为隔离会换目录。 */
  @State savesDirShown: string = '';

  /* 存档页当前是哪种视图。默认「按存档」—— 那是玩家真正要操作的那一屏（删除/复制/移动/
   * 看数据都在这儿）；「按版本」是拿来理解隔离在干什么的。⚠️ 别把默认改成按版本。 */
  @State savesView: string = SAVES_VIEW_SAVE;

  /* 「按版本」视图里选中的那个版本的 **jar 路径**（'' 表示没选）。带 `@Watch` 换 `versionSaves`。 */
  @State @Watch('onVersionSelected') selectedVersion: string = '';

  /** 已安装的版本（内置 ＋ 玩家导入的）。`refresh()` 里算一次，渲染只用它。 */
  @State versions: VersionEntry[] = [];

  /** 选中的那个版本的数据目录里有哪些存档。切版本时读一次。 */
  @State versionSaves: SaveEntry[] = [];

  /* ============ 垃圾站 ============ */

  /** 垃圾站视图开着吗。⛔ 它不是第三种「视图」—— 它是**另一个地方**，进出靠一个返回。 */
  @State showVault: boolean = false;
  /* 「清空垃圾站」的二次确认框开着没有。
   * ⛔⛔ 这个动作**不可逆**（`vaultPurge` 是真删，不是搬去别处）⇒ 必须过确认，
   *     和单个存档的删除走同一条规矩（那边的理由见 `showDeleteAsk`）。 */
  @State showVaultClearAsk: boolean = false;

  /* 「删除这个版本」的确认窗开着没有。
   * ⛔ 它与存档那个删除**不是一回事**：存档是搬进垃圾站（能找回），这里两个选项都是**真删**，
   *     而「连数据一起删」还可能连带别的版本（见 `otherVersionsOnSelectedDir`）⇒ 必须过确认。 */
  @State showGameDeleteAsk: boolean = false;
  /* 「按『xxx』进行数据隔离」那个窗里，详情展开了没有。
   * ⭐ 默认收起 —— 里面那两块（这一档怎么分 / 版本→目录表）是**要看的人才有用**的，
   * 摊在外面会让整个弹窗读不完（用户 2026-10-04：「之前的提示我都快看不懂了」）。 */
  @State showIsolationDetail: boolean = false;

  /** 「数据未迁移」那条提示被玩家**手动忽略**了吗。
   * ⭐ 忽略只在**本次运行内**有效，而且状态一变就会自己复位（见 `refresh()`）——
   *    否则他忽略了、又改了粒度，新出现的那个空目录就再也不会提示。
   * ⚠️ 忽略只是**把提示收起来**，不改任何文件 —— 它不是「门」，所以不需要出口。 */
  @State staleIgnored: boolean = false;

  /* 要删的是**哪一个**。⛔ 不用「当前选中的那个」—— 左滑是**对着某一行**做的动作，
   * 而那一行不一定是选中的那一行（选中只决定「点启动游戏时跑哪个」）。
   * ⚠️ 这三样都在**打开确认窗那一刻**存住，理由见 `openGameDeleteAsk`。 */
  @State gameDeletePath: string = '';
  @State gameDeleteLabel: string = '';
  @State gameDeleteDir: string = '';
  /* 版本页上一次删除的结果 / 失败原因。
   * ⛔ 必须说出来：删除失败却让界面看着正常，是这个项目最不该有的那类缺陷。 */
  @State gamesNote: string = '';
  /** 垃圾站里现在有什么。`refresh()` 里读一次，渲染只用它。 */
  @State vaultEntries: VaultEntry[] = [];
  /** 保留期（天）。⭐ 全局设置。 */
  @State vaultDays: number = 7;
  /** 垃圾站里上一次操作的结果（''=没有）。⛔ 只是一句话，不是门。 */
  @State vaultNote: string = '';
  /** 「删除」的确认框开着吗 —— 玩家要在这里选**放垃圾站**还是**归档**。 */
  @State showDeleteAsk: boolean = false;
  /** 上一次清掉几个到期条目。0 表示没有。 */
  @State vaultPurgedLast: number = 0;

  /** 复制/移动的目标选择开着吗，以及是哪一种。`''` = 关着。 */
  @State transferOp: string = '';
  /** 目标选择框里的提示（''=没有）。⛔ 只是一句话，不是门。 */
  @State transferNote: string = '';

  /* 已选中的目标（`v.path` 或 `DUP_KEY`）。**先选、再按确定**（见 TransferDialog）。
   * ⚠️ 复制可以多选；移动**只会有一个**（在 `toggleTransferPick` 里强制）。 */
  @State transferPicked: string[] = [];

  /* ── 整包导入 / 导出 ────────────────────────────────────────────────
   * `importRoot` 是**已解压且已校验过**的那个数据根（在沙箱暂存里）。
   * ⛔ 校验没过就**不开**那个对话框 —— 让玩家对着一个坏包选目标是最坏的一种失败。 */
  @State importOpen: boolean = false;
  @State importRoot: string = '';
  /* ⭐ 这次导入**勾中**的目标，按 `dataDir` 记、**去重**。
   * ⚠️ 用 `dataDir` 而不是版本名当键：两个版本可能共用同一份数据（同一个隔离键）
   *    ⇒ 那也是**一个**目标。写两遍不但浪费，还会让备份出现两份。
   *    这条就是用户 2026-10-03 要的「互斥逻辑」。 */
  @State importPicked: string[] = [];
  @State importNote: string = '';
  @State importMsg: string = '';   /* 非空 = 顶部显示一条进行中/失败的提示 */
  @State importToast: string = ''; /* 成功后的短提示 */
  @State exportMsg: string = '';

  /* 选中那个存档的元数据：在【选中】时读一次存下来（右侧栏要显示「哪个版本写的」），而不是点开弹窗才读。
   * ⚠️ 存的是**排好的行**而非 `SaveMeta` 原样：读它要**解压**（saveMetaText 走 zlib），常驻原始字段会让
   * 每次重绘都依赖一堆「可能是空串」的判断；界面里也因此没有 native 类型。
   * ⚠️ `selMetaNote` 非空 ⇒ 读失败了，`selMetaRows` 只有能确定的那一两行。
   * ⛔ **不允许「读失败但界面上看起来正常」** —— 那会让玩家以为存档是空的。 */
  @State selMetaRows: MetaRow[] = [];
  @State selMetaNote: string = '';

  /* 打开隔离时的**询问窗**是否开着。
   * 必须问：打开隔离会让 `user.home` 换地方，玩家进游戏发现存档「没了」而自己什么都没做
   * （虽然我们做的是**复制**、原数据留着，但玩家不知道）。
   * ⚠️ 只在「不隔离 → 某一档」时问。**关掉不问** —— 关掉一个字节都不会动，问了反以为有风险。 */
  @State showIsolationAsk: boolean = false;

  /** 询问里待确认的那一档；'' 表示没有。 */
  @State pendingGranularity: string = '';

  /* 「复制过去」时**玩家勾了哪些分类**。⚠️ 每次打开重算（见 `chooseGranularity`）——
   * 版本增删与各分类有没有数据都会变，缓存会显示过期的东西。 */
  /** 上一次「把数据复制进来」失败的原因；'' = 没有失败。
   * ⚠️ 单独一个 @State 而非复用 `isolationNote`：这一块显示在**存档页**（动作在那儿按的），
   * 而 `isolationNote` 渲染在**设置页** —— 一个字段两个渲染点就是「按了没反应」的病。 */
  @State staleCopyNote: string = '';
  /* **长按进入多选，一次删多个**（2026-10-02）。
   * ⚠️ 选中的键与单选**同一套**（`<目录>|<id>`）⇒ 两个视图、两张列表指的是同一样东西，
   * ⛔ 不需要第二套身份；而 `multiMode` **一个开关管两处**，进去后两张列表都按多选解释点击。
   * ⭐ 删除走**同一条路**（搬进垃圾站，不是抹掉），保留方式用**全局那个保留期** ——
   * 逐条问就把「一键」毁掉了；归档仍然可以事后在垃圾站里点。 */
  @State multiMode: boolean = false;
  @State multiPicked: string[] = [];
  /* 多选删除的**确认框**（2026-10-02：「我最后点删除的时候没有提示框」）。
   * ⛔ 我第一版是**故意不问**的（理由「逐条问就把一键毁掉了」），而那句话把两件事混成一件：
   * 他不要的是**逐条**问，要的是**删之前问一次** ⇒ 「不要 N 次」不等于「不要那一次」。 */
  @State showMultiAsk: boolean = false;
  /** 确认框里那张名单展开了吗。⚠️ 默认收起 —— 一次选二十个会把窗撑爆。 */
  @State multiListOpen: boolean = false;
  /** 多选删除之后的一句话（成功/失败都写这儿）。⚠️ 与 `vaultNote` 分开：
   * 那个渲染在**垃圾站**里，而这里是**存档页**。 */
  @State savesNote: string = '';
  @State copyTargets: CopyTarget[] = [];
  @State copyPicked: string[] = [];

  /** 迁移出问题时要告诉玩家的一句话；'' 表示没有。⛔ 不是门，只提示。 */
  @State isolationNote: string = '';

  /* 询问窗里「这一档下每个版本会落到哪个目录」的预览行（一行一个版本）。
   * ⚠️ 原来那句说明（`granularityHint`）只在**设置页、选完之后**才显示，而询问窗是唯一能
   * 反悔的地方，恰恰那时什么解释都没有。用玩家**真实的版本**算，不举 `160.5` 这种编的例子。
   * ⚠️ 在 `chooseGranularity()` 里算一次（要读每个 jar），⛔ 不在渲染里算。 */
  @State pendingPreview: string = '';
  /* ⭐⭐ 说明那一行**存下来**，渲染只读这个字符串。
   *
   * ⛔ 我 2026-10-04 把它改成「算出来的」之后，忘了它被**渲染**调用（设置页 + 弹窗两处），
   *    而它的实现要读**每一个 jar**（`gameVersionParts` 没有缓存，单个最大 88 MB）⇒
   *    **每渲染一次就把所有 jar 读一遍**。讽刺的是我自己在下面写了「⛔ 绝不在渲染路径上」，
   *    然后又违反了它。
   * ⭐ 判据（本文件通用）：**凡是要读 jar 的，一律在 `refresh()` / 事件处理里算好，存进 @State**；
   *    渲染里只允许读已经算好的值。
   * ⚠️ 两份：设置页按 `this.granularity` 算，弹窗按 `pendingGranularity` 算，两者不同。 */
  @State granularityHintText: string = '';
  @State pendingHint: string = '';

  /* 当前选中的是**内置游戏** —— 它在任何档位下都用固定的 `bundled` 目录。
   * ⛔ 必须专门说一句：玩家这时切「大版本/构建号/小版本」，**目录名一个都不会变** ⇒
   * 他会以为功能坏了。真因是一条刻意的设计：内置那份永不移动，换内置 jar 时玩家数据不跟着搬。 */
  @State pendingUsesBundled: boolean = false;

  /* 询问窗要点名的那个版本：「名字 · 版本号」。
   * ⚠️ 原来整句话只有指代（「这个版本」），而那个版本的**身份**在那一屏上看不见（它在首页页签）
   * ⇒ 这里点名。
   * ⛔【曾经还有一个 `pendingKey`】—— 窗里单独写一行「这一档下，它用目录：xxx」。
   *    2026-10-04 删了：下面那份「版本 → 目录」对照表**本来就含当前版本那一行**，
   *    再单独写一遍是同一份信息的第二遍。⚠️ 顺带省掉一次 `resolveGameDirAndKey()` ——
   *    它会**真读 jar**（最大 88 MB），而弹窗每打开一次要渲染好几遍。 */
  @State pendingVersionName: string = '';

  /* **隔离开着，但那一份数据目录根本不存在** —— 即「开关拨过去了、数据没过去」。
   * ⛔ 必须单独显出来：这种状态在界面上**完全看不出来**，玩家进游戏看到的是一整套空数据
   * ⇒ 只会说「我的存档全没了」。顺序已改成「复制成功才落盘」，但已经踩进去的状态不会自己
   * 出来，这个提示就是它的出口。
   * ⚠️ 在 `refresh()` 里算一次，⛔ 不在渲染时 `accessSync`（渲染每帧都跑）。 */
  @State isolationStale: boolean = false;

  /* 询问窗要摆出来的【现在有什么】。打开询问窗那一刻读一次，不常驻。
   * ⚠️ 每次打开都重读、刻意不缓存：两次打开之间玩家可能删过存档或装过模组，缓存会停在旧值。 */
  @State isolationCounts: GameDataCounts = { sectorSaves: 0, manualSaves: 0, mods: 0, schematics: 0 };

  /* 二次确认：`''` = 没有；`'copy'` / `'empty'` = 哪一个动作在等确认。
   * ⚠️ 两个动作都要确认（2026-10-02 要求）：`empty` 真的会让人看不到存档；`copy` 本身安全
   * （源不动）但它是「切换数据位置」的一半，玩家点的第一下未必是想好的那一个。 */
  @State isolationConfirm: string = '';

  /** 下拉刷新是否在进行中。`$$` 双向绑定给 Refresh，由 onRefreshing 放回 false。 */
  @State isRefreshing: boolean = false;

  /** 包内那份自带游戏的版本号；读不出时 ''，界面显示「未知版本」。 */
  @State bundledVer: string = '';

  /* 包内那份自带游戏**在不在**。⛔ 别从 `resolution.source` 反推 —— 那是「这次加载谁」。 */
  @State hasBundled: boolean = false;

  /* 给**人**看的那个文件夹路径，形如 `Download/<应用名>/games`。⚠️ `Download` 单数 —— 磁盘上的真名。
   * ⚠️ 真实路径不够用：那个文件夹**磁盘上叫包名**（ModImporter 用 bundle 名创建），
   * 而文件管理器把它**显示成应用名** ⇒ 玩家照着找**找不到**（卸载后才退化成包名）。
   * ⛔ 所以这里既不能写死包名、也不能写死应用名 —— 两个名字都随应用而变，见 `appLabel`。
   * ⇒ 两行都给：这一行用来**找**，真实路径那一行用来**复制**。 */
  @State jarDirHuman: string = '';

  /* 应用自己的显示名，由 resolveAppLabel() 从资源读出；读不到时 ''。 */
  /* ⚠️ 名字叫 `appName` 而不是 `appLabel`：后者是 `utils/AppLabel` 导入的【函数】名。 */
  private appName: string = '';

  /** 应用版本号，「关于」那一页要显示它。
   *
   * ⛔⛔ 它原来是**普通成员**（无 `@State`），而且**实际拿到的永远是空串**：
   *     Index 传进来的是 `Index.appVersion`，而那个字段只由**游戏侧**的 `openAbout()`
   *     赋值（`Index.ets:727`，悬浮球菜单触发）—— 启动器自己那个「关于」从没触发过它。
   *     ⇒ 「关于」里 `this.appVersion === ''` 恒真 ⇒ **只显示应用名、没有版本号**
   *     ⇒ 用户 2026-10-03 报「看版本号得到设置里去看」（那里的 About 是 Index 自己的，会查）。
   * ⭐ 两处一起改：加 `@State`（否则异步/后写的值不重绘），并由本组件自己的 `openAbout()`
   *    在**打开时**查一次 —— 与 `Index.ets` 那条注释同一个理由：
   *    「版本号在打开时才读，不是启动时：它要花一次包查询，而那之前没人需要它」。 */
  @State appVersion: string = '';

  /* 上一次启动失败的记录；'' 表示没失败过。
   * ⚠️ 它是【上一次】的判定，不是即时的：失败发生时进程已经死了、没有界面能弹窗，唯一物证是
   * native 在游戏入口前留下的东西，要等**下一次启动**才被读到。 */
  launchFault: string = '';

  /* 底部页签换成 HdsTabs（鸿蒙设计系统组件）之后，原来那两个字段都不需要了：
   *
   *   · canFloat（sdkApiVersion >= 26 的门槛）—— 裸 Tabs 的 barFloatingStyle 是 @since 26.0.0，
   *     而 HdsTabs 的 barFloatingStyle 是 @since 6.0.0(20)（逐条核过本机 SDK 的
   *     @hms.hds.hdsBaseComponent.d.ets）⇒ 我们 compatibleSdkVersion 24 ⇒ 门槛不存在了，
   *     原来那两条分支因此合成一条（同一份内容复制两遍，本文件已为「只改一处」吃过苦）。
   *   · barMaterial（uiMaterial.Material）—— 换成 systemMaterialEffect 里的两个枚举，
   *     由系统按设备与主题自适应，比我们原先自己挑一个材质更稳。
   * ⚠️ hdsMaterial 本身是 @since 6.1.0(23) ⇒ 仍要求 API 23+，与 compatibleSdkVersion(24) 相容。
   *
   * ⚠️ 控制器必须与 HdsTabs 配套（HdsTabsOptions.controller 收的是 HdsTabsController，
   *    不是 TabsController）—— AMCL 也单独持有它。 */
  private tabController: HdsTabsController = new HdsTabsController();

  aboutToAppear(): void {
    this.launchMode = readLaunchMode(this.filesDir);
    this.granularity = readGranularity(this.filesDir);
    this.appName = this.resolveAppLabel();
    /* 异形屏避让是**异步**的（getCutoutInfo 返回 Promise），所以单独走一条，不挡住下面那些。
     * ⚠️ 它一定在首帧之后才回来 ⇒ 不做骨架屏、也不迟到得像「界面闪了一下」：
     * 探测通常几毫秒，而玩家的注意力那时还在启动动画上。 */
    this.initSafeArea();
    /* 把「返回一层」交给宿主页 —— 见 registerBack。 */
    this.registerBack(() => this.handleBack());
    this.refresh();
  }

  /** 让开的边，翻成中文给玩家看。⭐ 用 effectiveEdges()（实际生效的那几边），
   * 不是 detectedEdges —— 探测为空时生效的是「只上边」，界面必须说「上」，否则它在骗人。 */
  private edgeNames(): string {
    const n: string[] = [];
    for (const e of this.effectiveEdges()) {
      n.push(e === 'top' ? '上' : (e === 'bottom' ? '下' : (e === 'left' ? '左' : '右')));
    }
    return n.join('/');
  }

  /* 某一条边最终让开多少 vp。⭐⭐ 三条规则，按顺序：
   *
   *   ① 避让量为 0        ⇒ 四边都不让（玩家明确选了「不让」）
   *   ② 探测**没命中任何边** ⇒ **只让上边**
   *   ③ 探测命中了那几边   ⇒ **只让那几边**（用户 2026-10-03：「保留一个滑条，但只用在探测到的那几边」）
   *
   * ⛔ ② 曾经是「四边都让」，**那是错的**（用户 2026-10-03 当场指出：「左右避让干啥啊」）。
   *    左右两条边在这台机器上白白少了一截可用宽度，而顶部那个孔根本没碰到它们。
   *    ⇒ 探测不到时按**最常见的形状**假定：顶部一个挖孔。要上下都让的机器由玩家自己拖。
   * ⚠️ 仍是猜测，但它的代价是「上边多让一点」而不是「左右各少一截」，而且**上边本来就最先被挡**。 */
  private edgeVp(edge: string): number {
    if (this.safeVp <= 0) {
      return 0;
    }
    if (this.detectedEdges.length === 0) {
      return edge === 'top' ? this.safeVp : 0;
    }
    return this.detectedEdges.indexOf(edge) >= 0 ? this.safeVp : 0;
  }

  /* 异形屏避让的初始化。⭐ 语义是**覆盖**（用户 2026-10-03 的选择）：
   *   玩家自己设过 ⇒ **完全听他的**，探测值只用来在设置页里显示作参考；
   *   没设过     ⇒ 用这次探测的结论**播种**一次，之后那也成了「玩家的选择」。
   * ⛔ 「设过没有」看的是**文件在不在**，不是「值是不是 0」—— 0 是合法选择（不让开）。 */
  /* 把存储位置 + 自动适配的那几行写成一个 hdc 读得到的小文件。
   *
   * ⛔ **抽成方法是因为它有【两个】调用点，而那两处缺一不可**：
   *    ① `refresh()` —— 常规时机；
   *    ② `initSafeArea()` 探测完成之后 —— ⭐ **少了它，自动适配的值永远不进这个文件**。
   *       探测是 async、`refresh()` 是 sync：文件在探测完成前就写好了，而之后没有第二次
   *       `refresh()`（我只在应用启动时跑一次）⇒ 文件里会永久留着一个 `derived:0`，
   *       看起来像「公式算出来是 0」。**2026-10-04 真的这样量到过一次。**
   * ⛔ 只在内容变了时写：它在 `refresh()` 里，而每渲染周期写一次文件本身就是卡顿源。 */
  private dumpStorageDiagnostics(): void {
    const dump: string = readStorageMode(this.filesDir) + '|' + this.storageUsed + '|'
                       + this.storageUsedReason + '|' + String(this.isolationStale)
                       /* ⭐ 自动适配的**输入与结果**也进这个键 ⇒ 它们一变就重写这个文件。
                        * 那几个数只在探测完成后才算得出来（`safeDetected`），
                        * 加进键里正是为了让**那一次**触发重写。 */
                       + '|' + String(this.safeDetected) + '|' + String(this.gameAuto)
                       + '|' + String(this.gameEdge) + '|' + String(this.detectedSafeVp);
    if (dump === this.storageDumped) {
      return;
    }
    /* ⚠️ 那份目录清单**在这里算**（而不是每次都算）—— 它要递归列两个根下每一份数据，
     *    比另外几行贵得多，而它只在真正写文件时才被用到。
     * ⛔ 缓存键里**不包含它**：清单会随游戏运行而变，把清单本身当键会让每次 refresh 都写。
     *    判据是「这几行没变就不重写」—— 而这个文件的用途是**事后**排查，写多了没意义。 */
    const dirs: string = dumpDataDirs(this.filesDir);
    /* ⭐ 自动适配那几个数落成文本行 —— 没有它们，「公式算得对不对」只能靠点滑条看效果
     *    （而本应用的 hilog 读不到，`game=` 那行只说游戏文件里现在是什么）。 */
    const extra: string = 'autofit=on:' + (this.gameAuto ? '1' : '0')
                        + ' detected:' + String(this.safeDetected)
                        + ' insetVp:' + String(this.detectedSafeVp)
                        + ' density:' + String(displayDensity())
                        + ' edge:' + String(this.gameEdge) + NL;
    if (dumpStorageState(this.filesDir, this.storageIntent, this.storageUsed,
                                  this.storageUsedReason, this.isolationStale, extra, dirs)) {
      this.storageDumped = dump;
    }
  }

  /* 按本机参数算一个避让值，并**直接采用它**（写进 `gameEdge`）。
   *
   * ⛔⛔ **为什么是「采用」而不是「并存两个值」**（2026-10-04 改的）：原来自动值与手动值分成
   *    `gameAutoEdge` / `gameEdge` 两份，而滑条动的是**手动**那份 ⇒ **自动开着时拖滑条完全无效**
   *    （滑条显示自动值、拖了却改不动生效的那个数）—— 那是「控件看起来能用、实际不起作用」，
   *    与本项目反复记下的那类缺陷同族。
   * ⭐ 现在的模型**只有一个值**：`gameEdge`，它就是会被写进游戏的那个数。
   *    「自动适配」退化成一个**动作**：按本机挖孔算一个值并填进 `gameEdge`；
   *    之后滑条就是唯一的编辑器，两者永远一致。
   * ⚠️ 代价：自动值**不会**每次启动重算（那会抹掉玩家的微调）。要重算就再拨一次开关。
   *
   * @returns 有没有真的算出一个可用的值（探测没回来 / 本机没挖孔 ⇒ false，**不动**现有值）。 */
  private seedGameEdgeFromDevice(): boolean {
    if (!this.safeDetected) {
      return false;                /* 探测没回来 ⇒ 算出来会是 0，而 0 是合法值 ⇒ 不能填 */
    }
    const density: number = displayDensity();
    const insetPx: number = Math.round(this.detectedSafeVp * density);
    const v: number = autoEdgePadding(insetPx, density, this.gameScale);
    if (v <= 0) {
      return false;                /* 本机没有挖孔要让（或推不出来）⇒ 保持玩家现有的值 */
    }
    this.gameEdge = v;
    return true;
  }

  private async initSafeArea(): Promise<void> {
    let ins: SafeInsets = { top: 0, right: 0, bottom: 0, left: 0 };
    try {
      ins = await detectInsets(getContext(this) as common.Context);
    } catch (e) {
      /* detectInsets 自己吞掉异常并返回 0；这一层只是不让它拖垮 aboutToAppear。 */
    }
    this.detectedSafeVp = uniformOf(ins);
    this.detectedEdges = edgesOf(ins);

    /* ⭐⭐ 自动 / 手动的判定。
     * ⛔ 第一版是「只播种一次」（文件不在就把探测值写进去，之后永远用文件里的值）——
     *    那个设计**坏过**：前一版探测本身有 bug、永远得 0，而那唯一一次播种把 0 固化了，
     *    从此探测值再也不被采用。用户 2026-10-03 报的「自动设置好异形屏避让没做」就是它。
     * ⇒ 改成**状态**：只要玩家没动过滑条（文件里写着 auto），每次启动都重新采用探测结果。 */
    const pref: SafePref = readSafePref(this.filesDir);
    this.safeAuto = pref.auto;
    this.safeVp = pref.auto ? this.detectedSafeVp : pref.vp;

    /* 每次都写回：auto 时值是探测的、user 时值是玩家的；写回也让这个文件自己可读（诊断用）。 */
    writeSafePref(this.filesDir, this.safeAuto, this.safeVp);

    /* 这一段落盘是**唯一**能离开设备的东西 —— 本应用的 hilog 实测读不到（见 SafeArea.ets）。 */
    dumpSafeArea('\n--- prefs ---\nauto=' + this.safeAuto
                 + '  applied=' + this.safeVp + ' vp\nfile='
                 + (pref.auto ? 'auto' : 'user') + ' ' + pref.vp
                 + '\napplied edges=' + JSON.stringify(this.effectiveEdges()) + '\n', true);
    hilog.info(DOMAIN, TAG,
               'safearea: auto=%{public}s applied=%{public}d vp (detected %{public}d)',
               String(this.safeAuto), this.safeVp, this.detectedSafeVp);

    /* ⭐ **探测回来了** ⇒ 现在才允许自动避让参与计算，并立刻重算一次 + 重试写入。
     * ⛔ 这两行是承重的：`refresh()` 早就在探测完成之前跑过了，那一次的自动值是 0
     *    （被 `safeDetected` 挡在计算之外，所以**没写进去**）。不复算的话，自动模式要等到
     *    下一次 `refresh()`（切页签之类）才会生效 —— 也就是「拨了开关没反应，过一会儿又好了」。 */
    this.safeDetected = true;
    if (this.gameAuto) {
      this.seedGameEdgeFromDevice();
    }
    this.applyGameDisplayNow();
    /* ⛔ 再把诊断文件写一次 —— 上面那几个数刚变，而这次不再有 `refresh()` 了。
     *    少了这一句，文件里会永久留着探测之前的 `derived:0`（2026-10-04 踩过）。 */
    this.dumpStorageDiagnostics();
  }

  /** 滑条真正作用在哪几边（探测为空时是「只上边」，见 edgeVp）。 */
  private effectiveEdges(): string[] {
    return this.detectedEdges.length === 0 ? ['top'] : this.detectedEdges;
  }

  /* ====================================================================
   * 版本隔离
   * ==================================================================== */

  /** 某一档的一句话说明。四档的差别对玩家不是自明的，所以每档都要写清。 */
  /* 档位的**名字**（弹窗标题用）。
   * ⚠️ 措辞必须与设置页那四个药丸（不隔离 / 大版本 / 构建号 / 小版本）**逐字一致** ——
   * 否则玩家会以为是两个东西。⛔ 别自己造一套更好听的说法。 */
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

  /* 把「已装的版本」按**当前档位算出来的键**分组 —— 键相同 = 落进同一个目录 = 共用一份数据。
   *
   * ⭐⭐ 这是用户 2026-10-04 要的那张「哪几个版本共用存档」的表，也是【说明文字】的唯一来源。
   * ⛔ 在它之前，说明那句是**写死的**（`'v8 的所有版本共用一份'`）而表是真算的 ⇒
   *    只要装的不是 v8，**说明就在说谎**（用户原话：「我不知道你有没有做 v7 等等的提示」——
   *    答案是没有）。现在两者同一处算，不可能分叉。
   *
   * ⚠️ 分组【不自己折版本字段】（number / build 那些）：`computeKey()` 已经把该并的并了，
   *    包括「与内置同版本也走 bundled」那条规则 —— 再折一次就是把那条规则实现第二遍。
   * ⚠️ 它会读每个 jar（`gameVersionParts` **没有缓存**）⇒ 只从 `chooseGranularity()` 与
   *    设置页那次调用，⛔ 绝不在渲染路径上。 */
  private isolationGroups(g: string): IsoGroup[] {
    const out: IsoGroup[] = [];
    const at: Map<string, number> = new Map<string, number>();
    for (const v of this.versions) {
      const key: string = resolveGameDirAndKey(g, v.source, v.path, this.bundledJar()).key;
      const k: string = key === '' ? '（不隔离）' : key;
      /* ⭐ 显示**实际版本号**，⛔ 不是 jar 文件名（用户 2026-10-04：
       * 「不要展示 jar 名称，展示实际版本名称」）。读不出才退回文件名。 */
      const nm: string = (v.version === '' ? v.label : v.version)
                       + (v.source === 'bundled' ? '（内置）' : '');
      const i: number | undefined = at.get(k);
      if (i === undefined) {
        at.set(k, out.length);
        out.push({ key: k, versions: [nm] });
      } else {
        out[at.get(k) as number].versions.push(nm);
      }
    }
    return out;
  }

  /* 键 → 它代表的**版本槽位**（`b160` → `160`、`n8` → `8`）；**不是槽位的键返回空串**。
   *
   * ⛔⛔ 这是 2026-10-04 用户当场看到那个 bug 的根：我在两个调用点各自写了
   *      `key.substring(1)`，理由是「槽位键恒为 `n`/`b` + 数字」。而 `KEY_BUNDLED`
   *      是 `bundled` ⇒ 被砍成 **`undled`**，又以 `b` 开头 ⇒ 还被当成「构建号系列」，
   *      于是弹窗上写着 **「vundled 的所有版本共用一份」**。
   * ⭐ 判据改成**形状**（`n`/`b` 后面必须跟数字）：`bundled`（b+u）与 `_unknown`（下划线）
   *    自然落选，⛔ 不依赖任何白名单，将来多出别的键也不会再误判。 */
  private slotOfKey(key: string): string {
    return /^[nb][0-9]/.test(key) ? key.substring(1) : '';
  }

  /* 内置那份**在这一档下本来会落到哪个槽位**（`n8` / `b160`）—— ⛔ 不是它实际用的那个：
   * 内置恒用 `bundled`，这个值只用来**告诉玩家它相当于哪一档**。
   * ⭐ 用户 2026-10-04：「按大版本：内置游戏（v8）」「按构建号：内置游戏（b160）」。
   * ⛔ 它读 jar（`gameVersionParts` 没有缓存）⇒ 只从 `buildGranularityPreview()` /
   *    `isoGroupTitle()` 走，⛔ 不在渲染路径上。读不出返回 `''`（那时不显示括号）。 */
  private bundledSlotKey(g: string): string {
    const p: string = bundledGamePath(this.bundleCodeDir);
    if (p === '') {
      return '';
    }
    return granularityKey(g, gameVersionParts(p));
  }

  /** 一个槽位键给玩家看的写法：`n8` → `v8`，`b160` → `b160`。⛔ 不是槽位就返回空串。 */
  private slotLabel(key: string): string {
    if (key === '' || key === KEY_UNKNOWN) {
      return '';
    }
    return key.charAt(0) === 'n' ? ('v' + key.substring(1)) : key;
  }

  /** 一个组在表里的标题。⛔ `bundled` / `_unknown` **不是版本槽位**，不能当版本号念。 */
  private isoGroupTitle(g: string, key: string): string {
    if (key === 'bundled') {
      /* ⭐ 说人话：它对应的就是「内置游戏」那一行。
       * ⭐⭐ 再带上它**相当于哪一档** —— 玩家看「内置游戏」不知道那一档把它分到了哪里，
       * 而括号里那个才是他能和自己导入的 jar 对上的东西。
       * ⚠️ 这个值是**算**出来的（读内置 jar 的版本），⛔ 不是写死的 ——
       * 我们换内置游戏版本时它会自己跟着变（用户 2026-10-04：「文字需要是动态的，
       * 不是固定死的，这样我们换了版本可以少改一处」）。 */
      const sub: string = this.slotLabel(this.bundledSlotKey(g));
      return sub === '' ? '内置游戏' : ('内置游戏（' + sub + '）');
    }
    if (key === '_unknown') {
      /* ⚠️ 同一条道理：`_unknown` 是**内部键**，不能原样念给玩家听。
       * 措辞跟版本列表那边走（读不出就是「未知版本」）—— 一处词，两处别分叉。 */
      return '未知版本';
    }
    const slot: string = this.slotOfKey(key);
    if (slot === '') {
      return key;                     // `_unknown` / `（不隔离）` 之类，原样
    }
    return key.charAt(0) === 'n' ? ('v' + slot + ' 系列') : (slot + ' 版本');
  }

  /* 说明那一行。⭐ **每一段都来自 `isolationGroups()`** —— 也就是玩家自己装了什么。 */
  private granularityHint(g: string): string {
    if (g === GRANULARITY_OFF) {
      return '所有版本共用一份数据（默认）';
    }
    const groups: IsoGroup[] = this.isolationGroups(g);
    if (groups.length === 0) {
      return '';
    }
    if (g === GRANULARITY_PATCH) {
      return '每个版本各一份';
    }
    /* ⭐ 只数**真槽位**（`n8` / `b160`）。`bundled` / `_unknown` 不是槽位 ——
     * 它们在这句里没有对应的话可说（内置那份由下面那行「注意」交代）。 */
    const slots: string[] = [];
    for (const gr of groups) {
      const s: string = this.slotOfKey(gr.key);
      if (s !== '' && slots.indexOf(s) < 0) {
        slots.push(s);
      }
    }
    if (slots.length === 0) {
      /* 装的版本一个槽位都算不出来（全是内置 / 读不出）⇒ 退回**通用规则**，
       * ⛔ 不要拼出半句空话。 */
      return g === GRANULARITY_NUMBER ? '同一个大版本共用一份' : '同一构建号的版本共用一份';
    }
    const parts: string[] = [];
    const cap: number = Math.min(slots.length, 2);
    for (let i = 0; i < cap; i += 1) {
      if (g === GRANULARITY_NUMBER) {
        parts.push('v' + slots[i] + ' 的所有版本共用一份');
      } else {
        /* ⛔ 这里不列成员 —— 下面那张表会逐个列出来，一行说明再列一遍就长了。 */
        parts.push('同一 ' + slots[i] + ' 的版本共用一份');
      }
    }
    if (slots.length > 2) {
      parts.push('其余同理');
    }
    return parts.join('；');
  }

  /* 玩家点了某一档。⭐ **关掉不问、打开才问** —— 两者后果不同：
   * 关掉 ⇒ `user.home` 回到原处、一个字节都不动；打开 ⇒ 换到一个新目录（要么是刚复制
   * 过去的、要么是空的）。⚠️ 对不会有后果的动作弹窗，会让玩家以为关掉也有风险。 */
  private chooseGranularity(g: string): void {
    if (g === this.granularity) {
      return;
    }
    if (g === GRANULARITY_OFF) {
      this.granularity = g;
      writeGranularity(this.filesDir, g);
      this.isolationNote = '';
      /* 关掉也要刷新 —— `user.home` 换回公开那一份，存档页要显示**另一批**存档、版本页要重算
       * 每个版本的目录。⛔ 少了这一句界面还停在隔离开着时的样子，玩家会以为没关掉。 */
      this.refresh();
      return;
    }
    /* 打开：先把「当前数据怎么办」问清楚。⛔ 这里**不**先落盘 —— 玩家取消的话那一档不该跳过去。 */
    this.pendingGranularity = g;
    /* 读一次「现在有什么」，好在玩家**选之前**把两个结果都写成数字。⚠️ 在这里读、不常驻。 */
    this.isolationCounts = countsOf(liveGameDataDir());
    /* 选之前就把「这一档怎么分、会落到哪些目录」摆出来（原来要选完才知道是啥情况）。 */
    this.pendingPreview = this.buildGranularityPreview(g);
    /* ⭐ 与上面同一批：要读 jar 的东西在这里一次算好（渲染只读字符串，见 `pendingHint` 的注释）。 */
    this.pendingHint = this.granularityHint(g);
    /* 每次打开都**收起详情** —— 上一次展开过的话，这次一进来就是展开的，
     * 而那是上一次的状态（与 `MultiBar` 里那个「名单每次重新收起」同一条理由）。 */
    this.showIsolationDetail = false;
    /* 「复制过去」要复制的分类：算出来并**默认全勾**（玩家的意图就是每个版本都别丢数据，
     * 那是常见情形；反过来默认一个都不勾会让最常见的意图要点两次）。与「我替你全选」的差别
     * 在于 —— **现在是看得见的**，而且能改。 */
    this.copyTargets = this.buildCopyTargets(g);
    this.copyPicked = this.copyTargets.map((c: CopyTarget) => c.key);
    this.pendingUsesBundled = this.versions.some((v: VersionEntry) => v.source === 'bundled');
    /* 点名当前这个版本。⚠️ 版本名按 `resolution.path`（**版本身份**，jar 路径）找，
     * ⛔ 不是版本号（两个 jar 可以是同一个版本号）。 */
    const res: GameResolution = this.resolution;
    const hit: VersionEntry | undefined =
      this.versions.find((v: VersionEntry) => v.path === res.path);
    if (hit === undefined) {
      /* 找不到就说实话（jar 在两次读取之间被删了）。⛔ 不要留空 —— 那会让玩家以为「没有版本」。 */
      this.pendingVersionName = '（当前没有可用的游戏版本）';
    } else {
      this.pendingVersionName = hit.label + (hit.version === '' ? '' : ('  ·  ' + hit.version));
    }
    this.showIsolationAsk = true;
  }

  /* 「按这一档分，每个已装版本会落到哪个目录」—— 逐行列出。用玩家**真实的版本**算，
   * 不举 `160.5` 那种编的例子：他要回答的是「我那两个 jar 会不会被分到一起」，只有他自己的版本号能回答。
   * ⚠️ 它会读每个 jar（`gameVersionParts` **没有缓存**）⇒ 只从 `chooseGranularity()` 调，
   * ⛔ 绝不在渲染路径上（一次点开 = 读 4 个 jar，与 `refresh()` 同量级）。 */
  private buildGranularityPreview(g: string): string {
    const groups: IsoGroup[] = this.isolationGroups(g);
    if (groups.length === 0) {
      return '（现在还没有可用的游戏版本）';
    }
    const lines: string[] = [];
    for (const gr of groups) {
      /* ⭐ 组标题（用户 2026-10-04 给的形状：「160版本 / xxx -> xxx / 159版本 / …」）。
       * ⛔ 小版本那一档**不出标题** —— 每个版本各一份，标题只会逐行重复「各自一份」。 */
      if (g !== GRANULARITY_PATCH) {
        lines.push(this.isoGroupTitle(g, gr.key));
      }
      for (const nm of gr.versions) {
        lines.push('    ' + nm + '   →   ' + gr.key);
      }
    }
    return lines.join('\n');
  }

  /* 询问里选了「复制过去」。复制而不是移动 —— 源目录一个字都不动（2026-10-02 定的
   * 「留一个当备份」）⇒ **可逆**：把隔离关掉，看到的还是原来那一份。
   * ⚠️ 复制失败**不阻止**打开隔离：新目录只是空的、**原数据完好**，记一句话给玩家看，流程照走。 */
  private applyIsolationCopy(): void {
    const g: string = this.pendingGranularity;
    const res: GameResolution = resolveGame(this.filesDir, this.bundleCodeDir);
    /* ⚠️ 用成对的那个函数、只取 `key` —— 目录这次用不上，但分开调两次会读两遍 jar。 */
    const key: string = resolveGameDirAndKey(g, res.source, res.path, this.bundledJar()).key;
    if (key === '') {
      /* 一个可加载的游戏都没有 ⇒ 键是空的 ⇒ 隔离没有意义。不落盘、也不报错。 */
      this.isolationNote = '现在没有可加载的游戏，先选一个游戏版本再开隔离';
      this.showIsolationAsk = false;
      this.pendingGranularity = '';
      return;
    }
    /* **先复制，成功了才落盘。**
     * ⛔ 原来顺序是反的（先 `writeGranularity` 再复制），2026-10-02 那次复制失败就暴露了：
     * 隔离标记已落盘 ⇒ 进游戏 `user.home` 指向那棵**空的**新树 ⇒ 「存档全没了」，而报错只写在
     * 设置页一行小字里。判据是「玩家的意图有没有被执行」，不是「数据有没有丢」；开关留在原处还保住可重试。 */
    /* **「复制过去」要给每个版本都补一份，不只当前那一个。**
     * ⛔ 2026-10-02 报「粒度的复制似乎是不起作用的」，而日志说那次复制**成功了**
     * （`copied 14 dir(s) / 188 file(s)`）—— 但它复制到 `instances/bundled`、那个目录**本来就有数据**
     * ⇒ 界面上与「什么都没做」完全一样。「粒度」的含义是：**这一档下的每一个版本各有一份**。
     * ⚠️ 只补**还没有数据**的那些，⛔ 不覆盖已有的（那等于又删了一次）；当前版本那份必须成功，其余尽力而为。 */
  const note: string = copyLiveDataInto(key);
  if (note !== '') {
    this.isolationNote = note + '。隔离没有打开，你的数据还在原来的位置。';
    this.showIsolationAsk = false;
    this.pendingGranularity = '';
    this.refresh();
    return;
  }
  /* 其余**玩家勾了的**分类 —— 不再是我替他全选（见 CopyTarget）。⚠️ 仍然只补「还没有数据」的
   * 那些（已有那份可能装着后来玩的进度，覆盖等于又删了一次）⇒ 勾了也不会覆盖。 */
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
    /* ⛔ 顺序：**先清空、再写失败说明**。原来写法是反的（先赋值、紧接着 `= ''`）⇒ 那句
     * 「有几个版本没能拿到这份数据」**一次都没显示过** —— 不报错、不留痕，只是永远看不见。 */
    this.isolationNote = extraFails.length > 0
      ? ('隔离已经打开，但有几个版本没能拿到这份数据：' + NL + extraFails.join(NL))
      : '';
    this.showIsolationAsk = false;
    this.pendingGranularity = '';
    this.copyTargets = [];
    this.copyPicked = [];
    /* **刷新** —— 这一句是 2026-10-02 报上来的缺口：复制**其实成功了**（日志 `copied 14 dir(s) /
     * 188 file(s)`）但界面没重算 ⇒ 存档列表、版本列表全停在旧值 ⇒ 玩家得出结论「复制不成功」。
     * ⭐ 功能做完了但没刷新，与功能坏了在界面上长得一模一样 —— 凡是会改变「界面依据什么来算」
     * 的动作都必须显式重算一次，⛔ 不能指望 @State 自己发现文件系统变了（它不会）。 */
    this.refresh();
  }

  /** 询问里选了「从空开始」。原数据留在原处（关掉隔离还能看到），新目录是空的。 */
  private applyIsolationEmpty(): void {
    this.granularity = this.pendingGranularity;
    writeGranularity(this.filesDir, this.granularity);
    this.isolationNote = '';
    this.showIsolationAsk = false;
    this.pendingGranularity = '';
    /* 与「复制过去」同一条道理：这条路也换了数据目录，界面必须重算。⚠️ 界面上会**看起来像空的**
     * —— 那是真的（玩家选的就是「不复制」），但必须是**新目录的空**，而不是停在旧目录的内容上。 */
    this.refresh();
  }

  /* ⭐⭐ 「隔离开着，但**当前版本那一档**还是空的」—— 给它一个出口。复制只发生在**改粒度**
   * 那一刻，而换 jar（键从 `bundled` 变成 `b159`）发生在改完粒度之后、粒度没变 ⇒
   * `chooseGranularity` 第一行就 return、再也不弹那个窗 ⇒ 新键那份目录没有任何代码路径去建它。
   * ⭐ 实测（2026-10-02 同一台平板）：`isolation: bridge written -- enabled=1 key=b159`，而
   * `instances/` 下只有 `bundled` 与 `n8`（STALE 日志说 b159 那个目录 does not exist）。
   * 判据（老账「门关上了也要有开它的路」）：目标目录空是一个**状态**，就必须有一个只针对它的出口。
   * ⭐ 为什么是**内嵌的一块**而不是弹窗：状态一出现它就一直在（切页签、切版本回来都还在），
   * 弹窗只在那一刻响一次、手一滑关掉就再也找不到；换一个 jar ⇒ 目标目录又空了 ⇒ 这块又出现。
   * ⛔ 只补当前版本这一个键，别的键一律不动，已有的数据一律不覆盖。 */
  private copyStaleCurrent(): void {
    /* ⛔ 搬移中不给点（同那个开关的防呆）—— 它俩都在搬同一批数据。 */
    if (this.storageBusy) {
      return;
    }
    this.staleCopyNote = '';
    const res: GameResolution = resolveGame(this.filesDir, this.bundleCodeDir);
    const key: string = resolveGameDirAndKey(this.granularity, res.source, res.path,
                                             this.bundledJar()).key;
    if (key === '') {
      /* 不隔离时这一块根本不显示；走到这里说明状态刚好变了。⛔ 不要硬造一个键 ——
       * 那会造出一个游戏根本不会去读的目录。 */
      this.staleCopyNote = '现在没有开启隔离，没有可以复制进去的分类';
      this.refresh();
      return;
    }
    /* ⭐ 同样**先让出一帧**再搬 —— 理由见 `askStorageSwitch`：同步搬移会把 UI 线程占住，
     * 不许让出的话，那两个按钮**没有机会变灰**，玩家看到的就是「点下去卡一下」。 */
    this.storageBusy = true;
    setTimeout(() => {
      const note: string = copyLiveDataInto(key);
      this.storageBusy = false;
      if (note !== '') {
        this.staleCopyNote = note;
      } else {
        this.isolationNote = '已经把数据复制进这一档（' + key + '）。';
      }
      /* 必须显式重算 —— 复制成功后这块会**自己消失**、存档列表会当场填上。⛔ 不刷新的话，
       * 「复制成功」与「什么都没发生」在界面上长得一模一样。 */
      this.refresh();
    }, 50);
  }

  /* 上面那个状态的界面。⭐ 零参 `@Builder`，所以**设置页与存档页可以共用同一份**
   * （开头那条「带参数的 @Builder 不会因状态变化重跑」只针对带参数的那种）。 */
  @Builder
  StaleCopyOffer() {
    Column() {
      /* ⭐⭐ 2026-10-04 按用户给的文案定稿（他原话：「开启隔离后，数据未迁移到当前版本。
       * 选项：复制过去；忽略」）。此前那一版是我自己收的，他不要。
       * ⚠️ 颜色仍是常规色而非 warning：这是**一个状态 + 两个选项**，不是错误 ——
       *    整块报警色会让人以为出了事，而其实什么都没坏。 */
      Text('开启隔离后，数据未迁移到当前版本')
        .fontSize(14).fontColor($r('sys.color.font_primary'))
        .width('100%')

      /* 失败时**留在这块里**说清楚 —— 失败意味着状态没变、这块还会在。⛔ 不写成弹窗：
       * 失败一次就弹一次的话，玩家得先关掉窗才看得见下面还有什么。
       * ⭐ 这一条**保留**警告色：它才是真的出事了。 */
      if (this.staleCopyNote !== '') {
        Text(this.staleCopyNote)
          .fontSize(12).fontColor($r('sys.color.warning'))
          .width('100%').margin({ top: 6 })
      }

      /* ⭐⭐ 按钮**必须比正文小**。原来用 `BUTTON_FONT_VP`（16）⇒ 按钮上的字**比要读的正文（12）还大**，
       * 加上 `Button` 默认 40vp 高，整块看起来是「一句话 + 一个和它一样大的色块」。
       * ⇒ 字号降到 14、高度压到 34（⛔ 不走 `BUTTON_FONT_VP`：那个常量同时管着 10 个**主**按钮，
       *   这里是个次要出路，不该跟着它们一起定）。
       * ⚠️ 34vp 低于 48vp 那个最小触控目标 —— 有意的取舍：它够宽（左右各 18vp 内边距），
       *    而这块提示本身不该在屏幕上占掉主按钮的分量。 */
      /* ⭐ 两个选项。「复制过去」是**主**动作（填色），「忽略」是次级（描边感：卡片底色）。
       * ⚠️ 两个都不走 `BUTTON_FONT_VP` —— 那个常量管着 10 个主按钮，这里是提示里的出路，
       *    字号 14 / 高 34 是刻意的（用户 2026-10-04：「按钮相较文字提示过大」）。 */
      Row() {
        Button('复制过去')
          .fontSize(14)
          .height(34)
          .padding({ left: 18, right: 18 })
          .enabled(!this.storageBusy)
          .onClick(() => { this.copyStaleCurrent(); })
        /* 「忽略」只把这一块收起来，**不动任何文件** —— 所以它不需要二次确认，
         * 也不需要「出口」：状态一变提示会自己回来（见 `refresh()` 里那次复位）。 */
        Button('忽略')
          .fontSize(14)
          .height(34)
          .padding({ left: 18, right: 18 })
          .fontColor($r('sys.color.font_secondary'))
          .backgroundColor($r('app.color.launcher_card'))
          .margin({ left: 8 })
          .enabled(!this.storageBusy)
          .onClick(() => { this.staleIgnored = true; })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
      .margin({ top: 10 })
    }
    .width('100%')
    .padding(14)
    .borderRadius(CARD_RADIUS_VP)
    .backgroundColor($r('app.color.launcher_bg'))
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: 16 })
  }

  /* 那个文件夹就绪了，重读一遍。
   * ⚠️ 只在 true 时重读（父组件只会把它从 false 翻到 true，这个判断其实是冗余的；留着是因为
   * 那个形状若哪天被改成双向，它就是唯一挡住无谓重读的东西）。
   * ⚠️ 重读是【幂等】的：`refresh()` 只按当前磁盘重算、不写任何东西 ⇒ 玩家等待期间点过的选择不会被抹掉。 */
  onFolderSettled(): void {
    if (this.folderSettled) {
      this.refresh();
    }
  }

  /* 应用自己的显示名 —— 也就是文件管理器给那个文件夹看的名。
   * ⭐ 实现搬去了 `utils/AppLabel.ets`：游戏里那个 About 卡片也要同一个名字，
   * 而两处各写一份就会漂移（2026-10-03 实测到过：一处走资源、一处写死，
   * 改名之后同一块屏幕上出现两个名字）。 */
  private resolveAppLabel(): string {
    return appLabel(getContext(this) as common.Context);
  }

  /* 弹窗宽度（vp）。两个弹窗都用它 —— 一处拥有这个规则，不然两处会各自漂移。
   * ⚠️ `winW` 在 onAreaChange 之前是 0，那时返回下限；它是 @State，量到宽度后 build 重跑即到位。 */
  private dialogWidthVp(): number {
    return Math.max(DIALOG_MIN_VP, this.winW * DIALOG_WIDTH_FRACTION);
  }

  /* 一个页签项 —— 用【原生】`BottomTabBarStyle`，不是自定义的 `@Builder`。
   * ⛔ 走过的弯路：自定义 @Builder 图标能显示但**没有按下去的反馈**（`tabBar()` 收到自定义 builder 时
   * 系统就不再绘制它自己的页签项，按压高光与沉浸光感只存在于系统画的那一个里）；自己补 `stateStyles`
   * 时编译器内部崩过一次（`Node must have a real position`），修好后效果也是假的（一个半透明方块）。
   * ⇒ 正解：图标交给 `TabBarSymbol`、页签项交给 `BottomTabBarStyle`，让系统去画它自己的页签 —— 按压、
   * 选中高亮、与 `barFloatingStyle` 那层沉浸光感的配合就都是原生的了。
   * ⭐ 颜色没丢：`TabBarSymbol` 的 `normal` / `selected` 两个 `SymbolGlyphModifier` 正好接住原来那套
   * 「未选中用次要色 / 选中用品牌色」。⚠️ 图标仍是 `$r('sys.symbol.*')`（矢量、与字体无关）。 */
  private tabItem(symbol: Resource, label: string): BottomTabBarStyle {
    /* **系统符号，不是 emoji。** 之前用 🎮 / ⚙️ —— 那是**字符**，由字体决定长相（有的设备
     * 是彩色 emoji、有的是单色轮廓），且**跟着系统字体漂移**。
     * `$r('sys.symbol.*')` 是鸿蒙自己的矢量图标：扁平、随主题变色、**与字体无关**（AMCL 也用这一套）。
     * ⚠️ 名字是在 SDK 资源索引里核过的（`house_fill`、`gearshape_fill` 都在），且编译器会校验：
     * 写错名字报 `Unknown resource name`。 */
    const marks: TabBarSymbol = {
      normal: new SymbolGlyphModifier(symbol).fontColor([$r('sys.color.font_secondary')]),
      selected: new SymbolGlyphModifier(symbol).fontColor([$r('sys.color.brand')]),
    };
    return new BottomTabBarStyle(marks, label);
  }

  /* 内置那份游戏 jar 的路径 —— 它参与**算隔离键**（同版本要合并）。
   * ⚠️ 做成方法是为了让「合并规则用的是哪一份内置」只有一处。 */
  private bundledJar(): string {
    return bundledGamePath(this.bundleCodeDir);
  }

  /** 重新读一遍磁盘。文件夹在这里【再确认一次】存在，因为玩家可能刚把它删掉。 */
  /* 把外观偏好应用到系统。⭐ 两个开关合成**三个**状态，正好对上 `ConfigurationConstant.ColorMode`
   * 的三个常量（本地 SDK `@ohos.app.ability.ConfigurationConstant.d.ts:48/57/66`）。
   *
   * ⚠️⚠️ **必须在页面加载完之后调**：`ApplicationContext.setColorMode()` 的文档写明
   *    「ensure that the window has been created and the page corresponding to the UIAbility has
   *    been loaded」（`ApplicationContext.d.ts:305-312`）⇒ ⛔ 不能放进 `EntryAbility.onCreate`。
   *    从本文件（页面）里调它是安全的，这正是 `refresh()` 所在的位置。
   *
   * ⚠️⚠️ **它不跨进程保留** —— 文档没说它会，而实测行为也是回到系统默认 ⇒ 所以每次启动都要
   *    重新应用一次（这就是它被 `refresh()` 调用的原因），而不是只在玩家拨开关时调。
   * ⛔ 少这一次重放，「强制深色」就只在本次会话有效、下次打开变回系统色，而界面上开关还开着。
   *
   * ⚠️ 取 context 走 `getUIContext().getHostContext()`（本工程既有的那条没废弃的路，
   *    见 `Index.ets:940-944` 的说明）；它可能返回 undefined ⇒ 检查它，别强转后直接用。 */
  private applyColorMode(): void {
    const mode: ConfigurationConstant.ColorMode = this.darkFollow
      ? ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET      // -1：跟随系统
      : (this.darkOn ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
                     : ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
    const ctx: common.UIAbilityContext | undefined =
      this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (ctx === undefined) {
      /* 还没挂到 ability 上。不是错误 —— 但要说出来，否则「开关没反应」会看起来像逻辑写错了。 */
      hilog.warn(DOMAIN, TAG, 'appearance: no ability context yet -- color mode not applied');
      return;
    }
    try {
      ctx.getApplicationContext().setColorMode(mode);
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'appearance: setColorMode(%{public}d) failed (%{public}s)',
                 mode, err.message);
    }
  }

  /* ⛔ 这里原来有两个方法：`storageUsedLine()`（「游戏上次启动用的是：…　← 需要重启游戏才会生效」）
   * 和 `storageUsedMismatch()`（给那行上警示色）。**2026-10-04 整行删了。**
   *
   * 用户的理由：**切换时游戏进程肯定是关着的** —— 而这条比听上去更强：
   *   启动器的设置页与游戏**不可能同时在跑**（同一个应用、同一个进程）⇒ `usedUserHome()`
   *   读到的永远来自**上一次**启动，**不存在活的冲突**。
   * ⭐ 那行当年存在的理由是「界面上说的和实际用的会分叉」，而在这个功能里那个分叉
   *   **构造上不可能出现** ⇒ 它是句废话，还把界面弄长了一行。
   * ⚠️ **`usedUserHome()` / `usedUserHomeReason()` 仍然在调用** —— 它们进
   *   `dumpStorageState()` → `storage_state.txt` 给 hdc 读。那是**排查通道**，
   *   与「界面上要不要显示」是两件不同的事：⛔ 别因为界面不显示了就把那条路也删掉，
   *   否则出问题时**只剩眼睛**可看（本应用的 hilog 读不到）。 */

  /* 拨存储位置那个开关。
   * ⭐ 顺序：**先探针、再问要不要搬、最后才落盘**。任何一步不过就什么都不改。 */
  /* 把开关控件拉回**意图**那一档。
   * ⛔ **任何「没有真正提交」的出口都要调它** —— 见 Toggle 那段的说明：控件的视觉状态不会
   *    因为「意图没变」而自己回去。 */
  private syncStorageToggle(): void {
    this.storageToggleOn = (this.storageIntent === STORAGE_MODE_EXTERNAL);
  }

  private askStorageSwitch(on: boolean): void {
    /* 控件可能因为别的重渲染回调一次与当前值相同的状态 ⇒ 先挡掉，否则会白弹一个询问窗。 */
    if (on === (this.storageIntent === STORAGE_MODE_EXTERNAL)) {
      this.syncStorageToggle();
      return;
    }

    /* ⭐⭐ **先把控件状态记成玩家刚拨到的这一档。这一步是承重的，别删。**
     *
     * ⛔⛔ 2026-10-04 我在这个问题上错了**两次**，两次都是同一个机制：
     *    `Toggle` 只在**绑定值发生变化时**才重新应用视觉状态。而「取消」那条路上
     *    `storageIntent` 没变 ⇒ `syncStorageToggle()` 算出来还是 `false`、**和之前同一个值**
     *    ⇒ ArkUI 认为无事发生 ⇒ **控件照旧停在「开」**（用户两次都看到这个）。
     *    ⭐ 我第一版甚至连 state 都没有（绑的是 `storageIntent` 的表达式）；
     *      第二版加了 state 但那个 state **从头到尾没变过** —— 都一样坏。
     * ⇒ **判据：要靠状态把控件弹回去，那个状态就必须在「拨了」与「没拨」两个值之间
     *    真的动一次。** 只提供一个「正确的值」是不够的。
     * ⚠️ 所以这里先设成 `on`（此时与控件自己的视觉一致、所以看不出变化），
     *    而在**任何取消路径**上再设回意图那一档 —— 那一次才是真的变化，控件才会弹回去。 */
    this.storageToggleOn = on;

    if (on) {
      /* ⛔ **外置必须先过探针**：那是「native 能不能在那儿写」的闸门，而且它返回的是
       * **字符串**（五种处境），不是布尔 —— 原样显示，别压成「不可用」。 */
      const p: string = probeExternalRoot(this.filesDir);
      if (!p.startsWith('ok')) {
        this.storageNote = '外置不可用：' + p;
        this.syncStorageToggle();      /* 刚设成 true，这里设回 false ⇒ 值真的变了 ⇒ 弹回去 */
        return;
      }
    }
    /* ⭐⭐ **拨完就直接搬**（用户 2026-10-04：「把提示框删了，这个就没用了」）。
     *    ⛔ 原来这里弹一个确认窗，而它只剩「搬过去 / 取消」两个按钮 —— 一个动作的窗
     *    只是多一次点按。删掉之后：**拨开关 = 立刻搬**。
     *
     * ⚠️⚠️ **这里有一个已知的、用户接受的取舍**：不再有确认，而搬会**删掉旧位置那份**。
     *    可恢复性靠三样：① 复制**全部成功才删源**（中途失败源完好，重试即可）；
     *    ② 搬反方向就是搬回来；③ 垃圾站留在沙箱、永远不跟着走。
     *    ⛔ 别因为「太危险」就自己把确认窗加回来 —— 那是用户明确要去掉的东西。
     * ⭐ **失败**仍然要说（用户 2026-10-04：「除非失败了才弹提示」）—— 见下面 `storageNote`。 */
    this.storageNote = '';
    const from: string = gameDataRoot(this.filesDir);
    const to: string = gameDataRootFor(this.filesDir,
                                       on ? STORAGE_MODE_EXTERNAL : STORAGE_MODE_SANDBOX);

    /* ⭐⭐ **防呆：搬移期间把开关置灰、不给点**（用户 2026-10-04）。
     *
     * ⛔⛔ **不能直接在这下面调 `migrateGameData`，否则那个灰色永远看不到。**
     *    搬移是**同步**的 —— 它在这一个事件回调里从头跑到尾，UI 线程被占着，
     *    ArkUI **没有机会画出「置灰」那一帧**：先 `true` 再 `false`，中间没有渲染点，
     *    玩家看到的只是「点下去卡一下」。
     * ⇒ 所以**先让出一帧**（`setTimeout`）：置灰 → 渲染出去 → 再开始搬。
     *    这也是唯一能给出可见反馈的办法 —— 搬移没有进度回调。
     * ⚠️ 那之后 UI 仍然会**冻结一小段**（同步 IO，写 250 来个文件），这是已知的、
     *    可接受的：冻结的时长与搬移时长相同，而它现在**有一个明确的视觉前因**
     *    （开关已经灰了），不再是「点下去没反应」。⛔ 要彻底不卡只能把搬移挪进
     *    worker，那是另一件事，别顺手做。 */
    this.storageBusy = true;
    setTimeout(() => {
      const err: string = migrateGameData(from, to);
      this.storageBusy = false;
      if (err !== '') {
        /* ⛔ 没提交 ⇒ 控件必须弹回去（同探针不过那条）。 */
        this.storageNote = err;
        this.syncStorageToggle();
        return;
      }
      writeStorageMode(this.filesDir, on ? STORAGE_MODE_EXTERNAL : STORAGE_MODE_SANDBOX);
      /* ⭐ `refresh()` 会把控件同步到新的意图，并把状态文件重写一遍。 */
      this.refresh();
    }, 50);
  }

  /* 把隔离/存储/语言的桥**立刻重写一遍**。
   *
   * ⛔ **为什么拨完开关要马上写**：native 在**启动那一刻**读这个文件，所以「拨完到下次启动」
   *    之间那个窗口里，文件里还是旧值。玩家完全可能拨完就点「启动游戏」—— 那时这次启动用的
   *    仍是旧的语言。⛔ 不重写就等于「开关看起来生效了，但这一次没用上」。
   * ⭐ 与 `EntryAbility.onCreate` / `Index.ets` 启动前那两处**算的是同一套输入**
   *    （当前粒度 + 当前解析到的游戏），所以三处写出来的内容一致。
   * ⚠️ 它自己吞掉异常 —— 与那两处一样，绝不因为写不了桥而拦住什么。 */
  /* 滑条松手：存偏好，并**立刻**把值写进游戏那份 settings.bin。
   * ⚠️ 只有松手才写（`End` / `Click`）—— 拖动中每次变化都写盘会写上百次，而这是块闪存。
   *    同 `writeSafePref` 那条既有规矩。 */
  private saveGameDisplay(): void {
    const p: GameDisplayPref = { edge: this.gameEdge, scale: this.gameScale,
                            auto: this.gameAuto };
    writeGameDisplay(this.filesDir, p);
    this.gameDisplayTried = '';        /* 值变了 ⇒ 让下面那个缓存失效，立刻重算一次 */
    this.applyGameDisplayNow();
  }

  /* 把当前偏好落进游戏那份 settings.bin。
   * ⛔ 目标是**游戏真正在读的那个数据目录**（`resolveGameDataDir`），不是沙箱也不是「当前根」
   *    —— 隔离开着时每个版本各一份 settings.bin，写错地方等于没写。 */
  private applyGameDisplayNow(): void {
    const dataDir: string = resolveGameDataDir(this.granularity, this.resolution.source,
                                              this.resolution.path, this.bundledJar());
    /* ⭐ **只有一个避让值**（`gameEdge`）—— 自动适配算出来的也是写进它，见 `seedGameEdgeFromDevice`。
     *    ⇒ 滑条无论自动开着还是关着都**真的生效**。 */
    const pref: GameDisplayPref = { edge: this.gameEdge, scale: this.gameScale, auto: this.gameAuto };
    /* ⭐ 缓存键里**带上 dataDir**：换版本 / 换粒度 / 换存储根都会指到另一个 settings.bin，
     *    而那一次必须重新尝试写入。 */
    const key: string = dataDir + '|' + String(pref.edge) + '|' + String(pref.scale);
    if (key === this.gameDisplayTried) {
      return;
    }
    this.gameDisplayTried = key;
    const note: string = applyGameDisplay(dataDir, this.filesDir, pref,
                                          readAppliedGameDisplay(this.filesDir));
    /* ⚠️ 只在**出错**时给提示 —— 成功是常态，不该在界面上说话。 */
    if (note !== this.gameDisplayNote) {
      this.gameDisplayNote = note;
    }
  }

  private rewriteBridge(): void {
    try {
      const k: GameDirForKey = resolveGameDirAndKey(this.granularity, this.resolution.source,
                                                    this.resolution.path, this.bundledJar());
      writeIsolationBridge(this.filesDir, this.granularity, k.key);
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'bridge: rewriting it after a settings change failed (%{public}s)',
                 err.message);
    }
  }

  private refresh(): void {
    /* ⭐⭐ **第一件事**：把游戏数据根告诉 `Isolation`（2026-10-04 起可切换）。
     * ⛔ **必须在任何算出游戏数据目录的调用之前** —— 它下面紧接着就会用
     *    `resolveGameDataDir()` / `liveGameDataDir()` 去列存档，而那两个读的就是这个根。
     *    顺序反了 ⇒ 这一次刷新列的还是**上一个根**的存档，界面看起来正常、内容却是旧的。
     * ⚠️ 根只有这一处设：别在事件处理里也调一次（两处赋值 = 两份真相，且不知道谁后跑）。 */
    setGameDataRoot(gameDataRoot(this.filesDir));
    /* ⚠️ 紧接着把根建出来（外置那一层可能是新的）。⛔ 顺序仍在任何「算游戏数据目录」之前 ——
     * 理由同上面那条。失败不拦：native 那边还有一道 mkdir + 回退。 */
    ensureGameDataRoot(this.filesDir);

    ensureGameJarDir(this.filesDir);
    this.games = listGameJars(this.filesDir);
    this.selected = readSelection(this.filesDir);
    this.resolution = resolveGame(this.filesDir, this.bundleCodeDir);
    this.bundledVer = bundledGameVersion(this.bundleCodeDir);
    this.hasBundled = hasBundledGame(this.bundleCodeDir);
    /* ⭐ 设置页那一行的说明：与版本列表同一批算好。⚠️ 它按 `this.granularity`（当前档），
     * 而弹窗那份按 `pendingGranularity`（待确认档）—— 两者在玩家正切换时不同，不能共用。 */
    this.granularityHintText = this.granularityHint(readGranularity(this.filesDir));

    /* ⭐ 外观：先读偏好、再应用。**每次 refresh 都要重放一次** —— `setColorMode` 不跨进程保留
     * （理由见 `applyColorMode`）。⚠️ 只在「读到的值与当前 State 不同」时才写 State，
     * 否则每次 refresh 都会改 State、多触发一轮重渲染。 */
    const ap: AppearancePref = readAppearance(this.filesDir);
    if (ap.follow !== this.darkFollow) { this.darkFollow = ap.follow; }
    if (ap.dark !== this.darkOn) { this.darkOn = ap.dark; }
    this.applyColorMode();

    /* ⭐ 存储位置：读**意图**（本页的设置）+ 读**实际**（native 上次启动记下的那份）。
     * ⚠️ 那个 `dumpStorageState` 是**这个功能唯一能被 hdc 读到的地方** —— 本应用的 hilog 读不到
     *    （既有笔记），所以这三行必须落成文件，否则「数据到底落在哪」只能靠眼睛看界面。
     * ⛔ 只在内容变了时写：它在 `refresh()` 里，而每渲染周期写一次文件本身就是卡顿源。 */
    this.storageIntent = readStorageMode(this.filesDir);
    /* ⭐ 开关控件跟**已确认的意图**对齐。它同时覆盖两件事：进页面时的初值、以及
     * 「切换成功」之后（本函数是 `confirmStorageSwitch` 的最后一步）—— 所以成功那条路
     * 不需要单独调 `syncStorageToggle()`。 */
    this.syncStorageToggle();
    this.storageUsed = usedUserHome();
    this.storageUsedReason = usedUserHomeReason();

    /* 存档。⚠️ 目录**取决于隔离状态** —— 用与 native 算 `user.home` 同一套输入，否则这里会列出
     * 另一份存档，那是最坏的一类不一致：界面上看起来完全正常。⚠️ 两者仍可能分叉：玩家改了粒度
     * 但还没重启时，游戏那边还是旧目录。 */
    const dataDir: string = resolveGameDataDir(this.granularity, this.resolution.source,
                                              this.resolution.path, this.bundledJar());
    const dir: string = dataDir + '/saves';
    this.savesDirShown = dir;
    this.saves = listSaves(dir);

    /* ⭐ 游戏语言（2026-10-04）。界面上只有标题 + 开关，所以这里只需读偏好。
     * ⚠️ 那两样**曾经**在这里算：翻译好的值（`gameLocaleValue`）与「游戏那份 settings.bin
     *    里已经写死了什么」（`gameLocalePinned`）—— 它们只喂那段被删掉的解释文字。
     *    ⛔ 别因为「也许以后要显示」就留着：留着的是**每次 refresh 都要问一次 i18n、还要读
     *    一次游戏正在读的那个 settings.bin 头部**的代价，而当前没有任何界面用到它们。
     *    ⭐ 真需要看游戏那份写的是什么，`storage_state.txt` 里每个数据目录都有 `locale=` 一行
     *      （`dumpDataDirs` → `settingsLocaleIn`），那条路才是排查用的。 */
    this.gameLocaleFollow = readGameLocaleFollow(this.filesDir);
    /* ⭐ 游戏内显示：先读偏好，再落进游戏（`applyGameDisplayNow` 自己有缓存，重复调用很便宜）。
     * ⚠️ 必须在 `dataDir` 解得出来之后 —— 它内部要算同一件事。所以放在这一段的**末尾**。 */
    /* 游戏内显示：读偏好 + 落进游戏。⚠️ 排在 `dataDir` 之后（上面刚解出来）。 */
    {
      const gd: GameDisplayPref = readGameDisplay(this.filesDir);
      if (gd.edge !== this.gameEdge) { this.gameEdge = gd.edge; }
      if (gd.scale !== this.gameScale) { this.gameScale = gd.scale; }
      if (gd.auto !== this.gameAuto) { this.gameAuto = gd.auto; }
      /* ⭐ 自动开着时**补种一次**：覆盖「开关是在探测完成之前拨的」那种情况
       *    （那时 `safeDetected` 还是 false、算不出来）。已经算过就不动，所以不会抹掉微调。 */
      if (this.gameAuto) {
        this.seedGameEdgeFromDevice();
      }
      this.applyGameDisplayNow();
    }

    /* 「开关拨过去了、数据没过去」。判据是两条**都**成立：① 隔离开着；② **蓝图 / 自制地图
     * 只在未隔离那棵树里**（那说明玩家一直在用的是未隔离那一份，而游戏现在读的是隔离目录）。
     *
     * ⛔⛔ **这个判据的形态改过两次，两次都是被同一个机制打败的**（2026-10-04 实测）：
     *     · 第一版：`!gameDataExists(dataDir)` —— **游戏每跑一次就会在那个目录里写一份
     *       `settings.bin`** ⇒ 目录立刻「存在」⇒ 判据**从第一次启动之后永久为假**，提示一次没出现过。
     *     · 第二版：改成「目标目录里没有玩家的东西（存档/模组/蓝图）」—— 仍然不对，因为
     *       **存档两棵树各自都会长出来**。实测形状：当前隔离目录里 **40 个 `.msav`（整个战役）**，
     *       未隔离那棵里 **53 KB 的设置 + 27 张蓝图 + 1 张自制地图、零存档** ⇒
     *       用「有没有存档」去问「哪一棵是他在用的」，答案正好是反的。
     * ⭐ 现在只问**蓝图与自制地图**（`.msch` / `maps/*.msav`）—— 那两样**只有玩家会放进去**。
     * ⭐ 一般化：**判据要落在「游戏不会自己生成的东西」上。** 凡是游戏自己会写的文件
     *    （`settings.bin`、存档、`steam_autocloud.vdf`），都只能证明「游戏在这里跑过」，
     *    不能证明「玩家的东西在这里」。 */
    this.isolationStale = (this.granularity !== GRANULARITY_OFF)
                       && !hasUserMadeFiles(dataDir)
                       && hasUserMadeFiles(liveGameDataDir());
    /* ⭐⭐ 存储位置那几行落盘（**放在这里**，因为 `stale` 也是它的一部分）。
     * ⚠️ 它**刻意排在 `isolationStale` 之后**：那个标志决定界面上有没有那条「数据没搬过来」的
     *    提示，而**本应用的 hilog 读不到** ⇒ 不写进这个文件，「提示到底有没有出现」就只能
     *    靠眼睛看屏幕。⛔ 别为了「就近」把它挪回上面去。 */
    this.dumpStorageDiagnostics();

    /* ⚠️ 只在**异常**时才记一行 —— 那正是需要日志的时候，一旦修好就自动安静。
     * ⭐ 它把「界面上有没有那条警告」变成一条**能读出来的**事实，不必靠眼睛看屏幕。
     *    ⚠️ 但**读得出来的那条是 `storage_state.txt` 里的 `stale=`** —— hilog 读不到。 */
    if (this.isolationStale) {
      hilog.error(DOMAIN, TAG, 'isolation: STALE -- %{public}s has no player data, '
                + 'but the un-isolated tree %{public}s does',
                dataDir, liveGameDataDir());
    } else {
      /* ⭐ 状态解除了 ⇒ 把「已忽略」一并复位。⛔ 不复位的话，下次真的又出现这个状态时，
       *    提示会被上一次的忽略静默吃掉 —— 而那正是最需要它出现的时候。 */
      this.staleIgnored = false;
      /* 状态解除了 ⇒ 上一次那句「没复制成功」不再关于任何东西 —— 清掉。⛔ 不清的话它会一直挂在
       * `StaleCopyOffer` 里，等下一次出现空的档位时重新露出来，而那时它说的是另一个键的事 ——
       * 一条关于旧状态的错误消息比没有消息更坏：它指向一个已经不存在的问题。 */
      this.staleCopyNote = '';
    }
    /* ⚠️ 版本列表要在 `resolution` / `hasBundled` / `games` **都算好之后**才能建（三样都用），
     * 而建它的那一步会**读每个 jar**（见 versionEntryOf）⇒ 整轮 refresh 只建一次，渲染只用结果。 */
    this.versions = this.buildVersions();
    /* 选中的版本没了（jar 被删了）⇒ 退回当前版本，别让右边空着。
     * ⚠️ 「当前版本」一定在这一批里（要么内置、要么来自 games），这个兜底是可靠的。 */
    if (this.selectedVersion === ''
        || !this.versions.some((v: VersionEntry) => v.path === this.selectedVersion)) {
      const cur: VersionEntry | undefined = this.versions.find((v: VersionEntry) => v.isCurrent);
      this.selectedVersion = cur === undefined ? '' : cur.path;
    }
    this.loadVersionSaves();
    /* 垃圾站：**清掉到期的**，再读一遍名单。
     * ⚠️ 放在 `refresh()` 里而非渲染里 —— 它要扫目录、还要真删文件，⛔ 每帧跑一次不可接受。 */
    this.reloadVault();
    this.vaultDays = readVaultDays(this.filesDir);
    /* 「按存档」那一屏的数据 —— **所有版本**的存档，按数据目录分组。
     * ⚠️ 必须在 `this.versions` 算好之后（它逐个版本解目录），见 buildSaveGroups。 */
    this.saveGroups = this.buildSaveGroups();
    /* **清失效的选中**放在这之后 —— 它要拿 saveGroups 去查那一行还在不在。
     * ⚠️ 换隔离粒度、删掉一个存档、切换版本，都会让原来那一行消失。 */
    if (this.selectedSave !== '' && this.selectedSaveRow() === undefined) {
      this.selectedSave = '';
    }
    /* ⚠️ 必须显式再读一次。`@Watch` 只在 id **真的变了**时才触发，而这里的常见情形恰恰是
     * 「id 没变、那份存档换了」—— 改了隔离粒度再回来，列表整份换掉，但选中的若两边同名 id 就一样；
     * 那时右侧栏会**显示上一个目录的元数据**，而界面上完全看不出不对。 */
    this.loadSelectedMeta();
    this.jarDirHint = gameJarDir(this.filesDir);
    /* ⚠️ 父文件夹叫 `Download`（单数）—— 这是**磁盘上的名字**，不是英文惯用的 "Downloads"。
     * 判据：`user_dirs.txt` 里记的是 `/storage/Users/currentUser/Download/<包名>`，
     * 而 `Environment.getUserDownloadDir()` 也返回 `.../currentUser/Download` ⇒ 写复数会让玩家找错。 */
    this.jarDirHuman = this.jarDirHint === '' ? '' : ('Download/' + this.appName + '/games');
    hilog.info(DOMAIN, TAG, 'launcher: %{public}d jar(s), resolved=%{public}s (%{public}s)',
               this.games.length, this.resolution.path === '' ? '(none)' : this.resolution.path,
               this.resolution.source);
  }

  /** 当前选中的那个存档项；没选（或它已经不在了）时 `undefined`。 */
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

  /* 选中那一行**所在的目录** —— 每个动作都该用它。⛔ 别退回 `savesDirShown`：那是**当前版本**
   * 的目录，而列表里可能有多个版本的存档，「当前」与「选中的那个」不是一回事。 */
  private selectedSaveDir(): string {
    const r: SaveRow | undefined = this.selectedSaveRow();
    return r === undefined ? '' : r.dir;
  }

  /** 存档列表里一行的选中键。⭐ 唯一性靠**目录**，见 `selectedSave`。 */
  private saveKey(dir: string, id: string): string {
    return dir + '|' + id;
  }

  /** 选中那一行属于哪些版本。⭐ 详情面板用它写「属于：A、B」。 */
  private selectedSaveVersions(): VersionEntry[] {
    const r: SaveRow | undefined = this.selectedSaveRow();
    if (r === undefined) {
      return [];
    }
    const g: SaveGroup | undefined = this.saveGroups.find((x: SaveGroup) => x.dir === r.dir);
    return g === undefined ? [] : g.versions;
  }

  /* 下面三个是给右侧栏用的取值函数。⚠️ 为什么做成方法而**不是**在 `build()` 里声明局部变量：
   * ArkUI 的 `build()` / `@Builder` 里**不允许声明本地变量**（那些语句会被当成 UI 描述解析，
   * 编译报的是语法错）⇒ 界面上要用的每个值都得是一个能直接写进表达式的方法。 */

  /** 选中存档的显示名；没选时空串。 */
  private selectedSaveLabel(): string {
    const sv: SaveEntry | undefined = this.selectedSaveEntry();
    return sv === undefined ? '' : sv.label;
  }

  /** 一行摘要：几个区块、几个文件、多大。 */
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

  /** 「最后更新 YYYY-MM-DD」。 */
  private selectedSaveUpdated(): string {
    const sv: SaveEntry | undefined = this.selectedSaveEntry();
    return sv === undefined ? '' : ('最后更新 ' + formatSaveDate(sv.mtime));
  }

  /* `loadSelectedMeta()` 上次读的是哪一个（`id@目录`）。
   * ⚠️ 刻意**不是** `@State` —— 它不参与渲染，只是去重用的账本；做成 @State 会多一次无意义的刷新。 */
  private metaLoadedKey: string = '';

  /** `@Watch` 的落点。选中变了 ⇒ 去读那个存档的元数据。 */
  private onSaveSelected(): void {
    this.loadSelectedMeta();
  }

  /* ==================================================================
   * 「按版本」视图
   * ================================================================== */

  /* 造一个版本项。⚠️ 它**读 jar**（`resolveGameDirAndKey` 里的 `computeKey` 最终会读
   * `version.properties`）⇒ 只能从 `buildVersions()` 里调，⛔ 绝不能在渲染路径上调（每帧开一次 jar）。 */
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

  /* 列出已装的版本：**内置的排最前**，然后是玩家导入的。
   * ⭐ 内置第一：它永远在（跟着包一起发），是「玩家什么都没选」时的落点。
   * ⚠️ 数存档那一步**按目录去重** —— 隔离关着时每个版本算出来的都是同一个目录，不去重会列 N 遍。 */
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

    /* 一个目录只列一次。`Map` 而不是对象字面量 —— ArkTS 拒绝无类型对象字面量。 */
    const counted: Map<string, number> = new Map<string, number>();
    for (const v of out) {
      let n: number | undefined = counted.get(v.dataDir);
      if (n === undefined) {
        n = listSaves(v.dataDir + '/saves').length;
        counted.set(v.dataDir, n);
      }
      v.saveCount = n;
      v.hasData = gameDataExists(v.dataDir);
      /* ⭐ 每个版本记一行：标签 / 版本号 / 隔离键 / 数据目录 —— 这是「我换了版本怎么看不到存档了」
       * 的**第一手答案**：看一眼 key 就知道两个 jar 有没有落进同一个目录，而这是**光看界面推不出来**
       * 的（界面上只写版本号，不写键）。⚠️ 只在 refresh() 里跑，⛔ 不在渲染路径上。 */
      hilog.info(DOMAIN, TAG, 'version: %{public}s | %{public}s | key=%{public}s | %{public}s',
                 v.label, v.version === '' ? '(unknown)' : v.version, v.key, v.dataDir);
    }
    /* ⭐ 记一行「有几个版本、几个**不同的**数据目录」。`distinct` 是这一屏的**核心诊断**：
     * > 1 才说明隔离真的把它们分开了，= 1 就是「所有版本共用一份」（隔离关着，或粒度太粗）。
     * ⚠️ 它**不是** UI 上那个「N 个版本」（那个只数版本，说不出有没有分开）。⚠️ 只在 refresh() 里跑。 */
    hilog.info(DOMAIN, TAG, 'saves: %{public}d version(s), %{public}d distinct data dir(s)',
               out.length, counted.size);
    return out;
  }

  /* ⭐⭐ 把**所有版本**的存档按数据目录聚起来 —— 「按存档」那一屏的数据源。
   * ⚠️ 按**目录**分组而不是按版本：隔离关着时所有版本共用一份数据，按版本分会让同一批存档出现 N 遍；
   * 按目录分恰好一组，组头的版本名单正好是「属于哪几个版本」。⭐ 顺序 = `this.versions` 的顺序。
   * ⚠️ 另外补一组**未隔离的那一份**（只在它不属于任何版本时）：「复制过去」刻意不动源目录，那份原始
   * 数据会一直留着；⛔ 不列出来玩家会以为它不见了 —— 它其实是最后一道保险。隔离关着时它**就是**各版本那一组。 */
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
    /* ⭐⭐ **`instances/` 下没有版本读的那些目录也要列出来。** ⛔ 光靠 `this.versions` 推不出它们，
     * 而它们全来自**规则的改变**：换粒度（昨天的 `b160.5` 今天没有版本指向它）、换 jar、
     * 内置/同版本合并（玩家 jar 原来那个槽位立刻没人读 —— 第三种是这次改动自己会造出来的）。
     * ⚠️ 只列**真有存档**的；⛔ 也不要列已被 `byDir` 认领的（那样同一份数据会出现两遍）。 */
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
    /* ⛔ **订正（2026-10-02，用户报上来的）：空组不再丢掉。** 我原来丢掉空组的理由（「一屏 5 组、
     * 3 组空，噪音大过信息」）是我自己的判断，代价他立刻就说出来了：「我按最小粒度，只显示了内置游戏
     * 和159.7，**其他的消失了**」。⭐⭐ 真正让那个判断站不住的是后来加的东西：每一组现在都是「把未隔离的
     * 那份复制过来」的**去处**（见 `StaleCopyOffer`）⇒ 空组**不是噪音，是一个还没填的槽位**；藏起来玩家
     * 就没法把数据放进那个版本。⚠️ 判据因此从「有没有存档」换成「**有没有版本**」：有版本读的目录一律列出来。
     * ⛔ 未隔离那一份仍只在真有存档时才补（它不属于任何版本，空的时候确实没有意义）。 */
    for (const g of out) {
      hilog.info(DOMAIN, TAG, 'save group: %{public}d save(s), %{public}d version(s), %{public}s',
                 g.saves.length, g.versions.length, g.dir);
    }
    return out;
  }

  /* ⭐⭐ 一组的标题。**顺序是用户定的**（2026-10-02）：「先展示**版本**，再展示**文件名**」。
   * ⇒ 形状 `v8 Build 160.5（内置游戏, Mindustry160.5.jar）`（我上一版是反的，那个理由只在单个版本时成立）。
   * ⚠️ **一组里可能有两个不同的版本号**（构建号档下 `160.4` 与 `160.5` 折进同一槽位）⇒ 版本号要
   * 去重后**全部列出来**（`/` 分隔），⛔ 只写第一个会让 160.4 的数据看起来属于 160.5。
   * ⚠️ 版本读不出来时写「未知版本」，⛔ 不留空 —— 空着会被读成「没有版本」。 */
  private groupTitle(g: SaveGroup): string {
    if (g.versions.length === 0) {
      /* 两种「没人读」：以前某一档留下的键 vs 未隔离的那一份本身。 */
      /* ⚠️ `orphanKey` 是**内部隔离键**（`b160.5` / `n8` / `_unknown`），它长得几乎就是版本号
     *    ⇒ 原来写成「没有版本读它（b160.5）」会被读成「又一个 160.5」，而玩家可能正看着一个
     *    真叫 160.5 的分组（内置那一份）⇒ 两条看起来完全一样，用户 2026-10-03 就是这么报的。
     * ⛔ 键不能删 —— 它说明这份数据来自哪个槽位，是「它从哪来」的唯一线索。
     *    ⇒ 所以只是把「这是一个内部标记」说出来，让它不再像版本号。 */
    return g.orphanKey === ''
      ? '未隔离的那一份'
      : ('没有版本读它（内部键 ' + g.orphanKey + '）');
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

  /** 一组的副标题：谁在读它。 */
  private groupSub(g: SaveGroup): string {
    if (g.versions.length === 0) {
      if (g.orphanKey !== '') {
        /* ⭐ 说清**它从哪来**，并给出路 —— ⛔ 只说「没人读」会让玩家以为这是垃圾。
         * ⭐ 最常见的成因就是我们自己改的合并规则，所以那句要写在这里。 */
        return '这是以前某一档隔离留下的数据，现在没有版本指向它了 —— '
             + '要接着玩，就从某一组里复制/移动一份过去（或者在「按版本」那边看看谁和它同版本）';
      }
      return '现在没有版本读它 —— 这是你数据最初的那一份，「复制过去」不会动它';
    }
    /* ⭐ 标出**游戏真正会读的那一份**（当前版本指向的目录）。⛔ 不标的话玩家看到两堆存档会不知道
     * 哪个是「正在玩的」—— 而那正是他换粒度之后第一个要问的问题。 */
    const cur: boolean = g.versions.some((v: VersionEntry) => v.isCurrent);
    const head: string = cur ? '当前版本在用 · ' : '';
    if (g.versions.length === 1) {
      return head + '只有这个版本读它';
    }
    return head + String(g.versions.length) + ' 个版本共用同一份数据';
  }

  /* ⭐⭐ **一行存档的键** —— 全文件**唯一**的一处定义。
   *
   * 凡是「渲染某份存档的那一行」的 `ForEach`，键都必须用它：`id` 只回答「这是哪一份」，
   * 而这一行还显示**大小与时间**，那两个字段**同一份存档也会变**（玩一局游戏就把它覆盖了）。
   * ⛔ 别再在别处手写 `sv.id` 当键 —— 那个 `id` 看着像个稳定标识，**正因如此它是个陷阱**。
   * ⚠️ 三个调用点：「按版本」列表、「按存档」分组的内层、以及 `groupKey()` 内部。 */
  private saveRowKey(sv: SaveEntry): string {
    return sv.id + '|' + sv.label + '|' + sv.kind + '|' + String(sv.sectors)
         + '|' + String(sv.bytes) + '|' + String(sv.mtime);
  }

  /* ⭐ 首页那一行版本（jar）的键。同一条道理：`path` 不会变，但**同一个路径上换一个 jar 文件**
   * （覆盖同名文件）会让大小 / 时间 / 版本号全变，而那一行渲染的正是这三样。 */
  private gameRowKey(g: GameJar): string {
    return g.path + '|' + g.name + '|' + g.version + '|' + String(g.size) + '|' + String(g.mtime);
  }

  /* ⭐⭐ 「按存档」分组列表**外层** `ForEach` 的键。⛔ 不能只用 `g.dir`，理由见下。
   *
   * 机制（官方文档 `arkts-rendering-control-foreach` 的原话）：
   *   「框架**不会为保留的数组项执行项构造函数**」
   * ⇒ 键没变的那一项**不重跑项构造函数** ⇒ 它里面**嵌套的** `ForEach(g.saves, …)` 拿到的还是
   *   **旧** `g.saves`（项构造函数闭包里捕获的那个数组）。而这一层原来的键只有 `g.dir`，
   *   **删掉一个存档并不会改目录名** ⇒ 那一组被当成「保留」⇒ 删掉的那一行**留在屏幕上**，
   *   切一下页面（子树整体重建）才消失。
   * ⚠️ 2026-10-03 用户报的正是它：「按存档」下长按进多选、只勾一条，**删掉了但列表不刷新**。
   * ⭐ 这是本项目**第二次**踩同一个坑 —— 第一次是垃圾站那张列表（见它 `ForEach` 上方那段注释）。
   *
   * ⭐ 写法：**键 = 这一组渲染出来的那两行字 + 这一组每一行的 `saveRowKey()`**。
   * ⚠️⚠️ **这里必须是每一行的 `saveRowKey()`，不能只放 `s.id`** —— 这是我 2026-10-03 那一版
   *   自己犯的错：`id` 是**稳定**的（`manual:0` 永远是 `manual:0`），而**字节数与修改时间会变**
   *   ⇒ 只放 id 的话外层仍被判为「保留」⇒ 不重建 ⇒ 内层更不会跑，那一行就一直显示旧的
   *   「多大 / 什么时候存的」。⭐ 判据：**外层键要覆盖内层渲染的一切** —— 外层不重建时，
   *   内层**根本没有机会**跑，内层的键写得再对也没用。
   * ⛔ 故意**不逐字段列**（目录、孤儿键、版本名单、`isCurrent`、存档 id…）：那种写法**漏一个字段
   *   就复发一次**；而「组头那两行」正好是 `groupTitle` / `groupSub` 的返回值 ⇒ 它们就是
   *   渲染依赖的**全集**，以后改组头版式也不会忘。
   * `g.dir` 放在最前面：分组本来就按目录去重（见 buildSaveGroups），它保证键唯一。
   * ⚠️ 键变 ⇒ 那一组的子树被**重建**（而不是移动）。这一组里没有需要保留的行内状态，代价可以接受。 */
  private groupKey(g: SaveGroup): string {
    const ids: string[] = [];
    for (const s of g.saves) {
      ids.push(this.saveRowKey(s));
    }
    return g.dir + '|' + this.groupTitle(g) + '|' + this.groupSub(g) + '|' + ids.join(',');
  }

  /* ⭐ 「按版本」列表 `ForEach` 的键。**同一类缺陷、同一页**：那一行渲染的是 `versionSavesLine(v)`，
   * 也就是 **`v.saveCount`** ⇒ 删掉一个存档那个数字就变了，而键原来只有 `v.path`（不会变）
   * ⇒ 数字停在旧值上。理由与修法见上面 `groupKey`。 */
  private versionRowKey(v: VersionEntry): string {
    return v.path + '|' + v.label + '|' + this.versionSavesLine(v);
  }

  /** 当前选中的那个版本项；没选或它已经不在（jar 被删了）时 `undefined`。 */
  private selectedVersionEntry(): VersionEntry | undefined {
    if (this.selectedVersion === '') {
      return undefined;
    }
    return this.versions.find((v: VersionEntry) => v.path === this.selectedVersion);
  }

  /* 读选中版本的数据目录里有哪些存档。
   * ⚠️ 这里**只列文件名**（`listSaves` 不读内容、不解压），很便宜 —— 与选中存档时那次解压不是一回事。
   * ⚠️ 它读的是**那个版本自己的**目录，而 `savesDirShown` 是**当前版本**的目录，两者在「看的是别的
   * 版本」时**不一样** ⇒ 这里绝不能借 `savesDirShown`；同理这个列表里**不做**任何元数据读取
   * （`loadSelectedMeta()` 只认 `savesDirShown`，混着用会读到另一个目录的元数据而界面上看不出不对）。 */
  private loadVersionSaves(): void {
    const v: VersionEntry | undefined = this.selectedVersionEntry();
    if (v === undefined) {
      this.versionSaves = [];
      return;
    }
    this.versionSaves = listSaves(v.dataDir + '/saves');
  }

  /** `@Watch` 的落点。切版本 ⇒ 换那一份存档名单。 */
  private onVersionSelected(): void {
    this.loadVersionSaves();
  }

  /** 还有哪些版本**和它共用同一个数据目录**（不含它自己）。 */
  private versionsSharingDir(dir: string, exceptPath: string): VersionEntry[] {
    return this.versions.filter((v: VersionEntry) =>
      v.dataDir === dir && v.path !== exceptPath);
  }

  /* 「哪些版本能看到【当前这个存档】」。⭐ 判据是**目录相等**，⛔ 不是比较版本号或 `build` ——
   * 游戏按 `user.home` 选数据目录，而它由隔离键算出来 ⇒ **「谁看得到」是一个目录问题，不是兼容性
   * 问题**，这是能确切回答的那个。⚠️「这个存档能不能被某个版本**读**」是另一件事（要看模组与版本
   * 规则），我们答不了。
   * ⚠️ 隔离关着时所有版本都指向同一目录 ⇒ 这里自然是「全部」，那是**对的**，正是「不隔离」的含义。 */
  private savesSeenByText(): string {
    const seen: VersionEntry[] = this.selectedSaveVersions();
    if (seen.length === 0) {
      /* 没有版本读这个目录 ⇒ 它是那份「未隔离的原始数据」。⛔ 不要显示成「没有」——
       * 要说清它是什么，否则玩家会以为这是个坏掉的条目。 */
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

  /** 头部那一行：视图不同，它要说的事情不同。 */
  private savesHeaderLine(): string {
    if (this.savesView === SAVES_VIEW_VERSION) {
      return this.versions.length === 0 ? '（没有可用的版本）'
                                        : (String(this.versions.length) + ' 个版本');
    }
    return this.savesDirShown === '' ? '（还没读到目录）' : this.savesDirShown;
  }

  /* 下面这些是给「按版本」那一屏的取值函数。⚠️ 做成方法而**不是**在 `build()` 里声明局部变量 ——
   * ArkUI 的 `build()` / `@Builder` 里不许声明本地变量（那些语句会被当成 UI 描述解析、编译报语法错）。 */

  /** 版本列表项第二行里那截「N 个存档」。 */
  private versionSavesLine(v: VersionEntry): string {
    if (!v.hasData) {
      return '还没有数据';
    }
    return v.saveCount === 0 ? '目录在，没有存档' : (String(v.saveCount) + ' 个存档');
  }

  /* ⭐ 这两个的**内容对调了**（2026-10-02，用户要「版本在前、文件名在后」）：`selectedVersionLabel`
   * 现在给**版本号**（手机子页拿它当标题），`selectedVersionLine` 给文件名与「当前版本」。
   * ⚠️ 名字没跟着改，因为「label / line」说的是**位置**（大字行 / 小字行）而不是内容。 */
  private selectedVersionLabel(): string {
    const v: VersionEntry | undefined = this.selectedVersionEntry();
    if (v === undefined) {
      return '';
    }
    return v.version === '' ? '未知版本' : v.version;
  }

  /** 选中版本的**文件名**那一行，附带「当前版本」。 */
  private selectedVersionLine(): string {
    const v: VersionEntry | undefined = this.selectedVersionEntry();
    if (v === undefined) {
      return '';
    }
    return this.selectedVersionIsCurrent() ? (v.label + '  ·  当前版本') : v.label;
  }

  /** 选中版本是不是当前正在使用的那个。 */
  private selectedVersionIsCurrent(): boolean {
    const v: VersionEntry | undefined = this.selectedVersionEntry();
    return v === undefined ? false : v.isCurrent;
  }

  /** 「这个目录里有 N 个存档」。 */
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

  /** 空名单时那句话：目录不在与目录空是两件事。 */
  private selectedVersionHasDataText(): string {
    const v: VersionEntry | undefined = this.selectedVersionEntry();
    if (v === undefined || !v.hasData) {
      return '还没有数据目录。';
    }
    return '还没有存档。';
  }

  /** 选中版本的数据目录。 */
  private selectedVersionDir(): string {
    const v: VersionEntry | undefined = this.selectedVersionEntry();
    return v === undefined ? '' : (v.dataDir + '/saves');
  }

  /* 「还有谁共用这一份数据」。⭐ 隔离**关着**时全部版本都会落进这一条（指向同一个目录）——
   * 那不是缺陷，正是「不隔离」的定义 ⇒ 措辞要**陈述**，不是警告。
   * ⚠️ 隔离开着时也可能共用（粒度选「大版本」而两个 jar 是同一大版本；粒度选「构建号」而两个 jar
   * 只是小版本不同）⇒ 这两句都要能自然读通。 */
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

  /* 读当前选中存档的元数据，存进 `selMetaRows`。⚠️ 会**解压一个 .msav**（`saveMetaText`），有真实
   * 成本 —— 但一次只读**一个**文件、且只在选中变化时做。⭐ **读组里最新的那个文件并把名字放进第一行**
   * （见 `metaRowsOf`）：一个 Serpulo 战役有 14 个区块文件，全解压是几 MB 的 CPU，而「这是哪个版本
   * 写的」通常指**最近在玩的那一个** ⇒ 读一个，同时让「其他区块可能不同」看得见。
   * ⚠️ 三种情形都要各自有话说，⛔ **不允许「读失败但界面上看着正常」**（无可用文件 / native 读不出来 / 正常）。 */
  private loadSelectedMeta(): void {
    const sv: SaveEntry | undefined = this.selectedSaveEntry();
    /* ⭐ 去重。读一次就是**解压一个 .msav**，而这件事会被两条路径同时触发：`@Watch`（选中变了）与
     * `refresh()` 里那次显式调用（换目录后 id 可能没变）。⚠️ 实测：不加这一句，选中一个存档会
     * **解压两遍**（日志里同一行出现两次）。⭐ 键是 `id @ 目录`：id 相同但目录换了（改完隔离粒度
     * 再回来）**要**重读，两者都没变时重读没有意义。 */
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

  /* 点一行的落点。⭐ 窄屏时**同时**打开子页 —— 手机上列表与详情放不下两栏，所以「选中」与「进去看」
   * 是同一个动作；⚠️ 宽屏时不设 `panelOpen`（那时详情一直在右边）。
   * ⭐⭐ 点**已经选中的那一行** = 取消选中（2026-10-02：「点击我选中过的，取消选中，右边界面变空」）：
   * `selectedSave` 之前**只增不减**，一旦点过任何一行右边就永远挂着一份详情，而「我不想看任何东西」
   * 这个状态**无法到达** —— 而右边那块占屏幕的三分之一（3:7 两栏），显示什么完全由很久以前的一次点击决定。
   * ⚠️ **只在单选态生效**：多选态的点击是「勾/取消勾」、走 `toggleMultiPick`（调用点已分开）——
   * 两件事都叫「取消选中」，但取消的东西不同：这里取消的是**详情**，那里取消的是**勾选**。
   * ⚠️ 窄屏（手机）**不在这里退子页**：手机上一个存档本来就是「进去看」，再点一下应当还是「看」，
   * ⛔ 不是把自己弹出去（那会让人以为点坏了）；出口是左上角那个返回箭头。 */
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

  /** 「按版本」面板里那个版本的 `saves/` 目录。 */
  private versionSavesDir(): string {
    const v: VersionEntry | undefined = this.selectedVersionEntry();
    return v === undefined ? '' : (v.dataDir + '/saves');
  }

  /** 版本列表同理。 */
  private openVersionRow(path: string): void {
    this.selectedVersion = path;
    if (this.isNarrow()) {
      this.panelOpen = true;
    }
  }

  /* ==================================================================
   * 垃圾站
   * ================================================================== */

  /* ⭐ 垃圾站**只碰自己那点数据**的重新读盘，单独一条路。
   * ⚠️ 为什么不靠 `refresh()`：那是**整页**重算（读每个 jar、扫三个目录），其中任何一步抛了，
   * 后面那些 `@State` 就一个都不会被赋值 —— 而玩家看到的正是「点了没反应」⇒ 垃圾站的动作先走
   * 这条**短**路，界面立刻是对的，`refresh()` 再去做剩下的（「取消归档和放回点了 UI 不刷新」有一半
   * 是这个形状：磁盘上确实发生了，而界面没跟上）。 */
  /** 垃圾站里**归档**的条数。清空之前要说出来 —— 那几条本来是不会自动消失的
   * （归档的定义就是「不参与自动清理，只能手动删或放回」），所以「清空」对它们是一次明确的推翻。 */
  private vaultArchivedCount(): number {
    let n: number = 0;
    for (const e of this.vaultEntries) {
      if (e.archived) {
        n += 1;
      }
    }
    return n;
  }

  /** 一键清空：逐个走 `vaultPurge`。
   *
   * ⛔ **不要**自己拼一个 `removeTree(VAULT_ROOT)` 一把删掉：那样绕过了这个模块自己的日志，
   *    而且**失败时说不清是哪一个条目出的问题** —— 而「少了几个、不知道为什么」正是垃圾站最不该有的状态。
   * ⭐ 即便有失败也重新读一遍列表：成功的那些确实已经没了，界面必须跟上，
   *    否则玩家会看着一堆已经不存在的东西。失败的那几个则**具名**写在 `vaultNote` 里。 */
  private clearVaultAll(): void {
    this.showVaultClearAsk = false;
    const total: number = this.vaultEntries.length;
    let done: number = 0;
    const fails: string[] = [];
    for (const e of this.vaultEntries) {
      const err: string = vaultPurge(e.id);
      if (err === '') {
        done += 1;
      } else {
        fails.push(e.label + '：' + err);
      }
    }
    /* ⛔ **只在失败时写 `vaultNote`**，两重理由：
     * ① 那个字段在界面里是 `$r('sys.color.warning')` —— 它是**错误通道**（别的调用点写进去的都是错），
     *    把「已清空 N 个」放进去会用警示色报一件成功的事。
     * ② 全部成功时**列表变空本身就是反馈**（那一屏会显示「垃圾站是空的」），
     *    再补一句话是冗余。而失败必须说，否则玩家只看到少了几个、不知道剩下的为什么还在。 */
    this.vaultNote = fails.length === 0
      ? ''
      : ('清掉了 ' + String(done) + ' 个；有 ' + String(fails.length) + ' 个没删掉：' + fails.join('；'));
    hilog.info(DOMAIN, TAG, 'vault: cleared %{public}d of %{public}d entry(ies)', done, total);
    this.reloadVault();
  }

  private reloadVault(): void {
    this.vaultPurgedLast = purgeExpired(Date.now());
    this.vaultEntries = listVault();
  }

  /** 打开「关于」，顺手把版本号读出来。
   *
   * ⭐ **按需读**（打开时才查），不是启动时读 —— 那次包查询在没人看之前没有意义，
   *    这条与 `Index.ets:727` 的注释是同一条规则。
   * ⚠️ 用的是**同步**那一版 `getBundleInfoForSelfSync`（`ExportDiagnostics.ets:44` 已在本项目用它），
   *    这样值在重绘前就位，不会先闪一下没有版本号的标题。
   * ⚠️ 读不到就留空串 —— 界面那边 `=== ''` 的分支就是兜底，⛔ 不要在这里编一个号。 */
  private openAbout(): void {
    this.showAbout = true;
    if (this.appVersion !== '') {
      return;
    }
    try {
      const info: bundleManager.BundleInfo =
        bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      this.appVersion = info.versionName;
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'about: version lookup failed: %{public}s', err.message);
    }
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

  /* 玩家点了「删除」。⛔ **不直接删** —— 先弹一个确认框，让他在「放进垃圾站（到期清理）」与
   * 「归档（不自动清理）」之间选一个：那两个就是垃圾站里条目的两种状态，所以这个确认框同时承担了
   * 「确认」与「选保留方式」，不需要第二个窗。⚠️ 要写出**具体保留到哪一天**（「7 天」太抽象）。 */
  /* 列出「这一档下的每一个分类」，以及谁落进它、它有没有数据。
   * ⚠️ 会读每个 jar（`gameVersionParts` 没有缓存）⇒ 只在**点开这个选择**时算一次，⛔ 不在渲染里算。 */
  private buildCopyTargets(g: string): CopyTarget[] {
    const out: CopyTarget[] = [];
    const byKey: Map<string, CopyTarget> = new Map<string, CopyTarget>();
    for (const v of this.versions) {
      const k: string = resolveGameDirAndKey(g, v.source, v.path, this.bundledJar()).key;
      if (k === '') {
        continue;   /* 不隔离 ⇒ 没有分类可复制进 */
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

  /** 分类的显示名：键 ＋ 落进它的版本。 */
  private copyTargetTitle(c: CopyTarget): string {
    const names: string[] = [];
    for (const v of c.versions) {
      names.push(v.label);
    }
    return names.join('  ·  ') + '   →   ' + c.key;
  }

  /** 分类的副标题：它现在有没有数据。⭐ 这一句是「勾了会发生什么」的答案。 */
  private copyTargetSub(c: CopyTarget): string {
    if (c.hasData) {
      return '已经有数据 —— 勾了也不会覆盖它';
    }
    return '还没有数据 —— 会复制一份当前数据进来';
  }

  /** 勾/取消勾一个分类。⚠️ 必须**赋新数组**，理由见 toggleTransferPick。 */
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

  /** 这一行现在算不算「选中」—— 多选态看 `multiPicked`，平时看 `selectedSave`。
   *  ⭐ 做成一个函数而不是两处各写一遍 if：两张列表必须**长得一样**。 */
  private rowHot(key: string): boolean {
    return this.multiMode ? (this.multiPicked.indexOf(key) >= 0) : (this.selectedSave === key);
  }

  /* ⛔ **长按与点击都要把 `selectedSave` 挪到刚碰的那一行**（2026-10-02：「长按选中时页面信息
   * 要刷新成我刚刚长按选中的。进入多选后再单点选中也是一样」）。
   * ⛔ 不改的后果就是他报的那个 bug：右边详情**还停在最开头选的那个** ⇒ 屏幕上同时有**两个
   * 「删除」**（多选条一个、详情下面单条一个），而玩家分不出哪个是哪个。
   * ⭐ 两处都改（进入时 + 已在多选态时）不是重复：它们是**两条入口**，而「详情显示哪一条」必须与
   * 「我刚碰了哪一条」一致 —— 这条不变量只要有一个入口漏了，症状就是同一个。 */
  private enterMulti(key: string): void {
    this.selectedSave = key;
    if (!this.multiMode) {
      this.multiMode = true;
      this.multiPicked = [key];
      return;
    }
    this.toggleMultiPick(key);
  }

  /** 勾/取消。⚠️ 必须**赋新数组**（ArkUI 只认赋值），理由同 toggleTransferPick。 */
  private toggleMultiPick(key: string): void {
    /* 先挪详情 —— 取消勾选时**也要**挪：详情答的是「我刚碰的是哪一个」，而不是「它还选着吗」；
     * ⚠️ 否则取消一个之后右边会跳回很久以前选的那条。`selectedSave` 永远等于「我刚碰的那一行」。 */
    this.selectedSave = key;
    const i: number = this.multiPicked.indexOf(key);
    if (i >= 0) {
      const out: string[] = this.multiPicked.slice();
      out.splice(i, 1);
      this.multiPicked = out;
    } else {
      this.multiPicked = this.multiPicked.concat([key]);
    }
    /* ⛔ **一个都不剩也【不】退出多选**（2026-10-03：「再点击选中的唯一一项不应该退出多选。
     * 要退出只能点取消」）。我原来在这里自动退出（理由「留着一个『已选 0 项』的条会让人以为卡住了」）——
     * ⭐ 那句话把一个**正常状态**当成异常：一次点击做了两件事（取消勾选 **＋** 退出模式），而玩家只要求
     * 了第一件 ⇒ 后果是**取消按钮形同虚设**，玩家学不会「退出是它管的」。
     * ⚠️ 0 项时「删除」是 `enabled(false)`（见 `MultiBar`），这个状态没有危险动作可做。 */
  }

  /* 退出多选。⚠️ 顺带把那两个只属于多选的开关也清掉 —— 不清的话下次进来会**直接弹着上一次的
   * 确认框**，而玩家根本没按删除。 */
  private exitMulti(): void {
    this.multiMode = false;
    this.multiPicked = [];
    this.showMultiAsk = false;
    this.multiListOpen = false;
  }

  /** 勾上的那些存档的名字，顿号相连 —— 确认框的标题行与展开窗都用它。 */
  private pickedNamesText(): string {
    const names: string[] = [];
    for (const r of this.pickedRows()) {
      names.push(r.entry.label);
    }
    return names.join('、');
  }

  /** 勾上的那些行（按 `saveGroups` 的顺序）。找不到的键**跳过** —— 它可能已被别处删掉，那不是错误。 */
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

  /* 勾选里**还在列表上**的那些的个数。
   * ⛔ 别用 `multiPicked.length` —— 那里面可能留着**已经不在的键**（移动部分成功就是这样：
   * 搬走的那些已经从 `saveGroups` 里没了，而键还留在数组里）⇒ 提示条会报一个比屏幕上真实
   * 存在的多的数，按钮也会在无事可做时仍可点。
   * ⭐ 判据：**说给玩家听的那个数，必须是接下来真的会被操作的那些**。 */
  private multiPickCount(): number {
    return this.pickedRows().length;
  }

  /* 一次删掉所有勾上的。⚠️ 一个个走**同一条**搬进垃圾站的路，不是批量直接删 —— 批量删要额外的
   * 回滚逻辑，而这条路已经带回了回滚（见 SaveVault.vaultDelete）。⚠️ 部分失败要**说出来**。 */
  private deleteMultiToVault(): void {
    const rows: SaveRow[] = this.pickedRows();
    if (rows.length === 0) {
      /* 一个都没勾 ⇒ 什么都不做。⛔ 也不退出 —— 与 toggleMultiPick 同一条规则：退出只归「取消」管。 */
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
    /* 先关窗再退出 —— `exitMulti()` 自己也会清 `showMultiAsk`，这里显式写一次是为了让「删完窗
     * 一定没了」读得出来（顺序不依赖另一个函数）。 */
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

  /* 真删。`archived = true` ⇒ 归档（不自动清理）。⚠️ 走的是**搬进垃圾站**，不是抹掉。 */
  private doVaultDelete(archived: boolean): void {
    const sv: SaveEntry | undefined = this.selectedSaveEntry();
    this.showDeleteAsk = false;
    if (sv === undefined) {
      return;
    }
    const dir: string = this.selectedSaveDir();
    const now: number = Date.now();
    /* ⭐ 把**来源**一起记下来（垃圾站里区分不出原来是哪个版本的）。
     * ⚠️ 在这里取值而不是在垃圾站里现算：删除之后那个 jar 可能就没了。 */
    const err: string = vaultDelete(sv, dir, this.vaultDays, now,
                                    this.ownerOfDir(dir), this.keyOfDir(dir));
    if (err !== '') {
      this.vaultNote = err;
      this.refresh();
      return;
    }
    if (archived) {
      /* 刚搬进去的那个 = 最新那一个（`listVault` 新的在前）。⚠️ 用「最新」而不是自己拼 id：
       * id 的拼法只有 SaveVault 知道，在这里再拼一遍就是同一件事两份实现。 */
      const fresh: VaultEntry[] = listVault();
      if (fresh.length > 0) {
        const e2: string = vaultSetArchived(fresh[0].id, true, this.vaultDays, now);
        if (e2 !== '') {
          /* ⚠️ 搬成功了、归档没设上 ⇒ 说出来：它现在是**普通垃圾站条目**，到期会被清掉 ——
           * 而那正是玩家选了归档想避免的事。 */
          this.vaultNote = '已经搬进垃圾站了，但归档没设上（它到期仍会被清理）：' + e2;
        }
      }
    }
    this.selectedSave = '';
    this.refresh();
  }

  /* ⭐ 一个**存档目录**属于哪些版本 —— 直接复用「按存档」那一屏的分组结论。
   * ⭐ 用 `groupTitle` 而不是自己拼：两处必须**说同一件事** —— 垃圾站里写「内置游戏」、
   * 存档页写「内置游戏（v8 Build 160.5）」，玩家会以为是两个东西。 */
  private ownerOfDir(dir: string): string {
    const g: SaveGroup | undefined = this.saveGroups.find((x: SaveGroup) => x.dir === dir);
    return g === undefined || g.versions.length === 0 ? '' : this.groupTitle(g);
  }

  /** 上面那个目录的隔离键；`''` = 未隔离（或推不出来）。 */
  private keyOfDir(dir: string): string {
    const g: SaveGroup | undefined = this.saveGroups.find((x: SaveGroup) => x.dir === dir);
    return g === undefined || g.versions.length === 0 ? '' : g.versions[0].key;
  }

  /* 垃圾站一行里「原来属于谁」。⛔ 三级回退，**顺序是用户定的**（2026-10-02）：
   * 版本 → 文件夹路径 → 不知道是谁的。
   * ① 版本（`内置游戏（v8 Build 160.5）`）就是他选的那一项；② 目录 —— 老条目、以及
   * 「留了很久没人读的孤立档」（`b160.5` 这种）只有这个，而它恰好**指得准**：那个键就是他当时那一档的名字；
   * ③ 都没有 ⇒ 实话实说。⛔ 别把 ③ 写成一句空话（「未知」）—— 要让人看出我们真的不知道。
   * ⚠️ 老条目没有 `owner` ⇒ **现算一次**，拿 `from` 去当前的分组里找；⛔ 都失败就说实话，别留空。 */
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

  /** 放回。刷新后存档列表当场出现它。 */
  private doVaultRestore(e: VaultEntry): void {
    /* 第二个参数只是**兜底**（原来那个目录没了时用它）—— 用当前版本的目录合适。 */
    this.vaultNote = vaultRestore(e, this.savesDirShown);
    /* ⚠️ 先短后长：垃圾站自己的名单立刻更新，`refresh()` 再去更新存档列表。 */
    this.reloadVault();
    this.refresh();
  }

  /** 彻底删掉（不可撤销）。 */
  private doVaultPurge(e: VaultEntry): void {
    this.vaultNote = vaultPurge(e.id);
    this.reloadVault();
    this.refresh();
  }

  /** 归档 / 取消归档。取消时**重新起算**保留期，见 SaveVault.vaultSetArchived。 */
  private doVaultToggleArchive(e: VaultEntry): void {
    this.vaultNote = vaultSetArchived(e.id, !e.archived, this.vaultDays, Date.now());
    this.reloadVault();
    this.refresh();
  }

  /** 改全局保留期。写盘后刷新，让每一行显示的剩余天数跟着变。 */
  private setVaultDays(d: number): void {
    this.vaultDays = d;
    writeVaultDays(this.filesDir, d);
    this.refresh();
  }

  /** 「保留到 YYYY-MM-DD HH:MM」。⚠️ 现在只在按钮上用到「日期」那一半。 */
  private deleteExpiryText(): string {
    return formatMs(Date.now() + this.vaultDays * 24 * 60 * 60 * 1000);
  }

  /* 只要日期那一段（`YYYY-MM-DD`）。⚠️ 按钮标签上写时分是噪音 —— 保留期是 3/7/30 天那个尺度。 */
  private deleteExpiryDate(): string {
    return this.deleteExpiryText().substring(0, 10);
  }

  /** 保留期那一档的按钮文案。 */
  private vaultDaysLabel(d: number): string {
    return d >= 30 ? '1 个月' : (String(d) + ' 天');
  }

  /* ---- 复制 / 移动 ---- */

  /* ⭐⭐ **这次操作作用在哪几份存档上。**
   *
   * 多选态 ⇒ **勾上的那批**（2026-10-04 用户：「多选再加一个：多选后的复制与移动」）；
   * 平时   ⇒ 选中的那一个。
   *
   * ⭐ 这套东西以前**只认一个源**：`confirmTransfer` 从头到尾读 `selectedSaveEntry()`，
   *    `transferTargets` 只排除那一个目录，对话框标题直接念 `selectedSaveLabel()`
   *    ⇒ 「对一批存档做复制/移动」在结构上做不到。这个函数就是把那个前提拆掉的地方 ——
   *    **其余每个动作（标题、副标题、目标表、执行循环）都从这里取源**，⛔ 别再各处自己读 `selectedSave`。
   *
   * ⚠️ **渲染期也会调它**（对话框的标题与副标题）⇒ 它只读内存里的 `saveGroups`，
   *    ⛔ **不读磁盘、不读 jar**（本文件那条「要读 jar 的一律在 refresh()/事件里算好」的规则）。
   * ⭐ 复用 `pickedRows()`（多选删除走的就是它）—— 映射逻辑只有一份。 */
  private transferSourceRows(): SaveRow[] {
    if (this.multiMode) {
      return this.pickedRows();
    }
    const r: SaveRow | undefined = this.selectedSaveRow();
    return r === undefined ? [] : [r];
  }

  /** 源所在的**目录**（去重）。⭐ 只有它的是「目标不能选哪几个」—— 见 `transferTargets`。 */
  private transferSourceDirs(): string[] {
    const out: string[] = [];
    for (const r of this.transferSourceRows()) {
      if (out.indexOf(r.dir) < 0) {
        out.push(r.dir);
      }
    }
    return out;
  }

  /** 源**全部**是手动存档吗。⭐ 「同版本再存一份」只对手动存档成立：战役存档复制一份会让游戏认不出
   * 那个区块（理由见对话框里那段说明）。⛔ 多选时**有一个不是**就不能给这一项 —— 否则它会安静地
   * 只给其中几个生效，而玩家以为整批都做了。 */
  private transferAllManual(): boolean {
    const rows: SaveRow[] = this.transferSourceRows();
    if (rows.length === 0) {
      return false;
    }
    for (const r of rows) {
      if (r.entry.kind !== 'manual') {
        return false;
      }
    }
    return true;
  }

  private askTransfer(op: string): void {
    /* ⭐ 判据是「有没有源」，⛔ 不是 `selectedSave === ''` —— 多选态下源是勾上的那批，
     * 而那个字段只是「详情里最后点过的那一个」。 */
    if (this.transferSourceRows().length === 0) {
      return;
    }
    this.transferOp = op;
    this.transferNote = '';
    /* 每次打开都从**空选择**开始 —— 上一次的选择留在那儿会让玩家以为已经选好了。 */
    this.transferPicked = [];
  }

  private closeTransferDialog(): void {
    this.transferOp = '';
    this.transferNote = '';
    this.transferPicked = [];
  }

  /** 这一项选中了吗。 */
  private isTransferPicked(key: string): boolean {
    return this.transferPicked.indexOf(key) >= 0;
  }

  /* 点一项 —— **只改选择，不执行任何动作**（用户要的「先多选再确定」）。
   * ⚠️ **必须赋一个【新数组】**：`push`/`splice` 改的是同一个对象，而 ArkUI 观测的是
   * 「这个 @State 被重新赋值了吗」——⛔ 原地改内容不保证触发重绘，症状就是「点了没反应」。 */
  private toggleTransferPick(key: string): void {
    const i: number = this.transferPicked.indexOf(key);
    if (this.transferOp === 'move') {
      /* 移动**单选**：再点已选的就取消，点别的就换成它。⚠️ 理由见 TransferDialog ——
       * 搬走之后源就没了，第二个目标无从谈起。 */
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

  /* 能当目标的版本 —— **排除当前版本自己**。
   * ⚠️ 判据是**数据目录**相同，不是 path 不同：隔离关着时所有版本的目录是同一个 ⇒ 必须也排除，
   * 否则会出现一个看起来能选、点下去报「源和目标在同一个目录」的选项。
   */
  private transferTargets(): VersionEntry[] {
    /* ⭐ 「源」= **源那几行自己的目录**，不再是当前版本的目录 —— 列表里可能有别的版本的存档。
     * ⛔ 用 `savesDirShown` 的话会把**当前版本那一份**当成源（而它可能根本没有这些存档）。
     * ⚠️ 多选时**每一个**源目录都要排除：勾上的两个存档可能来自同一个版本，而「复制到原地」
     * 是没意义的（`copySaveTo` 会当场报「源和目标在同一个目录」）⇒ 让玩家**选不出**这种组合，
     * 比让他按下去再报错好（同 L3142 对「移动单选」的处理理由）。 */
    const dirs: string[] = this.transferSourceDirs();
    return this.versions.filter((v: VersionEntry) => dirs.indexOf(v.dataDir + '/saves') < 0);
  }

  /** 目标那一行的后果说明。⭐ 用户要的就是「移动前讲清后果」。
   * ⚠️ 多选时要改复数措辞 —— 否则「复制**一份**过去」在一批 3 个时是错的。
   * ⛔ 源 =1 时**逐字保持原样**（那是已经在用的句子，别因为重构改了它）。 */
  private transferTargetNote(v: VersionEntry): string {
    const n: number = countSavesIn(v.dataDir + '/saves');
    const head: string = n === 0
      ? '它还没有存档'
      : ('它现在有 ' + String(n) + ' 个存档');
    const m: number = this.transferSourceRows().length;
    if (this.transferOp === 'move') {
      return m > 1
        ? (head + '；移过去之后，这 ' + String(m) + ' 个存档只在「' + v.label + '」下有。')
        : (head + '；移过去之后，这个存档只在「' + v.label + '」下有。');
    }
    return m > 1
      ? (head + '；复制 ' + String(m) + ' 份过去，两边都有。')
      : (head + '；复制一份过去，两边都有。');
  }

  /* 一条失败行。⭐ 源不止一个时**必须带上存档名** —— 否则「A → B：原因」里那个 A 是谁，
   * 玩家从屏幕上读不出来（而批量操作失败时，他正需要知道**是哪一个**没成）。
   * ⛔ 源 =1 时保持改动前那句话（`目标：原因`），别因为重构改了已经在用的措辞。
   * ⚠️ 写成方法而不是局部箭头函数：本文件通篇是这个形状，而 ArkTS 比 TS 严
   * （文件里没有任何局部函数定义的先例，不拿它试）。 */
  private transferFailLine(src: SaveRow, where: string, why: string): string {
    if (this.transferSourceRows().length > 1) {
      return src.entry.label + ' → ' + where + '：' + why;
    }
    return where + '：' + why;
  }

  /* 对话框的标题。⭐ 单源念名字（今天的样子），多源念个数。
   * ⚠️ 渲染期调用 ⇒ 只读内存（见 `transferSourceRows` 的注释）。 */
  private transferSourceTitle(): string {
    const m: number = this.transferSourceRows().length;
    const verb: string = this.transferOp === 'move' ? '移动' : '复制';
    if (m > 1) {
      return verb + ' ' + String(m) + ' 个存档';
    }
    return verb + '「' + this.selectedSaveLabel() + '」';
  }

  /** 对话框的副标题 —— 一句话说清「源会怎样」。 */
  private transferSourceSubtitle(): string {
    const m: number = this.transferSourceRows().length;
    if (this.transferOp === 'move') {
      return m > 1
        ? ('原版本会看不到这 ' + String(m) + ' 个。选一个目标。')
        : '原版本会看不到它。选一个目标。';
    }
    return m > 1
      ? ('原来那 ' + String(m) + ' 份不动。可以选多个目标。')
      : '原来那一份不动。可以选多个目标。';
  }

  /* 按下「确定」——**这才是真正动手的地方**。
   *
   * ⚠️ **源 × 目标**：多选态下源是一批（`transferSourceRows`），复制还可以有多个目标
   * ⇒ 最坏是 N×M 次文件操作。⛔ 单源时它与改动前逐字等价（一层循环退化成一次）。
   *
   * ⚠️ **不遇到第一个失败就停**：停下来的话，玩家会以为后面那些也没做，而其实前面已经成功了 ——
   * 那种「状态不明」比失败本身更难受。⇒ 成功的照做，失败的汇总，并且**照旧刷新**。
   *
   * ⚠️ **失败行要给上限**：源×目标可以到几十条，而这段文字渲染在**一个** `Text` 里
   * ⇒ 全列出来会把对话框顶爆。取前 6 条 + 一句「还有 N 条」。⛔ 但**总数照报** ——
   * 只说 6 条会让人以为只错了 6 个。 */
  private confirmTransfer(): void {
    const srcs: SaveRow[] = this.transferSourceRows();
    if (srcs.length === 0 || this.transferPicked.length === 0) {
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
        for (const src of srcs) {
          const e: string = moveSaveTo(src.entry, src.dir, v.dataDir + '/saves');
          if (e === '') {
            okCount += 1;
          } else {
            fails.push(this.transferFailLine(src, v.label, e));
          }
        }
      }
    } else {
      for (const key of this.transferPicked) {
        if (key === DUP_KEY) {
          for (const src of srcs) {
            const e: string = duplicateSave(src.entry, src.dir);
            if (e === '') {
              okCount += 1;
            } else {
              fails.push(this.transferFailLine(src, '再存一份', e));
            }
          }
          continue;
        }
        const v: VersionEntry | undefined =
          this.transferTargets().find((x: VersionEntry) => x.path === key);
        if (v === undefined) {
          fails.push('有个选中的目标已经不在了');
          continue;
        }
        for (const src of srcs) {
          const e: string = copySaveTo(src.entry, src.dir, v.dataDir + '/saves');
          if (e === '') {
            okCount += 1;
          } else {
            fails.push(this.transferFailLine(src, v.label, e));
          }
        }
      }
    }

    if (fails.length === 0) {
      /* ⚠️⚠️ **先记住是哪个动作，再关窗。** `closeTransferDialog()` 会把 `transferOp` 清成 `''`
       * ⇒ 关窗之后再写 `this.transferOp === 'move'` 是**恒假**，下面那个分支永远不进。
       *
       * ⛔ 2026-10-04 我正是这么写的第一版，用户当场看到：**移动完还留在多选态** ——
       * 提示条上「已选 2 项」停在旧数上（那两行已经从源里搬走了），勾选也没散。
       * ⭐ 教训：**一个函数把某个字段清掉之后，它就不是「那个动作」的证据了** ——
       * 想拿它做判断，就把值在读得到的时候先取出来。 */
      const wasMove: boolean = this.transferOp === 'move';
      this.closeTransferDialog();
      /* ⭐⭐ 收场按「源还在不在」而定（2026-10-04 用户选定）：
       *   **复制**不动源 ⇒ **留在多选态**，可以直接再复制到别的版本；
       *   **移动**把它们从源里搬走了 ⇒ **退出多选态**，否则会说「已选 3 项」而屏幕上只剩 2 行，
       *   而且 `selectedSave` 还指着一个已经不存在的存档（详情面板会念一个空）。 */
      if (wasMove && this.multiMode) {
        this.exitMulti();
        this.selectedSave = '';
      }
    } else {
      /* ⭐⭐ 失败提示就两行：**「复制失败：」/「移动失败：」＋具体原因**（2026-10-02：「复制失败：
       * 「具体原因」，别的解释不需要」）。⛔ 原来拼的是「成功了 N 个；没成功：A；B；C」，一句话塞
       * 三件事、像日志 ⇒ 改成**一个标题 + 逐行的原因**（每个目标单独一行、带目标名）。
       * ⚠️ 部分成功时只在最前面留一行「成功了 N 个。」—— 那是**事实**，少了它会让人以为一个都没成。 */
      const head: string = this.transferOp === 'move' ? '移动失败' : '复制失败';
      const okLine: string = okCount > 0 ? ('成功了 ' + String(okCount) + ' 个。\n') : '';
      const CAP: number = 6;
      const shown: string[] = fails.slice(0, CAP);
      const rest: string = fails.length > CAP
        ? ('\n…还有 ' + String(fails.length - CAP) + ' 条')
        : '';
      this.transferNote = okLine + head + '：\n' + shown.join('\n') + rest;
      /* 清掉选择 —— 成功的那些再点一次会撞同名而报错，失败的那些让玩家重新挑。 */
      this.transferPicked = [];
    }
    this.refresh();
  }

  /* ⭐⭐ 窄屏（手机）的判定。⚠️ 阈值 600 vp 与 AMCL 一致（他们 `viewportWidth >= 600` 才走双栏），
   * 也与 `CONTENT_MIN_VP` 那条实测（「手机上窗口只有 360–420 vp」）吻合。
   * ⚠️ `winW <= 0` 时（还没量到）**当作宽屏**：宁可先按宽屏画一帧，也不要让平板上闪一下子页 ——
   * 平板上量到宽度之前就点进子页的概率极低，而误判成窄屏会让平板一进页面就少一半界面。 */
  private isNarrow(): boolean {
    return this.winW > 0 && this.winW < NARROW_VP;
  }

  /** 手机上打开了详情子页。宽屏恒为 false（宽屏没有子页）。 */
  @State panelOpen: boolean = false;

  /** 元数据里**除了头条那三项**之外的行。
   * ⛔ 右侧面板把「构建号 / 地图 / 保存时间」放在头条（构建号还放大到 22），而 `metaRowsOf`
   * 的完整列表里也有这三项 ⇒ 不去掉的话同一字段会在一屏上出现两遍，读者会以为是两个东西。
   * ⚠️ 排的是**标签**，而那些标签在 `metaRowsOf` 里定义、只此一处 ⇒ 改名时两边一起改。 */
  private metaRowsExcept(): MetaRow[] {
    const skip: string[] = ['写入时的构建号', '地图', '保存时间'];
    return this.selMetaRows.filter((r: MetaRow) => skip.indexOf(r.label) < 0);
  }

  /** 玩家点了某个 jar。只是【记下来】，不在这里启动 —— 启动要重建整棵树。 */
  private pick(jarPath: string): void {
    this.selected = jarPath;
    writeSelection(this.filesDir, jarPath);
    this.resolution = resolveGame(this.filesDir, this.bundleCodeDir);
    hilog.info(DOMAIN, TAG, 'launcher: picked %{public}s', jarPath === '' ? '(bundled)' : jarPath);
  }

  /** 退回内置的那一份。写一个【空的】选择，那是明确的「用包里的」，不是清除。 */
  private pickBundled(): void {
    this.selected = '';
    writeSelection(this.filesDir, '');
    this.resolution = resolveGame(this.filesDir, this.bundleCodeDir);
    hilog.info(DOMAIN, TAG, 'launcher: picked (bundled)');
  }

  /* 打开确认窗。`g` = **刚被左滑的那一行**（见 `SwipeDeleteAction`），不是「选中的那个」。
   * ⭐⭐ 三样东西都在这里算一次并存住，理由有两条，缺一条都不行：
   *   ① `computeKey()` **没有缓存** —— 每调一次就真读一次那个 jar（最大 88 MB），
   *      而对话框会渲染好几遍，⛔ 不能每遍都去读；
   *   ② 删除流程走到一半 jar 就没了，**那时同一个版本会算到别的键上**
   *      ⇒「删它的数据」会删到另一份上去。 */
  private openGameDeleteAsk(g: GameJar): void {
    this.gameDeletePath = g.path;
    /* ⭐⭐ **文件名在前**（用户 2026-10-04：「具体哪个文件」）。
     * ⚠️ 与首页那一行的次序**相反**，而且这次是对的：那一行是**挑版本**时看的（版本号才是要比的），
     *    这里是**确认删哪个文件** —— 同一个版本号可能有好几个 jar，要认的正是文件名。
     * 版本号跟在后面（读不出就不跟），它只是补充。 */
    this.gameDeleteLabel = g.version === '' ? g.name : (g.name + '  ·  ' + g.version);
    this.gameDeleteDir = resolveGameDirAndKey(this.granularity, 'user', g.path,
                                              this.bundledJar()).dir;
    this.gamesNote = '';
    this.showGameDeleteAsk = true;
  }

  /** 这个版本有没有**自己**的隔离数据。
   *  ⛔ `false` 的含义很重：它用的是全应用唯一那份「未隔离的数据」⇒ **不能删**
   *     （删它等于把所有不隔离的版本一起清掉，还包括玩家最初那一份）。 */
  private jarHasOwnData(): boolean {
    return this.gameDeleteDir !== '' && this.gameDeleteDir !== liveGameDataDir();
  }

  /** 除它之外，还有哪些版本读同一个数据目录。 */
  private otherVersionsOnSelectedDir(): VersionEntry[] {
    const out: VersionEntry[] = [];
    if (this.gameDeletePath === '' || this.gameDeleteDir === '') {
      return out;
    }
    for (const v of this.versions) {
      if (v.dataDir === this.gameDeleteDir && v.path !== this.gameDeletePath) {
        out.push(v);
      }
    }
    return out;
  }

  /** 那些版本的名字。⚠️ 超过三个就截断 —— 一整串会把那段警告挤成墙。 */
  private otherVersionsText(): string {
    const names: string[] = [];
    for (const v of this.otherVersionsOnSelectedDir()) {
      names.push(v.version === '' ? v.label : v.version);
    }
    if (names.length <= 3) {
      return names.join('、');
    }
    return names.slice(0, 3).join('、') + ' 等 ' + String(names.length) + ' 个';
  }

  /** 这份数据里现在有几个存档。⭐ 「会少掉多少」要在按之前就能看见。 */
  private jarDataSaveCount(): number {
    if (this.gameDeleteDir === '') {
      return 0;
    }
    return countSavesIn(this.gameDeleteDir + '/saves');
  }

  /* 真删一个版本。`withData = true` ⇒ 连它的数据一起删。
   *
   * ⚠️ 目录用 `this.gameDeleteDir`（打开窗时算好的），⛔ **不在这里重算** —— 见 `openGameDeleteAsk`。
   *
   * ⚠️ 顺序是**先数据、后 jar**，而且数据没删干净就**整个停下**：
   *    · 反过来先删 jar，会留下一个「没有版本读它」的孤儿目录 —— 界面上本来就有一类专门显示
   *      它，但那是**另一件事**，不该由「删除」制造出来；
   *    · 数据删一半就停，玩家还能看着这个版本再试一次，而不是剩一个游戏配半份数据。 */
  private deleteGame(withData: boolean): void {
    const path: string = this.gameDeletePath;
    this.showGameDeleteAsk = false;
    if (path === '') {
      return;
    }
    const dir: string = this.gameDeleteDir;

    /* ⛔ 未隔离那一份**自己再拦一次**。界面本来就不会给出那个按钮（见 `jarHasOwnData`），
     * 但**界面不是门**：一个真删东西的动作必须自己认得「这个不能删」，而不是指望调用点记得。
     * 这也是这一条比界面那条更重要的地方 —— 界面会变，这条不会。 */
    if (withData && (dir === '' || dir === liveGameDataDir())) {
      this.gamesNote = '那份是全应用唯一的未隔离数据，不能这样删。';
      this.refresh();
      return;
    }

    if (withData) {
      const rm: TreeStat = newTreeStat();
      removeTree(dir, 0, rm);
      if (rm.failed > 0) {
        this.gamesNote = '数据没删干净，游戏也先没删（可以再试一次）：' + rm.firstError;
        this.refresh();
        return;
      }
      hilog.info(DOMAIN, TAG, 'games: removed data dir %{public}s', dir);
    }

    /* 删 jar 本身。⚠️ `unlinkSync` 删不存在的文件会**抛** ⇒ 先探一下（`EntryAbility` 里同一条）。 */
    try {
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
    } catch (e) {
      const err = e as BusinessError;
      this.gamesNote = '删除失败：' + err.message;
      this.refresh();
      return;
    }

    /* 删掉的正好是选中那个 ⇒ 退回内置。⛔ 不退的话选中路径指向一个不存在的文件，
     * 而首页会显示「没有找到游戏」—— 一个删除动作不该把应用弄成那个样子。 */
    if (this.selected === path) {
      writeSelection(this.filesDir, '');
    }
    this.gameDeletePath = '';
    this.gameDeleteLabel = '';
    this.gameDeleteDir = '';
    this.gamesNote = withData ? '已删除这个版本和它的数据。' : '已删除这个版本（保留数据）。';
    hilog.info(DOMAIN, TAG, 'games: deleted %{public}s withData=%{public}s',
               path, String(withData));
    this.refresh();
  }

  /** 内容一栏的宽度（vp）。**靠左**摆，见 CONTENT_MIN_VP。
   * ⚠️ 它返回**数值 width** 而不是配 `width('100%')` 用的 `constraintSize` —— 这个选择为动画服务：
   * `animateTo` 动的是**渲染属性**，而 `constraintSize` 是**布局约束**（约束变了布局直接重排、
   * 没有中间帧）⇒ 用 `constraintSize` 时动画根本没跑（用户说「**还是**太快了」），改回来。
   * ⚠️ 窗口宽度还没量到时给下限；`winW <= 0` 只出现在第一帧。 */
  private gamesWidthVp(): number {
    if (this.winW <= 0) {
      return CONTENT_MIN_VP;
    }
    /* ⭐⭐ **窄屏（手机比例）⇒ 直接铺满窗口宽度。**
     * ⛔ 原来靠 `max(360, 30%)` 里那个**下限**去「退回全宽」，而 360 是写死的数、不是窗口宽度：
     * 窗口在 361–599 vp 时内容 = 360、窗口比如 420 ⇒ 右边空 60vp；而外层 `HorizontalAlign.Start`
     * （靠左，宽屏的规格）⇒ 屏幕上是**一条靠左的窄栏 + 右边一条空白**（2026-10-03 报的
     * 「首页在手机比例下，列表不是居中的…而且此时最好占满左右」）。
     * ⇒ 判据：**「退回全宽」不能用常量表达** —— 只有窗口宽度本身是全宽。
     * ⚠️ 走 `isNarrow()`（同一个 600vp 阈值）而不是再写一个判断（阈值两处各写一遍会有一天只改一处）。
     * ⚠️ 返回值必须仍是**数值**（`animateTo` 只对渲染属性插值）⇒ 给 `this.winW` 而不是 `'100%'`。 */
    if (this.isNarrow()) {
      return this.winW;
    }
    const want: number = this.winW * (GAMES_WIDTH_PCT / 100);
    return want > CONTENT_MIN_VP ? want : CONTENT_MIN_VP;
  }

  /* ⛔ 这里曾有一个 `hasRightGap()`（用于「右侧非界面区」那套底色/分界线）。整套已回退
   * （2026-10-02：「还是去掉吧，背景就黑色就行了」）⇒ 没有用户了，别再加回来。 */

  /** 栏左右各留多少。**同一个值给两边 ⇒ 栏必然居中**（见 BAR_MAX_VP）。
   * 窗口宽度还没量到时返回下限 —— 那时栏会宽一点，下一帧就正了。宁可先宽后正，
   * 也不要先给一个可能算出负数的值。 */
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
      /* 下拉刷新。列表上直接下拉就重扫；设置页那个「重新扫描」按钮**保留**当备份（下拉是一条手势，
       * 手势失败时按钮还在 —— 出口多一点比少一点安全）。
       * ⚠️ 刷新的动作就是 `refresh()`，与按钮**完全同一个函数** —— 不要在两边各写一份读盘逻辑。
       * ⚠️ `refresh()` 是**同步**的 ⇒ 这里可以立刻把 isRefreshing 放回 false，转圈一闪而过是诚实的；
       * 刻意**不**加延时去「让动画好看一点」，那等于让界面撒谎。 */
      Refresh({ refreshing: $$this.isRefreshing }) {
        /* ⚠️ 必须有一个**可滚动**的子节点，否则下拉手势不一定触发 —— Refresh 是靠内容能滚动
         * 来判断「用户拉的是列表」的（原来那层直接是 Column、不可滚）⇒ 这里包一层 Scroll。
         * ⚠️ 再加一层 Row 是为了**恢复左对齐**：Refresh 内容区默认居中，会把卡片从屏幕左边跑到
         * 中间，而规格是「内容本身占 30%，在**最左边**，像 AMCL 那样」⇒ 靠结构而非调数值恢复。 */
        Scroll() {
          Row() {
            Column() {
              if (this.games.length === 0) {
          /* 空状态，而它同时是【逃生门】。「判定没有游戏」有三个来源（真的没有 / 内置路径算错 /
           * Downloads 文件夹在这台设备上还没创建），三者在界面上长得一模一样，而其中两个是**我的**
           * 问题 ⇒ 必须能出去：一个「仍然尝试启动」的入口。没有它，一次路径判断失误就把应用变成
           * 永远打不开游戏的启动器，而玩家没有任何办法绕过去（本项目为「门关上了却没有开的路径」付过代价）。 */
          Column() {
            /* ⛔⛔ **先分叉：这个包到底带不带运行时。**
             *  `resolution.source === 'no-runtime'` 由 `resolveGame()` 给出，而那是
             *  **运行期文件探测**（`hasRuntime()`，查包里有没有 `libjvm_real.so`），
             *  ⛔ 不是编译期常量 ⇒ 三种形态（master / lite / tools）的 ArkTS 因此可以逐字节相同。
             *
             *  ⚠️ 为什么这里非分叉不可：这个空状态原本一律说「把 .jar 放进文件夹」——
             *     而那对**没有运行时的包**是**空头承诺**：jar 放进来了也跑不起来
             *     （包里没有 JVM）。玩家会照做、然后发现「点了没反应」，
             *     而那是最难查的一种失败。⇒ 这个分支的**全部价值就是不给那条错指引**。 */
            if (this.resolution.source === 'no-runtime') {
              Text('这个包不能运行游戏')
                .fontSize(18).fontColor($r('sys.color.font_primary'))
              Text('它只能管理存档与数据包 —— 包里没有游戏运行时。')
                .fontSize(13).fontColor($r('sys.color.font_secondary'))
                .margin({ top: 8 })
                .textAlign(TextAlign.Center)
              /* ⭐ 给出**出路**，不只是一句「不行」。没有这一句，玩家只知道坏掉了。 */
              Text('要玩 Mindustry，请安装带游戏的完整版本；\n这个版本可以用「导入数据」接管它的存档。')
                .fontSize(13).fontColor($r('sys.color.font_secondary'))
                .margin({ top: 12 })
                .textAlign(TextAlign.Center)
            } else {
            /* ⚠️ 标题**据实**说，别一律说「没有找到游戏」。进入条件是 `games.length === 0`，
             * 而 `games` 是 `listGameJars()` 列出来的 —— 也就是**玩家自己放在 Download 里的 jar**，
             * 内置那份不在里面 ⇒ 内置在时写「没有找到游戏」会和下面的「内置游戏：有」**自相矛盾**，
             * 更糟的是底下「启动游戏」按钮是**可用**的。⭐ 只有**内置也不在**时那句话才是真的。
             * ⚠️ 判据用 `hasBundled`（直接问文件在不在），不是 `resolution.source`（那是「这次加载谁」）。 */
            Text(this.hasBundled ? '还没有导入其他游戏版本' : '没有找到游戏')
              .fontSize(18).fontColor($r('sys.color.font_primary'))
            /* 内置在时补一句「其实可以直接玩」—— 标题已经不再说「找不到」了，得让玩家知道这不是死路。 */
            if (this.hasBundled) {
              Text('内置的那一份可以直接玩，点下面的「启动游戏」就行')
                .fontSize(13).fontColor($r('sys.color.font_secondary'))
                .margin({ top: 8 })
                .textAlign(TextAlign.Center)
            }
            /* 提示里给**两条**路（下拉 / 设置页按钮），免得玩家以为只有一个办法。 */
            Text('把 Mindustry 的 .jar 放进下面这个文件夹，然后下拉刷新（或到「设置」里点「重新扫描」）：')
              .fontSize(13).fontColor($r('sys.color.font_secondary'))
              .margin({ top: 12 })
              .textAlign(TextAlign.Center)
            /* ⚠️ 两行，缺一不可（2026-10-02 定的）：第一行给人【找】（文件夹在磁盘上叫包名，
             * 而文件管理器显示的是应用名 ⇒ 照真实路径去文件管理器找是找不到的）；
             * 第二行给人【复制】（真实路径可以直接粘进文件管理器的地址栏）。 */
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
          }
          .width('100%')
          .padding({ left: 24, right: 24, top: 40, bottom: 24 })
          .alignItems(HorizontalAlign.Center)
        } else {
          /* ⚠️ 列表项是【内联】写的，不是 @Builder（见文件头第 2 条）：@Builder 的参数按值传递
           * ⇒ `this.selected` 变化不会让它重新执行 ⇒ 点击其实成功了（日志里 source=user 是对的）
           * 但 ✓ 不动，看起来就是「点了没反应」。 */
          List({ space: 8 }) {
            /* ⚠️ 这一行【必须】有守卫。lite 分支（`config.SHIPS_GAME = False`）的包里没有
             * 那份游戏，而一条指向不存在文件的条目照样会渲染、照样可点 —— 点下去只会得到
             * 「没有找到游戏」。判据用 `hasBundled`（直接问文件在不在），与上面版本列表
             * 和空态那几处是【同一条】。master 上它恒为真，渲染与从前一致。 */
            if (this.hasBundled) {
              ListItem() {
                Row() {
                  Column() {
                    Text('内置游戏')
                      .fontSize(16).fontColor($r('sys.color.font_primary'))
                    /* 第二行 = **版本号**。⚠️ 它【曾经】随选中状态切换（「正在使用」/「包里的那一份」），
                     * 那是多余的：选没选中已由右边的 ✓ 表达，再写一遍只是把唯一能放版本号的位置占掉了。 */
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
            }

            ForEach(this.games, (g: GameJar) => {
              ListItem() {
                Row() {
                  Column() {
                    /* 第一行 = **版本号**，第二行 = 文件名 · 大小 · 日期。⚠️ 与内置那一行的次序相反
                     * 是刻意的：内置那份没有文件名可看（「内置游戏」就是它的标题），而玩家导入的文件名
                     * 五花八门，**版本号才是选的时候真正要比的东西**。
                     * ⚠️ 读不出就写「未知版本」，**不是**留空或让条目消失 —— 不是游戏的 jar（例如模组）
                     * 本来就会走到这里，照样要能被选中。 */
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
                /* ⭐⭐ 白底与圆角**必须在【内容】这一层**，不能挂在 `ListItem` 上。
                 * ⛔ 挂在 ListItem 上的后果（用户 2026-10-04 报的）：`swipeAction` 移动的是
                 *    **内容**，而 ListItem 自己的背景不动 ⇒ 左滑时**文字滑走了、白卡片原地不动**，
                 *    看起来像"只有字在动"。挪进来之后整张卡片一起滑。
                 * ⚠️ `onClick` 与 `swipeAction` 留在 `ListItem` 上 —— 后者是 `ListItemAttribute`
                 *    的方法，挪不下来。 */
                .backgroundColor($r('app.color.launcher_card'))
                .borderRadius(CARD_RADIUS_VP)
              }
              .onClick(() => { this.pick(g.path); })
              /* ⭐ 左滑露出「删除」。用系统原生的 `ListItem.swipeAction`，**不自写手势** ——
               * 回弹、只允许一行展开、与纵向滚动抢手势，这些它都已经处理好了。
               * ⚠️ `end` = 垂直列表里**向左滑**露出的那一侧（向右滑是 `start`）。
               * ⛔ 不给 `onAction`（滑到底自动触发）：「滑到底」是个顺手就会做出来的动作，
               *    让它直接弹确认窗比「点一下露出来的按钮」容易误触。
               * ⚠️ 内置那一行没有这个 —— 它在 HAP 里，不是文件，删不掉。 */
              .swipeAction({ end: { builder: () => { this.SwipeDeleteAction(g) } },
                             edgeEffect: SwipeEdgeEffect.Spring })
            }, (g: GameJar): string => this.gameRowKey(g))
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 16 })
            }
            }
            .width(this.gamesWidthVp())
            .animation({ duration: 300, curve: Curve.FastOutSlowIn })
          }
          /* 靠左**且**靠上。⚠️ `height('100%')` 不是多余的：Row 自适应高度时 Scroll 会把它
           * **垂直居中**，于是列表上下各空出一大块（实测截图里第一张卡片落在屏幕 33% 处）；
           * 撑满之后 `VerticalAlign.Top` 才真正把它钉在顶部。 */
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Start)
          .alignItems(VerticalAlign.Top)
        }
        .width('100%')
        .height('100%')
        /* 关掉滚动条：内容通常只有几行，一条忽隐忽现的滚动条只是噪音。 */
        .scrollBar(BarState.Off)
      }
      /* Refresh 自己拿 layoutWeight(1)，让「列表 + 空状态」这块占满按钮以上的空间。
       * ⚠️ 里面那几层**不**要再要 layoutWeight：高度由 Refresh 决定，两处都要会让高度被算两次，
       * 症状是列表比可用空间矮一截。 */
      .layoutWeight(1)
      .width('100%')
      .onRefreshing(() => {
        this.refresh();
        this.isRefreshing = false;
      })

      /* 上一次删除的结果 / 失败原因。⭐ 独立于下面那个按钮 —— 删完之后那个版本就没了、
       * 按钮会跟着消失，而消息**必须还在**（否则就是「删了没反馈」）。 */
      if (this.gamesNote !== '') {
        Text(this.gamesNote)
          .fontSize(12).fontColor($r('sys.color.font_secondary'))
          .width(this.gamesWidthVp())
          .padding({ left: 16, right: 16, top: 12 })
      }


      /* 主按钮。它被禁用的唯一理由是「确实没有任何可加载的东西」—— 由 resolveGame 判定，
       * 而它已经确认过文件真的能打开。 */
      Column() {
        Button('启动游戏')
          .width('100%')
          .height(44)
          .fontSize(BUTTON_FONT_VP)
          .enabled(this.resolution.path !== '')
          .onClick(() => { this.onLaunch(this.resolution.path); })

        /* ⛔ 这里【曾经】有一行「仍然尝试启动」（没有选中 jar 时出现在「启动游戏」正下方）。
         * 2026-10-01 去掉它，理由是它**常驻**（「应该是启动失败了才有的东西（弹窗告知的）」）⇒
         * 它现在只在**上一次启动失败**时以弹窗出现（见 build() 末尾那个浮层）；设置页里同名的按钮
         * 也一并撤了 —— 同一个东西不该有两处常驻入口。 */
      }
      .width(this.gamesWidthVp())
      .animation({ duration: 300, curve: Curve.FastOutSlowIn })
      .padding({ left: 16, right: 16, top: 12 })
    }
    .width('100%')
    .height('100%')
    /* ⭐ **Start，不是 Center** —— 内容靠左，这是用户给的规格：
     * 「内容本身占 30%，在最左边，像 AMCL 那样。」见 CONTENT_FRACTION。 */
    .alignItems(HorizontalAlign.Start)
    /* 给悬浮栏让位，见 BAR_CLEARANCE_VP。 */
    .padding({ bottom: BAR_CLEARANCE_VP })
  }
  /* ==================================================================
   * 存档页的两个详情面板
   *
   * ⭐⭐ 抽成**零参** `@Builder` 是为了让**宽屏内嵌**与**窄屏子页**共用同一份。
   * ⛔ 注意是零参：开头那条「@Builder 的参数按值传递，`selected` 变了不会重跑」**只针对带参数的**；
   * 零参的那种只读 `this`，`this` 上任何 @State 变化都会让它重新执行 ⇒ 若哪天要加参数，先读文件头第 2 条。
   * ================================================================== */

  @Builder
  SaveDataPanel() {
    Column() {
      if (this.selectedSave === '') {
        Text(this.saves.length === 0 ? '还没有存档' : '从左边选一个存档')
          .fontSize(13).fontColor($r('sys.color.font_tertiary'))
      } else {
        /* 「这个存档对哪些版本可见」与**标题同一行、靠最右**（2026-10-02 要的）。⭐ 不只是好看：它是
         * 这个存档的**属性**，摆在整张元数据表**下面**会让人以为它是表格的最后一行。
         * ⚠️ 内部按 **2 : 1** 分，⛔ 不是按内容自适应（否则存档名一长就把右边挤掉/挤到换行，同一屏上
         * 换个存档那行字就跳一次位）⇒ 位置**由结构保证**。⚠️ 别与外层那两栏的 3 : 7 搞混。
         * ⚠️ 顶部对齐；右边整块 `HorizontalAlign.End` 贴右边缘。 */
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

          /* ⭐ 答的是**目录**层面的问题（谁的 `user.home` 指向这里），那是能确切回答的那个；
           * ⛔ 不是「这个存档能被哪些版本读」—— 那个还要看模组与版本迁移规则，我们答不了。
           * 存档自己的 `build` 就在下面，两件事分开摆着。 */
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

        /* ⚠️ 读失败时（`selMetaNote` 非空）**只显示那句话**，不显示半截数据 ——
         * ⛔ 一个「读不出来」的存档若看起来和正常存档一样（只是字段空着），玩家会以为存档本身是空的。 */
        if (this.selMetaNote !== '') {
          Text(this.selMetaNote)
            .fontSize(12).fontColor($r('sys.color.font_secondary'))
        } else {
          /* ⭐ 头条三行：构建号放大，地图与保存时间跟在下面。⛔ 这三项**不再出现在下面的完整列表里**
           * （用 `metaRowsExcept` 排掉）—— 同一个字段在一屏上出现两遍，读者会以为是两个不同的东西。 */
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

          /* ⭐⭐ **这里是「查看存档数据」原来那个弹窗的内容**，现在直接铺在右侧（2026-10-02：
           * 「我想把'查看存档数据'改成不弹窗，直接显示在右侧空白区域」）⇒ 那个按钮与弹窗**都已删除**，
           * 不是藏起来了。⚠️ 行内容在可滚动的一块里：`模组` 那条会长成 `[a, b, c]`，行数也跟着变。 */
          Divider()
            .strokeWidth(1).color($r('app.color.launcher_border'))
            .margin({ top: 14, bottom: 14 })

          Scroll() {
            Column() {
              ForEach(this.metaRowsExcept(), (r: MetaRow) => {
                Row() {
                  /* ⭐⭐ 这里**不能**用 `.width(88)`。它是**标签**（要跟着系统字体放大），
                   * 而 88vp 是个**定宽盒子** —— 两者只能选一个：
                   * 「写入时的构建号」7 个汉字，系统字体调到 1.75 倍就约 147vp ⇒ **被裁掉**。
                   * ⇒ 改成 `constraintSize({ minWidth: 88 })`：短标签仍从 88 起（列还是齐的），
                   *   长标签**把它撑开**而不是被裁 —— 代价是那一行的值列右移，但那比缺字好。 */
                  Text(r.label)
                    .fontSize(12).fontColor($r('sys.color.font_tertiary'))
                    .constraintSize({ minWidth: 88 })
                  Text(r.value)
                    .fontSize(12).fontColor($r('sys.color.font_primary'))
                    .layoutWeight(1)
                    .copyOption(CopyOptions.LocalDevice)
                }
                .width('100%')
                .margin({ bottom: 8 })
                .alignItems(VerticalAlign.Top)
              }, (r: MetaRow) => r.label + '|' + r.value)
            }
            .width('100%')
          }
          .width('100%')
          .layoutWeight(1)
          .align(Alignment.TopStart)
          .scrollBar(BarState.Off)
        }

        /* ⛔ 只有**当前版本**的存档能操作（`saves` 列表本来就只列当前版本的）；别的版本的存档要动，
         * 得先在「首页」把版本切过去（提示在「按版本」那边）。
         * ⭐⭐ **多选态下把这一条整根藏掉**（2026-10-02 同意）：不藏的话屏幕上会同时出现**两个「删除」**
         * （删勾上的这一批 / 删详情里那一个），长得一样、位置又近 ⇒ 玩家按下哪一个都是赌 —— 两个意思
         * 不同的同名按钮并存，比少一个按钮糟得多。
         * ⭐ **2026-10-04 起这条理由更硬了**：多选条上现在**也有复制/移动**，于是同名的冲突从
         * 「删除」一处变成**删除/复制/移动三处**。⚠️ 而两组按钮**意思确实不同**（多选条作用于
         * **勾上的那一批**、这一排只作用于**详情里那一个**）⇒ 判据不变、结论不变：**藏**。
         * ⛔ 别因为「现在两边都有复制了」就把这一排放出来。 */
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

  /* 对一个存档可做的事。⭐ 零参 `@Builder`，因为**两个面板都要用**。⚠️ 两份动作是安全的**现在**才
   * 成立：选中项自带目录（见 `selectedSave`），所以「操作的是哪一份数据」有唯一答案 —— ⛔ 在它只存
   * `id` 的那些日子里，两边各放一份会让它们对「操作谁」的理解分叉。 */
  /* 多选态的那一条。⭐ 零参 `@Builder`：两张列表共用同一份。
   * ⚠️ 两句话必须都在：「已选几项」是状态，「删除 = 放进垃圾站」是**后果** —— 少了后者玩家会以为
   * 「删除」是抹掉，于是不敢按。 */
  @Builder
  MultiBar() {
    /* ⭐⭐ **窄屏拆两行**（2026-10-04 用户：「这样在手机上，文字提示和按钮必须拆分成两行了
     * （平板够宽不用）」）。四个按钮加上那句提示，在手机上挤不进一行 ⇒ 提示独占一行、按钮换到第二行。
     * ⛔ 判据走 `isNarrow()`（阈值在 L243 那一处），别在这儿再写一个宽度判断。
     * ⚠️ 两个分支共用同一个 `MultiBarButtons()` —— ⛔ 别把四个按钮抄两遍。 */
    if (this.isNarrow()) {
      Column() {
        Text('已选 ' + String(this.multiPickCount()) + ' 项 · 删除只是放进垃圾站，可以找回')
          .fontSize(12).fontColor($r('sys.color.font_secondary'))
          .width('100%')
          /* 独占一行了，所以放宽到 2 行 —— 还按 1 行截断就白拆这一行了。 */
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        /* ⚠️ 外面再包一层 `Row`：`MultiBarButtons` 自己是自然宽度，要有东西把它推到右边。
         * ⛔ 别改成给那个 builder 里的 `Row` 加 `width('100%')` —— 宽屏那一臂里它与一个
         * `layoutWeight(1)` 的 `Text` 是兄弟，那个 100% 会把宽屏的文字挤成 0 宽。 */
        Row() {
          this.MultiBarButtons()
        }
        .width('100%')
        .justifyContent(FlexAlign.End)
        .margin({ top: 8 })
      }
      .width('100%')
      .margin({ top: 10 })
      .alignItems(HorizontalAlign.Start)
    } else {
      Row() {
        Text('已选 ' + String(this.multiPickCount()) + ' 项 · 删除只是放进垃圾站，可以找回')
          .fontSize(12).fontColor($r('sys.color.font_secondary'))
          .layoutWeight(1)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        this.MultiBarButtons()
      }
      .width('100%')
      .margin({ top: 10 })
      .alignItems(VerticalAlign.Center)
    }
  }

  /* 多选条上的四个按钮。⭐ **零参**（所以没有 L6 那条「参数按值传递 ⇒ 不刷新」的问题），
   * 两个分支共用同一份。
   * ⭐ 顺序与 `SaveActionRow`（删除 / 复制 / 移动）对齐 —— 用户 2026-10-03 说过这个顺序
   * 「看着更顺眼」，两处别分叉；`取消` 收尾。
   * ⚠️ `margin({ left: 8 })` 的分布照 `SaveActionRow`：**第一个按钮不能有左间距**，
   * 否则整排会往右缩 8vp。 */
  @Builder
  MultiBarButtons() {
    Row() {
      Button('删除')
        .fontSize(BUTTON_FONT_VP)
        .fontColor($r('sys.color.warning'))
        .backgroundColor($r('app.color.btn_neutral'))
        .enabled(this.multiPickCount() > 0)
        /* ⭐ 只**开窗**，不直接删 —— 见 `showMultiAsk`。⚠️ 名单每次重新**收起**：上一次展开过的
         * 话，这一次一进来就是展开的，而那是上一个批次的状态。 */
        .onClick(() => { this.showMultiAsk = true; this.multiListOpen = false; })
      Button('复制')
        .fontSize(BUTTON_FONT_VP)
        .fontColor(Color.White)
        .backgroundColor($r('sys.color.brand'))
        .margin({ left: 8 })
        .enabled(this.multiPickCount() > 0)
        .onClick(() => { this.askTransfer('copy'); })
      Button('移动')
        .fontSize(BUTTON_FONT_VP)
        .fontColor(Color.White)
        .backgroundColor($r('sys.color.brand'))
        .margin({ left: 8 })
        .enabled(this.multiPickCount() > 0)
        .onClick(() => { this.askTransfer('move'); })
      Button('取消')
        .fontSize(BUTTON_FONT_VP)
        .backgroundColor($r('app.color.btn_neutral'))
        .margin({ left: 8 })
        .onClick(() => { this.exitMulti(); })
    }
    /* ⛔ **不要在这里写 `width('100%')`** —— 理由见上面窄屏那一臂的注释。 */
  }

  @Builder
  SaveActionRow() {
    Row() {
      /* ⭐ 顺序是**删除 / 复制 / 移动**（2026-10-03 用户：「看着更顺眼」）。
       *
       * ⚠️⚠️ **配色在 2026-10-04 反了过来**（用户定的）：复制/移动是**主操作**（品牌蓝实底 + 白字），
       *    删除是**灰底 + 警示色字**。这一段原来写的是「删除自己带底色与警示色，与另外两个拉开」——
       *    ⛔ 那句话现在**不成立**了，删除反而是这三者里最不显眼的那个。别照着旧理由去「修」它。
       *    ⭐ 判据：靠颜色轻重说话，而不是靠位置。主操作给满色，破坏性动作给底色 + 警示词
       *    ——**不要**因为它是危险的就给它最亮的颜色（那会把鼠标往危险的那个上面引）。
       * ⛔ 三个都在同一个 `Row` 里靠右，改动顺序时**别动 `margin({ left: 8 })` 的分布** ——
       * 第一个按钮不能再有左间距，否则整排会往右缩 8vp。 */
      Button('删除')
        .fontSize(BUTTON_FONT_VP)
        .fontColor($r('sys.color.warning'))
        .backgroundColor($r('app.color.btn_neutral'))
        .onClick(() => { this.askDelete(); })
      Button('复制')
        .fontSize(BUTTON_FONT_VP)
        .fontColor(Color.White)
        .backgroundColor($r('sys.color.brand'))
        .margin({ left: 8 })
        .onClick(() => { this.askTransfer('copy'); })
      Button('移动')
        .fontSize(BUTTON_FONT_VP)
        .fontColor(Color.White)
        .backgroundColor($r('sys.color.brand'))
        .margin({ left: 8 })
        .onClick(() => { this.askTransfer('move'); })
    }
    /* ⭐ **靠右**（2026-10-02：「复制、移动、删除按钮应该在界面最右边，这样更符合人点击习惯」）。
     * ⚠️ 用 `justifyContent(FlexAlign.End)` 而不是塞一个 `Blank()` 占位 —— 靠右由**布局**保证，
     * 不需要多一个节点。⚠️ 拇指在右侧：动作放右、内容放左，是平板/手机上的通行摆法。 */
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
        /* 数据目录写出来 —— 这一屏的意义就是让「谁读哪一份数据」变得看得见。 */
        Text(this.selectedVersionDir())
          .fontSize(11).fontColor($r('sys.color.font_tertiary'))
          .margin({ top: 4 })
          .copyOption(CopyOptions.LocalDevice)

        /* ⭐⭐ **这一句是「按版本」这一屏真正的价值。**「哪个版本可以用这个存档」在机制上的真答案
         * 是「谁的 `user.home` 指向同一个目录，谁就看得见」。⚠️ 隔离**关着**时全部版本指向同一份 ⇒
         * 这句会写成「全部 N 个版本」，那不是 bug，正是「不隔离」的含义。 */
        if (this.selectedVersionSharedText() !== '') {
          Text(this.selectedVersionSharedText())
            .fontSize(11).fontColor($r('sys.color.font_tertiary'))
            .margin({ top: 10 })
        }

        if (!this.selectedVersionIsCurrent()) {
          /* 说的是**怎么去操作**，不是「不行」—— 门要能开。存档页的四个动作只作用于**当前版本**
           * 的数据（那是游戏实际会读的那份）。 */
          Text('这还不是当前版本。要操作这份数据，先在「首页」把它切过去。')
            .fontSize(11).fontColor($r('sys.color.font_tertiary'))
            .margin({ top: 10 })
        }

        Divider()
          .strokeWidth(1).color($r('app.color.launcher_border'))
          .margin({ top: 14, bottom: 14 })

        Text('这个目录里的存档')
          .fontSize(12).fontColor($r('sys.color.font_tertiary'))

        /* 2026-10-02：「右边的选择存档删除页应该能长按多选」。⚠️ 与「按存档」那边是**同一个**
         * `MultiBar` 与同一份选中集 —— 两处是同一件事。 */
        if (this.multiMode) {
          this.MultiBar()
        }

        /* ⭐⭐ 2026-10-02：「**按版本那里也要能管理存档**」。⛔ 原来这里只是一串只读文字
         * （看得到、动不了）⇒ 现在每一行**可以点**（与「按存档」那边用同一个选中状态），选中之后
         * 底下就是那三个动作。⚠️ 两处共用同一个 `selectedSave` ⇒ 在一边选了、切到另一边，
         * 选中的还是同一份 —— 它在两个视图里都是**同一个存档**。 */
        Scroll() {
          Column() {
            if (this.versionSaves.length === 0) {
              Text(this.selectedVersionHasDataText())
                .fontSize(12).fontColor($r('sys.color.font_secondary'))
                .margin({ top: 8 })
            }
            /* ⭐⭐ 这一段一起改掉了三件事（2026-10-02）：① 字体过小 ⇒ 名字 14、元数据 12；
             * ② 对齐 ⇒ 改成**三列**（名字吃剩余宽度，大小与时间各占定宽右对齐，原来是一整句拼的、三列全歪）；
             * ③ 热区太小 ⇒ 补内边距/圆角/底色，热区变成一整块（与左边版本列表同一形状）。
             * ⚠️ ✓ 用 `visibility` 而不是 `if`：`if` 会让未选中的行**少一个节点** ⇒ 两种行的列宽不一样
             * ⇒ 点一下整列就跳；`Visibility.Hidden` 照样占位，列不会动。 */
            ForEach(this.versionSaves, (sv: SaveEntry) => {
              Row() {
                Text(sv.label)
                  .fontSize(14)
                  .fontColor(this.rowHot(this.saveKey(this.versionSavesDir(), sv.id))
                             ? $r('sys.color.brand') : $r('sys.color.font_primary'))
                  .layoutWeight(1)
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })

                /* ⚠️ `'12vp'` 而不是 `12` —— 它在定宽列里，⛔ 不能跟着系统字体缩放。理由见常量那段。 */
                Text(formatSaveSize(sv.bytes))
                  .fontSize('12vp').fontColor($r('sys.color.font_tertiary'))
                  .width(SAVE_SIZE_COL_VP).textAlign(TextAlign.End)

                Text(formatSaveDate(sv.mtime))
                  .fontSize('12vp').fontColor($r('sys.color.font_tertiary'))
                  .width(SAVE_DATE_COL_VP).textAlign(TextAlign.End)
                  .margin({ left: 10 })

                Text('✓')
                  .fontSize('14vp').fontColor($r('sys.color.brand'))
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
                /* 与「按存档」那边同一套：点已选中的那一条 = 取消选中。⚠️ 别在这里直接赋值 ——
                 * 两处行为不一致时同一个动作在不同视图下结果不同，而那不是「两个视图」，是「两个东西」。 */
                this.openSaveRow(this.versionSavesDir(), sv.id);
              })
            }, (sv: SaveEntry) => this.saveRowKey(sv))
          }
          .width('100%')
        }
        .width('100%')
        .layoutWeight(1)
        .align(Alignment.TopStart)
        .scrollBar(BarState.Off)

        /* 选中了某一项才给动作 —— 没选时按下去无事可做，给出来只会让人点空。⛔ 多选态下一律不给：
         * 那会与上面那条多选条上的「删除」撞成一模一样的两个按钮（理由见 SaveDataPanel 那段）。 */
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

  /* 存档页。布局是「左侧列表选择存档/版本」＋右侧详情，且左右**对称**（不管左边选的是什么，
   * 右边永远是同一套「详情 + 对它可做的事」）。三处要点：① 宽度 100%（原 30–60% 可调，
   * 为的是把「查看存档数据」挪进右侧空白区）；② 「查看存档数据」不再弹窗（那个按钮与 `metaShown`
   * 弹窗**都已删除**）；③ 窄屏走子页。
   * ⛔ 没有用 `Navigation`/`NavDestination` —— 这一页的 `Navigation` 是 `NavigationMode.Stack`
   * 且**一个 NavDestination 都没有**，附近还栽过两次；这里用一个 `panelOpen` 开关在**同一个页签内**
   * 换内容，出口是左上角的返回箭头。
   * ⚠️ 两栏按 **3 : 7** 分（`layoutWeight`）：左边只是存档名与一行摘要，右边要放下整张元数据表；
   * 用 layoutWeight 而非写死 vp 是为了在任何窗口宽度下都自成比例（手机走子页，这条不参与）。 */
  /* 垃圾站。⭐ 它**不是第三种「视图」**（那种要挤进「按存档 / 按版本」那一排），而是**另一个地方** ——
   * 进出靠一个返回，与手机的详情子页同一套做法。理由：分段控件那两档回答「我怎么看这批存档」，
   * 垃圾站回答「我删掉的东西去哪了」，不是同一个问题。
   * ⚠️ 每一行自带三个动作（放回 / 归档 / 彻底删），**没有右侧详情栏**。 */
  /* 复制 / 移动的目标选择。⭐ 硬要求（2026-10-02）：「需要在移动前告诉用户移动后的效果是什么」
   * ⇒ 每一行都是**「动作 + 后果」**的形状，而不是一排光秃秃的版本名。
   * ⚠️ 目标列表**只列别的版本**：「移动到当前版本」什么都不会发生（放一行没意义的选项比不放更糟）；
   * 「复制到当前版本」= 同版本再存一份，那是**另一个动作**（改名复制），只对**手动存档**开放。 */
  @Builder
  TransferDialog() {
    Column() {
      Column() {
        /* ⭐ 多选态下源是一批 ⇒ 标题改念**个数**（念名字的话，三个存档的名字接在一起会溢出一行）。
         * ⛔ 源 =1 时保持原样「复制「名字」」—— 那是已经在用的样子。 */
        Text(this.transferSourceTitle())
          .fontSize(17).fontColor($r('sys.color.font_primary'))
          .width('100%').textAlign(TextAlign.Center)

        Text(this.transferSourceSubtitle())
          .fontSize(13).fontColor($r('sys.color.font_secondary'))
          .width('100%').textAlign(TextAlign.Center)
          .margin({ top: 10 })

        Divider().strokeWidth(1).color($r('app.color.launcher_border')).margin({ top: 14 })

        /* ⭐⭐ **先多选、再确定**（2026-10-02：「先多选再确定，而不是现在点了就尝试复制」）。⛔ 原来
         * 「点一行 = 立刻复制」，复制到三个版本要来回三趟，而且**没有后悔的机会** ⇒ 现在点只是**选中**，
         * 动作统一由底下的「确定」执行。
         * ⚠️ **移动是单选** —— 第一次搬走之后源就没了，第二个目标会搬一个不存在的东西。⛔ 按操作分：
         * 复制可多选、移动单选，并把这条差别做进**交互**（而不是做进报错）—— 让玩家选不出一个做不到的
         * 组合，比事后告诉他「不行」好。
         * ⚠️ 选中的样子**复用本项目已有的那套**（文字变 `brand` 色 + 右侧 ✓），⛔ 不引入 `Checkbox`
         * （它有自己的一套主题与获焦行为，本项目在焦点上栽过）。 */
        Scroll() {
          Column() {
            /* ---- 同版本再存一份（只有复制 + 源全是手动存档）----
             * ⚠️ 判据是**全部**（`transferAllManual`），⛔ 不是「第一个源的 kind」——
             * 混选时那样会让这一项出现、却只对其中几个生效。 */
            if (this.transferOp === 'copy' && this.transferAllManual()) {
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

            /* ---- 战役存档说明为什么没有上面那一项 ----
             * ⚠️ 对着**这批里有一个不是手动存档**就说 —— 混选时上面那一项整块不出现，
             * 不说一句的话玩家会以为它被删了（或者说不出为什么少了一项）。 */
            if (this.transferOp === 'copy'
                && !this.transferAllManual() && this.transferSourceRows().length > 0) {
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
                && !(this.transferOp === 'copy' && this.transferAllManual())) {
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

        /* 上一次「确定」的结果。⛔ 只是一句话，不是门 —— 没成功的会列在这儿。 */
        if (this.transferNote !== '') {
          Text(this.transferNote)
            .fontSize(12).fontColor($r('sys.color.warning'))
            .width('100%').margin({ top: 10 })
        }

        Divider().strokeWidth(1).color($r('app.color.launcher_border')).margin({ top: 8 })
        Row() {
          /* 选不出目标时**禁用**是对的：它不是逃生门，是这次动作本身。⚠️「别禁用逃生门」那条结论
           * 针对的是**出路**，而这里按下去必须得有个已选的目标，否则无事可做。 */
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
      /* 吞掉落在卡片上的点击 —— 与隔离窗同一处理由。 */
      .onClick(() => {})
    }
    .width('100%').height('100%')
    .backgroundColor('#80000000')
    .justifyContent(FlexAlign.Center)
    /* ⭐ 异形屏避让：遮罩本身要**铺满**（背景是全屏的），但卡片要落在避让区里面。
     * ⚠️ 为什么是加在遮罩的 padding 上、而不是靠外层 Stack 的 padding：见 Navigation 那处的说明。
     * ⚠️ 四边的 32 是**卡片自己的**边距（原本就有，只作用在左右），与避让无关，所以两者相加而不是覆盖。
     * ⚠️ 避让为 0 时这里与从前**逐像素相同**。 */
    .padding({ left: 32 + this.edgeVp('left'), right: 32 + this.edgeVp('right'),
               top: this.edgeVp('top'), bottom: this.edgeVp('bottom') })
    /* 整层淡入（遮罩 + 卡片一起）。 */
    .transition(enterFade())
  }

  @Builder
  VaultView() {
    Column() {
      Row() {
        /* ⚠️ 2026-10-02：「返回按钮太小了」。⭐ 字形 18 → **26** 并给足内边距 —— 可点区域从约
         * 18×18 变成约 46×46，接近触摸目标下限（约 44）。⛔ 别只放大字形而不给内边距：字形大了但
         * 热区还贴着笔画，照样点不中。 */
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(26).fontColor([$r('sys.color.brand')])
          .padding({ left: 10, right: 14, top: 10, bottom: 10 })
          .onClick(() => { this.closeVault(); })
        Text('垃圾站')
          .fontSize(18).fontColor($r('sys.color.font_primary'))
          .layoutWeight(1)
        Text(this.vaultEntries.length === 0 ? '空' : (String(this.vaultEntries.length) + ' 项'))
          .fontSize(12).fontColor($r('sys.color.font_tertiary'))
        /* ⭐ 一键清空。**只在有东西时出现** —— 空的时候放一个永远点不动的按钮是纯噪音。
         * ⛔ 它真删、不可逆，所以只**开窗**，删除在 `VaultClearAskDialog` 里确认之后才发生。
         * ⚠️ 用 `warning` 色而不是 `brand`：这一屏上 `brand` 是「点进去看」，而这个是「删掉」。 */
        if (this.vaultEntries.length > 0) {
          Text('清空')
            .fontSize(13).fontColor($r('sys.color.warning'))
            .padding({ left: 14, right: 4, top: 6, bottom: 6 })
            .onClick(() => { this.showVaultClearAsk = true; })
        }
      }
      .width('100%')
      .padding({ left: 12, right: 16, top: 16, bottom: 8 })
      .alignItems(VerticalAlign.Center)

      /* 保留期。⭐ 2026-10-02 定的是**全局**（「一次性设成全局」）—— 每次删都问一遍会把同一个问题的
       * 答案反复要一遍。⚠️ 放在这一屏而不是设置页：玩家是在**看垃圾站**的时候才会想「留多久」，
       * 一旦离开这一屏那个念头就没了。 */
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

      /* 上一次操作的结果。⛔ 只是一句话，不是门 —— 失败也照旧能继续用。 */
      if (this.vaultNote !== '') {
        Text(this.vaultNote)
          .fontSize(12).fontColor($r('sys.color.warning'))
          .width('100%').margin({ top: 10 }).padding({ left: 16, right: 16 })
      }
      /* 清掉到期条目时**说一声** —— 默默地少掉几项会让玩家以为是自己记错了。 */
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
            /* ⛔ **key 必须带上【会变的字段】** —— 这就是 2026-10-02 报的「取消归档 / 放回，点了
             * UI 不刷新」的成因之一。⭐ ArkUI 的 `ForEach` 按 key 做差分：**key 没变的那一项会被
             * 【复用】、不会重建** ⇒ 行里的文字永远停在旧值上；而 `e.id` 只在**增删**时变，归档/取消
             * 归档是**原地改内容** ⇒ key 一模一样 ⇒ 界面一动不动。
             * ⚠️ 所以 key 里要放**渲染真正依赖的**那几个字段：归档位与到期时刻。⛔ 别只写 `e.id`。 */
            }, (e: VaultEntry) => e.id + '|' + (e.archived ? 'a' : 'n') + '|' + String(e.expiresMs))
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 12 })
        }
        .width('100%')
        .justifyContent(FlexAlign.Start)
        .alignItems(VerticalAlign.Top)
      }
      .width('100%')
      .layoutWeight(1)
      /* ⭐ 与「按存档」/「按版本」那两个列表写成同一形状（那两处是对的，这里原来不是）：
       * ⛔ 内层那句 `height('100%')` 让内容高度**恒等于视口** ⇒ 可滚动余量 0 ⇒ 列表滚不动；
       *    而它在界面上看起来只是「列表就这么长」，能藏很久（用户 2026-10-03 报的就是它）。
       * ⚠️ 去掉之后会露出第二个毛病：`Scroll.align` **默认居中**，条目少时会停在屏幕中间
       *    ⇒ 所以必须补上 `TopStart`。**只改一行都不够** —— 这两件事互相遮丑。 */
      .align(Alignment.TopStart)
      .scrollBar(BarState.Off)

      /* 与悬浮底栏之间的留白。见 BAR_CLEARANCE_VP。 */
      Blank().height(BAR_CLEARANCE_VP)
    }
    .width('100%').height('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /* 删除的确认框。⭐ **它同时承担两件事**：「确认删除」与「选保留方式」（那两个选项就是
   * 垃圾站里条目的两种状态：到期清理 / 归档不清理）⇒ 不需要第二个窗。
   * ⚠️ 结构照抄「打开数据隔离」那个窗（同屏遮罩 + 卡片 + 点卡片不冒泡 + **点空白不关**）——
   * 手滑点空白就消失的确认框比没有更糟。⛔ 别照「关于 / 查看数据」那两个窗加「点外面也关」，它们只读。 */
  /* ⭐⭐ 多选删除的确认框（2026-10-02）。形状是他指定的：「标题显示多个，超长改成 ...，**用户可以点击**，
   * 出现一个小的提示窗展示**所有选中的存档（包括来源于哪里）**」⇒ ① 标题写出**有几个**；② 名字超长截成
   * `...`；③ 可点，点开小名单、每条带**来源**。⚠️ 名单**默认收起**且**放在这个窗里面**而不是再弹一层
   * （两层弹窗叠在一起时返回键该关哪一层会变成问题）。⛔ 没有「逐条选择保留方式」那一套 —— 一批就是一次
   * 决定，保留期用全局那个。⚠️ 结构照抄 `DeleteAskDialog`（同屏遮罩 + 卡片 + 点卡片不冒泡 + **点空白不关**）。 */
  @Builder
  MultiDeleteAskDialog() {
    Column() {
      Column() {
        Text('删除这 ' + String(this.multiPicked.length) + ' 个存档')
          .fontSize(17).fontColor($r('sys.color.font_primary'))
          .width('100%').textAlign(TextAlign.Center)

        /* 名字那条。⭐ `▾` / `▴` 是**它的可点性**唯一的视觉线索 —— ⛔ 别只靠「看起来像一行字」
         * 暗示它能点（有出口但没人知道它在）。
         * ⚠️ 箭头**不放进那个 Text 里**：它会被 `Ellipsis` 一起截掉，于是名字越长越看不见入口 ——
         * 恰好把最需要展开的那种情形挡掉。 */
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
                  /* 来源 —— 与垃圾站那行用**同一个** `ownerOfDir`，两处说法不会分叉。 */
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
          /* 给个上限，让名单自己滚 —— ⛔ 不给的话一次选二十个会把按钮顶出屏幕，而按钮正是这个窗
           * 存在的理由（与启动失败那个窗同一条道理）。 */
          .constraintSize({ maxHeight: 220 })
          .align(Alignment.TopStart)
          .margin({ top: 10 })
        }

        Divider().strokeWidth(1).color($r('app.color.launcher_border')).margin({ top: 14 })

        /* 与单删那个窗**同一套措辞**（`放进垃圾站（保留到 X）`）—— 否则玩家会以为是两种不同的去向。 */
        Button('放进垃圾站（保留到 ' + this.deleteExpiryDate() + '）')
          .fontSize(15)
          .constraintSize({ maxWidth: '100%' }).alignSelf(ItemAlign.Center)
          .margin({ top: 16 })
          .onClick(() => { this.deleteMultiToVault(); })

        Divider().strokeWidth(1).color($r('app.color.launcher_border')).margin({ top: 14 })
        Button('取消')
          .fontSize(14)
          .constraintSize({ maxWidth: '100%' }).alignSelf(ItemAlign.Center)
          .margin({ top: 12 })
          .onClick(() => { this.showMultiAsk = false; })
      }
      .width('100%')
      .constraintSize({ maxWidth: this.dialogWidthVp() })
      .padding(20)
      .backgroundColor($r('app.color.launcher_card'))
      .borderRadius(CARD_RADIUS_VP)
      .alignItems(HorizontalAlign.Start)
      /* 吞掉落在卡片上的点击 —— 与隔离窗同一处理由。 */
      .onClick(() => {})
    }
    .width('100%').height('100%')
    .backgroundColor('#80000000')
    .justifyContent(FlexAlign.Center)
    /* ⭐ 异形屏避让：遮罩本身要**铺满**（背景是全屏的），但卡片要落在避让区里面。
     * ⚠️ 为什么是加在遮罩的 padding 上、而不是靠外层 Stack 的 padding：见 Navigation 那处的说明。
     * ⚠️ 四边的 32 是**卡片自己的**边距（原本就有，只作用在左右），与避让无关，所以两者相加而不是覆盖。
     * ⚠️ 避让为 0 时这里与从前**逐像素相同**。 */
    .padding({ left: 32 + this.edgeVp('left'), right: 32 + this.edgeVp('right'),
               top: this.edgeVp('top'), bottom: this.edgeVp('bottom') })
    /* 整层淡入（遮罩 + 卡片一起）。 */
    .transition(enterFade())
  }

  /** 清空垃圾站的二次确认。
   *
   * ⭐ 与 `DeleteAskDialog` 的写法**不同**，而且这里是有意的：那个窗把区别写在**按钮标签**上就够
   * （「放进垃圾站」vs「归档」是两种去向）；而这里**没有第二种去向可选** ——
   * 玩家唯一需要知道的是**它不可撤销**，那只能写成一句话。
   * ⚠️ 那句话不能省：「删到垃圾站」这一整套设计一直在告诉玩家「删了还能找回」，
   * 所以「这一次找不回」必须由界面主动说，⛔ 不能指望他自己推断出来。 */
  @Builder
  VaultClearAskDialog() {
    Column() {
      Column() {
        Text('清空垃圾站？')
          .fontSize(17).fontColor($r('sys.color.font_primary'))
          .width('100%').textAlign(TextAlign.Center)

        Text('这 ' + String(this.vaultEntries.length) + ' 个存档会被永久删除，不能撤销。'
             + '\n垃圾站之外没有第二份。')
          .fontSize(13).fontColor($r('sys.color.font_secondary'))
          .width('100%').margin({ top: 12 })

        if (this.vaultArchivedCount() > 0) {
          Text('其中 ' + String(this.vaultArchivedCount())
               + ' 个是归档的 —— 归档本来不会自动清理，只有你手动删它才会消失。')
            .fontSize(12).fontColor($r('sys.color.font_tertiary'))
            .width('100%').margin({ top: 8 })
        }

        Divider().strokeWidth(1).color($r('app.color.launcher_border')).margin({ top: 14 })

        /* 按钮标签上再把「永久」和数量说一遍 —— 它在视觉上就是那个动作本身。 */
        Button('永久删除这 ' + String(this.vaultEntries.length) + ' 个')
          .fontSize(15)
          .constraintSize({ maxWidth: '100%' }).alignSelf(ItemAlign.Center)
          .margin({ top: 16 })
          .onClick(() => { this.clearVaultAll(); })

        Divider().strokeWidth(1).color($r('app.color.launcher_border')).margin({ top: 14 })
        Button('取消')
          .fontSize(14)
          .constraintSize({ maxWidth: '100%' }).alignSelf(ItemAlign.Center)
          .margin({ top: 12 })
          .onClick(() => { this.showVaultClearAsk = false; })
      }
      .width('100%')
      .constraintSize({ maxWidth: this.dialogWidthVp() })
      .padding(20)
      .backgroundColor($r('app.color.launcher_card'))
      .borderRadius(CARD_RADIUS_VP)
      .alignItems(HorizontalAlign.Start)
      /* 吞掉落在卡片上的点击 —— 与另外几个确认窗同一处理由（`DeleteAskDialog` 的注释）。 */
      .onClick(() => {})
    }
    .width('100%').height('100%')
    .backgroundColor('#80000000')
    .justifyContent(FlexAlign.Center)
    /* 异形屏避让，与另外几个确认窗逐字相同 —— ⛔ 别在这里另发明一套边距。 */
    .padding({ left: 32 + this.edgeVp('left'), right: 32 + this.edgeVp('right'),
               top: this.edgeVp('top'), bottom: this.edgeVp('bottom') })
    .transition(enterFade())
  }

  /* 「删除这个版本」的确认窗。
   * ⭐ 取舍与 `DeleteAskDialog` 同一条：把**代价写进按钮标签**，而不是在按钮上面写一段说明 ——
   * 玩家应当看一眼按钮就知道自己在选什么。
   * ⚠️ 但有一件事没法塞进标签：**共用数据**（还有别的版本在读）和**唯一那份未隔离数据**，
   * 那两个必须单独说，因为按下去损的不止是刚选的那个版本。 */
  /* 左滑露出的那一块。
   *
   * ⭐⭐ **只画一个图标，不画底色** —— 这一条同时解掉两个问题：
   *   ① 露出区的**尺寸就是 `builder` 内容的尺寸**（`actionAreaDistance` 是「滑多远才触发
   *      `onAction`」的阈值，**不是**色块大小，别被名字骗了）。做成整块底色的话，那块矩形
   *      比列表项高、又没有圆角 ⇒ 拉出来时**卡片右下角那个圆角就被盖掉了**。
   *   ② 露出区自己**没有背景**，所以唯一画出来的东西就是这里的内容。
   *      ⇒ 内容是圆的 ⇒ 圆角问题从根上不存在，⛔ 不需要去和框架较劲。
   *
   * ⚠️ 外层 `Row` 只负责给一个**够大的点击区域**（图标本身 26fp 小于 48vp 的最小触控目标），
   *    它自己不画任何东西；真正被看见的只有里面那个符号。
   * ⛔ `onAction`（滑到底自动触发）仍然不给 —— 「滑到底」顺手就能做出来，让它直接弹确认窗太容易误触。
   * ⚠️ 以后要加编辑、重命名之类，每个动作各占一个这样的小图标，**挤在一起要留出间距**。 */
  @Builder
  SwipeDeleteAction(g: GameJar) {
    Row() {
      SymbolGlyph($r('sys.symbol.ohos_trash_circle'))
        .fontSize(26)
        .fontColor([$r('app.color.danger')])
    }
    .height('100%')
    .padding({ left: 16, right: 20 })
    .justifyContent(FlexAlign.Center)
    .onClick(() => { this.openGameDeleteAsk(g); })
  }


  /** 询问窗里那段话：说清**往哪切**、**现在有多少东西**、**复制是搬运还是抄一份**。 */
  /* ⛔ 这里原来有一个 `storageSwitchLine()`，拼那段说明文字（往哪切 / 有多少存档 / 两个选项
   * 各对旧那份做什么）。**用户 2026-10-04 要求整段去掉，函数删了。**
   * ⚠️ 它顺带丢掉了三件事，都记在这儿，将来要加回来知道该加什么：
   *    ① 目标位置是「下载」里的应用文件夹（`data` 子目录）；
   *    ② 这份数据里有多少存档 / 模组 / 蓝图（`countsOf()`）；
   *    ③ **「移动会把旧那份删掉」** —— 这一条最要紧：它是玩家**唯一**可能在事后去旧位置
   *       找一个已经不在了的东西的情形。⛔ 要加回来时**别再用 `**` 写粗体**，
   *       `Text()` 不认 markdown、会原样显示两个星号（那次就是这么被发现的）。 */

  @Builder
  GameDeleteAskDialog() {
    Column() {
      Column() {
        /* ⭐ 标题两行（用户 2026-10-04 给的形状）：
         *   第一行 = **「永久删除」**，用危险色 —— 它说明【动作的性质】；
         *   第二行 = **具体哪个文件** —— 它说明【对象】。
         * ⛔ 原来是一行「删除「160.5（文件名）」」：既没说清是永久删除，又把两件事挤在一起。
         * ⚠️ 第二行用文件名而不是版本号为主：同一版本号可能有好几个 jar，
         *    而玩家要确认的正是"删的是哪一个文件"。 */
        Text('永久删除')
          .fontSize(17).fontColor($r('app.color.danger'))
          .width('100%').textAlign(TextAlign.Center)
        Text(this.gameDeleteLabel)
          .fontSize(13).fontColor($r('sys.color.font_secondary'))
          .width('100%').textAlign(TextAlign.Center)
          .margin({ top: 6 })

        if (!this.jarHasOwnData()) {
          /* 隔离关着 ⇒ 全应用唯一那份数据。⛔ 这条路连选项都不给。 */
          Text('这个版本用的是「未隔离」的那一份数据 —— 全应用只有那一份，'
               + '删它会把所有未隔离版本的数据一起清掉。\n所以这里只提供「只删除游戏」。')
            .fontSize(12).fontColor($r('sys.color.font_secondary'))
            .width('100%').margin({ top: 10 })
        } else if (this.otherVersionsOnSelectedDir().length > 0) {
          /* ⛔ 共用这一条必须点名：按下去损的不止是他刚选的那个版本。 */
          Text('这份数据还有 ' + String(this.otherVersionsOnSelectedDir().length)
               + ' 个版本在读（' + this.otherVersionsText() + '），'
               + '里面现在有 ' + String(this.jarDataSaveCount()) + ' 个存档。'
               + '\n连数据一起删，它们也会一起没有。')
            .fontSize(12).fontColor($r('sys.color.warning'))
            .width('100%').margin({ top: 10 })
        }

        Divider().strokeWidth(1).color($r('app.color.launcher_border')).margin({ top: 14 })

        Button('只删除游戏（保留数据）')
          .fontSize(15)
          .constraintSize({ maxWidth: '100%' }).alignSelf(ItemAlign.Center)
          .margin({ top: 16 })
          .onClick(() => { this.deleteGame(false); })

        /* ⛔ 数据不能删时这个按钮**不出现**（而不是出现再置灰）—— 置灰的按钮会让人一直找
         * 「怎么才能点亮它」，而上面那句话已经解释了原因。 */
        if (this.jarHasOwnData()) {
          Button('删除游戏和数据')
            .fontSize(15)
            .fontColor($r('sys.color.warning'))
            .backgroundColor($r('app.color.launcher_bg'))
            .constraintSize({ maxWidth: '100%' }).alignSelf(ItemAlign.Center)
            .margin({ top: 10 })
            .onClick(() => { this.deleteGame(true); })
        }

        Divider().strokeWidth(1).color($r('app.color.launcher_border')).margin({ top: 14 })
        Button('取消')
          .fontSize(14)
          .constraintSize({ maxWidth: '100%' }).alignSelf(ItemAlign.Center)
          .margin({ top: 12 })
          .onClick(() => { this.showGameDeleteAsk = false; })
      }
      .width('100%')
      .constraintSize({ maxWidth: this.dialogWidthVp() })
      .padding(20)
      .backgroundColor($r('app.color.launcher_card'))
      .borderRadius(CARD_RADIUS_VP)
      .alignItems(HorizontalAlign.Start)
      /* 吞掉落在卡片上的点击 —— 与另外几个确认窗同一处理由（`DeleteAskDialog` 的注释）。 */
      .onClick(() => {})
    }
    .width('100%').height('100%')
    .backgroundColor('#80000000')
    .justifyContent(FlexAlign.Center)
    /* 异形屏避让，与另外几个确认窗逐字相同 —— ⛔ 别在这里另发明一套边距。 */
    .padding({ left: 32 + this.edgeVp('left'), right: 32 + this.edgeVp('right'),
               top: this.edgeVp('top'), bottom: this.edgeVp('bottom') })
    .transition(enterFade())
  }

  @Builder
  DeleteAskDialog() {
    Column() {
      Column() {
        Text('删除「' + this.selectedSaveLabel() + '」')
          .fontSize(17).fontColor($r('sys.color.font_primary'))
          .width('100%').textAlign(TextAlign.Center)

        /* ⛔ **这个框里【没有任何说明文字】**（2026-10-02：「下面按钮都说了放到垃圾站，
         * 那上面的文字说明根本没用」）。理由不只是「嫌啰嗦」：原来把**区别**放在**按钮上面的文字**
         * 里，而按钮本身只说「放进垃圾站」「归档」⇒ 玩家要**先读上面、再看下面**才知道自己在选什么。
         * ⇒ 把区别**直接写进按钮标签**，一处说清。
         * ⚠️ 日期仍保留（它有信息量、且只有这里有），但压到「保留到 2026-10-09」—— 时分对 3/7/30 天是噪音。 */
        Divider().strokeWidth(1).color($r('app.color.launcher_border')).margin({ top: 14 })

        Button('放进垃圾站（保留到 ' + this.deleteExpiryDate() + '）')
          .fontSize(15)
          .constraintSize({ maxWidth: '100%' }).alignSelf(ItemAlign.Center)
          .margin({ top: 16 })
          .onClick(() => { this.doVaultDelete(false); })

        Button('归档（不自动清理）')
          .fontSize(15)
          .constraintSize({ maxWidth: '100%' }).alignSelf(ItemAlign.Center)
          .margin({ top: 10 })
          .onClick(() => { this.doVaultDelete(true); })

        Divider().strokeWidth(1).color($r('app.color.launcher_border')).margin({ top: 14 })
        Button('取消')
          .fontSize(14)
          .constraintSize({ maxWidth: '100%' }).alignSelf(ItemAlign.Center)
          .margin({ top: 12 })
          .onClick(() => { this.showDeleteAsk = false; })
      }
      .width('100%')
      .constraintSize({ maxWidth: this.dialogWidthVp() })
      .padding(20)
      .backgroundColor($r('app.color.launcher_card'))
      .borderRadius(CARD_RADIUS_VP)
      .alignItems(HorizontalAlign.Start)
      /* 吞掉落在卡片上的点击 —— 与隔离窗同一处理由。 */
      .onClick(() => {})
    }
    .width('100%').height('100%')
    .backgroundColor('#80000000')
    .justifyContent(FlexAlign.Center)
    /* ⭐ 异形屏避让：遮罩本身要**铺满**（背景是全屏的），但卡片要落在避让区里面。
     * ⚠️ 为什么是加在遮罩的 padding 上、而不是靠外层 Stack 的 padding：见 Navigation 那处的说明。
     * ⚠️ 四边的 32 是**卡片自己的**边距（原本就有，只作用在左右），与避让无关，所以两者相加而不是覆盖。
     * ⚠️ 避让为 0 时这里与从前**逐像素相同**。 */
    .padding({ left: 32 + this.edgeVp('left'), right: 32 + this.edgeVp('right'),
               top: this.edgeVp('top'), bottom: this.edgeVp('bottom') })
    /* 整层淡入（遮罩 + 卡片一起）。 */
    .transition(enterFade())
  }

  /* ====================================================================
   * 整包导入 / 导出
   * ==================================================================== */

  /** 临时目录（沙箱内）—— 打包与解包都在这里做。
   * ⚠️ 必须钉在 `NATIVE_FILES` 那条路径上（`exportDiagnostics` 的说明：ArkTS 的 `ctx.filesDir`
   *    是 HAP 级目录，两处不通用）。 */
  private packTmpDir(): string {
    return '/data/storage/el2/base/files/.temp/datapack';
  }

  /** 本应用在 Downloads 里的数据根 —— **就是那个【包名】文件夹本身**。
   *
   * ⭐⭐ **必须用包名，不能自己起名字。** 这条是从参考项目 AMCL 那儿学来的、也是本项目
   *     写在 README 致谢里的一条：**文件夹用【包名】命名，系统才认作本应用的
   *     （「所有权式访问」），跨重启有效**；自取的名字（它早期用的 `AMCL`）系统认不出来。
   * ⛔ 我第一版正是踩了这个坑：拿**显示名**建了个新顶层文件夹 `Download/MindustryArk`
   *     ⇒ 建不出来 ⇒ 导出直接失败（用户 2026-10-03 当场报）。**「Mindustry Ark」是
   *     玩家看到的名字，不是磁盘上的名字。**
   *
   * ⭐ 布局（用户 2026-10-03 定）—— 与 `games/` **并列**、⛔不塞进它里面：
   *     ```
   *     <Download>/<包名>/games/     游戏 jar（模组那边建立的，游戏自带浏览器打开它）
   *     <Download>/<包名>/exports/   导出的数据包      ← 本次新增
   *     <Download>/<包名>/backups/   覆盖导入前的备份  ← 本次新增
   *     ```
   *
   * ⚠️ 直接就用 `externalRootPath()` 那个值（平台报给我们、且**探针实测能写**的那个），
   *    不自己拼 Download 的绝对路径 —— 设备之间不一样。
   * ⚠️ 拿不到时返回 `''`，调用方要**如实说明**落在了哪，不要静默换地方。 */
  private packRoot(): string {
    const base: string = externalRootPath(this.filesDir);
    if (base === '') {
      return '';
    }
    /* ⚠️ 它必须**已经存在** —— 这里只确认，不新建（新建顶层文件夹会失败，见上）。
     * 那个文件夹由模组那条路建立（`ModImporter.ensureModFolder`）。 */
    return isDir(base) ? base : '';
  }

  /** 导出的数据包放哪。拿不到用户可见位置时返回 `''`。 */
  private exportsDir(): string {
    const root: string = this.packRoot();
    if (root === '') {
      return '';
    }
    const dir: string = root + '/exports';
    return ensureDir(dir) ? dir : '';
  }

  /** 覆盖导入前的自动备份放哪。
   *
   * ⛔⛔ **不能放在沙箱里** —— 我第一版放在 `.temp/datapack/`，用户当场问
   *     「存沙箱我没看到怎么恢复啊」。**一个恢复不了的备份等于没有备份**，
   *     而且它还会让人以为有退路。
   * ⭐ 现在放用户可见的 `MindustryArk/backups/`：拷得出来，
   *    而**恢复的方式就是「导入数据」再选它一遍** —— 不需要任何新的恢复 UI。 */
  private backupsDir(): string {
    const root: string = this.packRoot();
    if (root === '') {
      return '';
    }
    const dir: string = root + '/backups';
    return ensureDir(dir) ? dir : '';
  }

  /** 导入：选 zip → 拷进沙箱 → 解压 → 定位数据根 → 校验 → 问目标。
   *
   * ⚠️ 每一步失败都**在这一层就停**，并给一句人话 —— 不要带着半成品去问「你要覆盖哪个版本」。 */
  private async startImport(): Promise<void> {
    this.importMsg = '';
    let uri: string = '';
    try {
      const opts: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      /* ⭐ 只让选 zip。⚠️ 这是本项目第一次用 `select()` —— 现有的 picker 用法只有「保存」模式。 */
      opts.fileSuffixFilters = ['.zip'];
      opts.maxSelectNumber = 1;
      const view: picker.DocumentViewPicker = new picker.DocumentViewPicker(getContext(this) as common.Context);
      const uris: Array<string> = await view.select(opts);
      if (uris === undefined || uris.length === 0 || uris[0] === '') {
        return;   /* 玩家取消了 —— 不是错误，别弹提示。 */
      }
      uri = uris[0];
    } catch (e) {
      const err = e as BusinessError;
      this.showNotice('打不开文件选择器：' + err.message + ' (code=' + err.code + ')', 'import');
      return;
    }

    const tmp: string = this.packTmpDir();
    if (!ensureDir(tmp)) {
      this.showNotice('建不出临时目录。', 'import');
      return;
    }
    /* ⚠️ 扩展名必须逐字是 `.zip`（`decompressFile` 的硬要求），所以落地名由我们定，不用原名。 */
    const localZip: string = tmp + '/import.zip';
    /* ⚠️ 与 `packDataDir` 的内部暂存（`packing`）**必须不同** —— 见那边的说明。 */
    const staging: string = tmp + '/incoming';
    this.importMsg = '正在读取压缩包…';

    const copyErr: string = readUriToFile(uri, localZip);
    if (copyErr !== '') { this.showNotice(copyErr, 'import'); return; }

    const acc: TreeStat = newTreeStat();
    removeTree(staging, 0, acc);
    this.importMsg = '正在解压…';
    const unErr: string = await unpackZip(localZip, staging);
    if (unErr !== '') { this.showNotice(unErr, 'import'); return; }

    this.importMsg = '正在检查内容…';
    const root: string = locateDataRoot(staging);
    if (root === '') {
      this.showNotice('这个包里找不到游戏数据（既没有 saves/，也没有 mods/ 或 settings.bin），'
                      + '或者里面有好几个候选目录、分不清哪个才是。', 'import');
      return;
    }
    const vErr: string = validatePack(root);
    if (vErr !== '') { this.showNotice(vErr, 'import'); return; }

    /* 到这一步才允许问「放到哪」—— 见这个方法的说明。 */
    this.importRoot = root;
    this.importNote = countPackable(root);
    this.importMsg = '';
    this.importOpen = true;
  }

  /** 把若干**已校验**的数据根落到一个目标。
   * ⭐ 语义（用户 2026-10-03 定）：**每次导入都问目标**，而「覆盖 / 新建」由**目标有没有数据**决定：
   *    有 ⇒ 先整包备到垃圾站再覆盖（不可逆的事必须先留退路）；没有 ⇒ 直接写。 */
  private async importIntoOne(t: VersionEntry, index: number,
                              out: ImportOutcome): Promise<void> {
    const label: string = t.version === '' ? t.label : ('v' + t.version);
    if (t.dataDir === '') {
      out.fails.push(t.label + '：没有数据目录（读不出隔离键）');
      return;
    }
    if (!ensureDir(t.dataDir)) {
      out.fails.push(t.label + '：建不出目标目录');
      return;
    }

    /* ⭐ 目标已有数据 ⇒ **先备份**。不清空整个目录：整包导入是**叠加**语义
     * （同名覆盖、其余保留），所以不需要先删 —— 也就没有「清空到一半失败」这个状态。 */
    if (packableItems(t.dataDir).length > 0) {
      this.importMsg = '正在备份「' + t.label + '」…';
      const bak: string = this.backupPathFor(label, index);
      /* ⚠️ 打包是异步且可能几十 MB ⇒ 在这里 await，**逐个串行**：
       *    并行会把内存和 IO 顶满，而且失败时说不清是哪一个目标出的问题。 */
      const err: string = await packDataDir(t.dataDir, this.packTmpDir(), bak);
      if (err !== '') {
        /* ⛔ 备份失败 ⇒ **不动这一个目标**。这是「不可逆的事先留退路」的落点。
         * ⚠️ 只跳过它，其余目标继续 —— 一个目标备不出来不该把整批停掉。 */
        out.fails.push(t.label + '：备份失败，已跳过（它的数据没动）—— ' + err);
        return;
      }
      out.backups += 1;
      out.anyBackupInSandbox = out.anyBackupInSandbox || (this.backupsDir() === '');
    }

    this.importMsg = '正在写入「' + t.label + '」…';
    const acc: TreeStat = newTreeStat();
    copyTreeInto(this.importRoot, t.dataDir, 0, acc);
    out.dirs += acc.dirs;
    out.files += acc.files;
    if (acc.failed > 0) {
      out.fails.push(t.label + '：' + acc.firstError);
      return;
    }
    out.done += 1;
  }

  /** 确认之后：把暂存里的数据逐个落到**每一个**勾中的目标。
   *
   * ⭐ 用户 2026-10-03 定的形状是「**多选 + 确认**」。所以这里先关窗、再干活 ——
   *    从这一刻起不再需要玩家输入，窗留着只会挡住进度提示。
   * ⛔⛔ 原来的 `applyImportTo` 有**四条出路、只有三条关窗**（目标「没有数据」那条直连
   *    `copyImportInto`，而它从不碰 `importOpen`）⇒ 那条路上框一直开着，再点第二项就**又导入一次**。
   *    用户报的「点完不关」就是它。 */
  private async confirmImport(): Promise<void> {
    const targets: VersionEntry[] = this.pickedTargets();
    if (targets.length === 0) {
      return;
    }
    this.importOpen = false;
    this.importMsg = '正在导入…';

    const out: ImportOutcome = newImportOutcome();
    for (let i: number = 0; i < targets.length; i += 1) {
      await this.importIntoOne(targets[i], i, out);
    }

    /* ⭐ 暂存在**全部走完之后**才清，而且只清一次。
     * ⛔ 原来 `copyImportInto` 每落一个目标就清一次 ⇒ 多目标时第二个目标无源可拷。
     * ⚠️ 即便有目标失败也清：暂存是这次导入的中间产物，成功的那几处已经落好了。 */
    const clean: TreeStat = newTreeStat();
    removeTree(this.importRoot, 0, clean);
    this.importRoot = '';
    this.importMsg = '';
    this.importPicked = [];
    this.refresh();

    /* ⚠️ 汇总**不自动消失**（用户 2026-10-03 的要求）—— 「需要重启游戏」这条必须留着让玩家看到，
     *    而自动消失的提示恰好会在最需要它的时候不见。它带一个 ✕ 由玩家自己关。 */
    const head: string = out.done === 0
      ? '没有一处导入成功。'
      /* ⚠️ 写「合计」—— 这几个数是**所有目标加起来**的。选了三处就是三倍，
       *    不加这两个字会被读成「每个目标这么多」。 */
      : ('已导入到 ' + String(out.done) + ' 处（合计 '
         + String(out.dirs) + ' 个目录 / ' + String(out.files) + ' 个文件）');
    const bakNote: string = out.backups === 0 ? ''
      : ('\n覆盖前的备份有 ' + String(out.backups) + ' 份，在 '
         + (out.anyBackupInSandbox
            ? '⚠️ 应用沙箱里（外面拿不到），「导入数据」也够不着它'
            : this.backupsDir())
         + ' —— 要恢复就用「导入数据」再选那个文件。');
    const failNote: string = out.fails.length === 0 ? ''
      : ('\n有 ' + String(out.fails.length) + ' 处没成功：' + out.fails.join('；'));
    this.showNotice(head + bakNote + failNote + '\n需要重启游戏才看得到。', 'toast');
  }

  /** 勾中的目标，按 `dataDir` **去重** —— 两个版本共用同一份数据时只算一个目标。 */
  private pickedTargets(): VersionEntry[] {
    const all: VersionEntry[] = [this.liveImportTarget()];
    for (const v of this.versions) {
      all.push(v);
    }
    const out: VersionEntry[] = [];
    const seen: string[] = [];
    for (const t of all) {
      if (this.importPicked.indexOf(t.dataDir) < 0) {
        continue;
      }
      if (t.dataDir === '' || seen.indexOf(t.dataDir) >= 0) {
        continue;
      }
      seen.push(t.dataDir);
      out.push(t);
    }
    return out;
  }

  private isImportPicked(dir: string): boolean {
    return dir !== '' && this.importPicked.indexOf(dir) >= 0;
  }

  private toggleImportPick(dir: string): void {
    if (dir === '') {
      return;   /* 读不出数据目录的目标选不了 —— 行里已经写明原因了。 */
    }
    const i: number = this.importPicked.indexOf(dir);
    if (i < 0) {
      this.importPicked = this.importPicked.concat([dir]);
      return;
    }
    const next: string[] = this.importPicked.slice();
    next.splice(i, 1);
    this.importPicked = next;
  }

  /** 「全选」= 所有**互不相同**的数据目录。 */
  private pickAllImportTargets(): void {
    const all: VersionEntry[] = [this.liveImportTarget()];
    for (const v of this.versions) {
      all.push(v);
    }
    const out: string[] = [];
    for (const t of all) {
      if (t.dataDir !== '' && out.indexOf(t.dataDir) < 0) {
        out.push(t.dataDir);
      }
    }
    this.importPicked = out;
  }

  /** 备份文件的落点。
   * ⛔⛔ **不能只靠 `stampNow()` 区分** —— 它只精确到**分钟**（`DataPack.ets:58`），
   *    所以同一分钟内、同名标签的两次备份会拼出同一个名字，而**备份被覆盖等于没备份**。
   *    这里加两重保险：批内序号 `index`，以及撞到已有文件时再加 `-2`/`-3`。 */
  private backupPathFor(label: string, index: number): string {
    const base: string = 'Mindustry-' + label + '-' + stampNow()
                         + (index > 0 ? '-' + String(index + 1) : '');
    const dir: string = this.backupsDir();
    if (dir === '') {
      /* 拿不到用户可见目录 ⇒ 退回沙箱。⚠️ 调用方**必须如实说明**落在了哪（见 `backupsDir`）。 */
      return this.packTmpDir() + '/' + base + '-backup.zip';
    }
    let p: string = dir + '/' + base + '-backup.zip';
    for (let n: number = 2; pathExists(p) && n < 1000; n += 1) {
      p = dir + '/' + base + '-' + String(n) + '-backup.zip';
    }
    return p;
  }

  /** 关掉提示条。⚠️ 三个字段都要清 —— 它们共用同一个框（见 `PackNotice`）。 */
  private closePackNotice(): void {
    this.importMsg = '';
    this.exportMsg = '';
    this.importToast = '';
  }

  /** 显示一条提示，并**在几秒后自动收掉**（用户 2026-10-03 定的：3~5s）。
   * ⭐ 保留 ✕ 让人**立刻**关掉 —— 自动关闭负责「不挡路」，✕ 负责「不想等」。
   * ⛔ 定时器必须**带身份校验**：不加的话，先弹的那条会在几秒后把**后来那条**清掉
   *    （两条提示连着出现时就会这样，而失败提示被提前清掉最难查）。 */
  private showNotice(text: string, kind: string): void {
    if (kind === 'import') { this.importMsg = text; }
    else if (kind === 'toast') { this.importToast = text; }
    else { this.exportMsg = text; }
    setTimeout(() => {
      const now: string = kind === 'import' ? this.importMsg
                       : (kind === 'toast' ? this.importToast : this.exportMsg);
      if (now === text) { this.closePackNotice(); }
    }, NOTICE_MS);
  }

  /** 导出：把某个版本的数据打成 zip，再让玩家选存到哪。 */
  private async exportVersion(v: VersionEntry): Promise<void> {
    this.exportMsg = '';
    const tmp: string = this.packTmpDir();
    const zip: string = tmp + '/export.zip';
    this.exportMsg = '正在打包…';
    const err: string = await packDataDir(v.dataDir, tmp, zip);
    if (err !== '') { this.exportMsg = err; return; }

    /* ⭐ 名字 = **版本号 + 导出时间**（用户 2026-10-03 定）。只有版本号的话，
     * 同一个版本导两次出来的两个包分不出先后；时间能。 */
    const who: string = v.version === '' ? v.label : v.version;
    const outName: string = 'Mindustry-' + who + '-' + stampNow() + '.zip';

    /* ⭐⭐ **直接写到我们自建的 `MindustryArk/exports/`，不弹 picker**（用户 2026-10-03 定）。
     *    这样少一次交互，而且位置是**可预期的** —— 玩家看一遍提示就知道东西在哪，
     *    下次不必再找。
     * ⛔ 曾经用 `DocumentSaveOptions` + `pickerMode = DOWNLOAD`，踩过两个坑（都记在这里免得重走）：
     *    ① 不给 `pickerMode` 就是 `DEFAULT(=0)` = **应用沙箱** ⇒ 玩家在文件管理器里根本找不到；
     *    ② 给了 `DOWNLOAD` 之后，它返回的是**目录**不是文件
     *       （SDK 原文：「The **directories** created in DOWNLOAD mode are used only to save files.」）
     *       ⇒ 拿它当文件去写必然失败。
     *    ⇒ 现在干脆不经 picker。⚠️ 若哪天要恢复「让玩家自己选位置」，必须按 ② 的语义写。 */
    const dir: string = this.exportsDir();
    if (dir === '') {
      /* ⚠️ 拿不到用户可见位置时**如实说**，不要默默丢进沙箱（那等于玩家拿不到）。
       * 见 `packRoot()` 的说明。 */
      this.showNotice('导出失败：拿不到用户可见的文件夹（下载目录里本应用的那个）。'
                      + '如果这个提示反复出现，请把它截图发我 —— 我需要知道是「文件夹不存在」'
                      + '还是「不允许写」。', 'export');
      return;
    }
    const outPath: string = dir + '/' + outName;
    const wErr: string = copyLocalFile(zip, outPath);
    this.showNotice(wErr === '' ? '已导出：' + outPath : wErr, 'export');
  }
  /** 一个**永远存在**的导入目标：未隔离的那一份数据目录。
   *
   * ⭐⭐ 为什么需要它（用户 2026-10-03）：「单纯导入存档，**即便没有任何版本**」——
   *    他打算拆出一个**管理工具**形态的包（手机上不装游戏）。那种形态下 `versions` 是空的，
   *    而导入对话框若只列版本 ⇒ **导入功能直接死掉**。
   * ⚠️ 这份目录就是隔离关着时所有版本共用的那个（`liveGameDataDir()`），
   *    它在没有任何 jar 的时候**照样存在** —— 游戏数据与游戏本体是两回事。 */
  private liveImportTarget(): VersionEntry {
    const dir: string = liveGameDataDir();
    const c: GameDataCounts = countsOf(dir);
    return {
      path: LIVE_TARGET_PATH,
      source: 'live',
      label: '未隔离的那一份',
      version: '',
      key: '',
      dataDir: dir,
      isCurrent: false,
      saveCount: c.sectorSaves + c.manualSaves,
      hasData: gameDataExists(dir),
    };
  }

  /* 整包导入：选一个目标版本。
   * ⭐⭐ **每一行都是「版本 + 后果」的形状**（与 `TransferDialog` 同款，那是用户 2026-10-02 的硬要求）：
   *    光列版本名，玩家不知道点了会发生什么。这里必须说清「会覆盖 / 会新建」。 */
  @Builder
  ImportTargetDialog() {
    Column() {
      Column() {
        Text('导入到哪一份数据？')
          .fontSize(17).fontColor($r('sys.color.font_primary'))
          .width('100%').textAlign(TextAlign.Center)

        Text('这个包里是：' + (this.importNote === '' ? '（读不出内容清单）' : this.importNote))
          .fontSize(12).fontColor($r('sys.color.font_secondary'))
          .width('100%').textAlign(TextAlign.Center)
          .margin({ top: 8 })

        Scroll() {
          Column() {
            /* ⭐ **未隔离的那一份排在最前面**：它是唯一在「一个版本都没有」时也能用的目标，
             * 也是所有版本共用的那一份（隔离关着时就是它）。 */
            Row() {
              Column() {
                Text('未隔离的那一份')
                  .fontSize(15)
                  .fontColor(this.isImportPicked(this.liveImportTarget().dataDir)
                             ? $r('sys.color.brand') : $r('sys.color.font_primary'))
                  .width('100%')
                Text('所有版本共用它（隔离关着时就是这里）'
                     + (this.liveImportTarget().hasData
                        ? '　已有 ' + String(this.liveImportTarget().saveCount) + ' 个存档'
                        : '　还没有数据'))
                  .fontSize(12)
                  .fontColor(this.liveImportTarget().hasData
                             ? $r('sys.color.font_secondary') : $r('sys.color.brand'))
                  .width('100%').margin({ top: 3 })
              }
              .alignItems(HorizontalAlign.Start).layoutWeight(1)
              /* ⭐ 勾中的样子**复用本项目已有的那套**（文字变 brand 色 + 右侧 ✓），
               * ⛔ 不引入 `Checkbox` —— 它有自己的一套主题与获焦行为，本项目在焦点上栽过。 */
              if (this.isImportPicked(this.liveImportTarget().dataDir)) {
                Text('✓').fontSize(16).fontColor($r('sys.color.brand'))
              }
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })
            .backgroundColor($r('app.color.launcher_card'))
            .borderRadius(CARD_RADIUS_VP)
            .margin({ top: 8 })
            .onClick(() => { this.toggleImportPick(this.liveImportTarget().dataDir); })

            /* ⚠️ 一个版本都没有时，上面那一项就是唯一的目标 —— 而那正是「管理工具」形态。
             *    不要在这里写「请先导入一个游戏」：管存档本来就不需要游戏。 */
            ForEach(this.versions, (v: VersionEntry) => {
              Row() {
                Column() {
                  Text(v.label + (v.version === '' ? '' : '  ' + v.version))
                    .fontSize(15)
                    .fontColor(this.isImportPicked(v.dataDir)
                               ? $r('sys.color.brand') : $r('sys.color.font_primary'))
                    .width('100%')
                  /* ⭐ 后果写在行里 —— 有数据就会先备份再覆盖，没数据就是新建。 */
                  Text(v.hasData
                       ? ('已有数据（' + String(v.saveCount) + ' 个存档）—— 会先备份再覆盖')
                       : '没有数据 —— 会新建一份')
                    .fontSize(12)
                    .fontColor(v.hasData ? $r('sys.color.font_secondary') : $r('sys.color.brand'))
                    .width('100%').margin({ top: 3 })
                }
                .alignItems(HorizontalAlign.Start).layoutWeight(1)
                if (v.isCurrent) {
                  Text('当前').fontSize(12).fontColor($r('sys.color.font_tertiary'))
                }
                if (this.isImportPicked(v.dataDir)) {
                  Text('✓').fontSize(16).fontColor($r('sys.color.brand'))
                }
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 12, bottom: 12 })
              .backgroundColor($r('app.color.launcher_card'))
              .borderRadius(CARD_RADIUS_VP)
              .margin({ top: 8 })
              .onClick(() => { this.toggleImportPick(v.dataDir); })
            }, (v: VersionEntry) => v.path)
          }
          .width('100%')
        }
        .height(300)
        .scrollBar(BarState.Off)
        /* ⛔ `Scroll` 的 `align` **默认是 Center** —— 内容比视口矮时会**垂直居中**，
         *    表现就是「列表浮在中间」（用户 2026-10-03 报的）。
         *    ⚠️ 本文件在存档列表上踩过同一个坑（那边的注释写着「两行都改才平」）。 */
        .align(Alignment.TopStart)
        .margin({ top: 10 })

        /* ---- 选择控制 + 确认 ----
         * ⭐ 用户 2026-10-03 定的形状：**多选 + 确认**。原来点一行就立刻导入，
         *    而那样在「同一份数据」上有歧义 —— 点两行算导入两次还是一次？
         *    ⇒ 现在先勾、再确认；同一个 `dataDir` 只写一次（见 `pickedTargets`）。 */
        Row() {
          Text('全选')
            .fontSize(13).fontColor($r('sys.color.brand'))
            .padding({ top: 12, bottom: 6, right: 20 })
            .onClick(() => { this.pickAllImportTargets(); })
          Text('全不选')
            .fontSize(13).fontColor($r('sys.color.font_secondary'))
            .padding({ top: 12, bottom: 6 })
            .onClick(() => { this.importPicked = []; })
        }
        .width('100%')
        .justifyContent(FlexAlign.Start)

        /* ⚠️ 条数用 `importPicked.length` 就够：它按构造就是**互不相同且非空**的 `dataDir`
         *    （勾选时查重、全选时也去重）⇒ 与 `pickedTargets()` 的条数恒等，
         *    而后者每次调用都要摸一次文件系统（`liveImportTarget` 会 stat）。 */
        Text(this.importPicked.length === 0
             ? '请先选目标'
             : ('导入到 ' + String(this.importPicked.length) + ' 处'))
          .fontSize(15)
          .fontColor(this.importPicked.length === 0
                     ? $r('sys.color.font_tertiary') : $r('sys.color.brand'))
          .padding({ top: 14, bottom: 6 })
          .onClick(() => {
            /* ⛔ 一个都没勾时什么都不做 —— 但按钮的样子已经写着「请先选目标」，
             *    所以这不是静默失败。 */
            if (this.importPicked.length > 0) {
              this.confirmImport();
            }
          })

        Text('取消')
          .fontSize(14).fontColor($r('sys.color.font_secondary'))
          .padding({ top: 8, bottom: 4 })
          .onClick(() => { this.importOpen = false; })
      }
      .width('86%')
      .constraintSize({ maxWidth: 460 })
      .padding(16)
      .backgroundColor($r('app.color.launcher_bg'))
      .borderRadius(CARD_RADIUS_VP)
    }
    .width('100%').height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#F01C1C1C')
    .padding({ left: 32 + this.edgeVp('left'), right: 32 + this.edgeVp('right'),
               top: this.edgeVp('top'), bottom: this.edgeVp('bottom') })
    .transition(enterFade())
  }

  /* 导入 / 导出 / 完成 的提示条。
   * ⚠️ 它不是弹窗（不挡操作），因为导入是**异步且可能几秒**的 —— 而盖住界面的等待框
   *    在失败时会把「为什么失败」也一起藏起来。 */
  @Builder
  PackNotice() {
    /* ⛔ **不要用 `width('100%')` + 左右 margin** —— 那两样叠在一起会让它**溢出**，
     *    表现就是「占满左右」（用户 2026-10-03 报的）。用百分比宽度 + 上限，让 Stack 居中它。 */
    Row() {
      Text(this.importToast !== '' ? this.importToast
           : (this.importMsg !== '' ? this.importMsg : this.exportMsg))
        .fontSize(13).fontColor($r('sys.color.font_primary'))
        .layoutWeight(1)
      /* ⚠️ 用文字 ✕ 而不是 `Button`：本项目有硬规矩 —— **浮层里不能放可获焦的组件**
       * （`Button` 自带点击手势，会和外层 `onClick` 竞争）。一个 `Text` 就够。 */
      Text('✕')
        .fontSize(15).fontColor($r('sys.color.font_secondary'))
        .padding({ left: 14, right: 2, top: 2, bottom: 2 })
        .onClick(() => { this.closePackNotice(); })
    }
    .width('86%')
    .constraintSize({ maxWidth: 420 })
    .padding({ left: 16, right: 12, top: 12, bottom: 12 })
    .backgroundColor($r('app.color.launcher_card'))
    .borderRadius(CARD_RADIUS_VP)
    .margin({ top: this.edgeVp('top') + 12 })
    .transition(enterFade())
  }

  @Builder

  SavesTab() {
    Column() {
      /* ⭐ 垃圾站是**另一个地方**，所以在最外层就分开了 —— 进去之后看不到分段控件、也看不到
       * 存档列表，只有一个返回。⚠️ 与「手机详情子页」同一个形状（那个也在最外层分）：
       * 它们是「去了别处」，不是「换了个视图」。 */
      if (this.showVault) {
        this.VaultView()
      } else if (this.isNarrow() && this.panelOpen) {
        /* ===================== 窄屏：子页 ===================== */
        Row() {
          /* 与垃圾站那个返回同尺寸、同热区 —— 两处是同一个动作，别长得不一样。 */
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

        /* ⚠️ 面板必须包一层 `layoutWeight(1)`：面板自身写的是 `height('100%')`，而这里它上面还有
         * 一个返回行、下面还有一个 `Blank` ⇒ 不包的话它会要求**整列**那么高、把返回行挤出屏幕；
         * 包一层之后 `height('100%')` 参照的是这一层，剩下的高度正好是它。 */
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
          /* 视图切换：按存档 / 按版本。⭐ **它就是这一屏的标题**（2026-10-02 定的）—— 原来这里写着
           * 一行 `Text('存档')`、分段控件摆在**右边**，用户指出该在**左边**、且 `存档` 与 `按存档`
           * **语义重复** ⇒ 标题整个撤掉，由分段控件顶上。
           * ⚠️ 形状**照抄设置页那组粒度选择**（一排 `Text` ＋ 切底色），⛔ 不新造组件（这类自带主题的
           * 组件本项目为它付过代价：`stateStyles` 编译期崩、HdsTabs 的 UI Design Kit 只在中国境内）。
           * ⚠️ 未选中的底色是 `launcher_bg`（不是 `launcher_card` —— 后者与页面底色同色 ⇒ **完全看不见**）。 */
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
            /* ⭐ 垃圾站入口。⚠️ 用一个 `Blank()` 把它推到**最右**，而不是给它 `layoutWeight` ——
             * 那会让它按剩余宽度撑开，点到的区域比看起来大得多。
             * ⚠️ 空的时候也显示（写「垃圾站」而不写「(0)」）—— 一个数字 0 只会让人以为坏了；
             * 而**空垃圾站本身有说明作用**（删掉的东西会去哪）。 */
            Blank()
            /* ⭐ 导出。**只在「按版本」视图、且选中了某个版本时出现** ——
             * 导出必须有明确的对象；放在这里而不是列表行里，是为了不和「点行=选中」抢手势
             * （本项目有过手势竞争的坑：子组件的点击不会触发外层的 onClick）。 */
            if (this.savesView === SAVES_VIEW_VERSION && this.selectedVersionEntry() !== undefined) {
              Text('导出')
                .fontSize(13).fontColor($r('sys.color.brand'))
                .padding({ left: 4, right: 12, top: 7, bottom: 7 })
                .onClick(() => {
                  const v: VersionEntry | undefined = this.selectedVersionEntry();
                  if (v !== undefined) { this.exportVersion(v); }
                })
            }
            /* ⭐ 整包导入。⚠️ 放在**这一行**（对整个列表的操作），不塞进 `SaveActionRow` ——
             * 那个是零参 `@Builder`、被「按存档 / 按版本」两个面板共用，而导入不针对选中项。 */
            Text('导入数据')
              .fontSize(13).fontColor($r('sys.color.brand'))
              .padding({ left: 12, right: 12, top: 7, bottom: 7 })
              .onClick(() => { this.startImport(); })
            Text(this.vaultEntries.length === 0
                 ? '垃圾站'
                 : ('垃圾站 ' + String(this.vaultEntries.length)))
              .fontSize(13).fontColor($r('sys.color.brand'))
              .padding({ left: 12, right: 4, top: 7, bottom: 7 })
              .onClick(() => { this.openVault(); })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          /* 明确写出**在数哪个目录**：隔离一开一关这个路径就换了，不写出来玩家会以为存档丢了。
           * ⚠️ 「按版本」视图下这一行改成版本个数：那时左边根本不是某一份存档目录。 */
          Text(this.savesHeaderLine())
            .fontSize(11).fontColor($r('sys.color.font_tertiary'))
            .margin({ top: 8 })
            .copyOption(CopyOptions.LocalDevice)

          /* 多选那条，以及上一次多选删除的结果。⛔ 结果只说一句就走 —— 它是提示，不是门。 */
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
                  /* 版本列表。⚠️ 列表项同样**内联**写 —— 见文件开头 @Builder 按值传递那条。 */
                  if (this.versions.length === 0) {
                    Text('没有可用的游戏版本')
                      .fontSize(14).fontColor($r('sys.color.font_secondary'))
                      .margin({ top: 20 })
                  }
                  ForEach(this.versions, (v: VersionEntry) => {
                    Row() {
                      Column() {
                        /* **版本在前、文件名在后** —— 与组头同一套顺序（2026-10-02）。 */
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
                  }, (v: VersionEntry) => this.versionRowKey(v))
                } else if (this.saveGroups.length === 0) {
                  Text('没有存档')
                    .fontSize(15).fontColor($r('sys.color.font_secondary'))
                    .margin({ top: 20 })
                  Text('进游戏玩一局，存档会出现在这里')
                    .fontSize(12).fontColor($r('sys.color.font_tertiary'))
                    .margin({ top: 8 })
                } else {
                  /* ⭐⭐ 一屏列出**所有版本**的存档，按「共用同一份数据的版本」分组（2026-10-02 要的形状是
                   * 「A版本→B版本」排下去、小字和详情标注属于哪（几个）版本）。⛔ 原来只列**当前版本**那一个
                   * 目录 ⇒ 开了隔离后别的版本的存档**完全看不见**，而当前那个目录还没建出来时屏幕会写
                   * 「没有存档」—— 玩家看到的是「我的存档全都不见了」，尽管几十上百个存档都还在盘上。
                   * ⚠️ 分组键是**目录**而不是版本（见 buildSaveGroups）：隔离关着时只有一组。 */
                  /* ⭐⭐ 「当前版本那一档是空的」在**存档页**也要有出口 —— 玩家来找存档时就是在这儿看见
                   * 「空」的。⚠️ 放在列表**顶上**而不是塞进那一组里：这个状态意味着当前版本那一组本身是空的，
                   * 把按钮放进一个空组里玩家会以为它只对那一组有效。 */
                  if (this.isolationStale && !this.staleIgnored) {
                    this.StaleCopyOffer()
                  }
                  ForEach(this.saveGroups, (g: SaveGroup) => {
                    Column() {
                      /* 组头 = 用户要的「小字」那一半：谁在读这份数据。 */
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
                        /* ⭐ 长按进多选；已经在多选态时，**点击**就是勾选（见下）。⚠️ 多选态里长按
                         * 与点击做同一件事，是为了让「已经进去了」的人不会因记错手势而以为点不动。 */
                        .gesture(LongPressGesture({ repeat: false, duration: 400 })
                          .onAction(() => { this.enterMulti(this.saveKey(g.dir, sv.id)); }))
                        .onClick(() => {
                          if (this.multiMode) {
                            this.toggleMultiPick(this.saveKey(g.dir, sv.id));
                            return;
                          }
                          this.openSaveRow(g.dir, sv.id);
                        })
                      }, (sv: SaveEntry) => this.saveRowKey(sv))
                    }
                    .width('100%')
                    .margin({ bottom: 16 })
                    .alignItems(HorizontalAlign.Start)
                  }, (g: SaveGroup) => this.groupKey(g))
                }
              }
              .width('100%')
              .padding({ left: 16, right: 8, top: 12 })
            }
            /* ⛔ **这一行 `height('100%')` 必须没有** —— 它是 2026-10-02 报的「我只能看到头两个，
             * 后面的看不到（列表是固定死的）」的唯一原因。
             * ⭐ `Scroll` 的直接子节点写 `height('100%')` ⇒ 高度**等于视口** ⇒ 内容再高也是
             * 「和视口一样高」⇒ `Scroll` **可滚动的余量是 0**、多出来的被裁掉。⚠️ 界面上看起来就像
             * 「列表只有这么长」，而不是「滚不动」—— 所以它一直没被发现。
             * ⚠️ 它当初是治「列表竖直居中」的（Row 交叉轴默认 `VerticalAlign.Center`）；正确解法是
             * **不要那个高度**：Row 变成内容高 ⇒ 没有多余空间 ⇒ 居中无从发生、滚动照常。
             * ⛔ 别再把 height 加回来「以防万一」。 */
            .width('100%')
            .justifyContent(FlexAlign.Start)
            .alignItems(VerticalAlign.Top)
          }
          .layoutWeight(3)
          .height('100%')
          /* ⛔ **必须有这一行，否则内容短的时候会被竖直居中。**
           * ⭐ `Scroll` 的 `align` **默认是 `Alignment.Center`** —— 内容比视口矮时它就把内容摆在
           * 中间。2026-10-02 报的「按版本，左边列表居中了，应该置顶」就是它。
           * ⚠️ 以前看不出来：那时内层 Row 带着 `height('100%')`、**永远和视口一样高** ⇒ 没有「多余
           * 空间」可居中；而那一行正是让存档列表**滚不动**的原因。
           * ⇒ ⭐ 同一个布局缺了两个属性，各自遮住了对方的毛病：去掉 height 暴露了居中，补上 align
           * 才两件都平。⛔ 别只改一个（`height('100%')` 与 `.align(Alignment.TopStart)` **缺一不可**）。 */
          .align(Alignment.TopStart)
          .scrollBar(BarState.Off)

          /* ⚠️ 窄屏时**不渲染右侧面板**（那时它是子页，见上面那个分支），否则手机上 100% 宽度里再切
           * 两栏、每栏只剩一百多 vp。
           * ⛔ **这一层 `Column().layoutWeight(7)` 是必需的。** 面板的根节点写的是 `width('100%')` 而
           * **没有权重** ⇒ 直接放进 Row 里会要求**整行**宽度，于是左边那个 `layoutWeight(3)` 的 `Scroll`
           * 被挤成 0 宽 —— ⭐ **症状就是「从左边选的列表直接没了」**。
           * ⇒ 权重必须加在**调用点**，不能加在面板里（面板在手机子页包在 `layoutWeight(1)` 里，若它自己
           * 再带一个，两层权重叠在一起会算错比例）。⚠️ 3 : 7 与注释一致。 */
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
        /* ⚠️ 这里**只有** `layoutWeight(1)`，没有 `height('100%')` —— 外面那个 Column 里除了它还有
         * 一行标题和一个 `Blank`，写 height('100%') 就是在要求超出父容器的高度。 */
        .width('100%')
        .layoutWeight(1)
        .alignItems(VerticalAlign.Top)
      }

      /* 与悬浮底栏之间的留白。见 BAR_CLEARANCE_VP。 */
      Blank().height(BAR_CLEARANCE_VP)
    }
    .width('100%').height('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /* 设置页。2026-10-02 改成**全宽 + 卡片**（参考 AMCL 的设置页）。从那边的形态里取了三样**结构**上的
   * 东西，⛔ 不是照抄它的配色/图标体系：① **整片铺满**（左右各留 20，原来是一条 30% 的窄栏）；
   * ② **圆角卡片分组**（`launcher_card` + `CARD_RADIUS_VP` + 内边距 16，组间用留白分开而不是靠一堆
   * `top: 28` 硬撑）；③ **组标题在卡片外面** —— 读者才知道它是**这一组的名字**。⚠️ 我们**没有**取它的
   * 「每节点进去是子页」那套（这一页只有四组、六项设置，再套一层只会让人多点一次）。
   * ⚠️ 外面套 `Scroll` 是新加的：原来裸 `Column` + `Blank()` 在平板上刚好放得下，但卡片式总高变大、
   * 而手机上可用高度只有 800 上下 ⇒ 不滚会被裁掉，且裁掉的正好是最后一组「关于」。⛔ `Blank()` 一并去掉。 */
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
          /* 与空状态同款两行：给人找的一行 + 可复制的一行。理由见空状态里。 */
          Text(this.jarDirHuman === '' ? '　' : this.jarDirHuman)
            .fontSize(13).fontColor($r('sys.color.font_secondary'))
            .margin({ top: 4 })
          Text(this.jarDirHint === '' ? '（本设备上拿不到）' : this.jarDirHint)
            .fontSize(12).fontColor($r('sys.color.font_tertiary'))
            .margin({ top: 2 })
            .copyOption(CopyOptions.LocalDevice)

          Divider().strokeWidth(1).color($r('app.color.launcher_border'))
            .margin({ top: 14, bottom: 14 })

          /* 「本次启动将加载」与「重新扫描」**同一行**（2026-10-02：「设置那里的重新扫描太宽了，这个
           * 按钮最好和解释说明的字在同一行」）。⚠️ 原来「三行说明 + 一个 `width('100%')` 的按钮」上下排：
           * 按钮拉满整张卡片那么宽而它只有四个字 ⇒ 说明一栏 `layoutWeight(1)` 吃掉剩余宽度、按钮按内容自适应。
           * ⚠️ 字号【要给】：不给的话按钮按标签长度自适应时会**缩放字号**（就是「两个按钮字体大小不一样」的成因）。
           * ⚠️ 对齐用 `VerticalAlign.Top` 不是 Center：说明三行、按钮一行，居中会让按钮浮在三行文字的**中间**。 */
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

        /* ================= 外观 ================= */
        Text('外观')
          .fontSize(13).fontColor($r('sys.color.font_secondary'))
          .width('100%')
          .margin({ top: 20 })
        /* --- 深色模式 --- */
        /* ⭐ 两个开关（2026-10-04 用户：「开关深色模式 + 是否跟随系统深色模式」）。
         *
         * ⚠️⚠️ 第二个开关在「跟随系统」打开时**整行不渲染**（用户 2026-10-04 定的：
         *    「跟随系统时：下面的自定义不显示；不跟随：再显示出来」）。
         *    ⛔ 我第一版做的是**禁用**（理由是「隐藏会让卡片忽高忽低」）—— 那是**我**的顾虑，
         *    不是他的要求，而且它有个实际坏处：一个灰着的控件仍然在问「你要不要点我」。
         *    ⇒ 卡片高度会随开关变一行，这是**接受**的代价。
         * ⛔ 两条**文字提示也删了**（同一句要求：「文字提示就不要了」）—— 「跟随系统深色模式」
         *    和「深色模式」两个标签自己说完了，底下那行只是把标签重说一遍。
         *    ⚠️ 别再加回来「界面用深色 / 由系统决定」之类 —— 那正是被删掉的东西。 */
        Column() {
          Row() {
            Text('跟随系统深色模式')
              .fontSize(14).fontColor($r('sys.color.font_primary'))
              .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.darkFollow })
              .onChange((on: boolean) => {
                this.darkFollow = on;
                writeAppearance(this.filesDir, this.darkFollow, this.darkOn);
                /* ⭐ 立刻应用 —— 拨完就该看到变化，而不是等下次启动。
                 * ⚠️ 打开「跟随系统」时**不**去改 `darkOn`：记住玩家上次选的那一档，
                 *    他再关掉跟随时能回到自己那个选择，而不是被重置成浅色。 */
                this.applyColorMode();
              })
          }
          .width('100%')

          if (!this.darkFollow) {
            Row() {
              Text('深色模式')
                .fontSize(14).fontColor($r('sys.color.font_primary'))
                .layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.darkOn })
                .onChange((on: boolean) => {
                  this.darkOn = on;
                  writeAppearance(this.filesDir, this.darkFollow, this.darkOn);
                  this.applyColorMode();
                })
            }
            .width('100%')
            .margin({ top: 18 })
          }
        }
        .width('100%').padding(16)
        .backgroundColor($r('app.color.launcher_card'))
        .borderRadius(CARD_RADIUS_VP)
        .margin({ top: 8 })

        /* --- 异形屏避让 --- */
        /* ⛔ 卡片容器是必须的 —— 第一版我漏了它，于是这一段和上面那张卡片贴在一起、
         *    在界面上根本看不出是两块（用户 2026-10-03 当场指出）。
         * ⭐ 版式与「启动时直接进游戏」那张卡一致：一行标题 + 一个控件、整块一个底框。 */
        Column() {
          Row() {
            Column() {
              Text('异形屏避让')
                .fontSize(14).fontColor($r('sys.color.font_primary'))
              /* 副标题一行说清两件事：**谁在定** + **现在让多少**。
               * ⛔ 不再分开写「本机探测到 …」和「自动避让 …」两行 —— 那两行都在报同一个数，
               *    而且标题里也报一遍（用户 2026-10-03：这些数值重复了）。 */
              Text(this.safeAuto
                   ? (this.detectedSafeVp === 0 ? '自动 · 无需避让'
                      : ('自动 · ' + this.edgeNames() + ' ' + this.safeVp + ' vp'))
                   : ('手动 · ' + this.edgeNames() + ' ' + this.safeVp + ' vp'))
                .fontSize(12).fontColor($r('sys.color.font_tertiary'))
                .margin({ top: 4 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            /* 「开」= 跟着探测走（默认）；关掉 = 用滑条的值。
             * ⚠️ 拖滑条会**自动关掉它** —— 表达「我要自己定」最自然的方式。 */
            Toggle({ type: ToggleType.Switch, isOn: this.safeAuto })
              .onChange((on: boolean) => {
                /* ⭐ 高度变化必须包在 animateTo 里 —— 见下面那个容器的说明。 */
                this.getUIContext().animateTo(
                  { duration: 200, curve: Curve.FastOutSlowIn }, () => {
                    this.safeAuto = on;
                    /* 打开自动 ⇒ 立刻回到探测值；关掉 ⇒ 保留当前值，等玩家去拖。 */
                    if (on) {
                      this.safeVp = this.detectedSafeVp;
                    }
                  });
                writeSafePref(this.filesDir, this.safeAuto, this.safeVp);
              })
          }
          .width('100%')
          /* ⛔ **不能用 `if` 来做这个显隐**。原因是动画而非风格：
           *    `if` 会把节点整棵建/拆，而 `animateTo` 是在**两帧之间插值** —— 节点刚建出来时没有
           *    上一帧，高度就从 0 直接跳到目标值，看着还是瞬移。
           * ⇒ 让它**一直留在树里**，只改高度：`0`（收起）⇄ `SAFE_REVEAL_VP`（展开）。
           * ⭐ 这也顺带做对了「上下出入」的手感：收回是往上收，不是原地淡出。
           * ⛔ 开关本身**必须**一直在 —— 它是这一段唯一的出入口。 */
          Column() {
            Slider({
              value: this.safeVp,
              min: 0,
              max: SAFE_VP_MAX,
              step: SAFE_VP_STEP,
              style: SliderStyle.OutSet
            })
              .width('100%')
              .margin({ top: 6 })
              .onChange((v: number, mode: SliderChangeMode) => {
                const nv: number = Math.round(v);
                /* ⚠️ 只在**手指离开**时写盘（`End` / `Click`）—— 拖动中每次变化都写会写上百次，
                 * 而这是一块闪存。`Moving` 时只改内存里的值，界面照常实时预览。 */
                const end: boolean = (mode === SliderChangeMode.End
                                      || mode === SliderChangeMode.Click);
                /* ⛔⛔ 这个守卫【不能】把 `end` 那次也挡掉 —— 它挡掉过一次，代价是**手动值永远存不下来**：
                 *      拖动时 `Moving` 已经把 safeAuto 置 false、safeVp 跟到终点，于是 `End` 那一刻
                 *      `nv === safeVp && !safeAuto` 成立 ⇒ 直接 return ⇒ `writeSafePref` 一次都没执行。
                 *      内存里是对的（界面看着正常），文件里还是旧值，重启就回去了。
                 * ⭐ 「跳过没变化的更新」与「只在结束时写盘」是两条各自合理的规则，
                 *    叠在一起时**后者成了前者的受害者**。⇒ 写盘那一路必须从守卫里豁免。 */
                if (nv === this.safeVp && !this.safeAuto && !end) {
                  return;
                }
                /* ⚠️ 一动滑条就接管。 */
                this.safeAuto = false;
                this.safeVp = nv;
                if (end) {
                  writeSafePref(this.filesDir, false, nv);
                  dumpSafeArea('\n--- slide ---\nwrote user ' + nv + ' vp\n', true);
                }
              })
          }
          .width('100%')
          .height(this.safeAuto ? 0 : SAFE_REVEAL_VP)
          /* ⛔ 承重：不给 clip 的话，高度收到 0 时**内容还在画**，只是被容器框住而已。 */
          .clip(true)
        }
        /* ⛔ 四边一样，且**与其它卡片同一个值**（16）。
         *   我为了「滑条行高大」把这里改成过不对称的 top 14 / bottom 10 —— 那是错的：
         *   ① 自动开着时滑条**不显示**，卡片里只剩一行标题+开关 ⇒ 上下就不对称了；
         *   ② 而上下对称、且等于 16，才是这一页所有卡片共有的形状（用户 2026-10-03 两次指出）。
         * ⭐ 滑条与上面那行之间的间隔归**滑条自己的 margin** 管，不是归卡片的内边距管。 */
        .width('100%').padding(16)
        .backgroundColor($r('app.color.launcher_card'))
        .borderRadius(CARD_RADIUS_VP)
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

          /* 四个写成**并列的一行**而不是下拉菜单：互斥的四选一，一眼看全比点开一层省事，而且「当前是
           * 哪一档」不需要点开才看得见。⚠️ 下面那行说明是**必需**的：四档的差别（尤其中间两档）对玩家
           * 不是自明的，而选错的代价是「换个版本就看不到存档了」。
           * ⚠️ 未选中的底色从 `launcher_card` 改成 `launcher_bg`：卡片本身就是 `launcher_card`，两者同色
           * 会让未选中的那三个**完全看不见**（不是「颜色不好看」，是「没画出来」）。 */
          /* ⭐ **必须能换行。** 四个 chip 是定长的（各 12vp 内边距 + 三四个汉字），
           * 手机默认档实测就已经贴边，系统字体一大就会把最后一个挤出屏幕外 ——
           * 而这一行【不换行】的时候，溢出是**裁掉**，看起来像少了一个选项。
           * ⚠️ 间距从「每个左边 8」改成「每个右边 8 + 下边 8」：换行之后，
           *    第二行第一个若还带左间距，整行会比第一行缩进 8vp。 */
          Flex({ wrap: FlexWrap.Wrap }) {
            Text('不隔离')
              .fontSize(13)
              .fontColor(this.granularity === GRANULARITY_OFF
                         ? $r('sys.color.font_primary') : $r('sys.color.font_secondary'))
              .padding({ left: 12, right: 12, top: 7, bottom: 7 })
              .borderRadius(9)
              .backgroundColor(this.granularity === GRANULARITY_OFF
                               ? $r('app.color.launcher_border') : $r('app.color.launcher_bg'))
              .margin({ right: 8, bottom: 8 })
              .onClick(() => { this.chooseGranularity(GRANULARITY_OFF); })
            Text('大版本')
              .fontSize(13)
              .fontColor(this.granularity === GRANULARITY_NUMBER
                         ? $r('sys.color.font_primary') : $r('sys.color.font_secondary'))
              .padding({ left: 12, right: 12, top: 7, bottom: 7 })
              .borderRadius(9)
              .backgroundColor(this.granularity === GRANULARITY_NUMBER
                               ? $r('app.color.launcher_border') : $r('app.color.launcher_bg'))
              .margin({ right: 8, bottom: 8 })
              .onClick(() => { this.chooseGranularity(GRANULARITY_NUMBER); })
            Text('构建号')
              .fontSize(13)
              .fontColor(this.granularity === GRANULARITY_BUILD
                         ? $r('sys.color.font_primary') : $r('sys.color.font_secondary'))
              .padding({ left: 12, right: 12, top: 7, bottom: 7 })
              .borderRadius(9)
              .backgroundColor(this.granularity === GRANULARITY_BUILD
                               ? $r('app.color.launcher_border') : $r('app.color.launcher_bg'))
              .margin({ right: 8, bottom: 8 })
              .onClick(() => { this.chooseGranularity(GRANULARITY_BUILD); })
            Text('小版本')
              .fontSize(13)
              .fontColor(this.granularity === GRANULARITY_PATCH
                         ? $r('sys.color.font_primary') : $r('sys.color.font_secondary'))
              .padding({ left: 12, right: 12, top: 7, bottom: 7 })
              .borderRadius(9)
              .backgroundColor(this.granularity === GRANULARITY_PATCH
                               ? $r('app.color.launcher_border') : $r('app.color.launcher_bg'))
              .margin({ right: 8, bottom: 8 })
              .onClick(() => { this.chooseGranularity(GRANULARITY_PATCH); })
          }
          .width('100%').margin({ top: 12 })

          Text(this.granularityHintText)
            .fontSize(12).fontColor($r('sys.color.font_secondary'))
            .margin({ top: 10 })

          /* ⭐⭐ 这一条是给**已经踩进去的状态**留的出口。它不是错误提示，而是一句**诊断**：
           * 说清现在什么状态、以及怎么退回去。⛔ 没有它，玩家只能看到「存档全没了」，
           * 而界面上没有任何线索指向隔离。 */
          if (this.isolationStale && !this.staleIgnored) {
            /* ⛔ 原来这里只是一句提示（「请把隔离关掉（或重新打开一次）」）—— 那是让玩家去猜一个
             * **我们该做**的动作。现在它是同一块可点的东西。 */
            this.StaleCopyOffer()
          }

          /* 迁移出问题时的提示。⛔ 它不是门 —— 隔离照旧打开，只是新目录可能是空的，而原数据完好。
           * ⚠️ 紧跟在 `StaleCopyOffer` 后面时两者只隔 6vp 会像同一段话的两半 ⇒ 用一条分隔线断开。 */
          if (this.isolationNote !== '') {
            Divider().strokeWidth(1).color($r('app.color.launcher_border')).margin({ top: 10 })
            Text(this.isolationNote)
              .fontSize(12).fontColor($r('sys.color.font_tertiary'))
              .width('100%').margin({ top: 8 })
          }
        }
        .width('100%').padding(16)
        .backgroundColor($r('app.color.launcher_card'))
        .borderRadius(CARD_RADIUS_VP)
        .alignItems(HorizontalAlign.Start)
        .margin({ top: 8 })

        /* --- 存储位置 --- */
        /* ⚠️ **第 1 步只展示，不提供切换**（2026-10-04）。先证明「意图」与「实际」能对上，
         *    再让玩家能改它 —— 顺序反过来的话，一旦哪里对不上，你会同时面对
         *    「开关是新的」和「数据落到别处」两个未知数。
         * ⭐ 两行分开报，因为它们是**两件事**：意图是「你选的」，实际是「游戏上次真的用了哪个」。
         *    只报一个数的时候，改完设置还没重启会看起来像「没生效」。 */
        Column() {
          Row() {
            Column() {
              Text('使用外置存储')
                .fontSize(14).fontColor($r('sys.color.font_primary'))
              Text(this.storageIntent === STORAGE_MODE_EXTERNAL
                   ? '游戏数据放在「下载」里的应用文件夹（data 子目录）'
                   : '游戏数据放在应用内部（沙箱）')
                .fontSize(12).fontColor($r('sys.color.font_tertiary'))
                .margin({ top: 4 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            /* ⭐ 开关的「开」= 用外置。
             *
             * ⛔⛔ **`isOn` 绑的是一个独立的 `@State`，不是直接绑意图 —— 这是 2026-10-04 改的，
             *    因为原来那种写法有个真 bug。** 那一版绑的是 `this.storageIntent === EXTERNAL`，
             *    我以为「不动意图，开关自己就会弹回去」。**不会。**
             *    `Toggle` 有自己的视觉状态，而 `isOn` **只在绑定表达式的值【发生变化时】才重新应用**；
             *    意图没变 ⇒ 值没变 ⇒ 控件照样停在「开」。
             *    ⇒ 用户看到的是：**点取消，开关还是开着的，而下面的文字仍写着「沙箱」**
             *      （文字读的是意图，所以文字是对的 —— 两个不同步的东西并排显示，就是这么来的）。
             * ⭐ 所以要有这个显式的控件状态 + `syncStorageToggle()`：任何**没有真正提交**的出口
             *    （探针不过 / 取消 / 迁移失败）都要调它，把控件拉回意图那一档。
             * ⛔ 别再改回「直接绑意图」那种写法，也别删掉那些 sync —— 删了就退回这个 bug。 */
            /* ⭐ **搬移期间置灰、不给点**（用户 2026-10-04 要的防呆）。
             * ⛔ `enabled(false)` 是承重的，不只是好看：没有它，搬移那一小段里玩家
             *    再拨一次就**又发起一次搬移**，而那时源/目标的中间态正在被读写。
             * ⚠️ 灰**要能被看见**，所以搬移不能在同一个事件回调里跑完 —— 见
             *    `askStorageSwitch` 里那个 `setTimeout` 的说明。 */
            Toggle({ type: ToggleType.Switch, isOn: this.storageToggleOn })
              .enabled(!this.storageBusy)
              .onChange((on: boolean) => { this.askStorageSwitch(on); })
          }
          .width('100%')

          /* 搬移中把「正在搬」说出来 —— 只有灰色的话，玩家会以为是自己点坏了。 */
          if (this.storageBusy) {
            Text('正在搬移，请勿退出…')
              .fontSize(12).fontColor($r('sys.color.font_secondary'))
              .width('100%').margin({ top: 8 })
          }

          /* ⛔ 这里原来还有一行「游戏上次启动用的是：…（需要重启才生效）」，**2026-10-04 删了**。
           * 用户的理由：**切换时游戏进程肯定是关着的**。而这条比听上去更强 ——
           * 启动器的设置页与游戏**不可能同时在跑**（同一个应用、同一个进程）⇒
           * `usedUserHome()` 读到的永远来自**上一次**启动，**不存在活的冲突**，
           * 所以「要重启才生效」是句废话。⭐ 它当年存在的理由是「界面上说的和实际用的会分叉」，
           * 而那个分叉在这个功能里**构造上不可能出现**。
           * ⚠️ `usedUserHome()` / `usedUserHomeReason()` **仍然要留着** ——
           * `dumpStorageState()` 把它们写进 `storage_state.txt` 给 hdc 读，那是**排查通道**，
           * 与「界面上要不要显示」是两件事。 */

          /* 只在**出错**时给的提示。⛔ **原样显示探针那句话** —— 它返回五种不同处境
           * （`no-path` / `no-dir` / `open: errno=…` / `readback: …` / `left-behind: …`），
           * 压成一句「不可用」就把判据丢掉了。 */
          if (this.storageNote !== '') {
            Text(this.storageNote)
              .fontSize(12).fontColor($r('sys.color.warning'))
              .width('100%').margin({ top: 8 })
          }
        }
        .width('100%').padding(16)
        .backgroundColor($r('app.color.launcher_card'))
        .borderRadius(CARD_RADIUS_VP)
        .margin({ top: 8 })

        /* ================= 启动 ================= */
        Text('启动')
          .fontSize(13).fontColor($r('sys.color.font_secondary'))
          .width('100%')
          .margin({ top: 20 })
        Column() {
          /* 启动后进哪里。⭐ 这个开关是从一次真实的卡死里长出来的：他把一个 **mod 当成游戏**选了，
           * 于是每次打开都直接进游戏树、立刻闪退，而**没有任何界面能让他改回来**。检测机制
           * （launch_pending）现在也能把他送回启动器，但这是**不依赖检测**的那条路 —— 存在感为零、
           * 却让最坏情况有出口。
           * ⚠️ 默认「先进首页」（见 LauncherPrefs 的 LAUNCH_MODE_DEFAULT）；拨完立刻写盘、下次启动生效。 */
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

            /* 开关的「开」= 直接进游戏。写成左侧标签 + 右侧开关而不是两个单选 —— 它确实是二元的。 */
            Toggle({ type: ToggleType.Switch,
                     isOn: this.launchMode === LAUNCH_MODE_GAME })
              .onChange((on: boolean) => {
                this.launchMode = on ? LAUNCH_MODE_GAME : LAUNCH_MODE_HOME;
                writeLaunchMode(this.filesDir, this.launchMode);
              })
          }
          .width('100%')

          /* ⭐⭐ 游戏语言跟随系统（2026-10-04 用户要求）。
           *
           * ⛔⛔ **这是启动器**补**的一个能力，不是修游戏或本项目的缺陷** —— 用户 2026-10-04 明确
           *    纠正过一次：「这不是缺陷，正常 mindustry 就没有跟随」。他是对的，别再把这条写成
           *    「修复」：
           *      · Mindustry **本来就没有**「跟随系统」这个设置项。它的语言就是 `settings.bin`
           *        里那个值，`default` 的含义是「用 **JVM 的默认 locale**」。
           *      · 桌面版看起来「跟着系统」，只是因为桌面 JVM 的默认 locale 跟着操作系统环境走 ——
           *        同一套机制，不需要游戏做任何事。
           *      · 本启动器此前没给 JVM 传 locale ⇒ HotSpot 的 C locale 是 `C` ⇒ 那个
           *        `default` 落在**英文**上。这是**没人告诉过 JVM 设备语言**，不是谁坏了。
           *    ⭐ 所以这里做的是「把设备语言喂给 JVM」，出厂打开（见 `LauncherPrefs`）。
           *
           * ⚠️ **对已经在 `settings.bin` 里写死了语言的存档无效** —— 游戏读的是那个显式值，
           *    `-Duser.language` 只在它等于 `default` 时才起作用。改回中文的办法是**在游戏里
           *    「设置 → 语言」重选一次**。
           * ⛔ **这一条【不】在界面上写出来**（用户 2026-10-04：「提示不需要，冗余了」）。
           *    所以：界面上只有标题 + 开关，一个字的解释都没有。别再自己加回来 ——
           *    与深色模式那张卡同一个口味（那边也明确删过两条文字提示）。 */
          Row() {
            Text('游戏语言跟随系统')
              .fontSize(14).fontColor($r('sys.color.font_primary'))
              .layoutWeight(1)

            Toggle({ type: ToggleType.Switch, isOn: this.gameLocaleFollow })
              .onChange((on: boolean) => {
                this.gameLocaleFollow = on;
                writeGameLocaleFollow(this.filesDir, on);
                /* ⚠️ 桥文件要**立刻重写**：native 在启动那一刻读它，而这次改的正是「拨完到
                 *    下次启动」之间那个窗口 —— 不重写的话，玩家拨完开关直接点「启动游戏」，
                 *    这次启动仍然是旧的。 */
                this.rewriteBridge();
              })
          }
          .width('100%')
          .margin({ top: 18 })
        }
        .width('100%').padding(16)
        .backgroundColor($r('app.color.launcher_card'))
        .borderRadius(CARD_RADIUS_VP)
        .margin({ top: 8 })

        /* ================= 游戏内显示 ================= */
        /* ⭐ 2026-10-04 用户要的：「对游戏内的异形屏适配以及 UI 缩放做出调整，启动器默认帮用户
         * 调好（空存档），已有设置不覆盖」。
         *
         * ⛔ 这两行改的不是启动器，是**游戏自己的 `settings.bin`** —— 理由与格式见 `GameSettings.ets`。
         * ⭐ 但**默认值就是游戏的默认值**（边距 0、缩放 100 = 什么都不改变），因为合适的数值
         *    取决于真机上游戏 HUD 与挖孔的位置关系，而我**看不到屏幕**。
         *    ⇒ 给他两个滑条去试；试出合适的数之后把那两个数改成 `LauncherPrefs` 的出厂值，
         *      后面的人就自动调好了。⛔ 别在这里编一个数 —— 那会让游戏界面看起来像坏了，
         *      而玩家不知道是谁弄的。 */
        Text('游戏内显示')
          .fontSize(13).fontColor($r('sys.color.font_secondary'))
          .width('100%')
          .margin({ top: 20 })
        Column() {
          /* ⭐⭐ **实验性：自动适配**（用户 2026-10-04：「标注为实验性功能，这个不默认开启」）。
           * ⛔ 出厂关闭（见 `LauncherPrefs.GAME_DISPLAY_DEFAULT`）。
           * 算法与依据全在 `GameAutoFit.ets` 的文件头 —— 那里也记着**它算出来的值（84）
           * 比你在真机上实测最好的值（100）小**，而那是**有意的**：它给的是「刚好让开挖孔」的下限。
           *
           * ⛔⛔ **这一张卡上【只有两处文字】：`异形屏避让（单位：px）` 与底下的
           *    `只覆盖默认设置`。** 用户 2026-10-04 明确要求删掉我加的全部说明行，并立了一条规矩：
           *    **默认不加提示，他同意了才加。** ⇒ 别在这里写「关闭时用滑条自己定」之类的小字；
           *    也⛔ 不要在标题里带上当前数值（那也是一种提示，是他要删的那一类）。 */
          Row() {
            Text('自动适配（实验性）')
              .fontSize(14).fontColor($r('sys.color.font_primary'))
              .layoutWeight(1)

            Toggle({ type: ToggleType.Switch, isOn: this.gameAuto })
              .onChange((on: boolean) => {
                this.gameAuto = on;
                /* ⛔ 顺序是承重的：**先按本机算值，再落盘**。
                 *    `seedGameEdgeFromDevice` 在探测没回来时**不动**任何值（返回 false），
                 *    所以反过来的话不会写出 0 —— 但会让「拨上去」在探测未完成时看不出效果。 */
                if (on) {
                  this.seedGameEdgeFromDevice();
                }
                this.saveGameDisplay();
              })
          }
          .width('100%')

          /* ⛔ 用户 2026-10-04：**自动适配关着时这两个滑条不显示** —— 原话「游戏内能调的
           *    不给别人看；开了适配再把两个滑条放出来」。理由很正：游戏自己的设置里就有这两项，
           *    启动器复制一份出来只会让人分不清哪个在生效。
           * ⭐ 所以滑条的定位是「**给自动算出来的值做微调**」，而不是「另一个调这两项的地方」。
           * ⚠️ 关着时这一整段不渲染 ⇒ 卡片高度会变，这是**接受**的代价（同深色模式那张卡的做法）。 */
          if (this.gameAuto) {
            Text('异形屏避让 (单位:px)')
              .fontSize(14).fontColor($r('sys.color.font_primary'))
              .width('100%')
              .margin({ top: 18 })
            Slider({
              /* ⭐ 只有一个值，所以显示它、并且**两个模式下都能拖**（自动开着时拖的就是刚算出来的那个数）。 */
              value: this.gameEdge,
              min: GAME_EDGE_MIN,
              max: GAME_EDGE_MAX,
              step: 1,
              style: SliderStyle.OutSet
            })
              .width('100%')
              /* ⚠️ `enabled` 是**链式**通用属性，⛔ 不能写进 `Slider({...})` 的选项里。 */
              .margin({ top: 6 })
              .onChange((v: number, mode: SliderChangeMode) => {
                const nv: number = Math.round(v);
                if (nv === this.gameEdge || (mode !== SliderChangeMode.End && mode !== SliderChangeMode.Click)) {
                  this.gameEdge = nv;      /* 拖动中只改界面上的数，不写盘 */
                  return;
                }
                this.gameEdge = nv;
                this.saveGameDisplay();
              })

            Text('UI缩放 (百分比)')
              .fontSize(14).fontColor($r('sys.color.font_primary'))
              .width('100%')
              .margin({ top: 18 })
            Slider({
              value: this.gameScale,
              min: GAME_SCALE_MIN,
              max: GAME_SCALE_MAX,
              step: GAME_SCALE_STEP,
              style: SliderStyle.OutSet
            })
              .width('100%')
              .margin({ top: 6 })
              .onChange((v: number, mode: SliderChangeMode) => {
                const nv: number = Math.round(v);
                if (nv === this.gameScale || (mode !== SliderChangeMode.End && mode !== SliderChangeMode.Click)) {
                  this.gameScale = nv;
                  return;
                }
                this.gameScale = nv;
                this.saveGameDisplay();
              })
          }

          /* ⭐ 这张卡的**第二处、也是最后一处文字**（用户 2026-10-04 指定的）。
           * ⛔ 它把「不覆盖玩家已经调过的值」这条规则一句话说完 —— 所以**它同时取代了**
           *    我原来那句更长的说明，以及我在 `applyGameDisplay` 里为「自动模式没写进去」
           *    单独加的那条提示（那条已删：这条更短，而且涵盖同一个意思）。
           * ⇒ 别在它旁边再加解释。 */
          Text('只覆盖默认设置')
            .fontSize(12).fontColor($r('sys.color.font_tertiary'))
            .width('100%').margin({ top: 14 })
          /* ⚠️ 这一条**不是提示**，是**写入失败**时的报错（正常路径下永不出现）——
           *    与上面那条规则无关，所以留着。⛔ 但也别往里加正常的说明文字。 */
          if (this.gameDisplayNote !== '') {
            Text(this.gameDisplayNote)
              .fontSize(12).fontColor($r('sys.color.warning'))
              .width('100%').margin({ top: 6 })
          }
        }
        .width('100%').padding(16)
        .backgroundColor($r('app.color.launcher_card'))
        .borderRadius(CARD_RADIUS_VP)
        .alignItems(HorizontalAlign.Start)
        .margin({ top: 8 })

        /* ================= 关于 ================= */
        Text('关于')
          .fontSize(13).fontColor($r('sys.color.font_secondary'))
          .width('100%')
          .margin({ top: 20 })
        /* 关于 —— 现在是一个【入口】，点开才是内容（2026-10-01：「关于独立出来，点击出现一个有关闭
         * 按钮（右上角）的窗口展示信息」）。⚠️ 它【曾经】把整块信息平铺在这一页上 —— 问题不是好不好看，
         * 而是设置页的主语是**设置**，一块只能读、不能改的长文字会把真正的设置项挤下去 ⇒ 收成一行。
         * ⚠️ 游戏那边还有一份同内容的浮层，两者够不到彼此（那个在游戏树里）⇒ 两份都得留，改文案时一起改。 */
        Column() {
          Row() {
            Column() {
              Text('版本与许可')
                .fontSize(14).fontColor($r('sys.color.font_primary'))
              /* ⭐ 走资源（`this.appName`），与游戏里那个 About 同一处规则。
               * ⛔ 原来这里写死了名字 —— 它正是「改一次名、两个 About 显示两个名字」的另一半。 */
              Text(this.appName === ''
                   ? (this.appVersion === '' ? ' ' : this.appVersion)
                   : (this.appVersion === '' ? this.appName : (this.appName + '  ' + this.appVersion)))
                .fontSize(12).fontColor($r('sys.color.font_tertiary'))
                .margin({ top: 4 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            /* 一个朝右的箭头，表示「点进去还有一页」。用符号字形而不是字符，免得不同字体下宽度跳变。 */
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(16).fontColor([$r('sys.color.font_tertiary')])
          }
          .width('100%')
        }
        .width('100%').padding(16)
        .backgroundColor($r('app.color.launcher_card'))
        .borderRadius(CARD_RADIUS_VP)
        .margin({ top: 8 })
        .onClick(() => { this.openAbout(); })
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
    /* 外面这层 Stack 只为了在界面之上放两个弹窗（build 末尾那两个 if）。
     * ⚠️ 内层的 Navigation 及其整条链**刻意没有重新缩进**（与 Index.ets 那处同理）：给几百行整体
     * 加两格缩进会让「多了一个 Stack」这个唯一真实的改动被埋进一片空白 diff 里、审查时看不出来。 */
    Stack() {
    /* ⛔ 右侧「非界面区底色」那次尝试已**整体回退**（2026-10-02）。两次都失败，记这里免得重走：
     * 尝试 1：在 Navigation 【后面】加一层全屏底色 ⇒ 盖在界面上 ⇒ **UI 全部不见了**；尝试 2：移到
     * Navigation 【前面】（正确层序）+ 底色改透明 ⇒ UI 回来了，但**设置页的内容被推到屏幕右侧外并截断**。
     * ⚠️ 第二次的成因**没有查清**就回退了（可查：Navigation 底色改透明是否影响 Tabs 尺寸计算、Stack 里
     * 多一个 `position()` 的兄弟节点是否影响布局、那层空 Column 是否元凶）。
     * ⭐ 结论：**这条是纯观感改动，不值得在用户的实机上盲试** —— 要再做，先用最小页面把层序和尺寸行为
     * 验证清楚。⚠️ 而且「分成两块」可能与 `barOverlap(true)` 的悬浮底栏冲突：底栏居中在**整个窗口**
     * 宽度上，必然横跨这两块的边界。 */

    Navigation() {
      /* 2026-10-03：从裸 Tabs 换成 HdsTabs（鸿蒙设计系统组件，@kit.UIDesignKit）。三条依据：
       *   ① 参考项目 AMCL 用的就是它（Index.ets:2567），而用户对它的评价是「AMCL 就没有（掉帧）」；
       *   ② 裸 Tabs 的切换动效没有旋钮 —— TabsAttribute 里能碰的只有 animationCurve /
       *      animationDuration（逐条列过），而 HdsTabs 是设计系统组件，切换动效由系统那套实现；
       *   ③ 它让两条分支合成一条（理由见 tabController 那处）。
       *
       * ✅ 2026-10-03 **已定案：就用 HdsTabs**（用户实测「差不多」，且外观有变但他接受）。
       *    用户另给了一条长期口径：**后续同类的底部导航一律走沉浸光感**（即 HdsTabs 这套）。
       *
       * ⛔ 已知的取舍（我记录在案，不再当作「待观察」）：HdsTabs 没有 animationCurve ——
       *    逐条核过本机 SDK 的 HdsTabsAttribute 全部方法，确实没有。⇒ 我们那条显式曲线
       *    （实测让滑动顺畅了一些）在 HdsTabs 上设不了，切换节奏改由组件自己决定。
       * ⚠️ 也就是说：**这次是「拿掉一个已知有效的改动，换组件级实现，手感持平」**。
       *    用户是在知情下选的它，理由是设计系统组件是平台推荐路径、且要统一口径。
       *    改动前的整份文件备份在项目外（不在 git 里）：
       *    MindustryArkDocs/_backup_launcher_home_20261003/LauncherHome.ets.pre-hdstabs。
       *
       * ⚠️ 页签内容仍然走 @Builder（没有第二份）。⚠️ currentTab 现在是普通字段、不是 @State，
       *    见它自己的注释 —— 那是一次一行实验，别顺手改回去。 */
      HdsTabs({ barPosition: BarPosition.End, controller: this.tabController }) {
        TabContent() { this.GamesTab() }.tabBar(this.tabItem($r('sys.symbol.house_fill'), '首页'))
        TabContent() { this.SavesTab() }.tabBar(this.tabItem($r('sys.symbol.doc_text'), '存档'))
        TabContent() { this.SettingsTab() }.tabBar(this.tabItem($r('sys.symbol.gearshape_fill'), '设置'))
      }
      .barFloatingStyle({
        /* 左右同一个留白 ⇒ 居中由构造保证。见 BAR_MAX_VP。 */
        barSideMargin: this.sideMargin(),
        /* 把栏从屏幕下沿抬起来 —— 悬浮观感的另一半。 */
        barBottomMargin: BAR_BOTTOM_MARGIN_VP,
        /* ⛔ 字段名与裸 Tabs 不同，别照抄旧代码：
         *   · 旧：systemMaterial: uiMaterial.Material  +  maskColor: Color.Transparent
         *   · 新：systemMaterialEffect: { materialType, materialLevel }
         * ⛔ HdsTabsFloatingStyle 没有 maskColor（逐条核过字段表）⇒ 那一项去掉。
         * ⭐ ADAPTIVE 的官方释义就是「Follow system material policy / level」——
         *   交给系统按设备性能与主题自适应。⚠️ 这两个枚举是 @since 6.1.0(23)。 */
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE,
        },
      })
      /* ⚠️ 这一行 = 「悬浮」本身，不要改成 false。我不小心改过一次，用户报回来的第一句
       * 就是「底栏现在不悬浮，和左边融为一体了」—— 悬浮观感靠它生效。官方示例与 AMCL 都是 true。
       * ⇒ 「栏压住按钮」的正解是给内容留出底部空间（BAR_CLEARANCE_VP），不是关掉重叠。 */
      .barOverlap(true)
      /* ⚠️ 显式 300：SDK 说自定义 tabBar 不设时默认就是 300，但实测是跳的。
       * ⛔ 这里【不能】再写 animationCurve —— HdsTabs 没有这个方法（见上面那条取舍）。
       * ⚠️ 也因此，裸 Tabs 上「滑动走 spring、点击走贝塞尔」的那个不一致，
       *    在 HdsTabs 上由组件自己统一 —— 我们不再能（也不需要）干预。 */
      /* ⭐ 与 AMCL 对齐的那一行（`LauncherTabsStyle.ets:20`）。
       * ⛔ 我一度判定它「等于默认值、是噪音」—— **那个判断是错的**：我引的是【裸 Tabs】的文档
       *    （`tabs.d.ts:1591`：「不设时全部缓存」），而 **HdsTabs 自己的文档【没有】写默认值**
       *    （本机 `@hms.hds.hdsBaseComponent.d.ets` 里这条只有参数说明）⇒ 对 HdsTabs 不能假定。
       * ⇒ 既然 AMCL 显式写了、且它对结果满意，而 `.ets` 里的 `TabsCacheMode` 是全局声明
       *    （AMCL 也没 import 它），这一行的代价为零。 */
      .cachedMaxCount(2, TabsCacheMode.CACHE_BOTH_SIDE)
      .animationDuration(300)
      .barBackgroundColor(Color.Transparent)
      /* ⚠️ 要 onAnimationStart 而不是 onChange：onChange 在切换【完成之后】才触发 ⇒
       * 滑动的那一整段时间底栏高亮还停在旧页签上（「慢半拍」）。onChange 留作兜底、两者幂等。 */
      .onAnimationStart((_index: number, targetIndex: number) => {
        this.currentTab = targetIndex;
      })
      .onChange((index: number) => { this.currentTab = index; })
      .width('100%')
      .height('100%')
    }
    /* ⭐ 走资源。拿不到时给空串 —— 标题栏宁可空着，也不要显示另一个应用的名字。 */
    .title(this.appName)
    .titleMode(NavigationTitleMode.Mini)
    /* ⚠️ 必须显式写 Stack，**不能靠默认的 Auto** —— 这一行同时是两个缺陷的根因。
     * SDK 原文（`NavigationMode.Auto`）：In API version 10 and later versions: If the window width is
     * greater than or equal to 600 vp, the **Split** mode is used; otherwise, the Stack mode is used.
     * 600 vp = minNavBarWidth (240 vp) + minContentWidth (360 vp)。
     * 平板远超 600 vp ⇒ Auto 切成 **Split** ⇒ **左边多出一个 240 vp 的导航栏**，而 Tabs（连同悬浮底栏）
     * 住在**右侧的内容区**里 ⇒ 用户报的「底栏不居中」（在内容区里居中，相对整屏就偏了）与「界面太窄」
     * （那 240 vp 白给了）。Stack 下导航页与内容区互相独立，本页因此拿到整个窗口宽度。
     * ⚠️ 本页没有任何 NavDestination，Split 的那个导航栏里本来就什么都没有 ⇒ 关掉不损失任何东西。 */
    .mode(NavigationMode.Stack)
    /* ⚠️ 必须关掉：Navigation 默认在左上角画一个返回箭头，而**这一页不在任何 NavPathStack 里**
     * ⇒ 它没有任何可返回的东西、点它什么都不会发生（用户看到的就是「一个空按钮」）。 */
    .hideBackButton(true)
    /* ⭐ 异形屏避让加在**这里**，不在外层 Stack 上。
     * ⛔ 那个区别是承重的：几个弹窗的遮罩是 `.width('100%').height('100%')` 的**兄弟节点**，
     *    如果把 padding 加在 Stack 上，遮罩就只盖住缩进后的框，四周露出一圈没被压暗的条。
     *    ⇒ 内容在 Navigation 上避让，遮罩各自的 padding 里再加一份（见各弹窗）。 */
    .padding({ top: this.edgeVp('top'), bottom: this.edgeVp('bottom'),
               left: this.edgeVp('left'), right: this.edgeVp('right') })
    .width('100%')
    .height('100%')
    /* 唯一的任务是把窗口宽度学回来，好让底部栏能算出对称的左右留白。见 sideMargin()。 */
    .onAreaChange((_o: Area, n: Area) => {
      this.winW = Number(n.width);
    })
    .backgroundColor($r('app.color.launcher_bg'))

    /* 关于那个窗口。⚠️ 它排在失败弹窗【前面】，所以失败弹窗会盖在它上面（Stack 里后面的在上层）——
     * 这是对的：失败弹窗是必须处理的，关于是可选的。⚠️ 关闭按钮放在**右上角**（用户点名的位置），
     * 它必须真的存在 —— 一个只有内容没有出口的窗口就是「门关上了却没有开的路径」的界面版本。
     * 点遮罩也关（顺手），但出口以那个按钮为准。 */
    /* 打开隔离时的询问（2026-10-02 定：「询问玩家，给出不同选择」）。⭐ 结构照抄「关于」那个窗口
     * （同屏遮罩 + 卡片 + 点卡片不冒泡），理由也相同：里面的按钮是**要点的**，冒泡上去就会把窗口关掉。
     * ⚠️ 三个选项的顺序是刻意的：**先讲后果，再说动作**，而「复制过去」排第一（它最安全、可逆），
     * 所以默认落在它身上。⛔ 「从空开始」绝不能高亮成默认 —— 那等于把「看不到存档了」做成默认选项。 */
    if (this.showIsolationAsk) {
      Column() {
        Column() {
          /* ⭐ 标题（2026-10-04 用户重写的结构：「按"xxx"进行数据隔离」）。
           * ⛔ 它**取代了原来两段**：`打开数据隔离  ·  构建号` 与「之后，当前选中的版本的数据与
           *    其他版本隔离。你想怎么处理存档？」—— 那两句在说同一件事，而用户的原话是
           *    「之前的提示我都快看不懂了」。
           * ⚠️⚠️ 被取代的第二句，代码里原本标着**「用户留给他自己改的，别动」**（2026-10-02 他点名）。
           *    这次是他自己重做这个窗、并给了新结构，所以按新结构并进了标题。
           *    **它没有丢**（在 git 里），他要是要那句回来，一句话就能加。 */
          Text('按「' + this.granularityName(this.pendingGranularity) + '」进行数据隔离')
            .fontSize(18).fontColor($r('sys.color.font_primary'))

          /* 点名当前这个版本 —— ⚠️ 这一段**用户的新结构里没提**，但它原本是有理由的：
           * 玩家在那一屏上看不到自己选的是哪一个（它在「首页」页签里）。保留，降到小字。 */
          Text(this.pendingVersionName)
            .fontSize(13).fontColor($r('sys.color.font_secondary'))
            .width('100%').margin({ top: 6 })

          Divider().strokeWidth(1).color($r('app.color.launcher_border')).margin({ top: 14 })

          /* ⭐⭐ 「显示详情」—— 把原来摊在外面的两块收进来（用户 2026-10-04：
           * 「显示详情（点开后，列表分别展示哪几个版本共用存档）」）。
           * ⛔ 原来「这一档怎么分」+ 一张「版本 → 目录」表是**常驻**的，加上六行说明文字，
           *    整个弹窗读不完 —— 那正是他说的「快看不懂了」。现在默认收起。
           * ⭐ 形状照抄多选那个展开器：整行是个盒子、右边一个 `▾/▴`（那是「它能点」的唯一视觉线索）。 */
          Row() {
            Text(this.showIsolationDetail ? '收起详情' : '显示详情')
              .fontSize(13).fontColor($r('sys.color.font_secondary'))
              .layoutWeight(1)
            Text(this.showIsolationDetail ? '▴' : '▾')
              .fontSize(13).fontColor($r('sys.color.brand'))
              .margin({ left: 8 })
          }
          .width('100%')
          .margin({ top: 12 })
          .padding({ left: 12, right: 12, top: 10, bottom: 10 })
          .borderRadius(9)
          .backgroundColor($r('app.color.launcher_bg'))
          .alignItems(VerticalAlign.Center)
          .onClick(() => { this.showIsolationDetail = !this.showIsolationDetail; })

          if (this.showIsolationDetail) {
            /* ⭐ 这一档怎么分 —— 2026-10-02 点名要的（「必须让人选完了才知道是啥情况」）。
             * ⚠️ 给的是**用他自己的版本号算出来的**判断，不是编的例子。 */
            Text(this.pendingHint)
              .fontSize(12).fontColor($r('sys.color.font_secondary'))
              .width('100%').margin({ top: 10 })
            /* 版本 → 目录 的对照表。⚠️ 左对齐：居中的话 `→` 会参差不齐，反而读不出对应关系。 */
            Text(this.pendingPreview)
              .fontSize(12).fontColor($r('sys.color.font_tertiary'))
              .width('100%').textAlign(TextAlign.Start).margin({ top: 8 })
              .copyOption(CopyOptions.LocalDevice)
          }

          Divider().strokeWidth(1).color($r('app.color.launcher_border')).margin({ top: 14 })

          /* ⭐ 「注意」那一行（2026-10-04 用户指定的措辞与黄色）。
           * ⚠️ 仍然**有条件**，判据从 `pendingUsesBundled` 放宽到 `hasBundled`：
           *    · 这句话说的是「内置游戏」，而没有内置游戏的包（lite 分支，`SHIPS_GAME = False`）
           *      里它是**一句假话** ⇒ 不能无条件显示；
           *    · 放宽到「包里有没有那份游戏」，是他写的「常驻」在 master 上成立、在 lite 上不成立
           *      这两件事的交集。
           * ⛔ 原来挂得更窄（选中的正好是内置那份）—— 那时它解释的是「为什么切了档位没变化」；
           *    现在它是**陈述**，所以条件也换成「这份游戏在不在」。 */
          if (this.hasBundled) {
            Text('注意：内置游戏永远使用 bundled 目录存放数据')
              .fontSize(12).fontColor($r('sys.color.warning'))
              .width('100%').margin({ top: 12 })
          }

          /* ⭐ 摆出【现在有什么】，用真实数量 —— 「复制过去」会带走多少，在**选之前**就看得见。
           * ⚠️ 这一段**用户的新结构里也没提** —— 但两个选项的差别正是「带不带这些」，
           *    去掉它，玩家就得靠猜。保留。 */
          Text('当前数据：' + describeCounts(this.isolationCounts))
            .fontSize(12).fontColor($r('sys.color.font_secondary'))
            .width('100%').margin({ top: 12 })

          /* 每一块的顺序是【说明在上、按钮在下】（2026-10-02 要的对调）。⚠️「复制过去」**不配任何说明**
           * （「很直观了，根本不需要任何说明」）—— ⛔ 别在别处补一句解释回去，那正是被删掉的冗余。
           * ⭐⭐ 用真 `Button` 而不是给 `Text` 上色：设置页那个「重新扫描」是裸 `Button()`，它的蓝色是
           * **组件自带的默认主题色**，用它就自动与那一处一致（⛔ 不需要自己写一个蓝值，那样两处迟早分叉）。
           * ⚠️ 宽度 `'50%'` 之后要 `alignSelf(ItemAlign.Center)`：父 Column 是 `HorizontalAlign.Start`，
           * 光给宽度会让按钮贴左边。 */

          /* ⭐⭐ 按钮组：**一条分隔线 + 三个按钮**。
           * ⛔ 原来每个按钮上面各有一条线（共三条）—— 那是每个选项**各带一段说明**时的产物；
           *    说明在 2026-10-02 就删了，那两条线从此没有任何东西可分，只是把弹窗拉长。
           *
           * ⚠️ 三个都不设底色，全用 `Button` 的**系统默认主题色** —— 一处颜色，不给自己造的色值
           *    留分叉的机会。（`launcher_bg` 在深色模式下是近黑色，当年做过一次黑按钮。）
           *
           * ⭐ 尺寸（用户 2026-10-04：「文字可以小一点，按钮再稍微宽一点扁一点」）：
           *    字号 15 → **13**；宽 40% → **56%**；高显式给 **34**（`Button` 默认 40 ⇒ 扁一点）。
           *
           * ⛔⛔ 而「取消」原来是 `width('20%')` —— 它**装不下那两个字**：弹窗内容宽只有 280vp
           *    （`max(320, winW × 0.5)` = 320，减左右各 20vp 内边距），20% = **56vp**；
           *    而「取消」两字 14fp ≈ 28vp + `Button` 默认左右内边距 ≈ 32vp = **60vp** ⇒ **溢出成「...」**。
           *    这正是用户报的那个现象。现在 34% ≈ 95vp，宽裕。
           * ⚠️ 取消比另外两个窄是**刻意**的：它是否定动作，不该和「复制过去」长得一样重。 */
          Divider().strokeWidth(1).color($r('app.color.launcher_border')).margin({ top: 14 })
          Button('复制过去')
            .fontSize(13)
            .height(34)
            .constraintSize({ maxWidth: '100%' }).alignSelf(ItemAlign.Center)
            .margin({ top: 12 })
            /* ⭐ 两步：先记下意图，由下面那个二次确认来真正执行。⛔ 这里**不**直接调
             * applyIsolationCopy() —— 那会让二次确认变成摆设。 */
            .onClick(() => { this.isolationConfirm = 'copy'; })

          /* ⛔ **这个选项【没有】说明文字**（2026-10-02：「'不复制'的说明去掉吧，这个不用解释了」）。
           * ⚠️ 它与「复制过去」是**对称**的，两个词本身已经把结果说完了。⛔ 别再补「相当于新建一个
           * 存档」之类 —— 那是解释，不是信息。 */
          Button('不复制')
            .fontSize(13)
            .height(34)
            .constraintSize({ maxWidth: '100%' }).alignSelf(ItemAlign.Center)
            .margin({ top: 8 })
            .onClick(() => { this.isolationConfirm = 'empty'; })

          Button('取消')
            .fontSize(13)
            .height(34)
            .constraintSize({ maxWidth: '100%' }).alignSelf(ItemAlign.Center)
            .margin({ top: 8 })
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
        /* 吞掉落在卡片上的点击，别让它冒泡到遮罩把窗口关掉 —— 与「关于」同一处理由。 */
        .onClick(() => {})
      }
      .width('100%').height('100%')
      .backgroundColor('#80000000')
      .justifyContent(FlexAlign.Center)
      /* ⭐ 异形屏避让：遮罩本身要**铺满**（背景是全屏的），但卡片要落在避让区里面。
     * ⚠️ 为什么是加在遮罩的 padding 上、而不是靠外层 Stack 的 padding：见 Navigation 那处的说明。
     * ⚠️ 四边的 32 是**卡片自己的**边距（原本就有，只作用在左右），与避让无关，所以两者相加而不是覆盖。
     * ⚠️ 避让为 0 时这里与从前**逐像素相同**。 */
    .padding({ left: 32 + this.edgeVp('left'), right: 32 + this.edgeVp('right'),
               top: this.edgeVp('top'), bottom: this.edgeVp('bottom') })
    /* 整层淡入（遮罩 + 卡片一起）。 */
    .transition(enterFade())
      /* ⚠️ 这里【不】让点遮罩等于取消：这个窗比「关于」重（它会改数据位置），
       * 而一个手滑点空白就消失的确认框，比没有确认框更糟。出口只有「取消」。 */
    }

    /* 二次确认。⚠️ 它必须放在上面那个 `if` **之后** —— 在 Stack 里后声明的孩子画在上面，
     * 反过来写的话确认框会被主弹窗盖住，而症状是「点了按钮什么都没发生」。
     * ⚠️ 两条出口都要把 `isolationConfirm` 清回 `''`，否则下一次打开隔离会直接弹在确认框上。 */
    if (this.isolationConfirm !== '') {
      Column() {
        Column() {
          Text(this.isolationConfirm === 'copy'
               ? '复制到哪些分类' : '再确认一次')
            .fontSize(17).fontColor($r('sys.color.font_primary'))

          /* ============================================================
           * ⭐⭐ 「复制过去」＝**自己挑复制进哪些分类**（2026-10-02：「复制改成多版本自行选择，
           * **告知用户可以复制到哪些粒度下的分类里面**。现在这个有点反直觉」）。
           * ⛔ 原来是我替他全选，而它在界面上**看不见**（没东西告诉玩家刚才复制了几份）⇒ 一个聪明
           * 但沉默的默认值，比一个看得见的选择差。
           * ⭐ 每一行就是**这一档下的一个分类**（一个键），后面列出落进它的版本、以及它现在有没有数据
           * —— 那正是「勾了会发生什么」的答案。⚠️ 默认**全勾**（见 chooseGranularity）。
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
      /* ⭐ 异形屏避让：遮罩本身要**铺满**（背景是全屏的），但卡片要落在避让区里面。
     * ⚠️ 为什么是加在遮罩的 padding 上、而不是靠外层 Stack 的 padding：见 Navigation 那处的说明。
     * ⚠️ 四边的 32 是**卡片自己的**边距（原本就有，只作用在左右），与避让无关，所以两者相加而不是覆盖。
     * ⚠️ 避让为 0 时这里与从前**逐像素相同**。 */
    .padding({ left: 32 + this.edgeVp('left'), right: 32 + this.edgeVp('right'),
               top: this.edgeVp('top'), bottom: this.edgeVp('bottom') })
    /* 整层淡入（遮罩 + 卡片一起）。 */
    .transition(enterFade())
    }

    if (this.showAbout) {
      Column() {
        Column() {
          /* 标题行：左边标题，右边 ✕。用 Row 是为了让 ✕ 真的在右上角，而不是靠 margin 把它推到
           * 看起来像角落的地方。 */
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

          Text(this.appName + (this.appVersion === '' ? '' : ('  ' + this.appVersion)))
            .fontSize(14).fontColor($r('sys.color.font_secondary'))
            .margin({ top: 14 })
          Text('在 HarmonyOS / OpenHarmony 上运行 Mindustry')
            .fontSize(13).fontColor($r('sys.color.font_secondary'))
            .margin({ top: 8 })
          Text('以 GPL-3.0 分发。')
            .fontSize(13).fontColor($r('sys.color.font_secondary'))
            .margin({ top: 4 })

          /* 上游与本仓库是两个地址，别合并：本应用是上游的 fork，而「报问题」应当去
           * 它自己那个仓库。两个都列是因为它们回答的是不同的问题。
           *
           * ⛔ 这里原来缺了 `Text('上游')` 那一行，而它的三个修饰符留了下来、接到了上面那句
           * 「以 GPL-3.0 分发。」身上（后写的胜）⇒ 那行字实际渲染成 12/tertiary/间距16。
           * 同时第一个地址写的是**本仓库**，而注释说的是上游。两处都已修。 */
          Text('上游')
            .fontSize(12).fontColor($r('sys.color.font_tertiary'))
            .margin({ top: 16 })
          Text('https://github.com/Anuken/Mindustry')
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
        /* 吞掉落在卡片上的点击，不让它冒泡到下面那层遮罩。⚠️ 没有这一句，点卡片里的任意一行文字
         * 都会把窗口关掉 —— 而那里面有几条**要抄走的网址**（带 copyOption），正好是最需要点一下的。
         * ⚠️ 空处理器是有意的：只需要**接管**这一次手势（ArkUI 的手势竞争是子优先）。 */
        .onClick(() => {})
      }
      .width('100%').height('100%')
      .backgroundColor('#80000000')
      .justifyContent(FlexAlign.Center)
      /* ⭐ 异形屏避让：遮罩本身要**铺满**（背景是全屏的），但卡片要落在避让区里面。
     * ⚠️ 为什么是加在遮罩的 padding 上、而不是靠外层 Stack 的 padding：见 Navigation 那处的说明。
     * ⚠️ 四边的 32 是**卡片自己的**边距（原本就有，只作用在左右），与避让无关，所以两者相加而不是覆盖。
     * ⚠️ 避让为 0 时这里与从前**逐像素相同**。 */
    .padding({ left: 32 + this.edgeVp('left'), right: 32 + this.edgeVp('right'),
               top: this.edgeVp('top'), bottom: this.edgeVp('bottom') })
    /* 整层淡入（遮罩 + 卡片一起）。 */
    .transition(enterFade())
      /* 点卡片【外面】的空白处也关。与右上角那个 ✕ 并存 —— 两个都是出口，出口多一点比少一点安全。 */
      .onClick(() => { this.showAbout = false; })
    }

    /* 复制/移动的目标选择。同上：只读的窗可以盖在别的东西上，启动失败不能。 */
    if (this.transferOp !== '') {
      this.TransferDialog()
    }

    /* 整包导入的目标选择。⭐ 用户定的是「每次导入时问我」。 */
    if (this.importOpen) {
      this.ImportTargetDialog()
    }

    /* 导入/导出/进行中的提示条。⚠️ 只读提示，所以放在浮层链的最前面（最下层）。 */
    if (this.importMsg !== '' || this.exportMsg !== '' || this.importToast !== '') {
      this.PackNotice()
    }

    /* 删除确认。⚠️ 排在「上次没能启动成功」**前面** —— Stack 里后声明的在上层，而启动失败是必须
     * 处理的，不能被一个可选的确认框盖住。 */
    if (this.showDeleteAsk) {
      this.DeleteAskDialog()
    }

    /* 多选删除的确认框。⭐ 排在单删那个**后面**（同层的话后声明的在上）—— 两者不可能同时出现
     * （多选态下单条动作行整个藏了），所以顺序只是防御性的。 */
    if (this.showMultiAsk) {
      this.MultiDeleteAskDialog()
    }

    /* 清空垃圾站的确认。⚠️ 它只在垃圾站那一屏出现，与别的确认框不可能同时开着 ——
     * 排在这里只是防御性顺序（Stack 里后声明的在上）。 */
    if (this.showVaultClearAsk) {
      this.VaultClearAskDialog()
    }

    /* 删除版本的确认。⚠️ 它在**首页**，与垃圾站那个窗不可能同时开着 ——
     * 排在这里只是防御性顺序（Stack 里后声明的在上）。 */
    if (this.showGameDeleteAsk) {
      this.GameDeleteAskDialog()
    }

    if (this.launchFault !== '' && !this.faultAck) {
      /* 外面这层是【同屏遮罩】，里面那层是【盒子】（与「关于」那个窗口结构一致）。两层各拿各的
       * 修饰符，**不要合成一层**：合成之后背景色、对齐、内边距会互相覆盖，而那种错误只在视觉上
       * 体现、编译期看不出来。 */
      Column() {
        Column() {
          Text('上次没能启动成功')
            .fontSize(20).fontColor($r('sys.color.font_primary'))
          /* 内容在【可滚动】的一块里，而不是一个裸 Text。⚠️ 末尾是启动器自己的日志（最多 1.2 KB）、
           * 行数不定，裸 Text 会让弹窗随日志变长而撑高、最后把下面两个按钮顶出屏幕 —— 而按钮正是
           * 这个弹窗存在的理由（它是逃生门）⇒ 给一个上限，让文字自己滚。
           * ⚠️ 它**不**截断日志：截断了就等于把原因藏起来，而原因正是玩家要看的东西。 */
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

          /* 逃生门必须写明它绕开的是什么，否则玩家不知道按了会发生什么。 */
          Text('若你确认设备本可以运行游戏，可以用「仍然尝试启动」绕开这次判定。')
            .fontSize(12).fontColor($r('sys.color.font_tertiary'))
            .margin({ top: 10 })

          /* 按钮**并排**，各占一半。⚠️ 两个都用 `layoutWeight(1)` —— 在 Row 里它让子项**平分**可用宽度
           * ⇒ 两者**宽度严格相等**、一起铺满弹窗（用户报过「知道了这个按钮有点窄」，那正是按内容收缩时
           * 短标签必然更窄）⇒「一样宽」由**结构**保证，不必给 `minWidth` 填拍脑袋的数。
           * ⚠️ 顺序：次要的（灰）在左，主推的（主题色）在右 —— 各类对话框的通行次序。⚠️ ⛔ **不要**因为
           * 「看着不建议」就把「仍然尝试启动」禁用掉：它整个存在的意义就是在判定失误时留一条出路
           * （禁用它等于把逃生门拆了装成一个门把手）。 */
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
        /* 盒子的修饰符。⚠️ `constraintSize` 是【上限】，而宽度给 100% 是为了窄屏（手机）上占满可用
         * 宽度 —— 两者分工不同，缺了上限就是用户报的「太宽了」。 */
        .width('100%')
        .constraintSize({ maxWidth: this.dialogWidthVp() })
        .padding(20)
        .backgroundColor('#F01C1C1C')
        .borderRadius(CARD_RADIUS_VP)
        .alignItems(HorizontalAlign.Start)
      }
      /* 遮罩的修饰符。盒子之外再留一层，窄屏上也不至于贴边。 */
      .width('100%').height('100%')
      .backgroundColor('#B0000000')
      .justifyContent(FlexAlign.Center)
      /* ⭐ 异形屏避让：遮罩本身要**铺满**（背景是全屏的），但卡片要落在避让区里面。
     * ⚠️ 为什么是加在遮罩的 padding 上、而不是靠外层 Stack 的 padding：见 Navigation 那处的说明。
     * ⚠️ 四边的 32 是**卡片自己的**边距（原本就有，只作用在左右），与避让无关，所以两者相加而不是覆盖。
     * ⚠️ 避让为 0 时这里与从前**逐像素相同**。 */
    .padding({ left: 32 + this.edgeVp('left'), right: 32 + this.edgeVp('right'),
               top: this.edgeVp('top'), bottom: this.edgeVp('bottom') })
    /* 整层淡入（遮罩 + 卡片一起）。 */
    .transition(enterFade())
    }
    }
  }
}
