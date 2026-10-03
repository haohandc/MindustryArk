/* 「加载哪一个游戏」—— 这个文件的唯一职责。
 * 为什么必须是运行期的：自带那份固定在 bundle 里，换一个游戏版本意味着重新构建、重新签名、再装一遍
 * 171 MB ⇒ 让玩家把若干版本的 jar 丢进 Downloads 里本应用的那个文件夹，在界面上挑一个。
 * 为什么 jar 放在 [games] 子目录而不是那个 Downloads 文件夹本身：⚠️ 那个文件夹是【游戏自带文件浏览器】
 * 打开的根目录，它过去被自动扫描进模组目录，正是「模组删了又复活」和「存档被当成模组」的根因 —— 扫描
 * 代码已删不该回来。只收 .jar 不收 .zip：存档就是 .zip。
 * ⚠️ 这里是 launcher.c 的 resolve_game_jar() 的第二份副本：native 要在 ArkTS 判定【之后】再确认一次
 * （文件可能被删），ArkTS 要在挂载 XComponent【之前】判定（native 还没跑）—— **两处都要改**。 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { modFolderPath } from '../mods/ModImporter';
/* 从 jar 里读出版本号，原生实现（cpp/jarver.c）：version.properties 在 ZIP 里是 raw deflate，
 * 而 @ohos.zlib 只给 zlib 格式。 */
import jarver from 'libjarver.so';

const DOMAIN = 0x0000;
const TAG = 'MindustryLauncher';

/** 玩家选中的那个 jar 的绝对路径；一行纯文本。不存在 = 没选过。 */
const SELECTION_FILE_NAME = 'selected_game.txt';

/* 「正在尝试启动」的标记 —— 本文件【写】，native（launcher.c）拿到游戏入口方法后【删】，内容是被选中的 jar 路径。
 * ⭐ 不变量：**标记还在 ⟺ 上一次从来没走到游戏入口。** 它补的是两个现有标记都看不见的失败（2026-10-01 实测）：
 * 把 **mod 当成游戏**选了 ⇒ JVM 创建成功（已删 jvm_incomplete）、FindClass(主类) 失败（那里是【干净地 return 1】
 * 不写 crash.txt ⇒ 也没有 last-crash.txt）⇒ **一打开就闪退且没有任何办法回主界面**。 */
const LAUNCH_PENDING_FILE_NAME = 'launch_pending';

/** 「下次启动直接进启动器」的请求标记。见 consumeLauncherRequest()。 */
const LAUNCHER_MARKER_FILE_NAME = 'show_launcher';

/* 内置游戏在包里的路径，相对 bundleCodeDir。
 * ⚠️ 结尾是 .so 而不是 .jar，不是笔误：hvigor 只把文件名以 .so 结尾的东西从 entry/libs/ 拷进包，
 *    所以两个 jar 都是改过名的。见 launcher.c 的 GAME_JAR 注释。 */
const BUNDLED_GAME_REL = '/libs/arm64/game/mindustry.so';

/* 包内那份 JVM，相对 `bundleCodeDir`。
 *
 * ⭐ 为什么需要它：**有两种包不带运行时**。
 *    一种是 `SHIPS_GAME = False` 的 lite 分支（不带游戏，但**带** JDK）；
 *    另一种是 `make_store_app.sh tools` 产出的「管理工具」包
 *    —— **JDK 和游戏都不带**，因为不跑 JVM 就不需要
 *    `ALLOW_WRITABLE_CODE_MEMORY`，而那条 ACL 只覆盖平板与 PC/2in1
 *    ⇒ 那是它能在手机上架的**全部理由**（见那个脚本的文件头）。
 *
 * ⚠️ 路径里那两层名字都来自 `launcher.c` 的编译期常量
 *    （`JDK_HOME = ".../libs/arm64/jdk21"`、真正的 JVM 在 `lib/server/` 下，
 *     是 `libjvm_real.so`）。⛔ 改这里必须同时看那边 —— 两处指向同一个文件，
 *    而它们 **只有在「包齐不齐」这件事上会同时被用**。
 * ⚠️ `libjvm.so`（顶层那个）**不能**用来判：它是锚库，
 *    在一个没有 JDK 的包里它同样会缺席，但用真正的 JVM 更直白。 */
