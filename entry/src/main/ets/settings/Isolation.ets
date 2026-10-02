/* 版本隔离 —— 让每个游戏版本各用一套游戏数据。
 * 游戏的全部状态由 `-Duser.home=` 决定：`Vars.dataDirectory = Core.settings.getDataDirectory()`，
 * 后者在 `dataDirectory` 为 null 时用 `user.home` 派生 ⇒ **不隔离就是所有版本共用一份存档**。
 * ⭐ 本文件只【决定】与【传达】，不【执行】：ArkTS 算键 →写文件→ native（launcher.c）读文件、拼路径、
 * mkdir、设 `-Duser.home=`。⛔ 游戏完全不知道隔离存在，**不需要任何 Java 代码**。键在这里算是因为
 * `version.properties` 解析**已在这一侧**（GameLibrary.gameVersionParts），重写一遍 = 两份实现。
 * ⚠️ 两条不变量：1. **默认是「不隔离」**（文件不在/不认识/任何一步失败都回不隔离）—— 尤其因为 `user.home`
 * 一改玩家会以为存档「没了」；2. 隔离关着时 native 的 `user.home` **逐字节等于**隔离之前的值（不是「等价」）。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { GameVersionParts, gameVersionParts } from '../games/GameLibrary';
import { copyTreeInto, newTreeStat, TreeStat } from '../utils/FsTree';

const DOMAIN = 0x0000;
const TAG = 'MindustryLauncher';

/* ====================================================================
 * 粒度
 * ==================================================================== */

/** 不隔离 —— **出厂值**。 */
export const GRANULARITY_OFF: string = 'off';
/** 按大版本分（v8 / v9）。 */
export const GRANULARITY_NUMBER: string = 'number';
/** 按构建号分（160 / 159）。⭐ 推荐档。 */
export const GRANULARITY_BUILD: string = 'build';
/** 按构建号连小版本一起分（160.5 / 160.4）。 */
export const GRANULARITY_PATCH: string = 'patch';

/* ⭐ 出厂值 = **不隔离**，刻意如此：改 `user.home` 等于**搬走玩家存档**，让一个升级动作悄悄改变
 * 数据位置，会让「更新完应用，存档没了」变成一次事故 ⇒ 隔离必须是**玩家想要才开**的。
 * ⭐ 配套的是 native 那侧的不变量：关着时 user.home 与今天【逐字节相同】。 */
export const GRANULARITY_DEFAULT: string = GRANULARITY_OFF;

/** 界面上按顺序列出的四档。 */
export const GRANULARITIES: string[] = [
  GRANULARITY_OFF, GRANULARITY_NUMBER, GRANULARITY_BUILD, GRANULARITY_PATCH
];

/** 一个非法值不该被当成某个合法值，所以单独问一次。 */
export function isValidGranularity(g: string): boolean {
  return GRANULARITIES.indexOf(g) >= 0;
}

/* ====================================================================
 * 键
 * ==================================================================== */

/** 内置游戏用的固定键 —— ⛔ 它**永不移动**（我们换内置 jar 版本时数据必须原地不动）。 */
export const KEY_BUNDLED: string = 'bundled';
/** 版本读不出来时用的键。⚠️ 误把 mod jar 当游戏放进来就会走到这里。 */
export const KEY_UNKNOWN: string = '_unknown';

/** 目录名的允许字符集 —— ⛔ 必须与 launcher.c 的 resolve_user_home() 里那份一致。 */
const KEY_SAFE = /^[A-Za-z0-9._-]+$/;

/** `build` 字符串的整数部分：'160.5' -> '160'，'160' -> '160'。 */
function buildMajor(build: string): string {
  const dot: number = build.indexOf('.');
  return dot === -1 ? build : build.substring(0, dot);
}

/* 按粒度把版本字段折成一个键。
 * ⚠️ 键带 `n` / `b` 前缀，因为**游戏自己的 `v8` 指的是大版本（number）** —— 用 `v` 会撞车；
 * 看一眼目录名就知道是哪种粒度，而且粒度档位将来若被改（b160 -> n8），新旧目录不会同名。 */
