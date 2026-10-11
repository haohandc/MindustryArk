/* 版本间转移或同版本复制存档。仅手动存档可同版本复制。 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { SaveEntry, saveBaseName } from './SaveLibrary';
import { removeTree, newTreeStat, TreeStat, pathExists, listFiles } from '../utils/FsTree';

const DOMAIN = 0x0000;
const TAG = 'MindustryLauncher';

/** 副本后缀：`0` -> `0-copy`（被占就 `0-copy2`…）。 */
const COPY_SUFFIX = '-copy';

/** 返回错误信息，成功返回空字符串。 */
export function transferNote(err: string): string {
  return err;
}

/** 返回文件名中除基名外的后缀（如 `.msav`）。 */
function suffixOf(n: string): string {
  const base: string = saveBaseName(n);
  return n.length > base.length ? n.substring(base.length) : '';
}

/* 生成未占用的副本基名，检查本体与 `-backup`。 */
export function uniqueCopyBase(savesDir: string, base: string): string {
  for (let i = 1; i < 100; i++) {
    const cand: string = base + COPY_SUFFIX + (i === 1 ? '' : String(i));
    if (!pathExists(savesDir + '/' + cand + '.msav')
        && !pathExists(savesDir + '/' + cand + '.msav-backup.msav')) {
      return cand;
    }
  }
  return base + COPY_SUFFIX + String(Date.now());
}

/* 复制一组文件；`rename` 时目标名由 uniqueCopyBase 生成。遇冲突整体拒绝。 */
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
    return '目标里已经有同名的文件（' + conflicts.join('、') + '）';
  }
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

/** 复制存档，源不动。 */
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

/** 移动 = 复制后删除源。 */
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
    hilog.error(DOMAIN, TAG, 'transfer: move left %{public}d file(s) behind (%{public}s)',
                rm.failed, rm.firstError);
    return '已经搬到目标了，但原位置有 ' + String(rm.failed) + ' 个文件没删掉：' + rm.firstError;
  }
  hilog.info(DOMAIN, TAG, 'transfer: moved %{public}s (%{public}d file(s)) %{public}s -> %{public}s',
             save.label, save.files.length, fromDir, toDir);
  return '';
}

/* 同版本内复制（仅手动存档），副本在游戏中显示为 untitled。 */
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

/* 统计 `saves/` 中存档个数，仅数 `.msav` 文件（排除 `-backup`）。 */
export function countSavesIn(savesDir: string): number {
  let n: number = 0;
  for (const f of listFiles(savesDir)) {
    if (f.endsWith('.msav') && !f.includes('-backup')) {
      n += 1;
    }
  }
  return n;
}