const BUNDLED_RUNTIME_REL = '/libs/arm64/jdk21/lib/server/libjvm_real.so';

/* `source` 的取值：
 *   'user'      玩家自选的那个 jar
 *   'bundled'   包内自带的那个
 *   'none'      两个都不行（真的没有游戏）
 *   'no-runtime' **这个包不带 JVM** —— 它与 'none' 是两件事：
 *               前者是「这个包不支持跑游戏」，后者是「你没有游戏文件」。
 *               分开是因为对玩家的处置不同（换包 vs 导入一个 jar）。 */
/** 列表里的一项。够画一行就够了。 */
export interface GameJar {
  name: string;
  path: string;
  size: number;
  /** Unix 秒。 */
  mtime: number;
  /* jar 里自带的游戏版本，例如 '160.5'；**读不出时是空串**。
   * ⚠️ 空串表示「不知道」，不是错误 —— 调用方显示成「未知版本」，而不是让这一行消失或整个列表失败。
   *    一份不是游戏的 jar（比如模组）正常就会走到这里，而它照样应当能被选中、被启动。 */
  version: string;
}

/** 解析结果。path 为 '' 表示【没有】任何可加载的游戏。 */
export interface GameResolution {
  path: string;
  /** 'user'（玩家挑的）/ 'bundled'（包里的）/ 'none'。 */
  source: string;
}

/* ⚠️⚠️ 那个公共文件夹在**磁盘上叫 `Download`（单数）**，不是英文惯用的 "Downloads"。两条实测判据：
 * `user_dirs.txt` 里记着 `/storage/Users/currentUser/Download/<包名>`，而
 * `Environment.getUserDownloadDir()` 返回 `/storage/Users/currentUser/Download`。
 * ⭐ 它是个会直接害到玩家的错：写复数就是叫他去找一个磁盘上不存在的文件夹 ⇒ 印给玩家看的路径一律用 `Download`。 */

/** 玩家放游戏 jar 的目录；还拿不到那个 Download 文件夹时为 ''。
 * ⚠️ 它是从模组那个状态文件【推】出来的，而不是另立一份：那个文件夹已经是「本应用在 Download
 * 里的家」，多一个状态文件就多一份会跑偏的知识。 */
export function gameJarDir(filesDir: string): string {
  const base: string = modFolderPath(filesDir + '/mod_folder');
  if (base === '') {
    return '';
  }
  /* ⭐ 子目录名是**复数**，因为它装的就是**多个** jar（自选版本这个功能的前提）。⚠️ 时机只有这一次：该目录由
   * `b4f1a2b` 引入，而那笔提交在 `v1.1.0.1` 之后 —— **没有任何已发布版本用过 `/game`**。发布后再改，用户放进
   * 旧目录的 jar 会从列表里消失，而 `selected_game.txt` 还指着旧路径 ⇒ **列表空着但游戏照常启动**。 */
  return base + '/games';
}

/** 确保那个子目录存在，返回它；建不出来时返回 ''。
 * ⚠️ 它在平板上【可能永远建不出来】—— 平台 Download 目录的写入被以 EPERM 拒绝（手机则要靠
 * DOWNLOAD 模式 picker 的授权）。这不是错误，是本项目的既定事实 ⇒ 只记一条 info 并返回 ''，
 * 让上层安静地退回「只有内置游戏」。 */
export function ensureGameJarDir(filesDir: string): string {
  const dir: string = gameJarDir(filesDir);
  if (dir === '') {
    return '';
  }
  try {
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir, true);
      hilog.info(DOMAIN, TAG, 'games: created %{public}s', dir);
    }
    return dir;
  } catch (e) {
    const err = e as BusinessError;
    hilog.info(DOMAIN, TAG, 'games: cannot create %{public}s (%{public}s)', dir, err.message);
    return '';
  }
}

