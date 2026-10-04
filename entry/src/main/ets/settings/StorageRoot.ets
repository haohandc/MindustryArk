/* 游戏数据根在哪 —— **这一件事的唯一真相源**。
 *
 * ── 为什么要有这个文件 ──────────────────────────────────────────────────────
 * `NATIVE_FILES` 原先在四个文件里各写一遍，而**数据根一旦可切换，四处硬编码就会各自指向
 * 不同的地方**。参考项目 AMCL 的做法是把「游戏数据根」做成一个同步解析器
 * （`GameStorage.resolveMcDir(context, location)`），模块头写着「所有需要 .minecraft 根的地方
 * 都走它，不再各自硬编码」—— 本文件就是同一件事。
 *
 * ── ⛔⛔ 哪些**跟**着根走、哪些**故意不跟**（2026-10-04 定的，别去「统一」它们）────
 *
 *   | 用途                              | 跟？ | 为什么 |
 *   |-----------------------------------|------|--------|
 *   | 游戏数据（`Isolation` 的根）        | ✅ 跟 | 就是这件事本身 |
 *   | 存档垃圾站（`SaveVault`）           | ⛔ 不跟 | 它是**兜底恢复副本**：外置一旦不可用，连恢复副本也够不着就糟了 |
 *   | `ExportDiagnostics`（`crash.txt`/`stderr.log`）| ⛔ 不跟 | **诊断通道**，hdc 要按固定路径读走 |
 *   | `SafeArea`（`safearea.txt`）        | ⛔ 不跟 | 同上，异形屏数据的唯一可读通道 |
 *
 *   ⚠️ 所以「四处硬编码要统一」这个说法**已经作废**了 —— 只有一处该跟。
 *     ⛔ 判据是**「这个东西是给谁读的」**：给**游戏**读的跟着走；给**启动器自己 / hdc**
 *     读的钉在沙箱，因为它们的读者不会去外置目录找。
 *
 * ── ⭐⭐ 谁说了算：不是这里，是 native 的记录 ───────────────────────────────
 * `user.home` **只有 native 能决定**（它要 mkdir、要回退、要处理键非法），而 `launcher.c` 的
 * `record_user_home()` **早就把它实际用的那个值连同原因写了下来**：
 *
 *     /data/storage/el2/base/files/userhome_used.txt
 *       reason=off | bad-key | mkdir-failed | on
 *       home=<实际用的 user.home>
 *
 * ⭐ 所以本文件的 `gameDataRoot()` 只回答「**意图**是哪个根」，而
 *   `usedUserHome()` 读的是「**实际**用了哪个」—— 两者不一致就是「改了设置但没重启」，
 *   而那是**语义上的不一致**，不是 bug（native 在启动那一刻读桥）。
 * ⛔ **不要去让 ArkTS 独立再算一遍实际值**：那就是把 native 的回退逻辑抄一份，两份必然分叉
 *   （本项目已经在 `Isolation` 的说明里写着「三处里任何一处改了，另一处不会报错，只会让数据
 *   落到别处 —— 这是无声的」）。
 * ⭐ 那份记录**恒在沙箱**（`USERHOME_RECORD_FILE = DEST_ROOT "/userhome_used.txt"`），
 *   ⛔ **别把它挪进数据根**：外置根坏掉时，你正需要读它来知道发生了什么。
 *
 * ── 外部根为什么是 `Download/<包名>` ────────────────────────────────────────
 * ⭐ 因为这个目录**本项目已经在用**（`ModImporter.ensureModFolder` 建的模组文件夹就是它），
 *    而 AMCL 实测出一条关键性质：**用【包名】命名外部文件夹，系统会认作本应用的，
 *    从而拿到「所有权式访问」—— 跨重启有效，不需要 persist/activate**
 *    （它试过 persist/activate，在手机上报 `Operation not permitted`）。
 *    ⚠️ AMCL 早期用的是 `Download/AMCL` 这种自取名字，系统认不出来 —— 所以名字不能换。
 *
 * ⚠️ 本文件**目前只有「路径」这一半**。真正的位置切换与数据迁移还没做
 *    （计划里在它之后，因为那是要动 native 的 `user.home` 与迁移校验的大件）。
 *
 * ⭐ `probeExternalRoot()` 是那块功能的**闸门**，而且它已经**在设备上验过**：
 *    2026-10-03 在 Mate 80 Pro 上，native 用裸 POSIX 在那个目录里
 *    建文件 → 写入 → fsync → 读回比对 → 删掉，全部成功（返回 `ok`）。
 *    ⇒ 「外部存储能不能写」这个问题**已经有答案了**，不必等切换功能开工再验一次。
 * ⛔ 它返回的是**字符串**而不是布尔：`no-path` / `no-dir` / `open: errno=…` /
 *    `readback: …` / `left-behind: …` 是**五种不同处境**，处置完全不同
 *    （同 `shield.c` 文件头那条：门从来不触发，和门查了但没查到，长得一模一样）。
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

/** 外部根的候选路径；拿不到就是 `''`。
 * ⚠️ 它来自 `ModImporter` 记下的**解析后的路径**，不是 URI —— native 侧解析不了 URI。 */
