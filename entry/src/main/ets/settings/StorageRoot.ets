/* 游戏数据根在哪 —— **这一件事的唯一真相源**。
 *
 * ── 为什么要有这个文件 ──────────────────────────────────────────────────────
 * 现在 `NATIVE_FILES` 在四个文件里各写一遍（`Isolation` / `SaveVault` / `ExportDiagnostics` /
 * `SafeArea`），而**数据根一旦可切换，四处硬编码就会各自指向不同的地方**。
 * 参考项目 AMCL 的做法是把「游戏数据根」做成一个同步解析器
 * （`GameStorage.resolveMcDir(context, location)`），模块头写着「所有需要 .minecraft 根的地方
 * 都走它，不再各自硬编码」—— 本文件就是同一件事。
 *
 * ⛔ **不动 `ExportDiagnostics` 与 `SafeArea` 的路径**：那两个是**诊断通道**（hdc 要读），
 *    必须钉死在沙箱。它们与「游戏数据在哪」无关，不是漏改。
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
