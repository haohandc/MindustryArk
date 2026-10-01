/* [A]
 * 「加载哪一个游戏」—— 这个文件的唯一职责。
 *
 * 为什么它必须是运行期的
 *   自带的那份固定在 bundle 里，换一个游戏版本意味着重新构建、重新签名、再装一遍
 *   171 MB。启动器要做的是：玩家自己把若干个版本的 jar 丢进 Downloads 里本应用的
 *   那个文件夹，在界面上挑一个。于是「用哪个 jar」从一个编译期常量，变成一个每次
 *   启动都要问一次的问题。
 *
 * 为什么 jar 放在 [game] 子目录，而不是那个 Downloads 文件夹本身
 *   ⚠️ 那个文件夹是【游戏自带文件浏览器】打开的根目录（见 ModImporter.ets 的文件头）。
 *   它过去被自动扫描进模组目录，而那正是「模组删了又复活」和「存档被当成模组」的
 *   根因。扫描的代码已经删掉了，不该以任何形式回来 —— 所以游戏 jar 住进一个子目录，
 *   浏览器的根目录就不会因此变成一地的游戏包。
 *
 * 只收 .jar，不收 .zip
 *   存档就是 .zip，而这个项目正是在「.zip 被当成了别的东西」上栽过一次。收窄扩展名
 *   是一道便宜的护栏；代价只是极少数以 .zip 发布的游戏包需要玩家自己改个名。
 *
 * ⚠️ 这里是 launcher.c 的 resolve_game_jar() 的第二份副本
 *   native 那一侧要有，是因为它必须在 ArkTS 判定【之后】再确认一次（文件可能在两次
 *   检查之间被删掉）；ArkTS 这一侧要有，是因为闸门必须发生在挂载 XComponent【之前】，
 *   那一刻 native 还没跑。⚠️ **两处都要改。**
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { modFolderPath } from '../mods/ModImporter';

const DOMAIN = 0x0000;
const TAG = 'MindustryLauncher';

/** [B] 玩家选中的那个 jar 的绝对路径；一行纯文本。不存在 = 没选过。 */
const SELECTION_FILE_NAME = 'selected_game.txt';

/** [B] 「下次启动直接进启动器」的请求标记。见 consumeLauncherRequest()。 */
const LAUNCHER_MARKER_FILE_NAME = 'show_launcher';

/* [A]
 * 内置游戏在包里的路径，相对 bundleCodeDir。
 *
 * ⚠️ 结尾是 .so 而不是 .jar，这不是笔误：hvigor 只把文件名以 .so 结尾的东西从
 * entry/libs/ 拷进包，所以两个 jar 都是改过名的。见 launcher.c 的 GAME_JAR 注释。
 */
const BUNDLED_GAME_REL = '/libs/arm64/game/mindustry.so';

/** [B] 列表里的一项。够画一行就够了。 */
export interface GameJar {
  name: string;
  path: string;
  size: number;
  /** [B] Unix 秒。 */
  mtime: number;
}

/** [B] 解析结果。path 为 '' 表示【没有】任何可加载的游戏。 */
export interface GameResolution {
  path: string;
  /** [B] 'user'（玩家挑的）/ 'bundled'（包里的）/ 'none'。 */
  source: string;
}

/** [A]
 * 玩家放游戏 jar 的目录；还拿不到那个 Downloads 文件夹时为 ''。
 *
 * ⚠️ 它是从模组那个状态文件【推】出来的，而不是另立一份。那个文件夹已经是「本应用
 * 在 Downloads 里的家」，多一个状态文件就多一份会跑偏的知识 —— 本项目因为「同一件事
 * 存在两处、其中一处先跑偏」付过好几次代价。
 */
export function gameJarDir(filesDir: string): string {
  const base: string = modFolderPath(filesDir + '/mod_folder');
  if (base === '') {
    return '';
  }
  return base + '/game';
}

/** [A]
 * 确保那个子目录存在，返回它；建不出来时返回 ''。
 *
 * ⚠️ 它在平板上【可能永远建不出来】—— 平台 Download 目录的写入在那里被以 EPERM
 * 拒绝（手机则要靠 DOWNLOAD 模式 picker 的授权）。这不是错误，是本项目的既定事实，
 * 所以这里只记一条 info 并返回 ''，让上层安静地退回「只有内置游戏」。
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

/** [B] 那个目录里的 .jar，按名字排序。目录不存在时为空的。 */
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
    /* [B] 目录还没建出来是最常见的原因，而那是常态，不是问题。 */
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
      out.push({ name: name, path: path, size: st.size, mtime: st.mtime });
    } catch (e) {
      /* [B] 单个文件读不到 stat 就跳过 —— 一个列表项不值得让整个界面失败。 */
      hilog.info(DOMAIN, TAG, 'games: skipping %{public}s', name);
    }
  }
  out.sort((a: GameJar, b: GameJar): number => a.name < b.name ? -1 : (a.name > b.name ? 1 : 0));
  return out;
}

