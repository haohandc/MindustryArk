/* [A]
 * 版本隔离 —— 让每个游戏版本各用一套游戏数据。
 *
 * 为什么需要它
 *   启动器允许玩家自选加载哪个游戏 jar，而游戏的**全部**状态都由一个东西决定：
 *   `-Duser.home=`。`Vars.dataDirectory = Core.settings.getDataDirectory()`，
 *   而后者在 `dataDirectory` 为 null 时用 `user.home` 派生 ⇒ **不隔离就是所有版本共用一份存档**。
 *
 * ⭐ 这个文件负责【决定】与【传达】，不负责【执行】：
 *
 *     ArkTS（这里）                       native（launcher.c）
 *     算出这次该用哪个键  ──写文件──▶     读文件、拼路径、mkdir、设 -Duser.home=
 *
 * ⛔ 游戏完全不知道隔离存在。它只看到一个 user.home —— 所以这件事**不需要任何 Java 代码**。
 *
 * 为什么键在这里算、不在 native 算
 *   版本号的读取（`version.properties` 的解析）**已经在这一侧**（GameLibrary 的
 *   gameVersionParts）。让 native 再实现一遍 = 同一件事两份实现，而那是本项目反复付代价的形态。
 *
 * ⚠️ 两条不许破坏的不变量：
 *   1. **默认是「不隔离」**。文件不在、内容不认识、任何一步失败 ⇒ 一律回到不隔离。
 *      ⛔ 这条尤其重要，因为 `user.home` 一改，玩家打开游戏会发现存档「没了」。
 *   2. 隔离关着时 native 用的 `user.home` **逐字节等于**隔离功能出现之前的值 ——
 *      不是「等价」，是逐字节相同。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { GameVersionParts, gameVersionParts } from '../games/GameLibrary';

const DOMAIN = 0x0000;
const TAG = 'MindustryLauncher';

/* ====================================================================
 * 粒度
 * ==================================================================== */

/** [B] 不隔离 —— **出厂值**。 */
export const GRANULARITY_OFF: string = 'off';
/** [B] 按大版本分（v8 / v9）。 */
export const GRANULARITY_NUMBER: string = 'number';
/** [B] 按构建号分（160 / 159）。⭐ 推荐档。 */
export const GRANULARITY_BUILD: string = 'build';
/** [B] 按构建号连小版本一起分（160.5 / 160.4）。 */
export const GRANULARITY_PATCH: string = 'patch';

/* [A]
 * ⭐ 出厂值 = **不隔离**，而这是刻意的。
 *
 * 改 `user.home` 等于**搬走玩家存档**。让一个升级动作悄悄地改变数据位置，
 * 会让「更新完应用，存档没了」变成一次事故 —— 而玩家什么都没做。
 * ⇒ 隔离必须是**玩家想要才开**的东西。
 *
 * ⭐ 配套的是 native 那侧的不变量：关着时 user.home 与今天【逐字节相同】。
 * 两条一起才让「默认不隔离」真正落地，而不是一句口号。
 */
export const GRANULARITY_DEFAULT: string = GRANULARITY_OFF;

/** [B] 界面上按顺序列出的四档。 */
export const GRANULARITIES: string[] = [
  GRANULARITY_OFF, GRANULARITY_NUMBER, GRANULARITY_BUILD, GRANULARITY_PATCH
];

/** [B] 一个非法值不该被当成某个合法值，所以单独问一次。 */
export function isValidGranularity(g: string): boolean {
  return GRANULARITIES.indexOf(g) >= 0;
}

/* ====================================================================
 * 键
 * ==================================================================== */

/** [B] 内置游戏用的固定键 —— ⛔ 它**永不移动**（我们换内置 jar 版本时数据必须原地不动）。 */
export const KEY_BUNDLED: string = 'bundled';
/** [B] 版本读不出来时用的键。⚠️ 误把 mod jar 当游戏放进来就会走到这里。 */
export const KEY_UNKNOWN: string = '_unknown';

/** [B] 目录名的允许字符集 —— ⛔ 必须与 launcher.c 的 resolve_user_home() 里那份一致。 */
const KEY_SAFE = /^[A-Za-z0-9._-]+$/;

/** [B] `build` 字符串的整数部分：'160.5' -> '160'，'160' -> '160'。 */
function buildMajor(build: string): string {
  const dot: number = build.indexOf('.');
  return dot === -1 ? build : build.substring(0, dot);
}

/* [A]
 * 按粒度把版本字段折成一个键。
 *
 * ⚠️ 键带 `n` / `b` 前缀，是因为**游戏自己的 `v8` 指的是大版本（number）** ——
 * 用 `v` 会撞车。看一眼目录名就知道是哪种粒度。
 *
 * ⭐ 前缀还有一个实际好处：粒度档位将来若被改（b160 -> n8），新旧目录不会同名。
 */
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

/* [A]
 * 这次启动该用哪个键；返回空串表示【不隔离】。
 *
 * `source` 取 GameLibrary.resolveGame() 的结论：'user' / 'bundled' / 'none'。
 *
 * ⚠️ **内置游戏永远用 `bundled`，与粒度无关。** 理由是它有【一个】确定的来源，
 * 而且我们换内置 jar 版本时它必须原地不动 —— 否则一升级，玩家数据就「消失」了。
 *
 * ⚠️ `source === 'none'`（一个可加载的游戏都没有）⇒ 返回空串。
 * 那时什么都没得启动，`user.home` 指向哪里都无所谓，那就别白白造一个空目录出来。
 */
export function computeKey(granularity: string, source: string, jarPath: string): string {
  if (granularity === GRANULARITY_OFF || !isValidGranularity(granularity)) {
    return '';
  }
  if (source === 'none') {
    return '';
  }
  if (source === 'bundled') {
    return KEY_BUNDLED;
  }
  return granularityKey(granularity, gameVersionParts(jarPath));
}

/* ====================================================================
 * 持久化
 * ==================================================================== */

/** [B] 玩家选的粒度。这是**启动器的设置**，与下面那个给 native 的文件是两件事。 */
const SETTING_FILE_NAME = 'isolation_mode.txt';

/** [A] 给 native 读的桥。⛔ 路径必须与 launcher.c 的 ISOLATION_FILE 一致。 */
const BRIDGE_FILE_NAME = 'isolation.txt';

/** [B] 读玩家选的粒度。文件不在或内容不认识 ⇒ 出厂值（不隔离）。 */
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

/** [B] 记下粒度。只接受四档之一，其余拒绝。 */
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

/* [A]
 * 把这次的结论写给 native —— ⭐ **这是唯一影响 `-Duser.home=` 的地方**。
 *
 * 格式（key=value，native 用 read_kv 解析，与 user_dirs.txt 同一套规则）：
 *
 *     enabled=1
 *     key=b160.5
 *     granularity=build        ← ⛔ native 不用它，只为排障留痕
 *
 * ⚠️ 每次启动都要写，包括「不隔离」那一次 —— 因为玩家可能**刚刚**把开关关上，
 * 而 native 只认文件内容。留着一个上次的 `enabled=1` 就会让「关掉」看起来没生效。
 *
 * ⚠️ 写失败 ⇒ 什么都不做，让 native 落到「不隔离」。⛔ 绝不因为写不进去而拦住启动。
 */
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
