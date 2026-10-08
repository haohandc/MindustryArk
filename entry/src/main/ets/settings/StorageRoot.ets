/* 游戏数据根在哪 —— **这一件事的唯一真相源**。⚠️ 本文件目前只有「路径」这一半，切换与迁移还没做。
 * ⛔ 只有「游戏数据」（`Isolation` 的根）跟着根走；`SaveVault`（兜底恢复副本）、`ExportDiagnostics`、
 *   `SafeArea` 钉在沙箱 —— 它们的读者是启动器自己 / hdc，不会去外置找。
 * ⭐ `user.home` **只有 native 能决定**，它把实际值 + 原因写在沙箱的 `userhome_used.txt`
 *   （`reason=off|bad-key|mkdir-failed|on`）⇒ 这里只答「意图」，⛔ 不重算实际值。
 * ⭐ 外部根 = `Download/<包名>`：**用包名命名才被系统认作本应用的、拿到所有权式访问**（跨重启有效）；
 *   AMCL 实测 persist/activate 报 `Operation not permitted`，自取名字系统认不出来 ⇒ 名字不能换。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { modFolderPath } from '../mods/ModImporter';
import { fileIo as fs } from '@kit.CoreFileKit';
/* native 探针，见 cpp/storprobe.c 的文件头。 */
import storprobe from 'libstorprobe.so';

const DOMAIN = 0x0000;
const TAG = 'MindustryLauncher';

/** 模组文件夹的状态文件名（`ModImporter` 用它记下那个可被外部访问的路径）。 */
const MOD_FOLDER_STATE: string = '/mod_folder';

/** 外部根的候选路径；拿不到就是 `''`。⚠️ 来自 `ModImporter` 记下的**解析后的路径**，不是 URI（native 解析不了 URI）。 */
export function externalRootPath(filesDir: string): string {
  try {
    return modFolderPath(filesDir + MOD_FOLDER_STATE);
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'storage: reading the external root failed (%{public}s)', err.message);
    return '';
  }
}

/** 探一次「native 能不能在外部根上写」。**这是整个存储切换功能的闸门。**
 * ⛔ 返回**字符串**、判据是**以 `ok` 开头** —— 其余每种失败处置不同，不能压成布尔（见 `storprobe.c`）。
 * ⚠️ 探针**真的建一个文件再删掉**（只 stat 不算）；⛔ 但它量的是 **native** 的能力：
 *    2026-10-04 实测探针全过、而迁移（ArkTS `fileIo.copyFileSync`）**126 个文件全部 EPERM**。 */
export function probeExternalRoot(filesDir: string): string {
  const dir: string = externalRootPath(filesDir);
  if (dir === '') {
    /* ⚠️ 「路径还不知道」与「路径知道了但写不了」是两件事：多半是玩家还没跑过 ensureModFolder。 */
    return 'no-path: 还没有外部文件夹的路径（先运行一次 ensureModFolder）';
  }
  try {
    return storprobe.probeWritable(dir);
  } catch (e) {
    const err = e as BusinessError;
    return 'threw: ' + err.message;
  }
}

/** 在**要真正落数据的那一层**（`<外部文件夹>/data`）再探一次。
 * ⭐ 第二探的理由：迁移写的是 `<外部文件夹>/data/.local/share/…`，而第一探只写文件夹根 ——
 *    「权限覆盖文件夹本身」与「覆盖它下面新建的子目录」是两道不同的门。⛔ 它同样只量 native。 */
export function probeWithinExternal(filesDir: string): string {
  /* ⛔ **路径要直接算，不能走 `gameDataRoot()`** —— 那个跟着玩家选的模式走，于是「当前是沙箱」时
   *    会去探沙箱、报 `inside-sandbox`（2026-10-04 第一版就这么量的，白跑一轮）。 */
  const ext: string = externalRootPath(filesDir);
  if (ext === '') {
    return 'no-path';
  }
  try {
    return storprobe.probeWritable(ext + EXTERNAL_DATA_SUBDIR);
  } catch (e) {
    const err = e as BusinessError;
    return 'threw: ' + err.message;
  }
}

