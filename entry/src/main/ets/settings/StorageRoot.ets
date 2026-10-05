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
 *   | 存档回收站（`SaveVault`）           | ⛔ 不跟 | 它是**兜底恢复副本**：外置一旦不可用，连恢复副本也够不着就糟了 |
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
 * ⚠️ 探针会**真的建一个文件再删掉** —— 只 stat 一下不算，那只证明看得见。
 *
 * ⛔⛔ **但它量的是【native】的能力，不是 ArkTS 的。** 2026-10-04 实测撞上了这个盲区：
 *    探针（裸 POSIX `open/write/readback/unlink`）在外部文件夹里**全部成功**，
 *    而**迁移（ArkTS 的 `fileIo.copyFileSync`）126 个文件全部 EPERM**。
 *    连目录都建出来了，只有文件写不进去。
 *    ⭐ 所以「探针过了」只说明 native 能写 —— ⛔ **不能拿它当「迁移能成功」的证据**。
 *    `probeWithinExternal()` 是为这个盲区补的第二探（见它的说明）。 */
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

/** 在**要真正落数据的那一层**（`<外部文件夹>/data`）再探一次。
 *
 * ⭐ 为什么要有第二探：迁移是把 126 个文件写进 `<外部文件夹>/data/.local/share/Mindustry/…`，
 *    而第一探只往**文件夹根**写一个文件。两者在权限上**可能不是一回事** ——
 *    「权限覆盖这个文件夹本身」与「覆盖它下面新建的子目录」是两道不同的门。
 * ⛔ 它同样只量 native。ArkTS 那边的结论只能从**迁移自己的错误**里读
 *    （那正是 `FsTree` 现在会把源与目标都打出来的原因）。 */
