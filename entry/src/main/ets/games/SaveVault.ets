/* [A]
 * 存档垃圾站 —— 删除**不是**抹掉，是搬到一个游戏看不见的地方。
 *
 * 用户 2026-10-02 定的形态：
 *   「删除加上垃圾站，防止误删除，可以找回。然后可以自选保留时间（3天/7天/1个月）
 *     还可以加上归档，存档归档。」
 *
 * ⭐⭐ **存放位置是整个设计的关键**：`DEST_ROOT/save-vault/` ——
 *    **在游戏那棵树【外面】**（`…/files/.local/share/Mindustry/` 之外）。
 *
 *    ⛔ 若放在游戏的数据目录里（比如 `saves/` 旁边），两件事会同时坏：
 *      ① 游戏会把它当成自己的数据去扫（`Saves` 会把 `.msav` 都列出来）；
 *      ② 隔离一开，`user.home` 一换，垃圾站就**跟着版本走**了 ——
 *         而玩家的预期显然是「我删掉的东西在同一个地方找回来」。
 *    ⇒ 放在 level-2 的应用目录下，它**天然跨版本共享**，也不需要任何隔离逻辑。
 *
 * 目录布局：
 *
 *     <DEST_ROOT>/save-vault/
 *       <条目 id>/
 *         meta.txt        ← 人可读的说明（键值对，与 isolation.txt 同一套约定）
 *         files/          ← 原样搬过来的 msav（含 `-backup`。⛔ 不筛，见下）
 *
 * ⚠️ id 用 `<时间戳>-<安全化的标签>`：时间戳保证唯一，标签保证**人能认出是哪个**。
 *    标签里的非法字符会被替换 —— 它会进路径，而路径是从**玩家给的存档名**派生出来的。
 *
 * ⛔ **不挑文件**：一组存档的 `files[]` 原样全搬（含 `-backup`）。
 *    筛掉备份会让「放回去」得到一个**与删除前不同**的存档，而玩家要的是撤销。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { SaveEntry } from './SaveLibrary';
import { copyTreeInto, removeTree, newTreeStat, TreeStat, listFiles, sizeOf, pathExists }
  from '../utils/FsTree';

const DOMAIN = 0x0000;
const TAG = 'MindustryLauncher';

/* [A] 垃圾站的根。⭐ `NATIVE_FILES` 与 `Isolation.ets` 里那个是同一个值 ——
 * 都必须是 native 侧的应用级目录（`launcher.c` 的 `DEST_ROOT`），
 * ⛔ 不是 ArkTS 的 `ctx.filesDir`（那是 HAP 级目录，两处不通用）。 */
const NATIVE_FILES: string = '/data/storage/el2/base/files';
export const VAULT_ROOT: string = NATIVE_FILES + '/save-vault';

/** [B] 一个条目里的元数据文件名。 */
const META_NAME = 'meta.txt';
/** [B] 搬过来的存档文件放这一层 —— 与 meta.txt 分开，读目录时不会把 meta 当存档。 */
const FILES_DIR = 'files';

/** [B] 保留期的选项（天）。用户点名要的三档。 */
export const VAULT_DAYS_CHOICES: number[] = [3, 7, 30];
/** [B] 出厂值 7 天 —— 中间那档，也是三档里最不容易让人后悔的。 */
export const VAULT_DAYS_DEFAULT: number = 7;

const DAY_MS: number = 24 * 60 * 60 * 1000;

/** [B] 保留期存哪。与别的跨启动状态一样，一个纯文本文件。 */
const DAYS_FILE_NAME = 'save_vault_days.txt';

