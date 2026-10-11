/**
 * 游戏版本选择：ArkTS 先选 jar，Native 再确认（文件可能已删除）；
 * 选在 XComponent 挂载前完成，避免竞态。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { modFolderPath } from '../mods/ModImporter';
/** 因为 version.properties 在 ZIP 里是 raw deflate，@ohos.zlib 只给 zlib 格式，所以需要自己实现读取*/
import jarver from 'libjarver.so';

const DOMAIN = 0x0000;
const TAG = 'MindustryLauncher';

// 有跨进程需求，且读写较少，所以用txt而不是更推荐的官方API处理。
const SELECTION_FILE_NAME = 'selected_game.txt';

/** 「正在尝试启动」标记 —— ArkTS 写入（jar 路径），Native 在获取游戏入口后删除。
 * 用于捕获一种特殊失败：误选 mod 为游戏 → JVM 创建成功（jvm_incomplete 已删除），
 * 但 FindClass(主类) 失败（干净 return 1，未写 crash.txt / last-crash.txt），
 * 导致闪退且无法返回主界面。
 */
const LAUNCH_PENDING_FILE_NAME = 'launch_pending';

/** 「下次启动直接进启动器」的请求标记。见 consumeLauncherRequest()。 */
const LAUNCHER_MARKER_FILE_NAME = 'show_launcher';

const BUNDLED_GAME_REL = '/libs/arm64/game/mindustry.so';

/** JVM 在包内，路径相对于 `bundle`。
 *  两种包不带运行时：
 *    1. `SHIPS_GAME = False` 的 lite → 有 JDK 无游戏；
 *    2. `make_store_app.sh tools` 的管理工具 → JDK 和游戏均无（不跑 JVM 无需 `ALLOW_WRITABLE_CODE_MEMORY`，
 *       该 ACL 仅覆盖平板/PC，正是它能在手机上架的原因）。
 * ⚠️ 路径来自 `launcher.c` 编译期常量（`JDK_HOME`、实际 JVM 为 `libjvm_real.so`），修改须同步。 */
const BUNDLED_RUNTIME_REL = '/libs/arm64/jdk21/lib/server/libjvm_real.so';

/* `source` 的取值：'user' 玩家自选 / 'bundled' 包里自带 / 'none' 两个都不行 / 'no-runtime' **这个包不带 JVM**。
 * ⚠️ 'no-runtime' 与 'none' 是两件事（「这个包不支持跑游戏」vs「你没有游戏文件」），对玩家的处置不同。 */
/** 列表里的一项。够画一行就够了。 */
export interface GameJar {
  name: string;
  path: string;
  size: number;
  /** Unix 秒。 */
  mtime: number;
  version: string;
}

/** 解析结果。path 为 '' 表示【没有】任何可加载的游戏。 */
export interface GameResolution {
  path: string;
  /** 'user'（玩家挑的）/ 'bundled'（包里的）/ 'none'。 */
  source: string;
}

/**
 * 获取存放游戏 Jar 包的目录路径。
 *
 * @param filesDir - 应用沙箱根目录（`filesDir`），通常来自 Context。
 * @returns 游戏 Jar 包目录的完整路径。当无法获取模组文件夹路径时返回空字符串 `''`，
 *          此时调用方应视为“暂不可用”，不做任何写入/读取操作。
 *
 * @example
 * // 正常情况（filesDir = /data/storage/el2/base/haps/entry/files）
 * // 返回：/data/storage/el2/base/haps/entry/files/mod_folder/games
 */
export function gameJarDir(filesDir: string): string {
  const base: string = modFolderPath(filesDir + '/mod_folder');
  if (base === '') {
    return '';
  }
  //放在games文件夹
  return base + '/games';
}

/**确认指定路径`filesDir`的合法性。
 *
 * @param filesDir 传入一个路径
 * @returns 返回空，代表路径不存在。；返回原路径，代表路径存在
 * @throws {BusinessError} 文件创建出现系统级错误时（如权限不足、路径无效），错误信息会被记录到日志中，函数安全返回空值。
 */
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

/**
 * 列出指定应用文件目录下所有已放置的游戏 Jar 包信息。
 *
 * @param filesDir - 应用的文件根基目录（通常为 context.filesDir）。
 * @returns 升序排序后的 GameJar 数组，若目录不存在或读取失败则返回空数组。
 *
 */
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
    const err = e as BusinessError;// 应用第一次启动前文件夹不存在。
    hilog.info(DOMAIN, TAG, 'games: cannot list %{public}s (%{public}s)', dir, err.message);
    return out;
  }
  for (const name of names) {
    if (!name.toLowerCase().endsWith('.jar')) { // 统一转为小写，检测是否以jar结尾哦，减少一次对.JAR的判断。但性能开销应该差不多
      continue;
    }
    const path: string = dir + '/' + name;
    try {
      const st = fs.statSync(path); // Stat对象，“结构体”，包含文件大小，修改时间等等信息
      if (!st.isFile()) {
        continue;
      }
      out.push({ name: name, path: path, size: st.size, mtime: st.mtime,
                 version: gameVersionOf(path) });
    } catch (e) {
      hilog.info(DOMAIN, TAG, 'games: skipping %{public}s', name); // 单个文件读取不到stat就跳过
    }
  }
  out.sort((a: GameJar, b: GameJar): number => a.name < b.name ? -1 : (a.name > b.name ? 1 : 0));
  return out;
}