export function granularityKey(granularity: string, parts: GameVersionParts): string {
  if (granularity === GRANULARITY_NUMBER) {
    return parts.number === '' ? KEY_UNKNOWN : ('n' + parts.number);
  }
  if (granularity === GRANULARITY_BUILD) {
    return parts.build === '' ? KEY_UNKNOWN : ('b' + buildMajor(parts.build));
  }
  if (granularity === GRANULARITY_PATCH) {
    /* ⚠️ 原样用文件里的字符串，**不补 '.0'** —— 带不带点已经表达了 revision 是否为 0
     * （见 GameLibrary.gameVersionParts 的说明）。 */
    return parts.build === '' ? KEY_UNKNOWN : ('b' + parts.build);
  }
  return '';
}

/* 这次启动该用哪个键；返回空串表示【不隔离】。`source` 取 GameLibrary.resolveGame() 的 'user'/'bundled'/'none'。
 * ⚠️ **内置游戏永远用 `bundled`，与粒度无关** —— 它有【一个】确定的来源，且我们换内置 jar 版本时它必须
 *    原地不动，否则一升级玩家数据就「消失」了。
 * ⚠️ `source === 'none'` ⇒ 空串：什么都没得启动，`user.home` 指向哪都无所谓，别白造空目录。 */
/* 一个版本**在这一档下**的身份 —— 两个版本这个值相等，就说明它们本来会落进同一个槽位。 */
function slotOf(granularity: string, parts: GameVersionParts): string {
  if (granularity === GRANULARITY_NUMBER) {
    return parts.number;
  }
  if (granularity === GRANULARITY_BUILD) {
    return buildMajor(parts.build);
  }
  if (granularity === GRANULARITY_PATCH) {
    return parts.build;
  }
  return '';
}

/* ⭐⭐ 算这次该用哪个键。`bundledJarPath` = **内置那份游戏** jar 的路径 —— ⛔ 不是可选的：内置那份**永远**
 * 用 `bundled` 键，于是「内置 160.5」与「玩家导入的 160.5」会被分到两个槽位（设备实测 2026-10-02：内置
 * key=bundled，Mindustry160.5.jar key=b160.5）—— 同一版本两份数据 ⇒ 用户 2026-10-02 定的「版本一致就
 * 合并」需要它；「一致」**按当前档的粗细判**（`slotOf()`），读不出来的照旧单占槽位。合并时内置那份数据胜出。 */
export function computeKey(granularity: string, source: string, jarPath: string,
                           bundledJarPath: string): string {
  if (granularity === GRANULARITY_OFF || !isValidGranularity(granularity)) {
    return '';
  }
  if (source === 'none') {
    return '';
  }
  if (source === 'bundled') {
    return KEY_BUNDLED;
  }
  const parts: GameVersionParts = gameVersionParts(jarPath);
  const mine: string = slotOf(granularity, parts);
  if (mine !== '' && bundledJarPath !== '') {
    const theirs: string = slotOf(granularity, gameVersionParts(bundledJarPath));
    if (theirs !== '' && mine === theirs) {
      return KEY_BUNDLED;
    }
  }
  return granularityKey(granularity, parts);
}

/* ⭐ **`instances/` 下现存的每一个键。** 用途只有一个但那一个是必须的：「一个目录现在还有没有
 * 版本读它」—— ⛔ 只从 `this.versions` 推是推不出来的：数据目录按**键**建，玩家一换粒度、一换 jar、
 * 一改合并规则，昨天的键今天就没有版本指向它了，而「界面上看不见」与「数据没了」在玩家眼里是同一件事。
 * ⚠️ 只认**名字合法**的目录（与 native 的 `resolve_user_home()` 同一套判据）。返回**键**不是路径。 */
export function listInstanceKeys(): string[] {
  try {
    if (!fs.accessSync(INSTANCES_ROOT)) {
      return [];
    }
    return fs.listFileSync(INSTANCES_ROOT).filter((n: string) => KEY_SAFE.test(n));
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'isolation: listing %{public}s failed (%{public}s)', INSTANCES_ROOT, err.message);
    return [];
  }
}

/* ====================================================================
 * 持久化
 * ==================================================================== */

/** 玩家选的粒度。这是**启动器的设置**，与下面那个给 native 的文件是两件事。 */
const SETTING_FILE_NAME = 'isolation_mode.txt';

/** 给 native 读的桥。⛔ 路径必须与 launcher.c 的 ISOLATION_FILE 一致。 */
const BRIDGE_FILE_NAME = 'isolation.txt';

