/* 版本隔离 —— 让每个游戏版本各用一套游戏数据。
 * 游戏状态由 `-Duser.home=` 决定（`Vars.dataDirectory = Core.settings.getDataDirectory()`）⇒
 * **不隔离就是所有版本共用一份存档**。⭐ 本文件只【决定】与【传达】，不【执行】：ArkTS 算键 →写文件→
 * native（launcher.c）读文件、拼路径、mkdir、设 `-Duser.home=`；⛔ 游戏完全不知道隔离存在，**不需要
 * 任何 Java 代码**。键在这里算是因为 `version.properties` 解析已在这一侧（GameLibrary.gameVersionParts）。
 * ⚠️ 两条不变量：1. **默认是「不隔离」**（文件不在/不认识/任何一步失败都回不隔离）；
 * 2. 隔离关着时 native 的 `user.home` **逐字节等于**隔离之前的值（不是「等价」）。 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { GameVersionParts, gameVersionParts } from '../games/GameLibrary';
import { copyTreeInto, removeTree, newTreeStat, TreeStat } from '../utils/FsTree';
/* ⭐ 跨根迁移用 **native** 的递归复制 —— 理由见那个函数与 `storprobe.c` 的说明。 */
import { nativeCopyTree } from './StorageRoot';
/* ⭐ 存储根的唯一真相源。⛔ 这里 import 它**不会成环**（`StorageRoot` 只依赖 `ModImporter`）。 */
import { gameDataRoot, gameDataRootFor, nativeListTree, nativePathExists,
         STORAGE_MODE_SANDBOX, STORAGE_MODE_EXTERNAL } from './StorageRoot';
/* ⭐ 解析游戏自己的 settings.bin —— 诊断清单里要报那两个值（异形屏避让 / UI 缩放）。 */
import { loadGameSettings, intSetting, KEY_EDGE_PADDING, KEY_UI_SCALE } from '../games/GameSettings';
/* ⭐ 游戏语言：偏好在本文件写进桥，而「设备语言 → 游戏认得的那个值」的翻译在 GameLocale。 */
import { readGameLocaleFollow } from './LauncherPrefs';
import { systemGameLocale } from './GameLocale';

const DOMAIN = 0x0000;
const TAG = 'MindustryLauncher';

/* ===== 粒度 ===== */

/** 不隔离 —— **出厂值**。 */
export const GRANULARITY_OFF: string = 'off';
/** 按大版本分（v8 / v9）。 */
export const GRANULARITY_NUMBER: string = 'number';
/** 按构建号分（160 / 159）。⭐ 推荐档。 */
export const GRANULARITY_BUILD: string = 'build';
/** 按构建号连小版本一起分（160.5 / 160.4）。 */
export const GRANULARITY_PATCH: string = 'patch';

/* ⭐ 出厂值 = **不隔离**，刻意如此：改 `user.home` 等于**搬走玩家存档**，一个升级动作悄悄改变数据位置
 * 会让「更新完应用，存档没了」变成一次事故 ⇒ 隔离必须是**玩家想要才开**的。
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

/* ===== 键 ===== */

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

/* 按粒度把版本字段折成一个键。⚠️ 键带 `n` / `b` 前缀，因为**游戏自己的 `v8` 指的是大版本（number）**
 * —— 用 `v` 会撞车；看一眼目录名就知道是哪种粒度，粒度档位若被改（b160 -> n8）新旧目录也不会同名。 */
export function granularityKey(granularity: string, parts: GameVersionParts): string {
  if (granularity === GRANULARITY_NUMBER) {
    return parts.number === '' ? KEY_UNKNOWN : ('n' + parts.number);
  }
  if (granularity === GRANULARITY_BUILD) {
    return parts.build === '' ? KEY_UNKNOWN : ('b' + buildMajor(parts.build));
  }
  if (granularity === GRANULARITY_PATCH) {
    /* ⚠️ 原样用文件里的字符串，**不补 '.0'** —— 带不带点已经表达了 revision 是否为 0。 */
    return parts.build === '' ? KEY_UNKNOWN : ('b' + parts.build);
  }
  return '';
}