/** 判断文件是否为可读的 ZIP/JAR（头两字节 'PK'）。
 * 仅读取前 2 字节，以保证启动性能。
 * 与 Native 层 is_readable_jar() 判据一致。这里无需判断JAR包是否可以运行。 */
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

    }
  }
  return ok;
}

/**
 * 获取内置游戏在 HAP 包内的绝对路径。
 *
 * @param bundleCodeDir - 应用代码目录路径（可能含尾部斜杠）
 * @returns 拼接后的完整路径
 */
export function bundledGamePath(bundleCodeDir: string): string {
  const base = bundleCodeDir.replace(/\/+$/, ''); // 去除尾部斜杠
  return base + BUNDLED_GAME_REL;
}

/**
 * 从 `version.properties` 文件中提取指定键对应的字段值。
 *
 * @param text - properties 文件的完整文本内容
 * @param key  - 要查找的键名（如 "build"），函数匹配行首以该键名开头的行
 * @returns 匹配成功时返回等号右侧去除首尾空白后的值；未匹配时返回空字符串
 *
 */
function propField(text: string, key: string): string {
  const lines: string[] = text.split('\n');
  for (const raw of lines) {
    const line: string = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw; // 去掉行尾的 CR
    if (line.startsWith(key)) { // 使用这个，因为有其他的相似字符串含有相同的子串。
      return line.substring(key.length).trim();
    }
  }
  return '';
}

/**
 * 获取 Jar 文件的显示版本号。
 *
 * ⚠️ **不硬凑**：任一字段缺失时不生成形如 `v Build` 的半成品，以避免误读。
 *
 * ⚠️ **刻意不缓存**：玩家可能用新 Jar 替换同名旧文件，缓存会使界面仍显示旧版本，不易察觉。
 */
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

export interface GameVersionParts {
  number: string; // 大版本
  build: string; // 构建号
}

/**
 * 解析 Jar 包中的版本原始字段。
 *
 * @remarks
 * **返回的是原始数据字段，不是 UI 显示用的字符串。**
 * 目录名/版本隔离完全依赖此函数返回的结构化数据，
 * 调用方不得解析 `gameVersionOf(jarPath)` 的显示串来做目录名计算。
 *
 * @param jarPath - Jar 文件路径
 * @returns 包含 `number` 和 `build` 两个字段的结构化版本原始信息（字段可能为空字符串）
 */
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

/**
 * 检测包内是否包含自带游戏。
 * 注意：此函数直接判断文件是否存在且为可读的 Jar，不应通过 `resolveGame().source` 反推。
 */
export function hasBundledGame(bundleCodeDir: string): boolean {
  return isReadableJar(bundledGamePath(bundleCodeDir));
}


/**
 * 检查文件是否存在。
 *
 * 注意：
 * **不能使用 `isReadableJar` 替代此函数**（2026-10-03 的已知缺陷），
 * 因为 `isReadableJar` 会检查文件头是否为 `PK`（ZIP 格式），而 JVM 运行时是 ELF 格式
 * （以 `\x7fELF` 开头），会导致 `hasRuntime()` 恒返回 false，进而错误显示“此包不能运行游戏”，
 * 并禁用“启动游戏”按钮。游戏本体为改名的 ZIP 包，应使用 `isReadableJar` 判断。
 *
 * 注意：`fs.accessSync` 直接返回布尔值，文件不存在时不会抛出异常，因此无需 try-catch。
 */
export function fileExists(path: string): boolean {
  if (path === '') {
    return false;
  }
  return fs.accessSync(path);
}

/**
 * 检查此包是否包含运行时（自编译 JVM）。
 *
 * ⚠️ 与 `isReadableJar` 一样是**运行期文件探测**，不是编译期常量：
 * 三种形态（master/lite/tools）的 ArkTS 源码因此逐字节相同。
 *
 * @param bundleCodeDir - 包代码目录路径
 * @returns `true` 如果运行时文件存在，否则 `false`
 */
export function hasRuntime(bundleCodeDir: string): boolean {
  return fileExists(bundledRuntimePath(bundleCodeDir));
}

export function bundledRuntimePath(bundleCodeDir: string): string {
  const base = bundleCodeDir.replace(/\/+$/, ''); // 去除尾部斜杠
  return base + BUNDLED_RUNTIME_REL;
}

export function bundledGameVersion(bundleCodeDir: string): string {
  const p: string = bundledGamePath(bundleCodeDir);
  return p === '' ? '' : gameVersionOf(p);
}

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