/** 用 **native** 递归复制一棵树。返回 `''` 成功，否则一句给玩家看的话。
 * ⛔ **为什么不用 ArkTS 的 `FsTree.copyTreeInto`**：见 `storprobe.c` 里 `copyTree` 上方那段 ——
 *    同一文件、同一外部目标，ArkTS 报 EPERM 而 native 成功（差异没解释出来）⇒ 走被证明可行的那条。
 * ⚠️ 沙箱内部的复制（隔离、回收站）继续用 `copyTreeInto`（实测没问题，换过来没收益、还多一次跨语言调用）。 */
export function nativeCopyTree(src: string, dst: string): string {
  try {
    const r: string = storprobe.copyTree(src, dst);
    if (r.startsWith('ok')) {
      hilog.info(DOMAIN, TAG, 'storage: native copy %{public}s -> %{public}s (%{public}s)',
                 src, dst, r);
      return '';
    }
    /* ⛔ 原样带上 native 那句（含源、目标、errno）—— 压成「复制失败」会把唯一的判据丢掉。 */
    hilog.error(DOMAIN, TAG, 'storage: native copy failed %{public}s -> %{public}s: %{public}s',
                src, dst, r);
    return '复制没完成：' + r;
  } catch (e) {
    const err = e as BusinessError;
    return '复制没完成（native 调用失败）：' + err.message;
  }
}


/** 用 **native** 列一棵树（诊断用）。⛔ 返回 native 的原话，调用方别改写 —— 它把「不存在」「不是目录」
 *  「截断了」分开报。⚠️ 同 `nativeCopyTree`：那个文件夹 ArkTS 侧不一定读得到，native 能。 */
export function nativeListTree(dir: string, depth: number): string {
  try {
    return storprobe.listTree(dir, depth);
  } catch (e) {
    const err = e as BusinessError;
    return 'threw: ' + err.message;
  }
}


/** 用 **native** 判一个路径存不存在（一次 `lstat`）。
 * ⭐ 存在的理由：`fs.accessSync` 在外部根上实测会误报，而 `nativeListTree` 要列整棵树 ——
 *    在「每个粒度键问一次」的渲染期不能接受。
 * ⚠️ 拿不到答案时**抛出**，⛔ 不吞掉编 `false`（调用方要分开「不存在」与「问不到」）。 */
export function nativePathExists(path: string): number {
  return storprobe.pathExists(path);
}


/* ===== 两个根：沙箱 / 外置 ===== */

/* ⚠️ 应用级目录的【字面路径】。ArkTS 拿不到它：`ctx.filesDir` 是 **HAP 级**的
 * `…/haps/entry/files`，而 native 与游戏共享的是**应用级**的 `…/base/files` —— 写错了 native
 * 永远看不见，症状是「什么都没发生」。⛔ 必须与 `launcher.c` 的 `DEST_ROOT` 逐字一致。 */
export const SANDBOX_ROOT: string = '/data/storage/el2/base/files';

/** 存储位置的两种取值。字符串（不是枚举）—— 与 `LauncherPrefs` 里 launch mode 那套一致。 */
export const STORAGE_MODE_SANDBOX: string = 'sandbox';
export const STORAGE_MODE_EXTERNAL: string = 'external';

/** 记「玩家选的是哪个根」的状态文件名（在 HAP 级 `filesDir` 里，与 `mod_folder` 同处）。
 * ⛔ 它记的是**意图**；**实际**用了哪个由 native 记在 `userhome_used.txt`（见 `usedUserHome`）。 */
const STORAGE_MODE_FILE: string = '/storage_mode';

/* ⭐⭐ 外置那份**自带**的存储位置标记：`<外部文件夹>/.storage_mode`。
 * 沙箱那份（`STORAGE_MODE_FILE`）**活不过一次重装/清数据**，而外置数据活得下来 ⇒ 重装后启动器会指回
 *   沙箱、看到「存档全没了」（2026-10-05 实测：沙箱 `saves/` 空、外置有 1 存档 + 1167 条 settings.bin）。
 * ⛔ 不变量：**标记存在 ⟺ 数据在外置** ⇒ 切回沙箱要删掉它；⚠️ 只在沙箱那份【完全没记录】时才读。 */