/* 这次启动该用哪个键；返回空串表示【不隔离】。`source` 取 GameLibrary.resolveGame() 的 'user'/'bundled'/'none'。
 * ⚠️ **内置游戏永远用 `bundled`，与粒度无关**（它有【一个】确定的来源，换内置 jar 版本时它必须原地不动）。
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

/* `instances/` 下现存的每一个键。用途只有一个但必须：「一个目录现在还有没有版本读它」——
 * ⛔ 只从 `this.versions` 推不出来：数据目录按**键**建，玩家换粒度/换 jar/改合并规则后昨天的键就没人指向它。
 * ⚠️ 只认**名字合法**的目录（与 native 的 `resolve_user_home()` 同一套判据）。返回**键**不是路径。 */
export function listInstanceKeys(): string[] {
  /* ⚠️ 每次都问 `instancesRoot()`，**不要在函数外缓存** —— 根可以换，缓存住就等于换根之后还在列旧地方。 */
  const root: string = instancesRoot();
  try {
    if (!fs.accessSync(root)) {
      return [];
    }
    return fs.listFileSync(root).filter((n: string) => KEY_SAFE.test(n));
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'isolation: listing %{public}s failed (%{public}s)', root, err.message);
    return [];
  }
}

/* ===== 持久化 ===== */

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
    /* ⚠️ 不认识的值【不报错、也不静默当成另一个有效值】—— 记一条日志再回退（「降级默认值」会掩盖「读错了」）。 */
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
    /* ⛔ 键里有不允许的字符 ⇒ 当成「不隔离」，而不是把脏键写下去（它进路径，native 那侧也会再挡一次）。 */
    hilog.error(DOMAIN, TAG, 'isolation: key "%{public}s" has characters that are not allowed -- isolating nothing', key);
  }
  /* ⭐⭐ 存储根：**与 key 写在同一次 writeSync 里**，不是新开一个文件 —— 两次写之间有窗口会出现
   *    「根新键旧」，而这两个值**合起来**才决定 `user.home` ⇒ 撕裂的后果是数据落到谁也没打算用的地方。
   * ⚠️ 这里写的是**意图**，native 那边自己再校验（`root_is_usable`）；根**在这里算**、不当参数传。 */
  const root: string = gameDataRoot(filesDir);
  /* ⭐⭐ 游戏语言，**与 `root` 同一套道理：在这里算，不当参数传**（两处调用方，传参数就多两条能传错的路）。
   * ⚠️ 关掉「跟随系统」时写**空值**（`locale=`）而不是省略这一行 —— 写出来能让这个文件自己说明情况。
   * ⛔ 值必须是游戏认得的（见 `GameLocale.systemGameLocale()`）—— 给错值比不给更糟。 */
  const locale: string = readGameLocaleFollow(filesDir) ? systemGameLocale() : '';
  const body: string = 'enabled=' + (safeKey === '' ? '0' : enabled) + '\n'
                     + 'key=' + safeKey + '\n'
                     + 'root=' + root + '\n'
                     + 'locale=' + locale + '\n'
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

/* ===== 目录与迁移 ===== */

/* ⚠️ 应用级目录的【字面路径】。ArkTS 的 `ctx.filesDir` 是 **HAP 级**的 `…/haps/entry/files`，
 * 而 native 与游戏共享**应用级**的 `/data/storage/el2/base/files` —— 写错了 native 永远看不见。 */
const NATIVE_FILES: string = '/data/storage/el2/base/files';

/* ⭐⭐ **游戏数据根**（2026-10-04 起可切换）。由 `LauncherHome.refresh()` 每次刷新时 `setGameDataRoot()`。
 * ⛔ 用**模块级的一个值**、不给下面每个函数加 `filesDir` 参数：这里有 28 处调用点，漏传不会报错，
 *    只会让那一条路读到**另一个根** ——「界面上看起来完全正常」。判据同 `launcher.c` 拆掉
 *    `ISOLATION_ROOT` 宏：**让错误写法根本写不出来。** ⚠️ 默认 = 沙箱；它是 `let`，只在 `refresh()` 里改。 */
let GAME_DATA_ROOT: string = NATIVE_FILES;

/** 设定游戏数据根。⛔ 只有 `LauncherHome.refresh()` 该调它 —— 见上面那段。 */
export function setGameDataRoot(root: string): void {
  GAME_DATA_ROOT = (root === '' ? NATIVE_FILES : root);
}