/** 记录用户选中的游戏 Jar 文件路径。
 * 传入空字符串表示“退回内置 Jar”——这是一个明确的选定动作，而非清除选择。
 *
 * ⚠️ 写入的是绝对路径，不是索引或文件名：
 *
 * ArkTS 侧与 native 侧对“有哪些 Jar”的看法必须一致，且唯一来源为 ArkTS（UI 侧）。
 * Native 只读此文件记录的路径，不会自行扫描目录；否则若玩家删除文件，两侧将出现不一致。
 */
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

/**
 * 记录正在尝试启动的Jar文件路径。在切换到游戏树之前调用。
 * 尤其在误将Mod当作游戏选中时，此路径是唯一有诊断价值的信息。
 *
 * @param filesDir - 文件目录路径
 * @param jarPath - 待启动Jar文件的绝对路径
 */
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

/**
 * 返回上一次启动尝试的游戏 Jar 路径。
 * 返回空字符串表示没有上一次尝试（即上次正常进入游戏）。
 * 注意：本函数不会清除该记录；调用方应根据判定结果自行决定是否清除。
 */
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

/**
 * 清除上次启动尝试的标记文件。
 *
 * 此函数在两种情况下必须被调用：
 * 1. 启动时报告过一次失败之后：否则每次启动都会重弹相同的失败提示（与 consumeLauncherRequest 的读后即删行为类似）。
 * 2. 玩家从悬浮球返回启动器时：该操作会重启应用，残留的标记会被下次启动读取，导致正常退出也被误报为失败。
 *
 * 注意：正常情况下流程不会进入此函数——当成功进入游戏后，native 侧已经自行删除了该标记。
 * 此函数仅用于清除判定后留下的残留标记，防止误报。
 */
export function clearLaunchAttempt(filesDir: string): void {
  const path: string = filesDir + '/' + LAUNCH_PENDING_FILE_NAME;
  try {
    if (fs.accessSync(path)) {
      fs.unlinkSync(path);
      hilog.info(DOMAIN, TAG, 'games: cleared the launch attempt');
    }
  } catch (e) {
    /* 注意：fs.unlinkSync 在文件不存在时会抛出异常，因此先用 accessSync 检查。
     * 此处 catch 用于处理其他异常（如权限不足），删除标记失败不影响启动流程。 */
    const err = e as BusinessError;
    hilog.info(DOMAIN, TAG, 'games: clearing the attempt failed: %{public}s', err.message);
  }
}

/** 请求在下次启动时显示启动器界面。
 *
 * 此函数创建一个标记文件，用于在游戏退出后，下次启动应用时进入启动器而非直接启动游戏。
 * 由于游戏退出流程会销毁 Ability，无法直接切换界面，故采用标记文件机制，
 * 与切换操作方案（control_mode.txt）的设计思想一致。 */
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

/** 读取并删除启动器请求标记，返回标记是否已存在。
 *
 * ⚠️ 必须读取后立刻删除，否则标记将永久存在，导致每次启动都强制进入启动器，无论用户是否打开“直接进入游戏”开关。
 *   此前曾因未及时清除标记（如 jvm_incomplete 场景）导致应用被自身拦截。 */
export function consumeLauncherRequest(filesDir: string): boolean {
  const path: string = filesDir + '/' + LAUNCHER_MARKER_FILE_NAME;
  let present: boolean = false;
  try {
    /* accessSync 返回布尔值，文件不存在时不抛异常，此处不需要额外异常处理 */
    present = fs.accessSync(path);
  } catch (e) {
    return false;
  }
  if (present) {
    try {
      fs.unlinkSync(path);
    } catch (e) {
      /* 若删除失败，仅下次启动多进一次启动器，不影响正常流程 */
      hilog.warn(DOMAIN, TAG, 'games: could not clear the launcher marker');
    }
  }
  return present;
}

/** 决定本次启动使用的游戏Jar文件。
 *
 * 优先级：玩家选择 → 捆绑资源 → 无可用。
 *
 * 注意：
 * - 两个来源都必须确保文件真实可读（isReadableJar），
 *   若玩家删除了已选文件，则自动回退到下一档。
 * - 若运行时缺失（hasRuntime 为 false），则不返回任何游戏Jar，
 *   此时启动器仅作为管理工具，不参与游戏启动。
 */
export function resolveGame(filesDir: string, bundleCodeDir: string): GameResolution {
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
  /* 当运行时缺失时，不依赖玩家选择的Jar（选了也无法启动），
   * 但不清除选择记录，以便后续运行时恢复后继续生效。 */
  hilog.info(DOMAIN, TAG, 'games: no runtime in this package (form=tools?) -- '
             + 'the launcher is a management tool here, not a game launcher');
  return { path: '', source: 'no-runtime' };
}

/**
 * 输出游戏解析过程的调试日志到 hilog。
 *
 * 当 UI 显示“无可用游戏”时，可能原因有两个：
 * 1. 文件沙箱中确实没有 Jar 包；
 * 2. 内置游戏路径计算错误或 Jar 包不可读。
 *
 * @param filesDir      应用文件沙箱目录，用于计算 Jar 存放目录。
 * @param bundleCodeDir 应用内置代码目录，用于计算内置游戏路径。
 * @param r             游戏解析结果，包含最终路径和来源标识。
 */
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
