/* 存档回收站：删除时移到 save-vault/，布局：<id>/{meta.txt, files/} */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { SaveEntry } from './SaveLibrary';
import { copyTreeInto, removeTree, newTreeStat, TreeStat, listFiles, sizeOf, pathExists }
  from '../utils/FsTree';
import { currentGameDataRoot } from '../settings/Isolation';

const DOMAIN = 0x0000;
const TAG = 'MindustryLauncher';

const NATIVE_FILES: string = '/data/storage/el2/base/files';
export const VAULT_ROOT: string = NATIVE_FILES + '/save-vault';

const META_NAME = 'meta.txt';
const FILES_DIR = 'files';

export const VAULT_DAYS_CHOICES: number[] = [3, 7, 30];
export const VAULT_DAYS_DEFAULT: number = 7;

const DAY_MS: number = 24 * 60 * 60 * 1000;

const DAYS_FILE_NAME = 'save_vault_days.txt';

/* 回收站条目 */
export interface VaultEntry {
  id: string;
  label: string;
  from: string;
  owner: string;
  key: string;
  deletedMs: number;
  expiresMs: number;
  archived: boolean;
  count: number;
  bytes: number;
  files: string[];
}

/* ====================================================================
 * 保留期
 * ==================================================================== */

/* 读保留天数，失败/无效返回默认值 */
export function readVaultDays(filesDir: string): number {
  const path: string = filesDir + '/' + DAYS_FILE_NAME;
  try {
    if (!fs.accessSync(path)) {
      return VAULT_DAYS_DEFAULT;
    }
    const v: number = Number.parseInt(fs.readTextSync(path).trim(), 10);
    if (Number.isNaN(v) || VAULT_DAYS_CHOICES.indexOf(v) < 0) {
      hilog.warn(DOMAIN, TAG, 'vault: "%{public}d" is not one of the choices -- using the default', v);
      return VAULT_DAYS_DEFAULT;
    }
    return v;
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'vault: reading the retention failed (%{public}s)', err.message);
    return VAULT_DAYS_DEFAULT;
  }
}

/** 写保留天数，只接受三档之一 */
export function writeVaultDays(filesDir: string, days: number): void {
  if (VAULT_DAYS_CHOICES.indexOf(days) < 0) {
    hilog.error(DOMAIN, TAG, 'vault: refusing to write an unknown retention "%{public}d"', days);
    return;
  }
  try {
    const f: fs.File = fs.openSync(filesDir + '/' + DAYS_FILE_NAME,
      fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE);
    try {
      fs.writeSync(f.fd, String(days) + '\n');
    } finally {
      fs.closeSync(f);
    }
    hilog.info(DOMAIN, TAG, 'vault: retention -> %{public}d day(s)', days);
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'vault: saving the retention failed (%{public}s)', err.message);
  }
}

/* ====================================================================
 * meta.txt 键值解析
 * ==================================================================== */

/* 清除值中的换行符 */
function sanitizeValue(v: string): string {
  return v.replace(/[\r\n]+/g, ' ');
}

/* 取 meta 中指定键的值 */
function metaOf(text: string, key: string): string {
  const prefix: string = key + '=';
  const lines: string[] = text.split(String.fromCharCode(10));
  for (const raw of lines) {
    const line: string = raw.endsWith(String.fromCharCode(13))
      ? raw.substring(0, raw.length - 1) : raw;
    if (line.startsWith(prefix)) {
      return line.substring(prefix.length);
    }
  }
  return '';
}

/* 标签转目录名，最长 40 字符 */
function slug(label: string): string {
  let s: string = label.replace(/[^A-Za-z0-9._-]/g, '-');
  s = s.replace(/-+/g, '-').replace(/^-|-$/g, '');
  if (s === '') {
    s = 'save';
  }
  return s.length > 40 ? s.substring(0, 40) : s;
}

