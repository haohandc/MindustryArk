/* [A]
 * 把一组存档在**版本之间**搬，或在**同一个版本里**复制一份。
 *
 * 用户 2026-10-02：复制与移动**两者都要**。
 *
 * ⛔⛔ **一条硬约束决定了「同版本复制」只对【手动存档】开放。**
 *
 *   存档的归属是靠**文件名**推的（`sector-<星球>-<区块 id>.msav`），而游戏自己
 *   还按**内容**里的 `rules.sector` 认归属。同一份区块文件出现两次时，游戏有这句：
 *
 *       `-Sector @ has two corresponding saves: @ and @`
 *       （反编译 `mindustry.game.Saves` 的字符串常量，见路线图 §19.3）
 *
 *   ⇒ 把 `sector-serpulo-142.msav` 复制成 `sector-serpulo-142-copy.msav`，
 *     就是**亲手造出**那句警告描述的状态：一个区块两份存档。
 *     ⚠️ 而手动存档（`0.msav` 这种）没有这个牵连 —— 它不绑定任何区块，
 *     多一个就是多一个手动存档。
 *
 *   ⭐ 所以界面上的规则是：**同版本复制只给手动存档**；战役存档只能跨版本搬
 *     （那边不产生「同一版本里两份」）。⛔ 这不是省事，是让游戏别踩它自己的断言。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { SaveEntry, saveBaseName } from './SaveLibrary';
import { removeTree, newTreeStat, TreeStat, pathExists, listFiles } from '../utils/FsTree';

const DOMAIN = 0x0000;
const TAG = 'MindustryLauncher';

/** [B] 同版本复制时新名字的后缀。`0` -> `0-copy`（被占就 `0-copy2`…）。 */
const COPY_SUFFIX = '-copy';

/** [B] 一次转移的结果：'' 表示成功，否则是一句给玩家看的话。 */
export function transferNote(err: string): string {
  return err;
}

/** [B] 某组的文件里，除了基名之外剩下的那截（`.msav` / `.msav-backup.msav`）。 */
function suffixOf(n: string): string {
  const base: string = saveBaseName(n);
  return n.length > base.length ? n.substring(base.length) : '';
}

/* [A]
 * 在 `savesDir` 里挑一个没被占用的基名：`<base>-copy`、`<base>-copy2`、`<base>-copy3`…
 *
 * ⚠️ 只检查**本体**会不会撞（`<候选>.msav` 和它的 `-backup`）。
 *    万一某个 `-backup` 单独存在（本体没了），这里会选到一个已有备份的名字 ——
 *    那种目录本身就是坏的，而复制进去只会让它更坏。⇒ 调用方另有冲突检查兜底。
 */
export function uniqueCopyBase(savesDir: string, base: string): string {
  for (let i = 1; i < 100; i++) {
    const cand: string = base + COPY_SUFFIX + (i === 1 ? '' : String(i));
    if (!pathExists(savesDir + '/' + cand + '.msav')
        && !pathExists(savesDir + '/' + cand + '.msav-backup.msav')) {
      return cand;
    }
  }
  /* [B] 一百个副本都没位置了 —— 不是现实情况，但总要给个结果。 */
  return base + COPY_SUFFIX + String(Date.now());
}

/* [A]
 * 复制一组文件。`names` 是**源目录里的文件名**，`rename` 给出目标文件名（同版本复制用）。
 *
 * ⚠️ 任何一个目标名已存在 ⇒ **整体拒绝**并报出名字，⛔ 不覆盖也不跳过：
 *    · 覆盖 = 把目标那边已有的进度删掉，而玩家没说删
 *    · 跳过 = 得到一个**半个存档**，比覆盖更难发现
 *    （同一条理由在垃圾站的「放回」上也用着。）
 */
function copyGroup(srcDir: string, dstDir: string, names: string[],
                   rename: boolean, savesDirForNames: string): string {
  const pairs: string[][] = [];
  const conflicts: string[] = [];
  for (const n of names) {
    const out: string = rename ? (uniqueCopyBase(savesDirForNames, saveBaseName(n)) + suffixOf(n)) : n;
    pairs.push([n, out]);
    if (pathExists(dstDir + '/' + out)) {
      conflicts.push(out);
    }
  }
  if (conflicts.length > 0) {
    return '目标里已经有同名的文件（' + conflicts.join('、') + '），没有动任何东西。';
  }
  /* [B] 目标目录可能整棵都不在（那个版本从没启动过）⇒ 自己建。 */
  try {
    if (!pathExists(dstDir)) {
      fs.mkdirSync(dstDir, true);
    }
  } catch (e) {
    const err = e as BusinessError;
    return '建不出目标目录：' + err.message;
  }

  let done: number = 0;
  for (const p of pairs) {
    try {
      fs.copyFileSync(srcDir + '/' + p[0], dstDir + '/' + p[1]);
      done += 1;
    } catch (e) {
      const err = e as BusinessError;
      /* [A] 复制到一半失败 ⇒ **回滚**已复制过去的那几个，再把话说明白。
       * ⛔ 留一半在目标里是最坏的结果：玩家会以为搬成功了。 */
      for (const q of pairs) {
        if (pathExists(dstDir + '/' + q[1])) {
          const rb: TreeStat = newTreeStat();
          removeTree(dstDir + '/' + q[1], 0, rb);
        }
      }
      hilog.error(DOMAIN, TAG, 'transfer: copy failed after %{public}d file(s) (%{public}s)',
                  done, err.message);
      return '复制到一半失败了，已经回退：' + err.message;
    }
  }
  return '';
}