/** 那个目录里的 .jar，按名字排序。目录不存在时为空的。 */
export function listGameJars(filesDir: string): GameJar[] {
  const out: GameJar[] = [];
  const dir: string = gameJarDir(filesDir);
  if (dir === '') {
    return out;
  }
  let names: string[] = [];
  try {
    names = fs.listFileSync(dir);
  } catch (e) {
    /* 目录还没建出来是最常见的原因，而那是常态，不是问题。 */
    const err = e as BusinessError;
    hilog.info(DOMAIN, TAG, 'games: cannot list %{public}s (%{public}s)', dir, err.message);
    return out;
  }
  for (const name of names) {
    if (!name.toLowerCase().endsWith('.jar')) {
      continue;
    }
    const path: string = dir + '/' + name;
    try {
      const st = fs.statSync(path);
      if (!st.isFile()) {
        continue;
      }
      out.push({ name: name, path: path, size: st.size, mtime: st.mtime,
                 version: gameVersionOf(path) });
    } catch (e) {
      /* 单个文件读不到 stat 就跳过 —— 一个列表项不值得让整个界面失败。 */
      hilog.info(DOMAIN, TAG, 'games: skipping %{public}s', name);
    }
  }
  out.sort((a: GameJar, b: GameJar): number => a.name < b.name ? -1 : (a.name > b.name ? 1 : 0));
  return out;
}

/** 它存在、而且头两个字节是 'PK'（一个 ZIP/jar）时为真。
 * ⚠️ 只看头两个字节，不打开整包：内置游戏有 89 MB，而这是每次启动都要跑的判断。与 launcher.c 的
 * is_readable_jar() 是同一个判据 ——「是不是一个真能用的包」不值得在这里判断，那由 JVM 加载时报错。 */
export function isReadableJar(path: string): boolean {
  if (path === '') {
    return false;
  }
  let file: fs.File | undefined = undefined;
  let ok: boolean = false;
  try {
    file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    const buf = new ArrayBuffer(2);
    const n: number = fs.readSync(file.fd, buf);
    if (n >= 2) {
      const b = new Uint8Array(buf);
      ok = (b[0] === 0x50 && b[1] === 0x4B);
    }
  } catch (e) {
    const err = e as BusinessError;
    hilog.info(DOMAIN, TAG, 'games: %{public}s is not readable (%{public}s)', path, err.message);
    ok = false;
  }
  if (file !== undefined) {
    try {
      fs.closeSync(file);
    } catch (e) {
      /* 关不掉一个我们马上要丢弃的句柄不值得上报。 */
    }
  }
  return ok;
}

/** 内置游戏在包里的绝对路径。结尾的斜杠会被吃掉，因为 bundleCodeDir 有没有它不确定。 */
export function bundledGamePath(bundleCodeDir: string): string {
  let base: string = bundleCodeDir;
  while (base.length > 1 && base.endsWith('/')) {
    base = base.substring(0, base.length - 1);
  }
  return base + BUNDLED_GAME_REL;
}

/* 取 `version.properties` 里某个字段的值；没有这一行时返回 ''。
 * ⚠️⚠️ **必须用「这一行是否以 key 开头」判断，不能用 indexOf / 子串搜索。** 文件里同时有 `build=`
 *    和 `buildDate=`，而 `buildDate` 就在 `build` 之后 —— 子串搜索会**先命中 `buildDate`**，
 *    版本号于是变成「September 20, 2026 13:57 PM」。同一个坑也写在 cpp/jarver.c 的对应位置。 */
function propField(text: string, key: string): string {
  const lines: string[] = text.split('\n');
  for (const raw of lines) {
    /* 去掉行尾的 CR。这个文件由 Java 的 Properties.store() 写出，在别的平台上
     * 可能带 CRLF —— 那样 "160.5\r" 会显示成结尾多一个方块。 */
    const line: string = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
    if (line.startsWith(key)) {
      return line.substring(key.length).trim();
    }
  }
  return '';
}