/** **当前**的游戏数据根。⭐ 给「判断某个记下来的绝对路径还算不算数」用（根可以换，见 `SaveVault`）。 */
export function currentGameDataRoot(): string {
  return GAME_DATA_ROOT;
}

/* 隔离根与游戏数据的那一层后缀 —— ⛔ **都必须与 `launcher.c` 里的宏逐字一致**：
 *     ISOLATION_SUBDIR = "/instances"、ISOLATION_SET = "sets/default"，
 *     而 ".local/share/Mindustry" 是 ARC 的 `OS.getAppDataDirectoryString()` 拼出来的。 */
const INSTANCES_SUBDIR: string = '/instances';
const SETS_SUFFIX: string = '/sets/default';
const GAME_DATA_SUFFIX: string = '/.local/share/Mindustry';

/** 隔离根（在**当前数据根**之下）。⚠️ 它以前是个引用 `NATIVE_FILES` 的常量 —— 那样根一换，这里就还指着沙箱。 */
export function instancesRoot(): string {
  return GAME_DATA_ROOT + INSTANCES_SUBDIR;
}

/** 某个粒度键对应的游戏数据目录（= `user.home` + ARC 那一层）。
 * ⛔ **「用键拼路径」的本体，第二层防线**（第一层在 `resolveGameDirAndKey`）：键带 `/` 或 `..` 就能
 *    拼出数据根**外面**的路径，而它会交给 native 复制/删 ⇒ 不安全就返回**不隔离**那棵树，
 *    与桥、与 native `resolve_user_home()` 的兜底**三处一致**。 */
export function isolatedGameDataDir(key: string): string {
  if (!KEY_SAFE.test(key)) {
    hilog.warn(DOMAIN, TAG, 'isolation: unsafe key %{public}s in a data path -- using the '
               + 'live tree instead', key);
    return liveGameDataDir();
  }
  return instancesRoot() + '/' + key + SETS_SUFFIX + GAME_DATA_SUFFIX;
}

/** 隔离关着时游戏用的数据目录 —— 就在当前根底下。 */
export function liveGameDataDir(): string {
  return GAME_DATA_ROOT + GAME_DATA_SUFFIX;
}

/* ⭐⭐ 把 `settings.bin` 里 **`locale` 那个键的值**抠出来 —— 语言就是它决定的。
 * ⛔ `locale=default` = 跟随 `Locale.getDefault()`；在本启动器传 `-Duser.language` 之前那是 C locale ⇒ 英文。
 * ⚠️⚠️ 更要紧的是**它会被固化**：`LanguageDialog.findClosestLocale()` 找不到就硬编码 `new Locale("en")`
 *    并 **`put("locale", …)` 写回** ⇒ 实测两份 settings.bin 都是 `locale=en`，这一行是分辨病因的唯一判据。 */