/** [A] 复制（**源不动**）。`names` 用源目录里的名字，目标用同样的名字。 */
export function copySaveTo(save: SaveEntry, fromDir: string, toDir: string): string {
  if (fromDir === toDir) {
    return '源和目标在同一个目录，没东西可搬。';
  }
  const r: string = copyGroup(fromDir, toDir, save.files, false, fromDir);
  if (r === '') {
    hilog.info(DOMAIN, TAG, 'transfer: copied %{public}s (%{public}d file(s)) %{public}s -> %{public}s',
               save.label, save.files.length, fromDir, toDir);
  }
  return r;
}

/** [A] 移动 = 复制成功后**删源**。⚠️ 顺序不能反，见 copyGroup 的说明。 */
export function moveSaveTo(save: SaveEntry, fromDir: string, toDir: string): string {
  if (fromDir === toDir) {
    return '源和目标在同一个目录，没东西可搬。';
  }
  const r: string = copySaveTo(save, fromDir, toDir);
  if (r !== '') {
    return r;
  }
  const rm: TreeStat = newTreeStat();
  for (const n of save.files) {
    const one: TreeStat = newTreeStat();
    removeTree(fromDir + '/' + n, 0, one);
    rm.files += one.files;
    rm.failed += one.failed;
    if (rm.firstError === '' && one.firstError !== '') {
      rm.firstError = one.firstError;
    }
  }
  if (rm.failed > 0) {
    /* ⚠️ 两边都有了 ⇒ 数据没丢，但**要说出来** —— 玩家的预期是「搬走了」。 */
    hilog.error(DOMAIN, TAG, 'transfer: move left %{public}d file(s) behind (%{public}s)',
                rm.failed, rm.firstError);
    return '已经搬到目标了，但原位置有 ' + String(rm.failed) + ' 个文件没删掉：' + rm.firstError;
  }
  hilog.info(DOMAIN, TAG, 'transfer: moved %{public}s (%{public}d file(s)) %{public}s -> %{public}s',
             save.label, save.files.length, fromDir, toDir);
  return '';
}

/* [A]
 * **同一个版本里**再复制一份（改名）。
 *
 * ⛔ 只允许**手动存档** —— 理由见本文件开头那条硬约束（战役存档会造出
 *    「一个区块两份存档」）。这里再挡一次：⛔ 界面挡、模块也挡，两层都要有。
 *
 * ⚠️⚠️ **一个必须告诉玩家的后果**：游戏的存档显示名**不在文件里**，而在
 *    `settings.bin` 的 `save-<索引>-name` 键上，而索引就是**文件名**。
 *    ⇒ 复制出来的那一份，游戏里会显示成 **`untitled`**，直到玩家在游戏里给它改名。
 *    ⭐ 这不是我们能修的（要从 ArkTS 写游戏的设置文件，很脆）——
 *      所以**界面必须说出来**，不能让他自己发现。
 */
export function duplicateSave(save: SaveEntry, savesDir: string): string {
  if (save.kind !== 'manual') {
    return '战役存档不能在这同一个版本里再复制一份 —— 一个区块出现两份存档，游戏会认不出来。'
         + '要备份它，请复制到别的版本。';
  }
  const r: string = copyGroup(savesDir, savesDir, save.files, true, savesDir);
  if (r === '') {
    hilog.info(DOMAIN, TAG, 'transfer: duplicated %{public}s (%{public}d file(s))',
               save.label, save.files.length);
  }
  return r;
}

/* [A]
 * 目标版本那个 `saves/` 目录里现在有几个存档 —— 给界面写「目标会变成什么样」用。
 * ⚠️ 只数文件名（不解压），与列表那一步同一套口径。
 */
export function countSavesIn(savesDir: string): number {
  let n: number = 0;
  for (const f of listFiles(savesDir)) {
    if (f.endsWith('.msav') && !f.includes('-backup')) {
      n += 1;
    }
  }
  return n;
}