/** [A]
 * 它存在、而且头两个字节是 'PK'（一个 ZIP/jar）时为真。
 *
 * ⚠️ 只看头两个字节，不打开整包：内置游戏有 89 MB，而这是每次启动都要跑的判断。
 * 这与 launcher.c 的 is_readable_jar() 是同一个判据 —— 一次失败的 fopen 和一次
 * 成功的 fopen 都是廉价且确定的，而「是不是一个真的能用」的模组包不值得在这里判断，
 * 那由 JVM 在真正加载时报错。
 */
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
      /* [B] 关不掉一个我们马上要丢弃的句柄不值得上报。 */
    }
  }
  return ok;
}

/** [B] 内置游戏在包里的绝对路径。结尾的斜杠会被吃掉，因为 bundleCodeDir 有没有它不确定。 */
export function bundledGamePath(bundleCodeDir: string): string {
  let base: string = bundleCodeDir;
  while (base.length > 1 && base.endsWith('/')) {
    base = base.substring(0, base.length - 1);
  }
  return base + BUNDLED_GAME_REL;
}

/** [B] 玩家选中的那个 jar 的路径；没选过时为 ''。 */
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

/** [A]
 * 记下选中的 jar。传 '' 表示「退回内置的那份」—— 这是一个【明确的】选择，不是清除。
 *
 * ⚠️ 写的是【绝对路径】，不是索引或文件名。两侧对「有哪些 jar」的看法必须只有一个
 * 来源，而那个来源是 ArkTS（界面是它画的）。native 只负责打开这里写下的路径，不去
 * 自己重扫一遍目录 —— 否则玩家删掉一个文件之后，两个进程会各自看到一个不同的世界。
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

/** [A]
 * 请求「下次启动进启动器」—— 悬浮球菜单的「启动器」那一行用这个。
 *
 * 为什么需要一个标记文件而不是直接切界面：游戏的退出走的是既有的退出握手
 * （native 写 native_exit → ability 轮询到 → terminateSelf），而那条路是【销毁
 * ability】，不是重画本页。所以「回启动器」自然是「记下意图，下次启动生效」，与
 * 切换操作方案（control_mode.txt）完全同形。
 */
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

/** [A]
 * 读【并删除】那个请求标记；返回它先前是否存在。
 *
 * ⭐ 读到就删，这是本项目的铁律，不是顺手：一个只被读、不被清的标记会变成一道
 * 【永久的门】—— 玩家点了一次「启动器」，从此每次启动都停在启动器，而没有任何
 * 代码路径能把它解掉。实测踩过一次（jvm_incomplete），代价是应用每次启动都被自己
 * 拦住。
 */
export function consumeLauncherRequest(filesDir: string): boolean {
  const path: string = filesDir + '/' + LAUNCHER_MARKER_FILE_NAME;
  let present: boolean = false;
  try {
    /* [A] accessSync 【返回】一个布尔值；文件缺失时它不会抛。把它当成会抛是本项目
     * 踩过的另一个坑（见 Index.ets 的 pollImeWant）。 */
    present = fs.accessSync(path);
  } catch (e) {
    return false;
  }
  if (present) {
    try {
      fs.unlinkSync(path);
    } catch (e) {
      /* [B] 删不掉 —— 代价只是下次启动还会进启动器一次，而玩家在那里点一下「启动游戏」
       * 就继续了。绝不能让这一句挡住应用。 */
      hilog.warn(DOMAIN, TAG, 'games: could not clear the launcher marker');
    }
  }
  return present;
}

/** [A]
 * 决定这次启动用哪个 jar。**这是闸门读的那个函数。**
 *
 * 顺序：玩家选的 → 包里的 → 都没有。
 *
 * ⚠️ 两个来源都必须【真的能打开】才算数。一条记在那里、但文件已经被删掉的路径必须
 * 落回下一档，而不是让启动失败 —— 玩家删掉一个 jar 文件是常事。
 */
export function resolveGame(filesDir: string, bundleCodeDir: string): GameResolution {
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

/** [A]
 * 把这次判断的依据整个写进 hilog，每次都写。
 *
 * 为什么值得占几行日志
 *   「闸门判定没有游戏」和「我算错了内置游戏的路径」在界面上长得【一模一样】——
 *   都是启动器界面。🔶 `bundleCodeDir` 到底是不是 /data/storage/el1/bundle 目前
 *   只是推断（.d.ts 只写类型、不写值），所以第一次上设备时，这几行就是唯一的判据。
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