export function settingsLocaleIn(dir: string): string {
  const p: string = dir + '/settings.bin';
  try {
    if (!fs.accessSync(p)) {
      return 'no-settings';
    }
    const size: number = fs.statSync(p).size;
    /* ⛔ 只读前 64 KB：`settings.bin` 是几 KB，而它在 refresh() 里被调用；读整份给了「文件被撑大」无上限的成本。 */
    const want: number = size > 65536 ? 65536 : size;
    /* ⛔⛔ **`closeSync` 必须在 `finally` 里**（2026-10-05 修）：原来它与 `readSync` 同一条直线，
     *    `readSync` 一抛那句 `closeSync` 就永不执行、而 `f` 已是打开的描述符 ⇒ **fd 泄漏**。
     *    本函数在 `refresh()` 里对每个数据目录各读一次 ⇒ 一轮可能泄漏好几个，直到 `open` 报 EMFILE。 */
    const f: fs.File = fs.openSync(p, fs.OpenMode.READ_ONLY);
    let buf: ArrayBuffer = new ArrayBuffer(0);
    let got: number = 0;
    try {
      buf = new ArrayBuffer(want);
      got = fs.readSync(f.fd, buf);
    } finally {
      fs.closeSync(f);
    }
    const u: Uint8Array = new Uint8Array(buf, 0, got);
    const key: string = 'locale';
    let seen: number = 0;
    /* ⚠️ 从 2 开始：下面要回看 `u[i-2]`（长度前缀），从 0 开始会读到数组外，比较恒不相等 ⇒ 一个都匹配不上。 */
    for (let i = 2; i + key.length + 3 <= got; i++) {
      let hit: boolean = true;
      for (let j = 0; j < key.length; j++) {
        if (u[i + j] !== key.charCodeAt(j)) {
          hit = false;
          break;
        }
      }
      if (!hit) {
        continue;
      }
      seen++;
      /* 长度前缀对不上 ⇒ 不是这个键（可能别的键名里含 `locale`，或某个值里含它）。 */
      if (u[i - 2] !== 0 || u[i - 1] !== key.length) {
        continue;
      }
      /* 结构：`00 06 locale` | 类型字节 | 值。String 类型的值是 writeUTF ⇒ 又一个 2 字节长度。 */
      const typeAt: number = i + key.length;
      if (typeAt + 2 >= got) {
        continue;
      }
      const vlen: number = (u[typeAt + 1] << 8) | u[typeAt + 2];
      if (vlen <= 0 || vlen > 32 || typeAt + 3 + vlen > got) {
        return 'type=' + String(u[typeAt]) + ' len=' + String(vlen) + ' (not a short string)';
      }
      let out: string = '';
      for (let j = 0; j < vlen; j++) {
        const c: number = u[typeAt + 3 + j];
        /* 非可打印字节写成 `<1f>` 这种带尖括号的十六进制。⛔ 不用 `\x` 转义：那个反斜杠在几层工具
         *    之间传容易掉，而掉了之后 `'\x'` 是一个**编译错误**（`Hexadecimal digit expected`）—— 踩过。 */
        out += (c >= 32 && c < 127) ? String.fromCharCode(c) : ('<' + c.toString(16) + '>');
      }
      return out;
    }
    return seen === 0 ? 'no-key' : ('no-exact-key(' + String(seen) + ' loose)');
  } catch (e) {
    const err = e as BusinessError;
    return 'ERR(' + err.message + ')';
  }
}

/* 游戏那份 `settings.bin` 里「异形屏避让 / UI 缩放」两个值 —— **只给诊断用**。
 * ⛔ 写入只在「值仍是出厂默认」时才发生 ⇒ 全新安装上它什么都不做，「读得对不对」界面与日志都看不出。
 * ⭐ 这一行把「解析器能不能读懂真文件」变成不用点任何东西就能读到的数。
 * ⚠️ `unreadable` 与「读到了 0 / 100」必须分开报（`intSetting` 兜底用 -1：真值不可能为负）。 */
function gameDisplayLine(dir: string): string {
  const rows = loadGameSettings(dir + '/settings.bin');
  if (rows === null) {
    return 'game=unreadable';
  }
  return 'game=edge=' + String(intSetting(rows, KEY_EDGE_PADDING, -1))
       + ' scale=' + String(intSetting(rows, KEY_UI_SCALE, -1))
       + ' entries=' + String(rows.length);
}

/* ⭐⭐ 两个根下**每一个**游戏数据目录的清单（每行带文件大小）—— 只给诊断用。
 * ⛔ 外置那棵树在排查里原本不存在：ArkTS 的 fileIo 不一定读得到，而 `hdc shell` **连 `/storage/Users`
 *    都看不见** ⇒「搬过去之后少了什么」只能靠玩家照屏幕念，而「126 个文件里少了哪几个」念不出来。
 * ⭐ **文件大小是关键**：拿外置那份字节数与沙箱那份一比，「复制把文件截短了」就从推测变成一个数。 */