export function probeWithinExternal(filesDir: string): string {
  /* ⛔ **路径要直接算，不能走 `gameDataRoot()`** —— 那个跟着**玩家选的那个模式**走，
   *    于是「当前是沙箱」时这一探会去探沙箱、报 `inside-sandbox`（2026-10-04 第一版就是
   *    这么量的，白跑一轮）。⭐ 这一探量的是**文件系统**，与玩家选了什么都无关。 */
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
 *
 * ⛔ **为什么不用 `FsTree.copyTreeInto`（ArkTS 的 fileIo）**：见 `storprobe.c` 里
 *    `copyTree` 上方那段 —— 同一个文件、同一个外部目标，ArkTS 报 EPERM 而 native 成功，
 *    而把 `copyFileSync` 放进探针里单独跑**又成功**。那个差异我没解释出来（三种假设全被
 *    自己的测量推翻）⇒ **走被证明可行的那条**（native），别在解释上继续烧时间。
 * ⚠️ 它**只**用于跨根迁移；沙箱内部的复制（隔离、回收站）继续用 `FsTree.copyTreeInto`
 *    —— 那条路实测没问题，⛔ 不要顺手也换成 native（换没收益、还多一次跨语言调用）。 */
export function nativeCopyTree(src: string, dst: string): string {
  try {
    const r: string = storprobe.copyTree(src, dst);
    if (r.startsWith('ok')) {
      hilog.info(DOMAIN, TAG, 'storage: native copy %{public}s -> %{public}s (%{public}s)',
                 src, dst, r);
      return '';
    }
    /* ⛔ 原样带上 native 那句（它里面有源与目标路径 + errno）——
     *    压成「复制失败」会把**唯一的判据**丢掉。 */
    hilog.error(DOMAIN, TAG, 'storage: native copy failed %{public}s -> %{public}s: %{public}s',
                src, dst, r);
    return '复制没完成：' + r;
  } catch (e) {
    const err = e as BusinessError;
    return '复制没完成（native 调用失败）：' + err.message;
  }
}


/** 用 **native** 列一棵树（诊断用）。⛔ 返回 native 的原话，调用方别改写 ——
 *  它把「不存在」「不是目录」「截断了」分开报，压成一句话就把判据丢了。
 *  ⚠️ 与 `nativeCopyTree` 同一条理由：那个文件夹 ArkTS 侧不一定读得到，native 能。 */
export function nativeListTree(dir: string, depth: number): string {
  try {
    return storprobe.listTree(dir, depth);
  } catch (e) {
    const err = e as BusinessError;
    return 'threw: ' + err.message;
  }
}


/** 用 **native** 判一个路径存不存在（一次 `lstat`）。
 *  ⭐ 存在的理由：`fs.accessSync` **在外部根上实测会误报**（见 `Isolation.gameDataExists`
 *     那段），而 `nativeListTree` 虽然也能判，却要**列整棵树** —— 在「每个粒度键问一次」
 *     的地方（渲染期）那个代价不能接受。
 *  ⚠️ 拿不到答案时**抛出**，⛔ 不要在这里吞掉并编一个 `false`：
 *     调用方需要把「不存在」与「问不到」分开处置（见 `gameDataExists`）。 */
export function nativePathExists(path: string): number {
  return storprobe.pathExists(path);
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

/* ⭐⭐ 外置那一份**自带**的存储位置标记：`<外部文件夹>/.storage_mode`。
 *
 * ── 为什么必须有它（2026-10-05 在手机上量出来的）─────────────────────────────
 * `STORAGE_MODE_FILE` 在**沙箱**里，而沙箱**活不过一次重装/清数据**（`deploy.sh` 开头就是
 * `hdc uninstall`）。外置那份数据在用户可见的 `Download/<包名>/` 里，**活得下来**。
 * ⇒ 重装之后启动器**忘了**玩家在用外置：
 *   · 它指回沙箱（那里只剩一棵刚建的空树：`saves/` 是空的、`settings.bin` 只有几十条），
 *     于是玩家看到「我的存档全没了」——**而数据一直好好地在旁边**；
 *   · 更糟的是那时把开关拨到外置，会拿沙箱这棵几乎空的树去**盖掉**外置的 `settings.bin`
 *     （`settings.bin` 里还存着存档的显示名，见 `DataPack` 文件头）。
 * 【实测】2026-10-05 手机上就是这样：`installTime` = 10-04 21:12（一次**重装**，
 *   `firstInstallTime` 是 09-20），沙箱 `saves/` 空、`settings.bin` 28 条；
 *   外置那份有 1 个存档、27 个蓝图、1167 条 `settings.bin`（ArkTS 侧读得到，不是读不了）。
 *
 * ⭐ 判据：**一个「记住我在哪」的偏好，不能只存在它要记住的那个位置【会消失】的那一侧。**
 *   把同一件事在外置那边也记一份，代价是一个我们自己的小文件，买到的是「重装后自动认回来」。
 *
 * ⛔⛔ **不变量：这个标记存在 ⟺ 数据在外置。** 所以切回沙箱时要**删掉**它
 *   （见 `writeStorageMode`）——否则一次「外置 → 沙箱」之后它会指着一个已经被搬空的目录。
 *
 * ⚠️ **只在沙箱那份【完全没有记录】时才读它**（见 `readStorageMode`）：
 *   「玩家明确选了沙箱」（文件在、内容是 `sandbox`）与「沙箱里什么都没有」（全新安装）
 *   是**两件不同的事**，前者绝不能被这个标记翻掉。 */
const EXTERNAL_MODE_MARKER: string = '/.storage_mode';

/** native 记下的「这次启动实际用了哪个 user.home」。恒在**沙箱**里 —— 理由见文件头。 */
const USERHOME_RECORD: string = SANDBOX_ROOT + '/userhome_used.txt';

/** 读存储位置的意图。**沙箱里没有记录**时去问外置那份自带标记（见 `EXTERNAL_MODE_MARKER`）；
 *  两者都拿不到 ⇒ **沙箱**（= 本项目一直以来的行为）。 */
export function readStorageMode(filesDir: string): string {
  const path: string = filesDir + STORAGE_MODE_FILE;
  try {
    if (!fs.accessSync(path)) {
      /* ⭐ **沙箱里【完全没有记录】** —— 这是「全新安装 / 被重装清过」的样子，而它
       * **不等于**「玩家选了沙箱」（后者会把 `sandbox` 写进去）。
       * ⛔ 所以这里不能直接回退沙箱：那样就重现了 2026-10-05 那个「重装后忘了在用外置」。
       * ⚠️ 这条岔路只在**没有记录**时才走 ⇒ 稳态下是 0 次额外 IO，不是渲染期的负担。 */
      return readExternalMarker(filesDir);
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

/** 读外置那份自带标记。⛔ **只认 `external`** —— 其余（没有 / 读不懂 / 写着 `sandbox`）
 *  一律**沙箱**，与历来行为一致：宁可回到沙箱，也不要凭一个可疑的文件把玩家指到别处。 */
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
    /* ⭐ 必须**记一条**：这是「启动器为什么自己指到外置去了」的**唯一**解释
     * （本应用的 hilog 读不到，所以它进不了 storage_state.txt 就只剩猜）。 */
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
 *
 * ⭐ **外置那一份也一起维护**，不变量是「**标记存在 ⟺ 数据在外置**」：
 *   · 切到外置 ⇒ 在 `<外部文件夹>/.storage_mode` 写一份；
 *   · 切回沙箱 ⇒ **删掉**它（数据已经搬回沙箱，留着它就会指着一个被搬空的目录）。
 * ⚠️ 两处都写**不是**冗余：沙箱那份是权威、外置那份是**重装后的唯一线索**
 *   （见 `EXTERNAL_MODE_MARKER`）。⛔ 所以别「顺手统一成一份」。
 * ⚠️ 外置那份是**尽力而为**：写不了不影响任何事（沙箱那份才是判据），只记日志。 */
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
 * @param dirs **两个根下每个游戏数据目录的清单**（由 `Isolation.dumpDataDirs()` 算）。
 *   ⭐ 它存在的理由：**外置那棵树在排查里原本是不存在的** —— ArkTS 的 fileIo 在那个文件夹上
 *   不一定能读，而 `hdc shell` **连 `/storage/Users` 都看不见**（实测 `ls /storage` 只有
 *   `cloud media`）。于是「搬过去之后到底少了什么」只能靠玩家照屏幕念，而「126 个文件里少了
 *   哪几个」是念不出来的。⛔ **布局的真相源在 `Isolation`**（`instances/<键>/sets/default` 那几段），
 *   所以这份清单在那里算、这里只负责写下来。
 * @returns 写成功了没有（调用方用它决定要不要记住「已经写过这个内容」。） */
export function dumpStorageState(filesDir: string, intent: string, used: string,
                                  reason: string, stale: boolean, extra: string,
                                  dirs: string): boolean {
  /* ⭐ 顺带把**两个探针**的结论也记下来（2026-10-04 加）。
   * ⛔ 为什么必须落成文件而不是只显示在界面上：**本应用的 hilog 读不到**，
   *    而没有这两行时，「探针过了但迁移全废」只能靠玩家照屏幕念（那一轮就是这么来回的）。
   * ⚠️ 探针每次会**真的建一个文件再删掉** ⇒ 只在调用方判定「内容变了」时才走到这里
   *    （见 `LauncherHome.refresh()`），别把它变成每次渲染都跑的副作用。 */
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
                     /* ⭐ `stale` = 界面上那条「数据没搬过来」的提示有没有出现。
                      * ⛔ 它必须落在这里 —— **本应用的 hilog 读不到**，而那条提示是否出现
                      *    正是「这次是不是看起来像数据丢了」的判据（2026-10-04 那次全靠它）。 */
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