/* 一个 jar 的显示用版本号，形如 `v8 Build 160.5`；读不出时是【空串】。⭐ 两个字段拼起来才是完整版本
 * （用户 2026-10-01 定）：`number=8` 是**大版本**（「v8」）、`build=160.5` 是具体构建号；缺一半时只给
 * 一半，**不硬凑**（「v Build」这种半成品看起来像读成功了）。⚠️ **每次调用都真读一遍，刻意不缓存**：
 * 玩家可把新 jar 放到旧名字上（`mindustry.jar`），缓存会继续报旧版本且**从界面上完全看不出来**。 */
export function gameVersionOf(jarPath: string): string {
  const parts: GameVersionParts = gameVersionParts(jarPath);
  const number: string = parts.number;
  const build: string = parts.build;
  if (number !== '' && build !== '') {
    return 'v' + number + ' Build ' + build;
  }
  if (number !== '') {
    return 'v' + number;
  }
  if (build !== '') {
    return 'Build ' + build;
  }
  return '';
}

/** `version.properties` 里的两个原始字段。读不出时两个都是空串。 */
export interface GameVersionParts {
  /** 大版本，例如 '8'（= 玩家看到的 v8）。 */
  number: string;
  /** 构建号，例如 '160.5'；没有小版本时就是 '160'。 */
  build: string;
}

/* 原始字段，**不是**给眼睛看的那种。版本隔离要靠它算目录名。
 * ⚠️⚠️ 不让调用方解析 `gameVersionOf()` 的显示串：那个串格式随界面需要而变，而**目录名是用户数据的一部分**
 *    —— 格式一改老目录名就再也解析不出来，而无法在升级时批量改名 ⇒ 显示归显示、数据归数据。
 * ⚠️ `build` 用原样字符串（'160.5' 就是 '160.5'）：`Version.buildString()` = `build + (revision == 0 ? "" : "." + revision)`，**不要补 '.0'**。 */
export function gameVersionParts(jarPath: string): GameVersionParts {
  const none: GameVersionParts = { number: '', build: '' };
  if (!isReadableJar(jarPath)) {
    return none;
  }
  let text: string = '';
  try {
    text = jarver.jarVersionText(jarPath);
  } catch (e) {
    const err = e as BusinessError;
    hilog.info(DOMAIN, TAG, 'games: jarVersionText(%{public}s) failed (%{public}s)', jarPath, err.message);
    return none;
  }
  if (text === '') {
    return none;
  }
  return { number: propField(text, 'number='), build: propField(text, 'build=') };
}

/** 包内那份自带游戏的版本号；没有包内游戏、或读不出时是空串。 */
/* 包内那份自带游戏到底**在不在**。⚠️⚠️ `resolveGame().source` 回答的是「这次会加载哪个**来源**」，不是
 * 「内置那份在不在」—— 玩家一旦选中自己的 jar，`source` 就是 `'user'`，而内置那份**照样在**。
 * ⛔ 以前写错过：界面上用 `source === 'bundled'` 去判「内置游戏：有/无」，于是玩家一选自己的 jar 那一行
 *    就说「无」—— 同一个词（source）指了两件事。⇒ 问「在不在」就直接问文件，别反推。 */
export function hasBundledGame(bundleCodeDir: string): boolean {
  return isReadableJar(bundledGamePath(bundleCodeDir));
}