export function dumpDataDirs(filesDir: string): string {
  /* ArkTS 侧列一个目录能拿到几条（对照用）。⛔ 读不到要**报出来**（`ERR …`），不能当 0。 */
  const arktsEntryCount = (d: string): string => {
    try {
      return String(fs.listFileSync(d).length);
    } catch (e) {
      const err = e as BusinessError;
      return 'ERR(' + err.message + ')';
    }
  };
  let out: string = '';
  const roots: string[] = ['sandbox', 'external'];
  for (const which of roots) {
    const root: string = gameDataRootFor(filesDir,
                                         which === 'external' ? STORAGE_MODE_EXTERNAL
                                                              : STORAGE_MODE_SANDBOX);
    if (root === '') {
      continue;
    }
    out += '=== ' + which + ' ' + root + '\n';
    /* ① 不隔离的那一份（就在根底下）。 */
    /* ⛔ 用 `root + GAME_DATA_SUFFIX` 而**不是** `liveGameDataDir()` —— 后者读**当前**根，于是列「另一个
     *    根」时会印出当前根的路径，看上去像两份一样的清单（对比两个根正是本函数的意义）。 */
    out += '--- ' + which + ':live ' + root + GAME_DATA_SUFFIX + '\n'
         + nativeListTree(root + GAME_DATA_SUFFIX, 2);
    /* ⭐⭐ **对照**：同一棵树 **ArkTS 侧能看见多少**。⛔ 把「读不到」和「里面没有」分开 —— 两者在
     *    ArkTS 这边长得一样，而**整个存档管理器都走 ArkTS 的 `fs`**：2026-10-04 实测 native 列出
     *    外置那棵树里有 24 个 `.msch`，而 ArkTS 一个都读不出来。 */
    out += '--- ' + which + ':arkts ' + root + GAME_DATA_SUFFIX + '\n'
         + '  entries=' + arktsEntryCount(root + GAME_DATA_SUFFIX)
         + ' saves=' + arktsEntryCount(root + GAME_DATA_SUFFIX + '/saves')
         + ' schematics=' + arktsEntryCount(root + GAME_DATA_SUFFIX + '/schematics') + '\n'
         + '  locale=' + settingsLocaleIn(root + GAME_DATA_SUFFIX) + '\n'
         + '  ' + gameDisplayLine(root + GAME_DATA_SUFFIX) + '\n';
    /* ② 每一个隔离键那一份。⚠️ 键用 native 列 —— ArkTS 的 `fs` 在外部根上不一定读得到，「读不到」与「没有」长得一样。 */
    const keysRaw: string = nativeListTree(root + INSTANCES_SUBDIR, 1);
    const keys: string[] = [];
    for (const line of keysRaw.split('\n')) {
      const t: string = line.trim();
      /* ⛔ **只收【一层】的名字**：`/b160.4/` 是键，`/b160.4/sets/` 不是。第一版没这条，于是把
       *    `/b160.4/sets`、`/bundled/sets` 也当成键 —— 症状只是清单里多了几行，不会报错（踩过）。 */
      if (!t.startsWith('/') || !t.endsWith('/') || t.startsWith('<')) {
        continue;
      }
      const body: string = t.substring(1, t.length - 1);
      if (body === '' || body.indexOf('/') !== -1 || body.indexOf(' ') !== -1) {
        continue;
      }
      keys.push(body);
    }
    if (keys.length === 0) {
      out += '--- ' + which + ':keys none (' + keysRaw.trim() + ')\n';
    }
    for (const k of keys) {
      /* ⭐ 每一档也带上**语言**那一行 —— 「语言变英文了」要看的就是**这一档**里 settings.bin 的 `locale`。 */
      const kd: string = root + INSTANCES_SUBDIR + '/' + k + SETS_SUFFIX + GAME_DATA_SUFFIX;
      out += '--- ' + which + ':' + k + '\n'
           + nativeListTree(kd, 2)
           + '  locale=' + settingsLocaleIn(kd) + '\n';
    }
  }
  return out;
}

/* 按【这一次的粒度与选中项】解出游戏数据目录 —— 与 native 启动时算 `user.home` 用同一套输入。
 * ⭐ 存档管理器必须**看同一个目录**，否则会列出另一份存档（最坏的一类不一致）。
 * ⚠️ 两者仍可能分叉：native 在**启动那一刻**读桥，这里在**页面读到的时候**算 ⇒ 调用方要提示需要重启。 */
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

/* 一次算出**键**和**目录**。⚠️⚠️ 必须成对返回：分开调 `computeKey()` 与 `resolveGameDataDir()` 会把
 * 每个 jar 读两遍（`gameVersionParts()` **没有缓存**），而「按版本」那一屏是**渲染**出来的。
 * `resolveGameDataDir()` 是取 `dir` 的薄包装。 */