const EXTERNAL_MODE_MARKER: string = '/.storage_mode';

/** native 记下的「这次启动实际用了哪个 user.home」。恒在**沙箱**里 —— 理由见文件头。 */
const USERHOME_RECORD: string = SANDBOX_ROOT + '/userhome_used.txt';

/** 读存储位置的意图。**沙箱里没有记录**时去问外置那份自带标记（见 `EXTERNAL_MODE_MARKER`）；
 *  两者都拿不到 ⇒ **沙箱**（= 本项目一直以来的行为）。 */
export function readStorageMode(filesDir: string): string {
  const path: string = filesDir + STORAGE_MODE_FILE;
  try {
    if (!fs.accessSync(path)) {
      /* ⭐ **沙箱里【完全没有记录】** = 「全新安装 / 被重装清过」，**不等于**「玩家选了沙箱」
       * （后者会把 `sandbox` 写进去）⇒ 不能直接回退沙箱，否则重现 2026-10-05「重装后忘了在用外置」。 */
      return readExternalMarker(filesDir);
    }
    const raw: string = fs.readTextSync(path).trim();
    if (raw === STORAGE_MODE_SANDBOX || raw === STORAGE_MODE_EXTERNAL) {
      return raw;
    }
    /* ⛔ 不认识的值**不静默当成另一个有效值**：记一条日志再回退（「降级默认值」会把「读错了」掩盖成「看起来正常」）。 */
    hilog.warn(DOMAIN, TAG,
               'storage: mode "%{public}s" is not usable -- assuming the sandbox', raw);
    return STORAGE_MODE_SANDBOX;
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'storage: reading the mode failed (%{public}s)', err.message);
    return STORAGE_MODE_SANDBOX;
  }
}

/** 读外置那份自带标记。⛔ **只认 `external`**，其余（没有 / 读不懂 / 写着 `sandbox`）一律**沙箱**。 */
function readExternalMarker(filesDir: string): string {
  const ext: string = externalRootPath(filesDir);
  if (ext === '') {
    return STORAGE_MODE_SANDBOX;
  }
  const path: string = ext + EXTERNAL_MODE_MARKER;
  try {
    if (!fs.accessSync(path)) {
      return STORAGE_MODE_SANDBOX;
    }
    if (fs.readTextSync(path).trim() !== STORAGE_MODE_EXTERNAL) {
      return STORAGE_MODE_SANDBOX;
    }
    /* ⭐ 必须记一条：这是「启动器为什么自己指到外置」的**唯一**解释（本应用的 hilog 读不到）。 */
    hilog.info(DOMAIN, TAG,
               'storage: the sandbox has no record -- adopting the external marker %{public}s',
               path);
    return STORAGE_MODE_EXTERNAL;
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'storage: reading the external marker failed (%{public}s)',
               err.message);
    return STORAGE_MODE_SANDBOX;
  }
}

/** 写存储位置的意图。只接受两个已知值。
 * ⭐ **外置那一份也一起维护**：切到外置 ⇒ 写一份；切回沙箱 ⇒ **删掉**它（否则指着一个被搬空的目录）。
 * ⚠️ 两处都写**不是**冗余：沙箱那份是权威、外置那份是**重装后的唯一线索**。⛔ 别「顺手统一成一份」。
 * ⚠️ 外置那份**尽力而为**：写不了不影响任何事（沙箱那份才是判据），只记日志。 */