/** 这个包里**带不带运行时**（那份自编译的 JVM）。
 *
 * ⭐⭐ 与 `isReadableJar` 同样，是**运行期文件探测**，**不是编译期常量**。
 *    这一点是刻意的、也是承重的：三种形态（master / lite / tools）的
 *    ArkTS 源码因此**可以逐字节相同**，差异只体现在「包里有什么」——
 *    与 `SHIPS_GAME` 那套既有设计完全一致。
 *
 * ⛔ **为什么必须问它，而不是只问「有没有游戏」**：
 *    `resolveGame()` 是两级的 —— 先看**玩家自选**的 jar，再看包里的。
 *    只判「包里有没有游戏」的话，一个**没有运行时**的包里只要玩家
 *    导入并选中了自己的 jar，`resolveGame` 就会乐呵呵地返回那个路径，
 *    启动器显示「启动游戏」，按下去却什么都不发生（`launcher.c` 在
 *    `start_jvm` 里找不到 JVM 就直接返回）。
 *    ⇒ 那是「点了没反应」，最难查的一种失败。
 *
 * ⚠️ 判据取**真正的 JVM**（`libjvm_real.so`），不是顶层那个锚库 `libjvm.so`：
 *    两者在有运行时的包里都在、在没有的包里都不在，但前者是「能不能起 JVM」
 *    的直接回答，后者只是加载链上的一环。 */
export function hasRuntime(bundleCodeDir: string): boolean {
  return isReadableJar(bundledRuntimePath(bundleCodeDir));
}

/** 包内那份 JVM 的绝对路径。⚠️ 结尾斜杠会被吃掉，同 `bundledGamePath`。 */
export function bundledRuntimePath(bundleCodeDir: string): string {
  let base: string = bundleCodeDir;
  while (base.length > 1 && base.endsWith('/')) {
    base = base.substring(0, base.length - 1);
  }
  return base + BUNDLED_RUNTIME_REL;
}

export function bundledGameVersion(bundleCodeDir: string): string {
  const p: string = bundledGamePath(bundleCodeDir);
  return p === '' ? '' : gameVersionOf(p);
}

/** 玩家选中的那个 jar 的路径；没选过时为 ''。 */
export function readSelection(filesDir: string): string {
  const path: string = filesDir + '/' + SELECTION_FILE_NAME;
  try {
    if (!fs.accessSync(path)) {
      return '';
    }
    return fs.readTextSync(path).trim();
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'games: reading the selection failed: %{public}s', err.message);
    return '';
  }
}

/** 记下选中的 jar。传 '' 表示「退回内置的那份」—— 这是一个【明确的】选择，不是清除。
 * ⚠️ 写的是【绝对路径】，不是索引或文件名：两侧对「有哪些 jar」的看法必须只有一个来源，而那个
 *    来源是 ArkTS（界面是它画的）—— native 只打开这里写下的路径，不自己重扫目录，否则玩家删掉
 *    一个文件后两个进程会各自看到一个不同的世界。 */
export function writeSelection(filesDir: string, jarPath: string): void {
  const path: string = filesDir + '/' + SELECTION_FILE_NAME;
  try {
    const f: fs.File = fs.openSync(path,
      fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE);
    try {
      fs.writeSync(f.fd, jarPath + '\n');
    } finally {
      fs.closeSync(f);
    }
    hilog.info(DOMAIN, TAG, 'games: selection -> %{public}s', jarPath === '' ? '(bundled)' : jarPath);
  } catch (e) {
    const err = e as BusinessError;
    hilog.error(DOMAIN, TAG, 'games: writing the selection failed: %{public}s', err.message);
  }
}

/** 记下「正在尝试启动这个 jar」。在切到游戏树【之前】调用。
 * 把 jar 路径写进去，是为了失败时能告诉玩家**是哪一个** jar 没起来 —— 那正是「把 mod 当游戏选了」
 * 这种情形里唯一有诊断价值的信息。 */
export function markLaunchAttempt(filesDir: string, jarPath: string): void {
  const path: string = filesDir + '/' + LAUNCH_PENDING_FILE_NAME;
  try {
    const f: fs.File = fs.openSync(path,
      fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE);
    try {
      fs.writeSync(f.fd, jarPath + '\n');
    } finally {
      fs.closeSync(f);
    }
    hilog.info(DOMAIN, TAG, 'games: launch attempt -> %{public}s', jarPath);
  } catch (e) {
    const err = e as BusinessError;
    hilog.error(DOMAIN, TAG, 'games: marking the attempt failed: %{public}s', err.message);
  }
}

