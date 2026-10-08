/* 把一组存档在**版本之间**搬，或在**同一个版本里**复制一份。
 *
 * ⛔ 同版本复制只给**手动存档**：战役存档按文件名（`sector-<星球>-<区块>.msav`）
 *    和内容里的 `rules.sector` 认归属，复制一份就造出了游戏自己那句警告
 *    `-Sector @ has two corresponding saves: @ and @`（反编译 `mindustry.game.Saves`）。
 *    手动存档不绑定区块，多一个就是多一个。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { SaveEntry, saveBaseName } from './SaveLibrary';
import { removeTree, newTreeStat, TreeStat, pathExists, listFiles } from '../utils/FsTree';

const DOMAIN = 0x0000;
const TAG = 'MindustryLauncher';

/** 同版本复制的新名字后缀：`0` -> `0-copy`（被占就 `0-copy2`…）。 */
const COPY_SUFFIX = '-copy';

/** 一次转移的结果：'' 成功，否则是一句给玩家看的话。 */
export function transferNote(err: string): string {
  return err;
}

/** 文件名里除基名外剩下的那截（`.msav` / `.msav-backup.msav`）。 */
function suffixOf(n: string): string {
  const base: string = saveBaseName(n);
  return n.length > base.length ? n.substring(base.length) : '';
}

/* 挑一个没被占的基名：`<base>-copy`、`-copy2`…（本体与它的 `-backup` 都查）。
 * ⚠️ 单独存在的 `-backup` 会让这里选到一个已占的名字 —— 那种目录本身就是坏的，
 *    调用方另有冲突检查兜底。 */
export function uniqueCopyBase(savesDir: string, base: string): string {
  for (let i = 1; i < 100; i++) {
    const cand: string = base + COPY_SUFFIX + (i === 1 ? '' : String(i));
    if (!pathExists(savesDir + '/' + cand + '.msav')
        && !pathExists(savesDir + '/' + cand + '.msav-backup.msav')) {
      return cand;
    }
  }
  /* 一百个副本都没位置了 —— 不是现实情况，但总要给个结果。 */
  return base + COPY_SUFFIX + String(Date.now());
}

/* 复制一组文件；`rename` 时目标名由 uniqueCopyBase 给。
 * ⚠️ 任一目标名已存在 ⇒ **整体拒绝**并报出名字，⛔ 不覆盖也不跳过
 *    （覆盖 = 删掉玩家没说删的东西；跳过 = 半个存档，更难发现）。 */
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
    /* ⚠️ 结尾不写「没有动任何东西」这类话 —— 那是我们的辩解，不是玩家要的信息
     * （他要的是哪几个名字撞了），而且行为本身已经表达了它。 */
    return '目标里已经有同名的文件（' + conflicts.join('、') + '）';
  }
  /* 目标目录可能整棵都不在（那个版本从没启动过）⇒ 自己建。 */
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
      /* 复制到一半失败 ⇒ 回滚，再把话说明白。
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

/** 复制，源不动。 */
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

/** 移动 = 复制成功后删源。⚠️ 顺序不能反，见 copyGroup。 */
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

/* **同一个版本里**再复制一份（改名）。只允许手动存档（理由见文件头）。
 * ⚠️ 必须告诉玩家的后果：存档显示名在 `settings.bin` 的 `save-<索引>-name`，索引就是**文件名**
 *    ⇒ 副本在游戏里显示成 **`untitled`** —— 不是我们能修的，界面必须说出来。 */
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

/* 某个 `saves/` 里有几个存档 —— 给界面写「目标会变成什么样」用。
 * ⚠️ 只数文件名、不解压，与列表那一步同一套口径。 */
export function countSavesIn(savesDir: string): number {
  let n: number = 0;
  for (const f of listFiles(savesDir)) {
    if (f.endsWith('.msav') && !f.includes('-backup')) {
      n += 1;
    }
  }
  return n;
}