export function externalRootPath(filesDir: string): string {
  try {
    return modFolderPath(filesDir + MOD_FOLDER_STATE);
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'storage: reading the external root failed (%{public}s)', err.message);
    return '';
  }
}

/** 探一次「native 能不能在外部根上写」。
 *
 * ⛔ **这就是整个存储切换功能的闸门。** 返回**字符串**，判据是它**以 `ok` 开头**；
 *    其余每一种失败都指向不同的处置，所以不能压成布尔（见 `storprobe.c` 文件头）。
 *
 * ⚠️ 探针会**真的建一个文件再删掉** —— 只 stat 一下不算，那只证明看得见。 */
export function probeExternalRoot(filesDir: string): string {
  const dir: string = externalRootPath(filesDir);
  if (dir === '') {
    /* ⚠️ 「路径还不知道」和「路径知道了但写不了」是两件事：
     * 前者多半是玩家还没建过那个文件夹（需要先跑一次 ensureModFolder）。 */
    return 'no-path: 还没有外部文件夹的路径（先运行一次 ensureModFolder）';
  }
  try {
    return storprobe.probeWritable(dir);
  } catch (e) {
    const err = e as BusinessError;
    return 'threw: ' + err.message;
  }
}

/* ====================================================================
 * 两个根：沙箱 / 外置
 * ==================================================================== */

/* ⚠️ 应用级目录的【字面路径】。ArkTS 拿不到它：`ctx.filesDir` 是 **HAP 级**的
 * `/data/storage/el2/base/haps/entry/files`，而 native 与游戏共享的是**应用级**的
 * `/data/storage/el2/base/files` —— 两个目录长得很像但不可互换，写错了 native 永远看不见，
 * 症状是「什么都没发生」。
 * ⛔ 必须与 `launcher.c` 的 `DEST_ROOT` 逐字一致。 */
export const SANDBOX_ROOT: string = '/data/storage/el2/base/files';

/** 存储位置的两种取值。字符串（不是枚举）—— 与 `LauncherPrefs` 里 launch mode 那套一致。 */
export const STORAGE_MODE_SANDBOX: string = 'sandbox';
export const STORAGE_MODE_EXTERNAL: string = 'external';

/** 记「玩家选的是哪个根」的状态文件名（放在 HAP 级 `filesDir` 里，与 `mod_folder` 同一处）。
 * ⛔ 它记的是**意图**；**实际**用了哪个由 native 记在 `userhome_used.txt`（见下面的 `usedUserHome`）。 */
const STORAGE_MODE_FILE: string = '/storage_mode';

/** native 记下的「这次启动实际用了哪个 user.home」。恒在**沙箱**里 —— 理由见文件头。 */
const USERHOME_RECORD: string = SANDBOX_ROOT + '/userhome_used.txt';

/** 读存储位置的意图。文件不在 / 读不懂 ⇒ **沙箱**（= 本项目一直以来的行为）。 */
export function readStorageMode(filesDir: string): string {
  const path: string = filesDir + STORAGE_MODE_FILE;
  try {
    if (!fs.accessSync(path)) {
      return STORAGE_MODE_SANDBOX;
    }
    const raw: string = fs.readTextSync(path).trim();
    if (raw === STORAGE_MODE_SANDBOX || raw === STORAGE_MODE_EXTERNAL) {
      return raw;
    }
    /* ⛔ 不认识的值**不静默当成另一个有效值**：记一条日志再回退（「降级默认值」会把
     * 「读错了」掩盖成「看起来正常」，本项目为此付过代价）。 */
    hilog.warn(DOMAIN, TAG,
               'storage: mode "%{public}s" is not usable -- assuming the sandbox', raw);
    return STORAGE_MODE_SANDBOX;
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'storage: reading the mode failed (%{public}s)', err.message);
    return STORAGE_MODE_SANDBOX;
  }
}