/** [B] 垃圾站里的一个条目。 */
export interface VaultEntry {
  /** [B] 目录名，同时是它的稳定标识。 */
  id: string;
  /** [B] 它原来是哪个存档（给玩家看的名字）。 */
  label: string;
  /** [B] 原来那个 `saves/` 目录 —— 「放回」会放回**这里**。 */
  from: string;
  /* [A] ⭐⭐ **它原来属于哪个（些）版本** —— 用户 2026-10-02 报的：
   *    「细分后，放到垃圾站区分不出来原来那个存档属于哪个版本」。
   *
   * ⚠️ 这一条是**删除那一刻的快照**，不是现在现算的。两个理由：
   *    ① 玩家可能早就把那个 jar 删了 —— 现算只会得到空，而记录本身忘不掉；
   *    ② 「我删的是哪个版本的东西」是关于**那一刻**的问题。
   * ⭐ `owner` 是给人看的（「内置游戏（v8 Build 160.5）」），`key` 是给排查用的
   *    （`b160.5`）—— 与 `versionEntryOf` 那两行的口径一致。 */
  owner: string;
  /** [B] 删除那一刻的隔离键；'' = 未隔离（或老条目没记）。 */
  key: string;
  /** [B] 删除时刻（Unix 毫秒）。 */
  deletedMs: number;
  /** [B] 到期时刻（Unix 毫秒）；**0 表示归档，永不过期**。 */
  expiresMs: number;
  /** [B] 是不是归档 —— 归档不参与自动清理，只能手动删或放回。 */
  archived: boolean;
  /** [B] 搬进来时有多少个文件。 */
  count: number;
  /** [B] 现在的大小（字节）。 */
  bytes: number;
  /** [B] `files/` 里现在有哪些文件（放回时要按它来）。 */
  files: string[];
}

/* ====================================================================
 * 保留期（一个全局设置）
 * ==================================================================== */