/** 读玩家选的粒度。文件不在或内容不认识 ⇒ 出厂值（不隔离）。 */
export function readGranularity(filesDir: string): string {
  const path: string = filesDir + '/' + SETTING_FILE_NAME;
  try {
    if (!fs.accessSync(path)) {
      return GRANULARITY_DEFAULT;
    }
    const raw: string = fs.readTextSync(path).trim();
    if (isValidGranularity(raw)) {
      return raw;
    }
    /* ⚠️ 不认识的值【不报错、也不静默当成另一个有效值】—— 记一条日志再回退。
     * 「降级默认值」会把「读错了」掩盖成「看起来正常」，本项目为此付过代价。 */
    hilog.warn(DOMAIN, TAG, 'isolation: granularity "%{public}s" is not usable -- using the default', raw);
    return GRANULARITY_DEFAULT;
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'isolation: reading the granularity failed (%{public}s)', err.message);
    return GRANULARITY_DEFAULT;
  }
}

/** 记下粒度。只接受四档之一，其余拒绝。 */
export function writeGranularity(filesDir: string, g: string): void {
  if (!isValidGranularity(g)) {
    hilog.error(DOMAIN, TAG, 'isolation: refusing to write an unknown granularity "%{public}s"', g);
    return;
  }
  const path: string = filesDir + '/' + SETTING_FILE_NAME;
  try {
    const f: fs.File = fs.openSync(path,
      fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE);
    try {
      fs.writeSync(f.fd, g + '\n');
    } finally {
      fs.closeSync(f);
    }
    hilog.info(DOMAIN, TAG, 'isolation: granularity -> %{public}s', g);
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'isolation: saving the granularity failed (%{public}s)', err.message);
  }
}

/* 把这次的结论写给 native —— ⭐ **这是唯一影响 `-Duser.home=` 的地方**。格式（key=value，native 用
 * read_kv 解析，与 user_dirs.txt 同一套）：`enabled=1` / `key=b160.5` / `granularity=build`（后者只为排障留痕）。
 * ⚠️ 每次启动都要写，包括「不隔离」那一次 —— 留着一个上次的 `enabled=1` 会让「关掉」看起来没生效；
 *    写失败 ⇒ 什么都不做，让 native 落到「不隔离」，⛔ 绝不因为写不进去而拦住启动。 */
export function writeIsolationBridge(filesDir: string, granularity: string, key: string): void {
  const enabled: string = (key === '' || granularity === GRANULARITY_OFF) ? '0' : '1';
  const safeKey: string = (enabled === '1' && KEY_SAFE.test(key)) ? key : '';
  if (enabled === '1' && safeKey === '') {
    /* ⛔ 键里出现了不允许的字符 ⇒ 当成「不隔离」，而不是把脏键写下去。
     * 它会进路径，而 native 那侧也会再挡一次（两层都要有：这里防写坏，那里防读坏）。 */
    hilog.error(DOMAIN, TAG, 'isolation: key "%{public}s" has characters that are not allowed -- isolating nothing', key);
  }
  const body: string = 'enabled=' + (safeKey === '' ? '0' : enabled) + '\n'
                     + 'key=' + safeKey + '\n'
                     + 'granularity=' + granularity + '\n';
  const path: string = filesDir + '/' + BRIDGE_FILE_NAME;
  try {
    const f: fs.File = fs.openSync(path,
      fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE);
    try {
      fs.writeSync(f.fd, body);
    } finally {
      fs.closeSync(f);
    }
    hilog.info(DOMAIN, TAG, 'isolation: bridge written -- enabled=%{public}s key=%{public}s',
               (safeKey === '' ? '0' : enabled), safeKey);
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'isolation: writing the bridge failed (%{public}s)', err.message);
  }
}

/* ====================================================================
 * 目录与迁移
 * ==================================================================== */

/* ⚠️ 应用级目录的【字面路径】。ArkTS 拿不到它：`ctx.filesDir` 是 **HAP 级**的
 * `/data/storage/el2/base/haps/entry/files`，而 native 与游戏共享的是**应用级**的
 * `/data/storage/el2/base/files` —— 两个目录长得很像但不可互换，写错了 native 永远看不见，
 * 症状是「什么都没发生」。同款：`ExportDiagnostics.ets` 的 NATIVE_FILES、`Index.ets` 的 IME_*_FILE。 */
const NATIVE_FILES: string = '/data/storage/el2/base/files';