export function resolveGameDirAndKey(granularity: string, source: string, jarPath: string,
                                     bundledJarPath: string): GameDirForKey {
  const raw: string = computeKey(granularity, source, jarPath, bundledJarPath);
  /* ⛔⛔ **键必须在这里过一遍 `KEY_SAFE`，⛔ 不能只靠桥那一道。**（2026-10-05 代码审查）桥挡了脏键，
   *    但**这条真正做文件操作的路径一次都没校验过**，而键来自**玩家可替换的 jar**（`propField('build')`
   *    只 `trim()`）⇒ `build=../../x` 能让路径**穿出数据根**。⛔ 不安全 ⇒ 当成**不隔离**（`key=''`）。 */
  const key: string = (raw === '' || KEY_SAFE.test(raw)) ? raw : '';
  if (key === '' && raw !== '') {
    /* ⛔ 不静默：脏键意味着**有一个我们没料到的 jar 在读**，那是要有人知道的。 */
    hilog.warn(DOMAIN, TAG, 'isolation: refusing unsafe key %{public}s -- treating it as '
               + 'not isolated', raw);
  }
  return { key: key, dir: key === '' ? liveGameDataDir() : isolatedGameDataDir(key) };
}

/** 两个目录都存在吗。界面用它决定「复制」那一条要不要给，**迁移用它决定这一棵要不要搬**。
 * ⛔⛔ **两个通道都要问，任一说「有」就算有**：`fs.accessSync` 在外部根上不可靠（见 `nativeCopyTree` 的实测）。
 * ⭐ 代价不对称 ⇒ `||`：误报「有」无损失，误报「没有」会被静默 `continue` ⇒ 照样提交而那一棵还留在旧根。
 * ⚠️ native 那路用 `nativePathExists`（一次 `lstat`），⛔ 不是 `nativeListTree` —— 渲染期每个键调一次。 */
export function gameDataExists(dir: string): boolean {
  try {
    if (fs.accessSync(dir)) {
      return true;
    }
  } catch (e) {
    /* ⚠️ `accessSync` 本就不抛，这个 catch 只兜住极端情况（如路径非法），继续问 native。 */
  }
  try {
    if (nativePathExists(dir) !== 0) {
      /* ⭐ 两边不一致 ⇒ 记一笔：这是「ArkTS 在外部根上误报」的现场证据（hilog 读不到，也落诊断文件）。 */
      hilog.warn(DOMAIN, TAG, 'isolation: ArkTS says %{public}s is absent but native says it '
                 + 'exists -- trusting native', dir);
      return true;
    }
    return false;                  /* 两个通道都说不存在 ⇒ 才承认不存在 */
  } catch (e) {
    const err = e as BusinessError;
    /* ⚠️ native 也问不到 ⇒ **保守地当作「有」**：宁可去复制一棵空的，也不要静默跳过玩家的数据。 */
    hilog.warn(DOMAIN, TAG, 'isolation: cannot probe %{public}s on either channel (%{public}s) '
               + '-- treating it as present', dir, err.message);
    return true;
  }
}

/* 一份数据里各有多少东西 —— 给**询问窗**用（用户 2026-10-02：「必须选择确定后才能看到迁移成什么样」）。
 * ⛔⛔ 用户又说「40 个存档看着有歧义」—— 我去数了一遍，**那个 40 本身错三处**（同一台平板实测）：
 *    总条目 40、`-backup` 文件 21、非 .msav 1（steam_autocloud.vdf）⇒ 真存档 18（战役区块 15 + 手动 3）。
 * ⭐ 教训：我把「目录里的条目数」当成了「存档数」，两者差 22 个。 */
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

/** 这棵树里有没有**玩家自己放进去、游戏不会自己生成**的东西：蓝图与自制地图。
 * ⛔⛔ **不能用「目录存不存在」「有没有 settings.bin」「有没有存档」当判据**（2026-10-04 连错三次）：
 *    游戏每跑一次就写 `settings.bin` ⇒ 目录立刻「存在」；而**存档两棵树各自都会长**（实测：隔离目录 40 个
 *    `.msav`，未隔离那棵 53 KB 设置 + 27 蓝图 + 1 地图、零存档）。⭐ 蓝图/地图只有玩家会放 ⇒ 在哪棵就是他在用的。 */