/* 删除/放回/彻底删/归档 */
export function vaultDelete(save: SaveEntry, savesDir: string, days: number, nowMs: number,
                           owner: string, key: string): string {
  if (save.files.length === 0) {
    return '这个存档里没有文件。';
  }
  /* 撞名不拒绝，加序号 */
  const stem: string = String(nowMs) + '-' + slug(save.label);
  let id: string = stem;
  let dir: string = VAULT_ROOT + '/' + id;
  for (let n: number = 2; pathExists(dir) && n < 1000; n += 1) {
    id = stem + '-' + String(n);
    dir = VAULT_ROOT + '/' + id;
  }
  if (pathExists(dir)) {
    return '回收站里这个名字已经用过太多次了，请稍后再试。';
  }
  const filesDst: string = dir + '/' + FILES_DIR;

  /* ---- ① 复制 ---- */
  const cp: TreeStat = newTreeStat();
  for (const n of save.files) {
    const acc: TreeStat = newTreeStat();
    copyOneFile(savesDir + '/' + n, filesDst + '/' + n, acc);
    cp.files += acc.files;
    cp.failed += acc.failed;
    if (cp.firstError === '' && acc.firstError !== '') {
      cp.firstError = acc.firstError;
    }
  }
  if (cp.failed > 0) {
    /* 复制失败则回滚 */
    const rb: TreeStat = newTreeStat();
    removeTree(dir, 0, rb);
    hilog.error(DOMAIN, TAG, 'vault: copy failed (%{public}s), rolled back %{public}d file(s)',
                cp.firstError, rb.files);
    return '没能复制到回收站：' + cp.firstError;
  }

  /* ---- ② 写 meta ---- */
  const expires: number = nowMs + days * DAY_MS;
  const meta: string = 'label=' + sanitizeValue(save.label) + '\n'
                     + 'from=' + sanitizeValue(savesDir) + '\n'
                     + 'owner=' + sanitizeValue(owner) + '\n'
                     + 'key=' + sanitizeValue(key) + '\n'
                     + 'deleted=' + String(nowMs) + '\n'
                     + 'expires=' + String(expires) + '\n'
                     + 'archived=0\n'
                     + 'count=' + String(save.files.length) + '\n';
  const wrote: string = writeText(dir + '/' + META_NAME, meta);
  if (wrote !== '') {
    const rb: TreeStat = newTreeStat();
    removeTree(dir, 0, rb);
    return '没能写下回收站的记录：' + wrote;
  }

  /* ---- ③ 删源 ---- */
  const rm: TreeStat = newTreeStat();
  for (const n of save.files) {
    const one: TreeStat = newTreeStat();
    removeTree(savesDir + '/' + n, 0, one);
    rm.files += one.files;
    rm.failed += one.failed;
    if (rm.firstError === '' && one.firstError !== '') {
      rm.firstError = one.firstError;
    }
  }
  if (rm.failed > 0) {
    hilog.error(DOMAIN, TAG, 'vault: source cleanup had %{public}d failure(s) (%{public}s)',
                rm.failed, rm.firstError);
    return '已经放进回收站了，但原来的文件有 ' + String(rm.failed) + ' 个没删掉：' + rm.firstError;
  }

  hilog.info(DOMAIN, TAG, 'vault: deleted %{public}s (%{public}d file(s)) -> %{public}s',
             save.label, cp.files, id);
  return '';
}

/** 复制文件，必要时建父目录 */
function copyOneFile(src: string, dst: string, acc: TreeStat): void {
  const slash: number = dst.lastIndexOf('/');
  const parent: string = slash > 0 ? dst.substring(0, slash) : dst;
  try {
    if (!pathExists(parent)) {
      fs.mkdirSync(parent, true);
    }
    fs.copyFileSync(src, dst);
    acc.files += 1;
  } catch (e) {
    const err = e as BusinessError;
    acc.failed += 1;
    if (acc.firstError === '') {
      acc.firstError = src + '：' + err.message;
    }
  }
}

/* 写文本文件，失败返回错误信息 */
function writeText(path: string, body: string): string {
  try {
    const f: fs.File = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE);
    try {
      fs.writeSync(f.fd, body);
    } finally {
      fs.closeSync(f);
    }
    return '';
  } catch (e) {
    const err = e as BusinessError;
    return err.message;
  }
}