/* 隔离根与游戏数据的那一层后缀 —— ⛔ **两个都必须与 launcher.c 里的宏逐字一致**：
 *     ISOLATION_ROOT = DEST_ROOT "/instances"、ISOLATION_SET = "sets/default"，
 *     而 ".local/share/Mindustry" 是 ARC 的 OS.getAppDataDirectoryString() 拼出来的。
 * ⚠️ 三处里任何一处改了，另一处不会报错，只会让数据落到别处 —— 这是无声的。 */
const INSTANCES_ROOT: string = NATIVE_FILES + '/instances';
const SETS_SUFFIX: string = '/sets/default';
const GAME_DATA_SUFFIX: string = '/.local/share/Mindustry';

/** 某个粒度键对应的游戏数据目录（= `user.home` + ARC 那一层）。 */
export function isolatedGameDataDir(key: string): string {
  return INSTANCES_ROOT + '/' + key + SETS_SUFFIX + GAME_DATA_SUFFIX;
}

/** 隔离关着时游戏用的数据目录，也就是今天的位置。 */
export function liveGameDataDir(): string {
  return NATIVE_FILES + GAME_DATA_SUFFIX;
}

/* 按【这一次的粒度与选中项】解出游戏数据目录 —— 与 native 启动时算 `user.home` 用的是同一套输入。
 * ⭐ 为什么要有它：存档管理器必须**看同一个目录**，否则它会列出另一份存档，而那是最坏的一类不一致。
 * ⚠️ 两者仍可能分叉：native 在**启动那一刻**读桥，这里在**页面读到的时候**算 —— 玩家改了粒度还没重启
 *    的话，这里算的是**新**的而游戏那边是**旧**的 ⇒ 调用方要提示需要重启。 */
export function resolveGameDataDir(granularity: string, source: string, jarPath: string,
                                   bundledJarPath: string): string {
  return resolveGameDirAndKey(granularity, source, jarPath, bundledJarPath).dir;
}

/** 一次解析的结果：隔离键，以及它指向的数据目录。 */
export interface GameDirForKey {
  /** 隔离键；'' 表示不隔离（用公开的那一份数据）。 */
  key: string;
  /** 该键指向的游戏数据目录。 */
  dir: string;
}

/* 一次算出**键**和**目录**。⚠️⚠️ 必须成对返回，而不是分别调 `computeKey()` 与 `resolveGameDataDir()`：
 * `computeKey()` 最终会走 `gameVersionParts()`，那个函数**没有缓存** —— 每调一次就真读一次 jar
 * （`isReadableJar` + native 的 `jarVersionText`），分开调两次等于把每个 jar 读两遍；而「按版本」那一屏
 * 要为每个已装版本算目录且是**渲染**出来的 ⇒ 形状上就让它一次给全。`resolveGameDataDir()` 是取 `dir` 的薄包装。 */
export function resolveGameDirAndKey(granularity: string, source: string, jarPath: string,
                                     bundledJarPath: string): GameDirForKey {
  const key: string = computeKey(granularity, source, jarPath, bundledJarPath);
  return { key: key, dir: key === '' ? liveGameDataDir() : isolatedGameDataDir(key) };
}

/** 两个目录都存在吗。界面用它决定「复制」那一条要不要给。 */
export function gameDataExists(dir: string): boolean {
  try {
    return fs.accessSync(dir);
  } catch (e) {
    return false;
  }
}

/* 一份数据里各有多少东西 —— 给**询问窗**用的（用户 2026-10-02：「用户必须选择确定后才能看到迁移成什么样」⇒ 把结果先摆出来，用真实数量）。
 * ⛔⛔ 用户又说「40 个存档看着有歧义，应该是 40 个战役（区块）存档更合理」—— 我去数了一遍，**那个 40
 * 本身是错的，错三处**（同一台平板实测）：总条目 40、`-backup` 文件 21、非 .msav 1（steam_autocloud.vdf）
 * ⇒ 真存档 18（战役区块 15 + 手动 3）。⭐ 教训：我把「目录里的条目数」当成了「存档数」，两者差 22 个。 */
export interface GameDataCounts {
  /** 战役区块存档数（`sector-*.msav`），已排除 `-backup`。 */
  sectorSaves: number;
  /** 玩家手动存的档（非 `sector-` 前缀），已排除 `-backup`。 */
  manualSaves: number;
  /** `mods/` 里的条目数。 */
  mods: number;
  /** `schematics/` 里的条目数。 */
  schematics: number;
}

