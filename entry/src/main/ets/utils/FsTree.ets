/* [A]
 * 目录树的复制与删除 —— **只有这一份实现**。
 *
 * 为什么单独一个文件
 *   版本隔离要用它（把旧数据复制进隔离目录），存档垃圾站也要用它（搬家/彻底删除）。
 *   ⛔ 各写一份是「同一件事存在两处、其中一处先跑偏」的经典形态，本项目为此付过好几次代价。
 *
 * ⛔⛔ **不用 `fs.copyDirSync` / `fs.rmdirSync` 的递归能力** —— 它们在设备上实测过：
 *
 *   2026-10-02 四用例二分（同一次启动、同一台平板）：
 *     `copyDirSync(空目录, 新路径)`   -> ❌ Invalid argument (13900020)
 *     `copyFileSync(单个文件, 新路径)` -> ✅ OK
 *     `copyDirSync(saves/, 新路径)`    -> ❌ Invalid argument
 *     `copyDirSync(整棵数据树, 新路径)` -> ❌ Invalid argument
 *
 *   ⭐ **连复制一个空目录都失败** ⇒ 不是内容、不是父目录、不是路径长度。
 *      判据：一个连空目录都复制不了的 API，不能用。**不需要知道它为什么坏。**
 *
 * ⭐ 四个积木都实测可用：`mkdirSync` / `listFileSync` / `statSync` / `copyFileSync`。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';

const DOMAIN = 0x0000;
const TAG = 'MindustryLauncher';

/* [A] 递归的层数上限。
 * ⚠️ 它是**环的保护**：`statSync` 会跟随符号链接，而指向上级的链接会让递归不终止 ——
 *    一个不终止的递归会把主线程钉死。沙箱里实测没有符号链接，但防御要留着。 */
const MAX_DEPTH = 32;

/** [B] 一次复制/删除的记账。`firstError` 只留第一条，够定位就行。 */
export interface TreeStat {
  dirs: number;
  files: number;
  failed: number;
  firstError: string;
}

export function newTreeStat(): TreeStat {
  return { dirs: 0, files: 0, failed: 0, firstError: '' };
}

/** [B] 一个路径存在吗。`accessSync` **不抛**，返回 boolean，所以包一层统一语义。 */
function exists(path: string): boolean {
  try {
    return fs.accessSync(path);
  } catch (e) {
    return false;
  }
}

/* [A]
 * 递归复制 `src` 到 `dst`。**同步** —— 实测 188 个文件 120 毫秒（见隔离那边的记录），
 * 所以不值得为它引入异步的复杂度。⛔ 但它**不该出现在渲染路径上**。
 *
 * ⚠️ 每进一层自己 `mkdir`，所以调用方**不需要**预先建父目录
 *    （⭐ 这一点是踩出来的：我当初以为要预建，白改了一轮）。
 */
export function copyTreeInto(src: string, dst: string, depth: number, acc: TreeStat): void {
  if (depth > MAX_DEPTH) {
    acc.failed += 1;
    if (acc.firstError === '') {
      acc.firstError = '目录层级超过 ' + String(MAX_DEPTH) + ' 层（可能有环）';
    }
    return;
  }
  try {
    if (!exists(dst)) {
      fs.mkdirSync(dst, true);
    }
  } catch (e) {
    const err = e as BusinessError;
    acc.failed += 1;
    if (acc.firstError === '') {
      acc.firstError = '建目录失败 ' + dst + '：' + err.message;
    }
    return;
  }
  acc.dirs += 1;

  let names: string[] = [];
  try {
    names = fs.listFileSync(src);
  } catch (e) {
    const err = e as BusinessError;
    acc.failed += 1;
    if (acc.firstError === '') {
      acc.firstError = '列目录失败 ' + src + '：' + err.message;
    }
    return;
  }

  for (const n of names) {
    const s: string = src + '/' + n;
    const d: string = dst + '/' + n;
    let isDir: boolean = false;
    try {
      isDir = fs.statSync(s).isDirectory();
    } catch (e) {
      const err = e as BusinessError;
      acc.failed += 1;
      if (acc.firstError === '') {
        acc.firstError = '读状态失败 ' + s + '：' + err.message;
      }
      continue;
    }
    if (isDir) {
      copyTreeInto(s, d, depth + 1, acc);
    } else {
      try {
        fs.copyFileSync(s, d);
        acc.files += 1;
      } catch (e) {
        const err = e as BusinessError;
        acc.failed += 1;
        if (acc.firstError === '') {
          acc.firstError = '复制失败 ' + s + '：' + err.message;
        }
      }
    }
  }
}