/** 列出回收站条目，新的在前 */
export function listVault(): VaultEntry[] {
  const out: VaultEntry[] = [];
  for (const id of listFiles(VAULT_ROOT)) {
    if (!isDirName(VAULT_ROOT + '/' + id)) {
      continue;
    }
    const dir: string = VAULT_ROOT + '/' + id;
    let text: string = '';
    try {
      text = fs.readTextSync(dir + '/' + META_NAME);
    } catch (e) {
      /* 无 meta 跳过 */
      hilog.warn(DOMAIN, TAG, 'vault: %{public}s has no meta, skipped', id);
      continue;
    }
    const files: string[] = listFiles(dir + '/' + FILES_DIR);
    let bytes: number = 0;
    for (const n of files) {
      bytes += sizeOf(dir + '/' + FILES_DIR + '/' + n);
    }
    const arch: string = metaOf(text, 'archived');
    out.push({
      id: id,
      label: metaOf(text, 'label'),
      from: metaOf(text, 'from'),
      owner: metaOf(text, 'owner'),
      key: metaOf(text, 'key'),
      deletedMs: numberOrZero(metaOf(text, 'deleted')),
      expiresMs: numberOrZero(metaOf(text, 'expires')),
      archived: arch === '1',
      count: files.length,
      bytes: bytes,
      files: files,
    });
  }
  out.sort((a: VaultEntry, b: VaultEntry) => b.deletedMs - a.deletedMs);
  return out;
}

/** 解析数字，无效返回0 */
function numberOrZero(s: string): number {
  const v: number = Number.parseInt(s, 10);
  return Number.isNaN(v) ? 0 : v;
}

/** 判断是否为目录 */
function isDirName(path: string): boolean {
  try {
    return fs.statSync(path).isDirectory();
  } catch (e) {
    return false;
  }
}

/* 放回条目，目标已有同名文件则拒绝 */
export function vaultRestore(entry: VaultEntry, fallbackDir: string): string {
  const dir: string = VAULT_ROOT + '/' + entry.id;
  /* 原目录不在当前根下则用 fallback */
  const root: string = currentGameDataRoot();
  let dst: string = entry.from;
  const underCurrentRoot: boolean = dst.startsWith(root + '/');
  if (!underCurrentRoot) {
    hilog.info(0x0000, 'MindustryLauncher',
               'vault: %{public}s was deleted from %{public}s, which is not under the current root %{public}s -- restoring to %{public}s instead',
               entry.id, dst, root, fallbackDir);
    dst = fallbackDir;
  } else if (!pathExists(dst)) {
    dst = fallbackDir;
  }
  if (dst === '') {
    return '不知道要放回哪里。';
  }

  const conflicts: string[] = [];
  for (const n of entry.files) {
    if (pathExists(dst + '/' + n)) {
      conflicts.push(n);
    }
  }
  if (conflicts.length > 0) {
    return '这个存档原来的位置已经有同名文件了（' + conflicts.join('、')
         + '）。先处理掉它们再放回 —— 直接覆盖会把你后来玩的进度也删掉。';
  }

  const cp: TreeStat = newTreeStat();
  for (const n of entry.files) {
    const acc: TreeStat = newTreeStat();
    copyOneFile(dir + '/' + FILES_DIR + '/' + n, dst + '/' + n, acc);
    cp.files += acc.files;
    cp.failed += acc.failed;
    if (cp.firstError === '' && acc.firstError !== '') {
      cp.firstError = acc.firstError;
    }
  }
  if (cp.failed > 0) {
    /* 失败则回滚 */
    const rb: TreeStat = newTreeStat();
    for (const n of entry.files) {
      removeTree(dst + '/' + n, 0, rb);
    }
    hilog.error(DOMAIN, TAG, 'vault: restore failed (%{public}s), rolled back', cp.firstError);
    return '没能放回：' + cp.firstError;
  }

  /* 放回后删除条目 */
  const rm: TreeStat = newTreeStat();
  removeTree(dir, 0, rm);
  hilog.info(DOMAIN, TAG, 'vault: restored %{public}s -> %{public}s (%{public}d file(s))',
             entry.id, dst, cp.files);
  return '';
}

/** 删除条目 */
export function vaultPurge(entryId: string): string {
  const dir: string = VAULT_ROOT + '/' + entryId;
  if (!pathExists(dir)) {
    return '';
  }
  const rm: TreeStat = newTreeStat();
  removeTree(dir, 0, rm);
  if (rm.failed > 0) {
    hilog.error(DOMAIN, TAG, 'vault: purge failed (%{public}s)', rm.firstError);
    return '删除失败：' + rm.firstError;
  }
  hilog.info(DOMAIN, TAG, 'vault: purged %{public}s', entryId);
  return '';
}