/** 一个子目录里的【文件名】列表；目录不存在或读不出来 ⇒ 空数组。 */
function namesIn(dir: string, sub: string): string[] {
  try {
    const p: string = dir + '/' + sub;
    if (!fs.accessSync(p)) {
      return [];
    }
    return fs.listFileSync(p);
  } catch (e) {
    return [];
  }
}

/** 是不是一个真存档：`.msav` 结尾，且不是游戏自动生成的 `-backup`。 */
function isRealSave(n: string): boolean {
  return n.endsWith('.msav') && !n.includes('-backup');
}

/** 战役区块存档的判据 —— 文件名前缀，与 `Saves.getSectorFile()` 的命名一致。 */
function isSectorSave(n: string): boolean {
  return n.startsWith('sector-');
}

/** 数一下某个数据目录里有什么。⚠️ 数法见 GameDataCounts 上方那段订正。 */
export function countsOf(dir: string): GameDataCounts {
  const saves: string[] = namesIn(dir, 'saves').filter(isRealSave);
  return {
    sectorSaves: saves.filter(isSectorSave).length,
    manualSaves: saves.filter((n: string) => !isSectorSave(n)).length,
    mods: namesIn(dir, 'mods').length,
    schematics: namesIn(dir, 'schematics').length,
  };
}

/** 把数量说成一句人话，例如「15 个战役区块 · 3 个手动存档 · 2 个模组」。
 * ⚠️ 为 0 的那一类**不写出来** —— 「0 个模组」在这句话里是噪音。⛔ 但全都为 0 时要说「空的」。 */
export function describeCounts(c: GameDataCounts): string {
  const parts: string[] = [];
  if (c.sectorSaves > 0) {
    parts.push(c.sectorSaves + ' 个战役区块');
  }
  if (c.manualSaves > 0) {
    parts.push(c.manualSaves + ' 个手动存档');
  }
  if (c.mods > 0) {
    parts.push(c.mods + ' 个模组');
  }
  if (c.schematics > 0) {
    parts.push(c.schematics + ' 个蓝图');
  }
  return parts.length === 0 ? '空的' : parts.join(' · ');
}

/* 递归复制**不再在这里实现** —— 已抽到 `utils/FsTree.ets`（存档垃圾站也要用：搬家/放回/彻底删除）。
 * ⛔⛔ 那份实现里记着**为什么不能用 `fs.copyDirSync`** —— 2026-10-02 的四用例实测证明它在我们的
 * 沙箱里**连一个空目录都复制不了**（`Invalid argument`）。⛔ 别在这里重抄一遍（会分叉）。 */


export function copyLiveDataInto(key: string): string {
  const src: string = liveGameDataDir();
  const dst: string = isolatedGameDataDir(key);

  if (!gameDataExists(src)) {
    /* ⭐ 没有旧数据可搬 —— 这不是失败。全新安装第一次就打开隔离，走的就是这条。 */
    hilog.info(DOMAIN, TAG, 'isolation: nothing to copy (%{public}s does not exist)', src);
    return '';
  }

  /* ⭐ 走**自己的递归复制**，不是 `fs.copyDirSync`（那个 API 在我们的沙箱里连空目录都复制不了，见 FsTree.ets）。
   * ⛔⛔ 订正（2026-10-02）：我曾认定「失败是因为 dst 的父目录没建」并照改了一版，那是错的 —— 探针显示
   * 父目录建好了、依然同一 EINVAL。⇒ **报错文案列了多个成因时，先设计一个能区分它们的实验**（四用例二分）。 */

  const acc: TreeStat = newTreeStat();
  copyTreeInto(src, dst, 0, acc);
  if (acc.failed > 0) {
    /* ⚠️⚠️ 把 src / dst 与**第一个**错误都打进日志。
     *    上一版只报错误码、不报路径，于是我只能去设备上翻目录树 ——
     *    一条不写路径的日志，等于把排查的第一步推给下一个人。 */
    hilog.error(DOMAIN, TAG,
                'isolation: copy had %{public}d failure(s), first: %{public}s (%{public}s -> %{public}s)',
                acc.failed, acc.firstError, src, dst);
    return '复制没完成（' + String(acc.failed) + ' 个文件没复制过去）：' + acc.firstError;
  }
  hilog.info(DOMAIN, TAG, 'isolation: copied %{public}d dir(s) / %{public}d file(s) %{public}s -> %{public}s',
             acc.dirs, acc.files, src, dst);
  return '';
}