export function hasUserMadeFiles(dir: string): boolean {
  if (namesIn(dir, 'schematics').filter((n: string) => n.endsWith('.msch')).length > 0) {
    return true;
  }
  return namesIn(dir, 'maps').filter((n: string) => n.endsWith('.msav')).length > 0;
}

/** 把数量说成一句人话，例如「15 个战役区块 · 3 个手动存档 · 2 个模组」。
 * ⚠️ 为 0 的那一类**不写出来**（是噪音）；⛔ 但全都为 0 时要说「空的」。 */
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

/* 递归复制**不再在这里实现** —— 已抽到 `utils/FsTree.ets`。⛔⛔ 那里记着**为什么不能用 `fs.copyDirSync`**
 * （2026-10-02 四用例实测：它在我们的沙箱里**连一个空目录都复制不了**，`Invalid argument`）。⛔ 别重抄。 */


/* 切换存储位置时要搬的**那几棵子树**（相对于根的路径）。
 * ⛔⛔ **第一版搬的是【整个根】，结果 jdk/、那些 .so、stderr.log、save-vault/ 全被复制到外置目录**
 *    （2026-10-04 用户当场看到）—— ⭐ 判据：**搬的是一个【概念】，不是一个【目录】**；加新子树**加到这里**。
 * ⚠️ 搬 `.local/share` 整层（不更深）；`instances/` 必须在列（否则静默丢隔离树）；⛔ `save-vault/` 不在列。 */
const MIGRATED_SUBTREES: string[] = ['/.local/share', '/instances'];

/* 把一次迁移失败的详情落成一个**沙箱里的小文件**，供 hdc 读走。
 * ⭐ 理由同 `dumpStorageState` 而且这里更要紧：**本应用的 hilog 读不到**，没有它时一条失败的迁移
 *   只能靠玩家照着屏幕念。⚠️ 只写不读（除排障外），而且是**追加**语义 —— 直接在调用点覆盖写。 */
function writeStorageDiag(body: string): void {
  try {
    const f: fs.File = fs.openSync(NATIVE_FILES + '/storage_migrate_error.txt',
      fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE);
    try {
      fs.writeSync(f.fd, body + '\n');
    } finally {
      fs.closeSync(f);
    }
  } catch (e) {
    /* 落不下来不该拦住任何流程 —— 与全项目其它诊断写盘同一条。 */
  }
}

/* 搬移的结果。⛔⛔ **两个通道必须分开，不能挤进一个字符串。**
 * ⭐ 2026-10-05 修的缺陷：原来只返回一个字符串，而两种**后果完全相反**的非空返回被当成同一种 ——
 *    复制阶段失败 ⇒ **没提交**（必须弹回开关、不写 `storage_mode`）；复制成功只剩残留 ⇒ **已提交**。
 *    混淆后调用方一律当「没提交」，而旧根的 `saves/` 已被删掉 ⇒ 玩家看到「存档全没了」。 */
export interface MigrateOutcome {
  /** 非空 ⇒ **没有提交**（复制阶段就失败了，源分毫未动）。调用方必须回退开关。 */
  error: string;
  /** 非空 ⇒ **已经搬成功了**，只是旧位置没删干净。⛔ **不影响提交**，只提示。 */
  warning: string;
}

/* 把游戏数据在**两个根之间搬过去**：复制成功之后把源删掉。
 * ⛔ **没有「只复制不搬」这个选项**（用户 2026-10-04：只有移动）⇒ 连参数都不给，让错的写法写不出来。
 * ⚠️ 顺序承重：**先全部复制成功，再删源**（先删一旦中途失败就是真丢数据）。
 * ⚠️ 判「成没成」**只看 `error`**，不看 `warning`；⚠️「没有数据可搬」**不算失败**；⛔ 不读 `GAME_DATA_ROOT`。 */