export function writeStorageMode(filesDir: string, mode: string): void {
  if (mode !== STORAGE_MODE_SANDBOX && mode !== STORAGE_MODE_EXTERNAL) {
    hilog.error(DOMAIN, TAG, 'storage: refusing to write an unknown mode "%{public}s"', mode);
    return;
  }
  writeOneStorageMode(filesDir + STORAGE_MODE_FILE, mode, 'mode');

  const ext: string = externalRootPath(filesDir);
  if (ext === '') {
    return;
  }
  const marker: string = ext + EXTERNAL_MODE_MARKER;
  if (mode === STORAGE_MODE_EXTERNAL) {
    writeOneStorageMode(marker, mode, 'external marker');
    return;
  }
  /* 切回沙箱：删掉标记。⚠️ `unlinkSync` **删不存在的文件会抛**（本项目记过这条）⇒ 必须包住。 */
  try {
    if (fs.accessSync(marker)) {
      fs.unlinkSync(marker);
      hilog.info(DOMAIN, TAG, 'storage: removed the external marker %{public}s', marker);
    }
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'storage: could not remove the external marker (%{public}s)',
               err.message);
  }
}

/** 往一个路径写一行模式值。`what` 只进日志（沙箱那份 / 外置那份）。 */
function writeOneStorageMode(path: string, mode: string, what: string): void {
  try {
    const f: fs.File = fs.openSync(path,
      fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE);
    try {
      fs.writeSync(f.fd, mode + '\n');
    } finally {
      fs.closeSync(f);
    }
    hilog.info(DOMAIN, TAG, 'storage: %{public}s -> %{public}s', what, mode);
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'storage: saving the %{public}s failed (%{public}s)',
               what, err.message);
  }
}

/** 这一次启动 native **实际**用的 `user.home`；读不到就是 `''`。
 * ⭐ 判据是 native 写的那份记录，**不是**在这里重算（重算 = 抄一份 native 的回退逻辑，必然分叉）。
 * ⚠️ 文件不存在是**正常的**（游戏从没启动过）：返回 `''`，调用方要说「还不知道」，
 *    ⛔ 不要拿意图冒充实际。 */
export function usedUserHome(): string {
  try {
    if (!fs.accessSync(USERHOME_RECORD)) {
      return '';
    }
    for (const line of fs.readTextSync(USERHOME_RECORD).split('\n')) {
      if (line.startsWith('home=')) {
        return line.substring(5).trim();
      }
    }
    return '';
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'storage: reading userhome_used.txt failed (%{public}s)', err.message);
    return '';
  }
}

/** native 为什么用了那一个：`off` / `bad-key` / `mkdir-failed` / `on`；读不到就是 `''`。
 * ⭐ 它把「回退发生了」变成**能读出来的**事实 —— 否则「用了沙箱」可能是玩家选的、也可能是回退来的。 */
export function usedUserHomeReason(): string {
  try {
    if (!fs.accessSync(USERHOME_RECORD)) {
      return '';
    }
    for (const line of fs.readTextSync(USERHOME_RECORD).split('\n')) {
      if (line.startsWith('reason=')) {
        return line.substring(7).trim();
      }
    }
    return '';
  } catch (e) {
    return '';
  }
}

/** 外置时游戏数据在外部文件夹底下的哪一层。
 * ⭐ 用户 2026-10-04：「外置的数据存放到 data 文件夹吧」—— 与 `mods` 等并列，一眼看得出用途。
 * ⛔ **沙箱那一侧不加这一层**：加了就是把所有人现有数据的位置挪走（那是「存档没了」）。 */
export const EXTERNAL_DATA_SUBDIR: string = '/data';

/** 某个**给定模式**对应的游戏数据根。
 * ⭐ 与 `gameDataRoot()` 分开是为了让**切换那一次**能同时拿到「从哪」和「到哪」——
 *    `gameDataRoot()` 读的是已落盘的模式，切换时那个值还是旧的。
 * ⛔ `mode` 只接受两个已知值；别的一律当沙箱（同 `readStorageMode` 的回退判据）。 */
export function gameDataRootFor(filesDir: string, mode: string): string {
  if (mode !== STORAGE_MODE_EXTERNAL) {
    return SANDBOX_ROOT;
  }
  const ext: string = externalRootPath(filesDir);
  if (ext === '') {
    return SANDBOX_ROOT;
  }
  return ext + EXTERNAL_DATA_SUBDIR;
}