/** 写存储位置的意图。只接受两个已知值。 */
export function writeStorageMode(filesDir: string, mode: string): void {
  if (mode !== STORAGE_MODE_SANDBOX && mode !== STORAGE_MODE_EXTERNAL) {
    hilog.error(DOMAIN, TAG, 'storage: refusing to write an unknown mode "%{public}s"', mode);
    return;
  }
  const path: string = filesDir + STORAGE_MODE_FILE;
  try {
    const f: fs.File = fs.openSync(path,
      fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE);
    try {
      fs.writeSync(f.fd, mode + '\n');
    } finally {
      fs.closeSync(f);
    }
    hilog.info(DOMAIN, TAG, 'storage: mode -> %{public}s', mode);
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'storage: saving the mode failed (%{public}s)', err.message);
  }
}

/** 这一次启动 native **实际**用的 `user.home`；读不到就是 `''`。
 *
 * ⭐ 判据是 native 写的那份记录，**不是**在这里重算 —— 理由见文件头
 *   （重算就是把 native 的回退逻辑抄一份，两份必然分叉）。
 * ⚠️ 文件不存在是**正常的**：游戏从没启动过（启动器本来就能独立使用）。
 *    那时返回 `''`，调用方要说「还不知道」，⛔ 不要拿意图冒充实际。 */
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
 * ⭐ 它把「回退发生了」变成一条**能读出来的**事实 —— 否则「用了沙箱」既可能是玩家选的，
 *   也可能是好几种失败回退来的，而两者处置完全不同。 */
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
 * ⭐ 用户 2026-10-04：「外置的数据存放到 data 文件夹吧」—— 不把游戏数据直接摊在
 *    `Download/<包名>/` 的根上，让它与 `mods` 之类**并列**，一眼看得出这块是干什么的。
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

/** **意图**上的游戏数据根。
 * ⭐ 外置时 = 那个已被授权的外部文件夹（`Download/<包名>`，由 `ModImporter` 维护）+ `/data`；
 *    路径拿不到就回退沙箱 —— 与 native 的「任何失败都回退」是同一条不变量。
 * ⛔ 它**不**回答「游戏现在实际用哪个」：那是 `usedUserHome()`。 */
export function gameDataRoot(filesDir: string): string {
  return gameDataRootFor(filesDir, readStorageMode(filesDir));
}

/** 确保当前**意图**的那个根真的存在。
 *
 * ⛔⛔ **少了这一步，外置第一次用必然回退沙箱。** `launcher.c` 的 `mkdir()` 建 `instances/<键>/…`
 *    四层，但 **`mkdir` 不建父目录** ⇒ 上面那几层都建不起来，最后那层以 `ENOENT` 失败，
 *    于是按既有的不变量回退 `DEST_ROOT`、记 `reason=mkdir-failed`。
 *    ⚠️ 症状会是「切到外置、重启后又回到沙箱」，而原因藏在 native 的日志里、界面上只看到开关自己弹回去。
 * ⭐ 递归建（`mkdirSync(path, true)`）—— 那一段的父目录（`Download/<包名>`）本身可能也还没建
 *    （玩家没跑过模组那一套时）。
 * ⚠️ 失败**不拦**：native 那边还有一道 mkdir + 回退，界面上也有探针。这里尽力而为，只记日志。 */
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

/* ====================================================================
 * 给 hdc 读的那一份
 * ==================================================================== */

/** 把「意图 / 实际 / 原因」写成一个**沙箱里的小文件**。
 *
 * ⭐ **为什么要写文件，而不是打 hilog**：本应用的 hilog **读不到**（既有笔记里记过，
 *    `hdc shell hilog` 拿不到这个应用的日志）—— 而这三行是排查「数据到底落在哪」的第一问。
 * ⭐ 这不是新发明：异形屏数据走的是**同一条路**（`SafeArea.ets` 写
 *    `/data/storage/el2/base/files/safearea.txt`，就是为了让 hdc 读得到）。
 * ⛔ **只在内容变了的时候写** —— 它在 `refresh()` 里被调用，而每个渲染周期写一次文件
 *    本身就是卡顿源（本项目为「诊断工具拖慢被测对象」付过代价）。
 * @returns 写成功了没有（调用方用它决定要不要记住「已经写过这个内容」。） */
export function dumpStorageState(intent: string, used: string, reason: string): boolean {
  const body: string = 'intent=' + intent + '\n'
                     + 'used=' + used + '\n'
                     + 'reason=' + reason + '\n';
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