export function migrateGameData(fromRoot: string, toRoot: string): MigrateOutcome {
  if (fromRoot === '' || toRoot === '' || fromRoot === toRoot) {
    return { error: '', warning: '' };
  }
  /* ① 复制。逐个记成功的那几棵，**没复制成功的绝不删**。 */
  const copied: string[] = [];
  let dirs: number = 0;
  let files: number = 0;
  for (const rel of MIGRATED_SUBTREES) {
    const src: string = fromRoot + rel;
    const dst: string = toRoot + rel;
    if (!gameDataExists(src)) {
      continue;                     /* 这棵本来就没有 —— 不是错（全新安装就是这样） */
    }
    /* ⛔⛔ **跨根迁移走 native，不走 ArkTS 的 `copyTreeInto`。** 理由见 `storprobe.c`：同一文件、同一外部
     *    目标，ArkTS 的 `copyFileSync` 报 EPERM（126 个全废）而 native 裸 POSIX 拷贝成功，且
     *    `copyFileSync` 单独放进探针**又成功**（差异解释不了）⇒ 走被证明可行的那条。沙箱内部复制继续用 `copyTreeInto`。 */
    const err: string = nativeCopyTree(src, dst);
    if (err !== '') {
      hilog.error(DOMAIN, TAG, 'storage: migrating %{public}s failed: %{public}s', rel, err);
      /* ⭐ 落一个文件给 hdc 读 —— 本应用的 hilog 读不到，没有它这类失败只能靠玩家照着屏幕念。 */
      writeStorageDiag(rel + '：' + err);
      /* ⛔ 直接返回 ⇒ **连前面已经复制成功的那几棵也不删**（`move` 时更该如此）。 */
      return { error: err, warning: '' };
    }
    copied.push(rel);
  }

  /* ② 删源。⛔ **只删真的复制成功的那几棵** —— 失败的那几棵留在原地。 */
  let cleanupFailed: number = 0;
  {
    for (const rel of copied) {
      const acc: TreeStat = newTreeStat();
      removeTree(fromRoot + rel, 0, acc);
      if (acc.failed > 0) {
        /* ⚠️ 删不干净**不是**失败：新位置那份是好的。⛔⛔ 但它【不能】走 `error` 那条通道 —— 一走
         *    调用方就以为没搬成功、把开关弹回去，而这时源里的 `saves/` 可能已被删掉。
         * ⭐ 所以这里**只记一笔、继续删下一棵**，最后从 `warning` 出去。 */
        hilog.warn(DOMAIN, TAG, 'storage: could not remove %{public}s (%{public}d failure(s))',
                   fromRoot + rel, acc.failed);
        cleanupFailed += acc.failed;
      }
    }
  }

  hilog.info(DOMAIN, TAG,
             'storage: moved %{public}s -> %{public}s (%{public}s)',
             fromRoot, toRoot,
             copied.length === 0 ? 'nothing to move' : copied.join('+'));
  if (cleanupFailed > 0) {
    /* ⭐ `error` 空、`warning` 非空 = **已经搬好了**，调用方照常提交存储位置。 */
    return { error: '', warning: '已经搬到新位置了，但旧的那份没删干净（' + String(cleanupFailed)
             + ' 个文件）。可以在文件管理里手动删掉 ' + fromRoot + '，或者先不管它。' };
  }
  return { error: '', warning: '' };
}

export function copyLiveDataInto(key: string): string {
  const src: string = liveGameDataDir();
  const dst: string = isolatedGameDataDir(key);

  if (!gameDataExists(src)) {
    /* ⭐ 没有旧数据可搬 —— 这不是失败。全新安装第一次就打开隔离，走的就是这条。 */
    hilog.info(DOMAIN, TAG, 'isolation: nothing to copy (%{public}s does not exist)', src);
    return '';
  }

  /* ⛔⛔ **走 native，不走 ArkTS 的 `copyTreeInto`**（2026-10-04 改，实测）：同一文件、同一外部目标，
   *    ArkTS `copyFileSync` 报 **EPERM（126 个文件全废）** 而 native 裸 POSIX 成功。这里的目标**可能
   *    是外置文件夹** ⇒ 用 ArkTS 那条路，玩家唯一能自救的「复制过去」按钮会**当场失败**。 */
  const err: string = nativeCopyTree(src, dst);
  if (err !== '') {
    hilog.error(DOMAIN, TAG, 'isolation: copy failed %{public}s -> %{public}s: %{public}s',
                src, dst, err);
    return err;
  }
  hilog.info(DOMAIN, TAG, 'isolation: copied %{public}s -> %{public}s (via native)', src, dst);
  return '';
}