/** **意图**上的游戏数据根。⛔ 它**不**回答「游戏现在实际用哪个」：那是 `usedUserHome()`。
 * ⭐ 外置时 = 那个已被授权的外部文件夹（`Download/<包名>`，由 `ModImporter` 维护）+ `/data`；
 *    路径拿不到就回退沙箱 —— 与 native 的「任何失败都回退」是同一条不变量。 */
export function gameDataRoot(filesDir: string): string {
  return gameDataRootFor(filesDir, readStorageMode(filesDir));
}

/** 确保当前**意图**的那个根真的存在。⚠️ 失败**不拦**（native 还有一道 mkdir + 回退），只记日志。
 * ⛔⛔ **少了这一步，外置第一次用必然回退沙箱。** `launcher.c` 的 `mkdir()` 建 `instances/<键>/…`
 *    四层，但 **`mkdir` 不建父目录** ⇒ 以 `ENOENT` 失败、回退 `DEST_ROOT` 记 `reason=mkdir-failed`；
 *    症状是「切到外置、重启后又回到沙箱」。⭐ 递归建（父目录 `Download/<包名>` 可能也还没建）。 */
export function ensureGameDataRoot(filesDir: string): void {
  const root: string = gameDataRoot(filesDir);
  if (root === SANDBOX_ROOT) {
    return;                        /* 沙箱一直存在，不必（也不该）在这里建 */
  }
  try {
    if (!fs.accessSync(root)) {
      fs.mkdirSync(root, true);
      hilog.info(DOMAIN, TAG, 'storage: created %{public}s', root);
    }
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'storage: could not create %{public}s (%{public}s)',
               root, err.message);
  }
}

/* ===== 给 hdc 读的那一份 ===== */

/** 把「意图 / 实际 / 原因」写成一个**沙箱里的小文件**（本应用的 hilog 读不到，而这三行是排查
 * 「数据到底落在哪」的第一问）。⛔ **只在内容变了时写** —— 它在 `refresh()` 里被调用。
 * @param dirs 两个根下每个游戏数据目录的清单（布局真相源在 `Isolation.dumpDataDirs()`；外置那棵树
 *   `hdc shell` 连 `/storage/Users` 都看不见）。@returns 写成功了没有。 */
export function dumpStorageState(filesDir: string, intent: string, used: string,
                                  reason: string, stale: boolean, extra: string,
                                  dirs: string): boolean {
  /* ⭐ 顺带把**两个探针**的结论记下来。⛔ 必须落成文件（hilog 读不到），否则「探针过了但迁移全废」
   *    只能靠玩家照屏幕念。⚠️ 探针每次真的建文件再删 ⇒ 只在调用方判定「内容变了」时才走到这里。 */
  let probes: string = '';
  try {
    probes = 'probe_root=' + probeExternalRoot(filesDir) + '\n'
           + 'probe_data=' + probeWithinExternal(filesDir) + '\n';
  } catch (e) {
    probes = 'probe_root=threw\nprobe_data=threw\n';
  }
  const body: string = 'intent=' + intent + '\n'
                     + 'used=' + used + '\n'
                     + 'reason=' + reason + '\n'
                     /* ⭐ `stale` = 界面上「数据没搬过来」那条提示有没有出现；
                      * ⛔ 必须落在这里 —— 本应用的 hilog 读不到。 */
                     + 'stale=' + String(stale) + '\n'
                     /* ⭐ 调用方拼的额外几行（自动适配的输入与结果）。⛔ 它自带换行。 */
                     + extra
                     + probes
                     + dirs;
  const path: string = SANDBOX_ROOT + '/storage_state.txt';
  try {
    const f: fs.File = fs.openSync(path,
      fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE);
    try {
      fs.writeSync(f.fd, body);
    } finally {
      fs.closeSync(f);
    }
    return true;
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'storage: writing storage_state.txt failed (%{public}s)', err.message);
    return false;
  }
}