/** 永久删除，不进回收站 */
export function vaultPermanentDelete(save: SaveEntry, savesDir: string): string {
  const acc: TreeStat = newTreeStat();
  for (const n of save.files) {
    const one: TreeStat = newTreeStat();
    removeTree(savesDir + '/' + n, 0, one);
    acc.files += one.files;
    acc.failed += one.failed;
    if (acc.firstError === '' && one.firstError !== '') {
      acc.firstError = one.firstError;
    }
  }
  if (acc.failed > 0) {
    hilog.error(DOMAIN, TAG, 'vault: permanent delete had %{public}d failure(s) (%{public}s)',
                acc.failed, acc.firstError);
    return '有 ' + String(acc.failed) + ' 个文件没删掉：' + acc.firstError;
  }
  hilog.info(DOMAIN, TAG, 'vault: permanently deleted %{public}d file(s)', acc.files);
  return '';
}

/** 设置归档状态 */
export function vaultSetArchived(entryId: string, archived: boolean, days: number,
                                 nowMs: number): string {
  const dir: string = VAULT_ROOT + '/' + entryId;
  const metaPath: string = dir + '/' + META_NAME;
  let text: string = '';
  try {
    text = fs.readTextSync(metaPath);
  } catch (e) {
    const err = e as BusinessError;
    return '读不到它的记录：' + err.message;
  }
  const label: string = metaOf(text, 'label');
  const from: string = metaOf(text, 'from');
  const owner: string = metaOf(text, 'owner');
  const key: string = metaOf(text, 'key');
  const deleted: string = String(numberOrZero(metaOf(text, 'deleted')));
  const count: string = String(numberOrZero(metaOf(text, 'count')));
  const expires: number = archived ? 0 : (nowMs + days * DAY_MS);
  const body: string = 'label=' + sanitizeValue(label) + '\n'
                     + 'from=' + sanitizeValue(from) + '\n'
                     + 'owner=' + sanitizeValue(owner) + '\n'
                     + 'key=' + sanitizeValue(key) + '\n'
                     + 'deleted=' + deleted + '\n'
                     + 'expires=' + String(expires) + '\n'
                     + 'archived=' + (archived ? '1' : '0') + '\n'
                     + 'count=' + count + '\n';
  const w: string = writeText(metaPath, body);
  if (w !== '') {
    return '改不了它的记录：' + w;
  }
  hilog.info(DOMAIN, TAG, 'vault: %{public}s archived=%{public}s', entryId, String(archived));
  return '';
}

/** 清除到期条目 */
export function purgeExpired(nowMs: number): number {
  let n: number = 0;
  for (const e of listVault()) {
    if (e.archived || e.expiresMs === 0) {
      continue;
    }
    if (e.expiresMs <= nowMs) {
      const r: string = vaultPurge(e.id);
      if (r === '') {
        n += 1;
      } else {
        hilog.warn(DOMAIN, TAG, 'vault: could not purge expired %{public}s (%{public}s)', e.id, r);
      }
    }
  }
  if (n > 0) {
    hilog.info(DOMAIN, TAG, 'vault: purged %{public}d expired entr(ies)', n);
  }
  return n;
}

/* ====================================================================
 * 格式化
 * ==================================================================== */

/** 到期描述 */
export function describeExpiry(e: VaultEntry, nowMs: number): string {
  if (e.archived || e.expiresMs === 0) {
    return '已归档，不会自动清理';
  }
  const left: number = e.expiresMs - nowMs;
  if (left <= 0) {
    return '已到期，下次清理时删除';
  }
  const days: number = Math.ceil(left / DAY_MS);
  return days <= 1 ? '不到 1 天后清理' : ('还有 ' + String(days) + ' 天清理');
}

/** 毫秒 -> YYYY-MM-DD HH:MM */
export function formatMs(ms: number): string {
  const d: Date = new Date(ms);
  const p = (n: number): string => n < 10 ? '0' + String(n) : String(n);
  return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate())
       + ' ' + p(d.getHours()) + ':' + p(d.getMinutes());
}