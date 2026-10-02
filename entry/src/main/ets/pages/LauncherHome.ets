/* 启动器主界面 —— 没有游戏可加载时、或玩家主动要求时显示的那一屏。
 * ⚠️ 它替换 XComponent（不是盖在上面）⇒ 无 Surface，可获焦组件安全；若改成盖在游戏上，`focusable(false)` 规则立刻生效（症状：键盘废掉，无声）。
 * 布局 Navigation + 底部页签是被 API 推出来的：沉浸光感只在 Navigation/NavDestination 标题栏或横向 Tabs(BarPosition.End) 生效 ⇒ 顺带否掉平板侧边竖向页签。
 * 颜色两套：文字 $r('sys.color.*')（colorInvert 只对特殊资源值生效，硬编码色不反色）；表面色 $r('app.color.launcher_*')（base/dark 两处定义）。
 * 三条坑：① 浮底栏靠 `barOverlap(true)`，防「栏压按钮」要给内容留底部空间而非关重叠；
 * ② `@Builder` 参数按值传递 ⇒ 带 `chosen` 的列表项点击后 ✓ 不刷新，列表项必须内联；
 * ③ 漏改 import 调用点会让整个文件语法分析失败（真错在错误列表最后一条），而 `build.log`
 * 是追加的、混着历次错误 ⇒ 只信命令当场打印的那几行。 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { SymbolGlyphModifier, uiMaterial } from '@kit.ArkUI';
import { GameJar, GameResolution, listGameJars, readSelection, writeSelection,
         resolveGame, gameJarDir, ensureGameJarDir,
         bundledGameVersion, hasBundledGame, bundledGamePath } from '../games/GameLibrary';
/* 界面偏好（启动后进哪里）。⛔ 内容宽度**不再**在这里 —— 见 gamesWidthVp。 */
import { readLaunchMode, writeLaunchMode,
         LAUNCH_MODE_HOME, LAUNCH_MODE_GAME } from '../settings/LauncherPrefs';
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
         listInstanceKeys } from '../settings/Isolation';

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

/** 圆角。卡片和列表项共用，免得两处漂移。 */
const CARD_RADIUS_VP = 14;

/** 按钮字号。**显式给**，因为不给会按各自标签长度自适应，两个按钮的字不一样大。 */
const BUTTON_FONT_VP = 16;