/** [B] 读保留天数。文件不在/读不出/不在选项里 ⇒ 出厂值。⛔ 静默失败，不打断任何流程。 */
export function readVaultDays(filesDir: string): number {
  const path: string = filesDir + '/' + DAYS_FILE_NAME;
  try {
    if (!fs.accessSync(path)) {
      return VAULT_DAYS_DEFAULT;
    }
    const v: number = Number.parseInt(fs.readTextSync(path).trim(), 10);
    if (Number.isNaN(v) || VAULT_DAYS_CHOICES.indexOf(v) < 0) {
      /* ⚠️ 不认识的值**不静默当成另一个有效值** —— 记一条再回退。
       * 「降级默认值」会把「读错了」掩盖成「看起来正常」，本项目为此付过代价。 */
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

/** [B] 记下保留天数。只接受三档之一。 */
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
 * meta.txt —— 与 isolation.txt / user_dirs.txt 同一套键值约定
 * ==================================================================== */

/* [A]
 * 一个键一行、`key=value`。
 *
 * ⚠️ 值里**不能有换行** —— 存档名完全可能带空格，但换行会破坏这个格式。
 *    所以写的时候把 `\r`/`\n` 换成空格（见 `sanitizeValue`）。
 * ⛔ 而**不**做转义：读的那一侧（`readMeta`）刻意保持最笨的解析，
 *    因为这是**给我们自己看的**文件，不是要兼容的格式。
 */
function sanitizeValue(v: string): string {
  return v.replace(/[\r\n]+/g, ' ');
}

/** [A] 只取第一个 `=` 切分：值里可能有 `=`（路径、名字都可能有），键里不会有。 */
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

/** [A] 把标签变成能进路径的样子。⛔ 它会成为目录名，而来源是**玩家给的存档名**。 */
function slug(label: string): string {
  let s: string = label.replace(/[^A-Za-z0-9._-]/g, '-');
  /* [B] 连续的分隔符压成一个，两端也不留 —— 目录名好看一点，也更短。 */
  s = s.replace(/-+/g, '-').replace(/^-|-$/g, '');
  if (s === '') {
    s = 'save';
  }
  return s.length > 40 ? s.substring(0, 40) : s;
}

/* ====================================================================
 * 删除 / 放回 / 彻底删 / 归档
 * ==================================================================== */

/* [A]
 * 把 `save` 这一组文件**搬进**垃圾站。返回 '' 表示成功，否则是一句给玩家看的话。
 *
 * ⚠️ 是**搬**（复制成功后删源），不是纯复制 —— 玩家的意思是「删掉它」，
 *    留一份在 `saves/` 里就等于没删。⚠️ 但顺序必须是**先复制、成功了再删源**：
 *    反过来做，一旦复制失败，那些文件就**只存在于垃圾站**（数据没丢，但存档列表里没了）。
 */
export function vaultDelete(save: SaveEntry, savesDir: string, days: number, nowMs: number,
                           owner: string, key: string): string {
  if (save.files.length === 0) {
    return '这个存档里没有文件。';
  }
  const id: string = String(nowMs) + '-' + slug(save.label);
  const dir: string = VAULT_ROOT + '/' + id;
  const filesDst: string = dir + '/' + FILES_DIR;

  /* [B] 同毫秒重名（理论上可能：连点两次）⇒ 直接拒绝，别覆盖别人的条目。 */
  if (pathExists(dir)) {
    return '垃圾站里已经有同名的条目，请稍后再试。';
  }

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
    /* ⛔ 复制没成套 ⇒ **回滚**：把刚建的那个条目整个删掉，源一个字节都没动。 */
    const rb: TreeStat = newTreeStat();
    removeTree(dir, 0, rb);
    hilog.error(DOMAIN, TAG, 'vault: copy failed (%{public}s), rolled back %{public}d file(s)',
                cp.firstError, rb.files);
    return '没能复制到垃圾站：' + cp.firstError;
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
    return '没能写下垃圾站的记录：' + wrote;
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
    /* ⚠️ 这时**两边都有**（垃圾站 + 源里剩下的）。数据没丢，但要说出来 ——
     * ⛔ 不能默默当成功：玩家的存档列表里可能还留着几个文件。 */
    hilog.error(DOMAIN, TAG, 'vault: source cleanup had %{public}d failure(s) (%{public}s)',
                rm.failed, rm.firstError);
    return '已经放进垃圾站了，但原来的文件有 ' + String(rm.failed) + ' 个没删掉：' + rm.firstError;
  }

  hilog.info(DOMAIN, TAG, 'vault: deleted %{public}s (%{public}d file(s)) -> %{public}s',
             save.label, cp.files, id);
  return '';
}

/** [A] 单个文件从 `src` 复制到 `dst`（必要时建 `dst` 的父目录）。 */
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

/* [A]
 * 写一个纯文本文件。成功返回 ''，失败返回一句给玩家看的话。
 * ⚠️ 与项目里别的写盘一样：**失败不抛**，调用方决定要不要当回事。
 */
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

/** [B] 列出垃圾站里所有条目，新的在前。目录不在 ⇒ 空数组（不是错误）。 */
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
      /* [B] 没有 meta 的目录**不当成条目** —— 那是垃圾站弄坏了的残留，
       * 列出来会让玩家以为里面还有东西，而「放回」根本不知道往哪放。 */
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

/** [B] 解析一个可能是空串/垃圾的数字。⛔ 不抛 —— meta.txt 是玩家能碰到的文件。 */
function numberOrZero(s: string): number {
  const v: number = Number.parseInt(s, 10);
  return Number.isNaN(v) ? 0 : v;
}

/** [B] 名字是个目录吗。 */
function isDirName(path: string): boolean {
  try {
    return fs.statSync(path).isDirectory();
  } catch (e) {
    return false;
  }
}

/* [A]
 * 把一个条目**放回**它来的那个 `saves/` 目录。返回 '' 或一句给玩家看的话。
 *
 * ⛔⛔ **目标已有同名文件就整体拒绝**，不覆盖、也不跳过那一个。
 *    理由：放回的目的是**撤销一次删除**。若目标里已经有同名文件，
 *    那说明玩家在那之后又玩过（游戏自己存了新档）—— 覆盖它等于**又删了一次东西**，
 *    而这次是他没要求删的。跳过那个文件则会得到一个**半个存档**，更难看出来。
 *    ⇒ 拒绝，并把**撞上的文件名**报出来，让玩家自己决定。
 */
export function vaultRestore(entry: VaultEntry, fallbackDir: string): string {
  const dir: string = VAULT_ROOT + '/' + entry.id;
  /* [B] meta 里记着它原来在哪个目录；记着那个目录已经不在了（比如整个版本被删了），
   * 就退到调用方给的当前版本目录 —— 总比放不回去强，但要在界面里说出来。 */
  let dst: string = entry.from;
  if (!pathExists(dst)) {
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
    /* ⛔ 没放全 ⇒ **回滚目标**（把已复制过去的那几个删掉），再把话说明白。
     * 留一半在目标里是最坏的结果：玩家会以为放回成功了。 */
    const rb: TreeStat = newTreeStat();
    for (const n of entry.files) {
      removeTree(dst + '/' + n, 0, rb);
    }
    hilog.error(DOMAIN, TAG, 'vault: restore failed (%{public}s), rolled back', cp.firstError);
    return '没能放回：' + cp.firstError;
  }

  /* [B] 放回成功后**把条目本身删掉** —— 否则它会一直在垃圾站里，
   * 直到到期再「删」一份已经不在那儿的数据（无害，但会让垃圾站里的数字骗人）。 */
  const rm: TreeStat = newTreeStat();
  removeTree(dir, 0, rm);
  hilog.info(DOMAIN, TAG, 'vault: restored %{public}s -> %{public}s (%{public}d file(s))',
             entry.id, dst, cp.files);
  return '';
}

/** [B] 彻底删掉一个条目。返回 '' 或一句话。 */
export function vaultPurge(entryId: string): string {
  const dir: string = VAULT_ROOT + '/' + entryId;
  if (!pathExists(dir)) {
    return '';
  }
  const rm: TreeStat = newTreeStat();
  removeTree(dir, 0, rm);
  if (rm.failed > 0) {
    hilog.error(DOMAIN, TAG, 'vault: purge failed (%{public}s)', rm.firstError);
    return '删不干净：' + rm.firstError;
  }
  hilog.info(DOMAIN, TAG, 'vault: purged %{public}s', entryId);
  return '';
}

/* [A]
 * 归档 / 取消归档。
 *
 * ⭐ 归档的含义（用户 2026-10-02 定）：**不自动清理**，只能手动删或放回。
 *    ⇒ 实现上就是把 `archived` 置 1、并把 `expires` 写成 **0**。
 *    ⚠️ 取消归档时**重新起算**保留期（而不是恢复原来的到期时刻）——
 *      那个时刻可能早就过去了，恢复它等于一取消就被清掉。
 *      ⚠️ 需要调用方把「现在」和「保留天数」传进来，因为这个模块不读设置。
 */
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
  const deleted: string = String(numberOrZero(metaOf(text, 'deleted')));
  const count: string = String(numberOrZero(metaOf(text, 'count')));
  const expires: number = archived ? 0 : (nowMs + days * DAY_MS);
  const body: string = 'label=' + sanitizeValue(label) + '\n'
                     + 'from=' + sanitizeValue(from) + '\n'
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

/* [A]
 * 清掉到期的条目。返回**清掉几个**。
 *
 * ⚠️ 在哪里调：打开垃圾站时、以及每次 `refresh()`。⛔ 它不该在渲染路径上跑 ——
 *    那会每帧都去扫一遍目录。
 * ⭐ 归档的（`archived=1`，或 `expires=0`）**永不**在这里被清掉。
 */
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
 * 给界面用的格式化
 * ==================================================================== */

/** [B] 「还有 N 天到期」/「已归档，不会自动清理」。 */
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

/** [B] Unix 毫秒 -> `YYYY-MM-DD HH:MM`。 */
export function formatMs(ms: number): string {
  const d: Date = new Date(ms);
  const p = (n: number): string => n < 10 ? '0' + String(n) : String(n);
  return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate())
       + ' ' + p(d.getHours()) + ':' + p(d.getMinutes());
}