/** 上一次的启动尝试，'' 表示没有 —— 也就是上一次确实走到了游戏入口。
 * ⚠️ 它【不清除】：清除由调用方在决定怎么处理之后自己做，因为「读到之后要不要留」取决于判定结果。 */
export function pendingLaunchAttempt(filesDir: string): string {
  const path: string = filesDir + '/' + LAUNCH_PENDING_FILE_NAME;
  try {
    if (!fs.accessSync(path)) {
      return '';
    }
    return fs.readTextSync(path).trim();
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'games: reading the pending attempt failed: %{public}s', err.message);
    return '';
  }
}

/** 清掉那个标记。⚠️ 两个调用点都必要：启动时【报过一次失败之后】（否则每次启动都会再弹一次同样的
 * 窗，与 consumeLauncherRequest 的读后即删同形）；玩家从悬浮球回到启动器时（那条路会重启应用，
 * 标记会被下次启动读到，于是「刚才明明玩得好好的」也会被报成失败）。
 * ⚠️ 正常情况下【轮不到这里】清：走到游戏入口时 native 已经删了；这里清的是判定之后的残留。 */
export function clearLaunchAttempt(filesDir: string): void {
  const path: string = filesDir + '/' + LAUNCH_PENDING_FILE_NAME;
  try {
    if (fs.accessSync(path)) {
      fs.unlinkSync(path);
      hilog.info(DOMAIN, TAG, 'games: cleared the launch attempt');
    }
  } catch (e) {
    /* ⚠️ fs.unlinkSync 删不存在的文件会【抛】——所以上面先 accessSync 探一下。
     * 这里的 catch 兜的是别的失败（权限等），而删不掉一个标记不足以让启动失败。 */
    const err = e as BusinessError;
    hilog.info(DOMAIN, TAG, 'games: clearing the attempt failed: %{public}s', err.message);
  }
}

/** 请求「下次启动进启动器」—— 悬浮球菜单的「启动器」那一行用这个。
 * 为什么需要标记文件而不直接切界面：游戏退出走的是既有的退出握手（native 写 native_exit →
 * ability 轮询到 → terminateSelf），那条路是【销毁 ability】不是重画本页 ⇒「回启动器」自然是
 * 「记下意图，下次启动生效」，与切换操作方案（control_mode.txt）完全同形。 */
export function requestLauncher(filesDir: string): void {
  const path: string = filesDir + '/' + LAUNCHER_MARKER_FILE_NAME;
  try {
    const f: fs.File = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE);
    fs.closeSync(f);
    hilog.info(DOMAIN, TAG, 'games: launcher requested for the next start');
  } catch (e) {
    const err = e as BusinessError;
    hilog.error(DOMAIN, TAG, 'games: cannot request the launcher: %{public}s', err.message);
  }
}

/** 读【并删除】那个请求标记；返回它先前是否存在。
 * ⭐ 读到就删，这是本项目的铁律，不是顺手：一个只被读、不被清的标记会变成一道【永久的门】——
 * 玩家点了一次「启动器」就从此每次启动都停在启动器，而没有任何代码路径能把它解掉。实测踩过一次
 * （jvm_incomplete），代价是应用每次启动都被自己拦住。 */
export function consumeLauncherRequest(filesDir: string): boolean {
  const path: string = filesDir + '/' + LAUNCHER_MARKER_FILE_NAME;
  let present: boolean = false;
  try {
    /* accessSync 【返回】一个布尔值；文件缺失时它不会抛。把它当成会抛是本项目
     * 踩过的另一个坑（见 Index.ets 的 pollImeWant）。 */
    present = fs.accessSync(path);
  } catch (e) {
    return false;
  }
  if (present) {
    try {
      fs.unlinkSync(path);
    } catch (e) {
      /* 删不掉 —— 代价只是下次启动还会进启动器一次，而玩家在那里点一下「启动游戏」
       * 就继续了。绝不能让这一句挡住应用。 */
      hilog.warn(DOMAIN, TAG, 'games: could not clear the launcher marker');
    }
  }
  return present;
}