/* [A]
 * 递归删除一棵树。`TreeStat.files` 记删掉的文件数。
 *
 * ⚠️ 到最后一层才 `rmdirSync`，那一刻里面已经空了 ——
 *    **空目录的 `rmdir` 是普通的**（非递归），不需要平台支持什么特别的东西。
 */
export function removeTree(path: string, depth: number, acc: TreeStat): void {
  if (depth > MAX_DEPTH) {
    acc.failed += 1;
    if (acc.firstError === '') {
      acc.firstError = '目录层级超过 ' + String(MAX_DEPTH) + ' 层（可能有环）';
    }
    return;
  }
  if (!exists(path)) {
    return;
  }

  /* [A] ⛔⛔ **先判它是不是目录** —— 这个函数在**普通文件**上也必须能直接删掉。
   *
   *   ⚠️ 原来这里没有这一段，于是对着一个文件去 `listFileSync` ⇒
   *      `Not a directory` ⇒ 一个文件都删不掉。
   *
   *   ⭐ 是怎么发现的：我为垃圾站写了一个端到端探针（合成数据），
   *      其中「删除」的第 ③ 步是**逐个文件**删源目录里的 msav。
   *      探针直接报 `列目录失败 …/saves/0.msav：Not a directory`。
   *      而**光看代码是看不出来的** —— 这个函数在隔离那边一直被拿**目录**调用，
   *      所以从来没暴露出「它不能删文件」这件事。
   *
   *   ⭐⭐ 判据：一个叫 `removeTree` 的函数被拿来删单个文件时，
   *      **调用点看不出任何异常**。所以它必须自己把两种情况都处理掉，
   *      ⛔ 而不是靠调用方「记得只能传目录」。
   */
  if (!isDir(path)) {
    try {
      fs.unlinkSync(path);
      acc.files += 1;
    } catch (e) {
      const err = e as BusinessError;
      acc.failed += 1;
      if (acc.firstError === '') {
        acc.firstError = '删除失败 ' + path + '：' + err.message;
      }
    }
    return;
  }

  let names: string[] = [];
  try {
    names = fs.listFileSync(path);
  } catch (e) {
    const err = e as BusinessError;
    acc.failed += 1;
    if (acc.firstError === '') {
      acc.firstError = '列目录失败 ' + path + '：' + err.message;
    }
    return;
  }
  for (const n of names) {
    const c: string = path + '/' + n;
    let isDir: boolean = false;
    try {
      isDir = fs.statSync(c).isDirectory();
    } catch (e) {
      acc.failed += 1;
      if (acc.firstError === '') {
        acc.firstError = '读状态失败 ' + c;
      }
      continue;
    }
    if (isDir) {
      removeTree(c, depth + 1, acc);
    } else {
      try {
        fs.unlinkSync(c);
        acc.files += 1;
      } catch (e) {
        const err = e as BusinessError;
        acc.failed += 1;
        if (acc.firstError === '') {
          acc.firstError = '删除失败 ' + c + '：' + err.message;
        }
      }
    }
  }
  try {
    fs.rmdirSync(path);
    acc.dirs += 1;
  } catch (e) {
    const err = e as BusinessError;
    acc.failed += 1;
    if (acc.firstError === '') {
      acc.firstError = '删目录失败 ' + path + '：' + err.message;
    }
  }
}

/** [B] 一个目录下所有**普通文件**的名字（不递归）。列不出来时返回空数组，不抛。 */
export function listFiles(dir: string): string[] {
  try {
    if (!exists(dir)) {
      return [];
    }
    return fs.listFileSync(dir);
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'fs: cannot list %{public}s (%{public}s)', dir, err.message);
    return [];
  }
}

/** [B] 一个文件/目录的字节数；读不到时 0。 */
export function sizeOf(path: string): number {
  try {
    const st: fs.Stat = fs.statSync(path);
    return st.isDirectory() ? 0 : st.size;
  } catch (e) {
    return 0;
  }
}

/** [B] 一个路径是不是目录；读不到时 false。 */
export function isDir(path: string): boolean {
  try {
    return fs.statSync(path).isDirectory();
  } catch (e) {
    return false;
  }
}

/** [B] 路径存在吗（给别的模块用）。 */
export function pathExists(path: string): boolean {
  return exists(path);
}