/* 「按版本」那一屏存档行的三列宽度（vp）：文件名占剩下的全部，大小与时间**各占一列、右对齐**。
 * ⚠️ 宽度必须写死（`Text` 默认按内容自适应 ⇒ 列会歪），写死是安全的，因为两个格式**定长**：
 * 大小 ≤ 7 个字符（`1.2 MB`），时间恒为 10 个字符（`2026-10-02`）。
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

/** 底部页签的材质；拿不到返回 undefined，界面退回普通样式。
 * ⚠️ 判断本身也在 try 里：`uiMaterial` 起始 26.0.0 而 compatibleSdkVersion 是 6.1.1(24)，
 * 在 API 24 的设备上抛异常的正是 `isImmersiveMaterialSupported()` 这一句，而不是它的返回值。 */
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
  @State currentTab: number = 0;
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

  /* 当前选中的是**内置游戏** —— 它在任何档位下都用固定的 `bundled` 目录。
   * ⛔ 必须专门说一句：玩家这时切「大版本/构建号/小版本」，**目录名一个都不会变** ⇒
   * 他会以为功能坏了。真因是一条刻意的设计：内置那份永不移动，换内置 jar 时玩家数据不跟着搬。 */
  @State pendingUsesBundled: boolean = false;

  /* 询问窗要点名的那个版本：【「名字 · 版本号」】与它在**这一档下**会用的键。
   * ⚠️ 原来整句话只有指代（「这个版本」），而那个版本的**身份**在那一屏上看不见（它在首页页签）
   * ⇒ 这里点名。
   * ⚠️ `pendingKey` 必须用**待确认的那一档**算，⛔ 不能用 `versions` 里现成的 `.key`
   * （那是按**当前**档位算的）—— 两者在玩家正切换时不一样。 */
  @State pendingVersionName: string = '';
  @State pendingKey: string = '';

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

  /* 给**人**看的那个文件夹路径，例如 `Download/Ark Launcher/games`。⚠️ `Download` 单数 —— 磁盘上的真名。
   * ⚠️ 真实路径不够用：那个文件夹磁盘上叫 `com.haohandc.mindustryark`（ModImporter 用 bundle 名
   * 创建），而文件管理器把它显示成应用名「Ark Launcher」⇒ 玩家照着找**找不到**（卸载后才退化成包名）。
   * ⇒ 两行都给：这一行用来**找**，真实路径那一行用来**复制**。 */
  @State jarDirHuman: string = '';

  /* 应用自己的显示名，由 resolveAppLabel() 从资源读出；读不到时 ''。 */
  private appLabel: string = '';

  /** 应用版本，设置页那个「关于」入口用。由 Index.ets 从 bundle 问到后传进来。 */
  appVersion: string = '';

  /* 上一次启动失败的记录；'' 表示没失败过。
   * ⚠️ 它是【上一次】的判定，不是即时的：失败发生时进程已经死了、没有界面能弹窗，唯一物证是
   * native 在游戏入口前留下的东西，要等**下一次启动**才被读到。 */
  launchFault: string = '';

  /* 底部页签的悬浮样式（沉浸光感生效处）是 @since 26.0.0。更低 API 上那个属性方法不存在，
   * 调用它会抛 —— 而那发生在 build() 里、catch 不到 ⇒ 按运行期 API 级别分两条分支，不靠 try。 */
  private canFloat: boolean = deviceInfo.sdkApiVersion >= 26;
  private barMaterial: uiMaterial.Material | undefined = immersiveBarMaterial();

  aboutToAppear(): void {
    this.launchMode = readLaunchMode(this.filesDir);
    this.granularity = readGranularity(this.filesDir);
    this.appLabel = this.resolveAppLabel();
    /* 把「返回一层」交给宿主页 —— 见 registerBack。 */
    this.registerBack(() => this.handleBack());
    this.refresh();
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
    /* 「复制过去」要复制的分类：算出来并**默认全勾**（玩家的意图就是每个版本都别丢数据，
     * 那是常见情形；反过来默认一个都不勾会让最常见的意图要点两次）。与「我替你全选」的差别
     * 在于 —— **现在是看得见的**，而且能改。 */
    this.copyTargets = this.buildCopyTargets(g);
    this.copyPicked = this.copyTargets.map((c: CopyTarget) => c.key);
    this.pendingUsesBundled = this.versions.some((v: VersionEntry) => v.source === 'bundled');
    /* 点名当前这个版本，以及它在**这一档下**会用哪个目录。⚠️ 版本名按 `resolution.path`
     * （**版本身份**，jar 路径）找，⛔ 不是版本号（两个 jar 可以是同一个版本号）。 */
    const res: GameResolution = this.resolution;
    const rk: GameDirForKey = resolveGameDirAndKey(g, res.source, res.path, this.bundledJar());
    this.pendingKey = rk.key;
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
    const note: string = copyLiveDataInto(key);
    if (note !== '') {
      this.staleCopyNote = note;
    } else {
      this.isolationNote = '已经把数据复制进这一档（' + key + '）。';
    }
    /* 必须显式重算 —— 复制成功后这块会**自己消失**、存档列表会当场填上。⛔ 不刷新的话，
     * 「复制成功」与「什么都没发生」在界面上长得一模一样。 */
    this.refresh();
  }

  /* 上面那个状态的界面。⭐ 零参 `@Builder`，所以**设置页与存档页可以共用同一份**
   * （开头那条「带参数的 @Builder 不会因状态变化重跑」只针对带参数的那种）。 */
  @Builder
  StaleCopyOffer() {
    Column() {
      Text('⚠ 隔离开着，但当前版本这一档还是空的 —— 进游戏会看到空的数据。'
           + '你的存档一直都在（在「未隔离的那一份」里）。')
        .fontSize(12).fontColor($r('sys.color.warning'))
        .width('100%')
      /* 失败时**留在这块里**说清楚 —— 失败意味着状态没变、这块还会在。⛔ 不写成弹窗：
       * 失败一次就弹一次的话，玩家得先关掉窗才看得见下面还有什么。 */
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
   * ⚠️ **从资源读，不硬编码**：两个仓库的应用名不同（Mindustry Ark / Ark Launcher），硬编码
   * 意味着其中一边必然写错；走资源还顺带拿到当前语言下的名字。
   * ⚠️ 读不到返回 ''，调用方只显示真实路径 —— 退化成改之前的行为，比显示一个错的路径好。 */
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
  private refresh(): void {
    ensureGameJarDir(this.filesDir);
    this.games = listGameJars(this.filesDir);
    this.selected = readSelection(this.filesDir);
    this.resolution = resolveGame(this.filesDir, this.bundleCodeDir);
    this.bundledVer = bundledGameVersion(this.bundleCodeDir);
    this.hasBundled = hasBundledGame(this.bundleCodeDir);

    /* 存档。⚠️ 目录**取决于隔离状态** —— 用与 native 算 `user.home` 同一套输入，否则这里会列出
     * 另一份存档，那是最坏的一类不一致：界面上看起来完全正常。⚠️ 两者仍可能分叉：玩家改了粒度
     * 但还没重启时，游戏那边还是旧目录。 */
    const dataDir: string = resolveGameDataDir(this.granularity, this.resolution.source,
                                              this.resolution.path, this.bundledJar());
    const dir: string = dataDir + '/saves';
    this.savesDirShown = dir;
    this.saves = listSaves(dir);
    /* 「开关拨过去了、数据没过去」。判据是两条**都**成立：① 隔离开着；② 目标数据目录不存在，
     * 而**未隔离**那一份存在（真的丢不了东西）。⚠️ 第二个条件不能省：全新安装、第一次就打开
     * 隔离时目标也是空的，那是**正常**的（玩家选了「不复制」），只有「原来有数据、现在指向空目录」才是异常。 */
    this.isolationStale = (this.granularity !== GRANULARITY_OFF)
                       && !gameDataExists(dataDir)
                       && gameDataExists(liveGameDataDir());
    /* ⚠️ 只在**异常**时才记一行 —— 那正是需要日志的时候，一旦修好就自动安静。
     * ⭐ 它把「界面上有没有那条警告」变成一条**能读出来的**事实，不必靠眼睛看屏幕。 */
    if (this.isolationStale) {
      hilog.error(DOMAIN, TAG, 'isolation: STALE -- on, but %{public}s does not exist '
                + '(the un-isolated copy does)', dataDir);
    } else {
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
     * 判据：`user_dirs.txt` 里记的是 `/storage/Users/currentUser/Download/com.haohandc.mindustryark`，
     * 而 `Environment.getUserDownloadDir()` 也返回 `.../currentUser/Download` ⇒ 写复数会让玩家找错。 */
    this.jarDirHuman = this.jarDirHint === '' ? '' : ('Download/' + this.appLabel + '/games');
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

  private askTransfer(op: string): void {
    if (this.selectedSave === '') {
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
    /* ⭐ 「源」= **选中那一行自己的目录**，不再是当前版本的目录 —— 列表里可能有别的版本的存档。
     * ⛔ 用 `savesDirShown` 的话会把**当前版本那一份**当成源（而它可能根本没有这个存档）。 */
    const here: string = this.selectedSaveDir();
    return this.versions.filter((v: VersionEntry) => (v.dataDir + '/saves') !== here);
  }

  /** 目标那一行的后果说明。⭐ 用户要的就是「移动前讲清后果」。 */
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

  /* 按下「确定」——**这才是真正动手的地方**。
   * ⚠️ 多个目标时**逐个执行**，并把失败的那几个**列出来**（不是遇到第一个失败就停）：
   * 停下来的话，玩家会以为后面那些也没做，而其实前面已经成功了 —— 那种「状态不明」比失败本身更难受。
   * ⇒ 成功的照做，失败的汇总成一句话，并且**照旧刷新**（部分成功也要反映出来）。 */
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
      /* ⭐⭐ 失败提示就两行：**「复制失败：」/「移动失败：」＋具体原因**（2026-10-02：「复制失败：
       * 「具体原因」，别的解释不需要」）。⛔ 原来拼的是「成功了 N 个；没成功：A；B；C」，一句话塞
       * 三件事、像日志 ⇒ 改成**一个标题 + 逐行的原因**（每个目标单独一行、带目标名）。
       * ⚠️ 部分成功时只在最前面留一行「成功了 N 个。」—— 那是**事实**，少了它会让人以为一个都没成。 */
      const head: string = this.transferOp === 'move' ? '移动失败' : '复制失败';
      const okLine: string = okCount > 0 ? ('成功了 ' + String(okCount) + ' 个。\n') : '';
      this.transferNote = okLine + head + '：\n' + fails.join('\n');
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

        /* ⛔ 只有**当前版本**的存档能操作（`saves` 列表本来就只列当前版本的）；别的版本的存档要动，
         * 得先在「首页」把版本切过去（提示在「按版本」那边）。
         * ⭐⭐ **多选态下把这一条整根藏掉**（2026-10-02 同意）：不藏的话屏幕上会同时出现**两个「删除」**
         * （删勾上的这一批 / 删详情里那一个），长得一样、位置又近 ⇒ 玩家按下哪一个都是赌 —— 两个意思
         * 不同的同名按钮并存，比少一个按钮糟得多。⚠️ 复制/移动也一起藏（它们只作用于一个存档）。 */
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
        /* ⭐ 只**开窗**，不直接删 —— 见 `showMultiAsk`。⚠️ 名单每次重新**收起**：上一次展开过的
         * 话，这一次一进来就是展开的，而那是上一个批次的状态。 */
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
                /* 与「按存档」那边同一套：点已选中的那一条 = 取消选中。⚠️ 别在这里直接赋值 ——
                 * 两处行为不一致时同一个动作在不同视图下结果不同，而那不是「两个视图」，是「两个东西」。 */
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
    .padding({ left: 32, right: 32 })
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
        .height('100%')
        .justifyContent(FlexAlign.Start)
        .alignItems(VerticalAlign.Top)
      }
      .width('100%')
      .layoutWeight(1)
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
      /* 吞掉落在卡片上的点击 —— 与隔离窗同一处理由。 */
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

        /* ⛔ **这个框里【没有任何说明文字】**（2026-10-02：「下面按钮都说了放到垃圾站，
         * 那上面的文字说明根本没用」）。理由不只是「嫌啰嗦」：原来把**区别**放在**按钮上面的文字**
         * 里，而按钮本身只说「放进垃圾站」「归档」⇒ 玩家要**先读上面、再看下面**才知道自己在选什么。
         * ⇒ 把区别**直接写进按钮标签**，一处说清。
         * ⚠️ 日期仍保留（它有信息量、且只有这里有），但压到「保留到 2026-10-09」—— 时分对 3/7/30 天是噪音。 */
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
      /* 吞掉落在卡片上的点击 —— 与隔离窗同一处理由。 */
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
                  }, (v: VersionEntry) => v.path)
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
                  if (this.isolationStale) {
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

          /* ⭐⭐ 这一条是给**已经踩进去的状态**留的出口。它不是错误提示，而是一句**诊断**：
           * 说清现在什么状态、以及怎么退回去。⛔ 没有它，玩家只能看到「存档全没了」，
           * 而界面上没有任何线索指向隔离。 */
          if (this.isolationStale) {
            /* ⛔ 原来这里只是一句提示（「请把隔离关掉（或重新打开一次）」）—— 那是让玩家去猜一个
             * **我们该做**的动作。现在它是同一块可点的东西。 */
            this.StaleCopyOffer()
          }

          /* 迁移出问题时的提示。⛔ 它不是门 —— 隔离照旧打开，只是新目录可能是空的，而原数据完好。 */
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
        /* 关于 —— 现在是一个【入口】，点开才是内容（2026-10-01：「关于独立出来，点击出现一个有关闭
         * 按钮（右上角）的窗口展示信息」）。⚠️ 它【曾经】把整块信息平铺在这一页上 —— 问题不是好不好看，
         * 而是设置页的主语是**设置**，一块只能读、不能改的长文字会把真正的设置项挤下去 ⇒ 收成一行。
         * ⚠️ 游戏那边还有一份同内容的浮层，两者够不到彼此（那个在游戏树里）⇒ 两份都得留，改文案时一起改。 */
        Column() {
          Row() {
            Column() {
              Text('版本与许可')
                .fontSize(14).fontColor($r('sys.color.font_primary'))
              Text(this.appVersion === '' ? 'Ark Launcher' : ('Ark Launcher  ' + this.appVersion))
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
      /* 两条分支只差悬浮样式那一块，理由见 canFloat 的注释。⚠️ 页签内容走 @Builder，没有第二份。 */
      if (this.canFloat) {
        Tabs({ barPosition: BarPosition.End }) {
          TabContent() { this.GamesTab() }.tabBar(this.tabItem($r('sys.symbol.house_fill'), '首页'))
          TabContent() { this.SavesTab() }.tabBar(this.tabItem($r('sys.symbol.doc_text'), '存档'))
          TabContent() { this.SettingsTab() }.tabBar(this.tabItem($r('sys.symbol.gearshape_fill'), '设置'))
        }
        .barFloatingStyle({
          /* 左右同一个留白 ⇒ 居中由构造保证。见 BAR_MAX_VP。 */
          barSideMargin: this.sideMargin(),
          /* 把栏从屏幕下沿抬起来 —— 悬浮观感的另一半。 */
          barBottomMargin: BAR_BOTTOM_MARGIN_VP,
          systemMaterial: this.barMaterial,
          maskColor: Color.Transparent,
        })
        /* ⚠️ 这一行 = 「悬浮」本身，**不要改成 false**。我改过一次（理由「栏压住『启动游戏』」），
         * 用户报回来的第一句就是「底栏现在不悬浮，和左边融为一体了」—— 悬浮样式就是靠它生效的。
         * 官方示例与 AMCL 都是 true，AMCL 的注释明说「旧 API 仍覆盖在全屏内容上，不退回挤占
         * TabContent 高度的布局」。⇒ 「栏压住按钮」的正解是**给内容留出底部空间**（BAR_CLEARANCE_VP），
         * 不是关掉重叠 —— 关掉重叠同时失去悬浮观感，代价比问题本身大。 */
        .barOverlap(true)
        /* ⚠️ 这一行是「首页 / 设置 两页之间切换跳变」的修复（AMCL 同款）。SDK 文档说自定义 tabBar 不设时
         * 默认就是 300，但实测是跳的 ⇒ 显式写上。⛔ 更关键的是上面那处改动：Tabs 的 `index` 绑定已经去掉 ——
         * 原来 `Tabs({ index: this.currentTab })` 而 `onAnimationStart` 会回写 `this.currentTab` ⇒ **把值
         * 灌回 `index`** ⇒ 等于在动画中途重新请求一次切换，那一下就是「跳」。
         * ⚠️ `animationCurve` 不设时滑动切换的时长由默认曲线 `interpolatingSpring(-1, 1, 228, 30)` 自己决定
         * ⇒ 这一行对「点击页签」和「滑动」作用方式不完全一样，别以为是万能旋钮。 */
        .animationDuration(300)
        .barBackgroundColor(Color.Transparent)
        /* ⚠️ 这里要的是 onAnimationStart，**不是 onChange** —— 这一行就是「滑动换页时底栏高亮有延迟」
         * 的修复：onChange【在切换完成之后】才触发，手指滑动的那一整段时间高亮还停在旧页签上
         * （看起来「慢半拍」）；onAnimationStart【在动画一开始】就给出 targetIndex，高亮跟着手势走。
         * ⭐ 参考项目 AMCL 用的就是它，而用户报的正是「AMCL 就没有」这个延迟。
         * onChange 保留作兜底（动画被跳过时仍会把值纠正回来），两者写同一字段、都幂等，不冲突。 */
        .onAnimationStart((_index: number, targetIndex: number) => {
          this.currentTab = targetIndex;
        })
        .onChange((index: number) => { this.currentTab = index; })
        .width('100%')
        .height('100%')
      } else {
        /* 低于 API 26 的退路。没有悬浮材质，但**仍然重叠**（同上），用 `barBackgroundBlurStyle`
         * 换个毛玻璃 —— 它从 API 7 就有。同一个做法见 AMCL 的 LauncherTabsStyle.ets。 */
        Tabs({ barPosition: BarPosition.End }) {
          TabContent() { this.GamesTab() }.tabBar(this.tabItem($r('sys.symbol.house_fill'), '首页'))
          TabContent() { this.SavesTab() }.tabBar(this.tabItem($r('sys.symbol.doc_text'), '存档'))
          TabContent() { this.SettingsTab() }.tabBar(this.tabItem($r('sys.symbol.gearshape_fill'), '设置'))
        }
        .barOverlap(true)
        /* 同上：显式给切换时长，与 AMCL 对齐。 */
        .animationDuration(300)
        .barBackgroundBlurStyle(BlurStyle.COMPONENT_THICK)
        /* 同上面那条：要 onAnimationStart（在动画一开始就给出 targetIndex、高亮跟着手势走），
         * **不是 onChange**（切换完成之后才触发 ⇒ 滑动时高亮停在旧页签、「慢半拍」）。
         * onChange 保留作兜底（动画被跳过时仍会把值纠正回来），两者写同一字段、都幂等。 */
        .onAnimationStart((_index: number, targetIndex: number) => {
          this.currentTab = targetIndex;
        })
        .onChange((index: number) => { this.currentTab = index; })
        .width('100%')
        .height('100%')
      }
    }
    .title('Ark Launcher')
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
          /* ⭐ 标题里直接点出**这一档叫什么**（2026-10-02：「我们加上具体的版本粒度就行」）。
           * ⚠️ 原来只有「打开数据隔离」四个字，玩家看不出自己点的是哪一档 —— 那正是他下一步要确认的。 */
          Text('打开数据隔离  ·  ' + this.granularityName(this.pendingGranularity))
            .fontSize(18).fontColor($r('sys.color.font_primary'))
          /* ⛔ 这一行**是用户留给他自己改的**（2026-10-02 他点名要自己动措辞）⇒ 我**不动它**。
           * 之前有一轮我顺手改过一次、已还原 —— 那是他的句子。⚠️ 谁要改这句，先问他。 */
          Text('之后，当前选中的版本的数据与其他版本隔离。你想怎么处理存档？')
            .fontSize(13).fontColor($r('sys.color.font_secondary'))
            .width('100%').textAlign(TextAlign.Center)
            .margin({ top: 12 })

          /* ⭐⭐ 把「当前选中的版本」**点名**（2026-10-02：「现在说的是'这个版本'，我们加上具体的
           * 版本粒度就行」）。⚠️ 原来整句话里只有指代，而玩家在那一屏上根本看不到自己选的是哪一个
           * （它在「首页」页签里）⇒ 这里给出【版本名 + 版本号】，并把它**这一档下实际会用的目录**
           * 也写出来 —— 那就是「具体到什么粒度」的答案。
           * ⚠️ 目录名那一行**刻意**与上面那份总表用同一套键，两处不会分叉。 */
          Text(this.pendingVersionName)
            .fontSize(14).fontColor($r('sys.color.font_primary'))
            .width('100%').textAlign(TextAlign.Center)
            .margin({ top: 10 })
          Text('这一档下，它用目录：' + (this.pendingKey === '' ? '（不隔离）' : this.pendingKey))
            .fontSize(12).fontColor($r('sys.color.font_secondary'))
            .width('100%').textAlign(TextAlign.Center)
            .margin({ top: 4 })

          /* ============================================================
           * ⭐⭐ 「这一档到底怎么分」—— 2026-10-02 点名要的（原话：「切换的大版本，构建号，小版本时，
           * 弹窗**没说明是怎么分类的**，必须让人**选完了才知道是啥情况**」）。
           * ⛔ 必须在这个窗里说：**这个窗是唯一能反悔的地方**，而那句说明原来只在设置页、**选完之后**
           * 才显示 —— 顺序正好是反的。这里给的是**玩家自己的版本号算出来的目录名**，不是编的例子。
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
          /* ⚠️ 只有这一块**左对齐** —— 它是一份「版本 -> 目录名」的对照表，居中的话 `→` 会参差不齐、
           * 反而读不出对应关系。其余说明文字一律居中（与「文字居中显示」一致）。 */
          Text(this.pendingPreview)
            .fontSize(12).fontColor($r('sys.color.font_secondary'))
            .width('100%').textAlign(TextAlign.Start).margin({ top: 6 })
            .copyOption(CopyOptions.LocalDevice)

          /* ⭐⭐ 这一句是**必须**的，它解释的正是最容易让人误判成故障的那个现象：⛔ 当前玩的是内置
           * 游戏时，**任何档位算出来的键都是 `bundled`** ⇒ 玩家切来切去目录名一个都不变、会得出
           * 「这功能没生效/坏了」。而真因是**一条刻意的设计**（内置那份永不移动，这样换内置 jar 时
           * 玩家数据不会跟着搬走）。⭐ 不说这句，界面就在把一个设计决定**伪装成一个故障**。 */
          if (this.pendingUsesBundled) {
            Text('⚠️ 内置游戏永远用固定的目录 bundled，与这一档无关 —— '
                 + '这样我们以后换内置的游戏版本时，你的数据不会跟着搬走。'
                 + '要让档位真正起作用，得先在「首页」导入并选中一个自己的 jar。')
              .fontSize(11).fontColor($r('sys.color.warning'))
              .width('100%').textAlign(TextAlign.Center).margin({ top: 10 })
          }

          /* ⭐ 先摆出【现在有什么】，用真实数量 —— 让玩家在**选之前**就看到结果。 */
          Text('当前数据：' + describeCounts(this.isolationCounts))
            .fontSize(12).fontColor($r('sys.color.font_secondary'))
            .width('100%').textAlign(TextAlign.Center)
            .margin({ top: 12 })

          /* 每一块的顺序是【说明在上、按钮在下】（2026-10-02 要的对调）。⚠️「复制过去」**不配任何说明**
           * （「很直观了，根本不需要任何说明」）—— ⛔ 别在别处补一句解释回去，那正是被删掉的冗余。
           * ⭐⭐ 用真 `Button` 而不是给 `Text` 上色：设置页那个「重新扫描」是裸 `Button()`，它的蓝色是
           * **组件自带的默认主题色**，用它就自动与那一处一致（⛔ 不需要自己写一个蓝值，那样两处迟早分叉）。
           * ⚠️ 宽度 `'50%'` 之后要 `alignSelf(ItemAlign.Center)`：父 Column 是 `HorizontalAlign.Start`，
           * 光给宽度会让按钮贴左边。 */

          /* ============ 选项一：主操作（系统蓝） ============ */
          Divider().strokeWidth(1).color($r('app.color.launcher_border')).margin({ top: 14 })
          Button('复制过去')
            .fontSize(15)
            .width('40%').alignSelf(ItemAlign.Center)
            .margin({ top: 14 })
            /* ⭐ 两步：先记下意图，由下面那个二次确认来真正执行。⛔ 这里**不**直接调
             * applyIsolationCopy() —— 那会让二次确认变成摆设。 */
            .onClick(() => { this.isolationConfirm = 'copy'; })

          /* ============ 选项二 ============ */
          /* ⛔ **这个选项【没有】说明文字**（2026-10-02：「'不复制'的说明去掉吧，这个不用解释了」）。
           * ⚠️ 它与「复制过去」是**对称**的，两个词本身已经把结果说完了。⛔ 别再补「相当于新建一个
           * 存档」之类 —— 那是解释，不是信息。 */
          Divider().strokeWidth(1).color($r('app.color.launcher_border')).margin({ top: 14 })
          Button('不复制')
            .fontSize(15)
            .width('40%').alignSelf(ItemAlign.Center)
            .margin({ top: 10 })
            /* ⛔ 这里【曾经】写 `.backgroundColor(launcher_bg)` + `.fontColor(font_primary)` 想做成
             * 「灰底次级按钮」，**实测是黑的** —— `launcher_bg` 在深色模式下是 #FF101010，而深色主题
             * 正是默认（2026-10-02：「现在颜色是黑色的。也改成蓝色吧」）⇒ 三个按钮都不设底色，全用
             * `Button` 的系统默认主题色 —— 一处颜色，不给自己造的色值留分叉的机会。 */
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
        /* 吞掉落在卡片上的点击，别让它冒泡到遮罩把窗口关掉 —— 与「关于」同一处理由。 */
        .onClick(() => {})
      }
      .width('100%').height('100%')
      .backgroundColor('#80000000')
      .justifyContent(FlexAlign.Center)
      .padding({ left: 32, right: 32 })
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
      .padding({ left: 32, right: 32 })
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

          Text('Ark Launcher' + (this.appVersion === '' ? '' : ('  ' + this.appVersion)))
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
      .padding({ left: 32, right: 32 })
      /* 点卡片【外面】的空白处也关。与右上角那个 ✕ 并存 —— 两个都是出口，出口多一点比少一点安全。 */
      .onClick(() => { this.showAbout = false; })
    }

    /* 复制/移动的目标选择。同上：只读的窗可以盖在别的东西上，启动失败不能。 */
    if (this.transferOp !== '') {
      this.TransferDialog()
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
      .padding({ left: 32, right: 32 })
    }
    }
  }
}