/** 决定这次启动用哪个 jar。**这是闸门读的那个函数。** 顺序：玩家选的 → 包里的 → 都没有。
 * ⚠️ 两个来源都必须【真的能打开】才算数：一条记在那里但文件已被删掉的路径必须落回下一档，
 *    而不是让启动失败 —— 玩家删掉一个 jar 文件是常事。 */
export function resolveGame(filesDir: string, bundleCodeDir: string): GameResolution {
  /* ⭐⭐ **先问运行时在不在，再谈选哪个 jar。**
   * ⛔ 这一行是后补的，而它补的是一个真缺口：`resolveGame` 原本只看
   *    「哪个 jar 可读」，完全不问包里的 JVM 在不在。于是**没有运行时的包**
   *    （`make_store_app.sh tools` ⇒ 管理工具形态）里，只要玩家导入并选中
   *    自己的 jar，它就会返回 `source: 'user'` ⇒ 界面显示「启动游戏」
   *    ⇒ 按下去什么都不发生（`launcher.c` 的 `start_jvm` 找不到 JVM 直接返回）。
   *    ⇒ 一个**点了没反应**的按钮，比一个**明确不可用**的按钮糟得多。
   * ⚠️ 它**不**改动 `hasBundledGame()` 的语义，也不影响 master/lite：
   *    那两个形态的包里都有运行时，这一行恒为真。 */
  const runtime: boolean = hasRuntime(bundleCodeDir);
  if (runtime) {
    const chosen: string = readSelection(filesDir);
    if (chosen !== '' && isReadableJar(chosen)) {
      return { path: chosen, source: 'user' };
    }
    if (chosen !== '') {
      hilog.warn(DOMAIN, TAG, 'games: the chosen jar is gone, falling back: %{public}s', chosen);
    }
    const bundled: string = bundledGamePath(bundleCodeDir);
    if (isReadableJar(bundled)) {
      return { path: bundled, source: 'bundled' };
    }
    return { path: '', source: 'none' };
  }
  /* 没有运行时。❗ 这里**不再看玩家选的 jar** —— 选了也跑不起来。
   * ⚠️ 也不清 `selected_game.txt`：那个文件属于玩家，而且将来换回带运行时的
   *    包时它应该还有效。只是在**这个**包里它不构成「可以启动」。 */
  hilog.info(DOMAIN, TAG, 'games: no runtime in this package (form=tools?) -- '
             + 'the launcher is a management tool here, not a game launcher');
  return { path: '', source: 'no-runtime' };
}

/** 把这次判断的依据整个写进 hilog，每次都写。
 * 「闸门判定没有游戏」和「我算错了内置游戏的路径」在界面上长得【一模一样】—— 都是启动器界面。
 * 🔶 `bundleCodeDir` 到底是不是 /data/storage/el1/bundle 目前只是推断（.d.ts 只写类型、不写值），
 * 所以第一次上设备时，这几行就是唯一的判据。 */
export function reportGameResolution(filesDir: string, bundleCodeDir: string,
                                     r: GameResolution): void {
  hilog.info(DOMAIN, TAG, 'games: bundleCodeDir=%{public}s', bundleCodeDir);
  hilog.info(DOMAIN, TAG, 'games: jar dir=%{public}s',
             gameJarDir(filesDir) === '' ? '(not available)' : gameJarDir(filesDir));
  hilog.info(DOMAIN, TAG, 'games: bundled=%{public}s readable=%{public}s',
             bundledGamePath(bundleCodeDir), String(isReadableJar(bundledGamePath(bundleCodeDir))));
  hilog.info(DOMAIN, TAG, 'games: resolved=%{public}s source=%{public}s',
             r.path === '' ? '(none)' : r.path, r.source);
}
